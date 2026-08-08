#!/usr/bin/env bash
#
# ICA 4.1 — Configuring Authorization  ::  Break & Fix Lab
# Istio Certified Associate — Domain "Securing Workloads"
#
# WHAT THIS LAB TEACHES
#   Istio authorization is enforced by the Envoy sidecar via AuthorizationPolicy
#   custom resources (security.istio.io). This lab plants ONE realistic,
#   controlled defect in an ALLOW policy and asks you to diagnose the resulting
#   "RBAC: access denied" and repair the policy — WITHOUT deleting it — so that
#   the intended client is allowed and every other client stays denied.
#
# SAFETY
#   Everything lives inside a single throwaway namespace: authz-lab.
#   It never touches istio-system, kube-system or any of your workloads.
#   Full undo is a one-liner:  ./break-authz.sh clean   (deletes the namespace).
#   Run it ONLY on a disposable lab VM / cluster you can wipe.
#
# PREREQUISITES
#   - A kubeconfig pointing at a disposable cluster (kind/minikube/k3d/etc.)
#   - Istio installed (istiod running in istio-system) + istioctl in PATH
#     e.g.  istioctl install --set profile=demo -y
#
# Source of truth for the syntax used here:
#   https://istio.io/latest/docs/reference/config/security/authorization-policy/
#   https://istio.io/latest/docs/concepts/security/#authorization
#   https://istio.io/latest/docs/tasks/security/authorization/authz-http/
#
# ICA curriculum reference:
#   https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf

set -euo pipefail

NS="authz-lab"

# ---------------------------------------------------------------------------
# tiny log helpers
# ---------------------------------------------------------------------------
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'
info()  { printf '%s[*]%s %s\n' "$c_cyn" "$c_reset" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$c_ylw" "$c_reset" "$*"; }
die()   { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH."; }

# ---------------------------------------------------------------------------
# curl from inside a mesh client -> httpbin, returns the HTTP status code
# (curl without -f returns 0 even on 403, so this is safe under 'set -e')
# ---------------------------------------------------------------------------
http_code() {
  local client="$1" path="${2:-/get}"
  kubectl -n "$NS" exec "deploy/${client}" -c "${client}" -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://httpbin:8000${path}" 2>/dev/null \
    || echo "ERR"
}

body() {
  local client="$1" path="${2:-/get}"
  kubectl -n "$NS" exec "deploy/${client}" -c "${client}" -- \
    curl -s --max-time 5 "http://httpbin:8000${path}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# clean subcommand
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "clean" ]]; then
  info "Deleting namespace '$NS' (full reset)…"
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  ok "Reset requested. The lab namespace is being torn down."
  exit 0
fi

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
require_cmd kubectl
require_cmd istioctl

kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster. Fix your kubeconfig."
kubectl get ns istio-system >/dev/null 2>&1 || die "istio-system namespace not found. Install Istio first: istioctl install --set profile=demo -y"
kubectl -n istio-system get deploy istiod >/dev/null 2>&1 || die "istiod not found in istio-system. Install/repair Istio first."

CTX="$(kubectl config current-context 2>/dev/null || echo '?')"
warn "This will create/modify resources in namespace '$NS' on context '${CTX}'."
warn "Use this ONLY on a disposable lab cluster."
read -r -p "Type 'lab' to continue: " confirm
[[ "$confirm" == "lab" ]] || die "Aborted."

# ---------------------------------------------------------------------------
# 1. build the sandbox: namespace + sidecar injection + workloads
# ---------------------------------------------------------------------------
info "Creating namespace '$NS' with automatic sidecar injection…"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null

info "Deploying httpbin (the protected server) + two clients (sleep, notsleep)…"
kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
# --- service accounts give each workload a distinct SPIFFE identity ----------
apiVersion: v1
kind: ServiceAccount
metadata: { name: httpbin }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: sleep }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: notsleep }
---
# --- httpbin: the workload we will protect -----------------------------------
apiVersion: apps/v1
kind: Deployment
metadata: { name: httpbin }
spec:
  replicas: 1
  selector: { matchLabels: { app: httpbin, version: v1 } }
  template:
    metadata: { labels: { app: httpbin, version: v1 } }
    spec:
      serviceAccountName: httpbin
      containers:
      - name: httpbin
        image: docker.io/kennethreitz/httpbin
        ports: [ { containerPort: 80 } ]
---
apiVersion: v1
kind: Service
metadata: { name: httpbin, labels: { app: httpbin } }
spec:
  selector: { app: httpbin }
  ports:
  - { name: http, port: 8000, targetPort: 80 }
---
# --- sleep: the AUTHORIZED client (should be allowed) ------------------------
apiVersion: apps/v1
kind: Deployment
metadata: { name: sleep }
spec:
  replicas: 1
  selector: { matchLabels: { app: sleep } }
  template:
    metadata: { labels: { app: sleep } }
    spec:
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl
        command: [ "/bin/sleep", "infinity" ]
---
# --- notsleep: the UNAUTHORIZED client (must stay denied after the fix) ------
apiVersion: apps/v1
kind: Deployment
metadata: { name: notsleep }
spec:
  replicas: 1
  selector: { matchLabels: { app: notsleep } }
  template:
    metadata: { labels: { app: notsleep } }
    spec:
      serviceAccountName: notsleep
      containers:
      - name: notsleep
        image: curlimages/curl
        command: [ "/bin/sleep", "infinity" ]
EOF

info "Waiting for the sidecars to be injected and the pods to become Ready…"
kubectl -n "$NS" rollout status deploy/httpbin  --timeout=180s >/dev/null
kubectl -n "$NS" rollout status deploy/sleep     --timeout=180s >/dev/null
kubectl -n "$NS" rollout status deploy/notsleep  --timeout=180s >/dev/null

# Confirm each pod really has 2/2 containers (app + istio-proxy)
for d in httpbin sleep notsleep; do
  ready="$(kubectl -n "$NS" get pod -l app="$d" -o jsonpath='{.items[0].status.containerStatuses[*].ready}')"
  [[ "$ready" == *"true true"* ]] || warn "deploy/$d may be missing its sidecar (containers ready: $ready)"
done

# ---------------------------------------------------------------------------
# 2. baseline: with NO authorization policy, everything is allowed
# ---------------------------------------------------------------------------
info "Baseline reachability BEFORE any authorization policy is applied:"
printf '    sleep    -> httpbin  : HTTP %s\n' "$(http_code sleep)"
printf '    notsleep -> httpbin  : HTTP %s\n' "$(http_code notsleep)"
ok "Both return 200 — Istio is allow-by-default until an ALLOW policy selects the workload."

# ---------------------------------------------------------------------------
# 3. THE CONTROLLED BREAK
#    - Turn on STRICT mTLS so every request carries a verified identity.
#    - Apply an ALLOW policy on httpbin that is SUPPOSED to permit 'sleep'…
#      …but it contains one realistic defect. Find it. Fix it.
# ---------------------------------------------------------------------------
info "Applying STRICT mTLS + the (intentionally broken) AuthorizationPolicy…"
kubectl apply -n "$NS" -f - >/dev/null <<'EOF'
# Require mutual TLS so source.principals is always populated & trustworthy.
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default }
spec:
  mtls: { mode: STRICT }
---
# INTENDED behaviour: allow ONLY the 'sleep' service account to GET httpbin.
# ACTUAL behaviour  : nobody can reach httpbin. Your job is to explain why
#                     and repair THIS policy (do not delete it).
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: httpbin-allow-sleep }
spec:
  selector:
    matchLabels: { app: httpbin }
  action: ALLOW
  rules:
  - from:
    - source:
        principals: [ "cluster.local/ns/authz-lab/sa/slep" ]
    to:
    - operation:
        methods: [ "GET" ]
EOF

info "Giving the config a few seconds to propagate to the Envoy sidecars…"
sleep 6

echo
info "Reachability AFTER the policy is applied:"
printf '    sleep    -> httpbin  : HTTP %s   %s\n' "$(http_code sleep)"    "$(body sleep    | head -c 40)"
printf '    notsleep -> httpbin  : HTTP %s   %s\n' "$(http_code notsleep)" "$(body notsleep | head -c 40)"

# ---------------------------------------------------------------------------
# 4. brief the student
# ---------------------------------------------------------------------------
cat <<BRIEF

${c_red}================  BROKEN ON PURPOSE — YOUR MISSION  ================${c_reset}

WHAT YOU WILL OBSERVE
  * sleep  -> httpbin now returns ${c_red}HTTP 403${c_reset} with body: "RBAC: access denied".
  * notsleep -> httpbin also returns 403 (correct — it was never meant to pass).
  * The intended design was: "sleep is allowed to GET httpbin, everyone else denied."
    Instead, EVEN sleep is blocked. The ALLOW policy matches httpbin but grants
    access to no real identity, so — because at least one ALLOW policy now selects
    httpbin — every request that fails to match is denied.

THE GOAL (definition of done)
  1. ${c_grn}sleep    -> httpbin  GET  returns HTTP 200${c_reset}
  2. ${c_grn}notsleep -> httpbin  GET  still returns HTTP 403${c_reset}  (RBAC: access denied)
  3. You must ${c_ylw}REPAIR${c_reset} the AuthorizationPolicy 'httpbin-allow-sleep'.
     Deleting the policy is NOT a fix — that would allow everyone.

DIAGNOSTIC TOOLBOX (work top-down: policy -> identity -> Envoy)
  # See which policies select httpbin and read the rule you must correct:
  kubectl -n $NS get authorizationpolicy
  kubectl -n $NS get authorizationpolicy httpbin-allow-sleep -o yaml

  # What identity does the 'sleep' pod ACTUALLY present? (principal = SPIFFE id)
  kubectl -n $NS get pod -l app=sleep \\
    -o jsonpath='{.items[0].spec.serviceAccountName}{"\\n"}'
  # -> principal must be: cluster.local/ns/$NS/sa/<that service account>

  # Turn on RBAC debug logging on the httpbin sidecar, then re-run the curl and
  # watch Envoy explain exactly which policy/rule denied the request:
  istioctl -n $NS proxy-config log deploy/httpbin --level rbac:debug
  kubectl  -n $NS logs deploy/httpbin -c istio-proxy -f | grep -i rbac
  #   (re-run: kubectl -n $NS exec deploy/sleep -c sleep -- curl -s httpbin:8000/get)

  # Inspect the RBAC filter Istio pushed into Envoy and grep for the principal
  # string it is matching against — compare it to sleep's real identity:
  istioctl -n $NS proxy-config listener deploy/httpbin --port 80 -o json \\
    | grep -i principal

  # Re-test after each change:
  kubectl -n $NS exec deploy/sleep    -c sleep    -- curl -s -o /dev/null -w '%{http_code}\\n' httpbin:8000/get
  kubectl -n $NS exec deploy/notsleep -c notsleep -- curl -s -o /dev/null -w '%{http_code}\\n' httpbin:8000/get

HINTS (peel only if stuck)
  * Istio authorization is DENY-by-default the moment ANY ALLOW policy selects a
    workload. So the bug is not "a policy exists" — it is that the policy's rule
    matches nobody real.
  * Compare, character by character, the 'principals' value in the policy with
    the SPIFFE identity of the sleep workload.
  * The principal format is:  cluster.local/ns/<namespace>/sa/<serviceaccount>

When done, reset the lab with:   $0 clean

${c_red}===================================================================${c_reset}
BRIEF

exit 0

# ###########################################################################
# ##########   SOLUTION — commented out. Try it yourself first.   ###########
# ###########################################################################
#
# ROOT CAUSE
#   The AuthorizationPolicy 'httpbin-allow-sleep' is an ALLOW policy that
#   selects app=httpbin, which flips httpbin to deny-by-default. Its single
#   rule authorizes the principal:
#
#       cluster.local/ns/authz-lab/sa/slep      <-- typo: "slep"
#
#   No workload in the mesh has that identity. The sleep pod actually presents:
#
#       cluster.local/ns/authz-lab/sa/sleep     <-- correct: "sleep"
#
#   Because the only ALLOW rule matches a non-existent principal, every request
#   (including sleep's) matches no ALLOW rule and Envoy returns
#   "403 RBAC: access denied".
#
# STEP 1 — Confirm sleep's real identity (service account -> principal):
#
#     kubectl -n authz-lab get pod -l app=sleep \
#       -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
#     # prints: sleep   =>  principal cluster.local/ns/authz-lab/sa/sleep
#
# STEP 2 — Prove it from Envoy's own RBAC config (what it is matching on):
#
#     istioctl -n authz-lab proxy-config listener deploy/httpbin --port 80 -o json \
#       | grep -i principal
#     # You will see the "slep" string baked into the filter — the smoking gun.
#
# STEP 3 — Repair the policy (correct the principal). Re-apply, do NOT delete:
#
#     kubectl apply -n authz-lab -f - <<'FIX'
#     apiVersion: security.istio.io/v1
#     kind: AuthorizationPolicy
#     metadata: { name: httpbin-allow-sleep }
#     spec:
#       selector:
#         matchLabels: { app: httpbin }
#       action: ALLOW
#       rules:
#       - from:
#         - source:
#             principals: [ "cluster.local/ns/authz-lab/sa/sleep" ]   # fixed
#         to:
#         - operation:
#             methods: [ "GET" ]
#     FIX
#
# STEP 4 — Wait ~5s for config propagation, then verify the definition of done:
#
#     sleep 5
#     kubectl -n authz-lab exec deploy/sleep    -c sleep    -- \
#       curl -s -o /dev/null -w 'sleep    -> %{http_code}\n' httpbin:8000/get   # expect 200
#     kubectl -n authz-lab exec deploy/notsleep -c notsleep -- \
#       curl -s -o /dev/null -w 'notsleep -> %{http_code}\n' httpbin:8000/get   # expect 403
#
#   Result: sleep is allowed, notsleep is still denied, and the policy is intact.
#
# WHY notsleep STAYS DENIED
#   Its identity (cluster.local/ns/authz-lab/sa/notsleep) is not in 'principals',
#   so it matches no ALLOW rule under the now-active deny-by-default posture.
#
# BONUS OBSERVATION (method scoping)
#   The rule only allows methods: ["GET"]. Even after the fix, a POST from sleep
#   is denied:
#     kubectl -n authz-lab exec deploy/sleep -c sleep -- \
#       curl -s -o /dev/null -w '%{http_code}\n' -X POST httpbin:8000/post   # 403
#   That is correct, intentional least-privilege — 'to.operation.methods'
#   narrows WHAT an allowed identity may do, not just WHO may connect.
#
# CLEANUP
#     ./break-authz.sh clean        # deletes the whole authz-lab namespace
#
# REFERENCES
#   AuthorizationPolicy reference:
#     https://istio.io/latest/docs/reference/config/security/authorization-policy/
#   Authorization concepts (ALLOW/DENY precedence, deny-by-default):
#     https://istio.io/latest/docs/concepts/security/#authorization
#   HTTP authorization task:
#     https://istio.io/latest/docs/tasks/security/authorization/authz-http/
#   Debugging authorization (RBAC debug logs):
#     https://istio.io/latest/docs/ops/common-problems/security-issues/
# ###########################################################################