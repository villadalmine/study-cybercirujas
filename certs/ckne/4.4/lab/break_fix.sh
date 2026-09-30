#!/usr/bin/env bash
# =============================================================================
# CKNE - Topic 4.4: Implementing Pod-level Authentication and Authorization
# BREAK & FIX LAB: "The frontend lost its identity"
# =============================================================================
#
# WHAT THIS LAB COVERS
#   In a service mesh, pod-level authentication and authorization work in two layers:
#
#     1. AUTHENTICATION (who is calling?)
#        Each sidecar gets an X.509 certificate from istiod. The certificate
#        carries a SPIFFE ID derived from the pod's ServiceAccount:
#            spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>
#        A PeerAuthentication in STRICT mode makes the server-side sidecar
#        reject any connection that is not mutual TLS. A pod without a sidecar
#        has no certificate, so the server resets its connection.
#
#     2. AUTHORIZATION (is this caller allowed to do this?)
#        An AuthorizationPolicy with action ALLOW matches the authenticated
#        identity (source.principals = "<trust-domain>/ns/<ns>/sa/<sa>"),
#        the HTTP method, the path and so on. Once any ALLOW policy selects
#        a workload, every request that matches no rule is denied with
#        HTTP 403 "RBAC: access denied".
#
#   This script breaks both layers, one on top of the other. The first
#   symptom hides the second one. That is how this usually looks in production.
#
# REQUIREMENTS (disposable lab VM only)
#   - A Kubernetes cluster you can throw away (kind, minikube, k3d, kubeadm VM)
#   - Istio in sidecar mode (istiod running in istio-system); ambient mode
#     does not apply here
#   - kubectl; istioctl is optional but strongly recommended for diagnosis
#   - Outbound internet access to pull images:
#       docker.io/mccutchen/go-httpbin:v2.15.0
#       docker.io/curlimages/curl:8.8.0
#
# USAGE
#   ./ckne-4.4-break-fix.sh break     # deploy the scenario and break it
#   ./ckne-4.4-break-fix.sh status    # show the current symptoms
#   ./ckne-4.4-break-fix.sh check     # grade your fix (exit 0 = solved)
#   ./ckne-4.4-break-fix.sh cleanup   # delete everything this lab created
#
#   Optional environment variables:
#     ISTIO_REV=<rev>   use the istio.io/rev=<rev> label instead of istio-injection=enabled
#     BF_I_KNOW=1       skip the check that the kube context looks like a lab cluster
#
# SAFETY
#   The script creates and changes ONLY the namespaces "bf-authz" and
#   "bf-authz-outside". It does not touch istio-system, mesh-wide policies
#   or any other workload.
#
# OFFICIAL REFERENCES
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://istio.io/latest/docs/concepts/security/
#   https://istio.io/latest/docs/reference/config/security/peer_authentication/
#   https://istio.io/latest/docs/reference/config/security/authorization-policy/
#   https://istio.io/latest/docs/reference/config/security/conditions/
#   https://istio.io/latest/docs/ops/common-problems/security-issues/
#   https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
#   https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
#   https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
# =============================================================================

set -euo pipefail

NS="bf-authz"
NS_OUT="bf-authz-outside"
HTTPBIN_IMAGE="docker.io/mccutchen/go-httpbin:v2.15.0"
CURL_IMAGE="docker.io/curlimages/curl:8.8.0"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

info()  { printf '%s[INFO]%s %s\n'  "$BLUE"   "$RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$GREEN"  "$RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$YELLOW" "$RESET" "$*"; }
fail()  { printf '%s[FAIL]%s %s\n'  "$RED"    "$RESET" "$*"; }
die()   { fail "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."

  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "Cannot reach the API server. Check your kubeconfig/context."

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  if [[ "${BF_I_KNOW:-0}" != "1" ]] && ! [[ "$ctx" =~ (kind|minikube|k3d|lab|test|sandbox|dev|kubernetes-admin) ]]; then
    die "Current context '$ctx' does not look like a disposable lab cluster. Re-run with BF_I_KNOW=1 if you are sure."
  fi
  info "Kube context: ${BOLD}${ctx}${RESET}"

  kubectl get crd authorizationpolicies.security.istio.io >/dev/null 2>&1 \
    || die "The Istio CRDs are not installed (authorizationpolicies.security.istio.io)."
  kubectl get crd peerauthentications.security.istio.io >/dev/null 2>&1 \
    || die "The Istio CRDs are not installed (peerauthentications.security.istio.io)."

  kubectl -n istio-system get deploy -l app=istiod -o name 2>/dev/null | grep -q . \
    || die "istiod was not found in istio-system. This lab needs Istio in sidecar mode."

  kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -q 'istio-sidecar-injector' \
    || die "The Istio sidecar injector webhook was not found. Sidecar injection is required."

  if ! command -v istioctl >/dev/null 2>&1; then
    warn "istioctl not found. The lab still works, but diagnosis will be harder."
  fi
}

# Read the mesh trust domain from the mesh config (it defaults to cluster.local)
detect_trust_domain() {
  local cm="istio" td=""
  [[ -n "${ISTIO_REV:-}" ]] && cm="istio-${ISTIO_REV}"
  td="$(kubectl -n istio-system get cm "$cm" -o jsonpath='{.data.mesh}' 2>/dev/null \
        | awk '/^trustDomain:/ {print $2}' | tr -d '"' || true)"
  echo "${td:-cluster.local}"
}

injection_label() {
  if [[ -n "${ISTIO_REV:-}" ]]; then
    echo "istio.io/rev=${ISTIO_REV}"
  else
    echo "istio-injection=enabled"
  fi
}

# -----------------------------------------------------------------------------
# HTTP probe helper: prints only the HTTP code (000 = TCP/TLS failure)
# -----------------------------------------------------------------------------
probe() {
  local ns="$1" deploy="$2" url="$3"
  kubectl -n "$ns" exec "deploy/${deploy}" -c curl -- \
    curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true
}

probe_verbose() {
  local ns="$1" deploy="$2" url="$3"
  kubectl -n "$ns" exec "deploy/${deploy}" -c curl -- \
    curl -sS --max-time 5 -w '\n[http_code=%{http_code}]\n' "$url" 2>&1 || true
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  preflight
  local td inj
  td="$(detect_trust_domain)"
  inj="$(injection_label)"
  info "Detected trust domain: ${BOLD}${td}${RESET}"

  info "Creating namespaces..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" "$inj" --overwrite >/dev/null
  kubectl create namespace "$NS_OUT" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS_OUT" istio-injection=disabled --overwrite >/dev/null

  info "Deploying httpbin (server), frontend (legitimate client), intruder (unauthorized client)..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: ${NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: ${NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: intruder
  namespace: ${NS}
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: ${NS}
  labels:
    app: httpbin
spec:
  selector:
    app: httpbin
  ports:
    - name: http
      port: 8000
      targetPort: 8080
      appProtocol: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
        - name: httpbin
          image: ${HTTPBIN_IMAGE}
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /status/200
              port: 8080
            periodSeconds: 5
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: frontend
      terminationGracePeriodSeconds: 0
      containers:
        - name: curl
          image: ${CURL_IMAGE}
          command: ["sleep", "infinity"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: intruder
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: intruder
  template:
    metadata:
      labels:
        app: intruder
    spec:
      serviceAccountName: intruder
      terminationGracePeriodSeconds: 0
      containers:
        - name: curl
          image: ${CURL_IMAGE}
          command: ["sleep", "infinity"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: outsider
  namespace: ${NS_OUT}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: outsider
  template:
    metadata:
      labels:
        app: outsider
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: curl
          image: ${CURL_IMAGE}
          command: ["sleep", "infinity"]
EOF

  info "Applying authentication (STRICT mTLS) and authorization (ALLOW)..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ${NS}
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow-frontend
  namespace: ${NS}
spec:
  selector:
    matchLabels:
      app: httpbin
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "${td}/ns/${NS}/sa/front-end"
      to:
        - operation:
            methods: ["GET"]
            paths: ["/get", "/headers"]
EOF

  info "Waiting for the pods to be ready (this can take a while the first time images are pulled)..."
  kubectl -n "$NS" rollout status deploy/httpbin  --timeout=180s >/dev/null
  kubectl -n "$NS" rollout status deploy/frontend --timeout=180s >/dev/null
  kubectl -n "$NS" rollout status deploy/intruder --timeout=180s >/dev/null
  kubectl -n "$NS_OUT" rollout status deploy/outsider --timeout=180s >/dev/null
  sleep 5

  cat <<EOF

${BOLD}==================== SCENARIO ====================${RESET}
The platform team secured the "httpbin" service in namespace ${BOLD}${NS}${RESET}:

  * Pod-level authentication: PeerAuthentication "default" -> STRICT mTLS.
  * Pod-level authorization:  AuthorizationPolicy "httpbin-allow-frontend"
    should let ONLY the workload running as ServiceAccount "frontend"
    call GET /get and GET /headers.

After a "harmless" change, the frontend team says:

  "Our pod can't reach httpbin at all. Please just disable the security."

${BOLD}SYMPTOM you will see now:${RESET}
  kubectl -n ${NS} exec deploy/frontend -c curl -- curl -sS http://httpbin:8000/get
  -> curl: (56) Recv failure: Connection reset by peer

  Once you get past that layer, a second symptom appears:
  -> RBAC: access denied      (HTTP 403)

${BOLD}YOUR GOAL (all of these must hold at the same time):${RESET}
  1. frontend  -> GET http://httpbin:8000/get              returns 200
  2. intruder  -> GET http://httpbin:8000/get              returns 403 (still denied)
  3. frontend  -> POST http://httpbin:8000/post            returns 403 (only GET is allowed)
  4. outsider (${NS_OUT}, no sidecar) -> httpbin           fails (000) = STRICT mTLS still enforced
  5. PeerAuthentication stays STRICT, and httpbin stays protected by an ALLOW policy.

${BOLD}NOT ALLOWED:${RESET} switching to PERMISSIVE, deleting the policy, using principals "*",
or allowing the whole namespace. That turns security off; it does not fix it.

Useful commands:  $0 status   |   $0 check   |   $0 cleanup
${BOLD}==================================================${RESET}
EOF
}

# -----------------------------------------------------------------------------
# STATUS
# -----------------------------------------------------------------------------
do_status() {
  kubectl get ns "$NS" >/dev/null 2>&1 || die "The lab is not deployed. Run: $0 break"
  echo "${BOLD}--- Pods (look at the READY column: 2/2 = has a sidecar) ---${RESET}"
  kubectl -n "$NS" get pods -o wide
  echo
  echo "${BOLD}--- frontend -> GET /get ---${RESET}"
  probe_verbose "$NS" frontend "http://httpbin:8000/get" | tail -n 5
  echo
  echo "${BOLD}--- intruder -> GET /get ---${RESET}"
  probe_verbose "$NS" intruder "http://httpbin:8000/get" | tail -n 3
  echo
  echo "${BOLD}--- outsider (${NS_OUT}) -> GET /get ---${RESET}"
  probe_verbose "$NS_OUT" outsider "http://httpbin.${NS}:8000/get" | tail -n 3
}

# -----------------------------------------------------------------------------
# CHECK
# -----------------------------------------------------------------------------
has_sidecar() {
  local ns="$1" app="$2" names
  names="$(kubectl -n "$ns" get pods -l "app=${app}" --field-selector=status.phase=Running \
           -o jsonpath='{.items[*].spec.containers[*].name} {.items[*].spec.initContainers[*].name}' 2>/dev/null || true)"
  [[ " $names " == *" istio-proxy "* ]]
}

do_check() {
  kubectl get ns "$NS" >/dev/null 2>&1 || die "The lab is not deployed. Run: $0 break"
  local pass=0 total=0 code mode ap_count

  check() {
    total=$((total + 1))
    if [[ "$1" == "true" ]]; then ok "$2"; pass=$((pass + 1)); else fail "$2"; fi
  }

  # 1. frontend is in the mesh (it has an identity)
  if has_sidecar "$NS" frontend; then check true "frontend has an istio-proxy sidecar (SPIFFE identity)"
  else check false "frontend has NO sidecar -> no certificate -> STRICT mTLS resets the connection"; fi

  # 2. frontend -> GET /get = 200
  code="$(probe "$NS" frontend "http://httpbin:8000/get")"
  [[ "$code" == "200" ]] && check true "frontend GET /get -> 200" \
                         || check false "frontend GET /get -> ${code} (expected 200)"

  # 3. frontend -> POST /post = 403
  code="$(kubectl -n "$NS" exec deploy/frontend -c curl -- \
          curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST http://httpbin:8000/post 2>/dev/null || true)"
  [[ "$code" == "403" ]] && check true "frontend POST /post -> 403 (least privilege kept)" \
                         || check false "frontend POST /post -> ${code} (expected 403)"

  # 4. intruder -> GET /get = 403
  code="$(probe "$NS" intruder "http://httpbin:8000/get")"
  [[ "$code" == "403" ]] && check true "intruder GET /get -> 403 (authorization still enforced)" \
                         || check false "intruder GET /get -> ${code} (expected 403; the policy is too broad)"

  # 5. outsider without mTLS = 000
  code="$(probe "$NS_OUT" outsider "http://httpbin.${NS}:8000/get")"
  [[ "$code" == "000" ]] && check true "outsider without a sidecar -> connection rejected (STRICT mTLS enforced)" \
                         || check false "outsider without a sidecar -> ${code} (expected 000; STRICT mTLS has been relaxed)"

  # 6. PeerAuthentication STRICT
  mode="$(kubectl -n "$NS" get peerauthentication default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || true)"
  [[ "$mode" == "STRICT" ]] && check true "PeerAuthentication default = STRICT" \
                            || check false "PeerAuthentication default = '${mode:-missing}' (expected STRICT)"

  # 7. An ALLOW policy still selects httpbin
  ap_count="$(kubectl -n "$NS" get authorizationpolicy -o jsonpath='{range .items[*]}{.spec.action}{"|"}{.spec.selector.matchLabels.app}{"\n"}{end}' 2>/dev/null \
              | grep -Ec '^(ALLOW)?\|httpbin$' || true)"
  [[ "${ap_count:-0}" -ge 1 ]] && check true "httpbin is protected by an ALLOW AuthorizationPolicy" \
                               || check false "No ALLOW AuthorizationPolicy selects app=httpbin"

  echo
  if [[ "$pass" -eq "$total" ]]; then
    printf '%s%sSOLVED: %d/%d checks. Authentication and authorization are both working at pod level.%s\n' "$GREEN" "$BOLD" "$pass" "$total" "$RESET"
    return 0
  else
    printf '%s%sNOT SOLVED YET: %d/%d checks.%s\n' "$RED" "$BOLD" "$pass" "$total" "$RESET"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------
do_cleanup() {
  info "Deleting namespaces ${NS} and ${NS_OUT}..."
  kubectl delete namespace "$NS" "$NS_OUT" --ignore-not-found --wait=true >/dev/null
  ok "Lab removed."
}

case "${1:-}" in
  break)   do_break ;;
  status)  do_status ;;
  check)   do_check ;;
  cleanup) do_cleanup ;;
  *)
    echo "Usage: $0 {break|status|check|cleanup}"
    exit 2
    ;;
esac

exit 0

# =============================================================================
# STEP-BY-STEP SOLUTION (do not read until you have tried)
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0 - Reproduce and classify the symptom
# -----------------------------------------------------------------------------
#   kubectl -n bf-authz exec deploy/frontend -c curl -- curl -sS http://httpbin:8000/get
#     curl: (56) Recv failure: Connection reset by peer
#
#   Ask yourself: is it a TCP/TLS failure or an HTTP answer?
#     - Connection reset / 000  -> the server sidecar rejected the connection
#       BEFORE any HTTP was exchanged. That is the AUTHENTICATION layer (mTLS).
#     - HTTP 403 "RBAC: access denied" -> TLS worked and the identity is known,
#       but no ALLOW rule matched. That is the AUTHORIZATION layer.
#     - HTTP 503 "upstream connect error" -> usually a DestinationRule/TLS
#       mismatch on the CLIENT side, not an AuthorizationPolicy.
#
# -----------------------------------------------------------------------------
# STEP 1 - Authentication: does the client even have an identity?
# -----------------------------------------------------------------------------
#   kubectl -n bf-authz get pods
#     NAME                        READY   STATUS    RESTARTS   AGE
#     frontend-6c9f7d8b5d-x2mzq   1/1     Running   0          2m     <-- 1/1: no sidecar
#     httpbin-7b8d9c7f6-k8vlp     2/2     Running   0          2m
#     intruder-5f7d6c9b8-q4wzn    2/2     Running   0          2m
#
#   istioctl proxy-status | grep bf-authz
#     -> httpbin and intruder are listed, frontend is NOT.
#
#   Why is it missing? The namespace is labeled for injection, so something
#   in the pod template opts it out:
#   kubectl -n bf-authz get deploy frontend -o jsonpath='{.spec.template.metadata.labels}'; echo
#     {"app":"frontend","sidecar.istio.io/inject":"false"}
#
#   Without a sidecar the pod has no SPIFFE certificate and sends plain text.
#   The PeerAuthentication in STRICT mode makes httpbin's sidecar accept only
#   mTLS, so it resets the connection:
#   kubectl -n bf-authz get peerauthentication default -o jsonpath='{.spec.mtls.mode}'; echo
#     STRICT
#
#   FIX 1 - remove the opt-out label (in a JSON Pointer, "/" is escaped as "~1").
#   Changing the pod template triggers a new rollout on its own:
#   kubectl -n bf-authz patch deploy frontend --type=json \
#     -p='[{"op":"remove","path":"/spec/template/metadata/labels/sidecar.istio.io~1inject"}]'
#   kubectl -n bf-authz rollout status deploy/frontend
#   kubectl -n bf-authz get pods -l app=frontend
#     frontend-...   2/2   Running   <-- now it is in the mesh
#
#   Do NOT "fix" it by setting the PeerAuthentication to PERMISSIVE: that lets
#   any pod without an identity in, including the "outsider".
#
# -----------------------------------------------------------------------------
# STEP 2 - Authorization: the next layer shows up
# -----------------------------------------------------------------------------
#   kubectl -n bf-authz exec deploy/frontend -c curl -- curl -sS http://httpbin:8000/get
#     RBAC: access denied
#
#   TLS works now (you get an HTTP answer), so the caller IS authenticated.
#   What is its identity? Read the SAN of the certificate its sidecar received:
#   istioctl proxy-config secret deploy/frontend -n bf-authz -o json \
#     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
#     | base64 -d | openssl x509 -noout -ext subjectAltName
#     X509v3 Subject Alternative Name: critical
#         URI:spiffe://cluster.local/ns/bf-authz/sa/frontend
#
#   Now look at what the policy expects:
#   kubectl -n bf-authz get authorizationpolicy httpbin-allow-frontend \
#     -o jsonpath='{.spec.rules[0].from[0].source.principals}'; echo
#     ["cluster.local/ns/bf-authz/sa/front-end"]      <-- "front-end" != "frontend"
#
#   Confirm it from the enforcement point (the server's Envoy):
#   istioctl proxy-config log deploy/httpbin -n bf-authz --level rbac:debug
#   kubectl -n bf-authz exec deploy/frontend -c curl -- curl -s http://httpbin:8000/get >/dev/null
#   kubectl -n bf-authz logs deploy/httpbin -c istio-proxy --tail=20 | grep -i rbac
#     ... enforced denied, matched policy none
#   (With debug on you will also see the connection's peer principal,
#    ending in "/sa/frontend".)
#
#   Optional: list the policies that apply to the server pod:
#   istioctl x authz check deploy/httpbin -n bf-authz
#
#   Remember: principals are "<trust-domain>/ns/<namespace>/sa/<serviceaccount>",
#   WITHOUT the "spiffe://" prefix, and they are an exact string match
#   (only a "*" prefix or suffix is allowed as a wildcard).
#
#   FIX 2 - correct the principal:
#   kubectl -n bf-authz patch authorizationpolicy httpbin-allow-frontend --type=json \
#     -p='[{"op":"replace","path":"/spec/rules/0/from/0/source/principals/0","value":"cluster.local/ns/bf-authz/sa/frontend"}]'
#   (If your mesh uses a trust domain other than cluster.local, use that one;
#    the script printed it as "Detected trust domain".)
#
#   Or declaratively (the version to keep in Git):
#     apiVersion: security.istio.io/v1
#     kind: AuthorizationPolicy
#     metadata:
#       name: httpbin-allow-frontend
#       namespace: bf-authz
#     spec:
#       selector:
#         matchLabels:
#           app: httpbin
#       action: ALLOW
#       rules:
#         - from:
#             - source:
#                 principals:
#                   - "cluster.local/ns/bf-authz/sa/frontend"
#           to:
#             - operation:
#                 methods: ["GET"]
#                 paths: ["/get", "/headers"]
#
#   Do NOT "fix" it with principals: ["*"] or namespaces: ["bf-authz"]:
#   "intruder" runs in the same namespace and would get access.
#
# -----------------------------------------------------------------------------
# STEP 3 - Verify all layers at once
# -----------------------------------------------------------------------------
#   kubectl -n bf-authz exec deploy/frontend -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/get
#     200
#   kubectl -n bf-authz exec deploy/frontend -c curl -- curl -s -o /dev/null -w '%{http_code}\n' -X POST http://httpbin:8000/post
#     403
#   kubectl -n bf-authz exec deploy/intruder -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/get
#     403
#   kubectl -n bf-authz-outside exec deploy/outsider -c curl -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://httpbin.bf-authz:8000/get
#     000
#
#   Restore the Envoy log level:
#   istioctl proxy-config log deploy/httpbin -n bf-authz --level rbac:warning
#
#   ./ckne-4.4-break-fix.sh check      -> SOLVED: 7/7 checks.
#   ./ckne-4.4-break-fix.sh cleanup
#
# -----------------------------------------------------------------------------
# TAKEAWAYS FOR THE EXAM
# -----------------------------------------------------------------------------
#   * Identity = ServiceAccount. Changing a pod's serviceAccountName changes its
#     SPIFFE ID, and every AuthorizationPolicy that names it has to change too.
#   * source.principals and source.namespaces only work with mTLS: without
#     a sidecar or with mTLS disabled, the principal is empty and never matches.
#   * Connection reset/000 = authentication (mTLS). 403 RBAC: access denied =
#     authorization. Fix them in that order: the first one hides the second.
#   * An ALLOW policy turns the workload into deny-by-default for anything it
#     does not list. An empty "spec: {}" policy denies everything; a rule "{}"
#     allows everything.
#   * Evaluation order: CUSTOM -> DENY -> ALLOW. One DENY match wins over any ALLOW.
#   * Policies in the root namespace (istio-system by default) apply to the whole mesh:
#     check them with kubectl get authorizationpolicy -A when the behavior makes no sense.
# =============================================================================