#!/usr/bin/env bash
#
# ==============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 5 "Writing Policies" · Topic 5.4 "Mutation Rules" (exam weight 2.91%)
#
#  BREAK & FIX LAB — kca-5.4-mutation-break-fix.sh
#
#  This script simulates a realistic incident on a DISPOSABLE lab cluster:
#  a platform team ships three Kyverno mutation policies, and every one of them
#  is subtly wrong in a way that is common in production. Your job is to
#  diagnose the symptoms and repair the policies — not to delete them.
#
#  Faults injected (do NOT read further if you want the full experience):
#    A. strategic-merge patch semantics: list merge keys and the +() anchor
#    B. RFC 6902 JSON patch: "add" to an index of an array that does not exist
#    C. mutateExisting: background-controller RBAC + mutateExistingOnPolicyUpdate
#
#  Blast radius by construction:
#    * every policy is a NAMESPACED kyverno.io/v1 Policy, not a ClusterPolicy,
#      so even a mistyped match block cannot escape the lab namespace;
#    * every object created carries the label kca.lab/lab=5.4;
#    * nothing in kube-system, and nothing in the kyverno namespace is modified.
#
#  Reference: KCA curriculum — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#             Kyverno mutate rules — https://kyverno.io/docs/writing-policies/mutate/
#             Mutate existing     — https://kyverno.io/docs/writing-policies/mutate/#mutate-existing-resources
#             RBAC for background — https://kyverno.io/docs/installation/customization/#role-based-access-controls
#             JSON Patch RFC 6902 — https://datatracker.ietf.org/doc/html/rfc6902#section-4.1
#
#  Usage:
#     ./kca-5.4-mutation-break-fix.sh break      # preflight + baseline + inject faults + briefing
#     ./kca-5.4-mutation-break-fix.sh brief      # re-print the incident briefing
#     ./kca-5.4-mutation-break-fix.sh verify     # grade your fix (exit 0 only when all checks pass)
#     ./kca-5.4-mutation-break-fix.sh hint [1|2|3]
#     ./kca-5.4-mutation-break-fix.sh clean      # remove everything the lab created
#
#  Environment overrides:
#     LAB_NS=kca-mutation-lab  KYVERNO_NS=kyverno  LAB_DIR=$HOME/kca-5.4-mutation-lab
#     LAB_IMAGE=registry.k8s.io/pause:3.9  LAB_FORCE=1 (skip the interactive guard)
# ==============================================================================

set -Eeuo pipefail

readonly NS="${LAB_NS:-kca-mutation-lab}"
readonly KYVERNO_NS="${KYVERNO_NS:-kyverno}"
readonly LAB_DIR="${LAB_DIR:-$HOME/kca-5.4-mutation-lab}"
readonly IMAGE="${LAB_IMAGE:-registry.k8s.io/pause:3.9}"
readonly LAB_LABEL="kca.lab/lab=5.4"
readonly CRD_NAME="labwidgets.kca.lab"
readonly ROLE_NAME="kca54-labwidget-writer"
readonly POLICIES=(kca54-pod-defaults kca54-node-placement kca54-widget-annotations)

if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=''; GRN=''; YEL=''; CYA=''; BLD=''; RST=''
fi

hr()    { printf '%s\n' "------------------------------------------------------------------------------"; }
title() { printf '\n%s%s%s\n' "$BLD$CYA" "$*" "$RST"; hr; }
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  %s[ PASS ]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '  %s[ WARN ]%s %s\n' "$YEL" "$RST" "$*"; }
bad()   { printf '  %s[ FAIL ]%s %s\n' "$RED" "$RST" "$*"; }
die()   { printf '\n%s[ ABORT ]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }
indent(){ sed 's/^/      /'; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Read a field, never fail the script if the object is missing.
gf() { kubectl -n "$NS" get "$1" "$2" -o jsonpath="$3" 2>/dev/null || true; }

# Resolve a Kyverno deployment name across 1.9 (single pod) and 1.10+ (split controllers).
kyverno_deploy() {
  local role="$1" d
  d="$(kubectl -n "$KYVERNO_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -E "$role" | head -n1 || true)"
  [[ -n "$d" ]] || d="$(kubectl -n "$KYVERNO_NS" get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  printf '%s' "$d"
}

# ==============================================================================
#  PREFLIGHT — refuse to run anywhere that is not obviously a throwaway cluster
# ==============================================================================
preflight() {
  title "PREFLIGHT — is this really a disposable lab cluster?"
  need kubectl
  kubectl version -o yaml >/dev/null 2>&1 || die "kubectl cannot reach an API server."

  local ctx nodes
  ctx="$(kubectl config current-context)"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  info "context : $ctx"
  info "nodes   : $nodes"
  info "namespace to be used : $NS"

  if [[ "${LAB_FORCE:-0}" != "1" ]]; then
    if ! [[ "$ctx" =~ ^(kind-|k3d-|minikube|rancher-desktop|docker-desktop) || "$ctx" =~ (lab|sandbox|dev|test) ]]; then
      die "context '$ctx' does not look like a lab cluster.
         This script creates admission policies that reject Deployments on purpose.
         Re-run with LAB_FORCE=1 only if you are certain this cluster is disposable."
    fi
    if (( nodes > 3 )); then
      die "cluster has $nodes nodes — that is not a throwaway lab. Re-run with LAB_FORCE=1 if you disagree."
    fi
    printf '\n  %sType BREAK to inject the faults:%s ' "$BLD" "$RST"
    local answer; read -r answer
    [[ "$answer" == "BREAK" ]] || die "confirmation not given, nothing was changed."
  else
    warn "LAB_FORCE=1 — interactive guard skipped."
  fi

  # Do not hijack a pre-existing namespace we did not create.
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    if ! kubectl get ns "$NS" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q '"kca.lab/lab":"5.4"'; then
      die "namespace '$NS' already exists and was not created by this lab. Refusing to touch it."
    fi
    warn "namespace $NS already exists (previous run) — it will be reused."
  fi

  kubectl get ns "$KYVERNO_NS" >/dev/null 2>&1 \
    || die "Kyverno namespace '$KYVERNO_NS' not found. Install Kyverno first, e.g.
         kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
         kubectl -n kyverno wait --for=condition=Available deploy --all --timeout=300s"

  local adm bg img
  adm="$(kyverno_deploy 'admission|^kyverno$')"
  bg="$(kyverno_deploy 'background')"
  [[ -n "$adm" ]] || die "no Kyverno deployment found in namespace $KYVERNO_NS."
  img="$(kubectl -n "$KYVERNO_NS" get deploy "$adm" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  info "admission controller  : deploy/$adm  ($img)"
  if [[ -n "$bg" ]]; then
    info "background controller : deploy/$bg"
  else
    warn "no separate background controller (Kyverno < 1.10). Fault C still applies,
        but read the logs from deploy/$adm instead."
  fi
  kubectl -n "$KYVERNO_NS" wait --for=condition=Available deploy --all --timeout=180s >/dev/null \
    || warn "some Kyverno deployments are not Available yet; the lab may behave erratically."
  ok "preflight complete"
}

# ==============================================================================
#  BASELINE — a healthy, working namespace BEFORE anything is broken
# ==============================================================================
setup_baseline() {
  title "BASELINE — building a healthy namespace"
  mkdir -p "$LAB_DIR/policies" "$LAB_DIR/symptoms" "$LAB_DIR/manifests"

  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" "$LAB_LABEL" --overwrite >/dev/null

  # A CRD so that fault C is deterministic: Kyverno's background controller has
  # no permission on a brand-new custom resource, on any Kyverno version.
  cat >"$LAB_DIR/manifests/crd.yaml" <<YAML
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD_NAME}
  labels:
    kca.lab/lab: "5.4"
spec:
  group: kca.lab
  scope: Namespaced
  names:
    kind: LabWidget
    listKind: LabWidgetList
    plural: labwidgets
    singular: labwidget
    shortNames: ["lw"]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                tier:
                  type: string
      additionalPrinterColumns:
        - name: Tier
          type: string
          jsonPath: .spec.tier
        - name: ManagedBy
          type: string
          jsonPath: .metadata.annotations.kca\\.lab/managed-by
YAML
  kubectl apply -f "$LAB_DIR/manifests/crd.yaml" >/dev/null
  kubectl wait --for=condition=Established "crd/${CRD_NAME}" --timeout=60s >/dev/null
  ok "CRD ${CRD_NAME} established"

  cat >"$LAB_DIR/manifests/baseline.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: mutation-trigger
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
data:
  revision: "1"
---
apiVersion: kca.lab/v1alpha1
kind: LabWidget
metadata:
  name: widget-one
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
spec:
  tier: gold
---
apiVersion: kca.lab/v1alpha1
kind: LabWidget
metadata:
  name: widget-two
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
spec:
  tier: silver
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-alpha
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-alpha
  template:
    metadata:
      labels:
        app: app-alpha
        kca.lab/tier: gold
    spec:
      containers:
        - name: web
          image: ${IMAGE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-beta
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-beta
  template:
    metadata:
      labels:
        app: app-beta
    spec:
      tolerations:
        - key: node-role.kubernetes.io/lab
          operator: Exists
          effect: NoSchedule
      containers:
        - name: web
          image: ${IMAGE}
YAML
  kubectl apply -f "$LAB_DIR/manifests/baseline.yaml" >/dev/null
  kubectl -n "$NS" rollout status deploy/app-alpha --timeout=180s >/dev/null
  kubectl -n "$NS" rollout status deploy/app-beta  --timeout=180s >/dev/null
  ok "app-alpha and app-beta are running, widgets and trigger ConfigMap created"

  # RBAC that "the platform team already wrote" for the mutate-existing rule.
  # It is complete — except for the one thing that makes Kyverno pick it up.
  cat >"$LAB_DIR/manifests/rbac.yaml" <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${ROLE_NAME}
  labels:
    kca.lab/lab: "5.4"
rules:
  - apiGroups: ["kca.lab"]
    resources: ["labwidgets"]
    verbs: ["get", "list", "watch", "update", "patch"]
YAML
  kubectl apply -f "$LAB_DIR/manifests/rbac.yaml" >/dev/null
  ok "ClusterRole ${ROLE_NAME} created"
}

# ==============================================================================
#  BREAK — ship the three defective mutation policies
# ==============================================================================
apply_policy() {
  local file="$1" name out
  name="$(basename "$file" .yaml)"
  if out="$(kubectl apply -f "$file" 2>&1)"; then
    info "applied ${name}: ${out}"
  else
    warn "Kyverno REFUSED ${name} — that refusal is itself one of the symptoms:"
    printf '%s\n' "$out" | indent
    printf '%s\n' "$out" >"$LAB_DIR/symptoms/${name}-rejected.txt"
  fi
}

wait_for_webhook() {
  local i
  for i in $(seq 1 60); do
    if kubectl get mutatingwebhookconfigurations -o yaml 2>/dev/null | grep -q 'deployments'; then
      ok "Kyverno resource mutating webhook now intercepts Deployments"
      return 0
    fi
    sleep 2
  done
  warn "the mutating webhook does not list deployments yet; symptoms may lag a few seconds."
}

inject_faults() {
  title "BREAK — the platform team ships three mutation policies"

  cat >"$LAB_DIR/policies/kca54-pod-defaults.yaml" <<YAML
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: kca54-pod-defaults
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
  annotations:
    policies.kyverno.io/title: Pod defaults
    policies.kyverno.io/description: >-
      Every Deployment gets a default tier label (only when the team did not set
      one) and a hardened securityContext on every container.
spec:
  rules:
    - name: add-default-tier-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
      mutate:
        patchStrategicMerge:
          spec:
            template:
              metadata:
                labels:
                  kca.lab/tier: standard
    - name: add-container-securitycontext
      match:
        any:
          - resources:
              kinds:
                - Deployment
      mutate:
        patchStrategicMerge:
          spec:
            template:
              spec:
                containers:
                  - name: app
                    securityContext:
                      runAsNonRoot: true
                      runAsUser: 65532
                      allowPrivilegeEscalation: false
YAML

  cat >"$LAB_DIR/policies/kca54-node-placement.yaml" <<YAML
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: kca54-node-placement
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
  annotations:
    policies.kyverno.io/title: Lab node placement
    policies.kyverno.io/description: >-
      Append the lab toleration to every Deployment without discarding the
      tolerations the team already declared.
spec:
  rules:
    - name: add-lab-toleration
      match:
        any:
          - resources:
              kinds:
                - Deployment
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/template/spec/tolerations/-"
            value:
              key: kca.lab/dedicated
              operator: Equal
              value: students
              effect: NoSchedule
YAML

  cat >"$LAB_DIR/policies/kca54-widget-annotations.yaml" <<YAML
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: kca54-widget-annotations
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
  annotations:
    policies.kyverno.io/title: Widget ownership annotation
    policies.kyverno.io/description: >-
      When the mutation-trigger ConfigMap changes, stamp every existing
      LabWidget in this namespace with an ownership annotation.
spec:
  mutateExistingOnPolicyUpdate: false
  rules:
    - name: annotate-existing-widgets
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              names:
                - mutation-trigger
      mutate:
        targets:
          - apiVersion: kca.lab/v1alpha1
            kind: LabWidget
            namespace: ${NS}
        patchStrategicMerge:
          metadata:
            annotations:
              kca.lab/managed-by: kyverno
YAML

  local f
  for f in "$LAB_DIR"/policies/*.yaml; do apply_policy "$f"; done
  wait_for_webhook

  title "BREAK — reproducing the first symptom for you"
  info "\$ kubectl -n $NS rollout restart deployment/app-alpha"
  local out
  if out="$(kubectl -n "$NS" rollout restart deployment/app-alpha 2>&1)"; then
    warn "the restart was ACCEPTED: $out"
    warn "your Kyverno build admitted the request; inspect the mutated object and the"
    warn "admission-controller log to find what the rules actually did."
  else
    printf '%s\n' "$out" | indent
    printf '%s\n' "$out" >"$LAB_DIR/symptoms/rollout-restart.txt"
  fi
  info ""
  info "\$ kubectl -n $NS get labwidgets"
  kubectl -n "$NS" get labwidgets 2>&1 | indent
}

# ==============================================================================
#  BRIEFING
# ==============================================================================
brief() {
cat <<EOF

$BLD$CYA==============================================================================
 INCIDENT BRIEFING — KCA 5.4 Mutation Rules
==============================================================================$RST

$BLD WHAT THE PLATFORM TEAM MEANT TO SHIP $RST

  1) Policy $BLD kca54-pod-defaults $RST (namespace $NS)
     - every Deployment gets label  spec.template.metadata.labels["kca.lab/tier"]
       set to "standard" — but ONLY when the team did not declare one;
     - EVERY container gets securityContext runAsNonRoot=true, runAsUser=65532,
       allowPrivilegeEscalation=false.

  2) Policy $BLD kca54-node-placement $RST
     - append toleration key=kca.lab/dedicated operator=Equal value=students
       effect=NoSchedule to every Deployment, WITHOUT discarding tolerations the
       team already declared.

  3) Policy $BLD kca54-widget-annotations $RST
     - when the ConfigMap "mutation-trigger" changes, stamp every existing
       LabWidget in $NS with annotation kca.lab/managed-by=kyverno.

$BLD WHAT YOU WILL ACTUALLY SEE $RST

  SYMPTOM A — admission is blocked. Creating, applying, scaling or restarting
  any Deployment in $NS is rejected by the mutating webhook. The message names
  the webhook (mutate.kyverno.svc-fail) and a JSON patch failure similar to:

      admission webhook "mutate.kyverno.svc-fail" denied the request:
      ... failed to apply JSON patch: add operation does not apply:
      doc is missing path: "/spec/template/spec/tolerations/-"

  The exact wording depends on your Kyverno version. Captured output from this
  run, if any, is in:  $LAB_DIR/symptoms/

  SYMPTOM B — once admission stops failing, Deployments come back with a
  container you never wrote. The API server complains about a container with no
  image, e.g.  spec.template.spec.containers[1].image: Required value  — or, if
  it is admitted, the object shows TWO containers and the real one still has no
  securityContext.

  SYMPTOM C — a Deployment that explicitly declares kca.lab/tier: gold in its
  pod template comes back as kca.lab/tier: standard. The policy overwrote an
  intentional value. Nothing is logged: an unwanted mutation is silent.

  SYMPTOM D — the LabWidgets are never annotated, no matter how many times you
  touch the ConfigMap. Nothing is denied and nothing appears in the admission
  controller log, because mutate-existing is not admission work: it runs in the
  background controller under its own ServiceAccount.

      kubectl -n $NS get labwidgets
      kubectl -n $KYVERNO_NS logs deploy/\$(kubectl -n $KYVERNO_NS get deploy -o name \\
        | grep background | cut -d/ -f2) --tail=100

$BLD YOUR OBJECTIVE $RST

  Repair the three policies so that, on a freshly created Deployment:

    [1] a pod template that already sets kca.lab/tier keeps its own value;
    [2] a pod template with no kca.lab/tier receives "standard";
    [3] every real container — and no phantom container — receives
        securityContext.runAsNonRoot=true;
    [4] a Deployment with NO tolerations ends up with exactly the lab toleration;
    [5] a Deployment WITH a toleration keeps it AND gains the lab toleration;
    [6] both Deployments roll out successfully;
    [7] a LabWidget created after your fix is annotated kca.lab/managed-by=kyverno
        once the trigger ConfigMap is touched;
    [8] all three policies still exist, in namespace $NS, and are Ready.

$BLD RULES OF ENGAGEMENT $RST

  ALLOWED : editing the policies in $LAB_DIR/policies/, adding rules, adding
            preconditions, creating RBAC objects, reading any Kyverno log,
            using \`kubectl kyverno apply\` / \`kubectl kyverno test\` offline.
  FORBIDDEN: deleting the policies, setting failurePolicy: Ignore to hide the
            error, creating a PolicyException, editing the webhook configuration,
            hand-patching the probe objects, or editing the Kyverno deployments.

$BLD COMMANDS $RST

  Grade yourself :  $0 verify
  Stuck          :  $0 hint 1   (then 2, then 3)
  Tear down      :  $0 clean

EOF
}

# ==============================================================================
#  VERIFY — behavioural grading. Fresh objects only; nothing hand-patched passes.
# ==============================================================================
verify() {
  title "VERIFY — behavioural probes"
  local fail=0 out labels sc containers tols annot i

  kubectl get ns "$NS" >/dev/null 2>&1 || die "lab namespace $NS not found — run '$0 break' first."

  for p in "${POLICIES[@]}"; do
    if kubectl -n "$NS" get policy "$p" >/dev/null 2>&1; then
      ok "policy $p still exists"
    else
      bad "policy $p is missing — deleting a policy is not a fix"
      fail=1
    fi
  done

  kubectl -n "$NS" delete deploy probe-alpha probe-beta --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n "$NS" delete labwidget widget-probe --ignore-not-found >/dev/null 2>&1 || true

  cat >"$LAB_DIR/manifests/probes.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-alpha
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-alpha
  template:
    metadata:
      labels:
        app: probe-alpha
        kca.lab/tier: gold
    spec:
      containers:
        - name: web
          image: ${IMAGE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-beta
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-beta
  template:
    metadata:
      labels:
        app: probe-beta
    spec:
      tolerations:
        - key: node-role.kubernetes.io/lab
          operator: Exists
          effect: NoSchedule
      containers:
        - name: web
          image: ${IMAGE}
YAML

  if out="$(kubectl apply -f "$LAB_DIR/manifests/probes.yaml" 2>&1)"; then
    ok "probe Deployments were admitted"
  else
    bad "probe Deployments were rejected at admission:"
    printf '%s\n' "$out" | indent
    fail=1
  fi

  # [1] explicit label survives
  labels="$(gf deployment probe-alpha '{.spec.template.metadata.labels}')"
  if [[ "$labels" == *'"kca.lab/tier":"gold"'* ]]; then
    ok "[1] probe-alpha kept its explicit kca.lab/tier=gold"
  else
    bad "[1] probe-alpha lost its explicit tier label — got: ${labels:-<none>}"
    fail=1
  fi

  # [2] missing label is defaulted
  labels="$(gf deployment probe-beta '{.spec.template.metadata.labels}')"
  if [[ "$labels" == *'"kca.lab/tier":"standard"'* ]]; then
    ok "[2] probe-beta received the default kca.lab/tier=standard"
  else
    bad "[2] probe-beta did not receive the default tier label — got: ${labels:-<none>}"
    fail=1
  fi

  # [3] securityContext on the real container, and no phantom container
  for d in probe-alpha probe-beta; do
    containers="$(gf deployment "$d" '{.spec.template.spec.containers[*].name}')"
    sc="$(gf deployment "$d" '{.spec.template.spec.containers[0].securityContext.runAsNonRoot}')"
    if [[ "$containers" == "web" ]]; then
      ok "[3] $d has exactly one container named 'web'"
    else
      bad "[3] $d container list is '${containers:-<none>}' (expected exactly 'web')"
      fail=1
    fi
    if [[ "$sc" == "true" ]]; then
      ok "[3] $d container 'web' has securityContext.runAsNonRoot=true"
    else
      bad "[3] $d container 'web' has runAsNonRoot='${sc:-<unset>}'"
      fail=1
    fi
  done

  # [4] toleration added where none existed
  tols="$(gf deployment probe-alpha '{.spec.template.spec.tolerations[*].key}')"
  if [[ "$tols" == "kca.lab/dedicated" ]]; then
    ok "[4] probe-alpha has exactly the lab toleration"
  else
    bad "[4] probe-alpha tolerations are '${tols:-<none>}' (expected exactly 'kca.lab/dedicated')"
    fail=1
  fi

  # [5] toleration appended without destroying the declared one
  tols="$(gf deployment probe-beta '{.spec.template.spec.tolerations[*].key}')"
  if [[ "$tols" == *"kca.lab/dedicated"* && "$tols" == *"node-role.kubernetes.io/lab"* ]]; then
    ok "[5] probe-beta kept its own toleration and gained the lab toleration"
  else
    bad "[5] probe-beta tolerations are '${tols:-<none>}' (expected both keys)"
    fail=1
  fi

  # [6] both roll out
  for d in probe-alpha probe-beta; do
    if kubectl -n "$NS" rollout status "deploy/$d" --timeout=150s >/dev/null 2>&1; then
      ok "[6] $d rolled out successfully"
    else
      bad "[6] $d never became Available — check: kubectl -n $NS describe deploy/$d"
      fail=1
    fi
  done

  # [7] mutate existing reaches a widget created after the fix
  kubectl -n "$NS" apply -f - >/dev/null 2>&1 <<YAML || true
apiVersion: kca.lab/v1alpha1
kind: LabWidget
metadata:
  name: widget-probe
  namespace: ${NS}
  labels:
    kca.lab/lab: "5.4"
spec:
  tier: bronze
YAML
  kubectl -n "$NS" annotate configmap mutation-trigger "kca.lab/verify=$(date +%s)" --overwrite >/dev/null 2>&1 || true
  annot=""
  for i in $(seq 1 30); do
    annot="$(gf labwidget widget-probe '{.metadata.annotations}')"
    [[ "$annot" == *'"kca.lab/managed-by":"kyverno"'* ]] && break
    sleep 2
  done
  if [[ "$annot" == *'"kca.lab/managed-by":"kyverno"'* ]]; then
    ok "[7] widget-probe was annotated by the mutate-existing rule"
  else
    bad "[7] widget-probe was never annotated after 60s — got: ${annot:-<none>}"
    fail=1
  fi

  # [8] policies Ready
  for p in "${POLICIES[@]}"; do
    local ready
    ready="$(kubectl -n "$NS" get policy "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ -z "$ready" ]] && ready="$(kubectl -n "$NS" get policy "$p" -o jsonpath='{.status.ready}' 2>/dev/null || true)"
    if [[ "$ready" == "True" || "$ready" == "true" ]]; then
      ok "[8] policy $p is Ready"
    else
      warn "[8] policy $p Ready status is '${ready:-unknown}' (older Kyverno builds do not report it)"
    fi
  done

  hr
  if (( fail == 0 )); then
    printf '  %sALL CHECKS PASSED — topic 5.4 mutation semantics demonstrated.%s\n\n' "$GRN$BLD" "$RST"
    return 0
  fi
  printf '  %sSOME CHECKS FAILED — run "%s hint 1" or read the solution at the end of this script.%s\n\n' "$RED$BLD" "$0" "$RST"
  return 1
}

# ==============================================================================
#  HINTS
# ==============================================================================
hints() {
  local level="${1:-1}"
  title "HINT LEVEL $level"

  if (( level >= 1 )); then
cat <<'EOF'
  Level 1 — where to look
    * A mutate rule that FAILS blocks admission; a mutate rule that silently does
      NOTHING (or the wrong thing) leaves no trace at all. Read both:
          kubectl -n kyverno logs deploy/<admission-controller> --tail=200 | grep -i mutat
          kubectl -n kyverno logs deploy/<background-controller> --tail=200
    * Compare intent with reality on the object itself, not on the policy:
          kubectl -n LAB_NS get deploy app-beta -o yaml | sed -n '/template:/,$p'
    * Test a policy against a manifest offline, without touching the cluster:
          kubectl kyverno apply policies/kca54-pod-defaults.yaml --resource manifests/baseline.yaml
EOF
  fi

  if (( level >= 2 )); then
cat <<'EOF'

  Level 2 — the mechanics behind each symptom
    * strategic merge patches merge LISTS by their patchMergeKey. For
      spec.template.spec.containers the key is "name": an entry whose name does
      not exist in the target is ADDED, not merged. To reach every container
      regardless of its name you need Kyverno's conditional anchor on the key.
    * strategic merge patches on a MAP overwrite the keys they mention. Kyverno
      has a dedicated anchor that means "write this only if the key is absent".
      See https://kyverno.io/docs/writing-policies/mutate/#add-if-not-present-anchor
    * RFC 6902 "add" with the "-" token appends to an array — but the array must
      already exist. Adding to /a/b/- when b is absent is an error, by spec:
      https://datatracker.ietf.org/doc/html/rfc6902#section-4.1
      Kyverno's tool for "apply this rule only in this case" is preconditions.
    * mutate-existing does not run in the webhook. It runs in the background
      controller, as system:serviceaccount:kyverno:kyverno-background-controller,
      and that account only gets permissions through AGGREGATED ClusterRoles.
EOF
  fi

  if (( level >= 3 )); then
cat <<'EOF'

  Level 3 — near-spoilers
    * Anchors you need: (name): "*"  to select every list element, and
      +(key): value  to write a map key only when it is not already set.
    * Split the toleration rule in two, each with a precondition on
      length(request.object.spec.template.spec.tolerations || `[]`):
      one creates the array, the other appends to it with /-.
    * Look at how Kyverno's background ClusterRole selects the roles it absorbs:
EOF
    kubectl get clusterrole -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.aggregationRule.clusterRoleSelectors[*].matchLabels}{"\n"}{end}' 2>/dev/null \
      | grep -i 'background' | indent || warn "could not read the background-controller ClusterRole"
cat <<EOF
      Then compare it with the role the platform team wrote:
          kubectl get clusterrole ${ROLE_NAME} -o yaml
    * mutate-existing only fires on a trigger EVENT unless the policy opts into
      firing when the policy itself changes.
EOF
  fi
  printf '\n'
}

# ==============================================================================
#  CLEAN
# ==============================================================================
clean() {
  title "CLEAN — removing every object created by this lab"
  kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  info "namespace $NS deleted (policies, deployments, widgets, configmap)"
  kubectl delete crd "$CRD_NAME" --ignore-not-found >/dev/null 2>&1 || true
  info "CRD $CRD_NAME deleted"
  kubectl delete clusterrole "$ROLE_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole -l kca.lab/lab=5.4 --ignore-not-found >/dev/null 2>&1 || true
  info "lab ClusterRoles deleted"
  warn "any ClusterRole/ClusterRoleBinding YOU created without the kca.lab/lab=5.4 label"
  warn "was left in place on purpose — review with: kubectl get clusterrole | grep -i kca54"
  info "artifacts kept for review under: $LAB_DIR"
  ok "cleanup complete"
}

# ==============================================================================
#  MAIN
# ==============================================================================
main() {
  case "${1:-break}" in
    break)  preflight; setup_baseline; inject_faults; brief ;;
    brief)  brief ;;
    verify) verify ;;
    hint)   hints "${2:-1}" ;;
    clean)  clean ;;
    -h|--help|help)
            sed -n '1,40p' "$0" ;;
    *)      die "unknown command '$1' — try: break | brief | verify | hint | clean" ;;
  esac
}

main "$@"

# ==============================================================================
# ==============================================================================
#
#   S O L U T I O N   —   S T E P   B Y   S T E P   ( S P O I L E R S )
#
# ==============================================================================
# ==============================================================================
#
# ------------------------------------------------------------------------------
# STEP 0 — triage: separate "denied" from "silently wrong"
# ------------------------------------------------------------------------------
#   A mutation defect shows up in exactly two ways, and they are diagnosed in
#   different places:
#
#     denied at admission -> the rule threw an error; the message is in the
#                            kubectl output AND in the admission controller log:
#       kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=300 | grep -i mutat
#
#     silently wrong      -> the rule succeeded and produced the wrong object;
#                            nothing is logged, so you must diff intent vs object:
#       kubectl -n kca-mutation-lab get deploy app-alpha -o yaml | sed -n '/template:/,$p'
#
#     never ran at all    -> the rule is mutate-existing; the webhook is not
#                            involved, look at the background controller:
#       kubectl -n kyverno logs deploy/kyverno-background-controller --tail=300
#
#   Offline reproduction (no cluster, no webhook, instant feedback loop):
#       kubectl kyverno apply $LAB_DIR/policies/kca54-pod-defaults.yaml \
#               --resource $LAB_DIR/manifests/baseline.yaml
#
# ------------------------------------------------------------------------------
# FAULT B (fix this first — it blocks every other observation)
#   kca54-node-placement / rule add-lab-toleration
# ------------------------------------------------------------------------------
#   Root cause: RFC 6902 says "add" with the "-" index appends to an EXISTING
#   array. app-alpha and probe-alpha have no spec.template.spec.tolerations at
#   all, so the pointer /spec/template/spec/tolerations/- does not resolve and
#   the patch fails. Kyverno's default failurePolicy is Fail, so the whole
#   admission request — including an unrelated `rollout restart` — is denied.
#
#   Wrong fix: patchStrategicMerge on tolerations. PodSpec.tolerations has no
#   patchMergeKey, so a strategic merge REPLACES the list and destroys the
#   toleration probe-beta declared. Check [5] exists precisely to catch that.
#
#   Correct fix: two rules, each guarded by a precondition. Preconditions are
#   evaluated before the patch, so each rule only runs on the shape it can
#   handle. Write the file and re-apply:
#
#     cat > $LAB_DIR/policies/kca54-node-placement.yaml <<'YAML'
#     apiVersion: kyverno.io/v1
#     kind: Policy
#     metadata:
#       name: kca54-node-placement
#       namespace: kca-mutation-lab
#       labels:
#         kca.lab/lab: "5.4"
#     spec:
#       rules:
#         - name: create-toleration-list
#           match:
#             any:
#               - resources:
#                   kinds:
#                     - Deployment
#           preconditions:
#             all:
#               - key: '{{ length(request.object.spec.template.spec.tolerations || `[]`) }}'
#                 operator: Equals
#                 value: 0
#           mutate:
#             patchesJson6902: |-
#               - op: add
#                 path: "/spec/template/spec/tolerations"
#                 value:
#                   - key: kca.lab/dedicated
#                     operator: Equal
#                     value: students
#                     effect: NoSchedule
#         - name: append-lab-toleration
#           match:
#             any:
#               - resources:
#                   kinds:
#                     - Deployment
#           preconditions:
#             all:
#               - key: '{{ length(request.object.spec.template.spec.tolerations || `[]`) }}'
#                 operator: GreaterThan
#                 value: 0
#               - key: kca.lab/dedicated
#                 operator: AnyNotIn
#                 value: '{{ request.object.spec.template.spec.tolerations[].key }}'
#           mutate:
#             patchesJson6902: |-
#               - op: add
#                 path: "/spec/template/spec/tolerations/-"
#                 value:
#                   key: kca.lab/dedicated
#                   operator: Equal
#                   value: students
#                   effect: NoSchedule
#     YAML
#     kubectl apply -f $LAB_DIR/policies/kca54-node-placement.yaml
#
#   Note the second precondition on the append rule: without it, every UPDATE to
#   the Deployment appends the same toleration again and the list grows without
#   bound. Mutation rules must be idempotent, because they run on every UPDATE,
#   not only on CREATE.
#
# ------------------------------------------------------------------------------
# FAULT A.1 — phantom container
#   kca54-pod-defaults / rule add-container-securitycontext
# ------------------------------------------------------------------------------
#   Root cause: in a strategic merge patch, spec.template.spec.containers merges
#   by the patchMergeKey "name". The rule declares `- name: app`; no container in
#   the target is called "app", so the element is APPENDED as a brand-new
#   container that has a securityContext and no image. The API server then
#   rejects the object (containers[1].image: Required value), or admits a broken
#   template — and the real container "web" is never hardened.
#
#   Correct fix: the conditional anchor (name): "*" selects every element of the
#   list by its merge key instead of naming one.
#
# ------------------------------------------------------------------------------
# FAULT A.2 — the overwritten label
#   kca54-pod-defaults / rule add-default-tier-label
# ------------------------------------------------------------------------------
#   Root cause: a strategic merge patch on a map overwrites the keys it mentions.
#   "Default" was implemented as "always set", so app-alpha's deliberate
#   kca.lab/tier: gold became "standard". This is the most dangerous class of
#   mutation defect: nothing fails, nothing is logged, and the platform quietly
#   overrides application intent.
#
#   Correct fix: the add-if-not-present anchor +(key), which writes the key only
#   when it is absent from the target.
#
#     cat > $LAB_DIR/policies/kca54-pod-defaults.yaml <<'YAML'
#     apiVersion: kyverno.io/v1
#     kind: Policy
#     metadata:
#       name: kca54-pod-defaults
#       namespace: kca-mutation-lab
#       labels:
#         kca.lab/lab: "5.4"
#     spec:
#       rules:
#         - name: add-default-tier-label
#           match:
#             any:
#               - resources:
#                   kinds:
#                     - Deployment
#           mutate:
#             patchStrategicMerge:
#               spec:
#                 template:
#                   metadata:
#                     labels:
#                       +(kca.lab/tier): standard
#         - name: add-container-securitycontext
#           match:
#             any:
#               - resources:
#                   kinds:
#                     - Deployment
#           mutate:
#             patchStrategicMerge:
#               spec:
#                 template:
#                   spec:
#                     containers:
#                       - (name): "*"
#                         securityContext:
#                           +(runAsNonRoot): true
#                           +(runAsUser): 65532
#                           +(allowPrivilegeEscalation): false
#     YAML
#     kubectl apply -f $LAB_DIR/policies/kca54-pod-defaults.yaml
#
#   Anchor cheat sheet for mutate rules:
#       (key): value    conditional  — apply the sibling patch only if key matches
#                                      ("*" matches any value; also selects list
#                                      elements through their merge key)
#       +(key): value   add if not present — never overwrite an existing value
#   Validate rules use more anchors (=(), ^(), X(), <()) — do not mix them up.
#
# ------------------------------------------------------------------------------
# FAULT C — the mutate-existing rule that never runs
#   kca54-widget-annotations
# ------------------------------------------------------------------------------
#   Two independent defects:
#
#   C.1 RBAC. A rule with mutate.targets is executed by the BACKGROUND
#       controller, as system:serviceaccount:kyverno:kyverno-background-controller.
#       That account holds no permission on kca.lab/labwidgets. Kyverno's
#       background ClusterRole is an AGGREGATED role: it only absorbs roles
#       carrying the label rbac.kyverno.io/aggregate-to-background-controller.
#       The platform team's ClusterRole has the right rules and no label, so it
#       aggregates into nothing. Depending on your Kyverno version you will see
#       either a "forbidden" error in the background controller log, or the
#       policy itself refused at apply time with a message about missing
#       permissions on the target.
#
#         kubectl label clusterrole kca54-labwidget-writer \
#           rbac.kyverno.io/aggregate-to-background-controller=true
#
#         # confirm the aggregation actually happened:
#         kubectl get clusterrole kyverno:background-controller -o yaml | grep -A4 labwidgets
#         kubectl auth can-i update labwidgets.kca.lab \
#           --as=system:serviceaccount:kyverno:kyverno-background-controller \
#           -n kca-mutation-lab            # must print: yes
#
#   C.2 Trigger. mutateExistingOnPolicyUpdate: false means the rule only runs
#       when a matching trigger event occurs; creating or updating the policy
#       changes nothing. Set it to true so the fix takes effect immediately, and
#       still touch the trigger to prove the event path works:
#
#         kubectl -n kca-mutation-lab patch policy kca54-widget-annotations \
#           --type=merge -p '{"spec":{"mutateExistingOnPolicyUpdate":true}}'
#         kubectl -n kca-mutation-lab annotate cm mutation-trigger \
#           kca.lab/rev=2 --overwrite
#         kubectl -n kca-mutation-lab get labwidgets -o custom-columns=\
#         NAME:.metadata.name,OWNER:.metadata.annotations.kca\\.lab/managed-by
#
#   If it still does not fire, the background controller caches RBAC; give it a
#   few seconds, then re-read its log. Restarting deploy/kyverno-background-
#   controller is a legitimate last resort, not a fix.
#
# ------------------------------------------------------------------------------
# STEP FINAL — grade and tear down
# ------------------------------------------------------------------------------
#     ./kca-5.4-mutation-break-fix.sh verify     # must exit 0 with 8/8 checks
#     ./kca-5.4-mutation-break-fix.sh clean
#
# ------------------------------------------------------------------------------
# EXAM-LEVEL TAKEAWAYS (KCA 5.4)
# ------------------------------------------------------------------------------
#   1. Mutation is admission-time. Mutating a Deployment rewrites the pod
#      TEMPLATE; running pods are untouched until a rollout replaces them.
#      Matching Pods directly instead would activate Kyverno's autogen and
#      produce derived rules for the pod controllers — a different behaviour.
#   2. patchStrategicMerge merges maps key by key and lists by patchMergeKey;
#      patchesJson6902 is literal, positional and unforgiving. Use the first for
#      shape-preserving defaults, the second for surgical array work.
#   3. Anchors are the whole grammar of "when": (name):"*" to iterate a list,
#      +() to default without overwriting. A mutation without +() is a policy
#      that overrides application intent silently.
#   4. Rules must be idempotent: they run on every UPDATE. Guard appends with a
#      precondition or you will grow lists forever.
#   5. mutate.targets moves the work from the webhook to the background
#      controller — different identity, different RBAC, different log, and
#      nothing is ever denied when it fails.
#   6. Kyverno's default failurePolicy is Fail: a broken mutate rule is an
#      outage for every matching resource, including unrelated updates.
# ==============================================================================