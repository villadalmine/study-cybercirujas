#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate)
# Domain 6: Compliance and Standards | Topic 6.1: Compliance Frameworks
# 
# LAB EXERCISE: CIS Kubernetes Benchmark & Compliance Remediation
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# 
# Description:
# This script simulates a production Kubernetes control plane environment that 
# fails automated compliance audits (CIS Kubernetes Benchmark v1.8.0 & 
# NSA/CISA Kubernetes Hardening Guidance). 
# 
# TARGET OBJECTIVES:
# 1. Identify non-compliant control plane manifest permissions and flags.
# 2. Remediate API Server and Controller Manager configurations to comply with CIS.
# 3. Apply Pod Security Admission (PSA) standards to namespaces as per NIST/NSA.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

MANIFEST_DIR="/etc/kubernetes/manifests"
APISERVER_MANIFEST="${MANIFEST_DIR}/kube-apiserver.yaml"
CONTROLLER_MANIFEST="${MANIFEST_DIR}/kube-controller-manager.yaml"

function log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

function check_prereqs() {
    log_info "Checking prerequisites..."
    if [[ $EUID -ne 0 ]]; then
       log_error "This script must be run as root to modify control plane manifests in /etc/kubernetes/manifests."
       exit 1
    fi
}

function break_environment() {
    log_info "Injecting compliance violations into the control plane environment..."

    mkdir -p "${MANIFEST_DIR}"

    # Injecting API Server Violations (CIS 1.1.1, CIS 1.2.1)
    cat <<EOF > "${APISERVER_MANIFEST}"
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
    - --advertise-address=192.168.1.10
    - --allow-privileged=true
    - --anonymous-auth=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --etcd-servers=https://127.0.0.1:2379
    - --profiling=true
    - --secure-port=6443
EOF

    # CIS 1.1.1 Violation: Insecure file permissions (0777 instead of 0600)
    chmod 777 "${APISERVER_MANIFEST}"

    # Injecting Controller Manager Violations (CIS 1.3.2)
    cat <<EOF > "${CONTROLLER_MANIFEST}"
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - name: kube-controller-manager
    image: registry.k8s.io/kube-controller-manager:v1.30.0
    command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --bind-address=127.0.0.1
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --cluster-cidr=10.244.0.0/16
    - --profiling=true
EOF

    chmod 644 "${CONTROLLER_MANIFEST}"

    # Create non-compliant namespace configuration mock
    mkdir -p /tmp/kcsa-compliance
    cat <<EOF > /tmp/kcsa-compliance/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-workloads
  labels:
    environment: production
EOF

    log_warn "BREAK COMPLETE: Control plane components have been configured with security violations."
    echo ""
    show_symptoms
}

function show_symptoms() {
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "${YELLOW}                  SECURITY AUDIT SYMPTOMS & REPORT                   ${NC}"
    echo -e "${YELLOW}======================================================================${NC}"
    echo "An automated security scanner (CIS Benchmark / NSA-CISA Framework) evaluated"
    echo "the Kubernetes environment and flagged critical compliance failures:"
    echo ""
    echo "  [FAIL] CIS 1.1.1: Ensure that the API server pod specification file permissions"
    echo "                    are set to 600 or more restrictive."
    echo "                    Current permissions: $(stat -c "%a" "${APISERVER_MANIFEST}" 2>/dev/null || echo "Unknown")"
    echo ""
    echo "  [FAIL] CIS 1.2.1: Ensure that the --anonymous-auth argument is set to false."
    echo "                    Current setting: --anonymous-auth=true in kube-apiserver"
    echo ""
    echo "  [FAIL] CIS 1.3.2: Ensure that the --profiling argument is set to false."
    echo "                    Current setting: --profiling=true in kube-controller-manager"
    echo ""
    echo "  [FAIL] NIST SP 800-190 / NSA-CISA: Pod Security Standards enforcement missing."
    echo "                    Namespace 'production-workloads' is missing PSA labels."
    echo ""
    echo -e "${BLUE}YOUR TASK:${NC}"
    echo "1. Fix file permissions for '${APISERVER_MANIFEST}' to '600'."
    echo "2. Edit '${APISERVER_MANIFEST}' and set '--anonymous-auth=false'."
    echo "3. Edit '${CONTROLLER_MANIFEST}' and set '--profiling=false'."
    echo "4. Update '/tmp/kcsa-compliance/namespace.yaml' to include PSA enforcement label:"
    echo "   'pod-security.kubernetes.io/enforce: restricted'"
    echo ""
    echo "Run '$0 verify' to validate your remediation."
    echo -e "${YELLOW}======================================================================${NC}"
}

function verify_fix() {
    log_info "Running Compliance Verification Suite..."
    local errors=0

    # 1. Check API Server File Permissions (CIS 1.1.1)
    if [[ -f "${APISERVER_MANIFEST}" ]]; then
        PERMS=$(stat -c "%a" "${APISERVER_MANIFEST}")
        if [[ "${PERMS}" == "600" ]]; then
            log_success "PASS: CIS 1.1.1 - API server manifest permissions are 600."
        else
            log_error "FAIL: CIS 1.1.1 - API server manifest permissions are ${PERMS} (expected 600)."
            errors=$((errors + 1))
        fi
    else
        log_error "FAIL: API server manifest not found."
        errors=$((errors + 1))
    fi

    # 2. Check API Server Anonymous Auth Flag (CIS 1.2.1)
    if grep -q "\--anonymous-auth=false" "${APISERVER_MANIFEST}" 2>/dev/null; then
        log_success "PASS: CIS 1.2.1 - API server --anonymous-auth is set to false."
    else
        log_error "FAIL: CIS 1.2.1 - API server --anonymous-auth is not set to false."
        errors=$((errors + 1))
    fi

    # 3. Check Controller Manager Profiling Flag (CIS 1.3.2)
    if grep -q "\--profiling=false" "${CONTROLLER_MANIFEST}" 2>/dev/null; then
        log_success "PASS: CIS 1.3.2 - Controller Manager --profiling is set to false."
    else
        log_error "FAIL: CIS 1.3.2 - Controller Manager --profiling is not set to false."
        errors=$((errors + 1))
    fi

    # 4. Check Pod Security Admission Namespace Label
    if grep -q "pod-security.kubernetes.io/enforce: restricted" /tmp/kcsa-compliance/namespace.yaml 2>/dev/null; then
        log_success "PASS: NSA/CISA - Namespace 'production-workloads' includes Pod Security Admission label."
    else
        log_error "FAIL: NSA/CISA - Namespace 'production-workloads' missing 'pod-security.kubernetes.io/enforce: restricted' label."
        errors=$((errors + 1))
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        log_success "CONGRATULATIONS! All compliance audit checks have PASSED successfully."
    else
        log_error "VERIFICATION FAILED: $errors compliance violation(s) remain."
        exit 1
    fi
}

case "${1:-break}" in
    break)
        check_prereqs
        break_environment
        ;;
    status)
        show_symptoms
        ;;
    verify)
        verify_fix
        ;;
    *)
        echo "Usage: $0 {break|status|verify}"
        exit 1
        ;;
esac

# ==============================================================================
# STEP-BY-STEP SOLUTION (EXAM REFERENCE GUIDE)
# ==============================================================================
#
# STEP 1: Fix Manifest File Permissions (CIS 1.1.1)
# --------------------------------------------------
# Requirement: Control plane spec files must be owned by root:root and set to 600.
# Executed Command:
#   $ sudo chmod 600 /etc/kubernetes/manifests/kube-apiserver.yaml
#   $ sudo chown root:root /etc/kubernetes/manifests/kube-apiserver.yaml
#
# STEP 2: Configure API Server Anonymous Authentication (CIS 1.2.1)
# -----------------------------------------------------------------
# Requirement: Anonymous requests to the API server must be disabled to enforce
# authentication for all requests.
# Executed Command:
#   $ sudo sed -i 's/--anonymous-auth=true/--anonymous-auth=false/' /etc/kubernetes/manifests/kube-apiserver.yaml
#
# Expected Snippet in /etc/kubernetes/manifests/kube-apiserver.yaml:
# spec:
#   containers:
#   - command:
#     - kube-apiserver
#     - --anonymous-auth=false
#
# STEP 3: Disable Controller Manager Profiling (CIS 1.3.2)
# -------------------------------------------------------
# Requirement: Profiling exposes operational internal data via web endpoints
# and should be disabled unless actively debugging.
# Executed Command:
#   $ sudo sed -i 's/--profiling=true/--profiling=false/' /etc/kubernetes/manifests/kube-controller-manager.yaml
#
# Expected Snippet in /etc/kubernetes/manifests/kube-controller-manager.yaml:
# spec:
#   containers:
#   - command:
#     - kube-controller-manager
#     - --profiling=false
#
# STEP 4: Enforce Pod Security Admission (PSA) Labels (NSA/CISA & NIST SP 800-190)
# --------------------------------------------------------------------------------
# Requirement: Namespaces must declare security profiles to prevent privileged container executions.
# Executed Command:
#   $ cat <<EOF > /tmp/kcsa-compliance/namespace.yaml
# apiVersion: v1
# kind: Namespace
# metadata:
#   name: production-workloads
#   labels:
#     environment: production
#     pod-security.kubernetes.io/enforce: restricted
# EOF
#
# STEP 5: Verification Command
# ----------------------------
#   $ sudo ./lab.sh verify
# Output Expected:
#   [SUCCESS] PASS: CIS 1.1.1 - API server manifest permissions are 600.
#   [SUCCESS] PASS: CIS 1.2.1 - API server --anonymous-auth is set to false.
#   [SUCCESS] PASS: CIS 1.3.2 - Controller Manager --profiling is set to false.
#   [SUCCESS] PASS: NSA/CISA - Namespace 'production-workloads' includes Pod Security Admission label.
#   [SUCCESS] CONGRATULATIONS! All compliance audit checks have PASSED successfully.
# ==============================================================================