# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do **not** open a public issue or PR.
Email **convenientlymike@gmail.com** with a description, repro steps, and the
affected version. We aim to acknowledge within **3 business days**.

## Supported versions

The latest `main` build receives fixes.

## Security posture

- **No network, no daemon, no ports.** Fleet is plain local files + Claude Code
  shell hooks; it opens no listeners and makes no outbound calls.
- **No secrets.** Fleet stores no credentials. Runtime coordination state lives in
  `.fleet/state/` and is **gitignored** (per-machine), so agent IDs / claims / the
  message inbox never enter version control.
- **Blast radius is the working tree.** The `guard.sh` hook only ever *denies* an
  edit (`exit 2`); it never executes foreign input. Claims are atomic `mkdir` locks.
- **Heartbeat reaping** prevents a crashed window from holding a lock forever.
- Avoid running inside iCloud/Dropbox-synced folders (sync races can corrupt the
  atomic-claim guarantee) — see `.fleet/README.md`.
