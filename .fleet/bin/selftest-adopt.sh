#!/usr/bin/env bash
# selftest-adopt.sh — the FORCING FUNCTION for native reservation adoption (Trackboard D-v2 S4b, operator-greenlit).
#
# Proves each guarantee BITES, each with a control that fires (a control that never fires is not a control):
#   B1  a validly-signed, unbound, cwd+host-matching reservation is ADOPTED: identity overlay + reservation flip.
#   B2  the adopted record STILL verifies (re-signed) — Trackboard's signed-only read path keeps surfacing it.
#   B3  the mission is seeded host-locally, window-keyed (goalstack invoked with GOALSTACK_WINDOW=<sid> + the mission).
#   B4  the AUTHENTICITY gate bites: a post-sign-TAMPERED reservation is IGNORED.        control: an untampered twin adopts.
#   B5  AMBIGUITY (>1 cwd candidate) → adopt NONE (never silently guess).
#   B6  $FLEET_RESERVATION disambiguates: the named rid is adopted even amid ambiguity; the sibling stays pending.
#   B7  the STATUS gate bites: a `reserved` (not-yet-provisioned) reservation is NOT adopted.
#   B8  the HOST qualifier bites: a named-device reservation is NOT adopted without a matching $FLEET_HOST slug.  control: matching slug adopts + records bound_host.
#   B9  BACK-COMPAT: register.sh with no matching reservation writes an agent file byte-identical to the pre-S4b
#       baseline (no `host` key, 9 fields); with an adopted reservation it gains exactly `host` (10 fields).
#
# Hermetic: a temp STATE_DIR + a temp HMAC key + a mock `goalstack` on PATH exercise the REAL adopt.sh (and the REAL
# register.sh) end to end; the live fleet + the operator's goalstack are never touched. Reservations are minted with
# the SAME canonical `jq -cS` + `openssl` HMAC that Trackboard uses (cross-language byproduct-proven), so a green run
# means adopt.sh honours exactly the records Trackboard mints. Exit 0 = every guarantee bit; non-zero = a regression.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok=1
fail() { echo "  ✗ $1"; ok=0; }
pass() { echo "  ✓ $1"; }

echo "═══ selftest: native reservation adoption (Trackboard D-v2 S4b) ═══"

if ! command -v jq >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  echo "  ⚠ jq/openssl unavailable — adoption is a no-op on such a host; selftest cannot run. SKIP (not a fail)."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT
(
  export FLEET_STATE_DIR="$tmp/state"
  # shellcheck source=lib.sh
  . "$DIR/lib.sh" 2>/dev/null
  # shellcheck source=adopt.sh
  . "$DIR/adopt.sh" 2>/dev/null
  export STATE_DIR="$tmp/state"          # adopt.sh + register.sh read this (git-common-resolved in prod)
  RDIR="$STATE_DIR/reservations"
  mkdir -p "$RDIR" "$STATE_DIR/agents" "$STATE_DIR/identities"
  KEYHEX="$(openssl rand -hex 32)"
  printf '%s' "$KEYHEX" > "$STATE_DIR/.reservation_hmac_key"

  # mock goalstack — records the window + args so B3 can assert the mission seed without the real tool (absent in CI).
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/goalstack" <<'EOF'
#!/usr/bin/env bash
printf 'WINDOW=%s ARGS=%s\n' "${GOALSTACK_WINDOW:-}" "$*" >> "$GOALSTACK_LOG"
EOF
  chmod +x "$tmp/bin/goalstack"
  export PATH="$tmp/bin:$PATH"
  export GOALSTACK_LOG="$tmp/gs.log"
  : > "$GOALSTACK_LOG"

  # _mint <rid> <cwd> <device> <status> <mission> <name> <role> — writes a SIGNED reservation (Trackboard's shape).
  _mint() {
    local rid="$1" cwd="$2" dev="$3" st="$4" m="$5" nm="$6" rl="$7" f body payload sig now
    f="$RDIR/$rid.json"; now="$(now_iso)"
    body="$(jq -cn --arg rid "$rid" --arg cwd "$cwd" --arg dev "$dev" --arg st "$st" \
      --arg m "$m" --arg nm "$nm" --arg rl "$rl" --arg now "$now" '
      {rid:$rid, schema:2, display_name:$nm, role:$rl, mission:$m, model:"opus", reasoning_effort:"high",
       target:{device:$dev, kind:"new", name:"wt", cwd:$cwd},
       status:$st, bound_sid:null, bound_host:null, adopted_via:null,
       launch:{attempt_at:null, launched_at:null, mechanism:null, client_ip:null, result:null, model_applied:false},
       created_at:$now, updated_at:$now, expires_at:"2999-01-01T00:00:00Z"}')"
    payload="$(printf '%s' "$body" | jq -cS '.')"
    sig="$(printf '%s' "$payload" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$KEYHEX" 2>/dev/null | awk '{print $NF}')"
    printf '%s' "$body" | jq -c --arg sig "$sig" '. + {sig:$sig}' > "$f"
  }
  rstat() { jq -r '.status // ""' "$RDIR/$1.json" 2>/dev/null; }
  unset FLEET_RESERVATION FLEET_HOST 2>/dev/null || true

  # ── B1 + B2 + B3: happy-path adopt, re-sign integrity, mission seed ─────────────────────────────
  C1="$tmp/w1"; mkdir -p "$C1"; S1="adoptselftestsid001"
  _mint rsv_b1 "$C1" local provisioned "seed the crew UI" "Aurora" "Backend"
  adopt_reservation "$S1" "$C1"
  ov="$STATE_DIR/identities/$S1.json"
  { [ -f "$ov" ] && [ "$(jq -r .display_name "$ov")" = "Aurora" ] && [ "$(jq -r .role "$ov")" = "Backend" ]; } \
    && pass "B1: identity overlay written with the reservation's name+role" \
    || fail "B1: overlay missing/wrong (file=$ov)"
  { [ "$(rstat rsv_b1)" = "adopted" ] && [ "$(jq -r .bound_sid "$RDIR/rsv_b1.json")" = "$S1" ] \
      && [ "$(jq -r .adopted_via "$RDIR/rsv_b1.json")" = "native" ]; } \
    && pass "B1: reservation flipped to adopted (bound_sid=<sid>, adopted_via=native)" \
    || fail "B1: reservation not transitioned (status=$(rstat rsv_b1))"
  _adopt_sig_ok "$RDIR/rsv_b1.json" "$KEYHEX" \
    && pass "B2: the adopted record is RE-SIGNED and verifies (read path keeps surfacing it)" \
    || fail "B2: adopted record's signature does NOT verify — Trackboard would drop it"
  { grep -q "WINDOW=$S1" "$GOALSTACK_LOG" && grep -q "seed the crew UI" "$GOALSTACK_LOG" && grep -q "set" "$GOALSTACK_LOG"; } \
    && pass "B3: mission seeded via goalstack (GOALSTACK_WINDOW=<sid> set '<mission>')" \
    || fail "B3: mission was not seeded window-keyed (log: $(cat "$GOALSTACK_LOG" 2>/dev/null))"

  # ── B4: authenticity gate — a post-sign TAMPERED reservation is ignored (control: an untampered twin adopts) ──
  Cpos="$tmp/wpos"; mkdir -p "$Cpos"
  _mint rsv_pos "$Cpos" local provisioned "ok" "Nova" "Ops"
  adopt_reservation "ctlpossid000001" "$Cpos"
  [ "$(rstat rsv_pos)" = "adopted" ] && pass "B4 control: an untampered validly-signed reservation adopts" \
                                     || fail "B4 control: a valid reservation failed to adopt"
  Cneg="$tmp/wneg"; mkdir -p "$Cneg"
  _mint rsv_neg "$Cneg" local provisioned "ok" "Nova" "Ops"
  jq '.role="TAMPERED"' "$RDIR/rsv_neg.json" > "$RDIR/rsv_neg.tmp" && mv "$RDIR/rsv_neg.tmp" "$RDIR/rsv_neg.json"  # break the sig
  adopt_reservation "ctlnegsid000001" "$Cneg"
  { [ "$(rstat rsv_neg)" = "provisioned" ] && [ ! -f "$STATE_DIR/identities/ctlnegsid000001.json" ]; } \
    && pass "B4: a post-sign TAMPERED (forged) reservation is IGNORED (authenticity gate bites)" \
    || fail "B4: a tampered reservation was adopted — forgery gate did NOT bite (status=$(rstat rsv_neg))"

  # ── B5: ambiguity (>1 candidate for one cwd) → adopt NONE ───────────────────────────────────────
  Ca="$tmp/wambi"; mkdir -p "$Ca"
  _mint rsv_ambi1 "$Ca" local provisioned "m1" "A1" "R1"
  _mint rsv_ambi2 "$Ca" local provisioned "m2" "A2" "R2"
  unset FLEET_RESERVATION 2>/dev/null || true
  adopt_reservation "ambisid00000001" "$Ca"
  { [ "$(rstat rsv_ambi1)" = "provisioned" ] && [ "$(rstat rsv_ambi2)" = "provisioned" ] \
      && [ ! -f "$STATE_DIR/identities/ambisid00000001.json" ]; } \
    && pass "B5: ambiguous cwd match adopts NONE (both left pending — never a silent guess)" \
    || fail "B5: an ambiguous match was adopted (ambi1=$(rstat rsv_ambi1) ambi2=$(rstat rsv_ambi2))"

  # ── B6: $FLEET_RESERVATION disambiguates (the named rid adopts; the sibling stays pending) ───────
  export FLEET_RESERVATION="rsv_ambi2"
  adopt_reservation "ambisid00000002" "$Ca"
  { [ "$(rstat rsv_ambi2)" = "adopted" ] && [ "$(jq -r .bound_sid "$RDIR/rsv_ambi2.json")" = "ambisid00000002" ] \
      && [ "$(rstat rsv_ambi1)" = "provisioned" ]; } \
    && pass "B6: \$FLEET_RESERVATION adopts the named rid amid ambiguity; the sibling stays pending" \
    || fail "B6: env-named adoption wrong (ambi2=$(rstat rsv_ambi2) ambi1=$(rstat rsv_ambi1))"
  unset FLEET_RESERVATION 2>/dev/null || true

  # ── B7: status gate — a `reserved` (not-yet-provisioned) reservation is NOT adopted ─────────────
  Cr="$tmp/wresv"; mkdir -p "$Cr"
  _mint rsv_resv "$Cr" local reserved "m" "N" "R"
  adopt_reservation "resvsid00000001" "$Cr"
  { [ "$(rstat rsv_resv)" = "reserved" ] && [ ! -f "$STATE_DIR/identities/resvsid00000001.json" ]; } \
    && pass "B7: a 'reserved' (un-provisioned) reservation is NOT adopted (status gate bites)" \
    || fail "B7: a 'reserved' reservation was adopted (status=$(rstat rsv_resv))"

  # ── B8: host qualifier — a named-device reservation needs a matching $FLEET_HOST slug ───────────
  Ch="$tmp/whost"; mkdir -p "$Ch"
  _mint rsv_host "$Ch" node-beta provisioned "m" "N" "R"
  unset FLEET_HOST 2>/dev/null || true
  adopt_reservation "hostsid00000001" "$Ch"
  [ "$(rstat rsv_host)" = "provisioned" ] \
    && pass "B8: a named-device reservation is NOT adopted without a matching \$FLEET_HOST (qualifier bites)" \
    || fail "B8: a named-device reservation was adopted on an unknown host (status=$(rstat rsv_host))"
  export FLEET_HOST="node-beta"
  adopt_reservation "hostsid00000002" "$Ch"
  { [ "$(rstat rsv_host)" = "adopted" ] && [ "$(jq -r .bound_host "$RDIR/rsv_host.json")" = "node-beta" ]; } \
    && pass "B8 control: with a matching \$FLEET_HOST the reservation adopts + records bound_host" \
    || fail "B8 control: a slug-matching reservation failed to adopt (status=$(rstat rsv_host))"
  unset FLEET_HOST 2>/dev/null || true

  # ── B9: back-compat — register.sh with no reservation == pre-S4b baseline (no host); with one, gains host ──
  reg="$DIR/register.sh"
  Cbase="$tmp/wbase"; mkdir -p "$Cbase"       # no reservation for this cwd
  jq -cn --arg cwd "$Cbase" '{session_id:"bcsidbaseline0001",source:"startup",cwd:$cwd,model:"opus"}' \
    | FLEET_STATE_DIR="$STATE_DIR" bash "$reg" >/dev/null 2>&1
  bf="$STATE_DIR/agents/bcsidbaseline0001.json"
  { [ -f "$bf" ] && jq -e 'has("host")|not' "$bf" >/dev/null && [ "$(jq -r 'keys|length' "$bf")" = "9" ]; } \
    && pass "B9: no-reservation agent file is byte-compatible with the baseline (no host key, 9 fields)" \
    || fail "B9: baseline agent file drifted (host present or field count != 9)"
  Cw="$tmp/wbcadopt"; mkdir -p "$Cw"
  _mint rsv_bc "$Cw" local provisioned "m" "Byte" "Compat"
  jq -cn --arg cwd "$Cw" '{session_id:"bcsidadopted0002",source:"startup",cwd:$cwd,model:"opus"}' \
    | FLEET_STATE_DIR="$STATE_DIR" FLEET_HOST="node-x" bash "$reg" >/dev/null 2>&1
  af="$STATE_DIR/agents/bcsidadopted0002.json"
  { [ -f "$af" ] && [ "$(jq -r '.host // ""' "$af")" = "node-x" ] && [ "$(jq -r 'keys|length' "$af")" = "10" ]; } \
    && pass "B9 control: an adopted agent file gains exactly the host field (node-x, 10 fields)" \
    || fail "B9 control: adopted agent file missing host (host=$(jq -r '.host // "∅"' "$af" 2>/dev/null))"

  [ "$ok" = 1 ]
) || ok=0

[ "$ok" = 1 ] && { echo "selftest-adopt: OK — signed reservations adopt (identity+mission+host), forgeries/ambiguity/wrong-host are refused, back-compat holds"; exit 0; }
echo "selftest-adopt: FAIL — native adoption regressed"; exit 1
