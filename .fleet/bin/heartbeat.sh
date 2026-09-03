#!/usr/bin/env bash
# heartbeat.sh — Fleet PostToolUse heartbeat (matcher: * — every tool use refreshes liveness).
#
# THE ROOT-CAUSE FIX (2026-09-02 collateral incident). The liveness heartbeat
# (is_live = agent-file mtime within stale_after_s=180) was refreshed ONLY on
# UserPromptSubmit (awareness.sh). So during any autonomous turn > 3 min, the
# ACTIVELY-WORKING window reads STALE — and a sibling's reap() then garbage-
# collects its claims + agent file, leaving its dirty files ownerless. The
# sibling's `git add -A` / `commit -a` then sweeps that ownerless work into its
# own commit (it has pushed another window's work under the wrong message).
#
# This beats the heartbeat on every tool use (matcher broadened to * so a
# read/think/Task-heavy turn — not just Edit|Write|Bash — keeps liveness fresh),
# so a working window never reads dead mid-turn. It touches an EXISTING agent
# file OR RE-CREATES one that reap() already deleted (the C0a tail-fix: a tool
# just ran ⇒ the window is provably alive, so it must never stay invisible until
# its next prompt). Never blocks a tool. Fail-open + parallel-safe. Pairs with
# C0b (reap won't drop a dirty-path claim) + C1 (commit-guard blocks a foreign
# DIRTY-path claim regardless of liveness). See .fleet/README.md.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh" 2>/dev/null || exit 0
trap 'exit 0' ERR   # never let a heartbeat error surface after a tool ran

INPUT="$(cat 2>/dev/null || true)"
SID="$(json_field_str "$INPUT" session_id 2>/dev/null)"
[ -z "$SID" ] && SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$SID" ] && exit 0

# A tool just ran in this session ⇒ the window is ALIVE. ensure_self_registered (lib.sh) touches an existing
# agent file, or RE-CREATES one reap() already deleted (the session crossed stale_after_s between heartbeat
# events — a read/think-heavy or long-single-tool turn). The C0a tail-fix so an actively-working window can no
# longer stay invisible until its next prompt. Fail-open — never blocks the tool.
ensure_self_registered "$SID"
exit 0
