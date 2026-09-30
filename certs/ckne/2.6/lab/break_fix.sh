#!/usr/bin/env bash
# =============================================================================
# CKNE - Topic 2.6: Managing Traffic with the Gateway API (Gateway, HTTPRoutes)
# BREAK & FIX LAB: "The route that never attached"
# =============================================================================
#
# WHAT THIS LAB DOES
#   Builds a small multi-namespace Gateway API topology on a DISPOSABLE lab
#   cluster, then injects two controlled faults that are common in production:
#   the route is correct in isolation, but the Gateway rejects it.
#
#     infra-gw      -> Gateway "shared-gw"   (owned by the platform team)
#     team-a        -> HTTPRoute "storefront" (owned by the app team)
#     shop-backend  -> Deployment + Service "catalog" (owned by the backend team)
#
#   Traffic path that SHOULD work:
#     client --Host: shop.lab.example--> shared-gw:80 --> HTTPRoute storefront
#            --> Service shop-backend/catalog:8080 --> agnhost pods
#
# REQUIREMENTS
#   - A throwaway cluster (kind, k3d, minikube, kubeadm VM) that you can destroy.
#   - Gateway API CRDs (standard channel, v1.0+) installed: Gateway, HTTPRoute,
#     ReferenceGrant.
#   - A Gateway API implementation (Envoy Gateway, Istio, Cilium, NGINX Gateway
#     Fabric, Contour, Traefik...) with at least one GatewayClass that is Accepted.
#
# USAGE
#   ./break-fix-2.6.sh break      # build topology + inject faults
#   ./break-fix-2.6.sh verify     # check whether you fixed it
#   ./break-fix-2.6.sh cleanup    # delete everything this lab created
#
#   Environment overrides:
#     GATEWAY_CLASS=<name>   GatewayClass to use (default: first Accepted one)
#     LAB_CONFIRM=yes        skip the interactive "is this a lab cluster?" check
#
# SAFETY
#   - Only creates/deletes the three namespaces listed above (all labelled
#     lab=ckne-2-6). It never touches GatewayClasses, CRDs, or the controller.
#   - Refuses to run unless the kube context looks like a lab cluster or you
#     confirm explicitly.
#
# References (official):
#   https://gateway-api.sigs.k8s.io/reference/api-types/gateway/
#   https://gateway-api.sigs.k8s.io/reference/api-types/httproute/
#   https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/
#   https://gateway-api.sigs.k8s.io/guides/multiple-ns/
#   https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/
#   https://kubernetes.io/docs/concepts/services-networking/gateway/
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
# =============================================================================

set -euo pipefail

LAB_LABEL="lab=ckne-2-6"
NS_GW="infra-gw"
NS_ROUTE="team-a"
NS_BACKEND="shop-backend"
GW_NAME="shared-gw"
ROUTE_NAME="storefront"
SVC_NAME="catalog"
HOSTNAME_FQDN="shop.lab.example"
AGNHOST_IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.39"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
info()  { printf '%s[INFO]%s %s\n'  "$BLU" "$RST" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$GRN" "$RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$YLW" "$RST" "$*"; }
fail()  { printf '%s[FAIL]%s %s\n'  "$RED" "$RST" "$*"; }
die()   { fail "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "Cannot reach the API server. Check your kubeconfig."

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  if [[ "${LAB_CONFIRM:-}" != "yes" ]] && \
     ! [[ "$ctx" =~ (kind|k3d|minikube|lab|sandbox|test|dev|kubernetes-admin) ]]; then
    warn "Current context is '$ctx', which does not look like a lab cluster."
    read -r -p "Type 'yes' to continue on this cluster: " answer
    [[ "$answer" == "yes" ]] || die "Aborted by user."
  fi
  info "Using kube context: $ctx"

  for crd in gateways.gateway.networking.k8s.io \
             httproutes.gateway.networking.k8s.io \
             referencegrants.gateway.networking.k8s.io \
             gatewayclasses.gateway.networking.k8s.io; do
    kubectl get crd "$crd" >/dev/null 2>&1 \
      || die "CRD $crd missing. Install Gateway API standard channel first:
       kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
  done
  ok "Gateway API CRDs present."

  if [[ -z "${GATEWAY_CLASS:-}" ]]; then
    GATEWAY_CLASS="$(kubectl get gatewayclass \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Accepted")]}{.status}{end}{"\n"}{end}' \
      | awk '$2=="True"{print $1; exit}')"
  fi
  [[ -n "${GATEWAY_CLASS:-}" ]] \
    || die "No Accepted GatewayClass found. Install a Gateway API implementation (e.g. Envoy Gateway) or set GATEWAY_CLASS=<name>."
  kubectl get gatewayclass "$GATEWAY_CLASS" >/dev/null 2>&1 \
    || die "GatewayClass '$GATEWAY_CLASS' does not exist."
  ok "Using GatewayClass: $GATEWAY_CLASS"
}

# -----------------------------------------------------------------------------
# Build + break
# -----------------------------------------------------------------------------
do_break() {
  preflight

  info "Creating lab namespaces..."
  for ns in "$NS_GW" "$NS_ROUTE" "$NS_BACKEND"; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl label namespace "$ns" lab=ckne-2-6 --overwrite >/dev/null
  done

  info "Deploying backend '$SVC_NAME' in namespace $NS_BACKEND..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SVC_NAME}
  namespace: ${NS_BACKEND}
  labels:
    app: ${SVC_NAME}
    lab: ckne-2-6
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${SVC_NAME}
  template:
    metadata:
      labels:
        app: ${SVC_NAME}
    spec:
      containers:
        - name: agnhost
          image: ${AGNHOST_IMAGE}
          args:
            - netexec
            - --http-port=8080
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /hostname
              port: 8080
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${NS_BACKEND}
  labels:
    lab: ckne-2-6
spec:
  selector:
    app: ${SVC_NAME}
  ports:
    - name: http
      port: 8080
      targetPort: http
EOF

  # FAULT #1: the listener only accepts routes from its OWN namespace
  #           (allowedRoutes.namespaces.from: Same), but the route lives in team-a.
  info "Creating Gateway '$GW_NAME' in namespace $NS_GW..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${NS_GW}
  labels:
    lab: ckne-2-6
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.lab.example"
      allowedRoutes:
        kinds:
          - kind: HTTPRoute
        namespaces:
          from: Same
EOF

  # FAULT #2: the route references a Service in ANOTHER namespace and no
  #           ReferenceGrant exists in shop-backend to permit it.
  info "Creating HTTPRoute '$ROUTE_NAME' in namespace $NS_ROUTE..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${ROUTE_NAME}
  namespace: ${NS_ROUTE}
  labels:
    lab: ckne-2-6
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GW_NAME}
      namespace: ${NS_GW}
      sectionName: http
  hostnames:
    - ${HOSTNAME_FQDN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: ${SVC_NAME}
          namespace: ${NS_BACKEND}
          port: 8080
          weight: 1
EOF

  info "Waiting for backend pods to become Ready..."
  kubectl -n "$NS_BACKEND" rollout status deployment/"$SVC_NAME" --timeout=120s >/dev/null \
    || warn "Backend not Ready yet (image pull?). The lab still works; check it later."

  sleep 5
  cat <<EOF

${RED}=============================================================================
 INCIDENT TICKET #2604 - "shop.lab.example returns 404 through the shared gateway"
=============================================================================${RST}

 The platform team runs a shared Gateway ('${NS_GW}/${GW_NAME}').
 The app team deployed HTTPRoute '${NS_ROUTE}/${ROUTE_NAME}' for host
 '${HOSTNAME_FQDN}', pointing at Service '${NS_BACKEND}/${SVC_NAME}:8080'.
 Pods are Running and Ready. "kubectl apply" succeeded without errors.
 Yet every request through the gateway gets 404 (or connection reset,
 depending on the implementation), and no request ever reaches the pods.

 SYMPTOMS YOU WILL SEE
   - kubectl get httproute -n ${NS_ROUTE}  -> the route exists, looks fine.
   - kubectl get gateway -n ${NS_GW}       -> the Gateway is Programmed.
   - Gateway listener shows ATTACHED ROUTES = 0.
   - curl -H 'Host: ${HOSTNAME_FQDN}' http://<gateway-address>/hostname -> 404.
   - The HTTPRoute status.parents[].conditions tell the real story.

 YOUR GOAL
   1. Get the HTTPRoute Accepted=True by the Gateway listener 'http'
      WITHOUT moving the route into ${NS_GW} (team ownership must stay).
      Prefer a least-privilege change: admit only namespace ${NS_ROUTE},
      not every namespace in the cluster.
   2. Get ResolvedRefs=True WITHOUT moving the Service out of ${NS_BACKEND}.
      The backend team must explicitly permit the cross-namespace reference.
   3. Do NOT edit the backend Deployment/Service, and do not change the
      GatewayClass or the controller.

 USEFUL STARTING POINTS
   kubectl get gateway ${GW_NAME} -n ${NS_GW} -o yaml
   kubectl describe httproute ${ROUTE_NAME} -n ${NS_ROUTE}
   kubectl get httproute ${ROUTE_NAME} -n ${NS_ROUTE} \\
     -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\\n"}{end}'

 When you think you are done:   $0 verify
 To remove the lab completely:   $0 cleanup
${RED}=============================================================================${RST}
EOF
}

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
route_cond() {
  # $1 = condition type -> prints "Status Reason" for the parent that is our Gateway
  kubectl get httproute "$ROUTE_NAME" -n "$NS_ROUTE" -o jsonpath="{range .status.parents[?(@.parentRef.name==\"${GW_NAME}\")]}{range .conditions[?(@.type==\"$1\")]}{.status} {.reason}{end}{end}" 2>/dev/null
}

do_verify() {
  local pass=0 total=0

  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl get httproute "$ROUTE_NAME" -n "$NS_ROUTE" >/dev/null 2>&1 \
    || die "HTTPRoute $NS_ROUTE/$ROUTE_NAME not found. Did you run '$0 break' (and not move/delete the route)?"

  # Check 1: route still in team-a, service still in shop-backend
  total=$((total+1))
  local be_ns
  be_ns="$(kubectl get httproute "$ROUTE_NAME" -n "$NS_ROUTE" -o jsonpath='{.spec.rules[0].backendRefs[0].namespace}')"
  if [[ "$be_ns" == "$NS_BACKEND" ]] && kubectl get svc "$SVC_NAME" -n "$NS_BACKEND" >/dev/null 2>&1; then
    ok "Ownership preserved: route in $NS_ROUTE, backend Service in $NS_BACKEND."
    pass=$((pass+1))
  else
    fail "Ownership changed: the backendRef must still point to $NS_BACKEND/$SVC_NAME."
  fi

  # Check 2: Accepted
  total=$((total+1))
  local acc
  acc="$(route_cond Accepted)"
  if [[ "$acc" == True* ]]; then
    ok "HTTPRoute Accepted: $acc"
    pass=$((pass+1))
  else
    fail "HTTPRoute Accepted: ${acc:-<no status yet>}  (hint: look at the listener's allowedRoutes)"
  fi

  # Check 3: ResolvedRefs
  total=$((total+1))
  local res
  res="$(route_cond ResolvedRefs)"
  if [[ "$res" == True* ]]; then
    ok "HTTPRoute ResolvedRefs: $res"
    pass=$((pass+1))
  else
    fail "HTTPRoute ResolvedRefs: ${res:-<no status yet>}  (hint: who must authorize a cross-namespace backendRef?)"
  fi

  # Check 4: least privilege on the listener
  total=$((total+1))
  local from
  from="$(kubectl get gateway "$GW_NAME" -n "$NS_GW" -o jsonpath='{.spec.listeners[?(@.name=="http")].allowedRoutes.namespaces.from}')"
  if [[ "$from" == "Selector" ]]; then
    ok "Listener uses 'from: Selector' (least privilege)."
    pass=$((pass+1))
  elif [[ "$from" == "All" ]]; then
    warn "Listener uses 'from: All'. It works, but ANY namespace can now attach routes to the shared Gateway. Use a Selector."
  else
    fail "Listener allowedRoutes.namespaces.from is '${from:-unset}'."
  fi

  # Check 5: attachedRoutes counter on the listener
  total=$((total+1))
  local attached
  attached="$(kubectl get gateway "$GW_NAME" -n "$NS_GW" -o jsonpath='{.status.listeners[?(@.name=="http")].attachedRoutes}')"
  if [[ "${attached:-0}" -ge 1 ]]; then
    ok "Listener 'http' reports attachedRoutes=$attached."
    pass=$((pass+1))
  else
    fail "Listener 'http' reports attachedRoutes=${attached:-0}."
  fi

  # Optional data-plane check (only if the Gateway has a reachable address)
  local addr
  addr="$(kubectl get gateway "$GW_NAME" -n "$NS_GW" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ -n "$addr" ]] && command -v curl >/dev/null 2>&1; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
              -H "Host: ${HOSTNAME_FQDN}" "http://${addr}/hostname" || echo 000)"
    if [[ "$code" == "200" ]]; then
      ok "Data plane: curl -H 'Host: ${HOSTNAME_FQDN}' http://${addr}/hostname -> 200 ($(curl -s --max-time 5 -H "Host: ${HOSTNAME_FQDN}" "http://${addr}/hostname"))"
    else
      warn "Data plane: got HTTP $code from ${addr} (address may be unreachable from this host; the control-plane checks above are authoritative)."
    fi
  else
    warn "Gateway has no status address (no LoadBalancer?). Skipping data-plane curl; try a port-forward to the implementation's proxy Service."
  fi

  echo
  if [[ "$pass" -eq "$total" ]]; then
    ok "ALL CHECKS PASSED ($pass/$total). Incident #2604 resolved."
  else
    fail "$pass/$total checks passed. Keep going."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
do_cleanup() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  info "Deleting lab namespaces labelled $LAB_LABEL..."
  for ns in "$NS_GW" "$NS_ROUTE" "$NS_BACKEND"; do
    if [[ "$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.lab}' 2>/dev/null)" == "ckne-2-6" ]]; then
      kubectl delete namespace "$ns" --wait=false >/dev/null && ok "Deleting namespace $ns"
    else
      warn "Namespace $ns not found or not created by this lab; left untouched."
    fi
  done
}

case "${1:-}" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *) echo "Usage: $0 {break|verify|cleanup}"; exit 2 ;;
esac

exit 0

# =============================================================================
# SOLUTION (step by step) - read only after you have tried
# =============================================================================
#
# --- Step 1: read the route status, not the route spec ---------------------
#
#   kubectl get httproute storefront -n team-a \
#     -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
#
#   Typical output (reasons are defined by the spec, exact set varies slightly
#   by implementation):
#
#     Accepted=False NotAllowedByListeners
#     ResolvedRefs=False RefNotPermitted
#
#   And on the Gateway:
#
#     kubectl get gateway shared-gw -n infra-gw \
#       -o jsonpath='{range .status.listeners[*]}{.name}{" attachedRoutes="}{.attachedRoutes}{"\n"}{end}'
#     http attachedRoutes=0
#
#   Key insight: the Gateway API is a two-way handshake. A route's parentRef
#   is a REQUEST to attach; the listener's allowedRoutes is the Gateway
#   owner's CONSENT. Likewise, a cross-namespace backendRef is a request that
#   the target namespace must consent to via ReferenceGrant. "kubectl apply"
#   succeeds because the objects are schema-valid; the rejection only lives
#   in .status.
#
# --- Step 2: fix FAULT #1 (listener only admits routes from 'Same') ---------
#
#   The listener has:
#       allowedRoutes:
#         namespaces:
#           from: Same
#   so only routes in infra-gw can attach. Least-privilege fix: use a Selector
#   on the immutable label kubernetes.io/metadata.name (set automatically by
#   the API server on every namespace since Kubernetes 1.22):
#
#   kubectl patch gateway shared-gw -n infra-gw --type=json -p='[
#     {"op":"replace",
#      "path":"/spec/listeners/0/allowedRoutes/namespaces",
#      "value":{"from":"Selector",
#               "selector":{"matchLabels":{"kubernetes.io/metadata.name":"team-a"}}}}
#   ]'
#
#   (Alternative for several app namespaces: label them, e.g.
#    kubectl label ns team-a shared-gw-access=true, and select on that label.
#    'from: All' also works but lets ANY namespace hijack hostnames on the
#    shared Gateway - avoid it on multi-tenant gateways.)
#
#   Re-check:
#     Accepted=True Accepted
#     ResolvedRefs=False RefNotPermitted
#
# --- Step 3: fix FAULT #2 (cross-namespace backendRef without consent) -------
#
#   The ReferenceGrant must live in the namespace of the TARGET (shop-backend),
#   because only the owner of a resource may grant access to it:
#
#   kubectl apply -f - <<'EOF'
#   apiVersion: gateway.networking.k8s.io/v1beta1
#   kind: ReferenceGrant
#   metadata:
#     name: allow-team-a-routes
#     namespace: shop-backend
#   spec:
#     from:
#       - group: gateway.networking.k8s.io
#         kind: HTTPRoute
#         namespace: team-a
#     to:
#       - group: ""
#         kind: Service
#         name: catalog
#   EOF
#
#   Notes:
#     - group "" means the core API group (Service).
#     - 'name' is optional; omitting it grants access to ALL Services in the
#       namespace. Naming it is least privilege.
#     - A ReferenceGrant placed in team-a would do nothing: the grant is
#       always authored by the side being referenced.
#
#   Re-check:
#     Accepted=True Accepted
#     ResolvedRefs=True ResolvedRefs
#
#   kubectl get gateway shared-gw -n infra-gw \
#     -o jsonpath='{.status.listeners[?(@.name=="http")].attachedRoutes}'
#   1
#
# --- Step 4: prove the data plane ------------------------------------------
#
#   GW=$(kubectl get gateway shared-gw -n infra-gw -o jsonpath='{.status.addresses[0].value}')
#   curl -s -H 'Host: shop.lab.example' "http://${GW}/hostname"
#   catalog-6d5f8b7c9d-x2k4q
#
#   Without a LoadBalancer, port-forward the proxy Service your implementation
#   created for the Gateway (name varies per implementation; find it with
#   kubectl get svc -A | grep shared-gw), then:
#   curl -s -H 'Host: shop.lab.example' http://127.0.0.1:8080/hostname
#
#   Note the Host header: the listener hostname "*.lab.example" and the route
#   hostname "shop.lab.example" intersect, so a request without that Host
#   header does not match and still gets 404 - that is correct behaviour.
#
# --- Step 5: validate and clean up -----------------------------------------
#
#   ./break-fix-2.6.sh verify
#   ./break-fix-2.6.sh cleanup
#
# TAKEAWAYS
#   - Route attachment = parentRef (request) + allowedRoutes (consent).
#   - Cross-namespace backendRefs = backendRef (request) + ReferenceGrant in
#     the target namespace (consent).
#   - Debug from .status: HTTPRoute status.parents[].conditions (Accepted,
#     ResolvedRefs) and Gateway status.listeners[].attachedRoutes.
#   - Prefer 'from: Selector' over 'from: All' on shared Gateways, and name
#     the exact Service in a ReferenceGrant.
# =============================================================================