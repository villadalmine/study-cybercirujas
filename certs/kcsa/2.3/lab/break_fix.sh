#!/usr/bin/env bash

# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate)
# Break & Fix Lab Script
# Topic 2.3: Scheduler (Control Plane Security, Authz/Authn & Scheduling)
# ==============================================================================

set -euo pipefail

# Styling output
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MANIFEST_PATH="/etc/kubernetes/manifests/kube-scheduler.yaml"
BACKUP_PATH="/etc/kubernetes/manifests/kube-scheduler.yaml.bak_kcsa"
NS="kcsa-scheduler-lab"

echo -e "${CYAN}${BOLD}[+] Initializing KCSA Topic 2.3 (Scheduler Security) Break & Fix Environment...${NC}"

# Check root permissions
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Error: This script must be executed as root (or with sudo) to modify control plane manifests.${NC}"
   exit 1
fi

# Verify cluster control plane node accessibility
if [[ ! -f "${MANIFEST_PATH}" ]]; then
    echo -e "${RED}[!] Error: ${MANIFEST_PATH} not found. Run this script on a Kubernetes Control Plane node (e.g., kubeadm / minikube / control-plane VM).${NC}"
    exit 1
fi

# Verify kubectl access
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}[!] Error: Unable to communicate with Kubernetes API server via kubectl.${NC}"
    exit 1
fi

# Step 1: Backup original manifest
if [[ ! -f "${BACKUP_PATH}" ]]; then
    echo -e "${YELLOW}[*] Creating backup of original kube-scheduler manifest at ${BACKUP_PATH}...${NC}"
    cp "${MANIFEST_PATH}" "${BACKUP_PATH}"
else
    echo -e "${YELLOW}[*] Backup already exists at ${BACKUP_PATH}.${NC}"
fi

# Step 2: Inject safe, controlled breakage in kube-scheduler security parameters
echo -e "${YELLOW}[*] Applying controlled security misconfigurations to kube-scheduler manifest...${NC}"

# Misconfiguration 1: Point client CA file to invalid path (Breaks Authn for scheduler endpoint & apiserver auth)
sed -i 's|--client-ca-file=.*|--client-ca-file=/etc/kubernetes/pki/ca-invalid.crt|g' "${MANIFEST_PATH}"

# Misconfiguration 2: Invalidate kubeconfig path used by scheduler to communicate with kube-apiserver
sed -i 's|--kubeconfig=.*|--kubeconfig=/etc/kubernetes/scheduler-corrupted.conf|g' "${MANIFEST_PATH}"

# Misconfiguration 3: Disable secure port binding or corrupt authorization flags if present
if grep -q "--authorization-kubeconfig" "${MANIFEST_PATH}"; then
    sed -i 's|--authorization-kubeconfig=.*|--authorization-kubeconfig=/etc/kubernetes/scheduler-auth-broken.conf|g' "${MANIFEST_PATH}"
fi

# Step 3: Deploy test workloads requiring scheduling
echo -e "${YELLOW}[*] Deploying test namespace and workload...${NC}"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened-app
  namespace: ${NS}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hardened-app
  template:
    metadata:
      labels:
        app: hardened-app
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: "10m"
            memory: "16Mi"
EOF

echo -e "${GREEN}[+] Breakage successfully applied!${NC}\n"

# Step 4: Display Scenario Info to Student
cat <<EOF
================================================================================
${BOLD}${RED}LAB SCENARIO: KCSA Topic 2.3 - Scheduler Security Architecture Failure${NC}
================================================================================

${BOLD}PROBLEM STATEMENT:${NC}
A security audit was recently conducted on the control plane components. An engineer
attempted to harden the 'kube-scheduler' static pod parameters for mutual TLS (mTLS)
and RBAC authentication against the API Server. Shortly after applying the changes,
developers reported that new pods deployed to the cluster remain in the 'Pending'
state permanently.

${BOLD}OBSERVED SYMPTOMS:${NC}
1. New pods (such as those in namespace '${NS}') remain stuck in 'Pending'.
2. Control plane pod status for 'kube-scheduler' in namespace 'kube-system' shows
   CrashLoopBackOff, Error, or missing running instances.
3. System logs indicate authentication/authorization failures or certificate errors
   when kube-scheduler attempts to connect to kube-apiserver.

${BOLD}STUDENT OBJECTIVE:${NC}
1. Investigate why 'kube-scheduler' is failing to authenticate and operate correctly.
2. Inspect the static pod manifest at '${MANIFEST_PATH}'.
3. Restore valid TLS certificate references and kubeconfig paths for 'kube-scheduler'.
4. Ensure the deployment 'hardened-app' in namespace '${NS}' reaches 'Running' status.

${BOLD}VERIFICATION COMMANDS:${NC}
  kubectl get pods -n kube-system -l component=kube-scheduler
  kubectl get pods -n ${NS}
  crictl ps -a | grep scheduler

================================================================================
EOF

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & DIAGNOSTIC GUIDE (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# DIAGNOSIS PATH:
# 1. Check pod status in kube-system namespace:
#    $ kubectl get pods -n kube-system | grep scheduler
#    Output will show kube-scheduler pod missing, crashing, or failing health checks.
#
# 2. Inspect container logs via crictl or docker (since static pod might be failing before API registration):
#    $ crictl ps -a --name kube-scheduler
#    $ crictl logs <container-id>
#    Error output will highlight:
#    - "failed to load client CA file: open /etc/kubernetes/pki/ca-invalid.crt: no such file or directory"
#    - "stat /etc/kubernetes/scheduler-corrupted.conf: no such file or directory"
#
# 3. Inspect the static pod manifest file:
#    $ cat /etc/kubernetes/manifests/kube-scheduler.yaml
#
# FIX STEPS:
# Option A: Manual Edit of Manifest
#    Edit /etc/kubernetes/manifests/kube-scheduler.yaml and restore correct paths:
#    - Change --client-ca-file=/etc/kubernetes/pki/ca-invalid.crt back to /etc/kubernetes/pki/ca.crt
#    - Change --kubeconfig=/etc/kubernetes/scheduler-corrupted.conf back to /etc/kubernetes/scheduler.conf
#    - Change --authorization-kubeconfig=/etc/kubernetes/scheduler-auth-broken.conf back to /etc/kubernetes/scheduler.conf (if modified)
#
# Option B: Restore from Backup Script
#    $ cp /etc/kubernetes/manifests/kube-scheduler.yaml.bak_kcsa /etc/kubernetes/manifests/kube-scheduler.yaml
#
# VERIFICATION STEPS:
# 1. Kubelet automatically detects manifest change and restarts the scheduler static pod.
# 2. Confirm scheduler pod health:
#    $ kubectl get pods -n kube-system -l component=kube-scheduler
# 3. Confirm workload pod scheduling:
#    $ kubectl get pods -n kcsa-scheduler-lab
#    Both replicas of 'hardened-app' should transition from 'Pending' to 'Running'.
# ==============================================================================