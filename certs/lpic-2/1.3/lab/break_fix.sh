#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 (Exam 201-450) - Topic 201.1 / 1.3: System Startup
# Weight: 7 (or 3 in V4.5 Objectives, high priority core system administration)
# Role: Principal Platform Architect & Senior SRE Instructor
# Scenario: Break & Fix - Broken Default Systemd Target & Failing Boot Dependency
# Official References:
#   - https://www.lpi.org/our-certifications/lpic-2-overview/
#   - https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
#   - https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html
# ==============================================================================

set -euo pipefail

# Colors for UI output
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

BACKUP_DIR="/var/tmp/lpic2_startup_backup"

# Ensure execution as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be executed with root privileges.${NC}" >&2
    exit 1
fi

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN} LPIC-2 Topic 201.1: System Startup - Break & Fix Laboratory Environment${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# STEP 1: Backup current system state
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[+] Creating backup of startup configurations in ${BACKUP_DIR}...${NC}"
mkdir -p "${BACKUP_DIR}"

if [[ -L /etc/systemd/system/default.target || -f /etc/systemd/system/default.target ]]; then
    cp -P /etc/systemd/system/default.target "${BACKUP_DIR}/default.target.orig" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# STEP 2: Inject Breakage Scenario
# Description:
# A platform engineer attempted to enforce a strict pre-boot storage validation
# service in production by creating a custom target 'custom-production.target'
# and setting it as the default boot target.
# However:
# 1. The target depends strictly on 'storage-audit.service' (Type=oneshot).
# 2. 'storage-audit.service' executes a non-existent binary '/usr/local/bin/verify-nvme-arrays'.
# 3. 'storage-audit.service' has 'OnFailure=emergency.target' and 'JobTimeoutSec=5s'.
# 4. The default target symlink was directed to this broken custom target.
#
# Symptoms observed upon reboot or running `systemctl isolate default.target`:
# - System fails to reach 'multi-user.target' or 'graphical.target'.
# - Boot process aborts or drops into emergency shell / rescue mode.
# - Systemd unit dependency transaction fails with 'Job storage-audit.service/start failed with result failed'.
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[+] Injecting controlled system startup breakage...${NC}"

# Create broken storage audit oneshot service
cat << 'EOF' > /etc/systemd/system/storage-audit.service
[Unit]
Description=Production NVMe Storage Verification Service
Documentation=https://www.lpi.org/our-certifications/lpic-2-overview/
DefaultDependencies=no
Conflicts=shutdown.target
Before=sysinit.target
OnFailure=emergency.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/verify-nvme-arrays --strict
TimeoutSec=5s
RemainAfterExit=no

[Install]
WantedBy=custom-production.target
EOF

# Create custom target overriding standard boot workflow without multi-user dependencies
cat << 'EOF' > /etc/systemd/system/custom-production.target
[Unit]
Description=Custom Enterprise Production Boot Target
Documentation=https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
Requires=storage-audit.service
After=storage-audit.service
AllowIsolate=yes
EOF

# Override default target
ln -sf /etc/systemd/system/custom-production.target /etc/systemd/system/default.target

# Reload systemd daemon to pick up broken targets
systemctl daemon-reload

echo -e "${GREEN}[✔] Breakage successfully injected!${NC}"
echo ""

# ------------------------------------------------------------------------------
# STEP 3: Display Student Instructions & Problem Statement
# ------------------------------------------------------------------------------
cat << EOF
--------------------------------------------------------------------------------
LABORATORY SCENARIO: PRODUCTION BOOT FAILURE (LPIC-2 Topic 201.1)
--------------------------------------------------------------------------------
PROBLEM STATEMENT:
After a infrastructure policy push, node reboot tests fail. The machine cannot
reach standard multi-user operational state and instead drops into emergency mode
or fails target isolation.

OBSERVED SYMPTOMS:
1. Inspecting the default boot target shows a custom target configuration.
2. Executing 'systemctl isolate default.target' results in a dependency failure.
3. System logs indicate critical oneshot unit execution failure.

STUDENT OBJECTIVE:
1. Diagnose the root cause using official systemd diagnosis tooling:
   - Determine current default target configuration.
   - Inspect unit file dependencies and ordering.
   - Identify failed unit jobs via journal and status checks.
2. Recover the system:
   - Restore default system startup to standard production state ('multi-user.target').
   - Clean up or disable corrupt custom target and service dependencies.
   - Verify syntactical correctness and clean isolation transition.

COMMAND TO TRIGGER BREAKAGE IN CURRENT SESSION:
   # systemctl isolate default.target

WARNING: Running the above command will attempt to switch targets immediately.
Do not reboot unless you have access to a console (GRUB interactive recovery).
--------------------------------------------------------------------------------
EOF

exit 0

# ==============================================================================
# COMPREHENSIVE TROUBLESHOOTING & SOLUTION GUIDE (STUDENT REFERENCE)
# ==============================================================================
#
# STEP-BY-STEP DIAGNOSIS MECHANICS:
#
# 1. Inspect Default Target Configuration:
#    $ systemctl get-default
#    Expected output:
#    custom-production.target
#
# 2. Inspect target symlink and properties:
#    $ ls -l /etc/systemd/system/default.target
#    Expected output:
#    lrwxrwxrwx 1 root root ... /etc/systemd/system/default.target -> /etc/systemd/system/custom-production.target
#
# 3. Test Isolation and Inspect Failure Logs:
#    $ systemctl isolate default.target
#    Output:
#    Failed to isolate default.target: Job for storage-audit.service failed...
#
#    $ journalctl -xb -u storage-audit.service
#    Expected log evidence:
#    systemd[1]: Starting storage-audit.service - Production NVMe Storage Verification Service...
#    systemd[11234]: storage-audit.service: Failed to execute /usr/local/bin/verify-nvme-arrays: No such file or directory
#    systemd[1]: storage-audit.service: Main process exited, code=exited, status=203/EXEC
#    systemd[1]: storage-audit.service: Failed with result 'exit-code'.
#
# 4. Verify systemd unit configurations:
#    $ systemd-analyze verify /etc/systemd/system/custom-production.target
#    Expected output:
#    /etc/systemd/system/storage-audit.service: Service ... /usr/local/bin/verify-nvme-arrays does not exist.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP REMEDIATION PROCEDURE:
#
# Step 1: Temporarily isolate to standard multi-user target to establish operational control
#    # systemctl isolate multi-user.target
#
# Step 2: Re-set default target back to multi-user.target using systemctl
#    # systemctl set-default multi-user.target
#    Expected output:
#    Removed /etc/systemd/system/default.target.
#    Created symlink /etc/systemd/system/default.target -> /lib/systemd/system/multi-user.target.
#
# Step 3: Disable and remove corrupt target and service unit files
#    # systemctl stop storage-audit.service 2>/dev/null || true
#    # rm -f /etc/systemd/system/storage-audit.service
#    # rm -f /etc/systemd/system/custom-production.target
#    # systemctl daemon-reload
#    # systemctl reset-failed
#
# Step 4: GRUB / Kernel Command Line Recovery Knowledge (For LPIC-2 Exam 201.1):
#    If the machine is trapped in a boot loop at GRUB menu:
#    a. Press 'e' on the GRUB menu entry.
#    b. Append 'systemd.unit=multi-user.target' or 'systemd.unit=rescue.target' or 'init=/bin/bash' to the 'linux' line.
#    c. Press Ctrl+X or F10 to boot into single-user / rescue mode.
#    d. Remount root filesystem as read-write if necessary: # mount -o remount,rw /
#    e. Execute: # systemctl set-default multi-user.target
#
# Step 5: Final Verification:
#    # systemctl get-default
#    # systemctl isolate default.target
#    # systemctl status multi-user.target
#
# ==============================================================================