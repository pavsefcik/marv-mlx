# Changelog

All notable changes to ymlx are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/). Version numbers are kept in
sync across `VERSION`, `package.json`, the Homebrew formula, and the README.

## [Unreleased]

## [0.132.3] - 2026-09-29

### Fixed
- **Installer reliability (`install.sh`).** Step 4 now pins `mlx-vlm@0.7.4`
  and installs with `--force`.
- **uv linking quirk.** Some `uv` versions (observably `0.12.19`) link only
  `mlx_vlm.convert`/`mlx_vlm.generate` and skip `mlx_vlm.server`. Step 4 now
  synthesizes a `mlx_vlm.server` shim from the tool environment
  (`python -m mlx_vlm.server`) when uv fails to link it, so the server command
  ymlx depends on is always available.

## [0.132.2] - 2026-09-29

### Fixed
- **Installer (`install.sh`).** Removed the invalid `--bin-dir` flag from the
  `uv tool install` invocation (not supported by `uv tool install`).

## [0.132.1] - 2026-09-29

### Changed / Fixed
- **Installer (`install.sh`).** Resolved where ymlx assumed uv puts tool shims.
  Previously hardcoded to `~/.local/bin`; now queries `uv tool dir --bin` and
  wires that exact directory onto `PATH` in `~/.zshrc` (step 5). Fixes installs
  where uv's executable dir is non-default (uv installed via Homebrew, or
  `XDG_BIN_HOME`/`UV_TOOL_BIN_DIR`/`XDG_DATA_HOME` set).
- The `uv tool install mlx-vlm` step retries up to 3 times and verifies the
  `mlx_vlm.server` shim exists after install.

## [0.132.0] - 2026-09-29

- Keep weight blobs per-model; add shared-blob purge + migration.
- Show the model name as the running process (Activity Monitor / `ps` via
  `setproctitle` + `lib/sitecustomize.py`).
- Fix broken `install.sh` wrapper (set -u exec gotcha); add `ymlx --version`
  (`-v`/`-V`) flag.

---

> Note: version history before `0.132.0` is not yet captured in this changelog.
> It was started retroactively from git history; earlier changes remain only in
> commit messages (`git log`).