# Changelog

All notable changes to marv-mlx are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/). Version numbers are kept in
sync across `VERSION`, `package.json`, and the README.

## [Unreleased]

## [0.137.2] - 2026-10-15

### Fixed
- **CI: the listener check could not run on the runner.** `tests/test_cli.zsh`
  verified `_marv_mlx_servers_running` against a live `python3 -m http.server`.
  GitHub's `macos-latest` runners did not reliably bind localhost, so the test
  skipped (and, before that, failed on a hand-picked `PATH`). A test that cannot
  fail is worse than no test, so the live check was replaced with deterministic
  coverage: the `lsof -Fpcn` parsing is split into `_marv_mlx_parse_lsof_listeners`
  and pinned in `tests/test_helpers.zsh` against real output shapes — including
  the missing-`n` shape that `-Fpc` produces, which had made the live-server
  guard silent. `make doctor` independently asserts the helper passes `-Fpcn`.

## [0.137.1] - 2026-10-14

### Added
- **CI (`.github/workflows/`).** `Test` runs `make doctor` + `make test` on
  every push to `main` and every pull request. `Release` runs on a published
  release and verifies that `VERSION`, the `vX.Y.Z` tag, the `CHANGELOG.md`
  section, `package.json` and the README semver line all agree, then re-runs the
  same checks. Both use `macos-latest` because the suite exercises BSD/macOS-only
  tools (`lsof -Fpcn`, `stat -f%z`, `head -c`), and the project targets Apple
  Silicon. This closes a real gap: the installer resolves its download ref from
  `releases/latest` and the in-app update check reads the same endpoint, so a
  tag with no release — or a release whose files disagree on the version —
  silently ships the wrong thing (v0.137.0 was tagged before its release
  existed, and `releases/latest` still pointed at v0.136.3).

## [0.137.0] - 2026-10-14

### Added
- **`marv-mlx cache` and `marv-mlx clean`.** `cache [--json]` reports the
  on-disk footprint (APC checkpoints, logs, chat history, the HF hub, the
  mlx-vlm tool env) plus the effective APC settings and the newest request's
  `cached_tokens`. `clean --apc|--logs|--venvs|--all [--dry-run] [--force]`
  deletes regenerable caches only: never model weights or chat history, never
  anything with no target flag, and it refuses `--apc` while a server is live
  (the checkpoints are memory-mapped) unless `--force` is given. Both run before
  the gum/uv/mlx-vlm tool check, so they still work on a half-broken install —
  silent accumulation (a multi-GB APC tree, a stale per-model venv) is now
  visible and reclaimable.

### Fixed
- **pi `/marv-mlx-setup` now produces the same environment as `install.sh`.**
  The extension previously ran `uv tool install mlx-vlm --with jinja2` —
  unpinned, no `--force`, no `setproctitle`, no shim, no dep prune — so a
  pi-managed install could differ from a script install (and hit uv's link quirk
  that skips `mlx_vlm.server`). It now resolves uv's dirs with
  `uv tool dir [--bin]`, installs `mlx-vlm@0.7.4 --with jinja2 --with
  setproctitle --force` (retried 3x), synthesizes the same `mlx_vlm.server`
  shim, prunes `datasets/pandas/pyarrow`, and wires uv's actual bin dir into
  `~/.zshrc` instead of a hardcoded `~/.local/bin`.
- **`_marv_mlx_du_bytes` clobbered `PATH`.** The helper declared
  `local path=...`, which in zsh rebinds the special `path` array backing `PATH`,
  so every command lookup inside it failed (`command not found: awk`). Renamed
  and regression-tested.

### Changed
- **`make doctor`** asserts the installer invariants documented in `AGENTS.md`
  (the `mlx-vlm@0.7.4` pin, `--with setproctitle` and `--force` present and
  matching between `install.sh` and `extensions/marv-mlx.ts`, no `--bin-dir`,
  APC sitecustomize marker present). `tests/test_helpers.zsh` additionally fails
  if the APC defaults drift between `_marv_mlx_export_apc_env` and
  `lib/marv-mlx-apc-sitecustomize.py`.

## [0.136.4] - 2026-10-14

### Fixed
- **Every chat turn re-prefilled the whole conversation (~5k tokens, ~30s).**
  mlx-vlm 0.7.4 ships Automatic Prefix Caching (APC) but leaves it off by
  default (`APC_ENABLED=0`), and `mlx_vlm.server` exposes no CLI flag for it, so
  the server log showed `cached_tokens=0` on every request. marv-mlx now exports
  `APC_ENABLED=1` (plus a state-local disk cache cap and a 512-token checkpoint
  interval for hybrid models) right before launching the server, in both the TUI
  (`_marv_mlx_launch`) and `marv-mlx run` (`_marv_mlx_headless_launch`). Hybrid
  models like Qwen3.5 use APC's checkpoint (`mode=exact`) path automatically.
  Verified against `ornith-ai/Ornith-1.5-9B-MLX-4bit`: turn 2 reused 429/452
  prompt tokens and prefill dropped from 1.8s to 0.26s. Set `MARV_MLX_APC=0` in
  `config.zsh` to opt out.
- **Prefix caching now also covers servers marv-mlx doesn't launch itself.**
  The marv harness's *embedded* launch spawns `mlx_vlm.server` directly from
  the uv tool env, bypassing marv-mlx's launch path — so its server also ran
  with `cached_tokens=0` every turn. marv-mlx now installs a small
  `sitecustomize.py` (from `lib/marv-mlx-apc-sitecustomize.py`) into the
  mlx-vlm tool env's site-packages: it runs at interpreter startup and
  defaults the same `APC_*` variables on with `setdefault`, so *any* launcher
  (marv embedded, a manual `mlx_vlm.server`, marv-mlx) gets prefix caching.
  Installed by `install.sh` (step 4c) and `/marv-mlx-setup`, self-healed on
  every marv-mlx startup (a `uv tool update` drops it). Explicit env still
  wins; `APC_ENABLED=0` / `MARV_MLX_APC=0` opts out.

### Changed
- **The pi extension was renamed `marv-mlx-sync.ts` → `marv-mlx.ts`.** The file
  is now `extensions/marv-mlx.ts` and `install.sh` copies it to
  `~/.pi/agent/extensions/marv-mlx.ts`. The slash commands (`/marv-mlx-sync`,
  `/marv-mlx-setup`) and everything else are unchanged. Existing installs get
  the new file on `pi update --extensions` / a re-run of `install.sh`; the old
  `marv-mlx-sync.ts` copy in `~/.pi/agent/extensions/` should be deleted once
  the new one is in place (pi will otherwise load both).
- **The curated catalog is bundled in this repo again.** `curated-llms.md`
  (formerly `marv-curator`'s `marv-curator.md`) now ships with marv-mlx, so the
  Download menu no longer fetches a list from a separate GitHub repo at startup
  — it works offline out of the box. `MARV_MLX_CATALOG` overrides the path. The
  legacy cache (`~/.cache/marv/mlx/curated-llms.md`) is still kept in sync for
  the sibling marv harness, which reads that path.
- **Quitting no longer force-stops running models.** The quit prompt is a
  three-way menu — *Stop all models & quit*, *Quit, leave models running*,
  *Cancel* — instead of a yes/no confirm. Choosing *leave models running*
  detaches the session's server PIDs (so the exit trap doesn't stop them) and
  the sign-off reports it: `models still running — 'marv-mlx stop --all' to stop
  them`. *Cancel* returns to the TUI.
- **Dropped the Homebrew formula/tap.** `pavsefcik/homebrew-marv-mlx` is
  archived; install with the curl one-liner or `pi install`. `make formula` and
  the `BREW`/`FORMULA` Makefile targets are gone.

## [0.136.3] - 2026-10-07

### Fixed
- **The migration re-creates the `ymlx` deprecation stub whenever a legacy
  install is detected** (old wrapper present, or `~/.cache/ymlx` still exists),
  so an interrupted earlier migration cannot leave the `ymlx` alias missing.

### Added
- **Migration test coverage** (`tests/test_migration.zsh`, wired into
  `make test`): state copy, config shim, narrow `~/.zshrc` rewrite (sibling
  launchers untouched), pi wrapper/extension handling, and idempotency.

## [0.136.2] - 2026-10-07

### Fixed
- **The state migration no longer rewrites unrelated `~/.zshrc` launcher
  lines.** v0.136.1's rewrite matched any `source "…launcher.zsh"` line, which
  could clobber sibling projects' launchers. It now only touches lines naming
  `ymlx-launcher.zsh` / `marv-mlx-launcher.zsh`, updates the path to this
  checkout, and is idempotent.

## [0.136.1] - 2026-10-07

### Deprecated
- **`ymlx`.** The installer and one-time migration now write a
  `~/.pi/agent/bin/ymlx` wrapper that warns and forwards to `marv-mlx`, so old
  scripts and muscle memory keep working for one release. Remove after the
  rename is fully absorbed. (The migration previously replaced the stale wrapper
  with nothing.)

## [0.136.0] - 2026-10-07

### Changed
- **Renamed `ymlx` → `marv-mlx`.** The runtime is now the backend layer of the
  MARV family (harness `marv`, runtime `marv-mlx`). All user-facing names,
  binaries, the pi package, the tap, and the state layout follow this plan:
  - command / repo / pi package: `ymlx` → `marv-mlx`
  - launcher: `marv-mlx-launcher.zsh`; entry function `marv-mlx()`
  - internals: `marv-mlx.zsh`, `lib/marv-mlx-helpers.zsh`, `lib/marv_mlx_repl.py`,
    `extensions/marv-mlx-sync.ts`; helpers `_marv_mlx_*`, globals `_MARV_MLX_*`
  - env namespace: every `YMLX_*` → `MARV_MLX_*`
  - state: `~/.cache/ymlx` → `~/.cache/marv/mlx`; install dir `~/.marv-mlx`;
    stable pi copy `~/.local/share/marv-mlx`; wrapper `~/.pi/agent/bin/marv-mlx`
  - Homebrew formula/tap: `Formula/marv-mlx.rb`, tap `pavsefcik/marv-mlx`
    (now dropped; the tap is archived)
  - curated catalog: `pavsefcik/marv-curator` (`marv-curator.md`) — now bundled
    here as `curated-llms.md`; the curator repo is archived
- **One-time state migration (`lib/marv-mlx-helpers.zsh`).** On first launch,
  `~/.cache/ymlx` is copied to `~/.cache/marv/mlx` (target-absent guard, never
  destructive), the managed-block markers and `YMLX_QUICK_*` names in
  `config.zsh` are rewritten, the `~/.zshrc` launcher line is updated, and the
  stale `ymlx` pi wrapper is replaced with a forwarding deprecation stub.
  Idempotent.

## [0.135.1] - 2026-10-06

### Fixed
- **No more stray blinking cursor in the TUI (`marv-mlx.zsh`).** Every key-driven
  list (main menu, Download menu, Chat history) now hides the terminal cursor
  while it paints and restores it in the matching clear path, so quitting the
  menu no longer leaves a blinking block parked on the blank line under the
  footer. Sub-screens (gum prompts, the chat REPL) still get a visible cursor.

## [0.135.0] - 2026-10-06

### Added
- **Command-line surface (`marv-mlx.zsh`).** marv-mlx now takes subcommands instead of
  only opening the TUI: `run`, `chat`, `stop [<model>|--all]`, `status`,
  `list`, `info`, `endpoint`, `download`, `curated`, `version` and `help`
  (`serve`/`curator`/`ls` are hidden aliases). Data goes to stdout and logs to
  stderr; `status`/`list`/`info`/`endpoint`/`curated` support `--json`. Exit
  codes are stable (0 ok, 1 failure, 2 usage). Verbs that don't need the
  Download menu skip the startup curated-list fetch, so they are fast and work
  offline; `curated` is the exception (it wants the list, falling back to the
  cache offline).
- **`marv-mlx curated`** (`marv-mlx.zsh`). Prints the whole curated catalog — every RAM
  tier, not just this machine's — with installed models marked. Titles, flags
  and tags are shown but the model id is authoritative, so it doubles as a
  copy-paste source for `marv-mlx download`.
- **Tests (`tests/test_cli.zsh`).** Hermetic CLI contract tests (throwaway HOME
  + stub tools); wired into `make test` alongside the helper tests.

### Changed
- **Clean, friendly exit (`marv-mlx.zsh`).** The TUI now runs on the alternate
  screen buffer (`?1049`), so quitting restores the previous shell screen
  instead of leaving the marv-mlx banner behind and wiping scrollback. It signs off
  at the top of a fresh screen with `▌▌ marv-mlx says bye!`
  (`… (stopped N running model(s))` appended when models were up), and the
  restore also runs from the EXIT/INT/TERM traps so Ctrl-C can't strand you on
  the alt screen.
- **One catalog parser (`lib/marv-mlx-helpers.zsh`).** `_marv_mlx_parse_catalog` now
  backs both the TUI Download menu and `marv-mlx curated`, so the two can't drift
  on the block format / `#`-comment stripping / paired ids.
- **New catalog format (`marv-curator`).** Entries are now blank-line-separated
  2-line blocks — model id, then a tagline — with no flags, titles or tag
  lines. There is no separate entry name: the model id **is** the name, and the
  tagline maps to the description. `marv-mlx curated` prints one aligned line per
  id (tagline and install tick in their own columns). Legacy 3-line
  title-first and id/tags blocks still parse, so an older cached copy keeps
  working.
- **Parser field delimiter is ASCII US, not tab (`lib/marv-mlx-helpers.zsh`).**
  zsh's `read` collapses repeated IFS *whitespace*, so a tab-delimited empty
  field (an entry with no tags) silently shifted every later field and the
  tagline showed up as tags. The internal records now use `\x1f` and carry the
  tier header line verbatim, which `marv-mlx curated` prints as-is instead of
  rebuilding "<n> GB RAM" from the tier number.
- **`stop` gained targets** (`marv-mlx stop <model>` / `--all`) alongside the
  original no-arg form, which still stops the model on `:11500`.

### Fixed
- **Tier headers no longer clobber the Download menu / `marv-mlx curated`
  (`marv-mlx.zsh`).** Both call sites still read the old 5-field parser record, so
  with the new 6-field record the tier header line landed in the "title" slot,
  the model id in "tags", and the tagline in "description" — the menu showed
  `16 GB RAM Tier Models  // ornith-ai/Ornith-1.5-9B-MLX-4bit`. They now consume
  the header field (the menu ignores it; `curated` prints it verbatim).

## [0.134.0] - 2026-10-02

### Changed
- **No more auto-update of mlx-vlm on interactive start (`marv-mlx.zsh`).** Dropped
  `_marv_mlx_check_mlx_vlm_update`, which ran `uv tool update mlx-vlm` whenever
  `uv tool list --outdated` reported a newer release. marv-mlx now runs whatever
  mlx-vlm version is installed; update it yourself with `uv tool update mlx-vlm`.

The marv-mlx self-update *notice* (`_marv_mlx_check_update`, interactive only) is
unchanged — it only prints when a new marv-mlx release exists, it never installs.

## [0.133.0] - 2026-10-01

### Changed
- **Leaner mlx-vlm tool env (`install.sh`).** New step 4b prunes the unused
  data-science stack (`datasets` → `pandas`/`pyarrow`, ~160 MB) from the
  mlx-vlm uv tool env. mlx-vlm 0.7.4 no longer hard-depends on `datasets` (it
  moved to the `train` extra), so a fresh install is already lean; this clears
  the dead weight left behind by older installs / `uv tool update` transitions.
  VLM/audio-facing deps (`opencv`/cv2, `scipy`, `mlx-audio`, `llguidance`) are
  deliberately kept: unlike text-only wren, marv-mlx serves vision and audio models.

## [0.132.3] - 2026-09-29

### Fixed
- **Installer reliability (`install.sh`).** Step 4 now pins `mlx-vlm@0.7.4`
  and installs with `--force`.
- **uv linking quirk.** Some `uv` versions (observably `0.12.19`) link only
  `mlx_vlm.convert`/`mlx_vlm.generate` and skip `mlx_vlm.server`. Step 4 now
  synthesizes a `mlx_vlm.server` shim from the tool environment
  (`python -m mlx_vlm.server`) when uv fails to link it, so the server command
  marv-mlx depends on is always available.

## [0.132.2] - 2026-09-29

### Fixed
- **Installer (`install.sh`).** Removed the invalid `--bin-dir` flag from the
  `uv tool install` invocation (not supported by `uv tool install`).

## [0.132.1] - 2026-09-29

### Changed / Fixed
- **Installer (`install.sh`).** Resolved where marv-mlx assumed uv puts tool shims.
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
- Fix broken `install.sh` wrapper (set -u exec gotcha); add `marv-mlx --version`
  (`-v`/`-V`) flag.

---

> Note: version history before `0.132.0` is not yet captured in this changelog.
> It was started retroactively from git history; earlier changes remain only in
> commit messages (`git log`).