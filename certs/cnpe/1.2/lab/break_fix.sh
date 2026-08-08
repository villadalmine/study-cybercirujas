#!/usr/bin/env bash
#
# CNPE 1.2 — Using Cost Management Solutions for Right-Sizing and Scaling
# Break & Fix lab  ·  Certified Cloud Native Platform Engineer (CNPE)
# Syllabus: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
#
# WHAT THIS LAB TEACHES
#   Right-sizing is the primary cost-management lever in Kubernetes: a Pod
#   reserves exactly what its container `requests`, whether or not it uses it.
#   Over-provisioned requests do two expensive things at once:
#     1. They pin capacity the workload never touches, so the scheduler runs out
#        of room and forces you to add (pay for) more nodes than you need.
#     2. They break autoscaling economics. The HorizontalPodAutoscaler measures
#        utilization as usage/request, so an inflated request makes a busy app
#        look idle forever — it never scales, and you keep overpaying.
#   You will break a Deployment by over-requesting CPU, watch replicas fail to
#   schedule, then right-size it so it fits and can scale within one node.
#
# SAFETY
#   Everything lives in a throwaway namespace (cnpe-lab-12) and is pinned to a
#   single lab node with a nodeSelector. Nothing else on the cluster is touched.
#   Run only on a DISPOSABLE single-node lab VM (kind / minikube / k3s).
#   Tear down at any time with:  ./break_fix.sh --cleanup
#
set -euo pipefail

NS="cnpe-lab-12"
APP="web-store"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not installed." >&2; exit 1; }; }

# Convert a Kubernetes CPU quantity (e.g. "8", "7910m", "0.5") to integer millicores.
cpu_to_milli() {
  awk -v v="$1" 'BEGIN{
    if (v ~ /m$/) { sub(/m$/,"",v); printf "%d", v }
    else { printf "%d", v*1000 }
  }'
}

cleanup() {
  echo ">> Deleting namespace ${NS} (all lab objects) ..."
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
  echo ">> Cleanup requested. The lab namespace is being removed."
  exit 0
}

verify() {
  echo ">> Acceptance check for CNPE 1.2 right-sizing lab:"
  local desired ready pending
  desired=$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  ready=$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  ready=${ready:-0}
  pending=$(kubectl -n "${NS}" get pods -l app="${APP}" --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l | tr -d ' ')
  echo "   desired=${desired}  ready=${ready}  pending=${pending}"
  if [[ "${ready}" == "${desired}" && "${desired}" -gt 0 && "${pending}" -eq 0 ]]; then
    echo "   RESULT: PASS — all replicas scheduled and Ready on a single node. Right-sized. ✅"
    exit 0
  else
    echo "   RESULT: FAIL — replicas are still Pending. The workload does not fit; keep right-sizing. ❌"
    exit 1
  fi
}

case "${1:-}" in
  --cleanup|-c) need kubectl; cleanup ;;
  --verify|-v)  need kubectl; verify  ;;
  -h|--help)
    echo "Usage: $0 [--cleanup|--verify|--help]"
    echo "  (no args)   Deploy the broken, over-provisioned workload"
    echo "  --verify    Check whether you have right-sized it correctly"
    echo "  --cleanup   Remove the lab namespace"
    exit 0 ;;
esac

need kubectl
need awk

echo "==> CNPE 1.2 Break & Fix: over-provisioned requests break scheduling and scaling"

# --- Sanity: confirm we can reach a cluster and pick a single lab node ---------
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach a cluster. Point KUBECONFIG at your lab VM." >&2
  exit 1
fi

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_COUNT=$(kubectl get nodes -o name | wc -l | tr -d ' ')
if [[ "${NODE_COUNT}" -gt 1 ]]; then
  echo ">> WARNING: cluster has ${NODE_COUNT} nodes. This lab assumes a disposable single-node VM."
  echo ">> All lab Pods will be pinned to '${NODE}' so the scheduling constraint is deterministic."
fi

# --- Break: request half the node's CPU per replica ---------------------------
# We read the node's allocatable CPU and set each replica's request to ~50% of
# it. With 3 replicas, at most one can ever fit — the rest go Pending. The value
# is derived from the node so the break is deterministic on any host size, and
# it dramatizes the waste: nginx idles at ~1m while it *reserves* whole cores.
ALLOC_RAW=$(kubectl get node "${NODE}" -o jsonpath='{.status.allocatable.cpu}')
ALLOC_M=$(cpu_to_milli "${ALLOC_RAW}")
REQ_M=$(( ALLOC_M / 2 ))
[[ "${REQ_M}" -lt 100 ]] && REQ_M=100

echo ">> Lab node '${NODE}' allocatable CPU: ${ALLOC_RAW} (${ALLOC_M}m)"
echo ">> Injecting an OVER-PROVISIONED request of ${REQ_M}m CPU per replica (x3 replicas)."

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
  labels: { app: ${APP} }
spec:
  replicas: 3
  selector:
    matchLabels: { app: ${APP} }
  template:
    metadata:
      labels: { app: ${APP} }
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${NODE}
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports: [ { containerPort: 80 } ]
          resources:
            requests:
              cpu: "${REQ_M}m"
              memory: "128Mi"
            limits:
              cpu: "${REQ_M}m"
              memory: "128Mi"
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP}
  minReplicas: 3
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
EOF

echo ">> Waiting for the scheduler to react ..."
sleep 8

echo
echo "=========================== SYMPTOM ================================"
kubectl -n "${NS}" get pods -l app="${APP}" -o wide || true
echo
echo "HorizontalPodAutoscaler:"
kubectl -n "${NS}" get hpa "${APP}" || true
echo "==================================================================="
echo
cat <<'BRIEF'
WHAT YOU WILL SEE
  * `kubectl -n cnpe-lab-12 get pods` shows one replica Running and the others
    stuck in Pending.
  * `kubectl -n cnpe-lab-12 describe pod <pending-pod>` ends with:
        Warning  FailedScheduling  ... 0/1 nodes are available:
        Insufficient cpu.
  * `kubectl -n cnpe-lab-12 get hpa web-store` shows TARGETS as `<unknown>/50%`
    (no metrics-server) or a misleadingly low % — either way the HPA cannot do
    its job, because each replica already reserves half the node.

WHY IT MATTERS (the cost angle)
  The container asks for ~half a CPU core but nginx uses ~1m. You are paying to
  reserve capacity that is never used, and that reservation is exactly what
  keeps the extra replicas from scheduling. In a real cluster the autoscaler
  would now add a node — spending money — to satisfy a request the workload
  does not need. Right-sizing removes the spend and lets the app scale in place.

YOUR GOAL
  Right-size the container's CPU request so all 3 replicas schedule and become
  Ready on the single lab node — WITHOUT adding nodes and WITHOUT dropping
  replicas. Base the new value on real usage (a few tens of millicores), not on
  a guess. Then confirm with:

      ./break_fix.sh --verify

  (Hint: derive the real number from measured usage — `kubectl top pods`,
   a VerticalPodAutoscaler recommendation, or an OpenCost report — then set the
   request a little above the observed peak, not at it.)
BRIEF

exit 0

# =============================================================================
# SOLUTION — step by step (do not peek until you have tried it)
# =============================================================================
#
# The defect: `resources.requests.cpu` is set to ~50% of the node per replica,
# so the scheduler can only place one Pod and the HPA has no headroom to scale.
# The fix is to right-size the request down to what the workload actually uses.
#
# 1) Prove the failure and read the reason:
#      kubectl -n cnpe-lab-12 get pods -o wide
#      kubectl -n cnpe-lab-12 describe pod -l app=web-store | grep -A2 FailedScheduling
#      #   -> "Insufficient cpu"  (the request, not real usage, is the blocker)
#
# 2) Measure real usage instead of guessing. Any ONE of these is enough:
#      # a) metrics-server (fastest signal):
#      kubectl -n cnpe-lab-12 top pods            # nginx idles at ~1-5m CPU
#      # b) a VerticalPodAutoscaler in "Off" mode, which only *recommends*:
#      #    it will suggest a target request close to observed usage.
#      # c) an OpenCost / OpenCost-based report showing request-vs-usage waste.
#
# 3) Right-size the request (and matching limit) to a realistic value.
#    ~50m CPU is comfortably above nginx's real peak and leaves scaling room:
#      kubectl -n cnpe-lab-12 set resources deployment/web-store \
#        --requests=cpu=50m,memory=64Mi \
#        --limits=cpu=250m,memory=128Mi
#
#    Equivalent declarative fix (preferred for GitOps): edit the manifest's
#    resources block to requests cpu=50m/memory=64Mi and `kubectl apply` it.
#
# 4) Watch the rollout place every replica on the single node:
#      kubectl -n cnpe-lab-12 rollout status deployment/web-store
#      kubectl -n cnpe-lab-12 get pods -o wide      # 3/3 Running, all on one node
#
# 5) Confirm the HPA is now healthy and has room to scale to maxReplicas=6
#    within the node's budget (3 x 50m = 150m, vs whole cores before):
#      kubectl -n cnpe-lab-12 get hpa web-store
#      #   TARGETS now reads a real, meaningful % because the request reflects
#      #   actual usage — utilization = usage/request is no longer diluted.
#
# 6) Verify acceptance:
#      ./break_fix.sh --verify        # expect: PASS — 3/3 Ready, 0 Pending
#
# 7) Tear down when finished:
#      ./break_fix.sh --cleanup
#
# TAKEAWAY
#   Requests are a reservation, and utilization percentages are measured against
#   them. Set requests from observed p95/peak usage (via metrics-server, VPA
#   recommendations, or OpenCost), not from fear. Right-sizing is what makes both
#   bin-packing and autoscaling — and therefore your bill — behave.
#
# SOURCES (official)
#   Managing Resources for Containers:
#     https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
#   HorizontalPodAutoscaler:
#     https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
#   VerticalPodAutoscaler (recommendations):
#     https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
#   OpenCost (cost monitoring / right-sizing):
#     https://www.opencost.io/docs/
#   CNPE Curriculum:
#     https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# =============================================================================