#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 (Exam 202-450) Topic 2.1: Domain Name Server (BIND9) Break & Fix Lab
# 
# Target OS: Ubuntu 22.04 LTS / Debian 12 (Lab VM recommended)
# Weight: 8
# Official Reference: https://www.lpi.org/our-certifications/lpic-2-overview/
#
# DESCRIPTION:
# This script provisions a functional BIND9 DNS server for 'corp.internal'
# and then injects multiple real-world production failures:
#   1. Syntax errors in zone files & named configuration.
#   2. Incorrect file system permissions and ownership (chroot/daemon context).
#   3. Broken RNDC control interface key synchronization.
#   4. Restrictive ACLs breaking client resolution.
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
log_pass()  { echo -e "${GREEN}[OK]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   log_error "This lab script must be executed as root."
   exit 1
fi

log_info "Preparing LPIC-2 Topic 2.1 BIND9 Break & Fix Environment..."

# 1. Package Installation
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq bind9 bind9utils dnsutils > /dev/null

SERVICE_NAME="bind9"
CONF_DIR="/etc/bind"
ZONES_DIR="${CONF_DIR}/zones"

log_info "Setting up initial functional BIND9 architecture..."

mkdir -p "${ZONES_DIR}"

# 2. Base Configuration (Clean baseline)
cat << 'EOF' > "${CONF_DIR}/named.conf.options"
options {
        directory "/var/cache/bind";

        forwarders {
                8.8.8.8;
                8.8.4.4;
        };

        dnssec-validation auto;
        listen-on-v4 { any; };
        listen-on-v6 { any; };
        allow-query { any; };
};
EOF

cat << 'EOF' > "${CONF_DIR}/named.conf.local"
include "/etc/bind/rndc.key";

controls {
    inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
};

zone "corp.internal" {
    type master;
    file "/etc/bind/zones/db.corp.internal";
    allow-update { none; };
};

zone "10.10.10.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.10.10.10";
    allow-update { none; };
};
EOF

# Generate initial valid rndc key
rndc-confgen -a -c "${CONF_DIR}/rndc.key" -k rndc-key > /dev/null 2>&1 || true
chown bind:bind "${CONF_DIR}/rndc.key"
chmod 0640 "${CONF_DIR}/rndc.key"

# Clean Zone File: Forward
cat << 'EOF' > "${ZONES_DIR}/db.corp.internal"
$TTL    86400
@       IN      SOA     ns1.corp.internal. admin.corp.internal. (
                              2026080601 ; Serial
                                  3600   ; Refresh
                                   1800   ; Retry
                                 604800   ; Expire
                                  86400 ) ; Negative Cache TTL
;
@       IN      NS      ns1.corp.internal.
ns1     IN      A       10.10.10.2
app01   IN      A       10.10.10.50
db01    IN      A       10.10.10.60
web     IN      CNAME   app01.corp.internal.
EOF

# Clean Zone File: Reverse
cat << 'EOF' > "${ZONES_DIR}/db.10.10.10"
$TTL    86400
@       IN      SOA     ns1.corp.internal. admin.corp.internal. (
                              2026080601 ; Serial
                                  3600   ; Refresh
                                  1800   ; Retry
                                604800   ; Expire
                                 86400 ) ; Negative Cache TTL
;
@       IN      NS      ns1.corp.internal.
2       IN      PTR     ns1.corp.internal.
50      IN      PTR     app01.corp.internal.
60      IN      PTR     db01.corp.internal.
EOF

chown -R bind:bind "${CONF_DIR}"
chmod 0755 "${ZONES_DIR}"
chmod 0644 "${ZONES_DIR}"/*

systemctl restart "${SERVICE_NAME}"
sleep 2

# Verify baseline works
if ! rndc status > /dev/null 2>&1; then
    log_error "Baseline initialization failed. Check system logs."
    exit 1
fi
log_pass "Baseline BIND9 setup verified successfully."

# ==============================================================================
# INJECTING BREAKS (Simulating Production Incidents)
# ==============================================================================
log_warn "Injecting production faults into BIND9 DNS service..."

# FAULT 1: Syntax error in named.conf.options ('forwarder' typo instead of 'forwarders' & bad ACL syntax)
cat << 'EOF' > "${CONF_DIR}/named.conf.options"
options {
        directory "/var/cache/bind";

        forwarder {
                8.8.8.8;
                8.8.4.4;
        };

        dnssec-validation auto;
        listen-on-v4 { any; };
        listen-on-v6 { any; };
        allow-query { 127.0.0.2; };
};
EOF

# FAULT 2: Zone file syntax error (Missing origin dot in SOA & invalid TTL specifier)
cat << 'EOF' > "${ZONES_DIR}/db.corp.internal"
$TTL    86400
@       IN      SOA     ns1.corp.internal admin.corp.internal (
                              2026080601
                                  3600
                                  1800
                                604800
                                  INVALID_TTL )
;
@       IN      NS      ns1.corp.internal.
ns1     IN      A       10.10.10.2
app01   IN      A       10.10.10.50
db01    IN      A       10.10.10.60
web     IN      CNAME   app01
EOF

# FAULT 3: Permission and Ownership corruption on zone directory and zone files
chown -R root:root "${ZONES_DIR}"
chmod 000 "${ZONES_DIR}/db.corp.internal"
chmod 0700 "${ZONES_DIR}"

# FAULT 4: Break RNDC control key synchronization
cat << 'EOF' > "${CONF_DIR}/rndc.key"
key "rndc-key" {
    algorithm hmac-sha256;
    secret "dGhpcyBpcyBhIGZha2Uga2V5IGZvciBicmVhazZmaXgK";
};
EOF
chown root:root "${CONF_DIR}/rndc.key"
chmod 0600 "${CONF_DIR}/rndc.key"

# Attempt service reload/restart to activate broken state
systemctl reload "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true

log_warn "Fault injection complete. Service is now in a broken state."
echo ""
echo "=========================================================================="
echo "                   LPIC-2 BREAK & FIX LAB: DOMAIN NAME SERVER             "
echo "=========================================================================="
echo "INCIDENT REPORT:"
echo "System monitoring reported that internal DNS name resolution for 'corp.internal'"
echo "is failing, BIND9 service reloads fail, and daemon management via RNDC is broken."
echo ""
echo "STUDENT OBJECTIVES:"
echo " 1. Restore service functionality so 'bind9' starts and runs cleanly."
echo " 2. Ensure 'rndc status' and 'rndc reload' complete without errors."
echo " 3. Verify forward lookup resolution:"
echo "    - 'dig @127.0.0.1 app01.corp.internal A' returns 10.10.10.50"
echo "    - 'dig @127.0.0.1 web.corp.internal CNAME' returns app01.corp.internal."
echo " 4. Ensure BIND filesystem permissions adhere to security least-privilege."
echo ""
echo "DIAGNOSTIC TOOLS RECOMMENDED:"
echo " - named-checkconf -z /etc/bind/named.conf"
echo " - named-checkzone corp.internal /etc/bind/zones/db.corp.internal"
echo " - rndc status"
echo " - journalctl -u bind9 -n 50 --no-pager"
echo " - ls -la /etc/bind/ /etc/bind/zones/"
echo "=========================================================================="
echo ""

# ==============================================================================
# SOLUTION STEP-BY-STEP (Commented out for the student)
# ==============================================================================
#
# STEP 1: Inspect Systemd Service Logs & Syntax Check
# ----------------------------------------------------
# Run `named-checkconf` to find global configuration errors:
#   # named-checkconf /etc/bind/named.conf
#   /etc/bind/named.conf.options:4: unknown option 'forwarder'
#
# Fix `/etc/bind/named.conf.options`:
# Change `forwarder` to `forwarders` and fix `allow-query`:
#   options {
#           directory "/var/cache/bind";
#           forwarders {
#                   8.8.8.8;
#                   8.8.4.4;
#           };
#           dnssec-validation auto;
#           listen-on-v4 { any; };
#           listen-on-v6 { any; };
#           allow-query { any; };
#   };
#
# STEP 2: Diagnose RNDC Authentication Failures
# ---------------------------------------------
# Test RNDC:
#   # rndc status
#   rndc: connect failed: 127.0.0.1#953: connection refused OR permission denied / key mismatch
#
# Fix permissions and regenerate synchronous RNDC key:
#   # rndc-confgen -a -c /etc/bind/rndc.key -k rndc-key
#   # chown bind:bind /etc/bind/rndc.key
#   # chmod 0640 /etc/bind/rndc.key
#
# STEP 3: Diagnose Permissions and Zone Errors
# --------------------------------------------
# Check filesystem permissions:
#   # ls -ld /etc/bind/zones
#   drwx------ 2 root root ... /etc/bind/zones
#
# Fix permissions:
#   # chown -R bind:bind /etc/bind/zones
#   # chmod 0755 /etc/bind/zones
#   # chmod 0644 /etc/bind/zones/*
#
# Validate the forward zone file syntax using `named-checkzone`:
#   # named-checkzone corp.internal /etc/bind/zones/db.corp.internal
#   /etc/bind/zones/db.corp.internal:3: SOA record missing trailing dot or bad format
#   /etc/bind/zones/db.corp.internal:8: bad TTL 'INVALID_TTL'
#
# Fix `/etc/bind/zones/db.corp.internal`:
#   $TTL    86400
#   @       IN      SOA     ns1.corp.internal. admin.corp.internal. (
#                                 2026080602 ; Serial (incremented)
#                                     3600   ; Refresh
#                                     1800   ; Retry
#                                   604800   ; Expire
#                                    86400 ) ; Negative Cache TTL
#   ;
#   @       IN      NS      ns1.corp.internal.
#   ns1     IN      A       10.10.10.2
#   app01   IN      A       10.10.10.50
#   db01    IN      A       10.10.10.60
#   web     IN      CNAME   app01.corp.internal.
#
# STEP 4: Verification
# --------------------
# Reload and verify BIND9:
#   # named-checkconf -z /etc/bind/named.conf
#   # systemctl restart bind9
#   # rndc reload
#   server reload successful
#
# Test resolution:
#   # dig @127.0.0.1 app01.corp.internal A +short
#   10.10.10.50
#
#   # dig @127.0.0.1 web.corp.internal CNAME +short
#   app01.corp.internal.
# ==============================================================================