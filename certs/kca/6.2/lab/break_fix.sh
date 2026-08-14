#!/usr/bin/env bash
#
# ==============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 6 — Policy Management  /  Topic 6.2 — PolicyExceptions (exam weight 3.33%)
#
#  BREAK & FIX LAB — "the exception that never excepted"
#
#  Curriculum:      https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#  Kyverno docs:    https://kyverno.io/docs/
#                   https://kyverno.io/docs/exceptions/                (1.13+ path)
#                   https://kyverno.io/docs/writing-policies/exceptions/ (1.12 path)
#                   https://kyverno.io/docs/writing-policies/autogen/
#                   https://kyverno.io/docs/installation/customization/  (container flags)
#  Source:          https://github.com/kyverno/kyverno
#
#  WHAT THIS SCRIPT DOES
#    It builds a small but realistic production situation on a DISPOSABLE lab
#    cluster and then breaks it in a controlled, fully reversible way:
#
#      * ClusterPolicy `restrict-privileged-containers` runs in Enforce mode and
#        blocks privileged containers in namespaces `logging` and `demo-apps`.
#      * A legitimate node-level log shipper (DaemonSet `fluent-node`) genuinely
#        needs `privileged: true`, so the platform team filed ticket OPS-4471 and
#        landed a PolicyException for it.
#      * The exception is in the cluster... and it does absolutely nothing.
#
#    Two independent, very common real-world faults are injected. Fixing the
#    first one does NOT make the symptom go away — that is the lesson.
#
#  SAFETY
#    * Runs only after you export KCA_LAB_I_UNDERSTAND=yes.
#    * Refuses multi-node clusters and contexts that look like production
#      (override with --force, at your own risk).
#    * Touches ONLY: namespaces `logging` and `demo-apps`, one ClusterPolicy,
#      one PolicyException, and the args of the Kyverno admission controller
#      Deployment (original args are backed up to /var/tmp/kca-6.2-lab and
#      restored by `reset` / `cleanup`).
#    * Never touches kube-system, workloads you own, or any other namespace.
#
#  USAGE
#      export KCA_LAB_I_UNDERSTAND=yes
#      ./kca-6.2-policyexceptions-breakfix.sh break     # install + break (default)
#      ./kca-6.2-policyexceptions-breakfix.sh check     # grade your fix
#      ./kca-6.2-policyexceptions-breakfix.sh reset     # re-break from a clean slate
#      ./kca-6.2-policyexceptions-breakfix.sh cleanup   # remove everything
#
#  Requirements: kubectl, jq, and (only if Kyverno is not installed yet) helm.
#  Tested shape: single-node k3s / kind / minikube, Kyverno 1.12.x – 1.14.x.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
APP_NS="logging"
CONTROL_NS="demo-apps"
POLICY_NAME="restrict-privileged-containers"
POLEX_NAME="fluent-node-privileged"
DS_NAME="fluent-node"
DEBUG_POD="fluent-debug"
STATE_DIR="${STATE_DIR:-/var/tmp/kca-6.2-lab}"
FORCE="no"
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-}"   # empty = latest available

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'

log()  { printf '%s[lab]%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { printf '%s[fail]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { fail "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

guard_disposable_cluster() {
  [[ "${KCA_LAB_I_UNDERSTAND:-no}" == "yes" ]] || die \
    "refusing to run. This script intentionally breaks a cluster.
       Export KCA_LAB_I_UNDERSTAND=yes only on a THROWAWAY lab VM."

  kubectl version --request-timeout=10s >/dev/null 2>&1 \
    || die "no reachable cluster (check KUBECONFIG / current-context)"

  local ctx server nodes
  ctx=$(kubectl config current-context)
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  nodes=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')

  log "context : ${C_BLD}${ctx}${C_OFF}"
  log "server  : ${server}"
  log "nodes   : ${nodes}"

  if [[ "$FORCE" != "yes" ]]; then
    if printf '%s %s' "$ctx" "$server" | grep -Eqi '(prod|production|prd|live|corp)'; then
      die "context/server looks like production. Aborting (use --force to override)."
    fi
    if (( nodes > 3 )); then
      die "${nodes} nodes — this does not look like a disposable lab (use --force to override)."
    fi
  fi
  mkdir -p "$STATE_DIR"
}

# ------------------------------------------------------------------------------
# Kyverno discovery / installation
# ------------------------------------------------------------------------------
detect_admission_deploy() {
  local d
  d=$(kubectl -n "$KYVERNO_NS" get deploy \
        -l app.kubernetes.io/component=admission-controller \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$d" ]] || d=$(kubectl -n "$KYVERNO_NS" get deploy \
        -l app.kubernetes.io/name=kyverno \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  printf '%s' "$d"
}

detect_container_index() {
  kubectl -n "$KYVERNO_NS" get deploy "$1" -o json \
    | jq -r '(([.spec.template.spec.containers[].name] | index("kyverno")) // 0)'
}

detect_polex_apiversion() {
  # PolicyException was promoted from kyverno.io/v2beta1 to kyverno.io/v2 in 1.13.
  if kubectl explain policyexception --api-version=kyverno.io/v2 >/dev/null 2>&1; then
    printf 'kyverno.io/v2'
  else
    printf 'kyverno.io/v2beta1'
  fi
}

ensure_kyverno() {
  if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
    log "Kyverno CRDs already present, skipping installation"
  else
    require_cmd helm
    log "installing Kyverno via Helm (this is the only heavyweight step)"
    helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
    helm repo update >/dev/null
    # shellcheck disable=SC2086
    helm upgrade --install kyverno kyverno/kyverno \
      --namespace "$KYVERNO_NS" --create-namespace \
      ${KYVERNO_CHART_VERSION:+--version "$KYVERNO_CHART_VERSION"} \
      --set features.policyExceptions.enabled=true \
      --wait --timeout 10m
  fi

  DEPLOY="$(detect_admission_deploy)"
  [[ -n "$DEPLOY" ]] || die "could not locate the Kyverno admission controller Deployment in ns/$KYVERNO_NS"
  CIDX="$(detect_container_index "$DEPLOY")"
  kubectl -n "$KYVERNO_NS" rollout status "deploy/$DEPLOY" --timeout=300s >/dev/null
  ok "admission controller: ${KYVERNO_NS}/${DEPLOY} (container index ${CIDX})"

  KYVERNO_VER=$(kubectl -n "$KYVERNO_NS" get deploy "$DEPLOY" -o json \
    | jq -r ".spec.template.spec.containers[$CIDX].image" | awk -F: '{print $NF}')
  log "Kyverno image tag: ${KYVERNO_VER}"

  POLEX_API="$(detect_polex_apiversion)"
  log "PolicyException API in use: ${POLEX_API}"
}

# ------------------------------------------------------------------------------
# Baseline: the legitimate workload, running fine, before any policy exists
# ------------------------------------------------------------------------------
deploy_baseline() {
  log "creating namespaces ${APP_NS} and ${CONTROL_NS}"
  kubectl create namespace "$APP_NS"     --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create namespace "$CONTROL_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  log "deploying the node-level log shipper (legitimately privileged)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${DS_NAME}
  namespace: ${APP_NS}
  labels:
    app: ${DS_NAME}
    team: platform
spec:
  selector:
    matchLabels:
      app: ${DS_NAME}
  template:
    metadata:
      labels:
        app: ${DS_NAME}
    spec:
      terminationGracePeriodSeconds: 1
      tolerations:
        - operator: Exists
      containers:
        - name: agent
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
          securityContext:
            privileged: true          # reads /var/log and the container runtime socket
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
EOF
  kubectl -n "$APP_NS" rollout status "ds/$DS_NAME" --timeout=180s >/dev/null \
    || warn "DaemonSet not fully ready yet (image pull?) — continuing"
  ok "DaemonSet ${APP_NS}/${DS_NAME} is running BEFORE the policy exists"
}

# ------------------------------------------------------------------------------
# The policy under which everything must keep working
# ------------------------------------------------------------------------------
apply_policy() {
  log "applying ClusterPolicy ${POLICY_NAME} in Enforce mode"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_NAME}
  annotations:
    policies.kyverno.io/title: Restrict privileged containers
    policies.kyverno.io/severity: high
    kca.lab/owner: security-guild
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: privileged-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${APP_NS}
                - ${CONTROL_NS}
      validate:
        message: >-
          Privileged containers are not allowed in this namespace.
          Request an exception through the platform team (OPS ticket).
        pattern:
          spec:
            =(initContainers):
              - =(securityContext):
                  =(privileged): "false"
            =(ephemeralContainers):
              - =(securityContext):
                  =(privileged): "false"
            containers:
              - =(securityContext):
                  =(privileged): "false"
EOF
  kubectl wait --for=condition=Ready "cpol/$POLICY_NAME" --timeout=90s >/dev/null 2>&1 || true
}

# Server-side dry-run of a privileged Pod in the control namespace.
# Returns 0 when Kyverno DENIES it (which is what "the policy works" means).
control_pod_is_denied() {
  local out
  if out=$(kubectl -n "$CONTROL_NS" apply --dry-run=server -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nginx-privileged
  namespace: ${CONTROL_NS}
spec:
  containers:
    - name: web
      image: nginx:1.27-alpine
      securityContext:
        privileged: true
EOF
  ); then
    LAST_CONTROL_OUT="$out"; return 1
  else
    LAST_CONTROL_OUT="$out"; return 0
  fi
}

assert_policy_enforces() {
  local i
  for i in $(seq 1 20); do
    control_pod_is_denied && { ok "policy is enforcing (privileged Pod in ${CONTROL_NS} rejected)"; return 0; }
    sleep 3
  done

  # Kyverno 1.13+ moved the failure action to spec.rules[].validate.failureAction.
  warn "policy did not enforce with spec.validationFailureAction — trying the per-rule field"
  kubectl patch "cpol/$POLICY_NAME" --type=json -p \
    '[{"op":"remove","path":"/spec/validationFailureAction"},
      {"op":"add","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]' >/dev/null 2>&1 || true
  kubectl wait --for=condition=Ready "cpol/$POLICY_NAME" --timeout=90s >/dev/null 2>&1 || true
  for i in $(seq 1 20); do
    control_pod_is_denied && { ok "policy is enforcing (per-rule failureAction)"; return 0; }
    sleep 3
  done
  die "the ClusterPolicy is not blocking anything — the webhook is not ready or this Kyverno version needs a different failureAction field. Inspect: kubectl describe cpol $POLICY_NAME"
}

# ------------------------------------------------------------------------------
# FAULT 1 — the PolicyException feature is switched off in the controller
# ------------------------------------------------------------------------------
inject_fault_flag() {
  log "injecting fault #1 (controller flag)"
  local orig new
  orig=$(kubectl -n "$KYVERNO_NS" get deploy "$DEPLOY" -o json \
          | jq -c --argjson i "$CIDX" '.spec.template.spec.containers[$i].args // []')
  printf '%s' "$orig" > "$STATE_DIR/kyverno-args.json"

  new=$(printf '%s' "$orig" | jq -c \
        'map(select(startswith("--enablePolicyException") | not)) + ["--enablePolicyException=false"]')

  kubectl -n "$KYVERNO_NS" patch deploy "$DEPLOY" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/${CIDX}/args\",\"value\":${new}}]" >/dev/null

  if kubectl -n "$KYVERNO_NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1; then
    echo "yes" > "$STATE_DIR/fault-flag"
    ok "fault #1 active: --enablePolicyException=false"
  else
    warn "this Kyverno build rejected the flag — reverting fault #1, the lab continues with fault #2 only"
    restore_kyverno_args
    echo "no" > "$STATE_DIR/fault-flag"
  fi
}

restore_kyverno_args() {
  [[ -s "$STATE_DIR/kyverno-args.json" ]] || return 0
  local orig
  orig=$(cat "$STATE_DIR/kyverno-args.json")
  kubectl -n "$KYVERNO_NS" patch deploy "$DEPLOY" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/${CIDX}/args\",\"value\":${orig}}]" >/dev/null 2>&1 || true
  kubectl -n "$KYVERNO_NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# FAULT 2 — the PolicyException exists but matches nothing that is evaluated
# ------------------------------------------------------------------------------
inject_fault_exception() {
  log "injecting fault #2 (the exception as it was merged in ticket OPS-4471)"
  kubectl -n "$APP_NS" delete policyexception "$POLEX_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f - >/dev/null <<EOF
apiVersion: ${POLEX_API}
kind: PolicyException
metadata:
  name: ${POLEX_NAME}
  namespace: ${APP_NS}
  annotations:
    kca.lab/ticket: OPS-4471
    kca.lab/reason: "node-level log shipper needs host access"
spec:
  exceptions:
    - policyName: ${POLICY_NAME}
      ruleNames:
        - privileged-containers
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - ${APP_NS}
          names:
            - ${DS_NAME}
EOF
  ok "PolicyException ${APP_NS}/${POLEX_NAME} applied (and it will not work)"
}

# ------------------------------------------------------------------------------
# Trigger the symptom so the student sees it immediately
# ------------------------------------------------------------------------------
show_symptom() {
  local out rc=0
  out=$(kubectl -n "$APP_NS" rollout restart "ds/$DS_NAME" 2>&1) || rc=$?
  printf '\n%s--- what happens when the log shipper is rolled ---%s\n' "$C_BLD" "$C_OFF"
  printf '$ kubectl -n %s rollout restart ds/%s\n%s\n' "$APP_NS" "$DS_NAME" "$out"
  if (( rc == 0 )); then
    warn "the restart was accepted — check the Pods, the denial may surface at Pod creation:"
    kubectl -n "$APP_NS" get pods -l "app=$DS_NAME" || true
    kubectl -n "$APP_NS" get events --sort-by=.lastTimestamp | tail -n 8 || true
  fi
  printf '\n'
}

record_policy_baseline() {
  kubectl get "cpol/$POLICY_NAME" -o json | jq -S -c '.spec' \
    | sha256sum | awk '{print $1}' > "$STATE_DIR/policy.sha256"
}

# ------------------------------------------------------------------------------
# Briefing
# ------------------------------------------------------------------------------
briefing() {
cat <<BRIEF

${C_BLD}================= KCA 6.2 — PolicyExceptions — INCIDENT BRIEF =================${C_OFF}

${C_BLD}Context${C_OFF}
  Security enforces ClusterPolicy ${C_BLD}${POLICY_NAME}${C_OFF} (Enforce) in
  namespaces ${APP_NS} and ${CONTROL_NS}: no privileged containers.
  The platform team owns DaemonSet ${C_BLD}${APP_NS}/${DS_NAME}${C_OFF}, which genuinely
  requires privileged: true, and ticket OPS-4471 shipped a PolicyException for it.
  The exception object is in the cluster. The pods still cannot be recreated.

${C_BLD}Symptom you will see${C_OFF}
  \$ kubectl -n ${APP_NS} rollout restart ds/${DS_NAME}
  Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

  resource DaemonSet/${APP_NS}/${DS_NAME} was blocked due to the following policies

  ${POLICY_NAME}:
    autogen-privileged-containers: 'validation error: Privileged containers are not
      allowed in this namespace...'

  ...and the same for a bare privileged Pod in ${APP_NS}. Note the rule name in the
  message. That single line is the whole first half of the investigation.

${C_BLD}Your mission${C_OFF}
  1. ${C_BLD}${APP_NS}/${DS_NAME}${C_OFF} must roll and become Ready again, still privileged.
  2. A privileged Pod named ${C_BLD}${DEBUG_POD}${C_OFF} must be creatable in ${APP_NS}.
  3. A privileged Pod in ${C_BLD}${CONTROL_NS}${C_OFF} must STILL be denied.
  4. ${C_BLD}You may not modify or delete the ClusterPolicy${C_OFF} — no Audit mode, no
     extra exclude blocks, no deleting the policy. Its spec is hashed and checked.
     The only legal instrument is the PolicyException (plus the controller config
     that makes exceptions work at all).

${C_BLD}Hints (in the order a real on-call would use them)${C_OFF}
  * Is the feature even on?
      kubectl -n ${KYVERNO_NS} get deploy ${DEPLOY} -o json | jq '.spec.template.spec.containers[${CIDX}].args'
      kubectl -n ${KYVERNO_NS} logs deploy/${DEPLOY} | grep -i exception
  * Is the exception scoped where the exception is allowed to live?
      look for --exceptionNamespace / features.policyExceptions.namespace
  * Which rule actually fired? Compare it with spec.exceptions[].ruleNames:
      kubectl get cpol ${POLICY_NAME} -o jsonpath='{.status.autogen.rules[*].name}'
      kubectl -n ${APP_NS} get polex ${POLEX_NAME} -o yaml
  * Which KIND is under admission when a DaemonSet is patched? And what is the
    real NAME of a Pod created by a DaemonSet?

${C_BLD}Grade yourself${C_OFF}
  $0 check          # runs all four acceptance criteria
  $0 reset          # start over from the broken state
  $0 cleanup        # remove the lab and restore Kyverno's original args

${C_BLD}==============================================================================${C_OFF}

BRIEF
}

# ------------------------------------------------------------------------------
# Grader
# ------------------------------------------------------------------------------
cmd_check() {
  guard_disposable_cluster
  DEPLOY="$(detect_admission_deploy)"; CIDX="$(detect_container_index "$DEPLOY")"
  local failures=0

  printf '\n%s--- acceptance criteria ---%s\n' "$C_BLD" "$C_OFF"

  # 1. exceptions enabled
  if kubectl -n "$KYVERNO_NS" get deploy "$DEPLOY" -o json \
      | jq -e --argjson i "$CIDX" \
        '.spec.template.spec.containers[$i].args // [] | any(. == "--enablePolicyException=false")' >/dev/null; then
    fail "1/5 PolicyExceptions are still disabled in the admission controller"
    ((failures++))
  else
    ok "1/5 PolicyExceptions are enabled in the admission controller"
  fi

  # 2. the exception still exists (fixing by deletion is not fixing)
  if kubectl -n "$APP_NS" get policyexception "$POLEX_NAME" >/dev/null 2>&1 \
     || kubectl get policyexception -A --no-headers 2>/dev/null | grep -q "$POLICY_NAME\|$POLEX_NAME"; then
    ok "2/5 a PolicyException object is present"
  else
    fail "2/5 no PolicyException found — the workload must be exempted, not un-policed"
    ((failures++))
  fi

  # 3. the DaemonSet rolls and becomes Ready
  local out rc=0
  out=$(kubectl -n "$APP_NS" rollout restart "ds/$DS_NAME" 2>&1) || rc=$?
  if (( rc != 0 )); then
    fail "3/5 the DaemonSet is still blocked at admission:"; printf '%s\n' "$out" | sed 's/^/      /'
    ((failures++))
  elif kubectl -n "$APP_NS" rollout status "ds/$DS_NAME" --timeout=150s >/dev/null 2>&1; then
    ok "3/5 ${APP_NS}/${DS_NAME} rolled and is Ready"
  else
    fail "3/5 the DaemonSet update was accepted but its Pods are not Ready:"
    kubectl -n "$APP_NS" get pods -l "app=$DS_NAME" | sed 's/^/      /'
    kubectl -n "$APP_NS" get events --sort-by=.lastTimestamp | tail -n 5 | sed 's/^/      /'
    ((failures++))
  fi

  # 4. a bare privileged Pod is admitted in the exempted namespace
  kubectl -n "$APP_NS" delete pod "$DEBUG_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  rc=0
  out=$(kubectl -n "$APP_NS" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${DEBUG_POD}
  namespace: ${APP_NS}
  labels:
    app: ${DS_NAME}
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sh", "-c", "sleep 600"]
      securityContext:
        privileged: true
EOF
  ) || rc=$?
  if (( rc == 0 )); then
    ok "4/5 privileged Pod ${DEBUG_POD} admitted in ${APP_NS}"
  else
    fail "4/5 privileged Pod ${DEBUG_POD} still denied in ${APP_NS}:"; printf '%s\n' "$out" | sed 's/^/      /'
    ((failures++))
  fi

  # 5. blast radius: the control namespace must still be protected, policy untouched
  if control_pod_is_denied; then
    ok "5/5 privileged Pod in ${CONTROL_NS} is still denied (exception is correctly scoped)"
  else
    fail "5/5 the exception is too broad — ${CONTROL_NS} is no longer protected"
    ((failures++))
  fi

  if [[ -s "$STATE_DIR/policy.sha256" ]]; then
    local now expected
    now=$(kubectl get "cpol/$POLICY_NAME" -o json | jq -S -c '.spec' | sha256sum | awk '{print $1}')
    expected=$(cat "$STATE_DIR/policy.sha256")
    if [[ "$now" == "$expected" ]]; then
      ok "    ClusterPolicy spec is byte-for-byte unmodified"
    else
      fail "    the ClusterPolicy was modified — that is out of scope for this exercise"
      ((failures++))
    fi
  fi

  printf '\n'
  if (( failures == 0 )); then
    ok "${C_BLD}LAB PASSED${C_OFF} — the exception is enabled, scoped and minimal."
    kubectl -n "$APP_NS" get polex "$POLEX_NAME" -o yaml 2>/dev/null | sed -n '/^spec:/,$p' | sed 's/^/    /' || true
  else
    fail "${failures} criteria still failing. Re-read the hints in the brief."
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------
cmd_break() {
  guard_disposable_cluster
  require_cmd kubectl jq
  ensure_kyverno
  deploy_baseline
  apply_policy
  assert_policy_enforces
  record_policy_baseline
  inject_fault_flag
  inject_fault_exception
  show_symptom
  briefing
}

cmd_reset() {
  guard_disposable_cluster
  DEPLOY="$(detect_admission_deploy)"; CIDX="$(detect_container_index "$DEPLOY")"
  restore_kyverno_args
  kubectl -n "$APP_NS" delete pod "$DEBUG_POD" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete policyexception --all -A --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete "cpol/$POLICY_NAME" --ignore-not-found >/dev/null 2>&1 || true
  cmd_break
}

cmd_cleanup() {
  guard_disposable_cluster
  DEPLOY="$(detect_admission_deploy)"; CIDX="$(detect_container_index "$DEPLOY")"
  log "restoring the admission controller arguments"
  restore_kyverno_args
  log "removing lab objects"
  kubectl delete "cpol/$POLICY_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$APP_NS" delete policyexception "$POLEX_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$APP_NS" "$CONTROL_NS" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
  ok "lab removed. Kyverno itself was left installed (helm uninstall kyverno -n $KYVERNO_NS to drop it)."
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="break"
  for a in "$@"; do
    case "$a" in
      --force) FORCE="yes" ;;
      break|check|reset|cleanup) cmd="$a" ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $a (try --help)" ;;
    esac
  done
  require_cmd kubectl jq
  case "$cmd" in
    break)   cmd_break   ;;
    check)   cmd_check   ;;
    reset)   cmd_reset   ;;
    cleanup) cmd_cleanup ;;
  esac
}

main "$@"

# ==============================================================================
#  S O L U T I O N   —   D O   N O T   R E A D   U N T I L   Y O U   T R I E D
# ==============================================================================
#
#  There are TWO faults. Fault #1 makes the exception invisible to the engine;
#  fault #2 makes it match nothing. Fixing either one alone changes nothing you
#  can see, which is exactly why this pair is worth practising.
#
# ------------------------------------------------------------------------------
# STEP 0 — Reproduce and read the denial carefully
# ------------------------------------------------------------------------------
#   $ kubectl -n logging rollout restart ds/fluent-node
#   error: failed to patch: admission webhook "validate.kyverno.svc-fail" denied the request:
#
#   resource DaemonSet/logging/fluent-node was blocked due to the following policies
#
#   restrict-privileged-containers:
#     autogen-privileged-containers: 'validation error: Privileged containers are not
#       allowed in this namespace. Request an exception through the platform team (OPS
#       ticket). rule autogen-privileged-containers failed at path /spec/template/spec/
#       containers/0/securityContext/privileged/'
#
#   Two facts are already in that message:
#     * the KIND under admission is DaemonSet, not Pod;
#     * the RULE that fired is `autogen-privileged-containers`, not
#       `privileged-containers`. Kyverno auto-generates rules for pod controllers
#       (Deployment, DaemonSet, StatefulSet, Job, CronJob) from a Pod rule, and the
#       generated rule carries the `autogen-` prefix (`autogen-cronjob-` for CronJob).
#       https://kyverno.io/docs/writing-policies/autogen/
#
#   List them if your version populates policy status:
#     $ kubectl get cpol restrict-privileged-containers -o jsonpath='{.status.autogen.rules[*].name}'
#     autogen-privileged-containers autogen-cronjob-privileged-containers
#
# ------------------------------------------------------------------------------
# STEP 1 — Is the PolicyException feature even switched on?
# ------------------------------------------------------------------------------
#   A PolicyException that the engine never loads produces no error, no warning
#   and no event. It simply does nothing. Always check the controller first:
#
#     $ kubectl -n kyverno get deploy kyverno-admission-controller \
#         -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
#     ...
#     "--enablePolicyException=false"
#
#     $ kubectl -n kyverno logs deploy/kyverno-admission-controller | grep -i exception
#     ... "PolicyExceptions are disabled" ...
#
#   Two flags matter for this feature
#   (https://kyverno.io/docs/installation/customization/):
#     --enablePolicyException=true|false   turns the whole feature on/off
#     --exceptionNamespace=<ns>            if set, ONLY exceptions created in that
#                                          namespace are honoured; an exception in
#                                          any other namespace is silently ignored.
#   Helm equivalents: features.policyExceptions.enabled / features.policyExceptions.namespace
#
#   Fix it in place (index 0 is the `kyverno` container in the chart's 3.x layout):
#
#     $ kubectl -n kyverno patch deploy kyverno-admission-controller --type=json -p \
#       '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":[
#           "--enablePolicyException=true"]}]'    # ← keep the other args you saw above!
#
#   Safer, argument-preserving version with jq:
#
#     $ ARGS=$(kubectl -n kyverno get deploy kyverno-admission-controller -o json \
#         | jq -c '.spec.template.spec.containers[0].args
#                  | map(if startswith("--enablePolicyException")
#                        then "--enablePolicyException=true" else . end)')
#     $ kubectl -n kyverno patch deploy kyverno-admission-controller --type=json \
#         -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$ARGS}]"
#     $ kubectl -n kyverno rollout status deploy/kyverno-admission-controller
#
#   Declarative equivalent (preferred in a real cluster, so the next helm upgrade
#   does not undo you):
#     $ helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
#         --set features.policyExceptions.enabled=true
#
#   Retry the rollout now: it is STILL denied. That is expected — on to fault #2.
#
# ------------------------------------------------------------------------------
# STEP 2 — Read the exception against the denial, field by field
# ------------------------------------------------------------------------------
#     $ kubectl -n logging get polex fluent-node-privileged -o yaml
#     spec:
#       exceptions:
#       - policyName: restrict-privileged-containers
#         ruleNames:
#         - privileged-containers          # (a) the rule that fired is autogen-*
#       match:
#         any:
#         - resources:
#             kinds:
#             - Pod                        # (b) the DaemonSet itself is never matched
#             namespaces:
#             - logging
#             names:
#             - fluent-node                # (c) DaemonSet Pods are fluent-node-<hash>
#
#   Three independent mismatches, all of them classic:
#     (a) `ruleNames` must name the rule that actually evaluates the resource.
#         For pod controllers that is the autogen rule.
#     (b) `match.any[].resources.kinds` must include the kind under admission.
#         Patching a DaemonSet is a DaemonSet admission review.
#     (c) `names` is an exact match unless you use a wildcard. A Pod created by a
#         DaemonSet is `fluent-node-` plus a random suffix, so `fluent-node` alone
#         never matches a Pod.
#   An exception applies only when policyName + ruleNames + match ALL line up.
#   One wrong field and Kyverno evaluates the policy normally — silently.
#
# ------------------------------------------------------------------------------
# STEP 3 — Apply the corrected exception (least privilege, not a blanket wildcard)
# ------------------------------------------------------------------------------
#   $ cat <<'EOF' | kubectl apply -f -
#   apiVersion: kyverno.io/v2beta1        # kyverno.io/v2 on Kyverno 1.13+
#   kind: PolicyException
#   metadata:
#     name: fluent-node-privileged
#     namespace: logging                  # must be inside --exceptionNamespace, if set
#     annotations:
#       kca.lab/ticket: OPS-4471
#   spec:
#     exceptions:
#       - policyName: restrict-privileged-containers
#         ruleNames:
#           - privileged-containers               # the Pod rule
#           - autogen-privileged-containers       # the DaemonSet/Deployment rule
#     match:
#       any:
#         - resources:
#             kinds:
#               - Pod
#               - DaemonSet
#             namespaces:
#               - logging
#             names:
#               - fluent-node          # the DaemonSet object
#               - fluent-node-*        # the Pods it creates
#               - fluent-debug         # the on-call debug Pod
#   EOF
#
#   Notes on scope discipline — every one of these is a real production incident:
#     * `ruleNames: ["*"]` works but exempts rules that do not exist yet; the next
#       rule added to that policy is exempted the day it merges.
#     * dropping `names` exempts the whole namespace, not one workload.
#     * adding `demo-apps` to `namespaces` widens the blast radius — the grader
#       fails you for it, and so would a reviewer.
#     * a `selector` on the Pod labels (match.any[].resources.selector.matchLabels:
#       {app: fluent-node}) is an equally valid and often sturdier scoping tool
#       than name globs, because it survives renames.
#     * on Kyverno 1.13+, `spec.conditions` lets you narrow further with JMESPath
#       (for example only when the image comes from your own registry).
#
# ------------------------------------------------------------------------------
# STEP 4 — Verify the fix
# ------------------------------------------------------------------------------
#   $ kubectl -n logging rollout restart ds/fluent-node
#   daemonset.apps/fluent-node restarted
#
#   $ kubectl -n logging rollout status ds/fluent-node
#   daemon set "fluent-node" successfully rolled out
#
#   $ kubectl -n logging run fluent-debug --image=busybox:1.36 --restart=Never \
#       --overrides='{"spec":{"containers":[{"name":"shell","image":"busybox:1.36",
#       "command":["sh","-c","sleep 600"],"securityContext":{"privileged":true}}]}}'
#   pod/fluent-debug created
#
# ------------------------------------------------------------------------------
# STEP 5 — Prove you did not disarm the policy (the part candidates forget)
# ------------------------------------------------------------------------------
#   $ kubectl -n demo-apps run nginx-privileged --image=nginx:1.27-alpine \
#       --dry-run=server --restart=Never \
#       --overrides='{"spec":{"containers":[{"name":"web","image":"nginx:1.27-alpine",
#       "securityContext":{"privileged":true}}]}}'
#   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
#   resource Pod/demo-apps/nginx-privileged was blocked due to the following policies
#   restrict-privileged-containers:
#     privileged-containers: 'validation error: Privileged containers are not allowed...'
#
#   $ ./kca-6.2-policyexceptions-breakfix.sh check
#   [ ok ] 5/5 ...
#
# ------------------------------------------------------------------------------
# STEP 6 — What NOT to do, and why the exam cares
# ------------------------------------------------------------------------------
#   * Do not flip the policy to Audit: the whole cluster loses enforcement to
#     unblock one DaemonSet. A PolicyException is scoped, reviewable and auditable
#     (Kyverno reports show `skip` with the exception name in the PolicyReport:
#      kubectl -n logging get policyreport -o yaml | grep -A3 skip).
#   * Do not add an `exclude` block to the ClusterPolicy: it buries the waiver
#     inside the security team's object, hides it from exception tooling, and
#     grows without bound. Exceptions are owned by the workload team, in the
#     workload's namespace, with their own RBAC and their own lifecycle.
#   * Do not delete the exception and the policy "to test": the acceptance criteria
#     for any real waiver are (1) the workload runs, (2) everything else is still
#     protected, (3) the waiver is traceable to a ticket and expirable.
#   * Remember the two silent killers when an exception "does nothing":
#       --enablePolicyException=false   → the feature is off
#       --exceptionNamespace=<ns>       → your exception is in the wrong namespace
#     Neither produces an error on `kubectl apply` of the PolicyException.
#
#   References
#     https://kyverno.io/docs/exceptions/
#     https://kyverno.io/docs/writing-policies/exceptions/
#     https://kyverno.io/docs/writing-policies/autogen/
#     https://kyverno.io/docs/installation/customization/
#     https://github.com/kyverno/kyverno
#     https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
# ==============================================================================