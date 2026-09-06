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

**Step 1 — resolve this session's fleet paths** (identity is auto-detected):

```bash
.fleet/bin/fleet.sh whoami        # confirms your session id + role
# inbox  = .git/fleet/inbox/<session-id>.jsonl
# agents = .git/fleet/agents
# wake   = .git/fleet/wake/<session-id>.monitor
ls .git/fleet/inbox/*.jsonl        # find your inbox if whoami doesn't print the path
```

**Step 2 — arm the persistent Monitor** (harness Monitor tool, `persistent: true`,
`timeout_ms: 3600000`). Substitute your resolved `<session-id>`:

```bash
inbox=".git/fleet/inbox/<session-id>.jsonl"
mon=".git/fleet/wake/<session-id>.monitor"
agents=".git/fleet/agents"
mkdir -p "$(dirname "$mon")" 2>/dev/null
prev=0; [ -f "$inbox" ] && prev=$(wc -l < "$inbox" | tr -d ' '); prev=${prev:-0}
snap=$(ls "$agents"/*.json 2>/dev/null | sort); netdown=1
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
(e.g. "Fleet coordinator — inbox DMs + NEW-AGENT + NETWORK-recovery"),
`persistent: true`, `timeout_ms: 3600000`.

**Step 3 — confirm + announce.** State the monitor task id (so it can be stopped/
re-armed later) and, if you're the coordinator, note you're in armed standby.

## Notes

- **Re-arm after every restart.** The Monitor process does not survive a VS Code /
  session restart — `/arm` is the one-command recovery.
- **One monitor per session.** If re-arming, stop the stale one first (TaskStop) so you
  don't get duplicate pings.
- The inbox is a **local file**, so DM wake-ups keep working even when github egress is
  down — only the `NETWORK-RECOVERED` probe depends on the network (by design).
- A worker (non-coordinator) agent can also `/arm` to get woken on DMs; the new-agent +
  network signals are harmless extras.
