#!/usr/bin/env bash
# =============================================================================
# CKNE 1.5 - Configuring Multi-interface Pods - BREAK & FIX LAB
# =============================================================================
#
# What this lab does
# ------------------
# It deploys two Pods that are supposed to share a secondary "storage" network
# (net1, 10.10.0.0/24) through Multus and a NetworkAttachmentDefinition (NAD).
# It plants THREE controlled faults, each with a different symptom:
#
#   * one Pod never leaves ContainerCreating;
#   * once that is fixed, it is STILL stuck, with a different error;
#   * the other Pod is Running and looks healthy, but it silently has no net1.
#
# The last one is the dangerous kind: nothing goes red, and the Pod quietly
# runs without the network it depends on.
#
# Safety
# ------
#   * Everything lives in ONE dedicated namespace (ckne-lab-1-5), labeled
#     lab=ckne-1-5. Cleanup deletes only that namespace, and only if the
#     label is present.
#   * No node configuration is changed. The bridge CNI plugin creates a Linux
#     bridge (br-ckne15) on the node when the first Pod attaches. It does not
#     touch any physical interface or the Pod network.
#   * It asks for confirmation before acting on the current kubectl context.
#     Use it ONLY on a disposable lab cluster (kind, kubeadm VM, minikube).
#
# Requirements
# ------------
#   * kubectl pointing at a disposable lab cluster.
#   * Multus installed (thick plugin recommended):
#       kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
#   * The reference CNI plugins ("bridge", "host-local") present in
#     /opt/cni/bin on the nodes: https://github.com/containernetworking/plugins
#
# Usage
# -----
#   ./break-fix-1.5.sh break     # deploy the broken scenario (default)
#   ./break-fix-1.5.sh check     # verify your fix
#   ./break-fix-1.5.sh hint      # get one hint per fault
#   ./break-fix-1.5.sh cleanup   # delete everything the lab created
#
#   LAB_ASSUME_YES=1 skips the confirmation prompt.
#
# References
# ----------
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/how-to-use.md
#   https://github.com/k8snetworkplumbingwg/multi-net-spec
#   https://www.cni.dev/plugins/current/main/bridge/
#   https://www.cni.dev/plugins/current/ipam/host-local/
# =============================================================================

set -euo pipefail

NS="ckne-lab-1-5"
LAB_LABEL="lab=ckne-1-5"
WORKDIR="${WORKDIR:-/tmp/ckne-lab-1-5}"
NAD_NAME="storage-network"
SUBNET_PREFIX="10.10.0."
IMAGE="busybox:1.36"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."

  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "Cannot reach the API server. Check your kubeconfig / tunnel."

  if ! kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1; then
    red "The NetworkAttachmentDefinition CRD is not installed: Multus is missing."
    echo "Install it first (thick plugin):"
    echo "  kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml"
    echo "  kubectl -n kube-system rollout status ds/kube-multus-ds"
    exit 1
  fi

  if ! kubectl get pods -A -l app=multus --no-headers 2>/dev/null | grep -q Running; then
    yellow "WARNING: no Running Multus pod found with label app=multus."
    yellow "         The lab may fail for reasons that are not the planted faults."
  fi
}

confirm_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  bold "Current kubectl context: ${ctx}"
  if [[ "${LAB_ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "This must be a DISPOSABLE lab cluster. Continue? [yes/N] " ans
    [[ "${ans}" == "yes" ]] || die "Aborted by user."
  fi
}

pick_node() {
  # Both Pods go on the same node on purpose: the bridge plugin is node-local,
  # so two Pods on different nodes would share a subnet but no L2 segment.
  kubectl get nodes \
    -o jsonpath='{range .items[?(@.spec.unschedulable!=true)]}{.metadata.name}{"\n"}{end}' \
    | while read -r n; do
        # Skip nodes carrying a NoSchedule taint (e.g. control plane on kubeadm).
        if ! kubectl get node "$n" -o jsonpath='{.spec.taints[*].effect}' | grep -q NoSchedule; then
          echo "$n"; break
        fi
      done
}

# -----------------------------------------------------------------------------
# Break
# -----------------------------------------------------------------------------
do_break() {
  preflight
  confirm_context

  local node
  node="$(pick_node)"
  [[ -n "${node}" ]] || die "No schedulable untainted node found."
  bold "Pinning lab Pods to node: ${node}"

  if kubectl get ns "${NS}" >/dev/null 2>&1; then
    yellow "Namespace ${NS} already exists. Recreating it from scratch..."
    do_cleanup_quiet
  fi

  mkdir -p "${WORKDIR}"

  kubectl create namespace "${NS}" >/dev/null
  kubectl label namespace "${NS}" "${LAB_LABEL}" --overwrite >/dev/null

  # --- NetworkAttachmentDefinition -------------------------------------------
  # FAULT #2 is in here (host-local IPAM range).
  cat > "${WORKDIR}/nad.yaml" <<'EOF'
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: storage-network
  namespace: ckne-lab-1-5
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "storage-network",
      "type": "bridge",
      "bridge": "br-ckne15",
      "isGateway": false,
      "ipMasq": false,
      "ipam": {
        "type": "host-local",
        "subnet": "10.10.0.0/24",
        "rangeStart": "10.10.1.10",
        "rangeEnd": "10.10.0.50"
      }
    }
EOF

  # --- Pod app-a -------------------------------------------------------------
  # FAULT #1 is in here (network name in the annotation).
  cat > "${WORKDIR}/app-a.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: app-a
  namespace: ${NS}
  labels:
    app: storage-client
  annotations:
    k8s.v1.cni.cncf.io/networks: storage-net
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  terminationGracePeriodSeconds: 1
  containers:
    - name: shell
      image: ${IMAGE}
      command: ["sh", "-c", "sleep 36000"]
EOF

  # --- Pod app-b -------------------------------------------------------------
  # FAULT #3 is in here (annotation key).
  cat > "${WORKDIR}/app-b.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: app-b
  namespace: ${NS}
  labels:
    app: storage-server
  annotations:
    k8s.v1.cni.cncf.io/network: storage-network
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  terminationGracePeriodSeconds: 1
  containers:
    - name: shell
      image: ${IMAGE}
      command: ["sh", "-c", "sleep 36000"]
EOF

  kubectl apply -f "${WORKDIR}/nad.yaml" >/dev/null
  kubectl apply -f "${WORKDIR}/app-a.yaml" >/dev/null
  kubectl apply -f "${WORKDIR}/app-b.yaml" >/dev/null

  echo
  bold "Waiting ~30s for the Pods to settle..."
  kubectl -n "${NS}" wait --for=condition=Ready pod/app-b --timeout=60s >/dev/null 2>&1 || true
  sleep 15

  echo
  kubectl -n "${NS}" get pods -o wide || true
  echo

  cat <<EOF
=============================================================================
 THE SCENARIO
=============================================================================
 The storage team needs two Pods, app-a and app-b, to talk to each other over
 a dedicated secondary interface, net1, on 10.10.0.0/24. That network is
 described by the NetworkAttachmentDefinition "${NAD_NAME}" in namespace
 ${NS}, and Multus should attach it as net1 in both Pods.

 WHAT YOU WILL SEE
 -----------------
  * app-a is stuck in ContainerCreating. 'kubectl describe' shows
    FailedCreatePodSandBox events that come from Multus.
  * app-b is Running and looks fine. Look inside it anyway.

 YOUR GOAL
 ---------
  1. app-a and app-b are both Running.
  2. Both Pods have an interface named net1 with an IPv4 address in
     ${SUBNET_PREFIX}10 - ${SUBNET_PREFIX}50.
  3. The k8s.v1.cni.cncf.io/network-status annotation of each Pod lists
     ${NS}/${NAD_NAME}.
  4. app-a can ping app-b's net1 address.

 RULES
 -----
  * Do not change the node, the Multus DaemonSet or the Pod network.
  * The manifests are in ${WORKDIR}/ - edit them, do not start over.
  * There is more than one fault. Fixing one can reveal the next.

 USEFUL COMMANDS
 ---------------
  kubectl -n ${NS} describe pod app-a
  kubectl -n ${NS} get events --sort-by=.lastTimestamp
  kubectl -n ${NS} get net-attach-def
  kubectl -n ${NS} get net-attach-def ${NAD_NAME} -o jsonpath='{.spec.config}'
  kubectl -n ${NS} exec app-b -- ip -4 addr
  kubectl -n ${NS} get pod app-b -o jsonpath='{.metadata.annotations}'

  When you think you are done:   $0 check
  Stuck?                         $0 hint
  Finished:                      $0 cleanup
=============================================================================
EOF
}

# -----------------------------------------------------------------------------
# Check
# -----------------------------------------------------------------------------
net1_ip() {
  kubectl -n "${NS}" exec "$1" -- sh -c \
    "ip -4 -o addr show dev net1 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true
}

in_range() {
  local ip="$1" last
  [[ "${ip}" == ${SUBNET_PREFIX}* ]] || return 1
  last="${ip##*.}"
  (( last >= 10 && last <= 50 ))
}

do_check() {
  kubectl get ns "${NS}" >/dev/null 2>&1 || die "Namespace ${NS} not found. Run '$0 break' first."

  local fail=0 pod phase ip status ip_a ip_b

  bold "== 1. Pod phase"
  for pod in app-a app-b; do
    phase="$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
    if [[ "${phase}" == "Running" ]]; then
      green "  [OK]   ${pod} is Running"
    else
      red   "  [FAIL] ${pod} is ${phase}"
      fail=1
    fi
  done

  bold "== 2. net1 interface and address"
  for pod in app-a app-b; do
    ip="$(net1_ip "${pod}")"
    if [[ -z "${ip}" ]]; then
      red "  [FAIL] ${pod} has no net1 interface (or no IPv4 on it)"
      fail=1
    elif in_range "${ip}"; then
      green "  [OK]   ${pod} net1 = ${ip}"
    else
      red   "  [FAIL] ${pod} net1 = ${ip}, outside ${SUBNET_PREFIX}10-50"
      fail=1
    fi
  done

  bold "== 3. network-status annotation"
  for pod in app-a app-b; do
    status="$(kubectl -n "${NS}" get pod "${pod}" \
      -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null || true)"
    if grep -q "\"${NS}/${NAD_NAME}\"" <<<"${status}"; then
      green "  [OK]   ${pod} network-status lists ${NS}/${NAD_NAME}"
    else
      red   "  [FAIL] ${pod} network-status does not list ${NS}/${NAD_NAME}"
      fail=1
    fi
  done

  bold "== 4. L2 reachability over net1"
  ip_a="$(net1_ip app-a)"
  ip_b="$(net1_ip app-b)"
  if [[ -n "${ip_a}" && -n "${ip_b}" ]]; then
    if kubectl -n "${NS}" exec app-a -- ping -c 2 -W 2 -I net1 "${ip_b}" >/dev/null 2>&1; then
      green "  [OK]   app-a (${ip_a}) -> app-b (${ip_b}) over net1"
    else
      red   "  [FAIL] app-a cannot ping app-b (${ip_b}) over net1"
      fail=1
    fi
  else
    red "  [FAIL] skipped: at least one Pod has no net1 address"
    fail=1
  fi

  echo
  if (( fail == 0 )); then
    green "ALL CHECKS PASSED - the multi-interface Pods are correctly configured."
  else
    red "Not fixed yet. Run '$0 hint' if you are stuck."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Hints
# -----------------------------------------------------------------------------
do_hint() {
  cat <<'EOF'
HINT 1 (app-a, first error)
  Read the Multus error in 'kubectl describe pod app-a' word by word. It names
  the network it was asked for and the namespace it looked in. Compare that
  with 'kubectl get net-attach-def'.

HINT 2 (app-a, second error)
  The Multus error text changes: now it is the delegate plugin (bridge ->
  host-local) that fails. host-local validates rangeStart/rangeEnd against the
  subnet before it hands out any address. Is every address in the range inside
  10.10.0.0/24?

HINT 3 (app-b, silent)
  Multus reads exactly ONE annotation key to learn which extra networks a Pod
  wants. Any other key is just an ordinary annotation, so nothing fails and
  you get no event. Compare the key on app-b with the key on app-a.

HINT 4 (general)
  Multus acts only when the Pod sandbox is created. Editing a Pod's
  annotations, or the NAD, does NOTHING to an existing sandbox. What must
  happen to the Pods after you fix the config?
EOF
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
do_cleanup_quiet() {
  if kubectl get ns "${NS}" -l "${LAB_LABEL}" --no-headers 2>/dev/null | grep -q "${NS}"; then
    kubectl delete namespace "${NS}" --wait=true --timeout=120s >/dev/null
  elif kubectl get ns "${NS}" >/dev/null 2>&1; then
    die "Namespace ${NS} exists but lacks label ${LAB_LABEL}; refusing to delete it."
  fi
}

do_cleanup() {
  do_cleanup_quiet
  rm -rf "${WORKDIR}"
  green "Lab removed (namespace ${NS} and ${WORKDIR})."
  echo "Note: the node-local bridge br-ckne15 may remain on the node until reboot."
  echo "      It is harmless and has no attached ports. To remove it by hand, on the node:"
  echo "        sudo ip link delete br-ckne15"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
case "${1:-break}" in
  break)   do_break ;;
  check)   do_check ;;
  hint)    do_hint ;;
  cleanup) do_cleanup ;;
  *)       echo "Usage: $0 {break|check|hint|cleanup}"; exit 2 ;;
esac

# =============================================================================
# SOLUTION (step by step) - read it only after trying
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 - Observe before touching anything
# ---------------------------------------------------------------------------
#   kubectl -n ckne-lab-1-5 get pods -o wide
#     NAME    READY   STATUS              RESTARTS   AGE
#     app-a   0/1     ContainerCreating   0          40s
#     app-b   1/1     Running             0          40s
#
#   kubectl -n ckne-lab-1-5 describe pod app-a | sed -n '/Events:/,$p'
#     Warning  FailedCreatePodSandBox  ...  Failed to create pod sandbox: rpc error:
#       ... plugin type="multus-shim" name="multus-cni-network" failed (add):
#       ... error loading k8s delegates k8s args: TryLoadPodDelegates:
#       error in getting k8s network for pod: GetNetworkDelegates: failed
#       getting the delegate: getKubernetesDelegate: cannot find a
#       network-attachment-definition (storage-net) in namespace
#       (ckne-lab-1-5): network-attachment-definitions.k8s.cni.cncf.io
#       "storage-net" not found
#   (The exact wording varies across Multus versions and runtimes. The key
#    part is "cannot find a network-attachment-definition (storage-net)".)
#
#   The kubelet keeps retrying sandbox creation. It is the kubelet, through
#   the runtime, that calls the CNI chain: primary CNI first, then each
#   delegate Multus resolves from the annotation. If any delegate fails, the
#   WHOLE sandbox is torn down. That is why the Pod never reaches Running,
#   even though the primary network (eth0) would have worked.
#
# ---------------------------------------------------------------------------
# FAULT #1 - app-a references a NAD that does not exist
# ---------------------------------------------------------------------------
#   kubectl -n ckne-lab-1-5 get net-attach-def
#     NAME              AGE
#     storage-network   1m
#
#   The annotation asks for "storage-net". The NAD is "storage-network".
#   Multus resolves the name in the Pod's own namespace, unless you write
#   <namespace>/<name>. Fix the annotation in the manifest:
#
#     sed -i 's#k8s.v1.cni.cncf.io/networks: storage-net$#k8s.v1.cni.cncf.io/networks: storage-network#' \
#       /tmp/ckne-lab-1-5/app-a.yaml
#
#   Pod annotations are mutable, but Multus reads them only at sandbox
#   creation, so 'kubectl annotate' on the live Pod is not enough. Recreate
#   the Pod:
#
#     kubectl -n ckne-lab-1-5 delete pod app-a --wait=true
#     kubectl apply -f /tmp/ckne-lab-1-5/app-a.yaml
#
#   Still ContainerCreating, but the event is DIFFERENT now. That is progress.
#
# ---------------------------------------------------------------------------
# FAULT #2 - host-local IPAM range outside the subnet
# ---------------------------------------------------------------------------
#   kubectl -n ckne-lab-1-5 describe pod app-a | sed -n '/Events:/,$p'
#     Warning  FailedCreatePodSandBox ... [ckne-lab-1-5/app-a/...:storage-network]:
#       error adding container to network "storage-network": ... RangeStart
#       10.10.1.10 not in network 10.10.0.0/24
#   (Wording is approximate: the host-local plugin rejects the range.)
#
#   Now the NAD was found and Multus invoked the delegate (bridge), which
#   invoked its IPAM plugin (host-local), and host-local refused the config.
#   Read the config Multus actually passes:
#
#     kubectl -n ckne-lab-1-5 get net-attach-def storage-network \
#       -o jsonpath='{.spec.config}'
#
#   "rangeStart": "10.10.1.10" is in 10.10.1.0/24, not in 10.10.0.0/24.
#   Fix it:
#
#     sed -i 's#"rangeStart": "10.10.1.10"#"rangeStart": "10.10.0.10"#' \
#       /tmp/ckne-lab-1-5/nad.yaml
#     kubectl apply -f /tmp/ckne-lab-1-5/nad.yaml
#
#   Changing a NAD does not re-plumb existing Pods either. Recreate app-a
#   (or wait: the kubelet's next sandbox retry will read the new NAD, but
#   recreating is deterministic):
#
#     kubectl -n ckne-lab-1-5 delete pod app-a --wait=true
#     kubectl apply -f /tmp/ckne-lab-1-5/app-a.yaml
#     kubectl -n ckne-lab-1-5 wait --for=condition=Ready pod/app-a --timeout=60s
#
#     kubectl -n ckne-lab-1-5 exec app-a -- ip -4 -o addr show dev net1
#       3: net1    inet 10.10.0.10/24 brd 10.10.0.255 scope global net1
#
#   host-local keeps its allocations as files on the node, under
#   /var/lib/cni/networks/storage-network/ (one file per IP, containing the
#   container ID). That is where to look if IPs "leak" after unclean
#   teardowns.
#
# ---------------------------------------------------------------------------
# FAULT #3 - app-b uses the wrong annotation key (silent failure)
# ---------------------------------------------------------------------------
#   kubectl -n ckne-lab-1-5 exec app-b -- ip -4 -o addr
#     1: lo      inet 127.0.0.1/8 scope host lo
#     2: eth0    inet 10.244.1.23/24 ... eth0
#   -> no net1.
#
#   kubectl -n ckne-lab-1-5 get pod app-b \
#     -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
#   -> lists only the default network (e.g. "kindnet" or "cbr0"), no storage-network.
#
#   The key is "k8s.v1.cni.cncf.io/network" (singular). The multi-net spec
#   and Multus use "k8s.v1.cni.cncf.io/networks" (PLURAL). An unknown
#   annotation is not an error to the API server, and Multus never sees a
#   request for extra networks, so there is no event and no failure.
#   Only the network-status annotation, or looking inside the Pod, tells you.
#
#     sed -i 's#k8s.v1.cni.cncf.io/network: storage-network#k8s.v1.cni.cncf.io/networks: storage-network#' \
#       /tmp/ckne-lab-1-5/app-b.yaml
#     kubectl -n ckne-lab-1-5 delete pod app-b --wait=true
#     kubectl apply -f /tmp/ckne-lab-1-5/app-b.yaml
#     kubectl -n ckne-lab-1-5 wait --for=condition=Ready pod/app-b --timeout=60s
#
# ---------------------------------------------------------------------------
# STEP 4 - Verify end to end
# ---------------------------------------------------------------------------
#   kubectl -n ckne-lab-1-5 get pod app-b \
#     -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
#   Expected (trimmed): a JSON list with two entries, the default network on
#   eth0 and:
#     {"name": "ckne-lab-1-5/storage-network", "interface": "net1",
#      "ips": ["10.10.0.11"], "mac": "..."}
#
#   B_IP=$(kubectl -n ckne-lab-1-5 exec app-b -- sh -c \
#     "ip -4 -o addr show dev net1 | awk '{print \$4}' | cut -d/ -f1")
#   kubectl -n ckne-lab-1-5 exec app-a -- ping -c 3 -I net1 "$B_IP"
#     3 packets transmitted, 3 packets received, 0% packet loss
#
#   ./break-fix-1.5.sh check     -> ALL CHECKS PASSED
#
# ---------------------------------------------------------------------------
# TAKEAWAYS
# ---------------------------------------------------------------------------
#   * Multus is a meta-plugin. The error chain reads outside-in: runtime ->
#     multus-shim -> Multus (NAD lookup) -> delegate plugin (bridge) -> IPAM
#     (host-local). Identify WHICH layer produced the message before you
#     change anything.
#   * NAD names resolve in the Pod's namespace unless you qualify them as
#     "<ns>/<name>". A name mismatch is a Multus error, not a CNI plugin error.
#   * NAD configs are opaque JSON to the API server. Kubernetes does not
#     validate them, so a bad IPAM range is accepted by 'kubectl apply' and
#     only fails at Pod creation.
#   * The annotation key must be exactly "k8s.v1.cni.cncf.io/networks". Any
#     other key fails silently. Always confirm with the
#     "k8s.v1.cni.cncf.io/network-status" annotation, never only with
#     "STATUS Running".
#   * Networks are attached at sandbox creation. After changing an
#     annotation or a NAD, recreate the Pods (for a Deployment: kubectl
#     rollout restart).
#   * bridge is node-local L2. Pods on different nodes need macvlan/ipvlan
#     over a shared host interface, or an overlay, to share a secondary
#     network. That is why this lab pins both Pods to one node.
# =============================================================================