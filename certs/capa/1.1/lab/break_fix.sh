#!/usr/bin/env bash
#
# ============================================================================
#  CAPA 1.1 — Argo Project Fundamentals  ·  Break & Fix Lab
#  Scenario: "The Application that forgot how to compare"
# ============================================================================
#
#  What this lab teaches
#  ---------------------
#  Argo CD is not a monolith. It is a set of cooperating microservices, and
#  each one owns a distinct job. When you understand *which* component does
#  *what*, a stuck Application is trivial to diagnose. When you don't, it looks
#  like magic that broke. This lab breaks exactly one of those components and
#  makes you reason from the symptom back to the responsible service.
#
#  The Argo CD core components (memorize these — CAPA exam material):
#    * argocd-server               — the API/UI server (gRPC + REST)
#    * argocd-repo-server          — clones Git and RENDERS manifests
#                                     (helm template / kustomize build / plain)
#    * argocd-application-controller — the reconcile loop: compares the
#                                     DESIRED state (from repo-server) against
#                                     the LIVE state (from the cluster) and,
#                                     if configured, syncs and self-heals
#    * argocd-redis                — ephemeral cache used by the controller
#                                     and repo-server
#    * argocd-dex-server           — optional SSO/OIDC federation
#
#  Official sources (read them, do not trust memory):
#    - CNCF CAPA curriculum:
#      https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
#    - Argo CD architecture:
#      https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/
#    - Argo CD core concepts:
#      https://argo-cd.readthedocs.io/en/stable/core_concepts/
#    - The Argo Project umbrella (CD, Workflows, Rollouts, Events):
#      https://argoproj.github.io/
#
#  Safety
#  ------
#  This script is DESTRUCTIVE to an Argo CD control-plane component on purpose.
#  It is reversible (it only scales a Deployment to 0), it touches nothing
#  outside the 'argocd' and 'guestbook' namespaces, and it refuses to run
#  unless the current kube-context clearly looks like a throwaway lab. Run it
#  ONLY on a disposable VM / kind / minikube cluster you can delete.
# ============================================================================

set -uo pipefail

# --- Configuration ----------------------------------------------------------
NS_ARGOCD="argocd"
NS_APP="guestbook"
APP_NAME="guestbook"
REPO_URL="https://github.com/argoproj/argocd-example-apps.git"
REPO_PATH="guestbook"
ARGOCD_INSTALL_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
BROKEN_COMPONENT="argocd-repo-server"
SETUP_TIMEOUT="300"   # seconds to wait for Argo CD to come up
SYNC_TIMEOUT="180"    # seconds to wait for the first successful sync

# --- Pretty output ----------------------------------------------------------
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_ylw=$'\033[33m';  c_blu=$'\033[34m'; c_bold=$'\033[1m'

log()  { printf '%s[lab]%s %s\n'  "$c_blu" "$c_reset" "$*"; }
ok()   { printf '%s[ ok]%s %s\n'  "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_ylw" "$c_reset" "$*"; }
die()  { printf '%s[fail]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

# --- Safety guard: refuse anything that is not obviously a lab ---------------
require_disposable_lab() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster (check your kubeconfig)."

  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  log "Current kube-context: ${c_bold}${ctx}${c_reset}"

  # Allow only contexts that look disposable, unless the student opts in loudly.
  if printf '%s' "$ctx" | grep -Eqi 'kind|minikube|k3d|k3s|docker-desktop|lab|test|sandbox|disposable'; then
    ok "Context looks like a disposable lab. Proceeding."
  elif [ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB:-no}" = "yes" ]; then
    warn "Context does not look like a lab, but override flag is set. Proceeding."
  else
    die "Refusing to run on context '${ctx}'. This is a DESTRUCTIVE lab.
       Point kubectl at a throwaway cluster (kind/minikube/k3d), or, if you are
       certain this cluster is disposable, re-run with:
         I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes $0"
  fi
}

# --- Idempotent setup: install Argo CD if absent ----------------------------
ensure_argocd() {
  if kubectl get ns "$NS_ARGOCD" >/dev/null 2>&1 \
     && kubectl -n "$NS_ARGOCD" get deploy argocd-server >/dev/null 2>&1; then
    ok "Argo CD already installed in namespace '$NS_ARGOCD'."
    return 0
  fi

  log "Installing Argo CD (namespace '$NS_ARGOCD')..."
  kubectl create namespace "$NS_ARGOCD" >/dev/null 2>&1 || true
  kubectl apply -n "$NS_ARGOCD" -f "$ARGOCD_INSTALL_MANIFEST" >/dev/null \
    || die "Failed to apply Argo CD install manifest."

  log "Waiting up to ${SETUP_TIMEOUT}s for the control plane to become Available..."
  for d in argocd-repo-server argocd-server argocd-redis argocd-applicationset-controller; do
    kubectl -n "$NS_ARGOCD" rollout status "deploy/$d" --timeout="${SETUP_TIMEOUT}s" \
      >/dev/null 2>&1 || warn "Deployment '$d' not ready (may be optional)."
  done
  # The application-controller is a StatefulSet, not a Deployment.
  kubectl -n "$NS_ARGOCD" rollout status statefulset/argocd-application-controller \
    --timeout="${SETUP_TIMEOUT}s" >/dev/null 2>&1 \
    || warn "application-controller not ready yet."
  ok "Argo CD control plane is up."
}

# --- Idempotent setup: declare the sample Application -----------------------
ensure_app() {
  if kubectl -n "$NS_ARGOCD" get application "$APP_NAME" >/dev/null 2>&1; then
    ok "Application '$APP_NAME' already exists."
  else
    log "Creating a declarative, self-healing Application '$APP_NAME'..."
    kubectl apply -f - >/dev/null <<EOF || die "Failed to create Application."
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${NS_ARGOCD}
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
    namespace: ${NS_APP}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  fi

  # Wait for the FIRST healthy sync so the student sees a known-good baseline
  # before we break it. Without this baseline the break is indistinguishable
  # from "the lab never worked".
  log "Waiting up to ${SYNC_TIMEOUT}s for the initial Synced/Healthy state..."
  local deadline=$(( SECONDS + SYNC_TIMEOUT )) sync health
  while [ "$SECONDS" -lt "$deadline" ]; do
    sync="$(kubectl -n "$NS_ARGOCD" get application "$APP_NAME" \
             -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl -n "$NS_ARGOCD" get application "$APP_NAME" \
             -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      ok "Baseline reached: Sync=Synced, Health=Healthy."
      return 0
    fi
    printf '\r%s[lab]%s baseline... sync=%-8s health=%-10s' \
      "$c_blu" "$c_reset" "${sync:-?}" "${health:-?}"
    sleep 5
  done
  printf '\n'
  warn "Baseline not fully reached before timeout — breaking anyway."
  warn "(A slow Git clone on first run is common; the lab is still valid.)"
}

# --- The controlled break ---------------------------------------------------
break_scenario() {
  hr
  log "Introducing the fault..."
  # We scale the repo-server to zero. Nothing is deleted; the desired-state
  # RENDERER simply disappears. This is fully reversible and confined to the
  # argocd namespace.
  kubectl -n "$NS_ARGOCD" scale deploy "$BROKEN_COMPONENT" --replicas=0 >/dev/null \
    || die "Could not scale '$BROKEN_COMPONENT'."

  # Nudge the controller so the student sees the failure quickly instead of
  # waiting for the next reconcile tick / cache expiry.
  kubectl -n "$NS_ARGOCD" annotate application "$APP_NAME" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

  ok "Fault injected. Component '$BROKEN_COMPONENT' scaled to 0 replicas."
}

# --- Briefing shown to the student -----------------------------------------
brief_student() {
  hr
  printf '%s%s  CAPA 1.1 — BREAK & FIX: the Application that forgot how to compare  %s\n' \
    "$c_bold" "$c_blu" "$c_reset"
  hr
  cat <<'BRIEF'

WHAT JUST HAPPENED
  One Argo CD control-plane component has been disabled. Your guestbook
  Application was Synced and Healthy a moment ago; now it is stuck. No
  application workload was touched — the running guestbook Pods are fine.
  The problem is entirely in the Argo CD control plane.

THE SYMPTOM YOU WILL SEE
  Inspect the Application:

      kubectl -n argocd get application guestbook
      kubectl -n argocd get application guestbook \
        -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'

  Expect the Sync status to go to 'Unknown' and a condition of type
  'ComparisonError' whose message mentions something like:

      rpc error: code = Unavailable desc = ... argocd-repo-server ...
      (connection refused / no endpoints available)

  In the Argo CD UI the tile turns grey with "Unknown" and a red error banner.
  A manual sync will NOT fix it and will fail with the same error.

YOUR GOAL
  Restore the Application to Sync=Synced, Health=Healthy WITHOUT deleting or
  recreating the Application, and without editing the Application spec. You
  must find the failed component and bring it back.

DIAGNOSTIC HINTS (reason, don't guess)
  * Argo CD compares DESIRED vs LIVE state. Which component produces the
    DESIRED state by cloning Git and rendering manifests?
  * List the control-plane workloads and look for one with zero ready pods:
        kubectl -n argocd get deploy,statefulset,pods
  * The error message names the service that the controller cannot reach.
    Follow that name to the workload behind it.

SUCCESS CHECK
      kubectl -n argocd get application guestbook
      # -> SYNC STATUS: Synced   HEALTH STATUS: Healthy

Take your time. Everything you need is in `kubectl -n argocd get ...` and the
Application's `.status.conditions`. The step-by-step solution is at the bottom
of this script, commented out — only look if you are truly stuck.

BRIEF
  hr
}

# --- Orchestration ----------------------------------------------------------
main() {
  require_disposable_lab
  ensure_argocd
  ensure_app
  break_scenario
  brief_student
}

main "$@"

# ============================================================================
#  SOLUTION — do not read until you have tried  (CAPA 1.1)
# ============================================================================
#
#  STEP 1 — Confirm the symptom and read the actual error.
#  ------------------------------------------------------
#    kubectl -n argocd get application guestbook
#    kubectl -n argocd get application guestbook \
#      -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
#
#    You will see Sync=Unknown and a 'ComparisonError' condition whose message
#    names 'argocd-repo-server' as Unavailable / no endpoints. That name is the
#    whole clue: the reconcile loop cannot obtain the DESIRED manifests because
#    the component that renders them is unreachable.
#
#  STEP 2 — Map the error to a component and confirm it is down.
#  ------------------------------------------------------------
#    kubectl -n argocd get deploy,pods
#
#    Expected: 'argocd-repo-server' shows READY 0/0 and has no running Pod,
#    while every other component (server, redis, application-controller) is
#    healthy. This isolates the fault to a single microservice.
#
#      kubectl -n argocd get deploy argocd-repo-server
#      # NAME                 READY   UP-TO-DATE   AVAILABLE
#      # argocd-repo-server   0/0     0            0
#
#  STEP 3 — Restore the component. It was scaled to zero, so scale it back.
#  -----------------------------------------------------------------------
#    kubectl -n argocd scale deploy argocd-repo-server --replicas=1
#    kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=120s
#
#  STEP 4 — Force a fresh comparison and let automated sync + selfHeal work.
#  ------------------------------------------------------------------------
#    kubectl -n argocd annotate application guestbook \
#      argocd.argoproj.io/refresh=hard --overwrite
#    # (or, with the CLI:  argocd app get guestbook --refresh
#    #                     argocd app sync guestbook)
#
#  STEP 5 — Verify success.
#  -----------------------
#    kubectl -n argocd get application guestbook
#    # SYNC STATUS: Synced    HEALTH STATUS: Healthy
#
#    kubectl -n guestbook get all
#    # the guestbook Deployment/Service are present and Running.
#
#  WHY THIS IS THE LESSON
#  ----------------------
#    * argocd-repo-server is the *only* component that turns Git into rendered
#      Kubernetes manifests (the DESIRED state). Remove it and the
#      application-controller has nothing to diff against LIVE state, so every
#      comparison fails with 'Unknown' — even though your Git repo, your
#      cluster, and your running app are all perfectly fine.
#    * The fix is never "delete and recreate the Application". The Application
#      CR is just declared intent; the control plane is what was broken. This
#      distinction — declared desired state vs the engine that reconciles it —
#      is the heart of GitOps and a core CAPA objective.
#
#  RESET THE LAB (instructor convenience)
#  --------------------------------------
#    kubectl -n argocd scale deploy argocd-repo-server --replicas=1
#    # To tear everything down completely:
#    #   kubectl -n argocd delete application guestbook
#    #   kubectl delete ns guestbook argocd
#
#  References:
#    - https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/
#    - https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
#    - https://argo-cd.readthedocs.io/en/stable/core_concepts/
# ============================================================================