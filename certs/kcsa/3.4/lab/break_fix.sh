#!/usr/bin/env bash
# ==============================================================================
# KCSA Certification Preparation - Break & Fix Lab
# Domain 3.0: Kubernetes Security Operations
# Topic 3.4: Secrets Management, RBAC Least-Privilege, & Encryption at Rest
# Exam Weight: 3.14%
#
# Official References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - K8s Secrets Overview: https://kubernetes.io/docs/concepts/configuration/secret/
# - Encrypting Secret Data at Rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
# - Good Practices for Kubernetes Secrets: https://kubernetes.io/docs/concepts/security/secrets-good-practices/
# - Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
# ==============================================================================
# 
# TECHNICAL ARCHITECTURE & INTERNAL MECHANICS:
# 1. Secret Storage & etcd Encoding:
#    By default, Kubernetes Secrets are stored in etcd as unencrypted base64-encoded
#    strings under the key path `/registry/secrets/<namespace>/<secret-name>`.
#    Base64 encoding is NOT encryption; anyone with access to etcd or cluster-wide
#    `get/list` Secret permissions can decode sensitive data instantly using standard tools.
#
# 2. Encryption at Rest (KMS v2 / Provider Chain):
#    To secure Secrets in etcd, the kube-apiserver must be configured with an
#    `EncryptionConfiguration` file via the `--encryption-provider-config` flag.
#    Providers are evaluated in sequence (top to bottom). To ensure zero-downtime
#    key rotation, new keys/providers are placed first for writes, while legacy keys
#    remain secondary for reading existing encrypted data.
#
# 3. RBAC & Secret Security Risks:
#    Granting `get`, `list`, or `watch` verbs on `secrets` resources allows callers
#    to read raw credential payloads. Additionally, `create` or `patch` rights on Pods
#    allow attackers to extract Secrets by spawning workloads that mount target Secrets.
#    Least-privilege RBAC must scope Secret access down to specific ResourceNames.
#
# 4. Secret Exposure Vectors (Env Vars vs. Projected Volumes):
#    - Environment Variables (`envFrom`, `valueFrom.secretKeyRef`): Secrets are exposed
#      in process environments (`/proc/1/environ`), container logs, and crash dumps.
#    - Projected Volumes / Secret Volumes: Mounts Secrets as tempfs memory backed files.
#      Supports strict Linux file permissions (`defaultMode: 0400`), prevents disk writes,
#      and allows dynamic rotation without container restarts.
# ==============================================================================

set -euo pipefail

LAB_NAMESPACE="kcsa-secrets-lab"
TARGET_SA="payment-processor-sa"
TARGET_SECRET="db-credentials-v2"
APP_DEPLOYMENT="payment-api"

# Helper for colored output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[+] Initializing KCSA Topic 3.4 Break & Fix Environment...${NC}"

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERROR] 'kubectl' CLI tool is required but not installed or in PATH.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[ERROR] Unable to communicate with Kubernetes cluster. Check your kubeconfig.${NC}"
    exit 1
fi

# Cleanup existing lab resources if present
echo -e "${BLUE}[+] Cleaning up any existing lab resources in namespace '${LAB_NAMESPACE}'...${NC}"
kubectl delete namespace "${LAB_NAMESPACE}" --ignore-not-found=true --wait=true &> /dev/null || true

# Step 1: Create Lab Namespace
echo -e "${BLUE}[+] Creating lab namespace '${LAB_NAMESPACE}'...${NC}"
kubectl create namespace "${LAB_NAMESPACE}" > /dev/null

# Step 2: Create the target Secret
echo -e "${BLUE}[+] Provisioning target Secret '${TARGET_SECRET}'...${NC}"
kubectl create secret generic "${TARGET_SECRET}" \
    --namespace="${LAB_NAMESPACE}" \
    --from-literal=username="pg_sec_admin" \
    --from-literal=password="P@ssw0rd_KCSA_Production_2026!#" \
    --from-literal=db_name="payments_db" > /dev/null

# Step 3: Create ServiceAccount
echo -e "${BLUE}[+] Provisioning workload ServiceAccount '${TARGET_SA}'...${NC}"
kubectl create serviceaccount "${TARGET_SA}" --namespace="${LAB_NAMESPACE}" > /dev/null

# Step 4: Inject BREAK #1 - Broken RBAC Role & Binding
# The workload needs to fetch secret metadata via API sidecar, but the Role is misconfigured.
# It targets the wrong API resource ('configmaps' instead of 'secrets') and lacks resourceNames restrictions.
echo -e "${BLUE}[+] Injecting BREAK #1: Misconfigured RBAC Role for Secret Access...${NC}"
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payment-secret-reader
  namespace: ${LAB_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["configmaps"] # INTENTIONAL BREAK: Should be 'secrets'
  verbs: ["get", "list"]
EOF

kubectl create rolebinding payment-secret-reader-binding \
    --namespace="${LAB_NAMESPACE}" \
    --role=payment-secret-reader \
    --serviceaccount="${LAB_NAMESPACE}:${TARGET_SA}" > /dev/null

# Step 5: Inject BREAK #2 - Broken Pod Spec Secret Reference & Mounting Security
# The Deployment fails to start because:
# A) It attempts to read a non-existent key 'db_password' (actual key is 'password').
# B) The secret volume mount uses insecure default modes and wrong mount definitions.
echo -e "${BLUE}[+] Injecting BREAK #2: Deploying Workload with Malformed Secret Reference...${NC}"
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_DEPLOYMENT}
  namespace: ${LAB_NAMESPACE}
  labels:
    app: payment-api
    tier: backend
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
      serviceAccountName: ${TARGET_SA}
      containers:
      - name: api-server
        image: busybox:1.36.1
        command: ["sh", "-c", "echo 'API Running...'; sleep 3600"]
        env:
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: ${TARGET_SECRET}
              key: username
        - name: DB_PASS
          valueFrom:
            secretKeyRef:
              name: ${TARGET_SECRET}
              key: db_password # INTENTIONAL BREAK: Invalid key name (should be 'password')
        volumeMounts:
        - name: secret-volume
          mountPath: "/etc/secrets"
          readOnly: true
      volumes:
      - name: secret-volume
        secret:
          secretName: ${TARGET_SECRET}
          defaultMode: 0777 # SECURITY FAILURE & DRIFT: Insecure permission mode (production requires 0400)
EOF

echo ""
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "${YELLOW}               KCSA LAB BREAK & FIX CHALLENGE ACTIVATED                       ${NC}"
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "${GREEN}LAB ENVIRONMENT BROKEN SUCCESSFULLY!${NC}"
echo ""
echo -e "${BLUE}SCENARIO DESCRIPTION:${NC}"
echo "You are auditing a payment processing application in namespace '${LAB_NAMESPACE}'."
echo "The application '${APP_DEPLOYMENT}' is stuck in a degraded state (CreateContainerConfigError / CrashLoopBackOff)."
echo "Furthermore, an internal security audit flagged two compliance violations:"
echo "1. The ServiceAccount '${TARGET_SA}' fails automated RBAC Secret access verifications."
echo "2. The workload deployment uses incorrect Secret key references and insecure volume file modes."
echo ""
echo -e "${BLUE}SYMPTOMS TO INVESTIGATE:${NC}"
echo "1. Pods in deployment '${APP_DEPLOYMENT}' fail during container creation."
echo "2. Running RBAC verification CLI tools indicates access denied on Secret resources."
echo "3. Inspected Secret mounts exhibit overly permissive file attributes (0777 instead of 0400)."
echo ""
echo -e "${BLUE}STUDENT OBJECTIVES:${NC}"
echo "1. Fix the deployment '${APP_DEPLOYMENT}' so all pods achieve '1/1 Running' status."
echo "2. Correct the Secret key reference inside the container environment variable spec."
echo "3. Harden the Secret volume mount by setting `defaultMode: 0400` (read-only for owner)."
echo "4. Update the RBAC Role '${LAB_NAMESPACE}/payment-secret-reader' to:"
echo "   - Grant access specifically to 'secrets' resources (not 'configmaps')."
echo "   - Restrict access strictly using 'resourceNames: [\"${TARGET_SECRET}\"]'."
echo "   - Allow only the 'get' verb (Least Privilege principle)."
echo ""
echo -e "${BLUE}VERIFICATION COMMANDS TO RUN:${NC}"
echo "  kubectl get pods -n ${LAB_NAMESPACE}"
echo "  kubectl describe pod -l app=payment-api -n ${LAB_NAMESPACE}"
echo "  kubectl auth can-i get secret/${TARGET_SECRET} --as=system:serviceaccount:${LAB_NAMESPACE}:${TARGET_SA} -n ${LAB_NAMESPACE}"
echo ""
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "${YELLOW} Tip: Review the commented resolution guide at the end of this script file. ${NC}"
echo -e "${YELLOW}==============================================================================${NC}"

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION GUIDE (COMMENTED OUT)
# ==============================================================================
#
# STEP 1: DIAGNOSE WORKLOAD FAILURE
# ------------------------------------------------------------------------------
# Check pod status:
# $ kubectl get pods -n kcsa-secrets-lab
# Expected Output:
# NAME                           READY   STATUS                       RESTARTS   AGE
# payment-api-6d8b9f5c4-x9z2k   0/1     CreateContainerConfigError   0          45s
#
# Inspect pod events:
# $ kubectl describe pod -l app=payment-api -n kcsa-secrets-lab
# Expected Diagnostic Output:
# Error: secret "db-credentials-v2" key "db_password" not found in namespace "kcsa-secrets-lab"
#
# Inspect available keys in the target secret:
# $ kubectl get secret db-credentials-v2 -n kcsa-secrets-lab -o jsonpath='{.data}'
# Output: {"db_name":"...","password":"...","username":"..."}
# Notice key is 'password', NOT 'db_password'.
#
#
# STEP 2: DIAGNOSE AND FIX RBAC PERMISSIONS
# ------------------------------------------------------------------------------
# Test ServiceAccount authorization:
# $ kubectl auth can-i get secret/db-credentials-v2 \
#     --as=system:serviceaccount:kcsa-secrets-lab:payment-processor-sa \
#     -n kcsa-secrets-lab
# Output: no
#
# Inspect current Role:
# $ kubectl get role payment-secret-reader -n kcsa-secrets-lab -o yaml
# Notice resource is incorrectly configured as 'configmaps'.
#
# Apply corrected least-privilege Role manifest:
# $ cat <<EOF | kubectl apply -f -
# apiVersion: rbac.authorization.k8s.io/v1
# kind: Role
# metadata:
#   name: payment-secret-reader
#   namespace: kcsa-secrets-lab
# rules:
# - apiGroups: [""]
#   resources: ["secrets"]
#   resourceNames: ["db-credentials-v2"]
#   verbs: ["get"]
# EOF
#
# Verify updated RBAC permissions:
# $ kubectl auth can-i get secret/db-credentials-v2 \
#     --as=system:serviceaccount:kcsa-secrets-lab:payment-processor-sa \
#     -n kcsa-secrets-lab
# Output: yes
#
# Verify forbidden actions (ensuring least-privilege works):
# $ kubectl auth can-i list secrets \
#     --as=system:serviceaccount:kcsa-secrets-lab:payment-processor-sa \
#     -n kcsa-secrets-lab
# Output: no (because resourceNames restricts list/watch verbs)
#
#
# STEP 3: FIX DEPLOYMENT MANIFEST & HARDEN MOUNT SECURITY
# ------------------------------------------------------------------------------
# Patch Deployment to fix key reference and enforce secure volume permissions (0400):
#
# $ cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-api
#   namespace: kcsa-secrets-lab
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
#       serviceAccountName: payment-processor-sa
#       containers:
#       - name: api-server
#         image: busybox:1.36.1
#         command: ["sh", "-c", "echo 'API Running...'; sleep 3600"]
#         env:
#         - name: DB_USER
#           valueFrom:
#             secretKeyRef:
#               name: db-credentials-v2
#               key: username
#         - name: DB_PASS
#           valueFrom:
#             secretKeyRef:
#               name: db-credentials-v2
#               key: password # FIXED: Changed from db_password to password
#         volumeMounts:
#         - name: secret-volume
#           mountPath: "/etc/secrets"
#           readOnly: true
#       volumes:
#       - name: secret-volume
#         secret:
#           secretName: db-credentials-v2
#           defaultMode: 256 # FIXED: Octal 0400 represented in decimal is 256 (or octal string 0400 in YAML)
# EOF
#
#
# STEP 4: PRODUCTION VERIFICATION & AUDIT
# ------------------------------------------------------------------------------
# 1. Verify Pod Readiness:
#    $ kubectl get pods -n kcsa-secrets-lab
#    Expected Output: payment-api-xxx 1/1 Running
#
# 2. Verify File Permissions inside Container:
#    $ kubectl exec -it deploy/payment-api -n kcsa-secrets-lab -- ls -l /etc/secrets
#    Expected Output:
#    -r-------- 1 root root 15 Aug  7 20:00 db_name
#    -r-------- 1 root root 32 Aug  7 20:00 password
#    -r-------- 1 root root 11 Aug  7 20:00 username
#    (Mode 0400 ensures read-only access strictly for file owner)
#
# 3. Verify Encryption at Rest on Control Plane (KCSA Specific Knowledge):
#    To verify etcd raw storage status, inspect etcd using etcdctl (requires control plane access):
#    $ ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
#        --cert=/etc/kubernetes/pki/etcd/server.crt \
#        --key=/etc/kubernetes/pki/etcd/server.key \
#        get /registry/secrets/kcsa-secrets-lab/db-credentials-v2
#    If EncryptionConfiguration is enabled with a secretbox/kms provider:
#    Output header begins with: k8s:enc:aead:v1:secretbox:...
#    If unencrypted:
#    Output contains raw base64 data string: k8s:v1:Secret:...
# ==============================================================================