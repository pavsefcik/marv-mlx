# Agent Guide

Instructions for AI agents working in this repo (read this at the start of a
session and follow it). Keep answers short and direct; no emojis in commits.

## What this is

**marv-mlx** is a zsh TUI for browsing, running and downloading local MLX LLMs on
Apple Silicon, exposing a drop-in OpenAI-compatible endpoint at
`localhost:11500`. It also ships as a pi extension (`marv-mlx-sync`) that syncs/selects
models in-pi and runs a headless `marv-mlx run`.

## Repos involved

- `pavsefcik/marv-mlx` — this repo (zsh TUI + `install.sh` + Homebrew formula source).
- `pavsefcik/marv-curator` — `marv-curator.md`, the hand-picked download catalog
  (flag-titled blocks consumed by the Download menu).
- `pavsefcik/homebrew-marv-mlx` — the tap; `Formula/marv-mlx.rb` (path `../homebrew-marv-mlx`).

## Layout

- `marv-mlx.zsh` — the whole TUI (one large file, ~75KB). Read it in full before
  wide-ranging edits.
- `marv-mlx-launcher.zsh` — sourced from `~/.zshrc`; provides the `marv-mlx` shell entry.
- `install.sh` — standalone installer (brew `uv`/`gum`, `mlx-vlm` as a uv tool,
  pi extension + wrapper, wires `~/.zshrc`).
- `lib/` — `marv_mlx_repl.py` (chat REPL), `marv-mlx-helpers.zsh`, `sitecustomize.py`
  (setproctitle for process renaming).
- `extensions/marv-mlx-sync.ts` — pi extension (symlinked/copied into
  `~/.pi/agent/extensions/`).
- `scripts/` — one-off migration scripts.
- `tests/` — Python unittest (`mock_server.py`, `test_integration_repl.py`,
  `test_marv_mlx_repl.py`) + zsh helper tests (`test_helpers.zsh`, `test_cli.zsh`, `test_migration.zsh`).
- `Makefile` — release tooling.

## Commands

- Test: `make test` (runs `python3 -m unittest discover -s tests` then
  `zsh tests/test_helpers.zsh`, `zsh tests/test_cli.zsh`, `zsh tests/test_migration.zsh`).
- Validate the installer: `sh -n install.sh`.
- No lint/build step is enforced for the zsh; be careful with `set -e` /
  `POSIX sh` compatibility in `install.sh` (it runs under `/bin/sh`).

## Versioning / release process

- Source of truth: `VERSION` (semver). Keep synced: `package.json` `version`,
  the README's `(semver, currently X.Y.Z)` mention, and ideally the changelog.
- Standard flow (from `Makefile`): `make release VERSION=X.Y.Z` bumps `VERSION`
  + `package.json`, commits "Release X.Y.Z", tags `vX.Y.Z`; then
  `git push origin main vX.Y.Z`; then `make formula` to refresh the tap hash.
  Note: `make commit` stages only `VERSION package.json README.md` — stage the
  changelog and other changed files separately.
- Bump the changelog too (CHANGELOG.md) for each release.

## Installer invariants (do not regress)

Step 4 (`install.sh`) is the fragile part. It must:

- Resolve both `UV_TOOL_BIN` (`uv tool dir --bin`) and `UV_TOOL_DIR`
  (`uv tool dir`) up front; **never hardcode `~/.local/bin`** — uv's dirs are
  configurable (`UV_TOOL_BIN_DIR`, `XDG_BIN_HOME`, `XDG_DATA_HOME`) and depend
  on how uv was installed (brew vs standalone).
- Install with `uv tool install "mlx-vlm@0.7.4" --with jinja2 --with setproctitle --force`.
- **Never pass `--bin-dir`** to `uv tool install` — it is an invalid flag.
- Retry the install up to 3 times (the tool is large / network-bound).
- After install, if `mlx_vlm.server` is missing (uv linking quirk), synthesize
  a shim at `$UV_TOOL_BIN/mlx_vlm.server` that runs
  `"$UV_TOOL_DIR/mlx-vlm/bin/python" -m mlx_vlm.server "$@"`. The shim must use
  `--force` on later installs so uv can overwrite it cleanly.

Step 5 wires `$UV_TOOL_BIN` into `~/.zshrc` PATH; step 8 sources
`marv-mlx-launcher.zsh` from `~/.zshrc`. Both write with `>>` (creates `.zshrc` if
missing).

## Migration

- **Rename shim (one release).** `_marv_mlx_migrate_legacy_state`
  (`lib/marv-mlx-helpers.zsh`) copies `~/.cache/ymlx` to `~/.cache/marv/mlx`,
  rewrites the old managed-block markers/`YMLX_QUICK_*` names in `config.zsh`,
  fixes the `~/.zshrc` launcher line, and removes stale `ymlx` pi wrapper/extension
  copies. It is idempotent and target-absent guarded (never destructive). It runs
  before the new state dir is created. Remove it once the rename is fully absorbed.

## Known pitfalls

- **raw.githubusercontent.com CDN lags `main`.** After pushing, the one-liner
  `curl -fsSL .../marv-mlx/main/install.sh | sh` may serve a stale commit for a
  while. For a guaranteed-correct test, pin the URL to the full commit SHA:
  `.../pavsefcik/marv-mlx/<full-sha>/install.sh`. Verify content (e.g.
  `grep -c 'mlx-vlm@0.7.4'`) before trusting it.
- **GitHub push can be rejected with `GH007`** ("publish a private email").
  This repo uses the noreply email `187490479+pavsefcik@users.noreply.github.com`
  (set repo-locally as `user.email`). Keep using it for commits; don't reintroduce
  the private email.
- **Flags in the Download menu are cosmetic.** The `marv-curator.md` titles
  carry flags with a space; if the flag looks glued to the name it's a terminal
  emoji-width rendering artifact, not a bug. The download model ID comes from
  the subtitle line, never from the flag/title.
- **Open questions / pending work:** the standalone install on a fresh test
  machine hit uv's "only links convert+generate" quirk (uv 0.12.19). The shim
  fallback addresses it; a clean re-run of the current installer should be
  verified there before trusting it. Check whether uv ever needs the shim to be
  cleaned up on upgrade.