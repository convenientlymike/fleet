# Changelog

All notable changes to Fleet are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
