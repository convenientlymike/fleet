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

# DURABLE HANDOFF: do NOT destroy UNREAD agent-to-agent DMs when a window closes. Historically this hook deleted
# the inbox unconditionally, so a `fleet.sh msg` to a window that then closed was lost — making an autonomous
# handoff to a closed session impossible. If unread messages remain (line count > .seen count), PRESERVE the inbox
# AND the agent record so wake-dispatcher.sh can headless-resume this session to process them; the resumed turn
# reads them (.seen catches up) and its own SessionEnd then cleans up fully. reap()'s agent_gc_s TTL still bounds a
# record that is never revisited.
_seen=0;  [ -f "$INBOX_DIR/$SID.seen" ]  && _seen="$(cat "$INBOX_DIR/$SID.seen" 2>/dev/null | tr -d ' ')";        _seen="${_seen:-0}"
_lines=0; [ -f "$INBOX_DIR/$SID.jsonl" ] && _lines="$(wc -l < "$INBOX_DIR/$SID.jsonl" 2>/dev/null | tr -d ' ')";  _lines="${_lines:-0}"
if [ "$_lines" -gt "$_seen" ]; then
  [ -n "$LABEL" ] && board_event leave "$LABEL" "$SHORT" "$(jstr note "$((_lines - _seen)) unread DM(s) — inbox preserved for wake-dispatcher")"
  exit 0
fi

rm -f "$F" 2>/dev/null || true
rm -f "$INBOX_DIR/$SID.jsonl" "$INBOX_DIR/$SID.seen" 2>/dev/null || true

[ -n "$LABEL" ] && board_event leave "$LABEL" "$SHORT" ""
exit 0
