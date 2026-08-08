#!/usr/bin/env bash
#
# ============================================================================
#  ICA  --  Istio Certified Associate
#  Domain 1: Installation & Configuration
#  Topic 1.2: Installing Istio in Sidecar or Ambient Mode   (exam weight: 5%)
#
#  BREAK & FIX LAB  --  the control-plane dependency of sidecar injection
# ============================================================================
#
#  WHAT THIS LAB TEACHES
#    When you install Istio in *sidecar* mode, `istioctl install` deploys the
#    control plane (istiod) AND registers a MutatingWebhookConfiguration that
#    tells the kube-apiserver to call istiod on every Pod CREATE in an
#    injection-enabled namespace. istiod answers with a patched Pod spec that
#    adds the `istio-init` init-container and the `istio-proxy` sidecar.
#    => Automatic sidecar injection has a HARD runtime dependency on a
#       reachable istiod. No istiod endpoints, no injection.
#
#    This lab breaks exactly that dependency in a controlled, fully reversible
#    way (it scales istiod to zero), shows you the symptom, and challenges you
#    to restore injection WITHOUT hand-editing Pod specs.
#
#  DATA-PLANE vs CONTROL-PLANE (important, and demonstrated here)
#    Pods that were ALREADY injected keep running and keep serving traffic
#    while istiod is down: each Envoy caches its last-known xDS config. Only
#    NEW injection (and new config distribution) stops. This separation is a
#    core Istio design property and a frequent exam theme.
#
#  SAFE ON: a disposable single-node lab cluster (kind / minikube / k3s / a
#    throwaway VM). DO NOT run this against a cluster you care about.
#
#  Official references (read these):
#    - Install with istioctl .......... https://istio.io/latest/docs/setup/install/istioctl/
#    - Sidecar injection mechanics .... https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
#    - Troubleshooting injection ...... https://istio.io/latest/docs/ops/common-problems/injection/
#    - Ambient mode install (analog) .. https://istio.io/latest/docs/ambient/install/
#    - K8s admission webhooks ......... https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
#    - ICA curriculum ................. https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#
set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
NS="${LAB_NS:-ica-lab-1-2}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
IMAGE="${LAB_IMAGE:-nginx:alpine}"
STATE_FILE="${STATE_FILE:-/tmp/ica-lab-1-2.state}"

# --------------------------------------------------------------------------
# Pretty output (degrades gracefully when stdout is not a TTY)
# --------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"
  GRN="$(printf '\033[32m')"; YEL="$(printf '\033[33m')"
  CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
hr()  { printf '%s\n' "------------------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }
ok()  { printf '%s\n' "${GRN}[ OK ]${RST} $*"; }
warn(){ printf '%s\n' "${YEL}[WARN]${RST} $*"; }
err() { printf '%s\n' "${RED}[FAIL]${RST} $*" >&2; }
step(){ printf '%s\n' "${CYN}${BOLD}==> $*${RST}"; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "'$1' is required but not found in PATH."; exit 1; }; }

# --------------------------------------------------------------------------
# 0. Safety gate -- this script is destructive to injection; opt in explicitly
# --------------------------------------------------------------------------
CONFIRM_FLAG="${1:-}"
need kubectl
KCTX="$(kubectl config current-context 2>/dev/null || echo '<unknown>')"

hr
say "${BOLD}ICA 1.2 -- Break & Fix: sidecar injection control-plane dependency${RST}"
hr
say "Current kube-context : ${BOLD}${KCTX}${RST}"
say "Lab namespace        : ${BOLD}${NS}${RST}"
say "Istio namespace      : ${BOLD}${ISTIO_NS}${RST}"
say ""
say "${YEL}This will temporarily DISABLE Istio sidecar injection on this cluster${RST}"
say "${YEL}by scaling istiod to zero. Only run it on a DISPOSABLE lab cluster.${RST}"
say ""

if [ "$CONFIRM_FLAG" != "--yes" ] && [ "${CONFIRM:-}" != "yes" ]; then
  if [ -t 0 ]; then
    read -r -p "Type 'break' to proceed on context '${KCTX}': " reply
    [ "$reply" = "break" ] || { err "Aborted by user."; exit 1; }
  else
    err "Non-interactive run: pass '--yes' or set CONFIRM=yes to proceed."
    exit 1
  fi
fi

# --------------------------------------------------------------------------
# 1. Preconditions -- verify a *sidecar-mode* Istio install is present
# --------------------------------------------------------------------------
step "Checking cluster connectivity and Istio installation mode"
kubectl version >/dev/null 2>&1 || { err "Cannot reach the API server."; exit 1; }
kubectl get ns "$ISTIO_NS" >/dev/null 2>&1 || { err "Namespace '$ISTIO_NS' not found. Is Istio installed?"; exit 1; }

# Locate the sidecar injector MutatingWebhookConfiguration (name varies with revisions).
WEBHOOK="$(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null \
            | sed 's#.*/##' | grep -m1 'sidecar-injector' || true)"

if [ -z "$WEBHOOK" ]; then
  if kubectl -n "$ISTIO_NS" get daemonset ztunnel >/dev/null 2>&1; then
    warn "This cluster looks like an AMBIENT-mode install: ztunnel is present but"
    warn "there is no sidecar-injection webhook. Ambient captures traffic via the"
    warn "Istio CNI + ztunnel node proxy, so there is no per-Pod sidecar to break."
    warn "This particular lab targets SIDECAR mode. The ambient analog would be to"
    warn "cordon/roll ztunnel or remove the namespace label 'istio.io/dataplane-mode=ambient'."
    warn "See https://istio.io/latest/docs/ambient/install/  --  exiting cleanly."
    exit 0
  fi
  err "No sidecar-injection webhook and no ztunnel found: Istio is not installed."
  err "Install it first, e.g.:  istioctl install --set profile=demo -y"
  exit 1
fi
ok "Found sidecar injector webhook: ${BOLD}${WEBHOOK}${RST}"

FAILPOLICY="$(kubectl get mutatingwebhookconfiguration "$WEBHOOK" \
              -o jsonpath='{.webhooks[*].failurePolicy}' 2>/dev/null || echo '?')"
say "Webhook failurePolicy: ${BOLD}${FAILPOLICY}${RST}  (Fail => Pod CREATE is rejected when istiod is unreachable)"

# Locate istiod deployment(s) (there may be several when revisions are in use).
mapfile -t ISTIOD_DEPLOYS < <(kubectl -n "$ISTIO_NS" get deploy -l app=istiod \
                              -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
[ "${#ISTIOD_DEPLOYS[@]}" -gt 0 ] || { err "No istiod deployment (label app=istiod) found in $ISTIO_NS."; exit 1; }
ok "Found istiod deployment(s): ${ISTIOD_DEPLOYS[*]}"

# --------------------------------------------------------------------------
# 2. Baseline -- prove injection currently WORKS (new Pods come up 2/2)
# --------------------------------------------------------------------------
step "Establishing a working baseline in namespace '$NS'"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" istio-injection=enabled --overwrite >/dev/null
ok "Namespace '$NS' labelled istio-injection=enabled"

kubectl -n "$NS" get deploy demo-baseline >/dev/null 2>&1 \
  || kubectl -n "$NS" create deployment demo-baseline --image="$IMAGE" >/dev/null
kubectl -n "$NS" rollout status deploy/demo-baseline --timeout=120s

BPOD="$(kubectl -n "$NS" get pod -l app=demo-baseline -o jsonpath='{.items[0].metadata.name}')"
BCONTAINERS="$(kubectl -n "$NS" get pod "$BPOD" -o jsonpath='{.spec.containers[*].name}')"
if printf '%s' "$BCONTAINERS" | grep -qw istio-proxy; then
  ok "Baseline Pod '$BPOD' is injected. Containers: ${BOLD}${BCONTAINERS}${RST}"
  kubectl -n "$NS" get pod "$BPOD"
else
  err "Baseline Pod '$BPOD' has NO istio-proxy sidecar: ${BCONTAINERS}"
  err "Auto-injection is not working even before the break; fix the install first,"
  err "then re-run this lab. (Check: 'istioctl analyze -n $NS')"
  exit 1
fi

# --------------------------------------------------------------------------
# 3. THE BREAK -- record original state, then scale istiod to zero
# --------------------------------------------------------------------------
step "Breaking sidecar injection (scaling istiod to zero)"
: > "$STATE_FILE"
for d in "${ISTIOD_DEPLOYS[@]}"; do
  reps="$(kubectl -n "$ISTIO_NS" get deploy "$d" -o jsonpath='{.spec.replicas}')"
  printf '%s %s\n' "$d" "$reps" >> "$STATE_FILE"
  kubectl -n "$ISTIO_NS" scale deploy "$d" --replicas=0 >/dev/null
  warn "Scaled deploy/$d from $reps to 0 replicas"
done
ok "Original replica counts saved to ${STATE_FILE} (safety net only)"

warn "Waiting for istiod Pods to terminate..."
kubectl -n "$ISTIO_NS" wait --for=delete pod -l app=istiod --timeout=90s 2>/dev/null \
  || warn "Timed out waiting for termination; continuing (some Pods may still be draining)."
say "istiod endpoints now:"
kubectl -n "$ISTIO_NS" get endpoints istiod -o wide 2>/dev/null || true

# --------------------------------------------------------------------------
# 4. Demonstrate the SYMPTOM -- try to create a brand-new Pod
# --------------------------------------------------------------------------
step "Reproducing the symptom: creating a new Pod in the injection-enabled namespace"
set +e
CANARY_OUT="$(kubectl -n "$NS" run demo-canary --image="$IMAGE" --restart=Never 2>&1)"
CANARY_RC=$?
set -e

hr
if [ "$CANARY_RC" -ne 0 ]; then
  err "Pod creation was REJECTED by the admission webhook:"
  printf '%s\n' "${RED}${CANARY_OUT}${RST}"
  say ""
  say "This is the failurePolicy=Fail behaviour: with istiod unreachable the"
  say "kube-apiserver cannot call the injector, so it refuses to admit the Pod."
else
  warn "Pod was created, but inspect its containers:"
  printf '%s\n' "$CANARY_OUT"
  CCONTAINERS="$(kubectl -n "$NS" get pod demo-canary -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)"
  say "demo-canary containers: ${BOLD}${CCONTAINERS}${RST}"
  say "No 'istio-proxy' => this is the failurePolicy=Ignore behaviour: the Pod is"
  say "admitted un-injected (1/1) and will be OUTSIDE the mesh (no mTLS, no policy)."
fi
hr

# --------------------------------------------------------------------------
# 5. The challenge
# --------------------------------------------------------------------------
cat <<'EOF'

  ############################  YOUR TASK  ############################
  #
  #  SYMPTOM
  #    - The ALREADY-running Pod 'demo-baseline' is still 2/2 and healthy
  #      (its Envoy cached its config -> data plane keeps working).
  #    - Any NEW Pod in an injection-enabled namespace either:
  #        * is REJECTED at admission (failurePolicy=Fail), or
  #        * comes up 1/1 with NO istio-proxy sidecar (failurePolicy=Ignore).
  #    - Deployments that try to roll new Pods will stall at "available: 0".
  #
  #  GOAL
  #    Restore automatic sidecar injection so that a NEW Pod created in the
  #    namespace 'ica-lab-1-2' again starts with 2/2 containers
  #    (app + istio-proxy).  Fix the PLATFORM -- do NOT hand-add the sidecar
  #    to Pod manifests, and do NOT disable the webhook.
  #
  #  DIAGNOSTIC HINTS (run these, reason about them -- the answer is not here)
  #    kubectl -n ica-lab-1-2 get pods
  #    kubectl -n ica-lab-1-2 get events --sort-by=.lastTimestamp | tail -n 15
  #    istioctl analyze -n ica-lab-1-2        # if istioctl is installed
  #    kubectl get mutatingwebhookconfiguration <name> -o yaml   # what does it call?
  #    kubectl -n istio-system get deploy,pods,endpoints
  #    #  -> the injector webhook posts to the 'istiod' Service. Is that Service
  #    #     backed by ANY endpoints right now?  What controls that?
  #
  ####################################################################

EOF

ok "Break applied. Go fix it. The step-by-step solution is at the bottom of this script."
exit 0

# ============================================================================
#  SOLUTION  --  step by step  (do not peek until you have tried the task)
# ============================================================================
#
#  ROOT CAUSE
#    istiod was scaled to 0 replicas. The 'istiod' Service therefore has no
#    endpoints. The MutatingWebhookConfiguration's clientConfig points the
#    kube-apiserver at that Service (path /inject), so every Pod CREATE in an
#    injection-enabled namespace fails to be mutated. With failurePolicy=Fail
#    the API server rejects the Pod; with failurePolicy=Ignore it admits it
#    un-injected.
#
#  ------------------------------------------------------------------------
#  STEP 1 -- Confirm the blast radius (control plane down, data plane fine)
#  ------------------------------------------------------------------------
#    kubectl -n ica-lab-1-2 get pods
#      # demo-baseline is still Running 2/2 -> its Envoy runs on cached config.
#      # New Pods are the ones failing -> injection, not the running mesh.
#
#  ------------------------------------------------------------------------
#  STEP 2 -- Follow the injection call path to the failing component
#  ------------------------------------------------------------------------
#    kubectl -n ica-lab-1-2 get events --sort-by=.lastTimestamp | tail
#      # -> "failed calling webhook ... no endpoints available for service istiod"
#
#    WH=$(kubectl get mutatingwebhookconfiguration -o name | sed 's#.*/##' | grep sidecar-injector)
#    kubectl get mutatingwebhookconfiguration "$WH" \
#      -o jsonpath='{.webhooks[0].clientConfig.service}{"\n"}'
#      # -> the webhook targets Service istiod/istio-system on path /inject
#
#    kubectl -n istio-system get endpoints istiod
#      # -> ENDPOINTS is <none>  == the Service has no backing Pods
#
#    kubectl -n istio-system get deploy -l app=istiod
#      # -> READY 0/0  == istiod was scaled to zero.  There is the root cause.
#
#    # (If istioctl is installed, this summarises it in one line:)
#    istioctl analyze -n ica-lab-1-2
#
#  ------------------------------------------------------------------------
#  STEP 3 -- Fix: bring the control plane back up
#  ------------------------------------------------------------------------
#    # Simplest correct fix -- scale istiod back to a running replica:
#    kubectl -n istio-system scale deploy istiod --replicas=1
#
#    # Exact restore of the original replica count(s) recorded before the break:
#    while read -r dep reps; do
#      kubectl -n istio-system scale deploy "$dep" --replicas="$reps"
#    done < /tmp/ica-lab-1-2.state
#
#    # Wait for the control plane to be Ready again:
#    kubectl -n istio-system rollout status deploy/istiod --timeout=120s
#    kubectl -n istio-system get endpoints istiod        # ENDPOINTS now populated
#
#    # (Equivalent alternative that also self-heals a corrupted webhook config,
#    #  since istioctl install is idempotent:)
#    #   istioctl install -y      # re-applies the control plane + webhook
#
#  ------------------------------------------------------------------------
#  STEP 4 -- Verify injection is restored (a NEW Pod comes up 2/2)
#  ------------------------------------------------------------------------
#    kubectl -n ica-lab-1-2 delete pod demo-canary --ignore-not-found
#    kubectl -n ica-lab-1-2 run demo-verify --image=nginx:alpine --restart=Never
#    kubectl -n ica-lab-1-2 get pod demo-verify -o \
#      jsonpath='{.spec.containers[*].name}{"\n"}'      # must include istio-proxy
#    kubectl -n ica-lab-1-2 get pod demo-verify         # READY should be 2/2
#    istioctl proxy-status                               # new proxy is SYNCED
#
#    # IMPORTANT (failurePolicy=Ignore only): any Pod admitted un-injected during
#    # the outage stays 1/1 until it is recreated. Injection is NOT retroactive.
#    # Roll affected workloads to pick up the sidecar:
#    #   kubectl -n ica-lab-1-2 rollout restart deploy/demo-baseline
#
#  ------------------------------------------------------------------------
#  STEP 5 -- Clean up the lab
#  ------------------------------------------------------------------------
#    kubectl delete namespace ica-lab-1-2
#    rm -f /tmp/ica-lab-1-2.state
#
#  KEY TAKEAWAYS FOR THE EXAM
#    - Auto-injection = kube-apiserver -> MutatingWebhook -> istiod /inject.
#      Break any hop (istiod down, Service/endpoints gone, bad caBundle,
#      wrong namespaceSelector, missing/incorrect istio-injection or
#      istio.io/rev label) and new Pods silently or loudly lose the sidecar.
#    - failurePolicy decides the symptom: Fail = rejected Pods (loud),
#      Ignore = un-injected Pods outside the mesh (silent and dangerous).
#    - Control plane and data plane are decoupled: existing proxies survive an
#      istiod outage on cached config; only injection and config updates stop.
#    - Injection happens at Pod CREATE only. Fixing the platform does not
#      retro-inject running Pods -- you must recreate/roll them.
#    - Ambient mode has no per-Pod sidecar webhook; capture is via the Istio
#      CNI + ztunnel, so the equivalent failure lives there instead.
# ============================================================================