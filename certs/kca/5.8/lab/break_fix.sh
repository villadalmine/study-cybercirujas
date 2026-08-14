#!/usr/bin/env bash
#
# ============================================================================
#  KCA 5.8 — JSON Patches (RFC 6902) in Kyverno mutate rules
#  Break & fix laboratory — exam weight 2.91
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It builds a small, realistic production scenario in a THROWAWAY cluster:
#  a Deployment that is healthy, and then a ClusterPolicy shipped by the
#  "platform team" whose `patchesJson6902` block contains three classic
#  RFC 6901 / RFC 6902 mistakes. The mutation webhook then fails closed and
#  the workload cannot be scheduled at all.
#
#  Your job is to repair the JSON Patch — NOT to delete the policy, NOT to
#  disable the webhook, NOT to rewrite everything as patchStrategicMerge.
#
#  SAFETY — READ BEFORE RUNNING
#  ----------------------------
#  * Run this ONLY on a disposable lab VM / kind / k3d / minikube cluster.
#  * It creates exactly two objects it owns, both marked kca.lab/topic=5.8:
#        - Namespace         kca58-lab
#        - ClusterPolicy     kca58-cost-center-mutation
#    The policy `match` block is scoped to the lab namespace only, so no other
#    workload in the cluster can be affected by the broken mutation.
#  * It never edits MutatingWebhookConfigurations, never touches kube-system,
#    never deletes anything that does not carry the marker label.
#  * It refuses to run against a context that does not look like a lab cluster
#    unless you explicitly export KCA_LAB_FORCE=1.
#
#  USAGE
#  -----
#     ./kca-5.8-json-patches.sh                 # break the lab (default)
#     ./kca-5.8-json-patches.sh --install-kyverno
#     ./kca-5.8-json-patches.sh --verify        # grade your fix
#     ./kca-5.8-json-patches.sh --cleanup       # remove every lab object
#
#  REFERENCES
#  ----------
#     KCA curriculum ....... https://github.com/cncf/curriculum
#     Kyverno mutate ....... https://kyverno.io/docs/writing-policies/mutate/
#     Kyverno preconditions  https://kyverno.io/docs/writing-policies/preconditions/
#     Kyverno troubleshoot .. https://kyverno.io/docs/troubleshooting/
#     RFC 6902 JSON Patch .. https://datatracker.ietf.org/doc/html/rfc6902
#     RFC 6901 JSON Pointer  https://datatracker.ietf.org/doc/html/rfc6901
#     kubectl JSONPath ..... https://kubernetes.io/docs/reference/kubectl/jsonpath/
# ============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (all overridable from the environment)
# ---------------------------------------------------------------------------
readonly LAB_ID="kca-5.8-json-patches"
NS="${NS:-kca58-lab}"
POLICY="${POLICY:-kca58-cost-center-mutation}"
DEPLOY="${DEPLOY:-payments}"
REPLICAS="${REPLICAS:-3}"
IMAGE="${IMAGE:-registry.k8s.io/pause:3.9}"
WORKDIR="${WORKDIR:-${HOME}/${LAB_ID}}"
MARKER_KEY="kca.lab/topic"
MARKER_VAL="5.8"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"

# Expected end state, enforced by --verify
readonly WANT_ANNOTATION_KEY="cost-center.acme.io/owner"
readonly WANT_ANNOTATION_VAL="platform-team"
readonly WANT_MEM_LIMIT="256Mi"
readonly WANT_ENV_NAME="COST_CENTER"
readonly WANT_ENV_VAL="platform-team"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'
else
  C_RST=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""
fi

log()  { printf '%s[ lab ]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[  ok ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
fail() { printf '%s[fail ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { fail "$*"; exit 1; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

trap 'fail "aborted at line ${LINENO} (exit ${?})"' ERR

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found in PATH: $1"
}

preflight() {
  require_cmd kubectl
  kubectl version --request-timeout=15s >/dev/null 2>&1 \
    || die "no reachable Kubernetes API server (check your kubeconfig / tunnel)"
  mkdir -p "$WORKDIR"
}

assert_disposable_cluster() {
  local ctx nodes
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  case "$ctx" in
    kind-*|k3d-*|minikube*|rancher-desktop|docker-desktop|*lab*|*sandbox*|*test*|*dev*) ;;
    *)
      if [[ "${KCA_LAB_FORCE:-0}" != "1" ]]; then
        rule
        fail "current kube-context is '${ctx}', which does not look like a lab cluster."
        fail "This script intentionally breaks admission control. Refusing to continue."
        fail "If this really is a disposable cluster, re-run with: KCA_LAB_FORCE=1 $0"
        rule
        exit 1
      fi
      warn "KCA_LAB_FORCE=1 set — proceeding on context '${ctx}'"
      ;;
  esac
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  log "context='${ctx}' nodes=${nodes} namespace='${NS}'"
}

assert_kyverno() {
  kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 \
    || die "Kyverno CRDs not found. Install it first:  $0 --install-kyverno"
  local d
  while read -r d; do
    [[ -n "$d" ]] || continue
    kubectl -n "$KYVERNO_NS" rollout status "$d" --timeout=180s >/dev/null \
      || die "Kyverno deployment ${d} is not ready"
  done < <(kubectl -n "$KYVERNO_NS" get deploy -o name 2>/dev/null)
  ok "Kyverno is installed and its controllers are Available"
}

install_kyverno() {
  require_cmd helm
  log "installing Kyverno into namespace '${KYVERNO_NS}' via Helm"
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
  helm repo update kyverno >/dev/null
  helm upgrade --install kyverno kyverno/kyverno \
    --namespace "$KYVERNO_NS" --create-namespace --wait --timeout 10m
  ok "Kyverno installed"
}

# ---------------------------------------------------------------------------
# Lab assets
# ---------------------------------------------------------------------------
write_workload_manifest() {
  cat > "${WORKDIR}/workload.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    ${MARKER_KEY}: "${MARKER_VAL}"
    kca.lab/id: "${LAB_ID}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels:
    app: ${DEPLOY}
    ${MARKER_KEY}: "${MARKER_VAL}"
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${DEPLOY}
  template:
    metadata:
      labels:
        app: ${DEPLOY}
      # NOTE (deliberate): the pod template carries NO annotations map,
      # NO resources.limits and NO env list. Every one of those absences
      # is meaningful for an RFC 6902 patch.
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: app
          image: ${IMAGE}
YAML
}

# The broken policy. Three independent RFC 6901 / RFC 6902 defects.
write_broken_policy() {
  cat > "${WORKDIR}/policy-broken.yaml" <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY}
  labels:
    ${MARKER_KEY}: "${MARKER_VAL}"
  annotations:
    policies.kyverno.io/title: Cost center tagging and memory limit (JSON Patch)
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Every workload must be attributable to a cost center and must declare a
      memory limit. Implemented with RFC 6902 JSON Patches so that the exact
      operations are auditable.
spec:
  background: false
  rules:
    - name: add-cost-center-annotation
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS}
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/annotations/${WANT_ANNOTATION_KEY}"
            value: "${WANT_ANNOTATION_VAL}"

    - name: enforce-memory-limit
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS}
      mutate:
        patchesJson6902: |-
          - op: replace
            path: "/spec/containers/0/resources/limits/memory"
            value: "${WANT_MEM_LIMIT}"

    - name: inject-cost-center-env
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS}
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/containers/0/env/-"
            value:
              name: ${WANT_ENV_NAME}
              value: "${WANT_ENV_VAL}"
YAML
}

# Optional appendix: the CRD-level type error (list instead of string).
write_bonus_manifest() {
  cat > "${WORKDIR}/bonus-list-form.yaml" <<YAML
# Appendix challenge — do NOT apply this to fix the lab.
# Try:  kubectl apply -f ${WORKDIR}/bonus-list-form.yaml
# and explain, in one sentence, why the API server rejects it before Kyverno
# ever evaluates a single operation.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: kca58-bonus-list-form
spec:
  rules:
    - name: bonus
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [${NS}]
      mutate:
        patchesJson6902:
          - op: add
            path: "/metadata/annotations/example~1key"
            value: "bonus"
YAML
}

# ---------------------------------------------------------------------------
# Probe: a server-side dry run executes admission webhooks with no side effects
# ---------------------------------------------------------------------------
probe_admission() {
  local out
  if out="$(kubectl -n "$NS" run kca58-canary \
        --image="$IMAGE" --restart=Never \
        --dry-run=server -o name 2>&1)"; then
    return 1   # request was ALLOWED -> the break is not active yet
  fi
  printf '%s\n' "$out" > "${WORKDIR}/last-denial.txt"
  return 0     # request was DENIED  -> the break is active
}

wait_for_break() {
  local i
  for i in $(seq 1 30); do
    if probe_admission; then
      ok "mutating webhook is now rejecting Pod creation in '${NS}'"
      return 0
    fi
    sleep 2
  done
  die "the policy was applied but admission still succeeds; is Kyverno's webhook registered? (kubectl get mutatingwebhookconfigurations)"
}

# ---------------------------------------------------------------------------
# BREAK
# ---------------------------------------------------------------------------
do_break() {
  preflight
  assert_disposable_cluster
  assert_kyverno

  if kubectl get ns "$NS" >/dev/null 2>&1; then
    local mark
    mark="$(kubectl get ns "$NS" -o jsonpath="{.metadata.labels.kca\.lab/topic}" 2>/dev/null || true)"
    [[ "$mark" == "$MARKER_VAL" ]] \
      || die "namespace '${NS}' already exists and is not owned by this lab — refusing to touch it"
  fi

  write_workload_manifest
  write_broken_policy
  write_bonus_manifest

  log "stage 1/3 — deploying a healthy workload (pre-incident baseline)"
  kubectl apply -f "${WORKDIR}/workload.yaml" >/dev/null
  kubectl -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=180s \
    || die "the baseline deployment never became ready (image pull? node capacity?)"
  ok "baseline healthy: ${DEPLOY} ${REPLICAS}/${REPLICAS} ready"

  log "stage 2/3 — the platform team ships a mutation ClusterPolicy"
  kubectl apply -f "${WORKDIR}/policy-broken.yaml" >/dev/null
  ok "ClusterPolicy/${POLICY} applied"
  wait_for_break

  log "stage 3/3 — simulating a node drain: the Pods are recreated"
  kubectl -n "$NS" scale "deploy/${DEPLOY}" --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l "app=${DEPLOY}" --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "$NS" scale "deploy/${DEPLOY}" --replicas="${REPLICAS}" >/dev/null
  sleep 8
  ok "incident is live"

  print_briefing
}

print_briefing() {
  local denial
  denial="$(head -c 800 "${WORKDIR}/last-denial.txt" 2>/dev/null || echo '<not captured>')"

  rule
  printf '%sKCA 5.8 — JSON PATCHES — INCIDENT BRIEFING%s\n' "$C_BLD" "$C_RST"
  rule
  cat <<EOF

SITUATION
  A ClusterPolicy named '${POLICY}' was merged on Friday to satisfy a
  FinOps requirement: every Pod must carry the cost-center annotation, a
  memory limit and a COST_CENTER environment variable. It was implemented
  with RFC 6902 JSON Patches (patchesJson6902) instead of a strategic merge
  patch, because the audit team wants the exact operations recorded.

  Nothing broke on Friday: the running Pods were never re-admitted.
  Tonight the nodes were drained. The '${DEPLOY}' Deployment in namespace
  '${NS}' is now at 0 available replicas and will not recover.

SYMPTOMS YOU WILL SEE

  kubectl -n ${NS} get deploy ${DEPLOY}
      NAME       READY   UP-TO-DATE   AVAILABLE   AGE
      ${DEPLOY}   0/${REPLICAS}     ${REPLICAS}            0           2m

  kubectl -n ${NS} get pods
      No resources found in ${NS} namespace.

  kubectl -n ${NS} describe rs -l app=${DEPLOY} | tail -n 5
      Warning  FailedCreate  ...  Error creating: admission webhook
      "mutate.kyverno.svc-fail" denied the request: ...

  The exact denial captured by a server-side dry run just now:

$(printf '%s\n' "$denial" | sed 's/^/      /')

YOUR MISSION
  Bring '${DEPLOY}' back to ${REPLICAS}/${REPLICAS} Ready, WITH the mutations
  actually applied. Concretely, every Pod of the Deployment must end up with:

    1. annotation  ${WANT_ANNOTATION_KEY}: ${WANT_ANNOTATION_VAL}
    2. container[0] resources.limits.memory: ${WANT_MEM_LIMIT}
    3. container[0] env entry ${WANT_ENV_NAME}=${WANT_ENV_VAL}

RULES OF ENGAGEMENT (this is what makes it a JSON Patch exercise)
  ALLOWED     : editing the patch operations, adding rules, adding
                preconditions, re-applying the policy, restarting the rollout.
  NOT ALLOWED : deleting or disabling ClusterPolicy/${POLICY};
                setting failurePolicy: Ignore to hide the error;
                editing the MutatingWebhookConfiguration;
                hard-coding the three fields into the Deployment template;
                replacing every rule with patchStrategicMerge — the policy
                must still contain patchesJson6902.

WHERE TO START
  kubectl -n ${NS} describe rs -l app=${DEPLOY}
  kubectl get cpol ${POLICY} -o yaml
  kubectl -n ${KYVERNO_NS} logs deploy/kyverno-admission-controller --tail=80 | grep -i patch
  kubectl -n ${NS} run canary --image=${IMAGE} --restart=Never --dry-run=server -o yaml
      ^ server-side dry run runs the webhooks and creates nothing:
        it is your fastest feedback loop, use it after every edit.

HINTS (read one at a time, only if stuck)
  H1. There are THREE independent defects, one per rule. The first denial
      message only tells you about the first one; fix, re-probe, repeat.
  H2. Read the denial message literally. "doc is missing path" is telling you
      the pointer does not resolve — ask yourself which segment of the pointer
      does not exist in the incoming Pod JSON, and print that JSON.
  H3. Two of the three defects come from RFC 6902 semantics: an operation may
      require its target, or its target's PARENT, to already exist. The third
      comes from RFC 6901 pointer syntax and a character that is not allowed
      to appear raw inside a reference token.

FILES
  ${WORKDIR}/workload.yaml        the target Deployment
  ${WORKDIR}/policy-broken.yaml   the policy as shipped (edit this)
  ${WORKDIR}/bonus-list-form.yaml appendix challenge
  ${WORKDIR}/last-denial.txt      last captured admission denial

GRADE YOUR WORK
  $0 --verify
CLEAN UP
  $0 --cleanup

EOF
  rule
}

# ---------------------------------------------------------------------------
# VERIFY
# ---------------------------------------------------------------------------
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; return 0; fi
  fail "$desc"; return 1
}

do_verify() {
  preflight
  local failures=0

  rule
  printf '%sVERIFICATION — KCA 5.8 JSON Patches%s\n' "$C_BLD" "$C_RST"
  rule

  # 1. the policy must still exist and still use JSON Patch
  if kubectl get cpol "$POLICY" >/dev/null 2>&1; then
    ok "ClusterPolicy/${POLICY} still exists (you did not delete the control)"
  else
    fail "ClusterPolicy/${POLICY} is gone — deleting the policy is not a fix"
    failures=$((failures + 1))
  fi

  if kubectl get cpol "$POLICY" -o yaml 2>/dev/null | grep -q 'patchesJson6902'; then
    ok "the policy still mutates with patchesJson6902"
  else
    fail "no patchesJson6902 left in the policy — the exercise is to repair the JSON Patch"
    failures=$((failures + 1))
  fi

  if kubectl get cpol "$POLICY" -o jsonpath='{.spec.failurePolicy}' 2>/dev/null | grep -qi 'ignore'; then
    fail "failurePolicy=Ignore — you silenced the webhook instead of fixing the patch"
    failures=$((failures + 1))
  fi

  # 2. the Deployment must be fully available again
  local ready
  ready="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  ready="${ready:-0}"
  if [[ "$ready" == "$REPLICAS" ]]; then
    ok "Deployment ${DEPLOY} is ${ready}/${REPLICAS} Ready"
  else
    fail "Deployment ${DEPLOY} is ${ready}/${REPLICAS} Ready"
    failures=$((failures + 1))
  fi

  # 3. every Pod must carry the three mutations
  local pods p pod_fail=0
  pods="$(kubectl -n "$NS" get pods -l "app=${DEPLOY}" \
            --field-selector=status.phase=Running \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "$pods" ]]; then
    fail "no Running Pods to inspect"
    failures=$((failures + 1))
  else
    for p in $pods; do
      local ann env mem
      ann="$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.metadata.annotations}' 2>/dev/null || true)"
      mem="$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
      env="$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.containers[0].env}' 2>/dev/null || true)"

      grep -qF "${WANT_ANNOTATION_KEY}:${WANT_ANNOTATION_VAL}" <<<"$ann" \
        || { fail "${p}: missing annotation ${WANT_ANNOTATION_KEY}=${WANT_ANNOTATION_VAL}"; pod_fail=1; }
      [[ "$mem" == "$WANT_MEM_LIMIT" ]] \
        || { fail "${p}: memory limit is '${mem:-<unset>}', want ${WANT_MEM_LIMIT}"; pod_fail=1; }
      grep -qF "name:${WANT_ENV_NAME}" <<<"$env" && grep -qF "value:${WANT_ENV_VAL}" <<<"$env" \
        || { fail "${p}: missing env ${WANT_ENV_NAME}=${WANT_ENV_VAL}"; pod_fail=1; }
    done
    if [[ "$pod_fail" -eq 0 ]]; then
      ok "all Running Pods carry the annotation, the memory limit and the env var"
    else
      failures=$((failures + 1))
    fi
  fi

  # 4. the mutation must be reproducible, not a one-off manual edit
  if probe_admission; then
    fail "a fresh Pod is STILL being denied — the patch is not repaired for new admissions"
    sed 's/^/       /' "${WORKDIR}/last-denial.txt" 2>/dev/null | head -n 4 >&2
    failures=$((failures + 1))
  else
    ok "a fresh Pod is admitted and mutated (server-side dry run passes)"
  fi

  rule
  if [[ "$failures" -eq 0 ]]; then
    printf '%sPASS%s — the JSON Patch is correct and the workload is healthy.\n' "$C_GRN$C_BLD" "$C_RST"
    rule
    return 0
  fi
  printf '%sFAIL%s — %d check group(s) still failing. Keep going.\n' "$C_RED$C_BLD" "$C_RST" "$failures"
  printf 'Tip: after editing the policy, force new Pods with\n'
  printf '     kubectl -n %s rollout restart deploy/%s\n' "$NS" "$DEPLOY"
  rule
  return 1
}

# ---------------------------------------------------------------------------
# CLEANUP — only removes objects carrying the lab marker
# ---------------------------------------------------------------------------
do_cleanup() {
  preflight
  local mark
  if kubectl get cpol "$POLICY" >/dev/null 2>&1; then
    mark="$(kubectl get cpol "$POLICY" -o jsonpath="{.metadata.labels.kca\.lab/topic}" 2>/dev/null || true)"
    if [[ "$mark" == "$MARKER_VAL" ]]; then
      kubectl delete cpol "$POLICY" --wait=true >/dev/null && ok "deleted ClusterPolicy/${POLICY}"
    else
      warn "ClusterPolicy/${POLICY} lacks the lab marker — left untouched"
    fi
  fi
  kubectl delete cpol kca58-bonus-list-form --ignore-not-found >/dev/null 2>&1 || true
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    mark="$(kubectl get ns "$NS" -o jsonpath="{.metadata.labels.kca\.lab/topic}" 2>/dev/null || true)"
    if [[ "$mark" == "$MARKER_VAL" ]]; then
      kubectl delete ns "$NS" --wait=false >/dev/null && ok "deleting namespace ${NS}"
    else
      warn "namespace ${NS} lacks the lab marker — left untouched"
    fi
  fi
  ok "cleanup done (working files kept in ${WORKDIR})"
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^#\{1,2\} \{0,1\}//;s/^#$//'
}

main() {
  case "${1:---break}" in
    --break|"")        do_break ;;
    --verify|-v)       do_verify ;;
    --cleanup|-c)      do_cleanup ;;
    --install-kyverno) preflight; assert_disposable_cluster; install_kyverno ;;
    --help|-h)         usage ;;
    *)                 die "unknown option: $1 (try --help)" ;;
  esac
}

main "$@"

# ############################################################################
# #                                                                          #
# #   S O L U T I O N   —   do not read until you have tried the lab         #
# #                                                                          #
# ############################################################################
#
# ---------------------------------------------------------------------------
# STEP 0 — Confirm the failure domain before touching anything
# ---------------------------------------------------------------------------
#
#   kubectl -n kca58-lab get deploy,rs,pods
#   kubectl -n kca58-lab describe rs -l app=payments | tail -n 10
#
# Expected (abbreviated):
#
#   Events:
#     Type     Reason        Age   From                   Message
#     ----     ------        ----  ----                   -------
#     Warning  FailedCreate  30s   replicaset-controller  Error creating: admission
#       webhook "mutate.kyverno.svc-fail" denied the request: mutation policy
#       kca58-cost-center-mutation error: failed to apply JSON Patch: add operation
#       does not apply: doc is missing path:
#       "/metadata/annotations/cost-center.acme.io/owner"
#
# Two facts to extract from that single line:
#   * "mutate.kyverno.svc-fail" — this is the FAIL variant of Kyverno's webhook,
#     i.e. failurePolicy: Fail. A mutation error is therefore a hard denial, not
#     a warning. This is by design: a policy that silently stops mutating is a
#     compliance hole.
#   * "doc is missing path" comes from the JSON Patch library, not from Kyverno.
#     It means the JSON Pointer did not resolve against the incoming document.
#
# Establish a fast feedback loop — server-side dry run executes the full
# admission chain and persists nothing:
#
#   kubectl -n kca58-lab run canary --image=registry.k8s.io/pause:3.9 \
#           --restart=Never --dry-run=server -o yaml
#
# And look at the document the patch is actually applied to. This is the single
# most useful habit for JSON Patch work — stop guessing the shape of the doc:
#
#   kubectl -n kca58-lab get pod -l app=payments -o json | jq '.items[0]'
#   # or, with no jq available:
#   kubectl -n kca58-lab create -f - --dry-run=client -o json <<'EOF'
#   {"apiVersion":"v1","kind":"Pod","metadata":{"name":"shape"},
#    "spec":{"containers":[{"name":"app","image":"registry.k8s.io/pause:3.9"}]}}
#   EOF
#
# You will see, on a Pod with no annotations/limits/env:
#
#   "metadata": { "name": "...", "labels": {"app":"payments"} }      <- no annotations key
#   "spec": { "containers": [ { "name":"app", "image":"...",
#                               "resources": {} } ] }                <- resources exists, empty
#
# That last detail is worth memorising: containers[].resources is a struct, not
# a pointer, so it is ALWAYS serialised — as {} when unset. `limits` inside it
# is a map and is absent. `env` is a slice and is absent entirely. `annotations`
# is a map and is absent entirely.
#
# ---------------------------------------------------------------------------
# DEFECT 1 — rule add-cost-center-annotation: unescaped "/" in a JSON Pointer
# ---------------------------------------------------------------------------
#
#   BROKEN:  path: "/metadata/annotations/cost-center.acme.io/owner"
#   FIXED :  path: "/metadata/annotations/cost-center.acme.io~1owner"
#
# RFC 6901 §3: a JSON Pointer is a sequence of reference tokens separated by
# "/". Inside a token, the two characters that cannot appear literally are
# escaped:
#
#       "~"  ->  "~0"
#       "/"  ->  "~1"
#
# and unescaping is always ~1 first, then ~0. So the pointer above was not
# addressing one annotation key called "cost-center.acme.io/owner"; it was
# addressing the key "owner" inside an object called "cost-center.acme.io"
# inside annotations — an object that does not exist. Hence "doc is missing
# path". Every Kubernetes annotation or label that carries a prefixed key
# (app.kubernetes.io/name, policies.kyverno.io/description, node-role.
# kubernetes.io/control-plane, …) hits this, which is why it is the single most
# common JSON Patch bug in Kyverno policies.
#
# Dots need NO escaping — they are ordinary characters in a reference token.
# Only ~ and / do.
#
# ---------------------------------------------------------------------------
# DEFECT 1b — the parent map may not exist (defensive, and exam-relevant)
# ---------------------------------------------------------------------------
#
# Even with correct escaping, `add` to /metadata/annotations/<key> requires
# /metadata/annotations to already be an object. RFC 6902 §4.1: "the object
# itself or an array containing it does need to exist, and it remains an error
# for that not to be the case". A Pod template with no annotations at all
# therefore fails.
#
# Whether you observe this in your cluster depends on what other controllers
# put on the Pod before Kyverno sees it, which is exactly why you should not
# depend on luck. Add a guarded rule that materialises the map first — Kyverno
# applies mutate rules of a policy in declaration order, and each rule sees the
# result of the previous ones:
#
#     - name: ensure-annotations-object
#       match:
#         any:
#           - resources:
#               kinds: [Pod]
#               namespaces: [kca58-lab]
#       preconditions:
#         all:
#           - key: "{{ request.object.metadata.annotations || '' }}"
#             operator: Equals
#             value: ""
#       mutate:
#         patchesJson6902: |-
#           - op: add
#             path: "/metadata/annotations"
#             value: {}
#
# The precondition is not decoration. Without it, `add /metadata/annotations`
# with value {} REPLACES the whole map when one already exists (RFC 6902 §4.1:
# add on an existing object member replaces its value), silently destroying
# kubectl.kubernetes.io/last-applied-configuration, checksum/config annotations
# used to trigger rollouts, and anything a service mesh injected. That is a
# production incident, not a lab detail.
#
# ---------------------------------------------------------------------------
# DEFECT 2 — rule enforce-memory-limit: `replace` on a target that does not exist
# ---------------------------------------------------------------------------
#
#   BROKEN:  - op: replace
#              path: "/spec/containers/0/resources/limits/memory"
#              value: "256Mi"
#
#   FIXED :  - op: add
#              path: "/spec/containers/0/resources/limits"
#              value:
#                memory: "256Mi"
#
# RFC 6902 §4.3: "The target location MUST exist for the operation to be
# successful." replace is not upsert. The container had `resources: {}`, so
# neither `limits` nor `limits/memory` existed and the operation errored with
# "replace operation does not apply: doc is missing key".
#
# Note WHY the fix targets /limits and not /limits/memory: `add` also requires
# the parent to exist, and `limits` was absent. Adding the parent object with
# its member in one operation is the idiomatic form. The same caveat as above
# applies — if a container already declared limits.cpu, this add would wipe it.
# The production-grade version is a precondition on
# `{{ request.object.spec.containers[0].resources.limits || '' }}`, plus a
# second rule that adds only /limits/memory when limits already exists.
#
# ---------------------------------------------------------------------------
# DEFECT 3 — rule inject-cost-center-env: "-" appends only to an EXISTING array
# ---------------------------------------------------------------------------
#
#   BROKEN:  - op: add
#              path: "/spec/containers/0/env/-"
#              value: {name: COST_CENTER, value: "platform-team"}
#
#   FIXED :  - op: add
#              path: "/spec/containers/0/env"
#              value:
#                - name: COST_CENTER
#                  value: "platform-team"
#
# RFC 6901 §4 defines "-" as the (nonexistent) element after the last array
# element; RFC 6902 §4.1 gives it the meaning "append". But it is still a
# reference token that must resolve against an existing array. With no `env`
# key at all the library reports "add operation does not apply: doc is missing
# path: /spec/containers/0/env". Once `env` exists, `/env/-` is the correct and
# order-safe way to append; `/env/0` would prepend and shift, and any fixed
# index is a race with whatever other webhook injected variables first.
#
# ---------------------------------------------------------------------------
# STEP 1 — Apply the corrected policy
# ---------------------------------------------------------------------------
#
#   cat > ~/kca-5.8-json-patches/policy-fixed.yaml <<'EOF'
#   apiVersion: kyverno.io/v1
#   kind: ClusterPolicy
#   metadata:
#     name: kca58-cost-center-mutation
#     labels:
#       kca.lab/topic: "5.8"
#   spec:
#     background: false
#     rules:
#       - name: ensure-annotations-object
#         match:
#           any:
#             - resources:
#                 kinds: [Pod]
#                 namespaces: [kca58-lab]
#         preconditions:
#           all:
#             - key: "{{ request.object.metadata.annotations || '' }}"
#               operator: Equals
#               value: ""
#         mutate:
#           patchesJson6902: |-
#             - op: add
#               path: "/metadata/annotations"
#               value: {}
#
#       - name: add-cost-center-annotation
#         match:
#           any:
#             - resources:
#                 kinds: [Pod]
#                 namespaces: [kca58-lab]
#         mutate:
#           patchesJson6902: |-
#             - op: add
#               path: "/metadata/annotations/cost-center.acme.io~1owner"
#               value: "platform-team"
#
#       - name: enforce-memory-limit
#         match:
#           any:
#             - resources:
#                 kinds: [Pod]
#                 namespaces: [kca58-lab]
#         mutate:
#           patchesJson6902: |-
#             - op: add
#               path: "/spec/containers/0/resources/limits"
#               value:
#                 memory: "256Mi"
#
#       - name: inject-cost-center-env
#         match:
#           any:
#             - resources:
#                 kinds: [Pod]
#                 namespaces: [kca58-lab]
#         mutate:
#           patchesJson6902: |-
#             - op: add
#               path: "/spec/containers/0/env"
#               value:
#                 - name: COST_CENTER
#                   value: "platform-team"
#   EOF
#
#   kubectl apply -f ~/kca-5.8-json-patches/policy-fixed.yaml
#   kubectl get cpol kca58-cost-center-mutation
#
# Expected:
#
#   NAME                         ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
#   kca58-cost-center-mutation   true        false        Audit             True    3s
#
# READY=True means the policy compiled and the webhook was reconfigured. If it
# is False, `kubectl describe cpol kca58-cost-center-mutation` shows why.
#
# ---------------------------------------------------------------------------
# STEP 2 — Prove the fix on a throwaway request BEFORE touching the workload
# ---------------------------------------------------------------------------
#
#   kubectl -n kca58-lab run canary --image=registry.k8s.io/pause:3.9 \
#     --restart=Never --dry-run=server -o yaml | \
#     grep -A2 -E 'annotations:|limits:|env:'
#
# Expected:
#
#   annotations:
#     cost-center.acme.io/owner: platform-team
#   ...
#     env:
#     - name: COST_CENTER
#       value: platform-team
#   ...
#       limits:
#         memory: 256Mi
#
# ---------------------------------------------------------------------------
# STEP 3 — Recover the workload
# ---------------------------------------------------------------------------
#
# The ReplicaSet controller retries FailedCreate with exponential backoff, so
# the Deployment will self-heal, but not immediately. Force it:
#
#   kubectl -n kca58-lab rollout restart deploy/payments
#   kubectl -n kca58-lab rollout status deploy/payments --timeout=120s
#
# Expected:
#
#   deployment "payments" successfully rolled out
#
#   kubectl -n kca58-lab get pods -o custom-columns=\
#   NAME:.metadata.name,\
#   CC:.metadata.annotations.cost-center\\.acme\\.io/owner,\
#   MEM:.spec.containers[0].resources.limits.memory
#
#   NAME                        CC              MEM
#   payments-7c8d9f6b45-2q9xk   platform-team   256Mi
#   payments-7c8d9f6b45-8vlmq   platform-team   256Mi
#   payments-7c8d9f6b45-hd4pz   platform-team   256Mi
#
# Then grade:
#
#   ./kca-5.8-json-patches.sh --verify
#
# ---------------------------------------------------------------------------
# APPENDIX — the bonus manifest
# ---------------------------------------------------------------------------
#
#   kubectl apply -f ~/kca-5.8-json-patches/bonus-list-form.yaml
#
# Expected:
#
#   Error from server (BadRequest): error when creating "bonus-list-form.yaml":
#   ClusterPolicy in version "v1" cannot be handled as a ClusterPolicy:
#   json: cannot unmarshal array into Go struct field Mutation.spec.rules.mutate
#   .patchesJson6902 of type string
#
# `patchesJson6902` is typed as a STRING in the ClusterPolicy CRD, not as a
# list of operations. You must pass it as a YAML block scalar (|- or |). This
# is a schema rejection at the API server: no Kyverno evaluation happens at
# all, and the policy is never persisted. Recognising the difference between
# "the CRD rejected my policy" and "the patch failed at admission time" is
# half of troubleshooting mutations.
#
# ---------------------------------------------------------------------------
# WHAT TO REMEMBER FOR THE EXAM AND FOR PRODUCTION
# ---------------------------------------------------------------------------
#
# * patchesJson6902 is a STRING containing a YAML/JSON list of operations
#   {op, path, value}. Kyverno supports add, replace and remove.
# * JSON Pointer escaping: "/" -> ~1, "~" -> ~0. Dots are literal. Prefixed
#   Kubernetes keys therefore ALWAYS need ~1.
# * add     : parent must exist; on an existing member it REPLACES the value.
#   replace : the target itself must exist. It is not an upsert.
#   remove  : the target must exist, otherwise the whole patch errors.
# * "-" appends to an array that already exists. It never creates the array.
# * A JSON Patch is atomic: if operation N fails, none of 1..N-1 is applied,
#   and with failurePolicy: Fail the API request is denied outright.
# * Choose the patch type deliberately:
#     patchStrategicMerge — declarative, merges maps, creates missing parents,
#       understands Kubernetes list merge keys, supports Kyverno's conditional
#       anchors ()/+()/^(). Best default for "ensure this field looks like X".
#     patchesJson6902 — explicit, ordered, auditable operations, and the only
#       way to express positional array work or a true removal. Best when the
#       exact operation matters, or for CRs whose strategic-merge metadata the
#       API server does not publish (all CRDs: strategic merge is not supported
#       for custom resources, which is the main production reason to reach for
#       RFC 6902).
# * Scope with match/exclude and preconditions, never with a lucky document
#   shape. Test with --dry-run=server, and for large blast radius set
#   spec.validationFailureAction / rollout the policy in Audit-like fashion
#   first, then enforce.
# * mutate.foreach lets you patch every container instead of index 0 — the
#   hard-coded /spec/containers/0 used here is a lab simplification and is
#   wrong for multi-container Pods and sidecars.
#
# Sources:
#   https://kyverno.io/docs/writing-policies/mutate/
#   https://kyverno.io/docs/writing-policies/preconditions/
#   https://kyverno.io/docs/troubleshooting/
#   https://datatracker.ietf.org/doc/html/rfc6902
#   https://datatracker.ietf.org/doc/html/rfc6901
#   https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
#   https://github.com/cncf/curriculum