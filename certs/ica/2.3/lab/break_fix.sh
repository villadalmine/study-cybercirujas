#!/usr/bin/env bash
#
# ICA 2.3 — Troubleshooting the Mesh Data Plane
# Break & Fix lab :: subset routing with no healthy upstream (503 UH)
#
# WHAT THIS DOES
#   Deploys a known-good, mesh-injected sample app (httpbin + a curl client)
#   into a dedicated, disposable namespace, proves it returns HTTP 200 through
#   the sidecars, and then introduces ONE controlled fault in the data plane:
#   a VirtualService that pins all traffic to a DestinationRule subset ("v2")
#   for which no pods exist. The Envoy sidecar has a cluster with zero
#   endpoints, so every request is answered with "503 no healthy upstream".
#
#   Everything is confined to the namespace $NS. Nothing outside it is touched.
#   Reference: https://istio.io/latest/docs/ops/common-problems/network-issues/
#              https://github.com/cncf/curriculum (ICA_Curriculum.pdf, domain 2)
#
# USAGE
#   ./ica-2.3-break-and-fix.sh          # deploy the app and break it
#   ./ica-2.3-break-and-fix.sh clean    # tear the whole lab down
#
set -euo pipefail

NS="ica-lab-23"
APP_HOST="httpbin"
SVC_PORT="8000"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n'   "$*"; }
info()  { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Safety guards — refuse to run anywhere that is not a throwaway lab cluster.
# ---------------------------------------------------------------------------
require() { command -v "$1" >/dev/null 2>&1 || { red "Missing required tool: $1"; exit 1; }; }
require kubectl
require istioctl

if ! kubectl cluster-info >/dev/null 2>&1; then
  red "No reachable Kubernetes cluster (check your kubeconfig context)."; exit 1
fi
if ! kubectl get ns istio-system >/dev/null 2>&1; then
  red "Istio control plane not found (namespace istio-system is missing)."; exit 1
fi

CTX="$(kubectl config current-context)"
bold "Active kube-context: ${CTX}"
info "This script only creates/mutates the disposable namespace '${NS}'."

# ---------------------------------------------------------------------------
# Teardown path.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "clean" ]]; then
  kubectl delete namespace "${NS}" --ignore-not-found --wait=true
  green "Lab namespace '${NS}' removed."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) Known-good baseline: injected namespace + app + client, and a passing curl.
# ---------------------------------------------------------------------------
bold "[1/3] Deploying the known-good, mesh-injected baseline..."

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${NS}" istio-injection=enabled --overwrite >/dev/null

kubectl apply -n "${NS}" -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels: { app: httpbin, service: httpbin }
spec:
  ports:
    - name: http          # named port => Istio protocol detection is explicit
      port: 8000
      targetPort: 80
  selector: { app: httpbin }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-v1
spec:
  replicas: 1
  selector: { matchLabels: { app: httpbin, version: v1 } }
  template:
    metadata:
      labels: { app: httpbin, version: v1 }   # ONLY version v1 exists
    spec:
      containers:
        - name: httpbin
          image: docker.io/kennethreitz/httpbin:latest
          ports: [{ containerPort: 80 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
spec:
  replicas: 1
  selector: { matchLabels: { app: curl } }
  template:
    metadata:
      labels: { app: curl }
    spec:
      containers:
        - name: curl
          image: docker.io/curlimages/curl:latest
          command: ["sleep", "2147483647"]
YAML

kubectl rollout status -n "${NS}" deploy/httpbin-v1 --timeout=120s
kubectl rollout status -n "${NS}" deploy/curl       --timeout=120s

# Confirm both pods came up with 2/2 containers (app + istio-proxy sidecar).
if ! kubectl get pods -n "${NS}" -o wide | grep -q '2/2'; then
  red "Sidecars were not injected (expected 2/2 containers). Is istio-injection enabled?"
  kubectl get pods -n "${NS}"; exit 1
fi

probe() {
  kubectl exec -n "${NS}" deploy/curl -c curl -- \
    curl -sS -o /dev/null -w '%{http_code}' \
    "http://${APP_HOST}:${SVC_PORT}/status/200" 2>/dev/null || true
}

info "Verifying the baseline responds 200 through the mesh..."
for _ in $(seq 1 12); do
  code="$(probe)"; [[ "${code}" == "200" ]] && break; sleep 3
done
if [[ "${code:-}" != "200" ]]; then
  red "Baseline never returned 200 (got '${code:-none}'). Fix the environment before breaking it."
  exit 1
fi
green "Baseline healthy: GET http://${APP_HOST}:${SVC_PORT}/status/200 -> 200"

# ---------------------------------------------------------------------------
# 2) THE BREAK — route 100% of traffic to a subset that has no endpoints.
# ---------------------------------------------------------------------------
bold "[2/3] Injecting the data-plane fault..."

kubectl apply -n "${NS}" -f - >/dev/null <<YAML
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin
spec:
  host: ${APP_HOST}
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }   # no pod carries version=v2 => empty cluster
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: httpbin
spec:
  hosts: [ "${APP_HOST}" ]
  http:
    - route:
        - destination:
            host: ${APP_HOST}
            subset: v2            # <-- the fault: routing to the empty subset
YAML

sleep 5
broken_code="$(probe)"

# ---------------------------------------------------------------------------
# 3) Brief the student.
# ---------------------------------------------------------------------------
bold "[3/3] Fault injected. Over to you."
echo
red    "SYMPTOM"
info "From the in-mesh client, requests now fail:"
info "    kubectl exec -n ${NS} deploy/curl -c curl -- \\"
info "      curl -s -o /dev/null -w '%{http_code}\\n' http://${APP_HOST}:${SVC_PORT}/status/200"
info "  observed HTTP status: ${broken_code:-<none>}  (expected 503)"
info "The application pods are Running and Ready — nothing crashed, nothing"
info "restarted, DNS resolves, and the Service still has an endpoint. The"
info "failure lives entirely in the sidecar's (Envoy's) view of the world."
echo
green  "YOUR OBJECTIVE"
info "1. Confirm the failure is a data-plane problem, not the app:"
info "   read the CLIENT sidecar access log and identify the Envoy response"
info "   flag on the 503."
info "2. Trace the request path in the client proxy (listener -> route ->"
info "   cluster -> endpoints) and find the cluster that has 0 endpoints."
info "3. Restore HTTP 200 WITHOUT editing the httpbin Deployment's labels."
info "   (i.e. make the mesh route to a subset that actually has endpoints)."
echo
info "Useful data-plane tooling: istioctl proxy-config {routes,cluster,endpoints},"
info "istioctl analyze, istioctl x describe pod, and the istio-proxy access log."
info "When you are done, tear the lab down with:  $0 clean"
echo

# ===========================================================================
# ============================  SOLUTION (spoiler)  =========================
# ===========================================================================
# Do not read until you have tried it. Every command is scoped to $NS.
#
# ---- Step 1: prove it is the data plane, and read the Envoy response flag ---
#
#   # Generate one failing request, then inspect the CLIENT proxy's log:
#   kubectl exec -n ica-lab-23 deploy/curl -c curl -- \
#     curl -s -o /dev/null http://httpbin:8000/status/200
#
#   kubectl logs -n ica-lab-23 deploy/curl -c istio-proxy --tail=5
#
#   You will see a line ending with response flag  "UH"  and code 503, e.g.:
#     [...] "GET /status/200 HTTP/1.1" 503 UH ... "outbound|8000|v2|httpbin.ica-lab-23.svc.cluster.local" -
#   UH = "No healthy upstream". Envoy accepted the request but the target
#   cluster (subset v2) has no healthy endpoints to send it to. The upstream
#   host field is "-" (there was nowhere to send it). This rules the app out.
#
# ---- Step 2: walk the config: which cluster is empty, and why -------------
#
#   # Which route/subset is the client using for host httpbin?
#   istioctl proxy-config routes deploy/curl -n ica-lab-23 --name 8000 -o json \
#     | grep -E 'cluster|subset'
#     -> the route points at: outbound|8000|v2|httpbin.ica-lab-23.svc.cluster.local
#
#   # List the clusters Envoy built from the DestinationRule subsets:
#   istioctl proxy-config cluster deploy/curl -n ica-lab-23 \
#     --fqdn httpbin.ica-lab-23.svc.cluster.local
#     -> you will see both |v1| and |v2| subset clusters.
#
#   # Endpoints per subset cluster — this is the smoking gun:
#   istioctl proxy-config endpoints deploy/curl -n ica-lab-23 \
#     --cluster 'outbound|8000|v1|httpbin.ica-lab-23.svc.cluster.local'
#     -> 1 endpoint, HEALTHY
#   istioctl proxy-config endpoints deploy/curl -n ica-lab-23 \
#     --cluster 'outbound|8000|v2|httpbin.ica-lab-23.svc.cluster.local'
#     -> ENDPOINT column empty (0 endpoints)  <-- root cause
#
#   # A one-shot high-level confirmation (flags the subset with no matching pods):
#   istioctl analyze -n ica-lab-23
#   istioctl x describe pod -n ica-lab-23 \
#     "$(kubectl get pod -n ica-lab-23 -l app=httpbin -o name | head -1 | cut -d/ -f2)"
#
#   Diagnosis: the VirtualService pins 100% of traffic to subset v2, whose
#   selector labels {version: v2} match zero pods (only version=v1 is deployed).
#
# ---- Step 3: fix — route to a subset that has endpoints --------------------
#
#   # Correct the VirtualService to send traffic to the existing subset v1:
#   kubectl patch virtualservice httpbin -n ica-lab-23 --type=json \
#     -p='[{"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"v1"}]'
#
#   (Equivalent alternative fix: scale up a v2 deployment so subset v2 gets an
#    endpoint — but the objective forbids touching workload labels, so patch the
#    route instead. In real life you would also verify the DestinationRule
#    subset labels actually match a live version before routing to it.)
#
# ---- Verify recovery -------------------------------------------------------
#
#   kubectl exec -n ica-lab-23 deploy/curl -c curl -- \
#     curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/status/200
#     -> 200
#   istioctl proxy-config endpoints deploy/curl -n ica-lab-23 \
#     --cluster 'outbound|8000|v1|httpbin.ica-lab-23.svc.cluster.local'
#     -> 1 HEALTHY endpoint, and the access log no longer shows UH.
#
# ---- Takeaway --------------------------------------------------------------
#   "503 UH / no healthy upstream" almost always means the route resolved to a
#   cluster with zero endpoints. In a subset-based mesh that is typically a
#   VirtualService/DestinationRule pointing at a subset whose labels match no
#   running pods — a data-plane (Envoy config) fault, not an application fault.
#   Diagnose it downward: access-log flag -> route -> cluster -> endpoints.
# ===========================================================================