#!/usr/bin/env bash
# ==============================================================================
# LPI 702-100 (BSD Specialist v1.0) - Topic 712.5: Create and Change Hard and Symbolic Links
# Practical Production "Break & Fix" Laboratory Exercise
# ==============================================================================
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# Target Skill Set: Hard links (inode equivalence, link count, filesystem scope),
# Symbolic links (relative path resolution, dangling links), BSD link utility mechanics
# (ln options: -f, -h/-n, -s, directory link replacement behavior).
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lab_712_5"

echo "=== Initializing LPI-702 Topic 712.5 Break & Fix Environment ==="

# Clean up previous lab state if it exists
if [ -d "$LAB_DIR" ]; then
    rm -rf "$LAB_DIR"
fi

# ------------------------------------------------------------------------------
# STEP 1: Environment Provisioning & Release Hierarchy Setup
# ------------------------------------------------------------------------------
mkdir -p "$LAB_DIR/releases/v1.0.0/bin"
mkdir -p "$LAB_DIR/releases/v2.0.0/bin"
mkdir -p "$LAB_DIR/shared"
mkdir -p "$LAB_DIR/service"

# Create application binaries for release v1.0.0 and v2.0.0
cat << 'EOF' > "$LAB_DIR/releases/v1.0.0/bin/app"
#!/bin/sh
echo "Running Application Release v1.0.0"
EOF
chmod +x "$LAB_DIR/releases/v1.0.0/bin/app"

cat << 'EOF' > "$LAB_DIR/releases/v2.0.0/bin/app"
#!/bin/sh
echo "Running Application Release v2.0.0"
EOF
chmod +x "$LAB_DIR/releases/v2.0.0/bin/app"

# Shared production environment configuration
cat << 'EOF' > "$LAB_DIR/shared/app.conf"
DB_HOST=127.0.0.1
MAX_CONNECTIONS=100
LOG_LEVEL=DEBUG
EOF

# ------------------------------------------------------------------------------
# STEP 2: Fault Injection 1 - Broken Relative Symbolic Link
# ------------------------------------------------------------------------------
# Operator error: A relative symbolic link was created assuming working directory context
# of "$LAB_DIR/releases" rather than "$LAB_DIR/service".
ln -s "v2.0.0" "$LAB_DIR/service/current"

# ------------------------------------------------------------------------------
# STEP 3: Fault Injection 2 - Nested Directory Symlink Creation
# ------------------------------------------------------------------------------
# Initial release pointer pointing to v1.0.0 directory
ln -s "$LAB_DIR/releases/v1.0.0" "$LAB_DIR/service/active_dir"

# Operator error: Running `ln -sf target symlink_to_dir` without the -n / -h option
# (no-dereference). On Unix/BSD `ln`, because active_dir is a symlink pointing to an
# existing directory, `ln -sf` dereferences active_dir and creates a new symlink
# *inside* $LAB_DIR/releases/v1.0.0/ instead of replacing active_dir!
ln -sf "$LAB_DIR/releases/v2.0.0" "$LAB_DIR/service/active_dir" || true

# ------------------------------------------------------------------------------
# STEP 4: Fault Injection 3 - Incorrect Link Architecture (Soft Link instead of Hard Link)
# ------------------------------------------------------------------------------
# Service policy requires $LAB_DIR/service/app.conf to be a HARD LINK to $LAB_DIR/shared/app.conf
# so that inode updates persist across process isolation boundaries.
# Operator accidentally created a symbolic link instead.
ln -s "$LAB_DIR/shared/app.conf" "$LAB_DIR/service/app.conf"

echo ""
echo "=========================================================================="
echo "                           LAB ENVIRONMENT BROKEN                         "
echo "=========================================================================="
echo "SYMPTOMS OBSERVED IN PRODUCTION:"
echo "1. Invoking application link '$LAB_DIR/service/current/bin/app' fails with:"
echo "   'No such file or directory' (Dangling / broken relative symbolic link)."
echo ""
echo "2. Running deployment update to point '$LAB_DIR/service/active_dir' to v2.0.0 failed:"
echo "   '$LAB_DIR/service/active_dir' still resolves to v1.0.0, and an unintended"
echo "   nested symlink was created inside '$LAB_DIR/releases/v1.0.0/'."
echo ""
echo "3. Architecture violation: '$LAB_DIR/service/app.conf' must share the EXACT SAME"
echo "   inode as '$LAB_DIR/shared/app.conf' (Hard Link), but currently has a distinct inode"
echo "   due to being created as a symbolic link."
echo ""
echo "YOUR TASK OBJECTIVES:"
echo "1. Fix '$LAB_DIR/service/current' so it resolves cleanly to '$LAB_DIR/releases/v2.0.0'"
echo "   using a valid RELATIVE symbolic link path."
echo ""
echo "2. Remove the pollution inside '$LAB_DIR/releases/v1.0.0/' and atomically update"
echo "   '$LAB_DIR/service/active_dir' to point to '$LAB_DIR/releases/v2.0.0' using"
echo "   appropriate 'ln' flags (-n / -h / -f) to prevent directory dereferencing."
echo ""
echo "3. Convert '$LAB_DIR/service/app.conf' into a true HARD LINK pointing to"
echo "   '$LAB_DIR/shared/app.conf'. Verify inode numbers and link counts match."
echo "=========================================================================="
echo ""

exit 0

# ==============================================================================
#                       STUDENT SOLUTION (PASO A PASO)
# ==============================================================================
# Below is the step-by-step diagnostic and remediation sequence for LPI 712.5.
#
# ------------------------------------------------------------------------------
# DIAGNOSTIC PHASE
# ------------------------------------------------------------------------------
# 1. Inspect the broken relative symbolic link:
#    $ ls -l /tmp/lab_712_5/service/current
#    lrwxrwxrwx 1 user group 6 Aug  6 20:34 /tmp/lab_712_5/service/current -> v2.0.0
#    $ readlink /tmp/lab_712_5/service/current
#    v2.0.0
#    Explanation: Since the symlink resides in /tmp/lab_712_5/service/, the kernel resolves
#    v2.0.0 relative to /tmp/lab_712_5/service/ (looking for /tmp/lab_712_5/service/v2.0.0),
#    which does not exist.
#
# 2. Inspect the active_dir symlink and nested link pollution:
#    $ ls -ld /tmp/lab_712_5/service/active_dir
#    lrwxrwxrwx 1 user group 28 Aug  6 20:34 /tmp/lab_712_5/service/active_dir -> /tmp/lab_712_5/releases/v1.0.0
#    $ ls -l /tmp/lab_712_5/releases/v1.0.0/
#    lrwxrwxrwx 1 user group 28 Aug  6 20:34 v2.0.0 -> /tmp/lab_712_5/releases/v2.0.0
#    Explanation: Standard `ln -sf target link` follows the destination symlink if target is a
#    directory, creating `target` *inside* the existing destination directory.
#
# 3. Inspect file inodes and link types:
#    $ ls -li /tmp/lab_712_5/shared/app.conf /tmp/lab_712_5/service/app.conf
#    10234567 -rw-r--r-- 1 user group 52 Aug  6 20:34 /tmp/lab_712_5/shared/app.conf
#    10234599 lrwxrwxrwx 1 user group 26 Aug  6 20:34 /tmp/lab_712_5/service/app.conf -> /tmp/lab_712_5/shared/app.conf
#    Explanation: Notice file types ('-' vs 'l') and differing inode numbers (10234567 vs 10234599).
#
# ------------------------------------------------------------------------------
# REMEDIATION PHASE
# ------------------------------------------------------------------------------
# TASK 1: Fix relative symbolic link using proper relative target pathing
#
# Re-create the symlink with the relative path pointing out of 'service' into 'releases':
#    $ ln -snf ../releases/v2.0.0 /tmp/lab_712_5/service/current
#
# Verify execution succeeds:
#    $ /tmp/lab_712_5/service/current/bin/app
#    Output: Running Application Release v2.0.0
#
# ------------------------------------------------------------------------------
# TASK 2: Clean up nested symlink and update directory link with no-dereference
#
# Remove the accidentally created symlink inside v1.0.0:
#    $ rm -f /tmp/lab_712_5/releases/v1.0.0/v2.0.0
#
# Update the symlink using `-n` (or `-h` on BSD `ln`) combined with `-f` (force/unlink):
#    $ ln -snf /tmp/lab_712_5/releases/v2.0.0 /tmp/lab_712_5/service/active_dir
#    Note: -n / -h (--no-dereference / do not follow symlink to directory) forces `ln`
#    to treat `active_dir` as a plain symlink object to be replaced rather than a directory destination.
#
# Verify target path:
#    $ readlink /tmp/lab_712_5/service/active_dir
#    Output: /tmp/lab_712_5/releases/v2.0.0
#
# ------------------------------------------------------------------------------
# TASK 3: Re-create hard link and verify inode parity
#
# Remove the incorrect symbolic link:
#    $ rm -f /tmp/lab_712_5/service/app.conf
#
# Create a hard link pointing to the shared configuration file:
#    $ ln /tmp/lab_712_5/shared/app.conf /tmp/lab_712_5/service/app.conf
#
# Verify hard link structure (Inode number match and link count = 2):
#    $ ls -li /tmp/lab_712_5/shared/app.conf /tmp/lab_712_5/service/app.conf
#    Expected Output:
#    10234567 -rw-r--r-- 2 user group 52 Aug  6 20:34 /tmp/lab_712_5/service/app.conf
#    10234567 -rw-r--r-- 2 user group 52 Aug  6 20:34 /tmp/lab_712_5/shared/app.conf
# ==============================================================================