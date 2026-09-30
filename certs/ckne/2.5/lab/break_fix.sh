#!/usr/bin/env bash
# =============================================================================
# CKNE 2.5 - Configuring Pod Endpoint Availability - BREAK & FIX LAB
# =============================================================================
#
# What this lab breaks (on purpose, only inside its own namespace):
#   A 3-replica nginx Deployment sits behind a ClusterIP Service. The pods are
#   Running, the containers are healthy and nginx answers on port 80, yet the
#   Service sends traffic nowhere: no endpoint in the EndpointSlice is ready.
#   Two separate faults cause this, and you have to find and fix both.
#
# Concepts exercised:
#   - How the EndpointSlice controller derives conditions.ready/serving/
#     terminating from the Pod's Ready condition
#   - readinessProbe vs livenessProbe (liveness keeps the container alive,
#     readiness decides whether it gets traffic)
#   - Pod readinessGates: extra conditions that an external controller (for
#     example a cloud load balancer controller) must set before the Pod is Ready
#   - Why spec.publishNotReadyAddresses is NOT a fix for a broken probe
#   - How readinessGates can stall a Deployment rollout
#
# Requirements:
#   - A throwaway lab cluster (kind, minikube, k3s, kubeadm VM...). NEVER prod.
#   - kubectl >= 1.24 (needs `kubectl patch --subresource=status`)
#   - Nodes able to pull nginx:1.27-alpine and curlimages/curl:8.10.1
#
# Usage:
#   ./break-fix-2.5.sh break     # deploy the broken scenario
#   ./break-fix-2.5.sh status    # show what the student should look at
#   ./break-fix-2.5.sh check     # check whether the fix is correct
#   ./break-fix-2.5.sh cleanup   # delete the lab namespace
#   add -y to skip the confirmation prompt
#
# References:
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
#   https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-readiness-gate
#   https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
#   https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/
# =============================================================================

set -euo pipefail

NS="ckne-lab-2-5"
APP="web"
GATE="lab.ckne.io/lb-registered"
REPLICAS=3
ASSUME_YES="no"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'

info()  { printf '%s[INFO]%s %s\n' "$BLU" "$RST" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YEL" "$RST" "$*"; }
fail()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
die()   { fail "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Safety checks
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version --client >/dev/null 2>&1 || die "kubectl client is not working."

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "No current kubectl context. Point kubectl at a LAB cluster."

  if [[ "$ctx" =~ (prod|prd|production|live) ]] && [[ "${FORCE_UNSAFE:-}" != "1" ]]; then
    die "Context '$ctx' looks like production. Refusing. (FORCE_UNSAFE=1 overrides - don't.)"
  fi

  kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach the API server for context '$ctx'."

  info "kubectl context: ${YEL}${ctx}${RST}"
  info "Everything this lab does is confined to namespace '${NS}'."

  if [[ "$ASSUME_YES" != "yes" ]]; then
    read -r -p "Is this a disposable LAB cluster? Type 'yes' to continue: " ans
    [[ "$ans" == "yes" ]] || die "Aborted by user."
  fi
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  preflight

  if kubectl get ns "$NS" >/dev/null 2>&1; then
    warn "Namespace $NS already exists - recreating it for a clean scenario."
    kubectl delete ns "$NS" --wait=true >/dev/null
  fi

  info "Creating the broken scenario..."

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    purpose: ckne-break-fix
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app: ${APP}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${APP}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      readinessGates:
        - conditionType: "${GATE}"
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
            failureThreshold: 2
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
---
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
      protocol: TCP
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: ${NS}
  labels:
    role: client
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
EOF

  info "Waiting for the pods to be Running (they will NOT become Ready)..."
  kubectl -n "$NS" wait pod -l app="$APP" --for=jsonpath='{.status.phase}'=Running --timeout=180s >/dev/null \
    || warn "Pods are not Running yet - check image pulls with: kubectl -n $NS get pods"
  kubectl -n "$NS" wait pod/client --for=condition=Ready --timeout=180s >/dev/null \
    || warn "Client pod not ready yet."

  sleep 8

  cat <<EOF

${RED}=============================== SCENARIO ===============================${RST}
A product team says: "Our pods are Running and nginx works - if we exec into a
pod, curl localhost gets a 200. But the '${APP}' Service in namespace '${NS}'
times out or refuses connections. Something in Kubernetes networking is broken."

SYMPTOMS YOU WILL SEE:
  * kubectl -n ${NS} get pods -o wide
      READY 0/1 and READINESS GATES 0/1 on every ${APP} pod, STATUS Running,
      RESTARTS 0 (liveness is fine, so nothing restarts)
  * kubectl -n ${NS} get endpointslices -l kubernetes.io/service-name=${APP} -o yaml
      the endpoints are listed, but with conditions.ready: false
  * kubectl -n ${NS} exec client -- curl -sS -m 3 http://${APP}
      fails: connection refused / timeout (depends on your kube-proxy/CNI mode)
  * kubectl -n ${NS} describe pod <pod>
      "Readiness probe failed: ... connect: connection refused"

YOUR GOAL:
  1. All ${REPLICAS} ${APP} pods Ready (READY 1/1) and ${REPLICAS} ready endpoints in the EndpointSlice.
  2. 'curl http://${APP}' from the client pod returns HTTP 200.
  3. Keep a meaningful readinessProbe. Deleting the probe is NOT a fix.
  4. Do NOT set publishNotReadyAddresses on the Service. That hides the
     problem instead of fixing it.
  5. Understand the readiness gate '${GATE}'. In production an external
     controller (for example an LB controller) sets it. Here YOU play that
     controller. Removing the gate from the Deployment is accepted, but the
     checker will tell you what you gave up.

HINTS (only if you are stuck):
  - There are TWO independent reasons the pods are not Ready.
  - Look at the Pod's status.conditions, not just the READY column.
  - After you fix the Deployment, watch the rollout: why does it hang?

Run '$0 status' to watch progress and '$0 check' to check your fix.
${RED}=========================================================================${RST}
EOF
}

# -----------------------------------------------------------------------------
# STATUS - a quick diagnostic view
# -----------------------------------------------------------------------------
do_status() {
  kubectl get ns "$NS" >/dev/null 2>&1 || die "Namespace $NS not found. Run: $0 break"

  info "Pods (look at READY and READINESS GATES):"
  kubectl -n "$NS" get pods -l app="$APP" -o wide || true
  echo

  info "Pod conditions:"
  kubectl -n "$NS" get pods -l app="$APP" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.conditions[*]}{"    "}{.type}{"="}{.status}{"\n"}{end}{end}' || true
  echo

  info "EndpointSlice endpoint conditions (ready/serving/terminating):"
  kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name="$APP" \
    -o jsonpath='{range .items[*].endpoints[*]}{"    "}{.addresses[0]}{"  pod="}{.targetRef.name}{"  ready="}{.conditions.ready}{"  serving="}{.conditions.serving}{"  terminating="}{.conditions.terminating}{"\n"}{end}' || true
  echo

  info "Service reachability from the client pod:"
  if kubectl -n "$NS" exec client -- curl -sS -o /dev/null -w '    HTTP %{http_code}\n' -m 3 "http://${APP}" 2>/dev/null; then
    :
  else
    echo "    request failed"
  fi
}

# -----------------------------------------------------------------------------
# CHECK
# -----------------------------------------------------------------------------
do_check() {
  kubectl get ns "$NS" >/dev/null 2>&1 || die "Namespace $NS not found. Run: $0 break"
  local errors=0

  # 1. No cheating with publishNotReadyAddresses
  local pnra
  pnra="$(kubectl -n "$NS" get svc "$APP" -o jsonpath='{.spec.publishNotReadyAddresses}' 2>/dev/null || true)"
  if [[ "$pnra" == "true" ]]; then
    fail "Service has publishNotReadyAddresses=true. That sends traffic to pods that failed readiness. Revert it."
    errors=$((errors+1))
  else
    ok "Service does not publish not-ready addresses."
  fi

  # 2. Readiness probe still exists
  local probe
  probe="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null || true)"
  if [[ -z "$probe" ]]; then
    fail "The readinessProbe was removed. Without it, a pod is 'ready' as soon as the container starts."
    errors=$((errors+1))
  else
    ok "readinessProbe is present: $probe"
  fi

  # 3. Rollout completed
  if kubectl -n "$NS" rollout status deploy/"$APP" --timeout=20s >/dev/null 2>&1; then
    ok "Deployment rollout is complete."
  else
    fail "Deployment rollout is not complete (kubectl -n $NS rollout status deploy/$APP)."
    errors=$((errors+1))
  fi

  # 4. Ready endpoints in the EndpointSlice
  local ready_count
  ready_count="$(kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name="$APP" \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)"
  if [[ "${ready_count:-0}" -ge "$REPLICAS" ]]; then
    ok "EndpointSlice has ${ready_count} ready endpoints."
  else
    fail "EndpointSlice has ${ready_count:-0}/${REPLICAS} ready endpoints."
    errors=$((errors+1))
  fi

  # 5. Real traffic through the Service
  local code
  code="$(kubectl -n "$NS" exec client -- curl -s -o /dev/null -w '%{http_code}' -m 3 "http://${APP}" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    ok "client -> http://${APP} returned HTTP 200."
  else
    fail "client -> http://${APP} returned '${code:-no response}'."
    errors=$((errors+1))
  fi

  # 6. Readiness gate: kept (preferred) or removed (accepted, with a note)
  local gates
  gates="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.readinessGates[*].conditionType}' 2>/dev/null || true)"
  if [[ "$gates" == *"$GATE"* ]]; then
    ok "Readiness gate '${GATE}' kept and satisfied. This is the production-grade fix."
  else
    warn "Readiness gate removed. Accepted for the lab, but in production this lets pods take"
    warn "traffic before the external system (e.g. LB target registration) has confirmed them."
  fi

  echo
  if [[ "$errors" -eq 0 ]]; then
    ok "${GRN}LAB SOLVED.${RST} Run '$0 cleanup' when done."
  else
    fail "${errors} check(s) failed. Run '$0 status' to dig further."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------
do_cleanup() {
  preflight
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    kubectl delete ns "$NS" --wait=true
    ok "Namespace $NS deleted."
  else
    info "Nothing to clean up."
  fi
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
ACTION="${1:-}"
[[ "${2:-}" == "-y" || "${1:-}" == "-y" ]] && ASSUME_YES="yes"
[[ "$ACTION" == "-y" ]] && ACTION="${2:-}"

case "$ACTION" in
  break)   do_break ;;
  status)  do_status ;;
  check)   do_check ;;
  cleanup) do_cleanup ;;
  *)
    echo "Usage: $0 {break|status|check|cleanup} [-y]"
    exit 2
    ;;
esac

exit 0

# =============================================================================
# SOLUTION (step by step) - read only after you have tried
# =============================================================================
#
# --- Step 0: see the data plane from the control plane's side --------------
#
#   kubectl -n ckne-lab-2-5 get pods -o wide
#   # NAME                  READY   STATUS    RESTARTS   ...   READINESS GATES
#   # web-7d9c...-abcde     0/1     Running   0          ...   0/1
#
#   kubectl -n ckne-lab-2-5 get endpointslices -l kubernetes.io/service-name=web -o yaml
#   #   endpoints:
#   #   - addresses: ["10.244.1.12"]
#   #     conditions:
#   #       ready: false
#   #       serving: false
#   #       terminating: false
#
#   The EndpointSlice controller copies the Pod's Ready condition into
#   conditions.ready. kube-proxy (or eBPF replacements like Cilium) only
#   programs endpoints with ready=true (or serving=true while terminating).
#   Result: the Service VIP has no backends. With iptables kube-proxy you get
#   an immediate REJECT ("connection refused"). Other dataplanes may time out.
#
# --- Step 1: find why the Pod is not Ready -------------------------------
#
#   kubectl -n ckne-lab-2-5 get pod <pod> -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
#   # PodReadyToStartContainers=True
#   # Initialized=True
#   # Ready=False
#   # ContainersReady=False          <- fault #1: container readiness (probe)
#   # PodScheduled=True
#   #                                <- fault #2: lab.ckne.io/lb-registered is
#   #                                   MISSING, and a missing gate condition counts as False
#
#   Pod Ready = ContainersReady AND every readinessGates condition == True.
#
# --- Step 2: fault #1, the readiness probe points at the wrong port/path ------
#
#   kubectl -n ckne-lab-2-5 describe pod <pod> | grep -i readiness
#   #   Readiness:  http-get http://:8080/healthz delay=2s timeout=1s period=5s #success=1 #failure=2
#   #   Warning  Unhealthy  ...  Readiness probe failed: Get "http://10.244.1.12:8080/healthz":
#   #            dial tcp 10.244.1.12:8080: connect: connection refused
#
#   nginx listens on 80 (named port "http") and has no /healthz. The liveness
#   probe (tcpSocket on "http") passes, so nothing restarts. That is why the
#   pods "look fine".
#
#   Fix: probe the real port by name, on a path that returns 2xx/3xx:
#
#   kubectl -n ckne-lab-2-5 patch deployment web --type=json -p='[
#     {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":"http"},
#     {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}
#   ]'
#
# --- Step 3: notice the rollout hangs -----------------------------------
#
#   kubectl -n ckne-lab-2-5 rollout status deploy/web
#   # Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
#
#   With maxUnavailable=0 and maxSurge=1, the Deployment creates ONE new pod
#   and waits for it to become Ready before it continues. The new pod now has
#   ContainersReady=True, but READINESS GATES is still 0/1, so it never
#   becomes Ready and the rollout stalls. This is exactly what happens in
#   production when the LB controller that owns the gate is broken.
#
# --- Step 4: fault #2, satisfy the readiness gate (act as the controller) ----
#
#   A gate condition lives in pod.status, so it has to be written through the
#   status subresource (kubectl >= 1.24). The default strategic merge patch
#   merges conditions by 'type', so the kubelet-owned conditions are kept.
#   Loop until the rollout finishes, because every new pod needs the condition:
#
#   NS=ckne-lab-2-5
#   until kubectl -n $NS rollout status deploy/web --timeout=5s >/dev/null 2>&1; do
#     for p in $(kubectl -n $NS get pods -l app=web -o name); do
#       kubectl -n $NS patch "$p" --subresource=status \
#         -p '{"status":{"conditions":[{"type":"lab.ckne.io/lb-registered","status":"True","reason":"ManualRegistration","message":"set by student"}]}}' \
#         >/dev/null 2>&1 || true
#     done
#     sleep 3
#   done
#
#   (Alternative accepted by the checker: remove the gate from the template
#    with  kubectl -n $NS patch deploy web --type=json \
#          -p='[{"op":"remove","path":"/spec/template/spec/readinessGates"}]'
#    You lose the guarantee that pods only receive traffic after the external
#    system registers them.)
#
# --- Step 5: verify ---------------------------------------------------
#
#   kubectl -n ckne-lab-2-5 get pods -o wide
#   # web-...   1/1   Running   0   ...   1/1
#
#   kubectl -n ckne-lab-2-5 get endpointslices -l kubernetes.io/service-name=web \
#     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
#   # 10.244.1.20 ready=true
#   # 10.244.2.17 ready=true
#   # 10.244.1.21 ready=true
#
#   kubectl -n ckne-lab-2-5 exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web
#   # 200
#
#   ./break-fix-2.5.sh check
#
# --- Wrong fixes and why they are wrong ------------------------------
#
#   * spec.publishNotReadyAddresses: true on the Service
#       curl would succeed here only because nginx happens to work. The
#       setting exists for StatefulSet peer discovery via headless Services
#       (e.g. etcd, Cassandra bootstrap), where peers must resolve each other
#       before they are Ready. On a client-facing Service it sends traffic to
#       pods that failed readiness.
#   * Deleting the readinessProbe
#       The pod becomes Ready as soon as the container starts, before the app
#       is actually able to serve, so every rollout causes errors.
#   * Pointing the readinessProbe at the same check as liveness without thought
#       Readiness should reflect "can I serve traffic now" (dependencies,
#       warm-up). Liveness should reflect "am I stuck and need a restart".
#       If they are the same check, a slow dependency causes restarts.
#
# --- Cleanup ------------------------------------------------------
#
#   ./break-fix-2.5.sh cleanup
# =============================================================================