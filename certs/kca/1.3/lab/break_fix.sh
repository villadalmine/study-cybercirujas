#!/usr/bin/env bash
#
# =============================================================================
#  KCA — Topic 1.3: Admission Controllers
#  Break & Fix Lab:  "The webhook that ate the namespace"
# =============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  Admission controllers are the last gate in the API request pipeline, AFTER
#  authentication and authorization, and BEFORE an object is persisted to etcd:
#
#      kubectl -> AuthN -> AuthZ -> Mutating Admission -> Object Schema
#                                   Validation -> Validating Admission -> etcd
#
#  Two of those stages are extensible over the network via webhooks:
#  MutatingWebhookConfiguration and ValidatingWebhookConfiguration. Each webhook
#  carries a `failurePolicy`:
#
#      failurePolicy: Fail    -> if the API server cannot reach the webhook,
#                                the request is DENIED (fail-closed).
#      failurePolicy: Ignore  -> if unreachable, the request is ADMITTED
#                                (fail-open).
#
#  A ValidatingWebhookConfiguration with `failurePolicy: Fail` that points at a
#  Service which does not exist is one of the most common self-inflicted
#  outages in production Kubernetes: nothing can be created for the resources
#  the webhook intercepts, and the error blames a component the student did not
#  knowingly install.
#
#  Source (official curriculum): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#  Source (webhook reference):   https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
#  Source (admission plugins):   https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
#
#  THIS SCRIPT IS DESTRUCTIVE-BY-DESIGN. Run it ONLY on a disposable lab VM /
#  throwaway cluster (kind, minikube, k3s, k3d). It scopes the damage to a
#  single lab namespace via `namespaceSelector`, so the rest of the cluster
#  (including kube-system) keeps working — but do not run it on anything you
#  care about.
# =============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
LAB_NS="kca-lab-13"
LAB_LABEL_KEY="kca-lab"
LAB_LABEL_VAL="1.3"
WEBHOOK_CFG="kca-lab-13-deny-pods"
WEBHOOK_SVC="kca-lab-13-webhook"          # a Service that will NOT exist
WEBHOOK_NAME="deny.kca-lab.local"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
say()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Safety rails — refuse to run against anything that looks like production
# ------------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster (check your kubeconfig / current-context)."

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
NODE0="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"

say "Current context : ${CTX}"
say "First node      : ${NODE0}"

# Heuristic: allow known throwaway distros automatically; otherwise demand an
# explicit override so nobody bricks a shared cluster by reflex.
if [[ "${CTX}${NODE0}" =~ (kind|minikube|k3s|k3d|docker-desktop|colima) ]]; then
  : # looks like a local disposable cluster — proceed
elif [[ "${LAB_CONFIRM:-}" == "yes" ]]; then
  warn "LAB_CONFIRM=yes set — proceeding on a non-obvious cluster at your own risk."
else
  die "This does not look like a disposable lab cluster. If you are SURE this VM is throwaway, re-run with:  LAB_CONFIRM=yes $0"
fi

# ------------------------------------------------------------------------------
# STEP 0 — Baseline: prove the namespace is healthy BEFORE we break it
# ------------------------------------------------------------------------------
say "[0/2] Preparing a clean lab namespace and proving pods CAN be created..."

kubectl get ns "${LAB_NS}" >/dev/null 2>&1 || kubectl create ns "${LAB_NS}"
kubectl label ns "${LAB_NS}" "${LAB_LABEL_KEY}=${LAB_LABEL_VAL}" --overwrite >/dev/null

# Remove any leftover pods/webhook from a previous run so the lab is idempotent.
kubectl -n "${LAB_NS}" delete pod canary-before canary-after --ignore-not-found >/dev/null 2>&1 || true
kubectl delete validatingwebhookconfiguration "${WEBHOOK_CFG}" --ignore-not-found >/dev/null 2>&1 || true

if kubectl -n "${LAB_NS}" run canary-before --image=registry.k8s.io/pause:3.9 --restart=Never >/dev/null 2>&1; then
  say "Baseline OK: 'canary-before' was admitted. The namespace is healthy right now."
  kubectl -n "${LAB_NS}" delete pod canary-before --ignore-not-found >/dev/null 2>&1 || true
else
  die "Baseline FAILED before we even broke anything. Clean the lab namespace and retry."
fi

# ------------------------------------------------------------------------------
# STEP 1 — BREAK: install a fail-closed webhook aimed at a non-existent Service
# ------------------------------------------------------------------------------
say "[1/2] Installing a broken ValidatingWebhookConfiguration (fail-closed, no backend)..."

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: ${WEBHOOK_CFG}
  labels:
    ${LAB_LABEL_KEY}: "${LAB_LABEL_VAL}"
webhooks:
  - name: ${WEBHOOK_NAME}
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
    # failurePolicy: Fail == fail CLOSED. If the API server cannot reach the
    # webhook endpoint, it DENIES the request instead of letting it through.
    failurePolicy: Fail
    # Blast radius is contained to the lab namespace ONLY. kube-system and every
    # other namespace are untouched because their labels do not match.
    namespaceSelector:
      matchLabels:
        ${LAB_LABEL_KEY}: "${LAB_LABEL_VAL}"
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        operations: ["CREATE"]
        scope: Namespaced
    clientConfig:
      # This Service is never created. The webhook is therefore unreachable,
      # and because failurePolicy is Fail, every pod CREATE in the lab namespace
      # will be rejected.
      service:
        name: ${WEBHOOK_SVC}
        namespace: ${LAB_NS}
        path: /validate
        port: 443
YAML

# ------------------------------------------------------------------------------
# STEP 2 — Show the student the exact symptom they will have to diagnose
# ------------------------------------------------------------------------------
say "[2/2] Reproducing the symptom (attempting to create a pod in ${LAB_NS})..."

set +e
SYMPTOM="$(kubectl -n "${LAB_NS}" run canary-after --image=registry.k8s.io/pause:3.9 --restart=Never 2>&1)"
RC=$?
set -e

echo
warn "----- OBSERVED SYMPTOM -----"
echo "${SYMPTOM}"
warn "----------------------------"
echo
# Expected output looks like:
#
#   Error from server (InternalError): Internal error occurred: failed calling
#   webhook "deny.kca-lab.local": failed to call webhook: Post
#   "https://kca-lab-13-webhook.kca-lab-13.svc:443/validate?timeout=5s":
#   no endpoints available for service "kca-lab-13-webhook"
#
if [[ ${RC} -eq 0 ]]; then
  warn "Unexpected: the pod was admitted. Verify the namespace label matches the webhook selector and re-run."
fi

# ==============================================================================
#  YOUR MISSION, STUDENT
# ==============================================================================
cat <<'BRIEF'

============================================================================
 CHALLENGE — KCA 1.3 Admission Controllers
============================================================================

 SYMPTOM
   Nobody can create pods in the "kca-lab-13" namespace. Every attempt fails
   with an InternalError that mentions "failed calling webhook" and a Service
   with "no endpoints available". Deployments scaled into this namespace will
   sit at 0/N ready, and their ReplicaSet events will show the same webhook
   error. The rest of the cluster is unaffected.

 WHAT YOU MUST ACHIEVE  (success criteria)
   1. Explain, in one sentence, WHY new pods are being rejected — name the
      admission stage and the field that makes it fail-closed.
   2. Restore the ability to create pods in "kca-lab-13" WITHOUT disabling
      admission control cluster-wide and WITHOUT touching kube-apiserver flags.
   3. Prove it: `kubectl -n kca-lab-13 run fixed --image=registry.k8s.io/pause:3.9 --restart=Never`
      must return  "pod/fixed created".

 HINTS
   - The offending object is CLUSTER-SCOPED, not inside the namespace. You will
     not find it with `kubectl -n kca-lab-13 get ...`.
   - The API server is telling you the resource kind and the exact error in the
     symptom above. Read it literally.
   - There is a fast, blunt fix (remove the webhook) and a surgical fix (change
     its failurePolicy or point it at a real backend). A good SRE knows the
     difference and when each is appropriate.

 Do not scroll to the bottom of this script until you have tried.
============================================================================

BRIEF

exit 0

# ============================================================================
# ============================================================================
#  SOLUTION — step by step   (read only after you have attempted the challenge)
# ============================================================================
# ============================================================================
#
# ---------------------------------------------------------------------------
# 1) DIAGNOSE — read the error, then find the object it blames
# ---------------------------------------------------------------------------
# The error is:
#   failed calling webhook "deny.kca-lab.local": ... no endpoints available
#   for service "kca-lab-13-webhook"
#
# That single line tells you three things:
#   - the failure is at the VALIDATING ADMISSION stage (a "webhook"),
#   - the webhook is named "deny.kca-lab.local",
#   - its backing Service "kca-lab-13-webhook" has no ready endpoints.
#
# Webhook configurations are CLUSTER-SCOPED. List them:
#
#     kubectl get validatingwebhookconfigurations
#     # NAME                    WEBHOOKS   AGE
#     # kca-lab-13-deny-pods    1          2m
#
# Inspect the culprit and confirm the two fields that turn an unreachable
# backend into a hard outage:
#
#     kubectl get validatingwebhookconfiguration kca-lab-13-deny-pods -o yaml
#     # look for:
#     #   failurePolicy: Fail                 <-- fail-closed
#     #   clientConfig.service: kca-lab-13-webhook  (does not exist)
#
# Confirm the Service genuinely has no endpoints — this is the root cause,
# not the webhook itself:
#
#     kubectl -n kca-lab-13 get svc kca-lab-13-webhook
#     # Error from server (NotFound): services "kca-lab-13-webhook" not found
#     kubectl -n kca-lab-13 get endpoints kca-lab-13-webhook
#     # (empty / NotFound)
#
# ONE-SENTENCE ANSWER (success criterion #1):
#   "Pod CREATE is rejected because a ValidatingWebhookConfiguration with
#    failurePolicy: Fail points at a Service that has no endpoints, so the API
#    server, unable to reach the webhook, fails closed and denies the request."
#
# ---------------------------------------------------------------------------
# 2) FIX — pick the option that matches the situation
# ---------------------------------------------------------------------------
#
# OPTION A — Remove the broken webhook entirely (correct when the webhook was
#            never meant to be here / has no real backend). Fastest recovery:
#
#     kubectl delete validatingwebhookconfiguration kca-lab-13-deny-pods
#
# OPTION B — Make it fail-open instead of fail-closed (correct when the webhook
#            SHOULD exist but its backend is temporarily down and you must
#            unblock the namespace now). Surgical, reversible:
#
#     kubectl patch validatingwebhookconfiguration kca-lab-13-deny-pods \
#       --type=json \
#       -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
#
# OPTION C — Actually provide the missing backend (correct in real production:
#            the policy is legitimate and must keep enforcing). You would deploy
#            the admission webhook server as a Deployment, expose it with a
#            Service named exactly "kca-lab-13-webhook" on port 443 serving TLS,
#            and place its CA bundle in clientConfig.caBundle. Out of scope for
#            this lab, but this is the ONLY option that preserves the intended
#            control while restoring availability.
#
#   Production note: to avoid this class of outage, real webhooks either use
#   failurePolicy: Ignore for non-critical policy, and/or exclude control-plane
#   and system namespaces with a namespaceSelector such as
#     matchExpressions:
#       - { key: kubernetes.io/metadata.name, operator: NotIn,
#           values: [ kube-system ] }
#   and always set a small timeoutSeconds so a hung backend cannot stall the
#   API request path.
#
# ---------------------------------------------------------------------------
# 3) VERIFY — prove the namespace can create pods again (success criterion #3)
# ---------------------------------------------------------------------------
#
#     kubectl -n kca-lab-13 run fixed --image=registry.k8s.io/pause:3.9 --restart=Never
#     # pod/fixed created
#     kubectl -n kca-lab-13 get pod fixed
#     # NAME    READY   STATUS    RESTARTS   AGE
#     # fixed   1/1     Running   0          5s
#
# ---------------------------------------------------------------------------
# 4) CLEAN UP the lab
# ---------------------------------------------------------------------------
#
#     kubectl delete validatingwebhookconfiguration kca-lab-13-deny-pods --ignore-not-found
#     kubectl delete ns kca-lab-13 --ignore-not-found
#
# ============================================================================