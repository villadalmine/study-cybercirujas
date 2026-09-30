#!/usr/bin/env bash
# =============================================================================
# CKNE 3.3 - Configuring Egress Gateways for Cluster Exit Traffic
# BREAK & FIX LAB: "The egress gateway that nobody goes through"
# =============================================================================
#
# SCENARIO
#   The security team requires all HTTP traffic from namespace `egress-lab` to
#   the external API `httpbin.org` to leave the mesh through the dedicated
#   Istio egress gateway (istio-system/istio-egressgateway). Routing all exit
#   traffic through one proxy gives you one place to audit, apply policy and
#   (with node pinning plus SNAT) keep a stable source IP for external
#   firewalls.
#
#   A colleague "refactored" the egress manifests on Friday. Since then every
#   call from the application to the external API returns HTTP 503.
#
# WHAT THIS SCRIPT DOES (break mode)
#   1. Deploys a client (curl plus an Istio sidecar) in namespace `egress-lab`.
#   2. Registers httpbin.org in the mesh with a ServiceEntry, then checks that
#      the lab really has internet access. The lab only makes sense if it does.
#   3. Applies the egress Gateway, DestinationRule and VirtualService with TWO
#      deliberate, independent faults injected. Fixing one of them is not
#      enough.
#
# SAFETY
#   - Touches ONLY namespace `egress-lab`. It never modifies istio-system,
#     the MeshConfig, or any cluster-scoped object.
#   - Refuses to run against a kube context whose name contains "prod".
#   - `./breakfix-3.3-egress-gateway.sh cleanup` deletes the namespace and
#     leaves the cluster as it was.
#
# REQUIREMENTS (disposable lab VM)
#   - kubectl pointed at a lab cluster (kind, k3s, minikube...).
#   - Istio >= 1.22 (networking.istio.io/v1) installed WITH the egress
#     gateway. The `demo` profile includes it:
#         istioctl install --set profile=demo -y
#   - Outbound internet access from the cluster nodes (to httpbin.org:80).
#   - istioctl is recommended for diagnosis; the solution uses it.
#
# USAGE
#   ./breakfix-3.3-egress-gateway.sh break     # set up the broken scenario (default)
#   ./breakfix-3.3-egress-gateway.sh check     # grade your fix
#   ./breakfix-3.3-egress-gateway.sh cleanup   # remove everything
#   YES=1 ./breakfix-3.3-egress-gateway.sh ... # skip the confirmation prompt
#
# REFERENCES
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
#   https://istio.io/latest/docs/reference/config/networking/gateway/
#   https://istio.io/latest/docs/reference/config/networking/destination-rule/
#   https://istio.io/latest/docs/reference/config/analysis/ist0101/
#   https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
# =============================================================================

set -euo pipefail

NS="egress-lab"
EXT_HOST="${EXT_HOST:-httpbin.org}"
EGW_NS="istio-system"
EGW_SVC="istio-egressgateway"
EGW_FQDN="${EGW_SVC}.${EGW_NS}.svc.cluster.local"
MODE="${1:-break}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "No current kube context. Point kubectl at your lab cluster."
  if [[ "$ctx" == *prod* ]]; then
    die "Context '$ctx' looks like production. This lab only runs on disposable clusters."
  fi

  bold "Kube context: $ctx"
  if [[ "${YES:-0}" != "1" ]]; then
    read -r -p "This will create/modify namespace '$NS' in this cluster. Continue? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || die "Aborted by user."
  fi

  kubectl get crd gateways.networking.istio.io >/dev/null 2>&1 \
    || die "Istio CRDs not found. Install Istio first: istioctl install --set profile=demo -y"

  kubectl api-resources --api-group=networking.istio.io -o wide 2>/dev/null | grep -q 'v1[^a-z]' \
    || kubectl get --raw /apis/networking.istio.io/v1 >/dev/null 2>&1 \
    || die "networking.istio.io/v1 is not served. This lab needs Istio >= 1.22."

  kubectl -n "$EGW_NS" get deploy "$EGW_SVC" >/dev/null 2>&1 \
    || die "Deployment $EGW_NS/$EGW_SVC not found. Install with the demo profile or enable egressGateways in your IstioOperator."

  kubectl -n "$EGW_NS" get pods -l istio=egressgateway --no-headers 2>/dev/null | grep -q Running \
    || die "No Running pod with label istio=egressgateway in $EGW_NS."

  command -v istioctl >/dev/null 2>&1 \
    || yellow "WARNING: istioctl not found. You can still solve the lab, but diagnosis will be harder."
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Reads the egress gateway's Envoy counter for the external cluster.
# The cluster name follows the pattern outbound|<port>|<subset>|<host>.
egw_counter() {
  local v
  v="$(kubectl -n "$EGW_NS" exec deploy/"$EGW_SVC" -c istio-proxy -- \
        pilot-agent request GET stats 2>/dev/null \
      | grep -F "cluster.outbound|80||${EXT_HOST}.upstream_rq_total:" \
      | awk '{print $2}' | head -n1 || true)"
  echo "${v:-0}"
}

client_curl() {
  # Prints "<http_code>" and nothing else; 000 means the connection failed.
  kubectl -n "$NS" exec deploy/client -c curl -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${EXT_HOST}/anything/$1" 2>/dev/null \
    || echo "000"
}

# -----------------------------------------------------------------------------
# Base: namespace, client, ServiceEntry (these are all correct)
# -----------------------------------------------------------------------------
deploy_base() {
  bold ">> Creating namespace $NS with sidecar injection"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

  bold ">> Deploying client"
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: ${NS}
  labels:
    app: client
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
      terminationGracePeriodSeconds: 0
      containers:
      - name: curl
        image: curlimages/curl:8.10.1
        command: ["sleep", "infinity"]
EOF
  kubectl -n "$NS" rollout status deploy/client --timeout=180s

  local containers
  containers="$(kubectl -n "$NS" get pod -l app=client -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')"
  [[ "$containers" == *istio-proxy* ]] \
    || die "The client pod has no istio-proxy sidecar. Is injection enabled for this revision? (istio.io/rev label?)"

  bold ">> Registering ${EXT_HOST} with a ServiceEntry"
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: ext-httpbin
  namespace: ${NS}
spec:
  hosts:
  - ${EXT_HOST}
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  resolution: DNS
EOF
  sleep 5

  bold ">> Checking that the lab has internet access (direct path, no egress gateway yet)"
  local code
  code="$(client_curl preflight)"
  if [[ "$code" != "200" ]]; then
    die "Direct request to http://${EXT_HOST} returned '$code'. The lab needs outbound internet. Fix the VM network, or set EXT_HOST to a reachable HTTP host, then run: $0 cleanup && $0 break"
  fi
  green "   Direct path OK (HTTP 200). The environment is healthy; any failure from now on is the lab."
}

# -----------------------------------------------------------------------------
# Broken egress configuration (TWO injected faults)
# -----------------------------------------------------------------------------
apply_broken() {
  bold ">> Applying egress gateway configuration"
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
  namespace: ${NS}
spec:
  selector:
    istio: egress-gateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - ${EXT_HOST}
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-httpbin
  namespace: ${NS}
spec:
  host: ${EGW_FQDN}
  subsets:
  - name: httpbin-egress
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-httpbin-through-egress-gateway
  namespace: ${NS}
spec:
  hosts:
  - ${EXT_HOST}
  gateways:
  - istio-egressgateway
  - mesh
  http:
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: ${EGW_FQDN}
        subset: httpbin
        port:
          number: 80
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: ${EXT_HOST}
        port:
          number: 80
      weight: 100
EOF
  sleep 5
}

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------
do_break() {
  preflight
  deploy_base
  apply_broken

  local code
  code="$(client_curl symptom)"
  echo
  bold "=================================================================="
  bold " LAB READY - the scenario is broken"
  bold "=================================================================="
  cat <<EOF

SYMPTOM
  From the application pod:

    kubectl -n ${NS} exec deploy/client -c curl -- \\
      curl -sv http://${EXT_HOST}/headers

  returns HTTP ${code} (expected: 503). The request never reaches ${EXT_HOST}.
  The client sidecar's access log is revealing, especially the RESPONSE FLAG
  (NC, UF, URX, NR...):

    kubectl -n ${NS} logs deploy/client -c istio-proxy --tail=20

GOAL
  1. HTTP requests from deploy/client to http://${EXT_HOST} must return 200.
  2. They MUST go through ${EGW_NS}/${EGW_SVC}. Deleting the VirtualService
     so traffic leaves directly from the sidecar "works", but it fails the
     check: the grader reads the egress gateway's Envoy counters.
  3. Do not modify anything in ${EGW_NS}. Both faults are in the manifests
     in namespace ${NS}.

HINTS (only if you are stuck)
  - There are TWO independent faults. Once you fix the first, the symptom
    CHANGES: the response flag becomes different.
  - The static analyzer knows more than you think: istioctl analyze -n ${NS}
  - Which labels does the egress gateway pod actually have?
  - Which Envoy clusters does the client sidecar know about for the gateway?
      istioctl proxy-config clusters deploy/client -n ${NS} | grep egressgateway
  - Which listeners does the egress gateway have?
      istioctl proxy-config listeners deploy/${EGW_SVC} -n ${EGW_NS}

GRADE YOUR FIX
  $0 check

CLEANUP
  $0 cleanup
EOF
}

do_check() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || die "Namespace $NS does not exist. Run: $0 break"
  local pass=1 token before after code

  bold ">> [1/3] Objects that route through the egress gateway still exist"
  if kubectl -n "$NS" get virtualservice.networking.istio.io direct-httpbin-through-egress-gateway >/dev/null 2>&1 \
     && kubectl -n "$NS" get gateway.networking.istio.io istio-egressgateway >/dev/null 2>&1; then
    green "   OK: Gateway and VirtualService are present"
  else
    red "   FAIL: the Gateway or VirtualService was deleted. Bypassing the egress gateway is not a fix."
    pass=0
  fi

  bold ">> [2/3] End-to-end request from the client"
  token="check-$RANDOM$RANDOM"
  before="$(egw_counter)"
  code="$(client_curl "$token")"
  sleep 2
  after="$(egw_counter)"
  if [[ "$code" == "200" ]]; then
    green "   OK: HTTP 200"
  else
    red "   FAIL: HTTP $code (expected 200)"
    pass=0
  fi

  bold ">> [3/3] The request actually crossed the egress gateway"
  echo "   Counter cluster.outbound|80||${EXT_HOST}.upstream_rq_total on the gateway: before=$before after=$after"
  if (( after > before )); then
    green "   OK: the egress gateway forwarded the request to ${EXT_HOST}"
  else
    red "   FAIL: the egress gateway did NOT forward any request to ${EXT_HOST}"
    pass=0
  fi

  echo
  if (( pass )); then
    green "=============================================="
    green " LAB PASSED: exit traffic goes through the egress gateway"
    green "=============================================="
  else
    red "Not solved yet. Keep going."
    exit 1
  fi
}

do_cleanup() {
  bold ">> Deleting namespace $NS (removes every object in this lab)"
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  green "Cleanup complete. Nothing in ${EGW_NS} was modified."
}

case "$MODE" in
  break)   do_break ;;
  check)   do_check ;;
  cleanup) do_cleanup ;;
  *)       die "Unknown mode '$MODE'. Use: break | check | cleanup" ;;
esac

exit 0

# =============================================================================
# SOLUTION (do not read until you have tried)
# =============================================================================
#
# --- How the path is supposed to work --------------------------------------
#
#   client app --> client sidecar --(VS rule 'mesh')--> istio-egressgateway:80
#     (Envoy cluster outbound|80|httpbin|istio-egressgateway.istio-system.svc.cluster.local)
#   istio-egressgateway (listener 0.0.0.0_8080, built from the Gateway)
#     --(VS rule 'istio-egressgateway')--> outbound|80||httpbin.org --> internet
#
#   Four objects have to agree with each other:
#     - ServiceEntry     : httpbin.org exists in the mesh registry (HTTP/80).
#     - Gateway          : its `selector` must match the LABELS of the gateway
#                          pod. That is what makes istiod program a listener
#                          on that pod.
#     - DestinationRule  : defines subset `httpbin` for the gateway service, so
#                          the sidecar gets a cluster with that subset.
#     - VirtualService   : rule for `mesh` (sidecars) -> gateway, and rule for
#                          the Gateway -> external host.
#
# --- Step 1: static analysis ------------------------------------------------
#
#   istioctl analyze -n egress-lab
#
#   Expected output, similar to:
#     Error [IST0101] (Gateway egress-lab/istio-egressgateway) Referenced
#       selector not found: "istio=egress-gateway"
#     Error [IST0101] (VirtualService egress-lab/direct-httpbin-through-egress-gateway)
#       Referenced host+subset in destinationrule not found:
#       "istio-egressgateway.istio-system.svc.cluster.local+httpbin"
#
#   IST0101 = ReferencedResourceNotFound. In an exam, run this first.
#
# --- Step 2: first fault, the missing subset (symptom 503 / NC) ------------
#
#   The client sidecar tries to use a cluster that does not exist:
#
#     kubectl -n egress-lab logs deploy/client -c istio-proxy --tail=5
#       ... "GET /anything/... HTTP/1.1" 503 NC cluster_not_found ...
#
#   NC = "No Cluster": the VS points at subset `httpbin`, but the DR only
#   defines `httpbin-egress`. Confirm it:
#
#     istioctl proxy-config clusters deploy/client -n egress-lab | grep egressgateway
#       istio-egressgateway.istio-system.svc.cluster.local  80  httpbin-egress  outbound  EDS  ...
#     (there is no line with subset `httpbin`)
#
#   Fix: make the names match. The DR is the one that disagrees with the rest:
#
#     kubectl -n egress-lab patch destinationrule.networking.istio.io \
#       egressgateway-for-httpbin --type=merge \
#       -p '{"spec":{"subsets":[{"name":"httpbin"}]}}'
#
#   (Renaming the subset in the VS to `httpbin-egress` also works.)
#
# --- Step 3: second fault, the gateway without a listener (503 / UF, URX) ----
#
#   The request now reaches the egress gateway pod, but nothing is listening:
#
#     kubectl -n egress-lab exec deploy/client -c curl -- curl -s http://httpbin.org/headers
#       upstream connect error or disconnect/reset before headers.
#       reset reason: remote connection failure, transport failure reason:
#       delayed connect error: 111
#
#   111 = ECONNREFUSED: the Service istio-egressgateway:80 -> targetPort 8080
#   exists, but Envoy has no listener on 8080 because no Gateway selects it:
#
#     istioctl proxy-config listeners deploy/istio-egressgateway -n istio-system
#       (no listener on 0.0.0.0 port 8080)
#
#     kubectl -n istio-system get pods -l app=istio-egressgateway --show-labels
#       ... app=istio-egressgateway,istio=egressgateway,...
#
#     kubectl -n egress-lab get gateway.networking.istio.io istio-egressgateway \
#       -o jsonpath='{.spec.selector}{"\n"}'
#       {"istio":"egress-gateway"}      <-- does not match istio=egressgateway
#
#   Fix:
#
#     kubectl -n egress-lab patch gateway.networking.istio.io istio-egressgateway \
#       --type=merge -p '{"spec":{"selector":{"istio":"egressgateway"}}}'
#
#   Confirm the listener appears:
#
#     istioctl proxy-config listeners deploy/istio-egressgateway -n istio-system
#       ADDRESSES  PORT  MATCH  DESTINATION
#       0.0.0.0    8080  ALL    Route: http.8080
#
#     istioctl proxy-config routes deploy/istio-egressgateway -n istio-system
#       http.8080  httpbin.org  /*  direct-httpbin-through-egress-gateway.egress-lab
#
# --- Step 4: end-to-end verification ------------------------------------------
#
#   kubectl -n egress-lab exec deploy/client -c curl -- \
#     curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.org/headers
#   200
#
#   Proof that the request went THROUGH the gateway, not around it:
#
#     kubectl -n istio-system logs deploy/istio-egressgateway --tail=3
#       [...] "GET /headers HTTP/1.1" 200 - via_upstream ... "httpbin.org"
#       outbound|80||httpbin.org ...
#     (requires access logging, which is on in the demo profile)
#
#   Or, independently of access logs, the Envoy counters used by the grader:
#
#     kubectl -n istio-system exec deploy/istio-egressgateway -c istio-proxy -- \
#       pilot-agent request GET stats | grep 'outbound|80||httpbin.org.upstream_rq_total'
#
#   Then:  ./breakfix-3.3-egress-gateway.sh check
#
# --- Production lessons ------------------------------------------------------
#
#   1. An egress gateway is a ROUTING convention, not a security control.
#      Nothing here stops a pod without a sidecar, or one that skips the
#      sidecar, from going straight to the internet. For real enforcement,
#      combine it with:
#        - outboundTrafficPolicy.mode: REGISTRY_ONLY in the MeshConfig, and
#        - a Kubernetes NetworkPolicy (or CiliumNetworkPolicy) that only lets
#          the egress gateway pods reach 0.0.0.0/0, and application
#          namespaces reach only kube-dns and istio-system.
#      That is why the grader checks the counters instead of trusting a 200.
#   2. A wrong Gateway selector fails SILENTLY at apply time: the API server
#      accepts it, and the error only shows up as ECONNREFUSED on the data
#      path. Put `istioctl analyze` in CI (it exits non-zero on errors).
#   3. The Envoy response flag tells you which hop failed: NC/NR point at the
#      client sidecar configuration (clusters/routes); UF/URX with
#      "connect error 111" point at the next hop (the gateway has no
#      listener).
#   4. At L3 (Cilium), the equivalent pattern is CiliumEgressGatewayPolicy:
#      it SNATs traffic selected by podSelector + destinationCIDRs to a
#      fixed egress IP on designated nodes. It requires the egressGateway
#      feature, bpf masquerade and kube-proxy replacement. Diagnose it with
#      `cilium-dbg bpf egress list` on the agent.
#      https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
# =============================================================================