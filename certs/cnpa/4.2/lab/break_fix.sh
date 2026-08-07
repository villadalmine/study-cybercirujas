#!/usr/bin/env bash
#
# CNPA — Certified Cloud Native Platform Engineering Associate
# Exam version: 2025-04-01
# Domain 4 — Platform APIs and Provisioning
# Topic 4.2 — APIs for Self-Service Platforms (Custom Resource Definitions)  [weight 3.0]
#
# BREAK & FIX lab.
# This script publishes a tiny self-service platform API as a
# CustomResourceDefinition (CRD), proves an app team can use it, then injects a
# CONTROLLED FAULT into the CRD's OpenAPI v3 schema — the exact contract that
# lets teams self-serve. Your job: diagnose why the API server suddenly rejects
# previously-valid requests, and restore the contract.
#
# Official references:
#   - CNCF CNPA curriculum:
#       https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   - Extend the Kubernetes API with CustomResourceDefinitions:
#       https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
#   - Structural schemas (server-side validation of custom resources):
#       https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
#   - CRD versioning (served / storage / conversion):
#       https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
#   - kubectl explain (reads the published OpenAPI of any resource, incl. CRDs):
#       https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#explain
#
# !!  SAFETY: run this ONLY on a DISPOSABLE lab cluster (kind / minikube / k3s /
#     throwaway VM). It creates and mutates a CRD named 'widgets.platform.cnpa.io'
#     and a namespace 'platform-demo', and writes files under ~/cnpa-4.2-break.
#     It touches nothing else. Reset everything with:  bash break_fix.sh cleanup
#
set -euo pipefail

GROUP="platform.cnpa.io"
CRD="widgets.${GROUP}"
NS="platform-demo"
LAB_DIR="${CNPA_LAB_DIR:-${HOME}/cnpa-4.2-break}"

c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'
c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'
info(){ printf '%s[*]%s %s\n' "$c_blue"   "$c_reset" "$*"; }
ok(){   printf '%s[+]%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err(){  printf '%s[x]%s %s\n' "$c_red"    "$c_reset" "$*" >&2; }
step(){ printf '\n%s==== %s ====%s\n' "$c_blue" "$*" "$c_reset"; }

cleanup(){
  step "Cleanup"
  kubectl delete crd "${CRD}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "${LAB_DIR}"
  ok "Removed CRD ${CRD}, namespace ${NS}, and ${LAB_DIR}."
}

if [[ "${1:-}" == "cleanup" ]]; then cleanup; exit 0; fi

step "Preflight"
command -v kubectl >/dev/null 2>&1 || { err "kubectl not found in PATH."; exit 1; }
if ! kubectl cluster-info >/dev/null 2>&1; then
  err "No reachable Kubernetes cluster (kubectl cluster-info failed)."
  err "Start a disposable cluster first, e.g.:  kind create cluster --name cnpa-lab"
  exit 1
fi
ok "kubectl present; context: $(kubectl config current-context 2>/dev/null || echo unknown)"
mkdir -p "${LAB_DIR}"

step "Setup — publish the self-service API (the platform's source of truth in Git)"
# A structural OpenAPI v3 schema. This schema IS the public contract: the API
# server validates every write against it. Note the guard rails a platform team
# would expose to app teams: an allowed set of tiers and a bounded replica count.
cat >"${LAB_DIR}/widget-crd.yaml" <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.platform.cnpa.io
spec:
  group: platform.cnpa.io
  scope: Namespaced
  names:
    plural: widgets
    singular: widget
    kind: Widget
    shortNames: ["wg"]
    categories: ["platform"]
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: Tier
          type: string
          jsonPath: .spec.tier
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
        - name: Owner
          type: string
          jsonPath: .spec.owner
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                tier:
                  type: string
                  description: "Environment class the widget runs in."
                  enum: ["dev", "staging", "prod"]
                replicas:
                  type: integer
                  description: "Desired replica count (bounded guard rail)."
                  minimum: 1
                  maximum: 10
                  default: 1
                owner:
                  type: string
                  description: "Owning team; required for accountability."
              required: ["tier", "owner"]
            status:
              type: object
              properties:
                phase:
                  type: string
EOF

kubectl apply -f "${LAB_DIR}/widget-crd.yaml"
kubectl wait --for=condition=Established "crd/${CRD}" --timeout=60s >/dev/null
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "CRD published and Established; namespace ${NS} ready."

# An existing production Widget the app team already owns.
cat >"${LAB_DIR}/widget-checkout.yaml" <<'EOF'
apiVersion: platform.cnpa.io/v1
kind: Widget
metadata:
  name: checkout
  namespace: platform-demo
spec:
  tier: prod
  replicas: 3
  owner: team-payments
EOF

# A NEW production Widget another team wants to self-serve right now.
cat >"${LAB_DIR}/widget-search.yaml" <<'EOF'
apiVersion: platform.cnpa.io/v1
kind: Widget
metadata:
  name: search
  namespace: platform-demo
spec:
  tier: prod
  replicas: 3
  owner: team-search
EOF

info "App team applies a valid Widget (tier=prod, replicas=3) — this should succeed:"
kubectl apply -f "${LAB_DIR}/widget-checkout.yaml"
kubectl -n "${NS}" get widgets
ok "Self-service works: teams can create bounded prod Widgets through the API."

step "Introducing the fault"
warn "A platform engineer 'hardens' the LIVE CRD by hand — config drift vs Git."
# Two backward-INCOMPATIBLE contract changes applied straight to the served
# schema: drop 'prod' from the tier enum, and lower the replica ceiling to 2.
kubectl patch crd "${CRD}" --type=json -p '[
  {"op":"replace","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/tier/enum","value":["dev","staging"]},
  {"op":"replace","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/replicas/maximum","value":2}
]' >/dev/null
ok "Live CRD schema mutated; it no longer matches ${LAB_DIR}/widget-crd.yaml."

info "Re-running the app team's request now fails at admission (server-side validation):"
set +e
apply_out="$(kubectl apply -f "${LAB_DIR}/widget-checkout.yaml" 2>&1)"
set -e
printf '%s\n' "----------------- captured API server error -----------------" \
              "${apply_out}" \
              "-------------------------------------------------------------"

cat <<EOF

${c_yellow}================= BREAK & FIX BRIEFING =================${c_reset}

WHAT JUST HAPPENED
  The self-service API 'widgets.${GROUP}' is still installed, and existing
  objects are still readable (data lives in etcd; reads are not re-validated):

      kubectl -n ${NS} get widgets        # 'checkout' still shows up

  But every WRITE against it now fails. App teams can neither update existing
  Widgets nor create new ones, e.g.:

      kubectl apply -f ${LAB_DIR}/widget-checkout.yaml   # update -> rejected
      kubectl apply -f ${LAB_DIR}/widget-search.yaml     # new prod Widget -> rejected

SYMPTOM YOU WILL SEE
  Validation errors from the API server such as:
    * spec.tier: Unsupported value: "prod": supported values: "dev", "staging"
    * spec.replicas: Invalid value: 3: spec.replicas in body should be less than or equal to 2

  The manifests are correct and unchanged. The self-service *contract* moved.

YOUR GOAL
  Restore the platform API so BOTH of these succeed again, with tier=prod and
  replicas=3 accepted:

      kubectl apply -f ${LAB_DIR}/widget-checkout.yaml
      kubectl apply -f ${LAB_DIR}/widget-search.yaml
      kubectl -n ${NS} get widgets        # both Widgets present, TIER=prod

USEFUL DIAGNOSTICS (the CRD is the API — inspect the API)
  - kubectl explain widget.spec                     # the live, published contract
  - kubectl explain widget.spec.tier                # allowed values as the server sees them
  - kubectl get crd ${CRD} -o yaml                  # find spec.versions[0].schema...
  - diff <(kubectl get crd ${CRD} -o yaml) ${LAB_DIR}/widget-crd.yaml   # spot the drift

  Full reset if you want to start over:  bash break_fix.sh cleanup && bash break_fix.sh

${c_yellow}=======================================================${c_reset}
EOF

exit 0

# ============================================================================
#  SOLUTION (step by step) — reveal only after attempting the diagnosis.
# ============================================================================
#
#  0) Understand the failure class first.
#     A CRD's openAPIV3Schema is a real, versioned API contract, enforced by the
#     kube-apiserver on EVERY write (structural-schema / server-side validation).
#     Narrowing an enum and lowering a numeric maximum are backward-INCOMPATIBLE
#     changes: they reject resources that were valid a moment ago — including
#     objects already stored (reads still return them, writes/updates do not).
#     Nothing is wrong with the client manifests; the server-side contract drifted.
#
#  1) Confirm the symptom and that the objects still exist:
#       kubectl -n platform-demo get widgets
#       kubectl apply -f ~/cnpa-4.2-break/widget-checkout.yaml   # -> Invalid (tier/replicas)
#
#  2) Read the LIVE contract two ways and compare to the source of truth:
#       kubectl explain widget.spec.tier        # enum now shows only dev, staging
#       kubectl explain widget.spec.replicas    # maximum now 2
#       kubectl get crd widgets.platform.cnpa.io -o yaml \
#         | grep -nA3 -e 'enum:' -e 'maximum:'
#       diff <(kubectl get crd widgets.platform.cnpa.io -o yaml) \
#            ~/cnpa-4.2-break/widget-crd.yaml
#     You will see the served schema diverged from Git: enum lost "prod",
#     replicas.maximum dropped from 10 to 2.
#
#  3) Fix. Pick ONE:
#
#     Option A — reconcile to source of truth (preferred; this is what GitOps does):
#       kubectl apply -f ~/cnpa-4.2-break/widget-crd.yaml
#
#     Option B — targeted reverse patch (undo exactly the drift):
#       kubectl patch crd widgets.platform.cnpa.io --type=json -p '[
#         {"op":"replace","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/tier/enum","value":["dev","staging","prod"]},
#         {"op":"replace","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/replicas/maximum","value":10}
#       ]'
#
#     Option C — interactive edit:
#       kubectl edit crd widgets.platform.cnpa.io
#         # under spec.versions[0].schema.openAPIV3Schema.properties.spec.properties:
#         #   tier.enum:      [dev, staging, prod]
#         #   replicas.maximum: 10
#
#  4) Verify the self-service API is healthy again:
#       kubectl explain widget.spec.tier                      # prod is back
#       kubectl apply -f ~/cnpa-4.2-break/widget-checkout.yaml # updated OK
#       kubectl apply -f ~/cnpa-4.2-break/widget-search.yaml   # created OK
#       kubectl -n platform-demo get widgets                  # checkout + search, TIER=prod
#
#  5) Prevent the recurrence (platform-engineering takeaways):
#       - Treat CRD schema changes like any public API change: additive fields
#         and LOOSENED constraints are safe; tightening (narrower enums, lower
#         maxima, new required fields) breaks existing clients and stored objects.
#       - Keep CRDs in version control and roll them out through CI/GitOps; never
#         hand-edit a live CRD. Guard the schema with a validating admission
#         policy or PR review so drift like this cannot reach the served version.
#       - For genuinely breaking contract changes, introduce a NEW served version
#         (e.g. v1 -> v1beta2/v2) with served/storage flags and a conversion
#         strategy, and migrate clients — do not mutate a version teams depend on.
#
#  Cleanup when finished:
#       bash break_fix.sh cleanup
# ============================================================================