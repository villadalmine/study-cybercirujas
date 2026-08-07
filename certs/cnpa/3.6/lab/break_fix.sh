#!/usr/bin/env bash
#
# ============================================================================
#  CNPA 3.6 — GitOps Basics, Controllers, and Workflows
#  Break & Fix lab :: Argo CD reconciliation, drift detection, and self-heal
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#    Stands up a disposable `kind` cluster, installs Argo CD (a GitOps
#    reconciliation controller), and deploys a Git-managed Application.
#    It then BREAKS the GitOps guarantee in a controlled, reversible way:
#      1. disables the controller's self-heal, and
#      2. injects live drift by scaling a managed Deployment out-of-band.
#    The controller keeps *observing* the drift but stops *acting* on it.
#    Your job is to restore continuous reconciliation the GitOps way —
#    through the controller, not around it.
#
#  WHY THIS MATTERS (exam-relevant mechanics)
#    A GitOps controller runs a closed reconciliation loop:
#        observe live state  ->  diff against desired state in Git
#        ->  report status (Synced / OutOfSync)  ->  act (sync / self-heal)
#    "Declarative + versioned + pulled + continuously reconciled" is the
#    whole definition. Break the "act" step and you get a system that is
#    honest about being wrong (OutOfSync) yet never fixes itself — the
#    most common real-world GitOps misconfiguration.
#
#  SAFETY
#    Everything happens inside a dedicated kind cluster this script owns
#    (kube-context: kind-cnpa-gitops). Every kubectl call is pinned to that
#    context, so no other cluster in your kubeconfig is ever touched.
#    Full teardown (deletes the whole kind cluster):
#        ./break_fix.sh --cleanup
#
#  Reference:
#    CNCF CNPA Curriculum (Domain 3 — GitOps):
#      https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#    Argo CD — Automated Sync & Self-Healing:
#      https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
#    OpenGitOps principles:
#      https://opengitops.dev/
# ----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration (single source of truth for this lab) --------------------
CLUSTER_NAME="cnpa-gitops"
CONTEXT="kind-${CLUSTER_NAME}"
ARGO_NS="argocd"
APP_NAME="guestbook"
APP_NS="guestbook"
REPO_URL="https://github.com/argoproj/argocd-example-apps.git"
REPO_PATH="guestbook"          # Deployment 'guestbook-ui', desired replicas = 1
DRIFT_REPLICAS=4               # the out-of-band value we force during the break
ARGO_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# Pin EVERY cluster call to the lab context. This is the safety rail.
KC="kubectl --context ${CONTEXT}"

# --- Pretty logging ---------------------------------------------------------
c_reset="\033[0m"; c_blue="\033[1;34m"; c_green="\033[1;32m"
c_red="\033[1;31m"; c_yellow="\033[1;33m"
log()  { echo -e "${c_blue}[*]${c_reset} $*"; }
ok()   { echo -e "${c_green}[+]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[!]${c_reset} $*"; }
die()  { echo -e "${c_red}[x]${c_reset} $*" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: '$1'. Install it and re-run."; }

preflight() {
  log "Checking prerequisites (kind, kubectl, docker) ..."
  need kind
  need kubectl
  need docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable. Start Docker and re-run."
  ok "All prerequisites present."
}

# --- Cleanup (disposable teardown) ------------------------------------------
cleanup() {
  warn "Tearing down the disposable lab cluster '${CLUSTER_NAME}' ..."
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    ok "Cluster '${CLUSTER_NAME}' deleted. Nothing else on your machine was touched."
  else
    ok "No cluster named '${CLUSTER_NAME}' found. Already clean."
  fi
  exit 0
}

# --- Cluster + Argo CD bootstrap (idempotent) -------------------------------
ensure_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    ok "kind cluster '${CLUSTER_NAME}' already exists."
  else
    log "Creating disposable kind cluster '${CLUSTER_NAME}' ..."
    kind create cluster --name "${CLUSTER_NAME}"
    ok "Cluster created."
  fi
  $KC cluster-info >/dev/null 2>&1 || die "Cannot reach lab context '${CONTEXT}'."
}

install_argocd() {
  if $KC get ns "${ARGO_NS}" >/dev/null 2>&1 && \
     $KC -n "${ARGO_NS}" get deploy argocd-repo-server >/dev/null 2>&1; then
    ok "Argo CD already installed."
  else
    log "Installing Argo CD into namespace '${ARGO_NS}' (this pulls upstream manifests) ..."
    $KC create namespace "${ARGO_NS}" >/dev/null 2>&1 || true
    $KC apply -n "${ARGO_NS}" -f "${ARGO_MANIFEST}" >/dev/null
  fi
  log "Waiting for the Argo CD control plane to become ready ..."
  $KC -n "${ARGO_NS}" rollout status deploy/argocd-repo-server        --timeout=300s
  $KC -n "${ARGO_NS}" rollout status deploy/argocd-server             --timeout=300s
  $KC -n "${ARGO_NS}" rollout status statefulset/argocd-application-controller --timeout=300s
  ok "Argo CD is up (repo-server, api-server, application-controller running)."
}

# --- Deploy the GitOps-managed Application ----------------------------------
deploy_app() {
  log "Declaring Application '${APP_NAME}' (source of truth: ${REPO_URL} @ ${REPO_PATH}) ..."
  cat <<YAML | $KC apply -f - >/dev/null
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
    namespace: ${APP_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true          # <-- the knob this whole lab turns on/off
    syncOptions:
      - CreateNamespace=true
YAML
  ok "Application declared with automated sync + self-heal ENABLED."
}

wait_for_synced() {
  log "Waiting for '${APP_NAME}' to reconcile to Synced/Healthy ..."
  local sync health
  for _ in $(seq 1 60); do
    sync=$($KC -n "${ARGO_NS}" get application "${APP_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$($KC -n "${ARGO_NS}" get application "${APP_NAME}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
      ok "Application is Synced and Healthy. Desired state (1 replica) is live."
      return 0
    fi
    sleep 5
  done
  die "Timed out waiting for initial sync (last: sync='${sync:-?}', health='${health:-?}')."
}

# --- The controlled break ---------------------------------------------------
break_it() {
  warn "Injecting the controlled break ..."

  # Step 1: silence the 'act' half of the reconciliation loop.
  log "Disabling self-heal on the controller (drift will be detected but not corrected) ..."
  $KC -n "${ARGO_NS}" patch application "${APP_NAME}" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":true}}}}' >/dev/null

  # Step 2: introduce live drift the controller will now tolerate forever.
  log "Scaling the managed Deployment out-of-band: 1 -> ${DRIFT_REPLICAS} replicas ..."
  $KC -n "${APP_NS}" scale deploy guestbook-ui --replicas="${DRIFT_REPLICAS}" >/dev/null

  # Nudge a refresh so the student immediately sees OutOfSync.
  $KC -n "${ARGO_NS}" annotate application "${APP_NAME}" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

  sleep 8
  ok "Break applied. The controller now reports drift but will not fix it."
}

print_challenge() {
  local sync deploy
  sync=$($KC -n "${ARGO_NS}" get application "${APP_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo '?')
  cat <<TXT

============================================================================
  CNPA 3.6 — GitOps Break & Fix :: Reconciliation & Self-Heal
============================================================================

WHAT WAS DONE (controlled break):
  * Argo CD manages the 'guestbook' Application. Git is the source of truth;
    the desired Deployment size is 1 replica.
  * Self-heal was DISABLED on the Application, then the live Deployment was
    scaled out-of-band to ${DRIFT_REPLICAS} replicas.

SYMPTOM YOU WILL SEE (current sync status: ${sync}):
  \$ kubectl --context ${CONTEXT} -n ${ARGO_NS} get applications
    NAME        SYNC STATUS   HEALTH STATUS
    guestbook   OutOfSync     Healthy

  \$ kubectl --context ${CONTEXT} -n ${APP_NS} get deploy guestbook-ui
    NAME           READY   UP-TO-DATE   AVAILABLE
    guestbook-ui   ${DRIFT_REPLICAS}/${DRIFT_REPLICAS}     ${DRIFT_REPLICAS}            ${DRIFT_REPLICAS}

  The controller SEES the drift (OutOfSync) but never corrects it. Live
  state has permanently diverged from Git and just sits there.

YOUR GOAL:
  Restore the GitOps guarantee. Live state must converge back to Git
  (1 replica) AND stay converged automatically on any future drift.
  Fix it THROUGH the controller. A manual 'kubectl scale ... --replicas=1'
  is NOT a fix — it is the exact out-of-band anti-pattern that caused this,
  and the drift will just come back.

SUCCESS CRITERIA:
  * kubectl -n ${ARGO_NS} get app ${APP_NAME} -o jsonpath='{.status.sync.status}'  ->  Synced
  * kubectl -n ${APP_NS} get deploy guestbook-ui  ->  1/1
  * Re-introducing drift (scale to N) auto-reverts to 1 WITHOUT you acting.

HINT:
  Inspect  spec.syncPolicy.automated  on the Application object.
  Which half of the reconciliation loop was switched off?

When you are done experimenting, tear everything down with:
    ./break_fix.sh --cleanup
============================================================================

TXT
}

main() {
  if [[ "${1:-}" == "--cleanup" ]]; then
    preflight
    cleanup
  fi
  preflight
  ensure_cluster
  install_argocd
  deploy_app
  wait_for_synced
  break_it
  print_challenge
}

main "$@"

# ============================================================================
#  SOLUTION — step by step (do not peek until you have tried it)
# ============================================================================
#
#  0) Pin every command to the lab cluster so you never touch prod:
#       export KC="kubectl --context kind-cnpa-gitops"
#
#  1) CONFIRM THE SYMPTOM AND LOCATE THE FAULT
#     -----------------------------------------
#     $ $KC -n argocd get applications
#       NAME        SYNC STATUS   HEALTH STATUS
#       guestbook   OutOfSync     Healthy          # <- detected, not corrected
#
#     See exactly what drifted (live vs. desired):
#       $ $KC -n argocd get application guestbook \
#           -o jsonpath='{range .status.resources[*]}{.kind}/{.name}={.status}{"\n"}{end}'
#         Deployment/guestbook-ui=OutOfSync
#         Service/guestbook-ui=Synced
#
#       $ $KC -n guestbook get deploy guestbook-ui
#         NAME           READY   UP-TO-DATE   AVAILABLE
#         guestbook-ui   4/4     4            4        # Git says 1
#
#     Root cause — inspect the sync policy:
#       $ $KC -n argocd get application guestbook \
#           -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
#         {"prune":true,"selfHeal":false}            # <- self-heal is OFF
#
#     Interpretation: the controller's OBSERVE + DIFF + REPORT stages still
#     work (that is why it says OutOfSync), but the ACT-on-drift stage
#     (self-heal) is disabled, so live state is never reconciled back to Git.
#
#  2) DO NOT "FIX" IT THE WRONG WAY
#     -----------------------------
#     Tempting but WRONG:
#       $ $KC -n guestbook scale deploy guestbook-ui --replicas=1   # anti-pattern!
#     This is another out-of-band imperative change. It hides the symptom for
#     a moment, does not restore the guarantee, and the next drift recurs.
#     In GitOps you never converge the cluster by hand — you fix the loop.
#
#  3) FIX IT THROUGH THE CONTROLLER (re-enable self-heal)
#     ---------------------------------------------------
#       $ $KC -n argocd patch application guestbook --type merge \
#           -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'
#         application.argoproj.io/guestbook patched
#
#     Force an immediate reconcile instead of waiting for the resync interval
#     (default app resync ~180s):
#       $ $KC -n argocd annotate application guestbook \
#           argocd.argoproj.io/refresh=hard --overwrite
#       # or, if you have the CLI logged in:  argocd app sync guestbook
#
#  4) VERIFY CONVERGENCE
#     ------------------
#       $ $KC -n argocd get application guestbook -o jsonpath='{.status.sync.status}{"\n"}'
#         Synced
#       $ $KC -n guestbook get deploy guestbook-ui
#         NAME           READY   UP-TO-DATE   AVAILABLE
#         guestbook-ui   1/1     1            1          # back to Git's desired state
#
#  5) PROVE SELF-HEAL IS TRULY RESTORED (the real acceptance test)
#     -----------------------------------------------------------
#     Re-introduce drift and watch the controller undo it on its own:
#       $ $KC -n guestbook scale deploy guestbook-ui --replicas=7
#       $ $KC -n guestbook get deploy guestbook-ui -w
#         guestbook-ui   7/7  ...        # momentarily
#         guestbook-ui   1/1  ...        # controller reconciled it back — no human acted
#
#     That automatic revert is the GitOps guarantee working end-to-end:
#     the cluster continuously converges toward the versioned desired state.
#
#  KEY TAKEAWAYS
#    * A GitOps controller is a reconciliation loop; `selfHeal` is the ACT
#      stage for live drift. OutOfSync means "diff detected", not "will fix".
#    * Never converge the cluster imperatively; change desired state (Git) or
#      the controller's policy, then let the loop reconcile.
#    * `prune` handles deleted-in-Git resources; `selfHeal` handles
#      changed-in-cluster resources. They are independent knobs.
#    * The same reconcile-toward-declared-state pattern underpins every
#      controller you will meet in this domain — from Argo CD Applications
#      to Argo Workflows and custom operators.
# ============================================================================