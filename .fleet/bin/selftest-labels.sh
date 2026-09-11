#!/usr/bin/env bash
# selftest-labels.sh — the FORCING FUNCTION for the atomic agent-N label reservation (the duplicate-agent-1 fix).
#
# The bug: `next_label` READ the agent files then the caller WROTE its own — a TOCTOU window in which two windows
# registering concurrently both saw "agent-1 free" and both took it, so the roster showed two live "agent-1"s and
# a DM to "agent-1" mis-routed. The fix makes label assignment ATOMIC via a mkdir-mutex reservation
# (LABELS_DIR/agent-N/sid), stable-per-session, unique-among-live, with fail-loud routing on any residual dup.
#
# Proves each guarantee BITES, each paired with a control that fires (a control that never fires is not a control):
#   L1  reserve_label is ATOMIC — 8 CONCURRENT reservations get 8 DISTINCT labels.
#       control: the old read-then-write "naive pick" hands the SAME label to two not-yet-written sessions.
#   L2  a reservation is STABLE per session — a resume/heartbeat (and a different `preferred`) returns the SAME label.
#   L3  a freed label is REUSED — a non-live owner's slot is reclaimed; a LIVE owner's is never stolen.
#   L4  routing FAILS LOUD — a label held by >1 LIVE window makes `fleet.sh msg` exit 3 (naming candidates);
#       a short/sid id still resolves. control: a UNIQUE live label resolves (fail-loud does not over-trigger).
#   L5  continuity/migration bridge — an existing agent-file label with no reservation is PRESERVED (not renumbered);
#       control: a `preferred` already held by a LIVE other session is NOT stolen.
#   L6  reap GC bounds LABELS_DIR — a fully-reaped owner's reservation is removed; a kept (live) owner's is retained.
#
# Hermetic: a throwaway state dir (FLEET_STATE_DIR) + a pinned config (stale_after_s=180) exercise the REAL lib.sh /
# fleet.sh code; the live fleet state is never touched. Exit 0 = all guarantees bit + no false-positive.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok=1
fail() { echo "  ✗ $1"; ok=0; }
pass() { echo "  ✓ $1"; }

echo "═══ selftest: atomic agent-N label reservation ═══"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT
(
  export FLEET_STATE_DIR="$tmp/state"    # both this shell AND child `fleet.sh` processes resolve to the sandbox
  # shellcheck source=lib.sh
  . "$DIR/lib.sh" 2>/dev/null            # _fleet_resolve_state honors FLEET_STATE_DIR → STATE_DIR/AGENTS_DIR/LABELS_DIR sandboxed
  export PROJECT_ROOT="$tmp"
  CONFIG_FILE="$tmp/config.json"; printf '{"stale_after_s":180,"agent_gc_s":86400}\n' > "$CONFIG_FILE"  # deterministic liveness
  ensure_state

  # mk_agent <sid> <label> [old] — write an agent file (fresh=live; "old" => 1h ago => stale/not-live).
  mk_agent() {
    printf '{"session_id":"%s","agent":"%s","short":"%s","status":"active"}\n' "$1" "$2" "$(short_sid "$1")" > "$AGENTS_DIR/$1.json"
    if [ "${3:-}" = old ]; then touch -d '1 hour ago' "$AGENTS_DIR/$1.json" 2>/dev/null || touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || echo 200001010000)" "$AGENTS_DIR/$1.json"; fi
    return 0
  }

  # ── L1: atomic — 8 CONCURRENT reservations are all DISTINCT ──────────────────────────────────────
  outd="$tmp/l1"; mkdir -p "$outd"
  i=1
  while [ "$i" -le 8 ]; do ( printf '%s\n' "$(reserve_label "sidL1-$i")" > "$outd/$i" ) & i=$((i+1)); done
  wait
  uniqn="$(cat "$outd"/* | sort -u | grep -c .)"   # one label per line → true distinct count
  if [ "$uniqn" -eq 8 ]; then pass "L1: 8 concurrent reservations → 8 DISTINCT labels (atomic mkdir arbiter)"; else
    fail "L1: concurrent reservations collided ($uniqn/8 distinct) — assignment is not atomic"; fi

  # control: the OLD read-then-write picks the SAME label for two not-yet-written sessions (the race the fix closes)
  rm -rf "${LABELS_DIR:?}"/* "${AGENTS_DIR:?}"/*.json 2>/dev/null || true
  naive_pick() {  # a faithful copy of the REMOVED next_label — scans agent files, no atomic reservation
    local n=1 f lbl used=" "
    for f in "$AGENTS_DIR"/*.json; do [ -f "$f" ] || continue; lbl="$(json_field_file "$f" agent)"; case "$lbl" in agent-*) used="$used${lbl#agent-} " ;; esac; done
    while case "$used" in *" $n "*) true;; *) false;; esac; do n=$((n+1)); done
    printf 'agent-%s' "$n"
  }
  if [ "$(naive_pick)" = "$(naive_pick)" ]; then
    pass "L1 control: naive read-then-write hands two un-written sessions the SAME label (reservation is load-bearing)"
  else fail "L1 control: naive pick did not collide — the test is not exercising the TOCTOU race"; fi

  # ── L2: stable per session — resume/heartbeat/other-preferred returns the SAME label ─────────────
  rm -rf "${LABELS_DIR:?}"/* "${AGENTS_DIR:?}"/*.json 2>/dev/null || true
  mk_agent sidL2 placeholder
  a="$(reserve_label sidL2)"
  touch "$AGENTS_DIR/sidL2.json"                       # heartbeat
  b="$(reserve_label sidL2)"                           # resume, no hint
  c="$(reserve_label sidL2 agent-999)"                 # even with a different preferred, the existing reservation wins
  if [ "$a" = "$b" ] && [ "$b" = "$c" ]; then pass "L2: reservation is STABLE across resume/heartbeat/other-preferred ($a)"; else
    fail "L2: label changed for one session ($a → $b → $c) — not stable"; fi

  # ── L3: reuse — a non-live owner's slot is reclaimed; a live owner's is not stolen ───────────────
  rm -rf "${LABELS_DIR:?}"/* "${AGENTS_DIR:?}"/*.json 2>/dev/null || true
  mk_agent A x; la="$(reserve_label A)"   # A live → agent-1
  mk_agent B x; lb="$(reserve_label B)"   # B live → agent-2
  mk_agent A x old                        # A's agent file goes stale (not live)
  touch -d '1 hour ago' "$LABELS_DIR/$la" 2>/dev/null || touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || echo 200001010000)" "$LABELS_DIR/$la"  # A departed a while ago → its reservation aged past grace
  mk_agent C x; lc="$(reserve_label C)"   # C should reclaim A's freed agent-1
  if [ "$lc" = "$la" ] && [ "$lc" != "$lb" ]; then pass "L3: a NON-live owner's label ($la) is reclaimed for reuse by C, a live one ($lb) is not"; else
    fail "L3: reuse wrong (A=$la B=$lb C=$lc) — expected C to reclaim A's freed label and differ from B"; fi

  # ── L4: routing FAILS LOUD on a duplicate live label; a short/sid id still resolves ──────────────
  rm -rf "${LABELS_DIR:?}"/* "${AGENTS_DIR:?}"/*.json 2>/dev/null || true
  mk_agent dupA agent-1; mk_agent dupB agent-1        # simulate a pre-fix collision: two LIVE agent-1
  mk_agent uniq agent-2                               # a genuinely unique live label
  errf="$tmp/l4.err"; amb_rc=0
  bash "$DIR/fleet.sh" --id dupA msg agent-1 "ambiguity probe" >/dev/null 2>"$errf" || amb_rc=$?
  if [ "$amb_rc" -eq 3 ] && grep -q "ambiguous target 'agent-1'" "$errf" && grep -q "dupA" "$errf" && grep -q "dupB" "$errf"; then
    pass "L4: 'fleet.sh msg' to a label held by 2 LIVE windows FAILS LOUD (exit 3) and names both candidates"
  else fail "L4: duplicate live label did not fail loud (rc=$amb_rc) — routing would silently mis-deliver [$(tr '\n' '|' <"$errf")]"; fi

  # a sid/short id is ALWAYS unambiguous → delivered
  sid_rc=0; bash "$DIR/fleet.sh" --id dupA msg dupB "direct" >/dev/null 2>&1 || sid_rc=$?
  if [ "$sid_rc" -eq 0 ] && [ -f "$INBOX_DIR/dupB.jsonl" ] && grep -q "direct" "$INBOX_DIR/dupB.jsonl"; then
    pass "L4: a sid/short id resolves + delivers even amid a label collision"
  else fail "L4: sid/short routing broke amid a collision (rc=$sid_rc)"; fi

  # control: a UNIQUE live label resolves + delivers (fail-loud does not over-trigger)
  uniq_rc=0; bash "$DIR/fleet.sh" --id dupA msg agent-2 "unique" >/dev/null 2>&1 || uniq_rc=$?
  if [ "$uniq_rc" -eq 0 ] && [ -f "$INBOX_DIR/uniq.jsonl" ] && grep -q "unique" "$INBOX_DIR/uniq.jsonl"; then
    pass "L4 control: a UNIQUE live label still resolves + delivers (no over-trigger)"
  else fail "L4 control: a unique label was mis-flagged as ambiguous (rc=$uniq_rc)"; fi

  # ── L5: continuity bridge — an existing file-label with no reservation is PRESERVED ──────────────
  rm -rf "${LABELS_DIR:?}"/* "${AGENTS_DIR:?}"/*.json 2>/dev/null || true
  mk_agent mig agent-5                                # a resuming/upgraded session labeled agent-5, no reservation yet
  m="$(reserve_label mig agent-5)"
  [ "$m" = "agent-5" ] && pass "L5: an existing agent-5 label with no reservation is PRESERVED (not renumbered)" \
                       || fail "L5: preferred label not honored (got '$m', want agent-5)"
  # control: a preferred already held by a LIVE other session is NOT stolen
  mk_agent live5 agent-5; reserve_label live5 agent-5 >/dev/null   # live5 truly holds agent-5's reservation
  mk_agent thief x; t5="$(reserve_label thief agent-5)"
  [ "$t5" != "agent-5" ] && pass "L5 control: a preferred label held by a LIVE session is NOT stolen ($t5)" \
                         || fail "L5 control: reserve stole a live session's label — collision reintroduced"

  # ── L6: reap GC bounds LABELS_DIR — reaped owner's slot removed, kept (live) owner's retained ────
  rm -rf "${LABELS_DIR:?}"/* "${AGENTS_DIR:?}"/*.json 2>/dev/null || true
  mk_agent keep x; reserve_label keep >/dev/null      # live → keeps file + reservation
  mk_agent gone x; reserve_label gone >/dev/null; rm -f "$AGENTS_DIR/gone.json"   # owner file fully gone
  reap
  gone_present=0; keep_present=0
  for d in "$LABELS_DIR"/agent-*; do
    [ -d "$d" ] || continue
    o="$(cat "$d/sid" 2>/dev/null || true)"
    [ "$o" = gone ] && gone_present=1
    [ "$o" = keep ] && keep_present=1
  done
  [ "$gone_present" = 0 ] && pass "L6: reap GC-removes a reservation whose owner file is gone (LABELS_DIR bounded)" \
                          || fail "L6: a fully-reaped owner's reservation survived — LABELS_DIR grows unbounded"
  [ "$keep_present" = 1 ] && pass "L6 control: a LIVE owner keeps its reservation through reap (stable label preserved)" \
                          || fail "L6 control: reap dropped a live owner's reservation — label would churn"

  [ "$ok" = 1 ]
) || ok=0

[ "$ok" = 1 ] && { echo "selftest-labels: OK — atomic reservation BITES (unique-among-live, stable, fail-loud) + no false-positive"; exit 0; }
echo "selftest-labels: FAIL — the label-collision fix regressed"; exit 1
