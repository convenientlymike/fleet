# Changelog

All notable changes to Fleet are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
