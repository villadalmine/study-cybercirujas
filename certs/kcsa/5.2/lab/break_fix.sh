#!/usr/bin/env bash

# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Certification Lab
# Domain 5.2: Image Repository Security & Private Registry Authentication
# Curriculum Ref: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# Official Documentation Ref: https://kubernetes.io/docs/concepts/containers/images/#using-a-private-registry
# ==============================================================================
#
# LAB OVERVIEW:
# As a Senior SRE / Security Architect, you are troubleshooting a production
# deployment failure in the 'kcsa-image-repo' namespace.
#
# SCENARIO:
# The Security Team deployed a payment processing microservice 'payment-processor'
# configured to pull secure container images from a private enterprise repository.
# However, all Pods are failing to launch and are stuck in 'ImagePullBackOff'.
#
# YOUR OBJECTIVE:
# 1. Diagnose why Kubelet fails to authenticate against the private repository.
# 2. Identify the misconfigurations in the Kubernetes Secret data schema and
#    ServiceAccount binding.
# 3. Remediate the issue so that image pull credentials are syntactically valid
#    and properly associated via the ServiceAccount.
#
# ==============================================================================

set -euo pipefail

NAMESPACE="kcsa-image-repo"
SERVICE_ACCOUNT="payment-sa"
SECRET_NAME="private-registry-creds"
DEPLOYMENT_NAME="payment-processor"
IMAGE_URL="quay.io/kcsa-secure-labs/payment-api:v2.4.0"

echo "----------------------------------------------------------------------"
echo "[+] Initializing KCSA 5.2 Laboratory: Image Repository Break-Fix..."
echo "----------------------------------------------------------------------"

# 1. Ensure clean environment
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true 2>/dev/null || true

# 2. Create Target Namespace
kubectl create namespace "${NAMESPACE}"

# 3. Create ServiceAccount (Broken: Missing imagePullSecrets association)
kubectl create serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}"

# 4. Create Malformed Image Pull Secret
# ARCHITECTURAL NOTE: Kubelet requires the key inside 'data' to be exactly '.dockerconfigjson'
# when using secret type 'kubernetes.io/dockerconfigjson'.
# BREAK INTRODUCED: Using key 'dockerconfigjson' (missing leading dot) and wrong secret type 'Opaque'.
MALFORMED_DOCKER_CONFIG=$(cat <<EOF | base64 -w 0
{
  "auths": {
    "quay.io": {
      "username": "kcsa-service-account",
      "password": "dGhpcy1pcy1hLWZha2UtdG9rZW4tZm9yLWxhYi1wdXJwb3Nlcw==",
      "auth": "a2NzYS1zZXJ2aWNlLWFjY291bnQ6ZEdocGNpMXBjeTFoTFdabhhWVTBURzl1WjE5bWIzSWdiR0ZpTFhCMWNuQnZjMlZ6"
    }
  }
}
EOF
)

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  dockerconfigjson: ${MALFORMED_DOCKER_CONFIG}
EOF

# 5. Deploy Microservice using the ServiceAccount
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: payment-processor
    tier: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      serviceAccountName: ${SERVICE_ACCOUNT}
      containers:
      - name: payment-api
        image: ${IMAGE_URL}
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        resources:
          limits:
            cpu: "200m"
            memory: "256Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

echo "----------------------------------------------------------------------"
echo "[!] LAB SETUP COMPLETE: The environment has been broken!"
echo "----------------------------------------------------------------------"
cat << EOF

STUDENT INSTRUCTIONS & TROUBLESHOOTING SYMPTOMS:
------------------------------------------------
1. Check the Pod status in namespace '${NAMESPACE}':
   $ kubectl get pods -n ${NAMESPACE}

2. You will observe Pods transitioning into 'ErrImagePull' or 'ImagePullBackOff'.

3. Inspect the Pod events and configuration:
   $ kubectl describe pod -l app=${DEPLOYMENT_NAME} -n ${NAMESPACE}

4. Investigate why Kubelet is unable to authenticate against '${IMAGE_URL}':
   - Check the ServiceAccount configuration:
     $ kubectl get sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} -o yaml
   - Check the Secret structure and data keys:
     $ kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o yaml

5. GOAL TO FIX:
   - Fix the Secret key name to '.dockerconfigjson' and type to 'kubernetes.io/dockerconfigjson'.
   - Attach the secret to the ServiceAccount '${SERVICE_ACCOUNT}' via 'imagePullSecrets' or reference it in the Deployment spec.
   - Verify image pull credentials logic in Kubernetes SRE workflow.

(Note: The image URL is a simulated private image; fixing the secret structure and ServiceAccount reference proves mastery of Kubelet Image Repository Auth Mechanics.)

==============================================================================
EOF

exit 0

# ==============================================================================
# SOLUTION & STEP-BY-STEP REMEDIATION GUIDE (DON'T READ UNTIL YOU TRY TO FIX IT)
# ==============================================================================
#
# MECHANICAL & ARCHITECTURAL ANALYSIS:
# ------------------------------------
# 1. Kubelet Private Registry Authentication Mechanism:
#    When Kubelet pulls an image from a private container registry requiring authentication,
#    it looks for image pull credentials in two primary places within Kubernetes primitives:
#    a) PodSpec.imagePullSecrets
#    b) ServiceAccount.imagePullSecrets (associated with the Pod's serviceAccountName)
#
# 2. Secret Type & Data Schema Requirements:
#    Kubernetes requires Image Pull Secrets to have:
#    - type: kubernetes.io/dockerconfigjson
#    - data key: .dockerconfigjson (MUST include the leading dot)
#    If the key is named 'dockerconfigjson' or 'config.json', or if type is 'Opaque',
#    Kubelet fails to parse the secret as a valid Docker CLI configuration file,
#    silently ignoring the secret during registry authorization.
#
# 3. ServiceAccount Scoping & Decoupling (SRE Best Practice):
#    Instead of hardcoding 'imagePullSecrets' into every Deployment manifest, enterprise
#    SRE patterns bind 'imagePullSecrets' to the ServiceAccount. Kubelet automatically
#    injects these pull secrets into all Pods executing under that ServiceAccount.
#
# STEP-BY-STEP DIAGNOSTIC & REMEDIATION COMMANDS:
# ------------------------------------------------
# Step 1: Diagnose the broken deployment and inspect events
# $ kubectl get pods -n kcsa-image-repo
#   EXPECTED OUTPUT:
#   NAME                                 READY   STATUS             RESTARTS   AGE
#   payment-processor-78d9b4c56f-abc12   0/1     ImagePullBackOff   0          45s
#   payment-processor-78d9b4c56f-def34   0/1     ErrImagePull       0          45s
#
# $ kubectl describe pod -l app=payment-processor -n kcsa-image-repo
#   EXPECTED OUTPUT (Events section):
#   Warning  Failed     12s (x2 over 40s)  kubelet  Failed to pull image "quay.io/kcsa-secure-labs/payment-api:v2.4.0": rpc error: code = Unknown desc = failed to pull and unpack image ...: unauthorized: authentication required
#
# Step 2: Check ServiceAccount imagePullSecrets binding
# $ kubectl get serviceaccount payment-sa -n kcsa-image-repo -o yaml
#   OBSERVATION: 'imagePullSecrets' field is completely missing.
#
# Step 3: Inspect Secret schema
# $ kubectl get secret private-registry-creds -n kcsa-image-repo -o yaml
#   OBSERVATION: Secret type is 'Opaque' and data key is 'dockerconfigjson' (missing dot).
#
# Step 4: Re-create Secret with correct 'kubernetes.io/dockerconfigjson' format
# $ kubectl create secret docker-registry private-registry-creds \
#     --namespace=kcsa-image-repo \
#     --docker-server=quay.io \
#     --docker-username=kcsa-service-account \
#     --docker-password=this-is-a-fake-token-for-lab-purposes \
#     --dry-run=client -o yaml | kubectl apply -f -
#
# Step 5: Patch ServiceAccount to bind the imagePullSecret
# $ kubectl patch serviceaccount payment-sa \
#     -n kcsa-image-repo \
#     -p '{"imagePullSecrets": [{"name": "private-registry-creds"}]}'
#
# Step 6: Verify ServiceAccount updated spec
# $ kubectl get sa payment-sa -n kcsa-image-repo -o yaml
#   EXPECTED OUTPUT:
#   apiVersion: v1
#   kind: ServiceAccount
#   metadata:
#     name: payment-sa
#     namespace: kcsa-image-repo
#   imagePullSecrets:
#   - name: private-registry-creds
#
# Step 7: Restart Deployment rollout to trigger Kubelet re-evaluation
# $ kubectl rollout restart deployment payment-processor -n kcsa-image-repo
#
# Step 8: Confirm Kubelet now uses the injected secret credentials during image pull attempt
# $ kubectl describe pod -l app=payment-processor -n kcsa-image-repo
#
# OFFICIAL CNCF & KUBERNETES REFERENCES:
# - CNCF KCSA Curriculum Domain 5.2 (Image Repository): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Tasks - Pull Image from Private Registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
# - ServiceAccount ImagePullSecrets Concept: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#add-imagepullsecrets-to-a-service-account
# ==============================================================================