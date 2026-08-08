#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes & Cloud Native Security Associate) Exam Prep
# Topic 2.10: Client Security (Exam Weight: 2.0%)
# Lab Type: Production-Grade "Break & Fix" Hands-on Challenge
#
# References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - K8s Authenticating: https://kubernetes.io/docs/reference/access-authn-authz/authentication/
# - Kubeconfig Security: https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
# - TLS Client Certs: https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
# ==============================================================================
#
# ARCHITECTURAL BACKGROUND & DEEP TECHNICAL MECHANICS:
#
# Kubernetes Client Security relies on multi-layered verification:
# 1. Transport Layer Security (TLS) Mutual Authentication (mTLS):
#    - The client verifies the kube-apiserver using a trusted Certificate Authority (CA).
#    - Disabling TLS verification (`insecure-skip-tls-verify: true`) exposes the client to
#      Man-in-the-Middle (MitM) credential interception and token spoofing.
# 2. X.509 Certificate Subject Attribute Extraction:
#    - kube-apiserver extracts Subject attributes: Common Name (CN) -> User Name, 
#      Organization (O) -> Group Membership.
#    - RBAC authorization evaluates these extracted values against RoleBindings / ClusterRoleBindings.
#    - If `O` does not match the RBAC `subjects[].name` (for group bindings), requests return 403 Forbidden.
# 3. Kubeconfig File Permission & Credential Isolation:
#    - Kubeconfig files contain private keys, bearer tokens, or exec auth credentials.
#    - World/group readable kubeconfigs (`0644` or `0666`) leak administrative credentials
#      to unauthorized local users/processes. Standard hardening requires mode `0600` (`-rw-------`).
#
# TRADE-OFFS:
# - X.509 Client Certificates: Simple, native, zero external dependencies.
#   Trade-off: Hard to revoke before expiration (no native CRL/OCSP in kube-apiserver).
# - Exec Auth / OIDC Plugins: Dynamic token retrieval with centralized identity (IdP) & MFA support.
#   Trade-off: Requires external binary dependencies and network access to IdP endpoints.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/kcsa-client-security-lab"
KUBECONFIG_PATH="${LAB_DIR}/kubeconfig"
CA_KEY="${LAB_DIR}/ca.key"
CA_CERT="${LAB_DIR}/ca.crt"
USER_KEY="${LAB_DIR}/auditor.key"
USER_CSR="${LAB_DIR}/auditor.csr"
USER_CERT="${LAB_DIR}/auditor.crt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo -e "${BLUE}Usage:${NC} $0 {break|verify|cleanup}"
    echo "  break   : Injects security flaws into client config and environment"
    echo "  verify  : Checks if all security flaws have been properly remediated"
    echo "  cleanup : Removes lab artifacts and restores temporary resources"
    exit 1
}

check_prerequisites() {
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}ERROR: openssl is required but not installed.${NC}"
        exit 1
    fi
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl is required but not installed.${NC}"
        exit 1
    fi
}

inject_breakage() {
    echo -e "${YELLOW}[+] Setting up Client Security Break & Fix Scenario...${NC}"
    mkdir -p "${LAB_DIR}"

    # 1. Generate local dummy Root CA
    openssl genrsa -out "${CA_KEY}" 2048 &>/dev/null
    openssl req -x509 -new -nodes -key "${CA_KEY}" -subj "/CN=KCSA-Lab-CA" -days 1 -out "${CA_CERT}" &>/dev/null

    # 2. BREAKAGE 1: Generate Client Certificate with WRONG Organization (O)
    # Target RBAC expects Group: 'security-auditors'
    # Flaw: We set O='dev-auditors' (Causes RBAC 403 Forbidden)
    openssl genrsa -out "${USER_KEY}" 2048 &>/dev/null
    openssl req -new -key "${USER_KEY}" -subj "/CN=sec-auditor-user/O=dev-auditors" -out "${USER_CSR}" &>/dev/null
    openssl x509 -req -in "${USER_CSR}" -CA "${CA_CERT}" -CAkey "${CA_KEY}" -CAcreateserial -out "${USER_CERT}" -days 1 &>/dev/null

    # Encode credentials for kubeconfig insertion
    CA_DATA_BASE64=$(base64 -w 0 < "${CA_CERT}")
    CLIENT_CERT_BASE64=$(base64 -w 0 < "${USER_CERT}")
    CLIENT_KEY_BASE64=$(base64 -w 0 < "${USER_KEY}")

    # 3. BREAKAGE 2: Kubeconfig with insecure-skip-tls-verify=true (Security vulnerability)
    # 4. BREAKAGE 3: Kubeconfig file permissions set to 0666 (Overly permissive / Credential leak)
    cat <<EOF > "${KUBECONFIG_PATH}"
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://127.0.0.1:6443
  name: kcsa-secure-cluster
contexts:
- context:
    cluster: kcsa-secure-cluster
    user: sec-auditor-user
  name: sec-auditor-context
current-context: sec-auditor-context
users:
- name: sec-auditor-user
  user:
    client-certificate-data: ${CLIENT_CERT_BASE64}
    client-key-data: ${CLIENT_KEY_BASE64}
EOF

    # Flaw: Set file permission to 0666
    chmod 0666 "${KUBECONFIG_PATH}"

    # 5. Apply mock RBAC manifest (Syntactically valid Kubernetes Manifests)
    cat <<'EOF_RBAC' > "${LAB_DIR}/rbac-manifests.yaml"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kcsa-security-auditor-role
rules:
- apiGroups: [""]
  resources: ["pods", "namespaces", "configmaps"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kcsa-security-auditor-binding
subjects:
- kind: Group
  name: security-auditors
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: kcsa-security-auditor-role
  apiGroup: rbac.authorization.k8s.io
EOF_RBAC

    if kubectl cluster-info &>/dev/null; then
        kubectl apply -f "${LAB_DIR}/rbac-manifests.yaml" &>/dev/null || true
    fi

    echo -e "${RED}[!] SCENARIO BROKEN SUCCESSFULLY.${NC}\n"
    print_challenge
}

print_challenge() {
    cat <<EOF
================================================================================
KCSA 2.10 CLIENT SECURITY - LAB CHALLENGE
================================================================================
PROBLEM STATEMENT:
A junior engineer generated a custom kubeconfig file at:
  ${KUBECONFIG_PATH}

However, the configuration fails compliance audits and client authentication tests.

SYMPTOMS OBSERVED:
1. Security audit tools flag the kubeconfig file for dangerous filesystem permissions.
2. The kubeconfig context bypasses TLS verification (insecure-skip-tls-verify),
   exposing client API traffic to Man-in-the-Middle (MitM) attacks.
3. Authenticated requests using this kubeconfig fail with:
   "Error from server (Forbidden): User 'sec-auditor-user' cannot list resource..."
   because the client X.509 certificate Organization attribute does not match 
   the RBAC Group binding ('security-auditors').

OBJECTIVES TO COMPLETE:
1. Fix filesystem permissions on '${KUBECONFIG_PATH}' to conform to standard 
   credential storage security (Owner Read/Write ONLY - mode 0600).
2. Harden TLS Client Security in '${KUBECONFIG_PATH}':
   - Remove 'insecure-skip-tls-verify: true'.
   - Embed the trusted CA certificate using 'certificate-authority-data' 
     (CA cert file located at: ${CA_CERT}).
3. Re-issue the Client Certificate '${USER_CERT}':
   - Keep Common Name (CN): 'sec-auditor-user'.
   - Fix Organization (O): 'security-auditors'.
   - Update 'client-certificate-data' inside '${KUBECONFIG_PATH}' with the 
     corrected certificate.

VERIFICATION:
Run: $0 verify
================================================================================
EOF
}

verify_fix() {
    echo -e "${YELLOW}[*] Verifying Client Security Remediations...${NC}"
    local ERRORS=0

    # 1. Verify File Permissions (Must be 0600 or 0400)
    PERMS=$(stat -c "%a" "${KUBECONFIG_PATH}" 2>/dev/null || stat -f "%Lp" "${KUBECONFIG_PATH}" 2>/dev/null)
    if [[ "${PERMS}" != "600" && "${PERMS}" != "400" ]]; then
        echo -e "${RED}[FAIL] Kubeconfig permissions are ${PERMS}. Expected: 0600 or 0400.${NC}"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}[PASS] Kubeconfig file permissions are properly hardened (${PERMS}).${NC}"
    fi

    # 2. Verify TLS Configuration (No insecure-skip-tls-verify, MUST have certificate-authority-data or certificate-authority)
    if grep -q "insecure-skip-tls-verify: true" "${KUBECONFIG_PATH}"; then
        echo -e "${RED}[FAIL] TLS security flaw present: 'insecure-skip-tls-verify: true' found in kubeconfig.${NC}"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}[PASS] 'insecure-skip-tls-verify: true' has been removed.${NC}"
    fi

    if ! grep -q "certificate-authority-data" "${KUBECONFIG_PATH}" && ! grep -q "certificate-authority:" "${KUBECONFIG_PATH}"; then
        echo -e "${RED}[FAIL] Kubeconfig is missing 'certificate-authority-data' or 'certificate-authority'.${NC}"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}[PASS] Trusted CA configuration detected in kubeconfig.${NC}"
    fi

    # 3. Verify Certificate Organization (O) attribute
    EXTRACTED_CERT_B64=$(grep "client-certificate-data:" "${KUBECONFIG_PATH}" | awk '{print $2}')
    if [[ -z "${EXTRACTED_CERT_B64}" ]]; then
        echo -e "${RED}[FAIL] Could not locate 'client-certificate-data' in kubeconfig.${NC}"
        ERRORS=$((ERRORS + 1))
    else
        CERT_SUBJECT=$(echo "${EXTRACTED_CERT_B64}" | base64 -d | openssl x509 -noout -subject 2>/dev/null || true)
        if echo "${CERT_SUBJECT}" | grep -q "O = security-auditors" || echo "${CERT_SUBJECT}" | grep -q "O=security-auditors"; then
            echo -e "${GREEN}[PASS] Client Certificate Subject Organization correctly set to 'security-auditors'.${NC}"
        else
            echo -e "${RED}[FAIL] Client Certificate Subject invalid: ${CERT_SUBJECT}. Expected Organization 'O=security-auditors'.${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    if [[ ${ERRORS} -eq 0 ]]; then
        echo -e "\n${GREEN}================================================================${NC}"
        echo -e "${GREEN} CONGRATULATIONS! ALL KCSA CLIENT SECURITY CHECKS PASSED SUCCESSFULLY. ${NC}"
        echo -e "${GREEN}================================================================${NC}"
    else
        echo -e "\n${RED}[!] Verification failed with ${ERRORS} error(s). Review challenge requirements.${NC}"
        exit 1
    fi
}

cleanup() {
    echo -e "${YELLOW}[+] Cleaning up lab directory...${NC}"
    if kubectl cluster-info &>/dev/null; then
        kubectl delete -f "${LAB_DIR}/rbac-manifests.yaml" &>/dev/null || true
    fi
    rm -rf "${LAB_DIR}"
    echo -e "${GREEN}[+] Cleanup complete.${NC}"
}

# Main Execution Flow
check_prerequisites

case "${1:-}" in
    break)
        inject_breakage
        ;;
    verify)
        verify_fix
        ;;
    cleanup)
        cleanup
        ;;
    *)
        usage
        ;;
esac

# ==============================================================================
# STEP-BY-STEP SOLUTION (STUDENT REFERENCE & REMEDIATION GUIDE)
# ==============================================================================
#
# STEP 1: FIX KUBECONFIG FILE PERMISSIONS
# Kubeconfigs contain private cryptographic keys and must be restricted to user-only access.
# Command:
#   chmod 0600 /tmp/kcsa-client-security-lab/kubeconfig
# Expected output check:
#   ls -la /tmp/kcsa-client-security-lab/kubeconfig
#   -rw------- 1 user group 1850 Aug 7 19:00 /tmp/kcsa-client-security-lab/kubeconfig
#
# STEP 2: RE-ISSUE CLIENT CERTIFICATE WITH CORRECT ORGANIZATIONAL ATTRIBUTE (O)
# The RBAC ClusterRoleBinding 'kcsa-security-auditor-binding' maps the group 'security-auditors'.
# In X.509 client certificates, 'O' (Organization) maps to Kubernetes User Groups.
#
# 2.1 Generate new CSR with correct CN and O:
#   openssl req -new -key /tmp/kcsa-client-security-lab/auditor.key \
#     -subj "/CN=sec-auditor-user/O=security-auditors" \
#     -out /tmp/kcsa-client-security-lab/auditor_fixed.csr
#
# 2.2 Sign the CSR using the lab CA key and certificate:
#   openssl x509 -req -in /tmp/kcsa-client-security-lab/auditor_fixed.csr \
#     -CA /tmp/kcsa-client-security-lab/ca.crt \
#     -CAkey /tmp/kcsa-client-security-lab/ca.key \
#     -CAcreateserial \
#     -out /tmp/kcsa-client-security-lab/auditor_fixed.crt \
#     -days 1
#
# 2.3 Verify the certificate subject details:
#   openssl x509 -in /tmp/kcsa-client-security-lab/auditor_fixed.crt -noout -subject
#   Expected Output: subject=CN = sec-auditor-user, O = security-auditors
#
# STEP 3: UPDATE KUBECONFIG WITH TRUSTED CA DATA AND FIXED CLIENT CERTIFICATE
#
# 3.1 Base64 encode the CA certificate and fixed client certificate:
#   CA_B64=$(base64 -w 0 < /tmp/kcsa-client-security-lab/ca.crt)
#   CLIENT_CERT_B64=$(base64 -w 0 < /tmp/kcsa-client-security-lab/auditor_fixed.crt)
#
# 3.2 Update Kubeconfig:
#   - Remove: 'insecure-skip-tls-verify: true'
#   - Add under cluster: 'certificate-authority-data: <CA_B64>'
#   - Update under user: 'client-certificate-data: <CLIENT_CERT_B64>'
#
# CLI Command using kubectl config:
#   kubectl config --kubeconfig=/tmp/kcsa-client-security-lab/kubeconfig \
#     set-cluster kcsa-secure-cluster \
#     --certificate-authority-data="${CA_B64}" \
#     --embed-certs=true
#
#   kubectl config --kubeconfig=/tmp/kcsa-client-security-lab/kubeconfig \
#     unset clusters.kcsa-secure-cluster.insecure-skip-tls-verify
#
#   kubectl config --kubeconfig=/tmp/kcsa-client-security-lab/kubeconfig \
#     set-credentials sec-auditor-user \
#     --client-certificate-data="${CLIENT_CERT_B64}" \
#     --embed-certs=true
#
# STEP 4: RUN VERIFICATION
#   ./break-fix-client-security.sh verify
#   Expected Output:
#     [PASS] Kubeconfig file permissions are properly hardened (600).
#     [PASS] 'insecure-skip-tls-verify: true' has been removed.
#     [PASS] Trusted CA configuration detected in kubeconfig.
#     [PASS] Client Certificate Subject Organization correctly set to 'security-auditors'.
#     CONGRATULATIONS! ALL KCSA CLIENT SECURITY CHECKS PASSED SUCCESSFULLY.
# ==============================================================================