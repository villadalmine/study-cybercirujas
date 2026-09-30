#!/usr/bin/env bash
# =============================================================================
# CKNE 2.1 - Configuring L4 Services - BREAK & FIX LAB
# =============================================================================
#
# What this lab does
# ------------------
# Deploys a small application with one TCP Service and one UDP Service into a
# dedicated, disposable namespace, then breaks both Services in three separate
# and realistic ways. Your job is to diagnose and repair the L4 plumbing
# (Service -> EndpointSlice -> Pod port) using only kubectl.
#
# Safety
# ------
# - It only touches the namespace "ckne-l4-lab". It never modifies kube-system,
#   kube-proxy, CNI configuration, iptables/nftables rules or nodes.
# - It refuses to run if the namespace already exists (use "reset").
# - Run it only against a disposable lab cluster (kind, minikube, kubeadm VM).
#
# Usage
# -----
#   ./break-fix-l4-services.sh break     # deploy the lab and inject the faults
#   ./break-fix-l4-services.sh status    # show the state and the symptoms again
#   ./break-fix-l4-services.sh verify    # check whether you fixed everything
#   ./break-fix-l4-services.sh reset     # delete the lab and break it again
#   ./break-fix-l4-services.sh cleanup   # delete the lab namespace
#
# Requirements: kubectl with a working context, nodes able to pull
# registry.k8s.io/e2e-test-images/agnhost:2.39 and busybox:1.36.
#
# References:
# - https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
# - https://kubernetes.io/docs/concepts/services-networking/service/
# - https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
# - https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
# - https://kubernetes.io/docs/reference/networking/virtual-ips/
# =============================================================================

set -euo pipefail

NS="ckne-l4-lab"
AGNHOST_IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.39"
CLIENT_IMAGE="busybox:1.36"
TIMEOUT="120s"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
c_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { c_red "ERROR: $*" >&2; exit 1; }

preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
  kubectl version --request-timeout=10s >/dev/null 2>&1 \
    || die "cannot reach the API server with the current kubectl context"

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  c_yellow "Current kubectl context: ${ctx}"
  c_yellow "This lab creates and breaks resources ONLY in namespace '${NS}'."
  if [[ "${LAB_ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "Is this a disposable lab cluster? Type 'yes' to continue: " ans
    [[ "${ans}" == "yes" ]] || die "aborted by user"
  fi
}

ns_exists() { kubectl get namespace "${NS}" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Lab deployment (with the faults injected)
# ---------------------------------------------------------------------------
deploy_lab() {
  if ns_exists; then
    die "namespace '${NS}' already exists. Use '$0 reset' or '$0 cleanup' first."
  fi

  c_bold ">>> Creating namespace ${NS}"
  kubectl create namespace "${NS}" >/dev/null
  kubectl label namespace "${NS}" purpose=ckne-break-fix >/dev/null

  c_bold ">>> Deploying backend (agnhost netexec: HTTP on 8080/TCP, echo on 8081/UDP)"
  kubectl apply -n "${NS}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
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
        tier: frontend
    spec:
      containers:
        - name: netexec
          image: ${AGNHOST_IMAGE}
          args:
            - "netexec"
            - "--http-port=8080"
            - "--udp-port=8081"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: udp-echo
              containerPort: 8081
              protocol: UDP
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
EOF

  c_bold ">>> Deploying test client pod"
  kubectl apply -n "${NS}" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels:
    app: client
spec:
  containers:
    - name: client
      image: ${CLIENT_IMAGE}
      command: ["sh", "-c", "sleep 36000"]
  terminationGracePeriodSeconds: 1
EOF

  # ------------------------------------------------------------------
  # FAULT 1: selector does not match the Pod labels  -> no endpoints
  # FAULT 2: targetPort points at a port nobody listens on (80, not 8080)
  #          (only visible once fault 1 is fixed - layered like real life)
  # ------------------------------------------------------------------
  c_bold ">>> Creating Service 'web' (TCP)"
  kubectl apply -n "${NS}" -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: web
  labels:
    app: web
spec:
  type: ClusterIP
  selector:
    app: web-frontend
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
EOF

  # ------------------------------------------------------------------
  # FAULT 3: the backend speaks UDP but the Service port says TCP
  # ------------------------------------------------------------------
  c_bold ">>> Creating Service 'echo-udp'"
  kubectl apply -n "${NS}" -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: echo-udp
  labels:
    app: web
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: echo
      port: 5353
      targetPort: 8081
      protocol: TCP
EOF

  c_bold ">>> Waiting for Pods to become Ready (timeout ${TIMEOUT})"
  kubectl -n "${NS}" rollout status deployment/web --timeout="${TIMEOUT}" >/dev/null \
    || die "deployment 'web' did not become ready (image pull problem?)"
  kubectl -n "${NS}" wait --for=condition=Ready pod/client --timeout="${TIMEOUT}" >/dev/null \
    || die "client pod did not become ready"

  c_green ">>> Lab deployed and broken."
  echo
  briefing
}

# ---------------------------------------------------------------------------
# Student briefing
# ---------------------------------------------------------------------------
briefing() {
  cat <<EOF
=============================================================================
 SCENARIO
=============================================================================
 The team shipped a small service in namespace '${NS}':

   Deployment 'web' (2 replicas, agnhost netexec)
     - HTTP API on container port 8080/TCP  (GET /hostname returns pod name)
     - Echo service on container port 8081/UDP (send "hostname", get pod name)

   Service 'web'       -> should expose the HTTP API on  web:80/TCP
   Service 'echo-udp'  -> should expose the echo on       echo-udp:5353/UDP

 A pod called 'client' is available for testing from inside the cluster.

 SYMPTOMS YOU WILL SEE
 ---------------------
 1) HTTP through the Service fails, even though both backend Pods are Running
    and Ready:

      kubectl -n ${NS} exec client -- wget -qO- -T 3 http://web/hostname
      -> "wget: can't connect to remote host (...): Connection refused"
         or "download timed out" (the exact error depends on your CNI /
         kube-proxy mode)

 2) The UDP echo never answers:

      kubectl -n ${NS} exec client -- sh -c 'echo hostname | nc -u -w 2 echo-udp 5353'
      -> no output at all

 YOUR GOAL
 ---------
 - 'wget http://web/hostname' from the client pod returns a pod name
   (web-xxxxxxxxxx-yyyyy), and repeated calls hit BOTH replicas.
 - 'echo hostname | nc -u -w 2 echo-udp 5353' returns a pod name.
 - Do NOT modify the Deployment or its Pod labels: fix the Services.
 - Do NOT touch kube-proxy, the CNI or the nodes: the data plane is healthy.

 There are THREE independent faults. Fixing one may reveal the next.

 USEFUL STARTING POINTS
 ----------------------
   kubectl -n ${NS} get svc,endpointslices -o wide
   kubectl -n ${NS} get pods --show-labels -o wide
   kubectl -n ${NS} describe svc web
   kubectl -n ${NS} get endpointslices -l kubernetes.io/service-name=web -o yaml

 When you think you are done:   $0 verify
=============================================================================
EOF
}

# ---------------------------------------------------------------------------
# Status: show current state
# ---------------------------------------------------------------------------
show_status() {
  ns_exists || die "lab is not deployed. Run '$0 break' first."
  c_bold "--- Services ---"
  kubectl -n "${NS}" get svc -o wide
  echo
  c_bold "--- EndpointSlices ---"
  kubectl -n "${NS}" get endpointslices -o wide
  echo
  c_bold "--- Pods ---"
  kubectl -n "${NS}" get pods -o wide --show-labels
  echo
  briefing
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify() {
  ns_exists || die "lab is not deployed. Run '$0 break' first."
  local failed=0

  c_bold ">>> Check 0: the Deployment was not tampered with"
  local sel
  sel="$(kubectl -n "${NS}" get deploy web -o jsonpath='{.spec.selector.matchLabels.app}')"
  if [[ "${sel}" == "web" ]]; then
    c_green "  OK   Deployment selector unchanged (app=web)"
  else
    c_red   "  FAIL Deployment selector was modified (app=${sel}); fix the Service, not the workload"
    failed=1
  fi

  c_bold ">>> Check 1: Service 'web' has ready endpoints"
  local eps
  eps="$(kubectl -n "${NS}" get endpointslices -l kubernetes.io/service-name=web \
          -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{" "}{end}' 2>/dev/null || true)"
  if [[ -n "${eps// /}" ]]; then
    c_green "  OK   ready endpoint addresses: ${eps}"
  else
    c_red   "  FAIL EndpointSlice for 'web' has no ready endpoints (selector?)"
    failed=1
  fi

  c_bold ">>> Check 2: HTTP through Service 'web' on port 80"
  local seen="" out i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out="$(kubectl -n "${NS}" exec client -- wget -qO- -T 3 http://web/hostname 2>/dev/null || true)"
    [[ -n "${out}" ]] && seen+="${out}"$'\n'
  done
  local distinct
  distinct="$(printf '%s' "${seen}" | grep -c . | tr -d ' ' || true)"
  local uniq_count
  uniq_count="$(printf '%s' "${seen}" | sort -u | grep -c . || true)"
  if [[ "${distinct}" -ge 1 ]]; then
    c_green "  OK   HTTP answered ${distinct}/10 times from: $(printf '%s' "${seen}" | sort -u | tr '\n' ' ')"
    if [[ "${uniq_count}" -lt 2 ]]; then
      c_yellow "  WARN only one backend answered; check sessionAffinity and that both Pods are Ready"
    fi
  else
    c_red   "  FAIL no HTTP response through web:80 (targetPort?)"
    failed=1
  fi

  c_bold ">>> Check 3: Service 'echo-udp' port 5353 is UDP and answers"
  local proto
  proto="$(kubectl -n "${NS}" get svc echo-udp -o jsonpath='{.spec.ports[0].protocol}')"
  if [[ "${proto}" != "UDP" ]]; then
    c_red   "  FAIL Service 'echo-udp' port protocol is '${proto}', the backend speaks UDP"
    failed=1
  fi
  out="$(kubectl -n "${NS}" exec client -- sh -c 'echo hostname | nc -u -w 2 echo-udp 5353' 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    c_green "  OK   UDP echo answered: ${out}"
  else
    c_red   "  FAIL no UDP answer from echo-udp:5353"
    failed=1
  fi

  echo
  if [[ "${failed}" -eq 0 ]]; then
    c_green "=== ALL CHECKS PASSED - lab solved. Run '$0 cleanup' when done. ==="
  else
    c_red   "=== NOT SOLVED YET - keep digging (see '$0 status') ==="
    exit 1
  fi
}

cleanup() {
  if ns_exists; then
    c_bold ">>> Deleting namespace ${NS}"
    kubectl delete namespace "${NS}" --wait=true --timeout="${TIMEOUT}"
    c_green ">>> Clean."
  else
    c_yellow "Namespace ${NS} does not exist, nothing to do."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
  break)   preflight; deploy_lab ;;
  status)  show_status ;;
  verify)  verify ;;
  reset)   preflight; cleanup; deploy_lab ;;
  cleanup) cleanup ;;
  *)
    echo "Usage: $0 {break|status|verify|reset|cleanup}"
    exit 2
    ;;
esac

# =============================================================================
# SOLUTION - STEP BY STEP (do not read before trying!)
# =============================================================================
#
# How a ClusterIP Service works at L4, and where it can break:
#
#   client -> ClusterIP:port/PROTO  (virtual IP, programmed by kube-proxy or
#                                     the CNI's eBPF replacement per protocol)
#          -> DNAT to one ready endpoint (PodIP:targetPort/PROTO)
#
#   The EndpointSlice controller builds the endpoint list from:
#     - spec.selector          -> which Pods
#     - ports[].targetPort     -> which port on those Pods (number or name)
#     - ports[].protocol       -> TCP | UDP | SCTP, part of the rule itself
#   None of these are validated against what the Pod actually listens on.
#   The API accepts a Service that can never work.
#
# -----------------------------------------------------------------------------
# FAULT 1 - selector mismatch -> empty EndpointSlice
# -----------------------------------------------------------------------------
#   Diagnose:
#     kubectl -n ckne-l4-lab describe svc web
#       Selector:   app=web-frontend
#       Endpoints:  <none>                      <-- the giveaway
#     kubectl -n ckne-l4-lab get pods --show-labels
#       web-...   app=web,tier=frontend,...
#     kubectl -n ckne-l4-lab get pods -l app=web-frontend
#       No resources found                      <-- the selector matches nothing
#
#   With no endpoints, kube-proxy (iptables mode) installs a REJECT rule for the
#   ClusterIP, so the client gets "Connection refused" immediately instead of a
#   timeout. That is why "refused" does NOT always mean "the app isn't listening".
#
#   Fix (the Service selector must match the Pod template labels):
#     kubectl -n ckne-l4-lab patch svc web --type=merge \
#       -p '{"spec":{"selector":{"app":"web"}}}'
#
#   Confirm:
#     kubectl -n ckne-l4-lab get endpointslices -l kubernetes.io/service-name=web
#       NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
#       web-xxxxx   IPv4          80      10.244.1.5,10.244.2.7   ...
#
#   Note the PORTS column says 80: the next fault is already visible here.
#
# -----------------------------------------------------------------------------
# FAULT 2 - wrong targetPort -> endpoints exist, but nothing listens there
# -----------------------------------------------------------------------------
#   Diagnose:
#     kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://web/hostname
#       wget: can't connect to remote host (10.96.x.y): Connection refused
#     # Bypass the Service and talk to a Pod directly:
#     POD_IP=$(kubectl -n ckne-l4-lab get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
#     kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://$POD_IP:80/hostname
#       Connection refused                      <-- the Pod rejects port 80
#     kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://$POD_IP:8080/hostname
#       web-6d9c...                             <-- the app is on 8080
#     kubectl -n ckne-l4-lab get deploy web \
#       -o jsonpath='{.spec.template.spec.containers[0].ports}'
#
#   Fix - prefer the NAMED port, so a future change of containerPort in the
#   Deployment does not silently break the Service again:
#     kubectl -n ckne-l4-lab patch svc web --type=json \
#       -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
#
#   Confirm (repeat a few times; you should see both replicas):
#     for i in 1 2 3 4 5 6; do
#       kubectl -n ckne-l4-lab exec client -- wget -qO- -T 3 http://web/hostname; echo
#     done
#
# -----------------------------------------------------------------------------
# FAULT 3 - protocol mismatch -> TCP Service in front of a UDP listener
# -----------------------------------------------------------------------------
#   Diagnose:
#     kubectl -n ckne-l4-lab get svc echo-udp
#       NAME       TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)    AGE
#       echo-udp   ClusterIP   10.96.a.b     <none>        5353/TCP   ...
#     kubectl -n ckne-l4-lab get deploy web \
#       -o jsonpath='{range .spec.template.spec.containers[0].ports[*]}{.name}{" "}{.containerPort}/{.protocol}{"\n"}{end}'
#       http 8080/TCP
#       udp-echo 8081/UDP
#     # Direct test against the Pod proves the app works over UDP:
#     kubectl -n ckne-l4-lab exec client -- sh -c "echo hostname | nc -u -w 2 $POD_IP 8081"
#       web-6d9c...
#
#   kube-proxy only programs rules for the protocol declared in the Service.
#   UDP datagrams to 10.96.a.b:5353 match no rule and are dropped silently.
#   UDP has no handshake, so the symptom is "no output", not an error.
#
#   Fix:
#     kubectl -n ckne-l4-lab patch svc echo-udp --type=json -p '[
#       {"op":"replace","path":"/spec/ports/0/protocol","value":"UDP"},
#       {"op":"replace","path":"/spec/ports/0/targetPort","value":"udp-echo"}
#     ]'
#
#   Confirm:
#     kubectl -n ckne-l4-lab exec client -- sh -c 'echo hostname | nc -u -w 2 echo-udp 5353'
#       web-6d9c...
#
#   Production note: if you need the same port number on BOTH TCP and UDP
#   (the classic DNS case, 53/TCP + 53/UDP), list two entries in spec.ports
#   with distinct names. Both are supported, including on type LoadBalancer
#   (MixedProtocolLBService, GA since Kubernetes 1.26), subject to your
#   cloud/LB implementation.
#
#   UDP conntrack gotcha: after changing UDP backends, stale conntrack entries
#   can keep sending traffic to an old Pod IP until they expire. kube-proxy
#   clears them for Service changes it knows about; on a node you can inspect
#   them with:  conntrack -L -p udp --dport 5353
#
# -----------------------------------------------------------------------------
# Final check
# -----------------------------------------------------------------------------
#   ./break-fix-l4-services.sh verify
#     === ALL CHECKS PASSED - lab solved. ===
#
# The fixed Services, for reference:
#
#   apiVersion: v1
#   kind: Service
#   metadata:
#     name: web
#   spec:
#     type: ClusterIP
#     selector:
#       app: web
#     ports:
#       - name: http
#         port: 80
#         targetPort: http
#         protocol: TCP
#   ---
#   apiVersion: v1
#   kind: Service
#   metadata:
#     name: echo-udp
#   spec:
#     type: ClusterIP
#     selector:
#       app: web
#     ports:
#       - name: echo
#         port: 5353
#         targetPort: udp-echo
#         protocol: UDP
#
# Diagnostic ladder to memorise for the exam:
#   1. kubectl get svc          -> type, ClusterIP, port/PROTOCOL
#   2. kubectl get endpointslices -l kubernetes.io/service-name=<svc>
#                               -> empty? selector or readiness problem
#   3. curl/nc the Pod IP:targetPort directly
#                               -> fails? targetPort or protocol problem
#   4. Only then suspect kube-proxy / CNI (iptables-save | grep <svc>,
#      nft list ruleset, cilium service list, etc.)
#
# Cleanup:
#   ./break-fix-l4-services.sh cleanup
# =============================================================================