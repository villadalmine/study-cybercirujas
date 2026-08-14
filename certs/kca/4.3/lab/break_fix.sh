#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kubernetes and Cloud Native Associate
#  Domain 4: Cloud Native Security  ·  Topic 4.3
#  "Common Policy Settings for Kyverno Rules"   (exam weight: 3.33%)
# ============================================================================
#
#  BREAK & FIX LAB — controlled, safe, reversible.
#
#  WHAT THIS TEACHES
#  -----------------
#  Every Kyverno rule lives inside a Policy/ClusterPolicy whose *common
#  settings* decide HOW the rule behaves, independently of WHAT the rule
#  checks. The two most exam-relevant ones are:
#
#    * validationFailureAction:  Enforce | Audit
#         Enforce -> a violating request is BLOCKED at admission time.
#         Audit   -> the request is ADMITTED, and only a PolicyReport with a
#                    "fail" result is recorded. Nothing is blocked.
#      (In Kyverno >= 1.10 this can also be set per-rule as
#       spec.rules[].validate.failureAction; the policy-level field shown here
#       is the classic, still-supported form. Values are Capitalized;
#       the old lowercase enforce/audit are deprecated.)
#
#    * background:  true | false
#         Whether the rule is evaluated by the background scanner against
#         resources that ALREADY exist (not just new admission requests).
#
#    * match / exclude:  which resources the rule applies to (here we scope
#         the rule to a single lab namespace so the blast radius is tiny).
#
#  THE BREAK: we ship a ClusterPolicy that *looks* like a hard security
#  guardrail ("Pods must not run as root") but was configured with
#  validationFailureAction: Audit. It therefore blocks nothing — a classic
#  production misconfiguration where the security team believes root pods are
#  denied, yet they sail through.
#
#  Sources (official):
#    - Policy settings ....... https://kyverno.io/docs/writing-policies/policy-settings/
#    - Validate rules ........ https://kyverno.io/docs/writing-policies/validate/
#    - Installation .......... https://kyverno.io/docs/installation/
#    - require-run-as-nonroot  https://kyverno.io/policies/pod-security/restricted/require-run-as-non-root/
#
#  !!  RUN THIS ONLY ON A DISPOSABLE LAB CLUSTER (kind / minikube / k3s on a
#      throwaway VM). It installs Kyverno and creates a cluster-scoped policy.
# ============================================================================

set -euo pipefail

# --- Lab constants (unique names so cleanup is unambiguous) -----------------
NS="kca-4-3-lab"
POLICY="kca43-require-run-as-nonroot"
BAD_POD="root-app"
KYVERNO_MANIFEST="https://github.com/kyverno/kyverno/releases/latest/download/install.yaml"

info()  { printf '\n\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
rule()  { printf '\033[1;30m%s\033[0m\n' "----------------------------------------------------------------------"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not installed." >&2; exit 1; }
}

# --- Optional cleanup: `./break-fix-4.3.sh cleanup` -------------------------
if [[ "${1:-}" == "cleanup" ]]; then
  info "Reverting the lab..."
  kubectl delete clusterpolicy "$POLICY" --ignore-not-found
  kubectl delete namespace "$NS" --ignore-not-found
  ok "Lab objects removed. (Kyverno itself was left installed.)"
  exit 0
fi

# --- Preflight --------------------------------------------------------------
require kubectl
info "Checking cluster connectivity..."
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: no reachable cluster (check your kubeconfig)." >&2; exit 1; }
ok "Cluster reachable: $(kubectl config current-context)"

# --- Ensure Kyverno is present ----------------------------------------------
if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  info "Kyverno not found. Installing (server-side apply avoids the large-annotation limit)..."
  kubectl apply --server-side -f "$KYVERNO_MANIFEST"
  info "Waiting for the Kyverno control plane to become Available..."
  kubectl -n kyverno wait --for=condition=Available deploy --all --timeout=240s
  ok "Kyverno installed."
else
  ok "Kyverno already installed."
fi

# --- Lab namespace ----------------------------------------------------------
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Namespace '$NS' ready."

# ============================================================================
#  BREAK  —  ship the guardrail with the WRONG common policy setting
# ============================================================================
info "Applying the (mis)configured ClusterPolicy: validationFailureAction=Audit"
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: kca43-require-run-as-nonroot
  annotations:
    policies.kyverno.io/title: Require runAsNonRoot (KCA 4.3 lab)
spec:
  # ------------------------------------------------------------------ #
  #  COMMON POLICY SETTINGS (the subject of this topic)                 #
  # ------------------------------------------------------------------ #
  validationFailureAction: Audit   # <-- THE BUG: Audit only reports; it blocks nothing.
  background: true                 # also evaluate pre-existing pods in the background scan
  # ------------------------------------------------------------------ #
  rules:
    - name: check-run-as-non-root
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-4-3-lab     # scoped to the lab namespace only -> tiny blast radius
      validate:
        message: "Pods must set spec.securityContext.runAsNonRoot=true."
        pattern:
          spec:
            securityContext:
              runAsNonRoot: true
EOF
ok "Policy '$POLICY' created."

info "Now creating a Pod that clearly VIOLATES the rule (no securityContext -> runs as root)..."
if kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: root-app
  namespace: kca-4-3-lab
  labels:
    app: root-app
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
EOF
then
  warn "The root Pod was ADMITTED. Under a real Enforce guardrail it should have been DENIED."
fi

info "Letting the background scanner write its PolicyReport..."
sleep 8
rule
echo "PolicyReport for the lab namespace (note: result=fail, but the Pod is Running):"
kubectl get policyreports.wgpolicyk8s.io -n "$NS" -o wide 2>/dev/null || \
  kubectl get policyreport -n "$NS" -o wide 2>/dev/null || \
  warn "No report yet — the background scan may need a few more seconds."
echo
kubectl get pod "$BAD_POD" -n "$NS" -o wide || true
rule

# ============================================================================
#  BRIEFING FOR THE STUDENT
# ============================================================================
cat <<'BRIEF'

========================= YOUR MISSION (KCA 4.3) =========================

SYMPTOM YOU SEE
  - A ClusterPolicy named 'kca43-require-run-as-nonroot' exists and is meant
    to forbid Pods from running as root in the 'kca-4-3-lab' namespace.
  - Yet a Pod named 'root-app' with NO securityContext was created
    successfully and is Running.
  - `kubectl get policyreport -n kca-4-3-lab` shows a result of FAIL for that
    Pod... but nothing was blocked. The guardrail is decorative.

WHY (think about it before scrolling)
  - The rule logic is correct. The problem is a COMMON POLICY SETTING:
    the policy governs admission with validationFailureAction, and it is set
    to 'Audit'. Audit = report only, never block.

WHAT YOU MUST ACHIEVE (success criteria)
  1. Reconfigure the policy's common settings so that violating Pods are
     actively REJECTED at admission time (not merely reported).
  2. Prove it: deleting and recreating 'root-app' must now be DENIED by the
     Kyverno admission webhook with the policy's validation message.
  3. Prove you did not over-block: a COMPLIANT Pod (securityContext with
     runAsNonRoot: true, runAsUser: 1000) must still be admitted and Running.

HINTS
  - Inspect the setting:   kubectl get clusterpolicy kca43-require-run-as-nonroot -o yaml | grep -i failureAction
  - Docs:                  https://kyverno.io/docs/writing-policies/policy-settings/
  - After you change it, give the admission webhook a couple of seconds to
    reconcile before you re-test.

Reset the whole lab at any time with:   ./break-fix-4.3.sh cleanup
==========================================================================

BRIEF

exit 0

# ============================================================================
#  SOLUTION  —  step by step (uncomment / copy-paste to walk through it)
# ============================================================================
#
#  STEP 0 — Confirm the diagnosis: the rule is fine, the SETTING is wrong.
#
#     kubectl get clusterpolicy kca43-require-run-as-nonroot \
#       -o jsonpath='{.spec.validationFailureAction}{"\n"}'
#     # -> Audit        (this is why nothing is being blocked)
#
#  STEP 1 — Flip the common policy setting from Audit to Enforce.
#           A JSON-merge patch is the cleanest, idempotent way:
#
#     kubectl patch clusterpolicy kca43-require-run-as-nonroot \
#       --type merge \
#       -p '{"spec":{"validationFailureAction":"Enforce"}}'
#
#     # (Kyverno >= 1.10 equivalent, set per-rule instead of policy-wide:
#     #   kubectl patch clusterpolicy kca43-require-run-as-nonroot --type=json \
#     #     -p='[{"op":"add","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
#     # )
#
#  STEP 2 — Give the admission webhook a moment to reconcile the new setting.
#
#     sleep 5
#     kubectl get clusterpolicy kca43-require-run-as-nonroot \
#       -o jsonpath='{.spec.validationFailureAction}{"\n"}'   # -> Enforce
#
#  STEP 3 — Remove the pod that slipped through while the policy was in Audit.
#
#     kubectl delete pod root-app -n kca-4-3-lab
#
#  STEP 4 — Prove enforcement: recreating the violating Pod must now be DENIED.
#           (We expect a non-zero exit here — that is SUCCESS, not an error.)
#
#     kubectl run root-app -n kca-4-3-lab --image=busybox:1.36 \
#       --restart=Never -- sh -c 'sleep 3600'
#     # Expected output (admission is blocked):
#     #   Error from server: admission webhook "validate.kyverno.svc-fail"
#     #   denied the request:
#     #   resource Pod/kca-4-3-lab/root-app was blocked due to the following policies:
#     #   kca43-require-run-as-nonroot:
#     #     check-run-as-non-root: 'Pods must set spec.securityContext.runAsNonRoot=true.'
#
#  STEP 5 — Prove you did not over-block: a COMPLIANT Pod is still admitted.
#
#     kubectl apply -f - <<'YAML'
#     apiVersion: v1
#     kind: Pod
#     metadata:
#       name: good-app
#       namespace: kca-4-3-lab
#       labels: { app: good-app }
#     spec:
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 1000
#       containers:
#         - name: app
#           image: busybox:1.36
#           command: ["sh", "-c", "sleep 3600"]
#     YAML
#
#     kubectl wait --for=condition=Ready pod/good-app -n kca-4-3-lab --timeout=60s
#     kubectl get pod good-app -n kca-4-3-lab      # -> Running
#
#  RESULT
#     Violating Pod  -> DENIED at admission (Enforce working).
#     Compliant Pod  -> Running (scope/match correct, no over-blocking).
#     The single root cause was a common policy setting:
#     validationFailureAction Audit -> Enforce.
#
#  KEY TAKEAWAYS FOR THE EXAM
#     * validationFailureAction (or per-rule validate.failureAction) decides
#       Enforce (block) vs Audit (report-only). A "failing" PolicyReport under
#       Audit does NOT mean the request was blocked.
#     * background controls evaluation of already-existing resources by the
#       scanner; it does not affect admission-time blocking.
#     * match/exclude scope the rule — keep guardrails narrow while testing.
#
#  CLEANUP
#     ./break-fix-4.3.sh cleanup
# ============================================================================