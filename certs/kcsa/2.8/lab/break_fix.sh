#!/usr/bin/env bash
# ==============================================================================
# KCSA (Kubernetes & Cloud Native Security Associate) Lab Environment
# Domain 2: Kubernetes Cluster Hardening | Topic 2.8: Etcd Security
# Script Type: Safe & Controlled "Break & Fix" Production Simulation
#
# ARCHITECTURAL OVERVIEW & DEEP MECHANICS:
# Etcd is the strongly consistent, distributed key-value store used as Kubernetes'
# primary datastore. It stores the full state of the cluster, including sensitive
# resources such as Secrets, ConfigMaps, and service account tokens.
#
# Key Security Mechanisms:
# 1. Transport Layer Security (mTLS):
#    - Client-to-Server TLS: `--client-cert-auth=true`, `--trusted-ca-file`,
#      `--cert-file`, `--key-file`. Enforces mutual TLS so only authorized clients
#      (primarily kube-apiserver) can query or mutate etcd.
#    - Peer-to-Peer TLS: `--peer-client-cert-auth=true`, `--peer-trusted-ca-file`,
#      `--peer-cert-file`, `--peer-key-file`. Secures inter-node Raft consensus.
# 2. Encryption at Rest:
#    - Configured via `--encryption-provider-config` in `kube-apiserver`.
#    - Without this, secrets are stored in plaintext inside etcd key paths
#      (`/registry/secrets/<namespace>/<name>`).
# 3. Network Isolation & Access Control:
#    - Etcd should listen strictly on loopback (127.0.0.1) or dedicated internal interfaces.
#    - Listening on 0.0.0.0 without client cert verification exposes the entire cluster database.
#
# OFFICIAL REFERENCES & CURRICULUM LINKS:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - K8s Etcd Hardening: https://kubernetes.io/docs/setup/best-practices/securing-a-cluster/#securing-etcd
# - Etcd Official Security Guide: https://etcd.io/docs/v3.5/op-guide/security/
# - K8s Encryption at Rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This lab script must be executed as root." >&2
   exit 1
fi

MANIFEST_DIR="/etc/kubernetes/manifests"
ETCD_MANIFEST="${MANIFEST_DIR}/etcd.yaml"
APISERVER_MANIFEST="${MANIFEST_DIR}/kube-apiserver.yaml"
BACKUP_DIR="/var/lib/kcsa-etcd-lab-backup"

if [[ ! -f "$ETCD_MANIFEST" ]]; then
    echo "[ERROR] Static pod manifest $ETCD_MANIFEST not found." >&2
    echo "Ensure you are running this script on a control-plane node (kubeadm)." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Backup Stage
# ------------------------------------------------------------------------------
echo "[+] Step 1: Creating configuration backup..."
mkdir -p "$BACKUP_DIR"
cp "$ETCD_MANIFEST" "${BACKUP_DIR}/etcd.yaml.bak"
if [[ -f "$APISERVER_MANIFEST" ]]; then
    cp "$APISERVER_MANIFEST" "${BACKUP_DIR}/kube-apiserver.yaml.bak"
fi
echo "    Backup created at ${BACKUP_DIR}/"

# ------------------------------------------------------------------------------
# Controlled Chaos Injection (Break Stage)
# ------------------------------------------------------------------------------
echo "[+] Step 2: Injecting controlled security & PKI misconfigurations into etcd..."

# Misconfiguration 1: Corrupt trusted CA file path (Simulating broken mTLS validation)
sed -i 's|--trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt|--trusted-ca-file=/etc/kubernetes/pki/etcd/ca-broken.crt|g' "$ETCD_MANIFEST"

# Misconfiguration 2: Disable client certificate authentication (Security vulnerability)
sed -i 's|--client-cert-auth=true|--client-cert-auth=false|g' "$ETCD_MANIFEST"

# Misconfiguration 3: Bind etcd client URL to insecure non-TLS HTTP listener alongside HTTPS
sed -i 's|--listen-client-urls=https://127.0.0.1:2379,https://|--listen-client-urls=http://127.0.0.1:2379,https://|g' "$ETCD_MANIFEST"

echo "[+] Step 3: Triggering kubelet container recreation..."
# Kubelet automatically reloads static pods when manifest changes
touch "$ETCD_MANIFEST"

sleep 5

# ------------------------------------------------------------------------------
# Student Briefing & Symptom Explanation
# ------------------------------------------------------------------------------
cat << 'EOF'

==============================================================================
               LAB BREAK & FIX CHALLENGE: ETCD SECURITY & PKI BREAK
==============================================================================

[Symptom Description]:
The Kubernetes control plane has become unstable or unresponsive.
When executing `kubectl get nodes` or `kubectl get pods`, you may observe:
  - Error: "The connection to the server localhost:6443 was refused"
  - TLS handshake failures in `kube-apiserver` logs when connecting to etcd.
  - Potential unauthenticated HTTP endpoint exposure risk on etcd.

[Student Learning Objectives]:
1. Identify why `kube-apiserver` cannot communicate securely with `etcd`.
2. Inspect etcd container logs and status using container runtime tools (`crictl`).
3. Audit etcd flags for mTLS compliance (`--client-cert-auth`, `--trusted-ca-file`, `--cert-file`, `--key-file`).
4. Validate etcd health using `etcdctl` with proper PKI flags.
5. Remediate `/etc/kubernetes/manifests/etcd.yaml` to restore strict mTLS and cluster health.

[Diagnostic Tools & Expected Commands]:
- Check pod status:
    crictl ps --name etcd
    crictl logs <etcd-container-id>
- Inspect kubelet logs:
    journalctl -u kubelet -n 50 --no-pager
- Test etcd endpoints directly (mTLS check):
    ETCDCTL_API=3 etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      endpoint health

==============================================================================
TRY TO SOLVE THIS TASK NOW.
A complete step-by-step solution is included inside this script file (commented).
==============================================================================

EOF

exit 0

# ==============================================================================
#                               STEP-BY-STEP SOLUTION
# ==============================================================================
# To restore the environment, follow these SRE diagnostic and repair steps:
#
# STEP 1: Diagnose the Failure
# ------------------------------------------------------------------------------
# Inspect kube-apiserver logs to check etcd connectivity:
#   crictl logs $(crictl ps --name kube-apiserver -q)
# Expected Log Snippet:
#   "http: TLS handshake error from 127.0.0.1:...: remote error: tls: bad certificate"
#   or "context deadline exceeded"
#
# Inspect etcd container logs:
#   crictl logs $(crictl ps -a --name etcd -q | head -n1)
# Expected Log Snippet:
#   "cannot load certificate /etc/kubernetes/pki/etcd/ca-broken.crt: open ... no such file or directory"
#
# STEP 2: Audit Manifest Configuration
# ------------------------------------------------------------------------------
# Open `/etc/kubernetes/manifests/etcd.yaml` and check the command arguments:
#   vi /etc/kubernetes/manifests/etcd.yaml
#
# Look for the following invalid/insecure flags:
#   1. `--trusted-ca-file=/etc/kubernetes/pki/etcd/ca-broken.crt`  <-- Broken path
#   2. `--client-cert-auth=false`                                 <-- Insecure! Must be true
#   3. `--listen-client-urls=http://127.0.0.1:2379,...`           <-- Insecure HTTP exposure!
#
# STEP 3: Fix Manifest Configuration
# ------------------------------------------------------------------------------
# Correct `/etc/kubernetes/manifests/etcd.yaml` arguments:
#
# Corrected flags block:
#   spec:
#     containers:
#     - command:
#       - etcd
#       - --advertise-client-urls=https://127.0.0.1:2379
#       - --cert-file=/etc/kubernetes/pki/etcd/server.crt
#       - --client-cert-auth=true
#       - --initial-advertise-peer-urls=https://127.0.0.1:2380
#       - --initial-cluster=control-plane=https://127.0.0.1:2380
#       - --key-file=/etc/kubernetes/pki/etcd/server.key
#       - --listen-client-urls=https://127.0.0.1:2379,https://<NODE_IP>:2379
#       - --listen-metrics-urls=http://127.0.0.1:2381
#       - --listen-peer-urls=https://127.0.0.1:2380
#       - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
#       - --peer-client-cert-auth=true
#       - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
#       - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
#       - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
#
# Alternatively, restore from backup:
#   cp /var/lib/kcsa-etcd-lab-backup/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
#
# STEP 4: Verification
# ------------------------------------------------------------------------------
# 1. Wait 15-30 seconds for kubelet to restart static pods.
# 2. Check pod health:
#      kubectl get pods -n kube-system
# 3. Test etcd endpoint health using etcdctl:
#      ETCDCTL_API=3 etcdctl \
#        --endpoints=https://127.0.0.1:2379 \
#        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
#        --cert=/etc/kubernetes/pki/etcd/server.crt \
#        --key=/etc/kubernetes/pki/etcd/server.key \
#        endpoint health
#
# Expected output:
#   https://127.0.0.1:2379 is healthy: successfully committed proposal: took = ...
# ==============================================================================