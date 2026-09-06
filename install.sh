#!/usr/bin/env bash
# install.sh — drop Fleet into an existing project.
# Usage:
#   bash install.sh [TARGET_DIR] [-- <fleet init flags>]
# Copies the .fleet/ folder into TARGET_DIR (default: current directory) and
# runs `fleet.sh init`. Safe to re-run; never clobbers existing settings.
set -eu

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"
[ "${1:-}" = "--" ] && TARGET="$PWD"
case "${1:-}" in --) shift ;; "") : ;; *) shift || true ;; esac
if [ "${1:-}" = "--" ]; then shift || true; fi   # remaining args -> init flags

TARGET="$(cd "$TARGET" 2>/dev/null && pwd || echo "$TARGET")"
if [ ! -d "$TARGET" ]; then echo "target not a directory: $TARGET" >&2; exit 1; fi
if [ "$SRC" = "$(cd "$TARGET" && pwd)" ]; then
  echo "Installing in place ($TARGET)"
else
  echo "Copying .fleet/ -> $TARGET"
  cp -R "$SRC/.fleet" "$TARGET/"
fi
chmod +x "$TARGET/.fleet/bin/"*.sh 2>/dev/null || true

# Install the Fleet agent skills (/coordinator, /arm) into the project's
# .claude/skills/ so they are invocable in Claude Code. Fleet owns these two
# skill dirs (refreshed on every install); other skills in .claude/skills/ are
# left untouched.
if [ -d "$TARGET/.fleet/skills" ]; then
  mkdir -p "$TARGET/.claude/skills"
  for _sk in "$TARGET/.fleet/skills/"*/; do
    [ -d "$_sk" ] || continue
    _name="$(basename "$_sk")"
    rm -rf "$TARGET/.claude/skills/$_name"
    cp -R "$_sk" "$TARGET/.claude/skills/$_name"
  done
  echo "Installed Fleet skills -> $TARGET/.claude/skills/ (/coordinator, /arm)"
fi

exec bash "$TARGET/.fleet/bin/fleet.sh" init "$@"
