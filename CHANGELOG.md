# Changelog

All notable changes to Fleet are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Commit-attic — work-loss hardening (`fleet.sh attic`).** Every commit is auto-backed-up so a branch
  reset / `checkout -f` / gc can NEVER silently lose committed work — it is always recoverable. Two layers:
  - **Auto-backup on commit** (a `post-commit` hook) writes both a GC-proof ref
    `refs/attic/<agent>/<epoch>-<sha>` (a reset can't drop it; `git gc` keeps a ref's commit reachable) and a
    browsable patch + metadata under the git-common state dir (`<state>/commit-attic/<agent>/`). The `<agent>`
    sub-key is the fleet session id (else the branch).
  - **Pre-reset guard** (a `reference-transaction` hook) BLOCKS a branch **rewind** that would drop a commit not
    recoverable from the attic (a fast-forward, and a rewind whose dropped commits are all atticed, pass;
    non-branch refs incl. `refs/attic/*` are ignored so backups never self-block). Escape hatch:
    `FLEET_ATTIC_FORCE=1`.
  - `fleet.sh attic install | list | recover <sha>` — install the hooks, browse backups, and recreate a branch at
    any backed-up commit. Root-cause doctrine it pairs with: **each agent commits to a DEDICATED per-slice
    branch**; the coordinator integrates via batch-land — never reset a shared branch carrying others' work.
  - **Forcing function:** `.fleet/bin/selftest-attic.sh` (hermetic, wired into CI) proves each guarantee BITES
    with a control that fires — backup makes a ref+patch, the guard blocks an un-atticed rewind (allows a
    fast-forward / an atticed rewind / a FORCE escape), and a dropped commit is recoverable.
  - **WHY (2026-09-11):** a SHARED lane branch was repeatedly `reset --hard origin/main`, dropping in-flight
    slice commits from HEAD (recovered by hand via reflog). The attic makes recovery structural, not manual.

### Fixed
- **Label reservation hardening (pre-merge red-team follow-up to the atomic reservation).** A 6-lens
  adversarial red-team of the reservation (each finding refuted before trust) surfaced one **critical**
  residual and two completions, now closed:
  - **reap-vs-reserve race (the critical).** `reap()`'s label-GC removed a reservation whose owner had
    no agent file — but `register.sh` creates the reservation *before* writing the agent file, so a
    concurrent `reap` (which runs on every fleet command in every session) could delete a just-created
    in-flight reservation, after which a third session re-`mkdir`'d the same `agent-N` → **the exact
    duplicate-`agent-N` collision reintroduced**. The reap-GC path now carries the same reservation-age
    **grace guard** `_label_reclaimable` uses on the reserve side: GC only when the owner is departed
    **and** the reservation dir has aged past `FLEET_LABEL_GRACE`. A fresh in-flight slot (and the
    empty-`sid` sub-window between `mkdir` and the `sid` write) is protected; a genuinely-departed
    owner's minutes-old reservation still frees promptly.
  - **Fail-loud routing symmetry.** `sid_for_target`'s pass-2 (kept-stale files) now fails loud (exit 3,
    names candidate shorts) when ≥2 stale windows share a label, matching pass-1 — a handoff DM to a
    departed `agent-N` is no longer silently delivered to only one of two same-label inboxes.
  - **Grace is tunable + safer default.** `FLEET_LABEL_GRACE` is now config-readable (`label_grace_s`)
    like `stale_after_s`, and its default is raised 3→10s to comfortably exceed the reserve→agent-file
    write gap on a cold host spawning many windows at once.
  - **Upgrade-transition guard (closes the collision by construction, not rollout timing).** Rolling the
    reservation model onto an *active* fleet leaves existing windows carrying an agent-**file** label but
    no reservation yet (created on their next `register.sh`). `reserve_label`/`next_label` now consult
    `_label_held_by_live_file`: a label a LIVE window's agent-file holds OCCUPIES its slot (self-excluded,
    live-only), so a new registration during the transition is never handed a label a live window already
    shows. The check runs only on an otherwise-free slot, so it is ~free in steady state.
  - **Forcing coverage:** `selftest-labels.sh` gains **L7** (a concurrent reap during an in-flight
    reserve — the fresh reservation SURVIVES; control: an aged departed one is still GC'd), **L7b**
    (the empty-`sid` sub-window), **L4b** (pass-2 kept-stale fail-loud + no over-trigger), and **L8** (a
    new registration skips a live agent-file's label during an upgrade; control: a stale file-label is
    reusable). Each was watched to BITE with its guard reverted. (Reclaim-vs-reclaim atomicity and the
    reclaimed-then-revived heartbeat-heal remain tracked as follow-ups.)
- **Duplicate `agent-N` labels under concurrent registration (the two-"agent-1" collision).**
  `next_label` READ the agent files and the caller WROTE its own record separately, so two
  windows registering at the same time both saw "agent-1 free" and both took it — the roster
  showed two live `agent-1`s and a DM to `agent-1` mis-routed to whichever file enumerated
  first. Label assignment is now an **atomic reservation**: a directory `state/labels/agent-N`
  holding the owner `sid`, created with `mkdir` (the create-or-fail arbiter), so concurrent
  registrants can never land the same label.
  - **`reserve_label <sid> [preferred]`** (lib.sh) replaces `next_label` on every assignment
    path (`register.sh`, `awareness.sh`, `ensure_self_registered`). It is **stable per session**
    (a resume/heartbeat returns the SAME label — the reservation persists independently of the
    heartbeat-rewritten agent file), **unique among live**, and reclaims a slot only from a
    provably-departed owner (guarded by a grace window so a mid-registration winner — briefly
    "not live" because its agent file is not written yet — is never stolen). `preferred` bridges
    an upgrade/reservation-less resume so an existing `agent-N` is preserved, never a live one
    stolen. `next_label` remains as a pure non-mutating "what's next" peek over the same
    `LABELS_DIR` source of truth, so the two can't disagree.
  - **Fail-loud routing.** `sid_for_target` now refuses to guess when a **label** matches more
    than one LIVE window: `fleet.sh msg agent-1 …` exits **3** and names the candidate shorts
    (`fleet.sh msg <short> …`) instead of silently mis-delivering. A sid/short id is always
    unambiguous; a unique label still resolves.
  - **Bounded + reused.** `reap` GC-removes a reservation whose owner file is fully gone (a
    kept-stale, still-addressable window keeps its stable label); `deregister` frees a label on
    graceful close (the unread-DM handoff path keeps it for `wake-dispatcher`). `FLEET_STATE_DIR`
    / git-common worktree mode re-derive `LABELS_DIR` with the other state dirs, so labels
    always land in the resolved state dir (never a stale default).
  - **Forcing function:** `.fleet/bin/selftest-labels.sh` (hermetic, wired into CI) proves each
    guarantee BITES with a control that fires — 8 concurrent reservations are distinct (vs a
    naive read-then-write that collides), stable-per-session, freed-then-reused, and a duplicate
    live label fails loud without over-triggering on a unique one.

### Added
- **`/task-manager` agent skill.** Fleet ships a fourth dedicated-seat skill under
  `.fleet/skills/` (installed into the target's `.claude/skills/` like the others). It
  onboards a window as the fleet's **goals/tasks/status coordination seat** — the peer of
  `/coordinator` (git) and `/brain` (knowledge). It keeps every agent lane's active goal
  current, surfaces stalls + reachability gaps + stale claims + blockers from
  `fleet.sh roster` / `monitors`, routes work with `fleet.sh msg`, keeps the board tidy, and
  gives the operator a "who's on what / what's next / what's stuck" readout. Generic:
  Fleet's own `roster` / `board` / `msg` / `goal` / `retire` are the substrate, and any
  richer project-specific task board is an **optional** integration — the seat works with
  Fleet alone.
- **CI now proves skills install.** A new `skills-install` job runs `install.sh` into a temp
  project and asserts **every** skill under `.fleet/skills/` propagates into
  `.claude/skills/` (dynamic over the source, so new skills are auto-covered; explicit
  asserts for the known skills guard a silent glob no-op). Closes the gap where the smoke
  job only ran `fleet.sh init` (which does not copy skills), leaving skill propagation
  untested.
- **`/brain` agent skill + `brain` / `retire` subcommands.** Fleet ships a third skill
  under `.fleet/skills/` (installed into the target's `.claude/skills/` like the others),
  plus two new `fleet.sh` subcommands lazy-loaded from `.fleet/bin/brain-retire.sh`.
  - **`/brain`** onboards a window as the fleet's knowledge-oracle + research seat: it
    takes the Brain seat (`fleet.sh brain serve`), arms the wake-on-DM monitor, then answers
    `fleet.sh brain ask "<q>"` questions from any available memory/knowledge tooling + live
    web research, cites + honesty-bands, and captures durable findings. The skill is generic:
    any memory-corpus tool is an **optional** PATH integration — `brain` degrades gracefully
    (a clear message) when none is present, and uses only Fleet's own DM / board / state.
  - **`fleet.sh brain <query> | ask "<q>" | serve | who | stand-down`** — the CLI oracle
    (wraps a memory-search tool if present), deep-question routing to the Brain seat (DM, with
    a CLI fallback when no Brain is registered), and take/inspect/vacate of the seat.
  - **`fleet.sh retire [<agent>] [--force]`** — safely unload **any** agent from the fleet on
    demand (the on-demand sibling of the `SessionEnd` deregister hook). Resolves the target by
    `agent-N` / short / session-id (no arg = self), releases its claims, removes its record +
    wake breadcrumb, vacates the Brain seat if it held it, and emits a `retire` board event.
    Safe-by-default: **refuses** to drop a claim over uncommitted (dirty) work, or to strand a
    foreign agent's unread DMs, without `--force` (a `--force` retire preserves a non-empty
    inbox for durable handoff, matching `deregister.sh`).
  - **Forcing function:** `.fleet/bin/selftest-brain-retire.sh` (hermetic, isolated state)
    proves the happy paths AND that the safety guards BITE (retire refuses a dirty claim /
    stranded unread DMs without `--force`; the C0b dirty-work invariant is honored). Wired
    into CI as a dedicated `selftest` job run in a real git tree so the negative controls fire.
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
    - **Arm-the-monitor is now canonical.** `/coordinator` §4 arms via `fleet.sh wake-cmd`
      (resolves the inbox/wake paths for BOTH `local` and worktree `git-common` state
      modes, and writes the `: > "$mon"` liveness heartbeat so `fleet.sh monitors` reports
      the coordinator `MONITORED`), then splices in the new-agent + network-recovery probes
      — replacing a hand-rolled snippet that hardcoded `.git/fleet` (wrong in the default
      `local` mode) and omitted the heartbeat (coordinator mis-read as `UNMONITORED`).
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
