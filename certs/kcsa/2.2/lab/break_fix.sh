#!/usr/bin/env bash
# ==============================================================================
# KCSA Certification Lab - Topic 2.2: Controller Manager Security (Weight: 2.0)
# Break & Fix Exercise: kube-controller-manager Security Configuration Failure
#
# Official References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes kube-controller-manager Security Reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
# - PKI & Service Account Tokens: https://kubernetes.io/docs/concepts/security/control-plane-hardening/
# ==============================================================================

set -euo pipefail

MANIFEST_PATH="/etc/kubernetes/manifests/kube-controller-manager.yaml"
BACKUP_PATH="/etc/kubernetes/manifests/kube-controller-manager.yaml.bak"

# 1. Environment & Prerequisites Check
if [[ "${EUID}" -ne 0 ]]; then
  echo "[-] ERROR: This script must be executed with root privileges." >&2
  exit 1
fi

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  echo "[-] ERROR: Static pod manifest '${MANIFEST_PATH}' not found." >&2
  echo "[-] Please run this script on a Kubernetes control-plane node managed by kubeadm." >&2
  exit 1
fi

echo "[+] Initializing KCSA Topic 2.2 (Controller Manager) Lab Environment..."

# 2. Create Backup of Original Manifest
if [[ ! -f "${BACKUP_PATH}" ]]; then
  cp "${MANIFEST_PATH}" "${BACKUP_PATH}"
  echo "[+] Backup created at: ${BACKUP_PATH}"
else
  echo "[+] Existing backup detected at: ${BACKUP_PATH}"
fi

# 3. Inject Controlled Security Misconfiguration
# Replaces the valid ServiceAccount private key path with an invalid path.
# This prevents the ServiceAccount controller from signing JWT tokens.
sed -i 's|--service-account-private-key-file=/etc/kubernetes/pki/sa.key|--service-account-private-key-file=/etc/kubernetes/pki/sa-invalid.key|g' "${MANIFEST_PATH}"

echo "[+] Injected misconfiguration into ${MANIFEST_PATH}"
echo "[+] Waiting for Kubelet static pod manager to reload the component (15s)..."
sleep 15

# 4. Display Scenario Details to Student
cat << 'EOF'
================================================================================
LAB SCENARIO: KCSA Topic 2.2 - kube-controller-manager Security Failure
================================================================================

SITUATION:
During a security audit and maintenance cycle on the control plane, an engineer
updated the security flags on `kube-controller-manager`. Shortly after, cluster
reconciliation stopped, and new workloads failed to acquire valid ServiceAccount
authentication tokens.

SYMPTOMS:
1. `kubectl get pods -n kube-system` shows `kube-controller-manager` stuck in
   `CrashLoopBackOff` or `Error` state.
2. `kubectl logs` or container runtime logs reveal initialization errors related to
   cryptographic key loading for ServiceAccount token signing.
3. API server metrics report controller manager component health as degraded.

STUDENT OBJECTIVES:
1. Diagnose why `kube-controller-manager` static pod container is failing.
2. Use CLI diagnostics (`kubectl`, `crictl`, or `journalctl`) to extract the exact root cause log line.
3. Locate the misconfiguration in `/etc/kubernetes/manifests/kube-controller-manager.yaml`.
4. Correct the parameter `--service-account-private-key-file` to point to the valid PKI key file.
5. Verify that `kube-controller-manager` reaches `1/1 Running` state.

EXPECTED VERIFICATION OUTPUT:
$ kubectl get pods -n kube-system -l component=kube-controller-manager
NAME                                       READY   STATUS    RESTARTS   AGE
kube-controller-manager-control-plane      1/1     Running   0          45s

================================================================================
EOF

# ==============================================================================
# SOLUTION AND TROUBLESHOOTING GUIDE (COMMENTED OUT)
# ==============================================================================
#
# STEP 1: Identify degraded control plane pod status
#   kubectl get pods -n kube-system -l component=kube-controller-manager
#
# EXPECTED OUTPUT:
#   NAME                                    READY   STATUS             RESTARTS   AGE
#   kube-controller-manager-control-plane   0/1     CrashLoopBackOff   3          90s
#
# STEP 2: Extract container crash logs via crictl or kubectl
#   NODE_NAME=$(hostname)
#   kubectl logs -n kube-system "kube-controller-manager-${NODE_NAME}" --tail=20
#   
#   OR directly via container runtime interface CLI:
#   CONTAINER_ID=$(crictl ps -a --name kube-controller-manager -q | head -n 1)
#   crictl logs "${CONTAINER_ID}"
#
# EXPECTED LOG ERROR:
#   "error execution kube-controller-manager: open /etc/kubernetes/pki/sa-invalid.key: no such file or directory"
#
# STEP 3: Inspect PKI directory for valid private key file
#   ls -la /etc/kubernetes/pki/sa.key
#
# STEP 4: Correct the static pod manifest path
#   sudo sed -i 's|--service-account-private-key-file=/etc/kubernetes/pki/sa-invalid.key|--service-account-private-key-file=/etc/kubernetes/pki/sa.key|g' /etc/kubernetes/manifests/kube-controller-manager.yaml
#
# STEP 5: Verify automatic recovery by Kubelet
#   watch kubectl get pods -n kube-system -l component=kube-controller-manager
#
# STEP 6: Confirm healthz endpoint status
#   kubectl get --raw /healthz
# ==============================================================================