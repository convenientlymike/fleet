#!/usr/bin/env bash
# brain-retire.sh — two Fleet subcommands, lazy-sourced by fleet.sh (so the hot path stays lean):
#   • retire — the SAFE, on-demand, any-agent sibling of the SessionEnd deregister.sh hook.
#   • brain  — the fleet BRAIN: a memory-corpus oracle (CLI) + a router to the persistent Brain AGENT.
# Sourced INTO fleet.sh's shell AFTER lib.sh + the cmd_* helpers, so every lib helper (agent_file, _release_claims_of,
# _claim_path_dirty, board_event, sid_for_target, unread_count, is_live, jstr, now_iso …) and cmd_msg are in scope.
# MUST stay bash 3.2-safe (no assoc arrays / mapfile / ${var^^}), matching lib.sh.

# ===========================================================================
# retire — safely deregister an agent (default: self)
# ===========================================================================
# Usage: fleet.sh retire [<agent-N|short|sid>] [--force] [--reason "<why>"]
# Safe-by-default: REFUSES if the target holds a claim over UNCOMMITTED (dirty) work, or (for a NON-self target)
# has unread DMs that would be stranded — unless --force. Then: releases claims, removes the agent record + wake
# breadcrumb, clears the Brain registry if the retiree was the Brain, emits a `retire` board event. A --force retire
# PRESERVES a non-empty unread inbox (durable-handoff parity with deregister.sh) so wake-dispatcher can still resume it.
cmd_retire() {
  local target="" force=0 reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)        force=1 ;;
      --reason)       shift; reason="${1:-}" ;;
      --reason=*)     reason="${1#--reason=}" ;;
      -h|--help)      printf 'usage: fleet.sh retire [<agent-N|short|sid>] [--force] [--reason "<why>"]\n'; return 0 ;;
      -*)             log_err "retire: unknown flag '$1'"; return 2 ;;
      *)              target="$1" ;;
    esac
    shift || true
  done

  local sid
  if [ -z "$target" ]; then
    sid="${SELF_SID:-}"
    [ -z "$sid" ] && { log_err "retire: no session identity — pass a target or --id <sid>"; return 2; }
  else
    sid="$(sid_for_target "$target")" || { log_err "retire: unknown agent '$target' (see: fleet.sh roster)"; return 2; }
  fi

  ensure_state
  local f label short is_self=0
  f="$(agent_file "$sid")"; label="$(json_field_file "$f" agent)"; short="$(short_sid "$sid")"
  [ -z "$label" ] && label="$short"
  [ "$sid" = "${SELF_SID:-}" ] && is_self=1

  # SAFETY 1 — a claim over UNCOMMITTED work is live work, not an orphan (the C0b invariant). Never silently drop it.
  local dirty="" d meta p
  for d in "$CLAIMS_DIR"/*.lock; do
    [ -d "$d" ] || continue; meta="$d/meta.json"; [ -f "$meta" ] || continue
    [ "$(json_field_file "$meta" owner_session_id)" = "$sid" ] || continue
    if _claim_path_dirty "$meta"; then p="$(json_field_file "$meta" path)"; dirty="$dirty $p"; fi
  done
  if [ -n "$dirty" ] && [ "$force" -eq 0 ]; then
    log_err "retire REFUSED: $label holds claim(s) over UNCOMMITTED work:$dirty"
    log_err "  commit or discard that work first, then retire — or --force to release the claims anyway (risky)."
    return 1
  fi

  # SAFETY 2 — unread DMs would be stranded. For a FOREIGN target, refuse without --force; for self you've read them.
  local unread; unread="$(unread_count "$sid")"
  if [ "$unread" -gt 0 ] && [ "$is_self" -eq 0 ] && [ "$force" -eq 0 ]; then
    log_err "retire REFUSED: $label has $unread unread DM(s) — retiring it would strand them."
    log_err "  let it process its inbox, or --force (its inbox is preserved so wake-dispatcher can resume it)."
    return 1
  fi

  # release claims. _release_claims_of KEEPS a dirty-covering claim (C0b); with --force we then drop the remainder.
  _release_claims_of "$sid"
  if [ "$force" -eq 1 ]; then
    for d in "$CLAIMS_DIR"/*.lock; do
      [ -d "$d" ] || continue; meta="$d/meta.json"; [ -f "$meta" ] || continue
      [ "$(json_field_file "$meta" owner_session_id)" = "$sid" ] && rm -rf "$d" 2>/dev/null || true
    done
  fi

  rm -f "$STATE_DIR/wake/$sid.monitor" 2>/dev/null || true
  local extra note=""
  if [ "$unread" -gt 0 ]; then
    note="; $unread unread DM(s) preserved"          # keep the inbox (durable handoff) — remove only the record
    rm -f "$f" 2>/dev/null || true
    extra="$(jstr reason "${reason:-retired}"),$(jstr note "$unread unread DM(s) preserved for wake-dispatcher")"
  else
    rm -f "$f" "$INBOX_DIR/$sid.jsonl" "$INBOX_DIR/$sid.seen" 2>/dev/null || true
    extra="$(jstr reason "${reason:-retired}")"
  fi
  board_event retire "$label" "$short" "$extra"

  # if the retiree was the Brain, vacate the seat so `brain ask` stops routing to a dead agent.
  if [ -f "$STATE_DIR/brain.json" ] && [ "$(json_field_file "$STATE_DIR/brain.json" sid)" = "$sid" ]; then
    rm -f "$STATE_DIR/brain.json" 2>/dev/null || true; note="$note; vacated the Brain seat"
  fi

  printf 'retired %s (%s)%s. claims released; record removed%s.\n' \
    "$label" "$short" "$( [ -n "$reason" ] && printf ' — %s' "$reason" )" "$note"
  [ "$is_self" -eq 1 ] && printf 'note: this was YOU — stop your Monitor watcher (TaskStop) and let the session close.\n'
  return 0
}

# ===========================================================================
# brain — the fleet knowledge oracle (CLI) + router to the Brain AGENT
# ===========================================================================
# Usage:
#   fleet.sh brain <query>          instant answer from the memory corpus (fleet-memory search + citations)
#   fleet.sh brain ask <query>      route a DEEP-research question to the Brain agent (DM); CLI fallback if none
#   fleet.sh brain serve            register THIS session as the Brain agent
#   fleet.sh brain stand-down       vacate the Brain seat (only the holder may)
#   fleet.sh brain who              show the current Brain agent
BRAIN_REG_FILE() { printf '%s/brain.json' "$STATE_DIR"; }

cmd_brain() {
  local sub="${1:-}"
  case "$sub" in
    ""|-h|--help|help)
      cat <<'EOF'
fleet.sh brain <query>          ask the fleet BRAIN — instant memory-corpus answer (fleet-memory search + citations)
fleet.sh brain ask <query>      route a DEEP-research question to the Brain agent (memory + web + scrape + synthesis)
fleet.sh brain serve            register THIS session as the Brain agent (run /brain to become it properly)
fleet.sh brain stand-down       vacate the Brain seat
fleet.sh brain who              show the current Brain agent
EOF
      return 0 ;;
    serve)                require_id; _brain_serve ;;
    stand-down|standdown) require_id; _brain_standdown ;;
    who)                  _brain_who ;;
    ask)                  shift; require_id; _brain_ask "$*" ;;
    *)                    _brain_query "$*" ;;
  esac
}

_brain_who() {
  local reg; reg="$(BRAIN_REG_FILE)"
  [ -f "$reg" ] || { echo "no Brain agent registered. Run 'fleet.sh brain serve' (or /brain) to become it; 'fleet.sh brain <q>' works standalone."; return 0; }
  local bsid blabel bsince; bsid="$(json_field_file "$reg" sid)"; blabel="$(json_field_file "$reg" label)"; bsince="$(json_field_file "$reg" since)"
  if is_live "$bsid"; then
    echo "Brain: ${blabel:-?} ($(short_sid "$bsid")) — LIVE, since $bsince"
  else
    echo "Brain: ${blabel:-?} ($(short_sid "$bsid")) — registered but not live (since $bsince); 'brain ask' still queues to its inbox."
  fi
}

_brain_serve() {
  ensure_self_registered "$SELF_SID"
  local label reg tmp; label="$(self_label "$SELF_SID")"; reg="$(BRAIN_REG_FILE)"; tmp="$reg.tmp.$$"
  printf '{%s,%s,%s}\n' "$(jstr sid "$SELF_SID")" "$(jstr label "$label")" "$(jstr since "$(now_iso)")" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$reg" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; log_err "brain serve: could not write $reg"; return 1; }
  board_event brain-serve "$label" "$(short_sid "$SELF_SID")" ""
  echo "🧠 $label is now the fleet BRAIN. Agents reach you via:  fleet.sh brain ask \"<question>\""
  echo "   Next: arm your inbox (/arm) so BRAIN-ASK DMs wake you; answer with fleet-memory + web research; persist findings."
}

_brain_standdown() {
  local reg; reg="$(BRAIN_REG_FILE)"
  [ -f "$reg" ] || { echo "no Brain registered."; return 0; }
  local bsid; bsid="$(json_field_file "$reg" sid)"
  [ "$bsid" = "$SELF_SID" ] || { log_err "brain stand-down: you are not the registered Brain (held by $(short_sid "$bsid"))."; return 1; }
  rm -f "$reg" 2>/dev/null
  board_event brain-standdown "$(self_label "$SELF_SID")" "$(short_sid "$SELF_SID")" ""
  echo "stood down as Brain."
}

# _brain_query <query…> — the CLI oracle: search the curated memory corpus + cite. Delegates to fleet-memory (the
# hub-owned search over all tiers). Read-only; no identity needed.
_brain_query() {
  local q="$*"
  [ -z "$q" ] && { log_err 'usage: fleet.sh brain "<query>"'; return 2; }
  if command -v fleet-memory >/dev/null 2>&1; then
    printf '🧠 BRAIN — memory corpus for: %s\n\n' "$q"
    fleet-memory search "$q" 2>&1
    printf '\nDeep research (memory + web + scrape + synthesis) → route to the Brain agent:  fleet.sh brain ask "%s"\n' "$q"
    return 0
  fi
  log_err "brain: fleet-memory not on PATH — corpus search unavailable (is ~/.claude/bin on PATH?)"; return 1
}

# _brain_ask <question…> — route a deep-research question to the Brain agent via DM (a BRAIN-ASK envelope it
# recognizes). Falls back to the CLI oracle if no Brain is registered or if YOU are the Brain.
_brain_ask() {
  local q="$*"; local reg; reg="$(BRAIN_REG_FILE)"
  [ -z "$q" ] && { log_err 'usage: fleet.sh brain ask "<question>"'; return 2; }
  if [ ! -f "$reg" ]; then
    echo "(no Brain agent registered — answering from the corpus directly)"; echo
    _brain_query "$q"; return 0
  fi
  local bsid blabel; bsid="$(json_field_file "$reg" sid)"; blabel="$(json_field_file "$reg" label)"
  if [ "$bsid" = "$SELF_SID" ]; then echo "you ARE the Brain — answer it (try: fleet.sh brain \"$q\")."; return 0; fi
  cmd_msg "$bsid" "BRAIN-ASK from $(self_label "$SELF_SID"): $q"
  echo "routed to the Brain (${blabel:-$(short_sid "$bsid")}); it will answer via DM. Instant corpus hits meanwhile:  fleet.sh brain \"$q\""
}
