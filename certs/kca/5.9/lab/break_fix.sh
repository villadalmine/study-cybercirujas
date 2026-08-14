#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 5 · Topic 5.9: Autogen Rules            (exam weight: 2.91)
#  Break & Fix laboratory — auto-generated Pod controller rules
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#    It installs one namespaced-scoped Kyverno ClusterPolicy and three
#    workloads in a DISPOSABLE lab cluster, with autogen deliberately
#    sabotaged. The student must restore the intended admission behaviour.
#
#  WHERE TO RUN IT
#    A throw-away single-node cluster on a lab VM (k3s / kind / minikube /
#    Rancher Desktop) with Kyverno installed. NEVER on a shared or production
#    cluster: this script creates a ClusterPolicy object, which is a
#    cluster-scoped resource. The policy is deliberately restricted with
#    `match.any.resources.namespaces` so that only the lab namespace can ever
#    be affected, but the object itself is still cluster-scoped.
#
#  SUBCOMMANDS
#    break            create the lab and break it (default)
#    verify           grade the student's fix (exit 0 = solved)
#    hint             diagnostic commands, no spoilers
#    cleanup          remove every object this script created
#    install-kyverno  optional: install Kyverno on an empty lab cluster
#
#  REFERENCES
#    - KCA curriculum:   https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    - Kyverno docs:     https://kyverno.io/docs/
#      (Writing Policies > "Auto-Gen Rules for Pod Controllers":
#       https://kyverno.io/docs/writing-policies/autogen/)
#    - Kyverno source:   https://github.com/kyverno/kyverno
#    - Admission webhooks:
#      https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
# ============================================================================

set -Eeuo pipefail

readonly LAB_TITLE="KCA 5.9 — Autogen Rules"
readonly NS="kca59-autogen"
readonly POLICY="kca59-require-nonroot"
readonly RULE="check-runasnonroot"
readonly LAB_LABEL_KEY="kca-lab"
readonly LAB_LABEL_VAL="5.9"
readonly IMAGE="${LAB_IMAGE:-busybox:1.36}"

ASSUME_YES="${ASSUME_YES:-0}"
POLICY_VARIANT=""
LAST_DRYRUN=""
WORKDIR=""

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }
title(){ printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; hr; }

trap 'rc=$?; [[ $rc -ne 0 ]] && printf "\n%s[x]%s aborted at line %s (exit %s)\n" "$C_RED" "$C_OFF" "$LINENO" "$rc" >&2; exit $rc' ERR
trap '[[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

need_bin() { command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"; }

preflight() {
  need_bin kubectl
  kubectl cluster-info --request-timeout=10s >/dev/null 2>&1 \
    || die "no reachable cluster (check KUBECONFIG / current-context)"

  local ctx nodes
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  title "$LAB_TITLE — target cluster"
  printf '  context : %s\n  nodes   : %s\n  namespace to be created : %s\n' "$ctx" "$nodes" "$NS"

  case "$ctx" in
    *prod*|*prd*|*production*|*live*)
      warn "the context name looks like a PRODUCTION cluster" ;;
  esac

  if [[ "$ASSUME_YES" != "1" ]]; then
    printf '\nThis lab creates a cluster-scoped ClusterPolicy. Continue only on a\ndisposable lab cluster. Type %sBREAK%s to proceed: ' "$C_BLD" "$C_OFF"
    local answer=""
    read -r answer || true
    [[ "$answer" == "BREAK" ]] || die "aborted by the operator"
  fi
}

require_kyverno() {
  kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 \
    || die "Kyverno CRDs not found. Run: $0 install-kyverno"

  local ns dep
  ns="$(kubectl get deploy -A -l app.kubernetes.io/part-of=kyverno -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [[ -n "$ns" ]] || ns="kyverno"

  log "waiting for the Kyverno control plane in namespace '$ns'"
  for dep in $(kubectl get deploy -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl rollout status -n "$ns" "deploy/$dep" --timeout=180s >/dev/null 2>&1 \
      || warn "deployment $ns/$dep is not fully rolled out"
  done

  local img ver
  img="$(kubectl get deploy -n "$ns" -o jsonpath='{.items[*].spec.template.spec.containers[*].image}' 2>/dev/null | tr ' ' '\n' | grep -m1 kyverno || true)"
  ver="${img##*:}"
  log "Kyverno image in use: ${img:-unknown} (version ${ver:-unknown})"
}

install_kyverno() {
  need_bin kubectl
  if command -v helm >/dev/null 2>&1; then
    log "installing Kyverno with Helm"
    helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
    helm repo update >/dev/null
    # shellcheck disable=SC2086
    helm upgrade --install kyverno kyverno/kyverno \
      --namespace kyverno --create-namespace \
      ${KYVERNO_CHART_VERSION:+--version "$KYVERNO_CHART_VERSION"} \
      --wait --timeout 10m
  else
    log "helm not found, installing from the release manifest"
    # 'create' and not 'apply': the CRDs exceed the last-applied annotation limit.
    kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
    kubectl -n kyverno wait --for=condition=Available deploy --all --timeout=300s
  fi
  log "Kyverno installed"
}

# ---------------------------------------------------------------------------
# Manifest rendering
# ---------------------------------------------------------------------------

render_policy() {
  # $1 = broken|fixed   $2 = both|rule|spec   $3 = output file
  local mode="$1" variant="$2" out="$3"
  local autogen_annotation="" spec_action="" rule_action=""

  if [[ "$mode" == "broken" ]]; then
    # THE BREAK. 'none' tells Kyverno not to derive any Pod controller rule
    # from this Pod rule, so nothing guards Deployment/CronJob/... at all.
    autogen_annotation=$'\n    pod-policies.kyverno.io/autogen-controllers: "none"'
  fi

  # Kyverno moved the enforcement switch from spec.validationFailureAction
  # (<= 1.12) to spec.rules[].validate.failureAction (>= 1.13). Unknown CRD
  # fields are pruned silently, which would leave the policy in Audit and the
  # lab would never break, so the caller tries the variants until one of them
  # actually denies a Pod.
  case "$variant" in
    both) spec_action=$'\n  validationFailureAction: Enforce'
          rule_action=$'\n        failureAction: Enforce' ;;
    rule) rule_action=$'\n        failureAction: Enforce' ;;
    spec) spec_action=$'\n  validationFailureAction: Enforce' ;;
  esac

  cat >"$out" <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY}
  labels:
    ${LAB_LABEL_KEY}: "${LAB_LABEL_VAL}"
  annotations:
    policies.kyverno.io/title: Require runAsNonRoot (KCA 5.9 lab)
    policies.kyverno.io/category: Pod Security
    policies.kyverno.io/subject: Pod${autogen_annotation}
spec:${spec_action}
  background: true
  rules:
    - name: ${RULE}
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS}
      validate:${rule_action}
        message: >-
          Workloads in ${NS} must run as non-root:
          set spec.securityContext.runAsNonRoot=true
        pattern:
          spec:
            securityContext:
              runAsNonRoot: true
EOF
}

render_workload() {
  # $1 = name  $2 = kind(deploy|cronjob|pod)  $3 = compliant(yes|no)  $4 = out
  local name="$1" kind="$2" compliant="$3" out="$4"
  local sec="" pod_sec=""

  if [[ "$compliant" == "yes" ]]; then
    sec=$'\n          securityContext:\n            runAsNonRoot: true\n            runAsUser: 65534'
    pod_sec=$'\n  securityContext:\n    runAsNonRoot: true\n    runAsUser: 65534'
  fi

  case "$kind" in
    deploy)
      cat >"$out" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    app: ${name}
    ${LAB_LABEL_KEY}: "${LAB_LABEL_VAL}"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:${sec}
      containers:
        - name: app
          image: ${IMAGE}
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
EOF
      ;;
    cronjob)
      cat >"$out" <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    ${LAB_LABEL_KEY}: "${LAB_LABEL_VAL}"
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        metadata:
          labels:
            app: ${name}
        spec:${sec}
          restartPolicy: Never
          containers:
            - name: report
              image: ${IMAGE}
              command: ["sh", "-c", "echo nightly report; sleep 5"]
              resources:
                requests:
                  cpu: 10m
                  memory: 16Mi
EOF
      ;;
    pod)
      cat >"$out" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    ${LAB_LABEL_KEY}: "${LAB_LABEL_VAL}"
spec:${pod_sec}
  containers:
    - name: app
      image: ${IMAGE}
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
EOF
      ;;
  esac
}

render_all() {
  WORKDIR="$(mktemp -d -t kca59.XXXXXX)"
  cat >"$WORKDIR/ns.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    ${LAB_LABEL_KEY}: "${LAB_LABEL_VAL}"
EOF
  # Lab workloads (persisted in the cluster).
  render_workload legacy-api      deploy  no  "$WORKDIR/bad-deploy.yaml"
  render_workload good-api        deploy  yes "$WORKDIR/good-deploy.yaml"
  render_workload nightly-report  cronjob no  "$WORKDIR/bad-cronjob.yaml"
  # Probes (server-side dry-run only, never persisted). Distinct names so that
  # every probe is evaluated as a CREATE and not as an UPDATE.
  render_workload legacy-api-probe     deploy  no  "$WORKDIR/probe-bad-deploy.yaml"
  render_workload good-api-probe       deploy  yes "$WORKDIR/probe-good-deploy.yaml"
  render_workload nightly-report-probe cronjob no  "$WORKDIR/probe-bad-cronjob.yaml"
  render_workload rogue-pod-probe      pod     no  "$WORKDIR/probe-bad-pod.yaml"
}

# ---------------------------------------------------------------------------
# Admission helpers
# ---------------------------------------------------------------------------

dry_run_denied() {
  # returns 0 when the API server REJECTED the manifest
  if LAST_DRYRUN="$(kubectl apply -f "$1" --dry-run=server 2>&1)"; then
    return 1
  fi
  return 0
}

denied_by_policy() {
  dry_run_denied "$1" && grep -q "$POLICY" <<<"$LAST_DRYRUN"
}

wait_policy_ready() {
  local i state
  for i in $(seq 1 30); do
    state="$(kubectl get clusterpolicy "$POLICY" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.ready}' 2>/dev/null || true)"
    if [[ "$state" == *[Tt]rue* ]]; then
      sleep 3   # let the webhook configuration converge
      return 0
    fi
    sleep 2
  done
  sleep 5
  return 0
}

apply_policy() {
  # $1 = broken|fixed ; picks the schema variant that really enforces
  local mode="$1" variant
  for variant in both rule spec; do
    render_policy "$mode" "$variant" "$WORKDIR/policy.yaml"
    kubectl apply -f "$WORKDIR/policy.yaml" >/dev/null 2>&1 || continue
    wait_policy_ready
    if denied_by_policy "$WORKDIR/probe-bad-pod.yaml"; then
      POLICY_VARIANT="$variant"
      log "policy applied and enforcing (schema variant: $variant)"
      return 0
    fi
  done
  die "the policy never reached Enforce; check the Kyverno version and logs"
}

# ---------------------------------------------------------------------------
# break
# ---------------------------------------------------------------------------

do_break() {
  preflight
  require_kyverno
  render_all

  title "Building the lab"
  kubectl apply -f "$WORKDIR/ns.yaml" >/dev/null
  log "namespace $NS ready"

  apply_policy broken

  log "creating the non-compliant Deployment 'legacy-api'"
  kubectl apply -f "$WORKDIR/bad-deploy.yaml" >/dev/null \
    || die "the Deployment was rejected — the lab did not break as designed"

  log "creating the non-compliant CronJob 'nightly-report'"
  kubectl apply -f "$WORKDIR/bad-cronjob.yaml" >/dev/null \
    || die "the CronJob was rejected — the lab did not break as designed"

  log "creating the compliant Deployment 'good-api' (control workload)"
  kubectl apply -f "$WORKDIR/good-deploy.yaml" >/dev/null

  log "waiting ~40s for the ReplicaSet controller to hit the webhook"
  local i avail=""
  for i in $(seq 1 20); do
    avail="$(kubectl -n "$NS" get deploy legacy-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    [[ -z "$avail" || "$avail" == "0" ]] || break
    sleep 2
  done
  if [[ -n "$avail" && "$avail" != "0" ]]; then
    warn "legacy-api has $avail available replicas — the expected symptom did not appear"
  fi

  title "SYMPTOM — this is what you are looking at"
  kubectl -n "$NS" get deploy,rs,pod 2>/dev/null || true
  printf '\n'
  kubectl -n "$NS" describe rs -l app=legacy-api 2>/dev/null | sed -n '/Events:/,$p' | head -n 12 || true

  cat <<EOF

$(hr)
${C_BLD}WHAT YOU SHOULD SEE${C_OFF}

  * Deployment legacy-api  ->  READY 0/2, AVAILABLE 0, no Pods at all.
  * Its ReplicaSet reports repeated FailedCreate events:

      Warning  FailedCreate  ...  Error creating: admission webhook
      "validate.kyverno.svc-fail" denied the request:
      resource Pod/${NS}/legacy-api-xxxxxxxxx-yyyyy was blocked due to the
      following policies

      ${POLICY}:
        ${RULE}: 'validation error: Workloads in ${NS} must run as
          non-root: set spec.securityContext.runAsNonRoot=true'

  * CronJob nightly-report was accepted and fires every minute; each Job it
    creates fails the same way. Check it with:
        kubectl -n ${NS} get jobs
        kubectl -n ${NS} get events --sort-by=.lastTimestamp | tail -n 20

  * Deployment good-api is Ready. The policy itself is healthy.

${C_BLD}WHY THIS IS A PRODUCTION INCIDENT, NOT A COSMETIC ISSUE${C_OFF}

  'kubectl apply' returned success. The CI/CD pipeline is green. The user who
  shipped the Deployment saw no error at all — the rejection happens later,
  asynchronously, inside the controller-manager, where nobody is watching.
  Fail-fast at admission time on the object the human actually submits is the
  entire point of the feature that has been disabled here.

${C_BLD}YOUR MISSION${C_OFF}

  Make the very same violation be rejected AT CREATION TIME on the Deployment
  and on the CronJob themselves, so that 'kubectl apply' fails loudly.

  Constraints (a fix that violates any of these does not count):
    1. Do NOT hand-write extra rules for Deployment / CronJob / DaemonSet /
       StatefulSet / Job. Kyverno must derive them for you.
    2. Do NOT weaken the rule: same pattern, same message, still Enforce.
    3. Do NOT delete the policy and do NOT widen it beyond namespace ${NS}.
    4. good-api must remain admissible.

  Grade yourself:   $0 verify
  Stuck?            $0 hint
  Tear the lab down: $0 cleanup
$(hr)
EOF
}

# ---------------------------------------------------------------------------
# hint
# ---------------------------------------------------------------------------

do_hint() {
  cat <<EOF

$(hr)
${C_BLD}DIAGNOSTIC PATH (no spoilers)${C_OFF}

  1. Read the whole policy object, annotations included:
       kubectl get cpol ${POLICY} -o yaml

  2. Ask Kyverno which rules it is actually running, not which ones you wrote:
       kubectl get cpol ${POLICY} -o jsonpath='{.status.autogen.rules[*].name}'; echo
       kubectl get cpol ${POLICY} -o yaml | grep -n 'autogen'

  3. Ask the API server which resources the Kyverno webhook is registered for.
     If a kind is missing here, no policy can ever see it:
       kubectl get validatingwebhookconfiguration | grep kyverno
       kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \\
         -o jsonpath='{.webhooks[*].rules[*].resources}'; echo

  4. Reproduce admission without creating anything:
       kubectl -n ${NS} run probe --image=${IMAGE} --dry-run=server -- sleep 1
       kubectl apply -f <your-deployment.yaml> --dry-run=server

  5. Watch the admission controller reasoning in real time:
       kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50 -f

  Question to answer before touching anything: the Pod rule clearly works —
  so what is supposed to translate a Pod rule into a Deployment rule, and what
  in this policy is telling it not to?
$(hr)
EOF
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

PASS=0
FAIL=0
ok()  { printf '  %s[PASS]%s %s\n' "$C_GRN" "$C_OFF" "$1"; PASS=$((PASS+1)); }
bad() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$1"; FAIL=$((FAIL+1)); }

do_verify() {
  need_bin kubectl
  render_all

  title "$LAB_TITLE — grading"

  if ! kubectl get cpol "$POLICY" >/dev/null 2>&1; then
    bad "ClusterPolicy $POLICY exists (deleting it is not a fix)"
    printf '\n%sRESULT: FAIL%s (%s passed, %s failed)\n' "$C_RED" "$C_OFF" "$PASS" "$FAIL"
    exit 1
  fi
  ok "ClusterPolicy $POLICY still exists"

  local pol_yaml rule_names autogen_names action ns_match
  pol_yaml="$(kubectl get cpol "$POLICY" -o yaml)"
  rule_names="$(kubectl get cpol "$POLICY" -o jsonpath='{.spec.rules[*].name}')"
  autogen_names="$(kubectl get cpol "$POLICY" -o jsonpath='{.status.autogen.rules[*].name}' 2>/dev/null || true)"
  autogen_names="$autogen_names $rule_names"
  action="$(kubectl get cpol "$POLICY" -o jsonpath='{.spec.validationFailureAction} {.spec.rules[*].validate.failureAction}')"
  ns_match="$(kubectl get cpol "$POLICY" -o jsonpath='{.spec.rules[*].match.any[*].resources.namespaces[*]}')"

  grep -q 'runAsNonRoot' <<<"$pol_yaml" \
    && ok "the original validate pattern is intact (runAsNonRoot)" \
    || bad "the validate pattern was altered or removed"

  grep -qi 'enforce' <<<"$action" \
    && ok "the rule is still in Enforce (switching to Audit is not a fix)" \
    || bad "the rule is no longer Enforce"

  [[ "$ns_match" == *"$NS"* ]] \
    && ok "the policy is still scoped to namespace $NS" \
    || bad "the namespace scope was changed — the blast radius must stay in $NS"

  grep -qE "(^| )autogen-${RULE}( |$)" <<<"$autogen_names" \
    && ok "autogen rule for Pod controllers present: autogen-${RULE}" \
    || bad "no autogen-${RULE} rule — Deployments are still unguarded"

  grep -qE "(^| )autogen-cronjob-${RULE}( |$)" <<<"$autogen_names" \
    && ok "autogen rule for CronJob present: autogen-cronjob-${RULE}" \
    || bad "no autogen-cronjob-${RULE} rule — CronJobs are still unguarded"

  if denied_by_policy "$WORKDIR/probe-bad-deploy.yaml"; then
    ok "a non-compliant Deployment is rejected at admission time"
  else
    bad "a non-compliant Deployment is still ACCEPTED"
  fi

  if denied_by_policy "$WORKDIR/probe-bad-cronjob.yaml"; then
    ok "a non-compliant CronJob is rejected at admission time"
  else
    bad "a non-compliant CronJob is still ACCEPTED"
  fi

  if denied_by_policy "$WORKDIR/probe-bad-pod.yaml"; then
    ok "a bare non-compliant Pod is still rejected (rule not weakened)"
  else
    bad "a bare non-compliant Pod is now accepted — the rule was weakened"
  fi

  if dry_run_denied "$WORKDIR/probe-good-deploy.yaml"; then
    bad "a COMPLIANT Deployment is being rejected (false positive)"
    printf '        %s\n' "$LAST_DRYRUN"
  else
    ok "a compliant Deployment is still admitted (no false positives)"
  fi

  local avail
  avail="$(kubectl -n "$NS" get deploy good-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  [[ -n "$avail" && "$avail" != "0" ]] \
    && ok "the control workload good-api is still available ($avail replicas)" \
    || bad "good-api is not available — the fix broke a compliant workload"

  hr
  if [[ "$FAIL" -eq 0 ]]; then
    printf '%sRESULT: SOLVED%s — %s checks passed.\n' "$C_GRN" "$C_OFF" "$PASS"
    printf 'Autogen is restored: one Pod rule, seven guarded controller kinds.\n'
    exit 0
  fi
  printf '%sRESULT: NOT SOLVED%s — %s passed, %s failed. Run "%s hint".\n' \
    "$C_RED" "$C_OFF" "$PASS" "$FAIL" "$0"
  exit 1
}

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------

do_cleanup() {
  need_bin kubectl
  title "$LAB_TITLE — cleanup"
  kubectl delete clusterpolicy -l "${LAB_LABEL_KEY}=${LAB_LABEL_VAL}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete policy -A -l "${LAB_LABEL_KEY}=${LAB_LABEL_VAL}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  log "policy and namespace $NS removed (Kyverno itself was left installed)"
}

usage() {
  cat <<EOF
$LAB_TITLE — break & fix

Usage: $0 [break|verify|hint|cleanup|install-kyverno] [--yes]

  break            build the lab and break it (default)
  verify           grade the fix; exit 0 only when everything passes
  hint             diagnostic commands, no spoilers
  cleanup          delete the policy and the namespace
  install-kyverno  install Kyverno on an empty lab cluster

Environment:
  ASSUME_YES=1            skip the interactive confirmation
  LAB_IMAGE=<image>       workload image (default: busybox:1.36)
  KYVERNO_CHART_VERSION=  pin the Helm chart version on install
EOF
}

main() {
  local cmd="${1:-break}"
  [[ "${2:-}" == "--yes" || "${1:-}" == "--yes" ]] && ASSUME_YES=1
  case "$cmd" in
    break|--yes)       do_break ;;
    verify)            do_verify ;;
    hint)              do_hint ;;
    cleanup)           do_cleanup ;;
    install-kyverno)   install_kyverno ;;
    -h|--help|help)    usage ;;
    *)                 usage; exit 2 ;;
  esac
}

main "$@"

# ============================================================================
#  SOLUTION — do not read before attempting the lab
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  The ClusterPolicy carries this annotation:
#
#      metadata:
#        annotations:
#          pod-policies.kyverno.io/autogen-controllers: "none"
#
#  Kyverno's autogen feature normally reads any rule whose match block targets
#  ONLY the kind Pod and derives equivalent rules for the Pod controllers,
#  rewriting the JMESPath/pattern root as it goes:
#
#      Pod                      spec.<...>
#      Deployment/DaemonSet/    spec.template.spec.<...>       -> autogen-<rule>
#        StatefulSet/Job/
#        ReplicaSet/ReplicationController
#      CronJob                  spec.jobTemplate.spec.template.spec.<...>
#                                                              -> autogen-cronjob-<rule>
#
#  The value "none" switches that off. The Pod rule stays perfectly valid — it
#  is the reason the Pods get denied — but nothing evaluates the Deployment or
#  the CronJob, so both are admitted and the violation only surfaces later, in
#  the ReplicaSet/Job controller, as FailedCreate events nobody is watching.
#  Kyverno also derives its webhook registration from the matched kinds, so
#  with autogen off the resource webhook is not even registered for
#  apps/deployments or batch/cronjobs.
#
#  STEP BY STEP
#  ------------
#  1. Confirm the Pod rule works and the parent objects were admitted:
#
#       kubectl -n kca59-autogen get deploy,rs,pod
#       # deployment.apps/legacy-api   0/2   0   0
#       # replicaset.apps/legacy-api-6d4f8c9b7   2   0   0
#       # (no pods)
#
#       kubectl -n kca59-autogen describe rs -l app=legacy-api | sed -n '/Events:/,$p'
#       # Warning FailedCreate ... admission webhook "validate.kyverno.svc-fail"
#       # denied the request: ... kca59-require-nonroot: check-runasnonroot:
#       # 'validation error: Workloads in kca59-autogen must run as non-root...'
#
#     Reading: the policy is alive and enforcing. The failure is one level too
#     late. That combination — Pod denied, controller accepted — is the
#     signature of an autogen problem, not of a rule problem.
#
#  2. Prove that Kyverno is running no derived rules:
#
#       kubectl get cpol kca59-require-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
#       # (empty)
#
#     On a healthy policy this prints:
#       autogen-check-runasnonroot autogen-cronjob-check-runasnonroot
#
#  3. Find the switch:
#
#       kubectl get cpol kca59-require-nonroot -o yaml | grep -A6 'annotations:'
#       # pod-policies.kyverno.io/autogen-controllers: "none"
#
#  4. Fix it. Removing the annotation restores the default controller set,
#     which is what you want in almost every real cluster:
#
#       kubectl annotate cpol kca59-require-nonroot \
#         pod-policies.kyverno.io/autogen-controllers-
#
#     Equivalent, explicit form (use it only when you deliberately want a
#     narrower set; every kind you leave out stays unguarded):
#
#       kubectl annotate --overwrite cpol kca59-require-nonroot \
#         pod-policies.kyverno.io/autogen-controllers=DaemonSet,Deployment,Job,StatefulSet,ReplicaSet,ReplicationController,CronJob
#
#  5. Verify the derived rules exist and the webhook picked them up (allow a
#     few seconds for the webhook configuration to be rewritten):
#
#       kubectl get cpol kca59-require-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
#       # autogen-check-runasnonroot autogen-cronjob-check-runasnonroot
#
#       kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
#         -o jsonpath='{.webhooks[*].rules[*].resources}'; echo
#       # ... "deployments" ... "cronjobs" ... "pods" ...
#
#  6. Prove fail-fast without creating anything (server-side dry run executes
#     the admission chain, which is the cheapest way to test a policy against a
#     live cluster):
#
#       kubectl apply -f bad-deploy.yaml --dry-run=server
#       # Error from server: error when creating "bad-deploy.yaml": admission
#       # webhook "validate.kyverno.svc-fail" denied the request:
#       # resource Deployment/kca59-autogen/legacy-api was blocked due to the
#       # following policies
#       #
#       # kca59-require-nonroot:
#       #   autogen-check-runasnonroot: 'validation error: Workloads in
#       #     kca59-autogen must run as non-root...'
#
#     Note the rule name in the message: autogen-check-runasnonroot. That
#     prefix is how you tell a derived denial from a hand-written one when you
#     are reading someone else's incident ticket.
#
#  7. Clear the wreckage left by the broken state and re-run the grader:
#
#       kubectl -n kca59-autogen delete deploy legacy-api
#       kubectl -n kca59-autogen delete cronjob nightly-report
#       ./kca-5.9-autogen-breakfix.sh verify
#
#  WHAT THE EXAM EXPECTS YOU TO KNOW BEYOND THE FIX
#  ------------------------------------------------
#  * Autogen triggers only when the rule matches Pod and nothing else. Add a
#    non-Pod kind (ConfigMap, Service) to the same rule's match block and
#    Kyverno silently stops generating controller rules — same symptom,
#    different cause, and no annotation to point at. Split such rules.
#  * Derived rules are computed, not stored as authored content: you cannot
#    edit them, and editing the source rule regenerates them. They surface in
#    status.autogen.rules; older releases materialised them into spec.rules.
#  * "none" is legitimate in exactly two situations: a rule that must apply to
#    directly-created Pods only, and a policy where you hand-write the
#    controller logic because the derived path rewrite would be wrong.
#  * Autogen covers validate, mutate, generate and verifyImages rules, and the
#    CronJob variant carries its own prefix because it needs a second level of
#    template nesting.
#  * Autogen is an admission-time convenience. It does not change what the Pod
#    rule does, and it does not retroactively evict workloads that were already
#    running: for that you need the background scan and the resulting
#    PolicyReport / ClusterPolicyReport objects.
#  * Offline equivalent for CI, no cluster required:
#      kubectl kyverno apply policy.yaml --resource bad-deploy.yaml
#
#  REFERENCES
#  ----------
#  - Auto-Gen Rules for Pod Controllers — https://kyverno.io/docs/writing-policies/autogen/
#  - Kyverno documentation index      — https://kyverno.io/docs/
#  - Kyverno source                   — https://github.com/kyverno/kyverno
#  - KCA curriculum                   — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#  - Dynamic admission control        — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
# ============================================================================