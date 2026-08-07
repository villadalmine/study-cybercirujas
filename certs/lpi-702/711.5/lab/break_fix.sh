#!/usr/bin/env bash
# ==============================================================================
# LPI 702-100 (v1.0) - Topic 711.5: BSD Kernel Parameters & System Security Level
# SRE & Platform Architecture Lab: "Break & Fix" Production Scenario
#
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
# THEORETICAL ARCHITECTURE & INTERNAL MECHANICS
# ------------------------------------------------------------------------------
# BSD kernel parameters are organized in a Management Information Base (MIB)
# tree hierarchy and configured at runtime via sysctl(8) or persistently via
# /etc/sysctl.conf and /boot/loader.conf.
#
# Core Security & Process Isolation MIB Nodes:
#   - kern.securelevel                    : System security level (-1, 0, 1, 2, 3)
#   - security.bsd.see_other_uids        : Process visibility across UIDs (0=disabled, 1=enabled)
#   - security.bsd.see_other_gids        : Process visibility across GIDs (0=disabled, 1=enabled)
#   - security.bsd.unprivileged_proc_debug: Restricts ptrace/debugging for non-root users
#   - security.bsd.hardened_sysctl       : Aggregated hardening flags state
#
# System Security Level (kern.securelevel) Hierarchy & Restrictions:
#   - Level -1 (Permanently Insecure): Standard default state. Securelevel enforcement disabled.
#   - Level 0  (Insecure Mode)       : Boot initialization / single-user mode state.
#   - Level 1  (Secure Mode)         : 
#        * System immutable flags ('schg') cannot be removed from files.
#        * Raw disk write access denied for mounted filesystems.
#        * Kernel module loading/unloading (kldload/kldunload) disabled.
#        * /dev/mem and /dev/kmem opened as read-only.
#   - Level 2  (Highly Secure Mode)  : 
#        * All level 1 restrictions apply.
#        * System time cannot be adjusted backward by >1 second.
#        * Raw disk write access denied for unmounted filesystems.
#   - Level 3  (Network Secure Mode) : 
#        * All level 2 restrictions apply.
#        * IP packet filter (pf / ipfw) rulesets immutably locked.
#
# CRITICAL ARCHITECTURAL CONSTRAINT:
#   `kern.securelevel` can ONLY be INCREASED during runtime via `sysctl kern.securelevel=N`.
#   Lowering `kern.securelevel` at runtime is rejected by the kernel with EPERM.
#   Decreasing securelevel requires changing configuration files (/etc/rc.conf or
#   /boot/loader.conf) and rebooting into single-user mode.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo -e "${RED}ERROR: This lab script must be run as root.${NC}" >&2
        exit 1
    fi
}

inject_break() {
    check_root
    echo -e "${YELLOW}[+] Injecting production breakage for LPI Topic 711.5...${NC}"
    
    # 1. Backup configuration files
    if [[ -f /etc/sysctl.conf ]] && [[ ! -f /etc/sysctl.conf.bak_lab ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak_lab
    fi
    if [[ -f /etc/rc.conf ]] && [[ ! -f /etc/rc.conf.bak_lab ]]; then
        cp /etc/rc.conf /etc/rc.conf.bak_lab
    fi

    # 2. Inject restrictive process visibility sysctl
    # Disabling see_other_uids breaks non-root SRE monitoring agents (Datadog, Prometheus node_exporter)
    echo "security.bsd.see_other_uids=0" >> /etc/sysctl.conf
    
    if command -v sysctl >/dev/null 2>&1; then
        sysctl security.bsd.see_other_uids=0 2>/dev/null || true
    fi

    # 3. Lock sysctl configuration with System Immutable Flag (schg)
    if command -v chflags >/dev/null 2>&1; then
        chflags schg /etc/sysctl.conf || true
    fi

    # 4. Enable persistent securelevel in /etc/rc.conf
    if [[ -f /etc/rc.conf ]]; then
        echo 'kern_securelevel_enable="YES"' >> /etc/rc.conf
        echo 'kern_securelevel="1"' >> /etc/rc.conf
    fi

    # 5. Create unprivileged monitoring user to demonstrate process hiding issue
    if ! id -u sysmon >/dev/null 2>&1; then
        if command -v pw >/dev/null 2>&1; then
            pw useradd sysmon -m -s /bin/sh -c "SRE Monitoring Daemon" || true
        else
            useradd -m -s /bin/sh sysmon 2>/dev/null || true
        fi
    fi

    echo -e "${RED}[!] BREAKAGE INJECTED SUCCESSFULLY.${NC}\n"
    print_lab_instructions
}

print_lab_instructions() {
    cat << "EOF"
===============================================================================
               LPI 702-100 LAB SCENARIO: TROUBLESHOOTING TOPIC 711.5
===============================================================================

[SCENARIO SYMPTOMS REPORTED BY SRE INCIDENT RESPONSE]:
-------------------------------------------------------------------------------
1. Monitoring Failure:
   The unprivileged SRE monitoring agent 'sysmon' cannot observe processes 
   belonging to other services running under distinct UIDs. Command execution:
     $ su - sysmon -c "ps aux"
   Only displays 'sysmon' processes, blinding metrics collection for web/database daemons.

2. Remediation Failure (Permission Denied):
   The junior SRE attempted to edit /etc/sysctl.conf to restore process visibility, 
   but received an error despite being root:
     # echo "security.bsd.see_other_uids=1" >> /etc/sysctl.conf
     /etc/sysctl.conf: Operation not permitted

3. Kernel Securelevel Enforcement Lockout:
   Attempts to lower securelevel or clear flags fail at runtime:
     # sysctl kern.securelevel=0
     sysctl: kern.securelevel: Operation not permitted
     # chflags noschg /etc/sysctl.conf
     chflags: /etc/sysctl.conf: Operation not permitted

-------------------------------------------------------------------------------
[EXPECTED OPERATIONAL MANIFESTS AND REAL CLI DIAGNOSTICS]
-------------------------------------------------------------------------------

Sample 1: Inspecting current sysctl process security parameters
  $ sysctl security.bsd
  EXPECTED OUTPUT:
  security.bsd.see_other_uids: 0
  security.bsd.see_other_gids: 0
  security.bsd.unprivileged_proc_debug: 0

Sample 2: Inspecting file flags preventing file modifications
  $ ls -lo /etc/sysctl.conf
  EXPECTED OUTPUT:
  -rw-r--r--  1 root  wheel  schg 152 Aug  6 20:00 /etc/sysctl.conf

Sample 3: Inspecting kernel security level state
  $ sysctl kern.securelevel
  EXPECTED OUTPUT:
  kern.securelevel: 1

-------------------------------------------------------------------------------
[STUDENT OBJECTIVES]:
1. Diagnose why /etc/sysctl.conf cannot be edited even by root (identify file flags).
2. Understand the mechanics of 'kern.securelevel=1' preventing flag removal at runtime.
3. Modify /etc/rc.conf and /etc/sysctl.conf appropriately to restore process visibility.
4. Execute the proper remediation workflow (rebooting to insecure level, clearing schg, 
   setting sysctl parameters, and verifying monitoring metrics).

===============================================================================
EOF
}

show_status() {
    echo -e "${BLUE}[*] Current System Diagnostic State:${NC}"
    if command -v sysctl >/dev/null 2>&1; then
        echo -n "  - kern.securelevel: "
        sysctl -n kern.securelevel 2>/dev/null || echo "N/A"
        echo -n "  - security.bsd.see_other_uids: "
        sysctl -n security.bsd.see_other_uids 2>/dev/null || echo "N/A"
    fi
    if [[ -f /etc/sysctl.conf ]]; then
        echo -n "  - /etc/sysctl.conf flags: "
        if command -v ls >/dev/null 2>&1; then
            ls -lo /etc/sysctl.conf 2>/dev/null | awk '{print $5}' || echo "N/A"
        fi
    fi
}

case "${1:-break}" in
    --break|break)
        inject_break
        ;;
    --status|status)
        show_status
        ;;
    --help|help)
        echo "Usage: $0 [--break | --status | --help]"
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
esac

# ==============================================================================
# STEP-BY-STEP SOLUTION & REMEDIATION GUIDE (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# STEP 1: Diagnose File Flags blocking edits to /etc/sysctl.conf
# ------------------------------------------------------------------------------
# Run ls(1) with -l and -o flags to view BSD file flags:
#   # ls -lo /etc/sysctl.conf
#   -rw-r--r--  1 root  wheel  schg 152 Aug  6 20:00 /etc/sysctl.conf
#
# Diagnosis: 'schg' indicates System Immutable flag. Files with 'schg' cannot be
# modified, renamed, or deleted by any user, including root.
#
# STEP 2: Handle Securelevel Constraints
# ------------------------------------------------------------------------------
# Check current securelevel:
#   # sysctl kern.securelevel
#   kern.securelevel: 1
#
# Attempting to run `chflags noschg /etc/sysctl.conf` while kern.securelevel >= 1 
# will fail with "Operation not permitted" because securelevel 1 explicitly protects
# system immutable flags.
#
# Lowering securelevel at runtime (`sysctl kern.securelevel=0`) is also blocked by kernel design.
#
# To permanently allow configuration adjustments:
# 1. Update /etc/rc.conf to disable securelevel enforcement upon next boot:
#    Set:
#      kern_securelevel_enable="NO"
#      kern_securelevel="-1"
#    Or in /boot/loader.conf:
#      kern.securelevel="-1"
#
# 2. Reboot the operating system into single-user mode (boot -s) or standard reboot:
#    # shutdown -r now
#
# STEP 3: Remove Immutable Flags and Fix Sysctl Parameters
# ------------------------------------------------------------------------------
# Once securelevel is <= 0 (or in single-user mode):
#
# 1. Clear the System Immutable flag:
#    # chflags noschg /etc/sysctl.conf
#
# 2. Modify /etc/sysctl.conf to restore process visibility:
#    Edit /etc/sysctl.conf and set:
#      security.bsd.see_other_uids=1
#      security.bsd.see_other_gids=1
#
# 3. Apply sysctl parameter dynamically without rebooting:
#    # sysctl security.bsd.see_other_uids=1
#    EXPECTED OUTPUT:
#    security.bsd.see_other_uids: 0 -> 1
#
# 4. Verify unprivileged monitoring agent process access:
#    # su - sysmon -c "ps aux"
#    EXPECTED OUTPUT:
#    Full process list containing all system UIDs (root, www, postgres, etc.)
# ==============================================================================