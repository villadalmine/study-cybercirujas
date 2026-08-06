#!/bin/bash
# Break & Fix Lab: Broken Package Dependency
# This script deliberately breaks the system's package state to simulate a common production issue.

set -e

echo "[+] Starting Break & Fix Lab Setup for Linux Package Management..."

if [ -f /etc/debian_version ]; then
    echo "[+] Debian/Ubuntu system detected."
    # Install a tiny utility package to act as our victim
    apt-get update -qq && apt-get install -y tree -qq > /dev/null
    
    echo "[!] Deliberately corrupting the dpkg state for 'tree'..."
    # Remove a critical file installed by the package without using the package manager
    rm -f /usr/bin/tree
    
    # Introduce a broken dependency configuration
    cat << 'BROKEN' > /var/lib/dpkg/info/tree.list
/usr/bin/tree
/usr/share/doc/tree
/does/not/exist
BROKEN

    echo "=========================================================================="
    echo "LAB SCENARIO:"
    echo "A junior admin accidentally deleted some files, and now a package is "
    echo "reporting issues. The 'tree' command is missing, but the package manager "
    echo "believes it is installed."
    echo ""
    echo "GOAL:"
    echo "1. Verify which package provides the 'tree' command and check its integrity."
    echo "2. Repair the package state so the command works again and dpkg shows no errors."
    echo "=========================================================================="

elif [ -f /etc/redhat-release ]; then
    echo "[+] Red Hat/CentOS/Fedora system detected."
    dnf install -y tree -q > /dev/null
    
    echo "[!] Deliberately corrupting the rpm state for 'tree'..."
    rm -f /usr/bin/tree
    
    echo "=========================================================================="
    echo "LAB SCENARIO:"
    echo "A developer accidentally deleted some files, and now a package is "
    echo "reporting issues. The 'tree' command is missing, but the package manager "
    echo "believes it is installed."
    echo ""
    echo "GOAL:"
    echo "1. Verify which package provides the 'tree' command and check its integrity."
    echo "2. Repair the package state so the command works again and rpm shows no errors."
    echo "=========================================================================="
else
    echo "[-] Unsupported OS for this lab."
    exit 1
fi

# ==========================================================================
# SOLUTION (Do not look until you have tried to solve it yourself!)
# ==========================================================================
# Debian/Ubuntu Solution:
# 1. Verify the package integrity:
#    dpkg -V tree
#    # Output will show 'missing /usr/bin/tree'
# 2. Reinstall the package to fix the missing files:
#    apt-get install --reinstall tree
# 3. Verify it's fixed:
#    dpkg -V tree  # Should return nothing (clean)
#
# RHEL/CentOS/Fedora Solution:
# 1. Verify the package integrity:
#    rpm -V tree
#    # Output will show 'missing /usr/bin/tree'
# 2. Reinstall the package:
#    dnf reinstall tree
# 3. Verify it's fixed:
#    rpm -V tree   # Should return nothing (clean)
# ==========================================================================