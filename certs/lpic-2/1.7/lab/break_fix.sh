#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 Certification (Exams 201-450 & 202-450, Version 4.5)
# Topic 206: System Maintenance (Weight: 8)
# Break & Fix Hands-on Lab Environment
#
# Reference: https://www.lpi.org/our-certifications/lpic-2-overview/
# Target OS: Linux (Ubuntu 20.04+, Debian 11+, RHEL/Rocky Linux 8+)
# ==============================================================================
# WARNING: Run this script ONLY inside a disposable laboratory virtual machine!
# ==============================================================================

set -euo pipefail

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Root Privilege Guard
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This break & fix script must be executed with root privileges.${NC}" 1>&2
    echo -e "Please re-run using: ${BOLD}sudo $0${NC}" 1>&2
    exit 1
fi

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD} LPIC-2 Topic 206: System Maintenance - Break & Fix Lab Setup ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "${YELLOW}[!] Initializing break-state injection on host...${NC}\n"

# ------------------------------------------------------------------------------
# STEP 1: Setup Mock Source Package & Inject Dynamic Linker Breakage (Topic 206.1)
# ------------------------------------------------------------------------------
SRC_DIR="/usr/local/src/lpic2-monitor-1.0"
LIB_DIR="/opt/lpic2/lib"
INC_DIR="/opt/lpic2/include"

mkdir -p "${SRC_DIR}" "${LIB_DIR}" "${INC_DIR}"

# Create shared library header
cat << 'EOF' > "${INC_DIR}/lpic2_sys.h"
#ifndef LPIC2_SYS_H
#define LPIC2_SYS_H
void print_system_health(void);
#endif
EOF

# Create shared library C file
cat << 'EOF' > "${SRC_DIR}/lpic2_sys.c"
#include <stdio.h>
#include "lpic2_sys.h"

void print_system_health(void) {
    printf("[HEALTH CHECK] Maintenance Subsystem: Dynamic linkage functional.\n");
}
EOF

# Compile the shared library into /opt/lpic2/lib/liblpic2_sys.so
gcc -shared -fPIC -o "${LIB_DIR}/liblpic2_sys.so" "${SRC_DIR}/lpic2_sys.c" -I"${INC_DIR}"

# Create main application source
cat << 'EOF' > "${SRC_DIR}/main.c"
#include <stdio.h>
#include <lpic2_sys.h>

int main(void) {
    printf("LPIC-2 Maintenance Utility v1.0\n");
    print_system_health();
    return 0;
}
EOF

# Create Makefile with custom include/library flags
cat << 'EOF' > "${SRC_DIR}/Makefile"
CC = gcc
CFLAGS = -I/opt/lpic2/include -O2 -Wall
LDFLAGS = -L/opt/lpic2/lib -llpic2_sys
TARGET = lpic2-monitor

all: $(TARGET)

$(TARGET): main.c
	$(CC) $(CFLAGS) main.c $(LDFLAGS) -o $(TARGET)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/$(TARGET)

clean:
	rm -f $(TARGET)
EOF

# Compile and install application initially
make -C "${SRC_DIR}" > /dev/null 2>&1
make -C "${SRC_DIR}" install > /dev/null 2>&1

# BREAKAGE 1A: Misconfigure Dynamic Linker Cache (/etc/ld.so.conf.d/)
echo "/opt/lpic2/lib_invalid_path" > /etc/ld.so.conf.d/lpic2_sys.conf
ldconfig

# BREAKAGE 1B: Introduce Header / Library path failure for compilation
chmod 000 "${INC_DIR}/lpic2_sys.h"

# ------------------------------------------------------------------------------
# STEP 2: Inject Automated Backup Operations Failure (Topic 206.2)
# ------------------------------------------------------------------------------
BACKUP_DIR="/var/backups/lpic2_archives"
mkdir -p "${BACKUP_DIR}"

# Create exclusion list file
cat << 'EOF' > /etc/lpic2-backup.exclude
# LPIC-2 Maintenance Backup Excludes
/proc
/sys
/dev
/run
/tmp
EOF

# Create automated backup script
cat << 'EOF' > /usr/local/bin/lpic2-backup.sh
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DEST="/var/backups/lpic2_archives/system_snapshot.tar.gz"
EXCLUDE_FILE="/etc/lpic2-backup.exclude"

echo "[INFO] Starting scheduled backup operation..."
tar -czvf "${BACKUP_DEST}" --exclude-from="${EXCLUDE_FILE}" /etc /var/log > "${BACKUP_DEST}" 2>&1
echo "[INFO] Backup completed successfully."
EOF

chmod +x /usr/local/bin/lpic2-backup.sh

# BREAKAGE 2A: Truncation bug introduced by standard output redirection over target archive
# BREAKAGE 2B: Apply Immutable file attribute to destination directory preventing updates
chattr +i "${BACKUP_DIR}" || true

# ------------------------------------------------------------------------------
# STEP 3: Inject System Notification & User Lockout Failure (Topic 206.3)
# ------------------------------------------------------------------------------
# BREAKAGE 3A: Create /etc/nologin as a DIRECTORY instead of a standard file
# This breaks SSH/PAM login rejection mechanisms and standard shutdown tools with 'Is a directory'
rm -f /etc/nologin
mkdir -p /etc/nologin

# Create broken maintenance notification script
cat << 'EOF' > /usr/local/bin/lpic2-notify.sh
#!/usr/bin/env bash
# LPIC-2 Maintenance Notification Script
MESSAGE="SYSTEM MAINTENANCE IN PROGRESS. ALL NON-ROOT SESSIONS WILL BE TERMINATED."

# Broadcast wall message
wall "${MESSAGE}"

# Set user login lockout
echo "${MESSAGE}" > /etc/nologin
EOF
chmod +x /usr/local/bin/lpic2-notify.sh

# ------------------------------------------------------------------------------
# Display Lab Briefing & Diagnostic Objectives
# ------------------------------------------------------------------------------
echo -e "${GREEN}[+] Controlled environment breakages injected successfully.${NC}\n"
echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}${WHITE}               LAB TROUBLESHOOTING BRIEFING & SYMPTOMS                ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}Certification Exam:${NC} LPIC-2 (201-450)"
echo -e "${BOLD}Topic:${NC} 206 - System Maintenance (Weight: 8)"
echo -e "${BOLD}Official Overview:${NC} https.www.lpi.org/our-certifications/lpic-2-overview/\n"

echo -e "${YELLOW}${BOLD}[SYMPTOM 1 - Topic 206.1: Make & Install Software from Source]${NC}"
echo -e "  1. Attempting to execute '/usr/local/bin/lpic2-monitor' fails with:"
echo -e "     ${RED}error while loading shared libraries: liblpic2_sys.so: cannot open shared object file${NC}"
echo -e "  2. Navigating to '/usr/local/src/lpic2-monitor-1.0' and running 'make clean && make' fails with:"
echo -e "     ${RED}fatal error: lpic2_sys.h: Permission denied / No such file or directory${NC}\n"

echo -e "${YELLOW}${BOLD}[SYMPTOM 2 - Topic 206.2: Backup Operations]${NC}"
echo -e "  1. Running '/usr/local/bin/lpic2-backup.sh' fails with write permission errors or creates a corrupted 0-byte archive."
echo -e "  2. Investigating file attributes and shell redirection mechanics is required.\n"

echo -e "${YELLOW}${BOLD}[SYMPTOM 3 - Topic 206.3: Notify Users on System-Related Issues]${NC}"
echo -e "  1. Running '/usr/local/bin/lpic2-notify.sh' fails with:"
echo -e "     ${RED}/usr/local/bin/lpic2-notify.sh: line 9: /etc/nologin: Is a directory${NC}"
echo -e "  2. PAM-based user lockouts during scheduled maintenance windows fail to enforce correctly.\n"

echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}${WHITE}                        STUDENT GOALS TO FIX                          ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "  [ ] Objective 1: Fix include file permissions and ld.so cache configuration so 'lpic2-monitor' compiles and links dynamically."
echo -e "  [ ] Objective 2: Correct the backup script '/usr/local/bin/lpic2-backup.sh' redirection bug and directory attributes so backups write valid .tar.gz archives."
echo -e "  [ ] Objective 3: Resolve '/etc/nologin' path type mismatch so maintenance messages broadcast cleanly and block non-root logins."
echo -e "  [ ] Objective 4: Execute verification tests to ensure 100% operational readiness."
echo -e "${CYAN}======================================================================${NC}\n"
echo -e "${BOLD}Begin troubleshooting! Detailed step-by-step solution is embedded (commented) at the end of this script file.${NC}\n"

exit 0


# ==============================================================================
#                               STEP-BY-STEP SOLUTION
# ==============================================================================
# (Keep this section commented out so students can read it only when stuck)
#
# ------------------------------------------------------------------------------
# DEEP TECHNICAL DIAGNOSIS & RECOVERY PROCEDURE
# ------------------------------------------------------------------------------
#
# --- RESOLVING PROBLEM 1: Compilation & Dynamic Linker (Topic 206.1) ---
#
# Step 1.1: Diagnose header permission issue during compilation.
# Run:
#   cd /usr/local/src/lpic2-monitor-1.0
#   make clean && make
# Output error: main.c:2:10: fatal error: lpic2_sys.h: Permission denied
#
# Inspect file permissions:
#   ls -la /opt/lpic2/include/lpic2_sys.h
# Fix permissions:
#   chmod 644 /opt/lpic2/include/lpic2_sys.h
#
# Step 1.2: Recompile and install software.
# Run:
#   make && make install
#
# Step 1.3: Diagnose runtime dynamic library resolution failure.
# Test binary execution:
#   /usr/local/bin/lpic2-monitor
# Output error: error while loading shared libraries: liblpic2_sys.so: cannot open shared object file
#
# Trace library loading with ldd:
#   ldd /usr/local/bin/lpic2-monitor
# Output shows: liblpic2_sys.so => not found
#
# Check current ldconfig cache database:
#   ldconfig -p | grep liblpic2
# (No matches found)
#
# Inspect dynamic linker configuration directories:
#   cat /etc/ld.so.conf.d/lpic2_sys.conf
# Notice invalid path: /opt/lpic2/lib_invalid_path
#
# Fix the configuration file:
#   echo "/opt/lpic2/lib" > /etc/ld.so.conf.d/lpic2_sys.conf
#
# Update dynamic linker bindings cache:
#   ldconfig
#
# Verify resolution:
#   ldd /usr/local/bin/lpic2-monitor
#   /usr/local/bin/lpic2-monitor
# Output expected:
#   LPIC-2 Maintenance Utility v1.0
#   [HEALTH CHECK] Maintenance Subsystem: Dynamic linkage functional.
#
#
# --- RESOLVING PROBLEM 2: Backup Script & File Attributes (Topic 206.2) ---
#
# Step 2.1: Execute backup script and inspect errors.
# Run:
#   /usr/local/bin/lpic2-backup.sh
# Output error: Cannot open: Permission denied / Cannot write archive
#
# Step 2.2: Check extended attributes on destination directory.
# Run:
#   lsattr -d /var/backups/lpic2_archives
# Output shows: ----i---------e---- /var/backups/lpic2_archives
# Notice immutable flag (+i) set on directory.
#
# Remove immutable attribute:
#   chattr -i /var/backups/lpic2_archives
#
# Step 2.3: Analyze logic bug in /usr/local/bin/lpic2-backup.sh.
# Inspect script content:
#   cat /usr/local/bin/lpic2-backup.sh
# Redirection bug found:
#   tar -czvf "${BACKUP_DEST}" --exclude-from="${EXCLUDE_FILE}" /etc /var/log > "${BACKUP_DEST}" 2>&1
# Redirection '>' truncates ${BACKUP_DEST} simultaneously while tar writes to it via -f argument.
#
# Fix backup script logic using standard tar execution:
#   cat << 'EOF' > /usr/local/bin/lpic2-backup.sh
# #!/usr/bin/env bash
# set -euo pipefail
# BACKUP_DEST="/var/backups/lpic2_archives/system_snapshot.tar.gz"
# EXCLUDE_FILE="/etc/lpic2-backup.exclude"
# LOG_FILE="/var/log/lpic2-backup.log"
#
# echo "[INFO] Starting scheduled backup operation..."
# tar -czvf "${BACKUP_DEST}" --exclude-from="${EXCLUDE_FILE}" /etc /var/log > "${LOG_FILE}" 2>&1
# echo "[INFO] Backup completed successfully."
# EOF
#   chmod +x /usr/local/bin/lpic2-backup.sh
#
# Step 2.4: Test backup and verify archive integrity.
# Run:
#   /usr/local/bin/lpic2-backup.sh
#   tar -tzvf /var/backups/lpic2_archives/system_snapshot.tar.gz | head -n 10
#
#
# --- RESOLVING PROBLEM 3: System Notifications & /etc/nologin (Topic 206.3) ---
#
# Step 3.1: Execute notification script.
# Run:
#   /usr/local/bin/lpic2-notify.sh
# Output error: /usr/local/bin/lpic2-notify.sh: line 9: /etc/nologin: Is a directory
#
# Step 3.2: Check file type of /etc/nologin.
# Run:
#   file /etc/nologin
# Output: /etc/nologin: directory
#
# Step 3.3: Remove invalid directory and re-create notification flow.
# Run:
#   rm -rf /etc/nologin
#
# Test notification script:
#   /usr/local/bin/lpic2-notify.sh
#
# Verify file creation and content:
#   cat /etc/nologin
# Output expected:
#   SYSTEM MAINTENANCE IN PROGRESS. ALL NON-ROOT SESSIONS WILL BE TERMINATED.
#
# Clean up lockout after maintenance window:
#   rm -f /etc/nologin
#
# ------------------------------------------------------------------------------
# VERIFICATION COMPLETE
# All Topic 206 System Maintenance tasks operational and validated.
# Reference Documentation: https://www.lpi.org/our-certifications/lpic-2-overview/
# ==============================================================================