#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 (Exam 201-450) - Topic 205 / 1.6: Networking Configuration (Weight: 7)
# Production SRE Break & Fix Laboratory Scenario
# Official Reference: https://www.lpi.org/our-certifications/lpic-2-overview/
# ==============================================================================
# WARNING: Run this script ONLY on a disposable laboratory Virtual Machine.
# It intentionally disrupts Linux kernel routing tables, system name resolution,
# and sysctl network stack behavior to simulate a complex production outage.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Pre-flight Checks & Safety Guardrails
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] ERROR: This lab script must be executed as root (sudo)." >&2
    exit 1
fi

BACKUP_DIR="/var/tmp/lpic2_breakfix_net_backup_$(date +%s)"
mkdir -p "${BACKUP_DIR}"

echo "[*] Creating configuration backups in ${BACKUP_DIR}..."

if [[ -f /etc/nsswitch.conf ]]; then
    cp -p /etc/nsswitch.conf "${BACKUP_DIR}/nsswitch.conf.bak"
fi

if [[ -f /etc/resolv.conf ]]; then
    # Handle symlinks (e.g., systemd-resolved) safely
    cp -P /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || cp -p /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak"
fi

# Capture existing routing table state
ip route show > "${BACKUP_DIR}/ip_route_original.txt"
ip rule show > "${BACKUP_DIR}/ip_rule_original.txt"

# ------------------------------------------------------------------------------
# 2. Inject Controlled Failure Mechanics
# ------------------------------------------------------------------------------
echo "[*] Injecting multi-layered network configuration failures..."

# A. Layer 3 Routing Table Hijack
# Find the primary default interface and inject a rogue metric-0 blackhole default route
PRIMARY_IFACE=$(ip route | grep -m1 '^default' | awk '{print $5}' || true)
PRIMARY_GW=$(ip route | grep -m1 '^default' | awk '{print $3}' || true)

if [[ -n "${PRIMARY_IFACE}" ]]; then
    # Add a bogus default gateway with lower metric (higher priority) than existing default route
    ip route add default via 192.0.2.1 dev "${PRIMARY_IFACE}" metric 5 2>/dev/null || true
    # Add blackhole route for common upstream public DNS to block DNS fallback
    ip route add blackhole 1.1.1.1/32 metric 1 2>/dev/null || true
fi

# B. Kernel Sysctl ICMP & Reverse Path Filtering Disruption
SYSCTL_BREAK_FILE="/etc/sysctl.d/99-lpic2-breakfix.conf"
cat << 'EOF' > "${SYSCTL_BREAK_FILE}"
# Injected for LPIC-2 Networking Break&Fix Lab
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
sysctl -p "${SYSCTL_BREAK_FILE}" >/dev/null 2>&1 || true

# C. Name Service Switch (NSS) Database Desynchronization
# Alter /etc/nsswitch.conf: insert non-existent service module and break precedence
if [[ -f /etc/nsswitch.conf ]]; then
    sed -i 's/^hosts:.*/hosts:       invalid_nss_mod dns [NOTFOUND=return] files/' /etc/nsswitch.conf
fi

# D. Resolver Configuration Mutation & Immutable Lock
RESOLV_CONF="/etc/resolv.conf"
if [[ -L "${RESOLV_CONF}" ]]; then
    # Unlink if it points to systemd-resolved stub to force file override
    rm -f "${RESOLV_CONF}"
fi

cat << 'EOF' > "${RESOLV_CONF}"
# Injected broken resolver configuration
nameserver 198.51.100.254
nameserver 203.0.113.254
options timeout:1 attempts:1
EOF

# Set immutable attribute using chattr to prevent DHCP/NetworkManager auto-healing
if command -v chattr >/dev/null 2>&1; then
    chattr +i "${RESOLV_CONF}" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 3. Present Scenario & Objective to the Student
# ------------------------------------------------------------------------------
clear
cat << 'EOF'
================================================================================
 LPIC-2 (Exam 201-450) Topic 205 / 1.6: Networking Configuration
 PRODUCTION SRE INCIDENT REPORT & BREAK-AND-FIX LAB
================================================================================

[INCIDENT SUMMARY]
An automated deployment script misconfigured the network stack on this node.
Monitoring alerts report total loss of outbound network connectivity, DNS
resolution failures, and unresponsive ICMP diagnostic probes.

[OBSERVED SYMPTOMS]
1. `ping 127.0.0.1` works, but `ping <gateway_ip>` and `ping 8.8.8.8` fail or 
   return silence/errors.
2. Domain resolution via `host`, `dig`, or `getent hosts google.com` times out
   or throws lookup errors (`Host not found` / `Unknown database`).
3. Local `/etc/hosts` entries are completely ignored by system lookup APIs.
4. Editing `/etc/resolv.conf` directly fails with "Operation not permitted"
   even when logged in as root.

[STUDENT OBJECTIVES]
1. Diagnose and restore Layer 3 IPv4 default routing so traffic uses the proper
   gateway interface without blackhole/rogue metrics.
2. Restore kernel sysctl settings so ICMP echo requests behave according to
   standard baseline policies.
3. Repair `/etc/nsswitch.conf` host lookup order so `/etc/hosts` takes precedence
   over DNS, and remove invalid NSS modules.
4. Remove file attribute locks on `/etc/resolv.conf` and restore valid local
   nameservers (or reconnect systemd-resolved stub resolver if applicable).
5. Ensure all configuration fixes persist properly and survive a network service
   restart.

[OFFICIAL REFERENCE RESOURCES]
- LPI LPIC-2 Objectives: https://www.lpi.org/our-certifications/lpic-2-overview/
- iproute2 Documentation: https://man7.org/linux/man-pages/man8/ip.8.html
- NSSwitch Config Guide: https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html

================================================================================
 The system is now BROKEN. Begin your diagnosis using standard iproute2,
 getent, dig, ss, sysctl, and lsattr tools.
 (Full step-by-step solution is commented out at the bottom of this script file)
================================================================================
EOF

exit 0

# ==============================================================================
# STEP-BY-STEP DIAGNOSTIC PROCEDURES AND SOLUTION (FOR INSTRUCTOR / STUDENT)
# ==============================================================================
#
# --- PHASE 1: DIAGNOSIS ---
#
# 1. Test basic connectivity and IP layer routing:
#    $ ping -c 2 8.8.8.8
#    $ ip route show
#    --> Observe rogue route: `default via 192.0.2.1 dev eth0 metric 5`
#    --> Observe blackhole route: `blackhole 1.1.1.1 metric 1`
#
# 2. Test ICMP responsiveness:
#    $ sysctl net.ipv4.icmp_echo_ignore_all
#    --> Returns: net.ipv4.icmp_echo_ignore_all = 1
#
# 3. Test Name Resolution APIs & NSS Switch:
#    $ getent hosts localhost
#    --> Fails or behaves erratically due to invalid module in /etc/nsswitch.conf
#    $ cat /etc/nsswitch.conf | grep hosts
#    --> Returns: `hosts: invalid_nss_mod dns [NOTFOUND=return] files`
#    Notice that `files` comes AFTER `[NOTFOUND=return]`, causing /etc/hosts to be ignored!
#
# 4. Check DNS Resolver and File Attributes:
#    $ cat /etc/resolv.conf
#    $ nano /etc/resolv.conf
#    --> Fails to write/save due to ext2/ext3/ext4 immutable attribute.
#    $ lsattr /etc/resolv.conf
#    --> Returns: `----i---------e---- /etc/resolv.conf` (+i flag set)
#
# --- PHASE 2: RESOLUTION & REMEDIATION ---
#
# 1. Fix Layer 3 IP Routing Table:
#    $ sudo ip route del default via 192.0.2.1 metric 5
#    $ sudo ip route del blackhole 1.1.1.1/32 metric 1
#    (If default gateway was wiped completely, re-add your valid network gateway):
#    $ sudo ip route add default via <VALID_GATEWAY_IP> dev <INTERFACE>
#
# 2. Revert Kernel Sysctl Settings:
#    $ sudo rm -f /etc/sysctl.d/99-lpic2-breakfix.conf
#    $ sudo sysctl -w net.ipv4.icmp_echo_ignore_all=0
#    $ sudo sysctl --system
#
# 3. Repair Name Service Switch (/etc/nsswitch.conf):
#    Edit /etc/nsswitch.conf and fix the `hosts:` database line to standard LPIC-2 spec:
#    $ sudo sed -i 's/^hosts:.*/hosts:       files dns/' /etc/nsswitch.conf
#
# 4. Unlock and Restore /etc/resolv.conf:
#    $ sudo chattr -i /etc/resolv.conf
#    Restore standard nameservers or systemd-resolved symlink:
#    Option A (Standard Static DNS):
#      $ sudo bash -c 'cat << EOF > /etc/resolv.conf
#    nameserver 8.8.8.8
#    nameserver 1.1.1.1
#    EOF'
#    Option B (Systemd-resolved integration):
#      $ sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
#      $ sudo systemctl restart systemd-resolved
#
# 5. Verification Commands:
#    $ ip route show
#    $ getent hosts google.com
#    $ ping -c 2 8.8.8.8
#    $ dig google.com +short
# ==============================================================================