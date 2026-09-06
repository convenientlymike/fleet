# Changelog

All notable changes to Fleet are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Coordinator & arm agent skills (`/coordinator`, `/arm`).** Fleet now ships two Claude
  Code skills under `.fleet/skills/`, and `install.sh` installs them into the target
  project's `.claude/skills/` (Fleet owns those two skill dirs; other skills untouched).
  - **`/coordinator`** onboards a window as the dedicated git push/merge/integration
    coordinator: fast repo + worktree + fleet-agent orientation, arms the monitor, then
    the land loop — merge the frozen branch tip (`--no-ff`), run the pre-push gate,
    verify the push landed with an authoritative `ls-remote` (never trust exit-0),
    de-drift every worktree, DM the lane. Encodes the hard rules (never bypass the gate,
    stage narrowly, freeze the SHA, never rebase `fleet/*`) + block diagnosis (real vs.
    ephemeral-worktree false-fail, `SIGPIPE`-on-flaky-network, commit-guard).
  - **`/arm`** — standalone (re-)arm of the wake-on-message monitor (inbox DMs +
    new-agent + network recovery); the one-command recovery after a restart kills the
    Monitor tool.
  - Usage + operating model: `docs/COORDINATOR.md`; README Features + Quickstart updated.

## [0.8.1] — 2026-09-05

### Changed
- **Sharpened the managed `CLAUDE.md` stanza into a compliance amplifier for the one non-automatic step.**
  Delivery of DMs is now a mechanism (0.7.0) and visibility is automatic (0.8.0), but *arming the Monitor*
  and *acting on a received DM* are irreducibly the agent's job — a hook cannot call the Monitor tool. The
  stanza now (a) makes "ARM your inbox watcher first thing each session" an explicit first action with the
  exact Monitor-tool invocation, (b) states plainly that **a FLEET DM is a task to ACT on, not an FYI**
  (delivery is guaranteed; arming only changes latency), and (c) points to `fleet.sh monitors` for
  reachability. Refreshed in-place via the marker-guarded stanza (`fleet.sh init`).

### Fixed
- **`init` no longer re-dirties `.claude/settings.json` on every run.** The checked-in file was in the old
  compact one-line-array form while `init` emits pretty-printed JSON, so each `init` produced a large
  whitespace-only diff (drift that masked real changes). Committed the installer-canonical pretty form —
  `init` is now byte-idempotent on `settings.json` (verified: two consecutive runs produce identical output).

## [0.8.0] — 2026-09-05

### Added
- **`fleet.sh monitors` — coordinator/operator visibility into who will silently miss wakes.** Classifies every
  agent **MONITORED** / **UNMONITORED** (live but no armed watcher → won't proactively wake) / **CLOSED**, with
  unread counts, ranked unmonitored-with-unread first. Turns the invisible "an agent never armed its Monitor, so
  DMs wait" failure into an actionable signal. Backed by a watcher **liveness breadcrumb** — the `wake-cmd` watcher
  now touches `$STATE_DIR/wake/<sid>.monitor` each tick, giving robust, pgrep-free liveness that also catches a
  *wedged* watcher. New lib.sh: `monitor_fresh`, `agent_liveness_state`, `unread_count`.

### Changed
- **`awareness.sh` re-nudges to arm the watcher** when it isn't running (`⚠ FLEET WAKE NOT ARMED`), every turn until
  armed — a lapse self-heals. Detection is a MECHANISM (breadcrumb freshness); arming stays COMPLIANCE (a hook
  cannot call the Monitor tool — the irreducible platform limit).

## [0.7.0] — 2026-09-05

### Added
- **DM delivery is now a MECHANISM, not compliance.** Folded unread-DM delivery into `heartbeat.sh`
  (PostToolUse) via `hookSpecificOutput.additionalContext` JSON, so an **active** agent — submitting a prompt OR
  running any tool — receives every unread DM **before its next step, with zero arming, zero daemon, zero tokens.**
  `awareness.sh` (UserPromptSubmit, plain stdout) covers prompt-driven turns; `heartbeat.sh` covers long autonomous
  tool turns. Together: **no unread DM survives a turn boundary on an active agent.** (Proactively *waking* an
  idle window stays best-effort via the Monitor — a hook physically cannot arm it; the pull *delivers* on the next
  turn, it does not *wake*. Bare PostToolUse stdout is NOT injected — the `additionalContext` JSON is required and
  verified against the hooks docs.)

### Changed
- **Canonical inbox codepath** — `fleet_unread_scan` + `_fleet_seen_set` (lib.sh), shared by `awareness.sh` and
  `heartbeat.sh` so the read/seen logic never diverges. `.seen` writes are now **atomic (tmp+mv) + monotonic**
  (never regress → a racing writer can't skip a DM), and the cursor advances **only after an actual emit** (a
  throttled or non-injecting tick can never drop a DM). PostToolUse delivery is throttled (default 45s window,
  `FLEET_PULL_THROTTLE_S`) so a tool-heavy turn doesn't repeat the banner — throttle guards noise, never correctness.

### Fixed
- **Settings drift:** the checked-in `.claude/settings.json` was missing `PostToolUse:heartbeat` and the
  SessionStart wake nudges — the repo dogfooded a config that didn't deliver. Regenerated to the installer-canonical
  set; a `selftest-collateral.sh` control now bites if it drifts again.

## [0.6.0] — 2026-09-05

### Added
- **`fleet-agent-map`** — autonomously answer "who is each agent?" without hardcoding. Agents close, get recreated
  (a new `agent-N` inherits a lane), and change focus over time, so a static number→role list rots. This derives it
  live: **branch** from each agent's `cwd` record (authoritative), **role~** keyword-classified from the agent's
  RECENT transcript activity (a hint — re-confirm when it matters), plus the latest activity line. Run it any time
  instead of remembering who's who.

### Changed
- **`wake_nudge` now SURFACES unread DMs at SessionStart** — not just "arm your watcher". It computes
  `unread = inbox line-count − <SID>.seen` and prints `⚠ FLEET: N UNREAD DM(s)` + a 3-line preview when N>0, so a
  new/resumed session sees its backlog immediately (worktree-safe via `--git-common-dir`; all-defensive, never
  breaks the session). Complements the live-Monitor wake from 0.5.0. **Note:** a DM still only *wakes* an agent that
  has armed its Monitor — for a live-but-unmonitored window the DM queues until its next turn.

## [0.5.0] — 2026-09-03

### Added
- **Agent-to-agent wake — a `msg` can WAKE the recipient.** A file-append DM can't wake an idle agent (it's blocked
  on its stdin pipe, not polling the inbox). Two complementary mechanisms close the loop:
  - **Live windows:** `fleet.sh wake-cmd` prints a one-line inbox watcher to hand to the harness Monitor tool; a new
    DM then emits a `FLEET-PING` that re-invokes the window to act. A SessionStart hook (`wake_nudge.sh`, wired by
    `init`) reminds each agent to arm it once.
  - **Closed windows:** `wake-dispatcher.sh` (OPTIONAL, opt-in — never installed or started by `init`)
    headless-resumes an offline session (`claude -p --resume <uuid>`) to process its inbox. Guards: a PROCESS-liveness
    alive-guard (never races a live transcript), per-target cooldown, rolling rate-limit, a kill-switch file,
    cursor+`.seen` dedup, version-agnostic binary resolution, and **dry-run by default**. `--selftest` proves every
    guard bites. Ships with a launchd template (`com.fleet.wake-dispatcher.plist.template`).

### Changed
- **`SessionEnd` preserves UNREAD DMs (`deregister.sh`).** Previously the inbox was deleted unconditionally on window
  close, so a DM to a window that closed first was lost — making a handoff to a closed session impossible. Now the
  inbox + agent record are kept when unread messages remain (line count > `.seen`) so the dispatcher can wake the
  session to process them; a fully-read inbox is still cleaned up.

### Fixed
- **CI: `selftest-collateral.sh` shellcheck SC2034** — sandbox globals consumed by sourced `lib.sh` are now
  `export`ed, restoring a green `main` (the 0.4.0 push had landed red).

## [0.4.0] — 2026-09-02

### Added
- **Shared-tree collateral protection.** When several windows share one working tree + git index, a broad
  `git add -A` / `commit -a` could sweep another window's uncommitted work into a commit (it has pushed a sibling's
  work under the wrong message). Five layers close it, each with a control that bites (`bin/selftest-collateral.sh`):
  a **PostToolUse heartbeat** (`bin/heartbeat.sh`) so a working window never reads stale mid-turn; **reap keeps a
  claim whose path is still dirty** (live work ≠ orphan); a liveness-free **pre-commit `commit-guard.sh`** that blocks
  a staged file covered by a foreign claim when the owner is live *or* the path is dirty; a SessionStart
  **`multiwindow_nudge.sh`** steering a 2nd window to a per-window worktree; and `release` refusing to drop a claim on
  uncommitted work.
- **DM durability — a message to a momentarily-stale window is never dropped.** `reap()` now **keeps** a stale agent
  file (freeing its non-dirty claims) so the sid stays addressable, GC-deleting it only past `agent_gc_s` (default
  24h); `sid_for_target` resolves any known (live *or* kept-stale) window; `cmd_msg` delivers to its inbox regardless
  of liveness (surfaced on return by `awareness.sh`). Control: `selftest-collateral` **D**.

### Changed
- **Liveness tuned for long autonomous turns.** `stale_after_s` default **180 → 900**; the PostToolUse heartbeat
  matcher is **`*`** (every tool refreshes liveness, not just Edit/Write/Bash); and the heartbeat **re-creates** an
  agent file `reap()` already deleted (a tool just ran ⇒ the window is provably alive). `ensure_self_registered` moved
  to `lib.sh` so the heartbeat can share it. New config key: `agent_gc_s` (86400).

## [0.3.0] — 2026-09-01

### Added
- **Per-window goal stacks** (`.fleet/bin/goalstack` + `fleet.sh goal`). The anti-drift `goalstack` anchor keyed only
  by project, so parallel windows shared one stack — one window's goal leaked into another's re-injected "active
  goal" line (hit live: a Monopoly window's goal surfaced in a Pokémon-GO window). `goalstack` now keys **per window**
  (by the Claude Code session id): each window has its own goal + parent stack. A brand-new window inherits the last
  shared goal as a **baseline** (single-window continuity across session turnover preserved); live windows each read
  their own, never cross-contaminated. Backward-compatible: no session id → project-keyed (unchanged). The installer
  upgrades an older `~/.claude/bin/goalstack` in place only when it lacks the per-window capability (detection-gated).
  Byproof-tested: two session ids → two stacks; a fresh window inherits the baseline; no-session → project-keyed.

## [0.2.0] — 2026-09-01

### Added
- **`isolated-gate.sh` — push-safe under parallelism.** A pre-push gate that lints/tests the whole repo reads the
  *filesystem* (every live window's uncommitted work at once), so a sibling window's mid-build files could false-red
  another window's push even when its **commit** was green. The new helper validates the pushed **commit** in a clean
  ephemeral git worktree (deps symlinked) when the shared tree is dirty — bypassing the sibling's work, never touching
  the primary tree or stashing. Clean tree → runs in place (fast path). Real failures in your own commit still bite.
  Wire it in one line: `exec .fleet/bin/isolated-gate.sh -- bash <your gate>`. Byproof-tested (a dirty foreign file is
  invisible to the isolated command; a real commit failure propagates).

## [0.1.0] — 2026-06

Initial release.

### Added
- **Self-registering agents** — each Claude Code window registers as `agent-N` on
  `SessionStart` and is reaped on `SessionEnd`.
- **Hard collision guard** — `PreToolUse` denies (`exit 2`) edits to files a live
  foreign agent has claimed.
- **Atomic claims** — claim/release via atomic `mkdir` lock directories.
- **Live roster + heartbeats** — injected into context each turn; stale agents reaped
  after `stale_after_s` (default 180 s).
- **Agent-to-agent messaging** — `msg` / `inbox`.
- **Two isolation modes** — shared working tree (default) and per-window git worktrees.
- **One-shot installer** — `install.sh` copies `.fleet/` and wires the four hooks.
- CLI: `roster · claim · release · msg · inbox · board · status · doctor · whoami · worktree`.
