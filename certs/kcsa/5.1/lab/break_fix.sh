#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Exam Preparation
# Topic 5.1: Supply Chain Security (Exam Weight: 2.29%)
# Reference URLs:
#   - CNCF Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#   - Kubernetes Container Images: https://kubernetes.io/docs/concepts/containers/images/
#   - Sigstore / Cosign Documentation: https://docs.sigstore.dev/
#   - SLSA Security Framework: https://slsa.dev/
# ==============================================================================
# LAB SCENARIO: Supply Chain Security & Image Verification Admission Failure
#
# OBJECTIVE FOR THE STUDENT:
# 1. Inspect the failing deployment `payment-gateway` in namespace `production-sec`.
# 2. Identify why the Supply Chain Security Admission Policy is rejecting container workloads.
# 3. Diagnose two core supply chain defects:
#    a) The deployment manifest uses a mutable tag (`latest`) instead of an immutable SHA256 digest.
#    b) The Cosign verification key stored in Secret `cosign-verify-key` inside `supply-chain-system`
#       contains a corrupted public key, preventing cryptographic verification.
# 4. Fix the Cosign verification key by restoring the valid public key from `cosign-key-vault-backup`.
# 5. Update the deployment manifest to use a pinned, immutable SHA256 image digest.
# 6. Verify successful deployment rollout and supply chain compliance.
#
# EXPECTED SYMPTOMS:
# - Running `kubectl get deployment payment-gateway -n production-sec` shows 0/2 available replicas.
# - Describing the deployment or checking supply-chain annotations reveals:
#   "BLOCKED: Image signature verification failed and mutable tag detected."
# ==============================================================================

set -euo pipefail

# Terminal colors for lab environment
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}[+] Initializing CNCF KCSA Topic 5.1 Supply Chain Security Lab...${NC}"

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[!] Error: 'kubectl' command line tool is not installed or not in PATH.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[!] Error: Cannot connect to Kubernetes cluster. Verify your KUBECONFIG setting.${NC}"
    exit 1
fi

# Step 1: Prepare namespaces
echo -e "${GREEN}[1/4] Creating lab namespaces 'supply-chain-system' and 'production-sec'...${NC}"
kubectl create namespace supply-chain-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace production-sec --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Inject corrupted Cosign public key into the verification secret
echo -e "${GREEN}[2/4] Deploying Cosign Verification Secret (INTENTIONALLY BROKEN)...${NC}"

CORRUPTED_PUB_KEY="-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEBAD_INVALID_SUPPLY_CHAIN_KEY_
CORRUPTED_SIGNATURE_KEY_FOR_KCSA_LAB_DO_NOT_USE_IN_PROD_1234567890
-----END PUBLIC KEY-----"

kubectl create secret generic cosign-verify-key \
    --namespace=supply-chain-system \
    --from-literal=cosign.pub="${CORRUPTED_PUB_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

# Store valid Cosign public key in backup ConfigMap for student recovery
VALID_PUB_KEY="-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8/gXj0kZ0W3N8lC+J2QZ3a01qW+9
X2yM/Z4kL5m8N9v0P1q2R3s4T5u6V7w8X9y0Z1a2B3c4D5e6F7g8H9i0Jw==
-----END PUBLIC KEY-----"

kubectl create configmap cosign-key-vault-backup \
    --namespace=supply-chain-system \
    --from-literal=valid-cosign.pub="${VALID_PUB_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

# Step 3: Deploy Supply Chain Security Policy ConfigMap
echo -e "${GREEN}[3/4] Registering Supply Chain Security Policy...${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: supply-chain-enforcer-policy
  namespace: supply-chain-system
data:
  policy.yaml: |
    rules:
      - name: enforce-immutable-digest
        severity: High
        action: Deny
        match:
          resources: ["Pod", "Deployment"]
        condition:
          requireDigest: true
          digestPattern: "^[a-z0-9]+@sha256:[a-f0-9]{64}$"
      - name: verify-cosign-signature
        severity: Critical
        action: Deny
        keySecretRef:
          name: cosign-verify-key
          namespace: supply-chain-system
          key: cosign.pub
EOF

# Step 4: Deploy failing application with mutable tag and unverified image
echo -e "${GREEN}[4/4] Deploying 'payment-gateway' Deployment with mutable image tag...${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway
  namespace: production-sec
  labels:
    app: payment-gateway
    tier: api
    sec-policy: strict-supply-chain
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-gateway
  template:
    metadata:
      labels:
        app: payment-gateway
    spec:
      containers:
      - name: nginx-gateway
        # VIOLATION 1: Uses mutable tag 'latest' instead of pinned sha256 digest
        # VIOLATION 2: Image signature check fails due to corrupted public key in Secret
        image: nginx:latest
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
EOF

# Annotate deployment to simulate admission webhook policy failure state
kubectl annotate deployment payment-gateway \
    -n production-sec \
    supply-chain.k8s.io/status="BLOCKED: Image signature verification failed and mutable tag detected" \
    --overwrite

echo -e "\n${RED}[!] BREAK COMPLETED! The environment has been intentionally misconfigured.${NC}"
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "${YELLOW}STUDENT TASK & TROUBLESHOOTING INSTRUCTIONS:${NC}"
echo -e "1. Inspect deployment status in namespace 'production-sec':"
echo -e "   kubectl get deployments -n production-sec"
echo -e "   kubectl describe deployment payment-gateway -n production-sec"
echo -e "2. Check supply chain policy rules in namespace 'supply-chain-system':"
echo -e "   kubectl get configmap supply-chain-enforcer-policy -n supply-chain-system -o yaml"
echo -e "3. Inspect Cosign verification secret 'cosign-verify-key':"
echo -e "   kubectl get secret cosign-verify-key -n supply-chain-system -o yaml"
echo -e "4. Restore valid Cosign verification key from ConfigMap 'cosign-key-vault-backup'."
echo -e "5. Update 'payment-gateway' deployment image from 'nginx:latest' to an immutable sha256 digest:"
echo -e "   nginx@sha256:a4e918081137176a3861214eb1a4be4dfecbe5b9bc5d36e2f1e67b2d5612662c"
echo -e "==============================================================================\n"

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (STUDENT REFERENCE & VERIFICATION)
# ==============================================================================
#
# STEP 1: DIAGNOSE THE SUPPLY CHAIN VIOLATIONS
# ------------------------------------------------------------------------------
# Inspect deployment annotations and policy violations:
# $ kubectl describe deployment payment-gateway -n production-sec
#
# View active supply chain rules:
# $ kubectl get configmap supply-chain-enforcer-policy -n supply-chain-system -o yaml
#
# Root Cause Analysis:
# - Policy rule 'enforce-immutable-digest' requires image references matching `sha256:[a-f0-9]{64}`.
# - Policy rule 'verify-cosign-signature' uses Secret 'cosign-verify-key' key 'cosign.pub'.
# - Deployment 'payment-gateway' uses mutable tag 'nginx:latest'.
# - Secret 'cosign-verify-key' contains invalid public key data.
#
# STEP 2: FIX THE COSIGN SIGNATURE VERIFICATION SECRET
# ------------------------------------------------------------------------------
# Retrieve valid public key from backup ConfigMap:
# $ VALID_KEY=$(kubectl get configmap cosign-key-vault-backup -n supply-chain-system -o jsonpath='{.data.valid-cosign\.pub}')
#
# Overwrite Secret 'cosign-verify-key' with valid key:
# $ kubectl create secret generic cosign-verify-key \
#     --namespace=supply-chain-system \
#     --from-literal=cosign.pub="${VALID_KEY}" \
#     --dry-run=client -o yaml | kubectl apply -f -
#
# Confirm secret payload is valid PEM format:
# $ kubectl get secret cosign-verify-key -n supply-chain-system -o jsonpath='{.data.cosign\.pub}' | base64 --decode
#
# STEP 3: UPDATE DEPLOYMENT TO USE IMMUTABLE SHA256 DIGEST
# ------------------------------------------------------------------------------
# Target SHA256 Digest:
# nginx@sha256:a4e918081137176a3861214eb1a4be4dfecbe5b9bc5d36e2f1e67b2d5612662c
#
# Update image in deployment manifest:
# $ kubectl set image deployment/payment-gateway \
#     nginx-gateway=nginx@sha256:a4e918081137176a3861214eb1a4be4dfecbe5b9bc5d36e2f1e67b2d5612662c \
#     -n production-sec
#
# Update supply chain status annotation:
# $ kubectl annotate deployment payment-gateway \
#     -n production-sec \
#     supply-chain.k8s.io/status="VERIFIED: SHA256 digest pinned and Cosign signature validated" \
#     --overwrite
#
# STEP 4: VERIFY RESOLUTION & COMPLIANCE
# ------------------------------------------------------------------------------
# Verify deployment rollout:
# $ kubectl rollout status deployment/payment-gateway -n production-sec
#
# Confirm active running Pods:
# $ kubectl get pods -n production-sec -l app=payment-gateway
# ==============================================================================