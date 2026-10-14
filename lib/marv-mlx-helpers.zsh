# marv-mlx helpers — self-contained, arg-driven utilities extracted from the main
# marv-mlx() body. None of these read marv-mlx()'s locals. Sourced once by marv-mlx.zsh
# before marv-mlx() is defined.

# Pick a beginner-friendly editor: micro > nano > $EDITOR/$VISUAL > vi.
_marv_mlx_pick_editor() {
  if command -v micro >/dev/null 2>&1; then echo micro
  elif command -v nano >/dev/null 2>&1; then echo nano
  elif [[ -n "$VISUAL" ]] && command -v "${VISUAL%% *}" >/dev/null 2>&1; then echo "$VISUAL"
  elif [[ -n "$EDITOR" ]] && command -v "${EDITOR%% *}" >/dev/null 2>&1; then echo "$EDITOR"
  else echo vi
  fi
}

# Replace --flag value in a named array, or append if absent.
_marv_mlx_replace_or_append() {
  local name="$1" flag="$2" value="$3"
  local -a arr
  eval "arr=( \"\${${name}[@]}\" )"
  local i found=0
  for (( i=1; i<=${#arr[@]}; i++ )); do
    if [[ "${arr[i]}" == "$flag" ]]; then
      arr[i+1]="$value"
      found=1
      break
    fi
  done
  (( found )) || arr+=( "$flag" "$value" )
  eval "${name}=( \"\${arr[@]}\" )"
}

# Return 0 if semver-ish $1 > $2 (numeric dot-separated fields; non-numeric
# fields count as 0 — enough to compare marv-mlx releases). Handles "v" prefixes
# and unequal field counts (0.1 == 0.1.0).
_marv_mlx_version_gt() {
  local v1="${1#v}" v2="${2#v}"
  local -a a=("${(ps:.:)v1}") b=("${(ps:.:)v2}")
  local i n x y
  (( n = ${#a} > ${#b} ? ${#a} : ${#b} ))
  for (( i=1; i<=n; i++ )); do
    x="${a[$i]-0}"; y="${b[$i]-0}"
    [[ "$x" == <-> ]] || x=0
    [[ "$y" == <-> ]] || y=0
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 1
}

# Ensure (add=1) or remove (add=0) a valueless flag in a named array (e.g.
# --enable-thinking). Removes duplicates, then appends if adding.
_marv_mlx_flag_set() {
  local name="$1" flag="$2" add="$3"
  local -a arr out
  eval "arr=( \"\${${name}[@]}\" )"
  local i
  for (( i=1; i<=${#arr[@]}; i++ )); do
    [[ "${arr[i]}" == "$flag" ]] && continue
    out+=( "${arr[i]}" )
  done
  (( add )) && out+=( "$flag" )
  eval "${name}=( \"\${out[@]}\" )"
}

# ---------------------------------------------------------------------------
# Terminal screen state.
#
# The interactive TUI runs on the alternate screen buffer (?1049) so quitting
# restores whatever the shell showed before: no leftover marv-mlx banner, no
# destroyed scrollback. _MARV_MLX_TUI_ACTIVE tracks whether we own the alt buffer so
# a single restore path (also used by the EXIT trap) stays idempotent.
# ---------------------------------------------------------------------------
typeset -g _MARV_MLX_TUI_ACTIVE=0

_marv_mlx_tui_enter() {
  (( _MARV_MLX_TUI_ACTIVE )) && return 0
  _MARV_MLX_TUI_ACTIVE=1
  print -n -- $'\e[?1049h\e[H\e[2J'
}

_marv_mlx_tui_leave() {
  (( _MARV_MLX_TUI_ACTIVE )) || return 0
  _MARV_MLX_TUI_ACTIVE=0
  print -n -- $'\e[0m\e[?25h\e[?1049l'
}

# One-time, idempotent migration from the old `ymlx` layout. Runs on every
# launch but only acts when the old state exists and the new one doesn't yet.
# Copy-then-switch: the old tree is left intact for one release so a downgrade
# still works.
_marv_mlx_migrate_legacy_state() {
  local old="$HOME/.cache/ymlx"
  local new="$HOME/.cache/marv/mlx"
  _marv_mlx_migrate_state_dir "$old" "$new"
  _marv_mlx_migrate_config "$new/config.zsh"
  _marv_mlx_migrate_zshrc "$HOME/.zshrc"
  _marv_mlx_migrate_pi_files
  return 0
}

# Copy old runtime state to the shared marv cache root (target-absent guard).
_marv_mlx_migrate_state_dir() {
  local old="$1" new="$2"
  if [[ -d "$old" && ! -e "$new" ]]; then
    mkdir -p "${new:h}"
    cp -R "$old" "$new" 2>/dev/null && \
      print -u2 "marv-mlx: migrated state $old -> $new"
  fi
}

# Rewrite the managed-block markers and legacy `YMLX_*` names in config.zsh.
_marv_mlx_migrate_config() {
  local cf="$1"
  [[ -f "$cf" ]] || return 0
  if grep -q '^# >>> ymlx-managed' "$cf" 2>/dev/null; then
    sed -i '' 's/^# >>> ymlx-managed/# >>> marv-mlx-managed/; s/^# <<< end ymlx-managed/# <<< end marv-mlx-managed/' "$cf"
  fi
  if grep -q '^YMLX_' "$cf" 2>/dev/null; then
    sed -i '' 's/^\(YMLX_\)/MARV_MLX_/' "$cf"
  fi
}

# Fix the launcher line in ~/.zshrc. Deliberately narrow: only lines that name
# this project's launcher (ymlx/marv-mlx) are touched, so sibling launchers
# (wren, err, marv, …) are never rewritten.
_marv_mlx_migrate_zshrc() {
  local zshrc="$1"
  [[ -f "$zshrc" ]] || return 0
  # Prefer the directory marv-mlx.zsh exported at source time; fall back to $0.
  local src_dir="${_MARV_MLX_SRC_DIR:-${0:A:h}}"
  local target="$src_dir/marv-mlx-launcher.zsh"
  grep -qE '(ymlx|marv-mlx)-launcher\.zsh' "$zshrc" 2>/dev/null || return 0
  # Already pointing at the right path? Nothing to do (idempotent).
  grep -qF "$target" "$zshrc" 2>/dev/null && \
    ! grep -q '^# ymlx$' "$zshrc" 2>/dev/null && return 0

  local tmp="$zshrc.marv-mlx.tmp" line changed=0
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *ymlx-launcher.zsh* || "$line" == *marv-mlx-launcher.zsh* ]]; then
      # Rewrite the first quoted path so the surrounding line shape (comment,
      # `source "…"`, indentation) is preserved.
      if [[ "$line" == *\"*\"* ]]; then
        local head="${line%%\"*}"  # text before the opening quote
        local rest="${line#*\"}"   # text after the opening quote
        local tail="${rest#*\"}"  # text after the closing quote
        line="${head}\"${target}\"${tail}"
      else
        line="$target"
      fi
      changed=1
    fi
    [[ "$line" == '# ymlx' ]] && { line='# marv-mlx'; changed=1; }
    print -r -- "$line" >> "$tmp"
  done < "$zshrc"
  if (( changed )); then
    mv "$tmp" "$zshrc"
    print -u2 "marv-mlx: updated ~/.zshrc launcher line"
  else
    rm -f "$tmp"
  fi
}

# Replace the stale `ymlx` pi wrapper with a forwarding stub and drop the old
# extension copy. The stub is (re)created whenever a legacy install is detected
# (old wrapper present, or the old state dir exists), so an interrupted earlier
# migration cannot leave the alias missing.
_marv_mlx_migrate_pi_files() {
  local old_wrapper="$HOME/.pi/agent/bin/ymlx"
  local legacy_detected=0
  [[ -f "$old_wrapper" || -d "$HOME/.cache/ymlx" ]] && legacy_detected=1
  if (( legacy_detected )) && ! grep -q 'renamed to marv-mlx' "$old_wrapper" 2>/dev/null; then
    mkdir -p "$HOME/.pi/agent/bin"
    cat > "$old_wrapper" <<'EOF_YMLX'
#!/usr/bin/env bash
# Deprecated alias written by the marv-mlx migration; forwards to marv-mlx.
echo "ymlx has been renamed to marv-mlx; run 'marv-mlx' instead." >&2
exec marv-mlx "$@"
EOF_YMLX
    chmod +x "$old_wrapper"
  fi
  [[ -f "$HOME/.pi/agent/extensions/ymlx-sync.ts" ]] && rm -f "$HOME/.pi/agent/extensions/ymlx-sync.ts"
}

# Print a line on the NORMAL screen, leaving the alt buffer first so it stays
# visible in scrollback after marv-mlx exits (rather than being swallowed with the
# alt screen).
_marv_mlx_print_normal() {
  _marv_mlx_tui_leave
  print -r -- "$@"
}

# CLI help. Lives here (not inside marv-mlx()) so the --help fast path can print it
# before any of the TUI helpers are defined.
_marv_mlx_usage() {
  cat <<'USAGE'
marv-mlx — local MLX model manager + OpenAI-compatible server on :11500

Usage:
  marv-mlx                        interactive TUI (browse / run / download)
  marv-mlx run <model>            start a model on :11500 (detached) and wait
  marv-mlx chat <model>           start a model and open the built-in chat REPL
  marv-mlx stop [<model>|--all]   stop a running model (default: the one on :11500)
  marv-mlx status [--json]        show what is running
  marv-mlx list [--json]          list locally installed models
  marv-mlx download <model>...    download model(s) from the HuggingFace Hub
  marv-mlx curated [--json]       show the full curated model catalog (all tiers)
  marv-mlx info <model> [--json]  show details for a model (size, family, thinking)
  marv-mlx cache [--json]         show on-disk footprint (APC, logs, hub, tool env)
  marv-mlx clean --apc|--logs|--venvs|--all [--dry-run] [--force]
                                  delete regenerable caches (never model weights)
  marv-mlx endpoint [--json]      print the base URL / model of the running server
  marv-mlx version | -v           print the marv-mlx version
  marv-mlx help | -h | --help     show this help

Commands print data on stdout and human logs on stderr, so they compose; pass
--json where offered for machine-readable output. Exit codes: 0 ok, 1 failure,
2 usage error.
USAGE
}

# Parse the curated catalog (the repo's bundled curated-llms.md) into flat,
# all-tiers model rows. Emits one US-delimited (\x1f) line per distinct entry:
#
#   tier<US>tier_name<US>title<US>ids<US>tags<US>description
#
# `tier` is the numeric tier used for matching (8/16/32) and `tier_name` is the
# header line exactly as written in the source (e.g. "8 GB RAM Tier Models") —
# consumers display that verbatim instead of rebuilding it from the number.
#
# The delimiter is ASCII US (unit separator), NOT a tab: zsh's `read` collapses
# repeated IFS *whitespace*, so a tab-delimited empty field (e.g. no tags) would
# silently shift every later field. US is not whitespace, so empty fields survive.
# line containing "GB RAM". Entries may be '#'-commented; the marker is stripped
# so the full catalog shows (the '#' only highlights the hand-picked picks).
#
# Current format: blank-line-separated 2-line blocks of
#
#   <model-id>
#   <tagline>
#
# The model id is authoritative and doubles as the entry name; the tagline is a
# short human description. Legacy shapes are still accepted so an older cached
# copy keeps working:
#   * 3-line title-first:  <title> / <id(s)> / <tags>
#   * 2-line id/tags:      <id> / <tags>
#   * leading flag emoji:  "<flag> <id>" (cosmetic, peeled)
# Shared by the TUI download menu and `marv-mlx curated`.
_marv_mlx_parse_catalog() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  local _MARV_MLX_US=$'\x1f'
  local line current_tier=0 current_tier_name=""
  local -a entry=()
  _marv_mlx_catalog_flush() {
    ((${#entry[@]})) || return
    local a="${entry[1]}" b="${entry[2]:-}" c="${entry[3]:-}"
    entry=()
    [[ -n "$a" ]] || return
    # Legacy leading flag emoji: emoji carry no ASCII alphanumerics, so a first
    # whitespace-delimited token without any is a flag — peel it off.
    if [[ "$a" == *" "* ]]; then
      local f="${a%% *}"
      [[ "$f" != *[A-Za-z0-9]* ]] && a="${a#* }"
    fi
    local title="" ids="" tags="" desc=""
    if [[ "$a" == */* ]]; then
      # id-first block (the current format): '<id>' then a tagline. There is no
      # separate title in the source, so the entry name IS the model id.
      # A second line with spaces but no comma is the tagline (description);
      # otherwise it is a legacy tags token list.
      ids="$a"
      if [[ -n "$b" && "$b" == *" "* && "$b" != *,* ]]; then
        desc="$b"
      else
        tags="$b"; desc="$c"
      fi
      # ${(s:..:)x}[1] mis-subscripts when the split yields one word, so split
      # into an array first. The id list is ' & '-joined.
      local -a parts=( ${(s: & :)ids} )
      title="${parts[1]}"
    elif [[ -n "$b" ]]; then
      # legacy title-first 3-line block
      title="$a"; ids="$b"; tags="$c"
    else
      # bare id line
      ids="$a"; title="$a"
    fi
    print -r -- "$current_tier${_MARV_MLX_US}$current_tier_name${_MARV_MLX_US}$title${_MARV_MLX_US}$ids${_MARV_MLX_US}$tags${_MARV_MLX_US}$desc"
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      _marv_mlx_catalog_flush
      continue
    fi
    if [[ "$line" == *"GB RAM"* ]]; then
      _marv_mlx_catalog_flush
      current_tier="${line//[^0-9]/}"
      # Keep the header verbatim for display (trim surrounding whitespace).
      current_tier_name="${line##[[:space:]]#}"
      current_tier_name="${current_tier_name%%[[:space:]]#}"
      continue
    fi
    if [[ "$line" == \#* ]]; then
      line="${line#\#}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    entry+=( "$line" )
  done < "$file"
  _marv_mlx_catalog_flush
}

# Pad a string to a display width with trailing spaces (printf pads by
# character count, which is enough for the ASCII titles/ids in the catalog
# table after flag emojis are stripped).
_marv_mlx_pad() {
  printf '%-*s' "$2" "$1"
}

# Escape a string for embedding in a JSON double-quoted value (the CLI's
# --json output). Escapes backslash, quote, and control chars; yields the
# string WITHOUT surrounding quotes.
_marv_mlx_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  print -rn -- "$s"
}

# Is TCP port $1 free (nothing listening)?
_marv_mlx_port_free() {
  ! lsof -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# marv-mlx prefers :11500 so agentic CLIs always find the model, and falls back to
# the next free port so a second model can run in parallel.
_marv_mlx_find_port() {
  local p
  for p in {11500..11509}; do
    if _marv_mlx_port_free "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo ""
  return 1
}

# Auto-advance after a status message. Replaces the old "press enter to
# continue" prompts so marv-mlx moves on by itself instead of asking to hit Enter;
# the short pause still lets a result line be read before the next screen.
_marv_mlx_pause() {
  sleep 0.7
}

# Friendly display name: drop the org prefix (e.g. `mlx-community/`).
_marv_mlx_friendly_name() {
  print -r -- "${1##*/}"
}

_marv_mlx_display_name() {
  _marv_mlx_friendly_name "$1"
}

# Ministral ships as an Instruct+Reasoning pair (two separate model ids).
# If $1 is one half of a pair, echo the sibling full id and return 0;
# otherwise return 1.
_marv_mlx_ministral_sibling() {
  local m="$1" base="${1##*/}" sib
  if [[ "$base" == *-Instruct-* ]]; then
    sib="${base/-Instruct-/-Reasoning-}"
  elif [[ "$base" == *-Reasoning-* ]]; then
    sib="${base/-Reasoning-/-Instruct-}"
  else
    return 1
  fi
  print -r -- "${m%/*}/$sib"
}

# Base display name for a Ministral half, e.g.
#   mlx-community/Ministral-3-3B-Instruct-2512-4bit -> Ministral-3-3B-4bit
_marv_mlx_ministral_base() {
  print -r -- "$(print -r -- "${1##*/}" | sed -E 's/-([Ii]nstruct|[Rr]easoning)-[^-]+-/-/')"
}

# Classify a model into a thinking family. Reads model_type from the cached
# config.json ($2 = HF hub dir), falling back to the id.
#   qwen | gemma | ministral-reasoning | ministral-instruct | lfm | generic
_marv_mlx_model_family() {
  local model="$1" hub_dir="$2" base="${1##*/}" mt="" snap
  if [[ -n "$hub_dir" ]]; then
    snap=$(ls -d "$hub_dir/models--${model//\//--}"/snapshots/*(N/) 2>/dev/null | head -n1)
    [[ -n "$snap" && -f "$snap/config.json" ]] \
      && mt=$(sed -n 's/.*"model_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$snap/config.json" | head -n1)
  fi
  case "$mt" in
    qwen*) echo qwen; return ;;
    gemma*) echo gemma; return ;;
    lfm*) echo lfm; return ;;
    mistral3|ministral3)
      [[ "$base" == *-Reasoning-* ]] && echo ministral-reasoning || echo ministral-instruct
      return ;;
  esac
  case "$base" in
    *Qwen*|*qwen*) echo qwen ;;
    *[Gg]emma*) echo gemma ;;
    *LFM*|*lfm*) echo lfm ;;
    *Ministral*|*ministral*)
      [[ "$base" == *-Reasoning-* ]] && echo ministral-reasoning || echo ministral-instruct ;;
    *) echo generic ;;
  esac
}

# Thinking spec for a model: control<TAB>markers<TAB>reasoning-first.
#   control: enable_thinking (template bool) | variant (model id decides) | none
#   markers: think (<think>) | channel (<|channel>thought) | bracket ([THINK]) | none
#   reasoning-first: 1 when the trace starts immediately (Ministral Reasoning)
_marv_mlx_thinking_spec() {
  case "$(_marv_mlx_model_family "$1" "$2")" in
    qwen)                 print -r -- $'enable_thinking\tthink\t0' ;;
    gemma)                print -r -- $'enable_thinking\tchannel\t0' ;;
    ministral-reasoning)  print -r -- $'variant\tbracket\t1' ;;
    ministral-instruct)   print -r -- $'variant\tnone\t0' ;;
    lfm)                  print -r -- $'none\tthink\t0' ;;
    *)                    print -r -- $'enable_thinking\tthink\t0' ;;
  esac
}

# Mutate the named server-flag array ($1) for launching $2 (a model id) with
# $3 the HF hub dir:
#   * drop any stale/hand-written --enable-thinking, then add it iff the user's
#     toggle is explicitly "on" (the resolved default for API clients; the REPL
#     still sends the value per request);
#   * add Ministral's [THINK]/[/THINK] markers so the server splits its trace
#     into reasoning_content even outside the REPL.
_marv_mlx_apply_launch_thinking() {
  local name="$1" model="$2" hub_dir="$3"
  local spec markers
  spec=$(_marv_mlx_thinking_spec "$model" "$hub_dir")
  spec="${spec#*$'\t'}"
  markers="${spec%%$'\t'*}"
  _marv_mlx_flag_set "$name" --enable-thinking 0
  [[ "${MARV_MLX_QUICK_THINKING:-default}" == "on" ]] \
    && _marv_mlx_flag_set "$name" --enable-thinking 1
  if [[ "$markers" == "bracket" ]]; then
    _marv_mlx_replace_or_append "$name" --thinking-start-token "[THINK]"
    _marv_mlx_replace_or_append "$name" --thinking-end-token "[/THINK]"
  fi
}

# _marv_mlx_export_apc_env [state_dir]
# Export mlx-vlm's Automatic Prefix Caching (APC) switches for the server
# subprocess. mlx-vlm 0.7.4 ships APC but leaves it off by default, and
# mlx_vlm.server exposes no --apc flag -- the environment is the only switch.
# Without it every chat turn re-prefills the whole conversation (the server log
# shows cached_tokens=0), so long contexts stall on prefill each turn.
#
# Pre-set values win, so config.zsh / the shell can override anything. Opt out
# with MARV_MLX_APC=0 (or APC_ENABLED=0). The disk tier is pointed under
# marv-mlx's state dir instead of mlx-vlm's global ~/.cache/mlx-vlm/apc.
_marv_mlx_export_apc_env() {
  local state_dir="${1:-$HOME/.cache/marv/mlx}"
  local apc_opt="${MARV_MLX_APC:-1}"
  case "${apc_opt:l}" in
    (0|off|false|no) return 0 ;;
  esac
  export APC_ENABLED="${APC_ENABLED:-1}"
  export APC_DISK_ENABLED="${APC_DISK_ENABLED:-1}"
  export APC_DISK_PATH="${APC_DISK_PATH:-$state_dir/apc}"
  export APC_DISK_MAX_GB="${APC_DISK_MAX_GB:-5}"
  # Hybrid models (e.g. Qwen3.5's interleaved linear/full attention) cannot be
  # prefix-trimmed like plain K/V, so APC restores whole-cache checkpoints at
  # boundaries. 512 tokens keeps the un-cached suffix short without a large
  # memory cost; raise it on bigger conversations or lower it for tighter hits.
  export APC_CHECKPOINT_INTERVAL_TOKENS="${APC_CHECKPOINT_INTERVAL_TOKENS:-512}"
  export APC_CHECKPOINT_ENTRIES="${APC_CHECKPOINT_ENTRIES:-2}"
  return 0
}

# _marv_mlx_install_apc_sitecustomize [src] [tools_dir]
# Install the APC sitecustomize payload (lib/marv-mlx-apc-sitecustomize.py) into
# the mlx-vlm uv tool env, so servers launched by ANY tool get prefix caching
# on — not just marv-mlx's own launches (which already get it via the env above)
# but also foreign ones: the marv harness's embedded launch and manual
# `mlx_vlm.server` calls. It runs at interpreter startup (sitecustomize.py) and
# defaults the same APC_* variables with setdefault, so explicit env still wins.
#
# marv-mlx re-runs this on startup: a `uv tool update` reinstalls the tool env
# and drops the file. Idempotent (content-compare); a sitecustomize.py that is
# not ours is left untouched.
_marv_mlx_install_apc_sitecustomize() {
  local src="${1:-}" tools_dir="${2:-}" sp
  local marker="marv-mlx APC sitecustomize"
  [[ -n "$src" ]] || src="${_MARV_MLX_SRC_DIR:-$HOME}/lib/marv-mlx-apc-sitecustomize.py"
  [[ -r "$src" ]] || return 0
  if [[ -z "$tools_dir" ]]; then
    tools_dir="$(uv tool dir 2>/dev/null)"
    [[ -n "$tools_dir" && -d "$tools_dir" ]] || tools_dir="$HOME/.local/share/uv/tools"
  fi
  local -a sps=( "$tools_dir"/mlx-vlm/lib/python*/site-packages(N) )
  for sp in "${sps[@]}"; do
    [[ -d "$sp" ]] || continue
    if [[ -f "$sp/sitecustomize.py" ]] \
       && ! grep -q "$marker" "$sp/sitecustomize.py" 2>/dev/null; then
      print -u2 "marv-mlx: foreign sitecustomize.py in $sp — not touching it (APC defaults not installed)"
      continue
    fi
    if ! cmp -s "$src" "$sp/sitecustomize.py" 2>/dev/null; then
      cp -f "$src" "$sp/sitecustomize.py" 2>/dev/null || continue
    fi
  done
  return 0
}

# _marv_mlx_purge_orphan_blobs <hub_dir>
# After a model folder is rm -rf'd, its large weight blobs may still sit in the
# shared store hub/blobs/{shard}/. This sweeps that store and removes any blob
# no cached model folder still references via a symlink (deduplicated across
# the whole hub). Also removes the blob's .refs and .lock sidecars.
# Prints a summary of what was freed; non-fatal if the store isn't present.
_marv_mlx_purge_orphan_blobs() {
  local hub_dir="$1"
  # Canonicalize early so later realpath output (/private/tmp on macOS) matches
  # the hub_dir-derived blob paths below.
  hub_dir="$(/bin/realpath "$hub_dir" 2>/dev/null)"
  [[ -d "$hub_dir/blobs" ]] || return 0
  setopt localoptions null_glob

  # Build the set of blob paths still referenced by any symlink in model dirs.
  # realpath resolves the full chain: snapshot -> model blobs -> shared store.
  local -A used=()
  local link real
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    real="$(/bin/realpath "$link" 2>/dev/null)"
    [[ -n "$real" ]] && used[$real]=1
  done < <(find "$hub_dir"/models--* -type l 2>/dev/null)

  local shard blob base size
  local removed=0 freed_bytes=0
  for shard in "$hub_dir"/blobs/*/; do
    [[ -d "$shard" ]] || continue
    for blob in "$shard"*; do
      [[ -f "$blob" ]] || continue
      base="${blob:t}"
      # skip shared-store sidecars / marker; only real data blobs
      [[ "$base" == *.refs || "$base" == *.lock ]] && continue
      if [[ -z "${used[$blob]}" ]]; then
        size="$(/usr/bin/stat -f%z "$blob" 2>/dev/null)"
        size="${size:-0}"
        freed_bytes=$(( freed_bytes + size ))
        rm -f "$blob" "${blob}.refs" "${blob}.lock"
        removed=$(( removed + 1 ))
      fi
    done
  done

  if (( removed > 0 )); then
    print -r -- "Freed $removed orphaned shared blob(s): $freed_bytes bytes"
  fi
}

# ---- on-disk footprint + hygiene (`marv-mlx cache` / `marv-mlx clean`) --------
#
# Self-contained on purpose: both verbs run BEFORE marv-mlx.zsh's gum/curl/
# mlx-vlm tool check (reporting the footprint should work on a half-broken
# install), so they cannot rely on marv-mlx()'s locals or on functions defined
# inside its body.

# _marv_mlx_du_bytes <dir> — apparent size in bytes; 0 when the path is absent.
# NOTE: the local must NOT be named `path` — in zsh `path` is the special array
# tied to PATH, so `local path=...` silently replaces your command search path.
_marv_mlx_du_bytes() {
  local target="$1" kib
  [[ -e "$target" ]] || { print -r -- 0; return 0 }
  kib="$(du -sk "$target" 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$kib" ]] || kib=0
  print -r -- $(( kib * 1024 ))
}

# _marv_mlx_fmt_bytes <bytes> — base-1024 human size with one decimal.
_marv_mlx_fmt_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
  }'
}

# _marv_mlx_servers_running — emit "pid<TAB>port" for marv-mlx's server ports.
# Port-based, not name-based: the server renames itself to the model name via
# setproctitle (MARV_MLX_PROCTITLE), so `pgrep mlx_vlm.server` misses it.
_marv_mlx_servers_running() {
  command -v lsof >/dev/null 2>&1 || return 0
  # `-Fpcn`: `n` (the internet address) is NOT emitted by default. With only
  # `pc`, lsof prints p/c/f lines and no `n`, so the awk below silently yields
  # nothing and the live-server guard never fires. Verified against macOS lsof.
  lsof -nP -Fpcn -iTCP:11500-11509 -sTCP:LISTEN 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^n/ { port = substr($0, 2); sub(/.*:/, "", port); if (pid != "") print pid "\t" port }
  '
}

# _marv_mlx_last_cached_tokens <log_dir> — APC reuse of the most recent request
# in the newest server log, or empty when no server has logged yet. `grep -a`
# because a log can contain binary blobs, and the digits guard keeps a stray
# match from corrupting the --json payload.
_marv_mlx_last_cached_tokens() {
  local log_dir="$1" n
  [[ -d "$log_dir" ]] || return 0
  local -a logs=( "$log_dir"/*.log(Nom) )
  (( ${#logs[@]} )) || return 0
  n="$(grep -a -o 'cached_tokens=[0-9]*' "${logs[1]}" 2>/dev/null | tail -n 1 | sed 's/cached_tokens=//')"
  [[ "$n" == <-> ]] && print -r -- "$n"
  return 0
}

# _marv_mlx_cache_report [state_dir] [hub_dir] [tools_dir]
# TSV, one row per location: <key><TAB><bytes><TAB><path><TAB><removable 0|1>.
# `removable` marks what `marv-mlx clean` may delete — regenerable caches only.
# Model weights and chat history are reported but never disposable.
_marv_mlx_cache_report() {
  local state_dir="${1:-$HOME/.cache/marv/mlx}"
  local hub_dir="${2:-$HOME/.cache/huggingface/hub}"
  local tools_dir="${3:-}"
  if [[ -z "$tools_dir" ]] && command -v uv >/dev/null 2>&1; then
    tools_dir="$(uv tool dir 2>/dev/null)"
  fi
  [[ -n "$tools_dir" ]] || tools_dir="$HOME/.local/share/uv/tools"

  local -a keys=( apc logs chats venvs hub env )
  # `apc` follows the effective APC_DISK_PATH (set by _marv_mlx_export_apc_env)
  # so the report and `clean --apc` agree on the same directory. `venvs` is a
  # legacy path older builds / manual experiments left under the state dir.
  local -a paths=(
    "${APC_DISK_PATH:-$state_dir/apc}" "$state_dir/logs" "$state_dir/chats" "$state_dir/venvs"
    "$hub_dir" "$tools_dir/mlx-vlm"
  )
  local -a removable=( 1 1 0 1 0 0 )
  local i
  for (( i = 1; i <= ${#keys[@]}; i++ )); do
    print -r -- "${keys[$i]}"$'\t'"$(_marv_mlx_du_bytes "${paths[$i]}")"$'\t'"${paths[$i]}"$'\t'"${removable[$i]}"
  done
}

# Usage lines for the two hygiene verbs (also printed on --help).
_marv_mlx_cache_usage() {
  print -r -- "usage: marv-mlx cache [--json]"
}

_marv_mlx_clean_usage() {
  print -r -- "usage: marv-mlx clean [--apc|--logs|--venvs|--all] [--dry-run] [--force]"
}

# _marv_mlx_cache_cmd <state_dir> <hub_dir> <log_dir> [--json] — `marv-mlx cache`.
_marv_mlx_cache_cmd() {
  local state_dir="$1" hub_dir="$2" log_dir="$3"
  shift 3
  local json=0 a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      --help|-h) _marv_mlx_cache_usage; return 0 ;;
      *) print -u2 "marv-mlx cache: unknown option '$a'"; _marv_mlx_cache_usage >&2; return 2 ;;
    esac
  done

  # Is APC actually on? `MARV_MLX_APC`/`APC_ENABLED` opt-outs win, and the
  # export helper returns early on opt-out without setting APC_ENABLED — so this
  # must be computed BEFORE calling it, not read back from it.
  local enabled=1
  case "${MARV_MLX_APC:-}" in (0|off|false|no) enabled=0 ;; esac
  case "${APC_ENABLED:-}" in (0|off|false|no) enabled=0 ;; esac
  _marv_mlx_export_apc_env "$state_dir"

  # Numeric settings are interpolated into the JSON payload, so coerce a
  # non-numeric env override back to the default rather than emit invalid JSON.
  local cap iv ent
  cap="${APC_DISK_MAX_GB:-5}";          [[ "$cap" == <-> ]] || cap=5
  iv="${APC_CHECKPOINT_INTERVAL_TOKENS:-512}"; [[ "$iv" == <-> ]] || iv=512
  ent="${APC_CHECKPOINT_ENTRIES:-2}";    [[ "$ent" == <-> ]] || ent=2

  local -a keys=() sizes=() paths=() rem=()
  local k b p r
  while IFS=$'\t' read -r k b p r; do
    keys+=( "$k" ); sizes+=( "$b" ); paths+=( "$p" ); rem+=( "$r" )
  done < <(_marv_mlx_cache_report "$state_dir" "$hub_dir")
  local ct; ct="$(_marv_mlx_last_cached_tokens "$log_dir")"

  if (( json )); then
    printf '{"state_dir":"%s","apc":{"enabled":%s,"disk_path":"%s","disk_max_gb":%s,"checkpoint_interval_tokens":%s,"checkpoint_entries":%s},"cached_tokens_last":%s,"sizes":{' \
      "$(_marv_mlx_json_escape "$state_dir")" "$enabled" \
      "$(_marv_mlx_json_escape "${APC_DISK_PATH:-}")" \
      "$cap" "$iv" "$ent" \
      "${ct:-null}"
    local i first=1
    for (( i = 1; i <= ${#keys[@]}; i++ )); do
      (( first )) || print -n ','
      first=0
      printf '"%s":%s' "$(_marv_mlx_json_escape "${keys[$i]}")" "${sizes[$i]}"
    done
    print '}}'
    return 0
  fi

  local i total=0 mark
  printf 'marv-mlx cache — %s\n\n' "$state_dir"
  printf '  %-10s %-9s %s\n' "SIZE" "CATEGORY" "PATH"
  for (( i = 1; i <= ${#keys[@]}; i++ )); do
    mark=" "
    (( rem[i] )) && mark="*"
    printf '  %-10s %s%-8s %s\n' \
      "$(_marv_mlx_fmt_bytes "${sizes[$i]}")" "$mark" "${keys[$i]}" "${paths[$i]}"
    (( total += sizes[i] ))
  done
  printf '\n  %s total\n\n' "$(_marv_mlx_fmt_bytes "$total")"
  print "  * = regenerable; remove with 'marv-mlx clean <category>'"
  print "  APC: enabled=$enabled  cap=${cap}GB  interval=${iv} tokens  entries=${ent}"
  [[ -n "$ct" ]] && print "  APC last request: cached_tokens=$ct"
  return 0
}

# _marv_mlx_clean_cmd <state_dir> <hub_dir> [--apc|--logs|--venvs|--all]
#                                       [--dry-run] [--force]
# Deletes regenerable caches only — never the weight hub or chat history, and
# never anything by default (no args is a usage error, so a stray `clean` cannot
# destroy state).
_marv_mlx_clean_cmd() {
  local state_dir="$1" hub_dir="$2"
  shift 2
  local dry=0 force=0 a
  local -a want=()
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --force|-f) force=1 ;;
      --apc|--logs|--venvs) want+=( "${a#--}" ) ;;
      --all) want=( apc logs venvs ) ;;
      --help|-h) _marv_mlx_clean_usage; return 0 ;;
      *) print -u2 "marv-mlx clean: unknown option '$a'"; _marv_mlx_clean_usage >&2; return 2 ;;
    esac
  done
  if (( ${#want[@]} == 0 )); then
    print -u2 "marv-mlx clean: nothing selected — refusing to delete by default."
    _marv_mlx_clean_usage >&2
    print -u2 ""
    print -u2 "See sizes first:  marv-mlx cache"
    return 2
  fi

  # Resolve the APC dir the same way `cache` reports it, so the two agree.
  _marv_mlx_export_apc_env "$state_dir"

  # A live server has the APC checkpoints open; deleting them under it is
  # undefined, so require an explicit --force.
  local running; running="$(_marv_mlx_servers_running)"
  if (( ! dry )) && (( ! force )) && [[ " ${want[*]} " == *" apc "* ]] && [[ -n "$running" ]]; then
    local rline rp rport
    rline="${${(f)running}[1]}"
    rp="${rline%%$'\t'*}"
    rport="${rline##*$'\t'}"
    print -u2 "marv-mlx clean: a server is live on :$rport (pid $rp) and may hold APC files."
    print -u2 "Stop it ('marv-mlx stop') or pass --force."
    return 1
  fi

  local -a keys=() sizes=() paths=() rem=()
  local k b p r
  while IFS=$'\t' read -r k b p r; do
    keys+=( "$k" ); sizes+=( "$b" ); paths+=( "$p" ); rem+=( "$r" )
  done < <(_marv_mlx_cache_report "$state_dir" "$hub_dir")

  local kind target i freed=0 n=0 sz
  for kind in "${want[@]}"; do
    target=""
    for (( i = 1; i <= ${#keys[@]}; i++ )); do
      if [[ "${keys[$i]}" == "$kind" ]]; then
        (( rem[i] )) && target="${paths[$i]}"
        break
      fi
    done
    if [[ -z "$target" ]]; then
      print -u2 "marv-mlx clean: '$kind' is not a disposable category"
      return 2
    fi
    # Defence in depth: every disposable category lives under the state dir. A
    # drifted APC_DISK_PATH (or future category) must not turn this into an
    # arbitrary-path `rm -rf`.
    if [[ "$target" != "$state_dir"/* ]]; then
      print -u2 "marv-mlx clean: refusing to delete '$target' — outside the state dir ($state_dir)"
      return 1
    fi
    if [[ ! -e "$target" ]]; then
      print "marv-mlx: nothing to clean ($kind)"
      continue
    fi
    sz="$(_marv_mlx_du_bytes "$target")"
    if (( dry )); then
      print "would remove: $kind — $(_marv_mlx_fmt_bytes "$sz") ($target)"
      continue
    fi
    rm -rf "$target" 2>/dev/null || { print -u2 "marv-mlx clean: could not remove $target"; return 1; }
    freed=$(( freed + sz )); (( n++ ))
    print "removed: $kind — $(_marv_mlx_fmt_bytes "$sz")"
  done
  if (( dry )); then
    print "dry run — nothing removed"
    return 0
  fi
  print "marv-mlx: cleaned $n target(s), freed $(_marv_mlx_fmt_bytes "$freed")"
  return 0
}
