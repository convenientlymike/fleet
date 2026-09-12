#!/usr/bin/env bash
# selftest-adopt.sh — the FORCING FUNCTION for trackboard native reservation adoption (design §D.4 Path 1).
#
# adopt_reservation runs in register.sh (a SessionStart hook on EVERY window), so two properties are load-bearing:
# it must adopt the RIGHT reservation (and only a signature-verified, host-qualified, unambiguous one), and it must
# NEVER disturb a normal (non-adopting) registration — the agent file stays byte-identical to the pre-feature
# baseline. Each guarantee is proved to BITE, each paired with a control that fires (a control that never fires is
# not a control):
#   A1  explicit-rid ($FLEET_RESERVATION) adoption WRITES all four artifacts — name/role overlay, window-keyed
#       goalstack mission seed, reservation stamp (adopted/bound_sid/adopted_via=native/host), and a still-VALID
#       re-signed sig (proves the re-sign matches trackboard's canonicalization — anti-drift bite).
#   A2  BACK-COMPAT: with NO matching reservation, the REAL register.sh writes an agent file with NO `host` key
#       (byte-identical baseline). control: WITH a reservation, the same register.sh path DOES add `host`.
#   A3  cwd+device FALLBACK adopts exactly-one; AMBIGUITY (2 matches) adopts NONE. control: exactly-one is adopted
#       (the fallback is not over-blocked).
#   A4  AUTHENTICITY: a forged/unsigned reservation is IGNORED. control: the same record, validly signed, IS adopted.
#   A5  HOST QUALIFIER: a reservation for a DIFFERENT device is never cwd-bound. control: the matching device is.
#
# Hermetic: a throwaway FLEET_STATE_DIR + a stub `goalstack` on PATH exercise the REAL lib.sh / register.sh code;
# the live fleet + the real goalstack store are never touched. Exit 0 = every guarantee bit + no false-positive.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok=1
fail() { echo "  ✗ $1"; ok=0; }
pass() { echo "  ✓ $1"; }

echo "═══ selftest: trackboard native reservation adoption ═══"

if ! command -v python3 >/dev/null 2>&1; then
  echo "selftest-adopt: SKIP — python3 unavailable (sig verify/mint is python3-only; the runtime fail-closes)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT

# stub goalstack on PATH — records (window, args) so we can prove the window-keyed mission seed fired.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/goalstack" <<'EOF'
#!/usr/bin/env bash
printf 'WINDOW=%s ARGS=%s\n' "${GOALSTACK_WINDOW:-}" "$*" >> "$GOALSTACK_LOG"
EOF
chmod +x "$tmp/bin/goalstack"

(
  export FLEET_STATE_DIR="$tmp/state"
  export PATH="$tmp/bin:$PATH"
  export GOALSTACK_LOG="$tmp/goalstack.log"
  # shellcheck source=lib.sh
  . "$DIR/lib.sh" 2>/dev/null            # _fleet_resolve_state honors FLEET_STATE_DIR → all dirs sandboxed
  export PROJECT_ROOT="$tmp"
  CONFIG_FILE="$tmp/config.json"; printf '{"stale_after_s":900,"agent_gc_s":86400}\n' > "$CONFIG_FILE"
  ensure_state
  mkdir -p "$RESERVATIONS_DIR" "$IDENTITIES_DIR"

  # a persistent HMAC key (survives across the whole run, like trackboard's on-disk key).
  head -c 32 /dev/urandom > "$STATE_DIR/.reservation_hmac_key" 2>/dev/null
  chmod 600 "$STATE_DIR/.reservation_hmac_key" 2>/dev/null || true

  CWD="$tmp/work/proj"; SLUG="mini"; mkdir -p "$CWD"   # a REAL cwd — the mission seed cd's into it (a stale
  #                                                       worktree path would correctly short-circuit the seed)

  # mk_res <rid> <cwd> <device> <status> <name> <role> <mission> [signed|unsigned]
  mk_res() {
    RID="$1" RCWD="$2" RDEV="$3" RST="$4" RNAME="$5" RROLE="$6" RMIS="$7" RMODE="${8:-signed}" \
    RKEY="$STATE_DIR/.reservation_hmac_key" ROUT="$RESERVATIONS_DIR/$1.json" python3 - <<'PY'
import json, os, hmac, hashlib
r = {"rid": os.environ["RID"], "schema": 2, "status": os.environ["RST"],
     "display_name": os.environ["RNAME"], "role": os.environ["RROLE"],
     "mission": (os.environ["RMIS"] or None), "model": "opus", "reasoning_effort": "high",
     "target": {"device": os.environ["RDEV"], "kind": "new", "name": "wt", "cwd": os.environ["RCWD"]},
     "bound_sid": None, "bound_host": None, "adopted_via": None,
     "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
     "expires_at": "2099-01-01T00:00:00Z"}
key = open(os.environ["RKEY"], "rb").read()
payload = json.dumps(r, sort_keys=True, separators=(",", ":"))
sig = hmac.new(key, payload.encode(), hashlib.sha256).hexdigest()
if os.environ["RMODE"] == "unsigned":
    sig = "0" * 64                       # a wrong sig → the authenticity gate must reject it
r["sig"] = sig
open(os.environ["ROUT"], "w").write(json.dumps(r, ensure_ascii=False))
PY
  }
  reset_res() { rm -f "$RESERVATIONS_DIR"/*.json "$IDENTITIES_DIR"/*.json "$GOALSTACK_LOG" 2>/dev/null || true; }

  # ── A1: explicit-rid adoption writes all four artifacts (+ a valid re-sign) ─────────────────────────────────
  reset_res
  mk_res r_a1 "$CWD" "$SLUG" provisioned "Ada" "Backend" "ship the API"
  ( export TRACKBOARD_DEVICE_SLUG="$SLUG" FLEET_RESERVATION="r_a1"; adopt_reservation "sid-a1-xyz" "$CWD" )
  [ "$(json_field_file "$IDENTITIES_DIR/sid-a1-xyz.json" display_name)" = "Ada" ] \
    && [ "$(json_field_file "$IDENTITIES_DIR/sid-a1-xyz.json" role)" = "Backend" ] \
    && pass "A1: identities overlay carries the reservation's name + role" \
    || fail "A1: identities overlay missing/incorrect"
  grep -q 'WINDOW=sid-a1-xyz ARGS=set ship the API' "$GOALSTACK_LOG" 2>/dev/null \
    && pass "A1: mission seeded into the WINDOW-KEYED goalstack (window=sid, args=set <mission>)" \
    || fail "A1: window-keyed goalstack mission seed did not fire"
  [ "$(json_field_file "$RESERVATIONS_DIR/r_a1.json" status)" = "adopted" ] \
    && [ "$(json_field_file "$RESERVATIONS_DIR/r_a1.json" bound_sid)" = "sid-a1-xyz" ] \
    && [ "$(json_field_file "$RESERVATIONS_DIR/r_a1.json" adopted_via)" = "native" ] \
    && [ "$(json_field_file "$RESERVATIONS_DIR/r_a1.json" bound_host)" = "$SLUG" ] \
    && pass "A1: reservation stamped adopted/bound_sid/adopted_via=native/bound_host" \
    || fail "A1: reservation adoption stamp incorrect"
  _reservation_sig_ok "$RESERVATIONS_DIR/r_a1.json" \
    && pass "A1: the re-signed reservation still verifies (re-sign matches trackboard canonicalization)" \
    || fail "A1: re-signed reservation FAILS sig verify — canonicalization drift vs trackboard _reservation_sig"

  # ── A2: back-compat — the REAL register.sh adds `host` IFF a reservation is adopted ──────────────────────────
  reset_res
  base_sid="sid-base-0001"
  printf '{"session_id":"%s","cwd":"%s","source":"resume","model":"opus"}' "$base_sid" "$CWD" \
    | FLEET_STATE_DIR="$STATE_DIR" PATH="$tmp/bin:$PATH" bash "$DIR/register.sh"
  if grep -q '"host"' "$AGENTS_DIR/$base_sid.json" 2>/dev/null; then
    fail "A2: a NON-adopting registration wrote a host field — NOT byte-identical to the baseline"
  else
    pass "A2: a NON-adopting registration writes NO host field (byte-identical to the pre-feature baseline)"
  fi
  reset_res
  adopt_sid="sid-adopt-0002"
  mk_res r_a2 "$CWD" "$SLUG" provisioned "Bo" "Frontend" ""
  printf '{"session_id":"%s","cwd":"%s","source":"resume","model":"opus"}' "$adopt_sid" "$CWD" \
    | FLEET_STATE_DIR="$STATE_DIR" TRACKBOARD_DEVICE_SLUG="$SLUG" FLEET_RESERVATION="r_a2" PATH="$tmp/bin:$PATH" bash "$DIR/register.sh"
  [ "$(json_field_file "$AGENTS_DIR/$adopt_sid.json" host)" = "$SLUG" ] \
    && pass "A2 control: an ADOPTING registration DOES add host=<slug> (the write-block change bites only on adopt)" \
    || fail "A2 control: an adopting registration did not add the host field"

  # ── A3: cwd+device fallback — exactly-one adopts, ambiguity adopts NONE ──────────────────────────────────────
  reset_res
  mk_res r_dup1 "$CWD" "$SLUG" provisioned "X" "Backend" ""
  mk_res r_dup2 "$CWD" "$SLUG" provisioned "Y" "Backend" ""   # a 2nd match for the SAME cwd+device
  ( export TRACKBOARD_DEVICE_SLUG="$SLUG"; adopt_reservation "sid-ambig" "$CWD" )   # no FLEET_RESERVATION
  { [ ! -f "$IDENTITIES_DIR/sid-ambig.json" ] \
    && [ "$(json_field_file "$RESERVATIONS_DIR/r_dup1.json" status)" = "provisioned" ] \
    && [ "$(json_field_file "$RESERVATIONS_DIR/r_dup2.json" status)" = "provisioned" ]; } \
    && pass "A3: AMBIGUOUS cwd+device (2 matches) adopts NONE — leaves both pending (fail loud, never guess)" \
    || fail "A3: ambiguity silently bound one — the no-guess policy regressed"
  reset_res
  mk_res r_one "$CWD" "$SLUG" provisioned "Solo" "Backend" ""
  ( export TRACKBOARD_DEVICE_SLUG="$SLUG"; adopt_reservation "sid-one" "$CWD" )
  [ "$(json_field_file "$RESERVATIONS_DIR/r_one.json" bound_sid)" = "sid-one" ] \
    && pass "A3 control: EXACTLY-ONE cwd+device match IS adopted (fallback not over-blocked)" \
    || fail "A3 control: a single unambiguous fallback match was not adopted"

  # ── A4: authenticity — a forged sig is ignored; a valid sig is adopted ──────────────────────────────────────
  reset_res
  mk_res r_forged "$CWD" "$SLUG" provisioned "Mallory" "Backend" "" unsigned
  ( export TRACKBOARD_DEVICE_SLUG="$SLUG" FLEET_RESERVATION="r_forged"; adopt_reservation "sid-forged" "$CWD" )
  { [ ! -f "$IDENTITIES_DIR/sid-forged.json" ] \
    && [ "$(json_field_file "$RESERVATIONS_DIR/r_forged.json" status)" = "provisioned" ]; } \
    && pass "A4: a FORGED/unsigned reservation is IGNORED (authenticity gate bites)" \
    || fail "A4: a forged reservation was adopted — the HMAC gate did not bite"
  reset_res
  mk_res r_valid "$CWD" "$SLUG" provisioned "Trusted" "Backend" ""
  ( export TRACKBOARD_DEVICE_SLUG="$SLUG" FLEET_RESERVATION="r_valid"; adopt_reservation "sid-valid" "$CWD" )
  [ "$(json_field_file "$RESERVATIONS_DIR/r_valid.json" bound_sid)" = "sid-valid" ] \
    && pass "A4 control: a VALIDLY-signed reservation IS adopted (the gate does not over-block)" \
    || fail "A4 control: a validly-signed reservation was rejected"

  # ── A5: host qualifier — a different device is never cwd-bound; the matching device is ──────────────────────
  reset_res
  mk_res r_other "$CWD" "gpu-box" provisioned "Wrong" "Backend" ""   # targets a DIFFERENT device
  ( export TRACKBOARD_DEVICE_SLUG="$SLUG"; adopt_reservation "sid-wrongdev" "$CWD" )   # this host is "mini"
  { [ ! -f "$IDENTITIES_DIR/sid-wrongdev.json" ] \
    && [ "$(json_field_file "$RESERVATIONS_DIR/r_other.json" status)" = "provisioned" ]; } \
    && pass "A5: a reservation for ANOTHER device is never cwd-bound on this host" \
    || fail "A5: a foreign-device reservation was adopted on the wrong host"

  [ "$ok" = 1 ]
) || ok=0

[ "$ok" = 1 ] && { echo "selftest-adopt: OK — native adoption BITES (signed, host-qualified, unambiguous) + baseline byte-identical"; exit 0; }
echo "selftest-adopt: FAIL — reservation adoption regressed"; exit 1
