#!/usr/bin/env bash
# ==============================================================================
# KCSA (Kubernetes and Cloud Native Security Associate) Certification Lab
# Topic 5.5: Public Key Infrastructure (PKI) Architecture & Maintenance
# Exam Weight: 2.29%
# Official Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# Kubernetes PKI Spec: https://kubernetes.io/docs/setup/best-practices/certificates/
# ==============================================================================
# 
# ARCHITECTURAL DEEP-DIVE & INTERNAL MECHANICS:
# ---------------------------------------------
# Kubernetes relies heavily on X.509 Public Key Infrastructure (PKI) for mTLS
# authentication and authorization between control plane components, nodes, and
# administrative clients. A standard HA cluster manages up to 5 distinct CAs:
#
# 1. Cluster Root CA: Authenticates API server, kubelets, controller-manager, scheduler.
#    - CN in certs maps to User ID (e.g., CN=system:node:worker-1).
#    - O in certs maps to RBAC Groups (e.g., O=system:nodes).
# 2. Etcd Root CA: Secures peer-to-peer etcd communication and API-to-etcd client traffic.
# 3. Front-Proxy CA: Authenticates requests passing through API extension servers (Aggregated APIs).
# 4. Service Account Key Pair: RSA/ECDSA key pair used by API server to sign SA JWT tokens.
# 5. Kubelet Serving/Client CAs: Manages TLS certificates for node-level endpoints.
#
# PKI CRITICAL FAILURES IN PRODUCTION:
# - Extended Key Usage (EKU) Mismatches: Certificates missing `clientAuth` (1.3.6.1.5.5.7.3.2)
#   or `serverAuth` (1.3.6.1.5.5.7.3.1).
# - Missing SANs: API Server certificates lacking Subject Alternative Names for internal 
#   cluster IPs (10.96.0.1), hostname, or `kubernetes.default.svc.cluster.local`.
# - CA Chain Breaking: Clients presented with certificates signed by an untrusted intermediate
#   or mismatched CA bundle.
#
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/kcsa-pki-lab"
COLOR_RESET="\033[0m"
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_BLUE="\033[1;34m"
COLOR_CYAN="\033[1;36m"

log_info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"; }
log_err() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"; }

check_prerequisites() {
    log_info "Checking local tooling requirements..."
    command -v openssl >/dev/null 2>&1 || { log_err "openssl is required but not installed. Aborting."; exit 1; }
    command -v base64 >/dev/null 2>&1 || { log_err "base64 is required but not installed. Aborting."; exit 1; }
    log_success "Prerequisites verified."
}

setup_lab_environment() {
    log_info "Initializing temporary PKI lab workspace at ${LAB_DIR}..."
    rm -rf "${LAB_DIR}"
    mkdir -p "${LAB_DIR}"/{cluster-ca,rogue-ca,server,client,kubeconfig}
}

inject_pki_faults() {
    log_info "Generating Cluster Root CA (Legitimate)..."
    openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
        -keyout "${LAB_DIR}/cluster-ca/ca.key" \
        -out "${LAB_DIR}/cluster-ca/ca.crt" \
        -subj "/CN=kubernetes-ca/O=Kubernetes" >/dev/null 2>&1

    log_info "Generating Rogue Root CA (Mismatched Authority)..."
    openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
        -keyout "${LAB_DIR}/rogue-ca/rogue-ca.key" \
        -out "${LAB_DIR}/rogue-ca/rogue-ca.crt" \
        -subj "/CN=untrusted-untrusted-ca/O=Rogue-Corp" >/dev/null 2>&1

    log_info "Generating API Server TLS Private Key & CSR..."
    openssl req -newkey rsa:2048 -nodes \
        -keyout "${LAB_DIR}/server/apiserver.key" \
        -out "${LAB_DIR}/server/apiserver.csr" \
        -subj "/CN=kube-apiserver" >/dev/null 2>&1

    log_warn "INJECTING FAULT 1: Signing API Server cert WITHOUT required SANs (Subject Alternative Names)..."
    openssl x509 -req -in "${LAB_DIR}/server/apiserver.csr" \
        -CA "${LAB_DIR}/cluster-ca/ca.crt" \
        -CAkey "${LAB_DIR}/cluster-ca/ca.key" \
        -CAcreateserial \
        -out "${LAB_DIR}/server/apiserver.crt" \
        -days 365 >/dev/null 2>&1

    log_info "Generating Auditor Client Private Key & CSR (CN=security-auditor, O=system:masters)..."
    openssl req -newkey rsa:2048 -nodes \
        -keyout "${LAB_DIR}/client/auditor.key" \
        -out "${LAB_DIR}/client/auditor.csr" \
        -subj "/CN=security-auditor/O=system:masters" >/dev/null 2>&1

    log_warn "INJECTING FAULT 2: Signing client cert with ROGUE CA instead of Cluster CA..."
    openssl x509 -req -in "${LAB_DIR}/client/auditor.csr" \
        -CA "${LAB_DIR}/rogue-ca/rogue-ca.crt" \
        -CAkey "${LAB_DIR}/rogue-ca/rogue-ca.key" \
        -CAcreateserial \
        -out "${LAB_DIR}/client/auditor.crt" \
        -days 365 >/dev/null 2>&1

    log_warn "INJECTING FAULT 3: Building Kubeconfig with mismatched CA bundle & invalid client cert..."
    CA_BASE64=$(base64 -w 0 < "${LAB_DIR}/cluster-ca/ca.crt")
    CLIENT_CERT_BASE64=$(base64 -w 0 < "${LAB_DIR}/client/auditor.crt")
    CLIENT_KEY_BASE64=$(base64 -w 0 < "${LAB_DIR}/client/auditor.key")

    cat <<EOF > "${LAB_DIR}/kubeconfig/auditor.kubeconfig"
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_BASE64}
    server: https://127.0.0.1:6443
  name: broken-pki-cluster
contexts:
- context:
    cluster: broken-pki-cluster
    user: security-auditor
  name: auditor-context
current-context: auditor-context
users:
- name: security-auditor
  user:
    client-certificate-data: ${CLIENT_CERT_BASE64}
    client-key-data: ${CLIENT_KEY_BASE64}
EOF

    log_success "Fault injection completed successfully."
}

print_student_instructions() {
    echo -e "\n${COLOR_CYAN}==============================================================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN}                    BREAK & FIX LAB: PKI INCIDENT SCENARIO                   ${COLOR_RESET}"
    echo -e "${COLOR_CYAN}==============================================================================${COLOR_RESET}\n"

    echo -e "An SRE intern attempted to issue new credentials for a Security Auditor and reconfigure"
    echo -e "the API Server TLS configuration. Production client authentication is completely failing,"
    echo -e "and TLS connections to the API Server are throwing untrusted authority and SAN errors.\n"

    echo -e "${COLOR_YELLOW}LAB SYMPTOMS & VERIFICATION COMMANDS:${COLOR_RESET}"
    echo -e "------------------------------------------------------------------------------"
    echo -e "1. Run OpenSSL verification on the client certificate against the Cluster CA:"
    echo -e "   ${COLOR_GREEN}openssl verify -CAfile ${LAB_DIR}/cluster-ca/ca.crt ${LAB_DIR}/client/auditor.crt${COLOR_RESET}"
    echo -e "   ${COLOR_RED}Expected Symptom:${COLOR_RESET} error 20 at 0 depth lookup: unable to get local issuer certificate\n"

    echo -e "2. Inspect the API Server Certificate Subject Alternative Names (SAN):"
    echo -e "   ${COLOR_GREEN}openssl x509 -in ${LAB_DIR}/server/apiserver.crt -text -noout | grep -A1 'Subject Alternative Name'${COLOR_RESET}"
    echo -e "   ${COLOR_RED}Expected Symptom:${COLOR_RESET} No SAN extension found! Connections via IP 127.0.0.1 or domain"
    echo -e "   kubernetes.default.svc will be rejected by clients with 'x509: certificate is valid for ..., not 127.0.0.1'\n"

    echo -e "3. Test verification against simulated API server endpoint configuration:"
    echo -e "   ${COLOR_GREEN}openssl verify -CAfile ${LAB_DIR}/cluster-ca/ca.crt ${LAB_DIR}/server/apiserver.crt${COLOR_RESET}"
    echo -e "   (Notice CA verification succeeds, but hostname verification fails due to missing SANs)\n"

    echo -e "${COLOR_YELLOW}STUDENT OBJECTIVE:${COLOR_RESET}"
    echo -e "------------------------------------------------------------------------------"
    echo -e "Fix the broken PKI artifacts in '${LAB_DIR}' so that:"
    echo -e "  A. The API server certificate ('${LAB_DIR}/server/apiserver.crt') includes valid SANs:"
    echo -e "     - IP: 127.0.0.1, IP: 10.96.0.1"
    echo -e "     - DNS: kubernetes, DNS: kubernetes.default, DNS: kubernetes.default.svc.cluster.local"
    echo -e "     - Extended Key Usage: TLS Web Server Authentication (1.3.6.1.5.5.7.3.1)"
    echo -e "  B. The client certificate ('${LAB_DIR}/client/auditor.crt') is correctly re-signed by"
    echo -e "     the Cluster Root CA ('${LAB_DIR}/cluster-ca/ca.crt') with Extended Key Usage:"
    echo -e "     - TLS Web Client Authentication (1.3.6.1.5.5.7.3.2)"
    echo -e "     - Subject: CN=security-auditor, O=system:masters"
    echo -e "  C. The Kubeconfig ('${LAB_DIR}/kubeconfig/auditor.kubeconfig') is updated with the"
    echo -e "     newly signed, valid Base64 client certificate.\n"

    echo -e "${COLOR_CYAN}Scroll to the bottom of this script file to view the commented step-by-step solution.${COLOR_RESET}\n"
}

main() {
    check_prerequisites
    setup_lab_environment
    inject_pki_faults
    print_student_instructions
}

main "$@"

# ==============================================================================
#                             STEP-BY-STEP SOLUTION
# ==============================================================================
#
# STEP 1: Fix the API Server Certificate (Add SANs and Server EKU)
# ------------------------------------------------------------------------------
# Create an OpenSSL extension configuration file for the server certificate:
#
# cat <<EOF > /tmp/kcsa-pki-lab/server/openssl-san.cnf
# [ req ]
# default_bits       = 2048
# dist_name          = req_distinguished_name
# req_extensions     = v3_req
# prompt             = no
# 
# [ req_distinguished_name ]
# CN = kube-apiserver
# 
# [ v3_req ]
# basicConstraints = CA:FALSE
# keyUsage = nonRepudiation, digitalSignature, keyEncipherment
# extendedKeyUsage = serverAuth
# subjectAltName = @alt_names
# 
# [ alt_names ]
# DNS.1 = kubernetes
# DNS.2 = kubernetes.default
# DNS.3 = kubernetes.default.svc
# DNS.4 = kubernetes.default.svc.cluster.local
# IP.1  = 127.0.0.1
# IP.2  = 10.96.0.1
# EOF
#
# Re-sign the server CSR using the legitimate Cluster Root CA and extension config:
#
# openssl x509 -req \
#     -in /tmp/kcsa-pki-lab/server/apiserver.csr \
#     -CA /tmp/kcsa-pki-lab/cluster-ca/ca.crt \
#     -CAkey /tmp/kcsa-pki-lab/cluster-ca/ca.key \
#     -CAcreateserial \
#     -out /tmp/kcsa-pki-lab/server/apiserver.crt \
#     -days 365 \
#     -extfile /tmp/kcsa-pki-lab/server/openssl-san.cnf \
#     -extensions v3_req
#
# Verify SAN injection:
# openssl x509 -in /tmp/kcsa-pki-lab/server/apiserver.crt -text -noout | grep -A2 "Subject Alternative Name"
#
# STEP 2: Fix the Client Certificate (Sign with Cluster CA and add Client EKU)
# ------------------------------------------------------------------------------
# Create an OpenSSL extension configuration file for the client certificate:
#
# cat <<EOF > /tmp/kcsa-pki-lab/client/openssl-client.cnf
# [ v3_client ]
# basicConstraints = CA:FALSE
# keyUsage = digitalSignature, keyEncipherment
# extendedKeyUsage = clientAuth
# EOF
#
# Re-sign the auditor CSR using the legitimate Cluster Root CA (NOT Rogue CA):
#
# openssl x509 -req \
#     -in /tmp/kcsa-pki-lab/client/auditor.csr \
#     -CA /tmp/kcsa-pki-lab/cluster-ca/ca.crt \
#     -CAkey /tmp/kcsa-pki-lab/cluster-ca/ca.key \
#     -CAcreateserial \
#     -out /tmp/kcsa-pki-lab/client/auditor.crt \
#     -days 365 \
#     -extfile /tmp/kcsa-pki-lab/client/openssl-client.cnf \
#     -extensions v3_client
#
# Verify Client Certificate Trust Chain against Cluster Root CA:
# openssl verify -CAfile /tmp/kcsa-pki-lab/cluster-ca/ca.crt /tmp/kcsa-pki-lab/client/auditor.crt
# (Expected Output: /tmp/kcsa-pki-lab/client/auditor.crt: OK)
#
# STEP 3: Update the Kubeconfig File
# ------------------------------------------------------------------------------
# Encode the newly signed client certificate in Base64:
# NEW_CERT_BASE64=$(base64 -w 0 < /tmp/kcsa-pki-lab/client/auditor.crt)
#
# Update the client-certificate-data field in auditor.kubeconfig:
# sed -i "s|client-certificate-data:.*|client-certificate-data: ${NEW_CERT_BASE64}|" /tmp/kcsa-pki-lab/kubeconfig/auditor.kubeconfig
#
# Verify updated kubeconfig structure:
# kubectl config view --kubeconfig=/tmp/kcsa-pki-lab/kubeconfig/auditor.kubeconfig --raw
#
# ==============================================================================