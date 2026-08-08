#!/usr/bin/env bash
# ==============================================================================
# KCSA Certification Exam Preparation | Topic 1.4: Isolation Techniques
# Lab Scenario: Break & Fix - Pod Security Admission & Security Context Isolation
# ==============================================================================
# Domain: KCSA (Kubernetes and Cloud Native Security Associate)
# Topic 1.4: Isolation Techniques
# Exam Weight: 2.33%
#
# Official References:
#   - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#   - Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
#   - Pod Security Admission Engine: https://kubernetes.io/docs/concepts/security/pod-security-admission/
#   - Container Security Context: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
#   - Restrictive Seccomp Profiles: https://kubernetes.io/docs/tutorials/security/seccomp/
# ==============================================================================

set -euo pipefail

# ANSI Color Codes for SRE Terminal Diagnostics
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

LAB_NAMESPACE="kcsa-isolation-lab"
DEPLOYMENT_NAME="secure-payment-gateway"

echo -e "${BLUE}${BOLD}[+] Verifying Prerequisites...${RESET}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[!] Error: 'kubectl' CLI binary was not found on PATH.${RESET}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[!] Error: Cannot communicate with the Kubernetes API Server. Ensure your kubeconfig is active.${RESET}"
    exit 1
fi

echo -e "${GREEN}[✓] Kubernetes API Server is reachable.${RESET}\n"

# ------------------------------------------------------------------------------
# STEP 1: SETUP HARDENED ISOLATION ENVIRONMENT
# ------------------------------------------------------------------------------
echo -e "${BLUE}${BOLD}[+] Step 1: Provisioning isolated namespace '${LAB_NAMESPACE}' with enforced Pod Security Standards (PSS)...${RESET}"

kubectl create namespace "${LAB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# Enforce 'restricted' PSS via Pod Security Admission (PSA) labels
kubectl label --overwrite namespace "${LAB_NAMESPACE}" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest > /dev/null

echo -e "${GREEN}[✓] Namespace '${LAB_NAMESPACE}' configured with strict isolation: 'pod-security.kubernetes.io/enforce=restricted'.${RESET}\n"

# ------------------------------------------------------------------------------
# STEP 2: INJECT FAULTY / NON-COMPLIANT WORKLOAD MANIFEST (BREAK PHASE)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}${BOLD}[!] Step 2: Injecting broken deployment into '${LAB_NAMESPACE}'...${RESET}"

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${LAB_NAMESPACE}
  labels:
    app: payment-gateway
    tier: backend
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
      containers:
      - name: gateway
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
        securityContext:
          allowPrivilegeEscalation: true
          runAsUser: 0
EOF

echo -e "${RED}${BOLD}[✘] SIMULATED OUTAGE / DEPLOYMENT FAILURE INJECTED SUCCESSFULY.${RESET}\n"

# ------------------------------------------------------------------------------
# STEP 3: STUDENT PROBLEM STATEMENT & DIAGNOSTIC GUIDE
# ------------------------------------------------------------------------------
echo -e "${CYAN}${BOLD}================================================================================${RESET}"
echo -e "${CYAN}${BOLD}                 KCSA LAB 1.4: ISOLATION TECHNIQUES - INCIDENT REPORT           ${RESET}"
echo -e "${CYAN}${BOLD}================================================================================${RESET}"
echo -e "${BOLD}SYSTEM SYMPTOMS:${RESET}"
echo -e "  - Deployment '${DEPLOYMENT_NAME}' in namespace '${LAB_NAMESPACE}' shows 0 ready replicas."
echo -e "  - Pods are failing admission or replica sets are unable to create underlying pods."
echo -e "  - The cluster security policy mandates strict multi-tenant workloads isolation."
echo -e ""
echo -e "${BOLD}STUDENT OBJECTIVE:${RESET}"
echo -e "  1. Investigate why the ReplicaSet is unable to instantiate Pods."
echo -e "  2. Identify all Pod Security Admission (PSA) 'restricted' profile violations."
echo -e "  3. Modify the Deployment '${DEPLOYMENT_NAME}' manifest in namespace '${LAB_NAMESPACE}' so that:"
echo -e "     - It strictly complies with the 'restricted' Pod Security Standard."
echo -e "     - Container privilege escalation is prohibited (${BOLD}allowPrivilegeEscalation: false${RESET})."
echo -e "     - Root execution is forbidden (${BOLD}runAsNonRoot: true${RESET}, non-zero UID/GID e.g. 10001)."
echo -e "     - Linux kernel syscall filtering is enforced (${BOLD}seccompProfile.type: RuntimeDefault${RESET})."
echo -e "     - Unnecessary Linux capabilities are dropped (${BOLD}capabilities.drop: [\"ALL\"]${RESET})."
echo -e "     - Read-only root filesystem is enforced (${BOLD}readOnlyRootFilesystem: true${RESET}), using an 'emptyDir' volume for write paths (e.g. /var/cache/nginx, /var/run, /tmp)."
echo -e "  4. Verify that all 2/2 Pod replicas reach state 'Running' and pass PSS checks."
echo -e ""
echo -e "${BOLD}USEFUL DIAGNOSTIC COMMANDS:${RESET}"
echo -e "  $ kubectl get deployment -n ${LAB_NAMESPACE}"
echo -e "  $ kubectl get replicaset -n ${LAB_NAMESPACE}"
echo -e "  $ kubectl describe replicaset -l app=payment-gateway -n ${LAB_NAMESPACE}"
echo -e "  $ kubectl get events -n ${LAB_NAMESPACE} --field-selector reason=FailedCreate"
echo -e "${CYAN}${BOLD}================================================================================${RESET}\n"

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (FOR INSTRUCTOR / VERIFICATION)
# ==============================================================================
#
# TECHNICAL MECHANICS OF POD SECURITY ADMISSION (PSA):
# Kubernetes 1.23+ replaces PodSecurityPolicies (PSP) with built-in Pod Security
# Admission (PSA). PSA enforces Pod Security Standards (PSS) at the namespace level
# using standard labels:
#   - pod-security.kubernetes.io/enforce: <privilege_level> (privileged, baseline, restricted)
#   - pod-security.kubernetes.io/enforce-version: <version> (e.g., v1.30 or latest)
#
# When a ReplicaSet controller attempts to create a Pod in a namespace marked with
# `enforce=restricted`, the API Server's Admission Webhook validates the Pod's
# `securityContext`. If any security control violates the restricted profile, the
# Pod creation request is rejected synchronously, generating ReplicaSet `FailedCreate` events.
#
# REASONING FOR THE SECURITY CONTEXT FIELDS:
# 1. seccompProfile.type: RuntimeDefault
#    Restricts syscall access to the kernel via default container runtime filter profiles (e.g., runc/gVisor),
#    mitigating kernel exploit vectors.
# 2. allowPrivilegeEscalation: false
#    Prevents setuid binaries (no_new_privs bit) from elevating privileges inside the container namespace.
# 3. runAsNonRoot: true & runAsUser: 10001
#    Ensures container process runs as an unprivileged UID, preventing host root compromise if container breakouts occur.
# 4. capabilities.drop: ["ALL"]
#    Strips all Linux kernel capabilities (e.g., CAP_NET_ADMIN, CAP_SYS_ADMIN, CAP_CHOWN) to enforce zero-trust isolation.
# 5. readOnlyRootFilesystem: true
#    Prevents malware persistence or unauthorized binary modifications on the container root filesystem.
#
# ------------------------------------------------------------------------------
# COMPLETE RECOVERY COMMANDS & SYNTACTICALLY VALID MANIFEST:
# ------------------------------------------------------------------------------
#
# Execute the following CLI commands to inspect the failure:
#   kubectl describe replicaset -n kcsa-isolation-lab -l app=payment-gateway
#
# Apply the remediated manifest below to resolve the isolation failure:
#
# cat <<'EOF' | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: secure-payment-gateway
#   namespace: kcsa-isolation-lab
#   labels:
#     app: payment-gateway
#     tier: backend
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
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: gateway
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
# VERIFICATION COMMANDS:
#   kubectl get pods -n kcsa-isolation-lab -o wide
#   kubectl get deployment -n kcsa-isolation-lab
# ==============================================================================