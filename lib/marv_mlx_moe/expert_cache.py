"""Bounded LFU/LRU cache of materialized routed-expert weights.

Cache entries are keyed by ``(layer, expert_id)``. A byte budget bounds total
residency; eviction is least-frequently-used with a least-recently-used
tiebreak. The shared core of the model is never stored here.
"""

from __future__ import annotations

import threading
import time
from typing import Dict, List, Tuple

import mlx.core as mx

from .expert_store import PARTS, PROJECTIONS, ExpertStore


class ExpertCache:
    def __init__(
        self,
        store: ExpertStore,
        budget_bytes: int,
        eviction: str = "lfu",
    ):
        self.store = store
        self.budget = budget_bytes
        self.eviction = eviction

        # (layer, expert) -> {proj: {part: mx.array}}
        self._entries: Dict[Tuple[int, int], Dict[str, Dict[str, mx.array]]] = {}
        self._freq: Dict[Tuple[int, int], int] = {}
        self._last: Dict[Tuple[int, int], float] = {}
        self._bytes: Dict[Tuple[int, int], int] = {}

        self.total_bytes = 0
        self.hits = 0
        self.misses = 0
        self.evictions = 0
        self._lock = threading.Lock()

    # -- core ----------------------------------------------------------------

    def ensure(self, layer: int, expert_ids: List[int]) -> None:
        """Materialize ``expert_ids`` for ``layer``, fetching cold misses.

        Room is freed before insertion so the experts about to be used are
        never evicted by their own fetch.
        """
        cold = []
        now = time.monotonic()
        with self._lock:
            for expert in expert_ids:
                key = (layer, expert)
                if key in self._entries:
                    self.hits += 1
                    self._freq[key] += 1
                    self._last[key] = now
                else:
                    self.misses += 1
                    cold.append(expert)

        if cold:
            need = self.store.expert_bytes(layer) * len(cold)
            self._evict_to(self.budget - need)
            with self._lock:
                for expert in cold:
                    self._insert(layer, expert, now)

    def _insert(self, layer: int, expert: int, now: float) -> None:
        entry: Dict[str, Dict[str, mx.array]] = {}
        nbytes = 0

        for proj in PROJECTIONS:
            parts: Dict[str, mx.array] = {}
            for part in PARTS:
                parts[part] = self.store.expert(layer, proj, part, expert)
                nbytes += parts[part].nbytes
            entry[proj] = parts
        key = (layer, expert)
        self._entries[key] = entry
        self._freq[key] = 1
        self._last[key] = now
        self._bytes[key] = nbytes
        self.total_bytes += nbytes

    # -- gather --------------------------------------------------------------

    def stacked(self, layer: int, proj: str, part: str, expert_ids: List[int]) -> mx.array:
        """Return a ``[len(expert_ids), ...]`` tensor of a projection part."""
        arrays = [self._entries[(layer, expert)][proj][part] for expert in expert_ids]
        return mx.stack(arrays)

    # -- stats ---------------------------------------------------------------

    def stats(self) -> dict:
        with self._lock:
            total = self.hits + self.misses
            return {
                "hits": self.hits,
                "misses": self.misses,
                "hit_rate": (self.hits / total) if total else 0.0,
                "resident_bytes": self.total_bytes,
                "budget_bytes": self.budget,
                "evictions": self.evictions,
                "resident_experts": len(self._entries),
            }

    # -- eviction ------------------------------------------------------------

    def _evict_to(self, target: int) -> None:
        if self.total_bytes <= target:
            return
        with self._lock:
            if self.total_bytes <= target:
                return
            items = sorted(
                self._entries.keys(),
                key=lambda key: (self._freq[key], self._last[key]),
            )
            for key in items:
                if self.total_bytes <= target:
                    break
                self.total_bytes -= self._bytes[key]
                del self._entries[key]
                del self._freq[key]
                del self._last[key]
                del self._bytes[key]
                self.evictions += 1
