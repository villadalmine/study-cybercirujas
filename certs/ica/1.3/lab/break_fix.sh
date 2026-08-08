#!/usr/bin/env bash
#
# ============================================================================
#  ICA — Istio Certified Associate
#  Domain 1: Installation, Upgrade & Configuration
#  Topic 1.3 — Customizing your Istio Installation   (exam weight: 5)
#
#  BREAK & FIX LAB — "The customization that silently never rolls out"
#
#  This script INTENTIONALLY breaks an Istio installation on a DISPOSABLE
#  lab VM/cluster so you can practice diagnosing and repairing a bad
#  installation customization applied through the IstioOperator API.
#
#  DO NOT run this against anything you care about. It mutates the Istio
#  control-plane installation in the current kube-context.
#
#  Reference sources (official):
#    - ICA curriculum:
#        https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#    - Install with istioctl:
#        https://istio.io/latest/docs/setup/install/istioctl/
#    - Customizing the configuration (IstioOperator overrides):
#        https://istio.io/latest/docs/setup/additional-setup/customize-installation/
#    - Installation configuration profiles:
#        https://istio.io/latest/docs/setup/additional-setup/config-profiles/
#    - IstioOperator API reference:
#        https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
ISTIO_NS="istio-system"
GW_LABEL="app=istio-ingressgateway"
GW_DEPLOY="istio-ingressgateway"
BASE_PROFILE="default"          # 'default' includes istiod + istio-ingressgateway
BAD_CPU="2000"                  # 2000 CPU cores: unschedulable on any real node
WORKDIR="${WORKDIR:-./ica-1.3-lab}"
READINESS_TIMEOUT="45s"         # keep the broken install from hanging forever

# ----------------------------------------------------------------------------
# Pretty logging
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=""; RED=""; GRN=""; YLW=""; CYN=""; RST=""
fi
info() { echo "${CYN}[*]${RST} $*"; }
ok()   { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
need() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }
}
need kubectl
need istioctl

info "kubectl client / server:"
kubectl version --output=yaml 2>/dev/null | grep -E 'gitVersion|major|minor' | head -n 8 || true
info "istioctl version:"
istioctl version --remote=false 2>/dev/null || istioctl version 2>/dev/null || true

CTX="$(kubectl config current-context 2>/dev/null || echo '<none>')"
hr
warn "Current kube-context: ${BOLD}${CTX}${RST}"
warn "This lab will reinstall and then BREAK the Istio control plane in namespace '${ISTIO_NS}'."

# ----------------------------------------------------------------------------
# Safety guard — refuse to run unless the operator confirms it is a throwaway lab
# ----------------------------------------------------------------------------
if [[ "${ICA_LAB_CONFIRM:-}" != "yes" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Type 'yes' to confirm this is a DISPOSABLE lab cluster: " ans
    [[ "$ans" == "yes" ]] || { err "Aborted by user."; exit 1; }
  else
    err "Refusing to run non-interactively. Re-run with: ICA_LAB_CONFIRM=yes $0"
    exit 1
  fi
fi

mkdir -p "$WORKDIR"

# ----------------------------------------------------------------------------
# STEP 0 — Establish a known-good baseline (idempotent)
#   'istioctl install' is idempotent; re-running converges to the manifest.
# ----------------------------------------------------------------------------
hr
info "Ensuring a healthy baseline Istio install (profile: ${BASE_PROFILE}) ..."
cat > "${WORKDIR}/baseline.yaml" <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: ica-lab-install
spec:
  profile: ${BASE_PROFILE}
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

istioctl install -y -f "${WORKDIR}/baseline.yaml"
kubectl -n "${ISTIO_NS}" rollout status deploy/istiod --timeout=180s
kubectl -n "${ISTIO_NS}" rollout status deploy/"${GW_DEPLOY}" --timeout=180s
ok "Baseline is healthy. Snapshot of the working state:"
kubectl -n "${ISTIO_NS}" get pods -o wide

# ----------------------------------------------------------------------------
# STEP 1 — Introduce the fault: a customization that cannot schedule
#   We override components.ingressGateways[0].k8s.resources.requests.cpu with an
#   impossible value. This is a perfectly VALID IstioOperator document — it
#   parses, istioctl accepts it, the Deployment is patched — but the new pod can
#   never be scheduled, so the rollout stalls while the old ReplicaSet keeps
#   serving. This is a classic, subtle production trap.
# ----------------------------------------------------------------------------
hr
warn "Injecting the broken customization (ingress gateway requests cpu=${BAD_CPU}) ..."
cat > "${WORKDIR}/broken.yaml" <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: ica-lab-install
spec:
  profile: ${BASE_PROFILE}
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        resources:
          requests:
            cpu: "${BAD_CPU}"     # <-- 2000 cores: no node can satisfy this
            memory: "128Mi"
EOF

# The install will not reach readiness; we cap the wait and continue on purpose.
istioctl install -y -f "${WORKDIR}/broken.yaml" --readiness-timeout "${READINESS_TIMEOUT}" || \
  warn "istioctl reported the install did not become ready (expected for this lab)."

# ----------------------------------------------------------------------------
# STEP 2 — Show the student the observable symptom
# ----------------------------------------------------------------------------
hr
echo "${BOLD}=== SYMPTOM YOU WILL OBSERVE ===${RST}"
echo
echo "Ingress gateway pods (note a new pod stuck in Pending):"
kubectl -n "${ISTIO_NS}" get pods -l "${GW_LABEL}" -o wide || true
echo
echo "Rollout status (this will time out — the customization never lands):"
kubectl -n "${ISTIO_NS}" rollout status deploy/"${GW_DEPLOY}" --timeout=15s || true
echo
echo "Scheduler verdict for the pending pod:"
kubectl -n "${ISTIO_NS}" describe pod -l "${GW_LABEL}" 2>/dev/null \
  | sed -n '/Events:/,$p' | tail -n 15 || true

hr
cat <<'BRIEF'
=========================  YOUR MISSION  ===================================

WHAT HAPPENED
  You "customized" the Istio installation by overriding the ingress gateway's
  CPU resource request through the IstioOperator API. The document is valid and
  istioctl applied it, but the resulting Pod requests more CPU than any node can
  provide. Because a Deployment rolling update surges a NEW pod before removing
  the old one, the new pod is stuck 'Pending' (FailedScheduling / Insufficient
  cpu) while the OLD pod keeps serving. The rollout is wedged — your change
  never takes effect, and nothing crashes loudly to tell you so.

EXPECTED SYMPTOMS
  * `kubectl -n istio-system get pods -l app=istio-ingressgateway` shows a pod
    in 'Pending' (0/1) that never becomes Ready.
  * `kubectl -n istio-system rollout status deploy/istio-ingressgateway` hangs
    / times out ("Waiting for deployment ... rollout to finish").
  * `kubectl describe pod` Events show:
       "0/N nodes are available: N Insufficient cpu."
  * `istioctl verify-install` reports the installation is not fully applied.

YOUR GOAL (do NOT disable the gateway — that is cheating the objective)
  Restore a clean, fully rolled-out istio-ingressgateway by correcting the
  resource customization THROUGH the IstioOperator, then prove it:
    1. All pods in istio-system are Running and Ready.
    2. `kubectl -n istio-system rollout status deploy/istio-ingressgateway`
       returns "successfully rolled out".
    3. `istioctl verify-install` passes.

HINTS
  * The fault is in what you APPLIED, not in the cluster. Find the offending
    value, compare it against the profile defaults, and reapply a sane manifest.
  * Useful lenses:
      istioctl profile dump default | grep -A8 'resources'
      kubectl -n istio-system get deploy istio-ingressgateway \
        -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
  * Remember: `istioctl install` is idempotent and declarative — reapplying a
    corrected IstioOperator converges the cluster; you don't hand-edit the
    Deployment (that would be reverted on the next reconcile/upgrade).

============================================================================
BRIEF

ok "Break injected. The lab is ready for you to diagnose and fix."
echo "Working files are in: ${WORKDIR}/  (baseline.yaml, broken.yaml)"

exit 0

# ============================================================================
#  SOLUTION — step by step  (read only after attempting the fix yourself)
# ============================================================================
#
# 1) CONFIRM THE SYMPTOM
#    ------------------------------------------------------------------------
#    kubectl -n istio-system get pods -l app=istio-ingressgateway
#      # istio-ingressgateway-xxxxxxxxxx-yyyyy   0/1   Pending   0   2m
#
#    kubectl -n istio-system rollout status deploy/istio-ingressgateway --timeout=10s
#      # Waiting for deployment "istio-ingressgateway" rollout to finish:
#      # 1 old replicas are pending termination...   (times out)
#
# 2) ASK THE SCHEDULER WHY
#    ------------------------------------------------------------------------
#    kubectl -n istio-system describe pod -l app=istio-ingressgateway \
#      | sed -n '/Events:/,$p'
#      # Warning  FailedScheduling  ...  0/1 nodes are available:
#      #          1 Insufficient cpu. preemption: 0/1 nodes are available...
#
#    The pod is unschedulable — this is a resource request problem, not a crash.
#
# 3) LOCATE THE BAD CUSTOMIZATION (in what was applied, not the cluster)
#    ------------------------------------------------------------------------
#    # What the running Deployment is asking for:
#    kubectl -n istio-system get deploy istio-ingressgateway \
#      -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}'
#      # 2000
#
#    # The effective installed IstioOperator (present when installed via istioctl):
#    kubectl -n istio-system get istiooperator installed-state -o yaml 2>/dev/null \
#      | grep -A6 ingressGateways || true
#
#    # ...and the source of truth is the file you applied:
#    grep -A6 resources ./ica-1.3-lab/broken.yaml
#      # cpu: "2000"   <-- impossible
#
# 4) COMPARE AGAINST PROFILE DEFAULTS (so you pick a sane value)
#    ------------------------------------------------------------------------
#    istioctl profile dump default | grep -A8 'ingressGateways' | grep -A6 resources
#      # default ingress gateway request is cpu: 100m, memory: 128Mi
#
# 5) FIX IT THROUGH THE IstioOperator AND REAPPLY (declarative, idempotent)
#    ------------------------------------------------------------------------
#    cat > ./ica-1.3-lab/fixed.yaml <<'YAML'
#    apiVersion: install.istio.io/v1alpha1
#    kind: IstioOperator
#    metadata:
#      name: ica-lab-install
#    spec:
#      profile: default
#      components:
#        ingressGateways:
#        - name: istio-ingressgateway
#          enabled: true
#          k8s:
#            resources:
#              requests:
#                cpu: "100m"      # realistic, fits the node
#                memory: "128Mi"
#    YAML
#
#    # Preview the change before applying (optional but good practice):
#    istioctl manifest generate -f ./ica-1.3-lab/fixed.yaml \
#      | grep -A6 'name: istio-ingressgateway' | grep -A4 requests
#
#    istioctl install -y -f ./ica-1.3-lab/fixed.yaml
#
# 6) VERIFY THE FIX
#    ------------------------------------------------------------------------
#    kubectl -n istio-system rollout status deploy/istio-ingressgateway --timeout=180s
#      # deployment "istio-ingressgateway" successfully rolled out
#
#    kubectl -n istio-system get pods -l app=istio-ingressgateway
#      # istio-ingressgateway-...   1/1   Running
#
#    istioctl verify-install
#      # ... Istio is installed and verified successfully
#
# 7) WHY THIS MATTERS (the production lesson)
#    ------------------------------------------------------------------------
#    * A syntactically VALID installation customization can still be operationally
#      broken. `k8s.resources.requests` overrides under components.<component>
#      must fit real node capacity, or the pod is unschedulable.
#    * Rolling updates surge before terminating: a bad customization can stall
#      indefinitely while the previous version keeps serving traffic, so the
#      failure is silent until you check rollout/verify-install.
#    * Always gate customizations with `istioctl manifest generate` (diff/preview)
#      and confirm convergence with `rollout status` + `istioctl verify-install`.
#    * Never hand-patch the generated Deployment: `istioctl install` reconciles
#      from the IstioOperator, so out-of-band edits are reverted on the next
#      apply/upgrade. Fix the customization at its source.
#
# ============================================================================