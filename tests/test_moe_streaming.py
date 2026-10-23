"""Math check for lib/marv_mlx_moe's streaming expert path.

Builds a synthetic safetensors shard with mixed 4-bit/8-bit switch_mlp tensors,
then compares the streamed gather against the stock full-table gather. Skipped
when the system Python has no MLX (run it with the mlx-vlm tool env instead):

    PYTHONPATH=lib "$(uv tool dir)/mlx-vlm/bin/python3" -m unittest tests.test_moe_streaming
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

try:
    import mlx.core as mx
    import numpy as np
except Exception:  # pragma: no cover - depends on the interpreter
    mx = None
    np = None

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))


def _write_synthetic(path: Path, num_experts: int, hidden: int, inter: int):
    import safetensors.mlx as sm

    rng = np.random.default_rng(0)
    tensors = {}
    base = "language_model.model.layers.0.mlp.switch_mlp"
    bits_by_proj = {"gate_proj": 4, "up_proj": 8, "down_proj": 8}
    for proj, (out_dim, in_dim) in {
        "gate_proj": (inter, hidden),
        "up_proj": (inter, hidden),
        "down_proj": (hidden, inter),
    }.items():
        weight = mx.array(
            rng.normal(0, 0.02, size=(num_experts, out_dim, in_dim)).astype(np.float32)
        )
        quantized, scales, biases = mx.quantize(weight, group_size=64, bits=bits_by_proj[proj])
        tensors[f"{base}.{proj}.weight"] = quantized
        tensors[f"{base}.{proj}.scales"] = scales
        tensors[f"{base}.{proj}.biases"] = biases
    sm.save_file(tensors, str(path))


@unittest.skipIf(mx is None, "MLX not available in this interpreter")
class StreamingMoEMathTest(unittest.TestCase):
    def test_streamed_gather_matches_full_table(self):
        from marv_mlx_moe.expert_cache import ExpertCache
        from marv_mlx_moe.expert_store import ExpertStore
        from marv_mlx_moe.moe import MoEContext, Quant, _switch, swiglu

        num_experts, hidden, inter, top_k = 8, 128, 64, 3
        tmp = Path(tempfile.mkdtemp())
        shard = tmp / "model-00001-of-00001.safetensors"
        _write_synthetic(shard, num_experts, hidden, inter)

        store = ExpertStore(tmp)
        self.assertEqual(store.num_layers, 1)
        self.assertEqual(store.num_experts, num_experts)
        self.assertEqual(store.missing_tensors(), [])
        cache = ExpertCache(store, budget_bytes=1 << 30)

        rng = np.random.default_rng(1)
        x = mx.array(rng.normal(0, 1, size=(1, 5, hidden)).astype(np.float32))
        gate_w = mx.array(rng.normal(0, 0.02, size=(num_experts, hidden)).astype(np.float32))
        gates = mx.softmax(x @ gate_w.T, axis=-1, precise=True)
        inds = mx.argpartition(gates, kth=-top_k, axis=-1)[..., -top_k:]
        scores = mx.take_along_axis(gates, inds, axis=-1)
        scores = scores / scores.sum(axis=-1, keepdims=True)

        bits_by_proj = {"gate_proj": 4, "up_proj": 8, "down_proj": 8}
        stock = {}
        for proj in ("gate_proj", "up_proj", "down_proj"):
            stock[proj] = {
                part: mx.stack([store.expert(0, proj, part, e) for e in range(num_experts)])
                for part in ("weight", "scales", "biases")
            }

        xr = mx.expand_dims(x, (-2, -3))

        def stock_qmm(proj, inp):
            return mx.gather_qmm(
                inp,
                stock[proj]["weight"],
                stock[proj]["scales"],
                stock[proj]["biases"],
                rhs_indices=inds,
                transpose=True,
                group_size=64,
                bits=bits_by_proj[proj],
            )

        h = swiglu(stock_qmm("gate_proj", xr), stock_qmm("up_proj", xr))
        stock_y = (stock_qmm("down_proj", h).squeeze(-2) * scores[..., None]).sum(axis=-2)

        ctx = MoEContext(
            cache=cache,
            layer=0,
            quant={proj: Quant(bits=bits) for proj, bits in bits_by_proj.items()},
        )
        streamed_y = (_switch(ctx, x, inds) * scores[..., None]).sum(axis=-2)

        mx.eval(stock_y, streamed_y)
        diff = mx.abs(stock_y - streamed_y).max().item()
        self.assertLess(diff, 1e-3)


if __name__ == "__main__":
    unittest.main()
