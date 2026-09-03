#!/usr/bin/env bash
# multiwindow_nudge.sh — Fleet SessionStart nudge (fires once per session). When >1 live window SHARES the PRIMARY
# working tree (not a linked worktree), a broad `git add -A` / `git commit -a` in one window can sweep another
# window's uncommitted work into its commit (the 2026-09-02 collateral incident). This steers new windows to the
# STRUCTURAL fix — worktree-per-window (own working dir + own index → collateral impossible by construction).
# Quiet unless the risk is live. Read-only + fail-open. Pairs with the C0/C1 guards that protect the shared tree.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh" 2>/dev/null || exit 0
trap 'exit 0' ERR

n="$(count_live 2>/dev/null || echo 0)"
[ "${n:-0}" -gt 1 ] || exit 0   # 0-1 live windows → no shared-tree collision risk → quiet

# Already isolated in a linked worktree? (git-dir != git-common-dir). If so, this window is safe → quiet.
gd="$(git -C "$PROJECT_ROOT" rev-parse --git-dir 2>/dev/null)"
gcd="$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null)"
[ -n "$gd" ] && [ "$gd" != "$gcd" ] && exit 0

echo "⚠ Fleet: $n live windows SHARE this primary tree — a broad 'git commit -a' can sweep another window's uncommitted work into your commit."
echo "  ISOLATE this window (own working dir + branch → zero collateral by construction):"
echo "    .fleet/bin/fleet.sh worktree enable   &&   .fleet/bin/fleet.sh worktree new <label>   # then open that dir in a new window"
echo "  Until then, the shared-tree guards protect you IF you: claim before editing · commit narrowly ('git commit <your-paths>', never -a) · don't release a claim on uncommitted work."
exit 0
