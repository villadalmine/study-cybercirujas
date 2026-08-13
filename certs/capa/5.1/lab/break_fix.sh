#!/usr/bin/env bash
#
# ============================================================================
#  CAPA (Certified Argo Project Associate) — Break & Fix Lab
#  Domain 5. Argo Events   |   Topic 5.1 Argo Events   |   Exam weight: 20%
# ----------------------------------------------------------------------------
#  Reference sources (official):
#    - CNCF curriculum:   https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
#    - Argo Events docs:  https://argoproj.github.io/argo-events/
#    - Concepts:          https://argoproj.github.io/argo-events/concepts/architecture/
#    - Sensor spec:       https://argoproj.github.io/argo-events/APIs/#argoproj.io/v1alpha1.Sensor
#    - EventSource spec:  https://argoproj.github.io/argo-events/APIs/#argoproj.io/v1alpha1.EventSource
# ----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES
#    1. Installs Argo Events (controller + a native NATS EventBus) if missing.
#    2. Deploys a KNOWN-GOOD pipeline:  webhook EventSource -> EventBus -> Sensor(log trigger)
#    3. Proves it works end to end (POST to the webhook -> line appears in the Sensor log).
#    4. Then BREAKS it in ONE controlled, fully reversible way and hands the
#       cluster to you to diagnose and repair.
#
#  SAFETY
#    - Everything lives in the 'argo-events' namespace. It touches nothing else.
#    - The break is a single, reversible manifest edit on a Sensor it created.
#    - RUN THIS ONLY ON A DISPOSABLE LAB CLUSTER (kind / minikube / throwaway VM).
# ============================================================================

set -euo pipefail

NS="argo-events"
STABLE="https://raw.githubusercontent.com/argoproj/argo-events/stable"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true' EXIT

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# 0. Guard rails: refuse to run outside an obvious throwaway context.
# --------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster."

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
log "Current kube-context: ${CTX}"
if [[ "${CTX}" =~ (prod|production|mgmt|live) ]]; then
  die "Context '${CTX}' looks like a real cluster. Aborting. Switch to a lab context."
fi
if [[ "${I_UNDERSTAND_THIS_IS_A_LAB:-}" != "yes" ]]; then
  warn "This will install Argo Events and then intentionally break a Sensor."
  warn "Re-run with:  I_UNDERSTAND_THIS_IS_A_LAB=yes  $0"
  exit 1
fi

# --------------------------------------------------------------------------
# 1. Install Argo Events (idempotent).
# --------------------------------------------------------------------------
log "Ensuring namespace '${NS}' exists"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

log "Installing Argo Events controllers (idempotent apply)"
kubectl apply -n "${NS}" -f "${STABLE}/manifests/install.yaml" >/dev/null

log "Creating a native NATS EventBus named 'default'"
kubectl apply -n "${NS}" -f "${STABLE}/examples/eventbus/native.yaml" >/dev/null

log "Waiting for the EventBus to report Deployed=True (up to 180s)"
for i in $(seq 1 60); do
  STATUS="$(kubectl -n "${NS}" get eventbus default \
    -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null || true)"
  [[ "${STATUS}" == "True" ]] && break
  sleep 3
done
[[ "${STATUS:-}" == "True" ]] || die "EventBus 'default' never became ready. Check: kubectl -n ${NS} describe eventbus default"

# --------------------------------------------------------------------------
# 2. Deploy the KNOWN-GOOD pipeline.
#    A webhook EventSource publishes event 'example' to the EventBus.
#    The Sensor depends on (eventSourceName=webhook, eventName=example) and,
#    when that dependency fires, runs a 'log' trigger that prints the payload
#    to its own pod log — no extra RBAC, nothing created outside the ns.
# --------------------------------------------------------------------------
log "Applying the webhook EventSource"
cat >"${WORK}/eventsource.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: webhook
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  webhook:
    example:
      port: "12000"
      endpoint: /example
      method: POST
YAML
kubectl apply -f "${WORK}/eventsource.yaml" >/dev/null

log "Applying the GOOD Sensor (dependency eventName MATCHES the EventSource)"
cat >"${WORK}/sensor-good.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: webhook
  namespace: argo-events
spec:
  dependencies:
    - name: test-dep
      eventSourceName: webhook
      eventName: example          # <-- MATCHES the EventSource key 'example'
  triggers:
    - template:
        name: log-trigger
        log:
          intervalSeconds: 0
YAML
kubectl apply -f "${WORK}/sensor-good.yaml" >/dev/null

log "Waiting for the EventSource and Sensor deployments to roll out"
kubectl -n "${NS}" rollout status deploy/webhook-eventsource --timeout=180s
kubectl -n "${NS}" rollout status deploy/webhook-sensor      --timeout=180s

# --------------------------------------------------------------------------
# 3. Prove the pipeline works BEFORE we break it.
# --------------------------------------------------------------------------
log "Port-forwarding the EventSource service on localhost:12000"
kubectl -n "${NS}" port-forward svc/webhook-eventsource-svc 12000:12000 >/dev/null 2>&1 &
PF_PID=$!
sleep 4

log "Firing a test event: POST http://localhost:12000/example"
if command -v curl >/dev/null 2>&1; then
  curl -s -m 5 -d '{"message":"pre-break sanity check"}' \
       -H "Content-Type: application/json" \
       http://localhost:12000/example || warn "curl failed; the port-forward may need a moment."
fi
sleep 5

log "The Sensor SHOULD have logged the trigger. Recent Sensor log lines:"
kubectl -n "${NS}" logs deploy/webhook-sensor --tail=15 | grep -iE 'trigger|log-trigger|successfully' || \
  warn "No trigger line seen yet — give it a few more seconds and re-check the log."

kill "$PF_PID" 2>/dev/null || true
PF_PID=""

# --------------------------------------------------------------------------
# 4. THE CONTROLLED BREAK
#    We re-apply the SAME Sensor with a single-character typo in the
#    dependency: eventName 'example' -> 'exemple'. The EventBus subject the
#    Sensor subscribes to no longer matches the subject the EventSource
#    publishes on. Events keep flowing INTO the bus; the Sensor simply never
#    hears them. This is the single most common real-world Argo Events bug.
# --------------------------------------------------------------------------
log "Injecting the fault (dependency eventName typo)…"
cat >"${WORK}/sensor-broken.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: webhook
  namespace: argo-events
spec:
  dependencies:
    - name: test-dep
      eventSourceName: webhook
      eventName: exemple          # <-- BROKEN: does NOT match EventSource key 'example'
  triggers:
    - template:
        name: log-trigger
        log:
          intervalSeconds: 0
YAML
kubectl apply -f "${WORK}/sensor-broken.yaml" >/dev/null
kubectl -n "${NS}" rollout status deploy/webhook-sensor --timeout=120s

cat <<'BRIEF'

============================================================================
  BREAK INJECTED — YOUR TASK
============================================================================

SCENARIO
  A teammate reports: "The webhook still answers, our monitoring shows the
  EventSource is receiving hits, but the Sensor stopped doing anything.
  Nothing downstream fires anymore."

THE SYMPTOM YOU WILL OBSERVE
  * The webhook still returns HTTP 200. Reproduce it:
      kubectl -n argo-events port-forward svc/webhook-eventsource-svc 12000:12000 &
      curl -s -d '{"message":"hi"}' -H 'Content-Type: application/json' \
           http://localhost:12000/example

  * The EventSource log shows it RECEIVED and PUBLISHED the event:
      kubectl -n argo-events logs deploy/webhook-eventsource --tail=20
      # expect lines like: "dispatching event ... successfully processed"

  * BUT the Sensor NEVER logs a trigger anymore:
      kubectl -n argo-events logs deploy/webhook-sensor --tail=20
      # you will NOT see a new "successfully processed trigger 'log-trigger'"
      # The Sensor is healthy and Running — it is simply listening on the
      # wrong EventBus subject, so the dependency 'test-dep' is never satisfied.

  * 'kubectl get' looks green — the resources are all Ready. Nothing crashes.
    This is a SILENT, logic-level failure, not a crash. That is the lesson.

YOUR GOAL (definition of done)
  After your fix, a single POST to /example MUST produce a fresh
  "successfully processed trigger" line in the Sensor log — WITHOUT deleting
  and recreating the whole stack. Fix the misconfiguration in place.

HINTS
  * Argo Events routes on an EventBus SUBJECT derived from the pair
    (eventSourceName, eventName). Both sides must agree exactly.
  * Compare what the EventSource PUBLISHES against what the Sensor SUBSCRIBES to:
      kubectl -n argo-events get eventsource webhook -o yaml | grep -A6 'webhook:'
      kubectl -n argo-events get sensor      webhook -o yaml | grep -A4 'dependencies:'
  * The EventSource event key and the Sensor dependency 'eventName' are the
    contract. Read them character by character.

============================================================================
BRIEF

exit 0

# ============================================================================
#  SOLUTION — do not read until you have tried. Step by step.
# ============================================================================
#
#  STEP 1 — Confirm the two halves of the contract disagree.
#  ---------------------------------------------------------------------------
#    $ kubectl -n argo-events get eventsource webhook -o yaml | grep -A6 'webhook:'
#      webhook:
#        example:                     <-- EventSource publishes event key 'example'
#          endpoint: /example
#          method: POST
#          port: "12000"
#
#    $ kubectl -n argo-events get sensor webhook -o yaml | grep -A4 'dependencies:'
#      dependencies:
#      - eventName: exemple           <-- Sensor subscribes to 'exemple'  (TYPO)
#        eventSourceName: webhook
#        name: test-dep
#
#    'example' != 'exemple'. The Sensor is subscribed to a subject the
#    EventSource never publishes to, so dependency 'test-dep' never resolves.
#
#  STEP 2 — Fix it in place. Any of these works; pick one.
#  ---------------------------------------------------------------------------
#    (a) Live edit, then save:
#          $ kubectl -n argo-events edit sensor webhook
#            # change   eventName: exemple   ->   eventName: example
#
#    (b) Targeted patch (dependencies is a list, so patch element [0]):
#          $ kubectl -n argo-events patch sensor webhook --type='json' \
#              -p='[{"op":"replace","path":"/spec/dependencies/0/eventName","value":"example"}]'
#
#    (c) Re-apply a corrected manifest (GitOps-friendly, the real-world answer):
#          $ cat <<'EOF' | kubectl apply -f -
#          apiVersion: argoproj.io/v1alpha1
#          kind: Sensor
#          metadata:
#            name: webhook
#            namespace: argo-events
#          spec:
#            dependencies:
#              - name: test-dep
#                eventSourceName: webhook
#                eventName: example
#            triggers:
#              - template:
#                  name: log-trigger
#                  log:
#                    intervalSeconds: 0
#          EOF
#
#  STEP 3 — The Sensor controller redeploys the Sensor pod with the new
#           subscription. Wait for the new pod to be Ready:
#  ---------------------------------------------------------------------------
#    $ kubectl -n argo-events rollout status deploy/webhook-sensor
#      deployment "webhook-sensor" successfully rolled out
#
#  STEP 4 — Re-test end to end and confirm the definition of done.
#  ---------------------------------------------------------------------------
#    $ kubectl -n argo-events port-forward svc/webhook-eventsource-svc 12000:12000 &
#    $ curl -s -d '{"message":"fixed"}' -H 'Content-Type: application/json' \
#           http://localhost:12000/example
#      success
#
#    $ kubectl -n argo-events logs deploy/webhook-sensor --tail=20
#      ... "successfully processed the event"
#      ... "successfully processed trigger" triggerName=log-trigger
#      {"message":"fixed"}            <-- the payload printed by the log trigger
#
#    The trigger fires again -> the pipeline is repaired.
#
#  ROOT CAUSE / TAKEAWAY
#  ---------------------------------------------------------------------------
#    Argo Events is fully decoupled through the EventBus. An EventSource and a
#    Sensor never talk directly; they rendezvous on a subject computed from
#    (eventSourceName, eventName). A mismatch on EITHER field breaks routing
#    with NO error and NO crash — every resource stays Ready. Always debug
#    Argo Events top-down along the flow:
#        EventSource log (received/published?)  ->
#        EventBus healthy (Deployed=True?)      ->
#        Sensor log (dependency satisfied / trigger fired?)
#    and verify the (eventSourceName, eventName) contract on both ends first.
#
#  CLEANUP (optional, disposable lab):
#    $ kubectl delete ns argo-events
# ============================================================================