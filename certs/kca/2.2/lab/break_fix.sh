#!/usr/bin/env bash
#
# KCA — Topic 2.2: Kyverno Custom Resource Definitions (CRDs)
# Break & Fix laboratory — run ONLY on a disposable, single-node lab VM
# (kind / minikube / k3d) where Kyverno is already installed.
#
# What this drill teaches
# -----------------------
# A CRD is what makes `ClusterPolicy` a first-class kind that the Kubernetes
# API server understands. Kyverno ships a family of CRDs (ClusterPolicy,
# Policy, PolicyReport, ClusterPolicyReport, AdmissionReport, UpdateRequest,
# CleanupPolicy, PolicyException, ...). If the CRD that registers a kind
# disappears, the API server no longer serves that kind AND every custom
# resource of that kind is cascade-deleted with it. This drill removes the
# `clusterpolicies.kyverno.io` CRD (after backing everything up) so you can
# observe that failure mode and practice recovering it cleanly.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
TARGET_CRD="clusterpolicies.kyverno.io"
DEMO_POLICY="kca-lab-require-team-label"
BACKUP_DIR="/tmp/kca-2.2-kyverno-crd-backup"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n'  "$BLUE"   "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$GREEN"  "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$YELLOW" "$NC" "$*"; }
die()  { printf '%s[FAIL]%s %s\n'  "$RED"    "$NC" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Safety rails — refuse to run against anything that looks like a real cluster
# ----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster. Point KUBECONFIG at your lab VM."

CTX="$(kubectl config current-context 2>/dev/null || echo 'unknown')"
info "Current kube-context: ${CTX}"
if printf '%s' "$CTX" | grep -Eq 'kind-|minikube|k3d|k3s|lab|test|kca|dev'; then
  ok "Context looks like a disposable lab. Continuing."
else
  warn "Context does NOT look like a throwaway lab (kind/minikube/k3d/…)."
  if [ "${CONFIRM_DESTRUCTIVE:-no}" != "yes" ]; then
    if [ -t 0 ]; then
      printf '%sType exactly "destroy-my-lab" to proceed: %s' "$YELLOW" "$NC"
      read -r answer || answer=""
      [ "$answer" = "destroy-my-lab" ] || die "Aborted. This script deletes a CRD; run it only on a scratch VM."
    else
      die "Refusing non-interactively. Re-run with CONFIRM_DESTRUCTIVE=yes if this really is a lab."
    fi
  fi
fi

# ----------------------------------------------------------------------------
# Preconditions — Kyverno + the target CRD must be present
# ----------------------------------------------------------------------------
kubectl get crd "$TARGET_CRD" >/dev/null 2>&1 \
  || die "CRD ${TARGET_CRD} not found. Install Kyverno first: https://kyverno.io/docs/installation/"
ok "Found CRD ${TARGET_CRD}."

# Record the running Kyverno version so the recovery hint points at the right manifest.
KYVERNO_VER="$(
  kubectl get deploy -n "$KYVERNO_NS" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
  | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
)"
KYVERNO_VER="${KYVERNO_VER:-vX.Y.Z}"
info "Detected Kyverno version: ${KYVERNO_VER}"

# ----------------------------------------------------------------------------
# Seed a demo ClusterPolicy so you can watch it vanish with the CRD
# ----------------------------------------------------------------------------
info "Applying a harmless demo ClusterPolicy (${DEMO_POLICY}) in Audit mode..."
kubectl apply -f - >/dev/null <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${DEMO_POLICY}
  labels:
    app.kubernetes.io/part-of: kca-lab-2.2
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Every Pod must carry a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
YAML
ok "Demo policy present."
say ""
info "Baseline — the kind is registered and served:"
kubectl get clusterpolicy || true
say ""

# ----------------------------------------------------------------------------
# Back up everything BEFORE breaking anything (offline recovery path)
# ----------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
info "Backing up the CRD definition and all ClusterPolicy resources to ${BACKUP_DIR} ..."
kubectl get crd "$TARGET_CRD" -o yaml > "${BACKUP_DIR}/crd-${TARGET_CRD}.yaml"
kubectl get clusterpolicy -o yaml   > "${BACKUP_DIR}/clusterpolicies.yaml" 2>/dev/null || true
ok "Backups written:"
say "      - ${BACKUP_DIR}/crd-${TARGET_CRD}.yaml"
say "      - ${BACKUP_DIR}/clusterpolicies.yaml"
say ""

# ----------------------------------------------------------------------------
# >>> THE BREAK <<<  Delete the CRD that registers the ClusterPolicy kind.
# Deleting a CRD deregisters the kind AND cascade-deletes every CR of that kind.
# ----------------------------------------------------------------------------
warn "Deleting CRD ${TARGET_CRD} — this cascade-deletes all ClusterPolicies..."
kubectl delete crd "$TARGET_CRD" --wait=true
ok "Break applied."
say ""

# ----------------------------------------------------------------------------
# Brief the student
# ----------------------------------------------------------------------------
cat <<BRIEF

================================================================================
${RED}KCA LAB 2.2 — BREAK & FIX: Kyverno CRDs${NC}
================================================================================

${YELLOW}THE SYMPTOM YOU WILL SEE${NC}

  1) Listing the policies now fails outright — the API server no longer knows
     the kind exists:

       \$ kubectl get clusterpolicy
       error: the server doesn't have a resource type "clusterpolicy"

  2) Creating a new ClusterPolicy is rejected before it is ever admitted,
     because REST mapping fails at the client:

       \$ kubectl apply -f my-policy.yaml
       resource mapping not found for name: "..." namespace: "" from "...":
       no matches for kind "ClusterPolicy" in version "kyverno.io/v1"
       ensure CRDs are installed first

  3) The demo policy '${DEMO_POLICY}' is GONE. It was cascade-deleted together
     with its CRD — Kyverno is no longer enforcing anything it declared. The
     other Kyverno CRDs (policies.kyverno.io, policyreports, etc.) still exist;
     only the ClusterPolicy kind was deregistered.

  4) Confirm with:
       \$ kubectl get crd | grep kyverno.io        # clusterpolicies is missing
       \$ kubectl api-resources | grep -i clusterpolicy   # empty

${YELLOW}YOUR GOAL${NC}

  Restore the cluster so that ALL of the following are true again:

    [ ] 'kubectl get crd ${TARGET_CRD}' returns the CRD, Established=True
    [ ] 'kubectl explain clusterpolicy' resolves the schema
    [ ] 'kubectl get clusterpolicy' lists policies without error
    [ ] The demo policy '${DEMO_POLICY}' exists again and enforces its rule

  Think about the ordering that CRDs impose: the kind must be REGISTERED
  (CRD present and Established) BEFORE any custom resource of that kind can be
  recreated. A tidy backup of both was saved for you under:

       ${BACKUP_DIR}

  Try to recover it yourself first. The full walkthrough is at the bottom of
  this script, commented out.
================================================================================

BRIEF

exit 0

# ============================================================================
# ===============  SOLUTION — STEP BY STEP (read only if stuck)  ==============
# ============================================================================
#
# Mental model
# ------------
# A CustomResourceDefinition is a cluster-scoped object under the API group
# apiextensions.k8s.io/v1. It registers a new (group, version, kind) with the
# API server and installs an OpenAPI v3 validation schema for it. Two facts
# drive this whole drill:
#   * Without the CRD, kubectl's RESTMapper cannot map "ClusterPolicy" to a
#     REST path, so the failure happens client-side ("no matches for kind").
#   * Deleting a CRD triggers a cascading delete of every custom resource of
#     that kind (the CRs are children of the CRD, not of the Kyverno Pods),
#     which is why '${DEMO_POLICY}' disappeared.
#
# Step 1 — Confirm the diagnosis.
#   kubectl get crd | grep -i kyverno.io
#   kubectl api-resources --api-group=kyverno.io
#   # 'clusterpolicies' is absent; the other kyverno.io kinds are still there.
#
# Step 2 — Re-register the kind. Two valid paths:
#
#   (a) Canonical fix — reinstall from Kyverno's official manifest. This also
#       reconciles any other missing/updated CRDs and RBAC. Match your version:
#         kubectl apply --server-side \
#           -f https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VER}/install.yaml
#       (Docs: https://kyverno.io/docs/installation/methods/ )
#
#   (b) Offline fix — reapply the exact CRD you backed up before the break:
#         kubectl apply --server-side -f ${BACKUP_DIR}/crd-${TARGET_CRD}.yaml
#
# Step 3 — Wait until the CRD is actually Established (schema served) before
#          you create any CR against it — this is the ordering CRDs enforce:
#   kubectl wait --for=condition=Established crd/${TARGET_CRD} --timeout=60s
#   kubectl explain clusterpolicy.spec.rules       # schema resolves again
#
# Step 4 — Recreate the custom resources that were cascade-deleted:
#   kubectl apply -f ${BACKUP_DIR}/clusterpolicies.yaml
#   # (If the backup file only contains an empty List, just re-apply your own
#   #  policy YAML instead. resourceVersion/uid in the backup are ignored by
#   #  'kubectl apply'.)
#
# Step 5 — Verify enforcement is live again:
#   kubectl get clusterpolicy
#   kubectl get clusterpolicy ${DEMO_POLICY} -o jsonpath='{.status.ready}{"\n"}'
#   # Negative test — a Pod without the required 'team' label. In Audit mode it
#   # is admitted but a PolicyReport records the violation; switch the policy to
#   # validationFailureAction/failureAction: Enforce to have it blocked:
#   kubectl run kca-probe --image=busybox --restart=Never -- sleep 3600
#   kubectl get policyreport -A            # look for a 'fail' result on kca-probe
#   kubectl delete pod kca-probe --ignore-not-found
#
# Step 6 — (Optional) Clean up the lab artifact:
#   kubectl delete clusterpolicy ${DEMO_POLICY} --ignore-not-found
#   rm -rf ${BACKUP_DIR}
#
# Key takeaways
# -------------
#   * CRDs are the registration layer; delete one and its kind AND all its CRs
#     vanish together (cascade delete).
#   * Client-side "no matches for kind X in version Y" almost always means the
#     CRD is missing or not yet Established — not that your manifest is wrong.
#   * Ordering is intrinsic to CRDs: register the CRD, wait for Established,
#     THEN create custom resources. This is the same reason Kyverno's install
#     manifest lays down CRDs before policies.
#
# References
#   * KCA Curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#   * Kubernetes CRDs: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
#   * Kyverno policy/CRD reference: https://kyverno.io/docs/policy-types/
#   * Kyverno installation: https://kyverno.io/docs/installation/
# ============================================================================