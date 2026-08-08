#!/usr/bin/env bash
# ==============================================================================
# CNCF Certified Networked / Platform Engineer (CNPE) Exam Preparation
# Topic 5.4: Using Automation Frameworks for Self-Service Provisioning
# Exam Weight: 6.25%
#
# Reference Sources:
# - CNCF Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# - Crossplane Compositions & XRD Mechanics: https://docs.crossplane.io/latest/concepts/compositions/
# - Kubernetes API Extension & CRD Schema Validation: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
#
# Description:
# This script simulates a production self-service provisioning failure in a 
# Kubernetes platform environment using an abstraction framework (Crossplane-style 
# XRD & Composition architecture). It introduces an invalid JSON path and schema 
# patch mismatch in the Composition controller manifest, causing developer claims 
# to stall during self-service database provisioning.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

NAMESPACE="cnpe-selfservice-lab"

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE}  CNPE Scenario 5.4: Self-Service Provisioning Automation (Break & Fix)       ${NC}"
echo -e "${BLUE}==============================================================================${NC}"

# 1. Environment Verification
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[!] ERROR: 'kubectl' binary not found. Run this script in a Kubernetes environment.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[!] ERROR: Unable to connect to a valid Kubernetes API server.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}[Step 1/4] Creating isolated lab namespace '${NAMESPACE}'...${NC}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# 2. Deploy Infrastructure Abstraction API (CompositeResourceDefinition / CustomResourceDefinition)
echo -e "${YELLOW}[Step 2/4] Registering Platform Self-Service API (CompositeResourceDefinition)...${NC}"
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: xpostgresqlinstances.platform.example.com
spec:
  group: platform.example.com
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
    singular: xpostgresqlinstance
    shortNames:
      - xpostgres
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
              - storageGB
              - engineVersion
            properties:
              storageGB:
                type: integer
                minimum: 10
                maximum: 500
              engineVersion:
                type: string
          status:
            type: object
            properties:
              bindingStatus:
                type: string
              provisionedEndpoint:
                type: string
EOF

# 3. Inject Broken Composition Automation Framework Config
echo -e "${YELLOW}[Step 3/4] Injecting defective field-mapping patch into Automation Framework Composition...${NC}"
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: composition-rds-postgres-auto
  namespace: ${NAMESPACE}
  labels:
    framework.cncf.io/type: composition
    platform.example.com/target-kind: XPostgreSQLInstance
data:
  composition.yaml: |
    apiVersion: platform.example.com/v1alpha1
    kind: CompositionDefinition
    metadata:
      name: rds-postgres-auto-provision
    spec:
      compositeTypeRef:
        apiVersion: platform.example.com/v1alpha1
        kind: XPostgreSQLInstance
      resources:
        - name: managedRdsInstance
          base:
            apiVersion: database.aws.crossplane.io/v1beta1
            kind: RDSInstance
            spec:
              forProvider:
                dbInstanceClass: db.t3.micro
                engine: postgres
                allocatedStorage: 20
          patches:
            # DEFECT 1: Incorrect JSON field path reference ('storageSizeMB' does not exist in XRD schema 'storageGB')
            - type: FromCompositeFieldPath
              fromFieldPath: "spec.storageSizeMB"
              toFieldPath: "spec.forProvider.allocatedStorage"
            # DEFECT 2: Invalid target path mapping ('spec.engineVersion' mapped to missing key)
            - type: FromCompositeFieldPath
              fromFieldPath: "spec.engineVersion"
              toFieldPath: "spec.forProvider.dbEngineVersion"
EOF

# 4. Trigger Developer Self-Service Request (Resource Claim)
echo -e "${YELLOW}[Step 4/4] Submitting Developer Infrastructure Self-Service Claim...${NC}"
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - > /dev/null
apiVersion: platform.example.com/v1alpha1
kind: XPostgreSQLInstance
metadata:
  name: dev-team-db-claim
  namespace: ${NAMESPACE}
  annotations:
    composition.platform.example.com/name: "rds-postgres-auto-provision"
spec:
  storageGB: 50
  engineVersion: "15.3"
EOF

echo -e "\n${GREEN}[✓] Lab setup finished. Failure successfully injected!${NC}"
echo -e "${BLUE}==============================================================================${NC}"
echo -e "${CYAN}SRE INCIDENT REPORT & STUDENT TASK:${NC}"
echo -e "A developer team submitted a self-service provisioning claim for a PostgreSQL instance."
echo -e "However, the automation rendering pipeline failed to synthesize the underlying managed resource."
echo -e ""
echo -e "${YELLOW}OBSERVED SYMPTOMS:${NC}"
echo -e "1. Running 'kubectl get xpostgresqlinstance -n ${NAMESPACE}' shows binding state pending or incomplete."
echo -e "2. Automation controller logs or resource manifests report field resolution errors during composition rendering."
echo -e ""
echo -e "${YELLOW}YOUR GOAL:${NC}"
echo -e "Diagnose the schema definition vs composition field-path mapping defect, fix the ConfigMap"
echo -e "'composition-rds-postgres-auto' in namespace '${NAMESPACE}', and ensure valid composition rendering."
echo -e "${BLUE}==============================================================================${NC}\n"

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & ARCHITECTURAL ANALYSIS (STUDENT REFERENCE)
# ==============================================================================
#
# --- TECHNICAL BACKGROUND & MECHANICS ---
# In modern Platform Engineering (CNCF Self-Service Provisioning paradigm), infrastructure 
# abstractions separate the Developer API (Claims / XRDs) from the Infrastructure Provider 
# implementation (Compositions / Managed Resources).
#
# When a developer creates a Claim, the Automation Controller inspects the bound Composition 
# and executes field-path transformations (Patches). If a patch references a field path in 
# `fromFieldPath` that is not declared in the XRD OpenAPI v3 schema, or targets an invalid 
# provider schema in `toFieldPath`, the composition engine fails to render the template manifest.
#
# --- DIAGNOSTIC WORKFLOW ---
#
# Step 1: Check the status of the requested self-service resource:
#   kubectl get xpostgresqlinstance dev-team-db-claim -n cnpe-selfservice-lab -o yaml
#
# Step 2: Inspect the Custom Resource Definition (XRD) schema contract:
#   kubectl get crd xpostgresqlinstances.platform.example.com -o yaml
#   (Observe under spec.versions[0].schema.openAPIV3Schema.properties.spec:
#    The defined field is `storageGB` and `engineVersion`.)
#
# Step 3: Inspect the active Composition configuration mapping:
#   kubectl get configmap composition-rds-postgres-auto -n cnpe-selfservice-lab -o yaml
#
# Step 4: Identify defects in data.composition.yaml:
#   - Defect A: `fromFieldPath: "spec.storageSizeMB"` is invalid (must be `spec.storageGB`).
#   - Defect B: `toFieldPath: "spec.forProvider.dbEngineVersion"` is invalid (must be `spec.forProvider.engineVersion`).
#
# --- RESOLUTION & REMEDIATION COMMANDS ---
#
# Apply the corrected Composition manifest containing valid patch field paths:
#
# cat <<EOF | kubectl apply -f -
# apiVersion: v1
# kind: ConfigMap
# metadata:
#   name: composition-rds-postgres-auto
#   namespace: cnpe-selfservice-lab
#   labels:
#     framework.cncf.io/type: composition
#     platform.example.com/target-kind: XPostgreSQLInstance
# data:
#   composition.yaml: |
#     apiVersion: platform.example.com/v1alpha1
#     kind: CompositionDefinition
#     metadata:
#       name: rds-postgres-auto-provision
#     spec:
#       compositeTypeRef:
#         apiVersion: platform.example.com/v1alpha1
#         kind: XPostgreSQLInstance
#       resources:
#         - name: managedRdsInstance
#           base:
#             apiVersion: database.aws.crossplane.io/v1beta1
#             kind: RDSInstance
#             spec:
#               forProvider:
#                 dbInstanceClass: db.t3.micro
#                 engine: postgres
#                 allocatedStorage: 20
#           patches:
#             - type: FromCompositeFieldPath
#               fromFieldPath: "spec.storageGB"
#               toFieldPath: "spec.forProvider.allocatedStorage"
#             - type: FromCompositeFieldPath
#               fromFieldPath: "spec.engineVersion"
#               toFieldPath: "spec.forProvider.engine"
# EOF
#
# --- VERIFICATION & CLEANUP ---
#
# 1. Verify resource claim schema compliance:
#    kubectl get xpostgresqlinstance dev-team-db-claim -n cnpe-selfservice-lab
#
# 2. Teardown lab environment:
#    kubectl delete namespace cnpe-selfservice-lab
#    kubectl delete crd xpostgresqlinstances.platform.example.com
# ==============================================================================