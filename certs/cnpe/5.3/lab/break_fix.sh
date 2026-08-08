#!/usr/bin/env bash
# ==============================================================================
# CNPE (Certified Cloud Native Platform Engineer) Exam Prep Lab
# Topic 5.3: Using Kubernetes Operators for Platform Automation and Integration
# Weight: 6.25%
#
# Reference:
# CNCF Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# Kubernetes Operator Pattern: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
# Custom Resource Definitions (CRDs): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
#
# DESCRIPTION:
# This script deploys a custom Platform Operator (CRD + Controller + Webhook)
# into a target Kubernetes cluster and injects two realistic production faults:
#   1. Controller RBAC Misconfiguration: The Operator's ClusterRole is missing
#      permissions to update custom resource status subresources and manage
#      child Deployments, causing reconciliation failures.
#   2. Webhook Interception Failure: A ValidatingWebhookConfiguration is configured
#      with 'failurePolicy: Fail' pointing to an unreachable service target port,
#      blocking all custom resource apply operations.
#
# SAFETY: Safe to run on any disposable lab cluster (kind, minikube, k3s, eKS).
# Target Namespace: platform-operator-system
# ==============================================================================

set -euo pipefail

LAB_NS="platform-operator-system"
CRD_NAME="databaseclusters.platform.cncf.io"
WEBHOOK_NAME="db-operator-validating-webhook"
ROLE_NAME="db-operator-role"
DEPLOYMENT_NAME="db-operator-controller"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m' # No Color

echo -e "${COLOR_BLUE}[+] Verifying cluster prerequisites...${COLOR_NC}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${COLOR_RED}[!] Error: kubectl is not installed or not in PATH.${COLOR_NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${COLOR_RED}[!] Error: Cannot reach Kubernetes cluster. Ensure KUBECONFIG is set.${COLOR_NC}"
    exit 1
fi

echo -e "${COLOR_BLUE}[+] Provisioning lab namespace '${LAB_NS}'...${COLOR_NC}"
kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f -

echo -e "${COLOR_BLUE}[+] Deploying Custom Resource Definition (${CRD_NAME})...${COLOR_NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD_NAME}
spec:
  group: platform.cncf.io
  names:
    kind: DatabaseCluster
    listKind: DatabaseClusterList
    plural: databaseclusters
    singular: databasecluster
    shortNames:
      - dbc
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required:
                - engine
                - replicas
              properties:
                engine:
                  type: string
                  enum: ["postgres", "mysql", "redis"]
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 10
                storageGb:
                  type: integer
                  default: 10
            status:
              type: object
              properties:
                phase:
                  type: string
                readyReplicas:
                  type: integer
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      type: string
                      status:
                        type: string
                      reason:
                        type: string
                      message:
                        type: string
EOF

echo -e "${COLOR_BLUE}[+] Provisioning Operator ServiceAccount and broken ClusterRole...${COLOR_NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: db-operator-sa
  namespace: ${LAB_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${ROLE_NAME}
rules:
  # FAULT INJECTED: Missing verbs ('update', 'patch') on databaseclusters/status
  # and missing core resource access (deployments, services, configmaps)
  - apiGroups: ["platform.cncf.io"]
    resources: ["databaseclusters"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: db-operator-rolebinding
subjects:
  - kind: ServiceAccount
    name: db-operator-sa
    namespace: ${LAB_NS}
roleRef:
  kind: ClusterRole
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF

echo -e "${COLOR_BLUE}[+] Deploying Operator Controller Deployment...${COLOR_NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${LAB_NS}
  labels:
    app.kubernetes.io/name: db-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: db-operator
  template:
    metadata:
      labels:
        app.kubernetes.io/name: db-operator
    spec:
      serviceAccountName: db-operator-sa
      containers:
        - name: manager
          image: registry.k8s.io/pause:3.9
          command:
            - /bin/sh
            - -c
            - |
              echo "Starting Platform Operator Reconciler Loop..."
              while true; do
                # Simulating controller reconciliation check against API server
                STATUS=\$(curl -s -k -w "%{http_code}" -o /dev/null https://kubernetes.default.svc/apis/platform.cncf.io/v1alpha1/namespaces/${LAB_NS}/databaseclusters \
                  -H "Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)")
                echo "Reconcile cycle tick - API check status: \$STATUS"
                sleep 5
              done
EOF

echo -e "${COLOR_BLUE}[+] Deploying Webhook Service and broken ValidatingWebhookConfiguration...${COLOR_NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: db-operator-webhook-svc
  namespace: ${LAB_NS}
spec:
  ports:
    - port: 443
      targetPort: 9443
  selector:
    app.kubernetes.io/name: db-operator
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: ${WEBHOOK_NAME}
webhooks:
  - name: validate.databaseclusters.platform.cncf.io
    rules:
      - apiGroups: ["platform.cncf.io"]
        apiVersions: ["v1alpha1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["databaseclusters"]
        scope: "Namespaced"
    clientConfig:
      service:
        name: db-operator-webhook-svc
        namespace: ${LAB_NS}
        path: "/validate-platform-cncf-io-v1alpha1-databasecluster"
        # FAULT INJECTED: Target port set to non-existent endpoint (9999) via invalid CA / connection failure
        port: 9999
      caBundle: "Q2VydGlmaWNhdGVGYWtlRGF0YQ=="
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Fail
EOF

echo -e "${COLOR_GREEN}======================================================================${COLOR_NC}"
echo -e "${COLOR_GREEN}               BREAK & FIX CHALLENGE ACTIVATED                        ${COLOR_NC}"
echo -e "${COLOR_GREEN}======================================================================${COLOR_NC}"
echo -e "${COLOR_YELLOW}SCENARIO OVERVIEW:${COLOR_NC}"
echo "You are the Platform Engineer on-call. Your team relies on an Operator to"
echo "automate DatabaseCluster provisioning. Developers are reporting that they cannot"
echo "deploy new DatabaseCluster custom resources, and existing operator controllers"
echo "are failing to reconcile status and manage child workloads."
echo ""
echo -e "${COLOR_YELLOW}SYMPTOMS TO OBSERVE:${COLOR_NC}"
echo "1. Attempting to create a sample DatabaseCluster manifest fails immediately:"
echo "   Command: kubectl apply -n ${LAB_NS} -f - <<MANIFEST"
echo "   apiVersion: platform.cncf.io/v1alpha1"
echo "   kind: DatabaseCluster"
echo "   metadata:"
echo "     name: prod-db"
echo "   spec:"
echo "     engine: postgres"
echo "     replicas: 3"
echo "   MANIFEST"
echo "   Expected Error: Internal error / webhook connection refused / failurePolicy execution failure."
echo ""
echo "2. Check RBAC permissions for the operator controller ServiceAccount ('db-operator-sa'):"
echo "   Command: kubectl auth can-i update databaseclusters/status --as=system:serviceaccount:${LAB_NS}:db-operator-sa -n ${LAB_NS}"
echo "   Expected Result: 'no' (Operator cannot update status subresources)"
echo "   Command: kubectl auth can-i create deployments --as=system:serviceaccount:${LAB_NS}:db-operator-sa -n ${LAB_NS}"
echo "   Expected Result: 'no' (Operator cannot manage operand deployments)"
echo ""
echo -e "${COLOR_YELLOW}YOUR OBJECTIVES:${COLOR_NC}"
echo "1. Resolve the Admission Webhook block so that DatabaseCluster CRs can be created."
echo "2. Fix the RBAC ClusterRole ('${ROLE_NAME}') so the Operator has full reconcile"
echo "   rights over 'databaseclusters', 'databaseclusters/status', 'databaseclusters/finalizers',"
echo "   and underlying operand resources (Deployments, Services, ConfigMaps, Secrets)."
echo "3. Verify successful creation and RBAC authorization."
echo -e "${COLOR_GREEN}======================================================================${COLOR_NC}"

exit 0

# ==============================================================================
#                           STUDENT SOLUTION GUIDE
#                     (DO NOT READ BEFORE ATTEMPTING!)
# ==============================================================================
#
# STEP 1: Diagnose the Webhook Failure
# ------------------------------------------------------------------------------
# Test CR application:
#   kubectl apply -n platform-operator-system -f - <<EOF
#   apiVersion: platform.cncf.io/v1alpha1
#   kind: DatabaseCluster
#   metadata:
#     name: prod-db
#   spec:
#     engine: postgres
#     replicas: 3
#   EOF
#
# Error output:
#   Error from server (InternalError): error when creating "STDIN": Internal error occurred:
#   failed calling webhook "validate.databaseclusters.platform.cncf.io": ... connection refused
#
# Root Cause:
#   ValidatingWebhookConfiguration 'db-operator-validating-webhook' routes traffic to port 9999
#   with failurePolicy: Fail, but no webhook server is listening there.
#
# Fix Webhook:
# Option A (Fix port / bypass broken webhook for lab):
#   kubectl patch validatingwebhookconfiguration db-operator-validating-webhook \
#     --type='json' -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"}]'
#
# Option B (Delete unserviceable webhook if admission validation is handled by CRD schema):
#   kubectl delete validatingwebhookconfiguration db-operator-validating-webhook
#
#
# STEP 2: Diagnose and Remediate Operator RBAC Misconfiguration
# ------------------------------------------------------------------------------
# Test ServiceAccount capabilities using 'kubectl auth can-i':
#   kubectl auth can-i update databaseclusters/status \
#     --as=system:serviceaccount:platform-operator-system:db-operator-sa -n platform-operator-system
#
#   kubectl auth can-i create deployments \
#     --as=system:serviceaccount:platform-operator-system:db-operator-sa -n platform-operator-system
#
# Fix ClusterRole permissions:
#   cat <<EOF | kubectl apply -f -
#   apiVersion: rbac.authorization.k8s.io/v1
#   kind: ClusterRole
#   metadata:
#     name: db-operator-role
#   rules:
#     - apiGroups: ["platform.cncf.io"]
#       resources:
#         - databaseclusters
#         - databaseclusters/status
#         - databaseclusters/finalizers
#       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
#     - apiGroups: ["apps"]
#       resources: ["deployments", "statefulsets"]
#       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
#     - apiGroups: [""]
#       resources: ["services", "configmaps", "secrets", "events"]
#       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
#   EOF
#
# STEP 3: Verification
# ------------------------------------------------------------------------------
# 1. Verify RBAC authorizations pass:
#    kubectl auth can-i update databaseclusters/status \
#      --as=system:serviceaccount:platform-operator-system:db-operator-sa -n platform-operator-system
#    # Output must be: yes
#
# 2. Verify Custom Resource instantiation:
#    kubectl apply -n platform-operator-system -f - <<EOF
#    apiVersion: platform.cncf.io/v1alpha1
#    kind: DatabaseCluster
#    metadata:
#      name: prod-db
#    spec:
#      engine: postgres
#      replicas: 3
#    EOF
#    # Output: databasecluster.platform.cncf.io/prod-db created
#
# 3. Confirm resource list:
#    kubectl get databaseclusters -n platform-operator-system
#    kubectl get dbc -n platform-operator-system
# ==============================================================================