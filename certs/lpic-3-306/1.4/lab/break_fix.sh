#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 306 (Exam 306-300 v3.0) - Topic 364 / 1.4: Single Node High Availability
# Break & Fix Lab: Network High Availability (Link Aggregation & Bonding Failover)
#
# Official References:
#   - LPIC-3 306 Exam Overview: https://www.lpi.org/our-certifications/lpic-3-306-overview/
#   - Linux Ethernet Bonding Driver Documentation: https://www.kernel.org/doc/Documentation/networking/bonding.txt
# ==============================================================================

set -euo pipefail

# Ensure script is executed as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This lab script must be executed with root privileges." >&2
    exit 1
fi

BOND_IF="bond0"
SLAVE1="veth0"
SLAVE2="veth1"
PEER1="veth0-peer"
PEER2="veth1-peer"
NS_NAME="ns-upstream"
GATEWAY_IP="192.168.50.1"
HOST_IP="192.168.50.10"
NETMASK="/24"

echo "========================================================================"
echo " LPIC-3 306: Single Node High Availability - Network Bonding Lab Setup"
echo "========================================================================"
echo "[*] Initializing virtual network topology for High Availability testing..."

# 1. Clean up potential leftover state from previous runs
ip netns del "${NS_NAME}" 2>/dev/null || true
ip link del "${BOND_IF}" 2>/dev/null || true
ip link del "${SLAVE1}" 2>/dev/null || true
ip link del "${SLAVE2}" 2>/dev/null || true
modprobe -r bonding 2>/dev/null || true

# 2. Load bonding kernel module
modprobe bonding

# 3. Create isolated upstream network namespace (simulating upstream switch)
ip netns add "${NS_NAME}"

# 4. Create veth interface pairs representing redundant physical NICs
ip link add "${SLAVE1}" type veth peer name "${PEER1}"
ip link add "${SLAVE2}" type veth peer name "${PEER2}"

# 5. Move peer interfaces to the upstream namespace
ip link set "${PEER1}" netns "${NS_NAME}"
ip link set "${PEER2}" netns "${NS_NAME}"

# 6. Configure upstream namespace bridge & gateway interface
ip netns exec "${NS_NAME}" ip link add name br0 type bridge
ip netns exec "${NS_NAME}" ip link set "${PEER1}" master br0
ip netns exec "${NS_NAME}" ip link set "${PEER2}" master br0
ip netns exec "${NS_NAME}" ip link set br0 up
ip netns exec "${NS_NAME}" ip link set "${PEER1}" up
ip netns exec "${NS_NAME}" ip link set "${PEER2}" up
ip netns exec "${NS_NAME}" addr add "${GATEWAY_IP}${NETMASK}" dev br0

# 7. Create bonding interface on host in active-backup mode (mode 1)
ip link add "${BOND_IF}" type bond mode active-backup

# 8. Enslave physical host interfaces to bond0
ip link set "${SLAVE1}" master "${BOND_IF}"
ip link set "${SLAVE2}" master "${BOND_IF}"

# 9. Configure host bonding IP and bring interfaces up
ip addr add "${HOST_IP}${NETMASK}" dev "${BOND_IF}"
ip link set "${SLAVE1}" up
ip link set "${SLAVE2}" up
ip link set "${BOND_IF}" up

echo "[*] Base active-backup topology established."
echo "[*] Injecting configuration flaw into Single Node HA bonding stack..."

# ------------------------------------------------------------------------------
# INJECT BREAKAGE:
# 1. Disable MII Link Monitoring (miimon=0) and ARP monitoring (arp_interval=0).
# 2. Simulate physical link failure on primary link (PEER1 down).
# Result: Host fails to detect primary link degradation, preventing slave failover.
# ------------------------------------------------------------------------------

# Disable link health polling mechanisms via sysfs
echo 0 > /sys/class/net/"${BOND_IF}"/bonding/miimon
echo 0 > /sys/class/net/"${BOND_IF}"/bonding/arp_interval

# Set primary slave explicitly to SLAVE1
echo "${SLAVE1}" > /sys/class/net/"${BOND_IF}"/bonding/primary

# Simulate link fault at the physical layer of primary path
ip netns exec "${NS_NAME}" ip link set "${PEER1}" down

echo "========================================================================"
echo " [!] LAB SCENARIO LOADED - SINGLE NODE HA NETWORK BREAKAGE INJECTED"
echo "========================================================================"
cat << 'EOF'

PROBLEM STATEMENT:
You are managing a mission-critical database node configured with Single Node
Network High Availability using Linux Ethernet Bonding (mode 1: active-backup).
The primary physical network link experienced a hardware port down event on the
upstream switch side.

SYMPTOMS OBSERVED:
- Outbound network traffic to the gateway (192.168.50.1) is experiencing 100% packet loss.
- Executing: `ping -c 3 192.168.50.1` fails completely.
- The slave interface 'veth0' is marked down at physical carrier level, but 'bond0'
  has NOT failed over to the operational backup interface 'veth1'.

STUDENT OBJECTIVES:
1. Inspect the kernel bonding driver state in `/proc/net/bonding/bond0`.
2. Identify why the bonding driver failed to detect the link state failure of 'veth0'.
3. Reconfigure the live bonding parameters via sysfs (`/sys/class/net/bond0/bonding/`)
   or IP tools to restore automatic failover capability with a 100ms link monitoring interval.
4. Verify that 'bond0' automatically shifts the active slave to 'veth1' and ping connectivity
   to 192.168.50.1 is restored without resetting host IP addresses.

VERIFICATION COMMAND:
  ping -c 4 192.168.50.1

EOF

# ==============================================================================
# STEP-BY-STEP SOLUTION (COMMENTED OUT)
# ==============================================================================
# To view the solution, read the commented section below.
#
# ------------------------------------------------------------------------------
# TROUBLESHOOTING & RESOLUTION STEPS:
# ------------------------------------------------------------------------------
# Step 1: Diagnose the active bonding status and kernel configuration
#   cat /proc/net/bonding/bond0
#
#   Expected Output Analysis:
#   - Bonding Mode: Fault Tolerance (Active-Backup)
#   - Primary Slave: veth0
#   - Currently Active Slave: veth0 (or none)
#   - MII Status: down / unknown
#   - MII Polling Interval (ms): 0  <-- ROOT CAUSE: Monitoring is disabled (0ms).
#
# Step 2: Inspect sysfs parameters for bond0
#   cat /sys/class/net/bond0/bonding/miimon
#   # Output: 0
#
# Step 3: Configure MII link monitoring to poll link state every 100ms
#   echo 100 > /sys/class/net/bond0/bonding/miimon
#
#   Optionally, configure updelay and downdelay to prevent link flapping:
#   echo 200 > /sys/class/net/bond0/bonding/downdelay
#   echo 200 > /sys/class/net/bond0/bonding/updelay
#
# Step 4: Verify kernel driver state update
#   cat /proc/net/bonding/bond0
#
#   Expected Output:
#   - MII Polling Interval (ms): 100
#   - Currently Active Slave: veth1  <-- Driver automatically evicted failed veth0!
#
# Step 5: Test HA failover and network layer connectivity
#   ping -c 4 192.168.50.1
#
# Step 6: Persistent configuration rule (for production systemd-networkd / sysconfig / netplan):
#   If using legacy /etc/sysconfig/network-scripts/ifcfg-bond0:
#     BONDING_OPTS="mode=1 miimon=100 updelay=200 downdelay=200 primary=veth0"
#
#   If using Netplan (/etc/netplan/01-netcfg.yaml):
#     bonds:
#       bond0:
#         interfaces: [veth0, veth1]
#         parameters:
#           mode: active-backup
#           mii-monitor-interval: 100
#           primary: veth0
# ==============================================================================