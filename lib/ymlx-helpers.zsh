# ymlx helpers — self-contained, arg-driven utilities extracted from the main
# ymlx() body. None of these read ymlx()'s locals. Sourced once by ymlx.zsh
# before ymlx() is defined.

# Pick a beginner-friendly editor: micro > nano > $EDITOR/$VISUAL > vi.
_ymlx_pick_editor() {
  if command -v micro >/dev/null 2>&1; then echo micro
  elif command -v nano >/dev/null 2>&1; then echo nano
  elif [[ -n "$VISUAL" ]] && command -v "${VISUAL%% *}" >/dev/null 2>&1; then echo "$VISUAL"
  elif [[ -n "$EDITOR" ]] && command -v "${EDITOR%% *}" >/dev/null 2>&1; then echo "$EDITOR"
  else echo vi
  fi
}

# Replace --flag value in a named array, or append if absent.
_ymlx_replace_or_append() {
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
# fields count as 0 — enough to compare ymlx releases). Handles "v" prefixes
# and unequal field counts (0.1 == 0.1.0).
_ymlx_version_gt() {
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
_ymlx_flag_set() {
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

# Is TCP port $1 free (nothing listening)?
_ymlx_port_free() {
  ! lsof -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# ymlx prefers :11500 so agentic CLIs always find the model, and falls back to
# the next free port so a second model can run in parallel.
_ymlx_find_port() {
  local p
  for p in {11500..11509}; do
    if _ymlx_port_free "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo ""
  return 1
}

# Auto-advance after a status message. Replaces the old "press enter to
# continue" prompts so ymlx moves on by itself instead of asking to hit Enter;
# the short pause still lets a result line be read before the next screen.
_ymlx_pause() {
  sleep 0.7
}

# Friendly display name: drop the org prefix (e.g. `mlx-community/`).
_ymlx_friendly_name() {
  print -r -- "${1##*/}"
}

_ymlx_display_name() {
  _ymlx_friendly_name "$1"
}

# Ministral ships as an Instruct+Reasoning pair (two separate model ids).
# If $1 is one half of a pair, echo the sibling full id and return 0;
# otherwise return 1.
_ymlx_ministral_sibling() {
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
_ymlx_ministral_base() {
  print -r -- "$(print -r -- "${1##*/}" | sed -E 's/-([Ii]nstruct|[Rr]easoning)-[^-]+-/-/')"
}

# Classify a model into a thinking family. Reads model_type from the cached
# config.json ($2 = HF hub dir), falling back to the id.
#   qwen | gemma | ministral-reasoning | ministral-instruct | lfm | generic
_ymlx_model_family() {
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
_ymlx_thinking_spec() {
  case "$(_ymlx_model_family "$1" "$2")" in
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
_ymlx_apply_launch_thinking() {
  local name="$1" model="$2" hub_dir="$3"
  local spec markers
  spec=$(_ymlx_thinking_spec "$model" "$hub_dir")
  spec="${spec#*$'\t'}"
  markers="${spec%%$'\t'*}"
  _ymlx_flag_set "$name" --enable-thinking 0
  [[ "${YMLX_QUICK_THINKING:-default}" == "on" ]] \
    && _ymlx_flag_set "$name" --enable-thinking 1
  if [[ "$markers" == "bracket" ]]; then
    _ymlx_replace_or_append "$name" --thinking-start-token "[THINK]"
    _ymlx_replace_or_append "$name" --thinking-end-token "[/THINK]"
  fi
}

# _ymlx_purge_orphan_blobs <hub_dir>
# After a model folder is rm -rf'd, its large weight blobs may still sit in the
# shared store hub/blobs/{shard}/. This sweeps that store and removes any blob
# no cached model folder still references via a symlink (deduplicated across
# the whole hub). Also removes the blob's .refs and .lock sidecars.
# Prints a summary of what was freed; non-fatal if the store isn't present.
_ymlx_purge_orphan_blobs() {
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
