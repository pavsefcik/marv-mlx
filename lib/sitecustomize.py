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