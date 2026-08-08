#!/usr/bin/env bash
# ==============================================================================
# CNCF CNPE (Certified Cloud Native Platform Engineer) Exam Study Material
# Topic 3.4: Using Policy Engines and Admission Controllers for Governance
# Curriculum Ref: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# Weight: 3
# Author: Principal Platform Architect & Senior SRE Instructor
# ==============================================================================
# LAB SCENARIO: Admission Controller Webhook Lockout & Broken Policy Mechanics
# 
# ARCHITECTURAL CONTEXT & PRODUCTION MECHANICS:
# Dynamic Admission Control in Kubernetes relies on Mutating and Validating Webhook
# configurations registered via the `admissionregistration.k8s.io/v1` API group.
# When an API request passes authentication and authorization, the API Server's
# admission control phase executes built-in plugins followed by external webhooks.
#
# CRITICAL FAILURE MODES IN PRODUCTION:
# 1. Unscoped Webhook Match Rules & Unhandled Failures:
#    If a `ValidatingWebhookConfiguration` has `failurePolicy: Fail` and an empty
#    or overly broad `namespaceSelector`, any outage of the webhook backend (or DNS/
#    network timeouts) will lock out all API mutations across the entire cluster,
#    including system namespaces like `kube-system`.
#
# 2. Unsafe Expression Evaluation in Policy Engines (CEL / Rego):
#    Native Kubernetes `ValidatingAdmissionPolicy` (v1/v1alpha1/v1beta1) uses
#    Common Expression Language (CEL). In CEL, dereferencing optional or nested
#    object fields (e.g., `c.securityContext.runAsNonRoot`) without testing field
#    existence via `has()` causes runtime evaluation errors, rejecting valid pods
#    or crashing admission reviews.
# ==============================================================================

set -euo pipefail

# ANSI Color Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

LAB_NAMESPACE="governance-lab"
WEBHOOK_CONFIG_NAME="governance-policy-webhook"
VAP_NAME="require-non-root-user-policy"
VAPB_NAME="require-non-root-user-binding"

print_header() {
    echo -e "${CYAN}==============================================================================${NC}"
    echo -e "${BOLD}$1${NC}"
    echo -e "${CYAN}==============================================================================${NC}"
}

check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: 'kubectl' CLI tool is not installed or not in PATH.${NC}"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}ERROR: Unable to connect to a valid Kubernetes cluster.${NC}"
        echo -e "${YELLOW}Please ensure your local Kubeconfig is set up (kind, minikube, or k3s).${NC}"
        exit 1
    fi
}

break_environment() {
    print_header "INJECTING CONTROLLED PRODUCTION FAILURE (BREAKING LAB)"
    check_prerequisites

    echo -e "${YELLOW}[1/4] Preparing lab namespace: ${LAB_NAMESPACE}...${NC}"
    kubectl create namespace "${LAB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${YELLOW}[2/4] Injecting Faulty ValidatingWebhookConfiguration...${NC}"
    # BUG 1: failurePolicy set to Fail
    # BUG 2: Target service port is 9443 (nothing listening) & selector is empty (locks ALL namespaces)
    cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: "${WEBHOOK_CONFIG_NAME}"
  labels:
    platform.cncf.io/governance: "true"
webhooks:
  - name: "policy.governance.platform.cncf"
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
        scope:       "Namespaced"
    clientConfig:
      service:
        name: "governance-policy-backend"
        namespace: "${LAB_NAMESPACE}"
        path: "/validate"
        port: 9443
      caBundle: "Q2VydGlmaWNhdGVGYWtlRGF0YQ=="
    failurePolicy: Fail
    sideEffects: None
    admissionReviewVersions: ["v1"]
    namespaceSelector: {}
EOF

    echo -e "${YELLOW}[3/4] Injecting Faulty ValidatingAdmissionPolicy (CEL Evaluation Bug)...${NC}"
    # BUG 3: CEL expression directly evaluates c.securityContext.runAsNonRoot without checking has(c.securityContext)
    # This panics on pods where securityContext is omitted.
    cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "${VAP_NAME}"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)"
      message: "Security Policy Error: Containers must explicitly set runAsNonRoot to true."
EOF

    cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "${VAPB_NAME}"
spec:
  policyName: "${VAP_NAME}"
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: "${LAB_NAMESPACE}"
EOF

    echo -e "${YELLOW}[4/4] Triggering failure validation check...${NC}"
    echo ""
    print_symptoms
}

print_symptoms() {
    print_header "LAB SCENARIO SYMPTOMS & STUDENT OBJECTIVE"
    echo -e "${BOLD}SRE / Platform Incident Report:${NC}"
    echo -e "An emergency alert was raised by platform teams: All pod deployments and namespace operations"
    echo -e "are failing cluster-wide with webhook connectivity timeouts and CEL policy evaluation panics."
    echo ""
    echo -e "${BOLD}Observed Error Output when creating workloads:${NC}"
    echo -e "${RED}  Error from server (InternalError): Internal error occurred: failed calling webhook"
    echo -e "  \"policy.governance.platform.cncf\": failed to call webhook: post \"https://...:9443\": dial tcp: connect: connection refused${NC}"
    echo ""
    echo -e "${BOLD}Your Objectives:${NC}"
    echo -e " 1. Identify the cluster-wide admission webhook intercepting control plane operations."
    echo -e " 2. Configure proper ${CYAN}namespaceSelector${NC} exclusions so system namespaces (e.g., ${CYAN}kube-system${NC}) are spared from platform policy failure."
    echo -e " 3. Adjust ${CYAN}failurePolicy${NC} to ${CYAN}Ignore${NC} (or restore valid endpoint service) so webhook outages do not block cluster API operations."
    echo -e " 4. Fix the CEL expression in ${CYAN}ValidatingAdmissionPolicy/${VAP_NAME}${NC} so that containers without explicit ${CYAN}securityContext${NC} blocks are evaluated safely using ${CYAN}has()${NC} checks without throwing evaluation errors."
    echo -e " 5. Verify that valid pods with non-root security context can be created successfully in namespace ${CYAN}${LAB_NAMESPACE}${NC}."
    echo ""
    echo -e "${BOLD}Useful Diagnostic Commands:${NC}"
    echo -e "  kubectl get validatingwebhookconfigurations"
    echo -e "  kubectl describe validatingwebhookconfiguration ${WEBHOOK_CONFIG_NAME}"
    echo -e "  kubectl get validatingadmissionpolicies"
    echo -e "  kubectl describe validatingadmissionpolicy ${VAP_NAME}"
    echo -e "  kubectl run test-pod --image=nginx -n ${LAB_NAMESPACE}"
    echo ""
    echo -e "Run ${BOLD}./break_fix.sh --check${NC} when you believe you have resolved the issue."
}

check_solution() {
    print_header "VERIFYING STUDENT SOLUTION"
    check_prerequisites

    local ERRORS=0

    echo -e "${YELLOW}[1/3] Checking ValidatingWebhookConfiguration configuration...${NC}"
    if ! kubectl get validatingwebhookconfiguration "${WEBHOOK_CONFIG_NAME}" &> /dev/null; then
        echo -e "${GREEN}  ✓ Webhook configuration has been deleted or cleaned up.${NC}"
    else
        FAIL_POLICY=$(kubectl get validatingwebhookconfiguration "${WEBHOOK_CONFIG_NAME}" -o jsonpath='{.webhooks[0].failurePolicy}')
        NS_SELECTOR=$(kubectl get validatingwebhookconfiguration "${WEBHOOK_CONFIG_NAME}" -o jsonpath='{.webhooks[0].namespaceSelector}')

        if [[ "${FAIL_POLICY}" == "Fail" && ( "${NS_SELECTOR}" == "{}" || -z "${NS_SELECTOR}" ) ]]; then
            echo -e "${RED}  ✗ Webhook '${WEBHOOK_CONFIG_NAME}' still has failurePolicy: Fail without system namespace exclusions!${NC}"
            ERRORS=$((ERRORS + 1))
        else
            echo -e "${GREEN}  ✓ Webhook failurePolicy or namespaceSelector correctly configured.${NC}"
        fi
    fi

    echo -e "${YELLOW}[2/3] Testing pod creation with CEL ValidatingAdmissionPolicy...${NC}"
    
    # Test Pod manifest with proper securityContext
    cat <<EOF | kubectl apply -n "${LAB_NAMESPACE}" -f - &> /tmp/pod_test.log || true
apiVersion: v1
kind: Pod
metadata:
  name: platform-test-workload
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
  containers:
  - name: test-app
    image: registry.k8s.io/pause:3.9
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
EOF

    if grep -q "created" /tmp/pod_test.log; then
        echo -e "${GREEN}  ✓ Successfully deployed valid non-root workload in ${LAB_NAMESPACE}.${NC}"
    else
        echo -e "${RED}  ✗ Pod creation failed. Log output:${NC}"
        cat /tmp/pod_test.log
        ERRORS=$((ERRORS + 1))
    fi

    echo -e "${YELLOW}[3/3] Testing pod creation WITHOUT securityContext (verifying CEL null-safety)...${NC}"
    cat <<EOF | kubectl apply -n "${LAB_NAMESPACE}" -f - &> /tmp/pod_null_test.log || true
apiVersion: v1
kind: Pod
metadata:
  name: platform-unspecified-workload
spec:
  containers:
  - name: test-app
    image: registry.k8s.io/pause:3.9
EOF

    # If the policy safely denies without throwing CEL evaluation InternalError, it is correct.
    if grep -q "CEL" /tmp/pod_null_test.log || grep -q "Internal error" /tmp/pod_null_test.log; then
        echo -e "${RED}  ✗ CEL expression threw a runtime evaluation error! Check missing has() guard logic.${NC}"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}  ✓ CEL expression evaluated safely without runtime errors.${NC}"
    fi

    # Cleanup temporary test pods
    kubectl delete pod platform-test-workload platform-unspecified-workload -n "${LAB_NAMESPACE}" --ignore-not-found &> /dev/null || true
    rm -f /tmp/pod_test.log /tmp/pod_null_test.log

    echo ""
    if [[ ${ERRORS} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}==============================================================================${NC}"
        echo -e "${GREEN}${BOLD}CONGRATULATIONS! You have successfully resolved the Governance & Admission issue!${NC}"
        echo -e "${GREEN}${BOLD}==============================================================================${NC}"
        exit 0
    else
        echo -e "${RED}${BOLD}==============================================================================${NC}"
        echo -e "${RED}${BOLD}VERIFICATION FAILED: Found ${ERRORS} unresolved issue(s). Please try again.${NC}"
        echo -e "${RED}${BOLD}==============================================================================${NC}"
        exit 1
    fi
}

cleanup_environment() {
    print_header "CLEANING UP LAB RESOURCES"
    check_prerequisites

    echo -e "${YELLOW}Deleting namespace ${LAB_NAMESPACE}...${NC}"
    kubectl delete namespace "${LAB_NAMESPACE}" --ignore-not-found

    echo -e "${YELLOW}Deleting ValidatingWebhookConfiguration ${WEBHOOK_CONFIG_NAME}...${NC}"
    kubectl delete validatingwebhookconfiguration "${WEBHOOK_CONFIG_NAME}" --ignore-not-found

    echo -e "${YELLOW}Deleting ValidatingAdmissionPolicy and Binding...${NC}"
    kubectl delete validatingadmissionpolicybinding "${VAPB_NAME}" --ignore-not-found
    kubectl delete validatingadmissionpolicy "${VAP_NAME}" --ignore-not-found

    echo -e "${GREEN}Lab environment successfully cleaned up.${NC}"
}

# CLI Router
case "${1:-}" in
    --break)
        break_environment
        ;;
    --check)
        check_solution
        ;;
    --status)
        print_symptoms
        ;;
    --clean)
        cleanup_environment
        ;;
    *)
        echo -e "${BOLD}Usage:${NC} $0 {--break|--check|--status|--clean}"
        echo -e "  ${CYAN}--break${NC}  Inject the governance failure scenario into your cluster"
        echo -e "  ${CYAN}--check${NC}  Verify your fix against the verification tests"
        echo -e "  ${CYAN}--status${NC} View incident symptoms and objective description"
        echo -e "  ${CYAN}--clean${NC}  Remove lab resources and reset cluster"
        exit 1
        ;;
esac

# ==============================================================================
# STEP-BY-STEP SOLUTION (DO NOT READ UNTIL YOU HAVE ATTEMPTED THE FIX)
# ==============================================================================
#
# STEP 1: Diagnose the Webhook Outage
# ------------------------------------
# Run:
#   kubectl get validatingwebhookconfigurations
#   kubectl describe validatingwebhookconfiguration governance-policy-webhook
#
# Observation:
#   Notice 'failurePolicy: Fail' and 'namespaceSelector: {}'.
#   The webhook service 'governance-policy-backend' on port 9443 does not exist,
#   causing connection refused errors on ALL pod operations cluster-wide.
#
# STEP 2: Remediate the ValidatingWebhookConfiguration
# ----------------------------------------------------
# Update the webhook configuration to use 'failurePolicy: Ignore' OR restrict
# namespace scope so system namespaces like 'kube-system' are excluded using
# matchExpressions:
#
#   kubectl edit validatingwebhookconfiguration governance-policy-webhook
#
# Modify the spec as follows:
#   failurePolicy: Ignore
#   namespaceSelector:
#     matchExpressions:
#     - key: kubernetes.io/metadata.name
#       operator: NotIn
#       values: ["kube-system", "kube-public", "kube-node-lease"]
#
# STEP 3: Diagnose the CEL Policy Runtime Error
# ----------------------------------------------
# Run:
#   kubectl describe validatingadmissionpolicy require-non-root-user-policy
#
# Observation:
#   The expression: "object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)"
#   fails with an evaluation error when 'securityContext' is nil/undefined on a container.
#
# STEP 4: Fix the CEL Expression for Safe Dereferencing
# ----------------------------------------------------
# Edit the policy:
#   kubectl edit validatingadmissionpolicy require-non-root-user-policy
#
# Update the validations expression to use 'has()' guards:
#   validations:
#     - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)"
#       message: "Security Policy Error: Containers must explicitly set runAsNonRoot to true."
#
# STEP 5: Verify the Fix
# ----------------------
# Run:
#   ./break_fix.sh --check
# ==============================================================================