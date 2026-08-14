#!/usr/bin/env bash
# =============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 5 — Topic 5.3: Background Scans        (exam weight: 2.91)
#  BREAK & FIX laboratory
#
#  WARNING — DESTRUCTIVE. This script scales down and patches the Kyverno
#  reports controller and creates/deletes a lab namespace. Run it ONLY on a
#  disposable lab VM with a throwaway cluster (kind / k3d / minikube).
#  NEVER run it against a shared or production cluster.
#
#  Requirements: kubectl, a reachable cluster, Kyverno >= 1.10 installed
#  (Kyverno 1.10 split the reports controller into its own Deployment; the
#  background scanner lives there, not in the admission controller).
#
#  Usage:
#     ./kca-5.3-background-scans.sh            # same as: break
#     ./kca-5.3-background-scans.sh break      # build the lab and inject faults
#     ./kca-5.3-background-scans.sh verify     # grade your fix
#     ./kca-5.3-background-scans.sh cleanup    # remove lab, restore Kyverno
#
#  Environment overrides:
#     LAB_NS=kca-bgscan  KYVERNO_NS=kyverno  LAB_DIR=$HOME/kca-lab-5.3
#     LAB_YES=1          # skip the interactive confirmation (CI / VM images)
#
#  Official references:
#     https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#     https://kyverno.io/docs/writing-policies/background/
#     https://kyverno.io/docs/policy-reports/
#     https://kyverno.io/docs/installation/customization/      (container flags)
#     https://kyverno.io/docs/high-availability/               (controllers)
#     https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report
# =============================================================================

set -euo pipefail

LAB_NS="${LAB_NS:-kca-bgscan}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
LAB_DIR="${LAB_DIR:-$HOME/kca-lab-5.3}"
RC_DEPLOY="kyverno-reports-controller"
POLICY_A="kca53-require-runasnonroot"
POLICY_B="kca53-restrict-registry"
BAD_FLAG="--backgroundScanInterval=24h"
UID_FILE="${LAB_DIR}/lab.uids"
POLICY_B_FILE="${LAB_DIR}/policy-b-restrict-registry.yaml"
RC_BACKUP="${LAB_DIR}/reports-controller.original.yaml"

if [[ -t 1 ]]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else
  B=''; R=''; G=''; Y=''; C=''; N=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n'    "$C" "$N" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n'    "$Y" "$N" "$*"; }
die()  { printf '%s[x]%s %s\n'    "$R" "$N" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "======================================================================="; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster (check KUBECONFIG)."

  kubectl get ns "$KYVERNO_NS" >/dev/null 2>&1 \
    || die "Namespace '${KYVERNO_NS}' not found. Install Kyverno first:
       helm repo add kyverno https://kyverno.github.io/kyverno
       helm install kyverno kyverno/kyverno -n kyverno --create-namespace"

  kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" >/dev/null 2>&1 \
    || die "Deployment '${RC_DEPLOY}' not found in '${KYVERNO_NS}'.
       This lab needs Kyverno >= 1.10, where background scanning runs in its
       own reports controller. Check: kubectl -n ${KYVERNO_NS} get deploy"

  kubectl get crd policyreports.wgpolicyk8s.io >/dev/null 2>&1 \
    || die "CRD policyreports.wgpolicyk8s.io missing — Kyverno install is incomplete."
  kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 \
    || die "CRD clusterpolicies.kyverno.io missing — Kyverno install is incomplete."

  KYVERNO_IMG="$(kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo 'unknown')"
  CTX="$(kubectl config current-context 2>/dev/null || echo '?')"
  APISERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '?')"
}

confirm() {
  hr
  warn "Context      : ${CTX}"
  warn "API server   : ${APISERVER}"
  warn "Kyverno image: ${KYVERNO_IMG}"
  warn "This script WILL break Kyverno background scanning in this cluster."
  hr
  [[ "${LAB_YES:-0}" == "1" ]] && return 0
  [[ -t 0 ]] || die "Non-interactive shell. Re-run with LAB_YES=1 only if this cluster is disposable."
  local answer
  read -r -p "Type BREAK to continue: " answer
  [[ "$answer" == "BREAK" ]] || die "Aborted by the user."
}

uid_of() { kubectl -n "$LAB_NS" get "$1" "$2" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }

# -----------------------------------------------------------------------------
# BREAK — build the lab, then inject three faults
# -----------------------------------------------------------------------------
do_break() {
  preflight
  confirm
  mkdir -p "$LAB_DIR"

  info "Removing any previous run of this lab (idempotent)..."
  kubectl delete clusterpolicy "$POLICY_A" "$POLICY_B" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$LAB_NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  info "Saving the original reports controller spec to ${RC_BACKUP}"
  kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" -o yaml > "$RC_BACKUP"

  # ---------------------------------------------------------------------------
  # Workloads are created FIRST, on purpose. They pre-date the policies, so they
  # never pass through the admission webhook while the policies exist. Any
  # result they show in a PolicyReport can therefore only come from a
  # background scan. That is the whole point of the topic.
  # ---------------------------------------------------------------------------
  info "Creating pre-existing workloads in namespace '${LAB_NS}'..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${LAB_NS}
  labels:
    kca.lab/topic: "5.3"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bgscan-compliant
  namespace: ${LAB_NS}
  labels:
    app: bgscan-compliant
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bgscan-compliant
  template:
    metadata:
      labels:
        app: bgscan-compliant
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bgscan-legacy
  namespace: ${LAB_NS}
  labels:
    app: bgscan-legacy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bgscan-legacy
  template:
    metadata:
      labels:
        app: bgscan-legacy
    spec:
      containers:
        - name: web
          image: docker.io/library/nginx:1.25-alpine
---
apiVersion: v1
kind: Pod
metadata:
  name: bgscan-orphan
  namespace: ${LAB_NS}
  labels:
    app: bgscan-orphan
spec:
  containers:
    - name: shell
      image: docker.io/library/busybox:1.36
      command: ["/bin/sh"]
      args: ["-c", "while true; do sleep 30; done"]
EOF

  info "Waiting for the workloads to settle (non-fatal)..."
  kubectl -n "$LAB_NS" wait --for=condition=Ready pod --all --timeout=150s >/dev/null 2>&1 \
    || warn "Some pods are not Ready yet. Background scans read the spec from etcd, so the lab still works."

  info "Recording resource UIDs (the grader checks you did not recreate them)..."
  {
    echo "COMPLIANT_DEPLOY_UID=$(uid_of deploy bgscan-compliant)"
    echo "LEGACY_DEPLOY_UID=$(uid_of deploy bgscan-legacy)"
    echo "ORPHAN_POD_UID=$(uid_of pod bgscan-orphan)"
  } > "$UID_FILE"

  # ---------------------------------------------------------------------------
  # FAULT 1 — the policy is authored with background scanning disabled.
  # Note there is no validationFailureAction: the default is Audit, which is the
  # action that produces report entries instead of blocking admission.
  # ---------------------------------------------------------------------------
  info "Applying ClusterPolicy '${POLICY_A}'..."
  kubectl apply -f - <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_A}
  annotations:
    policies.kyverno.io/title: Require runAsNonRoot
    policies.kyverno.io/category: KCA 5.3 lab
spec:
  background: false
  rules:
    - name: check-run-as-nonroot
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${LAB_NS}
      validate:
        message: "spec.securityContext.runAsNonRoot must be set to true."
        pattern:
          spec:
            securityContext:
              runAsNonRoot: true
EOF

  # ---------------------------------------------------------------------------
  # FAULT 2 — a second policy that the student must apply. It is written against
  # AdmissionRequest-only data ({{ request.userInfo.* }}), which cannot exist
  # during a background scan: there is no user, no operation and no roles when
  # the reports controller re-reads an object straight out of etcd.
  # It is written to disk, NOT applied.
  # ---------------------------------------------------------------------------
  info "Writing the second policy to ${POLICY_B_FILE} (not applied — that is your job)..."
  cat > "$POLICY_B_FILE" <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_B}
  annotations:
    policies.kyverno.io/title: Restrict image registries
    policies.kyverno.io/category: KCA 5.3 lab
spec:
  background: true
  rules:
    - name: check-registry
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${LAB_NS}
      preconditions:
        all:
          - key: "{{ request.userInfo.username }}"
            operator: NotEquals
            value: "system:serviceaccount:kube-system:replicaset-controller"
      validate:
        message: "Images must be pulled from registry.k8s.io."
        pattern:
          spec:
            containers:
              - image: "registry.k8s.io/*"
EOF

  # ---------------------------------------------------------------------------
  # FAULT 3 — the reports controller is stopped and its scan interval is pushed
  # far beyond any lab session. Nothing scans, and even once it is restarted the
  # periodic re-scan would be 24 h away.
  # ---------------------------------------------------------------------------
  info "Stopping the reports controller and sabotaging its scan interval..."
  kubectl -n "$KYVERNO_NS" scale deploy "$RC_DEPLOY" --replicas=0 >/dev/null
  if kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" \
       -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q '\['; then
    kubectl -n "$KYVERNO_NS" patch deploy "$RC_DEPLOY" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${BAD_FLAG}\"}]" >/dev/null
  else
    kubectl -n "$KYVERNO_NS" patch deploy "$RC_DEPLOY" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"${BAD_FLAG}\"]}]" >/dev/null
  fi

  info "Clearing any leftover reports so the starting state is unambiguous..."
  kubectl -n "$LAB_NS" delete policyreport --all >/dev/null 2>&1 || true

  print_mission
}

# -----------------------------------------------------------------------------
# The mission briefing
# -----------------------------------------------------------------------------
print_mission() {
  hr
  say "${B} KCA 5.3 — BACKGROUND SCANS — BREAK & FIX${N}"
  hr
  cat <<EOF

${B}SCENARIO${N}
  A cluster admin reports: "Kyverno is installed, the policy is there, and I
  have Pods in ${LAB_NS} that clearly violate it — but the compliance
  dashboard is empty. New workloads get flagged, old ones never do."

  Three independent faults were injected. Fix all three.

${B}SYMPTOMS YOU WILL SEE${N}
  1) 'kubectl get policyreport -n ${LAB_NS}' returns "No resources found",
     even though ClusterPolicy ${POLICY_A} exists and
     pods bgscan-legacy-* and bgscan-orphan violate it.
  2) 'kubectl get cpol' shows the policy as READY — a Ready policy that
     produces zero results is the signature of this failure class.
  3) Once results finally start flowing, ${POLICY_A} still reports nothing
     for the pods that already existed. Create a brand new violating pod and
     it IS reported. That asymmetry — new resources reported, existing ones
     ignored — is the definition of background scanning being off.
  4) 'kubectl apply -f ${POLICY_B_FILE}'
     is REJECTED by the webhook validate-policy.kyverno.svc, with a message
     about variables that are not allowed in background mode.

${B}YOUR GOAL${N}
  Reach a state where, WITHOUT deleting or recreating any lab workload:
    a) The reports controller is running (>= 1 ready replica) and its
       background scan interval is back to a sane value (the injected
       '${BAD_FLAG}' must be gone).
    b) ClusterPolicy ${POLICY_A} runs in background mode.
    c) ClusterPolicy ${POLICY_B} is APPLIED, in background mode, and does not
       depend on any {{ request.userInfo.* }} / {{ request.operation }} /
       {{ request.roles }} data. Keep the same rule intent: only
       registry.k8s.io images are allowed.
    d) PolicyReports in ${LAB_NS} contain, for the ORIGINAL objects:
         - ${POLICY_A}: fail on bgscan-legacy and on bgscan-orphan
         - ${POLICY_B}: fail on bgscan-legacy
         - at least one pass on bgscan-compliant

${B}RULES${N}
  * Do NOT delete, recreate or re-apply the lab workloads. Their UIDs were
    recorded in ${UID_FILE}; the grader compares them.
    Recreating them would generate admission-time results and hide the bug.
  * Do NOT set 'background: false' anywhere. That silences the symptom by
    removing the feature under test.
  * Do NOT reinstall Kyverno.

${B}DIAGNOSTIC COMMANDS WORTH KNOWING${N}
  kubectl get cpol                          # ADMISSION / BACKGROUND / READY columns
  kubectl describe cpol ${POLICY_A}
  kubectl get polr -A                       # polr = PolicyReport (namespaced)
  kubectl get cpolr                         # ClusterPolicyReport (cluster-scoped)
  kubectl get polr -n ${LAB_NS} -o yaml
  kubectl -n ${KYVERNO_NS} get deploy
  kubectl -n ${KYVERNO_NS} get deploy ${RC_DEPLOY} -o yaml | grep -A20 'args:'
  kubectl -n ${KYVERNO_NS} logs deploy/${RC_DEPLOY} --tail=100
  kubectl -n ${LAB_NS} get ephemeralreports.reports.kyverno.io       # Kyverno >= 1.13
  kubectl -n ${LAB_NS} get backgroundscanreports.kyverno.io          # Kyverno 1.10-1.12
  kubectl -n ${KYVERNO_NS} get cm kyverno -o yaml                    # resourceFilters
  diff <(kubectl -n ${KYVERNO_NS} get deploy ${RC_DEPLOY} -o yaml) ${RC_BACKUP}

${B}GRADE YOURSELF${N}
  $0 verify        # polls up to 4 minutes for the reports to converge
  $0 cleanup       # tear the lab down and restore Kyverno

EOF
  hr
}

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
# One line per report result:  <policy>/<rule>=<result>@<Kind>:<name>:<uid>...
polr_lines() {
  kubectl -n "$LAB_NS" get policyreport -o jsonpath="{range .items[*]}{range .results[*]}{.policy}{'/'}{.rule}{'='}{.result}{'@'}{range .resources[*]}{.kind}{':'}{.name}{':'}{.uid}{' '}{end}{'\n'}{end}{end}" 2>/dev/null || true
}

# match_result <lines> <policy> <result> <uid list>
match_result() {
  local lines="$1" policy="$2" result="$3" uids="$4" line uid
  while IFS= read -r line; do
    [[ "$line" == "${policy}/"* ]] || continue
    [[ "$line" == *"=${result}@"* ]] || continue
    for uid in $uids; do
      [[ -n "$uid" && "$line" == *"$uid"* ]] && return 0
    done
  done <<< "$lines"
  return 1
}

do_verify() {
  preflight
  [[ -f "$UID_FILE" ]] || die "No lab state found at ${UID_FILE}. Run '$0 break' first."
  # shellcheck disable=SC1090
  source "$UID_FILE"

  local failed=0
  hr; say "${B} GRADING — KCA 5.3 Background Scans${N}"; hr

  # --- integrity: the original objects must still be the original objects ----
  local cur_legacy cur_compliant cur_orphan
  cur_legacy="$(uid_of deploy bgscan-legacy)"
  cur_compliant="$(uid_of deploy bgscan-compliant)"
  cur_orphan="$(uid_of pod bgscan-orphan)"
  if [[ "$cur_legacy" == "${LEGACY_DEPLOY_UID:-}" && "$cur_compliant" == "${COMPLIANT_DEPLOY_UID:-}" \
        && "$cur_orphan" == "${ORPHAN_POD_UID:-}" && -n "$cur_orphan" ]]; then
    ok "Lab workloads are the original ones (UIDs unchanged)."
  else
    bad "Lab workloads were deleted/recreated — the exercise is void."
    say "     Re-run '$0 break' and fix Kyverno instead of the workloads."
    return 1
  fi

  # --- check 1: reports controller running ----------------------------------
  local ready
  ready="$(kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ -n "$ready" && "$ready" -ge 1 ]]; then
    ok "Reports controller is running (${ready} ready replica(s))."
  else
    bad "Reports controller has no ready replica — nothing performs background scans."
    failed=$((failed + 1))
  fi

  # --- check 2: scan interval restored --------------------------------------
  local args
  args="$(kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" -o jsonpath='{.spec.template.spec.containers[*].args}' 2>/dev/null || true)"
  if grep -q 'backgroundScanInterval=24h' <<< "$args"; then
    bad "The reports controller still carries ${BAD_FLAG}."
    say "     Periodic re-scans would only happen once a day."
    failed=$((failed + 1))
  else
    ok "No sabotaged --backgroundScanInterval on the reports controller."
  fi

  # --- check 3: policy A in background mode ---------------------------------
  local bgA
  bgA="$(kubectl get cpol "$POLICY_A" -o jsonpath='{.spec.background}' 2>/dev/null || true)"
  if [[ "$bgA" == "true" || -z "$bgA" ]]; then
    ok "ClusterPolicy ${POLICY_A} has background scanning enabled."
  else
    bad "ClusterPolicy ${POLICY_A} still has spec.background=${bgA}."
    failed=$((failed + 1))
  fi

  # --- check 4: policy B applied, background-capable -------------------------
  if kubectl get cpol "$POLICY_B" >/dev/null 2>&1; then
    local bgB specB
    bgB="$(kubectl get cpol "$POLICY_B" -o jsonpath='{.spec.background}' 2>/dev/null || true)"
    specB="$(kubectl get cpol "$POLICY_B" -o jsonpath='{.spec}' 2>/dev/null || true)"
    if [[ "$bgB" == "true" || -z "$bgB" ]]; then
      ok "ClusterPolicy ${POLICY_B} is applied with background scanning enabled."
    else
      bad "ClusterPolicy ${POLICY_B} has spec.background=${bgB} — disabling it is not the fix."
      failed=$((failed + 1))
    fi
    if grep -qE 'request\.(userInfo|roles|clusterRoles|operation)' <<< "$specB"; then
      bad "${POLICY_B} still references AdmissionRequest-only data."
      say "     Those variables are unavailable during a background scan."
      failed=$((failed + 1))
    else
      ok "${POLICY_B} no longer depends on AdmissionRequest-only variables."
    fi
  else
    bad "ClusterPolicy ${POLICY_B} is not applied."
    say "     Fix ${POLICY_B_FILE} until the webhook accepts it in background mode."
    failed=$((failed + 1))
  fi

  # --- check 5: the reports themselves --------------------------------------
  local legacy_ids compliant_ids lines deadline=$((SECONDS + 240))
  legacy_ids="${LEGACY_DEPLOY_UID:-} $(kubectl -n "$LAB_NS" get pod -l app=bgscan-legacy -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null || true)"
  compliant_ids="${COMPLIANT_DEPLOY_UID:-} $(kubectl -n "$LAB_NS" get pod -l app=bgscan-compliant -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null || true)"

  info "Waiting for the background scan to converge (up to 4 min)..."
  while :; do
    lines="$(polr_lines)"
    if match_result "$lines" "$POLICY_A" fail "$legacy_ids" \
       && match_result "$lines" "$POLICY_A" fail "${ORPHAN_POD_UID:-}" \
       && match_result "$lines" "$POLICY_B" fail "$legacy_ids"; then
      break
    fi
    (( SECONDS < deadline )) || break
    printf '.'
    sleep 10
  done
  printf '\n'

  if match_result "$lines" "$POLICY_A" fail "$legacy_ids"; then
    ok "${POLICY_A}: fail result recorded for the pre-existing bgscan-legacy workload."
  else
    bad "${POLICY_A}: no fail result for bgscan-legacy."; failed=$((failed + 1))
  fi
  if match_result "$lines" "$POLICY_A" fail "${ORPHAN_POD_UID:-}"; then
    ok "${POLICY_A}: fail result recorded for the pre-existing pod bgscan-orphan."
  else
    bad "${POLICY_A}: no fail result for bgscan-orphan."; failed=$((failed + 1))
  fi
  if match_result "$lines" "$POLICY_B" fail "$legacy_ids"; then
    ok "${POLICY_B}: fail result recorded for bgscan-legacy (docker.io image)."
  else
    bad "${POLICY_B}: no fail result for bgscan-legacy."; failed=$((failed + 1))
  fi
  if match_result "$lines" "$POLICY_A" pass "$compliant_ids" \
     || match_result "$lines" "$POLICY_B" pass "$compliant_ids"; then
    ok "bgscan-compliant is reported as pass — the scan is evaluating, not just failing."
  else
    bad "No pass result for bgscan-compliant."; failed=$((failed + 1))
  fi

  hr
  if [[ "$failed" -eq 0 ]]; then
    say "${G}${B} ALL CHECKS PASSED — background scanning is healthy.${N}"
    say "Inspect the evidence: kubectl get polr -n ${LAB_NS} -o yaml"
    hr; return 0
  fi
  say "${R}${B} ${failed} CHECK(S) FAILED.${N} Keep digging, then run '$0 verify' again."
  say "Current report results:"
  say "${lines:-  (none)}"
  hr; return 1
}

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------
strip_bad_flag() {
  local idx
  idx="$(kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" \
        -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null \
        | grep -n -- 'backgroundScanInterval=24h' | head -1 | cut -d: -f1)"
  [[ -n "$idx" ]] || return 0
  kubectl -n "$KYVERNO_NS" patch deploy "$RC_DEPLOY" --type=json \
    -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/$((idx - 1))\"}]" >/dev/null
}

do_cleanup() {
  preflight
  info "Deleting lab policies and namespace..."
  kubectl delete clusterpolicy "$POLICY_A" "$POLICY_B" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$LAB_NS" --ignore-not-found >/dev/null 2>&1 || true
  info "Restoring the reports controller..."
  strip_bad_flag
  kubectl -n "$KYVERNO_NS" scale deploy "$RC_DEPLOY" --replicas=1 >/dev/null
  kubectl -n "$KYVERNO_NS" rollout status deploy "$RC_DEPLOY" --timeout=180s || true
  ok "Cleanup done. Lab files kept in ${LAB_DIR}."
}

case "${1:-break}" in
  break)   do_break   ;;
  verify)  do_verify  ;;
  cleanup) do_cleanup ;;
  *) die "Usage: $0 [break|verify|cleanup]" ;;
esac

# =============================================================================
# ============================  S O L U T I O N  ==============================
# =============================================================================
# Do not read this until you have genuinely tried. Every command below is meant
# to be typed by hand; the script never applies them for you.
#
# -----------------------------------------------------------------------------
# STEP 0 — Establish the fact: policies exist, reports do not.
# -----------------------------------------------------------------------------
#   kubectl get cpol
#     NAME                        ADMISSION   BACKGROUND   READY   AGE
#     kca53-require-runasnonroot  true        false        True    2m
#
#   The BACKGROUND column is printed by Kyverno's CRD printcolumns (1.11+).
#   'false' there is fault #1, visible without opening the YAML.
#
#   kubectl get polr -n kca-bgscan
#     No resources found in kca-bgscan namespace.
#
#   kubectl get polr -A
#     (empty everywhere — not just in the lab namespace)
#
#   A cluster-wide absence of reports does not point at one policy. It points at
#   the component that writes reports.
#
# -----------------------------------------------------------------------------
# STEP 1 — Find the component that performs background scans.
# -----------------------------------------------------------------------------
#   kubectl -n kyverno get deploy
#     NAME                          READY   UP-TO-DATE   AVAILABLE
#     kyverno-admission-controller  1/1     1            1
#     kyverno-background-controller 1/1     1            1
#     kyverno-cleanup-controller    1/1     1            1
#     kyverno-reports-controller    0/0     0            0        <-- fault #3
#
#   Read those four names carefully, because the exam trades on the confusion:
#     * admission-controller  -> the webhook; validates/mutates at CREATE/UPDATE
#     * background-controller -> generate rules and mutateExisting rules
#     * cleanup-controller    -> CleanupPolicy / TTL
#     * reports-controller    -> BACKGROUND SCANS and PolicyReport aggregation
#   Despite the name, "background scans" are NOT done by the background
#   controller. They are done by the reports controller.
#   https://kyverno.io/docs/high-availability/
#
#   Bring it back:
#     kubectl -n kyverno scale deploy kyverno-reports-controller --replicas=1
#     kubectl -n kyverno rollout status deploy kyverno-reports-controller
#
# -----------------------------------------------------------------------------
# STEP 2 — Remove the sabotaged scan interval.
# -----------------------------------------------------------------------------
#   kubectl -n kyverno get deploy kyverno-reports-controller -o yaml | grep -A20 'args:'
#     ...
#       - --backgroundScanInterval=24h        <-- injected
#
#   Compare against the snapshot the lab saved:
#     diff <(kubectl -n kyverno get deploy kyverno-reports-controller -o yaml) \
#          "$HOME/kca-lab-5.3/reports-controller.original.yaml"
#
#   Remove it interactively:
#     kubectl -n kyverno edit deploy kyverno-reports-controller     # delete the line
#
#   Or surgically, by index (no jq needed):
#     idx=$(kubectl -n kyverno get deploy kyverno-reports-controller \
#            -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' \
#            | grep -n backgroundScanInterval=24h | cut -d: -f1)
#     kubectl -n kyverno patch deploy kyverno-reports-controller --type=json \
#       -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/$((idx-1))\"}]"
#
#   Default is --backgroundScanInterval=1h. Related flags on the same controller:
#     --backgroundScanWorkers=2     parallelism of the scan loop
#     --backgroundScanInterval=1h   how often every in-scope resource is re-checked
#     --skipResourceFilters=true    whether the ConfigMap resourceFilters are
#                                   ignored during background scans
#     --aggregateReports / --policyReports  report aggregation behaviour
#   https://kyverno.io/docs/installation/customization/
#
#   Exam-relevant nuance: the controller performs a full scan on startup, so the
#   reports come back the moment you scale it up. A wrong interval does not
#   produce an immediate symptom — it produces STALE reports hours later, which
#   is far harder to notice in production. Fix it anyway.
#
# -----------------------------------------------------------------------------
# STEP 3 — Reports appear, but the old pods are still missing. Why?
# -----------------------------------------------------------------------------
#   kubectl get polr -n kca-bgscan
#     NAME                                   PASS   FAIL   WARN   ERROR   SKIP
#     8f2c... (one report per resource)       0      0      0      0       0
#
#   Prove the asymmetry to yourself before fixing it:
#     kubectl -n kca-bgscan run probe --image=docker.io/library/busybox:1.36 \
#       --restart=Never -- sleep 60
#     kubectl get polr -n kca-bgscan -o yaml | grep -A6 'policy: kca53-require'
#   The NEW pod is reported (the admission controller emits an EphemeralReport
#   for Audit-mode policies at CREATE time, and the reports controller
#   aggregates it into a PolicyReport). The pods that already existed are not.
#   Delete the probe afterwards:  kubectl -n kca-bgscan delete pod probe
#
#   That is exactly what spec.background: false means. Background scanning is
#   the only mechanism that evaluates resources which never pass through the
#   webhook again — everything already in etcd. Turn it on:
#
#     kubectl patch cpol kca53-require-runasnonroot --type=merge \
#       -p '{"spec":{"background":true}}'
#
#   background defaults to true. Someone had to switch it off, usually to work
#   around exactly the error you are about to meet in step 4.
#   https://kyverno.io/docs/writing-policies/background/
#
# -----------------------------------------------------------------------------
# STEP 4 — The rejected policy: AdmissionRequest data does not exist in a scan.
# -----------------------------------------------------------------------------
#   kubectl apply -f "$HOME/kca-lab-5.3/policy-b-restrict-registry.yaml"
#     Error from server: error when creating "...": admission webhook
#     "validate-policy.kyverno.svc" denied the request: ... rule check-registry:
#     variable {{ request.userInfo.username }} is not allowed in background mode
#
#   Kyverno refuses to store the policy rather than let it silently produce
#   wrong results. During a background scan the reports controller reads the
#   object from etcd; there is no AdmissionReview, therefore no:
#       request.userInfo.username / .groups
#       request.roles / request.clusterRoles
#       request.operation           (CREATE / UPDATE / DELETE)
#       request.oldObject
#   and no match/exclude on subjects, roles or clusterRoles.
#   request.object IS available — it is reconstructed from the stored resource.
#
#   Two possible responses, and only one is correct here:
#     (a) spec.background: false  -> the policy is accepted, but existing
#         resources are never evaluated. This is how someone "fixed" policy A.
#     (b) remove the dependency on AdmissionRequest-only data, keeping the rule
#         intent. Correct.
#
#   Edit the file and delete the whole preconditions block:
#     sed -i '/preconditions:/,/replicaset-controller"/d' \
#       "$HOME/kca-lab-5.3/policy-b-restrict-registry.yaml"
#     kubectl apply -f "$HOME/kca-lab-5.3/policy-b-restrict-registry.yaml"
#     clusterpolicy.kyverno.io/kca53-restrict-registry created
#
#   If you genuinely need to exclude controller-generated pods, express it with
#   resource data instead of user data — for example a precondition on
#   {{ request.object.metadata.ownerReferences[0].kind }} or an exclude block on
#   labels. Resource-derived expressions survive background evaluation.
#
# -----------------------------------------------------------------------------
# STEP 5 — Force a re-scan instead of waiting for the interval.
# -----------------------------------------------------------------------------
#   A policy create/update re-enqueues that policy immediately, so steps 3 and 4
#   already trigger a scan. If you need to force one:
#     kubectl -n kyverno rollout restart deploy/kyverno-reports-controller
#     kubectl -n kyverno rollout status  deploy/kyverno-reports-controller
#
#   Watch the pipeline work:
#     kubectl -n kyverno logs deploy/kyverno-reports-controller -f --tail=50
#     kubectl -n kca-bgscan get ephemeralreports.reports.kyverno.io   # >= 1.13
#     kubectl -n kca-bgscan get backgroundscanreports.kyverno.io      # 1.10-1.12
#
#   Ephemeral (intermediate) reports are produced by the admission and reports
#   controllers and then aggregated into the wgpolicyk8s.io PolicyReport /
#   ClusterPolicyReport that tooling consumes. If ephemeral reports pile up but
#   PolicyReports stay empty, the aggregation half is broken — that is the
#   reports controller again.
#
# -----------------------------------------------------------------------------
# STEP 6 — Confirm.
# -----------------------------------------------------------------------------
#   kubectl get polr -n kca-bgscan
#     NAME     KIND         NAME              PASS   FAIL   WARN   ERROR   SKIP
#     0f5a...  Deployment   bgscan-legacy     0      2      0      0       0
#     3b71...  Deployment   bgscan-compliant  2      0      0      0       0
#     a9c4...  Pod          bgscan-orphan     0      2      0      0       0
#
#   kubectl get polr -n kca-bgscan -o yaml | grep -E 'policy:|rule:|result:'
#     policy: kca53-require-runasnonroot
#     rule: autogen-check-run-as-nonroot
#     result: fail
#     ...
#
#   Note 'autogen-*': Kyverno auto-generated the equivalent rule for Pod
#   controllers, so the Deployment is evaluated as well as its Pods.
#
#   ./kca-5.3-background-scans.sh verify
#   ./kca-5.3-background-scans.sh cleanup
#
# -----------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM
# -----------------------------------------------------------------------------
#  * Background scans are executed by the REPORTS controller, not by the
#    background controller (that one handles generate and mutateExisting).
#  * spec.background (default true) controls whether a validate/verifyImages
#    rule is re-evaluated against resources already stored in etcd.
#    false => results only for resources passing through admission.
#  * Background mode forbids AdmissionRequest-only context: request.userInfo,
#    request.roles, request.clusterRoles, request.operation, request.oldObject,
#    and match/exclude on subjects/roles/clusterRoles. Kyverno REJECTS such a
#    policy at apply time when background is true.
#  * Reports are wgpolicyk8s.io/v1alpha2 PolicyReport (polr, namespaced) and
#    ClusterPolicyReport (cpolr). Since Kyverno 1.10 there is one report per
#    resource, named after the resource UID and owned by it.
#  * Only Audit-mode results become report entries you can browse; Enforce
#    blocks at admission but a background scan still records fail results for
#    resources that predate the policy.
#  * --backgroundScanInterval (default 1h) and --backgroundScanWorkers tune the
#    loop; resourceFilters in the kyverno ConfigMap plus --skipResourceFilters
#    decide what is in scope.
#  * A Ready policy with zero results is the canonical symptom: check the
#    controller, then background:true, then scope, then the interval.
# =============================================================================