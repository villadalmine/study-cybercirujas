#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 Exam 201-450 / 202-450 (v4.5) - Topic 2.4: Network Client Management
# Weight: 8
# Target Domain: DHCP Client, NSS (Name Service Switch), PAM, and SSSD/LDAP Integration
#
# Reference URLs:
# - LPIC-2 Certification Overview: https://www.lpi.org/our-certifications/lpic-2-overview/
# - OpenLDAP Client Documentation: https://www.openldap.org/doc/admin24/
# - Linux PAM System Administrator's Guide: http://www.linux-pam.org/Linux-PAM-html/
# - ISC DHCP Client Manual: https://kb.isc.org/docs/aa-00334
#
# WARNING: This script modifies critical networking, authentication, and NSS files.
# Run ONLY inside an isolated, disposable test VM / sandbox container!
# ==============================================================================

set -euo pipefail

# Color Codes for Terminal Output
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

BACKUP_DIR="/var/backups/lpic2_topic204_breakfix"
NSSWITCH_CONF="/etc/nsswitch.conf"
DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
PAM_SYS_AUTH="/etc/pam.d/system-auth"
PAM_COMMON_AUTH="/etc/pam.d/common-auth"

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[ERROR] This break-and-fix script must be executed as root.${NC}" >&2
    exit 1
fi

echo -e "${BLUE}${BOLD}====================================================================${NC}"
echo -e "${BLUE}${BOLD}   LPIC-2 Topic 2.4: Network Client Management - Break & Fix Lab    ${NC}"
echo -e "${BLUE}${BOLD}====================================================================${NC}"

# ------------------------------------------------------------------------------
# Backup Mechanism
# ------------------------------------------------------------------------------
mkdir -p "${BACKUP_DIR}"

backup_file() {
    local target="$1"
    if [[ -f "${target}" ]]; then
        cp -a "${target}" "${BACKUP_DIR}/$(basename "${target}").orig"
        echo -e "${GREEN}[BACKUP] Created copy of ${target} in ${BACKUP_DIR}${NC}"
    fi
}

backup_file "${NSSWITCH_CONF}"
if [[ -f "${DHCLIENT_CONF}" ]]; then backup_file "${DHCLIENT_CONF}"; fi
if [[ -f "${PAM_SYS_AUTH}" ]]; then backup_file "${PAM_SYS_AUTH}"; fi
if [[ -f "${PAM_COMMON_AUTH}" ]]; then backup_file "${PAM_COMMON_AUTH}"; fi

# ------------------------------------------------------------------------------
# Break Phase
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[INJECTING FAULTS] Applying production failure scenario...${NC}"

# 1. Break Name Service Switch (NSS) Configuration
# Mechanism: Corrupting service lookup modules. Adding an invalid plugin 'sss_broken' 
# before 'files' and adding '[NOTFOUND=return]' on hosts database to break DNS fallback.
if [[ -f "${NSSWITCH_CONF}" ]]; then
    cat << 'EOF' > "${NSSWITCH_CONF}"
# /etc/nsswitch.conf - Corrupted for LPIC-2 Topic 204 Diagnostic Lab
passwd:         sss_broken files
group:          sss_broken files
shadow:         files
gshadow:        files

hosts:          dns [NOTFOUND=return] files
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files
EOF
fi

# 2. Break DHCP Client Resolver Overrides
# Mechanism: Append erroneous prepend/supersede directives into dhclient.conf that forces 
# dhclient to configure invalid nameservers and static search domains, breaking glibc resolver.
mkdir -p /etc/dhcp
cat << 'EOF' >> "${DHCLIENT_CONF}"
# LPIC-2 Fault Injection
option domain-name-servers 192.0.2.254, 198.51.100.254;
supersede domain-name "invalid.internal.local";
prepend domain-name-servers 127.0.0.1;
request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, host-name;
require domain-name-servers, subnet-mask;
EOF

# 3. Break PAM Authentication Chain (PAM Module Evaluation Stack)
# Mechanism: Misconfigure PAM module control flag. Setting pam_unix to 'requisite' 
# with invalid options and inserting broken pam_ldap.so/pam_sss.so directives.
PAM_TARGET=""
if [[ -f "${PAM_SYS_AUTH}" ]]; then
    PAM_TARGET="${PAM_SYS_AUTH}"
elif [[ -f "${PAM_COMMON_AUTH}" ]]; then
    PAM_TARGET="${PAM_COMMON_AUTH}"
fi

if [[ -n "${PAM_TARGET}" ]]; then
    cat << 'EOF' > "${PAM_TARGET}"
# /etc/pam.d authentication stack - Corrupted for LPIC-2 Topic 204
auth        requisite                     pam_nologin.so
auth        [success=1 default=ignore]    pam_unix.so nullok try_first_pass invalid_option_test
auth        requisite                     pam_deny.so
auth        required                      pam_permit.so
auth        authfailed                    pam_sss.so use_first_pass
account     required                      pam_unix.so
password    sufficient                    pam_unix.so sha512 shadow try_first_pass use_authtok
session     required                      pam_unix.so
EOF
fi

# Apply system changes (e.g. restart networking/dhclient if running)
echo -e "${RED}[FAULT INJECTED] System network client configuration broken successfully.${NC}\n"

# ------------------------------------------------------------------------------
# Student Challenge Notification & Symptoms
# ------------------------------------------------------------------------------
echo -e "${BOLD}====================================================================${NC}"
echo -e "${BOLD}                     STUDENT INCIDENT REPORT                        ${NC}"
echo -e "${BOLD}====================================================================${NC}"
echo -e "INCIDENT SEVERITY: ${RED}CRITICAL${NC}"
echo -e "AFFECTED COMPONENT: Topic 2.4 - Network Client Management (LPIC-2)"
echo -e "DESCRIPTION:"
echo -e "  The system administrator updated network client configurations for LDAP/SSSD,"
echo -e "  DHCP, and PAM. Since the change, local and network identity resolutions are"
echo -e "  failing, DNS lookup fallback is non-functional, and PAM authentication fails."
echo -e ""
echo -e "OBSERVED SYMPTOMS:"
echo -e "  1. Running 'getent passwd' outputs library/module lookup errors or hangs."
echo -e "  2. Network host lookups fail even if entries exist in /etc/hosts due to incorrect"
echo -e "     NSS module traversal logic in /etc/nsswitch.conf."
echo -e "  3. 'dhclient' generated an unusable /etc/resolv.conf populated with non-routable"
echo -e "     nameservers (192.0.2.254, 198.51.100.254) and an unresolvable search domain."
echo -e "  4. Local authentication (su / ssh / pam_tester) fails with PAM stack errors."
echo -e ""
echo -e "YOUR OBJECTIVES:"
echo -e "  1. Audit and repair ${NSSWITCH_CONF}:"
echo -e "     - Fix the 'passwd' and 'group' database configuration order."
echo -e "     - Correct the 'hosts' database resolution order so local (/etc/hosts) is tried"
echo -e "       BEFORE DNS, and remove the premature [NOTFOUND=return] guard."
echo -e "  2. Audit and repair ${DHCLIENT_CONF}:"
echo -e "     - Remove invalid 'supersede' and 'option' directives causing DNS poison."
echo -e "  3. Repair PAM authentication configuration in ${PAM_TARGET}:"
echo -e "     - Fix invalid syntax ('invalid_option_test', 'authfailed' control flag)."
echo -e "     - Restore valid PAM control flags (required, requisite, sufficient, optional)."
echo -e "  4. Verify system operation using standard diagnostic tools:"
echo -e "     - 'getent passwd <user>'"
echo -e "     - 'getent hosts localhost'"
echo -e "     - 'dhclient -v -r && dhclient -v'"
echo -e "     - 'pam_tester' or 'su - <user>'"
echo -e "====================================================================\n"

exit 0

# ==============================================================================
# SOLUTION & TECHNICAL DEEP DIVE (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
# To view the step-by-step resolution, open this script file in an editor.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP SOLUTION & DIAGNOSTIC WALKTHROUGH
# ------------------------------------------------------------------------------
#
# 1. DIAGNOSING AND FIXING /etc/nsswitch.conf
# -------------------------------------------
# Symptom: 'getent passwd' fails or behaves erratically; host resolution fails.
# Internal Mechanics:
#   glibc uses Name Service Switch (NSS) to dynamic-link C libraries matching 
#   libnss_<module>.so.2. When nsswitch.conf lists 'sss_broken', glibc searches 
#   for /lib64/libnss_sss_broken.so.2.
#   For the 'hosts' database, '[NOTFOUND=return]' causes glibc's resolver to terminate
#   search immediately if DNS returns NOTFOUND (NXDOMAIN), preventing it from reading /etc/hosts.
#
# Diagnosis Commands & Expected Outputs:
#   $ getent hosts localhost
#   (Returns empty or fails)
#
#   $ strace -e openat getent passwd
#   openat(AT_FDCWD, "/lib64/libnss_sss_broken.so.2", O_RDONLY|O_CLOEXEC) = -1 ENOENT
#
# Correct /etc/nsswitch.conf Syntax:
#   passwd:         files sss
#   group:          files sss
#   shadow:         files
#   hosts:          files dns
#   networks:       files
#
# Fix Command:
#   sed -i 's/sss_broken files/files sss/g' /etc/nsswitch.conf
#   sed -i 's/hosts:.*dns \[NOTFOUND=return\] files/hosts:          files dns/g' /etc/nsswitch.conf
#
#
# 2. DIAGNOSING AND FIXING /etc/dhcp/dhclient.conf
# ------------------------------------------------
# Symptom: /etc/resolv.conf keeps getting overwritten with broken DNS servers (192.0.2.254).
# Internal Mechanics:
#   'dhclient' reads /etc/dhcp/dhclient.conf upon interface up or lease renewal.
#   Directives like 'supersede domain-name-servers' override values provided by the DHCP server.
#   'prepend' adds IP addresses prior to server-supplied DNS servers.
#
# Diagnosis Command:
#   $ cat /etc/dhcp/dhclient.conf
#   $ dhclient -v -r eth0 && dhclient -v eth0
#   $ cat /etc/resolv.conf
#
# Fix Command:
#   Remove the bad lines injected into /etc/dhcp/dhclient.conf or restore backup:
#   cp /var/backups/lpic2_topic204_breakfix/dhclient.conf.orig /etc/dhcp/dhclient.conf
#   dhclient -r && dhclient
#
#
# 3. DIAGNOSING AND FIXING PAM CONFIGURATION (/etc/pam.d/)
# --------------------------------------------------------
# Symptom: Authentication failures logged in /var/log/auth.log or /var/log/secure.
# Internal Mechanics:
#   PAM syntax structure: <module_type> <control_flag> <module_path> [module_args]
#   Valid module_types: auth, account, password, session.
#   Valid control_flags: required, requisite, sufficient, optional, or complex [...] syntax.
#   In the corrupted state:
#     'authfailed' is NOT a valid PAM control flag (causes PAM parse error).
#     'invalid_option_test' is an unsupported argument for pam_unix.so.
#
# Diagnosis Command:
#   $ tail -f /var/log/auth.log  # (or /var/log/secure on RHEL-based systems)
#   $ su - nobody
#   Output log: "PAM [_pam_load_conf] syntax error /etc/pam.d/system-auth ..."
#
# Correct PAM Auth Stack Example:
#   auth        required      pam_env.so
#   auth        sufficient    pam_unix.so nullok try_first_pass
#   auth        requisite     pam_succeed_if.so user ingroup wheel
#   auth        required      pam_deny.so
#
# Fix Command:
#   Restore backup of the PAM configuration file:
#   cp /var/backups/lpic2_topic204_breakfix/system-auth.orig /etc/pam.d/system-auth
#   # Or for Debian/Ubuntu:
#   cp /var/backups/lpic2_topic204_breakfix/common-auth.orig /etc/pam.d/common-auth
#   pam-auth-update --force  # On Debian/Ubuntu to regenerate PAM stack cleanly
#
#
# 4. VERIFICATION COMMANDS
# ------------------------
# Verify NSS Passwd Database:
#   $ getent passwd root
#   root:x:0:0:root:/root:/bin/bash
#
# Verify NSS Host Resolution:
#   $ getent hosts localhost
#   127.0.0.1       localhost
#
# Verify LDAP/SSSD Client Lookup (if SSSD service active):
#   $ sssd -i -d 6  # Runs SSSD in foreground with debug level 6
#   $ ldapsearch -x -H ldap://localhost -b "dc=example,dc=org"
#
# Verify DHCP Client Lease:
#   $ dhclient -v -d --dry-run
# ==============================================================================