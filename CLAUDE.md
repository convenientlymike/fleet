
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

Your identity is auto-detected — just run the commands.
<!-- FLEET:END -->
