#!/usr/bin/env bash
#
# ============================================================================
#  CAPA — Certified Argo Project Associate
#  Domain 3: Argo CD   ·   Exam weight: 20%
#  Topic 3.1 — BREAK & FIX lab:  "The Application that keeps running but
#              silently stops reconciling"
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#    1. Deploys a known-good Argo CD Application (ends up Synced + Healthy).
#    2. Breaks EXACTLY ONE field, in a controlled and fully reversible way.
#    3. Prints the symptom you should observe and the goal you must reach.
#    4. Ships the complete step-by-step solution at the bottom, COMMENTED OUT.
#
#  WHERE TO RUN THIS
#    On a DISPOSABLE lab VM with a throwaway cluster (kind / k3s / minikube)
#    that already has Argo CD installed in the `argocd` namespace. Everything
#    created here lives in its own namespace (`capa-lab`) and its own
#    Application (`capa-guestbook`); it never touches your real workloads.
#
#  OFFICIAL REFERENCES (cited, read them while you diagnose)
#    - Application spec:
#        https://argo-cd.readthedocs.io/en/stable/operator-manual/application-specification/
#    - Automated sync & self-heal:
#        https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
#    - Tracking & targetRevision (HEAD vs branch vs tag vs SHA):
#        https://argo-cd.readthedocs.io/en/stable/user-guide/tracking_strategies/
#    - App health & sync status model:
#        https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
#    - CAPA curriculum:
#        https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
#
#  USAGE
#    ./capa_3_1_break_fix.sh            # setup a good app, then arm the break
#    ./capa_3_1_break_fix.sh setup      # only deploy the known-good Application
#    ./capa_3_1_break_fix.sh break      # only arm the break (app must exist)
#    ./capa_3_1_break_fix.sh verify     # check whether YOU fixed it
#    ./capa_3_1_break_fix.sh reset      # tear the whole lab down (idempotent)
# ============================================================================

set -euo pipefail

# --------------------------- configuration ----------------------------------
ARGOCD_NS="argocd"                                   # where Argo CD runs
APP_NAME="capa-guestbook"                            # our lab Application
DEST_NS="capa-lab"                                   # where the workload lands
REPO="https://github.com/argoproj/argocd-example-apps.git"
APP_PATH="guestbook"
GOOD_REV="HEAD"                                      # a revision that resolves
BAD_REV="capa-broken-revision"                       # a revision that does NOT
POLL_TIMEOUT=180                                     # seconds

# --------------------------- pretty output ----------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
c_cya=$'\033[36m'; c_bld=$'\033[1m';  c_rst=$'\033[0m'

banner() { printf '\n%s%s==> %s%s\n' "$c_bld" "$c_cya" "$1" "$c_rst"; }
info()   { printf '    %s\n' "$1"; }
warn()   { printf '%s[warn]%s %s\n' "$c_yel" "$c_rst" "$1"; }
die()    { printf '%s[fatal]%s %s\n' "$c_red" "$c_rst" "$1" >&2; exit 1; }

# --------------------------- guard rails ------------------------------------
require() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH."; }

preflight() {
  require kubectl
  kubectl get ns "$ARGOCD_NS" >/dev/null 2>&1 \
    || die "Namespace '$ARGOCD_NS' not found. Install Argo CD first."
  kubectl get crd applications.argoproj.io >/dev/null 2>&1 \
    || die "Argo CD CRDs not found. Is Argo CD installed in this cluster?"

  # This lab is destructive-by-design. Refuse to run unless the operator has
  # confirmed the cluster is disposable.
  if [ "${I_HAVE_A_DISPOSABLE_LAB:-no}" != "yes" ]; then
    warn "This lab intentionally breaks an Argo CD Application."
    warn "Run it ONLY on a throwaway cluster."
    warn "Re-run with:  I_HAVE_A_DISPOSABLE_LAB=yes $0 $*"
    die  "Refusing to touch a cluster that was not declared disposable."
  fi
}

# Poll the Application's status until sync==Synced AND health==Healthy.
wait_healthy() {
  local deadline=$((SECONDS + POLL_TIMEOUT)) sync health
  banner "Waiting for '$APP_NAME' to become Synced + Healthy (<= ${POLL_TIMEOUT}s)"
  while [ "$SECONDS" -lt "$deadline" ]; do
    sync="$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" \
              -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" \
              -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    info "sync=${sync:-<none>}  health=${health:-<none>}"
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      printf '%s    OK — baseline is green.%s\n' "$c_grn" "$c_rst"
      return 0
    fi
    sleep 6
  done
  die "Timed out waiting for a green baseline. Check 'kubectl -n $ARGOCD_NS describe application $APP_NAME'."
}

# --------------------------- lab lifecycle ----------------------------------
setup() {
  preflight "$@"
  banner "Deploying the known-good Application '$APP_NAME'"
  # Automated sync + self-heal + prune, so the app reconciles on its own and
  # no 'argocd login' is needed for the lab to drive itself.
  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NS}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO}
    targetRevision: ${GOOD_REV}
    path: ${APP_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DEST_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  wait_healthy
}

break_it() {
  preflight "$@"
  kubectl -n "$ARGOCD_NS" get application "$APP_NAME" >/dev/null 2>&1 \
    || die "Application '$APP_NAME' not found. Run '$0 setup' first."

  banner "Arming the break — pointing targetRevision at a revision that does not exist"
  # The ONLY change: swap the resolvable revision for a bogus one. This is a
  # spec-only edit on our own Application CR; nothing else in the cluster is
  # modified, and it is undone by putting the good revision back.
  kubectl -n "$ARGOCD_NS" patch application "$APP_NAME" --type merge \
    -p "{\"spec\":{\"source\":{\"targetRevision\":\"${BAD_REV}\"}}}" >/dev/null

  # Force Argo CD to re-run the manifest comparison right now.
  kubectl -n "$ARGOCD_NS" annotate application "$APP_NAME" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  sleep 8

  cat <<'STUDENT'

  ------------------------------------------------------------------------
   STUDENT BRIEF — CAPA 3.1  ·  "It's still up... so why is it red?"
  ------------------------------------------------------------------------

  SYMPTOM YOU WILL SEE
    - The guestbook pods in namespace 'capa-lab' are STILL RUNNING and the
      app still serves traffic — nothing appears "down".
    - But Argo CD now reports the Application as:
          Sync Status:  Unknown        (not "OutOfSync" — Unknown)
          Conditions:   ComparisonError
      with a message similar to:
          "Unable to resolve 'capa-broken-revision' to a commit SHA"
          "unknown revision or path not in the working tree"
    - self-heal does NOT rescue you: Argo CD cannot compute a desired state
      it can't fetch, so it has nothing to heal *toward*. Reconciliation is
      effectively frozen. This is the trap — a green dashboard for the pods,
      a red control plane for the Application.

  INSPECT IT YOURSELF
      kubectl -n argocd get application capa-guestbook
      kubectl -n argocd describe application capa-guestbook
      # or, if you have the CLI logged in:
      argocd app get capa-guestbook

  YOUR GOAL
    Bring 'capa-guestbook' back to  Sync=Synced  and  Health=Healthy,
    WITHOUT deleting and recreating the Application. Find the single wrong
    field, understand WHY it produces a ComparisonError (not OutOfSync),
    correct it, and let auto-sync converge.

  WHEN YOU THINK YOU'RE DONE
      ./capa_3_1_break_fix.sh verify

  ------------------------------------------------------------------------

STUDENT
}

verify() {
  preflight "$@"
  local sync health rev
  sync="$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  rev="$(kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || true)"

  banner "Grading your fix"
  info "targetRevision = ${rev:-<none>}"
  info "sync=${sync:-<none>}  health=${health:-<none>}"

  if [ "$rev" = "$BAD_REV" ]; then
    printf '%sFAIL — the bogus revision is still in the spec.%s\n' "$c_red" "$c_rst"; exit 1
  fi
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    printf '%sPASS — Application is Synced + Healthy again. Well done.%s\n' "$c_grn" "$c_rst"; exit 0
  fi
  printf '%sNOT YET — spec looks fixed, but status is not green. Force a refresh/sync and wait.%s\n' "$c_yel" "$c_rst"
  exit 1
}

reset() {
  require kubectl
  banner "Tearing down the lab"
  kubectl -n "$ARGOCD_NS" delete application "$APP_NAME" --ignore-not-found >/dev/null 2>&1 || true
  # The finalizer prunes managed resources; also drop the namespace to be safe.
  kubectl delete namespace "$DEST_NS" --ignore-not-found >/dev/null 2>&1 || true
  info "Lab removed."
}

# --------------------------- entrypoint -------------------------------------
case "${1:-arm}" in
  setup)  setup "$@" ;;
  break)  break_it "$@" ;;
  verify) verify "$@" ;;
  reset)  reset ;;
  arm)    setup "$@"; break_it "$@" ;;
  *)      die "Unknown command '$1'. Use: setup | break | verify | reset | (default) arm" ;;
esac


# ============================================================================
#  SOLUTION — step by step  (do not read until you have tried it yourself)
# ============================================================================
#
#  ROOT CAUSE
#    'spec.source.targetRevision' was set to 'capa-broken-revision', a git
#    revision that does not exist in the repository. Argo CD's repo-server
#    cannot resolve it to a commit SHA, so it cannot render the desired
#    manifests. With no desired state to diff against, the comparison itself
#    fails: status becomes Sync=Unknown with a ComparisonError condition
#    (distinct from OutOfSync, which means "I compared and they differ").
#    Because self-heal only reverts *known* drift, it cannot act — hence the
#    running-but-frozen behaviour.
#
#  STEP 1 — Confirm the diagnosis.
#    kubectl -n argocd get application capa-guestbook
#    kubectl -n argocd get application capa-guestbook \
#        -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
#    # Expect a ComparisonError mentioning it cannot resolve 'capa-broken-revision'.
#
#  STEP 2 — Find the offending field.
#    kubectl -n argocd get application capa-guestbook \
#        -o jsonpath='{.spec.source.targetRevision}{"\n"}'
#    # -> capa-broken-revision      (this is the single wrong value)
#
#  STEP 3 — Correct it. Either the declarative way (patch the CR):
#    kubectl -n argocd patch application capa-guestbook --type merge \
#        -p '{"spec":{"source":{"targetRevision":"HEAD"}}}'
#    # ...or the imperative CLI way, if you are logged into argocd:
#    #   argocd app set capa-guestbook --revision HEAD
#
#  STEP 4 — Force a fresh comparison against the good revision.
#    kubectl -n argocd annotate application capa-guestbook \
#        argocd.argoproj.io/refresh=hard --overwrite
#    #   argocd app get capa-guestbook --refresh     # equivalent via CLI
#
#  STEP 5 — Let auto-sync converge (or push it manually).
#    # Automated sync should now transition Unknown -> Synced on its own.
#    # If you want to force it:
#    #   argocd app sync capa-guestbook
#
#  STEP 6 — Verify.
#    kubectl -n argocd get application capa-guestbook
#    # Expect: SYNC STATUS = Synced,  HEALTH STATUS = Healthy.
#    ./capa_3_1_break_fix.sh verify
#
#  TAKEAWAYS FOR THE EXAM
#    - "Unknown + ComparisonError" != "OutOfSync". The first means Argo CD
#      could not even build the desired state (bad repoURL / targetRevision /
#      path / unparseable manifests); the second means it built it and found
#      drift.
#    - Healthy pods do NOT imply a Healthy Application. The Application's
#      status reflects the GitOps reconciliation, not just runtime liveness.
#    - self-heal cannot fix what it cannot render. A broken source silences
#      reconciliation instead of triggering it.
#    - targetRevision accepts HEAD, a branch, a tag, or a commit SHA; a value
#      that resolves to none of these is the classic cause of this failure.
# ============================================================================