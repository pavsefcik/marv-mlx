### Added

- **`marv-mlx list --all`** shows every repo in the HuggingFace cache, including
  the ones the default list now hides because `mlx-vlm` cannot load them.

### Changed

- **Only loadable repos are offered as models.** `mlx_vlm.utils.load_model`
  reads `*.safetensors` (MLX-quantized, or plain bf16/fp16 HuggingFace) and
  nothing else, so the main menu, `marv-mlx list` and the pi extension's model
  sync now skip a cached repo when:
  - its id says GGUF (`…-GGUF`) or its snapshot holds a `.gguf` file —
    neither mlx-vlm nor mlx-lm ships a GGUF loader;
  - its snapshot has no usable `.safetensors` (PyTorch `pytorch_model.bin`,
    ONNX, CoreML, npz-only, `consolidated.safetensors` alone, or an unfinished
    download) — the loader aborts with "No safetensors found";
  - its `config.json` packs weights for another runtime
    (`quantization_config.quant_method` = bitsandbytes/gptq/awq/
    compressed-tensors/…), which needs `mlx_vlm.convert` first. fp8 and MLX's
    own `quantization` block are allowed.

  The check is on format, not on an "mlx" in the id, so locally converted
  models — whose names need not mention mlx — stay listed, and unknown repos
  (nothing cached yet) are assumed loadable.

### Fixed

- Launching or downloading an unloadable model now fails with a one-line
  explanation of the format problem instead of a traceback in the server log.
- `_marv_mlx_model_family` no longer resolves a missing snapshot to the current
  directory (`ls -d` with no surviving argument lists `.`), which could read an
  unrelated `config.json` from the working directory.
