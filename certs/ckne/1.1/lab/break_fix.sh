#!/usr/bin/env bash
# =============================================================================
#  CKNE - Topic 1.1: Installing and Configuring CNI Plugins
#  BREAK & FIX LAB: "The node that forgot how to wire pods"
# =============================================================================
#
#  Run this ONLY on a disposable lab VM: a kubeadm node that uses containerd
#  (or CRI-O) and already has a working CNI (Calico, Flannel, Cilium, bridge...).
#  Run it as root ON THE NODE whose CNI you want to break.
#
#  What this script does:
#    break    -> adds two controlled faults to the node's CNI setup
#    check    -> checks whether you fixed them (read-only)
#    restore  -> puts everything back from the backup (emergency exit)
#    status   -> shows lab state and the symptom
#
#  Safety:
#    * Nothing is deleted. /etc/cni/net.d and the permissions of the altered
#      binary are backed up to /var/lib/bnf-cni-lab before anything changes.
#    * Running pods keep their network. CNI runs only when a pod sandbox is
#      created or destroyed (ADD/DEL), so only NEW pods are affected.
#    * It will not run unless you pass --i-am-on-a-lab-vm.
#
#  Official references:
#    https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#    https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
#    https://www.cni.dev/docs/spec/
#    https://github.com/containerd/containerd/blob/main/docs/cri/config.md
#
#  Usage:
#    sudo ./bnf-cni-1.1.sh break   --i-am-on-a-lab-vm
#    sudo ./bnf-cni-1.1.sh status
#    sudo ./bnf-cni-1.1.sh check
#    sudo ./bnf-cni-1.1.sh restore --i-am-on-a-lab-vm
#
#  Optional environment variables:
#    KUBECONFIG    (default: /etc/kubernetes/admin.conf if it exists)
#    CNI_CONF_DIR  (default: /etc/cni/net.d)
#    CNI_BIN_DIR   (default: /opt/cni/bin)
#    NODE_NAME     (default: detected from the hostname)
# =============================================================================

set -euo pipefail

CNI_CONF_DIR="${CNI_CONF_DIR:-/etc/cni/net.d}"
CNI_BIN_DIR="${CNI_BIN_DIR:-/opt/cni/bin}"
STATE_DIR="/var/lib/bnf-cni-lab"
LAB_NS="bnf-cni"
LAB_POD="wire-me"
SHADOW_CONF="00-lab-shadow.conflist"
BROKEN_TYPE="lab-bridge-v2"

if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_off=$'\e[0m'
info() { printf '%s[i]%s %s\n' "$c_cyn" "$c_off" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*"; }
fail() { printf '%s[X]%s %s\n' "$c_red" "$c_off" "$*"; }
die()  { fail "$*"; exit 1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (sudo): the script edits ${CNI_CONF_DIR} and ${CNI_BIN_DIR}."
}

require_lab_flag() {
  local flag="${1:-}"
  [[ "$flag" == "--i-am-on-a-lab-vm" ]] || die "Refusing to run without --i-am-on-a-lab-vm. This lab breaks pod networking on this node."
}

require_tools() {
  local t
  for t in kubectl grep sed awk sort stat chmod cp; do
    command -v "$t" >/dev/null 2>&1 || die "Missing tool: $t"
  done
  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "kubectl cannot reach the API server. Export KUBECONFIG or run this on a control-plane node."
}

detect_node() {
  if [[ -n "${NODE_NAME:-}" ]]; then
    kubectl get node "$NODE_NAME" >/dev/null 2>&1 || die "NODE_NAME=${NODE_NAME} does not exist in the cluster."
    echo "$NODE_NAME"; return
  fi
  local h short n
  h="$(hostname -f 2>/dev/null || hostname)"
  short="$(hostname -s 2>/dev/null || hostname)"
  for n in "$h" "$short" "$(hostname)"; do
    if kubectl get node "$n" >/dev/null 2>&1; then echo "$n"; return; fi
  done
  die "Could not match this host to a Kubernetes node. Set NODE_NAME=<node>."
}

# The container runtime loads the LEXICALLY FIRST valid file in the conf dir
# (containerd: max_conf_num = 1 by default). This picks the same one.
active_conf() {
  find "$CNI_CONF_DIR" -maxdepth 1 -type f \( -name '*.conflist' -o -name '*.conf' -o -name '*.json' \) \
    2>/dev/null | LC_ALL=C sort | head -n1
}

# The first "type" in a conflist is the main plugin (calico, flannel, cilium-cni, bridge...)
primary_type() {
  local f="$1"
  grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" | head -n1 | sed 's/.*"\([^"]*\)"$/\1/'
}

apply_test_pod() {
  local node="$1"
  kubectl get ns "$LAB_NS" >/dev/null 2>&1 || kubectl create ns "$LAB_NS" >/dev/null
  kubectl -n "$LAB_NS" delete pod "$LAB_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${LAB_POD}
  namespace: ${LAB_NS}
  labels:
    app: bnf-cni
spec:
  nodeName: ${node}
  tolerations:
  - operator: "Exists"
  terminationGracePeriodSeconds: 1
  containers:
  - name: probe
    image: registry.k8s.io/pause:3.10
EOF
}

# ----------------------------------------------------------------------------
cmd_break() {
  require_root
  require_lab_flag "${1:-}"
  require_tools
  [[ -e "$STATE_DIR/broken" ]] && die "The lab is already broken. Use 'status', 'check' or 'restore'."
  [[ -d "$CNI_CONF_DIR" ]] || die "${CNI_CONF_DIR} does not exist: this node has no CNI installed."

  local node conf ptype pbin
  node="$(detect_node)"
  conf="$(active_conf)"
  [[ -n "$conf" ]] || die "No CNI config found in ${CNI_CONF_DIR}. Install a CNI plugin first."
  ptype="$(primary_type "$conf")"
  [[ -n "$ptype" ]] || die "Could not read the main plugin type from ${conf}."
  pbin="${CNI_BIN_DIR}/${ptype}"

  info "Node:                 ${node}"
  info "Active CNI config:    ${conf}"
  info "Main plugin:          ${ptype} (${pbin})"

  # Baseline: the network must work BEFORE we break it
  info "Checking baseline: a new pod must get an IP..."
  apply_test_pod "$node"
  if ! kubectl -n "$LAB_NS" wait pod/"$LAB_POD" --for=condition=Ready --timeout=90s >/dev/null 2>&1; then
    kubectl -n "$LAB_NS" delete ns "$LAB_NS" --wait=false >/dev/null 2>&1 || true
    die "The baseline pod did not reach Ready. Pod networking was already broken; fix it before running the lab."
  fi
  ok "Baseline OK: pod IP $(kubectl -n "$LAB_NS" get pod "$LAB_POD" -o jsonpath='{.status.podIP}')"
  kubectl -n "$LAB_NS" delete pod "$LAB_POD" --wait=true >/dev/null

  # Backup
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cp -a "$CNI_CONF_DIR" "$STATE_DIR/net.d.bak"
  {
    echo "NODE=${node}"
    echo "ORIG_CONF=${conf}"
    echo "PTYPE=${ptype}"
    echo "PBIN=${pbin}"
  } > "$STATE_DIR/state.env"

  # FAULT 1: a config that sorts first and shadows the real one.
  # The file itself is valid JSON; the error only appears on CNI ADD, when
  # libcni looks for the "lab-bridge-v2" binary in the bin dir.
  cat > "${CNI_CONF_DIR}/${SHADOW_CONF}" <<EOF
{
  "cniVersion": "1.0.0",
  "name": "lab-shadow-net",
  "plugins": [
    {
      "type": "${BROKEN_TYPE}",
      "bridge": "cni-lab0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{ "subnet": "10.250.0.0/24" }]],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    },
    {
      "type": "portmap",
      "capabilities": { "portMappings": true }
    }
  ]
}
EOF
  chmod 0644 "${CNI_CONF_DIR}/${SHADOW_CONF}"

  # FAULT 2: the real plugin binary loses its execute bit.
  # It only shows up after fault 1 is fixed (the classic layered failure).
  if [[ -f "$pbin" ]]; then
    stat -c '%a' "$pbin" > "$STATE_DIR/pbin.mode"
    chmod a-x "$pbin"
    echo "FAULT2=1" >> "$STATE_DIR/state.env"
  else
    warn "${pbin} does not exist (non-standard bin dir?). Only fault 1 will be applied."
    echo "FAULT2=0" >> "$STATE_DIR/state.env"
  fi

  touch "$STATE_DIR/broken"

  # Pod that shows the symptom
  apply_test_pod "$node"
  sleep 8

  cat <<EOF

${c_red}=====================================================================
 LAB BROKEN
=====================================================================${c_off}

 SCENARIO
   A colleague "tested a bridge plugin upgrade" on node ${node} and
   went on vacation. Since then no new pod on this node gets networking.
   Pods that were already running still work fine.

 SYMPTOM YOU WILL SEE
   \$ kubectl -n ${LAB_NS} get pod ${LAB_POD}
   NAME      READY   STATUS              RESTARTS   AGE
   wire-me   0/1     ContainerCreating   0          30s

   \$ kubectl -n ${LAB_NS} describe pod ${LAB_POD} | tail -n 3
   Warning  FailedCreatePodSandBox  ...  Failed to create pod sandbox:
     rpc error: code = Unknown desc = failed to setup network for sandbox
     "...": plugin type="${BROKEN_TYPE}" failed (add): failed to find
     plugin "${BROKEN_TYPE}" in path [${CNI_BIN_DIR}]

   Note: the Node probably still shows Ready. The runtime loaded a
   config that parses fine; it only fails when it runs the plugin.

 YOUR GOAL
   1. Pod ${LAB_NS}/${LAB_POD} reaches Running/Ready and has a podIP
      from the cluster's real Pod CIDR (not 10.250.0.0/24).
   2. The node uses the ORIGINAL CNI config (${conf##*/}) again.
   3. Every binary the active config references exists and is executable.
   4. Do NOT reinstall the CNI or delete ${CNI_CONF_DIR} wholesale.
      Find the exact cause(s). There may be more than one.

 USEFUL TOOLS
   kubectl describe / get events, crictl info, journalctl -u containerd
   (or -u crio), journalctl -u kubelet, ls -l, cat, the CNI spec.

 CHECK YOUR PROGRESS:  sudo $0 check
 EMERGENCY EXIT:       sudo $0 restore --i-am-on-a-lab-vm
=====================================================================
EOF
}

# ----------------------------------------------------------------------------
cmd_status() {
  require_tools
  if [[ -e "$STATE_DIR/broken" ]]; then
    warn "The lab is BROKEN (state in ${STATE_DIR})."
  else
    info "The lab is not active."
  fi
  info "Config files in ${CNI_CONF_DIR} (lexical order = load order):"
  find "$CNI_CONF_DIR" -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort | sed 's/^/     /'
  info "Test pod:"
  kubectl -n "$LAB_NS" get pod "$LAB_POD" -o wide 2>/dev/null | sed 's/^/     /' || echo "     (does not exist)"
  info "Latest pod events:"
  kubectl -n "$LAB_NS" get events --field-selector involvedObject.name="$LAB_POD" \
    --sort-by=.lastTimestamp 2>/dev/null | tail -n 3 | sed 's/^/     /' || true
}

# ----------------------------------------------------------------------------
cmd_check() {
  require_root
  require_tools
  [[ -f "$STATE_DIR/state.env" ]] || die "No lab state found. Run 'break' first."
  # shellcheck disable=SC1091
  source "$STATE_DIR/state.env"

  local passed=0 total=5 conf t missing=0

  # 1. The shadow config is gone
  if [[ ! -e "${CNI_CONF_DIR}/${SHADOW_CONF}" ]]; then
    ok "1/5 No config file shadows the real one."; passed=$((passed+1))
  else
    fail "1/5 ${SHADOW_CONF} is still in ${CNI_CONF_DIR}. Which file does the runtime load first?"
  fi

  # 2. The active config is the original one
  conf="$(active_conf)"
  if [[ "$conf" == "$ORIG_CONF" ]]; then
    ok "2/5 Active config: ${conf##*/}"; passed=$((passed+1))
  else
    fail "2/5 Active config is '${conf:-none}', expected '${ORIG_CONF}'."
  fi

  # 3. Every binary referenced by the active config exists and is executable
  if [[ -n "$conf" ]]; then
    while read -r t; do
      [[ -z "$t" ]] && continue
      if [[ ! -x "${CNI_BIN_DIR}/${t}" ]]; then
        fail "3/5 ${CNI_BIN_DIR}/${t} is missing or not executable."; missing=1
      fi
    done < <(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$conf" | sed 's/.*"\([^"]*\)"$/\1/' | sort -u)
  else
    missing=1
  fi
  if [[ $missing -eq 0 ]]; then
    ok "3/5 Every plugin referenced by the active config is executable."; passed=$((passed+1))
  fi

  # 4. The test pod is Ready
  if kubectl -n "$LAB_NS" wait pod/"$LAB_POD" --for=condition=Ready --timeout=45s >/dev/null 2>&1; then
    ok "4/5 ${LAB_NS}/${LAB_POD} is Ready."; passed=$((passed+1))
  else
    fail "4/5 ${LAB_NS}/${LAB_POD} is not Ready. Check 'kubectl describe' (the kubelet retries with backoff)."
  fi

  # 5. The IP does not come from the lab's fake network
  local ip
  ip="$(kubectl -n "$LAB_NS" get pod "$LAB_POD" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  if [[ -n "$ip" && "$ip" != 10.250.0.* ]]; then
    ok "5/5 podIP ${ip} comes from the real network."; passed=$((passed+1))
  else
    fail "5/5 podIP '${ip:-none}' is not valid (empty, or from 10.250.0.0/24)."
  fi

  echo
  if [[ $passed -eq $total ]]; then
    ok "LAB SOLVED (${passed}/${total}). Clean up with: kubectl delete ns ${LAB_NS}; rm -rf ${STATE_DIR}"
    rm -f "$STATE_DIR/broken"
  else
    warn "Progress: ${passed}/${total}. Keep going."
    exit 1
  fi
}

# ----------------------------------------------------------------------------
cmd_restore() {
  require_root
  require_lab_flag "${1:-}"
  [[ -f "$STATE_DIR/state.env" ]] || die "No backup found in ${STATE_DIR}."
  # shellcheck disable=SC1091
  source "$STATE_DIR/state.env"

  rm -f "${CNI_CONF_DIR}/${SHADOW_CONF}"
  if [[ -d "$STATE_DIR/net.d.bak" ]]; then
    cp -a "$STATE_DIR/net.d.bak/." "$CNI_CONF_DIR/"
  fi
  if [[ "${FAULT2:-0}" == "1" && -f "$STATE_DIR/pbin.mode" && -f "$PBIN" ]]; then
    chmod "$(cat "$STATE_DIR/pbin.mode")" "$PBIN"
  fi
  kubectl delete ns "$LAB_NS" --wait=false >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
  ok "Restored. ${CNI_CONF_DIR} and ${PBIN} are back to their original state."
}

# ----------------------------------------------------------------------------
case "${1:-}" in
  break)   shift; cmd_break "${1:-}" ;;
  check)   cmd_check ;;
  status)  cmd_status ;;
  restore) shift; cmd_restore "${1:-}" ;;
  -h|--help|"") usage 0 ;;
  *) usage 1 ;;
esac

exit 0

# =============================================================================
#  SOLUTION (do not read it before trying)
# =============================================================================
#
#  --- Step 1: read the symptom where it is written --------------------------
#
#    kubectl -n bnf-cni describe pod wire-me
#      Warning  FailedCreatePodSandBox  kubelet  Failed to create pod sandbox:
#      ... plugin type="lab-bridge-v2" failed (add): failed to find plugin
#      "lab-bridge-v2" in path [/opt/cni/bin]
#
#    Key point: the kubelet does not run CNI. It asks the runtime for a
#    sandbox through CRI (RunPodSandbox), and the runtime (containerd/CRI-O)
#    runs the plugins through libcni. That is why the error comes back
#    wrapped in "rpc error" and why the detail is also in the runtime's
#    journal:
#
#    journalctl -u containerd --since "10 min ago" | grep -i cni
#
#  --- Step 2: which config is the runtime actually using? -------------------
#
#    ls -l /etc/cni/net.d/
#      -rw-r--r-- 1 root root  512 ... 00-lab-shadow.conflist   <-- sorts first
#      -rw-r--r-- 1 root root  680 ... 10-calico.conflist        (or 10-flannel...)
#
#    crictl info | grep -A3 -i '"cni"'
#      "confDir": "/etc/cni/net.d",
#      "binDirs": ["/opt/cni/bin"],
#      "maxConfNum": 1,
#
#    crictl info | grep -i '"name"' | head
#      shows "lab-shadow-net": the loaded network is not the cluster's.
#
#    containerd (CRI plugin) sorts the files in confDir lexically and loads
#    up to max_conf_num (default 1). The first one wins. A leftover file
#    named 00-* silently shadows the real CNI. It parses fine, so the Node
#    stays Ready; it only fails on the CNI ADD for each new pod.
#
#    ls /opt/cni/bin/lab-bridge-v2
#      ls: cannot access '/opt/cni/bin/lab-bridge-v2': No such file or directory
#
#    The "type" field of each plugin is the NAME OF THE BINARY that libcni
#    looks for in binDirs (CNI spec, "Plugin configuration objects").
#
#  --- Step 3: take the shadow config out (move it, don't delete it: evidence)
#
#    mkdir -p /root/cni-quarantine
#    mv /etc/cni/net.d/00-lab-shadow.conflist /root/cni-quarantine/
#
#    containerd watches confDir (fsnotify) and reloads without a restart.
#    CRI-O does too. If in doubt:
#      systemctl restart containerd     # running pods are not affected
#
#  --- Step 4: the SECOND fault appears (it was hidden behind the first) -----
#
#    kubectl -n bnf-cni describe pod wire-me | tail -n 2
#      ... plugin type="calico" failed (add): fork/exec /opt/cni/bin/calico:
#      permission denied
#    (with Flannel: /opt/cni/bin/flannel; with Cilium: /opt/cni/bin/cilium-cni)
#
#    ls -l /opt/cni/bin/calico
#      -rw-r--r-- 1 root root 59M ... /opt/cni/bin/calico      <-- no 'x'
#
#    Compare with its neighbours:
#    ls -l /opt/cni/bin/ | head
#      -rwxr-xr-x 1 root root 4.0M ... bandwidth
#      -rwxr-xr-x 1 root root 4.4M ... bridge
#      ...
#
#  --- Step 5: restore the execute bit ---------------------------------------
#
#    chmod 0755 /opt/cni/bin/calico           # use the real binary name
#
#    Note: with Calico, Cilium and Flannel, the DaemonSet's init container
#    (install-cni) copies the binaries back when the agent pod restarts.
#    The "operator" alternative would be:
#      kubectl -n kube-system delete pod -l k8s-app=calico-node \
#        --field-selector spec.nodeName=<node>
#    But in the exam, fixing the exact cause is faster and shows you
#    understand it. Also check the whole chain the config references
#    (the main plugin + IPAM + portmap/bandwidth/tuning):
#
#      for t in $(grep -o '"type": *"[^"]*"' /etc/cni/net.d/10-*.conflist \
#                 | cut -d'"' -f4 | sort -u); do
#        test -x /opt/cni/bin/$t && echo "OK  $t" || echo "BAD $t"
#      done
#
#  --- Step 6: verify ---------------------------------------------------------
#
#    The kubelet retries sandbox creation with exponential backoff, so you
#    don't need to recreate the pod (you can delete it to speed things up):
#
#    kubectl -n bnf-cni get pod wire-me -o wide -w
#      NAME      READY   STATUS    RESTARTS   AGE   IP              NODE
#      wire-me   1/1     Running   0          6m    192.168.35.201  node1
#
#    The IP must come from the cluster's Pod CIDR:
#      kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
#      kubectl -n kube-system get cm kubeadm-config -o yaml | grep podSubnet
#
#    sudo ./bnf-cni-1.1.sh check
#      [OK] 1/5 No config file shadows the real one.
#      [OK] 2/5 Active config: 10-calico.conflist
#      [OK] 3/5 Every plugin referenced by the active config is executable.
#      [OK] 4/5 bnf-cni/wire-me is Ready.
#      [OK] 5/5 podIP 192.168.35.201 comes from the real network.
#      [OK] LAB SOLVED (5/5).
#
#  --- Step 7: cleanup ---------------------------------------------------------
#
#    kubectl delete ns bnf-cni
#    rm -rf /var/lib/bnf-cni-lab /root/cni-quarantine
#
#  --- Lessons for the exam ----------------------------------------------------
#
#    1. Pod stuck in ContainerCreating + FailedCreatePodSandBox = look at CNI
#       before anything else. A Ready Node does NOT prove CNI works.
#    2. The runtime loads the lexically first file in /etc/cni/net.d.
#       One leftover file (00-*, 05-*, 99-backup.conflist.bak ending in
#       .conflist) changes the whole node's network.
#    3. "type" = binary name in bin_dir. "failed to find plugin" = missing
#       binary or wrong bin_dir (check with crictl info / config.toml).
#    4. "permission denied" on fork/exec = file permissions or noexec,
#       not network policy.
#    5. Faults stack up: after fixing one, read the NEW event, don't assume.
#    6. Running pods are not affected: CNI only runs on ADD/DEL/CHECK.
# =============================================================================