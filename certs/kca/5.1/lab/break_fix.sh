#!/usr/bin/env bash
#
# KCA — Topic 5.1: Validation Rules  (exam weight 2.91)
# Break & Fix lab — a broken CEL validation rule inside a CustomResourceDefinition.
#
# WHAT THIS TEACHES
#   A CustomResourceDefinition can embed CEL (Common Expression Language) "validation
#   rules" under `x-kubernetes-validations`. The kube-apiserver compiles them once and
#   evaluates them on every CREATE/UPDATE of a custom resource. A single wrong operator
#   silently rewrites the contract of your API: it rejects objects that are perfectly
#   valid and — the dangerous half — admits objects that are not. You will observe the
#   symptom, locate the offending expression, repair it, and prove both directions of
#   the fix (good object accepted, bad object rejected).
#
# OFFICIAL SOURCES
#   Validation rules (x-kubernetes-validations):
#     https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
#   CEL in the Kubernetes API:
#     https://kubernetes.io/docs/reference/using-api/cel/
#   KCA curriculum:
#     https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#
# REQUIREMENTS
#   Kubernetes >= 1.25 (CEL CRD validation is on by default; GA since v1.29) and kubectl.
#
# SAFETY MODEL
#   This script only ever touches resources it owns: one cluster-scoped CRD in the
#   private group `training.kca.local` and one namespace (`kca-lab-51`). It creates,
#   mutates and deletes nothing else. It is meant for a DISPOSABLE lab cluster
#   (kind / minikube / k3d / k3s / docker-desktop). Run `cleanup` to remove all traces.
#
# USAGE
#   ./5.1-validation-rules-breakfix.sh start     # break it + explain the mission
#   ./5.1-validation-rules-breakfix.sh verify    # grade your fix (idempotent)
#   ./5.1-validation-rules-breakfix.sh cleanup    # delete the CRD and namespace
#
set -euo pipefail

GROUP="training.kca.local"
CRD="labapps.${GROUP}"
NS="kca-lab-51"
APIVER="${GROUP}/v1"

# ----- pretty output (degrades gracefully with no TTY) -----------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  B="$(tput bold)"; R="$(tput setaf 1)"; G="$(tput setaf 2)"; Y="$(tput setaf 3)"; C="$(tput setaf 6)"; Z="$(tput sgr0)"
else
  B=""; R=""; G=""; Y=""; C=""; Z=""
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s== %s ==%s\n' "$B$C" "$*" "$Z"; }
ok()   { printf '%s[ OK ]%s %s\n' "$G" "$Z" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$R" "$Z" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$Y" "$Z" "$*"; }

# ----- preflight: refuse to run against something that looks like production --
preflight() {
  command -v kubectl >/dev/null 2>&1 || { bad "kubectl not found in PATH."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { bad "No reachable cluster (check your kubeconfig/context)."; exit 1; }
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo '?')"
  case "$ctx" in
    kind-*|minikube|k3d-*|k3s*|*docker-desktop*|*rancher-desktop*) : ;;
    *)
      warn "Current context '${ctx}' does not look like a throwaway lab cluster."
      warn "This lab installs and mutates a cluster-scoped CRD. Only continue on a disposable cluster."
      if [[ "${KCA_LAB_CONFIRM:-}" != "yes" ]]; then
        read -r -p "Type 'yes' to proceed on context '${ctx}': " ans
        [[ "$ans" == "yes" ]] || { say "Aborted. Set KCA_LAB_CONFIRM=yes to skip this prompt on a known-safe cluster."; exit 1; }
      fi
      ;;
  esac
}

# ----- the (intentionally BROKEN) CRD ----------------------------------------
# The first CEL rule below reads `self.minReplicas >= self.maxReplicas`. That is the
# planted defect: it enforces the OPPOSITE of what its own message promises.
apply_broken_crd() {
  kubectl apply -f - >/dev/null <<YAML
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD}
spec:
  group: ${GROUP}
  scope: Namespaced
  names:
    kind: LabApp
    plural: labapps
    singular: labapp
    shortNames: ["la"]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["image", "replicas", "minReplicas", "maxReplicas"]
              properties:
                image:       { type: string }
                replicas:    { type: integer, minimum: 0 }
                minReplicas: { type: integer, minimum: 0 }
                maxReplicas: { type: integer, minimum: 0 }
              x-kubernetes-validations:
                # >>> PLANTED BUG: operator is inverted (>= instead of <=) <<<
                - rule: "self.minReplicas >= self.maxReplicas"
                  message: "minReplicas must be less than or equal to maxReplicas"
                - rule: "self.replicas >= self.minReplicas && self.replicas <= self.maxReplicas"
                  message: "replicas must be within the range [minReplicas, maxReplicas]"
YAML
  kubectl wait --for=condition=Established "crd/${CRD}" --timeout=60s >/dev/null
  kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}" >/dev/null
}

# A syntactically and semantically VALID object: min(2) <= max(5), replicas(3) in range.
valid_cr() {
  cat <<YAML
apiVersion: ${APIVER}
kind: LabApp
metadata: { name: demo, namespace: ${NS} }
spec: { image: "nginx:1.27", replicas: 3, minReplicas: 2, maxReplicas: 5 }
YAML
}

# A genuinely INVALID object: min(5) > max(2). A correct rule MUST reject this.
invalid_cr() {
  cat <<YAML
apiVersion: ${APIVER}
kind: LabApp
metadata: { name: bad, namespace: ${NS} }
spec: { image: "nginx:1.27", replicas: 2, minReplicas: 5, maxReplicas: 2 }
YAML
}

# ----- START: break it, then brief the student -------------------------------
cmd_start() {
  preflight
  head "Provisioning the (broken) CRD"
  apply_broken_crd
  ok "Installed CRD ${C}${CRD}${Z} and namespace ${C}${NS}${Z}."

  head "Reproducing the symptom"
  say "Applying a LabApp that is obviously valid (minReplicas=2, maxReplicas=5, replicas=3):"
  say ""
  set +e
  local out; out="$(valid_cr | kubectl apply -f - 2>&1)"; local rc=$?
  set -e
  printf '  %s\n' "$out"
  say ""
  if [[ $rc -ne 0 ]]; then
    ok "Symptom reproduced: the API server REJECTED a valid object."
  else
    warn "Expected a rejection but the object was accepted. The CRD may already be patched."
  fi

  head "Your mission"
  cat <<TXT
  A team ships the CRD ${C}${CRD}${Z}. Users report that they cannot create LabApps at
  all: every apply is rejected with

      "${R}minReplicas must be less than or equal to maxReplicas${Z}"

  even when minReplicas IS less than maxReplicas (2 <= 5). Worse, an SRE noticed that a
  clearly broken object (minReplicas=5, maxReplicas=2) is ${R}accepted${Z} instead.

  The schema types are fine. The bug lives in the CEL ${B}validation rule${Z} itself — the
  expression under ${C}spec.versions[0].schema.openAPIV3Schema.properties.spec.x-kubernetes-validations${Z}.

  ${B}GOAL — make BOTH of these true at the same time:${Z}
    1. A valid LabApp   (minReplicas <= maxReplicas)  is ${G}ACCEPTED${Z}.
    2. An invalid LabApp (minReplicas >  maxReplicas)  is ${R}REJECTED${Z}
       with a message that matches what it actually enforces.

  ${B}Investigate with:${Z}
    kubectl get crd ${CRD} -o yaml | grep -n -A2 x-kubernetes-validations
    kubectl explain labapp.spec --recursive

  ${B}Edit the live CRD with:${Z}
    kubectl edit crd ${CRD}
  (CEL rules recompile on save; no apiserver restart is needed.)

  When you think it is fixed, grade yourself:
    $0 verify

  Tear the whole lab down with:
    $0 cleanup
TXT
}

# ----- VERIFY: grade the fix in both directions ------------------------------
cmd_verify() {
  preflight
  kubectl get crd "${CRD}" >/dev/null 2>&1 || { bad "CRD ${CRD} is not installed. Run: $0 start"; exit 1; }
  kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}" >/dev/null

  head "Grading your fix"
  local pass_valid=0 pass_invalid=0

  # Direction 1: a valid object MUST be accepted.
  kubectl delete labapp demo -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  set +e
  local o1; o1="$(valid_cr | kubectl apply -f - 2>&1)"; local r1=$?
  set -e
  if [[ $r1 -eq 0 ]]; then ok "Valid LabApp (min=2,max=5) was accepted."; pass_valid=1
  else bad "Valid LabApp was rejected — the rule is still too strict:"; printf '     %s\n' "$o1"; fi

  # Direction 2: an invalid object MUST be rejected.
  kubectl delete labapp bad -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  set +e
  local o2; o2="$(invalid_cr | kubectl apply -f - 2>&1)"; local r2=$?
  set -e
  if [[ $r2 -ne 0 ]]; then ok "Invalid LabApp (min=5,max=2) was rejected as it should be."; pass_invalid=1
  else bad "Invalid LabApp was ACCEPTED — the rule is inverted or missing."; fi

  # Leave the cluster clean regardless of outcome.
  kubectl delete labapp bad demo -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true

  head "Result"
  if [[ $pass_valid -eq 1 && $pass_invalid -eq 1 ]]; then
    ok "${B}${G}PASSED${Z} — the validation rule now accepts valid objects and rejects invalid ones."
    exit 0
  else
    bad "${B}Not yet.${Z} Both directions must hold. Re-read the rule with:"
    say "    kubectl get crd ${CRD} -o yaml | grep -n -A2 x-kubernetes-validations"
    exit 1
  fi
}

# ----- CLEANUP ----------------------------------------------------------------
cmd_cleanup() {
  preflight
  head "Removing the lab"
  kubectl delete crd "${CRD}" --ignore-not-found >/dev/null 2>&1 || true   # cascades to all LabApps
  kubectl delete namespace "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  ok "Deleted CRD ${CRD} and namespace ${NS}."
}

case "${1:-start}" in
  start)   cmd_start   ;;
  verify)  cmd_verify  ;;
  cleanup) cmd_cleanup ;;
  *) say "usage: $0 {start|verify|cleanup}"; exit 2 ;;
esac

# =============================================================================
#  SOLUTION — full walkthrough (do not read until you have tried it yourself)
# =============================================================================
#
#  STEP 1 — Confirm the symptom precisely.
#    Applying a valid object fails; an invalid one succeeds:
#
#      $ kubectl apply -f valid.yaml
#      The LabApp "demo" is invalid: spec: Invalid value: "object":
#        minReplicas must be less than or equal to maxReplicas
#
#    The types are correct (the apiserver got as far as running CEL), so the fault
#    is in a validation rule, not in the OpenAPI schema.
#
#  STEP 2 — Read the actual expressions, not just the messages.
#
#      $ kubectl get crd labapps.training.kca.local -o yaml | grep -n -A2 x-kubernetes-validations
#        x-kubernetes-validations:
#        - message: minReplicas must be less than or equal to maxReplicas
#          rule: self.minReplicas >= self.maxReplicas       <-- CONTRADICTS its own message
#        - message: replicas must be within the range [minReplicas, maxReplicas]
#          rule: self.replicas >= self.minReplicas && self.replicas <= self.maxReplicas
#
#    The message says "<=" but the rule enforces ">=". A CEL `rule` is the CONDITION
#    that must evaluate to TRUE for the object to be admitted. So this rule only admits
#    objects where minReplicas >= maxReplicas — the exact opposite of the intent, which
#    is why 2>=5 (false) is rejected and 5>=2 (true) is accepted. The second rule is fine.
#
#  STEP 3 — Fix the operator. Either edit in place:
#
#      $ kubectl edit crd labapps.training.kca.local
#      # change:  rule: self.minReplicas >= self.maxReplicas
#      # to:      rule: self.minReplicas <= self.maxReplicas
#
#    ...or re-apply the corrected manifest (idempotent):
#
#      kubectl apply -f - <<'EOF'
#      apiVersion: apiextensions.k8s.io/v1
#      kind: CustomResourceDefinition
#      metadata:
#        name: labapps.training.kca.local
#      spec:
#        group: training.kca.local
#        scope: Namespaced
#        names: { kind: LabApp, plural: labapps, singular: labapp, shortNames: ["la"] }
#        versions:
#          - name: v1
#            served: true
#            storage: true
#            schema:
#              openAPIV3Schema:
#                type: object
#                properties:
#                  spec:
#                    type: object
#                    required: ["image","replicas","minReplicas","maxReplicas"]
#                    properties:
#                      image:       { type: string }
#                      replicas:    { type: integer, minimum: 0 }
#                      minReplicas: { type: integer, minimum: 0 }
#                      maxReplicas: { type: integer, minimum: 0 }
#                    x-kubernetes-validations:
#                      - rule: "self.minReplicas <= self.maxReplicas"          # FIXED
#                        message: "minReplicas must be less than or equal to maxReplicas"
#                      - rule: "self.replicas >= self.minReplicas && self.replicas <= self.maxReplicas"
#                        message: "replicas must be within the range [minReplicas, maxReplicas]"
#      EOF
#
#    CEL rules are recompiled by the apiserver the moment the CRD is saved — there is
#    nothing to restart. Existing stored objects are only re-checked on their next write.
#
#  STEP 4 — Prove BOTH directions (this is exactly what `verify` automates):
#
#      $ kubectl -n kca-lab-51 apply -f valid.yaml      # min=2,max=5
#      labapp.training.kca.local/demo created            # accepted  ✅
#
#      $ kubectl -n kca-lab-51 apply -f invalid.yaml    # min=5,max=2
#      The LabApp "bad" is invalid: spec: Invalid value: "object":
#        minReplicas must be less than or equal to maxReplicas   # rejected ✅
#
#  WHY THIS MATTERS / EXAM TAKEAWAYS
#    * A CEL `rule` is a REQUIREMENT the object must satisfy, expressed as a boolean over
#      `self`. If it reads false, the write is denied. "Enforce X" means "rule: X".
#    * The `message` (or `messageExpression`) is documentation shown to the user — the
#      apiserver does NOT check that it agrees with the rule. A mismatch between the two
#      is the classic tell of an inverted or wrong expression, so read the rule, never
#      trust the message.
#    * Validation rules can fail SAFE (reject good input) or fail OPEN (admit bad input).
#      Always test both a passing and a failing sample; a rule that rejects everything and
#      a rule that accepts everything can look identical from a single test.
#    * Related knobs to know for KCA 5.1: `optionalOldSelf`/transition rules (compare
#      `self` to `oldSelf` on UPDATE), `messageExpression`, `reason`, `fieldPath`, the
#      per-rule cost budget, and how CRD `x-kubernetes-validations` differs from a
#      ValidatingAdmissionPolicy (cluster-wide CEL admission, also GA and CEL-based).
# =============================================================================