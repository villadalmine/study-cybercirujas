#!/usr/bin/env bash
#
# =============================================================================
#  CGOA — Certified GitOps Associate
#  Domain 3.1 · "GitOps Tooling & Implementation" (25% of the exam)
#  BREAK & FIX LAB — Argo CD reconciliation failures you will actually meet
# =============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  A GitOps controller is a closed loop: desired state (Git) -> render ->
#  diff against live state -> act. Every production incident in a GitOps
#  platform is a break in exactly one link of that loop. This lab breaks four
#  of them, one per class, and asks you to restore the loop:
#
#    Fault 1  SOURCE     the controller cannot resolve the desired state
#    Fault 2  TENANCY    the controller resolves it but is not allowed to use it
#    Fault 3  DIFF       the controller compares wrong, so drift is invisible
#    Fault 4  ACT        the controller sees the diff but is forbidden to act
#
#  Fault 3 is the dangerous one and the reason this lab exists: the dashboard
#  says "Synced / Healthy" while the cluster is objectively wrong. Learn to
#  distrust the green checkmark and to ask *what was compared*.
#
#  REQUIREMENTS
#  ------------
#    * A DISPOSABLE single-node cluster (kind / k3d / minikube / rancher-desktop)
#      on a throwaway lab VM. This script refuses to run anywhere else.
#    * kubectl >= 1.27, jq, git, curl, outbound HTTPS (GitHub + your registry).
#    * ~1.5 GiB RAM free for the Argo CD control plane.
#    * The `argocd` CLI is OPTIONAL. Every step is doable with kubectl alone;
#      the equivalent `argocd` commands are shown in comments and in `hint`.
#
#  USAGE
#  -----
#    ./cgoa-3.1-break-fix.sh setup      # install Argo CD + the healthy baseline
#    ./cgoa-3.1-break-fix.sh break      # inject the faults + print the briefing
#    ./cgoa-3.1-break-fix.sh status     # your diagnostic dashboard (read-only)
#    ./cgoa-3.1-break-fix.sh verify     # grade your fixes, objective by objective
#    ./cgoa-3.1-break-fix.sh hint [1-4] # progressive hints, no spoilers
#    ./cgoa-3.1-break-fix.sh solution   # prints the commented answer key below
#    ./cgoa-3.1-break-fix.sh cleanup    # remove everything this script created
#
#    Environment knobs:
#      FAULTS="1 3"          inject only some faults (default: "1 2 3 4")
#      ALLOW_ANY_CONTEXT=1   bypass the disposable-cluster guard (DON'T)
#      LAB_CONFIRM=yes       skip the interactive confirmation (CI use)
#      LAB_IMAGE=nginx:1.27-alpine   workload image used by the kustomize override
#
#  SAFETY MODEL
#  ------------
#    * Refuses to run unless the current kube-context looks like a local lab
#      cluster, the cluster has <= 3 nodes, and no namespace is labelled
#      env=prod / environment=production.
#    * Touches only: namespace `argocd`, namespace `gitops-lab`, the Application
#      `guestbook` and the AppProject `lab-restricted`. Nothing else, ever.
#    * `break` snapshots the pristine Application to $STATE_DIR before mutating,
#      so `cleanup` is always able to return the VM to a blank state.
#    * No `--force`, no `--grace-period=0`, no cluster-scoped deletions.
#
#  OFFICIAL SOURCES
#  ----------------
#    CNCF CGOA curriculum ....... https://github.com/cncf/curriculum/blob/master/cgoa/README.md
#    OpenGitOps principles ...... https://opengitops.dev/
#    Argo CD auto-sync .......... https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
#    Argo CD sync options ....... https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
#    Argo CD diffing ............ https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
#    Argo CD projects ........... https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
#    Argo CD resource tracking .. https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
#    Argo CD kustomize .......... https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/
#    Argo CD declarative setup .. https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
#    Flux GitRepository ......... https://fluxcd.io/flux/components/source/gitrepositories/
#    Flux Kustomization ......... https://fluxcd.io/flux/components/kustomize/kustomizations/
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
LAB_ID="cgoa-3.1"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
APP_NS="${APP_NS:-gitops-lab}"
APP_NAME="${APP_NAME:-guestbook}"
REPO_URL="${REPO_URL:-https://github.com/argoproj/argocd-example-apps.git}"
REPO_PATH="${REPO_PATH:-kustomize-guestbook}"
REPO_REV="${REPO_REV:-HEAD}"
LAB_IMAGE="${LAB_IMAGE:-nginx:1.27-alpine}"
ARGOCD_CHANNEL="${ARGOCD_CHANNEL:-stable}"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_CHANNEL}/manifests/install.yaml"
STATE_DIR="${STATE_DIR:-/var/tmp/${LAB_ID}-lab}"
BAD_PROJECT="lab-restricted"
ROGUE_CM="rogue-legacy-config"
FAULTS="${FAULTS:-1 2 3 4}"
CTX_PATTERN="${CTX_PATTERN:-^(kind-|k3d-|minikube|rancher-desktop|docker-desktop|colima|lab-)}"
MAX_NODES="${MAX_NODES:-3}"

# --- Presentation ------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$B" "----------------------------------------------------------------------" "$N"; }
head1() { rule; printf '%s%s%s\n' "$B" "$*" "$N"; rule; }

# --- Helpers -----------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing required binary: $1"; }

app_json() { kubectl -n "$ARGOCD_NS" get application "$APP_NAME" -o json 2>/dev/null; }
appq()     { app_json | jq -r "$1" 2>/dev/null || true; }

require_app() {
  kubectl -n "$ARGOCD_NS" get application "$APP_NAME" >/dev/null 2>&1 \
    || die "Application $APP_NAME not found in namespace $ARGOCD_NS. Run: $0 setup"
}

# Ask the controller to re-compare now instead of waiting for the 3m resync timer.
refresh_app() {
  kubectl -n "$ARGOCD_NS" annotate application "$APP_NAME" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

wants_fault() { [[ " $FAULTS " == *" $1 "* ]]; }

wait_until() {
  # wait_until <timeout_seconds> <description> <predicate-function>
  local timeout="$1" desc="$2" fn="$3" start=$SECONDS
  info "waiting for ${desc} (timeout ${timeout}s)"
  while (( SECONDS - start < timeout )); do
    if "$fn"; then return 0; fi
    sleep 5
  done
  return 1
}

app_synced_healthy() {
  [[ "$(appq '.status.sync.status')" == "Synced" && "$(appq '.status.health.status')" == "Healthy" ]]
}

# --- Safety guard ------------------------------------------------------------
guard_disposable_cluster() {
  need kubectl; need jq

  local ctx nodes prod
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "no current kube-context; point KUBECONFIG at your lab cluster"

  if [[ "${ALLOW_ANY_CONTEXT:-0}" != "1" ]]; then
    [[ "$ctx" =~ $CTX_PATTERN ]] || die \
"REFUSING TO RUN. Current context is '${ctx}', which does not look like a
   disposable lab cluster (expected pattern: ${CTX_PATTERN}).
   This script intentionally breaks a cluster. Point it at kind/k3d/minikube.
   If you are absolutely sure, re-run with ALLOW_ANY_CONTEXT=1."
  fi

  kubectl cluster-info >/dev/null 2>&1 || die "cannot reach the API server for context '${ctx}'"

  nodes="$(kubectl get nodes -o json | jq '.items | length')"
  (( nodes <= MAX_NODES )) || die \
"REFUSING TO RUN. Cluster has ${nodes} nodes (max allowed: ${MAX_NODES}).
   Lab clusters are small; this looks like a shared or production cluster."

  prod="$(kubectl get ns -o json \
    | jq -r '[.items[] | select((.metadata.labels.env // "") | test("^prod")) or ((.metadata.labels.environment // "") | test("^prod"))] | length')"
  [[ "$prod" == "0" ]] || die \
"REFUSING TO RUN. Found ${prod} namespace(s) labelled as production."

  printf '%s[guard]%s context=%s nodes=%s — accepted as a disposable lab cluster\n' \
    "$G" "$N" "$ctx" "$nodes"
}

confirm() {
  [[ "${LAB_CONFIRM:-}" == "yes" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "non-interactive shell: set LAB_CONFIRM=yes to acknowledge that this breaks the cluster"
  fi
  local answer
  printf '%sType %sBREAK MY LAB%s to continue: %s' "$Y" "$B" "$N$Y" "$N"
  read -r answer
  [[ "$answer" == "BREAK MY LAB" ]] || die "aborted by user"
}

# =============================================================================
# SETUP — install Argo CD and a known-good Application (the baseline)
# =============================================================================
detect_image_override() {
  # The upstream example manifests pin an old gcr.io image. We rewrite it through
  # Argo CD's kustomize image override so the lab depends only on a registry you
  # already reach. This is also a real 3.1 skill: source-level parameterisation.
  local tmp img=""
  tmp="$(mktemp -d)"
  if git clone --depth 1 --quiet "$REPO_URL" "$tmp/repo" 2>/dev/null; then
    img="$(grep -rhoE '^[[:space:]]*image:[[:space:]]*[^[:space:]]+' "$tmp/repo/$REPO_PATH" 2>/dev/null \
           | head -1 | awk '{print $2}' || true)"
  fi
  rm -rf "$tmp"
  img="${img:-gcr.io/heptio-images/ks-guestbook-demo:0.2}"
  # strip the tag only if the last path segment actually carries one
  local last="${img##*/}"
  [[ "$last" == *:* ]] && img="${img%:*}"
  printf '%s=%s\n' "$img" "$LAB_IMAGE"
}

install_argocd() {
  if kubectl get ns "$ARGOCD_NS" >/dev/null 2>&1 \
     && kubectl -n "$ARGOCD_NS" get deploy argocd-application-controller >/dev/null 2>&1; then
    info "Argo CD already present in namespace ${ARGOCD_NS}, skipping install (idempotent)"
    return 0
  fi
  info "installing Argo CD (${ARGOCD_CHANNEL}) into namespace ${ARGOCD_NS}"
  kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n "$ARGOCD_NS" -f "$ARGOCD_MANIFEST"
  info "waiting for the Argo CD control plane to become available"
  kubectl -n "$ARGOCD_NS" wait --for=condition=Available deployment --all --timeout=600s
  # The application-controller is a StatefulSet in recent releases; tolerate both.
  kubectl -n "$ARGOCD_NS" rollout status statefulset/argocd-application-controller --timeout=300s 2>/dev/null \
    || kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-application-controller --timeout=300s
}

apply_baseline_app() {
  local override
  override="$(detect_image_override)"
  info "kustomize image override: ${override}"

  kubectl create namespace "$APP_NS" --dry-run=client -o yaml \
    | kubectl label --local -f - "lab=${LAB_ID}" -o yaml \
    | kubectl apply -f -

  cat <<YAML | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NS}
  labels:
    lab: ${LAB_ID}
  finalizers:
    # Cascading delete: removing the Application removes the resources it owns.
    - resources-finalizer.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REPO_REV}
    path: ${REPO_PATH}
    kustomize:
      images:
        - ${override}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${APP_NS}
  syncPolicy:
    automated:
      prune: true      # delete live resources removed from Git
      selfHeal: true   # revert drift applied directly to the cluster
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 5
YAML
}

cmd_setup() {
  guard_disposable_cluster
  need git; need curl
  mkdir -p "$STATE_DIR"

  head1 "SETUP — building the healthy baseline"
  install_argocd
  apply_baseline_app
  refresh_app

  if wait_until 420 "the Application to report Synced/Healthy" app_synced_healthy; then
    ok "baseline is Synced and Healthy"
  else
    warn "baseline did not reach Synced/Healthy in time. Inspect before breaking anything:"
    warn "  kubectl -n ${ARGOCD_NS} get application ${APP_NAME} -o yaml | less"
    warn "  kubectl -n ${APP_NS} get pods"
    warn "Most common cause on an air-gapped VM: the workload image cannot be pulled."
    warn "Retry with e.g. LAB_IMAGE=<an image your registry serves> $0 setup"
  fi

  app_json > "${STATE_DIR}/application.pristine.json" 2>/dev/null || true

  rule
  say "${B}Argo CD UI${N}"
  say "  kubectl -n ${ARGOCD_NS} port-forward svc/argocd-server 8080:443"
  say "  open https://localhost:8080  (user: admin)"
  say "  password: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret \\"
  say "              -o jsonpath='{.data.password}' | base64 -d; echo"
  say ""
  say "  Optional CLI login:"
  say "  argocd login localhost:8080 --username admin --password \"\$PW\" --insecure"
  rule
  say "Baseline ready. Now run: ${B}$0 break${N}"
}

# =============================================================================
# BREAK — inject the faults
# =============================================================================
break_fault_1_source() {
  info "fault 1/4 — SOURCE: pointing the Application at a revision and path that do not exist"
  kubectl -n "$ARGOCD_NS" patch application "$APP_NAME" --type merge -p '{
    "spec": {
      "source": {
        "targetRevision": "release-42",
        "path": "kustomize-guestbok"
      }
    }
  }' >/dev/null
}

break_fault_2_tenancy() {
  info "fault 2/4 — TENANCY: moving the Application into a project that forbids its repo and namespace"
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${BAD_PROJECT}
  namespace: ${ARGOCD_NS}
  labels:
    lab: ${LAB_ID}
spec:
  description: "Tenant boundary installed by a well-meaning platform admin"
  sourceRepos:
    - https://github.com/acme-internal/*
  destinations:
    - namespace: acme-prod
      server: https://kubernetes.default.svc
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
YAML
  kubectl -n "$ARGOCD_NS" patch application "$APP_NAME" --type merge \
    -p "{\"spec\":{\"project\":\"${BAD_PROJECT}\"}}" >/dev/null
}

break_fault_3_diff() {
  info "fault 3/4 — DIFF: disabling self-heal and masking replica drift with ignoreDifferences"
  kubectl -n "$ARGOCD_NS" patch application "$APP_NAME" --type merge -p '{
    "spec": {
      "syncPolicy": { "automated": { "prune": true, "selfHeal": false } },
      "ignoreDifferences": [
        {
          "group": "apps",
          "kind": "Deployment",
          "jsonPointers": ["/spec/replicas"]
        }
      ]
    }
  }' >/dev/null

  local dep
  dep="$(kubectl -n "$APP_NS" get deploy -o name 2>/dev/null | head -1 || true)"
  if [[ -n "$dep" ]]; then
    kubectl -n "$APP_NS" scale "$dep" --replicas=4 >/dev/null
    info "        drift applied: ${dep} scaled to 4 replicas directly in the cluster"
  else
    warn "        no Deployment found in ${APP_NS}; drift will appear once fault 1 is fixed"
  fi
}

break_fault_4_act() {
  info "fault 4/4 — ACT: planting a tracked orphan resource that refuses to be pruned"
  kubectl -n "$APP_NS" create configmap "$ROGUE_CM" \
    --from-literal=owner=leftover-migration \
    --from-literal=note="created by hand during the 2024 cutover, never added to Git" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # The instance label is Argo CD's default resource-tracking mechanism: this
  # ConfigMap now *claims* to belong to the Application, but no manifest in Git
  # produces it -> the controller wants to prune it.
  kubectl -n "$APP_NS" label configmap "$ROGUE_CM" \
    "app.kubernetes.io/instance=${APP_NAME}" --overwrite >/dev/null
  # ...and this sync option forbids the controller from doing so.
  kubectl -n "$APP_NS" annotate configmap "$ROGUE_CM" \
    'argocd.argoproj.io/sync-options=Prune=false' --overwrite >/dev/null
}

print_briefing() {
  head1 "MISSION BRIEFING — CGOA 3.1 · GitOps Tooling & Implementation"
  cat <<'BRIEF'
An on-call engineer "fixed things by hand" on this cluster last night. Argo CD is
still running; the Application is not. Your job is to restore a trustworthy
reconciliation loop — not merely a green screen.

Ground rules
  * Do NOT delete and recreate the Application. Diagnose, then repair.
  * Do NOT `kubectl apply` the workload yourself. Git is the source of truth;
    if you fix live state by hand you have proven nothing.
  * Everything is doable with kubectl. The argocd CLI is a convenience.

Start here:
  kubectl -n argocd get application guestbook
  kubectl -n argocd get application guestbook -o jsonpath='{.status.conditions}' | jq .
  kubectl -n argocd logs deploy/argocd-repo-server --tail=50
  kubectl -n argocd logs statefulset/argocd-application-controller --tail=50

BRIEF

  if wants_fault 1; then
    say "${B}FAULT 1 — the controller cannot resolve the desired state${N}"
    say "  SYMPTOM   Sync status and health both show ${Y}Unknown${N}. The Application"
    say "            carries a ComparisonError condition whose message mentions a"
    say "            revision that cannot be resolved to a commit SHA, and/or an"
    say "            app path that does not exist in the repository."
    say "            .status.sync.revision is empty: nothing was ever rendered."
    say "  OBJECTIVE Make the Application resolve a real revision and a real path in"
    say "            ${REPO_URL},"
    say "            so that .status.sync.revision holds a commit SHA and no"
    say "            ComparisonError condition remains."
    say "  THINK     Which component resolves the revision — repo-server or the"
    say "            application-controller? Where do you see its error first?"
    say "            (Flux equivalent: a GitRepository whose Ready condition is"
    say "             False because the ref cannot be checked out.)"
    say ""
  fi

  if wants_fault 2; then
    say "${B}FAULT 2 — the controller is not allowed to use that source${N}"
    say "  SYMPTOM   Even with a valid source, the Application reports an"
    say "            ${Y}InvalidSpecError${N} saying the repo is not permitted in its"
    say "            project, and/or that the destination namespace is not permitted."
    say "            Syncing from the UI/CLI is rejected before anything is applied."
    say "  OBJECTIVE Restore the tenancy boundary correctly: the project that owns"
    say "            this Application must explicitly permit the repository and the"
    say "            destination namespace ${APP_NS}. No 'not permitted'"
    say "            condition may remain."
    say "  THINK     AppProject is the multi-tenancy guardrail: sourceRepos,"
    say "            destinations, and resource allow/deny lists. Ask yourself which"
    say "            side is wrong — the Application or the project — before editing."
    say ""
  fi

  if wants_fault 3; then
    say "${B}FAULT 3 — the diff lies to you (the dangerous one)${N}"
    say "  SYMPTOM   Once faults 1 and 2 are gone, the Application reports the"
    say "            Deployment as ${G}Synced${N} — while the live Deployment runs 4"
    say "            replicas and Git asks for 1. Nothing corrects it, ever."
    say "  OBJECTIVE Make the reported state match reality AND make the controller"
    say "            enforce Git again: the replica count must return to the value"
    say "            declared in the repository ${B}without you scaling anything${N}."
    say "  THINK     Two independent settings conspire here. One decides *what is"
    say "            compared*; the other decides *whether drift is corrected*."
    say "            Note that automated sync alone does not fix drift, and that an"
    say "            ignored difference is never self-healed either."
    say "            (Flux equivalent: spec.force/prune plus a drift-detection gap.)"
    say ""
  fi

  if wants_fault 4; then
    say "${B}FAULT 4 — the controller sees the diff but may not act${N}"
    say "  SYMPTOM   The Application stays ${Y}OutOfSync${N} forever with one extra"
    say "            resource in ${APP_NS} that is attributed to this app but exists"
    say "            in no manifest. A sync with pruning enabled completes"
    say "            successfully and the resource is still there."
    say "  OBJECTIVE End with zero resources requiring pruning and the Application"
    say "            fully Synced — while understanding *why* Argo CD believed that"
    say "            hand-made object belonged to it in the first place."
    say "  THINK     Resource tracking (instance label vs. tracking annotation) and"
    say "            per-resource sync options. Read the object's own metadata."
    say ""
  fi

  rule
  say "Grade yourself at any time:  ${B}$0 verify${N}"
  say "Stuck?                       ${B}$0 hint 1${N} .. ${B}$0 hint 4${N}"
  rule
}

cmd_break() {
  guard_disposable_cluster
  require_app
  mkdir -p "$STATE_DIR"

  head1 "BREAK — this will deliberately damage the lab cluster"
  say "Target context : $(kubectl config current-context)"
  say "Target objects : Application/${APP_NAME}, AppProject/${BAD_PROJECT}, ns/${APP_NS}"
  say "Faults to inject: ${FAULTS}"
  confirm

  app_json > "${STATE_DIR}/application.pristine.json"
  info "pristine Application snapshot saved to ${STATE_DIR}/application.pristine.json"
  info "(that file is the answer key for the Application spec — resist reading it)"

  wants_fault 2 && break_fault_2_tenancy
  wants_fault 1 && break_fault_1_source
  wants_fault 3 && break_fault_3_diff
  wants_fault 4 && break_fault_4_act
  refresh_app

  info "waiting ~20s for the controller to report the damage"
  sleep 20
  print_briefing
}

# =============================================================================
# STATUS — read-only diagnostic dashboard
# =============================================================================
cmd_status() {
  require_app
  refresh_app; sleep 3

  head1 "STATUS — Application ${APP_NAME}"
  kubectl -n "$ARGOCD_NS" get application "$APP_NAME" \
    -o custom-columns='NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
    2>/dev/null || true

  say ""
  say "${B}spec.source${N}"
  appq '.spec.source | {repoURL, targetRevision, path, kustomize}' | sed 's/^/  /'

  say ""
  say "${B}spec.syncPolicy / spec.ignoreDifferences${N}"
  appq '{syncPolicy: .spec.syncPolicy, ignoreDifferences: (.spec.ignoreDifferences // [])}' | sed 's/^/  /'

  say ""
  say "${B}status.conditions${N}  (empty is what you want)"
  local conds
  conds="$(appq '[.status.conditions[]? | {type, message}]')"
  if [[ -z "$conds" || "$conds" == "[]" ]]; then
    say "  ${G}none${N}"
  else
    printf '%s\n' "$conds" | sed "s/^/  ${R}/;s/\$/${N}/"
  fi

  say ""
  say "${B}resources requiring pruning${N}  (tracked, but absent from Git)"
  local prune
  prune="$(appq '[.status.resources[]? | select(.requiresPruning == true) | "\(.kind)/\(.name) in \(.namespace // "-")"] | .[]')"
  if [[ -z "$prune" ]]; then say "  ${G}none${N}"; else printf '%s\n' "$prune" | sed "s/^/  ${Y}/;s/\$/${N}/"; fi

  say ""
  say "${B}out-of-sync resources${N}"
  appq '[.status.resources[]? | select(.status != "Synced") | "\(.kind)/\(.name): \(.status)"] | .[]' \
    | sed 's/^/  /' || true

  say ""
  say "${B}live workload in namespace ${APP_NS}${N}"
  kubectl -n "$APP_NS" get deploy,cm -o wide 2>/dev/null | sed 's/^/  /' || say "  (namespace empty)"

  say ""
  say "${B}live vs. declared replicas${N}"
  local dep live
  dep="$(kubectl -n "$APP_NS" get deploy -o name 2>/dev/null | head -1 || true)"
  if [[ -n "$dep" ]]; then
    live="$(kubectl -n "$APP_NS" get "$dep" -o jsonpath='{.spec.replicas}')"
    say "  live: ${dep} = ${live} replica(s)"
    say "  declared: inspect the rendered manifests, e.g."
    say "    argocd app manifests ${APP_NAME} | grep -A2 'replicas'"
    say "    (or read ${REPO_PATH}/ in ${REPO_URL})"
  else
    say "  no Deployment present"
  fi
  rule
}

# =============================================================================
# VERIFY — grade the objectives
# =============================================================================
cmd_verify() {
  require_app
  refresh_app
  info "refreshed the Application and waiting 25s for reconciliation to settle"
  sleep 25

  local failures=0

  head1 "VERIFY — objective by objective"

  # ---- Objective 1: the source resolves -------------------------------------
  if wants_fault 1; then
    local rev cmp_err
    rev="$(appq '.status.sync.revision // ""')"
    cmp_err="$(appq '[.status.conditions[]? | select(.type == "ComparisonError")] | length')"
    if [[ "$rev" =~ ^[0-9a-f]{7,40}$ && "${cmp_err:-0}" == "0" ]]; then
      ok "1/4 SOURCE — desired state resolves (revision ${rev:0:7}, no ComparisonError)"
    else
      bad "1/4 SOURCE — the controller still cannot render the desired state"
      say "      revision='${rev}' comparisonErrors=${cmp_err:-?}"
      say "      look at: .spec.source.targetRevision and .spec.source.path"
      failures=$((failures+1))
    fi
  fi

  # ---- Objective 2: the project permits the source and destination ----------
  if wants_fault 2; then
    local denied proj
    proj="$(appq '.spec.project')"
    denied="$(appq '[.status.conditions[]? | select(.message | test("not permitted|does not permit"; "i"))] | length')"
    if [[ "${denied:-0}" == "0" ]]; then
      ok "2/4 TENANCY — project '${proj}' permits this repository and destination"
    else
      bad "2/4 TENANCY — the AppProject boundary still rejects this Application"
      appq '[.status.conditions[]? | select(.message | test("not permitted|does not permit"; "i")) | .message] | .[]' | sed 's/^/      /'
      say "      inspect: kubectl -n ${ARGOCD_NS} get appproject ${proj} -o yaml"
      failures=$((failures+1))
    fi
  fi

  # ---- Objective 3: the diff is honest and drift is corrected ---------------
  if wants_fault 3; then
    local ignored selfheal depstatus
    ignored="$(appq '[.spec.ignoreDifferences[]? | select((.jsonPointers // []) + (.jqPathExpressions // []) | tostring | test("replicas"))] | length')"
    selfheal="$(appq '.spec.syncPolicy.automated.selfHeal // false')"
    depstatus="$(appq '[.status.resources[]? | select(.kind == "Deployment") | .status] | join(",")')"
    if [[ "${ignored:-0}" == "0" && "$selfheal" == "true" && "$depstatus" == "Synced" ]]; then
      ok "3/4 DIFF — replica drift is visible again, self-heal is on, Deployment is Synced"
    else
      bad "3/4 DIFF — the comparison or the enforcement is still wrong"
      say "      ignoreDifferences touching replicas: ${ignored:-?} (must be 0)"
      say "      syncPolicy.automated.selfHeal: ${selfheal} (must be true)"
      say "      Deployment sync status: ${depstatus:-none} (must be Synced)"
      say "      NOTE: do not scale the Deployment yourself — the controller must do it."
      failures=$((failures+1))
    fi
  fi

  # ---- Objective 4: nothing is stuck awaiting pruning -----------------------
  if wants_fault 4; then
    local pruning
    pruning="$(appq '[.status.resources[]? | select(.requiresPruning == true)] | length')"
    if [[ "${pruning:-0}" == "0" ]]; then
      ok "4/4 ACT — no tracked resource is stuck waiting to be pruned"
    else
      bad "4/4 ACT — ${pruning} resource(s) still require pruning and are not being removed"
      appq '[.status.resources[]? | select(.requiresPruning == true) | "\(.kind)/\(.name)"] | .[]' | sed 's/^/      /'
      say "      inspect the object's own metadata:"
      say "      kubectl -n ${APP_NS} get cm ${ROGUE_CM} -o jsonpath='{.metadata}' | jq ."
      failures=$((failures+1))
    fi
  fi

  # ---- Final gate -----------------------------------------------------------
  local sync health
  sync="$(appq '.status.sync.status')"; health="$(appq '.status.health.status')"
  rule
  if [[ "$sync" == "Synced" && "$health" == "Healthy" && $failures -eq 0 ]]; then
    say "${G}${B}LAB PASSED${N} — Application ${APP_NAME}: Synced / Healthy, loop restored."
    say "Now prove it holds: break it again by hand and watch the controller undo you:"
    say "  kubectl -n ${APP_NS} scale deploy --all --replicas=7 && sleep 20 && kubectl -n ${APP_NS} get deploy"
    rule
    return 0
  fi
  say "${R}${B}NOT DONE YET${N} — Application ${APP_NAME}: ${sync} / ${health}, ${failures} objective(s) failing."
  say "Run '$0 status' for the dashboard, '$0 hint <n>' for a nudge."
  rule
  return 1
}

# =============================================================================
# HINT — progressive nudges, no full answers
# =============================================================================
cmd_hint() {
  local n="${1:-0}"
  case "$n" in
    1) cat <<'H'
HINT — Fault 1 (SOURCE)
  * The full error text lives in the Application status, not in `get app`:
      kubectl -n argocd get app guestbook -o jsonpath='{.status.conditions}' | jq .
  * The repo-server is the component that fetches and renders. Its log names the
    exact git operation that failed:
      kubectl -n argocd logs deploy/argocd-repo-server --tail=100 | grep -i -E 'revision|ls-remote|path'
  * Ask git yourself what actually exists — the controller has no magic:
      git ls-remote --heads --tags https://github.com/argoproj/argocd-example-apps.git | head
  * Two fields in .spec.source are wrong, not one. One names a ref; one names a
    directory. Compare both against the repository.
  * CLI equivalent of the repair: `argocd app set guestbook --revision <ref> --path <dir>`
H
      ;;
    2) cat <<'H'
HINT — Fault 2 (TENANCY)
  * The condition type to look for is InvalidSpecError, and its message names the
    project that refused the request.
  * List projects and read the one in use:
      kubectl -n argocd get appprojects
      kubectl -n argocd get appproject lab-restricted -o yaml
  * Three fields decide everything: spec.sourceRepos (which repos may be used),
    spec.destinations (which server+namespace pairs may be targeted), and the
    resource allow/deny lists.
  * There are two legitimate repairs. Moving the Application back to `default`
    makes the symptom vanish but dissolves the tenancy boundary; widening the
    project's allow-lists keeps the boundary and is what a platform team does.
    The grader accepts either — choose deliberately and be able to justify it.
  * CLI: `argocd proj add-source ...`, `argocd proj add-destination ...`
H
      ;;
    3) cat <<'H'
HINT — Fault 3 (DIFF)
  * Compare what Argo CD *renders* with what is *running*:
      argocd app manifests guestbook | grep -n -A1 replicas
      kubectl -n gitops-lab get deploy -o jsonpath='{.items[*].spec.replicas}'
    If those disagree while the UI says Synced, the comparison itself is rigged.
  * Read the Application spec for a field whose entire purpose is to remove
    something from the diff:
      kubectl -n argocd get app guestbook -o jsonpath='{.spec.ignoreDifferences}' | jq .
  * Then read the sync policy. Automated sync reacts to changes in Git.
    Correcting changes made *in the cluster* is a separate switch.
  * Order matters: unmask the diff first, then let enforcement act. Do not scale
    the Deployment by hand — that is the anti-pattern this fault is about.
  * To remove a whole field with kubectl, `--type json` and an op:"remove" patch
    is the reliable route; a merge patch with null also works.
H
      ;;
    4) cat <<'H'
HINT — Fault 4 (ACT)
  * Find out why Argo CD thinks that object is its own:
      kubectl -n gitops-lab get cm rogue-legacy-config -o jsonpath='{.metadata}' | jq .
    Default resource tracking is the label app.kubernetes.io/instance
    (configurable via application.instanceLabelKey / application.resourceTrackingMethod
     in the argocd-cm ConfigMap).
  * Now find out why it is not deleted despite prune being enabled. There is an
    annotation whose whole job is to veto pruning for one resource. It is honoured
    even when it sits only on the live object.
  * Three valid endings: delete the orphan, remove the veto annotation and let the
    controller prune it, or untrack it (drop the instance label) so it stops being
    reported as belonging to the app. Pick the one that matches what a real
    "leftover from a 2024 migration" deserves, and be able to explain it.
  * Force a sync attempt to observe the veto in action:
      argocd app sync guestbook --prune
      kubectl -n argocd get app guestbook -o jsonpath='{.status.operationState.message}'
H
      ;;
    *) die "usage: $0 hint <1|2|3|4>" ;;
  esac
}

cmd_solution() {
  head1 "ANSWER KEY (also readable as comments at the bottom of this file)"
  sed -n '/^# === SOLUTION START/,/^# === SOLUTION END/p' "$0"
}

# =============================================================================
# CLEANUP — leave the VM as it was
# =============================================================================
cmd_cleanup() {
  guard_disposable_cluster
  head1 "CLEANUP — removing everything this lab created"

  if kubectl -n "$ARGOCD_NS" get application "$APP_NAME" >/dev/null 2>&1; then
    info "deleting Application ${APP_NAME} (cascading through its finalizer)"
    kubectl -n "$ARGOCD_NS" delete application "$APP_NAME" --wait=false >/dev/null 2>&1 || true
    local waited=0
    while kubectl -n "$ARGOCD_NS" get application "$APP_NAME" >/dev/null 2>&1 && (( waited < 90 )); do
      sleep 5; waited=$((waited+5))
    done
    if kubectl -n "$ARGOCD_NS" get application "$APP_NAME" >/dev/null 2>&1; then
      warn "deletion is stuck on the finalizer (a broken controller cannot finish it)"
      warn "removing resources-finalizer.argoproj.io — the standard unblock:"
      kubectl -n "$ARGOCD_NS" patch application "$APP_NAME" --type merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    fi
  fi

  kubectl -n "$ARGOCD_NS" delete appproject "$BAD_PROJECT" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "$APP_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  if [[ "${PURGE_ARGOCD:-0}" == "1" ]]; then
    info "PURGE_ARGOCD=1 — deleting the Argo CD installation as well"
    kubectl delete namespace "$ARGOCD_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io \
      --ignore-not-found >/dev/null 2>&1 || true
  else
    info "Argo CD kept (re-run with PURGE_ARGOCD=1 to remove it too)"
  fi

  rm -rf "$STATE_DIR"
  ok "cleanup done"
}

# =============================================================================
usage() {
  cat <<USAGE
CGOA 3.1 — GitOps Tooling & Implementation :: break & fix lab

  $0 setup      install Argo CD + the healthy baseline Application
  $0 break      inject the faults and print the mission briefing
  $0 status     read-only diagnostic dashboard
  $0 verify     grade your fixes objective by objective
  $0 hint <n>   progressive hint for fault n (1..4)
  $0 solution   print the step-by-step answer key
  $0 cleanup    remove everything this lab created

Environment: FAULTS, ALLOW_ANY_CONTEXT, LAB_CONFIRM, LAB_IMAGE, PURGE_ARGOCD
USAGE
}

main() {
  case "${1:-}" in
    setup)    shift; cmd_setup "$@" ;;
    break)    shift; cmd_break "$@" ;;
    status)   shift; cmd_status "$@" ;;
    verify)   shift; cmd_verify "$@" ;;
    hint)     shift; cmd_hint "${1:-0}" ;;
    solution) shift; cmd_solution ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
exit $?

# === SOLUTION START ==========================================================
#
#  STEP-BY-STEP SOLUTION — do not read until you have tried `verify`
#  -----------------------------------------------------------------
#
#  STEP 0 — Read the machine, not the dashboard
#  -------------------------------------------
#    kubectl -n argocd get application guestbook
#    kubectl -n argocd get application guestbook -o json | jq '.status.conditions'
#    kubectl -n argocd logs deploy/argocd-repo-server --tail=100
#    kubectl -n argocd logs statefulset/argocd-application-controller --tail=100
#
#    `.status.conditions` is the single most useful field in the Application CR:
#    ComparisonError means "I could not build the desired state"; InvalidSpecError
#    means "your spec is not allowed"; SyncError means "I tried and the API server
#    said no". They are produced by different components, so they send you to
#    different logs. (Ref: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
#
#
#  STEP 1 — SOURCE: make the desired state resolvable
#  -------------------------------------------------
#    Observed:
#      ComparisonError: ... Unable to resolve 'release-42' to a commit SHA
#      (and, once the revision is fixed) app path does not exist: kustomize-guestbok
#
#    Confirm from outside Argo CD which refs and paths actually exist:
#      git ls-remote --heads https://github.com/argoproj/argocd-example-apps.git
#      git clone --depth 1 https://github.com/argoproj/argocd-example-apps.git /tmp/ex && ls /tmp/ex
#
#    Repair:
#      kubectl -n argocd patch application guestbook --type merge -p '{
#        "spec": { "source": { "targetRevision": "HEAD", "path": "kustomize-guestbook" } }
#      }'
#
#      # argocd CLI equivalent:
#      # argocd app set guestbook --revision HEAD --path kustomize-guestbook
#
#    Verify:
#      kubectl -n argocd get app guestbook -o jsonpath='{.status.sync.revision}{"\n"}'
#      # -> a 40-char commit SHA. Empty means it still did not render.
#
#    Why it matters: `targetRevision` is the contract between Git and the cluster.
#    A branch name is a moving target (continuous delivery of whatever lands), a
#    tag or SHA is an immutable pin (auditable, reproducible rollback). In
#    production, pin environments to tags/SHAs and promote by changing the pin —
#    that promotion is itself a reviewable commit, which is the whole point of the
#    OpenGitOps "declared, versioned and immutable" principle (https://opengitops.dev/).
#    Flux equivalent: GitRepository .spec.ref.{branch,tag,semver,commit}; the same
#    failure surfaces as a GitRepository whose Ready condition is False.
#
#
#  STEP 2 — TENANCY: let the project permit this workload
#  -----------------------------------------------------
#    Observed:
#      InvalidSpecError: application repo https://github.com/argoproj/argocd-example-apps.git
#        is not permitted in project 'lab-restricted'
#      InvalidSpecError: application destination ... is not permitted in project 'lab-restricted'
#
#    Inspect the boundary before touching it:
#      kubectl -n argocd get appproject lab-restricted -o yaml
#
#    Preferred repair — widen the project, keep the boundary:
#      kubectl -n argocd patch appproject lab-restricted --type merge -p '{
#        "spec": {
#          "sourceRepos": [
#            "https://github.com/acme-internal/*",
#            "https://github.com/argoproj/argocd-example-apps.git"
#          ],
#          "destinations": [
#            { "namespace": "acme-prod",  "server": "https://kubernetes.default.svc" },
#            { "namespace": "gitops-lab", "server": "https://kubernetes.default.svc" }
#          ]
#        }
#      }'
#
#      # argocd CLI equivalent:
#      # argocd proj add-source lab-restricted https://github.com/argoproj/argocd-example-apps.git
#      # argocd proj add-destination lab-restricted https://kubernetes.default.svc gitops-lab
#
#    Acceptable alternative — move the app back to the default project:
#      kubectl -n argocd patch application guestbook --type merge -p '{"spec":{"project":"default"}}'
#      This clears the symptom but throws away the guardrail. Choose it only if the
#      project was created by mistake; in a shared cluster it is the wrong answer.
#
#    Why it matters: AppProject is Argo CD's tenancy primitive — it constrains
#    which repos a tenant may deploy from, which cluster/namespace pairs they may
#    write to, which cluster-scoped kinds they may create, and it carries the RBAC
#    role bindings. `default` permits '*' everywhere, which is exactly why no
#    production installation should leave workloads in it.
#    Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
#
#
#  STEP 3 — DIFF: unmask the drift, then enforce it
#  -----------------------------------------------
#    Observed: the Deployment reports Synced, yet:
#      kubectl -n gitops-lab get deploy -o jsonpath='{.items[*].spec.replicas}'   -> 4
#      argocd app manifests guestbook | grep -A1 replicas                          -> 1
#
#    The two culprits, read them first:
#      kubectl -n argocd get app guestbook -o jsonpath='{.spec.ignoreDifferences}' | jq .
#      kubectl -n argocd get app guestbook -o jsonpath='{.spec.syncPolicy}' | jq .
#
#    3a. Remove the diff mask (JSON-patch removal is the reliable form):
#      kubectl -n argocd patch application guestbook --type json \
#        -p '[{"op":"remove","path":"/spec/ignoreDifferences"}]'
#
#      # merge-patch alternative:
#      # kubectl -n argocd patch application guestbook --type merge -p '{"spec":{"ignoreDifferences":null}}'
#
#      Immediately after this the app flips to OutOfSync — that is progress: the
#      diff is now telling the truth.
#
#    3b. Re-enable drift correction:
#      kubectl -n argocd patch application guestbook --type merge -p '{
#        "spec": { "syncPolicy": { "automated": { "prune": true, "selfHeal": true } } }
#      }'
#
#      # argocd CLI equivalent:
#      # argocd app set guestbook --sync-policy automated --self-heal --auto-prune
#
#    3c. Watch the controller — not you — undo the drift:
#      kubectl -n gitops-lab get deploy -w        # replicas return to 1 within seconds
#
#    Why it matters, and this is the exam-relevant nuance:
#      * `automated: {}` alone syncs when the *desired* state changes (a new commit).
#        It does NOT react to someone editing the cluster.
#      * `selfHeal: true` is what makes the loop converge on cluster-side drift.
#        Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
#      * `ignoreDifferences` removes a field from the comparison entirely. An
#        ignored field is never reported AND never self-healed — which is exactly
#        what you want for fields owned by another controller (an HPA owning
#        /spec/replicas, a webhook injecting sidecars) and exactly what you must
#        never use to silence an inconvenient diff.
#        Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
#      * The legitimate version of this pattern is HPA coexistence: ignore
#        /spec/replicas *because* an HPA owns it, and document why. An undocumented
#        ignoreDifferences is a lie encoded in YAML — grep for it during audits.
#
#
#  STEP 4 — ACT: unblock the prune of the tracked orphan
#  ----------------------------------------------------
#    Observed: permanently OutOfSync, one resource with requiresPruning=true:
#      kubectl -n argocd get app guestbook -o json \
#        | jq '[.status.resources[] | select(.requiresPruning == true)]'
#
#    Find out why it is attributed to the app and why prune is vetoed:
#      kubectl -n gitops-lab get cm rogue-legacy-config -o jsonpath='{.metadata}' | jq .
#      # labels:      app.kubernetes.io/instance: guestbook     <- makes Argo CD own it
#      # annotations: argocd.argoproj.io/sync-options: Prune=false  <- forbids deletion
#
#    Repair (pick one, deliberately):
#      # (a) It is genuine leftover garbage — delete it:
#      kubectl -n gitops-lab delete configmap rogue-legacy-config
#
#      # (b) Let the controller prune it, which proves the loop works:
#      kubectl -n gitops-lab annotate configmap rogue-legacy-config \
#        argocd.argoproj.io/sync-options-
#      argocd app sync guestbook --prune     # or wait for self-heal
#
#      # (c) It must survive but is not Argo CD's business — untrack it:
#      kubectl -n gitops-lab label configmap rogue-legacy-config app.kubernetes.io/instance-
#
#    Why it matters:
#      * Resource tracking: by default Argo CD claims resources carrying
#        app.kubernetes.io/instance=<app>. That label is also used by Helm and by
#        the common labels convention, which is why a hand-made object can be
#        adopted by accident and then deleted by a prune. The safer production
#        setting is annotation-based tracking:
#          kubectl -n argocd patch cm argocd-cm --type merge \
#            -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'
#        which uses argocd.argoproj.io/tracking-id and cannot collide with Helm.
#        Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
#      * Sync options are per-resource vetoes over the controller's actions:
#        Prune=false, Delete=false, Replace=true, ServerSideApply=true,
#        SkipDryRunOnMissingResource=true, PruneLast=true. They are honoured even
#        when only the live object carries them, so a stale annotation can freeze
#        reconciliation indefinitely.
#        Ref: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
#      * "Sync succeeded but still OutOfSync" is the signature of a skipped prune.
#        Read .status.operationState.message before suspecting the controller.
#
#
#  STEP 5 — Prove the loop, do not trust it
#  ----------------------------------------
#    ./cgoa-3.1-break-fix.sh verify
#
#    Then attack it once more and watch it defend itself:
#      kubectl -n gitops-lab scale deploy --all --replicas=7
#      kubectl -n gitops-lab delete svc --all
#      sleep 20 && kubectl -n gitops-lab get deploy,svc
#      # Both must be restored by the controller, from Git, with no human action.
#
#    That last test is the actual definition of GitOps compliance: the system's
#    observed state converges to the declared state continuously and autonomously.
#    Everything else in this lab was a way of breaking one of those four words.
#
#
#  MAPPING TO FLUX (the exam covers both toolchains)
#  -------------------------------------------------
#    Fault 1  SOURCE   -> GitRepository .spec.ref / .spec.url; `flux get sources git`
#                        Ready=False with "failed to checkout and determine revision".
#                        https://fluxcd.io/flux/components/source/gitrepositories/
#    Fault 2  TENANCY  -> Kustomization .spec.serviceAccountName + RBAC, and
#                        cross-namespace source refs disabled by the controller flag
#                        --no-cross-namespace-refs. The boundary is Kubernetes RBAC
#                        rather than an AppProject CR.
#    Fault 3  DIFF     -> `flux diff kustomization`, .spec.force, and drift correction:
#                        Flux re-applies on every interval, so drift is corrected by
#                        default; the analogue of the mask is excluding paths or
#                        setting .spec.suspend: true, which silences reconciliation
#                        while the object still reports its last known state.
#                        https://fluxcd.io/flux/components/kustomize/kustomizations/
#    Fault 4  ACT      -> .spec.prune plus the kustomize.toolkit.fluxcd.io/prune: disabled
#                        annotation, and the inventory that Flux keeps in the
#                        Kustomization status (its equivalent of resource tracking).
#
#
#  EXAM CHECKPOINTS COVERED (CGOA domain 3.1, 25%)
#  -----------------------------------------------
#    * Argo CD Application CR anatomy: source / destination / project / syncPolicy.
#    * Manifest formats and rendering: kustomize path + image overrides at the
#      Application level. https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/
#    * Automated sync vs. self-heal vs. prune — three orthogonal switches.
#    * Diff customisation and its abuse; when ignoreDifferences is correct (HPA,
#      mutating webhooks) and when it is a cover-up.
#    * Resource tracking and ownership; label vs. annotation tracking methods.
#    * Multi-tenancy via AppProject: sourceRepos, destinations, resource allow-lists.
#    * Reading controller conditions and choosing the right component's logs.
#    * Cascading deletion and the resources-finalizer.argoproj.io escape hatch.
#
# === SOLUTION END ============================================================