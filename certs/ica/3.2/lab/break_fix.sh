#!/usr/bin/env bash
#
# ICA — Istio Certified Associate
# Domain 3: Advanced Scenarios
# Topic 3.2 — Configuring Routing within a Service Mesh (exam weight: 5%)
# Reference syllabus: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#
# BREAK & FIX LAB — "The subset that resolves to nothing"
#
# WHAT THIS LAB TEACHES
#   In an Istio mesh, east-west (in-mesh) HTTP routing is a two-object contract:
#     - a VirtualService decides *which named subset* a request is sent to;
#     - a DestinationRule defines *what a subset actually is* — a label selector
#       that Envoy turns into an upstream cluster of real endpoints.
#   The name is the link between the two objects. The labels are the link between
#   the subset and the Pods. Break either link and the route still "exists" on
#   paper but points at an empty cluster. This lab breaks the second link (labels)
#   in a controlled, fully reversible way and asks you to restore the route.
#
# SAFETY / SCOPE
#   * Designed for a DISPOSABLE lab VM (minikube / kind / k3d) with Istio installed.
#   * Everything lives in a single throwaway namespace ($NS). Nothing outside it
#     is touched. Teardown is a single namespace delete.
#   * All applies are idempotent: re-running is safe.
#
# USAGE
#   ./ica-3.2-routing-breakfix.sh setup     # deploy the healthy app + routing
#   ./ica-3.2-routing-breakfix.sh verify    # prove it returns 200 / "v1"
#   ./ica-3.2-routing-breakfix.sh break     # introduce the controlled fault
#   ./ica-3.2-routing-breakfix.sh solve     # (instructor) apply the fix
#   ./ica-3.2-routing-breakfix.sh cleanup   # delete the namespace
#   ./ica-3.2-routing-breakfix.sh all       # setup + verify + break (default)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NS="${NS:-ica-mesh-lab}"
SVC="helloworld"
SVC_PORT="5000"
IMG_V1="docker.io/istio/examples-helloworld-v1"
IMG_V2="docker.io/istio/examples-helloworld-v2"
IMG_CURL="curlimages/curl:8.10.1"
FQDN="${SVC}.${NS}.svc.cluster.local"
CLUSTER_V1="outbound|${SVC_PORT}|v1|${FQDN}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; CYA=$'\033[0;36m'; RST=$'\033[0m'
info()  { printf '%s[i]%s %s\n' "$CYA" "$RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()   { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
rule()  { printf '%s\n' "------------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  command -v kubectl  >/dev/null 2>&1 || die "kubectl not found in PATH."
  command -v istioctl >/dev/null 2>&1 || warn "istioctl not found — diagnostics in the solution need it; the break still works via kubectl."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster. Point KUBECONFIG at your lab VM."
  kubectl -n istio-system get deploy istiod >/dev/null 2>&1 \
    || die "istiod not found in istio-system. Install Istio before running this lab."

  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  if [ "${ICA_LAB_CONFIRM:-}" != "yes" ]; then
    rule
    warn "This script CREATES and BREAKS resources in namespace '${NS}'."
    warn "Current kube-context: ${ctx}"
    warn "Run this ONLY on a disposable lab cluster."
    rule
    if [ -t 0 ]; then
      read -r -p "Type 'yes' to proceed on context '${ctx}': " ans
      [ "$ans" = "yes" ] || die "Aborted by user."
    else
      die "Non-interactive shell: set ICA_LAB_CONFIRM=yes to proceed."
    fi
  fi
}

client_pod() {
  kubectl -n "$NS" get pod -l app=curl -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

curl_svc() {
  # Exercises in-mesh routing from an injected client Pod through its sidecar.
  local pod; pod="$(client_pod)"
  [ -n "$pod" ] || die "client Pod not ready; run 'setup' first."
  kubectl -n "$NS" exec "$pod" -c curl -- \
    curl -s -m 4 -o /dev/null -w '%{http_code}' "http://${SVC}:${SVC_PORT}/hello" 2>/dev/null || echo "000"
}

curl_body() {
  local pod; pod="$(client_pod)"
  kubectl -n "$NS" exec "$pod" -c curl -- \
    curl -s -m 4 "http://${SVC}:${SVC_PORT}/hello" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------
apply_app() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

  cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  labels: { app: ${SVC}, service: ${SVC} }
spec:
  selector: { app: ${SVC} }
  ports:
    - name: http            # named 'http' so Envoy applies L7 routing
      port: ${SVC_PORT}
      targetPort: ${SVC_PORT}
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${SVC}-v1 }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${SVC}, version: v1 } }
  template:
    metadata: { labels: { app: ${SVC}, version: v1 } }
    spec:
      containers:
        - name: ${SVC}
          image: ${IMG_V1}
          imagePullPolicy: IfNotPresent
          ports: [ { containerPort: ${SVC_PORT} } ]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${SVC}-v2 }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${SVC}, version: v2 } }
  template:
    metadata: { labels: { app: ${SVC}, version: v2 } }
    spec:
      containers:
        - name: ${SVC}
          image: ${IMG_V2}
          imagePullPolicy: IfNotPresent
          ports: [ { containerPort: ${SVC_PORT} } ]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: curl }
spec:
  replicas: 1
  selector: { matchLabels: { app: curl } }
  template:
    metadata: { labels: { app: curl } }
    spec:
      containers:
        - name: curl
          image: ${IMG_CURL}
          command: [ "sh", "-c", "while true; do sleep 3600; done" ]
YAML

  info "Waiting for workloads (sidecar injection + image pull)..."
  kubectl -n "$NS" rollout status deploy/${SVC}-v1 --timeout=180s >/dev/null
  kubectl -n "$NS" rollout status deploy/${SVC}-v2 --timeout=180s >/dev/null
  kubectl -n "$NS" rollout status deploy/curl       --timeout=180s >/dev/null
}

# Correct routing: VS pins 100% of traffic to subset v1; DR defines v1/v2 by the
# 'version' label that the Pods actually carry.
apply_routing_good() {
  cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: { name: ${SVC} }
spec:
  host: ${SVC}
  subsets:
    - name: v1
      labels: { version: v1 }     # <-- matches the running v1 Pods
    - name: v2
      labels: { version: v2 }
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: ${SVC} }
spec:
  hosts: [ ${SVC} ]
  http:
    - route:
        - destination: { host: ${SVC}, subset: v1 }
          weight: 100
YAML
}

# The CONTROLLED FAULT: the v1 subset keeps its NAME (so the VirtualService still
# resolves) but its label selector is changed to a value no Pod carries. The route
# now targets a real cluster that contains ZERO endpoints.
apply_routing_broken() {
  cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: { name: ${SVC} }
spec:
  host: ${SVC}
  subsets:
    - name: v1
      labels: { version: v1-CANARY }   # <-- FAULT: no Pod has version=v1-CANARY
    - name: v2
      labels: { version: v2 }
YAML
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
do_setup() {
  preflight
  apply_app
  apply_routing_good
  ok "Namespace '${NS}' is up: helloworld v1/v2, a curl client, and healthy routing."
}

do_verify() {
  info "Probing in-mesh route http://${SVC}:${SVC_PORT}/hello ..."
  local code=""; local i
  for i in 1 2 3 4 5; do
    code="$(curl_svc)"; [ "$code" = "200" ] && break; sleep 3
  done
  if [ "$code" = "200" ]; then
    ok "HTTP ${code} — $(curl_body)"
    ok "Routing is healthy: every request is pinned to subset v1."
  else
    warn "HTTP ${code} — route is NOT healthy right now (expected if you already ran 'break')."
  fi
}

do_break() {
  preflight
  apply_routing_broken
  rule
  printf '%s  ICA 3.2 — BREAK & FIX: your route now points at an empty cluster%s\n' "$YEL" "$RST"
  rule
  cat <<EOF

WHAT JUST HAPPENED (controlled, reversible)
  The DestinationRule for '${SVC}' still declares subset "v1", so the
  VirtualService still passes admission and still routes 100% of traffic to it.
  But subset v1's label selector was changed to a value no Pod carries.

THE SYMPTOM YOU WILL SEE
  From the in-mesh client:
      kubectl -n ${NS} exec deploy/curl -c curl -- \\
        curl -s http://${SVC}:${SVC_PORT}/hello

  returns HTTP ${RED}503${RST} with the body:
      ${RED}no healthy upstream${RST}

  The client sidecar's access log shows response flag ${RED}UH${RST} (no healthy
  upstream) on cluster "${CLUSTER_V1}".
  Note: 'istioctl analyze' may report NOTHING — the subset name is valid, so a
  name-level check passes. This is the trap: a route can be perfectly wired and
  still be dead because its selector matches no endpoints.

YOUR GOAL
  Restore HTTP 200 responses that read "Hello version: v1", WITHOUT changing the
  intent (traffic must still be pinned to v1) and WITHOUT relabeling the Pods.
  In other words: make subset v1 resolve to the real v1 endpoints again.

CONFIRM CURRENT STATE
EOF
  info "Live probe result:"
  printf '    HTTP %s — %s\n' "$(curl_svc)" "$(curl_body || echo '(no body / 503)')"
  rule
  warn "When you have fixed it, verify with:  $0 verify"
  warn "To see the reference fix executed:    $0 solve"
  warn "To tear everything down:              $0 cleanup"
}

do_solve() {
  preflight
  info "Applying the reference fix (subset v1 selector -> version: v1)..."
  apply_routing_good
  sleep 4
  do_verify
}

do_cleanup() {
  info "Deleting namespace '${NS}'..."
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null
  ok "Lab environment removed."
}

case "${1:-all}" in
  setup)   do_setup ;;
  verify)  do_verify ;;
  break)   do_break ;;
  solve)   do_solve ;;
  cleanup) do_cleanup ;;
  all)     do_setup; do_verify; do_break ;;
  *)       die "Unknown phase '${1}'. Use: setup | verify | break | solve | cleanup | all" ;;
esac

# ===========================================================================
# SOLUTION — step by step (do NOT read until you have tried)
# ===========================================================================
#
# MENTAL MODEL
#   Request  ->  VirtualService (chooses subset by NAME)
#            ->  DestinationRule (turns subset NAME into a LABEL selector)
#            ->  Envoy cluster "outbound|5000|v1|helloworld..." (LABELS -> endpoints)
#            ->  Pod endpoints
#   A 503 "no healthy upstream" (flag UH) means the route resolved to a cluster,
#   but that cluster has zero healthy endpoints. So the break is downstream of
#   the VirtualService — it is in how the subset maps to Pods (the DestinationRule
#   labels), not in the VirtualService route itself.
#
# STEP 1 — Reproduce and classify the failure
#   kubectl -n ica-mesh-lab exec deploy/curl -c curl -- \
#     curl -s -o /dev/null -w '%{http_code}\n' http://helloworld:5000/hello
#   # => 503
#   kubectl -n ica-mesh-lab exec deploy/curl -c curl -- \
#     curl -s http://helloworld:5000/hello
#   # => no healthy upstream
#   Read the client sidecar access log; the response flag is the key signal:
#   kubectl -n ica-mesh-lab logs deploy/curl -c istio-proxy --tail=20 | grep helloworld
#   # ... "GET /hello" 503 UH ... outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local
#   # UH = No Healthy Upstream  ->  the chosen cluster (subset v1) has no endpoints.
#
# STEP 2 — Confirm the route itself is fine (rule out the VirtualService)
#   istioctl proxy-config route deploy/curl -n ica-mesh-lab \
#     --name 5000 -o json | grep -A3 '"cluster"'
#   # The route points at: outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local
#   # That is exactly what the VirtualService asked for. The route is correct.
#   # (istioctl analyze -n ica-mesh-lab may print no error here — do NOT trust its
#   #  silence as "healthy"; it validates references, not live endpoint population.)
#
# STEP 3 — Prove the cluster is empty, and find out WHY
#   istioctl proxy-config endpoints deploy/curl -n ica-mesh-lab \
#     --cluster 'outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local'
#   # => (empty)   <-- zero endpoints -> this is the UH.
#   # Compare the subset's required labels against the labels the Pods actually have:
#   istioctl proxy-config cluster deploy/curl -n ica-mesh-lab \
#     --fqdn helloworld.ica-mesh-lab.svc.cluster.local --subset v1 -o json \
#     | grep -A4 metadataMatch
#   # => version: v1-CANARY          (what the subset demands)
#   kubectl -n ica-mesh-lab get pods -l app=helloworld \
#     -L version --show-labels
#   # => the running Pods carry version=v1 and version=v2 — NOT v1-CANARY.
#   # ROOT CAUSE: DestinationRule subset v1 selects a label no endpoint has.
#
# STEP 4 — Apply the fix (make subset v1 select the real v1 endpoints)
#   Edit the DestinationRule so subset v1's labels match the Pods again:
#
#   kubectl -n ica-mesh-lab apply -f - <<'EOF'
#   apiVersion: networking.istio.io/v1
#   kind: DestinationRule
#   metadata: { name: helloworld }
#   spec:
#     host: helloworld
#     subsets:
#       - name: v1
#         labels: { version: v1 }     # corrected: matches the running v1 Pods
#       - name: v2
#         labels: { version: v2 }
#   EOF
#
#   (Equivalent surgical patch:
#     kubectl -n ica-mesh-lab patch destinationrule helloworld --type=json \
#       -p='[{"op":"replace","path":"/spec/subsets/0/labels/version","value":"v1"}]'
#   )
#
#   Note the two WRONG "fixes" the goal explicitly forbids, and why:
#     - Relabeling the Pods to version=v1-CANARY would "work" but destroys the
#       v1/v2 distinction the mesh relies on for canary/version routing.
#     - Deleting the subset / dropping the subset field from the VirtualService
#       removes the version pinning instead of repairing it.
#   The correct fix repairs the subset->endpoint link and preserves intent.
#
# STEP 5 — Verify recovery
#   istioctl proxy-config endpoints deploy/curl -n ica-mesh-lab \
#     --cluster 'outbound|5000|v1|helloworld.ica-mesh-lab.svc.cluster.local'
#   # => now lists the v1 Pod IP:5000
#   kubectl -n ica-mesh-lab exec deploy/curl -c curl -- \
#     curl -s http://helloworld:5000/hello
#   # => Hello version: v1, instance: helloworld-v1-xxxxx
#   Envoy config converges within a couple of seconds of the DR apply; if it lags,
#   confirm push status is clean: istioctl proxy-status
#
# TAKEAWAYS FOR THE EXAM
#   * VirtualService subset = a NAME; DestinationRule subset = NAME + label selector.
#     Both the name AND the labels must line up, or the route is dead on arrival.
#   * 503 UH / "no healthy upstream" = route resolved, cluster empty. Look at the
#     DestinationRule labels and the Pod labels, not the VirtualService.
#   * Diagnose with the data plane, not just the control plane: proxy-config
#     route -> cluster -> endpoints walks the exact path a request takes.
#     'istioctl analyze' checks references, not live endpoint population.
# ===========================================================================