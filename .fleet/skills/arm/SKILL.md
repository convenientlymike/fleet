---
name: arm
description: >-
  Arm (or re-arm) the fleet coordination MONITOR for this session — a persistent
  background watcher that wakes you on inbox DMs (LAND-READY signals), new-agent
  registrations, and network (github egress) recovery. Invoke with /arm after a
  VS Code / session restart (the Monitor tool dies on restart and must be re-armed),
  or any time the coordinator's wake-on-events watcher isn't running. This is the
  standalone re-arm; /coordinator runs it as part of full onboarding.
---

# Arm the fleet monitor

Arms ONE persistent background monitor that turns three fleet events into wake-ups so
you don't have to poll:

1. **Inbox DMs** — every new line in your session inbox (e.g. `LAND-READY <sha>` from a
   lane) fires a `FLEET-PING`.
2. **New-agent registrations** — a new agent joining the fleet fires `FLEET-PING
   NEW-AGENT <id>` (identify it with `fleet-agent-map`, greet, track).
3. **Network recovery** — when github egress returns after a drop, fires
   `FLEET-PING NETWORK-RECOVERED` (re-verify origin, drain any held pushes).

## Do this on /arm

**Step 1 — get your session's CANONICAL paths from the resolver** (never hand-transcribe them):

```bash
.fleet/bin/fleet.sh whoami        # your session id + role
.fleet/bin/fleet.sh wake-cmd      # prints the EXACT inbox=/mon= paths for the Monitor tool
```

⚠ **Do NOT assume `.git/fleet/...`.** The real state dir depends on config
`state_location`: with `git-common` (worktree-shared) it is
`$(git rev-parse --git-common-dir)/fleet` — which in a *linked worktree* is the MAIN
repo's `.git/fleet`, **not** this worktree's `.git`, and **not** the local
`.fleet/state`. `wake-cmd` resolves this correctly for you — copy its `inbox=` / `mon=`
lines verbatim into Step 2. Arming from hand-typed paths silently orphans your watcher
(it runs, but writes its breadcrumb where the fleet never looks → you read UNMONITORED
and DMs never wake you). Step 3 catches this.

**Step 2 — arm the persistent Monitor** (harness Monitor tool, `persistent: true`,
`timeout_ms: 3600000`). Paste the `inbox=` / `mon=` lines from `wake-cmd`; the agents
dir is derived from `mon`, so you never retype a path:

```bash
# Paste the two lines that `fleet.sh wake-cmd` printed (authoritative paths):
inbox="…/fleet/inbox/<session-id>.jsonl"
mon="…/fleet/wake/<session-id>.monitor"
agents="$(dirname "$(dirname "$mon")")/agents"      # -> <state-dir>/agents
mkdir -p "$(dirname "$mon")" 2>/dev/null
prev=0; [ -f "$inbox" ] && prev=$(wc -l < "$inbox" | tr -d ' '); prev=${prev:-0}
snap=$(ls "$agents"/*.json 2>/dev/null | sort); netdown=0    # seed 0 = no spurious first-tick ping
while true; do
  : > "$mon" 2>/dev/null
  cur=0; [ -f "$inbox" ] && cur=$(wc -l < "$inbox" | tr -d ' '); cur=${cur:-0}
  if [ "$cur" -gt "$prev" ]; then tail -n +$((prev+1)) "$inbox" | sed 's/^/FLEET-PING /'; prev=$cur; fi
  cursnap=$(ls "$agents"/*.json 2>/dev/null | sort)
  newf=$(comm -13 <(printf '%s\n' "$snap") <(printf '%s\n' "$cursnap"))
  if [ -n "$newf" ]; then for f in $newf; do [ -n "$f" ] && echo "FLEET-PING NEW-AGENT registered: $(basename "$f" .json) — run fleet-agent-map to identify + greet/track"; done; snap="$cursnap"; fi
  if nc -z -w3 github.com 22 >/dev/null 2>&1; then [ "$netdown" = 1 ] && echo "FLEET-PING NETWORK-RECOVERED — egress back; re-verify origin==local + drain the held push queue"; netdown=0; else netdown=1; fi
  sleep 15
done
```

Pass this as the Monitor tool's `command` with a clear `description`
(e.g. "Fleet agent-N — inbox DMs + NEW-AGENT + NETWORK-recovery"),
`persistent: true`, `timeout_ms: 3600000`.

**Step 3 — confirm + VERIFY (byproduct, not assumption).** State the monitor task id
(so it can be stopped/re-armed later), then run the forcing-function check:

```bash
.fleet/bin/fleet.sh monitors      # find YOUR short id in the STATE column
```

- **MONITORED** → you are wake-capable. (Strongest proof: the next real DM fires a
  `FLEET-PING` through your monitor.)
- **UNMONITORED while your Monitor is alive** → your watcher is on the WRONG path
  (classic: local `.fleet/state` while the fleet runs `git-common`). Its breadcrumb
  lands where the fleet never looks, so DMs will NOT wake you. **Stop it (TaskStop) and
  re-arm from `wake-cmd` output.** Do not declare armed until `monitors` shows MONITORED.

If you're the coordinator, note you're in armed standby.

## Notes

- **Re-arm after every restart.** The Monitor process does not survive a VS Code /
  session restart — `/arm` is the one-command recovery.
- **One monitor per session.** If re-arming, stop the stale one first (TaskStop) so you
  don't get duplicate pings.
- **git-common gotcha — verify, don't assume (learned the hard way).** If the fleet uses
  `state_location=git-common`, the real wake/inbox dirs are under
  `$(git rev-parse --git-common-dir)/fleet`, NOT the local `.fleet/state` and NOT this
  worktree's `.git/fleet`. A watcher armed from stale/hand-typed paths is alive but
  orphaned (reads UNMONITORED; DMs deliver on your next turn but never proactively wake
  you). Always arm from `wake-cmd` (Step 1) and confirm with `monitors` (Step 3).
- The inbox is a **filesystem file** (not a network resource), so DM wake-ups keep
  working even when github egress is down — only the `NETWORK-RECOVERED` probe depends on
  the network (by design).
- A worker (non-coordinator) agent can also `/arm` to get woken on DMs; the new-agent +
  network signals are harmless extras.
