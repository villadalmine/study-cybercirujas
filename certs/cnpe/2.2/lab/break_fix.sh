#!/usr/bin/env bash
#
# ==============================================================================
# CNPE 2.2 — Measuring and Improving Platform Efficiency Using Deployment
#            Metrics and Performance Indicators
# ------------------------------------------------------------------------------
# break & fix lab  ·  scenario: "the utilization KPI goes dark"
#
# WHAT THIS TEACHES
#   A platform team measures efficiency with a normalized performance indicator:
#   CPU utilization = actual_usage / requested_resources. That ratio is what
#   feeds capacity dashboards, right-sizing reports, and — most visibly — the
#   HorizontalPodAutoscaler. This lab breaks the *denominator* of that ratio and
#   shows how a single missing field silently kills the efficiency signal for a
#   whole workload: telemetry keeps flowing, but the KPI reads <unknown> and the
#   platform can no longer make an efficiency decision.
#
# SAFE / DESTRUCTIVE-BY-DESIGN
#   Runs ONLY against a disposable lab cluster. It creates an isolated namespace
#   (eff-lab) and, if needed, installs metrics-server. It never touches your
#   existing workloads. Undo everything with:  ./break_fix.sh --cleanup
#
# REFERENCES (official)
#   - HorizontalPodAutoscaler:
#       https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
#   - Resource metrics pipeline (metrics-server / metrics.k8s.io):
#       https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
#   - Managing container resources (requests are the KPI denominator):
#       https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
#   - metrics-server:
#       https://github.com/kubernetes-sigs/metrics-server
#   - CNPE curriculum:
#       https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# ==============================================================================

set -euo pipefail

NS="eff-lab"
APP="web"
IMAGE="registry.k8s.io/hpa-example"   # canonical php-apache HPA demo image
HPA_TARGET_PCT="50"

# ------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------
log()  { printf '\033[1;34m[break-fix]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[break-fix]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[break-fix]\033[0m %s\n' "$*" >&2; exit 1; }
rule() { printf '%s\n' "------------------------------------------------------------------------------"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# ------------------------------------------------------------------------------
# safety gate: never run against something that looks like production
# ------------------------------------------------------------------------------
guard() {
  need kubectl
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "no current kubectl context; point KUBECONFIG at a LAB cluster first"
  case "$ctx" in
    *prod*|*production*|*prd*)
      die "refusing to run: context '$ctx' looks like production — this script BREAKS things on purpose" ;;
  esac
  log "current context: $ctx"
  if [[ "${LAB_CONFIRM:-}" != "yes" && "${1:-}" != "--i-understand" ]]; then
    rule
    warn "This will CREATE namespace '$NS' and deploy an intentionally mis-sized workload."
    warn "Run only on a throwaway lab cluster."
    warn "Proceed with:   LAB_CONFIRM=yes $0        (or)   $0 --i-understand"
    rule
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# ensure the resource metrics pipeline exists (idempotent)
# ------------------------------------------------------------------------------
ensure_metrics_server() {
  if kubectl top nodes >/dev/null 2>&1; then
    log "metrics-server is already serving metrics — leaving it untouched"
    return 0
  fi
  log "metrics.k8s.io not answering; installing metrics-server release manifest"
  kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"

  # kind/minikube/k3s present self-signed kubelet certs; allow them in the lab.
  # Append the flag only once so re-runs stay idempotent.
  if ! kubectl -n kube-system get deploy metrics-server \
        -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
        | grep -q -- '--kubelet-insecure-tls'; then
    log "patching metrics-server with --kubelet-insecure-tls (lab kubelet certs)"
    kubectl -n kube-system patch deployment metrics-server --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  fi
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
}

wait_for_pod_metrics() {
  log "waiting for the metrics pipeline to scrape the workload (~up to 180s)"
  local deadline=$((SECONDS + 180))
  until kubectl top pods -n "$NS" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || { warn "pod metrics still unavailable — symptom below may read differently"; return 0; }
    sleep 5
  done
  log "pod metrics are flowing"
}

# ------------------------------------------------------------------------------
# the BREAK: deploy a workload with NO cpu request, plus an HPA that needs one
# ------------------------------------------------------------------------------
apply_broken_state() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

  # NOTE the deliberate bug: the container declares no resources.requests block.
  # Utilization is defined as usage/request; with no request the ratio has no
  # denominator, so the efficiency KPI for this Deployment is undefined.
  kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
  labels: { app: ${APP} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${APP} }
  template:
    metadata:
      labels: { app: ${APP} }
    spec:
      containers:
        - name: ${APP}
          image: ${IMAGE}
          ports:
            - containerPort: 80
          # <<< THE BREAK: intentionally no resources.requests here >>>
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  selector: { app: ${APP} }
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP}
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${HPA_TARGET_PCT}
YAML

  kubectl rollout status deployment/"$APP" -n "$NS" --timeout=120s
}

# ------------------------------------------------------------------------------
# brief the student
# ------------------------------------------------------------------------------
brief() {
  rule
  log "SCENARIO IS ARMED — the efficiency KPI for deployment/${APP} is now dark."
  rule
  cat <<EOF

WHAT YOU WILL SEE (the symptom)
  \$ kubectl get hpa ${APP} -n ${NS}
    NAME   REFERENCE        TARGETS         MINPODS   MAXPODS   REPLICAS
    ${APP}    Deployment/${APP}   cpu: <unknown>/${HPA_TARGET_PCT}%   1         5         1

  \$ kubectl describe hpa ${APP} -n ${NS}
    ...
    Conditions:
      Type           Status  Reason                   Message
      ScalingActive  False   FailedGetResourceMetric  failed to get cpu utilization:
                                                       missing request for cpu ...
    Events:
      Warning  FailedGetResourceMetric   ... did not receive metrics for ...

  The TARGETS column reads <unknown>. The HPA cannot scale, capacity planning
  cannot right-size, and the efficiency dashboard for this workload flatlines.

  IMPORTANT — telemetry is NOT the problem. Prove it:
  \$ kubectl top pods -n ${NS}
    NAME                     CPU(cores)   MEMORY(bytes)
    ${APP}-xxxxxxxxxx-xxxxx     1m           11Mi
  Raw usage is visible. What is missing is the DENOMINATOR that turns raw usage
  into a normalized performance indicator.

YOUR GOAL
  Restore the utilization KPI so that:
    - kubectl get hpa ${APP} -n ${NS}  shows a numeric TARGETS (e.g. 0%/${HPA_TARGET_PCT}%),
      NOT <unknown>; and
    - the HPA can scale the Deployment under load.
  Do NOT change the HPA target, min, or max. Fix the workload, not the KPI.

HINTS
  - averageUtilization is a percentage of *what*? (Check the container spec.)
  - kubectl explain deployment.spec.template.spec.containers.resources
  - A namespace LimitRange with default requests would have prevented this
    entire class of blind spot — think about why that is a platform guardrail.

When you think it is fixed, verify, then reveal the solution at the bottom of
this script (it is commented out) or run:  ${0} --solution

EOF
  rule
}

# ------------------------------------------------------------------------------
# print the worked solution (also kept as comments at the end of the file)
# ------------------------------------------------------------------------------
solution() {
  cat <<EOF

STEP-BY-STEP SOLUTION
  1. Confirm the KPI is dark and locate the reason:
       kubectl get hpa ${APP} -n ${NS}            # TARGETS <unknown>/${HPA_TARGET_PCT}%
       kubectl describe hpa ${APP} -n ${NS}       # "missing request for cpu"
       kubectl top pods -n ${NS}                  # raw usage IS present

  2. Root cause: the container has no cpu request. Utilization = usage / request,
     so with no request the platform cannot compute the ratio -> <unknown>.

  3. Fix — give the container a request (the KPI denominator). Also set a limit
     so the workload is a good bin-packing citizen:
       kubectl set resources deployment/${APP} -n ${NS} \\
         --requests=cpu=100m,memory=64Mi --limits=cpu=250m,memory=128Mi
     (equivalently: edit spec.template.spec.containers[0].resources.requests)

  4. Roll out and let one scrape cycle pass:
       kubectl rollout status deployment/${APP} -n ${NS}
       sleep 30

  5. Verify the KPI is back — TARGETS is now a number:
       kubectl get hpa ${APP} -n ${NS}            # e.g. cpu: 0%/${HPA_TARGET_PCT}%

  6. (Optional) prove the control loop closes end-to-end — drive load and watch
     replicas climb toward maxReplicas, then settle:
       kubectl run load -n ${NS} --rm -it --image=busybox --restart=Never -- \\
         /bin/sh -c "while true; do wget -q -O- http://${APP}; done"
       # in another terminal:
       watch kubectl get hpa,pods -n ${NS}

  PLATFORM LESSON
    Efficiency indicators are ratios, and a ratio dies quietly when its
    denominator is absent — no error at deploy time, just a KPI that reads
    <unknown>. The durable fix is not per-workload firefighting but a policy
    guardrail: a namespace LimitRange with default requests (or an admission
    policy) makes "no request" impossible, so every deployment is measurable by
    construction. Measure what you require; require what you measure.

EOF
}

# ------------------------------------------------------------------------------
# teardown
# ------------------------------------------------------------------------------
cleanup() {
  need kubectl
  log "removing namespace '$NS' (metrics-server is left in place)"
  kubectl delete namespace "$NS" --ignore-not-found
  log "done"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
  case "${1:-}" in
    --cleanup)  cleanup; exit 0 ;;
    --solution) solution; exit 0 ;;
  esac
  guard "${1:-}"
  ensure_metrics_server
  apply_broken_state
  wait_for_pod_metrics
  brief
}

main "$@"

# ==============================================================================
# SOLUTION (kept here so the file is self-contained; also via: ./break_fix.sh --solution)
# ------------------------------------------------------------------------------
# 1. Confirm the KPI is dark and locate the reason:
#      kubectl get hpa web -n eff-lab            # TARGETS <unknown>/50%
#      kubectl describe hpa web -n eff-lab       # "missing request for cpu"
#      kubectl top pods -n eff-lab               # raw usage IS present -> telemetry is fine
#
# 2. Root cause: the container declares no cpu request. Utilization is
#    usage/request; with no request the ratio has no denominator, so the HPA
#    (and every efficiency report built on the same metric) reads <unknown>.
#
# 3. Fix — supply the request (the KPI denominator) plus a sane limit:
#      kubectl set resources deployment/web -n eff-lab \
#        --requests=cpu=100m,memory=64Mi --limits=cpu=250m,memory=128Mi
#
# 4. Roll out and wait ~one scrape cycle:
#      kubectl rollout status deployment/web -n eff-lab
#      sleep 30
#
# 5. Verify — TARGETS is now numeric, not <unknown>:
#      kubectl get hpa web -n eff-lab            # e.g. cpu: 0%/50%
#
# 6. (Optional) close the loop under load and watch it scale:
#      kubectl run load -n eff-lab --rm -it --image=busybox --restart=Never -- \
#        /bin/sh -c "while true; do wget -q -O- http://web; done"
#      watch kubectl get hpa,pods -n eff-lab
#
# LESSON: efficiency KPIs are ratios; a missing request silently nulls the
# denominator with no deploy-time error. Enforce requests with a namespace
# LimitRange / admission policy so every workload is measurable by construction.
# ==============================================================================