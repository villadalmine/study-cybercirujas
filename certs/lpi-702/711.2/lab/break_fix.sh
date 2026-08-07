#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist (702-100) - Topic 711.2: BSD Software and Package Management
# Production Break & Fix Lab Script
#
# Certification: LPI BSD Specialist (702-100)
# Topic: 711.2 BSD Software and Package Management
# Exam Weight: 6.67
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# Target OS: FreeBSD / BSD operating systems utilizing pkg(8) package manager
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

BACKUP_DIR="/var/tmp/bsd_pkg_lab_backup"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[ERROR] This lab script must be executed with root privileges.${NC}" >&2
        exit 1
    fi
}

backup_environment() {
    echo -e "${YELLOW}[+] Creating pre-fault backup of package management state...${NC}"
    mkdir -p "${BACKUP_DIR}"
    
    if [ -d "/etc/pkg" ]; then
        cp -rp /etc/pkg "${BACKUP_DIR}/etc_pkg" 2>/dev/null || true
    fi
    if [ -d "/usr/local/etc/pkg" ]; then
        cp -rp /usr/local/etc/pkg "${BACKUP_DIR}/usr_local_etc_pkg" 2>/dev/null || true
    fi
    if [ -f "/var/db/pkg/local.sqlite" ]; then
        cp -p /var/db/pkg/local.sqlite "${BACKUP_DIR}/local.sqlite.bak" 2>/dev/null || true
    fi
}

inject_failures() {
    echo -e "${YELLOW}[+] Injecting controlled production faults into pkg(8) subsystem...${NC}"
    
    # 1. Create custom repository override directory if missing
    mkdir -p /usr/local/etc/pkg/repos

    # 2. Inject a corrupted FreeBSD.conf override pointing to an invalid mirror and missing SSL key
    cat << 'EOF' > /usr/local/etc/pkg/repos/FreeBSD.conf
# Production Lab Fault - Overridden Repository Config
FreeBSD: {
  url: "pkg+http://unreachable-mirror.internal.local/${ABI}/quarterly",
  mirror_type: "srv",
  signature_type: "pubkey",
  pubkey: "/etc/ssl/certs/nonexistent_pkg_key.pub",
  enabled: yes
}
EOF

    # 3. Inject a syntax-corrupted overlay config file causing YAML/UCL parser failures in pkg(8)
    cat << 'EOF' > /usr/local/etc/pkg/repos/00_broken_syntax.conf
FreeBSD_Broken: {
  url: pkg+http://invalid-syntax-repo.local
  enabled: yes
  pubkey: missing_quotes_and_invalid_ucl_structure
EOF

    # 4. Restrict permissions on the local package database file (SQLite access failure)
    if [ -f "/var/db/pkg/local.sqlite" ]; then
        chmod 000 /var/db/pkg/local.sqlite
    fi

    # 5. Create stale transaction lockfile blocking package operations
    touch /var/db/pkg/lockfile
    touch /var/db/pkg/journal
    chmod 400 /var/db/pkg/lockfile

    # 6. Wipe local repository catalog sqlite caches to force catalog re-fetch
    rm -f /var/db/pkg/repo-*.sqlite 2>/dev/null || true
}

display_symptoms() {
    cat << EOF

${RED}==============================================================================${NC}
${RED}       LAB SETUP COMPLETE - TROUBLESHOOTING SCENARIO ACTIVE                  ${NC}
${RED}==============================================================================${NC}

${YELLOW}Certification Target:${NC} LPI-702 (BSD Specialist 702-100, Version 1.0)
${YELLOW}Topic 711.2:${NC} BSD Software and Package Management (Weight: 6.67)
${YELLOW}Official Syllabus Reference:${NC} https://www.lpi.org/our-certifications/bsd-specialist-overview/

${GREEN}[SCENARIO OVERVIEW]${NC}
An automated configuration management run has broken the pkg(8) packaging system on this 
BSD host. Software deployment pipelines, security audit runs, and port builds are 
completely stalled due to configuration syntax errors, invalid cryptographic verification 
keys, locked local SQLite databases, and incorrect repository mirror endpoints.

${GREEN}[OBSERVED SYMPTOMS]${NC}
1. Running 'pkg update' or 'pkg search <package>' fails immediately with UCL/YAML parsing 
   errors on configuration files in /usr/local/etc/pkg/repos/.
2. Running 'pkg info' or 'pkg audit' fails with SQLite permission denied errors or 
   database file lockouts.
3. System error logs display errors similar to:
   - "pkg: /usr/local/etc/pkg/repos/00_broken_syntax.conf: UCL parsing error..."
   - "pkg: sqlite3_open(/var/db/pkg/local.sqlite): permission denied"
   - "pkg: Unable to open public key /etc/ssl/certs/nonexistent_pkg_key.pub"

${GREEN}[STUDENT OBJECTIVES]${NC}
1. Identify and resolve all UCL/YAML syntax errors in /usr/local/etc/pkg/repos/.
2. Repair local package database (/var/db/pkg/local.sqlite) permissions and clear stale lockfiles.
3. Restore valid repository configuration settings and cryptographic signature checking 
   (using default fingerprints in /usr/share/keys/pkg or default repository definitions).
4. Verify complete package subsystem recovery by successfully running 'pkg update -f', 
   'pkg audit -F', and 'pkg check -s -a'.

${YELLOW}CRITICAL NOTE:${NC} Do NOT delete /var/db/pkg/local.sqlite! It holds the registration database of all 
currently installed packages on the system.

EOF
}

check_root
backup_environment
inject_failures
display_symptoms

exit 0

# ==============================================================================
#                               STEP-BY-STEP SOLUTION
# ==============================================================================
#
# Step 1: Diagnose and resolve UCL configuration parsing errors
# ------------------------------------------------------------------------------
# Run 'pkg update' to isolate configuration parsing errors:
#   # pkg update
#
# Output pinpoints malformed syntax in /usr/local/etc/pkg/repos/00_broken_syntax.conf.
# Inspect and delete the corrupted config overlay:
#   # cat /usr/local/etc/pkg/repos/00_broken_syntax.conf
#   # rm -f /usr/local/etc/pkg/repos/00_broken_syntax.conf
#
# Step 2: Repair database permissions and remove stale locks
# ------------------------------------------------------------------------------
# Test local package database access:
#   # pkg info
#
# SQLite fails due to permission denied on /var/db/pkg/local.sqlite.
# Inspect ownership and permissions on /var/db/pkg/:
#   # ls -la /var/db/pkg/
#
# Fix permissions on local database (root:wheel, 0644):
#   # chmod 0644 /var/db/pkg/local.sqlite
#   # chown root:wheel /var/db/pkg/local.sqlite
#
# Remove stale database lock files blocking package transactions:
#   # rm -f /var/db/pkg/lockfile /var/db/pkg/journal
#
# Step 3: Repair repository configuration and signature verification
# ------------------------------------------------------------------------------
# Inspect overriding repo configuration file:
#   # cat /usr/local/etc/pkg/repos/FreeBSD.conf
#
# Notice invalid URL endpoint and non-existent public key file location.
#
# Option A (Recommended): Remove broken custom override to inherit system defaults from /etc/pkg/FreeBSD.conf:
#   # rm -f /usr/local/etc/pkg/repos/FreeBSD.conf
#
# Option B (Manual Repair): Edit /usr/local/etc/pkg/repos/FreeBSD.conf to valid configuration:
#   FreeBSD: {
#     url: "pkg+http://pkg.FreeBSD.org/${ABI}/quarterly",
#     mirror_type: "srv",
#     signature_type: "fingerprints",
#     fingerprints: "/usr/share/keys/pkg",
#     enabled: yes
#   }
#
# Step 4: Verify complete recovery of the package subsystem
# ------------------------------------------------------------------------------
# Force update of remote package catalogs:
#   # pkg update -f
#
# Fetch security vulnerability database and run vulnerability check:
#   # pkg audit -F
#
# Check integrity of installed packages:
#   # pkg check -s -a
#
# Step 5: (Optional) Restore original lab backup state
# ------------------------------------------------------------------------------
# If needed to reset to pre-lab state:
#   # cp -rp /var/tmp/bsd_pkg_lab_backup/usr_local_etc_pkg/* /usr/local/etc/pkg/ 2>/dev/null || true
#   # cp -p /var/tmp/bsd_pkg_lab_backup/local.sqlite.bak /var/db/pkg/local.sqlite
# ==============================================================================