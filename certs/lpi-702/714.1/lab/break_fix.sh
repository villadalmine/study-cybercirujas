#!/usr/bin/env bash
# ==============================================================================
# LPI-702 (Exam 702-100 v1.0) - Topic 714.1: Fundamentals of Internet Protocols
# Production SRE Break & Fix Laboratory Challenge
# Target: Disposable Linux Laboratory VM / Container Environment
# Weight: 3.33
# Official Reference: https://www.lpi.org/our-certifications/open-source-essentials/
# ==============================================================================
# DISCLAIMER: Execute this script ONLY on disposable test environments.
# It intentionally alters network interface configurations, MTU settings,
# kernel sysctl parameters, local routing tables, and DNS resolution rules.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BACKUP_DIR="/var/tmp/lpi702_714_1_backup_$(date +%s)"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed with root privileges (sudo).${NC}" >&2
        exit 1
    fi
}

create_backups() {
    echo -e "${BLUE}[INFO] Creating configuration backups in ${BACKUP_DIR}...${NC}"
    mkdir -p "${BACKUP_DIR}"

    if [[ -f /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
    fi
    if [[ -f /etc/nsswitch.conf ]]; then
        cp /etc/nsswitch.conf "${BACKUP_DIR}/nsswitch.conf.bak" 2>/dev/null || true
    fi
    
    # Backup current network state
    ip addr show > "${BACKUP_DIR}/ip_addr.bak"
    ip route show > "${BACKUP_DIR}/ip_route.bak"
    sysctl -a 2>/dev/null > "${BACKUP_DIR}/sysctl.bak" || true
    
    echo "${BACKUP_DIR}" > /var/tmp/lpi702_last_backup_path
}

inject_faults() {
    echo -e "${YELLOW}[SETUP] Injecting controlled network stack anomalies...${NC}"

    # --------------------------------------------------------------------------
    # FAULT 1: PMTU Discovery Blackholing & MTU Subnet Mismatch
    # Reduce MTU on primary non-loopback network interface to 1280 bytes
    # and drop ICMP Type 3 Code 4 (Fragmentation Needed) packets.
    # --------------------------------------------------------------------------
    PRIMARY_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    if [[ -z "${PRIMARY_IFACE}" ]]; then
        PRIMARY_IFACE=$(ip -o link show | awk -F': ' '$2 !~ "^lo$" {print $2}' | head -n1)
    fi

    if [[ -n "${PRIMARY_IFACE}" ]]; then
        echo "Primary interface detected: ${PRIMARY_IFACE}"
        ip link set dev "${PRIMARY_IFACE}" mtu 1200
    fi

    # Block ICMP Type 3 (Destination Unreachable) / Code 4 (Frag Needed) using iptables/nftables
    if command -v iptables &>/dev/null; then
        iptables -A INPUT -p icmp --icmp-type 3/4 -j DROP 2>/dev/null || true
        iptables -A OUTPUT -p icmp --icmp-type 3/4 -j DROP 2>/dev/null || true
    fi

    # --------------------------------------------------------------------------
    # FAULT 2: Strict Reverse Path Filtering (rp_filter) & Asymmetric Route Injection
    # Enable strict unicast reverse path validation while injecting a bogus host route
    # for public DNS upstreams (e.g. 1.1.1.1 or 8.8.8.8) via an invalid dummy route.
    # --------------------------------------------------------------------------
    sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null
    if [[ -n "${PRIMARY_IFACE}" ]]; then
        sysctl -w "net.ipv4.conf.${PRIMARY_IFACE}.rp_filter=1" >/dev/null 2>&1 || true
    fi

    # Inject blackhole / high-metric route override for upstream DNS target
    ip route add blackhole 1.1.1.1/32 metric 1 2>/dev/null || true
    ip route add blackhole 8.8.8.8/32 metric 1 2>/dev/null || true

    # --------------------------------------------------------------------------
    # FAULT 3: Local Name Resolution Chain Breakage
    # Break nsswitch.conf module precedence and configure unreachable nameserver
    # --------------------------------------------------------------------------
    if [[ -f /etc/resolv.conf ]]; then
        # Handle symlinked resolv.conf (systemd-resolved) by temporary unlink/replacement
        rm -f /etc/resolv.conf
        cat <<EOF > /etc/resolv.conf
# Managed by SRE Break-and-Fix Lab
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:1
EOF
    fi

    if [[ -f /etc/nsswitch.conf ]]; then
        sed -i -E 's/^hosts:.*/hosts:    invalid_module_xyz/' /etc/nsswitch.conf
    fi

    # Disable IP Forwarding (if relevant for local routing tests)
    sysctl -w net.ipv4.ip_forward=0 >/dev/null

    echo -e "${GREEN}[OK] Anomalies injected successfully.${NC}"
}

print_student_briefing() {
    cat <<EOF

================================================================================
                    LPI-702 SRE LAB: INCIDENT REPORT #7141
================================================================================
CRITICALITY: HIGH
AFFECTED SERVICE: Network Transport, Name Resolution, and PMTU Discovery Stack
TOPIC: 714.1 - Fundamentals of Internet Protocols

[SYMPTOMS OBSERVED BY ON-CALL SRE]
1. Internal applications report "Host name lookup failure" or hang indefinitely
   when attempting outbound TCP connections over HTTP/HTTPS.
2. Standard ICMP pings to IP addresses succeed for small payload sizes, but
   large payloads (e.g. TCP payloads > 1200 bytes) silently drop or time out.
3. System logs indicate network packet drops under strict ingress/egress filtering.
4. Routing table inspection reveals abnormal routing decisions for core upstream services.

[YOUR MISSION]
Diagnose the root causes at Layer 3 (IP, ICMP, Routing) and Layer 7/NSS (DNS Resolution),
restore standard production behavior without rebooting the system, and ensure:
 - Name resolution functions properly via standard glibc getaddrinfo mechanics.
 - Path MTU Discovery (PMTUD) functions without blackholing TCP streams.
 - Upstream IP routes to 1.1.1.1 and 8.8.8.8 are restored to standard gateway paths.
 - Reverse Path Filtering and interface MTUs are aligned to standard MTU 1500 (or interface default).

[RECOMMENDED DIAGNOSTIC TOOLING]
 - ip addr, ip route, ip link
 - sysctl net.ipv4.conf.all.rp_filter / net.ipv4.ip_forward
 - dig, nslookup, getent hosts www.google.com
 - tcpdump -nn -i any icmp or proto TCP
 - tracepath / traceroute
 - iptables -L -n -v

[BACKUP LOCATION]
Original configurations saved to: ${BACKUP_DIR}
================================================================================

EOF
}

main() {
    check_root
    create_backups
    inject_faults
    print_student_briefing
}

main "$@"

# ==============================================================================
#               STEP-BY-STEP INCIDENT SOLUTION & TECHNICAL GUIDE
# ==============================================================================
# (DO NOT READ THIS SECTION UNTIL YOU HAVE ATTEMPTED TO RESOLVE THE INCIDENT)
#
# ------------------------------------------------------------------------------
# 1. UNDERSTANDING THE DEEP TECHNICAL MECHANICS (THEORY & ARCHITECTURE)
# ------------------------------------------------------------------------------
# A. Name Resolution Architecture (NSS & resolv.conf):
#    In Linux, glibc uses the Name Service Switch (NSS) defined in `/etc/nsswitch.conf`
#    to control how databases like 'hosts' are queried. The entry `hosts: invalid_module_xyz`
#    causes `getaddrinfo()` to instantly fail before even consulting `/etc/resolv.conf`
#    or `/etc/hosts`. Replacing this with `hosts: files dns` restores glibc resolution.
#
# B. Blackhole Routing & Subnet Overrides:
#    The `ip route add blackhole` command inserts a L3 route with a RTN_BLACKHOLE type.
#    Packets matching this route are silently dropped by the kernel network stack.
#    Removing these static L3 host routes via `ip route del` returns traffic matching
#    to the default gateway L3 destination.
#
# C. Path MTU Discovery (PMTUD) Blackholing:
#    When an interface MTU is manually constrained (e.g. MTU 1200), TCP segments larger
#    than 1160 bytes (1200 - 20 IP header - 20 TCP header) set the IP header 'Don't Fragment'
#    (DF) flag. If a router or local stack drops the packet because it exceeds MTU, it must
#    emit ICMP Type 3, Code 4 ("Destination Unreachable, Fragmentation Needed and DF Set").
#    By dropping ICMP Type 3/4 via iptables, TCP endpoints never receive the ICMP payload
#    specifying the Next-Hop MTU. This causes silent TCP packet drops (PMTUD Blackhole).
#    Fix: Restore interface MTU to 1500 and flush dropping firewall rules.
#
# D. Reverse Path Filtering (rp_filter):
#    `net.ipv4.conf.all.rp_filter = 1` enforces RFC 3704 Strict Reverse Path Forwarding.
#    The kernel checks if the source IP of an incoming packet would be routed out through
#    the same interface it arrived on. If not, the packet is dropped.
#
# ------------------------------------------------------------------------------
# 2. STEP-BY-STEP DIAGNOSTIC AND RESOLUTION COMMANDS
# ------------------------------------------------------------------------------
# Step 1: Diagnose and Fix Name Service Switch (NSS)
# --------------------------------------------------
# Test glibc name resolution:
# $ getent hosts google.com
# Expected output: (Empty / Error)
#
# Check /etc/nsswitch.conf:
# $ grep '^hosts:' /etc/nsswitch.conf
# hosts:    invalid_module_xyz
#
# Fix:
# $ sed -i -E 's/^hosts:.*/hosts:    files dns/' /etc/nsswitch.conf
# $ getent hosts localhost
# 127.0.0.1       localhost
#
#
# Step 2: Identify and Clear Blackhole IP Routes
# -----------------------------------------------
# Inspect the kernel IPv4 routing table:
# $ ip route show
# blackhole 1.1.1.1 metric 1
# blackhole 8.8.8.8 metric 1
# default via 192.168.1.1 dev eth0 ...
#
# Delete blackhole entries:
# $ ip route del blackhole 1.1.1.1/32 metric 1
# $ ip route del blackhole 8.8.8.8/32 metric 1
#
# Verify route to DNS targets:
# $ ip route get 1.1.1.1
# 1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.50
#
#
# Step 3: Restore Interface MTU & Flush Blocked ICMP Rules
# --------------------------------------------------------
# Check interface configuration:
# $ ip link show
# eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1200 qdisc fq_codel state UP
#
# Restore standard Ethernet MTU (1500 bytes):
# $ PRIMARY_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
# $ ip link set dev "${PRIMARY_IFACE}" mtu 1500
#
# Check firewall for ICMP Type 3/4 drops:
# $ iptables -L INPUT -n -v --line-numbers
# $ iptables -L OUTPUT -n -v --line-numbers
#
# Flush or delete iptables rules dropping ICMP:
# $ iptables -D INPUT -p icmp --icmp-type 3/4 -j DROP
# $ iptables -D OUTPUT -p icmp --icmp-type 3/4 -j DROP
#
#
# Step 4: Tune Kernel Sysctl Parameters
# --------------------------------------
# Re-enable IP forwarding (if host acts as gateway/router) and adjust rp_filter:
# $ sysctl -w net.ipv4.ip_forward=1
# $ sysctl -w net.ipv4.conf.all.rp_filter=2 # Loose mode or 0 (disabled) depending on topology
# $ sysctl -w net.ipv4.conf.default.rp_filter=2
#
# Persist sysctl settings (production best practice):
# $ cat <<EOF > /etc/sysctl.d/99-sre-network-fix.conf
# net.ipv4.ip_forward = 1
# net.ipv4.conf.all.rp_filter = 2
# net.ipv4.conf.default.rp_filter = 2
# EOF
# $ sysctl --system
#
#
# Step 5: Verification & End-to-End Validation
# ---------------------------------------------
# 1. Test DNS Lookup:
# $ dig +short google.com @1.1.1.1
# 142.250.190.46
#
# 2. Test PMTUD with large ICMP payloads (DF bit set):
# $ ping -M do -s 1440 1.1.1.1
# PING 1.1.1.1 (1.1.1.1) 1440(1468) bytes of data.
# 1448 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=12.4 ms
#
# 3. Test HTTP/HTTPS transport stream:
# $ curl -Iv https://www.google.com
# HTTP/2 200 ...
#
# ------------------------------------------------------------------------------
# OFFICIAL REFERENCES & CITATIONS
# ------------------------------------------------------------------------------
# - LPI BSD Specialist / DevOps Overview:
#   https://www.lpi.org/our-certifications/bsd-specialist-overview/
# - IETF RFC 791 (Internet Protocol Specification):
#   https://datatracker.ietf.org/doc/html/rfc791
# - IETF RFC 1191 (Path MTU Discovery):
#   https://datatracker.ietf.org/doc/html/rfc1191
# - IETF RFC 3704 (Ingress Filtering for Multihomed Networks / rp_filter):
#   https://datatracker.ietf.org/doc/html/rfc3704
# - Linux Kernel IP Sysctl Documentation:
#   https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt
# ==============================================================================