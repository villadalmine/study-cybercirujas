#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist (702-100) - Topic 714.2: Basic Network Configuration
# Script Type: Production SRE Break & Fix Lab Environment
# Author: Senior SRE & Principal Platform Architect
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# Target OS: FreeBSD / OpenBSD / NetBSD (or BSD-compatible lab VM)
# ==============================================================================
# WARNING: Run this script ONLY on a disposable, isolated laboratory VM.
# It will intentionally disrupt network interfaces, routing tables, and DNS.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Privileges & Environment Sanity Checks
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This break-and-fix lab script must be executed as root." >&2
    exit 1
fi

UNAME_S=$(uname -s)
BACKUP_DIR="/var/backups/lpi702_topic714_2_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${BACKUP_DIR}"

echo "======================================================================"
echo "  LPI 702-100 | Topic 714.2: Basic Network Configuration Break & Fix"
echo "  Detected OS: ${UNAME_S}"
echo "  Backup Directory: ${BACKUP_DIR}"
echo "======================================================================"

# Detect primary active network interface
PRIMARY_IF=""
if [[ "${UNAME_S}" == "FreeBSD" ]] || [[ "${UNAME_S}" == "NetBSD" ]]; then
    PRIMARY_IF=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}' || true)
    if [[ -z "${PRIMARY_IF}" ]]; then
        PRIMARY_IF=$(ifconfig -l | awk '{print $1}')
    fi
elif [[ "${UNAME_S}" == "OpenBSD" ]]; then
    PRIMARY_IF=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}' || true)
    if [[ -z "${PRIMARY_IF}" ]]; then
        PRIMARY_IF=$(ifconfig | grep -E '^[a-z0-9]+:' | head -n1 | cut -d: -f1)
    fi
else
    # Linux fallback for lab container simulation
    PRIMARY_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1 || true)
    if [[ -z "${PRIMARY_IF}" ]]; then
        PRIMARY_IF=$(ifconfig -a 2>/dev/null | grep -E '^[a-z0-9]+' | head -n1 | awk '{print $1}' || echo "eth0")
    fi
fi

if [[ -z "${PRIMARY_IF}" ]]; then
    echo "[ERROR] Could not determine primary network interface." >&2
    exit 1
fi

echo "[+] Primary interface identified: ${PRIMARY_IF}"

# ------------------------------------------------------------------------------
# 1. Configuration Backup Phase
# ------------------------------------------------------------------------------
echo "[+] Backing up current networking configuration files..."

FILES_TO_BACKUP=(
    "/etc/rc.conf"
    "/etc/rc.conf.d/netif"
    "/etc/rc.conf.d/routing"
    "/etc/resolv.conf"
    "/etc/hosts"
    "/etc/nsswitch.conf"
    "/etc/mygate"
    "/etc/myname"
    "/etc/hostname.${PRIMARY_IF}"
)

for file in "${FILES_TO_BACKUP[@]}"; do
    if [[ -f "${file}" ]]; then
        cp -p "${file}" "${BACKUP_DIR}/"
        echo "    - Saved ${file}"
    fi
done

# ------------------------------------------------------------------------------
# 2. Inject Controlled System Breakages
# ------------------------------------------------------------------------------
echo "[!] Injecting controlled network failures across interface, routing, and DNS..."

# --- BREAK 1: Misconfigure IP Address & Subnet Mask (L1/L2 Subnet Mismatch) ---
# Set an invalid netmask (/32 255.255.255.255) on runtime interface and persist bad config
if [[ "${UNAME_S}" == "FreeBSD" ]]; then
    # Inject persistent error into /etc/rc.conf
    sed -i '' "/ifconfig_${PRIMARY_IF}/d" /etc/rc.conf 2>/dev/null || true
    sed -i '' "/defaultrouter/d" /etc/rc.conf 2>/dev/null || true
    echo "ifconfig_${PRIMARY_IF}=\"inet 192.168.50.254 netmask 255.255.255.255 description broken_lab_if\"" >> /etc/rc.conf
    echo "defaultrouter=\"192.168.50.1\"" >> /etc/rc.conf
    
    # Apply broken runtime configuration
    ifconfig "${PRIMARY_IF}" inet 192.168.50.254 netmask 255.255.255.255 down 2>/dev/null || true
    ifconfig "${PRIMARY_IF}" up 2>/dev/null || true

elif [[ "${UNAME_S}" == "OpenBSD" ]]; then
    # Inject persistent error into /etc/hostname.<if> and /etc/mygate
    echo "inet 192.168.50.254 255.255.255.255 NONE description broken_lab_if" > "/etc/hostname.${PRIMARY_IF}"
    echo "192.168.50.1" > /etc/mygate
    
    # Apply broken runtime configuration
    ifconfig "${PRIMARY_IF}" inet 192.168.50.254 netmask 255.255.255.255 down 2>/dev/null || true
    ifconfig "${PRIMARY_IF}" up 2>/dev/null || true

else
    # Generic BSD/Linux break simulation
    ifconfig "${PRIMARY_IF}" 192.168.50.254 netmask 255.255.255.255 up 2>/dev/null || true
fi

# --- BREAK 2: Flush & Corrupt Kernel Routing Table ---
route -n flush 2>/dev/null || route flush 2>/dev/null || true
# Add a rogue non-routable default gateway pointing to invalid interface/next-hop
route add default 192.168.50.1 2>/dev/null || true

# --- BREAK 3: Corrupt Resolver & Name Services ---
# Truncate /etc/resolv.conf and point to a non-responsive loopback address with syntax noise
cat << 'EOF' > /etc/resolv.conf
# Corrupted Resolver Config for LPI 702 Lab
nameserver 127.0.0.53
options timeout:invalid_value
search internal.broken.domain.invalid
EOF

# Mutate /etc/nsswitch.conf if present (FreeBSD/NetBSD) to bypass 'dns' lookup entirely
if [[ -f /etc/nsswitch.conf ]]; then
    sed -i '' 's/^hosts:.*/hosts: files/' /etc/nsswitch.conf 2>/dev/null || \
    sed -i 's/^hosts:.*/hosts: files/' /etc/nsswitch.conf 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 3. Present Student Lab Challenge Banner & Symptoms
# ------------------------------------------------------------------------------
cat << EOF

================================================================================
  LAB INCIDENT REPORT: INC-7142-NET-01 (BREAK & FIX ACTIVE)
================================================================================
  Topic: 714.2 Basic Network Configuration (Weight: 5)
  Target System: ${UNAME_S} (${PRIMARY_IF})

  [SYMPTOMS REPORTED BY APPLICATION TEAM]
  1. Complete outbound network isolation. Neither local gateway nor internet
     end-points are reachable.
  2. Local hostname lookup succeeds for 'localhost', but all external FQDN
     resolution attempts (e.g., 'pkg.freebsd.org' or 'ftp.openbsd.org') fail instantly.
  3. System reboots fail to recover network access; configuration state is broken 
     at runtime and persisted across boot configs.

  [STUDENT OBJECTIVES]
  1. Diagnose the network interface configuration (${PRIMARY_IF}) including IP,
     netmask, broadcast, and link state.
  2. Identify why default route addition fails or routes traffic into a blackhole.
  3. Restore standard DNS name resolution mechanics (/etc/resolv.conf & /etc/nsswitch.conf).
  4. Ensure all changes are properly persisted in system boot configuration files 
     (/etc/rc.conf for FreeBSD, /etc/hostname.${PRIMARY_IF} & /etc/mygate for OpenBSD).
  5. Validate full connectivity with ping, netstat/route, and host/dig commands.

  [DIAGNOSTIC TOOLBOX AVAILABLE]
  - ifconfig ${PRIMARY_IF}
  - netstat -rn  (or 'route -n show')
  - route get default
  - host / nslookup / ping
  - cat /etc/resolv.conf /etc/nsswitch.conf

  [BACKUP LOCATION]
  Original config snapshot saved at: ${BACKUP_DIR}

================================================================================
  BEGIN TROUBLESHOOTING NOW. DO NOT CHEAT BY READING THE SCRIPT SOURCE SOLUTION!
================================================================================

EOF

exit 0

# ==============================================================================
# COMPREHENSIVE STEP-BY-STEP SOLUTION (STUDENT REFERENCE & EXAM GUIDANCE)
# ==============================================================================
# 
# OFFICIAL REFERENCE CITATIONS:
# - LPI BSD Specialist Objectives: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# - FreeBSD Handbook (Network Configuration): https://docs.freebsd.org/en/books/handbook/network/
# - OpenBSD Manual Pages (ifconfig, hostname.if, mygate): https://man.openbsd.org/
#
# ------------------------------------------------------------------------------
# ARCHITECTURAL MECHANICS & TROUBLESHOOTING METHODOLOGY
# ------------------------------------------------------------------------------
# In BSD systems, networking configuration exists in two domains:
# 1. Kernel Runtime State: Modifiable instantly via `ifconfig` and `route`.
# 2. Boot Persistence State: Processed during init via `/etc/rc` scripts.
#    - FreeBSD: `/etc/rc.conf` (parsed by `/etc/rc.d/netif` and `/etc/rc.d/routing`)
#    - OpenBSD: `/etc/hostname.<interface>` and `/etc/mygate` (parsed by `/etc/netstart`)
#    - NetBSD: `/etc/rc.conf` and `/etc/ifconfig.<interface>`
#
# The failure injected in this lab comprises 3 distinct layers of the OSI model:
# - Layer 3 Subnet Isolation: The netmask was set to 255.255.255.255 (/32), causing 
#   the local kernel to consider the local router IP outside its broadcast domain.
# - Layer 3 Routing Table Corruption: The default gateway route points to an invalid 
#   host or missing broadcast interface.
# - Layer 7 / Resolver Failure: `/etc/resolv.conf` points to a non-existent local DNS 
#   stub, and `/etc/nsswitch.conf` lacks the `dns` keyword in the `hosts:` database line.
#
# ------------------------------------------------------------------------------
# DIAGNOSIS & REPAIR EXECUTABLE STEPS
# ------------------------------------------------------------------------------
#
# STEP 1: Inspect and Fix the Runtime & Persistent Interface Configuration
# ------------------------------------------------------------------------------
# Check interface status:
#   # ifconfig vtnet0
# (Expected Output shows incorrect netmask 0xffffffff / 255.255.255.255)
#
# Fix Runtime (FreeBSD / OpenBSD / NetBSD):
#   # ifconfig vtnet0 inet 192.168.1.150 netmask 255.255.255.0 broadcast 192.168.1.255 up
#
# Fix Boot Persistence (FreeBSD - /etc/rc.conf):
# Edit /etc/rc.conf and set syntactically valid parameters:
#   ------------------------------------------------------------------------
#   # /etc/rc.conf snippet
#   hostname="bsd-lab-node.local"
#   ifconfig_vtnet0="inet 192.168.1.150 netmask 255.255.255.0"
#   defaultrouter="192.168.1.1"
#   ------------------------------------------------------------------------
#
# Fix Boot Persistence (OpenBSD - /etc/hostname.vtnet0 & /etc/mygate):
# Edit /etc/hostname.vtnet0:
#   ------------------------------------------------------------------------
#   inet 192.168.1.150 255.255.255.0 NONE description "Primary Interface"
#   ------------------------------------------------------------------------
# Edit /etc/mygate:
#   ------------------------------------------------------------------------
#   192.168.1.1
#   ------------------------------------------------------------------------
#
# STEP 2: Re-establish Routing Table Integrity
# ------------------------------------------------------------------------------
# View current kernel routing table:
#   # netstat -rn
#   # route get default
#
# Flush corrupt routes and add valid default gateway:
#   # route -n flush
#   # route add default 192.168.1.1
#
# Expected CLI verification output:
#   # route get 8.8.8.8
#   route to: 8.8.8.8
#   destination: default
#   gateway: 192.168.1.1
#   interface: vtnet0
#   flags: <UP,GATEWAY,DONE,STATIC>
#
# STEP 3: Repair Resolver & Name Services Switch
# ------------------------------------------------------------------------------
# Fix /etc/resolv.conf syntax and valid Upstream Nameservers:
#   # cat << 'EOF' > /etc/resolv.conf
#   search local.lan
#   nameserver 1.1.1.1
#   nameserver 8.8.8.8
#   options timeout:2 attempts:3
#   EOF
#
# Fix /etc/nsswitch.conf (FreeBSD / NetBSD) to enable DNS lookup fallback:
#   # edit /etc/nsswitch.conf
#   Ensure the hosts entry reads:
#   hosts: files dns
#
# STEP 4: Service Restart & Empirical Verification Commands
# ------------------------------------------------------------------------------
# On FreeBSD, reload network stack without rebooting:
#   # /etc/rc.d/netif restart && /etc/rc.d/routing restart
#
# On OpenBSD, reload network configuration:
#   # sh /etc/netstart
#
# Validate ICMP Reachability to Local Gateway & Internet:
#   # ping -c 3 192.168.1.1
#   PING 192.168.1.1 (192.168.1.1): 56 data bytes
#   64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=0.452 ms
#   --- 192.168.1.1 ping statistics ---
#   3 packets transmitted, 3 packets received, 0.0% packet loss
#
# Validate DNS Resolution:
#   # host www.lpi.org
#   www.lpi.org has address 198.51.100.42
#   www.lpi.org has IPv6 address 2001:db8::42
#
# ==============================================================================