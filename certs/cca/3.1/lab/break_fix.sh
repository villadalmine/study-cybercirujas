#!/usr/bin/env bash
# =============================================================================
#  CCA — Cilium Certified Associate
#  Domain 3 · Kubernetes Networking with Cilium   (exam weight: 20%)
#  Topic 3.1 — BREAK & FIX laboratory
#
#  Syllabus reference:
#    https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
#
#  Official documentation this lab is built on:
#    kube-proxy replacement / service datapath
#      https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
#    masquerading (BPF + iptables modes)
#      https://docs.cilium.io/en/stable/network/concepts/masquerading/
#    CNI plugin installation and lifecycle
#      https://docs.cilium.io/en/stable/installation/cni-config/
#    troubleshooting / cilium-dbg command reference
#      https://docs.cilium.io/en/stable/operations/troubleshooting/
#      https://docs.cilium.io/en/stable/cmdref/cilium-dbg_service/
#    Hubble flow observability
#      https://docs.cilium.io/en/stable/observability/hubble/
#    Kubernetes CNI network plugin contract (kubelet side)
#      https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
#
# -----------------------------------------------------------------------------
#  !! THIS SCRIPT INTENTIONALLY BREAKS CLUSTER NETWORKING !!
#
#  LAB CONTRACT — what it touches:
#    * creates namespace "cca-lab" with a web Deployment/Service, a netshoot
#      client and a scaled-to-zero "canary" Deployment;
#    * fault 1: deletes ONE service entry from the Cilium eBPF LB map
#               (in-memory datapath state, restored by an agent resync);
#    * fault 2: sets enable-ipv4-masquerade/enable-bpf-masquerade=false in the
#               cilium-config ConfigMap and restarts the agent DaemonSet
#               (full YAML backup written to the state dir first);
#    * fault 3: renames /opt/cni/bin/cilium-cni on the lab node
#               (the original file is never deleted, only renamed).
#  What it never touches: any namespace other than cca-lab and kube-system's
#  cilium-config ConfigMap, no CRDs, no RBAC, no node OS packages, no data.
#
#  Run it ONLY on a disposable single-node lab (kind / minikube / k3d / a
#  throw-away VM). It refuses to run elsewhere unless you export
#  CCA_LAB_FORCE=yes-destroy-this-cluster.
# =============================================================================

set -Eeuo pipefail

LAB_ID="cca-3.1"
LAB_NS="${LAB_NS:-cca-lab}"
CILIUM_NS="${CILIUM_NS:-kube-system}"
STATE_DIR="${STATE_DIR:-/var/tmp/${LAB_ID}}"
STATE_FILE="${STATE_DIR}/state.env"
WEB_IMAGE="${WEB_IMAGE:-nginx:1.27-alpine}"
CLIENT_IMAGE="${CLIENT_IMAGE:-nicolaka/netshoot:v0.13}"
TOOL_IMAGE="${TOOL_IMAGE:-busybox:1.36}"
EXTERNAL_TARGET="${EXTERNAL_TARGET:-1.1.1.1}"
NODESHELL_POD="cca-lab-nodeshell"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYA=$'\033[36m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_BLD=""; C_OFF=""
fi

log()  { printf '%s\n' "${C_CYA}[lab]${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_GRN}[ ok ]${C_OFF} $*"; }
warn() { printf '%s\n' "${C_YEL}[warn]${C_OFF} $*" >&2; }
err()  { printf '%s\n' "${C_RED}[fail]${C_OFF} $*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "${C_BLD}------------------------------------------------------------------------${C_OFF}"; }

trap 'err "aborted (line $LINENO)"' ERR

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------
state_set() {
  local k="$1" v="$2"
  mkdir -p "$STATE_DIR"; touch "$STATE_FILE"
  sed -i "/^${k}=/d" "$STATE_FILE"
  printf '%s=%q\n' "$k" "$v" >>"$STATE_FILE"
}
state_load() { [[ -f "$STATE_FILE" ]] && . "$STATE_FILE" || true; }

# ---------------------------------------------------------------------------
# guards and preflight
# ---------------------------------------------------------------------------
need_bin() { command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"; }

guard_disposable_cluster() {
  local ctx nodes safe=0
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  case "$ctx" in
    kind-*|minikube|k3d-*|*lab*|*vagrant*|*sandbox*|*test*) safe=1 ;;
  esac
  [[ "$nodes" == "1" ]] || safe=0
  if [[ "$safe" != "1" && "${CCA_LAB_FORCE:-}" != "yes-destroy-this-cluster" ]]; then
    hr
    err "refusing to run: context='${ctx}', nodes=${nodes}"
    err "this lab destroys networking; it only auto-approves a single-node"
    err "kind/minikube/k3d/lab context. If this really is a disposable VM:"
    err "    export CCA_LAB_FORCE=yes-destroy-this-cluster"
    hr
    exit 1
  fi
  log "target context: ${C_BLD}${ctx}${C_OFF} (${nodes} node(s))"
}

CILIUM_BIN=""
detect_cilium() {
  local pods
  pods="$(cilium_pods)"
  [[ -n "$pods" ]] || die "no Cilium agent pods found in namespace ${CILIUM_NS}"
  local first="${pods%% *}"
  CILIUM_BIN="$(kubectl -n "$CILIUM_NS" exec "$first" -c cilium-agent -- \
      sh -c 'command -v cilium-dbg || command -v cilium' 2>/dev/null | head -n1)"
  CILIUM_BIN="$(basename "${CILIUM_BIN:-cilium}")"
  log "cilium agent CLI in-pod: ${CILIUM_BIN}"
}

cilium_pods() {
  local sel out
  for sel in "k8s-app=cilium" "app.kubernetes.io/name=cilium-agent"; do
    out="$(kubectl -n "$CILIUM_NS" get pods -l "$sel" \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  done
  return 0
}

cx() { # cx <cilium-pod> <args...>   → run the agent CLI inside that pod
  local pod="$1"; shift
  kubectl -n "$CILIUM_NS" exec "$pod" -c cilium-agent -- "$CILIUM_BIN" "$@"
}

cilium_ds_restart() {
  log "restarting the Cilium agent DaemonSet (full resync from the API server)"
  kubectl -n "$CILIUM_NS" rollout restart ds/cilium >/dev/null
  kubectl -n "$CILIUM_NS" rollout status ds/cilium --timeout=300s
}

client_pod() { kubectl -n "$LAB_NS" get pod -l app=client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
in_client()  { kubectl -n "$LAB_NS" exec "$(client_pod)" -- "$@"; }

svc_ip()  { kubectl -n "$LAB_NS" get svc web -o jsonpath='{.spec.clusterIP}'; }
svc_uid() { kubectl -n "$LAB_NS" get svc web -o jsonpath='{.metadata.uid}'; }

http_code_svc() {
  in_client curl -sS -m 6 -o /dev/null -w '%{http_code}' \
    "http://web.${LAB_NS}.svc.cluster.local/" 2>/dev/null || true
}
http_code_podip() {
  local ip
  ip="$(kubectl -n "$LAB_NS" get pod -l app=web -o jsonpath='{.items[0].status.podIP}')"
  in_client curl -sS -m 6 -o /dev/null -w '%{http_code}' "http://${ip}/" 2>/dev/null || true
}
external_ok() { in_client curl -sS -m 8 -o /dev/null "http://${EXTERNAL_TARGET}/" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# node shell: a hostNetwork + privileged pod.
#   hostNetwork:true is deliberate — kubelet does NOT call the CNI plugin for
#   host-network pods, so this helper still schedules while the CNI datapath
#   is broken. That is the escape hatch fault 3 teaches.
#   NOTE: <snippet> must not contain double quotes (it is inlined into JSON).
# ---------------------------------------------------------------------------
run_node_shell() {
  local node="$1" snippet="$2" phase="" i
  kubectl -n "$LAB_NS" delete pod "$NODESHELL_POD" --ignore-not-found --wait=true >/dev/null
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${NODESHELL_POD}
  namespace: ${LAB_NS}
  labels:
    app: nodeshell
spec:
  nodeName: ${node}
  hostNetwork: true
  hostPID: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  volumes:
    - name: cni-bin
      hostPath:
        path: /opt/cni/bin
        type: Directory
    - name: cni-netd
      hostPath:
        path: /etc/cni/net.d
        type: Directory
  containers:
    - name: shell
      image: ${TOOL_IMAGE}
      securityContext:
        privileged: true
      command: ["/bin/sh","-c","${snippet}"]
      volumeMounts:
        - name: cni-bin
          mountPath: /host/opt/cni/bin
        - name: cni-netd
          mountPath: /host/etc/cni/net.d
YAML
  for ((i=0; i<60; i++)); do
    phase="$(kubectl -n "$LAB_NS" get pod "$NODESHELL_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
  done
  kubectl -n "$LAB_NS" logs "$NODESHELL_POD" 2>/dev/null | sed 's/^/       | /' || true
  kubectl -n "$LAB_NS" delete pod "$NODESHELL_POD" --ignore-not-found --wait=false >/dev/null
  [[ "$phase" == "Succeeded" ]] || die "node helper pod did not complete (phase=${phase:-unknown})"
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
cmd_setup() {
  guard_disposable_cluster
  need_bin kubectl
  detect_cilium

  log "deploying the lab workload in namespace ${LAB_NS}"
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${LAB_NS}
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ${LAB_NS}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: ${WEB_IMAGE}
          ports:
            - containerPort: 80
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: ${LAB_NS}
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: ${LAB_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
    spec:
      containers:
        - name: client
          image: ${CLIENT_IMAGE}
          command: ["sleep","infinity"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: canary
  namespace: ${LAB_NS}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: canary
  template:
    metadata:
      labels:
        app: canary
    spec:
      containers:
        - name: canary
          image: ${WEB_IMAGE}
YAML

  kubectl -n "$LAB_NS" rollout status deploy/web --timeout=180s
  kubectl -n "$LAB_NS" rollout status deploy/client --timeout=180s

  local node cip uid
  node="$(kubectl -n "$LAB_NS" get pod -l app=client -o jsonpath='{.items[0].spec.nodeName}')"
  cip="$(svc_ip)"; uid="$(svc_uid)"

  hr
  log "BASELINE (this is the state you must return the cluster to)"
  printf '       ClusterIP             : %s\n' "$cip"
  printf '       Service -> HTTP       : %s\n' "$(http_code_svc)"
  printf '       Pod IP  -> HTTP       : %s\n' "$(http_code_podip)"
  printf '       DNS A record          : %s\n' "$(in_client dig +short "web.${LAB_NS}.svc.cluster.local" 2>/dev/null | tr '\n' ' ')"
  if external_ok; then
    printf '       Egress to %-12s: reachable\n' "$EXTERNAL_TARGET"
    state_set BASELINE_EXTERNAL ok
  else
    printf '       Egress to %-12s: NOT reachable (fault 2 will be unavailable)\n' "$EXTERNAL_TARGET"
    state_set BASELINE_EXTERNAL na
  fi
  hr

  [[ "$(http_code_svc)" == "200" ]] || die "baseline is already broken: ClusterIP does not answer 200"

  state_set NODE "$node"
  state_set SVC_CLUSTER_IP "$cip"
  state_set SVC_UID "$uid"
  state_set SCENARIO 0
  ok "lab ready. Now run:  $0 break --scenario <1|2|3>"
}

# ---------------------------------------------------------------------------
# fault 1 — the eBPF LB map loses one service entry
# ---------------------------------------------------------------------------
break_1() {
  state_load
  local cip="${SVC_CLUSTER_IP:?run setup first}" pod id found=0
  for pod in $(cilium_pods); do
    id="$(cx "$pod" service list 2>/dev/null | awk -v f="${cip}:80" '$2 ~ "^"f"(/|$)" {print $1; exit}')"
    [[ -n "$id" ]] || continue
    log "deleting LB frontend ${cip}:80 (service id ${id}) from the datapath of ${pod}"
    cx "$pod" service delete "$id" >/dev/null
    found=1
  done
  [[ "$found" == "1" ]] || die "could not locate ${cip}:80 in any agent's service list"
  state_set SCENARIO 1
  sleep 3
  brief_1
}

brief_1() {
  state_load
  hr
  printf '%s\n' "${C_BLD}INCIDENT #1 — kubectl says the Service is healthy. The pods disagree.${C_OFF}"
  hr
  cat <<TXT
SYMPTOM you will observe
  * DNS still resolves web.${LAB_NS}.svc.cluster.local to ${SVC_CLUSTER_IP:-<clusterIP>}.
  * curl http://web.${LAB_NS}.svc.cluster.local/ hangs and then times out
    (observed HTTP code now: $(http_code_svc)).
  * curl http://<web-pod-ip>/ returns 200 instantly
    (observed HTTP code now: $(http_code_podip)).
  * kubectl get svc,endpointslice -n ${LAB_NS} shows two healthy, Ready backends.
  * Nothing is CrashLooping. No NetworkPolicy exists in the namespace.

WHAT YOU MUST WORK OUT
  With kube-proxy replacement, the Kubernetes Service object is NOT what forwards
  traffic; the eBPF load-balancer maps attached to the datapath are. Explain the
  divergence between control-plane state and datapath state, and prove it with
  the agent's own view before you change anything.

YOUR MISSION
  Restore ClusterIP connectivity WITHOUT deleting or recreating the Service,
  the Deployment or the namespace. The Service UID must not change.

TOOLS YOU ARE EXPECTED TO REACH FOR
  kubectl -n ${CILIUM_NS} exec ds/cilium -c cilium-agent -- ${CILIUM_BIN:-cilium-dbg} status --verbose
  kubectl -n ${CILIUM_NS} exec ds/cilium -c cilium-agent -- ${CILIUM_BIN:-cilium-dbg} service list
  kubectl -n ${CILIUM_NS} exec ds/cilium -c cilium-agent -- ${CILIUM_BIN:-cilium-dbg} bpf lb list
  kubectl -n ${CILIUM_NS} exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED --last 20
  kubectl -n ${LAB_NS} get endpointslices -l kubernetes.io/service-name=web -o yaml

SUCCESS CRITERIA (checked by: $0 verify)
  1. curl from the client to the ClusterIP returns HTTP 200.
  2. The frontend ${SVC_CLUSTER_IP:-<clusterIP>}:80 is present again in
     '${CILIUM_BIN:-cilium-dbg} service list' on every agent, with active backends.
  3. The Service UID is unchanged (you did not recreate the object).
TXT
  hr
}

verify_1() {
  state_load
  local rc=0 pod code uid
  code="$(http_code_svc)"
  if [[ "$code" == "200" ]]; then ok "PASS  ClusterIP answers HTTP 200"; else err "FAIL  ClusterIP answers '${code}'"; rc=1; fi
  uid="$(svc_uid)"
  if [[ "$uid" == "${SVC_UID:-}" ]]; then ok "PASS  Service UID unchanged (object was not recreated)"
  else err "FAIL  Service UID changed — recreating the Service is not an accepted fix"; rc=1; fi
  for pod in $(cilium_pods); do
    if cx "$pod" service list 2>/dev/null | awk -v f="${SVC_CLUSTER_IP}:80" '$2 ~ "^"f"(/|$)"' | grep -q .; then
      ok "PASS  ${pod}: frontend ${SVC_CLUSTER_IP}:80 present in the datapath"
    else
      err "FAIL  ${pod}: frontend ${SVC_CLUSTER_IP}:80 still missing from the datapath"; rc=1
    fi
  done
  return $rc
}

reset_1() { cilium_ds_restart; }

# ---------------------------------------------------------------------------
# fault 2 — masquerading disabled
# ---------------------------------------------------------------------------
break_2() {
  state_load
  [[ "${BASELINE_EXTERNAL:-na}" == "ok" ]] || \
    die "fault 2 needs working egress to ${EXTERNAL_TARGET} at baseline; re-run setup on a lab VM with outbound access, or set EXTERNAL_TARGET"

  mkdir -p "$STATE_DIR"
  kubectl -n "$CILIUM_NS" get cm cilium-config -o yaml >"${STATE_DIR}/cilium-config.backup.yaml"
  log "cilium-config backed up to ${STATE_DIR}/cilium-config.backup.yaml"

  local prev4 prevbpf
  prev4="$(kubectl -n "$CILIUM_NS" get cm cilium-config -o jsonpath='{.data.enable-ipv4-masquerade}' 2>/dev/null || true)"
  prevbpf="$(kubectl -n "$CILIUM_NS" get cm cilium-config -o jsonpath='{.data.enable-bpf-masquerade}' 2>/dev/null || true)"
  state_set PREV_IPV4_MASQ "${prev4:-ABSENT}"
  state_set PREV_BPF_MASQ "${prevbpf:-ABSENT}"

  log "disabling masquerading in cilium-config"
  kubectl -n "$CILIUM_NS" patch cm cilium-config --type merge \
    -p '{"data":{"enable-ipv4-masquerade":"false","enable-bpf-masquerade":"false"}}' >/dev/null
  cilium_ds_restart
  state_set SCENARIO 2
  sleep 5
  brief_2
}

brief_2() {
  state_load
  hr
  printf '%s\n' "${C_BLD}INCIDENT #2 — 'the internet is down', but only for Pods.${C_OFF}"
  hr
  cat <<TXT
SYMPTOM you will observe
  * East-west traffic is perfect: Pod -> Pod and Pod -> ClusterIP both work
    (ClusterIP right now: $(http_code_svc)).
  * In-cluster DNS resolves normally.
  * Any Pod reaching an address OUTSIDE the cluster (${EXTERNAL_TARGET}, a package
    mirror, an external API) times out with no TCP handshake. curl reports
    'Connection timed out', never 'Connection refused' and never a DNS error.
  * The SAME request from the node itself (or from a hostNetwork Pod) succeeds.
  * Nothing changed in NetworkPolicy, in the app, or on the firewall.

WHAT YOU MUST WORK OUT
  A Pod's source address belongs to the Pod CIDR, which nothing outside the node
  knows how to route back to. Identify which component is normally responsible
  for rewriting that source address on egress, where that behaviour is
  configured, and how to read its live state from the agent instead of guessing
  from the Helm values you think were applied.

YOUR MISSION
  Restore Pod egress to ${EXTERNAL_TARGET} by fixing the configuration source of
  truth — not by adding a manual iptables MASQUERADE rule on the node, and not
  by moving the workload to hostNetwork.

TOOLS YOU ARE EXPECTED TO REACH FOR
  kubectl -n ${CILIUM_NS} exec ds/cilium -c cilium-agent -- ${CILIUM_BIN:-cilium-dbg} status --verbose | grep -iA2 Masquerading
  kubectl -n ${CILIUM_NS} exec ds/cilium -c cilium-agent -- ${CILIUM_BIN:-cilium-dbg} config
  kubectl -n ${CILIUM_NS} exec ds/cilium -c cilium-agent -- ${CILIUM_BIN:-cilium-dbg} bpf nat list | head
  kubectl -n ${CILIUM_NS} get cm cilium-config -o yaml | grep -i masq
  kubectl -n ${LAB_NS} exec deploy/client -- tcpdump -ni any host ${EXTERNAL_TARGET}   # watch the source IP

SUCCESS CRITERIA (checked by: $0 verify)
  1. curl http://${EXTERNAL_TARGET}/ from the client Pod succeeds again.
  2. The agent reports masquerading enabled for IPv4 in 'status --verbose'.
  3. East-west traffic (ClusterIP) still returns HTTP 200 — you did not trade one
     outage for another.
TXT
  hr
}

verify_2() {
  local rc=0 pod line code
  if external_ok; then ok "PASS  Pod egress to ${EXTERNAL_TARGET} works"
  else err "FAIL  Pod egress to ${EXTERNAL_TARGET} still fails"; rc=1; fi
  for pod in $(cilium_pods); do
    line="$(cx "$pod" status --verbose 2>/dev/null | grep -i '^Masquerading' || true)"
    if [[ -n "$line" && "$line" != *"Masquerading:"*"Disabled"* ]]; then
      ok "PASS  ${pod}: ${line}"
    else
      err "FAIL  ${pod}: ${line:-Masquerading line not found}"; rc=1
    fi
  done
  code="$(http_code_svc)"
  if [[ "$code" == "200" ]]; then ok "PASS  east-west ClusterIP traffic still healthy"
  else err "FAIL  east-west ClusterIP traffic broke ('${code}')"; rc=1; fi
  return $rc
}

reset_2() {
  state_load
  local p
  for p in enable-ipv4-masquerade:"${PREV_IPV4_MASQ:-ABSENT}" enable-bpf-masquerade:"${PREV_BPF_MASQ:-ABSENT}"; do
    local k="${p%%:*}" v="${p#*:}"
    if [[ "$v" == "ABSENT" ]]; then
      kubectl -n "$CILIUM_NS" patch cm cilium-config --type json \
        -p "[{\"op\":\"remove\",\"path\":\"/data/${k}\"}]" >/dev/null 2>&1 || true
    else
      kubectl -n "$CILIUM_NS" patch cm cilium-config --type merge \
        -p "{\"data\":{\"${k}\":\"${v}\"}}" >/dev/null
    fi
  done
  cilium_ds_restart
}

# ---------------------------------------------------------------------------
# fault 3 — the CNI plugin binary disappears from the node
# ---------------------------------------------------------------------------
break_3() {
  state_load
  local node="${NODE:?run setup first}"
  log "renaming the Cilium CNI plugin binary on node ${node}"
  run_node_shell "$node" \
    'for f in /host/opt/cni/bin/cilium-cni; do [ -f $f ] && mv $f $f.cca-lab-disabled; done; ls -la /host/opt/cni/bin'
  state_set SCENARIO 3
  log "scaling the canary Deployment to 1 to surface the symptom"
  kubectl -n "$LAB_NS" scale deploy/canary --replicas=1 >/dev/null
  sleep 25
  brief_3
}

brief_3() {
  hr
  printf '%s\n' "${C_BLD}INCIDENT #3 — running Pods are fine; no new Pod ever starts.${C_OFF}"
  hr
  kubectl -n "$LAB_NS" get pods -o wide 2>/dev/null | sed 's/^/       /' || true
  printf '\n       %s\n' "${C_BLD}Latest event on the canary Pod:${C_OFF}"
  kubectl -n "$LAB_NS" get events --field-selector reason=FailedCreatePodSandBox \
    -o custom-columns=OBJ:.involvedObject.name,MSG:.message --no-headers 2>/dev/null \
    | tail -n2 | cut -c1-200 | sed 's/^/       | /' || true
  cat <<TXT

SYMPTOM you will observe
  * Every Pod that was already Running keeps working: existing traffic, ClusterIP
    and DNS are untouched (ClusterIP right now: $(http_code_svc)).
  * Every NEW Pod is stuck in ContainerCreating forever, with a
    FailedCreatePodSandBox event from kubelet.
  * The node itself is Ready. The Cilium agent is Running and 'status' looks OK.
  * A Pod with hostNetwork: true still starts normally. That asymmetry is the
    single most valuable clue in this incident.

WHAT YOU MUST WORK OUT
  Which process actually wires a Pod's network namespace, when it is invoked, and
  which two directories on the NODE it depends on. Then explain why a
  hostNetwork Pod is immune, and who is responsible for putting those files on
  the node in a Cilium installation.

YOUR MISSION
  Get the canary Deployment to Running/Ready again. You may not switch the
  workload to hostNetwork, and you may not reinstall Cilium with Helm.

TOOLS YOU ARE EXPECTED TO REACH FOR
  kubectl -n ${LAB_NS} describe pod -l app=canary | sed -n '/Events/,\$p'
  kubectl -n ${CILIUM_NS} get ds cilium -o jsonpath='{.spec.template.spec.initContainers[*].name}'
  kubectl -n ${CILIUM_NS} logs ds/cilium -c install-cni-binaries
  # inspect the node filesystem WITHOUT the CNI datapath (hostNetwork is the escape hatch):
  kubectl debug node/<node> -it --image=${TOOL_IMAGE} -- ls -la /host/opt/cni/bin /host/etc/cni/net.d
  # or, on kind:  docker exec <node> ls -la /opt/cni/bin /etc/cni/net.d

SUCCESS CRITERIA (checked by: $0 verify)
  1. The canary Pod reaches Ready with its own Pod IP (not the node IP).
  2. The plugin binary is executable again at /opt/cni/bin/cilium-cni.
  3. The pre-existing workload is still healthy (ClusterIP returns HTTP 200).
TXT
  hr
}

verify_3() {
  state_load
  local rc=0 code ready hostnet
  log "waiting up to 120s for the canary Deployment"
  kubectl -n "$LAB_NS" rollout status deploy/canary --timeout=120s >/dev/null 2>&1 || true
  ready="$(kubectl -n "$LAB_NS" get deploy canary -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${ready:-0}" -ge 1 ]]; then ok "PASS  canary Pod is Ready"
  else err "FAIL  canary Pod is not Ready (readyReplicas=${ready:-0})"; rc=1; fi

  hostnet="$(kubectl -n "$LAB_NS" get pod -l app=canary -o jsonpath='{.items[0].spec.hostNetwork}' 2>/dev/null || true)"
  if [[ "$hostnet" == "true" ]]; then err "FAIL  canary was moved to hostNetwork — that bypasses the fault, it does not fix it"; rc=1
  else ok "PASS  canary still uses the CNI datapath (hostNetwork not set)"; fi

  run_node_shell "${NODE}" 'test -x /host/opt/cni/bin/cilium-cni && echo PLUGIN-PRESENT || echo PLUGIN-MISSING' \
    | tee "${STATE_DIR}/verify3.out" >/dev/null || true
  if grep -q PLUGIN-PRESENT "${STATE_DIR}/verify3.out" 2>/dev/null; then
    ok "PASS  /opt/cni/bin/cilium-cni present and executable"
  else
    warn "could not confirm the plugin binary from the node helper (see output above)"
  fi

  code="$(http_code_svc)"
  if [[ "$code" == "200" ]]; then ok "PASS  pre-existing workload still healthy"
  else err "FAIL  pre-existing workload broke ('${code}')"; rc=1; fi
  return $rc
}

reset_3() {
  state_load
  run_node_shell "${NODE}" \
    'for f in /host/opt/cni/bin/cilium-cni.cca-lab-disabled; do [ -f $f ] && mv $f /host/opt/cni/bin/cilium-cni; done; ls -la /host/opt/cni/bin'
  cilium_ds_restart
  kubectl -n "$LAB_NS" rollout status deploy/canary --timeout=180s || true
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
cmd_break() {
  local scenario=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--scenario) scenario="${2:?}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  guard_disposable_cluster
  state_load
  [[ -n "${NODE:-}" ]] || die "no lab state found — run '$0 setup' first"
  if [[ "${SCENARIO:-0}" != "0" ]]; then
    die "fault ${SCENARIO} is still active. Fix it, or run '$0 reset' before injecting another one."
  fi
  detect_cilium
  hr
  printf '%s\n' "${C_RED}${C_BLD}  INJECTING FAULT ${scenario} — cluster networking is about to break  ${C_OFF}"
  hr
  if [[ "${CCA_LAB_ASSUME_YES:-}" != "1" ]]; then
    read -r -p "Type BREAK to continue: " answer
    [[ "$answer" == "BREAK" ]] || die "cancelled"
  fi
  case "$scenario" in
    1) break_1 ;;
    2) break_2 ;;
    3) break_3 ;;
    *) die "no such scenario: ${scenario} (valid: 1, 2, 3)" ;;
  esac
}

cmd_brief() {
  state_load; detect_cilium
  case "${SCENARIO:-0}" in
    1) brief_1 ;; 2) brief_2 ;; 3) brief_3 ;;
    *) log "no fault is active. Run '$0 break --scenario <1|2|3>'." ;;
  esac
}

cmd_verify() {
  state_load; detect_cilium
  local rc=0
  hr
  case "${SCENARIO:-0}" in
    1) verify_1 || rc=1 ;;
    2) verify_2 || rc=1 ;;
    3) verify_3 || rc=1 ;;
    *) log "no fault is active — nothing to verify"; hr; return 0 ;;
  esac
  hr
  if [[ $rc -eq 0 ]]; then
    ok "INCIDENT ${SCENARIO} RESOLVED. Write down the one-line root cause before moving on."
    state_set SCENARIO 0
  else
    err "not fixed yet. Re-read the brief: $0 brief"
  fi
  return $rc
}

cmd_status() {
  state_load; detect_cilium
  local pod
  hr; log "Kubernetes view"
  kubectl -n "$LAB_NS" get pods -o wide 2>/dev/null | sed 's/^/       /' || true
  kubectl -n "$LAB_NS" get svc,endpointslices 2>/dev/null | sed 's/^/       /' || true
  hr; log "Cilium datapath view"
  for pod in $(cilium_pods); do
    printf '       %s\n' "${C_BLD}${pod}${C_OFF}"
    cx "$pod" status --brief 2>/dev/null | sed 's/^/       | /' || true
    cx "$pod" status --verbose 2>/dev/null | grep -i '^Masquerading' | sed 's/^/       | /' || true
    cx "$pod" service list 2>/dev/null | grep -E "^ID|${SVC_CLUSTER_IP:-@@}" | sed 's/^/       | /' || true
  done
  hr; log "Recent dropped flows (Hubble, if enabled)"
  for pod in $(cilium_pods); do
    kubectl -n "$CILIUM_NS" exec "$pod" -c cilium-agent -- \
      hubble observe --verdict DROPPED --last 10 2>/dev/null | sed 's/^/       | /' || \
      printf '       | hubble unavailable in %s\n' "$pod"
  done
  hr
}

cmd_reset() {
  state_load; detect_cilium
  warn "reset undoes the fault for you — only use it if you are truly stuck"
  case "${SCENARIO:-0}" in
    1) reset_1 ;; 2) reset_2 ;; 3) reset_3 ;;
    *) log "no fault is active"; return 0 ;;
  esac
  state_set SCENARIO 0
  sleep 5
  [[ "$(http_code_svc)" == "200" ]] && ok "baseline restored" || warn "baseline not fully restored — check '$0 status'"
}

cmd_cleanup() {
  kubectl delete ns "$LAB_NS" --ignore-not-found --wait=false >/dev/null
  rm -rf "$STATE_DIR"
  ok "lab namespace deleted and state removed"
}

usage() {
  cat <<TXT
CCA 3.1 — Kubernetes Networking with Cilium — break & fix lab

Usage: $0 <command> [options]

  setup                 deploy the lab workload and record a healthy baseline
  break -s <1|2|3>      inject a fault (default 1) and print the incident brief
  brief                 re-print the brief for the active fault
  verify                check whether your fix meets the success criteria
  status                dump control-plane + datapath state (no hints)
  reset                 undo the active fault (spoiler; last resort)
  cleanup               delete the lab namespace and local state

Faults
  1  eBPF load-balancer entry deleted   — ClusterIP dead, Endpoints healthy
  2  masquerading disabled              — east-west fine, egress dead
  3  CNI plugin binary renamed          — running Pods fine, no new Pod starts

Environment
  LAB_NS=${LAB_NS}  CILIUM_NS=${CILIUM_NS}  EXTERNAL_TARGET=${EXTERNAL_TARGET}
  CLIENT_IMAGE=${CLIENT_IMAGE}  WEB_IMAGE=${WEB_IMAGE}  TOOL_IMAGE=${TOOL_IMAGE}
  CCA_LAB_FORCE=yes-destroy-this-cluster   run outside an auto-approved lab context
  CCA_LAB_ASSUME_YES=1                     skip the interactive BREAK confirmation
TXT
}

main() {
  need_bin kubectl
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    setup)   cmd_setup "$@" ;;
    break)   cmd_break "$@" ;;
    brief)   cmd_brief "$@" ;;
    verify)  cmd_verify "$@" ;;
    status)  cmd_status "$@" ;;
    reset)   cmd_reset "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

# =============================================================================
# ==  SOLUTION — DO NOT READ UNTIL YOU HAVE SOLVED THE INCIDENT              ==
# =============================================================================
#
# -----------------------------------------------------------------------------
# INCIDENT 1 — eBPF LB entry deleted (ClusterIP dead, Endpoints healthy)
# -----------------------------------------------------------------------------
# Root cause in one line:
#   With kube-proxy replacement, Service forwarding lives in the cilium_lb4_*
#   eBPF maps. The Kubernetes Service/EndpointSlice objects are only the DESIRED
#   state; the agent programs the maps. The frontend entry was removed from the
#   map, so the socket-LB / tail-call translation from ClusterIP to a backend no
#   longer has a mapping. Packets to the ClusterIP are dropped in the datapath
#   while every control-plane object still reports Healthy.
#
# Step 1 — separate control plane from datapath. Control plane is fine:
#   kubectl -n cca-lab get svc web -o wide
#   kubectl -n cca-lab get endpointslices -l kubernetes.io/service-name=web -o wide
#   # 2 Ready backend addresses -> the Service selector and readiness are correct.
#
# Step 2 — prove the datapath disagrees. This is the decisive command:
#   CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium -o name | head -1)
#   kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg service list
#   # The frontend <ClusterIP>:80/TCP is ABSENT, while kube-dns, kubernetes and
#   # every other Service are listed. Confirm at the map level:
#   kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg bpf lb list | grep <ClusterIP>
#
# Step 3 — confirm the verdict on the wire:
#   kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
#       hubble observe --from-pod cca-lab/client --verdict DROPPED --last 20
#   # Look for the drop reason pointing at a missing service translation. Note
#   # that direct Pod-IP traffic is FORWARDED — only the ClusterIP path fails.
#
# Step 4 — fix by forcing a full resync from the API server. The agent rebuilds
#   the LB maps from the watched Service/EndpointSlice state at startup:
#     kubectl -n kube-system rollout restart ds/cilium
#     kubectl -n kube-system rollout status ds/cilium --timeout=300s
#   Surgical alternative, without restarting the agent (useful when the node is
#   carrying production traffic) — re-create the frontend from the known backends:
#     kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg service update \
#         --frontend <ClusterIP>:80 --backends <podIP1>:80,<podIP2>:80 --k8s-cluster-internal
#   Third option: touch the Service so the watcher emits an update event
#   (e.g. add a harmless annotation) and the agent reprograms the frontend:
#     kubectl -n cca-lab annotate svc web cca-lab/resync="$(date +%s)" --overwrite
#   All three keep the Service UID intact. Deleting and recreating the Service
#   also "works" and is exactly what the verify step rejects: in production it
#   would change the ClusterIP and break every client holding a cached DNS answer.
#
# Step 5 — verify:
#   kubectl -n cca-lab exec deploy/client -- curl -sS -o /dev/null -w '%{http_code}\n' \
#       http://web.cca-lab.svc.cluster.local/
#   kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg service list | grep <ClusterIP>
#
# Exam takeaway: when a Service is unreachable, ask "is the frontend programmed
# in the datapath?" before touching the Service object. cilium-dbg service list
# and cilium-dbg bpf lb list are the source of truth for forwarding; kubectl is not.
#
# -----------------------------------------------------------------------------
# INCIDENT 2 — masquerading disabled (east-west fine, egress dead)
# -----------------------------------------------------------------------------
# Root cause in one line:
#   enable-ipv4-masquerade=false in the cilium-config ConfigMap. Packets leaving
#   the node keep their Pod CIDR source address; the upstream router has no route
#   back to that prefix, so replies never return — a one-way blackhole that looks
#   like a firewall drop.
#
# Step 1 — characterise the blast radius. Pod->Pod and Pod->ClusterIP work, DNS
#   works, only off-cluster destinations fail, and the same request from the node
#   succeeds. That combination points at SNAT on egress, not at policy (a policy
#   drop would show up in Hubble as DROPPED with a Policy denied reason) and not
#   at DNS (name resolution still succeeds).
#
# Step 2 — read the agent's live state rather than the Helm values:
#   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -iA2 Masquerading
#   # Healthy node:  Masquerading:  BPF   [eth0]  10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
#   # Broken node:   Masquerading:  Disabled
#   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg config | grep -i masq
#   kubectl -n kube-system get cm cilium-config -o yaml | grep -i masq
#
# Step 3 — see it on the wire (the source address is the proof):
#   kubectl -n cca-lab exec deploy/client -- \
#       tcpdump -ni any host 1.1.1.1 and tcp port 80 -c 5
#   # SYN leaves with a Pod IP as source and nothing ever comes back.
#   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf nat list | head
#   # No NAT entries created for the egress flow when BPF masquerading is off.
#
# Step 4 — fix at the source of truth, then roll the agents:
#   kubectl -n kube-system patch cm cilium-config --type merge \
#       -p '{"data":{"enable-ipv4-masquerade":"true","enable-bpf-masquerade":"true"}}'
#   kubectl -n kube-system rollout restart ds/cilium
#   kubectl -n kube-system rollout status ds/cilium --timeout=300s
#   In a Helm-managed cluster the durable fix is the values file, otherwise the
#   next 'helm upgrade' reintroduces the outage:
#       helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
#            --set enableIPv4Masquerade=true --set bpf.masquerade=true
#   Do NOT "fix" this with a hand-written iptables MASQUERADE rule on the node:
#   it is invisible to the agent, survives no reboot, and will silently conflict
#   the day BPF masquerading is turned back on.
#
# Step 5 — verify:
#   kubectl -n cca-lab exec deploy/client -- curl -sS -o /dev/null -w '%{http_code}\n' http://1.1.1.1/
#   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -i Masquerading
#
# Exam takeaway: know the three egress knobs and how they interact —
#   enableIPv4Masquerade (do SNAT at all), bpf.masquerade (do it in eBPF instead
#   of iptables), and ipMasqAgent/nonMasqueradeCIDRs (which destinations are
#   exempt). Also remember masquerading is skipped for destinations inside the
#   cluster CIDR, which is exactly why east-west traffic survived.
#
# -----------------------------------------------------------------------------
# INCIDENT 3 — CNI plugin binary renamed (running Pods fine, no new Pod starts)
# -----------------------------------------------------------------------------
# Root cause in one line:
#   /opt/cni/bin/cilium-cni was renamed. kubelet reads the network config from
#   /etc/cni/net.d/05-cilium.conflist, then executes the plugin named in it from
#   the CNI bin dir; the binary is missing, so every CreatePodSandbox call fails
#   and Pods never leave ContainerCreating. Already-running Pods are untouched
#   because CNI ADD only runs at sandbox creation.
#
# Step 1 — read the kubelet event verbatim, do not paraphrase it:
#   kubectl -n cca-lab describe pod -l app=canary | sed -n '/Events/,$p'
#   # network: failed to find plugin "cilium-cni" in path [/opt/cni/bin]
#   # (the sibling failure mode, worth recognising, is
#   #  "no networks found in /etc/cni/net.d" -> the CONFIG is missing, not the binary)
#
# Step 2 — inspect the node without a working CNI. hostNetwork Pods do not need
#   the plugin, which is why 'kubectl debug node/...' still works:
#   NODE=$(kubectl -n cca-lab get pod -l app=client -o jsonpath='{.items[0].spec.nodeName}')
#   kubectl debug node/$NODE -it --image=busybox:1.36 -- ls -la /host/opt/cni/bin /host/etc/cni/net.d
#   # on kind:  docker exec ${NODE} ls -la /opt/cni/bin /etc/cni/net.d
#   # cilium-cni.cca-lab-disabled is present; cilium-cni is not.
#
# Step 3 — identify who owns those files. The agent DaemonSet ships them:
#   kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.initContainers[*].name}'
#   # ... install-cni-binaries ...   copies cilium-cni into the host CNI bin dir
#   kubectl -n kube-system logs ds/cilium -c install-cni-binaries
#   # The agent itself writes 05-cilium.conflist when it is ready
#   # (--write-cni-conf-when-ready), which is why restarting it repairs BOTH files.
#
# Step 4 — fix by restarting the DaemonSet so the init container reinstalls the plugin:
#   kubectl -n kube-system rollout restart ds/cilium
#   kubectl -n kube-system rollout status ds/cilium --timeout=300s
#   kubectl -n cca-lab rollout status deploy/canary --timeout=180s
#   This works because the agent Pod is hostNetwork: true and therefore does not
#   itself require the CNI plugin to start — the property that makes CNI
#   DaemonSets self-healing. If the binary had been renamed rather than deleted
#   and you wanted to avoid the restart, the equivalent manual repair is a
#   privileged hostNetwork Pod mounting hostPath /opt/cni/bin that moves it back.
#   Pods already stuck in ContainerCreating retry the sandbox automatically; you
#   do not need to delete them, though 'kubectl delete pod' speeds it up.
#
# Step 5 — verify:
#   kubectl -n cca-lab get pods -o wide      # canary Running/Ready with its own Pod IP
#   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
#
# Exam takeaway: the CNI contract has exactly two node-local dependencies —
#   the config in /etc/cni/net.d and the binary in /opt/cni/bin. "Old Pods work,
#   new Pods hang in ContainerCreating" is the signature of that pair being
#   broken, and it is never a NetworkPolicy, never DNS, and never the Service.
# =============================================================================