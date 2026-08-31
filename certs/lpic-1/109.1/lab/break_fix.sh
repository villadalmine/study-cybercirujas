#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (Exam 102-500) -- Topic 109.1: Fundamentals of internet protocols
#  BREAK & FIX LABORATORY  --  break-109-1-internet-protocols.sh
# =============================================================================
#
#  WARNING: THIS SCRIPT INTENTIONALLY BREAKS NETWORKING ON THIS MACHINE.
#           RUN IT ONLY ON A DISPOSABLE LABORATORY VM TO WHICH YOU HAVE
#           CONSOLE ACCESS (virt-manager / VirtualBox console / Proxmox
#           noVNC / cloud serial console). DO NOT RUN IT OVER SSH ON A
#           MACHINE YOU CANNOT REACH BY CONSOLE: ONE OF THE FAULTS
#           DELIBERATELY REMOVES YOUR DEFAULT ROUTE.
#
#  Scope of the objective being exercised (LPI 102-500, objective 109.1,
#  weight 4):
#    * Demonstrate an understanding of network masks and CIDR notation
#    * Knowledge of the differences between private and public "dotted quad"
#      IP addresses
#    * Knowledge about common TCP and UDP ports and services (20, 21, 22, 23,
#      25, 53, 80, 110, 123, 139, 143, 161, 162, 389, 443, 465, 514, 636,
#      993, 995)
#    * Knowledge about the differences and major features of UDP, TCP and ICMP
#    * Knowledge of the major differences between IPv4 and IPv6
#    * Knowledge of the basic features of IPv6
#
#  Reference (official, authoritative):
#    LPI Exam 102-500 objectives -- https://www.lpi.org/our-certifications/exam-102-objectives/
#    LPI certification catalogue  -- https://www.lpi.org/our-certifications/exam-101-objectives/
#    RFC 1918 (private IPv4 space) -- https://www.rfc-editor.org/rfc/rfc1918
#    RFC 4291 (IPv6 addressing)    -- https://www.rfc-editor.org/rfc/rfc4291
#    RFC 4193 (IPv6 ULA)           -- https://www.rfc-editor.org/rfc/rfc4193
#    IANA service name / port registry --
#      https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml
#    ip(8) / ip-route(8)           -- https://man7.org/linux/man-pages/man8/ip-route.8.html
#    nsswitch.conf(5)              -- https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
#    resolv.conf(5)                -- https://man7.org/linux/man-pages/man5/resolv.conf.5.html
#    services(5)                   -- https://man7.org/linux/man-pages/man5/services.5.html
#    ip-sysctl.txt (kernel)        -- https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt
#
#  DESIGN OF THIS LAB
#  ------------------
#  Five independent faults are injected, each one mapping to a different
#  bullet of objective 109.1. They are deliberately layered so that the
#  student must reason about the protocol stack bottom-up instead of
#  guessing:
#
#     FAULT 1  layer 3, addressing   -- wrong netmask / CIDR prefix
#     FAULT 2  layer 3, forwarding   -- default route removed
#     FAULT 3  layer 3.5, ICMP       -- kernel drops all ICMP echo requests
#     FAULT 4  layer 7, name service -- resolver pointed at a black hole
#     FAULT 5  layer 4, port naming  -- /etc/services entries corrupted
#
#  Every change is made through a normal, documented interface (ip(8),
#  sysctl(8), plain text config files). Nothing is hidden, nothing is
#  obfuscated with a kernel module or an out-of-tree binary, and every
#  original value is saved under the snapshot directory so the fix is
#  always reversible even if the student gives up.
#
#  USAGE
#  -----
#     sudo ./break-109-1-internet-protocols.sh break     # inject the faults
#     sudo ./break-109-1-internet-protocols.sh status    # show the symptoms
#     sudo ./break-109-1-internet-protocols.sh hint      # progressive hints
#     sudo ./break-109-1-internet-protocols.sh verify    # grade the repair
#     sudo ./break-109-1-internet-protocols.sh restore   # give up, undo all
#
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Constants and global state
# -----------------------------------------------------------------------------

readonly LAB_ID="lpic1-109.1"
readonly LAB_DIR="/var/tmp/${LAB_ID}"
readonly SNAP_DIR="${LAB_DIR}/snapshot"
readonly STATE_FILE="${LAB_DIR}/state.env"
readonly BRIEF_FILE="${LAB_DIR}/BRIEFING.txt"
readonly MARKER="# ${LAB_ID} lab marker -- do not ship to production"

# The black-hole resolver. 203.0.113.0/24 is TEST-NET-3 (RFC 5737), reserved
# for documentation and guaranteed never to be routed on the public Internet,
# so pointing the resolver here produces a clean timeout rather than leaking
# the student's queries to a third party.
readonly BLACKHOLE_DNS="203.0.113.53"

# The wrong prefix we will impose on the primary interface. A /30 leaves the
# host with exactly two usable addresses, so any gateway outside that pair
# becomes unreachable at layer 3 -- the classic "netmask typo" outage.
readonly WRONG_PREFIX=30

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'

log()  { printf '%s[ lab ]%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
die()  { printf '%s[fail]%s %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; exit 1; }
ok()   { printf '%s[ ok ]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
rule() { printf '%s\n' "-----------------------------------------------------------------------"; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "This script must run as root. Try: sudo $0 $*"
}

# Refuse to run anywhere that looks like it might matter. This is a heuristic,
# not a security control -- it exists so that a distracted student does not
# nuke their workstation, not to stop a determined one.
guard_disposable_host() {
  local reason=""
  if [[ -f /etc/lab-vm-ok ]]; then
    return 0
  fi
  if systemctl is-active --quiet kubelet 2>/dev/null; then
    reason="a kubelet is running (this looks like a cluster node)"
  elif [[ -d /var/lib/etcd ]]; then
    reason="/var/lib/etcd exists (this looks like a control plane)"
  elif [[ -n "${SSH_CONNECTION:-}" && ! -e /dev/console ]]; then
    reason="you are on SSH and no console device is visible"
  fi
  if [[ -n ${reason} ]]; then
    warn "Refusing to break this host: ${reason}."
    warn "If this really is a throwaway lab VM, run:  touch /etc/lab-vm-ok"
    die  "Aborted for safety."
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn "You appear to be connected over SSH (${SSH_CONNECTION%% *} -> this host)."
    warn "FAULT 2 removes the default route. If your SSH client is NOT on the"
    warn "same subnet as this VM, your session will freeze and you will need"
    warn "the hypervisor console to finish the lab."
    printf 'Type EXACTLY "i have console access" to continue: '
    local answer; IFS= read -r answer
    [[ ${answer} == "i have console access" ]] || die "Aborted by user."
  fi
}

# Discover the interface that currently carries the default route. Everything
# else in the lab hangs off this. We resolve it once and persist it, because
# after FAULT 2 the default route no longer exists to be queried.
detect_primary_iface() {
  local iface
  iface="$(ip -4 -oneline route show default 2>/dev/null | awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' | head -n1)"
  if [[ -z ${iface} ]]; then
    iface="$(ip -4 -oneline addr show scope global up 2>/dev/null | awk '$2 != "lo" { print $2; exit }')"
  fi
  [[ -n ${iface} ]] || die "No usable IPv4 interface found. Give this VM a network first."
  printf '%s\n' "${iface}"
}

save_state() {
  umask 022
  mkdir -p "${SNAP_DIR}"
  cat > "${STATE_FILE}" <<-EOF
	# Autogenerated by ${LAB_ID}. Do not edit by hand.
	LAB_IFACE='${LAB_IFACE}'
	LAB_ADDR='${LAB_ADDR}'
	LAB_PREFIX='${LAB_PREFIX}'
	LAB_GATEWAY='${LAB_GATEWAY}'
	LAB_BROKEN_AT='${LAB_BROKEN_AT}'
	EOF
}

load_state() {
  [[ -r ${STATE_FILE} ]] || die "No lab state found at ${STATE_FILE}. Run '$0 break' first."
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

# Copy a file into the snapshot directory, preserving mode and ownership, but
# never overwrite an existing snapshot -- 'break' must be idempotent, and the
# first snapshot is the only pristine one.
snapshot_file() {
  local src="$1"
  local dst="${SNAP_DIR}/$(printf '%s' "${src}" | tr '/' '_')"
  mkdir -p "${SNAP_DIR}"
  if [[ -e ${dst} ]]; then
    return 0
  fi
  if [[ -e ${src} ]]; then
    cp --archive --dereference "${src}" "${dst}"
  else
    : > "${dst}.ABSENT"
  fi
}

restore_file() {
  local src="$1"
  local dst="${SNAP_DIR}/$(printf '%s' "${src}" | tr '/' '_')"
  if [[ -e "${dst}.ABSENT" ]]; then
    rm -f "${src}"
  elif [[ -e ${dst} ]]; then
    cp --archive --force "${dst}" "${src}"
  fi
}

# -----------------------------------------------------------------------------
# FAULT INJECTORS
# -----------------------------------------------------------------------------

# FAULT 1 -- Network mask / CIDR notation.
#
# Objective bullet: "Demonstrate an understanding of network masks and CIDR
# notation."
#
# Mechanics: an IPv4 interface address carries a prefix length. The kernel
# derives from it the on-link (directly connected) route that is installed
# automatically in the main routing table with proto kernel scope link. Narrow
# the prefix and that connected route shrinks; any address outside the new,
# smaller network -- typically the default gateway -- is no longer considered
# reachable without a router, and the kernel answers with EHOSTUNREACH /
# ENETUNREACH before a single packet is ever put on the wire.
inject_fault_addressing() {
  log "FAULT 1: replacing ${LAB_ADDR}/${LAB_PREFIX} with ${LAB_ADDR}/${WRONG_PREFIX} on ${LAB_IFACE}"
  ip -4 addr flush dev "${LAB_IFACE}" 2>/dev/null || true
  ip -4 addr add "${LAB_ADDR}/${WRONG_PREFIX}" dev "${LAB_IFACE}"
  ip link set dev "${LAB_IFACE}" up
}

# FAULT 2 -- Routing / default gateway.
#
# Objective bullet: routing is the practical consequence of understanding
# masks and of the public/private address distinction. With no default route,
# an RFC 1918 host can still reach its own subnet but nothing beyond it.
#
# Mechanics: the kernel FIB is consulted longest-prefix-first. 0.0.0.0/0 is
# the least specific entry and the last resort. Delete it and any destination
# not covered by a connected or a more specific route fails immediately with
# "Network is unreachable" -- note the distinction from a timeout, which would
# indicate the packet did leave and nothing answered.
inject_fault_routing() {
  log "FAULT 2: deleting the IPv4 default route (was via ${LAB_GATEWAY})"
  while ip -4 route show default | grep -q .; do
    ip -4 route del default || break
  done
}

# FAULT 3 -- ICMP.
#
# Objective bullet: "Knowledge about the differences and major features of
# UDP, TCP and ICMP."
#
# Mechanics: net.ipv4.icmp_echo_ignore_all makes the kernel silently discard
# every incoming ICMP Echo Request (type 8) without generating an Echo Reply
# (type 0). This is a favourite production foot-gun: ping to the host fails
# while TCP services on the same host answer perfectly, which is exactly the
# lesson -- ICMP is a separate IP protocol number (1), not "a kind of TCP",
# and its reachability says nothing about layer 4 reachability.
inject_fault_icmp() {
  log "FAULT 3: enabling net.ipv4.icmp_echo_ignore_all (host stops replying to ping)"
  snapshot_file /etc/sysctl.d/99-lab-icmp.conf
  cat > /etc/sysctl.d/99-lab-icmp.conf <<-EOF
	${MARKER}
	net.ipv4.icmp_echo_ignore_all = 1
	EOF
  sysctl --quiet --write net.ipv4.icmp_echo_ignore_all=1
}

# FAULT 4 -- Name resolution.
#
# Objective bullet: DNS is the canonical UDP/53 (and TCP/53) service; this
# fault forces the student to separate "the network is down" from "the name
# service is down", the single most common misdiagnosis in the field.
#
# Mechanics: glibc's stub resolver reads /etc/resolv.conf. Pointing it at an
# address in TEST-NET-3 (RFC 5737) yields no answer at all, so every lookup
# burns the full timeout (5 s) times attempts (2) before failing. On systemd
# hosts /etc/resolv.conf is frequently a symlink into /run/systemd/resolve/;
# we replace the symlink with a regular file so the fault is visible and
# self-contained, and the snapshot remembers that it used to be a symlink.
inject_fault_dns() {
  log "FAULT 4: pointing the stub resolver at the black hole ${BLACKHOLE_DNS} (TEST-NET-3)"
  snapshot_file /etc/resolv.conf
  if [[ -L /etc/resolv.conf ]]; then
    readlink /etc/resolv.conf > "${SNAP_DIR}/resolv.conf.symlink_target"
    rm -f /etc/resolv.conf
  fi
  cat > /etc/resolv.conf <<-EOF
	${MARKER}
	nameserver ${BLACKHOLE_DNS}
	options timeout:5 attempts:2
	EOF
}

# FAULT 5 -- Well-known ports and service names.
#
# Objective bullet: "Knowledge about common TCP and UDP ports and services."
#
# Mechanics: /etc/services is the local copy of the IANA registry consulted by
# getservbyname(3)/getservbyport(3). Tools that print names instead of numbers
# -- ss -tulpn without --numeric, netstat, nmap's service column, lsof -i --
# all read it. Corrupting three high-profile entries (ssh, https, domain)
# produces output that is subtly, confusingly wrong while the actual sockets
# are untouched: nothing on the wire has changed, only the human-readable
# label. The lesson is that a service NAME is a local lookup, never a
# guarantee of what is listening.
inject_fault_services() {
  log "FAULT 5: corrupting well-known port entries in /etc/services"
  snapshot_file /etc/services
  # ssh 22 -> 2222, https 443 -> 4443, domain 53 -> 5353. sed is applied only
  # to the canonical lines so the rest of the file stays byte-identical.
  sed --in-place \
      -e 's|^ssh[[:space:]]\+22/tcp|ssh\t\t2222/tcp|' \
      -e 's|^ssh[[:space:]]\+22/udp|ssh\t\t2222/udp|' \
      -e 's|^https[[:space:]]\+443/tcp|https\t\t4443/tcp|' \
      -e 's|^https[[:space:]]\+443/udp|https\t\t4443/udp|' \
      -e 's|^domain[[:space:]]\+53/tcp|domain\t\t5353/tcp|' \
      -e 's|^domain[[:space:]]\+53/udp|domain\t\t5353/udp|' \
      /etc/services
  printf '%s\n' "${MARKER}" >> /etc/services
}

# -----------------------------------------------------------------------------
# BRIEFING -- what the student is told
# -----------------------------------------------------------------------------

write_briefing() {
  cat > "${BRIEF_FILE}" <<-EOF
	=======================================================================
	 LPIC-1 102-500 -- Objective 109.1  Fundamentals of internet protocols
	 BREAK & FIX SCENARIO                          lab id: ${LAB_ID}
	=======================================================================

	 THE TICKET (as it would arrive from a user)

	   "Nothing works. I can't ping the server, the server can't ping
	    anything either, apt/dnf just hangs forever, and when I ran
	    'ss -tulpn' the port numbers next to sshd looked wrong to me.
	    It worked yesterday."

	 WHAT WAS DONE TO THIS VM

	   Five independent faults were injected. All of them live in normal,
	   documented places: interface configuration, the routing table, a
	   kernel sysctl, and two plain-text files under /etc. No binaries were
	   replaced, no kernel module was loaded, no firewall rule was added,
	   and nothing was hidden. Everything can be found with the standard
	   tools listed below.

	   Baseline that was captured BEFORE the damage (you will need it):

	     interface : ${LAB_IFACE}
	     address   : ${LAB_ADDR}
	     prefix    : /${LAB_PREFIX}   (correct value)
	     gateway   : ${LAB_GATEWAY}

	 SYMPTOMS YOU SHOULD OBSERVE

	   S1. 'ping ${LAB_GATEWAY}' fails INSTANTLY with
	         "connect: Network is unreachable"
	       -- not a timeout. An instant failure means the local kernel
	       refused to send: this is a routing/addressing problem, not a
	       remote one.

	   S2. 'ip -4 addr show ${LAB_IFACE}' shows a prefix that does not match
	       the size of the LAN this VM is plugged into.

	   S3. 'ip -4 route show' has no line starting with 'default'.

	   S4. Another machine on the LAN pings this VM and gets 100% packet
	       loss, YET it can still open a TCP connection to this VM's sshd.
	       Ping failing while TCP succeeds is a specific, diagnosable state.

	   S5. 'getent hosts www.lpi.org' hangs for ~10 seconds and returns
	       nothing, while 'getent hosts <a literal IPv4 address>' answers
	       immediately.

	   S6. 'ss -tulpn' (or 'netstat -tulp') shows sshd bound to a port whose
	       NAME does not correspond to the port your client is actually
	       connecting to.

	 WHAT YOU MUST ACHIEVE

	   G1. The interface carries the correct address AND the correct CIDR
	       prefix, and the kernel has re-installed the matching connected
	       route (proto kernel, scope link).
	   G2. A working IPv4 default route exists via ${LAB_GATEWAY}.
	   G3. This host replies to ICMP Echo Requests again, and the change
	       survives a reboot (a runtime-only fix is only half a fix).
	   G4. Forward DNS resolution works: 'getent hosts www.lpi.org' returns
	       an address in under a second.
	   G5. /etc/services maps ssh->22/tcp, https->443/tcp and domain->53
	       (tcp and udp) exactly as the IANA registry does.

	 TOOLS THAT ARE ENOUGH TO SOLVE THIS (no others are needed)

	   ip addr / ip route / ip -brief addr        addressing and forwarding
	   ipcalc  or  sipcalc                        prefix arithmetic
	   sysctl -a | grep icmp                      kernel ICMP behaviour
	   ping / ping -c / traceroute / tracepath    reachability, path
	   ss -tulpn / ss -tulp                       listening sockets
	   dig +short / host / getent hosts           name resolution paths
	   grep on /etc/resolv.conf /etc/nsswitch.conf /etc/services
	   journalctl -u systemd-resolved (if present)

	 REFLECTION QUESTIONS (answer them before you look at the solution)

	   Q1. Why does a WRONG NETMASK break the default gateway even when the
	       gateway's address itself is typed correctly?
	   Q2. What is the exact difference between
	         "connect: Network is unreachable"
	         "Destination Host Unreachable"
	         100% packet loss with no message
	       and which layer does each one implicate?
	   Q3. Your host does not answer ping but serves HTTPS fine. Name two
	       distinct causes and the command that distinguishes them.
	   Q4. Why is UDP the default transport for DNS, and what specifically
	       makes a resolver fall back to TCP/53?
	   Q5. This VM has an RFC 1918 address. Explain why that address can
	       never appear as the source address of a packet arriving at
	       www.lpi.org, and what mechanism rewrites it.
	   Q6. Write the IPv6 equivalent of each command you used. Which
	       concepts (ARP, broadcast, fragmentation by routers) have no IPv6
	       counterpart, and what replaced them?

	 COMMANDS FOR THIS LAB

	   sudo $0 status    show a symptom report
	   sudo $0 hint      progressive hints (one more each time you run it)
	   sudo $0 verify    grade your repair, G1..G5
	   sudo $0 restore   give up and undo everything

	=======================================================================
	EOF
  cat "${BRIEF_FILE}"
}

# -----------------------------------------------------------------------------
# ACTIONS
# -----------------------------------------------------------------------------

action_break() {
  guard_disposable_host

  LAB_IFACE="$(detect_primary_iface)"
  LAB_ADDR="$(ip -4 -oneline addr show dev "${LAB_IFACE}" scope global | awk '{ split($4, a, "/"); print a[1]; exit }')"
  LAB_PREFIX="$(ip -4 -oneline addr show dev "${LAB_IFACE}" scope global | awk '{ split($4, a, "/"); print a[2]; exit }')"
  LAB_GATEWAY="$(ip -4 -oneline route show default | awk '{ for (i=1;i<=NF;i++) if ($i=="via") { print $(i+1); exit } }' | head -n1)"
  LAB_BROKEN_AT="$(date --iso-8601=seconds)"

  [[ -n ${LAB_ADDR}   ]] || die "Could not read an IPv4 address from ${LAB_IFACE}."
  [[ -n ${LAB_PREFIX} ]] || die "Could not read the prefix length from ${LAB_IFACE}."
  if [[ -z ${LAB_GATEWAY} ]]; then
    warn "This VM has no default route to begin with; FAULT 2 will be a no-op"
    warn "and goal G2 will be skipped during verification."
    LAB_GATEWAY="none"
  fi

  mkdir -p "${SNAP_DIR}"
  save_state

  # Snapshot everything we are about to touch, plus the routing table, so a
  # human can always reconstruct the original by hand.
  ip -4 addr  show > "${SNAP_DIR}/ip-addr.before"
  ip -4 route show > "${SNAP_DIR}/ip-route.before"
  sysctl net.ipv4.icmp_echo_ignore_all > "${SNAP_DIR}/sysctl-icmp.before" 2>/dev/null || true
  snapshot_file /etc/services
  snapshot_file /etc/resolv.conf
  snapshot_file /etc/nsswitch.conf

  rule
  log "Injecting faults for ${LAB_ID}. Snapshot: ${SNAP_DIR}"
  rule

  inject_fault_services   # least disruptive first, so a failure mid-run
  inject_fault_icmp       # leaves the box in the most recoverable state
  inject_fault_dns
  inject_fault_addressing # these two cut connectivity, so they go last
  inject_fault_routing

  rule
  ok "Five faults injected at ${LAB_BROKEN_AT}."
  rule
  write_briefing
}

action_status() {
  load_state
  rule
  printf '%sSYMPTOM REPORT -- %s%s\n' "${C_BOLD}" "${LAB_ID}" "${C_RESET}"
  rule

  printf '\n%s# ip -brief -4 addr show%s\n' "${C_BOLD}" "${C_RESET}"
  ip -brief -4 addr show || true

  printf '\n%s# ip -4 route show%s\n' "${C_BOLD}" "${C_RESET}"
  ip -4 route show || printf '(empty)\n'

  printf '\n%s# sysctl net.ipv4.icmp_echo_ignore_all%s\n' "${C_BOLD}" "${C_RESET}"
  sysctl net.ipv4.icmp_echo_ignore_all 2>/dev/null || true

  printf '\n%s# grep -v ^# /etc/resolv.conf%s\n' "${C_BOLD}" "${C_RESET}"
  grep -v '^#' /etc/resolv.conf 2>/dev/null | grep -v '^$' || printf '(empty)\n'

  printf '\n%s# grep -E "^(ssh|https|domain)[[:space:]]" /etc/services%s\n' "${C_BOLD}" "${C_RESET}"
  grep -E '^(ssh|https|domain)[[:space:]]' /etc/services 2>/dev/null || printf '(no match)\n'

  printf '\n%s# ping -c1 -W2 %s%s\n' "${C_BOLD}" "${LAB_GATEWAY}" "${C_RESET}"
  if [[ ${LAB_GATEWAY} != "none" ]]; then
    ping -c1 -W2 "${LAB_GATEWAY}" 2>&1 | tail -n3 || true
  fi

  printf '\n%s# getent hosts www.lpi.org  (may take ~10s)%s\n' "${C_BOLD}" "${C_RESET}"
  timeout 12 getent hosts www.lpi.org || printf '(no answer -- resolution failed)\n'
  rule
}

action_hint() {
  load_state
  local counter_file="${LAB_DIR}/hint.count"
  local n=0
  [[ -r ${counter_file} ]] && n="$(cat "${counter_file}")"
  n=$(( n + 1 ))
  printf '%s\n' "${n}" > "${counter_file}"

  rule
  printf '%sHINT %d%s\n' "${C_BOLD}" "${n}" "${C_RESET}"
  rule
  case ${n} in
    1) cat <<-'EOF'
	Work bottom-up and never trust a single tool.

	Layer 3 first: does the host have a correct address, and does the kernel
	believe the gateway is on-link? 'ip -4 route show' prints the connected
	route the kernel derived from your prefix. Compare the network in that
	route against the gateway address. If the gateway is not inside it, the
	prefix is wrong -- and no amount of restarting NetworkManager will help.
	EOF
       ;;
    2) cat <<-'EOF'
	'ipcalc 192.0.2.10/30' (or sipcalc) prints the network, the broadcast and
	the usable host range for a prefix. Do that for your current prefix and
	then for the prefix the rest of the LAN uses. The gateway must fall
	inside the usable range. Fix the prefix with:

	    ip addr del <addr>/<wrong> dev <iface>
	    ip addr add <addr>/<right> dev <iface>

	Then re-add the default route with 'ip route add default via <gw>'.
	Order matters: the gateway must already be on-link, or the route add
	fails with "Error: Nexthop has invalid gateway."
	EOF
       ;;
    3) cat <<-'EOF'
	For the ping-fails-but-TCP-works symptom: this host is not filtering,
	it is refusing at the kernel level. Look at

	    sysctl -a 2>/dev/null | grep -E 'icmp_echo|icmp_ignore'

	A value of 1 in icmp_echo_ignore_all makes the kernel drop every Echo
	Request without a reply. 'sysctl -w' fixes it now; a file under
	/etc/sysctl.d/ is what makes it survive a reboot. Find the file that was
	added -- 'grep -rn icmp /etc/sysctl.conf /etc/sysctl.d/'.
	EOF
       ;;
    4) cat <<-'EOF'
	DNS: prove where the failure is before touching anything.

	    getent hosts 1.1.1.1        # nsswitch + files path, no DNS involved
    	dig +short @<a known-good resolver> www.lpi.org
	    cat /etc/resolv.conf

	If a query to a resolver you name explicitly succeeds and the default
	one times out, the resolver ADDRESS is wrong, not the network. Note the
	address currently configured: 203.0.113.0/24 is TEST-NET-3 (RFC 5737),
	reserved for documentation and never routed -- a deliberate black hole.
	EOF
       ;;
    5) cat <<-'EOF'
	Ports: 'ss -tulpn' with -n prints numbers, without -n it prints names
	from /etc/services via getservbyport(3). If the name and the number
	disagree with what you know from the IANA registry, the FILE is wrong,
	not the socket. Check the canonical values you must know for 109.1:

	  20/21 ftp-data,ftp   22 ssh    23 telnet  25 smtp   53 domain
	  80 http   110 pop3   123 ntp   139 netbios-ssn      143 imap
	  161/162 snmp,snmp-trap   389 ldap   443 https   465 submissions
	  514 syslog/shell  636 ldaps   993 imaps   995 pop3s

	Restore those three lines by hand, or reinstall the package that owns
	the file ('rpm -qf /etc/services' or 'dpkg -S /etc/services').
	EOF
       ;;
    *) cat <<-'EOF'
	You have used every hint. The full solution is at the bottom of this
	script, commented out. Read it only after you have written down your own
	answers to the six reflection questions -- the diagnosis is the exam,
	the fix is just typing.
	EOF
       ;;
  esac
  rule
}

# -----------------------------------------------------------------------------
# VERIFICATION
# -----------------------------------------------------------------------------

pass_count=0
fail_count=0

check() {
  local goal="$1" description="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    ok "${goal}  ${description}"
    pass_count=$(( pass_count + 1 ))
  else
    printf '%s[FAIL]%s %s  %s\n' "${C_RED}" "${C_RESET}" "${goal}" "${description}"
    fail_count=$(( fail_count + 1 ))
  fi
}

# G1 -- the interface must carry the original address AND the original prefix.
verify_prefix() {
  ip -4 -oneline addr show dev "${LAB_IFACE}" scope global \
    | grep --quiet --fixed-strings " ${LAB_ADDR}/${LAB_PREFIX} "
}

# G1b -- the kernel-derived connected route must actually cover the gateway.
verify_gateway_onlink() {
  [[ ${LAB_GATEWAY} == "none" ]] && return 0
  ip -4 route get "${LAB_GATEWAY}" 2>/dev/null | grep --quiet "dev ${LAB_IFACE}"
}

verify_default_route() {
  [[ ${LAB_GATEWAY} == "none" ]] && return 0
  ip -4 route show default | grep --quiet "via ${LAB_GATEWAY}"
}

# G3 -- runtime value AND persistence. A student who only ran 'sysctl -w'
# passes the first half and fails the second, which is the point.
verify_icmp_runtime() {
  [[ "$(sysctl --values net.ipv4.icmp_echo_ignore_all 2>/dev/null)" == "0" ]]
}

verify_icmp_persistent() {
  ! grep -rqsE '^[[:space:]]*net\.ipv4\.icmp_echo_ignore_all[[:space:]]*=[[:space:]]*1' \
      /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null
}

verify_dns() {
  ! grep -qsE "^[[:space:]]*nameserver[[:space:]]+${BLACKHOLE_DNS}" /etc/resolv.conf \
    && timeout 5 getent hosts www.lpi.org >/dev/null 2>&1
}

verify_services() {
  grep -qE '^ssh[[:space:]]+22/tcp'      /etc/services &&
  grep -qE '^https[[:space:]]+443/tcp'   /etc/services &&
  grep -qE '^domain[[:space:]]+53/udp'   /etc/services
}

action_verify() {
  load_state
  pass_count=0
  fail_count=0
  rule
  printf '%sGRADING -- %s%s\n' "${C_BOLD}" "${LAB_ID}" "${C_RESET}"
  rule
  check "G1a" "interface ${LAB_IFACE} carries ${LAB_ADDR}/${LAB_PREFIX}" verify_prefix
  check "G1b" "the gateway ${LAB_GATEWAY} is reachable on-link"          verify_gateway_onlink
  check "G2 " "an IPv4 default route exists via ${LAB_GATEWAY}"          verify_default_route
  check "G3a" "the kernel answers ICMP Echo Requests (runtime)"          verify_icmp_runtime
  check "G3b" "no sysctl.d file re-enables the drop after reboot"        verify_icmp_persistent
  check "G4 " "forward DNS resolution works under 5 s"                   verify_dns
  check "G5 " "/etc/services matches IANA for ssh, https and domain"     verify_services
  rule
  if [[ ${fail_count} -eq 0 ]]; then
    ok "${pass_count}/7 goals met. Lab solved."
    printf '\nNow answer the six reflection questions in %s.\n' "${BRIEF_FILE}"
    printf 'Then run: sudo %s restore   (to clean up the lab markers)\n' "$0"
  else
    printf '%s%d/%d goals met -- keep going. Run "%s hint" for the next hint.%s\n' \
      "${C_YELLOW}" "${pass_count}" "$(( pass_count + fail_count ))" "$0" "${C_RESET}"
  fi
  rule
  return 0
}

action_restore() {
  load_state
  rule
  log "Restoring everything from ${SNAP_DIR}"
  rule

  restore_file /etc/services
  restore_file /etc/nsswitch.conf

  rm -f /etc/sysctl.d/99-lab-icmp.conf
  sysctl --quiet --write net.ipv4.icmp_echo_ignore_all=0 || true

  rm -f /etc/resolv.conf
  if [[ -r "${SNAP_DIR}/resolv.conf.symlink_target" ]]; then
    ln --symbolic --force "$(cat "${SNAP_DIR}/resolv.conf.symlink_target")" /etc/resolv.conf
  else
    restore_file /etc/resolv.conf
  fi

  ip -4 addr flush dev "${LAB_IFACE}" 2>/dev/null || true
  ip -4 addr add "${LAB_ADDR}/${LAB_PREFIX}" dev "${LAB_IFACE}"
  ip link set dev "${LAB_IFACE}" up
  if [[ ${LAB_GATEWAY} != "none" ]]; then
    ip -4 route replace default via "${LAB_GATEWAY}" dev "${LAB_IFACE}"
  fi

  ok "Restored. Original snapshots kept in ${SNAP_DIR} for reference."
  warn "If this VM uses NetworkManager or systemd-networkd, the runtime state"
  warn "above is authoritative only until the next reconfiguration. Reboot, or"
  warn "run 'nmcli device reapply ${LAB_IFACE}' / 'networkctl reconfigure ${LAB_IFACE}'"
  warn "to prove the on-disk configuration is also correct."
  rule
}

usage() {
  cat <<-EOF
	${LAB_ID} -- LPIC-1 109.1 break & fix laboratory

	Usage: sudo $0 <command>

	  break     inject the five faults (captures a snapshot first)
	  status    print a symptom report
	  hint      print the next progressive hint
	  verify    grade the repair against goals G1..G5
	  restore   undo everything from the snapshot
	EOF
}

main() {
  local cmd="${1:-help}"
  case "${cmd}" in
    break)   require_root "$@"; action_break   ;;
    status)  require_root "$@"; action_status  ;;
    hint)    require_root "$@"; action_hint    ;;
    verify)  require_root "$@"; action_verify  ;;
    restore) require_root "$@"; action_restore ;;
    help|-h|--help) usage ;;
    *) usage; exit 64 ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTION -- step by step
#  ------------------------------------------------------------------------
#  Do not read this until you have run 'hint' to exhaustion and written down
#  your answers to Q1..Q6. The diagnosis is what the exam tests; the repair
#  is three commands and two text edits.
# =============================================================================
#
#  STEP 0 -- ESTABLISH THE FACTS BEFORE CHANGING ANYTHING
#  ------------------------------------------------------
#    # ip -brief -4 addr show
#    lo               UNKNOWN        127.0.0.1/8
#    ens18            UP             192.168.178.42/30
#
#    # ip -4 route show
#    192.168.178.40/30 dev ens18 proto kernel scope link src 192.168.178.42
#
#    Two facts jump out. First, there is no 'default' line at all. Second,
#    the connected route is a /30 -- network 192.168.178.40, usable hosts
#    .41 and .42 only. The gateway on this LAN is 192.168.178.1, which is
#    NOT in that range. That single observation explains Q1: the kernel
#    decides whether a destination is on-link purely from the prefix. With
#    a /30 the gateway looks like a remote host, reachable only through a
#    router -- and the only router we had was the gateway itself. Circular,
#    therefore unreachable.
#
#    # ping -c1 192.168.178.1
#    connect: Network is unreachable
#
#    "Network is unreachable" is emitted by the local kernel (ENETUNREACH)
#    before any packet is transmitted -- confirm with 'tcpdump -ni ens18 icmp'
#    in another terminal: you will see nothing at all. Contrast with
#    "Destination Host Unreachable" (an ICMP type 3 code 1 came BACK from a
#    router, so your packet did travel) and with silent 100% loss (the packet
#    left, and either it or the reply was dropped somewhere). That is Q2.
#
#  STEP 1 -- FIX THE PREFIX (goal G1)
#  ----------------------------------
#    Compute what the prefix should be. If the LAN is 192.168.178.0 with 254
#    usable hosts, the prefix is /24 (mask 255.255.255.0):
#
#      # ipcalc 192.168.178.42/24
#      Address:   192.168.178.42       11000000.10101000.10110010. 00101010
#      Netmask:   255.255.255.0 = 24   11111111.11111111.11111111. 00000000
#      Network:   192.168.178.0/24
#      HostMin:   192.168.178.1
#      HostMax:   192.168.178.254
#      Broadcast: 192.168.178.255
#
#    The gateway 192.168.178.1 is HostMin -- inside the network. Apply it:
#
#      # ip addr del 192.168.178.42/30 dev ens18
#      # ip addr add 192.168.178.42/24 dev ens18
#      # ip -4 route show
#      192.168.178.0/24 dev ens18 proto kernel scope link src 192.168.178.42
#
#    The connected route was re-derived automatically by the kernel; you never
#    add it by hand. Note also that 192.168.0.0/16 is RFC 1918 private space,
#    which is why this address can never be the source seen by a public server
#    (Q5): the border router performs source NAT (masquerading), rewriting the
#    source address to its own public one and tracking the flow in conntrack.
#
#  STEP 2 -- RESTORE THE DEFAULT ROUTE (goal G2)
#  ---------------------------------------------
#      # ip route add default via 192.168.178.1 dev ens18
#      # ip -4 route show
#      default via 192.168.178.1 dev ens18
#      192.168.178.0/24 dev ens18 proto kernel scope link src 192.168.178.42
#
#      # ping -c2 192.168.178.1
#      PING 192.168.178.1 (192.168.178.1) 56(84) bytes of data.
#      64 bytes from 192.168.178.1: icmp_seq=1 ttl=64 time=0.512 ms
#      64 bytes from 192.168.178.1: icmp_seq=2 ttl=64 time=0.488 ms
#      --- 192.168.178.1 ping statistics ---
#      2 packets transmitted, 2 received, 0% packet loss, time 1001ms
#
#    Had you tried this BEFORE step 1, it would have failed with
#      Error: Nexthop has invalid gateway.
#    -- the kernel refuses a gateway that is not on-link. Order is not
#    cosmetic here; it is the proof that step 1 was the real root cause.
#
#    Make it persistent for the distribution in use:
#      NetworkManager:  nmcli con mod "System ens18" ipv4.addresses 192.168.178.42/24 \
#                         ipv4.gateway 192.168.178.1 ipv4.method manual
#                       nmcli con up "System ens18"
#      systemd-networkd: edit /etc/systemd/network/*.network -> [Network] Address=/Gateway=
#                        then: networkctl reload && networkctl reconfigure ens18
#      Debian ifupdown:  /etc/network/interfaces -> address/netmask/gateway
#
#  STEP 3 -- RE-ENABLE ICMP ECHO REPLIES (goal G3)
#  -----------------------------------------------
#    From a second machine on the LAN, the signature was: ping to this host
#    times out, but 'nc -vz 192.168.178.42 22' connects. TCP up, ICMP down.
#    Two plausible causes (Q3): a firewall rule dropping ICMP, or the kernel
#    ignoring echo requests. Distinguish them:
#
#      # nft list ruleset            # or: iptables -S
#      (empty -- so it is not filtering)
#
#      # sysctl net.ipv4.icmp_echo_ignore_all
#      net.ipv4.icmp_echo_ignore_all = 1        <-- there it is
#
#    Fix the runtime value and remove the file that makes it persistent:
#
#      # sysctl -w net.ipv4.icmp_echo_ignore_all=0
#      net.ipv4.icmp_echo_ignore_all = 0
#      # grep -rn icmp_echo_ignore_all /etc/sysctl.conf /etc/sysctl.d/
#      /etc/sysctl.d/99-lab-icmp.conf:2:net.ipv4.icmp_echo_ignore_all = 1
#      # rm /etc/sysctl.d/99-lab-icmp.conf
#      # sysctl --system | grep icmp_echo          # reload, confirm
#
#    Deleting the file without 'sysctl -w' leaves the box broken until
#    reboot; running 'sysctl -w' without deleting the file leaves it broken
#    AFTER the next reboot. Both halves are required -- that is why the
#    grader checks G3a and G3b separately.
#
#    Protocol note for the exam: ICMP is IP protocol number 1 -- it is not
#    carried inside TCP or UDP and has no port numbers at all. That is
#    precisely why "I can't ping it" is never sufficient evidence that a
#    service is down, and why 'ping' is a poor monitoring check.
#
#  STEP 4 -- REPAIR NAME RESOLUTION (goal G4)
#  ------------------------------------------
#    Split the problem in two: is it the network path, or the resolver?
#
#      # getent hosts 192.168.178.1
#      192.168.178.1     gateway              <-- files path fine, nsswitch fine
#
#      # cat /etc/resolv.conf
#      nameserver 203.0.113.53
#      options timeout:5 attempts:2
#
#      # dig +short @1.1.1.1 www.lpi.org
#      104.22.32.163                          <-- an explicit resolver answers
#
#      # dig www.lpi.org
#      ;; communications error to 203.0.113.53#53: timed out
#      ;; no servers could be reached
#
#    203.0.113.0/24 is TEST-NET-3 (RFC 5737): reserved for documentation and
#    never routed on the Internet, so queries vanish. Point the resolver at
#    the real one -- on most LANs that is the gateway itself:
#
#      # printf 'nameserver 192.168.178.1\nnameserver 1.1.1.1\noptions timeout:2\n' \
#          > /etc/resolv.conf
#      # getent hosts www.lpi.org
#      104.22.32.163   www.lpi.org
#
#    If /etc/resolv.conf is a symlink into /run/systemd/resolve/ on your VM,
#    do NOT hand-edit the target -- it is regenerated. Configure the resolver
#    where it belongs and reload:
#      # resolvectl dns ens18 192.168.178.1
#      # resolvectl status ens18
#      # ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
#    Likewise, if NetworkManager owns the file, set ipv4.dns on the connection
#    and 'nmcli con up' -- otherwise your edit is erased at the next DHCP renew.
#
#    Q4, for the exam: DNS uses UDP/53 by default because a query and its
#    answer each fit in a single datagram, and a connectionless exchange
#    avoids the three-way handshake -- one round trip instead of three. The
#    resolver retries over TCP/53 when the response has the TC (truncated)
#    flag set, i.e. the answer exceeded the negotiated size (512 bytes
#    classically, or the EDNS0 advertised buffer), and always for zone
#    transfers (AXFR/IXFR), which are arbitrarily large and must be reliable.
#
#  STEP 5 -- RESTORE THE WELL-KNOWN PORT NAMES (goal G5)
#  -----------------------------------------------------
#    The socket was never wrong -- only the label:
#
#      # ss -tulpn | grep :22
#      tcp   LISTEN 0  128   0.0.0.0:22    0.0.0.0:*   users:(("sshd",pid=812,fd=3))
#
#      # ss -tulp | grep ssh
#      tcp   LISTEN 0  128   0.0.0.0:ssh   0.0.0.0:*   ...     <-- name lookup
#
#      # grep -E '^(ssh|https|domain)[[:space:]]' /etc/services
#      ssh             2222/tcp
#      ssh             2222/udp
#      https           4443/tcp
#      domain          5353/tcp
#      domain          5353/udp
#
#    getservbyport(3) reads this file; nothing on the wire changed. Restore
#    the canonical IANA values:
#
#      # sed -i -e 's|^ssh\t\t2222/|ssh\t\t22/|' \
#               -e 's|^https\t\t4443/|https\t\t443/|' \
#               -e 's|^domain\t\t5353/|domain\t\t53/|' /etc/services
#      # sed -i '/lpic1-109.1 lab marker/d' /etc/services
#
#    Or let the package manager do it, which is what you would do in
#    production:
#      Debian/Ubuntu:  dpkg -S /etc/services   -> netbase
#                      apt-get install --reinstall netbase
#      RHEL/Fedora:    rpm -qf /etc/services   -> setup
#                      rpm --verify setup ; dnf reinstall setup
#
#    The ports you are expected to recognise on sight for 109.1:
#      20  ftp-data (TCP)      21  ftp (TCP)          22  ssh (TCP)
#      23  telnet (TCP)        25  smtp (TCP)         53  domain (UDP+TCP)
#      80  http (TCP)         110  pop3 (TCP)        123  ntp (UDP)
#     139  netbios-ssn (TCP)  143  imap (TCP)        161  snmp (UDP)
#     162  snmp-trap (UDP)    389  ldap (TCP)        443  https (TCP)
#     465  submissions/SMTPS  514  syslog (UDP)      636  ldaps (TCP)
#     993  imaps (TCP)        995  pop3s (TCP)
#
#  STEP 6 -- VERIFY END TO END
#  ---------------------------
#      # sudo ./break-109-1-internet-protocols.sh verify
#      [ ok ] G1a  interface ens18 carries 192.168.178.42/24
#      [ ok ] G1b  the gateway 192.168.178.1 is reachable on-link
#      [ ok ] G2   an IPv4 default route exists via 192.168.178.1
#      [ ok ] G3a  the kernel answers ICMP Echo Requests (runtime)
#      [ ok ] G3b  no sysctl.d file re-enables the drop after reboot
#      [ ok ] G4   forward DNS resolution works under 5 s
#      [ ok ] G5   /etc/services matches IANA for ssh, https and domain
#      [ ok ] 7/7 goals met. Lab solved.
#
#  STEP 7 -- THE IPv6 HALF OF THE OBJECTIVE (Q6)
#  ---------------------------------------------
#    Every command above has an IPv6 form; the objective requires you to know
#    both. Run these on the repaired VM and compare the output:
#
#      # ip -6 addr show ens18
#      inet6 2001:db8:178::2a/64 scope global
#      inet6 fe80::5054:ff:fe12:3456/64 scope link      <-- always present
#
#      # ip -6 route show
#      2001:db8:178::/64 dev ens18 proto kernel metric 256
#      fe80::/64 dev ens18 proto kernel metric 256
#      default via fe80::1 dev ens18 proto ra metric 1024   <-- learned by RA
#
#      # ping -6 -c2 2001:4860:4860::8888
#      # ip -6 neigh show                 # the ND cache -- IPv6's "arp -n"
#
#    What changed, and what disappeared:
#      * 128-bit addresses in eight hextets, written with :: collapsing one
#        run of zeros (RFC 4291). No dotted quad, no netmask -- prefix length
#        only, and /64 for a normal LAN is effectively mandatory because SLAAC
#        depends on it.
#      * ARP is gone. Neighbor Discovery (ICMPv6 types 133-137) replaces it,
#        which makes ICMPv6 structurally mandatory -- blocking ICMPv6 the way
#        this lab blocked ICMPv4 does not "harden" a host, it disconnects it.
#      * Broadcast is gone. Multicast replaces it: ff02::1 all-nodes,
#        ff02::2 all-routers, plus solicited-node ff02::1:ff00:0/104.
#      * Routers never fragment. The source does Path MTU Discovery, so a
#        firewall that drops ICMPv6 Packet Too Big (type 2) creates the classic
#        "small pages load, large ones hang" black hole.
#      * Address autoconfiguration is built in: SLAAC from Router
#        Advertisements, optionally with DHCPv6 for other parameters.
#      * NAT is not required -- global addresses are the norm; fc00::/7
#        (RFC 4193, in practice fd00::/8) is the ULA range, the closest
#        equivalent to RFC 1918, and fe80::/10 link-local exists on every
#        interface unconditionally.
#      * There is no checksum in the IPv6 header, and the header is a fixed
#        40 bytes with options moved to extension headers.
#
#  CLEAN UP
#  --------
#      # sudo ./break-109-1-internet-protocols.sh restore
#      # sudo rm -rf /var/tmp/lpic1-109.1 /etc/lab-vm-ok
#
# =============================================================================