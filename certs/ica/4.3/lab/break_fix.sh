#!/usr/bin/env bash
#
# ==============================================================================
#  ICA (Istio Certified Associate) — Domain 4: Securing Workloads
#  Topic 4.3: Securing Edge Traffic with TLS   (exam weight: 8)
#
#  BREAK & FIX LAB  —  "The credential that hides in the wrong namespace"
#
#  Source of truth (syllabus):
#    https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#  Concepts exercised (official docs):
#    - Ingress gateway TLS termination (SIMPLE mode):
#      https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
#    - How the gateway loads certificates over SDS (credentialName):
#      https://istio.io/latest/docs/ops/configuration/traffic-management/secret-creation/
#    - Gateway API reference (tls.mode / tls.credentialName):
#      https://istio.io/latest/docs/reference/config/networking/gateway/
#
#  WHAT THIS SCRIPT DOES
#    1. Builds a known-good edge-TLS baseline (httpbin behind an HTTPS Gateway).
#    2. Proves it works with curl.
#    3. Breaks ONE thing, in a controlled and fully reversible way.
#    4. Tells you the symptom you will see and the goal you must reach.
#    5. Keeps the fix at the very bottom, commented out — try it yourself first.
#
#  SAFETY
#    - Runs ONLY against a disposable lab cluster. It touches exactly one
#      namespace (ica-tls-lab) and exactly one secret name (edge-tls-cert)
#      in istio-system. It deletes nothing else. Use `cleanup` to remove all.
#    - Self-signed certs live in $LAB_DIR and expire in 3 days on purpose.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration — override via environment if your lab differs.
# ------------------------------------------------------------------------------
APP_NS="${APP_NS:-ica-tls-lab}"                 # application namespace
GW_NS="${GW_NS:-istio-system}"                  # ingress-gateway namespace
INGRESS_SVC="${INGRESS_SVC:-istio-ingressgateway}"
INGRESS_SELECTOR_LABEL="${INGRESS_SELECTOR_LABEL:-istio=ingressgateway}"
CRED_NAME="${CRED_NAME:-edge-tls-cert}"         # Gateway credentialName
HOSTNAME_FQDN="${HOSTNAME_FQDN:-httpbin.ica.example}"
LAB_DIR="${LAB_DIR:-/tmp/ica-tls-lab}"

CRT="${LAB_DIR}/edge-tls.crt"
KEY="${LAB_DIR}/edge-tls.key"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!! ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preconditions.
# ------------------------------------------------------------------------------
require_tools() {
  for bin in kubectl openssl curl; do
    command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
  done
  command -v istioctl >/dev/null 2>&1 || warn "istioctl not found — diagnostics will be limited"
  kubectl get ns "$GW_NS" >/dev/null 2>&1 \
    || die "namespace '$GW_NS' not found — is Istio installed on this cluster?"
  kubectl -n "$GW_NS" get deploy "$INGRESS_SVC" >/dev/null 2>&1 \
    || die "deployment '$INGRESS_SVC' not found in '$GW_NS' — no ingress gateway to secure"
}

confirm_disposable() {
  warn "This lab mutates cluster state (namespace '$APP_NS', secret '$CRED_NAME')."
  warn "Run it ONLY on a throwaway lab cluster."
  read -r -p "Type 'lab' to continue: " answer
  [ "$answer" = "lab" ] || die "aborted by user"
}

# ------------------------------------------------------------------------------
# Ingress endpoint discovery (LoadBalancer, then NodePort fallback).
# ------------------------------------------------------------------------------
discover_ingress() {
  INGRESS_HOST="$(kubectl -n "$GW_NS" get svc "$INGRESS_SVC" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$INGRESS_HOST" ] || INGRESS_HOST="$(kubectl -n "$GW_NS" get svc "$INGRESS_SVC" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

  SECURE_INGRESS_PORT="$(kubectl -n "$GW_NS" get svc "$INGRESS_SVC" \
      -o jsonpath='{.spec.ports[?(@.name=="https")].port}' 2>/dev/null || true)"

  if [ -z "$INGRESS_HOST" ]; then
    # No external LB — fall back to a node IP + the HTTPS nodePort.
    INGRESS_HOST="$(kubectl get nodes \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
    SECURE_INGRESS_PORT="$(kubectl -n "$GW_NS" get svc "$INGRESS_SVC" \
        -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"
  fi

  [ -n "$INGRESS_HOST" ]        || die "could not determine ingress host"
  [ -n "$SECURE_INGRESS_PORT" ] || die "could not determine HTTPS ingress port"
  log "ingress endpoint: ${INGRESS_HOST}:${SECURE_INGRESS_PORT}"
}

# ------------------------------------------------------------------------------
# Certificate material (self-signed, short-lived, lab-only).
# ------------------------------------------------------------------------------
ensure_certs() {
  mkdir -p "$LAB_DIR"
  if [ ! -s "$CRT" ] || [ ! -s "$KEY" ]; then
    log "generating self-signed cert for CN=${HOSTNAME_FQDN} (3-day validity)"
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "$KEY" -out "$CRT" -days 3 \
      -subj "/CN=${HOSTNAME_FQDN}/O=ICA Lab" \
      -addext "subjectAltName=DNS:${HOSTNAME_FQDN}" >/dev/null 2>&1
  fi
}

put_secret_in() {  # $1 = namespace
  kubectl -n "$1" create secret tls "$CRED_NAME" \
    --cert="$CRT" --key="$KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# ------------------------------------------------------------------------------
# Baseline: sample app + HTTPS Gateway + VirtualService.
# ------------------------------------------------------------------------------
setup_baseline() {
  ensure_certs
  log "creating namespace '$APP_NS' with sidecar injection"
  kubectl create ns "$APP_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label ns "$APP_NS" istio-injection=enabled --overwrite >/dev/null

  log "deploying httpbin backend"
  kubectl -n "$APP_NS" apply -f \
    https://raw.githubusercontent.com/istio/istio/release-1.22/samples/httpbin/httpbin.yaml >/dev/null

  log "installing the TLS credential in the GATEWAY namespace ('$GW_NS')"
  put_secret_in "$GW_NS"

  log "applying Gateway (SIMPLE TLS termination) + VirtualService"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: edge-gateway
  namespace: ${APP_NS}
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: ${CRED_NAME}
    hosts:
    - "${HOSTNAME_FQDN}"
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "${HOSTNAME_FQDN}"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: httpbin
  namespace: ${APP_NS}
spec:
  hosts:
  - "${HOSTNAME_FQDN}"
  gateways:
  - edge-gateway
  http:
  - route:
    - destination:
        host: httpbin
        port:
          number: 8000
EOF

  kubectl -n "$APP_NS" rollout status deploy/httpbin --timeout=120s >/dev/null
  ok "baseline applied"
}

verify_https() {  # returns 0 if edge TLS returns HTTP 200
  discover_ingress
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      --cacert "$CRT" \
      --resolve "${HOSTNAME_FQDN}:${SECURE_INGRESS_PORT}:${INGRESS_HOST}" \
      "https://${HOSTNAME_FQDN}:${SECURE_INGRESS_PORT}/status/200" 2>/dev/null || echo 000)"
  [ "$code" = "200" ]
}

# ------------------------------------------------------------------------------
# THE CONTROLLED BREAK
#   We do NOT touch the Gateway, the VirtualService, the app, the cert bytes,
#   or the secret's name. We move the identical secret ONE namespace over:
#   out of the gateway's namespace ('istio-system') and into the app namespace.
#   Everything still "looks" present — `kubectl get secret edge-tls-cert` finds
#   it — but the ingress gateway can no longer load it over SDS.
# ------------------------------------------------------------------------------
do_break() {
  ensure_certs
  log "BREAK: relocating credential '$CRED_NAME' from '$GW_NS' to '$APP_NS'"
  put_secret_in "$APP_NS"                                     # decoy copy in app ns
  kubectl -n "$GW_NS" delete secret "$CRED_NAME" --ignore-not-found >/dev/null
  ok "break applied — the secret now exists, but not where the gateway reads it"
}

print_challenge() {
  discover_ingress
  cat <<EOF

  ============================================================================
   ICA 4.3 — BREAK & FIX CHALLENGE :: Securing Edge Traffic with TLS
  ============================================================================

   Nothing changed in your Gateway, VirtualService, app, or certificate.
   A secret named '${CRED_NAME}' still exists in the cluster. Yet edge TLS
   is now broken. Find out why, and restore it.

   --- SYMPTOM YOU WILL SEE -------------------------------------------------
   Plain HTTP still routes (port 80 has no TLS to break):

     curl -sS -o /dev/null -w '%{http_code}\\n' \\
       --resolve "${HOSTNAME_FQDN}:80:${INGRESS_HOST}" \\
       "http://${HOSTNAME_FQDN}/status/200"          # -> 200

   HTTPS at the edge fails the handshake — connection reset, no certificate:

     curl -v --cacert ${CRT} \\
       --resolve "${HOSTNAME_FQDN}:${SECURE_INGRESS_PORT}:${INGRESS_HOST}" \\
       "https://${HOSTNAME_FQDN}:${SECURE_INGRESS_PORT}/status/200"
     # -> OpenSSL/SSL_connect: Connection reset by peer  (or handshake failure)

   And the classic tell — the credential is simply not loaded by the gateway:

     istioctl proxy-config secret deploy/${INGRESS_SVC} -n ${GW_NS} \\
       | grep -i ${CRED_NAME}     # -> nothing, or WARN/NOT SENT

   --- YOUR GOAL ------------------------------------------------------------
   Make this command print exactly '200' again, WITHOUT editing the Gateway,
   the VirtualService, or regenerating the certificate:

     curl -sS -o /dev/null -w '%{http_code}\\n' --cacert ${CRT} \\
       --resolve "${HOSTNAME_FQDN}:${SECURE_INGRESS_PORT}:${INGRESS_HOST}" \\
       "https://${HOSTNAME_FQDN}:${SECURE_INGRESS_PORT}/status/200"

   --- HINTS (peel only if stuck) -------------------------------------------
   1. A Gateway's 'credentialName' is not resolved in the app's namespace.
      In which namespace does the ingress gateway workload actually run?
   2. 'kubectl get secret ${CRED_NAME} -A' — where is it, and where is it NOT?
   3. Istio reads gateway TLS secrets over SDS from the gateway's OWN namespace
      ('${GW_NS}'), regardless of where the Gateway resource is declared.

   When you think it is fixed, re-run:  $0 verify
  ============================================================================

EOF
}

verify_challenge() {
  if verify_https; then
    ok "HTTPS edge returns 200 — challenge SOLVED. TLS termination restored."
  else
    warn "Still failing. The credential must live in the gateway namespace ('$GW_NS')."
    warn "Inspect:  kubectl get secret $CRED_NAME -A"
    exit 1
  fi
}

cleanup() {
  log "removing lab resources"
  kubectl -n "$APP_NS" delete deploy,svc,sa httpbin --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$APP_NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$GW_NS" delete secret "$CRED_NAME" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  ok "cleanup complete"
}

# ------------------------------------------------------------------------------
# Entry point.
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 [command]
  (no args)   confirm -> setup baseline -> prove it works -> break -> challenge
  setup       build/repair the known-good baseline only
  break       apply the controlled break only (assumes baseline exists)
  verify      check whether edge HTTPS returns 200 (grades your fix)
  cleanup     remove everything this lab created
EOF
}

main() {
  local cmd="${1:-run}"
  case "$cmd" in
    run)
      require_tools
      confirm_disposable
      setup_baseline
      if verify_https; then
        ok "baseline verified — edge HTTPS returns 200"
      else
        die "baseline did not come up healthy; fix the environment before breaking it"
      fi
      do_break
      print_challenge
      ;;
    setup)   require_tools; setup_baseline; verify_https && ok "baseline healthy" || warn "baseline not yet healthy" ;;
    break)   require_tools; do_break; print_challenge ;;
    verify)  require_tools; verify_challenge ;;
    cleanup) require_tools; cleanup ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"

# ==============================================================================
#  SOLUTION  (commented — try the challenge before reading)
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  Istio's ingress gateway loads TLS certificates referenced by a Gateway's
#  'tls.credentialName' through SDS (Secret Discovery Service). The secret is
#  looked up in the namespace where the INGRESS GATEWAY WORKLOAD runs
#  (here: 'istio-system'), NOT in the namespace of the Gateway resource or of
#  the application. Our break moved the identical secret into the app namespace
#  ('ica-tls-lab'). The secret exists, the name matches, the cert is valid —
#  but the gateway proxy cannot see it, so the HTTPS listener has no server
#  certificate and every TLS handshake is reset.
#
#  DIAGNOSIS, STEP BY STEP
#  -----------------------
#  1. Confirm HTTP still works but HTTPS does not (isolates the fault to TLS):
#       curl -s -o /dev/null -w '%{http_code}\n' \
#         --resolve "httpbin.ica.example:80:$INGRESS_HOST" \
#         http://httpbin.ica.example/status/200                 # 200
#       curl -v --cacert /tmp/ica-tls-lab/edge-tls.crt \
#         --resolve "httpbin.ica.example:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
#         https://httpbin.ica.example:$SECURE_INGRESS_PORT/status/200   # reset
#
#  2. Ask the gateway proxy which secrets it actually holds:
#       istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system
#     -> 'edge-tls-cert' is absent (or shown as not sent / no valid cert chain).
#
#  3. Read the gateway logs for the missing-credential warning:
#       kubectl -n istio-system logs deploy/istio-ingressgateway \
#         | grep -iE 'edge-tls-cert|sds|secret'
#
#  4. Locate the secret cluster-wide — this reveals the misplacement:
#       kubectl get secret edge-tls-cert -A
#     -> present in 'ica-tls-lab', ABSENT in 'istio-system'.
#
#  THE FIX (one of two equivalent forms)
#  -------------------------------------
#  (a) Put the credential back where the gateway reads it — istio-system:
#       kubectl -n istio-system create secret tls edge-tls-cert \
#         --cert=/tmp/ica-tls-lab/edge-tls.crt \
#         --key=/tmp/ica-tls-lab/edge-tls.key \
#         --dry-run=client -o yaml | kubectl apply -f -
#
#  (b) Or copy the existing secret across namespaces without the source files:
#       kubectl -n ica-tls-lab get secret edge-tls-cert -o yaml \
#         | sed -e 's/namespace: ica-tls-lab/namespace: istio-system/' \
#               -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
#         | kubectl apply -f -
#
#  Then remove the decoy so the lesson sticks (optional):
#       kubectl -n ica-tls-lab delete secret edge-tls-cert
#
#  SDS reloads the credential within seconds — no gateway restart is needed.
#
#  VERIFY
#  ------
#       istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system \
#         | grep edge-tls-cert                                   # now present
#       ./this-script.sh verify                                  # prints: 200
#
#  TAKEAWAY FOR THE EXAM (ICA 4.3)
#  -------------------------------
#  For edge TLS termination, the golden rule is: the secret named by
#  'credentialName' MUST live in the ingress gateway's namespace (istio-system
#  by default), it MUST be type kubernetes.io/tls with 'tls.crt'/'tls.key'
#  (or 'tls.key'+'ca.crt' for MUTUAL mode), and it is served over SDS — no
#  volume mounts, no gateway redeploy. "Secret exists somewhere" is not the
#  same as "the gateway can load it."
# ==============================================================================