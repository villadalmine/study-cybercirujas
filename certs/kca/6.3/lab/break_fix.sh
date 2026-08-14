#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kubernetes and Cloud Native Associate
#  Domain 6: Platform Security / Policy Engines
#  Topic 6.3 — Kyverno Metrics                                (exam weight 3.33)
#
#  BREAK & FIX LAB — "the policy engine is enforcing, but the dashboard is blind"
#
#  WHAT THIS SCRIPT DOES
#    1. Verifies you are on a DISPOSABLE lab cluster (kind / k3d / minikube / k3s).
#    2. Makes sure Kyverno is installed and healthy.
#    3. Builds a small workload namespace + a ClusterPolicy, and drives real
#       admission traffic through it so the metrics counters have data.
#    4. Shows you a HEALTHY baseline of the metrics endpoint.
#    5. Injects three independent, fully reversible faults into the *observability
#       path only* — the enforcement path keeps working, which is exactly what
#       makes this class of incident dangerous in production.
#    6. Prints your mission and leaves you alone.
#
#  Everything it touches is backed up to $BACKUP_DIR first, and `restore` puts
#  it all back. No cluster-wide deletions, no CRD changes, no RBAC changes.
#
#  Reference material (official sources):
#    - Kyverno monitoring & metrics ........ https://kyverno.io/docs/monitoring/
#    - Kyverno installation customization .. https://kyverno.io/docs/installation/customization/
#    - Kyverno source & flags .............. https://github.com/kyverno/kyverno
#    - Service targetPort semantics ........ https://kubernetes.io/docs/concepts/services-networking/service/
#    - Prometheus exposition format ........ https://prometheus.io/docs/instrumenting/exposition_formats/
#    - KCA curriculum ...................... https://github.com/cncf/curriculum
#
#  USAGE
#    ./kca-6.3-kyverno-metrics-break-fix.sh            # setup + break (default)
#    ./kca-6.3-kyverno-metrics-break-fix.sh status     # show current state
#    ./kca-6.3-kyverno-metrics-break-fix.sh traffic    # generate more admission traffic
#    ./kca-6.3-kyverno-metrics-break-fix.sh verify     # grade your fix
#    ./kca-6.3-kyverno-metrics-break-fix.sh restore    # emergency undo (spoils the lab)
#    ./kca-6.3-kyverno-metrics-break-fix.sh cleanup    # restore + delete the lab namespace/policy
#
#  ENV
#    KYVERNO_NS=kyverno      override Kyverno namespace autodetection
#    LAB_FORCE=1             bypass the "is this really a lab cluster?" guard
#    ASSUME_YES=1            do not prompt
# ============================================================================

set -euo pipefail

LAB_NS="${LAB_NS:-kca-metrics-lab}"
POLICY_NAME="kca-6-3-require-team-label"
BACKUP_DIR="${BACKUP_DIR:-/var/tmp/kca-6.3-break-fix}"
METRICS_CONTAINER_PORT=8000

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_C=$'\033[36m'; C_M=$'\033[35m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_M=""
fi

hr()   { printf '%s\n' "------------------------------------------------------------------------"; }
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_B$C_C" "$*" "$C_RST"; }
ok()   { printf '%s[ OK ]%s %s\n'   "$C_G" "$C_RST" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n'   "$C_R" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n'   "$C_Y" "$C_RST" "$*"; }
die()  { printf '%s[STOP]%s %s\n'   "$C_R" "$C_RST" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply || true
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Safety guard: this script mutates the Kyverno namespace. Refuse to do that on
# anything that does not look like a throwaway cluster.
# ---------------------------------------------------------------------------
guard_lab() {
  local ctx nodes
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  case "$ctx" in
    kind-*|k3d-*|minikube*|default|k3s*|*lab*|*sandbox*|*test*|*dev*) ;;
    *)
      if [[ "${LAB_FORCE:-0}" != "1" ]]; then
        bad "kubectl context '$ctx' does not look like a disposable lab cluster."
        say "     This lab patches the Kyverno Service and the Kyverno metrics ConfigMap."
        say "     If this really is a throwaway VM, re-run with: LAB_FORCE=1 $0 $*"
        exit 1
      fi
      warn "LAB_FORCE=1 set — proceeding on context '$ctx' at your own risk."
      ;;
  esac
  if [[ "$nodes" -gt 5 && "${LAB_FORCE:-0}" != "1" ]]; then
    die "cluster has $nodes nodes; that is not a lab VM. Set LAB_FORCE=1 to override."
  fi
  ok "lab guard passed (context=$ctx, nodes=$nodes)"
}

# ---------------------------------------------------------------------------
# Discovery. Kyverno 1.10+ splits into admission / background / cleanup /
# reports controllers, each with its own metrics Service on port 8000.
# The admission controller is the one that records admission-time policy results.
# ---------------------------------------------------------------------------
detect_kyverno() {
  if [[ -z "${KYVERNO_NS:-}" ]]; then
    KYVERNO_NS="$(kubectl get deploy -A \
      -l app.kubernetes.io/part-of=kyverno,app.kubernetes.io/component=admission-controller \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  fi
  [[ -z "${KYVERNO_NS:-}" ]] && KYVERNO_NS="kyverno"

  kubectl get ns "$KYVERNO_NS" >/dev/null 2>&1 || return 1

  ADM_DEPLOY="$(kubectl -n "$KYVERNO_NS" get deploy \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -m1 -E '^kyverno(-admission-controller)?$' || true)"
  [[ -z "${ADM_DEPLOY:-}" ]] && return 1

  METRICS_SVC="$(kubectl -n "$KYVERNO_NS" get svc \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -m1 -E '^kyverno-svc-metrics$' || true)"
  if [[ -z "${METRICS_SVC:-}" ]]; then
    METRICS_SVC="$(kubectl -n "$KYVERNO_NS" get svc \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -m1 -E 'metrics$' || true)"
  fi
  [[ -z "${METRICS_SVC:-}" ]] && return 1

  # The metrics ConfigMap name comes from the --metricsConfig flag; default is
  # "kyverno-metrics". Read it from the running args instead of assuming.
  METRICS_CM="$(kubectl -n "$KYVERNO_NS" get deploy "$ADM_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[*].args}' 2>/dev/null \
    | tr ',' '\n' | tr -d '"[]' | grep -m1 -oE 'metricsConfig=[A-Za-z0-9._-]+' \
    | cut -d= -f2 || true)"
  [[ -z "${METRICS_CM:-}" ]] && METRICS_CM="kyverno-metrics"
  return 0
}

ensure_kyverno() {
  if detect_kyverno; then
    ok "Kyverno found: ns=$KYVERNO_NS deploy=$ADM_DEPLOY svc=$METRICS_SVC cm=$METRICS_CM"
    return 0
  fi
  warn "Kyverno is not installed on this cluster."
  command -v helm >/dev/null 2>&1 || die "helm not found — install Kyverno first: https://kyverno.io/docs/installation/"
  confirm "Install Kyverno now with Helm into namespace 'kyverno'?" || die "aborted by user"
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo update kyverno >/dev/null
  helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 10m
  detect_kyverno || die "Kyverno install finished but discovery still fails"
  ok "Kyverno installed: ns=$KYVERNO_NS deploy=$ADM_DEPLOY svc=$METRICS_SVC cm=$METRICS_CM"
}

wait_rollout() {
  kubectl -n "$KYVERNO_NS" rollout status "deploy/$ADM_DEPLOY" --timeout=240s >/dev/null \
    || warn "rollout did not converge within 240s — check 'kubectl -n $KYVERNO_NS get pods'"
}

# ---------------------------------------------------------------------------
# Scrape /metrics through an arbitrary target (svc/... or deploy/...).
# Going through svc/ exercises the Service port -> targetPort translation,
# which is exactly the path Prometheus uses. Going through deploy/ bypasses it.
# ---------------------------------------------------------------------------
fetch_metrics() {
  local target="$1" lport out pf
  lport=$(( 18000 + RANDOM % 2000 ))
  out="$(mktemp)"
  kubectl -n "$KYVERNO_NS" port-forward "$target" "${lport}:${METRICS_CONTAINER_PORT}" \
    >/dev/null 2>&1 &
  pf=$!
  sleep 3
  curl -sS --max-time 12 "http://127.0.0.1:${lport}/metrics" >"$out" 2>/dev/null || true
  kill "$pf" >/dev/null 2>&1 || true
  wait "$pf" 2>/dev/null || true
  cat "$out"
  rm -f "$out"
}

# ---------------------------------------------------------------------------
# Lab workload: a namespace, a ClusterPolicy in Enforce mode, and traffic.
# The policy shape is version-tolerant: Kyverno 1.13+ moved the enforcement
# switch from spec.validationFailureAction to spec.rules[].validate.failureAction.
# ---------------------------------------------------------------------------
apply_policy() {
  if kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: $POLICY_NAME
  annotations:
    policies.kyverno.io/title: Require team label (KCA 6.3 metrics lab)
    policies.kyverno.io/category: Lab
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - $LAB_NS
      validate:
        message: "Pods in $LAB_NS must carry a non-empty 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
  then
    ok "ClusterPolicy/$POLICY_NAME applied (spec.validationFailureAction: Enforce)"
    return 0
  fi

  kubectl apply -f - >/dev/null <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: $POLICY_NAME
spec:
  background: false
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - $LAB_NS
      validate:
        failureAction: Enforce
        message: "Pods in $LAB_NS must carry a non-empty 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
  ok "ClusterPolicy/$POLICY_NAME applied (rules[].validate.failureAction: Enforce)"
}

gen_traffic() {
  local rounds="${1:-4}" i
  for (( i = 1; i <= rounds; i++ )); do
    # Compliant Pod -> admission ALLOWED  -> rule_result="pass"
    kubectl -n "$LAB_NS" run "kca-pass-$i" \
      --image=registry.k8s.io/pause:3.9 --restart=Never \
      --labels="team=platform,lab=kca-6-3" >/dev/null 2>&1 || true
    # Non-compliant Pod -> admission DENIED -> rule_result="fail"
    kubectl -n "$LAB_NS" run "kca-fail-$i" \
      --image=registry.k8s.io/pause:3.9 --restart=Never \
      --labels="lab=kca-6-3" >/dev/null 2>&1 || true
  done
  kubectl -n "$LAB_NS" delete pod -l lab=kca-6-3 --wait=false --ignore-not-found >/dev/null 2>&1 || true
  ok "generated $((rounds * 2)) admission requests against $LAB_NS (half of them denied)"
}

setup_lab() {
  step "Building the lab workload"
  kubectl create ns "$LAB_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "namespace/$LAB_NS ready"
  apply_policy
  kubectl wait --for=condition=Ready "clusterpolicy/$POLICY_NAME" --timeout=90s >/dev/null 2>&1 \
    || warn "policy did not report Ready; continuing anyway"
  gen_traffic 4
}

baseline() {
  step "Healthy baseline — what a working Kyverno metrics pipeline looks like"
  local m
  m="$(fetch_metrics "svc/$METRICS_SVC")"
  if ! grep -q '^kyverno_' <<<"$m"; then
    warn "could not scrape a healthy baseline; the cluster may already be broken"
    return 0
  fi
  say ""
  say "  Series families exposed by the admission controller on :$METRICS_CONTAINER_PORT"
  grep -oE '^kyverno_[a-z_]+' <<<"$m" | sort -u | sed 's/^/    /'
  say ""
  say "  Policy results recorded for namespace $LAB_NS:"
  grep '^kyverno_policy_results_total' <<<"$m" \
    | grep "resource_namespace=\"$LAB_NS\"" | head -6 | sed 's/^/    /' \
    || say "    (none yet)"
  say ""
  say "  Remember these three; every check below is one of them:"
  say "    kyverno_policy_results_total       counter, labelled by policy_name, rule_name,"
  say "                                       rule_result, resource_kind, resource_namespace"
  say "    kyverno_admission_requests_total   counter of AdmissionReviews handled"
  say "    kyverno_admission_review_duration_seconds  histogram — your webhook latency SLI"
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
snapshot() {
  mkdir -p "$BACKUP_DIR"
  kubectl -n "$KYVERNO_NS" get svc "$METRICS_SVC" -o yaml >"$BACKUP_DIR/metrics-svc.yaml"
  kubectl -n "$KYVERNO_NS" get svc "$METRICS_SVC" \
    -o jsonpath='{.spec.ports[0].targetPort}' >"$BACKUP_DIR/metrics-svc.targetport"
  if kubectl -n "$KYVERNO_NS" get cm "$METRICS_CM" >/dev/null 2>&1; then
    kubectl -n "$KYVERNO_NS" get cm "$METRICS_CM" -o yaml >"$BACKUP_DIR/metrics-cm.yaml"
  else
    : >"$BACKUP_DIR/metrics-cm.absent"
  fi
  ok "originals saved under $BACKUP_DIR (last-resort undo, not the exercise)"
}

# ---------------------------------------------------------------------------
# THE BREAKS
#   #1 transport level  — Service sends scrapes to the webhook port, not metrics
#   #2 data level       — the lab namespace is filtered out of metrics
#   #3 semantic level   — counters are reset every minute
# ---------------------------------------------------------------------------
break_service_targetport() {
  step "Fault #1 — retargeting the metrics Service"
  kubectl -n "$KYVERNO_NS" patch svc "$METRICS_SVC" --type=json \
    -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9443}]' >/dev/null
  ok "svc/$METRICS_SVC patched"
}

break_metrics_configmap() {
  step "Fault #2 and #3 — rewriting the Kyverno metrics configuration"
  if ! kubectl -n "$KYVERNO_NS" get cm "$METRICS_CM" >/dev/null 2>&1; then
    kubectl -n "$KYVERNO_NS" create cm "$METRICS_CM" >/dev/null
  fi
  kubectl -n "$KYVERNO_NS" patch cm "$METRICS_CM" --type=merge -p \
    "{\"data\":{\"namespaces\":\"{\\\"include\\\":[],\\\"exclude\\\":[\\\"$LAB_NS\\\"]}\",\"metricsRefreshInterval\":\"1m\"}}" >/dev/null
  ok "configmap/$METRICS_CM patched"
  kubectl -n "$KYVERNO_NS" rollout restart "deploy/$ADM_DEPLOY" >/dev/null
  wait_rollout
  ok "admission controller restarted with the new metrics configuration"
}

briefing() {
  say ""
  hr
  printf '%s  KCA 6.3 — BREAK & FIX: Kyverno metrics have gone dark%s\n' "$C_B$C_M" "$C_RST"
  hr
  cat <<EOF

SCENARIO
  It is 02:10. Your platform Prometheus has been scraping Kyverno for months.
  Tonight the on-call dashboard "Policy Engine — Admission" is empty, and the
  alert PolicyEngineScrapeDown is firing. Nobody has touched the policies.
  A change freeze is NOT in effect: someone shipped a Helm values change earlier.

  Enforcement itself is fine — that is the trap. Kyverno is still denying
  non-compliant Pods. You have lost the *evidence*, not the *control*.
  In a regulated environment that is still an incident: you cannot prove to an
  auditor that the control was active during the window you cannot measure.

SYMPTOMS YOU WILL SEE
  1. Scraping through the Service returns nothing usable:
         kubectl -n $KYVERNO_NS port-forward svc/$METRICS_SVC 8000:8000
         curl -s http://127.0.0.1:8000/metrics | head
     -> empty reply / connection reset, no text exposition format at all.
        In Prometheus this is up{job=~".*kyverno.*"} == 0.

  2. Once you get bytes flowing again, the series for the workload namespace
     "$LAB_NS" are still missing, even though you can watch Kyverno deny
     Pods there in real time:
         kubectl -n $LAB_NS run probe --image=registry.k8s.io/pause:3.9 --restart=Never
         -> admission webhook denied the request
         ...yet kyverno_policy_results_total has no resource_namespace="$LAB_NS".

  3. The counters that DO exist keep falling back to zero on their own, so any
     panel built on raw totals or increase() over a long window is wrong.

YOUR MISSION
  Restore a trustworthy metrics pipeline. Concretely, all three must hold:
    [1] GET /metrics through svc/$METRICS_SVC returns Kyverno series in
        Prometheus text exposition format.
    [2] Fresh admission traffic in namespace "$LAB_NS" shows up as
        kyverno_policy_results_total{...,resource_namespace="$LAB_NS",...}
        with both rule_result="pass" and rule_result="fail".
    [3] Counters are monotonic again — no periodic self-reset.

RULES OF ENGAGEMENT
  - Do not uninstall or reinstall Kyverno, and do not helm upgrade over it.
  - Do not delete the ClusterPolicy: the control must stay enforcing while you
    repair the observability path. Verify that at the end.
  - Everything you need is inside namespace $KYVERNO_NS plus the metric names.

USEFUL STARTING POINTS
    kubectl -n $KYVERNO_NS get svc,ep,cm
    kubectl -n $KYVERNO_NS get deploy $ADM_DEPLOY -o jsonpath='{.spec.template.spec.containers[0].ports}'
    kubectl -n $KYVERNO_NS logs deploy/$ADM_DEPLOY --tail=50
    kubectl -n $KYVERNO_NS port-forward deploy/$ADM_DEPLOY 8000:8000   # bypasses the Service

  Ask yourself, in this order: does the container still expose metrics? does the
  Service reach that port? does Kyverno still record the namespace? does it keep
  what it records?

WHEN YOU THINK YOU ARE DONE
    $0 verify        # graded, generates fresh traffic first
    $0 traffic       # more admission requests on demand
    $0 restore       # emergency undo — spoils the exercise

EOF
  hr
}

# ---------------------------------------------------------------------------
# Grading
# ---------------------------------------------------------------------------
verify() {
  step "Generating fresh admission traffic before grading"
  gen_traffic 3
  sleep 5

  local fails=0 m_svc m_pod ri ns_cfg
  step "Grading"

  m_svc="$(fetch_metrics "svc/$METRICS_SVC")"
  if grep -q '^kyverno_' <<<"$m_svc"; then
    ok "[1/4] /metrics is reachable through svc/$METRICS_SVC and speaks the exposition format"
  else
    bad "[1/4] scraping svc/$METRICS_SVC still returns no Kyverno series"
    m_pod="$(fetch_metrics "deploy/$ADM_DEPLOY")"
    if grep -q '^kyverno_' <<<"$m_pod"; then
      say "       hint: the container DOES serve metrics on :$METRICS_CONTAINER_PORT — "
      say "             so the fault is in front of it, on the Service."
    else
      say "       hint: the container itself is not serving metrics; check the"
      say "             --metricsPort / --otelConfig flags on deploy/$ADM_DEPLOY."
    fi
    fails=$((fails + 1))
  fi

  if grep '^kyverno_policy_results_total' <<<"$m_svc" \
       | grep -q "resource_namespace=\"$LAB_NS\""; then
    ok "[2/4] policy results are recorded for namespace $LAB_NS"
  else
    bad "[2/4] no kyverno_policy_results_total series for resource_namespace=\"$LAB_NS\""
    ns_cfg="$(kubectl -n "$KYVERNO_NS" get cm "$METRICS_CM" -o jsonpath='{.data.namespaces}' 2>/dev/null || true)"
    [[ -n "$ns_cfg" ]] && say "       current metrics namespace filter: $ns_cfg"
    fails=$((fails + 1))
  fi

  if grep '^kyverno_policy_results_total' <<<"$m_svc" | grep -q 'rule_result="fail"' \
     && grep '^kyverno_policy_results_total' <<<"$m_svc" | grep -q 'rule_result="pass"'; then
    ok "[3/4] both rule_result=\"pass\" and rule_result=\"fail\" are observable"
  else
    bad "[3/4] pass/fail results are not both present — the counter is still filtered or reset"
    fails=$((fails + 1))
  fi

  ri="$(kubectl -n "$KYVERNO_NS" get cm "$METRICS_CM" -o jsonpath='{.data.metricsRefreshInterval}' 2>/dev/null || true)"
  if [[ -z "$ri" || "$ri" =~ ^([0-9]+h|[0-9]+d)$ ]]; then
    ok "[4/4] metricsRefreshInterval is sane (${ri:-unset — uses the default})"
  else
    bad "[4/4] metricsRefreshInterval=$ri resets the counters far too often"
    say "       a short reset makes raw totals and increase() over long ranges meaningless"
    fails=$((fails + 1))
  fi

  step "Control-still-enforcing check (the fix must not have weakened security)"
  if kubectl -n "$LAB_NS" run kca-verify-probe --image=registry.k8s.io/pause:3.9 \
       --restart=Never >/dev/null 2>&1; then
    bad "an unlabelled Pod was ADMITTED — you disabled the policy instead of fixing metrics"
    kubectl -n "$LAB_NS" delete pod kca-verify-probe --wait=false --ignore-not-found >/dev/null 2>&1 || true
    fails=$((fails + 1))
  else
    ok "ClusterPolicy/$POLICY_NAME is still denying non-compliant Pods"
  fi

  say ""
  if [[ "$fails" -eq 0 ]]; then
    printf '%s  PASSED — the metrics pipeline is trustworthy again.%s\n' "$C_B$C_G" "$C_RST"
    say "  Now answer the production question: what stops the next helm upgrade"
    say "  from reintroducing all three faults? (see the SOLUTION block at the"
    say "  bottom of this script, step 6)"
  else
    printf '%s  %d check(s) still failing — keep going.%s\n' "$C_B$C_R" "$fails" "$C_RST"
    return 1
  fi
}

status() {
  step "Current state"
  kubectl -n "$KYVERNO_NS" get deploy,svc -o wide 2>/dev/null | sed 's/^/  /'
  say ""
  kubectl -n "$KYVERNO_NS" get endpoints "$METRICS_SVC" 2>/dev/null | sed 's/^/  /' || true
  say ""
  kubectl get clusterpolicy "$POLICY_NAME" 2>/dev/null | sed 's/^/  /' || true
  say ""
  say "  first 5 kyverno_ series scraped through svc/$METRICS_SVC:"
  fetch_metrics "svc/$METRICS_SVC" | grep '^kyverno_' | head -5 | sed 's/^/    /' \
    || say "    (nothing — the Service path is broken)"
}

restore() {
  step "Restoring the pre-break configuration"
  if [[ -f "$BACKUP_DIR/metrics-svc.targetport" ]]; then
    local tp; tp="$(cat "$BACKUP_DIR/metrics-svc.targetport")"
    kubectl -n "$KYVERNO_NS" patch svc "$METRICS_SVC" --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/targetPort\",\"value\":$( [[ "$tp" =~ ^[0-9]+$ ]] && echo "$tp" || echo "\"$tp\"" )}]" >/dev/null
    ok "svc/$METRICS_SVC targetPort restored to $tp"
  fi
  if [[ -f "$BACKUP_DIR/metrics-cm.absent" ]]; then
    kubectl -n "$KYVERNO_NS" delete cm "$METRICS_CM" --ignore-not-found >/dev/null
    ok "configmap/$METRICS_CM removed (it did not exist before the lab)"
  elif [[ -f "$BACKUP_DIR/metrics-cm.yaml" ]]; then
    kubectl replace -f "$BACKUP_DIR/metrics-cm.yaml" >/dev/null 2>&1 \
      || kubectl apply -f "$BACKUP_DIR/metrics-cm.yaml" >/dev/null
    ok "configmap/$METRICS_CM restored"
  fi
  kubectl -n "$KYVERNO_NS" rollout restart "deploy/$ADM_DEPLOY" >/dev/null
  wait_rollout
  ok "restore complete"
}

cleanup() {
  restore
  step "Removing lab artefacts"
  kubectl delete clusterpolicy "$POLICY_NAME" --ignore-not-found >/dev/null
  kubectl delete ns "$LAB_NS" --ignore-not-found --wait=false >/dev/null
  ok "ClusterPolicy/$POLICY_NAME and namespace/$LAB_NS deleted"
}

usage() {
  sed -n '1,45p' "$0" | sed 's/^#//'
}

main() {
  local action="${1:-break}"
  need kubectl
  need curl
  kubectl version >/dev/null 2>&1 || die "cannot reach a Kubernetes API server"

  case "$action" in
    help|-h|--help) usage; exit 0 ;;
  esac

  guard_lab "$@"
  ensure_kyverno

  case "$action" in
    break)
      setup_lab
      baseline
      snapshot
      say ""
      confirm "Ready to break the metrics pipeline in ns/$KYVERNO_NS?" || die "aborted by user"
      break_service_targetport
      break_metrics_configmap
      gen_traffic 3
      briefing
      ;;
    status)  status ;;
    traffic) gen_traffic "${2:-4}" ;;
    verify)  verify ;;
    restore) restore ;;
    cleanup) cleanup ;;
    *) die "unknown action '$action' — try: break | status | traffic | verify | restore | cleanup | help" ;;
  esac
}

main "$@"

# ============================================================================
#                        S O L U T I O N   (spoilers)
# ============================================================================
#
# The mental model first. A Kyverno metric has to survive four hops before it
# reaches a dashboard, and each hop is a different failure class:
#
#   [rule executes] -> [Kyverno records it] -> [OTel Prometheus exporter serves
#   it on :8000/metrics] -> [Service routes the scrape to :8000] -> [Prometheus
#   stores it]
#
# This lab breaks hop 4 (loud), hop 2 (silent), and the retention of hop 2
# (subtle). Diagnose from the outside in and never trust "the dashboard is
# empty" as a statement about the policy engine — it is a statement about the
# weakest hop.
#
# ---------------------------------------------------------------------------
# STEP 0 — Establish that this is an observability incident, not a security one
# ---------------------------------------------------------------------------
#   kubectl get clusterpolicy
#   kubectl -n kca-metrics-lab run probe --image=registry.k8s.io/pause:3.9 --restart=Never
#     -> Error from server: admission webhook "validate.kyverno.svc-fail" denied
#        the request: ... Pods in kca-metrics-lab must carry a non-empty 'team' label.
#
#   The control is live. Say so explicitly in the incident channel before you
#   touch anything: it changes the severity and it stops someone "fixing" the
#   dashboard by disabling policies.
#
# ---------------------------------------------------------------------------
# STEP 1 — Is the process still exposing metrics at all? (bypass the Service)
# ---------------------------------------------------------------------------
#   kubectl -n kyverno get pods
#   kubectl -n kyverno port-forward deploy/kyverno-admission-controller 8000:8000 &
#   curl -s http://127.0.0.1:8000/metrics | head -20
#     -> HELP/TYPE lines, kyverno_* series. The exporter is healthy.
#   kill %1
#
#   Port-forward to a Pod/Deployment talks to the container port directly.
#   Port-forward to a Service goes through port -> targetPort translation, the
#   same translation EndpointSlices give Prometheus. Comparing the two isolates
#   "the app is broken" from "the routing is broken" in one move.
#
#   If this had returned nothing, the next suspects would have been the
#   container flags:
#     kubectl -n kyverno get deploy kyverno-admission-controller \
#       -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
#   Expect --metricsPort=8000 and --otelConfig=prometheus. With
#   --otelConfig=grpc Kyverno pushes OTLP to --otelCollector and the scrape
#   endpoint is gone by design — a classic "who changed the values file" outage.
#   Reference: https://kyverno.io/docs/installation/customization/
#
# ---------------------------------------------------------------------------
# STEP 2 — Fault #1: the Service points at the webhook port
# ---------------------------------------------------------------------------
#   kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
#   curl -sv http://127.0.0.1:8000/metrics
#     -> empty reply / reset. You are speaking plain HTTP to a TLS listener.
#   kill %1
#
#   kubectl -n kyverno get svc kyverno-svc-metrics -o yaml
#     spec.ports[0]: port: 8000, targetPort: 9443     <-- 9443 is the webhook port
#   kubectl -n kyverno get endpointslices -l kubernetes.io/service-name=kyverno-svc-metrics -o yaml
#     -> ports: [{port: 9443}]   The endpoints are Ready, which is why no probe
#        or event ever fired: Kubernetes routed the traffic exactly as told.
#
#   Find the right value from the container itself, do not guess:
#   kubectl -n kyverno get deploy kyverno-admission-controller \
#     -o jsonpath='{.spec.template.spec.containers[0].ports}'
#     -> [{"containerPort":9443,"name":"https"},{"containerPort":8000,"name":"metrics-port"}]
#
#   Fix (use the port NAME — it survives a port renumbering in the chart):
#   kubectl -n kyverno patch svc kyverno-svc-metrics --type=json \
#     -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"metrics-port"}]'
#
#   Re-scrape through the Service — you should now get the exposition format.
#
# ---------------------------------------------------------------------------
# STEP 3 — Fault #2: the namespace is filtered out of metrics
# ---------------------------------------------------------------------------
#   curl -s http://127.0.0.1:8000/metrics | grep kyverno_policy_results_total | head
#     -> series exist, but none with resource_namespace="kca-metrics-lab".
#
#   Kyverno's metrics exposure is itself configurable, in the ConfigMap named by
#   --metricsConfig (default: kyverno-metrics):
#   kubectl -n kyverno get cm kyverno-metrics -o yaml
#     data:
#       namespaces: '{"include":[],"exclude":["kca-metrics-lab"]}'
#       metricsRefreshInterval: 1m
#
#   Semantics: exclude wins, and a non-empty include list means "only these".
#   Excluding a namespace does NOT stop policy evaluation there — it stops the
#   *reporting*. That is the whole point of the lab: a one-line filter turns a
#   compliance control invisible while leaving it fully enforcing.
#
#   Fix:
#   kubectl -n kyverno patch cm kyverno-metrics --type=merge \
#     -p '{"data":{"namespaces":"{\"include\":[],\"exclude\":[]}"}}'
#
# ---------------------------------------------------------------------------
# STEP 4 — Fault #3: the counters reset every minute
# ---------------------------------------------------------------------------
#   metricsRefreshInterval controls how often Kyverno resets its metric state;
#   the documented default is 24h. At 1m, every counter is a sawtooth. Prometheus
#   compensates for resets inside rate(), but everything else breaks: raw totals
#   on a panel, increase() over 24h, topk over a counter, and any alert that
#   compares an absolute count to a threshold. Worse, a reset that lands between
#   two scrapes silently loses the samples in between.
#
#   Fix:
#   kubectl -n kyverno patch cm kyverno-metrics --type=merge \
#     -p '{"data":{"metricsRefreshInterval":"24h"}}'
#
# ---------------------------------------------------------------------------
# STEP 5 — Apply, reload, and prove it with traffic
# ---------------------------------------------------------------------------
#   kubectl -n kyverno rollout restart deploy/kyverno-admission-controller
#   kubectl -n kyverno rollout status  deploy/kyverno-admission-controller
#
#   (Kyverno watches its ConfigMaps, but a restart is the deterministic move
#   during an incident: it removes "did it reload?" from the hypothesis list,
#   and it is safe because the webhook failurePolicy and the Service stay put.)
#
#   Then re-drive admission traffic — a counter that nobody increments proves
#   nothing:
#     kubectl -n kca-metrics-lab run good --image=registry.k8s.io/pause:3.9 \
#       --restart=Never --labels=team=platform          # admitted
#     kubectl -n kca-metrics-lab run bad  --image=registry.k8s.io/pause:3.9 \
#       --restart=Never                                  # denied
#
#   kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
#   curl -s http://127.0.0.1:8000/metrics \
#     | grep 'kyverno_policy_results_total' \
#     | grep 'resource_namespace="kca-metrics-lab"'
#     -> two families of series, rule_result="pass" and rule_result="fail",
#        both labelled policy_name="kca-6-3-require-team-label",
#        rule_name="check-team-label", rule_type="validate",
#        policy_validation_mode="enforce", resource_request_operation="create".
#
#   Then: ./kca-6.3-kyverno-metrics-break-fix.sh verify
#
# ---------------------------------------------------------------------------
# STEP 6 — The part that makes it a production fix, not a lab fix
# ---------------------------------------------------------------------------
#   Everything above was done with kubectl patch on Helm-managed objects. The
#   next `helm upgrade` reverts your Service patch and, if the bad values were
#   committed, re-applies the exclude list. Close the loop in Git:
#
#     # values.yaml
#     admissionController:
#       serviceMonitor:
#         enabled: true
#     metricsConfig:
#       namespaces:
#         include: []
#         exclude: []
#       metricsRefreshInterval: 24h
#
#   And add the detection you did not have. The incident lasted until a human
#   looked at a dashboard; it should have paged:
#
#     - alert: KyvernoMetricsDown
#       expr: up{job=~".*kyverno.*"} == 0
#       for: 10m
#     - alert: KyvernoAdmissionSilent
#       expr: sum(rate(kyverno_admission_requests_total[15m])) == 0
#       for: 15m
#     - alert: KyvernoAdmissionLatencyHigh
#       expr: histogram_quantile(0.99,
#               sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))) > 1
#       for: 10m
#
#   The second one is the lesson of fault #2 and #3: "the scrape succeeds" is not
#   "the control is observable". Alert on the absence of expected data, not only
#   on the absence of the target. And keep an eye on
#   kyverno_policy_rule_info_total — if the number of loaded rules drops, your
#   policy set shrank, whether or not anyone meant it to.
#
#   Metric reference: https://kyverno.io/docs/monitoring/
# ============================================================================