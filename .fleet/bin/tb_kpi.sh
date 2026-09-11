#!/usr/bin/env bash
# tb_kpi.sh — trackboard KPI-reporter deploy shim (telemetry slice 3, B7). SIDE-EFFECT-FREE when sourced: it only
# DEFINES functions (no top-level work), so a test / caller can `source tb_kpi.sh; _tb_kpi <sid>` with ZERO fleet
# side effects (never touches ensure_self_registered / the DM scan). heartbeat.sh sources this and calls
# `_tb_kpi "$SID"` BACKGROUNDED + fail-open, after ensure_self_registered.
#
# WHY: the KPI reporter runs from a GLOBAL fleet PostToolUse hook on ANY registered box. It must succeed on a BARE
# python3 — the dependency-light telemetry_store extraction (no fastapi/pydantic pull) guarantees that via
# PYTHONPATH=<checkout>/src. A fastapi+pydantic venv per box would ROT SILENTLY (a new/moved/un-provisioned box ->
# the hook silent-no-ops -> NO KPIs flow, invisibly = the multi-device "wrong/no target" failure class the
# operator's doctrine forbids). So this shim (1) RESOLVES the trackboard checkout on THIS box (never a lying
# default — fail-loud on none), (2) runs the reporter on a bare python3, and (3) on ANY failure (unresolved
# checkout OR import/run error) writes a LOUD, THROTTLED breadcrumb (a marker file + a best-effort board note) so a
# broken wiring is VISIBLE, never a silent no-op. Pairs with the B7 importability gate (tests/test_telemetry_b7_*).

# --- minimal SELF-CONTAINED helpers (deliberately do NOT depend on lib.sh — this lib is sourced standalone) ------
_tb_now()  { date +%s 2>/dev/null || echo 0; }
_tb_host() { hostname -s 2>/dev/null || uname -n 2>/dev/null | cut -d. -f1 || echo unknown; }
_tb_mtime() {  # $1=file -> epoch mtime (BSD stat -f, then GNU stat -c), 0 if absent/unknown
  [ -f "$1" ] || { echo 0; return; }
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}
# Telemetry state dir — resolved the SAME way trackboard.telemetry_store.state_dir() does (FLEET_STATE_DIR first),
# so the reporter's KPI overlay and this shim's breadcrumb marker always land in the SAME telemetry/ dir. STATE_DIR
# (set by lib.sh when running inside the real heartbeat) is the fallback; else a sane per-user default.
_tb_state_dir() { printf '%s\n' "${FLEET_STATE_DIR:-${STATE_DIR:-$HOME/.fleet/state}}"; }

# --- resolver: the trackboard checkout on THIS box. Order: explicit env -> per-box registry -> well-known default
#     (ONLY if it truly has the package) -> return 1 (unresolvable). NEVER a bare/lying default (multi-device rule).
_tb_resolve_home() {
  if [ -n "${TRACKBOARD_HOME:-}" ] && [ -d "${TRACKBOARD_HOME}/src/trackboard" ]; then printf '%s\n' "$TRACKBOARD_HOME"; return 0; fi
  local reg h; reg="$(_tb_state_dir)/trackboard_home"          # one line = the checkout path on this box
  if [ -f "$reg" ]; then h="$(head -n1 "$reg" 2>/dev/null)"; [ -n "$h" ] && [ -d "$h/src/trackboard" ] && { printf '%s\n' "$h"; return 0; }; fi
  if [ -d "$HOME/Desktop/trackboard/src/trackboard" ]; then printf '%s\n' "$HOME/Desktop/trackboard"; return 0; fi
  return 1
}

# --- non-silent breadcrumb: a LOUD marker file (+ best-effort board note), throttled to <= 1/hour so a 50-tool
#     burst can't spam. The MARKER is the load-bearing signal (asserted by the B7 gate); board_event is a bonus
#     only when running inside the full heartbeat (lib.sh sourced) — skipped when this lib is sourced standalone.
_tb_kpi_breadcrumb() {  # $1 = reason
  local reason="${1:-unknown}" host now dir marker last
  host="$(_tb_host)"; now="$(_tb_now)"
  dir="$(_tb_state_dir)/telemetry"; marker="$dir/.kpi_unwired.$host"
  mkdir -p "$dir" 2>/dev/null || return 0
  last="$(_tb_mtime "$marker")"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $(( now - last )) -ge 3600 ]; then
    printf '{"host":"%s","ts":%s,"reason":"%s","hint":"set TRACKBOARD_HOME to the trackboard checkout (a dir containing src/trackboard)"}\n' \
      "$host" "$now" "$reason" > "$marker" 2>/dev/null || true
    if command -v board_event >/dev/null 2>&1; then
      board_event "⚠ trackboard KPI reporter NOT wired on $host — no KPIs flowing (reason: $reason; set \$TRACKBOARD_HOME)" 2>/dev/null || true
    fi
  fi
}

# --- _tb_kpi <sid> : run the reporter on a bare python3 via PYTHONPATH=<checkout>/src; breadcrumb LOUD on any
#     failure. Synchronous (the CALLER backgrounds it in the heartbeat); returns 0 always (fail-open, never blocks).
_tb_kpi() {
  local sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}"; [ -n "$sid" ] || return 0
  local home py; home="$(_tb_resolve_home)" || { _tb_kpi_breadcrumb "unresolved-checkout"; return 0; }
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"; [ -n "$py" ] || { _tb_kpi_breadcrumb "no-python3"; return 0; }
  # FORK PRE-GATE: at most ~1 python fork / TB_KPI_MIN_FORK_S (default 30s) / agent, so a busy tool-use burst does
  # NOT spawn python on every call (report_kpi is ALSO time-throttled internally; this avoids even the process
  # spawn). Runs AFTER the resolve so an UNWIRED box still breadcrumbs every tool (the breadcrumb has its own
  # hourly throttle). TB_KPI_MIN_FORK_S=0 disables the pre-gate (tests). Marker: <telemetry>/.kpi_fork.<sid>.
  local win fdir fmark last now; win="${TB_KPI_MIN_FORK_S:-30}"
  fdir="$(_tb_state_dir)/telemetry"; fmark="$fdir/.kpi_fork.$sid"; now="$(_tb_now)"
  if [ "$win" -gt 0 ] 2>/dev/null; then
    last="$(_tb_mtime "$fmark")"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - last )) -lt "$win" ] && return 0    # too soon since the last fork — skip (fail-open, no breadcrumb)
  fi
  mkdir -p "$fdir" 2>/dev/null; : > "$fmark" 2>/dev/null || true    # stamp the fork attempt BEFORE running
  # PYTHONPATH=<checkout>/src makes the bare reporter importable with no install; FLEET_STATE_DIR passthrough keeps
  # the reporter's KPI overlay + this shim's marker in the SAME telemetry dir (they must agree).
  if ! PYTHONPATH="$home/src${PYTHONPATH:+:$PYTHONPATH}" FLEET_STATE_DIR="$(_tb_state_dir)" \
       "$py" -m trackboard.telemetry_report --sid "$sid" --cwd "$PWD" >/dev/null 2>&1; then
    _tb_kpi_breadcrumb "import-or-run-failed"
  fi
  return 0
}
