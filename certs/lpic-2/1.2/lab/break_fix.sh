#!/bin/bash
# ==============================================================================
# LPIC-2 (Exam 201-450) Topic 201: Linux Kernel - Break & Fix SRE Lab
# Weight: 7
# Reference: https://www.lpi.org/our-certifications/lpic-2-overview/
#
# Description:
# This script injects realistic production kernel module and sysctl breakages
# into a disposable Linux laboratory VM. It tests the engineer's ability to
# diagnose module dependency failures, misconfigured modprobe directives,
# and broken runtime kernel parameter files.
#
# IMPORTANT: Run this ONLY on a disposable test VM as root.
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/tmp/lpic2_kernel_lab"
BACKUP_DIR="${LAB_DIR}/backups"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed as root.${NC}" >&2
        exit 1
    fi
}

create_backups() {
    echo -e "${BLUE}[*] Creating configuration backups in ${BACKUP_DIR}...${NC}"
    mkdir -p "${BACKUP_DIR}"

    KVER=$(uname -r)
    
    if [[ -f "/lib/modules/${KVER}/modules.dep" ]]; then
        cp "/lib/modules/${KVER}/modules.dep" "${BACKUP_DIR}/modules.dep.bak"
    fi
    if [[ -f "/lib/modules/${KVER}/modules.dep.bin" ]]; then
        cp "/lib/modules/${KVER}/modules.dep.bin" "${BACKUP_DIR}/modules.dep.bin.bak"
    fi

    mkdir -p "${BACKUP_DIR}/modprobe.d"
    cp -r /etc/modprobe.d/* "${BACKUP_DIR}/modprobe.d/" 2>/dev/null || true

    mkdir -p "${BACKUP_DIR}/sysctl.d"
    cp -r /etc/sysctl.d/* "${BACKUP_DIR}/sysctl.d/" 2>/dev/null || true
}

break_scenario() {
    echo -e "${YELLOW}[!] Injecting Kernel & Module Breakages...${NC}"
    KVER=$(uname -r)

    # Breakage 1: Corrupt kernel module dependency index file
    # Symptoms: modprobe fails to resolve dependencies for complex kernel modules
    if [[ -f "/lib/modules/${KVER}/modules.dep" ]]; then
        sed -i 's/veth/veth_broken_nonexistent_dep/g' "/lib/modules/${KVER}/modules.dep"
        truncate -s 0 "/lib/modules/${KVER}/modules.dep.bin" 2>/dev/null || true
    fi

    # Breakage 2: Introduce conflicting & malformed modprobe configuration
    # Symptoms: Unable to load dummy / overlay modules due to bad options and alias overrides
    cat << 'EOF' > /etc/modprobe.d/99-sre-production-override.conf
# Production Kernel Override Policy
install dummy /bin/false
options dummy numdummies=invalid_integer_string
blacklist overlay
alias veth_test_alias non_existent_kernel_module_xyz
EOF

    # Breakage 3: Introduce broken sysctl configuration file with invalid keys and syntax errors
    # Symptoms: sysctl --system reports parse errors and fails to apply kernel runtime tuning
    cat << 'EOF' > /etc/sysctl.d/99-kernel-hardening-broken.conf
# SRE Security Hardening Rules
net.ipv4.ip_forward = 1
kernel.panic = 10
fs.file-max == 2097152
kernel.invalid_sre_tunable_key_xyz = 99999
net.core.somaxconn = invalid_value_string
EOF

    # Unload target test modules if currently loaded
    rmmod dummy 2>/dev/null || true
    rmmod veth 2>/dev/null || true
}

display_manifest() {
    echo -e "\n${GREEN}======================================================================${NC}"
    echo -e "${GREEN}        LPIC-2 TOPIC 201: KERNEL BREAK & FIX LAB INSTALLED            ${NC}"
    echo -e "${GREEN}======================================================================${NC}\n"

    echo -e "${YELLOW}INCIDENT REPORT / SYMPTOMS:${NC}"
    echo -e "1. The network engineering team reports that attempting to load virtual network"
    echo -e "   and storage modules using 'modprobe dummy' or 'modprobe veth' fails."
    echo -e "2. The security team reports that automated kernel runtime parameter application"
    echo -e "   via 'sysctl --system' is failing with syntax and key error messages."
    echo -e "3. Kernel module dependency resolution appears unstable for standard modules."

    echo -e "\n${YELLOW}STUDENT OBJECTIVES:${NC}"
    echo -e "A. Diagnose why 'modprobe dummy' and 'modprobe veth' fail to load."
    echo -e "B. Identify and correct the modprobe override file in /etc/modprobe.d/."
    echo -e "C. Regenerate and verify the kernel module dependency graph database."
    echo -e "D. Troubleshoot /etc/sysctl.d/ to fix syntax errors and invalid kernel keys"
    echo -e "   so that 'sysctl --system' executes with zero errors."
    echo -e "E. Verify your fixes using lsmod, modinfo, depmod, sysctl, and dmesg."

    echo -e "\n${BLUE}DIAGNOSTIC CLI COMMANDS TO START WITH:${NC}"
    echo -e "  - modprobe -v dummy"
    echo -e "  - modprobe -v veth"
    echo -e "  - sysctl --system"
    echo -e "  - depmod -n"
    echo -e "  - ls /etc/modprobe.d/"
    echo -e "  - ls /etc/sysctl.d/"

    echo -e "\n${GREEN}======================================================================${NC}"
    echo -e "Note: A detailed, step-by-step solution is embedded inside this script."
    echo -e "Inspect the source comments at the bottom of this file when done."
    echo -e "${GREEN}======================================================================${NC}\n"
}

main() {
    check_root
    create_backups
    break_scenario
    display_manifest
}

main "$@"

# ==============================================================================
#                      STEP-BY-STEP SRE SOLUTION & RCA
# ==============================================================================
#
# RCA (Root Cause Analysis):
# --------------------------
# 1. /etc/modprobe.d/99-sre-production-override.conf injected three issues:
#    - 'install dummy /bin/false': Overrides modprobe execution with a command
#      that returns non-zero exit status 1, preventing module load.
#    - 'options dummy numdummies=invalid_integer_string': Passes an invalid parameter.
#    - 'blacklist overlay': Prevents modprobe from loading the overlay module.
# 2. /lib/modules/$(uname -r)/modules.dep was manually edited and modules.dep.bin
#    was emptied, corrupting the dependency tree for module resolution.
# 3. /etc/sysctl.d/99-kernel-hardening-broken.conf introduced invalid syntax
#    ('==' instead of '='), an invalid kernel key ('kernel.invalid_sre_tunable_key_xyz'),
#    and an invalid data type for 'net.core.somaxconn'.
#
# STEP-BY-STEP RESOLUTION:
# ------------------------
#
# Step 1: Diagnose and Fix Kernel Module Configuration (/etc/modprobe.d)
# ---------------------------------------------------------------------
# Command:
#   modprobe -v dummy
# Output Expected:
#   Executing /bin/false
#   modprobe: ERROR: could not insert 'dummy': Operation not permitted
#
# Inspect modprobe configuration files:
#   grep -rn "dummy" /etc/modprobe.d/
#   grep -rn "blacklist" /etc/modprobe.d/
#
# Remove or correct the malicious file:
#   rm -f /etc/modprobe.d/99-sre-production-override.conf
#
# Step 2: Regenerate Kernel Module Dependency Graph (depmod)
# -----------------------------------------------------------
# Diagnose broken dependencies:
#   depmod -v | grep error
#
# Rebuild the dependency map files (modules.dep, modules.dep.bin, modules.alias):
#   depmod -a
#
# Verify module loading works cleanly:
#   modprobe -v dummy
#   lsmod | grep dummy
#   modinfo dummy
#
# Clean up test module loading:
#   rmmod dummy
#
# Step 3: Troubleshoot and Fix Runtime Kernel Parameters (sysctl)
# ----------------------------------------------------------------
# Execute sysctl system reload to locate errors:
#   sysctl --system
#
# Expected Error Lines:
#   sysctl: /etc/sysctl.d/99-kernel-hardening-broken.conf: line 4: syntax error
#   sysctl: cannot stat /proc/sys/kernel/invalid_sre_tunable_key_xyz: No such file or directory
#   sysctl: setting key "net.core.somaxconn": Invalid argument
#
# Edit or remove the broken sysctl file:
#   rm -f /etc/sysctl.d/99-kernel-hardening-broken.conf
#
# Alternatively, fix the syntactically valid parameters in a proper config file:
#   cat << 'EOF' > /etc/sysctl.d/99-sre-production-fixed.conf
#   net.ipv4.ip_forward = 1
#   kernel.panic = 10
#   fs.file-max = 2097152
#   net.core.somaxconn = 4096
#   EOF
#
# Apply and verify sysctl settings:
#   sysctl --system
#   sysctl net.ipv4.ip_forward kernel.panic fs.file-max net.core.somaxconn
#
# Expected Output:
#   net.ipv4.ip_forward = 1
#   kernel.panic = 10
#   fs.file-max = 2097152
#   net.core.somaxconn = 4096
#
# Verification complete! All LPIC-2 Topic 201 components are restored.
# ==============================================================================