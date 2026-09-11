#!/usr/bin/env bash
# adopt.sh — NATIVE reservation adoption for the fleet (Trackboard D-v2 S4b, operator-greenlit).
#
# WHAT: when a Claude session starts (register.sh, the SessionStart hook), if it was launched to fulfil a
# Trackboard "reservation" (a signed request to create/launch an agent with a chosen name/role/mission/model),
# adopt it AUTHORITATIVELY on the real host — seed the agent's identity + mission + host binding, and flip the
# reservation to status=adopted. This is the on-host counterpart to Trackboard's server-side reconcile task
# (which best-effort adopts NAME/ROLE remotely); the native path additionally seeds the mission reliably
# (goalstack runs on the target host, keyed by the real session id) and records the device slug.
#
# WHY IT'S SAFE (indirect-prompt-injection / forgery — the reservations/ dir is shared + on-default-unauthenticated):
# Trackboard signs every reservation it mints with a per-host HMAC key (`.reservation_hmac_key`, hex, 0600).
# adopt_reservation honours ONLY reservations whose `sig` verifies with that key — a hand-dropped forged
# reservation (that would seed a live agent's goalstack) is ignored. Cross-language authenticity is byproduct-
# proven: bash `jq -cS 'del(.sig)'` reproduces Trackboard's canonical (sorted-key, compact) payload EXACTLY and
# `openssl dgst -sha256 -mac HMAC -macopt hexkey:` reproduces the exact signature. After mutating the record we
# RE-SIGN it (we hold the key) so Trackboard's signed-only read path keeps surfacing it as "adopted".
#
# WHY IT NEVER BREAKS A SESSION: fail-OPEN everywhere. Missing jq/openssl, no key (no Trackboard ran on this host),
# no match, an ambiguous cwd match, or a bad signature → a SILENT no-op. register.sh calls this under `trap 'exit 0'
# ERR`; the agent registers exactly as before (the Trackboard reconcile task is the backstop for un-adopted ones).
#
# MULTI-DEVICE: the host slug comes from $FLEET_HOST (an env the launcher/profile passes) — NEVER `hostname`. The
# cwd fallback host-qualifies (a named-device reservation is adopted only on that device; a bare "local" only when
# we can't be attributed elsewhere) so a reservation meant for device A is never silently adopted on device B.
#
# Sourced by register.sh AFTER lib.sh (uses STATE_DIR / now_iso / jstr / short_sid). bash-3.2-safe.
set -u

# _adopt_have_deps — jq (nested read + canonical JSON) and openssl (HMAC) are both required; absent → caller no-ops.
_adopt_have_deps() { command -v jq >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; }

# _adopt_sig_calc <rfile> <keyhex> — the HMAC-SHA256 (hex) over the canonical JSON of the record MINUS `sig`.
# Mirrors Trackboard's _reservation_sig: json.dumps(record-minus-sig, sort_keys=True, separators=(",",":")).
_adopt_sig_calc() {
  local rfile="$1" keyhex="$2" payload
  payload="$(jq -cS 'del(.sig)' "$rfile" 2>/dev/null)" || return 1
  [ -n "$payload" ] || return 1
  printf '%s' "$payload" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$keyhex" 2>/dev/null | awk '{print $NF}'
}

# _adopt_sig_ok <rfile> <keyhex> — does the file's stored `sig` match a freshly-computed one? (authenticity gate)
_adopt_sig_ok() {
  local rfile="$1" keyhex="$2" have want
  want="$(jq -r '.sig // ""' "$rfile" 2>/dev/null)"
  [ -n "$want" ] || return 1
  have="$(_adopt_sig_calc "$rfile" "$keyhex")" || return 1
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# _adopt_candidate_ok <rfile> <cwd> <host_slug> <keyhex> — the full cwd-fallback filter: authentic, adoptable
# status, still unbound, cwd matches, AND host-qualifies. Every clause must hold for a reservation to be a candidate.
_adopt_candidate_ok() {
  local rfile="$1" cwd="$2" host="$3" keyhex="$4" rstatus rbound rcwd rdev
  _adopt_sig_ok "$rfile" "$keyhex" || return 1
  rstatus="$(jq -r '.status // ""' "$rfile" 2>/dev/null)"
  case "$rstatus" in provisioned | launching | launched) : ;; *) return 1 ;; esac
  rbound="$(jq -r '.bound_sid // ""' "$rfile" 2>/dev/null)"
  [ -z "$rbound" ] || [ "$rbound" = "null" ] || return 1
  rcwd="$(jq -r '.target.cwd // ""' "$rfile" 2>/dev/null)"
  [ "$rcwd" = "$cwd" ] || return 1
  rdev="$(jq -r '.target.device // ""' "$rfile" 2>/dev/null)"
  if [ -n "$host" ]; then
    [ "$rdev" = "$host" ] || [ "$rdev" = "local" ] || return 1     # named device must match THIS slug (or bare local)
  else
    [ "$rdev" = "local" ] || return 1                              # no slug → only adopt a device-agnostic "local"
  fi
  return 0
}

# _adopt_write_identity <sid> <display_name> <role> — the name+role overlay Trackboard's roster reads
# (identities/<sid>.json). Same shape as Trackboard's set_agent_identity writer; atomic (tmp + mv).
_adopt_write_identity() {
  local sid="$1" dname="$2" role="$3" dir tmp
  dir="$STATE_DIR/identities"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$dir/$sid.json.tmp.$$"
  {
    printf '{'
    printf '%s,' "$(jstr display_name "$dname")"
    printf '%s,' "$(jstr role "$role")"
    printf '%s' "$(jstr updated_at "$(now_iso)")"
    printf '}\n'
  } >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$dir/$sid.json" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

# _adopt_stamp_reservation <rfile> <sid> <host_slug> <keyhex> — flip the reservation to adopted and RE-SIGN it
# (we hold the key) so Trackboard's signed-only read path keeps surfacing it. bound_host is null when no slug.
_adopt_stamp_reservation() {
  local rfile="$1" sid="$2" host="$3" keyhex="$4" body payload sig tmp now
  now="$(now_iso)"
  body="$(jq -c --arg sid "$sid" --arg host "$host" --arg now "$now" \
    'del(.sig)
     | .bound_sid = $sid
     | .bound_host = (if $host == "" then null else $host end)
     | .adopted_via = "native"
     | .status = "adopted"
     | .updated_at = $now' "$rfile" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  payload="$(printf '%s' "$body" | jq -cS '.' 2>/dev/null)" || return 1
  [ -n "$payload" ] || return 1
  sig="$(printf '%s' "$payload" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$keyhex" 2>/dev/null | awk '{print $NF}')"
  [ -n "$sig" ] || return 1
  tmp="$rfile.tmp.$$"
  printf '%s' "$body" | jq -c --arg sig "$sig" '. + {sig: $sig}' >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$rfile" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

# adopt_reservation <sid> <cwd> — the entrypoint register.sh calls. On a clean, authentic, unambiguous match it
# seeds identity + mission + reservation transition and sets the globals ADOPTED_HOST / ADOPTED_RID (register.sh
# records `host` in the agent file when ADOPTED_HOST is non-empty). Fail-OPEN: any problem → return 0, no mutation.
adopt_reservation() {
  local sid="$1" cwd="$2" rdir keyfile keyhex host_slug rfile
  _adopt_have_deps || return 0
  rdir="$STATE_DIR/reservations"
  keyfile="$STATE_DIR/.reservation_hmac_key"
  [ -d "$rdir" ] || return 0
  [ -f "$keyfile" ] || return 0                                   # no Trackboard server ran here → nothing to adopt
  keyhex="$(tr -d '[:space:]' <"$keyfile" 2>/dev/null)"
  [ -n "$keyhex" ] || return 0
  host_slug="${FLEET_HOST:-}"                                     # device slug from the launcher — NEVER hostname
  rfile=""

  # Path 1 — the exact rid the launcher exported (unambiguous; sidesteps every cwd-collision class). Preferred.
  if [ -n "${FLEET_RESERVATION:-}" ]; then
    local rid
    rid="$(printf '%s' "$FLEET_RESERVATION" | tr -cd 'A-Za-z0-9_')"   # sanitize → path-safe (no traversal)
    [ -n "$rid" ] && [ -f "$rdir/$rid.json" ] && rfile="$rdir/$rid.json"
  fi

  # Path 2 — the newest authentic, unbound, host-qualified reservation whose target.cwd == $cwd.
  # Ambiguity (>1 candidate) → adopt NONE and leave them pending (never silently guess).
  if [ -z "$rfile" ]; then
    local f count newest newest_ts cts
    count=0
    newest=""
    newest_ts=""
    for f in "$rdir"/*.json; do
      [ -f "$f" ] || continue
      _adopt_candidate_ok "$f" "$cwd" "$host_slug" "$keyhex" || continue
      count=$((count + 1))
      cts="$(jq -r '.created_at // ""' "$f" 2>/dev/null)"
      if [ -z "$newest_ts" ] || [[ "$cts" > "$newest_ts" ]]; then
        newest_ts="$cts"
        newest="$f"
      fi
    done
    [ "$count" -eq 1 ] && rfile="$newest" || return 0
  fi

  [ -n "$rfile" ] && [ -f "$rfile" ] || return 0

  # Common gate (authoritative for Path 1, belt-and-suspenders for Path 2): authentic + adoptable + unbound.
  _adopt_sig_ok "$rfile" "$keyhex" || return 0
  local status bound
  status="$(jq -r '.status // ""' "$rfile" 2>/dev/null)"
  case "$status" in provisioned | launching | launched) : ;; *) return 0 ;; esac
  bound="$(jq -r '.bound_sid // ""' "$rfile" 2>/dev/null)"
  [ -z "$bound" ] || [ "$bound" = "null" ] || return 0

  # ── adopt ──────────────────────────────────────────────────────────────────
  local dname role mission
  dname="$(jq -r '.display_name // ""' "$rfile" 2>/dev/null)"
  role="$(jq -r '.role // ""' "$rfile" 2>/dev/null)"
  mission="$(jq -r '.mission // ""' "$rfile" 2>/dev/null)"

  # (a) identity overlay — survives the register/heartbeat rewrite by construction (a separate file).
  _adopt_write_identity "$sid" "$dname" "$role" || return 0
  # (b) mission seed — host-local, window-keyed (the only reliable seed; runs on the target host as this sid).
  if [ -n "$mission" ] && [ "$mission" != "null" ] && command -v goalstack >/dev/null 2>&1; then
    (cd "$cwd" 2>/dev/null && GOALSTACK_WINDOW="$sid" goalstack set "$mission" >/dev/null 2>&1) || true
  fi
  # (c) reservation transition + re-sign (non-fatal: overlay+mission already applied if this hiccups).
  _adopt_stamp_reservation "$rfile" "$sid" "$host_slug" "$keyhex" || true

  # ADOPTED_HOST is an OUTPUT consumed by register.sh (the sourcing caller) to record `host`; not read here.
  # shellcheck disable=SC2034
  ADOPTED_HOST="$host_slug"
  return 0
}
