#!/usr/bin/env bash
#
# ==============================================================================
#  CNPA — Cloud Native Platform Engineering Associate  (exam version 2025-04-01)
#  Domain 5: Platform Observability, Reliability & Security  — well, actually:
#  Topic 5.2: API-Driven Service Catalogs and Infrastructure Abstractions  (w=2.0)
# ------------------------------------------------------------------------------
#  BREAK & FIX LAB — "The golden path that the catalog advertises no longer
#                     validates against the provisioning API."
#
#  What this lab teaches (production-grade takeaways):
#    * A platform is a set of *APIs*, not scripts. In Kubernetes those APIs are
#      CustomResourceDefinitions (CRDs); in Crossplane they are XRDs
#      (CompositeResourceDefinitions). The CRD/XRD OpenAPI v3 schema IS the
#      contract between the platform team and its consumers.
#    * A *service catalog* advertises which self-service offerings ("golden
#      paths") exist. When the catalog and the provisioning API drift apart,
#      self-service silently breaks: developers get a hard validation rejection
#      even though nothing is "down".
#    * Changing a CRD/XRD schema is an API-breaking change. Removing an enum
#      value, adding a `required` field, or flipping `served:` are all ways a
#      well-meaning platform PR takes down the golden path.
#
#  This models — with plain CRDs so it runs on any throwaway cluster — exactly
#  what happens when you edit a Crossplane XRD in place: existing claims survive,
#  but new claims for the removed shape are refused by the API server.
#
#  SAFETY: designed for a DISPOSABLE lab VM + a DISPOSABLE kind cluster.
#          It creates its own kind cluster (kind-cnpa-lab) by default and touches
#          only the `cnpa-lab` namespace + two lab CRDs. It refuses to run against
#          a context whose name contains "prod". Nothing outside the lab is
#          modified. `cleanup` removes everything, including the kind cluster.
#
#  Sources (official):
#    * Kubernetes CustomResourceDefinitions
#      https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
#    * CRD versioning & schema evolution
#      https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#versions-in-customresourcedefinitions
#    * Crossplane — Composite Resource Definitions (XRDs) & Compositions
#      https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
#    * Open Service Broker API (the original API-driven catalog spec)
#      https://www.openservicebrokerapi.org/
#    * Backstage Software Catalog
#      https://backstage.io/docs/features/software-catalog/
#    * ValidatingAdmissionPolicy (CEL guardrails for schema/contract changes)
#      https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
#    * CNPA curriculum
#      https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ==============================================================================

set -euo pipefail

# --------------------------- configuration ------------------------------------
NS="cnpa-lab"
KIND_CLUSTER="cnpa-lab"                       # -> context "kind-cnpa-lab"
CRD_DB="databases.platform.acme.io"
CRD_OFFER="serviceofferings.catalog.platform.acme.io"
DEV_SA="app-developer"
DEV_USER="system:serviceaccount:${NS}:${DEV_SA}"
LAB_DIR="${LAB_DIR:-/tmp/cnpa-5.2-lab}"
GOLDEN="${LAB_DIR}/golden-path-db.yaml"
USE_KIND="${USE_KIND:-1}"                      # 1 = create/use a kind lab cluster

# --------------------------- logging helpers ----------------------------------
if [ -t 1 ]; then C_B=$'\e[1m'; C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""; fi
log()  { printf '%s[lab]%s %s\n'  "$C_C" "$C_0" "$*"; }
ok()   { printf '%s[ ok]%s %s\n'  "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[err]%s %s\n'  "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# --------------------------- preflight & safety -------------------------------
ensure_cluster() {
  need kubectl
  if command -v kind >/dev/null 2>&1 && [ "$USE_KIND" = "1" ]; then
    if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
      log "creating disposable kind cluster '${KIND_CLUSTER}' ..."
      kind create cluster --name "$KIND_CLUSTER" >/dev/null
    fi
    kubectl config use-context "kind-${KIND_CLUSTER}" >/dev/null
    ok "using disposable kind context: kind-${KIND_CLUSTER}"
  else
    local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
    [ -n "$ctx" ] || die "no kubectl context; start minikube/kind or set USE_KIND=1"
    case "$ctx" in
      *prod*|*production*) die "refusing to run against context '$ctx' (looks like prod)";;
    esac
    if [ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB:-no}" != "yes" ]; then
      die "kind not used and this is not confirmed disposable. Re-run with:
       I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes $0 $*"
    fi
    warn "operating on existing context '$ctx' (namespace ${NS} + lab CRDs only)"
  fi
  kubectl cluster-info >/dev/null 2>&1 || die "cluster unreachable"
}

# --------------------------- platform bootstrap -------------------------------
deploy_platform() {
  mkdir -p "$LAB_DIR"
  log "installing the platform APIs (service-catalog API + provisioning API) ..."

  # (1) The provisioning API: a self-service Database abstraction. The tier enum
  #     is the contract clause we will later break. This is the plain-CRD analog
  #     of a Crossplane XRD's openAPIV3Schema.
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.platform.acme.io
spec:
  group: platform.acme.io
  scope: Namespaced
  names:
    kind: Database
    plural: databases
    singular: database
    shortNames: [db]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: Engine
          type: string
          jsonPath: .spec.engine
        - name: Tier
          type: string
          jsonPath: .spec.tier
        - name: Size(Gi)
          type: integer
          jsonPath: .spec.sizeGi
        - name: Phase
          type: string
          jsonPath: .status.phase
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [engine, tier, sizeGi]
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql, redis]
                tier:
                  type: string
                  description: "Golden-path service tier advertised by the catalog"
                  enum: [standard, high-mem, gpu]
                sizeGi:
                  type: integer
                  minimum: 1
                  maximum: 1024
                team:
                  type: string
            status:
              type: object
              properties:
                phase:
                  type: string
YAML

  # (2) The service catalog API: cluster-scoped ServiceOffering objects that
  #     ADVERTISE which offerings exist (the OSB-API / Backstage-catalog analog).
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: serviceofferings.catalog.platform.acme.io
spec:
  group: catalog.platform.acme.io
  scope: Cluster
  names:
    kind: ServiceOffering
    plural: serviceofferings
    singular: serviceoffering
    shortNames: [offering]
  versions:
    - name: v1
      served: true
      storage: true
      additionalPrinterColumns:
        - {name: Engine, type: string, jsonPath: .spec.engine}
        - {name: Tier,   type: string, jsonPath: .spec.tier}
        - {name: Golden, type: boolean, jsonPath: .spec.golden}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [engine, tier]
              properties:
                engine: {type: string}
                tier:   {type: string}
                golden: {type: boolean}
                description: {type: string}
YAML

  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # (3) Seed the catalog. "postgres-standard" is the advertised golden path.
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: catalog.platform.acme.io/v1
kind: ServiceOffering
metadata:
  name: postgres-standard
spec:
  engine: postgres
  tier: standard
  golden: true
  description: "Managed PostgreSQL, standard tier — the recommended default."
---
apiVersion: catalog.platform.acme.io/v1
kind: ServiceOffering
metadata:
  name: postgres-high-mem
spec:
  engine: postgres
  tier: high-mem
  golden: false
  description: "Managed PostgreSQL, memory-optimized tier."
YAML

  # (4) Self-service RBAC: application developers may consume the provisioning
  #     API in their namespace. This proves the later failure is NOT an RBAC
  #     problem — it is an API-contract problem.
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: ${DEV_SA}, namespace: ${NS}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: db-self-service, namespace: ${NS}}
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["databases", "databases/status"]
    verbs: ["get","list","watch","create","update","patch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: db-self-service, namespace: ${NS}}
subjects:
  - {kind: ServiceAccount, name: ${DEV_SA}, namespace: ${NS}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: db-self-service}
YAML

  # (5) The golden-path claim the developer is expected to `kubectl apply`.
  cat > "$GOLDEN" <<YAML
# Golden path consumed straight from the catalog offering "postgres-standard".
apiVersion: platform.acme.io/v1alpha1
kind: Database
metadata:
  name: orders-db
  namespace: ${NS}
  labels:
    catalog.platform.acme.io/offering: postgres-standard
spec:
  engine: postgres
  tier: standard        # <- exactly what ServiceOffering/postgres-standard advertises
  sizeGi: 20
  team: payments
YAML

  ok "platform installed. catalog offering 'postgres-standard' advertises tier=standard."

  # (6) Baseline proof: as the developer, the golden path validates (server-side
  #     dry-run runs full admission/validation without persisting anything).
  log "baseline check: does the golden path validate as ${DEV_SA}? ..."
  if kubectl apply -f "$GOLDEN" --dry-run=server --as="$DEV_USER" >/dev/null 2>&1; then
    ok "baseline OK — self-service provisioning of the golden path works."
  else
    warn "baseline unexpectedly failed; inspect the cluster before continuing."
  fi
}

# --------------------------- the controlled break -----------------------------
break_it() {
  log "introducing a controlled API-contract regression on ${CRD_DB} ..."
  # A platform PR 'tightens' the provisioning API and drops the 'standard' tier
  # from the enum — WITHOUT updating the catalog. Existing objects are untouched;
  # only NEW claims for tier=standard are refused. This is exactly what an
  # in-place Crossplane XRD schema edit does to claims.
  kubectl patch crd "$CRD_DB" --type=json -p \
    '[{"op":"replace","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/tier/enum","value":["high-mem","gpu"]}]' \
    >/dev/null
  ok "break applied. The Database API now serves tier enum: [high-mem, gpu]."

  cat <<EOF

${C_B}================================  YOUR TASK  ================================${C_0}

  ${C_B}SCENARIO${C_0}
    You are the on-call platform engineer. A developer opens a ticket:
    "I followed the golden path from the service catalog and I can't create my
     database. Nothing is down — the API just rejects me."

  ${C_B}SYMPTOM you will see${C_0}
    Run the developer's exact command:

      kubectl apply -f ${GOLDEN} --as=${DEV_USER}

    and it fails with a hard admission/validation error, roughly:

      ${C_R}The Database "orders-db" is invalid: spec.tier: Unsupported value:${C_0}
      ${C_R}"standard": supported values: "high-mem", "gpu"${C_0}

    Meanwhile:
      * kubectl auth can-i create databases -n ${NS} --as=${DEV_USER}  ->  ${C_G}yes${C_0}
        (so it is NOT an RBAC problem)
      * kubectl get serviceoffering postgres-standard -o yaml
        still advertises  tier: standard, golden: true
        (the CATALOG and the PROVISIONING API disagree — contract drift)

  ${C_B}OBJECTIVE (definition of done)${C_0}
    Restore self-service so a developer can create the catalog's golden path
    through the platform API — WITHOUT abandoning the abstraction (no hand-
    crafting the underlying resources, no editing the developer's manifest to a
    different tier). The catalog and the provisioning API must agree again.

    Verify your fix with:

      ${C_B}$0 verify${C_0}

    It PASSES when 'orders-db' is created by ${DEV_SA} via the golden path.

  ${C_B}HINTS${C_0}
    * The error is a schema/enum rejection, not authorization.
    * Compare what the catalog advertises vs. what the live API accepts:
        kubectl get serviceoffering postgres-standard -o jsonpath='{.spec.tier}{"\n"}'
        kubectl get crd ${CRD_DB} \\
          -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.tier.enum}{"\n"}'
        kubectl explain database.spec.tier
    * Who changed the contract, and is the removal intentional or a regression?

  Stuck? The full step-by-step solution is at the very bottom of this script
  (commented out). Or apply it automatically with:  ${C_B}$0 solve${C_0}
  Tear everything down with:                         ${C_B}$0 cleanup${C_0}
${C_B}===========================================================================${C_0}

EOF
}

# --------------------------- verification -------------------------------------
verify() {
  need kubectl
  log "verifying as ${DEV_SA}: apply the catalog golden path for real ..."
  set +e
  out="$(kubectl apply -f "$GOLDEN" --as="$DEV_USER" 2>&1)"; rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    kubectl get databases.platform.acme.io -n "$NS" 2>/dev/null || true
    printf '\n%s[PASS]%s golden path provisioned via the platform API. Self-service restored.\n' "$C_G" "$C_0"
    return 0
  fi
  printf '\n%s[FAIL]%s the golden path is still rejected by the provisioning API:\n' "$C_R" "$C_0"
  printf '       %s\n' "$out"
  printf '       The catalog still advertises tier=standard; make the API accept it.\n'
  return 1
}

# --------------------------- reference fix ------------------------------------
solve() {
  need kubectl
  warn "applying the reference fix: reconcile the provisioning API with the catalog contract ..."
  kubectl patch crd "$CRD_DB" --type=json -p \
    '[{"op":"replace","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/tier/enum","value":["standard","high-mem","gpu"]}]' \
    >/dev/null
  ok "enum restored to [standard, high-mem, gpu]."
  verify
}

# --------------------------- teardown -----------------------------------------
cleanup() {
  need kubectl
  log "cleaning up lab resources ..."
  kubectl delete -f "$GOLDEN" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete crd "$CRD_DB" "$CRD_OFFER" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  if command -v kind >/dev/null 2>&1 && [ "$USE_KIND" = "1" ] \
     && kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    log "deleting disposable kind cluster '${KIND_CLUSTER}' ..."
    kind delete cluster --name "$KIND_CLUSTER" >/dev/null || true
  fi
  ok "cleanup complete."
}

# --------------------------- entrypoint ---------------------------------------
usage() {
  cat <<EOF
CNPA 5.2 — API-Driven Service Catalogs & Infrastructure Abstractions : break & fix

Usage: $0 [command]
  run       (default) provision the platform, prove baseline, then break it
  verify    check whether you have restored the golden path (PASS/FAIL)
  solve     apply the reference fix, then verify
  cleanup   remove the namespace, CRDs, lab files and the kind cluster

Env:
  USE_KIND=0   use the current kubectl context instead of a kind lab cluster
  LAB_DIR=...  where manifests are written (default: /tmp/cnpa-5.2-lab)
EOF
}

main() {
  case "${1:-run}" in
    run)     ensure_cluster "$@"; deploy_platform; break_it ;;
    verify)  ensure_cluster "$@"; verify ;;
    solve)   ensure_cluster "$@"; solve ;;
    cleanup) cleanup ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"

# ==============================================================================
#  ▼▼▼  SOLUTION — step by step (read only after you have tried)  ▼▼▼
# ------------------------------------------------------------------------------
#
#  ROOT CAUSE
#    The provisioning API (CRD databases.platform.acme.io) had its `spec.tier`
#    OpenAPI enum tightened from [standard, high-mem, gpu] to [high-mem, gpu].
#    The service catalog (ServiceOffering/postgres-standard) still advertises
#    tier=standard as the golden path. Catalog ↔ provisioning-API drift: the
#    self-service contract the developer was told to follow no longer validates.
#    Nothing is "down"; the API server correctly rejects an out-of-contract
#    value. Existing Database objects with tier=standard are unaffected because
#    enum validation runs on write, not on read.
#
#  STEP 1 — Reproduce and read the error precisely.
#      kubectl apply -f /tmp/cnpa-5.2-lab/golden-path-db.yaml \
#        --as=system:serviceaccount:cnpa-lab:app-developer
#    -> spec.tier: Unsupported value: "standard": supported values: "high-mem","gpu"
#    The message names the field and the accepted set: this is schema validation.
#
#  STEP 2 — Rule out RBAC (a common misdiagnosis for "can't create").
#      kubectl auth can-i create databases -n cnpa-lab \
#        --as=system:serviceaccount:cnpa-lab:app-developer      # -> yes
#    Authorization is fine; the request is rejected at *validation/admission*.
#
#  STEP 3 — Inspect the live API contract (the CRD is the source of truth).
#      kubectl explain database.spec.tier
#      kubectl get crd databases.platform.acme.io \
#        -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.tier.enum}{"\n"}'
#    -> ["high-mem","gpu"]   (note: "standard" is gone)
#
#  STEP 4 — Compare against what the catalog advertises.
#      kubectl get serviceoffering postgres-standard -o yaml
#    -> spec.tier: standard, spec.golden: true
#    Drift confirmed: the catalog promises a tier the provisioning API refuses.
#    (In Crossplane terms: the XRD schema was changed under a live claim shape.)
#
#  STEP 5 — Decide the correct reconciliation.
#    Two legitimate directions; pick by intent:
#      (A) The 'standard' tier is still valid  -> the CRD change was a regression.
#          Restore the contract (preferred here, matches the objective):
#            kubectl patch crd databases.platform.acme.io --type=json -p \
#              '[{"op":"replace",
#                 "path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/tier/enum",
#                 "value":["standard","high-mem","gpu"]}]'
#      (B) 'standard' is genuinely being deprecated -> then the *catalog* and all
#          consumers must be migrated first, and the API bumped to a NEW version
#          (v1alpha2) with a conversion webhook — never dropped in place under a
#          live golden path. Update ServiceOffering/postgres-standard (or retire
#          it) BEFORE removing the enum value, so the catalog never advertises an
#          offering the API cannot fulfil.
#    Because the objective is "restore the advertised golden path", use (A).
#
#  STEP 6 — Verify end-to-end as the developer.
#      kubectl apply -f /tmp/cnpa-5.2-lab/golden-path-db.yaml \
#        --as=system:serviceaccount:cnpa-lab:app-developer
#      kubectl get databases -n cnpa-lab
#    orders-db is created; self-service through the platform API is restored.
#    (Equivalent: ./this-script.sh verify  -> PASS)
#
#  STEP 7 — Prevent recurrence (platform-engineering guardrails).
#    * Treat CRD/XRD schema edits as API-breaking. Do additive-only changes;
#      remove fields/enum values only across a version bump + conversion webhook.
#      https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#versions-in-customresourcedefinitions
#    * Gate every CRD change in CI with `kubectl diff` and a policy check that
#      asserts: for each golden ServiceOffering, its tier ∈ Database.spec.tier
#      enum — so catalog/provisioning drift fails the pipeline, not the developer.
#    * Enforce it in-cluster with a ValidatingAdmissionPolicy (CEL) that blocks
#      shrinking the enum of a served CRD version.
#      https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
#    * Manage CRDs/XRDs via GitOps so the schema is declarative and drift like
#      this is auto-reverted (and reviewed) instead of hand-patched in prod.
#    * Crossplane analog: the XRD is the contract for every Claim/XR; evolve it
#      additively and version it — an in-place breaking edit rejects new claims
#      exactly as seen here.
#      https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
# ==============================================================================