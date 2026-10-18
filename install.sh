#!/bin/sh
# marv-mlx installer — a single script, three ways to run it:
#
#   1. One line, from any directory:
#        curl -fsSL https://raw.githubusercontent.com/pavsefcik/marv-mlx/main/install.sh | sh
#
#   2. One line, and grab a model on the way out:
#        curl -fsSL .../install.sh | sh -s -- --model mlx-community/Qwen3.5-4B-MLX-4bit
#
#   3. From a git clone / checkout:
#        git clone https://github.com/pavsefcik/marv-mlx && sh marv-mlx/install.sh
#
# No Xcode Command Line Tools and no Homebrew required. It installs the tools
# marv-mlx needs the same way a curl install expects to work: uv from Astral's
# standalone installer, gum from its signed-off GitHub release binary (sha256
# checked), mlx-vlm as a uv tool. Anything already present on PATH (uv, gum,
# brew) is reused, never reinstalled.
#
# It also materializes the repo into a stable directory when it isn't already a
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
#   MARV_MLX_MODEL  model id(s) to download instead of passing --model (space/comma separated)
#   MARV_SKIP_HARDWARE_CHECK=1
#              skip the Apple Silicon / macOS preflight
#   MARV_NO_ZSH=1  do not modify ~/.zshrc
#   MARV_MLX_DRY_RUN=1
#              preflight and print the plan without installing anything
#
# Flags:
#   --model <id>   download a model after installing (repeatable)
#   --dry-run      print the plan without changing anything
#   --no-zsh       do not touch ~/.zshrc
#   --help

set -e

step() { printf '\n==> %s\n' "$1"; }
says() { printf '    %s\n' "$1"; }
warn() { printf '    ! %s\n' "$1"; }
die()  { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# Run a mutating command, or print it under a dry run.
run() {
  if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

usage() {
  sed -n '2,44p' "$0" 2>/dev/null | sed -n 's/^# \{0,1\}//p' || \
    printf 'usage: install.sh [--model <id>]... [--dry-run] [--no-zsh]\n'
}

# ---- Args → env --------------------------------------------------------------
models="${MARV_MLX_MODEL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      [ $# -ge 2 ] || die "--model needs a model id"
      models="$models $2"; shift 2 ;;
    --model=*) models="$models ${1#*=}"; shift ;;
    --dry-run) MARV_MLX_DRY_RUN=1; shift ;;
    --no-zsh)  MARV_NO_ZSH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
export MARV_MLX_DRY_RUN MARV_NO_ZSH

# ---- PATH helpers ------------------------------------------------------------
# uv and gum both land in the user's bin dir (no brew involved). Put it on PATH
# for the rest of this script, and later for the user's shells.
LOCAL_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
path_add() {
  case ":$PATH:" in
    *":$1:"*) : ;;
    *) PATH="$1:$PATH"; export PATH ;;
  esac
}
path_add "$LOCAL_BIN"

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
  if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
    says "[dry-run] fetch the latest release tarball into $repo_dir"
  else
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
fi

# ---- 1. Hardware preflight ---------------------------------------------------
# MLX is Apple-Silicon-only, and the gum release binary below is Darwin/arm64.
# Fail here, early, instead of halfway through a tool install.
# ver_ge A B -> success when A >= B (dot-separated numeric versions).
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) {
      xi = (i <= na ? x[i] + 0 : 0)
      yi = (i <= nb ? y[i] + 0 : 0)
      if (xi > yi) exit 0
      if (xi < yi) exit 1
    }
    exit 0
  }'
}

step "Checking hardware (Apple Silicon / MLX)…"
if [ "${MARV_SKIP_HARDWARE_CHECK:-0}" = "1" ]; then
  says "skipped (MARV_SKIP_HARDWARE_CHECK=1)"
else
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || die \
    "marv-mlx targets macOS — this system is $(uname -s). Set MARV_SKIP_HARDWARE_CHECK=1 to install anyway (the runtime still needs Apple Silicon to serve models)."

  arch="$(uname -m 2>/dev/null)"
  [ "$arch" = "arm64" ] || die \
    "MLX needs an Apple Silicon Mac (M-series); this machine reports '$arch'. Set MARV_SKIP_HARDWARE_CHECK=1 to install anyway."

  osver="$(sw_vers -productVersion 2>/dev/null)"
  [ -n "$osver" ] || die "Could not read the macOS version (sw_vers)."
  ver_ge "$osver" "14.0" || die \
    "macOS $osver is too old — MLX requires macOS 14.0 (Sonoma) or later. Upgrade and re-run."

  mem_bytes="$(sysctl -n hw.memsize 2>/dev/null)"
  if [ -n "$mem_bytes" ]; then
    mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
    says "Apple Silicon — macOS $osver, ${mem_gb} GB unified memory"
    [ "$mem_gb" -ge 16 ] || warn "16 GB is recommended; ${mem_gb} GB can only run small models comfortably."
  else
    says "Apple Silicon — macOS $osver"
  fi
fi

# ---- 2. uv (standalone binary; reused when already present) ------------------
step "Installing uv…"
if command -v uv >/dev/null 2>&1; then
  says "present ($(uv --version | head -n1))"
elif [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh"
else
  # Astral's installer drops a prebuilt binary — no compiler, no CLT, no brew.
  # We set UV_NO_MODIFY_PATH so PATH wiring stays in this script (one line in
  # ~/.zshrc, next to the uv tool bin dir) instead of two competing ones.
  if curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh; then
    path_add "$LOCAL_BIN"
    # The installer still uses ~/.cargo/bin when that legacy dir exists.
    if [ -x "$HOME/.cargo/bin/uv" ]; then
      path_add "$HOME/.cargo/bin"
    fi
    command -v uv >/dev/null 2>&1 || die \
      "uv installed but not on PATH (looked in $LOCAL_BIN and ~/.cargo/bin) — open a new terminal and re-run."
    says "installed $(uv --version | head -n1)"
  elif command -v brew >/dev/null 2>&1; then
    says "standalone install failed — falling back to Homebrew"
    run brew install uv || die "brew install uv failed."
  else
    die "uv install failed — install it by hand (https://docs.astral.sh/uv/getting-started/installation/) and re-run."
  fi
fi
command -v uv >/dev/null 2>&1 || die \
  "uv is not on PATH — open a new terminal and re-run this script."

# ---- 3. gum (release binary + sha256; reused when already present) -----------
# gum is what the TUI is built out of, and it is a standalone Go binary — there
# is no reason to drag Homebrew (and Xcode CLT) in for it.
GUM_VERSION="2.0.2"
GUM_SHA256="4777a69b1170b8db23c95d5889fb32186cfda1a3ac950d339aa17e3513633890"

gum_release_install() {
  _url="https://github.com/charmbracelet/gum/releases/download/v$GUM_VERSION/gum_${GUM_VERSION}_Darwin_arm64.tar.gz"
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/marv-mlx-gum.XXXXXX")" || return 1
  if ! curl -fsSL "$_url" -o "$_tmp/gum.tar.gz"; then
    rm -rf "$_tmp"; return 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    _got="$(shasum -a 256 "$_tmp/gum.tar.gz" | awk '{print $1}')"
  else
    _got="$(sha256sum "$_tmp/gum.tar.gz" | awk '{print $1}')"
  fi
  if [ "$_got" != "$GUM_SHA256" ]; then
    rm -rf "$_tmp"
    die "gum checksum mismatch (got $_got, want $GUM_SHA256) — refusing to install."
  fi
  if ! tar -xzf "$_tmp/gum.tar.gz" -C "$_tmp"; then
    rm -rf "$_tmp"; return 1
  fi
  _bin="$(find "$_tmp" -type f -name gum 2>/dev/null | head -n1)"
  if [ -z "$_bin" ]; then
    rm -rf "$_tmp"; return 1
  fi
  mkdir -p "$LOCAL_BIN" || { rm -rf "$_tmp"; return 1; }
  if ! cp -f "$_bin" "$LOCAL_BIN/gum"; then
    rm -rf "$_tmp"; return 1
  fi
  chmod 755 "$LOCAL_BIN/gum"
  rm -rf "$_tmp"
  return 0
}

step "Installing gum…"
if command -v gum >/dev/null 2>&1; then
  says "present ($(gum --version 2>/dev/null | head -n1))"
elif [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] download gum $GUM_VERSION (Darwin/arm64, sha256 verified) -> $LOCAL_BIN/gum"
else
  if gum_release_install; then
    says "installed $GUM_VERSION -> $LOCAL_BIN/gum (sha256 verified)"
  elif command -v brew >/dev/null 2>&1; then
    says "release download failed — falling back to Homebrew"
    run brew install gum || die "brew install gum failed."
  else
    die "could not download the gum release binary — check your network and re-run (or install gum yourself and re-run)."
  fi
  path_add "$LOCAL_BIN"
  command -v gum >/dev/null 2>&1 || die \
    "gum is not on PATH after install (expected at $LOCAL_BIN/gum) — open a new terminal and re-run."
fi

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
if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] uv tool install mlx-vlm@0.7.4 --with jinja2 --with setproctitle --force"
else
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
fi

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
if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] prune datasets/pandas/pyarrow from the mlx-vlm tool env"
else
  prune_tool_bloat
  says "pruned unused data-science deps (datasets/pandas/pyarrow)"
fi

# --- 4c. APC sitecustomize (prefix caching ON for any launcher) ----------------
# mlx-vlm 0.7.4 ships Automatic Prefix Caching (APC) but leaves it off by
# default, and mlx_vlm.server has no CLI flag for it — the environment is the
# only switch. marv-mlx exports the APC_* env for its own launches; this
# additionally defaults it on INSIDE the tool env (sitecustomize.py runs at
# interpreter startup) so servers launched by other tools — the marv
# harness's embedded launch, a manual mlx_vlm.server call — also get prefix
# caching. setdefault semantics: explicit APC_ENABLED=0 / MARV_MLX_APC=0 wins.
apc_src="$repo_dir/lib/marv-mlx-apc-sitecustomize.py"
if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] install the APC sitecustomize into the mlx-vlm tool env"
elif [ -r "$apc_src" ]; then
  for sp in "$UV_TOOL_DIR"/mlx-vlm/lib/python*/site-packages; do
    [ -d "$sp" ] || continue
    if [ -f "$sp/sitecustomize.py" ] \
       && ! grep -q "marv-mlx APC sitecustomize" "$sp/sitecustomize.py" 2>/dev/null; then
      says "foreign sitecustomize.py in $sp — left untouched (APC defaults not installed)"
      continue
    fi
    if ! cmp -s "$apc_src" "$sp/sitecustomize.py" 2>/dev/null; then
      cp -f "$apc_src" "$sp/sitecustomize.py" \
        || die "could not write $sp/sitecustomize.py"
      says "APC sitecustomize installed in $sp (prefix caching on for any launcher)"
    fi
  done
fi

# ---- 5. Make sure uv's bin dirs are on PATH ----------------------------------
# Don't assume ~/.local/bin: uv's tool executable dir is configurable (UV_TOOL_BIN_DIR,
# XDG_BIN_HOME, XDG_DATA_HOME) and defaults to the first resolution on that list before
# ~/.local/bin. Ask uv where it really installs tool scripts.
step "Checking PATH…"
# UV_TOOL_BIN was already resolved in step 4 (before the mlx-vlm install).
if ! command -v mlx_vlm.server >/dev/null 2>&1; then
  if [ -f "$UV_TOOL_BIN/mlx_vlm.server" ]; then
    path_add "$UV_TOOL_BIN"
    says "mlx_vlm.server found at $UV_TOOL_BIN — open a new terminal before running marv-mlx."
  else
    die "mlx_vlm.server is not on PATH and not at $UV_TOOL_BIN — something went wrong (uv tool dir --bin = $UV_TOOL_BIN)."
  fi
else
  says "mlx_vlm.server on PATH ✓"
fi

# Both `uv` itself and `gum` live in LOCAL_BIN; the uv tool shims may live
# elsewhere. Write one guarded line per dir so new shells see all of it (uv's own
# installer is told not to touch shell rc files, so this is the only writer).
wire_zsh_path() {
  _dir="$1"
  if [ "${MARV_NO_ZSH:-0}" = "1" ]; then
    says "skipped ~/.zshrc (MARV_NO_ZSH=1) — add: export PATH=\"$_dir:\$PATH\""
  elif [ -f "$HOME/.zshrc" ] && grep -qF "$_dir" "$HOME/.zshrc" 2>/dev/null; then
    says "$_dir already referenced in ~/.zshrc"
  elif [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
    says "[dry-run] append PATH line for $_dir to ~/.zshrc"
  else
    printf 'export PATH="%s:$PATH"\n' "$_dir" >> "$HOME/.zshrc"
    says "appended $_dir to ~/.zshrc"
  fi
}
wire_zsh_path "$LOCAL_BIN"
if [ "$UV_TOOL_BIN" != "$LOCAL_BIN" ]; then
  wire_zsh_path "$UV_TOOL_BIN"
fi

# ---- 6. Final verification ---------------------------------------------------
step "Verifying…"
ok=1
if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] nothing installed, nothing to verify"
else
for c in gum uv mlx_vlm.server; do
  command -v "$c" >/dev/null 2>&1 || { says "MISSING: $c"; ok=0; }
done
if [ "$ok" -eq 1 ]; then
  says "all tools present ✓"
else
  # No set -e here: verification must report, not abort before the pi wiring
  # (the remaining steps are still useful and the exit code carries the failure).
  warn "missing tools above — the install may need a re-run in a fresh shell"
fi
fi

# ---- 7. pi integration — extension + wrapper ---------------------------------
step "Installing pi extension + wrapper…"
if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] copy extensions/marv-mlx.ts -> ~/.pi/agent/extensions/marv-mlx.ts"
  says "[dry-run] write ~/.pi/agent/bin/marv-mlx wrapper (points at $repo_dir/marv-mlx.zsh)"
  says "[dry-run] write ~/.pi/agent/bin/ymlx deprecation stub"
else
mkdir -p "$HOME/.pi/agent/extensions" "$HOME/.pi/agent/bin"
if [ -f "$repo_dir/extensions/marv-mlx.ts" ]; then
  cp -f "$repo_dir/extensions/marv-mlx.ts" "$HOME/.pi/agent/extensions/marv-mlx.ts"
  says "extension -> ~/.pi/agent/extensions/marv-mlx.ts"
else
  says "SKIP: extensions/marv-mlx.ts not found — is this a full checkout of the repo?"
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
fi
if command -v pi >/dev/null 2>&1; then
  says "pi found — run /reload inside pi to activate marv-mlx (or /marv-mlx-setup to repair)"
else
  says "pi not found — install it with: npm i -g @earendil-works/pi-coding-agent"
fi

# ---- 8. Wire the launcher into ~/.zshrc (idempotent) -------------------------
step "Wiring marv-mlx into ~/.zshrc …"
if grep -q 'marv-mlx-launcher.zsh' "$HOME/.zshrc" 2>/dev/null; then
  says "launcher already wired"
elif [ "${MARV_NO_ZSH:-0}" = "1" ]; then
  says "skipped (MARV_NO_ZSH=1) — add manually: source $repo_dir/marv-mlx-launcher.zsh"
elif [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] append launcher source line to ~/.zshrc"
else
  {
    printf '\n# marv-mlx (installed by install.sh)\n'
    printf 'test -f "%s/marv-mlx-launcher.zsh" && source "%s/marv-mlx-launcher.zsh"\n' "$repo_dir" "$repo_dir"
  } >> "$HOME/.zshrc"
  says "appended launcher source to ~/.zshrc"
fi

# ---- 9. Optional model download ---------------------------------------------
# `--model` turns the installer into a one-shot setup: install + fetch weights.
# marv-mlx is the runtime half, so this only downloads — set the default model in
# marv's config yourself (`marv`'s own installer does that for you).
if [ -n "$(printf '%s' "$models" | tr -d ' ')" ]; then
  for model in $(printf '%s' "$models" | tr ',' ' '); do
    case "$model" in
      "") continue ;;
      *[!A-Za-z0-9._/-]*) die "invalid model id: $model" ;;
    esac
    step "Downloading ${model}…"
    if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
      says "[dry-run] zsh $repo_dir/marv-mlx.zsh download $model"
      continue
    fi
    if zsh "$repo_dir/marv-mlx.zsh" download "$model"; then
      says "downloaded $model"
    else
      warn "download failed for $model"
      model_failed=1
    fi
  done
fi

if [ "${MARV_MLX_DRY_RUN:-0}" = "1" ]; then
  step "Dry run complete — nothing was installed."
  says "Re-run without --dry-run (or MARV_MLX_DRY_RUN=1) to apply."
  exit 0
fi

step "Done. marv-mlx is installed in $repo_dir"
says "Open a NEW terminal (or run: source ~/.zshrc), then type: marv-mlx"
if [ -n "${model_failed:-}" ]; then
  warn "the install itself is complete, but one or more model downloads failed."
  exit 1
fi
if [ "$ok" -ne 1 ]; then
  exit 1
fi
exit 0