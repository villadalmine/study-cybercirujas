#!/usr/bin/env bash

# ==============================================================================
# CNCF KCSA Certification Study Material - Exam Topic 2.1: API Server
# Script Type: Break & Fix Lab Scenario
# Purpose: Controlled security misconfiguration breakdown for hands-on SRE diagnosis
# Official References:
#   - https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#   - https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[!] Error: This script must be executed as root (sudo)." >&2
    exit 1
fi

MANIFEST_PATH="/etc/kubernetes/manifests/kube-apiserver.yaml"
ENCRYPTION_CONFIG_PATH="/etc/kubernetes/encryption-config.yaml"
TIMESTAMP=$(date +%s)
BACKUP_PATH="/etc/kubernetes/manifests/kube-apiserver.yaml.bak.${TIMESTAMP}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "[!] Error: Kube-APIServer static pod manifest not found at ${MANIFEST_PATH}." >&2
    echo "    This lab requires a control-plane node managed via Kubeadm, Kind, or Minikube static pods." >&2
    exit 1
fi

echo "[+] Starting KCSA Topic 2.1 API Server Break & Fix Scenario..."

# ------------------------------------------------------------------------------
# Step 1: Backup Existing API Server Manifest
# ------------------------------------------------------------------------------
cp "$MANIFEST_PATH" "$BACKUP_PATH"
echo "[+] Backup of API Server manifest saved to: ${BACKUP_PATH}"

# ------------------------------------------------------------------------------
# Step 2: Inject Malformed Encryption Configuration (Breakage)
# ------------------------------------------------------------------------------
# Creates an invalid EncryptionConfiguration missing a 32-byte base64 encoded secret.
cat << 'EOF' > "$ENCRYPTION_CONFIG_PATH"
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: invalid-short-key-not-base64
      - identity: {}
EOF
chmod 600 "$ENCRYPTION_CONFIG_PATH"
echo "[+] Created malformed EncryptionConfiguration at ${ENCRYPTION_CONFIG_PATH}"

# Add --encryption-provider-config flag to static pod manifest if not already present
if ! grep -q "--encryption-provider-config=" "$MANIFEST_PATH"; then
    sed -i '/- kube-apiserver/a \    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml' "$MANIFEST_PATH"
    echo "[+] Injected --encryption-provider-config flag into ${MANIFEST_PATH}"
fi

echo "[+] Kubelet will now trigger static pod reconciliation for kube-apiserver."
echo ""

# ------------------------------------------------------------------------------
# Student Instructions & Diagnostics Briefing
# ------------------------------------------------------------------------------
cat << 'EOF'
================================================================================
  KCSA LAB SCENARIO 2.1: API SERVER ENCRYPTION AT REST FAILURE
================================================================================

[SYMPTOMS OBSERVED]:
  - The Kubernetes API Server has crashed and stopped responding to clients.
  - Running 'kubectl get nodes' or any API command fails with:
    "The connection to the server <host>:6443 was refused - did you specify the right host or port?"

[STUDENT OBJECTIVES]:
  1. Identify why the kube-apiserver static pod container fails to initialize.
  2. Inspect low-level container runtime logs (using crictl/docker/journalctl).
  3. Locate the corrupted security configuration file causing startup rejection.
  4. Fix the issue by configuring a valid AES-CBC 32-byte base64 secret key in
     '/etc/kubernetes/encryption-config.yaml'.
  5. Verify that the control plane recovers and API Server successfully serves traffic.

[REQUIRED ENVIRONMENT]:
  - Linux VM running Kubernetes control plane with static pod manifests.

================================================================================
EOF

# ==============================================================================
# COMMENTED-OUT STEP-BY-STEP SOLUTION & TROUBLESHOOTING GUIDE
# ==============================================================================
#
# STEP 1: Inspect Container Logs
# ------------------------------------------------------------------------------
# Since API Server is down, kubectl cannot be used. Inspect low-level container
# logs via crictl:
#
#   sudo crictl ps -a --name kube-apiserver
#   sudo crictl logs <CONTAINER_ID>
#
# Expected error output in logs:
#   "error: failed to create encryption provider: secret is not 32 bytes long"
#
# STEP 2: Generate Valid 32-Byte Base64 Secret Key
# ------------------------------------------------------------------------------
# Generate a cryptographically secure 32-byte key encoded in base64:
#
#   NEW_KEY=$(head -c 32 /dev/urandom | base64)
#   echo "Generated Key: ${NEW_KEY}"
#
# STEP 3: Repair EncryptionConfiguration Schema
# ------------------------------------------------------------------------------
# Overwrite /etc/kubernetes/encryption-config.yaml with syntactically valid YAML:
#
#   cat <<EOF | sudo tee /etc/kubernetes/encryption-config.yaml
#   apiVersion: apiserver.config.k8s.io/v1
#   kind: EncryptionConfiguration
#   resources:
#     - resources:
#         - secrets
#       providers:
#         - aescbc:
#             keys:
#               - name: key1
#                 secret: ${NEW_KEY}
#         - identity: {}
#   EOF
#   sudo chmod 600 /etc/kubernetes/encryption-config.yaml
#
# STEP 4: Verify API Server Recovery
# ------------------------------------------------------------------------------
# Kubelet automatically reloads static pods upon file modification. Wait ~30s:
#
#   kubectl get nodes
#   kubectl get pods -n kube-system
#
# STEP 5: Verify Secret Encryption at Rest in etcd
# ------------------------------------------------------------------------------
# Create a test secret:
#   kubectl create secret generic kcsatest --from-literal=pass=supersecret
#
# Query raw ETCD key store to verify encryption prefix (k8s:enc:aescbc:v1:key1):
#   ETCDCTL_API=3 etcdctl \
#     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
#     --cert=/etc/kubernetes/pki/etcd/server.crt \
#     --key=/etc/kubernetes/pki/etcd/server.key \
#     get /registry/secrets/default/kcsatest | hexdump -C
#
# ROLLBACK / CLEANUP (If needed):
#   sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak.* /etc/kubernetes/manifests/kube-apiserver.yaml
#   sudo rm -f /etc/kubernetes/encryption-config.yaml
# ==============================================================================