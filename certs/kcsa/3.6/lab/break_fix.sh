#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Exam Prep
# Topic 3.6: Audit Logging (Weight: 3.14%)
# Production-Grade Break & Fix Lab Scenario
#
# Reference Documentation:
# - Kubernetes Audit Logging: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
# - KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# ==============================================================================

set -euo pipefail

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m' # No Color

BACKUP_DIR="/var/tmp/kcsa-audit-lab-backup"
MANIFEST_PATH="/etc/kubernetes/manifests/kube-apiserver.yaml"
AUDIT_DIR="/etc/kubernetes/audit"
POLICY_FILE="${AUDIT_DIR}/audit-policy.yaml"

log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $1"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_NC} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $1"
}

check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
       log_error "This script must be run as root (or with sudo) to edit control-plane manifests."
       exit 1
    fi

    if [[ ! -f "${MANIFEST_PATH}" ]]; then
        log_error "kube-apiserver static pod manifest not found at ${MANIFEST_PATH}."
        log_error "This lab requires a control-plane node (e.g., kubeadm, minikube with kubeadm driver)."
        exit 1
    fi
}

usage() {
    cat << EOF
Usage: $0 {break|verify|restore}

Commands:
  break    Simulate a production outage by breaking kube-apiserver audit logging setup.
  verify   Check if audit logging is functioning properly and kube-apiserver is healthy.
  restore  Restore original control-plane configuration from backup.

EOF
    exit 1
}

do_break() {
    check_prerequisites
    log_info "Initiating Break Scenario for KCSA Topic 3.6: Audit Logging..."

    # Create backup
    mkdir -p "${BACKUP_DIR}"
    if [[ ! -f "${BACKUP_DIR}/kube-apiserver.yaml.bak" ]]; then
        cp "${MANIFEST_PATH}" "${BACKUP_DIR}/kube-apiserver.yaml.bak"
        log_info "Backup created at ${BACKUP_DIR}/kube-apiserver.yaml.bak"
    fi

    mkdir -p "${AUDIT_DIR}"
    mkdir -p /var/log/kubernetes/audit

    # Create a corrupted audit policy file with syntax & API version errors
    cat << 'EOF' > "${POLICY_FILE}"
# Corrupted Audit Policy File for KCSA Lab
apiVersion: audit.k8s.io/v1alpha1  # Invalid / Deprecated API Version
kind: AuditPolicy                    # Incorrect Kind (Should be Policy)
rules:
  - level: Full                      # Invalid Level (Valid: None, Metadata, Request, RequestResponse)
    omitStages:
      - "RequestReceived"
  - level: Metadata
    resources:
    - group: ""
      resources: ["pods", "secrets"]
EOF
    chmod 600 "${POLICY_FILE}"

    # Inject invalid flag path and missing volumeMount mapping into kube-apiserver.yaml
    # 1. Point flag to wrong location inside container
    # 2. Add volumeMount pointing to incorrect host path
    python3 - << 'PYEOF'
import yaml

manifest_path = "/etc/kubernetes/manifests/kube-apiserver.yaml"

with open(manifest_path, 'r') as f:
    doc = yaml.safe_load(f)

container = doc['spec']['containers'][0]

# Clean existing audit flags if present
flags_to_remove = ['--audit-policy-file', '--audit-log-path', '--audit-log-maxage', '--audit-log-maxsize', '--audit-log-maxbackup']
container['command'] = [arg for arg in container['command'] if not any(arg.startswith(f) for f in flags_to_remove)]

# Add broken/mismatched audit flags
container['command'].extend([
    '--audit-policy-file=/etc/kubernetes/audit/policy-invalid.yaml', # Non-existent file in container
    '--audit-log-path=/var/log/kubernetes/audit/audit.log',
    '--audit-log-maxage=30',
    '--audit-log-maxbackup=10',
    '--audit-log-maxsize=100'
])

# Ensure volumeMounts and volumes exist or modify them improperly
volume_mounts = container.setdefault('volumeMounts', [])
volumes = doc['spec'].setdefault('volumes', [])

# Remove existing audit mounts if present
container['volumeMounts'] = [vm for vm in volume_mounts if vm['name'] != 'k8s-audit' and vm['name'] != 'k8s-audit-log']
doc['spec']['volumes'] = [v for v in volumes if v['name'] != 'k8s-audit' and v['name'] != 'k8s-audit-log']

# Add misconfigured volume mount (missing hostPath directory / incorrect container path)
container['volumeMounts'].append({
    'name': 'k8s-audit',
    'mountPath': '/etc/kubernetes/audit-wrong', # Path mismatch with flag
    'readOnly': True
})
container['volumeMounts'].append({
    'name': 'k8s-audit-log',
    'mountPath': '/var/log/kubernetes/audit',
    'readOnly': False
})

doc['spec']['volumes'].append({
    'name': 'k8s-audit',
    'hostPath': {
        'path': '/etc/kubernetes/audit',
        'type': 'DirectoryOrCreate'
    }
})
doc['spec']['volumes'].append({
    'name': 'k8s-audit-log',
    'hostPath': {
        'path': '/var/log/kubernetes/audit',
        'type': 'DirectoryOrCreate'
    }
})

with open(manifest_path, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False)
PYEOF

    log_warn "Break executed successfully!"
    echo "----------------------------------------------------------------------"
    echo -e "${COLOR_RED}OUTAGE INCIDENT SUMMARY:${COLOR_NC}"
    echo "The Security Compliance team enforced Kubernetes Audit Logging on the control plane."
    echo "An SRE modified '/etc/kubernetes/manifests/kube-apiserver.yaml' and created an audit policy."
    echo "Immediately after, the Kubernetes Control Plane became completely unreachable."
    echo ""
    echo -e "${COLOR_YELLOW}EXPECTED SYMPTOMS:${COLOR_NC}"
    echo "1. 'kubectl get nodes' returns: 'The connection to the server <host>:6443 was refused'."
    echo "2. The kube-apiserver static pod container repeatedly restarts or fails to start."
    echo ""
    echo -e "${COLOR_YELLOW}YOUR OBJECTIVE:${COLOR_NC}"
    echo "1. Diagnose why the API server fails to initialize using container runtime logs."
    echo "2. Fix all syntax, schema, and API version errors in '/etc/kubernetes/audit/audit-policy.yaml'."
    echo "3. Fix the flags, volumeMounts, and file path references in '/etc/kubernetes/manifests/kube-apiserver.yaml'."
    echo "4. Ensure audit events (at Metadata level for Secrets & ConfigMaps, and RequestResponse for Pods) are generated in '/var/log/kubernetes/audit/audit.log'."
    echo "----------------------------------------------------------------------"
}

do_verify() {
    log_info "Verifying Audit Logging setup and API Server health..."

    if ! kubectl cluster-info &>/dev/null; then
        log_error "API Server is not responding. 'kubectl' cannot connect to the cluster."
        log_error "Check container logs via: crictl logs \$(crictl ps -a --name kube-apiserver -q | head -n1)"
        exit 1
    fi

    log_success "API Server is healthy and reachable!"

    # Check if audit log file exists and receives entries
    if [[ ! -f "/var/log/kubernetes/audit/audit.log" ]]; then
        log_error "Audit log file /var/log/kubernetes/audit/audit.log does not exist!"
        exit 1
    fi

    # Trigger a test event to verify auditing
    kubectl get pods -n kube-system &>/dev/null || true
    sleep 2

    if grep -q "audit.k8s.io" /var/log/kubernetes/audit/audit.log 2>/dev/null; then
        log_success "Audit logs are actively being written to /var/log/kubernetes/audit/audit.log!"
        log_success "LAB COMPLETED SUCCESSFULLY! You solved the KCSA Audit Logging issue."
    else
        log_warn "API Server is running, but no audit events found in /var/log/kubernetes/audit/audit.log."
        log_warn "Verify '--audit-log-path' and volume mounts in kube-apiserver.yaml."
        exit 1
    fi
}

do_restore() {
    check_prerequisites
    log_info "Restoring original configuration..."

    if [[ -f "${BACKUP_DIR}/kube-apiserver.yaml.bak" ]]; then
        cp "${BACKUP_DIR}/kube-apiserver.yaml.bak" "${MANIFEST_PATH}"
        log_success "Restored ${MANIFEST_PATH} from backup."
    else
        log_error "No backup file found at ${BACKUP_DIR}/kube-apiserver.yaml.bak!"
        exit 1
    fi

    rm -rf "${AUDIT_DIR}"
    rm -rf /var/log/kubernetes/audit

    log_info "Waiting for API server to stabilize after restoration..."
    sleep 10
    if kubectl cluster-info &>/dev/null; then
        log_success "Control plane restored successfully."
    else
        log_warn "Control plane restored, but apiserver might still be restarting. Wait 15 seconds and test with 'kubectl get nodes'."
    fi
}

case "${1:-}" in
    break)
        do_break
        ;;
    verify)
        do_verify
        ;;
    restore)
        do_restore
        ;;
    *)
        usage
        ;;
esac

# ==============================================================================
# SOLUTION AND TROUBLESHOOTING GUIDE (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# STEP 1: Diagnose the Failure
# ------------------------------------------------------------------------------
# Run crictl or docker logs to view why kube-apiserver failed to launch:
#   $ sudo crictl ps -a --name kube-apiserver
#   $ sudo crictl logs <container-id>
#
# Typical Error Log 1:
#   "Error: open /etc/kubernetes/audit/policy-invalid.yaml: no such file or directory"
#   Reason: The API Server flag --audit-policy-file points to a file path that does not exist
#   inside the container mount.
#
# Typical Error Log 2 (once path fixed):
#   "error loading audit policy file: unknown group audit.k8s.io/v1alpha1" or "invalid Level Full"
#   Reason: Invalid apiVersion, Kind, or Rule Level in the audit policy YAML.
#
# STEP 2: Fix the Audit Policy YAML (/etc/kubernetes/audit/audit-policy.yaml)
# ------------------------------------------------------------------------------
# Edit /etc/kubernetes/audit/audit-policy.yaml and replace content with valid syntax:
#
# cat << 'EOF' > /etc/kubernetes/audit/audit-policy.yaml
# apiVersion: audit.k8s.io/v1
# kind: Policy
# omitStages:
#   - "RequestReceived"
# rules:
#   # Do not log audit events for noisy system endpoints
#   - level: None
#     users: ["system:kube-proxy"]
#     verbs: ["watch"]
#     resources:
#       - group: ""
#         resources: ["endpoints", "services", "services/status"]
#
#   # Log secret and configmap access at Metadata level for security compliance
#   - level: Metadata
#     resources:
#       - group: ""
#         resources: ["secrets", "configmaps"]
#
#   # Log pod lifecycle requests at RequestResponse level
#   - level: RequestResponse
#     resources:
#       - group: ""
#         resources: ["pods"]
#
#   # Default fallback for all other resources
#   - level: Metadata
# EOF
# chmod 600 /etc/kubernetes/audit/audit-policy.yaml
#
# STEP 3: Fix kube-apiserver Static Pod Manifest (/etc/kubernetes/manifests/kube-apiserver.yaml)
# ------------------------------------------------------------------------------
# Open /etc/kubernetes/manifests/kube-apiserver.yaml and verify three key elements:
#
# A. Command Flags under spec.containers[0].command:
#   - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
#   - --audit-log-path=/var/log/kubernetes/audit/audit.log
#   - --audit-log-maxage=30
#   - --audit-log-maxbackup=10
#   - --audit-log-maxsize=100
#
# B. VolumeMounts under spec.containers[0].volumeMounts:
#   - mountPath: /etc/kubernetes/audit
#     name: k8s-audit
#     readOnly: true
#   - mountPath: /var/log/kubernetes/audit
#     name: k8s-audit-log
#     readOnly: false
#
# C. Volumes under spec.volumes:
#   - name: k8s-audit
#     hostPath:
#       path: /etc/kubernetes/audit
#       type: DirectoryOrCreate
#   - name: k8s-audit-log
#     hostPath:
#       path: /var/log/kubernetes/audit
#       type: DirectoryOrCreate
#
# STEP 4: Verification
# ------------------------------------------------------------------------------
# 1. Wait for static pod watcher to restart kube-apiserver (approx. 15-30s).
# 2. Check cluster readiness:
#    $ kubectl get nodes
# 3. Verify audit log creation and content:
#    $ tail -f /var/log/kubernetes/audit/audit.log
# 4. Run verification command in this script:
#    $ sudo ./break_fix_audit_logging.sh verify
# ==============================================================================