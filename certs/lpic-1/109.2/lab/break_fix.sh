#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-1 (Exam 101-500 / 102-500, version 5.0)
#  Topic 109.2 -- Persistent network configuration
#  BREAK & FIX laboratory script
# ============================================================================
#
#  WHAT THIS SCRIPT IS
#  -------------------
#  It deliberately breaks the *persistent* network configuration of a
#  throw-away lab VM, in a fully reversible way, and then hands the machine
#  to you with a mission statement. Every file it touches is archived first,
#  so `--restore` always brings the box back.
#
#  The whole point of objective 109.2 is the distinction between:
#
#     * RUNTIME state   -> `ip addr`, `ip route`, `hostname`, `resolvectl`
#                          Lives in kernel memory. Dies on reboot.
#     * PERSISTENT state -> /etc/hostname, /etc/hosts, /etc/nsswitch.conf,
#                          /etc/resolv.conf, NetworkManager keyfiles,
#                          /etc/network/interfaces, /etc/systemd/network/*.
#                          Survives a reboot -- and re-applies the fault if
#                          you only patched the runtime.
#
#  This lab is therefore graded twice: once on the live system, and once
#  after a simulated reboot. A runtime-only fix WILL be rejected.
#
#  !! RUN THIS ONLY ON A DISPOSABLE LAB VM WITH CONSOLE ACCESS !!
#  It removes the default route. If your only way in is SSH, you will be
#  locked out. The script refuses to run over SSH unless you force it.
#
#  Reference (official objectives):
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#    https://www.lpi.org/our-certifications/exam-102-objectives/
#
#  USAGE
#    sudo LAB_CONFIRM=yes ./lpic1-109.2-break-and-fix.sh break     # break it
#    sudo ./lpic1-109.2-break-and-fix.sh hint                      # nudges
#    sudo ./lpic1-109.2-break-and-fix.sh verify                    # grade me
#    sudo ./lpic1-109.2-break-and-fix.sh status                    # dump state
#    sudo ./lpic1-109.2-break-and-fix.sh restore                   # give up
#
#  Environment knobs:
#    LAB_CONFIRM=yes   required acknowledgement for `break`
#    LAB_FORCE_SSH=yes allow breaking while logged in over SSH (don't)
#    LAB_HARD=yes      adds the immutable-resolv.conf twist (chattr +i)
#    TEST_HOST=...     external name used for the DNS check (default: deb.debian.org)
# ============================================================================

set -uo pipefail

readonly LAB_TAG="lpic1-109.2"
readonly BACKUP_DIR="/var/backups/${LAB_TAG}"
readonly ARCHIVE="${BACKUP_DIR}/etc-backup.tar.gz"
readonly STATE="${BACKUP_DIR}/state.env"

readonly BOGUS_DNS="192.0.2.53"          # RFC 5737 TEST-NET-1: guaranteed dead
readonly BOGUS_ADDR="10.99.99.7"
readonly BOGUS_CIDR="10.99.99.7/24"
readonly BOGUS_GW="10.99.99.1"
readonly BROKEN_HOSTNAME="broken-node"

readonly NM_LAB_MARK="# ${LAB_TAG} lab fault"
readonly NETWORKD_LAB_FILE="/etc/systemd/network/99-${LAB_TAG}-broken.network"

TEST_HOST="${TEST_HOST:-deb.debian.org}"

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3)
    C_BLU=$(tput setaf 4); C_BLD=$(tput bold);    C_OFF=$(tput sgr0)
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[OK]%s   %s\n' "$C_GRN" "$C_OFF" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
skip() { printf '%s[SKIP]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s[X]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$C_BLD" "------------------------------------------------------------------------" "$C_OFF"; }

# ----------------------------------------------------------------------------
# Safety gates
# ----------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must run as root (try: sudo $0 $*)."
}

safety_gate() {
    if [ "${LAB_CONFIRM:-}" != "yes" ]; then
        rule
        say "${C_BLD}REFUSING TO BREAK ANYTHING WITHOUT AN EXPLICIT ACKNOWLEDGEMENT.${C_OFF}"
        say ""
        say "This script will disable networking on THIS machine until you repair"
        say "it. Use a snapshot-able lab VM you can reach from the hypervisor"
        say "console. Then re-run:"
        say ""
        say "    sudo LAB_CONFIRM=yes $0 break"
        rule
        exit 1
    fi

    if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && [ "${LAB_FORCE_SSH:-}" != "yes" ]; then
        die "You are connected over SSH. Breaking the default route will lock you out.
    Log in on the VM console instead, or set LAB_FORCE_SSH=yes if you have
    an out-of-band console (virsh console / hypervisor GUI / serial)."
    fi

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt; virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
        if [ "$virt" = "none" ]; then
            warn "systemd-detect-virt says this is BARE METAL, not a VM. Continuing anyway"
            warn "because you passed LAB_CONFIRM=yes. Take a backup. You were told."
            sleep 5
        else
            info "Virtualisation detected: ${virt}. Good."
        fi
    fi
}

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------
detect_iface() {
    local dev
    dev="$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)"
    if [ -z "$dev" ]; then
        dev="$(ip -o link show up 2>/dev/null \
               | awk -F': ' '{print $2}' | grep -v '^lo$' | head -n1)"
    fi
    printf '%s' "$dev"
}

detect_stack() {
    # Returns: networkmanager | networkd | ifupdown | unknown
    if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
        printf 'networkmanager'
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        printf 'networkd'
    elif [ -f /etc/network/interfaces ] && command -v ifup >/dev/null 2>&1; then
        printf 'ifupdown'
    else
        printf 'unknown'
    fi
}

nm_connection_for() {
    local dev="$1"
    nmcli -t -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1
}

resolved_active() {
    systemctl is-active --quiet systemd-resolved 2>/dev/null
}

load_state() {
    [ -f "$STATE" ] || die "No lab state found in ${STATE}. Nothing was broken by this script."
    # shellcheck disable=SC1090
    . "$STATE"
}

# ----------------------------------------------------------------------------
# Backup / restore
# ----------------------------------------------------------------------------
BACKUP_PATHS=(
    "etc/hostname"
    "etc/hosts"
    "etc/nsswitch.conf"
    "etc/resolv.conf"
    "etc/systemd/resolved.conf"
    "etc/systemd/resolved.conf.d"
    "etc/systemd/network"
    "etc/NetworkManager"
    "etc/network/interfaces"
    "etc/network/interfaces.d"
    "etc/sysconfig/network-scripts"
    "etc/sysconfig/network"
    "etc/netplan"
)

do_backup() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"      # NM keyfiles can contain Wi-Fi/802.1x secrets

    local existing=()
    local p
    for p in "${BACKUP_PATHS[@]}"; do
        [ -e "/$p" ] && existing+=("$p")
    done

    tar czpf "$ARCHIVE" -C / --warning=no-file-changed "${existing[@]}" 2>/dev/null
    [ -s "$ARCHIVE" ] || die "Backup archive is empty -- refusing to break anything."
    chmod 600 "$ARCHIVE"

    # Human-readable snapshot of the runtime state, for the student's reference.
    {
        echo "### ip addr"; ip addr
        echo; echo "### ip route"; ip route
        echo; echo "### resolv.conf"; cat /etc/resolv.conf 2>/dev/null
        echo; echo "### nmcli con show"; nmcli con show 2>/dev/null
    } > "${BACKUP_DIR}/pre-break-snapshot.txt" 2>/dev/null

    ok "Backup written to ${ARCHIVE}"
}

do_restore() {
    require_root
    [ -s "$ARCHIVE" ] || die "No backup archive at ${ARCHIVE}."
    load_state

    info "Clearing the immutable bit from /etc/resolv.conf (if set)..."
    command -v chattr >/dev/null 2>&1 && chattr -i /etc/resolv.conf 2>/dev/null

    info "Removing lab-injected files..."
    rm -f "$NETWORKD_LAB_FILE"

    info "Extracting the pre-break configuration..."
    tar xzpf "$ARCHIVE" -C / || die "Extraction failed."

    if [ -n "${ORIG_HOSTNAME:-}" ]; then
        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$ORIG_HOSTNAME" 2>/dev/null
        else
            hostname "$ORIG_HOSTNAME"
        fi
    fi

    restart_stack
    ok "System restored. Verify with: ip a; ip r; getent hosts ${TEST_HOST}"
    warn "A reboot is still the honest final check."
}

restart_stack() {
    info "Restarting the network stack (${STACK:-unknown})..."
    case "${STACK:-unknown}" in
        networkmanager)
            systemctl restart NetworkManager 2>/dev/null
            sleep 3
            [ -n "${NM_CON:-}" ] && timeout 25 nmcli con up "$NM_CON" >/dev/null 2>&1
            ;;
        networkd)
            systemctl restart systemd-networkd 2>/dev/null
            command -v networkctl >/dev/null 2>&1 && networkctl reload 2>/dev/null
            sleep 3
            ;;
        ifupdown)
            ifdown --force "${IFACE:-lo}" >/dev/null 2>&1
            ifup "${IFACE:-lo}"           >/dev/null 2>&1
            sleep 2
            ;;
        *)
            warn "Unknown stack: restart networking manually."
            ;;
    esac
    resolved_active && systemctl restart systemd-resolved 2>/dev/null
    sleep 2
}

# ----------------------------------------------------------------------------
# Baseline: only demand of the student what actually worked before the break
# ----------------------------------------------------------------------------
capture_baseline() {
    BASE_DEFAULT_ROUTE=no
    BASE_GW=""
    BASE_DNS=no
    BASE_HOSTNAME_RESOLVES=no

    if ip -4 route show default 2>/dev/null | grep -q .; then
        BASE_DEFAULT_ROUTE=yes
        BASE_GW="$(ip -o -4 route show default | awk '{print $3}' | head -n1)"
    fi
    if getent ahostsv4 "$TEST_HOST" >/dev/null 2>&1; then
        BASE_DNS=yes
    fi
    if getent hosts "$(hostname)" >/dev/null 2>&1; then
        BASE_HOSTNAME_RESOLVES=yes
    fi
}

# ----------------------------------------------------------------------------
# THE FAULTS
# ----------------------------------------------------------------------------
fault_identity() {
    # FAULT 1 -- persistent hostname changed, and the matching /etc/hosts
    # entry removed. Symptom: sudo prints "unable to resolve host" and pauses.
    info "Fault 1/5: rewriting /etc/hostname and stripping the host's own /etc/hosts entry"

    printf '%s\n' "$BROKEN_HOSTNAME" > /etc/hostname
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$BROKEN_HOSTNAME" 2>/dev/null
    else
        hostname "$BROKEN_HOSTNAME"
    fi

    # Remove any /etc/hosts line that maps the old or the new name.
    local tmp; tmp="$(mktemp)"
    grep -v -E "(^|[[:space:]])(${ORIG_HOSTNAME}|${ORIG_HOSTNAME%%.*}|${BROKEN_HOSTNAME})([[:space:]]|$)" \
        /etc/hosts > "$tmp" 2>/dev/null
    cat "$tmp" > /etc/hosts
    rm -f "$tmp"
}

fault_nsswitch() {
    # FAULT 2 -- the hosts: line no longer consults `files`, so /etc/hosts is
    # ignored entirely. This is the trap: a student can write a perfect
    # /etc/hosts entry and still see nothing resolve.
    info "Fault 2/5: /etc/nsswitch.conf hosts: line now consults DNS only"
    if grep -qE '^[[:space:]]*hosts:' /etc/nsswitch.conf 2>/dev/null; then
        sed -i -E "s/^[[:space:]]*hosts:.*/hosts:          dns/" /etc/nsswitch.conf
    else
        printf 'hosts:          dns\n' >> /etc/nsswitch.conf
    fi
}

fault_resolver() {
    # FAULT 3 -- persistent DNS pointed at an unroutable TEST-NET-1 address.
    info "Fault 3/5: resolver pointed at the black hole ${BOGUS_DNS}"

    RESOLV_WAS_SYMLINK=no
    RESOLV_TARGET=""
    if [ -L /etc/resolv.conf ]; then
        RESOLV_WAS_SYMLINK=yes
        RESOLV_TARGET="$(readlink /etc/resolv.conf)"
        rm -f /etc/resolv.conf
    fi

    cat > /etc/resolv.conf <<EOF
# ${LAB_TAG} lab fault -- this resolver does not exist
nameserver ${BOGUS_DNS}
options timeout:1 attempts:1
EOF

    if resolved_active && [ -f /etc/systemd/resolved.conf ]; then
        info "        systemd-resolved is active: poisoning /etc/systemd/resolved.conf too"
        sed -i -E 's/^#?[[:space:]]*DNS=.*/DNS='"${BOGUS_DNS}"'/;   s/^#?[[:space:]]*FallbackDNS=.*/FallbackDNS=/' \
            /etc/systemd/resolved.conf
        grep -qE '^DNS=' /etc/systemd/resolved.conf || printf 'DNS=%s\n' "$BOGUS_DNS" >> /etc/systemd/resolved.conf
    fi

    if [ "${LAB_HARD:-}" = "yes" ] && command -v chattr >/dev/null 2>&1; then
        chattr +i /etc/resolv.conf 2>/dev/null && \
            info "        HARD mode: /etc/resolv.conf is now immutable (chattr +i)"
    fi
}

fault_persistent_ip() {
    # FAULT 4 -- the *persistent* profile is rewritten to a static address in
    # a subnet nobody serves, with a gateway that does not answer, and
    # autoconnect/auto disabled so nothing comes back after a reboot.
    info "Fault 4/5: persistent interface profile for ${IFACE} rewritten (stack: ${STACK})"

    case "$STACK" in
        networkmanager)
            if [ -n "${NM_CON:-}" ]; then
                nmcli con mod "$NM_CON" \
                    ipv4.method manual \
                    ipv4.addresses "$BOGUS_CIDR" \
                    ipv4.gateway "$BOGUS_GW" \
                    ipv4.dns "$BOGUS_DNS" \
                    ipv4.ignore-auto-dns yes \
                    connection.autoconnect no >/dev/null 2>&1
                timeout 25 nmcli con up "$NM_CON" >/dev/null 2>&1
            else
                warn "        No NetworkManager profile bound to ${IFACE}; runtime break only."
            fi
            ;;
        networkd)
            # Park the real .network units and drop a broken one with priority.
            mkdir -p "${BACKUP_DIR}/networkd-parked"
            local f
            for f in /etc/systemd/network/*.network; do
                [ -e "$f" ] || continue
                mv "$f" "${BACKUP_DIR}/networkd-parked/" 2>/dev/null
            done
            cat > "$NETWORKD_LAB_FILE" <<EOF
${NM_LAB_MARK}
[Match]
Name=${IFACE}

[Network]
Address=${BOGUS_CIDR}
DNS=${BOGUS_DNS}
# Note the missing Gateway= and the missing DHCP=yes.
EOF
            systemctl restart systemd-networkd >/dev/null 2>&1
            ;;
        ifupdown)
            cat > /etc/network/interfaces <<EOF
${NM_LAB_MARK}
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# The 'auto ${IFACE}' line is gone, so this interface is not brought up at
# boot -- and the addressing below is wrong anyway.
iface ${IFACE} inet static
    address ${BOGUS_ADDR}
    netmask 255.255.255.0
    gateway ${BOGUS_GW}
    dns-nameservers ${BOGUS_DNS}
EOF
            ;;
        *)
            warn "        Unrecognised network stack; applying the runtime fault only."
            ;;
    esac
}

fault_runtime() {
    # FAULT 5 -- make the damage visible right now, so the student does not
    # have to reboot to see a symptom.
    info "Fault 5/5: flushing the runtime address and default route on ${IFACE}"
    ip -4 addr flush dev "$IFACE" 2>/dev/null
    ip addr add "$BOGUS_CIDR" dev "$IFACE" 2>/dev/null
    ip link set "$IFACE" up 2>/dev/null
    while ip -4 route show default 2>/dev/null | grep -q .; do
        ip route del default 2>/dev/null || break
    done
}

# ----------------------------------------------------------------------------
# Briefing
# ----------------------------------------------------------------------------
briefing() {
    rule
    say "${C_BLD} LPIC-1 109.2 -- Persistent network configuration :: LAB IS ARMED${C_OFF}"
    rule
    say ""
    say "${C_BLD}SYMPTOMS YOU SHOULD SEE${C_OFF}"
    say ""
    say "  1. Every sudo invocation now prints, after a noticeable delay:"
    say "       sudo: unable to resolve host ${BROKEN_HOSTNAME}: ..."
    say "     and your shell prompt shows the wrong machine name."
    say ""
    say "  2. Nothing off-box is reachable:"
    say "       \$ ping -c1 1.1.1.1"
    say "       ping: connect: Network is unreachable"
    say "     because ${IFACE} carries ${BOGUS_CIDR} and there is no default route."
    say ""
    say "  3. Name resolution fails even for names you add to /etc/hosts:"
    say "       \$ getent hosts ${TEST_HOST}"
    say "       (no output, exit status 2)"
    say "       \$ ping ${TEST_HOST}"
    say "       ping: ${TEST_HOST}: Temporary failure in name resolution"
    say ""
    say "  4. And -- the part that matters for this objective -- rebooting does"
    say "     NOT help. The faults are in the persistent configuration."
    say ""
    say "${C_BLD}YOUR MISSION${C_OFF}"
    say ""
    say "  a) Restore the machine's identity: the hostname must be"
    say "     ${C_BLD}${ORIG_HOSTNAME}${C_OFF} again, persistently, and it must resolve locally."
    say "  b) Restore IPv4 connectivity on ${C_BLD}${IFACE}${C_OFF}: correct address and a"
    say "     working default route (the lab gateway was ${C_BLD}${BASE_GW:-<unknown>}${C_OFF})."
    say "  c) Restore DNS: ${TEST_HOST} must resolve again."
    say "  d) Make /etc/hosts authoritative again for local lookups."
    say "  e) ${C_BLD}All of it must survive a reboot.${C_OFF} A fix made only with 'ip' and"
    say "     'hostname' is not a fix -- it is a countdown."
    say ""
    say "${C_BLD}RULES${C_OFF}"
    say "  * Do not restore from ${ARCHIVE}. That is the surrender button."
    say "  * Detected stack: ${C_BLD}${STACK}${C_OFF}${NM_CON:+  (profile: ${NM_CON})}"
    say "  * Pre-break snapshot for reference: ${BACKUP_DIR}/pre-break-snapshot.txt"
    say ""
    say "${C_BLD}COMMANDS${C_OFF}"
    say "  sudo $0 hint      # graduated hints, no spoilers"
    say "  sudo $0 verify    # grades you, including a simulated reboot"
    say "  sudo $0 restore   # undo everything"
    rule
}

# ----------------------------------------------------------------------------
# break
# ----------------------------------------------------------------------------
do_break() {
    require_root
    safety_gate

    [ -f "$STATE" ] && die "The lab is already armed (${STATE}). Run '$0 restore' first."

    IFACE="$(detect_iface)"
    [ -n "$IFACE" ] || die "Could not determine a primary network interface."
    STACK="$(detect_stack)"
    ORIG_HOSTNAME="$(hostname)"
    NM_CON=""
    [ "$STACK" = "networkmanager" ] && NM_CON="$(nm_connection_for "$IFACE")"

    info "Interface : ${IFACE}"
    info "Stack     : ${STACK}${NM_CON:+ (profile: ${NM_CON})}"
    info "Hostname  : ${ORIG_HOSTNAME}"

    capture_baseline
    do_backup

    mkdir -p "$BACKUP_DIR"
    cat > "$STATE" <<EOF
# ${LAB_TAG} lab state -- written at break time
IFACE="${IFACE}"
STACK="${STACK}"
NM_CON="${NM_CON}"
ORIG_HOSTNAME="${ORIG_HOSTNAME}"
BASE_DEFAULT_ROUTE="${BASE_DEFAULT_ROUTE}"
BASE_GW="${BASE_GW}"
BASE_DNS="${BASE_DNS}"
BASE_HOSTNAME_RESOLVES="${BASE_HOSTNAME_RESOLVES}"
TEST_HOST="${TEST_HOST}"
RESOLV_WAS_SYMLINK="no"
RESOLV_TARGET=""
EOF
    chmod 600 "$STATE"

    say ""
    info "Injecting faults..."
    fault_identity
    fault_nsswitch
    fault_resolver
    fault_persistent_ip
    fault_runtime

    # Persist the resolv.conf symlink facts discovered inside fault_resolver().
    sed -i -E "s|^RESOLV_WAS_SYMLINK=.*|RESOLV_WAS_SYMLINK=\"${RESOLV_WAS_SYMLINK}\"|" "$STATE"
    sed -i -E "s|^RESOLV_TARGET=.*|RESOLV_TARGET=\"${RESOLV_TARGET}\"|" "$STATE"

    say ""
    briefing
}

# ----------------------------------------------------------------------------
# hint
# ----------------------------------------------------------------------------
do_hint() {
    load_state
    rule
    say "${C_BLD}HINTS -- read them one at a time, and try the box between each${C_OFF}"
    rule
    say ""
    say "${C_BLD}Hint 1 -- work bottom-up, the OSI way.${C_OFF}"
    say "  Link, then address, then route, then resolver, then name service"
    say "  switch. Fixing DNS while the interface has no route is wasted effort."
    say "    ip link show ${IFACE}"
    say "    ip -4 addr show ${IFACE}"
    say "    ip route show"
    say ""
    say "${C_BLD}Hint 2 -- 'Network is unreachable' is a routing message, not a DNS one.${C_OFF}"
    say "  The address on ${IFACE} belongs to a subnet nobody serves. Compare it"
    say "  with what the rest of the lab uses (your hypervisor's NAT/bridge range),"
    say "  and with ${BACKUP_DIR}/pre-break-snapshot.txt."
    say ""
    say "${C_BLD}Hint 3 -- find who owns the persistent config before editing files.${C_OFF}"
    say "    systemctl is-active NetworkManager systemd-networkd systemd-resolved"
    say "    nmcli device status ; nmcli con show"
    say "    networkctl status ${IFACE}"
    say "    ls /etc/network/interfaces.d/ /etc/systemd/network/"
    say "  Editing the file the running daemon does not read is the classic waste"
    say "  of an exam hour. This box is using: ${C_BLD}${STACK}${C_OFF}."
    say ""
    say "${C_BLD}Hint 4 -- two separate DNS layers may be lying to you.${C_OFF}"
    say "    cat /etc/resolv.conf          # is it a real file or a symlink?"
    say "    ls -l /etc/resolv.conf"
    say "    resolvectl status             # if systemd-resolved is running"
    say "  ${BOGUS_DNS} is in RFC 5737 TEST-NET-1. It will never answer."
    say ""
    say "${C_BLD}Hint 5 -- 'I added it to /etc/hosts and it still fails.'${C_OFF}"
    say "  Then something is not consulting /etc/hosts at all."
    say "    grep ^hosts: /etc/nsswitch.conf"
    say "    getent hosts localhost        # does even THIS fail?"
    say "  man 5 nsswitch.conf"
    say ""
    say "${C_BLD}Hint 6 -- the hostname lives in two places.${C_OFF}"
    say "  The kernel's current one ('hostname', 'hostnamectl') and the one read"
    say "  at boot (/etc/hostname). Change only the first and the reboot undoes you."
    say "  And /etc/hosts must map it, or every sudo pays a DNS timeout."
    say ""
    say "${C_BLD}Hint 7 -- if a file refuses to be edited even as root...${C_OFF}"
    say "    lsattr /etc/resolv.conf"
    say ""
    say "Grade yourself:  sudo $0 verify"
    rule
}

# ----------------------------------------------------------------------------
# verify
# ----------------------------------------------------------------------------
PASS=0; FAILED=0

check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"; PASS=$((PASS+1)); return 0
    else
        bad "$desc"; FAILED=$((FAILED+1)); return 1
    fi
}

has_default_route()   { ip -4 route show default | grep -q .; }
addr_not_bogus()      { ! ip -4 addr show "$IFACE" 2>/dev/null | grep -q "$BOGUS_ADDR"; }
has_v4_addr()         { ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet '; }
gateway_reachable()   { local gw; gw="$(ip -o -4 route show default | awk '{print $3}' | head -n1)"; [ -n "$gw" ] && ping -c1 -W2 "$gw" >/dev/null 2>&1; }
resolver_sane()       { ! grep -qE "^[[:space:]]*nameserver[[:space:]]+${BOGUS_DNS}" /etc/resolv.conf 2>/dev/null && grep -qE '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null; }
nsswitch_files()      { grep -E '^[[:space:]]*hosts:' /etc/nsswitch.conf 2>/dev/null | grep -qw 'files'; }
hostname_persistent() { [ "$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')" = "$ORIG_HOSTNAME" ]; }
hostname_runtime()    { [ "$(hostname)" = "$ORIG_HOSTNAME" ]; }
hostname_resolves()   { getent hosts "$ORIG_HOSTNAME" >/dev/null 2>&1; }
dns_works()           { getent ahostsv4 "$TEST_HOST" >/dev/null 2>&1; }
resolv_mutable()      { ! lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; }
lab_file_gone()       { [ ! -f "$NETWORKD_LAB_FILE" ]; }
no_lab_marker()       { ! grep -qrl "$NM_LAB_MARK" /etc/network/interfaces /etc/systemd/network/ 2>/dev/null; }

run_checks() {
    PASS=0; FAILED=0

    check "Interface ${IFACE} carries an IPv4 address"            has_v4_addr
    check "The bogus ${BOGUS_ADDR} address is gone"               addr_not_bogus
    check "A default route exists"                                has_default_route

    if [ "${BASE_DEFAULT_ROUTE:-no}" = "yes" ]; then
        check "The default gateway answers ICMP"                  gateway_reachable
    else
        skip "Gateway reachability (no default route existed before the break)"
    fi

    check "/etc/resolv.conf lists a usable nameserver"            resolver_sane
    check "/etc/resolv.conf is not immutable"                     resolv_mutable
    check "nsswitch.conf 'hosts:' consults 'files'"               nsswitch_files
    check "/etc/hostname is '${ORIG_HOSTNAME}'"                   hostname_persistent
    check "Running hostname is '${ORIG_HOSTNAME}'"                hostname_runtime

    if [ "${BASE_HOSTNAME_RESOLVES:-no}" = "yes" ]; then
        check "'${ORIG_HOSTNAME}' resolves locally (no sudo delay)" hostname_resolves
    else
        skip "Local hostname resolution (it did not resolve before the break either)"
    fi

    if [ "${BASE_DNS:-no}" = "yes" ]; then
        check "DNS resolves ${TEST_HOST}"                         dns_works
    else
        skip "External DNS (${TEST_HOST} did not resolve before the break either)"
    fi

    check "Lab-injected networkd unit removed"                    lab_file_gone
    check "No lab fault markers left in the config files"         no_lab_marker
}

do_verify() {
    require_root
    load_state

    rule
    say "${C_BLD} PASS 1 -- live system${C_OFF}"
    rule
    run_checks
    local live_failed=$FAILED

    if [ "$live_failed" -ne 0 ]; then
        say ""
        bad "${live_failed} check(s) failed on the live system. Keep going."
        say "    Hints:  sudo $0 hint"
        exit 1
    fi

    say ""
    rule
    say "${C_BLD} PASS 2 -- simulated reboot (this is where runtime-only fixes die)${C_OFF}"
    rule
    restart_stack
    run_checks

    say ""
    if [ "$FAILED" -eq 0 ]; then
        rule
        ok "${C_BLD}LAB PASSED${C_OFF} -- ${PASS} checks green, before and after a stack restart."
        say ""
        say "Final honesty check, because a service restart is not a boot:"
        say "    sudo reboot"
        say "    # then, once it is back:  sudo $0 verify"
        say ""
        say "When you are done, drop the lab state:  sudo rm -rf ${BACKUP_DIR}"
        rule
        exit 0
    else
        rule
        bad "${C_BLD}NOT PERSISTENT${C_OFF} -- it worked live, then ${FAILED} check(s) broke on restart."
        say ""
        say "This is exactly the failure objective 109.2 exists to teach: you fixed"
        say "the running kernel state, not the configuration that recreates it."
        say "Find the file or profile the daemon actually reads, and put the fix there."
        rule
        exit 1
    fi
}

do_status() {
    load_state
    rule
    say "${C_BLD}Lab state${C_OFF}"
    rule
    say "  Interface        : ${IFACE}"
    say "  Stack            : ${STACK}${NM_CON:+ (profile: ${NM_CON})}"
    say "  Original hostname: ${ORIG_HOSTNAME}"
    say "  Backup archive   : ${ARCHIVE}"
    say ""
    say "${C_BLD}Current runtime${C_OFF}"
    ip -4 -br addr show 2>/dev/null
    ip -4 route show 2>/dev/null
    say ""
    say "${C_BLD}/etc/resolv.conf${C_OFF}"
    ls -l /etc/resolv.conf 2>/dev/null
    cat /etc/resolv.conf 2>/dev/null
    say ""
    say "${C_BLD}nsswitch hosts line${C_OFF}"
    grep -E '^[[:space:]]*hosts:' /etc/nsswitch.conf 2>/dev/null
    rule
}

usage() {
    cat <<EOF
LPIC-1 109.2 -- Persistent network configuration :: break & fix lab

  sudo LAB_CONFIRM=yes $0 break     Arm the lab (backs up /etc first)
  sudo $0 hint                      Graduated hints
  sudo $0 verify                    Grade the repair, including a reboot simulation
  sudo $0 status                    Dump the current network state
  sudo $0 restore                   Undo everything from the backup

Environment: LAB_CONFIRM, LAB_FORCE_SSH, LAB_HARD, TEST_HOST
EOF
}

case "${1:-}" in
    break)   do_break   ;;
    hint)    do_hint    ;;
    verify)  do_verify  ;;
    status)  do_status  ;;
    restore) do_restore ;;
    ""|-h|--help|help) usage ;;
    *) die "Unknown command: $1 (try --help)" ;;
esac

# ============================================================================
# ============================================================================
#
#   S O L U T I O N   --   step by step
#
#   Stop reading here if you have not finished the lab.
#
# ============================================================================
# ============================================================================
#
# ----------------------------------------------------------------------------
# STEP 0 -- Establish what you are looking at, before editing anything
# ----------------------------------------------------------------------------
#
#   The single most expensive mistake in this objective is editing the right
#   kind of file for the wrong stack: writing /etc/network/interfaces on a
#   NetworkManager box, or nmcli-ing a systemd-networkd box. Identify the
#   owner first.
#
#     systemctl is-active NetworkManager systemd-networkd systemd-resolved networking
#     nmcli device status                # NetworkManager's view; STATE column
#     networkctl status                  # systemd-networkd's view
#     ls -l /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null
#     ls -l /etc/systemd/network/ /etc/netplan/ 2>/dev/null
#     ls -l /etc/NetworkManager/system-connections/ 2>/dev/null
#
#   And take the runtime picture:
#
#     ip -br link                        # is the NIC UP? is the carrier there?
#     ip -4 -br addr
#     ip -4 route
#     hostname; hostnamectl status
#
#   Expected findings after this lab armed itself:
#     * eth0/ens*/enp* holds 10.99.99.7/24
#     * `ip route` shows no `default via ...` line
#     * hostname is `broken-node`
#     * /etc/resolv.conf says `nameserver 192.0.2.53`
#     * /etc/nsswitch.conf says `hosts:  dns`
#
# ----------------------------------------------------------------------------
# STEP 1 -- Layer 3: give the interface a correct address and a default route
# ----------------------------------------------------------------------------
#
#   "ping: connect: Network is unreachable" is emitted by the kernel routing
#   code, not by the resolver. It means: no route matches the destination.
#
#   First find what the subnet actually is. Sources of truth, in order:
#     * ${BACKUP_DIR}/pre-break-snapshot.txt   (this lab left it for you)
#     * your hypervisor's NAT/bridge network (libvirt default: 192.168.122.0/24,
#       gateway 192.168.122.1; VirtualBox NAT: 10.0.2.0/24, gateway 10.0.2.2)
#     * a DHCP server on the segment, which is the usual answer for a lab VM
#
#   1a. RUNTIME repair -- proves the diagnosis, survives nothing:
#
#         ip addr flush dev eth0
#         ip addr add 192.168.122.50/24 dev eth0        # or your real subnet
#         ip link set eth0 up
#         ip route add default via 192.168.122.1 dev eth0
#         ping -c2 192.168.122.1
#
#       Do this to confirm the address plan, then throw it away and do 1b.
#       `ip` writes to the kernel only; nothing under /etc changes.
#       (man 8 ip, man 8 ip-address, man 8 ip-route)
#
#   1b. PERSISTENT repair -- pick the branch that matches your stack:
#
#     ---- NetworkManager (Fedora/RHEL/Rocky/Alma, Ubuntu Desktop) ----------
#
#       nmcli con show                                  # find the profile name
#       CON="Wired connection 1"                        # yours will differ
#
#       # Back to DHCP, which is what a lab VM normally wants:
#       nmcli con mod "$CON" ipv4.method auto
#       nmcli con mod "$CON" ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
#       nmcli con mod "$CON" ipv4.ignore-auto-dns no
#       nmcli con mod "$CON" connection.autoconnect yes    # <-- the reboot fix
#       nmcli con down "$CON"; nmcli con up "$CON"
#
#       # Or, if the lab uses static addressing:
#       nmcli con mod "$CON" ipv4.method manual \
#             ipv4.addresses 192.168.122.50/24 \
#             ipv4.gateway 192.168.122.1 \
#             ipv4.dns "192.168.122.1 1.1.1.1" \
#             connection.autoconnect yes
#       nmcli con up "$CON"
#
#       Verify what was actually written to disk:
#         nmcli -f ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,connection.autoconnect \
#               con show "$CON"
#         grep -r . /etc/NetworkManager/system-connections/
#
#       Note: `nmcli con mod` writes the keyfile immediately; `nmcli dev`
#       commands and `ip` do not. autoconnect=no is the fault that only
#       appears at boot -- it is the whole trap of this branch.
#
#     ---- systemd-networkd (minimal servers, containers, Debian netplan) ----
#
#       # The lab moved your real *.network units into
#       #   /var/backups/lpic1-109.2/networkd-parked/
#       # Restore them, or simply write a correct unit and delete the fault:
#
#       rm -f /etc/systemd/network/99-lpic1-109.2-broken.network
#       cat > /etc/systemd/network/10-lab.network <<'EOF'
#       [Match]
#       Name=eth0
#
#       [Network]
#       DHCP=ipv4
#       EOF
#
#       # Static variant:
#       #   [Network]
#       #   Address=192.168.122.50/24
#       #   Gateway=192.168.122.1
#       #   DNS=192.168.122.1
#
#       networkctl reload            # or: systemctl restart systemd-networkd
#       networkctl status eth0
#
#       Gotcha: units are applied in lexical order and the FIRST matching
#       [Match] wins, which is why a file called 99-* can still be the one in
#       force if nothing else matches. `networkctl status` tells you which
#       file was applied.  (man 5 systemd.network)
#
#     ---- ifupdown (classic Debian /etc/network/interfaces) ----------------
#
#       cat > /etc/network/interfaces <<'EOF'
#       source /etc/network/interfaces.d/*
#
#       auto lo
#       iface lo inet loopback
#
#       auto eth0
#       iface eth0 inet dhcp
#       EOF
#
#       # Static variant:
#       #   auto eth0
#       #   iface eth0 inet static
#       #       address 192.168.122.50/24
#       #       gateway 192.168.122.1
#       #       dns-nameservers 192.168.122.1
#
#       ifdown eth0 ; ifup eth0
#       # or: systemctl restart networking
#
#       The `auto eth0` line is what makes it come up at boot; `allow-hotplug
#       eth0` does it on device appearance instead. Without either, the stanza
#       is inert -- that was the injected fault.  (man 5 interfaces)
#
#     ---- netplan (Ubuntu Server, a front-end over NM or networkd) ---------
#
#       Edit /etc/netplan/*.yaml, then:
#         netplan generate && netplan apply
#       netplan does not configure anything itself; it renders unit files for
#       the backend named in `renderer:`. Check the rendered output under
#       /run/systemd/network/ before blaming the YAML.
#
#   Checkpoint:
#       ip -4 addr show eth0
#       ip route            # a 'default via <gw>' line must be present
#       ping -c2 <gateway>
#       ping -c2 1.1.1.1    # layer 3 to the outside, still no DNS involved
#
# ----------------------------------------------------------------------------
# STEP 2 -- The resolver: /etc/resolv.conf
# ----------------------------------------------------------------------------
#
#   Symptom: `ping 1.1.1.1` works but `ping deb.debian.org` says
#   "Temporary failure in name resolution".
#
#     cat /etc/resolv.conf
#     ls -l /etc/resolv.conf         # a symlink? then something else owns it
#
#   The file is a plain list of directives read by the glibc stub resolver:
#     nameserver <ip>     up to three, tried in order
#     search <domain...>  suffixes appended to unqualified names
#     domain <domain>     legacy single-suffix form
#     options timeout:2 attempts:2 ndots:1
#   (man 5 resolv.conf)
#
#   2a. If it is an immutable file (LAB_HARD mode):
#         lsattr /etc/resolv.conf        # shows ----i---------
#         chattr -i /etc/resolv.conf
#
#   2b. Who owns it? Three common answers:
#
#       * Nobody -- a real file you may edit directly:
#           printf 'nameserver 192.168.122.1\nnameserver 1.1.1.1\n' > /etc/resolv.conf
#
#       * NetworkManager -- it rewrites the file from the active profile.
#         Editing by hand is undone on the next connection change. Fix the
#         profile instead:
#           nmcli con mod "$CON" ipv4.dns "192.168.122.1 1.1.1.1"
#           nmcli con mod "$CON" ipv4.ignore-auto-dns no    # or 'yes' + explicit dns
#           nmcli con up "$CON"
#
#       * systemd-resolved -- /etc/resolv.conf is a symlink to
#         /run/systemd/resolve/stub-resolv.conf and points at 127.0.0.53.
#         The real setting is elsewhere:
#           resolvectl status                       # per-link DNS servers
#           $EDITOR /etc/systemd/resolved.conf      # [Resolve] DNS= / FallbackDNS=
#           systemctl restart systemd-resolved
#           resolvectl query deb.debian.org
#           resolvectl flush-caches                 # a stale negative cache lies to you
#         If the lab poisoned resolved.conf, set DNS= back to your real resolver
#         (or comment it out entirely so the per-link DHCP servers are used),
#         and restore the symlink if you deleted it:
#           ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
#
#   Checkpoint:
#       getent ahostsv4 deb.debian.org
#       dig +short deb.debian.org          # or: host deb.debian.org
#
# ----------------------------------------------------------------------------
# STEP 3 -- The name service switch: /etc/nsswitch.conf
# ----------------------------------------------------------------------------
#
#   Symptom that gives this one away: you add a line to /etc/hosts and it has
#   no effect whatsoever -- and `getent hosts localhost` also returns nothing.
#
#     grep ^hosts: /etc/nsswitch.conf
#     hosts:          dns                <-- the fault: /etc/hosts is never read
#
#   Restore the normal order, files first:
#
#     hosts:          files dns
#
#   or, on a systemd box that also wants mDNS and the magic self-name module:
#
#     hosts:          files mymachines myhostname resolve [!UNAVAIL=return] dns
#
#   No daemon restart is needed -- nsswitch.conf is consulted by the glibc
#   NSS machinery per lookup -- but long-lived processes may have cached the
#   old configuration, so re-test in a fresh shell.  (man 5 nsswitch.conf)
#
#   Note `myhostname`: that NSS module resolves the local hostname without any
#   /etc/hosts entry, which is why some distributions survive step 4 by
#   accident. Do not rely on it in the exam; LPI expects the /etc/hosts entry.
#
#   Checkpoint:
#       getent hosts localhost         # must print 127.0.0.1 localhost
#
# ----------------------------------------------------------------------------
# STEP 4 -- Identity: /etc/hostname and /etc/hosts
# ----------------------------------------------------------------------------
#
#   Symptom: `sudo: unable to resolve host broken-node: Name or service not
#   known`, plus a multi-second pause on every sudo (that pause is the DNS
#   timeout for a name that only exists locally).
#
#   4a. Persistent hostname. Two equivalent routes:
#
#         hostnamectl set-hostname lab-vm01        # systemd: writes /etc/hostname
#                                                  # AND sets the running name
#       or the portable pair:
#         echo 'lab-vm01' > /etc/hostname          # persistent, read at boot
#         hostname lab-vm01                        # runtime, immediate
#
#       `hostname lab-vm01` alone is the trap: correct now, gone after reboot.
#       `echo > /etc/hostname` alone is the mirror trap: correct after reboot,
#       still broken now. hostnamectl does both, which is why it is preferred.
#
#         hostnamectl status        # static / transient / pretty hostname
#
#   4b. Map the name to a local address, so lookups never leave the box:
#
#         cat /etc/hosts
#         127.0.0.1       localhost
#         127.0.1.1       lab-vm01.example.lan lab-vm01
#         ::1             localhost ip6-localhost ip6-loopback
#
#       Format: <address> <canonical-name> [aliases...]  (man 5 hosts)
#       Debian convention is 127.0.1.1 for the machine's own name; RHEL puts
#       the name on the 127.0.0.1 line or on the real LAN address. Either is
#       accepted -- what matters is that the running hostname resolves.
#
#   Checkpoint:
#       hostname; cat /etc/hostname          # must agree
#       getent hosts "$(hostname)"           # must return an address
#       sudo true                            # must be instant, no warning
#
# ----------------------------------------------------------------------------
# STEP 5 -- Prove persistence. This is the graded part.
# ----------------------------------------------------------------------------
#
#     sudo /path/to/this-script.sh verify     # runs a simulated reboot
#     sudo reboot
#     # after it comes back:
#     ip -4 -br addr ; ip route ; hostname ; getent hosts deb.debian.org
#     sudo /path/to/this-script.sh verify
#
#   If something reverts across the reboot, the fix went into runtime state.
#   Map each symptom back to its persistent home:
#
#     address / route revert  -> profile or unit file, and whether it is set to
#                                auto-start (NM connection.autoconnect,
#                                ifupdown `auto`, networkd unit present & matching)
#     hostname reverts        -> /etc/hostname (or hostnamectl, which writes it)
#     resolv.conf reverts     -> it is generated: fix the generator
#                                (NM ipv4.dns / systemd-resolved DNS=), not the file
#     /etc/hosts ignored      -> /etc/nsswitch.conf hosts: line
#
# ----------------------------------------------------------------------------
# Command reference for this objective
# ----------------------------------------------------------------------------
#
#   Runtime   : ip link | ip addr | ip route | ip neigh, hostname,
#               ifconfig / route / arp (deprecated net-tools, still examinable)
#   Persistent: /etc/hostname, /etc/hosts, /etc/nsswitch.conf, /etc/resolv.conf,
#               /etc/network/interfaces(.d), /etc/systemd/network/*.network,
#               /etc/NetworkManager/system-connections/*, /etc/netplan/*.yaml
#   Tools     : hostnamectl, nmcli, nmtui, networkctl, resolvectl, netplan,
#               ifup / ifdown, dhclient, getent, host, dig
#   Read      : man 5 hosts, man 5 resolv.conf, man 5 nsswitch.conf,
#               man 5 interfaces, man 5 systemd.network, man 1 nmcli,
#               man 1 hostnamectl, man 8 ip
#
# ----------------------------------------------------------------------------
# Sources
# ----------------------------------------------------------------------------
#   LPI Exam 101-500 objectives -- https://www.lpi.org/our-certifications/exam-101-objectives/
#   LPI Exam 102-500 objectives -- https://www.lpi.org/our-certifications/exam-102-objectives/
#   systemd.network(5)          -- https://www.freedesktop.org/software/systemd/man/systemd.network.html
#   systemd-resolved(8)         -- https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html
#   hostnamectl(1)              -- https://www.freedesktop.org/software/systemd/man/hostnamectl.html
#   nmcli(1)                    -- https://networkmanager.dev/docs/api/latest/nmcli.html
#   NetworkManager settings     -- https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html
#   interfaces(5), Debian       -- https://manpages.debian.org/stable/ifupdown/interfaces.5.en.html
#   Netplan reference           -- https://netplan.readthedocs.io/en/stable/netplan-yaml/
#   RFC 5737, reserved test IPv4 -- https://www.rfc-editor.org/rfc/rfc5737
# ============================================================================