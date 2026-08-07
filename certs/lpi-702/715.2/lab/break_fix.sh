#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist (Exam 702-100) - Topic 715.2: Perform Basic File Management
# Production Break & Fix Lab Script
# ==============================================================================
#
# TECHNICAL ARCHITECTURE & INTERNAL MECHANICS
# ------------------------------------------------------------------------------
# 1. BSD File Flags Mechanics (chflags, stat, VFS):
#    Unlike standard POSIX file permissions (rwxrwxrwx), BSD Kernel Virtual File
#    System (VFS) extends inode metadata using file flags stored in the st_flags
#    field of struct stat. These flags are categorized into:
#    - User flags: uchg (user immutable), uappnd (user append-only), uunlnk (user nodump/nounlink)
#    - System flags: schg (system immutable), sappnd (system append-only), sunlnk (system nounlink)
#    When 'uchg' or 'schg' is set, VFS operations such as write(), unlink(), and
#    rename() fail at the syscall level with EPERM ("Operation not permitted"), even
#    for UID 0 (root) when kernel securelevel >= 1.
#    Inspection requires 'ls -lo' or 'stat -f "%N %f %u%g %Sp %Sf"'.
#
# 2. Inode Linking Dynamics (ln, stat, POSIX VFS):
#    - Hard links create additional directory entry pointers (dentries) referencing
#      the identical inode number within a single filesystem filesystem block map.
#      Hard links cannot cross filesystem mount points (returning EXDEV: "Invalid
#      cross-device link") and cannot target directory inodes (preventing cyclic graphs).
#    - Symbolic (soft) links store a target path string in the inode data blocks
#      (or inline fast-symlink inode area). They seamlessly cross filesystem mount
#      boundaries and target directory paths.
#
# 3. File Type Identification Mechanics (file, libmagic):
#    The BSD 'file' utility evaluates file types independently of filename extensions
#    by parsing magic byte signatures (matching header bytes against /etc/magic or
#    /usr/share/misc/magic.mgc), evaluating character encoding (ASCII, UTF-8), or
#    querying inode file mode masks (S_IFREG, S_IFDIR, S_IFLNK, S_IFCHR, S_IFBLK).
#
# 4. Data Interchange & Archive Preservation (tar, cpio, pax):
#    Directory tree replication and archival across system boundaries require tools
#    (tar, pax, cpio) that serialize raw data alongside metadata. Standard 'cp -R'
#    without '-p' or '-a' strips extended BSD file flags and ownership, whereas
#    'pax -rw -pe' or 'tar -cvpf' explicitly preserves file modes, flags, and timestamps.
#
# PRODUCTION ARCHITECTURAL TRADE-OFFS
# ------------------------------------------------------------------------------
# - Immutability (chflags schg/uchg) vs. Automated CI/CD Maintenance:
#   Setting 'schg' on critical system binaries hardens against unauthorized file
#   tampering and malware, but breaks automated CI/CD deployment pipelines unless
#   pipeline hooks explicitly execute 'chflags noschg' prior to update cycles.
# - Hard Links vs. Soft Links in BSD Jails / Containerization:
#   Hard links conserve inode pointer overhead but fail when linking assets across
#   ZFS datasets or nullfs mounts. Symbolic links offer cross-dataset flexibility
#   but create broken targets when referenced inside chroot/jail boundaries if target
#   paths are relative to the host root.
# - 'cp -R' vs. 'pax -rw' Directory Replication:
#   'cp -R' is ubiquitous across Unix systems but behaves inconsistently regarding
#   BSD flag propagation. 'pax' provides strict POSIX metadata preservation (-pe)
#   and inline regex file renaming, at the cost of slight CPU overhead during parsing.
#
# OFFICIAL REFERENCES
# ------------------------------------------------------------------------------
# - LPI BSD Specialist Overview: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# - FreeBSD chflags(1) Manual: https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1
# - FreeBSD file(1) Manual: https://man.freebsd.org/cgi/man.cgi?query=file&sektion=1
# - FreeBSD ln(1) Manual: https://man.freebsd.org/cgi/man.cgi?query=ln&sektion=1
# - FreeBSD cp(1) Manual: https://man.freebsd.org/cgi/man.cgi?query=cp&sektion=1
# - FreeBSD tar(1) Manual: https://man.freebsd.org/cgi/man.cgi?query=tar&sektion=1
# ==============================================================================

set -euo pipefail

LAB_BASE="/var/tmp/lpi_715_2_lab"

# Ensure execution as root for BSD flag manipulation
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This lab script must be executed as root (UID 0)." >&2
    exit 1
fi

apply_immutable_flag() {
    local target="$1"
    if command -v chflags &>/dev/null; then
        chflags uchg "$target" 2>/dev/null || chflags schg "$target" 2>/dev/null || true
    elif command -v chattr &>/dev/null; then
        chattr +i "$target" 2>/dev/null || true
    fi
}

echo "[+] Initializing LPI 702-100 Topic 715.2 Break & Fix Laboratory..."

# Cleanup old lab runs
rm -rf "$LAB_BASE" 2>/dev/null || {
    # If standard rm fails due to leftover flags from previous runs
    if command -v chflags &>/dev/null; then
        chflags -R nouchg,noschg "$LAB_BASE" 2>/dev/null || true
    elif command -v chattr &>/dev/null; then
        chattr -R -i "$LAB_BASE" 2>/dev/null || true
    fi
    rm -rf "$LAB_BASE"
}

# Create base directories
mkdir -p "$LAB_BASE/incident1_cleanup/app_cache"
mkdir -p "$LAB_BASE/incident2_linking/sys_config"
mkdir -p "$LAB_BASE/incident2_linking/mount_target"
mkdir -p "$LAB_BASE/incident3_archiving/release_build"

# ------------------------------------------------------------------------------
# INJECTION 1: Immutable BSD File Flag Blocking Directory Removal
# ------------------------------------------------------------------------------
echo "[+] Injecting Incident 1: Directory cleanup blockage..."
cat << 'EOF' > "$LAB_BASE/incident1_cleanup/app_cache/temp_session.log"
[SESSION] Active connection log token: 0x99A0F2
EOF
cat << 'EOF' > "$LAB_BASE/incident1_cleanup/app_cache/locked_kernel_state.sys"
[SYS] Protected state block checksum: e29a75d1
EOF

# Lock file with immutable flag
apply_immutable_flag "$LAB_BASE/incident1_cleanup/app_cache/locked_kernel_state.sys"

# ------------------------------------------------------------------------------
# INJECTION 2: Failed Cross-Device / Target Directory Hard Link Attempt
# ------------------------------------------------------------------------------
echo "[+] Injecting Incident 2: Link generation failure..."
echo "service_port=8443" > "$LAB_BASE/incident2_linking/sys_config/daemon.conf"
mkdir -p "$LAB_BASE/incident2_linking/sys_config/modules"

# Generate broken state descriptor file recording failed link script execution
cat << 'EOF' > "$LAB_BASE/incident2_linking/link_status.log"
[DEPLOY ERROR] Failed to create hard link for configuration directory 'modules' into deployment target.
Reason: Hard link to directory or cross-device link invalid (EXDEV/EPERM).
EOF

# ------------------------------------------------------------------------------
# INJECTION 3: Corrupted Archive Extraction & File Type Misclassification
# ------------------------------------------------------------------------------
echo "[+] Injecting Incident 3: Archive payload extraction and file classification issue..."

# Create a mock ELF binary header and executable payload
cat << 'EOF' > "$LAB_BASE/incident3_archiving/release_build/service_daemon"
#!/bin/sh
# Mock BSD Daemon Executable Payload
echo "Service Daemon Running OK"
EOF
chmod +x "$LAB_BASE/incident3_archiving/release_build/service_daemon"

# Create a configuration file
echo "ENV=PRODUCTION" > "$LAB_BASE/incident3_archiving/release_build/env.config"

# Pack archive stripped of executable bit
(
    cd "$LAB_BASE/incident3_archiving/release_build"
    chmod -x service_daemon
    tar -czf "$LAB_BASE/incident3_archiving/app_release.tar.gz" .
)
# Restore correct perms in source directory after packaging corrupt archive
chmod +x "$LAB_BASE/incident3_archiving/release_build/service_daemon"

# Clean destination extraction area
mkdir -p "$LAB_BASE/incident3_archiving/extracted"
tar -xzf "$LAB_BASE/incident3_archiving/app_release.tar.gz" -C "$LAB_BASE/incident3_archiving/extracted"

echo "[+] Lab setup completed successfully."
echo "=============================================================================="
echo "                  STUDENT BRIEFING - INCIDENT SCENARIOS                       "
echo "=============================================================================="
echo "System Environment: Disposable BSD File Management Lab ($LAB_BASE)"
echo "Topic: 715.2 Perform basic file management (LPI 702-100)"
echo ""
echo "INCIDENT 1: AUTOMATED CLEANUP SCRIPT FAILURE"
echo "  Symptom: Automated maintenance script trying to clear temporary cache"
echo "           files executes 'rm -rf $LAB_BASE/incident1_cleanup/app_cache'"
echo "           and throws 'rm: $LAB_BASE/incident1_cleanup/app_cache/locked_kernel_state.sys: Operation not permitted'."
echo "  Goal   : Identify why UID 0 cannot remove the file, inspect file flags,"
echo "           clear the restriction using BSD file flag tools, and remove the cache folder."
echo ""
echo "INCIDENT 2: BROKEN DEPLOYMENT SYMLINK & LINKING ERROR"
echo "  Symptom: A deployment script failed when attempting to link configuration"
echo "           assets ($LAB_BASE/incident2_linking/sys_config/daemon.conf and"
echo "           $LAB_BASE/incident2_linking/sys_config/modules) into the target directory."
echo "  Goal   : Create the correct symbolic link type allowing directory linking,"
echo "           verify inode numbers, and ensure links traverse targets cleanly."
echo ""
echo "INCIDENT 3: ARCHIVE EXTRACTION & FILE TYPE INSPECTION"
echo "  Symptom: An application archive ($LAB_BASE/incident3_archiving/app_release.tar.gz)"
echo "           was extracted into '$LAB_BASE/incident3_archiving/extracted/'."
echo "           The executable payload 'service_daemon' fails to execute."
echo "  Goal   : Use the 'file' utility to analyze extracted file types,"
echo "           identify missing permissions/attributes, repair file modes, and"
echo "           re-pack a compliant archive preserving permissions."
echo "=============================================================================="
echo ""
echo "Run your diagnostic commands now inside: $LAB_BASE"
echo "Refer to commented section at the end of this script for step-by-step solution."

exit 0

# ==============================================================================
#                       STEP-BY-STEP SOLUTION GUIDE
# ==============================================================================
#
# ------------------------------------------------------------------------------
# RESOLUTION FOR INCIDENT 1: BSD File Flags & Directory Cleanup
# ------------------------------------------------------------------------------
# Diagnostic 1.1: Attempt directory removal to observe VFS failure
# Command:
#   rm -rf /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache
# Expected Output:
#   rm: /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache/locked_kernel_state.sys: Operation not permitted
#
# Diagnostic 1.2: Inspect file mode and BSD file flags using 'ls -lo' or 'stat'
# Command:
#   ls -lo /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache
# Expected Output:
#   -rw-r--r--  1 root  wheel  uchg 43 Aug 6 21:00 locked_kernel_state.sys
#   -rw-r--r--  1 root  wheel  -    43 Aug 6 21:00 temp_session.log
#
# Technical Explanation:
#   The 'uchg' (user immutable) flag prevents modification, renaming, or deletion
#   by any user including root. On FreeBSD/NetBSD/OpenBSD, 'chflags' manages these flags.
#
# Remediation 1.3: Clear immutable file flag recursively and remove directory
# Commands:
#   chflags -R nouchg,noschg /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache
#   # (If running on Linux lab compatibility host: chattr -R -i /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache)
#   rm -rf /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache
#
# Verification 1.4: Confirm directory removal
# Command:
#   ls -d /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache
# Expected Output:
#   ls: /var/tmp/lpi_715_2_lab/incident1_cleanup/app_cache: No such file or directory
#
# ------------------------------------------------------------------------------
# RESOLUTION FOR INCIDENT 2: Inode Linking & Symbolic Link Creation
# ------------------------------------------------------------------------------
# Technical Explanation:
#   Hard links ('ln target link') cannot point to directories (preventing infinite loops
#   in directory traversal) and cannot span across separate filesystems (EXDEV error).
#   Symbolic links ('ln -s target link') store the target path as a string and can
#   reference directories and cross-filesystem mount points.
#
# Remediation 2.1: Create symbolic link for daemon.conf file
# Command:
#   ln -s /var/tmp/lpi_715_2_lab/incident2_linking/sys_config/daemon.conf \
#         /var/tmp/lpi_715_2_lab/incident2_linking/mount_target/daemon.conf
#
# Remediation 2.2: Create symbolic link for modules directory
# Command:
#   ln -s /var/tmp/lpi_715_2_lab/incident2_linking/sys_config/modules \
#         /var/tmp/lpi_715_2_lab/incident2_linking/mount_target/modules
#
# Verification 2.3: Verify link types and targets using 'ls -l' and 'file'
# Command:
#   ls -l /var/tmp/lpi_715_2_lab/incident2_linking/mount_target/
# Expected Output:
#   lrwxr-xr-x  1 root  wheel  ... daemon.conf -> /var/tmp/lpi_715_2_lab/incident2_linking/sys_config/daemon.conf
#   lrwxr-xr-x  1 root  wheel  ... modules -> /var/tmp/lpi_715_2_lab/incident2_linking/sys_config/modules
#
# Command:
#   file /var/tmp/lpi_715_2_lab/incident2_linking/mount_target/daemon.conf
# Expected Output:
#   /var/tmp/lpi_715_2_lab/incident2_linking/mount_target/daemon.conf: symbolic link to /var/tmp/lpi_715_2_lab/incident2_linking/sys_config/daemon.conf
#
# ------------------------------------------------------------------------------
# RESOLUTION FOR INCIDENT 3: File Type Identification & Archive Management
# ------------------------------------------------------------------------------
# Diagnostic 3.1: Inspect file types in extracted directory using 'file'
# Command:
#   file /var/tmp/lpi_715_2_lab/incident3_archiving/extracted/*
# Expected Output:
#   /var/tmp/lpi_715_2_lab/incident3_archiving/extracted/env.config:    POSIX shell script, ASCII text executable
#   /var/tmp/lpi_715_2_lab/incident3_archiving/extracted/service_daemon: POSIX shell script, ASCII text executable
#
# Diagnostic 3.2: Inspect permissions to discover why execution fails
# Command:
#   ls -l /var/tmp/lpi_715_2_lab/incident3_archiving/extracted/service_daemon
# Expected Output:
#   -rw-r--r--  1 root  wheel  68 Aug 6 21:00 service_daemon
#
# Technical Explanation:
#   The file is identified as a shell script text file by magic analysis, but lacks
#   executable bit (+x) due to improper permissions when the tarball was created.
#
# Remediation 3.3: Fix permissions and verify execution
# Commands:
#   chmod +x /var/tmp/lpi_715_2_lab/incident3_archiving/extracted/service_daemon
#   /var/tmp/lpi_715_2_lab/incident3_archiving/extracted/service_daemon
# Expected Output:
#   Service Daemon Running OK
#
# Remediation 3.4: Re-pack archive preserving modes using tar (-p flag)
# Command:
#   cd /var/tmp/lpi_715_2_lab/incident3_archiving/extracted
#   tar -czpf /var/tmp/lpi_715_2_lab/incident3_archiving/app_release_repaired.tar.gz .
#
# Verification 3.5: Inspect archive content table with permissions using 'tar -tvf'
# Command:
#   tar -tvf /var/tmp/lpi_715_2_lab/incident3_archiving/app_release_repaired.tar.gz
# Expected Output:
#   -rwxr-xr-x  0 root   wheel       68 Aug 6 21:00 ./service_daemon
#   -rw-r--r--  0 root   wheel       15 Aug 6 21:00 ./env.config
# ==============================================================================