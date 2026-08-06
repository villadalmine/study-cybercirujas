#!/usr/bin/env bash
#
# ============================================================================
#  CNPA — Cloud Native Platform Associate (exam version 2025-04-01)
#  Domain 2.2 — Secure Service-to-Service Communication   (exam weight: 4.0)
#
#  BREAK & FIX LAB  —  "The botched CA rotation"
#  Scenario: mutual TLS (mTLS) between two workloads —
#            frontend.svc.lab  (the caller / client)
#            backend.svc.lab   (the callee / server, enforces client certs)
#  A controlled fault is injected; the student must restore verifiable,
#  mutually-authenticated identity WITHOUT weakening the verifier.
#
#  SAFETY / SCOPE
#   - Run ONLY on a disposable lab VM. Everything lives under $LAB_DIR and a
#     single loopback-only TCP port. No external hosts are touched. Fully
#     reversible: `` <thisscript> cleanup `` removes it all.
#   - No real credentials, no production trust store, no network scanning.
#
#  Reference sources (official / normative):
#   - CNCF CNPA curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   - TLS 1.3 (mutual authentication): https://www.rfc-editor.org/rfc/rfc8446
#   - SPIFFE/SPIRE workload identity:  https://spiffe.io/docs/latest/spiffe-about/overview/
#   - OpenSSL s_server/s_client:       https://docs.openssl.org/master/man1/openssl-s_server/
#   - Istio PeerAuthentication (mesh analogue): https://istio.io/latest/docs/reference/config/security/peer_authentication/
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-/tmp/cnpa-2.2-mtls-lab}"
PORT="${PORT:-8443}"
PKI="$LAB_DIR/pki"
ROGUE="$LAB_DIR/rogue"
PIDFILE="$LAB_DIR/service.pid"
LOG="$LAB_DIR/service.log"

TRUST_CA_CN="CNPA Lab Root CA"   # the fleet-wide trust anchor
SERVER_CN="backend.svc.lab"      # the callee identity
CLIENT_CN="frontend.svc.lab"     # the caller identity

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "----------------------------------------------------------------------"; }

require_openssl() {
  if ! have openssl; then
    say "FATAL: 'openssl' is required and was not found on PATH." >&2
    say "       Install it (e.g. 'apt-get install -y openssl') and re-run." >&2
    exit 1
  fi
}

# Send one HTTP request through the mTLS tunnel as the frontend workload and
# return everything openssl printed (handshake + verify status + response).
run_client() {
  local timeout_bin=()
  have timeout && timeout_bin=(timeout 10)
  printf 'GET / HTTP/1.0\r\n\r\n' \
    | "${timeout_bin[@]}" openssl s_client \
        -connect "127.0.0.1:$PORT" \
        -cert "$PKI/client.crt" -key "$PKI/client.key" \
        -CAfile "$PKI/ca.crt" 2>&1 || true
}

# Pass == the caller cryptographically verified the callee's identity.
check_mtls() { run_client | grep -q "Verify return code: 0 (ok)"; }

# ---------------------------------------------------------------------------
# Service lifecycle (the backend workload — it survives script exit so the
# student can poke at it interactively)
# ---------------------------------------------------------------------------
stop_service() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  # Belt-and-suspenders idempotency for a stray listener from a prior run.
  pkill -f "s_server -accept 127.0.0.1:$PORT" 2>/dev/null || true
  sleep 1
}

start_service() {
  # -Verify 1  => REQUIRE a client certificate (strict mTLS, not opportunistic)
  # -CAfile    => the CA the backend trusts to authenticate CALLERS
  # -www       => answer with a small HTTP status page, then keep listening
  nohup openssl s_server \
    -accept "127.0.0.1:$PORT" \
    -cert "$PKI/server.crt" -key "$PKI/server.key" \
    -CAfile "$PKI/ca.crt" \
    -Verify 1 -www \
    >"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  disown || true
  sleep 1
}

restart_service() { stop_service; start_service; }

# ---------------------------------------------------------------------------
# Build the lab PKI: one root CA, one server identity (with SAN), one client
# identity. All three chain to the SAME trusted CA -> mTLS works.
# ---------------------------------------------------------------------------
build_pki() {
  mkdir -p "$PKI"

  # Fleet-wide trust anchor.
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$PKI/ca.key" -out "$PKI/ca.crt" \
    -subj "/CN=$TRUST_CA_CN" >/dev/null 2>&1

  # Backend (server) identity — SAN is mandatory for hostname verification.
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$PKI/server.key" -out "$PKI/server.csr" \
    -subj "/CN=$SERVER_CN" >/dev/null 2>&1
  openssl x509 -req -in "$PKI/server.csr" \
    -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -days 1 \
    -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n") \
    -out "$PKI/server.crt" >/dev/null 2>&1

  # Frontend (client) identity — enables mutual authentication.
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$PKI/client.key" -out "$PKI/client.csr" \
    -subj "/CN=$CLIENT_CN" >/dev/null 2>&1
  openssl x509 -req -in "$PKI/client.csr" \
    -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -days 1 \
    -out "$PKI/client.crt" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# THE BREAK — simulate a certificate rotation performed against the WRONG CA.
# The backend is redeployed with a brand-new identity signed by a CA the fleet
# does not trust. Nothing about connectivity, ports, or NetworkPolicy changes;
# only the callee's cryptographic identity becomes untrusted.
# ---------------------------------------------------------------------------
arm_break() {
  mkdir -p "$ROGUE"

  # A rogue/unrelated CA appears (attacker CA, or an unbootstrapped issuer in a
  # different trust domain — the real-world root cause of most mTLS incidents).
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$ROGUE/rogue-ca.key" -out "$ROGUE/rogue-ca.crt" \
    -subj "/CN=Rogue CA" >/dev/null 2>&1

  # Re-issue the backend cert (same private key) but sign it with the rogue CA.
  openssl req -new -key "$PKI/server.key" -subj "/CN=$SERVER_CN" \
    -out "$ROGUE/server.csr" >/dev/null 2>&1
  openssl x509 -req -in "$ROGUE/server.csr" \
    -CA "$ROGUE/rogue-ca.crt" -CAkey "$ROGUE/rogue-ca.key" -CAcreateserial -days 1 \
    -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n") \
    -out "$PKI/server.crt" >/dev/null 2>&1

  restart_service
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
cleanup() {
  stop_service
  rm -rf "$LAB_DIR"
  say "Lab torn down: service stopped, $LAB_DIR removed."
}

usage() {
  say "Usage: $0 [cleanup]"
  say "  (no args)  build the mTLS lab, prove it works, then inject the fault"
  say "  cleanup    stop the backend and delete all lab artifacts"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-arm}" in
  -h|--help) usage; exit 0 ;;
  cleanup)   cleanup; exit 0 ;;
  arm)       : ;;
  *)         usage; exit 1 ;;
esac

require_openssl

hr
say "CNPA 2.2 — Secure Service-to-Service Communication : BREAK & FIX"
hr

# Reset to a known-good state (idempotent: safe to re-run any number of times).
stop_service
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR"

say "[1/4] Provisioning lab PKI (root CA + backend + frontend identities)..."
build_pki

say "[2/4] Starting the backend workload with strict mTLS on 127.0.0.1:$PORT..."
start_service

say "[3/4] Baseline check — the frontend should verify the backend cleanly:"
if check_mtls; then
  say "      OK: 'Verify return code: 0 (ok)' — mutual TLS is healthy."
else
  say "      FATAL: baseline mTLS did not come up. Inspect $LOG and re-run." >&2
  say "             (Likely an ancient openssl or port $PORT already in use.)" >&2
  exit 1
fi

say "[4/4] Injecting the fault..."
arm_break
hr

cat <<EOF

  ========================  INCIDENT BRIEFING  ========================

  A routine certificate rotation was just applied to '$SERVER_CN'. The
  backend process is UP and the port is OPEN — but the frontend can no
  longer trust who it is talking to.

  ---------------------------  SYMPTOM  -------------------------------
  Run the exact call the frontend workload makes:

    printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client \\
        -connect 127.0.0.1:$PORT \\
        -cert $PKI/client.crt -key $PKI/client.key \\
        -CAfile $PKI/ca.crt 2>&1 | grep -i -E 'verify|error'

  You will see something like:
      verify error:num=20:unable to get local issuer certificate
      verify error:num=21:unable to verify the first certificate
      Verify return code: 21 (unable to verify the first certificate)

  Note carefully what is NOT broken:
    - 'ss -ltnp | grep $PORT'  ->  the backend is LISTENING (up).
    - The TCP connection and the TLS handshake both proceed far enough to
      EXCHANGE certificates. This is NOT a connectivity, DNS, firewall or
      NetworkPolicy failure. It is an IDENTITY / TRUST failure.
    - openssl s_client is lenient and still prints the page; a real caller
      (curl, an app, a sidecar) REFUSES the connection outright with
      'SSL certificate problem: unable to get local issuer certificate'.
      Data flowing without a verified peer identity is precisely the risk
      this domain is about.

  ----------------------------  GOAL  --------------------------------
  Restore trustworthy, mutually-authenticated service-to-service comms:
    * Make '$SERVER_CN' present an identity that chains back to the fleet's
      trusted CA ('$TRUST_CA_CN'), keeping its SAN intact.
    * Keep strict mTLS enforced — the backend must still REQUIRE and verify
      the frontend's client certificate.
    * Do NOT weaken the verifier: no 'curl -k', no disabling verification,
      and never add the rogue CA to anyone's trust store.

  SUCCESS CRITERION: the command above prints
      Verify return code: 0 (ok)
  and the backend's HTTP status page is returned, with client-cert mutual
  authentication still in force. Confirm with:  bash $0   (re-arms), or
  just re-run the s_client call after your fix.

  Progressive hints (uncover only what you need):
    1. Classify: reachable (port/handshake) vs. trusted (issuer). Which is it?
    2. Inspect the identity the backend actually presents (issuer/subject/SAN).
    3. Compare that issuer against '$TRUST_CA_CN'.
    4. Re-issue the backend cert from the trusted CA; reload; re-verify.

  Artifacts:  PKI=$PKI   backend log=$LOG   backend pid=\$(cat $PIDFILE)
  Reset/teardown when done:  $0 cleanup
  =====================================================================

EOF

exit 0

# ===========================================================================
#  SOLUTION — STEP BY STEP   (try it yourself before reading)
#  All commands assume you are in the lab dir:  cd $LAB_DIR/pki
# ===========================================================================
#
#  STEP 0 — Confirm it is a TRUST problem, not a connectivity problem:
#     ss -ltnp | grep 8443
#        -> LISTEN ... openssl        (the service is up; ports are fine)
#     printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client -connect 127.0.0.1:8443 \
#        -cert client.crt -key client.key -CAfile ca.crt 2>&1 | grep -i verify
#        -> Verify return code: 21 (unable to verify the first certificate)
#
#  STEP 1 — Inspect the identity the backend is presenting on the wire:
#     openssl s_client -connect 127.0.0.1:8443 \
#        -cert client.crt -key client.key </dev/null 2>/dev/null \
#        | openssl x509 -noout -issuer -subject -ext subjectAltName
#        -> issuer=CN = Rogue CA          <-- the smoking gun
#           subject=CN = backend.svc.lab
#
#  STEP 2 — Confirm the CA the fleet actually trusts:
#     openssl x509 -in ca.crt -noout -subject
#        -> subject=CN = CNPA Lab Root CA   (backend's issuer must match THIS)
#
#  STEP 3 — Re-issue the backend certificate from the TRUSTED CA.
#           Reuse the existing server key; you MUST re-add the SAN, or you
#           will just trade an "unknown issuer" error for a hostname-mismatch:
#     openssl req -new -key server.key -subj "/CN=backend.svc.lab" -out server.csr
#     openssl x509 -req -in server.csr \
#        -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 \
#        -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n") \
#        -out server.crt
#
#  STEP 4 — Validate the new identity BEFORE deploying it (fail closed):
#     openssl verify -CAfile ca.crt server.crt
#        -> server.crt: OK
#
#  STEP 5 — Reload the backend with the corrected identity (same strict flags):
#     kill "$(cat ../service.pid)" 2>/dev/null; sleep 1
#     nohup openssl s_server -accept 127.0.0.1:8443 \
#        -cert server.crt -key server.key -CAfile ca.crt -Verify 1 -www \
#        > ../service.log 2>&1 & echo $! > ../service.pid ; disown
#
#  STEP 6 — Verify the fix (both directions of the mutual handshake):
#     printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client -connect 127.0.0.1:8443 \
#        -cert client.crt -key client.key -CAfile ca.crt 2>&1 | grep -i verify
#        -> Verify return code: 0 (ok)
#     # And prove mTLS is still STRICT (no client cert must be rejected):
#     printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client -connect 127.0.0.1:8443 \
#        -CAfile ca.crt 2>&1 | grep -i -E 'alert|handshake failure|peer'
#        -> ... alert handshake failure ...  (server correctly demands a cert)
#
#  WHY THIS IS THE CORRECT FIX — and the tempting wrong ones:
#   - mTLS security rests on BOTH peers chaining to a MUTUALLY trusted CA. The
#     backend's identity was rotated onto a CA the fleet does not trust, so every
#     caller correctly rejected it. Fixing the identity at its source restores
#     zero-trust guarantees for the whole fleet at once.
#   - WRONG: 'curl -k' / verify=none / adding "Rogue CA" to the client trust
#     store. These make the error disappear while destroying the exact control
#     this domain tests — you would fleet-wide trust an unknown issuer, which is
#     indistinguishable from accepting an attacker's man-in-the-middle cert.
#   - WRONG: dropping '-Verify 1' to "get traffic flowing". That downgrades
#     strict mTLS to server-only TLS and lets unauthenticated callers in.
#   - Mesh analogue (Istio/Linkerd/SPIFFE): a workload presenting an SVID/cert
#     from the wrong trust domain, or an expired/rotated intermediate. The remedy
#     is identical — correct the ISSUER at the workload (re-bootstrap identity),
#     never relax PeerAuthentication/mode: STRICT or the peer trust bundle.
# ===========================================================================