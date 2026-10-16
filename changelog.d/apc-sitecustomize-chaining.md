## [Unreleased]

### Fixed

- `lib/sitecustomize.py` (the process-rename hook) now chain-loads the next
  `sitecustomize` on `sys.path`. Python imports only the first one, and the
  hook directory sits on `PYTHONPATH` ahead of site-packages, so it silently
  shadowed the marv-mlx APC payload installed in the mlx-vlm tool env and any
  other foreign `sitecustomize`. marv-mlx's own launches were masked by the
  exported `APC_*` env, but the chained hook keeps the payload effective even
  without it.
- `marv-mlx cache` now reports `cached_tokens_last` from the newest server log
  across both marv-mlx's own log dir and the marv harness's
  `~/.cache/marv/logs` (where an embedded-launch server writes), instead of
  reporting `null` while a harness server was serving.
