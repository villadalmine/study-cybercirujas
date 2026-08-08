#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Break & Fix Lab
# Topic 6.2: Threat Modeling Frameworks (STRIDE & MITRE ATT&CK for Containers)
#
# Official References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
# - MITRE ATT&CK for Containers: https://attack.mitre.org/matrices/enterprise/containers/
# - CNCF Cloud Native Security Whitepaper: https://github.com/cncf/tag-security/blob/main/security-whitepaper/v2/cloud-native-security-whitepaper-v2.pdf
#
# ==============================================================================
# LAB SCENARIO OVERVIEW
# ==============================================================================
# Threat modeling frameworks like STRIDE (Spoofing, Tampering, Repudiation, 
# Information Disclosure, Denial of Service, Elevation of Privilege) and 
# MITRE ATT&CK for Containers provide structured methods to identify and mitigate 
# cloud-native attack vectors.
#
# Following a recent threat model evaluation using STRIDE and MITRE ATT&CK 
# (specifically targeting T1611 - Container Escape and T1068 - Exploitation for 
# Privilege Escalation), SecOps enabled the 'Restricted' Pod Security Standard 
# admission control level on namespace `sec-lab-threat-model`.
#
# A developer pushed an emergency hotfix deployment `analytics-processor` into 
# `sec-lab-threat-model`. The application failed to launch due to severe 
# security anti-patterns violating multiple STRIDE threat boundaries:
#   1. Elevation of Privilege (STRIDE-E / MITRE T1611): `privileged: true`, 
#      `hostPID: true`, `allowPrivilegeEscalation: true`.
#   2. Information Disclosure & Tampering (STRIDE-I / STRIDE-T): Mounting sensitive 
#      host file paths `/etc/kubernetes` and `/var/run/docker.sock`.
#   3. Spoofing & Repudiation (STRIDE-S / STRIDE-R): Automounting high-privilege 
#      default ServiceAccount tokens combined with unsegmented network permissions.
#
# ==============================================================================
# STUDENT SYMPTOMS & DIAGNOSTIC CHALLENGE
# ==============================================================================
# - Running `kubectl get pods -n sec-lab-threat-model` shows `0` ready pods or 
#   no running pods created by the ReplicaSet controller.
# - `kubectl get events -n sec-lab-threat-model` or `kubectl describe deployment` 
#   shows admission control errors rejecting pod creation against Pod Security Standards.
#
# YOUR GOAL:
# 1. Analyze the failed Deployment `analytics-processor` against STRIDE principles.
# 2. Inspect namespace admission policy labels (`pod-security.kubernetes.io/enforce`).
# 3. Refactor `deploy/analytics-processor` in namespace `sec-lab-threat-model` to comply 
#    with the 'Restricted' Pod Security Standard without breaking the core app execution:
#    - Remove host namespace sharing (`hostPID: false`).
#    - Remove dangerous `hostPath` volume mounts.
#    - Disable privileged execution and privilege escalation (`privileged: false`, 
#      `allowPrivilegeEscalation: false`).
#    - Configure non-root execution (`runAsNonRoot: true`, `runAsUser: 10001`, `runAsGroup: 10001`).
#    - Drop all POSIX capabilities (`capabilities: { drop: ["ALL"] }`).
#    - Enforce immutable root filesystem (`readOnlyRootFilesystem: true`) with emptyDir 
#      mounts for required temporary write paths (`/tmp`).
#    - Disable automatic ServiceAccount token mounting (`automountServiceAccountToken: false`).
# 4. Verify deployment reaches status `READY: 1/1` without security warning events.
# ==============================================================================

set -euo pipefail

NAMESPACE="sec-lab-threat-model"
DEPLOYMENT_NAME="analytics-processor"

echo "[+] Checking environment prerequisites..."
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: 'kubectl' command line tool is not installed or not in PATH."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster. Ensure KUBECONFIG is properly configured."
    exit 1
fi

echo "[+] Preparing test environment in namespace: '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "[+] Enforcing 'Restricted' Pod Security Standard on namespace '${NAMESPACE}'..."
kubectl label namespace "${NAMESPACE}" \
    "pod-security.kubernetes.io/enforce=restricted" \
    "pod-security.kubernetes.io/enforce-version=latest" \
    "pod-security.kubernetes.io/warn=restricted" \
    "pod-security.kubernetes.io/warn-version=latest" \
    --overwrite > /dev/null

echo "[+] Deploying insecure work manifest violating STRIDE threat modeling rules..."
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: analytics-processor
    tier: processing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: analytics-processor
  template:
    metadata:
      labels:
        app: analytics-processor
    spec:
      hostPID: true
      automountServiceAccountToken: true
      containers:
      - name: processor
        image: busybox:1.36.1
        command: ["sh", "-c", "echo Processing analytics data... && sleep 3600"]
        securityContext:
          privileged: true
          allowPrivilegeEscalation: true
          runAsUser: 0
        volumeMounts:
        - name: host-k8s-config
          mountPath: /host/etc/kubernetes
        - name: host-docker-sock
          mountPath: /var/run/docker.sock
        - name: app-temp
          mountPath: /tmp
      volumes:
      - name: host-k8s-config
        hostPath:
          path: /etc/kubernetes
          type: Directory
      - name: host-docker-sock
        hostPath:
          path: /var/run/docker.sock
          type: Socket
      - name: app-temp
        emptyDir: {}
EOF

echo ""
echo "=========================================================================="
echo " [!] BREAK & FIX ENVIRONMENT READY"
echo "=========================================================================="
echo " Target Namespace : ${NAMESPACE}"
echo " Deployment Name  : ${DEPLOYMENT_NAME}"
echo " Target Framework : STRIDE & MITRE ATT&CK for Containers (KCSA 6.2)"
echo "--------------------------------------------------------------------------"
echo " SYMPTOM:"
echo " The deployment '${DEPLOYMENT_NAME}' was applied but zero pods are running."
echo " Admission controllers rejected pod creation due to severe security violations."
echo ""
echo " DIAGNOSTIC COMMANDS TO START WITH:"
echo "   kubectl get deployment -n ${NAMESPACE}"
echo "   kubectl get rs -n ${NAMESPACE}"
echo "   kubectl describe rs -l app=${DEPLOYMENT_NAME} -n ${NAMESPACE}"
echo "   kubectl get events -n ${NAMESPACE} --field-selector reason=FailedCreate"
echo "=========================================================================="
echo ""

# ==============================================================================
# COMPREHENSIVE STEP-BY-STEP SOLUTION & WALKTHROUGH (KEEP COMMENTED)
# ==============================================================================
#
# STEP 1: INITIAL DIAGNOSIS & THREAT VECTOR AUDIT
# ------------------------------------------------------------------------------
# Run the following command to observe why the ReplicaSet failed to spawn pods:
#
#   kubectl describe rs -n sec-lab-threat-model -l app=analytics-processor
#
# Expected Error Output Sample:
#   Warning  FailedCreate  12s (x4 over 45s)  replicaset-controller  
#   Error creating: pods "analytics-processor-xxxxx" is forbidden: 
#   violates PodSecurity "restricted:latest": 
#   - host namespaces (hostPID=true)
#   - privileged (container "processor" must not set securityContext.privileged=true)
#   - allowPrivilegeEscalation != false (container "processor" must set securityContext.allowPrivilegeEscalation=false)
#   - unrestricted capabilities (container "processor" must set securityContext.capabilities.drop=["ALL"])
#   - runAsNonRoot != true (pod or container "processor" must set securityContext.runAsNonRoot=true)
#   - runAsUser=0 (container "processor" must not set runAsUser=0)
#   - seccompProfile (pod or container "processor" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
#   - hostPath volumes (volumes "host-k8s-config", "host-docker-sock")
#
# ------------------------------------------------------------------------------
# STEP 2: STRIDE THREAT MODEL MAPPING
# ------------------------------------------------------------------------------
# 1. Elevation of Privilege (STRIDE-E / MITRE T1611 - Container Escape):
#    - Threat: `privileged: true` gives full host kernel device access.
#    - Threat: `hostPID: true` allows inspecting/killing processes on the host.
#    - Threat: `allowPrivilegeEscalation: true` enables setuid binary escalation.
#    - Fix: Set `privileged: false`, `hostPID: false`, `allowPrivilegeEscalation: false`, 
#      and set `seccompProfile: { type: "RuntimeDefault" }`.
#
# 2. Information Disclosure & Tampering (STRIDE-I & STRIDE-T):
#    - Threat: `hostPath` mounts (`/etc/kubernetes`, `/var/run/docker.sock`) expose 
#      cluster control plane certificates and container runtime sockets.
#    - Threat: Writeable root filesystem allows attackers to modify binary code.
#    - Fix: Remove `hostPath` volumes entirely. Enforce `readOnlyRootFilesystem: true` 
#      and use `emptyDir` for transient buffer paths like `/tmp`.
#
# 3. Spoofing & Repudiation (STRIDE-S & STRIDE-R):
#    - Threat: `automountServiceAccountToken: true` mounts service account tokens 
#      unconditionally, enabling unauthenticated API server calls.
#    - Fix: Set `automountServiceAccountToken: false` on pod spec.
#
# 4. Least Privilege Enforcement:
#    - Threat: Running as root (`runAsUser: 0`) violates container isolation.
#    - Fix: Set `runAsNonRoot: true`, `runAsUser: 10001`, `runAsGroup: 10001`, 
#      and drop capabilities (`capabilities: { drop: ["ALL"] }`).
#
# ------------------------------------------------------------------------------
# STEP 3: APPLY FULLY SECURED & SYNTACTICALLY VALID MANIFEST
# ------------------------------------------------------------------------------
# Apply the remediated manifest using kubectl:
#
# cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: analytics-processor
#   namespace: sec-lab-threat-model
#   labels:
#     app: analytics-processor
#     tier: processing
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: analytics-processor
#   template:
#     metadata:
#       labels:
#         app: analytics-processor
#     spec:
#       hostPID: false
#       automountServiceAccountToken: false
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: processor
#         image: busybox:1.36.1
#         command: ["sh", "-c", "echo Processing analytics data safely... && sleep 3600"]
#         securityContext:
#           privileged: false
#           allowPrivilegeEscalation: false
#           readOnlyRootFilesystem: true
#           capabilities:
#             drop:
#             - ALL
#         volumeMounts:
#         - name: app-temp
#           mountPath: /tmp
#       volumes:
#       - name: app-temp
#         emptyDir: {}
# EOF
#
# ------------------------------------------------------------------------------
# STEP 4: VERIFY RESOLUTION & COMPLIANCE
# ------------------------------------------------------------------------------
# 1. Verify Deployment Status:
#    kubectl get deployment analytics-processor -n sec-lab-threat-model
#
#    Expected Output:
#    NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
#    analytics-processor   1/1     1            1           30s
#
# 2. Check Pod Security Status & Events:
#    kubectl get pods -n sec-lab-threat-model
#    kubectl get events -n sec-lab-threat-model --field-selector reason=FailedCreate
#
#    Expected Output:
#    No new FailedCreate events generated; pod status changes to 'Running'.
# ==============================================================================