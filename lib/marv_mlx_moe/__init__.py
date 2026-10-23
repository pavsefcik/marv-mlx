"""Streaming routed experts for mlx-vlm MoE models.

This is marv-mlx's built-in MoE engine: the shared core stays resident while the
routed experts are read from the original safetensors checkpoint on demand and
kept in a bounded RAM cache. It is used only for checkpoints that are compatible
with the engine (see :func:`marv_mlx_moe.engine.load_engine`); every other model
keeps using ``mlx_vlm.server``.
"""

from .engine import (
    Engine,
    EngineConfig,
    IncompatibleModelError,
    generate,
    load_engine,
    resolve_model_path,
    stream,
)
from .expert_cache import ExpertCache
from .expert_store import ExpertStore
from .moe import MoEContext, Quant, patch_moe

__all__ = [
    "Engine",
    "EngineConfig",
    "ExpertCache",
    "ExpertStore",
    "IncompatibleModelError",
    "MoEContext",
    "Quant",
    "generate",
    "load_engine",
    "patch_moe",
    "resolve_model_path",
    "stream",
]
