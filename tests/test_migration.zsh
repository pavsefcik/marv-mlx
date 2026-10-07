#!/usr/bin/env zsh
# Tests for the one-time ymlx -> marv-mlx state migration.
# Hermetic: builds a throwaway HOME and runs the real helper.
# Run:  zsh tests/test_migration.zsh

emulate -L zsh
setopt no_unset

typeset -g fail=0
check() { # expected actual label
  if [[ "$1" != "$2" ]]; then
    print -u2 "FAIL: $3 — expected '$1', got '$2'"
    fail=1
  else
    print "ok: $3"
  fi
}

repo="${0:A:h}/.."

# --- Build a fake pre-rename machine -----------------------------------------
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

mkdir -p "$home/.cache/ymlx/chats" "$home/.pi/agent/bin" "$home/.pi/agent/extensions"
cat > "$home/.cache/ymlx/config.zsh" <<'CFG'
# >>> ymlx-managed quick settings <<<
YMLX_QUICK_THINKING="on"
# <<< end ymlx-managed >>>
YMLX_CHAT_FLAGS=( --temperature 0.7 )
CFG
print -r -- 'old chat' > "$home/.cache/ymlx/chats/one.txt"
cat > "$home/.zshrc" <<'EOF'
# ymlx
source "/old/path/ymlx/ymlx-launcher.zsh"
source "/x/wren/wren-launcher.zsh"
test -f "/y/marv/marv-launcher.zsh" && source "/y/marv/marv-launcher.zsh"
EOF
print -r -- '#!/bin/sh' > "$home/.pi/agent/bin/ymlx"
print -r -- '// old' > "$home/.pi/agent/extensions/ymlx-sync.ts"

# Run the migration exactly as marv-mlx.zsh does (with _MARV_MLX_SRC_DIR set).
HOME="$home" _MARV_MLX_SRC_DIR="$repo" zsh -c "
  source '$repo/lib/marv-mlx-helpers.zsh'
  _marv_mlx_migrate_legacy_state
" 2>/dev/null

# --- State dir copied, old tree preserved ------------------------------------
check 0 "$([[ -f "$home/.cache/marv/mlx/config.zsh" ]] && echo 0 || echo 1)" \
  "state copied to ~/.cache/marv/mlx"
check 0 "$([[ -f "$home/.cache/ymlx/config.zsh" ]] && echo 0 || echo 1)" \
  "old state preserved (copy-then-switch)"
check 'old chat' "$(<"$home/.cache/marv/mlx/chats/one.txt")" "chat history survived"

# --- Config shim -------------------------------------------------------------
check 1 "$(grep -c '^# >>> marv-mlx-managed' "$home/.cache/marv/mlx/config.zsh")" \
  "managed block marker renamed"
check 1 "$(grep -c '^MARV_MLX_QUICK_THINKING' "$home/.cache/marv/mlx/config.zsh")" \
  "quick-setting var renamed"
check 1 "$(grep -c '^MARV_MLX_CHAT_FLAGS' "$home/.cache/marv/mlx/config.zsh")" \
  "hand-edited flag var renamed"
check 0 "$(grep -c '^YMLX_' "$home/.cache/marv/mlx/config.zsh")" \
  "no legacy YMLX_ vars remain"

# --- zshrc: only this project's launcher is rewritten ------------------------
check 1 "$(grep -cF "source \"$repo/marv-mlx-launcher.zsh\"" "$home/.zshrc")" \
  "ymlx launcher line points at marv-mlx"
check 1 "$(grep -c '^# marv-mlx$' "$home/.zshrc")" "comment line renamed"
check 1 "$(grep -cF 'source "/x/wren/wren-launcher.zsh"' "$home/.zshrc")" \
  "sibling wren launcher untouched"
check 1 "$(grep -cF 'source "/y/marv/marv-launcher.zsh"' "$home/.zshrc")" \
  "sibling marv launcher untouched"
check 0 "$(grep -c 'ymlx-launcher' "$home/.zshrc")" "no old launcher path remains"

# --- pi files ----------------------------------------------------------------
check 1 "$(grep -c 'renamed to marv-mlx' "$home/.pi/agent/bin/ymlx")" \
  "ymlx wrapper replaced with deprecation stub"
check 1 "$(test -x "$home/.pi/agent/bin/ymlx" && echo 1 || echo 0)" "stub is executable"
check 0 "$(test -f "$home/.pi/agent/extensions/ymlx-sync.ts" && echo 1 || echo 0)" \
  "old pi extension copy removed"

# --- Idempotency -------------------------------------------------------------
before="$(cat "$home/.zshrc")"
HOME="$home" _MARV_MLX_SRC_DIR="$repo" zsh -c "
  source '$repo/lib/marv-mlx-helpers.zsh'
  _marv_mlx_migrate_legacy_state
  _marv_mlx_migrate_legacy_state
" 2>/dev/null
check "$before" "$(cat "$home/.zshrc")" "second run leaves ~/.zshrc unchanged"

exit $fail
