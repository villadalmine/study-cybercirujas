#!/usr/bin/env bash
# ==============================================================================
# LPIC-1 (Exams 101-500 & 102-500, Version 5.0)
# Topic 1.1: System Architecture (Weight: 10)
# Subtopics: 101.1 Determine & configure hardware settings, 101.2 Boot the system,
#            101.3 Change runlevels / boot targets and shutdown/reboot.
#
# Author: Principal Platform Architect & Senior SRE Instructor
# Official Reference: https://www.lpi.org/our-certifications/lpic-1-overview/
# Target OS: Debian/Ubuntu/RHEL Linux (Disposable Lab VM)
# ==============================================================================

set -euo pipefail

# Color formatting for SRE lab CLI output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

cat << 'EOF'
==============================================================================
   LPIC-1 Topic 1.1: System Architecture - Production Break & Fix Lab
==============================================================================
 Architecture Deep-Dive & Mechanics:
 The Linux boot chain and hardware subsystem initialization rely on strict
 execution handoffs:
   1. Firmware (BIOS/UEFI) -> Bootloader (GRUB2)
   2. Kernel execution + initramfs decompression
   3. Device discovery via udevd & sysfs (/sys) / dynamic module load (modprobe)
   4. Init process initialization (systemd PID 1)
   5. Target state convergence (default.target -> multi-user.target / graphical.target)

 Kernel modules dynamically export symbols into space managed by kmod. Modprobe
 evaluates dependency trees (/lib/modules/$(uname -r)/modules.dep) and parses
 configuration rules under /etc/modprobe.d/*. Bad module directives or broken
 IPC/kernel parameter configurations in sysctl (/proc/sys) degrade subsystem load.
 Concurrently, systemd relies on soft symlinks in /etc/systemd/system/default.target
 to determine state reaching final operational targets.
==============================================================================
EOF

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] This script must be executed as root (sudo bash).${NC}" >&2
   exit 1
fi

echo -e "\n${YELLOW}[!] Injecting controlled architectural failure state...${NC}"

# Backup state directory creation
BACKUP_DIR="/var/tmp/lpic1_topic11_backup"
mkdir -p "${BACKUP_DIR}"

# 1. Break Kernel Module Auto-Loading Logic (/etc/modprobe.d)
# We inject a softdog/dummy module syntax error and blacklist critical kernel dynamic loading features
if [[ -d /etc/modprobe.d ]]; then
    cat << 'FAIL_MOD' > /etc/modprobe.d/99-lpic1-broken.conf
# LPIC-1 Lab Breakdown Directive
options dummy invalid_param_override=1024
blacklist loop
softdep dummy pre: non_existent_module_xyz
FAIL_MOD
    echo -e "${GREEN}[+] Injected corrupted configuration into /etc/modprobe.d/99-lpic1-broken.conf${NC}"
fi

# 2. Break Kernel Runtime Parameter State via sysctl / procfs interface
cat << 'FAIL_SYSCTL' > /etc/sysctl.d/99-lpic1-architecture-fault.conf
# Malformed Kernel Parameter Definition
kernel.domainname = 
net.ipv4.ip_forward = invalid_boolean_value
fs.file-max = -999999
FAIL_SYSCTL
echo -e "${GREEN}[+] Injected broken sysctl parameters into /etc/sysctl.d/99-lpic1-architecture-fault.conf${NC}"

# 3. Corrupt systemd default target symlink
if [[ -d /etc/systemd/system ]]; then
    if [[ -L /etc/systemd/system/default.target || -f /etc/systemd/system/default.target ]]; then
        cp -P /etc/systemd/system/default.target "${BACKUP_DIR}/default.target.orig" || true
        rm -f /etc/systemd/system/default.target
    fi
    # Point default target to a non-existent unit to simulate boot target convergence failure
    ln -s /dev/null /etc/systemd/system/default.target
    echo -e "${GREEN}[+] Masked/Broken systemd default.target symbolic link${NC}"
fi

# Trigger kernel parameter reload to apply broken state immediately
sysctl --system >/dev/null 2>&1 || true

cat << 'EOF'

==============================================================================
                       LAB TROUBLESHOOTING CHALLENGE
==============================================================================
 [Symptom Overview]:
 The system exhibits three critical production architectural failures:
   1. Dynamic kernel module management via `modprobe` throws execution errors
      or hangs when attempting to load network/virtual device drivers (e.g., `modprobe dummy` or `modprobe loop`).
   2. Kernel runtime tuning via `sysctl --system` fails during boot processing,
      preventing network forwarding and file-descriptor limit allocation.
   3. The system cannot determine its default systemd boot target (`systemctl get-default`),
      risking boot-looping into emergency mode upon next reboot.

 [Student Task & Objectives]:
   - Objective 1: Inspect system hardware state, loaded modules (`lsmod`, `modprobe`), 
     and repair module load errors caused by invalid configurations in `/etc/modprobe.d/`.
   - Objective 2: Inspect runtime kernel settings under `/proc/sys/`, identify the
     malformed sysctl drop-in file in `/etc/sysctl.d/`, and apply a clean runtime kernel configuration.
   - Objective 3: Diagnose systemd default target status using `systemctl`, fix the broken link,
     and set the default target back to `multi-user.target`.
   - Objective 4: Validate boot parameters and hardware log state using `dmesg`, `journalctl -b`,
     and `lsusb`/`lspci`/`lscpu`.

 Execute your diagnostics using standard LPIC-1 commands!
==============================================================================
EOF

# ==============================================================================
#                               STEP-BY-STEP SOLUTION
# ==============================================================================
# To resolve the issue manually, execute the following commands as root:
#
# --- STEP 1: Fix Kernel Module Configuration & Diagnostics ---
# 1.1 Test module load to identify syntax error:
#     # modprobe -v dummy
#     Output expected: modprobe: ERROR: Invalid option parameter...
#
# 1.2 Inspect module configuration drop-in files:
#     # ls -la /etc/modprobe.d/
#     # cat /etc/modprobe.d/99-lpic1-broken.conf
#
# 1.3 Remove or fix the invalid modprobe configuration:
#     # rm -f /etc/modprobe.d/99-lpic1-broken.conf
#
# 1.4 Test module loading and verification:
#     # modprobe dummy
#     # lsmod | grep dummy
#     # modprobe -r dummy
#
# --- STEP 2: Fix Kernel Runtime Parameters (sysctl / procfs) ---
# 2.1 Test sysctl system reload to reveal syntax errors:
#     # sysctl --system
#     Output expected: Line error parsing /etc/sysctl.d/99-lpic1-architecture-fault.conf
#
# 2.2 Inspect and remove the invalid sysctl override:
#     # rm -f /etc/sysctl.d/99-lpic1-architecture-fault.conf
#
# 2.3 Re-apply sysctl rules cleanly and verify /proc/sys values:
#     # sysctl --system
#     # cat /proc/sys/net/ipv4/ip_forward
#
# --- STEP 3: Fix systemd Default Target & Boot Architecture ---
# 3.1 Check current systemd default boot target state:
#     # systemctl get-default
#     Output expected: default.target -> /dev/null (masked) or unresolvable link.
#
# 3.2 Unmask/Remove broken default.target symlink:
#     # rm -f /etc/systemd/system/default.target
#
# 3.3 Set default target explicitly to multi-user.target:
#     # systemctl set-default multi-user.target
#
# 3.4 Confirm systemd default target convergence:
#     # systemctl get-default
#     Output expected: multi-user.target
#
# --- STEP 4: Comprehensive System Architecture Verification ---
# 4.1 Verify hardware & CPU instruction architecture flags:
#     # lscpu
#     # lspci -tv
#     # lsusb
#
# 4.2 Inspect kernel ring buffer logs for boot anomalies:
#     # dmesg --level=err,warn
#     # journalctl -b -p err
#
# ==============================================================================