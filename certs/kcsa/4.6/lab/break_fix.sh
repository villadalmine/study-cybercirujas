#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Certification Prep
# Topic 4.6: Access to Sensitive Data (Exam Weight: 2.29%)
# Script Type: Break & Fix Production Training Scenario
#
# Official Documentation References:
#   - KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#   - Kubernetes Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
#   - Good Practices for Secrets: https://kubernetes.io/docs/concepts/security/secrets-good-practices/
#   - ServiceAccount Token Automounting: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
#   - RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
# ==============================================================================

set -euo pipefail

# Visual Formatting Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

NAMESPACE="finance-prod"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
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
    log_info "Verifying environment prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl utility is not installed or not in PATH."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Unable to connect to a valid Kubernetes cluster. Check your KUBECONFIG."
        exit 1
    fi
    log_success "Kubernetes cluster connection verified."
}

inject_breakage() {
    log_warn "Injecting sensitive data access vulnerabilities into namespace '${NAMESPACE}'..."

    # Create target namespace
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # 1. Create a sensitive database credential secret
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-primary-creds
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  username: "admin_finance"
  password: "SuperSecretProductionPassword2026!"
  api_token: "sk_live_998877665544332211"
EOF

    # 2. VULNERABILITY 1: Over-privileged RBAC granting secret read permissions to app ServiceAccount
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-reporter-sa
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: reporter-excessive-role
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["secrets", "configmaps", "pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reporter-excessive-binding
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: app-reporter-sa
  namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: reporter-excessive-role
  apiGroup: rbac.authorization.k8s.io
EOF

    # 3. VULNERABILITY 2: Workload injecting sensitive credentials into Environment Variables & Automounting SA Tokens
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: ${NAMESPACE}
  labels:
    tier: payment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      serviceAccountName: default
      automountServiceAccountToken: true
      containers:
      - name: payment-container
        image: nginx:1.25-alpine
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-primary-creds
              key: password
        - name: API_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: db-primary-creds
              key: api_token
        resources:
          limits:
            memory: "128Mi"
            cpu: "250m"
EOF

    # 4. VULNERABILITY 3: Insecure Secret Volume File Mode (Default Mode 0644 exposes secret keys to all container processes)
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: analytics-worker
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: analytics-worker
  template:
    metadata:
      labels:
        app: analytics-worker
    spec:
      serviceAccountName: app-reporter-sa
      containers:
      - name: worker
        image: nginx:1.25-alpine
        volumeMounts:
        - name: secret-volume
          mountPath: "/etc/secrets"
        resources:
          limits:
            memory: "128Mi"
            cpu: "250m"
      volumes:
      - name: secret-volume
        secret:
          secretName: db-primary-creds
          # Missed defaultMode restriction: defaults to 0644 (world readable inside container)
EOF

    log_info "Waiting for workloads to settle..."
    kubectl rollout status deployment/payment-api -n "${NAMESPACE}" --timeout=60s || true
    kubectl rollout status deployment/analytics-worker -n "${NAMESPACE}" --timeout=60s || true

    log_warn "Breakage injection complete!"
}

display_exercise_brief() {
    echo -e "\n${CYAN}==============================================================================${NC}"
    echo -e "${CYAN}                  KCSA EXAM SCENARIO: ACCESS TO SENSITIVE DATA                ${NC}"
    echo -e "${CYAN}==============================================================================${NC}"
    echo -e "A production security audit in namespace '${NAMESPACE}' reported multiple severe"
    echo -e "violations of CNCF/Kubernetes sensitive data security controls.\n"
    echo -e "${YELLOW}AUDIT FINDINGS & SYMPTOMS TO RESOLVE:${NC}"
    echo -e "1. ${RED}[RBAC Secret Exposure]${NC} ServiceAccount 'app-reporter-sa' can read all raw Secrets"
    echo -e "   in '${NAMESPACE}'. Verify with:"
    echo -e "   ${BLUE}kubectl auth can-i get secrets --as=system:serviceaccount:${NAMESPACE}:app-reporter-sa -n ${NAMESPACE}${NC}"
    echo -e "   Expected audit policy: ServiceAccount MUST NOT have read access to Secrets.\n"

    echo -e "2. ${RED}[Env Var Leakage & Unnecessary SA Token Mount]${NC} Deployment 'payment-api':"
    echo -e "   - Passes DB_PASSWORD and API_SECRET_KEY as environment variables (visible via 'kubectl describe pod'"
    echo -e "     and inside process environment /proc/1/environ)."
    echo -e "   - Unnecessarily automounts ServiceAccount tokens (automountServiceAccountToken: true).\n"

    echo -e "3. ${RED}[Insecure Secret Volume Permissions]${NC} Deployment 'analytics-worker':"
    echo -e "   - Mounts secret 'db-primary-creds' at '/etc/secrets' without restricting permissions."
    echo -e "   - File mode defaults to 0644 instead of recommended 0400 (read-only by owner, 256 octal).\n"

    echo -e "${GREEN}STUDENT OBJECTIVES:${NC}"
    echo -e "1. Modify RBAC Role 'reporter-excessive-role' to REMOVE 'secrets' from resources."
    echo -e "2. Harden Deployment 'payment-api':"
    echo -e "   - Set 'automountServiceAccountToken: false' in the pod spec."
    echo -e "   - Remove sensitive environment variables from container 'payment-container'."
    echo -e "   - Mount 'db-primary-creds' as a read-only volume at '/etc/secrets/db' with file permissions 0400."
    echo -e "3. Harden Deployment 'analytics-worker':"
    echo -e "   - Set 'defaultMode: 256' (octal 0400) and 'readOnly: true' on its secret volume mount."
    echo -e "${CYAN}==============================================================================${NC}\n"
}

# Main Execution Flow
check_prerequisites
inject_breakage
display_exercise_brief

# ==============================================================================
#                             STEP-BY-STEP SOLUTION
# ==============================================================================
# Un-comment or reference the steps below to verify and fix the environment.
#
# STEP 1: VERIFY INITIAL VULNERABILITIES
# ------------------------------------------------------------------------------
# A) Check RBAC privilege leak:
#    kubectl auth can-i get secrets --as=system:serviceaccount:finance-prod:app-reporter-sa -n finance-prod
#    # Output: yes (VULNERABLE)
#
# B) Check environment variable secret exposure:
#    kubectl get deploy payment-api -n finance-prod -o yaml | grep -A 10 env:
#    # Output: DB_PASSWORD and API_SECRET_KEY mapped via secretKeyRef (VULNERABLE)
#
# C) Check automountServiceAccountToken on payment-api:
#    kubectl get deploy payment-api -n finance-prod -o jsonpath='{.spec.template.spec.automountServiceAccountToken}'
#    # Output: true (VULNERABLE)
#
# STEP 2: FIX VULNERABILITY 1 - RESTRICT RBAC ACCESS TO SECRETS
# ------------------------------------------------------------------------------
# Edit or re-apply the Role to remove 'secrets' from resources:
#
# kubectl apply -f - <<EOF
# apiVersion: rbac.authorization.k8s.io/v1
# kind: Role
# metadata:
#   name: reporter-excessive-role
#   namespace: finance-prod
# rules:
# - apiGroups: [""]
#   resources: ["configmaps", "pods"]
#   verbs: ["get", "list", "watch"]
# EOF
#
# Verify RBAC remediation:
# kubectl auth can-i get secrets --as=system:serviceaccount:finance-prod:app-reporter-sa -n finance-prod
# # Expected Output: no
#
# STEP 3: FIX VULNERABILITY 2 - HARDEN DEPLOYMENT 'payment-api'
# ------------------------------------------------------------------------------
# Remove secret env vars, disable automountServiceAccountToken, and use volume mounts:
#
# kubectl apply -f - <<EOF
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-api
#   namespace: finance-prod
#   labels:
#     tier: payment
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: payment-api
#   template:
#     metadata:
#       labels:
#         app: payment-api
#     spec:
#       serviceAccountName: default
#       automountServiceAccountToken: false
#       containers:
#       - name: payment-container
#         image: nginx:1.25-alpine
#         volumeMounts:
#         - name: db-secret-vol
#           mountPath: "/etc/secrets/db"
#           readOnly: true
#         resources:
#           limits:
#             memory: "128Mi"
#             cpu: "250m"
#       volumes:
#       - name: db-secret-vol
#         secret:
#           secretName: db-primary-creds
#           defaultMode: 256 # 0400 octal permissions
# EOF
#
# STEP 4: FIX VULNERABILITY 3 - HARDEN DEPLOYMENT 'analytics-worker'
# ------------------------------------------------------------------------------
# Apply defaultMode 256 (0400) and readOnly to secret volume:
#
# kubectl apply -f - <<EOF
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: analytics-worker
#   namespace: finance-prod
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: analytics-worker
#   template:
#     metadata:
#       labels:
#         app: analytics-worker
#     spec:
#       serviceAccountName: app-reporter-sa
#       automountServiceAccountToken: false
#       containers:
#       - name: worker
#         image: nginx:1.25-alpine
#         volumeMounts:
#         - name: secret-volume
#           mountPath: "/etc/secrets"
#           readOnly: true
#         resources:
#           limits:
#             memory: "128Mi"
#             cpu: "250m"
#       volumes:
#       - name: secret-volume
#         secret:
#           secretName: db-primary-creds
#           defaultMode: 256
# EOF
#
# STEP 5: FINAL VERIFICATION
# ------------------------------------------------------------------------------
# 1. Verify SA token mount path does NOT exist inside payment-api pod:
#    PAYMENT_POD=$(kubectl get pod -n finance-prod -l app=payment-api -o jsonpath='{.items[0].metadata.name}')
#    kubectl exec -n finance-prod "${PAYMENT_POD}" -- ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1
#    # Expected Output: ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
#
# 2. Verify volume permissions on mounted secret file inside analytics-worker:
#    WORKER_POD=$(kubectl get pod -n finance-prod -l app=analytics-worker -o jsonpath='{.items[0].metadata.name}')
#    kubectl exec -n finance-prod "${WORKER_POD}" -- ls -la /etc/secrets
#    # Expected Output: -r-------- 1 root root ... username
# ==============================================================================