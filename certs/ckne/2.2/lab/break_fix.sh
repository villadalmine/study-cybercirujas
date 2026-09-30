#!/usr/bin/env bash
# =============================================================================
# CKNE 2.2 - Understanding kube-proxy and CNI Alternatives
# Break & Fix lab: "The Service that never was"
#
# Where to run it: a DISPOSABLE lab cluster (kubeadm, kind, or a single-node
# VM) where kube-proxy runs as the DaemonSet kube-system/kube-proxy. Never run
# it against a shared or production cluster.
#
# What it breaks, safely and reversibly:
#   It edits the kube-proxy DaemonSet's nodeSelector so that no node matches.
#   The DaemonSet controller then deletes every kube-proxy Pod. The iptables,
#   nftables, or IPVS rules those Pods already wrote stay in the kernel, so
#   existing Services keep working. Anything that changes after the break is
#   never programmed into the data plane.
#
# What this teaches:
#   - kube-proxy is a controller. It watches Services and EndpointSlices and
#     programs the kernel. It is not in the packet path, which is why it can
#     die without an immediate outage.
#   - The control plane (the Service object and its EndpointSlices) and the
#     data plane (the kernel rules) can disagree. You have to check both.
#   - How to tell "kube-proxy is broken" apart from "this cluster has no
#     kube-proxy by design", for example Cilium kube-proxy replacement or
#     Calico eBPF.
#
# Usage:
#   ./break-fix-kube-proxy.sh break    # set up the workload and break kube-proxy
#   ./break-fix-kube-proxy.sh verify   # check whether your fix worked
#   ./break-fix-kube-proxy.sh reset    # restore the original state and clean up
#
# References:
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/reference/networking/virtual-ips/
#   https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
#   https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
#   https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
#   https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
# =============================================================================
set -euo pipefail

NS="bf-kproxy"
DS_NS="kube-system"
DS_NAME="kube-proxy"
POD_SELECTOR="k8s-app=kube-proxy"
STATE_DIR="${HOME}/.bf-kube-proxy"
STATE_FILE="${STATE_DIR}/original-nodeselector.json"
WEB_IMAGE="nginx:1.27-alpine"
CLIENT_IMAGE="busybox:1.36"

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()   { printf '\033[33m%s\033[0m\n' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()     { c_red "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH."
  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "Cannot reach the API server. Check your kubeconfig and current context."

  if ! kubectl -n "${DS_NS}" get ds "${DS_NAME}" >/dev/null 2>&1; then
    c_yel "There is no DaemonSet ${DS_NS}/${DS_NAME} in this cluster."
    c_yel "It most likely runs without kube-proxy (for example Cilium with"
    c_yel "kubeProxyReplacement=true, or Calico in eBPF mode). Service load"
    c_yel "balancing then happens in eBPF programs and this lab does not apply."
    c_yel "Check with: cilium status | grep KubeProxyReplacement"
    exit 2
  fi
}

confirm_lab() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  c_bold "Current kube-context: ${ctx}"
  c_yel  "This lab stops kube-proxy on EVERY node in this cluster."
  if [[ "${BF_LAB_CONFIRM:-}" == "yes" ]]; then
    return 0
  fi
  read -r -p "Is this a disposable lab cluster? Type 'yes' to continue: " ans
  [[ "${ans}" == "yes" ]] || die "Aborted by user."
}

proxy_mode() {
  local mode
  mode="$(kubectl -n "${DS_NS}" get cm kube-proxy \
          -o jsonpath='{.data.config\.conf}' 2>/dev/null \
          | awk '/^mode:/ {gsub(/"/,"",$2); print $2}' || true)"
  echo "${mode:-iptables (default)}"
}

kp_pod_count() {
  kubectl -n "${DS_NS}" get pods -l "${POD_SELECTOR}" \
    --field-selector=status.phase!=Succeeded -o name 2>/dev/null | wc -l
}

linux_node_count() {
  kubectl get nodes -l kubernetes.io/os=linux -o name | wc -l
}

# Runs wget from the client Pod against a Service. Returns 0 if the Service answers.
probe() {
  local svc="$1"
  kubectl -n "${NS}" exec client -- \
    wget -q -O /dev/null -T 3 "http://${svc}.${NS}.svc.cluster.local" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Workload: one backend Deployment, one Service created BEFORE the break,
# and a client Pod to test from.
# -----------------------------------------------------------------------------
deploy_workload() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ${NS}
  labels:
    app: web
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
        - name: nginx
          image: ${WEB_IMAGE}
          ports:
            - containerPort: 80
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: web-old
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
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: ${NS}
  labels:
    app: client
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: client
      image: ${CLIENT_IMAGE}
      command: ["sleep", "86400"]
EOF

  echo "Waiting for the workload to become ready..."
  kubectl -n "${NS}" rollout status deploy/web --timeout=180s >/dev/null
  kubectl -n "${NS}" wait --for=condition=Ready pod/client --timeout=180s >/dev/null

  # Give kube-proxy a moment to program web-old before the break.
  local i
  for i in $(seq 1 20); do
    if probe web-old; then
      c_green "Baseline OK: web-old answers through its ClusterIP."
      return 0
    fi
    sleep 2
  done
  die "Baseline failed: web-old does not answer while kube-proxy is healthy. Fix the cluster before running this lab."
}

create_new_service() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: web-new
  namespace: ${NS}
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
EOF
}

# -----------------------------------------------------------------------------
# break
# -----------------------------------------------------------------------------
do_break() {
  preflight
  if [[ -f "${STATE_FILE}" ]]; then
    c_yel "The lab is already broken (state file ${STATE_FILE} exists)."
    c_yel "Run '$0 verify' to check your fix, or '$0 reset' to start over."
    exit 0
  fi
  confirm_lab

  c_bold "kube-proxy mode detected: $(proxy_mode)"
  deploy_workload

  mkdir -p "${STATE_DIR}"
  local orig
  orig="$(kubectl -n "${DS_NS}" get ds "${DS_NAME}" \
          -o jsonpath='{.spec.template.spec.nodeSelector}')"
  printf '%s\n' "${orig:-null}" > "${STATE_FILE}"

  # The break: a one-letter typo in the OS node selector. No node carries
  # kubernetes.io/os=linx, so the DaemonSet wants 0 Pods.
  kubectl -n "${DS_NS}" patch ds "${DS_NAME}" --type merge \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linx"}}}}}' >/dev/null

  echo "Waiting for the kube-proxy Pods to terminate..."
  local i
  for i in $(seq 1 60); do
    [[ "$(kp_pod_count)" -eq 0 ]] && break
    sleep 2
  done

  # This change arrives AFTER the break, so nothing programs it into the kernel.
  create_new_service
  sleep 3

  cat <<EOF

$(c_bold "=================== SCENARIO ===================")
Ticket from the application team:

  "We added a second Service, bf-kproxy/web-new, in front of the same 'web'
   Deployment. 'kubectl get svc' shows it with a ClusterIP, and its
   EndpointSlice lists both Pods. But every request to it times out, while
   web-old, which points at the SAME Pods, works fine. Please fix it."

$(c_bold "What you will see:")
  kubectl -n ${NS} exec client -- wget -qO- -T 3 http://web-old   -> nginx welcome page
  kubectl -n ${NS} exec client -- wget -qO- -T 3 http://web-new   -> wget: download timed out
  kubectl -n ${NS} get endpointslices                               -> web-new has 2 ready endpoints

$(c_bold "Your goal:")
  1. Explain why the old Service works and the new one does not.
  2. Find the root cause. Do not work around it (no NodePort, no hostNetwork,
     no connecting to Pod IPs).
  3. Put the cluster back in a state where EVERY Service, including new
     ones, is programmed on every Linux node.
  4. Run: $0 verify

$(c_bold "Rules:")
  Do not delete or re-create the web-new Service. The fix belongs in the
  component that failed, not in the application.

Hints, if you need them (read one at a time):
  H1: Which component turns a Service into kernel rules? Is it running?
  H2: kubectl -n kube-system get ds kube-proxy -o wide   (look at DESIRED and NODE SELECTOR)
  H3: Compare the DaemonSet's nodeSelector with: kubectl get nodes --show-labels
EOF
}

# -----------------------------------------------------------------------------
# verify
# -----------------------------------------------------------------------------
do_verify() {
  preflight
  local ok=1 desired ready nodes sel

  nodes="$(linux_node_count)"
  desired="$(kubectl -n "${DS_NS}" get ds "${DS_NAME}" -o jsonpath='{.status.desiredNumberScheduled}')"
  ready="$(kubectl -n "${DS_NS}" get ds "${DS_NAME}" -o jsonpath='{.status.numberReady}')"
  sel="$(kubectl -n "${DS_NS}" get ds "${DS_NAME}" -o jsonpath='{.spec.template.spec.nodeSelector}')"

  echo "Linux nodes: ${nodes} | kube-proxy desired: ${desired:-0} | ready: ${ready:-0}"
  echo "kube-proxy nodeSelector: ${sel:-<none>}"

  if [[ "${desired:-0}" -ne "${nodes}" ]]; then
    c_red "[FAIL] The DaemonSet does not target every Linux node."; ok=0
  else
    c_green "[PASS] The DaemonSet targets every Linux node."
  fi
  if [[ "${ready:-0}" -ne "${desired:-0}" || "${ready:-0}" -eq 0 ]]; then
    c_red "[FAIL] Not every kube-proxy Pod is Ready."; ok=0
  else
    c_green "[PASS] Every kube-proxy Pod is Ready."
  fi

  if ! kubectl -n "${NS}" get svc web-new >/dev/null 2>&1; then
    c_red "[FAIL] Service ${NS}/web-new is missing. Run '$0 reset' and then '$0 break'."; ok=0
  else
    local i passed=0
    for i in $(seq 1 10); do
      if probe web-new && probe web-old; then passed=1; break; fi
      sleep 2
    done
    if [[ "${passed}" -eq 1 ]]; then
      c_green "[PASS] web-old and web-new both answer through their ClusterIPs."
    else
      c_red "[FAIL] At least one Service still does not answer."; ok=0
    fi
  fi

  if [[ "${ok}" -eq 1 ]]; then
    c_green "Lab solved. Run '$0 reset' to clean up."
  else
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# reset
# -----------------------------------------------------------------------------
do_reset() {
  preflight
  if [[ -f "${STATE_FILE}" ]]; then
    local orig
    orig="$(cat "${STATE_FILE}")"
    if [[ "${orig}" == "null" || -z "${orig}" ]]; then
      kubectl -n "${DS_NS}" patch ds "${DS_NAME}" --type json \
        -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' >/dev/null 2>&1 || true
    else
      kubectl -n "${DS_NS}" patch ds "${DS_NAME}" --type json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":${orig}}]" >/dev/null
    fi
    kubectl -n "${DS_NS}" rollout status ds/"${DS_NAME}" --timeout=180s >/dev/null || true
    rm -f "${STATE_FILE}"
    c_green "Restored the original kube-proxy nodeSelector: ${orig}"
  else
    c_yel "No state file found; the kube-proxy DaemonSet was left untouched."
  fi
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null
  c_green "Removed namespace ${NS}."
}

case "${1:-}" in
  break)  do_break ;;
  verify) do_verify ;;
  reset)  do_reset ;;
  *) echo "Usage: $0 {break|verify|reset}"; exit 64 ;;
esac

# =============================================================================
# SOLUTION (step by step). Do not read this until you have tried.
# =============================================================================
#
# 1) Confirm the control plane is fine. The Service and its endpoints exist:
#
#      kubectl -n bf-kproxy get svc,endpointslices
#      NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
#      service/web-new   ClusterIP   10.96.142.17    <none>        80/TCP    2m
#      service/web-old   ClusterIP   10.96.201.33    <none>        80/TCP    3m
#      NAME                                     ADDRESSTYPE   PORTS   ENDPOINTS                 AGE
#      endpointslice.../web-new-xk2p9           IPv4          80      10.244.1.12,10.244.2.9    2m
#      endpointslice.../web-old-7rq4d           IPv4          80      10.244.1.12,10.244.2.9    3m
#
#    Both Services select the same healthy Pods, so the Deployment, the
#    selector, and the EndpointSlice controller are not the problem. The fault
#    is between "the API knows" and "the kernel knows".
#
# 2) Check the component that bridges the two, kube-proxy:
#
#      kubectl -n kube-system get ds kube-proxy -o wide
#      NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR           AGE
#      kube-proxy   0         0         0       0            0           kubernetes.io/os=linx   20d
#
#      kubectl -n kube-system get pods -l k8s-app=kube-proxy
#      No resources found in kube-system namespace.
#
#    DESIRED 0 on a cluster with nodes means no node matches the selector.
#    "linx" is a typo for "linux":
#
#      kubectl get nodes -L kubernetes.io/os
#      NAME     STATUS   ROLES           AGE   VERSION   OS
#      cp-1     Ready    control-plane   20d   v1.34.x   linux
#      node-1   Ready    <none>          20d   v1.34.x   linux
#
# 3) (Optional, but this is the key insight.) Look at the data plane on a node.
#    In iptables mode:
#
#      sudo iptables -t nat -S KUBE-SERVICES | grep bf-kproxy
#      -A KUBE-SERVICES -d 10.96.201.33/32 -p tcp -m comment --comment "bf-kproxy/web-old:http cluster IP" ... -j KUBE-SVC-...
#      (there is NO line for web-new)
#
#    In nftables mode:   sudo nft list table ip kube-proxy | grep bf-kproxy
#    In IPVS mode:       sudo ipvsadm -Ln | grep -A2 10.96.201.33
#                        (web-new's ClusterIP is also missing from kube-ipvs0:
#                         ip addr show kube-ipvs0)
#
#    Why web-old still works: kube-proxy does not forward packets. It writes
#    rules, and those rules stay in the kernel after the process exits (only
#    'kube-proxy --cleanup' removes them). Existing Services keep working
#    until something changes: a new Service, a Pod rescheduled to a new IP,
#    a scale-out, or a node reboot that wipes the tables. That delayed failure
#    is what makes this class of outage dangerous in production.
#
# 4) Fix the root cause by restoring the correct nodeSelector:
#
#      kubectl -n kube-system patch ds kube-proxy --type merge \
#        -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'
#
#      kubectl -n kube-system rollout status ds/kube-proxy
#      daemon set "kube-proxy" successfully rolled out
#
#    (Equivalent: kubectl -n kube-system edit ds kube-proxy and fix the typo.)
#
# 5) On startup, kube-proxy does a full sync from the API. It lists every
#    Service and EndpointSlice and reprograms the kernel, so web-new appears
#    without touching it:
#
#      kubectl -n kube-system logs ds/kube-proxy | grep -i -E 'sync|proxier'
#      kubectl -n bf-kproxy exec client -- wget -qO- -T 3 http://web-new | head -4
#      <!DOCTYPE html>
#      <html>
#      <head>
#      <title>Welcome to nginx!</title>
#
# 6) Run: ./break-fix-kube-proxy.sh verify   then   ./break-fix-kube-proxy.sh reset
#
# Takeaways for the exam and for production:
#   - Service triage ladder: Service -> EndpointSlice (control plane) ->
#     node rules (data plane) -> the component that syncs them.
#   - "Old Services work, new ones don't" points strongly at the Service
#     proxy, not at the CNI's Pod-to-Pod routing. Pod-to-Pod traffic by
#     Pod IP keeps working the whole time.
#   - Alert on the kube-proxy DaemonSet with numberReady < desiredNumberScheduled
#     AND desiredNumberScheduled < node count. A DaemonSet that wants zero
#     Pods looks "healthy" (0/0) to a naive check.
#   - With a CNI that replaces kube-proxy (Cilium kubeProxyReplacement, Calico
#     eBPF), there is no kube-proxy DaemonSet at all. There, the equivalent
#     check is the agent's own service table, for example
#     'cilium-dbg service list' inside a cilium Pod, or 'cilium status'.
#     If you see kube-proxy AND an eBPF replacement both active, that is a
#     misconfiguration: two components are programming Service load balancing.
# =============================================================================