"""High-level engine: lazy-load a compatible MoE, attach streaming, generate."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import mlx.core as mx

from .expert_cache import ExpertCache
from .expert_store import ExpertStore
from .moe import patch_moe

logger = logging.getLogger(__name__)

# Same file filters mlx-vlm's get_model_path uses when pulling a repo.
_ALLOW_PATTERNS = [
    "*.json",
    "*.safetensors",
    "*.py",
    "*.model",
    "*.tiktoken",
    "*.txt",
    "*.jinja",
]


class IncompatibleModelError(RuntimeError):
    """The checkpoint has no routed experts this engine can stream."""


@dataclass
class EngineConfig:
    model_id: str = "mlx-community/Ornith-1.5-35B-A3B-OptiQ-4bit"
    cache_gb: float = 6.0
    eviction: str = "lfu"
    max_tokens: int = 1024
    temperature: float = 0.7
    top_p: float = 0.95
    top_k: int = 64
    repetition_penalty: float = 1.0
    enable_thinking: bool = False
    extra: dict = field(default_factory=dict)


class Engine:
    def __init__(
        self,
        model,
        processor,
        store: ExpertStore,
        cache: ExpertCache,
        cfg: EngineConfig,
    ):
        self.model = model
        self.processor = processor
        self.store = store
        self.cache = cache
        self.cfg = cfg

    @property
    def num_layers(self) -> int:
        return self.store.num_layers

    def stats(self) -> dict:
        return {
            **self.cache.stats(),
            "peak_memory_bytes": int(mx.get_peak_memory()),
        }

    def chat_prompt(
        self, messages: list, enable_thinking: Optional[bool] = None
    ) -> str:
        from mlx_vlm.prompt_utils import apply_chat_template

        if enable_thinking is None:
            enable_thinking = self.cfg.enable_thinking
        return apply_chat_template(
            self.processor,
            self.model.config,
            messages,
            enable_thinking=enable_thinking,
        )

    def close(self) -> None:
        """Release the engine's resources (kept for API symmetry)."""
        pass


class TextProcessor:
    """Minimal processor shim exposing ``.tokenizer`` and ``.detokenizer``.

    mlx-vlm's generate path only needs these for text-only requests. Avoiding
    the full ``AutoProcessor`` keeps the vision/audio tower out of the loading
    path; the streaming engine serves text.
    """

    def __init__(self, tokenizer, detokenizer):
        object.__setattr__(self, "tokenizer", tokenizer)
        object.__setattr__(self, "detokenizer", detokenizer)

    def __getattr__(self, name):
        return getattr(self.tokenizer, name)


def _load_text_processor(model_path):
    from mlx_vlm.tokenizer_utils import load_tokenizer
    from transformers import AutoTokenizer

    hf_tokenizer = AutoTokenizer.from_pretrained(model_path)
    detokenizer_class = load_tokenizer(model_path, return_tokenizer=False)
    return TextProcessor(hf_tokenizer, detokenizer_class(hf_tokenizer))


def resolve_model_path(model_id: str) -> Path:
    """Return the local path for ``model_id``, downloading only if needed."""
    path = Path(model_id)
    if path.exists():
        logger.info("Local model ready: %s", path)
        return path

    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import IncompleteSnapshotError, LocalEntryNotFoundError

    try:
        cached = snapshot_download(
            repo_id=model_id,
            allow_patterns=_ALLOW_PATTERNS,
            local_files_only=True,
        )
    except (LocalEntryNotFoundError, IncompleteSnapshotError):
        logger.info("Model %s not in local cache; downloading...", model_id)
    else:
        logger.info("Local model ready: %s", model_id)
        return Path(cached)

    return Path(
        snapshot_download(
            repo_id=model_id,
            allow_patterns=_ALLOW_PATTERNS,
        )
    )


def load_engine(cfg: EngineConfig, model_path: str | Path | None = None) -> Engine:
    from mlx_vlm.utils import StoppingCriteria, load_model

    if model_path is None:
        model_path = resolve_model_path(cfg.model_id)
    model = load_model(model_path, lazy=True)

    processor = _load_text_processor(model_path)
    eos = getattr(model.config, "eos_token_id", None)
    processor.tokenizer.stopping_criteria = StoppingCriteria(eos, processor.tokenizer)

    store = ExpertStore(Path(model_path))
    missing = store.missing_tensors()
    if missing:
        raise IncompatibleModelError(
            "checkpoint is not streamable: missing routed-expert tensors "
            + ", ".join(missing[:5])
            + (" ..." if len(missing) > 5 else "")
        )

    budget = int(cfg.cache_gb * (1024**3))
    cache = ExpertCache(store, budget_bytes=budget, eviction=cfg.eviction)
    patched = patch_moe(model, cache)
    if patched == 0:
        raise IncompatibleModelError(
            "checkpoint has no compatible MoE blocks with routed experts"
        )

    logger.info(
        "Streaming MoE ready: %d blocks, %d experts/layer, %.1f GiB experts on disk, "
        "%.1f GiB cache",
        patched,
        store.num_experts,
        store.total_expert_bytes() / 2**30,
        cfg.cache_gb,
    )
    return Engine(model, processor, store, cache, cfg)


def generate(engine: Engine, prompt: str, **kwargs) -> str:
    """One-shot generation returning the full text."""
    from mlx_vlm import generate as vlm_generate

    result = vlm_generate(engine.model, engine.processor, prompt, **_gen_kwargs(engine, kwargs))
    return result.text if hasattr(result, "text") else str(result)


def stream(engine: Engine, prompt: str, **kwargs):
    """Yield text chunks as they are generated."""
    from mlx_vlm import stream_generate

    for result in stream_generate(
        engine.model, engine.processor, prompt, **_gen_kwargs(engine, kwargs)
    ):
        if getattr(result, "text", None):
            yield result.text


def _gen_kwargs(engine: Engine, overrides: dict) -> dict:
    values = {
        "max_tokens": engine.cfg.max_tokens,
        "temperature": engine.cfg.temperature,
        "top_p": engine.cfg.top_p,
        "top_k": engine.cfg.top_k,
        "repetition_penalty": engine.cfg.repetition_penalty,
        "enable_thinking": engine.cfg.enable_thinking,
    }
    for key, value in overrides.items():
        if value is not None:
            values[key] = value
    return values
