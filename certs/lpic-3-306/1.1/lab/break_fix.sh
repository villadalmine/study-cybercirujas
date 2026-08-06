#!/bin/bash
# ==============================================================================
# LPIC-3 Exam 306-300 (v3.0) - Topic 1.1: High Availability Cluster Management
# Script: Break & Fix Lab Environment (Pacemaker / Corosync)
# Author: Senior SRE & Principal Platform Architect
# Reference: https://www.lpi.org/our-certifications/lpic-3-306-overview/
# ==============================================================================
# WARNING: Run this script ONLY inside a disposable laboratory Linux virtual machine.
# Do NOT run this on production systems.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_BACKUP_DIR="/var/backups/lpic3_cluster_lab_$(date +%Y%m%d_%H%M%S)"
COROSYNC_CONF="/etc/corosync/corosync.conf"
COROSYNC_AUTHKEY="/etc/corosync/authkey"

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be run as root (or via sudo).${NC}" >&2
        exit 1
    fi
}

function print_banner() {
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE}        LPIC-3 306-300: Topic 1.1 High Availability Cluster Management        ${NC}"
    echo -e "${BLUE}                      LAB SCENARIO: BREAK & FIX                               ${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "Target: Corosync 3.x / Pacemaker 2.x High Availability Stack"
    echo -e "Official Reference: https://www.lpi.org/our-certifications/lpic-3-306-overview/"
    echo -e "------------------------------------------------------------------------------"
}

function setup_mock_cluster_environment() {
    echo -e "${YELLOW}[+] Preparing base environment and directory structures...${NC}"
    mkdir -p /etc/corosync /var/lib/pacemaker/cib "${LOG_BACKUP_DIR}"

    # Generate standard corosync.conf if it does not exist
    if [[ ! -f "${COROSYNC_CONF}" ]]; then
        cat << 'EOF' > "${COROSYNC_CONF}"
totem {
    version: 2
    cluster_name: ha_prod_cluster
    transport: knet
    crypto_cipher: aes256
    crypto_hash: sha256
}

logging {
    to_logfile: yes
    logfile: /var/log/corosync/corosync.log
    to_syslog: yes
    logger_subsys {
        subsys: QUORUM
        debug: off
    }
}

nodelist {
    node {
        ring0_addr: node1.cluster.local
        nodeid: 1
    }
    node {
        ring0_addr: node2.cluster.local
        nodeid: 2
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
}
EOF
    fi

    # Backup original configuration
    cp -a "${COROSYNC_CONF}" "${LOG_BACKUP_DIR}/corosync.conf.orig"
    
    # Create authkey with proper permissions initially
    if [[ ! -f "${COROSYNC_AUTHKEY}" ]]; then
        head -c 128 /dev/urandom > "${COROSYNC_AUTHKEY}"
    fi
    chmod 0400 "${COROSYNC_AUTHKEY}"
    chown root:root "${COROSYNC_AUTHKEY}"
    cp -a "${COROSYNC_AUTHKEY}" "${LOG_BACKUP_DIR}/authkey.orig"
}

function inject_failures() {
    echo -e "${YELLOW}[+] Injecting controlled cluster faults...${NC}"

    # BUG 1: Insecure authkey permissions (Corosync security validation failure)
    # Corosync engine will refuse to load authkey if mode is not strict 0400 / 0600
    chmod 0644 "${COROSYNC_AUTHKEY}"

    # BUG 2: Syntax / Parameter corruption in corosync.conf Totem section
    # Replace valid crypto_cipher with unsupported string and sabotage nodelist transport config
    sed -i 's/crypto_cipher: aes256/crypto_cipher: invalid-cipher-gcm/' "${COROSYNC_CONF}"
    sed -i 's/transport: knet/transport: invalid_transport/' "${COROSYNC_CONF}"

    # BUG 3: Create a misconfigured OCF resource definition mock file simulating Pacemaker CIB invalid parameter
    cat << 'EOF' > /tmp/corrupted_resource_cib.xml
<primitive id="Virtual_IP" class="ocf" provider="heartbeat" type="IPaddr2">
  <instance_attributes id="Virtual_IP-instance_attributes">
    <!-- BUG: 'ip_address' is an invalid parameter name; correct parameter is 'ip' -->
    <nvpair id="Virtual_IP-ip" name="ip_address" value="192.168.122.100"/>
    <nvpair id="Virtual_IP-cidr" name="cidr_netmask" value="24"/>
  </instance_attributes>
  <operations>
    <op id="Virtual_IP-monitor-10s" name="monitor" interval="10s" timeout="20s"/>
  </operations>
</primitive>
<constraint_colocation id="cli-prefer-web-with-ip" score="-INFINITY" rsc="web_server" with-rsc="Virtual_IP"/>
<!-- BUG: Colocation score set to -INFINITY instead of INFINITY forces web_server and Virtual_IP onto SEPARATE nodes -->
EOF

    # If services are installed, restart to force systemd to encounter errors
    if systemctl is-active --quiet corosync 2>/dev/null; then
        systemctl restart corosync || true
    fi
    if systemctl is-active --quiet pacemaker 2>/dev/null; then
        systemctl restart pacemaker || true
    fi
}

function print_student_instructions() {
    echo -e "\n${GREEN}[✔] INJECTION COMPLETE. SCENARIO INITIALIZED.${NC}\n"
    echo -e "${YELLOW}------------------------------------------------------------------------------${NC}"
    echo -e "${YELLOW}STUDENT INCIDENT REPORT & DIAGNOSTIC OBJECTIVES${NC}"
    echo -e "${YELLOW}------------------------------------------------------------------------------${NC}"
    echo -e "ALERT: The High Availability cluster has failed to boot and sync nodes."
    echo -e "The SRE on call reports that 'pcs status' and 'corosync' systemd service fail."
    echo -e ""
    echo -e "OBSERVED SYMPTOMS:"
    echo -e " 1. 'systemctl status corosync' returns an error during startup."
    echo -e " 2. Log files (/var/log/corosync/corosync.log or journalctl -u corosync) indicate initialization failures."
    echo -e " 3. Pacemaker cannot establish connection to the Corosync CPG (Cluster Closed Process Group) layer."
    echo -e " 4. Resource configuration validation fails due to invalid parameters and inverted constraint rules."
    echo -e ""
    echo -e "YOUR OBJECTIVES:"
    echo -e " 1. Inspect system logs using systemctl, journalctl, corosync-cfgtool, and corosync-cmapctl."
    echo -e " 2. Identify and fix security/permission defects on security key files."
    echo -e " 3. Resolve syntax errors and illegal parameters in /etc/corosync/corosync.conf."
    echo -e " 4. Analyze Pacemaker OCF resource parameters and colocation constraints."
    echo -e " 5. Restore full cluster quorum and ensure resources run co-located on the active node."
    echo -e ""
    echo -e "BACKUP FILES CREATED AT: ${LOG_BACKUP_DIR}"
    echo -e "${YELLOW}------------------------------------------------------------------------------${NC}"
    echo -e "Inspect the bottom of this script file for the complete, step-by-step solution guide."
    echo -e "${BLUE}==============================================================================${NC}\n"
}

# --- MAIN EXECUTION ---
check_root
print_banner
setup_mock_cluster_environment
inject_failures
print_student_instructions

exit 0

# ==============================================================================
#                      STEP-BY-STEP SOLUTION & DIAGNOSTIC GUIDE
#                      (LPIC-3 306 - Topic 1.1 HA Cluster Management)
# ==============================================================================
#
# STEP 1: DIAGNOSE COROSYNC SERVICE FAILURE
# ------------------------------------------------------------------------------
# Check the systemd daemon status and journal logs:
#   systemctl status corosync.service
#   journalctl -u corosync.service -e --no-pager
#
# Log output reveals two critical errors:
#   1) "File /etc/corosync/authkey has invalid permissions. Must be 0400 or 0600"
#   2) "Parse error in /etc/corosync/corosync.conf: Invalid transport or cipher configuration"
#
# STEP 2: FIX AUTHKEY PERMISSIONS
# ------------------------------------------------------------------------------
# Corosync enforces strict file permissions on cluster cryptographic secrets.
# Execute:
#   chown root:root /etc/corosync/authkey
#   chmod 0400 /etc/corosync/authkey
#
# Verify permissions:
#   ls -la /etc/corosync/authkey
#   # Expected output: -r-------- 1 root root ... /etc/corosync/authkey
#
# STEP 3: REPAIR COROSYNC CONFIGURATION (/etc/corosync/corosync.conf)
# ------------------------------------------------------------------------------
# Edit /etc/corosync/corosync.conf and correct invalid totem options:
#
#   Incorrect lines:
#     transport: invalid_transport
#     crypto_cipher: invalid-cipher-gcm
#
#   Correct lines (Corosync 3.x with Kronosnet):
#     transport: knet
#     crypto_cipher: aes256
#     crypto_hash: sha256
#
# Validate file syntax using corosync-parser or testing service start:
#   corosync -t
#   systemctl restart corosync
#   systemctl status corosync
#
# STEP 4: VERIFY COROSYNC QUORUM AND MEMBERSHIP
# ------------------------------------------------------------------------------
# Check cluster communication and membership state:
#   corosync-cfgtool -s
#   corosync-cmapctl | grep runtime.totem.pg.mems
#   pcs cluster status
#
# Expected output showing active ring communication:
#   Printing ring status.
#   RING ID 0
#           id      = 192.168.122.10
#           status  = ring 0 active with no faults
#
# STEP 5: DIAGNOSE AND REPAIR PACEMAKER OCF RESOURCES & CONSTRAINTS
# ------------------------------------------------------------------------------
# Inspect cluster resource status:
#   pcs status
#   crm_mon -1 -V
#
# Issue A: Virtual_IP resource failing with 'ocf-secret-fail' or 'invalid parameter'.
#   Inspect OCF resource attributes:
#     pcs resource config Virtual_IP
#   The OCF agent 'ocf:heartbeat:IPaddr2' requires parameter 'ip', not 'ip_address'.
#   Fix command:
#     pcs resource update Virtual_IP ip=192.168.122.100 --delete ip_address
#
# Issue B: Web server and IP running on different nodes unexpectedly.
#   Inspect colocation constraints:
#     pcs constraint list --full
#   Found:
#     Location Constraint: cli-prefer-web-with-ip (score:-INFINITY)
#   A score of -INFINITY forces resources APART. To bind them to the SAME node,
#   the score must be +INFINITY.
#   Fix command:
#     pcs constraint delete cli-prefer-web-with-ip
#     pcs constraint colocation add web_server with Virtual_IP INFINITY
#
# STEP 6: VERIFY FINAL CLUSTER HEALTH
# ------------------------------------------------------------------------------
# Clear resource failcounts and verify clean state:
#   pcs resource cleanup
#   pcs status
#
# Output should show all nodes Online and resources Started on the same node:
#   Cluster name: ha_prod_cluster
#   Cluster Summary:
#     * Stack: corosync
#     * Current DC: node1.cluster.local (version 2.1.x) - partition with quorum
#     * 2 nodes configured
#     * 2 resources configured
#
#   Node List:
#     * Online: [ node1.cluster.local node2.cluster.local ]
#
#   Full List of Resources:
#     * Virtual_IP   (ocf::heartbeat:IPaddr2):  Started node1.cluster.local
#     * web_server   (systemd:nginx):          Started node1.cluster.local
# ==============================================================================