"""marv-mlx APC sitecustomize — installed into the mlx-vlm uv tool env.

Installed as ``sitecustomize.py`` inside the mlx-vlm uv tool env's
site-packages, so Python imports it at interpreter startup for EVERY process
in that env — including servers launched by tools that never go through
marv-mlx's launch path (e.g. the marv harness's embedded launch, which spawns
``mlx_vlm.server`` directly, or a manual ``mlx_vlm.server`` call).

Why: mlx-vlm 0.7.4 ships Automatic Prefix Caching (APC) but leaves it off by
default, and ``mlx_vlm.server`` has no CLI flag for it — the environment is the
only switch. Without it every request re-prefills the whole conversation
(``cached_tokens=0`` in the server log). marv-mlx exports the APC_* env for its
own launches (``_marv_mlx_export_apc_env``); this file additionally defaults it
on inside the tool env itself so foreign launches are covered too.

Semantics: ``setdefault`` only — any value already in the environment wins.
Opt out entirely by setting ``APC_ENABLED=0`` or ``MARV_MLX_APC=0`` in the
launching environment (e.g. in ``~/.cache/marv/mlx/config.zsh``).

This file must stay silent (no stdout/stderr writes): other console scripts in
this env (mlx_vlm.chat, mlx_vlm.convert, ...) import it as well.
"""

import os

_OPT_OUT = ("0", "off", "false", "no")


def _opted_out(name):
    return os.environ.get(name, "").strip().lower() in _OPT_OUT


if not _opted_out("MARV_MLX_APC") and not _opted_out("APC_ENABLED"):
    os.environ.setdefault("APC_ENABLED", "1")
    os.environ.setdefault("APC_DISK_ENABLED", "1")
    os.environ.setdefault(
        "APC_DISK_PATH", os.path.expanduser("~/.cache/marv/mlx/apc")
    )
    os.environ.setdefault("APC_DISK_MAX_GB", "5")
    # Hybrid models (Qwen3.5-style interleaved linear/full attention) use
    # APC's checkpoint path; a 512-token interval keeps the re-prefilled
    # suffix short without a large memory cost.
    os.environ.setdefault("APC_CHECKPOINT_INTERVAL_TOKENS", "512")
    os.environ.setdefault("APC_CHECKPOINT_ENTRIES", "2")
