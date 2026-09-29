#!/bin/sh
# ymlx installer — a single script, three ways to run it:
#
#   1. One line, from any directory:
#        curl -fsSL https://raw.githubusercontent.com/pavsefcik/ymlx/main/install.sh | sh
#
#   2. From a git clone / checkout:
#        git clone https://github.com/pavsefcik/ymlx && sh ymlx/install.sh
#
#   3. From a brew-installed copy (one-off runtime setup):
#        sh "$(brew --prefix)/opt/ymlx/libexec/install.sh"
#
# It installs the tools ymlx needs (uv and gum via Homebrew, mlx-vlm as a uv
# tool), materializes the repo into a stable directory when it isn't already a
# checkout, wires the pi extension + wrapper, and sources the `ymlx` launcher
# from ~/.zshrc.
#
# Safe to re-run: each step skips what's already present, and the mlx-vlm step
# re-installs with jinja2 so a prior install that lacked it gets repaired.
#
# Environment:
#   YMLX_DIR   install directory when no checkout is available (default $HOME/.ymlx)
#   YMLX_REF   git ref to fetch (default: latest release tag, else main)
#   YMLX_FORCE re-download the source even if ymlx.zsh already exists. The in-app
#              "Update to latest version" uses this to refresh non-git managed
#              copies (which otherwise wouldn't be updated by a plain re-run).

set -e

step() { printf '\n==> %s\n' "$1"; }
says() { printf '    %s\n' "$1"; }
die()  { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# ---- Resolve the ymlx source/working directory ------------------------------
# If we're running from a real script that sits next to ymlx.zsh (a clone or a
# brew libexec), use that dir so the paths baked into the launcher/wrapper are
# stable. Otherwise (piped via curl, no checkout present) materialize a copy
# into $YMLX_DIR.
self_dir="$(dirname "$0" 2>/dev/null)"
if [ -n "$self_dir" ] && [ -f "$self_dir/ymlx.zsh" ]; then
  repo_dir="$(cd "$self_dir" && pwd)"
else
  repo_dir="${YMLX_DIR:-$HOME/.ymlx}"
fi

# Fetch a copy if the resolved dir has no ymlx.zsh yet, or when YMLX_FORCE=1
# (in-app update for managed copies) forces a refresh from GitHub.
if [ ! -f "$repo_dir/ymlx.zsh" ] || [ "$YMLX_FORCE" = "1" ]; then
  step "Downloading ymlx into $repo_dir …"
  mkdir -p "$repo_dir"
  ref="${YMLX_REF:-}"
  if [ -z "$ref" ]; then
    ref="$(curl -fsSL "https://api.github.com/repos/pavsefcik/ymlx/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$ref" ] || ref="main"
  fi
  if [ "$ref" = "main" ]; then
    url="https://github.com/pavsefcik/ymlx/archive/refs/heads/main.tar.gz"
  else
    url="https://github.com/pavsefcik/ymlx/archive/refs/tags/$ref.tar.gz"
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ymlx.XXXXXX")"
  curl -fsSL "$url" -o "$tmp/src.tar.gz"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp"
  sub="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  cp -R "$sub/." "$repo_dir/"
  rm -rf "$tmp"
  says "downloaded @ $ref ($repo_dir)"
fi

# ---- 1. Xcode Command Line Tools --------------------------------------------
step "Checking Xcode Command Line Tools…"
if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode CLT not installed. Run 'xcode-select --install' (GUI prompt), then re-run this script."
else
  says "present ($(xcode-select -p))"
fi

# ---- 2. Homebrew ------------------------------------------------------------
step "Checking Homebrew…"
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew missing — install it:
    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
  then re-run this script."
else
  says "present ($(brew --version | head -n1))"
fi

# ---- 3. uv + gum via brew (no-op if already installed) ----------------------
step "Installing uv and gum…"
brew list uv >/dev/null 2>&1 || brew install uv
brew list gum >/dev/null 2>&1 || brew install gum
command -v uv >/dev/null 2>&1 || die "uv not on PATH after install — re-run this script in a new terminal."
command -v gum >/dev/null 2>&1 || die "gum not on PATH after install — re-run this script in a new terminal."
says "uv $(uv --version | awk '{print $2}'), gum installed"

# ---- 4. mlx-vlm as a uv tool -------------------------------------------------
# setproctitle lets ymlx rename the running server to the model name in
# Activity Monitor / ps (see lib/sitecustomize.py).
step "Installing mlx-vlm (with jinja2 + setproctitle)…"
# Resolve uv's tool + bin dirs up front (reused by step 5). We deliberately do
# NOT pin uv to ~/.local/bin — its dirs are configurable (UV_TOOL_BIN_DIR,
# XDG_BIN_HOME, XDG_DATA_HOME) and depend on how uv was installed — so we ask
# uv where it will place things and wire that into PATH later. Pin the package
# version for reproducible resolver behavior.
UV_TOOL_BIN="$(uv tool dir --bin 2>/dev/null || printf '%s/.local/bin' "$HOME")"
UV_TOOL_DIR="$(uv tool dir 2>/dev/null || printf '%s/.local/share/uv/tools' "$HOME")"
install_mlx_vlm() {
  uv tool install "mlx-vlm@0.7.4" --with jinja2 --with setproctitle --force
}
# The mlx-vlm tool is large and network-bound; retry a couple of times before
# giving up.
attempt=0
while ! install_mlx_vlm; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 3 ]; then
    die "uv tool install mlx-vlm failed after $attempt attempts."
  fi
  says "mlx-vlm install failed — retrying (attempt $attempt)…"
done
# uv occasionally fails to link every console script (a uv linking/cleanup quirk)
# — we've seen it link only convert+generate and skip mlx_vlm.server. ymlx needs
# `mlx_vlm.server`, so synthesize it from the tool env if uv didn't link it.
if ! [ -x "$UV_TOOL_BIN/mlx_vlm.server" ] && ! command -v mlx_vlm.server >/dev/null 2>&1; then
  mkdir -p "$UV_TOOL_BIN"
  cat > "$UV_TOOL_BIN/mlx_vlm.server" <<SHIM
#!/usr/bin/env bash
# ymlx fallback shim — uv didn't link mlx_vlm.server; run the tool env module.
exec "$UV_TOOL_DIR/mlx-vlm/bin/python" -m mlx_vlm.server "\$@"
SHIM
  chmod +x "$UV_TOOL_BIN/mlx_vlm.server"
  says "created mlx_vlm.server shim in $UV_TOOL_BIN (uv did not link it)"
fi
# Verify the server command is usable after install.
command -v mlx_vlm.server >/dev/null 2>&1 || [ -x "$UV_TOOL_BIN/mlx_vlm.server" ] || \
  die "mlx_vlm.server is not available after install (expected at $UV_TOOL_BIN)."

# ---- 5. Make sure uv's tool bin dir is on PATH ------------------------------------
# Don't assume ~/.local/bin: uv's tool executable dir is configurable (UV_TOOL_BIN_DIR,
# XDG_BIN_HOME, XDG_DATA_HOME) and defaults to the first resolution on that list before
# ~/.local/bin. Ask uv where it really installs tool scripts.
step "Checking PATH…"
# UV_TOOL_BIN was already resolved in step 4 (before the mlx-vlm install).
if ! command -v mlx_vlm.server >/dev/null 2>&1; then
  if [ -f "$UV_TOOL_BIN/mlx_vlm.server" ]; then
    if ! printf '%s' "$PATH" | grep -qF "$UV_TOOL_BIN"; then
      if ! grep -qF "$UV_TOOL_BIN" "$HOME/.zshrc" 2>/dev/null; then
        printf 'export PATH="%s:$PATH"\n' "$UV_TOOL_BIN" >> "$HOME/.zshrc"
        says "appended $UV_TOOL_BIN to ~/.zshrc"
      fi
    fi
    says "mlx_vlm.server found at $UV_TOOL_BIN — open a new terminal before running ymlx."
  else
    die "mlx_vlm.server is not on PATH and not at $UV_TOOL_BIN — something went wrong (uv tool dir --bin = $UV_TOOL_BIN)."
  fi
else
  says "mlx_vlm.server on PATH ✓"
fi

# ---- 6. Final verification ---------------------------------------------------
step "Verifying…"
ok=1
for c in gum uv mlx_vlm.server; do
  command -v "$c" >/dev/null 2>&1 || { says "MISSING: $c"; ok=0; }
done
[ "$ok" -eq 1 ] && says "all tools present ✓"

# ---- 7. pi integration — extension + wrapper ---------------------------------
step "Installing pi extension + wrapper…"
mkdir -p "$HOME/.pi/agent/extensions" "$HOME/.pi/agent/bin"
if [ -f "$repo_dir/extensions/ymlx-sync.ts" ]; then
  cp -f "$repo_dir/extensions/ymlx-sync.ts" "$HOME/.pi/agent/extensions/ymlx-sync.ts"
  says "extension -> ~/.pi/agent/extensions/ymlx-sync.ts"
else
  says "SKIP: extensions/ymlx-sync.ts not found — is this a full checkout of the repo?"
fi
cat > "$HOME/.pi/agent/bin/ymlx" <<EOF_YMLX
#!/usr/bin/env bash
# Generated by ymlx/install.sh — points at ymlx.zsh in $repo_dir.
set -euo pipefail
YMLX_ZSH="$repo_dir/ymlx.zsh"
exec zsh "\$YMLX_ZSH" "\$@"
EOF_YMLX
chmod +x "$HOME/.pi/agent/bin/ymlx"
says "wrapper -> ~/.pi/agent/bin/ymlx (points at $repo_dir/ymlx.zsh)"
if command -v pi >/dev/null 2>&1; then
  says "pi found — run /reload inside pi to activate ymlx-sync (or /ymlx-setup to repair)"
else
  says "pi not found — install it with: npm i -g @earendil-works/pi-coding-agent"
fi

# ---- 8. Wire the launcher into ~/.zshrc (idempotent) -------------------------
step "Wiring ymlx into ~/.zshrc …"
if ! grep -q 'ymlx-launcher.zsh' "$HOME/.zshrc" 2>/dev/null; then
  {
    printf '\n# ymlx (installed by install.sh)\n'
    printf 'test -f "%s/ymlx-launcher.zsh" && source "%s/ymlx-launcher.zsh"\n' "$repo_dir" "$repo_dir"
  } >> "$HOME/.zshrc"
  says "appended launcher source to ~/.zshrc"
else
  says "launcher already wired"
fi

step "Done. ymlx is installed in $repo_dir"
says "Open a NEW terminal (or run: source ~/.zshrc), then type: ymlx"