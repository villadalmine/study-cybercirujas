#!/usr/bin/env bash
#
# ICA — Istio Certified Associate
# Domain 2.1 — Troubleshooting Configuration (exam weight: 7)
#
# Break & Fix lab: a VirtualService routes to a subset that its DestinationRule
# never declares. The data plane is healthy, every pod is Ready, the Service has
# endpoints — and yet requests fail. This is the archetypal Istio configuration
# fault: the break lives entirely in the control-plane config, so `kubectl get
# pods` tells you nothing and you MUST reach for Istio's own diagnostics.
#
# WHAT THIS SCRIPT DOES
#   1. Refuses to run unless you confirm this is a disposable lab cluster.
#   2. Builds a known-good sleep -> httpbin path in the throwaway ns `ica-lab`.
#   3. Proves the baseline works (HTTP 200).
#   4. Breaks exactly ONE field on purpose, then hands the cluster to you.
#
# SAFETY
#   - Everything is created in the namespace `ica-lab`. Nothing cluster-scoped,
#     nothing in istio-system, no host mounts, no privileged pods.
#   - `--clean` deletes the namespace and every object created here.
#
# Source of truth — ICA Curriculum (CNCF):
#   https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
# Istio configuration-debugging references:
#   https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
#   https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
#   https://istio.io/latest/docs/reference/config/networking/destination-rule/
#   https://istio.io/latest/docs/reference/config/networking/virtual-service/

set -euo pipefail

NS="ica-lab"
SVC_FQDN="httpbin.${NS}.svc.cluster.local"

# --- pretty output (honours NO_COLOR) ---------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; X=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; C=""; X=""
fi
log()  { printf '%s[ica]%s %s\n'  "$C" "$X" "$*"; }
ok()   { printf '%s[ ok]%s %s\n'  "$G" "$X" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$Y" "$X" "$*"; }
die()  { printf '%s[fail]%s %s\n' "$R" "$X" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH — this lab needs it."; }

# --- preflight ---------------------------------------------------------------
preflight() {
  need kubectl
  need istioctl
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster (check your kubeconfig / context)."
  kubectl get ns istio-system >/dev/null 2>&1 \
    || die "istio-system namespace not found. Install Istio first, e.g.: istioctl install --set profile=demo -y"
  kubectl -n istio-system get deploy istiod >/dev/null 2>&1 \
    || die "istiod deployment not found in istio-system. Istio control plane is not installed."
  ok "kubectl, istioctl and an Istio control plane are present."
}

confirm_lab() {
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  warn "This script will CREATE and then BREAK objects in namespace '${NS}'."
  warn "Active kube-context: ${B}${ctx}${X}"
  if [[ "${LAB_CONFIRM:-}" == "1" || "${ASSUME_YES:-}" == "1" ]]; then
    ok "Confirmation bypassed (LAB_CONFIRM/--yes)."
    return
  fi
  [[ -t 0 ]] || die "Non-interactive shell and no --yes/LAB_CONFIRM=1. Refusing to touch an unconfirmed cluster."
  read -r -p "Type the context name '${ctx}' to confirm this is a DISPOSABLE lab: " ans
  [[ "$ans" == "$ctx" ]] || die "Context not confirmed. Aborting without changing anything."
}

# --- lifecycle ---------------------------------------------------------------
clean() {
  log "Deleting namespace '${NS}' and everything in it..."
  kubectl delete ns "$NS" --ignore-not-found --wait=true
  ok "Lab removed."
}

deploy_app() {
  log "Creating namespace '${NS}' with sidecar injection enabled..."
  kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label ns "$NS" istio-injection=enabled --overwrite >/dev/null

  log "Deploying httpbin (v1), a sleep/curl client, and a KNOWN-GOOD Istio config..."
  kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 8080
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-v1
  labels:
    app: httpbin
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - name: httpbin
        image: docker.io/mccutchen/go-httpbin:v2.15.0
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  labels:
    app: sleep
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      serviceAccountName: sleep
      containers:
      - name: curl
        image: curlimages/curl:8.7.1
        command: ["/bin/sleep", "infinity"]
        imagePullPolicy: IfNotPresent
---
# DestinationRule declares ONLY subset v1. Remember this — it is the whole lab.
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: httpbin
spec:
  host: httpbin
  subsets:
  - name: v1
    labels:
      version: v1
---
# Baseline VirtualService: routes to subset v1 (which the DR does declare).
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: httpbin
spec:
  hosts:
  - httpbin
  http:
  - route:
    - destination:
        host: httpbin
        subset: v1
EOF

  log "Waiting for workloads (and their injected sidecars) to become Ready..."
  kubectl -n "$NS" rollout status deploy/httpbin-v1 --timeout=150s
  kubectl -n "$NS" rollout status deploy/sleep      --timeout=150s
  ok "App is up with a valid config."
}

curl_code() {
  kubectl -n "$NS" exec deploy/sleep -c curl -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://httpbin:8000/status/200" || true
}

baseline_test() {
  log "Proving the baseline works before we break anything..."
  local code; code="$(curl_code)"
  [[ "$code" == "200" ]] \
    && ok "Baseline OK: sleep -> httpbin returned HTTP ${code}." \
    || die "Baseline is NOT healthy (got '${code}'). Fix the environment before breaking it on purpose."
}

break_config() {
  log "Introducing the fault: repointing the VirtualService to subset ${B}v2${X}..."
  # ONE field changes. The DestinationRule still only knows about v1, so Istio
  # generates a route to a subset cluster that does not exist in the sidecar.
  kubectl -n "$NS" patch virtualservice httpbin --type=json \
    -p='[{"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"v2"}]' >/dev/null

  sleep 2
  local code; code="$(curl_code)"
  ok "Fault injected. sleep -> httpbin now returns HTTP ${B}${code}${X} (expected 503)."
}

print_mission() {
  cat <<EOF

${B}====================================================================${X}
${B} ICA 2.1 — TROUBLESHOOTING CONFIGURATION : YOUR MISSION${X}
${B}====================================================================${X}

${B}THE SYMPTOM${X}
  From the sleep client, this request that returned 200 a minute ago now
  returns ${R}HTTP 503${X}:

      kubectl -n ${NS} exec deploy/sleep -c curl -- \\
        curl -s -o /dev/null -w '%{http_code}\\n' http://httpbin:8000/status/200

  Yet everything you would normally check looks perfectly healthy:
    - kubectl -n ${NS} get pods          -> all Running / Ready
    - kubectl -n ${NS} get endpoints httpbin -> has a backing pod IP
    - no CrashLoopBackOff, no image pull error, no OOMKill

  Nothing in the ${B}data plane${X} is broken. The break is 100% in the Istio
  ${B}configuration${X}: the sidecar has been told to send this traffic somewhere
  that does not exist, so Envoy has no valid upstream cluster to pick.

${B}YOUR GOAL${X}
  Get a ${G}200${X} back from the sleep client again — WITHOUT blindly deleting the
  VirtualService or the DestinationRule. Diagnose which object is wrong,
  understand why, and correct the minimal thing.

${B}THE EXACT SKILLS THIS DOMAIN TESTS — start here${X}
  1) Ask Istio to grade your own config:
       istioctl analyze -n ${NS}
  2) See where the client sidecar actually routes port 8000:
       istioctl proxy-config routes deploy/sleep -n ${NS} --name 8000 -o json
  3) List the upstream clusters the sidecar really has for httpbin:
       istioctl proxy-config clusters deploy/sleep -n ${NS} --fqdn ${SVC_FQDN}
  4) Read both objects and compare subset names:
       kubectl -n ${NS} get virtualservice,destinationrule -o yaml
  5) (Optional) read the sidecar access log's response flag:
       kubectl -n ${NS} logs deploy/sleep -c istio-proxy --tail=20

${B}YOU HAVE WON WHEN${X}
       kubectl -n ${NS} exec deploy/sleep -c curl -- \\
         curl -s -o /dev/null -w '%{http_code}\\n' http://httpbin:8000/status/200
  prints ${G}200${X} and 'istioctl analyze -n ${NS}' reports no validation errors.

  When you are done (or stuck), run:  ${B}$0 --clean${X}
${B}====================================================================${X}

EOF
}

usage() {
  cat <<EOF
Usage: $0 [--break | --clean | --yes]
  (no args)   Same as --break.
  --break     Deploy the good app, verify 200, then inject the fault.
  --clean     Delete the '${NS}' namespace and everything created here.
  --yes / -y  Skip the interactive lab-confirmation prompt (or LAB_CONFIRM=1).
EOF
}

main() {
  local action="break"
  for arg in "$@"; do
    case "$arg" in
      --break)      action="break" ;;
      --clean)      action="clean" ;;
      --yes|-y)     ASSUME_YES=1 ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage; die "Unknown argument: $arg" ;;
    esac
  done

  preflight
  if [[ "$action" == "clean" ]]; then
    clean
    exit 0
  fi

  confirm_lab
  deploy_app
  baseline_test
  break_config
  print_mission
}

main "$@"

# =============================================================================
# SOLUTION — read only after you have genuinely tried the mission above.
# =============================================================================
#
# ROOT CAUSE
#   A VirtualService may only route to a `subset` that is DECLARED by a
#   DestinationRule for the same host. Here the VirtualService sends traffic to
#   `subset: v2`, but the DestinationRule for host `httpbin` declares only
#   subset `v1`. Istio (Pilot) builds Envoy CDS clusters ONLY for subsets that
#   exist in a DestinationRule — so the cluster
#       outbound|8000|v2|httpbin.ica-lab.svc.cluster.local
#   is never programmed into the sleep sidecar. The RDS route still references
#   that (missing) cluster, so Envoy has no upstream and answers 503. In the
#   access log you will typically see the response flag `NC` (No Cluster) —
#   the tell-tale signature of "route points to a subset/cluster that Envoy
#   does not have", as opposed to `UH`/`UF` (real endpoints down) or `NR`
#   (no route matched at all). Pods, Service and Endpoints are all irrelevant
#   to this failure — which is exactly why `kubectl get pods` misleads you.
#
# STEP-BY-STEP DIAGNOSIS
#   1. Confirm the failure and that it is config, not data plane:
#        kubectl -n ica-lab get pods,endpoints
#        kubectl -n ica-lab exec deploy/sleep -c curl -- \
#          curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/status/200   # -> 503
#
#   2. Let Istio grade the config first — this is the fastest signal:
#        istioctl analyze -n ica-lab
#      It reports the VirtualService referencing a subset not found in any
#      DestinationRule (a referenced-resource-not-found validation warning).
#
#   3. Confirm at the proxy level where the route goes:
#        istioctl proxy-config routes deploy/sleep -n ica-lab --name 8000 -o json | \
#          grep -i cluster
#      You will see the route target cluster ...|v2|httpbin...  (subset v2).
#
#   4. Confirm the sidecar has NO such cluster (only v1 + the base cluster):
#        istioctl proxy-config clusters deploy/sleep -n ica-lab --fqdn \
#          httpbin.ica-lab.svc.cluster.local
#      -> you see subset `v1` and the subset-less cluster, but NO `v2`.
#
#   5. Read the two objects side by side and spot the mismatch:
#        kubectl -n ica-lab get virtualservice httpbin -o yaml   # route -> subset: v2
#        kubectl -n ica-lab get destinationrule  httpbin -o yaml   # subsets: only v1
#
# THE FIX — pick the one that matches intent
#
#   FIX A — the `v2` was a typo / the intended target is v1 (minimal, correct here):
#        kubectl -n ica-lab patch virtualservice httpbin --type=json \
#          -p='[{"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"v1"}]'
#
#   FIX B — a v2 rollout WAS intended: make the config internally consistent by
#           BOTH declaring the subset AND providing pods that match its labels.
#           Declaring the subset alone is not enough; with zero v2 endpoints you
#           would trade the 503/NC for a 503/UH (no healthy upstream).
#        kubectl -n ica-lab apply -f - <<'YAML'
#        apiVersion: networking.istio.io/v1beta1
#        kind: DestinationRule
#        metadata:
#          name: httpbin
#        spec:
#          host: httpbin
#          subsets:
#          - name: v1
#            labels: { version: v1 }
#          - name: v2
#            labels: { version: v2 }
#        ---
#        apiVersion: apps/v1
#        kind: Deployment
#        metadata:
#          name: httpbin-v2
#          labels: { app: httpbin, version: v2 }
#        spec:
#          replicas: 1
#          selector:
#            matchLabels: { app: httpbin, version: v2 }
#          template:
#            metadata:
#              labels: { app: httpbin, version: v2 }
#            spec:
#              serviceAccountName: httpbin
#              containers:
#              - name: httpbin
#                image: docker.io/mccutchen/go-httpbin:v2.15.0
#                ports:
#                - containerPort: 8080
#        YAML
#
# VERIFY THE FIX
#        istioctl analyze -n ica-lab                                   # -> no errors
#        kubectl -n ica-lab exec deploy/sleep -c curl -- \
#          curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/status/200   # -> 200
#
# TAKEAWAY
#   VirtualService and DestinationRule are two halves of one contract: the VS
#   picks a `subset` NAME, the DR is the only place that DEFINES what that name
#   means (its label selector). Any subset named on one side but missing on the
#   other is a silent 503 whose evidence lives in `istioctl analyze` and
#   `istioctl proxy-config`, never in `kubectl get pods`. Make config-level
#   tools your first reflex for domain 2.1, not your last.
# =============================================================================