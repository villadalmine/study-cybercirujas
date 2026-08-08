#!/usr/bin/env bash

# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Certification Lab
# Topic 1.3: Controls and Frameworks (Domain 1: Overview of Cloud Native Security)
# Exam Weight: 2.33%
#
# References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
# - Pod Security Admission: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-control/
# - NSA/CISA Kubernetes Hardening Guidance: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_V1.1.PDF
# - CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
# ==============================================================================
# 
# SCENARIO DESCRIPTION:
# As a Platform Security Architect, you are enforcing the NSA/CISA Hardening
# Guidance and CIS Kubernetes Benchmark controls. The Security Operations team
# applied Pod Security Admission (PSA) with the 'restricted' profile on the 
# namespace 'kcsa-controls-lab' to enforce mandatory security controls.
#
# However, right after applying the control framework, the production workload
# 'payment-processor' failed during deployment. The ReplicaSet is blocked by 
# the Kubernetes API Server admission controller because the pod template 
# violates multiple security policies defined in the Restricted PSS control.
#
# YOUR GOAL:
# 1. Inspect the admission controller errors and identify why the workload 
#    violates the Restricted Pod Security Standard (PSS).
# 2. Update the Deployment manifest to comply with the Restricted PSS control
#    framework without relaxing or removing the namespace security labels.
# 3. Ensure the deployment achieves 1/1 READY replicas and running status.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes for UI Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

NAMESPACE="kcsa-controls-lab"
DEPLOYMENT_NAME="payment-processor"

echo -e "${CYAN}${BOLD}======================================================================${NC}"
echo -e "${CYAN}${BOLD}  KCSA 1.3: Controls & Frameworks - Break & Fix Laboratory Setup ${NC}"
echo -e "${CYAN}${BOLD}======================================================================${NC}"

# Pre-flight Check: Ensure kubectl is installed and cluster is reachable
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERROR] 'kubectl' CLI binary not found in PATH. Please install kubectl.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[ERROR] Unable to communicate with Kubernetes API Server. Check kubeconfig.${NC}"
    exit 1
fi

# Cleanup flag execution
if [[ "${1:-}" == "--cleanup" ]]; then
    echo -e "${YELLOW}[CLEANUP] Removing lab namespace '${NAMESPACE}'...${NC}"
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
    echo -e "${GREEN}[CLEANUP] Laboratory environment clean.${NC}"
    exit 0
fi

echo -e "${BLUE}[STEP 1/3] Preparing clean isolated namespace: '${NAMESPACE}'...${NC}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

echo -e "${BLUE}[STEP 2/3] Applying Security Control Framework (PSA Restricted Enforce Label)...${NC}"
# Enforce NSA/CISA & CIS Benchmark Pod Security Standard: Restricted
kubectl label --overwrite namespace "${NAMESPACE}" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest > /dev/null

echo -e "${BLUE}[STEP 3/3] Deploying insecure workload template to trigger policy failure...${NC}"

# Apply non-compliant workload manifest
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: checkout-system
    security.kcsa.cncf/framework: nsa-cisa-v1.1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      containers:
      - name: api-server
        image: nginx:alpine-slim
        ports:
        - containerPort: 80
        # Insecure container context missing mandatory PSS control enforcement
        securityContext:
          privileged: false
          allowPrivilegeEscalation: true
EOF

echo -e "\n${RED}${BOLD}[LAB STATE: BROKEN]${NC}"
echo -e "${YELLOW}Security Control Framework applied successfully, but the workload rollout is blocked.${NC}\n"

echo -e "${BOLD}--- STUDENT SYMPTOMS & DIAGNOSTIC SUMMARY ---${NC}"
echo -e "1. ${BOLD}Target Namespace:${NC} ${NAMESPACE}"
echo -e "2. ${BOLD}Deployment Name:${NC} ${DEPLOYMENT_NAME}"
echo -e "3. ${BOLD}Observed Behavior:${NC} Deployment exists, but AVAILABLE pods = 0."
echo -e "4. ${BOLD}Diagnostic Hints:${NC}"
echo -e "   - Run: ${CYAN}kubectl get pods -n ${NAMESPACE}${NC} (Notice no pods are created)"
echo -e "   - Run: ${CYAN}kubectl get rs -n ${NAMESPACE}${NC} (Check ReplicaSet creation status)"
echo -e "   - Run: ${CYAN}kubectl describe rs -n ${NAMESPACE}${NC} (Inspect API Server Admission rejection messages)"
echo -e "   - Run: ${CYAN}kubectl get events -n ${NAMESPACE} --field-selector reason=FailedCreate${NC}"
echo -e ""
echo -e "${BOLD}--- RELEVENT SECURITY CONTROL REQUIREMENTS (PSS Restricted Profile) ---${NC}"
echo -e "To satisfy NSA/CISA Hardening & CIS Kubernetes Benchmark Controls:"
echo -e "  - ${BOLD}seccompProfile:${NC} Must be explicitly set to 'RuntimeDefault' or 'Localhost'."
echo -e "  - ${BOLD}runAsNonRoot:${NC} Must be set to 'true' (Pod or Container level)."
echo -e "  - ${BOLD}allowPrivilegeEscalation:${NC} Must be set to 'false'."
echo -e "  - ${BOLD}capabilities:${NC} Must explicitly drop 'ALL' capabilities (e.g. drop: ['ALL'])."
echo -e "  - ${BOLD}readOnlyRootFilesystem:${NC} Recommended/Required for immutable root fs."
echo -e ""
echo -e "${GREEN}${BOLD}Task:${NC} Fix the Deployment manifest in namespace '${NAMESPACE}' so it complies with"
echo -e "the Restricted Pod Security Standard without removing the namespace security labels."
echo -e "To tear down the lab later, execute: ${CYAN}$0 --cleanup${NC}\n"


# ==============================================================================
#                              STEP-BY-STEP SOLUTION
# ==============================================================================
# (The complete solution below is commented out to prevent auto-solving)
#
# ------------------------------------------------------------------------------
# TECHNICAL EXPLANATION & ARCHITECTURE TRADE-OFFS:
# ------------------------------------------------------------------------------
# Pod Security Admission (PSA) is the built-in Kubernetes admission controller
# that enforces Pod Security Standards (PSS). PSS defines three levels:
# 1. Privileged: Unrestricted execution (default for system workloads).
# 2. Baseline: Minimizes known privilege escalations with default settings.
# 3. Restricted: Heavily hardened profile aligning with CIS & NSA/CISA benchmarks.
#
# When a namespace is labeled with 'pod-security.kubernetes.io/enforce=restricted',
# the API server validates all incoming Pod creation requests against PSS.
# Deployment objects are accepted by the API server because PSA evaluates Pods,
# not Deployments. The failure occurs asynchronously when the Deployment's 
# ReplicaSet controller attempts to create underlying Pods.
#
# To comply with the Restricted profile, the Pod template MUST include:
# 1. spec.securityContext.seccompProfile.type = "RuntimeDefault"
# 2. spec.securityContext.runAsNonRoot = true
# 3. spec.securityContext.runAsUser = 10001 (or any non-zero UID)
# 4. spec.template.spec.containers[*].securityContext.allowPrivilegeEscalation = false
# 5. spec.template.spec.containers[*].securityContext.capabilities.drop = ["ALL"]
#
# ------------------------------------------------------------------------------
# RECOVERY STEPS:
# ------------------------------------------------------------------------------
#
# Step 1: Diagnose the exact policy violation from ReplicaSet events
# $ kubectl describe rs -n kcsa-controls-lab
#
# Expected output showing admission rejection:
#   Warning  FailedCreate  10s  replicaset-controller  Error creating: pods "payment-processor-..." 
#   is forbidden: violates PodSecurity "restricted:latest": 
#   allowPrivilegeEscalation != false (container "api-server" must set allowPrivilegeEscalation=false), 
#   unrestricted capabilities (container "api-server" must set securityContext.capabilities.drop=["ALL"]), 
#   runAsNonRoot != true (pod or container "api-server" must set securityContext.runAsNonRoot=true), 
#   seccompProfile (pod or container "api-server" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
#
# Step 2: Apply the fully compliant, hardened manifest
#
# cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-processor
#   namespace: kcsa-controls-lab
#   labels:
#     app.kubernetes.io/name: payment-processor
#     app.kubernetes.io/part-of: checkout-system
#     security.kcsa.cncf/framework: nsa-cisa-v1.1
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: payment-processor
#   template:
#     metadata:
#       labels:
#         app: payment-processor
#     spec:
#       # Pod-level security context satisfying PSS Restricted controls
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: api-server
#         image: nginx:alpine-slim
#         ports:
#         - containerPort: 8080
#         # Container-level security context satisfying PSS Restricted controls
#         securityContext:
#           allowPrivilegeEscalation: false
#           readOnlyRootFilesystem: false # Set true if ephemeral volumes are mounted
#           capabilities:
#             drop:
#             - ALL
# EOF
#
# Step 3: Validate successful rollout and compliance
# $ kubectl rollout status deployment/payment-processor -n kcsa-controls-lab
# Expected output: deployment "payment-processor" successfully rolled out
#
# $ kubectl get pods -n kcsa-controls-lab
# Expected output:
# NAME                                 READY   STATUS    RESTARTS   AGE
# payment-processor-674b9d7994-x9z2p   1/1     Running   0          15s
# ==============================================================================