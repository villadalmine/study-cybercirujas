#!/usr/bin/env bash
# =============================================================================
# CKNE 4.3 - Managing TLS Certificates for Gateway API
# Break & Fix lab: "The HTTPS listener that never served a byte"
# =============================================================================
#
# WHAT THIS SCRIPT DOES
#   It builds a small, self-contained Gateway API setup on a DISPOSABLE lab
#   cluster (kind, k3d, minikube or a throwaway VM). Then it breaks TLS
#   termination on purpose, in two independent ways that stack on top of each
#   other:
#
#     * a failure the controller DOES report, in the Gateway status
#     * a failure the controller does NOT report: every status condition turns
#       green and clients still refuse the connection
#
#   The script touches only two namespaces it creates itself (tls-lab-app and
#   tls-lab-certs) and one local working directory. It does not change the
#   GatewayClass, the controller, the CRDs or any other namespace.
#
# SCENARIO
#   The platform team keeps every TLS Secret in the "tls-lab-certs" namespace.
#   Application teams must not be able to read those Secrets. The application
#   team owns the Gateway and the HTTPRoute in "tls-lab-app". They should serve
#   https://app.tls-lab.local with a certificate signed by the lab's internal
#   CA. The ticket says: "HTTPS is broken. Fix it, and keep the Secret where
#   the platform team put it."
#
# REQUIREMENTS
#   - kubectl pointing at a DISPOSABLE cluster
#   - Gateway API CRDs installed (standard channel: Gateway, HTTPRoute,
#     ReferenceGrant)
#   - a Gateway API implementation with an Accepted GatewayClass (Envoy
#     Gateway, Cilium, Istio, NGINX Gateway Fabric, Contour, ...)
#   - openssl, curl, base64
#
# USAGE
#   ./break-fix-4.3.sh break     # build the scenario and break it (default)
#   ./break-fix-4.3.sh hint      # progressive hints, without spoilers
#   ./break-fix-4.3.sh check     # verify your fix
#   ./break-fix-4.3.sh cleanup   # remove everything the lab created
#
# ENVIRONMENT OVERRIDES
#   GATEWAY_CLASS=<name>   use this GatewayClass instead of auto-detecting one
#   LAB_DIR=<path>         working directory for keys and certs
#                          (default: ~/tls-lab-4.3)
#   FORCE=1                skip the "is this a lab cluster?" safety check
#
# REFERENCES (official)
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://gateway-api.sigs.k8s.io/guides/tls/
#   https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/
#   https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/#gatewaytlsconfig
#   https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets
# =============================================================================

set -euo pipefail

APP_NS="tls-lab-app"
CERT_NS="tls-lab-certs"
GW_NAME="tls-lab-gw"
ROUTE_NAME="app-route"
SECRET_NAME="app-tls"
HOST="app.tls-lab.local"
WRONG_HOST="app.wrong.lab.local"
BACKEND_IMAGE="${BACKEND_IMAGE:-registry.k8s.io/e2e-test-images/agnhost:2.52}"
LAB_DIR="${LAB_DIR:-$HOME/tls-lab-4.3}"
LAB_LABEL="teach-plat/lab=ckne-4.3"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; BLD=$'\033[1m'; RST=$'\033[0m'

info() { printf '%s[INFO]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
die()  { fail "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
require_tools() {
  local t
  for t in kubectl openssl curl base64; do
    command -v "$t" >/dev/null 2>&1 || die "Required tool not found: $t"
  done
}

safety_check() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "kubectl has no current context."
  if [[ "${FORCE:-0}" != "1" ]]; then
    case "$ctx" in
      kind-*|k3d-*|minikube|*lab*|*sandbox*|*test*|default) : ;;
      *) die "Context '$ctx' does not look like a disposable lab cluster. Re-run with FORCE=1 if you are sure." ;;
    esac
  fi
  kubectl version --request-timeout=5s >/dev/null 2>&1 || die "Cannot reach the API server for context '$ctx'."
  info "Using kubectl context: ${BLD}${ctx}${RST}"
}

require_gateway_api() {
  local crd
  for crd in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io; do
    kubectl get crd "$crd" >/dev/null 2>&1 || die "CRD $crd not found. Install the Gateway API standard channel CRDs first: https://gateway-api.sigs.k8s.io/guides/#installing-gateway-api"
  done
}

detect_gateway_class() {
  if [[ -n "${GATEWAY_CLASS:-}" ]]; then
    kubectl get gatewayclass "$GATEWAY_CLASS" >/dev/null 2>&1 || die "GatewayClass '$GATEWAY_CLASS' does not exist."
    echo "$GATEWAY_CLASS"; return
  fi
  local gc status
  for gc in $(kubectl get gatewayclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    status="$(kubectl get gatewayclass "$gc" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then echo "$gc"; return; fi
  done
  die "No Accepted GatewayClass found. Install a Gateway API implementation (for example Envoy Gateway: https://gateway.envoyproxy.io/docs/tasks/quickstart/) or set GATEWAY_CLASS=<name>."
}

# -----------------------------------------------------------------------------
# PKI helpers (local lab CA)
# -----------------------------------------------------------------------------
make_ca() {
  mkdir -p "$LAB_DIR"
  chmod 700 "$LAB_DIR"
  cat > "$LAB_DIR/ca.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no

[ dn ]
CN = TLS Lab Internal CA

[ v3_ca ]
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
EOF
  openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 30 \
    -keyout "$LAB_DIR/ca.key" -out "$LAB_DIR/ca.crt" \
    -config "$LAB_DIR/ca.cnf" >/dev/null 2>&1
  chmod 600 "$LAB_DIR/ca.key"
}

# issue_server_cert <dns-name> <output-prefix>
issue_server_cert() {
  local dns="$1" out="$2"
  cat > "$LAB_DIR/${out}.ext" <<EOF
basicConstraints       = CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = DNS:${dns}
authorityKeyIdentifier = keyid
EOF
  openssl req -new -nodes -newkey rsa:2048 -sha256 \
    -keyout "$LAB_DIR/${out}.key" -out "$LAB_DIR/${out}.csr" \
    -subj "/CN=${dns}" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 30 \
    -in "$LAB_DIR/${out}.csr" \
    -CA "$LAB_DIR/ca.crt" -CAkey "$LAB_DIR/ca.key" -CAcreateserial \
    -extfile "$LAB_DIR/${out}.ext" \
    -out "$LAB_DIR/${out}.crt" >/dev/null 2>&1
  chmod 600 "$LAB_DIR/${out}.key"
}

# -----------------------------------------------------------------------------
# Status helpers
# -----------------------------------------------------------------------------
listener_cond() {
  # listener_cond <conditionType> <field: status|reason|message>
  kubectl -n "$APP_NS" get gateway "$GW_NAME" \
    -o jsonpath="{.status.listeners[?(@.name==\"https\")].conditions[?(@.type==\"$1\")].$2}" 2>/dev/null || true
}

gateway_address() {
  kubectl -n "$APP_NS" get gateway "$GW_NAME" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

# Finds the Service the implementation created for this Gateway. Labels
# differ between implementations, so try the common ones.
find_gateway_service() {
  local sel line
  for sel in \
    "gateway.networking.k8s.io/gateway-name=${GW_NAME}" \
    "gateway.envoyproxy.io/owning-gateway-name=${GW_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${APP_NS}" \
    "io.cilium.gateway/owning-gateway=${GW_NAME}"; do
    line="$(kubectl get svc -A -l "$sel" -o jsonpath='{range .items[0]}{.metadata.namespace} {.metadata.name}{end}' 2>/dev/null || true)"
    if [[ -n "$line" ]]; then echo "$line"; return; fi
  done
}

wait_for_listener_status() {
  local i s
  for i in $(seq 1 30); do
    s="$(listener_cond ResolvedRefs status)"
    [[ -n "$s" ]] && return 0
    sleep 2
  done
  return 1
}

# Runs an HTTPS request against the Gateway through whichever path is
# available: the Gateway address first, then a port-forward to its Service.
# Prints curl's output and returns curl's exit code.
https_probe() {
  local addr svc svc_ns svc_name pf_pid rc=0 out
  addr="$(gateway_address)"
  if [[ -n "$addr" ]]; then
    if [[ "$addr" =~ ^[0-9.]+$ ]]; then
      out="$(curl -sS --max-time 6 --cacert "$LAB_DIR/ca.crt" \
        --resolve "${HOST}:443:${addr}" "https://${HOST}/hostname" 2>&1)" || rc=$?
    else
      out="$(curl -sS --max-time 6 --cacert "$LAB_DIR/ca.crt" \
        --connect-to "${HOST}:443:${addr}:443" "https://${HOST}/hostname" 2>&1)" || rc=$?
    fi
    echo "$out"; return "$rc"
  fi
  svc="$(find_gateway_service)"
  if [[ -z "$svc" ]]; then
    echo "NO_PATH: no Gateway address and no Service found for the Gateway"
    return 99
  fi
  svc_ns="${svc%% *}"; svc_name="${svc##* }"
  kubectl -n "$svc_ns" port-forward "svc/${svc_name}" 18443:443 >/dev/null 2>&1 &
  pf_pid=$!
  sleep 3
  out="$(curl -sS --max-time 6 --cacert "$LAB_DIR/ca.crt" \
    --resolve "${HOST}:18443:127.0.0.1" "https://${HOST}:18443/hostname" 2>&1)" || rc=$?
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
  echo "$out"; return "$rc"
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  require_tools
  safety_check
  require_gateway_api
  local gc
  gc="$(detect_gateway_class)"
  info "Using GatewayClass: ${BLD}${gc}${RST}"

  if kubectl get ns "$APP_NS" >/dev/null 2>&1 || kubectl get ns "$CERT_NS" >/dev/null 2>&1; then
    die "Lab namespaces already exist. Run '$0 cleanup' first for a fresh start."
  fi

  info "Creating the lab CA and a server certificate in $LAB_DIR ..."
  rm -rf "$LAB_DIR"
  make_ca
  # Fault #2 (silent): the platform team issued the certificate for the
  # wrong name. The controller never inspects SANs, so this does not show
  # up in any status condition.
  issue_server_cert "$WRONG_HOST" "issued"

  info "Creating namespaces ..."
  kubectl create namespace "$APP_NS" >/dev/null
  kubectl create namespace "$CERT_NS" >/dev/null
  kubectl label namespace "$APP_NS" "$LAB_LABEL" >/dev/null
  kubectl label namespace "$CERT_NS" "$LAB_LABEL" >/dev/null

  info "Storing the TLS Secret in the platform namespace ($CERT_NS) ..."
  kubectl -n "$CERT_NS" create secret tls "$SECRET_NAME" \
    --cert="$LAB_DIR/issued.crt" --key="$LAB_DIR/issued.key" >/dev/null

  info "Deploying the backend ..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: ${APP_NS}
  labels:
    app: app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      containers:
        - name: netexec
          image: ${BACKEND_IMAGE}
          args:
            - netexec
            - --http-port=8080
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
---
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: ${APP_NS}
spec:
  selector:
    app: app
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

  # Fault #1 (reported): the Gateway references a Secret in another
  # namespace, and nobody created the ReferenceGrant that allows it.
  info "Creating the Gateway and the HTTPRoute ..."
  kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${APP_NS}
spec:
  gatewayClassName: ${gc}
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "${HOST}"
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
            name: ${SECRET_NAME}
            namespace: ${CERT_NS}
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${ROUTE_NAME}
  namespace: ${APP_NS}
spec:
  parentRefs:
    - name: ${GW_NAME}
      sectionName: https
  hostnames:
    - "${HOST}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: app
          port: 80
EOF

  info "Waiting for the controller to reconcile the listener ..."
  wait_for_listener_status || warn "The controller has not written listener status yet. Check that it is running."
  kubectl -n "$APP_NS" rollout status deploy/app --timeout=120s >/dev/null 2>&1 || warn "Backend not ready yet (image pull?)."

  cat <<EOF

${BLD}================================================================${RST}
${BLD} LAB READY - CKNE 4.3: Managing TLS Certificates for Gateway API${RST}
${BLD}================================================================${RST}

${BLD}Ticket #4312 (priority: high)${RST}
  "https://${HOST} does not work. The app team says the Gateway is
   configured. The platform team says the certificate is in its
   namespace. Fix it."

${BLD}What you will see${RST}
  * kubectl -n ${APP_NS} get gateway ${GW_NAME}
      PROGRAMMED will not be True, or the https listener will report
      attachedRoutes but refuse to serve.
  * kubectl -n ${APP_NS} describe gateway ${GW_NAME}
      Read the conditions of listener "https", not only the top-level
      conditions of the Gateway.
  * Once the reported problem is gone, a client that trusts the lab CA
    (${LAB_DIR}/ca.crt) will STILL fail the TLS handshake, while
    every condition in the status looks healthy.

${BLD}Constraints (what the platform team will accept)${RST}
  1. The Secret ${SECRET_NAME} STAYS in namespace ${CERT_NS}. Do not copy
     it into ${APP_NS}.
  2. Grant access to the SMALLEST scope that works: only Gateways from
     ${APP_NS}, and only this Secret.
  3. The certificate must be signed by the lab CA (${LAB_DIR}/ca.key,
     ${LAB_DIR}/ca.crt) and valid for ${HOST}.
  4. Do not recreate the Gateway. Rotate the certificate in place.

${BLD}Goal${RST}
  curl --cacert ${LAB_DIR}/ca.crt https://${HOST}/hostname
  returns the backend pod name, with no -k / --insecure.

${BLD}Commands${RST}
  $0 hint      progressive hints
  $0 check     verify your fix
  $0 cleanup   remove the lab

EOF
  info "Current listener status: ResolvedRefs=$(listener_cond ResolvedRefs status) reason=$(listener_cond ResolvedRefs reason)"
}

# -----------------------------------------------------------------------------
# HINTS
# -----------------------------------------------------------------------------
do_hint() {
  cat <<EOF
${BLD}Hint 1${RST}  Gateway status has two levels. Look at
        .status.listeners[?(@.name=="https")].conditions
        What does the ResolvedRefs condition report as its reason?

${BLD}Hint 2${RST}  Gateway API blocks cross-namespace references by default. The
        OWNER of the target (the namespace holding the Secret) has to opt
        in, with an object that lives in that namespace.

${BLD}Hint 3${RST}  After ResolvedRefs turns True, test with SNI and the lab CA:
        openssl s_client -connect <addr>:443 -servername ${HOST} \\
          -CAfile ${LAB_DIR}/ca.crt </dev/null 2>/dev/null \\
          | openssl x509 -noout -subject -ext subjectAltName
        Compare what the certificate says with the listener hostname.

${BLD}Hint 4${RST}  The controller checks that the Secret exists, is readable and is
        a valid kubernetes.io/tls keypair. It does NOT check that the SAN
        matches the listener hostname. That part is up to you.

${BLD}Hint 5${RST}  "kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -"
        updates a Secret in place. Most implementations pick up the new
        certificate without a restart.
EOF
}

# -----------------------------------------------------------------------------
# CHECK
# -----------------------------------------------------------------------------
do_check() {
  require_tools
  kubectl get ns "$APP_NS" >/dev/null 2>&1 || die "Lab not found. Run '$0 break' first."
  local pass=0 total=0 partial=0 v tmp

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  echo "${BLD}== Constraint checks ==${RST}"

  # 1. The Secret is still in the platform namespace, and no copy exists.
  total=$((total+1))
  v="$(kubectl -n "$APP_NS" get gateway "$GW_NAME" \
      -o jsonpath='{.spec.listeners[?(@.name=="https")].tls.certificateRefs[0].namespace}' 2>/dev/null || true)"
  if [[ "$v" == "$CERT_NS" ]] && ! kubectl -n "$APP_NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    ok "Listener still references ${CERT_NS}/${SECRET_NAME}, and no copy exists in ${APP_NS}."
    pass=$((pass+1))
  else
    fail "The Secret must stay in ${CERT_NS} and the listener must reference it there (found namespace='${v:-<empty>}')."
  fi

  # 2. A ReferenceGrant exists, and its scope is minimal.
  total=$((total+1))
  local rg_lines
  rg_lines="$(kubectl -n "$CERT_NS" get referencegrants \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .spec.from[*]}{.kind}/{.namespace},{end}{"|"}{range .spec.to[*]}{.kind}/{.name},{end}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "$rg_lines" ]]; then
    fail "No ReferenceGrant in ${CERT_NS}."
  elif grep -q "Gateway/${APP_NS}," <<<"$rg_lines"; then
    if grep -E "Gateway/${APP_NS}," <<<"$rg_lines" | grep -q "Secret/${SECRET_NAME},"; then
      ok "ReferenceGrant allows Gateway from ${APP_NS} -> Secret ${SECRET_NAME} only."
      pass=$((pass+1))
    else
      warn "A ReferenceGrant exists but allows ALL Secrets in ${CERT_NS}. Restrict it with spec.to[].name: ${SECRET_NAME}."
      partial=1
    fi
  else
    fail "ReferenceGrant(s) found, but none allow kind Gateway from namespace ${APP_NS}:"
    printf '        %s\n' "$rg_lines"
  fi

  echo "${BLD}== Controller view ==${RST}"

  # 3. Listener ResolvedRefs and Programmed.
  total=$((total+1))
  local rr rr_reason pg
  rr="$(listener_cond ResolvedRefs status)"; rr_reason="$(listener_cond ResolvedRefs reason)"
  pg="$(listener_cond Programmed status)"
  if [[ "$rr" == "True" && "$pg" == "True" ]]; then
    ok "Listener https: ResolvedRefs=True, Programmed=True."
    pass=$((pass+1))
  else
    fail "Listener https: ResolvedRefs=${rr:-?} (${rr_reason:-?}), Programmed=${pg:-?}."
  fi

  echo "${BLD}== Certificate content (what the controller does not check) ==${RST}"

  kubectl -n "$CERT_NS" get secret "$SECRET_NAME" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$tmp/tls.crt" 2>/dev/null || true
  kubectl -n "$CERT_NS" get secret "$SECRET_NAME" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > "$tmp/tls.key" 2>/dev/null || true

  # 4. SAN matches the listener hostname.
  total=$((total+1))
  local san
  san="$(openssl x509 -in "$tmp/tls.crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' || true)"
  if grep -qE "(^|,)DNS:${HOST//./\\.}(,|$)" <<<"$san"; then
    ok "Certificate SAN includes ${HOST} (${san})."
    pass=$((pass+1))
  else
    fail "Certificate SAN does not include ${HOST} (found: ${san:-<none>})."
  fi

  # 5. Signed by the lab CA, not expired, key matches.
  total=$((total+1))
  local chain_ok=0 key_ok=0 time_ok=0
  openssl verify -CAfile "$LAB_DIR/ca.crt" "$tmp/tls.crt" >/dev/null 2>&1 && chain_ok=1
  openssl x509 -in "$tmp/tls.crt" -noout -checkend 0 >/dev/null 2>&1 && time_ok=1
  if [[ "$(openssl x509 -in "$tmp/tls.crt" -noout -pubkey 2>/dev/null | openssl sha256)" == \
        "$(openssl pkey -in "$tmp/tls.key" -pubout 2>/dev/null | openssl sha256)" ]]; then
    key_ok=1
  fi
  if (( chain_ok && time_ok && key_ok )); then
    ok "Certificate chains to the lab CA, has not expired, and matches tls.key."
    pass=$((pass+1))
  else
    fail "Certificate checks: chains to lab CA=${chain_ok} not expired=${time_ok} key matches=${key_ok}."
  fi

  echo "${BLD}== End to end ==${RST}"

  # 6. Real TLS handshake + HTTP request, strict verification.
  total=$((total+1))
  local out rc=0
  out="$(https_probe)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    ok "curl --cacert ca.crt https://${HOST}/hostname -> ${out}"
    pass=$((pass+1))
  elif [[ $rc -eq 99 ]]; then
    warn "No network path to the Gateway (no address in status, no Service found)."
    warn "On kind, run cloud-provider-kind or MetalLB, or port-forward to the data plane Service yourself."
    partial=1
  else
    fail "HTTPS request failed (curl exit ${rc}): ${out}"
  fi

  echo
  if [[ $pass -eq $total ]]; then
    printf '%s%sRESULT: %d/%d - FIXED. Ticket #4312 can be closed.%s\n' "$GRN" "$BLD" "$pass" "$total" "$RST"
  elif [[ $partial -eq 1 && $pass -eq $((total-1)) ]]; then
    printf '%s%sRESULT: %d/%d - almost there, see the warnings.%s\n' "$YLW" "$BLD" "$pass" "$total" "$RST"
  else
    printf '%s%sRESULT: %d/%d - not fixed yet. Try: %s hint%s\n' "$RED" "$BLD" "$pass" "$total" "$0" "$RST"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------
do_cleanup() {
  require_tools
  safety_check
  local ns
  for ns in "$APP_NS" "$CERT_NS"; do
    if kubectl get ns "$ns" -o jsonpath='{.metadata.labels.teach-plat/lab}' 2>/dev/null | grep -q "ckne-4.3"; then
      info "Deleting namespace $ns ..."
      kubectl delete ns "$ns" --wait=false >/dev/null
    elif kubectl get ns "$ns" >/dev/null 2>&1; then
      warn "Namespace $ns exists but was not created by this lab (label missing); leaving it alone."
    fi
  done
  if [[ -d "$LAB_DIR" ]]; then
    info "Removing $LAB_DIR ..."
    rm -rf "$LAB_DIR"
  fi
  ok "Cleanup done."
}

case "${1:-break}" in
  break)   do_break ;;
  hint)    do_hint ;;
  check)   do_check ;;
  cleanup) do_cleanup ;;
  *) echo "Usage: $0 {break|hint|check|cleanup}"; exit 2 ;;
esac

# =============================================================================
# SOLUTION (spoilers - try it yourself first)
# =============================================================================
#
# --- Step 1: read the listener conditions, not only the Gateway conditions --
#
#   kubectl -n tls-lab-app get gateway tls-lab-gw \
#     -o jsonpath='{range .status.listeners[*]}{.name}{"\n"}{range .conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}{end}'
#
#   Typical output (the wording of the message depends on the implementation):
#
#     https
#       Accepted=True Accepted: ...
#       ResolvedRefs=False RefNotPermitted: certificateRef tls-lab-certs/app-tls
#                   is not permitted by any ReferenceGrant
#       Programmed=False Invalid: ...
#
#   RefNotPermitted means the reference points into another namespace and
#   the owner of that namespace did not allow it. The Gateway API spec
#   requires implementations to reject the reference in that case. This
#   is what stops any namespace from mounting any other namespace's
#   private keys.
#
# --- Step 2: grant the minimal access, from the namespace that owns the Secret
#
#   The ReferenceGrant lives in the TARGET namespace (tls-lab-certs). "from"
#   names who may reference; "to" names what they may reference. Setting
#   "name" limits the grant to this Secret only (constraint #2).
#
#   kubectl apply -f - <<'EOF'
#   apiVersion: gateway.networking.k8s.io/v1beta1
#   kind: ReferenceGrant
#   metadata:
#     name: allow-tls-lab-app-gateway
#     namespace: tls-lab-certs
#   spec:
#     from:
#       - group: gateway.networking.k8s.io
#         kind: Gateway
#         namespace: tls-lab-app
#     to:
#       - group: ""
#         kind: Secret
#         name: app-tls
#   EOF
#
#   Check that the controller now accepts it:
#
#   kubectl -n tls-lab-app get gateway tls-lab-gw \
#     -o jsonpath='{.status.listeners[?(@.name=="https")].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}'
#   # True
#
# --- Step 3: notice that "green" does not mean "working" -------------------
#
#   ADDR=$(kubectl -n tls-lab-app get gateway tls-lab-gw -o jsonpath='{.status.addresses[0].value}')
#   curl -v --cacert ~/tls-lab-4.3/ca.crt \
#     --resolve app.tls-lab.local:443:$ADDR https://app.tls-lab.local/hostname
#
#   Expected failure:
#     curl: (60) SSL: no alternative certificate subject name matches
#     target host name 'app.tls-lab.local'
#
#   (With no LoadBalancer address, port-forward to the data plane Service,
#    for example on Envoy Gateway:
#      kubectl -n envoy-gateway-system get svc \
#        -l gateway.envoyproxy.io/owning-gateway-name=tls-lab-gw
#      kubectl -n envoy-gateway-system port-forward svc/<name> 18443:443 &
#      curl --cacert ~/tls-lab-4.3/ca.crt \
#        --resolve app.tls-lab.local:18443:127.0.0.1 https://app.tls-lab.local:18443/hostname )
#
#   Inspect what the Gateway actually serves for that SNI:
#
#   openssl s_client -connect $ADDR:443 -servername app.tls-lab.local \
#     -CAfile ~/tls-lab-4.3/ca.crt </dev/null 2>/dev/null \
#     | openssl x509 -noout -subject -issuer -ext subjectAltName
#
#     subject=CN=app.wrong.lab.local
#     issuer=CN=TLS Lab Internal CA
#     X509v3 Subject Alternative Name:
#         DNS:app.wrong.lab.local
#
#   Or read it straight from the Secret:
#
#   kubectl -n tls-lab-certs get secret app-tls -o jsonpath='{.data.tls\.crt}' \
#     | base64 -d | openssl x509 -noout -subject -ext subjectAltName -enddate
#
#   Lesson: the controller checks that the Secret exists, is readable and
#   holds a parseable kubernetes.io/tls keypair. It does not compare the SAN
#   with listener.hostname. Clients match hostnames against the SAN only;
#   modern clients ignore the CN.
#
# --- Step 4: reissue the certificate with the right SAN, signed by the lab CA
#
#   cd ~/tls-lab-4.3
#   cat > app.ext <<'EOF'
#   basicConstraints       = CA:FALSE
#   keyUsage               = critical,digitalSignature,keyEncipherment
#   extendedKeyUsage       = serverAuth
#   subjectAltName         = DNS:app.tls-lab.local
#   authorityKeyIdentifier = keyid
#   EOF
#   openssl req -new -nodes -newkey rsa:2048 -sha256 \
#     -keyout app.key -out app.csr -subj "/CN=app.tls-lab.local"
#   openssl x509 -req -sha256 -days 30 -in app.csr \
#     -CA ca.crt -CAkey ca.key -CAcreateserial -extfile app.ext -out app.crt
#
#   Verify BEFORE uploading (cheap, and it catches most mistakes):
#   openssl verify -CAfile ca.crt app.crt                 # app.crt: OK
#   openssl x509 -in app.crt -noout -ext subjectAltName   # DNS:app.tls-lab.local
#   diff <(openssl x509 -in app.crt -noout -pubkey) \
#        <(openssl pkey -in app.key -pubout) && echo "key matches"
#
# --- Step 5: rotate the Secret in place (constraint #4) ---------------------
#
#   kubectl -n tls-lab-certs create secret tls app-tls \
#     --cert=app.crt --key=app.key --dry-run=client -o yaml \
#     | kubectl apply -f -
#
#   The Gateway, the listener and the ReferenceGrant do not change. The
#   implementation watches the Secret and reloads the certificate (Envoy
#   through SDS, for example), with no restart and no dropped connections.
#   In production, cert-manager does this same rotation for you: it writes
#   to the Secret referenced by certificateRefs. If it runs in another
#   namespace, the same ReferenceGrant rule applies.
#
# --- Step 6: verify end to end, strictly (no -k) ----------------------------
#
#   curl --cacert ~/tls-lab-4.3/ca.crt \
#     --resolve app.tls-lab.local:443:$ADDR https://app.tls-lab.local/hostname
#   # app-7c9d8f6b5-x2kqp
#
#   ./break-fix-4.3.sh check
#   # RESULT: 6/6 - FIXED. Ticket #4312 can be closed.
#
# --- Wrong fixes that the check rejects, and why ----------------------------
#
#   * Copying the Secret into tls-lab-app: the private key now lives where
#     the app team can read it, which defeats the separation that
#     ReferenceGrant exists to keep.
#   * A ReferenceGrant without "to[].name": it works, but every Gateway in
#     tls-lab-app can now use EVERY certificate in tls-lab-certs.
#   * A ReferenceGrant created in tls-lab-app: grants are only honored in
#     the namespace of the target, so nothing changes.
#   * Changing listener.hostname to app.wrong.lab.local: the status stays
#     green, but you broke the contract. Clients ask for app.tls-lab.local.
#   * Testing with curl -k: -k skips exactly the check that was failing.
# =============================================================================