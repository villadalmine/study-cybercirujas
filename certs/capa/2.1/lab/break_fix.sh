#!/usr/bin/env bash
#
# ============================================================================
#  CAPA — Certified Argo Project Associate
#  Domain 2.1: Argo Workflows  (exam weight: 20%)
#  Break & Fix lab:  "The output parameter that vanished" — Workflow RBAC
# ============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  In Argo Workflows the *controller* creates the workflow Pods, but each Pod
#  runs under the *Workflow's own ServiceAccount* (spec.serviceAccountName,
#  default: "default"). Since the Emissary executor became the default (v3.4+),
#  that ServiceAccount is what the in-Pod executor uses to report a step's
#  results back to the control plane by creating/patching a
#  `workflowtaskresults.argoproj.io` object. Output parameters, `outputs.result`,
#  artifact metadata and node status all travel through that object.
#
#  Strip the ServiceAccount of that permission and the Pod still starts, the
#  container still runs — but the step's result never reaches the controller.
#  Any downstream step that consumes `{{steps.X.outputs.result}}` breaks, and
#  the Workflow ends Failed/Error. This is one of the most common and most
#  confusing production failures in Argo Workflows, precisely because "the Pod
#  ran fine" and yet "the Workflow failed."
#
#  SAFETY
#  ------
#  * Everything happens inside a throwaway namespace (default: capa-lab-argowf).
#  * The break is the deletion of ONE RoleBinding that this script created.
#  * It touches nothing in the argo system namespace and nothing cluster-wide.
#  * It is fully reversible; `--cleanup` deletes the whole lab namespace.
#  RUN ONLY ON A DISPOSABLE LAB CLUSTER / VM.
#
#  Official sources (verify, do not memorize):
#   - Workflow RBAC ......... https://argo-workflows.readthedocs.io/en/latest/workflow-rbac/
#   - Service Accounts ...... https://argo-workflows.readthedocs.io/en/latest/service-accounts/
#   - Emissary executor ..... https://argo-workflows.readthedocs.io/en/latest/workflow-executors/
#   - Quick start / install . https://argo-workflows.readthedocs.io/en/latest/quick-start/
#   - Project repo .......... https://github.com/argoproj/argo-workflows
#   - CAPA curriculum ....... https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
# ============================================================================

set -euo pipefail

# --- Tunables (override via environment) ------------------------------------
NS="${NS:-capa-lab-argowf}"
SA="${SA:-wf-runner}"
ROLE="${ROLE:-wf-runner-role}"
BINDING="${BINDING:-wf-runner-binding}"
ARGO_NS="${ARGO_NS:-argo}"
ARGO_VERSION="${ARGO_VERSION:-v3.6.4}"
IMAGE="${IMAGE:-busybox:1.36}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-150}"     # seconds to wait for a workflow to settle
ASSUME_YES="${ASSUME_YES:-false}"
DO_INSTALL="false"
DO_CLEANUP="false"

# --- Pretty logging ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\e[0m'; C_B=$'\e[1m'; C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi
say()  { printf '%s\n' "${C_C}==>${C_RST} $*"; }
ok()   { printf '%s\n' "${C_G} ok${C_RST} $*"; }
warn() { printf '%s\n' "${C_Y}!! ${C_RST} $*"; }
die()  { printf '%s\n' "${C_R}xx ${C_RST} $*" >&2; exit 1; }
rule() { printf '%s\n' "${C_B}--------------------------------------------------------------------------${C_RST}"; }

usage() {
  cat <<EOF
CAPA 2.1 Argo Workflows — break & fix lab

Usage: $0 [--yes] [--install] [--cleanup] [--help]

  --yes       Do not prompt for confirmation (non-interactive labs / CI).
  --install   If Argo Workflows is not detected, install the cluster build
              ${ARGO_VERSION} into the '${ARGO_NS}' namespace (watches all namespaces).
  --cleanup   Delete the lab namespace '${NS}' and exit. Does not remove Argo.
  --help      Show this help.

Environment overrides: NS, SA, ARGO_NS, ARGO_VERSION, IMAGE, WAIT_TIMEOUT, ASSUME_YES
EOF
}

# --- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)     ASSUME_YES="true" ;;
    --install) DO_INSTALL="true" ;;
    --cleanup) DO_CLEANUP="true" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# --- Preflight --------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl version -o json >/dev/null 2>&1 || kubectl cluster-info >/dev/null 2>&1 \
  || die "No reachable Kubernetes cluster. Point KUBECONFIG at your lab cluster."

CTX="$(kubectl config current-context 2>/dev/null || echo '<none>')"

if [[ "$DO_CLEANUP" == "true" ]]; then
  say "Cleaning up lab namespace '${NS}' on context '${CTX}' ..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  ok "Requested deletion of namespace '${NS}'. Argo left untouched."
  exit 0
fi

rule
printf '%s\n' "${C_B} CAPA 2.1 — Argo Workflows :: BREAK & FIX${C_RST}"
rule
say "kube-context : ${C_B}${CTX}${C_RST}"
say "lab namespace: ${C_B}${NS}${C_RST}  (throwaway)"
warn "This lab intentionally BREAKS a ServiceAccount's RBAC. Use a disposable cluster."
if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Type 'break' to proceed against context '${CTX}': " REPLY
  [[ "$REPLY" == "break" ]] || die "Aborted by user."
fi

# --- Ensure Argo Workflows is present ---------------------------------------
if ! kubectl get crd workflows.argoproj.io >/dev/null 2>&1; then
  if [[ "$DO_INSTALL" == "true" ]]; then
    say "Argo Workflows not found. Installing cluster build ${ARGO_VERSION} into '${ARGO_NS}' ..."
    kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -
    # Official cluster install manifest (controller watches ALL namespaces).
    kubectl -n "$ARGO_NS" apply -f \
      "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/install.yaml"
    say "Waiting for the workflow-controller to become ready ..."
    kubectl -n "$ARGO_NS" rollout status deploy/workflow-controller --timeout=180s
    ok "Argo Workflows ${ARGO_VERSION} is up."
  else
    die "Argo Workflows CRDs not found. Install it (docs: quick-start) or re-run with --install."
  fi
else
  ok "Argo Workflows CRDs detected."
fi

# ============================================================================
#  STEP 1 — Build a HEALTHY, least-privilege lab (idempotent)
# ============================================================================
say "Creating lab namespace, ServiceAccount and least-privilege executor RBAC ..."

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create serviceaccount "$SA" --dry-run=client -o yaml | kubectl apply -f -

# The documented minimum an Argo Workflow ServiceAccount needs so the Emissary
# executor can report step results. workflowtaskresults create/patch is the
# critical rule — that is what we will remove in the break.
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE}
  namespace: ${NS}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "watch", "patch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "watch"]
  - apiGroups: ["argoproj.io"]
    resources: ["workflowtaskresults"]
    verbs: ["create", "patch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BINDING}
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE}
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${NS}
EOF
ok "Least-privilege RBAC applied."

# --- Reusable helpers -------------------------------------------------------
# A two-step Workflow: 'produce' emits a value on stdout (outputs.result),
# 'consume' receives it as a parameter. The result travels via workflowtaskresults,
# so this Workflow FAILS deterministically the moment that permission is gone.
submit_workflow() {  # prints the created workflow name
  kubectl -n "$NS" create -o name -f - <<EOF | sed 's#.*/##'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: capa-rbac-
spec:
  entrypoint: main
  serviceAccountName: ${SA}
  templates:
    - name: main
      steps:
        - - name: produce
            template: produce
        - - name: consume
            template: consume
            arguments:
              parameters:
                - name: msg
                  value: "{{steps.produce.outputs.result}}"
    - name: produce
      script:
        image: ${IMAGE}
        command: [sh]
        source: |
          echo "payload-from-produce"
    - name: consume
      inputs:
        parameters:
          - name: msg
      container:
        image: ${IMAGE}
        command: [sh, -c]
        args: ["echo 'consume received ->' '{{inputs.parameters.msg}}'"]
EOF
}

wait_for_phase() {  # $1=wf name -> prints final phase
  local wf="$1" phase="" i=0
  while (( i < WAIT_TIMEOUT )); do
    phase="$(kubectl -n "$NS" get wf "$wf" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded|Failed|Error) echo "$phase"; return 0 ;;
    esac
    sleep 3; i=$((i+3))
  done
  echo "${phase:-Pending}"
}

show_nodes() {  # $1=wf name
  kubectl -n "$NS" get wf "$1" \
    -o jsonpath='{range .status.nodes.*}{"  - "}{.displayName}{" ["}{.phase}{"] "}{.message}{"\n"}{end}' \
    2>/dev/null || true
}

show_executor_evidence() {  # $1=wf name — dumps the forbidden line from the wait container
  local pods
  pods="$(kubectl -n "$NS" get pods -l "workflows.argoproj.io/workflow=$1" -o name 2>/dev/null || true)"
  for p in $pods; do
    kubectl -n "$NS" logs "$p" -c wait 2>/dev/null | grep -i "forbidden" | sed 's/^/  /' || true
  done
}

# ============================================================================
#  STEP 2 — Prove the environment is HEALTHY (baseline)
# ============================================================================
say "Submitting a baseline workflow (RBAC intact) — this MUST succeed ..."
BASE_WF="$(submit_workflow)"
say "Submitted: ${C_B}${BASE_WF}${C_RST}. Waiting up to ${WAIT_TIMEOUT}s ..."
BASE_PHASE="$(wait_for_phase "$BASE_WF")"
if [[ "$BASE_PHASE" == "Succeeded" ]]; then
  ok "Baseline succeeded — output parameter passing works end to end."
else
  show_nodes "$BASE_WF"
  die "Baseline did NOT succeed (phase=${BASE_PHASE}). Fix the cluster before running the break."
fi

# ============================================================================
#  STEP 3 — THE BREAK  (safe, isolated, reversible)
# ============================================================================
rule
say "${C_R}BREAKING:${C_RST} deleting RoleBinding '${BINDING}' in namespace '${NS}'."
say "The ServiceAccount '${SA}' keeps existing, but loses ALL its Role grants —"
say "including 'workflowtaskresults: create/patch'. Nothing else is touched."
kubectl -n "$NS" delete rolebinding "$BINDING" --ignore-not-found
ok "RoleBinding removed. The environment is now broken."

# ============================================================================
#  STEP 4 — Reproduce the SYMPTOM
# ============================================================================
say "Submitting the SAME workflow again (RBAC now broken) ..."
BAD_WF="$(submit_workflow)"
say "Submitted: ${C_B}${BAD_WF}${C_RST}. Waiting up to ${WAIT_TIMEOUT}s ..."
BAD_PHASE="$(wait_for_phase "$BAD_WF")"

rule
printf '%s\n' "${C_B} SYMPTOM${C_RST}"
rule
echo "Workflow phase : ${C_R}${BAD_PHASE}${C_RST}  (was 'Succeeded' one minute ago)"
echo "Node breakdown :"
show_nodes "$BAD_WF"
echo "Executor evidence (produce Pod, 'wait' container):"
if ! show_executor_evidence "$BAD_WF" | grep -q .; then
  echo "  (no 'forbidden' line captured yet — inspect manually, see hints below)"
fi
cat <<EOF

What you are seeing and WHY:
  * The 'produce' Pod is created and its 'main' container runs fine — the image
    exists, the command exits 0. The Pod is NOT the problem.
  * The Emissary executor ('wait' container) then tries to POST a
    'workflowtaskresults.argoproj.io' object to report the step's result, using
    the token of ServiceAccount '${SA}'. That call is now 403 Forbidden.
  * Because 'produce.outputs.result' never reaches the controller, the step is
    marked Error and '{{steps.produce.outputs.result}}' cannot be resolved for
    'consume'. The Workflow ends ${BAD_PHASE}. "The Pod ran, the Workflow failed."

EOF

# ============================================================================
#  YOUR MISSION
# ============================================================================
rule
printf '%s\n' "${C_B} YOUR MISSION${C_RST}"
rule
cat <<EOF
Goal: make a freshly submitted workflow in namespace '${NS}' reach phase
      'Succeeded' again, with 'consume' printing the value produced upstream —
      WITHOUT weakening security (no cluster-admin, no cluster-wide grants).
      The fix must stay least-privilege and scoped to '${NS}'.

Success check:
  WF=\$(kubectl -n ${NS} create -o name -f <your-or-this-workflow> | sed 's#.*/##')
  kubectl -n ${NS} get wf \$WF -w        # expect: Succeeded

Diagnostic hints (work top-down — do not jump to the answer):
  1. Confirm the control plane is healthy:
       kubectl -n ${ARGO_NS} get deploy workflow-controller
     (If the controller were down, workflows would sit 'Pending' with NO pods.
      Here the Pod DID run — so the controller is fine. Different symptom, note it.)
  2. Read the failing node's message:
       kubectl -n ${NS} get wf ${BAD_WF} -o jsonpath='{.status.nodes}' | tr ',' '\n' | grep -i forbid
  3. Read the executor logs of the produce Pod's 'wait' container:
       kubectl -n ${NS} logs -l workflows.argoproj.io/workflow=${BAD_WF} -c wait | grep -i forbidden
     The message names the exact User (ServiceAccount), verb and resource denied.
  4. Ask the API server directly whether the SA may do it:
       kubectl auth can-i create workflowtaskresults \\
         --as=system:serviceaccount:${NS}:${SA} -n ${NS}
     A 'no' here is the smoking gun.
  5. Inspect what the SA is (not) bound to:
       kubectl -n ${NS} get rolebinding
       kubectl -n ${NS} get role ${ROLE} -o yaml
  Then restore exactly the missing grant. Re-run step 4 until it says 'yes',
  then re-submit and confirm 'Succeeded'.

When you have solved it (or want to compare), read the commented SOLUTION below.
EOF
rule
exit 0

# ============================================================================
# ============================  S O L U T I O N  =============================
# ============================================================================
# Do not read past here until you have attempted the fix yourself.
#
# ROOT CAUSE
# ----------
# The Workflow's ServiceAccount ('${SA}') exists, but its RoleBinding was
# deleted, so it now has zero permissions. The Emissary executor (default since
# Argo Workflows v3.4) reports each step's result by creating a
# 'workflowtaskresults.argoproj.io' object under that ServiceAccount's identity.
# Without 'create/patch' on that resource the executor gets 403 Forbidden, the
# step's 'outputs.result' never reaches the controller, the downstream 'consume'
# step cannot resolve '{{steps.produce.outputs.result}}', and the Workflow fails.
# Ref: https://argo-workflows.readthedocs.io/en/latest/workflow-rbac/
#
# STEP-BY-STEP FIX
# ----------------
# 1) Diagnose — confirm the ServiceAccount is being denied:
#
#      kubectl auth can-i create workflowtaskresults \
#        --as=system:serviceaccount:${NS}:${SA} -n ${NS}
#      # -> no        (this is the failure)
#
#      kubectl -n ${NS} get rolebinding
#      # -> the '${BINDING}' RoleBinding is gone; the Role '${ROLE}' still exists.
#
# 2) Fix — recreate the least-privilege RoleBinding that ties the existing Role
#    to the ServiceAccount. Do NOT grant cluster-admin; keep it scoped to '${NS}'.
#    (The Role '${ROLE}' already carries the correct minimal rules, including
#     'argoproj.io/workflowtaskresults: [create, patch, get]'.)
#
#      kubectl apply -f - <<'YAML'
#      apiVersion: rbac.authorization.k8s.io/v1
#      kind: RoleBinding
#      metadata:
#        name: ${BINDING}
#        namespace: ${NS}
#      roleRef:
#        apiGroup: rbac.authorization.k8s.io
#        kind: Role
#        name: ${ROLE}
#      subjects:
#        - kind: ServiceAccount
#          name: ${SA}
#          namespace: ${NS}
#      YAML
#
#    (If the Role itself had also been lost, recreate it with exactly these rules:
#       - "" / pods                      : get, watch, patch
#       - "" / pods/log                  : get, watch
#       - argoproj.io / workflowtaskresults : create, patch, get
#     — that is the documented minimum for a Workflow ServiceAccount.)
#
# 3) Verify the permission is back BEFORE re-running the workflow:
#
#      kubectl auth can-i create workflowtaskresults \
#        --as=system:serviceaccount:${NS}:${SA} -n ${NS}
#      # -> yes
#
# 4) Re-submit and confirm success (RBAC is checked at execution time, so a
#    brand-new submission is the clean test):
#
#      WF=$(kubectl -n ${NS} create -o name -f - <<'YAML' | sed 's#.*/##'
#      apiVersion: argoproj.io/v1alpha1
#      kind: Workflow
#      metadata:
#        generateName: capa-rbac-fixed-
#      spec:
#        entrypoint: main
#        serviceAccountName: ${SA}
#        templates:
#          - name: main
#            steps:
#              - - {name: produce, template: produce}
#              - - name: consume
#                  template: consume
#                  arguments:
#                    parameters: [{name: msg, value: "{{steps.produce.outputs.result}}"}]
#          - name: produce
#            script: {image: ${IMAGE}, command: [sh], source: "echo payload-from-produce"}
#          - name: consume
#            inputs: {parameters: [{name: msg}]}
#            container:
#              image: ${IMAGE}
#              command: [sh, -c]
#              args: ["echo 'consume received ->' '{{inputs.parameters.msg}}'"]
#      YAML
#      )
#      kubectl -n ${NS} get wf "$WF" -w        # -> Succeeded
#      kubectl -n ${NS} logs -l workflows.argoproj.io/workflow="$WF" -c main | grep 'consume received'
#      # -> consume received -> payload-from-produce
#
# 5) Tear down the lab when finished:
#
#      $0 --cleanup        # deletes namespace '${NS}'; leaves Argo installed
#
# KEY TAKEAWAYS (exam-relevant)
# -----------------------------
#  * The controller creates Pods; the Workflow's ServiceAccount is what the
#    in-Pod executor uses. They are two different identities with two different
#    RBAC needs — diagnose which one is denied.
#  * 'workflowtaskresults: create/patch' is mandatory for the Emissary executor;
#    lose it and steps run but never report — output parameters/artifacts break.
#  * 'kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>' is the fastest way
#    to confirm an Argo RBAC problem, independent of any workflow.
#  * Least privilege: bind a scoped Role in the workflow's namespace; never reach
#    for cluster-admin to "make it work."
#  Refs:
#   - https://argo-workflows.readthedocs.io/en/latest/workflow-rbac/
#   - https://argo-workflows.readthedocs.io/en/latest/service-accounts/
#   - https://argo-workflows.readthedocs.io/en/latest/workflow-executors/
# ============================================================================