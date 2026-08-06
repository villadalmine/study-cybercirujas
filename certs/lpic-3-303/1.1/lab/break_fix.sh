#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 303 (Exam 303-300 v3.0) - Topic 1.1: Cryptography
# Break & Fix Lab: OpenSSL X.509v3 PKI Architecture & Chain Verification Failure
# Reference: https://www.lpi.org/our-certifications/lpic-3-303-overview/
# ==============================================================================
# 
# ARCHITECTURE OVERVIEW:
# In modern production SRE environments, zero-trust service mesh topologies and
# TLS mutual authentication depend on a strict X.509v3 Public Key Infrastructure.
# Certificate validation failure during TLS handshakes (`openssl verify` / 
# `openssl s_client`) often stems from subtle PKI misconfigurations:
# 1. Missing or invalid X509v3 extensions (`basicConstraints = CA:TRUE`, `keyUsage`).
# 2. Incomplete Certificate Authority chains in fullchain bundles.
# 3. Missing Subject Key Identifier (SKI) / Authority Key Identifier (AKI) linkages.
# 4. Unhashed OpenSSL trusted certificate directories (missing OpenSSL hash symlinks).
#
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/tmp/lpic3_crypto_lab"
PKI_DIR="${LAB_DIR}/pki"
TRUST_DIR="${LAB_DIR}/trusted_cas"
SERVER_DIR="${LAB_DIR}/server"

# Ensure openssl is installed
if ! command -v openssl &> /dev/null; then
    echo "[ERROR] OpenSSL utility is required for this lab." >&2
    exit 1
fi

echo "=========================================================================="
echo "  LPIC-3 303: Cryptography Break & Fix Lab Setup"
echo "  Target Topic: 1.1 Cryptography (PKI, X.509v3, OpenSSL Verification)"
echo "=========================================================================="
echo "[+] Initializing disposable lab environment at ${LAB_DIR}..."

# Clean up any existing state
rm -rf "${LAB_DIR}"
mkdir -p "${PKI_DIR}" "${TRUST_DIR}" "${SERVER_DIR}"

cd "${LAB_DIR}"

# ------------------------------------------------------------------------------
# STEP 1: Generate Root CA (Valid Configuration)
# ------------------------------------------------------------------------------
echo "[+] Generating Enterprise Root CA (RSA 4096-bit)..."

openssl genrsa -out "${PKI_DIR}/root-ca.key" 4096 2>/dev/null

cat <<'EOF' > "${PKI_DIR}/root-ca.cnf"
[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
x509_extensions     = v3_ca
prompt              = no

[ req_distinguished_name ]
C  = US
ST = California
L  = San Francisco
O  = Enterprise SRE SecOps Root Authority
CN = Enterprise Root CA v3

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
EOF

openssl req -new -x509 -days 3650 \
    -key "${PKI_DIR}/root-ca.key" \
    -out "${PKI_DIR}/root-ca.crt" \
    -config "${PKI_DIR}/root-ca.cnf" 2>/dev/null

# ------------------------------------------------------------------------------
# STEP 2: Generate Intermediate CA (INJECTED FLAW #1: Missing CA:TRUE Constraint)
# ------------------------------------------------------------------------------
echo "[+] Generating Intermediate CA Key & Signing Request..."

openssl genrsa -out "${PKI_DIR}/intermediate-ca.key" 3072 2>/dev/null

cat <<'EOF' > "${PKI_DIR}/intermediate-ca.cnf"
[ req ]
default_bits        = 3072
distinguished_name  = req_distinguished_name
prompt              = no

[ req_distinguished_name ]
C  = US
ST = California
L  = San Francisco
O  = Enterprise SRE Subordinate Services
CN = Enterprise Intermediate Issuing CA v3

[ v3_flawed_inter ]
# FLAW 1: basicConstraints is explicitly set to CA:FALSE instead of CA:TRUE
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req -new \
    -key "${PKI_DIR}/intermediate-ca.key" \
    -out "${PKI_DIR}/intermediate-ca.csr" \
    -config "${PKI_DIR}/intermediate-ca.cnf" 2>/dev/null

# Sign Intermediate CA using Root CA with the flawed extension profile
openssl x509 -req -days 1825 \
    -in "${PKI_DIR}/intermediate-ca.csr" \
    -CA "${PKI_DIR}/root-ca.crt" \
    -CAkey "${PKI_DIR}/root-ca.key" \
    -CAcreateserial \
    -out "${PKI_DIR}/intermediate-ca.crt" \
    -extfile "${PKI_DIR}/intermediate-ca.cnf" \
    -extensions v3_flawed_inter 2>/dev/null

# ------------------------------------------------------------------------------
# STEP 3: Generate Server Leaf Certificate
# ------------------------------------------------------------------------------
echo "[+] Generating Server Leaf Certificate (api.internal.net)..."

openssl genrsa -out "${SERVER_DIR}/server.key" 2048 2>/dev/null

cat <<'EOF' > "${SERVER_DIR}/server.cnf"
[ req ]
default_bits        = 2048
distinguished_name  = req_dn
req_extensions      = v3_req
prompt              = no

[ req_dn ]
C  = US
O  = SRE Infrastructure Team
CN = api.internal.net

[ v3_req ]
basicConstraints     = CA:FALSE
keyUsage             = critical, digitalSignature, keyEncipherment
extendedKeyUsage     = serverAuth, clientAuth
subjectAltName       = @alt_names

[ alt_names ]
DNS.1 = api.internal.net
DNS.2 = *.api.internal.net
EOF

openssl req -new \
    -key "${SERVER_DIR}/server.key" \
    -out "${SERVER_DIR}/server.csr" \
    -config "${SERVER_DIR}/server.cnf" 2>/dev/null

# Sign Server Certificate using Intermediate CA
openssl x509 -req -days 365 \
    -in "${SERVER_DIR}/server.csr" \
    -CA "${PKI_DIR}/intermediate-ca.crt" \
    -CAkey "${PKI_DIR}/intermediate-ca.key" \
    -CAcreateserial \
    -out "${SERVER_DIR}/server.crt" \
    -extfile "${SERVER_DIR}/server.cnf" \
    -extensions v3_req 2>/dev/null

# ------------------------------------------------------------------------------
# STEP 4: Setup Incomplete Server Fullchain & Unhashed Trust Directory (FLAWS #2 & #3)
# ------------------------------------------------------------------------------
# FLAW 2: Server fullchain only contains the leaf cert, omitting the Intermediate CA
cp "${SERVER_DIR}/server.crt" "${SERVER_DIR}/fullchain.pem"

# FLAW 3: Root CA copied to trusted directory, but hashed symlinks (openssl rehash / c_rehash) were omitted
cp "${PKI_DIR}/root-ca.crt" "${TRUST_DIR}/root-ca.crt"

echo "[+] Lab setup complete."
echo ""
cat << 'EOF'
==============================================================================
               LAB TROUBLESHOOTING INSTRUCTIONS & SYMPTOMS
==============================================================================

SCENARIO:
You are an SRE on-call engineer. An automated microservice deployment failed
validation when establishing TLS connections to `api.internal.net`. The security
auditor reports that certificate path validation fails, preventing the deployment.

YOUR LOCATION:
All lab files have been staged in: /var/tmp/lpic3_crypto_lab

SYMPTOMS OBSERVED:
1. When validating the service certificate chain against the Root CA:
   $ openssl verify -CAfile /var/tmp/lpic3_crypto_lab/pki/root-ca.crt \
     -untrusted /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt \
     /var/tmp/lpic3_crypto_lab/server/server.crt

   OUTPUT / ERROR:
   C = US, ST = California, L = San Francisco, O = Enterprise SRE Subordinate Services, CN = Enterprise Intermediate Issuing CA v3
   error 24 at 1 depth lookup: invalid CA certificate
   error /var/tmp/lpic3_crypto_lab/server/server.crt: verification failed

2. When attempting directory-based trust lookup using OpenSSL trust directory:
   $ openssl verify -CApath /var/tmp/lpic3_crypto_lab/trusted_cas \
     /var/tmp/lpic3_crypto_lab/server/fullchain.pem

   OUTPUT / ERROR:
   error /var/tmp/lpic3_crypto_lab/server/fullchain.pem: verification failed
   unable to get local issuer certificate

YOUR OBJECTIVE:
1. Diagnose why `intermediate-ca.crt` is marked as an "invalid CA certificate" by
   inspecting its X.509v3 structure and re-issue a valid Intermediate CA certificate.
2. Re-sign `server.crt` using the fixed Intermediate CA.
3. Build a proper `fullchain.pem` bundle containing both the leaf certificate and
   the Intermediate CA certificate.
4. Prepare the `/var/tmp/lpic3_crypto_lab/trusted_cas` directory using the standard
   OpenSSL hash utility so `-CApath` verification succeeds.
5. Confirm success when running BOTH verification commands clean with return code 0:
   
   Command A:
   openssl verify -CAfile /var/tmp/lpic3_crypto_lab/pki/root-ca.crt \
     -untrusted /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt \
     /var/tmp/lpic3_crypto_lab/server/server.crt
   Expected output: /var/tmp/lpic3_crypto_lab/server/server.crt: OK

   Command B:
   openssl verify -CApath /var/tmp/lpic3_crypto_lab/trusted_cas \
     /var/tmp/lpic3_crypto_lab/server/fullchain.pem
   Expected output: /var/tmp/lpic3_crypto_lab/server/fullchain.pem: OK

==============================================================================
EOF

exit 0

# ==============================================================================
#                               STEP-BY-STEP SOLUTION
# ==============================================================================
# To fix this lab manually, run the following commands step-by-step:
#
# --- STEP 1: Inspect the Broken Intermediate CA Certificate ---
# Analyze X509v3 Extensions of intermediate-ca.crt to identify why error 24 occurred:
#   openssl x509 -in /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt -text -noout
# 
# Notice under "X509v3 extensions":
#   X509v3 Basic Constraints: critical
#       CA:FALSE    <-- ROOT CAUSE OF ERROR 24 ("invalid CA certificate")
#
# --- STEP 2: Create a Valid Intermediate CA OpenSSL Configuration ---
# Create an updated configuration file with `basicConstraints = critical, CA:TRUE, pathlen:0`
# and `keyUsage = critical, digitalSignature, cRLSign, keyCertSign`:
#
# cat <<'EOF' > /var/tmp/lpic3_crypto_lab/pki/intermediate-ca-fixed.cnf
# [ req ]
# default_bits        = 3072
# distinguished_name  = req_distinguished_name
# prompt              = no
# 
# [ req_distinguished_name ]
# C  = US
# ST = California
# L  = San Francisco
# O  = Enterprise SRE Subordinate Services
# CN = Enterprise Intermediate Issuing CA v3
# 
# [ v3_intermediate_ca ]
# subjectKeyIdentifier   = hash
# authorityKeyIdentifier = keyid:always,issuer
# basicConstraints       = critical, CA:TRUE, pathlen:0
# keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
# EOF
#
# --- STEP 3: Re-sign the Intermediate CA Certificate ---
# Use the Root CA key to issue a new intermediate-ca.crt with the correct extensions:
#   openssl x509 -req -days 1825 \
#     -in /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.csr \
#     -CA /var/tmp/lpic3_crypto_lab/pki/root-ca.crt \
#     -CAkey /var/tmp/lpic3_crypto_lab/pki/root-ca.key \
#     -CAcreateserial \
#     -out /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt \
#     -extfile /var/tmp/lpic3_crypto_lab/pki/intermediate-ca-fixed.cnf \
#     -extensions v3_intermediate_ca
#
# --- STEP 4: Re-sign the Leaf Server Certificate ---
# Sign the server CSR with the updated Intermediate CA:
#   openssl x509 -req -days 365 \
#     -in /var/tmp/lpic3_crypto_lab/server/server.csr \
#     -CA /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt \
#     -CAkey /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.key \
#     -CAcreateserial \
#     -out /var/tmp/lpic3_crypto_lab/server/server.crt \
#     -extfile /var/tmp/lpic3_crypto_lab/server/server.cnf \
#     -extensions v3_req
#
# --- STEP 5: Construct the Full Certificate Chain (Fullchain Bundle) ---
# In production (Nginx/HAProxy/Envoy), the server must present its leaf cert AND
# all intermediate CAs up to (but optional) the root CA:
#   cat /var/tmp/lpic3_crypto_lab/server/server.crt \
#       /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt \
#       > /var/tmp/lpic3_crypto_lab/server/fullchain.pem
#
# --- STEP 6: Generate Hashed Symlinks for Trust Directory (-CApath) ---
# Also copy the Intermediate CA into the trust directory, then run openssl rehash / c_rehash:
#   cp /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt /var/tmp/lpic3_crypto_lab/trusted_cas/
#   openssl rehash /var/tmp/lpic3_crypto_lab/trusted_cas
#   (or `c_rehash /var/tmp/lpic3_crypto_lab/trusted_cas` on older distributions)
#
# Verify that subject hash symlinks (e.g. `a1b2c3d4.0`) are created in trusted_cas:
#   ls -la /var/tmp/lpic3_crypto_lab/trusted_cas
#
# --- STEP 7: Final Verification Commands ---
# Verify explicit chain validation:
#   openssl verify -CAfile /var/tmp/lpic3_crypto_lab/pki/root-ca.crt \
#     -untrusted /var/tmp/lpic3_crypto_lab/pki/intermediate-ca.crt \
#     /var/tmp/lpic3_crypto_lab/server/server.crt
#
# Verify CApath hash directory validation against fullchain:
#   openssl verify -CApath /var/tmp/lpic3_crypto_lab/trusted_cas \
#     /var/tmp/lpic3_crypto_lab/server/fullchain.pem
#
# Both commands will now return `: OK`.
# ==============================================================================