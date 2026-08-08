#!/usr/bin/env bash
# ==============================================================================
# CNCF CNPE Exam Prep - Topic 5.1: Designing & Creating CRDs for Platform Services
# Lab Scenario: Break & Fix Custom Resource Definition Validation & Architecture
# Target Exam Weight: 6.25%
# Reference: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}   CNPE Lab 5.1: Custom Resource Definition (CRD) Break & Fix Lab     ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Prerequisite Checks
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}ERROR: 'kubectl' executable not found in PATH.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}ERROR: Cannot communicate with target Kubernetes cluster.${NC}"
    exit 1
fi

LAB_NS="cnpe-crd-lab"
echo -e "${YELLOW}[+] Preparing lab namespace '${LAB_NS}'...${NC}"
kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# Clean previous lab state if present
kubectl delete crd postgresclusters.db.platform.io --ignore-not-found=true > /dev/null 2>&1 || true

BROKEN_CRD_PATH="/tmp/cnpe-postgrescluster-crd-broken.yaml"
TARGET_CR_PATH="/tmp/cnpe-postgrescluster-cr.yaml"

# Inject flawed CRD definition into lab workspace
cat << 'EOF' > "${BROKEN_CRD_PATH}"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresclusters.db.platform.io
spec:
  group: db.platform.io
  names:
    kind: PostgresCluster
    listKind: PostgresClusterList
    plural: postgresclusters
    singular: postgrescluster
    shortNames:
    - pg
  scope: Cluster
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required:
            - storageSize
            - replicas
            properties:
              engineVersion:
                type: string
                default: "15"
              replicas:
                type: string
                minimum: 1
              storageSize:
                type: string
                pattern: '^[0-9]+(Gi|Mi)$'
          status:
            type: object
            properties:
              conditions:
                type: array
                items:
                  type: object
                  properties:
                    type:
                      type: string
                    status:
                      type: string
                    lastTransitionTime:
                      type: string
EOF

# Inject desired Custom Resource manifest that should be deployable by tenant teams
cat << 'EOF' > "${TARGET_CR_PATH}"
apiVersion: db.platform.io/v1alpha1
kind: PostgresCluster
metadata:
  name: prod-db-instance
  namespace: cnpe-crd-lab
spec:
  engineVersion: "15.4"
  replicas: 3
  storageSize: 100Gi
EOF

echo -e "${YELLOW}[+] Deploying broken platform CRD ('postgresclusters.db.platform.io')...${NC}"
kubectl apply -f "${BROKEN_CRD_PATH}" > /dev/null

echo -e "\n${RED}======================================================================${NC}"
echo -e "${RED}                       LAB SCENARIO & SYMPTOMS                        ${NC}"
echo -e "${RED}======================================================================${NC}"
echo -e "You are serving as a Senior Platform Engineer on a multi-tenant platform."
echo -e "The database platform sub-team pushed a new Custom Resource Definition (CRD)"
echo -e "to provide Postgres clusters as a service ('postgresclusters.db.platform.io')."
echo -e ""
echo -e "Tenant teams report multiple production issues upon trying to consume the platform:"
echo -e " 1. Attempts to deploy namespaced instances in tenant namespaces fail."
echo -e " 2. Manifest validation fails for numerical fields like 'spec.replicas'."
echo -e " 3. Platform operators cannot update resource status isolated from main spec."
echo -e " 4. 'kubectl get pg' output lacks critical summary columns (Replicas, Version, Age)."
echo -e ""
echo -e "Test the failure by executing:"
echo -e "  ${YELLOW}kubectl apply -f ${TARGET_CR_PATH}${NC}"
echo -e ""

echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}                        STUDENT OBJECTIVES                            ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e "Re-architect and fix the CRD 'postgresclusters.db.platform.io' to satisfy:"
echo -e " 1. Set CRD scope to 'Namespaced' to support multi-tenancy."
echo -e " 2. Fix openAPIV3Schema validation for 'spec.replicas' (must be integer, min 1)."
echo -e " 3. Enable the status subresource ('subresources.status: {}')."
echo -e " 4. Add additionalPrinterColumns for 'kubectl get' terminal formatting:"
echo -e "    - Column 'Replicas' -> JSON path '.spec.replicas', type 'integer'"
echo -e "    - Column 'Version'  -> JSON path '.spec.engineVersion', type 'string'"
echo -e "    - Column 'Age'      -> JSON path '.metadata.creationTimestamp', type 'date'"
echo -e " 5. Ensure target manifest '${TARGET_CR_PATH}' applies successfully."
echo -e " 6. Verify status update capability using the status subresource endpoint."
echo -e ""
echo -e "${BLUE}Target CR File Location: ${TARGET_CR_PATH}${NC}"
echo -e "${BLUE}Inspect active CRD: kubectl get crd postgresclusters.db.platform.io -o yaml${NC}\n"

# ==============================================================================
# SOLUTION AND DIAGNOSTIC STEPS (KEEP COMMENTED OUT FOR STUDENT EXERCISES)
# ==============================================================================
#
# STEP-BY-STEP DIAGNOSIS & SOLUTION:
#
# Step 1: Diagnose symptoms by applying the target Custom Resource:
#   kubectl apply -f /tmp/cnpe-postgrescluster-cr.yaml
#   Error 1: "an empty namespace may not be set when creating a resource with a cluster scoped socket"
#            -> Root cause: CRD spec.scope is set to 'Cluster' instead of 'Namespaced'.
#   Error 2: "Invalid value: string: spec.replicas in body must be of type integer"
#            -> Root cause: openAPIV3Schema defines spec.replicas as 'type: string'.
#
# Step 2: Write a corrected CRD manifest to /tmp/cnpe-postgrescluster-crd-fixed.yaml:
#
# cat << 'EOF' > /tmp/cnpe-postgrescluster-crd-fixed.yaml
# apiVersion: apiextensions.k8s.io/v1
# kind: CustomResourceDefinition
# metadata:
#   name: postgresclusters.db.platform.io
# spec:
#   group: db.platform.io
#   names:
#     kind: PostgresCluster
#     listKind: PostgresClusterList
#     plural: postgresclusters
#     singular: postgrescluster
#     shortNames:
#     - pg
#   scope: Namespaced
#   versions:
#   - name: v1alpha1
#     served: true
#     storage: true
#     subresources:
#       status: {}
#     additionalPrinterColumns:
#     - name: Replicas
#       type: integer
#       jsonPath: .spec.replicas
#     - name: Version
#       type: string
#       jsonPath: .spec.engineVersion
#     - name: Age
#       type: date
#       jsonPath: .metadata.creationTimestamp
#     schema:
#       openAPIV3Schema:
#         type: object
#         properties:
#           spec:
#             type: object
#             required:
#             - storageSize
#             - replicas
#             properties:
#               engineVersion:
#                 type: string
#                 default: "15"
#               replicas:
#                 type: integer
#                 minimum: 1
#               storageSize:
#                 type: string
#                 pattern: '^[0-9]+(Gi|Mi)$'
#           status:
#             type: object
#             properties:
#               conditions:
#                 type: array
#                 items:
#                   type: object
#                   properties:
#                     type:
#                       type: string
#                     status:
#                       type: string
#                     lastTransitionTime:
#                       type: string
# EOF
#
# Step 3: Apply fixed CRD definition:
#   kubectl apply -f /tmp/cnpe-postgrescluster-crd-fixed.yaml
#
# Step 4: Apply target Custom Resource:
#   kubectl apply -f /tmp/cnpe-postgrescluster-cr.yaml
#   Expected Output: postgrescluster.db.platform.io/prod-db-instance created
#
# Step 5: Verify additionalPrinterColumns output:
#   kubectl get pg -n cnpe-crd-lab
#   Expected Output:
#   NAME               REPLICAS   VERSION   AGE
#   prod-db-instance   3          15.4      15s
#
# Step 6: Verify status subresource mutation capability (Operator simulation):
#   kubectl patch postgrescluster prod-db-instance -n cnpe-crd-lab \
#     --subresource='status' \
#     --type='merge' \
#     -p '{"status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": "2026-08-07T19:00:00Z"}]}}'
#
#   kubectl get pg prod-db-instance -n cnpe-crd-lab -o jsonpath='{.status.conditions[0].type}'
#   Expected Output: Ready
# ==============================================================================