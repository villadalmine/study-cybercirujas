#!/usr/bin/env bash
# =============================================================================
#  CCA — Cilium Certified Associate
#  Domain 4: Observability  ·  Topic 4.1: Observability with Cilium (weight 20%)
#
#  break-fix-4.1-observability.sh — controlled fault injection lab
#
#  WHAT THIS IS
#    A disposable-lab exercise. The script breaks ONE part of the Hubble
#    observability pipeline in a way that is reversible, tells you the symptom
#    you are about to see, and then verifies your repair. It never touches
#    workload data and never leaves the cluster.
#
#  THE PIPELINE YOU ARE LEARNING TO DEBUG
#
#    eBPF datapath (per node)
#         │  perf ring buffer / events
#         ▼
#    cilium-agent  ──► Hubble observer library
#         │              ├── unix:///var/run/cilium/hubble.sock  (node-local CLI)
#         │              ├── :4244  gRPC Peer/Observer service   (mTLS by default)
#         │              └── :9965  Prometheus metrics endpoint
#         ▼
#    Service hubble-peer:443 ──► targetPort 4244  (peer discovery, one entry/node)
#         ▼
#    hubble-relay (Deployment)  aggregates every node into one Observer API
#         │  :4245
#         ▼
#    hubble CLI  /  hubble-ui  /  Prometheus + Grafana
#
#    Every fault below cuts exactly one of those arrows. Your job is to find
#    which one, using only observability tooling — not by reading this script.
#
#  REQUIREMENTS
#    - A DISPOSABLE single-node or multi-node lab cluster (kind / k3d / minikube)
#      with Cilium installed and Hubble + hubble-relay enabled:
#        cilium install --set hubble.relay.enabled=true --set hubble.ui.enabled=true
#      or:  helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
#             --set hubble.enabled=true --set hubble.relay.enabled=true \
#             --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2}"
#    - kubectl, and the hubble CLI in $PATH
#      (https://github.com/cilium/hubble/releases)
#    - Cluster-admin on that lab cluster. DO NOT RUN THIS ANYWHERE ELSE.
#
#  USAGE
#    ./break-fix-4.1-observability.sh setup            # deploy demo app + traffic
#    ./break-fix-4.1-observability.sh break [1..5|random]
#    ./break-fix-4.1-observability.sh hint             # progressive hints
#    ./break-fix-4.1-observability.sh verify           # grade your fix
#    ./break-fix-4.1-observability.sh restore          # give up / reset
#    ./break-fix-4.1-observability.sh cleanup          # remove demo namespace
#
#  SOURCES
#    CCA curriculum ..... https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
#    Hubble ............. https://docs.cilium.io/en/stable/observability/hubble/
#    Hubble internals ... https://docs.cilium.io/en/stable/observability/hubble/setup/
#    Hubble metrics ..... https://docs.cilium.io/en/stable/observability/metrics/
#    L7 visibility ...... https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples
#    Agent config keys .. https://docs.cilium.io/en/stable/cmdref/cilium-agent/
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------- config
NS_SYS="kube-system"
NS_LAB="cca-obs"
STATE_DIR="${CCA_STATE_DIR:-/var/tmp/cca-4.1-breakfix}"
FAULT_FILE="$STATE_DIR/active_fault"
RELAY_PORT="${CCA_RELAY_PORT:-4245}"
export HUBBLE_SERVER="localhost:${RELAY_PORT}"

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
info() { printf '%s[i]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$C_BLD" "-------------------------------------------------------------------------------" "$C_OFF"; }

# ----------------------------------------------------------------------------- guards
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

assert_lab_cluster() {
  local ctx nodes
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [ -n "$ctx" ] || die "no current kubectl context"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$nodes" -gt 0 ] || die "cannot reach the cluster"

  if [ "${CCA_LAB_FORCE:-0}" != "1" ]; then
    case "$ctx" in
      kind-*|k3d-*|minikube*|*lab*|*cca*|*sandbox*) : ;;
      *) die "context '$ctx' does not look like a disposable lab cluster.
    Refusing to inject faults. Re-run with CCA_LAB_FORCE=1 only if you are
    certain this cluster is throwaway." ;;
    esac
    if [ "$nodes" -gt 6 ]; then
      die "context '$ctx' has $nodes nodes — too big for a scratch lab. Aborting."
    fi
  fi
  info "cluster: ${C_BLD}${ctx}${C_OFF} (${nodes} node(s))"
}

assert_cilium_hubble() {
  kubectl -n "$NS_SYS" get ds cilium >/dev/null 2>&1 \
    || die "no cilium DaemonSet in $NS_SYS — install Cilium first"
  kubectl -n "$NS_SYS" get deploy hubble-relay >/dev/null 2>&1 \
    || die "no hubble-relay Deployment — enable it: cilium hubble enable"
}

confirm() {
  local answer
  printf '%sType "break" to inject the fault (anything else aborts): %s' "$C_YEL" "$C_OFF"
  read -r answer
  [ "$answer" = "break" ] || die "aborted by user"
}

# ----------------------------------------------------------------------------- helpers
node_count()   { kubectl get nodes --no-headers | wc -l | tr -d ' '; }
first_node_ip(){ kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'; }

# Run any hubble subcommand against hubble-relay through an ephemeral port-forward.
# If relay is unreachable this fails loudly — which is exactly the signal in
# several of the faults below.
hubble_q() {
  local pf_pid rc=0
  kubectl -n "$NS_SYS" port-forward svc/hubble-relay "${RELAY_PORT}:80" >/dev/null 2>&1 &
  pf_pid=$!
  sleep 2
  set +e
  hubble "$@"
  rc=$?
  set -e
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
  return "$rc"
}

# `cilium status` was renamed `cilium-dbg status` inside the agent in 1.15+.
agent_status() {
  kubectl -n "$NS_SYS" exec ds/cilium -c cilium-agent -- \
    sh -c 'cilium-dbg status 2>/dev/null || cilium status' 2>/dev/null
}

cm_get() { kubectl -n "$NS_SYS" get cm cilium-config -o jsonpath="{.data.$1}" 2>/dev/null || true; }

restart_agents() {
  info "restarting cilium agents (config changes are read at agent start)"
  kubectl -n "$NS_SYS" rollout restart ds/cilium >/dev/null
  kubectl -n "$NS_SYS" rollout status ds/cilium --timeout=180s >/dev/null
}

restart_relay() {
  kubectl -n "$NS_SYS" rollout restart deploy/hubble-relay >/dev/null
  kubectl -n "$NS_SYS" rollout status deploy/hubble-relay --timeout=180s >/dev/null || true
}

save_state() { mkdir -p "$STATE_DIR"; }

active_fault() { [ -f "$FAULT_FILE" ] && cat "$FAULT_FILE" || echo ""; }

# ----------------------------------------------------------------------------- demo app
# A tiny, self-contained traffic generator so Hubble always has flows to show.
# backend: nginx on :80  ·  client: curls it every 2s  ·  plus periodic DNS.
deploy_demo() {
  info "deploying demo workload in namespace ${NS_LAB}"
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: cca-obs
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: cca-obs
spec:
  replicas: 1
  selector:
    matchLabels: {app: backend}
  template:
    metadata:
      labels: {app: backend}
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests: {cpu: 10m, memory: 16Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: cca-obs
spec:
  selector: {app: backend}
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: cca-obs
spec:
  replicas: 1
  selector:
    matchLabels: {app: client}
  template:
    metadata:
      labels: {app: client}
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.8.0
        command: ["/bin/sh","-c"]
        args:
        - |
          while true; do
            curl -sS -o /dev/null http://backend.cca-obs.svc.cluster.local/ || true
            curl -sS -o /dev/null http://backend.cca-obs.svc.cluster.local/healthz || true
            sleep 2
          done
        resources:
          requests: {cpu: 10m, memory: 16Mi}
YAML
  kubectl -n "$NS_LAB" rollout status deploy/backend --timeout=120s >/dev/null
  kubectl -n "$NS_LAB" rollout status deploy/client  --timeout=120s >/dev/null
  ok "demo workload ready — steady HTTP traffic client → backend"
}

apply_l7_policy() {
  # L7 (HTTP) visibility in Hubble is a side effect of an L7 policy: the flow is
  # redirected to the per-node Envoy proxy, which is what emits http-request /
  # http-response events. An L3/L4-only policy gives you NO L7 flows.
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: obs-l7-visibility
  namespace: cca-obs
spec:
  description: "Allow client -> backend on 80/TCP with L7 HTTP parsing (visibility)"
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: client
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - {}
YAML
}

apply_l4_only_policy() {
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: obs-l7-visibility
  namespace: cca-obs
spec:
  description: "L3/L4 only — traffic still flows, but Envoy is bypassed"
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: client
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
YAML
}

# =============================================================================
#  FAULTS
# =============================================================================

# --- Fault 1: Hubble disabled at the agent -----------------------------------
break_1() {
  save_state
  kubectl -n "$NS_SYS" get cm cilium-config -o yaml > "$STATE_DIR/cilium-config.bak.yaml"
  kubectl -n "$NS_SYS" patch cm cilium-config --type merge \
    -p '{"data":{"enable-hubble":"false"}}' >/dev/null
  restart_agents
  restart_relay
  echo 1 > "$FAULT_FILE"
  briefing_1
}
briefing_1() {
  rule
  say "${C_BLD}SYMPTOM${C_OFF}"
  say "  \$ hubble observe --namespace cca-obs"
  say "  (hangs, then) no flows — the stream stays empty forever"
  say ""
  say "  \$ hubble status"
  say "  Healthcheck (via localhost:4245): Ok"
  say "  Current/Max Flows: 0/0 (0.00%)"
  say "  Flows/s: 0.00"
  say "  Connected Nodes: 0/$(node_count)      <-- relay is up, but sees nobody"
  say ""
  say "  hubble-ui loads and shows an empty service map. No errors in the UI."
  say ""
  say "${C_BLD}YOUR GOAL${C_OFF}"
  say "  Get 'Connected Nodes: $(node_count)/$(node_count)' back and see live flows"
  say "  for namespace ${NS_LAB} through hubble-relay."
  say ""
  say "${C_BLD}WHERE TO LOOK${C_OFF}"
  say "  Relay says the nodes are gone — so ask a node what it thinks it is doing:"
  say "  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble"
  rule
}
verify_1() {
  local rc=0 val
  val="$(cm_get 'enable-hubble')"
  if [ "$val" = "true" ]; then ok "cilium-config: enable-hubble=true"
  else warn "cilium-config: enable-hubble='$val' (expected true)"; rc=1; fi

  if agent_status | grep -qiE '^Hubble:[[:space:]]+Ok'; then
    ok "agent reports Hubble: Ok"
  else
    warn "agent does not report 'Hubble: Ok' — did you restart the DaemonSet?"; rc=1
  fi
  verify_flows || rc=1
  return $rc
}

# --- Fault 2: hubble-peer Service points at the wrong target port ------------
break_2() {
  save_state
  kubectl -n "$NS_SYS" get svc hubble-peer -o yaml > "$STATE_DIR/hubble-peer.bak.yaml"
  local pname
  pname="$(kubectl -n "$NS_SYS" get svc hubble-peer -o jsonpath='{.spec.ports[0].name}')"
  kubectl -n "$NS_SYS" patch svc hubble-peer --type merge \
    -p "{\"spec\":{\"ports\":[{\"name\":\"${pname}\",\"port\":443,\"protocol\":\"TCP\",\"targetPort\":4299}]}}" >/dev/null
  restart_relay
  echo 2 > "$FAULT_FILE"
  briefing_2
}
briefing_2() {
  rule
  say "${C_BLD}SYMPTOM${C_OFF}"
  say "  \$ hubble status"
  say "  Healthcheck (via localhost:4245): Ok"
  say "  Connected Nodes: 0/$(node_count)"
  say ""
  say "  \$ kubectl -n kube-system logs deploy/hubble-relay | tail"
  say "  level=warning msg=\"Failed to create gRPC client\" ..."
  say "    error=\"context deadline exceeded\" ..."
  say "    target=\"...:4244\" subsys=hubble-relay"
  say ""
  say "  BUT: the agent itself is healthy —"
  say "  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble"
  say "  Hubble:  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 27.31"
  say ""
  say "${C_BLD}YOUR GOAL${C_OFF}"
  say "  The agents are producing flows and relay is running: repair the path"
  say "  between them until 'Connected Nodes: $(node_count)/$(node_count)'."
  say ""
  say "${C_BLD}WHERE TO LOOK${C_OFF}"
  say "  Relay discovers agents through one Kubernetes Service. Which one, and"
  say "  which container port must it reach? Compare the Service with the port"
  say "  the agent actually listens on (hubble-listen-address in cilium-config)."
  rule
}
verify_2() {
  local rc=0 tp
  tp="$(kubectl -n "$NS_SYS" get svc hubble-peer -o jsonpath='{.spec.ports[0].targetPort}')"
  if [ "$tp" = "4244" ]; then ok "hubble-peer targetPort=4244"
  else warn "hubble-peer targetPort='$tp' (agents listen on 4244)"; rc=1; fi
  verify_flows || rc=1
  return $rc
}

# --- Fault 3: hubble-relay pointed at a non-existent peer service ------------
break_3() {
  save_state
  kubectl -n "$NS_SYS" get cm hubble-relay-config -o yaml > "$STATE_DIR/hubble-relay-config.bak.yaml"
  kubectl -n "$NS_SYS" get cm hubble-relay-config -o jsonpath='{.data.config\.yaml}' \
    > "$STATE_DIR/relay-config.yaml"
  sed 's#^\([[:space:]]*peer-service:[[:space:]]*\).*#\1hubble-peer.cilium-system.svc.cluster.local:443#' \
    "$STATE_DIR/relay-config.yaml" | sed 's/^/    /' > "$STATE_DIR/relay-config.indented"
  {
    echo "data:"
    echo "  config.yaml: |"
    cat "$STATE_DIR/relay-config.indented"
  } > "$STATE_DIR/relay-patch.yaml"
  kubectl -n "$NS_SYS" patch cm hubble-relay-config --patch-file "$STATE_DIR/relay-patch.yaml" >/dev/null
  restart_relay
  echo 3 > "$FAULT_FILE"
  briefing_3
}
briefing_3() {
  rule
  say "${C_BLD}SYMPTOM${C_OFF}"
  say "  \$ kubectl -n kube-system get pods -l k8s-app=hubble-relay"
  say "  NAME                            READY   STATUS    RESTARTS   AGE"
  say "  hubble-relay-6d9f8c7b4c-xxxxx   0/1     Running   0          40s"
  say "                                  ^^^ never becomes Ready"
  say ""
  say "  \$ hubble status"
  say "  failed to connect to 'localhost:4245': context deadline exceeded"
  say ""
  say "  \$ kubectl -n kube-system logs deploy/hubble-relay"
  say "  level=error msg=\"Failed to create peer client for peers synchronization\""
  say "    error=\"...lookup hubble-peer.cilium-system.svc.cluster.local: no such host\""
  say ""
  say "  Node-local observability still works, which is the key clue:"
  say "  kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --last 5"
  say ""
  say "${C_BLD}YOUR GOAL${C_OFF}"
  say "  hubble-relay 1/1 Ready, 'hubble status' healthy, flows visible again."
  say ""
  say "${C_BLD}WHERE TO LOOK${C_OFF}"
  say "  Relay reads its own ConfigMap at startup. Print it and check every"
  say "  address in it against what actually exists in the cluster."
  rule
}
verify_3() {
  local rc=0 peer ready
  peer="$(kubectl -n "$NS_SYS" get cm hubble-relay-config -o jsonpath='{.data.config\.yaml}' \
          | sed -n 's/^[[:space:]]*peer-service:[[:space:]]*//p')"
  if printf '%s' "$peer" | grep -q "hubble-peer.${NS_SYS}.svc.cluster.local:443"; then
    ok "relay peer-service = $peer"
  else
    warn "relay peer-service = '$peer' (expected hubble-peer.${NS_SYS}.svc.cluster.local:443)"; rc=1
  fi
  ready="$(kubectl -n "$NS_SYS" get deploy hubble-relay -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${ready:-0}" -ge 1 ]; then ok "hubble-relay has ${ready} ready replica(s)"
  else warn "hubble-relay has no ready replicas"; rc=1; fi
  verify_flows || rc=1
  return $rc
}

# --- Fault 4: L7 (HTTP) visibility lost --------------------------------------
break_4() {
  save_state
  deploy_demo
  apply_l7_policy
  info "baseline established with L7 visibility, generating traffic (20s)…"
  sleep 20
  apply_l4_only_policy
  echo 4 > "$FAULT_FILE"
  sleep 10
  briefing_4
}
briefing_4() {
  rule
  say "${C_BLD}SYMPTOM${C_OFF}"
  say "  L3/L4 flows are perfectly fine:"
  say "  \$ hubble observe --namespace cca-obs --last 3"
  say "  ... cca-obs/client-xxx:41288 -> cca-obs/backend-yyy:80 to-endpoint FORWARDED (TCP Flags: ACK, PSH)"
  say ""
  say "  But the HTTP layer has vanished:"
  say "  \$ hubble observe --namespace cca-obs --protocol http --last 20"
  say "  (empty)"
  say ""
  say "  \$ hubble observe --namespace cca-obs --http-status 200"
  say "  (empty)"
  say ""
  say "  The Hubble UI still draws the client → backend edge, but clicking it"
  say "  shows no HTTP verbs, paths or status codes."
  say ""
  say "${C_BLD}YOUR GOAL${C_OFF}"
  say "  Make 'hubble observe --namespace cca-obs --protocol http' emit"
  say "  http-request / http-response events for client → backend again,"
  say "  WITHOUT dropping or altering which traffic is allowed."
  say ""
  say "${C_BLD}WHERE TO LOOK${C_OFF}"
  say "  Hubble does not parse HTTP by itself. Something has to redirect the"
  say "  connection to the per-node proxy first. Inspect:"
  say "  kubectl -n cca-obs get cnp obs-l7-visibility -o yaml"
  say "  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg policy get"
  rule
}
verify_4() {
  local rc=0 out
  if kubectl -n "$NS_LAB" get cnp obs-l7-visibility -o yaml 2>/dev/null | grep -q 'http:'; then
    ok "CiliumNetworkPolicy obs-l7-visibility carries L7 http rules"
  else
    warn "no L7 http rules found in the policy"; rc=1
  fi
  info "sampling HTTP flows for 25s…"
  out="$(hubble_q observe --namespace "$NS_LAB" --protocol http --last 20 2>/dev/null || true)"
  if printf '%s' "$out" | grep -qiE 'http-(request|response)|HTTP/'; then
    ok "L7 flows are visible:"
    printf '%s\n' "$out" | head -3 | sed 's/^/      /'
  else
    warn "still no HTTP flows via relay (give the proxy ~20s after applying the policy)"; rc=1
  fi
  return $rc
}

# --- Fault 5: Hubble metrics endpoint removed --------------------------------
break_5() {
  save_state
  kubectl -n "$NS_SYS" get cm cilium-config -o yaml > "$STATE_DIR/cilium-config.bak.yaml"
  cm_get 'hubble-metrics' > "$STATE_DIR/hubble-metrics.bak"
  cm_get 'hubble-metrics-server' > "$STATE_DIR/hubble-metrics-server.bak"
  kubectl -n "$NS_SYS" patch cm cilium-config --type json \
    -p '[{"op":"remove","path":"/data/hubble-metrics"},{"op":"remove","path":"/data/hubble-metrics-server"}]' >/dev/null 2>&1 \
    || kubectl -n "$NS_SYS" patch cm cilium-config --type merge \
       -p '{"data":{"hubble-metrics":"","hubble-metrics-server":""}}' >/dev/null
  restart_agents
  echo 5 > "$FAULT_FILE"
  briefing_5
}
briefing_5() {
  local ip; ip="$(first_node_ip)"
  rule
  say "${C_BLD}SYMPTOM${C_OFF}"
  say "  'hubble observe' works. Flows are fine. Dashboards are not:"
  say ""
  say "  \$ curl -s http://${ip}:9965/metrics | head"
  say "  curl: (7) Failed to connect to ${ip} port 9965: Connection refused"
  say ""
  say "  Prometheus target cilium-hubble → DOWN"
  say "  \"connection refused\"; every Hubble Grafana panel reads 'No data'."
  say "  hubble_flows_processed_total / hubble_dns_queries_total are gone,"
  say "  while cilium_* agent metrics on :9962 are still being scraped."
  say ""
  say "${C_BLD}YOUR GOAL${C_OFF}"
  say "  Restore the Hubble Prometheus endpoint on every node (:9965) so that"
  say "  hubble_flows_processed_total is exported again."
  say ""
  say "${C_BLD}WHERE TO LOOK${C_OFF}"
  say "  Hubble metrics are opt-in and enumerated explicitly. Diff cilium-config"
  say "  against a healthy reference and check which keys stopped existing:"
  say "  kubectl -n kube-system get cm cilium-config -o yaml | grep -i metrics"
  rule
}
verify_5() {
  local rc=0 m ip out
  m="$(cm_get 'hubble-metrics')"
  if [ -n "$m" ]; then ok "hubble-metrics = $m"
  else warn "hubble-metrics is unset/empty in cilium-config"; rc=1; fi
  [ -n "$(cm_get 'hubble-metrics-server')" ] \
    && ok "hubble-metrics-server = $(cm_get 'hubble-metrics-server')" \
    || { warn "hubble-metrics-server is unset (expected e.g. ':9965')"; rc=1; }

  ip="$(first_node_ip)"
  info "probing http://${ip}:9965/metrics from an ephemeral pod…"
  out="$(kubectl run cca-metrics-probe --rm -i --restart=Never --quiet \
          --image=curlimages/curl:8.8.0 --command -- \
          curl -sf --max-time 8 "http://${ip}:9965/metrics" 2>/dev/null | head -40 || true)"
  if printf '%s' "$out" | grep -q 'hubble_'; then
    ok "endpoint answers with hubble_* series:"
    printf '%s\n' "$out" | grep '^hubble_' | head -3 | sed 's/^/      /'
  else
    warn "no hubble_* metrics served on ${ip}:9965"; rc=1
  fi
  return $rc
}

# ----------------------------------------------------------------------------- shared check
verify_flows() {
  local rc=0 st nodes connected out
  nodes="$(node_count)"
  st="$(hubble_q status 2>&1 || true)"
  printf '%s\n' "$st" | sed 's/^/      /'
  connected="$(printf '%s' "$st" | sed -n 's#.*Connected Nodes:[[:space:]]*\([0-9]*\)/.*#\1#p' | head -1)"
  if [ "${connected:-0}" = "$nodes" ] && [ "${connected:-0}" != "0" ]; then
    ok "relay is connected to ${connected}/${nodes} node(s)"
  else
    warn "relay sees ${connected:-0}/${nodes} node(s)"; rc=1
  fi
  out="$(hubble_q observe --namespace "$NS_LAB" --last 5 2>/dev/null || true)"
  if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    ok "flows are streaming from ${NS_LAB}:"
    printf '%s\n' "$out" | head -3 | sed 's/^/      /'
  else
    warn "no flows returned for namespace ${NS_LAB}"; rc=1
  fi
  return $rc
}

# ----------------------------------------------------------------------------- hints
show_hint() {
  case "$(active_fault)" in
    1) say "Hint 1: relay is healthy and the network is fine — the producers are silent."
       say "Hint 2: 'cilium-dbg status' on any agent prints one line about Hubble."
       say "Hint 3: cilium-config holds a boolean that turns the observer off entirely."
       say "Hint 4: agents read cilium-config only at startup." ;;
    2) say "Hint 1: agents have flows, relay has none — so the break is in between."
       say "Hint 2: 'kubectl -n kube-system get svc hubble-peer -o yaml'."
       say "Hint 3: compare .spec.ports[0].targetPort with hubble-listen-address."
       say "Hint 4: 'kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=hubble-peer -o yaml'." ;;
    3) say "Hint 1: the relay Pod never turns Ready — it fails its own startup work."
       say "Hint 2: read its logs, not the agent's."
       say "Hint 3: 'kubectl -n kube-system get cm hubble-relay-config -o yaml'."
       say "Hint 4: does the hostname in peer-service resolve? Which namespace is it in?" ;;
    4) say "Hint 1: L4 works, L7 does not — nothing is parsing HTTP."
       say "Hint 2: HTTP events come from the Envoy proxy redirect, which only"
       say "        happens when a policy contains an L7 rule for that port."
       say "Hint 3: 'kubectl -n cca-obs get cnp obs-l7-visibility -o yaml' — what is missing under toPorts?"
       say "Hint 4: an empty rule set 'http: [{}]' matches all requests and still allows everything." ;;
    5) say "Hint 1: flows are fine, so the observer runs; only the exporter is gone."
       say "Hint 2: 'kubectl -n kube-system get cm cilium-config -o yaml | grep -i metrics'."
       say "Hint 3: you need BOTH the metric list and the listen address."
       say "Hint 4: values such as: dns,drop,tcp,flow,port-distribution,icmp,httpV2 and ':9965'." ;;
    "") warn "no active fault — run: $0 break random" ;;
  esac
}

# ----------------------------------------------------------------------------- restore
restore_all() {
  local f; f="$(active_fault)"
  [ -n "$f" ] || { warn "nothing to restore"; return 0; }
  warn "restoring fault $f (this is the give-up path)"
  case "$f" in
    1) kubectl -n "$NS_SYS" patch cm cilium-config --type merge -p '{"data":{"enable-hubble":"true"}}' >/dev/null
       restart_agents; restart_relay ;;
    2) kubectl apply -f "$STATE_DIR/hubble-peer.bak.yaml" >/dev/null; restart_relay ;;
    3) kubectl apply -f "$STATE_DIR/hubble-relay-config.bak.yaml" >/dev/null; restart_relay ;;
    4) apply_l7_policy ;;
    5) kubectl -n "$NS_SYS" patch cm cilium-config --type merge -p "$(printf '{"data":{"hubble-metrics":"%s","hubble-metrics-server":"%s"}}' \
         "$(cat "$STATE_DIR/hubble-metrics.bak" 2>/dev/null || echo 'dns drop tcp flow port-distribution icmp httpV2')" \
         "$(cat "$STATE_DIR/hubble-metrics-server.bak" 2>/dev/null || echo ':9965')")" >/dev/null
       restart_agents ;;
  esac
  rm -f "$FAULT_FILE"
  ok "restored — re-run '$0 verify' to confirm the baseline is healthy"
}

cleanup_all() {
  kubectl delete ns "$NS_LAB" --ignore-not-found >/dev/null
  rm -rf "$STATE_DIR"
  ok "demo namespace and lab state removed"
}

# ----------------------------------------------------------------------------- main
usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

cmd_break() {
  local pick="${1:-random}"
  if [ "$pick" = "random" ]; then pick="$(( (RANDOM % 5) + 1 ))"; fi
  case "$pick" in 1|2|3|4|5) : ;; *) die "unknown fault '$pick' (use 1..5 or random)" ;; esac
  [ -z "$(active_fault)" ] || die "fault $(active_fault) is still active — fix it or run '$0 restore'"

  say ""
  warn "About to inject a controlled observability fault into this LAB cluster."
  say "    Reversible with: $0 restore"
  confirm
  save_state
  deploy_demo
  [ "$pick" = "4" ] || apply_l7_policy
  info "injecting fault #${pick}…"
  "break_${pick}"
  say ""
  info "when you think it is fixed:  $0 verify"
  info "stuck?                       $0 hint"
}

cmd_verify() {
  local f; f="$(active_fault)"
  [ -n "$f" ] || die "no active fault"
  rule; info "grading fault #${f}"; rule
  if "verify_${f}"; then
    rule
    ok "${C_BLD}FIXED.${C_OFF} Observability pipeline restored for fault #${f}."
    rm -f "$FAULT_FILE"
    say "Next: $0 break random   (or $0 cleanup)"
  else
    rule
    warn "not yet — read the warnings above, then '$0 hint'"
    return 1
  fi
}

cmd_status() {
  local f; f="$(active_fault)"
  if [ -n "$f" ]; then warn "active fault: #${f}"; "briefing_${f}"
  else ok "no active fault"; fi
}

main() {
  case "${1:-help}" in
    setup)   require_cmd kubectl hubble; assert_lab_cluster; assert_cilium_hubble; save_state; deploy_demo; apply_l7_policy; ok "baseline ready" ;;
    break)   require_cmd kubectl hubble; assert_lab_cluster; assert_cilium_hubble; cmd_break "${2:-random}" ;;
    hint)    show_hint ;;
    verify)  require_cmd kubectl hubble; assert_lab_cluster; cmd_verify ;;
    restore) require_cmd kubectl; assert_lab_cluster; restore_all ;;
    status)  cmd_status ;;
    cleanup) require_cmd kubectl; assert_lab_cluster; cleanup_all ;;
    help|-h|--help) usage ;;
    *) die "unknown command '${1}' — try: $0 help" ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTIONS — read only after you have tried. One block per fault.
# =============================================================================
#
# -----------------------------------------------------------------------------
#  GENERAL METHOD (works for every fault, and for the exam)
# -----------------------------------------------------------------------------
#  Walk the pipeline from the producer to the consumer and stop at the first
#  broken arrow. Four questions, in this order:
#
#   1) Does the DATAPATH produce events?
#      kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble
#      # Hubble:  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 27.31
#      # "Disabled" here means nothing downstream can ever work.
#
#   2) Does the NODE-LOCAL API answer? (bypasses relay, Service and TLS)
#      kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --last 5
#      # This talks to unix:///var/run/cilium/hubble.sock inside the agent.
#      # Works => the break is north of the agent (Service / relay / client).
#
#   3) Does RELAY see the nodes?
#      kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
#      hubble status
#      # Connected Nodes: N/N is the single most informative line in Hubble.
#      kubectl -n kube-system logs deploy/hubble-relay --tail=50
#
#   4) Do the CONSUMERS get what they need?
#      hubble observe --namespace X --protocol http     # L7 → needs Envoy redirect
#      curl http://<node>:9965/metrics | grep hubble_   # Prometheus → needs metrics config
#
#  Rule of thumb: 0/N connected nodes = discovery or agent problem;
#  relay Pod not Ready = relay's own config; flows but no HTTP = policy/proxy;
#  flows but no metrics = exporter config.
#
# -----------------------------------------------------------------------------
#  FAULT 1 — enable-hubble: "false" in the cilium-config ConfigMap
# -----------------------------------------------------------------------------
#  Diagnosis
#    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble
#    # Hubble:   Disabled
#    kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'hubble'
#    # enable-hubble: "false"
#
#  Fix
#    # 1. flip the flag
#    kubectl -n kube-system patch cm cilium-config --type merge \
#      -p '{"data":{"enable-hubble":"true"}}'
#
#    # 2. agents read cilium-config only at startup — a restart is mandatory
#    kubectl -n kube-system rollout restart ds/cilium
#    kubectl -n kube-system rollout status  ds/cilium --timeout=180s
#
#    # 3. relay reconnects on its own, but restart it if it stays at 0 nodes
#    kubectl -n kube-system rollout restart deploy/hubble-relay
#
#  Verify
#    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i hubble
#    # Hubble:  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 31.02
#    hubble status      # Connected Nodes: N/N
#
#  Production note
#    In a Helm-managed cluster, patching the ConfigMap by hand is undone by the
#    next 'helm upgrade'. The durable fix is:
#      helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
#        --set hubble.enabled=true --set hubble.relay.enabled=true
#    Same for every other fault in this lab.
#
# -----------------------------------------------------------------------------
#  FAULT 2 — Service hubble-peer forwarding to the wrong container port
# -----------------------------------------------------------------------------
#  Diagnosis
#    hubble status                       # Connected Nodes: 0/N, healthcheck Ok
#    kubectl -n kube-system logs deploy/hubble-relay | tail
#    # "Failed to create gRPC client" ... error="context deadline exceeded"
#    kubectl -n kube-system get svc hubble-peer -o yaml
#    # targetPort: 4299   <-- nothing listens there
#    kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-listen-address}'
#    # :4244
#
#  Fix
#    kubectl -n kube-system patch svc hubble-peer --type merge -p \
#      '{"spec":{"ports":[{"name":"peer-service","port":443,"protocol":"TCP","targetPort":4244}]}}'
#    # (keep the original port name; a wrong name creates a second port instead
#    #  of replacing the existing one)
#
#    kubectl -n kube-system rollout restart deploy/hubble-relay
#
#  Verify
#    kubectl -n kube-system get endpointslices \
#      -l kubernetes.io/service-name=hubble-peer -o wide
#    # one endpoint per node, port 4244, ready=true
#    hubble status          # Connected Nodes: N/N
#
#  Why it matters
#    hubble-peer is a hostNetwork-backed Service (internalTrafficPolicy: Local)
#    whose only job is peer discovery: relay lists it, then opens one Observer
#    stream per node to :4244 over mTLS. Break the Service and relay is blind,
#    even though every agent is perfectly healthy.
#
# -----------------------------------------------------------------------------
#  FAULT 3 — hubble-relay-config points at a non-existent peer service
# -----------------------------------------------------------------------------
#  Diagnosis
#    kubectl -n kube-system get pods -l k8s-app=hubble-relay     # 0/1 Running
#    kubectl -n kube-system logs deploy/hubble-relay
#    # "Failed to create peer client for peers synchronization"
#    # lookup hubble-peer.cilium-system.svc.cluster.local: no such host
#    kubectl -n kube-system get cm hubble-relay-config -o jsonpath='{.data.config\.yaml}'
#    # peer-service: hubble-peer.cilium-system.svc.cluster.local:443
#    kubectl get svc -A | grep hubble-peer     # it lives in kube-system
#
#  Fix
#    kubectl -n kube-system get cm hubble-relay-config \
#      -o jsonpath='{.data.config\.yaml}' > /tmp/relay.yaml
#    sed -i 's#peer-service: .*#peer-service: hubble-peer.kube-system.svc.cluster.local:443#' /tmp/relay.yaml
#
#    { echo "data:"; echo "  config.yaml: |"; sed 's/^/    /' /tmp/relay.yaml; } > /tmp/relay-patch.yaml
#    kubectl -n kube-system patch cm hubble-relay-config --patch-file /tmp/relay-patch.yaml
#    kubectl -n kube-system rollout restart deploy/hubble-relay
#    kubectl -n kube-system rollout status  deploy/hubble-relay
#
#  Verify
#    kubectl -n kube-system get pods -l k8s-app=hubble-relay     # 1/1 Running
#    hubble status                                               # Connected Nodes: N/N
#
#  Adjacent failure to recognise
#    If instead of DNS errors you see 'transport: authentication handshake
#    failed' or 'x509: certificate signed by unknown authority', the peer
#    address is right and the mTLS material is wrong: relay mounts
#    hubble-relay-client-certs (client cert + CA) and the agent presents
#    hubble-server-certs. Rotate with 'cilium hubble disable && cilium hubble
#    enable', or re-run the Helm upgrade so cert-manager/Helm regenerates both.
#
# -----------------------------------------------------------------------------
#  FAULT 4 — L7 visibility lost (policy downgraded to L3/L4)
# -----------------------------------------------------------------------------
#  Diagnosis
#    hubble observe --namespace cca-obs --last 3                  # L4 flows OK
#    hubble observe --namespace cca-obs --protocol http --last 20 # empty
#    kubectl -n cca-obs get cnp obs-l7-visibility -o yaml
#    # toPorts has ports: but no rules: block  -> no Envoy redirect
#    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg policy get
#    # no L7 rules listed for the backend identity
#
#  Fix — reinstate an L7 rule that allows everything but forces HTTP parsing
#    cat <<'EOF' | kubectl apply -f -
#    apiVersion: cilium.io/v2
#    kind: CiliumNetworkPolicy
#    metadata:
#      name: obs-l7-visibility
#      namespace: cca-obs
#    spec:
#      endpointSelector:
#        matchLabels:
#          app: backend
#      ingress:
#      - fromEndpoints:
#        - matchLabels:
#            app: client
#        toPorts:
#        - ports:
#          - port: "80"
#            protocol: TCP
#          rules:
#            http:
#            - {}          # match-all: same allow-set as L4, but proxied
#    EOF
#
#  Verify (allow ~15s for the proxy redirect to be programmed)
#    hubble observe --namespace cca-obs --protocol http --last 10
#    # cca-obs/client-xxx:41288 -> cca-obs/backend-yyy:80 http-request FORWARDED (HTTP/1.1 GET http://backend.cca-obs.svc.cluster.local/)
#    # cca-obs/backend-yyy:80 -> cca-obs/client-xxx:41288 http-response FORWARDED (HTTP/1.1 200 1ms (GET http://.../))
#    hubble observe --namespace cca-obs --http-status 200 --last 5
#
#  Key concepts
#    * Hubble reports L7 only for traffic redirected to the node's Envoy proxy;
#      that redirect is created by an L7 policy rule, never by Hubble itself.
#    * 'http: [{}]' is the visibility idiom: it changes nothing about what is
#      allowed, it only moves the connection through the proxy. Adding a real
#      rule (method: "GET", path: "/api/.*") turns visibility into enforcement,
#      and anything unmatched becomes 'http-request DROPPED (403)'.
#    * The old 'policy.cilium.io/proxy-visibility' annotation did the same job
#      without a policy; it is deprecated and removed in current Cilium — use a
#      CiliumNetworkPolicy.
#    * L7 proxying costs CPU and latency, and breaks flows that are not really
#      HTTP. Scope it to the ports you actually need to observe.
#
# -----------------------------------------------------------------------------
#  FAULT 5 — Hubble Prometheus exporter disabled
# -----------------------------------------------------------------------------
#  Diagnosis
#    hubble observe --last 5                       # flows fine → observer alive
#    curl -s http://<node-ip>:9965/metrics         # connection refused
#    kubectl -n kube-system get cm cilium-config -o yaml | grep -i metrics
#    # hubble-metrics and hubble-metrics-server are gone;
#    # prometheus-serve-addr (:9962, agent metrics) is still there — that is why
#    # cilium_* keeps being scraped while hubble_* does not.
#
#  Fix
#    kubectl -n kube-system patch cm cilium-config --type merge -p '{"data":{
#      "hubble-metrics-server": ":9965",
#      "hubble-metrics": "dns drop tcp flow port-distribution icmp httpV2"
#    }}'
#    kubectl -n kube-system rollout restart ds/cilium
#    kubectl -n kube-system rollout status  ds/cilium --timeout=180s
#
#  Verify
#    kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.8.0 -- \
#      curl -s http://<node-ip>:9965/metrics | grep -E '^hubble_(flows_processed|dns_queries)'
#    # hubble_flows_processed_total{protocol="TCP",subtype="to-endpoint",type="Trace",verdict="FORWARDED"} 1843
#    kubectl -n kube-system get svc hubble-metrics -o yaml    # headless, port 9965
#
#  Notes
#    * The space-separated list is exact: an unknown handler name makes the
#      agent fail to start the metrics server — check with
#      'kubectl -n kube-system logs ds/cilium -c cilium-agent | grep -i metric'.
#    * Context labels are opt-in and expensive; 'httpV2:labelsContext=source_namespace,
#      destination_namespace' is the usual compromise. Per-pod labels are a
#      cardinality trap on any real cluster.
#    * These are AGGREGATE metrics derived from flows. They are not a substitute
#      for flow export: for per-flow retention beyond the in-memory ring buffer
#      (hubble-event-buffer-capacity, default 4095 flows per node) configure
#      Hubble export to a file/collector, otherwise old flows are simply gone.
# =============================================================================