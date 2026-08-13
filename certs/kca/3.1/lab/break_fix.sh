#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Domain 3: Kubernetes Fundamentals
#  Topic 3.1  "apply"  (exam weight 3.0)
#  Break & Fix lab — the three-way merge trap of `kubectl apply`
# ----------------------------------------------------------------------------
#  What this lab teaches
#  ---------------------
#  `kubectl apply` is declarative: you keep a manifest, and Kubernetes
#  reconciles the live object toward it. To decide which fields to ADD, CHANGE
#  and — the hard part — DELETE, apply performs a THREE-WAY MERGE between:
#
#     (1) last-applied  : the manifest you applied last time, stored in the
#                         annotation  kubectl.kubernetes.io/last-applied-configuration
#     (2) modified      : the manifest you are applying now (the file on disk)
#     (3) live          : the object currently in etcd
#
#  Deletions are computed as: "keys present in (1) but absent in (2)".
#  If the object was NOT born from `apply` (e.g. it was created with
#  `kubectl create`, `kubectl run`, or a Helm/operator install), annotation (1)
#  DOES NOT EXIST. With no record of what it previously owned, apply cannot
#  know that a field you just deleted from your file used to be yours — so it
#  silently LEAVES IT IN PLACE. Your YAML says one thing, the cluster says
#  another, and no error is ever printed.
#
#  This is one of the most common real-world "why won't my change take?"
#  incidents. The lab reproduces it deterministically and asks you to fix it.
#
#  Official sources
#  ----------------
#  - Declarative Management of Kubernetes Objects Using Configuration Files
#    https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
#  - kubectl apply set-last-applied
#    https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/kubectl_apply_set-last-applied/
#  - Server-Side Apply (the modern successor that fixes this class of bug)
#    https://kubernetes.io/docs/reference/using-api/server-side-apply/
#  - KCA Curriculum
#    https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#
#  SAFETY: everything happens inside a dedicated throwaway namespace
#  (kca-apply-lab). Nothing outside it is touched. Run only on a DISPOSABLE
#  lab cluster (kind / minikube / k3s in a VM you can delete).
#
#  Usage:
#     ./break_apply.sh          # arm the break
#     ./break_apply.sh cleanup  # remove the namespace and all lab objects
# ============================================================================

set -euo pipefail

NS="kca-apply-lab"
DEP="web"
WORKDIR="$(mktemp -d /tmp/kca-apply-lab.XXXXXX)"
V1="${WORKDIR}/web-v1.yaml"   # original manifest, has the label 'tier: frontend'
V2="${WORKDIR}/web-v2.yaml"   # your edited manifest, 'tier' removed on purpose

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# 0. Preconditions and cleanup path
# ----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster. Point KUBECONFIG at your lab cluster."

if [[ "${1:-}" == "cleanup" ]]; then
  log "Removing lab namespace '${NS}'..."
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
  rm -rf /tmp/kca-apply-lab.* 2>/dev/null || true
  echo "Done."
  exit 0
fi

CTX="$(kubectl config current-context 2>/dev/null || echo '<unknown>')"
warn "This will create/modify namespace '${NS}' on context: ${CTX}"
warn "Only run this on a DISPOSABLE lab cluster."
if [[ "${KCA_LAB_CONFIRM:-}" != "yes" ]]; then
  read -r -p "Type 'yes' to continue: " REPLY </dev/tty || die "No TTY; re-run with KCA_LAB_CONFIRM=yes"
  [[ "${REPLY}" == "yes" ]] || die "Aborted by user."
fi

# ----------------------------------------------------------------------------
# 1. Write the two manifests
# ----------------------------------------------------------------------------
log "Writing lab manifests to ${WORKDIR}"

cat >"${V1}" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: kca-apply-lab
  labels:
    app: web
    tier: frontend        # <-- the field that will get "stuck" in the cluster
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
YAML

cat >"${V2}" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: kca-apply-lab
  labels:
    app: web
    # tier: frontend  <-- DELETED on purpose. This is the change you want live.
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
YAML

# ----------------------------------------------------------------------------
# 2. THE BREAK — create the object IMPERATIVELY (no apply, no --save-config)
#    so it is born WITHOUT the last-applied-configuration annotation.
# ----------------------------------------------------------------------------
log "Arming the break: creating the Deployment with 'kubectl create' (NOT apply)"
kubectl create namespace "${NS}" >/dev/null 2>&1 || true
# Reset any previous run so the scenario is deterministic.
kubectl delete deployment "${DEP}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
kubectl create -f "${V1}"
kubectl rollout status deployment/"${DEP}" -n "${NS}" --timeout=90s || true

# ----------------------------------------------------------------------------
# 3. Brief the student
# ----------------------------------------------------------------------------
cat <<EOF

############################################################################
#  SCENARIO
############################################################################
A Deployment '${DEP}' already exists in namespace '${NS}'. It carries the
label  tier=frontend. A previous operator created it with 'kubectl create'
(a very common real-world starting point: Helm, an operator, or a colleague
running an imperative command).

Your task list said: "remove the tier=frontend label, declaratively."
So you edited the manifest to drop that label (file: ${V2}) and you are
about to manage it the right way, with 'kubectl apply'.

############################################################################
#  REPRODUCE THE SYMPTOM (run these yourself)
############################################################################
  kubectl apply -f ${V2}
  kubectl get deployment ${DEP} -n ${NS} --show-labels

  Expected by you : the 'tier=frontend' label is GONE.
  What you get     : 'tier=frontend' is STILL THERE. No error. No warning.
                     apply reports "configured", yet nothing was removed.

Run 'apply' a second, a third time — the label never leaves. The file and
the cluster disagree, permanently, and apply stays silent about it.

############################################################################
#  YOUR GOAL
############################################################################
  1. Explain WHY 'kubectl apply -f ${V2}' refuses to delete the label.
  2. Make the live Deployment '${DEP}' lose the 'tier' label WHILE keeping
     it manageable by future 'kubectl apply' runs (i.e. leave it in a state
     where a later declarative deletion WOULD work).
  Verify success with:
     kubectl get deployment ${DEP} -n ${NS} --show-labels
     # -> the 'tier' label must be absent

Files:  original = ${V1}
        edited   = ${V2}
Reset / clean up:  $0 cleanup
############################################################################

EOF

# ============================================================================
#  ██  SOLUTION — read only after you have tried  ██
# ============================================================================
#
#  --- STEP 1. Diagnose: confirm the object has no apply history ------------
#
#    kubectl get deployment web -n kca-apply-lab \
#      -o "jsonpath={.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}"; echo
#
#    Output: (empty line)
#
#    Compare with a field the object DOES have:
#    kubectl get deployment web -n kca-apply-lab --show-labels
#    NAME   READY   ...   LABELS
#    web    2/2     ...   app=web,tier=frontend
#
#    The annotation is empty because the object was created with `create`,
#    not `apply` and not `create --save-config`. Without it, apply's
#    three-way merge has no "last-applied" set to diff against, so its
#    DELETE set (keys in last-applied but not in your file) is empty — it can
#    only ADD/UPDATE the fields your file names; it will never remove a field.
#    Worse: your first naive `apply -f web-v2.yaml` wrote last-applied = v2
#    (which already lacks 'tier'), so 'tier' is now invisible to every future
#    diff and stuck forever.
#
#  --- STEP 2. Fix (canonical, keeps it declarative) ------------------------
#
#    Seed the annotation from the ORIGINAL manifest (the one that still HAS
#    'tier'), so the next apply has something to diff the deletion against:
#
#      kubectl apply set-last-applied --create-annotation -f web-v1.yaml \
#        -n kca-apply-lab
#
#    Now apply the edited manifest. The three-way merge finally sees
#    'tier' in last-applied but not in your file -> it emits a delete:
#
#      kubectl apply -f web-v2.yaml -n kca-apply-lab
#      kubectl get deployment web -n kca-apply-lab --show-labels
#      # LABELS: app=web        <- 'tier' is gone. Fixed.
#
#    From here on the object carries a correct last-applied annotation, so
#    ordinary `kubectl apply` deletions behave as expected.
#
#  --- Alternative fixes (know the trade-offs) ------------------------------
#
#    a) Server-Side Apply — the modern, recommended cure for this whole bug
#       class. It tracks field ownership in .metadata.managedFields on the
#       server instead of the fragile client-side annotation:
#
#         kubectl apply --server-side --field-manager=me \
#           -f web-v2.yaml -n kca-apply-lab
#
#       Because your field-manager no longer lists 'tier', SSA removes it.
#       (If another manager owns a field you also set, SSA reports a conflict;
#        resolve intentionally with --force-conflicts, never blindly.)
#
#    b) Imperative full replace — removes the label immediately but does NOT
#       create a last-applied annotation, so you are back to square one for
#       the NEXT declarative change. Use only as a one-off:
#
#         kubectl replace -f web-v2.yaml -n kca-apply-lab
#
#    c) Imperative label delete — fast, surgical, but not declarative:
#
#         kubectl label deployment web tier- -n kca-apply-lab
#
#  --- The lesson -----------------------------------------------------------
#    Pick ONE management style per object and keep it. If an object will be
#    managed declaratively, create it declaratively:
#
#         kubectl apply -f web-v1.yaml        # right from birth
#      or kubectl create --save-config -f web-v1.yaml
#
#    Mixing an imperative `create` with a later declarative `apply` is what
#    produced this silent divergence. When adopting a pre-existing object
#    (Helm/operator-made) into GitOps, prefer Server-Side Apply, or seed the
#    annotation first with `apply set-last-applied --create-annotation`.
# ============================================================================