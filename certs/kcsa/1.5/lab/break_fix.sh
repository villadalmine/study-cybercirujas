#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate)
# Topic 1.5: Artifact Repository and Image Security (Exam Weight: 2.33%)
# Break & Fix Production-Grade Practice Lab
#
# References:
# - CNCF Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - K8s Pull Image Private Registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
# - K8s ServiceAccount ImagePullSecrets: https://kubernetes.io/docs/concepts/containers/images/#specifying-imagepullsecrets-on-a-serviceaccount
# - Container Image Security & Digests: https://kubernetes.io/docs/concepts/containers/images/
# ==============================================================================

set -euo pipefail

NAMESPACE="image-sec-lab"
SA_NAME="payment-sa"
SECRET_NAME="registry-corp-auth"
DEPLOYMENT_NAME="payment-gateway"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_err "kubectl CLI is not installed or not in PATH."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_err "Cannot connect to Kubernetes cluster via kubectl."
        exit 1
    fi
}

inject_breakage() {
    log_info "Cleaning up previous lab namespace if exists..."
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true &> /dev/null || true

    log_info "Creating lab namespace '${NAMESPACE}'..."
    kubectl create namespace "${NAMESPACE}"

    log_info "Injecting controlled security and repository configuration breakages..."

    # Breakage 1: Malformed base64 / invalid JSON inside .dockerconfigjson secret
    # Content is intentional garbage string encoded in base64
    CORRUPTED_DOCKERCONFIG=$(echo -n '{"auths":{"index.docker.io":{"auth":"INVALID_BASE64_TOKEN_STRUCTURE_NO_COLON"}}}' | base64 -w 0)

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${CORRUPTED_DOCKERCONFIG}
EOF

    # Breakage 2: ServiceAccount created without linking default imagePullSecrets
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
EOF

    # Breakage 3: Deployment references non-existent secret name AND uses invalid digest format for public image
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
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
    spec:
      serviceAccountName: ${SA_NAME}
      imagePullSecrets:
      - name: wrong-registry-secret-name
      containers:
      - name: gateway
        # Corrupted SHA256 digest format and non-existent tag combination
        image: docker.io/library/nginx@sha256:BAD1234567890abcdef01234567890abcdef01234567890abcdef01234567890a
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
EOF
}

display_student_instructions() {
    cat <<EOF

================================================================================
  KCSA LAB 1.5: ARTIFACT REPOSITORY AND IMAGE SECURITY - BREAK & FIX
================================================================================

[SCENARIO DESCRIPTION]
The DevSecOps team deployed a critical workload '${DEPLOYMENT_NAME}' into the
namespace '${NAMESPACE}'. The cluster enforces strict image security policies,
requiring secure repository authentication and immutable image digest pinning.

However, the deployment is completely degraded and pods fail to launch.

[SYMPTOMS OBSERVED]
- Pods under namespace '${NAMESPACE}' are stuck in 'ErrImagePull' / 'ImagePullBackOff'.
- Container runtime emits errors related to image reference parsing and registry authentication.

[STUDENT OBJECTIVES]
1. Investigate the failure using 'kubectl describe pod' and system events in namespace '${NAMESPACE}'.
2. Identify why image pull secrets fail and correct the Secret '.dockerconfigjson' structure 
   or recreate a valid docker-registry Secret named '${SECRET_NAME}'.
3. Configure the ServiceAccount '${SA_NAME}' to automatically supply '${SECRET_NAME}' 
   as an 'imagePullSecrets' entry.
4. Fix the Deployment '${DEPLOYMENT_NAME}':
   - Reference the valid secret or rely on ServiceAccount level image pull secrets.
   - Update container image to use a valid, immutable digest pin for official public nginx:
     Image: docker.io/library/nginx:1.25.4-alpine
     Digest: sha256:6db391d1c0cfb305c57ab0fdb97ee0079641c8d2d1dbdb3d69b5e523f09d57a5
     (Full reference: docker.io/library/nginx@sha256:6db391d1c0cfb305c57ab0fdb97ee0079641c8d2d1dbdb3d69b5e523f09d57a5)
5. Verify that all replicas reach state 2/2 'Running' and 'Ready'.

[DIAGNOSTIC HINT]
Execute:
  kubectl get pods -n ${NAMESPACE}
  kubectl describe pod -l app=payment-gateway -n ${NAMESPACE}
  kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

================================================================================
EOF
}

main() {
    check_prerequisites
    inject_breakage
    display_student_instructions
}

main "$@"

# ==============================================================================
# STEP-BY-STEP SOLUTION (DO NOT UNCOMMENT UNLESS SOLVING LAB)
# ==============================================================================
#
# STEP 1: Inspect the broken deployment and pods
# ------------------------------------------------------------------------------
# kubectl get pods -n image-sec-lab
# kubectl describe pod -l app=payment-gateway -n image-sec-lab
#
# Observations in events:
# 1) Error: secret "wrong-registry-secret-name" not found.
# 2) Failed to pull image "docker.io/library/nginx@sha256:BAD123...": invalid digest format / repository pull failure.
#
# STEP 2: Re-create valid Docker Registry Secret
# ------------------------------------------------------------------------------
# Delete malformed secret:
# kubectl delete secret registry-corp-auth -n image-sec-lab
#
# Create syntactically valid docker-registry secret (using standard auth format or dummy credentials for public repository):
# kubectl create secret docker-registry registry-corp-auth \
#   --docker-server=https://index.docker.io/v1/ \
#   --docker-username=secops-read-only \
#   --docker-password=dckr_pat_dummy_token_12345 \
#   --docker-email=secops@corp.internal \
#   -n image-sec-lab
#
# STEP 3: Bind Secret to ServiceAccount
# ------------------------------------------------------------------------------
# Patch the payment-sa ServiceAccount to include imagePullSecrets automatically:
# kubectl patch serviceaccount payment-sa \
#   -p '{"imagePullSecrets": [{"name": "registry-corp-auth"}]}' \
#   -n image-sec-lab
#
# Verify ServiceAccount patch:
# kubectl get sa payment-sa -n image-sec-lab -o yaml
#
# STEP 4: Update Deployment Spec (Correct secret reference & valid digest)
# ------------------------------------------------------------------------------
# Apply corrected Deployment YAML:
# cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-gateway
#   namespace: image-sec-lab
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
#     spec:
#       serviceAccountName: payment-sa
#       imagePullSecrets:
#       - name: registry-corp-auth
#       containers:
#       - name: gateway
#         image: docker.io/library/nginx@sha256:6db391d1c0cfb305c57ab0fdb97ee0079641c8d2d1dbdb3d69b5e523f09d57a5
#         ports:
#         - containerPort: 80
#         resources:
#           limits:
#             cpu: "100m"
#             memory: "128Mi"
# EOF
#
# STEP 5: Verification
# ------------------------------------------------------------------------------
# kubectl rollout status deployment/payment-gateway -n image-sec-lab --timeout=60s
# kubectl get pods -n image-sec-lab -o wide
#
# Expected output:
# NAME                               READY   STATUS    RESTARTS   AGE
# payment-gateway-xxxxxxxxxx-xxxxx   1/1     Running   0          20s
# payment-gateway-xxxxxxxxxx-yyyyy   1/1     Running   0          20s
# ==============================================================================