#!/usr/bin/env bash
# commit-guard.sh — Fleet git PRE-COMMIT guard: BLOCK a commit that would include a file CLAIMED BY ANOTHER LIVE
# agent. This closes the layer guard.sh (the PreToolUse edit-guard) cannot see:
#
#   Multiple Claude sessions SHARE one working tree + git index. A broad `git add -A` / `git commit -a` stages every
#   modified/uncommitted file — including a SIBLING session's staged-but-uncommitted work — and commits it under the
#   committer's message (and has, historically, pushed another session's UNREVIEWED work PUBLIC). guard.sh blocks
#   EDITING a foreign claim, but a `commit -a` AUTO-STAGES before the git pre-commit runs, so the edit-guard never
#   fires. This guard runs at commit time and refuses when the staged set contains a file a LIVE FOREIGN agent claims.
#
# It is the commit-boundary twin of the fleet claim: claim before editing (guard.sh) + never commit another live
# agent's claim (this). Reuses lib.sh (covering_lock / is_live). Fail-OPEN on any error (a guard bug must NEVER wedge
# commits). Respects block_mode (block=default | warn). --selftest proves it BITES (a foreign live claim → block) and
# does NOT over-block (own claim / unclaimed / dead owner → allow).
#
# Remedy when it blocks: commit ONLY your own paths — `git commit <your-file> ...` (explicit paths bypass the shared
# index, so a sibling's staged files can't ride along), or release a stale claim (.fleet/bin/fleet.sh roster).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
trap 'exit 0' ERR   # fail OPEN — never block all commits on an internal error

_self_sid() {
  [ -n "${FLEET_ID:-}" ] && { printf '%s' "$FLEET_ID"; return; }
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && { printf '%s' "$CLAUDE_CODE_SESSION_ID"; return; }
  [ -n "${FLEET_SESSION:-}" ] && { printf '%s' "$FLEET_SESSION"; return; }
  printf ''
}

# The files this commit would CREATE. `--cached` is correct even for `git commit -a` (it auto-stages BEFORE the
# pre-commit hook runs) and for `git commit <paths>` (git builds a temp index the hook sees via --cached).
_staged_files() { git diff --cached --name-only --diff-filter=ACMR 2>/dev/null; }

# _covering_claim_dirty <claimed-path> — 0 if the claim's path has UNCOMMITTED changes (a sibling's live CONTENT).
# THE C1 CONTENT-PROVENANCE SIGNAL (2026-09-02): liveness is the WRONG question during work (a working window reads
# stale in a >3min turn). The right question is "is this file's content someone else's uncommitted work" — which is
# liveness-free. Mockable (like covering_lock/is_live) so the selftest stays hermetic. Prefix-safe.
_covering_claim_dirty() {
  local p="$1"
  [ -z "$p" ] && return 1
  command -v git >/dev/null 2>&1 || return 1
  [ -n "$(git -C "${PROJECT_ROOT:-.}" status --porcelain -- "$p" 2>/dev/null)" ] && return 0
  return 1
}

# check_commit <me_sid> <files-or-empty> — returns 1 (+ prints the offenders to stderr) if any file is covered by a
# LIVE FOREIGN claim; 0 otherwise. files empty => read the real staged set (the selftest injects a synthetic list).
check_commit() {
  local me="$1" files="$2" f hit owner rest cpath oagent ointent foreign=""
  [ -z "$files" ] && files="$(_staged_files)"
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    hit="$(covering_lock "$f" 2>/dev/null || true)"
    [ -z "$hit" ] && continue
    owner="${hit%%|*}"; rest="${hit#*|}"; cpath="${rest%%|*}"; rest="${rest#*|}"; oagent="${rest%%|*}"; ointent="${rest#*|}"
    [ "$owner" = "$me" ] && continue           # my own claim — fine
    [ "$owner" = "INPROGRESS" ] && continue    # a claim mid-write — not a foreign commit target
    # C1 (2026-09-02): a foreign claim blocks if the owner is LIVE (proven-good), OR — regardless of liveness — the
    # claimed path is DIRTY (a sibling's uncommitted CONTENT). A working window reads STALE during a long turn, so a
    # liveness-only gate is blind exactly when it matters. A stale owner over a CLEAN path has nothing to sweep → skip.
    if ! is_live "$owner"; then
      _covering_claim_dirty "$cpath" || continue
    fi
    foreign="${foreign}"$'\n'"  ${f}  ← claimed by ${oagent:-agent ${owner:0:8}} (covering ${cpath}${ointent:+ — ${ointent}})"
  done <<EOF
$files
EOF
  [ -z "$foreign" ] && return 0
  {
    echo "── FLEET COMMIT GUARD — BLOCKED ──"
    echo "This commit includes file(s) CLAIMED BY ANOTHER LIVE agent. A broad add / commit-a sweeps a sibling"
    echo "session's staged, UNREVIEWED work into your commit (it has pushed another session's work PUBLIC before)."
    echo "Commit ONLY your own paths (explicit paths bypass the shared index):"
    echo "    git commit <your-file> [<your-file> ...]"
    echo "Foreign-claimed file(s) in this commit:${foreign}"
    echo "(if a claim is stale: .fleet/bin/fleet.sh roster  →  ask them to release, or --force)"
  } >&2
  return 1
}

# ── negative control: mock the two lib primitives so the DECISION LOGIC is proven hermetically (no real fleet state).
_selftest() {
  local ok=1
  # (1) a FOREIGN + LIVE claim on a staged file MUST bite
  covering_lock() { printf 'FOREIGNSID|path/x.py|agent-7|doing x\n'; }
  is_live() { return 0; }
  if check_commit "MYSID" "path/x.py" >/dev/null 2>&1; then echo "SELFTEST FAIL: a foreign LIVE claim did NOT block"; ok=0; fi
  # (2) MY OWN claim on the same file MUST pass
  covering_lock() { printf 'MYSID|path/x.py|me|doing x\n'; }
  if ! check_commit "MYSID" "path/x.py" >/dev/null 2>&1; then echo "SELFTEST FAIL: my own claim was WRONGLY blocked"; ok=0; fi
  # (3) a foreign claim by a DEAD owner over a CLEAN path MUST pass (stale lock, nothing dirty to sweep)
  covering_lock() { printf 'DEADSID|path/x.py|agent-9|gone\n'; }
  is_live() { return 1; }
  _covering_claim_dirty() { return 1; }   # clean
  if ! check_commit "MYSID" "path/x.py" >/dev/null 2>&1; then echo "SELFTEST FAIL: a DEAD owner's stale+CLEAN claim over-blocked"; ok=0; fi
  # (4) an UNCLAIMED file MUST pass
  covering_lock() { printf ''; }
  is_live() { return 0; }
  if ! check_commit "MYSID" "path/unclaimed.py" >/dev/null 2>&1; then echo "SELFTEST FAIL: an unclaimed file was blocked"; ok=0; fi
  # (5) C1 — a foreign claim by a STALE owner over a DIRTY path MUST BLOCK (the collateral incident's shape; the
  #     working owner read stale during a long turn, its dirty-covering claim survived C0b — this is what bites).
  covering_lock() { printf 'STALESID|path/x.py|agent-7|mid-long-turn\n'; }
  is_live() { return 1; }                 # owner reads stale
  _covering_claim_dirty() { return 0; }   # but the path is DIRTY = a sibling's uncommitted content
  if check_commit "MYSID" "path/x.py" >/dev/null 2>&1; then echo "SELFTEST FAIL(C1): a STALE-owner DIRTY-path foreign claim did NOT block — the collateral gap is OPEN"; ok=0; fi
  # (6) C1 control — same STALE owner but CLEAN path MUST pass (no over-block / no wedge)
  _covering_claim_dirty() { return 1; }   # clean
  if ! check_commit "MYSID" "path/x.py" >/dev/null 2>&1; then echo "SELFTEST FAIL(C1): a STALE-owner CLEAN-path claim over-blocked (would wedge)"; ok=0; fi
  [ "$ok" = 1 ] && { echo "commit-guard: self-test OK (foreign-live + foreign-stale-DIRTY BITE; own/dead-clean/unclaimed/stale-clean all pass)"; return 0; }
  return 1
}

[ "${1:-}" = "--selftest" ] && { _selftest; exit $?; }

me="$(_self_sid)"
[ -z "$me" ] && exit 0   # can't identify the committer (e.g. a manual terminal outside a Claude session) → fail OPEN
if check_commit "$me" ""; then exit 0; fi
[ "$(block_mode)" = "warn" ] && exit 0
exit 1
