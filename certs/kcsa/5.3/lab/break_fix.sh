#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Exam Preparation
# Topic 5.3: Observability (Weight: 2.29%)
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#
# LAB SCENARIO: Kubernetes API Security Audit Logging Pipeline Failure
# ------------------------------------------------------------------------------
# DESCRIPTION:
# As a Senior SRE / Security Architect, you are tasked with verifying audit logging
# compliance across control plane components. A junior engineer attempted to update
# the API server security audit policy and log backend path, causing the 
# kube-apiserver static pod to crash continuously and breaking security observability.
#
# OBJECTIVE:
# Diagnose the failure using control plane logs, fix the audit policy syntax,
# resolve hostPath volume mount/permission conflicts, and restore security audit event generation.
#
# SYMPTOMS TO OBSERVE:
# 1. `kubectl` commands fail with "The connection to the server localhost:6443 was refused".
# 2. `crictl ps` or `docker ps` shows kube-apiserver restarting or in Exited state.
# 3. Kubelet logs report static pod container creation failures related to flags/mounts.
# 4. Security audit logs are missing from the targeted host log directory.
# ==============================================================================

set -euo pipefail

# Visual formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LOG_DIR="/var/log/kubernetes/audit"
POLICY_DIR="/etc/kubernetes/audit"
MANIFEST_FILE="/etc/kubernetes/manifests/kube-apiserver.yaml"
BACKUP_DIR="/tmp/kcsa-lab-backup-5.3"

function print_header() {
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}  KCSA 5.3: Security Observability - Break & Fix Lab Script  ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

function check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This lab script must be executed as root (sudo).${NC}"
        exit 1
    fi

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        echo -e "${YELLOW}[WARN] Static pod manifest $MANIFEST_FILE not found.${NC}"
        echo -e "${YELLOW}Creating mock directory structure for standalone lab validation...${NC}"
        mkdir -p /etc/kubernetes/manifests
        cat <<'EOF' > "$MANIFEST_FILE"
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.30.0
    command:
    - kube-apiserver
    - --advertise-address=127.0.0.1
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
EOF
    fi
}

function backup_state() {
    echo -e "${CYAN}[+] Backing up existing configuration to $BACKUP_DIR...${NC}"
    mkdir -p "$BACKUP_DIR"
    cp "$MANIFEST_FILE" "$BACKUP_DIR/kube-apiserver.yaml.bak" 2>/dev/null || true
    if [[ -d "$POLICY_DIR" ]]; then
        cp -r "$POLICY_DIR" "$BACKUP_DIR/audit-policy.bak" 2>/dev/null || true
    fi
}

function break_environment() {
    echo -e "${YELLOW}[!] Injecting security observability fault into control plane...${NC}"

    # 1. Prepare directories
    mkdir -p "$POLICY_DIR"
    mkdir -p "$LOG_DIR"

    # 2. Inject invalid AuditPolicy manifest (Syntax/Schema Error + Invalid Stage Enum)
    cat <<'EOF' > "$POLICY_DIR/audit-policy.yaml"
apiVersion: audit.k8s.io/v1
kind: AuditPolicy
rules:
  # Fault 1: Invalid level value 'FullDetails' (Must be None, Metadata, Request, or RequestResponse)
  - level: FullDetails
    resources:
      - group: ""
        resources: ["pods", "secrets"]
  # Fault 2: Invalid omitStages value 'ResponseStarted' (Must be RequestReceived, ResponseStarted, etc. with typo: 'RespStarted')
  - level: Metadata
    omitStages:
      - RespStarted
    userGroups: ["system:authenticated"]
EOF

    # 3. Lock directory permissions so kube-apiserver process cannot write audit logs
    chmod 000 "$LOG_DIR"
    chown 1000:1000 "$LOG_DIR"

    # 4. Inject broken CLI flags and volume mounts into API server manifest
    # Fault 3: Invalid flag `--audit-log-mode=blocking-sync` (Valid modes: batch, blocking)
    # Fault 4: Non-existent policy file path reference
    python3 - <<'PYTHON_EOF'
import yaml

manifest_path = "/etc/kubernetes/manifests/kube-apiserver.yaml"

with open(manifest_path, 'r') as f:
    doc = yaml.safe_load(f)

container = doc['spec']['containers'][0]
command = container.get('command', [])

# Remove existing audit flags
command = [c for c in command if not c.startswith('--audit-')]

# Inject broken flags
command.extend([
    '--audit-policy-file=/etc/kubernetes/audit/invalid-policy-filename.yaml',
    '--audit-log-path=/var/log/kubernetes/audit/sec-audit.log',
    '--audit-log-maxage=30',
    '--audit-log-maxbackup=10',
    '--audit-log-maxsize=100',
    '--audit-log-mode=blocking-sync'
])

container['command'] = command

# Inject volumes if missing
volumes = doc['spec'].setdefault('volumes', [])
volume_mounts = container.setdefault('volumeMounts', [])

# Audit policy mount
if not any(v['name'] == 'audit-policy' for v in volumes):
    volumes.append({'name': 'audit-policy', 'hostPath': {'path': '/etc/kubernetes/audit', 'type': 'DirectoryOrCreate'}})
    volume_mounts.append({'name': 'audit-policy', 'mountPath': '/etc/kubernetes/audit', 'readOnly': True})

# Audit log mount
if not any(v['name'] == 'audit-log' for v in volumes):
    volumes.append({'name': 'audit-log', 'hostPath': {'path': '/var/log/kubernetes/audit', 'type': 'Directory'}})
    volume_mounts.append({'name': 'audit-log', 'mountPath': '/var/log/kubernetes/audit', 'readOnly': True}) # Fault 5: Mounted ReadOnly!

with open(manifest_path, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False)

PYTHON_EOF

    echo -e "${RED}[X] Fault injection complete! Security Observability is broken.${NC}"
}

function display_challenge() {
    echo ""
    echo -e "${GREEN}----------------------------------------------------------------------${NC}"
    echo -e "${GREEN}STUDENT INSTRUCTIONS - KCSA 5.3 OBSERVABILITY CHALLENGE${NC}"
    echo -e "${GREEN}----------------------------------------------------------------------${NC}"
    echo -e "Scenario: Kubernetes API Server Security Audit Logging is non-functional."
    echo -e "Your task is to restore the API server and enable proper security auditing."
    echo ""
    echo -e "${YELLOW}Expected Troubleshooting Steps:${NC}"
    echo -e " 1. Inspect static pod state and crictl/docker logs or system logs:"
    echo -e "    $ sudo crictl ps -a | grep kube-apiserver"
    echo -e "    $ sudo crictl logs <container_id>"
    echo -e "    $ sudo tail -n 50 /var/log/syslog | grep kube-apiserver"
    echo -e " 2. Fix flag errors in: ${CYAN}$MANIFEST_FILE${NC}"
    echo -e "    - Ensure valid audit log mode ('batch' or 'blocking')."
    echo -e "    - Ensure correct path to audit policy file."
    echo -e "    - Fix volume mount read-only restriction for the log directory."
    echo -e " 3. Fix syntax and schema errors in: ${CYAN}$POLICY_DIR/audit-policy.yaml${NC}"
    echo -e "    - Valid audit levels: None, Metadata, Request, RequestResponse."
    echo -e "    - Valid omitStages: RequestReceived, ResponseStarted, ResponseComplete, Panic."
    echo -e " 4. Fix host file permissions on ${CYAN}$LOG_DIR${NC} so the process can write."
    echo -e " 5. Verify security events are generated in ${CYAN}$LOG_DIR/sec-audit.log${NC}."
    echo -e "${GREEN}----------------------------------------------------------------------${NC}"
}

print_header
check_prerequisites
backup_state
break_environment
display_challenge

# ==============================================================================
# SOLUTION AND VERIFICATION (KEEP COMMENTED OUT FOR STUDENTS)
# ==============================================================================
#
# STEP-BY-STEP SOLUTION:
#
# 1. Identify the root causes of the API server crash:
#    Inspect logs:
#    $ sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -n1)
#    Error output will indicate:
#    - invalid flag --audit-log-mode=blocking-sync
#    - audit policy file does not exist (/etc/kubernetes/audit/invalid-policy-filename.yaml)
#    - unknown level "FullDetails" in audit policy
#    - permission denied when creating /var/log/kubernetes/audit/sec-audit.log
#
# 2. Fix Host Directory Permissions:
#    $ sudo chmod 755 /var/log/kubernetes/audit
#    $ sudo chown root:root /var/log/kubernetes/audit
#
# 3. Correct Audit Policy (/etc/kubernetes/audit/audit-policy.yaml):
#    $ sudo cat <<'EOF' > /etc/kubernetes/audit/audit-policy.yaml
#    apiVersion: audit.k8s.io/v1
#    kind: AuditPolicy
#    rules:
#      - level: RequestResponse
#        resources:
#          - group: ""
#            resources: ["pods", "secrets"]
#      - level: Metadata
#        omitStages:
#          - ResponseStarted
#        userGroups: ["system:authenticated"]
#    EOF
#
# 4. Correct Static Pod Manifest (/etc/kubernetes/manifests/kube-apiserver.yaml):
#    Update flags in container spec:
#    - Set: --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
#    - Set: --audit-log-mode=batch
#    - Update volumeMounts for audit-log: change 'readOnly: true' to 'readOnly: false'
#
# 5. Verification:
#    - Check pod health:
#      $ kubectl get pods -n kube-system -l component=kube-apiserver
#    - Trigger an audited event:
#      $ kubectl get pods -A
#    - Verify log stream output:
#      $ sudo tail -f /var/log/kubernetes/audit/sec-audit.log | jq .
# ==============================================================================