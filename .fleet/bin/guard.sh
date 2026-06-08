#!/usr/bin/env bash
# guard.sh — Fleet PreToolUse hook (matcher: Edit|Write|MultiEdit|NotebookEdit).
# THE ENFORCER. Strictly READ-ONLY (never writes/reaps) so it is safe to run in
# parallel with other PreToolUse hooks. If the target file is covered by a LIVE
# *foreign* agent's claim, it blocks the edit:
#   block_mode=block (default) -> exit 2  (harness denies the tool before it runs)
#   block_mode=warn            -> exit 0 with a stderr notice (advisory)
# Fail-open: any internal error allows the edit (exit 0), never wedges editing.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

# fail OPEN on any unexpected error
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"

SID="$(json_field_str "$INPUT" session_id)"
[ -z "$SID" ] && SID="${CLAUDE_CODE_SESSION_ID:-}"

# target path: file_path (Edit/Write/MultiEdit) or notebook_path (NotebookEdit)
TARGET="$(json_field_str "$INPUT" tool_input.file_path)"
[ -z "$TARGET" ] && TARGET="$(json_field_str "$INPUT" tool_input.notebook_path)"
[ -z "$TARGET" ] && exit 0   # nothing to guard

[ -d "$CLAIMS_DIR" ] || exit 0

REL="$(rel_path "$TARGET")"
HIT="$(covering_lock "$REL")"
[ -z "$HIT" ] && exit 0

OWNER="${HIT%%|*}"
REST="${HIT#*|}"; CPATH="${REST%%|*}"
REST="${REST#*|}"; OAGENT="${REST%%|*}"
OINTENT="${REST#*|}"

# own claim -> allow
[ "$OWNER" = "$SID" ] && exit 0

# INPROGRESS = a claim mid-write or a corrupt meta -> fail SAFE (block).
# A real owner that is not live = a dead lock -> allow (reaper cleans it later).
if [ "$OWNER" != "INPROGRESS" ]; then
  is_live "$OWNER" || exit 0
fi

REASON="Fleet: \"$REL\" is claimed by ${OAGENT:-another agent} (covering \"$CPATH\""
[ -n "$OINTENT" ] && REASON="$REASON — $OINTENT"
REASON="$REASON). Claim a different area, or ask ${OAGENT:-them} to release it: .fleet/bin/fleet.sh release \"$CPATH\""

if [ "$(block_mode)" = "warn" ]; then
  log_err "WARNING $REASON"
  exit 0
fi

# hard block
log_err "BLOCKED $REASON"
exit 2
