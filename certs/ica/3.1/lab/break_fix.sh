#!/usr/bin/env bash
#
# ica-3.1-break-and-fix.sh
# Certification : ICA (Istio Certified Associate)
# Topic         : 3.1 Configuring Ingress and Egress Traffic (exam weight: 5)
#
# WHAT THIS IS
#   A self-contained "break & fix" lab. It stands up a known-good ingress path
#   (Gateway + VirtualService + httpbin), PROVES it returns HTTP 200, then
#   introduces ONE controlled, fully reversible misconfiguration. Your job is to
#   diagnose the failure and restore end-to-end HTTP 200 through the Istio
#   ingress gateway. The step-by-step solution is at the very bottom, commented.
#
#   Everything the lab creates lives in a single dedicated namespace
#   (ica-lab-31) plus one patch to a Gateway that the lab itself owns. Nothing
#   in istio-system is mutated. Blast radius is contained; `cleanup` removes it.
#
# RUN THIS ONLY ON A DISPOSABLE LAB VM / THROWAWAY CLUSTER.
#
# PREREQUISITES
#   - A Kubernetes cluster you can throw away (kind / minikube / k3d).
#   - Istio installed with the default ingress gateway
#     (`istioctl install --set profile=demo -y`).
#   - kubectl, istioctl and curl on PATH.
#
# USAGE
#   ./ica-3.1-break-and-fix.sh run        # setup, verify 200, then break it (default)
#   ./ica-3.1-break-and-fix.sh verify     # probe the ingress path, print HTTP code
#   ./ica-3.1-break-and-fix.sh fix        # apply the intended fix (instructor/reset)
#   ./ica-3.1-break-and-fix.sh cleanup    # delete everything the lab created
#
# OFFICIAL SOURCES
#   Ingress control        https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
#   Egress control         https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
#   Gateway reference      https://istio.io/latest/docs/reference/config/networking/gateway/
#   VirtualService ref     https://istio.io/latest/docs/reference/config/networking/virtual-service/
#   istioctl analyze       https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
#   Analyzer IST0101       https://istio.io/latest/docs/reference/config/analysis/ist0101/
#   ServiceEntry reference https://istio.io/latest/docs/reference/config/networking/service-entry/

set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
NS="ica-lab-31"                 # lab namespace (single blast radius)
ISTIO_NS="istio-system"         # where the ingress gateway lives
ISTIO_GW_SVC="istio-ingressgateway"
GOOD_SELECTOR="ingressgateway"  # value of the `istio` label on ingress pods
BAD_SELECTOR="ingressgateway-BROKEN"
GW_NAME="httpbin-gw"
VS_NAME="httpbin-vs"
VS_HOST="httpbin.example.com"
LOCAL_PORT="18080"              # local port used for port-forward probing

# --------------------------------------------------------------------------- #
# Logging helpers
# --------------------------------------------------------------------------- #
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_bld=$'\033[1m'
info()  { printf '%s[i]%s %s\n' "$c_cya" "$c_reset" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$c_yel" "$c_reset" "$*"; }
err()   { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
rule()  { printf '%s----------------------------------------------------------------------%s\n' "$c_cya" "$c_reset"; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
preflight() {
  local bin
  for bin in kubectl istioctl curl; do
    command -v "$bin" >/dev/null 2>&1 || { err "'$bin' not found on PATH."; exit 1; }
  done
  kubectl cluster-info >/dev/null 2>&1 || { err "No reachable Kubernetes cluster (check KUBECONFIG)."; exit 1; }
  kubectl -n "$ISTIO_NS" get deploy istiod >/dev/null 2>&1 || { err "istiod not found in $ISTIO_NS — is Istio installed?"; exit 1; }
  kubectl -n "$ISTIO_NS" get svc "$ISTIO_GW_SVC" >/dev/null 2>&1 || { err "Service $ISTIO_GW_SVC not found in $ISTIO_NS."; exit 1; }

  # Auto-detect the real ingress selector so the fix is precise across profiles.
  local detected
  detected="$(kubectl -n "$ISTIO_NS" get pods -l "istio=$GOOD_SELECTOR" \
    -o jsonpath='{.items[0].metadata.labels.istio}' 2>/dev/null || true)"
  if [ -n "$detected" ]; then
    GOOD_SELECTOR="$detected"
  else
    warn "Could not confirm ingress pod label 'istio'; assuming '$GOOD_SELECTOR'."
  fi
  ok "Preflight passed (ingress selector: istio=$GOOD_SELECTOR)."
}

# --------------------------------------------------------------------------- #
# Probe: curl the ingress gateway via an ephemeral port-forward.
# Prints the HTTP status code (or 000 on connection failure).
# --------------------------------------------------------------------------- #
ingress_curl() {
  local path="${1:-/status/200}" code pf
  kubectl -n "$ISTIO_NS" port-forward "svc/$ISTIO_GW_SVC" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
  pf=$!
  # Wait for the tunnel to accept connections (a 404 here still proves it's up).
  local up=""
  local i
  for i in $(seq 1 20); do
    if curl -s -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/" 2>/dev/null; then up=1; break; fi
    sleep 0.5
  done
  if [ -z "$up" ]; then code="000"; else
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Host: ${VS_HOST}" \
      "http://127.0.0.1:${LOCAL_PORT}${path}" 2>/dev/null || echo '000')"
  fi
  kill "$pf" >/dev/null 2>&1 || true
  wait "$pf" 2>/dev/null || true
  echo "$code"
}

wait_for_code() {
  # wait_for_code <expected> <tries>
  local expected="$1" tries="${2:-24}" code="000" i
  for i in $(seq 1 "$tries"); do
    code="$(ingress_curl /status/200)"
    [ "$code" = "$expected" ] && { echo "$code"; return 0; }
    sleep 5
  done
  echo "$code"; return 1
}

# --------------------------------------------------------------------------- #
# Setup: deploy the known-good ingress path.
# --------------------------------------------------------------------------- #
setup() {
  info "Creating namespace $NS with sidecar injection enabled..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

  info "Deploying httpbin backend..."
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: $NS
  labels: { app: httpbin, service: httpbin }
spec:
  ports:
    - name: http
      port: 8000
      targetPort: 80
  selector: { app: httpbin }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels: { app: httpbin, version: v1 }
  template:
    metadata:
      labels: { app: httpbin, version: v1 }
    spec:
      containers:
        - name: httpbin
          image: docker.io/kong/httpbin
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
YAML

  info "Publishing the ingress path (Gateway + VirtualService)..."
  kubectl apply -f - >/dev/null <<YAML
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: $GW_NAME
  namespace: $NS
spec:
  selector:
    istio: $GOOD_SELECTOR
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "$VS_HOST"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: $VS_NAME
  namespace: $NS
spec:
  hosts:
    - "$VS_HOST"
  gateways:
    - $GW_NAME
  http:
    - match:
        - uri: { prefix: /status }
        - uri: { prefix: /headers }
      route:
        - destination:
            host: httpbin
            port:
              number: 8000
YAML

  info "Waiting for httpbin to become ready..."
  kubectl -n "$NS" rollout status deploy/httpbin --timeout=120s >/dev/null
  ok "Backend and ingress resources applied."
}

verify_healthy() {
  info "Probing the ingress path (expecting HTTP 200)..."
  local code
  if code="$(wait_for_code 200 24)"; then
    ok "Ingress path healthy: curl -H 'Host: $VS_HOST' .../status/200 -> $code"
    return 0
  else
    err "Ingress path is NOT healthy (last code: $code)."
    return 1
  fi
}

# --------------------------------------------------------------------------- #
# The controlled break: point the Gateway selector at a workload that does
# not exist. istiod then has no gateway workload to program with this config,
# so the ingress gateway loses the server/route for $VS_HOST.
# This edits ONLY the Gateway this lab created. It is fully reversible.
# --------------------------------------------------------------------------- #
do_break() {
  rule
  info "Introducing a controlled fault into Gateway/$GW_NAME ..."
  kubectl -n "$NS" patch gateway "$GW_NAME" --type merge \
    -p "{\"spec\":{\"selector\":{\"istio\":\"$BAD_SELECTOR\"}}}" >/dev/null
  ok "Fault injected."
  sleep 6  # let the config distribution settle

  local code; code="$(ingress_curl /status/200)"
  rule
  printf '%s%sICA 3.1 — BREAK & FIX: your incident starts now%s\n' "$c_bld" "$c_yel" "$c_reset"
  rule
  cat <<BRIEF

  SYMPTOM
    A request that returned 200 a moment ago now fails:

      \$ curl -s -o /dev/null -w '%{http_code}\n' \\
          -H 'Host: $VS_HOST' http://<ingress-gateway>/status/200
      $code            <-- observed now (was 200)

    A 404 here means the ingress gateway has NO listener/route serving
    host '$VS_HOST'. The backend pod is healthy; the app never sees the
    request. The break is in the ingress *configuration plane*, not the app.

  OBJECTIVE
    Restore end-to-end HTTP 200 through the Istio ingress gateway.
    Constraints:
      - Do NOT delete/recreate the namespace or re-run this script's setup.
      - Fix the actual misconfiguration in place, then prove 200:
            ./$(basename "$0") verify

  WHERE TO LOOK (suggested diagnostic ladder)
    1. Ask Istio's own analyzer first — it usually names the fault:
         istioctl analyze -n $NS
    2. Read the Gateway you own and inspect its selector:
         kubectl -n $NS get gateway $GW_NAME -o yaml
    3. Compare that selector to the labels the ingress pods actually carry:
         kubectl -n $ISTIO_NS get pods -l istio=$GOOD_SELECTOR --show-labels
    4. Confirm from Envoy's side that the route/listener is gone:
         istioctl proxy-config listeners deploy/$ISTIO_GW_SVC -n $ISTIO_NS --port 80
         istioctl proxy-config routes    deploy/$ISTIO_GW_SVC -n $ISTIO_NS

  When you think it's fixed:
         ./$(basename "$0") verify         # must print 200
  If you get stuck, the full solution is at the bottom of this script.

BRIEF
  rule
}

# --------------------------------------------------------------------------- #
# The intended fix (also used for `fix` / instructor reset).
# --------------------------------------------------------------------------- #
do_fix() {
  info "Restoring Gateway selector to istio=$GOOD_SELECTOR ..."
  kubectl -n "$NS" patch gateway "$GW_NAME" --type merge \
    -p "{\"spec\":{\"selector\":{\"istio\":\"$GOOD_SELECTOR\"}}}" >/dev/null
  ok "Selector restored."
}

cleanup() {
  info "Deleting namespace $NS (removes all lab resources)..."
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null
  ok "Lab cleaned up. istio-system was never modified."
}

usage() {
  sed -n '2,40p' "$0"
}

main() {
  case "${1:-run}" in
    run)     preflight; setup; verify_healthy; do_break ;;
    verify)  preflight; verify_healthy ;;
    fix)     preflight; do_fix; verify_healthy ;;
    cleanup) cleanup ;;
    -h|--help|help) usage ;;
    *) err "Unknown command: $1"; usage; exit 2 ;;
  esac
}

main "$@"

# ===========================================================================
# SOLUTION — step by step (do not peek until you have tried)
# ===========================================================================
#
# ROOT CAUSE
#   The Gateway resource selects the gateway *workload* it configures via
#   `spec.selector`. The break set it to `istio: ingressgateway-BROKEN`, which
#   matches no pod. With no matching workload, istiod pushes this Gateway's
#   server (port 80, host httpbin.example.com) to nobody. The ingress gateway
#   Envoy therefore has no route for that host and answers 404. The backend is
#   fine — this is purely a control-plane selector mismatch.
#
# 1) Let the analyzer point at it:
#      istioctl analyze -n ica-lab-31
#    Expected finding (IST0101, "Referenced selector not found"):
#      Warning [IST0101] (Gateway ica-lab-31/httpbin-gw) Referenced selector
#      not found: "istio=ingressgateway-BROKEN"
#
# 2) Confirm the mismatch by hand:
#      kubectl -n ica-lab-31 get gateway httpbin-gw \
#        -o jsonpath='{.spec.selector}{"\n"}'
#        => {"istio":"ingressgateway-BROKEN"}
#      kubectl -n istio-system get pods -l istio=ingressgateway --show-labels
#        => pods carry the label  istio=ingressgateway   (NOT ...-BROKEN)
#
# 3) (Optional, prove it from Envoy) — the listener/route for the host is gone:
#      istioctl proxy-config routes deploy/istio-ingressgateway -n istio-system \
#        | grep -i httpbin        # returns nothing while broken
#
# 4) Fix in place — restore the selector so it matches the ingress pods:
#      kubectl -n ica-lab-31 patch gateway httpbin-gw --type merge \
#        -p '{"spec":{"selector":{"istio":"ingressgateway"}}}'
#    (Equivalent: `kubectl -n ica-lab-31 edit gateway httpbin-gw` and correct
#     the selector value.)
#
# 5) Verify recovery (config push takes a few seconds):
#      kubectl -n istio-system port-forward svc/istio-ingressgateway 18080:80 &
#      curl -s -o /dev/null -w '%{http_code}\n' \
#        -H 'Host: httpbin.example.com' http://127.0.0.1:18080/status/200
#        => 200
#      istioctl proxy-config routes deploy/istio-ingressgateway -n istio-system \
#        | grep -i httpbin        # the route is back
#    Or simply:  ./ica-3.1-break-and-fix.sh verify
#
# KEY TAKEAWAYS
#   - Gateway.spec.selector must equal a LABEL that real gateway pods carry;
#     a typo silently removes the listener with no error on apply.
#   - `istioctl analyze` catches selector/binding faults that `kubectl apply`
#     accepts happily. Make it the first reflex on any ingress incident.
#   - HTTP 404 at the gateway => no matching route/listener (config plane).
#     HTTP 503 => route exists but no healthy upstream (destination/cluster).
#     Read Envoy's view with `istioctl proxy-config {listeners,routes,clusters}`.
#
# ---------------------------------------------------------------------------
# BONUS DRILL — the EGRESS half of topic 3.1 (optional; run manually)
# ---------------------------------------------------------------------------
#   By default Istio's outbound policy is ALLOW_ANY, so meshed pods can reach
#   the internet. Production meshes often lock this to REGISTRY_ONLY so only
#   explicitly declared external hosts are reachable. To practice:
#
#   BREAK — deny undeclared egress:
#     istioctl install --set profile=demo \
#       --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
#     kubectl -n ica-lab-31 exec deploy/httpbin -c istio-proxy -- \
#       curl -sS -o /dev/null -w '%{http_code}\n' https://httpbin.org/get
#       => 502 (BlackHoleCluster: the host is not in the mesh registry)
#
#   FIX — declare the external host with a ServiceEntry:
#     kubectl apply -f - <<'EOF'
#     apiVersion: networking.istio.io/v1beta1
#     kind: ServiceEntry
#     metadata:
#       name: allow-httpbin-org
#       namespace: ica-lab-31
#     spec:
#       hosts: ["httpbin.org"]
#       ports:
#         - number: 443
#           name: https
#           protocol: TLS
#       resolution: DNS
#       location: MESH_EXTERNAL
#     EOF
#     # re-run the curl above => 200
#
#   RESET egress back to permissive:
#     istioctl install --set profile=demo \
#       --set meshConfig.outboundTrafficPolicy.mode=ALLOW_ANY -y
#
# ===========================================================================