#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 (Exams 201-450 & 202-450, v4.5) - Topic 206: System Security (Weight: 9)
# PRODUCTION BREAK & FIX HANDS-ON LAB: Hardened Security Subsystem Failures
# Author: Senior SRE & Principal Platform Architect
# Official Reference: https://www.lpi.org/our-certifications/lpic-2-overview/
# ==============================================================================
#
# OVERVIEW & ARCHITECTURAL CONTEXT:
# ---------------------------------
# Linux System Security (LPIC-2 Topic 206) encompasses packet filtering
# (iptables/nftables), kernel routing controls (sysctl IP forwarding/rp_filter),
# host access control (TCP Wrappers / hosts.allow / hosts.deny), daemon
# hardening (OpenSSH sshd_config, permissions, ciphers), and authentication
# shadow integrity.
#
# In production, security misconfigurations often manifest as silent dropouts,
# sshd daemon boot failures, broken routing/NAT, or complete admin lockouts.
#
# LAB INSTRUCTIONS FOR STUDENT:
# -----------------------------
# 1. Run this script as root on a disposable virtual machine:
#    sudo bash lpic2_topic206_break_fix.sh
# 2. Review the SYMPTOMS and GOALS presented by the script output.
# 3. Use standard Linux diagnostic CLI tools (ss, iptables-save, journalctl,
#    sshd -t, sysctl, tcpdump, etc.) to investigate and resolve the issue.
# 4. Do NOT read the commented solution at the bottom until you attempt fixing!
#
# ==============================================================================

set -euo pipefail

# Color Palette for CLI output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_BACKUP_DIR="/var/backups/lpic2_topic206_lab"

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This break-and-fix scenario must be executed as root!${NC}" >&2
        exit 1
    fi
}

function print_banner() {
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${YELLOW}  LPIC-2 TOPIC 206: SYSTEM SECURITY - BREAK & FIX ADVANCED SCENARIO   ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "Target Certification : LPIC-2 (Exam 202-450 v4.5)"
    echo -e "Topic 206 Coverage   : 206.1 Router Config, 206.2 Traffic Management,"
    echo -e "                       206.3 Securing Network Services (SSH, TCP Wrappers)"
    echo -e "Official Reference   : https://www.lpi.org/our-certifications/lpic-2-overview/"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
}

function apply_breakage() {
    echo -e "${YELLOW}[+] Creating configuration backups in ${LOG_BACKUP_DIR}...${NC}"
    mkdir -p "${LOG_BACKUP_DIR}"

    # Backup files before modifying
    [[ -f /etc/sysctl.d/99-ipforward.conf ]] && cp /etc/sysctl.d/99-ipforward.conf "${LOG_BACKUP_DIR}/"
    [[ -f /etc/hosts.deny ]] && cp /etc/hosts.deny "${LOG_BACKUP_DIR}/"
    [[ -f /etc/hosts.allow ]] && cp /etc/hosts.allow "${LOG_BACKUP_DIR}/"
    [[ -f /etc/shadow ]] && cp /etc/shadow "${LOG_BACKUP_DIR}/"
    
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "${LOG_BACKUP_DIR}/iptables.rules.bak" || true
    fi

    echo -e "${YELLOW}[+] Injecting Level-1 Failure: Disabling Kernel IPv4 Packet Forwarding...${NC}"
    # Subtopic 206.1 - Router Configuration
    cat <<EOF > /etc/sysctl.d/99-lpic2-security.conf
# LPIC-2 Lab Security Lockdown
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
EOF
    sysctl -p /etc/sysctl.d/99-lpic2-security.conf >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=0 >/dev/null

    echo -e "${YELLOW}[+] Injecting Level-2 Failure: Restrictive iptables Policies without Loopback / Stateful Rules...${NC}"
    # Subtopic 206.2 - Managing Network Traffic
    if command -v iptables >/dev/null 2>&1; then
        iptables -F
        iptables -X
        iptables -t nat -F || true
        iptables -t nat -X || true
        # Drop incoming and forwarded packets, forgetting ESTABLISHED,RELATED and loopback
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT
        # Deliberately block loopback traffic to break local inter-process security checks
        iptables -A INPUT -i lo -j DROP
    fi

    echo -e "${YELLOW}[+] Injecting Level-3 Failure: TCP Wrappers Lockdown & Syntax Error...${NC}"
    # Subtopic 206.3 - Securing Network Services (TCP Wrappers / hosts.allow / hosts.deny)
    cat <<EOF > /etc/hosts.deny
# Restrict all services by default
ALL: ALL
EOF

    cat <<EOF > /etc/hosts.allow
# Syntax error in daemon name and subnet syntax
sshd_daemon_invalid: 192.168.1.0/255.255.255.0 : ALLOW
ALL: 127.0.0.1 : ALLOW
EOF

    echo -e "${YELLOW}[+] Injecting Level-4 Failure: OpenSSH Hardening Misconfiguration & Key Permissions...${NC}"
    # Subtopic 206.3 - OpenSSH Hardening
    mkdir -p /etc/ssh/sshd_config.d/
    cat <<EOF > /etc/ssh/sshd_config.d/99-lpic2-break.conf
# LPIC-2 Hardening Lab
PermitRootLogin no
PasswordAuthentication no
AllowUsers non_existent_admin_user
# Invalid configuration directive causing daemon start failure
BadConfigurationDirectiveValue invalid_cipher_suite
EOF

    # Insecure permission setup on shadow file
    chmod 0666 /etc/shadow

    echo -e "\n${RED}[!] BREAKAGE APPLIED SUCCESSFULLY.${NC}\n"
}

function print_student_challenge() {
    cat <<'EOF'
================================================================================
                        STUDENT DIAGNOSTIC CHALLENGE
================================================================================

[PROBLEM STATEMENT & SYMPTOMS]
You have been called to troubleshoot a hardened Linux server that recently
underwent a security compliance rollout. Multiple service and network failures
have been reported by production engineering:

1. Local services using loopback sockets (e.g. 127.0.0.1) are timing out or failing.
2. IP Routing / Packet Forwarding between interfaces is broken, failing NAT/router role.
3. TCP Wrappers (/etc/hosts.allow and /etc/hosts.deny) are rejecting SSH connections.
4. SSH daemon configuration validation (`sshd -t`) fails with a syntax error,
   preventing service reload/restart.
5. The `/etc/shadow` file permissions fail security compliance checks (world-writable).

[STUDENT GOALS]
1. Diagnose and fix the iptables netfilter policies:
   - Restore IPv4 forwarding in kernel sysctl (`net.ipv4.ip_forward = 1`).
   - Allow loopback interface (`lo`) traffic in iptables.
   - Configure stateful firewalling (`ESTABLISHED,RELATED`) on INPUT chain.
2. Fix TCP Wrappers configuration:
   - Correct `/etc/hosts.allow` syntax for `sshd` and local networks.
3. Repair OpenSSH configuration:
   - Identify and fix invalid syntax in `/etc/ssh/sshd_config.d/99-lpic2-break.conf`.
   - Ensure valid user access rules or correct `AllowUsers` directive.
   - Verify syntax with `sshd -t` and reload the service.
4. Restore strict standard Linux permissions on `/etc/shadow` (`0640` or `0600` root:shadow).

[REQUIRED DIAGNOSTIC COMMANDS TO USE]
- `sysctl -a | grep ip_forward`
- `iptables -L -n -v --line-numbers`
- `cat /etc/hosts.allow` and `cat /etc/hosts.deny`
- `sshd -t`
- `ls -l /etc/shadow`

================================================================================
EOF
}

check_root
print_banner
apply_breakage
print_student_challenge

exit 0

# ==============================================================================
#                      STEP-BY-STEP SOLUTION (SPOILERS BELOW)
# ==============================================================================
#
# STEP 1: Diagnose & Repair Kernel Packet Forwarding (Subtopic 206.1)
# ------------------------------------------------------------------
# Check current IP forwarding state:
#   # sysctl net.ipv4.ip_forward
# Output expected:
#   net.ipv4.ip_forward = 0
#
# Fix: Edit /etc/sysctl.d/99-lpic2-security.conf or add custom sysctl file:
#   # echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
#   # sysctl --system
# Verify:
#   # sysctl net.ipv4.ip_forward
# Output expected:
#   net.ipv4.ip_forward = 1
#
# ------------------------------------------------------------------
# STEP 2: Diagnose & Repair Netfilter / iptables Rules (Subtopic 206.2)
# ------------------------------------------------------------------
# Check existing iptables rules:
#   # iptables -L -n -v --line-numbers
# Notice the DROP rule on loopback 'lo' interface:
#   Chain INPUT (policy DROP 0 packets, 0 bytes)
#   num   pkts bytes target     prot opt in     out     source               destination
#   1        0     0 DROP       all  --  lo     *       0.0.0.0/0            0.0.0.0/0
#
# Fix: Remove the loopback drop rule and add loopback + stateful rules:
#   # iptables -D INPUT -i lo -j DROP
#   # iptables -A INPUT -i lo -j ACCEPT
#   # iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
#   # iptables -A INPUT -p tcp --dport 22 -j ACCEPT
#
# Save iptables rules (on Debian/Ubuntu using iptables-persistent or rhel/centos):
#   # iptables-save > /etc/iptables/rules.v4  (or netfilter-persistent save)
#
# ------------------------------------------------------------------
# STEP 3: Diagnose & Repair TCP Wrappers Access Control (Subtopic 206.3)
# ------------------------------------------------------------------
# Check hosts.deny and hosts.allow:
#   # cat /etc/hosts.deny
#   ALL: ALL
#   # cat /etc/hosts.allow
#   sshd_daemon_invalid: 192.168.1.0/255.255.255.0 : ALLOW
#
# Mechanics: TCP wrappers (libwrap) match daemon executable names (e.g. 'sshd').
# 'sshd_daemon_invalid' does not match the process name 'sshd'.
#
# Fix: Edit /etc/hosts.allow to use valid daemon name 'sshd':
#   # cat <<EOF > /etc/hosts.allow
#   sshd: 127.0.0.1 LOCAL 192.168.1.0/255.255.255.0 : ALLOW
#   EOF
#
# Verify TCP wrappers configuration:
#   # tcpdmatch sshd 127.0.0.1
# Output expected:
#   client:   address  127.0.0.1
#   server:   process  sshd
#   access:   granted
#
# ------------------------------------------------------------------
# STEP 4: Diagnose & Repair OpenSSH Configuration Syntax (Subtopic 206.3)
# ------------------------------------------------------------------
# Test SSH daemon configuration syntax:
#   # sshd -t
# Output expected:
#   /etc/ssh/sshd_config.d/99-lpic2-break.conf: line 6: Bad configuration option: BadConfigurationDirectiveValue
#
# Fix: Remove or correct the invalid file:
#   # rm -f /etc/ssh/sshd_config.d/99-lpic2-break.conf
# Or edit it to contain valid directives:
#   # cat <<EOF > /etc/ssh/sshd_config.d/99-lpic2-hardened.conf
#   PermitRootLogin prohibit-password
#   PasswordAuthentication yes
#   X11Forwarding no
#   MaxAuthTries 4
#   EOF
#
# Test syntax again:
#   # sshd -t
# (No output indicates syntax is valid)
#
# Reload sshd daemon:
#   # systemctl reload sshd || systemctl reload ssh
#
# ------------------------------------------------------------------
# STEP 5: Repair /etc/shadow Security Permissions (Subtopic 206.3 / 201.1)
# ------------------------------------------------------------------
# Check file permissions:
#   # ls -l /etc/shadow
# Output expected:
#   -rw-rw-rw- 1 root shadow ... /etc/shadow  (INSECURE!)
#
# Fix: Reset permissions to 0640 owned by root:shadow (or 0600 root:root depending on distro):
#   # chmod 0640 /etc/shadow
#   # chown root:shadow /etc/shadow
# Verify:
#   # ls -l /etc/shadow
# Output expected:
#   -rw-r----- 1 root shadow ... /etc/shadow
#
# ==============================================================================
# VERIFICATION CHECKLIST FOR LPIC-2 EXAM 202-450 TOPIC 206:
# [✓] sysctl net.ipv4.ip_forward = 1
# [✓] iptables allows lo and ESTABLISHED,RELATED connections
# [✓] hosts.allow correctly specifies 'sshd' process name
# [✓] sshd -t returns 0 (clean configuration)
# [✓] /etc/shadow has 0640 permissions (root:shadow)
# ==============================================================================