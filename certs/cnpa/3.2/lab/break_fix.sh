#!/usr/bin/env bash
#
# CNPA — Topic 3.2: Continuous Delivery Concepts and GitOps Principles
# Break & Fix lab — GitOps reconciliation / self-heal drift
#
# WHAT THIS TEACHES
#   The core GitOps promise is *continuous reconciliation*: Git is the single
#   source of truth for the desired state, and an in-cluster agent (here Argo CD)
#   continuously pulls that state and converges the live cluster toward it. Two
#   properties make that promise real:
#     - automated sync   -> commits are applied without a human running kubectl
#     - self-heal        -> out-of-band changes (manual drift) are reverted
#   Turn either off and you no longer have GitOps — you have a one-shot deploy
#   tool that happens to read YAML from a repo. This lab breaks exactly that.
#
# SAFETY
#   Everything runs inside a dedicated, disposable namespace and a demo
#   Application pointing at the public argocd-example-apps guestbook. It never
#   touches kube-system, your workloads, or cluster-scoped resources beyond the
#   Argo CD install. Run `--cleanup` to remove everything the lab created.
#
# REQUIREMENTS
#   - A DISPOSABLE cluster (kind / minikube / k3s) — do NOT run against prod.
#   - kubectl configured and pointing at that cluster.
#   - Outbound internet (to fetch the Argo CD install manifest and the demo repo).
#
# Sources (official):
#   - OpenGitOps Principles v1.0 ......... https://opengitops.dev/
#   - CNCF App Delivery TAG (GitOps) ..... https://tag-app-delivery.cncf.io/
#   - Argo CD Automated Sync / Self Heal . https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
#   - Argo CD Application spec ........... https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
#   - Flux (alternative reconciler) ...... https://fluxcd.io/flux/concepts/
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ARGO_NS="argocd"
LAB_NS="cnpa-gitops-lab"
APP_NAME="guestbook"
DEPLOY="guestbook-ui"
REPO_URL="https://github.com/argoproj/argocd-example-apps.git"
REPO_PATH="guestbook"
DRIFT_REPLICAS=4
ARGO_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
  YLW="$(printf '\033[33m')"; CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YLW=""; CYN=""; RST=""
fi
info() { echo "${CYN}[*]${RST} $*"; }
ok()   { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }
hr()   { printf '%s\n' "----------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || { err "kubectl not found in PATH."; exit 1; }
  if ! kubectl cluster-info >/dev/null 2>&1; then
    err "No reachable Kubernetes cluster. Point kubectl at a DISPOSABLE lab cluster first."
    exit 1
  fi
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  warn "Active kube-context: ${BOLD}${ctx}${RST}"
  warn "This lab breaks a running resource on purpose. Use a throwaway cluster ONLY."
}

# Wait until a jsonpath field on an object equals an expected value (or times out).
wait_for() {
  local ns="$1" kind="$2" name="$3" jsonpath="$4" want="$5" timeout="${6:-300}"
  local waited=0 got=""
  while (( waited < timeout )); do
    got="$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath="$jsonpath" 2>/dev/null || true)"
    [[ "$got" == "$want" ]] && return 0
    sleep 5; waited=$((waited + 5))
  done
  err "Timed out waiting for ${kind}/${name} ${jsonpath} == ${want} (last: '${got}')."
  return 1
}

# ---------------------------------------------------------------------------
# Bootstrap: install Argo CD + a healthy, GitOps-managed demo Application
# ---------------------------------------------------------------------------
ensure_argocd() {
  if kubectl get ns "$ARGO_NS" >/dev/null 2>&1 \
     && kubectl -n "$ARGO_NS" get deploy argocd-application-controller >/dev/null 2>&1; then
    ok "Argo CD already installed in namespace '${ARGO_NS}'."
  else
    info "Installing Argo CD into namespace '${ARGO_NS}' (this can take a couple of minutes)..."
    kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n "$ARGO_NS" -f "$ARGO_INSTALL_URL"
  fi
  info "Waiting for the Argo CD application-controller and repo-server to be ready..."
  kubectl -n "$ARGO_NS" rollout status deploy/argocd-repo-server --timeout=300s
  kubectl -n "$ARGO_NS" rollout status statefulset/argocd-application-controller --timeout=300s 2>/dev/null \
    || kubectl -n "$ARGO_NS" rollout status deploy/argocd-application-controller --timeout=300s
  ok "Argo CD is up."
}

ensure_app() {
  kubectl create namespace "$LAB_NS" --dry-run=client -o yaml | kubectl apply -f -
  info "Declaring the '${APP_NAME}' Application with automated sync + self-heal (the GitOps way)..."
  # NOTE: syncPolicy.automated.selfHeal=true is what makes drift self-correct.
  cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGO_NS}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: HEAD
    path: ${REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${LAB_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  info "Waiting for the Application to become Synced and Healthy..."
  wait_for "$ARGO_NS" application "$APP_NAME" '{.status.sync.status}'   Synced  420
  wait_for "$ARGO_NS" application "$APP_NAME" '{.status.health.status}' Healthy 420
  kubectl -n "$LAB_NS" rollout status "deploy/${DEPLOY}" --timeout=180s
  ok "Baseline established: Git desired state == cluster live state."
  echo "    Desired replicas (from Git): $(kubectl -n "$LAB_NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')"
}

# ---------------------------------------------------------------------------
# THE BREAK
#   1. Disable the automated sync policy  -> the reconciler stops enforcing Git.
#   2. Manually scale the Deployment      -> introduce out-of-band drift.
#   With self-heal gone, the drift STICKS. The app reports OutOfSync forever
#   and no one is converging the cluster back to the source of truth.
# ---------------------------------------------------------------------------
do_break() {
  hr
  info "Breaking GitOps reconciliation..."

  info "Step 1/2 — removing spec.syncPolicy.automated (disabling auto-sync + self-heal)."
  kubectl -n "$ARGO_NS" patch application "$APP_NAME" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'

  info "Step 2/2 — introducing manual drift: scaling ${DEPLOY} to ${DRIFT_REPLICAS} replicas."
  kubectl -n "$LAB_NS" scale "deploy/${DEPLOY}" --replicas="$DRIFT_REPLICAS"

  # Nudge Argo CD to re-evaluate so the OutOfSync verdict shows up promptly.
  kubectl -n "$ARGO_NS" annotate application "$APP_NAME" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

  ok "Break applied."
  hr
  cat <<EOF

${BOLD}SCENARIO${RST}
  A teammate "hotfixed" production by running a manual \`kubectl scale\` and, to
  stop Argo CD from "undoing their work", they disabled the app's automated sync
  policy. Git still says the desired state is 1 replica. The cluster now runs
  ${DRIFT_REPLICAS}. Nobody is reconciling the two. GitOps is effectively off.

${BOLD}SYMPTOM YOU WILL OBSERVE${RST}
  * The Application is stuck OutOfSync and never recovers on its own:

      kubectl -n ${ARGO_NS} get application ${APP_NAME}
      # NAME        SYNC STATUS   HEALTH STATUS
      # ${APP_NAME}   OutOfSync     Healthy

  * The manual drift persists instead of being reverted:

      kubectl -n ${LAB_NS} get deploy ${DEPLOY}
      # READY   UP-TO-DATE   AVAILABLE
      # ${DRIFT_REPLICAS}/${DRIFT_REPLICAS}     ${DRIFT_REPLICAS}            ${DRIFT_REPLICAS}          <-- Git says 1, cluster says ${DRIFT_REPLICAS}

  * Inspect *why* it will not fix itself — the reconciler has no marching orders:

      kubectl -n ${ARGO_NS} get application ${APP_NAME} \\
        -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
      # (empty)   <-- no automated policy => no auto-sync, no self-heal

${BOLD}YOUR GOAL${RST}
  Restore true GitOps behavior. When you are done, WITHOUT ever running a manual
  \`kubectl scale\`/\`edit\` to fix the replica count yourself:
    1. \`spec.syncPolicy.automated.selfHeal\` is true again, and
    2. the reconciler drives ${DEPLOY} back to the Git-declared 1 replica, and
    3. the Application returns to SYNC STATUS = Synced.
  The whole point: you fix the *policy*, and the *convergence* happens on its own.

  Verify success with:
      kubectl -n ${ARGO_NS} get application ${APP_NAME}
      kubectl -n ${LAB_NS} get deploy ${DEPLOY}

  (Scroll to the very bottom of this script for the step-by-step solution.)

EOF
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
do_cleanup() {
  info "Removing lab Application and namespace..."
  kubectl -n "$ARGO_NS" delete application "$APP_NAME" --ignore-not-found --wait=false || true
  kubectl delete namespace "$LAB_NS" --ignore-not-found || true
  warn "Argo CD itself (namespace '${ARGO_NS}') was left installed."
  warn "Remove it with:  kubectl delete namespace ${ARGO_NS}"
  ok "Cleanup done."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  case "${1:-break}" in
    --cleanup|cleanup) preflight; do_cleanup ;;
    break|"")          preflight; ensure_argocd; ensure_app; do_break ;;
    *) err "Usage: $0 [break|--cleanup]"; exit 2 ;;
  esac
}
main "$@"

# ===========================================================================
# SOLUTION — step by step (do not peek until you have tried it)
# ===========================================================================
#
# The root cause is NOT the replica count; that is only the visible symptom.
# The root cause is that the GitOps controller was told to stop reconciling.
# Fixing the number by hand would "work" for ten seconds and drift again the
# next time someone fat-fingers a change. You must fix the *policy* so the
# system converges by itself. That is the difference between a deploy tool and
# GitOps.
#
# 1) Confirm the diagnosis — the automated policy is gone:
#
#      kubectl -n argocd get application guestbook \
#        -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
#      # prints nothing -> no auto-sync, no self-heal
#
# 2) Re-enable automated sync WITH self-heal (and prune). This is the actual fix:
#
#      kubectl -n argocd patch application guestbook --type merge -p \
#        '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
#
#    Field meanings (Argo CD Application spec):
#      selfHeal=true -> revert live drift back to the Git-declared state.
#      prune=true    -> delete live resources that were removed from Git.
#
# 3) (Optional) Trigger an immediate reconcile instead of waiting for the
#    default ~3-minute app-resync interval:
#
#      kubectl -n argocd annotate application guestbook \
#        argocd.argoproj.io/refresh=hard --overwrite
#
#    Or, if you have the Argo CD CLI logged in, force a sync explicitly:
#
#      argocd app sync guestbook
#
# 4) Verify convergence happened on its own — you never scaled the Deployment:
#
#      kubectl -n argocd get application guestbook
#      # NAME        SYNC STATUS   HEALTH STATUS
#      # guestbook   Synced        Healthy
#
#      kubectl -n cnpa-gitops-lab get deploy guestbook-ui
#      # READY   UP-TO-DATE   AVAILABLE
#      # 1/1     1            1          <-- self-heal reverted the drift to Git
#
# 5) Prove it is durable — GitOps now defends the desired state. Try to drift
#    again and watch the controller undo it:
#
#      kubectl -n cnpa-gitops-lab scale deploy/guestbook-ui --replicas=7
#      sleep 20
#      kubectl -n cnpa-gitops-lab get deploy guestbook-ui   # back to 1/1
#
# KEY TAKEAWAYS (map to OpenGitOps Principles v1.0 — https://opengitops.dev/):
#   * Declarative + Versioned: Git holds the desired state (1 replica). Never
#     "fix" a GitOps-managed resource with imperative kubectl — change Git.
#   * Pulled automatically: automated sync applies commits without a human.
#   * Continuously reconciled: self-heal is the property that turns "deployed
#     once" into "kept correct forever". Disable it and OutOfSync becomes a
#     permanent, silent divergence rather than a self-correcting blip.
#   * Alternative implementations (e.g. Flux Kustomization/HelmRelease) express
#     the same policy differently: prune: true and a reconcile interval, with
#     `flux suspend`/`flux resume` as the equivalent kill switch you just used.
# ===========================================================================