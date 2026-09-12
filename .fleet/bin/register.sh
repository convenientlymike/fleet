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

F="$(agent_file "$SID")"
SHORT="$(short_sid "$SID")"

# trackboard native adoption (design §D.4) — if a signed reservation targets this window's cwd+device, adopt it
# here on the target host: writes the name/role overlay + seeds the mission + sets ADOPT_HOST for the agent-file
# `host` field below. Always a silent no-op on any doubt (returns 0), so it can never block a normal registration.
adopt_reservation "$SID" "$CWD" || true

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
  # device host — emitted ONLY when a reservation was adopted (ADOPT_HOST set). Absent otherwise, so a
  # non-adopting (baseline) registration writes a byte-identical agent file (the selftest back-compat bite).
  [ -n "${ADOPT_HOST:-}" ] && printf '%s,'  "$(jstr host "$ADOPT_HOST")"
  printf '%s'   "$(jstr status active)"
  printf '}\n'
} > "$TMP" 2>/dev/null
mv -f "$TMP" "$F" 2>/dev/null || rm -f "$TMP" 2>/dev/null

if [ "$SOURCE" = "startup" ]; then
  board_event join "$LABEL" "$SHORT" "$(jstr source "$SOURCE")"
fi

exit 0
