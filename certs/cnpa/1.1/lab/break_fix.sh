#!/usr/bin/env bash
#
# =============================================================================
#  CNPA — Cloud Native Platform Engineering Associate   (exam version 2025-04-01)
#  Domain 1 · Topic 1.1 — Declarative Resource Management and Infrastructure
#                         Concepts                             (exam weight 7.2)
#
#  BREAK & FIX LAB — "the cluster is not the source of truth"
#
#  Three production incidents that share one root cause: a declarative system
#  was operated as if it were imperative.
#
#    FAULT A — The Deployment was created imperatively (`kubectl create -f`
#              without --save-config). `kubectl apply` therefore has no
#              `kubectl.kubernetes.io/last-applied-configuration` bookkeeping
#              and can no longer compute deletions: fields that exist in the
#              cluster but not in the manifest survive every apply forever.
#
#    FAULT B — Two field managers claim `.spec.replicas` under Server-Side
#              Apply. The GitOps applier is rejected with a conflict, so the
#              pipeline is red and the desired state never lands.
#
#    FAULT C — The source of truth itself is wrong: the ConfigMap manifest
#              carries a dangling `ownerReference`. The garbage collector
#              resolves the owner, does not find it, and deletes the object a
#              few seconds after every apply. The workload cannot start.
#
#  MENTAL MODEL BEING TRAINED
#    A Kubernetes object is a record of intent. Controllers run a reconciliation
#    loop: observe current state -> compare against desired state -> act. Three
#    different actors write "desired state" here — the human, the GitOps
#    applier, and a rogue automation — and Kubernetes keeps a per-field ledger
#    (`.metadata.managedFields`) of who wrote what. Almost every "my apply does
#    nothing" incident in production is a question about that ledger.
#
#  DESTRUCTIVE — run ONLY on a disposable single-node lab cluster (kind, k3d,
#  k3s, minikube, colima, docker-desktop). Every cluster mutation is confined
#  to the namespace `cnpa-lab-11`; every file mutation is confined to
#  $CNPA_LAB_HOME (default: ~/cnpa-lab-1.1). Nothing else is touched.
#
#  USAGE
#     ./break_fix.sh break      # arm the lab (default subcommand)
#     ./break_fix.sh status     # dump current state, no grading
#     ./break_fix.sh hint       # progressive hints, no spoilers
#     ./break_fix.sh verify     # grade your fix
#     ./break_fix.sh cleanup    # delete namespace + working directory
#
#  ENVIRONMENT
#     CNPA_LAB_HOME=<dir>   working directory        (default ~/cnpa-lab-1.1)
#     CNPA_LAB_IMAGE=<ref>  container image          (default busybox:1.36)
#     CNPA_LAB_YES=1        skip the interactive confirmation
#     CNPA_LAB_FORCE=1      bypass the kube-context allowlist (use with care)
#
#  SOURCES (original material; mechanics verified against upstream docs)
#     - CNCF CNPA curriculum
#       https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#     - Declarative management of objects with kubectl apply
#       https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
#     - Server-Side Apply, field management and conflicts
#       https://kubernetes.io/docs/reference/using-api/server-side-apply/
#     - Owners and dependents
#       https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/
#     - Garbage collection
#       https://kubernetes.io/docs/concepts/architecture/garbage-collection/
#     - Controllers and the reconciliation loop
#       https://kubernetes.io/docs/concepts/architecture/controller/
# =============================================================================

set -euo pipefail

readonly NS="cnpa-lab-11"
readonly APP="checkout-api"
readonly CM="checkout-api-config"
readonly ROGUE_MANAGER="legacy-autoscaler-v1"
readonly GITOPS_MANAGER="gitops"
readonly DANGLING_UID="deadbeef-0000-4000-8000-000000000000"

LAB_HOME="${CNPA_LAB_HOME:-$HOME/cnpa-lab-1.1}"
LAB_IMAGE="${CNPA_LAB_IMAGE:-busybox:1.36}"
GITOPS_DIR="$LAB_HOME/gitops"
SEED_DIR="$LAB_HOME/.seed"

# --- presentation -----------------------------------------------------------

if [[ -t 1 ]]; then
  C_RST=$'\e[0m'; C_B=$'\e[1m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'
  C_YEL=$'\e[33m'; C_CYA=$'\e[36m'
else
  C_RST=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

hr()   { printf '%s\n' "-------------------------------------------------------------------------------"; }
say()  { printf '%s\n' "$*"; }
head1(){ hr; printf '%s%s%s\n' "$C_B" "$*" "$C_RST"; hr; }
info() { printf '%s[..]%s %s\n' "$C_CYA" "$C_RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
fail() { printf '%s[XX]%s %s\n' "$C_RED" "$C_RST" "$*"; }
die()  { fail "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- safety rails -----------------------------------------------------------

require_tools() {
  have kubectl || die "kubectl not found in PATH."
  have jq      || die "jq not found in PATH. Install it: 'sudo dnf install -y jq' or 'sudo apt-get install -y jq'."
  kubectl version -o json >/dev/null 2>&1 \
    || die "kubectl cannot reach an API server. Start your lab cluster first (kind create cluster / minikube start)."
}

assert_disposable_cluster() {
  local ctx node_count prod_hits

  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  case "$ctx" in
    kind-*|k3d-*|minikube|k3s*|default|docker-desktop|colima|rancher-desktop) ;;
    *)
      if [[ "${CNPA_LAB_FORCE:-0}" != "1" ]]; then
        die "Current kube-context is '$ctx', which does not look like a disposable lab cluster.
     This script creates and deletes objects. Point kubectl at a throwaway
     cluster, or re-run with CNPA_LAB_FORCE=1 if you are certain."
      fi
      warn "Context allowlist bypassed via CNPA_LAB_FORCE=1 (context: $ctx)."
      ;;
  esac

  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${CNPA_LAB_FORCE:-0}" != "1" && "${node_count:-0}" -gt 3 ]]; then
    die "Cluster has $node_count nodes; a disposable lab is expected to have 1-3. Refusing."
  fi

  prod_hits="$(kubectl get nodes -o json 2>/dev/null \
    | jq -r '[.items[].metadata.labels // {} | to_entries[]
              | select(.key|test("env|environment|stage";"i"))
              | select(.value|test("^(prod|production|prd)$";"i"))] | length')"
  if [[ "${prod_hits:-0}" -gt 0 && "${CNPA_LAB_FORCE:-0}" != "1" ]]; then
    die "At least one node is labelled as a production environment. Refusing to run."
  fi

  info "Context: $ctx | nodes: $node_count | blast radius: namespace/$NS + $LAB_HOME"
}

confirm() {
  [[ "${CNPA_LAB_YES:-0}" == "1" ]] && return 0
  local answer
  printf '%s' "Type 'break-it' to arm the lab: "
  read -r answer || true
  [[ "$answer" == "break-it" ]] || die "Aborted by the operator. Nothing was changed."
}

# --- source of truth (the simulated GitOps repository) ----------------------

write_gitops_repo() {
  mkdir -p "$GITOPS_DIR" "$SEED_DIR"

  cat >"$GITOPS_DIR/00-namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: cnpa-lab-11
  labels:
    app.kubernetes.io/part-of: payments-platform
    pod-security.kubernetes.io/enforce: baseline
YAML

  # NOTE: this file is written ALREADY BROKEN (Fault C). The dangling
  # ownerReference is committed in the source of truth, not injected live.
  cat >"$GITOPS_DIR/10-configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-api-config
  namespace: cnpa-lab-11
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/managed-by: gitops
  ownerReferences:
    - apiVersion: v1
      kind: ConfigMap
      name: platform-bootstrap-config
      uid: deadbeef-0000-4000-8000-000000000000
      controller: false
      blockOwnerDeletion: false
data:
  RELEASE_CHANNEL: "stable"
  FEATURE_CHECKOUT_V2: "false"
  UPSTREAM_TIMEOUT_MS: "2500"
YAML

  cat >"$GITOPS_DIR/20-deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: cnpa-lab-11
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/part-of: payments-platform
    app.kubernetes.io/managed-by: gitops
spec:
  replicas: 2
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/part-of: payments-platform
    spec:
      terminationGracePeriodSeconds: 5
      containers:
        - name: api
          image: busybox:1.36
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "checkout-api booting"
              env | sort | grep -E '^(RELEASE_CHANNEL|FEATURE_CHECKOUT_V2|UPSTREAM_TIMEOUT_MS)=' || true
              while true; do sleep 3600; done
          envFrom:
            - configMapRef:
                name: checkout-api-config
          resources:
            requests:
              cpu: "10m"
              memory: "16Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
YAML

  # The manifest a human actually used during last night's incident. It is NOT
  # in the GitOps repo; it lives in a chat thread. This is what makes Fault A
  # possible: the live object was born outside the source of truth.
  cat >"$SEED_DIR/incident-hotfix-deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: cnpa-lab-11
  annotations:
    deploy.corp/hotfix: "manual-2026-08-05-INC-4471"
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/part-of: payments-platform
    app.kubernetes.io/managed-by: human
spec:
  replicas: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/part-of: payments-platform
    spec:
      terminationGracePeriodSeconds: 5
      containers:
        - name: api
          image: busybox:1.36
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "checkout-api booting"
              while true; do sleep 3600; done
          env:
            - name: DEBUG_TRACE
              value: "1"
          envFrom:
            - configMapRef:
                name: checkout-api-config
YAML

  cat >"$SEED_DIR/rogue-autoscaler-patch.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: cnpa-lab-11
spec:
  replicas: 6
YAML

  if [[ "$LAB_IMAGE" != "busybox:1.36" ]]; then
    sed -i "s#image: busybox:1.36#image: ${LAB_IMAGE}#g" \
      "$GITOPS_DIR/20-deployment.yaml" "$SEED_DIR/incident-hotfix-deployment.yaml"
    info "Image overridden to $LAB_IMAGE"
  fi
}

# --- break ------------------------------------------------------------------

do_break() {
  require_tools
  assert_disposable_cluster
  head1 "CNPA 1.1 — Break & Fix : arming the lab"
  say "This will DELETE and recreate namespace/$NS and rewrite $LAB_HOME."
  confirm

  if kubectl get ns "$NS" >/dev/null 2>&1; then
    info "Removing the previous run of namespace/$NS ..."
    kubectl delete ns "$NS" --wait=true >/dev/null
  fi

  info "Writing the simulated GitOps repository to $GITOPS_DIR ..."
  write_gitops_repo

  info "Creating namespace/$NS declaratively ..."
  kubectl apply -f "$GITOPS_DIR/00-namespace.yaml" >/dev/null

  # ---- FAULT A ------------------------------------------------------------
  # `kubectl create -f` writes the object but does NOT store the
  # last-applied-configuration annotation (only `--save-config` or `apply`
  # would). From now on, client-side apply cannot compute a 3-way merge and
  # therefore cannot delete anything it never recorded as its own.
  info "FAULT A: creating deployment/$APP imperatively (no --save-config) ..."
  kubectl create -f "$SEED_DIR/incident-hotfix-deployment.yaml" >/dev/null

  # ---- FAULT B ------------------------------------------------------------
  # A decommissioned autoscaler still runs somewhere and force-applies its own
  # replica count. It becomes the registered Apply-owner of .spec.replicas.
  info "FAULT B: registering field manager '$ROGUE_MANAGER' as owner of .spec.replicas ..."
  kubectl apply --server-side --force-conflicts \
    --field-manager="$ROGUE_MANAGER" \
    -f "$SEED_DIR/rogue-autoscaler-patch.yaml" >/dev/null

  # ---- FAULT C ------------------------------------------------------------
  # The ConfigMap manifest in git carries an ownerReference to an object that
  # does not exist. The garbage collector resolves owners by (apiVersion, kind,
  # name) and compares UIDs; a miss means "my owner is gone, delete me".
  info "FAULT C: applying the ConfigMap exactly as it is committed in git ..."
  kubectl apply -f "$GITOPS_DIR/10-configmap.yaml" >/dev/null

  info "Waiting for the reconciliation loops to settle (~25s) ..."
  sleep 25

  head1 "THE INCIDENT"
  cat <<'BRIEF'
You are on call for the payments platform. The GitOps pipeline for
`checkout-api` has been red for 40 minutes and the service will not start.

The repository of record is:

    $CNPA_LAB_HOME/gitops/
        00-namespace.yaml
        10-configmap.yaml
        20-deployment.yaml

Nobody has told you what was done to the cluster by hand last night. That is
the point of the exercise: read the cluster, do not trust the story.

SYMPTOMS YOU WILL SEE
---------------------

1) Pods never become Ready.

     $ kubectl -n cnpa-lab-11 get pods
     NAME                            READY   STATUS                       RESTARTS   AGE
     checkout-api-6c9f7d5b8b-2xk4n   0/1     CreateContainerConfigError   0          45s
     ...
     $ kubectl -n cnpa-lab-11 describe pod -l app.kubernetes.io/name=checkout-api | tail -5
       Warning  Failed  ...  Error: configmap "checkout-api-config" not found

2) `kubectl apply` of the ConfigMap reports success, and the object disappears
   a few seconds later. No Event is emitted for the deletion.

     $ kubectl apply -f gitops/10-configmap.yaml
     configmap/checkout-api-config created
     $ sleep 15 && kubectl -n cnpa-lab-11 get cm checkout-api-config
     Error from server (NotFound): configmaps "checkout-api-config" not found

3) `kubectl apply` of the Deployment warns that the object was not created
   declaratively, and the fields you removed from git are still live:

     Warning: resource deployments/checkout-api is missing the
     kubectl.kubernetes.io/last-applied-configuration annotation which is
     required by kubectl apply. ... The missing annotation will be adopted
     automatically.

4) Switching the pipeline to Server-Side Apply fails outright:

     $ kubectl apply --server-side --field-manager=gitops -f gitops/20-deployment.yaml
     error: Apply failed with N conflicts: conflict with "legacy-autoscaler-v1":
       .spec.replicas
     conflict with "kubectl-create": .metadata.labels..., .spec.template...

WHAT YOU MUST ACHIEVE
---------------------
  [A] deployment/checkout-api contains NOTHING that the git manifest does not
      declare: no `deploy.corp/hotfix` annotation, no `DEBUG_TRACE` env var,
      and `app.kubernetes.io/managed-by` must read `gitops`, not `human`.
  [B] `.spec.replicas` is 2 AND is owned by the field manager `gitops`
      through an **Apply** operation (check `.metadata.managedFields`).
      No other manager may claim it.
  [C] configmap/checkout-api-config exists, still exists 20 seconds later,
      and carries RELEASE_CHANNEL=stable, FEATURE_CHECKOUT_V2=false.
      Fix the SOURCE OF TRUTH, not just the live object — a fix that a
      re-apply of git would undo does not count.
  [D] 2/2 replicas Ready.
  [E] Re-applying the whole repo is a no-op: `kubectl diff -f gitops/`
      exits 0.

USEFUL INVESTIGATION COMMANDS
-----------------------------
  kubectl -n cnpa-lab-11 get deploy checkout-api -o yaml --show-managed-fields
  kubectl -n cnpa-lab-11 get deploy checkout-api -o json | jq '.metadata.managedFields[] | {manager, operation}'
  kubectl -n cnpa-lab-11 get cm --watch
  kubectl -n cnpa-lab-11 get cm checkout-api-config -o jsonpath='{.metadata.ownerReferences}'
  kubectl -n cnpa-lab-11 describe pod -l app.kubernetes.io/name=checkout-api
  kubectl diff -f "$CNPA_LAB_HOME/gitops/"

Grade yourself with:   ./break_fix.sh verify
Stuck?                 ./break_fix.sh hint
BRIEF
  hr
  warn "Lab armed. Do not read the commented solution at the bottom of this file yet."
}

# --- status -----------------------------------------------------------------

do_status() {
  require_tools
  head1 "Current state of namespace/$NS"

  say "${C_B}Workloads${C_RST}"
  kubectl -n "$NS" get deploy,rs,pods,cm -o wide 2>/dev/null || warn "namespace/$NS not found — run './break_fix.sh break' first."
  say ""

  say "${C_B}Field ownership ledger (.metadata.managedFields)${C_RST}"
  kubectl -n "$NS" get deploy "$APP" -o json 2>/dev/null \
    | jq -r '.metadata.managedFields[]
             | "  manager=\(.manager)  operation=\(.operation)  subresource=\(.subresource // "-")"' \
    || warn "deployment/$APP not found."
  say ""

  say "${C_B}Owner of .spec.replicas${C_RST}"
  kubectl -n "$NS" get deploy "$APP" -o json 2>/dev/null \
    | jq -r '[.metadata.managedFields[]
              | select(.fieldsV1["f:spec"]["f:replicas"]? != null)
              | "  \(.manager) (\(.operation))"] | .[]' \
    || true
  say ""

  say "${C_B}ownerReferences committed in the source of truth${C_RST}"
  if grep -q 'ownerReferences' "$GITOPS_DIR/10-configmap.yaml" 2>/dev/null; then
    fail "  $GITOPS_DIR/10-configmap.yaml still declares ownerReferences"
  else
    ok "  $GITOPS_DIR/10-configmap.yaml declares no ownerReferences"
  fi
}

# --- hints ------------------------------------------------------------------

do_hint() {
  head1 "Progressive hints (each one gives away a little more)"
  cat <<'HINTS'
HINT 1 — Ask the right question first.
  "Why does apply not remove the field?" is the wrong question. The right one
  is "who does the API server think owns this field?" Every object carries a
  ledger: `kubectl get <obj> -o yaml --show-managed-fields`. Read it before
  typing another apply.

HINT 2 — Client-side apply is bookkeeping, not magic.
  `kubectl apply` computes a THREE-way merge: (last-applied-configuration in
  the annotation) vs (your manifest) vs (live object). A field is deleted only
  when it is present in last-applied and absent from your manifest. An object
  created with `kubectl create -f` has no last-applied at all, so the "delete"
  side of the merge is empty. Corollary that surprises everyone: even after
  the annotation is adopted, fields that were never in it are never removed by
  apply. Somebody has to remove them explicitly — or the object has to be
  recreated from the source of truth.

HINT 3 — Server-Side Apply moves the ledger into the API server.
  With `--server-side` the annotation is replaced by per-field ownership in
  `.metadata.managedFields`. A conflict is not an error to route around; it is
  the API server telling you that two systems believe they own the same field.
  You have exactly three legitimate answers: take ownership (`--force-conflicts`),
  give it up (remove the field from your manifest, which is the correct answer
  when an HPA owns `.spec.replicas`), or co-own it. Picking one is a design
  decision, not a flag.

HINT 4 — Objects can be deleted by something that is not you.
  The garbage collector walks `.metadata.ownerReferences`, looks the owner up
  by apiVersion/kind/name and compares the UID. Owner missing, or UID mismatch
  => the dependent is deleted. No Event, no log line in your terminal, no
  warning at apply time (the reference is syntactically valid). If an object
  vanishes seconds after every create, look at its ownerReferences, then ask
  where that ownerReference came from.

HINT 5 — Fix the input, not the output.
  Anything you repair only in the cluster will be reverted by the next
  reconcile. Grep the repository before you patch the API.
HINTS
}

# --- verify -----------------------------------------------------------------

PASS=0; FAILED=0
check_ok()   { ok   "$1"; PASS=$((PASS+1)); }
check_bad()  { fail "$1"; FAILED=$((FAILED+1)); }

do_verify() {
  require_tools
  head1 "Grading CNPA 1.1 Break & Fix"

  kubectl get ns "$NS" >/dev/null 2>&1 || die "namespace/$NS does not exist. Run './break_fix.sh break' first."

  # ---- A: the live object contains nothing git does not declare ------------
  local hotfix envs managed_by
  hotfix="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.metadata.annotations.deploy\.corp/hotfix}' 2>/dev/null || true)"
  if [[ -z "$hotfix" ]]; then
    check_ok "A1 — orphan annotation 'deploy.corp/hotfix' is gone"
  else
    check_bad "A1 — orphan annotation still live: deploy.corp/hotfix=$hotfix"
  fi

  envs="$(kubectl -n "$NS" get deploy "$APP" -o json 2>/dev/null \
          | jq -r '[.spec.template.spec.containers[]?.env[]?.name] | join(",")')"
  if [[ "$envs" != *"DEBUG_TRACE"* ]]; then
    check_ok "A2 — orphan env var 'DEBUG_TRACE' is gone"
  else
    check_bad "A2 — orphan env var still live (container env: ${envs:-<none>})"
  fi

  managed_by="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  if [[ "$managed_by" == "gitops" ]]; then
    check_ok "A3 — app.kubernetes.io/managed-by=gitops"
  else
    check_bad "A3 — app.kubernetes.io/managed-by='${managed_by:-<unset>}' (expected 'gitops')"
  fi

  # ---- B: replicas value and single Apply-owner ---------------------------
  local replicas owners
  replicas="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  if [[ "$replicas" == "2" ]]; then
    check_ok "B1 — .spec.replicas == 2 (matches the manifest)"
  else
    check_bad "B1 — .spec.replicas == ${replicas:-<none>} (expected 2)"
  fi

  owners="$(kubectl -n "$NS" get deploy "$APP" -o json 2>/dev/null \
    | jq -r '[.metadata.managedFields[]
              | select(.operation == "Apply")
              | select(.fieldsV1["f:spec"]["f:replicas"]? != null)
              | .manager] | unique | join(",")')"
  if [[ "$owners" == "$GITOPS_MANAGER" ]]; then
    check_ok "B2 — .spec.replicas owned by field manager '$GITOPS_MANAGER' (Apply)"
  else
    check_bad "B2 — Apply-owner of .spec.replicas is '${owners:-<none>}' (expected exactly '$GITOPS_MANAGER')"
  fi

  # ---- C: the source of truth is repaired, and the object survives ---------
  if grep -q 'ownerReferences' "$GITOPS_DIR/10-configmap.yaml" 2>/dev/null; then
    check_bad "C1 — $GITOPS_DIR/10-configmap.yaml still declares ownerReferences (the source of truth is still wrong)"
  else
    check_ok "C1 — the committed ConfigMap manifest no longer declares ownerReferences"
  fi

  if kubectl -n "$NS" get cm "$CM" >/dev/null 2>&1; then
    info "C2 — configmap/$CM exists; re-checking in 20s to rule out a garbage-collection race ..."
    sleep 20
    if kubectl -n "$NS" get cm "$CM" >/dev/null 2>&1; then
      check_ok "C2 — configmap/$CM survived the garbage collector"
    else
      check_bad "C2 — configmap/$CM was deleted again; a dangling ownerReference is still live"
    fi
  else
    check_bad "C2 — configmap/$CM does not exist"
  fi

  local chan flag
  chan="$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.RELEASE_CHANNEL}'    2>/dev/null || true)"
  flag="$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.FEATURE_CHECKOUT_V2}' 2>/dev/null || true)"
  if [[ "$chan" == "stable" && "$flag" == "false" ]]; then
    check_ok "C3 — ConfigMap data matches the manifest (RELEASE_CHANNEL=stable, FEATURE_CHECKOUT_V2=false)"
  else
    check_bad "C3 — ConfigMap data drifted (RELEASE_CHANNEL='${chan:-<none>}', FEATURE_CHECKOUT_V2='${flag:-<none>}')"
  fi

  # ---- D: the workload actually converged ---------------------------------
  local ready
  ready="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${ready:-0}" == "2" ]]; then
    check_ok "D  — 2/2 replicas Ready"
  else
    check_bad "D  — readyReplicas=${ready:-0} (expected 2); give the rollout a few more seconds and re-run verify"
  fi

  # ---- E: convergence / idempotency (informational) -----------------------
  if kubectl diff -f "$GITOPS_DIR/" >/dev/null 2>&1; then
    ok "E  — bonus: 'kubectl diff -f gitops/' is clean; live state == desired state"
  else
    warn "E  — bonus: 'kubectl diff -f gitops/' still reports drift. Inspect it; server-side defaulting can produce benign noise, but real drift means you are not converged."
  fi

  hr
  if [[ "$FAILED" -eq 0 ]]; then
    printf '%sPASSED%s  %d/%d checks. The cluster is now a projection of the repository.\n' \
      "$C_GRN$C_B" "$C_RST" "$PASS" "$((PASS+FAILED))"
    say "Read the commented solution at the bottom of this script to compare reasoning."
    return 0
  fi
  printf '%sNOT YET%s  %d passed, %d failed.\n' "$C_RED$C_B" "$C_RST" "$PASS" "$FAILED"
  say "Run './break_fix.sh hint' for a nudge, or './break_fix.sh status' to re-read the ledger."
  return 1
}

# --- cleanup ----------------------------------------------------------------

do_cleanup() {
  require_tools
  head1 "Cleaning up"
  kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null && ok "namespace/$NS removed"
  if [[ -n "$LAB_HOME" && "$LAB_HOME" == *"cnpa-lab-1.1"* && -d "$LAB_HOME" ]]; then
    rm -rf -- "$LAB_HOME"
    ok "working directory $LAB_HOME removed"
  else
    warn "Refusing to delete '$LAB_HOME' automatically (unexpected path). Remove it by hand if you want."
  fi
}

# --- entrypoint -------------------------------------------------------------

case "${1:-break}" in
  break)   do_break   ;;
  status)  do_status  ;;
  hint)    do_hint    ;;
  verify)  do_verify  ;;
  cleanup) do_cleanup ;;
  -h|--help|help)
    sed -n '1,45p' "$0"
    ;;
  *) die "Unknown subcommand '$1'. Use: break | status | hint | verify | cleanup" ;;
esac


# =============================================================================
# =========================  SOLUTION — STOP READING  =========================
# =============================================================================
#
# Everything below is the worked solution with the output you should expect at
# each step. Do not read it before you have driven `verify` yourself at least
# once. Commands are shown for namespace cnpa-lab-11 with the repository at
# $CNPA_LAB_HOME/gitops (default ~/cnpa-lab-1.1/gitops).
#
# -----------------------------------------------------------------------------
# STEP 0 — Read the cluster before you change it
# -----------------------------------------------------------------------------
#
#   $ kubectl -n cnpa-lab-11 get deploy,pods,cm
#   NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
#   deployment.apps/checkout-api   0/6     6            0           2m
#
#   NAME                                READY   STATUS                       RESTARTS   AGE
#   pod/checkout-api-77b4c8c9c5-4hnzq   0/1     CreateContainerConfigError   0          2m
#   ... (6 pods, all identical)
#
#   No ConfigMap is listed. Three independent facts already contradict git:
#   six replicas instead of two, zero Ready, and a missing ConfigMap.
#
#   $ kubectl -n cnpa-lab-11 describe pod -l app.kubernetes.io/name=checkout-api | tail -4
#     Warning  Failed     kubelet  Error: configmap "checkout-api-config" not found
#
#   The pods are a SYMPTOM. `envFrom.configMapRef` is a hard dependency: the
#   kubelet refuses to create the container until the ConfigMap resolves. Fix
#   the ConfigMap and the pods heal themselves — there is nothing wrong with
#   the Deployment's runtime.
#
# -----------------------------------------------------------------------------
# STEP 1 — FAULT C: why does the ConfigMap keep disappearing?
# -----------------------------------------------------------------------------
#
#   Watch it die. In one terminal:
#
#     $ kubectl -n cnpa-lab-11 get cm --watch
#
#   In another:
#
#     $ kubectl apply -f ~/cnpa-lab-1.1/gitops/10-configmap.yaml
#     configmap/checkout-api-config created
#
#   The watcher shows the object appear and then, within a few seconds:
#
#     checkout-api-config   3      6s
#     checkout-api-config   3      11s        <- DELETED
#
#   Nothing in the event stream explains it:
#
#     $ kubectl -n cnpa-lab-11 get events --sort-by=.lastTimestamp | grep -i configmap
#     (no output)
#
#   Garbage collection does not emit Events on the dependent. The evidence is
#   on the object itself — you have to be fast, or ask for it at create time:
#
#     $ kubectl apply -f ~/cnpa-lab-1.1/gitops/10-configmap.yaml -o json \
#         | jq '.metadata.ownerReferences'
#     [
#       {
#         "apiVersion": "v1",
#         "kind": "ConfigMap",
#         "name": "platform-bootstrap-config",
#         "uid": "deadbeef-0000-4000-8000-000000000000",
#         "controller": false,
#         "blockOwnerDeletion": false
#       }
#     ]
#
#     $ kubectl -n cnpa-lab-11 get cm platform-bootstrap-config
#     Error from server (NotFound): configmaps "platform-bootstrap-config" not found
#
#   That is the whole mechanism. The garbage collector resolves each
#   ownerReference by apiVersion/kind/name and compares the stored UID against
#   the live one. Owner absent (or UID mismatch, which is why deleting and
#   recreating an owner orphans its old dependents) => the dependent is
#   deleted. `blockOwnerDeletion: false` and `controller: false` change
#   nothing here; they govern foreground deletion and controller adoption, not
#   whether the sweep happens.
#
#   The decisive question is WHERE the ownerReference came from. It is not a
#   live-only mutation:
#
#     $ grep -n -A6 ownerReferences ~/cnpa-lab-1.1/gitops/10-configmap.yaml
#     8:  ownerReferences:
#     9:    - apiVersion: v1
#     ...
#
#   The bad desired state is committed. This is the classic way it happens in
#   real platforms: somebody ran `kubectl get -o yaml` on an operator-generated
#   object, pasted the result into the repo, and shipped the operator's
#   ownership metadata along with it. Patching the cluster would be undone by
#   the very next reconcile.
#
#   FIX — repair the source of truth, then re-apply:
#
#     $ cd ~/cnpa-lab-1.1
#     $ python3 - <<'PY'
#     import re, pathlib
#     p = pathlib.Path("gitops/10-configmap.yaml")
#     s = p.read_text()
#     s = re.sub(r"\n  ownerReferences:\n(?:    .*\n| *- .*\n)+", "\n", s)
#     p.write_text(s)
#     PY
#
#   (or simply delete the ownerReferences block with your editor — the point is
#   that the file, not the API object, is what must change.)
#
#     $ grep -c ownerReferences gitops/10-configmap.yaml
#     0
#     $ kubectl apply --server-side --field-manager=gitops -f gitops/10-configmap.yaml
#     configmap/checkout-api-config serverside-applied
#     $ sleep 20 && kubectl -n cnpa-lab-11 get cm checkout-api-config
#     NAME                  DATA   AGE
#     checkout-api-config   3      20s
#
#   It survives, because the recreated object carries no ownerReferences at all.
#   Note the trap: if a stale copy WITH the ownerReference were still live,
#   applying a manifest without it would not remove it — ownerReferences is an
#   atomic list owned by whoever set it. In that situation you strip it
#   explicitly:
#
#     $ kubectl -n cnpa-lab-11 patch cm checkout-api-config --type=json \
#         -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'
#
# -----------------------------------------------------------------------------
# STEP 2 — FAULT A: why does apply not remove what git removed?
# -----------------------------------------------------------------------------
#
#     $ kubectl apply -f ~/cnpa-lab-1.1/gitops/20-deployment.yaml
#     Warning: resource deployments/checkout-api is missing the
#     kubectl.kubernetes.io/last-applied-configuration annotation which is
#     required by kubectl apply. kubectl apply should only be used on resources
#     created declaratively by either kubectl create --save-config or kubectl
#     apply. The missing annotation will be adopted automatically.
#     deployment.apps/checkout-api configured
#
#     $ kubectl -n cnpa-lab-11 get deploy checkout-api \
#         -o jsonpath='{.metadata.annotations.deploy\.corp/hotfix}{"\n"}'
#     manual-2026-08-05-INC-4471                       <- still there
#
#     $ kubectl -n cnpa-lab-11 get deploy checkout-api -o json \
#         | jq -r '.spec.template.spec.containers[].env'
#     [ { "name": "DEBUG_TRACE", "value": "1" } ]      <- still there
#
#   Mechanism. Client-side apply performs a three-way merge over
#   (last-applied-configuration, your manifest, live object). A field is
#   DELETED only when it appears in last-applied and not in your manifest.
#   `kubectl create -f` never wrote a last-applied annotation, so the deletion
#   set was empty, and it stays empty for these two fields even after the
#   annotation is adopted — because the adopted annotation is built from the
#   manifest you just applied, which never mentioned them.
#
#   Read the ownership ledger to see who is actually holding them:
#
#     $ kubectl -n cnpa-lab-11 get deploy checkout-api -o json \
#         | jq -r '.metadata.managedFields[] | "\(.manager)\t\(.operation)"'
#     kubectl-create               Update
#     legacy-autoscaler-v1         Apply
#     kubectl-client-side-apply    Update
#     kube-controller-manager      Update      (subresource: status)
#
#   `kubectl-create` still owns the annotation and the env list. Server-Side
#   Apply will NOT remove them either: SSA removes only fields that the
#   applying manager itself previously owned and has now dropped. Fields owned
#   exclusively by another manager and absent from your config are left alone.
#   This is the single most misunderstood property of declarative management,
#   and it is worth stating flatly:
#
#       apply converges the fields you declare. It does not delete
#       state that no manifest has ever claimed.
#
#   That leaves two legitimate remediations.
#
#   (a) THE CATTLE ANSWER — recreate the object from the source of truth.
#       Correct here: the object was never declaratively owned, and this also
#       clears the rogue manager from Fault B in one move.
#
#         $ kubectl -n cnpa-lab-11 delete deployment checkout-api --wait=true
#         deployment.apps "checkout-api" deleted
#         $ kubectl apply --server-side --field-manager=gitops -f ~/cnpa-lab-1.1/gitops/
#         namespace/cnpa-lab-11 serverside-applied
#         configmap/checkout-api-config serverside-applied
#         deployment.apps/checkout-api serverside-applied
#
#       Note what this costs: full downtime for that Deployment. Acceptable for
#       a stateless service behind a queue or during a maintenance window,
#       unacceptable for a singleton with a PVC. Decide before you type it.
#
#   (b) THE IN-PLACE ANSWER — when deleting is not allowed. Take ownership of
#       the declared fields, then explicitly evict the two orphans:
#
#         $ kubectl apply --server-side --force-conflicts \
#             --field-manager=gitops -f ~/cnpa-lab-1.1/gitops/20-deployment.yaml
#         deployment.apps/checkout-api serverside-applied
#         $ kubectl -n cnpa-lab-11 annotate deployment checkout-api deploy.corp/hotfix-
#         deployment.apps/checkout-api annotated
#         $ kubectl -n cnpa-lab-11 set env deployment/checkout-api DEBUG_TRACE-
#         deployment.apps/checkout-api env updated
#
#       Both paths satisfy `verify`. Path (b) is the one you will actually use
#       on a live payments service.
#
#   Side lesson worth internalising: `spec.selector` is immutable. Had the
#   hotfix manifest used a different selector, neither path (b) nor any apply
#   would have worked — the API server would answer
#     `Deployment.apps "checkout-api" is invalid: spec.selector: Invalid
#      value: ...: field is immutable`
#   and delete-and-recreate would be the ONLY option. Immutable fields are the
#   hard boundary of declarative management.
#
# -----------------------------------------------------------------------------
# STEP 3 — FAULT B: two managers, one field
# -----------------------------------------------------------------------------
#
#   If you took path (b), your first SSA attempt without --force-conflicts
#   looked like this:
#
#     $ kubectl apply --server-side --field-manager=gitops -f gitops/20-deployment.yaml
#     error: Apply failed with 5 conflicts:
#     conflict with "legacy-autoscaler-v1": .spec.replicas
#     conflict with "kubectl-create":
#       - .metadata.labels.app.kubernetes.io/managed-by
#       - .spec.template.spec.containers[name="api"].args
#       ...
#     Please review the fields above--they currently have other managers. Here
#     are the ways you can resolve this warning:
#     * If you intend to manage all of these fields, please re-run the apply
#       command with the `--force-conflicts` flag.
#     * If you do not intend to manage all of the fields, please edit your
#       manifest to remove references to the fields that should keep their
#       current managers.
#
#   The error is a design question, not an obstacle. Three valid answers:
#
#     1. TAKE the field. Correct when git is genuinely the owner:
#          kubectl apply --server-side --force-conflicts --field-manager=gitops -f ...
#        `.spec.replicas` moves to `gitops` and `legacy-autoscaler-v1` loses it.
#
#     2. GIVE UP the field. Correct when a live controller owns it — and this
#        is exactly the production pattern for HorizontalPodAutoscaler: delete
#        `replicas:` from the manifest so the HPA owns it and your pipeline
#        stops fighting the autoscaler every sync. If you leave `replicas` in
#        git alongside an HPA you get a permanent flap: apply sets 2, HPA sets
#        6, apply sets 2. (This lab's grader requires answer 1, because
#        `legacy-autoscaler-v1` is decommissioned — it is not a real owner,
#        it is a ghost. Identify the owner before you yield to it.)
#
#     3. CO-OWN the field, by having both managers apply an identical value.
#        Rarely what you want; it hides disagreement instead of resolving it.
#
#   Confirm the ledger afterwards:
#
#     $ kubectl -n cnpa-lab-11 get deploy checkout-api -o json | jq -r '
#         .metadata.managedFields[]
#         | select(.fieldsV1["f:spec"]["f:replicas"]? != null)
#         | "\(.manager) \(.operation)"'
#     gitops Apply
#
#   One line, one owner, Apply operation. That is the goal state.
#
#   Housekeeping: a manager that owns no fields is dropped automatically. If a
#   stale entry lingers you can clear it explicitly by applying an empty
#   configuration under that manager name, or by moving to answer 1 as above.
#
# -----------------------------------------------------------------------------
# STEP 4 — Converge and confirm
# -----------------------------------------------------------------------------
#
#     $ kubectl -n cnpa-lab-11 rollout restart deployment/checkout-api
#     deployment.apps/checkout-api restarted
#     $ kubectl -n cnpa-lab-11 rollout status deployment/checkout-api --timeout=120s
#     deployment "checkout-api" successfully rolled out
#
#   (The restart is a convenience, not a requirement: pods stuck in
#   CreateContainerConfigError retry with exponential backoff and recover on
#   their own once the ConfigMap exists. Restarting just skips the backoff.
#   Remember, though, that `envFrom` is evaluated once at container start — a
#   later ConfigMap edit does NOT reach a running container. Volume-mounted
#   ConfigMaps do update in place, with kubelet sync latency.)
#
#     $ kubectl -n cnpa-lab-11 get pods
#     NAME                            READY   STATUS    RESTARTS   AGE
#     checkout-api-5f9c7b6d44-9lm2v   1/1     Running   0          25s
#     checkout-api-5f9c7b6d44-rr7qz   1/1     Running   0          22s
#
#     $ kubectl -n cnpa-lab-11 logs -l app.kubernetes.io/name=checkout-api --tail=5 | sort -u
#     FEATURE_CHECKOUT_V2=false
#     RELEASE_CHANNEL=stable
#     UPSTREAM_TIMEOUT_MS=2500
#     checkout-api booting
#
#   The last and most important check — idempotency. A declarative system is
#   only healthy when re-applying is a no-op:
#
#     $ kubectl diff -f ~/cnpa-lab-1.1/gitops/ ; echo "exit=$?"
#     exit=0
#
#     $ ./break_fix.sh verify
#     [OK] A1 — orphan annotation 'deploy.corp/hotfix' is gone
#     [OK] A2 — orphan env var 'DEBUG_TRACE' is gone
#     [OK] A3 — app.kubernetes.io/managed-by=gitops
#     [OK] B1 — .spec.replicas == 2 (matches the manifest)
#     [OK] B2 — .spec.replicas owned by field manager 'gitops' (Apply)
#     [OK] C1 — the committed ConfigMap manifest no longer declares ownerReferences
#     [OK] C2 — configmap/checkout-api-config survived the garbage collector
#     [OK] C3 — ConfigMap data matches the manifest
#     [OK] D  — 2/2 replicas Ready
#     [OK] E  — bonus: 'kubectl diff -f gitops/' is clean
#     PASSED  10/10 checks.
#
# -----------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM AND INTO PRODUCTION
# -----------------------------------------------------------------------------
#   * Imperative and declarative are not styles, they are different contracts.
#     `create`/`edit`/`scale`/`patch` state a transition; `apply` states an
#     invariant. Mixing them without `--save-config` breaks the invariant's
#     bookkeeping permanently.
#   * Client-side apply keeps its ledger in an annotation and can only delete
#     what that annotation recorded. Server-Side Apply keeps a per-field ledger
#     in `.metadata.managedFields` inside the API server, which is why it can
#     report conflicts, survive `kubectl` version drift, and be used safely by
#     controllers. New platforms should default to
#     `--server-side --field-manager=<pipeline-name>`.
#   * A conflict is information. Resolve it by deciding the owner: force, or
#     drop the field from git. Never by looping.
#   * Deletion is a controller behaviour too. `ownerReferences` make the
#     garbage collector a reconciliation loop that can remove your objects
#     without an Event, without a log, and without any error from apply.
#     Never copy an operator's metadata into a hand-maintained manifest.
#   * Drift can live in the repository. When the cluster disagrees with git,
#     confirm which one is actually wrong before you reconcile toward either.
#   * Idempotency is the acceptance test. `kubectl diff` exiting 0 after a full
#     apply is the only evidence that the cluster is a projection of the repo.
#
#   Tear the lab down with:  ./break_fix.sh cleanup
# =============================================================================