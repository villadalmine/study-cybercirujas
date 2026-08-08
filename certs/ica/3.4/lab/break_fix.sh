#!/usr/bin/env bash
#
# ICA — Istio Certified Associate
# Domain 3: Traffic Management
# Topic 3.4: Configuring Traffic Shifting (exam weight: 5)
#
# BREAK & FIX lab — controlled, reversible breakage on a DISPOSABLE lab VM.
#
# What this script does:
#   1. Builds a clean, isolated mesh workload in its own namespace.
#   2. Configures a healthy 80/20 weighted traffic split (v1/v2) — the
#      canonical "traffic shifting" primitive: VirtualService weights over
#      DestinationRule subsets.
#   3. Proves the split works (baseline traffic sample).
#   4. Introduces ONE subtle, safe misconfiguration.
#   5. Tells you the symptom you will observe and the objective you must reach.
#   6. Leaves the cluster broken for you to diagnose and repair.
#
# The step-by-step ANSWER KEY is at the very bottom, fully commented out.
# Do not read it until you have tried to fix the break yourself.
#
# Requirements (all provided by a standard Istio lab VM):
#   - A throwaway Kubernetes cluster (kind/minikube/k3d) — NOT production.
#   - Istio installed with a working sidecar injector (istiod running).
#   - kubectl in PATH. istioctl recommended (used in the solution).
#
# Sources (official):
#   - CNCF ICA Curriculum:
#       https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#   - Traffic shifting:
#       https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
#   - Request routing / subsets:
#       https://istio.io/latest/docs/tasks/traffic-management/request-routing/
#   - DestinationRule / VirtualService API:
#       https://istio.io/latest/docs/reference/config/networking/destination-rule/
#       https://istio.io/latest/docs/reference/config/networking/virtual-service/
#   - Diagnosing config with istioctl:
#       https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
#       https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
#
# NOTE: intentionally NO 'set -e'. Once the break is applied, ~1 in 5 curls
# returns HTTP 503 on purpose; a non-zero exit there is expected, not fatal.
set -uo pipefail

NS="ica-traffic-lab"
APP="helloworld"
SVC_PORT="5000"
CLIENT="curlclient"
FQDN="${APP}.${NS}.svc.cluster.local"

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Preflight — refuse to run anywhere that is not a disposable lab.
# ---------------------------------------------------------------------------
log "Preflight checks"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl cluster-info >/dev/null 2>&1 || die "No reachable Kubernetes cluster."

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
info "Active context: ${CTX}"
case "${CTX}" in
  *prod*|*production*) die "Context looks like PRODUCTION. Aborting. Use a throwaway VM." ;;
esac

if ! kubectl -n istio-system get deploy istiod >/dev/null 2>&1; then
  warn "istiod not found in istio-system. Istio must be installed for this lab."
  die  "Install Istio first (e.g. 'istioctl install --set profile=demo -y')."
fi
command -v istioctl >/dev/null 2>&1 || warn "istioctl not found — needed for the solution's proxy-config diagnostics."

# ---------------------------------------------------------------------------
# 1. Isolated namespace with automatic sidecar injection.
#    (Idempotent: safe to re-run.)
# ---------------------------------------------------------------------------
log "Creating isolated namespace '${NS}' with sidecar injection"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Classic injection label. If your mesh uses revisions, replace with:
#   kubectl label ns ${NS} istio.io/rev=<your-revision> --overwrite
kubectl label namespace "${NS}" istio-injection=enabled --overwrite >/dev/null
info "Namespace ready and labeled for injection."

# ---------------------------------------------------------------------------
# 2. Workload: two versions behind one Service, plus a curl client.
#    The Service selector matches BOTH versions (app=helloworld); the
#    DestinationRule subsets are what split them apart. This is the exact
#    shape traffic shifting operates on.
# ---------------------------------------------------------------------------
log "Deploying workload (helloworld v1 + v2) and traffic client"
kubectl apply -n "${NS}" -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  labels: { app: helloworld }
spec:
  selector: { app: helloworld }
  ports:
    - name: http          # Istio needs the 'http' prefix for L7 protocol selection
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
          image: docker.io/istio/examples-helloworld-v1:1.0
          ports: [ { containerPort: 5000 } ]
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
          image: docker.io/istio/examples-helloworld-v2:1.0
          ports: [ { containerPort: 5000 } ]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curlclient
spec:
  replicas: 1
  selector: { matchLabels: { app: curlclient } }
  template:
    metadata:
      labels: { app: curlclient }
    spec:
      containers:
        - name: curl
          image: curlimages/curl:8.8.0
          command: ["sleep", "infinity"]
YAML

info "Waiting for rollouts (sidecars are injected on pod creation)..."
kubectl -n "${NS}" rollout status deploy/helloworld-v1 --timeout=150s || die "v1 did not become ready."
kubectl -n "${NS}" rollout status deploy/helloworld-v2 --timeout=150s || die "v2 did not become ready."
kubectl -n "${NS}" rollout status deploy/curlclient   --timeout=150s || die "client did not become ready."

# ---------------------------------------------------------------------------
# 3. Healthy traffic-shifting config: 80% v1 / 20% v2.
# ---------------------------------------------------------------------------
log "Applying HEALTHY traffic shifting: 80% v1 / 20% v2"
kubectl apply -n "${NS}" -f - >/dev/null <<'YAML'
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: helloworld
spec:
  host: helloworld
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: helloworld
spec:
  hosts: [ helloworld ]
  http:
    - route:
        - destination: { host: helloworld, subset: v1 }
          weight: 80
        - destination: { host: helloworld, subset: v2 }
          weight: 20
YAML
info "Config accepted. Giving Envoy a moment to converge..."
sleep 6

# ---------------------------------------------------------------------------
# Traffic sampler — sends N requests from inside the mesh and tallies
# HTTP codes and served versions.
# ---------------------------------------------------------------------------
gen_traffic() {
  local n="${1:-50}"
  kubectl -n "${NS}" exec deploy/${CLIENT} -c curl -- sh -c "
    for i in \$(seq 1 ${n}); do
      code=\$(curl -s -o /tmp/body -w '%{http_code}' http://${APP}:${SVC_PORT}/hello)
      ver=\$(grep -o 'version: v[0-9a-z-]*' /tmp/body 2>/dev/null | head -1 | awk '{print \$2}')
      echo \"\$code \${ver:-none}\"
    done
  " 2>/dev/null
}

summarize() {
  awk '
    { total++; codes[$1]++; if ($1==200) served[$2]++ }
    END {
      printf "   requests: %d\n", total
      printf "   HTTP codes:"; for (c in codes) printf " %s=%d", c, codes[c]; printf "\n"
      printf "   served 200s:"; for (v in served) printf " %s=%d", v, served[v]; printf "\n"
    }'
}

log "Baseline sample (expect ~80% v1 / ~20% v2, all HTTP 200)"
gen_traffic 50 | summarize

# ---------------------------------------------------------------------------
# 4. THE CONTROLLED BREAK
#    We do NOT touch the VirtualService weights. Instead we make the v2
#    subset in the DestinationRule select a label that no pod carries
#    (version: v2-broken). The subset still EXISTS (so 'istioctl analyze'
#    will not flag it), but the resulting Envoy cluster has zero endpoints.
#    The 20% of traffic the VirtualService still sends there now has nowhere
#    to land.
# ---------------------------------------------------------------------------
log "Introducing controlled break (subset v2 -> non-existent label)"
kubectl -n "${NS}" patch destinationrule helloworld --type=json \
  -p '[{"op":"replace","path":"/spec/subsets/1/labels/version","value":"v2-broken"}]' >/dev/null
info "Break applied. Letting Envoy reconverge..."
sleep 6

log "Post-break sample (watch the 503s appear)"
gen_traffic 50 | summarize

# ---------------------------------------------------------------------------
# 5. Brief the student.
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
 SYMPTOM
   Roughly 1 request in 5 (~20%) now returns HTTP 503 ("no healthy upstream").
   Every SUCCESSFUL response is "version: v1" — the v2 canary has effectively
   vanished, even though 'kubectl get vs helloworld -o yaml' still shows a
   20% weight pointing at subset v2, and both v2 pods are Running and Ready.
   The failure rate tracks the traffic-shift weight, not pod health.

 CONSTRAINTS / OBJECTIVE
   Restore a 100% success rate while KEEPING the intended 80/20 v1/v2 split.
   You may NOT change the VirtualService weights. The routing intent is
   correct; the routing TARGET is what is wrong. Make subset v2 resolve to
   real endpoints again.

 START HERE
   NS=${NS}
   # generate traffic on demand:
   kubectl -n \$NS exec deploy/${CLIENT} -c curl -- \\
     sh -c 'for i in \$(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\\n" \\
       http://${APP}:${SVC_PORT}/hello; done'

 Success = 20/20 requests return 200, and a larger sample shows both v1 and v2.
============================================================================

EOF

info "Lab is now in the BROKEN state. Diagnose and fix it. Answer key below."
exit 0

# ###########################################################################
# #                    SOLUTION — ANSWER KEY (do not peek early)           #
# ###########################################################################
#
# MENTAL MODEL
#   Traffic shifting is two objects working together:
#     - VirtualService  : the INTENT   -> "send 20% to subset v2"
#     - DestinationRule  : the BINDING  -> "subset v2 == pods labeled version=v2"
#   A 503 that is proportional to a weight almost always means the destination
#   the weight points at has NO ENDPOINTS. The intent is fine; the binding is
#   broken. Confirm before you change anything.
#
# STEP 1 — Reproduce and quantify (never trust "it's flaky"):
#   kubectl -n ica-traffic-lab exec deploy/curlclient -c curl -- \
#     sh -c 'for i in $(seq 1 50); do curl -s -o /dev/null -w "%{http_code}\n" \
#       http://helloworld:5000/hello; done' | sort | uniq -c
#   # ~40x 200, ~10x 503  -> failure rate matches the 20% weight. Suspect the
#   # v2 destination, not the v2 pods.
#
# STEP 2 — Ask Istio to lint the config first (cheap, catches most mistakes):
#   istioctl analyze -n ica-traffic-lab
#   # Teaching point: this break is a LABEL MISMATCH, not a missing subset, so
#   # analyze stays quiet. It flags "subset not found" typos, but it cannot
#   # know that 'version: v2-broken' matches zero pods. You must go deeper.
#
# STEP 3 — Confirm the VirtualService still routes 20% to v2 (intent is OK):
#   kubectl -n ica-traffic-lab get virtualservice helloworld -o yaml
#   # weights are 80/v1 and 20/v2 -> do NOT touch this. Constraint respected.
#
# STEP 4 — Inspect the actual Envoy clusters/endpoints (the ground truth):
#   istioctl proxy-config endpoints deploy/curlclient.ica-traffic-lab \
#     --cluster 'outbound|5000|v1|helloworld.ica-traffic-lab.svc.cluster.local'
#   # -> shows 1 healthy endpoint.
#   istioctl proxy-config endpoints deploy/curlclient.ica-traffic-lab \
#     --cluster 'outbound|5000|v2|helloworld.ica-traffic-lab.svc.cluster.local'
#   # -> EMPTY. The v2 cluster exists but has zero endpoints -> "no healthy
#   #    upstream" (503, response flag UH) for the 20% routed there.
#
# STEP 5 — Compare the subset selector against real pod labels (root cause):
#   kubectl -n ica-traffic-lab get pods --show-labels | grep helloworld
#   #   helloworld-v2-...  ... version=v2       <- pods carry version=v2
#   kubectl -n ica-traffic-lab get destinationrule helloworld \
#     -o jsonpath='{range .spec.subsets[*]}{.name}{" -> "}{.labels}{"\n"}{end}'
#   #   v1 -> {"version":"v1"}
#   #   v2 -> {"version":"v2-broken"}            <- binding points at nothing
#
# STEP 6 — Fix the binding (make subset v2 select real pods again). Either patch:
#   kubectl -n ica-traffic-lab patch destinationrule helloworld --type=json \
#     -p '[{"op":"replace","path":"/spec/subsets/1/labels/version","value":"v2"}]'
#   # ...or re-apply the corrected DestinationRule declaratively:
#   #   kubectl apply -n ica-traffic-lab -f - <<'EOF'
#   #   apiVersion: networking.istio.io/v1beta1
#   #   kind: DestinationRule
#   #   metadata: { name: helloworld }
#   #   spec:
#   #     host: helloworld
#   #     subsets:
#   #       - { name: v1, labels: { version: v1 } }
#   #       - { name: v2, labels: { version: v2 } }
#   #   EOF
#
# STEP 7 — Verify the fix (endpoints populated, split restored, zero 503s):
#   istioctl proxy-config endpoints deploy/curlclient.ica-traffic-lab \
#     --cluster 'outbound|5000|v2|helloworld.ica-traffic-lab.svc.cluster.local'
#   # -> now shows the v2 endpoint.
#   kubectl -n ica-traffic-lab exec deploy/curlclient -c curl -- \
#     sh -c 'for i in $(seq 1 50); do curl -s http://helloworld:5000/hello; echo; done' \
#     | grep -o 'version: v[0-9]' | sort | uniq -c
#   # -> ~40 v1 / ~10 v2, and no 503s. Objective met: 100% success, 80/20 kept.
#
# WHY THIS MATTERS ON THE EXAM
#   The most common self-inflicted traffic-shifting outage is a DestinationRule
#   subset whose labels drift from the pod labels (a renamed 'version' value,
#   a typo, a Deployment relabel). The VirtualService looks perfect and the
#   pods are healthy, so the trap is blaming the app. The diagnostic reflex to
#   internalize: 503 rate == weight  =>  inspect 'proxy-config endpoints' for
#   the weighted cluster, then reconcile subset labels with pod labels.
#
# CLEANUP (disposable lab — remove everything):
#   kubectl delete namespace ica-traffic-lab
#
# ###########################################################################