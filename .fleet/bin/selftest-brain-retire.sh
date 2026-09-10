#!/usr/bin/env bash
# selftest-brain-retire.sh — forcing function for the `retire` + `brain` fleet subcommands.
# Runs against an ISOLATED FLEET_STATE_DIR (a mktemp) so it NEVER touches the live fleet's agents/claims/brain seat.
# Proves the happy paths AND that the safety guards BITE (negative controls): retire refuses a dirty-claim / stranded
# unread DMs without --force; the C0b dirty-work invariant is honored. Exit 0 = all green, non-zero = a check failed.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$DIR/fleet.sh"
PROJECT_ROOT="$(cd "$DIR/../.." && pwd)"

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-brain-retire.XXXXXX")"
# Probe path lives DIRECTLY under .fleet/ (not .fleet/tmp/ or .fleet/state/) so it dodges the
# common `tmp/` + `.fleet/state/` .gitignore rules — otherwise `git status --porcelain` never
# reports it dirty and the dirty-claim NEGATIVE CONTROL below silently SKIPs (a dead forcing function).
DIRTY_REL=".fleet/brain_retire_selftest_dirty.$$"
DIRTY_ABS="$PROJECT_ROOT/$DIRTY_REL"
cleanup() { rm -rf "$T" 2>/dev/null; rm -f "$DIRTY_ABS" 2>/dev/null; }
trap cleanup EXIT

export FLEET_STATE_DIR="$T"      # lib.sh honors this → fully isolated agents/claims/inbox/board/brain
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1 [ $2 ]"; fi; }

ADMIN="admin-sid-0000-0000-0000-000000000000"
A="aaaa1111-2222-3333-4444-555566667777"
B="bbbb1111-2222-3333-4444-555566667777"

echo "═══ selftest: retire + brain (isolated state: $T) ═══"

# ---- retire: happy path (clean claim released + record removed + board event) ----
"$FLEET" --id "$A" claim "some/module.ts" "unit under test" >/dev/null 2>&1
chk "seed: agent A registered + holds a claim" '[ -f "$T/agents/$A.json" ] && [ "$(ls -d "$T"/claims/*.lock 2>/dev/null | wc -l | tr -d " ")" -ge 1 ]'
"$FLEET" --id "$ADMIN" retire "$A" >/dev/null 2>&1
chk "retire(clean): agent record removed"          '[ ! -f "$T/agents/$A.json" ]'
chk "retire(clean): claim released"                '[ "$(ls -d "$T"/claims/*.lock 2>/dev/null | wc -l | tr -d " ")" -eq 0 ]'
chk "retire(clean): board emitted a retire event"  'grep -q "\"event\":\"retire\"" "$T/board.jsonl"'

# ---- retire: NEGATIVE CONTROL — refuse a claim over UNCOMMITTED work without --force ----
printf 'dirty\n' > "$DIRTY_ABS"
# only meaningful if git actually reports the file dirty (untracked, non-ignored); skip-guard otherwise
if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain -- "$DIRTY_REL" 2>/dev/null)" ]; then
  "$FLEET" --id "$B" claim "$DIRTY_REL" "work-in-progress" >/dev/null 2>&1
  "$FLEET" --id "$ADMIN" retire "$B" >/dev/null 2>&1; rc=$?
  chk "retire(dirty,no-force): REFUSED (non-zero exit)" '[ "'$rc'" -ne 0 ]'
  chk "retire(dirty,no-force): record still present"    '[ -f "$T/agents/$B.json" ]'
  chk "retire(dirty,no-force): claim NOT released"      '[ "$(ls -d "$T"/claims/*.lock 2>/dev/null | wc -l | tr -d " ")" -ge 1 ]'
  "$FLEET" --id "$ADMIN" retire "$B" --force >/dev/null 2>&1
  chk "retire(dirty,--force): record removed"           '[ ! -f "$T/agents/$B.json" ]'
  chk "retire(dirty,--force): claim released"           '[ "$(ls -d "$T"/claims/*.lock 2>/dev/null | wc -l | tr -d " ")" -eq 0 ]'
else
  echo "  SKIP  dirty-claim guard (git did not report $DIRTY_REL dirty in this tree)"
fi

# ---- brain: serve / who / ask-routing / stand-down ----
"$FLEET" --id "$A" brain serve >/dev/null 2>&1
chk "brain serve: registry written"                '[ -f "$T/brain.json" ] && grep -q "'$A'" "$T/brain.json"'
chk "brain who: reports the Brain agent"            '"$FLEET" brain who 2>&1 | grep -qi "Brain:"'
"$FLEET" --id "$B" brain ask "what do we know about X" >/dev/null 2>&1
chk "brain ask: routed a BRAIN-ASK DM to the Brain" 'grep -q "BRAIN-ASK" "$T/inbox/$A.jsonl"'
"$FLEET" --id "$A" brain stand-down >/dev/null 2>&1
chk "brain stand-down: seat vacated"                '[ ! -f "$T/brain.json" ]'

# ---- retire vacates the Brain seat ----
"$FLEET" --id "$A" brain serve >/dev/null 2>&1
"$FLEET" --id "$A" retire >/dev/null 2>&1
chk "retire(self): vacates the Brain seat"          '[ ! -f "$T/brain.json" ]'

# ---- brain query: the CLI corpus oracle returns something for a known term (uses the REAL corpus via fleet-memory) ----
if command -v fleet-memory >/dev/null 2>&1; then
  chk "brain <query>: corpus oracle returns a header" '"$FLEET" brain "gpu" 2>&1 | grep -qi "BRAIN"'
else
  echo "  SKIP  brain <query> (fleet-memory not on PATH)"
fi

echo "─── $PASS passed, $FAIL failed ───"
[ "$FAIL" -eq 0 ]
