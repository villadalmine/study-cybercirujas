#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Enterprise Security (Exam 303-300, Version 3.0)
# Topic 5.1: Network Security (Weight: 16.67)
# Reference: https://www.lpi.org/our-certifications/lpic-3-303-overview/
#
# LAB TITLE: Production Gateway Stateful Firewall & IP Forwarding Break & Fix
# AUTHOR: Principal Platform Architect & Senior SRE Instructor
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
CYAN='\e[0;36m'
BOLD='\e[1m'
NC='\e[0m'

# Ensure script is executed as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be executed with root privileges.${NC}" >&2
    exit 1
fi

echo -e "${CYAN}${BOLD}"
echo "========================================================================"
echo " LPIC-3 303 (v3.0) Topic 5.1 - Network Security Break & Fix Scenario"
echo "========================================================================"
echo -e "${NC}"

# Step 1: Pre-flight checks and package dependency installation
echo -e "${YELLOW}[1/4] Checking and installing required packages (nftables, iproute2, procps)...${NC}"
if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq nftables iproute2 procps tcpdump &>/dev/null
elif command -v dnf &>/dev/null; then
    dnf install -y -q nftables iproute procps-ng tcpdump &>/dev/null
elif command -v yum &>/dev/null; then
    yum install -y -q nftables iproute procps-ng tcpdump &>/dev/null
fi

# Step 2: Backup existing nftables configuration if present
echo -e "${YELLOW}[2/4] Backing up existing nftables configuration...${NC}"
if [[ -f /etc/nftables.conf ]]; then
    cp /etc/nftables.conf /etc/nftables.conf.lpic3.bak
fi

# Step 3: Inject controlled misconfigurations (Break Phase)
echo -e "${YELLOW}[3/4] Injecting network security misconfigurations...${NC}"

# Misconfiguration A: Kernel IPv4 forwarding disabled via sysctl override
cat << 'EOF' > /etc/sysctl.d/99-lpic3-netsec-broken.conf
# LPIC-3 Topic 5.1 Lab Override - Disabling IPv4 Forwarding
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0
net.ipv4.conf.default.forwarding = 0
EOF
sysctl --system &>/dev/null || sysctl -p /etc/sysctl.d/99-lpic3-netsec-broken.conf &>/dev/null

# Misconfiguration B: Broken nftables stateful firewall ruleset
cat << 'EOF' > /etc/nftables.conf
#!/usr/sbin/nft -f

# Flush existing ruleset
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Localhost traffic allowed
        iif "lo" accept

        # BROKEN: Missing 'ct state established,related accept' rule
        # BROKEN: Missing ICMP Path MTU Discovery (type destination-unreachable)

        # Only allow fresh SSH connections (SYN state only implicitly allowed, but return packets dropped)
        tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # BROKEN: Drop stateful return traffic across routed interfaces
        # BROKEN: Missing masquerading/NAT for egress interface
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

# Apply the broken nftables configuration and ensure service is active
nft -f /etc/nftables.conf
systemctl enable nftables &>/dev/null || true
systemctl restart nftables &>/dev/null || true

echo -e "${YELLOW}[4/4] Misconfigurations successfully injected.${NC}\n"

# Step 4: Display student briefing
echo -e "${BOLD}${RED}=== LAB BRIEFING: SYSTEM IS BROKEN ===${NC}"
echo -e "${BOLD}Role:${NC} Senior Infrastructure Security Engineer / SRE"
echo -e "${BOLD}Target Topic:${NC} LPIC-3 303 - Topic 5.1 (Network Security)"
echo -e "${BOLD}Scenario Description:${NC}"
echo -e "A production Linux router/gateway running ${CYAN}nftables${NC} recently underwent a automated policy audit."
echo -e "Following the update, the following critical incidents were reported:"
echo -e "  1. Incoming SSH connections hang or time out immediately after authentication."
echo -e "  2. Routed traffic between internal segments fails completely."
echo -e "  3. Path MTU Discovery is broken, causing large TCP packets to drop silently."
echo ""
echo -e "${BOLD}Expected Objectives to Complete:${NC}"
echo -e "  1. Re-enable kernel-level IPv4 packet forwarding persistently."
echo -e "  2. Fix the ${CYAN}nftables${NC} filter table to properly handle connection tracking (${CYAN}ct state established,related${NC})."
echo -e "  3. Allow required ICMP types for Path MTU Discovery (PMTUD) in the input chain."
echo -e "  4. Ensure forward chain permits established/related stateful routed traffic."
echo -e "  5. Persist the valid ${CYAN}nftables${NC} configuration to withstand system reboots."
echo ""
echo -e "${BOLD}Diagnostic Commands to Start:${NC}"
echo -e "  $ ${YELLOW}sysctl net.ipv4.ip_forward${NC}"
echo -e "  $ ${YELLOW}nft list ruleset${NC}"
echo -e "  $ ${YELLOW}systemctl status nftables${NC}"
echo -e "  $ ${YELLOW}tcpdump -nn -i any icmp or tcp port 22${NC}"
echo -e "========================================================================\n"

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (LPIC-3 303 Topic 5.1)
# ==============================================================================
# To solve this lab, perform the following step-by-step remediation:
#
# STEP 1: Diagnose Kernel IPv4 Forwarding
# Check the current status of packet forwarding:
#   # sysctl net.ipv4.ip_forward
# Output: net.ipv4.ip_forward = 0
#
# Fix: Remove or update the broken sysctl config in /etc/sysctl.d/
#   # rm -f /etc/sysctl.d/99-lpic3-netsec-broken.conf
#   # cat << 'EOF' > /etc/sysctl.d/99-lpic3-netsec.conf
#   net.ipv4.ip_forward = 1
#   EOF
#   # sysctl --system
#
# STEP 2: Inspect and Analyze Broken nftables Ruleset
# Inspect existing rules:
#   # nft list ruleset
#
# Root Cause Analysis:
# - Input policy is DROP. Without `ct state established,related accept`, return traffic 
#   for outbound connections initiated by the server or SSH response packets are dropped.
# - ICMP packets necessary for PMTUD (`icmp type { destination-unreachable, time-exceeded }`)
#   are missing, causing TCP session stalls over IPsec/GRE/WireGuard or low-MTU paths.
# - Forward policy is DROP without stateful tracking or forwarding allowances.
#
# STEP 3: Write and Apply Production-Grade Synthetic Correct Ruleset
# Update /etc/nftables.conf with proper hooks, priorities, and conntrack rules:
#
# cat << 'EOF' > /etc/nftables.conf
# #!/usr/sbin/nft -f
# 
# flush ruleset
# 
# table inet filter {
#     chain input {
#         type filter hook input priority filter; policy drop;
# 
#         # Allow loopback
#         iif "lo" accept
# 
#         # Stateful connection tracking (Crucial for return traffic)
#         ct state established,related accept
#         ct state invalid drop
# 
#         # Allow ICMP for diagnostic & Path MTU Discovery (PMTUD)
#         icmp type { destination-unreachable, router-advertisement, param-problem, time-exceeded, echo-request } accept
#         icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
# 
#         # Service rules
#         tcp dport 22 accept
#     }
# 
#     chain forward {
#         type filter hook forward priority filter; policy drop;
# 
#         # Allow stateful routed traffic
#         ct state established,related accept
#         ct state invalid drop
#     }
# 
#     chain output {
#         type filter hook output priority filter; policy accept;
#     }
# }
# EOF
#
# STEP 4: Apply and Persist Configuration
# Apply configuration:
#   # nft -f /etc/nftables.conf
#
# Enable service persistence across reboot:
#   # systemctl restart nftables
#   # systemctl enable nftables
#
# STEP 5: Verification
#   # sysctl net.ipv4.ip_forward
#   Expected: net.ipv4.ip_forward = 1
#
#   # nft list ruleset
#   Verify `ct state established,related accept` is present in both input and forward chains.
# ==============================================================================