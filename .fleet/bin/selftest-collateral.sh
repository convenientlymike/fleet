#!/usr/bin/env bash
# selftest-collateral.sh — the FORCING FUNCTION for the 2026-09-02 shared-tree collateral fixes.
#
# Proves the fixes BITE (a control that never fires is not a control):
#   C0a  ensure_self_registered RE-CREATES a reaped agent file for a provably-alive session (the heartbeat
#        tail-fix), so an actively-working window can't stay invisible until its next prompt; touch-only does not.
#   C0b  reap() / _release_claims_of KEEP a claim whose path is DIRTY (live work), REMOVE one that is clean.
#   C1   commit-guard blocks a staged file covered by a foreign claim whose path is DIRTY (regardless of liveness),
#        and does NOT over-block (foreign+clean, own, unclaimed) — delegated to commit-guard.sh --selftest.
#   D    a DM to a STALE (non-live but kept) window is DELIVERED to its inbox (reap keeps the file; sid_for_target
#        resolves it) — the dropped-DM fix; a truly-abandoned file is GC'd; an unknown target is rejected (no false send).
#
# Hermetic: builds a throwaway git repo + a temp fleet state dir, exercises the REAL lib.sh functions against them
# (no live fleet state touched). Exit 0 = all controls bit + no false-positive; non-zero = a fix regressed.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok=1
fail() { echo "  ✗ $1"; ok=0; }
pass() { echo "  ✓ $1"; }

# ── C0b: reap keeps a dirty-path claim, removes a clean-path claim ──────────────────────────────
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT
(
  cd "$tmp"
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p work
  echo committed > work/file.txt
  git add -A && git commit -qm init

  # Source the REAL lib, THEN repoint its globals at this throwaway repo. (lib.sh recomputes PROJECT_ROOT from its
  # own path on source, so the override MUST come after — bash reads globals at call-time, so this is honored.)
  . "$DIR/lib.sh" 2>/dev/null
  PROJECT_ROOT="$tmp"
  STATE_DIR="$tmp/.fleet-state"; AGENTS_DIR="$STATE_DIR/agents"; CLAIMS_DIR="$STATE_DIR/claims"
  BOARD_FILE="$STATE_DIR/board.jsonl"; LEDGER_FILE="$STATE_DIR/ledger.jsonl"; INBOX_DIR="$STATE_DIR/inbox"
  mkdir -p "$AGENTS_DIR" "$CLAIMS_DIR" "$INBOX_DIR"

  # a DEAD (stale) owner: an agent file with an ancient mtime (< now - stale_after_s).
  dead="deadsid1111"
  printf '{"agent":"agent-9","session_id":"%s"}\n' "$dead" > "$AGENTS_DIR/$dead.json"
  touch -t 200001010000 "$AGENTS_DIR/$dead.json"

  seed_claim() {  # <lockname> <path>
    local L="$CLAIMS_DIR/$1.lock"; mkdir -p "$L"
    printf '{"path":"%s","owner_session_id":"%s","agent":"agent-9"}\n' "$2" "$dead" > "$L/meta.json"
    printf '%s' "$L"
  }

  # (1) claim over a DIRTY path → must SURVIVE reap.
  echo dirty >> work/file.txt                      # make work/ dirty
  d1="$(seed_claim dirtyclaim work)"
  # (2) claim over a CLEAN path → must be REMOVED by reap.
  d2="$(seed_claim cleanclaim other-clean-path)"   # never-touched path = clean

  _release_claims_of "$dead"                        # the exact reap→dead-agent path

  [ -d "$d1" ] && pass "C0b: reap KEEPS a dirty-path claim (live work protected)" || fail "C0b: reap DROPPED a dirty-path claim — the collateral bug is BACK"
  [ -d "$d2" ] && fail "C0b control: reap KEPT a clean-path claim (over-blocking — would wedge)" || pass "C0b control: reap removes a clean-path claim (no over-keep)"

  # negative control: prove the check is load-bearing — with the guard bypassed, the dirty claim WOULD be dropped.
  _claim_path_dirty() { return 1; }                 # force "always clean"
  d3="$(seed_claim dirtyclaim2 work)"               # work/ is still dirty
  _release_claims_of "$dead"
  [ -d "$d3" ] && fail "C0b neg-control: dirty claim survived even with the guard disabled (test is not exercising the guard)" \
                || pass "C0b neg-control: disabling the dirty-guard DROPS the dirty claim (the guard is load-bearing)"

  [ "$ok" = 1 ]
) || ok=0

# ── C1: delegate to the commit-guard's own hermetic selftest (cases 1–6) ────────────────────────
if [ -x "$DIR/commit-guard.sh" ]; then
  if "$DIR/commit-guard.sh" --selftest >/dev/null 2>&1; then pass "C1: commit-guard --selftest (foreign-dirty BITES; own/clean/unclaimed pass)"; else fail "C1: commit-guard --selftest FAILED"; fi
fi

# ── C0a: ensure_self_registered RE-CREATES a reaped-but-active agent file (the heartbeat tail-fix) ──────────────
tmpa="$(mktemp -d)"
(
  cd "$tmpa"
  . "$DIR/lib.sh" 2>/dev/null
  PROJECT_ROOT="$tmpa"
  STATE_DIR="$tmpa/.fleet-state"; AGENTS_DIR="$STATE_DIR/agents"; CLAIMS_DIR="$STATE_DIR/claims"
  BOARD_FILE="$STATE_DIR/board.jsonl"; LEDGER_FILE="$STATE_DIR/ledger.jsonl"; INBOX_DIR="$STATE_DIR/inbox"
  mkdir -p "$AGENTS_DIR" "$CLAIMS_DIR" "$INBOX_DIR"
  sid="revivesid2222"; af="$AGENTS_DIR/$sid.json"

  # a tool just ran for a session whose file reap() already deleted (file MISSING) → must be re-created + live.
  [ -f "$af" ] || true
  ensure_self_registered "$sid"
  { [ -f "$af" ] && is_live "$sid"; } \
    && pass "C0a: heartbeat re-creates a reaped-but-active agent file (never invisible until next prompt)" \
    || fail "C0a: reaped agent file NOT re-created/live — an active window would stay invisible"

  # negative control: the OLD touch-only behavior leaves a reaped file missing → proves the re-create is load-bearing.
  rm -f "$af"
  touch_only() { local f; f="$(agent_file "$1")"; [ -f "$f" ] && touch "$f" 2>/dev/null || true; }
  touch_only "$sid"
  [ -f "$af" ] && fail "C0a neg-control: touch-only re-created the file (test not exercising the fix)" \
               || pass "C0a neg-control: touch-only leaves a reaped file missing (the re-create is load-bearing)"

  [ "$ok" = 1 ]
) || ok=0
rm -rf "$tmpa" 2>/dev/null || true

# ── D: DM durability — a DM to a STALE (kept) window is delivered; GC bounds the dir; unknown target rejected ──────
tmpd="$(mktemp -d)"
(
  cd "$tmpd"
  . "$DIR/lib.sh" 2>/dev/null
  # export the sandbox globals so sourced lib.sh helpers see them (and shellcheck knows they're used, not dead)
  export PROJECT_ROOT="$tmpd"
  export FLEET_STATE_DIR="$tmpd/.fleet-state"
  STATE_DIR="$FLEET_STATE_DIR"; AGENTS_DIR="$STATE_DIR/agents"; CLAIMS_DIR="$STATE_DIR/claims"
  export BOARD_FILE="$STATE_DIR/board.jsonl"; export LEDGER_FILE="$STATE_DIR/ledger.jsonl"; INBOX_DIR="$STATE_DIR/inbox"
  mkdir -p "$AGENTS_DIR" "$CLAIMS_DIR" "$INBOX_DIR"
  age1h() { touch -d '1 hour ago' "$1" 2>/dev/null || touch -t "$(date -v-1H +%Y%m%d%H%M)" "$1"; }

  tgt="staletarget99"
  printf '{"session_id":"%s","agent":"agent-7","short":"staletar","status":"active"}\n' "$tgt" > "$AGENTS_DIR/$tgt.json"
  age1h "$AGENTS_DIR/$tgt.json"                    # stale (> stale_after) but < agent_gc_s → reap must KEEP it

  reap
  [ -f "$AGENTS_DIR/$tgt.json" ] && pass "D: reap KEEPS a stale agent file (sid stays addressable)" \
                                  || fail "D: reap DELETED a stale file — DMs to it would drop"

  CLAUDE_CODE_SESSION_ID=sendersid001 bash "$DIR/fleet.sh" --id sendersid001 msg agent-7 "durability ping" >/dev/null 2>&1
  if [ -f "$INBOX_DIR/$tgt.jsonl" ] && grep -q "durability ping" "$INBOX_DIR/$tgt.jsonl"; then
    pass "D: a DM to a STALE (non-live) window is DELIVERED to its inbox (not dropped)"
  else
    fail "D: a DM to a stale window was DROPPED (durability fix not working)"
  fi

  old="ancienttarget"; printf '{"session_id":"%s","agent":"agent-8"}\n' "$old" > "$AGENTS_DIR/$old.json"
  touch -t 200001010000 "$AGENTS_DIR/$old.json"    # > agent_gc_s (24h) → reap must GC it
  reap
  [ -f "$AGENTS_DIR/$old.json" ] && fail "D control: an ancient (>agent_gc_s) file survived reap (unbounded growth)" \
                                  || pass "D control: reap GC-deletes a truly-abandoned agent file (dir bounded)"

  if CLAUDE_CODE_SESSION_ID=sendersid001 bash "$DIR/fleet.sh" --id sendersid001 msg agent-99 "x" >/dev/null 2>&1; then
    fail "D neg-control: msg to an unknown target SUCCEEDED (false delivery)"
  else
    pass "D neg-control: msg to a truly-unknown target is rejected (no false delivery)"
  fi

  [ "$ok" = 1 ]
) || ok=0
rm -rf "$tmpd" 2>/dev/null || true

# ── DELIVERY: heartbeat.sh (PostToolUse) surfaces unread DMs via additionalContext JSON; .seen advances only on emit
#    (the reliability-backbone forcing function — bare PostToolUse stdout is NOT injected, so this proves the JSON path)
dlv="$(mktemp -d)"
(
  export FLEET_STATE_DIR="$dlv/state"; mkdir -p "$FLEET_STATE_DIR/inbox" "$FLEET_STATE_DIR/agents"
  sid="dlvsid1"
  printf '{"from":"agent-2","body":"DELIVERY NONCE 4f9a"}\n' > "$FLEET_STATE_DIR/inbox/$sid.jsonl"
  out="$(printf '{"session_id":"%s"}' "$sid" | FLEET_STATE_DIR="$FLEET_STATE_DIR" CLAUDE_CODE_SESSION_ID="$sid" bash "$DIR/heartbeat.sh" 2>/dev/null)"
  if printf '%s' "$out" | grep -q 'DELIVERY NONCE 4f9a' && printf '%s' "$out" | grep -q 'additionalContext' \
     && [ "$(cat "$FLEET_STATE_DIR/inbox/$sid.seen" 2>/dev/null)" = "1" ]; then
    pass "DELIVERY: heartbeat surfaces an unread DM via additionalContext JSON + advances seen"
  else
    fail "DELIVERY: heartbeat did NOT inject the DM / advance seen (out=$out)"
  fi
  # neg-control: no new DM → silent, seen unchanged (proves it only injects real new DMs)
  out2="$(printf '{"session_id":"%s"}' "$sid" | FLEET_STATE_DIR="$FLEET_STATE_DIR" FLEET_PULL_THROTTLE_S=0 CLAUDE_CODE_SESSION_ID="$sid" bash "$DIR/heartbeat.sh" 2>/dev/null)"
  if [ -z "$out2" ] && [ "$(cat "$FLEET_STATE_DIR/inbox/$sid.seen")" = "1" ]; then
    pass "DELIVERY neg-control: no new DM → silent, seen unchanged"
  else
    fail "DELIVERY neg-control: re-emitted or moved seen with nothing new (out2=$out2)"
  fi
  [ "$ok" = 1 ]
) || ok=0
rm -rf "$dlv" 2>/dev/null || true

# ── SETTINGS DRIFT: the checked-in settings.json MUST wire the delivery/wake hooks (the exact class that drifted
#    2026-09-05 — heartbeat + wake nudges were absent). Bites if a hook the installer wires is missing from settings.
S_JSON="$DIR/../../.claude/settings.json"
if [ -f "$S_JSON" ]; then
  if grep -q 'heartbeat.sh' "$S_JSON" && grep -q 'wake_nudge.sh' "$S_JSON" && grep -q 'awareness.sh' "$S_JSON" && grep -q 'multiwindow_nudge.sh' "$S_JSON"; then
    pass "SETTINGS: checked-in settings.json wires the delivery/wake hooks (heartbeat + awareness + wake_nudge + multiwindow)"
  else
    fail "SETTINGS DRIFT: checked-in settings.json is MISSING a delivery/wake hook the installer wires (heartbeat/awareness/wake_nudge/multiwindow)"
  fi
fi

echo
[ "$ok" = 1 ] && { echo "selftest-collateral: OK — every collateral fix BITES + no over-block"; exit 0; }
echo "selftest-collateral: FAIL — a collateral fix regressed"; exit 1
