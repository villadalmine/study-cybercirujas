#!/usr/bin/env bash
# ==============================================================================
# LPI-702 BSD Specialist (Exam 702-100 v1.0)
# Topic 714.4: Configure Client Side DNS (Weight: 3.33)
# 
# Author: Principal Platform Architect & Senior SRE Instructor
# Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# Manpages: https://man.freebsd.org/cgi/man.cgi?query=nsswitch.conf
#           https://man.freebsd.org/cgi/man.cgi?query=resolv.conf
#           https://man.freebsd.org/cgi/man.cgi?query=dhclient.conf
# ==============================================================================
# PRODUCTION BREAK & FIX LAB ENVIRONMENT
# This script safely introduces 3 real-world production client-side DNS failure
# modes on a BSD/POSIX test system. It tests your deep knowledge of libc host
# resolution, nsswitch syntax engine, resolv.conf parser behavior, and dhclient/
# resolvconf state synchronization.
# ==============================================================================

set -euo pipefail

# Color Palette for Terminal Formatting
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

BACKUP_DIR="/var/tmp/lpi702_dns_backup"

# Ensure execution as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This lab script must be run as root to alter system network configuration.${NC}" >&2
    exit 1
fi

usage() {
    cat << EOF
${BOLD}LPI-702 Topic 714.4: Configure Client Side DNS - Break & Fix Lab CLI${NC}

${CYAN}Usage:${NC}
  sudo $0 --break     Inject production DNS failures into the local environment.
  sudo $0 --status    Display current DNS configuration state and diagnostic tests.
  sudo $0 --restore   Restore original DNS configuration files from pre-break backup.
  sudo $0 --help      Show this help interface.

EOF
}

explain_architecture() {
    cat << 'EOF'
==============================================================================
 ARCHITECTURAL DEEP-DIVE: BSD CLIENT-SIDE RESOLUTION PIPELINE
==============================================================================

 In BSD operating systems (FreeBSD, OpenBSD, NetBSD), application hostname
 resolution follows a multi-tiered POSIX libc pipeline:

   [ Application Call: getaddrinfo() / gethostbyname() ]
                          │
                          ▼
           [ /etc/nsswitch.conf Engine ]
  (Evaluates sources: files -> dns -> cache in defined sequence)
                          │
            ┌─────────────┴─────────────┐
            ▼                           ▼
    [ Source 1: files ]         [ Source 2: dns ]
    (/etc/hosts local map)      (libc resolver query)
                                        │
                                        ▼
                              [ /etc/resolv.conf ]
                       - nameserver (Upstream IP)
                       - search / domain (Suffixes)
                       - options (ndots, timeout, attempts)
                                        │
                                        ▼
                            [ Local Caching Daemon ]
                          (unbound / local-unbound)
                                        │
                                        ▼
                            [ Interface Manager ]
                          (dhclient / resolvconf)

 KEY TECHNICAL MECHANICS FOR LPI-702:
 -----------------------------------
 1. /etc/nsswitch.conf Control Criteria:
    - Syntax: `hosts: files dns`
    - Criteria Actions: `[STATUS=action]`, where STATUS can be SUCCESS, NOTFOUND,
      UNAVAIL, or TRYAGAIN. Action can be `return` or `continue`.
    - DANGER: `hosts: dns [NOTFOUND=return] files` instructs libc to abort 
      resolution immediately if DNS returns NXDOMAIN, bypassing /etc/hosts!

 2. /etc/resolv.conf Parser Directives:
    - `nameserver`: IP address of DNS server (max 3 nameservers evaluated).
    - `search`: Search list for host-name lookup (max 6 domains, total 256 chars).
    - `ndots:n`: Threshold for number of dots in a query name before an absolute
      lookup is attempted first (Default: 1). Setting ndots:5 forces local domain
      suffix concatenation on almost all external domain queries, multiplying latency.

 3. DHCP & Interface Overwrite Management:
    - `dhclient` and `resolvconf` regenerate `/etc/resolv.conf` on lease renewal.
    - Configuration in `/etc/dhclient.conf` using `supersede` or `prepend` controls
      how dhclient populates nameservers and search paths.

==============================================================================
EOF
}

backup_system() {
    mkdir -p "${BACKUP_DIR}"
    if [[ ! -f "${BACKUP_DIR}/resolv.conf.orig" && -f /etc/resolv.conf ]]; then
        cp -p /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.orig"
    fi
    if [[ ! -f "${BACKUP_DIR}/nsswitch.conf.orig" && -f /etc/nsswitch.conf ]]; then
        cp -p /etc/nsswitch.conf "${BACKUP_DIR}/nsswitch.conf.orig"
    fi
    if [[ ! -f "${BACKUP_DIR}/hosts.orig" && -f /etc/hosts ]]; then
        cp -p /etc/hosts "${BACKUP_DIR}/hosts.orig"
    fi
    if [[ ! -f "${BACKUP_DIR}/dhclient.conf.orig" && -f /etc/dhclient.conf ]]; then
        cp -p /etc/dhclient.conf "${BACKUP_DIR}/dhclient.conf.orig"
    elif [[ ! -f "${BACKUP_DIR}/dhclient.conf.orig" ]]; then
        touch "${BACKUP_DIR}/dhclient.conf.orig"
    fi
}

inject_breakage() {
    backup_system
    echo -e "${YELLOW}[+] Injecting controlled failure modes into client-side DNS configuration...${NC}"

    # 1. Inject local host static entry for testing
    if ! grep -q "production-db.internal.local" /etc/hosts; then
        echo "127.0.0.50 production-db.internal.local" >> /etc/hosts
    fi

    # 2. Break /etc/nsswitch.conf:
    # Set hosts resolution order to consult DNS first, and RETURN (abort) on NOTFOUND.
    # This prevents libc from ever reaching /etc/hosts if DNS returns NXDOMAIN.
    if [[ -f /etc/nsswitch.conf ]]; then
        sed -i.bak -E 's/^hosts:.*/hosts: dns [NOTFOUND=return] files/' /etc/nsswitch.conf
    else
        echo "hosts: dns [NOTFOUND=return] files" > /etc/nsswitch.conf
    fi

    # 3. Break /etc/resolv.conf:
    # Point nameserver to non-routable RFC 5737 TEST-NET-1 IP (192.0.2.53),
    # set extreme ndots:5, and set 1-second timeout.
    cat << 'EOF' > /etc/resolv.conf
# Corrupted by LPI-702 Break & Fix Lab
nameserver 192.0.2.53
nameserver 198.51.100.53
search invalid.local sub.invalid.local broken.test
options timeout:1 attempts:1 ndots:5
EOF

    # 4. Break /etc/dhclient.conf persistence:
    # Ensure that any network interface update or dhclient trigger will re-inject bad DNS servers.
    cat << 'EOF' >> /etc/dhclient.conf
# Added by LPI-702 Break & Fix Lab
prepend domain-name-servers 192.0.2.53;
prepend domain-search "invalid.local";
EOF

    echo -e "${GREEN}[✔] Breakage injected successfully!${NC}\n"
    print_lab_incident
}

print_lab_incident() {
    explain_architecture
    cat << EOF
${RED}${BOLD}==============================================================================
 INCIDENT REPORT: CLIENT-SIDE DNS RESOLUTION OUTAGE DETECTED
==============================================================================${NC}

${BOLD}SITUATION OVERVIEW:${NC}
 You are an SRE on call. Application services report that all outbound API calls 
 and local microservice lookups are failing or timing out. A junior admin 
 attempted to tweak network settings on this BSD node, causing severe DNS degradation.

${BOLD}REPORTED SYMPTOMS:${NC}
 1. Local resolution for internal static mapping '${CYAN}production-db.internal.local${NC}' 
    fails to resolve via standard system lookups (${CYAN}getent hosts${NC}), even though 
    the entry exists in ${CYAN}/etc/hosts${NC}.
 2. External domain resolution (e.g., '${CYAN}host lpi.org${NC}' or '${CYAN}drill lpi.org${NC}') 
    hangs and times out.
 3. Standard DNS resolution tools bypass local hosts files and attempt resolution 
    against unreachable IP addresses (${CYAN}192.0.2.53${NC}).
 4. Manual edits to ${CYAN}/etc/resolv.conf${NC} are overwritten whenever interface events 
    or ${CYAN}dhclient${NC} / ${CYAN}resolvconf${NC} update routines run.

${BOLD}DIAGNOSTIC TEST COMMANDS TO EXECUTE:${NC}
  a) ${YELLOW}getent hosts production-db.internal.local${YELLOW}${NC}
     Expected behavior when broken: Returns NOTHING (fails silently or errors).
  b) ${YELLOW}host -v lpi.org${NC} or ${YELLOW}drill -v lpi.org${NC}
     Expected behavior when broken: Attempts query against 192.0.2.53 and times out.
  c) ${YELLOW}cat /etc/nsswitch.conf | grep hosts:${NC}
     Expected behavior when broken: Shows 'hosts: dns [NOTFOUND=return] files'

${BOLD}YOUR OBJECTIVES TO RESOLVE THE INCIDENT:${NC}
 [ ] 1. Correct ${CYAN}/etc/nsswitch.conf${NC} so local static files (/etc/hosts) are prioritized 
        and failure status criteria do not prematurely block file evaluation.
 [ ] 2. Reconfigure ${CYAN}/etc/resolv.conf${NC} with valid upstream resolvers (e.g., 1.1.1.1, 8.8.8.8), 
        sane options (e.g., ${CYAN}timeout:2 attempts:2 ndots:1${NC}), and appropriate search suffixes.
 [ ] 3. Fix ${CYAN}/etc/dhclient.conf${NC} to prevent DHCP client renewals from prepending invalid 
        resolvers or breaking resolv.conf on reboot/lease renewal.
 [ ] 4. Verify system host lookup behavior using ${CYAN}getent hosts${NC}, ${CYAN}host${NC}, and ${CYAN}drill${NC}.

==============================================================================
EOF
}

check_status() {
    echo -e "${BOLD}--- Current Client-Side DNS Diagnostic Status ---${NC}"
    
    echo -n "1. /etc/nsswitch.conf hosts line: "
    if grep -E "^hosts:" /etc/nsswitch.conf 2>/dev/null; then
        :
    else
        echo "NOT CONFIGURED"
    fi

    echo -e "\n2. /etc/resolv.conf contents:"
    cat /etc/resolv.conf 2>/dev/null || echo "MISSING"

    echo -e "\n3. Testing resolution for local host 'production-db.internal.local':"
    if getent hosts production-db.internal.local >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS] Local host resolved: $(getent hosts production-db.internal.local)${NC}"
    else
        echo -e "${RED}[FAIL] Could not resolve production-db.internal.local via libc${NC}"
    fi

    echo -e "\n4. Testing resolution for external domain 'lpi.org':"
    if host -t A lpi.org >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS] External host lpi.org resolved successfully.${NC}"
    else
        echo -e "${RED}[FAIL] External lookup for lpi.org failed or timed out.${NC}"
    fi
}

restore_system() {
    echo -e "${YELLOW}[+] Restoring pre-lab DNS configuration...${NC}"
    if [[ -f "${BACKUP_DIR}/resolv.conf.orig" ]]; then
        cp -p "${BACKUP_DIR}/resolv.conf.orig" /etc/resolv.conf
    fi
    if [[ -f "${BACKUP_DIR}/nsswitch.conf.orig" ]]; then
        cp -p "${BACKUP_DIR}/nsswitch.conf.orig" /etc/nsswitch.conf
    fi
    if [[ -f "${BACKUP_DIR}/hosts.orig" ]]; then
        cp -p "${BACKUP_DIR}/hosts.orig" /etc/hosts
    fi
    if [[ -f "${BACKUP_DIR}/dhclient.conf.orig" ]]; then
        cp -p "${BACKUP_DIR}/dhclient.conf.orig" /etc/dhclient.conf
    fi
    sed -i '/production-db.internal.local/d' /etc/hosts 2>/dev/null || true
    echo -e "${GREEN}[✔] System state restored successfully.${NC}"
}

# Process Command Line Flags
if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

case "$1" in
    --break)
        inject_breakage
        ;;
    --status)
        check_status
        ;;
    --restore)
        restore_system
        ;;
    --help|-h)
        usage
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}" >&2
        usage
        exit 1
        ;;
esac

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION GUIDE (LPI-702 TOPIC 714.4)
# ==============================================================================
# Read this section to understand how to diagnose and permanently resolve the lab.
#
# ------------------------------------------------------------------------------
# STEP 1: DIAGNOSE NSSWITCH ORDER AND CRITERIA ACTIONS
# ------------------------------------------------------------------------------
# Check how libc processes name queries:
#   $ cat /etc/nsswitch.conf | grep hosts:
#   Output: hosts: dns [NOTFOUND=return] files
#
# Root Cause: The directive `[NOTFOUND=return]` immediately following `dns` tells
# libc: "If the DNS server answers with NOTFOUND (NXDOMAIN), stop processing 
# immediately and return failure to the calling program." Consequently, local entries 
# in /etc/hosts are never queried!
#
# FIX: Edit /etc/nsswitch.conf and restore standard BSD resolution order where local 
# files are checked first, followed by DNS:
#
#   hosts: files dns
#
# Or, if DNS must be checked first, use default continuation logic:
#
#   hosts: dns files
#
# ------------------------------------------------------------------------------
# STEP 2: FIX RESOLV.CONF NAMESERVERS, OPTIONS, AND SEARCH PATHS
# ------------------------------------------------------------------------------
# Inspect /etc/resolv.conf:
#   $ cat /etc/resolv.conf
#   nameserver 192.0.2.53
#   options timeout:1 attempts:1 ndots:5
#
# Root Cause:
# 1. 192.0.2.53 is a non-routable documentation IP (RFC 5737). Queries blackhole.
# 2. `ndots:5` forces any domain name containing fewer than 5 dots (e.g. `lpi.org` 
#    has only 1 dot) to first be queried with all search domains appended! This 
#    generates up to 6 invalid queries before trying `lpi.org.` directly.
#
# FIX: Edit /etc/resolv.conf with production-grade syntax:
#
#   # /etc/resolv.conf - LPI-702 Compliant Production Configuration
#   search internal.domain
#   nameserver 1.1.1.1
#   nameserver 8.8.8.8
#   options timeout:2 attempts:2 ndots:1 edns0
#
# ------------------------------------------------------------------------------
# STEP 3: PREVENT DHCLIENT / RESOLVCONF FROM OVERWRITING RESOLV.CONF
# ------------------------------------------------------------------------------
# Inspect /etc/dhclient.conf:
#   $ cat /etc/dhclient.conf
#   prepend domain-name-servers 192.0.2.53;
#
# Root Cause: dhclient prepends 192.0.2.53 to /etc/resolv.conf every time an interface
# receives a DHCP lease renew event.
#
# FIX: Remove the invalid `prepend` directives from /etc/dhclient.conf and use 
# `supersede` to enforce static DNS servers regardless of DHCP offers:
#
#   # /etc/dhclient.conf
#   supersede domain-name-servers 1.1.1.1, 8.8.8.8;
#   supersede domain-name "internal.domain";
#
# ------------------------------------------------------------------------------
# STEP 4: VERIFY COMPLETE RESOLUTION PIPELINE
# ------------------------------------------------------------------------------
# Run empirical verification commands:
#
# 1. Verify static local host lookup:
#   $ getent hosts production-db.internal.local
#   Expected output: 127.0.0.50 production-db.internal.local
#
# 2. Verify external query with BSD drill tool:
#   $ drill lpi.org @1.1.1.1
#   $ drill lpi.org
#   Expected output: NOERROR status with valid A record.
#
# 3. Verify system host tool lookup:
#   $ host lpi.org
#   Expected output: lpi.org has address 198.51.100.1
#
# 4. Verify DHCP client integration by triggering resolvconf / dhclient:
#   $ resolvconf -u
#   $ cat /etc/resolv.conf  (Ensure valid nameservers persist)
# ==============================================================================