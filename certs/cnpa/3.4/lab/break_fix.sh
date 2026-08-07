#!/usr/bin/env bash
#
# ==============================================================================
#  CNPA 3.4 — Incident Response and Remediation in Platform Engineering
#  Break & Fix Lab:  "The service is down, but every pod is Running"
# ==============================================================================
#
#  Exam           : CNPA (Cloud Native Platform Engineering Associate)
#  Version        : 2025-04-01
#  Domain         : 3.4 Incident Response and Remediation in Platform Engineering
#  Exam weight    : 2.3
#  Reference      : https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  A Kubernetes-native platform team ships a "config tweak" to a web service.
#  The rollout completes, no image fails to pull, no container crashes, every
#  pod reports `Running`. And yet the service is hard-down: callers get
#  connection refused. This is one of the most common and most misdiagnosed
#  production incidents in platform engineering: the difference between a pod
#  being *running* and a pod being *Ready*. Only Ready pods are added to a
#  Service's Endpoints/EndpointSlices; a readiness probe that fails silently
#  removes every backend and the ClusterIP has nowhere to send traffic.
#
#  You will practice the full incident-response loop the CNPA curriculum
#  expects: detect -> triage -> diagnose (blast radius, root cause) ->
#  remediate (fast rollback vs. forward fix) -> verify -> capture follow-ups.
#
#  SAFETY MODEL
#  ------------
#  * Everything is created inside a single disposable namespace (default
#    "cnpa-incident-lab"). Nothing outside that namespace is ever touched.
#  * The script refuses to run against a context that looks like production
#    unless you set FORCE=1, and it prints the target context/cluster first.
#  * `cleanup` removes the whole namespace and leaves no residue.
#  * Intended target: a throwaway single-node cluster (kind / minikube / k3s)
#    on a lab VM you can delete afterwards.
#
#  USAGE
#  -----
#    ./cnpa_3_4_break_and_fix.sh break     # deploy healthy app, then inject the fault (default)
#    ./cnpa_3_4_break_and_fix.sh verify    # print current health/endpoint status
#    ./cnpa_3_4_break_and_fix.sh hint      # reprint the student briefing
#    ./cnpa_3_4_break_and_fix.sh cleanup   # delete the lab namespace
#
#  Requirements: bash 4+, kubectl configured for a reachable, disposable cluster.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
NS="${NS:-cnpa-incident-lab}"
APP="web"
IMAGE="${IMAGE:-nginxinc/nginx-unprivileged:stable-alpine}"   # listens on :8080, runs as non-root uid 101
REPLICAS="${REPLICAS:-3}"
HEALTHY_PROBE_PATH="/"
BROKEN_PROBE_PATH="/healthz"   # nginx returns 404 here -> httpGet probe treats non-2xx/3xx as failure

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
fi
log()   { printf '%s[ lab ]%s %s\n'  "$C_BLU" "$C_RESET" "$*"; }
ok()    { printf '%s[  ok ]%s %s\n'  "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s[ warn]%s %s\n'  "$C_YEL" "$C_RESET" "$*"; }
die()   { printf '%s[ fail]%s %s\n'  "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
rule()  { printf '%s%s%s\n' "$C_CYN" "------------------------------------------------------------------------------" "$C_RESET"; }

# ------------------------------------------------------------------------------
# Preflight & safety guardrails
# ------------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster. Point KUBECONFIG at your disposable lab cluster."

  local ctx cluster
  ctx="$(kubectl config current-context 2>/dev/null || echo 'unknown')"
  cluster="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo 'unknown')"

  rule
  log "Target context : ${C_BOLD}${ctx}${C_RESET}"
  log "Target cluster : ${C_BOLD}${cluster}${C_RESET}"
  log "Lab namespace  : ${C_BOLD}${NS}${C_RESET}  (all changes are confined here)"
  rule

  # Refuse anything that smells like production unless explicitly forced.
  if [[ "${FORCE:-0}" != "1" ]]; then
    if printf '%s %s %s' "$ctx" "$cluster" "$NS" | grep -Eiq 'prod|prd|live|customer'; then
      die "Context/cluster looks like production. Refusing. Set FORCE=1 to override on a DISPOSABLE cluster."
    fi
  fi
}

ensure_ns() {
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null
  kubectl label ns "$NS" cnpa.lab/purpose=incident-response --overwrite >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Manifests
# ------------------------------------------------------------------------------
# Deployment is rendered with a parameterised readiness-probe path and a
# human-readable change-cause so `kubectl rollout history` reads like a
# release log. Strategy is Recreate on purpose: it makes the incident
# deterministic (a bad probe on every replica => total outage) AND it is a
# real-world anti-pattern the student should be able to name in the postmortem.
render_deployment() {
  local probe_path="$1" change_cause="$2"
  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app: ${APP}
    cnpa.lab/component: frontend
spec:
  replicas: ${REPLICAS}
  revisionHistoryLimit: 10
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
      annotations:
        kubernetes.io/change-cause: "${change_cause}"
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: ${APP}
          image: ${IMAGE}
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          # Liveness stays on a valid path so the container never crashes:
          # the ONLY thing that changes between the healthy and broken release
          # is the readiness path. That is what makes this a "Running but not
          # Ready" incident instead of a CrashLoopBackOff.
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: ${probe_path}
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
YAML
}

render_service() {
  cat <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app: ${APP}
spec:
  type: ClusterIP
  selector:
    app: ${APP}
  ports:
    - name: http
      port: 80
      targetPort: http
YAML
}

# ------------------------------------------------------------------------------
# Status helpers
# ------------------------------------------------------------------------------
ready_replicas()    { kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true; }
endpoint_count()    { kubectl -n "$NS" get endpoints "$APP" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -c . || true; }

wait_for_ready() {
  local want="$1" timeout="${2:-120}" waited=0
  log "Waiting for ${want}/${REPLICAS} pods to become Ready (timeout ${timeout}s)..."
  while (( waited < timeout )); do
    [[ "$(ready_replicas)" == "$want" ]] && { ok "Deployment reports ${want} Ready replica(s)."; return 0; }
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

wait_for_running_not_ready() {
  local timeout="${1:-90}" waited=0 running notready
  log "Waiting for the faulted rollout to land (pods Running, 0 Ready)..."
  while (( waited < timeout )); do
    running="$(kubectl -n "$NS" get pods -l app="$APP" --field-selector=status.phase=Running -o name 2>/dev/null | grep -c . || true)"
    notready="$(ready_replicas)"; notready="${notready:-0}"
    if (( running >= 1 )) && [[ "$notready" == "0" || -z "$notready" ]]; then
      ok "Fault has landed: pods are Running but 0 are Ready."
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  warn "Timed out waiting for the exact symptom, but the fault has been applied."
  return 0
}

verify() {
  local rr ec
  rr="$(ready_replicas)"; rr="${rr:-0}"
  ec="$(endpoint_count)"; ec="${ec:-0}"
  rule
  printf '%sCurrent state of Service/%s in namespace %s%s\n' "$C_BOLD" "$APP" "$NS" "$C_RESET"
  rule
  kubectl -n "$NS" get deploy "$APP" -o wide 2>/dev/null || true
  echo
  kubectl -n "$NS" get pods -l app="$APP" -o wide 2>/dev/null || true
  echo
  printf 'Ready replicas : %s / %s\n' "$rr" "$REPLICAS"
  printf 'Service backends (endpoints): %s\n' "$ec"
  rule
  if [[ "$rr" == "$REPLICAS" && "$ec" -ge 1 ]]; then
    ok "SERVICE HEALTHY — all replicas Ready and the Service has live endpoints."
    return 0
  else
    printf '%sSERVICE DOWN — %s Ready replica(s), %s endpoint(s). Callers get connection refused.%s\n' \
      "$C_RED" "$rr" "$ec" "$C_RESET"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Student briefing
# ------------------------------------------------------------------------------
briefing() {
  cat <<EOF

${C_BOLD}==============================================================================${C_RESET}
${C_BOLD} INCIDENT TICKET  INC-3407  —  SEV2  —  "web is down for all users"${C_RESET}
${C_BOLD}==============================================================================${C_RESET}

${C_BOLD}Reporter:${C_RESET}   On-call alert "web: 0 healthy backends" + user reports of errors.
${C_BOLD}Namespace:${C_RESET}  ${NS}
${C_BOLD}Change:${C_RESET}     A platform engineer applied a "small probe/config tweak" to the
            ${APP} Deployment ~2 minutes before the alert fired.

${C_BOLD}SYMPTOM YOU WILL OBSERVE${C_RESET}
  * ${C_YEL}kubectl -n ${NS} get pods${C_RESET} shows the ${APP} pods as ${C_BOLD}Running${C_RESET}, restart
    count is low/zero — nothing is crash-looping, nothing failed to pull.
  * BUT the READY column shows ${C_RED}0/1${C_RESET} for every pod.
  * ${C_YEL}kubectl -n ${NS} get endpoints ${APP}${C_RESET} shows ${C_RED}<none>${C_RESET} (no backends).
  * A request to the Service ClusterIP is refused — the service is hard-down
    even though "the pods are up".

${C_BOLD}YOUR OBJECTIVE (definition of done)${C_RESET}
  Restore the service WITHOUT deleting the Deployment or the namespace, so that:
    1. All ${REPLICAS} ${APP} pods are ${C_GRN}Ready 1/1${C_RESET}.
    2. Service/${APP} has ${C_GRN}>= 1 endpoint${C_RESET}.
    3. An in-cluster HTTP GET to http://${APP}.${NS}.svc returns ${C_GRN}HTTP 200${C_RESET}.
  Then be ready to answer, as in a real postmortem:
    - Why were the pods Running but the Service still down?
    - What is the fastest safe remediation, and what is the durable fix?
    - Which platform guardrail would have caught this before users did?

${C_BOLD}USEFUL STARTING COMMANDS${C_RESET}
  kubectl -n ${NS} get deploy,rs,pods,endpoints -o wide
  kubectl -n ${NS} describe pod -l app=${APP} | less
  kubectl -n ${NS} get events --sort-by=.lastTimestamp | tail -n 20
  kubectl -n ${NS} rollout history deploy/${APP}

${C_BOLD}When you think it is fixed:${C_RESET}  ./$(basename "$0") verify
${C_BOLD}To reset the lab:${C_RESET}              ./$(basename "$0") cleanup && ./$(basename "$0") break

$(rule)
EOF
}

# ------------------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------------------
do_break() {
  preflight
  ensure_ns

  log "Step 1/3 — Deploying the HEALTHY baseline release (revision 1)..."
  render_service | kubectl apply -f - >/dev/null
  render_deployment "$HEALTHY_PROBE_PATH" "baseline healthy release (readiness=/)" | kubectl apply -f - >/dev/null
  kubectl -n "$NS" rollout status deploy/"$APP" --timeout=120s >/dev/null \
    || die "Baseline failed to become healthy. Check image pull / cluster capacity."
  wait_for_ready "$REPLICAS" 120 || die "Baseline never reached ${REPLICAS} Ready replicas."
  ok "Baseline is healthy and serving."

  log "Step 2/3 — Injecting the controlled fault (bad readiness path, revision 2)..."
  # The ONLY change is the readiness-probe path -> a non-existent endpoint that
  # returns HTTP 404. The container keeps running; it just never becomes Ready.
  render_deployment "$BROKEN_PROBE_PATH" "incident: readiness path changed to ${BROKEN_PROBE_PATH} (404)" \
    | kubectl apply -f - >/dev/null
  wait_for_running_not_ready 90

  log "Step 3/3 — Confirming the outage symptom..."
  if verify; then
    warn "Expected an outage but the service still looks healthy. Re-run 'break' or inspect manually."
  else
    ok "Fault injected successfully. The service is now DOWN in a controlled way."
  fi

  briefing
}

do_cleanup() {
  preflight
  log "Deleting lab namespace ${NS} (and everything in it)..."
  kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ok "Cleanup requested. Namespace ${NS} is terminating."
}

usage() {
  cat <<EOF
CNPA 3.4 Break & Fix — Incident Response and Remediation

Usage: $(basename "$0") [break|verify|hint|cleanup]

  break     Deploy the healthy app, then inject the fault (default).
  verify    Print current health/endpoint status (your success check).
  hint      Reprint the incident briefing.
  cleanup   Delete the lab namespace and all its resources.

Env overrides: NS, IMAGE, REPLICAS, FORCE=1 (bypass prod-name guard).
EOF
}

main() {
  local action="${1:-break}"
  case "$action" in
    break)   do_break ;;
    verify)  preflight; verify ;;
    hint)    briefing ;;
    cleanup) do_cleanup ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown action: ${action}" ;;
  esac
}

main "$@"

# ==============================================================================
#  INSTRUCTOR SOLUTION — DO NOT READ UNTIL YOU HAVE ATTEMPTED THE FIX
# ==============================================================================
#
#  Root cause in one sentence:
#    The rollout changed the container's readinessProbe httpGet path to
#    "/healthz", which nginx answers with HTTP 404. A readiness probe treats
#    any non-2xx/3xx response as a failure, so every pod stays NotReady; the
#    kubelet removes NotReady pods from the Service's EndpointSlice, leaving the
#    ClusterIP with zero backends — a full outage even though every container
#    is happily Running (liveness still targets "/", so nothing restarts).
#
#  ----------------------------------------------------------------------------
#  PHASE 1 — DETECT & TRIAGE (establish blast radius before touching anything)
#  ----------------------------------------------------------------------------
#    kubectl -n cnpa-incident-lab get deploy,rs,pods,endpoints -o wide
#      # Deployment: 0/3 available. Pods: Running, READY 0/1, low restarts.
#      # endpoints/web: <none>  <-- this line IS the outage.
#
#    kubectl -n cnpa-incident-lab get endpointslices -l kubernetes.io/service-name=web
#      # Confirms zero ready addresses backing the Service.
#
#  Mental model to verbalize: "Running" is a pod lifecycle phase; "Ready" is a
#  readiness-gate result. Services route only to Ready endpoints. The two are
#  independent — that gap is the whole incident.
#
#  ----------------------------------------------------------------------------
#  PHASE 2 — DIAGNOSE (find the proximate cause and the change that introduced it)
#  ----------------------------------------------------------------------------
#    kubectl -n cnpa-incident-lab describe pod -l app=web | sed -n '/Conditions/,/Events/p'
#      # Ready: False, ContainersReady: False.
#      # Events: "Readiness probe failed: HTTP probe failed with statuscode: 404".
#
#    kubectl -n cnpa-incident-lab get events --sort-by=.lastTimestamp | tail
#      # A wall of "Unhealthy ... Readiness probe failed ... statuscode: 404".
#
#    # Prove it is readiness-only (container is genuinely serving on "/"):
#    POD=$(kubectl -n cnpa-incident-lab get pod -l app=web -o name | head -1)
#    kubectl -n cnpa-incident-lab exec "$POD" -- \
#      wget -qO- -S http://127.0.0.1:8080/ 2>&1 | head -1     # -> 200 OK
#    kubectl -n cnpa-incident-lab exec "$POD" -- \
#      wget -qO- -S http://127.0.0.1:8080/healthz 2>&1 | head -1  # -> 404 Not Found
#
#    # Tie it to a change — read the release log:
#    kubectl -n cnpa-incident-lab rollout history deploy/web
#      # REVISION 1  baseline healthy release (readiness=/)
#      # REVISION 2  incident: readiness path changed to /healthz (404)
#    kubectl -n cnpa-incident-lab rollout history deploy/web --revision=2
#      # Shows readinessProbe.httpGet.path: /healthz  <-- the smoking gun.
#
#  ----------------------------------------------------------------------------
#  PHASE 3 — REMEDIATE  (choose based on urgency; both restore service)
#  ----------------------------------------------------------------------------
#  OPTION A — FAST ROLLBACK (preferred under SEV pressure; reverts to a known-good state):
#    kubectl -n cnpa-incident-lab rollout undo deploy/web --to-revision=1
#    kubectl -n cnpa-incident-lab rollout status deploy/web --timeout=120s
#
#  OPTION B — FORWARD FIX (when rollback would revert other, wanted changes):
#    kubectl -n cnpa-incident-lab patch deploy/web --type=json \
#      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
#    kubectl -n cnpa-incident-lab rollout status deploy/web --timeout=120s
#    # (In a real platform, the durable forward fix is to make the probe target
#    #  a real endpoint: ship an actual /healthz in the app, or point the probe
#    #  at "/". Never "fix" a red probe by deleting it.)
#
#  ----------------------------------------------------------------------------
#  PHASE 4 — VERIFY (do not declare resolved until traffic actually flows)
#  ----------------------------------------------------------------------------
#    kubectl -n cnpa-incident-lab get pods -l app=web        # 3x READY 1/1
#    kubectl -n cnpa-incident-lab get endpoints web          # 3 IPs listed
#    kubectl -n cnpa-incident-lab run smoke --rm -it --restart=Never \
#      --image=curlimages/curl -- -sS -o /dev/null -w '%{http_code}\n' http://web
#      # -> 200
#    ./cnpa_3_4_break_and_fix.sh verify                      # -> SERVICE HEALTHY
#
#  ----------------------------------------------------------------------------
#  PHASE 5 — POST-INCIDENT / DURABLE GUARDRAILS (the platform-engineering payload)
#  ----------------------------------------------------------------------------
#   * Why did one bad probe = total outage? The Deployment used strategy
#     Recreate, so all replicas were replaced at once with the broken spec.
#     A RollingUpdate with a conservative maxUnavailable (e.g. 0) plus a
#     minReadySeconds gate would have STALLED the rollout with the old healthy
#     pods still serving — the rollout would fail closed instead of open.
#   * Add a progressive-delivery gate (Argo Rollouts / Flagger canary) that
#     watches Ready endpoints and auto-aborts a rollout that yields 0 backends.
#   * CI policy check on manifests: readiness/liveness probe paths must match a
#     route the app actually serves; block probes pointing at undefined paths.
#   * Alert on the leading signal — Service endpoints == 0 (or
#     kube_endpoint_address_available == 0) — not just on user-facing 5xx, so
#     detection beats the customers.
#   * Keep liveness and readiness semantically distinct: readiness gates
#     traffic; liveness restarts. Had liveness ALSO pointed at /healthz, this
#     would have degraded into CrashLoopBackOff and masked the real cause.
#
#  Sources (official):
#    - Kubernetes — Configure Liveness, Readiness and Startup Probes:
#      https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
#    - Kubernetes — Service & EndpointSlices (readiness -> endpoints):
#      https://kubernetes.io/docs/concepts/services-networking/service/
#      https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
#    - Kubernetes — Deployments: rollout, history, undo, strategies:
#      https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
#    - CNPA Curriculum (Domain 3.4):
#      https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ==============================================================================