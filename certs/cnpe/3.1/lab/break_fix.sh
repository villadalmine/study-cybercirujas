#!/usr/bin/env bash
#
# ==============================================================================
#  BREAK & FIX LAB  —  CNPE Topic 3.1
#  Configuring Secure Service-to-Service Communication
# ==============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  In a service mesh, "secure service-to-service communication" means workloads
#  authenticate and encrypt traffic to each other with mutual TLS (mTLS). The
#  mesh enforces this with two DIFFERENT objects that must agree:
#
#    * PeerAuthentication  -> what the SERVER (inbound side) REQUIRES.
#                             STRICT means "I only accept mTLS, never plaintext".
#    * DestinationRule     -> how the CLIENT (outbound side) SENDS traffic.
#                             tls.mode ISTIO_MUTUAL = speak mTLS,
#                             tls.mode DISABLE       = send plaintext.
#
#  The single most common production outage in a hardened mesh is a MISMATCH:
#  the server demands mTLS (STRICT) while a stray DestinationRule tells the
#  client to send plaintext (DISABLE). The connection is refused at the TLS
#  layer and every request 503s — yet nothing in the application logs explains
#  why. This lab reproduces exactly that failure, safely, in a throwaway
#  namespace, and asks you to restore connectivity WITHOUT weakening security.
#
#  This is a controlled break. It only creates/edits objects inside the
#  dedicated namespace "s2s-lab". Run "$0 cleanup" to remove everything.
#
#  PREREQUISITES (expected on a disposable lab VM)
#  -----------------------------------------------
#    * A running Kubernetes cluster (kind / minikube / k3d are fine).
#    * kubectl configured against that cluster.
#    * Istio installed with the "default" profile (istiod in namespace
#      istio-system). Install quickly with:  istioctl install -y
#
#  Sources (official):
#    * Istio mTLS / PeerAuthentication:
#        https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
#    * Istio mTLS migration (STRICT vs PERMISSIVE):
#        https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
#    * DestinationRule ClientTLSSettings (tls.mode):
#        https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
#    * PeerAuthentication API reference:
#        https://istio.io/latest/docs/reference/config/security/peer_authentication/
#    * CNCF CNPE curriculum:
#        https://github.com/cncf/curriculum
# ==============================================================================

set -euo pipefail

NS="s2s-lab"
SERVER_IMG="docker.io/mccutchen/go-httpbin:v2.15.0"   # HTTP server, listens on :8080
CLIENT_IMG="docker.io/curlimages/curl:8.11.1"         # client with curl
SVC_HOST="httpbin.${NS}.svc.cluster.local"

# ------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------
c_red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_grn()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yel()   { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
hr()      { printf '%s\n' "------------------------------------------------------------------------"; }

die() { c_red "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH. Install it before running this lab."
}

preflight() {
  require_cmd kubectl
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster. Point your kubeconfig at the lab cluster."
  if ! kubectl get ns istio-system >/dev/null 2>&1; then
    die "Istio is not installed (namespace istio-system missing). Run: istioctl install -y"
  fi
  kubectl -n istio-system get deploy istiod >/dev/null 2>&1 \
    || die "istiod not found in istio-system. Reinstall Istio: istioctl install -y"
}

confirm() {
  [ "${AUTO_YES:-0}" = "1" ] && return 0
  c_yel "This will create namespace '${NS}' and inject a controlled mTLS fault into it."
  read -r -p "Type 'break' to continue: " ans
  [ "$ans" = "break" ] || die "Aborted by user."
}

wait_ready() {
  # $1 = deployment name
  kubectl -n "$NS" rollout status "deploy/$1" --timeout=120s >/dev/null
}

# curl the server FROM the client pod; echoes just the HTTP status code
probe() {
  local pod
  pod="$(kubectl -n "$NS" get pod -l app=client -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$NS" exec "$pod" -c curl -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://httpbin:8000/get" || true
}

# ------------------------------------------------------------------------------
# SETUP  —  a correct, secure baseline: two meshed services + STRICT mTLS.
# At the end of setup, traffic works (HTTP 200) and is fully encrypted.
# ------------------------------------------------------------------------------
setup() {
  c_bold ">> [1/3] Building the secure baseline in namespace '${NS}'..."

  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Turn on automatic sidecar injection for the whole namespace.
  kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

  # --- Server: go-httpbin, meshed, exposed on service port 8000 -> pod 8080 ---
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: ${NS}
  labels: { app: httpbin }
spec:
  replicas: 1
  selector: { matchLabels: { app: httpbin } }
  template:
    metadata:
      labels: { app: httpbin }
    spec:
      containers:
        - name: httpbin
          image: ${SERVER_IMG}
          args: ["-port", "8080"]
          ports: [ { containerPort: 8080 } ]
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: ${NS}
  labels: { app: httpbin }
spec:
  selector: { app: httpbin }
  ports:
    - name: http
      port: 8000
      targetPort: 8080
YAML

  # --- Client: idle curl pod that will call the server ----------------------
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: ${NS}
  labels: { app: client }
spec:
  replicas: 1
  selector: { matchLabels: { app: client } }
  template:
    metadata:
      labels: { app: client }
    spec:
      containers:
        - name: curl
          image: ${CLIENT_IMG}
          command: ["sleep", "infinity"]
YAML

  # --- Security posture: require mTLS for every workload in this namespace ---
  #     This is the CORRECT hardening. It is NOT the bug. Do not remove it.
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: require-mtls
  namespace: ${NS}
spec:
  mtls:
    mode: STRICT
YAML

  wait_ready httpbin
  wait_ready client

  c_bold ">> Verifying the healthy baseline (expect HTTP 200)..."
  local code; code="$(probe)"
  if [ "$code" = "200" ]; then
    c_grn "   Baseline OK: client -> httpbin returned ${code} over mTLS."
  else
    c_yel "   Baseline returned ${code} (sidecars may still be warming up; re-run in a few seconds)."
  fi
}

# ------------------------------------------------------------------------------
# BREAK  —  inject a client-side DestinationRule that forces PLAINTEXT to a
# server that REQUIRES mTLS. The result is an mTLS mode mismatch.
# ------------------------------------------------------------------------------
break_it() {
  c_bold ">> [2/3] Injecting the controlled fault..."
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin-plaintext      # <-- the culprit you will hunt down
  namespace: ${NS}
spec:
  host: ${SVC_HOST}
  trafficPolicy:
    tls:
      mode: DISABLE            # client is told to send plaintext...
YAML
  # ...while PeerAuthentication STRICT means the server accepts ONLY mTLS.
  c_grn "   Fault injected."
  sleep 3   # let the config propagate to the sidecars
}

# ------------------------------------------------------------------------------
# SYMPTOM  —  what the student observes.
# ------------------------------------------------------------------------------
show_symptom() {
  c_bold ">> [3/3] Reproducing the symptom..."
  local code; code="$(probe)"
  hr
  c_red  "SYMPTOM"
  hr
  cat <<EOF
The client can no longer talk to the server. A request that returned 200 a
moment ago now returns:

    HTTP status observed:  ${code}      (expected: 200)

Reproduce it yourself and read the verbose error:

    POD=\$(kubectl -n ${NS} get pod -l app=client -o jsonpath='{.items[0].metadata.name}')
    kubectl -n ${NS} exec \$POD -c curl -- curl -sv http://httpbin:8000/get

You will see the client-side Envoy answer with something like:

    < HTTP/1.1 503 Service Unavailable
    upstream connect error or disconnect/reset before headers.
    reset reason: connection termination

Key observations that make this a SECURITY-layer failure, not an app bug:
  * The httpbin application logs show NO incoming request — the connection
    never reached the app; it died in the sidecar's TLS handshake.
  * Both pods are Running and 2/2 Ready (app + istio-proxy). Nothing crashed.
  * DNS resolves and the Service has endpoints. It is purely a TLS mode clash.
EOF
  hr
  c_yel "OBJECTIVE"
  hr
  cat <<EOF
Restore client -> httpbin to HTTP 200 WHILE KEEPING the mesh secure:

  * The 'require-mtls' PeerAuthentication (STRICT) MUST stay in place.
    Switching it to PERMISSIVE would make the 503 disappear but would silently
    allow unencrypted traffic — that is a security regression, NOT a fix.
  * Find the object that instructs the client to bypass mTLS and correct it so
    the client speaks mTLS to the server again.

Useful diagnostics:
    kubectl -n ${NS} get peerauthentication,destinationrule
    istioctl x describe pod \$POD -n ${NS}          # if istioctl is available
    istioctl proxy-config cluster \$POD -n ${NS} --fqdn ${SVC_HOST} -o json | grep -i tls

Verify success with:
    kubectl -n ${NS} exec \$POD -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/get
    # -> 200

When you are done, clean up the lab with:   $0 cleanup
EOF
  hr
}

cleanup() {
  c_bold ">> Removing lab namespace '${NS}'..."
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null
  c_grn "   Done."
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------
main() {
  case "${1:-run}" in
    cleanup) require_cmd kubectl; cleanup ;;
    run)
      preflight
      confirm
      setup
      break_it
      show_symptom
      ;;
    *) die "Usage: $0 [run|cleanup]   (set AUTO_YES=1 to skip the prompt)" ;;
  esac
}
main "$@"

# ==============================================================================
#  SOLUTION  —  step by step (read only after you have tried it yourself)
# ==============================================================================
#
#  DIAGNOSIS
#  ---------
#  1) Confirm the failure and that it is transport-level, not application-level:
#
#         POD=$(kubectl -n s2s-lab get pod -l app=client -o jsonpath='{.items[0].metadata.name}')
#         kubectl -n s2s-lab exec $POD -c curl -- curl -sv http://httpbin:8000/get
#         # 503, "reset reason: connection termination" -> Envoy killed it, app never saw it.
#
#  2) List the security/traffic objects that govern this path. The server side
#     is fine (STRICT is intentional). Look at the client side:
#
#         kubectl -n s2s-lab get peerauthentication,destinationrule
#         # NAME                                        MODE
#         # peerauthentication.../require-mtls          STRICT   <- correct, keep it
#         #
#         # NAME                                        HOST
#         # destinationrule.../httpbin-plaintext        httpbin.s2s-lab.svc.cluster.local
#
#     Inspect the DestinationRule — this is where the client's TLS behaviour is set:
#
#         kubectl -n s2s-lab get destinationrule httpbin-plaintext -o yaml
#         # trafficPolicy.tls.mode: DISABLE   <-- THE BUG.
#         # It orders the client sidecar to send PLAINTEXT to a server that,
#         # per PeerAuthentication STRICT, refuses everything but mTLS.
#
#  3) Confirm the client's effective outbound TLS mode with istioctl (optional):
#
#         istioctl proxy-config cluster $POD -n s2s-lab --fqdn httpbin.s2s-lab.svc.cluster.local -o json \
#           | grep -i '"mode"'      # shows DISABLE, i.e. no client certificate presented.
#
#  ROOT CAUSE
#  ----------
#  mTLS is a two-sided contract. PeerAuthentication (server) says "mTLS only".
#  A DestinationRule (client) overrode the client to "DISABLE" TLS. Server and
#  client no longer agree on the transport, so the handshake is rejected -> 503.
#
#  FIX  —  make the client speak mTLS again, keeping STRICT intact.
#  --------------------------------------------------------------
#  Preferred: the DestinationRule serves no purpose here, so remove it. With no
#  override, Istio auto-negotiates ISTIO_MUTUAL because the destination is in
#  the mesh — the default secure behaviour.
#
#         kubectl -n s2s-lab delete destinationrule httpbin-plaintext
#
#  Alternative (if the DestinationRule is needed for other policy such as load
#  balancing/outlier detection): keep it, but set the TLS mode to ISTIO_MUTUAL
#  so the client presents its mesh-issued certificate:
#
#         kubectl -n s2s-lab patch destinationrule httpbin-plaintext --type merge -p \
#           '{"spec":{"trafficPolicy":{"tls":{"mode":"ISTIO_MUTUAL"}}}}'
#
#  DO NOT "fix" it by relaxing the server:
#         # WRONG — hides the symptom, disables encryption enforcement:
#         # kubectl -n s2s-lab patch peerauthentication require-mtls --type merge \
#         #   -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'
#
#  VERIFY
#  ------
#         sleep 3   # allow config to propagate to the sidecars
#         kubectl -n s2s-lab exec $POD -c curl -- \
#           curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/get
#         # -> 200
#
#     And confirm it is genuinely encrypted (mTLS, not plaintext) end to end:
#         istioctl x describe pod $POD -n s2s-lab   # reports "mTLS: STRICT" on the path
#
#  TAKEAWAY
#  --------
#  Secure service-to-service communication requires BOTH sides to agree. When a
#  STRICT PeerAuthentication is in force, every DestinationRule targeting an
#  in-mesh host must use ISTIO_MUTUAL (or omit tls entirely and let Istio
#  negotiate it). A lone DestinationRule with tls.mode: DISABLE is the classic
#  way an operator accidentally breaks a hardened mesh — and the fix is to
#  align the client, never to weaken the server.
# ==============================================================================