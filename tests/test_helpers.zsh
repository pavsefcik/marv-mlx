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
  # A real MLX/HF snapshot always carries weights; without them the model is
  # filtered as unloadable (see the format tests below).
  print -r -- x > "$dir/model.safetensors"
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

# --- Format support: only MLX-loadable repos are listed -----------------------
# mlx-vlm reads *.safetensors (MLX-quantized, or plain bf16/fp16 HF) and nothing
# else: no GGUF, no PyTorch .bin/ONNX/CoreML, no foreign weight packing.
mk "acme/Llama-3.2-3B-GGUF" ""               # id signal (no gguf file needed)
mk "acme/Oddly-Named-4bit" ""                  # file signal below
print -r -- x > "$hub/models--acme--Oddly-Named-4bit/snapshots/abc/model-Q4_K_M.gguf"
mk "acme/Nested-GGUF-Dir" ""
mkdir -p "$hub/models--acme--Nested-GGUF-Dir/snapshots/abc/q4"
print -r -- x > "$hub/models--acme--Nested-GGUF-Dir/snapshots/abc/q4/model.gguf"
mk "acme/PyTorch-Only-7B" ""
rm -f "$hub/models--acme--PyTorch-Only-7B/snapshots/abc/model.safetensors"
print -r -- x > "$hub/models--acme--PyTorch-Only-7B/snapshots/abc/pytorch_model.bin"
mk "acme/Consolidated-Only" ""
rm -f "$hub/models--acme--Consolidated-Only/snapshots/abc/model.safetensors"
print -r -- x > "$hub/models--acme--Consolidated-Only/snapshots/abc/consolidated.safetensors"
mk "acme/Sharded-4bit" ""
rm -f "$hub/models--acme--Sharded-4bit/snapshots/abc/model.safetensors"
print -r -- x > "$hub/models--acme--Sharded-4bit/snapshots/abc/model-00001-of-00002.safetensors"
for qm in gptq bitsandbytes awq compressed-tensors; do
  mk "acme/Packed-$qm" ""
  print -r -- "{\"model_type\": \"qwen3_5\", \"quantization_config\": {\"quant_method\": \"$qm\"}}" \
    > "$hub/models--acme--Packed-$qm/snapshots/abc/config.json"
done
mk "acme/Fp8-DeepSeek" ""
print -r -- '{"model_type": "deepseek_v3", "quantization_config": {"quant_method": "fp8"}}' \
  > "$hub/models--acme--Fp8-DeepSeek/snapshots/abc/config.json"
mk "acme/MLX-Quantized" ""
print -r -- '{"model_type": "qwen3_5", "quantization": {"group_size": 64, "bits": 4}}' \
  > "$hub/models--acme--MLX-Quantized/snapshots/abc/config.json"

supported() { # model-id -> yes|no
  _marv_mlx_model_supported "$1" "$hub" && print yes || print no
}
check yes "$(supported acme/Qwen3.5-9B)" "supported: MLX repo"
check yes "$(supported acme/MLX-Quantized)" "supported: MLX quantization block"
check yes "$(supported acme/Fp8-DeepSeek)" "supported: fp8 quantization_config"
check yes "$(supported acme/Sharded-4bit)" "supported: sharded safetensors"
check yes "$(supported acme/Not-Downloaded-4bit)" "supported: unknown id assumed MLX"
check no  "$(supported acme/Llama-3.2-3B-GGUF)" "supported: -GGUF id rejected"
check no  "$(supported acme/Oddly-Named-4bit)" "supported: .gguf in snapshot rejected"
check no  "$(supported acme/Nested-GGUF-Dir)" "supported: nested .gguf rejected"
check no  "$(supported acme/Lowercase-Gguf)" "supported: case-insensitive gguf id"
check no  "$(supported acme/PyTorch-Only-7B)" "supported: pytorch_model.bin rejected"
check no  "$(supported acme/Consolidated-Only)" "supported: consolidated.safetensors alone rejected"
for qm in gptq bitsandbytes awq compressed-tensors; do
  check no "$(supported acme/Packed-$qm)" "supported: $qm packing rejected"
done
check "no .safetensors weights (PyTorch .bin, ONNX, CoreML, or an unfinished download)" \
  "$(_marv_mlx_model_unsupported_reason acme/PyTorch-Only-7B "$hub")" \
  "unsupported reason: no safetensors"
check "GGUF (llama.cpp) — mlx-vlm has no GGUF loader" \
  "$(_marv_mlx_model_unsupported_reason acme/Llama-3.2-3B-GGUF "$hub")" \
  "unsupported reason: GGUF"
check "" "$(_marv_mlx_model_unsupported_reason acme/Qwen3.5-9B "$hub")" \
  "unsupported reason: empty for a servable model"

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

# --- APC (Automatic Prefix Caching) env defaults ------------------------------
# mlx-vlm leaves prefix caching off by default; the helper turns it on and must
# respect pre-set values / the MARV_MLX_APC opt-out without mutating the caller.
apc() { # extra zsh to run before the helper; prints ENABLED|DISK_PATH|INTERVAL|MAXGB
  (
    unset APC_ENABLED APC_DISK_ENABLED APC_DISK_PATH APC_DISK_MAX_GB \
          APC_CHECKPOINT_INTERVAL_TOKENS APC_CHECKPOINT_ENTRIES MARV_MLX_APC
    eval "$1"
    _marv_mlx_export_apc_env /tmp/marv-apc-state
    print -r -- "${APC_ENABLED:-}|${APC_DISK_PATH:-}|${APC_CHECKPOINT_INTERVAL_TOKENS:-}|${APC_DISK_MAX_GB:-}"
  )
}
check '1|/tmp/marv-apc-state/apc|512|5' "$(apc '')" "apc: defaults exported"
check '|||' "$(apc 'MARV_MLX_APC=0')" "apc: MARV_MLX_APC=0 opts out"
check '0|/tmp/marv-apc-state/apc|1024|5' \
  "$(apc 'APC_ENABLED=0; APC_CHECKPOINT_INTERVAL_TOKENS=1024')" \
  "apc: existing env respected"

# --- APC sitecustomize (covers foreign launches too) --------------------------
# The payload defaults the APC env at interpreter startup, so servers launched
# by ANY tool (marv's embedded launch spawns mlx_vlm.server directly) get
# prefix caching; the installer that drops it into the tool env must be
# idempotent and never touch a foreign sitecustomize.
apc_src="${0:A:h}/../lib/marv-mlx-apc-sitecustomize.py"
mkdir -p "$hub/apc-sp"
cp "$apc_src" "$hub/apc-sp/sitecustomize.py"
apc_py() { # extra zsh before launch; prints ENABLED|INTERVAL|MAXGB
  (
    unset APC_ENABLED APC_DISK_ENABLED APC_DISK_PATH APC_DISK_MAX_GB \
          APC_CHECKPOINT_INTERVAL_TOKENS APC_CHECKPOINT_ENTRIES MARV_MLX_APC
    eval "$1"
    PYTHONPATH="$hub/apc-sp" python3 -c \
      'import os; print("|".join(os.environ.get(k, "-") for k in ("APC_ENABLED", "APC_CHECKPOINT_INTERVAL_TOKENS", "APC_DISK_MAX_GB")))'
  )
}
check '1|512|5' "$(apc_py '')" "apc sitecustomize: defaults at startup"
check '-|-|-' "$(apc_py 'export MARV_MLX_APC=0')" "apc sitecustomize: MARV_MLX_APC=0 opts out"
check '0|-|-' "$(apc_py 'export APC_ENABLED=0')" "apc sitecustomize: APC_ENABLED=0 opts out"
check '1|2048|5' "$(apc_py 'export APC_CHECKPOINT_INTERVAL_TOKENS=2048')" "apc sitecustomize: preset env wins"

# Installer: installs into a tools-dir fixture, idempotent, foreign-safe.
mkdir -p "$hub/apc-tools/mlx-vlm/lib/python3.13/site-packages"
sp_dir="$hub/apc-tools/mlx-vlm/lib/python3.13/site-packages"
_marv_mlx_install_apc_sitecustomize "$apc_src" "$hub/apc-tools"
check '1' "$([[ -f "$sp_dir/sitecustomize.py" ]] && echo 1)" "apc installer: installs sitecustomize"
check '1' "$(cmp -s "$apc_src" "$sp_dir/sitecustomize.py" && echo 1)" "apc installer: content matches payload"
_marv_mlx_install_apc_sitecustomize "$apc_src" "$hub/apc-tools"
check '1' "$(cmp -s "$apc_src" "$sp_dir/sitecustomize.py" && echo 1)" "apc installer: re-run is idempotent"
print -r -- 'import something_else  # not ours' > "$sp_dir/sitecustomize.py"
_marv_mlx_install_apc_sitecustomize "$apc_src" "$hub/apc-tools" 2>/dev/null
check 'import something_else  # not ours' "$(<"$sp_dir/sitecustomize.py")" "apc installer: leaves foreign sitecustomize alone"

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

# --- cache footprint helpers --------------------------------------------------
check "0 B"     "$(_marv_mlx_fmt_bytes 0)"          "fmt 0"
check "512 B"   "$(_marv_mlx_fmt_bytes 512)"        "fmt bytes"
check "1.0 KiB" "$(_marv_mlx_fmt_bytes 1024)"       "fmt KiB"
check "1.5 GiB" "$(_marv_mlx_fmt_bytes 1610612736)" "fmt GiB"

# Regression guard: _marv_mlx_du_bytes once declared `local path=...`, which
# rebinds zsh's special path array (backing PATH) and broke command lookup
# inside it. That surfaces as a 0/short return, asserted below. (A PATH-equality
# assertion would be vacuous: `local` is restored on return and $( ) runs in a
# subshell.) Also assert the source doesn't reintroduce the declaration.
local hub_bytes="$(_marv_mlx_du_bytes "$hub")"
check 1 "$([[ "$hub_bytes" == <-> && "$hub_bytes" -gt 0 ]] && print 1 || print 0)" \
  "du_bytes returns a positive byte count"
local path_decl=0
grep -qE '^[[:space:]]*local path=' "${0:A:h}/../lib/marv-mlx-helpers.zsh" && path_decl=1
check 0 "$path_decl" "helpers declare no 'local path=' (PATH-clobber guard)"

# A missing path is a silent zero, not an error.
check "0" "$(_marv_mlx_du_bytes "$hub/does-not-exist")" "du_bytes missing path -> 0"

# --- lsof listener parsing (the live-server guard's core) ----------------------
# `make doctor` asserts the helper passes `-Fpcn`; these pin the parser against
# real output shapes, including the missing-`n` shape that `-Fpc` produces. That
# regression is what made `clean --apc`'s live-server guard silently inert.
check $'123\t11507' \
  "$(printf 'p123\ncPython\nf4\nn*:11507\n' | _marv_mlx_parse_lsof_listeners)" \
  "lsof parse: pid + wildcard port"
check $'1\t11500\n2\t11509' \
  "$(printf 'p1\ncA\nn*:11500\np2\ncB\nn127.0.0.1:11509\n' | _marv_mlx_parse_lsof_listeners)" \
  "lsof parse: multiple listeners, wildcard + ipv4"
check '' \
  "$(printf 'p123\ncPython\nf4\n' | _marv_mlx_parse_lsof_listeners)" \
  "lsof parse: no 'n' line -> nothing (the -Fpc regression)"
check '' \
  "$(printf '' | _marv_mlx_parse_lsof_listeners)" \
  "lsof parse: empty input -> nothing"

# --- APC defaults must agree across the two layers that enable it --------------
# `_marv_mlx_export_apc_env` (helpers) covers marv-mlx's own launches and the
# sitecustomize payload covers foreign ones. If a change to one skips the other,
# foreign servers silently behave differently from marv-mlx's.
local lib_dir="${0:A:h}/../lib"
local h_max h_int h_ent s_max s_int s_ent
h_max=$(sed -n 's/.*APC_DISK_MAX_GB:-\([0-9][0-9]*\)}.*/\1/p' "$lib_dir/marv-mlx-helpers.zsh" | head -n1)
h_int=$(sed -n 's/.*APC_CHECKPOINT_INTERVAL_TOKENS:-\([0-9][0-9]*\)}.*/\1/p' "$lib_dir/marv-mlx-helpers.zsh" | head -n1)
h_ent=$(sed -n 's/.*APC_CHECKPOINT_ENTRIES:-\([0-9][0-9]*\)}.*/\1/p' "$lib_dir/marv-mlx-helpers.zsh" | head -n1)
s_max=$(sed -n 's/.*setdefault("APC_DISK_MAX_GB", "\([0-9][0-9]*\)").*/\1/p' "$lib_dir/marv-mlx-apc-sitecustomize.py" | head -n1)
s_int=$(sed -n 's/.*setdefault("APC_CHECKPOINT_INTERVAL_TOKENS", "\([0-9][0-9]*\)").*/\1/p' "$lib_dir/marv-mlx-apc-sitecustomize.py" | head -n1)
s_ent=$(sed -n 's/.*setdefault("APC_CHECKPOINT_ENTRIES", "\([0-9][0-9]*\)").*/\1/p' "$lib_dir/marv-mlx-apc-sitecustomize.py" | head -n1)
check "$h_max" "$s_max" "APC disk cap agrees across layers"
check "$h_int" "$s_int" "APC checkpoint interval agrees across layers"
check "$h_ent" "$s_ent" "APC checkpoint entries agrees across layers"
[[ -n "$h_max" && -n "$h_int" && -n "$h_ent" ]] \
  && print "ok: APC defaults are non-empty on both layers" \
  || { print -u2 "FAIL: APC defaults not found (sed patterns drifted?)"; fail=1; }

# --- _marv_mlx_last_cached_tokens: newest log across dirs ---------------------
local ct_a="$hub/ct-a" ct_b="$hub/ct-b"
mkdir -p "$ct_a" "$ct_b"
print -r -- 'Prefill completed: prompt_tokens=10 cached_tokens=3' > "$ct_a/own.log"
sleep 1
print -r -- 'Prefill completed: prompt_tokens=20 cached_tokens=17' > "$ct_b/harness.log"
check 17 "$(_marv_mlx_last_cached_tokens "$ct_a" "$ct_b")" \
  "cached_tokens: newest log across dirs wins"
check 3 "$(_marv_mlx_last_cached_tokens "$ct_a" "$ct_a/nonexistent")" \
  "cached_tokens: missing dir ignored"
check '' "$(_marv_mlx_last_cached_tokens "$ct_a/nonexistent")" \
  "cached_tokens: no logs -> empty"
print -r -- 'noise cached_tokens=notanumber' > "$ct_b/harness.log"
check '' "$(_marv_mlx_last_cached_tokens "$ct_b")" \
  "cached_tokens: non-numeric match ignored"

# --- sitecustomize chains the next one on sys.path ----------------------------
# The process-rename hook shadows any sitecustomize later on sys.path (Python
# imports only the first); it must chain into the marv-mlx APC payload so a
# marv-mlx launch keeps prefix caching on. Simulate: PYTHONPATH=<hook dir>:<apc
# dir>, a plain python3 with setproctitle unavailable in a foreign venv would
# skip the rename but still run the chained APC defaults.
local chain_lib="${0:A:h}/../lib"
local chain_apc="$hub/chain-apc"
mkdir -p "$chain_apc"
cp "$lib_dir/marv-mlx-apc-sitecustomize.py" "$chain_apc/sitecustomize.py"
chain_out="$(MARV_MLX_PROCTITLE=chain-test PYTHONPATH="$chain_lib:$chain_apc" python3 -c \
  'import os; print(os.environ.get("APC_ENABLED", "unset"))' 2>/dev/null)"
check 1 "$chain_out" "sitecustomize: proctitle hook chains into the APC payload"
chain_out="$(MARV_MLX_PROCTITLE=chain-test MARV_MLX_APC=0 PYTHONPATH="$chain_lib:$chain_apc" python3 -c \
  'import os; print(os.environ.get("APC_ENABLED", "unset"))' 2>/dev/null)"
check unset "$chain_out" "sitecustomize: chained APC opt-out respected (no default set)"

exit $fail
