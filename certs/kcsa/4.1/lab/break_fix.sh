#!/usr/bin/env bash
# ==============================================================================
# KCSA Exam Preparation - Topic 4.1: Kubernetes Trust Boundaries and Data Flow
# Lab Script: Break & Fix - Control Plane to Node & Pod Data Flow Isolation
# Weight in Exam: 2.29%
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# Official Documentation:
#   - https://kubernetes.io/docs/concepts/security/controlling-access/
#   - https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet-authentication-authorization/
#   - https://kubernetes.io/docs/concepts/services-networking/network-policies/
# ==============================================================================
# DISCLAIMER: Run this script ONLY in a non-production, disposable Kubernetes 
# cluster (e.g., KinD, Minikube, or a dedicated lab VM).
# ==============================================================================

set -euo pipefail

# Color Codes for Output
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CLUSTER_NAME="kcsa-trust-boundary-lab"

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_error "'kubectl' CLI tool is not installed. Please install kubectl."
        exit 1
    fi

    if ! command -v kind &> /dev/null; then
        log_warn "'kind' is not installed. Will check if existing cluster context is available."
    fi
}

ensure_cluster() {
    if kubectl cluster-info &> /dev/null; then
        log_info "Using existing active Kubernetes context: $(kubectl config current-context)"
    else
        if command -v kind &> /dev/null; then
            log_info "No active cluster found. Creating a KinD cluster named '${CLUSTER_NAME}'..."
            cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF
            log_success "KinD cluster created."
        else
            log_error "No active Kubernetes cluster found and 'kind' is not installed. Provide a disposable cluster."
            exit 1
        fi
    fi
}

inject_faults() {
    log_info "Setting up lab architecture: Multi-tenant namespaces and workloads..."

    # 1. Create Namespaces
    kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace untrusted-tenant --dry-run=client -o yaml | kubectl apply -f -

    # 2. Deploy Production Database (Sensitive Data Flow Target)
    kubectl apply -n production -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: Secure-db
  labels:
    app: secure-db
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-db
  template:
    metadata:
      labels:
        app: secure-db
        tier: backend
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
EOF

    # 3. Deploy Untrusted Tenant Pod (Compromised or External Trust Boundary Boundary)
    kubectl apply -n untrusted-tenant -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  labels:
    app: web-frontend
    tier: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
        tier: frontend
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF

    log_info "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=secure-db -n production --timeout=90s
    kubectl wait --for=condition=ready pod -l app=web-frontend -n untrusted-tenant --timeout=90s

    log_info "Injecting Architectural Misconfigurations (Breaking Trust Boundaries)..."

    # BREAK 1: ServiceAccount Privilege Escalation (Breaching RBAC Trust Boundary)
    # Creating a ServiceAccount in untrusted-tenant with cluster-admin rights!
    kubectl create serviceaccount compromised-sa -n untrusted-tenant --dry-run=client -o yaml | kubectl apply -f -
    kubectl create clusterrolebinding leak-admin-binding \
        --clusterrole=cluster-admin \
        --serviceaccount=untrusted-tenant:compromised-sa \
        --dry-run=client -o yaml | kubectl apply -f -

    # Patch untrusted deployment to use this service account
    kubectl patch deployment web-frontend -n untrusted-tenant \
        -p '{"spec":{"template":{"spec":{"serviceAccountName":"compromised-sa"}}}}'

    # BREAK 2: Missing Network Isolation (Breaching Pod-to-Pod Data Flow Boundary)
    # Create an invalid/flawed NetworkPolicy that allows all traffic into production
    kubectl apply -n production -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: flawed-production-policy
spec:
  podSelector: {}
  ingress:
  - {} # Allows ALL ingress traffic across all namespaces!
  policyTypes:
  - Ingress
EOF

    # BREAK 3: Node/Kubelet Control Plane Ingress Misconfiguration simulation
    # Labeling node as insecure and exposing sensitive host paths
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    kubectl label node "${NODE_NAME}" security-zone=untrusted --overwrite

    log_success "Fault injection completed successfully!"
}

display_symptoms_and_instructions() {
    cat << 'EOF'

================================================================================
                     KCSA LAB 4.1: DIAGNOSTIC & CHALLENGE GUIDE
================================================================================

SCENARIO OVERVIEW:
You are auditing a Kubernetes cluster following a security incident. An application 
deployed in the 'untrusted-tenant' namespace was compromised, and the attacker 
successfully traversed internal trust boundaries to reach internal production databases 
and execute arbitrary Kubernetes API calls across the control plane.

STUDENT MISSION:
Inspect the trust boundaries and data flows in the cluster to identify three critical 
vulnerabilities and apply production-grade remediation manifestos.

--------------------------------------------------------------------------------
EXPECTED SYMPTOMS & AUDIT STEPS TO PERFORM:
--------------------------------------------------------------------------------

1. RECONNAISSANCE & RBAC DATA FLOW AUDIT:
   - Check what capabilities workloads in 'untrusted-tenant' possess.
   - Run: 
     kubectl auth can-i --list --as=system:serviceaccount:untrusted-tenant:compromised-sa
   - SYMPTOM: ServiceAccount has full '*' permissions on '*' resources (cluster-admin).
   - GOAL: Remove the overly permissive ClusterRoleBinding and implement Least Privilege.

2. POD-TO-POD DATA FLOW isolation AUDIT:
   - Test data flow from 'untrusted-tenant' into 'production' namespace:
     FRONTEND_POD=$(kubectl get pod -n untrusted-tenant -l app=web-frontend -o jsonpath='{.items[0].metadata.name}')
     DB_IP=$(kubectl get pod -n production -l app=secure-db -o jsonpath='{.items[0].metadata.path.podIP}')
     kubectl exec -n untrusted-tenant $FRONTEND_POD -- nc -zv $DB_IP 6379
   - SYMPTOM: Connection succeeds (0 status code) despite namespaces being isolated tenant zones!
   - GOAL: Replace the flawed NetworkPolicy in 'production' namespace with a zero-trust policy 
           enforcing default-deny ingress and allowing traffic ONLY from authorized components.

3. KUBELET / NODE TRUST BOUNDARY AUDIT:
   - Audit node labels and RBAC Node Restriction boundaries.
   - Run:
     kubectl get nodes --show-labels
   - GOAL: Understand the Node-to-Control-Plane trust boundary and NodeRestriction admission controller.

--------------------------------------------------------------------------------
VERIFICATION COMMANDS FOR THE STUDENT:
--------------------------------------------------------------------------------
Task A: Ensure ServiceAccount in 'untrusted-tenant' CANNOT list pods in cluster scope:
  $ kubectl auth can-i list pods --as=system:serviceaccount:untrusted-tenant:compromised-sa --all-namespaces
  Expected output: "no"

Task B: Verify Network Policy prevents untrusted traffic into production:
  $ kubectl exec -n untrusted-tenant $FRONTEND_POD -- nc -zv -w 3 $DB_IP 6379
  Expected output: Connection timed out / Failed.

================================================================================
EOF
}

main() {
    check_prerequisites
    ensure_cluster
    inject_faults
    display_symptoms_and_instructions
}

main "$@"

# ==============================================================================
#                               STUDENT SOLUTION
#                         (Step-by-step Remediation)
# ==============================================================================
#
# STEP 1: FIX RBAC TRUST BOUNDARY BREACH
# Delete the over-privileged ClusterRoleBinding that crossed namespace boundaries:
#   kubectl delete clusterrolebinding leak-admin-binding
#
# Create a restrictive role and binding scoped strictly to untrusted-tenant if needed:
#   kubectl apply -n untrusted-tenant -f - <<EOF
# apiVersion: rbac.authorization.k8s.io/v1
# kind: Role
# metadata:
#   name: minimal-frontend-role
# rules:
# - apiGroups: [""]
#   resources: ["configmaps"]
#   verbs: ["get"]
# EOF
#
# STEP 2: FIX NETWORK DATA FLOW BOUNDARY (ZERO-TRUST NETWORK POLICY)
# Delete the flawed open NetworkPolicy in production:
#   kubectl delete networkpolicy flawed-production-policy -n production
#
# Apply Default-Deny Ingress Policy for the 'production' namespace:
#   kubectl apply -n production -f - <<EOF
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: default-deny-all-ingress
#   namespace: production
# spec:
#   podSelector: {}
#   policyTypes:
#   - Ingress
# EOF
#
# Apply Strict Explicit Allow NetworkPolicy for 'secure-db':
#   kubectl apply -n production -f - <<EOF
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-secure-db-internal-only
#   namespace: production
# spec:
#   podSelector:
#     matchLabels:
#       app: secure-db
#   policyTypes:
#   - Ingress
#   ingress:
#   - from:
#     - podSelector:
#         matchLabels:
#           tier: backend
#     ports:
#     - protocol: TCP
#       port: 6379
# EOF
#
# STEP 3: VERIFY TRUST BOUNDARY INTEGRITY
# 1. Test RBAC restriction:
#    kubectl auth can-i get pods -n production --as=system:serviceaccount:untrusted-tenant:compromised-sa
#    # Output must be: "no"
#
# 2. Test Network Isolation:
#    FRONTEND_POD=$(kubectl get pod -n untrusted-tenant -l app=web-frontend -o jsonpath='{.items[0].metadata.name}')
#    DB_IP=$(kubectl get pod -n production -l app=secure-db -o jsonpath='{.items[0].status.podIP}')
#    kubectl exec -n untrusted-tenant $FRONTEND_POD -- nc -zv -w 2 $DB_IP 6379
#    # Output must indicate connection refused or timeout!
# ==============================================================================