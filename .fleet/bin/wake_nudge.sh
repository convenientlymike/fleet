#!/usr/bin/env bash
# wake_nudge.sh — Fleet SessionStart hook (Part A of the agent-to-agent wake feature).
#
# WHY: `fleet.sh msg <you>` appends a line to your inbox .jsonl — but a file append does NOT wake an idle agent.
# An idle claude process is blocked reading its OWN stdin pipe (owned by the editor/extension), not polling any
# file, so a queued DM sits unseen until you next take a turn. The ONLY in-editor way to make an inbound DM WAKE a
# LIVE session is for that session to run a background watcher whose stdout re-invokes the model — the harness
# Monitor tool. A hook CANNOT call the Monitor tool (only the agent can), so this hook can only DIRECT the agent to
# arm it. That is an honest platform limit: this half is compliance-based. Sessions that are not running at all are
# covered by the complementary mechanism, wake-dispatcher.sh (headless `claude --resume`).
#
# Emits a short directive on stdout at SessionStart. Never blocks the session.
set -u
trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
# minimal, dependency-free session_id extraction (avoid sourcing lib.sh in a hook)
SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -z "$SID" ] && SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$SID" ] && exit 0   # no identity -> nothing useful to say; stay silent

# Surface any UNREAD DMs so a NEW/resumed session SEES the backlog immediately (not just "arm it"). unread =
# inbox line-count - the seen count cmd_inbox persists to <SID>.seen. Worktree-safe via --git-common-dir (fleet
# state lives under the SHARED gitdir, addressable from any worktree). All-defensive: never break the session.
_wn_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_wn_cdir="$(cd "${_wn_dir:-.}" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
_wn_inbox="${_wn_cdir}/fleet/inbox/${SID}.jsonl"
if [ -n "$_wn_cdir" ] && [ -f "$_wn_inbox" ]; then
  _wn_cur="$(wc -l < "$_wn_inbox" 2>/dev/null | tr -d ' ')"; _wn_cur="${_wn_cur:-0}"
  _wn_seen=0; [ -f "${_wn_cdir}/fleet/inbox/${SID}.seen" ] && _wn_seen="$(tr -d ' ' < "${_wn_cdir}/fleet/inbox/${SID}.seen" 2>/dev/null)"; _wn_seen="${_wn_seen:-0}"
  case "$_wn_cur$_wn_seen" in *[!0-9]*) _wn_cur=0; _wn_seen=0 ;; esac   # numeric-guard (set -u + ERR-trap safe)
  _wn_unread=$(( _wn_cur - _wn_seen ))
  if [ "$_wn_unread" -gt 0 ]; then
    echo "⚠ FLEET: ${_wn_unread} UNREAD DM(s) waiting — run: .fleet/bin/fleet.sh inbox  (then act on anything actionable)"
    tail -n +"$(( _wn_seen + 1 ))" "$_wn_inbox" 2>/dev/null | head -3 | sed 's/^/    • /'
    echo
  fi
fi

cat <<'EOF'
⎇ FLEET WAKE — to receive agent-to-agent pings that WAKE you (not just queue silently in your inbox):
  Arm your inbox watcher ONCE, now: run `.fleet/bin/fleet.sh wake-cmd` and hand its printed command to the
  Monitor tool (persistent:true, timeout_ms:3600000). After that, any `fleet.sh msg <you> "…"` re-invokes you
  so you can `.fleet/bin/fleet.sh inbox` and act on it. (Skip if you already armed it this session.)
  Sessions that are fully closed are woken instead by .fleet/bin/wake-dispatcher.sh.
EOF
exit 0
