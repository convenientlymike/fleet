#!/usr/bin/env bash
# selftest-attic.sh — the FORCING FUNCTION for the commit-attic work-loss hardening (operator-greenlit 2026-09-11).
#
# Proves each guarantee BITES, each with a control that fires (a control that never fires is not a control):
#   A1  attic_backup(HEAD) creates a GC-proof refs/attic/* ref AND a browsable patch — a commit is backed up.
#   A2  the reference-transaction guard ALLOWS a fast-forward (drops nothing).             control: a rewind is judged.
#   A3  the guard BLOCKS a branch REWIND that would drop an UN-atticed commit.             (the work-loss guard bites)
#   A4  the guard ALLOWS the same rewind once the dropped commits ARE atticed (recoverable) + FLEET_ATTIC_FORCE=1 escapes.
#   A5  after a REAL reset that drops an atticed commit, `attic recover` recreates it — nothing is lost.
#   A6  the guard IGNORES non-branch refs (incl. refs/attic/* — our own backups never recurse/self-block).
#   A7  `attic install` writes an executable post-commit + reference-transaction hook.
#
# Hermetic: a throwaway git repo + a temp STATE_DIR exercise the REAL attic.sh functions; the live fleet is untouched.
# Exit 0 = every guarantee bit + no false-positive; non-zero = the hardening regressed.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok=1
fail() { echo "  ✗ $1"; ok=0; }
pass() { echo "  ✓ $1"; }

echo "═══ selftest: commit-attic work-loss hardening ═══"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT
(
  # shellcheck source=lib.sh
  . "$DIR/lib.sh" 2>/dev/null
  # shellcheck source=attic.sh
  . "$DIR/attic.sh" 2>/dev/null
  export STATE_DIR="$tmp/state"; export FLEET_STATE_DIR="$STATE_DIR"   # attic patches land here
  export CLAUDE_CODE_SESSION_ID="selftestsid00001"                     # deterministic agent sub-key
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/gc" \
         GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  repo="$tmp/repo"; mkdir -p "$repo"; cd "$repo" || exit 1
  git init -q -b main .
  c() { echo "$1" > f.txt; git add -A; git commit -qm "$1"; git rev-parse HEAD; }
  s1="$(c one)"; s2="$(c two)"; s3="$(c three)"

  # ── A1: attic_backup creates a GC-proof ref + a patch ──────────────────────────────────────────
  attic_backup "$s3"
  ref="$(git for-each-ref --format='%(objectname)' refs/attic 2>/dev/null | head -1)"
  patch="$(find "$STATE_DIR/commit-attic" -name '*.patch' 2>/dev/null | head -1)"
  { [ "$ref" = "$s3" ] && [ -s "$patch" ]; } \
    && pass "A1: attic_backup made a refs/attic ref at the commit + a non-empty patch" \
    || fail "A1: no attic ref/patch for the commit (ref=$ref patch=$patch)"

  # ── A2: guard ALLOWS a fast-forward; control — a rewind is actually evaluated (not blanket-allowed) ──
  if printf '%s %s %s\n' "$s2" "$s3" "refs/heads/main" | attic_guard prepared; then
    pass "A2: guard ALLOWS a fast-forward (s2→s3 drops nothing)"
  else fail "A2: guard wrongly blocked a fast-forward"; fi

  # ── A3: guard BLOCKS a rewind dropping an UN-atticed TIP commit ────────────────────────────────
  # A fresh commit s4 (NOT atticed, and NOT an ancestor of the atticed s3) → dropping it is un-recoverable.
  # (Dropping s2 would be ALLOWED — s2 is an ancestor of the atticed s3, so it is reachable/recoverable.)
  s4="$(c four)"
  if printf '%s %s %s\n' "$s4" "$s3" "refs/heads/main" | attic_guard prepared; then
    fail "A3: guard ALLOWED a rewind dropping the un-atticed tip s4 — work-loss guard did NOT bite"
  else pass "A3: guard BLOCKS a rewind dropping an un-atticed (unrecoverable) tip commit"; fi

  # ── A4: once the dropped commit IS atticed, the same rewind is ALLOWED (recoverable) ───────────
  attic_backup "$s4"   # now s4 is atticed → recoverable
  if printf '%s %s %s\n' "$s4" "$s3" "refs/heads/main" | attic_guard prepared; then
    pass "A4: guard ALLOWS the rewind once the dropped commit is atticed (recoverable)"
  else fail "A4: guard still blocked a rewind whose dropped commit is atticed"; fi
  # A4 escape hatch: an UN-atticed drop is normally blocked, but FLEET_ATTIC_FORCE=1 bypasses it.
  s5="$(c five)"   # a fresh un-atticed tip
  if printf '%s %s %s\n' "$s5" "$s3" "refs/heads/main" | attic_guard prepared; then
    fail "A4 escape setup: the un-atticed s5 drop should be BLOCKED without FORCE"
  elif printf '%s %s %s\n' "$s5" "$s3" "refs/heads/main" | FLEET_ATTIC_FORCE=1 attic_guard prepared; then
    pass "A4 escape: FLEET_ATTIC_FORCE=1 bypasses the guard (un-atticed drop allowed)"
  else
    fail "A4 escape: FLEET_ATTIC_FORCE=1 did NOT bypass the guard"
  fi

  # ── A5: a REAL reset that drops an atticed commit → `attic recover` recreates it ───────────────
  git reset --hard "$s1" >/dev/null 2>&1   # drops s2,s3 from main (both atticed)
  ! git merge-base --is-ancestor "$s3" HEAD 2>/dev/null \
    && pass "A5: s3 is dropped from HEAD after the reset" || fail "A5: reset did not drop s3"
  _attic_recover "$s3" >/dev/null 2>&1
  rec="$(git rev-parse --verify "attic-recover-$(printf '%s' "$s3" | cut -c1-8)" 2>/dev/null)"
  [ "$rec" = "$s3" ] && pass "A5: attic recover recreated a branch at the dropped commit (nothing lost)" \
                     || fail "A5: attic recover did not recover s3 (got $rec)"

  # ── A6: guard IGNORES a non-branch ref (refs/attic/* — our own writes never self-block) ────────
  if printf '%s %s %s\n' "$s3" "$s1" "refs/attic/x/y" | attic_guard prepared; then
    pass "A6: guard ignores a non-branch ref (refs/attic/* — no self-block/recursion)"
  else fail "A6: guard wrongly evaluated a non-branch (refs/attic) ref"; fi

  # ── A7: install writes executable hooks ────────────────────────────────────────────────────────
  _attic_install >/dev/null 2>&1
  hd="$(git rev-parse --git-path hooks)"
  { [ -x "$hd/post-commit" ] && [ -x "$hd/reference-transaction" ] \
    && grep -q 'fleet.sh attic' "$hd/post-commit" && grep -q 'fleet.sh attic' "$hd/reference-transaction"; } \
    && pass "A7: install wrote executable post-commit + reference-transaction hooks" \
    || fail "A7: install did not write both executable hooks"

  [ "$ok" = 1 ]
) || ok=0

[ "$ok" = 1 ] && { echo "selftest-attic: OK — every commit is backed up + a rewind can't silently drop work + it's recoverable"; exit 0; }
echo "selftest-attic: FAIL — the work-loss hardening regressed"; exit 1
