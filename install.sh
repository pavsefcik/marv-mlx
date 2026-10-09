#!/bin/sh
# marv-mlx installer — a single script, three ways to run it:
#
#   1. One line, from any directory:
#        curl -fsSL https://raw.githubusercontent.com/pavsefcik/marv-mlx/main/install.sh | sh
#
#   2. From a git clone / checkout:
#        git clone https://github.com/pavsefcik/marv-mlx && sh marv-mlx/install.sh
#
# It installs the tools marv-mlx needs (uv and gum via Homebrew, mlx-vlm as a uv
# tool), materializes the repo into a stable directory when it isn't already a
# checkout, wires the pi extension + wrapper, and sources the `marv-mlx` launcher
# from ~/.zshrc.
#
# Safe to re-run: each step skips what's already present, and the mlx-vlm step
# re-installs with jinja2 so a prior install that lacked it gets repaired.
#
# Environment:
#   MARV_MLX_DIR   install directory when no checkout is available (default $HOME/.marv-mlx)
#   MARV_MLX_REF   git ref to fetch (default: latest release tag, else main)
#   MARV_MLX_FORCE re-download the source even if marv-mlx.zsh already exists. The in-app
#              "Update to latest version" uses this to refresh non-git managed
#              copies (which otherwise wouldn't be updated by a plain re-run).

set -e

step() { printf '\n==> %s\n' "$1"; }
says() { printf '    %s\n' "$1"; }
die()  { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# ---- Resolve the marv-mlx source/working directory ------------------------------
# If we're running from a real script that sits next to marv-mlx.zsh (a clone),
# use that dir so the paths baked into the launcher/wrapper are stable.
# Otherwise (piped via curl, no checkout present) materialize a copy
# into $MARV_MLX_DIR.
self_dir="$(dirname "$0" 2>/dev/null)"
if [ -n "$self_dir" ] && [ -f "$self_dir/marv-mlx.zsh" ]; then
  repo_dir="$(cd "$self_dir" && pwd)"
else
  repo_dir="${MARV_MLX_DIR:-$HOME/.marv-mlx}"
fi

# Fetch a copy if the resolved dir has no marv-mlx.zsh yet, or when MARV_MLX_FORCE=1
# (in-app update for managed copies) forces a refresh from GitHub.
if [ ! -f "$repo_dir/marv-mlx.zsh" ] || [ "$MARV_MLX_FORCE" = "1" ]; then
  step "Downloading marv-mlx into $repo_dir …"
  mkdir -p "$repo_dir"
  ref="${MARV_MLX_REF:-}"
  if [ -z "$ref" ]; then
    ref="$(curl -fsSL "https://api.github.com/repos/pavsefcik/marv-mlx/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$ref" ] || ref="main"
  fi
  if [ "$ref" = "main" ]; then
    url="https://github.com/pavsefcik/marv-mlx/archive/refs/heads/main.tar.gz"
  else
    url="https://github.com/pavsefcik/marv-mlx/archive/refs/tags/$ref.tar.gz"
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/marv-mlx.XXXXXX")"
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
# setproctitle lets marv-mlx rename the running server to the model name in
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
# — we've seen it link only convert+generate and skip mlx_vlm.server. marv-mlx needs
# `mlx_vlm.server`, so synthesize it from the tool env if uv didn't link it.
if ! [ -x "$UV_TOOL_BIN/mlx_vlm.server" ] && ! command -v mlx_vlm.server >/dev/null 2>&1; then
  mkdir -p "$UV_TOOL_BIN"
  cat > "$UV_TOOL_BIN/mlx_vlm.server" <<SHIM
#!/usr/bin/env bash
# marv-mlx fallback shim — uv didn't link mlx_vlm.server; run the tool env module.
exec "$UV_TOOL_DIR/mlx-vlm/bin/python" -m mlx_vlm.server "\$@"
SHIM
  chmod +x "$UV_TOOL_BIN/mlx_vlm.server"
  says "created mlx_vlm.server shim in $UV_TOOL_BIN (uv did not link it)"
fi
# Verify the server command is usable after install.
command -v mlx_vlm.server >/dev/null 2>&1 || [ -x "$UV_TOOL_BIN/mlx_vlm.server" ] || \
  die "mlx_vlm.server is not available after install (expected at $UV_TOOL_BIN)."

# --- 4b. Prune unused heavy deps (keep the tool env lean) ----------------------
# Older mlx-vlm releases listed `datasets` (-> pandas/pyarrow, ~160MB) as an
# unconditional dep. 0.7.4 moved it to the `train` extra, but a `uv tool update`
# from such an older install (or any stale/extra'd env) can leave that
# data-science weight behind. wren-style, strip it — it is never used at
# inference/server runtime. We deliberately KEEP opencv/cv2, scipy and mlx-audio:
# unlike text-only wren, marv-mlx serves VLM/audio/grammar models that depend on them.
prune_tool_bloat() {
  local py="$UV_TOOL_DIR/mlx-vlm/bin/python"
  [ -x "$py" ] || return 0
  uv pip uninstall --python "$py" -q datasets pandas pyarrow 2>/dev/null || true
}
prune_tool_bloat
says "pruned unused data-science deps (datasets/pandas/pyarrow)"

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
    says "mlx_vlm.server found at $UV_TOOL_BIN — open a new terminal before running marv-mlx."
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
if [ -f "$repo_dir/extensions/marv-mlx-sync.ts" ]; then
  cp -f "$repo_dir/extensions/marv-mlx-sync.ts" "$HOME/.pi/agent/extensions/marv-mlx-sync.ts"
  says "extension -> ~/.pi/agent/extensions/marv-mlx-sync.ts"
else
  says "SKIP: extensions/marv-mlx-sync.ts not found — is this a full checkout of the repo?"
fi
cat > "$HOME/.pi/agent/bin/marv-mlx" <<EOF_MARV_MLX
#!/usr/bin/env bash
# Generated by marv-mlx/install.sh — points at marv-mlx.zsh in $repo_dir.
set -euo pipefail
MARV_MLX_ZSH="$repo_dir/marv-mlx.zsh"
exec zsh "\$MARV_MLX_ZSH" "\$@"
EOF_MARV_MLX
chmod +x "$HOME/.pi/agent/bin/marv-mlx"
says "wrapper -> ~/.pi/agent/bin/marv-mlx (points at $repo_dir/marv-mlx.zsh)"
# Deprecation stub: the old `ymlx` command still works for one release, but
# says so loudly and forwards to marv-mlx. Remove after the rename is absorbed.
cat > "$HOME/.pi/agent/bin/ymlx" <<'EOF_YMLX'
#!/usr/bin/env bash
# Generated by marv-mlx/install.sh — deprecated alias for marv-mlx.
echo "ymlx has been renamed to marv-mlx; run 'marv-mlx' instead." >&2
exec marv-mlx "$@"
EOF_YMLX
chmod +x "$HOME/.pi/agent/bin/ymlx"
says "deprecation stub -> ~/.pi/agent/bin/ymlx (forwards to marv-mlx)"
if command -v pi >/dev/null 2>&1; then
  says "pi found — run /reload inside pi to activate marv-mlx-sync (or /marv-mlx-setup to repair)"
else
  says "pi not found — install it with: npm i -g @earendil-works/pi-coding-agent"
fi

# ---- 8. Wire the launcher into ~/.zshrc (idempotent) -------------------------
step "Wiring marv-mlx into ~/.zshrc …"
if ! grep -q 'marv-mlx-launcher.zsh' "$HOME/.zshrc" 2>/dev/null; then
  {
    printf '\n# marv-mlx (installed by install.sh)\n'
    printf 'test -f "%s/marv-mlx-launcher.zsh" && source "%s/marv-mlx-launcher.zsh"\n' "$repo_dir" "$repo_dir"
  } >> "$HOME/.zshrc"
  says "appended launcher source to ~/.zshrc"
else
  says "launcher already wired"
fi

step "Done. marv-mlx is installed in $repo_dir"
says "Open a NEW terminal (or run: source ~/.zshrc), then type: marv-mlx"