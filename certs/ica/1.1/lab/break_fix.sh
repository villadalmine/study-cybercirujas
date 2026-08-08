#!/usr/bin/env bash
#
# ================================================================================
#  ICA (Istio Certified Associate) — Domain 1: Installation, Upgrade, Configuration
#  Topic 1.1: Installing Istio with istioctl or Helm   (exam weight: 5)
#
#  BREAK & FIX LAB — "The mesh looks healthy, but sidecars stopped appearing"
#
#  Reference (official):
#    - ICA Curriculum:      https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
#    - istioctl install:    https://istio.io/latest/docs/setup/install/istioctl/
#    - Helm install:        https://istio.io/latest/docs/setup/install/helm/
#    - Sidecar injection:   https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
#    - Config profiles:     https://istio.io/latest/docs/setup/additional-setup/config-profiles/
#
#  #############################################################################
#  # WARNING: DISPOSABLE LAB VM ONLY.                                          #
#  # This script INTENTIONALLY breaks the Istio control plane wiring.          #
#  # Run it ONLY against a throwaway cluster (kind / minikube / k3d) that you  #
#  # can delete. Never point it at anything you care about.                    #
#  #############################################################################
# ================================================================================

set -uo pipefail

# --- Lab parameters -----------------------------------------------------------
ISTIO_NS="istio-system"
LAB_NS="ica-lab-1-1"
APP="inject-check"
BROKEN_KEY="ica-lab-1-1-broken"     # the surgical wrench we throw into the works
STATE_DIR="/tmp/${LAB_NS}"
PROFILE="demo"                      # canonical learning profile from the docs

# --- Small helpers ------------------------------------------------------------
say()   { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn()  { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()   { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# --- 0. Preconditions ---------------------------------------------------------
have kubectl  || die "kubectl not found in PATH. Install it before running this lab."
have istioctl || die "istioctl not found in PATH. Grab it: https://istio.io/latest/docs/setup/getting-started/#download"

kubectl cluster-info >/dev/null 2>&1 \
  || die "No reachable Kubernetes cluster. Point KUBECONFIG at your disposable lab cluster."

mkdir -p "$STATE_DIR"

say "Cluster reachable. Current context:"
kubectl config current-context

# --- 1. Make sure Istio is actually installed ---------------------------------
if ! kubectl -n "$ISTIO_NS" get deploy istiod >/dev/null 2>&1; then
  warn "Istio control plane (istiod) not found. Installing the '${PROFILE}' profile with istioctl..."
  istioctl install --set profile="${PROFILE}" -y \
    || die "istioctl install failed. Fix the install before running the break lab."
fi

say "Waiting for istiod to be Ready..."
kubectl -n "$ISTIO_NS" rollout status deploy/istiod --timeout=180s \
  || die "istiod never became Ready. Cannot start the lab from a broken baseline."

# --- 2. Build a known-good baseline: an injection-enabled workload -------------
say "Preparing an injection-enabled namespace and a canary workload"
kubectl get ns "$LAB_NS" >/dev/null 2>&1 || kubectl create ns "$LAB_NS"
kubectl label ns "$LAB_NS" istio-injection=enabled --overwrite

kubectl -n "$LAB_NS" create deployment "$APP" --image=nginx:stable >/dev/null 2>&1 || true
kubectl -n "$LAB_NS" rollout status deploy/"$APP" --timeout=120s \
  || die "Canary deployment did not roll out. Baseline is not healthy."

# Confirm the sidecar was injected (2 containers: nginx + istio-proxy).
BASELINE_CONTAINERS="$(kubectl -n "$LAB_NS" get pod -l app="$APP" \
  -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null)"
case "$BASELINE_CONTAINERS" in
  *istio-proxy*)
    say "Baseline OK — sidecar present. Pod containers: ${BASELINE_CONTAINERS}"
    ;;
  *)
    die "Baseline pod has NO istio-proxy sidecar (containers: '${BASELINE_CONTAINERS}'). \
Fix injection before running the break lab (is the namespace labeled? is the webhook installed?)."
    ;;
esac

# --- 3. Snapshot the piece we are about to sabotage (for reference) ------------
kubectl -n "$ISTIO_NS" get svc istiod -o jsonpath='{.spec.selector}' \
  > "${STATE_DIR}/istiod-selector.before.json" 2>/dev/null
say "Saved original istiod Service selector to ${STATE_DIR}/istiod-selector.before.json"
echo "    -> $(cat "${STATE_DIR}/istiod-selector.before.json")"

# --- 4. THE BREAK -------------------------------------------------------------
# We do NOT touch istiod's Deployment, its pods, or the webhook object. istiod
# stays 1/1 Running and looks perfectly healthy. We add ONE extra label to the
# istiod Service selector. Selector matching is AND, so the Service now demands a
# label no istiod pod carries -> the Service ends up with ZERO endpoints -> the
# injection webhook has nothing to call. This is the classic "everything is green
# but nothing works" install-topology failure.
say "Injecting the fault into the istiod Service selector..."
kubectl -n "$ISTIO_NS" patch svc istiod --type=merge \
  -p "{\"spec\":{\"selector\":{\"${BROKEN_KEY}\":\"true\"}}}" \
  || die "Failed to apply the break patch."

# Force the symptom to surface: roll the canary so a fresh pod must be admitted.
kubectl -n "$LAB_NS" rollout restart deploy/"$APP" >/dev/null 2>&1 || true

sleep 5
say "istiod Service endpoints AFTER the break (note: this should be empty / <none>):"
kubectl -n "$ISTIO_NS" get endpoints istiod

# --- 5. Brief the student -----------------------------------------------------
cat <<EOF

################################################################################
#                        BREAK & FIX — YOUR MISSION                            #
################################################################################

WHAT JUST HAPPENED
  The Istio control plane pod (istiod) is still Running and Ready. 'kubectl get
  pods -n ${ISTIO_NS}' looks completely healthy. Yet the mesh has silently
  stopped admitting new sidecars.

THE SYMPTOM YOU WILL SEE
  Try to create or restart a workload in the injection-enabled namespace:

      kubectl -n ${LAB_NS} rollout restart deploy/${APP}
      kubectl -n ${LAB_NS} get pods
      kubectl -n ${LAB_NS} describe rs -l app=${APP} | tail -n 20

  Depending on the injection webhook's failurePolicy you will see ONE of:
    (a) New pods are NOT created at all. The ReplicaSet events show:
          Warning FailedCreate ... failed calling webhook
          "namespace.sidecar-injector.istio.io": ... Post
          "https://istiod.${ISTIO_NS}.svc:443/inject?timeout=10s":
          no endpoints available for service "istiod"
        (failurePolicy: Fail — admission is blocked)
    (b) New pods come up as 1/1 instead of 2/2 — no istio-proxy sidecar.
        (failurePolicy: Ignore — injection is silently skipped)

  Either way: 'istioctl proxy-status' and 'istioctl analyze' will also complain
  that the control plane is unreachable.

YOUR GOAL
  Restore sidecar injection WITHOUT deleting or recreating the istiod pod.
  Success = a freshly rolled pod in '${LAB_NS}' comes back as 2/2 (Running),
  and 'kubectl -n ${ISTIO_NS} get endpoints istiod' shows real pod IPs again.

DIAGNOSTIC LADDER (work top to bottom — do not guess)
  1. kubectl -n ${ISTIO_NS} get deploy,pods istiod        # looks healthy — a trap
  2. kubectl -n ${LAB_NS} describe rs -l app=${APP}        # read the webhook error
  3. kubectl get mutatingwebhookconfiguration | grep sidecar-injector
  4. Follow the webhook's clientConfig.service -> it points at svc/istiod
  5. kubectl -n ${ISTIO_NS} get endpoints istiod           # <-- THE SMOKING GUN (empty)
  6. Compare Service selector vs istiod pod labels:
       kubectl -n ${ISTIO_NS} get svc istiod -o jsonpath='{.spec.selector}'; echo
       kubectl -n ${ISTIO_NS} get pod -l app=istiod --show-labels

When you have found and removed the offending selector label and injection works
again, tear the lab down with:  kubectl delete ns ${LAB_NS}

Good luck. The full worked solution is at the bottom of this script, commented out.
################################################################################
EOF

exit 0

# ==============================================================================
#  SOLUTION — step by step (uncomment / copy-paste to verify your own fix)
# ==============================================================================
#
# --- Step 1: Confirm the control plane pod itself is fine (rule it out) --------
#   kubectl -n istio-system get deploy istiod
#   kubectl -n istio-system get pods -l app=istiod
#   # istiod is 1/1 Running. So the problem is NOT the control plane process.
#
# --- Step 2: Read the actual admission error ----------------------------------
#   kubectl -n ica-lab-1-1 rollout restart deploy/inject-check
#   kubectl -n ica-lab-1-1 describe rs -l app=inject-check | tail -n 20
#   # -> "...failed calling webhook ...sidecar-injector.istio.io...
#   #     no endpoints available for service \"istiod\""
#   # The API server cannot reach the injection webhook backend.
#
# --- Step 3: Locate the webhook and what it calls -----------------------------
#   kubectl get mutatingwebhookconfiguration | grep -i sidecar-injector
#   kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
#     -o jsonpath='{.webhooks[0].clientConfig.service}'; echo
#   # -> {"name":"istiod","namespace":"istio-system","path":"/inject","port":443}
#   # The webhook is intact and points at svc/istiod. So inspect that Service.
#
# --- Step 4: Find the smoking gun — the Service has no endpoints ---------------
#   kubectl -n istio-system get endpoints istiod
#   # -> ENDPOINTS   <none>     (a Service with zero endpoints = nothing to call)
#
# --- Step 5: Root cause — the selector no longer matches any istiod pod --------
#   kubectl -n istio-system get svc istiod -o jsonpath='{.spec.selector}'; echo
#   # -> {"app":"istiod","istio":"pilot","ica-lab-1-1-broken":"true"}
#   kubectl -n istio-system get pod -l app=istiod --show-labels
#   # The pod has app=istiod,istio=pilot but NOT ica-lab-1-1-broken=true.
#   # Selector matching is AND -> the Service selects nothing -> zero endpoints.
#
# --- Step 6a: Fix (surgical) — drop the bogus selector key --------------------
#   # In a JSON merge patch, setting a key to null removes it.
#   kubectl -n istio-system patch svc istiod --type=merge \
#     -p '{"spec":{"selector":{"ica-lab-1-1-broken":null}}}'
#
# --- Step 6b: Fix (idempotent reinstall — the install-topic-appropriate way) ---
#   # istioctl reconciles live objects back to the profile's desired state, which
#   # is exactly why installs are idempotent. This also repairs the Service.
#   istioctl install --set profile=demo -y
#   # (Helm equivalent: `helm upgrade istiod istio/istiod -n istio-system --reuse-values`)
#
# --- Step 7: Verify the fix ---------------------------------------------------
#   kubectl -n istio-system get endpoints istiod          # now shows real pod IPs
#   kubectl -n ica-lab-1-1 rollout restart deploy/inject-check
#   kubectl -n ica-lab-1-1 rollout status  deploy/inject-check --timeout=120s
#   kubectl -n ica-lab-1-1 get pod -l app=inject-check \
#     -o jsonpath='{.items[0].spec.containers[*].name}'; echo
#   # -> nginx istio-proxy   (2/2: the sidecar is back)
#   istioctl proxy-status                                  # data plane sees istiod again
#
# --- Step 8: Clean up ---------------------------------------------------------
#   kubectl delete ns ica-lab-1-1
#
# --- Lesson --------------------------------------------------------------------
#   A Ready control-plane pod does NOT prove the mesh is wired correctly. The
#   install topology is a chain: istiod Deployment -> istiod Pod (labels) ->
#   istiod Service (selector -> Endpoints) -> Mutating/Validating webhooks
#   (clientConfig.service). Break ANY link and injection stops, while every
#   individual object still reports "healthy". Always follow the chain to the
#   Endpoints object — an empty Endpoints list is the fault localizer that turns
#   a vague "injection isn't working" into a one-line fix.
# ==============================================================================