#!/usr/bin/env bash
# =============================================================================
# CKNE 2.4 - Troubleshooting Service Network Traffic
# BREAK & FIX LAB
#
# What this lab does:
#   Deploys a small web app behind a ClusterIP Service in a dedicated namespace,
#   then breaks the path between the client and the backends in several
#   independent, layered ways. Fixing one fault only reveals the next one, the
#   way real incidents usually go: the first symptom you see is rarely the
#   only cause.
#
# Scope and safety:
#   - Everything is created inside ONE namespace: ckne-lab-2-4.
#   - Nothing cluster-wide is modified: kube-proxy, CoreDNS, the CNI and
#     node iptables/nftables are untouched. You only READ them to diagnose.
#   - `reset` deletes the namespace and leaves the cluster as it was.
#   - Run it on a disposable lab cluster (kind, k3s, kubeadm VM, minikube).
#
# Requirements:
#   - kubectl pointing at a lab cluster, with permission to create a namespace
#   - Nodes able to pull nginx:1.27-alpine and busybox:1.36
#   - Optional fault 4 (NetworkPolicy) needs a CNI that ENFORCES NetworkPolicy
#     (Calico, Cilium, Antrea, kindnet >= kind v0.24). With flannel alone the
#     policy is accepted by the API server but silently ignored.
#
# Usage:
#   ./ckne-2.4-break-fix.sh break            # deploy and break (faults 1-3)
#   WITH_NETPOL=1 ./ckne-2.4-break-fix.sh break   # also add fault 4
#   ./ckne-2.4-break-fix.sh check            # grade your fix
#   ./ckne-2.4-break-fix.sh hint             # one nudge per fault, no answers
#   ./ckne-2.4-break-fix.sh reset            # delete everything
#
# References (official):
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/concepts/services-networking/service/
#   https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
#   https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
#   https://kubernetes.io/docs/reference/networking/virtual-ips/
#   https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
#   https://kubernetes.io/docs/concepts/services-networking/network-policies/
# =============================================================================

set -euo pipefail

NS="ckne-lab-2-4"
LAB_LABEL="ckne-lab=2.4"
SVC_FQDN="web.${NS}.svc.cluster.local"
WITH_NETPOL="${WITH_NETPOL:-0}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

info()  { printf '%s[INFO]%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()    { printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"; }
fail()  { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()   { fail "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "Cannot reach the API server. Is your kubeconfig pointing at the lab cluster?"

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  info "Current kubectl context: ${BOLD}${ctx}${RESET}"

  case "$ctx" in
    *prod*|*production*|*prd*)
      die "Context '${ctx}' looks like production. Refusing to run a break & fix lab there." ;;
  esac

  if kubectl get ns "$NS" >/dev/null 2>&1; then
    if ! kubectl get ns "$NS" -l "$LAB_LABEL" -o name 2>/dev/null | grep -q .; then
      die "Namespace ${NS} exists but was not created by this lab. Refusing to touch it."
    fi
  fi
}

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  read -r -p "Deploy the broken lab into namespace '${NS}' on this cluster? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  preflight
  confirm

  info "Creating namespace ${NS}"
  kubectl create namespace "$NS" --dry-run=client -o yaml \
    | kubectl label --local -f - ckne-lab=2.4 -o yaml \
    | kubectl apply -f - >/dev/null

  info "Deploying backend Deployment 'web' (2 replicas of nginx listening on :80)"
  # FAULT 3 (readiness): the probe asks for /ready, which nginx does not serve
  # (404). The pods run, but never become Ready.
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
      tier: front-end
  template:
    metadata:
      labels:
        app: web
        tier: front-end
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
            failureThreshold: 2
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
EOF

  info "Creating Service 'web' (ClusterIP, port 80)"
  # FAULT 1 (selector): 'tier: frontend' vs the pods' 'tier: front-end'.
  #                    The selector matches zero pods -> no EndpointSlice entries.
  # FAULT 2 (targetPort): traffic is sent to 8080, but nginx listens on 80.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: ${NS}
  labels:
    app: web
spec:
  type: ClusterIP
  selector:
    app: web
    tier: frontend
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
EOF

  info "Deploying debug client pod 'client'"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: ${NS}
  labels:
    role: debug
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sleep", "36000"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 50m
          memory: 32Mi
EOF

  if [[ "$WITH_NETPOL" == "1" ]]; then
    info "Adding NetworkPolicy 'web-allow-clients' (fault 4)"
    # FAULT 4 (policy): only pods labelled role=client may reach the backends.
    #                   The debug pod is labelled role=debug.
    kubectl apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-clients
  namespace: ${NS}
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: client
      ports:
        - protocol: TCP
          port: 80
EOF
  fi

  info "Waiting for pods to be Running (they will NOT become Ready - that is part of the lab)"
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running pod -l app=web --timeout=180s >/dev/null \
    || die "Backend pods did not reach Running. Check image pulls: kubectl -n ${NS} describe pod -l app=web"
  kubectl -n "$NS" wait --for=condition=Ready pod/client --timeout=120s >/dev/null \
    || die "Client pod did not become Ready. Check: kubectl -n ${NS} describe pod client"

  cat <<EOF

${BOLD}=====================================================================${RESET}
${BOLD} THE INCIDENT${RESET}
${BOLD}=====================================================================${RESET}
The team shipped a new 'web' service in namespace ${NS}. The pods are
Running, the Service exists, DNS resolves... and every request from inside
the cluster fails.

Reproduce the symptom:

  kubectl -n ${NS} exec client -- wget -qO- -T 3 http://${SVC_FQDN}/

What you will see (iptables/nftables kube-proxy mode):

  wget: can't connect to remote host (10.96.x.y): Connection refused
  command terminated with exit code 1

$( [[ "$WITH_NETPOL" == "1" ]] && echo "Fault 4 is enabled: once the refusals are gone, expect a TIMEOUT instead:

  wget: download timed out
" )
YOUR GOAL
  1. From pod 'client', http://${SVC_FQDN}/ returns the nginx welcome page.
  2. BOTH backend pods are Ready and listed as ready endpoints of Service web.
  3. You fix the root causes. These do NOT count as fixes and the grader
     rejects them:
       - deleting the readinessProbe
       - setting publishNotReadyAddresses: true on the Service
       - replacing the Service with a different name or port
       - deleting the NetworkPolicy (if fault 4 is enabled)
  4. You touch nothing outside namespace ${NS}.

There is more than one fault. Fixing one reveals the next.

  Grade:  $0 check
  Nudge:  $0 hint
  Clean:  $0 reset

Tip: the symptom looks identical for several of the faults. Decide what is
broken from the EndpointSlices and the pod conditions, not from the error.
EOF
}

# -----------------------------------------------------------------------------
# HINT
# -----------------------------------------------------------------------------
do_hint() {
  cat <<EOF
${BOLD}Hints (no answers):${RESET}
  - What does 'kubectl -n ${NS} get endpointslices -l kubernetes.io/service-name=web -o wide'
    show? Empty ENDPOINTS and "not ready" endpoints are two different problems.
  - Compare the Service .spec.selector with the pod labels character by character:
    kubectl -n ${NS} get pods --show-labels
  - A Running pod is not necessarily a Ready pod. Why is READY 0/1?
    Look at the Events in 'kubectl describe'.
  - Endpoints ready, still refused? Check which port the Service forwards to
    versus which port the container actually listens on.
  - Refused vs timed out: kube-proxy actively REJECTs traffic to a Service with no
    ready endpoints; a NetworkPolicy DROPs silently.
EOF
}

# -----------------------------------------------------------------------------
# CHECK
# -----------------------------------------------------------------------------
do_check() {
  kubectl get ns "$NS" >/dev/null 2>&1 || die "Namespace ${NS} not found. Run: $0 break"
  local failures=0

  # 1. Service still exists with the same identity
  local svc_port
  svc_port="$(kubectl -n "$NS" get svc web -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  if [[ "$svc_port" == "80" ]]; then
    ok "Service web exists and still exposes port 80"
  else
    fail "Service web is missing or no longer exposes port 80"; failures=$((failures+1))
  fi

  # 2. No shortcut via publishNotReadyAddresses
  local pnra
  pnra="$(kubectl -n "$NS" get svc web -o jsonpath='{.spec.publishNotReadyAddresses}' 2>/dev/null || true)"
  if [[ "$pnra" == "true" ]]; then
    fail "publishNotReadyAddresses=true hides the readiness problem instead of fixing it"; failures=$((failures+1))
  else
    ok "publishNotReadyAddresses is not used"
  fi

  # 3. The readinessProbe still exists
  local probe_path
  probe_path="$(kubectl -n "$NS" get deploy web \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null || true)"
  if [[ -n "$probe_path" ]]; then
    ok "readinessProbe is still configured (httpGet path: ${probe_path})"
  else
    fail "readinessProbe (httpGet) was removed - fix the probe, don't delete it"; failures=$((failures+1))
  fi

  # 4. Both backends Ready
  local ready_pods
  ready_pods="$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${ready_pods:-0}" -ge 2 ]]; then
    ok "Deployment web has ${ready_pods} Ready replicas"
  else
    fail "Deployment web has ${ready_pods:-0}/2 Ready replicas"; failures=$((failures+1))
  fi

  # 5. EndpointSlices contain 2 ready endpoints
  local ready_eps
  ready_eps="$(kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null \
    | grep -c '^true$' || true)"
  if [[ "${ready_eps:-0}" -ge 2 ]]; then
    ok "EndpointSlices for web list ${ready_eps} ready endpoints"
  else
    fail "EndpointSlices for web list ${ready_eps:-0} ready endpoints (expected 2)"; failures=$((failures+1))
  fi

  # 6. NetworkPolicy still present if fault 4 was enabled
  if kubectl -n "$NS" get networkpolicy web-allow-clients >/dev/null 2>&1; then
    ok "NetworkPolicy web-allow-clients is still in place"
  elif [[ "$WITH_NETPOL" == "1" ]]; then
    fail "NetworkPolicy web-allow-clients was deleted - fix the traffic, keep the policy"; failures=$((failures+1))
  fi

  # 7. End-to-end traffic by DNS name (3 attempts to cover both backends)
  local i body passed=0
  for i in 1 2 3; do
    body="$(kubectl -n "$NS" exec client -- wget -qO- -T 3 "http://${SVC_FQDN}/" 2>&1 || true)"
    if grep -q 'Welcome to nginx' <<<"$body"; then
      passed=$((passed+1))
    fi
  done
  if [[ "$passed" -eq 3 ]]; then
    ok "client -> http://${SVC_FQDN}/ returned the nginx page (3/3)"
  else
    fail "client -> http://${SVC_FQDN}/ succeeded ${passed}/3 times. Last output:"
    printf '       %s\n' "${body:-<empty>}"
    failures=$((failures+1))
  fi

  echo
  if [[ "$failures" -eq 0 ]]; then
    printf '%s%sLAB COMPLETE%s - Service traffic restored at the root cause.\n' "$GREEN" "$BOLD" "$RESET"
  else
    printf '%s%s%d check(s) failing.%s Keep going, or run: %s hint\n' "$RED" "$BOLD" "$failures" "$RESET" "$0"
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# RESET
# -----------------------------------------------------------------------------
do_reset() {
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    info "Namespace ${NS} does not exist. Nothing to clean."
    return 0
  fi
  kubectl get ns "$NS" -l "$LAB_LABEL" -o name | grep -q . \
    || die "Namespace ${NS} was not created by this lab. Not deleting it."
  info "Deleting namespace ${NS}"
  kubectl delete namespace "$NS" --wait=true --timeout=120s
  ok "Lab removed"
}

case "${1:-}" in
  break) do_break ;;
  check) do_check ;;
  hint)  do_hint ;;
  reset) do_reset ;;
  *)
    echo "Usage: $0 {break|check|hint|reset}"
    echo "       WITH_NETPOL=1 $0 break    # adds the NetworkPolicy fault"
    echo "       ASSUME_YES=1 $0 break     # skip the confirmation prompt"
    exit 2 ;;
esac

exit 0

# =============================================================================
# SOLUTION - STEP BY STEP (read only after you have tried)
# =============================================================================
#
# The method: follow the packet, layer by layer.
#   client -> DNS -> ClusterIP (kube-proxy rules) -> EndpointSlice -> Pod IP:targetPort
#                                                         ^
#                     most Service failures are decided here
#
# -----------------------------------------------------------------------------
# STEP 0 - Reproduce, and rule out DNS
# -----------------------------------------------------------------------------
#   kubectl -n ckne-lab-2-4 exec client -- nslookup web.ckne-lab-2-4.svc.cluster.local
#
#   Server:    10.96.0.10
#   Address:   10.96.0.10:53
#   Name:      web.ckne-lab-2-4.svc.cluster.local
#   Address:   10.96.143.27
#
#   DNS works: the name resolves to the ClusterIP. "Connection refused" is NOT
#   a DNS problem (that would be "bad address"). Move down one layer.
#
#   Why is it "refused" and not a timeout? When a Service has no READY
#   endpoints, kube-proxy (iptables mode) installs a REJECT rule for the
#   ClusterIP in the filter table, so the client fails fast. You can see it on
#   a node (read only):
#
#   sudo iptables -t filter -S KUBE-SERVICES | grep ckne-lab-2-4
#   -A KUBE-SERVICES -d 10.96.143.27/32 -p tcp -m comment \
#     --comment "ckne-lab-2-4/web:http has no endpoints" -m tcp --dport 80 \
#     -j REJECT --reject-with icmp-port-unreachable
#
#   In nftables mode:  sudo nft list chain ip kube-proxy service-ips   (+ 'no-endpoint-services')
#   In IPVS mode:      sudo ipvsadm -Ln -t 10.96.143.27:80   (virtual server with no real servers)
#
# -----------------------------------------------------------------------------
# STEP 1 - FAULT 1: selector matches no pods
# -----------------------------------------------------------------------------
#   kubectl -n ckne-lab-2-4 get endpointslices -l kubernetes.io/service-name=web
#
#   NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
#   web-7xk2p   IPv4          <unset>   <unset>     3m
#
#   Zero endpoints: the selector matches nothing. Compare:
#
#   kubectl -n ckne-lab-2-4 get svc web -o jsonpath='{.spec.selector}{"\n"}'
#   {"app":"web","tier":"frontend"}
#
#   kubectl -n ckne-lab-2-4 get pods -l app=web --show-labels
#   NAME                   READY   STATUS    ...   LABELS
#   web-6d9c8b7f5-4rj2m    0/1     Running   ...   app=web,pod-template-hash=...,tier=front-end
#
#   'frontend' != 'front-end'. Selectors are an exact AND of every key/value.
#   Quick proof: kubectl -n ckne-lab-2-4 get pods -l app=web,tier=frontend  -> No resources found
#
#   Fix the Service (the Deployment is the source of truth for pod labels):
#
#   kubectl -n ckne-lab-2-4 patch svc web --type merge \
#     -p '{"spec":{"selector":{"app":"web","tier":"front-end"}}}'
#
# -----------------------------------------------------------------------------
# STEP 2 - FAULT 3: endpoints exist but are NOT ready
# -----------------------------------------------------------------------------
#   kubectl -n ckne-lab-2-4 get endpointslices -l kubernetes.io/service-name=web -o wide
#   NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
#   web-7xk2p   IPv4          8080    10.244.1.5,10.244.2.7   4m
#
#   The addresses are there now, but look at their conditions:
#
#   kubectl -n ckne-lab-2-4 get endpointslices -l kubernetes.io/service-name=web \
#     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"  ready="}{.conditions.ready}{"\n"}{end}'
#   10.244.1.5  ready=false
#   10.244.2.7  ready=false
#
#   kube-proxy only programs READY endpoints, so the REJECT rule is still
#   there and the client still sees "Connection refused". Same symptom,
#   different cause - this is why you read EndpointSlices, not the error.
#
#   kubectl -n ckne-lab-2-4 describe pod -l app=web | grep -A2 -i 'readiness'
#     Readiness:  http-get http://:http/ready delay=2s timeout=1s period=5s #success=1 #failure=2
#     Warning  Unhealthy  ...  Readiness probe failed: HTTP probe failed with statuscode: 404
#
#   nginx has no /ready. Point the probe at a path that exists (do NOT delete
#   the probe, and do NOT set publishNotReadyAddresses - both would send
#   traffic to pods that have not proven they can serve it):
#
#   kubectl -n ckne-lab-2-4 patch deploy web --type json -p \
#     '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
#
#   kubectl -n ckne-lab-2-4 rollout status deploy/web
#   deployment "web" successfully rolled out
#
# -----------------------------------------------------------------------------
# STEP 3 - FAULT 2: endpoints ready, but targetPort is wrong
# -----------------------------------------------------------------------------
#   kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://web.ckne-lab-2-4.svc.cluster.local/
#   wget: can't connect to remote host (10.96.143.27): Connection refused
#
#   Still refused - but now it comes from the POD, not from kube-proxy. The
#   REJECT rule is gone; the DNAT rule sends the packet to PodIP:8080 and
#   nothing listens there, so the pod's kernel answers with a TCP RST.
#
#   Isolate the layer by skipping the Service and hitting the pod directly:
#
#   POD_IP=$(kubectl -n ckne-lab-2-4 get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
#   kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://$POD_IP:8080/  -> Connection refused
#   kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://$POD_IP:80/    -> Welcome to nginx!
#
#   The pod works on 80; the Service forwards to 8080:
#
#   kubectl -n ckne-lab-2-4 get svc web -o jsonpath='{.spec.ports[0].targetPort}{"\n"}'
#   8080
#
#   On a node, the DNAT target confirms it (read only):
#   sudo iptables -t nat -S | grep -A1 'ckne-lab-2-4/web:http' | grep DNAT
#   ... -j DNAT --to-destination 10.244.1.5:8080
#
#   Fix it with the NAMED port, so a future containerPort change in the pod
#   spec cannot silently break the Service again:
#
#   kubectl -n ckne-lab-2-4 patch svc web --type json -p \
#     '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
#
#   kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://web.ckne-lab-2-4.svc.cluster.local/ | head -4
#   <!DOCTYPE html>
#   <html>
#   <head>
#   <title>Welcome to nginx!</title>
#
# -----------------------------------------------------------------------------
# STEP 4 - FAULT 4 (only with WITH_NETPOL=1): the policy drops the client
# -----------------------------------------------------------------------------
#   kubectl -n ckne-lab-2-4 exec client -- wget -qO- -T 3 http://web.ckne-lab-2-4.svc.cluster.local/
#   wget: download timed out
#
#   Refused -> timed out is the signature change: something now DROPS packets
#   silently. Endpoints are ready and the pod answers on :80 locally
#   (kubectl -n ckne-lab-2-4 exec deploy/web -- wget -qO- -T 2 http://127.0.0.1/ works),
#   so look for policy:
#
#   kubectl -n ckne-lab-2-4 get networkpolicy
#   NAME                POD-SELECTOR   AGE
#   web-allow-clients   app=web        9m
#
#   kubectl -n ckne-lab-2-4 describe networkpolicy web-allow-clients
#     Allowing ingress traffic:
#       To Port: 80/TCP
#       From:
#         PodSelector: role=client
#
#   kubectl -n ckne-lab-2-4 get pod client --show-labels
#   client   1/1   Running   ...   role=debug
#
#   Note the policy is evaluated on the BACKEND pod after kube-proxy's DNAT,
#   so the port it must allow is the targetPort (80), not the Service port.
#   The intended design is "only clients may call web", so label the client
#   rather than widening the policy:
#
#   kubectl -n ckne-lab-2-4 label pod client role=client --overwrite
#
#   (With Cilium you can confirm the drop live: 'cilium monitor --type drop'
#    or 'hubble observe -n ckne-lab-2-4 --verdict DROPPED'. With Calico,
#    policy drops appear as iptables/nft counters in the cali-* chains.)
#
# -----------------------------------------------------------------------------
# STEP 5 - Verify
# -----------------------------------------------------------------------------
#   ./ckne-2.4-break-fix.sh check
#   [PASS] Service web exists and still exposes port 80
#   [PASS] publishNotReadyAddresses is not used
#   [PASS] readinessProbe is still configured (httpGet path: /)
#   [PASS] Deployment web has 2 Ready replicas
#   [PASS] EndpointSlices for web list 2 ready endpoints
#   [PASS] client -> http://web.ckne-lab-2-4.svc.cluster.local/ returned the nginx page (3/3)
#   LAB COMPLETE - Service traffic restored at the root cause.
#
#   ./ckne-2.4-break-fix.sh reset
#
# -----------------------------------------------------------------------------
# TAKEAWAYS
# -----------------------------------------------------------------------------
#   Symptom                         | Where to look            | Likely cause
#   --------------------------------|--------------------------|--------------------------------------
#   "bad address" / NXDOMAIN        | nslookup, CoreDNS        | wrong name/namespace, DNS down
#   refused, EndpointSlice empty    | svc selector vs labels   | selector mismatch
#   refused, endpoints ready=false  | pod conditions, probes   | failing readinessProbe
#   refused, endpoints ready        | direct PodIP:port test   | wrong targetPort / app not listening
#   timeout, endpoints ready        | NetworkPolicy, CNI       | policy drop, broken pod network/routes
#   works from node, not from pod   | NetworkPolicy, CNI       | policy / CNI routing
#
#   Always read EndpointSlices before touching anything: they are the single
#   object that tells you whether kube-proxy has anywhere to send the packet.
# =============================================================================