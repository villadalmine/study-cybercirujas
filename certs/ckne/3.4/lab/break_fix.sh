#!/usr/bin/env bash
# =============================================================================
# CKNE 3.4 - Implementing Cross Cluster Service Discovery and Load Balancing
# BREAK & FIX LAB: "The failover that never happened"
# =============================================================================
#
# RUN THIS ONLY ON A DISPOSABLE LAB VM. It creates and changes two local kind
# clusters named "ckne-east" and "ckne-west". It never touches any other
# kubeconfig context. Your real clusters are safe.
#
# Requirements on the VM:
#   - docker (or podman with kind support), kind >= 0.20, kubectl, cilium CLI >= 0.16
#   - about 4 vCPU / 6 GB RAM for two single-node clusters
#   - if kind nodes crash-loop, raise the inotify limits first:
#       sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
#
# Usage:
#   ./break-fix-3.4.sh setup   # build both clusters + Cilium ClusterMesh (about 5-10 min)
#   ./break-fix-3.4.sh break   # deploy the app, prove the mesh works, then break it
#   ./break-fix-3.4.sh check   # check your fix
#   ./break-fix-3.4.sh reset   # delete both lab clusters
#
# Why this topic matters:
#   A "global" Service in Cilium ClusterMesh is one Service (same name + same
#   namespace) that exists in several clusters. Its ClusterIP load-balances
#   across healthy backends in every cluster that shares them. If the local
#   backends disappear, traffic fails over to remote clusters with no DNS
#   change: the client keeps calling echo.mcs-lab.svc.cluster.local.
#   The upstream Kubernetes version of the same idea is the Multi-Cluster
#   Services API (KEP-1645: ServiceExport / ServiceImport, domain clusterset.local).
#
# References:
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/
#   https://docs.cilium.io/en/stable/network/clustermesh/services/
#   https://github.com/kubernetes/enhancements/tree/master/keps/sig-multicluster/1645-multi-cluster-services-api
#   https://kind.sigs.k8s.io/docs/user/configuration/
# =============================================================================

set -euo pipefail

EAST_NAME="ckne-east"
WEST_NAME="ckne-west"
EAST="kind-${EAST_NAME}"
WEST="kind-${WEST_NAME}"
NS="mcs-lab"
URL="http://echo.${NS}.svc.cluster.local"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_off=$'\e[0m'
log()  { echo "${c_cyn}[lab]${c_off} $*"; }
ok()   { echo "${c_grn}[ OK ]${c_off} $*"; }
warn() { echo "${c_ylw}[WARN]${c_off} $*"; }
fail() { echo "${c_red}[FAIL]${c_off} $*"; }
die()  { fail "$*"; exit 1; }

need() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "Missing required binary: $bin"
  done
}

context_exists() {
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$1"
}

guard_contexts() {
  # Safety: work only against the two lab contexts this script created.
  context_exists "$EAST" || die "Context $EAST not found. Run: $0 setup"
  context_exists "$WEST" || die "Context $WEST not found. Run: $0 setup"
}

# -----------------------------------------------------------------------------
# SETUP: two kind clusters with no default CNI, pod/service CIDRs that do not
# overlap, and Cilium with a unique cluster.name/cluster.id in each, joined by ClusterMesh.
# -----------------------------------------------------------------------------
create_kind_cluster() {
  local name="$1" pod_cidr="$2" svc_cidr="$3"
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    log "kind cluster $name already exists, skipping"
    return
  fi
  log "Creating kind cluster $name (pods $pod_cidr, services $svc_cidr)"
  kind create cluster --name "$name" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "${pod_cidr}"
  serviceSubnet: "${svc_cidr}"
nodes:
  - role: control-plane
EOF
}

install_cilium() {
  local ctx="$1" name="$2" id="$3"
  if kubectl --context "$ctx" -n kube-system get ds cilium >/dev/null 2>&1; then
    log "Cilium already installed in $ctx, skipping"
  else
    log "Installing Cilium in $ctx (cluster.name=$name cluster.id=$id)"
    cilium install --context "$ctx" \
      --set cluster.name="$name" \
      --set cluster.id="$id" \
      --set ipam.mode=kubernetes
  fi
  cilium status --context "$ctx" --wait
}

share_ca() {
  # ClusterMesh needs both clusters to trust the same CA. Copy the east CA to
  # west BEFORE Cilium is installed there (the Helm chart reuses an existing secret).
  if kubectl --context "$WEST" -n kube-system get secret cilium-ca >/dev/null 2>&1; then
    log "cilium-ca already present in $WEST, skipping"
    return
  fi
  log "Copying cilium-ca from $EAST to $WEST"
  kubectl --context "$EAST" -n kube-system get secret cilium-ca -o yaml \
    | grep -v -E '^\s*(resourceVersion|uid|creationTimestamp):' \
    | kubectl --context "$WEST" create -f -
}

do_setup() {
  need docker kind kubectl cilium
  create_kind_cluster "$EAST_NAME" "10.1.0.0/16" "10.11.0.0/16"
  create_kind_cluster "$WEST_NAME" "10.2.0.0/16" "10.12.0.0/16"

  install_cilium "$EAST" "$EAST_NAME" 1
  share_ca
  install_cilium "$WEST" "$WEST_NAME" 2

  for ctx in "$EAST" "$WEST"; do
    log "Enabling ClusterMesh in $ctx (clustermesh-apiserver exposed as NodePort)"
    cilium clustermesh enable --context "$ctx" --service-type NodePort || true
    cilium clustermesh status --context "$ctx" --wait
  done

  log "Connecting $EAST <-> $WEST"
  cilium clustermesh connect --context "$EAST" --destination-context "$WEST" || true
  cilium clustermesh status --context "$EAST" --wait
  ok "Lab infrastructure ready. Now run: $0 break"
}

# -----------------------------------------------------------------------------
# APPLICATION
# -----------------------------------------------------------------------------
apply_namespace() {
  local ctx="$1"
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
EOF
}

apply_backend() {
  local ctx="$1" cluster="$2" replicas="$3"
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: ${NS}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0
          args:
            - "-listen=:8080"
            - "-text=served-by-${cluster}"
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            periodSeconds: 3
EOF
}

# Healthy global Service: same name and namespace in both clusters.
apply_global_service() {
  local ctx="$1"
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: ${NS}
  annotations:
    service.cilium.io/global: "true"
spec:
  selector:
    app: echo
  ports:
    - name: http
      port: 80
      targetPort: 8080
EOF
}

apply_client() {
  kubectl --context "$EAST" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: ${NS}
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
        - name: curl
          image: curlimages/curl:8.10.1
          command: ["sleep", "infinity"]
EOF
}

# Calls the global service from a client in the EAST cluster N times and prints
# one line per response (or ERR).
probe() {
  local n="${1:-6}" i
  for i in $(seq 1 "$n"); do
    kubectl --context "$EAST" -n "$NS" exec deploy/client -- \
      curl -s --max-time 3 "$URL" 2>/dev/null || echo "ERR"
  done
}

wait_for_west_answer() {
  local tries="${1:-30}" i
  for i in $(seq 1 "$tries"); do
    if probe 1 | grep -q "served-by-${WEST_NAME}"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  need kubectl cilium
  guard_contexts

  log "Checking ClusterMesh health before starting"
  cilium clustermesh status --context "$EAST" --wait >/dev/null \
    || die "ClusterMesh is not healthy. Fix the lab first (or: $0 reset && $0 setup)."

  for ctx in "$EAST" "$WEST"; do apply_namespace "$ctx"; done
  apply_backend "$EAST" "$EAST_NAME" 2
  apply_backend "$WEST" "$WEST_NAME" 2
  apply_global_service "$EAST"
  apply_global_service "$WEST"
  apply_client

  for ctx in "$EAST" "$WEST"; do
    kubectl --context "$ctx" -n "$NS" rollout status deploy/echo --timeout=180s
  done
  kubectl --context "$EAST" -n "$NS" rollout status deploy/client --timeout=180s

  # Baseline: prove the mesh really fails over BEFORE the fault is injected,
  # so the only thing wrong afterwards is what this script breaks.
  log "Baseline: scaling east backends to 0 and expecting failover to west"
  kubectl --context "$EAST" -n "$NS" scale deploy/echo --replicas=0
  if wait_for_west_answer 30; then
    ok "Baseline OK: east client reaches west backends through the global Service"
  else
    die "Baseline failed: the lab mesh is not working. This is an infra problem, not the exercise. Try: $0 reset && $0 setup"
  fi

  # ---------------- THE FAULT (applied in WEST only) ----------------
  log "Injecting the fault..."
  kubectl --context "$WEST" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: ${NS}
  annotations:
    service.cilium.io/global: "true"
    service.cilium.io/shared: "false"
spec:
  selector:
    app: echo-backend
  ports:
    - name: http
      port: 80
      targetPort: 8080
EOF
  sleep 5

  clear || true
  cat <<EOF
${c_red}=====================================================================
 INCIDENT: east lost its backends and the failover did not happen
=====================================================================${c_off}

 Topology
   - Two clusters joined by Cilium ClusterMesh:  ${EAST}  and  ${WEST}
   - Namespace: ${NS}
   - Service  : echo (should be a GLOBAL service in both clusters)
   - Client   : deploy/client in ${EAST}, calling ${URL}

 What happened
   The east "echo" Deployment is at 0 replicas (a simulated regional outage).
   The design says traffic must fail over to the west backends through the
   same Service name. It did not. Someone "tuned" the west Service last night.

 The symptom you will see
   kubectl --context ${EAST} -n ${NS} exec deploy/client -- curl -s --max-time 3 ${URL}
     -> empty response / timeout (curl exit code 28), no "served-by-${WEST_NAME}"

 Your goal
   1. From the east client, ${URL} must answer "served-by-${WEST_NAME}".
   2. The east Deployment MUST STAY at 0 replicas. Scaling east back up
      hides the incident and does not count as a fix.
   3. Do not delete or rename the Service, and do not change the client.
   4. Fix only in ${WEST}. There is more than one problem.

 Useful places to look
   cilium clustermesh status --context ${EAST}
   kubectl --context ${WEST} -n ${NS} get svc echo -o yaml
   kubectl --context ${WEST} -n ${NS} get endpointslices -l kubernetes.io/service-name=echo
   kubectl --context ${EAST} -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list

 When you think it is fixed:   $0 check
EOF
  echo
  log "Current symptom (6 probes from east):"
  probe 6 | sed 's/^/    /'
}

# -----------------------------------------------------------------------------
# CHECK
# -----------------------------------------------------------------------------
do_check() {
  need kubectl cilium
  guard_contexts
  local errors=0

  local east_replicas
  east_replicas="$(kubectl --context "$EAST" -n "$NS" get deploy echo -o jsonpath='{.spec.replicas}')"
  if [[ "$east_replicas" == "0" ]]; then
    ok "East backends are still at 0 replicas (the outage is still simulated)"
  else
    fail "East echo has $east_replicas replicas. Scale it back to 0: failover must work WITHOUT local backends"
    errors=$((errors + 1))
  fi

  if cilium clustermesh status --context "$EAST" >/dev/null 2>&1; then
    ok "ClusterMesh reports healthy from $EAST"
  else
    fail "ClusterMesh is unhealthy from $EAST"
    errors=$((errors + 1))
  fi

  local global shared
  global="$(kubectl --context "$WEST" -n "$NS" get svc echo -o jsonpath='{.metadata.annotations.service\.cilium\.io/global}')"
  shared="$(kubectl --context "$WEST" -n "$NS" get svc echo -o jsonpath='{.metadata.annotations.service\.cilium\.io/shared}')"
  if [[ "$global" == "true" && "$shared" != "false" ]]; then
    ok "West Service is global and shares its backends (global=$global shared=${shared:-<default true>})"
  else
    fail "West Service does not export backends to the mesh (global=${global:-<unset>} shared=${shared:-<unset>})"
    errors=$((errors + 1))
  fi

  local ready
  ready="$(kubectl --context "$WEST" -n "$NS" get endpointslices \
    -l kubernetes.io/service-name=echo \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' | grep -c '^true$' || true)"
  if [[ "${ready:-0}" -ge 1 ]]; then
    ok "West Service has $ready ready local endpoint(s)"
  else
    fail "West Service has no ready endpoints: its selector matches no Pod"
    errors=$((errors + 1))
  fi

  log "Probing ${URL} from the east client (waiting up to 60s for mesh sync)..."
  if wait_for_west_answer 30; then
    local out
    out="$(probe 6)"
    echo "$out" | sed 's/^/    /'
    if echo "$out" | grep -q "ERR"; then
      fail "Some requests still fail"
      errors=$((errors + 1))
    else
      ok "Cross-cluster failover works: every request was served by ${WEST_NAME}"
    fi
  else
    fail "The east client still cannot reach west backends"
    errors=$((errors + 1))
  fi

  echo
  if [[ "$errors" -eq 0 ]]; then
    ok "LAB PASSED."
    echo "   Bonus: scale east back to 2 and run the probe 20 times. With both clusters"
    echo "   healthy the global Service load-balances across BOTH (east and west answers)."
    echo "   Then annotate the east Service with service.cilium.io/affinity=local and see the difference."
  else
    fail "LAB NOT PASSED ($errors problem(s) left)."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# RESET
# -----------------------------------------------------------------------------
do_reset() {
  need kind
  for c in "$EAST_NAME" "$WEST_NAME"; do
    if kind get clusters 2>/dev/null | grep -qx "$c"; then
      log "Deleting kind cluster $c"
      kind delete cluster --name "$c"
    fi
  done
  ok "Lab removed."
}

case "${1:-}" in
  setup) do_setup ;;
  break) do_break ;;
  check) do_check ;;
  reset) do_reset ;;
  *) echo "Usage: $0 {setup|break|check|reset}"; exit 2 ;;
esac

# =============================================================================
# SOLUTION (read only after you have tried)
# =============================================================================
#
# --- Step 0: rule out the mesh itself ---------------------------------------
#   cilium clustermesh status --context kind-ckne-east
#   Expected: "All 1 nodes are connected to all clusters", "ckne-west: ready".
#   The control plane is fine, so the problem is in what west publishes to the mesh.
#
# --- Step 1: ask the east datapath which backends it knows about ------------
#   kubectl --context kind-ckne-east -n mcs-lab get svc echo -o jsonpath='{.spec.clusterIP}'
#   kubectl --context kind-ckne-east -n kube-system exec ds/cilium -c cilium-agent -- \
#     cilium-dbg service list
#   Find the row whose frontend is <east ClusterIP>:80. It has NO backends
#   (or none with a 10.2.x.x west pod IP). East kube-proxy-replacement has
#   nothing to send the traffic to, so curl times out.
#   With a working setup you would see west pod IPs (10.2.x.x:8080) there, because
#   Cilium merges remote backends into the local ClusterIP for global services.
#
# --- Step 2: inspect the west Service ---------------------------------------
#   kubectl --context kind-ckne-west -n mcs-lab get svc echo -o yaml
#     annotations:
#       service.cilium.io/global: "true"
#       service.cilium.io/shared: "false"      <-- FAULT 1
#     selector:
#       app: echo-backend                      <-- FAULT 2
#
#   FAULT 1: global="true" makes the Service part of the global service, but
#   shared="false" means "consume remote backends, do NOT export mine".
#   West can still reach east, but east never learns about west pods.
#   The shared annotation defaults to true when global is true.
#
#   FAULT 2: the selector does not match the pods (label app=echo), so west has
#   no local endpoints. Even with sharing on, it would export an empty set.
#   ClusterMesh shares endpoints, not Service definitions: no endpoints, no failover.
#
#   kubectl --context kind-ckne-west -n mcs-lab get endpointslices \
#     -l kubernetes.io/service-name=echo
#   -> ENDPOINTS <unset>   (confirms FAULT 2)
#   kubectl --context kind-ckne-west -n mcs-lab get pods --show-labels
#   -> app=echo            (the label the selector should use)
#
# --- Step 3: fix the selector -----------------------------------------------
#   kubectl --context kind-ckne-west -n mcs-lab patch svc echo \
#     --type merge -p '{"spec":{"selector":{"app":"echo"}}}'
#   kubectl --context kind-ckne-west -n mcs-lab get endpointslices \
#     -l kubernetes.io/service-name=echo
#   -> ENDPOINTS 10.2.0.x:8080,10.2.0.y:8080
#
# --- Step 4: share the west backends again -----------------------------------
#   Remove the annotation (default is shared) ...
#   kubectl --context kind-ckne-west -n mcs-lab annotate svc echo service.cilium.io/shared-
#   ... or set it explicitly:
#   kubectl --context kind-ckne-west -n mcs-lab annotate svc echo \
#     service.cilium.io/shared="true" --overwrite
#
# --- Step 5: verify from the east side ---------------------------------------
#   kubectl --context kind-ckne-east -n kube-system exec ds/cilium -c cilium-agent -- \
#     cilium-dbg service list
#   -> the echo frontend now lists 10.2.x.x:8080 backends (west pods)
#
#   kubectl --context kind-ckne-east -n mcs-lab exec deploy/client -- \
#     curl -s http://echo.mcs-lab.svc.cluster.local
#   -> served-by-ckne-west
#
#   ./break-fix-3.4.sh check    -> LAB PASSED.
#
# --- Key points for the exam -------------------------------------------------
#   * Global services are matched by NAME + NAMESPACE in every cluster. A typo in
#     either one silently creates two unrelated local services.
#   * service.cilium.io/global  = join the global service.
#     service.cilium.io/shared  = export (true, the default) or only consume (false).
#     service.cilium.io/affinity= local | remote | none: which backends are preferred
#     when both are healthy (local = use remote only as failover).
#   * DNS does not change: the client resolves the LOCAL ClusterIP and the eBPF
#     datapath picks local or remote backends. The cross-cluster "discovery" is
#     the endpoint sync through clustermesh-apiserver (etcd), not CoreDNS.
#   * Prerequisites that break a mesh before any Service does: unique cluster.id
#     and cluster.name, pod CIDRs that do not overlap, a shared or trusted CA, and
#     node-to-node reachability to the clustermesh-apiserver port.
#   * Upstream equivalent (KEP-1645, MCS API): export with a ServiceExport object
#     named like the Service; consumers get a ServiceImport and resolve
#     <svc>.<ns>.svc.clusterset.local. The same principle applies: "exported but
#     no ready endpoints" means the name resolves and the traffic has nowhere to go.
# =============================================================================