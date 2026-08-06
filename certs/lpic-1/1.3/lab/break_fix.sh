#!/bin/bash
# Break & Fix Lab: Broken Configuration Stream
# This script deliberately breaks a critical text-processing stream to simulate a common production issue.

set -e

echo "[+] Starting Break & Fix Lab Setup for GNU and Unix Commands..."

# Create a mock web server access log
mkdir -p /var/log/mock_app
cat << 'LOG' > /var/log/mock_app/access.log
192.168.1.10 - - [10/Oct/2026:13:55:36] "GET /api/login HTTP/1.1" 401
10.0.0.5 - - [10/Oct/2026:13:55:37] "GET /api/status HTTP/1.1" 200
192.168.1.10 - - [10/Oct/2026:13:55:38] "GET /api/login HTTP/1.1" 401
172.16.0.4 - - [10/Oct/2026:13:55:39] "POST /api/data HTTP/1.1" 201
192.168.1.10 - - [10/Oct/2026:13:55:40] "GET /api/login HTTP/1.1" 401
10.0.0.5 - - [10/Oct/2026:13:55:41] "GET /api/status HTTP/1.1" 200
LOG

# Create a broken script that attempts to analyze the log
cat << 'SCRIPT' > /usr/local/bin/analyze_log.sh
#!/bin/bash
# This script is supposed to print a count of the unique IP addresses that received a 401 status.
# However, it contains a logical error in the pipeline.
awk '$9 == "401" {print $1}' /var/log/mock_app/access.log | uniq -c
SCRIPT

chmod +x /usr/local/bin/analyze_log.sh

echo "=========================================================================="
echo "LAB SCENARIO:"
echo "A junior engineer wrote a script (/usr/local/bin/analyze_log.sh) to count"
echo "the unique IP addresses that are triggering '401 Unauthorized' errors in"
echo "the application log (/var/log/mock_app/access.log)."
echo ""
echo "However, the script is outputting multiple separate lines for the same IP"
echo "address instead of a single grouped count."
echo ""
echo "GOAL:"
echo "1. Run the script and observe the broken behavior."
echo "2. Edit /usr/local/bin/analyze_log.sh and fix the pipeline so that it"
echo "   correctly groups the identical IP addresses together using standard GNU"
echo "   core utilities."
echo "=========================================================================="

# ==========================================================================
# SOLUTION (Do not look until you have tried to solve it yourself!)
# ==========================================================================
# 1. Run the script:
#    /usr/local/bin/analyze_log.sh
#    # Output will be:
#    #   1 192.168.1.10
#    #   1 192.168.1.10
#    #   1 192.168.1.10
#
# 2. Fix the script:
#    # The 'uniq' command only collapses adjacent lines. It requires sorted input.
#    # Edit the script using nano or vi:
#    nano /usr/local/bin/analyze_log.sh
#    
#    # Change this line:
#    # awk '$9 == "401" {print $1}' /var/log/mock_app/access.log | uniq -c
#    
#    # To this:
#    # awk '$9 == "401" {print $1}' /var/log/mock_app/access.log | sort | uniq -c
#
# 3. Verify it's fixed:
#    /usr/local/bin/analyze_log.sh
#    # Output should now correctly group them:
#    #   3 192.168.1.10
# ==========================================================================