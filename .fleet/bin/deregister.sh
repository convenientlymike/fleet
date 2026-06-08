#!/usr/bin/env bash
# deregister.sh — Fleet SessionEnd hook.
# Best-effort cleanup when a window closes gracefully: remove this agent's file,
# release its claims, log a leave. SessionEnd does NOT fire on kill -9, so the
# time-based reaper (in register.sh / awareness.sh) is the real liveness
# guarantee; this just makes the common case instant. Silent on stdout.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
SID="$(json_field_str "$INPUT" session_id)"
[ -z "$SID" ] && SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$SID" ] && exit 0

[ -d "$STATE_DIR" ] || exit 0

F="$(agent_file "$SID")"
LABEL=""
[ -f "$F" ] && LABEL="$(json_field_file "$F" agent)"
SHORT="$(short_sid "$SID")"

_release_claims_of "$SID"
rm -f "$F" 2>/dev/null || true
rm -f "$INBOX_DIR/$SID.jsonl" "$INBOX_DIR/$SID.seen" 2>/dev/null || true

[ -n "$LABEL" ] && board_event leave "$LABEL" "$SHORT" ""
exit 0
