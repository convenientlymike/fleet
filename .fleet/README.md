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
