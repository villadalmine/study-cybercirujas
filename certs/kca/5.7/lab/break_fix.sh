#!/usr/bin/env bash
#
# =============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 5 · Topic 5.7 — Variables & API Calls in Policies (exam weight 2.91)
#
#  BREAK & FIX laboratory. Runs ONLY against a disposable cluster (kind, k3d,
#  minikube, docker-desktop) unless you explicitly override the safety guard.
#
#  What this lab teaches
#  ---------------------
#  A Kyverno rule that reaches outside the AdmissionReview payload has three
#  independent failure surfaces, and each one produces a completely different
#  symptom:
#
#    (a) RBAC          — the Kyverno *admission controller* ServiceAccount must
#                        be granted read access to whatever the `apiCall` reads.
#                        Kyverno ships aggregated ClusterRoles precisely so that
#                        you can extend them; CRDs created after install are
#                        NEVER covered by the defaults.
#    (b) JMESPath type  — `spec.active=='true'` (string) does not match a JSON
#                        boolean. The context resolves to `[]` and the policy
#                        fails *closed*, denying everything.
#    (c) Missing default— a variable that resolves to null aborts the rule with
#                        a substitution error instead of your clean message.
#
#  Official references
#    - Variables:          https://kyverno.io/docs/writing-policies/variables/
#    - External data:      https://kyverno.io/docs/writing-policies/external-data-sources/
#    - JMESPath in Kyverno:https://kyverno.io/docs/writing-policies/jmespath/
#    - Customize RBAC:     https://kyverno.io/docs/installation/customization/
#    - Aggregated roles:   https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles
#    - JMESPath spec:      https://jmespath.org/specification.html
#    - KCA curriculum:     https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#
#  Usage
#    ./kca-5.7-break-fix.sh setup      # break the cluster and print the briefing
#    ./kca-5.7-break-fix.sh verify     # grade your fix (this is the exam)
#    ./kca-5.7-break-fix.sh hint [1-3] # progressive hints
#    ./kca-5.7-break-fix.sh status     # show lab objects + Kyverno errors
#    ./kca-5.7-break-fix.sh cleanup    # remove every object this lab created
#
#  The full step-by-step solution is at the bottom of this file, commented out.
#  Do not read it until `verify` has beaten you at least twice.
# =============================================================================

set -euo pipefail

# ----------------------------- configuration --------------------------------
LAB_NS="${LAB_NS:-kca-lab}"
POLICY_NAME="kca-5-7-team-registry"
CRD_NAME="teams.kca.example.com"
CRD_GROUP="kca.example.com"
CRD_VERSION="v1alpha1"
TEAM_LABEL="kca.example.com/team"
PROBE_IMAGE="${PROBE_IMAGE:-busybox:1.36}"
DENY_MSG_SNIPPET="must name a registered active Team"
SOLUTION_CLUSTERROLE="kca-lab-kyverno-teams-reader"
KYVERNO_NS=""
KYVERNO_SA=""
KYVERNO_VER=""
FAILURE_MODE=""      # "spec" (<=1.12) or "rule" (>=1.13)
PROBE_OUT=""
PROBE_RC=0

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[i]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

# --------------------------- safety / preflight -----------------------------

assert_tools() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version -o json >/dev/null 2>&1 \
    || kubectl cluster-info >/dev/null 2>&1 \
    || die "No reachable Kubernetes API server for the current context."
}

assert_disposable_cluster() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  info "Current kubectl context: ${C_BLD}${ctx}${C_OFF}"

  if [[ "${KCA_LAB_I_KNOW_WHAT_IM_DOING:-0}" == "1" ]]; then
    warn "Safety guard bypassed via KCA_LAB_I_KNOW_WHAT_IM_DOING=1."
    return 0
  fi

  case "$ctx" in
    kind-*|k3d-*|minikube|docker-desktop|rancher-desktop|kubernetes-admin@kind*) ;;
    *)
      die "Context '${ctx}' does not look like a disposable lab cluster.
    This lab installs a CRD, a cluster-wide Kyverno policy in Enforce mode and
    will BLOCK Pod creation in namespace '${LAB_NS}'.
    Re-run against kind/k3d/minikube, or export KCA_LAB_I_KNOW_WHAT_IM_DOING=1."
      ;;
  esac
}

confirm_break() {
  [[ "${1:-}" == "--yes" || "${KCA_LAB_ASSUME_YES:-0}" == "1" ]] && return 0
  printf '%s' "Type BREAK to arm the lab: "
  local answer; read -r answer
  [[ "$answer" == "BREAK" ]] || die "Aborted by user."
}

discover_kyverno() {
  KYVERNO_NS="$(kubectl get deploy -A -o jsonpath='{range .items[?(@.metadata.name=="kyverno-admission-controller")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  if [[ -z "$KYVERNO_NS" ]]; then
    KYVERNO_NS="$(kubectl get deploy -A -o jsonpath='{range .items[?(@.metadata.name=="kyverno")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$KYVERNO_NS" ]] || die "Kyverno is not installed.
    Install it first, e.g.:
      kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.13.4/install.yaml
      kubectl -n kyverno rollout status deploy/kyverno-admission-controller"

  local dep="kyverno-admission-controller"
  kubectl -n "$KYVERNO_NS" get deploy "$dep" >/dev/null 2>&1 || dep="kyverno"

  KYVERNO_SA="$(kubectl -n "$KYVERNO_NS" get deploy "$dep" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
  [[ -n "$KYVERNO_SA" ]] || KYVERNO_SA="kyverno-admission-controller"

  local img; img="$(kubectl -n "$KYVERNO_NS" get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  KYVERNO_VER="$(printf '%s' "$img" | sed -n 's/.*:v\{0,1\}\([0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/p')"

  FAILURE_MODE="spec"
  if [[ -n "$KYVERNO_VER" ]]; then
    local maj="${KYVERNO_VER%%.*}" min="${KYVERNO_VER##*.}"
    if [[ "$maj" -gt 1 || ( "$maj" -eq 1 && "$min" -ge 13 ) ]]; then
      FAILURE_MODE="rule"
    fi
  fi

  kubectl -n "$KYVERNO_NS" rollout status "deploy/$dep" --timeout=120s >/dev/null 2>&1 \
    || warn "Kyverno deployment $dep is not fully rolled out; continuing anyway."

  info "Kyverno namespace ......... $KYVERNO_NS"
  info "Admission ServiceAccount .. $KYVERNO_SA"
  info "Kyverno version ........... ${KYVERNO_VER:-unknown} (failureAction placement: $FAILURE_MODE)"
}

# ------------------------------ lab artifacts -------------------------------

emit_crd() {
  cat <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: teams.kca.example.com
  labels:
    kca.example.com/lab: "5.7"
spec:
  group: kca.example.com
  scope: Cluster
  names:
    plural: teams
    singular: team
    kind: Team
    shortNames:
      - tm
  versions:
    - name: v1alpha1
      served: true
      storage: true
      additionalPrinterColumns:
        - name: Display Name
          type: string
          jsonPath: .spec.displayName
        - name: Active
          type: boolean
          jsonPath: .spec.active
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required:
                - displayName
                - active
              properties:
                displayName:
                  type: string
                active:
                  type: boolean
                costCenter:
                  type: string
YAML
}

emit_teams() {
  cat <<'YAML'
apiVersion: kca.example.com/v1alpha1
kind: Team
metadata:
  name: platform
  labels:
    kca.example.com/lab: "5.7"
spec:
  displayName: Platform Engineering
  active: true
  costCenter: CC-1001
---
apiVersion: kca.example.com/v1alpha1
kind: Team
metadata:
  name: payments
  labels:
    kca.example.com/lab: "5.7"
spec:
  displayName: Payments
  active: true
  costCenter: CC-2044
---
apiVersion: kca.example.com/v1alpha1
kind: Team
metadata:
  name: legacy
  labels:
    kca.example.com/lab: "5.7"
spec:
  displayName: Legacy Billing (decommissioned)
  active: false
  costCenter: CC-0000
YAML
}

# The BROKEN policy. Three independent defects are planted here on purpose:
#   FAULT-1  the apiCall reads a CRD nobody granted Kyverno access to
#   FAULT-2  spec.active=='true' compares a JSON boolean against a string
#   FAULT-3  the label lookup has no default, so a Pod without the label
#            aborts the rule with a substitution error
emit_policy() {
  local spec_fa rule_fa
  if [[ "$FAILURE_MODE" == "rule" ]]; then
    spec_fa="# failureAction is declared per rule (Kyverno >= 1.13)"
    rule_fa="failureAction: Enforce"
  else
    spec_fa="validationFailureAction: Enforce"
    rule_fa="# validationFailureAction is declared at spec level (Kyverno <= 1.12)"
  fi

  cat <<'YAML' | sed -e "s|__LAB_NS__|${LAB_NS}|g" \
                     -e "s|__SPEC_FAILURE_ACTION__|${spec_fa}|" \
                     -e "s|__RULE_FAILURE_ACTION__|${rule_fa}|"
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: kca-5-7-team-registry
  labels:
    kca.example.com/lab: "5.7"
  annotations:
    policies.kyverno.io/title: Pods must reference a registered, active Team
    policies.kyverno.io/category: Governance
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      The set of valid teams is not hardcoded: it is read at admission time from
      the cluster-scoped Team custom resources through a Kyverno API call.
spec:
  __SPEC_FAILURE_ACTION__
  background: false
  rules:
    - name: pod-team-must-be-registered
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - __LAB_NS__
      context:
        - name: activeteams
          apiCall:
            urlPath: "/apis/kca.example.com/v1alpha1/teams"
            jmesPath: "items[?spec.active=='true'].metadata.name"
      validate:
        __RULE_FAILURE_ACTION__
        message: >-
          Pod label kca.example.com/team must name a registered active Team.
          Got '{{ request.object.metadata.labels."kca.example.com/team" }}'.
          Registered active teams: {{ activeteams }}
        deny:
          conditions:
            all:
              - key: '{{ request.object.metadata.labels."kca.example.com/team" }}'
                operator: AnyNotIn
                value: "{{ activeteams }}"
YAML
}

apply_policy() {
  local out
  if out="$(emit_policy | kubectl apply -f - 2>&1)"; then
    say "$out"
    return 0
  fi
  warn "Apply failed with failureAction placement '$FAILURE_MODE'; retrying with the other placement."
  say "$out"
  if [[ "$FAILURE_MODE" == "rule" ]]; then FAILURE_MODE="spec"; else FAILURE_MODE="rule"; fi
  emit_policy | kubectl apply -f - || die "Could not apply the lab policy. Is the Kyverno webhook healthy?"
}

# ------------------------------- probes -------------------------------------

probe() {
  # $1 = pod name, $2 = value for the team label ("" means: create it unlabelled)
  local name="$1" team="${2:-}"
  local -a cmd
  if [[ -n "$team" ]]; then
    cmd=(kubectl run "$name" --image="$PROBE_IMAGE" --restart=Never
         --namespace "$LAB_NS" --labels="${TEAM_LABEL}=${team}"
         --dry-run=server -o name --command -- sleep 3600)
  else
    cmd=(kubectl run "$name" --image="$PROBE_IMAGE" --restart=Never
         --namespace "$LAB_NS"
         --dry-run=server -o name --command -- sleep 3600)
  fi
  set +e
  PROBE_OUT="$("${cmd[@]}" 2>&1)"
  PROBE_RC=$?
  set -e
}

# ------------------------------- setup --------------------------------------

do_setup() {
  assert_tools
  assert_disposable_cluster
  confirm_break "${1:-}"
  discover_kyverno

  rule
  info "Staging the lab..."
  kubectl create namespace "$LAB_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$LAB_NS" kca.example.com/lab=5.7 --overwrite >/dev/null

  emit_crd | kubectl apply -f - >/dev/null
  kubectl wait --for=condition=Established "crd/${CRD_NAME}" --timeout=60s >/dev/null
  emit_teams | kubectl apply -f - >/dev/null
  ok "CRD ${CRD_NAME} established, 3 Team objects created."

  apply_policy >/dev/null
  kubectl wait --for=condition=Ready "clusterpolicy/${POLICY_NAME}" --timeout=90s >/dev/null 2>&1 \
    || warn "ClusterPolicy did not report Ready=True. That is part of the puzzle, keep going."
  ok "ClusterPolicy ${POLICY_NAME} applied in Enforce mode."

  rule
  info "Reproducing the symptom for you (server-side dry-run, nothing is persisted):"
  say ""
  say "  \$ kubectl run demo --image=${PROBE_IMAGE} -n ${LAB_NS} --labels=${TEAM_LABEL}=platform --dry-run=server --command -- sleep 3600"
  probe "demo" "platform"
  say ""
  printf '%s%s%s\n' "$C_RED" "$PROBE_OUT" "$C_OFF"
  say ""

  print_briefing
}

print_briefing() {
  rule
  printf '%s KCA 5.7 — Variables & API Calls in Policies — BREAK & FIX %s\n' "$C_BLD" "$C_OFF"
  rule
  cat <<EOF

SCENARIO
  A platform team replaced a hardcoded allow-list with a live one. The set of
  valid teams now lives in cluster-scoped ${CRD_GROUP} Team custom resources,
  and the ClusterPolicy '${POLICY_NAME}' reads them at admission
  time with a Kyverno context of type 'apiCall'. Every Pod in namespace
  '${LAB_NS}' must carry the label:

      ${TEAM_LABEL}=<name of an ACTIVE Team>

  The registry:

$(kubectl get teams -o custom-columns='NAME:.metadata.name,ACTIVE:.spec.active,DISPLAY:.spec.displayName' --no-headers 2>/dev/null | sed 's/^/      /')

SYMPTOM YOU WILL SEE
  Right now NOTHING can be created in '${LAB_NS}' — not even a Pod carrying a
  perfectly valid team label. The API server returns an admission webhook
  error coming from Kyverno's validating webhook, and the text of that error
  changes as you repair each layer. Read it every single time: the error is
  the instrument, not the noise.

  You will walk through three distinct error shapes:
    1. an RBAC 'forbidden' error naming ServiceAccount '${KYVERNO_SA}'
    2. a clean policy denial that nevertheless reports 'Registered active
       teams: []' although two Teams are active
    3. a variable-substitution error for Pods that carry no team label at all

YOUR MISSION
  Make the policy behave exactly as intended, without weakening it:

    [ ] a Pod labelled ${TEAM_LABEL}=platform  is ADMITTED
    [ ] a Pod labelled ${TEAM_LABEL}=ghost     is DENIED
    [ ] a Pod labelled ${TEAM_LABEL}=legacy    is DENIED (Team exists, active: false)
    [ ] a Pod with NO team label               is DENIED with the policy message,
                                                 not with a substitution error
    [ ] creating a NEW active Team makes its Pods admissible immediately,
        with no policy edit — the registry must stay live

RULES OF ENGAGEMENT
  - Do NOT delete the policy, do NOT switch it to Audit, do NOT remove the
    'apiCall' context and hardcode the team names. 'verify' checks for that.
  - Do NOT grant cluster-admin to Kyverno. Grant the least privilege needed
    and use the mechanism Kyverno ships for exactly this purpose.
  - You may edit the ClusterPolicy freely and create new RBAC objects.

TOOLBOX
  kubectl -n ${KYVERNO_NS} logs deploy/kyverno-admission-controller --tail=80 | grep -iE 'apicall|forbidden|substitut'
  kubectl auth can-i list teams.${CRD_GROUP} --as=system:serviceaccount:${KYVERNO_NS}:${KYVERNO_SA}
  kubectl get clusterpolicy ${POLICY_NAME} -o yaml
  kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active].metadata.name"   # needs the Kyverno CLI
  kubectl get clusterrole -l rbac.kyverno.io/aggregate-to-admission-controller=true

WHEN YOU THINK YOU ARE DONE
  $0 verify          # grades the five acceptance criteria
  $0 hint 1|2|3      # progressive hints
  $0 cleanup         # removes everything this lab created

EOF
  rule
}

# ------------------------------- verify -------------------------------------

PASS=0
FAIL=0

t_pass() { ok   "PASS  $*"; PASS=$((PASS+1)); }
t_fail() { printf '%s[-]%s FAIL  %s\n' "$C_RED" "$C_OFF" "$*"; FAIL=$((FAIL+1)); }

do_verify() {
  assert_tools
  discover_kyverno >/dev/null 2>&1 || true
  rule
  printf '%s Grading KCA 5.7 — acceptance criteria %s\n' "$C_BLD" "$C_OFF"
  rule

  # --- 0. the policy must still be a live API-call policy ------------------
  local pol
  if ! pol="$(kubectl get clusterpolicy "$POLICY_NAME" -o yaml 2>/dev/null)"; then
    t_fail "ClusterPolicy ${POLICY_NAME} does not exist. Deleting it is not a fix."
  else
    if grep -q 'apiCall' <<<"$pol" && grep -q 'teams' <<<"$pol"; then
      t_pass "policy still resolves the team registry through an apiCall context"
    else
      t_fail "the apiCall context is gone — the team list must not be hardcoded"
    fi
    if grep -qE 'Audit' <<<"$pol"; then
      t_fail "policy is in Audit mode; it must stay in Enforce"
    fi
  fi

  # --- 1. valid, active team is admitted -----------------------------------
  probe "kca-probe-good" "platform"
  if [[ $PROBE_RC -eq 0 ]]; then
    t_pass "Pod with ${TEAM_LABEL}=platform is admitted"
  else
    t_fail "Pod with ${TEAM_LABEL}=platform is still rejected:"
    sed 's/^/        /' <<<"$PROBE_OUT"
  fi

  # --- 2. unknown team is denied -------------------------------------------
  probe "kca-probe-ghost" "ghost"
  if [[ $PROBE_RC -ne 0 ]] && grep -qF "$DENY_MSG_SNIPPET" <<<"$PROBE_OUT"; then
    t_pass "Pod with an unregistered team is denied by the policy"
  else
    t_fail "Pod with team=ghost should be denied by ${POLICY_NAME} (rc=$PROBE_RC)"
    sed 's/^/        /' <<<"$PROBE_OUT"
  fi

  # --- 3. inactive team is denied ------------------------------------------
  probe "kca-probe-legacy" "legacy"
  if [[ $PROBE_RC -ne 0 ]] && grep -qF "$DENY_MSG_SNIPPET" <<<"$PROBE_OUT"; then
    t_pass "Pod with an inactive Team (legacy) is denied"
  else
    t_fail "team=legacy has spec.active=false and must be denied (rc=$PROBE_RC)"
    sed 's/^/        /' <<<"$PROBE_OUT"
  fi

  # --- 4. missing label denied cleanly, not with a substitution error ------
  probe "kca-probe-nolabel" ""
  if [[ $PROBE_RC -eq 0 ]]; then
    t_fail "Pod without a team label was admitted; it must be denied"
  elif grep -qiE 'not resolved|substitut|failed to load context|failed to substitute' <<<"$PROBE_OUT"; then
    t_fail "Pod without the label fails with a variable error instead of your message:"
    sed 's/^/        /' <<<"$PROBE_OUT"
  elif grep -qF "$DENY_MSG_SNIPPET" <<<"$PROBE_OUT"; then
    t_pass "Pod without a team label is denied with the policy's own message"
  else
    t_fail "unexpected rejection reason for the unlabelled Pod:"
    sed 's/^/        /' <<<"$PROBE_OUT"
  fi

  # --- 5. the registry is live ---------------------------------------------
  local live=1
  kubectl apply -f - >/dev/null 2>&1 <<'YAML' || live=0
apiVersion: kca.example.com/v1alpha1
kind: Team
metadata:
  name: kca-probe-sre
  labels:
    kca.example.com/lab: "5.7"
spec:
  displayName: SRE (verification probe)
  active: true
YAML
  if [[ $live -eq 1 ]]; then
    local i ok5=0
    for i in 1 2 3 4 5 6; do
      probe "kca-probe-live" "kca-probe-sre"
      [[ $PROBE_RC -eq 0 ]] && { ok5=1; break; }
      sleep 5
    done
    if [[ $ok5 -eq 1 ]]; then
      t_pass "a newly created active Team is honoured without editing the policy"
    else
      t_fail "new Team 'kca-probe-sre' is active but its Pods are still denied:"
      sed 's/^/        /' <<<"$PROBE_OUT"
    fi
    kubectl delete team kca-probe-sre --ignore-not-found >/dev/null 2>&1 || true
  else
    t_fail "could not create the probe Team (is the CRD still there?)"
  fi

  rule
  if [[ $FAIL -eq 0 ]]; then
    printf '%s ALL %d CHECKS PASSED — topic 5.7 mastered. %s\n' "$C_GRN$C_BLD" "$PASS" "$C_OFF"
    rule
    return 0
  fi
  printf '%s %d passed, %d failed. Run "%s hint 1" if you are stuck. %s\n' "$C_YEL$C_BLD" "$PASS" "$FAIL" "$0" "$C_OFF"
  rule
  return 1
}

# ------------------------------- helpers ------------------------------------

do_hint() {
  case "${1:-1}" in
    1) cat <<EOF
HINT 1 — read who is being refused, not what is being refused.
  The first error contains the string 'is forbidden: User
  "system:serviceaccount:<ns>:<sa>"'. That subject is the Kyverno ADMISSION
  controller, not you. Kyverno's default ClusterRoles cover built-in resources
  only; a CRD installed afterwards is invisible to it.
  Confirm the diagnosis:
    kubectl auth can-i list teams.${CRD_GROUP} --as=system:serviceaccount:${KYVERNO_NS:-kyverno}:${KYVERNO_SA:-kyverno-admission-controller}
    -> no
  Kyverno publishes aggregated ClusterRoles for exactly this. Find the label:
    kubectl get clusterrole kyverno:admission-controller -o jsonpath='{.aggregationRule}{"\n"}'
EOF
       ;;
    2) cat <<EOF
HINT 2 — the message says 'Registered active teams: []'.
  The API call now succeeds, so the empty list is a JMESPath problem, not an
  RBAC problem. spec.active is a JSON boolean; the filter compares it with the
  STRING 'true'. In JMESPath a literal boolean is written between backticks.
  Prove it outside the cluster:
    kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active=='true'].metadata.name"
    -> []
    kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active].metadata.name"
    -> [ "payments", "platform" ]
EOF
       ;;
    3) cat <<EOF
HINT 3 — a variable that resolves to null aborts the rule.
  For a Pod with no team label the JMESPath expression returns null, and
  Kyverno reports a substitution failure instead of evaluating your condition.
  Two idiomatic cures, both exam-relevant:
    a) a context variable with an explicit default:
         context:
           - name: team
             variable:
               jmesPath: 'request.object.metadata.labels."${TEAM_LABEL}"'
               default: ""
       then use {{ team }} in the message and in the deny condition.
    b) the JMESPath OR operator inline: {{ ... || '' }}
  Option (a) is preferred: the default is declared once and the rule reads
  cleanly. See https://kyverno.io/docs/writing-policies/variables/
EOF
       ;;
    *) die "hint takes 1, 2 or 3." ;;
  esac
}

do_status() {
  assert_tools
  discover_kyverno >/dev/null 2>&1 || true
  rule
  say "Namespace / policy"
  kubectl get ns "$LAB_NS" --no-headers 2>/dev/null || warn "namespace ${LAB_NS} missing"
  kubectl get clusterpolicy "$POLICY_NAME" -o wide 2>/dev/null || warn "policy missing"
  rule
  say "Team registry"
  kubectl get teams -o custom-columns='NAME:.metadata.name,ACTIVE:.spec.active' 2>/dev/null || warn "CRD missing"
  rule
  say "ClusterRoles aggregated into the admission controller"
  kubectl get clusterrole -l rbac.kyverno.io/aggregate-to-admission-controller=true --no-headers 2>/dev/null | awk '{print "  "$1}'
  rule
  say "Effective permission on the CRD"
  kubectl auth can-i list "teams.${CRD_GROUP}" \
    --as="system:serviceaccount:${KYVERNO_NS:-kyverno}:${KYVERNO_SA:-kyverno-admission-controller}" 2>/dev/null || true
  rule
  say "Recent Kyverno admission errors"
  kubectl -n "${KYVERNO_NS:-kyverno}" logs deploy/kyverno-admission-controller --tail=120 2>/dev/null \
    | grep -iE 'apicall|forbidden|substitut|failed to load context' | tail -n 15 || say "  (none)"
  rule
}

do_cleanup() {
  assert_tools
  info "Removing lab objects..."
  kubectl delete clusterpolicy "$POLICY_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$LAB_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete crd "$CRD_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole "$SOLUTION_CLUSTERROLE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole -l kca.example.com/lab=5.7 --ignore-not-found >/dev/null 2>&1 || true
  ok "Done."
  warn "If you created RBAC objects under a different name, remove them yourself:"
  say  "    kubectl get clusterrole -l rbac.kyverno.io/aggregate-to-admission-controller=true"
}

usage() {
  cat <<EOF
KCA 5.7 — Variables & API Calls in Policies — break & fix lab

  $0 setup [--yes]   arm the lab (disposable clusters only)
  $0 verify          grade your fix
  $0 hint [1|2|3]    progressive hints
  $0 status          lab objects, RBAC and Kyverno errors
  $0 cleanup         remove everything this lab created
EOF
}

main() {
  case "${1:-setup}" in
    setup)   shift || true; do_setup "${1:-}" ;;
    verify)  do_verify ;;
    hint)    shift || true; do_hint "${1:-1}" ;;
    status)  do_status ;;
    cleanup) do_cleanup ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

# =============================================================================
# ============================  SOLUTION  =====================================
# =============================================================================
# Stop here unless you have already fought `verify` at least twice.
#
# -----------------------------------------------------------------------------
# STEP 0 — read the failure, do not guess
# -----------------------------------------------------------------------------
#   $ kubectl run demo --image=busybox:1.36 -n kca-lab \
#       --labels=kca.example.com/team=platform --dry-run=server --command -- sleep 3600
#
#   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
#
#   resource Pod/kca-lab/demo was blocked due to the following policies
#
#   kca-5-7-team-registry:
#     pod-team-must-be-registered: 'failed to load context: failed to fetch data for
#       APICall: failed to execute APICall: teams.kca.example.com is forbidden: User
#       "system:serviceaccount:kyverno:kyverno-admission-controller" cannot list
#       resource "teams" in API group "kca.example.com" at the cluster scope'
#
#   Three facts are already in that string:
#     - the subject is the Kyverno admission controller SA, not your user;
#     - the verb is list, the resource is teams in group kca.example.com;
#     - the webhook is *-fail, i.e. failurePolicy: Fail, which is why a broken
#       context blocks the request instead of silently allowing it. That is the
#       correct default for a security control: fail closed.
#
#   Confirm it with SubjectAccessReview impersonation:
#     $ kubectl auth can-i list teams.kca.example.com \
#         --as=system:serviceaccount:kyverno:kyverno-admission-controller
#     no
#
# -----------------------------------------------------------------------------
# STEP 1 — FAULT 1: grant the API call the RBAC it needs (aggregated ClusterRole)
# -----------------------------------------------------------------------------
#   Kyverno 1.10+ splits its permissions across four controllers, and each one
#   has an aggregated ClusterRole you extend by LABEL, never by editing the
#   shipped roles (they are reconciled/overwritten on upgrade):
#
#     rbac.kyverno.io/aggregate-to-admission-controller   -> apiCall at admission time
#     rbac.kyverno.io/aggregate-to-background-controller  -> background scans, generate/mutateExisting
#     rbac.kyverno.io/aggregate-to-reports-controller     -> PolicyReports
#     rbac.kyverno.io/aggregate-to-cleanup-controller     -> cleanup policies
#
#   Inspect the aggregation rule you are targeting:
#     $ kubectl get clusterrole kyverno:admission-controller -o jsonpath='{.aggregationRule}{"\n"}'
#     {"clusterRoleSelectors":[{"matchLabels":{"rbac.kyverno.io/aggregate-to-admission-controller":"true"}}]}
#
#   Our policy has background: false, so ONLY the admission controller performs
#   the call. If you ever set background: true (or add a generate rule), add the
#   background-controller label too, otherwise background scans fail while
#   admission works — a classic half-fixed state.
#
#   cat <<'EOF' | kubectl apply -f -
#   apiVersion: rbac.authorization.k8s.io/v1
#   kind: ClusterRole
#   metadata:
#     name: kca-lab-kyverno-teams-reader
#     labels:
#       rbac.kyverno.io/aggregate-to-admission-controller: "true"
#       rbac.kyverno.io/aggregate-to-background-controller: "true"
#       kca.example.com/lab: "5.7"
#   rules:
#     - apiGroups: ["kca.example.com"]
#       resources: ["teams"]
#       verbs: ["get", "list", "watch"]
#   EOF
#
#   No RoleBinding is required: the ClusterRole is absorbed by aggregation into
#   kyverno:admission-controller, which is already bound to the ServiceAccount.
#   Verify (aggregation is reconciled by kube-controller-manager, allow a few
#   seconds; the Kyverno API client picks it up on the next call):
#
#     $ kubectl auth can-i list teams.kca.example.com \
#         --as=system:serviceaccount:kyverno:kyverno-admission-controller
#     yes
#
# -----------------------------------------------------------------------------
# STEP 2 — FAULT 2: the JMESPath filter compares a boolean with a string
# -----------------------------------------------------------------------------
#   Retry the Pod. New error, new layer:
#
#     resource Pod/kca-lab/demo was blocked due to the following policies
#     kca-5-7-team-registry:
#       pod-team-must-be-registered: 'validation error: Pod label
#         kca.example.com/team must name a registered active Team. Got
#         ''platform''. Registered active teams: []'
#
#   'Registered active teams: []' is the tell: RBAC is fine, the expression is
#   wrong. spec.active is a JSON boolean; 'true' is a string. In JMESPath a
#   literal is written between backticks, so `true` is the boolean and 'true'
#   is text. They never compare equal.
#
#   Reproduce it offline with the Kyverno CLI (kubectl kyverno jp query):
#     $ kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active=='true'].metadata.name"
#     []
#     $ kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active==\`true\`].metadata.name"
#     [
#       "payments",
#       "platform"
#     ]
#     $ kubectl get teams -o json | kubectl kyverno jp query "items[?spec.active].metadata.name"
#     [
#       "payments",
#       "platform"
#     ]
#
#   Both fixed forms are correct. `items[?spec.active]` relies on JMESPath
#   truthiness; `== \`true\`` is explicit and survives a schema change from
#   boolean to something else more visibly. Prefer the explicit one in policy.
#
# -----------------------------------------------------------------------------
# STEP 3 — FAULT 3: give the label lookup a default
# -----------------------------------------------------------------------------
#   Now a labelled Pod is admitted and 'ghost'/'legacy' are denied. But:
#
#     $ kubectl run nolabel --image=busybox:1.36 -n kca-lab --dry-run=server --command -- sleep 3600
#     Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
#     ... failed to substitute variables in deny conditions: ... variable
#     request.object.metadata.labels."kca.example.com/team" not resolved at path ...
#
#   The Pod is blocked, so the cluster is still safe — but the operator gets a
#   Kyverno internal error instead of the actionable message, and an auditor
#   reading PolicyReports sees 'error', not 'fail'. Declare the default once, as
#   a context variable, and reference it everywhere.
#
#   Note also the quoting rule: label keys contain dots and slashes, so the
#   JMESPath segment MUST be double quoted -> labels."kca.example.com/team".
#   Without the quotes JMESPath parses it as nested fields and the policy fails
#   validation or resolves to null.
#
# -----------------------------------------------------------------------------
# STEP 4 — the corrected policy, in full
# -----------------------------------------------------------------------------
#   cat <<'EOF' | kubectl apply -f -
#   apiVersion: kyverno.io/v1
#   kind: ClusterPolicy
#   metadata:
#     name: kca-5-7-team-registry
#     labels:
#       kca.example.com/lab: "5.7"
#     annotations:
#       policies.kyverno.io/title: Pods must reference a registered, active Team
#       policies.kyverno.io/category: Governance
#       policies.kyverno.io/subject: Pod
#   spec:
#     validationFailureAction: Enforce     # Kyverno <= 1.12
#     background: false                    # only the admission controller calls the API
#     rules:
#       - name: pod-team-must-be-registered
#         match:
#           any:
#             - resources:
#                 kinds:
#                   - Pod
#                 namespaces:
#                   - kca-lab
#         context:
#           # 1) external data: the live registry, read at admission time
#           - name: activeteams
#             apiCall:
#               urlPath: "/apis/kca.example.com/v1alpha1/teams"
#               jmesPath: "items[?spec.active==`true`].metadata.name"
#           # 2) local variable with an explicit default -> never resolves to null
#           - name: team
#             variable:
#               jmesPath: 'request.object.metadata.labels."kca.example.com/team"'
#               default: ""
#         validate:
#           # failureAction: Enforce      # Kyverno >= 1.13 puts it here instead
#           message: >-
#             Pod label kca.example.com/team must name a registered active Team.
#             Got '{{ team }}'. Registered active teams: {{ activeteams }}
#           deny:
#             conditions:
#               all:
#                 - key: "{{ team }}"
#                   operator: AnyNotIn
#                   value: "{{ activeteams }}"
#   EOF
#
#   $ kubectl wait --for=condition=Ready clusterpolicy/kca-5-7-team-registry --timeout=60s
#   clusterpolicy.kyverno.io/kca-5-7-team-registry condition met
#
# -----------------------------------------------------------------------------
# STEP 5 — prove the four behaviours by hand
# -----------------------------------------------------------------------------
#   $ kubectl run ok --image=busybox:1.36 -n kca-lab \
#       --labels=kca.example.com/team=platform --dry-run=server --command -- sleep 3600
#   pod/ok created (server dry run)
#
#   $ kubectl run ghost --image=busybox:1.36 -n kca-lab \
#       --labels=kca.example.com/team=ghost --dry-run=server --command -- sleep 3600
#   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
#   ... validation error: Pod label kca.example.com/team must name a registered
#   active Team. Got 'ghost'. Registered active teams: ["payments","platform"]
#
#   $ kubectl run legacy --image=busybox:1.36 -n kca-lab \
#       --labels=kca.example.com/team=legacy --dry-run=server --command -- sleep 3600
#   ... Got 'legacy'. Registered active teams: ["payments","platform"]
#
#   $ kubectl run nolabel --image=busybox:1.36 -n kca-lab --dry-run=server --command -- sleep 3600
#   ... Got ''. Registered active teams: ["payments","platform"]
#
#   Liveness of the registry — no policy edit involved:
#   $ kubectl apply -f - <<'EOF'
#   apiVersion: kca.example.com/v1alpha1
#   kind: Team
#   metadata: {name: sre}
#   spec: {displayName: SRE, active: true}
#   EOF
#   $ kubectl run sre --image=busybox:1.36 -n kca-lab \
#       --labels=kca.example.com/team=sre --dry-run=server --command -- sleep 3600
#   pod/sre created (server dry run)
#
#   $ ./kca-5.7-break-fix.sh verify
#   [+] PASS  policy still resolves the team registry through an apiCall context
#   [+] PASS  Pod with kca.example.com/team=platform is admitted
#   [+] PASS  Pod with an unregistered team is denied by the policy
#   [+] PASS  Pod with an inactive Team (legacy) is denied
#   [+] PASS  Pod without a team label is denied with the policy's own message
#   [+] PASS  a newly created active Team is honoured without editing the policy
#   ALL 6 CHECKS PASSED — topic 5.7 mastered.
#
# -----------------------------------------------------------------------------
# STEP 6 — what to carry into the exam and into production
# -----------------------------------------------------------------------------
#   * apiCall permissions belong to the controller that runs the rule. Admission
#     rules -> aggregate-to-admission-controller. background: true, generate or
#     mutateExisting -> aggregate-to-background-controller as well. Extend by
#     labelled ClusterRole, never by editing kyverno:* roles.
#   * failurePolicy: Fail means every context error is an outage. Treat urlPath,
#     jmesPath and RBAC as production code: an apiCall that 404s or 403s takes
#     the namespace down with it.
#   * JMESPath literals need backticks: `true`, `false`, `10`, `"str"`.
#     Single quotes are raw strings. This one-character difference is the most
#     common silent bug in KCA policy questions, and it fails CLOSED here only
#     because the operator is AnyNotIn — with AnyIn the same bug would fail OPEN
#     and admit everything. Always ask which way your expression degrades.
#   * Label keys with dots/slashes must be double quoted inside JMESPath.
#   * Every variable that may be absent needs a default (context variable
#     `default:`) or an inline `|| ''`; otherwise the rule errors instead of
#     denying, and your PolicyReports fill with 'error' instead of 'fail'.
#   * Cost: an apiCall runs on every matching AdmissionReview. For hot paths
#     prefer a ConfigMap context, or a cached global context entry
#     (GlobalContextEntry, Kyverno 1.11+), instead of hitting the API server.
#   * Test expressions with `kubectl kyverno jp query` and rules with
#     `kubectl kyverno test` / `kubectl kyverno apply` before they reach a
#     cluster whose webhook is fail-closed.
#
#   Sources: https://kyverno.io/docs/writing-policies/external-data-sources/
#            https://kyverno.io/docs/writing-policies/variables/
#            https://kyverno.io/docs/writing-policies/jmespath/
#            https://kyverno.io/docs/installation/customization/
#            https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles
#            https://jmespath.org/specification.html
# =============================================================================