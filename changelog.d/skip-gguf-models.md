### Added

- **`marv-mlx list --all`** shows every repo in the HuggingFace cache, including
  the GGUF ones the default list now hides.

### Changed

- **GGUF repos no longer show up as runnable models.** `mlx-vlm` (and `mlx-lm`)
  ship no GGUF loader, so a cached GGUF repo could only fail at launch. The main
  menu, `marv-mlx list` and the pi extension's model sync now skip a repo when
  its id says GGUF (e.g. `…-GGUF`) or its cached snapshot contains a `.gguf`
  file. Filtering on that signal rather than on an "mlx" in the id keeps locally
  converted models — whose names need not mention mlx — in the list.

### Fixed

- Launching or downloading a GGUF repo now fails with a one-line explanation
  (`mlx-vlm cannot load GGUF — pick an MLX-quantized repo`) instead of a
  traceback in the server log.
