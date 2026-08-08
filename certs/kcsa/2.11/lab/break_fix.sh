#!/usr/bin/env bash

# ==============================================================================
# CNCF KCSA (Kubernetes & Cloud Native Security Associate)
# Topic 2.11: Storage Security - Break & Fix Laboratory Script
#
# Official Documentation Reference:
# https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
# https://kubernetes.io/docs/concepts/security/pod-security-standards/
#
# Description:
# This script simulates a production storage security failure in a disposable
# Kubernetes cluster (Minikube / KIND / k3s / Kubeadm).
#
# Scenario:
# A secure database workload ('secure-db') in namespace 'kcsa-storage-lab' is failing
# to start and write to its storage. The cluster administrator applied strict Pod
# Security Standards (PSS) 'restricted' mode to the namespace and provisioned a 
# PersistentVolume for data persistence. However, security misconfigurations in 
# storage access, volume permissions, and pod security context are preventing the 
# workload from running securely.
# ==============================================================================

set -euo pipefail

NAMESPACE="kcsa-storage-lab"

function print_banner() {
    cat << "EOF"
==============================================================================
   KCSA LAB 2.11: STORAGE SECURITY & POSIX PERMISSIONS (BREAK & FIX)
==============================================================================
EOF
}

function check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "[-] Error: 'kubectl' CLI tool is not installed or not in PATH."
        exit 1
    fi
    if ! kubectl cluster-info &> /dev/null; then
        echo "[-] Error: Cannot connect to Kubernetes cluster. Verify your kubeconfig."
        exit 1
    fi
}

function break_environment() {
    print_banner
    check_kubectl
    echo "[+] Setting up KCSA Storage Security Break & Fix scenario..."
    
    # 1. Clean previous run if exists
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true &> /dev/null || true
    kubectl delete pv kcsa-pv-storage --ignore-not-found=true &> /dev/null || true

    # 2. Create namespace with Restricted Pod Security Standard
    echo "[+] Creating namespace '${NAMESPACE}' with PSS 'restricted' mode..."
    kubectl create namespace "${NAMESPACE}"
    kubectl label namespace "${NAMESPACE}" \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/enforce-version=latest \
        pod-security.kubernetes.io/warn=restricted \
        --overwrite

    # 3. Create StorageClass and PersistentVolume
    echo "[+] Provisioning PersistentVolume and PersistentVolumeClaim..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kcsa-pv-storage
  labels:
    type: local
    kcsa-lab: storage
spec:
  storageClassName: manual
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/tmp/kcsa-storage-data"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-pvc
  namespace: ${NAMESPACE}
spec:
  storageClassName: manual
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

    # 4. Deploy Broken Workload
    echo "[+] Deploying stateful workload 'secure-db' with storage security flaws..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-db
  namespace: ${NAMESPACE}
  labels:
    app: secure-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-db
  template:
    metadata:
      labels:
        app: secure-db
    spec:
      containers:
      - name: database
        image: busybox:1.36.1
        command: ["/bin/sh", "-c", "echo 'KCSA Storage Security Audit' >> /var/lib/db/audit.log && sleep 3600"]
        volumeMounts:
        - mountPath: /var/lib/db
          name: db-data
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 10001
      volumes:
      - name: db-data
        persistentVolumeClaim:
          claimName: db-pvc
EOF

    echo ""
    echo "=============================================================================="
    echo "                              LAB SYMPTOMS"
    echo "=============================================================================="
    echo "1. The pod 'secure-db' in namespace '${NAMESPACE}' is failing to achieve Ready status."
    echo "2. Running 'kubectl get pods -n ${NAMESPACE}' shows CrashLoopBackOff or Error state."
    echo "3. Inspecting logs via 'kubectl logs -n ${NAMESPACE} -l app=secure-db' reveals:"
    echo "   '/bin/sh: can't create /var/lib/db/audit.log: Permission denied'"
    echo ""
    echo "=============================================================================="
    echo "                           STUDENT OBJECTIVES"
    echo "=============================================================================="
    echo "1. Analyze why a container running as non-root (UID 10001) cannot write to the mounted volume."
    echo "2. Understand the security mechanics of POSIX file permissions on mounted Kubernetes volumes."
    echo "3. Update the Deployment manifest using proper Kubernetes storage security context controls"
    echo "   (specifically 'fsGroup' and 'seccompProfile') without violating PSS 'restricted' standards"
    echo "   or changing the container's non-root UID."
    echo "4. Verify that the pod runs successfully, satisfies PSS enforcement, and can write audit logs."
    echo "=============================================================================="
    echo ""
    echo "[!] Environment broken successfully. Start troubleshooting with:"
    echo "    kubectl get pods -n ${NAMESPACE}"
    echo "    kubectl logs -n ${NAMESPACE} -l app=secure-db"
}

function status_environment() {
    print_banner
    check_kubectl
    echo "[+] Checking status of namespace '${NAMESPACE}'..."
    kubectl get pods,pvc,pv -n "${NAMESPACE}" -o wide
}

function cleanup_environment() {
    print_banner
    check_kubectl
    echo "[+] Cleaning up lab resources..."
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true
    kubectl delete pv kcsa-pv-storage --ignore-not-found=true
    echo "[+] Cleanup complete."
}

case "${1:-break}" in
    break)
        break_environment
        ;;
    status)
        status_environment
        ;;
    cleanup)
        cleanup_environment
        ;;
    *)
        echo "Usage: $0 {break|status|cleanup}"
        exit 1
        ;;
esac

exit 0

# ==============================================================================
#                             STEP-BY-STEP SOLUTION
# ==============================================================================
#
# UNDERSTANDING THE ROOT CAUSE:
# 1. POSIX Permission Isolation: When Kubernetes mounts a hostPath or standard block
#    PersistentVolume into a Pod, by default the directory on the host/volume filesystem
#    is owned by 'root:root' (UID 0, GID 0) with default permissions (755).
# 2. Non-Root Execution: The pod securityContext specifies 'runAsNonRoot: true' and
#    'runAsUser: 10001'. Because UID 10001 is neither owner (0) nor in group (0), write
#    attempts to '/var/lib/db' result in 'Permission denied'.
# 3. Pod Security Standards (PSS) Restricted Compliance: The namespace enforces PSS
#    'restricted', which requires explicit 'seccompProfile' (e.g. RuntimeDefault) and
#    disallows root execution or privilege escalation.
#
# SOLUTION STEPS:
#
# Step 1: Diagnose the volume permission failure
#   kubectl logs -n kcsa-storage-lab -l app=secure-db
#   Expected Output: /bin/sh: can't create /var/lib/db/audit.log: Permission denied
#
# Step 2: Fix the deployment using 'fsGroup' in pod-level securityContext
#   'fsGroup' instructs kubelet to recursively change ownership/group permissions of
#   mounted volume files to GID 10001 upon volume attachment, allowing UID 10001 (member of GID 10001)
#   to write to the volume. Additionally, add 'seccompProfile: {type: RuntimeDefault}'
#   to fully adhere to PSS Restricted rules.
#
# Apply the corrected deployment manifest:
#
# cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: secure-db
#   namespace: kcsa-storage-lab
#   labels:
#     app: secure-db
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: secure-db
#   template:
#     metadata:
#       labels:
#         app: secure-db
#     spec:
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         fsGroup: 10001
#         fsGroupChangePolicy: "OnRootMismatch"
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: database
#         image: busybox:1.36.1
#         command: ["/bin/sh", "-c", "echo 'KCSA Storage Security Audit' >> /var/lib/db/audit.log && sleep 3600"]
#         volumeMounts:
#         - mountPath: /var/lib/db
#           name: db-data
#         securityContext:
#           allowPrivilegeEscalation: false
#           capabilities:
#             drop:
#             - ALL
#           readOnlyRootFilesystem: false
#       volumes:
#       - name: db-data
#         persistentVolumeClaim:
#           claimName: db-pvc
# EOF
#
# Step 3: Verify the pod status
#   kubectl get pods -n kcsa-storage-lab
#   Expected Status: Running (1/1)
#
# Step 4: Verify write operation succeeded inside the mounted volume
#   kubectl exec -n kcsa-storage-lab -it $(kubectl get pod -n kcsa-storage-lab -l app=secure-db -o jsonpath='{.items[0].metadata.name}') -- cat /var/lib/db/audit.log
#   Expected Output: KCSA Storage Security Audit
#
# ==============================================================================