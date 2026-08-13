#!/usr/bin/env bash
#
# KCA — Kyverno Certified Associate
# Topic 1.1  Kyverno Policies & Rules   (exam weight 4.51)
# Break & Fix lab — run ONLY on a disposable, single-node lab cluster.
#
# What this drills: how a Kyverno `validate` rule is evaluated at admission time,
# the difference between `Enforce` and `Audit`, validate patterns and wildcard
# anchors, and how an over-strict / wrong policy silently blocks rollouts even
# when the workload is compliant. Fixing it means editing the POLICY, not the app.
#
# Reference sources (official):
#   - Kyverno policies & rules:   https://kyverno.io/docs/policy-types/
#   - Writing validate rules:     https://kyverno.io/docs/policy-types/cluster-policy/validate/
#   - Wildcards / anchors:        https://kyverno.io/docs/policy-types/cluster-policy/validate/#anchors
#   - match / exclude:            https://kyverno.io/docs/policy-types/cluster-policy/match-exclude/
#   - Installation:               https://kyverno.io/docs/installation/
#   - CNCF KCA curriculum:        https://github.com/cncf/curriculum
#
set -euo pipefail

LAB_NS="kca-lab"
POLICY="require-team-label"
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.4}"
KYVERNO_INSTALL_URL="https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"

say()  { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!!! %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# cleanup mode:  ./break_fix.sh cleanup
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "cleanup" ]]; then
  say "Tearing the lab down"
  kubectl delete clusterpolicy "${POLICY}" --ignore-not-found
  kubectl delete ns "${LAB_NS}" --ignore-not-found
  echo "Kyverno itself was left installed. Remove it with:"
  echo "  kubectl delete -f ${KYVERNO_INSTALL_URL}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
command -v kubectl >/dev/null || { warn "kubectl not found in PATH"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { warn "No reachable cluster. Point KUBECONFIG at a disposable lab cluster."; exit 1; }

if ! kubectl get ns kyverno >/dev/null 2>&1; then
  say "Installing Kyverno ${KYVERNO_VERSION} (first run only)"
  kubectl create -f "${KYVERNO_INSTALL_URL}"
fi
say "Waiting for the Kyverno admission controller to be ready"
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s

# ---------------------------------------------------------------------------
# BREAK — apply a ClusterPolicy that enforces the WRONG label key.
# The org standard is the label `team`; this policy demands `app-team`.
# It is namespace-scoped to kca-lab so it can never brick the cluster.
# ---------------------------------------------------------------------------
say "Creating namespace ${LAB_NS}"
kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f -

say "Applying the (intentionally broken) ClusterPolicy '${POLICY}'"
cat <<'YAML' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Every Pod in kca-lab must carry the ownership label. INTENTIONAL BUG:
      it requires 'app-team', but the organisation standard is 'team'.
spec:
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-lab
      validate:
        # failureAction: Enforce  -> the request is REJECTED at admission.
        # (Legacy Kyverno < 1.13 used spec.validationFailureAction instead.)
        failureAction: Enforce
        message: "The label 'app-team' is required on all pods."
        pattern:
          metadata:
            labels:
              app-team: "?*"   # <-- BUG: wrong key. Should be 'team'. '?*' = one-or-more chars.
YAML

kubectl wait --for=condition=Ready "clusterpolicy/${POLICY}" --timeout=60s || true

say "Deploying a COMPLIANT workload (it carries the org-standard label team=payments)"
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: kca-lab
  labels:
    team: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        team: payments        # <-- correct org label, present on the Pod template
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
YAML

sleep 6

# ---------------------------------------------------------------------------
# SYMPTOM the student will observe
# ---------------------------------------------------------------------------
warn "SYMPTOM — the rollout is stuck even though the app is labelled correctly"
echo
echo "  \$ kubectl -n ${LAB_NS} get deploy web"
kubectl -n "${LAB_NS}" get deploy web || true
echo
echo "  \$ kubectl -n ${LAB_NS} get rs"
kubectl -n "${LAB_NS}" get rs || true
echo
echo "  \$ kubectl -n ${LAB_NS} get events --sort-by=.lastTimestamp | tail -n 5"
kubectl -n "${LAB_NS}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 5 || true

cat <<'BRIEF'

========================================================================
  YOUR MISSION
========================================================================
  Deployment web/kca-lab is 0/2 Ready. `kubectl apply` on the Deployment
  SUCCEEDED, but no Pods appear. The ReplicaSet keeps firing FailedCreate
  events: an admission webhook is denying every Pod.

  The workload is compliant with the company standard (label team=payments,
  present on the Pod template). So the Deployment is NOT the problem.

  Fix the rollout so that `web` reaches 2/2 Ready, WITHOUT:
    - deleting the ClusterPolicy,
    - switching it from Enforce to Audit,
    - editing the Deployment.
  In other words: correct the POLICY so it enforces the real label the
  organisation uses. Then prove the guardrail still rejects unlabelled Pods.

  Useful starting points:
    kubectl -n kca-lab describe rs
    kubectl get clusterpolicy require-team-label -o yaml
    kubectl -n kyverno logs deploy/kyverno-admission-controller | tail
========================================================================
BRIEF

exit 0

# ==========================================================================
#  SOLUTION — step by step  (read only after you have tried it yourself)
# ==========================================================================
#
#  ROOT CAUSE
#  ----------
#  Kyverno validate rules are evaluated by the admission webhook against the
#  resource being CREATED. Here the rule matches Pods in kca-lab. The Deployment
#  object itself is admitted (the rule doesn't match Deployments), which is why
#  `kubectl apply` returned success — but when the ReplicaSet controller tries to
#  create the Pods, the webhook rejects them. The policy demands the label
#  `app-team`, while the Pod template carries `team`. Different key -> the
#  `app-team: "?*"` pattern never matches -> Enforce denies the request.
#
#  1) Confirm the Pod really is compliant with the org standard 'team':
#       kubectl -n kca-lab get deploy web \
#         -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
#       # -> {"app":"web","team":"payments"}   the workload is fine.
#
#  2) Read WHY admission is failing (the exact rule + message):
#       kubectl -n kca-lab describe rs | sed -n '/Events/,$p'
#       # FailedCreate ... admission webhook "validate.kyverno.svc-fail" denied
#       # the request: ... validation error: The label 'app-team' is required on
#       # all pods. rule check-team-label failed.
#     Or straight from Kyverno:
#       kubectl -n kyverno logs deploy/kyverno-admission-controller | tail
#
#  3) Inspect the policy and spot the wrong key:
#       kubectl get clusterpolicy require-team-label \
#         -o jsonpath='{.spec.rules[0].validate.pattern.metadata.labels}{"\n"}'
#       # -> {"app-team":"?*"}   <-- should be {"team":"?*"}
#
#  4) FIX: correct the label key in the policy (message + pattern):
#       kubectl edit clusterpolicy require-team-label
#     ...changing both `app-team` occurrences to `team`. Or re-apply the fixed
#     manifest below:
#
#       apiVersion: kyverno.io/v1
#       kind: ClusterPolicy
#       metadata:
#         name: require-team-label
#       spec:
#         background: true
#         rules:
#           - name: check-team-label
#             match:
#               any:
#                 - resources:
#                     kinds: [Pod]
#                     namespaces: [kca-lab]
#             validate:
#               failureAction: Enforce
#               message: "The label 'team' is required on all pods."
#               pattern:
#                 metadata:
#                   labels:
#                     team: "?*"
#
#  5) No manual restart is needed. The ReplicaSet controller retries Pod
#     creation with backoff; once the corrected policy admits them, the rollout
#     heals on its own. Verify:
#       kubectl -n kca-lab rollout status deploy/web --timeout=90s
#       # deployment "web" successfully rolled out
#       kubectl -n kca-lab get pods
#       # 2x Running
#
#  6) PROVE the guardrail still works (you fixed the key, not disabled the rule):
#       kubectl -n kca-lab run bad --image=registry.k8s.io/pause:3.9 --restart=Never
#       # Error ... admission webhook denied the request: ... The label 'team'
#       # is required on all pods. rule check-team-label failed.
#       kubectl -n kca-lab run ok --image=registry.k8s.io/pause:3.9 \
#         --restart=Never --labels=team=payments   # admitted
#
#  WHY THIS MATTERS / ADVANCED NOTES
#  ---------------------------------
#   - Enforce vs Audit: with `failureAction: Audit` the Pods would have been
#     ALLOWED and the violation only recorded — the symptom would be a red
#     PolicyReport, not a stuck rollout:
#       kubectl -n kca-lab get policyreport -o wide
#     Never "fix" an Enforce block in production by flipping it to Audit or
#     deleting the policy — that removes the guardrail. Correct the rule.
#   - Wildcard anchors in validate patterns:
#       "?*"  = one or more characters (label must exist AND be non-empty)
#       "*"   = zero or more characters (label may be empty)
#       "?"   = exactly one character
#     See https://kyverno.io/docs/policy-types/cluster-policy/validate/#anchors
#   - Scope matters: this rule was namespace-scoped via match.namespaces so it
#     could never block kube-system / kyverno. An Enforce policy that matches Pods
#     cluster-wide with no exclude for system namespaces is a classic self-inflicted
#     outage — always exclude control-plane namespaces or scope the match.
#       https://kyverno.io/docs/policy-types/cluster-policy/match-exclude/
#
#  CLEAN UP
#  --------
#       ./break_fix.sh cleanup
# ==========================================================================