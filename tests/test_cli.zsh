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
# lsof is stubbed to report "no listeners" by default, but delegates to the real
# binary when MARV_TEST_REAL_LSOF is set. The real-lsof integration test below
# needs that (a hand-picked PATH turned out to be runner-fragile), and an
# absolute path avoids the stub resolving to itself.
cat > "$bin/lsof" <<'LSOF'
#!/bin/sh
[ -n "$MARV_TEST_REAL_LSOF" ] || exit 0
for p in /usr/sbin/lsof /usr/bin/lsof /sbin/lsof; do
  [ -x "$p" ] && exec "$p" "$@"
done
exit 1
LSOF
chmod +x "$bin/lsof"
# curl always fails fast: the network-using verbs are skipped by design in CLI
# mode, and the self-update check should not be hit.
printf '#!/bin/sh\nexit 1\n' > "$bin/curl"; chmod +x "$bin/curl"
export PATH="$bin:$PATH"

# --- Fixture curated catalog (MARV_MLX_CATALOG overrides the bundled one) ------
mkdir -p "$HOME/.cache/marv/mlx"
cat > "$tmp/catalog.md" <<'CATALOG'
8 GB RAM Tier Models

acme/Tiny-4B
The compact generalist


16 GB RAM Tier Models (power users)

acme/Qwen3.5-9B & acme/Qwen3.5-9B-Reasoning
The one that thinks

acme/Bare-7B
No tagline here
CATALOG
export MARV_MLX_CATALOG="$tmp/catalog.md"

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
# number), so catalog wording changes show straight through.
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

# --- cache / clean (on-disk footprint + hygiene) ------------------------------
# The lsof stub above keeps these hermetic: no listener -> idle, as in a fresh
# shell. Regenerable caches are the only things `clean` may touch.
mkdir -p "$HOME/.cache/marv/mlx/apc" "$HOME/.cache/marv/mlx/venvs"
head -c 65536 /dev/zero > "$HOME/.cache/marv/mlx/apc/checkpoint.safetensors"
venvs_sentinel="$HOME/.cache/marv/mlx/venvs/keep"
head -c 16 /dev/zero > "$venvs_sentinel"

check 0 "$(marv-mlx cache >/dev/null 2>&1; echo $?)" "cache exit=0"
out=$(marv-mlx cache 2>/dev/null)
[[ "$out" == *"apc"* && "$out" == *"hub"* ]] && print "ok: cache lists categories" \
  || { print -u2 "FAIL: cache categories missing"; print -u2 "$out"; fail=1; }
out=$(marv-mlx cache --json 2>/dev/null)
check ok "$(print -r -- "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("ok" if d["sizes"]["apc"] >= 65536 and d["apc"]["enabled"] in (0, 1) and "disk_max_gb" in d["apc"] else "bad")' 2>/dev/null)" \
  "cache --json sizes + apc block"

# Nothing is deletable by default; unknown flags are usage errors.
marv-mlx clean >/dev/null 2>&1; check 2 "$?" "clean (no target) -> 2"
marv-mlx clean --nope >/dev/null 2>&1; check 2 "$?" "clean unknown flag -> 2"

# --dry-run reports without deleting.
out=$(marv-mlx clean --dry-run --all 2>/dev/null); rc=$?
check 0 "$rc" "clean --dry-run exit=0"
[[ "$out" == *"would remove: apc"* ]] && print "ok: clean --dry-run names apc" \
  || { print -u2 "FAIL: clean --dry-run output: $out"; fail=1; }
[[ -f "$HOME/.cache/marv/mlx/apc/checkpoint.safetensors" ]] \
  && print "ok: clean --dry-run deleted nothing" \
  || { print -u2 "FAIL: clean --dry-run deleted files"; fail=1; }

# A real clean removes the selected category only.
marv-mlx clean --apc >/dev/null 2>&1; check 0 "$?" "clean --apc exit=0"
[[ -e "$HOME/.cache/marv/mlx/apc/checkpoint.safetensors" ]] \
  && { print -u2 "FAIL: clean --apc left APC files"; fail=1; } \
  || print "ok: clean --apc removed APC files"
[[ -f "$venvs_sentinel" ]] && print "ok: clean --apc left other categories" \
  || { print -u2 "FAIL: clean --apc removed venvs"; fail=1; }

# Live-server guard: a listener on marv-mlx's port range makes `clean --apc`
# refuse unless --force (deleting memory-mapped checkpoints is unsafe).
bin_live="$tmp/bin_live"; mkdir -p "$bin_live"
printf '#!/bin/sh\nprintf "p123\\ncpython3.13\\nn*:11500\\n"\n' > "$bin_live/lsof"
chmod +x "$bin_live/lsof"
saved_path="$PATH"
export PATH="$bin_live:$PATH"
mkdir -p "$HOME/.cache/marv/mlx/apc"
head -c 65536 /dev/zero > "$HOME/.cache/marv/mlx/apc/checkpoint.safetensors"
err=$(marv-mlx clean --apc 2>&1 >/dev/null); rc=$?
check 1 "$rc" "clean --apc refuses while a server is live"
[[ "$err" == *"--force"* ]] && print "ok: live-server guard suggests --force" \
  || { print -u2 "FAIL: guard message: $err"; fail=1; }
[[ -f "$HOME/.cache/marv/mlx/apc/checkpoint.safetensors" ]] \
  && print "ok: refused clean deleted nothing" \
  || { print -u2 "FAIL: refused clean deleted files"; fail=1; }
export PATH="$saved_path"

# A real `clean --all` removes every disposable category and preserves chats.
mkdir -p "$HOME/.cache/marv/mlx/apc" "$HOME/.cache/marv/mlx/venvs" "$HOME/.cache/marv/mlx/chats"
head -c 4096 /dev/zero > "$HOME/.cache/marv/mlx/apc/x.safetensors"
head -c 4096 /dev/zero > "$HOME/.cache/marv/mlx/venvs/x"
chat_sentinel="$HOME/.cache/marv/mlx/chats/keep.json"
head -c 128 /dev/zero > "$chat_sentinel"
marv-mlx clean --all >/dev/null 2>&1; check 0 "$?" "clean --all exit=0"
[[ -f "$chat_sentinel" ]] && print "ok: clean --all preserved chat history" \
  || { print -u2 "FAIL: clean --all deleted chats"; fail=1; }
[[ -e "$HOME/.cache/marv/mlx/venvs/x" ]] \
  && { print -u2 "FAIL: clean --all left venvs"; fail=1; } \
  || print "ok: clean --all removed venvs"

# Real-lsof integration. The stub above hard-codes the exact `-F` output shape a
# buggy flag set would omit, so it cannot catch a wrong lsof field list. Verify
# _marv_mlx_servers_running against an actual listener, with the stub delegating
# to the real lsof (MARV_TEST_REAL_LSOF). Polls for the bind rather than a fixed
# sleep, and prints the raw lsof output on failure so a runner difference is
# diagnosable instead of a bare 'got nothing'.
if command -v python3 >/dev/null 2>&1; then
  real_lsof=""
  for p in /usr/sbin/lsof /usr/bin/lsof /sbin/lsof; do
    [ -x "$p" ] && { real_lsof="$p"; break; }
  done
  if [ -z "$real_lsof" ]; then
    print "note: real-lsof listener check skipped (no lsof on this host)"
  else
    source "$repo/lib/marv-mlx-helpers.zsh"
    python3 -m http.server 11507 >/dev/null 2>&1 &
    srv_pid=$!
    got=""
    for _ in {1..20}; do
      got="$(MARV_TEST_REAL_LSOF=1 _marv_mlx_servers_running)"
      [[ "$got" == *"11507"* ]] && break
      sleep 0.5
    done
    kill "$srv_pid" 2>/dev/null
    if [[ "$got" == *"11507"* ]]; then
      print "ok: servers_running detects a real listener"
    else
      print -u2 "FAIL: servers_running missed a real listener (got '$got')"
      print -u2 "  lsof: $real_lsof ; lsof on PATH resolves to: $(command -v lsof)"
      print -u2 "  raw real-lsof output for :11507:"
      MARV_TEST_REAL_LSOF=1 lsof -nP -Fpcn -iTCP:11507 -sTCP:LISTEN 2>&1 | sed 's/^/    /' >&2
      fail=1
    fi
  fi
fi

exit $fail
