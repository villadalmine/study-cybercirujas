#!/usr/bin/env bash
#
# ============================================================================
#  CNPA · Topic 4.3 — Infrastructure Provisioning with Kubernetes
#                      (Crossplane / Kratix)
#  Exam version: 2025-04-01   ·   Exam weight: 3.0
#
#  BREAK & FIX lab — run ONLY on a disposable lab VM / throwaway cluster.
#
#  What this lab teaches
#  ---------------------
#  Crossplane turns a Kubernetes cluster into a control plane that provisions
#  infrastructure. The chain a platform team ships to app developers is:
#
#      Claim (namespaced, dev-facing)
#        └─> Composite Resource / XR (cluster-scoped, platform-facing)
#              └─> Composition (the "recipe": mode Pipeline + Functions)
#                    └─> Managed Resources (the real infra: DB, bucket, ...)
#
#  A CompositeResourceDefinition (XRD) declares the XR/Claim API and, crucially,
#  which apiVersions it *serves* and marks *referenceable*. A Composition binds
#  to exactly one XR type through spec.compositeTypeRef {apiVersion, kind}. If
#  that type reference drifts away from what the XRD actually serves, Crossplane
#  refuses to use the Composition — provisioning silently stops even though every
#  object still "exists". This lab reproduces that failure with a credential-free
#  stack (provider-nop composes fake Managed Resources, so no cloud account and
#  no real spend are involved), then asks you to repair it.
#
#  Sources (official)
#    - CNPA Curriculum ....... https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#    - Crossplane concepts ... https://docs.crossplane.io/latest/concepts/
#    - Compositions .......... https://docs.crossplane.io/latest/concepts/compositions/
#    - XRDs .................. https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
#    - Composition Functions . https://docs.crossplane.io/latest/concepts/composition-functions/
#    - provider-nop .......... https://github.com/crossplane-contrib/provider-nop
#    - function-patch-transform https://github.com/crossplane-contrib/function-patch-and-transform
#    - Kratix (analogue) ..... https://docs.kratix.io/
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via environment before running)
# ----------------------------------------------------------------------------
NS="${NS:-cnpa-lab}"                      # namespace the app dev "owns"
XRD_NAME="xdatabaseinstances.platform.cnpa.io"
COMP_NAME="xdatabaseinstances.platform.cnpa.io"
CLAIM_KIND="databaseinstance"             # lowercase for kubectl
CLAIM_NAME="orders-db"
CLAIM_CRD="databaseinstances.platform.cnpa.io"

GOOD_APIVERSION="platform.cnpa.io/v1alpha1"   # the version the XRD really serves
BAD_APIVERSION="platform.cnpa.io/v1beta1"     # a version the XRD does NOT serve  <-- the injected bug

# Pinned example package tags. These move over time — if a pull fails, check the
# Upbound / crossplane-contrib marketplace and bump the tag. Both registries are
# valid: xpkg.crossplane.io (current) and xpkg.upbound.io (legacy mirror).
CROSSPLANE_NAMESPACE="${CROSSPLANE_NAMESPACE:-crossplane-system}"
CROSSPLANE_CHART_VERSION="${CROSSPLANE_CHART_VERSION:-}"   # empty = latest stable
PROVIDER_NOP_IMAGE="${PROVIDER_NOP_IMAGE:-xpkg.crossplane.io/crossplane-contrib/provider-nop:v0.4.0}"
FUNCTION_PNT_IMAGE="${FUNCTION_PNT_IMAGE:-xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.8.2}"

WAIT_LONG="${WAIT_LONG:-300s}"
WAIT_MED="${WAIT_MED:-180s}"

# ----------------------------------------------------------------------------
# Pretty output
# ----------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  BOLD="$(tput bold)"; RED="$(tput setaf 1)"; GRN="$(tput setaf 2)"
  YEL="$(tput setaf 3)"; CYN="$(tput setaf 6)"; RST="$(tput sgr0)"
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s== %s ==%s\n' "${BOLD}${CYN}" "$*" "${RST}"; }
ok()   { printf '%s[ ok ]%s %s\n' "${GRN}" "${RST}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${YEL}" "${RST}" "$*"; }
die()  { printf '%s[fail]%s %s\n' "${RED}" "${RST}" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Safety guard — this script mutates a live cluster
# ----------------------------------------------------------------------------
confirm_disposable() {
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  head "Target cluster"
  say "  kube-context : ${BOLD}${ctx}${RST}"
  say "  namespace    : ${BOLD}${NS}${RST}"
  say "  This lab installs Crossplane and injects a fault. Use a THROWAWAY cluster."
  if [ "${CNPA_LAB_ASSUME_YES:-0}" = "1" ] || [ "${ASSUME_YES:-0}" = "1" ]; then
    warn "ASSUME_YES set — skipping confirmation."
    return 0
  fi
  printf 'Type the context name to proceed: '
  local answer; read -r answer
  [ "$answer" = "$ctx" ] || die "Confirmation did not match current-context. Aborting."
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "Required tool not found: '$bin'"
  done
}

# ----------------------------------------------------------------------------
# Baseline: a healthy Crossplane control plane that provisions a "database"
# ----------------------------------------------------------------------------
install_crossplane() {
  head "Installing Crossplane (Helm)"
  helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
  helm repo update >/dev/null
  local vflag=()
  [ -n "$CROSSPLANE_CHART_VERSION" ] && vflag=(--version "$CROSSPLANE_CHART_VERSION")
  helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace "$CROSSPLANE_NAMESPACE" --create-namespace \
    "${vflag[@]}" --wait --timeout "$WAIT_LONG"
  kubectl wait --for=condition=Available deployment --all \
    -n "$CROSSPLANE_NAMESPACE" --timeout="$WAIT_MED" >/dev/null
  ok "Crossplane core is up in namespace '$CROSSPLANE_NAMESPACE'."
}

install_packages() {
  head "Installing provider-nop and function-patch-and-transform"
  cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-nop
spec:
  package: ${PROVIDER_NOP_IMAGE}
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: ${FUNCTION_PNT_IMAGE}
EOF
  say "Waiting for packages to become Healthy (image pull can take a minute)..."
  kubectl wait provider.pkg.crossplane.io/provider-nop \
    --for=condition=Healthy --timeout="$WAIT_MED" \
    || die "provider-nop never became Healthy — check 'kubectl describe provider.pkg provider-nop' (bad image tag?)."
  kubectl wait function.pkg.crossplane.io/function-patch-and-transform \
    --for=condition=Healthy --timeout="$WAIT_MED" \
    || die "function never became Healthy — check 'kubectl describe function.pkg function-patch-and-transform'."
  kubectl wait --for=condition=Established crd/nopresources.nop.crossplane.io --timeout=60s >/dev/null
  ok "Packages Healthy; NopResource CRD established."
}

apply_platform_api() {
  head "Publishing the platform API (XRD + Composition)"
  # XRD — serves ONLY v1alpha1. Note this well: the bug will point the Composition
  # at v1beta1, which is NOT in this list.
  cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xdatabaseinstances.platform.cnpa.io
spec:
  group: platform.cnpa.io
  names:
    kind: XDatabaseInstance
    plural: xdatabaseinstances
  claimNames:
    kind: DatabaseInstance
    plural: databaseinstances
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                parameters:
                  type: object
                  properties:
                    engine:
                      type: string
                      enum: ["postgres", "mysql"]
                    size:
                      type: string
                      enum: ["small", "large"]
                  required: ["engine", "size"]
              required: ["parameters"]
            status:
              type: object
              properties:
                ready:
                  type: boolean
EOF
  kubectl wait --for=condition=Established "xrd/${XRD_NAME}" --timeout=90s >/dev/null
  kubectl wait --for=condition=Offered "xrd/${XRD_NAME}" --timeout=90s >/dev/null
  kubectl wait --for=condition=Established "crd/${CLAIM_CRD}" --timeout=90s >/dev/null

  # Composition — mode: Pipeline, one function step. compositeTypeRef is the
  # single most fragile line: it MUST match an apiVersion the XRD serves.
  cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xdatabaseinstances.platform.cnpa.io
spec:
  compositeTypeRef:
    apiVersion: platform.cnpa.io/v1alpha1
    kind: XDatabaseInstance
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: database
            base:
              apiVersion: nop.crossplane.io/v1alpha1
              kind: NopResource
              spec:
                forProvider:
                  conditionAfter:
                    - time: 0s
                      conditionType: Ready
                      conditionStatus: "False"
                    - time: 10s
                      conditionType: Ready
                      conditionStatus: "True"
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.engine
                toFieldPath: metadata.annotations[platform.cnpa.io/engine]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.size
                toFieldPath: metadata.annotations[platform.cnpa.io/size]
            readinessChecks:
              - type: MatchCondition
                matchCondition:
                  type: Ready
                  status: "True"
EOF
  ok "XRD Established+Offered; Composition applied; Claim CRD '${CLAIM_CRD}' ready."
}

apply_claim() {
  head "Submitting an app-developer Claim"
  kubectl create namespace "$NS" >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f -
apiVersion: platform.cnpa.io/v1alpha1
kind: DatabaseInstance
metadata:
  name: ${CLAIM_NAME}
  namespace: ${NS}
spec:
  compositionRef:
    name: ${COMP_NAME}
  parameters:
    engine: postgres
    size: small
EOF
}

wait_baseline_ready() {
  say "Waiting for the Claim to become Ready (nop flips Ready=True after ~10s)..."
  kubectl wait "${CLAIM_KIND}/${CLAIM_NAME}" -n "$NS" \
    --for=condition=Ready --timeout="$WAIT_MED" \
    || die "Baseline never became Ready — do not break a lab that is not green yet."
  ok "Baseline is GREEN: Claim '${CLAIM_NAME}' provisioned successfully."
}

ensure_baseline() {
  require kubectl helm
  confirm_disposable
  install_crossplane
  install_packages
  apply_platform_api
  apply_claim
  wait_baseline_ready
}

# ----------------------------------------------------------------------------
# THE BREAK — point the Composition at an apiVersion the XRD does not serve,
# then resubmit the Claim so the failure is observed on a fresh provisioning.
# Nothing is deleted from the cluster; nothing external is touched.
# ----------------------------------------------------------------------------
do_break() {
  head "Injecting the fault"
  kubectl patch composition "$COMP_NAME" --type=merge \
    -p "{\"spec\":{\"compositeTypeRef\":{\"apiVersion\":\"${BAD_APIVERSION}\"}}}"
  ok "Composition '${COMP_NAME}' compositeTypeRef.apiVersion is now '${BAD_APIVERSION}'."

  say "Re-submitting the Claim so provisioning is re-evaluated from scratch..."
  kubectl delete "${CLAIM_KIND}/${CLAIM_NAME}" -n "$NS" --wait=true --timeout=90s >/dev/null 2>&1 || true
  apply_claim
  sleep 8
}

print_symptom() {
  cat <<EOF

${BOLD}${RED}################  LAB 4.3 IS NOW BROKEN  ################${RST}

${BOLD}What you will observe${RST}

  The Claim is stuck. It never reports SYNCED=True, and a Managed Resource
  (NopResource) is never created. Example:

    \$ kubectl get ${CLAIM_KIND} -n ${NS}
    NAME        SYNCED   READY   CONNECTION-SECRET   AGE
    ${CLAIM_NAME}   False            ${NS}                 25s

    \$ kubectl get composite            # the cluster-scoped XR behind the Claim
    NAME                    SYNCED   READY   COMPOSITION                              AGE
    ${CLAIM_NAME}-xxxxx     False            ${COMP_NAME}   25s

    \$ kubectl get managed              # nothing was provisioned
    No resources found

  Read the events on the XR — that is where the real message lives:

    \$ kubectl describe composite ${CLAIM_NAME}-xxxxx
    ...
    Warning  ComposeResources  ...  refusing to use Composition "${COMP_NAME}":
             compositeTypeRef ("${BAD_APIVERSION}", "XDatabaseInstance")
             is not compatible with this composite resource
             ("${GOOD_APIVERSION}", "XDatabaseInstance")

  (Exact wording varies by Crossplane version, but the essence is always:
   the referenced Composition is NOT COMPATIBLE with / does not MATCH the XR.)

${BOLD}Your objective${RST}

  Make this command report ${GRN}SYNCED=True${RST} and ${GRN}READY=True${RST} again:

    \$ kubectl get ${CLAIM_KIND}/${CLAIM_NAME} -n ${NS}

  Constraints (this is what makes it a real diagnosis, not a guess):
    • Do NOT edit the XRD.
    • Do NOT edit the Claim.
    • The bug is entirely inside the ${BOLD}Composition${RST}. Find it and fix it.

${BOLD}Hints — the ladder to walk${RST}
  1. get -> describe the Claim, then the composite (XR). Follow SYNCED=False down.
  2. Which apiVersions does the XRD actually serve+reference?
       kubectl get xrd ${XRD_NAME} \\
         -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" ref="}{.referenceable}{"\\n"}{end}'
  3. Which apiVersion does the Composition claim to compose?
       kubectl get composition ${COMP_NAME} -o jsonpath='{.spec.compositeTypeRef.apiVersion}{"\\n"}'
  4. Compare 2 and 3. Reconcile the drift.

  When you are ready to check yourself (or to auto-fix), run:
       $0 solve
  Full step-by-step solution is at the very bottom of this script, commented out.

${BOLD}${RED}########################################################${RST}
EOF
}

# ----------------------------------------------------------------------------
# Convenience: status, auto-solve, teardown
# ----------------------------------------------------------------------------
show_status() {
  head "Current state"
  echo "-- Claim --";        kubectl get "${CLAIM_KIND}" -n "$NS" 2>/dev/null || true
  echo "-- Composite (XR) --"; kubectl get composite 2>/dev/null || true
  echo "-- Managed --";      kubectl get managed 2>/dev/null || true
  echo "-- Composition typeRef --"
  kubectl get composition "$COMP_NAME" -o jsonpath='{.spec.compositeTypeRef.apiVersion}{"\n"}' 2>/dev/null || true
}

do_solve() {
  head "Applying the fix (Composition compositeTypeRef -> ${GOOD_APIVERSION})"
  kubectl patch composition "$COMP_NAME" --type=merge \
    -p "{\"spec\":{\"compositeTypeRef\":{\"apiVersion\":\"${GOOD_APIVERSION}\"}}}"
  say "Waiting for the Claim to converge..."
  kubectl wait "${CLAIM_KIND}/${CLAIM_NAME}" -n "$NS" --for=condition=Ready --timeout="$WAIT_MED" \
    && ok "Fixed. Claim '${CLAIM_NAME}' is Ready and Synced again." \
    || warn "Not Ready yet — re-run '$0 status' in a few seconds; nop needs ~10s."
}

do_teardown() {
  head "Tearing down the lab"
  kubectl delete "${CLAIM_KIND}/${CLAIM_NAME}" -n "$NS" --ignore-not-found --wait=false
  kubectl delete composition "$COMP_NAME" --ignore-not-found
  kubectl delete xrd "$XRD_NAME" --ignore-not-found
  kubectl delete function.pkg.crossplane.io/function-patch-and-transform --ignore-not-found
  kubectl delete provider.pkg.crossplane.io/provider-nop --ignore-not-found
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  warn "Crossplane core (namespace '${CROSSPLANE_NAMESPACE}') left in place. Remove with:"
  say  "    helm uninstall crossplane -n ${CROSSPLANE_NAMESPACE} && kubectl delete ns ${CROSSPLANE_NAMESPACE}"
  ok "Lab objects removed."
}

usage() {
  cat <<EOF
Usage: $0 [command]

  break      (default) build a healthy baseline, then inject the fault
  status     show Claim / XR / Managed Resources / Composition typeRef
  solve      auto-apply the fix and wait for convergence
  teardown   remove the lab objects (leaves Crossplane core installed)

Environment:
  NS, ASSUME_YES=1, PROVIDER_NOP_IMAGE, FUNCTION_PNT_IMAGE, CROSSPLANE_CHART_VERSION
EOF
}

main() {
  case "${1:-break}" in
    break)    ensure_baseline; do_break; print_symptom ;;
    status)   show_status ;;
    solve)    do_solve; show_status ;;
    teardown) do_teardown ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: ${1}" ;;
  esac
}
main "$@"

# ============================================================================
#  SOLUTION — step by step  (read only after you have tried it yourself)
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  A Composition binds to exactly one Composite Resource type via
#  spec.compositeTypeRef {apiVersion, kind}. Crossplane will only use a
#  Composition for an XR whose GVK matches that reference. The fault set:
#
#      spec.compositeTypeRef.apiVersion: platform.cnpa.io/v1beta1
#
#  but the XRD serves and marks referenceable ONLY:
#
#      platform.cnpa.io/v1alpha1
#
#  The XR (created from the Claim) is of type v1alpha1. Because the referenced
#  Composition now advertises v1beta1, Crossplane's composite reconciler
#  "refuses to use" it — the XR reports Synced=False with a "not compatible /
#  does not match" event, no Composition Function runs, and no Managed Resource
#  is ever created. Every object still exists, so nothing is "gone" — the
#  provisioning pipeline is simply severed at the type boundary. This is the
#  common real-world version of the bug: someone bumps an XRD to a new version
#  (or hand-edits a Composition) and the two drift apart.
#
#  DIAGNOSIS
#  ---------
#   1. Follow SYNCED=False from the Claim down to the XR, and read its events:
#        kubectl get databaseinstance -n cnpa-lab
#        XR=$(kubectl get composite -o name | head -n1)
#        kubectl describe "$XR"
#      -> "refusing to use Composition ...: compositeTypeRef ... is not
#         compatible with this composite resource ..."
#
#   2. List the apiVersions the XRD really serves + marks referenceable:
#        kubectl get xrd xdatabaseinstances.platform.cnpa.io \
#          -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" ref="}{.referenceable}{"\n"}{end}'
#      -> v1alpha1 served=true ref=true      (there is NO v1beta1)
#
#   3. Read what the Composition claims to compose:
#        kubectl get composition xdatabaseinstances.platform.cnpa.io \
#          -o jsonpath='{.spec.compositeTypeRef.apiVersion}{"\n"}'
#      -> platform.cnpa.io/v1beta1           (the mismatch — root cause)
#
#  FIX (any one of these)
#  ----------------------
#   A. Targeted patch (fastest):
#        kubectl patch composition xdatabaseinstances.platform.cnpa.io --type=merge \
#          -p '{"spec":{"compositeTypeRef":{"apiVersion":"platform.cnpa.io/v1alpha1"}}}'
#
#   B. Edit interactively and set spec.compositeTypeRef.apiVersion back to
#      platform.cnpa.io/v1alpha1:
#        kubectl edit composition xdatabaseinstances.platform.cnpa.io
#
#   C. Re-apply a corrected manifest from Git (the GitOps-correct answer — the
#      cluster patch above should really land as a commit).
#
#  Note the *legitimate* alternative: if v1beta1 were genuinely intended, the
#  real fix would be on the XRD (add a v1beta1 version, served+referenceable,
#  with a conversion strategy) — but the objective here forbids editing the XRD,
#  which is the correct call for a hotfix: match the recipe to the published API.
#
#  VERIFY
#  ------
#        kubectl wait databaseinstance/orders-db -n cnpa-lab \
#          --for=condition=Ready --timeout=180s
#        kubectl get databaseinstance -n cnpa-lab          # SYNCED=True READY=True
#        kubectl get managed                               # a NopResource now exists
#
#  KRATIX — the same failure in the other tool (topic pairs Crossplane/Kratix)
#  --------------------------------------------------------------------------
#  Kratix models this as a Promise: a Promise bundles an api (the CRD it offers,
#  e.g. kind Database), a set of dependencies, and a workflow pipeline. The
#  equivalent break is a Promise whose api.kind / group / version drifts from
#  what the pipeline and requests expect, or a request submitted for a Promise
#  whose CRD was never installed. Symptom: `kubectl get promises` shows the
#  Promise present, but requests sit unfulfilled and the pipeline never runs;
#  `kubectl get databases` (the Promise's offered kind) returns "no matches for
#  kind" when the api block is wrong. Diagnosis mirrors Crossplane: reconcile
#  the offered API (Promise.spec.api) with what requesters and the pipeline use,
#  and confirm a Destination/StateStore exists to schedule the work to.
#  Ref: https://docs.kratix.io/main/reference/promises/intro
#
#  CLEAN UP
#  --------
#        $0 teardown
#        helm uninstall crossplane -n crossplane-system && kubectl delete ns crossplane-system
# ============================================================================