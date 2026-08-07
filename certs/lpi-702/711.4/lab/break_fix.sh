#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist (Exam 702-100) - Topic 711.4: Hardware Configuration
# Weight: 3.33 | Production Lab Scenario: "The Phantom Interface & Locked Storage"
# Author: Senior SRE & Principal Platform Architect
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
# WARNING: Run this script ONLY inside a disposable test VM running FreeBSD/BSD.
# ==============================================================================

set -euo pipefail

# Color definitions for output
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_BACKUP_DIR="/var/backups/lpi702_topic711.4"

# ------------------------------------------------------------------------------
# 1. PRE-FLIGHT CHECKS & BACKUP CREATION
# ------------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}[ERROR] This break-and-fix script must be executed as root.${NC}" >&2
    exit 1
fi

echo -e "${CYAN}[+] Creating backup directory at ${LOG_BACKUP_DIR}...${NC}"
mkdir -p "${LOG_BACKUP_DIR}"

# Backup critical hardware configuration files if they exist
for file in /boot/loader.conf /etc/rc.conf /etc/sysctl.conf /etc/devfs.rules; do
    if [[ -f "$file" ]]; then
        cp "$file" "${LOG_BACKUP_DIR}/$(basename "$file").bak"
    fi
done

# ------------------------------------------------------------------------------
# 2. CONTROLLED BREAKAGE INJECTION (Topic 711.4 Mechanisms)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[!] Injecting controlled hardware configuration faults...${NC}"

# Fault A: loader.conf corruption (Kernel module load suppression & invalid tunable)
cat << 'EOF' >> /boot/loader.conf

# --- BEGIN INCIDENT 711.4 INJECTED CONFIGURATION ---
# Misconfigured driver disable flag and invalid module syntax
if_vtnet_load="NO"
hw.vtnet.csum_disable="INVALID_VALUE_1"
if_re_load="CORRUPTED_YES"
hw.pci.enable_msix="0"
# --- END INCIDENT 711.4 INJECTED CONFIGURATION ---
EOF

# Fault B: devfs.rules lockup (Restrictive device node permissions for NVMe/virtio block)
cat << 'EOF' > /etc/devfs.rules
[system_rules=10]
add path 'ada*' mode 0600 group wheel
add path 'da*' mode 0600 group wheel
add path 'vtbd*' mode 0000 group wheel
add path 'nvd*' mode 0600 group wheel
EOF

# Apply misconfigured devfs rules to active environment if devfs command exists
if command -v devfs &>/dev/null; then
    sysctl devfs.rulesets.system_ruleset=10 2>/dev/null || true
    devfs rule applyset 2>/dev/null || true
fi

# Fault C: Unload virtio network kernel module dynamically if loaded
if command -v kldunload &>/dev/null; then
    kldunload if_vtnet 2>/dev/null || true
    kldunload if_re 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 3. INCIDENT BRIEFING & DIAGNOSTIC OBJECTIVES DISPLAY
# ------------------------------------------------------------------------------
cat << EOF

================================================================================
  LPI 702 BSD SPECIALIST | TOPIC 711.4 HARDWARE CONFIGURATION BREAK-AND-FIX
================================================================================
  Status: INCIDENT ACTIVE - Production Degradation Simulated
  Target System: BSD Kernel Subsystems (devfs, kld, loader, sysctl, hardware tree)
  Official Documentation: https://www.lpi.org/our-certifications/bsd-specialist-overview/
================================================================================

[INCIDENT SUMMARY]
A night shift automated kernel tuning update broke hardware initialization on this
production node. Network interfaces have disappeared from the system tree, storage
monitoring daemons report permission failures accessing raw disk nodes (/dev/vtbd* or /dev/ada*),
and non-standard PCI MSI-X interrupt allocation has degraded device throughput.

[SYMPTOMS OBSERVED]
1. Network interfaces (e.g., vtnet0 / re0) are missing from 'ifconfig' and 'kldstat'.
2. The kernel dmesg log displays tunable parse warnings at early boot.
3. Disk hardware nodes under /dev/ (e.g., /dev/vtbd0, /dev/ada0) report 'Permission Denied'
   for standard SRE monitoring utilities running under non-wheel user groups.
4. PCI device tree ('devinfo -v' or 'pciconf -lv') lists unattached hardware devices.

[STUDENT OBJECTIVES]
1. Inspect early boot hardware detection using 'dmesg', 'devinfo', and 'pciconf'.
2. Audit kernel module loader configuration in '/boot/loader.conf' and fix invalid tunables.
3. Dynamically re-load the required network interface driver modules using 'kldload'.
4. Audit and remediate restrictive devfs permissions in '/etc/devfs.rules'.
5. Restore full PCI MSI-X interrupt capabilities and verify hardware state via 'sysctl'.

================================================================================
  Type 'exit' and start troubleshooting. The solution is embedded below!
================================================================================
EOF

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & ARCHITECTURAL DEEP-DIVE (FOR INSTRUCTOR / STUDENT)
# ==============================================================================
#
# ARCHITECTURAL MECHANICS (Topic 711.4):
# In BSD operating systems (FreeBSD/DragonFlyBSD), hardware configuration spans
# three distinct lifecycle phases:
# 1. Boot Loader Stage (/boot/loader.conf): Passes environment variables and
#    loads kernel modules (.ko) prior to kernel initialization.
# 2. Kernel Hardware Probing (dmesg, devinfo, pciconf): The bus architecture
#    (pci, isa, usb, cam) probes devices and attaches matching driver modules.
# 3. Runtime Device Management (devfs, sysctl, kldload): Manages dynamic node
#    creation under /dev, tuning kernel OIDs, and loading modules post-boot.
#
# ------------------------------------------------------------------------------
# STEP 1: HARDWARE DIAGNOSTICS & ENUMERATION
# ------------------------------------------------------------------------------
# Identify unattached PCI hardware and driver status:
#
# $ pciconf -lv
# Expected output showing unattached network device:
# virtio_pci0@pci0:0:3:0:  class=0x020000 rev=0x00 chip=0x10001af4 rev=0x00
#     vendor     = 'Red Hat, Inc.'
#     device     = 'Virtio network device'
#     class      = network
#
# Inspect kernel hardware attachment tree:
# $ devinfo -v
#
# Inspect kernel log for driver attachment failures or missing modules:
# $ dmesg | grep -E "(vtnet|re|ada|vtbd|loader)"
#
# ------------------------------------------------------------------------------
# STEP 2: FIX LOADER CONFIGURATION (/boot/loader.conf)
# ------------------------------------------------------------------------------
# Edit /boot/loader.conf to remove corrupted tunables and explicitly enable drivers.
#
# Open /boot/loader.conf in your editor:
# $ vi /boot/loader.conf
#
# Remove or modify the broken block:
# - Remove: if_vtnet_load="NO"
# - Remove: hw.vtnet.csum_disable="INVALID_VALUE_1"
# - Remove: if_re_load="CORRUPTED_YES"
# - Change: hw.pci.enable_msix="1"
#
# Valid syntactically correct manifest for /boot/loader.conf:
# ------------------------------------------------------------------------------
# # Enable VirtIO Network Driver
# if_vtnet_load="YES"
# # Enable PCI MSI-X Interrupt Vectoring
# hw.pci.enable_msix="1"
# # Ensure CAM SCSI/SATA subsystem support
# cam_load="YES"
# ------------------------------------------------------------------------------
#
# ------------------------------------------------------------------------------
# STEP 3: DYNAMIC KERNEL MODULE MANAGEMENT (Runtime Fix)
# ------------------------------------------------------------------------------
# Manually load the correct network driver without rebooting:
#
# $ kldload if_vtnet
# (Or for Realtek hardware: $ kldload if_re)
#
# Verify driver module status:
# $ kldstat -v | grep if_vtnet
# Expected Output:
# Id Refs Address            Size     Name
#  5    1 0xffffffff82610000  0x11280  if_vtnet.ko
#
# Verify network interface attachment:
# $ ifconfig -a
# Expected Output:
# vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
#         ether 52:54:00:12:34:56
#
# ------------------------------------------------------------------------------
# STEP 4: DEVFS PERMISSION & RULESET REMEDIATION
# ------------------------------------------------------------------------------
# Inspect devfs rules in /etc/devfs.rules. The ruleset 'system_rules=10' set
# mode 0000 on block devices, rendering them inaccessible.
#
# Fix /etc/devfs.rules with standard production permissions:
# $ cat << 'EOF' > /etc/devfs.rules
# [system_rules=10]
# add path 'ada*' mode 0660 group operator
# add path 'da*' mode 0660 group operator
# add path 'vtbd*' mode 0660 group operator
# add path 'nvd*' mode 0660 group operator
# EOF
#
# Re-apply devfs rulesets dynamically:
# $ sysctl devfs.rulesets.system_ruleset=10
# $ devfs rule applyset
#
# Verify file permissions on disk device nodes under /dev:
# $ ls -l /dev/vtbd* /dev/ada* 2>/dev/null || true
# Expected Output:
# crw-rw----  1 root  operator  0x53 Oct 24 10:00 /dev/vtbd0
#
# ------------------------------------------------------------------------------
# STEP 5: VERIFICATION & HARDWARE PERFORMANCE TUNING
# ------------------------------------------------------------------------------
# Verify CPU throttling and ACPI power management status:
# $ sysctl dev.cpu.0.freq_levels
# $ sysctl hw.model hw.ncpu hw.physmem
#
# Verify CAM/ATA disk bus controller status:
# $ camcontrol devlist
# Expected Output:
# <QEMU HARDDISK 2.5+>               at scbus0 target 0 lun 0 (da0,da)
#
# Verify USB controller hierarchy:
# $ usbconfig
# Expected Output:
# ubus0: <UHCI Root Hub> at usbus0, cfg 0 md HOST spd FULL (12Mbps) pwr SAVE
#
# ------------------------------------------------------------------------------
# ARCHITECTURAL TRADE-OFFS & PRODUCTION LESSONS
# ------------------------------------------------------------------------------
# 1. /boot/loader.conf vs /etc/sysctl.conf:
#    - loader.conf tunables are applied BEFORE kernel initialization. Mandatory for
#      memory allocation, bus tuning (MSI-X), and storage controller drivers.
#    - sysctl.conf tunables are applied post-kernel boot during rc initialization.
#      Modifying bus properties in sysctl.conf will fail if the driver requires
#      allocation at early boot stage.
#
# 2. devfs Security vs SRE Visibility:
#    - Restricting /dev device nodes to root:wheel prevents unauthorized raw disk
#      access (reading filesystem data directly bypassing kernel VFS).
#    - Production trade-off: Monitoring tools (Prometheus node_exporter, smartd)
#      must belong to the 'operator' group with 0660 permissions to safely read
#      S.M.A.R.T telemetry without requiring elevated root privileges.
# ==============================================================================