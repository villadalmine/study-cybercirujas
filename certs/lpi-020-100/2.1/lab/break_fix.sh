#!/bin/bash
# ==============================================================================
# LPI 020-100 (Security Essentials v1.0) - Topic 2.1: Encryption (Weight: 20)
# Break & Fix Hands-On Laboratory Environment
#
# Official Reference: https://www.lpi.org/our-certifications/security-essentials-overview/
# Role: Senior SRE & Platform Architect Instructor
# Target Audience: CNCF / SRE / Security Engineers preparing for LPI-020-100
# ==============================================================================
#
# SCENARIO DESCRIPTION:
# An automated deployment pipeline and secure backup system in a production-like
# environment failed following an emergency maintenance window.
#
# The architecture relies on two critical encryption components:
#   1. TLS Infrastructure (OpenSSL): Secure API endpoint certificates.
#   2. Data-at-Rest Protection (GnuPG / OpenPGP): Encrypted automated backups.
#
# SYMPTOMS REPORTED BY MONITORING:
#   - API TLS service fails startup or client handshake validation.
#   - Backup restoration fails with error: "gpg: decryption failed: No secret key".
#   - Warning raised regarding insecure directory permissions on the GPG keyring.
#
# STUDENT GOAL:
#   1. Diagnose and fix the OpenSSL TLS certificate chain, key permissions, and key-cert pair mismatch.
#   2. Diagnose and fix the GPG keyring home permissions and restore missing secret key capabilities.
#   3. Successfully verify both encryption pipelines using `openssl` and `gpg` CLI tools.
#
# DISCLAIMER: Run this script ONLY in a safe, disposable laboratory VM or container.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_encryption_lab"

echo "======================================================================"
echo " [+] Initializing LPI 020-100 Topic 2.1 (Encryption) Lab Environment..."
echo "======================================================================"

# Clean previous lab runs
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/tls" "${LAB_DIR}/gpg/home" "${LAB_DIR}/temp_gen"

# ------------------------------------------------------------------------------
# 1. SETUP OPENSSL TLS BREAKAGE
# ------------------------------------------------------------------------------
echo "[*] Provisioning OpenSSL PKI infrastructure..."

# Generate Root CA
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${LAB_DIR}/tls/rootCA.key" \
    -out "${LAB_DIR}/tls/rootCA.crt" \
    -days 365 \
    -subj "/C=US/ST=Tech/L=Lab/O=LPI-Cert/CN=LPI-Root-CA" 2>/dev/null

# Generate Genuine Server Private Key and CSR
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${LAB_DIR}/tls/.correct_server.key" \
    -out "${LAB_DIR}/temp_gen/server.csr" \
    -subj "/C=US/ST=Tech/L=Lab/O=LPI-Cert/CN=api.production.local" 2>/dev/null

# Sign Certificate with Root CA
openssl x509 -req \
    -in "${LAB_DIR}/temp_gen/server.csr" \
    -CA "${LAB_DIR}/tls/rootCA.crt" \
    -CAkey "${LAB_DIR}/tls/rootCA.key" \
    -CAcreateserial \
    -out "${LAB_DIR}/tls/server.crt" \
    -days 365 2>/dev/null

# Generate Mismatched Private Key
openssl genrsa -out "${LAB_DIR}/tls/server.key" 2048 2>/dev/null

# BREAK 1A: Broken file permissions on server.key (unreadable by process)
chmod 000 "${LAB_DIR}/tls/server.key"

# BREAK 1B: Empty CA chain bundle file (incomplete PKI chain)
touch "${LAB_DIR}/tls/ca_chain.crt"

# ------------------------------------------------------------------------------
# 2. SETUP GNUPG (GPG) BREAKAGE
# ------------------------------------------------------------------------------
echo "[*] Provisioning GnuPG encrypted backup pipeline..."

TEMP_GPG="${LAB_DIR}/temp_gen/gpg"
mkdir -p "${TEMP_GPG}"
chmod 700 "${TEMP_GPG}"

cat <<EOF > "${LAB_DIR}/temp_gen/key_config"
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Backup Service
Name-Email: backup@lpi.local
Expire-Date: 0
%no-protection
%commit
EOF

# Generate keypair in temporary keyring
gpg --batch --homedir "${TEMP_GPG}" --generate-key "${LAB_DIR}/temp_gen/key_config" 2>/dev/null

# Encrypt test payload
echo "CONFIDENTIAL_PRODUCTION_DATABASE_BACKUP_DUMP_HASH_883921" > "${LAB_DIR}/gpg/backup_payload.txt"
gpg --batch --homedir "${TEMP_GPG}" --recipient "backup@lpi.local" \
    --encrypt --output "${LAB_DIR}/gpg/backup_payload.gpg" "${LAB_DIR}/gpg/backup_payload.txt" 2>/dev/null
rm -f "${LAB_DIR}/gpg/backup_payload.txt"

# Export public and secret keys
gpg --batch --homedir "${TEMP_GPG}" --armor --export "backup@lpi.local" > "${LAB_DIR}/gpg/public_key.asc" 2>/dev/null
gpg --batch --homedir "${TEMP_GPG}" --armor --export-secret-keys "backup@lpi.local" > "${LAB_DIR}/gpg/.secret_key_backup.asc" 2>/dev/null

# Populate student target keyring with ONLY the public key (Secret key missing)
GPG_HOME="${LAB_DIR}/gpg/home"
chmod 700 "${GPG_HOME}"
gpg --batch --homedir "${GPG_HOME}" --import "${LAB_DIR}/gpg/public_key.asc" 2>/dev/null

# BREAK 2A: Set insecure permissions on GPG home directory (triggers GPG warnings/failures)
chmod 777 "${GPG_HOME}"

# Cleanup temporary artifacts
rm -rf "${LAB_DIR}/temp_gen"

# ------------------------------------------------------------------------------
# LAB BRIEFING & INSTRUCTIONS
# ------------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo " [!] LAB ENVIRONMENT IS READY AND BROKEN!"
echo "======================================================================"
echo "Lab Location: ${LAB_DIR}"
echo ""
echo "TASK 1: Fix OpenSSL TLS Infrastructure (${LAB_DIR}/tls/)"
echo "----------------------------------------------------------------------"
echo "  Symptom 1: Running 'openssl verify -CAfile ${LAB_DIR}/tls/ca_chain.crt ${LAB_DIR}/tls/server.crt'"
echo "             fails with certificate verification errors."
echo "  Symptom 2: '${LAB_DIR}/tls/server.key' cannot be read due to file permissions."
echo "  Symptom 3: Even after fixing permissions, '${LAB_DIR}/tls/server.key' does NOT match '${LAB_DIR}/tls/server.crt'."
echo ""
echo "TASK 2: Fix GnuPG Encrypted Backup Pipeline (${LAB_DIR}/gpg/)"
echo "----------------------------------------------------------------------"
echo "  Symptom 1: Decryption command:"
echo "             gpg --homedir ${LAB_DIR}/gpg/home --decrypt ${LAB_DIR}/gpg/backup_payload.gpg"
echo "             throws unsafe directory permissions warning."
echo "  Symptom 2: Decryption fails with 'No secret key'."
echo ""
echo "Use standard Linux CLI tools (openssl, gpg, chmod, cmp, etc.) to repair the environment."
echo "Inspect the end of this script file for the complete commented-out step-by-step solution."
echo "======================================================================"

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & DIAGNOSTIC GUIDE (FOR STUDENTS / INSTRUCTORS)
# ==============================================================================
#
# ------------------------------------------------------------------------------
# PART 1: DIAGNOSING & FIXING OPENSSL TLS ISSUES
# ------------------------------------------------------------------------------
#
# Step 1.1: Verify certificate chain failure
# Command:
#   openssl verify -CAfile /tmp/lpi_encryption_lab/tls/ca_chain.crt /tmp/lpi_encryption_lab/tls/server.crt
# Expected Error:
#   error 20 at 0 depth lookup: unable to get local issuer certificate
# Root Cause:
#   ca_chain.crt is empty. Root CA certificate (rootCA.crt) must be present in ca_chain.crt.
# Fix 1.1:
#   cp /tmp/lpi_encryption_lab/tls/rootCA.crt /tmp/lpi_encryption_lab/tls/ca_chain.crt
#
# Step 1.2: Check private key read permissions
# Command:
#   cat /tmp/lpi_encryption_lab/tls/server.key
# Expected Error:
#   cat: /tmp/lpi_encryption_lab/tls/server.key: Permission denied
# Root Cause:
#   Permissions set to 000. Private keys should strictly be owned by the service user with 600 permissions.
# Fix 1.2:
#   chmod 600 /tmp/lpi_encryption_lab/tls/server.key
#
# Step 1.3: Verify Public/Private Key Modulus Match
# Command:
#   CERT_HASH=$(openssl x509 -noout -modulus -in /tmp/lpi_encryption_lab/tls/server.crt | openssl md5)
#   KEY_HASH=$(openssl rsa -noout -modulus -in /tmp/lpi_encryption_lab/tls/server.key | openssl md5)
#   echo "Cert Hash: $CERT_HASH"
#   echo "Key Hash:  $KEY_HASH"
# Expected Outcome:
#   Hashes DO NOT match! (The server.key file is a mismatched private key).
# Root Cause:
#   The current server.key was generated independently of the certificate request.
#   The genuine key was hidden as .correct_server.key during the breakage.
# Fix 1.3:
#   cp /tmp/lpi_encryption_lab/tls/.correct_server.key /tmp/lpi_encryption_lab/tls/server.key
#   chmod 600 /tmp/lpi_encryption_lab/tls/server.key
#
# Step 1.4: Final Verification of OpenSSL TLS Pipeline
# Command:
#   openssl verify -CAfile /tmp/lpi_encryption_lab/tls/ca_chain.crt /tmp/lpi_encryption_lab/tls/server.crt
# Expected Success Output:
#   /tmp/lpi_encryption_lab/tls/server.crt: OK
#
# Command:
#   CERT_MD5=$(openssl x509 -noout -modulus -in /tmp/lpi_encryption_lab/tls/server.crt | openssl md5)
#   KEY_MD5=$(openssl rsa -noout -modulus -in /tmp/lpi_encryption_lab/tls/server.key | openssl md5)
#   [ "$CERT_MD5" = "$KEY_MD5" ] && echo "SUCCESS: Certificate and Private Key Modulus Match!"
#
# ------------------------------------------------------------------------------
# PART 2: DIAGNOSING & FIXING GNUPG (GPG) ISSUES
# ------------------------------------------------------------------------------
#
# Step 2.1: Test decryption attempt
# Command:
#   gpg --homedir /tmp/lpi_encryption_lab/gpg/home --decrypt /tmp/lpi_encryption_lab/gpg/backup_payload.gpg
# Expected Errors:
#   1. gpg: WARNING: unsafe permissions on homedir '/tmp/lpi_encryption_lab/gpg/home'
#   2. gpg: decryption failed: No secret key
#
# Step 2.2: Fix GPG homedir permissions
# Root Cause:
#   GPG enforces strict security controls. Homedir must be restricted to user-only (0700).
# Fix 2.2:
#   chmod 700 /tmp/lpi_encryption_lab/gpg/home
#
# Step 2.3: List keys in GPG keyring to verify secret key availability
# Command:
#   gpg --homedir /tmp/lpi_encryption_lab/gpg/home --list-secret-keys
# Expected Outcome:
#   No secret keys displayed. (Only public key exists in the keyring).
#
# Step 2.4: Import missing secret key
# Root Cause:
#   The private key was omitted from the keyring during initialization. Backup key exists at .secret_key_backup.asc.
# Fix 2.4:
#   gpg --batch --homedir /tmp/lpi_encryption_lab/gpg/home --import /tmp/lpi_encryption_lab/gpg/.secret_key_backup.asc
#
# Step 2.5: Final Verification of GPG Decryption Pipeline
# Command:
#   gpg --batch --homedir /tmp/lpi_encryption_lab/gpg/home --decrypt /tmp/lpi_encryption_lab/gpg/backup_payload.gpg
# Expected Success Output:
#   CONFIDENTIAL_PRODUCTION_DATABASE_BACKUP_DUMP_HASH_883921
#
# ==============================================================================