"""Streaming MoE forward used instead of a resident ``switch_mlp`` table.

The stock block computes over the full fused expert table. This forward:

1. runs the router unchanged,
2. materializes only the selected experts in the :class:`ExpertCache`,
3. stacks those experts and runs ``gather_qmm`` (the same quantized-gather
   kernel the stock path uses).

Quantization parameters are kept per layer *and per projection*: OptiQ-style
checkpoints mix 4-bit and 8-bit tensors within the same layer.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict

import mlx.core as mx
import mlx.nn as nn
import numpy as np

from .expert_cache import ExpertCache
from .expert_store import PROJECTIONS


@dataclass(frozen=True)
class Quant:
    group_size: int = 64
    bits: int = 4
    mode: str = "affine"


@dataclass
class MoEContext:
    cache: ExpertCache
    layer: int
    quant: Dict[str, Quant] = field(default_factory=dict)


def silu(x: mx.array) -> mx.array:
    return x * mx.sigmoid(x)


def swiglu(gate: mx.array, up: mx.array) -> mx.array:
    """MLX-LM's SwiGLU activation (kept local so mlx-lm is not required)."""
    return silu(gate) * up


def _switch(ctx: MoEContext, x: mx.array, inds: mx.array) -> mx.array:
    ids_flat = [int(i) for i in np.asarray(inds).reshape(-1).tolist()]
    distinct = list(dict.fromkeys(ids_flat))

    ctx.cache.ensure(ctx.layer, distinct)

    local = {expert: i for i, expert in enumerate(distinct)}
    linds = mx.array([local[expert] for expert in ids_flat], dtype=mx.uint32).reshape(
        inds.shape
    )

    xr = mx.expand_dims(x, (-2, -3))

    def qmm(proj: str, inp: mx.array) -> mx.array:
        quant = ctx.quant.get(proj) or Quant()
        weight = ctx.cache.stacked(ctx.layer, proj, "weight", distinct)
        scales = ctx.cache.stacked(ctx.layer, proj, "scales", distinct)
        biases = ctx.cache.stacked(ctx.layer, proj, "biases", distinct)
        return mx.gather_qmm(
            inp,
            weight,
            scales,
            biases,
            rhs_indices=linds,
            transpose=True,
            group_size=quant.group_size,
            bits=quant.bits,
            mode=quant.mode,
        )

    x_gate = qmm("gate_proj", xr)
    x_up = qmm("up_proj", xr)
    h = swiglu(x_gate, x_up)
    x = qmm("down_proj", h)

    return x.squeeze(-2)


def _moe_forward(block, ctx: MoEContext, x: mx.array) -> mx.array:
    logits = block.gate(x)
    gates = mx.softmax(logits, axis=-1, precise=True)

    k = block.top_k
    inds = mx.argpartition(gates, kth=-k, axis=-1)[..., -k:]
    scores = mx.take_along_axis(gates, inds, axis=-1)
    scores = scores / scores.sum(axis=-1, keepdims=True)

    routed = _switch(ctx, x, inds)
    routed = (routed * scores[..., None]).sum(axis=-2)

    shared = block.shared_expert(x)
    scale = getattr(block, "_shared_expert_scale", None)
    if callable(scale):
        shared = scale(x) * shared
    elif hasattr(block, "shared_expert_gate"):
        shared = mx.sigmoid(block.shared_expert_gate(x)) * shared
    return routed + shared


class StreamingMoeBlock(nn.Module):
    """Wrap a dense MoE block and route only its selected experts."""

    def __init__(self, inner: nn.Module, context: MoEContext):
        super().__init__()
        self.inner = inner
        self.context = context

    def __call__(self, x: mx.array) -> mx.array:
        return _moe_forward(self.inner, self.context, x)


def _projection_quant(layer: int, mlp) -> Dict[str, Quant]:
    quant: Dict[str, Quant] = {}
    switch = mlp.switch_mlp
    for proj in PROJECTIONS:
        linear = getattr(switch, proj, None)
        bits = getattr(linear, "bits", None)
        if bits is None:
            raise ValueError(
                f"layer {layer} {proj} is not quantized; streaming MoE needs an "
                "MLX affine-quantized checkpoint"
            )
        quant[proj] = Quant(
            group_size=int(getattr(linear, "group_size", 64) or 64),
            bits=int(bits),
            mode=str(getattr(linear, "mode", "affine") or "affine"),
        )
    return quant


def _candidate_layers(model):
    lm = getattr(model, "language_model", model)
    inner = getattr(lm, "model", lm)
    return getattr(inner, "layers", [])


def patch_moe(model, cache: ExpertCache) -> int:
    """Attach the streaming forward to every compatible MoE block in ``model``.

    Returns the number of patched blocks. A model with no compatible blocks is
    rejected by the caller (it should have used ``mlx_vlm.server`` instead).
    """
    patched = 0
    for index, layer in enumerate(_candidate_layers(model)):
        mlp = getattr(layer, "mlp", None)
        if mlp is None or isinstance(mlp, StreamingMoeBlock):
            continue
        if not all(
            hasattr(mlp, attr)
            for attr in ("gate", "switch_mlp", "shared_expert", "top_k")
        ):
            continue
        ctx = MoEContext(
            cache=cache,
            layer=index,
            quant=_projection_quant(index, mlp),
        )
        layer.mlp = StreamingMoeBlock(mlp, ctx)
        patched += 1
    return patched
