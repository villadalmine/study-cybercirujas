#!/usr/bin/env bash
# =============================================================================
# CKNE - Topic 1.2: Managing IPAM and Pod CIDR Allocation
# BREAK & FIX lab: node Pod CIDR exhaustion (controller-manager range allocator)
# =============================================================================
#
# WHAT THIS LAB DOES
#   Creates a new, disposable 3-node kind cluster named "ckne-ipam-lab" and
#   deliberately gives it a cluster Pod CIDR that is too small:
#
#       --cluster-cidr        = 10.244.0.0/23   (set from kubeadm networking.podSubnet)
#       --node-cidr-mask-size = 24              (kube-controller-manager IPv4 default)
#
#   A /23 cut into /24 blocks gives exactly 2^(24-23) = 2 node CIDRs. With three
#   nodes, the range allocator in kube-controller-manager
#   (--allocate-node-cidrs=true) has no CIDR left for the last node that
#   registers.
#
# SAFETY
#   - It does not touch any existing cluster, kubeconfig context or host network.
#     Everything runs inside kind's Docker containers.
#   - Every kubectl call uses --context kind-ckne-ipam-lab explicitly.
#   - "cleanup" deletes the whole lab cluster.
#
# REQUIREMENTS
#   docker, kind (>= v0.20), kubectl, internet access for the node image
#   (and registry.k8s.io/pause:3.10 for the probe pods).
#   Optional: KIND_NODE_IMAGE=kindest/node:vX.Y.Z to pin the Kubernetes version.
#
# USAGE
#   ./ckne-1.2-ipam-break-fix.sh break     # create the broken cluster, show the task
#   ./ckne-1.2-ipam-break-fix.sh symptoms  # show the evidence again
#   ./ckne-1.2-ipam-break-fix.sh check     # check your fix
#   ./ckne-1.2-ipam-break-fix.sh cleanup   # delete the lab cluster
#
# OFFICIAL REFERENCES
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
#   https://kubernetes.io/docs/concepts/cluster-administration/networking/
#   https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/node-v1/
#   https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
#   https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
#   https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
#   https://kind.sigs.k8s.io/docs/user/configuration/#pod-subnet
#   https://www.cni.dev/plugins/current/ipam/host-local/
# =============================================================================

set -euo pipefail

CLUSTER="ckne-ipam-lab"
CTX="kind-${CLUSTER}"
CP_CONTAINER="${CLUSTER}-control-plane"
BROKEN_POD_SUBNET="10.244.0.0/23"
PROBE_IMAGE="registry.k8s.io/pause:3.10"
STATE_FILE="${TMPDIR:-/tmp}/${CLUSTER}.starved-node"

# ---------------------------------------------------------------- helpers ----
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*" >&2; exit 1; }

k() { kubectl --context "$CTX" "$@"; }

require() {
  local bin
  for bin in docker kind kubectl; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH."
  done
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable (is your user in the docker group?)."
}

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }

# IPv4 dotted quad -> 32-bit integer
ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# prefix length -> 32-bit netmask as integer
len2mask() {
  local len=$1
  if (( len == 0 )); then echo 0; else echo $(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF )); fi
}

# ip_in_cidr 10.244.2.7 10.244.2.0/24 -> exit 0 when the IP is inside the CIDR
ip_in_cidr() {
  local ip=$1 net=${2%/*} len=${2#*/} mask
  mask=$(len2mask "$len")
  (( ($(ip2int "$ip") & mask) == ($(ip2int "$net") & mask) ))
}

# cidr_within 10.244.2.0/24 10.244.0.0/16 -> exit 0 when the first CIDR fits inside the second
cidr_within() {
  local inner=$1 outer=$2
  local ilen=${inner#*/} olen=${outer#*/}
  (( ilen >= olen )) && ip_in_cidr "${inner%/*}" "$outer"
}

# "name podCIDR" per line (podCIDR is empty when none has been allocated)
node_cidrs() {
  k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.podCIDR}{"\n"}{end}'
}

nodes_without_cidr() { node_cidrs | awk 'NF == 1 {print $1}'; }

running_cluster_cidr() {
  k -n kube-system get pod -l component=kube-controller-manager \
    -o jsonpath='{range .items[0].spec.containers[0].command[*]}{@}{"\n"}{end}' 2>/dev/null \
    | awk -F= '/^--cluster-cidr=/ {print $2}'
}

running_node_mask() {
  local m
  m=$(k -n kube-system get pod -l component=kube-controller-manager \
      -o jsonpath='{range .items[0].spec.containers[0].command[*]}{@}{"\n"}{end}' 2>/dev/null \
      | awk -F= '/^--node-cidr-mask-size(-ipv4)?=/ {print $2}' | head -n1)
  echo "${m:-24 (default)}"
}

kubeadm_pod_subnet() {
  k -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null \
    | awk '/podSubnet:/ {print $2}' | tr -d '"'
}

kube_proxy_cluster_cidr() {
  k -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null \
    | awk '/^clusterCIDR:/ {print $2}' | tr -d '"'
}

kindnet_pod_subnet() {
  k -n kube-system get ds kindnet \
    -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="POD_SUBNET")]}{.value}{end}' 2>/dev/null || true
}

# ------------------------------------------------------------------ break ----
do_break() {
  require
  if cluster_exists; then
    die "Cluster '$CLUSTER' already exists. Run '$0 cleanup' first for a clean scenario."
  fi

  local cfg
  cfg=$(mktemp)
  trap 'rm -f "$cfg"' RETURN
  cat >"$cfg" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: ipv4
  podSubnet: "${BROKEN_POD_SUBNET}"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

  blue ">>> Creating the lab cluster '$CLUSTER' (takes 1-3 minutes)..."
  local image_args=()
  [[ -n "${KIND_NODE_IMAGE:-}" ]] && image_args=(--image "$KIND_NODE_IMAGE")
  kind create cluster --name "$CLUSTER" --config "$cfg" "${image_args[@]}"

  blue ">>> Waiting for the range allocator to hand out the Pod CIDRs..."
  local i starved with_cidr total
  for i in $(seq 1 60); do
    total=$(node_cidrs | wc -l)
    with_cidr=$(node_cidrs | awk 'NF == 2' | wc -l)
    starved=$(nodes_without_cidr)
    if (( total == 3 && with_cidr == 2 )) && [[ -n "$starved" ]]; then
      break
    fi
    sleep 3
  done

  if [[ -z "${starved:-}" ]]; then
    node_cidrs
    die "The expected state (2 nodes with a CIDR, 1 without) did not appear. Check the controller-manager flags and run '$0 cleanup'."
  fi
  echo "$starved" >"$STATE_FILE"

  green ">>> Scenario ready. Something is wrong in the cluster."
  print_briefing
}

print_briefing() {
  cat <<EOF

=============================================================================
 INCIDENT TICKET  #IPAM-1.2
=============================================================================
 "We added a third node to the cluster. It never becomes Ready and no
  workload lands on it. The CNI team says their plugin is fine."

 SYMPTOMS YOU WILL SEE
  1) kubectl --context $CTX get nodes
       -> one node stays NotReady.
  2) kubectl --context $CTX describe node <that node>
       -> Conditions: "container runtime network not ready ...
          NetworkPluginNotReady ... cni plugin not initialized"
       -> the PodCIDR / PodCIDRs fields are missing.
       -> Events: CIDRNotAvailable
  3) kubectl --context $CTX -n kube-system logs -l component=kube-controller-manager
       -> "CIDR allocation failed; there are no remaining CIDRs left to
           allocate in the accepted range"
  4) The kindnet pod on that node has no podCIDR to build its CNI config
     from, so /etc/cni/net.d is left without a network config.
     Look inside the node with:  docker exec <node> ls /etc/cni/net.d

 YOUR GOAL (without deleting or recreating the cluster)
  a) Every node gets a spec.podCIDR, with no overlaps, and becomes Ready.
  b) Pods on the previously starved node get an IP from THAT node's podCIDR.
  c) The cluster Pod CIDR is widened to 10.244.0.0/16 CONSISTENTLY:
       - kube-controller-manager --cluster-cidr   (static pod manifest)
       - kubeadm-config ConfigMap networking.podSubnet (so the next
         'kubeadm upgrade' does not quietly put back the /23)
       - kube-proxy ConfigMap clusterCIDR (masquerade decisions)
       - kindnet DaemonSet POD_SUBNET (CNI masquerade), when present
  d) Do not leave any backup file inside /etc/kubernetes/manifests/.

 CONSTRAINTS / THINGS TO THINK ABOUT
  - Node.spec.podCIDR can be set once and then never changed.
  - Why would reducing --node-cidr-mask-size NOT fix this by itself?
  - The control-plane node is the Docker container: $CP_CONTAINER
      docker exec -it $CP_CONTAINER bash

 When you think you are done:   $0 check
 To delete the lab:              $0 cleanup
=============================================================================
EOF
}

# --------------------------------------------------------------- symptoms ----
do_symptoms() {
  require
  cluster_exists || die "Cluster '$CLUSTER' does not exist. Run '$0 break' first."

  blue "--- Nodes and their allocated Pod CIDRs"
  k get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,PODCIDR:.spec.podCIDR,PODCIDRS:.spec.podCIDRs'
  echo
  blue "--- Allocator settings (running kube-controller-manager)"
  echo "cluster-cidr        : $(running_cluster_cidr)"
  echo "node-cidr-mask-size : $(running_node_mask)"
  echo
  blue "--- CIDRNotAvailable events"
  k get events -A --field-selector reason=CIDRNotAvailable 2>/dev/null || true
  echo
  blue "--- Allocator log lines"
  k -n kube-system logs -l component=kube-controller-manager --tail=400 2>/dev/null \
    | grep -iE 'cidr' | tail -n 5 || true
}

# ------------------------------------------------------------------ check ----
do_check() {
  require
  cluster_exists || die "Cluster '$CLUSTER' does not exist. Run '$0 break' first."

  local failures=0
  pass() { green "  [PASS] $*"; }
  fail() { red   "  [FAIL] $*"; failures=$((failures + 1)); }

  local cc
  cc=$(running_cluster_cidr)
  blue "1) kube-controller-manager --cluster-cidr"
  if [[ -z "$cc" ]]; then
    fail "Could not read --cluster-cidr from the running kube-controller-manager pod."
  elif [[ "$cc" == "10.244.0.0/16" ]]; then
    pass "--cluster-cidr=$cc"
  else
    fail "--cluster-cidr is '$cc', expected 10.244.0.0/16"
  fi

  blue "2) Every node has a podCIDR, inside the cluster CIDR, with no duplicates"
  local missing dupes
  missing=$(nodes_without_cidr)
  if [[ -n "$missing" ]]; then
    fail "Nodes without spec.podCIDR: $(echo "$missing" | tr '\n' ' ')"
  else
    pass "All nodes have a spec.podCIDR"
  fi
  dupes=$(node_cidrs | awk 'NF == 2 {print $2}' | sort | uniq -d)
  if [[ -n "$dupes" ]]; then
    fail "Duplicate node Pod CIDRs: $dupes"
  else
    pass "No duplicate node Pod CIDRs"
  fi
  if [[ -n "$cc" ]]; then
    local name cidr
    while read -r name cidr; do
      [[ -z "${cidr:-}" ]] && continue
      if cidr_within "$cidr" "$cc"; then
        pass "$name -> $cidr lies within $cc"
      else
        fail "$name -> $cidr lies OUTSIDE $cc"
      fi
    done < <(node_cidrs)
  fi

  blue "3) All nodes Ready"
  local notready
  notready=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
             | awk '$2 != "True" {print $1}')
  if [[ -n "$notready" ]]; then
    fail "NotReady nodes: $(echo "$notready" | tr '\n' ' ')"
  else
    pass "Every node reports Ready=True"
  fi

  blue "4) Configuration consistency (the ones that bite during upgrades)"
  local ps kp kn
  ps=$(kubeadm_pod_subnet)
  if [[ "$ps" == "$cc" && -n "$ps" ]]; then
    pass "kubeadm-config networking.podSubnet = $ps"
  else
    fail "kubeadm-config networking.podSubnet = '${ps:-<empty>}' (expected $cc)"
  fi
  kp=$(kube_proxy_cluster_cidr)
  if [[ "$kp" == "$cc" && -n "$kp" ]]; then
    pass "kube-proxy clusterCIDR = $kp"
  else
    fail "kube-proxy clusterCIDR = '${kp:-<empty>}' (expected $cc)"
  fi
  kn=$(kindnet_pod_subnet)
  if [[ -z "$kn" ]]; then
    yellow "  [SKIP] kindnet DaemonSet has no POD_SUBNET env var in this kind version"
  elif [[ "$kn" == "$cc" ]]; then
    pass "kindnet POD_SUBNET = $kn"
  else
    fail "kindnet POD_SUBNET = '$kn' (expected $cc)"
  fi

  blue "5) No leftover files in the static pod directory"
  local extra
  extra=$(docker exec "$CP_CONTAINER" sh -c 'ls -1 /etc/kubernetes/manifests' 2>/dev/null \
          | grep -vxE 'etcd\.yaml|kube-apiserver\.yaml|kube-controller-manager\.yaml|kube-scheduler\.yaml' || true)
  if [[ -n "$extra" ]]; then
    fail "Extra files in /etc/kubernetes/manifests (the kubelet may run them as pods): $(echo "$extra" | tr '\n' ' ')"
  else
    pass "/etc/kubernetes/manifests contains only the four control-plane manifests"
  fi

  blue "6) Data plane: a probe pod on each node gets an IP from that node's podCIDR"
  local node ncidr pod ip
  while read -r node ncidr; do
    pod="ipam-probe-${node}"
    k delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    if [[ -z "${ncidr:-}" ]]; then
      fail "$node: no podCIDR, skipping the probe"
      continue
    fi
    k run "$pod" --image="$PROBE_IMAGE" --restart=Never \
      --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${node}\"}}" >/dev/null
    if ! k wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null 2>&1; then
      fail "$node: probe pod did not become Ready (kubectl describe pod $pod)"
      continue
    fi
    ip=$(k get pod "$pod" -o jsonpath='{.status.podIP}')
    if [[ -n "$ip" ]] && ip_in_cidr "$ip" "$ncidr"; then
      pass "$node: pod IP $ip is inside $ncidr"
    else
      fail "$node: pod IP '${ip:-<none>}' is NOT inside $ncidr"
    fi
    k delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  done < <(node_cidrs)

  if [[ -f "$STATE_FILE" ]]; then
    echo
    yellow "  (The node starved at break time was: $(cat "$STATE_FILE"))"
  fi

  echo
  if (( failures == 0 )); then
    green "=============================================================="
    green " ALL CHECKS PASSED - Pod CIDR allocation is healthy again."
    green " Delete the lab with: $0 cleanup"
    green "=============================================================="
  else
    red "=============================================================="
    red " $failures check(s) failed. Run '$0 symptoms' and keep going."
    red "=============================================================="
    exit 1
  fi
}

# ---------------------------------------------------------------- cleanup ----
do_cleanup() {
  require
  if cluster_exists; then
    blue ">>> Deleting cluster '$CLUSTER'..."
    kind delete cluster --name "$CLUSTER"
  else
    yellow "Cluster '$CLUSTER' does not exist; nothing to delete."
  fi
  rm -f "$STATE_FILE"
  green ">>> Cleanup complete."
}

# ------------------------------------------------------------------- main ----
case "${1:-}" in
  break)    do_break ;;
  symptoms) do_symptoms ;;
  check)    do_check ;;
  cleanup)  do_cleanup ;;
  *)
    echo "Usage: $0 {break|symptoms|check|cleanup}"
    exit 2
    ;;
esac

exit 0

# =============================================================================
# SOLUTION (step by step) - try it on your own first
# =============================================================================
#
# --- STEP 0: Confirm the diagnosis -------------------------------------------
#
#   kubectl --context kind-ckne-ipam-lab get nodes \
#     -o custom-columns='NAME:.metadata.name,PODCIDR:.spec.podCIDR'
#
#   Expected output (which worker is starved varies from run to run):
#     NAME                          PODCIDR
#     ckne-ipam-lab-control-plane   10.244.0.0/24
#     ckne-ipam-lab-worker          10.244.1.0/24
#     ckne-ipam-lab-worker2         <none>
#
#   kubectl --context kind-ckne-ipam-lab -n kube-system logs \
#     -l component=kube-controller-manager | grep -i cidr
#     ... "CIDR allocation failed; there are no remaining CIDRs left to
#          allocate in the accepted range" ...
#
#   The math: cluster-cidr /23, node-cidr-mask-size /24 gives
#   2^(24-23) = 2 node blocks for 3 nodes.
#   The CNI (kindnet, like flannel or any plugin driven by host-local
#   IPAM) builds each node's range from Node.spec.podCIDR. No podCIDR means
#   no CNI config, so the kubelet reports NetworkReady=false and the node is
#   NotReady. The CNI is a victim here, not the cause.
#
# --- WHY THE "OBVIOUS" FIXES DO NOT WORK ---------------------------------------
#
#   * Only lowering --node-cidr-mask-size to 25: the two /24s already
#     handed out fill the whole /23, so there is nothing left to carve.
#     Node.spec.podCIDR can be set once and never changed afterwards, so the
#     allocator cannot shrink the existing ones either.
#   * Moving to a DIFFERENT, non-overlapping range (e.g. 10.100.0.0/16):
#     the existing nodes keep CIDRs outside the new cluster-cidr and
#     kube-proxy/CNI masquerade rules stop matching the real pod IPs.
#     Changing ranges needs a drain + node delete + rejoin per node.
#   * The safe in-place change: WIDEN to a SUPERSET of the old range
#     (10.244.0.0/23 -> 10.244.0.0/16). When the allocator starts, it marks
#     the existing /24s as used and gives the next free one
#     (10.244.2.0/24) to the starved node.
#     First check that the new range overlaps neither the Service CIDR
#     (10.96.0.0/16 here) nor the node/LAN network.
#
# --- STEP 1: Widen --cluster-cidr in the static pod manifest --------------------
#
#   Back up OUTSIDE the manifests directory. The kubelet treats every
#   file there as a static pod, so a stray backup can start a second
#   kube-controller-manager.
#
#   docker exec ckne-ipam-lab-control-plane \
#     cp /etc/kubernetes/manifests/kube-controller-manager.yaml /root/kcm.yaml.bak
#
#   docker exec ckne-ipam-lab-control-plane \
#     sed -i 's#--cluster-cidr=10.244.0.0/23#--cluster-cidr=10.244.0.0/16#' \
#     /etc/kubernetes/manifests/kube-controller-manager.yaml
#
#   docker exec ckne-ipam-lab-control-plane \
#     grep -E 'cluster-cidr|allocate-node-cidrs|node-cidr-mask' \
#     /etc/kubernetes/manifests/kube-controller-manager.yaml
#     - --allocate-node-cidrs=true
#     - --cluster-cidr=10.244.0.0/16
#
#   The kubelet sees the manifest change and recreates the static pod.
#   Wait for it:
#
#   kubectl --context kind-ckne-ipam-lab -n kube-system get pod \
#     -l component=kube-controller-manager -w
#
# --- STEP 2: Check that the starved node got its CIDR ---------------------------
#
#   kubectl --context kind-ckne-ipam-lab get nodes \
#     -o custom-columns='NAME:.metadata.name,PODCIDR:.spec.podCIDR'
#     ckne-ipam-lab-control-plane   10.244.0.0/24
#     ckne-ipam-lab-worker          10.244.1.0/24
#     ckne-ipam-lab-worker2         10.244.2.0/24
#
#   Within a few seconds kindnet on that node writes the CNI config and the
#   kubelet flips it to Ready:
#
#   docker exec ckne-ipam-lab-worker2 ls /etc/cni/net.d
#   kubectl --context kind-ckne-ipam-lab get nodes
#
# --- STEP 3: Make kubeadm's source of truth agree -------------------------------
#
#   'kubeadm upgrade' rebuilds the control-plane manifests from the
#   ClusterConfiguration stored in this ConfigMap. If you skip this step,
#   the next upgrade quietly brings the /23 back.
#
#   kubectl --context kind-ckne-ipam-lab -n kube-system get cm kubeadm-config -o yaml \
#     | sed 's#podSubnet: 10.244.0.0/23#podSubnet: 10.244.0.0/16#' \
#     | kubectl --context kind-ckne-ipam-lab apply -f -
#
# --- STEP 4: kube-proxy clusterCIDR ---------------------------------------------
#
#   kube-proxy uses clusterCIDR to decide which traffic to Services comes
#   from outside the Pod network and must be masqueraded. With a stale /23,
#   pods in 10.244.2.0/24 would be treated as "external".
#
#   kubectl --context kind-ckne-ipam-lab -n kube-system get cm kube-proxy -o yaml \
#     | sed 's#clusterCIDR: 10.244.0.0/23#clusterCIDR: 10.244.0.0/16#' \
#     | kubectl --context kind-ckne-ipam-lab apply -f -
#   kubectl --context kind-ckne-ipam-lab -n kube-system rollout restart ds/kube-proxy
#   kubectl --context kind-ckne-ipam-lab -n kube-system rollout status ds/kube-proxy
#
#   (If the sed did not match, the value may be quoted in your version.
#    Edit it directly with: kubectl -n kube-system edit cm kube-proxy)
#
# --- STEP 5: CNI plugin view of the Pod network ----------------------------------
#
#   kindnet uses POD_SUBNET to decide what NOT to masquerade:
#
#   kubectl --context kind-ckne-ipam-lab -n kube-system set env ds/kindnet \
#     POD_SUBNET=10.244.0.0/16
#   kubectl --context kind-ckne-ipam-lab -n kube-system rollout status ds/kindnet
#
#   Other CNIs keep this setting elsewhere: flannel in the net-conf.json
#   "Network" key, Calico in its IPPool, Cilium in
#   clusterPoolIPv4PodCIDRList when it runs its own IPAM instead of
#   ipam.mode=kubernetes.
#
# --- STEP 6: Clean up the backup and verify end to end ---------------------------
#
#   /root/kcm.yaml.bak is outside /etc/kubernetes/manifests, so the kubelet
#   ignores it. Confirm the directory holds only the four manifests:
#
#   docker exec ckne-ipam-lab-control-plane ls /etc/kubernetes/manifests
#     etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
#
#   Then:
#   ./ckne-1.2-ipam-break-fix.sh check
#
# --- PRODUCTION TAKEAWAYS -------------------------------------------------------
#
#   * Size it up front:  nodes_max = 2^(node_mask - cluster_mask).
#     A /16 with /24 per node gives 256 nodes of 254 usable IPs each. The kubelet
#     limit (maxPods, default 110) is what bounds pods per node,
#     not the /24.
#   * Watch for CIDRNotAvailable events and alert on NotReady nodes whose
#     spec.podCIDR is empty. That pair means IPAM exhaustion, not a CNI bug.
#   * There are four places that must agree on the Pod CIDR: controller-manager,
#     kubeadm-config, kube-proxy, and the CNI. Changing only one of them gives a
#     cluster that "works" until the next upgrade or the next node.
#   * Widening in place only works to a superset. Anything else is a
#     per-node migration (drain, delete Node, rejoin), because
#     spec.podCIDR cannot be changed.
# =============================================================================