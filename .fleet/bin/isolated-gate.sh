#!/usr/bin/env bash
# isolated-gate.sh — run a whole-tree gate/command in ISOLATION from a sibling window's uncommitted work.
#
# THE PROBLEM (fleet shared-tree hazard): many Claude windows share ONE working tree. A whole-tree gate — a git
# pre-push hook that lints/tests the repo, a coverage/coherence check — reads the FILESYSTEM, which is EVERY live
# window's uncommitted work at once. So Window B's mid-build files (an untested new component, a half-edited config)
# make the gate FAIL and BLOCK Window A's push, even though Window A's COMMIT is perfectly green. A push must be
# validated by the COMMIT it pushes, NOT by the shared dirty tree.
#
# THE FIX: when the working tree is DIRTY, run the command against an EPHEMERAL git worktree checked out at the
# pushed commit (default HEAD), with the project's heavy dependency dirs symlinked in so the gate can actually run.
# A sibling window's uncommitted work is thereby bypassed — it lives only in the primary tree, never in the fresh
# worktree. When the tree is CLEAN, run in place (fast path — the working tree already equals HEAD). This NEVER
# touches the primary tree or the sibling's work (no stash, no reset), so it is safe under any parallelism.
#
# Usage:   isolated-gate.sh [--deps "d1 d2 …"] [--ref <rev>] -- <command> [args…]
#   --deps   space-separated in-repo dependency dirs to symlink into the worktree (node_modules, venvs, …).
#            Default covers the common JS/Py layout. Absolute-path deps (e.g. ~/.cache venvs) need no symlink.
#   --ref    the commit to validate (default HEAD — the tip being pushed).
# Exit code = the command's exit code (or the command's, run in place, if isolation can't be set up).
#
# Wire it into a project's pre-push hook:   exec .fleet/bin/isolated-gate.sh -- bash scripts/lint/run_gates.sh
set -u

DEPS="node_modules ui/frontend/node_modules ui/server/.venv .venv frontend/node_modules server/node_modules"
REF="HEAD"
while [ $# -gt 0 ]; do
  case "$1" in
    --deps) DEPS="${2:-}"; shift 2 ;;
    --ref)  REF="${2:-HEAD}"; shift 2 ;;
    --)     shift; break ;;
    *)      break ;;
  esac
done
[ "$#" -eq 0 ] && { echo "isolated-gate: no command given (usage: isolated-gate.sh [--deps …] [--ref …] -- <cmd>)" >&2; exit 2; }

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || exec "$@"    # not a git repo → just run the command

# ── FAST PATH: a clean working tree already equals HEAD, so an in-place run validates exactly what's pushed. ──
if [ -z "$(git -C "$REPO" status --porcelain 2>/dev/null | head -1)" ]; then
  exec "$@"
fi

# ── ISOLATION PATH: the shared tree is DIRTY (a parallel window has uncommitted work). Validate the pushed commit
#    in a clean ephemeral worktree so a sibling's uncommitted work can't false-red this push. ──
SHA="$(git -C "$REPO" rev-parse "$REF" 2>/dev/null)"
WT_PARENT="$(mktemp -d 2>/dev/null || true)"
WT="${WT_PARENT}/fleet-iso-wt"
echo "isolated-gate: shared tree is DIRTY — validating the pushed commit ${SHA:0:12} in an isolated worktree" >&2
echo "isolated-gate: (a parallel window's uncommitted work is bypassed; the primary tree is never touched)…" >&2

if [ -n "$WT_PARENT" ] && git -C "$REPO" worktree add --detach -q "$WT" "$SHA" 2>/dev/null; then
  for d in $DEPS; do
    [ -e "$REPO/$d" ] && [ ! -e "$WT/$d" ] && ln -s "$REPO/$d" "$WT/$d" 2>/dev/null
  done
  ( cd "$WT" && "$@" ); RC=$?
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null
  rm -rf "$WT_PARENT" 2>/dev/null
  if [ "$RC" -ne 0 ]; then
    echo "isolated-gate: FAILED on the isolated commit ${SHA:0:12} — this is a REAL failure in YOUR commit, not a" >&2
    echo "isolated-gate: sibling's uncommitted artifact. Fix the commit (or --no-verify if you've verified it)." >&2
  fi
  exit "$RC"
fi

# ── FALLBACK: couldn't build the worktree — run in place but WARN. Never silently skip the gate. ──
rm -rf "$WT_PARENT" 2>/dev/null
echo "isolated-gate: WARN — couldn't create the isolation worktree; running in place on the DIRTY tree. A parallel" >&2
echo "isolated-gate: window's uncommitted work MAY cause a false red; if so, have it commit, or use a git worktree." >&2
exec "$@"
