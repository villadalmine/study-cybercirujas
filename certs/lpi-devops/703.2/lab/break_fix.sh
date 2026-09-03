#!/usr/bin/env bash
#
# lpi-701-703.2-break-and-fix.sh
#
# LPI DevOps Tools Engineer — Exam 701-100 (v2.0.0)
# Topic 703.2: Basic Kubernetes Operations  (exam weight: 11.67)
#
# Break & fix lab: this script injects controlled, reversible faults into a
# throwaway single-node Kubernetes cluster, tells the student exactly which
# symptom to expect, and grades the repair. Every object it creates lives in a
# dedicated namespace labelled `lpi.lab/disposable=true`; nothing outside that
# namespace is touched except the *default namespace of the current kubeconfig
# context* (scenario 6), which is saved and restored on cleanup.
#
# RUN THIS ONLY ON A DISPOSABLE LAB VM (k3s / minikube / kind / kubeadm sandbox).
#
# Sources:
#   - LPI Exam 701 objectives: https://www.lpi.org/our-certifications/exam-701-objectives/
#   - kubectl reference:       https://kubernetes.io/docs/reference/kubectl/
#   - Debug running pods:      https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
#   - Service / EndpointSlice: https://kubernetes.io/docs/concepts/services-networking/service/
#   - Probes:                  https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
#
# Usage:
#   ./lpi-701-703.2-break-and-fix.sh setup                 # build the healthy baseline
#   ./lpi-701-703.2-break-and-fix.sh break random          # inject one random fault
#   ./lpi-701-703.2-break-and-fix.sh break 1 4             # inject specific faults
#   ./lpi-701-703.2-break-and-fix.sh break all             # inject every fault
#   ./lpi-701-703.2-break-and-fix.sh status                # raw cluster state
#   ./lpi-701-703.2-break-and-fix.sh hint                  # progressive hints
#   ./lpi-701-703.2-break-and-fix.sh verify                # grade the repair
#   ./lpi-701-703.2-break-and-fix.sh solution              # print the answer key
#   ./lpi-701-703.2-break-and-fix.sh cleanup               # remove everything
#
# Environment overrides:
#   NS=bf-703-2               target namespace
#   APP_IMAGE=nginx:1.29-alpine
#   CURL_IMAGE=curlimages/curl:8.11.1
#   MAX_NODES=3               refuse to run on a cluster larger than this
#   LAB_CONFIRM=yes           required when the kube-context is not a known lab context
#   CONTEXT_TRAP=0            disable scenario 6 when using "break all"

set -euo pipefail

NS="${NS:-bf-703-2}"
DECOY_NS="${NS}-decoy"
APP_IMAGE="${APP_IMAGE:-nginx:1.29-alpine}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"
MAX_NODES="${MAX_NODES:-3}"
CONTEXT_TRAP="${CONTEXT_TRAP:-1}"
MARKER="LPI-703.2-OK"
SVC_FQDN="web.${NS}.svc.cluster.local"
TOTAL_SCENARIOS=6

STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lpi-703.2}"
STATE_FILE="${STATE_DIR}/active-scenarios"
ORIG_NS_FILE="${STATE_DIR}/original-namespace"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED="$(tput setaf 1)"; C_GRN="$(tput setaf 2)"; C_YEL="$(tput setaf 3)"
    C_BLU="$(tput setaf 4)"; C_BLD="$(tput bold)";    C_RST="$(tput sgr0)"
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
fail()  { printf '%s[-]%s %s\n' "$C_RED" "$C_RST" "$*"; }
die()   { fail "$*"; exit 1; }
rule()  { printf '%s%s%s\n' "$C_BLD" "--------------------------------------------------------------------------" "$C_RST"; }
title() { rule; printf '%s%s%s\n' "$C_BLD" "$*" "$C_RST"; rule; }

k() { kubectl -n "$NS" "$@"; }

# ---------------------------------------------------------------------------
# Guard rails
# ---------------------------------------------------------------------------

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

assert_lab_cluster() {
    need_cmd kubectl
    kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster: check KUBECONFIG / current-context"

    local ctx nodes
    ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
    nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    if [ "$nodes" -gt "$MAX_NODES" ]; then
        die "cluster has ${nodes} nodes (MAX_NODES=${MAX_NODES}). This does not look like a disposable lab."
    fi

    case "$ctx" in
        default|k3s-default|minikube|microk8s|kind-*|kubernetes-admin@kubernetes|*lab*|*sandbox*)
            : ;;
        *)
            if [ "${LAB_CONFIRM:-no}" != "yes" ]; then
                fail "current-context is '${ctx}', which is not a recognised lab context."
                die  "Re-run with LAB_CONFIRM=yes if this VM really is disposable."
            fi
            warn "unrecognised context '${ctx}' accepted via LAB_CONFIRM=yes"
            ;;
    esac
    info "context=${ctx}  nodes=${nodes}  namespace=${NS}"
}

assert_lab_namespace() {
    local label
    label="$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.lpi\.lab/disposable}' 2>/dev/null || true)"
    [ "$label" = "true" ] || die "namespace '${NS}' is missing the lpi.lab/disposable=true label — refusing to touch it. Run: $0 setup"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

state_add() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    grep -qx "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >>"$STATE_FILE"
}

state_list() {
    [ -f "$STATE_FILE" ] && sort -u "$STATE_FILE" || true
}

state_clear() { rm -f "$STATE_FILE"; }

# ---------------------------------------------------------------------------
# Baseline stack
# ---------------------------------------------------------------------------

cmd_setup() {
    assert_lab_cluster
    title "Building the healthy baseline in namespace '${NS}'"

    kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    lpi.lab/disposable: "true"
    lpi.lab/topic: "703.2"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-content
  namespace: ${NS}
data:
  index.html: |
    <!doctype html>
    <html>
      <head><title>${MARKER}</title></head>
      <body><h1>${MARKER}</h1><p>703.2 Basic Kubernetes Operations</p></body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ${NS}
  labels:
    app: web
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        tier: frontend
    spec:
      containers:
        - name: web
          image: ${APP_IMAGE}
          ports:
            - name: http
              containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html
              readOnly: true
      volumes:
        - name: content
          configMap:
            name: web-content
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: ${NS}
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tester
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tester
  template:
    metadata:
      labels:
        app: tester
    spec:
      containers:
        - name: curl
          image: ${CURL_IMAGE}
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
YAML

    info "waiting for the rollout (this pulls images the first time) ..."
    k rollout status deployment/web    --timeout=180s
    k rollout status deployment/tester --timeout=180s

    if probe_http | grep -q '^200'; then
        ok "baseline is healthy: http://${SVC_FQDN} returns 200 and serves '${MARKER}'"
    else
        warn "baseline came up but the HTTP probe did not return 200 yet — re-run '$0 status' in a few seconds"
    fi
    echo
    info "Next: $0 break random"
}

# ---------------------------------------------------------------------------
# Probes used by both the briefing and the grader
# ---------------------------------------------------------------------------

probe_http() {
    # prints "<http_code> <body-first-line>" or "000 " when unreachable
    local code body
    if ! k get deployment tester >/dev/null 2>&1; then echo "000 no-tester"; return; fi
    code="$(k exec deploy/tester -- curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${SVC_FQDN}/" 2>/dev/null || echo 000)"
    body="$(k exec deploy/tester -- curl -sS -m 5 "http://${SVC_FQDN}/" 2>/dev/null | tr -d '\r' | grep -o "${MARKER}" | head -n1 || true)"
    echo "${code} ${body}"
}

ready_endpoints() {
    k get endpointslice -l "kubernetes.io/service-name=web" \
        -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null \
        | grep -c '^true$' || true
}

total_endpoints() {
    k get endpointslice -l "kubernetes.io/service-name=web" \
        -o jsonpath='{range .items[*].endpoints[*].addresses[*]}{@}{"\n"}{end}' 2>/dev/null \
        | grep -c . || true
}

desired_replicas() { k get deployment web -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0; }
available_replicas() { k get deployment web -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0; }

waiting_reasons() {
    k get pods -l app=web \
        -o jsonpath='{range .items[*].status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' || true
}

pending_pods() {
    k get pods -l app=web --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' '
}

current_ctx_ns() { kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Fault injection
# ---------------------------------------------------------------------------

break_1() { # Service selector drift
    k patch service web -p '{"spec":{"selector":{"app":"web-frontend"}}}' >/dev/null
}

break_2() { # Image tag typo -> ImagePullBackOff
    k set image deployment/web "web=${APP_IMAGE%:*}:1.29-alpone" >/dev/null
}

break_3() { # Unschedulable CPU request -> Pending
    k patch deployment web --type=json \
      -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"64"},
           {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"64"}]' >/dev/null
}

break_4() { # Missing ConfigMap -> CreateContainerConfigError
    k delete configmap web-content --ignore-not-found >/dev/null
    k rollout restart deployment/web >/dev/null
}

break_5() { # Readiness probe on the wrong port -> Running but 0/1 READY
    k patch deployment web --type=json \
      -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":8080}]' >/dev/null
}

break_6() { # kubeconfig default namespace trap
    mkdir -p "$STATE_DIR"
    [ -f "$ORIG_NS_FILE" ] || current_ctx_ns >"$ORIG_NS_FILE"
    kubectl create namespace "$DECOY_NS" --dry-run=client -o yaml \
        | kubectl label -f - --local -o yaml lpi.lab/disposable=true \
        | kubectl apply -f - >/dev/null
    kubectl config set-context --current --namespace="$DECOY_NS" >/dev/null
}

brief_1() {
cat <<EOF
${C_BLD}Scenario 1 — the Service stops sending traffic to its Pods${C_RST}

  SYMPTOM
    The Pods are Running and 1/1 READY, but nothing answers through the Service:

      \$ kubectl -n ${NS} exec deploy/tester -- curl -sS -m 5 http://${SVC_FQDN}/
      curl: (28) Failed to connect to ${SVC_FQDN} port 80 after 5000 ms

      \$ kubectl -n ${NS} get endpoints web
      NAME   ENDPOINTS   AGE
      web    <none>      12m

  WHAT IS BEING TESTED
    A ClusterIP Service is nothing but a label selector plus a virtual IP. The
    control plane builds the EndpointSlice by listing Pods whose labels match
    spec.selector. No match -> no endpoints -> kube-proxy has no backend and the
    connection is black-holed (timeout), not refused.

  YOUR OBJECTIVE
    Make 'kubectl -n ${NS} get endpointslice -l kubernetes.io/service-name=web'
    list 3 ready addresses, and the curl above return HTTP 200 with '${MARKER}'.
    Do not delete the Deployment.
EOF
}

brief_2() {
cat <<EOF
${C_BLD}Scenario 2 — a rollout that never finishes${C_RST}

  SYMPTOM
      \$ kubectl -n ${NS} rollout status deployment/web
      Waiting for deployment "web" rollout to finish: 2 out of 3 new replicas have been updated...

      \$ kubectl -n ${NS} get pods -l app=web
      NAME                   READY   STATUS             RESTARTS   AGE
      web-7d9f8c6b45-2xq7z   0/1     ImagePullBackOff   0          70s
      web-5c8bd6f9d7-lm4kv   1/1     Running            0          14m

      \$ kubectl -n ${NS} describe pod -l app=web | grep -A2 Failed
        Warning  Failed  kubelet  Failed to pull image "nginx:1.29-alpone":
                 not found: manifest unknown

  WHAT IS BEING TESTED
    RollingUpdate keeps the old ReplicaSet alive while the new one fails, so the
    service degrades instead of dying — which is exactly why a broken rollout can
    sit unnoticed. You must read the Pod events, and roll back or correct forward.

  YOUR OBJECTIVE
    3/3 Pods Running with a valid image, 'kubectl rollout status' returning
    "successfully rolled out", and the Service answering 200.
EOF
}

brief_3() {
cat <<EOF
${C_BLD}Scenario 3 — Pods that are never scheduled${C_RST}

  SYMPTOM
      \$ kubectl -n ${NS} get pods -l app=web
      NAME                   READY   STATUS    RESTARTS   AGE
      web-6b4c9d8f77-9wqmt   0/1     Pending   0          45s

      \$ kubectl -n ${NS} describe pod -l app=web | tail -5
      Events:
        Warning  FailedScheduling  default-scheduler
          0/1 nodes are available: 1 Insufficient cpu.
          preemption: 0/1 nodes are available: 1 No preemption victims found.

  WHAT IS BEING TESTED
    Pending means the scheduler could not place the Pod: it is a *scheduling*
    problem, never a kubelet or image problem. requests (not limits) are what the
    scheduler compares against the node's allocatable capacity.

  YOUR OBJECTIVE
    Compare the Pod request against 'kubectl describe node', bring the request
    back to something the node can host, and get 3/3 Pods Running.
EOF
}

brief_4() {
cat <<EOF
${C_BLD}Scenario 4 — the container cannot even be created${C_RST}

  SYMPTOM
      \$ kubectl -n ${NS} get pods -l app=web
      NAME                   READY   STATUS                       RESTARTS   AGE
      web-58cf7b5d94-hs2kx   0/1     CreateContainerConfigError   0          30s

      \$ kubectl -n ${NS} describe pod -l app=web | tail -4
      Events:
        Warning  Failed  kubelet  Error: configmap "web-content" not found

  WHAT IS BEING TESTED
    A volume that projects a ConfigMap is a hard dependency: the kubelet refuses
    to build the container sandbox's mounts until the object exists. Note the
    status is CreateContainerConfigError, not ImagePullBackOff and not
    CrashLoopBackOff — each of those points at a different layer.

  YOUR OBJECTIVE
    Recreate the missing object so that the Pods start AND the page served on
    http://${SVC_FQDN}/ contains the string '${MARKER}'.
    Hint: the key inside the ConfigMap must be the file name nginx will serve.
EOF
}

brief_5() {
cat <<EOF
${C_BLD}Scenario 5 — Running, but never Ready${C_RST}

  SYMPTOM
      \$ kubectl -n ${NS} get pods -l app=web
      NAME                   READY   STATUS    RESTARTS   AGE
      web-79fbb6cc8d-pk2tt   0/1     Running   0          90s

      \$ kubectl -n ${NS} describe pod -l app=web | grep -i readiness
        Readiness probe failed: Get "http://10.42.0.31:8080/": dial tcp 10.42.0.31:8080: connect: connection refused

      \$ kubectl -n ${NS} get endpointslice -l kubernetes.io/service-name=web -o wide
      NAME        ADDRESSTYPE   PORTS   ENDPOINTS     READY
      web-2xk9d   IPv4          80      10.42.0.31    false

  WHAT IS BEING TESTED
    Readiness gates Service membership. The container is alive and listening,
    but on a port the probe is not asking about, so the endpoint stays
    ready=false and the Service has no usable backend. Contrast with liveness,
    which would restart the container instead.

  YOUR OBJECTIVE
    3/3 READY, endpoints ready=true, and 200 through the Service — without
    changing the port nginx actually listens on.
EOF
}

brief_6() {
cat <<EOF
${C_BLD}Scenario 6 — "my objects disappeared"${C_RST}

  SYMPTOM
      \$ kubectl get pods
      No resources found in ${DECOY_NS} namespace.

      \$ kubectl get deployments
      No resources found in ${DECOY_NS} namespace.

  WHAT IS BEING TESTED
    kubectl resolves the namespace in this order: --namespace flag > the
    'namespace' field of the current kubeconfig context > "default". Someone
    changed the context default. Nothing was deleted.

  YOUR OBJECTIVE
    Prove where your workload lives with a cluster-wide query, then point the
    current context back at a sane namespace.
    Note: cleanup restores your original context namespace automatically.
EOF
}

cmd_break() {
    assert_lab_cluster
    assert_lab_namespace

    local requested=("$@")
    [ ${#requested[@]} -eq 0 ] && requested=("random")

    local targets=()
    case "${requested[0]}" in
        all)
            targets=(1 2 3 4 5)
            [ "$CONTEXT_TRAP" = "1" ] && targets+=(6)
            ;;
        random)
            local n
            if command -v shuf >/dev/null 2>&1; then
                n="$(shuf -i 1-5 -n 1)"
            else
                n=$(( (RANDOM % 5) + 1 ))
            fi
            targets=("$n")
            ;;
        *)
            targets=("${requested[@]}")
            ;;
    esac

    local s
    for s in "${targets[@]}"; do
        case "$s" in
            [1-6]) ;;
            *) die "unknown scenario '$s' (valid: 1..${TOTAL_SCENARIOS}, all, random)" ;;
        esac
        info "injecting fault #${s} ..."
        "break_${s}"
        state_add "$s"
    done

    info "letting the controllers converge on the broken state (20s) ..."
    sleep 20

    echo
    title "BREAK & FIX — LPI 701-100, topic 703.2 (Basic Kubernetes Operations)"
    cat <<EOF
Everything you need lives in namespace '${NS}'. The reference service is:

    ClusterIP Service 'web'  ->  Deployment 'web' (3 replicas, nginx)
    A helper Deployment 'tester' gives you an in-cluster curl:

        kubectl -n ${NS} exec deploy/tester -- curl -sS -m 5 http://${SVC_FQDN}/

The lab is SOLVED when that command returns the page containing '${MARKER}'
and '$0 verify' prints ALL CHECKS PASSED.

EOF
    for s in $(state_list); do
        echo
        "brief_${s}"
    done
    echo
    rule
    printf 'Suggested toolkit: %s\n' "kubectl get/describe/logs/events, -o yaml, --show-labels, rollout history|undo, explain"
    printf 'Stuck?  %s hint      Grade yourself?  %s verify      Answer key?  %s solution\n' "$0" "$0" "$0"
    rule
}

# ---------------------------------------------------------------------------
# Hints
# ---------------------------------------------------------------------------

cmd_hint() {
    assert_lab_cluster
    local active; active="$(state_list)"
    [ -n "$active" ] || { warn "no active scenario recorded; nothing to hint at"; return 0; }

    title "Hints (in escalating order — stop reading as soon as you can act)"
    local s
    for s in $active; do
        case "$s" in
          1) cat <<'EOF'
Scenario 1:
  1. Endpoints are computed, never typed. Which two objects must agree?
  2. kubectl -n NS get pods --show-labels   vs   kubectl -n NS get svc web -o yaml | grep -A3 selector
  3. Both `kubectl patch svc` and `kubectl label pods` can close the gap; only one of
     them survives the next rollout of the Deployment. Prefer the durable fix.
EOF
          ;;
          2) cat <<'EOF'
Scenario 2:
  1. Read the Pod, not the Deployment: kubectl -n NS describe pod -l app=web
  2. The Events block names the exact image reference the kubelet tried to pull.
  3. kubectl rollout history deployment/web --revision=N shows the last good image.
     `kubectl rollout undo` reverts; `kubectl set image` fixes forward. Both are valid.
EOF
          ;;
          3) cat <<'EOF'
Scenario 3:
  1. Pending == the scheduler, not the kubelet. Read the FailedScheduling event.
  2. kubectl describe node | grep -A6 "Allocatable"  and compare with the Pod's requests.
  3. kubectl -n NS get deploy web -o jsonpath='{.spec.template.spec.containers[0].resources}'
     Then patch requests AND limits back to a sane value (50m / 200m).
EOF
          ;;
          4) cat <<'EOF'
Scenario 4:
  1. CreateContainerConfigError points at configuration the kubelet must resolve
     BEFORE starting the container: ConfigMap, Secret, or a projected key.
  2. kubectl -n NS get deploy web -o jsonpath='{.spec.template.spec.volumes}' names it.
  3. nginx serves /usr/share/nginx/html; the ConfigMap key becomes the file name.
     So you need a key literally called index.html containing the marker string.
EOF
          ;;
          5) cat <<'EOF'
Scenario 5:
  1. STATUS=Running with READY=0/1 is always a readiness question.
  2. kubectl -n NS describe pod -l app=web | grep -i "readiness probe failed"
  3. Compare the probe port with containerPort / with what nginx binds:
     kubectl -n NS exec deploy/web -- wget -qO- http://127.0.0.1:80/ | head -1
     Fix the probe, not the server.
EOF
          ;;
          6) cat <<'EOF'
Scenario 6:
  1. Nothing was deleted. Ask the whole cluster: kubectl get deploy -A | grep web
  2. kubectl config view --minify | grep namespace   shows what kubectl assumes.
  3. kubectl config set-context --current --namespace=<ns>   (or just use -n).
EOF
          ;;
        esac
        echo
    done
}

# ---------------------------------------------------------------------------
# Status dump
# ---------------------------------------------------------------------------

cmd_status() {
    assert_lab_cluster
    title "Raw state of namespace '${NS}'"
    kubectl get all -n "$NS" -o wide 2>/dev/null || true
    echo
    info "Pod labels"
    k get pods --show-labels 2>/dev/null || true
    echo
    info "Service selector"
    k get svc web -o jsonpath='{.spec.selector}{"\n"}' 2>/dev/null || true
    echo
    info "EndpointSlices"
    k get endpointslice -l "kubernetes.io/service-name=web" -o wide 2>/dev/null || true
    echo
    info "Recent events"
    k get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 15 || true
    echo
    info "HTTP probe through the Service"
    probe_http
}

# ---------------------------------------------------------------------------
# Grading
# ---------------------------------------------------------------------------

check_1() { [ "$(total_endpoints)" -ge 1 ]; }
check_2() { ! waiting_reasons | grep -qiE 'ImagePull|ErrImage'; }
check_3() { [ "$(pending_pods)" -eq 0 ]; }
check_4() { k get configmap web-content >/dev/null 2>&1 && probe_http | grep -q "${MARKER}"; }
check_5() { local d r; d="$(desired_replicas)"; r="$(ready_endpoints)"; [ "${r:-0}" -ge "${d:-1}" ]; }
check_6() { [ "$(current_ctx_ns)" != "$DECOY_NS" ]; }

label_for() {
    case "$1" in
        1) echo "Service selector matches the Pods (endpoints populated)" ;;
        2) echo "No image pull failures on any Pod" ;;
        3) echo "No Pod stuck in Pending (schedulable requests)" ;;
        4) echo "ConfigMap web-content exists and its content is served" ;;
        5) echo "All endpoints are ready=true (readiness probe correct)" ;;
        6) echo "kubeconfig context no longer points at the decoy namespace" ;;
    esac
}

cmd_verify() {
    assert_lab_cluster
    assert_lab_namespace
    title "Grading topic 703.2 lab in namespace '${NS}'"

    local rc=0 s desired avail probe code

    desired="$(desired_replicas)"; avail="$(available_replicas)"; avail="${avail:-0}"
    probe="$(probe_http)"; code="${probe%% *}"

    printf '  %-62s ' "Deployment web available replicas (${avail}/${desired})"
    if [ "${avail:-0}" -ge "${desired:-1}" ]; then printf '%sPASS%s\n' "$C_GRN" "$C_RST"; else printf '%sFAIL%s\n' "$C_RED" "$C_RST"; rc=1; fi

    printf '  %-62s ' "HTTP 200 through the Service (got ${code})"
    if [ "$code" = "200" ]; then printf '%sPASS%s\n' "$C_GRN" "$C_RST"; else printf '%sFAIL%s\n' "$C_RED" "$C_RST"; rc=1; fi

    printf '  %-62s ' "Served page contains '${MARKER}'"
    if echo "$probe" | grep -q "${MARKER}"; then printf '%sPASS%s\n' "$C_GRN" "$C_RST"; else printf '%sFAIL%s\n' "$C_RED" "$C_RST"; rc=1; fi

    local active; active="$(state_list)"
    if [ -n "$active" ]; then
        echo
        info "Per-scenario checks"
        for s in $active; do
            printf '  #%s %-59s ' "$s" "$(label_for "$s")"
            if "check_${s}"; then printf '%sPASS%s\n' "$C_GRN" "$C_RST"; else printf '%sFAIL%s\n' "$C_RED" "$C_RST"; rc=1; fi
        done
    fi

    echo
    if [ "$rc" -eq 0 ]; then
        ok "ALL CHECKS PASSED — the service is healthy end to end."
        info "Now explain out loud, for each fault: which layer failed, and which single command proved it."
        state_clear
    else
        fail "Not there yet. Re-read the failing line above and go back to describe/events/logs."
        info "Progressive hints: $0 hint     Answer key: $0 solution"
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Answer key / cleanup
# ---------------------------------------------------------------------------

cmd_solution() {
    title "Answer key — step by step"
    sed -n '/^# === SOLUTION START/,$p' "${BASH_SOURCE[0]}"
}

cmd_cleanup() {
    assert_lab_cluster
    if kubectl get ns "$NS" >/dev/null 2>&1; then
        assert_lab_namespace
        info "deleting namespace ${NS} ..."
        kubectl delete namespace "$NS" --wait=false >/dev/null
    fi
    if kubectl get ns "$DECOY_NS" >/dev/null 2>&1; then
        info "deleting namespace ${DECOY_NS} ..."
        kubectl delete namespace "$DECOY_NS" --wait=false >/dev/null
    fi
    if [ -f "$ORIG_NS_FILE" ]; then
        local orig; orig="$(cat "$ORIG_NS_FILE")"
        [ -z "$orig" ] && orig="default"
        kubectl config set-context --current --namespace="$orig" >/dev/null
        info "kubeconfig context namespace restored to '${orig}'"
        rm -f "$ORIG_NS_FILE"
    fi
    state_clear
    ok "lab removed"
}

usage() {
cat <<EOF
LPI 701-100 — topic 703.2 Basic Kubernetes Operations — break & fix lab

  $0 setup                 build the healthy baseline in namespace '${NS}'
  $0 break [all|random|N…] inject fault(s) 1..${TOTAL_SCENARIOS} and print the briefing
  $0 status                dump the raw cluster state
  $0 hint                  progressive hints for the active scenarios
  $0 verify                grade the repair (exit 0 == solved)
  $0 solution              print the commented answer key
  $0 cleanup               delete everything and restore the kubeconfig namespace

Scenarios:
  1  Service selector drift            -> empty endpoints, curl times out
  2  Image tag typo                    -> ImagePullBackOff, rollout stuck
  3  Oversized CPU request             -> Pending / Insufficient cpu
  4  Missing ConfigMap                 -> CreateContainerConfigError
  5  Readiness probe on the wrong port -> Running but 0/1 READY
  6  kubeconfig default namespace trap -> "No resources found"
EOF
}

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        setup)    cmd_setup ;;
        break)    cmd_break "$@" ;;
        status)   cmd_status ;;
        hint)     cmd_hint ;;
        verify)   cmd_verify ;;
        solution) cmd_solution ;;
        cleanup)  cmd_cleanup ;;
        help|-h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
exit $?

# === SOLUTION START =========================================================
#
# ANSWER KEY — LPI 701-100, topic 703.2 (Basic Kubernetes Operations)
# Namespace: bf-703-2 (override with NS=). Every command below assumes
# `-n bf-703-2` unless it is explicitly cluster-scoped.
#
# ---------------------------------------------------------------------------
# STEP 0 — Universal triage order. Do this before touching anything.
# ---------------------------------------------------------------------------
#   kubectl -n bf-703-2 get all -o wide
#   kubectl -n bf-703-2 get pods --show-labels
#   kubectl -n bf-703-2 get events --sort-by=.lastTimestamp | tail -20
#
#   Read the Pod STATUS column first; it tells you which layer failed:
#     Pending                     -> scheduler (resources, taints, nodeSelector)
#     ContainerCreating (stuck)   -> kubelet: volumes, CNI, image pull in progress
#     ImagePullBackOff/ErrImagePull -> registry, tag or credentials
#     CreateContainerConfigError  -> missing ConfigMap/Secret referenced by the Pod
#     CrashLoopBackOff            -> the process itself exits; read logs
#     Running + READY 0/1         -> readiness probe
#     Running + READY 1/1 + no traffic -> Service selector / ports / NetworkPolicy
#
# ---------------------------------------------------------------------------
# SCENARIO 1 — Service selector drift (empty endpoints)
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n bf-703-2 get endpointslice -l kubernetes.io/service-name=web -o wide
#     NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
#     web-9wq2p   IPv4          <unset> <unset>     14m       <-- no addresses
#   kubectl -n bf-703-2 get svc web -o jsonpath='{.spec.selector}{"\n"}'
#     {"app":"web-frontend"}
#   kubectl -n bf-703-2 get pods -l app=web --show-labels
#     web-5c8bd6f9d7-lm4kv   1/1   Running   app=web,pod-template-hash=...,tier=frontend
#
#   The Service selects app=web-frontend; the Pods carry app=web. No intersection.
#
# Fix (durable — change the Service, which is the object that drifted):
#   kubectl -n bf-703-2 patch service web -p '{"spec":{"selector":{"app":"web"}}}'
#
#   Equivalent declarative form:
#     kubectl -n bf-703-2 edit service web        # spec.selector.app: web
#
#   Do NOT "fix" it by relabelling the Pods (kubectl label pod ... app=web-frontend):
#   the Deployment's template would overwrite that on the next rollout, and a Pod
#   whose labels no longer match spec.selector.matchLabels is orphaned from its
#   ReplicaSet — the controller immediately creates a replacement.
#
# Verify:
#   kubectl -n bf-703-2 get endpointslice -l kubernetes.io/service-name=web -o wide
#     ENDPOINTS: 10.42.0.31,10.42.0.32,10.42.0.33
#   kubectl -n bf-703-2 exec deploy/tester -- curl -sS http://web.bf-703-2.svc.cluster.local/ | grep LPI
#     <h1>LPI-703.2-OK</h1>
#
# ---------------------------------------------------------------------------
# SCENARIO 2 — Image tag typo (ImagePullBackOff, rollout stuck)
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n bf-703-2 rollout status deployment/web --timeout=10s
#     error: timed out waiting for the condition
#   kubectl -n bf-703-2 describe pod -l app=web | grep -B2 -A4 'Failed'
#     Warning  Failed  kubelet  Failed to pull image "nginx:1.29-alpone":
#              failed to resolve reference: not found: manifest unknown
#   kubectl -n bf-703-2 get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
#     nginx:1.29-alpone
#
# Fix A — roll back to the last known-good revision (fastest, and what you do at 03:00):
#   kubectl -n bf-703-2 rollout history deployment/web
#     REVISION  CHANGE-CAUSE
#     1         <none>
#     2         <none>
#   kubectl -n bf-703-2 rollout history deployment/web --revision=1 | grep Image
#     Image:  nginx:1.29-alpine
#   kubectl -n bf-703-2 rollout undo deployment/web --to-revision=1
#
# Fix B — fix forward (when the intended new version is known good):
#   kubectl -n bf-703-2 set image deployment/web web=nginx:1.29-alpine
#
# Verify:
#   kubectl -n bf-703-2 rollout status deployment/web
#     deployment "web" successfully rolled out
#   kubectl -n bf-703-2 get pods -l app=web
#     3 Pods, 1/1 Running
#
# Note: the old ReplicaSet kept serving throughout. `kubectl get rs -n bf-703-2`
# shows the failed one scaled to its surge count with 0 ready — that pair of
# ReplicaSets is the signature of a stalled RollingUpdate.
#
# ---------------------------------------------------------------------------
# SCENARIO 3 — Unschedulable CPU request (Pending)
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n bf-703-2 describe pod -l app=web | tail -6
#     Warning  FailedScheduling  default-scheduler
#       0/1 nodes are available: 1 Insufficient cpu.
#   kubectl describe node | grep -A8 'Allocatable'
#     cpu:  4
#   kubectl -n bf-703-2 get deploy web \
#     -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
#     {"limits":{"cpu":"64","memory":"128Mi"},"requests":{"cpu":"64","memory":"32Mi"}}
#
#   64 CPUs requested on a 4-CPU node: the scheduler can never satisfy it. The
#   scheduler only ever looks at requests; limits are enforced later by the
#   kubelet/cgroups, but a limit lower than the request is rejected by the API
#   server, which is why both fields must come down together.
#
# Fix:
#   kubectl -n bf-703-2 patch deployment web --type=json -p '[
#     {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"50m"},
#     {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"200m"}]'
#
# Verify:
#   kubectl -n bf-703-2 get pods -l app=web -o wide     # all Running, NODE assigned
#   kubectl -n bf-703-2 rollout status deployment/web
#
# ---------------------------------------------------------------------------
# SCENARIO 4 — Missing ConfigMap (CreateContainerConfigError)
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n bf-703-2 describe pod -l app=web | tail -4
#     Warning  Failed  kubelet  Error: configmap "web-content" not found
#   kubectl -n bf-703-2 get deploy web -o jsonpath='{.spec.template.spec.volumes}{"\n"}'
#     [{"configMap":{"name":"web-content"},"name":"content"}]
#   kubectl -n bf-703-2 get cm
#     No resources found in bf-703-2 namespace.
#
#   The mount path tells you what the key must be called:
#   volumeMounts[0].mountPath == /usr/share/nginx/html, and a ConfigMap volume
#   projects each key as a file. nginx serves index.html from that directory.
#
# Fix (declarative — this is the form you keep in git):
#   kubectl apply -f - <<'YAML'
#   apiVersion: v1
#   kind: ConfigMap
#   metadata:
#     name: web-content
#     namespace: bf-703-2
#   data:
#     index.html: |
#       <!doctype html>
#       <html>
#         <head><title>LPI-703.2-OK</title></head>
#         <body><h1>LPI-703.2-OK</h1><p>703.2 Basic Kubernetes Operations</p></body>
#       </html>
#   YAML
#
#   Imperative equivalent:
#     printf '<h1>LPI-703.2-OK</h1>\n' > /tmp/index.html
#     kubectl -n bf-703-2 create configmap web-content --from-file=index.html=/tmp/index.html
#
#   Pods in CreateContainerConfigError retry on their own backoff; to converge now:
#     kubectl -n bf-703-2 rollout restart deployment/web
#
#   Careful: an already-mounted ConfigMap updates in place (kubelet refreshes the
#   projected files within ~1 minute) but a *recreated* one only reaches Pods that
#   are (re)started — which is exactly why the fault survived until the restart.
#
# Verify:
#   kubectl -n bf-703-2 exec deploy/tester -- curl -sS http://web.bf-703-2.svc.cluster.local/
#     ... <h1>LPI-703.2-OK</h1> ...
#
# ---------------------------------------------------------------------------
# SCENARIO 5 — Readiness probe on the wrong port (Running, 0/1 READY)
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n bf-703-2 get pods -l app=web
#     web-79fbb6cc8d-pk2tt   0/1   Running   0   90s
#   kubectl -n bf-703-2 describe pod -l app=web | grep -i -A1 'readiness'
#     Readiness:  http-get http://:8080/ delay=2s timeout=1s period=5s
#     Warning  Unhealthy  kubelet  Readiness probe failed:
#       Get "http://10.42.0.31:8080/": dial tcp 10.42.0.31:8080: connect: connection refused
#   Prove the server itself is fine, from inside the container:
#   kubectl -n bf-703-2 exec deploy/web -- wget -qO- http://127.0.0.1:80/ | head -1
#     <!doctype html>
#
#   Container alive + probe failing = the probe is wrong, not the app. Because
#   readiness is what gates EndpointSlice membership, the Service has endpoints
#   with conditions.ready=false and kube-proxy programs no backend.
#
# Fix:
#   kubectl -n bf-703-2 patch deployment web --type=json -p '[
#     {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'
#
#   Better still, reference the named port so the probe can never drift again:
#     ... readinessProbe.httpGet.port: http     # matches ports[0].name
#
# Verify:
#   kubectl -n bf-703-2 get pods -l app=web            # 1/1 READY
#   kubectl -n bf-703-2 get endpointslice -l kubernetes.io/service-name=web \
#     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
#     10.42.0.31 ready=true
#
# ---------------------------------------------------------------------------
# SCENARIO 6 — kubeconfig default namespace trap
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl get pods
#     No resources found in bf-703-2-decoy namespace.       <-- read the namespace!
#   kubectl config view --minify -o jsonpath='{..namespace}{"\n"}'
#     bf-703-2-decoy
#   kubectl get deployments -A | grep web
#     bf-703-2   web   3/3   3   3   22m
#
# Fix:
#   kubectl config set-context --current --namespace=bf-703-2
#   kubectl config view --minify | grep namespace:
#     namespace: bf-703-2
#
#   Resolution order to memorise: --namespace/-n  >  context.namespace  >  "default".
#   `kubectl api-resources --namespaced=false` lists what ignores namespaces entirely
#   (nodes, PVs, StorageClasses, ClusterRoles…), which is why `get nodes` kept working.
#
# ---------------------------------------------------------------------------
# FINAL VERIFICATION (what the grader runs)
# ---------------------------------------------------------------------------
#   kubectl -n bf-703-2 get deploy web -o jsonpath='{.status.availableReplicas}/{.spec.replicas}{"\n"}'
#     3/3
#   kubectl -n bf-703-2 exec deploy/tester -- \
#     curl -sS -o /dev/null -w '%{http_code}\n' http://web.bf-703-2.svc.cluster.local/
#     200
#   ./lpi-701-703.2-break-and-fix.sh verify
#     [+] ALL CHECKS PASSED
#
# Tear down:
#   ./lpi-701-703.2-break-and-fix.sh cleanup
#
# References
#   https://www.lpi.org/our-certifications/exam-701-objectives/
#   https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
#   https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment
#   https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
#   https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
#   https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
#   https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
# === SOLUTION END ===========================================================