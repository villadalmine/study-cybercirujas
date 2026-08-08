#!/usr/bin/env bash
# ==============================================================================
# KCSA (Kubernetes & Cloud Native Security Associate) Exam Lab
# Topic 2.7: Pod Security, SecurityContext, & Pod Security Admission (PSA)
# Exam Weight: 2.0%
#
# Official Reference Documentation:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
# - Kubernetes Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
# - Security Context Configuration: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
# ==============================================================================
#
# DESCRIPTION:
# This script simulates a production Incident Response scenario where a 
# microservice Deployment fails to schedule Pods in a namespace enforcing the
# "restricted" Pod Security Standard (PSS) via Pod Security Admission (PSA).
#
# INSTRUCTIONS FOR THE STUDENT:
# 1. Run this script in a test/disposable Kubernetes cluster (minikube/kind/k3s).
# 2. Observe the reported symptoms and error messages.
# 3. Resolve the Pod Security violations without weakening namespace security policies.
# 4. Check the end of this script for the commented step-by-step solution.
# ==============================================================================

set -euo pipefail

LAB_NS="kcsa-pod-sec-lab"
MANIFEST_PATH="/tmp/payment-processor.yaml"

echo "[+] Checking environment prerequisites..."
if ! command -v kubectl &> /dev/null; then
    echo "[-] ERROR: 'kubectl' CLI tool is not installed or not in PATH."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "[-] ERROR: Cannot communicate with a Kubernetes cluster via kubectl."
    exit 1
fi

echo "[+] Preparing laboratory namespace: '${LAB_NS}'..."
kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "[+] Enforcing Restricted Pod Security Standard on namespace '${LAB_NS}'..."
kubectl label namespace "${LAB_NS}" \
    "pod-security.kubernetes.io/enforce=restricted" \
    "pod-security.kubernetes.io/enforce-version=latest" \
    "pod-security.kubernetes.io/warn=restricted" \
    "pod-security.kubernetes.io/warn-version=latest" \
    --overwrite

echo "[+] Generating non-compliant Deployment manifest at '${MANIFEST_PATH}'..."
cat << 'EOF' > "${MANIFEST_PATH}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: kcsa-pod-sec-lab
  labels:
    app: payment-processor
    tier: api
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
      containers:
      - name: payment-api
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
        securityContext:
          privileged: false
          allowPrivilegeEscalation: true
          runAsUser: 0
EOF

echo "[+] Applying non-compliant Deployment into namespace '${LAB_NS}'..."
# Deployments will be accepted by API server, but ReplicaSet will fail to create Pods
kubectl apply -f "${MANIFEST_PATH}"

echo ""
echo "=============================================================================="
echo "                         SCENARIO & LAB BREAKDOWN                             "
echo "=============================================================================="
echo "NAMESPACE: ${LAB_NS}"
echo "TARGET DEPLOYMENT: payment-processor"
echo "MANIFEST FILE: ${MANIFEST_PATH}"
echo ""
echo "SYMPTOM OBSERVED:"
echo "  - The deployment 'payment-processor' was created, but 0/2 Pods are Running."
echo "  - The ReplicaSet controller cannot create Pods due to PodSecurity Admission"
echo "    policy rejections."
echo ""
echo "YOUR OBJECTIVE:"
echo "  1. Inspect the ReplicaSet events in namespace '${LAB_NS}' to identify all"
echo "     Pod Security Standard (Restricted profile) violations."
echo "  2. Edit '${MANIFEST_PATH}' to make the Pod template fully compliant with"
echo "     the 'restricted' Pod Security Standard:"
echo "       a. Set 'runAsNonRoot: true' and a non-zero 'runAsUser' / 'runAsGroup'."
echo "       b. Set 'allowPrivilegeEscalation: false'."
echo "       c. Set 'seccompProfile.type: RuntimeDefault'."
echo "       d. Drop ALL capabilities ('capabilities.drop: [\"ALL\"]')."
echo "       e. Set 'readOnlyRootFilesystem: true' and mount an emptyDir volume"
echo "          at paths requiring write access (e.g. /var/cache/nginx, /var/run, /tmp)."
echo "  3. Apply the updated manifest and verify that 2/2 Pods transition to"
echo "     the 'Running' state cleanly without security warnings."
echo "=============================================================================="
echo ""
echo "[+] Current Namespace Status:"
kubectl get deployment -n "${LAB_NS}"
echo ""
echo "[+] Run 'kubectl describe rs -n ${LAB_NS}' to start diagnosing the failure."
echo "=============================================================================="

# ==============================================================================
#                         STEP-BY-STEP SOLUTION (COMMENTED)
# ==============================================================================
#
# STEP 1: DIAGNOSE THE FAILURE
# Run the following commands to inspect why the ReplicaSet failed to spawn Pods:
#
#   kubectl get replica-sets -n kcsa-pod-sec-lab
#   kubectl describe rs -n kcsa-pod-sec-lab
#
# Expected Output Snippet from 'kubectl describe rs':
#   Warning  FailedCreate  12s (x4 over 35s)  replicaset-controller
#   Error creating: pods "payment-processor-..." is forbidden: violates PodSecurity "restricted:latest":
#   - allowPrivilegeEscalation != false (container "payment-api" must set securityContext.allowPrivilegeEscalation=false)
#   - unrestricted capabilities (container "payment-api" must set securityContext.capabilities.drop=["ALL"])
#   - runAsNonRoot != true (pod or container "payment-api" must set securityContext.runAsNonRoot=true)
#   - runAsUser=0 (container "payment-api" must not set runAsUser=0)
#   - seccompProfile (pod or container "payment-api" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
#
# ------------------------------------------------------------------------------
#
# STEP 2: CREATE COMPLIANT MANIFEST
# Replace the contents of /tmp/payment-processor.yaml with the following fully
# compliant Pod specification:
#
# cat << 'EOF' > /tmp/payment-processor.yaml
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-processor
#   namespace: kcsa-pod-sec-lab
#   labels:
#     app: payment-processor
#     tier: api
# spec:
#   replicas: 2
#   selector:
#     matchLabels:
#       app: payment-processor
#   template:
#     metadata:
#       labels:
#         app: payment-processor
#     spec:
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: payment-api
#         image: nginxinc/nginx-unprivileged:1.25-alpine
#         ports:
#         - containerPort: 8080
#         securityContext:
#           allowPrivilegeEscalation: false
#           readOnlyRootFilesystem: true
#           capabilities:
#             drop:
#             - ALL
#         volumeMounts:
#         - name: tmp-volume
#           mountPath: /tmp
#         - name: cache-volume
#           mountPath: /var/cache/nginx
#         - name: run-volume
#           mountPath: /var/run
#       volumes:
#       - name: tmp-volume
#         emptyDir: {}
#       - name: cache-volume
#         emptyDir: {}
#       - name: run-volume
#         emptyDir: {}
# EOF
#
# ------------------------------------------------------------------------------
#
# STEP 3: APPLY AND VERIFY THE FIX
# Apply the fixed manifest and check the Pod status:
#
#   kubectl apply -f /tmp/payment-processor.yaml
#   kubectl get pods -n kcsa-pod-sec-lab -w
#
# Expected Output:
#   NAME                                 READY   STATUS    RESTARTS   AGE
#   payment-processor-7d9b5c844f-ab12c   1/1     Running   0          10s
#   payment-processor-7d9b5c844f-xy89z   1/1     Running   0          10s
#
# Verify SecurityContext parameters on running Pod:
#   kubectl get pod -n kcsa-pod-sec-lab -l app=payment-processor \
#     -o jsonpath='{.items[0].spec.containers[0].securityContext}' | jq .
#
# STEP 4: CLEANUP (OPTIONAL)
#   kubectl delete namespace kcsa-pod-sec-lab
#   rm -f /tmp/payment-processor.yaml
# ==============================================================================