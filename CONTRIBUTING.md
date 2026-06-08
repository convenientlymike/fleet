# Contributing to Fleet

Thanks for helping make parallel Claude Code work safer.

## Ground rules
- **Shell:** POSIX-friendly Bash. Keep it dependency-free (Bash + coreutils + `git`).
- **Lint:** `shellcheck` is the gate — run it on everything before a PR:
  ```bash
  shellcheck --severity=warning install.sh .fleet/bin/*.sh
  ```
- **Atomicity is sacred.** The claim mechanism relies on `mkdir` being atomic +
  fail-if-exists. Don't replace it with read-then-write logic.
- **No new runtime deps, no daemon, no ports.** The whole value is "just files + hooks."
- **State stays gitignored.** Never commit anything under `.fleet/state/`.

## Workflow
1. Branch from `main`.
2. Make the change; run `shellcheck` (and `bash .fleet/bin/fleet.sh doctor`).
3. Conventional-commit message (`feat:`, `fix:`, `docs:`, `chore:`) explaining the *why*.
4. Open a PR with a clear description; CI (shellcheck) must be green.

## Testing a change locally
Install Fleet into a scratch project and open two Claude Code windows:
```bash
bash install.sh /tmp/fleet-scratch && cd /tmp/fleet-scratch
.fleet/bin/fleet.sh roster
```
Verify a claim in one window blocks an edit in the other.
