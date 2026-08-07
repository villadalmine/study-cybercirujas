#!/usr/bin/env bash
#
# ============================================================================
#  CNPA — Break & Fix Lab
#  Topic 4.4: Kubernetes Operator Pattern for Integration and Automation
#  Exam weight: 3.0  |  Curriculum version: 2025-04-01
#  Reference: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  The Operator pattern extends Kubernetes with a CustomResourceDefinition
#  (the desired state, expressed as a domain object) plus a controller that
#  runs a level-based reconcile loop to make the actual state converge on it.
#  Two mechanics make an operator a reliable automation building block:
#
#    1. RBAC. The controller acts through its own ServiceAccount. It can only
#       reconcile what that identity is authorized to read and write. Strip the
#       permission and the loop keeps running but every action is denied — a
#       silent, running-but-useless operator.
#
#    2. Finalizers. Before an operator deletes external/child state it must run
#       cleanup. It does this by adding a finalizer to the custom resource; the
#       API server then blocks hard-deletion (object sticks in Terminating,
#       deletionTimestamp set) until the controller removes the finalizer. If
#       the controller cannot act, the object is wedged in Terminating forever.
#
#  This script deploys a genuine (if tiny) operator, proves it healthy, then
#  BREAKS its RBAC — coupling both failure modes above into one incident.
#
#  SAFETY
#  ------
#  Run ONLY on a disposable single-node lab cluster (kind / minikube / k3s in a
#  throwaway VM). Everything created is namespaced under 'cnpa-op-lab' plus one
#  CRD and one ClusterRole/ClusterRoleBinding, all clearly prefixed. A cleanup
#  block is provided (commented) at the very end. This script does not touch
#  kube-system or any pre-existing workload.
# ============================================================================

set -euo pipefail

# ---- Configuration ---------------------------------------------------------
NS="cnpa-op-lab"
CRD="widgets.ops.example.com"
GROUP="ops.example.com"
CRB="cnpa-op-lab-widget-operator"          # the object the break removes
CR_ROLE="cnpa-op-lab-widget-operator"
SA="widget-operator"
DEPLOY="widget-operator"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-bitnami/kubectl:latest}"   # needs bash + kubectl
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- Helpers ---------------------------------------------------------------
fail()      { echo "ERROR: $*" >&2; exit 1; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not installed."; }
hr()        { printf '%s\n' "----------------------------------------------------------------------"; }

need_cmd kubectl
need_cmd mktemp
kubectl cluster-info >/dev/null 2>&1 || fail "No reachable cluster (check your kubeconfig/context)."

CONTEXT="$(kubectl config current-context 2>/dev/null || echo unknown)"
echo
echo "This lab will CREATE an operator and then deliberately BREAK it."
echo "Target kube context : ${CONTEXT}"
echo "Namespace           : ${NS}  (created here)"
echo "Cluster-scoped items: CRD ${CRD}, ClusterRole/Binding ${CR_ROLE}"
echo
if [ "${LAB_CONFIRM:-}" != "yes" ] && [ "${1:-}" != "-y" ]; then
  read -r -p "Confirm this is a DISPOSABLE lab cluster. Type 'yes' to continue: " ANS
  [ "$ANS" = "yes" ] || fail "Aborted by user."
fi

# ============================================================================
#  STEP 1 — Build the healthy environment (the "before")
# ============================================================================
echo; hr; echo "[1/4] Deploying the CustomResourceDefinition and a working operator..."; hr

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- 1a. The CRD: this is the operator's API (the desired-state object) ------
kubectl apply -f - >/dev/null <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD}
  labels: { lab: cnpa-4-4 }
spec:
  group: ${GROUP}
  scope: Namespaced
  names:
    plural: widgets
    singular: widget
    kind: Widget
    shortNames: [wg]
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              message:
                type: string
            required: [message]
EOF

kubectl wait --for=condition=Established "crd/${CRD}" --timeout=60s >/dev/null

# --- 1b. The controller code (mounted into the operator pod) -----------------
#     A real, minimal level-based reconciler. It is the teaching artifact:
#     desired state (Widget.spec.message) -> actual state (child ConfigMap),
#     with a finalizer guaranteeing the child is cleaned up on delete.
cat > "$TMP/reconcile.sh" <<'RECONCILE'
#!/usr/bin/env bash
set -uo pipefail
NS="${WATCH_NAMESPACE:-cnpa-op-lab}"
FINALIZER="ops.example.com/cleanup"
export HOME=/tmp
export KUBECACHEDIR=/tmp/.kube/cache
log() { echo "[operator] $*"; }

log "reconcile loop started; watching Widgets in namespace ${NS}"
while true; do
  if ! items=$(kubectl get widgets.ops.example.com -n "$NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"|"}{.spec.message}{"\n"}{end}' 2>&1); then
    log "ERROR listing widgets (RBAC?): ${items}"
    sleep 5; continue
  fi
  printf '%s\n' "$items" | while IFS='|' read -r name del message; do
    [ -z "$name" ] && continue
    if [ -n "$del" ]; then
      # Object is being deleted: run cleanup, THEN drop the finalizer so the
      # API server can complete the delete.
      log "widget ${name} is Terminating -> finalizing (deleting child configmap)"
      kubectl delete configmap "widget-${name}" -n "$NS" --ignore-not-found >/dev/null 2>&1 \
        || log "ERROR deleting child configmap for ${name}"
      if ! out=$(kubectl patch widgets.ops.example.com "$name" -n "$NS" \
            --type=merge -p '{"metadata":{"finalizers":[]}}' 2>&1); then
        log "ERROR removing finalizer on ${name}: ${out}"
      fi
      continue
    fi
    # Ensure our finalizer is present before we create owned state.
    if ! out=$(kubectl patch widgets.ops.example.com "$name" -n "$NS" \
          --type=merge -p "{\"metadata\":{\"finalizers\":[\"${FINALIZER}\"]}}" 2>&1); then
      log "ERROR setting finalizer on ${name}: ${out}"
    fi
    # Drive actual state: the child ConfigMap must exist and match spec.message.
    if kubectl create configmap "widget-${name}" -n "$NS" \
         --from-literal=message="${message:-<none>}" \
         --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1; then
      log "reconciled widget ${name} -> configmap widget-${name}"
    else
      log "ERROR reconciling child configmap for ${name}"
    fi
  done
  sleep 8
done
RECONCILE

kubectl create configmap operator-code -n "$NS" \
  --from-file=reconcile.sh="$TMP/reconcile.sh" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- 1c. The operator identity + permissions (the thing we will break) -------
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA}
  namespace: ${NS}
  labels: { lab: cnpa-4-4 }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CR_ROLE}
  labels: { lab: cnpa-4-4 }
rules:
- apiGroups: ["${GROUP}"]
  resources: ["widgets"]
  verbs: ["get","list","watch","update","patch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get","list","watch","create","update","patch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB}
  labels: { lab: cnpa-4-4 }
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CR_ROLE}
subjects:
- kind: ServiceAccount
  name: ${SA}
  namespace: ${NS}
EOF

# --- 1d. The operator Deployment (the controller) ----------------------------
kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels: { app: widget-operator, lab: cnpa-4-4 }
spec:
  replicas: 1
  selector:
    matchLabels: { app: widget-operator }
  template:
    metadata:
      labels: { app: widget-operator }
    spec:
      serviceAccountName: ${SA}
      containers:
      - name: operator
        image: ${OPERATOR_IMAGE}
        command: ["/bin/bash", "/scripts/reconcile.sh"]
        env:
        - { name: WATCH_NAMESPACE, value: "${NS}" }
        - { name: HOME, value: "/tmp" }
        volumeMounts:
        - { name: code, mountPath: /scripts }
      volumes:
      - name: code
        configMap:
          name: operator-code
          items:
          - { key: reconcile.sh, path: reconcile.sh }
EOF

echo "Waiting for the operator pod to become Ready..."
kubectl rollout status "deploy/${DEPLOY}" -n "$NS" --timeout=180s \
  || fail "Operator failed to start (image pull? try: OPERATOR_IMAGE=<img> $0). "

# --- 1e. Create a Widget and prove the operator reconciles it ----------------
kubectl apply -f - >/dev/null <<EOF
apiVersion: ${GROUP}/v1
kind: Widget
metadata:
  name: alpha
  namespace: ${NS}
spec:
  message: "hello from alpha"
EOF

echo "Waiting for the operator to reconcile widget 'alpha' into a ConfigMap..."
OK=0
for _ in $(seq 1 40); do
  if kubectl get configmap widget-alpha -n "$NS" >/dev/null 2>&1; then OK=1; break; fi
  sleep 3
done
if [ "$OK" = "1" ]; then
  echo "  OK: configmap/widget-alpha exists — the operator is healthy."
else
  echo "  WARNING: alpha not reconciled yet; check 'kubectl logs deploy/${DEPLOY} -n ${NS}'."
fi

# ============================================================================
#  STEP 2 — THE BREAK  (do NOT read the solution at the bottom yet)
# ============================================================================
echo; hr; echo "[2/4] Breaking the environment..."; hr

# Remove the operator's authorization. The pod keeps running; every API call it
# makes is now denied. (A very common real incident: a GitOps prune or a
# "clean up unused RBAC" change deletes a binding that was actually load-bearing.)
kubectl delete clusterrolebinding "$CRB" >/dev/null 2>&1 || true

# Now enqueue new work the broken operator can no longer perform.
kubectl apply -f - >/dev/null <<EOF
apiVersion: ${GROUP}/v1
kind: Widget
metadata:
  name: beta
  namespace: ${NS}
spec:
  message: "hello from beta"
EOF

echo "Break applied."

# ============================================================================
#  STEP 3 — Brief the student
# ============================================================================
echo; hr; echo "[3/4] YOUR MISSION"; hr
cat <<BRIEF

SETUP
  A namespaced operator manages 'Widget' custom resources (CRD ${CRD}).
  For each Widget it maintains a child ConfigMap 'widget-<name>' and it puts a
  finalizer 'ops.example.com/cleanup' on the Widget so it can clean that child
  up on deletion. Everything lives in namespace '${NS}'.

SYMPTOMS YOU WILL OBSERVE
  * A new Widget 'beta' exists, but ConfigMap 'widget-beta' is NEVER created:
        kubectl get widgets,configmaps -n ${NS}
  * The operator pod is Running (not crashing), yet its log is full of denials:
        kubectl logs deploy/${DEPLOY} -n ${NS} --tail=20
    (look for: "cannot list ... widgets" / "forbidden")
  * Try to delete the older Widget and watch it WEDGE in Terminating forever
    (the operator can no longer remove its finalizer):
        kubectl delete widget alpha -n ${NS} --timeout=15s
        kubectl get widget alpha -n ${NS} -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'

WHAT "FIXED" MEANS — your goal
  1. The operator log stops printing "forbidden"/denied errors.
  2. ConfigMap 'widget-beta' appears (spec was reconciled into actual state).
  3. Widget 'alpha' finishes deleting on its own (finalizer gets removed) —
     it must NOT be stuck in Terminating, and you must NOT force it by hand.

CONSTRAINT
  Fix the *authorization*, not the symptom. Do not delete the CRD, do not edit
  finalizers by hand, and do not force-delete alpha — those hide the root cause
  instead of restoring the operator. Diagnose, then grant the operator exactly
  the identity it needs again.

  Useful probe:
        kubectl auth can-i patch widgets.${GROUP##*.}.example.com \\
          --as=system:serviceaccount:${NS}:${SA} -n ${NS}

BRIEF

echo; hr; echo "[4/4] Lab is armed. Diagnose and fix. Solution is at the bottom of this file."; hr
echo

exit 0

# ============================================================================
#  SOLUTION  (commented — try on your own first)
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  The operator authenticates as ServiceAccount ${NS}:${SA}. Its permissions
#  came entirely from a single ClusterRoleBinding (${CRB}) that granted the
#  ClusterRole ${CR_ROLE}. The break DELETED that binding. The ClusterRole
#  (the permission definition) still exists, but nothing binds the operator's
#  identity to it, so every request the controller makes is denied. RBAC is
#  evaluated per request, so no restart or new token is involved — the moment
#  the binding returns, the already-running pod is authorized again.
#
#  DIAGNOSIS (what you should have found)
#  --------------------------------------
#    # 1) The operator is Running but denied — points at authorization:
#    kubectl logs deploy/${DEPLOY} -n ${NS} --tail=20
#      # -> "cannot list resource \"widgets\" ... is forbidden: User
#      #     \"system:serviceaccount:${NS}:${SA}\" cannot list ..."
#
#    # 2) Confirm the identity is not allowed:
#    kubectl auth can-i list widgets.${GROUP} \
#      --as=system:serviceaccount:${NS}:${SA} -n ${NS}      # -> no
#
#    # 3) The ClusterRole exists but its binding is gone:
#    kubectl get clusterrole  ${CR_ROLE}                    # -> present
#    kubectl get clusterrolebinding ${CRB}                  # -> NotFound  <== cause
#
#  FIX (re-grant the identity)
#  ---------------------------
#    kubectl create clusterrolebinding ${CRB} \
#      --clusterrole=${CR_ROLE} \
#      --serviceaccount=${NS}:${SA}
#
#    # (equivalent declarative form)
#    # kubectl apply -f - <<'YAML'
#    # apiVersion: rbac.authorization.k8s.io/v1
#    # kind: ClusterRoleBinding
#    # metadata: { name: ${CRB}, labels: { lab: cnpa-4-4 } }
#    # roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ${CR_ROLE} }
#    # subjects: [ { kind: ServiceAccount, name: ${SA}, namespace: ${NS} } ]
#    # YAML
#
#  VERIFY (all three must hold)
#  ----------------------------
#    kubectl auth can-i patch widgets.${GROUP} \
#      --as=system:serviceaccount:${NS}:${SA} -n ${NS}      # -> yes
#
#    # within ~10s (one reconcile tick) beta is reconciled:
#    kubectl get configmap widget-beta -n ${NS}             # -> exists
#
#    # and alpha, if you deleted it, finalizes and disappears on its own:
#    kubectl get widget alpha -n ${NS}                      # -> NotFound
#    kubectl logs deploy/${DEPLOY} -n ${NS} --tail=10       # -> "reconciled ...", no "forbidden"
#
#  WHY THE HANG HAPPENED (the finalizer lesson)
#  --------------------------------------------
#  'kubectl delete widget alpha' only set a deletionTimestamp; the API server
#  will not remove the object while the finalizer 'ops.example.com/cleanup' is
#  present. Removing that finalizer is the OPERATOR'S job (after it deletes the
#  child ConfigMap). With RBAC broken the operator could not patch the Widget,
#  so alpha was pinned in Terminating. Restoring RBAC let the operator complete
#  its finalizer logic — which is exactly why the correct fix is to restore the
#  binding, not to strip the finalizer by hand. (Manually forcing it with
#  'kubectl patch alpha -p '{"metadata":{"finalizers":[]}}'' would delete the
#  Widget but ORPHAN its child ConfigMap — the leak the finalizer exists to
#  prevent.)
#
#  CLEAN UP THE LAB
#  ----------------
#    kubectl delete namespace ${NS} --ignore-not-found
#    kubectl delete clusterrolebinding ${CRB} --ignore-not-found
#    kubectl delete clusterrole ${CR_ROLE} --ignore-not-found
#    kubectl delete crd ${CRD} --ignore-not-found
#
#  REFERENCES
#  ----------
#   - Operator pattern:        https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
#   - Custom Resources / CRDs: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
#   - Finalizers:              https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
#   - RBAC:                    https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#   - CNPA Curriculum:         https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ============================================================================