#!/usr/bin/env bash
#
# ============================================================================
#  ICA — Istio Certified Associate
#  Domain 3: Resiliency and Fault Injection
#  Topic 3.6: Using Resilience Features
#            (circuit breaking, failover, outlier detection, timeouts, retries)
#  Exam weight: 5
#  Reference syllabus: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#
#  LAB TYPE: break & fix
#  This script deploys a tiny in-mesh workload, then plants a PATHOLOGICAL
#  resilience configuration (a DestinationRule whose outlier detection ejects
#  the ENTIRE upstream pool on a single 5xx). Your job is to retune the
#  resilience policy so healthy traffic flows again WITHOUT disabling the
#  resilience feature altogether.
#
#  RUN THIS ONLY ON A DISPOSABLE LAB VM / THROWAWAY KUBERNETES CLUSTER.
#  It creates and deletes a dedicated namespace ($NS). It touches nothing else.
#
#  Official documentation you will need:
#   - Circuit breaking task ....... https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
#   - OutlierDetection reference ... https://istio.io/latest/docs/reference/config/networking/destination-rule/#OutlierDetection
#   - ConnectionPool reference ..... https://istio.io/latest/docs/reference/config/networking/destination-rule/#ConnectionPoolSettings
#   - Request timeouts task ........ https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
#   - HTTP retries reference ....... https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRetry
#   - Network resilience concept ... https://istio.io/latest/docs/concepts/traffic-management/#network-resilience-and-testing
#   - Envoy response flags (UO/UF) . https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#config-access-log-format-response-flags
#
#  Usage:
#     ./lab_3_6.sh break     # deploy, plant the fault, show the symptom, brief you  (default)
#     ./lab_3_6.sh verify    # check whether YOU have fixed it correctly
#     ./lab_3_6.sh diag      # dump the Envoy circuit-breaker / outlier stats
#     ./lab_3_6.sh cleanup   # delete everything this lab created
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
NS="${NS:-ica-lab-36}"
APP="httpbin"
CLIENT="curl-client"
SVC_PORT=8000
DR_API="networking.istio.io/v1"   # v1beta1 also works on older Istio releases
PROBES=20                          # number of probes verify/symptom sends
PASS_THRESHOLD=19                  # >=95% of $PROBES must be HTTP 200 to pass

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
say()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

kx()   { kubectl -n "$NS" "$@"; }

# Run a curl from inside the in-mesh client (so the client sidecar's
# DestinationRule / circuit breaker / outlier detection actually applies).
incurl() {
  kx exec "deploy/${CLIENT}" -c curl -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${APP}:${SVC_PORT}$1" 2>/dev/null || echo "000"
}

client_pod() { kx get pod -l app="${CLIENT}" -o jsonpath='{.items[0].metadata.name}'; }

# ----------------------------------------------------------------------------
# Preflight & safety
# ----------------------------------------------------------------------------
preflight() {
  need kubectl
  need istioctl
  kubectl version >/dev/null 2>&1 || die "cannot reach a Kubernetes cluster (check your kubeconfig/context)."
  kubectl get ns istio-system >/dev/null 2>&1 || die "Istio does not appear to be installed (no istio-system namespace)."

  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  warn "About to operate on context '${ctx}', namespace '${NS}'."
  warn "This MUST be a disposable lab cluster."
  if [ "${FORCE:-}" != "1" ] && [ -t 0 ]; then
    read -r -p "Type the namespace name '${NS}' to continue: " ans
    [ "$ans" = "$NS" ] || die "confirmation mismatch — aborting."
  fi
}

# ----------------------------------------------------------------------------
# Setup: namespace, sidecar injection, workload, in-mesh client
# ----------------------------------------------------------------------------
setup() {
  say "[setup] Creating namespace '${NS}' with sidecar injection enabled"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

  say "[setup] Deploying '${APP}' (2 replicas) and the in-mesh client"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  namespace: ${NS}
  labels: { app: ${APP}, service: ${APP} }
spec:
  ports:
  - name: http
    port: ${SVC_PORT}
    targetPort: 80
  selector: { app: ${APP} }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  replicas: 2
  selector: { matchLabels: { app: ${APP} } }
  template:
    metadata:
      labels: { app: ${APP} }
    spec:
      containers:
      - name: ${APP}
        image: docker.io/kong/httpbin
        ports: [ { containerPort: 80 } ]
        readinessProbe:
          httpGet: { path: /status/200, port: 80 }
          initialDelaySeconds: 2
          periodSeconds: 5
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CLIENT}
  namespace: ${NS}
spec:
  replicas: 1
  selector: { matchLabels: { app: ${CLIENT} } }
  template:
    metadata:
      labels: { app: ${CLIENT} }
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.8.0
        command: ["sleep","infinity"]
EOF

  say "[setup] Waiting for rollouts (workload must be 2/2 = app + sidecar)"
  kx rollout status "deploy/${APP}"    --timeout=150s
  kx rollout status "deploy/${CLIENT}" --timeout=150s

  # Sanity: baseline must be healthy BEFORE we break anything.
  local code; code="$(incurl /status/200)"
  [ "$code" = "200" ] || die "baseline probe returned ${code}, expected 200 — environment not ready."
  say "[setup] Baseline healthy: GET /status/200 -> 200"
}

# ----------------------------------------------------------------------------
# THE BREAK: a resilience policy that turns one transient error into a
# full-pool outage. This is a real, subtle production misconfiguration.
# ----------------------------------------------------------------------------
break_it() {
  say "[break] Planting a pathological DestinationRule on '${APP}'"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: ${DR_API}
kind: DestinationRule
metadata:
  name: ${APP}
  namespace: ${NS}
spec:
  host: ${APP}
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1
      http:
        http1MaxPendingRequests: 1
        maxRequestsPerConnection: 1
    outlierDetection:
      consecutive5xxErrors: 1     # eject a host after a SINGLE 5xx
      interval: 1s
      baseEjectionTime: 180s      # keep it ejected for 3 minutes
      maxEjectionPercent: 100     # allow the ENTIRE pool to be ejected
EOF

  say "[break] Injecting one burst of transient upstream errors (GET /status/503 x30)"
  for _ in $(seq 1 30); do incurl /status/503 >/dev/null; done

  say "[break] Now probing a HEALTHY endpoint that should always be 200:"
  local ok=0 bad=0 code
  for _ in $(seq 1 "$PROBES"); do
    code="$(incurl /status/200)"
    if [ "$code" = "200" ]; then ok=$((ok+1)); else bad=$((bad+1)); fi
    printf '  GET /status/200 -> %s\n' "$code"
  done
  printf '\n  Result: %d x 200, %d x non-200\n' "$ok" "$bad"

  brief
}

# ----------------------------------------------------------------------------
# Student briefing
# ----------------------------------------------------------------------------
brief() {
  cat <<EOF

============================================================================
 STUDENT BRIEFING — Topic 3.6: Using Resilience Features
============================================================================

WHAT YOU JUST SAW (the symptom)
  A brief spike of upstream 5xx errors has "poisoned" the whole service.
  Requests to /status/200 — an endpoint that CANNOT fail on its own — now
  return 503. Inside the client's Envoy you will see the response flag
  'UO' (upstream overflow / circuit breaker open) and/or endpoints marked
  as ejected, i.e. "no healthy upstream". The service is effectively down,
  yet every pod is Running and Ready.

WHY (the mechanism you are being tested on)
  Outlier detection is a passive circuit breaker: the client sidecar ejects
  an upstream host after N consecutive 5xx. Here it was tuned to fail-closed:
    * consecutive5xxErrors: 1   -> one blip ejects a host
    * maxEjectionPercent: 100   -> ALL hosts may be ejected at once
    * baseEjectionTime: 180s    -> and they stay ejected for 3 minutes
  Result: a transient error becomes a self-inflicted total outage. The
  connectionPool limits (maxConnections/http1MaxPendingRequests = 1) make it
  worse by tripping the circuit breaker under trivial concurrency.

WHAT YOU MUST ACHIEVE (definition of done)
  1. GET /status/200 returns 200 reliably again (>= ${PASS_THRESHOLD}/${PROBES} probes).
  2. Outlier detection MUST remain ENABLED. Deleting the DestinationRule or
     removing outlierDetection is NOT an acceptable fix — resilience must
     survive. Retune it so a single bad response can never take out the
     whole pool.
  Then run:  ./lab_3_6.sh verify

DIAGNOSE FIRST (recommended)
  kubectl -n ${NS} get destinationrule ${APP} -o yaml
  ./lab_3_6.sh diag        # shows Envoy outlier/circuit-breaker counters
  istioctl -n ${NS} proxy-config clusters deploy/${CLIENT} --fqdn ${APP}.${NS}.svc.cluster.local

HINTS
  * Study the DestinationRule fields listed above and ask: which of them can
    convert one error into total unavailability?
  * A safe circuit breaker degrades PARTIALLY, never fully.
  * Re-applying a corrected DestinationRule resets Envoy's clusters and
    immediately clears any hosts still ejected from the 180s timer.
============================================================================
EOF
}

# ----------------------------------------------------------------------------
# Diagnostics: expose the circuit-breaker / outlier counters from Envoy
# ----------------------------------------------------------------------------
diag() {
  local pod; pod="$(client_pod)"
  say "[diag] Envoy outlier & circuit-breaker stats for cluster '${APP}'"
  kx exec "$pod" -c istio-proxy -- \
    pilot-agent request GET clusters 2>/dev/null \
    | grep -E "outbound\|${SVC_PORT}\|\|${APP}\." \
    | grep -E 'health_flags|ejections|overflow|cx_active|rq_pending' || \
    warn "no matching cluster stats (has traffic been sent yet?)"
}

# ----------------------------------------------------------------------------
# Verify the student's fix
# ----------------------------------------------------------------------------
verify() {
  say "[verify] Checking that outlier detection is still ENABLED..."
  local dr; dr="$(kx get destinationrule "${APP}" -o yaml 2>/dev/null || true)"
  [ -n "$dr" ] || die "DestinationRule '${APP}' is gone. You must FIX it, not delete it."
  echo "$dr" | grep -q 'outlierDetection' || \
    die "outlierDetection removed. The fix must retune resilience, not disable it."
  if echo "$dr" | grep -qE 'maxEjectionPercent:[[:space:]]*100'; then
    die "maxEjectionPercent is still 100 — the whole pool can still be ejected."
  fi

  say "[verify] Re-injecting the same transient error burst (GET /status/503 x30)..."
  local pod; pod="$(client_pod)"
  for _ in $(seq 1 30); do incurl /status/503 >/dev/null; done

  say "[verify] Probing the healthy endpoint ${PROBES} times..."
  local ok=0 code
  for _ in $(seq 1 "$PROBES"); do
    code="$(incurl /status/200)"
    [ "$code" = "200" ] && ok=$((ok+1))
  done
  printf '  %d/%d probes returned 200 (need >= %d)\n' "$ok" "$PROBES" "$PASS_THRESHOLD"

  if [ "$ok" -ge "$PASS_THRESHOLD" ]; then
    say "PASS ✅  Resilience restored: a transient 5xx no longer sinks the pool, and outlier detection is still active."
  else
    die "FAIL ❌  Healthy traffic is still being dropped. Re-read the briefing and retune the DestinationRule."
  fi
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
cleanup() {
  say "[cleanup] Deleting namespace '${NS}'"
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  say "[cleanup] Done."
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
main() {
  case "${1:-break}" in
    break)   preflight; setup; break_it ;;
    verify)  verify ;;
    diag)    diag ;;
    cleanup) cleanup ;;
    *) echo "Usage: $0 [break|verify|diag|cleanup]"; exit 1 ;;
  esac
}
main "$@"

# ============================================================================
#  INSTRUCTOR SOLUTION — do not read until you have tried it yourself
#  ---------------------------------------------------------------------------
#  ROOT CAUSE
#    The DestinationRule configured a fail-CLOSED circuit breaker. With
#    consecutive5xxErrors=1 a single upstream 5xx ejects a host; with
#    maxEjectionPercent=100 both replicas can be ejected at once; with
#    baseEjectionTime=180s they stay out for 3 minutes. So one transient
#    error produced a full, self-inflicted outage — even on /status/200,
#    which cannot fail on its own. The 1/1/1 connectionPool limits made the
#    breaker trip under trivial concurrency (Envoy flag 'UO').
#
#  STEP 1 — Observe and confirm the diagnosis
#    kubectl -n ica-lab-36 get destinationrule httpbin -o yaml
#    ./lab_3_6.sh diag
#      # look for  outlier.ejections_active  > 0  and  health_flags::/failed_outlier_check
#    istioctl -n ica-lab-36 proxy-config clusters deploy/curl-client \
#      --fqdn httpbin.ica-lab-36.svc.cluster.local
#
#  STEP 2 — Retune the resilience policy (fail PARTIAL, not TOTAL)
#    cat <<'YAML' | kubectl apply -f -
#    apiVersion: networking.istio.io/v1
#    kind: DestinationRule
#    metadata:
#      name: httpbin
#      namespace: ica-lab-36
#    spec:
#      host: httpbin
#      trafficPolicy:
#        connectionPool:
#          tcp:
#            maxConnections: 100          # room for real concurrency
#          http:
#            http1MaxPendingRequests: 100
#            maxRequestsPerConnection: 0  # 0 = unlimited (no premature recycling)
#        outlierDetection:
#          consecutive5xxErrors: 5        # need a real pattern, not one blip
#          interval: 5s
#          baseEjectionTime: 30s          # shorter penalty, self-heals faster
#          maxEjectionPercent: 50         # NEVER eject the whole pool
#    YAML
#    # Re-applying the DestinationRule resets Envoy's cluster and immediately
#    # clears any hosts still ejected under the old 180s timer.
#
#  STEP 3 — Verify
#    ./lab_3_6.sh verify        # expect PASS: ~20/20 x 200, outlier detection still on
#
#  KEY TAKEAWAYS FOR THE EXAM
#    * maxEjectionPercent caps the blast radius; 100 turns a circuit breaker
#      into a single point of failure. Keep it well below 100 (commonly 10-50).
#    * consecutive5xxErrors=1 is hair-trigger; use a threshold that reflects a
#      genuine failure trend, and keep baseEjectionTime short so hosts re-enter.
#    * Related resilience knobs you should also be able to configure:
#        - Timeouts:  VirtualService http.timeout
#            https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
#        - Retries:   VirtualService http.retries {attempts, perTryTimeout, retryOn}
#            https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRetry
#        - Failover:  DestinationRule localityLbSetting.failover / failoverPriority
#            https://istio.io/latest/docs/reference/config/networking/destination-rule/#LocalityLoadBalancerSetting
#    * Golden rule of resilience config: degrade gracefully and partially;
#      a policy that can drive availability to zero is worse than none.
# ============================================================================