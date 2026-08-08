#!/usr/bin/env bash
#
# ica-3.7-fault-injection-break-and-fix.sh
#
# ICA (Istio Certified Associate) — Domain 3: Traffic Management
# Topic 3.7: "Using Fault Injection"  (exam weight: 5%)
#
# BREAK & FIX lab. This script deliberately misconfigures an Istio
# VirtualService so that a healthy backend appears to be failing, and then
# challenges you to diagnose and repair it. The step-by-step solution is at
# the very bottom of the file, commented out — try to solve it first.
#
# Scenario (very common in the field): a teammate ran a chaos / resilience
# test using Istio fault injection and forgot to remove the fault rule before
# merging. The Deployment, the Pods and the Service are all perfectly healthy,
# yet every request to the service returns HTTP 503. Nothing in `kubectl get
# pods`, `kubectl logs` or `kubectl describe` points at a cause, because the
# failure is being manufactured by the Envoy sidecar, not by the application.
#
# References (official):
#   - Istio task: Fault Injection
#       https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
#   - VirtualService API — HTTPFaultInjection (abort / delay)
#       https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPFaultInjection
#   - CNCF ICA curriculum
#       https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#
# ---------------------------------------------------------------------------
# !!! DISPOSABLE LAB VM ONLY !!!
# This creates and mutates real cluster objects. Run it against a throwaway
# kind/minikube/k3d cluster on a lab VM you can delete. Never against a
# cluster that matters. The script confirms the active context before acting.
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---------------------------------------------------------
NS="${NS:-ica-lab-37}"                 # dedicated, disposable namespace
ISTIO_VS_API="${ISTIO_VS_API:-networking.istio.io/v1}"
CONFIRM="${LAB_CONFIRM:-}"             # set LAB_CONFIRM=yes to skip the prompt
MODE="${1:-break}"                      # break | test | cleanup

# --- Pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
  YLW="$(printf '\033[33m')"; CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YLW=""; CYN=""; RST=""
fi
info() { printf '%s[*]%s %s\n' "$CYN" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster. Point KUBECONFIG at your lab cluster."
  kubectl get ns istio-system >/dev/null 2>&1 || \
    die "istio-system namespace not found. Install Istio first: 'istioctl install --set profile=demo -y'."
  command -v istioctl >/dev/null 2>&1 || \
    warn "istioctl not found. It is optional here, but you will want it for proxy-config diagnosis."
}

confirm_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo 'unknown')"
  warn "Active kube-context : ${BOLD}${ctx}${RST}"
  warn "Target namespace    : ${BOLD}${NS}${RST}"
  if [[ "$CONFIRM" != "yes" ]]; then
    printf '%sType exactly "%s" to proceed (or Ctrl-C to abort): %s' "$YLW" "$NS" "$RST"
    local answer; read -r answer
    [[ "$answer" == "$NS" ]] || die "Aborted: confirmation did not match."
  fi
}

# --- Sample app ------------------------------------------------------------
deploy_app() {
  info "Creating namespace '$NS' with automatic sidecar injection..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

  info "Deploying a healthy backend (httpbin) and a client (sleep)..."
  kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
---
apiVersion: v1
kind: Service
metadata:
  name: sleep
  labels:
    app: sleep
    service: sleep
spec:
  ports:
  - port: 80
    name: http
  selector:
    app: sleep
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      terminationGracePeriodSeconds: 0
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl
        command: ["/bin/sleep", "infinity"]
        imagePullPolicy: IfNotPresent
EOF

  info "Waiting for the workloads to become ready (this pulls images on first run)..."
  kubectl -n "$NS" rollout status deploy/httpbin --timeout=180s >/dev/null
  kubectl -n "$NS" rollout status deploy/sleep   --timeout=180s >/dev/null
  ok "Backend and client are healthy. Confirm the app is fine BEFORE we break it:"
  run_probe
}

# --- The controlled break --------------------------------------------------
apply_break() {
  info "Applying the fault: a VirtualService that aborts 100% of requests with HTTP 503..."
  kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: ${ISTIO_VS_API}
kind: VirtualService
metadata:
  name: httpbin
  annotations:
    lab/injected-by: "ica-3.7-break-and-fix"
spec:
  hosts:
  - httpbin
  http:
  - fault:
      abort:
        httpStatus: 503
        percentage:
          value: 100
    route:
    - destination:
        host: httpbin
EOF
  ok "Fault injected."
}

# --- Probe helper ----------------------------------------------------------
run_probe() {
  local pod
  pod="$(kubectl -n "$NS" get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || die "sleep pod not found. Run '$0 break' first."
  printf '    %s$ kubectl -n %s exec deploy/sleep -c sleep -- curl -s -o /dev/null -w "HTTP %%{http_code}\\n" httpbin:8000/get%s\n' "$BOLD" "$NS" "$RST"
  local code
  code="$(kubectl -n "$NS" exec deploy/sleep -c sleep -- \
            curl -s -o /dev/null -w '%{http_code}' httpbin:8000/get 2>/dev/null || echo '000')"
  printf '    -> HTTP %s\n' "$code"
  printf '    %s(response body):%s\n' "$BOLD" "$RST"
  kubectl -n "$NS" exec deploy/sleep -c sleep -- \
    curl -s httpbin:8000/get 2>/dev/null | sed 's/^/    | /' || true
}

# --- Cleanup ---------------------------------------------------------------
cleanup() {
  confirm_context
  info "Deleting namespace '$NS' and everything in it..."
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null
  ok "Lab torn down."
}

# --- Briefing --------------------------------------------------------------
brief() {
  cat <<EOF

${BOLD}================= ICA 3.7 — BREAK & FIX: FAULT INJECTION =================${RST}

${BOLD}THE SYMPTOM${RST}
  Every request from the 'sleep' client to 'httpbin' now returns:

      ${RED}HTTP 503${RST}   with body:  ${RED}fault filter abort${RST}

  The Deployment is Ready, the Pod is Running, the Service has endpoints,
  and the container logs show NOTHING wrong — because the application never
  received the request. Envoy short-circuited it at the sidecar.

  Reproduce it any time with:
      ${CYN}$0 test${RST}

${BOLD}YOUR MISSION${RST}
  Restore normal service so that requests to httpbin:8000 return HTTP 200
  again — WITHOUT deleting the httpbin workload. The workload is innocent.

${BOLD}HINTS (spend a moment on each before scrolling)${RST}
  1. "fault filter abort" is not an application message. Which Istio object
     can manufacture an HTTP status that the app never produced?
  2. Compare the mesh config objects in the namespace against the workloads.
     Something is present that should not be.
  3. istioctl can show you exactly what Envoy was told to do per route.

  When you are ready, read the commented SOLUTION block at the bottom of
  this script (${BOLD}$0${RST}).

${BOLD}=========================================================================${RST}

EOF
}

# --- Main ------------------------------------------------------------------
case "$MODE" in
  break)
    preflight
    confirm_context
    deploy_app
    apply_break
    warn "Now observe the failure:"
    run_probe
    brief
    ;;
  test)
    preflight
    run_probe
    ;;
  cleanup)
    cleanup
    ;;
  *)
    die "Usage: $0 [break|test|cleanup]   (env: NS, LAB_CONFIRM=yes, ISTIO_VS_API)"
    ;;
esac

# ===========================================================================
# ============================  SOLUTION (SPOILER)  =========================
# ===========================================================================
#
# ---- STEP 0: Confirm the workload itself is healthy ----------------------
#   The instinct is to blame the app. Rule it out first.
#
#     kubectl -n ica-lab-37 get pods,svc,endpoints
#     kubectl -n ica-lab-37 logs deploy/httpbin -c httpbin --tail=20
#
#   Pods Running, Service has endpoints, logs clean. The app is fine.
#
# ---- STEP 1: Read the symptom precisely ---------------------------------
#   The body "fault filter abort" is emitted by Envoy's fault filter, not by
#   httpbin. That single string is the whole diagnosis: an Istio fault
#   injection rule is aborting the request before it reaches the app.
#     (A companion symptom for the DELAY variant is a request that hangs for
#      N seconds and then may time out — same root cause, different knob.)
#
#     kubectl -n ica-lab-37 exec deploy/sleep -c sleep -- \
#       curl -s -D - httpbin:8000/get -o /dev/null
#     # HTTP/1.1 503 Service Unavailable
#     # ... body: fault filter abort
#
# ---- STEP 2: Find the object that injects the fault ---------------------
#   Fault injection lives in a VirtualService (HTTPRoute.fault). List them:
#
#     kubectl -n ica-lab-37 get virtualservice
#     # NAME      GATEWAYS   HOSTS         AGE
#     # httpbin              ["httpbin"]   2m
#
#     kubectl -n ica-lab-37 get virtualservice httpbin -o yaml
#     # spec:
#     #   http:
#     #   - fault:
#     #       abort:
#     #         httpStatus: 503
#     #         percentage:
#     #           value: 100      <-- 100% of traffic aborted. This is the bug.
#     #     route:
#     #     - destination:
#     #         host: httpbin
#
# ---- STEP 3 (optional): Confirm it in the data plane --------------------
#   Prove the sidecar actually enforces it. The fault shows up on the route
#   of the CLIENT proxy (sleep), because that is where the outbound rule is
#   evaluated:
#
#     istioctl -n ica-lab-37 proxy-config route deploy/sleep \
#       --name 8000 -o yaml | grep -A3 fault
#     # typedPerFilterConfig envoy.filters.http.fault -> abort 503 @ 100%
#
# ---- STEP 4: Fix it -----------------------------------------------------
#   Remove the fault. Pick ONE:
#
#   (a) Surgical patch — keep the VirtualService, drop only the fault block:
#         kubectl -n ica-lab-37 patch virtualservice httpbin --type=json \
#           -p '[{"op":"remove","path":"/spec/http/0/fault"}]'
#
#   (b) Re-apply a clean VirtualService (routing kept, fault gone):
#         kubectl apply -n ica-lab-37 -f - <<'YAML'
#         apiVersion: networking.istio.io/v1
#         kind: VirtualService
#         metadata:
#           name: httpbin
#         spec:
#           hosts:
#           - httpbin
#           http:
#           - route:
#             - destination:
#                 host: httpbin
#         YAML
#
#   (c) If no routing rule is needed at all, delete the VirtualService and
#       let mesh defaults route the Service:
#         kubectl -n ica-lab-37 delete virtualservice httpbin
#
#   In production, prefer (a) or (b): removing the object may also remove
#   legitimate routing/retry/timeout rules that share it. Fault injection
#   should always be scoped and temporary — gate it with a `match` clause
#   (e.g. a test header) so it can never abort real user traffic:
#
#         http:
#         - match:
#           - headers:
#               x-chaos-test: { exact: "on" }
#           fault: { abort: { httpStatus: 503, percentage: { value: 100 } } }
#           route: [ { destination: { host: httpbin } } ]
#         - route: [ { destination: { host: httpbin } } ]   # normal traffic
#
# ---- STEP 5: Verify recovery -------------------------------------------
#     kubectl -n ica-lab-37 exec deploy/sleep -c sleep -- \
#       curl -s -o /dev/null -w "HTTP %{http_code}\n" httpbin:8000/get
#     # HTTP 200      <-- mission accomplished
#
# ---- STEP 6: Clean up the lab ------------------------------------------
#     ./ica-3.7-fault-injection-break-and-fix.sh cleanup
#
# ---- WHY THIS MATTERS FOR THE EXAM -------------------------------------
#   * Fault injection is a TEST tool (verify retries/timeouts/circuit
#     breaking), not a routing feature — its side effect is a failure that
#     leaves the app untouched, which is exactly what makes it tricky to
#     diagnose from the app side.
#   * Two knobs: `abort` (return an HTTP/gRPC status) and `delay`
#     (`fixedDelay`), each gated by `percentage.value`.
#   * The fault is enforced by the *caller's* Envoy sidecar; look at the
#     client proxy's routes, not the server's.
#   * "fault filter abort" is the fingerprint. Memorize it.
#
#   Docs: https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
# ===========================================================================