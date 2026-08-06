#!/usr/bin/env bash
# ==============================================================================
# CNCF / LPI LPIC-2 (Exams 201-450 & 202-450 v4.5) Production Lab Material
# Topic 1.1: Capacity Planning (Exam 201, Weight 7)
# Script: break_and_fix_capacity_planning.sh
# Author: Senior SRE & Principal Platform Architect
# ==============================================================================
#
# TECHNICAL BACKGROUND & ARCHITECTURE OVERVIEW:
# ------------------------------------------------------------------------------
# Capacity planning in Linux production environments requires monitoring and 
# predicting utilization across four primary resource pillars: CPU, Memory, 
# Disk I/O, and Network/System Handles (File Descriptors, Inodes, Sockets).
#
# 1. System Limits & File Descriptors:
#    - Kernel-wide max open file handles: /proc/sys/fs/file-max
#    - Current kernel file descriptor allocation: /proc/sys/fs/file-nr
#      Format: [allocated file handles] [unused allocated handles] [max file handles]
#    - User-space per-process limit enforced by PAM/systemd: ulimit -n / NOFILE
#    - Inotify user watches: /proc/sys/fs/inotify/max_user_watches
#
# 2. Sysstat Data Collection Subsystem:
#    - Binary collector: sadc (System Activity Data Collector) invoked by sa1
#    - Report generator: sar (System Activity Reporter) invoked by sa2
#    - Configuration: /etc/default/sysstat (ENABLED="true"), /etc/sysstat/sysstat
#    - Timer units: sysstat-collect.timer and sysstat-summary.timer (systemd)
#    - Daily data files stored in: /var/log/sysstat/saDD or /var/log/sa/saDD
#
# 3. Kernel Subsystem Monitoring & Metrics:
#    - CPU & Load: /proc/stat, /proc/loadavg (mpstat, sar -u, uptime)
#    - Memory & Swap Pressure: /proc/meminfo (vmstat, sar -r, sar -S, free)
#    - Disk I/O Bottlenecks: /proc/diskstats (iostat -xz, sar -b, sar -d)
#    - Cgroups v2 Resource Accounting: /sys/fs/cgroup/ (systemd-cgtop)
#
# REFERENCES:
# - LPI LPIC-2 Objectives: https://www.lpi.org/our-certifications/lpic-2-overview/
# - Linux Kernel /proc Documentation: https://www.kernel.org/doc/Documentation/filesystems/proc.txt
# - Sysstat / SAR Official Documentation: https://sysstat.github.io/
# - Linux Kernel Cgroups v2: https://www.kernel.org/doc/Documentation/cgroup-v2.txt
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This break-and-fix script must be executed as root." >&2
   exit 1
fi

echo "======================================================================"
echo " LPIC-2 Topic 1.1: Capacity Planning - Break & Fix Laboratory Environment"
echo "======================================================================"
echo "[*] Initializing safe, controlled breakage on disposable lab VM..."

# ------------------------------------------------------------------------------
# STEP 1: Ensure sysstat package & dependencies are installed
# ------------------------------------------------------------------------------
if ! command -v sar &>/dev/null || ! command -v iostat &>/dev/null; then
    echo "[*] Installing sysstat monitoring suite..."
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq sysstat lsof python3 &>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q sysstat lsof python3 &>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q sysstat lsof python3 &>/dev/null
    fi
fi

# ------------------------------------------------------------------------------
# STEP 2: Inject Controlled Breakage Scenario
# ------------------------------------------------------------------------------

# Breakage A: Disable sysstat background data collection baseline
echo "[+] Inducing Failure A: Misconfiguring sysstat trend historical collector..."
if [[ -f /etc/default/sysstat ]]; then
    sed -i 's/ENABLED="true"/ENABLED="false"/g' /etc/default/sysstat
fi
systemctl stop sysstat-collect.timer &>/dev/null || true
systemctl disable sysstat-collect.timer &>/dev/null || true
systemctl mask sysstat-collect.timer &>/dev/null || true
systemctl stop sysstat.service &>/dev/null || true

# Breakage B: Throttle Kernel & Process-level File Descriptor Caps
echo "[+] Inducing Failure B: Restricting system-wide and process file descriptor capacity..."

# Create broken sysctl configuration (extremely low global file-max and inotify limits)
cat << 'EOF' > /etc/sysctl.d/99-capacity-break.conf
# ARTIFICIAL CAPACITY BOTTLENECK INJECTED FOR LAB EXERCISE
fs.file-max = 1024
fs.inotify.max_user_watches = 64
EOF
sysctl -p /etc/sysctl.d/99-capacity-break.conf &>/dev/null || sysctl -w fs.file-max=1024 &>/dev/null

# Create broken PAM security limits
cat << 'EOF' > /etc/security/limits.d/99-capacity-break.conf
*    soft    nofile    256
*    hard    nofile    512
root soft    nofile    256
root hard    nofile    512
EOF

# Create broken systemd default service limits
mkdir -p /etc/systemd/system.conf.d/
cat << 'EOF' > /etc/systemd/system.conf.d/99-capacity-break.conf
[Manager]
DefaultLimitNOFILE=256:512
EOF
systemctl daemon-reload &>/dev/null || true

# Breakage C: Launch background worker to exhaust file descriptors up to global cap
echo "[+] Inducing Failure C: Spawning rogue background leak process to consume kernel handles..."

cat << 'EOF' > /usr/local/bin/lab_fd_leaker.py
#!/usr/bin/env python3
import time
import os
import sys

files = []
# Keep opening anonymous descriptors until limit is reached
for i in range(800):
    try:
        f = open('/dev/null', 'r')
        files.append(f)
    except Exception:
        break

# Hold descriptors open indefinitely
while True:
    time.sleep(3600)
EOF

chmod +x /usr/local/bin/lab_fd_leaker.py

# Run rogue process in background via systemd-run or nohup
nohup /usr/local/bin/lab_fd_leaker.py >/dev/null 2>&1 &
LEAKER_PID=$!
echo "$LEAKER_PID" > /var/run/lab_fd_leaker.pid

# ------------------------------------------------------------------------------
# STEP 3: Present Problem Statement to the Student
# ------------------------------------------------------------------------------
cat << 'EOF'

==============================================================================
 SYSTEM INCIDENT REPORT - LPIC-2 TOPIC 1.1 CAPACITY PLANNING CHALLENGE
==============================================================================
STATUS: CRITICAL / DEGRADED PERFORMANCE
AFFECTED SUBSYSTEMS: Historical Trend Metrics Gathering, System Handle Allocation

INCIDENT DESCRIPTION:
Application teams report sporadic "Errno 24: Too many open files" errors 
across the system, preventing tools from spawning child processes and 
logging events. Furthermore, the Lead SRE attempting to perform capacity 
planning trend analysis discovered that historical performance statistics 
(`sar`) are completely missing or outdated for today's data window.

YOUR OBJECTIVES:
1. Diagnose why kernel file descriptor metrics (`/proc/sys/fs/file-nr`) are
   approaching capacity limits and identify the rogue process consuming handles.
2. Identify and revert all persistent configuration bottlenecks limiting system 
   file handle capacity (`sysctl`, PAM limits, systemd defaults).
3. Restore historical capacity data collection infrastructure (`sysstat`) so that
   `sar` properly records CPU, memory, and I/O metrics on schedule.
4. Verify overall system capacity health using Linux diagnostics (`vmstat`, 
   `iostat`, `sar`, `systemd-cgtop`, `prlimit`).

DIAGNOSTIC TOOLKIT (RECOMMENDED COMMANDS TO TRY):
  - Check current vs max global file descriptors:
      cat /proc/sys/fs/file-nr
      sysctl fs.file-max
  - Inspect process open file descriptors and active limits:
      lsof | head -n 20
      prlimit --pid=$(cat /var/run/lab_fd_leaker.pid 2>/dev/null || echo 1)
      ulimit -a
  - Check historical metrics collector status:
      sar -u 1 3
      systemctl status sysstat-collect.timer
      cat /etc/default/sysstat
  - Analyze real-time capacity usage across pillars:
      vmstat 1 5
      iostat -xz 1 3
      mpstat -P ALL 1 2

==============================================================================
NOTE: The detailed step-by-step solution is embedded inside this script!
To inspect the solution once done, read the commented block at the end of:
file://$(realpath $0)
==============================================================================

EOF

exit 0

# ==============================================================================
#                         STEP-BY-STEP SOLUTION & RCA
# ==============================================================================
# (Keep this section commented out so students can attempt the challenge first!)
#
# ------------------------------------------------------------------------------
# ROOT CAUSE ANALYSIS (RCA):
# ------------------------------------------------------------------------------
# 1. File Descriptor Exhaustion:
#    The global kernel limit `fs.file-max` was set to 1024 (via 
#    `/etc/sysctl.d/99-capacity-break.conf`). A background python daemon 
#    (`lab_fd_leaker.py`) opened hundreds of file handles to `/dev/null`, 
#    pushing `/proc/sys/fs/file-nr` close to the max capacity. In addition, 
#    PAM security limits (`/etc/security/limits.d/99-capacity-break.conf`) and 
#    systemd manager limits (`/etc/systemd/system.conf.d/99-capacity-break.conf`) 
#    were artificially bottlenecked to 256 soft / 512 hard open files.
#
# 2. Historical Baseline Collection Failure:
#    The `sysstat` daemon configuration `/etc/default/sysstat` was set to 
#    `ENABLED="false"`, and the systemd timer `sysstat-collect.timer` was 
#    stopped, disabled, and masked, preventing `sadc` from gathering `saDD` 
#    binary performance snapshots into `/var/log/sysstat/`.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP RESOLUTION COMMANDS:
# ------------------------------------------------------------------------------
#
# STEP 1: Diagnose File Handle Bottleneck & Terminate Leak Process
# ------------------------------------------------------------------
# # Check current global kernel handle accounting [Allocated, Unused, Max]:
# cat /proc/sys/fs/file-nr
# # Expected output sample showing saturation: 1010 0 1024
#
# # Locate processes consuming the highest number of open file descriptors:
# lsof | awk '{print $1, $2}' | sort | uniq -c | sort -nr | head -n 10
#
# # Terminate the rogue background handle leaker process:
# if [[ -f /var/run/lab_fd_leaker.pid ]]; then
#     kill -9 $(cat /var/run/lab_fd_leaker.pid)
#     rm -f /var/run/lab_fd_leaker.pid
# fi
# pkill -9 -f lab_fd_leaker.py || true
# rm -f /usr/local/bin/lab_fd_leaker.py
#
# STEP 2: Revert System-Wide Capacity Bottlenecks & Limits
# ------------------------------------------------------------------
# # Remove broken sysctl parameters and restore default kernel capacity:
# rm -f /etc/sysctl.d/99-capacity-break.conf
# sysctl -w fs.file-max=9223372036854775807 || sysctl -w fs.file-max=2097152
# sysctl -w fs.inotify.max_user_watches=524288
# sysctl --system
#
# # Remove broken PAM limits:
# rm -f /etc/security/limits.d/99-capacity-break.conf
#
# # Remove broken systemd default process limits:
# rm -f /etc/systemd/system.conf.d/99-capacity-break.conf
# systemctl daemon-reload
#
# STEP 3: Restore Historical Trend Monitoring (`sysstat` / `sar`)
# ------------------------------------------------------------------
# # Enable sysstat data collection in defaults:
# if [[ -f /etc/default/sysstat ]]; then
#     sed -i 's/ENABLED="false"/ENABLED="true"/g' /etc/default/sysstat
# fi
#
# # Unmask, enable, and start systemd collectors:
# systemctl unmask sysstat-collect.timer
# systemctl enable --now sysstat-collect.timer sysstat.service
#
# # Force immediate historical sample generation via sa1 / sadc:
# /usr/lib/sysstat/sa1 1 1 || /usr/lib64/sysstat/sa1 1 1 || true
#
# STEP 4: Production Verification & Capacity Validation
# ------------------------------------------------------------------
# # 1. Verify global file descriptor headroom:
# cat /proc/sys/fs/file-nr
# # Expected output sample showing low utilization: 1280 0 9223372036854775807
#
# # 2. Verify current process open file limit (should match default 1024 or higher):
# ulimit -n
#
# # 3. Test historical CPU trend generation with sar:
# sar -u 1 3
# # Expected output: Valid CPU %user, %system, %iowait, %idle breakdown table
#
# # 4. Test RAM & Swap capacity metrics:
# sar -r 1 2
# sar -S 1 2
# free -h
#
# # 5. Test Disk I/O throughput & queue statistics:
# iostat -xz 1 3
# vmstat 1 5
# ==============================================================================