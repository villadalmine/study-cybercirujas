#!/usr/bin/env bash
#
# =============================================================================
# CNPE — Certified Cloud Native Platform Engineer
# Domain 1: Platform Engineering Core  ·  Topic 1.3 (exam weight: 5)
# Optimizing Multi-Tenancy Resource Usage
# -----------------------------------------------------------------------------
# BREAK & FIX LAB — "The quota that rejects every pod"
#
# What this drills:
#   In a multi-tenant cluster you isolate tenants with namespaces and cap what
#   each one may consume with a ResourceQuota. A subtle, production-grade side
#   effect follows from a rule most people learn the hard way:
#
#       If a ResourceQuota limits a compute resource (e.g. requests.cpu),
#       then EVERY pod created in that namespace MUST declare that resource.
#       A pod that omits it is rejected at admission time — it is never created.
#
#   So the moment you add a quota to protect the neighbours, workloads that
#   used to schedule fine (because they never bothered to set requests/limits)
#   stop being created entirely. The tenant sees a Deployment stuck at 0 ready
#   and no obvious reason on the pods (there are no pods to look at).
#
#   The optimization lesson: the fix is NOT to loosen or delete the quota —
#   that defeats multi-tenancy. The fix is to make the namespace supply sane
#   defaults with a LimitRange, so every workload inherits requests/limits that
#   fit inside the tenant's budget. That is how you keep a hard cap AND keep
#   tenants productive without forcing every team to hand-tune resources.
#
# Safety:
#   * Everything happens inside a throwaway namespace ($NS). Nothing outside it
#     is touched, patched or deleted.
#   * Designed for a DISPOSABLE lab cluster (kind / minikube / k3s) on a
#     scratch VM. Do NOT point this at a shared or production cluster.
#   * The script prints the current kube-context and asks for confirmation.
#     Set BF_ASSUME_YES=1 to skip the prompt in automated lab runs.
#   * Idempotent: re-running it wipes $NS and rebuilds the broken state fresh.
#
# Official references:
#   * ResourceQuota .... https://kubernetes.io/docs/concepts/policy/resource-quotas/
#   * LimitRange ....... https://kubernetes.io/docs/concepts/policy/limit-range/
#   * Multi-tenancy .... https://kubernetes.io/docs/concepts/security/multi-tenancy/
# =============================================================================

set -euo pipefail

# --- Parameters --------------------------------------------------------------
NS="bf-tenant-a"
DEPLOY="web"
REPLICAS=3
QUOTA="tenant-quota"
# Tiny, universally-pullable image so the lab works on a laptop-sized cluster.
IMAGE="registry.k8s.io/pause:3.9"

# --- Pretty output -----------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=""; RED=""; GRN=""; YLW=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$CYN" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$BOLD" "--------------------------------------------------------------------------" "$RST"; }

# --- Preflight ---------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl cluster-info >/dev/null 2>&1 || die "No reachable Kubernetes cluster (check your kubeconfig / context)."

CTX="$(kubectl config current-context 2>/dev/null || echo '<unknown>')"
info "Current kube-context: ${BOLD}${CTX}${RST}"
if [[ "${BF_ASSUME_YES:-0}" != "1" ]]; then
  warn "This lab creates and destroys the namespace '${NS}'. Use a DISPOSABLE cluster only."
  read -r -p "Proceed against context '${CTX}'? [y/N] " reply
  [[ "${reply:-N}" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

# --- Reset to a clean, reproducible state (idempotent) -----------------------
info "Resetting namespace '${NS}' ..."
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl create namespace "$NS" >/dev/null
ok "Namespace '${NS}' created."

# --- Install the tenant's ResourceQuota --------------------------------------
# This is the CORRECT, intended guard-rail — the noisy-neighbour protection.
# It is NOT the bug. It stays in place through the fix.
info "Applying the tenant ResourceQuota (this is the guard-rail, keep it)..."
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${QUOTA}
  namespace: ${NS}
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
EOF
ok "ResourceQuota '${QUOTA}' applied."

# --- Deploy the workload the way the tenant actually wrote it -----------------
# The break: the Deployment sets NO resources.requests / resources.limits.
# Because a quota constrains compute resources, admission control refuses every
# pod this ReplicaSet tries to create. The Deployment will sit at 0 ready.
info "Deploying tenant workload '${DEPLOY}' with NO resource requests/limits (the break)..."
kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels: { app: ${DEPLOY} }
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels: { app: ${DEPLOY} }
  template:
    metadata:
      labels: { app: ${DEPLOY} }
    spec:
      containers:
        - name: app
          image: ${IMAGE}
          # <-- intentionally no 'resources:' block. This is the fault.
EOF
ok "Deployment '${DEPLOY}' created."

# --- Let the controller try (and fail) a few times, then show the symptom -----
info "Waiting a few seconds for the ReplicaSet controller to attempt pod creation..."
sleep 8

rule
say "${BOLD}OBSERVED STATE${RST}"
rule
kubectl -n "$NS" get deployment "$DEPLOY" -o wide || true
echo
kubectl -n "$NS" get replicaset -l app="$DEPLOY" || true
echo
say "${BOLD}Recent FailedCreate events in the namespace:${RST}"
kubectl -n "$NS" get events --field-selector reason=FailedCreate \
  --sort-by=.lastTimestamp 2>/dev/null | tail -n 5 || true
rule

# =============================================================================
#  STUDENT BRIEF
# =============================================================================
cat <<BRIEF

${BOLD}SYMPTOM YOU WILL SEE${RST}
  * '${DEPLOY}' reports ${RED}READY 0/${REPLICAS}${RST} and never progresses.
  * There are ${BOLD}no pods${RST} to inspect — none were ever created, so
    'kubectl -n ${NS} get pods' is empty or shows nothing useful.
  * The truth is in the ReplicaSet, not the pods. Look here:
        kubectl -n ${NS} describe replicaset -l app=${DEPLOY}
        kubectl -n ${NS} get events --field-selector reason=FailedCreate
    You will find a message like:
        Error creating: pods "${DEPLOY}-xxxxx" is forbidden: failed quota:
        ${QUOTA}: must specify limits.cpu,limits.memory,requests.cpu,requests.memory

${BOLD}WHY IT HAPPENS${RST}
  A ResourceQuota that caps a compute resource makes that resource ${BOLD}mandatory${RST}
  on every pod in the namespace. Your workload declares none, so the API server
  rejects each pod at admission. The Deployment controller keeps retrying with
  backoff, which is why it looks "stuck" rather than "failed".

${BOLD}YOUR GOAL${RST}
  Get '${DEPLOY}' to ${GRN}READY ${REPLICAS}/${REPLICAS}${RST} ${BOLD}without weakening the tenant's
  isolation${RST}:
      * Do NOT delete or raise the ResourceQuota '${QUOTA}'.
      * The quota must still be enforced when you are done.
  Inspect what is used vs. what is allowed while you work:
      kubectl -n ${NS} describe resourcequota ${QUOTA}

${BOLD}HINT${RST}
  The right answer is the one that scales to hundreds of tenants without asking
  every team to hand-edit their manifests. Think: how does a namespace hand out
  ${BOLD}default${RST} requests/limits to any workload that forgot to set them — and how do
  you make sure those defaults fit inside the quota's budget?

  When you have it green, re-read the commented SOLUTION at the very bottom of
  this script to check your reasoning. To wipe the lab:
      kubectl delete namespace ${NS}

BRIEF

ok "Break is in place. The namespace '${NS}' is now yours to fix."
exit 0

# =============================================================================
#  SOLUTION — step by step  (read only after you have tried it yourself)
# =============================================================================
#
# The quota is correct and must stay. The workload is "wrong" only in that it
# omits resources — which is exactly the common case in a real platform, where
# tenants ship manifests that never set requests/limits. The platform-engineering
# fix is to make the NAMESPACE supply defaults, using a LimitRange. This is both
# the exam-intended answer and the production best practice for multi-tenancy.
#
# ---------------------------------------------------------------------------
# STEP 1 — Confirm the diagnosis (know WHY before you touch anything)
# ---------------------------------------------------------------------------
#   kubectl -n bf-tenant-a describe replicaset -l app=web | sed -n '/Events/,$p'
#   # -> FailedCreate ... "must specify limits.cpu,limits.memory,requests.cpu,requests.memory"
#
#   kubectl -n bf-tenant-a describe resourcequota tenant-quota
#   # -> Used is 0 across the board; the quota is fine, nothing is consuming it,
#   #    because nothing was ever admitted.
#
# ---------------------------------------------------------------------------
# STEP 2 — Give the namespace default requests/limits with a LimitRange
# ---------------------------------------------------------------------------
# 'defaultRequest' fills in requests.*; 'default' fills in limits.*. Any
# container that omits them inherits these values at admission time, which
# satisfies the quota's "must specify" rule. Size the defaults so that
# REPLICAS x default still fits under the quota:
#     requests: 3 x 100m  = 300m  <= 1     CPU      OK
#               3 x 128Mi = 384Mi <= 1Gi   memory   OK
#     limits:   3 x 200m  = 600m  <= 2     CPU      OK
#               3 x 256Mi = 768Mi <= 2Gi   memory   OK
#
#   kubectl apply -f - <<'YAML'
#   apiVersion: v1
#   kind: LimitRange
#   metadata:
#     name: tenant-defaults
#     namespace: bf-tenant-a
#   spec:
#     limits:
#       - type: Container
#         defaultRequest:      # becomes resources.requests when unset
#           cpu: 100m
#           memory: 128Mi
#         default:             # becomes resources.limits when unset
#           cpu: 200m
#           memory: 256Mi
#   YAML
#
# ---------------------------------------------------------------------------
# STEP 3 — Force the controller to retry now (instead of waiting for backoff)
# ---------------------------------------------------------------------------
# A LimitRange only applies to pods created AFTER it exists. The existing
# ReplicaSet will eventually retry on its own (backoff caps around ~5 min), but
# a rollout restart makes new pods immediately and picks up the defaults:
#
#   kubectl -n bf-tenant-a rollout restart deployment/web
#   kubectl -n bf-tenant-a rollout status  deployment/web --timeout=90s
#
# ---------------------------------------------------------------------------
# STEP 4 — Verify: green Deployment AND quota still enforced
# ---------------------------------------------------------------------------
#   kubectl -n bf-tenant-a get deployment web
#   # -> READY 3/3
#
#   kubectl -n bf-tenant-a get pods -o \
#     'custom-columns=POD:.metadata.name,REQ_CPU:.spec.containers[0].resources.requests.cpu,LIM_CPU:.spec.containers[0].resources.limits.cpu'
#   # -> each pod now shows 100m / 200m, injected by the LimitRange
#
#   kubectl -n bf-tenant-a describe resourcequota tenant-quota
#   # -> Used: requests.cpu 300m/1, requests.memory 384Mi/1Gi, etc.
#   #    The cap is intact and now actually accounting for real usage.
#
# ---------------------------------------------------------------------------
# ALTERNATIVE fix (valid, but does NOT scale for multi-tenancy)
# ---------------------------------------------------------------------------
# You could instead hard-code resources on this one Deployment:
#
#   kubectl -n bf-tenant-a set resources deployment/web \
#     --requests=cpu=100m,memory=128Mi --limits=cpu=200m,memory=256Mi
#
# This turns THIS workload green, but every other tenant workload that forgets
# resources will hit the same wall. In a platform with many tenants, the
# LimitRange (Step 2) is the correct, once-per-namespace optimization: it makes
# the tenant's namespace self-serve safe defaults that always fit the quota.
#
# ---------------------------------------------------------------------------
# Anti-pattern — what NOT to do
# ---------------------------------------------------------------------------
#   kubectl -n bf-tenant-a delete resourcequota tenant-quota   # <-- WRONG
#   kubectl -n bf-tenant-a patch resourcequota tenant-quota ...--raise-limits   # <-- WRONG
# Removing or inflating the quota "fixes" the symptom by removing the isolation
# you built the namespace to have. That is the opposite of optimizing
# multi-tenant resource usage — it just restores the noisy-neighbour problem.
#
# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
#   kubectl delete namespace bf-tenant-a
# =============================================================================