



<!-- FLEET:BEGIN (managed by .fleet — do not edit between markers) -->
## Fleet protocol (multi-window coordination)

Multiple Claude Code windows may be open on this project at once. Each is a
registered agent. To work in parallel without clobbering each other:

- **Check the roster** before starting: `.fleet/bin/fleet.sh roster`
- **Claim your area** before editing shared code:
  `.fleet/bin/fleet.sh claim <path> "<what you're doing>"`
- Editing a file another **live** agent has claimed is **BLOCKED** by the harness.
  If blocked, pick another area or message them: `.fleet/bin/fleet.sh msg <agent> "..."`
- **Release** when done: `.fleet/bin/fleet.sh release <path>`
- Read messages: `.fleet/bin/fleet.sh inbox`

### Wake + messages — do this, it's the one part that isn't automatic

- **First thing each session: ARM your inbox watcher.** Run `.fleet/bin/fleet.sh wake-cmd` and hand its
  printed command to the **Monitor tool** (`persistent: true`, `timeout_ms: 3600000`). This is the ONE
  coordination step a hook physically cannot do for you (a hook can't call the Monitor tool), so it's on
  you — do it before other work. If you skip it, a re-nudge (`⚠ FLEET WAKE NOT ARMED`) fires every turn
  until you do. Once armed, a `msg` to you re-invokes your window to act on it.
- **A FLEET DM is a TASK, not an FYI — ACT on it.** Delivery is guaranteed: whether or not your watcher is
  armed, any unread DM is injected into your context before your next step (arming only changes *latency* —
  it wakes an idle window sooner). So when you see a `[fleet]`/`New messages` block or a `FLEET-PING`: read
  it, DO what it asks (e.g. a coordinator's "rebase", "land-blocked: fix X", or a peer's claim handoff),
  then reply with `.fleet/bin/fleet.sh msg <agent> "<result>"`. Never merely acknowledge and move on — an
  unactioned DM stalls another agent that's waiting on you.
- **See who's reachable:** `.fleet/bin/fleet.sh monitors` classifies every agent MONITORED / UNMONITORED
  (live but won't proactively wake) / CLOSED — use it before you rely on a DM waking someone.

Your identity is auto-detected — just run the commands.
<!-- FLEET:END -->
