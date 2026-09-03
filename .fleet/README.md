# Fleet (`.fleet/`)

Multi-window coordination for Claude Code. Open several Claude Code windows on
the same project; each becomes a **registered agent** that works independently
but can see the others and is **hard-blocked** from editing files another live
agent has claimed.

Everything here is plain files — you can always inspect and recover by hand.

## Layout

```
.fleet/
  VERSION            schema/version string
  config.json        tunables (see below)
  bin/               all logic (bash 3.2-safe; jq/python optional)
    lib.sh           shared helpers
    register.sh      SessionStart  -> register this window as an agent (silent)
    guard.sh         PreToolUse     -> BLOCKS edits to files a live agent claimed
    commit-guard.sh  git pre-commit -> BLOCKS committing a file a live FOREIGN agent claimed (--selftest)
    awareness.sh     UserPromptSubmit -> heartbeat + inject roster into context
    deregister.sh    SessionEnd     -> release claims, remove agent
    fleet.sh         the CLI (claim/release/roster/msg/inbox/board/...)
    installer.sh     init / uninstall logic (sourced by fleet.sh)
  state/             RUNTIME, git-ignored, per-machine:
    agents/<sid>.json   one file per LIVE window (presence = registered; mtime = alive)
    claims/<slug>.lock/ a DIRECTORY per claim (mkdir is the atomic mutex)
    inbox/<sid>.jsonl   messages to an agent
    board.jsonl         shared activity feed
    ledger.jsonl        append-only audit log
```

## Config (`config.json`)

| key              | default  | meaning                                                        |
|------------------|----------|----------------------------------------------------------------|
| `stale_after_s`  | `180`    | no heartbeat for this many seconds → agent is dead, claims freed |
| `claim_mode`     | `prefix` | `prefix` = a dir claim covers everything under it; `exact` = file-level |
| `block_mode`     | `block`  | `block` = hard-deny the edit (exit 2); `warn` = advisory only  |
| `state_location` | `local`  | `local` = state in `.fleet/state`; `git-common` = shared across worktrees |

## Commit safety (the shared-index hazard)

Sessions share ONE working tree **and one git index**. `guard.sh` blocks *editing* a foreign claim, but a broad
`git add -A` / `git commit -a` **auto-stages** every modified file — including a sibling session's staged,
unreviewed work — and commits it under your message (this has pushed another session's work PUBLIC). The edit-guard
can't see that (the commit auto-stages *after* editing).

- **`commit-guard.sh`** (git `pre-commit`, wired by `install-hook` into `scripts/git-pre-commit`) refuses any commit
  whose staged set contains a file **claimed by another LIVE agent**. Fail-open (a guard bug never wedges commits);
  respects `block_mode`. Prove it bites: `bash .fleet/bin/commit-guard.sh --selftest`.
- **Commit narrowly:** `git commit <your-file> …` — explicit paths build a temp index from just those paths, so a
  sibling's staged files can't ride along (and the guard passes since you only touch your own claims).
- **Structural fix for heavy parallel work:** a **`git worktree` per session** (own index + working dir, shared
  `.git`): `git worktree add ../phantom-<task> -b <branch>`.

## Recover by hand

- See who's live: `ls .fleet/state/agents/` or `bash .fleet/bin/fleet.sh roster`
- See claims: `ls .fleet/state/claims/`
- Force-free a stuck claim: `rm -rf .fleet/state/claims/<slug>.lock`
- Reset everything: `rm -rf .fleet/state/*` (agents re-register on next prompt)
- Health check: `bash .fleet/bin/fleet.sh doctor`

## Caveats

- **Cloud-synced folders** (iCloud Drive, Dropbox, OneDrive): `mkdir` atomicity
  is unreliable there, which weakens the lock. Use a non-synced path, or
  worktree mode. `fleet.sh status` warns if it detects one.
- **settings.json is read at startup** — reopen already-open windows after install.
- Locks prevent two windows editing the **same file**; git is still the
  authority for line-level merges of edits to *different* files. For
  write-heavy parallel work, use `fleet.sh worktree enable` + one worktree
  per window (true isolation, fleet coordinates across them).
- **Symlinks are not canonicalized.** A claim on `real/file.txt` does not block
  an edit that targets a *symlink* pointing at it. Claude Code passes the literal
  path the user/model referenced, so this only matters if you deliberately edit a
  claimed file through a different symlinked path. Claim the path you actually edit.

## Shared-tree collateral protection (2026-09-02)

The failure: two windows share one working tree + git index; a sibling's broad `git add -A` / `commit -a` swept
another window's *uncommitted* work into its commit (and pushed it under the wrong message). Root cause — deeper
than "claim released before commit": the liveness heartbeat beat **only on UserPromptSubmit**, so a window working
autonomously for `> stale_after_s` (180 s) read **STALE**; a sibling's `reap()` then garbage-collected its *claims*,
leaving its dirty files ownerless for the sweep. Five layers now close this (each with a control that bites —
`bash .fleet/bin/selftest-collateral.sh`, wired into the project gate suite):

- **C0a — heartbeat on work.** `heartbeat.sh` (PostToolUse: `Edit|Write|MultiEdit|Bash`) `touch`es the agent file
  on every tool use, so a working window never reads dead mid-turn.
- **C0b — reap keeps a DIRTY-path claim.** `reap()`/`_release_claims_of` skip removing a claim whose path still has
  uncommitted changes — a claim over dirty content is *live work*, not an orphan.
- **C1 — commit-guard is liveness-free.** It blocks a staged file covered by a foreign claim if the owner is LIVE
  **or** (regardless of liveness) the claimed path is **DIRTY** (a sibling's uncommitted content). Fail-OPEN on
  identity/infra ambiguity; fail-SAFE on content collision. Escape hatch: `git commit <your-explicit-paths>` (a
  file you didn't stage can't ride along).
- **D1 — worktree nudge.** `multiwindow_nudge.sh` (SessionStart) steers a 2nd+ window sharing the primary tree to
  `fleet.sh worktree enable && fleet.sh worktree new <label>` — the **structural** fix (own working dir + index →
  collateral impossible by construction).
- **D2 — release refuses a dirty claim.** `fleet.sh release` refuses to drop a claim whose path is uncommitted
  (the exact antipattern), unless `--force`.

**The rules, restated:** claim before editing · commit **narrowly** (`git commit <your-paths>`, never `-a`) · don't
release a claim on uncommitted work · for write-heavy parallel work, use a **worktree per window**.

## Liveness + DM durability (v0.4.0)

A window is "live" iff its agent file's mtime is within `stale_after_s`. Two failure modes are closed so an
**actively-working** window is neither hidden from the roster nor un-messageable:

- **Prevention (never read stale mid-work).** `stale_after_s` defaults to **900s** (long autonomous turns); the
  PostToolUse heartbeat matches **`*`** (every tool — a Read/Grep/Task/think-heavy turn refreshes liveness, not just
  Edit/Write/Bash); and the heartbeat **re-creates** an agent file `reap()` already deleted (a tool just ran ⇒ the
  window is provably alive → `ensure_self_registered`, moved to `lib.sh`). Control: selftest-collateral **C0a**.
- **Durability (a DM is never dropped).** `reap()` **keeps** a stale agent file (frees its non-dirty claims) so the
  sid stays addressable, and only **GC-deletes** it once its mtime passes `agent_gc_s` (default 24h) — so
  `sid_for_target` resolves a momentarily-stale window by label/short/sid and `cmd_msg` delivers to its inbox, which
  `awareness.sh` surfaces on its return. `count_live`/roster stay mtime-based, so a kept-stale file never reads live.
  Control: selftest-collateral **D** (deliver-to-stale + GC-bound + reject-unknown).

Tunables in `config.json`: `stale_after_s` (900), `agent_gc_s` (86400).

### Worktree-per-window — the STRUCTURAL end to the shared-index races

The guards above are a backstop; a shared *git index* can still be raced (two windows `git add` into the one index,
a racing `git commit` sweeps the other's staged files — happened 2026-09-02). A worktree gives each window its **own
index + working dir**, so a commit there *physically cannot* see another window's staged files — collateral is
impossible by construction. State is `git-common` (shared `.git/fleet` board across worktrees), so fleet coordination
still spans them. The flow (each window, once):

```
fleet.sh worktree new <lane>      # creates ../<repo>--<lane> on branch fleet/<lane> (a SIBLING dir, own index)
# → open ../<repo>--<lane> in a NEW window; RETIRE the old primary-tree window. Work + commit freely there.
fleet.sh worktree merge <lane>    # ff-only merge fleet/<lane> → main in the PRIMARY (clean integration point); push from there
fleet.sh worktree gc              # prune removed worktrees + list merged fleet/* branches to delete
```

Once BOTH windows are in worktrees, **no window edits the primary tree** — it's the clean integration point (merges
land there, pushes happen there). `worktree merge` refuses if the primary is dirty (a window still works there). If
`main` moved since your branch (the other window merged first), rebase your branch on `main` then re-merge, or
`worktree merge --merge <lane>` for a merge commit.
