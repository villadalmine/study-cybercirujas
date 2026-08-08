#!/usr/bin/env bash

# ==============================================================================
# CNCF KCSA Certification Preparation - Topic 3.2: Pod Security Admissions
# Break & Fix Interactive Laboratory Script
#
# Official Documentation References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - K8s Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
# - K8s Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
# - Configure Pod Security Admission: https://kubernetes.io/docs/tasks/configure-pod-security-admission/
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

echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${BLUE}${BOLD}    KCSA Lab 3.2: Pod Security Admissions (PSA) - Break & Fix Scenario${NC}"
echo -e "${BLUE}${BOLD}======================================================================${NC}"

# ------------------------------------------------------------------------------
# 1. Environment Verification
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[1/4] Verifying prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERROR] 'kubectl' command line tool was not found in PATH.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[ERROR] Unable to communicate with Kubernetes cluster via kubectl.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Kubernetes API Server is reachable.${NC}"

# ------------------------------------------------------------------------------
# 2. Inject Breakage Scenario #1: Restricted Namespace Admission Rejection
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[2/4] Injecting Breakage Scenario #1 (Restricted PSS Admission Failure)...${NC}"

# Ensure clean slate for namespace
kubectl create namespace finance-app --dry-run=client -o yaml | kubectl apply -f -

# Enforce 'restricted' Pod Security Standard on namespace
kubectl label --overwrite namespace finance-app \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/audit-version=latest > /dev/null

# Deploy non-compliant workload into the restricted namespace
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: finance-api
  namespace: finance-app
  labels:
    app.kubernetes.io/name: finance-api
    app.kubernetes.io/part-of: finance-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: finance-api
  template:
    metadata:
      labels:
        app: finance-api
    spec:
      containers:
      - name: api
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
EOF

# ------------------------------------------------------------------------------
# 3. Inject Breakage Scenario #2: Invalid PSA Namespace Label Syntax
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[3/4] Injecting Breakage Scenario #2 (Invalid PSA Label Configuration)...${NC}"

kubectl create namespace analytics-tier --dry-run=client -o yaml | kubectl apply -f -

# Inject invalid label syntax and non-existent version
kubectl label --overwrite namespace analytics-tier \
    pod-security.kubernetes.io/enforce=super-restricted-invalid \
    pod-security.kubernetes.io/enforce-version=v1.999 > /dev/null

# ------------------------------------------------------------------------------
# 4. Scenario Briefing & Diagnostics Prompt
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[4/4] Breakage injection complete!${NC}"

echo -e "\n${RED}${BOLD}======================================================================${NC}"
echo -e "${RED}${BOLD}                     LAB INCIDENT BRIEFING                            ${NC}"
echo -e "${RED}${BOLD}======================================================================${NC}"
echo -e "${YELLOW}SYMPTOM REPORT:${NC}"
echo -e "  1. The SRE team reports that Deployment 'finance-api' in namespace 'finance-app'"
echo -e "     shows 0/2 READY replicas. The API server accepted the Deployment object, but"
echo -e "     no Pods are actively running in the namespace."
echo -e "  2. Security audit tools flagged namespace 'analytics-tier' as having invalid"
echo -e "     Pod Security Admission (PSA) label values, causing fallback warnings in audit logs."
echo -e ""
echo -e "${YELLOW}STUDENT OBJECTIVES:${NC}"
echo -e "  [Objective A] Diagnose why Pods fail to create in namespace 'finance-app'."
echo -e "                Update the 'finance-api' Deployment manifest so its Pod template"
echo -e "                complies with the 'restricted' Pod Security Standard profile"
echo -e "                WITHOUT relaxing or removing namespace PSA labels."
echo -e "  [Objective B] Correct the invalid PSA labels on namespace 'analytics-tier'."
echo -e "                Set enforce level to 'baseline' (latest) and warn/audit to 'restricted' (latest)."
echo -e ""
echo -e "${YELLOW}RECOMMENDED DIAGNOSTIC COMMANDS:${NC}"
echo -e "  - Inspect Deployment status:     ${BOLD}kubectl get deployment -n finance-app${NC}"
echo -e "  - Inspect ReplicaSet events:     ${BOLD}kubectl describe replicaset -n finance-app${NC}"
echo -e "  - Inspect Namespace PSA labels:  ${BOLD}kubectl get ns analytics-tier --show-labels${NC}"
echo -e "  - Test dry-run admission check:  ${BOLD}kubectl label ns finance-app pod-security.kubernetes.io/enforce=restricted --dry-run=server${NC}"
echo -e "${RED}${BOLD}======================================================================${NC}\n"

exit 0

# ==============================================================================
#                           SOLUTION PASO A PASO / STEP-BY-STEP SOLUTION
# ==============================================================================
#
# Reference Links:
# - Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
# - Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
#
# ------------------------------------------------------------------------------
# STEP 1: Diagnose Objective A (finance-app Pod Creation Failure)
# ------------------------------------------------------------------------------
# 1. Check Deployment status in finance-app namespace:
#    kubectl get deployments -n finance-app
#    (Output shows 0/2 READY)
#
# 2. List Pods to check execution state:
#    kubectl get pods -n finance-app
#    (Output shows "No resources found in finance-app namespace." - indicates controller layer failure)
#
# 3. Inspect ReplicaSet status and event stream:
#    kubectl describe replicaset -n finance-app
#
# Expected Error Output in ReplicaSet Events:
#   FailedCreate: pods "finance-api-..." is forbidden: violates Pod Security Standard "restricted:latest":
#     * allowPrivilegeEscalation != false (container "api" must set securityContext.allowPrivilegeEscalation=false)
#     * unrestricted capabilities (container "api" must set securityContext.capabilities.drop=["ALL"])
#     * runAsNonRoot != true (pod or container "api" must set securityContext.runAsNonRoot=true)
#     * seccompProfile (pod or container "api" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
#
# ------------------------------------------------------------------------------
# STEP 2: Fix Objective A (Harden Pod Spec for Restricted PSS Profile)
# ------------------------------------------------------------------------------
# To satisfy the 'restricted' Pod Security Standard profile, update the Deployment
# manifest to add mandatory pod-level and container-level securityContext parameters:
#
# Apply the hardened manifest:
#
# kubectl apply -f - <<EOF
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: finance-api
#   namespace: finance-app
#   labels:
#     app.kubernetes.io/name: finance-api
#     app.kubernetes.io/part-of: finance-system
# spec:
#   replicas: 2
#   selector:
#     matchLabels:
#       app: finance-api
#   template:
#     metadata:
#       labels:
#         app: finance-api
#     spec:
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: api
#         image: nginx:1.25-alpine
#         ports:
#         - containerPort: 80
#         securityContext:
#           allowPrivilegeEscalation: false
#           readOnlyRootFilesystem: true
#           capabilities:
#             drop:
#             - ALL
# EOF
#
# Verify pod creation and readiness:
#    kubectl get pods -n finance-app
# Expected Output:
#    NAME                           READY   STATUS    RESTARTS   AGE
#    finance-api-79b8c6f49d-abc12   1/1     Running   0          12s
#    finance-api-79b8c6f49d-def34   1/1     Running   0          12s
#
# ------------------------------------------------------------------------------
# STEP 3: Diagnose & Fix Objective B (analytics-tier Namespace Labels)
# ------------------------------------------------------------------------------
# 1. View current labels on analytics-tier namespace:
#    kubectl get ns analytics-tier --show-labels
#
# 2. Overwrite invalid labels with correct Pod Security Admission key-value pairs:
#    kubectl label --overwrite namespace analytics-tier \
#      pod-security.kubernetes.io/enforce=baseline \
#      pod-security.kubernetes.io/enforce-version=latest \
#      pod-security.kubernetes.io/warn=restricted \
#      pod-security.kubernetes.io/warn-version=latest \
#      pod-security.kubernetes.io/audit=restricted \
#      pod-security.kubernetes.io/audit-version=latest
#
# 3. Confirm label assignment:
#    kubectl get ns analytics-tier --show-labels
# Expected Output:
#    NAME             STATUS   AGE   LABELS
#    analytics-tier   Active   3m    kubernetes.io/metadata.name=analytics-tier,pod-security.kubernetes.io/audit-version=latest,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce-version=latest,pod-security.kubernetes.io/enforce=baseline,pod-security.kubernetes.io/warn-version=latest,pod-security.kubernetes.io/warn=restricted
# ==============================================================================