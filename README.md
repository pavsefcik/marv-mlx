# marv-mlx

A small zsh launcher for browsing, running and downloading local MLX LLMs on
Apple Silicon, with a drop-in OpenAI-compatible REST endpoint at
`localhost:11500`.

**marv-mlx** is the runtime (backend) layer of the **MARV** family — *Modular
Agent Runtime Valve*. It manages models and serves them; the sibling
[marv](https://github.com/pavsefcik/marv) harness is the coding agent that talks
to them.

```
user ──► marv   (harness: agent loop · tools · sessions · TUI)
            │  OpenAI-compatible HTTP :11500 + lifecycle CLI
            ▼
         marv-mlx (runtime: catalog · download · run/swap · mlx_vlm.server)
            │
            ▼
         Hugging Face hub + Apple Silicon (MLX)
```

The harness is self-sufficient (it can launch `mlx_vlm.server` itself), so
`marv-mlx` is the *recommended* manager, not a hard runtime dependency. Both
layers read the same Hugging Face hub.

## Install

The repo ships as a [pi package](https://pi.dev/packages) — install [pi](https://pi.dev) once, then everything else comes from in-pi commands:

```sh
pi install git:github.com/pavsefcik/marv-mlx
```

Inside pi, run **`/marv-mlx-setup`** (auto-offered on first launch): it installs
`uv`, `gum` and `mlx-vlm` (Xcode CLT and Homebrew are the only manual steps),
copies `marv-mlx.zsh` to a stable directory, and wires a headless wrapper. Then
**`/marv-mlx-sync`** and pick a model via `/model` — it starts and switches marv-mlx to
the selected model automatically. Requires network for the first install (brew/
`uv`), then runs offline once models are cached.

Prefer `marv-mlx` standalone (no pi)? `git clone` the repo and run
`sh install.sh` — same deps, plus the pi extension and wrapper. It adds the
`marv-mlx-launcher.zsh` source line to `~/.zshrc`, so `marv-mlx` is available in
any new shell.

### Standalone — one line (curl)

Installs to `~/.marv-mlx` (`MARV_MLX_DIR` to override) and wires the launcher into `~/.zshrc`:

```sh
curl -fsSL https://raw.githubusercontent.com/pavsefcik/marv-mlx/main/install.sh | sh
```

Homebrew is not supported (the tap is archived) — use the curl one-liner above
or the repo checkout.

## Run

Run it from any terminal with:

```sh
marv-mlx
```

Quitting restores your previous screen (marv-mlx runs on the terminal's alternate
screen buffer) and signs off at the top of a fresh screen with an
`▌▌ marv-mlx says bye!` line.

## Commands

Besides the TUI, `marv-mlx` is a normal command-line tool with data on stdout and
logs on stderr, so it composes with scripts, agents and other programs.

```sh
marv-mlx                        # interactive TUI
marv-mlx run <model>            # start a model on :11500 (detached) and wait until ready
marv-mlx chat <model>           # start a model and open the built-in chat REPL
marv-mlx stop [<model>|--all]   # stop a model (default: the one on :11500)
marv-mlx status [--json]        # what is running
marv-mlx list [--json]          # locally installed models
marv-mlx download <model>...    # download model(s) from the HuggingFace Hub
marv-mlx curated [--json]       # the full curated catalog, all RAM tiers
marv-mlx info <model> [--json]  # size, family, thinking spec, path
marv-mlx endpoint [--json]      # base URL / model of the running server
marv-mlx version                # installed version
marv-mlx help                   # usage
```

Hidden aliases: `marv-mlx serve` = `run`, `marv-mlx curator` = `curated`,
`marv-mlx ls` = `list`.

Example — see what's running, then hit it:

```sh
marv-mlx status --json
# {"model":"mlx-community/Qwen3.5-4B-MLX-4bit","port":11500,"pid":12345,"base_url":"http://127.0.0.1:11500/v1"}

curl -s http://127.0.0.1:11500/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Qwen3.5-4B-MLX-4bit","messages":[{"role":"user","content":"hi"}]}'
```

Machine-readable output (`--json`) and a stable exit-code contract — `0` ok,
`1` failure, `2` usage error — make marv-mlx safe to drive from the `marv-mlx` pi
extension or your own tooling. Two edge cases are part of that contract:

- `status --json` when nothing is running prints `null` **and exits 1** (idle is
  treated as a non-zero status, not a failure) — the harness's
  `MarvMlxCli.status()` relies on this.
- `stop <model>` when that model is not running exits `1`, while `stop` (port
  11500) and `stop --all` exit `0` when already idle.

The headless subcommands (`run`/`stop`/`status`/`list`/`info`/`endpoint`/
`download`/`curated`/`version`/`help`) clear their signal traps so they compose
from scripts; only `chat` keeps them. `run` disowns the server and polls for
readiness for up to ~20 minutes. Headless always uses `:11500`; the parallel
ports `11500–11509` are a TUI-only feature.

## Use

- Start model and run — Enter starts the highlighted model and drops straight
  into chat. If another model is already running, marv-mlx asks **Yes** (swap:
  stop it and run the selected one on `:11500`), **No**, or **Run in parallel**
  (keep both, the new one on the next free port). Multiple models can run at
  once; each shows a `●` in the menu, and `^s` stops the highlighted one.
- Thinking is off by default; `tab` turns it on and the reasoning trace then
  shows in grey above the answer. Each family is handled natively (Qwen/Gemma
  via their templates, Ministral via its Instruct/Reasoning pair). `esc` stops
  an answer mid-stream, and a lone `esc` at the chat prompt returns to the menu
  (the server keeps running) · `^s` stops server
- Status/confirm screens auto-continue instead of asking "press enter to continue".
- **Chat history** records every chat; open it from the menu and **enter** a chat
  for actions: resume (continue the thread), copy to clipboard, rename, or
  delete permanently. `^d` deletes the highlighted chat at a keystroke; `esc`
  returns. `s` or
  `/` searches across all chats, `o` opens the chat folder. Deleted chats are
  gone for good (no trash).
- Download from the bundled curated list (filtered to your RAM tier) or paste
  any HuggingFace id
- Ministral models are shipped as Instruct+Reasoning pairs: downloading a
  Ministral entry fetches both halves, the menu shows a single
  `Ministral-3-xB-4bit` entry, and `tab` swaps between the Instruct and
  Reasoning version (never both at once)
- Drop-in OpenAI endpoint for other apps — from the **Use from another app**
  screen: base URL `http://localhost:11500/v1`, model = HF id of the running
  model, API key not required

## Configuration

**Basic settings** — thinking (default/on/off), temperature, max tokens, system
prompt. **Advanced settings** — every `mlx_vlm` flag (`--kv-bits`,
`--draft-model`, adapters, extra model slots, …). Everything persists in
`~/.cache/marv/mlx/config.zsh`.

## Updates

marv-mlx checks GitHub for a newer version at every interactive (TUI) launch;
when one exists a
`▲ Update available: X.Y.Z → A.B.C` banner appears and the menu gains an
**Update to latest version** entry that pulls and reinstalls in place (a
pi-managed install instead guides you to `pi update`; a curl/managed copy is
refreshed from GitHub automatically). Installed version lives
in the repo-root `VERSION` file (semver, currently 0.136.3).
