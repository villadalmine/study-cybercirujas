#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Exam 300-300 (v3.0) - Topic 2.1: Samba and Active Directory Domains
# Break & Fix Lab Scenario: AD DC Kerberos, Winbind & ID Mapping Failure
#
# Exam: LPIC-3 300-300 (Version 3.0)
# Topic: 2.1 Samba and Active Directory Domains (Weight: 20)
# References:
#   - LPI LPIC-3 300 Objectives: https://www.lpi.org/our-certifications/lpic-3-300-overview/
#   - Samba Official AD DC Setup: https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller
#   - Samba ID Mapping Guide: https://wiki.samba.org/index.php/Idmap_config_ad
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/tmp/lpic3_topic21_lab"
BACKUP_DIR="${LAB_DIR}/backups"
SMB_CONF="/etc/samba/smb.conf"
KRB5_CONF="/etc/krb5.conf"
NSS_CONF="/etc/nsswitch.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed as root.${NC}" >&2
        exit 1
    fi
}

print_header() {
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${BLUE} LPIC-3 300-300 Topic 2.1: Samba & AD Domains Break & Fix Challenge${NC}"
    echo -e "${BLUE}======================================================================${NC}"
}

print_usage() {
    echo "Usage: $0 {--break|--status|--restore|--help}"
    echo
    echo "Commands:"
    echo "  --break    Inject production faults into Samba AD DC & Kerberos/Winbind configs"
    echo "  --status   Inspect current system state and diagnose issues"
    echo "  --restore  Revert system configurations back to the initial working state"
    echo "  --help     Display problem statement, symptoms, and target objectives"
}

init_environment() {
    mkdir -p "${BACKUP_DIR}"
    
    # Ensure baseline directory structure for Samba if not present
    mkdir -p /etc/samba /var/lib/samba/private /var/log/samba

    # Create dummy baseline configurations if missing for standalone testing
    if [[ ! -f "${SMB_CONF}" ]]; then
        cat <<'EOF' > "${SMB_CONF}"
[global]
    netbios name = ADDC01
    realm = AD.CORP.EXAMPLE.COM
    workgroup = CORP
    server role = active directory domain controller
    dns forwarder = 8.8.8.8
    idmap_ldb:enum active = yes
    idmap config * : backend = tdb
    idmap config * : range = 3000000-4000000
    idmap config CORP : backend = rid
    idmap config CORP : range = 10000-99999

[sysvol]
    path = /var/lib/samba/sysvol
    read only = No

[netlogon]
    path = /var/lib/samba/sysvol/ad.corp.example.com/scripts
    read only = No
EOF
    fi

    if [[ ! -f "${KRB5_CONF}" ]]; then
        cat <<'EOF' > "${KRB5_CONF}"
[libdefaults]
    default_realm = AD.CORP.EXAMPLE.COM
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    AD.CORP.EXAMPLE.COM = {
        kdc = 127.0.0.1:88
        admin_server = 127.0.0.1
        default_domain = ad.corp.example.com
    }

[domain_realm]
    .ad.corp.example.com = AD.CORP.EXAMPLE.COM
    ad.corp.example.com = AD.CORP.EXAMPLE.COM
EOF
    fi

    if [[ ! -f "${NSS_CONF}" ]]; then
        cat <<'EOF' > "${NSS_CONF}"
passwd:         files winbind
group:          files winbind
shadow:         files
hosts:          files dns
networks:       files
protocols:      files
services:       files
ethers:         files
rpc:            files
EOF
    fi
}

backup_configs() {
    echo -e "${YELLOW}[*] Creating configuration backups in ${BACKUP_DIR}...${NC}"
    cp "${SMB_CONF}" "${BACKUP_DIR}/smb.conf.bak"
    cp "${KRB5_CONF}" "${BACKUP_DIR}/krb5.conf.bak"
    cp "${NSS_CONF}" "${BACKUP_DIR}/nsswitch.conf.bak"
    echo -e "${GREEN}[+] Backups successfully created.${NC}"
}

break_system() {
    check_root
    init_environment
    backup_configs

    echo -e "${YELLOW}[*] Injecting controlled production faults for Topic 2.1...${NC}"

    # Fault 1: Sabotage Kerberos KDC configuration (Realm casing & wrong port/kdc)
    sed -i 's/default_realm = AD.CORP.EXAMPLE.COM/default_realm = ad.corp.example.com/g' "${KRB5_CONF}"
    sed -i 's/127.0.0.1:88/127.0.0.1:8888/g' "${KRB5_CONF}"

    # Fault 2: Sabotage Name Service Switch (NSS) - remove winbind integration
    sed -i 's/passwd:         files winbind/passwd:         files/g' "${NSS_CONF}"
    sed -i 's/group:          files winbind/group:          files/g' "${NSS_CONF}"

    # Fault 3: Break Samba ID Mapping & Server Role in smb.conf
    sed -i 's/server role = active directory domain controller/server role = member server/g' "${SMB_CONF}"
    sed -i 's/idmap config CORP : backend = rid/idmap config CORP : backend = invalid_backend/g' "${SMB_CONF}"
    sed -i '/idmap config CORP : range/d' "${SMB_CONF}"

    # Fault 4: Restrict permissions on krb5.conf to block non-root ticket generation
    chmod 0600 "${KRB5_CONF}"

    echo -e "${RED}[!] System has been intentionally broken!${NC}"
    echo -e "${YELLOW}Run '$0 --help' to review the issue symptoms and target objectives.${NC}"
}

show_help() {
    print_header
    cat <<'EOF'
SCENARIO DESCRIPTION:
You are tasked with restoring a critical Enterprise Samba 4 Active Directory
Domain Controller (AD DC) and domain-joined identity node. Following a misconfiguration 
by a junior administrator, domain users are unable to authenticate via Kerberos, 
domain identity resolution (NSS) is broken, and Samba fail to parse its ID mapping engine.

STUDENT OBJECTIVES:
1. Identify and fix Kerberos realm specification and KDC socket configuration errors.
2. Restore Name Service Switch (NSS) Winbind resolution for AD domain users and groups.
3. Repair smb.conf Active Directory Domain Controller role and ID mapping settings.
4. Verify Kerberos ticket acquisition (kinit) and NSS enumeration (getent / wbinfo).

EXPECTED SYMPTOMS & DIAGNOSTIC LAB EVIDENCE:
- 'kinit Administrator@AD.CORP.EXAMPLE.COM' fails with:
  "kinit: KDC reply did not match expectations while getting initial credentials"
  or "kinit: Cannot contact any KDC for realm".
- 'wbinfo -u' or 'getent passwd' fails to list AD domain accounts.
- 'testparm -v' reports syntax errors regarding idmap config backends.
- Samba log files (/var/log/samba/log.samba) report invalid server role mismatches.

VERIFICATION COMMANDS:
- testparm -s
- kinit Administrator@AD.CORP.EXAMPLE.COM
- klist
- wbinfo -p
- getent passwd
EOF
}

check_status() {
    check_root
    print_header
    echo -e "${YELLOW}[*] Performing diagnostic verification of Samba AD DC environment...${NC}\n"

    # Test 1: Check testparm syntax
    echo -n "[1/4] Checking Samba configuration syntax (testparm)... "
    if testparm -s "${SMB_CONF}" &>/dev/null; then
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${RED}[FAILED] (Syntax errors detected in smb.conf)${NC}"
    fi

    # Test 2: Check NSS Winbind integration
    echo -n "[2/4] Checking /etc/nsswitch.conf winbind binding... "
    if grep -qE '^passwd:.*winbind' "${NSS_CONF}" && grep -qE '^group:.*winbind' "${NSS_CONF}"; then
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${RED}[FAILED] (Winbind missing from passwd/group entries)${NC}"
    fi

    # Test 3: Check krb5.conf realm & port configuration
    echo -n "[3/4] Checking Kerberos default realm configuration... "
    if grep -q "default_realm = AD.CORP.EXAMPLE.COM" "${KRB5_CONF}" && grep -q "127.0.0.1:88" "${KRB5_CONF}"; then
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${RED}[FAILED] (Invalid realm case or KDC port misconfiguration)${NC}"
    fi

    # Test 4: Check file permissions
    echo -n "[4/4] Checking /etc/krb5.conf permissions... "
    local perms
    perms=$(stat -c "%a" "${KRB5_CONF}")
    if [[ "${perms}" == "644" ]]; then
        echo -e "${GREEN}[OK] (644)${NC}"
    else
        echo -e "${RED}[FAILED] (Current perms: ${perms}, expected 644)${NC}"
    fi
}

restore_system() {
    check_root
    echo -e "${YELLOW}[*] Restoring configurations from backups...${NC}"

    if [[ -d "${BACKUP_DIR}" ]]; then
        [[ -f "${BACKUP_DIR}/smb.conf.bak" ]] && cp "${BACKUP_DIR}/smb.conf.bak" "${SMB_CONF}"
        [[ -f "${BACKUP_DIR}/krb5.conf.bak" ]] && cp "${BACKUP_DIR}/krb5.conf.bak" "${KRB5_CONF}"
        [[ -f "${BACKUP_DIR}/nsswitch.conf.bak" ]] && cp "${BACKUP_DIR}/nsswitch.conf.bak" "${NSS_CONF}"
        chmod 644 "${KRB5_CONF}"
        echo -e "${GREEN}[+] Configurations restored successfully.${NC}"
    else
        echo -e "${RED}[ERROR] Backup directory ${BACKUP_DIR} does not exist.${NC}" >&2
        exit 1
    fi
}

# Command dispatch
case "${1:-}" in
    --break)
        break_system
        ;;
    --status)
        check_status
        ;;
    --restore)
        restore_system
        ;;
    --help)
        show_help
        ;;
    *)
        print_usage
        exit 1
        ;;
esac

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & TROUBLESHOOTING GUIDE (SOLUCION PASO A PASO)
# ==============================================================================
#
# ISSUE 1: Kerberos Authentication Failure (kinit: Cannot contact any KDC)
# ------------------------------------------------------------------------------
# Diagnostic Steps:
#   1. Execute kinit to check ticket acquisition:
#      $ kinit Administrator@AD.CORP.EXAMPLE.COM
#      Output: kinit: Cannot contact any KDC for realm 'ad.corp.example.com' while getting initial credentials
#
#   2. Check /etc/krb5.conf for realm naming conventions and KDC ports:
#      - Kerberos REALM names MUST be strictly uppercase (e.g., AD.CORP.EXAMPLE.COM).
#      - Verify the KDC port assignment. Standard Kerberos operates on UDP/TCP port 88.
#
# Remediation:
#   Edit /etc/krb5.conf:
#   ```ini
#   [libdefaults]
#       default_realm = AD.CORP.EXAMPLE.COM
#
#   [realms]
#       AD.CORP.EXAMPLE.COM = {
#           kdc = 127.0.0.1:88
#           admin_server = 127.0.0.1
#       }
#   ```
#   Fix file permissions:
#   # chmod 644 /etc/krb5.conf
#
#
# ISSUE 2: Samba AD DC Server Role & ID Mapping Corruption
# ------------------------------------------------------------------------------
# Diagnostic Steps:
#   1. Validate smb.conf using testparm:
#      # testparm -s /etc/samba/smb.conf
#      Output: Error loading services: Invalid idmap backend requested
#
#   2. Verify the server role:
#      Samba AD DCs require 'server role = active directory domain controller'.
#      ID mapping backends for domains typically use 'rid' or 'ad' backends.
#
# Remediation:
#   Edit /etc/samba/smb.conf under [global]:
#   ```ini
#   [global]
#       server role = active directory domain controller
#       idmap config * : backend = tdb
#       idmap config * : range = 3000000-4000000
#       idmap config CORP : backend = rid
#       idmap config CORP : range = 10000-99999
#   ```
#
#
# ISSUE 3: Name Service Switch (NSS) Winbind User/Group Lookups Missing
# ------------------------------------------------------------------------------
# Diagnostic Steps:
#   1. Verify if system calls can resolve Active Directory accounts:
#      # getent passwd Administrator
#      (Returns nothing even though wbinfo -u lists accounts)
#
#   2. Inspect /etc/nsswitch.conf database lines for passwd and group:
#      Ensure 'winbind' is listed after 'files'.
#
# Remediation:
#   Edit /etc/nsswitch.conf:
#   ```conf
#   passwd:         files winbind
#   group:          files winbind
#   ```
#
#
# FINAL VERIFICATION PROTOCOL:
# ------------------------------------------------------------------------------
# 1. Test Samba syntax:
#    # testparm -s
#
# 2. Acquire Kerberos TGT:
#    # kinit Administrator@AD.CORP.EXAMPLE.COM
#    # klist
#
# 3. Test Winbind & NSS integration:
#    # wbinfo -p
#    # wbinfo -u
#    # getent passwd
#
# 4. Verify script status:
#    # ./break_and_fix.sh --status
# ==============================================================================