# ymlx

A small zsh launcher for browsing, running and downloading local MLX LLMs on
Apple Silicon, with a drop-in OpenAI-compatible REST endpoint at
`localhost:11500`.

## Install

The repo ships as a [pi package](https://pi.dev/packages) — install [pi](https://pi.dev) once, then everything else comes from in-pi commands:

```sh
pi install git:github.com/pavsefcik/ymlx
```

Inside pi, run **`/ymlx-setup`** (auto-offered on first launch): it installs
`uv`, `gum` and `mlx-vlm` (Xcode CLT and Homebrew are the only manual steps),
copies `ymlx.zsh` to a stable directory, and wires a headless wrapper. Then
**`/ymlx-sync`** and pick a model via `/model` — it starts and switches ymlx to
the selected model automatically, all offline.

Prefer ymlx standalone (no pi)? `git clone` the repo and run `sh install.sh`
— same deps, plus the pi extension and wrapper. It adds the
`ymlx-launcher.zsh` source line to `~/.zshrc`, so `ymlx` is available in any
new shell.

### Standalone — one line (curl)

Installs to `~/.ymlx` (`YMLX_DIR` to override) and wires the launcher into `~/.zshrc`:

```sh
curl -fsSL https://raw.githubusercontent.com/pavsefcik/ymlx/main/install.sh | sh
```

### Standalone — Homebrew (tap)

```sh
brew install pavsefcik/ymlx/ymlx
```

One line on any Homebrew version. Homebrew ≥ 6 auto-trusts exactly this
formula on a fully-qualified install, so there's no separate tap/trust step.
For the shorter `ymlx` name (tapped + trusted):

```sh
brew trust pavsefcik/ymlx   # Homebrew 6+ only: taps are executable Ruby, so they need explicit trust
brew tap pavsefcik/ymlx
brew install ymlx
```

The formula brings `gum` + `uv`; run
`sh "$(brew --prefix)/opt/ymlx/libexec/install.sh"` once — it installs the
`mlx-vlm` tool and adds the launcher to `~/.zshrc`. Then open a new terminal
and run `ymlx`.

## Run

Run it from any terminal with:

```sh
ymlx
```

## Use

- Start model and run — Enter starts the highlighted model and drops straight
  into chat. If another model is already running, ymlx asks **Yes** (swap:
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
- Download from a curated list ([ymlx-curator](https://github.com/pavsefcik/ymlx-curator),
  filtered to your RAM tier) or paste any HuggingFace id
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
`~/.cache/ymlx/config.zsh`.

## Updates

ymlx checks GitHub for a newer version at every launch; when one exists a
`▲ Update available: X.Y.Z → A.B.C` banner appears and the menu gains an
**Update to latest version** entry that pulls and reinstalls in place (a
pi-managed install instead guides you to `pi update`; a curl/managed copy is
refreshed from GitHub automatically). Installed version lives
in the repo-root `VERSION` file (semver, currently 0.131.0).
