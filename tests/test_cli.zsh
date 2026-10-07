#!/usr/bin/env zsh
# Hermetic CLI tests for marv-mlx.zsh: exit codes + --json output for the
# non-interactive verbs, with stub tools on PATH so no real install is needed.
# Run:  zsh tests/test_cli.zsh

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
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- Hermetic HOME: empty HF hub + a couple of fake installed models ----------
export HOME="$tmp/home"
hub="$HOME/.cache/huggingface/hub"
mkdir -p "$hub/models--acme--Qwen3.5-9B/snapshots/abc" \
         "$hub/models--acme--gemma-4-12B/snapshots/abc"
print -r -- '{"model_type": "qwen3_5"}'    > "$hub/models--acme--Qwen3.5-9B/snapshots/abc/config.json"
print -r -- '{"model_type": "gemma4_unified"}' > "$hub/models--acme--gemma-4-12B/snapshots/abc/config.json"

# --- Stub tools on PATH so the pre-dispatch tool check passes ------------------
bin="$tmp/bin"
mkdir -p "$bin"
for t in gum uvx mlx_vlm.server; do printf '#!/bin/sh\nexit 0\n' > "$bin/$t"; chmod +x "$bin/$t"; done
# curl always fails fast: the network-using verbs are skipped by design in CLI
# mode, and the curated-list fallback should not be hit.
printf '#!/bin/sh\nexit 1\n' > "$bin/curl"; chmod +x "$bin/curl"
export PATH="$bin:$PATH"

# --- Fixture curated catalog (the curl stub can't fetch the real one) ---------
mkdir -p "$HOME/.cache/marv/mlx"
cat > "$HOME/.cache/marv/mlx/curated-llms.md" <<'CATALOG'
8 GB RAM Tier Models

acme/Tiny-4B
The compact generalist


16 GB RAM Tier Models (power users)

acme/Qwen3.5-9B & acme/Qwen3.5-9B-Reasoning
The one that thinks

acme/Bare-7B
No tagline here
CATALOG

marv-mlx() { zsh "$repo/marv-mlx.zsh" "$@" }   # run the real entry point

# --- version / help -----------------------------------------------------------
ver=$(marv-mlx --version)
check "$(<"$repo/VERSION")" "$ver" "version matches VERSION"
marv-mlx --help | grep -q 'marv-mlx download' && print "ok: help mentions download" \
  || { print -u2 "FAIL: help missing download"; fail=1 }

# --- status --json (nothing running) -----------------------------------------
out=$(marv-mlx status --json 2>/dev/null); rc=$?
check 1 "$rc" "status exit=1 when idle"
check null "$out" "status --json = null when idle"

# --- list / list --json -------------------------------------------------------
check $'acme/Qwen3.5-9B\nacme/gemma-4-12B' "$(marv-mlx list 2>/dev/null)" "list prints model ids"
out=$(marv-mlx list --json 2>/dev/null)
check ok "$(print -r -- "$out" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>/dev/null)" \
  "list --json is valid JSON"
check 2 "$(print -r -- "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" \
  "list --json has 2 entries"

# --- info / info --json -------------------------------------------------------
marv-mlx info acme/Qwen3.5-9B | grep -q 'Family:     qwen' \
  && print "ok: info resolves family" || { print -u2 "FAIL: info family"; fail=1 }
out=$(marv-mlx info acme/gemma-4-12B --json)
check ok "$(print -r -- "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["family"]=="gemma" and d["installed"] and d["thinking_markers"]=="channel" else "bad")')" \
  "info --json fields"

# --- endpoint --json (nothing running) ---------------------------------------
out=$(marv-mlx endpoint --json 2>/dev/null); rc=$?
check 1 "$rc" "endpoint exit=1 when idle"
check null "$out" "endpoint --json = null when idle"

# --- curated / curated --json -------------------------------------------------
check 0 "$(marv-mlx curated >/dev/null 2>&1; echo $?)" "curated exit=0"
out=$(marv-mlx curated 2>/dev/null)
[[ "$out" == *"acme/Qwen3.5-9B"* ]] && print "ok: curated lists catalog models" \
  || { print -u2 "FAIL: curated missing catalog model"; print -u2 "$out"; fail=1 }
[[ "$out" == *"The compact generalist"* ]] && print "ok: curated shows taglines" \
  || { print -u2 "FAIL: curated missing tagline"; fail=1 }
# Tier headers are printed verbatim from the source (not rebuilt from the tier
# number), so curator-repo wording changes show straight through.
[[ "$out" == *"8 GB RAM Tier Models"* ]] && print "ok: curated prints tier header verbatim" \
  || { print -u2 "FAIL: curated tier header not verbatim"; print -u2 "$out"; fail=1; }
[[ "$out" == *"16 GB RAM Tier Models (power users)"* ]] \
  && print "ok: curated keeps custom tier header text" \
  || { print -u2 "FAIL: curated dropped custom tier header"; fail=1; }
# A tagline must not leak into a second id, and a multi-id entry keeps both.
json=$(marv-mlx curated --json 2>/dev/null)
check ok "$(print -r -- "$json" | python3 -c 'import json,sys;
d=json.load(sys.stdin);
print("ok" if any(e["tier"]==16 and e["models"]==["acme/Qwen3.5-9B","acme/Qwen3.5-9B-Reasoning"] and e["description"]=="The one that thinks" and e["tags"]=="" for e in d) else "bad")' 2>/dev/null)" \
  "curated --json tiers + models[]"
check ok "$(print -r -- "$json" | python3 -c 'import json,sys;
d=json.load(sys.stdin);
print("ok" if any(e["tier"]==8 and e["models"]==["acme/Tiny-4B"] and e["description"]=="The compact generalist" for e in d) else "bad")' 2>/dev/null)" \
  "curated --json tagline -> description"

# --- serve is an alias for run -------------------------------------------------
# Dispatched to `run`, so an empty call shows run's usage, NOT "unknown command".
err=$(marv-mlx serve 2>&1 >/dev/null); rc=$?
check 2 "$rc" "serve (no model) -> usage exit 2"
case "$err" in
  *"unknown command"*) print -u2 "FAIL: serve rejected as unknown"; fail=1 ;;
  *"marv-mlx run <model-id>"*) print "ok: serve dispatches to run" ;;
  *) print -u2 "FAIL: serve gave unexpected error: $err"; fail=1 ;;
esac

# --- usage errors -------------------------------------------------------------
marv-mlx info >/dev/null 2>&1; check 2 "$?" "info without model -> 2"
marv-mlx download >/dev/null 2>&1; check 2 "$?" "download without model -> 2"
marv-mlx bogus >/dev/null 2>&1; check 2 "$?" "unknown command -> 2"

# --- stop --all is a no-op (and silent) when nothing runs ----------------------
marv-mlx stop --all >/dev/null 2>&1; check 0 "$?" "stop --all exit=0 when idle"

exit $fail
