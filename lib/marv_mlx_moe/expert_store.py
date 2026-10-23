"""Lazy partial reads of routed-expert weights from safetensors shards.

Each routed expert tensor is stored contiguously in a shard with shape
``[num_experts, ...]``. We parse the safetensors header once to find byte
offsets, keep the shard file descriptors open, and read a single expert's bytes
with ``os.pread`` on demand. Only the requested expert touches the disk, and
there is no per-slice overhead from the safetensors Python backend.

The parser is deliberately tolerant of model-family prefixes: keys match a
generic ``...layers.N.mlp.switch_mlp.<projection>.<part>`` shape, and mixed
quantization is supported because every projection keeps its own layout.
"""

from __future__ import annotations

import glob
import json
import os
import re
import struct
from pathlib import Path
from typing import Dict, Tuple

import mlx.core as mx
import numpy as np

PROJECTIONS = ("gate_proj", "up_proj", "down_proj")
PARTS = ("weight", "scales", "biases")

# numpy dtype -> (storage dtype, bitcast target). bfloat16 has no numpy dtype,
# so its bytes are read as uint16 and reinterpreted by MLX.
_NP_DTYPE = {
    "U8": (np.uint8, None),
    "I8": (np.int8, None),
    "U16": (np.uint16, None),
    "I16": (np.int16, None),
    "U32": (np.uint32, None),
    "I32": (np.int32, None),
    "U64": (np.uint64, None),
    "I64": (np.int64, None),
    "F16": (np.float16, None),
    "BF16": (np.uint16, mx.bfloat16),
    "F32": (np.float32, None),
    "F64": (np.float64, None),
}

_KEY_RE = re.compile(
    r"(?:^|.*\.)layers\.(\d+)\.mlp\.switch_mlp\.(\w+_proj)\.(\w+)$"
)


class _Tensor:
    __slots__ = ("fd", "data_start", "per_expert_bytes", "inner_shape", "np_dtype", "mx_dtype")

    def __init__(
        self,
        fd: int,
        data_start: int,
        per_expert_bytes: int,
        inner_shape,
        np_dtype,
        mx_dtype,
    ):
        self.fd = fd
        self.data_start = data_start
        self.per_expert_bytes = per_expert_bytes
        self.inner_shape = inner_shape
        self.np_dtype = np_dtype
        self.mx_dtype = mx_dtype


class ExpertStore:
    """Byte-offset index over the routed-expert tensors in a checkpoint."""

    def __init__(self, model_dir: Path | str):
        model_dir = Path(model_dir)
        shard_paths = sorted(glob.glob(str(model_dir / "*.safetensors")))
        shard_paths = [p for p in shard_paths if not p.endswith("consolidated.safetensors")]
        if not shard_paths:
            raise FileNotFoundError(f"No safetensors shards found in {model_dir}")

        self._fds = []
        self._tensors: Dict[Tuple[int, str, str], _Tensor] = {}
        self.num_layers = 0
        self.num_experts = 0

        for path in shard_paths:
            fd = os.open(path, os.O_RDONLY)
            self._fds.append(fd)
            with open(path, "rb") as fh:
                header_len = struct.unpack("<Q", fh.read(8))[0]
                meta = json.loads(fh.read(header_len))
            base = 8 + header_len  # data_offsets are relative to the data section

            for key, info in meta.items():
                match = _KEY_RE.match(key)
                if not match:
                    continue
                layer = int(match.group(1))
                proj = match.group(2)
                part = match.group(3)
                if proj not in PROJECTIONS or part not in PARTS:
                    continue
                shape = info["shape"]
                dtype = info["dtype"]
                if dtype not in _NP_DTYPE:
                    raise ValueError(f"Unsupported expert dtype {dtype} in {key}")
                start, end = info["data_offsets"]
                per = (end - start) // shape[0]
                np_dtype, mx_dtype = _NP_DTYPE[dtype]
                self._tensors[(layer, proj, part)] = _Tensor(
                    fd, base + start, per, tuple(shape[1:]), np_dtype, mx_dtype
                )
                self.num_layers = max(self.num_layers, layer + 1)
                self.num_experts = max(self.num_experts, shape[0])

    # -- discovery / validation ---------------------------------------------

    def missing_tensors(self) -> list[str]:
        """Return human-readable names of expected tensors that are absent."""
        missing = []
        for layer in range(self.num_layers):
            for proj in PROJECTIONS:
                for part in PARTS:
                    if (layer, proj, part) not in self._tensors:
                        missing.append(f"layer {layer} {proj} {part}")
        return missing

    def total_expert_bytes(self) -> int:
        return self.num_experts * sum(
            self.expert_bytes(layer) for layer in range(self.num_layers)
        )

    # -- raw reads -----------------------------------------------------------

    def read_bytes(self, layer: int, proj: str, part: str, idx: int) -> bytes:
        tensor = self._tensors[(layer, proj, part)]
        return os.pread(
            tensor.fd,
            tensor.per_expert_bytes,
            tensor.data_start + idx * tensor.per_expert_bytes,
        )

    def expert(self, layer: int, proj: str, part: str, idx: int) -> mx.array:
        tensor = self._tensors[(layer, proj, part)]
        data = self.read_bytes(layer, proj, part, idx)
        arr = np.frombuffer(data, dtype=tensor.np_dtype).reshape(tensor.inner_shape)
        out = mx.array(arr)
        if tensor.mx_dtype is not None:
            out = out.view(tensor.mx_dtype)
        return out

    def dtype_of(self, layer: int, proj: str, part: str):
        return self._tensors[(layer, proj, part)].np_dtype

    def inner_shape(self, layer: int, proj: str, part: str):
        return self._tensors[(layer, proj, part)].inner_shape

    def expert_bytes(self, layer: int) -> int:
        return sum(
            self._tensors[(layer, proj, part)].per_expert_bytes
            for proj in PROJECTIONS
            for part in PARTS
        )
