#!/usr/bin/env bash
# fleet.sh — Fleet command line (model- and human-callable).
# Identity is auto-detected from $CLAUDE_CODE_SESSION_ID (override with --id <sid>
# or $FLEET_SESSION). Usage: .fleet/bin/fleet.sh <command> [args]
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

# ---- identity --------------------------------------------------------------
SELF_SID=""
fleet_self_sid() {
  if [ -n "${FLEET_ID:-}" ]; then printf '%s' "$FLEET_ID"; return 0; fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then printf '%s' "$CLAUDE_CODE_SESSION_ID"; return 0; fi
  if [ -n "${FLEET_SESSION:-}" ]; then printf '%s' "$FLEET_SESSION"; return 0; fi
  return 1
}

ensure_self_registered() {
  local sid="$1" f label short
  f="$(agent_file "$sid")"
  [ -f "$f" ] && { touch "$f" 2>/dev/null || true; return 0; }
  ensure_state
  short="$(short_sid "$sid")"; label="$(next_label)"
  local tmp="$f.tmp.$$"
  {
    printf '{'
    printf '%s,' "$(jstr session_id "$sid")"
    printf '%s,' "$(jstr agent "$label")"
    printf '%s,' "$(jstr short "$short")"
    printf '%s,' "$(jstr source cli)"
    printf '%s,' "$(jstr cwd "$PROJECT_ROOT")"
    printf '%s,' "$(jstr started_at "$(now_iso)")"
    printf '%s,' "$(jstr last_seen "$(now_iso)")"
    printf '%s'  "$(jstr status active)"
    printf '}\n'
  } > "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

self_label() { json_field_file "$(agent_file "$1")" agent; }

# ---- config_set <key> <value-as-json> (jq -> python -> naive) --------------
config_set() {
  local key="$1" val="$2" tmp
  [ -f "$CONFIG_FILE" ] || printf '{}\n' > "$CONFIG_FILE"
  tmp="$CONFIG_FILE.tmp.$$"
  if _have jq; then
    jq --arg k "$key" --argjson v "$val" '.[$k]=$v' "$CONFIG_FILE" > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$CONFIG_FILE" && return 0
    rm -f "$tmp" 2>/dev/null
  fi
  if _have python3; then
    FLEET_K="$key" FLEET_V="$val" python3 - "$CONFIG_FILE" <<'PY' && return 0
import json,os,sys
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: d={}
import json as _j
d[os.environ["FLEET_K"]]=_j.loads(os.environ["FLEET_V"])
json.dump(d,open(p,"w"),indent=2)
PY
  fi
  log_err "fleet: cannot edit config without jq or python3"; return 1
}

# ---- resolve a recipient target (label | short | sid) to a sid -------------
sid_for_target() {
  local t="$1" sid lbl sh
  for sid in $(live_sids); do
    [ "$sid" = "$t" ] && { printf '%s' "$sid"; return 0; }
    lbl="$(json_field_file "$(agent_file "$sid")" agent)"
    sh="$(short_sid "$sid")"
    if [ "$lbl" = "$t" ] || [ "$sh" = "$t" ]; then printf '%s' "$sid"; return 0; fi
  done
  return 1
}

# ===========================================================================
# commands
# ===========================================================================
cmd_claim() {
  local path="$1"; shift || true
  local intent="$*"
  [ -z "$path" ] && { log_err "usage: fleet.sh claim <path> [intent]"; return 2; }
  local rel lock owner segs
  rel="$(rel_path "$path")"
  ensure_self_registered "$SELF_SID"
  local label short; label="$(self_label "$SELF_SID")"; short="$(short_sid "$SELF_SID")"
  lock="$(lock_dir_for "$rel")"
  ensure_state

  # gentle warning on very broad claims (< 2 path segments and not a file)
  segs="$(printf '%s' "$rel" | awk -F/ '{print NF}')"
  case "$rel" in */) [ "$segs" -le 2 ] && log_err "note: '$rel' is a broad claim; consider a narrower subtree." ;; esac

  reap   # clear genuinely-stale locks first (respects the mid-write grace window)

  # mkdir is the atomic mutex. If it fails the lock is HELD — never steal it.
  if ! mkdir "$lock" 2>/dev/null; then
    owner="$(json_field_file "$lock/meta.json" owner_session_id)"
    if [ "$owner" = "$SELF_SID" ]; then
      echo "already yours: $rel"; return 0
    fi
    if [ -z "$owner" ]; then
      log_err "DENIED: '$rel' is being claimed by another window right now — try again in a moment."
      return 1
    fi
    if is_live "$owner"; then
      local olabel ointent; olabel="$(json_field_file "$lock/meta.json" agent)"; ointent="$(json_field_file "$lock/meta.json" intent)"
      log_err "DENIED: '$rel' is held by ${olabel:-another agent}${ointent:+ ($ointent)}. Pick another area or message them."
      return 1
    fi
    # meta present but owner not live: a stale lock reap just missed; it frees
    # within ${FLEET_CLAIM_GRACE}s. Don't race to steal it.
    log_err "DENIED: '$rel' is held by a stale lock; retry shortly, or force: fleet.sh release --force '$rel'"
    return 1
  fi

  local meta="$lock/meta.json" tmp="$lock/meta.json.tmp.$$"
  {
    printf '{'
    printf '%s,' "$(jstr path "$rel")"
    printf '%s,' "$(jstr mode write)"
    printf '%s,' "$(jstr owner_session_id "$SELF_SID")"
    printf '%s,' "$(jstr agent "$label")"
    printf '%s,' "$(jstr short "$short")"
    printf '%s,' "$(jstr intent "$intent")"
    printf '%s'  "$(jstr claimed_at "$(now_iso)")"
    printf '}\n'
  } > "$tmp" 2>/dev/null
  mv -f "$tmp" "$meta" 2>/dev/null || rm -f "$tmp" 2>/dev/null

  board_event claim "$label" "$short" "$(jstr path "$rel")${intent:+,$(jstr intent "$intent")}"
  echo "claimed: $rel${intent:+  ($intent)}"
}

cmd_release() {
  local force=0
  [ "${1:-}" = "--force" ] && { force=1; shift; }
  local path="${1:-}"
  [ -z "$path" ] && { log_err "usage: fleet.sh release [--force] <path>"; return 2; }
  local rel lock owner; rel="$(rel_path "$path")"; lock="$(lock_dir_for "$rel")"
  [ -d "$lock" ] || { echo "no claim on: $rel"; return 0; }
  owner="$(json_field_file "$lock/meta.json" owner_session_id)"
  if [ "$owner" != "$SELF_SID" ] && [ "$force" -ne 1 ]; then
    local olabel; olabel="$(json_field_file "$lock/meta.json" agent)"
    log_err "held by ${olabel:-another agent}; use --force to override."
    return 1
  fi
  rm -rf "$lock" 2>/dev/null
  local label short; label="$(self_label "$SELF_SID")"; short="$(short_sid "$SELF_SID")"
  board_event release "${label:-?}" "$short" "$(jstr path "$rel")"
  echo "released: $rel"
}

cmd_roster() {
  reap
  local n; n="$(count_live)"
  echo "Fleet roster — $n live agent(s) in $(basename "$PROJECT_ROOT")"
  local sid
  for sid in $(live_sids); do
    local af lbl sh you=""; af="$(agent_file "$sid")"
    lbl="$(json_field_file "$af" agent)"; sh="$(short_sid "$sid")"
    [ "$sid" = "$SELF_SID" ] && you="  <- you"
    echo "  $lbl ($sh)$you"
    local d
    for d in "$CLAIMS_DIR"/*.lock; do
      [ -d "$d" ] || continue; [ -f "$d/meta.json" ] || continue
      [ "$(json_field_file "$d/meta.json" owner_session_id)" = "$sid" ] || continue
      local cp intent; cp="$(json_field_file "$d/meta.json" path)"; intent="$(json_field_file "$d/meta.json" intent)"
      echo "      holds: $cp${intent:+  ($intent)}"
    done
  done
}

cmd_whoami() {
  ensure_self_registered "$SELF_SID"
  local lbl; lbl="$(self_label "$SELF_SID")"
  echo "$lbl  (session $SELF_SID, short $(short_sid "$SELF_SID"))"
}

cmd_msg() {
  local to="${1:-}"; shift || true
  local body="$*"
  [ -z "$to" ] || [ -z "$body" ] && { log_err 'usage: fleet.sh msg <agent-N|short|all> "<message>"'; return 2; }
  ensure_self_registered "$SELF_SID"
  local from short; from="$(self_label "$SELF_SID")"; short="$(short_sid "$SELF_SID")"
  local mid; mid="$(now_epoch)-$$-${RANDOM:-0}"
  _emit_msg() {
    local rsid="$1" line ibox="$INBOX_DIR/$1.jsonl"
    line="{$(jstr msg_id "$mid"),$(jstr ts "$(now_iso)"),$(jstr from "$from"),$(jstr from_short "$short"),$(jstr to "$to"),$(jstr body "$body")}"
    printf '%s\n' "$line" >> "$ibox" 2>/dev/null || true
  }
  if [ "$to" = "all" ]; then
    local sid c=0
    for sid in $(live_sids); do
      [ "$sid" = "$SELF_SID" ] && continue
      _emit_msg "$sid"; c=$((c+1))
    done
    board_event msg "$from" "$short" "$(jstr to all),$(jstr body "$body")"
    echo "broadcast to $c agent(s)"
  else
    local rsid; rsid="$(sid_for_target "$to")" || { log_err "no live agent matches '$to' (try fleet.sh roster)"; return 1; }
    _emit_msg "$rsid"
    board_event msg "$from" "$short" "$(jstr to "$to"),$(jstr body "$body")"
    echo "sent to $to"
  fi
}

cmd_inbox() {
  local ibox="$INBOX_DIR/$SELF_SID.jsonl"
  [ -f "$ibox" ] || { echo "(inbox empty)"; return 0; }
  local total; total="$(wc -l < "$ibox" 2>/dev/null | tr -d ' ')"
  [ -z "$total" ] || [ "$total" -eq 0 ] && { echo "(inbox empty)"; return 0; }
  local line
  while IFS= read -r line; do
    local frm body ts; frm="$(json_field_str "$line" from)"; body="$(json_field_str "$line" body)"; ts="$(json_field_str "$line" ts)"
    echo "[$ts] $frm: $body"
  done < "$ibox"
  printf '%s' "$total" > "$INBOX_DIR/$SELF_SID.seen" 2>/dev/null || true
}

cmd_board() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    post)
      local text="$*"; [ -z "$text" ] && { log_err 'usage: fleet.sh board post "<text>"'; return 2; }
      [ -n "$SELF_SID" ] || { log_err "no session identity (\$CLAUDE_CODE_SESSION_ID unset). Pass --id <sid>."; return 1; }
      ensure_self_registered "$SELF_SID"
      local label short; label="$(self_label "$SELF_SID")"; short="$(short_sid "$SELF_SID")"
      board_event note "$label" "$short" "$(jstr text "$text")"
      echo "posted."
      ;;
    list|*)
      [ -f "$BOARD_FILE" ] || { echo "(board empty)"; return 0; }
      tail -n 40 "$BOARD_FILE"
      ;;
  esac
}

cmd_status() {
  reap
  echo "Fleet v$(cat "$VERSION_FILE" 2>/dev/null || echo '?')  (schema $FLEET_SCHEMA_VERSION)"
  echo "project:   $PROJECT_ROOT"
  echo "state dir: $STATE_DIR"
  echo "config:    claim_mode=$(claim_mode)  block_mode=$(block_mode)  stale_after_s=$(stale_after)  state_location=$(config_get state_location local)"
  echo "live agents: $(count_live)    active claims: $(count_claims)"
  case "$PROJECT_ROOT" in
    *"/Library/Mobile Documents/"*|*"/Dropbox/"*|*"/Google Drive/"*|*"/OneDrive/"*)
      echo "WARNING: project is inside a cloud-synced folder; mkdir locks are unreliable there. Prefer worktree mode or a non-synced path." ;;
  esac
}

cmd_doctor() {
  echo "== fleet doctor =="
  cmd_status
  echo
  echo "tools: jq=$(command -v jq || echo no)  python3=$(command -v python3 || echo no)  git=$(command -v git || echo no)"
  local s="$PROJECT_ROOT/.claude/settings.json"
  if [ -f "$s" ]; then
    if grep -q '.fleet/bin/guard.sh' "$s" 2>/dev/null; then echo "hooks: wired in .claude/settings.json (OK)"; else echo "hooks: NOT wired — run: bash .fleet/bin/fleet.sh init"; fi
  else
    echo "hooks: no .claude/settings.json — run: bash .fleet/bin/fleet.sh init"
  fi
  local f x=0
  for f in lib.sh register.sh guard.sh awareness.sh deregister.sh fleet.sh; do
    [ -x "$DIR/$f" ] || { echo "not executable: $f"; x=1; }
  done
  [ "$x" -eq 0 ] && echo "scripts: all executable (OK)"
  # stale / orphan summary
  local stale=0 d
  for f in "$AGENTS_DIR"/*.json; do [ -f "$f" ] || continue; is_live "$(basename "$f" .json)" || stale=$((stale+1)); done
  echo "stale agent files (will be reaped): $stale"
}

cmd_worktree() {
  local sub="${1:-list}"; shift || true
  _have git || { log_err "git not found"; return 1; }
  case "$sub" in
    enable)
      config_set state_location '"git-common"' && _fleet_resolve_state && reap
      echo "worktree mode ON: state is now shared across all worktrees of this repo ($STATE_DIR)."
      ;;
    disable)
      config_set state_location '"local"' && _fleet_resolve_state
      echo "worktree mode OFF: state is local to this checkout."
      ;;
    new)
      local name="${1:-}"; [ -z "$name" ] && { log_err "usage: fleet.sh worktree new <name>"; return 2; }
      [ "$(config_get state_location local)" = "git-common" ] || log_err "note: run 'fleet.sh worktree enable' first so the new worktree shares fleet state."
      local repo dest branch; repo="$(basename "$PROJECT_ROOT")"
      dest="$(dirname "$PROJECT_ROOT")/${repo}--${name}"; branch="fleet/${name}"
      git -C "$PROJECT_ROOT" worktree add "$dest" -b "$branch" || return 1
      echo "created worktree: $dest  (branch $branch)"
      echo "open it in a NEW VS Code window to run a Claude Code agent there."
      ;;
    list|*)
      git -C "$PROJECT_ROOT" worktree list ;;
  esac
}

usage() {
  cat <<EOF
Fleet — multi-window Claude Code coordination.  identity: \$CLAUDE_CODE_SESSION_ID (auto)

  fleet.sh claim <path> [intent]     reserve a file/dir so other windows can't edit it
  fleet.sh release [--force] <path>  release your claim
  fleet.sh roster                    who is live and what they hold
  fleet.sh whoami                    your agent label + session
  fleet.sh msg <agent-N|short|all> "<msg>"   message another agent
  fleet.sh inbox                     read your messages (marks them read)
  fleet.sh board [list|post "<t>"]   shared activity feed
  fleet.sh status | doctor           health + config
  fleet.sh worktree enable|new <name>|list   git-worktree isolation mode
  fleet.sh init [--dry-run|--yes|--print-settings]   install into this project
  fleet.sh uninstall                 remove hooks + .fleet
  fleet.sh version

  global flag:  --id <session-id>    act as a specific agent (testing/scripts)
EOF
}

# ---- dispatch --------------------------------------------------------------
# leading --id <sid>
if [ "${1:-}" = "--id" ]; then FLEET_ID="${2:-}"; shift 2 || true; fi

CMD="${1:-help}"; shift || true

case "$CMD" in
  init|uninstall)
    . "$DIR/installer.sh"
    if [ "$CMD" = "init" ]; then cmd_init "$@"; else cmd_uninstall "$@"; fi
    exit $?
    ;;
  version|--version|-v) cat "$VERSION_FILE" 2>/dev/null || echo "?"; exit 0 ;;
  help|--help|-h) usage; exit 0 ;;
esac

# Identity is OPTIONAL for read-only views (roster/status/doctor/board list) so
# they work from a plain terminal or CI; mutations resolve it strictly via
# require_id below.
SELF_SID="$(fleet_self_sid 2>/dev/null || true)"
ensure_state

require_id() {
  [ -n "$SELF_SID" ] && return 0
  log_err "no session identity (\$CLAUDE_CODE_SESSION_ID unset). Pass --id <sid>."
  exit 1
}

case "$CMD" in
  claim)    require_id; cmd_claim "$@" ;;
  release)  require_id; cmd_release "$@" ;;
  roster)   cmd_roster ;;
  whoami)   require_id; cmd_whoami ;;
  msg)      require_id; cmd_msg "$@" ;;
  inbox)    require_id; cmd_inbox ;;
  board)    cmd_board "$@" ;;
  status)   cmd_status ;;
  doctor)   cmd_doctor ;;
  worktree) cmd_worktree "$@" ;;
  goal)     exec "$(dirname "$0")/goalstack" "$@" ;;   # per-window anchor goal (keyed by this window's session id)
  *) log_err "unknown command: $CMD"; usage; exit 2 ;;
esac
