#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 303-300 (Version 3.0) - Topic 3.1: Application Security
# Exam Weight: 16.66
# Lab Challenge: Web Application Firewall (WAF) & TLS Hardening Break-and-Fix
#
# Official References:
# - https://www.lpi.org/our-certifications/lpic-3-303-overview/
# - https://wiki.lpi.org/wiki/LPIC-3_Security_Exam_303_Objectives
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_done()  { echo -e "${GREEN}[OK]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be executed as root (e.g., via sudo)."
    exit 1
fi

log_info "Initializing LPIC-3 303 Topic 3.1 Application Security Lab Environment..."

# Detect Linux Distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    log_error "Unsupported operating system. /etc/os-release not found."
    exit 1
fi

log_info "Installing required packages for Web Application Security testing..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq apache2 libapache2-mod-security2 openssl curl > /dev/null
    HTTPD_SERVICE="apache2"
    CONF_DIR="/etc/apache2"
    MODSEC_CONF="/etc/apache2/mods-available/security2.conf"
    SITE_CONF="/etc/apache2/sites-available/app-security-ssl.conf"
    WEB_USER="www-data"
    WEB_GROUP="www-data"
    a2enmod ssl security2 headers rewrite > /dev/null 2>&1 || true
elif [[ "$OS" == "rocky" || "$OS" == "almalinux" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    dnf install -y -q httpd mod_ssl mod_security openssl curl > /dev/null
    HTTPD_SERVICE="httpd"
    CONF_DIR="/etc/httpd"
    MODSEC_CONF="/etc/httpd/conf.modules.d/00-security.conf"
    SITE_CONF="/etc/httpd/conf.d/app-security-ssl.conf"
    WEB_USER="apache"
    WEB_GROUP="apache"
else
    log_error "Distribution '$OS' is not supported by this automated lab setup."
    exit 1
fi

log_info "Setting up Public Key Infrastructure (PKI) for mTLS Client Authentication..."
CERT_DIR="/etc/ssl/app-security"
mkdir -p "$CERT_DIR"
chmod 755 "$CERT_DIR"

# Generate Internal CA
openssl req -x509 -newkey rsa:4096 -days 365 -nodes \
    -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
    -subj "/C=US/ST=State/L=City/O=LPIC3-Lab/OU=Security/CN=Internal-CA" >/dev/null 2>&1

# Generate Server Certificate & CSR
openssl req -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" \
    -subj "/C=US/ST=State/L=City/O=LPIC3-Lab/OU=Production/CN=localhost" >/dev/null 2>&1

# Sign Server Certificate
openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial -out "$CERT_DIR/server.crt" -days 365 >/dev/null 2>&1

# Generate Valid Client Certificate for mTLS tests
openssl req -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/client.key" -out "$CERT_DIR/client.csr" \
    -subj "/C=US/ST=State/L=City/O=LPIC3-Lab/OU=APIClient/CN=api-client" >/dev/null 2>&1

openssl x509 -req -in "$CERT_DIR/client.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial -out "$CERT_DIR/client.crt" -days 365 >/dev/null 2>&1

# Configure Web Root Document
WEB_ROOT="/var/www/app-security"
mkdir -p "$WEB_ROOT/api/v1"
echo '{"status":"success","message":"Authenticated API Endpoint Access Granted"}' > "$WEB_ROOT/api/v1/data.json"
echo '<html><body><h1>Production Application Home</h1></body></html>' > "$WEB_ROOT/index.html"
chown -R "$WEB_USER:$WEB_GROUP" "$WEB_ROOT"

log_info "Deploying baseline HTTPD Application Security Configuration..."

# Base VirtualHost with TLS, mTLS, HSTS, and ModSecurity Integration
cat <<EOF > "$SITE_CONF"
<VirtualHost *:443>
    ServerName localhost
    DocumentRoot $WEB_ROOT

    SSLEngine on
    SSLCertificateFile $CERT_DIR/server.crt
    SSLCertificateKeyFile $CERT_DIR/server.key
    SSLCACertificateFile $CERT_DIR/ca.crt

    # Modern TLS Security Controls (LPIC-3 303 Objective 331/335)
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder off

    # HTTP Security Headers
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"

    # Enforce mTLS Client Certificate Authentication on API Endpoints
    <Location /api/v1>
        SSLVerifyClient require
        SSLVerifyDepth 2
        SSLOptions +StdEnvVars
    </Location>

    ErrorLog /var/log/$HTTPD_SERVICE/app_error.log
    CustomLog /var/log/$HTTPD_SERVICE/app_access.log combined
</VirtualHost>
EOF

# Ensure ModSecurity base workspace and rule directories exist
MODSEC_RULE_DIR="/etc/modsecurity/rules"
mkdir -p "$MODSEC_RULE_DIR"
mkdir -p /var/cache/modsecurity
chown -R "$WEB_USER:$WEB_GROUP" /var/cache/modsecurity

# Base ModSecurity main configuration
cat <<EOF > /etc/modsecurity/modsecurity.conf
SecRuleEngine On
SecRequestBodyAccess On
SecResponseBodyAccess Off
SecResponseBodyMimeType text/html text/plain text/xml application/json
SecResponseBodyLimit 5242880
SecRequestBodyNoFilesLimit 131072
SecRequestBodyInMemoryLimit 131072
SecRequestBodyLimitAction Reject
SecRuleSecGeoDir /usr/share/GeoIP
SecTmpDir /tmp/
SecDataDir /var/cache/modsecurity
SecAuditEngine RelevanceOnly
SecAuditLogRelevantStatus "^(?:5|(?:4(?!04)))"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/$HTTPD_SERVICE/modsec_audit.log
SecArgumentSeparator &
SecCookieFormat 0
EOF

cat <<EOF > "$MODSEC_RULE_DIR/custom_rules.conf"
# LPIC-3 Custom Web Application Protection Rules
SecRule REQUEST_HEADERS:User-Agent "@rx (?i)(sqlmap|nikto|havij|nmap)" \
    "id:1000001,phase:1,log,deny,status:403,msg:'Automated Vulnerability Scanner Blocked'"
EOF

log_info "Injecting controlled production security failures (BREAK phase)..."

# BREAK 1: Corrupt mTLS CA Certificate File permissions and inject invalid SSLCipherSuite syntax
chmod 000 "$CERT_DIR/ca.crt"
sed -i 's/SSLCipherSuite .*/SSLCipherSuite INVALID-CIPHER-SUITE-XYZ:ECDHE-RSA-DES-CBC3-SHA/' "$SITE_CONF"

# BREAK 2: Inject ModSecurity syntax error & invalid SecDataDir configuration
cat <<EOF > "$MODSEC_RULE_DIR/custom_rules.conf"
# BROKEN WAF RULE - Missing mandatory rule ID and malformed action quotes
SecRule REQUEST_HEADERS:User-Agent "@rx (?i)(sqlmap|nikto|havij|nmap)" \
    "phase:1,deny,status:403,msg:Automated Scanner Blocked"
EOF

chmod 000 /var/cache/modsecurity

# BREAK 3: Enforce restrictive systemd Sandbox Override blocking state paths
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/$HTTPD_SERVICE.service.d"
mkdir -p "$SYSTEMD_OVERRIDE_DIR"
cat <<EOF > "$SYSTEMD_OVERRIDE_DIR/hardening.conf"
[Service]
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/$HTTPD_SERVICE
# Systemd restriction intentionally missing /var/cache/modsecurity and /etc/ssl/app-security access
ReadOnlyPaths=/etc
EOF

systemctl daemon-reload

# Attempt to restart service to reflect broken state (expected to fail or degrade)
systemctl restart "$HTTPD_SERVICE" >/dev/null 2>&1 || true

cat << 'EOF'

==============================================================================
             LPIC-3 303-300: APPLICATION SECURITY BREAK & FIX LAB
==============================================================================

STATUS: BROKEN ENVIRONMENT DEPLOYED

[SCENARIO DESCRIPTION]
You are acting as a Senior Platform Architect / SRE responding to an emergency
incident. A hardened production web application running on Apache HTTPD with 
mod_ssl, mTLS client verification, and ModSecurity (WAF) failed after a security
compliance deployment.

[SYMPTOMS]
1. The web server service (apache2 / httpd) fails to start or pass configuration tests.
2. `systemctl status` or `journalctl -u` reports errors loading SSL components and
   parsing WAF security rules.
3. API endpoints requiring mTLS fail during TLS negotiation or throw 500/503 errors.
4. ModSecurity fails to write transaction state data due to permission & sandboxing constraints.

[YOUR OBJECTIVE]
Troubleshoot and remediate all security misconfigurations, syntax errors, PKI/mTLS
permission issues, and systemd sandboxing constraints while maintaining strict 
hardening standards:
- Fix Web Application Firewall (ModSecurity) rule engine syntax and storage permissions.
- Restore valid, secure TLS 1.2/1.3 cipher suites and mTLS CA certificate accessibility.
- Adjust systemd service hardening overrides to allow necessary state & logging access.
- Validate that the web server passes syntax validation (`apachectl configtest`).
- Verify mTLS endpoint protection using curl:
    curl -k --cert /etc/ssl/app-security/client.crt \
            --key /etc/ssl/app-security/client.key \
            https://localhost/api/v1/data.json

[DIAGNOSTIC HINTS & USEFUL COMMANDS]
- Service Syntax Check: apachectl configtest / apache2ctl configtest
- Audit System Logs:   journalctl -u apache2 -e  OR  journalctl -u httpd -e
- Audit Error Logs:    tail -n 50 /var/log/apache2/error.log (or /var/log/httpd/error_log)
- ModSecurity Logs:    tail -n 50 /var/log/apache2/modsec_audit.log
- Verify Certificate:  openssl x509 -in /etc/ssl/app-security/ca.crt -text -noout

==============================================================================
EOF

exit 0

# ==============================================================================
#                        STEP-BY-STEP SOLUTION (COMMENTED)
# ==============================================================================
#
# Below is the complete step-by-step diagnostic and remediation procedure to resolve
# all issues injected by this lab.
#
# ------------------------------------------------------------------------------
# STEP 1: Perform Initial Service Diagnostics
# ------------------------------------------------------------------------------
# Run the Apache configuration test tool to identify syntax and file access errors:
#
#   # apache2ctl configtest
#   (or: apachectl configtest)
#
# Output will highlight configuration parsing failures, e.g.:
# - SSLCACertificateFile: file '/etc/ssl/app-security/ca.crt' does not exist or is empty
# - ModSecurity rule error: Rule missing id
#
# ------------------------------------------------------------------------------
# STEP 2: Fix PKI and File Permissions
# ------------------------------------------------------------------------------
# Inspect permissions of the CA certificate:
#   # ls -la /etc/ssl/app-security/ca.crt
#
# Restore read permissions for the web server user:
#   # chmod 644 /etc/ssl/app-security/ca.crt
#
# Fix ModSecurity state directory permissions:
#   # chmod 750 /var/cache/modsecurity
#   # chown -R www-data:www-data /var/cache/modsecurity   # (On RHEL/Rocky: apache:apache)
#
# ------------------------------------------------------------------------------
# STEP 3: Correct TLS Cipher Suites in VirtualHost Configuration
# ------------------------------------------------------------------------------
# Edit the VirtualHost site configuration file:
#   Debian/Ubuntu: /etc/apache2/sites-available/app-security-ssl.conf
#   RHEL/Rocky:    /etc/httpd/conf.d/app-security-ssl.conf
#
# Locate `SSLCipherSuite` and replace invalid entries with modern, secure ciphers:
#
#   SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
#
# ------------------------------------------------------------------------------
# STEP 4: Fix ModSecurity Custom Rules Syntax
# ------------------------------------------------------------------------------
# Edit /etc/modsecurity/rules/custom_rules.conf and correct the rule syntax.
# Every custom ModSecurity rule MUST contain a unique `id` field and properly quoted metadata:
#
#   SecRule REQUEST_HEADERS:User-Agent "@rx (?i)(sqlmap|nikto|havij|nmap)" \
#       "id:1000001,phase:1,log,deny,status:403,msg:'Automated Vulnerability Scanner Blocked'"
#
# ------------------------------------------------------------------------------
# STEP 5: Update Systemd Sandbox Overrides
# ------------------------------------------------------------------------------
# Inspect systemd override file:
#   # cat /etc/systemd/system/apache2.service.d/hardening.conf
#
# The `ProtectSystem=strict` directive makes /var read-only except paths explicitly listed
# in `ReadWritePaths`. ModSecurity requires write access to `/var/cache/modsecurity`.
#
# Update the override file (/etc/systemd/system/apache2.service.d/hardening.conf or httpd):
#
#   [Service]
#   ProtectSystem=strict
#   ProtectHome=true
#   ReadWritePaths=/var/log/apache2 /var/log/httpd /var/cache/modsecurity /run/apache2 /run/httpd
#
# Reload systemd manager configuration:
#   # systemctl daemon-reload
#
# ------------------------------------------------------------------------------
# STEP 6: Validate Configuration and Restart Service
# ------------------------------------------------------------------------------
# Run syntax check:
#   # apache2ctl configtest
#   Syntax OK
#
# Restart web server:
#   # systemctl restart apache2   # (or httpd)
#   # systemctl status apache2    # (or httpd)
#
# ------------------------------------------------------------------------------
# STEP 7: Verify Application Security & mTLS Enforcement
# ------------------------------------------------------------------------------
# A) Test unauthenticated request to mTLS location (Must fail with 400 Bad Request / SSL error):
#    curl -k https://localhost/api/v1/data.json
#
# B) Test authenticated request using valid mTLS Client Certificate (Must return 200 OK):
#    curl -k --cert /etc/ssl/app-security/client.crt \
#            --key /etc/ssl/app-security/client.key \
#            https://localhost/api/v1/data.json
#
# C) Test ModSecurity WAF Blocking (Must return 403 Forbidden):
#    curl -k -A "nikto" https://localhost/index.html
#
# ==============================================================================