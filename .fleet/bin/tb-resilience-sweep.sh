#!/usr/bin/env bash
# tb-resilience-sweep.sh — trackboard resilience RECOVERY sweep (telemetry slice 5, #8b-3).
#
# For each parked/backed-off agent that has RECOVERED — its rate-limit backoff elapsed, or connectivity is
# N-of-M stabilized (decided by `python3 -m trackboard.resilience --sweep`, #8a/#8b-1) — post a recovery nudge
# into that agent's inbox and mark it nudged (non-destructive, #8b-1). The wake-dispatcher then wakes the OFFLINE
# agents and delivers the nudge, STAGGERED across scans by the #8b-2 defer-not-drop cursor-fix (so a whole-fleet
# recovery doesn't thundering-herd the API). Runs from the dispatcher's --watch loop (FLEET_WAKE_SWEEP_CMD / the
# sibling-convention hook), so it fires even when the ENTIRE fleet is offline (no PostToolUse to trigger the hook).
#
# SAFETY: fail-open (never exits non-zero, never blocks the dispatcher). Bare-python (no venv — the dependency-light
# reporter chain). Posts ONLY to an existing inbox (a known session); a missing checkout LOUDLY breadcrumbs (tb_kpi).
# The recovery message is advisory — it does NOT resume the agent itself; the dispatcher's own wake does that.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh" 2>/dev/null || exit 0          # INBOX_DIR / jstr / now_iso / now_epoch / short_sid / ensure_state
. "$DIR/tb_kpi.sh" 2>/dev/null || exit 0        # _tb_resolve_home / _tb_state_dir / _tb_kpi_breadcrumb (side-effect-free)
ensure_state 2>/dev/null || true

_tb_home="$(_tb_resolve_home)" || { _tb_kpi_breadcrumb "unresolved-checkout"; exit 0; }
_tb_py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"; [ -n "$_tb_py" ] || exit 0

# invoke trackboard.resilience on a bare python3 (PYTHONPATH=<checkout>/src), FLEET_STATE_DIR passed through so the
# sweep reads/writes the SAME telemetry markers the reporter wrote.
_rez() { PYTHONPATH="$_tb_home/src${PYTHONPATH:+:$PYTHONPATH}" FLEET_STATE_DIR="$(_tb_state_dir)" "$_tb_py" -m trackboard.resilience "$@" 2>/dev/null; }

# append a recovery nudge to a sid's inbox — system sender, matching cmd_msg's line format so the dispatcher +
# the agent's inbox reader treat it as a normal DM. Only nudge a session that already HAS an inbox (a known agent).
_post_recovery() {  # $1=sid  $2=kind
  local sid="$1" kind="$2" ibox="$INBOX_DIR/$1.jsonl" body mid
  [ -f "$ibox" ] || return 0
  body="[resilience recovery] The API path you failed on (${kind}) is confirmed back online (N-of-M stabilized). Resume where you left off and re-run your last step."
  mid="$(now_epoch)-$$-${RANDOM:-0}"
  printf '%s\n' "{$(jstr msg_id "$mid"),$(jstr ts "$(now_iso)"),$(jstr from resilience-sweep),$(jstr from_short resilience),$(jstr to "$(short_sid "$sid")"),$(jstr body "$body")}" >> "$ibox" 2>/dev/null || true
}

# --sweep prints `<sid> <kind> <retry_n>` for each recovered/ready agent
_rez --sweep | while read -r _sid _kind _retry; do
  [ -n "$_sid" ] || continue
  _post_recovery "$_sid" "$_kind"
  _rez --mark-nudged "$_sid"        # non-destructive stamp — do not re-nudge this failure episode
done
exit 0
