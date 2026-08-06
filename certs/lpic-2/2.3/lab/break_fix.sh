#!/usr/bin/env bash

# ==============================================================================
# LPIC-2 (Exam 202-450, v4.5) - Topic 2.3: File Sharing (NFS & Samba)
# Lab Scenario: Production Break & Fix Exercise
# Target Audience: SRE / Senior Systems Engineer / CNCF Candidate
# ==============================================================================
#
# DESCRIPTION:
# This script simulates a realistic, multi-layered file-sharing outage on a 
# Linux server hosting NFSv4 and Samba (SMB/CIFS) services.
# 
# THE SCENARIO:
# A recent maintenance automation script modified NFS export definitions and
# Samba share configurations. Users are now reporting:
# 1. NFS clients receive "Permission denied" or are mounted as Read-Only when
#    attempting to write to the exported NFS directory.
# 2. Samba clients cannot connect or authenticate to the shared directory, 
#    and `testparm` reports configuration anomalies.
# 3. System logs display rpc.mountd and smbd daemon permission/parsing errors.
#
# GOAL:
# Diagnosing and fixing the NFS `/etc/exports` parsing bug and the Samba 
# `/etc/samba/smb.conf` permission & parameter errors without disrupting service 
# security or re-creating shares from scratch.
# ==============================================================================

set -euo pipefail

# Ensure script is executed as root
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This lab script must be run as root." >&2
   exit 1
fi

echo "========================================================================"
echo "          LPIC-2 Topic 2.3: File Sharing Lab (Break Phase)              "
echo "========================================================================"
echo "[*] Preparing lab environment and installing required file sharing packages..."

# Detect Package Manager and Install Dependencies
if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nfs-kernel-server samba smbclient rpcbind >/dev/null 2>&1
    NFS_SERVICE="nfs-kernel-server"
    SAMBA_SERVICE="smbd"
elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    PKG_MGR=$(command -v dnf || command -v yum)
    $PKG_MGR install -y -q nfs-utils samba samba-client rpcbind >/dev/null 2>&1
    NFS_SERVICE="nfs-server"
    SAMBA_SERVICE="smb"
else
    echo "[ERROR] Unsupported package manager. Please run on Debian/Ubuntu or RHEL/Rocky." >&2
    exit 1
fi

# Step 1: Set up directories and mock share files
echo "[*] Creating production share directories..."
NFS_DIR="/srv/nfs/engineering"
SMB_DIR="/srv/samba/finance"

mkdir -p "${NFS_DIR}"
mkdir -p "${SMB_DIR}"

echo "Confidential Engineering Docs" > "${NFS_DIR}/design_spec.txt"
echo "Q3 Financial Audit Report" > "${SMB_DIR}/audit_q3.txt"

# Step 2: Inject Breaking Changes - NFS (/etc/exports)
# ISSUE A: Space between client IP specifier and options list in /etc/exports.
# In exportfs syntax, "127.0.0.1 (rw,...)" parses "127.0.0.1" with default options (ro,root_squash)
# and "(rw,...)" as a separate hostname rule applying to world (*)!
# ISSUE B: Mismatch on directory POSIX permissions (root:root 0700) preventing squashed users.
echo "[*] Injecting controlled break into NFS configuration (/etc/exports)..."
cp /etc/exports /etc/exports.bak.$(date +%s) 2>/dev/null || true

cat << 'EOF' > /etc/exports
# LPIC-2 File Sharing Lab Export
/srv/nfs/engineering 127.0.0.1 (rw,sync,no_subtree_check,no_root_squash)
EOF

chmod 0700 "${NFS_DIR}"
chown root:root "${NFS_DIR}"

# Step 3: Inject Breaking Changes - Samba (/etc/samba/smb.conf)
# ISSUE C: Syntax error in smb.conf parameter ("invalid option = yes" & invalid section token).
# ISSUE D: Incorrect share permission mask and invalid path.
echo "[*] Injecting controlled break into Samba configuration (/etc/samba/smb.conf)..."
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%s) 2>/dev/null || true

cat << 'EOF' > /etc/samba/smb.conf
[global]
    workgroup = WORKGROUP
    server string = LPIC2 Lab Samba Server
    security = user
    map to guest = Bad User
    log file = /var/log/samba/log.%m
    max log size = 1000
    invalid_global_directive = enabled

[finance]
    comment = Finance Team Share
    path = /srv/samba/finance_broken_path
    read only = no
    guest ok = yes
    browsable = yes
    create mask = 0000
    directory mask = 0000
EOF

chmod 0700 "${SMB_DIR}"
chown root:root "${SMB_DIR}"

# Step 4: Reload / Restart Services to Apply Broken State
echo "[*] Reloading system services into broken state..."
systemctl restart rpcbind || true
systemctl restart "${NFS_SERVICE}" || true
exportfs -ra || true
systemctl restart "${SAMBA_SERVICE}" || true

echo ""
echo "========================================================================"
echo "                        LAB OUTAGE ACTIVATED                            "
echo "========================================================================"
echo "STUDENT TASK & SYMPTOMS TO DIAGNOSE:"
echo "------------------------------------------------------------------------"
echo "1. NFS SYMPTOM:"
echo "   Attempting to mount and write to NFS share locally:"
echo "     mount -t nfs 127.0.0.1:/srv/nfs/engineering /mnt"
echo "     touch /mnt/testfile"
echo "   Expected Failure: 'Permission denied' or unintended export options."
echo "   Diagnostic Tool: Inspect '/etc/exports', run 'exportfs -v', and check"
echo "   NFS daemon logs in 'journalctl -u ${NFS_SERVICE}'."
echo ""
echo "2. SAMBA SYMPTOM:"
echo "   Running the configuration validation tool:"
echo "     testparm -s"
echo "   Attempting to list shares using smbclient:"
echo "     smbclient -L //127.0.0.1 -N"
echo "   Expected Failure: Syntax/parsing errors reported by testparm, path"
echo "   not found when connecting to [finance], or inability to read/write."
echo "------------------------------------------------------------------------"
echo "Your objective: Fix both services so that:"
echo "  a) NFS /srv/nfs/engineering can be mounted via 127.0.0.1 and written to."
echo "  b) Samba share [finance] passes 'testparm' clean check, points to"
echo "     '/srv/samba/finance', and allows guest read/write access."
echo "========================================================================"
echo ""

# ==============================================================================
# SOLUTION AND STEP-BY-STEP TROUBLESHOOTING GUIDE (FOR INSTRUCTOR / REFERENCE)
# ==============================================================================
#
# --- PART 1: DIAGNOSING & FIXING NFS ---
#
# Step 1.1: Verify current NFS exports state
#   Command: exportfs -v
#   Observation: Output shows:
#     /srv/nfs/engineering  (rw,sync,wdelay,hide,nocrossmnt,secure,root_squash,no_all_squash,...)
#     /srv/nfs/engineering  127.0.0.1(ro,sync,wdelay,hide,nocrossmnt,secure,root_squash,no_all_squash,...)
#   Root Cause: In `/etc/exports`, a space between `127.0.0.1` and `(rw,...)` causes
#   NFS to treat `127.0.0.1` as a host with DEFAULT options (ro, root_squash), while
#   `(rw,...)` is interpreted as a wildcard host (`*`) specification with `rw`.
#
# Step 1.2: Fix `/etc/exports`
#   Remove the space between host identifier and host options:
#   Edit `/etc/exports`:
#     /srv/nfs/engineering 127.0.0.1(rw,sync,no_subtree_check,no_root_squash)
#
# Step 1.3: Fix directory permissions for NFS squashed user access
#   Command: chmod 0777 /srv/nfs/engineering
#
# Step 1.4: Re-export shares and test
#   Command: exportfs -ra
#   Command: exportfs -v
#   Command: mount -t nfs 127.0.0.1:/srv/nfs/engineering /mnt
#   Command: touch /mnt/test_nfs_ok && rm /mnt/test_nfs_ok
#   Command: umount /mnt
#
# --- PART 2: DIAGNOSING & FIXING SAMBA ---
#
# Step 2.1: Audit smb.conf syntax
#   Command: testparm -s
#   Observation: Reports unknown parameter 'invalid_global_directive' under [global].
#
# Step 2.2: Fix `/etc/samba/smb.conf`
#   Edit `/etc/samba/smb.conf` to look like this:
#
#   [global]
#       workgroup = WORKGROUP
#       server string = LPIC2 Lab Samba Server
#       security = user
#       map to guest = Bad User
#       log file = /var/log/samba/log.%m
#       max log size = 1000
#
#   [finance]
#       comment = Finance Team Share
#       path = /srv/samba/finance
#       read only = no
#       guest ok = yes
#       browsable = yes
#       create mask = 0664
#       directory mask = 0775
#
# Step 2.3: Fix directory POSIX ownership/permissions for guest user (nobody/nobody)
#   Command: chmod 0777 /srv/samba/finance
#   Command: chown -R nobody:nogroup /srv/samba/finance (or nobody:nobody on RHEL)
#
# Step 2.4: Restart Samba daemon and test
#   Command: systemctl restart smbd (or systemctl restart smb)
#   Command: testparm -s
#   Command: smbclient //127.0.0.1/finance -N -c "ls"
#   Command: smbclient //127.0.0.1/finance -N -c "put /etc/hostname test_smb.txt"
#
# ==============================================================================