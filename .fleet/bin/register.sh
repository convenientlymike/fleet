#!/usr/bin/env bash
# register.sh — Fleet SessionStart hook.
# Registers this window as an agent (one file in state/agents/), reaps stale
# agents/claims, and logs a join. Emits NOTHING on stdout so it coexists with
# any other SessionStart hook (e.g. a global port-registry hook that prints raw
# text to stdout). Roster awareness is delivered later via awareness.sh.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

# never let a hook error block the session
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"

SID="$(json_field_str "$INPUT" session_id)"
[ -z "$SID" ] && SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$SID" ] && exit 0   # no identity -> nothing we can do; stay silent

SOURCE="$(json_field_str "$INPUT" source)";  [ -z "$SOURCE" ] && SOURCE="startup"
CWD="$(json_field_str "$INPUT" cwd)";        [ -z "$CWD" ] && CWD="$PROJECT_ROOT"
MODEL="$(json_field_str "$INPUT" model)"
[ -z "$MODEL" ] && MODEL="${CLAUDE_MODEL:-unknown}"

ensure_state
reap   # clean up dead agents/claims first so labels/counts are accurate

# Native reservation adoption (Trackboard D-v2 S4b): if this session was launched to fulfil a SIGNED reservation
# for this cwd/host, seed its identity overlay + mission (goalstack) + host binding and flip it to adopted. Sets
# ADOPTED_HOST only on a clean, authentic, unambiguous match. Fail-OPEN — never blocks registration (no jq/openssl,
# no key, no/ambiguous match, or a bad signature → a silent no-op, and the agent registers exactly as before).
ADOPTED_HOST=""
# shellcheck source=adopt.sh
. "$DIR/adopt.sh"
adopt_reservation "$SID" "$CWD"

F="$(agent_file "$SID")"
SHORT="$(short_sid "$SID")"

if [ -f "$F" ]; then
  # resume / clear / compact of an existing session: reserve keeps the SAME label (stable per session; the
  # file's current label is passed as the continuity hint so an upgrade / reservation-less resume preserves it)
  LABEL="$(reserve_label "$SID" "$(json_field_file "$F" agent)")"
  STARTED="$(json_field_file "$F" started_at)"
  [ -z "$STARTED" ] && STARTED="$(now_iso)"
else
  LABEL="$(reserve_label "$SID")"   # first registration: atomically claim a UNIQUE label (no TOCTOU dup)
  STARTED="$(now_iso)"
fi

TMP="$F.tmp.$$"
{
  printf '{'
  printf '%s,'  "$(jstr session_id "$SID")"
  printf '%s,'  "$(jstr agent "$LABEL")"
  printf '%s,'  "$(jstr short "$SHORT")"
  printf '%s,'  "$(jstr source "$SOURCE")"
  printf '%s,'  "$(jstr cwd "$CWD")"
  printf '%s,'  "$(jstr model "$MODEL")"
  printf '%s,'  "$(jstr started_at "$STARTED")"
  printf '%s,'  "$(jstr last_seen "$(now_iso)")"
  # `host` (device slug) is recorded ONLY when a reservation was natively adopted (read_roster surfaces it, and the
  # reconcile host-qualifier trusts it). When absent, the object is byte-identical to the pre-S4b baseline.
  [ -n "$ADOPTED_HOST" ] && printf '%s,'  "$(jstr host "$ADOPTED_HOST")"
  printf '%s'   "$(jstr status active)"
  printf '}\n'
} > "$TMP" 2>/dev/null
mv -f "$TMP" "$F" 2>/dev/null || rm -f "$TMP" 2>/dev/null

if [ "$SOURCE" = "startup" ]; then
  board_event join "$LABEL" "$SHORT" "$(jstr source "$SOURCE")"
fi

exit 0
