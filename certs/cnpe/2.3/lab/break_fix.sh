#!/usr/bin/env bash
#
# CNPE — Certified Cloud Native Platform Engineer (exam version: unknown)
# Domain 2: Platform Operations & Reliability
# Topic 2.3: Diagnosing and Remediating Platform Issues and Incident Scenarios
# Exam weight: 6.67%
#
# Reference (official CNCF curriculum):
#   https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
#
# ==============================================================================
#  BREAK & FIX INCIDENT DRILL  —  "the pods are Running, but everything 503s"
# ==============================================================================
# This script deploys a small, HEALTHY web service into an isolated namespace on
# a DISPOSABLE lab cluster, then injects ONE controlled fault that reproduces a
# textbook production incident: a bad "config hotfix" rollout that silently takes
# the whole service offline while every pod still shows as Running.
#
# The fault is a normal Deployment rollout, so it is 100% reversible with stock
# kubectl. Nothing outside the lab namespace is ever touched. You play the
# on-call platform engineer: triage the incident, isolate the root cause, and
# restore service — ideally under the pressure of a stuck rollout.
#
# Usage:
#   ./break_fix.sh            # inject the fault and print the incident briefing
#   ./break_fix.sh verify     # check whether you have restored the service
#   ./break_fix.sh cleanup    # delete the lab namespace and everything in it
#
# Safety:
#   * Requires a reachable cluster and refuses to run until you confirm the
#     target context is throwaway (export LAB_ASSUME_YES=1 to skip the prompt).
#   * Never edits any object outside namespace 'cnpe-lab-23'.
# ==============================================================================

set -euo pipefail

NS="cnpe-lab-23"
APP="payments-api"
IMAGE="nginx:1.27-alpine"
HEALTHY_PORT=80          # nginx actually listens here
BROKEN_PORT=8080         # nothing listens here — this is the injected fault

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FATAL: required tool '$1' not found in PATH." >&2
    exit 1
  }
}

preflight() {
  require kubectl
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "FATAL: no reachable Kubernetes cluster (kubectl cluster-info failed)." >&2
    echo "       Spin up a throwaway one first, e.g.:" >&2
    echo "         kind create cluster --name cnpe-lab" >&2
    echo "         minikube start -p cnpe-lab" >&2
    exit 1
  fi
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  echo ">> Target context: ${ctx}"
  if [[ "${LAB_ASSUME_YES:-0}" != "1" ]]; then
    read -r -p ">> Type 'yes' to confirm this is a DISPOSABLE lab cluster: " ans
    [[ "${ans}" == "yes" ]] || { echo "Aborted — no changes made."; exit 1; }
  fi
}

# ------------------------------------------------------------------------------
# Step 1 — deploy the healthy baseline (this becomes rollout revision 1)
# ------------------------------------------------------------------------------
deploy_baseline() {
  echo ">> Deploying healthy baseline (revision 1) into namespace '${NS}'..."
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -n "${NS}" -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  labels:
    app: ${APP}
    tier: backend
spec:
  replicas: 3
  revisionHistoryLimit: 5
  # Recreate makes the incident realistic: a bad template swaps ALL pods at once,
  # so a failing readiness probe empties the endpoints and drops the service.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
        tier: backend
    spec:
      containers:
      - name: web
        image: ${IMAGE}
        ports:
        - name: http
          containerPort: 80
        resources:
          requests:
            cpu: 25m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
        # Liveness stays on the real port: the container is genuinely alive,
        # which is why the broken pods never restart — a key diagnostic signal.
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 10
        # Readiness is the probe the fault will sabotage.
        readinessProbe:
          httpGet:
            path: /
            port: ${HEALTHY_PORT}
          initialDelaySeconds: 2
          periodSeconds: 5
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  labels:
    app: ${APP}
spec:
  selector:
    app: ${APP}
  ports:
  - name: http
    port: 80
    targetPort: http
YAML

  echo ">> Waiting for the baseline to become healthy..."
  kubectl rollout status "deployment/${APP}" -n "${NS}" --timeout=120s
}

# ------------------------------------------------------------------------------
# Step 2 — inject the fault (this becomes rollout revision 2)
# ------------------------------------------------------------------------------
introduce_break() {
  echo ">> Injecting fault: a 'config hotfix' rollout (revision 2)..."
  echo "   The readiness probe is repointed at :${BROKEN_PORT}, where nothing listens."
  kubectl patch deployment "${APP}" -n "${NS}" --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/httpGet/port\",\"value\":${BROKEN_PORT}}]" >/dev/null
  # The new ReplicaSet will never report Ready, so this rollout is stuck by design.
  kubectl rollout status "deployment/${APP}" -n "${NS}" --timeout=30s || true
}

# ------------------------------------------------------------------------------
# Incident briefing shown to the student
# ------------------------------------------------------------------------------
briefing() {
  cat <<TXT

================================================================================
  INCIDENT #2.3 — "payments-api is throwing 503s in production"
================================================================================
PAGE:  Synthetic checks against the 'payments-api' Service started failing right
       after the last config hotfix was rolled out. Customers see 503s. The
       platform team escalated to you.

WHAT YOU WILL SEE (start your triage here):

    kubectl get deploy,rs,pods,svc,endpoints -n ${NS}

  * The Deployment is NOT fully available; the latest rollout is stuck.
  * Every pod is 'Running' with RESTARTS = 0 ... yet READY shows 0/1.
  * 'kubectl get endpoints ${APP} -n ${NS}' returns NO ready addresses.
  * A request to the Service times out / never reaches a backend.

  Note the trap: the pods are up and never crash, so a naive "just restart it"
  reflex will not help. The processes are alive — they are simply never marked
  Ready, so the Service has zero endpoints to route to.

WHAT YOU MUST ACHIEVE (definition of done):

  1. Service/${APP} again has one or more READY endpoints, and
  2. An in-cluster HTTP GET to http://${APP}.${NS}.svc.cluster.local/ returns 200.

  Bonus (real incident hygiene): resolve it the way an on-call engineer would —
  fastest safe path first — and be ready to explain the root cause afterward.

CHECK YOUR WORK AT ANY TIME:

    ./$(basename "$0") verify

WHEN YOU ARE DONE (tear the lab down):

    ./$(basename "$0") cleanup

The full step-by-step solution is at the very bottom of this script, commented
out. Try to solve it before reading it.
================================================================================

TXT
}

# ------------------------------------------------------------------------------
# Verification the student can run repeatedly
# ------------------------------------------------------------------------------
verify() {
  echo ">> Verifying service restoration in namespace '${NS}'..."
  local ready
  ready="$(kubectl get endpoints "${APP}" -n "${NS}" \
             -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null \
           | grep -c . || true)"
  echo "   Ready endpoints behind Service/${APP}: ${ready}"

  echo ">> Sending a request from an ephemeral in-cluster client..."
  local code
  code="$(kubectl run "cnpe-probe-${RANDOM}" -n "${NS}" \
            --image=curlimages/curl:8.10.1 --restart=Never -i --rm --quiet \
            --command -- sh -c \
            "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://${APP}.${NS}.svc.cluster.local/" \
          2>/dev/null || true)"
  echo "   HTTP status from Service/${APP}: ${code:-<none>}"

  if [[ "${ready}" =~ ^[0-9]+$ && "${ready}" -gt 0 && "${code}" == "200" ]]; then
    echo "   RESULT: PASS ✔  Service restored — incident resolved."
  else
    echo "   RESULT: FAIL �’  Still broken. Keep triaging (see the briefing)."
  fi
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
main() {
  case "${1:-break}" in
    break)
      preflight
      deploy_baseline
      introduce_break
      briefing
      ;;
    verify)
      require kubectl
      verify
      ;;
    cleanup)
      require kubectl
      kubectl delete namespace "${NS}" --ignore-not-found
      echo "Lab namespace '${NS}' removed."
      ;;
    *)
      echo "Usage: $0 [break|verify|cleanup]" >&2
      exit 2
      ;;
  esac
}

main "$@"

# ==============================================================================
#  SOLUTION — step by step (read only after you have tried)
# ==============================================================================
#
# ------------------------------------------------------------------------------
# 0) Frame the incident: what is the blast radius?
# ------------------------------------------------------------------------------
#   kubectl get deploy,rs,pods,svc,endpoints -n cnpe-lab-23
#
#   You will see:
#     * deployment.apps/payments-api  READY 0/3  (or 3/3 UP-TO-DATE but 0 AVAILABLE)
#     * a NEW replicaset scaled to 3, an OLD one scaled to 0
#     * pods:  STATUS=Running   READY=0/1   RESTARTS=0
#     * endpoints/payments-api:  <none>     <-- the smoking gun
#
#   Reading it: the app is not crashing (RESTARTS=0, STATUS=Running), so this is
#   NOT an image/crashloop problem. The Service has no endpoints, which is
#   exactly why callers get 503 — kube-proxy has nothing to route to.
#
# ------------------------------------------------------------------------------
# 1) Confirm it is a "no ready endpoints" problem, not a selector/DNS problem
# ------------------------------------------------------------------------------
#   kubectl get endpoints payments-api -n cnpe-lab-23
#   kubectl get endpointslices -n cnpe-lab-23 -l kubernetes.io/service-name=payments-api
#
#   The addresses list is empty and pods appear under 'notReadyAddresses' only.
#   Rule out a selector mismatch (a common look-alike incident):
#     kubectl describe svc payments-api -n cnpe-lab-23        # Selector: app=payments-api
#     kubectl get pods -n cnpe-lab-23 --show-labels           # pods carry app=payments-api
#   Labels match, so the Service targets the right pods — they are simply Not Ready.
#
# ------------------------------------------------------------------------------
# 2) Ask WHY the pods are Not Ready — read the pod events
# ------------------------------------------------------------------------------
#   kubectl describe pod -n cnpe-lab-23 -l app=payments-api | sed -n '/Events/,$p'
#
#   Events show, repeatedly:
#     Warning  Unhealthy  Readiness probe failed: Get "http://10.x.x.x:8080/":
#              dial tcp 10.x.x.x:8080: connect: connection refused
#   Liveness (port 80) is silent — the container IS alive. Only *readiness* on
#   port 8080 fails. Root cause hypothesis: the readiness probe points at a port
#   nothing is listening on.
#
#   Confirm the container really listens on 80, not 8080:
#     kubectl exec -n cnpe-lab-23 deploy/payments-api -- \
#       sh -c 'wget -qO- -T2 http://127.0.0.1:80/ >/dev/null && echo "80 OK"; \
#              wget -qO- -T2 http://127.0.0.1:8080/ >/dev/null || echo "8080 DEAD"'
#
# ------------------------------------------------------------------------------
# 3) Pin the change to a rollout (this is an incident, so look at history)
# ------------------------------------------------------------------------------
#   kubectl rollout history deployment/payments-api -n cnpe-lab-23
#   kubectl get deploy payments-api -n cnpe-lab-23 \
#     -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}{"\n"}'
#   -> 8080   (revision 2 introduced the bad probe port; revision 1 had 80)
#
# ------------------------------------------------------------------------------
# 4) Remediate — pick the on-call-correct path
# ------------------------------------------------------------------------------
#   OPTION A (preferred during an incident: fast, low-risk rollback):
#     kubectl rollout undo deployment/payments-api -n cnpe-lab-23
#     kubectl rollout status deployment/payments-api -n cnpe-lab-23 --timeout=120s
#
#   OPTION B (forward fix, if you must keep other revision-2 changes):
#     kubectl patch deployment payments-api -n cnpe-lab-23 --type=json \
#       -p='[{"op":"replace",
#             "path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port",
#             "value":80}]'
#     kubectl rollout status deployment/payments-api -n cnpe-lab-23 --timeout=120s
#
# ------------------------------------------------------------------------------
# 5) Verify recovery (both signals must be green)
# ------------------------------------------------------------------------------
#   kubectl get pods,endpoints -n cnpe-lab-23        # pods 1/1 Ready, endpoints populated
#   ./break_fix.sh verify                            # endpoints > 0 AND HTTP 200
#   # or manually:
#   kubectl run t --rm -i --restart=Never -n cnpe-lab-23 \
#     --image=curlimages/curl:8.10.1 -- \
#     curl -s -o /dev/null -w '%{http_code}\n' \
#     http://payments-api.cnpe-lab-23.svc.cluster.local/
#
# ------------------------------------------------------------------------------
# 6) Post-incident lesson (the platform-engineering takeaway)
# ------------------------------------------------------------------------------
#   * A wrong readiness probe is a silent outage: pods stay Running and never
#     restart, so alerting on RESTARTS or CrashLoopBackOff would have missed it.
#     Alert on Deployment AVAILABLE replicas and on Service endpoint count.
#   * The 'Recreate' strategy let a bad template take down every pod at once.
#     With a RollingUpdate + maxUnavailable:0, the new Not-Ready pods could never
#     have replaced the healthy ones — the rollout would have stalled at surge
#     capacity with ZERO customer impact. That is the guardrail worth adding.
#   * readinessProbe governs traffic (endpoints); livenessProbe governs restarts.
#     Confusing the two is one of the most common self-inflicted platform outages.
#
# Sources (official):
#   Configure liveness, readiness and startup probes —
#     https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
#   Debug Services (endpoints, selectors, 503s) —
#     https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
#   Rolling back a Deployment —
#     https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment
#   EndpointSlices —
#     https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
#   CNPE Curriculum —
#     https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# ==============================================================================