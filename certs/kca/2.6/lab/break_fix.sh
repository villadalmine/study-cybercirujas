#!/usr/bin/env bash
#
# ==============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 2.6: Upgrading Kyverno   (exam weight: 3.0)
#
#  BREAK & FIX LAB — "The botched upgrade"
#
#  What this lab teaches
#  ---------------------
#  Upgrading Kyverno is not "bump the image tag". Kyverno 1.10+ ships as FOUR
#  independent controllers (admission, background, cleanup, reports) that must
#  move together, its CRDs are NOT upgraded by `helm upgrade` (a Helm design
#  limitation), and a version skew or a dead admission controller mid-upgrade
#  can wedge the API for every resource the webhooks intercept.
#
#  This script simulates an upgrade that pointed the admission controller at an
#  incompatible / non-existent image and took the Deployment down. You will see
#  the real production symptom: the admission webhook can no longer be reached,
#  so the API SERVER itself starts rejecting requests it used to allow.
#
#  Sources (official)
#  ------------------
#   - Upgrading Kyverno .......... https://kyverno.io/docs/installation/upgrading/
#   - Install methods (Helm) ..... https://kyverno.io/docs/installation/methods/
#   - Compatibility matrix ....... https://kyverno.io/docs/installation/#compatibility-matrix
#   - High availability / arch ... https://kyverno.io/docs/high-availability/
#   - KCA curriculum ............. https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#
#  !!!  DISPOSABLE LAB VM ONLY  !!!
#  This intentionally degrades a Kyverno install and can block resource
#  creation cluster-wide. Run it ONLY against a throwaway kind/minikube cluster.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
NS="kyverno"
POLICY_NAME="kca-require-team-label"
STATE_FILE="/tmp/kca-2.6-break.env"
# A tag that does not exist upstream -> guarantees ImagePullBackOff, simulating
# an "upgrade" to an incompatible / typo'd version.
BROKEN_TAG="v1.14.99-broken-upgrade"

# ------------------------------------------------------------------------------
# Pretty logging
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_CYN=$'\033[0;36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_RST=""
fi
info()  { echo "${C_CYN}[*]${C_RST} $*"; }
ok()    { echo "${C_GRN}[+]${C_RST} $*"; }
warn()  { echo "${C_YEL}[!]${C_RST} $*"; }
err()   { echo "${C_RED}[x]${C_RST} $*" >&2; }
hr()    { printf '%s\n' "------------------------------------------------------------------------"; }

# ------------------------------------------------------------------------------
# Safety guard — force an explicit acknowledgement
# ------------------------------------------------------------------------------
confirm_disposable() {
  if [ "${1:-}" = "--yes" ] || [ "${KCA_LAB_CONFIRM:-}" = "yes" ]; then
    return 0
  fi
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo 'unknown')"
  warn "Current kube-context: ${C_BLD}${ctx}${C_RST}"
  warn "This lab will DEGRADE Kyverno and may block resource creation cluster-wide."
  read -r -p "Type 'break-my-lab' to continue: " reply
  [ "$reply" = "break-my-lab" ] || { err "Aborted."; exit 1; }
}

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------
require_tools() {
  command -v kubectl >/dev/null 2>&1 || { err "kubectl not found in PATH."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { err "No reachable cluster. Point KUBECONFIG at your lab cluster."; exit 1; }
}

# ------------------------------------------------------------------------------
# Ensure Kyverno is present. If not, install a baseline via Helm so the lab is
# self-contained. The break is version-agnostic.
# ------------------------------------------------------------------------------
ensure_kyverno() {
  if kubectl get ns "$NS" >/dev/null 2>&1 \
     && kubectl -n "$NS" get deploy >/dev/null 2>&1 \
     && [ -n "$(kubectl -n "$NS" get deploy -o name 2>/dev/null)" ]; then
    ok "Kyverno namespace and deployments already present."
    return 0
  fi
  command -v helm >/dev/null 2>&1 || { err "Kyverno is not installed and 'helm' is missing to install it."; exit 1; }
  info "Installing a baseline Kyverno via Helm (this is the 'before upgrade' state)..."
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm install kyverno kyverno/kyverno -n "$NS" --create-namespace --wait --timeout 5m \
    || helm install kyverno kyverno/kyverno -n "$NS" --create-namespace --wait --timeout 5m --version 3.2.6
  ok "Kyverno installed."
}

# ------------------------------------------------------------------------------
# Resolve the admission-controller Deployment name across chart generations.
# ------------------------------------------------------------------------------
resolve_deploy() {
  if kubectl -n "$NS" get deploy kyverno-admission-controller >/dev/null 2>&1; then
    echo "kyverno-admission-controller"
  elif kubectl -n "$NS" get deploy kyverno >/dev/null 2>&1; then
    echo "kyverno"
  else
    err "Could not find the Kyverno admission Deployment in namespace '$NS'."
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Install an enforcing policy that intercepts Pod CREATE, so the admission
# webhook is actually wired up. Without a matching policy Kyverno registers no
# resource webhook and the outage would be invisible.
# ------------------------------------------------------------------------------
apply_demo_policy() {
  info "Applying an Enforce ClusterPolicy so the Pod admission webhook is active..."
  cat <<'YAML' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: kca-require-team-label
  annotations:
    policies.kyverno.io/title: Require team label (KCA 2.6 lab)
    policies.kyverno.io/description: >-
      Pods must carry a non-empty 'team' label. Used to prove the admission
      engine is alive AND enforcing, not merely bypassed.
spec:
  # NOTE: top-level validationFailureAction is deprecated in 1.13+ in favour of
  # spec.rules[].validate.failureAction, but remains functional. Kept top-level
  # here for broad version compatibility during the lab.
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Every Pod must have a non-empty 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
YAML
  # ClusterPolicy exposes a Ready condition once webhooks are configured.
  kubectl wait --for=condition=Ready "clusterpolicy/${POLICY_NAME}" --timeout=90s 2>/dev/null || {
    warn "Could not confirm Ready condition; giving the controller a few seconds."
    sleep 8
  }
  ok "Policy '${POLICY_NAME}' is active. The admission webhook now guards Pod creation."
}

# ------------------------------------------------------------------------------
# Prove the baseline works before we break anything.
# ------------------------------------------------------------------------------
baseline_check() {
  info "Baseline check: a compliant Pod should be admitted right now..."
  if kubectl run kca-baseline --image=registry.k8s.io/pause:3.9 \
       --labels="team=platform" --restart=Never --dry-run=server >/dev/null 2>&1; then
    ok "Baseline OK — the admission webhook is reachable and admitting compliant Pods."
  else
    warn "Baseline server-side dry-run did not pass cleanly; continuing anyway."
  fi
}

# ------------------------------------------------------------------------------
# THE BREAK — simulate an upgrade to an incompatible image and force the old
# pod out (Recreate) so the admission controller actually goes to zero.
# Idempotent: never overwrites the saved-good image if already broken.
# ------------------------------------------------------------------------------
do_break() {
  local deploy="$1" ctr orig_image orig_strategy cur_image

  cur_image="$(kubectl -n "$NS" get deploy "$deploy" \
      -o jsonpath='{.spec.template.spec.containers[0].image}')"

  if [ -f "$STATE_FILE" ] && printf '%s' "$cur_image" | grep -q "$BROKEN_TAG"; then
    ok "Lab already in the broken state (state file: $STATE_FILE). Re-showing briefing."
    return 0
  fi

  ctr="$(kubectl -n "$NS" get deploy "$deploy" \
      -o jsonpath='{.spec.template.spec.containers[0].name}')"
  orig_image="$cur_image"
  orig_strategy="$(kubectl -n "$NS" get deploy "$deploy" \
      -o jsonpath='{.spec.strategy.type}')"
  [ -n "$orig_strategy" ] || orig_strategy="RollingUpdate"

  {
    echo "# KCA 2.6 lab — saved-good state for restoring the botched upgrade"
    echo "NS='${NS}'"
    echo "DEPLOY='${deploy}'"
    echo "CONTAINER='${ctr}'"
    echo "ORIG_IMAGE='${orig_image}'"
    echo "ORIG_STRATEGY='${orig_strategy}'"
    echo "POLICY_NAME='${POLICY_NAME}'"
  } > "$STATE_FILE"
  ok "Saved the good state to ${C_BLD}${STATE_FILE}${C_RST}"

  local broken_image="${orig_image%:*}:${BROKEN_TAG}"
  info "Simulating a botched 'helm upgrade': pointing '${deploy}' at ${C_RED}${broken_image}${C_RST}"

  # Recreate strategy: kill the healthy pod before the (unpullable) new one is
  # ready, so the controller truly hits 0 available replicas — a real outage.
  kubectl -n "$NS" patch deploy "$deploy" --type merge \
    -p '{"spec":{"strategy":{"type":"Recreate"}}}'
  kubectl -n "$NS" patch deploy "$deploy" --type merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${ctr}\",\"image\":\"${broken_image}\"}]}}}}"

  info "Waiting for the outage to manifest..."
  kubectl -n "$NS" rollout status deploy/"$deploy" --timeout=45s >/dev/null 2>&1 || true
  sleep 5
  ok "Break applied."
}

# ------------------------------------------------------------------------------
# Student briefing
# ------------------------------------------------------------------------------
briefing() {
  local deploy="$1"
  hr
  echo "${C_BLD} KCA 2.6 — UPGRADING KYVERNO — BREAK & FIX BRIEFING${C_RST}"
  hr
  echo
  echo "${C_BLD}WHAT JUST HAPPENED${C_RST}"
  echo "  An 'upgrade' repointed the ${C_BLD}${deploy}${C_RST} Deployment at an image tag"
  echo "  that does not exist, and the rollout took the running pod down with it."
  echo "  The admission controller is the process the API server calls on every"
  echo "  intercepted request. It is now gone."
  echo
  echo "${C_BLD}SYMPTOMS YOU WILL SEE${C_RST}"
  echo "  1) The controller pods are unhealthy:"
  echo "       kubectl -n ${NS} get pods"
  echo "     -> ${C_RED}ImagePullBackOff / ErrImagePull${C_RST} on ${deploy}, 0/1 READY."
  echo
  echo "  2) The API server can no longer reach the webhook. Try a COMPLIANT Pod"
  echo "     (it has the required 'team' label, so policy alone would ADMIT it):"
  echo "       kubectl run canary --image=registry.k8s.io/pause:3.9 --labels=team=platform --restart=Never"
  echo "     -> ${C_RED}Internal error occurred: failed calling webhook"
  echo "        \"validate.kyverno.svc-fail\": ... connection refused${C_RST}"
  echo "        (or \"no endpoints available for service\")."
  echo
  echo "     Read that carefully: a VALID request is being rejected — not by the"
  echo "     policy, but because the policy ENGINE is down. That is the signature"
  echo "     of a broken Kyverno upgrade, and with failurePolicy=Fail it can wedge"
  echo "     the whole API for the resources Kyverno guards."
  echo
  echo "${C_BLD}YOUR GOAL${C_RST}"
  echo "  Restore a HEALTHY, VERSION-CONSISTENT Kyverno so that:"
  echo "    * all controllers in '${NS}' are Running/Ready on the SAME version, and"
  echo "    * a compliant Pod is admitted again, while a NON-compliant Pod (no"
  echo "      'team' label) is correctly REJECTED BY THE POLICY."
  echo
  echo "  ${C_YEL}TRAP:${C_RST} deleting the webhook config or the ClusterPolicy makes the"
  echo "  error disappear — but that DISABLES enforcement, it does not fix the"
  echo "  upgrade. The exam (and production) want the engine healthy, not muted."
  echo
  echo "  Saved-good state for reference: ${C_BLD}${STATE_FILE}${C_RST}"
  hr
  echo "  When you are ready, the full worked solution is at the very bottom of"
  echo "  this script, in the commented SOLUTION block."
  hr
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  confirm_disposable "${1:-}"
  require_tools
  ensure_kyverno
  local deploy; deploy="$(resolve_deploy)"
  apply_demo_policy
  baseline_check
  do_break "$deploy"
  briefing "$deploy"
}

main "$@"

# ==============================================================================
#  SOLUTION — step-by-step (read only after you have tried on your own)
# ==============================================================================
#
#  The saved-good values were written to /tmp/kca-2.6-break.env. Load them:
#
#     source /tmp/kca-2.6-break.env
#     # provides: NS DEPLOY CONTAINER ORIG_IMAGE ORIG_STRATEGY POLICY_NAME
#
#  ----------------------------------------------------------------------------
#  STEP 1 — Diagnose (never fix what you have not confirmed)
#  ----------------------------------------------------------------------------
#     kubectl -n "$NS" get pods -o wide
#         # admission controller pod is ImagePullBackOff / 0-ready.
#
#     kubectl -n "$NS" get deploy -o wide
#         # Compare the IMAGES column across the four controllers. The admission
#         # controller shows the bogus tag (…:v1.14.99-broken-upgrade) while the
#         # background/cleanup/reports controllers still run the old, good tag.
#         # THIS IS VERSION SKEW — the classic partial/botched-upgrade signature.
#
#     kubectl -n "$NS" describe pod -l app.kubernetes.io/component=admission-controller \
#         | sed -n '/Events/,$p'
#         # "Failed to pull image ... not found" confirms the bad target.
#
#     kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=10s
#         # Hangs / times out: the new ReplicaSet can never become available.
#
#  ----------------------------------------------------------------------------
#  STEP 2 — Restore service quickly (rollback), then do the upgrade PROPERLY
#  ----------------------------------------------------------------------------
#  Fast recovery A — roll back the pod template to the last good revision:
#
#     kubectl -n "$NS" rollout history deploy/"$DEPLOY"
#     kubectl -n "$NS" rollout undo deploy/"$DEPLOY"
#
#  Fast recovery B — set the known-good image explicitly:
#
#     kubectl -n "$NS" set image deploy/"$DEPLOY" "${CONTAINER}=${ORIG_IMAGE}"
#
#  Note: `rollout undo`/`set image` revert the POD TEMPLATE (the image) but NOT
#  spec.strategy. Restore the original update strategy so future rollouts stay
#  zero-downtime (Kyverno's default is RollingUpdate, and admission controllers
#  should be HA — see https://kyverno.io/docs/high-availability/):
#
#     kubectl -n "$NS" patch deploy/"$DEPLOY" --type merge -p \
#       '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":"25%","maxSurge":"25%"}}}}'
#
#  Wait for health:
#
#     kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s
#     kubectl -n "$NS" get pods
#         # admission controller Running / 1-1 READY. The webhook endpoint is back.
#
#  ----------------------------------------------------------------------------
#  STEP 3 — The correct upgrade procedure (the real KCA 2.6 lesson)
#  ----------------------------------------------------------------------------
#  Do NOT hand-patch images to upgrade Kyverno. Use the release process:
#
#  3a. Check the compatibility matrix — Kyverno version vs. your Kubernetes
#      version — BEFORE choosing a target.
#          https://kyverno.io/docs/installation/#compatibility-matrix
#
#  3b. Read the release notes / migration guide for breaking changes between
#      YOUR current version and the target (never skip minor versions blindly):
#          https://kyverno.io/docs/installation/upgrading/
#
#  3c. Upgrade the CRDs FIRST. `helm upgrade` does NOT upgrade CRDs (Helm never
#      manages the crds/ directory on upgrade). Skipping this is the #1 cause of
#      "unknown field" / policies-not-reconciling after an upgrade:
#
#          helm repo update
#          # Render the target chart's CRDs and apply them server-side:
#          helm template kyverno kyverno/kyverno --version <TARGET_CHART_VERSION> \
#            --include-crds --show-only crds/crds.yaml \
#            | kubectl apply --server-side --force-conflicts -f -
#          # (Exact path/flags per the Upgrading Kyverno docs above.)
#
#  3d. Upgrade the release — ALL four controllers move together, no skew:
#
#          helm upgrade kyverno kyverno/kyverno -n "$NS" \
#            --version <TARGET_CHART_VERSION> --wait --timeout 5m
#
#  3e. Verify version consistency and health:
#
#          kubectl -n "$NS" get deploy -o wide      # every controller: same version
#          kubectl -n "$NS" get pods                 # all Running / Ready
#          kubectl -n "$NS" rollout status deploy/"$DEPLOY"
#
#  ----------------------------------------------------------------------------
#  STEP 4 — Prove the ENGINE is healthy, not merely bypassed
#  ----------------------------------------------------------------------------
#  A compliant Pod must be ADMITTED:
#
#     kubectl run canary-good --image=registry.k8s.io/pause:3.9 \
#         --labels=team=platform --restart=Never
#     # -> pod/canary-good created
#
#  A non-compliant Pod must be REJECTED BY THE POLICY (not by a webhook error):
#
#     kubectl run canary-bad --image=registry.k8s.io/pause:3.9 --restart=Never
#     # -> Error from server: admission webhook "validate.kyverno.svc-fail" denied
#     #    the request: ... Every Pod must have a non-empty 'team' label.
#
#  Seeing a POLICY message (not "connection refused") is the pass condition:
#  the upgrade is healthy and enforcement is intact.
#
#  ----------------------------------------------------------------------------
#  STEP 5 — Clean up the lab
#  ----------------------------------------------------------------------------
#     kubectl delete pod canary-good canary-bad --ignore-not-found
#     kubectl delete clusterpolicy "$POLICY_NAME" --ignore-not-found
#     rm -f /tmp/kca-2.6-break.env
#     # (Optional) tear down Kyverno entirely if it was installed for this lab:
#     #   helm uninstall kyverno -n "$NS"; kubectl delete ns "$NS"
# ==============================================================================