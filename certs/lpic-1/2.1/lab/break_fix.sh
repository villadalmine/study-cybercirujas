#!/usr/bin/env bash
# Break & Fix Lab: Silent Failure / Strict Mode
# This script simulates a dangerous, poorly written shell script that causes data destruction.

# We deliberately do NOT use strict mode here to demonstrate the failure.
# set -euo pipefail

echo "[+] Starting Break & Fix Lab Setup for Shell Scripting..."

# 1. Setup a dummy application environment
mkdir -p /tmp/myapp/logs
touch /tmp/myapp/logs/access.log
touch /tmp/myapp/logs/error.log

# Set a variable that we will pretend to 'lose' later
APP_DIR="/tmp/myapp"

echo "=========================================================================="
echo "LAB SCENARIO:"
echo "A nightly log-cleanup script was written by an intern."
echo "The script changes directory to the application folder and deletes old logs."
echo "However, the server administrator recently renamed the application directory,"
echo "and the script was never updated. Let's see what happens when it runs."
echo ""
echo "GOAL:"
echo "1. We will simulate running the script below. It contains a critical flaw."
echo "2. Your goal is to identify the flaw, and add the 'Unofficial Bash Strict Mode'"
echo "   to prevent the script from deleting the wrong files if the directory is missing."
echo "=========================================================================="

echo "Simulating the dangerous script execution..."
echo "-------------------------------------------"

# The Dangerous Script Logic:
# The admin renamed /tmp/myapp to /tmp/myapp_v2, so this cd will fail.
cd /tmp/myapp_missing_directory 2>/dev/null

# Because 'set -e' is not active, the script continues to the next line!
# We use a safe echo here instead of rm to protect your VM, but imagine this was rm -rf *
echo "[FATAL DANGER] Executing: rm -rf *"
echo "(If this were real, it would have just deleted everything in your current directory,"
echo " because the 'cd' failed and left you wherever you were before running the script!)"

echo "-------------------------------------------"
echo "TASK:"
echo "How would you rewrite the top of this script to ensure that if the 'cd' command"
echo "fails, the script immediately aborts before executing the 'rm' command?"

# ==========================================================================
# SOLUTION (Do not look until you have tried to solve it yourself!)
# ==========================================================================
# 1. Add strict mode immediately after the shebang:
#    #!/usr/bin/env bash
#    set -euo pipefail
#
# 2. Alternatively, chain the commands with logical AND (&&):
#    cd /tmp/myapp_missing_directory && rm -rf *
#
#    Using 'set -e' is the preferred SRE pattern because it protects the entire script
#    without relying on the developer remembering to use '&&' on every single line.
# ==========================================================================