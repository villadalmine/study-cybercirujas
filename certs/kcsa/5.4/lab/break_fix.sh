#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Lab Environment
# Topic 5.4: Service Mesh Security & Zero Trust Architecture
# Weight in Exam: 2.29%
#
# Official References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Istio Security Architecture & mTLS: https://istio.io/latest/docs/concepts/security/
# - SPIFFE Identity Specification: https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md
# ==============================================================================

set -euo pipefail

# Color Output Formatting
RED='\030[0;31m'
GREEN='\038;5;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LAB_NAMESPACE="kcsa-mesh-lab"

echo -e "${CYAN}[+] Initializing KCSA Topic 5.4 (Service Mesh Security) Break & Fix Lab...${NC}"

# 1. Pre-requisite Checks
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[!] Error: kubectl is not installed or not in PATH.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[!] Error: Cannot connect to Kubernetes cluster. Ensure KUBECONFIG is set.${NC}"
    exit 1
fi

# 2. Cleanup existing lab environment if present
echo -e "${YELLOW}[*] Cleaning up old lab resources (if any)...${NC}"
kubectl delete namespace "${LAB_NAMESPACE}" --ignore-not-found=true --wait=true &> /dev/null

# 3. Create Lab Namespace
echo -e "${CYAN}[+] Creating namespace '${LAB_NAMESPACE}'...${NC}"
kubectl create namespace "${LAB_NAMESPACE}"

# Label namespace for Istio sidecar injection (standard practice for Istio-based Service Mesh)
kubectl label namespace "${LAB_NAMESPACE}" istio-injection=enabled --overwrite

# 4. Deploy Workloads (Target Service and Client Workload)
echo -e "${CYAN}[+] Deploying target microservice (backend-api) and client (frontend-app)...${NC}"

# Target Service Account & Workload
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: ${LAB_NAMESPACE}
---
apiVersion: v1
kind: Service
metadata:
  name: backend-api
  namespace: ${LAB_NAMESPACE}
  labels:
    app: backend-api
spec:
  ports:
  - port: 8080
    targetPort: 80
    name: http
  selector:
    app: backend-api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: ${LAB_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      serviceAccountName: backend-sa
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF

# Client Service Accounts & Workload
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: ${LAB_NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: authorized-payment-sa
  namespace: ${LAB_NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-app
  namespace: ${LAB_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend-app
  template:
    metadata:
      labels:
        app: frontend-app
    spec:
      serviceAccountName: frontend-sa
      containers:
      - name: curl-client
        image: curlimages/curl:latest
        command: ["/bin/sh", "-c", "sleep 3600"]
EOF

# Wait for Pods to be ready
echo -e "${YELLOW}[*] Waiting for pods in '${LAB_NAMESPACE}' to reach ready state...${NC}"
kubectl rollout status deployment/backend-api -n "${LAB_NAMESPACE}" --timeout=90s
kubectl rollout status deployment/frontend-app -n "${LAB_NAMESPACE}" --timeout=90s

# 5. INJECT FAULT: Misconfigured Service Mesh PeerAuthentication & AuthorizationPolicy
echo -e "${RED}[!] INJECTING SCENARIO FAULT: Service Mesh Zero Trust Security Misconfiguration...${NC}"

# Enforce Strict mTLS at Namespace level
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ${LAB_NAMESPACE}
spec:
  mtls:
    mode: STRICT
EOF

# Enforce RBAC Authorization Policy requiring a specific SPIFFE identity principal that does NOT match frontend-app
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: backend-rbac-policy
  namespace: ${LAB_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: backend-api
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/${LAB_NAMESPACE}/sa/authorized-payment-sa"]
    to:
    - operation:
        methods: ["GET"]
        ports: ["8080"]
EOF

echo -e "\n${GREEN}==============================================================================${NC}"
echo -e "${GREEN}                       LAB SETUP COMPLETE & FAULT INJECTED                    ${NC}"
echo -e "${GREEN}==============================================================================${NC}\n"

echo -e "${YELLOW}--- STUDENT CHALLENGE INSTRUCTIONS ---${NC}"
echo -e "${CYAN}SCENARIO DESCRIPTION:${NC}"
echo -e "You are managing a microservice architecture in namespace '${LAB_NAMESPACE}' secured by a Service Mesh."
echo -e "The 'frontend-app' service needs to securely access 'backend-api' over mutual TLS (mTLS) using SPIFFE identities."
echo -e "Currently, inter-service communications are failing despite the Pods running without errors."

echo -e "\n${CYAN}OBSERVED SYMPTOM:${NC}"
echo -e "Running an HTTP request from 'frontend-app' to 'backend-api' results in an RBAC Access Denied / HTTP 403 Forbidden error."
echo -e "Verification Command:"
echo -e "  ${YELLOW}kubectl exec -n ${LAB_NAMESPACE} deployment/frontend-app -- curl -s -o /dev/null -w \"%{http_code}\" http://backend-api:8080${NC}"
echo -e "  Expected Failure Output: 403 (RBAC access denied by proxy)"

echo -e "\n${CYAN}LAB OBJECTIVES:${NC}"
echo -e "1. Inspect the Service Mesh security policies (PeerAuthentication, AuthorizationPolicy) in '${LAB_NAMESPACE}'."
echo -e "2. Identify the SPIFFE Identity mismatch between what 'backend-api' requires and what 'frontend-app' presents."
echo -e "3. Fix the deployment or authorization manifest so that 'frontend-app' authenticates with mTLS and passes RBAC validation."
echo -e "4. Verify success: 'curl' from 'frontend-app' to 'http://backend-api:8080' must return HTTP status 200 OK."

echo -e "\n${CYAN}DIAGNOSTIC HINTS:${NC}"
echo -e "- Check AuthorizationPolicy objects: ${YELLOW}kubectl get authorizationpolicy -n ${LAB_NAMESPACE} -o yaml${NC}"
echo -e "- Check PeerAuthentication objects: ${YELLOW}kubectl get peerauthentication -n ${LAB_NAMESPACE} -o yaml${NC}"
echo -e "- Review the ServiceAccount used by deployment/frontend-app vs the principal defined in AuthorizationPolicy."
echo -e "- Remember SPIFFE ID format: ${YELLOW}cluster.local/ns/<namespace>/sa/<serviceaccount>${NC}"
echo -e "==============================================================================\n"

exit 0

# ==============================================================================
#                        STEP-BY-STEP SOLUTION (TEACHER GUIDE)
# ==============================================================================
#
# PROBLEM ANALYSIS:
# 1. PeerAuthentication in `kcsa-mesh-lab` enforces `STRICT` mTLS. Every request
#    must use X.509 SVIDs generated by the Service Mesh CA containing SPIFFE identities.
# 2. AuthorizationPolicy `backend-rbac-policy` enforces RBAC:
#    - Target: Pods labeled `app: backend-api`
#    - Action: ALLOW
#    - Principal allowed: `cluster.local/ns/kcsa-mesh-lab/sa/authorized-payment-sa`
# 3. However, `frontend-app` is configured with `serviceAccountName: frontend-sa`.
#    Therefore, its SPIFFE ID is `cluster.local/ns/kcsa-mesh-lab/sa/frontend-sa`.
# 4. The Envoy sidecar proxy attached to `backend-api` evaluates the incoming connection,
#    validates mTLS, extracts the SAN URI (`cluster.local/ns/kcsa-mesh-lab/sa/frontend-sa`),
#    checks against `backend-rbac-policy`, finds no match, and returns HTTP 403 Forbidden.
#
# OPTION A SOLUTION: Update the AuthorizationPolicy to allow `frontend-sa` (Recommended):
#
# Step 1: Inspect current AuthorizationPolicy
#   kubectl get authorizationpolicy backend-rbac-policy -n kcsa-mesh-lab -o yaml
#
# Step 2: Edit or apply updated AuthorizationPolicy adding frontend-sa to principals:
#   kubectl apply -f - <<EOF
#   apiVersion: security.istio.io/v1beta1
#   kind: AuthorizationPolicy
#   metadata:
#     name: backend-rbac-policy
#     namespace: kcsa-mesh-lab
#   spec:
#     selector:
#       matchLabels:
#         app: backend-api
#     action: ALLOW
#     rules:
#     - from:
#       - source:
#           principals:
#           - "cluster.local/ns/kcsa-mesh-lab/sa/authorized-payment-sa"
#           - "cluster.local/ns/kcsa-mesh-lab/sa/frontend-sa"
#       to:
#       - operation:
#           methods: ["GET"]
#           ports: ["8080"]
#   EOF
#
# OPTION B SOLUTION: Update `frontend-app` Deployment to use `authorized-payment-sa`:
#
#   kubectl patch deployment frontend-app -n kcsa-mesh-lab -p \
#     '{"spec":{"template":{"spec":{"serviceAccountName":"authorized-payment-sa"}}}}'
#
# VERIFICATION:
# Run the curl test command again:
#   kubectl exec -n kcsa-mesh-lab deployment/frontend-app -- curl -s -o /dev/null -w "%{http_code}\n" http://backend-api:8080
# Output must be:
#   200
# ==============================================================================