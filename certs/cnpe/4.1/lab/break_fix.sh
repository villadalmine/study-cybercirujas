#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CNCF Certified Cloud Native Platform Engineer (CNPE) Exam Preparation Lab
# Topic 4.1: Implementing GitOps Workflows for Application & Infrastructure Deployment
# Scenario: "Immutable Field Drift & Reconciliation Deadlock in GitOps Pipelines"
#
# Official References:
# - CNCF CNPE Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# - Argo CD Declarative Setup: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
# - Argo CD Sync Mechanics & SyncOptions: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-mechanics/
# - OpenGitOps Standard Specifications: https://opengitops.dev/
# ==============================================================================

# Terminal color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 1. Pre-flight Environment Checks
log_info "Performing pre-flight environment verification..."

if ! command -v kubectl &> /dev/null; then
    log_error "'kubectl' CLI tool is required but not installed. Please install kubectl."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to an active Kubernetes cluster. Ensure your kubeconfig is active."
    exit 1
fi

log_success "Kubernetes cluster connectivity confirmed."

# 2. Lab Setup & Controlled Breakage Execution
LAB_NS="cnpe-gitops-system"
APP_NS="cnpe-prod-app"

log_info "Initializing lab namespaces: '${LAB_NS}' (Control Plane) and '${APP_NS}' (Target Workloads)..."

kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
kubectl create namespace "${APP_NS}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

log_info "Ensuring Argo CD Application CustomResourceDefinition (CRD) is registered..."
if ! kubectl get crd applications.argoproj.io &> /dev/null; then
    kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.10.0/manifests/crds/application-crd.yaml > /dev/null
fi

log_info "Deploying target GitOps workload into namespace '${APP_NS}'..."

cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: Service
metadata:
  name: payment-gateway-svc
  namespace: ${APP_NS}
  labels:
    app.kubernetes.io/name: payment-gateway
    app.kubernetes.io/instance: payment-pipeline
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
  selector:
    app: payment-gateway
    tier: api
EOF

cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway
  namespace: ${APP_NS}
  labels:
    app.kubernetes.io/name: payment-gateway
    app.kubernetes.io/instance: payment-pipeline
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-gateway
  template:
    metadata:
      labels:
        app: payment-gateway
        tier: api
    spec:
      containers:
      - name: web
        image: nginx:1.25-alpine
        ports:
        - containerPort: 8080
EOF

log_warn "Injecting controlled GitOps breakdown: Out-of-band manual drift on immutable Service field..."

# Inject live cluster drift: mutate Service selector (immutable field in K8s Services API)
kubectl patch service payment-gateway-svc -n "${APP_NS}" --type='json' \
  -p='[{"op": "replace", "path": "/spec/selector", "value": {"app": "payment-gateway-v2", "tier": "legacy"}}]' > /dev/null

# Register the declarative Argo CD Application tracking the repository state
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-pipeline
  namespace: ${LAB_NS}
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'https://github.com/cncf-demo/gitops-manifests.git'
    targetRevision: HEAD
    path: apps/payment-gateway
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: ${APP_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - Validate=true
EOF

# Update Application status to mirror an active SyncFailed / Degraded reconciliation loop
kubectl patch application payment-pipeline -n "${LAB_NS}" --type='merge' --subresource=status -p='{
  "status": {
    "sync": {
      "status": "OutOfSync"
    },
    "health": {
      "status": "Degraded"
    },
    "conditions": [
      {
        "type": "SyncError",
        "message": "One or more resources failed to sync: Service \"payment-gateway-svc\" is invalid: spec.selector: field is immutable",
        "lastTransitionTime": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"
      }
    ],
    "operationState": {
      "phase": "Failed",
      "message": "one or more synchronization tasks failed",
      "syncResult": {
        "resources": [
          {
            "group": "",
            "version": "v1",
            "kind": "Service",
            "name": "payment-gateway-svc",
            "namespace": "'"${APP_NS}"'",
            "status": "SyncFailed",
            "message": "Service \"payment-gateway-svc\" is invalid: spec.selector: field is immutable"
          }
        ]
      }
    }
  }
}' > /dev/null 2>&1 || true

log_success "Controlled breakage successfully injected!"

# 3. Output Student Instructions and Diagnostic Guidance
echo ""
echo -e "${CYAN}================================================================================${NC}"
echo -e "${CYAN}            CNPE LAB: GITOPS IMMUTABLE FIELD DRIFT & RECONCILIATION STALL      ${NC}"
echo -e "${CYAN}================================================================================${NC}"
echo ""
echo -e "${YELLOW}SYMPTOM OBSERVED:${NC}"
echo "  The GitOps controller Application 'payment-pipeline' in namespace '${LAB_NS}'"
echo "  is reporting status 'OutOfSync' and 'Degraded' with repeated sync failures."
echo "  An out-of-band change altered an immutable field on live resources, causing"
echo "  Argo CD's automated reconciliation loop to stall."
echo ""
echo -e "${YELLOW}YOUR MISSION:${NC}"
echo "  1. Inspect the Application CRD in namespace '${LAB_NS}' to locate the failing resource."
echo "  2. Compare live state in namespace '${APP_NS}' against desired Git specs."
echo "  3. Fix the reconciliation deadlock using an enterprise GitOps pattern:"
echo "     - Option A: Revert the out-of-band live object drift to match desired Git source."
echo "     - Option B: Configure Application 'syncOptions' with 'Replace=true' to allow object recreation."
echo "  4. Verify that Application status recovers to 'Synced' and 'Healthy'."
echo ""
echo -e "${YELLOW}INITIAL DIAGNOSTIC COMMANDS:${NC}"
echo "  - kubectl get application payment-pipeline -n ${LAB_NS} -o yaml"
echo "  - kubectl get service payment-gateway-svc -n ${APP_NS} -o yaml"
echo ""
echo -e "${CYAN}================================================================================${NC}"
echo ""

exit 0

# ==============================================================================
# SOLUTION (STEP-BY-STEP) - DO NOT UNCOMMENT UNTIL YOU HAVE TRIED TO SOLVE IT
# ==============================================================================
#
# STEP 1: Inspect the GitOps Application Status & Error Conditions
# ------------------------------------------------------------------------------
# Query the Argo CD Application status conditions in the management namespace:
#
# $ kubectl get application payment-pipeline -n cnpe-gitops-system -o jsonpath='{.status.conditions[*].message}'
# Output:
# One or more resources failed to sync: Service "payment-gateway-svc" is invalid: spec.selector: field is immutable
#
# STEP 2: Inspect Live Object State vs Desired Git State
# ------------------------------------------------------------------------------
# Check the current selector on the live Kubernetes Service:
#
# $ kubectl get service payment-gateway-svc -n cnpe-prod-app -o jsonpath='{.spec.selector}'
# Output:
# {"app":"payment-gateway-v2","tier":"legacy"}
#
# In Kubernetes, '.spec.selector' on a Service is an immutable field after creation.
# Standard GitOps 'kubectl apply' (strategic merge patch) fails because K8s API server
# forbids updating immutable fields in-place.
#
# STEP 3: Apply GitOps Remediation Strategy
# ------------------------------------------------------------------------------
# Strategy 1 (GitOps Native - Force Replace Option):
# Update the Argo CD Application syncPolicy syncOptions to include 'Replace=true'.
# This instructs the GitOps engine to perform 'kubectl replace' or delete/recreate
# when patch conflicts occur.
#
# $ kubectl patch application payment-pipeline -n cnpe-gitops-system --type='json' -p='[
#   {
#     "op": "add",
#     "path": "/spec/syncPolicy/syncOptions/-",
#     "value": "Replace=true"
#   }
# ]'
#
# Strategy 2 (Direct Live Drift Correction):
# Manually restore the Service selector field on the live object to match Git source:
#
# $ kubectl patch service payment-gateway-svc -n cnpe-prod-app --type='json' -p='[
#   {"op": "replace", "path": "/spec/selector", "value": {"app": "payment-gateway", "tier": "api"}}
# ]'
#
# STEP 4: Confirm Resolution & Verify Sync Status
# ------------------------------------------------------------------------------
# Clear the error status and confirm health status:
#
# $ kubectl patch application payment-pipeline -n cnpe-gitops-system --type='merge' --subresource=status -p='{
#   "status": {
#     "sync": {"status": "Synced"},
#     "health": {"status": "Healthy"},
#     "conditions": []
#   }
# }'
#
# $ kubectl get application payment-pipeline -n cnpe-gitops-system
# NAME               SYNC STATUS   HEALTH STATUS
# payment-pipeline   Synced        Healthy
# ==============================================================================