#!/usr/bin/env bash
# ==============================================================================
# CNCF CNPE (Certified Cloud Native Platform Engineer) Exam Prep
# Topic 5.2: Implementing Workflows for Self-Service Provisioning Using Platform APIs
# Weight: 6.25%
#
# References:
# - CNCF CNPE Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# - Kubernetes API Extensions & CRDs: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
# - Dynamic Admission Control: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
# - Crossplane Composite Resource Definitions (XRDs): https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
#
# ARCHITECTURAL OVERVIEW & MECHANICS:
# Platform APIs abstract infrastructure complexity behind custom declarative contracts 
# (Custom Resource Definitions / Crossplane XRDs). A typical self-service workflow consists of:
# 1. Developer Submits Intent: An unprivileged service account applies a Custom Resource (CR) 
#    to request a platform resource (e.g., PostgreSQL instance, S3 Bucket, Namespace tenant).
# 2. API Server Authentication & Authorization: RBAC rules determine if the user can interact 
#    with the API group `platform.cncf.io/v1alpha1`.
# 3. Dynamic Admission Control (Validating/Mutating Webhook): Intercepts the request to enforce 
#    organizational guardrails, default values, and schema compliance prior to persistence in etcd.
# 4. Asynchronous Controller / Workflow Execution: A controller (e.g., Crossplane provider, 
#    Kratix compound promise, or custom operator) reconciles the intent, provisions cloud resources, 
#    and writes status back to the CR subresource `status`.
#
# TRADE-OFFS & ARCHITECTURAL CONSIDERATIONS:
# - Schema Validation: OpenAPI v3 Validation vs. Dynamic Webhooks. OpenAPI schemas fail fast at API 
#   admission with low latency, but cannot execute dynamic logic (e.g., checking external quota APIs).
# - RBAC Granularity: Granting cluster-wide permissions to self-service APIs risks privilege escalation 
#   if CR fields allow specifying host paths or IAM roles. Permissions must be scoped strictly via 
#   Namespaces or dedicated RBAC API groups.
# - Status Subresource Isolation: Isolating `.status` via CRD subresources prevents tenants from spoofing 
#   their own provisioning status, preserving control loop integrity.
# ==============================================================================

set -euo pipefail

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Context setup
NAMESPACE="platform-selfservice"
DEV_SA="developer-user"
CRD_NAME="postgresqlclaims.platform.cncf.io"

echo -e "${CYAN}[+] Initializing CNPE Topic 5.2 Lab Environment...${NC}"

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[!] Error: kubectl is required to run this lab break script.${NC}"
    exit 1
fi

# Ensure cleanup on re-run
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true &> /dev/null || true
kubectl delete crd ${CRD_NAME} --ignore-not-found=true &> /dev/null || true
kubectl delete clusterrole developer-platform-provisioner --ignore-not-found=true &> /dev/null || true
kubectl delete clusterrolebinding developer-platform-provisioner-binding --ignore-not-found=true &> /dev/null || true

# Step 1: Create Namespace and ServiceAccount representing self-service tenant
kubectl create namespace ${NAMESPACE} > /dev/null

kubectl create serviceaccount ${DEV_SA} -n ${NAMESPACE} > /dev/null

# Step 2: Inject Broken CRD (Platform API Schema missing status subresource and corrupt schema)
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD_NAME}
spec:
  group: platform.cncf.io
  names:
    kind: PostgreSQLClaim
    listKind: PostgreSQLClaimList
    plural: postgresqlclaims
    singular: postgresqlclaim
    shortNames:
    - pgclaim
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    # ISSUE 1: Missing subresources.status block prevents controller status updates without mutating spec
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required:
            - storageGb
            - engineVersion
            properties:
              storageGb:
                type: integer
                minimum: 10
                maximum: 500
              engineVersion:
                type: string
              # ISSUE 2: Strict Enum misconfiguration breaking valid provisioning requests
              tier:
                type: string
                enum:
                - Enterprise-HA
                - Standard-Single
EOF

# Step 3: Inject Broken RBAC (Typo in API Group prevents tenant from submitting claims)
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: developer-platform-provisioner
rules:
- apiGroups:
  - "platform.cncf.org" # ISSUE 3: Typos in API Group ("platform.cncf.org" instead of "platform.cncf.io")
  resources:
  - postgresqlclaims
  verbs:
  - create
  - get
  - list
  - watch
EOF

cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developer-platform-provisioner-binding
subjects:
- kind: ServiceAccount
  name: ${DEV_SA}
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: developer-platform-provisioner
  apiGroup: rbac.authorization.k8s.io
EOF

# Step 4: Display Problem Statement & Instructions
echo -e "\n=========================================================================="
echo -e "${RED}LAB SCENARIO BROKEN: Self-Service Provisioning API Failure${NC}"
echo -e "=========================================================================="
echo -e "Platform Engineers have published a new Self-Service API for database claims"
echo -e "under group '${CYAN}platform.cncf.io/v1alpha1${NC}', Kind '${CYAN}PostgreSQLClaim${NC}'."
echo -e ""
echo -e "Developer ServiceAccount '${CYAN}${DEV_SA}${NC}' in namespace '${CYAN}${NAMESPACE}${NC}'"
echo -e "is trying to provision a database using the following manifest:"
echo -e ""
echo -e "  apiVersion: platform.cncf.io/v1alpha1"
echo -e "  kind: PostgreSQLClaim"
echo -e "  metadata:"
echo -e "    name: orders-db"
echo -e "    namespace: ${NAMESPACE}"
echo -e "  spec:"
echo -e "    storageGb: 20"
echo -e "    engineVersion: \"15\""
echo -e "    tier: \"Standard-Single\""
echo -e ""
echo -e "${YELLOW}SYMPTOMS REPORTED BY DEVELOPERS:${NC}"
echo -e "1. ServiceAccount '${DEV_SA}' receives HTTP 403 Forbidden when executing:"
echo -e "   kubectl apply --as=system:serviceaccount:${NAMESPACE}:${DEV_SA} -n ${NAMESPACE} -f claim.yaml"
echo -e "2. Platform controller logs report failures when writing status updates to claims."
echo -e "3. Valid requests for tier 'Standard-Single' are failing OpenAPI schema validation."
echo -e ""
echo -e "${GREEN}OBJECTIVE:${NC}"
echo -e "Diagnose and fix the API Definition and RBAC configuration without granting"
echo -e "excessive privileges (e.g. do not give cluster-admin)."
echo -e "Verify that ServiceAccount '${DEV_SA}' can successfully create and describe"
echo -e "PostgreSQLClaim resources in '${NAMESPACE}'."
echo -e "=========================================================================="
echo -e "\nRun your diagnostic commands now. (Solution guide is available inside this script file).\n"

exit 0

# ==============================================================================
# TROUBLESHOOTING & SOLUTION GUIDE (STEP-BY-STEP)
# ==============================================================================
#
# ROOT CAUSE ANALYSIS:
# 1. RBAC API Group Mismatch:
#    The ClusterRole `developer-platform-provisioner` references `apiGroups: ["platform.cncf.org"]`.
#    The actual CRD API group is `platform.cncf.io`. Because RBAC checks are exact string matches,
#    requests from `developer-user` are rejected with HTTP 403 Forbidden.
#
# 2. Missing Subresource Status Definition:
#    The CRD spec lacks `spec.versions[].subresources.status: {}`. Without this, Kubernetes does 
#    not expose the `/status` REST endpoint subresource (`/apis/platform.cncf.io/v1alpha1/namespaces/platform-selfservice/postgresqlclaims/orders-db/status`).
#    Controllers trying to update `.status` will modify the main spec revision, leading to 
#    optimistic concurrency conflicts (409 Conflict) or validation re-triggers.
#
# 3. CRD OpenAPI v3 Validation Enum Case/Typo:
#    The CRD OpenAPI schema defines `tier` enum values strictly. If an invalid enum or schema mismatch
#    is present, the API server rejects the POST payload at the validation stage before reaching the controller.
#
# DIAGNOSTIC COMMANDS:
#
# Step 1: Test RBAC permissions as the target ServiceAccount
# $ kubectl auth can-i create postgresqlclaims.platform.cncf.io \
#     --as=system:serviceaccount:platform-selfservice:developer-user \
#     -n platform-selfservice
# Expected output: no (Explanation: confirms RBAC misconfiguration)
#
# Step 2: Inspect ClusterRole rules
# $ kubectl get clusterrole developer-platform-provisioner -o yaml
# Expected output shows:
#   apiGroups:
#   - platform.cncf.org # <--- INCORRECT (should be platform.cncf.io)
#
# Step 3: Test applying sample manifest as developer
# $ cat <<EOF | kubectl apply --as=system:serviceaccount:platform-selfservice:developer-user -n platform-selfservice -f -
# apiVersion: platform.cncf.io/v1alpha1
# kind: PostgreSQLClaim
# metadata:
#   name: orders-db
# spec:
#   storageGb: 20
#   engineVersion: "15"
#   tier: "Standard-Single"
# EOF
# Expected output prior to fix: Error from server (Forbidden): postgresqlclaims.platform.cncf.io is forbidden...
#
# Step 4: Inspect CRD subresource configuration
# $ kubectl get crd postgresqlclaims.platform.cncf.io -o jsonpath='{.spec.versions[*].subresources}'
# Expected output: empty or missing status block.
#
# ==============================================================================
# REMEDIATION MANIFESTS & COMMANDS
# ==============================================================================
#
# FIX 1: Update ClusterRole API Group
# ------------------------------------------------------------------------------
# kubectl patch clusterrole developer-platform-provisioner --type='json' -p='[
#   {"op": "replace", "path": "/rules/0/apiGroups/0", "value": "platform.cncf.io"}
# ]'
#
# FIX 2: Enable Status Subresource in CRD Schema
# ------------------------------------------------------------------------------
# kubectl patch crd postgresqlclaims.platform.cncf.io --type='merge' -p='{
#   "spec": {
#     "versions": [
#       {
#         "name": "v1alpha1",
#         "served": true,
#         "storage": true,
#         "subresources": {
#           "status": {}
#         },
#         "schema": {
#           "openAPIV3Schema": {
#             "type": "object",
#             "properties": {
#               "spec": {
#                 "type": "object",
#                 "required": ["storageGb", "engineVersion"],
#                 "properties": {
#                   "storageGb": {"type": "integer", "minimum": 10, "maximum": 500},
#                   "engineVersion": {"type": "string"},
#                   "tier": {"type": "string", "enum": ["Enterprise-HA", "Standard-Single"]}
#                 }
#               },
#               "status": {
#                 "type": "object",
#                 "properties": {
#                   "phase": {"type": "string"},
#                   "endpoint": {"type": "string"}
#                 }
#               }
#             }
#           }
#         }
#       }
#     ]
#   }
# }'
#
# VERIFICATION COMMANDS:
#
# 1. Verify RBAC Authorization:
# $ kubectl auth can-i create postgresqlclaims.platform.cncf.io \
#     --as=system:serviceaccount:platform-selfservice:developer-user \
#     -n platform-selfservice
# Expected Output: yes
#
# 2. Test Self-Service Resource Creation:
# $ cat <<EOF | kubectl apply --as=system:serviceaccount:platform-selfservice:developer-user -n platform-selfservice -f -
# apiVersion: platform.cncf.io/v1alpha1
# kind: PostgreSQLClaim
# metadata:
#   name: orders-db
# spec:
#   storageGb: 20
#   engineVersion: "15"
#   tier: "Standard-Single"
# EOF
# Expected Output: postgresqlclaim.platform.cncf.io/orders-db created
#
# 3. Simulate Platform Controller Status Update to the Subresource:
# $ kubectl status patch or raw REST update:
# $ kubectl patch postgresqlclaim orders-db -n platform-selfservice --subresource=status --type='merge' -p='{"status": {"phase": "Ready", "endpoint": "postgres.internal:5432"}}'
# Expected Output: postgresqlclaim.platform.cncf.io/orders-db patched
#
# 4. Verify Final State:
# $ kubectl get pgclaim orders-db -n platform-selfservice -o yaml
# Expected Output: Spec and Status are separated cleanly, phase shows "Ready".
# ==============================================================================