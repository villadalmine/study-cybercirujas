#!/bin/bash
# Break & Fix Lab: Emergency Mode / fstab Corruption
# This script deliberately breaks /etc/fstab to simulate a critical boot failure scenario.

set -e

echo "[+] Starting Break & Fix Lab Setup for Devices and Filesystems..."

# 1. Create a dummy mount point
mkdir -p /mnt/critical_data

# 2. Corrupt the fstab file by adding a non-existent UUID that is NOT marked as nofail
# We backup the original fstab first so the user can theoretically recover it, 
# but the real challenge is editing the broken one.
cp /etc/fstab /etc/fstab.backup

cat << 'BROKEN_ENTRY' >> /etc/fstab

# --- Added by Lab Script ---
# This simulates a disk that was physically removed or a snapshot restoration 
# where the UUID of the block device changed, but the config wasn't updated.
UUID=deadbeef-1234-5678-90ab-cdef01234567 /mnt/critical_data ext4 defaults 0 2
BROKEN_ENTRY

echo "=========================================================================="
echo "LAB SCENARIO:"
echo "A junior admin migrated a data volume to a new disk array overnight."
echo "They copied the data, but forgot to update the UUID in /etc/fstab."
echo "The old disk was destroyed."
echo ""
echo "If this server reboots right now, systemd will wait 90 seconds for"
echo "UUID=deadbeef-... to appear. When it times out, the server will drop into"
echo "Emergency Mode, and SSH will be offline, causing a Sev-1 outage."
echo ""
echo "GOAL:"
echo "1. Run 'sudo mount -a'. Observe the failure."
echo "2. Edit /etc/fstab and fix the entry so that the system ignores the missing"
echo "   disk and boots normally, while leaving the entry in place for documentation."
echo "3. Run 'sudo mount -a' again. It should return silently with no errors."
echo "=========================================================================="

# ==========================================================================
# SOLUTION (Do not look until you have tried to solve it yourself!)
# ==========================================================================
# 1. Observe the error:
#    sudo mount -a
#    # Output: mount: /mnt/critical_data: can't find UUID=deadbeef-...
#
# 2. Fix the file:
#    # Use an editor like nano or vi
#    sudo nano /etc/fstab
#    
#    # Find the broken line:
#    # UUID=deadbeef-... /mnt/critical_data ext4 defaults 0 2
#    
#    # Change 'defaults' to 'defaults,nofail':
#    # UUID=deadbeef-... /mnt/critical_data ext4 defaults,nofail 0 2
#
#    # (Alternatively, you can comment the line out with a '#' at the start, 
#    # but using 'nofail' is the correct SRE pattern for non-root mounts).
#
# 3. Verify it's fixed:
#    sudo mount -a
#    # Should return silently with exit code 0.
# ==========================================================================