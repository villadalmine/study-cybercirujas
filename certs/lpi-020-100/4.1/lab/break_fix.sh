#!/usr/bin/env bash
# ==============================================================================
# CNCF / LPI Security Essentials (020-100 v1.0) Production Break & Fix Lab
# Topic 4.1: Network and Service Security (Exam Weight: 20)
# Reference: https://www.lpi.org/our-certifications/security-essentials-overview/
#
# SCENARIO: "Network Security & Service Isolation Outage"
# A junior SRE attempted to harden a Linux production node using packet filtering,
# SSH service interface binding, and StrictModes file permission policies.
# The automation script contained flaws that locked out external management,
# broke local loopback IPC, prevented web application traffic, and rejected SSH authentication.
#
# YOUR TASK:
# 1. Execute this script to apply the broken state: `sudo ./break_and_fix.sh break`
# 2. Diagnose the root causes using standard tools (`ss`, `iptables`, `journalctl`, `ls`).
# 3. Repair the firewall, SSH service binding, stateful packet inspection, and key file security.
# 4. Verify your solution: `sudo ./break_and_fix.sh check`
# ==============================================================================

set -eo pipefail

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"
COLOR_RESET="\033[0m"

LAB_USER="sre_student"
LAB_DIR="/home/${LAB_USER}"
SSH_CONFIG="/etc/ssh/sshd_config"
IPTABLES_BAK="/tmp/iptables_lab_orig.bak"
SSHD_BAK="/tmp/sshd_config_lab_orig.bak"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLOR_RED}[ERROR] This lab script must be executed with root privileges (sudo).${COLOR_RESET}" >&2
        exit 1
    fi
}

detect_ssh_service() {
    if systemctl is-active --quiet sshd; then
        echo "sshd"
    elif systemctl is-active --quiet ssh; then
        echo "ssh"
    else
        # Default fallback depending on OS family
        if command -v redhat-release &>/dev/null; then
            echo "sshd"
        else
            echo "ssh"
        fi
    fi
}

start_dummy_web_service() {
    echo -e "${COLOR_CYAN}[+] Provisioning dummy HTTP application service on TCP port 80...${COLOR_RESET}"
    cat << 'EOF' > /tmp/dummy_web.py
import http.server
import socketserver

PORT = 80
Handler = http.server.SimpleHTTPRequestHandler

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", PORT), QuietHandler) as httpd:
    httpd.serve_forever()
EOF

    cat << 'EOF' > /etc/systemd/system/lab-web.service
[Unit]
Description=LPI Lab Dummy Web Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /tmp/dummy_web.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now lab-web.service &>/dev/null || true
}

do_break() {
    check_root
    SSH_SVC=$(detect_ssh_service)

    echo -e "${COLOR_YELLOW}[!] BACKUP: Preserving original network & service state...${COLOR_RESET}"
    iptables-save > "${IPTABLES_BAK}" 2>/dev/null || true
    cp "${SSH_CONFIG}" "${SSHD_BAK}" 2>/dev/null || true

    start_dummy_web_service

    # Create lab user for SSH key permission testing
    if ! id "${LAB_USER}" &>/dev/null; then
        useradd -m -s /bin/bash "${LAB_USER}"
    fi

    mkdir -p "${LAB_DIR}/.ssh"
    echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3LabTestKeyDummySecurityEssentials020100 student@lpi" > "${LAB_DIR}/.ssh/authorized_keys"
    chown -R "${LAB_USER}:${LAB_USER}" "${LAB_DIR}/.ssh"

    echo -e "${COLOR_RED}[!] INJECTING FAULTS: Breaking Network and Service Security configuration...${COLOR_RESET}"

    # 1. SSH Service Configuration Faults
    # - Bind SSH exclusively to loopback interface (127.0.0.1) instead of 0.0.0.0 / ::
    # - Change SSH port to non-standard 2222
    # - Keep StrictModes enabled (which rejects ssh login if directory/file permissions are overly permissive)
    sed -i '/^ListenAddress/d' "${SSH_CONFIG}"
    sed -i '/^Port /d' "${SSH_CONFIG}"
    echo "ListenAddress 127.0.0.1" >> "${SSH_CONFIG}"
    echo "Port 2222" >> "${SSH_CONFIG}"
    systemctl restart "${SSH_SVC}"

    # 2. File & Directory Permission Faults (OpenSSH StrictModes violation)
    # OpenSSH requires ~/.ssh to be max 700 and authorized_keys to be max 600/644 owned by user
    chmod 777 "${LAB_DIR}/.ssh"
    chmod 777 "${LAB_DIR}/.ssh/authorized_keys"

    # 3. Packet Filter (iptables) Misconfigurations
    # - Flush rules and set default INPUT policy to DROP
    # - Block loopback interface (lo)
    # - Allow wrong ports (8080 instead of 80, missing TCP 22 for SSH)
    # - Omit ESTABLISHED,RELATED connection tracking rule
    iptables -F INPUT
    iptables -F FORWARD
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # Explicitly drop loopback traffic (breaks local IPC and local health checks)
    iptables -A INPUT -i lo -j DROP

    # Allow incorrect service port
    iptables -A INPUT -p tcp --dport 8080 -j ACCEPT

    echo -e "\n${COLOR_RED}======================================================================${COLOR_RESET}"
    echo -e "${COLOR_RED}                 [ LAB ENVIRONMENT BROKEN SUCCESSFULLY ]              ${COLOR_RESET}"
    echo -e "${COLOR_RED}======================================================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN}SYMPTOMS REPORTED BY APPLICATION OPERATIONS:${COLOR_RESET}"
    echo -e " 1. External clients cannot connect to SSH on default port 22."
    echo -e " 2. Web clients cannot fetch pages from the HTTP application on port 80."
    echo -e " 3. Local health checks and inter-process communication on loopback ('lo') fail."
    echo -e " 4. SSH key-based login fails with permission errors even when connected locally."
    echo -e ""
    echo -e "${COLOR_YELLOW}STUDENT OBJECTIVES:${COLOR_RESET}"
    echo -e " A. Use diagnostic tools ('ss -tulpn', 'iptables -L -n -v', 'journalctl -u ${SSH_SVC}')"
    echo -e "    to inspect socket bindings, active packet filtering rules, and SSH daemon logs."
    echo -e " B. Reconfigure packet filtering rules (iptables) to:"
    echo -e "    - Set INPUT chain policy appropriately."
    echo -e "    - Allow unrestricted loopback traffic ('lo')."
    echo -e "    - Allow stateful traffic (ESTABLISHED, RELATED)."
    echo -e "    - Allow incoming TCP traffic on port 22 (SSH) and port 80 (HTTP)."
    echo -e " C. Fix '${SSH_CONFIG}' to listen on all IPv4 interfaces ('0.0.0.0') and standard port 22."
    echo -e " D. Secure '${LAB_DIR}/.ssh' directory (chmod 700) and 'authorized_keys' (chmod 600)."
    echo -e " E. Restart '${SSH_SVC}' and verify resolution with: sudo ./break_and_fix.sh check"
    echo -e "${COLOR_RED}======================================================================${COLOR_RESET}\n"
}

do_check() {
    check_root
    SSH_SVC=$(detect_ssh_service)
    ERRORS=0

    echo -e "${COLOR_CYAN}[+] Running Production Verification Diagnostics...${COLOR_RESET}\n"

    # Test 1: Loopback Interface Traffic
    echo -n "Test 1: Loopback (lo) packet filter status... "
    if iptables -L INPUT -v -n | grep -E "ACCEPT.*all.*--  lo  \*" &>/dev/null || ping -c 1 127.0.0.1 &>/dev/null; then
        echo -e "${COLOR_GREEN}[PASS] Loopback traffic is allowed.${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL] Loopback interface traffic is dropped by packet filter.${COLOR_RESET}"
        ((ERRORS++))
    fi

    # Test 2: Stateful Packet Inspection (ESTABLISHED,RELATED)
    echo -n "Test 2: Firewall connection state tracking (ESTABLISHED,RELATED)... "
    if iptables -L INPUT -v -n | grep -i "ESTABLISHED,RELATED" &>/dev/null; then
        echo -e "${COLOR_GREEN}[PASS] Stateful connection tracking rule detected.${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}[WARN] No explicit ESTABLISHED,RELATED rule found in INPUT chain.${COLOR_RESET}"
    fi

    # Test 3: HTTP Port 80 Firewall Rule
    echo -n "Test 3: Firewall permission for TCP port 80 (HTTP)... "
    if iptables -L INPUT -v -n | grep -E "dpt:80\b" | grep -i "ACCEPT" &>/dev/null; then
        echo -e "${COLOR_GREEN}[PASS] TCP port 80 is accepted in packet filter.${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL] Firewall is missing an ACCEPT rule for TCP port 80.${COLOR_RESET}"
        ((ERRORS++))
    fi

    # Test 4: SSH Port 22 Firewall Rule
    echo -n "Test 4: Firewall permission for TCP port 22 (SSH)... "
    if iptables -L INPUT -v -n | grep -E "dpt:22\b" | grep -i "ACCEPT" &>/dev/null; then
        echo -e "${COLOR_GREEN}[PASS] TCP port 22 is accepted in packet filter.${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL] Firewall is missing an ACCEPT rule for TCP port 22.${COLOR_RESET}"
        ((ERRORS++))
    fi

    # Test 5: SSH Daemon Socket Binding
    echo -n "Test 5: SSH Daemon network binding (0.0.0.0:22 or *:22)... "
    if ss -tulpn | grep -E "sshd|ssh" | grep -E "0\.0\.0\.0:22|\*:22|\[::\]:22" &>/dev/null; then
        echo -e "${COLOR_GREEN}[PASS] SSH daemon is bound to all network interfaces on port 22.${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL] SSH daemon is not listening on 0.0.0.0:22 (currently: $(ss -tulpn | grep -E 'sshd|ssh' | awk '{print $5}')).${COLOR_RESET}"
        ((ERRORS++))
    fi

    # Test 6: SSH Key File Permissions (StrictModes check)
    echo -n "Test 6: SSH key file & directory permissions (~/.ssh & authorized_keys)... "
    DIR_PERM=$(stat -c "%a" "${LAB_DIR}/.ssh" 2>/dev/null || echo "000")
    FILE_PERM=$(stat -c "%a" "${LAB_DIR}/.ssh/authorized_keys" 2>/dev/null || echo "000")

    if [[ "${DIR_PERM}" -le 700 ]] && [[ "${FILE_PERM}" -le 644 ]]; then
        echo -e "${COLOR_GREEN}[PASS] SSH directory permissions (${DIR_PERM}) and file permissions (${FILE_PERM}) comply with StrictModes.${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL] Overly permissive SSH permissions detected: .ssh=${DIR_PERM} (must be <=700), authorized_keys=${FILE_PERM} (must be <=644).${COLOR_RESET}"
        ((ERRORS++))
    fi

    # Test 7: HTTP Application Service Reachability
    echo -n "Test 7: HTTP Application response check (curl http://127.0.0.1:80)... "
    if curl -s --connect-timeout 2 http://127.0.0.1:80 &>/dev/null; then
        echo -e "${COLOR_GREEN}[PASS] HTTP application is serving traffic successfully.${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL] Unable to connect to HTTP application on port 80.${COLOR_RESET}"
        ((ERRORS++))
    fi

    echo -e "\n======================================================================"
    if [[ ${ERRORS} -eq 0 ]]; then
        echo -e "${COLOR_GREEN} CONGRATULATIONS! All Network & Service Security checks passed!${COLOR_RESET}"
        echo -e "${COLOR_GREEN} You have successfully resolved all packet filter, SSH binding, and permission faults.${COLOR_RESET}"
    else
        echo -e "${COLOR_RED} VERIFICATION FAILED: ${ERRORS} check(s) did not pass.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW} Review the failure messages above and re-examine service configs/firewall rules.${COLOR_RESET}"
    fi
    echo -e "======================================================================\n"
}

do_restore() {
    check_root
    SSH_SVC=$(detect_ssh_service)

    echo -e "${COLOR_YELLOW}[+] Restoring original system configuration...${COLOR_RESET}"

    if [[ -f "${IPTABLES_BAK}" ]]; then
        iptables-restore < "${IPTABLES_BAK}"
        rm -f "${IPTABLES_BAK}"
    else
        iptables -F
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
    fi

    if [[ -f "${SSHD_BAK}" ]]; then
        cp "${SSHD_BAK}" "${SSH_CONFIG}"
        rm -f "${SSHD_BAK}"
        systemctl restart "${SSH_SVC}"
    fi

    systemctl disable --now lab-web.service &>/dev/null || true
    rm -f /etc/systemd/system/lab-web.service /tmp/dummy_web.py
    systemctl daemon-reload

    if id "${LAB_USER}" &>/dev/null; then
        userdel -r "${LAB_USER}" 2>/dev/null || true
    fi

    echo -e "${COLOR_GREEN}[+] System restored to clean pre-lab state.${COLOR_RESET}"
}

usage() {
    echo "Usage: $0 {break|check|restore}"
    echo "  break   - Inject network & service security faults into the lab VM"
    echo "  check   - Run automated verification checks against your repairs"
    echo "  restore - Clean up lab changes and restore pre-lab settings"
    exit 1
}

case "${1:-break}" in
    break)
        do_break
        ;;
    check)
        do_check
        ;;
    restore)
        do_restore
        ;;
    *)
        usage
        ;;
esac

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & DIAGNOSTIC GUIDE (FOR INSTRUCTORS / REFERENCE)
# ==============================================================================
#
# STEP 1: DIAGNOSE ACTIVE NETWORK SOCKETS & SERVICES
# --------------------------------------------------
# 1. Check which ports and IP addresses services are listening on:
#    $ sudo ss -tulpn
#    Expected Finding:
#    - 'sshd' is bound to 127.0.0.1:2222 (Loopback only, wrong port!).
#    - 'python3' (web app) is listening on 0.0.0.0:80.
#
# 2. Inspect SSH Service logs to check for StrictModes or binding errors:
#    $ sudo journalctl -u sshd --no-pager -n 20
#    (or 'journalctl -u ssh' on Debian/Ubuntu)
#
# STEP 2: DIAGNOSE PACKET FILTER (IPTABLES) RULES
# ------------------------------------------------
# 1. View all active iptables rules with packet counters and line numbers:
#    $ sudo iptables -L INPUT -v -n --line-numbers
#    Expected Findings:
#    - Default policy: DROP.
#    - Rule 1: DROP traffic on interface 'lo' (Loopback interface blocked!).
#    - Rule 2: ACCEPT tcp dpt:8080 (Wrong application port).
#    - Missing: ACCEPT for lo, ESTABLISHED/RELATED connection state, port 22, port 80.
#
# STEP 3: REPAIR PACKET FILTER (IPTABLES)
# ----------------------------------------
# 1. Flush existing bad INPUT rules or adjust them explicitly:
#    $ sudo iptables -F INPUT
#
# 2. Set default INPUT policy to DROP (Security Best Practice / Zero Trust):
#    $ sudo iptables -P INPUT DROP
#
# 3. Allow all loopback traffic (critical for internal system communication):
#    $ sudo iptables -A INPUT -i lo -j ACCEPT
#
# 4. Allow stateful established/related return traffic:
#    $ sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
#
# 5. Allow incoming SSH (port 22) and HTTP (port 80):
#    $ sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
#    $ sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
#
# 6. Verify firewall table:
#    $ sudo iptables -L INPUT -v -n
#
# STEP 4: RECONFIGURE SSH DAEMON CONFIGURATION (/etc/ssh/sshd_config)
# -------------------------------------------------------------------
# 1. Open /etc/ssh/sshd_config in an editor:
#    $ sudo nano /etc/ssh/sshd_config
#
# 2. Locate and modify the following directives:
#    - Remove or comment out 'ListenAddress 127.0.0.1' (or change to 'ListenAddress 0.0.0.0')
#    - Change 'Port 2222' back to standard 'Port 22'
#
# 3. Save file and test sshd syntax:
#    $ sudo sshd -t
#
# 4. Restart SSH service:
#    $ sudo systemctl restart sshd    # (or systemctl restart ssh)
#
# 5. Confirm SSH is listening on 0.0.0.0:22:
#    $ sudo ss -tulpn | grep ssh
#
# STEP 5: FIX SSH FILE & DIRECTORY PERMISSIONS (StrictModes Compliance)
# ---------------------------------------------------------------------
# OpenSSH daemon checks file ownership and mode bits when StrictModes is active.
# If ~/.ssh or authorized_keys is writable by group or world, key authentication fails.
#
# 1. Inspect permissions on the student directory:
#    $ ls -ld /home/sre_student/.ssh
#    $ ls -l /home/sre_student/.ssh/authorized_keys
#
# 2. Fix directory permissions (must be 700 - rwx------):
#    $ sudo chmod 700 /home/sre_student/.ssh
#
# 3. Fix authorized_keys permissions (must be 600 - rw-------):
#    $ sudo chmod 600 /home/sre_student/.ssh/authorized_keys
#
# 4. Ensure proper ownership:
#    $ sudo chown -R sre_student:sre_student /home/sre_student/.ssh
#
# STEP 6: VERIFY SOLUTION
# -----------------------
# 1. Execute automated verification:
#    $ sudo ./break_and_fix.sh check
#
# 2. Test HTTP application locally via curl:
#    $ curl -I http://127.0.0.1:80
# ==============================================================================