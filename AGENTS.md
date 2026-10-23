# Agent Guide

Instructions for AI agents working in this repo (read this at the start of a
session and follow it). Keep answers short and direct; no emojis in commits.

## What this is

**marv-mlx** is a zsh TUI for browsing, running and downloading local MLX LLMs on
Apple Silicon, exposing a drop-in OpenAI-compatible endpoint at
`localhost:11500`. It also ships as a pi extension (`marv-mlx`) that syncs/selects
models in-pi and runs a headless `marv-mlx run`.

## Repos involved

- `pavsefcik/marv-mlx` — this repo (zsh TUI + `install.sh` + the bundled catalog).
- `pavsefcik/marv-curator` — **archived.** Its `marv-curator.md` catalog was
  moved into this repo as `curated-llms.md`; the runtime no longer fetches it.
  (The `~/.cache/marv/mlx/curated-llms.md` cache is still written for the
  sibling marv harness, which reads that path.)
- `pavsefcik/homebrew-marv-mlx` — **archived.** No Homebrew formula/tap ships
  anymore; use the curl one-liner or `pi install`.

## Layout

- `marv-mlx.zsh` — the whole TUI (one large file, ~2300 lines / ~85KB). Read it
  in full before wide-ranging edits.
- `curated-llms.md` — the bundled curated catalog (RAM tier headers +
  blank-line-separated 2-line id/tagline blocks). Edit this to change the
  Download menu / `marv-mlx curated`. `MARV_MLX_CATALOG` overrides the path.
- `marv-mlx-launcher.zsh` — sourced from `~/.zshrc`; provides the `marv-mlx` shell entry.
- `install.sh` — standalone installer (uv via Astral's installer, `gum` via its
  sha256-checked release binary, `mlx-vlm` as a uv tool — no Xcode CLT, no
  Homebrew; brew is only a fallback and an existing uv/gum is reused),
  pi extension + wrapper, wires `~/.zshrc`. Accepts `--model <id>` to also
  download weights.
- `lib/` — `marv_mlx_repl.py` (chat REPL), `marv-mlx-helpers.zsh`, `sitecustomize.py`
  (setproctitle for process renaming), and `marv_mlx_moe/` (the bundled
  streaming routed-expert engine for compatible MoE checkpoints).
- `extensions/marv-mlx.ts` — pi extension (symlinked/copied into
  `~/.pi/agent/extensions/`).
- `scripts/` — one-off migration scripts.
- `tests/` — Python unittest (`mock_server.py`, `test_integration_repl.py`,
  `test_marv_mlx_repl.py`) + zsh helper tests (`test_helpers.zsh`, `test_cli.zsh`, `test_migration.zsh`).
- `Makefile` — release tooling (VERSION bump + tag; no Homebrew formula step —
  the tap is archived).

## Commands

- Test: `make test` (runs `python3 -m unittest discover -s tests` then
  `zsh tests/test_helpers.zsh`, `zsh tests/test_cli.zsh`, `zsh tests/test_migration.zsh`).
- Installer invariants: `make doctor` (asserts `install.sh` parses, the
  `mlx-vlm@0.7.4` pin and `--with setproctitle`/`--force` match between
  `install.sh` and `extensions/marv-mlx.ts`, no `--bin-dir` is passed, the
  brew-free uv URL + pinned gum sha256 are present in both, no Xcode-CLT gate has
  crept back in, and the APC sitecustomize marker is present). Run it before a
  release.
- Validate the installer: `sh -n install.sh`.
- On-disk hygiene: `marv-mlx cache [--json]` reports the footprint (APC, logs,
  hub, tool env); `marv-mlx clean --apc|--logs|--venvs|--all [--dry-run] [--force]` deletes
  regenerable caches only (never model weights or chat history, and never
  anything without an explicit flag).
- No lint/build step is enforced for the zsh; be careful with `set -e` /
  `POSIX sh` compatibility in `install.sh` (it runs under `/bin/sh`).

## Versioning / release process

- Source of truth: `VERSION` (semver). Keep synced: `package.json` `version`,
  the README's `(semver, currently X.Y.Z)` mention, and ideally the changelog.
- Standard flow (from `Makefile`): `make release VERSION=X.Y.Z` bumps `VERSION`
  + `package.json`, commits "Release X.Y.Z", tags `vX.Y.Z`; then
  `git push origin main vX.Y.Z`. Note: `make commit` stages only
  `VERSION package.json README.md` — stage the changelog and other changed
  files separately.
- Bump the changelog too (CHANGELOG.md) for each release.

## Installer invariants (do not regress)

Step 4 (`install.sh`) is the fragile part. It must:

- Resolve both `UV_TOOL_BIN` (`uv tool dir --bin`) and `UV_TOOL_DIR`
  (`uv tool dir`) up front; **prefer those over hardcoded paths** — uv's dirs are
  configurable (`UV_TOOL_BIN_DIR`, `XDG_BIN_HOME`, `XDG_DATA_HOME`) and depend
  on how uv was installed (brew vs standalone). Note `install.sh` *does* fall
  back to `$HOME/.local/bin` / `~/.local/share/uv/tools` when `uv tool dir`
  fails, so "never hardcode" is a preference, not an absolute.
- Install with `uv tool install "mlx-vlm@0.7.4" --with jinja2 --with setproctitle --force`.
- **Never pass `--bin-dir`** to `uv tool install` — it is an invalid flag.
- Retry the install up to 3 times (the tool is large / network-bound).
- After install, if `mlx_vlm.server` is missing (uv linking quirk), synthesize
  a shim at `$UV_TOOL_BIN/mlx_vlm.server` that runs
  `"$UV_TOOL_DIR/mlx-vlm/bin/python" -m mlx_vlm.server "$@"`. The shim must use
  `--force` on later installs so uv can overwrite it cleanly.
- Step 4c installs `lib/marv-mlx-apc-sitecustomize.py` into the tool env's
  `site-packages/sitecustomize.py` (defaults APC on for ANY launcher, foreign
  launches included). A `uv tool update` reinstalls the env and drops it —
  install.sh re-applies it, and `marv-mlx` startup self-heals via
  `_marv_mlx_install_apc_sitecustomize`. A `sitecustomize.py` without the
  `marv-mlx APC sitecustomize` marker is foreign and must be left untouched.

Step 5 wires `$UV_TOOL_BIN` (and `$LOCAL_BIN`, where uv itself and gum live) into
`~/.zshrc` PATH; step 8 sources `marv-mlx-launcher.zsh` from `~/.zshrc`. All
writes are grep-guarded and use `>>` (creates `.zshrc` if missing).

Steps 1-3 must stay brew-free and CLT-free:

- Step 1 is the hardware preflight (Darwin, arm64, macOS 14+) — the gum release
  below is Darwin/arm64, and MLX needs Apple Silicon anyway.
- Step 2 installs uv with `curl -LsSf https://astral.sh/uv/install.sh |
  UV_NO_MODIFY_PATH=1 sh` — a prebuilt binary, no compiler. `UV_NO_MODIFY_PATH`
  keeps PATH wiring in this script (otherwise uv writes its own rc line).
  Reuse any `uv` already on PATH; fall back to `brew install uv` only if the
  download fails.
- Step 3 installs `gum` from
  `gum_${GUM_VERSION}_Darwin_arm64.tar.gz` and **must** verify `GUM_SHA256`
  before copying the binary to `$LOCAL_BIN/gum`. Never accept an unverified
  download; fall back to brew only on network failure. `make doctor` fails if
  the pin, the sha, or the brew-freedom drift apart (in `install.sh` *or* the pi
  extension).

## Migration

- **Rename shim (one release).** `_marv_mlx_migrate_legacy_state`
  (`lib/marv-mlx-helpers.zsh`) copies `~/.cache/ymlx` to `~/.cache/marv/mlx`,
  rewrites the old managed-block markers/`YMLX_QUICK_*` names in `config.zsh`,
  fixes the `~/.zshrc` launcher line, replaces the old `ymlx` pi wrapper with a
  forwarding deprecation stub, and removes the stale `ymlx` pi extension copy.
  It is idempotent and target-absent guarded (never destructive). It runs
  before the new state dir is created. Remove it once the rename is fully
  absorbed.

## Concurrent agents

Several agents may run against this repo at once. Keep them from colliding:

- **One writer per checkout.** Any agent that edits files must run in its own
  git worktree/branch and commit before it reports back. Never leave two
  agents' output uncommitted in the same tree.
- **Single-writer artifacts.** `VERSION`, `package.json`'s version, the version
  headings in `CHANGELOG.md`, and the README's `(semver, currently X.Y.Z)` line
  belong to the releaser only. Agents do not touch them.
- **Changelog fragments.** Rather than editing `CHANGELOG.md`, an agent drops a
  `changelog.d/<slug>.md` fragment (Keep a Changelog headings). The releaser
  folds fragments into `CHANGELOG.md` under the new version heading and deletes
  them.
- **Disjoint file scopes.** `marv-mlx.zsh` and `lib/marv-mlx-helpers.zsh` are the
  two big shared files — serialize work that touches them.
- **Pre-flight.** The tree must be clean before launching a writer
  (`git status --porcelain` empty). `make doctor` fails on a duplicated
  `## [Unreleased]` heading — the tell-tale of two writers in one tree.

## Known pitfalls

- **`extensions/marv-mlx.ts` must stay in sync with `install.sh`.** As of the
  parity pass it resolves `uv tool dir [--bin]`, installs
  `mlx-vlm@0.7.4 --with jinja2 --with setproctitle --force` (retried 3×), writes
  the same `mlx_vlm.server` shim, prunes `datasets/pandas/pyarrow`, installs the
  APC sitecustomize, wires uv's actual bin dir into PATH, and installs uv/gum the
  same brew-free way (Astral installer + sha256-checked gum release). `make
  doctor` fails if the pin/`--force`/`setproctitle`/uv-URL/gum-pin drift apart.
  Two deliberate
  divergences remain: it does **not** copy `lib/sitecustomize.py` (the
  process-rename payload), so that feature no-ops on a pi copy, and it hardcodes
  a dev-fallback repo path `~/Dev/projects/marv-mlx`.
- **Never name a zsh local `path`.** `path` is the special array tied to `PATH`,
  so `local path="$1"` silently replaces your command search path for the rest
  of the function (it surfaced as `command not found: awk` inside
  `_marv_mlx_du_bytes`). Use `target`/`dir`/`file`. `tests/test_helpers.zsh`
  guards this for the size helper.
- **`lsof -F` needs field letters selected explicitly.** `p`/`f` are the only
  fields `lsof` emits unconditionally; with `-Fpc` you get no `n` line, so
  `_marv_mlx_servers_running` (the live-server guard for `marv-mlx clean --apc`)
  silently detected nothing. Use `-Fpcn`. `make doctor` and the real-listener
  test in `tests/test_cli.zsh` guard this.
- **`scripts/migrate-shared-blobs.py` is required after enabling
  `HF_HUB_DISABLE_SHARED_BLOBS=1`** (which `marv-mlx.zsh` exports process-wide on
  launch). Run it once to rewrite existing hub blobs.
- **Prefix caching is opt-in inside mlx-vlm, enabled by marv-mlx.** mlx-vlm
  0.7.4 ships APC but defaults `APC_ENABLED=0`, and the server has no `--apc`
  flag. Two layers enable it, both with the same defaults and `setdefault`
  semantics (explicit env wins; `MARV_MLX_APC=0` / `APC_ENABLED=0` opts out):
  `_marv_mlx_export_apc_env` (`lib/marv-mlx-helpers.zsh`) exports the env
  before both server launches (`_marv_mlx_launch` and
  `_marv_mlx_headless_launch`), and `lib/marv-mlx-apc-sitecustomize.py` is
  installed into the mlx-vlm **uv tool env's site-packages** as
  `sitecustomize.py` so foreign launches (the marv harness's embedded launch,
  manual `mlx_vlm.server`) are covered too. Any new code path that spawns
  `mlx_vlm.server` must call the helper (or rely on the sitecustomize) or cache
  hits silently regress to `cached_tokens=0`. Hybrid models (e.g. Qwen3.5:
  interleaved linear/full attention) use APC's checkpoint (`mode=exact`) path
  automatically; tune `APC_CHECKPOINT_INTERVAL_TOKENS` if turn suffixes still
  prefill long.
- **Streaming MoE is opt-in by checkpoint, not by launch path.**
  `_marv_mlx_moe_compatible` (`lib/marv-mlx-helpers.zsh`) decides from the cached
  `config.json`: `qwen3_5_moe` + an MLX `quantization` block + `switch_mlp`
  expert tensors + affine mode. `_marv_mlx_build_server_argv` then launches
  `<mlx-vlm-env-python> -m marv_mlx_moe.server` with `PYTHONPATH=<repo>/lib`;
  every other model still launches `mlx_vlm.server`. The engine reads experts
  from the original shards with `os.pread` (no repack) and supports mixed
  per-projection bit widths (OptiQ). Keep both launch sites
  (`_marv_mlx_launch` and `_marv_mlx_headless_launch`) going through the helper.
  The pi extension's stable copy must include `lib/marv_mlx_moe/` (it uses
  `fs.cp` recursively).
- **Hidden global side effects on launch:** `HF_TOKEN` is injected from
  `~/.cache/huggingface/token` and `HF_HUB_DISABLE_SHARED_BLOBS=1` is exported.
- **raw.githubusercontent.com CDN lags `main`.** After pushing, the one-liner
  `curl -fsSL .../marv-mlx/main/install.sh | sh` may serve a stale commit for a
  while. For a guaranteed-correct test, pin the URL to the full commit SHA:
  `.../pavsefcik/marv-mlx/<full-sha>/install.sh`. Verify content (e.g.
  `grep -c 'mlx-vlm@0.7.4'`) before trusting it.
- **GitHub push can be rejected with `GH007`** ("publish a private email").
  This repo uses the noreply email `187490479+pavsefcik@users.noreply.github.com`
  (set repo-locally as `user.email`). Keep using it for commits; don't reintroduce
  the private email.
- **Flags in the Download menu are a legacy-format artifact.** The bundled
  `curated-llms.md` catalog is plain `id` + `tagline` lines (no flags, titles or
  subtitle); only older/legacy blocks carried them. If you see a "glued" flag it
  is cosmetic and irrelevant — the model id always comes from the id line.
- **Open questions / pending work:** the standalone install on a fresh test
  machine hit uv's "only links convert+generate" quirk (uv 0.12.19). The shim
  fallback addresses it; a clean re-run of the current installer should be
  verified there before trusting it. Check whether uv ever needs the shim to be
  cleaned up on upgrade.