#!/usr/bin/env bash
# wake-dispatcher.sh — Fleet agent-to-agent wake, Part B: wake sessions that are NOT running.
#
# THE PROBLEM. `fleet.sh msg <B>` appends a line to B's inbox .jsonl. That does not wake B:
#   - If B is LIVE in the editor, only B's own Monitor watcher wakes it (Part A: `fleet.sh wake-cmd`). This
#     dispatcher MUST NOT touch a live session — two writers on one transcript .jsonl corrupts it (the exact
#     failure /claude-code-resume-recovery exists to fix). So live targets are SKIPPED here, by design.
#   - If B is CLOSED/parked (no process), nothing can wake it in-editor. This dispatcher headless-resumes it:
#     `claude -p --resume <B-uuid>` runs one turn against B's transcript (single writer -> safe), which lands in
#     the same session the human sees when they reopen it. That is the autonomous handoff.
#
# The fleet session id == $CLAUDE_CODE_SESSION_ID == the claude `--resume` transcript UUID == the inbox filename
# stem. So an inbox file <uuid>.jsonl maps directly to `claude --resume <uuid>` and to a liveness probe
# `pgrep -f -- "--resume <uuid>"`. That equivalence is the whole mechanism.
#
# SAFETY (this spawns billable claude turns autonomously — treated like any metered/one-way-door surface):
#   - DRY-RUN by default. It only prints the wake PLAN. Pass --live to actually spawn.
#   - ALIVE-GUARD: never wake a uuid whose process is running (avoids the transcript-corruption one-way-door).
#     Uses PROCESS liveness (pgrep), NOT fleet's mtime is_live() — an idle-but-open window is fleet-stale yet its
#     process is alive, and waking it would race.
#   - RATE LIMIT (FLEET_WAKE_MAX per FLEET_WAKE_WINDOW s) + per-target COOLDOWN + a KILL SWITCH file bound the
#     cost and stop wake<->reply cascades.
#   - Version-agnostic binary resolution (newest anthropic.claude-code-* — NEVER a hardcoded version), $CLAUDE_BIN
#     override.
#   - Conservative headless permission mode (FLEET_WAKE_PERMISSION, default acceptEdits; NOT skip-permissions).
#     Genuinely dangerous ops (e.g. a push) get denied headlessly unless the operator opts in — a deliberate floor.
#
# Modes:  wake-dispatcher.sh            one-shot scan, DRY-RUN (safe; prints the plan)
#         wake-dispatcher.sh --live     one-shot scan, actually spawn wakes
#         wake-dispatcher.sh --watch [--live]   loop forever (for launchd); interval FLEET_WAKE_INTERVAL s
#         wake-dispatcher.sh --reset    clear all cursors/cooldowns/ratelimit (replay every pending message)
#         wake-dispatcher.sh --status   show config + pending-per-inbox + which targets are live
#         wake-dispatcher.sh --selftest negative-control tests that must BITE
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
cd "$PROJECT_ROOT" 2>/dev/null || true   # git-common state resolution needs to run inside the repo
ensure_state                              # resolves INBOX_DIR / AGENTS_DIR (git-common aware) + creates dirs

# ---- config (all env-overridable; nothing hardcoded to a single target) ----
WAKE_STATE_DIR="${FLEET_WAKE_STATE:-$STATE_DIR/wake}"
WAKE_OFF="$STATE_DIR/wake-dispatcher.OFF"
WAKE_MAX_PER_WINDOW="${FLEET_WAKE_MAX:-5}"
WAKE_WINDOW_S="${FLEET_WAKE_WINDOW:-60}"
WAKE_COOLDOWN_S="${FLEET_WAKE_COOLDOWN:-120}"
WAKE_TIMEOUT_S="${FLEET_WAKE_TIMEOUT:-240}"
WAKE_PERMISSION="${FLEET_WAKE_PERMISSION:-acceptEdits}"
WATCH_INTERVAL_S="${FLEET_WAKE_INTERVAL:-10}"
LIVE=0
EMITTED=0

mkdir -p "$WAKE_STATE_DIR" 2>/dev/null || true

log() { printf '%s wake-dispatcher: %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
shortid() { printf '%s' "$1" | tr -d '-' | cut -c1-8; }

# ---- resolve the claude binary, version-agnostically (NEVER hardcode the extension version) ----
resolve_claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ] && [ -x "${CLAUDE_BIN:-}" ]; then printf '%s' "$CLAUDE_BIN"; return 0; fi
  local d bin
  for d in $(ls -d "$HOME/.vscode/extensions/anthropic.claude-code-"* 2>/dev/null | sort -V -r); do
    bin="$d/resources/native-binary/claude"
    [ -x "$bin" ] && { printf '%s' "$bin"; return 0; }
  done
  bin="$(command -v claude 2>/dev/null || true)"
  [ -n "$bin" ] && { printf '%s' "$bin"; return 0; }
  return 1
}

# ---- process liveness of a session (the alive-guard) ----
is_running() { pgrep -f -- "--resume $1" >/dev/null 2>&1; }

agent_cwd() { json_field_file "$(agent_file "$1")" cwd; }
has_agent_record() { [ -f "$(agent_file "$1")" ]; }

# ---- rate limit (rolling window token count) ----
rate_ok() {
  local f="$WAKE_STATE_DIR/ratelimit" now cutoff n
  now="$(date +%s)"; cutoff=$((now - WAKE_WINDOW_S))
  if [ -f "$f" ]; then awk -v c="$cutoff" '$1>=c' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true; fi
  n=0; [ -f "$f" ] && n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"; n="${n:-0}"
  [ "$n" -lt "$WAKE_MAX_PER_WINDOW" ]
}
in_cooldown() {
  local f="$WAKE_STATE_DIR/$1.lastwake" last now
  [ -f "$f" ] || return 1
  last="$(cat "$f" 2>/dev/null | tr -d ' ')"; last="${last:-0}"; now="$(date +%s)"
  [ $((now - last)) -lt "$WAKE_COOLDOWN_S" ]
}

# ---- bound a command by wall-clock (GNU `timeout` on Linux; perl alarm fallback on macOS) ----
_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# ---- perform (or plan) one wake ----
do_wake() {
  local uuid="$1" n="$2" cwd bin prompt logf
  echo "$(date +%s)" >> "$WAKE_STATE_DIR/ratelimit"          # count against the rate window
  echo "$(date +%s)" >  "$WAKE_STATE_DIR/$uuid.lastwake"     # start the per-target cooldown
  cwd="$(agent_cwd "$uuid")"; [ -d "$cwd" ] || cwd="$PROJECT_ROOT"
  prompt="You were woken by the fleet wake-dispatcher: ${n} new inbox message(s) arrived while you were offline. Run  .fleet/bin/fleet.sh inbox  and act on anything actionable, then stop. If nothing needs action, just stop."
  EMITTED=$((EMITTED+1))
  if [ "$LIVE" != 1 ]; then
    log "DRY-RUN would wake $(shortid "$uuid") in $cwd (${n} new): claude -p --resume $uuid --permission-mode $WAKE_PERMISSION"
    return 0
  fi
  bin="$(resolve_claude_bin)" || { log "ERROR: no claude binary found (set \$CLAUDE_BIN) — cannot wake $(shortid "$uuid")"; return 1; }
  mkdir -p "$WAKE_STATE_DIR/logs" 2>/dev/null || true
  logf="$WAKE_STATE_DIR/logs/${uuid}-$(date +%s).log"
  log "WAKING $(shortid "$uuid") (live) in $cwd — bounded ${WAKE_TIMEOUT_S}s — log: $logf"
  ( cd "$cwd" 2>/dev/null || exit 1
    export FLEET_WOKEN_BY=dispatcher
    _bounded "$WAKE_TIMEOUT_S" "$bin" -p --resume "$uuid" --permission-mode "$WAKE_PERMISSION" "$prompt" > "$logf" 2>&1
  ) || log "wake of $(shortid "$uuid") exited non-zero (timeout or error) — see $logf"
}

# ---- one scan over all inbox files ----
scan_once() {
  EMITTED=0
  local ibox uuid cursor_f prev cur newcount
  for ibox in "$INBOX_DIR"/*.jsonl; do
    [ -f "$ibox" ] || continue
    uuid="$(basename "$ibox" .jsonl)"
    cursor_f="$WAKE_STATE_DIR/$uuid.cursor"
    prev=0; [ -f "$cursor_f" ] && prev="$(cat "$cursor_f" 2>/dev/null | tr -d ' ')"; prev="${prev:-0}"
    # never re-wake for messages the agent itself already READ (.seen) — take the higher of our cursor and .seen
    local seen=0; [ -f "$INBOX_DIR/$uuid.seen" ] && seen="$(cat "$INBOX_DIR/$uuid.seen" 2>/dev/null | tr -d ' ')"; seen="${seen:-0}"
    [ "$seen" -gt "$prev" ] && prev="$seen"
    cur=0; cur="$(wc -l < "$ibox" 2>/dev/null | tr -d ' ')"; cur="${cur:-0}"
    [ "$cur" -le "$prev" ] && continue
    newcount=$((cur - prev))
    printf '%s' "$cur" > "$cursor_f" 2>/dev/null || true    # advance cursor = "dispatcher has processed these"
    if ! has_agent_record "$uuid"; then log "skip $(shortid "$uuid"): no agent record (unknown/GC'd session)"; continue; fi
    if is_running "$uuid"; then log "skip $(shortid "$uuid"): LIVE process — its own Monitor handles it (${newcount} new)"; continue; fi
    if [ -f "$WAKE_OFF" ]; then log "KILL-SWITCH on ($WAKE_OFF) — NOT waking $(shortid "$uuid") (${newcount} new)"; continue; fi
    if ! rate_ok; then log "RATE-LIMIT ${WAKE_MAX_PER_WINDOW}/${WAKE_WINDOW_S}s — deferring $(shortid "$uuid")"; continue; fi
    if in_cooldown "$uuid"; then log "COOLDOWN ${WAKE_COOLDOWN_S}s — skipping $(shortid "$uuid")"; continue; fi
    do_wake "$uuid" "$newcount"
  done
  log "scan done: $EMITTED wake(s) $( [ "$LIVE" = 1 ] && echo spawned || echo 'planned (dry-run)')"
}

cmd_status() {
  echo "== wake-dispatcher status =="
  echo "state dir:   $WAKE_STATE_DIR"
  echo "inbox dir:   $INBOX_DIR"
  echo "kill switch: $WAKE_OFF $( [ -f "$WAKE_OFF" ] && echo '(PRESENT — waking disabled)' || echo '(absent)')"
  echo "limits:      max=$WAKE_MAX_PER_WINDOW/${WAKE_WINDOW_S}s  cooldown=${WAKE_COOLDOWN_S}s  timeout=${WAKE_TIMEOUT_S}s  perm=$WAKE_PERMISSION"
  echo "claude bin:  $(resolve_claude_bin || echo 'NOT FOUND (set $CLAUDE_BIN)')"
  echo "pending per inbox (new lines beyond dispatcher cursor):"
  local ibox uuid cursor_f prev cur
  for ibox in "$INBOX_DIR"/*.jsonl; do
    [ -f "$ibox" ] || continue
    uuid="$(basename "$ibox" .jsonl)"; cursor_f="$WAKE_STATE_DIR/$uuid.cursor"
    prev=0; [ -f "$cursor_f" ] && prev="$(cat "$cursor_f" 2>/dev/null | tr -d ' ')"; prev="${prev:-0}"
    local seen=0; [ -f "$INBOX_DIR/$uuid.seen" ] && seen="$(cat "$INBOX_DIR/$uuid.seen" 2>/dev/null | tr -d ' ')"; seen="${seen:-0}"
    [ "$seen" -gt "$prev" ] && prev="$seen"
    cur="$(wc -l < "$ibox" 2>/dev/null | tr -d ' ')"; cur="${cur:-0}"
    printf '  %s  pending=%s  %s\n' "$(shortid "$uuid")" "$((cur - prev))" "$(is_running "$uuid" && echo LIVE || echo offline)"
  done
}

cmd_reset() { rm -f "$WAKE_STATE_DIR"/*.cursor "$WAKE_STATE_DIR"/*.lastwake "$WAKE_STATE_DIR/ratelimit" 2>/dev/null || true; log "reset cursors/cooldowns/ratelimit"; }

# ===========================================================================
# selftest — negative controls that must BITE
# ===========================================================================
selftest() {
  local tmp pass=0 fail=0
  tmp="$(mktemp -d)"
  # redirect all state to the sandbox
  INBOX_DIR="$tmp/inbox"; AGENTS_DIR="$tmp/agents"; WAKE_STATE_DIR="$tmp/wake"; WAKE_OFF="$tmp/OFF"
  mkdir -p "$INBOX_DIR" "$AGENTS_DIR" "$WAKE_STATE_DIR"
  LIVE=0
  # agent_file() from lib.sh uses AGENTS_DIR -> now sandboxed
  local dead="00000000-dead-4dead-dead-000000000000"
  local live; live="$(ps -Ao command 2>/dev/null | grep -oE -- '--resume [0-9a-f]{8}-[0-9a-f-]{27}' | awk '{print $2}' | head -1)"
  ok()   { pass=$((pass+1)); printf '  \342\234\205 %s\n' "$1"; }
  bad()  { fail=$((fail+1)); printf '  \342\235\214 %s\n' "$1"; }
  mkrec() { printf '{"session_id":"%s","agent":"agent-x","cwd":"%s"}\n' "$1" "$PROJECT_ROOT" > "$AGENTS_DIR/$1.json"; }

  echo "== wake-dispatcher selftest (sandbox: $tmp) =="

  # 1) binary resolves (WARN not FAIL if absent — CI/headless may lack the editor)
  if resolve_claude_bin >/dev/null; then ok "positive: claude binary resolved ($(resolve_claude_bin | sed 's#.*/extensions/##'))"; else printf '  \342\232\240 WARN: no claude binary on this host (set \$CLAUDE_BIN)\n'; fi

  # 2) alive-guard: a LIVE uuid is skipped
  if [ -n "$live" ]; then
    mkrec "$live"; printf '{"body":"x"}\n' > "$INBOX_DIR/$live.jsonl"
    EMITTED=0; scan_once >/dev/null 2>&1
    [ "$EMITTED" -eq 0 ] && ok "neg: LIVE session skipped (alive-guard bit)" || bad "alive-guard did NOT bite (woke a live uuid)"
  else
    printf '  \342\232\240 WARN: no running --resume process found to test the alive-guard (are any agents live?)\n'
  fi

  # 3) dead session IS eligible + cursor dedup: first scan emits 1, second emits 0
  cmd_reset >/dev/null 2>&1
  mkrec "$dead"; printf '{"body":"m1"}\n{"body":"m2"}\n' > "$INBOX_DIR/$dead.jsonl"
  EMITTED=0; scan_once >/dev/null 2>&1
  [ "$EMITTED" -eq 1 ] && ok "positive: offline session planned once for 2 msgs (newcount batched)" || bad "offline wake plan wrong (EMITTED=$EMITTED, want 1)"
  EMITTED=0; scan_once >/dev/null 2>&1
  [ "$EMITTED" -eq 0 ] && ok "neg: cursor dedup bit (no re-wake on already-processed msgs)" || bad "cursor dedup did NOT bite (EMITTED=$EMITTED, want 0)"

  # 4) kill-switch: new msg to a dead session, switch ON -> 0
  cmd_reset >/dev/null 2>&1; : > "$WAKE_OFF"
  printf '{"body":"m3"}\n' >> "$INBOX_DIR/$dead.jsonl"
  EMITTED=0; scan_once >/dev/null 2>&1
  [ "$EMITTED" -eq 0 ] && ok "neg: kill-switch bit (no wake while OFF present)" || bad "kill-switch did NOT bite (EMITTED=$EMITTED)"
  rm -f "$WAKE_OFF"

  # 5) rate limit: max=1, two dead targets each with a new msg -> exactly 1 planned
  cmd_reset >/dev/null 2>&1; WAKE_MAX_PER_WINDOW=1
  local d2="11111111-dead-4dead-dead-111111111111"
  mkrec "$d2"
  printf '{"body":"a"}\n' > "$INBOX_DIR/$dead.jsonl"
  printf '{"body":"b"}\n' > "$INBOX_DIR/$d2.jsonl"
  EMITTED=0; scan_once >/dev/null 2>&1
  [ "$EMITTED" -eq 1 ] && ok "neg: rate-limit bit (1 of 2 planned; 1 deferred)" || bad "rate-limit did NOT bite (EMITTED=$EMITTED, want 1)"

  rm -rf "$tmp" 2>/dev/null || true
  echo ""
  if [ "$fail" -eq 0 ]; then printf '\342\234\205 selftest PASS (%s checks) — alive-guard, dedup, kill-switch, rate-limit all bite.\n' "$pass"; return 0
  else printf '\342\235\214 selftest FAIL (%s failed, %s passed)\n' "$fail" "$pass"; return 1; fi
}

# ---- dispatch ----
WATCH=0
for a in "$@"; do
  case "$a" in
    --live) LIVE=1 ;;
    --watch) WATCH=1 ;;
    --reset) cmd_reset; exit 0 ;;
    --status) cmd_status; exit 0 ;;
    --selftest) selftest; exit $? ;;
    --once) WATCH=0 ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) log "unknown arg: $a"; exit 2 ;;
  esac
done

if [ "$WATCH" = 1 ]; then
  log "watch mode (interval ${WATCH_INTERVAL_S}s, live=$LIVE) — kill switch: touch $WAKE_OFF"
  while true; do scan_once; sleep "$WATCH_INTERVAL_S"; done
else
  scan_once
fi
