#!/usr/bin/env bash
# ==============================================================================
# LPI 702: BSD Specialist (Exam 702-100, v1.0)
# Topic 711.3: BSD System Startup Configuration (Weight: 5)
# Lab Type: Break & Fix Scenario
# Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
# WARNING: Run this script only inside a disposable BSD laboratory VM/Environment!
# Requires superuser privileges (root).
# ==============================================================================

set -euo pipefail

# Color formatting
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This lab script must be executed as root.${NC}" >&2
    exit 1
fi

echo -e "${BLUE}====================================================================${NC}"
echo -e "${BLUE}     LPI 702 - Topic 711.3: BSD Startup Break & Fix Laboratory      ${NC}"
echo -e "${BLUE}====================================================================${NC}"

# Backup critical startup configuration files
echo -e "${YELLOW}[*] Creating safe backups of system startup configurations...${NC}"
mkdir -p /var/backups/lpi711_3
cp -p /etc/rc.conf /var/backups/lpi711_3/rc.conf.orig 2>/dev/null || touch /var/backups/lpi711_3/rc.conf.orig
cp -p /boot/loader.conf /var/backups/lpi711_3/loader.conf.orig 2>/dev/null || touch /var/backups/lpi711_3/loader.conf.orig
cp -p /etc/sysctl.conf /var/backups/lpi711_3/sysctl.conf.orig 2>/dev/null || touch /var/backups/lpi711_3/sysctl.conf.orig

# ------------------------------------------------------------------------------
# INJECT BREAKAGE
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[*] Injecting controlled startup configuration flaws...${NC}"

# 1. Breakage: Circular Dependency in rcorder via custom rc.d script
cat << 'EOF' > /usr/local/etc/rc.d/app_telemetry
#!/bin/sh
#
# PROVIDE: app_telemetry
# REQUIRE: NETWORKING SERVERS
# BEFORE: DAEMON
# KEYWORD: shutdown

. /etc/rc.subr

name="app_telemetry"
rcvar="app_telemetry_enable"

load_rc_config $name
: ${app_telemetry_enable:="NO"}

command="/usr/bin/true"

run_rc_command "$1"
EOF
chmod +x /usr/local/etc/rc.d/app_telemetry

# Inject cyclic dependency in rc.d script header: NETWORKING requires app_telemetry, while app_telemetry requires NETWORKING
cat << 'EOF' > /usr/local/etc/rc.d/edge_proxy
#!/bin/sh
#
# PROVIDE: edge_proxy
# REQUIRE: app_telemetry
# BEFORE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="edge_proxy"
rcvar="edge_proxy_enable"

load_rc_config $name
: ${edge_proxy_enable:="YES"}

command="/usr/bin/true"

run_rc_command "$1"
EOF
chmod +x /usr/local/etc/rc.d/edge_proxy

# 2. Breakage: Add malformed override entry in /etc/rc.conf.d/ and syntax anomaly in /etc/rc.conf
mkdir -p /etc/rc.conf.d
cat << 'EOF' > /etc/rc.conf.d/syslogd
# Override directory setting for syslogd
syslogd_enable="YES
syslogd_flags="-s -s"
EOF

# 3. Breakage: Malformed sysctl startup tuning parameter
cat << 'EOF' >> /etc/sysctl.conf
# LPI 711.3 Tuning exercise
kern.maxproc=INVALID_INT_VALUE
net.inet.tcp.sendspace=65536
EOF

# 4. Breakage: Invalid kernel module loading syntax in /boot/loader.conf
cat << 'EOF' >> /boot/loader.conf
# Driver loading configuration
accf_http_load=YES
geom_mirror_load="ENABLE"
EOF

echo -e "${GREEN}[+] System startup break injection completed successfully.${NC}"
echo ""

# ------------------------------------------------------------------------------
# STUDENT LAB BRIEFING
# ------------------------------------------------------------------------------
echo -e "${BLUE}--------------------------------------------------------------------${NC}"
echo -e "${BLUE}                         STUDENT INSTRUCTIONS                       ${NC}"
echo -e "${BLUE}--------------------------------------------------------------------${NC}"
cat << 'INSTRUCTIONS'
SCENARIO & SYMPTOMS:
The FreeBSD/BSD production node experienced a partial failure during boot startup order
evaluation, daemon configuration loading, sysctl applying, and loader module loading.

Observed Issues:
 1. Running 'rcorder /etc/rc.d/* /usr/local/etc/rc.d/*' fails or outputs a circular
    dependency warning (`rcorder: circular dependency`).
 2. Running `service syslogd status` or `service --status-all` throws syntax errors
    related to unclosed quotes in configuration files.
 3. Executing `service sysctl start` (or `sysctl -p`) fails due to malformed variable assignment.
 4. Early boot system kernel loader `/boot/loader.conf` contains non-standard boolean syntax
    for kernel module initialization.

YOUR OBJECTIVES:
 1. Identify and break the circular dependency loop in `/usr/local/etc/rc.d/` using `rcorder(8)`.
    Ensure proper sequence (`PROVIDE`, `REQUIRE`, `BEFORE`).
 2. Locate and repair the syntax error inside the `/etc/rc.conf` or `/etc/rc.conf.d/` tree.
 3. Fix the invalid tuning entry inside `/etc/sysctl.conf`.
 4. Fix the invalid module load value in `/boot/loader.conf`.
 5. Verify system startup integrity with `rcorder`, `service -e`, `sysctl -a`, and `kldstat`.

DIAGNOSTIC COMMANDS TO GET STARTED:
 - rcorder /etc/rc.d/* /usr/local/etc/rc.d/*
 - service -e
 - service syslogd rcvar
 - sysctl -f /etc/sysctl.conf
--------------------------------------------------------------------
INSTRUCTIONS

exit 0

# ==============================================================================
# SOLUTION AND DIAGNOSTIC GUIDE (FOR INSTRUCTORS / REFERENCE)
# ==============================================================================
# To resolve the issues injected by this script, execute the following steps:
#
# STEP 1: Fix the Circular Dependency in rc.d Startup Scripts
# ------------------------------------------------------------------------------
# Symptom Check:
#   # rcorder /etc/rc.d/* /usr/local/etc/rc.d/*
#   Output: rcorder: circular dependency: NETWORKING, app_telemetry, edge_proxy, NETWORKING
#
# Root Cause:
#   `/usr/local/etc/rc.d/edge_proxy` specifies `BEFORE: NETWORKING` while requiring `app_telemetry`,
#   which in turn specifies `REQUIRE: NETWORKING`. This creates a closed loop.
#
# Resolution:
#   Edit `/usr/local/etc/rc.d/edge_proxy` and modify the dependency header block:
#   Change:
#     # REQUIRE: app_telemetry
#     # BEFORE: NETWORKING
#   To:
#     # REQUIRE: NETWORKING
#     # BEFORE: DAEMON
#
# Verification:
#   # rcorder /etc/rc.d/* /usr/local/etc/rc.d/* | grep -E 'edge_proxy|app_telemetry'
#
# STEP 2: Fix Syntax Error in /etc/rc.conf.d/ Overrides
# ------------------------------------------------------------------------------
# Symptom Check:
#   # service syslogd status
#   Output: /etc/rc.conf.d/syslogd: 2: Syntax error: Unterminated quoted string
#
# Root Cause:
#   The file `/etc/rc.conf.d/syslogd` contains an unclosed quote: `syslogd_enable="YES`.
#
# Resolution:
#   Edit `/etc/rc.conf.d/syslogd` and close the string:
#     syslogd_enable="YES"
#     syslogd_flags="-s -s"
#
# Verification:
#   # service syslogd status
#   # service -e
#
# STEP 3: Fix Invalid sysctl Startup Parameter
# ------------------------------------------------------------------------------
# Symptom Check:
#   # sysctl -f /etc/sysctl.conf
#   Output: sysctl: kern.maxproc=INVALID_INT_VALUE: Invalid argument
#
# Root Cause:
#   `/etc/sysctl.conf` assigns a string `INVALID_INT_VALUE` to an integer sysctl node (`kern.maxproc`).
#
# Resolution:
#   Edit `/etc/sysctl.conf` and set a valid integer or remove the line:
#     kern.maxproc=5000
#
# Verification:
#   # sysctl -f /etc/sysctl.conf
#   # sysctl kern.maxproc
#
# STEP 4: Fix Invalid Kernel Module Loader Option in /boot/loader.conf
# ------------------------------------------------------------------------------
# Symptom Check:
#   Reviewing `/boot/loader.conf` reveals `geom_mirror_load="ENABLE"`.
#   The FreeBSD `loader.conf(5)` syntax expects `"YES"` or `"1"` for boolean options, not `"ENABLE"`.
#
# Resolution:
#   Edit `/boot/loader.conf`:
#   Change:
#     geom_mirror_load="ENABLE"
#   To:
#     geom_mirror_load="YES"
#
# Verification:
#   Check configuration correctness using `kldload` dry-checks or reading `loader.conf(5)` rules.
# ==============================================================================