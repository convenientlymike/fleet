#!/usr/bin/env bash
# lib.sh — shared helpers for Fleet (multi-window Claude Code coordination).
# Sourced by register.sh, guard.sh, awareness.sh, deregister.sh, fleet.sh.
# MUST stay bash 3.2-safe: no associative arrays, no ${var^^}, no mapfile/readarray.
# Reads may use jq -> python3 -> grep/sed (in that order). Writes are pure-bash JSON
# so the runtime never hard-depends on jq.

# ---- resolve locations (robust regardless of cwd) --------------------------
_FLEET_LIB_SRC="${BASH_SOURCE[0]}"
FLEET_BIN_DIR="$(cd "$(dirname "$_FLEET_LIB_SRC")" && pwd)"
FLEET_DIR="$(cd "$FLEET_BIN_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$FLEET_DIR/.." && pwd)"
STATE_DIR="$FLEET_DIR/state"
AGENTS_DIR="$STATE_DIR/agents"
CLAIMS_DIR="$STATE_DIR/claims"
INBOX_DIR="$STATE_DIR/inbox"
BOARD_FILE="$STATE_DIR/board.jsonl"
LEDGER_FILE="$STATE_DIR/ledger.jsonl"
CONFIG_FILE="$FLEET_DIR/config.json"
# shellcheck disable=SC2034  # consumed by scripts that source this lib (fleet.sh)
VERSION_FILE="$FLEET_DIR/VERSION"

# shellcheck disable=SC2034  # consumed by scripts that source this lib (fleet.sh)
FLEET_SCHEMA_VERSION="1"

# ---- tiny utilities --------------------------------------------------------
_have() { command -v "$1" >/dev/null 2>&1; }
log_err() { printf '%s\n' "$*" >&2; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

# mtime of a file as epoch seconds; BSD (macOS) then GNU.
mtime_epoch() {
  # GNU coreutils (Linux) uses `stat -c %Y`; BSD/macOS uses `stat -f %m`. Try GNU
  # first because BSD `-f` means --file-system on GNU and prints (to stdout) a
  # filesystem dump that would poison the arithmetic that consumes this. Guard the
  # result to digits so a surprising platform can never break `$(( ... ))`.
  local m=""
  m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || m=0
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

ensure_state() {
  mkdir -p "$AGENTS_DIR" "$CLAIMS_DIR" "$INBOX_DIR" 2>/dev/null || true
  [ -f "$BOARD_FILE" ]  || : >> "$BOARD_FILE"  2>/dev/null || true
  [ -f "$LEDGER_FILE" ] || : >> "$LEDGER_FILE" 2>/dev/null || true
}

# ---- config ----------------------------------------------------------------
# config_get <key> <default>  — reads a top-level scalar from config.json
config_get() {
  local key="$1" def="$2" val=""
  [ -f "$CONFIG_FILE" ] || { printf '%s' "$def"; return; }
  val="$(json_field_file "$CONFIG_FILE" "$key")"
  if [ -z "$val" ]; then printf '%s' "$def"; else printf '%s' "$val"; fi
}
stale_after() { config_get stale_after_s 180; }
claim_mode()  { config_get claim_mode prefix; }   # prefix | exact
block_mode()  { config_get block_mode block; }     # block  | warn

# ---- JSON reading (jq -> python3 -> grep/sed) ------------------------------
# json_field_str '<json text>' <key>  — extract a flat OR dotted string/number key.
# Dotted keys (e.g. tool_input.file_path) are supported by jq/python; the grep
# fallback only handles the LAST path segment as a flat key (best effort).
json_field_str() {
  local json="$1" key="$2" out=""
  if _have jq; then
    out="$(printf '%s' "$json" | jq -er ".${key} // empty" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
    return 0
  fi
  if _have python3; then
    out="$(printf '%s' "$json" | FLEET_KEY="$key" python3 -c '
import json,os,sys
key=os.environ["FLEET_KEY"]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
cur=d
for part in key.split("."):
    if isinstance(cur,dict) and part in cur:
        cur=cur[part]
    else:
        sys.exit(0)
if cur is None: sys.exit(0)
if isinstance(cur,(dict,list)):
    print(json.dumps(cur))
else:
    print(cur)
' 2>/dev/null)" && { printf '%s' "$out"; return 0; }
    return 0
  fi
  # grep/sed fallback: match the last segment as "key":"value" or "key":value
  local last="${key##*.}"
  out="$(printf '%s' "$json" \
    | tr -d '\n' \
    | sed -n 's/.*"'"$last"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)"
  if [ -z "$out" ]; then
    out="$(printf '%s' "$json" \
      | tr -d '\n' \
      | sed -n 's/.*"'"$last"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
      | head -1)"
  fi
  printf '%s' "$out"
}

# json_field_file <file> <key>
json_field_file() {
  local f="$1" key="$2"
  [ -f "$f" ] || return 0
  json_field_str "$(cat "$f" 2>/dev/null)" "$key"
}

# ---- JSON writing (pure bash, no deps) -------------------------------------
# json_escape <string>  — escape for embedding inside a JSON double-quoted string.
# Must handle the FULL control-char set (0x00-0x1F incl. CR) or the resulting
# state files become invalid JSON and the guard fails open. python3 -> jq ->
# pure-bash fallback (the fallback strips the rarer controls it can't escape).
json_escape() {
  local s="$1" e
  if _have python3; then
    printf '%s' "$s" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null && return 0
  fi
  if _have jq; then
    e="$(printf '%s' "$s" | jq -Rs . 2>/dev/null)"; e="${e#\"}"; e="${e%\"}"; printf '%s' "$e"; return 0
  fi
  s="${s//\\/\\\\}"        # backslash first
  s="${s//\"/\\\"}"        # double quote
  s="${s//$'\t'/\\t}"      # tab
  s="${s//$'\r'/\\r}"      # carriage return
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"  # drop other C0 controls
  s="${s//$'\n'/\\n}"      # newline last
  printf '%s' "$s"
}

# jstr <key> <value>  — emit  "key":"escaped-value"
jstr() { printf '"%s":"%s"' "$1" "$(json_escape "$2")"; }
# jnum <key> <value>  — emit  "key":value  (value assumed numeric/bare)
jnum() { printf '"%s":%s' "$1" "$2"; }

# ---- path helpers ----------------------------------------------------------
# rel_path <path> — canonical key for a path.
#  - PROJECT_ROOT (with/without trailing slash) -> "." (root sentinel)
#  - a path under PROJECT_ROOT -> project-relative
#  - an absolute path NOT under PROJECT_ROOT -> kept ABSOLUTE (distinct namespace,
#    so /etc/passwd can never collide with the in-project "etc/passwd")
#  - a relative path -> as-is (leading "./" stripped)
# A single trailing slash is stripped so "src/dir" and "src/dir/" are one key.
rel_path() {
  local p="$1"
  case "$p" in
    "$PROJECT_ROOT")    printf '.'; return ;;
    "$PROJECT_ROOT"/*)  p="${p#"$PROJECT_ROOT"/}" ;;
    /*)                 case "$p" in */) [ "$p" != "/" ] && p="${p%/}" ;; esac; printf '%s' "$p"; return ;;
    ./*)                p="${p#./}" ;;
    .)                  printf '.'; return ;;
  esac
  case "$p" in */) p="${p%/}" ;; esac
  [ -z "$p" ] && p="."
  printf '%s' "$p"
}

# _hash <string> — short stable hex digest (for over-long slugs). Tries the
# usual suspects; cksum is the universal floor.
_hash() {
  if _have shasum;  then printf '%s' "$1" | shasum    | cut -c1-40
  elif _have sha1sum; then printf '%s' "$1" | sha1sum | cut -c1-40
  elif _have md5;     then printf '%s' "$1" | md5      | cut -c1-32
  elif _have md5sum;  then printf '%s' "$1" | md5sum   | cut -c1-32
  else printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-20
  fi
}

# slugify <relpath> — INJECTIVE, filesystem-safe lock-dir basename.
# BYTE-EXACT and locale-independent: reads the path one raw byte at a time via
# od (so multibyte UTF-8 and high bytes can't collide or sign-extend), passing
# the ASCII safe set [A-Za-z0-9._-] through and percent-encoding every other
# byte as %XX. Over-long results (deep/CJK paths > NAME_MAX) collapse to a hash
# (still injective in practice; the human path lives in meta.json). Root -> "ROOT".
slugify() {
  local p="$1" out
  { [ "$p" = "." ] || [ -z "$p" ]; } && { printf 'ROOT'; return; }
  out="$(printf '%s' "$p" | od -An -v -tx1 | tr ' ' '\n' | grep -v '^$' | while read -r b; do
    d=$((16#$b))
    if   [ "$d" -ge 48 ] && [ "$d" -le 57 ]; then printf '%b' "\\x$b"   # 0-9
    elif [ "$d" -ge 65 ] && [ "$d" -le 90 ]; then printf '%b' "\\x$b"   # A-Z
    elif [ "$d" -ge 97 ] && [ "$d" -le 122 ]; then printf '%b' "\\x$b"  # a-z
    elif [ "$d" -eq 46 ] || [ "$d" -eq 95 ] || [ "$d" -eq 45 ]; then printf '%b' "\\x$b"  # . _ -
    else printf '%%%s' "$(printf '%s' "$b" | tr 'a-f' 'A-F')"
    fi
  done)"
  # over-long -> hash. Prefix with "%H": the encoder only ever emits '%' as part
  # of a "%XX" (uppercase-hex) triple, so a "%H..." slug is UNREACHABLE by any
  # real path and can never alias a literal filename.
  if [ "${#out}" -gt 200 ]; then out="%H$(_hash "$p")"; fi
  printf '%s' "$out"
}

# lock dir basename is prefixed so it can NEVER begin with '.', keeping every
# lock visible to the unquoted "$CLAIMS_DIR"/*.lock globs (bash 3.2 dotglob off).
FLEET_LOCK_PREFIX="c-"
lock_dir_for() { printf '%s/%s%s.lock' "$CLAIMS_DIR" "$FLEET_LOCK_PREFIX" "$(slugify "$1")"; }

# ---- agent / liveness ------------------------------------------------------
agent_file() { printf '%s/%s.json' "$AGENTS_DIR" "$1"; }
short_sid()  { printf '%s' "$1" | tr -d '-' | cut -c1-8; }

# is_live <sid> — agent file present AND mtime within stale window.
is_live() {
  local sid="$1" f age stale
  f="$(agent_file "$sid")"
  [ -f "$f" ] || return 1
  stale="$(stale_after)"
  age=$(( $(now_epoch) - $(mtime_epoch "$f") ))
  [ "$age" -lt "$stale" ]
}

# live_sids — print session ids of all live agents, one per line.
live_sids() {
  local f sid
  [ -d "$AGENTS_DIR" ] || return 0
  for f in "$AGENTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    sid="$(basename "$f" .json)"
    is_live "$sid" && printf '%s\n' "$sid"
  done
}

count_live() { live_sids | grep -c . ; }

# count_claims — number of active claim lock dirs (glob-based; handles odd names).
count_claims() {
  local n=0 d
  for d in "$CLAIMS_DIR"/*.lock; do [ -d "$d" ] && n=$((n+1)); done
  printf '%s\n' "$n"
}

# next_label — lowest unused agent-N among live agents.
next_label() {
  local used n f lbl
  used=" "
  for f in "$AGENTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    lbl="$(json_field_file "$f" agent)"
    case "$lbl" in agent-*) used="$used${lbl#agent-} " ;; esac
  done
  n=1
  while case "$used" in *" $n "*) true;; *) false;; esac; do n=$((n+1)); done
  printf 'agent-%s' "$n"
}

# ---- append-only logs (atomic for small single-line writes) ----------------
append_board()  { printf '%s\n' "$1" >> "$BOARD_FILE"  2>/dev/null || true; }
append_ledger() { printf '%s\n' "$1" >> "$LEDGER_FILE" 2>/dev/null || true; }

# board_event <event> <agent> <short> [<extra-json-without-braces>]
board_event() {
  local ev="$1" agent="$2" short="$3" extra="$4" line
  line="{$(jstr ts "$(now_iso)"),$(jstr event "$ev"),$(jstr agent "$agent"),$(jstr short "$short")"
  [ -n "$extra" ] && line="$line,$extra"
  line="$line}"
  append_board "$line"
  append_ledger "$line"
}

# ---- claims ----------------------------------------------------------------
# claim_owner <relpath>   — print owner sid of the claim whose path == relpath (exact), else empty
# covering_lock <relpath> — print "sid|path|agent|intent" of a LIVE foreign-or-any lock covering relpath.
#   Honors claim_mode (prefix => ancestor dir claims cover descendants).
covering_lock() {
  local target="$1" mode d meta cpath csid cagent cintent bn slug tslug
  target="$(rel_path "$target")"
  tslug="$(slugify "$target")"
  mode="$(claim_mode)"
  [ -d "$CLAIMS_DIR" ] || return 0
  for d in "$CLAIMS_DIR"/*.lock; do
    [ -d "$d" ] || continue
    meta="$d/meta.json"
    bn="$(basename "$d")"; slug="${bn%.lock}"; slug="${slug#"$FLEET_LOCK_PREFIX"}"
    if [ -f "$meta" ]; then
      cpath="$(json_field_file "$meta" path)"
      cprel=""
      [ -n "$cpath" ] && cprel="$(rel_path "$cpath")"
      # Trust the stored path ONLY if it slugs back to this lock's identity.
      # An empty / wrong-typed / tampered path fails this check and falls through
      # to the fail-safe exact-slug match (never trusts a path that doesn't match
      # the lock it sits in).
      if [ -n "$cprel" ] && [ "$(slugify "$cprel")" = "$slug" ]; then
        if _path_covers "$cprel" "$target" "$mode"; then
          csid="$(json_field_file "$meta" owner_session_id)"
          cagent="$(json_field_file "$meta" agent)"
          cintent="$(json_field_file "$meta" intent)"
          [ -z "$csid" ] && csid="INPROGRESS"   # present meta, empty owner -> fail safe
          printf '%s|%s|%s|%s\n' "$csid" "$cprel" "$cagent" "$cintent"
          return 0
        fi
      else
        # corrupt/empty/tampered path -> fail SAFE on an exact slug match only.
        [ "$slug" = "$tslug" ] && { printf 'INPROGRESS|%s|?|corrupt claim meta\n' "$target"; return 0; }
      fi
    else
      # meta not written yet: a claim in progress (mkdir won, meta pending).
      # Within the grace window, block an EXACT-path edit (slug match); past it,
      # it's an orphan the reaper will clear.
      if [ $(( $(now_epoch) - $(mtime_epoch "$d") )) -le "$FLEET_CLAIM_GRACE" ]; then
        if [ "$slug" = "$tslug" ]; then
          printf 'INPROGRESS|%s|?|claim in progress\n' "$target"
          return 0
        fi
      fi
    fi
  done
  return 0
}

# _path_covers <claimpath> <target> <mode>  — does a claim on claimpath cover target?
_path_covers() {
  local claim="$1" target="$2" mode="$3"
  [ "$claim" = "$target" ] && return 0
  # root claim ('.') covers every in-project (relative) target under prefix mode
  if [ "$claim" = "." ]; then
    if [ "$mode" = "prefix" ]; then
      case "$target" in /*) return 1 ;; *) return 0 ;; esac
    fi
    return 1
  fi
  if [ "$mode" = "prefix" ]; then
    local base="${claim%/}"
    case "$target" in
      "$base"/*) return 0 ;;
    esac
  fi
  return 1
}

# ---- reaper ----------------------------------------------------------------
# reap — remove dead agents and orphaned claims. Safe to call from any context
# that is allowed to write (NOT from guard.sh, which stays read-only).
reap() {
  local f sid d meta owner
  ensure_state
  # dead agents
  for f in "$AGENTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    sid="$(basename "$f" .json)"
    if ! is_live "$sid"; then
      local lbl; lbl="$(json_field_file "$f" agent)"
      rm -f "$f" 2>/dev/null || true
      _release_claims_of "$sid"
      board_event reap "${lbl:-?}" "$(short_sid "$sid")" "$(jstr reason stale)"
    fi
  done
  # orphaned/stale claims. A lock with a meta file is removed if its owner is
  # not live. A lock with NO meta yet is a claim in progress (mkdir won, meta
  # not written) — only treat it as orphaned if it is older than the grace
  # window, so a concurrent reap never deletes a fresh winner mid-write.
  for d in "$CLAIMS_DIR"/*.lock; do
    [ -d "$d" ] || continue
    meta="$d/meta.json"
    if [ -f "$meta" ]; then
      owner="$(json_field_file "$meta" owner_session_id)"
      if [ -z "$owner" ] || ! is_live "$owner"; then
        rm -rf "$d" 2>/dev/null || true
      fi
    else
      if [ $(( $(now_epoch) - $(mtime_epoch "$d") )) -gt "$FLEET_CLAIM_GRACE" ]; then
        rm -rf "$d" 2>/dev/null || true
      fi
    fi
  done
}

# seconds a freshly-mkdir'd lock may exist without meta.json before being
# considered orphaned (covers the mkdir->write-meta window).
FLEET_CLAIM_GRACE="${FLEET_CLAIM_GRACE:-5}"

# _release_claims_of <sid> — rm -rf every claim owned by sid.
_release_claims_of() {
  local sid="$1" d meta owner
  for d in "$CLAIMS_DIR"/*.lock; do
    [ -d "$d" ] || continue
    meta="$d/meta.json"
    [ -f "$meta" ] || { rm -rf "$d" 2>/dev/null || true; continue; }
    owner="$(json_field_file "$meta" owner_session_id)"
    if [ "$owner" = "$sid" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}

# ---- state location resolution (supports worktree-shared state) ------------
# Default: local in-project state ($FLEET_DIR/state) — the "folder in the
# project" model. When config state_location=git-common (worktree mode), all
# worktrees of the same repo share one state dir under the common git dir, so
# agents in different worktrees still see each other. FLEET_STATE_DIR overrides.
_fleet_resolve_state() {
  local loc gcd
  if [ -n "${FLEET_STATE_DIR:-}" ]; then
    STATE_DIR="$FLEET_STATE_DIR"
  else
    loc="$(config_get state_location local)"
    if [ "$loc" = "git-common" ] && _have git; then
      gcd="$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null)"
      if [ -n "$gcd" ]; then
        case "$gcd" in /*) : ;; *) gcd="$PROJECT_ROOT/$gcd" ;; esac
        STATE_DIR="$gcd/fleet"
      fi
    fi
  fi
  AGENTS_DIR="$STATE_DIR/agents"
  CLAIMS_DIR="$STATE_DIR/claims"
  INBOX_DIR="$STATE_DIR/inbox"
  BOARD_FILE="$STATE_DIR/board.jsonl"
  LEDGER_FILE="$STATE_DIR/ledger.jsonl"
}
_fleet_resolve_state
