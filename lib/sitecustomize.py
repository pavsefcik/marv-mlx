# marv-mlx process-title hook (auto-imported by Python at interpreter startup).
#
# The Python `site` module imports any `sitecustomize` found on sys.path, so
# placing this file on PYTHONPATH lets marv-mlx rename a launched process to the
# model it is running. Activity Monitor and `ps` then show e.g.
# "mlx-community/Qwen3-8B-Instruct" instead of a generic "Python 3.1x", which
# makes it obvious which model a running server belongs to.
#
# marv-mlx launches the server / chat REPL with:
#   MARV_MLX_PROCTITLE=<model-id> PYTHONPATH=<directory containing this file> ...
#
# The rename is silent and best-effort: if the `setproctitle` package isn't
# importable (e.g. the mlx-vlm uv tool predates install.sh's change, or a
# plain interpreter is used), we simply do nothing and the command runs
# exactly as before.
import os

title = os.environ.get("MARV_MLX_PROCTITLE")
if title:
    try:
        from setproctitle import setproctitle
    except Exception:
        pass  # no setproctitle — leave the process named "python3.x"
    else:
        setproctitle(title)

# Chain-load the next sitecustomize on sys.path. Python's `site` module imports
# only the FIRST `sitecustomize` it finds, and this directory sits on
# PYTHONPATH (ahead of site-packages), so without this tail any sitecustomize
# later on sys.path is silently skipped — notably the marv-mlx APC defaults
# installed into the mlx-vlm tool env's site-packages, whose loss quietly
# disables prefix caching for the launched server (cached_tokens=0 every
# turn). Best-effort: any failure here must never break interpreter startup.
def _marv_mlx_chain_sitecustomize():
    import importlib.util
    import sys
    from pathlib import Path

    try:
        here = str(Path(__file__).resolve().parent)
    except Exception:
        return
    for entry in list(sys.path):
        if not entry:
            continue
        try:
            if str(Path(entry).resolve()) == here:
                continue
            candidate = Path(entry) / "sitecustomize.py"
            if not candidate.is_file():
                continue
            if str(candidate.resolve()) == str(Path(__file__).resolve()):
                continue
        except Exception:
            continue
        try:
            spec = importlib.util.spec_from_file_location("_marv_mlx_chained_sitecustomize", candidate)
            if spec is not None and spec.loader is not None:
                spec.loader.exec_module(importlib.util.module_from_spec(spec))
        except Exception:
            pass
        return  # first other sitecustomize found — chained or not, we are done


_marv_mlx_chain_sitecustomize()