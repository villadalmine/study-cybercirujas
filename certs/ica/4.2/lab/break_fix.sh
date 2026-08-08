#!/usr/bin/env bash
#
# ==============================================================================
#  ICA — Istio Certified Associate
#  Domain 4.2  ·  Configuring Authentication (mTLS, JWT)   ·  exam weight: 8
# ==============================================================================
#
#  BREAK & FIX LAB  —  run ONLY on a disposable Istio lab VM / throwaway cluster.
#
#  This script builds a small, self-contained authentication stack inside a
#  dedicated namespace and then introduces ONE controlled, reversible fault in
#  the JWT origin-authentication configuration. Everything it creates is
#  namespace-scoped: it never touches the mesh-wide MeshConfig, the root CA, or
#  any workload outside the lab namespace. Tear the whole thing down with the
#  'cleanup' subcommand.
#
#  What you are practising
#  -----------------------
#  Istio splits "who is the caller" into two independent planes, and 4.2 wants
#  you fluent in both:
#
#    * PEER authentication  (service-to-service)  -> PeerAuthentication + mTLS.
#      The sidecars present X.509 SVIDs to each other; STRICT mode refuses any
#      plaintext. This is transport identity.
#
#    * REQUEST authentication (end-user)          -> RequestAuthentication (JWT)
#      + AuthorizationPolicy. The receiving sidecar validates the bearer token
#      against a configured issuer + JWKS, then policy decides access. This is
#      end-user identity, layered ON TOP of mTLS.
#
#  In this lab mTLS is STRICT and healthy. The fault is planted in the JWT
#  layer, because that is where most exam-day and production incidents actually
#  live: a token that "looks valid" is rejected for a reason that is invisible
#  unless you compare the token's claims against the policy.
#
#  Reference sources (official):
#    - Security concepts .......... https://istio.io/latest/docs/concepts/security/
#    - Authentication policies task https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
#    - PeerAuthentication ref ...... https://istio.io/latest/docs/reference/config/security/peer_authentication/
#    - RequestAuthentication ref ... https://istio.io/latest/docs/reference/config/security/request_authentication/
#    - AuthorizationPolicy ref ..... https://istio.io/latest/docs/reference/config/security/authorization-policy/
#    - Demo JWT / JWKS samples ..... https://github.com/istio/istio/tree/master/security/tools/jwt/samples
#
#  Usage:
#     ./ica-4.2-mtls-jwt-breakfix.sh setup     # build stack, verify, then BREAK
#     ./ica-4.2-mtls-jwt-breakfix.sh verify     # re-run the probes any time
#     ./ica-4.2-mtls-jwt-breakfix.sh cleanup    # delete the lab namespace
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
NS="ica-lab-42"
ISTIO_REL="release-1.23"   # branch that hosts the demo JWT + JWKS sample assets
JWT_BASE="https://raw.githubusercontent.com/istio/istio/${ISTIO_REL}/security/tools/jwt/samples"
DEMO_JWT_URL="${JWT_BASE}/demo.jwt"
JWKS_URI="${JWT_BASE}/jwks.json"

RIGHT_ISSUER="testing@secure.istio.io"     # the real 'iss' claim inside demo.jwt
WRONG_ISSUER="testing@insecure.istio.io"   # the planted typo:  secure -> insecure

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; CYA=$'\033[0;36m'; NC=$'\033[0m'

log()  { printf '%s[ica-lab]%s %s\n' "$CYA" "$NC" "$*"; }
warn() { printf '%s[ica-lab]%s %s\n' "$YEL" "$NC" "$*"; }
die()  { printf '%s[ica-lab] FATAL:%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preflight — refuse to run without the tools and a real Istio control plane
# ------------------------------------------------------------------------------
preflight() {
  command -v kubectl  >/dev/null 2>&1 || die "kubectl not found in PATH."
  command -v istioctl >/dev/null 2>&1 || warn "istioctl not found — diagnostics will be limited (kubectl still works)."
  command -v curl     >/dev/null 2>&1 || die "curl not found in PATH (needed to fetch the demo token)."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster. Point KUBECONFIG at your disposable lab VM."
  kubectl get ns istio-system >/dev/null 2>&1 \
    || die "Namespace 'istio-system' is missing — Istio does not appear to be installed on this cluster."
  log "Preflight OK — talking to: $(kubectl config current-context)"
}

# ------------------------------------------------------------------------------
# Deploy the baseline (all healthy): STRICT mTLS + valid JWT origin-auth
# ------------------------------------------------------------------------------
deploy() {
  log "Creating namespace '${NS}' with automatic sidecar injection..."
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "${NS}" istio-injection=enabled --overwrite >/dev/null

  log "Deploying workloads: 'httpbin' (protected server) and 'client' (caller)..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: ${NS}
  labels: { app: httpbin }
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector: { app: httpbin }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: ${NS}
spec:
  replicas: 1
  selector: { matchLabels: { app: httpbin } }
  template:
    metadata:
      labels: { app: httpbin }
    spec:
      containers:
      - name: httpbin
        image: docker.io/kennethreitz/httpbin
        ports: [ { containerPort: 80 } ]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: ${NS}
spec:
  replicas: 1
  selector: { matchLabels: { app: client } }
  template:
    metadata:
      labels: { app: client }
    spec:
      containers:
      - name: curl
        image: curlimages/curl
        command: [ "sleep", "infinity" ]
EOF

  log "Waiting for workloads (and their sidecars) to become ready..."
  kubectl -n "${NS}" rollout status deploy/httpbin --timeout=120s >/dev/null
  kubectl -n "${NS}" rollout status deploy/client  --timeout=120s >/dev/null

  log "Applying PEER authentication: STRICT mTLS across the namespace..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ${NS}
spec:
  mtls:
    mode: STRICT
EOF

  log "Applying REQUEST authentication (JWT) with the CORRECT issuer..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-httpbin
  namespace: ${NS}
spec:
  selector:
    matchLabels: { app: httpbin }
  jwtRules:
  - issuer: "${RIGHT_ISSUER}"
    jwksUri: "${JWKS_URI}"
EOF

  log "Applying AuthorizationPolicy: require ANY valid end-user principal..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: ${NS}
spec:
  selector:
    matchLabels: { app: httpbin }
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["*"]
EOF

  # Let the sidecars pull the JWKS and the policies converge.
  sleep 8
}

# ------------------------------------------------------------------------------
# Probe helpers — all traffic flows client-sidecar --mTLS--> httpbin-sidecar
# ------------------------------------------------------------------------------
client_pod() { kubectl -n "${NS}" get pod -l app=client -o jsonpath='{.items[0].metadata.name}'; }

fetch_token() {
  local t; t="$(curl -fsSL "${DEMO_JWT_URL}" | tr -d '[:space:]')" || die "Could not fetch demo JWT from ${DEMO_JWT_URL}"
  [ -n "${t}" ] || die "Fetched an empty demo JWT."
  printf '%s' "${t}"
}

# HTTP status code only.
probe_code() { # $1 = "none" | "<token>"
  local pod token; pod="$(client_pod)"; token="${1:-none}"
  if [ "${token}" = "none" ]; then
    kubectl -n "${NS}" exec "${pod}" -c curl -- \
      curl -s -o /dev/null -w '%{http_code}' "http://httpbin:8000/headers" 2>/dev/null || echo "ERR"
  else
    kubectl -n "${NS}" exec "${pod}" -c curl -- \
      curl -s -o /dev/null -w '%{http_code}' "http://httpbin:8000/headers" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || echo "ERR"
  fi
}

# Response body (used to reveal the Envoy JWT filter's rejection message).
probe_body() { # $1 = token
  local pod; pod="$(client_pod)"
  kubectl -n "${NS}" exec "${pod}" -c curl -- \
    curl -s "http://httpbin:8000/headers" -H "Authorization: Bearer ${1}" 2>/dev/null || true
}

verify() {
  local token; token="$(fetch_token)"
  log "Probing httpbin from the client pod ..."
  local c_none c_valid; c_none="$(probe_code none)"; c_valid="$(probe_code "${token}")"
  printf '   %-38s -> HTTP %s\n' "request WITHOUT a token" "${c_none}"
  printf '   %-38s -> HTTP %s\n' "request WITH the valid demo JWT" "${c_valid}"
  if [ "${c_valid}" != "200" ]; then
    printf '   %sserver said:%s %s\n' "$YEL" "$NC" "$(probe_body "${token}" | head -c 200)"
  fi
}

# ------------------------------------------------------------------------------
# THE CONTROLLED BREAK — mutate the JWT issuer to a value the token cannot match
# ------------------------------------------------------------------------------
break_it() {
  warn "Introducing the fault into RequestAuthentication/jwt-httpbin ..."
  kubectl -n "${NS}" patch requestauthentication jwt-httpbin --type merge -p \
    "{\"spec\":{\"jwtRules\":[{\"issuer\":\"${WRONG_ISSUER}\",\"jwksUri\":\"${JWKS_URI}\"}]}}" >/dev/null
  sleep 6
}

# ------------------------------------------------------------------------------
# Orchestration
# ------------------------------------------------------------------------------
cmd_setup() {
  preflight
  deploy

  echo
  log "${GRN}BASELINE (everything healthy) — expected: no-token 403, valid-token 200${NC}"
  verify

  break_it

  cat <<BRIEF

${RED}================================  FAULT INJECTED  ================================${NC}

  The lab is now broken. Here is your situation.

  ${YEL}SYMPTOM${NC}
  ------------------------------------------------------------------------------
  A request that carries the *known-good* Istio demo JWT — a token that has NOT
  changed and is NOT expired — is suddenly rejected. Reproduce it:

      POD=\$(kubectl -n ${NS} get pod -l app=client -o jsonpath='{.items[0].metadata.name}')
      TOKEN=\$(curl -sL ${DEMO_JWT_URL} | tr -d '[:space:]')

      kubectl -n ${NS} exec \$POD -c curl -- \\
        curl -s -w '\\nHTTP %{http_code}\\n' http://httpbin:8000/headers \\
        -H "Authorization: Bearer \$TOKEN"

  You will see:  HTTP ${RED}401${NC}  with body:  ${RED}Jwt issuer is not configured${NC}

  Meanwhile a request WITHOUT any token still returns 403 (the AuthorizationPolicy
  is fine), and mTLS is still STRICT and healthy. So peer auth is NOT the problem —
  the fault is purely in the end-user (JWT) authentication layer.

  ${YEL}YOUR GOAL${NC}
  ------------------------------------------------------------------------------
  Restore correct behaviour, WITHOUT weakening security:

      * request WITH the valid demo JWT   ->  HTTP 200
      * request WITHOUT a token           ->  HTTP 403  (must stay denied)
      * mTLS stays in STRICT mode         ->  do not touch PeerAuthentication

  ${YEL}HINTS — the diagnostic ladder for 4.2${NC}
  ------------------------------------------------------------------------------
  1. The message "Jwt issuer is not configured" comes from the Envoy JWT filter:
     it received a token whose 'iss' claim matches NONE of the configured issuers.

  2. Read what the token actually claims. A JWT is three base64url parts; decode
     the middle (payload) one:

        echo "\$TOKEN" | cut -d. -f2 | tr '_-' '/+' | \\
          awk '{ while(length%4)\$0=\$0"="; print }' | base64 -d 2>/dev/null; echo

     Look at the "iss" field. That is the identity the token was signed for.

  3. Read what the mesh is configured to trust:

        kubectl -n ${NS} get requestauthentication jwt-httpbin \\
          -o jsonpath='{.spec.jwtRules[0].issuer}{"\\n"}'

  4. Compare (2) and (3) character by character. They must be byte-for-byte equal.
     Also confirm mTLS is genuinely up (peer auth is a red herring here):

        istioctl authz check deploy/httpbin -n ${NS}     # end-user auth view
        kubectl -n ${NS} get peerauthentication default -o yaml | grep -A2 mtls

  When both a valid token yields 200 AND a no-token request yields 403, you win.
  Re-check any time with:   ${CYA}$0 verify${NC}
  Tear the lab down with:   ${CYA}$0 cleanup${NC}

${RED}=================================================================================${NC}
BRIEF
}

cmd_verify() { preflight; verify; }

cmd_cleanup() {
  preflight
  warn "Deleting lab namespace '${NS}' and everything in it ..."
  kubectl delete namespace "${NS}" --ignore-not-found >/dev/null
  log "Done. The lab is gone."
}

case "${1:-setup}" in
  setup)   cmd_setup   ;;
  verify)  cmd_verify  ;;
  cleanup) cmd_cleanup ;;
  *) die "Unknown subcommand '${1}'. Use: setup | verify | cleanup" ;;
esac

# ==============================================================================
#  SOLUTION  —  step by step (read only after you have tried it yourself)
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  The break patched RequestAuthentication/jwt-httpbin so that its jwtRules[0].issuer
#  became "testing@insecure.istio.io" (secure -> insecure), while the JWKS URI and
#  the token itself were left untouched. The Istio demo token (demo.jwt) is signed
#  with the claim  iss = "testing@secure.istio.io".
#
#  Envoy's JWT filter matches an incoming token to a jwtRule by its 'iss' claim.
#  With no rule whose issuer equals "testing@secure.istio.io", the token matches
#  nothing, so the filter rejects it outright with HTTP 401 and the body
#  "Jwt issuer is not configured". This happens BEFORE the AuthorizationPolicy is
#  even consulted — which is why a *valid* token fails while a *no-token* request
#  is still cleanly 403'd by the policy. Nothing is wrong with mTLS or with authz;
#  the defect is a single mismatched string in the request-authentication rule.
#
#  STEP 1 — Reproduce and read the token's real issuer.
#     POD=$(kubectl -n ica-lab-42 get pod -l app=client -o jsonpath='{.items[0].metadata.name}')
#     TOKEN=$(curl -sL https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/demo.jwt | tr -d '[:space:]')
#     echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | awk '{ while(length%4)$0=$0"="; print }' | base64 -d; echo
#        -> {"exp":..., "iat":..., "iss":"testing@secure.istio.io", "sub":"testing@secure.istio.io", ...}
#
#  STEP 2 — Read what the mesh trusts, and confirm the mismatch.
#     kubectl -n ica-lab-42 get requestauthentication jwt-httpbin -o jsonpath='{.spec.jwtRules[0].issuer}{"\n"}'
#        -> testing@insecure.istio.io          # <-- does NOT equal the token's iss
#
#  STEP 3 — Fix the issuer back to the exact value the token carries. Keep the
#           JWKS URI as-is; keep the selector as-is; do NOT touch mTLS or authz.
#     kubectl -n ica-lab-42 patch requestauthentication jwt-httpbin --type merge -p \
#       '{"spec":{"jwtRules":[{"issuer":"testing@secure.istio.io","jwksUri":"https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/jwks.json"}]}}'
#
#     (Equivalent declarative form — apply this manifest instead:)
#        apiVersion: security.istio.io/v1
#        kind: RequestAuthentication
#        metadata: { name: jwt-httpbin, namespace: ica-lab-42 }
#        spec:
#          selector: { matchLabels: { app: httpbin } }
#          jwtRules:
#          - issuer: "testing@secure.istio.io"
#            jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/jwks.json"
#
#  STEP 4 — Give the sidecars a few seconds to converge, then verify the contract.
#     sleep 6
#     # valid token -> must be 200
#     kubectl -n ica-lab-42 exec "$POD" -c curl -- \
#       curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/headers -H "Authorization: Bearer $TOKEN"
#        -> 200
#     # no token -> must STILL be 403 (proves you did not weaken authz to "fix" it)
#     kubectl -n ica-lab-42 exec "$POD" -c curl -- \
#       curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/headers
#        -> 403
#     # mTLS still STRICT (unchanged the whole time)
#     kubectl -n ica-lab-42 get peerauthentication default -o jsonpath='{.spec.mtls.mode}{"\n"}'
#        -> STRICT
#
#  ANTI-PATTERN — what NOT to do
#  -----------------------------
#  Do NOT "fix" the 401 by deleting the RequestAuthentication or by loosening the
#  AuthorizationPolicy (e.g. adding a blanket allow / removing requestPrincipals).
#  That turns a rejected-good-token into an accept-everything endpoint: the no-token
#  request would then return 200 and you would have removed end-user authentication
#  entirely. The correct fix touches exactly one field: the issuer string.
#
#  TAKEAWAY for ICA 4.2
#  --------------------
#  RequestAuthentication only *validates* tokens; it never *requires* them — the
#  requirement comes from AuthorizationPolicy (requestPrincipals). A JWT is matched
#  to its rule strictly by the 'iss' claim, so the configured issuer must equal the
#  token's iss byte-for-byte; a mismatch yields 401 "Jwt issuer is not configured",
#  which is a configuration bug, not a bad token. Peer (mTLS) and request (JWT)
#  authentication are independent layers: verify each on its own axis
#  (istioctl authz check, PeerAuthentication mode) before assuming they interact.
# ==============================================================================