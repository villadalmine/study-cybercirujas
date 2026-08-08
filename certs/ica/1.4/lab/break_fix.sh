#!/usr/bin/env bash
#
# ============================================================================
#  ICA 1.4 — Upgrading Istio (Canary, In-Place)
#  BREAK & FIX lab  ·  exam weight: 5
#
#  Reference material:
#    - ICA curriculum ....... https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#    - Canary upgrades ...... https://istio.io/latest/docs/setup/upgrade/canary/
#    - In-place upgrades .... https://istio.io/latest/docs/setup/upgrade/in-place/
#    - Revisions & tags ..... https://istio.io/latest/docs/setup/upgrade/canary/#stable-revision-labels
#    - Injection precedence . https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  A canary upgrade installs a *second* control plane (a new istiod "revision")
#  next to the old one and migrates workloads by relabelling their namespace to
#  `istio.io/rev=<revision>` and RESTARTING the pods. The single most common way
#  to botch that migration is to point a namespace at a revision whose istiod
#  (and therefore whose injection webhook) does not exist. No webhook matches,
#  so the restarted pods come up with NO sidecar. Traffic frequently keeps
#  flowing (auto-mTLS falls back to plaintext against a proxy-less endpoint), so
#  the outage is SILENT: the workload has quietly left the mesh and every mTLS
#  and AuthorizationPolicy guarantee attached to it stopped being enforced.
#
#  This script builds a healthy meshed app, proves the mesh is enforcing a DENY
#  policy, then performs that exact botched migration so you can diagnose and
#  repair it. The full solution is at the very bottom of this file, commented.
#
#  SAFETY
#  ------
#  Runs ONLY against a throwaway lab cluster. Everything it touches lives in a
#  single dedicated namespace (ica-lab-14); it never modifies your istio-system
#  control plane. Tear the whole lab down with:  $0 --cleanup
# ============================================================================

set -Eeuo pipefail

NS="ica-lab-14"
BOGUS_REV="canary-1-99-0"       # a revision that is deliberately NOT installed
ASSUME_YES="no"
DO_CLEANUP="no"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!! ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
ICA 1.4 break & fix lab.

  $0 [--yes]      build the healthy app, then break the canary migration
  $0 --cleanup    delete namespace '$NS' and all lab objects
  $0 -h|--help    this help

Requires: kubectl (context pointing at a DISPOSABLE lab cluster), a running
Istio control plane, and (recommended) istioctl.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)     ASSUME_YES="yes" ;;
    --cleanup)    DO_CLEANUP="yes" ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster in the current kube-context."

HAVE_ISTIOCTL="no"
command -v istioctl >/dev/null 2>&1 && HAVE_ISTIOCTL="yes"
[ "$HAVE_ISTIOCTL" = "no" ] && warn "istioctl not found — proxy-status checks will be skipped (kubectl checks still run)."

if [ "$DO_CLEANUP" = "yes" ]; then
  log "Deleting namespace '$NS' ..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ok "Cleanup requested. Namespace '$NS' is being removed."
  exit 0
fi

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
log "Current kube-context: ${CTX}"
case "$CTX" in
  *prod*|*production*) die "context name looks like PRODUCTION ('$CTX'). Refusing. Point at a lab cluster." ;;
esac

if [ "$ASSUME_YES" != "yes" ]; then
  warn "This will create workloads and then intentionally BREAK them in namespace '$NS'."
  printf "Type YES to continue against context '%s': " "$CTX"
  read -r ans
  [ "$ans" = "YES" ] || die "aborted by user."
fi

# Locate the control plane and its installed revision.
ISTIO_NS="$(kubectl get pods -A -l app=istiod -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
[ -z "$ISTIO_NS" ] && ISTIO_NS="istio-system"
kubectl -n "$ISTIO_NS" get deploy -l app=istiod >/dev/null 2>&1 \
  || die "no istiod found in namespace '$ISTIO_NS'. Install Istio before running this lab."

INSTALLED_REV="$(kubectl -n "$ISTIO_NS" get pods -l app=istiod \
  -o jsonpath='{.items[0].metadata.labels.istio\.io/rev}' 2>/dev/null || true)"
[ -z "$INSTALLED_REV" ] && INSTALLED_REV="default"
log "Control plane namespace: ${ISTIO_NS}   ·   installed revision: ${INSTALLED_REV}"

# Choose the correct "good" injection label for this install flavour.
if [ "$INSTALLED_REV" = "default" ]; then
  GOOD_DESC="istio-injection=enabled"
  set_good() {
    kubectl label ns "$NS" "istio.io/rev-" --overwrite >/dev/null 2>&1 || true
    kubectl label ns "$NS" "istio-injection=enabled" --overwrite >/dev/null
  }
else
  GOOD_DESC="istio.io/rev=${INSTALLED_REV}"
  set_good() {
    kubectl label ns "$NS" "istio-injection-" --overwrite >/dev/null 2>&1 || true
    kubectl label ns "$NS" "istio.io/rev=${INSTALLED_REV}" --overwrite >/dev/null
  }
fi
set_bad() {
  kubectl label ns "$NS" "istio-injection-" --overwrite >/dev/null 2>&1 || true
  kubectl label ns "$NS" "istio.io/rev=${BOGUS_REV}" --overwrite >/dev/null
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have_sidecar() {
  kubectl get pods -n "$NS" -l app=httpbin \
    -o jsonpath='{.items[*].spec.containers[*].name}' 2>/dev/null \
    | tr ' ' '\n' | grep -qx "istio-proxy"
}

http_code() {  # http_code <path>  -> prints the HTTP status seen by the meshed client
  kubectl exec -n "$NS" deploy/sleep -c curl -- \
    curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://httpbin:8000/$1" 2>/dev/null \
    || echo "000"
}

wait_rollout() { kubectl rollout status "deploy/$1" -n "$NS" --timeout=150s >/dev/null; }

# ---------------------------------------------------------------------------
# STAGE 1 — build a known-good, fully meshed baseline
# ---------------------------------------------------------------------------
log "STAGE 1/3 — building a healthy meshed application in namespace '$NS' ..."

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
set_good
ok "Namespace '$NS' labelled for injection via: ${GOOD_DESC}"

kubectl apply -n "$NS" -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: { name: httpbin }
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels: { app: httpbin }
spec:
  selector: { app: httpbin }
  ports:
    - name: http
      port: 8000
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector: { matchLabels: { app: httpbin } }
  template:
    metadata:
      labels: { app: httpbin }
    spec:
      serviceAccountName: httpbin
      containers:
        - name: httpbin
          image: docker.io/kennethreitz/httpbin
          imagePullPolicy: IfNotPresent
          ports: [ { containerPort: 80 } ]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
spec:
  replicas: 1
  selector: { matchLabels: { app: sleep } }
  template:
    metadata:
      labels: { app: sleep }
    spec:
      containers:
        - name: curl
          image: curlimages/curl
          imagePullPolicy: IfNotPresent
          command: ["/bin/sleep", "infinity"]
---
# The mesh MUST enforce this: any request to /headers is denied at httpbin's
# sidecar. It is our tripwire — enforceable only while the sidecar exists.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-deny-headers
spec:
  selector: { matchLabels: { app: httpbin } }
  action: DENY
  rules:
    - to:
        - operation: { paths: ["/headers"] }
---
# Mesh-wide-style STRICT mTLS, scoped to this lab namespace.
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
spec:
  mtls: { mode: STRICT }
YAML

wait_rollout httpbin
wait_rollout sleep

have_sidecar || die "baseline httpbin came up WITHOUT a sidecar. Injection webhook for '${GOOD_DESC}' did not match — fix the install before running this lab."
ok "httpbin injected: pod is 2/2 (app + istio-proxy)."

BASE_GET="$(http_code get)"
BASE_DENY="$(http_code headers)"
log "Baseline check  ·  GET /get -> ${BASE_GET} (expect 200)   ·   GET /headers -> ${BASE_DENY} (expect 403, policy enforced)"
[ "$BASE_DENY" = "403" ] || warn "expected 403 on /headers at baseline; got ${BASE_DENY}. Mesh may not be fully enforcing yet — give it a few seconds."

if [ "$HAVE_ISTIOCTL" = "yes" ]; then
  log "istioctl proxy-status (httpbin should be listed and SYNCED):"
  istioctl proxy-status 2>/dev/null | grep -E 'NAME|httpbin' || true
fi
ok "STAGE 1 complete — healthy, fully meshed baseline established."
echo

# ---------------------------------------------------------------------------
# STAGE 2 — the controlled break (a botched canary migration)
# ---------------------------------------------------------------------------
log "STAGE 2/3 — simulating a canary migration to a revision that was never installed ..."
set_bad
warn "Namespace '$NS' now points at revision '${BOGUS_REV}' — no such istiod / injector exists."
kubectl rollout restart deploy/httpbin -n "$NS" >/dev/null
wait_rollout httpbin

if have_sidecar; then
  die "unexpected: httpbin still has a sidecar. A webhook matched '${BOGUS_REV}'. Re-run --cleanup and retry."
fi
ok "Break realised: restarted httpbin pod came up WITHOUT a sidecar (1/1)."

POST_GET="$(http_code get)"
POST_DENY="$(http_code headers)"
echo

# ---------------------------------------------------------------------------
# STAGE 3 — student briefing
# ---------------------------------------------------------------------------
cat <<EOF
================================================================================
  ICA 1.4 — BROKEN. YOUR TASK.
================================================================================

WHAT HAPPENED (the story)
  You were performing a canary upgrade. You relabelled the '$NS' namespace to
  the new revision and restarted the workloads — the textbook canary migration
  step. But the target revision's control plane was never actually installed.

THE SYMPTOMS YOU CAN SEE NOW
  * httpbin pod is READY 1/1, not 2/2 — the istio-proxy container is gone:
        kubectl get pods -n $NS
  * The DENY policy is no longer enforced. A request that MUST return 403 now
    returns 200 — the security guarantee silently evaporated:
        baseline  GET /headers -> ${BASE_DENY}      now  GET /headers -> ${POST_DENY}
  * Ordinary traffic still 'works' (GET /get -> ${POST_GET}), which is the trap:
    the outage is SILENT. httpbin has fallen out of the mesh — no mTLS identity,
    no policy, no telemetry — yet nothing is throwing errors.
  * istioctl no longer knows this proxy:
        istioctl proxy-status        # httpbin is absent

YOUR GOAL (definition of done)
  1. httpbin pod back to READY 2/2 (istio-proxy present).
  2. GET /headers denied again (403) — policy re-enforced.
  3. httpbin appears SYNCED in 'istioctl proxy-status'.

DIAGNOSTIC HINTS (find the real revision yourself — do NOT guess)
  * What revision is the namespace pointing at, and does it exist?
        kubectl get ns $NS --show-labels
        istioctl tag list
        kubectl get mutatingwebhookconfigurations | grep sidecar-injector
        kubectl -n $ISTIO_NS get pods -l app=istiod --show-labels
  * Remember: relabelling a namespace does nothing to already-running pods.
    A revision change is only realised when the data plane is RESTARTED — the
    same truth that makes in-place upgrades require a rollout of every workload.

  When you think it is fixed, re-run the three checks above.
  The full step-by-step solution is at the bottom of this script file.
================================================================================
EOF

exit 0

# ============================================================================
#  SOLUTION  (read only after you have tried)
# ============================================================================
#
#  ROOT CAUSE
#    The namespace was labelled `istio.io/rev=canary-1-99-0`, a revision with no
#    installed istiod and therefore no matching sidecar-injection webhook. On
#    pod restart, no MutatingWebhookConfiguration selected the namespace, so the
#    sidecar was never injected. The workload silently left the mesh: mTLS
#    identity, the DENY AuthorizationPolicy and all telemetry stopped applying,
#    even though plaintext traffic kept flowing.
#
#  STEP 1 — Confirm which revision(s) actually exist.
#      istioctl tag list
#      kubectl get mutatingwebhookconfigurations | grep sidecar-injector
#      kubectl -n <istio-ns> get pods -l app=istiod \
#        -o jsonpath='{range .items[*]}{.metadata.labels.istio\.io/rev}{"\n"}{end}'
#    In this lab the real revision printed at startup as ${INSTALLED_REV}
#    (installed in namespace ${ISTIO_NS}).
#
#  STEP 2 — See the bad label on the namespace.
#      kubectl get ns ${NS} --show-labels
#      # -> istio.io/rev=${BOGUS_REV}   (points at nothing)
#
#  STEP 3 — Repoint the namespace at a revision that exists.
#    For a revisioned install:
#      kubectl label ns ${NS} istio.io/rev=${INSTALLED_REV} --overwrite
#    For a default install, either of these is correct (never set both — the
#    istio-injection label wins and maps to the 'default' revision):
#      kubectl label ns ${NS} istio-injection- --overwrite
#      kubectl label ns ${NS} istio-injection=enabled --overwrite
#    Best practice for real upgrades: point namespaces at a STABLE revision tag
#    (e.g. `istioctl tag set prod --revision <rev>`, then
#     `kubectl label ns ${NS} istio.io/rev=prod`) so you re-tag once instead of
#    relabelling every namespace on each upgrade.
#
#  STEP 4 — Restart the data plane so the new label takes effect.
#    Labels are NOT retroactive; running pods keep whatever they were injected
#    with. This restart step is identical to what an in-place upgrade demands
#    (roll every workload after istiod is replaced):
#      kubectl rollout restart deploy/httpbin -n ${NS}
#      kubectl rollout status  deploy/httpbin -n ${NS}
#
#  STEP 5 — Verify the fix against the definition of done.
#      kubectl get pods -n ${NS}                         # httpbin -> READY 2/2
#      istioctl proxy-status | grep httpbin              # present and SYNCED
#      kubectl exec -n ${NS} deploy/sleep -c curl -- \
#        curl -s -o /dev/null -w '%{http_code}\n' http://httpbin:8000/headers
#      # -> 403  (DENY policy enforced again; the workload is back in the mesh)
#      istioctl analyze -n ${NS}                         # no injection warnings
#
#  TEARDOWN
#      $0 --cleanup      # or: kubectl delete namespace ${NS}
#
#  Sources:
#    https://istio.io/latest/docs/setup/upgrade/canary/
#    https://istio.io/latest/docs/setup/upgrade/in-place/
#    https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
#    https://istio.io/latest/docs/ops/common-problems/injection/
# ============================================================================