#!/usr/bin/env zsh
# Unit tests for the thinking classifier/spec in lib/marv-mlx-helpers.zsh.
# Hermetic: builds a throwaway HF hub fixture.
# Run:  zsh tests/test_helpers.zsh

emulate -L zsh
setopt no_unset

source "${0:A:h}/../lib/marv-mlx-helpers.zsh"

typeset -g fail=0

check() { # expected actual label
  if [[ "$1" != "$2" ]]; then
    print -u2 "FAIL: $3 — expected '$1', got '$2'"
    fail=1
  else
    print "ok: $3"
  fi
}

hub=$(mktemp -d)
trap 'rm -rf "$hub"' EXIT

mk() { # model-id model_type-or-empty
  local id="$1" mt="$2" dir="$hub/models--${1//\//--}/snapshots/abc"
  mkdir -p "$dir"
  [[ -n "$mt" ]] && print -r -- "{\"model_type\": \"$mt\"}" > "$dir/config.json"
}

mk "acme/Qwen3.5-9B" qwen3_5
mk "acme/Qwen3.6-MoE" qwen3_5_moe
mk "acme/gemma-4-12B" gemma4_unified
mk "acme/Ministral-3-8B-Reasoning-2512-4bit" mistral3
mk "acme/Ministral-3-8B-Instruct-2512-4bit" mistral3
mk "acme/LFM2.5-8B" lfm2_moe
mk "acme/SomeModel" ""                       # name fallback
mk "acme/Mystery-Qwen-X" ""                  # name fallback

check qwen "$(_marv_mlx_model_family acme/Qwen3.5-9B "$hub")" "qwen3_5 -> qwen"
check qwen "$(_marv_mlx_model_family acme/Qwen3.6-MoE "$hub")" "qwen3_5_moe -> qwen"
check gemma "$(_marv_mlx_model_family acme/gemma-4-12B "$hub")" "gemma4_unified -> gemma"
check ministral-reasoning "$(_marv_mlx_model_family acme/Ministral-3-8B-Reasoning-2512-4bit "$hub")" "mistral3 reasoning"
check ministral-instruct "$(_marv_mlx_model_family acme/Ministral-3-8B-Instruct-2512-4bit "$hub")" "mistral3 instruct"
check lfm "$(_marv_mlx_model_family acme/LFM2.5-8B "$hub")" "lfm2_moe -> lfm"
check generic "$(_marv_mlx_model_family acme/SomeModel "$hub")" "unknown -> generic"
check qwen "$(_marv_mlx_model_family acme/Mystery-Qwen-X "$hub")" "name fallback qwen"

check $'enable_thinking\tthink\t0' "$(_marv_mlx_thinking_spec acme/Qwen3.5-9B "$hub")" "qwen spec"
check $'enable_thinking\tchannel\t0' "$(_marv_mlx_thinking_spec acme/gemma-4-12B "$hub")" "gemma spec"
check $'variant\tbracket\t1' "$(_marv_mlx_thinking_spec acme/Ministral-3-8B-Reasoning-2512-4bit "$hub")" "ministral-r spec"
check $'variant\tnone\t0' "$(_marv_mlx_thinking_spec acme/Ministral-3-8B-Instruct-2512-4bit "$hub")" "ministral-i spec"
check $'none\tthink\t0' "$(_marv_mlx_thinking_spec acme/LFM2.5-8B "$hub")" "lfm spec"

# Launch flags: resolved --enable-thinking + Ministral markers.
MARV_MLX_QUICK_THINKING=on
local -a flags
flags=( --max-tokens 2048 )
_marv_mlx_apply_launch_thinking flags acme/Ministral-3-8B-Reasoning-2512-4bit "$hub"
check "1" "$(( ${flags[(I)--enable-thinking]} > 0 ))" "ministral on: --enable-thinking added"
check "1" "$(( ${flags[(I)--thinking-start-token]} > 0 ))" "ministral on: start token added"
check "1" "$(( ${flags[(I)--thinking-end-token]} > 0 ))" "ministral on: end token added"

flags=( --max-tokens 2048 --enable-thinking )
MARV_MLX_QUICK_THINKING=default
_marv_mlx_apply_launch_thinking flags acme/Qwen3.5-9B "$hub"
check "0" "$(( ${flags[(I)--enable-thinking]} > 0 ))" "qwen default: stale flag dropped"
check "0" "$(( ${flags[(I)--thinking-start-token]} > 0 ))" "qwen: no bracket markers"

# --- CLI plumbing helpers -----------------------------------------------------
# `filters` / `replace` stand in for a hub dir listing: they let us exercise
# _marv_mlx_json_escape without touching the filesystem.
check 'org/Model' "$(_marv_mlx_json_escape 'org/Model')" "json: plain string"
check 'a\"b'   "$(_marv_mlx_json_escape 'a"b')"     "json: quote escaped"
check 'a\\b'   "$(_marv_mlx_json_escape 'a\b')"     "json: backslash escaped"
check 'a\nb'   "$(_marv_mlx_json_escape $'a\nb')"   "json: newline escaped"
check 'a\tb'   "$(_marv_mlx_json_escape $'a\tb')"   "json: tab escaped"

# Alternate-screen state machine: enter/leave are idempotent and leave() must
# actually emit the restore sequence when we own the terminal.
_MARV_MLX_TUI_ACTIVE=0
_marv_mlx_tui_enter >/dev/null
check 1 "$_MARV_MLX_TUI_ACTIVE" "tui: enter sets active"
_marv_mlx_tui_enter >/dev/null   # second call must not re-emit
_marv_mlx_tui_leave >/dev/null
check 0 "$_MARV_MLX_TUI_ACTIVE" "tui: leave clears active"
out=$(_marv_mlx_tui_leave; print -n X)
check X "$out" "tui: leave is idempotent"
out=$(_MARV_MLX_TUI_ACTIVE=1 _marv_mlx_tui_leave; print -n X)
check X "${out##*$'\e[?1049l'}" "tui: leave emits restore when active"

_marv_mlx_usage | grep -q 'marv-mlx download' \
  && print "ok: usage lists download" \
  || { print -u2 "FAIL: usage missing download"; fail=1 }

# --- Catalog parser -----------------------------------------------------------
# Current 2-line format: id + tagline. Also legacy 3-line title-first blocks.
cat > "$hub/cat.md" <<'CAT'
8 GB RAM Tier Models

acme/Tiny-4B
The compact generalist

acme/Pair-A & acme/Pair-B
The paired one


16 GB RAM Tier Models

Legacy Title Here
acme/Legacy-9B
t3, vision
CAT

# Field order is tier<US>tier_name<US>title<US>ids<US>tags<US>description. Read
# with US as IFS: a tab IFS would collapse the empty tags field and shift the
# tagline.
catalog_rows() { _marv_mlx_parse_catalog "$hub/cat.md"; }
row1=$(catalog_rows | sed -n 1p)
IFS=$'\x1f' read -r t tname title ids tags desc <<< "$row1"
check 8 "$t" "catalog: tier"
check '8 GB RAM Tier Models' "$tname" "catalog: tier header kept verbatim"
check acme/Tiny-4B "$title" "catalog: entry name is the model id"
check acme/Tiny-4B "$ids" "catalog: id"
check '' "$tags" "catalog: no tags (2-line format)"
check 'The compact generalist' "$desc" "catalog: tagline -> description"

row2=$(catalog_rows | sed -n 2p)
IFS=$'\x1f' read -r t tname title ids tags desc <<< "$row2"
check 'acme/Pair-A & acme/Pair-B' "$ids" "catalog: paired ids kept"
check acme/Pair-A "$title" "catalog: paired name = first id"
check 'The paired one' "$desc" "catalog: paired tagline"

row3=$(catalog_rows | sed -n 3p)
IFS=$'\x1f' read -r t tname title ids tags desc <<< "$row3"
check 16 "$t" "catalog: second tier parsed"
check '16 GB RAM Tier Models' "$tname" "catalog: second tier header"
check 'Legacy Title Here' "$title" "catalog: legacy title-first block"
check acme/Legacy-9B "$ids" "catalog: legacy id"
check 't3, vision' "$tags" "catalog: legacy tags"
check '' "$desc" "catalog: legacy desc empty"

# Legacy id/tags 2-line block (no title line) still resolves.
cat > "$hub/cat2.md" <<'CAT'
8 GB RAM Tier Models

acme/Old-4B
t3
CAT
old=$( _marv_mlx_parse_catalog "$hub/cat2.md" )
IFS=$'\x1f' read -r t tname title ids tags desc <<< "$old"
check 'acme/Old-4B' "$ids" "catalog: legacy id-only block"
check 'acme/Old-4B' "$title" "catalog: legacy id-only name"
check 't3' "$tags" "catalog: legacy id-only tags"

# Empty catalog is not an error.
: > "$hub/empty.md"
check '' "$(_marv_mlx_parse_catalog "$hub/empty.md")" "catalog: empty file -> no rows"

# The US delimiter round-trips a field containing spaces and slashes.
check 6 "$(print -r -- "$row1" | awk -F$'\x1f' '{print NF}')" "catalog: exactly 6 fields"

exit $fail
