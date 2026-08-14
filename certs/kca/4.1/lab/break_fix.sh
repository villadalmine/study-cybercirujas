#!/usr/bin/env bash
#
# KCA — Domain 4: Cloud Native Security
# Topic 4.1: Applying Policy in Cluster
# Exam weight: 3.33
# Reference (official curriculum):
#   https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
# Pod Security Admission (the in-tree policy controller used here):
#   https://kubernetes.io/docs/concepts/security/pod-security-admission/
# Pod Security Standards (the 'restricted' profile enforced below):
#   https://kubernetes.io/docs/concepts/security/pod-security-standards/
#
# ---------------------------------------------------------------------------
# BREAK & FIX LAB  —  run ONLY on a disposable, throwaway lab VM / cluster.
# ---------------------------------------------------------------------------
# What "applying policy in the cluster" means here:
#   Kubernetes ships a built-in admission controller, Pod Security Admission
#   (PSA), enabled by default since v1.25. You apply policy by LABELLING a
#   namespace with one of the three Pod Security Standards profiles:
#       privileged  -> no restrictions
#       baseline    -> blocks known privilege escalations
#       restricted  -> hardened, follows current best practice
#   The label key carries the MODE: enforce (reject), warn (user warning),
#   audit (audit-log entry).
#
#   This script creates one throwaway namespace, ENFORCES the 'restricted'
#   profile on it, and then deploys a workload that does not satisfy that
#   profile. PSA rejects the pods at admission time, so the Deployment can
#   never become Ready. Nothing outside '$NS' is touched. Full reset at any
#   moment with:   kubectl delete namespace kca-policy-lab
# ---------------------------------------------------------------------------

set -euo pipefail

NS="kca-policy-lab"
APP="policy-demo"
IMAGE="nginxinc/nginx-unprivileged:stable"   # listens on :8080 as UID 101

# --- tiny presentation helpers (safe on a non-TTY) -------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; C=$'\033[0;36m'; Z=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; Z=""
fi
info(){ printf '%s[*]%s %s\n' "$C" "$Z" "$*"; }
ok(){   printf '%s[+]%s %s\n' "$G" "$Z" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$Y" "$Z" "$*"; }
head(){ printf '\n%s==== %s ====%s\n' "$B" "$*" "$Z"; }

# --- preflight -------------------------------------------------------------
head "Preflight checks"
command -v kubectl >/dev/null 2>&1 || { warn "kubectl not found in PATH."; exit 1; }
if ! kubectl cluster-info >/dev/null 2>&1; then
  warn "No reachable cluster (check your kubeconfig / context)."; exit 1
fi
SRV="$(kubectl version -o json 2>/dev/null | grep -o '"minor":[^,]*' | head -n1 | tr -dc '0-9' || true)"
if [[ -n "${SRV}" && "${SRV}" -lt 25 ]]; then
  warn "Server appears to be v1.${SRV}. Pod Security Admission is GA on 1.25+."
  warn "On older clusters the lab may not reject the pod. Continuing anyway."
fi
ok "Context: $(kubectl config current-context 2>/dev/null || echo '<unknown>')"

# --- idempotent reset of any previous run ----------------------------------
head "Resetting any previous lab state"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
ok "Clean slate."

# --- apply the policy: enforce 'restricted' on a fresh namespace -----------
head "Applying policy to the cluster (this is the 'apply policy' step)"
kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted \
  --overwrite >/dev/null
ok "Namespace '$NS' now ENFORCES the 'restricted' Pod Security Standard:"
kubectl get namespace "$NS" -o jsonpath='{.metadata.labels}'; echo

# --- THE BREAK: deploy a workload that violates 'restricted' ----------------
head "Deploying a non-compliant workload (THE BREAK)"
# The Deployment object itself is valid and will be accepted; PSA only judges
# the PODS the ReplicaSet tries to create. This manifest has NO securityContext,
# so it violates several 'restricted' rules at once.
kubectl apply -f - <<YAML >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app: ${APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      containers:
      - name: web
        image: ${IMAGE}
        ports:
        - containerPort: 8080
YAML
ok "Deployment '${APP}' created. Waiting a few seconds for the ReplicaSet to try..."
sleep 8

# --- show the student the symptom ------------------------------------------
head "SYMPTOM — what you will observe"
echo "Deployment / ReplicaSet / Pods:"
kubectl -n "$NS" get deploy,rs,pods 2>/dev/null || true
echo
echo "Recent namespace events (look for FailedCreate / PodSecurity):"
kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 12 || true

cat <<EOF

${B}------------------------------------------------------------------${Z}
${R}${B}BROKEN.${Z} The Deployment exists but reports ${B}0/1 READY${Z}, and there
are ${B}zero pods${Z}. The ReplicaSet keeps retrying and each attempt is
rejected at admission time with a message like:

  Error creating: pods "${APP}-..." is forbidden: violates PodSecurity
  "restricted:latest": allowPrivilegeEscalation != false, unrestricted
  capabilities, runAsNonRoot != true, seccompProfile ... not set to
  RuntimeDefault or Localhost

${C}${B}YOUR MISSION${Z}
  Get the '${APP}' pod to reach ${B}Running / Ready${Z} in namespace
  '${NS}', ${B}WITHOUT deleting or weakening${Z} the namespace's
  'pod-security.kubernetes.io/enforce=restricted' label. In other words:
  fix the WORKLOAD so it complies with the policy — do not disable the
  policy to fit a bad workload.

${C}${B}USEFUL COMMANDS WHILE YOU WORK${Z}
  kubectl -n ${NS} get deploy,rs,pods
  kubectl -n ${NS} describe replicaset -l app=${APP} | sed -n '/Events/,\$p'
  kubectl get namespace ${NS} -o jsonpath='{.metadata.labels}'; echo

${C}${B}SUCCESS LOOKS LIKE${Z}
  kubectl -n ${NS} get pods        # STATUS = Running, READY = 1/1
${B}------------------------------------------------------------------${Z}
EOF

# ===========================================================================
# SOLUTION  (commented — try to solve it yourself before reading)
# ===========================================================================
#
# STEP 0 — Confirm the diagnosis. The Deployment was admitted, but the
#          ReplicaSet cannot create any pod; the reason is a PodSecurity
#          denial, not a scheduling/image problem.
#
#   kubectl -n kca-policy-lab get deploy,rs,pods
#   kubectl -n kca-policy-lab describe replicaset -l app=policy-demo | sed -n '/Events/,$p'
#
# STEP 1 — Read the policy in force. The namespace LABELS *are* the policy.
#
#   kubectl get namespace kca-policy-lab -o jsonpath='{.metadata.labels}'; echo
#     -> pod-security.kubernetes.io/enforce=restricted   (mode: enforce = reject)
#
# STEP 2 — The 'restricted' profile requires, at minimum:
#            pod-level:       runAsNonRoot: true
#                             seccompProfile.type: RuntimeDefault (or Localhost)
#            container-level: allowPrivilegeEscalation: false
#                             capabilities.drop: ["ALL"]
#          Make the WORKLOAD compliant by adding those securityContext fields.
#          (The nginx-unprivileged image runs as UID 101 and binds :8080, so
#           runAsNonRoot is genuinely satisfiable — no root needed.)
#
#   cat <<'YAML' | kubectl apply -f -
#   apiVersion: apps/v1
#   kind: Deployment
#   metadata:
#     name: policy-demo
#     namespace: kca-policy-lab
#     labels:
#       app: policy-demo
#   spec:
#     replicas: 1
#     selector:
#       matchLabels:
#         app: policy-demo
#     template:
#       metadata:
#         labels:
#           app: policy-demo
#       spec:
#         securityContext:
#           runAsNonRoot: true
#           seccompProfile:
#             type: RuntimeDefault
#         containers:
#         - name: web
#           image: nginxinc/nginx-unprivileged:stable
#           ports:
#           - containerPort: 8080
#           securityContext:
#             allowPrivilegeEscalation: false
#             capabilities:
#               drop: ["ALL"]
#   YAML
#
# STEP 3 — Verify the pod is now admitted and Running, with the policy still
#          fully enforced (label untouched):
#
#   kubectl -n kca-policy-lab rollout status deploy/policy-demo --timeout=60s
#   kubectl -n kca-policy-lab get pods -o wide
#   kubectl get namespace kca-policy-lab -o jsonpath='{.metadata.labels}'; echo
#
# WHY THIS IS THE CORRECT FIX
#   Running 'kubectl label ns kca-policy-lab \
#     pod-security.kubernetes.io/enforce=baseline --overwrite' would ALSO make
#   the pod schedule, but it defeats the exercise: you would be lowering the
#   cluster's security posture to accommodate an insecure workload. In
#   production you keep 'restricted' enforced and ship compliant manifests; use
#   the 'warn' and 'audit' modes first to discover non-compliant workloads and
#   migrate them BEFORE flipping 'enforce' on.
#
# CLEAN UP (fully removes the lab)
#   kubectl delete namespace kca-policy-lab
# ===========================================================================