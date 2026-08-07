#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist (702-100) - Exam Version 1.0
# Topic 713.3: Maintain System Time (Weight: 1.67)
# Production SRE Break & Fix Laboratory Environment
# Target OS: Linux / BSD Compatible Lab Shell
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================

set -euo pipefail

# ANSI Color Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

LOG_FILE="/tmp/lpi_713.3_lab_break.log"

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[ERROR] This laboratory scenario script must be executed as root.${NC}" >&2
        echo "Please re-run using: sudo $0" >&2
        exit 1
    fi
}

backup_configs() {
    echo -e "${BLUE}[INFO] Creating configuration backups...${NC}"
    mkdir -p /tmp/ntp_lab_backup
    
    [[ -f /etc/ntp.conf ]] && cp /etc/ntp.conf /tmp/ntp_lab_backup/ntp.conf.bak
    [[ -f /etc/ntpd.conf ]] && cp /etc/ntpd.conf /tmp/ntp_lab_backup/ntpd.conf.bak
    [[ -f /etc/chrony/chrony.conf ]] && cp /etc/chrony/chrony.conf /tmp/ntp_lab_backup/chrony.conf.bak
    [[ -f /etc/chrony.conf ]] && cp /etc/chrony.conf /tmp/ntp_lab_backup/chrony.conf.bak
    [[ -f /etc/rc.conf ]] && cp /etc/rc.conf /tmp/ntp_lab_backup/rc.conf.bak
    
    echo -e "${GREEN}[OK] Backups stored in /tmp/ntp_lab_backup/${NC}"
}

break_system_time() {
    echo -e "${YELLOW}[CAUTION] Injecting production time synchronization failures...${NC}"
    
    # 1. Simulating extreme time skew (>1000 seconds, exceeding default NTP panic limit)
    echo -e "${BLUE}[+] Injecting +3600 seconds offset into system clock...${NC}"
    CURRENT_TS=$(date +%s)
    NEW_TS=$((CURRENT_TS + 3600))
    date -s "@${NEW_TS}" >/dev/null 2>&1 || date 010101002026.00 >/dev/null 2>&1 || true

    # 2. Corrupting NTP Daemon Configurations (Invalid servers, bad stratum, malformed restrict directives)
    if [[ -f /etc/ntp.conf ]]; then
        cat << 'EOF' > /etc/ntp.conf
# CORRUPTED LPI 713.3 LAB CONFIGURATION
driftfile /var/db/ntp/ntp.drift.invalid/nonexistent.drift
server 192.0.2.254 iburst maxpoll 4
server 198.51.100.254 minpoll 4
restrict default ignore
restrict 127.0.0.1 mask 255.0.0.0
EOF
    elif [[ -f /etc/ntpd.conf ]]; then
        cat << 'EOF' > /etc/ntpd.conf
# CORRUPTED OPENNTPD LAB CONFIGURATION
listen on 127.0.0.1
servers 192.0.2.254
sensor *
EOF
    elif [[ -f /etc/chrony/chrony.conf || -f /etc/chrony.conf ]]; [[ -f /etc/chrony/chrony.conf ]] && CHRONY_PATH="/etc/chrony/chrony.conf" || CHRONY_PATH="/etc/chrony.conf"
        cat << 'EOF' > "${CHRONY_PATH}"
# CORRUPTED CHRONY LAB CONFIGURATION
server 192.0.2.254 iburst
driftfile /var/lib/chrony/invalid_path/drift
maxdistance 0.00001
local stratum 16
EOF
    fi

    # 3. Restricting outbound UDP Port 123 (NTP) via local packet filter / iptables if available
    if command -v iptables >/dev/null 2>&1; then
        iptables -A OUTPUT -p udp --dport 123 -j DROP 2>/dev/null || true
    fi

    # 4. Stopping NTP services to simulate failed start due to panic threshold
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop ntp 2>/dev/null || systemctl stop ntpd 2>/dev/null || systemctl stop chrony 2>/dev/null || true
    elif [[ -f /etc/rc.d/ntpd ]]; then
        /etc/rc.d/ntpd stop 2>/dev/null || true
    fi

    echo -e "${RED}[FAILURE] System time maintenance broken successfully.${NC}"
}

print_deep_dive_guide() {
    cat << 'EOF'
===============================================================================
 LPI BSD Specialist (702-100) | Topic 713.3: Maintain System Time
 Production Architecture, Internal Mechanics & Diagnostic Manual
===============================================================================

1. SYSTEM TIME ARCHITECTURE & INTERNAL MECHANICS IN BSD / UNIX
-------------------------------------------------------------------------------
Unix and BSD systems maintain time across two distinct clock layers:

A. Hardware Clock (Real-Time Clock / RTC / CMOS):
   - Battery-backed oscillator on the motherboard operating in UTC or local time.
   - Read during kernel initialization to seed the system clock.
   - In FreeBSD/NetBSD, managed via sysctl `machdep.wall_cmos_clock` and the
     `adjkerntz(8)` utility (which handles local time to UTC adjustments for 
     MS-DOS file compatibility).

B. Kernel System Clock (POSIX Time):
   - Software clock driven by hardware timer interrupts (e.g., HPET, TSC, LAPIC).
   - Counts seconds and nanoseconds since the Unix Epoch (1970-01-01 00:00:00 UTC).
   - Adjusted dynamically by the Phase-Locked Loop (PLL) or Frequency-Locked Loop
     (FLL) inside the kernel via syscalls: `adjtime(2)` and `ntp_adjtime(2)`.

C. Network Time Protocol (NTP) Architecture:
   - Operating Model: Client-Server / Peering over UDP port 123.
   - Stratum Hierarchy:
     * Stratum 0: High-precision atomic clocks, GPS receivers, rubidium standards.
     * Stratum 1: Primary time servers directly attached to Stratum 0 devices.
     * Stratum 2+: Secondary servers synchronizing via network with Stratum N-1.
   - Clock Adjustment Modes:
     * Slewing (`adjtime`): Slowly altering clock frequency (up to 500 ppm or 0.5 ms/s)
       to avoid backward time jumps. Used for small offsets (< 128 ms).
     * Stepping (`settimeofday`): Instantly setting the system clock to accurate time.
       Used when offset is between 128 ms and 1000 s (15 minutes).
     * Panic Threshold: If offset exceeds 1000 seconds, standard `ntpd` aborts
       execution to protect databases/logs from clock corruption, UNLESS configured
       with `-g` (gregarious flag) or step directives.

2. BSD TIME DAEMONS & CONFIGURATION TRADE-OFFS
-------------------------------------------------------------------------------
* Classic ISC `ntpd` (FreeBSD / NetBSD default):
  - Configuration: `/etc/ntp.conf`, Drift file: `/var/db/ntp/ntpd.drift`
  - Control tool: `ntpq -p`, `ntpdate -b`
  - Trade-off: Highly accurate, supports nanosecond precision, complex config,
     susceptible to large codebase vulnerabilities.

* OpenBSD `openntpd` (`ntpd` on OpenBSD):
  - Configuration: `/etc/ntpd.conf`
  - Control tool: `ntpctl -s all`
  - Trade-off: Secure-by-design, privilege separated, simple configuration,
     uses `constraints` over HTTPS to prevent NTP spoofing, but less sub-millisecond tuning.

* `chrony` (`chronyd`):
  - Configuration: `/etc/chrony/chrony.conf`
  - Control tool: `chronyc tracking`, `chronyc sources -v`
  - Trade-off: Fast synchronization on intermittent connections or VMs, excellent
     slew performance, default on modern cloud images.

3. COMMAND CLI EXAMPLES & EXPECTED OUTPUTS
-------------------------------------------------------------------------------
Command 1: Checking NTP Peer Status (Classic ISC ntpd)
$ ntpq -pn
     remote           refid      st t when poll reach   delay   offset  jitter
==============================================================================
*198.51.100.1    203.0.113.5      2 u   42   64  377    12.451   -0.124   0.042
+203.0.113.10    198.51.100.1     3 u   11   64  377    24.891    0.312   0.115

Key Tally Codes:
 '*' = Current synchronized association (sys.peer)
 '+' = Candidate peer (combined in NTP algorithm)
 'x' = Falsticker (rejected by intersection algorithm)
 ' ' = Unreachable or rejected

Command 2: Checking OpenBSD NTP Daemon Status
$ ntpctl -s all
1/1 peers valid, clock is synced, stratum 2
peer 198.51.100.1
        next poll 31s, offset -0.112ms, peer stratum 2

Command 3: Checking System Date and Hardware Clock Sync
$ date -u
Thu Aug  6 20:40:00 UTC 2026

$ sysctl machdep.wall_cmos_clock (FreeBSD)
machdep.wall_cmos_clock: 0

4. OFFICIAL DOCUMENTATION REFERENCES
-------------------------------------------------------------------------------
- LPI BSD Specialist Overview:
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- FreeBSD Handbook - Chapter 30: Network Servers (NTP):
  https://docs.freebsd.org/en/books/handbook/network-servers/#network-ntp
- OpenBSD ntpd.conf(5) Manual Page:
  https://man.openbsd.org/ntpd.conf.5
- NetBSD NTP Configuration Guide:
  https://www.netbsd.org/docs/guide/en/chap-net-services.html#chap-net-services-ntp

===============================================================================
 LAB BREAKDOWN SYMPTOMS & STUDENT OBJECTIVES
===============================================================================

[SYMPTOMS OBSERVED]
1. The system clock is skewed by +1 hour (+3600s), causing SSL/TLS failures,
   Kerberos ticket rejections, and incorrect log timestamps.
2. The NTP service fails to start or exits immediately upon execution.
3. Running `ntpq -p` or `chronyc sources` returns unreachable peers or timeout errors.
4. Firewall policy or invalid configuration parameters are blocking NTP traffic on UDP 123.

[YOUR GOAL]
1. Diagnose why NTP time synchronization is broken.
2. Fix firewall / network accessibility issues for NTP traffic.
3. Correct the NTP configuration file (`/etc/ntp.conf`, `/etc/ntpd.conf`, or `/etc/chrony.conf`).
4. Perform a manual clock step/sync to bring time within acceptable convergence bounds (< 128ms).
5. Verify daemon status and persistence across service restarts.

EOF
}

main() {
    check_root
    backup_configs
    break_system_time
    echo ""
    print_deep_dive_guide
    echo -e "${YELLOW}Laboratory environment broken successfully. Begin troubleshooting!${NC}"
}

main "$@"

# ==============================================================================
# STEP-BY-STEP SOLUTION (STUDENT REFERENCE & VERIFICATION)
# ==============================================================================
# Follow these exact commands to diagnose and resolve the issue:
#
# STEP 1: Diagnose Clock Offset and NTP Daemon Status
#   # Check current system date against true time:
#   date -u
#
#   # Inspect NTP daemon logs for panic threshold errors:
#   tail -n 30 /var/log/messages /var/log/syslog 2>/dev/null | grep -i ntp
#   # Expected Log Output:
#   # ntpd[PID]: time-offset +3600.000000 s exceeds panic threshold (1000); exiting
#
# STEP 2: Inspect and Flush Firewall Rules Blocking UDP Port 123
#   # Check iptables (Linux) or pfctl (BSD):
#   iptables -L -n -v | grep 123
#   # Remove the drop rule for UDP 123:
#   iptables -D OUTPUT -p udp --dport 123 -j DROP 2>/dev/null || true
#   # On FreeBSD/OpenBSD:
#   # pfctl -d   (or edit /etc/pf.conf to allow out proto udp to any port 123)
#
# STEP 3: Repair NTP Configuration File
#   # For Classic ISC ntpd (/etc/ntp.conf):
#   cat << 'EOF_FIX' > /etc/ntp.conf
#   driftfile /var/db/ntp/ntp.drift
#   server 0.pool.ntp.org iburst
#   server 1.pool.ntp.org iburst
#   server 2.pool.ntp.org iburst
#   restrict default kod nomodify nopeer noquery limited limited
#   restrict 127.0.0.1
#   restrict ::1
#   EOF_FIX
#
#   # For OpenBSD ntpd (/etc/ntpd.conf):
#   # cat << 'EOF_FIX' > /etc/ntpd.conf
#   # servers pool.ntp.org
#   # sensor *
#   # constraints from "https://www.google.com"
#   # EOF_FIX
#
#   # For Chrony (/etc/chrony/chrony.conf):
#   # cat << 'EOF_FIX' > /etc/chrony/chrony.conf
#   # pool pool.ntp.org iburst
#   # driftfile /var/lib/chrony/drift
#   # makestep 1.0 3
#   # EOF_FIX
#
# STEP 4: Manually Step System Clock (Bypass 1000s Panic Limit)
#   # Stop daemon if running:
#   systemctl stop ntp 2>/dev/null || systemctl stop chrony 2>/dev/null || /etc/rc.d/ntpd stop 2>/dev/null || true
#
#   # Force one-time time step using ntpdate or ntpd/chronyd one-shot:
#   ntpdate -b 0.pool.ntp.org 2>/dev/null || ntpd -gq 2>/dev/null || chronyd -q 'server pool.ntp.org iburst' 2>/dev/null || date -s "$(curl -sI http://google.com | grep -i '^Date:' | cut -d' ' -f3-)"
#
# STEP 5: Restart Service & Verify Synchronization
#   # Enable and start service:
#   systemctl restart ntp 2>/dev/null || systemctl restart chrony 2>/dev/null || /etc/rc.d/ntpd restart 2>/dev/null || true
#
#   # Verify peers and offset convergence:
#   ntpq -pn
#   # OR for OpenBSD:
#   # ntpctl -s all
#   # OR for Chrony:
#   # chronyc tracking
# ==============================================================================