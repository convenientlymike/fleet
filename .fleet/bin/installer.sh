#!/usr/bin/env bash
# installer.sh — sourced by fleet.sh for `init` and `uninstall`.
# Idempotent + additive: merges Fleet hooks into the PROJECT .claude/settings.json
# (never the user's global settings), preserving any existing hooks. Re-running
# strips old fleet entries first, so it never duplicates.

SETTINGS_DIR="$PROJECT_ROOT/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"
GITIGNORE="$PROJECT_ROOT/.gitignore"
CLAUDEMD="$PROJECT_ROOT/CLAUDE.md"

# fixed hook objects (relative paths -> portable across clones)
SS_OBJ='{"hooks":[{"type":"command","command":".fleet/bin/register.sh"},{"type":"command","command":".fleet/bin/multiwindow_nudge.sh"},{"type":"command","command":".fleet/bin/wake_nudge.sh"}]}'
PRE_OBJ='{"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":".fleet/bin/guard.sh"}]}'
POST_OBJ='{"matcher":"*","hooks":[{"type":"command","command":".fleet/bin/heartbeat.sh"}]}'
UPS_OBJ='{"hooks":[{"type":"command","command":".fleet/bin/awareness.sh"}]}'
SE_OBJ='{"hooks":[{"type":"command","command":".fleet/bin/deregister.sh"}]}'
ALLOW='"Bash(.fleet/bin/fleet.sh:*)"'

_print_settings_block() {
  cat <<EOF
{
  "permissions": { "allow": [ $ALLOW ] },
  "hooks": {
    "SessionStart":     [ $SS_OBJ ],
    "PreToolUse":       [ $PRE_OBJ ],
    "PostToolUse":      [ $POST_OBJ ],
    "UserPromptSubmit": [ $UPS_OBJ ],
    "SessionEnd":       [ $SE_OBJ ]
  }
}
EOF
}

# merge into $1 (existing settings or {}), print merged JSON to stdout.
# CRITICAL: on unparseable input, print NOTHING and return non-zero so cmd_init
# ABORTS without overwriting the user's file. Tries jq (strict JSON, fast); on
# jq failure falls through to python3 which is JSONC-tolerant (strips // and /*
# comments) and aborts safely on genuinely-invalid input.
_merge_settings() {
  local cur="$1" out
  if _have jq; then
    out="$(printf '%s' "$cur" | jq 2>/dev/null \
      --argjson ss "$SS_OBJ" --argjson pre "$PRE_OBJ" --argjson post "$POST_OBJ" --argjson ups "$UPS_OBJ" --argjson se "$SE_OBJ" \
      --arg allow "Bash(.fleet/bin/fleet.sh:*)" '
      def strip(a): (a // []) | map(select(((.hooks // []) | any((.command // "") | contains(".fleet/bin/"))) | not));
      .hooks = (.hooks // {})
      | .hooks.SessionStart    = (strip(.hooks.SessionStart)    + [$ss])
      | .hooks.PreToolUse      = (strip(.hooks.PreToolUse)      + [$pre])
      | .hooks.PostToolUse     = (strip(.hooks.PostToolUse)     + [$post])
      | .hooks.UserPromptSubmit= (strip(.hooks.UserPromptSubmit)+ [$ups])
      | .hooks.SessionEnd      = (strip(.hooks.SessionEnd)      + [$se])
      | .permissions = (.permissions // {})
      | .permissions.allow = ((.permissions.allow // []) as $a | if ($a|index($allow)) then $a else $a + [$allow] end)
    ')" && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if _have python3; then
    printf '%s' "$cur" | python3 -c '
import json,sys
def strip_jsonc(s):
    out=[]; i=0; n=len(s); instr=False; esc=False
    while i<n:
        o=ord(s[i])
        if instr:
            out.append(s[i])
            if esc: esc=False
            elif o==92: esc=True
            elif o==34: instr=False
            i+=1; continue
        if o==34:
            instr=True; out.append(s[i]); i+=1; continue
        if o==47 and i+1<n and ord(s[i+1])==47:
            i+=2
            while i<n and ord(s[i])!=10: i+=1
            continue
        if o==47 and i+1<n and ord(s[i+1])==42:
            i+=2
            while i+1<n and not (ord(s[i])==42 and ord(s[i+1])==47): i+=1
            i+=2; continue
        out.append(s[i]); i+=1
    return "".join(out)
def strip_trailing_commas(s):
    out=[]; i=0; n=len(s); instr=False; esc=False
    while i<n:
        o=ord(s[i])
        if instr:
            out.append(s[i])
            if esc: esc=False
            elif o==92: esc=True
            elif o==34: instr=False
            i+=1; continue
        if o==34: instr=True; out.append(s[i]); i+=1; continue
        if o==44:
            j=i+1
            while j<n and ord(s[j]) in (32,9,13,10): j+=1
            if j<n and (ord(s[j])==125 or ord(s[j])==93):
                i+=1; continue
        out.append(s[i]); i+=1
    return "".join(out)
raw=sys.stdin.read()
if raw.strip()=="":
    d={}
else:
    try:
        d=json.loads(strip_trailing_commas(strip_jsonc(raw)))
    except Exception:
        sys.stderr.write("fleet: existing settings.json is not valid JSON/JSONC; refusing to overwrite.\n")
        sys.exit(2)
if not isinstance(d,dict): d={}
ss={"hooks":[{"type":"command","command":".fleet/bin/register.sh"},{"type":"command","command":".fleet/bin/multiwindow_nudge.sh"},{"type":"command","command":".fleet/bin/wake_nudge.sh"}]}
pre={"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":".fleet/bin/guard.sh"}]}
post={"matcher":"*","hooks":[{"type":"command","command":".fleet/bin/heartbeat.sh"}]}
ups={"hooks":[{"type":"command","command":".fleet/bin/awareness.sh"}]}
se={"hooks":[{"type":"command","command":".fleet/bin/deregister.sh"}]}
allow="Bash(.fleet/bin/fleet.sh:*)"
def strip(a):
    out=[]
    for o in (a or []):
        if any(".fleet/bin/" in (h.get("command","")) for h in o.get("hooks",[])): continue
        out.append(o)
    return out
h=d.get("hooks") or {}
h["SessionStart"]=strip(h.get("SessionStart"))+[ss]
h["PreToolUse"]=strip(h.get("PreToolUse"))+[pre]
h["PostToolUse"]=strip(h.get("PostToolUse"))+[post]
h["UserPromptSubmit"]=strip(h.get("UserPromptSubmit"))+[ups]
h["SessionEnd"]=strip(h.get("SessionEnd"))+[se]
d["hooks"]=h
p=d.get("permissions") or {}
a=p.get("allow") or []
if allow not in a: a=a+[allow]
p["allow"]=a; d["permissions"]=p
print(json.dumps(d,indent=2))
'
    return $?
  fi
  return 3
}

_strip_settings() {
  # remove fleet hook entries + the allow rule; print cleaned JSON.
  # On unparseable input: print NOTHING, return non-zero -> caller skips writing.
  local cur="$1" out
  if _have jq; then
    out="$(printf '%s' "$cur" | jq 2>/dev/null --arg allow "Bash(.fleet/bin/fleet.sh:*)" '
      def strip(a): (a // []) | map(select(((.hooks // []) | any((.command // "") | contains(".fleet/bin/"))) | not));
      if .hooks then .hooks |= ( .SessionStart=strip(.SessionStart) | .PreToolUse=strip(.PreToolUse) | .UserPromptSubmit=strip(.UserPromptSubmit) | .SessionEnd=strip(.SessionEnd) ) else . end
      | if (.permissions|type)=="object" and (.permissions.allow|type)=="array" then .permissions.allow |= map(select(.!=$allow)) else . end
    ')" && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if _have python3; then
    printf '%s' "$cur" | python3 -c '
import json,sys
def strip_jsonc(s):
    out=[]; i=0; n=len(s); instr=False; esc=False
    while i<n:
        o=ord(s[i])
        if instr:
            out.append(s[i])
            if esc: esc=False
            elif o==92: esc=True
            elif o==34: instr=False
            i+=1; continue
        if o==34:
            instr=True; out.append(s[i]); i+=1; continue
        if o==47 and i+1<n and ord(s[i+1])==47:
            i+=2
            while i<n and ord(s[i])!=10: i+=1
            continue
        if o==47 and i+1<n and ord(s[i+1])==42:
            i+=2
            while i+1<n and not (ord(s[i])==42 and ord(s[i+1])==47): i+=1
            i+=2; continue
        out.append(s[i]); i+=1
    return "".join(out)
def strip_trailing_commas(s):
    out=[]; i=0; n=len(s); instr=False; esc=False
    while i<n:
        o=ord(s[i])
        if instr:
            out.append(s[i])
            if esc: esc=False
            elif o==92: esc=True
            elif o==34: instr=False
            i+=1; continue
        if o==34: instr=True; out.append(s[i]); i+=1; continue
        if o==44:
            j=i+1
            while j<n and ord(s[j]) in (32,9,13,10): j+=1
            if j<n and (ord(s[j])==125 or ord(s[j])==93):
                i+=1; continue
        out.append(s[i]); i+=1
    return "".join(out)
raw=sys.stdin.read()
try: d=json.loads(strip_trailing_commas(strip_jsonc(raw))) if raw.strip() else {}
except Exception:
    sys.stderr.write("fleet: settings.json not valid JSON; leaving it untouched.\n"); sys.exit(2)
allow="Bash(.fleet/bin/fleet.sh:*)"
def strip(a):
    return [o for o in (a or []) if not any(".fleet/bin/" in (h.get("command","")) for h in o.get("hooks",[]))]
h=d.get("hooks")
if isinstance(h,dict):
    for k in ("SessionStart","PreToolUse","UserPromptSubmit","SessionEnd"):
        if k in h: h[k]=strip(h.get(k))
p=d.get("permissions")
if isinstance(p,dict) and isinstance(p.get("allow"),list):
    p["allow"]=[x for x in p["allow"] if x!=allow]
print(json.dumps(d,indent=2))
'
    return $?
  fi
  return 3
}

CLAUDE_STANZA() {
  cat <<'EOF'
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

### Wake + messages — do this, it's the one part that isn't automatic

- **First thing each session: ARM your inbox watcher.** Run `.fleet/bin/fleet.sh wake-cmd` and hand its
  printed command to the **Monitor tool** (`persistent: true`, `timeout_ms: 3600000`). This is the ONE
  coordination step a hook physically cannot do for you (a hook can't call the Monitor tool), so it's on
  you — do it before other work. If you skip it, a re-nudge (`⚠ FLEET WAKE NOT ARMED`) fires every turn
  until you do. Once armed, a `msg` to you re-invokes your window to act on it.
- **A FLEET DM is a TASK, not an FYI — ACT on it.** Delivery is guaranteed: whether or not your watcher is
  armed, any unread DM is injected into your context before your next step (arming only changes *latency* —
  it wakes an idle window sooner). So when you see a `[fleet]`/`New messages` block or a `FLEET-PING`: read
  it, DO what it asks (e.g. a coordinator's "rebase", "land-blocked: fix X", or a peer's claim handoff),
  then reply with `.fleet/bin/fleet.sh msg <agent> "<result>"`. Never merely acknowledge and move on — an
  unactioned DM stalls another agent that's waiting on you.
- **See who's reachable:** `.fleet/bin/fleet.sh monitors` classifies every agent MONITORED / UNMONITORED
  (live but won't proactively wake) / CLOSED — use it before you rely on a DM waking someone.

Your identity is auto-detected — just run the commands.
<!-- FLEET:END -->
EOF
}

cmd_init() {
  local dry=0 print_only=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --print-settings) print_only=1 ;;
      --yes|-y) : ;;
    esac
  done

  if [ "$print_only" -eq 1 ]; then _print_settings_block; return 0; fi

  echo "Fleet init -> $PROJECT_ROOT"

  # --- settings.json ---
  local cur merged
  if [ -f "$SETTINGS" ]; then cur="$(cat "$SETTINGS")"; else cur='{}'; fi
  if ! merged="$(_merge_settings "$cur")" || [ -z "$merged" ]; then
    log_err "could not merge settings automatically (need jq or python3)."
    log_err "paste this into $SETTINGS manually:"; _print_settings_block; return 1
  fi

  if [ "$dry" -eq 1 ]; then
    echo "--- would write $SETTINGS ---"
    if _have diff && [ -f "$SETTINGS" ]; then
      printf '%s\n' "$merged" | diff -u "$SETTINGS" - || true
    else
      printf '%s\n' "$merged"
    fi
    echo "--- would append to .gitignore: .fleet/state/ ---"
    echo "--- would add FLEET stanza to CLAUDE.md ---"
    echo "(dry run — nothing written)"
    return 0
  fi

  mkdir -p "$SETTINGS_DIR"
  printf '%s\n' "$merged" > "$SETTINGS.tmp.$$" && mv -f "$SETTINGS.tmp.$$" "$SETTINGS"
  echo "  settings.json: hooks merged (existing hooks preserved)"

  # --- .gitignore ---
  if [ ! -f "$GITIGNORE" ] || ! grep -qxF '.fleet/state/' "$GITIGNORE" 2>/dev/null; then
    printf '\n# Fleet runtime state (per-machine)\n.fleet/state/\n' >> "$GITIGNORE"
    echo "  .gitignore: added .fleet/state/"
  else
    echo "  .gitignore: already ignores .fleet/state/"
  fi

  # --- CLAUDE.md stanza (marker-guarded) ---
  if [ -f "$CLAUDEMD" ] && grep -q 'FLEET:BEGIN' "$CLAUDEMD" 2>/dev/null; then
    awk 'BEGIN{skip=0} /FLEET:BEGIN/{skip=1} skip==0{print} /FLEET:END/{skip=0}' "$CLAUDEMD" > "$CLAUDEMD.tmp.$$"
    { cat "$CLAUDEMD.tmp.$$"; printf '\n'; CLAUDE_STANZA; } > "$CLAUDEMD.tmp2.$$"
    mv -f "$CLAUDEMD.tmp2.$$" "$CLAUDEMD"; rm -f "$CLAUDEMD.tmp.$$"
    echo "  CLAUDE.md: refreshed Fleet stanza"
  else
    if [ -f "$CLAUDEMD" ]; then printf '\n' >> "$CLAUDEMD"; fi
    CLAUDE_STANZA >> "$CLAUDEMD"
    echo "  CLAUDE.md: added Fleet stanza"
  fi

  ensure_state
  chmod +x "$DIR"/*.sh 2>/dev/null || true
  chmod +x "$DIR/goalstack" 2>/dev/null || true

  # --- per-window goalstack: upgrade the global ~/.claude/bin/goalstack in place ONLY when it lacks the per-window
  #     capability (detection-gated — never clobbers a newer/customized one; the re-anchor hook uses the global tool). ---
  GB_GLOBAL="$HOME/.claude/bin/goalstack"
  if [ -f "$DIR/goalstack" ]; then
    if [ ! -f "$GB_GLOBAL" ]; then
      mkdir -p "$HOME/.claude/bin" && cp "$DIR/goalstack" "$GB_GLOBAL" && chmod +x "$GB_GLOBAL"
      echo "  goalstack: installed per-window goalstack → ~/.claude/bin/"
    elif ! grep -q "_window_key" "$GB_GLOBAL" 2>/dev/null; then
      cp "$GB_GLOBAL" "$GB_GLOBAL.pre-fleet.bak" 2>/dev/null
      cp "$DIR/goalstack" "$GB_GLOBAL" && chmod +x "$GB_GLOBAL"
      echo "  goalstack: upgraded ~/.claude/bin/goalstack to per-window (backup: goalstack.pre-fleet.bak)"
    else
      echo "  goalstack: ~/.claude/bin/goalstack already per-window (no change)"
    fi
  fi

  echo
  echo "Done. IMPORTANT: settings.json is read at startup — REOPEN any already-open"
  echo "windows for Fleet to activate. Then open more windows and they coordinate."
}

cmd_uninstall() {
  echo "Fleet uninstall <- $PROJECT_ROOT"
  if [ -f "$SETTINGS" ]; then
    local cleaned; cleaned="$(_strip_settings "$(cat "$SETTINGS")")"
    [ -n "$cleaned" ] && { printf '%s\n' "$cleaned" > "$SETTINGS.tmp.$$" && mv -f "$SETTINGS.tmp.$$" "$SETTINGS"; echo "  settings.json: fleet hooks + allow removed"; }
  fi
  if [ -f "$CLAUDEMD" ] && grep -q 'FLEET:BEGIN' "$CLAUDEMD" 2>/dev/null; then
    awk 'BEGIN{skip=0} /FLEET:BEGIN/{skip=1} skip==0{print} /FLEET:END/{skip=0}' "$CLAUDEMD" > "$CLAUDEMD.tmp.$$" && mv -f "$CLAUDEMD.tmp.$$" "$CLAUDEMD"
    echo "  CLAUDE.md: stanza removed"
  fi
  echo "  (left .gitignore entry and the .fleet/ folder in place; 'rm -rf .fleet' to fully remove)"
}
