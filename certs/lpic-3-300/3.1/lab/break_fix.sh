#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Exam 300-300 (v3.0) - Topic 3.1: Samba Share Configuration
# Exam Weight: 20
# Official Reference: https://www.lpi.org/our-certifications/lpic-3-300-overview/
#
# Lab Type: Break & Fix - Production Troubleshooting Simulation
# Target Environment: Disposable Linux Lab VM (RHEL/AlmaLinux/Debian/Ubuntu)
# ==============================================================================

set -euo pipefail

RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] This script must be executed with root privileges.${NC}" >&2
   exit 1
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}    LPIC-3 300-300 Topic 3.1: Samba Share Configuration Lab Setup     ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# 1. Package Installation Check
echo -e "\n${YELLOW}[1/4] Verifying required Samba binaries...${NC}"
if command -v apt-get &>/dev/null; then
    pkg_mgr="apt-get"
    packages=(samba samba-client smbclient cifs-utils acl)
elif command -v dnf &>/dev/null; then
    pkg_mgr="dnf"
    packages=(samba samba-client cifs-utils acl)
else
    echo -e "${RED}[ERROR] Supported package manager (apt-get/dnf) not found.${NC}" >&2
    exit 1
fi

for pkg in "${packages[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null && ! rpm -q "$pkg" &>/dev/null; then
        echo -e "${YELLOW}Installing missing package: ${pkg}...${NC}"
        $pkg_mgr update -y &>/dev/null || true
        $pkg_mgr install -y "$pkg" &>/dev/null
    fi
done

# 2. Base Environment Provisioning
echo -e "\n${YELLOW}[2/4] Provisioning lab users, groups, and directory hierarchy...${NC}"

# Clean up previous runs if any
groupdel finance_dept &>/dev/null || true
userdel -r finanalyst &>/dev/null || true
rm -rf /srv/samba/finance /etc/samba/smb.conf.bak.*

# Create group and user
groupadd finance_dept
useradd -M -s /sbin/nologin -g finance_dept finanalyst
echo "FinAnalyst2026!" | passwd --stdin finanalyst &>/dev/null || echo "finanalyst:FinAnalyst2026!" | chpasswd

# Set up Samba passdb entry
(echo "FinAnalyst2026!"; echo "FinAnalyst2026!") | smbpasswd -a -s finanalyst &>/dev/null
smbpasswd -e finanalyst &>/dev/null

# Backup original smb.conf
if [[ -f /etc/samba/smb.conf ]]; then
    cp /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%s)"
fi

# 3. Inject Production Breakages (Controlled Chaos)
echo -e "\n${YELLOW}[3/4] Injecting controlled misconfigurations into Samba & OS...${NC}"

# Create actual physical directory
mkdir -p /srv/samba/finance
touch /srv/samba/finance/quarterly_report.xlsx
echo "CONFIDENTIAL FINANCIAL DATA" > /srv/samba/finance/quarterly_report.xlsx

# BREAKAGE 1: Incorrect POSIX permissions (Root-only access, denying Samba daemon worker)
chmod 0700 /srv/samba/finance
chown root:root /srv/samba/finance

# BREAKAGE 2: SELinux mislabeling (if SELinux is active)
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    chcon -t user_home_t /srv/samba/finance &>/dev/null || true
    chcon -t user_home_t /srv/samba/finance/quarterly_report.xlsx &>/dev/null || true
fi

# BREAKAGE 3: Conflicting and erroneous smb.conf directives
cat << 'EOF' > /etc/samba/smb.conf
[global]
    workgroup = SAMBA
    security = user
    passdb backend = tdbsam
    printing = cups
    printcap name = cups
    load printers = yes
    cups options = raw
    log file = /var/log/samba/log.%m
    max log size = 50

[finance_data]
    comment = Financial Department Production Share
    path = /srv/samba/finance_reports
    browseable = yes
    read only = yes
    writable = yes
    valid users = @financedept finanalyst
    invalid users = finanalyst
    write list = @finance_dept
    force user = finanalyst
    force group = finance_dept
    create mask = 0640
    directory mask = 0750
    hosts allow = 192.168.254.0/24
EOF

# Restart Samba services
if systemctl list-unit-files | grep -q smbd; then
    systemctl restart smbd nmbd &>/dev/null || true
elif systemctl list-unit-files | grep -q smb; then
    systemctl restart smb nmb &>/dev/null || true
fi

# 4. Scenario Briefing & Troubleshooting Mission
echo -e "\n${GREEN}[4/4] Break & Fix Lab Environment Ready!${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "${YELLOW}INCIDENT TICKET: #SRE-30031 - Samba Share Mount & Access Failure${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "Severity: Critical (P1)"
echo -e "Target Share Name: [finance_data]"
echo -e "Target User Credential: User = 'finanalyst', Password = 'FinAnalyst2026!'\n"

echo -e "${YELLOW}[EXPECTED SYMPTOMS REPORTED BY CLIENTS]${NC}"
echo -e "1. Executing 'smbclient //localhost/finance_data -U finanalyst' yields:"
echo -e "   - 'NT_STATUS_BAD_NETWORK_NAME' or 'NT_STATUS_ACCESS_DENIED'."
echo -e "2. Mounting via CIFS fails with 'Permission denied' or 'No such file or directory'."
echo -e "3. User 'finanalyst' cannot write or read files even when authenticated."
echo -e "4. Configuration verification tools highlight parameter warnings.\n"

echo -e "${YELLOW}[YOUR MISSION]${NC}"
echo -e "Diagnose and resolve all configuration errors, filesystem permission blocks,"
echo -e "access control rules, and SELinux label mismatches. Ensure user 'finanalyst'"
echo -e "can connect via SMB, list contents, and create new files under [finance_data].\n"

echo -e "${YELLOW}[REQUIRED DIAGNOSTIC COMMANDS FOR EXAM PRACTICE]${NC}"
echo -e " - testparm -s"
echo -e " - smbclient -L localhost -U finanalyst"
echo -e " - smbclient //localhost/finance_data -U finanalyst"
echo -e " - ls -ldZ /srv/samba/finance"
echo -e " - getfacl /srv/samba/finance"
echo -e " - tail -f /var/log/samba/log.*"
echo -e "${BLUE}======================================================================${NC}\n"

exit 0

# ==============================================================================
# LPIC-3 300-300 TOPIC 3.1: STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION
# ==============================================================================
#
# BROKEN COMPONENTS ANALYSIS:
# ---------------------------
# 1. smb.conf Path Mismatch:
#    Configured 'path = /srv/samba/finance_reports' does not exist on disk.
#    Real path: '/srv/samba/finance'.
#    Symptom: NT_STATUS_BAD_NETWORK_NAME upon authentication.
#
# 2. smb.conf Conflicting Directives:
#    a) 'read only = yes' conflicts with 'writable = yes'. Samba parses top-to-bottom;
#       last parameter wins, but setting both creates logical ambiguities.
#    b) 'valid users = @financedept finanalyst' vs 'invalid users = finanalyst'.
#       'invalid users' always takes precedence over 'valid users', blocking finanalyst.
#    c) Group syntax error: '@financedept' is referenced, but actual system group is 'finance_dept'.
#
# 3. smb.conf Network Access Restriction:
#    'hosts allow = 192.168.254.0/24' restricts connections to an unreachable subnet,
#    rejecting connections from 127.0.0.1 / localhost.
#    Symptom: NT_STATUS_ACCESS_DENIED or immediate connection reset.
#
# 4. OS Filesystem Permissions (POSIX & Ownership):
#    Directory permissions are set to '0700 root:root'. The Samba worker process
#    impersonating user/group cannot access the directory path.
#    Required: '0770 root:finance_dept' or appropriate permissions.
#
# 5. SELinux Context Security Label:
#    Context is set to 'user_home_t'. Samba daemon (smbd_t) is blocked by SELinux policy.
#    Required: 'samba_share_t'.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP RESOLUTION COMMANDS:
# ------------------------------------------------------------------------------
#
# Step 1: Diagnose smb.conf syntax errors and runtime parameters
# # testparm -s /etc/samba/smb.conf
#
# Step 2: Edit /etc/samba/smb.conf to fix share parameter definitions
# Replace the broken [finance_data] block with valid configuration:
#
# Cat /etc/samba/smb.conf:
# ------------------------------------------------------------------------------
# [global]
#     workgroup = SAMBA
#     security = user
#     passdb backend = tdbsam
#     log file = /var/log/samba/log.%m
#     max log size = 50
#
# [finance_data]
#     comment = Financial Department Production Share
#     path = /srv/samba/finance
#     browseable = yes
#     read only = no
#     writable = yes
#     valid users = @finance_dept finanalyst
#     force group = finance_dept
#     create mask = 0660
#     directory mask = 0770
#     hosts allow = 127.0.0.1 192.168.0.0/16 10.0.0.0/8
# ------------------------------------------------------------------------------
#
# Step 3: Validate smb.conf syntax after edits
# # testparm -s
#
# Step 4: Fix POSIX Filesystem Ownership & Permissions
# # chown -R root:finance_dept /srv/samba/finance
# # chmod -R 0770 /srv/samba/finance
# # chmod g+s /srv/samba/finance    # Set SGID bit to inherit group ownership
#
# Step 5: Fix SELinux Contexts (Persistent & Immediate)
# # semanage fcontext -a -t samba_share_t "/srv/samba/finance(/.*)?"
# # restorecon -Rv /srv/samba/finance
# (Or temporary fix if semanage not installed: chcon -Rt samba_share_t /srv/samba/finance)
#
# Step 6: Reload Samba Services
# # systemctl reload smbd nmbd || systemctl reload smb nmb
#
# Step 7: Verify Fix via CLI
# # smbclient -L localhost -U finanalyst%FinAnalyst2026!
# # smbclient //localhost/finance_data -U finanalyst%FinAnalyst2026! -c "ls; put /etc/hosts test_upload.txt; ls"
#
# Expected output on successful verification:
# smb: \> ls
#   .                                   D        0  Thu Aug  6 12:00:00 2026
#   ..                                  D        0  Thu Aug  6 12:00:00 2026
#   quarterly_report.xlsx               A       27  Thu Aug  6 12:00:00 2026
#   test_upload.txt                     A     158  Thu Aug  6 12:00:00 2026
# ==============================================================================