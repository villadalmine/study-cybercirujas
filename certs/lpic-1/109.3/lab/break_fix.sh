#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1  (exams 101-500 / 102-500, version 5.0)
#  Topic 109.3 - Basic network troubleshooting
#  Break & Fix laboratory driver
# =============================================================================
#
#  WHAT THIS IS
#    A controlled fault injector for a DISPOSABLE lab VM. It breaks exactly one
#    network subsystem at a time, in RAM only (no unit files rewritten, nothing
#    made persistent), tells the student the symptom they will observe and the
#    objective they must reach, and can verify their repair.
#
#  WHAT THIS IS NOT
#    It is not a hardening tool, not a persistence mechanism and not something
#    you run on a machine you care about. Every fault is reversible with
#    --restore, and a dead-man timer restores automatically after N minutes so
#    a student working over SSH cannot permanently lock themselves out.
#
#  USAGE
#    sudo ./109.3-break-and-fix.sh --list
#    sudo ./109.3-break-and-fix.sh --break 3            # inject scenario 3
#    sudo ./109.3-break-and-fix.sh --break random       # instructor mode
#    sudo ./109.3-break-and-fix.sh --status             # what is broken, timer
#    sudo ./109.3-break-and-fix.sh --hint               # progressive hints
#    sudo ./109.3-break-and-fix.sh --verify             # grade the repair
#    sudo ./109.3-break-and-fix.sh --restore            # undo everything
#
#  Reference (exam objectives):
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#    https://www.lpi.org/our-certifications/exam-102-objectives/
#
#  The full, step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until you have spent real time with ip(8), ss(8),
#  dig(1), getent(1) and tcpdump(8).
# =============================================================================

set -uo pipefail

SELF="$(readlink -f "$0")"
STATE_DIR="/var/tmp/lpic1-109.3-breakfix"
BACKUP_DIR="${STATE_DIR}/backup"
STATE_ENV="${STATE_DIR}/state.env"
HINT_FILE="${STATE_DIR}/hints_shown"
DEADMAN_PID="${STATE_DIR}/deadman.pid"

MARKER="# LPIC1-BREAKFIX-109.3"
FW_CHAIN="LPIC1BF"
FW_TABLE="lpic1bf"
PROBE_HOST="deb.debian.org"
BLACKHOLE_GW="192.0.2.254"      # TEST-NET-1, RFC 5737 - never routable
BLACKHOLE_DNS="203.0.113.53"    # TEST-NET-3, RFC 5737 - never answers
POISON_IP="198.51.100.66"       # TEST-NET-2, RFC 5737

DEADMAN_MIN=30
QUIET=0
ASSUME_YES=0
FORCE_SSH=0

SCENARIO_COUNT=6

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
    C_Y=$'\033[33m'; C_C=$'\033[36m'
else
    C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

log()  { [ "$QUIET" -eq 1 ] || printf '%s[ lab ]%s %s\n' "$C_C" "$C_RST" "$*"; }
warn() { printf '%s[ warn ]%s %s\n' "$C_Y" "$C_RST" "$*" >&2; }
ok()   { printf '%s[ pass ]%s %s\n' "$C_G" "$C_RST" "$*"; }
bad()  { printf '%s[ fail ]%s %s\n' "$C_R" "$C_RST" "$*"; }
die()  { printf '%s[ stop ]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }
rule() { [ "$QUIET" -eq 1 ] || printf '%s\n' "-------------------------------------------------------------------------------"; }

# -----------------------------------------------------------------------------
# Safety guards
# -----------------------------------------------------------------------------
need_root() {
    [ "$(id -u)" -eq 0 ] || die "root is required: re-run with sudo."
}

guard_lab() {
    if [ "$ASSUME_YES" -eq 1 ] || [ -f /etc/lpic1-lab ] || [ "${LPIC1_LAB:-no}" = "yes" ]; then
        return 0
    fi
    cat <<EOF
${C_B}This script will deliberately break networking on this machine.${C_RST}

Run it ONLY on a throw-away lab VM or container you can rebuild.
Everything it does is runtime-only (a reboot also undoes it), but a
misidentified host means a real outage.

Hostname : $(hostname -f 2>/dev/null || hostname)
Kernel   : $(uname -r)
Uptime   : $(uptime -p 2>/dev/null || true)
EOF
    read -r -p "Type LAB to confirm this host is disposable: " answer
    [ "$answer" = "LAB" ] || die "not confirmed - nothing was changed."
}

guard_ssh() {
    if [ -n "${SSH_CONNECTION:-}" ] && [ "$FORCE_SSH" -eq 0 ]; then
        warn "You are connected over SSH ($SSH_CONNECTION)."
        warn "Scenarios 1 and 6 cut the route your session is using; you will be"
        warn "disconnected and will need console access (or the dead-man timer)."
        warn "Re-run with --force-ssh if you have console access, or work from the console."
        die  "refusing to inject a fault over the session it would kill."
    fi
}

# -----------------------------------------------------------------------------
# Environment discovery
# -----------------------------------------------------------------------------
discover() {
    DEF_ROUTE="$(ip -4 route show default 2>/dev/null | head -n1)"
    IFACE="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$DEF_ROUTE")"
    GW="$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$DEF_ROUTE")"

    if [ -z "$IFACE" ]; then
        IFACE="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $2}')"
    fi
    [ -n "$IFACE" ] || die "no usable IPv4 interface found; is this host networked at all?"

    CIDR="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk 'NR==1{print $4}')"
    IPADDR="${CIDR%/*}"
    PREFIX="${CIDR#*/}"
}

firewall_flavour() {
    if command -v iptables >/dev/null 2>&1; then echo iptables
    elif command -v nft   >/dev/null 2>&1; then echo nft
    else echo none
    fi
}

# -----------------------------------------------------------------------------
# State / backup handling
# -----------------------------------------------------------------------------
init_state() {
    mkdir -p "$BACKUP_DIR"
    : > "$HINT_FILE"
    {
        echo "SCENARIO=$1"
        echo "IFACE=$IFACE"
        echo "GW=$GW"
        echo "CIDR=$CIDR"
        echo "IPADDR=$IPADDR"
        echo "PREFIX=$PREFIX"
        echo "DEF_ROUTE='$DEF_ROUTE'"
        echo "BROKEN_AT=$(date -Iseconds)"
    } > "$STATE_ENV"
}

backup_file() {
    local path="$1" name
    name="$(basename "$path")"
    if [ -L "$path" ]; then
        echo "SYMLINK_${name//./_}=$(readlink -f "$path")" >> "$STATE_ENV"
        echo "WASLINK_${name//./_}=yes" >> "$STATE_ENV"
    fi
    [ -e "$path" ] && cp -a --dereference "$path" "${BACKUP_DIR}/${name}" 2>/dev/null
    return 0
}

restore_file() {
    local path="$1" name link_var was_var
    name="$(basename "$path")"
    link_var="SYMLINK_${name//./_}"
    was_var="WASLINK_${name//./_}"
    [ -f "${BACKUP_DIR}/${name}" ] || return 0
    if [ "${!was_var:-no}" = "yes" ]; then
        rm -f "$path"
        ln -s "${!link_var}" "$path"
    else
        cp -a "${BACKUP_DIR}/${name}" "$path"
    fi
    log "restored $path"
}

# -----------------------------------------------------------------------------
# Dead-man timer - guarantees the VM heals itself
# -----------------------------------------------------------------------------
arm_deadman() {
    [ "$DEADMAN_MIN" -gt 0 ] || { log "dead-man timer disabled"; return 0; }
    local secs=$((DEADMAN_MIN * 60))
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup bash -c "sleep $secs; '$SELF' --restore --quiet" >/dev/null 2>&1 &
    else
        nohup bash -c "sleep $secs; '$SELF' --restore --quiet" >/dev/null 2>&1 &
    fi
    echo $! > "$DEADMAN_PID"
    echo "DEADLINE=$(( $(date +%s) + secs ))" >> "$STATE_ENV"
    log "dead-man timer armed: everything is restored automatically in ${DEADMAN_MIN} min"
}

disarm_deadman() {
    if [ -f "$DEADMAN_PID" ]; then
        kill "$(cat "$DEADMAN_PID")" 2>/dev/null
        rm -f "$DEADMAN_PID"
    fi
}

# =============================================================================
#  SCENARIOS - each one has break_N, brief_N, hints_N, verify_N
# =============================================================================

# --- 1. Default route pointing at a black hole -------------------------------
break_1() {
    backup_file /etc/resolv.conf
    ip route replace default via "$BLACKHOLE_GW" dev "$IFACE" onlink \
        || die "could not replace the default route"
    ip neigh flush dev "$IFACE" 2>/dev/null
}
brief_1() {
cat <<EOF
${C_B}SCENARIO 1 - "the internet is down, but the LAN is fine"${C_RST}

Symptom you will see
  ping ${BLACKHOLE_GW%.*}.1 or any public address fails immediately or with
  "Destination Host Unreachable"; hosts on your own subnet still answer;
  name resolution appears to hang because the resolver itself is off-subnet.
  traceroute dies at the first hop.

  \$ ping -c2 1.1.1.1
  From ${IPADDR} icmp_seq=1 Destination Host Unreachable

Your objective
  Restore reachability of anything outside the local subnet, without rebooting
  and without touching persistent configuration. When you are done,
  ping -c2 1.1.1.1 must answer and traceroute must leave your network.

Tools that matter here
  ip route show / ip -br addr / ip neigh / ping -c / traceroute / tracepath / mtr
EOF
}
hints_1=(
"Layer by layer: is the interface up with an address? ip -br addr show"
"Compare 'ip route show' with what a working host of the same subnet shows. Which gateway is listed, and is it even inside your subnet?"
"'ip neigh show' proves the gateway never answered ARP - the address is a fiction. Put the real one back with: ip route replace default via <real-gw> dev <iface>"
)
verify_1() {
    local cur
    cur="$(ip -4 route show default | head -n1)"
    if grep -q "$BLACKHOLE_GW" <<<"$cur"; then
        bad "the default route still points at the black hole: $cur"; return 1
    fi
    if [ -z "$cur" ]; then bad "there is no default route at all"; return 1; fi
    ok "default route present: $cur"
    if ping -c2 -W2 1.1.1.1 >/dev/null 2>&1; then ok "off-subnet ICMP works"
    else warn "route is sane but 1.1.1.1 does not answer - offline lab? check with your instructor"; fi
    return 0
}

# --- 2. Resolver pointed at a dead nameserver --------------------------------
break_2() {
    backup_file /etc/resolv.conf
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
${MARKER}
nameserver ${BLACKHOLE_DNS}
options timeout:2 attempts:2
EOF
}
brief_2() {
cat <<EOF
${C_B}SCENARIO 2 - "names do not resolve, addresses do"${C_RST}

Symptom you will see
  \$ ping -c1 ${PROBE_HOST}
  ping: ${PROBE_HOST}: Temporary failure in name resolution
  \$ ping -c1 1.1.1.1
  64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=11.2 ms

  Every query stalls a couple of seconds before failing. apt/dnf/curl all hang
  the same way.

Your objective
  Make forward and reverse resolution work again on this host. getent hosts
  ${PROBE_HOST} must return an address, and dig must show a real ANSWER
  section. Explain, in one sentence, why ping by IP kept working the whole time.

Tools that matter here
  cat /etc/resolv.conf / resolvectl status / dig / dig @<server> / host /
  getent hosts / getent ahostsv4 / ss -u -a
EOF
}
hints_2=(
"Resolution and routing are separate problems. Which one is actually failing here?"
"Read /etc/resolv.conf. Then query the listed server directly: dig @<that-ip> ${PROBE_HOST} - does it even reply?"
"${BLACKHOLE_DNS} is RFC 5737 documentation space; nothing lives there. Point the resolver at a nameserver that exists (your gateway, or 1.1.1.1). If /etc/resolv.conf is a symlink into systemd-resolved, fix it with resolvectl / the .network file instead of clobbering the link."
)
verify_2() {
    if grep -q "$BLACKHOLE_DNS" /etc/resolv.conf 2>/dev/null; then
        bad "/etc/resolv.conf still lists the dead server ${BLACKHOLE_DNS}"; return 1
    fi
    ok "the dead nameserver is gone from the resolver configuration"
    if getent ahostsv4 "$PROBE_HOST" >/dev/null 2>&1; then
        ok "getent resolves ${PROBE_HOST}"
    else
        warn "configuration looks clean but ${PROBE_HOST} still does not resolve - verify upstream DNS"
        return 1
    fi
    return 0
}

# --- 3. /etc/hosts poisoned --------------------------------------------------
break_3() {
    backup_file /etc/hosts
    printf '%s\n%s\t%s\n' "$MARKER" "$POISON_IP" "$PROBE_HOST" >> /etc/hosts
}
brief_3() {
cat <<EOF
${C_B}SCENARIO 3 - "DNS says one thing, the host says another"${C_RST}

Symptom you will see
  \$ ping -c1 ${PROBE_HOST}
  PING ${PROBE_HOST} (${POISON_IP}) 56(84) bytes of data.
  --- 100% packet loss ---
  \$ dig +short ${PROBE_HOST}
  <a completely different, correct address>

  curl and apt time out against that host only; every other name is fine.

Your objective
  Make the host resolve ${PROBE_HOST} to the same address DNS returns.
  Then be able to state the rule that decides which source wins.

Tools that matter here
  getent hosts / dig +short / host / cat /etc/hosts / cat /etc/nsswitch.conf
EOF
}
hints_3=(
"dig talks to DNS directly. ping goes through the NSS resolver. They disagree - so something answers before DNS does."
"Read /etc/nsswitch.conf: 'hosts: files dns'. 'files' means /etc/hosts, and it is consulted FIRST."
"Delete the bogus entry from /etc/hosts (look for the ${MARKER} tag) and re-test with getent hosts ${PROBE_HOST}."
)
verify_3() {
    if grep -q "$POISON_IP" /etc/hosts 2>/dev/null; then
        bad "/etc/hosts still maps ${PROBE_HOST} to ${POISON_IP}"; return 1
    fi
    ok "/etc/hosts no longer contains the poisoned entry"
    grep -q "$MARKER" /etc/hosts 2>/dev/null && warn "the lab marker comment is still there (harmless)"
    return 0
}

# --- 4. NSS hosts database missing dns ---------------------------------------
break_4() {
    backup_file /etc/nsswitch.conf
    if grep -qE '^[[:space:]]*hosts:' /etc/nsswitch.conf; then
        sed -i -E "s/^[[:space:]]*hosts:.*/hosts:          files            ${MARKER}/" /etc/nsswitch.conf
    else
        printf 'hosts:          files            %s\n' "$MARKER" >> /etc/nsswitch.conf
    fi
}
brief_4() {
cat <<EOF
${C_B}SCENARIO 4 - "dig works, everything else does not"${C_RST}

Symptom you will see
  \$ dig +short ${PROBE_HOST}          # correct answer, instantly
  \$ getent hosts ${PROBE_HOST}        # no output, exit status 2
  \$ ping ${PROBE_HOST}
  ping: ${PROBE_HOST}: Name or service not known

  /etc/resolv.conf is perfect. The nameserver is reachable and answers dig.
  Only the machine's own programs cannot resolve anything.

Your objective
  Make getent hosts and ping resolve names again. Then explain why dig was
  never affected - that distinction is the whole point of this scenario.

Tools that matter here
  dig / getent hosts / getent ahostsv4 / cat /etc/nsswitch.conf /
  ldd \$(which ping) / man 5 nsswitch.conf
EOF
}
hints_4=(
"dig is a DNS client and speaks to port 53 by itself. ping, curl and ssh call getaddrinfo(3) in libc. Two different code paths - only one is broken."
"getaddrinfo obeys /etc/nsswitch.conf. Read the 'hosts:' line and compare it with a healthy system."
"It should read 'hosts: files dns' (a systemd host may also list mymachines/resolve/myhostname). Restore the dns source and re-test with getent ahostsv4 ${PROBE_HOST}."
)
verify_4() {
    local line
    line="$(grep -E '^[[:space:]]*hosts:' /etc/nsswitch.conf 2>/dev/null | head -n1)"
    if ! grep -qE '\b(dns|resolve)\b' <<<"$line"; then
        bad "the hosts NSS line still has no dns source: ${line:-<missing>}"; return 1
    fi
    ok "NSS hosts line restored: $line"
    getent ahostsv4 "$PROBE_HOST" >/dev/null 2>&1 \
        && ok "getent resolves ${PROBE_HOST}" \
        || { warn "nsswitch looks right but resolution still fails - check /etc/resolv.conf too"; return 1; }
    return 0
}

# --- 5. Firewall silently dropping outbound DNS ------------------------------
break_5() {
    local fw; fw="$(firewall_flavour)"
    echo "FW=$fw" >> "$STATE_ENV"
    case "$fw" in
        iptables)
            iptables -w -N "$FW_CHAIN" 2>/dev/null
            iptables -w -F "$FW_CHAIN"
            iptables -w -A "$FW_CHAIN" -p udp --dport 53 -j DROP
            iptables -w -A "$FW_CHAIN" -p tcp --dport 53 -j REJECT --reject-with tcp-reset
            iptables -w -C OUTPUT -j "$FW_CHAIN" 2>/dev/null || iptables -w -I OUTPUT 1 -j "$FW_CHAIN"
            ;;
        nft)
            nft add table inet "$FW_TABLE"
            nft add chain inet "$FW_TABLE" out '{ type filter hook output priority 0 ; policy accept ; }'
            nft add rule inet "$FW_TABLE" out udp dport 53 drop
            nft add rule inet "$FW_TABLE" out tcp dport 53 reject
            ;;
        *) die "neither iptables nor nft is available; pick another scenario" ;;
    esac
}
brief_5() {
cat <<EOF
${C_B}SCENARIO 5 - "the resolver is correct and still nothing resolves"${C_RST}

Symptom you will see
  \$ ping -c1 ${PROBE_HOST}
  ping: ${PROBE_HOST}: Temporary failure in name resolution   # after a long pause
  \$ ping -c1 1.1.1.1                                          # works
  \$ cat /etc/resolv.conf                                      # looks perfect
  \$ dig ${PROBE_HOST}
  ;; connection timed out; no servers could be reached

  UDP queries vanish with no error at all. TCP queries fail instantly instead.
  That asymmetry is the clue.

Your objective
  Restore name resolution without changing /etc/resolv.conf, /etc/hosts or
  /etc/nsswitch.conf - all three are already correct. Find what is eating the
  packets, prove it, and remove only that.

Tools that matter here
  dig +short / dig +tcp / tcpdump -ni any port 53 / iptables -L -n -v --line-numbers
  iptables -S / nft list ruleset / ss -tunap / journalctl -k
EOF
}
hints_5=(
"Prove where the packet dies: run tcpdump -ni any port 53 in one terminal and dig in another. Does the query ever leave the interface?"
"DROP is silent, REJECT is loud. UDP hangs, TCP fails at once - that is a packet filter, not DNS."
"List the rules: iptables -S | grep -i ${FW_CHAIN}  (or nft list ruleset). Detach the jump from OUTPUT, then flush and delete the chain / table."
)
verify_5() {
    local fw; fw="$(firewall_flavour)"
    if [ "$fw" = iptables ] && iptables -w -S 2>/dev/null | grep -q "$FW_CHAIN"; then
        bad "the ${FW_CHAIN} chain is still referenced in the ruleset"; return 1
    fi
    if [ "$fw" = nft ] && nft list ruleset 2>/dev/null | grep -q "$FW_TABLE"; then
        bad "the inet ${FW_TABLE} table still exists"; return 1
    fi
    ok "the blocking ruleset is gone"
    getent ahostsv4 "$PROBE_HOST" >/dev/null 2>&1 \
        && ok "resolution works again" \
        || { warn "the filter is gone but resolution still fails - is the upstream server reachable?"; return 1; }
    return 0
}

# --- 6. Wrong netmask on the primary interface -------------------------------
break_6() {
    [ -n "$CIDR" ] || die "could not determine the current address of $IFACE"
    ip addr del "$CIDR" dev "$IFACE" || die "could not remove $CIDR from $IFACE"
    ip addr add "${IPADDR}/32" dev "$IFACE" || die "could not add ${IPADDR}/32"
    ip neigh flush dev "$IFACE" 2>/dev/null
}
brief_6() {
cat <<EOF
${C_B}SCENARIO 6 - "my address is right and I can reach nothing"${C_RST}

Symptom you will see
  \$ ip -br addr show ${IFACE}
  ${IFACE}   UP    ${IPADDR}/32
  \$ ping -c1 ${GW:-<gateway>}
  connect: Network is unreachable

  The address is exactly the one you expect. Even the gateway on your own
  segment is unreachable, and adding a default route fails outright.

Your objective
  Restore full connectivity: neighbours on the local segment, the gateway, and
  the internet. Note the original prefix length before you start guessing - it
  is in your DHCP lease or in the interface's persistent configuration.

Tools that matter here
  ip -br addr / ip addr add|del / ip route / ip neigh / ipcalc /
  cat /var/lib/dhcp/*.leases / nmcli con show / arping
EOF
}
hints_6=(
"'Network is unreachable' comes from the ROUTING table, not from the wire. Look at ip route show - which connected route disappeared?"
"A /32 tells the kernel that the only host on your link is yourself, so there is no on-link route to reach the gateway through."
"Recover the real prefix (DHCP lease, nmcli, another host on the segment), then: ip addr del ${IPADDR}/32 dev ${IFACE} && ip addr add ${CIDR} dev ${IFACE} && ip route add default via ${GW} dev ${IFACE}"
)
verify_6() {
    local cur
    cur="$(ip -4 -o addr show dev "$IFACE" scope global | awk 'NR==1{print $4}')"
    if [ "$cur" = "${IPADDR}/32" ]; then bad "$IFACE still carries a /32"; return 1; fi
    if [ "$cur" != "$CIDR" ]; then warn "prefix is $cur, the original was $CIDR"; fi
    ok "interface address restored: $cur"
    if [ -n "$GW" ]; then
        ping -c2 -W2 "$GW" >/dev/null 2>&1 && ok "the gateway answers" || { bad "the gateway $GW does not answer"; return 1; }
    fi
    ip -4 route show default | grep -q . && ok "default route present" || { bad "no default route"; return 1; }
    return 0
}

# =============================================================================
#  Dispatcher
# =============================================================================
list_scenarios() {
cat <<EOF
${C_B}Topic 109.3 - available faults${C_RST}

  1  Default route pointing at a black hole      (routing)
  2  Resolver pointed at a dead nameserver       (name resolution)
  3  /etc/hosts poisoned                         (NSS source precedence)
  4  NSS hosts database missing 'dns'            (getaddrinfo vs dig)
  5  Firewall silently dropping outbound DNS     (packet filter)
  6  Wrong netmask on the primary interface      (addressing)

  random  - let the script choose (instructor mode: you get no scenario number)
EOF
}

do_break() {
    local n="$1"
    [ -f "$STATE_ENV" ] && die "a fault is already active. Run --status, then --restore first."

    if [ "$n" = random ]; then n=$(( (RANDOM % SCENARIO_COUNT) + 1 )); RANDOM_MODE=1; else RANDOM_MODE=0; fi
    [[ "$n" =~ ^[1-6]$ ]] || die "unknown scenario '$n' (see --list)"

    discover
    case "$n" in 1|6) guard_ssh ;; esac
    guard_lab

    init_state "$n"
    log "injecting scenario $n on ${IFACE} (${CIDR}, gw ${GW:-none})"
    "break_${n}"
    arm_deadman

    rule
    if [ "${RANDOM_MODE:-0}" -eq 1 ]; then
        cat <<EOF
${C_B}BLIND MODE${C_RST}

A single network fault has been injected. You are not being told which one.
Work the layers in order - link, address, route, filter, resolution - and
narrate what you rule out at each step:

  ip -br link ; ip -br addr ; ip route show ; ip neigh show
  ping -c2 <gateway> ; ping -c2 1.1.1.1
  getent hosts ${PROBE_HOST} ; dig +short ${PROBE_HOST}
  iptables -S | head -40   (or nft list ruleset)
  tcpdump -ni any port 53 or icmp

Run --hint for graduated hints, --verify to be graded, --restore to give up.
EOF
    else
        "brief_${n}"
        rule
        cat <<EOF
Grade yourself with:  sudo $SELF --verify
Undo everything with: sudo $SELF --restore
Automatic recovery in ${DEADMAN_MIN} minutes even if you do nothing.
EOF
    fi
    rule
}

do_status() {
    [ -f "$STATE_ENV" ] || { log "no fault is active."; return 0; }
    # shellcheck disable=SC1090
    . "$STATE_ENV"
    printf '%sActive fault%s\n' "$C_B" "$C_RST"
    printf '  scenario : %s\n  interface: %s\n  broken at: %s\n' "$SCENARIO" "$IFACE" "$BROKEN_AT"
    if [ -n "${DEADLINE:-}" ]; then
        local left=$(( DEADLINE - $(date +%s) ))
        if [ "$left" -gt 0 ]; then printf '  auto-fix : in %d min %d s\n' $((left/60)) $((left%60))
        else printf '  auto-fix : overdue - the timer should have fired\n'; fi
    fi
    printf '  hints used: %s\n' "$(wc -l < "$HINT_FILE" 2>/dev/null || echo 0)"
}

do_hint() {
    [ -f "$STATE_ENV" ] || die "no fault is active."
    # shellcheck disable=SC1090
    . "$STATE_ENV"
    local shown next arr
    shown="$(wc -l < "$HINT_FILE" 2>/dev/null || echo 0)"
    arr="hints_${SCENARIO}[@]"
    local -a hints=( "${!arr}" )
    next=$shown
    if [ "$next" -ge "${#hints[@]}" ]; then
        warn "no hints left. Read the commented solution at the bottom of $SELF."
        return 0
    fi
    printf '%sHint %d/%d:%s %s\n' "$C_B" $((next+1)) "${#hints[@]}" "$C_RST" "${hints[$next]}"
    echo "hint$((next+1))" >> "$HINT_FILE"
}

do_verify() {
    [ -f "$STATE_ENV" ] || die "no fault is active - nothing to verify."
    # shellcheck disable=SC1090
    . "$STATE_ENV"
    rule
    log "grading scenario ${SCENARIO}"
    if "verify_${SCENARIO}"; then
        rule
        ok "REPAIRED. Now write down, in your own words: what was the symptom, what"
        ok "command proved the cause, and which layer of the stack was at fault."
        ok "Then run --restore to clear the lab state file."
        return 0
    else
        rule
        bad "not fixed yet. Keep going, or run --hint."
        return 1
    fi
}

do_restore() {
    [ -f "$STATE_ENV" ] || { log "nothing to restore."; return 0; }
    # shellcheck disable=SC1090
    . "$STATE_ENV"
    disarm_deadman

    restore_file /etc/resolv.conf
    restore_file /etc/hosts
    restore_file /etc/nsswitch.conf

    # routing / addressing
    if [ -n "${IFACE:-}" ]; then
        local cur
        cur="$(ip -4 -o addr show dev "$IFACE" scope global | awk 'NR==1{print $4}')"
        if [ -n "${CIDR:-}" ] && [ "$cur" != "$CIDR" ]; then
            [ -n "$cur" ] && ip addr del "$cur" dev "$IFACE" 2>/dev/null
            ip addr add "$CIDR" dev "$IFACE" 2>/dev/null && log "restored $CIDR on $IFACE"
        fi
        ip link set "$IFACE" up 2>/dev/null
        if [ -n "${GW:-}" ]; then
            ip route replace default via "$GW" dev "$IFACE" 2>/dev/null && log "restored default via $GW"
        fi
        ip neigh flush dev "$IFACE" 2>/dev/null
    fi

    # firewall
    if command -v iptables >/dev/null 2>&1; then
        while iptables -w -C OUTPUT -j "$FW_CHAIN" 2>/dev/null; do
            iptables -w -D OUTPUT -j "$FW_CHAIN"
        done
        iptables -w -F "$FW_CHAIN" 2>/dev/null
        iptables -w -X "$FW_CHAIN" 2>/dev/null
    fi
    if command -v nft >/dev/null 2>&1; then
        nft list table inet "$FW_TABLE" >/dev/null 2>&1 && nft delete table inet "$FW_TABLE"
    fi

    rm -rf "$STATE_DIR"
    log "lab restored. Verify with: ip route show ; getent hosts ${PROBE_HOST}"
}

usage() {
cat <<EOF
LPIC-1 topic 109.3 - Basic network troubleshooting - break & fix lab

  --list                 show the available faults
  --break <1..6|random>  inject a fault
  --status               show what is active and how long until auto-recovery
  --hint                 reveal the next hint for the active fault
  --verify               grade the repair
  --restore              undo everything now
  --deadman <minutes>    auto-recovery delay (default ${DEADMAN_MIN}, 0 disables)
  --yes                  skip the "this is a lab" confirmation
  --force-ssh            allow faults that will cut your own SSH session
  --quiet                suppress informational output
EOF
}

main() {
    local action="" arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --list)      action=list ;;
            --break)     action=break; arg="${2:-}"; shift ;;
            --status)    action=status ;;
            --hint)      action=hint ;;
            --verify)    action=verify ;;
            --restore)   action=restore ;;
            --deadman)   DEADMAN_MIN="${2:-30}"; shift ;;
            --yes|-y)    ASSUME_YES=1 ;;
            --force-ssh) FORCE_SSH=1 ;;
            --quiet|-q)  QUIET=1 ;;
            -h|--help)   usage; exit 0 ;;
            *)           usage; die "unknown option: $1" ;;
        esac
        shift
    done

    case "$action" in
        list)    list_scenarios ;;
        break)   need_root; [ -n "$arg" ] || die "--break needs a scenario (see --list)"; do_break "$arg" ;;
        status)  do_status ;;
        hint)    need_root; do_hint ;;
        verify)  need_root; do_verify ;;
        restore) need_root; do_restore ;;
        *)       usage; exit 1 ;;
    esac
}

main "$@"

# =============================================================================
#  SOLUTION - do not read until you have finished the exercise
# =============================================================================
#
#  A method that works for all six, and for the exam:
#  go up the stack and stop at the first layer that lies to you.
#
#    1. Link      ip -br link show          state UP? carrier? (ethtool <if>)
#    2. Address   ip -br addr show          right IP *and* right prefix?
#    3. Neighbour ip neigh show             does the gateway answer ARP?
#    4. Route     ip route show             is there a default, and is the
#                                           gateway inside the local subnet?
#    5. Filter    iptables -S / nft list ruleset   anything DROPping?
#    6. Names     getent hosts X vs dig +short X   NSS and DNS disagree?
#    7. Sockets   ss -tulpn                 is the service even listening,
#                                           and on 0.0.0.0 or only 127.0.0.1?
#
# -----------------------------------------------------------------------------
#  SCENARIO 1 - default route pointing at a black hole
# -----------------------------------------------------------------------------
#   Diagnose
#     ip route show
#       default via 192.0.2.254 dev eth0 onlink       <-- not in our subnet
#       10.0.2.0/24 dev eth0 proto kernel scope link src 10.0.2.15
#     ip neigh show
#       192.0.2.254 dev eth0 FAILED                   <-- nobody answers ARP
#     ping -c2 1.1.1.1
#       From 10.0.2.15 icmp_seq=1 Destination Host Unreachable
#     traceroute 1.1.1.1     -> first hop is already * * *
#
#   Fix (runtime)
#     ip route replace default via 10.0.2.2 dev eth0
#     ping -c2 1.1.1.1
#
#   How to find the real gateway when you do not know it
#     grep -r routers /var/lib/dhcp/*.leases   |  nmcli -f IP4.GATEWAY dev show eth0
#     ip route show | awk '/proto kernel/{print $1}'   # your subnet; .1 or .254 is usual
#
#   Persistent form (survives a reboot; the lab deliberately did NOT touch these)
#     Debian /etc/network/interfaces:   gateway 10.0.2.2
#     NetworkManager:                   nmcli con mod "<name>" ipv4.gateway 10.0.2.2 && nmcli con up "<name>"
#     systemd-networkd:                 [Route] Gateway=10.0.2.2 in /etc/systemd/network/*.network
#
# -----------------------------------------------------------------------------
#  SCENARIO 2 - resolver pointed at a dead nameserver
# -----------------------------------------------------------------------------
#   Diagnose
#     ping -c1 deb.debian.org      -> Temporary failure in name resolution
#     ping -c1 1.1.1.1             -> works, so routing is fine
#     cat /etc/resolv.conf
#       nameserver 203.0.113.53
#     dig @203.0.113.53 deb.debian.org
#       ;; connection timed out; no servers could be reached
#     dig @1.1.1.1 deb.debian.org  -> answers instantly, so the network is fine
#
#   Fix
#     printf 'nameserver 1.1.1.1\nnameserver 10.0.2.2\n' > /etc/resolv.conf
#     getent hosts deb.debian.org
#
#   If /etc/resolv.conf is a symlink to /run/systemd/resolve/stub-resolv.conf,
#   do not overwrite the link - configure the real resolver instead:
#     resolvectl status
#     resolvectl dns eth0 1.1.1.1
#     resolvectl flush-caches
#
#   Why ping by IP still worked: getaddrinfo(3) never runs when the argument is
#   already an address literal. Only the name->address step was broken.
#
# -----------------------------------------------------------------------------
#  SCENARIO 3 - /etc/hosts poisoned
# -----------------------------------------------------------------------------
#   Diagnose
#     getent hosts deb.debian.org   -> 198.51.100.66 deb.debian.org
#     dig +short deb.debian.org     -> the correct public address
#     grep -n deb.debian.org /etc/hosts
#       12:198.51.100.66   deb.debian.org
#     grep ^hosts /etc/nsswitch.conf
#       hosts: files dns              <-- 'files' wins, and files is /etc/hosts
#
#   Fix
#     cp /etc/hosts /etc/hosts.bak
#     sed -i '/198\.51\.100\.66/d' /etc/hosts
#     sed -i '/LPIC1-BREAKFIX/d'   /etc/hosts
#     getent hosts deb.debian.org
#
#   Exam point: /etc/hosts has no TTL and no cache to flush - the change is
#   effective on the next call. Order in nsswitch.conf decides who answers.
#
# -----------------------------------------------------------------------------
#  SCENARIO 4 - NSS hosts database missing 'dns'
# -----------------------------------------------------------------------------
#   Diagnose
#     dig +short deb.debian.org     -> correct answer  (dig bypasses NSS)
#     getent hosts deb.debian.org   -> nothing, exit status 2
#     ping deb.debian.org           -> Name or service not known
#     grep ^hosts /etc/nsswitch.conf
#       hosts:  files                 <-- no dns source at all
#
#   Fix
#     sed -i -E 's/^hosts:.*/hosts:          files dns/' /etc/nsswitch.conf
#     getent ahostsv4 deb.debian.org
#   (on a systemd host the healthy line is usually:
#      hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns )
#
#   Why dig was unaffected: dig/nslookup/host are DNS clients that build their
#   own queries to port 53. ping/curl/ssh/apt call getaddrinfo(3) in glibc,
#   which consults /etc/nsswitch.conf first. A tool that resolves and a tool
#   that does not is nearly always an NSS problem, not a DNS problem.
#
# -----------------------------------------------------------------------------
#  SCENARIO 5 - firewall silently dropping outbound DNS
# -----------------------------------------------------------------------------
#   Diagnose
#     dig deb.debian.org
#       ;; connection timed out; no servers could be reached     (UDP: silent)
#     dig +tcp deb.debian.org
#       ;; communications error ... connection reset by peer      (TCP: instant)
#     # prove where the packet dies:
#     tcpdump -ni any port 53 &            # nothing leaves the interface
#     iptables -L OUTPUT -n -v --line-numbers
#       1  LPIC1BF  all -- *  *  0.0.0.0/0  0.0.0.0/0
#     iptables -S LPIC1BF
#       -A LPIC1BF -p udp -m udp --dport 53 -j DROP
#       -A LPIC1BF -p tcp -m tcp --dport 53 -j REJECT --reject-with tcp-reset
#
#   Fix (iptables)
#     iptables -D OUTPUT -j LPIC1BF
#     iptables -F LPIC1BF
#     iptables -X LPIC1BF
#     getent hosts deb.debian.org
#
#   Fix (nftables)
#     nft list ruleset | less
#     nft delete table inet lpic1bf
#
#   Reading the symptom: DROP discards without notice, so the client waits for
#   its timeout; REJECT sends an RST or an ICMP error, so it fails immediately.
#   "Hangs on UDP, fails fast on TCP" is a filter signature, and the counters in
#   iptables -L -n -v (pkts/bytes rising as you retry) confirm which rule.
#
# -----------------------------------------------------------------------------
#  SCENARIO 6 - wrong netmask on the primary interface
# -----------------------------------------------------------------------------
#   Diagnose
#     ip -br addr show eth0
#       eth0  UP   10.0.2.15/32                       <-- prefix is wrong
#     ip route show
#       (the 10.0.2.0/24 connected route is gone)
#     ping 10.0.2.2      -> connect: Network is unreachable
#     ip route add default via 10.0.2.2 dev eth0
#       Error: Nexthop has invalid gateway.
#
#   Recover the real prefix
#     grep -E 'subnet-mask|option routers' /var/lib/dhcp/*.leases
#     nmcli -f IP4.ADDRESS,IP4.GATEWAY dev show eth0
#     ipcalc 10.0.2.15/24        # confirm network, broadcast and usable range
#
#   Fix
#     ip addr del 10.0.2.15/32 dev eth0
#     ip addr add 10.0.2.15/24 dev eth0
#     ip route add default via 10.0.2.2 dev eth0
#     ping -c2 10.0.2.2 && ping -c2 1.1.1.1
#     # or simply let the DHCP client redo it:  dhclient -r eth0 && dhclient eth0
#
#   Why the whole network died from a netmask: the prefix is what creates the
#   on-link (connected) route. With /32 the kernel believes the only host on the
#   segment is itself, so it has no interface route through which to ARP for the
#   gateway - hence "Network is unreachable" from the routing layer, before a
#   single packet is ever sent.
#
# -----------------------------------------------------------------------------
#  Sources
#    LPI exam 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
#    LPI exam 102-500 objectives: https://www.lpi.org/our-certifications/exam-102-objectives/
#    ip(8), ip-route(8), ip-address(8): https://man7.org/linux/man-pages/man8/ip.8.html
#    nsswitch.conf(5): https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
#    resolv.conf(5):   https://man7.org/linux/man-pages/man5/resolv.conf.5.html
#    ss(8):            https://man7.org/linux/man-pages/man8/ss.8.html
#    nftables wiki:    https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
#    RFC 5737 (documentation address blocks): https://www.rfc-editor.org/rfc/rfc5737
# =============================================================================