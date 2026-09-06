# The Coordinator role — `/coordinator` and `/arm`

Fleet lets you open many Claude Code windows as parallel agents that develop in
isolated **git worktrees** on `fleet/*` branches. Someone has to keep `main` green
and integrate everyone's work. That's the **coordinator** — and these two skills let
any agent become one (or recover one) in a single command.

| Skill | What it does |
|---|---|
| **`/coordinator`** | Onboards the current window as the dedicated git push/merge/integration coordinator: fast repo + worktree + fleet-agent orientation, arms the monitor, then runs the land loop for every `LAND-READY` signal. |
| **`/arm`** | Standalone (re-)arm of the persistent fleet monitor (inbox DMs + new-agent + network recovery). The one-command recovery after a restart kills the Monitor. |

Both ship with Fleet under `.fleet/skills/` and are installed into your project's
`.claude/skills/` by `install.sh`, so they're invocable as `/coordinator` and `/arm`
in any Fleet-enabled project.

---

## Install

`install.sh` copies them automatically:

```bash
bash install.sh /path/to/your/project      # copies .fleet/ AND installs the skills
```

Already have `.fleet/` and just want the skills? Re-run `install.sh` in place, or copy
them yourself:

```bash
mkdir -p .claude/skills
cp -R .fleet/skills/coordinator .fleet/skills/arm .claude/skills/
```

Then **reopen** the window (skills load at startup). Fleet owns the `coordinator` and
`arm` skill dirs and refreshes them on every install; your other skills are untouched.

---

## Use it

### One coordinator per fleet

Open a window in the project's **primary tree** (or wherever you integrate from) and run:

```
/coordinator
```

It will orient itself (worktrees, lanes, live agents, the gate list), arm the monitor,
and announce itself on the board. From then on it integrates every lane's verified work:

> **merge the frozen branch tip (`--no-ff`) → run the pre-push gate → verify the push
> actually landed with an authoritative `ls-remote` (never trust exit-0) → de-drift every
> worktree → DM the lane.**

The worker agents just develop, claim files, commit narrowly, and DM the coordinator
`LAND-READY <sha>` when a chunk is gate-green. The coordinator does the rest.

### After a restart — re-arm

Claude Code's Monitor tool does **not** survive a window/VS Code restart, so the
coordinator's wake-on-events watcher dies. Bring it back with:

```
/arm
```

This re-arms the persistent monitor (inbox DMs + new-agent registrations + network
recovery) for the session. `/coordinator` runs `/arm` as part of onboarding; use `/arm`
on its own when only the watcher needs recovering. (Under the hood it's the same watcher
`fleet.sh wake-cmd` prints, extended with new-agent + network-recovery signals.)

---

## The operating model (what the coordinator enforces)

The full playbook lives in [`.fleet/skills/coordinator/SKILL.md`](../.fleet/skills/coordinator/SKILL.md).
The load-bearing rules:

- **Never bypass the gate.** No `--no-verify`, no forcing past a red gate or the
  commit-guard. A red gate means the tree isn't ready — fix the root cause or coordinate
  the owner's fix. One red commit poisons `main` for every later push.
- **A push is unverified until `ls-remote` proves it.** Exit-0 lies — on a flaky network a
  gate-green push can `SIGPIPE` mid-transfer and still report success. Always compare
  `git ls-remote origin refs/heads/main` to local `main`.
- **Stage narrowly.** Never `git add -A` / `commit -a` on a shared tree — a broad add
  sweeps a sibling's uncommitted work into your commit.
- **De-drift bidirectionally.** After landing, merge `origin/main` into every worktree so
  all lanes pick up each other's work. The merge aborts cleanly on overlap — it never
  clobbers in-flight work.
- **Diagnose real vs. false-fail.** If a data-dependent gate fails only in the gate's
  ephemeral isolated-worktree (because the tree was dirty), confirm by running it
  *in-place*; keep the tree clean (gitignore transient dirs like `.claude/worktrees/`) so
  the gate runs in-place with correct results.
- **Name agents by branch + mission**, never a bare rotating number.

## Project-specific bits

The skills reference two things each project provides:

- **The pre-push gate** — the coordinator runs it via `.fleet/bin/isolated-gate.sh`; the
  actual checks (e.g. a `run_gates` script) are the project's own. The isolated-gate runs
  the gate **in-place** on a clean tree, or in an **ephemeral worktree** when dirty.
- **`fleet-agent-map`** *(optional helper)* — resolves each agent's branch + founding
  mission for human-readable references. If absent, use `fleet.sh roster` +
  `git worktree list` to map agents to lanes.
