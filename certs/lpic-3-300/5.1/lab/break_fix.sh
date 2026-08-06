#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 300 (Exam 300-300, Version 3.0) - Advanced Production Scenario
# Topic 305 / 5.1: Linux Identity Management and File Sharing (Weight: 20)
#
# ROLE: Senior SRE & Principal Platform Architect
# PURPOSE: Safe, controlled "Break & Fix" lab exercise for Enterprise Identity
#          Management (FreeIPA/SSSD/Kerberos) and Kerberized NFSv4 File Sharing.
#
# OFFICIAL REFERENCES:
# - LPIC-3 300 Overview: https://www.lpi.org/our-certifications/lpic-3-300-overview/
# - FreeIPA Documentation: https://www.freeipa.org/page/Documentation
# - SSSD Architecture & Configuration: https://sssd.io/documentation/sssd.html
# - NFSv4 / RPCSEC_GSSD Architecture: https://linux-nfs.org/wiki/index.php/Main_Page
# ==============================================================================

set -euo pipefail

RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BACKUP_DIR="/var/tmp/lpic3_topic305_backup_$(date +%Y%m%d_%H%M%S)"

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} LPIC-3 300 (v3.0) Topic 5.1: Identity & File Sharing Break-and-Fix   ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# 1. Pre-flight Checks
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] This script must be executed as root to modify SSSD, PAM, NFS, and Kerberos settings.${NC}"
   exit 1
fi

echo -e "${YELLOW}[1/4] Creating system configuration backups at ${BACKUP_DIR}...${NC}"
mkdir -p "${BACKUP_DIR}"

for cfg in /etc/sssd/sssd.conf /etc/idmapd.conf /etc/nsswitch.conf /etc/exports /etc/krb5.conf; do
    if [[ -f "$cfg" ]]; then
        cp -p "$cfg" "${BACKUP_DIR}/"
    fi
done

# 2. Provisioning Baseline Mock Lab Configuration
echo -e "${YELLOW}[2/4] Provisioning enterprise baseline for FreeIPA + SSSD + Kerberized NFSv4...${NC}"

# Ensure SSSD config directory exists
mkdir -p /etc/sssd /etc/exports.d

# Generate base krb5.conf if missing
if [[ ! -f /etc/krb5.conf ]]; then
cat <<'EOF' > /etc/krb5.conf
[libdefaults]
    default_realm = IPA.LAB.LOCAL
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    ticket_lifetime = 24h
    forwardable = true

[realms]
    IPA.LAB.LOCAL = {
        kdc = ipa.lab.local:88
        admin_server = ipa.lab.local:749
    }

[domain_realm]
    .lab.local = IPA.LAB.LOCAL
    lab.local = IPA.LAB.LOCAL
EOF
fi

# Generate base sssd.conf
cat <<'EOF' > /etc/sssd/sssd.conf
[sssd]
services = nss, pam, sudo, ssh
config_file_version = 2
domains = IPA.LAB.LOCAL

[domain/IPA.LAB.LOCAL]
id_provider = ipa
auth_provider = ipa
access_provider = ipa
chpass_provider = ipa
ipa_domain = lab.local
ipa_server = _srv_, ipa.lab.local
krb5_realm = IPA.LAB.LOCAL
cache_credentials = True
krb5_store_password_if_offline = True
EOF
chmod 0600 /etc/sssd/sssd.conf

# Generate base idmapd.conf
cat <<'EOF' > /etc/idmapd.conf
[General]
Verbosity = 0
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = lab.local

[Mapping]
Nobody-User = nobody
Nobody-Group = nobody

[Translation]
Method = nsswitch
EOF

# Generate base /etc/exports
cat <<'EOF' > /etc/exports
/srv/nfs/secured_data *.lab.local(rw,sync,sec=krb5p,no_root_squash)
EOF

# Touch mock keytab if not existing
mkdir -p /etc/krb5.keytab.d
if [[ ! -f /etc/krb5.keytab ]]; then
    touch /etc/krb5.keytab
fi

# 3. Injecting Controlled Failures (Break Stage)
echo -e "${RED}[3/4] Injecting multi-layered production breakdowns...${NC}"

# BREAKAGE A: SSSD Domain Mismatch & NSS Switch Plugin Exclusion
# Mechanic: Removing 'sss' from nsswitch.conf breaks identity resolution for LDAP/IPA users.
if [[ -f /etc/nsswitch.conf ]]; then
    sed -i 's/passwd:     files sss/passwd:     files/' /etc/nsswitch.conf || true
    sed -i 's/group:      files sss/group:      files/' /etc/nsswitch.conf || true
    sed -i 's/passwd:.*files.*/passwd: files/' /etc/nsswitch.conf || true
    sed -i 's/group:.*files.*/group: files/' /etc/nsswitch.conf || true
fi

# BREAKAGE B: SSSD Realm and Provider Misconfiguration
# Mechanic: Discarding valid IPA domain mapping in sssd.conf prevents PAM & NSS integration.
cat <<'EOF' > /etc/sssd/sssd.conf
[sssd]
services = pam, sudo
config_file_version = 2
domains = WRONG.REALM.INTERNAL

[domain/WRONG.REALM.INTERNAL]
id_provider = ldap
ldap_uri = ldap://invalid-kdc.lab.local
krb5_realm = WRONG.REALM.INTERNAL
EOF
chmod 0644 /etc/sssd/sssd.conf  # Insecure permissions trigger SSSD start failure

# BREAKAGE C: NFSv4 Domain Name Mapping Mismatch (idmapd)
# Mechanic: Mismatched NFSv4 Domain in idmapd causes all remote Kerberos users to fall back to 'nobody:nobody'.
cat <<'EOF' > /etc/idmapd.conf
[General]
Verbosity = 3
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = invalid-nfs-domain.org

[Mapping]
Nobody-User = nobody
Nobody-Group = nobody

[Translation]
Method = static
EOF

# BREAKAGE D: Kerberos Service Keytab Permissions & Exports Security Flags
# Mechanic: World-unreadable keytab blocks rpc.gssd from loading 'nfs/fqdn@REALM' principal.
chmod 0000 /etc/krb5.keytab

cat <<'EOF' > /etc/exports
/srv/nfs/secured_data *.lab.local(rw,sync,sec=sys,no_root_squash)
EOF

echo -e "${GREEN}[4/4] Environment state degraded successfully!${NC}"
echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} INCIDENT BRIEFING & DIAGNOSTIC OBJECTIVES (LPIC-3 300 Topic 5.1)      ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo "SYMPTOMS REPORTED BY SRE TEAM:"
echo " 1. Enterprise domain users (e.g., FreeIPA identity 'e.user') cannot be resolved"
echo "    via 'getent passwd' or 'id' on client systems."
echo " 2. The SSSD service fails to start or rejects configuration loading."
echo " 3. Kerberized NFSv4 mount requests (/srv/nfs/secured_data) fail with 'Permission Denied'"
echo "    or degrade to unsecured 'sec=sys', mapping all users to 'nobody:nobody'."
echo " 4. RPC SEC GSSD fails to locate valid host/service principals from /etc/krb5.keytab."
echo ""
echo "YOUR OBJECTIVES:"
echo " A. Restore Name Service Switch (NSS) and PAM integration in /etc/nsswitch.conf."
echo " B. Fix /etc/sssd/sssd.conf permissions (0600) and set domain 'IPA.LAB.LOCAL' with 'ipa' provider."
echo " C. Align NFSv4 identity mapping domain in /etc/idmapd.conf to match 'lab.local' with 'nsswitch' translation."
echo " D. Enforce strict RPCSEC_GSSD Kerberos security (sec=krb5p) in /etc/exports and fix keytab permissions."
echo ""
echo "DIAGNOSTIC TOOLING TO USE:"
echo " - getent passwd <user> / sssctl domain-status / sssctl config-check"
echo " - klist -kt /etc/krb5.keytab"
echo " - exportfs -v / nfsidmap -c"
echo " - journalctl -u sssd -u nfs-server -u rpc-gssd"
echo ""
echo -e "${YELLOW}To view the step-by-step solution, open this file and read the commented code at the end.${NC}"
echo -e "${BLUE}======================================================================${NC}"

exit 0

# ==============================================================================
#                      STEP-BY-STEP SOLUTION & ARCHITECTURAL GUIDE
# ==============================================================================
#
# TECHNICAL MECHANICS & ARCHITECTURE:
# 1. FreeIPA & SSSD Integration (Topic 305.1 & 305.2):
#    SSSD acts as the caching NSS and PAM provider for Linux identity management.
#    - /etc/sssd/sssd.conf MUST have permissions 0600 (owned by root:root); SSSD refuses
#      to start if world- or group-readable.
#    - /etc/nsswitch.conf must route database lookups to the SSSD daemon via 'sss':
#      passwd: files sss
#      group:  files sss
#    - The FreeIPA domain configuration in sssd.conf requires matching 'id_provider = ipa',
#      'ipa_domain = lab.local', and 'krb5_realm = IPA.LAB.LOCAL'.
#
# 2. NFSv4 & Kerberos Security (RPCSEC_GSSD & IDMAPD) (Topic 305.4):
#    - NFSv4 does not pass numeric UID/GIDs over the wire; it passes user strings
#      (user@domain). Both server and client MUST share the exact same 'Domain' setting
#      in /etc/idmapd.conf. Mismatches cause default fallback to 'nobody:nobody'.
#    - 'sec=krb5p' enforces full RPCSEC_GSSD packet encryption and integrity.
#    - The GSSD daemon (rpc-gssd.service) requires read access to /etc/krb5.keytab containing
#      the service principal 'nfs/<fqdn>@REALM'.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP REMEDIATION COMMANDS:
# ------------------------------------------------------------------------------
#
# STEP 1: Fix Name Service Switch (/etc/nsswitch.conf)
# --------------------------------------------------
# Ensure 'sss' is present for passwd and group databases:
#
#   sed -i 's/^passwd:.*/passwd:     files sss/' /etc/nsswitch.conf
#   sed -i 's/^group:.*/group:      files sss/' /etc/nsswitch.conf
#
# Verification:
#   getent passwd
#
# STEP 2: Repair SSSD Configuration & Secure File Permissions (/etc/sssd/sssd.conf)
# ----------------------------------------------------------------------------------
# Write valid configuration:
#
#   cat <<'EOF' > /etc/sssd/sssd.conf
#   [sssd]
#   services = nss, pam, sudo, ssh
#   config_file_version = 2
#   domains = IPA.LAB.LOCAL
#   
#   [domain/IPA.LAB.LOCAL]
#   id_provider = ipa
#   auth_provider = ipa
#   access_provider = ipa
#   chpass_provider = ipa
#   ipa_domain = lab.local
#   ipa_server = _srv_, ipa.lab.local
#   krb5_realm = IPA.LAB.LOCAL
#   cache_credentials = True
#   krb5_store_password_if_offline = True
#   EOF
#
# Enforce security permissions and restart SSSD:
#   chmod 0600 /etc/sssd/sssd.conf
#   chown root:root /etc/sssd/sssd.conf
#   sssctl config-check
#   systemctl restart sssd
#
# Verification:
#   sssctl domain-status IPA.LAB.LOCAL
#
# STEP 3: Align NFSv4 Identity Mapping (/etc/idmapd.conf)
# --------------------------------------------------------
# Set matching domain and translation method:
#
#   cat <<'EOF' > /etc/idmapd.conf
#   [General]
#   Verbosity = 0
#   Pipefs-Directory = /var/lib/nfs/rpc_pipefs
#   Domain = lab.local
#   
#   [Mapping]
#   Nobody-User = nobody
#   Nobody-Group = nobody
#   
#   [Translation]
#   Method = nsswitch
#   EOF
#
# Clear NFS IDMAP cache:
#   nfsidmap -c
#
# STEP 4: Enforce Kerberized NFSv4 Export & Fix Keytab Permissions
# ----------------------------------------------------------------
# Fix keytab permissions:
#   chmod 0600 /etc/krb5.keytab
#   chown root:root /etc/krb5.keytab
#
# Verify keytab principals:
#   klist -kt /etc/krb5.keytab
#
# Configure kerberized export in /etc/exports:
#   cat <<'EOF' > /etc/exports
#   /srv/nfs/secured_data *.lab.local(rw,sync,sec=krb5p,no_root_squash)
#   EOF
#
# Re-export shares and restart RPCSEC_GSSD:
#   exportfs -rv
#   systemctl restart rpc-gssd nfs-server
#
# Verification:
#   exportfs -v
#   showmount -e localhost
#
# ------------------------------------------------------------------------------
# PRODUCTION TRADE-OFFS & BEST PRACTICES:
# - sec=krb5: Authenticates RPC requests, minimal performance overhead.
# - sec=krb5i: Authenticates and signs packet header/payload (integrity), protects against tampering.
# - sec=krb5p: Full payload encryption (privacy). High security, CPU overhead on high-throughput storage networks.
# - SSSD Caching: In high-availability setups, 'cache_credentials = True' allows offline login during KDC outages,
#   but key revocation propagation is delayed until cache timeout expires.
# ==============================================================================