#!/usr/bin/env bash
# =============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 6 · Monitoring, Reporting and Troubleshooting
#  Topic 6.1 — Policy Reports          (exam weight: 3.33%)
#
#  BREAK & FIX LAB — RUN ONLY ON A DISPOSABLE LABORATORY VM / THROWAWAY CLUSTER
#  (kind, k3s, minikube, a scratch EKS/GKE… never a cluster you care about)
#
#  WHAT THIS LAB IS ABOUT
#  ----------------------
#  A PolicyReport is not something Kyverno "prints". It is the terminal state of
#  a small distributed pipeline, and every rung of that pipeline can fail
#  independently and silently:
#
#      (a) ADMISSION PATH
#          kube-apiserver -> ValidatingWebhookConfiguration -> admission
#          controller -> evaluates the resource -> writes an *ephemeral report*
#          (reports.kyverno.io/v1 EphemeralReport, short name `ephr`;
#           pre-1.11 these were AdmissionReport / BackgroundScanReport).
#
#      (b) BACKGROUND PATH
#          reports controller -> every `backgroundScanInterval` (default 1h) and
#          on every policy change, re-evaluates *already existing* resources
#          that were admitted before the policy existed -> ephemeral report.
#          Only policies with `spec.background: true` are eligible.
#
#      (c) AGGREGATION
#          reports controller merges the ephemeral reports of a resource into a
#          durable wgpolicyk8s.io/v1alpha2 PolicyReport (`polr`, namespaced) or
#          ClusterPolicyReport (`cpolr`, cluster-scoped). Since Kyverno 1.10 the
#          aggregation key is the RESOURCE, so the report is named after the
#          resource UID and carries an ownerReference to it: delete the Pod and
#          the report is garbage-collected with it.
#
#      (d) ENGINE CONFIGURATION
#          Both paths consult the `kyverno` ConfigMap. `resourceFilters` is an
#          allow/deny list of [Kind,Namespace,Name] triplets evaluated BEFORE
#          any policy: a filtered resource is invisible to admission AND to
#          background scans, so it produces no results and no report at all.
#
#  This script builds a healthy reporting pipeline, proves it works, then
#  injects controlled faults into it. Your job is to bring the reports back.
#
#  USAGE
#  -----
#     ./kca-6.1-policy-reports-breakfix.sh            # set up + break (default)
#     ./kca-6.1-policy-reports-breakfix.sh --check    # grade your fix
#     ./kca-6.1-policy-reports-breakfix.sh --hints    # progressive hints
#     ./kca-6.1-policy-reports-breakfix.sh --restore  # undo the faults (give up)
#     ./kca-6.1-policy-reports-breakfix.sh --cleanup  # undo faults + delete lab
#
#  Environment overrides:
#     LAB_NS=kca-reports-lab   STATE_DIR=$HOME/.kca-6.1-lab
#     LAB_IMAGE=registry.k8s.io/pause:3.9   CHECK_TIMEOUT=240   FORCE=0
#
#  Requirements: kubectl (>=1.25), bash >= 4, a cluster with Kyverno >= 1.11
#  installed via the official chart (admission + background + reports
#  controllers as separate Deployments).
#
#  DO NOT read the bottom of this file until you have finished. The full,
#  step-by-step solution is there, commented out.
# =============================================================================

set -euo pipefail

LAB_NS="${LAB_NS:-kca-reports-lab}"
STATE_DIR="${STATE_DIR:-${HOME}/.kca-6.1-lab}"
LAB_IMAGE="${LAB_IMAGE:-registry.k8s.io/pause:3.9}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-240}"
FORCE="${FORCE:-0}"

POLICY_NONROOT="kca61-require-nonroot"
POLICY_LABEL="kca61-require-team-label"
POD_GOOD="compliant-app"
POD_BAD="offender-app"
FILTER_ENTRY="[*,${LAB_NS},*]"

KYVERNO_NS=""
RC_DEPLOY=""
KY_CM=""

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_OFF=""
fi

log()  { printf '%s[ lab ]%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
ok()   { printf '%s[  ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '%s[fail ]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { fail "$*"; exit 1; }
hr()   { printf '%s\n' "-------------------------------------------------------------------------------"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"; }

# ------------------------------------------------------------- discovery ----
discover_kyverno() {
  local line
  line="$(kubectl get deploy -A -l app.kubernetes.io/component=reports-controller \
            --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name \
            2>/dev/null | head -n1 || true)"
  if [ -z "$line" ]; then
    line="$(kubectl get deploy -A --no-headers \
              -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
              | awk '$2 ~ /reports-controller/ {print; exit}' || true)"
  fi
  if [ -n "$line" ]; then
    KYVERNO_NS="$(awk '{print $1}' <<<"$line")"
    RC_DEPLOY="$(awk '{print $2}' <<<"$line")"
  fi

  if [ -z "$KYVERNO_NS" ]; then
    KYVERNO_NS="$(kubectl get deploy -A --no-headers \
                    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
                    | awk '$2 ~ /kyverno/ {print $1; exit}' || true)"
  fi
  [ -n "$KYVERNO_NS" ] || die "Kyverno does not appear to be installed in this cluster."

  local cm
  for cm in $(kubectl -n "$KYVERNO_NS" get cm -o name 2>/dev/null); do
    if kubectl -n "$KYVERNO_NS" get "$cm" -o jsonpath='{.data.resourceFilters}' 2>/dev/null | grep -q '.'; then
      KY_CM="${cm#configmap/}"
      break
    fi
  done
}

preflight() {
  need kubectl
  need awk
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 required (associative arrays)."
  kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster (check your kubeconfig / context)."

  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  case "$ctx" in
    *prod*|*prd*|*production*|*live*)
      [ "$FORCE" = "1" ] || die "context '$ctx' looks like production. Refusing. Set FORCE=1 only if you are certain."
      warn "context '$ctx' looks like production and FORCE=1 was set. You own the consequences."
      ;;
  esac

  kubectl get crd policyreports.wgpolicyk8s.io >/dev/null 2>&1 \
    || die "CRD policyreports.wgpolicyk8s.io is missing — this cluster cannot store Policy Reports."

  discover_kyverno
  log "context           : ${ctx}"
  log "kyverno namespace : ${KYVERNO_NS}"
  log "reports controller: ${RC_DEPLOY:-<not found>}"
  log "kyverno configmap : ${KY_CM:-<not found>}"
  log "lab namespace     : ${LAB_NS}"
}

confirm() {
  [ "${KCA_LAB_YES:-0}" = "1" ] && return 0
  hr
  printf '%sThis will create objects and deliberately degrade the Kyverno reporting\n' "$C_BLD"
  printf 'pipeline of the cluster above. Only do this on a disposable lab cluster.%s\n' "$C_OFF"
  hr
  printf 'Type BREAK to continue: '
  local answer=""; read -r answer || true
  [ "$answer" = "BREAK" ] || die "aborted by user."
}

# ----------------------------------------------------------------- setup ----
apply_lab_objects() {
  log "creating namespace, two audit ClusterPolicies and two workloads…"

  kubectl create namespace "$LAB_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # NOTE ON API SURFACE: spec.validationFailureAction is deprecated since
  # Kyverno 1.13 in favour of the per-rule spec.rules[].validate.failureAction.
  # It is kept here because it is what still works on 1.11/1.12 too; on 1.13+
  # you will simply see a deprecation warning from the CLI.
  kubectl apply -f - >/dev/null <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_NONROOT}
  annotations:
    policies.kyverno.io/title: Require runAsNonRoot
    policies.kyverno.io/category: KCA 6.1 lab
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Audit-only control used to populate PolicyReports. Pods must declare
      spec.securityContext.runAsNonRoot=true.
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: check-run-as-non-root
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
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_LABEL}
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/category: KCA 6.1 lab
    policies.kyverno.io/severity: medium
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${LAB_NS}
      validate:
        message: "The label 'team' is required for cost attribution."
        pattern:
          metadata:
            labels:
              team: "?*"
YAML

  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_GOOD}
  namespace: ${LAB_NS}
  labels:
    app: ${POD_GOOD}
    team: platform
spec:
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: ${LAB_IMAGE}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_BAD}
  namespace: ${LAB_NS}
  labels:
    app: ${POD_BAD}
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: app
      image: ${LAB_IMAGE}
YAML

  kubectl -n "$LAB_NS" wait --for=condition=Ready "pod/${POD_GOOD}" --timeout=120s >/dev/null
  kubectl -n "$LAB_NS" wait --for=condition=Ready "pod/${POD_BAD}"  --timeout=120s >/dev/null
  ok "workloads are Running (${POD_GOOD} is compliant, ${POD_BAD} violates both policies)."
}

# Emits one line per result:  <resourceName>|<policy>|<result>
collect_results() {
  local r scope res
  for r in $(kubectl -n "$LAB_NS" get polr -o name 2>/dev/null); do
    scope="$(kubectl -n "$LAB_NS" get "$r" -o jsonpath='{.scope.name}' 2>/dev/null || true)"
    if [ -z "$scope" ]; then
      scope="$(kubectl -n "$LAB_NS" get "$r" -o jsonpath='{.results[0].resources[0].name}' 2>/dev/null || true)"
    fi
    res="$(kubectl -n "$LAB_NS" get "$r" \
             -o jsonpath='{range .results[*]}{.policy}|{.result}{"\n"}{end}' 2>/dev/null || true)"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s|%s\n' "$scope" "$line"
    done <<<"$res"
  done
}

count_expected_results() {
  local out; out="$(collect_results)"
  local n=0
  grep -Fq "${POD_BAD}|${POLICY_NONROOT}|fail" <<<"$out" && n=$((n+1))
  grep -Fq "${POD_BAD}|${POLICY_LABEL}|fail"   <<<"$out" && n=$((n+1))
  grep -Fq "${POD_GOOD}|${POLICY_NONROOT}|pass" <<<"$out" && n=$((n+1))
  grep -Fq "${POD_GOOD}|${POLICY_LABEL}|pass"   <<<"$out" && n=$((n+1))
  printf '%s' "$n"
}

wait_for_reports() {
  local timeout="$1" waited=0 n
  while [ "$waited" -lt "$timeout" ]; do
    n="$(count_expected_results)"
    [ "$n" -eq 4 ] && { printf '%s' "$n"; return 0; }
    sleep 5; waited=$((waited+5))
  done
  printf '%s' "$(count_expected_results)"
  return 1
}

show_reports() {
  hr
  printf '%s$ kubectl get policyreport -n %s%s\n' "$C_BLD" "$LAB_NS" "$C_OFF"
  kubectl get policyreport -n "$LAB_NS" 2>&1 || true
  hr
}

baseline() {
  log "waiting for the reporting pipeline to converge (admission + aggregation)…"
  local n; n="$(wait_for_reports 150)" || true
  show_reports
  if [ "$n" -eq 4 ]; then
    ok "healthy baseline: 4 results across 2 PolicyReports (one report per resource UID)."
    cat <<'TXT'
       Reference output (column set varies slightly by Kyverno version):

         NAME                                   KIND   NAME            PASS  FAIL  WARN  ERROR  SKIP  AGE
         3a1f0c8e-...-0b7d2a91c4e5              Pod    compliant-app   2     0     0     0      0     12s
         9c74d2b1-...-5f3e8ab07d16              Pod    offender-app    0     2     0     0      0     12s

       The report NAME is the UID of the reported resource, and the report is
       owned by it (ownerReferences), which is why reports disappear with their
       workload. On Kyverno < 1.10 you would instead see one `polr-ns-<ns>`
       object per namespace holding every result.
TXT
  else
    warn "only ${n}/4 expected results materialised before the timeout."
    warn "The lab will continue, but investigate your Kyverno install first"
    warn "(admission webhook reachable? reports controller running? admissionReports enabled?)."
  fi
}

# ------------------------------------------------------------- the break ----
save_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  kubectl config current-context > "$STATE_DIR/context" 2>/dev/null || true
  printf '%s\n' "$KYVERNO_NS" > "$STATE_DIR/kyverno-ns"
  printf '%s\n' "$RC_DEPLOY"  > "$STATE_DIR/rc-deploy"
  printf '%s\n' "$KY_CM"      > "$STATE_DIR/kyverno-cm-name"
  kubectl -n "$LAB_NS" get pod "$POD_GOOD" "$POD_BAD" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{"\n"}{end}' \
    > "$STATE_DIR/pod-uids"
  : > "$STATE_DIR/faults"
}

record_fault() { printf '%s\n' "$1" >> "$STATE_DIR/faults"; }

break_it() {
  log "injecting faults into the reporting pipeline…"

  # -- fault: engine-level resource filtering -------------------------------
  if [ -n "$KY_CM" ]; then
    local orig
    orig="$(kubectl -n "$KYVERNO_NS" get cm "$KY_CM" -o jsonpath='{.data.resourceFilters}')"
    kubectl -n "$KYVERNO_NS" get cm "$KY_CM" -o yaml > "$STATE_DIR/kyverno-cm.yaml"
    printf '%s' "$orig" > "$STATE_DIR/resourceFilters.orig"
    if ! grep -Fq "$FILTER_ENTRY" <<<"$orig"; then
      # Kyverno's default filter list never contains " or \, so plain
      # interpolation into a strategic-merge patch is safe here.
      kubectl -n "$KYVERNO_NS" patch cm "$KY_CM" --type merge \
        -p "{\"data\":{\"resourceFilters\":\"${orig}${FILTER_ENTRY}\"}}" >/dev/null
      record_fault "resourceFilters"
    fi
  else
    warn "no ConfigMap with a resourceFilters key was found; skipping that fault."
  fi

  # -- fault: policies removed from background scanning ---------------------
  local p
  for p in "$POLICY_NONROOT" "$POLICY_LABEL"; do
    kubectl patch clusterpolicy "$p" --type merge -p '{"spec":{"background":false}}' >/dev/null
  done
  record_fault "background"

  # -- fault: the aggregator itself is gone ---------------------------------
  if [ -n "$RC_DEPLOY" ]; then
    local replicas
    replicas="$(kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" -o jsonpath='{.spec.replicas}')"
    printf '%s' "${replicas:-1}" > "$STATE_DIR/rc-replicas"
    kubectl -n "$KYVERNO_NS" scale deploy "$RC_DEPLOY" --replicas=0 >/dev/null
    kubectl -n "$KYVERNO_NS" wait --for=delete pod \
      -l app.kubernetes.io/component=reports-controller --timeout=90s >/dev/null 2>&1 || true
    record_fault "reports-controller"
  else
    warn "reports controller Deployment not found; skipping that fault."
  fi

  # -- materialise the symptom deterministically ----------------------------
  kubectl -n "$LAB_NS" delete policyreport --all >/dev/null 2>&1 || true
  kubectl -n "$LAB_NS" delete ephemeralreports.reports.kyverno.io --all >/dev/null 2>&1 || true

  ok "faults injected. State saved to ${STATE_DIR} (do not read it — that is the answer key)."
}

briefing() {
  cat <<TXT

$(hr)
${C_BLD}KCA 6.1 — POLICY REPORTS · BREAK & FIX${C_OFF}
$(hr)

${C_BLD}SYMPTOM${C_OFF}
  Compliance reporting for namespace '${LAB_NS}' has gone dark. The two audit
  ClusterPolicies still exist, both workloads are still Running and one of them
  (${POD_BAD}) still violates both policies — yet:

      \$ kubectl get policyreport -n ${LAB_NS}
      No resources found in ${LAB_NS} namespace.

      \$ kubectl get cpolr
      (no entry covering these workloads)

  Nothing is CrashLooping. The API server is healthy. No error is printed
  anywhere by kubectl. This is exactly how reporting failures show up in
  production: as an absence, which every dashboard happily renders as "0
  violations — compliant".

${C_BLD}YOUR MISSION${C_OFF}
  Restore the reporting pipeline until a PolicyReport again exists for BOTH
  pods, containing all four results:

      ${POD_BAD}   -> fail  (${POLICY_NONROOT})
      ${POD_BAD}   -> fail  (${POLICY_LABEL})
      ${POD_GOOD}  -> pass  (${POLICY_NONROOT})
      ${POD_GOOD}  -> pass  (${POLICY_LABEL})

${C_BLD}CONSTRAINTS (this is what makes it a real exercise)${C_OFF}
  1. Do NOT delete, recreate, restart or edit the two Pods. Their UIDs were
     recorded; recreating them would recreate the reports through the admission
     path and hide the actual defect. The grader fails you for it.
  2. Do NOT delete or recreate the two ClusterPolicies — repair them in place.
  3. Do NOT reinstall or 'helm upgrade' Kyverno. Every fault is repairable with
     kubectl against objects that already exist.
  4. There is more than one fault, layered: fixing one will not bring the
     reports back on its own.

${C_BLD}WHERE TO LOOK (in pipeline order, not in panic order)${C_OFF}
  kubectl -n ${LAB_NS} get pods --show-labels
  kubectl get clusterpolicy                       # note the ADMISSION / BACKGROUND / READY columns
  kubectl describe clusterpolicy ${POLICY_NONROOT}
  kubectl -n ${KYVERNO_NS} get deploy,pods
  kubectl -n ${KYVERNO_NS} logs deploy/${RC_DEPLOY:-kyverno-reports-controller} --tail=100
  kubectl -n ${KYVERNO_NS} get cm ${KY_CM:-kyverno} -o yaml
  kubectl get ephemeralreports.reports.kyverno.io -A      # the intermediate objects
  kubectl get polr -A ; kubectl get cpolr
  kubectl get polr -n ${LAB_NS} -o yaml                   # results[], summary{}, scope{}
  kubectl explain policyreport.results

  Useful cross-check that isolates policy logic from cluster plumbing — if the
  Kyverno CLI produces the report offline, the policy is not the problem:
      kubectl get pod ${POD_BAD} -n ${LAB_NS} -o yaml > /tmp/pod.yaml
      kubectl get cpol ${POLICY_NONROOT} -o yaml > /tmp/pol.yaml
      kyverno apply /tmp/pol.yaml --resource /tmp/pod.yaml --policy-report

${C_BLD}HOW YOU KNOW YOU ARE DONE${C_OFF}
      $0 --check
  It polls for up to ${CHECK_TIMEOUT}s, because a repaired background scan is not
  instantaneous. Stuck? '$0 --hints' gives three escalating hints.
  Given up? '$0 --restore'. Finished? '$0 --cleanup'.

  Suggested time budget: 20–30 minutes.
$(hr)
TXT
}

# ------------------------------------------------------------------ hints ---
hints() {
  cat <<TXT
$(hr)
HINT 1 — Reports have producers. A PolicyReport for a resource that was
         admitted BEFORE the last relevant change is produced by a scan, not by
         admission. Ask yourself which component runs that scan, and whether it
         is currently running at all.

HINT 2 — Not every policy is eligible for that scan. There is one boolean in
         the ClusterPolicy spec that removes a policy from it entirely, and
         'kubectl get clusterpolicy' prints it as a column.

HINT 3 — Even a healthy controller evaluating an eligible policy will report
         nothing about a resource the engine has been told to ignore. That
         instruction is not in the policy: it is in Kyverno's ConfigMap, it is
         a list of [Kind,Namespace,Name] triplets, and it is applied before any
         rule is evaluated. After correcting it, force a fresh full scan
         instead of waiting for backgroundScanInterval (default 1h).
$(hr)
TXT
}

# ------------------------------------------------------------------ check ---
check() {
  preflight
  [ -d "$STATE_DIR" ] || die "no lab state in ${STATE_DIR}. Run the script without arguments first."

  local errors=0

  # constraint: original workloads
  local name uid current
  while IFS='=' read -r name uid; do
    [ -n "$name" ] || continue
    current="$(kubectl -n "$LAB_NS" get pod "$name" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    if [ -z "$current" ]; then
      fail "pod '${name}' no longer exists — constraint 1 violated."
      errors=$((errors+1))
    elif [ "$current" != "$uid" ]; then
      fail "pod '${name}' was recreated (UID changed) — constraint 1 violated."
      fail "  The exercise is about the background/aggregation path, not about re-admission."
      errors=$((errors+1))
    fi
  done < "$STATE_DIR/pod-uids"
  [ "$errors" -eq 0 ] && ok "original workloads intact (untouched UIDs)."

  log "polling the reporting pipeline for up to ${CHECK_TIMEOUT}s…"
  local n; n="$(wait_for_reports "$CHECK_TIMEOUT")" || true
  show_reports

  if [ "$n" -ne 4 ]; then
    fail "${n}/4 expected results present. Missing:"
    local out; out="$(collect_results)"
    grep -Fq "${POD_BAD}|${POLICY_NONROOT}|fail"  <<<"$out" || fail "  ${POD_BAD}  -> fail (${POLICY_NONROOT})"
    grep -Fq "${POD_BAD}|${POLICY_LABEL}|fail"    <<<"$out" || fail "  ${POD_BAD}  -> fail (${POLICY_LABEL})"
    grep -Fq "${POD_GOOD}|${POLICY_NONROOT}|pass" <<<"$out" || fail "  ${POD_GOOD} -> pass (${POLICY_NONROOT})"
    grep -Fq "${POD_GOOD}|${POLICY_LABEL}|pass"   <<<"$out" || fail "  ${POD_GOOD} -> pass (${POLICY_LABEL})"
    errors=$((errors+1))
  else
    ok "all four expected results are present in the namespace PolicyReports."
  fi

  # substance checks: the results must come from a genuinely healthy pipeline
  local p bg
  for p in "$POLICY_NONROOT" "$POLICY_LABEL"; do
    bg="$(kubectl get clusterpolicy "$p" -o jsonpath='{.spec.background}' 2>/dev/null || true)"
    if [ "$bg" = "false" ]; then
      fail "clusterpolicy/${p} is still excluded from background scanning."
      errors=$((errors+1))
    fi
  done

  if [ -n "$KY_CM" ] && kubectl -n "$KYVERNO_NS" get cm "$KY_CM" \
        -o jsonpath='{.data.resourceFilters}' 2>/dev/null | grep -Fq "$LAB_NS"; then
    fail "namespace '${LAB_NS}' is still excluded by the engine's resourceFilters."
    errors=$((errors+1))
  fi

  if [ -n "$RC_DEPLOY" ]; then
    local ready
    ready="$(kubectl -n "$KYVERNO_NS" get deploy "$RC_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [ -z "$ready" ] || [ "$ready" -lt 1 ] 2>/dev/null; then
      fail "deployment ${KYVERNO_NS}/${RC_DEPLOY} has no ready replica."
      errors=$((errors+1))
    fi
  fi

  hr
  if [ "$errors" -eq 0 ]; then
    ok "${C_BLD}LAB PASSED${C_OFF} — the reporting pipeline is healthy end to end."
    log "Run '$0 --cleanup' to return the cluster to its original state."
    return 0
  fi
  fail "${C_BLD}LAB NOT PASSED${C_OFF} — ${errors} condition(s) still failing. Keep going ('$0 --hints')."
  return 1
}

# ---------------------------------------------------------------- restore ---
restore() {
  preflight
  [ -d "$STATE_DIR" ] || die "no lab state in ${STATE_DIR}."
  local faults=""; [ -f "$STATE_DIR/faults" ] && faults="$(cat "$STATE_DIR/faults")"
  local ns cm rc
  ns="$(cat "$STATE_DIR/kyverno-ns" 2>/dev/null || echo "$KYVERNO_NS")"
  cm="$(cat "$STATE_DIR/kyverno-cm-name" 2>/dev/null || echo "$KY_CM")"
  rc="$(cat "$STATE_DIR/rc-deploy" 2>/dev/null || echo "$RC_DEPLOY")"

  if grep -q '^resourceFilters$' <<<"$faults" && [ -n "$cm" ]; then
    local orig; orig="$(cat "$STATE_DIR/resourceFilters.orig")"
    kubectl -n "$ns" patch cm "$cm" --type merge \
      -p "{\"data\":{\"resourceFilters\":\"${orig}\"}}" >/dev/null
    ok "resourceFilters restored in ${ns}/${cm}."
  fi

  if grep -q '^background$' <<<"$faults"; then
    local p
    for p in "$POLICY_NONROOT" "$POLICY_LABEL"; do
      kubectl patch clusterpolicy "$p" --type merge \
        -p '{"spec":{"background":true}}' >/dev/null 2>&1 || true
    done
    ok "background scanning re-enabled on both lab policies."
  fi

  if grep -q '^reports-controller$' <<<"$faults" && [ -n "$rc" ]; then
    local r; r="$(cat "$STATE_DIR/rc-replicas" 2>/dev/null || echo 1)"
    kubectl -n "$ns" scale deploy "$rc" --replicas="${r:-1}" >/dev/null
    kubectl -n "$ns" rollout status deploy "$rc" --timeout=120s >/dev/null || true
    ok "reports controller scaled back to ${r:-1}."
  fi

  kubectl -n "$ns" rollout restart deploy \
    -l app.kubernetes.io/part-of=kyverno >/dev/null 2>&1 \
    || kubectl -n "$ns" rollout restart deploy >/dev/null 2>&1 || true
  ok "Kyverno controllers restarted to force a fresh full background scan."
}

cleanup() {
  restore || true
  kubectl delete clusterpolicy "$POLICY_NONROOT" "$POLICY_LABEL" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "$LAB_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
  ok "lab objects deleted and state removed. Kyverno itself was left installed."
}

usage() { sed -n '2,60p' "$0"; }

main() {
  case "${1:-}" in
    ""|--break)  preflight; confirm; save_state; apply_lab_objects; baseline; break_it; briefing ;;
    --check)     check ;;
    --hints)     hints ;;
    --restore)   restore ;;
    --cleanup)   cleanup ;;
    -h|--help)   usage ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
}

main "$@"
exit 0

# =============================================================================
# ==                                                                         ==
# ==   S O L U T I O N   —   D O   N O T   R E A D   B E F O R E   T R Y I N G ==
# ==                                                                         ==
# =============================================================================
#
# THREE FAULTS WERE INJECTED, LAYERED SO THAT NO SINGLE FIX RESTORES THE REPORTS:
#
#   F1. The lab namespace was appended to `resourceFilters` in the `kyverno`
#       ConfigMap  ->  the engine ignores every resource in it, for admission
#       and for background scans alike.
#   F2. `spec.background: false` was patched into both ClusterPolicies
#       ->  the policies are no longer eligible for background scanning, so
#       already-admitted Pods are never re-evaluated.
#   F3. The reports controller Deployment was scaled to 0
#       ->  nothing aggregates ephemeral reports into PolicyReports, and no
#       background scan runs at all.
#   Plus: the existing PolicyReports were deleted, so the symptom is a clean
#       absence instead of a stale report (stale reports are the other, nastier
#       production symptom: numbers that no longer move).
#
# -----------------------------------------------------------------------------
# STEP 0 — Reproduce and bound the problem
# -----------------------------------------------------------------------------
#   kubectl get policyreport -n kca-reports-lab
#   kubectl get cpolr
#   kubectl get ephemeralreports.reports.kyverno.io -A
#
#   No `polr`, and no `ephr` either. That is the first real datum: the absence
#   starts UPSTREAM of aggregation. If ephemeral reports existed but no polr,
#   the fault would be in aggregation only.
#
# -----------------------------------------------------------------------------
# STEP 1 — Prove the inputs are still valid (never debug a pipeline from the end)
# -----------------------------------------------------------------------------
#   kubectl -n kca-reports-lab get pods --show-labels
#   kubectl get clusterpolicy
#
#     NAME                       ADMISSION   BACKGROUND   READY   AGE
#     kca61-require-nonroot      true        false        True    5m
#     kca61-require-team-label   true        false        True    5m
#                                            ^^^^^ FAULT 2 is visible right here
#
#   The policies are READY=True (they compiled and the webhook is configured),
#   they still match Pods in the namespace, and the offending Pod still offends:
#
#   kubectl -n kca-reports-lab get pod offender-app -o jsonpath='{.spec.securityContext}'
#   (empty  -> it does violate require-nonroot; the policy logic is not at fault)
#
#   Optional offline confirmation, fully independent of the cluster pipeline:
#     kubectl get pod offender-app -n kca-reports-lab -o yaml > /tmp/pod.yaml
#     kubectl get cpol kca61-require-nonroot -o yaml       > /tmp/pol.yaml
#     kyverno apply /tmp/pol.yaml --resource /tmp/pod.yaml --policy-report
#   The CLI prints a PolicyReport with a `fail` result -> policy is correct,
#   therefore the defect is in the cluster's reporting machinery.
#
# -----------------------------------------------------------------------------
# STEP 2 — Fix F3: bring the producer/aggregator back
# -----------------------------------------------------------------------------
#   kubectl -n kyverno get deploy
#
#     NAME                          READY   UP-TO-DATE   AVAILABLE
#     kyverno-admission-controller   1/1     1            1
#     kyverno-background-controller  1/1     1            1
#     kyverno-cleanup-controller     1/1     1            1
#     kyverno-reports-controller     0/0     0            0      <-- FAULT 3
#
#   kubectl -n kyverno scale deploy/kyverno-reports-controller --replicas=1
#   kubectl -n kyverno rollout status deploy/kyverno-reports-controller
#
#   Do not confuse the controllers: the BACKGROUND controller executes
#   generate/mutateExisting rules; the REPORTS controller runs background scans
#   for validate rules and aggregates reports. Only the latter feeds `polr`.
#
#   Recheck — still nothing:
#   kubectl get polr -n kca-reports-lab      # No resources found
#
# -----------------------------------------------------------------------------
# STEP 3 — Fix F2: make the policies eligible for background scanning
# -----------------------------------------------------------------------------
#   kubectl patch clusterpolicy kca61-require-nonroot    --type merge -p '{"spec":{"background":true}}'
#   kubectl patch clusterpolicy kca61-require-team-label --type merge -p '{"spec":{"background":true}}'
#   kubectl get clusterpolicy      # BACKGROUND must now read true / true
#
#   Why this matters and why the exam asks about it: `background: false` is
#   mandatory whenever a rule references admission-only context such as
#   `request.userInfo`, `request.operation` or `AdmissionRequest` roles — that
#   data does not exist during a scan. The price is that such policies can only
#   ever report on resources at admission time; pre-existing resources stay
#   invisible in reports forever. It is a genuine trade-off, not a bug.
#
#   Recheck — STILL nothing. Two faults fixed, symptom unchanged. Resist the
#   temptation to recreate the Pod: that would only mask the third fault.
#
# -----------------------------------------------------------------------------
# STEP 4 — Fix F1: the engine was told to ignore the namespace
# -----------------------------------------------------------------------------
#   kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=50
#     (clean: no RBAC 'forbidden', no panics — the controller is happily doing
#      nothing, which is precisely the tell)
#
#   kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n'
#     ...
#     [Node,*,*]
#     [*,kube-system,*]
#     [*,kyverno,*]
#     [*,kca-reports-lab,*]      <-- FAULT 1
#
#   Remove that single triplet, preserving everything else:
#     kubectl -n kyverno edit cm kyverno        # delete [*,kca-reports-lab,*]
#   or, non-interactively:
#     ORIG=$(kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}')
#     NEW=${ORIG/\[\*,kca-reports-lab,\*\]/}
#     kubectl -n kyverno patch cm kyverno --type merge \
#       -p "{\"data\":{\"resourceFilters\":\"${NEW}\"}}"
#
#   Never rewrite the whole list from memory: dropping the built-in excludes
#   ([Event,*,*], [*,kube-system,*], [Node,*,*], the SubjectAccessReview family,
#   Kyverno's own namespace…) puts the webhook in the path of core control-plane
#   traffic and can wedge the cluster.
#
#   Then force a fresh full scan instead of waiting for backgroundScanInterval
#   (default 1h):
#     kubectl -n kyverno rollout restart deploy/kyverno-reports-controller
#     kubectl -n kyverno rollout restart deploy/kyverno-admission-controller
#     kubectl -n kyverno rollout status  deploy/kyverno-reports-controller
#
# -----------------------------------------------------------------------------
# STEP 5 — Verify
# -----------------------------------------------------------------------------
#   kubectl get ephemeralreports.reports.kyverno.io -n kca-reports-lab   # transient
#   kubectl get polr -n kca-reports-lab
#
#     NAME                                   KIND   NAME            PASS  FAIL  WARN  ERROR  SKIP  AGE
#     3a1f0c8e-...-0b7d2a91c4e5              Pod    compliant-app   2     0     0     0      0     30s
#     9c74d2b1-...-5f3e8ab07d16              Pod    offender-app    0     2     0     0      0     30s
#
#   kubectl -n kca-reports-lab get polr -o yaml | grep -A6 'results:'
#     results:
#     - message: 'validation error: spec.securityContext.runAsNonRoot must be set to true.
#         rule check-run-as-non-root failed at path /spec/securityContext/'
#       policy: kca61-require-nonroot
#       result: fail
#       rule: check-run-as-non-root
#       scored: true
#       severity: high
#       source: kyverno
#
#   Fleet-wide views you should be fluent with for the exam:
#     kubectl get polr -A
#     kubectl get cpolr                                   # cluster-scoped resources
#     kubectl get polr -A -o jsonpath='{range .items[*]}{range .results[?(@.result=="fail")]}{.policy}{"\n"}{end}{end}' | sort | uniq -c
#     kubectl get polr -A -o custom-columns=NS:.metadata.namespace,FAIL:.summary.fail
#
#   Finally:  ./kca-6.1-policy-reports-breakfix.sh --check
#   Cleanup:  ./kca-6.1-policy-reports-breakfix.sh --cleanup
#
# -----------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM (AND INTO PRODUCTION)
# -----------------------------------------------------------------------------
#   * PolicyReport / ClusterPolicyReport are wgpolicyk8s.io/v1alpha2 objects
#     defined by the Kubernetes Policy WG, not by Kyverno. Kyverno is one
#     producer among several (kube-bench, Trivy, Falco… write the same CRD),
#     which is why every result carries `source: kyverno`.
#   * Fields you must recognise: `scope` (the reported resource), `summary`
#     (pass/fail/warn/error/skip counters) and `results[]` with
#     policy, rule, result, severity, category, scored, message, source.
#   * `result: fail` means a violation of an Audit policy. Enforce-mode
#     violations are usually never reported at all: the resource is rejected at
#     admission and therefore never exists to be reported on. An empty report is
#     not proof of compliance.
#   * Two independent producers: admission-time evaluation and background scans.
#     `spec.background`, the reports controller's replica count, and
#     `backgroundScanInterval` govern the second one only.
#   * `resourceFilters` in the `kyverno` ConfigMap short-circuits BOTH producers,
#     before any rule runs. It is the first place to look for "my policy simply
#     does not apply here", together with the namespaceSelector of the
#     ValidatingWebhookConfiguration.
#   * Reports are owned by the reported resource (Kyverno >= 1.10, one report per
#     resource, named after its UID); deleting a workload deletes its report, and
#     `kubectl get polr` counts are therefore a live view, not an audit log. If
#     you need history, scrape the `kyverno_policy_results_total` metric or ship
#     the reports to an external store — Policy Reporter is the common choice.
#
# REFERENCES (official)
#   - Kyverno — Policy Reports:            https://kyverno.io/docs/policy-reports/
#   - Kyverno — Background scans:          https://kyverno.io/docs/writing-policies/background/
#   - Kyverno — Installation/customization (ConfigMap keys, resourceFilters):
#                                          https://kyverno.io/docs/installation/customization/
#   - Kyverno — Troubleshooting:           https://kyverno.io/docs/troubleshooting/
#   - Kyverno CLI (`apply --policy-report`): https://kyverno.io/docs/kyverno-cli/
#   - Kubernetes Policy WG, PolicyReport CRD:
#       https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report
#   - KCA curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
# =============================================================================