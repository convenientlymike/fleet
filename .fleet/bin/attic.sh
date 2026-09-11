#!/usr/bin/env bash
# attic.sh — WORK-LOSS HARDENING for the fleet (operator-greenlit 2026-09-11). Every commit is auto-backed-up to a
# GC-proof ref (refs/attic/<agent>/<epoch>-<sha>) AND a browsable patch under the git-common state dir, so a branch
# reset / checkout -f / gc can NEVER lose committed work — it is always recoverable. A reference-transaction guard
# additionally BLOCKS a branch REWIND that would drop an UN-atticed commit (escape hatch: FLEET_ATTIC_FORCE=1).
#
# WHY (2026-09-11): the SHARED fleet/frontend branch was repeatedly `reset --hard origin/main`, dropping in-flight
# commits (a slice's whole work) from HEAD 3x. Recovered via reflog by hand. Doctrine pairing: each agent commits
# to a DEDICATED per-slice branch; you integrate via batch-land — never reset a shared branch carrying others' work.
#
# Sourced by fleet.sh (the `attic` subcommand); the installed git hooks call back into `fleet.sh attic backup|guard`.
# bash-3.2-safe. Sourced AFTER lib.sh (uses STATE_DIR / now_epoch / short_sid / log_err / FLEET_BIN_DIR).
set -u

_ATTIC_ZERO="0000000000000000000000000000000000000000"

# _attic_dir — the git-common commit-attic folder (browsable patches). STATE_DIR is git-common-resolved by lib.sh,
# so backups are shared across worktrees of the repo and survive a per-repo ref purge.
_attic_dir() { printf '%s/commit-attic' "$STATE_DIR"; }

# _attic_agent — the backup sub-key: the fleet session id (short) if present, else the current branch. Sanitized to
# a single path-safe component (a ref/dir name).
_attic_agent() {
  local a="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$a" ] && a="$(short_sid "$a")"
  [ -z "$a" ] && a="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
  printf '%s' "$a" | tr -c 'A-Za-z0-9._-' '-'
}

# attic_backup [<committish>] — back up a commit (default HEAD): a GC-proof ref + a patch + a meta sidecar.
# Idempotent, FAIL-OPEN (never blocks a commit). Called by the post-commit hook.
attic_backup() {
  local sha short agent epoch d pf
  sha="$(git rev-parse --verify "${1:-HEAD}^{commit}" 2>/dev/null)" || return 0
  short="$(printf '%s' "$sha" | cut -c1-12)"
  agent="$(_attic_agent)"
  epoch="$(now_epoch)"
  # (a) GC-proof backup ref — a reset / branch-delete cannot drop it; `git gc` keeps a ref's commit reachable.
  git update-ref "refs/attic/$agent/$epoch-$short" "$sha" 2>/dev/null || true
  # (b) browsable patch + metadata under the git-common state dir.
  d="$(_attic_dir)/$agent"
  mkdir -p "$d" 2>/dev/null || true
  pf="$d/$epoch-$short.patch"
  { git format-patch -1 --stdout "$sha" 2>/dev/null || git show "$sha" 2>/dev/null; } > "$pf" 2>/dev/null || true
  git log -1 --format='%H%x09%an%x09%ci%x09%s' "$sha" > "$d/$epoch-$short.meta" 2>/dev/null || true
  return 0
}

# _attic_contains <sha> — is <sha> already recoverable from the attic (contained by some refs/attic/* ref)?
_attic_contains() {
  [ -n "$(git for-each-ref --contains "$1" refs/attic 2>/dev/null | head -1)" ]
}

# attic_guard <state> — the reference-transaction hook body. On 'prepared', BLOCK (exit 1) a branch REWIND that
# would drop a commit NOT already in the attic (escape: FLEET_ATTIC_FORCE=1). Fast; fail-OPEN on anything odd so it
# can never wedge normal git. Ignores non-branch refs (incl. refs/attic/* — so our own backup writes never recurse).
attic_guard() {
  [ "${1:-}" = "prepared" ] || return 0
  [ "${FLEET_ATTIC_FORCE:-}" = "1" ] && return 0
  local old new ref dropped c
  while read -r old new ref; do
    case "$ref" in refs/heads/*) : ;; *) continue ;; esac   # only guard LOCAL branches
    [ "$old" = "$_ATTIC_ZERO" ] && continue                 # branch creation — nothing dropped
    [ "$new" = "$_ATTIC_ZERO" ] && continue                 # deletion — the attic still holds the commits
    git merge-base --is-ancestor "$old" "$new" 2>/dev/null && continue   # fast-forward — drops nothing
    dropped="$(git rev-list "$new..$old" 2>/dev/null)" || continue        # commits in old NOT in new (dropped)
    for c in $dropped; do
      if ! _attic_contains "$c"; then
        log_err "fleet attic: REFUSING to move $ref — it would DROP un-backed-up commit ${c}."
        log_err "  (work-loss guard) That commit is not in the attic. It should be auto-atticed by post-commit;"
        log_err "  if you truly mean to drop it, re-run with FLEET_ATTIC_FORCE=1. Recover any commit: fleet.sh attic recover <sha>."
        return 1
      fi
    done
  done
  return 0
}

# ---- CLI subcommands -------------------------------------------------------
_attic_hooks_dir() {
  local hp; hp="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [ -n "$hp" ]; then
    case "$hp" in /*) printf '%s' "$hp" ;; *) printf '%s/%s' "$(git rev-parse --show-toplevel 2>/dev/null)" "$hp" ;; esac
  else
    git rev-parse --git-path hooks 2>/dev/null
  fi
}

_attic_write_hook() {
  local path="$1" body="$2"
  if [ -f "$path" ] && ! grep -q 'fleet.sh attic' "$path" 2>/dev/null; then
    printf '\n# --- fleet attic (auto) ---\n%s\n' "$body" >> "$path"          # chain onto a foreign hook, never clobber
  else
    printf '#!/usr/bin/env bash\n# fleet attic (auto-installed) — re-run: fleet.sh attic install\n%s\n' "$body" > "$path"
  fi
  chmod +x "$path" 2>/dev/null || true
}

_attic_install() {
  local hd self
  hd="$(_attic_hooks_dir)"; [ -n "$hd" ] || { log_err "attic: cannot resolve the git hooks dir"; return 1; }
  mkdir -p "$hd" 2>/dev/null || true
  self="$FLEET_BIN_DIR/fleet.sh"
  _attic_write_hook "$hd/post-commit"            "exec \"$self\" attic backup >/dev/null 2>&1 || true"
  _attic_write_hook "$hd/reference-transaction"  "exec \"$self\" attic guard \"\$@\""
  printf 'fleet attic: installed post-commit (auto-backup) + reference-transaction (pre-reset guard) in %s\n' "$hd"
}

_attic_list() {
  printf 'ATTIC REFS (refs/attic/*):\n'
  git for-each-ref --sort=-refname --format='  %(refname:short)  %(objectname:short)  %(subject)' refs/attic 2>/dev/null | head -60
  printf 'ATTIC PATCHES (%s):\n' "$(_attic_dir)"
  find "$(_attic_dir)" -name '*.meta' 2>/dev/null | sort -r | head -60 | while read -r m; do
    printf '  %s  %s\n' "$(basename "$m" .meta)" "$(cut -f4 "$m" 2>/dev/null)"
  done
}

_attic_recover() {
  local what="${1:-}" sha br
  [ -n "$what" ] || { log_err "usage: fleet.sh attic recover <sha|attic-ref-fragment>"; return 2; }
  sha="$(git rev-parse --verify "$what^{commit}" 2>/dev/null || true)"
  [ -n "$sha" ] || sha="$(git for-each-ref --format='%(objectname)' "refs/attic/**" 2>/dev/null | while read -r s; do
      case "$s" in *"$what"*) printf '%s\n' "$s"; break ;; esac; done)"
  [ -n "$sha" ] || sha="$(git for-each-ref refs/attic --format='%(refname) %(objectname)' 2>/dev/null | grep -- "$what" | head -1 | awk '{print $2}')"
  [ -n "$sha" ] || { log_err "attic: no commit matches '$what' (see: fleet.sh attic list)"; return 1; }
  br="attic-recover-$(printf '%s' "$sha" | cut -c1-8)"
  git branch -f "$br" "$sha" 2>/dev/null || { log_err "attic: could not create branch $br"; return 1; }
  printf 'fleet attic: recovered %s → branch %s  (git checkout %s)\n' "$sha" "$br" "$br"
}

cmd_attic() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    install) _attic_install ;;
    backup)  attic_backup "$@" ;;    # post-commit hook entrypoint
    guard)   attic_guard "$@" ;;     # reference-transaction hook entrypoint
    list)    _attic_list "$@" ;;
    recover) _attic_recover "$@" ;;
    *) log_err "usage: fleet.sh attic {install|list|recover <sha>|backup|guard}"; return 2 ;;
  esac
}
