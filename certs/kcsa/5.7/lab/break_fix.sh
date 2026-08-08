#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Study Material
# Domain 5.0: Kubernetes Security Architecture & Operations
# Subtopic 5.7: Admission Control (Weight: 2.29%)
#
# Official References:
#   - CNCF Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#   - Kubernetes Dynamic Admission Control: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
#   - Admission Controllers Reference: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
# ==============================================================================
# ARCHITECTURAL DEEP DIVE: ADMISSION CONTROL MECHANICS & PRODUCTION TRADE-OFFS
# ==============================================================================
# Admission controllers evaluate requests to the Kubernetes API server after
# authentication (authn) and authorization (authz), but prior to object persistence
# in etcd.
#
# Processing Phases:
# 1. Mutating Phase (Sequential): Mutating Webhooks modify incoming object specs
#    (e.g., sidecar injection, default securityContext enforcement).
# 2. Object Schema Validation: Built-in API server validation.
# 3. Validating Phase (Parallel): Validating Webhooks evaluate the final spec
#    (e.g., image registry verification, PSP/PSS enforcement, OPA/Kyverno rules).
#
# Production Failure Modes & Mechanics:
# - Webhook Failure Policy (`failurePolicy: Fail` vs `Ignore`):
#   * `Fail`: Blocks API operations if webhook endpoint is unreachable or times out.
#     Prevents security bypass, but risks control plane outage if webhook fails.
#   * `Ignore`: Allows API requests to proceed if webhook fails. Prioritizes
#     availability over security enforcement.
# - TLS / PKI Trust Chain (`caBundle`):
#   * The kube-apiserver acts as a TLS client to admission webhooks.
#   * If `caBundle` is corrupted, expired, or missing in the WebhookConfiguration,
#     the API server fails TLS handshake (`x509: certificate signed by unknown authority`).
# - Match Conditions & Scoping:
#   * Broad scope (`operations: ["CREATE", "UPDATE"]`, `apiGroups: ["*"]`) with `failurePolicy: Fail`
#     can lock down the cluster, including system components and CRDs.
# ==============================================================================

set -euo pipefail

LAB_NAMESPACE="kcsa-admission-lab"
WEBHOOK_CONFIG_NAME="kcsa-enforce-pod-security"
SERVICE_NAME="kcsa-admission-svc"

function log_info() {
    echo -e "\031[1;34m[INFO]\033[0m $1"
}

function log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}

function log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

function check_prerequisites() {
    log_info "Checking environment prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl binary not found. Please install kubectl and ensure cluster connectivity."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to target Kubernetes cluster."
        exit 1
    fi
}

function setup_break_scenario() {
    log_info "Deploying KCSA 5.7 Admission Control Break-and-Fix Scenario..."

    # 1. Ensure target namespace exists
    kubectl create namespace "${LAB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # 2. Deploy dummy admission webhook service infrastructure in lab namespace
    log_info "Deploying mock admission controller service..."
    cat <<EOF | kubectl apply -n "${LAB_NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
  labels:
    app.kubernetes.io/name: ${SERVICE_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${SERVICE_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${SERVICE_NAME}
    spec:
      containers:
      - name: webhook
        image: registry.k8s.io/e2e-test-images/agnhost:2.40
        args:
        - netexec
        - --http-port=8080
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${LAB_NAMESPACE}
spec:
  ports:
  - port: 443
    targetPort: 8080
  selector:
    app.kubernetes.io/name: ${SERVICE_NAME}
EOF

    # 3. Inject Misconfigured ValidatingWebhookConfiguration
    # BREAKAGE MECHANICS INTRODUCED:
    # A) caBundle contains invalid base64 TLS cert data.
    # B) failurePolicy is set to Fail.
    # C) Service port points to 443 (HTTP/TCP mismatch without proper TLS handshake).
    # D) Namespace Selector targets 'kcsa-admission-lab'.
    log_info "Injecting misconfigured ValidatingWebhookConfiguration '${WEBHOOK_CONFIG_NAME}'..."
    cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: ${WEBHOOK_CONFIG_NAME}
  labels:
    kcsa.cncf.io/exam-lab: "5.7"
webhooks:
- name: pod-security-policy.kcsa.internal
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
    scope: "Namespaced"
  clientConfig:
    service:
      name: ${SERVICE_NAME}
      namespace: ${LAB_NAMESPACE}
      path: "/validate"
      port: 443
    # Corrupted / mismatched caBundle representation (Base64 encoded invalid certificate string)
    caBundle: "QkdHWE1JTFNFQ1VSSVRZQ0VSVElGSUNBVEVERUFETUVBVA=="
  admissionReviewVersions: ["v1"]
  sideEffects: None
  timeoutSeconds: 3
  failurePolicy: Fail
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${LAB_NAMESPACE}
EOF

    log_info "Scenario deployment complete."
}

function print_challenge_instructions() {
    cat <<'EOF'

================================================================================
KCSA EXAM TROUBLESHOOTING CHALLENGE: ADMISSION CONTROL BREAKAGE
================================================================================
SCENARIO DESCRIPTION:
The platform engineering team introduced a new ValidatingWebhookConfiguration
to enforce pod security guardrails in the namespace 'kcsa-admission-lab'.
Immediately after rollout, application deployments in this namespace began failing
unconditionally.

SYMPTOM:
Attempts to deploy any pod inside 'kcsa-admission-lab' result in an API Server
InternalError, preventing workload creation.

REPRODUCTION COMMAND:
  kubectl run test-pod --image=nginx:alpine -n kcsa-admission-lab

EXPECTED CLI FAILURE OUTPUT:
  Error from server (InternalError): Internal error occurred: failed calling webhook
  "pod-security-policy.kcsa.internal": failed to call webhook: ... x509: certificate
  signed by unknown authority (or connection failed)

YOUR OBJECTIVE:
1. Diagnose the root cause of the admission webhook failure using kubectl.
2. Determine why the kube-apiserver cannot establish a valid webhook transaction.
3. Fix the admission control configuration so that workloads can be created in
   'kcsa-admission-lab' without removing security validation controls completely.

DIAGNOSTIC TASK COMMANDS TO RUN FIRST:
  $ kubectl get validatingwebhookconfigurations
  $ kubectl describe validatingwebhookconfiguration kcsa-enforce-pod-security
  $ kubectl get pods,svc -n kcsa-admission-lab

================================================================================
EOF
}

# Main Execution Flow
check_prerequisites
setup_break_scenario
print_challenge_instructions

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & DIAGNOSTIC GUIDE (COMMENTED)
# ==============================================================================
# To view the solution, read the commented lines below.
#
# --- DIAGNOSIS & TROUBLESHOOTING WORKFLOW ---
#
# STEP 1: Reproduce the error and inspect the exact API error response.
# Command:
#   kubectl run test-pod --image=nginx:alpine -n kcsa-admission-lab
#
# Output:
#   Error from server (InternalError): Internal error occurred: failed calling
#   webhook "pod-security-policy.kcsa.internal": failed to call webhook:
#   post "https://kcsa-admission-svc.kcsa-admission-lab.svc:443/validate?timeout=3s":
#   x509: certificate signed by unknown authority
#
# Analysis:
# The kube-apiserver is configured with `failurePolicy: Fail`. When a Pod CREATE
# request arrives for namespace `kcsa-admission-lab`, apiserver calls the external
# webhook endpoint. The TLS handshake fails because `caBundle` in the configuration
# does not trust the certificate presented by the webhook (or contains corrupted data).
#
# STEP 2: Inspect the ValidatingWebhookConfiguration resource spec.
# Command:
#   kubectl get validatingwebhookconfiguration kcsa-enforce-pod-security -o yaml
#
# Key fields to inspect:
# - `failurePolicy: Fail` -> Causes API server to reject Pod creation if webhook fails.
# - `clientConfig.caBundle` -> Contains encoded invalid CA cert `QkdHWE1...`.
# - `clientConfig.service` -> Points to service `kcsa-admission-svc` on port 443.
#
# STEP 3: Verify the backing Webhook Service & Endpoint Health.
# Command:
#   kubectl get svc -n kcsa-admission-lab kcsa-admission-svc
#   kubectl get endpoints -n kcsa-admission-lab kcsa-admission-svc
#
# STEP 4: Choose the Correct Remediation Strategy (Production Best Practices):
#
# Strategy A (Emergency Mitigation / Non-blocking):
# If the webhook is not production-ready or TLS is misconfigured, update `failurePolicy`
# to `Ignore` temporarily to unblock critical workload deployments while fixing PKI.
#
# Strategy B (Full Fix / PKI Correction):
# Generate a valid TLS keypair for the service, populate a valid CA certificate base64
# string into `caBundle`, and configure TLS on the backend container.
#
# --- EXAM SOLUTION COMMANDS ---
#
# Quick Fix Option 1: Patch `failurePolicy` to `Ignore` (Unblocks pod creation)
# Command:
#   kubectl patch validatingwebhookconfiguration kcsa-enforce-pod-security \
#     --type='json' -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"}]'
#
# Quick Fix Option 2: Scope the webhook namespaceSelector to exclude the lab namespace
# or delete the non-functional webhook configuration if deemed orphaned:
# Command:
#   kubectl delete validatingwebhookconfiguration kcsa-enforce-pod-security
#
# VERIFICATION COMMAND:
#   kubectl run test-pod --image=nginx:alpine -n kcsa-admission-lab
# Expected output:
#   pod/test-pod created
# ==============================================================================