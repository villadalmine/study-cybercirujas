#!/usr/bin/env bash
#
# ============================================================================
#  CCA · Cilium Certified Associate
#  Domain 1 — Cilium Fundamentals (exam weight: 20 %)
#  Topic 1.1 — Break & Fix lab
#
#  "Where does a Cilium datapath actually die?"
#
#  A Cilium-managed pod network is three independent layers stacked on top of
#  each other. Each layer fails with a *different* symptom, and each one is
#  repaired at a *different* level of the stack:
#
#     Layer 3 — kubelet <-> CNI       /etc/cni/net.d/*.conflist  (node filesystem)
#     Layer 2 — control plane         cilium-agent + cilium-config ConfigMap
#     Layer 1 — datapath              eBPF maps under /sys/fs/bpf/tc/globals
#
#  This script breaks exactly one of those layers, on purpose, in a way that is
#  fully reversible, and then gets out of your way. Your job is to identify the
#  layer from the symptom alone and repair it with the same commands you will
#  be given in the exam terminal.
#
#  RUN THIS ONLY ON A DISPOSABLE LAB CLUSTER (kind / minikube / k3d / a VM you
#  can throw away). It edits a node's CNI configuration, the cilium-config
#  ConfigMap and live eBPF maps. Never point it at anything you care about.
#
#  Reference material (official, cited in the solution section):
#    - CCA curriculum:  https://github.com/cncf/curriculum  (cca/README.md)
#    - Cilium docs:     https://docs.cilium.io/en/stable/
#    - Troubleshooting: https://docs.cilium.io/en/stable/operations/troubleshooting/
#    - Command ref:     https://docs.cilium.io/en/stable/cmdref/
#    - Kubernetes CNI:  https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
#
#  Usage:
#     ./cca-1.1-break-and-fix.sh setup                 # deploy the lab workload
#     ./cca-1.1-break-and-fix.sh break [--fault cni|config|bpf|random]
#     ./cca-1.1-break-and-fix.sh verify                # did you fix it?
#     ./cca-1.1-break-and-fix.sh hint [1|2|3]          # progressive hints
#     ./cca-1.1-break-and-fix.sh status                # what is broken right now
#     ./cca-1.1-break-and-fix.sh cleanup [--i-give-up] # remove lab (--i-give-up restores the fault)
#
#  Non-interactive: export CCA_LAB_YES=1 to skip the safety prompt.
# ============================================================================

set -euo pipefail

NS="cca-lab"
NODESHELL="cca-lab-nodeshell"
CANARY="cca-lab-canary"
STATE_DIR="${CCA_LAB_STATE:-${HOME}/.cca-lab/topic-1.1}"
STATE_FILE="${STATE_DIR}/fault.env"
CNI_DIR="/host/etc/cni/net.d"
CNI_BACKUP_DIR="/host/etc/cni/net.d/.cca-lab-backup"
BOGUS_CNI="00-cca-broken.conflist"
SERVER_IMAGE="${CCA_LAB_SERVER_IMAGE:-nginx:1.27-alpine}"
TOOLS_IMAGE="${CCA_LAB_TOOLS_IMAGE:-busybox:1.36}"

CILIUM_NS=""
DBG=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

log()   { printf '%s[ lab ]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s[ ok  ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%s[warn ]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail()  { printf '%s[fail ]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()   { fail "$*"; exit 1; }
rule()  { printf '%s%s%s\n' "$C_BLD" "----------------------------------------------------------------------" "$C_OFF"; }

# ---------------------------------------------------------------------------
# Preflight and safety guardrails
# ---------------------------------------------------------------------------
preflight() {
    command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
    kubectl version --request-timeout=10s >/dev/null 2>&1 \
        || die "Cannot reach the API server. Check your kubeconfig."

    # Cilium may be installed in kube-system (Helm default) or in its own namespace.
    CILIUM_NS="$(kubectl get ds --all-namespaces -l k8s-app=cilium \
                 -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
    [ -n "$CILIUM_NS" ] || die "No DaemonSet with label k8s-app=cilium found. Is Cilium installed?"

    mkdir -p "$STATE_DIR"
}

confirm_disposable_cluster() {
    local ctx nodes
    ctx="$(kubectl config current-context)"
    nodes="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"

    rule
    printf '%sTHIS SCRIPT INTENTIONALLY BREAKS THE CLUSTER NETWORK.%s\n' "$C_BLD" "$C_OFF"
    printf '  context : %s\n  nodes   : %s\n  cilium  : namespace %s\n' "$ctx" "$nodes" "$CILIUM_NS"
    rule

    [ "${CCA_LAB_YES:-0}" = "1" ] && { warn "CCA_LAB_YES=1 — skipping confirmation."; return 0; }

    case "$ctx" in
        kind-*|minikube|k3d-*|*lab*|*sandbox*|*test*) : ;;
        *) warn "Context '$ctx' does not look like a throwaway lab cluster." ;;
    esac

    local answer
    printf 'Type the context name to confirm it is disposable: '
    read -r answer
    [ "$answer" = "$ctx" ] || die "Confirmation did not match. Nothing was touched."
}

# ---------------------------------------------------------------------------
# Cilium helpers
# ---------------------------------------------------------------------------
agent_pod_on() {
    # $1 = node name -> prints the cilium agent pod name running there
    kubectl -n "$CILIUM_NS" get pods -l k8s-app=cilium \
        --field-selector "spec.nodeName=$1" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

detect_dbg() {
    # Cilium >= 1.16 ships the in-agent CLI as 'cilium-dbg'; older releases as 'cilium'.
    local pod="$1"
    if kubectl -n "$CILIUM_NS" exec "$pod" -c cilium-agent -- \
         sh -c 'command -v cilium-dbg' >/dev/null 2>&1; then
        DBG="cilium-dbg"
    else
        DBG="cilium"
    fi
}

agent_exec() {
    # $1 = pod, rest = command
    local pod="$1"; shift
    kubectl -n "$CILIUM_NS" exec "$pod" -c cilium-agent -- "$@"
}

# ---------------------------------------------------------------------------
# Node shell — a hostNetwork pod used to reach the node filesystem.
#
# hostNetwork: true is not a detail, it is the whole point: a hostNetwork pod
# needs NO CNI plugin to start, so it survives the CNI fault we are about to
# inject. Always create your escape hatch BEFORE you break the datapath.
# ---------------------------------------------------------------------------
ensure_node_shell() {
    local node="$1" current
    current="$(kubectl -n "$NS" get pod "$NODESHELL" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    if [ "$current" = "$node" ]; then
        kubectl -n "$NS" wait --for=condition=Ready "pod/$NODESHELL" --timeout=120s >/dev/null
        return 0
    fi
    [ -n "$current" ] && kubectl -n "$NS" delete pod "$NODESHELL" --ignore-not-found --wait=true >/dev/null

    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${NODESHELL}
  namespace: ${NS}
  labels:
    app: cca-lab-nodeshell
spec:
  nodeName: ${node}
  hostNetwork: true
  hostPID: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: shell
      image: ${TOOLS_IMAGE}
      command: ["sh", "-c", "sleep 86400"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: cni-conf
          mountPath: /host/etc/cni/net.d
  volumes:
    - name: cni-conf
      hostPath:
        path: /etc/cni/net.d
        type: DirectoryOrCreate
EOF
    kubectl -n "$NS" wait --for=condition=Ready "pod/$NODESHELL" --timeout=180s >/dev/null
}

node_exec() { kubectl -n "$NS" exec "$NODESHELL" -- sh -c "$1"; }

# ---------------------------------------------------------------------------
# Lab workload
#   cca-server : DaemonSet (one HTTP backend per node — guarantees a local
#                endpoint on every node, which the datapath fault needs)
#   cca-client : one pod that curls the backends
#   cca-server : ClusterIP Service in front of the DaemonSet
# ---------------------------------------------------------------------------
setup_workload() {
    log "Deploying the lab workload in namespace '${NS}' ..."
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    purpose: cca-lab
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cca-server
  namespace: ${NS}
spec:
  selector:
    matchLabels:
      app: cca-server
  template:
    metadata:
      labels:
        app: cca-server
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: web
          image: ${SERVER_IMAGE}
          ports:
            - containerPort: 80
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: cca-server
  namespace: ${NS}
spec:
  selector:
    app: cca-server
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cca-client
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cca-client
  template:
    metadata:
      labels:
        app: cca-client
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: shell
          image: ${TOOLS_IMAGE}
          command: ["sh", "-c", "sleep 86400"]
EOF
    kubectl -n "$NS" rollout status ds/cca-server --timeout=300s
    kubectl -n "$NS" rollout status deploy/cca-client --timeout=300s

    local client_node
    client_node="$(kubectl -n "$NS" get pod -l app=cca-client \
        -o jsonpath='{.items[0].spec.nodeName}')"
    ok "Workload ready. Client pod is on node '${client_node}'."

    baseline_probe || die "Baseline connectivity failed BEFORE breaking anything. Fix the cluster first."
    ok "Baseline connectivity verified — the lab starts from a healthy cluster."
}

client_pod() { kubectl -n "$NS" get pod -l app=cca-client -o jsonpath='{.items[0].metadata.name}'; }

client_curl() {
    # $1 = target (IP or DNS name). Returns 0 on HTTP success.
    local target="$1" pod
    pod="$(client_pod)"
    kubectl -n "$NS" exec "$pod" -- \
        wget -q -T 4 -O /dev/null "http://${target}/" >/dev/null 2>&1
}

baseline_probe() {
    local node srv_ip
    node="$(kubectl -n "$NS" get pod -l app=cca-client -o jsonpath='{.items[0].spec.nodeName}')"
    srv_ip="$(kubectl -n "$NS" get pod -l app=cca-server \
              --field-selector "spec.nodeName=$node" \
              -o jsonpath='{.items[0].status.podIP}')"
    client_curl "$srv_ip" && client_curl "cca-server.${NS}.svc.cluster.local"
}

# ---------------------------------------------------------------------------
# Fault 1 — kubelet <-> CNI  (node filesystem)
# ---------------------------------------------------------------------------
break_cni() {
    local node="$1" cilium_conf
    ensure_node_shell "$node"

    cilium_conf="$(node_exec "ls -1 ${CNI_DIR} 2>/dev/null | grep -i cilium | head -1" || true)"
    [ -n "$cilium_conf" ] || die "No Cilium CNI conf file found in /etc/cni/net.d on ${node}."

    node_exec "mkdir -p ${CNI_BACKUP_DIR} && mv ${CNI_DIR}/${cilium_conf} ${CNI_BACKUP_DIR}/${cilium_conf}"

    # kubelet loads the LEXICOGRAPHICALLY FIRST valid conf file in the directory,
    # so '00-' shadows anything Cilium writes even if the real file comes back.
    node_exec "cat > ${CNI_DIR}/${BOGUS_CNI} <<'JSON'
{
  \"cniVersion\": \"1.0.0\",
  \"name\": \"cca-broken\",
  \"plugins\": [
    { \"type\": \"cca-nonexistent-plugin\" }
  ]
}
JSON"

    {
        echo "FAULT=cni"
        echo "NODE=${node}"
        echo "CILIUM_CONF=${cilium_conf}"
    } > "$STATE_FILE"

    rule
    printf '%sFAULT INJECTED — layer 3: kubelet <-> CNI%s\n' "$C_BLD" "$C_OFF"
    rule
    cat <<'BRIEF'
SYMPTOM YOU WILL SEE
  * Every pod that was already running keeps working. Existing connections do
    not drop, the Service still answers. Nothing looks wrong at first glance.
  * Any NEW pod scheduled on the affected node is stuck in ContainerCreating
    forever, and `kubectl describe pod` shows a FailedCreatePodSandBox event
    mentioning a CNI plugin that does not exist.
  * `kubectl get nodes` may report the node as NotReady with
    "container runtime network not ready: cni config uninitialized" or similar.
  * The cilium agent pod on that node is Running and 1/1 Ready. It is NOT the
    culprit and its logs are clean — this is a kubelet-side failure.

WHAT YOU MUST ACHIEVE
  A newly created pod on the affected node reaches Running with an IP from the
  cluster pod CIDR, and the CNI configuration in use is the one Cilium itself
  owns and writes — not a file you hand-crafted. Hand-writing a conflist is a
  fail: the exam (and production) expects the agent to be the owner of that file.

USEFUL STARTING POINTS
  kubectl get nodes -o wide
  kubectl -n cca-lab describe pod <pending-pod> | tail -30
  kubectl -n <cilium-ns> logs ds/cilium -c cilium-agent | tail -40
BRIEF
    rule
    log "Creating a canary pod on '${node}' so the symptom is visible right now ..."
    spawn_canary "$node" || true
}

# ---------------------------------------------------------------------------
# Fault 2 — control plane  (cilium-config ConfigMap + agent)
# ---------------------------------------------------------------------------
break_config() {
    local node="$1" ipv6
    ipv6="$(kubectl -n "$CILIUM_NS" get cm cilium-config -o jsonpath='{.data.enable-ipv6}' 2>/dev/null || true)"
    [ "$ipv6" = "true" ] && die "This cluster is dual-stack; the 'config' fault needs an IPv4-only lab. Use --fault cni or --fault bpf."

    kubectl -n "$CILIUM_NS" get cm cilium-config -o yaml > "${STATE_DIR}/cilium-config.backup.yaml"
    kubectl -n "$CILIUM_NS" patch cm cilium-config --type merge \
        -p '{"data":{"enable-ipv4":"false"}}' >/dev/null

    {
        echo "FAULT=config"
        echo "NODE=${node}"
        echo "BACKUP=${STATE_DIR}/cilium-config.backup.yaml"
    } > "$STATE_FILE"

    log "Restarting the cilium DaemonSet so the new configuration takes effect ..."
    kubectl -n "$CILIUM_NS" rollout restart ds/cilium >/dev/null
    sleep 20

    rule
    printf '%sFAULT INJECTED — layer 2: Cilium control plane%s\n' "$C_BLD" "$C_OFF"
    rule
    cat <<'BRIEF'
SYMPTOM YOU WILL SEE
  * The cilium agent pods go 0/1 and enter CrashLoopBackOff on every node.
  * The agent dies during startup and writes ONE fatal line explaining exactly
    why. Read it — do not guess. Because the pod is restarting, you often need
    the previous container's logs (`--previous`).
  * Nodes flip to NotReady; new pods cannot be created anywhere; already
    running pods keep their eBPF datapath and mostly keep working, which is why
    the cluster looks "half alive".
  * `cilium status` (the cilium-cli) reports the DaemonSet as unavailable.

WHAT YOU MUST ACHIEVE
  All cilium agent pods back to Running 1/1, nodes Ready, and a brand-new pod
  able to start and reach the cca-server Service. The fix must be made in the
  place the agent actually reads its settings from — restarting pods without
  correcting the source of truth only reproduces the crash.

USEFUL STARTING POINTS
  kubectl -n <cilium-ns> get pods -l k8s-app=cilium -o wide
  kubectl -n <cilium-ns> logs ds/cilium -c cilium-agent --previous --tail=40
  kubectl -n <cilium-ns> get cm cilium-config -o yaml
BRIEF
    rule
}

# ---------------------------------------------------------------------------
# Fault 3 — datapath  (eBPF endpoints map, a.k.a. cilium_lxc)
# ---------------------------------------------------------------------------
break_bpf() {
    local node="$1" agent srv_pod srv_ip
    agent="$(agent_pod_on "$node")"
    [ -n "$agent" ] || die "No cilium agent pod found on node ${node}."
    detect_dbg "$agent"

    srv_pod="$(kubectl -n "$NS" get pod -l app=cca-server \
               --field-selector "spec.nodeName=$node" \
               -o jsonpath='{.items[0].metadata.name}')"
    srv_ip="$(kubectl -n "$NS" get pod "$srv_pod" -o jsonpath='{.status.podIP}')"
    [ -n "$srv_ip" ] || die "Could not resolve a cca-server pod IP on ${node}."

    log "Removing the endpoints-map entry for ${srv_pod} (${srv_ip}) on node ${node} ..."
    agent_exec "$agent" "$DBG" bpf endpoint delete "$srv_ip" >/dev/null

    {
        echo "FAULT=bpf"
        echo "NODE=${node}"
        echo "AGENT=${agent}"
        echo "TARGET_POD=${srv_pod}"
        echo "TARGET_IP=${srv_ip}"
        echo "DBG=${DBG}"
    } > "$STATE_FILE"

    rule
    printf '%sFAULT INJECTED — layer 1: eBPF datapath%s\n' "$C_BLD" "$C_OFF"
    rule
    cat <<BRIEF
SYMPTOM YOU WILL SEE
  * Everything is green. All pods Running, all agents 1/1, nodes Ready,
    \`cilium status\` healthy, \`${DBG:-cilium-dbg} endpoint list\` shows the
    endpoint in state ready. Kubernetes has no idea anything is wrong.
  * Yet traffic to pod ${srv_ip} (${srv_pod}, on node ${node}) is silently
    blackholed from workloads on that same node: connections hang and time out
    instead of being refused. Requests to the Service fail intermittently —
    only when load balancing picks that backend.
  * No error appears in any log, because nothing errored: a lookup in an eBPF
    map simply missed.

WHAT YOU MUST ACHIEVE
  Restore local delivery to ${srv_ip} without deleting or rescheduling the
  server pod (in production you cannot always restart the workload). Then be
  able to explain, in one sentence, WHY Kubernetes reported everything healthy.

USEFUL STARTING POINTS
  kubectl -n $CILIUM_NS exec ds/cilium -c cilium-agent -- ${DBG:-cilium-dbg} endpoint list
  kubectl -n $CILIUM_NS exec ds/cilium -c cilium-agent -- ${DBG:-cilium-dbg} bpf endpoint list
  kubectl -n $CILIUM_NS exec ds/cilium -c cilium-agent -- ${DBG:-cilium-dbg} monitor --type drop
BRIEF
    rule
}

# ---------------------------------------------------------------------------
# Canary pod — the cheapest possible "can this node still create pods?" probe
# ---------------------------------------------------------------------------
spawn_canary() {
    local node="$1"
    kubectl -n "$NS" delete pod "$CANARY" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${CANARY}
  namespace: ${NS}
  labels:
    app: cca-lab-canary
spec:
  nodeName: ${node}
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: shell
      image: ${TOOLS_IMAGE}
      command: ["sh", "-c", "sleep 3600"]
EOF
    kubectl -n "$NS" wait --for=condition=Ready "pod/$CANARY" --timeout=60s >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify() {
    [ -f "$STATE_FILE" ] || die "No active fault. Run '$0 break' first."
    # shellcheck disable=SC1090
    . "$STATE_FILE"

    local rc=0
    rule
    log "Verifying repair of fault '${FAULT}' ..."

    case "$FAULT" in
        cni)
            local leftover
            leftover="$(node_exec "ls -1 ${CNI_DIR}/${BOGUS_CNI} 2>/dev/null" || true)"
            if [ -n "$leftover" ]; then
                fail "The bogus CNI conflist is still present on ${NODE}."
                rc=1
            else
                ok "No shadowing conflist left in /etc/cni/net.d."
            fi

            local owned
            owned="$(node_exec "ls -1 ${CNI_DIR} 2>/dev/null | grep -i cilium | head -1" || true)"
            if [ -z "$owned" ]; then
                fail "No Cilium CNI configuration present on ${NODE}."
                rc=1
            else
                ok "Cilium CNI configuration present: ${owned}"
            fi

            log "Scheduling a fresh canary pod on ${NODE} ..."
            if spawn_canary "$NODE"; then
                ok "Canary pod Running with IP $(kubectl -n "$NS" get pod "$CANARY" -o jsonpath='{.status.podIP}')"
            else
                fail "Canary pod did not become Ready — the node still cannot create sandboxes."
                kubectl -n "$NS" describe pod "$CANARY" 2>/dev/null | tail -12 || true
                rc=1
            fi
            ;;
        config)
            local ready desired
            ready="$(kubectl -n "$CILIUM_NS" get ds cilium -o jsonpath='{.status.numberReady}')"
            desired="$(kubectl -n "$CILIUM_NS" get ds cilium -o jsonpath='{.status.desiredNumberScheduled}')"
            if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
                ok "cilium DaemonSet ready: ${ready}/${desired}"
            else
                fail "cilium DaemonSet not ready: ${ready}/${desired}"
                rc=1
            fi

            local v4
            v4="$(kubectl -n "$CILIUM_NS" get cm cilium-config -o jsonpath='{.data.enable-ipv4}')"
            if [ "$v4" = "true" ]; then
                ok "cilium-config: enable-ipv4=true"
            else
                fail "cilium-config still holds enable-ipv4=${v4} — the source of truth is not fixed."
                rc=1
            fi

            if spawn_canary "$NODE"; then
                ok "A new pod can be created again."
            else
                fail "New pods still cannot start."
                rc=1
            fi
            ;;
        bpf)
            local agent
            agent="$(agent_pod_on "$NODE")"
            [ -n "$agent" ] || { fail "No cilium agent on ${NODE}."; rc=1; }
            if [ -n "${agent:-}" ] && agent_exec "$agent" "${DBG:-cilium-dbg}" bpf endpoint list \
                 | grep -q "^${TARGET_IP}[[:space:]]"; then
                ok "Endpoints map contains ${TARGET_IP} again."
            else
                fail "Endpoints map still has no entry for ${TARGET_IP}."
                rc=1
            fi

            local still_there
            still_there="$(kubectl -n "$NS" get pod "$TARGET_POD" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
            if [ "$still_there" = "$TARGET_IP" ]; then
                ok "Target pod ${TARGET_POD} was repaired in place (not recreated)."
            else
                warn "Target pod was recreated. Connectivity is back, but the in-place fix is the one that matters."
            fi

            local i pass=0
            for i in 1 2 3; do
                client_curl "$TARGET_IP" && pass=$((pass+1))
            done
            if [ "$pass" -eq 3 ]; then
                ok "Pod-to-pod connectivity to ${TARGET_IP}: 3/3."
            else
                fail "Pod-to-pod connectivity to ${TARGET_IP}: ${pass}/3."
                rc=1
            fi
            ;;
    esac

    if client_curl "cca-server.${NS}.svc.cluster.local"; then
        ok "Service cca-server.${NS}.svc.cluster.local reachable from the client pod."
    else
        fail "Service cca-server.${NS}.svc.cluster.local is NOT reachable."
        rc=1
    fi

    rule
    if [ "$rc" -eq 0 ]; then
        printf '%sPASS — the datapath is healthy again.%s\n' "$C_GRN$C_BLD" "$C_OFF"
        printf 'Now read the SOLUTION comment block at the bottom of this script and\n'
        printf 'compare it with the path you took. Then: %s cleanup\n' "$0"
        rm -f "$STATE_FILE"
    else
        printf '%sNOT FIXED YET — keep going. Try: %s hint 1%s\n' "$C_RED$C_BLD" "$0" "$C_OFF"
    fi
    rule
    return "$rc"
}

# ---------------------------------------------------------------------------
# Hints
# ---------------------------------------------------------------------------
hint() {
    [ -f "$STATE_FILE" ] || die "No active fault."
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    local n="${1:-1}"

    case "${FAULT}:${n}" in
        cni:1) cat <<'H'
The cilium agent is healthy, so stop reading its logs. The component that
failed is the one that ASKS for an IP, not the one that gives it.
Look at the Events of the pending pod: `kubectl -n cca-lab describe pod ...`.
H
        ;;
        cni:2) cat <<'H'
kubelet reads CNI configurations from /etc/cni/net.d and uses the
lexicographically first valid file it finds. Two questions:
  1. What files are in that directory on the affected node?
  2. Which one is kubelet actually picking?
You reach the node filesystem through the hostNetwork pod 'cca-lab-nodeshell'
that is already running there.
H
        ;;
        cni:3) cat <<'H'
Deleting the bad file is only half of it. The Cilium conflist must come back,
and the component that writes it is the agent itself, at startup
(write-cni-conf-when-ready). Removing the intruder and then restarting the
DaemonSet gets you a file written by Cilium, which is what the grader checks.
H
        ;;
        config:1) cat <<'H'
CrashLoopBackOff means the process starts and exits. Get the log of the
container that already died, not the one starting now:
  kubectl -n <cilium-ns> logs ds/cilium -c cilium-agent --previous --tail=40
H
        ;;
        config:2) cat <<'H'
The fatal line names the setting that is inconsistent. Cilium agents read
their settings from the 'cilium-config' ConfigMap, mounted as flags/env into
the pod. Compare what the agent complains about against:
  kubectl -n <cilium-ns> get cm cilium-config -o yaml
H
        ;;
        config:3) cat <<'H'
A ConfigMap change does not reach a running DaemonSet by itself. After fixing
the key you must roll the agents:
  kubectl -n <cilium-ns> rollout restart ds/cilium
  kubectl -n <cilium-ns> rollout status  ds/cilium
H
        ;;
        bpf:1) cat <<'H'
Kubernetes only knows what the kubelet and the API server know. Cilium's
forwarding decisions live in eBPF maps, and nothing in `kubectl` reads them.
Compare the agent's own view of its endpoints with the map that the datapath
actually uses:
  cilium-dbg endpoint list        # agent state (control plane)
  cilium-dbg bpf endpoint list    # eBPF map cilium_lxc (datapath)
H
        ;;
        bpf:2) cat <<'H'
One IP is present in the first list and missing from the second. That is the
definition of a blackhole: the packet arrives, the map lookup misses, and the
program has nowhere to deliver it. `cilium-dbg monitor --type drop` on that
node while you curl is the confirmation.
H
        ;;
        bpf:3) cat <<'H'
Do not delete the pod. The agent reconciles its endpoints into the eBPF maps
on startup and on endpoint regeneration; the Kubernetes API is the source of
truth, the maps are derived state. Restarting the agent on that ONE node
rebuilds them without touching the workload:
  kubectl -n <cilium-ns> delete pod <cilium-agent-pod-on-that-node>
H
        ;;
        *) warn "No hint ${n} for fault ${FAULT}. Hints available: 1, 2, 3." ;;
    esac
}

# ---------------------------------------------------------------------------
# Status / cleanup
# ---------------------------------------------------------------------------
status() {
    rule
    kubectl get nodes -o wide
    rule
    kubectl -n "$CILIUM_NS" get pods -l k8s-app=cilium -o wide
    rule
    kubectl -n "$NS" get pods -o wide 2>/dev/null || true
    rule
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        printf 'Active fault: %s%s%s on node %s\n' "$C_BLD" "$FAULT" "$C_OFF" "$NODE"
    else
        printf 'No active fault recorded.\n'
    fi
    rule
}

restore_fault() {
    [ -f "$STATE_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    warn "Restoring fault '${FAULT}' automatically (you asked to give up)."
    case "$FAULT" in
        cni)
            ensure_node_shell "$NODE"
            node_exec "rm -f ${CNI_DIR}/${BOGUS_CNI}; [ -f ${CNI_BACKUP_DIR}/${CILIUM_CONF} ] && mv ${CNI_BACKUP_DIR}/${CILIUM_CONF} ${CNI_DIR}/${CILIUM_CONF}; rmdir ${CNI_BACKUP_DIR} 2>/dev/null; true"
            kubectl -n "$CILIUM_NS" rollout restart ds/cilium >/dev/null
            kubectl -n "$CILIUM_NS" rollout status ds/cilium --timeout=300s
            ;;
        config)
            kubectl -n "$CILIUM_NS" patch cm cilium-config --type merge \
                -p '{"data":{"enable-ipv4":"true"}}' >/dev/null
            kubectl -n "$CILIUM_NS" rollout restart ds/cilium >/dev/null
            kubectl -n "$CILIUM_NS" rollout status ds/cilium --timeout=300s
            ;;
        bpf)
            local agent
            agent="$(agent_pod_on "$NODE")"
            [ -n "$agent" ] && kubectl -n "$CILIUM_NS" delete pod "$agent" >/dev/null
            kubectl -n "$CILIUM_NS" rollout status ds/cilium --timeout=300s
            ;;
    esac
    rm -f "$STATE_FILE"
    ok "Fault restored."
}

cleanup() {
    [ "${1:-}" = "--i-give-up" ] && restore_fault
    log "Deleting namespace '${NS}' ..."
    kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null
    ok "Lab removed. State kept in ${STATE_DIR} for reference."
}

pick_node() {
    # Prefer the node where the client pod runs: same-node faults are the ones
    # whose symptom the student can reproduce with a single curl.
    local n
    n="$(kubectl -n "$NS" get pod -l app=cca-client -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
    [ -n "$n" ] || n="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
    printf '%s' "$n"
}

do_break() {
    local fault="${1:-random}" node
    [ "$fault" = "random" ] && fault="$(printf 'cni\nconfig\nbpf\n' | sed -n "$(( (RANDOM % 3) + 1 ))p")"

    kubectl get ns "$NS" >/dev/null 2>&1 || setup_workload
    node="$(pick_node)"
    [ -f "$STATE_FILE" ] && die "A fault is already active. Fix it, or run '$0 cleanup --i-give-up'."

    case "$fault" in
        cni)    break_cni    "$node" ;;
        config) break_config "$node" ;;
        bpf)    break_bpf    "$node" ;;
        *)      die "Unknown fault '${fault}'. Use: cni | config | bpf | random" ;;
    esac

    printf '\nWhen you believe it is fixed:  %s verify\n' "$0"
    printf 'Stuck?                         %s hint 1\n\n' "$0"
}

usage() {
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        setup)   preflight; confirm_disposable_cluster; setup_workload ;;
        break)
            preflight; confirm_disposable_cluster
            local f="random"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --fault) f="${2:-random}"; shift 2 ;;
                    *) die "Unknown flag '$1'." ;;
                esac
            done
            do_break "$f"
            ;;
        verify)  preflight; verify ;;
        hint)    preflight; hint "${1:-1}" ;;
        status)  preflight; status ;;
        cleanup) preflight; cleanup "${1:-}" ;;
        help|-h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"


# ==========================================================================
# ==========================================================================
#
#   S O L U T I O N   —   do not read until you have tried
#
#   Everything below is a comment. Each fault is solved end to end, with the
#   real commands and the output you should expect to see.
#
# ==========================================================================
# ==========================================================================
#
# --------------------------------------------------------------------------
# FAULT 1 — "cni"  ·  kubelet cannot call the CNI plugin
# --------------------------------------------------------------------------
#
# STEP 1 — Read the symptom precisely. Old pods work, new pods do not.
#
#   $ kubectl -n cca-lab get pods -o wide
#   NAME                          READY   STATUS              RESTARTS   AGE
#   cca-client-6d9f7c9c8b-2xk4q   1/1     Running             0          9m
#   cca-lab-canary                0/1     ContainerCreating   0          40s
#   cca-server-r7ttp              1/1     Running             0          9m
#
#   Anything already running kept its veth pair and its eBPF programs. Only pod
#   *creation* is failing. That excludes the whole datapath and points at the
#   sandbox-creation path: kubelet -> container runtime -> CNI.
#
# STEP 2 — Get the actual error from the pod's Events, not from a log file.
#
#   $ kubectl -n cca-lab describe pod cca-lab-canary | tail -8
#   Events:
#     Type     Reason                  Age   From     Message
#     ----     ------                  ----  ----     -------
#     Warning  FailedCreatePodSandBox  12s   kubelet  Failed to create pod sandbox:
#       rpc error: code = Unknown desc = failed to setup network for sandbox
#       "…": plugin type="cca-nonexistent-plugin" failed (add): failed to find
#       plugin "cca-nonexistent-plugin" in path [/opt/cni/bin]
#
#   The string "plugin type=..." comes from libcni: kubelet parsed a CNI
#   configuration that references a binary that is not installed. So the
#   configuration is wrong, not Cilium.
#
# STEP 3 — Confirm the agent is innocent before touching it.
#
#   $ kubectl -n kube-system get pods -l k8s-app=cilium -o wide
#   NAME           READY   STATUS    RESTARTS   AGE   NODE
#   cilium-8l2vq   1/1     Running   0          22m   kind-worker
#
#   $ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
#   OK
#
# STEP 4 — Inspect /etc/cni/net.d on the affected node. kubelet loads the
#          lexicographically FIRST valid file in that directory
#          (https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/).
#
#   $ kubectl -n cca-lab exec cca-lab-nodeshell -- ls -la /host/etc/cni/net.d
#   drwxr-xr-x    .cca-lab-backup
#   -rw-r--r--    00-cca-broken.conflist      <-- shadows everything else
#
#   The Cilium conflist is gone and an intruder sorts first. Both problems have
#   to be solved: remove the intruder AND get Cilium's file back.
#
# STEP 5 — Remove the shadowing file.
#
#   $ kubectl -n cca-lab exec cca-lab-nodeshell -- rm -f /host/etc/cni/net.d/00-cca-broken.conflist
#
# STEP 6 — Let Cilium write its own configuration back. Do NOT hand-write a
#          conflist. The agent's install-cni-binaries / cni-install path writes
#          05-cilium.conflist when it is ready to serve
#          (option write-cni-conf-when-ready; see
#           https://docs.cilium.io/en/stable/network/kubernetes/configuration/).
#
#   $ kubectl -n kube-system rollout restart ds/cilium
#   $ kubectl -n kube-system rollout status  ds/cilium
#   daemon set "cilium" successfully rolled out
#
#   $ kubectl -n cca-lab exec cca-lab-nodeshell -- ls -1 /host/etc/cni/net.d
#   05-cilium.conflist
#
# STEP 7 — Prove it. A pending pod does not retry instantly; delete and recreate.
#
#   $ kubectl -n cca-lab delete pod cca-lab-canary
#   $ ./cca-1.1-break-and-fix.sh verify
#   [ ok  ] Canary pod Running with IP 10.244.1.219
#
# WHY IT MATTERS: Cilium owns the CNI configuration file, and a stale or
# shadowing file in /etc/cni/net.d is one of the most common causes of
# "node NotReady: cni config uninitialized" after migrating from another CNI.
# Uninstalling the previous plugin's conflist is a documented migration step:
# https://docs.cilium.io/en/stable/installation/k8s-install-migration/
#
#
# --------------------------------------------------------------------------
# FAULT 2 — "config"  ·  the agent refuses to start
# --------------------------------------------------------------------------
#
# STEP 1 — See the shape of the failure.
#
#   $ kubectl -n kube-system get pods -l k8s-app=cilium
#   NAME           READY   STATUS             RESTARTS      AGE
#   cilium-8l2vq   0/1     CrashLoopBackOff   4 (31s ago)   3m
#
#   CrashLoopBackOff = the process starts and exits. Configuration or
#   environment, almost never networking.
#
# STEP 2 — Read the previous container's log. This is the single most important
#          habit for this exam objective.
#
#   $ kubectl -n kube-system logs ds/cilium -c cilium-agent --previous --tail=20
#   level=info  msg="Cilium 1.16.x …"
#   level=fatal msg="Either IPv4 or IPv6 addressing must be enabled"
#
#   The agent told you exactly what is wrong. Both address families are
#   disabled, which is not a valid configuration.
#
# STEP 3 — Find where that setting comes from. Agent flags are rendered from
#          the cilium-config ConfigMap (https://docs.cilium.io/en/stable/cmdref/).
#
#   $ kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'enable-ipv[46]'
#     enable-ipv4: "false"      <-- injected fault
#     enable-ipv6: "false"
#
# STEP 4 — Fix the source of truth, not the symptom.
#
#   $ kubectl -n kube-system patch cm cilium-config --type merge \
#       -p '{"data":{"enable-ipv4":"true"}}'
#   configmap/cilium-config patched
#
#   In a Helm-managed installation the durable fix is
#   `cilium upgrade --reuse-values --set ipv4.enabled=true` or the equivalent
#   `helm upgrade`, because the next Helm run would otherwise overwrite the
#   ConfigMap back to the broken value. Editing the ConfigMap directly is the
#   fast path for the exam; knowing that Helm is upstream of it is the
#   production answer.
#
# STEP 5 — A ConfigMap change is NOT hot-reloaded by the agents. Roll them.
#
#   $ kubectl -n kube-system rollout restart ds/cilium
#   $ kubectl -n kube-system rollout status  ds/cilium --timeout=300s
#   daemon set "cilium" successfully rolled out
#
# STEP 6 — Validate at the two levels that matter.
#
#   $ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
#   OK
#   $ cilium status --wait            # cilium-cli, if installed
#   $ ./cca-1.1-break-and-fix.sh verify
#
# WHY IT MATTERS: the agent is the only writer of the datapath. When it is
# down, existing pods keep forwarding (the eBPF programs are already attached
# and survive the agent), but nothing new can be programmed: no new endpoints,
# no policy updates, no service updates. "Data plane keeps running while the
# control plane is dead" is a defining property of eBPF-based networking and a
# favourite exam question.
# See https://docs.cilium.io/en/stable/operations/troubleshooting/
#
#
# --------------------------------------------------------------------------
# FAULT 3 — "bpf"  ·  a missing eBPF map entry, with everything green
# --------------------------------------------------------------------------
#
# STEP 1 — Reproduce the symptom and note its exact flavour: it HANGS, it is not
#          refused. Timeouts mean packets are being dropped or dead-ended;
#          "connection refused" would mean they arrived and no one listened.
#
#   $ kubectl -n cca-lab exec deploy/cca-client -- wget -T 4 -O- http://10.244.1.83/
#   wget: download timed out
#   command terminated with exit code 1
#
# STEP 2 — Confirm Kubernetes thinks everything is fine, then stop trusting it.
#
#   $ kubectl -n cca-lab get pods -o wide       # all Running, all Ready
#   $ kubectl -n kube-system get pods -l k8s-app=cilium   # 1/1 Running
#
# STEP 3 — Compare the agent's view of the world with the datapath's view.
#          These are two different databases, and the bug is in the second one.
#
#   $ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list
#   ENDPOINT   IDENTITY   IPv4           STATUS
#   1204       12583      10.244.1.83    ready       <-- control plane: present
#
#   $ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf endpoint list
#   IP ADDRESS        LOCAL ENDPOINT INFO
#   10.244.1.117      id=1730 …
#   10.244.1.1        (localhost)
#   # 10.244.1.83 is MISSING                          <-- datapath: absent
#
#   That asymmetry is the whole diagnosis. `cilium-dbg bpf endpoint list` dumps
#   the cilium_lxc map, which the to-container / from-container programs use to
#   resolve a destination pod IP into an interface and a security identity. No
#   entry, no delivery, no error.
#   https://docs.cilium.io/en/stable/cmdref/cilium-dbg_bpf_endpoint_list/
#
# STEP 4 — Watch the drop live while you retry, on the affected node:
#
#   $ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg monitor --type drop
#   xx drop (Unknown L3 target address) flow 0x0 to endpoint 0, ... 10.244.1.117 -> 10.244.1.83
#
# STEP 5 — Repair by reconciliation, NOT by recreating the workload. The
#          Kubernetes API is the source of truth; the maps are derived state,
#          and the agent rebuilds them on startup from its endpoint state
#          directory (/var/run/cilium/state) plus the API.
#
#   $ NODE=$(kubectl -n cca-lab get pod -l app=cca-client -o jsonpath='{.items[0].spec.nodeName}')
#   $ POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
#           --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
#   $ kubectl -n kube-system delete pod "$POD"
#   $ kubectl -n kube-system rollout status ds/cilium --timeout=300s
#
#   An alternative, narrower fix is to force the endpoint to regenerate its
#   datapath (`cilium-dbg endpoint config <id> DebugPolicy=true` toggles cause a
#   regeneration); restarting the single agent on that node is the version-stable
#   answer and does not touch the workload's network namespace.
#
# STEP 6 — Verify the map, then the traffic — in that order.
#
#   $ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf endpoint list | grep 10.244.1.83
#   10.244.1.83   id=1204 sec_id=12583 flags=0x0000 ifindex=27 …
#   $ kubectl -n cca-lab exec deploy/cca-client -- wget -qO- http://10.244.1.83/ | head -1
#   <!DOCTYPE html>
#
# WHY IT MATTERS: this is the failure class that `kubectl` structurally cannot
# see. Pod status, readiness probes over the loopback, node conditions and even
# `cilium status` can all be green while a map entry is missing. The only
# instruments that reach that layer are `cilium-dbg bpf …`, `cilium-dbg monitor`
# and Hubble. Learn to jump straight from "it times out but everything is
# Ready" to a map dump — that reflex is worth more than any single command.
#
#
# --------------------------------------------------------------------------
# THE ONE-PARAGRAPH TAKEAWAY
# --------------------------------------------------------------------------
# Cilium fails at three distinct layers and each one has its own fingerprint:
#   * only NEW pods fail            -> kubelet/CNI, look in /etc/cni/net.d
#   * agents CrashLoopBackOff       -> configuration, read `logs --previous`
#   * everything green but timeouts -> eBPF maps, dump them with cilium-dbg
# Match the symptom to the layer before you type a single fix command, and
# always repair at the source of truth (CNI conf written by the agent, the
# cilium-config ConfigMap / Helm values, the agent's reconciliation) rather
# than patching the derived state by hand.
#
# Sources:
#   https://github.com/cncf/curriculum                (CCA curriculum, domain 1)
#   https://docs.cilium.io/en/stable/operations/troubleshooting/
#   https://docs.cilium.io/en/stable/network/kubernetes/configuration/
#   https://docs.cilium.io/en/stable/cmdref/
#   https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
# ==========================================================================