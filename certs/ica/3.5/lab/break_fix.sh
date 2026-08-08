#!/usr/bin/env bash
#
# ica-3.5-break-and-fix.sh
#
# ICA (Istio Certified Associate) — Topic 3.5
# "Connecting In-Mesh Workloads to External Workloads and Services"
#
# WHAT THIS SCRIPT DOES
#   It performs a *controlled, namespace-scoped* break inside a throwaway lab
#   cluster/VM and then hands the console back to you so you can diagnose and
#   repair it. Nothing outside the lab namespace is touched: the break is a
#   single namespace-scoped `Sidecar` resource, so the blast radius is one
#   namespace and cleanup is one `kubectl delete`.
#
#   Scenario: an in-mesh client that could freely reach an external HTTP service
#   suddenly cannot. Your job is to restore egress *the Istio way* — by
#   declaring the external service in the mesh registry — not by disabling the
#   egress policy.
#
# REQUIREMENTS
#   - A DISPOSABLE lab cluster (kind/minikube/k3d on a scratch VM). Do not run
#     against anything you care about.
#   - Istio installed (any profile with the default injection webhook).
#   - kubectl and istioctl on PATH, both pointing at the lab cluster.
#   - Outbound Internet from the cluster nodes (we probe a real external host).
#
# USAGE
#   ./ica-3.5-break-and-fix.sh            # setup + break (asks for confirmation)
#   ASSUME_YES=1 ./ica-3.5-break-and-fix.sh   # non-interactive
#   ./ica-3.5-break-and-fix.sh --cleanup  # remove everything this script created
#
# The step-by-step SOLUTION is at the very bottom of this file, commented out.
# Try to solve it yourself before scrolling down.
#
# Reference: CNCF ICA Curriculum
#   https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
# Istio docs:
#   ServiceEntry ............ https://istio.io/latest/docs/reference/config/networking/service-entry/
#   Sidecar (egress policy) . https://istio.io/latest/docs/reference/config/networking/sidecar/
#   Accessing external svcs . https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NS="${NS:-ica-3-5-lab}"                 # dedicated lab namespace (safe to delete)
CLIENT="${CLIENT:-mesh-client}"         # in-mesh client Deployment name
EXT_HOST="${EXT_HOST:-httpbin.org}"     # external service we test egress against
EXT_PATH="${EXT_PATH:-/get}"            # a path that returns HTTP 200
ISTIO_NS="${ISTIO_NS:-istio-system}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; CYN=$'\033[0;36m'; RST=$'\033[0m'

info()  { printf '%s[i]%s %s\n' "$CYN" "$RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()   { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Safety guards
# ---------------------------------------------------------------------------
case "$NS" in
  ""|default|kube-system|kube-public|kube-node-lease|"$ISTIO_NS")
    die "Refusing to use protected namespace '$NS'. Set NS to a scratch namespace."
    ;;
esac

confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local ans
  read -r -p "$(printf '%s%s%s ' "$YEL" "$1 [y/N]" "$RST")" ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  command -v kubectl  >/dev/null 2>&1 || die "kubectl not found on PATH."
  command -v istioctl >/dev/null 2>&1 || die "istioctl not found on PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster."
  kubectl get ns "$ISTIO_NS" >/dev/null 2>&1 \
    || die "Namespace '$ISTIO_NS' not found — is Istio installed?"
  kubectl -n "$ISTIO_NS" get deploy istiod >/dev/null 2>&1 \
    || warn "istiod deployment not found in $ISTIO_NS; continuing anyway."
  ok "Preflight passed (kubectl + istioctl reach the lab cluster)."
}

# Run curl from *inside* the client's app container (traffic goes through the
# sidecar). Prints only the HTTP status code (000 = no HTTP response at all).
probe() {
  kubectl exec -n "$NS" "deploy/$CLIENT" -c "$CLIENT" -- \
    curl -sS -o /dev/null -m 8 -w '%{http_code}' \
    "http://${EXT_HOST}${EXT_PATH}" 2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
# Setup: injected namespace + in-mesh client
# ---------------------------------------------------------------------------
setup() {
  info "Creating lab namespace '$NS' with automatic sidecar injection..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

  info "Deploying in-mesh client '$CLIENT'..."
  cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CLIENT}
  namespace: ${NS}
  labels: { app: ${CLIENT} }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${CLIENT} } }
  template:
    metadata:
      labels: { app: ${CLIENT} }
    spec:
      containers:
        - name: ${CLIENT}
          image: curlimages/curl:8.11.1
          command: ["/bin/sh", "-c", "sleep infinity"]
          securityContext:
            runAsUser: 1000
            allowPrivilegeEscalation: false
YAML

  info "Waiting for the client (app + istio-proxy sidecar) to become ready..."
  kubectl -n "$NS" rollout status "deploy/$CLIENT" --timeout=150s

  # Confirm the sidecar was actually injected (2/2 containers).
  local containers
  containers=$(kubectl -n "$NS" get pod -l "app=$CLIENT" \
    -o jsonpath='{.items[0].spec.containers[*].name}')
  [[ "$containers" == *"istio-proxy"* ]] \
    || die "No istio-proxy sidecar on the client pod — injection is not working."
  ok "In-mesh client ready. Containers: $containers"
}

# ---------------------------------------------------------------------------
# Baseline: prove egress works before we break it
# ---------------------------------------------------------------------------
baseline() {
  info "Baseline egress test to http://${EXT_HOST}${EXT_PATH} ..."
  local code; code="$(probe)"
  if [[ "$code" == "200" ]]; then
    ok "Baseline OK — external service reachable (HTTP $code)."
  else
    warn "Expected HTTP 200 but got '$code'. Check node egress/DNS before breaking."
    confirm "Continue and break anyway?" || die "Aborted before breaking."
  fi
}

# ---------------------------------------------------------------------------
# THE BREAK: lock egress from this namespace to the mesh registry only.
# Namespace-scoped Sidecar => blast radius is exactly one namespace.
# ---------------------------------------------------------------------------
break_it() {
  confirm "Apply the controlled break to namespace '$NS'?" || die "Aborted."
  info "Applying namespace-scoped egress lockdown (outboundTrafficPolicy=REGISTRY_ONLY)..."
  cat <<YAML | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: ${NS}
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
YAML

  info "Giving istiod a moment to push the new config to the sidecar..."
  sleep 6

  local code; code="$(probe)"
  printf '\n'
  if [[ "$code" == "200" ]]; then
    warn "Still 200 — config may not have propagated yet. Re-run the probe:"
    warn "  kubectl exec -n $NS deploy/$CLIENT -c $CLIENT -- curl -s -o /dev/null -w '%{http_code}' http://${EXT_HOST}${EXT_PATH}"
  else
    ok "Break confirmed. External egress now returns HTTP '$code' (expected 502)."
  fi

  cat <<BRIEF

${RED}=============================================================${RST}
${RED}  BROKEN — ICA 3.5: external service is now unreachable${RST}
${RED}=============================================================${RST}

${YEL}SYMPTOM${RST}
  The in-mesh client used to reach ${EXT_HOST} and now it does not.
  From inside the pod you will see something like:

    \$ kubectl exec -n ${NS} deploy/${CLIENT} -c ${CLIENT} -- \\
        curl -sSv http://${EXT_HOST}${EXT_PATH}
    ...
    < HTTP/1.1 502 Bad Gateway
    upstream connect error or disconnect/reset before headers.
    reset reason: connection termination

  The 502 comes from the client's own istio-proxy, not from ${EXT_HOST}.

${YEL}DIAGNOSE${RST}  (recommended commands)
  # See where the sidecar is sending unknown traffic — look for BlackHoleCluster:
  istioctl proxy-config clusters deploy/${CLIENT}.${NS} | grep -i blackhole
  # Tail the sidecar access log while you re-run the curl:
  kubectl logs -n ${NS} deploy/${CLIENT} -c istio-proxy --tail=20
  #   -> route/cluster will show "BlackHoleCluster" and response_flags "-"
  # Confirm the external host is NOT in the mesh registry yet:
  kubectl get serviceentry -n ${NS}

${YEL}YOUR GOAL${RST}
  Restore egress to ${EXT_HOST} WITHOUT weakening the egress policy.
  In other words: keep outboundTrafficPolicy = REGISTRY_ONLY (deleting the
  Sidecar resource is cheating). Make the external host a first-class,
  explicitly-declared member of the mesh's service registry so the sidecar
  has a real upstream cluster to route to.

  Success = this returns 200 again:
    kubectl exec -n ${NS} deploy/${CLIENT} -c ${CLIENT} -- \\
      curl -s -o /dev/null -w '%{http_code}\\n' http://${EXT_HOST}${EXT_PATH}

  Hint: which Istio networking resource registers an out-of-mesh host?
${RED}=============================================================${RST}

BRIEF
}

# ---------------------------------------------------------------------------
# Cleanup: remove everything this script created
# ---------------------------------------------------------------------------
cleanup() {
  confirm "Delete lab namespace '$NS' and all resources in it?" || die "Aborted."
  kubectl delete namespace "$NS" --ignore-not-found
  ok "Cleanup complete. Namespace '$NS' removed."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  case "${1:-}" in
    --cleanup) preflight; cleanup; exit 0 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
  esac
  preflight
  setup
  baseline
  break_it
  info "When you have fixed it, tear the lab down with: $0 --cleanup"
}

main "$@"

# ===========================================================================
# SOLUTION — do not read until you have tried it yourself
# ===========================================================================
#
# ROOT CAUSE
#   The namespace-scoped `Sidecar` resource set outboundTrafficPolicy.mode to
#   REGISTRY_ONLY. Under ALLOW_ANY (the install default) the sidecar forwards
#   any unknown destination to the PassthroughCluster, so egress "just works".
#   Under REGISTRY_ONLY, any host that is not in the mesh service registry is
#   routed to the BlackHoleCluster, which immediately terminates the connection
#   — that is the 502 you saw. The external host must therefore be *declared*.
#
# STEP 1 — Confirm the diagnosis
#   kubectl get sidecar -n ica-3-5-lab -o yaml   # mode: REGISTRY_ONLY
#   istioctl proxy-config clusters deploy/mesh-client.ica-3-5-lab | grep -i black
#     # BlackHoleCluster ... exists -> unknown hosts are being dropped
#
# STEP 2 — Register the external service with a ServiceEntry
#   This is the intended fix: it adds httpbin.org to the mesh registry, giving
#   the sidecar a real upstream cluster to route to, while keeping the strict
#   REGISTRY_ONLY egress policy in force for every *other* undeclared host.
#
#   cat <<'EOF' | kubectl apply -f -
#   apiVersion: networking.istio.io/v1
#   kind: ServiceEntry
#   metadata:
#     name: httpbin-external
#     namespace: ica-3-5-lab
#   spec:
#     hosts:
#       - httpbin.org
#     location: MESH_EXTERNAL     # traffic leaves the mesh; not a mesh workload
#     resolution: DNS             # let the sidecar resolve httpbin.org via DNS
#     ports:
#       - number: 80
#         name: http
#         protocol: HTTP
#       - number: 443
#         name: https
#         protocol: TLS
#   EOF
#
# STEP 3 — Verify the repair
#   # Registry now knows the host (no longer black-holed):
#   istioctl proxy-config clusters deploy/mesh-client.ica-3-5-lab \
#     --fqdn httpbin.org
#   # And egress works again:
#   kubectl exec -n ica-3-5-lab deploy/mesh-client -c mesh-client -- \
#     curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.org/get
#   # -> 200
#
# WHY NOT JUST DELETE THE SIDECAR / SET ALLOW_ANY?
#   That re-opens egress to *everything*, which is exactly the posture a
#   production mesh locks down. REGISTRY_ONLY + explicit ServiceEntry objects
#   gives you an allow-list of external dependencies you can review and audit.
#
# GOING FURTHER (exam-relevant extensions of topic 3.5)
#   - For TLS origination (let the sidecar upgrade plaintext to TLS to the
#     external host), pair the ServiceEntry with a DestinationRule using
#     trafficPolicy.tls.mode: SIMPLE. See:
#     https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
#   - To force all external traffic through a controlled egress point, route it
#     via an Egress Gateway:
#     https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
#   - To connect a NON-Kubernetes workload (a VM) *into* the mesh, the
#     mirror-image resources are WorkloadGroup + WorkloadEntry:
#     https://istio.io/latest/docs/reference/config/networking/workload-entry/
#
# TEAR DOWN
#   ./ica-3.5-break-and-fix.sh --cleanup
# ===========================================================================