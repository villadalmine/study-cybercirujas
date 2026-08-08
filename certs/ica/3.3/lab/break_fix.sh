#!/usr/bin/env bash
#
# ICA — Topic 3.3: Defining Traffic Policies with Destination Rules
# Break & Fix laboratory — Istio subset / traffic-policy failure
#
# WHAT THIS DOES
#   Deploys a two-version demo app (helloworld v1/v2) into a disposable,
#   mesh-injected namespace, wires a VirtualService that routes 100% of
#   traffic to the "v2" subset, and then installs a DestinationRule that is
#   DELIBERATELY BROKEN: its "v2" subset selects the wrong pod label, so the
#   subset resolves to zero endpoints. The route exists, the cluster exists,
#   but it has no healthy backends behind it.
#
# WHY THIS IS SAFE
#   Everything lives inside a single throwaway namespace (ica-33-lab). It
#   creates no cluster-scoped objects, mutates nothing outside that namespace,
#   and is fully reverted with:  ./break-fix-3.3.sh cleanup
#   Run it ONLY on a disposable lab VM / kind / minikube cluster with Istio.
#
# Official references (read these before you touch anything):
#   - DestinationRule API:
#       https://istio.io/latest/docs/reference/config/networking/destination-rule/
#   - Traffic management concepts (subsets, policies):
#       https://istio.io/latest/docs/concepts/traffic-management/
#   - Debugging 503s / no healthy upstream:
#       https://istio.io/latest/docs/ops/common-problems/network-issues/
#   - istioctl proxy-config (endpoints/cluster/route inspection):
#       https://istio.io/latest/docs/reference/commands/istioctl/
#
set -euo pipefail

NS="ica-33-lab"
APP_HOST="helloworld.${NS}.svc.cluster.local"

# ---- pretty logging -------------------------------------------------------
c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_ylw=$'\033[0;33m'
c_blu=$'\033[0;34m'; c_bld=$'\033[1m';   c_rst=$'\033[0m'
info() { printf '%s[*]%s %s\n'  "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n'  "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$c_ylw" "$c_rst" "$*"; }
err()  { printf '%s[x]%s %s\n'  "$c_red" "$c_rst" "$*" >&2; }

# ---- prerequisites --------------------------------------------------------
require() {
  command -v "$1" >/dev/null 2>&1 || { err "'$1' not found in PATH."; exit 1; }
}

preflight() {
  require kubectl
  require istioctl
  if ! kubectl cluster-info >/dev/null 2>&1; then
    err "No reachable Kubernetes cluster. Point KUBECONFIG at your lab VM."
    exit 1
  fi
  if ! kubectl get ns istio-system >/dev/null 2>&1; then
    err "istio-system namespace not found. Install Istio first:"
    err "  istioctl install --set profile=demo -y"
    exit 1
  fi
  ok "Preflight passed (kubectl, istioctl, cluster, istio-system present)."
}

# ---- cleanup path ---------------------------------------------------------
cleanup() {
  info "Deleting lab namespace '${NS}' (this reverts everything)…"
  kubectl delete ns "${NS}" --ignore-not-found --wait=true
  ok "Lab environment removed."
  exit 0
}

# ---- deploy the working baseline -----------------------------------------
deploy_app() {
  info "Creating namespace '${NS}' with sidecar injection…"
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${NS}" istio-injection=enabled --overwrite >/dev/null

  info "Deploying helloworld v1/v2, the Service, and a client (sleep) pod…"
  kubectl apply -n "${NS}" -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  labels: { app: helloworld, service: helloworld }
spec:
  selector: { app: helloworld }
  ports:
    - name: http
      port: 5000
      targetPort: 5000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld-v1
spec:
  replicas: 1
  selector: { matchLabels: { app: helloworld, version: v1 } }
  template:
    metadata:
      labels: { app: helloworld, version: v1 }
    spec:
      containers:
        - name: helloworld
          image: docker.io/istio/examples-helloworld-v1
          ports: [ { containerPort: 5000 } ]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 128Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld-v2
spec:
  replicas: 1
  selector: { matchLabels: { app: helloworld, version: v2 } }
  template:
    metadata:
      labels: { app: helloworld, version: v2 }
    spec:
      containers:
        - name: helloworld
          image: docker.io/istio/examples-helloworld-v2
          ports: [ { containerPort: 5000 } ]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 128Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
spec:
  replicas: 1
  selector: { matchLabels: { app: sleep } }
  template:
    metadata:
      labels: { app: sleep }
    spec:
      containers:
        - name: curl
          image: curlimages/curl
          command: [ "/bin/sleep", "infinity" ]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 50m, memory: 64Mi }
YAML

  info "Waiting for rollouts (sidecars take a moment to become ready)…"
  kubectl -n "${NS}" rollout status deploy/helloworld-v1 --timeout=180s
  kubectl -n "${NS}" rollout status deploy/helloworld-v2 --timeout=180s
  kubectl -n "${NS}" rollout status deploy/sleep          --timeout=180s
  ok "Baseline application is up."
}

# ---- routing + the controlled fault --------------------------------------
apply_routing_and_break() {
  info "Applying VirtualService (100% of traffic -> subset 'v2')…"
  info "Applying a DestinationRule whose 'v2' subset has a WRONG label."
  kubectl apply -n "${NS}" -f - <<YAML
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: helloworld
spec:
  hosts: [ "helloworld" ]
  http:
    - route:
        - destination:
            host: helloworld
            subset: v2
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: helloworld
spec:
  host: helloworld
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      # >>> INJECTED FAULT <<<
      # This subset selects pods labelled 'version: v2-canary'. No such pod
      # exists — every helloworld-v2 pod is labelled 'version: v2'. The subset
      # (and therefore the Envoy cluster it produces) has ZERO endpoints.
      labels: { version: v2-canary }
YAML
  ok "Routing applied and fault injected."
}

# ---- demonstrate the symptom ---------------------------------------------
show_symptom() {
  info "Generating traffic from the in-mesh client to prove the break…"
  echo
  for i in $(seq 1 5); do
    code="$(kubectl exec -n "${NS}" deploy/sleep -c curl -- \
              curl -s -o /dev/null -w '%{http_code}' \
              "http://helloworld:5000/hello" 2>/dev/null || echo 'ERR')"
    printf '  request %d -> HTTP %s%s%s\n' "$i" "$c_red" "$code" "$c_rst"
  done
  echo
}

print_mission() {
  cat <<EOF
${c_bld}=====================================================================
 ICA 3.3 — BREAK & FIX: Destination Rules and subset traffic policies
=====================================================================${c_rst}

${c_bld}SYMPTOM YOU WILL OBSERVE${c_rst}
  Every request to the 'helloworld' Service returns ${c_red}HTTP 503${c_rst}.
  From the caller's sidecar the response body reads:
      ${c_ylw}no healthy upstream${c_rst}
  Yet:
      * both helloworld-v1 and helloworld-v2 pods are Running and Ready,
      * a direct pod-to-pod curl (bypassing the subset) works fine,
      * 'istioctl analyze -n ${NS}' may report NO error at all.

  Confirm the shape of the failure yourself:
      kubectl -n ${NS} get pods -L version
      istioctl proxy-config cluster   deploy/sleep -n ${NS} | grep helloworld
      istioctl proxy-config endpoints deploy/sleep -n ${NS} \\
          --cluster 'outbound|5000|v2|${APP_HOST}'
      istioctl proxy-config route     deploy/sleep -n ${NS} \\
          --name 5000 -o json | grep -A2 subset

  Read the output carefully: the route sends traffic to subset 'v2', the
  'v2' cluster EXISTS, but its endpoint list is EMPTY.

${c_bld}YOUR GOAL${c_rst}
  Make all requests return ${c_grn}HTTP 200${c_rst} ("Hello version: v2, ...")
  ${c_bld}WITHOUT${c_rst} touching the Deployments, the pod labels, the Service, or the
  VirtualService. The DestinationRule is the only object you are allowed to
  edit. Understand WHY the subset had no endpoints before you change it.

${c_bld}HINTS${c_rst}
  * A subset is nothing more than a named label selector layered on top of
    the Service's endpoints. If the selector matches no pod, the subset is a
    valid-but-empty cluster — hence 503 "no healthy upstream", not a 404.
  * 'kubectl get pods -L version' shows the labels the subset MUST match.
  * There is no syntax error to find. This is a semantic mismatch.

  When you are ready to reset the whole lab:  $0 cleanup

EOF
}

main() {
  case "${1:-run}" in
    cleanup) preflight; cleanup ;;
    run)
      preflight
      deploy_app
      apply_routing_and_break
      show_symptom
      print_mission
      ;;
    *) err "Usage: $0 [run|cleanup]"; exit 2 ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTION — step by step  (do not read until you have tried it yourself)
# =============================================================================
#
#  DIAGNOSIS
#  ---------
#  1. Verify the app itself is healthy (rules out a crashed workload):
#         kubectl -n ica-33-lab get pods -L version
#     Expected: helloworld-v1 (version=v1) and helloworld-v2 (version=v2),
#     both 2/2 Ready (app container + istio-proxy).
#
#  2. Prove the traffic policy — not the app — is at fault. Curl the pod IP
#     directly, bypassing the DestinationRule subset:
#         V2_IP=$(kubectl -n ica-33-lab get pod -l version=v2 \
#                   -o jsonpath='{.items[0].status.podIP}')
#         kubectl -n ica-33-lab exec deploy/sleep -c curl -- \
#             curl -s "http://$V2_IP:5000/hello"
#     Expected: "Hello version: v2, ..."  -> the pod serves fine; routing is
#     the problem.
#
#  3. Show that the 'v2' Envoy cluster has zero endpoints:
#         istioctl proxy-config endpoints deploy/sleep -n ica-33-lab \
#             --cluster 'outbound|5000|v2|helloworld.ica-33-lab.svc.cluster.local'
#     Expected: an EMPTY endpoint list. Compare with subset v1, which is
#     populated. Empty subset cluster == "no healthy upstream" == 503.
#
#  4. Read the DestinationRule and spot the mismatch between the subset's
#     label selector and the real pod labels:
#         kubectl -n ica-33-lab get destinationrule helloworld -o yaml
#     Subset 'v2' selects 'version: v2-canary'; the pods carry 'version: v2'.
#
#  FIX
#  ---
#  Correct the subset selector so it matches the actual pods. The clean,
#  declarative fix (idempotent — safe to re-run):
#
#      kubectl apply -n ica-33-lab -f - <<'EOF'
#      apiVersion: networking.istio.io/v1
#      kind: DestinationRule
#      metadata:
#        name: helloworld
#      spec:
#        host: helloworld
#        subsets:
#          - name: v1
#            labels: { version: v1 }
#          - name: v2
#            labels: { version: v2 }      # was: v2-canary  <-- the fix
#      EOF
#
#  (Equivalent quick edit:  kubectl -n ica-33-lab edit destinationrule helloworld
#   and change v2-canary -> v2.)
#
#  VERIFY
#  ------
#      # Endpoints now populated:
#      istioctl proxy-config endpoints deploy/sleep -n ica-33-lab \
#          --cluster 'outbound|5000|v2|helloworld.ica-33-lab.svc.cluster.local'
#
#      # Traffic now succeeds and is pinned to v2:
#      for i in $(seq 1 5); do
#        kubectl -n ica-33-lab exec deploy/sleep -c curl -- \
#            curl -s http://helloworld:5000/hello
#      done
#      # Expected: five lines of "Hello version: v2, instance: ..." (HTTP 200)
#
#  KEY TAKEAWAYS
#  -------------
#  * A VirtualService can only route to a subset that a DestinationRule
#    defines; the DestinationRule is what turns Service endpoints into named,
#    policy-bearing subsets. A subset whose labels match nothing is a valid
#    object that yields an empty cluster and a 503 — the config "works" but
#    routes into a void.
#  * 'istioctl analyze' checks references and schema, not whether a selector
#    actually matches live pods. Endpoint-level truth comes from
#    'istioctl proxy-config endpoints'. Always descend to the data plane.
#  * DestinationRules also carry trafficPolicy blocks (loadBalancer,
#    connectionPool, outlierDetection, tls). Other common self-inflicted
#    3.3 outages worth practising on this same lab:
#      - tls.mode: DISABLE on the client DR while the server enforces STRICT
#        PeerAuthentication  -> 503 UC / upstream reset (mTLS mismatch).
#      - connectionPool.http.http1MaxPendingRequests: 1 + maxConnections: 1
#        under load  -> 503 UO (upstream overflow / circuit broken).
#      - Aggressive outlierDetection ejecting the only endpoint -> 503.
#    See https://istio.io/latest/docs/reference/config/networking/destination-rule/
# =============================================================================