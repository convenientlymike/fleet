#!/usr/bin/env bash
# awareness.sh — Fleet UserPromptSubmit hook.
# (1) Heartbeat: refresh this agent's liveness (mtime) so it isn't reaped.
# (2) Light reap of dead agents/claims.
# (3) If there are OTHER live agents or unread messages, inject a compact roster
#     as context (UserPromptSubmit stdout is added to the model's context).
# Stays quiet on solo sessions with no messages to avoid per-turn noise.
# This event is not shared with the port hooks, so writing here is safe.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
SID="$(json_field_str "$INPUT" session_id)"
[ -z "$SID" ] && SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$SID" ] && exit 0

ensure_state
F="$(agent_file "$SID")"

# heartbeat (lazily register if the agent file is missing)
if [ -f "$F" ]; then
  touch "$F" 2>/dev/null || true
else
  SHORT="$(short_sid "$SID")"; LABEL="$(next_label)"
  TMP="$F.tmp.$$"
  {
    printf '{'
    printf '%s,' "$(jstr session_id "$SID")"
    printf '%s,' "$(jstr agent "$LABEL")"
    printf '%s,' "$(jstr short "$SHORT")"
    printf '%s,' "$(jstr source resumed)"
    printf '%s,' "$(jstr cwd "$PROJECT_ROOT")"
    printf '%s,' "$(jstr started_at "$(now_iso)")"
    printf '%s,' "$(jstr last_seen "$(now_iso)")"
    printf '%s'  "$(jstr status active)"
    printf '}\n'
  } > "$TMP" 2>/dev/null
  mv -f "$TMP" "$F" 2>/dev/null || rm -f "$TMP" 2>/dev/null
fi

reap

MY_LABEL="$(json_field_file "$F" agent)"; [ -z "$MY_LABEL" ] && MY_LABEL="agent-?"
MY_SHORT="$(short_sid "$SID")"

# ---- gather live roster (excluding self) -----------------------------------
OTHERS=""
OTHER_COUNT=0
for sid in $(live_sids); do
  [ "$sid" = "$SID" ] && continue
  af="$(agent_file "$sid")"
  lbl="$(json_field_file "$af" agent)"; [ -z "$lbl" ] && lbl="agent-?"
  sh="$(short_sid "$sid")"
  # collect this agent's held claim paths
  held=""
  for d in "$CLAIMS_DIR"/*.lock; do
    [ -d "$d" ] || continue
    [ -f "$d/meta.json" ] || continue
    own="$(json_field_file "$d/meta.json" owner_session_id)"
    [ "$own" = "$sid" ] || continue
    cp="$(json_field_file "$d/meta.json" path)"
    intent="$(json_field_file "$d/meta.json" intent)"
    if [ -n "$held" ]; then held="$held, "; fi
    if [ -n "$intent" ]; then held="$held$cp ($intent)"; else held="$held$cp"; fi
  done
  [ -z "$held" ] && held="(no active claims)"
  OTHERS="$OTHERS  - $lbl ($sh): $held
"
  OTHER_COUNT=$((OTHER_COUNT+1))
done

# ---- unread messages -------------------------------------------------------
fleet_unread_scan "$SID"
NEW_COUNT="$FLEET_UNREAD_N"
NEWMSGS="$FLEET_UNREAD_BLOCK"

# ---- quiet on solo + no messages -------------------------------------------
if [ "$OTHER_COUNT" -eq 0 ] && [ "$NEW_COUNT" -eq 0 ]; then
  exit 0
fi

# ---- inject compact roster as context (plain text) -------------------------
printf '[fleet] You are %s (%s). Other live agents: %s.\n' "$MY_LABEL" "$MY_SHORT" "$OTHER_COUNT"
if [ "$OTHER_COUNT" -gt 0 ]; then
  printf '%s' "$OTHERS"
fi
if [ "$NEW_COUNT" -gt 0 ]; then
  printf 'New messages (%s):\n' "$NEW_COUNT"
  printf '%s' "$NEWMSGS"
  _fleet_seen_set "$SID" "$FLEET_INBOX_TOTAL"   # advance ONLY after emit (UserPromptSubmit stdout IS injected)
fi
printf 'Protocol: claim before editing shared areas -> .fleet/bin/fleet.sh claim <path> "<why>". Edits to a file another live agent holds are BLOCKED by the harness. See the roster anytime: .fleet/bin/fleet.sh roster\n'
exit 0
