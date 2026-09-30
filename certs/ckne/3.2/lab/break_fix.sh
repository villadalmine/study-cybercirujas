#!/usr/bin/env bash
# =============================================================================
# CKNE 3.2 - Implementing Routing to Expose Networks
# BREAK & FIX LAB: "The route that the Gateway ignores"
# =============================================================================
#
# RUN THIS ONLY ON A DISPOSABLE LAB CLUSTER (kind, kubeadm VM, k3d...).
# Everything is created in three namespaces labelled bf-lab=ckne-3-2.
# `cleanup` deletes those namespaces and nothing else.
#
# WHAT THIS LAB BUILDS
#   bf-gw       Gateway "edge": one HTTP listener for "*.lab.example".
#               Its allowedRoutes accepts routes only from namespaces labelled
#               expose=true.
#   bf-app      Deployment/Service "web" and the HTTPRoute "shop" for
#               shop.lab.example.
#   bf-backend  Deployment/Service "api". It is owned by another team, so it
#               lives in another namespace.
#
# INTENDED BEHAVIOUR (what you must restore)
#   Host: shop.lab.example   GET /           -> body "web"
#   Host: shop.lab.example   GET /api        -> body "api"
#   Host: shop.lab.example   GET /api/items  -> body "api"
#   HTTPRoute bf-app/shop -> Accepted=True, ResolvedRefs=True
#
# WHAT GETS BROKEN
#   There are three independent faults, stacked like real incidents: fixing
#   one reveals the next. The only thing wrong is routing configuration. The
#   pods and Services are healthy, so debugging them wastes time.
#
# REQUIREMENTS
#   - kubectl pointed at the lab cluster
#   - Gateway API CRDs (standard channel, v1.0+): Gateway, HTTPRoute,
#     ReferenceGrant
#   - A working Gateway controller with a GatewayClass (Envoy Gateway, Cilium
#     with gatewayAPI.enabled, Istio, NGINX Gateway Fabric, Traefik...)
#   - curl
#
# USAGE
#   ./break-fix-3.2.sh break     # deploy the lab in its broken state
#   ./break-fix-3.2.sh verify    # check your progress (run it as often as you like)
#   ./break-fix-3.2.sh hint      # progressive hints, no spoilers for the full fix
#   ./break-fix-3.2.sh cleanup   # remove everything
#
# OPTIONAL ENVIRONMENT
#   GW_CLASS=<name>     GatewayClass to use (default: the first one found)
#   GW_PORT=<port>      Listener port (default: 80)
#   GW_ADDR=<ip|host>   Address to curl if Gateway .status.addresses is empty.
#                       For example, if no LoadBalancer exists, run
#                       `kubectl port-forward` against the Service your
#                       controller generated for the Gateway, then use
#                       GW_ADDR=127.0.0.1 GW_PORT=<local-port>.
#   BF_ASSUME_YES=1     Skip the confirmation prompt
#
# REFERENCES
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://gateway-api.sigs.k8s.io/reference/api-types/httproute/
#   https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/
#   https://gateway-api.sigs.k8s.io/guides/multiple-ns/
#   https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/
# =============================================================================

set -euo pipefail

LAB_LABEL="bf-lab=ckne-3-2"
NS_GW="bf-gw"
NS_APP="bf-app"
NS_BE="bf-backend"
HOST="shop.lab.example"
GW_PORT="${GW_PORT:-80}"
ECHO_IMAGE="hashicorp/http-echo:1.0.0"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight: never touch a cluster we are not sure about
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
  command -v curl    >/dev/null 2>&1 || die "curl not found in PATH"

  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "cannot reach the API server with the current kubeconfig"

  for res in gateways.gateway.networking.k8s.io \
             httproutes.gateway.networking.k8s.io \
             referencegrants.gateway.networking.k8s.io; do
    kubectl get crd "$res" >/dev/null 2>&1 \
      || die "CRD $res missing - install the Gateway API standard channel first"
  done

  if [[ -z "${GW_CLASS:-}" ]]; then
    GW_CLASS="$(kubectl get gatewayclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  [[ -n "${GW_CLASS:-}" ]] \
    || die "no GatewayClass found - install a Gateway controller (e.g. Envoy Gateway) or set GW_CLASS"

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  bold "kube context : $ctx"
  bold "GatewayClass : $GW_CLASS"
  bold "listener port: $GW_PORT"

  # Refuse to reuse namespaces that were not created by this lab.
  for ns in "$NS_GW" "$NS_APP" "$NS_BE"; do
    if kubectl get ns "$ns" >/dev/null 2>&1; then
      local owner
      owner="$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.bf-lab}')"
      [[ "$owner" == "ckne-3-2" ]] \
        || die "namespace $ns exists and is not owned by this lab - aborting"
    fi
  done

  if [[ "${BF_ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "This is a DISPOSABLE lab cluster and I want to deploy the broken lab [y/N]: " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by user"
  fi
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  preflight

  bold ">> Creating namespaces"
  # Fault #1 is here: bf-app is deliberately created WITHOUT expose=true.
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS_GW}
  labels:
    bf-lab: ckne-3-2
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS_APP}
  labels:
    bf-lab: ckne-3-2
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS_BE}
  labels:
    bf-lab: ckne-3-2
    expose: "true"
EOF

  bold ">> Deploying backends (healthy on purpose)"
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ${NS_APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: echo
          image: ${ECHO_IMAGE}
          args:
            - "-text=web"
            - "-listen=:5678"
          ports:
            - containerPort: 5678
          readinessProbe:
            tcpSocket:
              port: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: ${NS_APP}
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: ${NS_BE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: echo
          image: ${ECHO_IMAGE}
          args:
            - "-text=api"
            - "-listen=:5678"
          ports:
            - containerPort: 5678
          readinessProbe:
            tcpSocket:
              port: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: ${NS_BE}
spec:
  selector:
    app: api
  ports:
    - name: http
      port: 80
      targetPort: 5678
EOF

  bold ">> Creating the Gateway"
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: ${NS_GW}
spec:
  gatewayClassName: ${GW_CLASS}
  listeners:
    - name: http
      protocol: HTTP
      port: ${GW_PORT}
      hostname: "*.lab.example"
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              expose: "true"
EOF

  bold ">> Creating the HTTPRoute"
  # Fault #2: cross-namespace backendRef to bf-backend/api with no ReferenceGrant.
  # Fault #3: /api uses Exact, so /api/items falls through to the "/" prefix rule.
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: ${NS_APP}
spec:
  parentRefs:
    - name: edge
      namespace: ${NS_GW}
      sectionName: http
  hostnames:
    - ${HOST}
  rules:
    - matches:
        - path:
            type: Exact
            value: /api
      backendRefs:
        - name: api
          namespace: ${NS_BE}
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: web
          port: 80
EOF

  bold ">> Waiting for backends to become Ready"
  kubectl -n "$NS_APP" rollout status deploy/web --timeout=120s || yellow "web not ready yet"
  kubectl -n "$NS_BE"  rollout status deploy/api --timeout=120s || yellow "api not ready yet"

  bold ">> Waiting for the Gateway to be Programmed (may time out without a LoadBalancer)"
  kubectl -n "$NS_GW" wait --for=condition=Programmed gateway/edge --timeout=120s \
    || yellow "Gateway not Programmed yet - check 'kubectl -n $NS_GW describe gateway edge'"

  cat <<EOF

$(bold "============================ THE INCIDENT ============================")
The product team says:
  "We shipped shop.lab.example through the shared edge Gateway. Nothing
   works. The pods are green, the Services have endpoints, and the Gateway
   is up. When we get a response at all, /api/items comes back from the
   wrong service."

SYMPTOMS YOU WILL SEE
  * curl -H 'Host: ${HOST}' http://<gw>:${GW_PORT}/ fails with an HTTP 404
    or a connection error, depending on the implementation. The route is not
    attached to the listener.
  * 'kubectl -n ${NS_APP} describe httproute shop' shows conditions in the
    parent status. Read the Reason fields, not just the Status fields.
  * After the first fix, one path answers 500. Another path answers 200,
    but from the wrong backend.

YOUR GOAL
  GET /           -> "web"
  GET /api        -> "api"
  GET /api/items  -> "api"
  HTTPRoute shop  -> Accepted=True and ResolvedRefs=True

RULES
  * Do NOT modify the Gateway ${NS_GW}/edge. It is shared infrastructure
    owned by the platform team, and its allowedRoutes policy is intentional.
  * Do NOT move the api Service out of ${NS_BE}.
  * Do NOT touch Deployments or Services. They are fine.

  Check progress:  $0 verify
  Need a nudge:    $0 hint
EOF
}

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
cond() {
  # cond <type> -> status/reason of that condition on the first parent of the route
  local t="$1"
  local s r
  s="$(kubectl -n "$NS_APP" get httproute shop \
        -o jsonpath="{.status.parents[0].conditions[?(@.type==\"$t\")].status}" 2>/dev/null || true)"
  r="$(kubectl -n "$NS_APP" get httproute shop \
        -o jsonpath="{.status.parents[0].conditions[?(@.type==\"$t\")].reason}" 2>/dev/null || true)"
  echo "${s:-Unknown}/${r:-none}"
}

gw_addr() {
  if [[ -n "${GW_ADDR:-}" ]]; then
    echo "$GW_ADDR"
    return
  fi
  kubectl -n "$NS_GW" get gateway edge -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

probe() {
  # probe <path> <expected-body>
  local path="$1" want="$2" addr="$3"
  local out code body
  out="$(curl -s --max-time 5 -o - -w $'\n%{http_code}' \
          -H "Host: ${HOST}" "http://${addr}:${GW_PORT}${path}" 2>/dev/null || echo $'\n000')"
  code="$(printf '%s' "$out" | tail -n1)"
  body="$(printf '%s' "$out" | sed '$d' | tr -d '\r\n')"
  if [[ "$code" == "200" && "$body" == "$want" ]]; then
    green "  PASS  GET ${path} -> ${code} '${body}'"
    return 0
  fi
  red   "  FAIL  GET ${path} -> ${code} '${body}' (expected 200 '${want}')"
  return 1
}

do_verify() {
  kubectl get ns "$NS_APP" >/dev/null 2>&1 || die "lab not deployed - run '$0 break' first"

  local fails=0
  bold "HTTPRoute ${NS_APP}/shop status"
  local acc res
  acc="$(cond Accepted)"
  res="$(cond ResolvedRefs)"
  if [[ "$acc" == True/* ]]; then green "  PASS  Accepted     = $acc"; else red "  FAIL  Accepted     = $acc"; fails=$((fails+1)); fi
  if [[ "$res" == True/* ]]; then green "  PASS  ResolvedRefs = $res"; else red "  FAIL  ResolvedRefs = $res"; fails=$((fails+1)); fi

  bold "Gateway ${NS_GW}/edge was not modified"
  local allowed
  allowed="$(kubectl -n "$NS_GW" get gateway edge \
      -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}')"
  if [[ "$allowed" == "Selector" ]]; then
    green "  PASS  allowedRoutes.namespaces.from = Selector"
  else
    red   "  FAIL  allowedRoutes.namespaces.from = ${allowed} (the shared Gateway must not be loosened)"
    fails=$((fails+1))
  fi

  bold "Data plane (Host: ${HOST})"
  local addr
  addr="$(gw_addr)"
  if [[ -z "$addr" ]]; then
    yellow "  SKIP  Gateway has no .status.addresses - set GW_ADDR (and GW_PORT) to test traffic"
    fails=$((fails+1))
  else
    echo "  gateway address: ${addr}:${GW_PORT}"
    probe /          web "$addr" || fails=$((fails+1))
    probe /api       api "$addr" || fails=$((fails+1))
    probe /api/items api "$addr" || fails=$((fails+1))
  fi

  echo
  if [[ "$fails" -eq 0 ]]; then
    green "ALL CHECKS PASSED - the network is exposed correctly."
  else
    yellow "${fails} check(s) failing. Keep going ('$0 hint' if stuck)."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# HINTS
# -----------------------------------------------------------------------------
do_hint() {
  cat <<'EOF'
HINT 1 - Start from the route's status. The controller writes one entry per
         parentRef under .status.parents. The Reason explains the failure:
           kubectl -n bf-app get httproute shop -o yaml | sed -n '/^status:/,$p'

HINT 2 - A Gateway listener decides WHICH namespaces may attach routes to it
         (spec.listeners[].allowedRoutes). Compare the listener's selector
         with the labels on the route's namespace:
           kubectl -n bf-gw get gateway edge -o jsonpath='{.spec.listeners[0].allowedRoutes}'; echo
           kubectl get ns bf-app --show-labels

HINT 3 - A route may reference a Service in ANOTHER namespace only if the
         owner of that namespace allows it. The grant lives in the TARGET
         namespace, not in the route's namespace. Look up the reason
         RefNotPermitted.

HINT 4 - Gateway API path match types: Exact, PathPrefix and
         RegularExpression (implementation-specific). Which one matches
         /api/items? And when several rules match, which one wins?
EOF
}

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------
do_cleanup() {
  bold ">> Deleting lab namespaces (selector ${LAB_LABEL})"
  kubectl delete ns -l "$LAB_LABEL" --wait=true --ignore-not-found
  green "Lab removed."
}

case "${1:-}" in
  break)   do_break ;;
  verify)  do_verify ;;
  hint)    do_hint ;;
  cleanup) do_cleanup ;;
  *)
    echo "usage: $0 {break|verify|hint|cleanup}"
    exit 2
    ;;
esac

# =============================================================================
# SOLUTION - STEP BY STEP (do not read before trying)
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 - Rule out the data plane before touching routing
# ---------------------------------------------------------------------------
#   kubectl -n bf-app get endpointslices -l kubernetes.io/service-name=web
#   kubectl -n bf-backend get endpointslices -l kubernetes.io/service-name=api
#   kubectl -n bf-gw get gateway edge
#
#   Both Services have ready endpoints, and the Gateway shows PROGRAMMED=True.
#   The problem is between the listener and the route. That layer is the
#   Gateway API "attachment" contract.
#
# ---------------------------------------------------------------------------
# STEP 1 - Fault #1: the route is not allowed to attach to the listener
# ---------------------------------------------------------------------------
#   kubectl -n bf-app describe httproute shop
#
#   Expected (abbreviated):
#     Status:
#       Parents:
#         Conditions:
#           Type:    Accepted
#           Status:  False
#           Reason:  NotAllowedByListeners
#         Parent Ref:
#           Name:          edge
#           Namespace:     bf-gw
#           Section Name:  http
#
#   The listener only admits routes from namespaces labelled expose=true:
#     kubectl -n bf-gw get gateway edge \
#       -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces}'; echo
#     {"from":"Selector","selector":{"matchLabels":{"expose":"true"}}}
#
#     kubectl get ns bf-app --show-labels
#     NAME     STATUS   AGE   LABELS
#     bf-app   Active   3m    bf-lab=ckne-3-2,kubernetes.io/metadata.name=bf-app
#
#   Attachment is a two-way handshake. The route asks for a parent in
#   parentRefs, and the Gateway admits it through allowedRoutes. The platform
#   team controls the second half. Do not change the Gateway to "from: All",
#   because that would let any namespace publish any hostname on the shared
#   edge. Onboard the namespace instead:
#
#     kubectl label ns bf-app expose=true
#
#   Now Accepted=True/Accepted. GET / returns "web". GET /api returns 500, and
#   GET /api/items returns "web". Two faults remain.
#
# ---------------------------------------------------------------------------
# STEP 2 - Fault #2: cross-namespace backendRef without a ReferenceGrant
# ---------------------------------------------------------------------------
#   kubectl -n bf-app get httproute shop \
#     -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")]}'; echo
#
#   Expected:
#     {"...","reason":"RefNotPermitted","status":"False","type":"ResolvedRefs"}
#
#   The spec says a rule whose backend reference is invalid must answer HTTP
#   500 for matching requests. The other rules keep working, so this is a
#   partial outage.
#
#   Only the owner of the TARGET namespace (bf-backend) can grant access.
#   The route owner cannot give themselves permission. The ReferenceGrant goes
#   in bf-backend and should be as narrow as possible: one source kind, one
#   source namespace, and one named Service.
#
#     kubectl apply -f - <<'EOF'
#     apiVersion: gateway.networking.k8s.io/v1beta1
#     kind: ReferenceGrant
#     metadata:
#       name: allow-bf-app-httproutes
#       namespace: bf-backend
#     spec:
#       from:
#         - group: gateway.networking.k8s.io
#           kind: HTTPRoute
#           namespace: bf-app
#       to:
#         - group: ""
#           kind: Service
#           name: api
#     EOF
#
#   (group "" is the core API group, where Service lives.)
#
#   Now ResolvedRefs=True/ResolvedRefs and GET /api returns "api".
#   GET /api/items still returns "web".
#
# ---------------------------------------------------------------------------
# STEP 3 - Fault #3: Exact match sends sub-paths to the catch-all rule
# ---------------------------------------------------------------------------
#   The first rule uses path type Exact with value /api. It matches exactly
#   "/api" and nothing else. /api/items does not match it, so it falls to
#   PathPrefix "/", which matches everything. The request succeeds, but it
#   reaches the wrong service. No status condition reports this. Only
#   end-to-end testing catches it.
#
#   PathPrefix matches whole path elements: /api matches /api, /api/ and
#   /api/items, but NOT /apiv2. When several rules match, Gateway API gives
#   precedence to Exact over PathPrefix, and then to the longest prefix.
#   With PathPrefix /api and PathPrefix /, requests under /api always reach
#   the api backend, whatever the order of the rules.
#
#     kubectl -n bf-app patch httproute shop --type=json -p='[
#       {"op":"replace","path":"/spec/rules/0/matches/0/path/type","value":"PathPrefix"}
#     ]'
#
# ---------------------------------------------------------------------------
# STEP 4 - Prove it end to end
# ---------------------------------------------------------------------------
#   GW=$(kubectl -n bf-gw get gateway edge -o jsonpath='{.status.addresses[0].value}')
#   for p in / /api /api/items; do
#     printf '%-12s ' "$p"; curl -s -H 'Host: shop.lab.example' "http://$GW$p"
#   done
#
#   Expected:
#     /            web
#     /api         api
#     /api/items   api
#
#   ./break-fix-3.2.sh verify   -> ALL CHECKS PASSED
#
# ---------------------------------------------------------------------------
# TAKEAWAYS FOR THE EXAM
# ---------------------------------------------------------------------------
#   1. Read .status.parents[].conditions on the ROUTE first. The Gateway can
#      be Programmed while every route on it is rejected.
#   2. Accepted=False/NotAllowedByListeners -> allowedRoutes (namespace
#      selector or kinds). Accepted=False/NoMatchingListenerHostname ->
#      listener hostname vs route hostnames. Fix these on the route side, or
#      on namespace labels, unless you own the Gateway.
#   3. ResolvedRefs=False/RefNotPermitted -> missing ReferenceGrant, created
#      in the namespace that OWNS the referenced object.
#   4. ResolvedRefs=False/BackendNotFound -> wrong Service name or namespace.
#      A port that does not exist on the Service is also invalid.
#   5. A 200 from the wrong backend is a match/precedence bug, not an
#      attachment bug. Test every path you publish, not just "/".
#
# Cleanup when done:  ./break-fix-3.2.sh cleanup
# =============================================================================