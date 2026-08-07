#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist Certification (Exam 702-100, Version 1.0)
# Topic 714.3: Basic Network Troubleshooting
# Exam Weight: 5
# ==============================================================================
#
# OFFICIAL REFERENCE SOURCES & CITATIONS:
# 1. LPI BSD Specialist Overview & Exam Objectives:
#    https://www.lpi.org/our-certifications/bsd-specialist-overview/
# 2. FreeBSD Handbook - Advanced Networking & Troubleshooting:
#    https://docs.freebsd.org/en/books/handbook/network-advanced/
# 3. FreeBSD Manual Pages (ifconfig, netstat, sockstat, route, pfctl):
#    https://man.freebsd.org/cgi/man.cgi?query=sockstat
#    https://man.freebsd.org/cgi/man.cgi?query=netstat
#    https://man.freebsd.org/cgi/man.cgi?query=route
#    https://man.freebsd.org/cgi/man.cgi?query=pfctl
#
# ==============================================================================
# DEEP TECHNICAL ARCHITECTURE & KERNEL MECHANICS
# ==============================================================================
#
# 1. BSD NETWORK SUBSYSTEM & PROTOCOL CONTROL BLOCKS (PCBs):
#    - Socket Layer & Kernel Memory: BSD networking manages connections via
#      Protocol Control Blocks (inpcb for IP, tcpcb for TCP) tied to socket
#      buffers (so_rcvbuf, so_sndbuf).
#    - sockstat vs. netstat Mechanics:
#      * sockstat: Directly queries kernel sysctl nodes (net.inet.tcp.pcblist,
#        kern.file) via sysctlbyname() or kvm interfaces. It maps open sockets,
#        protocol endpoints, binding addresses, and Process IDs (PIDs) instantly
#        without traversing user-space process files.
#      * netstat: Reads routing tables, interface statistics, and mbuf (memory
#        buffer) allocations. Used to inspect socket states (LISTEN, ESTABLISHED,
#        TIME_WAIT) and routing socket messages (RTM_ADD, RTM_DELETE).
#
# 2. BSD ROUTING TABLE & RADIX TRIE (PATRICIA TRIE):
#    - The BSD kernel maintains IPv4 and IPv6 routes in a Radix tree structure,
#      enabling fast Longest Match Prefix (LMP) lookups.
#    - Link-Layer resolution relies on kernel tables: ARP (IPv4) and NDP (IPv6).
#      Commands `arp -a` and `ndp -a` inspect mapping between IP and MAC addresses.
#
# 3. PACKET FILTERING (PF / pfil(9) HOOKS):
#    - OpenBSD PF (integrated into FreeBSD) hooks into the pfil(9) kernel framework
#      between network interface drivers and Layer 3 handlers (ip_input/ip_output).
#    - Stateful rule evaluation (`pfctl -ss`) evaluates existing connections
#      before falling back to sequential ruleset matching (`pfctl -sr`), avoiding
#      per-packet ruleset traversal for established flows.
#
# 4. SRE TROUBLESHOOTING METHODOLOGY (OSI LAYER BREAKDOWN):
#    - Layer 1/2 (Link Status & MAC Resolution):
#      `ifconfig -a` -> Check interface flags (UP, RUNNING), media status (active), MTU.
#      `arp -a` / `ndp -a` -> Verify gateway IP resolves to a valid MAC address.
#    - Layer 3 (Network & Routing):
#      `netstat -rn` / `route get <ip>` -> Audit IPv4/IPv6 routing tables, default gateway.
#      `ping -c 3 <gw_ip>` / `ping6 -c 3 <gw_ip>` -> Test ICMP echo reachability.
#      `traceroute -n <target_ip>` -> Identify hop-by-hop latency and drop points.
#    - Layer 4 (Transport & Listening Ports):
#      `sockstat -4 -6 -l` -> Verify bound listening daemon ports and associated PIDs.
#      `netstat -an -p tcp` -> Inspect TCP state machine transitions (SYN_SENT, TIME_WAIT).
#      `pfctl -s info` / `pfctl -sr` -> Audit packet filter status and active block rules.
#    - Layer 7 & Name Resolution:
#      `/etc/resolv.conf`, `/etc/nsswitch.conf` -> Inspect nameserver entries and lookup order.
#      `drill @<nameserver> <domain>` / `dig @<nameserver> <domain>` -> Direct DNS queries.
#
# 5. PRODUCTION TRADE-OFFS & HARDENING CONSIDERATIONS:
#    - Diagnostic Performance Impact: In high-concurrency production nodes (>200k active TCP
#      flows), running `netstat -a` without `-n` forces blocking reverse DNS lookups, causing
#      severe CPU/memory spikes. Always use numeric output (`-n`).
#    - Path MTU Discovery (PMTUD) vs ICMP Filtering: Blocking ICMP indiscriminately breaks
#      ICMP Type 3 Code 4 (Fragmentation Needed and DF set). This causes silent TCP connection
#      stalls on large payloads. Always allow required ICMP control messages in `pf.conf`.
#
# ==============================================================================

set -euo pipefail

BACKUP_DIR="/var/tmp/lpi_714_3_lab_backup"
RESOLV_CONF="/etc/resolv.conf"
PF_CONF="/etc/pf.conf"

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}ERROR: This lab script must be executed as root.${NC}" >&2
        exit 1
    fi
}

detect_default_gw() {
    if command -v netstat >/dev/null 2>&1; then
        netstat -rn | awk '$1 == "default" || $1 == "0.0.0.0" { print $2; exit }'
    elif command -v ip >/dev/null 2>&1; then
        ip route show | awk '$1 == "default" { print $3; exit }'
    fi
}

detect_active_iface() {
    if command -v route >/dev/null 2>&1; then
        route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}' || true
    fi
}

do_backup() {
    mkdir -p "${BACKUP_DIR}"
    
    # Backup resolv.conf
    if [ -f "${RESOLV_CONF}" ] && [ ! -f "${BACKUP_DIR}/resolv.conf.orig" ]; then
        cp "${RESOLV_CONF}" "${BACKUP_DIR}/resolv.conf.orig"
    fi

    # Backup Default Gateway
    ORIG_GW=$(detect_default_gw || true)
    if [ -n "${ORIG_GW}" ] && [ ! -f "${BACKUP_DIR}/default_gw.orig" ]; then
        echo "${ORIG_GW}" > "${BACKUP_DIR}/default_gw.orig"
    fi

    # Backup PF rules if pfctl exists
    if command -v pfctl >/dev/null 2>&1; then
        pfctl -sr > "${BACKUP_DIR}/pf.rules.orig" 2>/dev/null || true
    fi
}

do_break() {
    require_root
    do_backup

    echo -e "${YELLOW}[+] Injecting production network faults for LPI 714.3 lab...${NC}"

    # 1. DNS Fault: Overwrite resolv.conf with non-routable dummy nameserver (RFC 5737)
    cat << 'EOF' > "${RESOLV_CONF}"
# Lab Fault Injected - Invalid Nameserver
nameserver 192.0.2.53
options timeout:1 attempts:1
EOF

    # 2. Routing Fault: Replace default gateway with invalid route
    ORIG_GW=""
    if [ -f "${BACKUP_DIR}/default_gw.orig" ]; then
        ORIG_GW=$(cat "${BACKUP_DIR}/default_gw.orig")
    fi

    if [ -n "${ORIG_GW}" ]; then
        if command -v route >/dev/null 2>&1; then
            route delete default >/dev/null 2>&1 || true
            route add default 192.0.2.1 >/dev/null 2>&1 || true
        elif command -v ip >/dev/null 2>&1; then
            ip route del default >/dev/null 2>&1 || true
            ip route add default via 192.0.2.1 >/dev/null 2>&1 || true
        fi
    fi

    # 3. Firewall Fault: Inject silent outbound drop rules (PF or iptables fallback)
    if command -v pfctl >/dev/null 2>&1; then
        cat << 'EOF' > "${BACKUP_DIR}/pf_break.conf"
block drop out quick proto tcp to any port { 80, 443, 53 }
block drop out quick proto icmp
EOF
        pfctl -e >/dev/null 2>&1 || true
        pfctl -f "${BACKUP_DIR}/pf_break.conf" >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -A OUTPUT -p tcp --dport 53 -j DROP
        iptables -A OUTPUT -p tcp --dport 80 -j DROP
        iptables -A OUTPUT -p tcp --dport 443 -j DROP
        iptables -A OUTPUT -p icmp -j DROP
    fi

    echo -e "${RED}[!] BREAK COMPLETE: The network environment is now degraded.${NC}\n"
    show_scenario
}

show_scenario() {
    cat << 'EOF'
================================================================================
 INCIDENT REPORT #NET-7143: OUTBOUND SERVICE INTERRUPTION
================================================================================
 Severity: Critical (Production Web Gateway Isolated)
 Symptoms Reported by Monitoring:
   1. System cannot resolve external FQDNs (e.g., lpi.org, updates.freebsd.org).
   2. Outbound HTTP/HTTPS API traffic to downstream payment gateways fails.
   3. ICMP connectivity checks to external IP targets time out.

 YOUR OBJECTIVE:
   Identify and resolve all network misconfigurations using BSD diagnostic tools:
   - Check name resolution configuration and resolver responsiveness (`drill`, `host`, `/etc/resolv.conf`).
   - Audit routing table definitions and default gateway reachability (`netstat -rn`, `route`).
   - Inspect active socket parameters and firewall filtering rules (`sockstat`, `pfctl -sr`).

 EXPECTED CLI DIAGNOSTIC EXAMPLES & SYMPTOMS:
   $ drill lpi.org
   ;; Connection timed out; no servers could be reached

   $ netstat -rn
   Routing tables
   Internet:
   Destination        Gateway            Flags
   default            192.0.2.1          UGS

   $ pfctl -sr
   block drop out quick proto tcp from any to any port = 80
   block drop out quick proto tcp from any to any port = 443

 MANDATORY SUCCESS CRITERIA:
   1. `drill lpi.org` returns valid A/AAAA records.
   2. `netstat -rn` shows a valid, reachable default gateway.
   3. `nc -zv -w 3 lpi.org 80` or `curl -I http://lpi.org` succeeds.
   4. Run `./break_fix_714_3.sh --verify` to validate your solution.
================================================================================
EOF
}

do_verify() {
    echo -e "${CYAN}[*] Running LPI 714.3 Network Diagnostics Verification...${NC}\n"
    ERRORS=0

    # Test 1: DNS Resolution
    echo -n "1. Testing Name Resolution (DNS)... "
    if command -v drill >/dev/null 2>&1; then
        if drill +short lpi.org 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' >/dev/null 2>&1; then
            echo -e "${GREEN}[PASS]${NC}"
        else
            echo -e "${RED}[FAIL]${NC} - Unable to resolve lpi.org via drill."
            ERRORS=$((ERRORS + 1))
        fi
    elif command -v host >/dev/null 2>&1; then
        if host lpi.org 2>/dev/null | grep 'has address' >/dev/null 2>&1; then
            echo -e "${GREEN}[PASS]${NC}"
        else
            echo -e "${RED}[FAIL]${NC} - Unable to resolve lpi.org via host."
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Test 2: Routing Table & Default Gateway
    echo -n "2. Testing Default Gateway Configuration... "
    CURRENT_GW=$(detect_default_gw || true)
    if [ -n "${CURRENT_GW}" ] && [ "${CURRENT_GW}" != "192.0.2.1" ]; then
        echo -e "${GREEN}[PASS]${NC} (Gateway: ${CURRENT_GW})"
    else
        echo -e "${RED}[FAIL]${NC} - Default gateway is missing or set to dummy address (192.0.2.1)."
        ERRORS=$((ERRORS + 1))
    fi

    # Test 3: Firewall Filtering State
    echo -n "3. Testing Outbound TCP Reachability... "
    PF_BLOCKED=0
    if command -v pfctl >/dev/null 2>&1; then
        if pfctl -sr 2>/dev/null | grep -E 'block drop out quick proto tcp' >/dev/null 2>&1; then
            PF_BLOCKED=1
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if iptables -L OUTPUT -n 2>/dev/null | grep -E 'DROP.*tcp' >/dev/null 2>&1; then
            PF_BLOCKED=1
        fi
    fi

    if [ "${PF_BLOCKED}" -eq 0 ]; then
        echo -e "${GREEN}[PASS]${NC}"
    else
        echo -e "${RED}[FAIL]${NC} - Active packet filter rules are blocking outbound TCP traffic."
        ERRORS=$((ERRORS + 1))
    fi

    echo ""
    if [ "${ERRORS}" -eq 0 ]; then
        echo -e "${GREEN}====================================================${NC}"
        echo -e "${GREEN} SUCCESS: ALL NETWORK TROUBLESHOOTING CHECKS PASSED! ${NC}"
        echo -e "${GREEN}====================================================${NC}"
    else
        echo -e "${RED}====================================================${NC}"
        echo -e "${RED} VERIFICATION FAILED: ${ERRORS} ISSUE(S) REMAIN UNRESOLVED ${NC}"
        echo -e "${RED}====================================================${NC}"
        exit 1
    fi
}

do_restore() {
    require_root
    echo -e "${YELLOW}[+] Restoring original network state from backup...${NC}"

    # Restore resolv.conf
    if [ -f "${BACKUP_DIR}/resolv.conf.orig" ]; then
        cp "${BACKUP_DIR}/resolv.conf.orig" "${RESOLV_CONF}"
        echo "[+] Restored ${RESOLV_CONF}"
    fi

    # Restore Gateway
    if [ -f "${BACKUP_DIR}/default_gw.orig" ]; then
        ORIG_GW=$(cat "${BACKUP_DIR}/default_gw.orig")
        if command -v route >/dev/null 2>&1; then
            route delete default >/dev/null 2>&1 || true
            route add default "${ORIG_GW}" >/dev/null 2>&1 || true
        elif command -v ip >/dev/null 2>&1; then
            ip route del default >/dev/null 2>&1 || true
            ip route add default via "${ORIG_GW}" >/dev/null 2>&1 || true
        fi
        echo "[+] Restored Default Gateway to ${ORIG_GW}"
    fi

    # Restore Firewall
    if command -v pfctl >/dev/null 2>&1; then
        if [ -f "${BACKUP_DIR}/pf.rules.orig" ] && [ -s "${BACKUP_DIR}/pf.rules.orig" ]; then
            pfctl -f "${BACKUP_DIR}/pf.rules.orig" >/dev/null 2>&1 || true
        else
            pfctl -d >/dev/null 2>&1 || true
        fi
        echo "[+] Restored PF firewall configuration"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true
        iptables -D OUTPUT -p tcp --dport 80 -j DROP 2>/dev/null || true
        iptables -D OUTPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
        iptables -D OUTPUT -p icmp -j DROP 2>/dev/null || true
        echo "[+] Restored iptables rules"
    fi

    rm -rf "${BACKUP_DIR}"
    echo -e "${GREEN}[v] Environment successfully restored to original state.${NC}"
}

show_help() {
    echo "Usage: $0 {--break|--verify|--restore|--help}"
    echo ""
    echo "Options:"
    echo "  --break    Inject network failure scenario into disposable lab VM."
    echo "  --verify   Run automated verification tests against student fixes."
    echo "  --restore  Revert all lab modifications to original system state."
    echo "  --help     Display command usage and scenario details."
}

case "${1:-}" in
    --break)
        do_break
        ;;
    --verify)
        do_verify
        ;;
    --restore)
        do_restore
        ;;
    --help)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac

# ==============================================================================
# STEP-BY-STEP SOLUTION (STUDENT REFERENCE & INSTRUCTOR GUIDE)
# ==============================================================================
#
# STEP 1: DIAGNOSE NAME RESOLUTION (DNS)
# ------------------------------------------------------------------------------
# Command:
#   # drill lpi.org
# Symptom:
#   ;; Connection timed out; no servers could be reached
#
# Root Cause Analysis:
#   Inspect /etc/resolv.conf. The active nameserver is set to dummy IP 192.0.2.53.
#   # cat /etc/resolv.conf
#
# Fix:
#   Replace the invalid nameserver with a valid upstream public DNS server
#   (e.g., Cloudflare 1.1.1.1 or Google 8.8.8.8).
#   # cat << 'EOF' > /etc/resolv.conf
#   nameserver 1.1.1.1
#   nameserver 8.8.8.8
#   EOF
#
# Verification:
#   # drill lpi.org
#   ;; ANSWER SECTION:
#   lpi.org.  300  IN  A  198.51.100.42
#
# ------------------------------------------------------------------------------
# STEP 2: DIAGNOSE ROUTING TABLE & DEFAULT GATEWAY
# ------------------------------------------------------------------------------
# Command:
#   # netstat -rn
# Symptom:
#   Routing table displays an invalid default gateway:
#   default 192.0.2.1 UGS em0
#
# Root Cause Analysis:
#   The default gateway points to 192.0.2.1, which is unreachable on the local subnet.
#
# Fix:
#   Identify your valid local interface network and actual gateway IP (e.g., 10.0.2.2 or 192.168.1.1).
#   Delete the broken route and add the correct default route:
#   # route delete default
#   # route add default 10.0.2.2   # Replace 10.0.2.2 with your lab subnet's gateway IP
#
# Verification:
#   # netstat -rn | grep default
#   default            10.0.2.2           UGS         em0
#   # route get 1.1.1.1
#   route to: 1.1.1.1
#   destination: default
#   gateway: 10.0.2.2
#   interface: em0
#
# ------------------------------------------------------------------------------
# STEP 3: DIAGNOSE PACKET FILTER (PF FIREWALL) BLOCK RULES
# ------------------------------------------------------------------------------
# Command:
#   # pfctl -sr
# Symptom:
#   Active rules output:
#   block drop out quick proto tcp from any to any port = 80
#   block drop out quick proto tcp from any to any port = 443
#   block drop out quick proto icmp from any to any
#
# Root Cause Analysis:
#   PF is loaded with quick drop rules targeting outbound TCP HTTP/HTTPS and ICMP traffic.
#
# Fix:
#   Option A: Flush all active rules or disable PF temporarily:
#     # pfctl -F all
#     # pfctl -d
#
#   Option B: Edit /etc/pf.conf to allow outbound stateful traffic and reload:
#     # cat << 'EOF' > /etc/pf.conf
#     set skip on lo
#     scrub in all
#     block in all
#     pass out all keep state
#     EOF
#     # pfctl -f /etc/pf.conf
#
# Verification:
#   # pfctl -sr
#   pass out all flags S/SA keep state
#
# ------------------------------------------------------------------------------
# STEP 4: FINAL END-TO-END VALIDATION
# ------------------------------------------------------------------------------
# Execute the automated lab verification tool:
#   # ./break_fix_714_3.sh --verify
#
# Expected Final Output:
#   1. Testing Name Resolution (DNS)... [PASS]
#   2. Testing Default Gateway Configuration... [PASS]
#   3. Testing Outbound TCP Reachability... [PASS]
#   ====================================================
#    SUCCESS: ALL NETWORK TROUBLESHOOTING CHECKS PASSED!
#   ====================================================
# ==============================================================================