#!/usr/bin/env bash
#
# ==============================================================================
#  BREAK & FIX LAB  —  KCA (Kubernetes and Cloud Native Associate)
#  Topic 5.11: Common Expression Language (CEL)   ·   Exam weight: 2.91
# ==============================================================================
#
#  WHAT THIS TEACHES
#  -----------------
#  CEL is the in-process expression language Kubernetes uses to validate objects
#  without an external webhook: CRD validation rules (`x-kubernetes-validations`)
#  and, most prominently for the exam, ValidatingAdmissionPolicy (VAP). The one
#  rule that catches almost everyone is CEL's *admission polarity*:
#
#      A `validations[].expression` must evaluate to TRUE for the request to be
#      ADMITTED. It is the condition you REQUIRE, NOT the condition you reject.
#
#  This lab installs a VAP whose author confused the two. The result is an
#  inverted guard that rejects healthy Deployments and waves through the exact
#  ones it was written to stop. You will read the CEL, understand the polarity,
#  and repair the expression.
#
#  SAFETY
#  ------
#  * Run ONLY on a disposable lab VM / throwaway cluster (kind, minikube, k3s).
#  * The break is fully reversible and *namespace-scoped*: the policy Binding
#    only matches the labeled namespace `cel-lab`, so nothing else is affected.
#  * The symptom is demonstrated with `--dry-run=server`, which runs the full
#    admission chain (VAP included) WITHOUT creating a single Pod. No workloads
#    are ever persisted by this script.
#  * `bash cel-511-breakfix.sh cleanup` removes everything.
#
#  REQUIREMENTS
#  ------------
#  * kubectl with cluster admin, and a reachable cluster.
#  * Kubernetes >= 1.30 for the GA API (admissionregistration.k8s.io/v1).
#    1.28/1.29 work too if the ValidatingAdmissionPolicy feature gate + API are
#    enabled (v1beta1); the script auto-detects the version.
#
#  SOURCES (official)
#  ------------------
#  * KCA curriculum ....... https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#  * CEL in Kubernetes .... https://kubernetes.io/docs/reference/using-api/cel/
#  * ValidatingAdmissionPolicy
#                           https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
#  * CEL language spec .... https://github.com/google/cel-spec/blob/master/doc/langdef.md
#  * Live CEL playground .. https://playcel.undistro.io/
# ==============================================================================

set -euo pipefail

NS="cel-lab"
POLICY="cel-lab-replica-limit"
BINDING="cel-lab-replica-limit-binding"
LIMIT=5

# ------------------------------------------------------------------------------
# cleanup subcommand
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "cleanup" ]]; then
  echo ">> Tearing down the CEL lab ..."
  kubectl delete validatingadmissionpolicybinding "$BINDING" --ignore-not-found
  kubectl delete validatingadmissionpolicy        "$POLICY"  --ignore-not-found
  kubectl delete namespace "$NS" --ignore-not-found
  echo ">> Clean."
  exit 0
fi

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { echo "FATAL: kubectl not found."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "FATAL: no reachable cluster."; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
if printf '%s' "$CTX" | grep -qiE 'prod|production'; then
  echo "REFUSING TO RUN: current context '$CTX' looks like production."
  echo "Point kubectl at a disposable lab cluster and try again."
  exit 1
fi

echo "###############################################################"
echo "#  CEL Break & Fix  —  target context: $CTX"
echo "###############################################################"
if [[ "${CEL_LAB_CONFIRM:-}" != "yes" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "This will install a broken admission policy on '$CTX'. Type 'yes' to continue: " ANS
    [[ "$ANS" == "yes" ]] || { echo "Aborted."; exit 1; }
  else
    echo "Non-interactive shell: re-run with CEL_LAB_CONFIRM=yes to proceed."
    exit 1
  fi
fi

# Detect the ValidatingAdmissionPolicy API version available on this cluster.
if kubectl explain validatingadmissionpolicy --api-version=admissionregistration.k8s.io/v1 >/dev/null 2>&1; then
  VAP_APIVERSION="admissionregistration.k8s.io/v1"
elif kubectl explain validatingadmissionpolicy --api-version=admissionregistration.k8s.io/v1beta1 >/dev/null 2>&1; then
  VAP_APIVERSION="admissionregistration.k8s.io/v1beta1"
  echo "NOTE: using the beta API (admissionregistration.k8s.io/v1beta1)."
else
  echo "FATAL: ValidatingAdmissionPolicy API is not available on this cluster."
  echo "       You need Kubernetes >= 1.30 (GA), or 1.28/1.29 with the"
  echo "       ValidatingAdmissionPolicy feature gate + API server flags enabled."
  exit 1
fi
echo ">> Using API: $VAP_APIVERSION"

# ------------------------------------------------------------------------------
# SETUP: a guarded namespace
# ------------------------------------------------------------------------------
echo ">> Creating guarded namespace '$NS' ..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$NS" cel-lab=true --overwrite >/dev/null

# ------------------------------------------------------------------------------
# THE BREAK: install a ValidatingAdmissionPolicy with an INVERTED CEL guard.
#
# The author's intent was: "reject any Deployment with more than 5 replicas."
# They wrote the *reject* condition into the expression:  object.spec.replicas > 5
# But VAP ADMITS when the expression is TRUE, so this policy now only admits
# Deployments that exceed the limit, and denies every compliant one.
# ------------------------------------------------------------------------------
echo ">> Installing the (broken) ValidatingAdmissionPolicy ..."
kubectl apply -f - <<YAML >/dev/null
apiVersion: ${VAP_APIVERSION}
kind: ValidatingAdmissionPolicy
metadata:
  name: ${POLICY}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    # BUG IS ON THE NEXT LINE. This is the reject-condition, not the requirement.
    - expression: "object.spec.replicas > ${LIMIT}"
      message: "Deployment replicas must not exceed ${LIMIT}."
      reason: Invalid
YAML

kubectl apply -f - <<YAML >/dev/null
apiVersion: ${VAP_APIVERSION}
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: ${BINDING}
spec:
  policyName: ${POLICY}
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        cel-lab: "true"
YAML

echo ">> Waiting a moment for the policy to be indexed by the API server ..."
sleep 5

# ------------------------------------------------------------------------------
# DEMONSTRATE THE SYMPTOM (server-side dry-run: no Pods are created)
# ------------------------------------------------------------------------------
demo() {
  local title="$1" name="$2" replicas="$3"
  echo
  echo "----- ${title} (replicas=${replicas}) -----"
  set +e
  local out
  out="$(kubectl apply --dry-run=server -f - <<YAML 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  replicas: ${replicas}
  selector:
    matchLabels: { app: ${name} }
  template:
    metadata:
      labels: { app: ${name} }
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
YAML
)"
  local rc=$?
  set -e
  echo "$out"
  if [[ $rc -eq 0 ]]; then echo "==> RESULT: ADMITTED"; else echo "==> RESULT: DENIED"; fi
}

demo "Compliant Deployment (should be allowed)" web-good 3
demo "Over-limit Deployment (should be denied)" web-bad  8

# ------------------------------------------------------------------------------
# STUDENT BRIEFING
# ------------------------------------------------------------------------------
cat <<'BRIEF'

================================================================================
  BROKEN. Here is your assignment.
================================================================================

SYMPTOM
  * The compliant 3-replica Deployment was DENIED with:
        "Deployment replicas must not exceed 5."
  * The over-limit 8-replica Deployment was ADMITTED.
  The guard is doing the exact opposite of its stated purpose. Note that the
  namespace, RBAC and Deployment spec are all perfectly fine — the fault is in
  the CEL expression itself.

YOUR GOAL
  Repair the policy so that, in namespace 'cel-lab':
    * a Deployment with replicas <= 5  is ADMITTED, and
    * a Deployment with replicas  > 5  is DENIED with the same message.

VERIFY WITH (no Pods are created — server-side dry-run runs admission only):
    kubectl apply --dry-run=server -n cel-lab -f - <<'EOF'
    apiVersion: apps/v1
    kind: Deployment
    metadata: { name: web-good }
    spec:
      replicas: 3
      selector: { matchLabels: { app: web-good } }
      template:
        metadata: { labels: { app: web-good } }
        spec: { containers: [ { name: web, image: nginx:1.27-alpine } ] }
    EOF
  Then repeat with replicas: 8 and confirm it is denied.

HINTS
  1. Read the policy:
        kubectl get validatingadmissionpolicy cel-lab-replica-limit -o yaml
  2. Recall the ONE rule of CEL admission: the expression is the condition you
     REQUIRE to be TRUE, not the condition under which you reject.
  3. Prototype the expression against a sample object before you patch — paste
     a Deployment and your CEL into https://playcel.undistro.io/
  4. Also check `.status.typeChecking` on the policy for CEL type warnings:
        kubectl get validatingadmissionpolicy cel-lab-replica-limit \
          -o jsonpath='{.status.typeChecking}'

When finished, tidy up with:  bash cel-511-breakfix.sh cleanup
================================================================================
BRIEF


# ==============================================================================
#  SOLUTION  —  do not read until you have tried it yourself
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  CEL admission polarity. In a ValidatingAdmissionPolicy, the request is
#  ALLOWED when `validations[].expression` evaluates to `true`, and DENIED when
#  it is `false`. The author wrote the reject condition:
#
#        object.spec.replicas > 5        # true for the ones we WANTED to block
#
#  so the API server only admitted Deployments with more than 5 replicas and
#  denied everything at or below the limit. The required invariant — "replicas
#  must be at most 5" — is the logical inverse.
#
#  STEP 1 — Confirm the polarity mistake by reading the CEL:
#      kubectl get validatingadmissionpolicy cel-lab-replica-limit \
#        -o jsonpath='{.spec.validations[0].expression}{"\n"}'
#      # -> object.spec.replicas > 5
#
#  STEP 2 — Fix the expression to state the REQUIRED invariant, not the reject
#           condition. A JSON patch on the single field is the surgical fix:
#
#      kubectl patch validatingadmissionpolicy cel-lab-replica-limit \
#        --type='json' \
#        -p='[{"op":"replace","path":"/spec/validations/0/expression","value":"object.spec.replicas <= 5"}]'
#
#      Equivalently, re-apply the whole policy with the corrected line:
#
#          validations:
#            - expression: "object.spec.replicas <= 5"
#              message: "Deployment replicas must not exceed 5."
#              reason: Invalid
#
#  STEP 3 (hardening, optional but production-grade) — make the rule null-safe.
#          `spec.replicas` is an optional field; if it is absent the bare
#          comparison raises a CEL runtime error, and with `failurePolicy: Fail`
#          that becomes a denial. Guard the access with the has() macro so an
#          omitted value (which the apiserver defaults to 1) is treated as valid:
#
#          validations:
#            - expression: "!has(object.spec.replicas) || object.spec.replicas <= 5"
#              messageExpression: "'replicas ' + string(object.spec.replicas) + ' exceeds the limit of 5'"
#              reason: Invalid
#
#          (`messageExpression` is itself CEL and must return a string; it lets
#           the denial name the offending value. See the CEL reference above.)
#
#  STEP 4 — Re-verify. No Pods are created; dry-run exercises admission only:
#
#      # compliant -> admitted
#      kubectl apply --dry-run=server -n cel-lab -f - <<'EOF'
#      apiVersion: apps/v1
#      kind: Deployment
#      metadata: { name: web-good }
#      spec:
#        replicas: 3
#        selector: { matchLabels: { app: web-good } }
#        template:
#          metadata: { labels: { app: web-good } }
#          spec: { containers: [ { name: web, image: nginx:1.27-alpine } ] }
#      EOF
#
#      # over-limit -> denied with the policy message
#      #   (same manifest, replicas: 8)
#
#  STEP 5 — Clean up:
#      bash cel-511-breakfix.sh cleanup
#
#  TAKEAWAYS
#  ---------
#  * VAP expressions state what must be TRUE to ADMIT — always phrase the
#    invariant, never the violation.
#  * Optional fields need has()/default handling; a raw access on an absent key
#    is a runtime error that failurePolicy: Fail converts into a hard denial.
#  * `--dry-run=server` is the safe way to test admission logic: it runs CEL and
#    every other admission plugin without persisting the object.
# ==============================================================================