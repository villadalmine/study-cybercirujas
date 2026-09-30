#!/usr/bin/env bash
# =============================================================================
# CKNE 4.2 - Implementing Node and Pod Level Encryption
# BREAK & FIX LAB: "The encryption that someone quietly switched off"
# =============================================================================
#
# WHAT THIS LAB DOES
#   1. Creates a disposable 3-node kind cluster (1 control-plane + 2 workers)
#      with NO default CNI and installs Cilium with WireGuard transparent
#      encryption turned on for pod traffic (pod-to-pod) and for node traffic
#      (nodeEncryption).
#   2. Deploys a server on worker 1 that returns a fake "cardholder record",
#      plus two clients on worker 2 (a normal pod, and a hostNetwork pod that
#      acts as the node itself) and a packet sniffer on worker 1.
#   3. Runs a baseline check to prove that encryption works.
#   4. BREAKS the cluster in a realistic, multi-layer way (see the MISSION
#      banner printed at the end of the run).
#
# SAFETY
#   - Everything runs inside Docker containers created by kind. The host's
#     own firewall, routes and interfaces are never modified.
#   - Every kubectl/helm call is pinned to the context "kind-${CLUSTER}", so
#     the script cannot touch any other cluster in your kubeconfig.
#   - Run it on a disposable lab VM. The iptables changes happen only inside
#     the kind node container "${CLUSTER}-worker".
#   - "./lab.sh cleanup" deletes the whole cluster.
#
# REQUIREMENTS
#   docker, kind (>= 0.20), kubectl, helm (>= 3.12), about 6 GB of free RAM,
#   internet access to pull images, and a Linux kernel with WireGuard
#   (>= 5.6, built in or loadable with "sudo modprobe wireguard").
#   kind nodes share the host kernel, so the host needs the module.
#
# USAGE
#   ./lab.sh            # build the cluster, check the baseline, apply the break
#   ./lab.sh check      # grade your fix (exit 0 = solved)
#   ./lab.sh cleanup    # delete the lab cluster
#   ASSUME_YES=1 ./lab.sh                      # skip the confirmation prompt
#   CILIUM_VERSION=1.18.2 ./lab.sh             # pin another Cilium chart
#
# REFERENCES
#   CKNE curriculum:
#     https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   Cilium WireGuard transparent encryption:
#     https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
#   Cilium IPsec transparent encryption (alternative mechanism):
#     https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
#   Cilium on kind:
#     https://docs.cilium.io/en/stable/installation/kind/
#   kind configuration:
#     https://kind.sigs.k8s.io/docs/user/configuration/
#   kubectl debug node (netadmin profile):
#     https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/
# =============================================================================

set -Eeuo pipefail

CLUSTER="${CLUSTER:-ckne-enc-lab}"
CTX="kind-${CLUSTER}"
NS="enc-lab"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.2}"
WORKER="${CLUSTER}-worker"
WORKER2="${CLUSTER}-worker2"
SECRET_MARKER="PAN-4111-1111-1111-1111-CKNE-LAB"
WG_PORT="51871"
VXLAN_PORT="8472"

NGINX_IMAGE="nginx:1.27-alpine"
CURL_IMAGE="curlimages/curl:8.10.1"
NETSHOOT_IMAGE="nicolaka/netshoot:v0.13"

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_rst=$'\e[0m'
log()  { printf '%s[lab]%s %s\n' "$c_cyn" "$c_rst" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s[fatal]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
pass() { printf '  %s[PASS]%s %s\n' "$c_grn" "$c_rst" "$*"; }
failm(){ printf '  %s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*"; }

k()    { kubectl --context "$CTX" "$@"; }
h()    { helm --kube-context "$CTX" "$@"; }

trap 'warn "command failed at line $LINENO: $BASH_COMMAND"' ERR

need() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { warn "missing required command: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install the missing tools and run again"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

preflight() {
  need docker kind kubectl helm
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable by this user"
  if [ ! -d /sys/module/wireguard ]; then
    die "WireGuard kernel module not loaded on the host. Run: sudo modprobe wireguard"
  fi
}

confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  cat <<EOF

This lab will create the kind cluster '${CLUSTER}' (3 Docker containers),
install Cilium ${CILIUM_VERSION} and then deliberately break it.
Only use it on a disposable lab VM.

EOF
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted by user"
}

# ----------------------------------------------------------------------------
# build
# ----------------------------------------------------------------------------
create_cluster() {
  if cluster_exists; then
    die "cluster '${CLUSTER}' already exists. Run './$(basename "$0") cleanup' first."
  fi
  local cfg
  cfg="$(mktemp /tmp/ckne-enc-kind.XXXXXX)"
  cat >"$cfg" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
  log "creating kind cluster '${CLUSTER}'"
  kind create cluster --name "$CLUSTER" --config "$cfg" --wait 0s
  rm -f "$cfg"
}

install_cilium() {
  log "installing Cilium ${CILIUM_VERSION} with WireGuard pod + node encryption"
  helm repo add cilium https://helm.cilium.io --force-update >/dev/null
  helm repo update cilium >/dev/null
  h upgrade --install cilium cilium/cilium \
    --version "$CILIUM_VERSION" \
    --namespace kube-system \
    --set image.pullPolicy=IfNotPresent \
    --set ipam.mode=kubernetes \
    --set operator.replicas=1 \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set encryption.nodeEncryption=true \
    --description "Initial install: WireGuard transparent encryption (pods + nodes)"
  wait_cilium
  k wait --for=condition=Ready nodes --all --timeout=300s
}

wait_cilium() {
  k -n kube-system rollout status ds/cilium --timeout=300s
  k -n kube-system rollout status deploy/cilium-operator --timeout=300s
}

deploy_workloads() {
  log "deploying server, clients and sniffer"
  k apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: server-content
  namespace: ${NS}
data:
  index.html: |
    customer-id=88213 cardholder-record=${SECRET_MARKER}
---
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: ${NS}
  labels:
    app: server
spec:
  nodeSelector:
    kubernetes.io/hostname: ${WORKER}
  containers:
    - name: nginx
      image: ${NGINX_IMAGE}
      ports:
        - containerPort: 80
      volumeMounts:
        - name: content
          mountPath: /usr/share/nginx/html
  volumes:
    - name: content
      configMap:
        name: server-content
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: ${NS}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${WORKER2}
  containers:
    - name: curl
      image: ${CURL_IMAGE}
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: hostclient
  namespace: ${NS}
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: ${WORKER2}
  containers:
    - name: curl
      image: ${CURL_IMAGE}
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: sniffer
  namespace: ${NS}
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: ${WORKER}
  containers:
    - name: netshoot
      image: ${NETSHOOT_IMAGE}
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW"]
EOF
  k -n "$NS" wait --for=condition=Ready pod --all --timeout=240s
}

# ----------------------------------------------------------------------------
# observation primitives (also used by the grader)
# ----------------------------------------------------------------------------
server_ip() {
  k -n "$NS" get pod server -o jsonpath='{.status.podIP}'
}

fetch() {  # $1 = client pod name
  k -n "$NS" exec "$1" -- curl -s -m 5 "http://$(server_ip)/" 2>/dev/null || true
}

sniff() {  # $1 = client pod name; prints the path of a text capture from worker eth0
  local client="$1" ip cap tpid
  ip="$(server_ip)"
  cap="$(mktemp /tmp/ckne-enc-cap.XXXXXX)"
  k -n "$NS" exec sniffer -- timeout 12 tcpdump -l -i eth0 -nn -A -s 0 \
    "udp port ${VXLAN_PORT} or udp port ${WG_PORT} or tcp port 80" >"$cap" 2>/dev/null &
  tpid=$!
  sleep 3
  for _ in 1 2 3 4 5; do
    k -n "$NS" exec "$client" -- curl -s -m 3 "http://${ip}/" >/dev/null 2>&1 || true
    sleep 1
  done
  wait "$tpid" 2>/dev/null || true
  printf '%s\n' "$cap"
}

cm_value() {
  k -n kube-system get cm cilium-config -o "jsonpath={.data.$1}" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# grader
# ----------------------------------------------------------------------------
check() {
  cluster_exists || die "cluster '${CLUSTER}' does not exist; run the lab first"
  local rc=0 p st out cap label client

  echo
  log "1) Cilium configuration"
  if [ "$(cm_value enable-wireguard)" = "true" ]; then
    pass "cilium-config enable-wireguard=true"
  else
    failm "cilium-config enable-wireguard is not 'true' (pod-level encryption is off)"; rc=1
  fi
  if [ "$(cm_value encrypt-node)" = "true" ]; then
    pass "cilium-config encrypt-node=true"
  else
    failm "cilium-config encrypt-node is not 'true' (node-level encryption is off)"; rc=1
  fi

  log "2) every Cilium agent reports WireGuard at runtime"
  for p in $(k -n kube-system get pods -l k8s-app=cilium -o name); do
    st="$(k -n kube-system exec "$p" -c cilium-agent -- cilium-dbg encrypt status 2>/dev/null || true)"
    if grep -qi 'wireguard' <<<"$st"; then
      pass "${p#pod/}: $(head -n1 <<<"$st")"
    else
      failm "${p#pod/}: $(head -n1 <<<"${st:-no answer}")  (agent config may be stale: was the DaemonSet restarted?)"; rc=1
    fi
  done

  log "3) cross-node connectivity (worker2 -> worker)"
  for client in client hostclient; do
    out="$(fetch "$client")"
    if grep -q "$SECRET_MARKER" <<<"$out"; then
      pass "${client} reaches the server pod"
    else
      failm "${client} cannot reach the server pod ($(server_ip):80)"; rc=1
    fi
  done

  log "4) wire capture on ${WORKER} eth0: no plaintext allowed"
  for client in client hostclient; do
    if [ "$client" = client ]; then label="pod-to-pod"; else label="node-to-pod"; fi
    cap="$(sniff "$client")"
    if grep -q "$SECRET_MARKER" "$cap"; then
      failm "${label}: the cardholder record is readable on the wire:"
      grep -m1 -o "cardholder-record=[A-Z0-9-]*" "$cap" | sed 's/^/           /'
      rc=1
    elif grep -q "\.${WG_PORT}[: ]" "$cap"; then
      pass "${label}: only WireGuard (udp/${WG_PORT}) observed, payload not readable"
    else
      failm "${label}: no WireGuard packets observed on udp/${WG_PORT}"; rc=1
    fi
    rm -f "$cap"
  done

  echo
  if [ "$rc" -eq 0 ]; then
    printf '%sLAB SOLVED%s: pod and node traffic are encrypted and flowing.\n' "$c_grn" "$c_rst"
  else
    printf '%sNOT SOLVED YET%s: fix the failing checks and run "%s check" again.\n' "$c_red" "$c_rst" "$0"
  fi
  return "$rc"
}

# ----------------------------------------------------------------------------
# the break
# ----------------------------------------------------------------------------
apply_break() {
  log "change 1/2 (the 'security hardening' ticket SEC-2291) on ${WORKER}"
  docker exec "$WORKER" sh -c "
    iptables -N LAB-HARDENING 2>/dev/null || true
    iptables -F LAB-HARDENING
    iptables -A LAB-HARDENING -p udp --dport ${VXLAN_PORT} -m comment --comment 'SEC-2291 allow overlay' -j ACCEPT
    iptables -A LAB-HARDENING -p udp --dport ${WG_PORT} -m comment --comment 'SEC-2291 deny unapproved UDP service' -j DROP
    iptables -C INPUT -j LAB-HARDENING 2>/dev/null || iptables -I INPUT 1 -j LAB-HARDENING
  "

  log "change 2/2 (the 'incident mitigation' INC-4471)"
  h upgrade cilium cilium/cilium \
    --version "$CILIUM_VERSION" \
    --namespace kube-system \
    --reuse-values \
    --set encryption.enabled=false \
    --set encryption.nodeEncryption=false \
    --description "INC-4471 mitigation: cross-node timeouts, transparent encryption disabled temporarily" \
    >/dev/null
  k -n kube-system rollout restart ds/cilium >/dev/null
  wait_cilium
  sleep 10
}

show_symptom() {
  local cap
  echo
  log "what the compliance scanner sees now on ${WORKER} eth0:"
  cap="$(sniff client)"
  if grep -q "$SECRET_MARKER" "$cap"; then
    grep -m3 -E "(\.${VXLAN_PORT}|cardholder-record)" "$cap" | cut -c1-140 | sed 's/^/    /'
  else
    warn "no plaintext captured on this run; run '$0 check' to see the full state"
  fi
  rm -f "$cap"
}

mission() {
  cat <<EOF

${c_ylw}=============================================================================
 MISSION (CKNE 4.2)
=============================================================================${c_rst}
 Context: a PCI-scoped workload lives in namespace '${NS}'. The policy says
 ALL traffic between nodes must be encrypted, both pod-to-pod and
 node(host)-to-pod.

 Symptom reported by the compliance team:
   "A capture on node ${WORKER} (eth0) shows cardholder records in cleartext
    inside VXLAN (udp/${VXLAN_PORT}). Nobody knows since when. The app works fine."

 Your goal:
   1. Encrypt pod-to-pod traffic between nodes with WireGuard.
   2. Encrypt node-level traffic too (host network namespace -> remote pods).
   3. Keep cross-node connectivity working for BOTH client pods on ${WORKER2}.
   4. Understand WHY encryption was switched off, and fix the root cause
      properly. Turning the protection off, or deleting a whole firewall
      policy, is not an acceptable fix.

 Hints:
   - Changes to a Helm-managed CNI leave a trail.
   - There may be more than one layer to this incident.
   - Tools: helm history, cilium-dbg (inside the agent pods), kubectl debug
     node/... --profile=netadmin, docker exec ${WORKER} ...

 Grade your work:   $0 check
 Tear down:         $0 cleanup
 The step-by-step solution is commented at the end of this script.
=============================================================================
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
  case "${1:-break}" in
    break)
      preflight
      confirm
      create_cluster
      install_cilium
      deploy_workloads
      log "baseline: proving that encryption works BEFORE the break"
      check || die "baseline failed: the environment is not healthy, the lab cannot continue (check the WireGuard module and the pulled images)"
      apply_break
      show_symptom
      mission
      ;;
    check)
      need kubectl kind
      check
      ;;
    cleanup)
      need kind
      if cluster_exists; then
        kind delete cluster --name "$CLUSTER"
        log "cluster '${CLUSTER}' deleted"
      else
        log "nothing to clean up"
      fi
      ;;
    *)
      die "usage: $0 [break|check|cleanup]"
      ;;
  esac
}

main "$@"

# =============================================================================
# SOLUTION (step by step) - do not read until you have tried
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 - Confirm the symptom yourself
# ---------------------------------------------------------------------------
#   kubectl config use-context kind-ckne-enc-lab
#
#   kubectl debug node/ckne-enc-lab-worker -it --profile=netadmin \
#     --image=nicolaka/netshoot:v0.13 -- \
#     tcpdump -i eth0 -nn -A -s0 'udp port 8472 or udp port 51871'
#
#   # in another terminal, generate traffic:
#   kubectl -n enc-lab exec client -- curl -s http://$(kubectl -n enc-lab get pod server -o jsonpath='{.status.podIP}')/
#
#   You will see "IP 172.18.0.x.NNNNN > 172.18.0.y.8472: OTV/VXLAN ..." and,
#   a few lines later, "cardholder-record=PAN-4111-...". The overlay
#   encapsulates, it does NOT encrypt. VXLAN is a transport, not a
#   confidentiality control.
#
# ---------------------------------------------------------------------------
# STEP 1 - Check the runtime state of the datapath
# ---------------------------------------------------------------------------
#   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
#     Encryption: Disabled
#
#   kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'wireguard|encrypt'
#     (enable-wireguard / encrypt-node are missing or not "true")
#
#   Note: cilium-config is what the agents read on START. Editing the
#   ConfigMap without restarting the DaemonSet does not change anything at
#   runtime unless the chart was installed with rollOutCiliumPods=true.
#
# ---------------------------------------------------------------------------
# STEP 2 - Find the trail: who switched it off, and why
# ---------------------------------------------------------------------------
#   helm --kube-context kind-ckne-enc-lab -n kube-system history cilium
#     REVISION  STATUS      DESCRIPTION
#     1         superseded  Initial install: WireGuard transparent encryption (pods + nodes)
#     2         deployed    INC-4471 mitigation: cross-node timeouts, transparent encryption disabled temporarily
#
#   helm --kube-context kind-ckne-enc-lab -n kube-system get values cilium --revision 1
#   helm --kube-context kind-ckne-enc-lab -n kube-system get values cilium --revision 2
#
#   Conclusion: someone saw cross-node timeouts and "mitigated" them by
#   turning encryption off. That is a symptom-level fix. Something made
#   WireGuard fail FIRST. Keep that in mind: if you only re-enable
#   encryption, the original outage will come back.
#
# ---------------------------------------------------------------------------
# STEP 3 - Re-enable pod AND node encryption (WireGuard)
# ---------------------------------------------------------------------------
#   helm --kube-context kind-ckne-enc-lab upgrade cilium cilium/cilium \
#     --version 1.18.2 -n kube-system --reuse-values \
#     --set encryption.enabled=true \
#     --set encryption.type=wireguard \
#     --set encryption.nodeEncryption=true \
#     --description "INC-4471 fix: re-enable WireGuard pod+node encryption"
#
#   kubectl -n kube-system rollout restart ds/cilium
#   kubectl -n kube-system rollout status ds/cilium
#
#   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
#     Encryption: Wireguard
#     Interface: cilium_wg0
#         Public key: <base64>
#         Number of peers: 2
#
#   How it works: each agent generates a WireGuard key pair, creates the
#   cilium_wg0 interface (UDP 51871) and publishes its public key on its
#   CiliumNode object (annotation network.cilium.io/wg-pub-key). Every
#   agent adds every other node as a peer, with the remote PodCIDRs (and,
#   with nodeEncryption, the node IPs) as AllowedIPs. Keys are never
#   distributed by hand, unlike IPsec, where you create and rotate the
#   'cilium-ipsec-keys' Secret yourself.
#
#   Node encryption notes: by default, nodes labeled
#   node-role.kubernetes.io/control-plane opt out of node-to-node
#   encryption (encryption.nodeEncryption opt-out labels), so the API
#   server keeps working if the WireGuard mesh breaks. That is why this lab
#   measures between the two workers.
#
# ---------------------------------------------------------------------------
# STEP 4 - The second layer: cross-node traffic now fails
# ---------------------------------------------------------------------------
#   ./lab.sh check
#     [FAIL] client cannot reach the server pod ...
#     [FAIL] hostclient cannot reach the server pod ...
#
#   Isolate it:
#   - Only flows that touch ckne-enc-lab-worker fail. worker2 <-> control-plane
#     works. That points to ONE node, not to the Cilium config.
#   - Health probes:
#       kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-health status
#     ckne-enc-lab-worker shows as unreachable from the other nodes.
#   - WireGuard counters on the node (TX grows, RX stays flat = no handshake):
#       docker exec ckne-enc-lab-worker ip -s link show cilium_wg0
#       docker exec ckne-enc-lab-worker2 ip -s link show cilium_wg0
#   - Is the packet ARRIVING? tcpdump on worker eth0 sees udp/51871 from
#     worker2 (tcpdump taps before netfilter), yet no reply goes out:
#       kubectl debug node/ckne-enc-lab-worker -it --profile=netadmin \
#         --image=nicolaka/netshoot:v0.13 -- tcpdump -i eth0 -nn udp port 51871
#   - Arriving but not processed means the host firewall. Look at the
#     counters:
#       docker exec ckne-enc-lab-worker iptables -L INPUT -v -n --line-numbers
#       docker exec ckne-enc-lab-worker iptables -L LAB-HARDENING -v -n --line-numbers
#     Chain LAB-HARDENING
#     1  ...  ACCEPT  udp dpt:8472   /* SEC-2291 allow overlay */
#     2  ...  DROP    udp dpt:51871  /* SEC-2291 deny unapproved UDP service */
#            ^^^ pkts counter growing
#
#   Root cause: the hardening ticket allow-listed the overlay (VXLAN 8472)
#   but not the encryption transport (WireGuard 51871). WireGuard fails
#   closed: it does NOT fall back to plaintext, so traffic just stopped. The
#   "mitigation" then removed the encryption instead of fixing the rule.
#
# ---------------------------------------------------------------------------
# STEP 5 - Fix the firewall properly (allow WireGuard from nodes only)
# ---------------------------------------------------------------------------
#   Do not delete the whole LAB-HARDENING chain: that removes the security
#   control. Replace the DROP with an ACCEPT scoped to the node network:
#
#   NODE_NET=$(docker network inspect kind \
#     -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
#   echo "$NODE_NET"          # e.g. 172.18.0.0/16
#
#   docker exec ckne-enc-lab-worker iptables -D LAB-HARDENING \
#     -p udp --dport 51871 -m comment --comment 'SEC-2291 deny unapproved UDP service' -j DROP
#   docker exec ckne-enc-lab-worker iptables -I LAB-HARDENING 2 \
#     -p udp --dport 51871 -s "$NODE_NET" \
#     -m comment --comment 'SEC-2291 allow Cilium WireGuard between nodes' -j ACCEPT
#   docker exec ckne-enc-lab-worker iptables -A LAB-HARDENING \
#     -p udp --dport 51871 -m comment --comment 'SEC-2291 deny WireGuard from outside' -j DROP
#
#   The handshake usually recovers within seconds (WireGuard retries the
#   handshake automatically). Watch RX grow:
#     docker exec ckne-enc-lab-worker ip -s link show cilium_wg0
#
# ---------------------------------------------------------------------------
# STEP 6 - Verify
# ---------------------------------------------------------------------------
#   ./lab.sh check
#     [PASS] cilium-config enable-wireguard=true
#     [PASS] cilium-config encrypt-node=true
#     [PASS] cilium-xxxxx: Encryption: Wireguard     (x3)
#     [PASS] client reaches the server pod
#     [PASS] hostclient reaches the server pod
#     [PASS] pod-to-pod: only WireGuard (udp/51871) observed, payload not readable
#     [PASS] node-to-pod: only WireGuard (udp/51871) observed, payload not readable
#     LAB SOLVED
#
#   Manual proof: repeat the tcpdump from STEP 0. You now see only
#   "172.18.0.x.51871 > 172.18.0.y.51871: UDP, length NNN" with unreadable
#   payload, and no udp/8472 carrying the HTTP payload on eth0 for that flow.
#
# ---------------------------------------------------------------------------
# PRODUCTION TAKEAWAYS
# ---------------------------------------------------------------------------
#   - Firewall / security groups between nodes must allow the encryption
#     transport: WireGuard = UDP 51871. IPsec = IP protocol 50 (ESP), plus
#     the overlay port if you tunnel. Put it in the node firewall IaC, not in
#     ad-hoc iptables commands (a node reboot here would also "fix" the lab,
#     and then the real rule would come back with the next config push).
#   - Encryption that fails closed turns a firewall mistake into an outage.
#     That is correct behavior: the incident process must forbid "disable
#     encryption" as a mitigation for regulated workloads.
#   - Alert on it: scrape Cilium metrics and run "cilium-dbg encrypt status"
#     / "cilium-health status" in your checks; a drop in peers or a
#     non-WireGuard mode is a compliance incident, not only a network one.
#   - WireGuard vs IPsec: WireGuard gives automatic per-node keys and a
#     simpler setup. IPsec is the choice when you need FIPS-validated
#     algorithms or explicit key management, and then you own key rotation
#     (increment the key ID in 'cilium-ipsec-keys').
#   - Strict mode (encryption.strictMode.*) can drop unencrypted pod traffic
#     to a CIDR instead of letting it leak. Check the Cilium docs for your
#     version's routing-mode requirements before you enable it.
#   - Encryption in transit does not replace NetworkPolicy or mTLS at L7:
#     it protects the node-to-node wire, not same-node traffic or who is
#     allowed to talk to whom.
# =============================================================================