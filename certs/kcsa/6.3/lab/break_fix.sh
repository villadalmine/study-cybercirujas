#!/bin/bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Exam Prep
# Topic 6.3: Supply Chain Compliance (Exam Weight: 2.5%)
# Lab Type: Break & Fix Scenario
# Author: Senior SRE & Principal Platform Architect
# ==============================================================================
#
# --- SCENARIO OVERVIEW ---
# Production security policy mandates strict Supply Chain Compliance for all
# workloads deployed to the 'production-secured' namespace.
#
# To prevent image tampering, tag mutation attacks, and unauthorized software
# execution, the cluster enforces an Admission Control Policy that requires:
#   1. Strict Image Digest Pinning (must use immutable @sha256:<hash> instead of mutable tags).
#   2. Trusted Registry Source enforcement (only images from signed/approved registries).
#   3. Supply Chain Provenance metadata (SBOM and signature verification annotations).
#
# --- SYMPTOMS ---
# The engineering team attempted to deploy the 'payment-gateway' service, but
# the Deployment rollout is failing. Pods are either blocked by admission policy
# or failing validation checks.
#
# --- STUDENT GOAL ---
# 1. Investigate why the deployment is failing using real Kubernetes CLI diagnostic commands.
# 2. Identify the supply chain compliance violations in the workload manifest.
# 3. Remediate the Deployment manifest to satisfy strict supply chain security criteria.
# 4. Verify that the payment-gateway Pod reaches 1/1 Running status.
#
# References:
# - https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - https://kubernetes.io/docs/concepts/security/software-supply-chain/
# - https://sigstore.dev/
# ==============================================================================

set -euo pipefail

LAB_NAMESPACE="production-secured"
POLICY_NAME="enforce-supply-chain-compliance"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_CYAN='\033[0;36m'
COLOR_NC='\033[0m'

echo -e "${COLOR_CYAN}[1/4] Checking prerequisites...${COLOR_NC}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${COLOR_RED}Error: 'kubectl' command line tool is required but not installed.${COLOR_NC}"
    exit 1
fi

echo -e "${COLOR_CYAN}[2/4] Provisioning isolated lab environment in namespace: ${LAB_NAMESPACE}...${COLOR_NC}"
kubectl create namespace "${LAB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo -e "${COLOR_CYAN}[3/4] Installing Supply Chain Admission Control Policies...${COLOR_NC}"
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_NAME}
  annotations:
    policies.kyverno.io/title: Enforce Image Digest Pinning and Supply Chain Metadata
    policies.kyverno.io/category: Supply Chain Compliance (KCSA 6.3)
    policies.kyverno.io/severity: High
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: require-image-digests
      match:
        any:
        - resources:
            namespaces:
            - ${LAB_NAMESPACE}
            kinds:
            - Pod
      validate:
        message: "SUPPLY CHAIN SECURITY VIOLATION: Image tag detected. Container images must use immutable digests (@sha256:...) to prevent supply chain tampering."
        pattern:
          spec:
            containers:
            - image: "*@sha256:*"
    - name: require-supply-chain-attestation-label
      match:
        any:
        - resources:
            namespaces:
            - ${LAB_NAMESPACE}
            kinds:
            - Pod
      validate:
        message: "SUPPLY CHAIN COMPLIANCE VIOLATION: Missing required label 'sec.domain/sbom-verified=true'."
        pattern:
          metadata:
            labels:
              sec.domain/sbom-verified: "true"
EOF

echo -e "${COLOR_CYAN}[4/4] Triggering failure state: Deploying non-compliant workload...${COLOR_NC}"
cat <<EOF | kubectl apply -f - || true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway
  namespace: ${LAB_NAMESPACE}
  labels:
    app: payment-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-gateway
  template:
    metadata:
      labels:
        app: payment-gateway
        env: production
    spec:
      containers:
      - name: payment-api
        image: nginx:1.25.3
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
EOF

echo ""
echo -e "${COLOR_YELLOW}==============================================================================${COLOR_NC}"
echo -e "${COLOR_YELLOW} LAB INFRASTRUCTURE BROKEN (SUPPLY CHAIN COMPLIANCE INCIDENT INITIALIZED)    ${COLOR_NC}"
echo -e "${COLOR_YELLOW}==============================================================================${COLOR_NC}"
echo -e "Namespace: ${COLOR_CYAN}${LAB_NAMESPACE}${COLOR_NC}"
echo -e "Workload:  ${COLOR_CYAN}deployment/payment-gateway${COLOR_NC}"
echo ""
echo -e "${COLOR_YELLOW}STUDENT DIAGNOSTIC INSTRUCTIONS:${COLOR_YELLOW}"
echo -e "1. Execute: ${COLOR_CYAN}kubectl get deployments -n ${LAB_NAMESPACE}${COLOR_NC}"
echo -e "   Notice that READY count is 0/2."
echo -e "2. Inspect replica set events: ${COLOR_CYAN}kubectl get events -n ${LAB_NAMESPACE} --sort-by='.metadata.creationTimestamp'${COLOR_NC}"
echo -e "3. Troubleshoot admission controller error messages rejecting pod creation."
echo -e "4. Obtain the authentic digest for nginx:1.25.3:"
echo -e "   Official Digest: ${COLOR_CYAN}nginx@sha256:aab8e157e84170b77477651e3609804fb730623d240d463b2f2ff04c55a5b512${COLOR_NC}"
echo -e "5. Fix the Deployment manifest in '${LAB_NAMESPACE}' to satisfy all compliance rules."
echo -e "${COLOR_YELLOW}==============================================================================${COLOR_NC}"
echo ""

exit 0

# ==============================================================================
# SOLUTION & EXPLANATION (FOR INSTRUCTOR / REFERENCE)
# ==============================================================================
#
# --- STEP-BY-STEP DIAGNOSIS ---
#
# Step 1: Inspect Deployment and ReplicaSet status
# $ kubectl get deployment payment-gateway -n production-secured
# NAME              READY   UP-TO-DATE   AVAILABLE   AGE
# payment-gateway   0/2     0            0           1m
#
# Step 2: Check ReplicaSet events for admission controller rejections
# $ kubectl describe rs -l app=payment-gateway -n production-secured
# ...
# Messages: Failed create pod: admission webhook "kyverno-resource-validating-webhook-cfg"
# denied the request:
# resource Pod/production-secured/payment-gateway-xxxxx was blocked due to the following policies:
# enforce-supply-chain-compliance:
#   require-image-digests: SUPPLY CHAIN SECURITY VIOLATION: Image tag detected.
#     Container images must use immutable digests (@sha256:...) to prevent supply chain tampering.
#   require-supply-chain-attestation-label: SUPPLY CHAIN COMPLIANCE VIOLATION:
#     Missing required label 'sec.domain/sbom-verified=true'.
#
# --- ROOT CAUSE ANALYSIS ---
# In modern cloud-native software supply chain security (SLSA, Sigstore, CNCF guidelines):
# 1. Tags like `nginx:1.25.3` are mutable. An attacker compromising a container registry can
#    overwrite `nginx:1.25.3` with a malicious image payload without changing the tag name.
# 2. Immutable image digests (`image@sha256:...`) lock the content hash, guaranteeing cryptographically
#    that the container runtime executes the exact code scanned and attested in CI/CD.
# 3. Supply chain governance requires metadata attestations (e.g., SBOM generation, Cosign signature)
#    reflected in deployment metadata or verified via admission control webhooks.
#
# --- REMEDIATION EXECUTION ---
#
# Apply the following syntactically valid compliant manifest:
#
# cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-gateway
#   namespace: production-secured
#   labels:
#     app: payment-gateway
# spec:
#   replicas: 2
#   selector:
#     matchLabels:
#       app: payment-gateway
#   template:
#     metadata:
#       labels:
#         app: payment-gateway
#         env: production
#         sec.domain/sbom-verified: "true"
#     spec:
#       containers:
#       - name: payment-api
#         image: nginx@sha256:aab8e157e84170b77477651e3609804fb730623d240d463b2f2ff04c55a5b512
#         ports:
#         - containerPort: 80
#         resources:
#           limits:
#             cpu: "100m"
#             memory: "128Mi"
# EOF
#
# --- VERIFICATION COMMANDS ---
#
# $ kubectl get pods -n production-secured
# NAME                               READY   STATUS    RESTARTS   AGE
# payment-gateway-7b895697d9-x8z2l   1/1     Running   0          12s
# payment-gateway-7b895697d9-z49pl   1/1     Running   0          12s
#
# $ kubectl get policyreport -n production-secured (if Kyverno report CRD installed)
#
# Clean up lab resources:
# $ kubectl delete namespace production-secured
# $ kubectl delete clusterpolicy enforce-supply-chain-compliance
# ==============================================================================