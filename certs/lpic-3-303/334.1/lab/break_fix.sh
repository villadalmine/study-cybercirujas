#!/usr/bin/env bash
#
# =============================================================================
#  teach-plat :: LPIC-3 303 (exam 303-300, version 3.0.0)
#  Topic 334.1 -- Network Hardening   (exam weight: 6.67)
#  Break & Fix laboratory
# =============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It introduces three *controlled*, *reversible* network-hardening regressions
#  into a DISPOSABLE lab VM, prints the symptom the student will observe, the
#  success criteria, and installs a machine-checkable verifier. It does NOT
#  print the fix: the full step-by-step solution is at the bottom of this file,
#  commented out.
#
#  FAULT 1  FreeRADIUS network-node authentication is broken in two places
#           (shared secret mismatch + wrong operator on the known-good password)
#  FAULT 2  A rogue IPv6 Router Advertisement poisons a host whose RA-related
#           sysctls have been un-hardened (contained in a network namespace)
#  FAULT 3  A service that must be loopback-only is listening on 0.0.0.0 and
#           serving cleartext credentials -- discoverable with nmap/ss/tcpdump
#
#  BLAST RADIUS / SAFETY MODEL
#  ---------------------------
#  * Root namespace routing is NEVER touched. The rogue Router Advertiser and
#    its victim both live inside dedicated network namespaces connected by a
#    veth pair whose two ends are BOTH moved out of the root namespace, so no
#    RA can reach the VM's real NIC, its neighbours, or the lab LAN.
#  * IPv4 sysctl weakenings ARE applied host-wide (that is the realistic
#    regression an auditor must catch), but only knobs that degrade security
#    without dropping the SSH session you are working from.
#  * Every file mutated is copied to /var/lib/lab-334-1/backup/ first.
#  * Nothing listens on a privileged port; the exposed service is on 8081/tcp.
#
#  REFERENCES (official)
#  ---------------------
#  LPI 303-300 objectives ..... https://www.lpi.org/our-certifications/exam-303-objectives/
#  FreeRADIUS documentation ... https://www.freeradius.org/documentation/freeradius-server/3.2.0/
#  Kernel network sysctls ..... https://docs.kernel.org/networking/ip-sysctl.html
#  Nmap reference guide ....... https://nmap.org/book/man.html
#  tcpdump manual ............. https://www.tcpdump.org/manpages/tcpdump.1.html
#  radvd manual ............... https://radvd.litech.org/man/radvd.conf.5.html
#  RFC 6104 Rogue RA problem .. https://www.rfc-editor.org/rfc/rfc6104
#  RFC 6105 IPv6 RA Guard ..... https://www.rfc-editor.org/rfc/rfc6105
#
# =============================================================================

set -Eeuo pipefail
trap 'printf "\n[FATAL] %s failed at line %s (exit %s)\n" "${BASH_SOURCE[0]}" "$LINENO" "$?" >&2' ERR

# ----------------------------------------------------------------------------- 
# Constants
# -----------------------------------------------------------------------------
LAB_ID="334.1"
LAB_TAG="lab-334-1"
STATE_DIR="/var/lib/${LAB_TAG}"
BACKUP_DIR="${STATE_DIR}/backup"
CONF_DIR="/etc/${LAB_TAG}"
DOCROOT="/srv/${LAB_TAG}"
LOGFILE="/var/log/${LAB_TAG}.log"
MISSION="${STATE_DIR}/mission.txt"
VERIFY_BIN="/usr/local/bin/${LAB_TAG}-verify"

SYSCTL_HOST_DROPIN="/etc/sysctl.d/99-${LAB_TAG}-host.conf"
SYSCTL_NS_FILE="${CONF_DIR}/victim-ns.sysctl.conf"
RADVD_CONF="${CONF_DIR}/radvd-rogue.conf"
RADVD_PID="/run/${LAB_TAG}-radvd.pid"
RADVD_LOG="/var/log/${LAB_TAG}-radvd.log"

NS_ROGUE="lab3341-rogue"
NS_VICTIM="lab3341-victim"
VETH_ROGUE="veth-r"
VETH_VICTIM="veth-v"
ROGUE_PREFIX="2001:db8:bad:c0de::/64"
ROGUE_ADDR="2001:db8:bad:c0de::1/64"

EXPOSED_PORT="8081"
EXPOSED_UNIT="${LAB_TAG}-inventory.service"

RAD_USER="labuser"
RAD_PASS="L4bP4ss-334"
RAD_SECRET="testing123"          # what the (simulated) NAS is provisioned with
RAD_BAD_SECRET="R4d-L4b-BADSECRET"

# Populated by detect_freeradius()
RADDB=""; RAD_BIN=""; RAD_SVC=""; RAD_USERS=""

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
  C_B=$'\033[1;34m'; C_D=$'\033[2m';    C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

say()  { printf '%s[*]%s %s\n'  "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n'  "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$C_R" "$C_0" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$C_D" "-------------------------------------------------------------------------------" "$C_0"; }

usage() {
  cat <<USAGE
Usage: ${0##*/} [--force] [--help]

  --force   Skip the interactive confirmation (also: LAB_FORCE=yes).
  --help    Show this help.

Run ONLY on a disposable lab VM. Requires root.
USAGE
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
FORCE="${LAB_FORCE:-no}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root (the lab edits sysctls, systemd units and /etc/raddb)"
  [[ -f /etc/teach-plat-production ]] && die "refusing to run: /etc/teach-plat-production marker present"
  command -v ip >/dev/null       || die "iproute2 is required (ip(8) not found)"
  command -v systemctl >/dev/null|| warn "systemd not detected -- fault 3 will fall back to a plain background process"
  [[ -d /proc/sys/net/ipv6 ]]    || warn "IPv6 stack disabled in the kernel -- fault 2 will be skipped"

  if [[ -f "${STATE_DIR}/BROKEN" ]]; then
    warn "this lab is already broken (state file ${STATE_DIR}/BROKEN)."
    warn "re-running will re-apply the faults on top of your repairs."
  fi

  if [[ "$FORCE" != "yes" ]]; then
    [[ -t 0 ]] || die "non-interactive shell: re-run with --force (or LAB_FORCE=yes) to confirm"
    rule
    printf '%sTHIS SCRIPT INTENTIONALLY WEAKENS THIS MACHINE.%s\n' "$C_R" "$C_0"
    printf 'It will modify: %s, %s, a FreeRADIUS config, and start a service on 0.0.0.0:%s.\n' \
           "$SYSCTL_HOST_DROPIN" "/etc/{raddb,freeradius}" "$EXPOSED_PORT"
    printf 'Use a snapshot. Never run it on anything you care about.\n'
    rule
    read -r -p "Type BREAK to continue: " answer
    [[ "$answer" == "BREAK" ]] || die "aborted by operator"
  fi
}

# -----------------------------------------------------------------------------
# Package handling (best effort -- every fault feature-detects afterwards)
# -----------------------------------------------------------------------------
PKG=""
detect_pkg_manager() {
  for m in apt-get dnf yum zypper pacman; do
    command -v "$m" >/dev/null 2>&1 && { PKG="$m"; return 0; }
  done
  PKG=""
}

pkg_install() {
  [[ -n "$PKG" ]] || { warn "no known package manager -- install manually: $*"; return 0; }
  say "installing (best effort): $*"
  case "$PKG" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >>"$LOGFILE" 2>&1 || true ;;
    dnf|yum) "$PKG" install -y -q "$@"                                 >>"$LOGFILE" 2>&1 || true ;;
    zypper)  zypper --non-interactive --quiet install "$@"             >>"$LOGFILE" 2>&1 || true ;;
    pacman)  pacman -Sy --noconfirm --needed "$@"                      >>"$LOGFILE" 2>&1 || true ;;
  esac
}

install_dependencies() {
  detect_pkg_manager
  [[ "$PKG" == "apt-get" ]] && { apt-get update -qq >>"$LOGFILE" 2>&1 || true; }
  case "$PKG" in
    apt-get) pkg_install freeradius freeradius-utils nmap tcpdump radvd iproute2 python3 ;;
    dnf|yum) pkg_install freeradius freeradius-utils nmap tcpdump radvd iproute  python3 ;;
    zypper)  pkg_install freeradius-server freeradius-server-utils nmap tcpdump radvd iproute2 python3 ;;
    pacman)  pkg_install freeradius nmap tcpdump radvd iproute2 python ;;
  esac
}

# -----------------------------------------------------------------------------
# FAULT 1 -- FreeRADIUS: shared secret mismatch + wrong known-good-password operator
# -----------------------------------------------------------------------------
detect_freeradius() {
  local d
  for d in /etc/freeradius/3.2 /etc/freeradius/3.0 /etc/freeradius /etc/raddb; do
    [[ -f "$d/clients.conf" ]] && { RADDB="$d"; break; }
  done
  [[ -n "$RADDB" ]] || return 1

  if   command -v freeradius >/dev/null 2>&1; then RAD_BIN="freeradius"
  elif command -v radiusd    >/dev/null 2>&1; then RAD_BIN="radiusd"
  else return 1; fi

  local s
  for s in freeradius radiusd; do
    systemctl cat "${s}.service" >/dev/null 2>&1 && { RAD_SVC="$s"; break; }
  done

  if   [[ -f "$RADDB/mods-config/files/authorize" ]]; then RAD_USERS="$RADDB/mods-config/files/authorize"
  elif [[ -f "$RADDB/users" ]];                       then RAD_USERS="$RADDB/users"
  else return 1; fi
  return 0
}

break_freeradius() {
  say "FAULT 1 :: FreeRADIUS node authentication"

  if ! detect_freeradius; then
    warn "FreeRADIUS not usable on this host -- FAULT 1 skipped."
    warn "install it and re-run: freeradius / freeradius-server + freeradius-utils"
    echo "skipped" > "${STATE_DIR}/fault1.state"
    return 0
  fi
  say "  raddb=$RADDB  binary=$RAD_BIN  service=${RAD_SVC:-<none>}  users=$RAD_USERS"

  install -d -m 0750 "${BACKUP_DIR}"
  cp -a "$RADDB/clients.conf" "${BACKUP_DIR}/clients.conf.orig"
  cp -a "$RAD_USERS"          "${BACKUP_DIR}/authorize.orig"

  # 1a) Shared secret mismatch: the NAS profile says "testing123", the server no
  #     longer agrees. Everything else stays valid, so the daemon starts fine.
  sed -i "s/^\([[:space:]]*secret[[:space:]]*=[[:space:]]*\)${RAD_SECRET}[[:space:]]*$/\1${RAD_BAD_SECRET}/" \
      "$RADDB/clients.conf"
  if grep -q "$RAD_BAD_SECRET" "$RADDB/clients.conf"; then
    ok "  clients.conf: shared secret for the localhost client desynchronised"
  else
    warn "  clients.conf: no 'secret = ${RAD_SECRET}' line found; secret left untouched"
  fi

  # 1b) The lab user exists, but the known-good password is declared with the
  #     comparison operator '==' instead of the assignment operator ':='.
  #     rlm_files therefore never adds Cleartext-Password to the control list,
  #     rlm_pap finds no known-good password, and no Auth-Type is ever set.
  if ! grep -q "^${RAD_USER}[[:space:]]" "$RAD_USERS"; then
    local tmp; tmp="$(mktemp)"
    {
      printf '# --- %s BEGIN (lab entry, do not ship) ---\n' "$LAB_TAG"
      printf '%s\tCleartext-Password == "%s"\n' "$RAD_USER" "$RAD_PASS"
      printf '\tReply-Message := "334.1 lab access granted for %%{User-Name}"\n'
      printf '# --- %s END ---\n\n' "$LAB_TAG"
      cat "$RAD_USERS"
    } > "$tmp"
    cat "$tmp" > "$RAD_USERS"     # rewrite in place: keeps owner/group/mode
    rm -f "$tmp"
    ok "  ${RAD_USERS##*/}: user '${RAD_USER}' declared with a non-assigning operator"
  else
    warn "  user '${RAD_USER}' already present in ${RAD_USERS} -- left as is"
  fi

  # The daemon must be RUNNING and broken, not dead: a dead daemon is a
  # different (easier) exercise.
  if "$RAD_BIN" -XC >>"$LOGFILE" 2>&1; then
    ok "  configuration still parses (${RAD_BIN} -XC returned 0)"
  else
    warn "  ${RAD_BIN} -XC returned non-zero; see $LOGFILE"
  fi
  if [[ -n "$RAD_SVC" ]]; then
    systemctl enable --now "$RAD_SVC" >>"$LOGFILE" 2>&1 || true
    systemctl restart "$RAD_SVC"      >>"$LOGFILE" 2>&1 || warn "  could not restart ${RAD_SVC}"
    systemctl is-active --quiet "$RAD_SVC" && ok "  ${RAD_SVC} is active (and misconfigured)"
  else
    warn "  no systemd unit found; start the server manually with: ${RAD_BIN} -X"
  fi
  echo "broken" > "${STATE_DIR}/fault1.state"
}

# -----------------------------------------------------------------------------
# FAULT 2 -- Rogue IPv6 Router Advertisement against an un-hardened stack
# -----------------------------------------------------------------------------
break_rogue_ra() {
  say "FAULT 2 :: rogue IPv6 Router Advertisement (namespace-contained)"

  if [[ ! -d /proc/sys/net/ipv6 ]]; then
    warn "  IPv6 disabled in the kernel -- FAULT 2 skipped"
    echo "skipped" > "${STATE_DIR}/fault2.state"; return 0
  fi

  ip netns del "$NS_ROGUE"  >/dev/null 2>&1 || true
  ip netns del "$NS_VICTIM" >/dev/null 2>&1 || true
  ip netns add "$NS_ROGUE"
  ip netns add "$NS_VICTIM"

  # Both ends leave the root namespace: nothing can escape onto the real LAN.
  ip link add "$VETH_ROGUE" type veth peer name "$VETH_VICTIM"
  ip link set "$VETH_ROGUE"  netns "$NS_ROGUE"
  ip link set "$VETH_VICTIM" netns "$NS_VICTIM"

  ip -n "$NS_ROGUE"  link set lo up
  ip -n "$NS_VICTIM" link set lo up
  ip -n "$NS_ROGUE"  link set "$VETH_ROGUE"  up
  ip -n "$NS_VICTIM" link set "$VETH_VICTIM" up
  ip -n "$NS_ROGUE"  addr add "$ROGUE_ADDR" dev "$VETH_ROGUE" nodad

  # The regression: RA acceptance, SLAAC, router preference and ICMPv6
  # redirects are all re-enabled on the victim.
  install -d -m 0755 "$CONF_DIR"
  cat > "$SYSCTL_NS_FILE" <<'NSCONF'
# Namespace-scoped hardening regression injected by the 334.1 break & fix lab.
# These knobs are per network namespace, which is why they are NOT in
# /etc/sysctl.d -- a sysctl.d drop-in would only ever reach the root namespace.
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.all.accept_ra_defrtr = 1
net.ipv6.conf.all.accept_ra_pinfo = 1
net.ipv6.conf.all.accept_ra_rtr_pref = 1
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.all.accept_redirects = 1
net.ipv6.conf.all.accept_source_route = 1
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.default.accept_ra_defrtr = 1
net.ipv6.conf.default.autoconf = 1
net.ipv6.conf.default.accept_redirects = 1
NSCONF
  ip netns exec "$NS_VICTIM" sysctl -q -p "$SYSCTL_NS_FILE" >>"$LOGFILE" 2>&1 || true
  ip netns exec "$NS_VICTIM" sysctl -q -w "net.ipv6.conf.${VETH_VICTIM}.accept_ra=2"          >>"$LOGFILE" 2>&1 || true
  ip netns exec "$NS_VICTIM" sysctl -q -w "net.ipv6.conf.${VETH_VICTIM}.accept_ra_defrtr=1"   >>"$LOGFILE" 2>&1 || true
  ip netns exec "$NS_VICTIM" sysctl -q -w "net.ipv6.conf.${VETH_VICTIM}.autoconf=1"           >>"$LOGFILE" 2>&1 || true
  ip netns exec "$NS_VICTIM" sysctl -q -w "net.ipv6.conf.${VETH_VICTIM}.accept_redirects=1"   >>"$LOGFILE" 2>&1 || true
  ok "  victim namespace ${NS_VICTIM} un-hardened (accept_ra=2, autoconf on)"

  if ! command -v radvd >/dev/null 2>&1; then
    warn "  radvd not installed -- the namespaces and the weak sysctls are in place,"
    warn "  but no live Router Advertisement will be injected."
    echo "partial" > "${STATE_DIR}/fault2.state"; return 0
  fi

  cat > "$RADVD_CONF" <<RADVD
# Rogue router impersonation for the 334.1 lab. High default preference
# (RFC 4191) so the bogus router wins over any legitimate one.
interface ${VETH_ROGUE}
{
    AdvSendAdvert on;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 4;
    AdvDefaultPreference high;
    AdvDefaultLifetime 1800;
    AdvManagedFlag off;
    AdvOtherConfigFlag off;

    prefix ${ROGUE_PREFIX}
    {
        AdvOnLink on;
        AdvAutonomous on;
        AdvRouterAddr on;
        AdvValidLifetime 3600;
        AdvPreferredLifetime 1800;
    };

    RDNSS 2001:db8:bad:c0de::53
    {
        AdvRDNSSLifetime 1800;
    };
};
RADVD
  chmod 0644 "$RADVD_CONF"

  ip netns exec "$NS_ROGUE" sysctl -q -w net.ipv6.conf.all.forwarding=1 >>"$LOGFILE" 2>&1 || true
  rm -f "$RADVD_PID"
  if ip netns exec "$NS_ROGUE" radvd -C "$RADVD_CONF" -p "$RADVD_PID" -m logfile -l "$RADVD_LOG" >>"$LOGFILE" 2>&1; then
    ok "  radvd advertising ${ROGUE_PREFIX} from ${NS_ROGUE} (pid $(cat "$RADVD_PID" 2>/dev/null || echo '?'))"
  else
    warn "  radvd failed to start -- see $LOGFILE and $RADVD_LOG"
  fi

  sleep 6
  if ip netns exec "$NS_VICTIM" ip -6 route show default 2>/dev/null | grep -q 'proto ra'; then
    ok "  victim poisoned: a default route learnt from the rogue RA is installed"
  else
    warn "  no RA-learnt route yet; it usually appears within ~10 s"
  fi
  echo "broken" > "${STATE_DIR}/fault2.state"
}

# -----------------------------------------------------------------------------
# FAULT 3 -- host-wide IPv4 sysctl regression + a service exposed on 0.0.0.0
# -----------------------------------------------------------------------------
break_exposure() {
  say "FAULT 3 :: host IPv4 sysctl regression + service exposed on all interfaces"

  # 3a) The IPv4 hardening drop-in is replaced by its exact opposite. Only knobs
  #     that weaken the host without dropping your session are touched.
  [[ -f "$SYSCTL_HOST_DROPIN" ]] && cp -a "$SYSCTL_HOST_DROPIN" "${BACKUP_DIR}/$(basename "$SYSCTL_HOST_DROPIN").orig"
  sysctl -a 2>/dev/null | grep -E '^net\.ipv4\.(ip_forward|tcp_syncookies|icmp_echo_ignore_broadcasts|conf\.(all|default)\.(rp_filter|accept_redirects|secure_redirects|send_redirects|accept_source_route|log_martians)) ' \
    > "${BACKUP_DIR}/sysctl-ipv4.pre-break" 2>/dev/null || true

  cat > "$SYSCTL_HOST_DROPIN" <<'HOSTCONF'
# Injected by the LPIC-3 334.1 break & fix lab. This file is the regression:
# every line below is the WRONG value for a hardened host. Reference:
# https://docs.kernel.org/networking/ip-sysctl.html
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 1
net.ipv4.conf.default.accept_redirects = 1
net.ipv4.conf.all.secure_redirects = 1
net.ipv4.conf.default.secure_redirects = 1
net.ipv4.conf.all.send_redirects = 1
net.ipv4.conf.default.send_redirects = 1
net.ipv4.conf.all.accept_source_route = 1
net.ipv4.conf.default.accept_source_route = 1
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
net.ipv4.icmp_echo_ignore_broadcasts = 0
net.ipv4.tcp_syncookies = 0
HOSTCONF
  sysctl -q -p "$SYSCTL_HOST_DROPIN" >>"$LOGFILE" 2>&1 || warn "  some sysctl keys were rejected; see $LOGFILE"
  ok "  ${SYSCTL_HOST_DROPIN} written and loaded (running kernel is now weakened)"

  # 3b) An internal "inventory" service bound to every interface, serving a
  #     cleartext credential file. Classic finding of an nmap sweep.
  install -d -m 0755 "$DOCROOT"
  cat > "${DOCROOT}/backup-credentials.txt" <<'CREDS'
# fake credentials -- lab material only, these accounts do not exist
nas-01.lab.example.com   radius-secret = testing123
switch-core-1            enable        = Tr0ub4dor&3
backup-operator          password      = Backup-2026-Winter
CREDS
  chmod 0644 "${DOCROOT}/backup-credentials.txt"
  echo "<h1>lab-334-1 inventory</h1>" > "${DOCROOT}/index.html"

  if command -v systemctl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${EXPOSED_UNIT}" <<UNIT
[Unit]
Description=LPIC-3 334.1 lab :: internal inventory service (intentionally exposed)
After=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/python3 -m http.server ${EXPOSED_PORT} --bind 0.0.0.0 --directory ${DOCROOT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    # 'nogroup' does not exist on RHEL-family systems.
    getent group nogroup >/dev/null 2>&1 || sed -i 's/^Group=nogroup$/Group=nobody/' "/etc/systemd/system/${EXPOSED_UNIT}"
    systemctl daemon-reload
    systemctl enable --now "$EXPOSED_UNIT" >>"$LOGFILE" 2>&1 || warn "  could not start ${EXPOSED_UNIT}"
    sleep 1
    systemctl is-active --quiet "$EXPOSED_UNIT" \
      && ok "  ${EXPOSED_UNIT} listening on 0.0.0.0:${EXPOSED_PORT}" \
      || warn "  ${EXPOSED_UNIT} is not active; see: systemctl status ${EXPOSED_UNIT}"
  elif command -v python3 >/dev/null 2>&1; then
    setsid python3 -m http.server "$EXPOSED_PORT" --bind 0.0.0.0 --directory "$DOCROOT" \
      >>"$LOGFILE" 2>&1 < /dev/null &
    echo $! > "${STATE_DIR}/exposed.pid"
    ok "  background listener on 0.0.0.0:${EXPOSED_PORT} (pid $(cat "${STATE_DIR}/exposed.pid"))"
  else
    warn "  python3 unavailable -- exposed-service fault skipped"
  fi
  echo "broken" > "${STATE_DIR}/fault3.state"
}

# -----------------------------------------------------------------------------
# Verifier installed for the student
# -----------------------------------------------------------------------------
install_verifier() {
  cat > "$VERIFY_BIN" <<'VERIFY'
#!/usr/bin/env bash
# lab-334-1-verify -- non-destructive check of the three 334.1 faults.
# Exit 0 = all repaired. Exit 1 = at least one fault still present.
set -uo pipefail

NS_VICTIM="lab3341-victim"
VETH_VICTIM="veth-v"
EXPOSED_PORT="8081"
RAD_USER="labuser"
RAD_PASS="L4bP4ss-334"
RAD_SECRET="testing123"
FAIL=0

if [[ -t 1 ]]; then G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; Z=$'\033[0m'
else G=""; R=""; Y=""; Z=""; fi
pass() { printf '%sPASS%s  %s\n' "$G" "$Z" "$*"; }
fail() { printf '%sFAIL%s  %s\n' "$R" "$Z" "$*"; FAIL=1; }
skip() { printf '%sSKIP%s  %s\n' "$Y" "$Z" "$*"; }

echo "== 334.1 Network Hardening :: verification =="
echo
echo "-- Fault 1: FreeRADIUS authentication"
if command -v radtest >/dev/null 2>&1; then
  out="$(radtest "$RAD_USER" "$RAD_PASS" 127.0.0.1 10 "$RAD_SECRET" 2>&1)"
  if grep -q 'Access-Accept' <<<"$out"; then
    pass "radtest ${RAD_USER} -> Access-Accept from 127.0.0.1:1812"
  else
    fail "radtest did not get an Access-Accept. Last lines:"
    printf '        %s\n' "$(tail -n 3 <<<"$out")"
  fi
else
  skip "radtest not installed (freeradius-utils)"
fi

echo
echo "-- Fault 2: rogue IPv6 Router Advertisement"
if ip netns list 2>/dev/null | grep -qw "$NS_VICTIM"; then
  bad=0
  for k in accept_ra accept_ra_defrtr accept_ra_pinfo autoconf accept_redirects accept_source_route; do
    for s in all default "$VETH_VICTIM"; do
      v="$(ip netns exec "$NS_VICTIM" sysctl -n "net.ipv6.conf.${s}.${k}" 2>/dev/null)" || continue
      [[ "$v" == "0" ]] || { fail "net.ipv6.conf.${s}.${k} = ${v} (expected 0)"; bad=1; }
    done
  done
  [[ $bad -eq 0 ]] && pass "victim namespace RA/SLAAC/redirect knobs are all 0"
  echo "      waiting 12 s for a rogue RA to be re-accepted..."
  sleep 12
  if ip netns exec "$NS_VICTIM" ip -6 route show 2>/dev/null | grep -q 'proto ra'; then
    fail "an RA-learnt route is still installed in ${NS_VICTIM}"
    ip netns exec "$NS_VICTIM" ip -6 route show | sed 's/^/        /'
  else
    pass "no RA-learnt route in ${NS_VICTIM}"
  fi
  if ip netns exec "$NS_VICTIM" ip -6 addr show 2>/dev/null | grep -q '2001:db8:bad:c0de'; then
    fail "a SLAAC address from the rogue prefix is still configured"
  else
    pass "no SLAAC address from 2001:db8:bad:c0de::/64"
  fi
else
  skip "namespace ${NS_VICTIM} absent (fault not applied, or already torn down)"
fi

echo
echo "-- Fault 3a: host IPv4 sysctl hardening"
declare -A WANT=(
  [net.ipv4.ip_forward]=0
  [net.ipv4.conf.all.accept_redirects]=0
  [net.ipv4.conf.default.accept_redirects]=0
  [net.ipv4.conf.all.secure_redirects]=0
  [net.ipv4.conf.default.secure_redirects]=0
  [net.ipv4.conf.all.send_redirects]=0
  [net.ipv4.conf.default.send_redirects]=0
  [net.ipv4.conf.all.accept_source_route]=0
  [net.ipv4.conf.default.accept_source_route]=0
  [net.ipv4.conf.all.log_martians]=1
  [net.ipv4.conf.default.log_martians]=1
  [net.ipv4.icmp_echo_ignore_broadcasts]=1
  [net.ipv4.tcp_syncookies]=1
)
bad=0
for k in "${!WANT[@]}"; do
  v="$(sysctl -n "$k" 2>/dev/null)" || continue
  [[ "$v" == "${WANT[$k]}" ]] || { fail "$k = $v (expected ${WANT[$k]})"; bad=1; }
done
for k in net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter; do
  v="$(sysctl -n "$k" 2>/dev/null)" || continue
  [[ "$v" == "1" || "$v" == "2" ]] || { fail "$k = $v (expected 1 strict or 2 loose)"; bad=1; }
done
[[ $bad -eq 0 ]] && pass "all audited IPv4 knobs hold hardened values"
if grep -rqs 'ip_forward = 1' /etc/sysctl.d/ /etc/sysctl.conf 2>/dev/null; then
  fail "a persistent config still sets net.ipv4.ip_forward = 1 (it will return on reboot)"
else
  pass "no persistent config re-enables ip_forward"
fi

echo
echo "-- Fault 3b: service exposure"
listen="$(ss -Hlnt 2>/dev/null | awk -v p=":${EXPOSED_PORT}" '$4 ~ p"$" {print $4}')"
if [[ -z "$listen" ]]; then
  pass "nothing is listening on port ${EXPOSED_PORT}"
else
  offend=0
  while read -r a; do
    [[ -z "$a" ]] && continue
    case "$a" in
      127.0.0.1:*|\[::1\]:*) : ;;
      *) fail "listening on a non-loopback address: $a"; offend=1 ;;
    esac
  done <<< "$listen"
  [[ $offend -eq 0 ]] && pass "port ${EXPOSED_PORT} is bound to loopback only"
fi
if [[ -r /srv/lab-334-1/backup-credentials.txt ]]; then
  printf '%sWARN%s  cleartext credential file still present under the docroot: /srv/lab-334-1/backup-credentials.txt\n' "$Y" "$Z"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  printf '%s== ALL CHECKS PASSED ==%s\n' "$G" "$Z"
else
  printf '%s== FAULTS REMAIN ==%s\n' "$R" "$Z"
fi
exit "$FAIL"
VERIFY
  chmod 0755 "$VERIFY_BIN"
  ok "verifier installed: ${VERIFY_BIN}"
}

# -----------------------------------------------------------------------------
# Mission briefing
# -----------------------------------------------------------------------------
briefing() {
  local ip4
  ip4="$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  ip4="${ip4:-<this-vm-ip>}"

  {
  cat <<BRIEF

===============================================================================
 LPIC-3 303-300 v3.0.0 -- Topic ${LAB_ID} Network Hardening -- BREAK & FIX
===============================================================================

Three independent network-hardening faults are now active on this VM.
Your job is to diagnose each one from its symptom and restore the intended
state. Do not read the solution at the bottom of the lab script until you have
made a serious attempt.

Machine-checkable success criteria:   ${VERIFY_BIN}
This briefing:                        ${MISSION}
Backups of every file mutated:        ${BACKUP_DIR}
Lab log:                              ${LOGFILE}

-------------------------------------------------------------------------------
 FAULT 1 -- RADIUS network-node authentication is rejecting everybody
-------------------------------------------------------------------------------
Context
  A FreeRADIUS server authenticates network devices (switches, APs, VPN
  concentrators) for this site. The NAS profile is fixed and cannot be changed:

      NAS address .......... 127.0.0.1
      shared secret ........ ${RAD_SECRET}
      test account ......... ${RAD_USER} / ${RAD_PASS}
      auth type ............ PAP

Symptom you will see
      # radtest ${RAD_USER} ${RAD_PASS} 127.0.0.1 10 ${RAD_SECRET}
      Sent Access-Request Id 215 from 0.0.0.0:41234 to 127.0.0.1:1812 length 76
      Received Access-Reject Id 215 from 127.0.0.1:1812 to 127.0.0.1:41234 length 20
      (*) No reply from server for ID 215 socket 3        <-- on some 3.2.x builds

  The daemon is running and its configuration parses. There are TWO distinct
  defects on the server side; fixing one is not enough. Depending on the
  FreeRADIUS build you may see, in debug mode, either of these lines -- they
  point at different defects:

      ... with invalid Message-Authenticator! (Shared secret is incorrect.)
      pap: WARNING: No "known good" password found for the user. Not setting Auth-Type
      No Auth-Type found: rejecting the user via Post-Auth-Type = Reject

What you must achieve
  radtest with the exact NAS profile above returns Access-Accept, with the
  server still running under systemd (not just under ${RAD_BIN:-radiusd} -X).

Tools that matter
  ${RAD_BIN:-radiusd} -X        run in foreground debug -- the single most useful RADIUS tool
  ${RAD_BIN:-radiusd} -XC       parse-only configuration check
  radtest, radclient            client-side probes
  ${RADDB:-/etc/raddb}/clients.conf
  ${RAD_USERS:-<raddb>/mods-config/files/authorize}
  journalctl -u ${RAD_SVC:-radiusd} -n 50

-------------------------------------------------------------------------------
 FAULT 2 -- A host is being hijacked by a rogue IPv6 Router Advertisement
-------------------------------------------------------------------------------
Context
  Namespace '${NS_VICTIM}' models a hardened Linux host on an untrusted L2
  segment. Namespace '${NS_ROGUE}' models an attacker (or a misconfigured
  appliance) sending Router Advertisements with high router preference,
  a bogus on-link prefix and a bogus RDNSS. Both namespaces are isolated from
  the VM's real network: nothing you do here reaches the LAN.

Symptom you will see
      # ip netns exec ${NS_VICTIM} ip -6 route show
      2001:db8:bad:c0de::/64 dev ${VETH_VICTIM} proto ra metric 1024 pref medium
      default via fe80::XXXX:XXff:feXX:XXXX dev ${VETH_VICTIM} proto ra metric 1024 pref high

      # ip netns exec ${NS_VICTIM} ip -6 addr show dev ${VETH_VICTIM}
      inet6 2001:db8:bad:c0de:XXXX:XXff:feXX:XXXX/64 scope global dynamic mngtmpaddr

  All of the victim's IPv6 traffic now leaves through an attacker-controlled
  next hop: a textbook on-path position (RFC 6104).

What you must achieve
  The victim must ignore Router Advertisements entirely -- no RA-learnt route,
  no SLAAC address from 2001:db8:bad:c0de::/64, no ICMPv6 redirects accepted --
  while the rogue advertiser keeps transmitting. Removing the veth, killing
  radvd or deleting the namespace is NOT a fix; the host must survive the
  attack, not have the attacker switched off.

Tools that matter
  ip netns exec ${NS_VICTIM} tcpdump -vvni ${VETH_VICTIM} 'icmp6 && ip6[40] == 134'
  ip netns exec ${NS_VICTIM} sysctl -a | grep -E 'ipv6.*(accept_ra|autoconf|redirect)'
  ip -6 route show / ip -6 addr show / ip -6 neigh show
  Detection & mitigation to know for the exam: ndpmon, rafixd, ramond,
  and RA Guard on the switch (RFC 6105).
  Kernel knob reference: https://docs.kernel.org/networking/ip-sysctl.html

-------------------------------------------------------------------------------
 FAULT 3 -- The host answers things it should not, and offers a service it should not
-------------------------------------------------------------------------------
Context
  A change was merged that "fixed a routing problem". The host now forwards
  packets, accepts ICMP redirects and source-routed packets, has reverse-path
  filtering off, martian logging off and SYN cookies off. Separately, an
  internal inventory service that must only be reachable from localhost is
  bound to every interface.

Symptom you will see
      # sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects
      net.ipv4.ip_forward = 1
      net.ipv4.conf.all.rp_filter = 0
      net.ipv4.conf.all.accept_redirects = 1

      # ss -lntp | grep :${EXPOSED_PORT}
      LISTEN 0  5   0.0.0.0:${EXPOSED_PORT}   0.0.0.0:*   users:(("python3",pid=NNNN,fd=3))

      # nmap -Pn -sT -p ${EXPOSED_PORT} --reason ${ip4}
      PORT     STATE SERVICE REASON
      ${EXPOSED_PORT}/tcp open  http    syn-ack ttl 64

      # curl -s http://${ip4}:${EXPOSED_PORT}/backup-credentials.txt
      nas-01.lab.example.com   radius-secret = testing123
      ...

What you must achieve
  1. Every audited IPv4 knob back to its hardened value, in the RUNNING kernel
     AND persistently -- a fix that disappears on reboot does not count.
  2. Port ${EXPOSED_PORT} must not be reachable from any address other than
     loopback. Either bind the service to 127.0.0.1 or retire it; filtering it
     as well is good practice.
  3. Confirm with nmap from off-host if you have a second machine, and confirm
     with tcpdump that the service was speaking cleartext.

Tools that matter
  sysctl -a / sysctl --system / /etc/sysctl.d/
  ss -lntup ; lsof -nPi ; nmap -sT -sV -p- ; nmap --reason
  tcpdump -A -ni any tcp port ${EXPOSED_PORT}
  systemctl cat|edit|disable|mask ${EXPOSED_UNIT}

-------------------------------------------------------------------------------
 WHEN YOU THINK YOU ARE DONE
-------------------------------------------------------------------------------
      # ${VERIFY_BIN}

  It takes about 15 seconds: it deliberately waits for the rogue advertiser to
  send several more RAs before declaring fault 2 repaired.
===============================================================================

BRIEF
  } | tee "$MISSION"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
  preflight
  install -d -m 0750 "$STATE_DIR" "$BACKUP_DIR"
  install -d -m 0755 "$CONF_DIR"
  : > "$LOGFILE"; chmod 0640 "$LOGFILE"

  rule
  say "teach-plat break & fix :: LPIC-3 303-300 topic ${LAB_ID} (Network Hardening)"
  rule
  install_dependencies
  break_freeradius
  break_rogue_ra
  break_exposure
  install_verifier
  date -u +'%Y-%m-%dT%H:%M:%SZ' > "${STATE_DIR}/BROKEN"
  rule
  briefing
  ok "lab armed. Start with: ${VERIFY_BIN}"
}

main "$@"

# =============================================================================
# =============================================================================
#  SOLUTION -- do not read until you have attempted the lab
# =============================================================================
# =============================================================================
#
# -----------------------------------------------------------------------------
# FAULT 1 -- FreeRADIUS: two defects, both visible in debug mode
# -----------------------------------------------------------------------------
#
# Step 1. Reproduce and capture the server's own view of the transaction.
#         Never diagnose FreeRADIUS from the client side alone.
#
#             systemctl stop freeradius     # or: systemctl stop radiusd
#             freeradius -X | tee /tmp/radius-debug.log     # or: radiusd -X
#
#         In a second shell:
#
#             radtest labuser L4bP4ss-334 127.0.0.1 10 testing123
#
# Step 2. Defect A -- shared secret desynchronisation.
#         In the debug output the request either fails Message-Authenticator
#         validation outright:
#
#             Received packet from 127.0.0.1 with invalid Message-Authenticator!
#             (Shared secret is incorrect.)
#
#         or is accepted but the User-Password attribute decrypts to binary
#         garbage, because the secret is the key of the MD5 keystream that
#         RFC 2865 uses to hide it:
#
#             (0)   User-Password = "\310\031\262\355..."
#
#         Locate the client definition and restore the provisioned secret:
#
#             grep -rn 'secret' /etc/freeradius/3.0/clients.conf   # Debian/Ubuntu
#             grep -rn 'secret' /etc/raddb/clients.conf            # RHEL/SUSE
#
#             client localhost {
#                 ipaddr = 127.0.0.1
#                 proto  = *
#                 secret = testing123          <-- was R4d-L4b-BADSECRET
#                 ...
#             }
#
#         Concretely:
#
#             sed -i 's/^\([[:space:]]*secret[[:space:]]*=[[:space:]]*\)R4d-L4b-BADSECRET/\1testing123/' \
#                 /etc/freeradius/3.0/clients.conf
#
#         Note for 3.2.x and later: BlastRADIUS mitigation makes the server
#         require a Message-Authenticator from clients by default. If your NAS
#         genuinely cannot send one, the knob is
#         'require_message_authenticator = no' inside the client block -- but
#         understand that you are trading away integrity protection, and never
#         set it to work around a secret you simply have not synchronised.
#
# Step 3. Defect B -- wrong operator on the known-good password.
#         Debug output:
#
#             (0) files: users: Matched entry labuser at line 2
#             (0) pap: WARNING: No "known good" password found for the user.
#                      Not setting Auth-Type
#             (0) No Auth-Type found: rejecting the user via Post-Auth-Type = Reject
#
#         In the users file the entry reads:
#
#             labuser  Cleartext-Password == "L4bP4ss-334"
#
#         '==' is a CHECK operator: it compares an attribute that must already
#         be in the request, and never adds anything to the control list. A
#         known-good password must be ASSIGNED with ':=' so rlm_pap can find it
#         and set Auth-Type := PAP:
#
#             labuser  Cleartext-Password := "L4bP4ss-334"
#                      Reply-Message := "334.1 lab access granted for %{User-Name}"
#
#         Concretely (path differs per distro):
#
#             U=/etc/freeradius/3.0/mods-config/files/authorize   # or /etc/raddb/...
#             sed -i 's/^\(labuser[[:space:]]*Cleartext-Password[[:space:]]*\)==/\1:=/' "$U"
#
#         In production this password would not be in cleartext at all: use
#         SSHA2-Password, or delegate to LDAP/Kerberos/PAM/sql. Cleartext-Password
#         is only mandatory when the authentication method itself needs the
#         plaintext (CHAP, MS-CHAP, EAP-MD5).
#
# Step 4. Validate, then restart under systemd, then re-test.
#
#             freeradius -XC && systemctl start freeradius   # or radiusd
#             radtest labuser L4bP4ss-334 127.0.0.1 10 testing123
#
#         Expected:
#
#             Sent Access-Request Id 87 from 0.0.0.0:38222 to 127.0.0.1:1812 length 76
#             Received Access-Accept Id 87 from 127.0.0.1:1812 to 127.0.0.1:38222 length 39
#                 Reply-Message = "334.1 lab access granted for labuser"
#
#         Restoring from the lab backups instead is legitimate too:
#             cp -a /var/lib/lab-334-1/backup/clients.conf.orig  <raddb>/clients.conf
#             cp -a /var/lib/lab-334-1/backup/authorize.orig     <raddb>/mods-config/files/authorize
#
# -----------------------------------------------------------------------------
# FAULT 2 -- rogue Router Advertisement
# -----------------------------------------------------------------------------
#
# Step 1. Prove what you are dealing with before changing anything. RA is
#         ICMPv6 type 134; the byte offset trick works because ip6[40] is the
#         first byte of the ICMPv6 header after the fixed 40-byte IPv6 header:
#
#             ip netns exec lab3341-victim tcpdump -vvni veth-v 'icmp6 && ip6[40] == 134'
#
#             IP6 (hlim 255, next-header ICMPv6 (58) payload length: 88)
#               fe80::a4:c1ff:fe1e:9d2 > ff02::1: [icmp6 sum ok] ICMP6, router advertisement,
#               length 88, hop limit 64, Flags [none], pref high, router lifetime 1800s
#                 prefix info option (3), length 32 (4): 2001:db8:bad:c0de::/64,
#                   Flags [onlink, auto, router], valid time 3600s, pref. time 1800s
#                 rdnss option (25), length 24 (3):  lifetime 1800s, addr: 2001:db8:bad:c0de::53
#
#         'pref high' is RFC 4191 Default Router Preference: this is how a rogue
#         router out-competes the legitimate one without any race.
#
# Step 2. Read the current (wrong) knob values:
#
#             ip netns exec lab3341-victim sysctl -a 2>/dev/null \
#               | grep -E 'net\.ipv6\.conf\.(all|default|veth-v)\.(accept_ra|accept_ra_defrtr|accept_ra_pinfo|accept_ra_rtr_pref|autoconf|accept_redirects|accept_source_route)'
#
# Step 3. Harden. accept_ra semantics: 0 = never accept, 1 = accept only when
#         forwarding is off, 2 = accept even when forwarding is on. A host that
#         gets its addressing from DHCPv6 or statically must be 0. Set 'all',
#         'default' (for interfaces created later) and the live interface --
#         for these knobs the kernel does not compute an effective value from
#         'all' alone the way it does for rp_filter (max) or log_martians (or):
#
#             NS="ip netns exec lab3341-victim"
#             for s in all default veth-v; do
#               $NS sysctl -qw net.ipv6.conf.$s.accept_ra=0
#               $NS sysctl -qw net.ipv6.conf.$s.accept_ra_defrtr=0
#               $NS sysctl -qw net.ipv6.conf.$s.accept_ra_pinfo=0
#               $NS sysctl -qw net.ipv6.conf.$s.accept_ra_rtr_pref=0
#               $NS sysctl -qw net.ipv6.conf.$s.autoconf=0
#               $NS sysctl -qw net.ipv6.conf.$s.accept_redirects=0
#               $NS sysctl -qw net.ipv6.conf.$s.accept_source_route=0
#             done
#
# Step 4. Setting the knob stops NEW poisoning; it does not retract what was
#         already installed. Flush the state the attacker planted:
#
#             $NS ip -6 route flush dev veth-v
#             $NS ip -6 addr flush dev veth-v scope global
#             $NS ip -6 neigh flush dev veth-v
#
#         Then wait and re-read -- with radvd still transmitting every 3-4 s,
#         nothing must come back:
#
#             sleep 12; $NS ip -6 route show; $NS ip -6 addr show dev veth-v
#
# Step 5. Persist it on a real host (a namespace is ephemeral by nature):
#
#             cat >/etc/sysctl.d/60-ipv6-ra-hardening.conf <<'EOF'
#             net.ipv6.conf.all.accept_ra = 0
#             net.ipv6.conf.default.accept_ra = 0
#             net.ipv6.conf.all.accept_ra_defrtr = 0
#             net.ipv6.conf.default.accept_ra_defrtr = 0
#             net.ipv6.conf.all.accept_ra_pinfo = 0
#             net.ipv6.conf.default.accept_ra_pinfo = 0
#             net.ipv6.conf.all.accept_ra_rtr_pref = 0
#             net.ipv6.conf.default.accept_ra_rtr_pref = 0
#             net.ipv6.conf.all.autoconf = 0
#             net.ipv6.conf.default.autoconf = 0
#             net.ipv6.conf.all.accept_redirects = 0
#             net.ipv6.conf.default.accept_redirects = 0
#             net.ipv6.conf.all.accept_source_route = 0
#             net.ipv6.conf.default.accept_source_route = 0
#             EOF
#             sysctl --system
#
#         Ordering caveat: sysctl.d runs before some interfaces exist, and
#         NetworkManager/systemd-networkd re-assert their own values per link
#         (NM: ipv6.method / ipv6.ra-timeout; networkd: IPv6AcceptRA=no in the
#         .network file). Verify per interface after boot, not just 'all'.
#
# Step 6. Know the layers above the host, because the host knob only protects
#         the host -- the rogue RA still floods the segment:
#           * RA Guard on the access switch (RFC 6105) -- the real fix.
#           * ndpmon      -- NDP monitor, alerts on new/changed routers and RAs.
#           * rafixd      -- answers a rogue RA with a lifetime-0 RA to cancel it.
#           * ramond      -- monitors and can neutralise rogue RAs.
#           * Note that RA Guard is evadable by IPv6 extension-header
#             fragmentation (RFC 7113); defence in depth is the answer.
#
# -----------------------------------------------------------------------------
# FAULT 3 -- sysctl regression and an exposed service
# -----------------------------------------------------------------------------
#
# Step 1. Find WHERE the wrong values are persisted, not just what they are.
#         'sysctl --system' shows the load order and lets the last file win:
#
#             sysctl --system 2>&1 | grep -i 'Applying'
#             grep -rn 'ip_forward\|rp_filter\|accept_redirects' /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/
#
#         The culprit here is /etc/sysctl.d/99-lab-334-1-host.conf -- and 99-
#         means it overrides every distro default, which is exactly why the
#         running kernel already has the weak values.
#
# Step 2. Replace it with the hardened set (or delete it and let the distro
#         defaults apply, then add your own drop-in):
#
#             rm -f /etc/sysctl.d/99-lab-334-1-host.conf
#             cat >/etc/sysctl.d/60-network-hardening.conf <<'EOF'
#             net.ipv4.ip_forward = 0
#             net.ipv4.conf.all.rp_filter = 1
#             net.ipv4.conf.default.rp_filter = 1
#             net.ipv4.conf.all.accept_redirects = 0
#             net.ipv4.conf.default.accept_redirects = 0
#             net.ipv4.conf.all.secure_redirects = 0
#             net.ipv4.conf.default.secure_redirects = 0
#             net.ipv4.conf.all.send_redirects = 0
#             net.ipv4.conf.default.send_redirects = 0
#             net.ipv4.conf.all.accept_source_route = 0
#             net.ipv4.conf.default.accept_source_route = 0
#             net.ipv4.conf.all.log_martians = 1
#             net.ipv4.conf.default.log_martians = 1
#             net.ipv4.icmp_echo_ignore_broadcasts = 1
#             net.ipv4.icmp_ignore_bogus_error_responses = 1
#             net.ipv4.tcp_syncookies = 1
#             EOF
#             sysctl --system
#
#         What each one buys you, since the exam asks for reasoning:
#           ip_forward=0 ............ the host is a host, not an unintended router
#           rp_filter=1 ............. drops packets whose source is not reachable
#                                     back out the receiving interface (RFC 3704
#                                     strict mode); use 2 (loose) on multihomed
#                                     or asymmetric-routing boxes, never 0
#           accept_redirects=0 ...... an ICMP redirect can rewrite your routing
#                                     table -- classic on-path insertion
#           secure_redirects=0 ...... even redirects "from a known gateway" are
#                                     spoofable; on a host you need none
#           send_redirects=0 ........ a non-router must not emit them
#           accept_source_route=0 ... LSRR/SSRR lets the sender pick the path
#           log_martians=1 .......... impossible-source packets get logged
#           tcp_syncookies=1 ........ SYN-flood survivability
#
#         Effective-value semantics differ per knob and this bites people:
#         rp_filter uses MAX(all, iface), log_martians uses OR(all, iface),
#         accept_redirects uses AND(all, iface). Writing to conf/all also
#         propagates to existing interfaces for most knobs -- verify, do not
#         assume:
#
#             for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo "$i = $(cat "$i")"; done
#
# Step 3. Find the exposed service by fact, not by memory:
#
#             ss -lntup
#             LISTEN 0 5 0.0.0.0:8081 0.0.0.0:* users:(("python3",pid=1842,fd=3))
#
#             systemctl status lab-334-1-inventory.service
#             systemctl cat lab-334-1-inventory.service | grep ExecStart
#
#         Scan yourself the way an attacker would. -Pn skips host discovery,
#         --reason shows why nmap believes the state, -sV fingerprints it:
#
#             nmap -Pn -sT -sV --reason -p 8081 <this-vm-ip>
#             nmap -Pn -sT -p- --open <this-vm-ip>          # full TCP sweep
#             nmap -Pn -sU --top-ports 50 <this-vm-ip>      # do not forget UDP
#
#         And prove it is cleartext -- this is the argument that gets the
#         change approved:
#
#             tcpdump -A -ni any 'tcp port 8081' &
#             curl -s http://<this-vm-ip>:8081/backup-credentials.txt
#
# Step 4. Fix the binding. Preferred: make the service listen on loopback only,
#         with a systemd drop-in so the change survives a package update:
#
#             systemctl edit lab-334-1-inventory.service
#             # [Service]
#             # ExecStart=
#             # ExecStart=/usr/bin/python3 -m http.server 8081 --bind 127.0.0.1 --directory /srv/lab-334-1
#             systemctl restart lab-334-1-inventory.service
#             ss -lntp | grep :8081       # -> 127.0.0.1:8081
#
#         Or retire it entirely, which is the better answer when the service has
#         no owner:
#
#             systemctl disable --now lab-334-1-inventory.service
#             systemctl mask lab-334-1-inventory.service
#             rm -f /srv/lab-334-1/backup-credentials.txt
#
#         Harden the unit while you are there -- systemd sandboxing is part of
#         host/network hardening, not a separate discipline:
#
#             # [Service]
#             # IPAddressDeny=any
#             # IPAddressAllow=localhost
#             # PrivateNetwork=yes / RestrictAddressFamilies=AF_INET AF_INET6
#             # NoNewPrivileges=yes  ProtectSystem=strict  ProtectHome=yes
#
#         Add packet filtering as defence in depth (topic 334.3 proper):
#
#             nft add table inet filter
#             nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
#             nft add rule inet filter input iif lo accept
#             nft add rule inet filter input ct state established,related accept
#             nft add rule inet filter input tcp dport 22 accept
#             # 8081 is simply never accepted
#         or with firewalld:
#             firewall-cmd --permanent --remove-port=8081/tcp; firewall-cmd --reload
#
#         The credential file is the real incident: rotate every secret it
#         contained -- including the RADIUS shared secret from fault 1 -- and
#         stop storing secrets in a document root.
#
# Step 5. Confirm everything, ideally from a second machine:
#
#             lab-334-1-verify
#             nmap -Pn -sT -p 8081 --reason <this-vm-ip>
#             # 8081/tcp closed http reason: conn-refused     (bound to loopback)
#             # 8081/tcp filtered http reason: no-response    (dropped by nftables)
#
# -----------------------------------------------------------------------------
# FULL TEARDOWN (after the lab is passed)
# -----------------------------------------------------------------------------
#             systemctl disable --now lab-334-1-inventory.service 2>/dev/null
#             rm -f /etc/systemd/system/lab-334-1-inventory.service
#             systemctl daemon-reload
#             pkill -F /run/lab-334-1-radvd.pid 2>/dev/null
#             ip netns del lab3341-rogue  2>/dev/null
#             ip netns del lab3341-victim 2>/dev/null
#             rm -f /etc/sysctl.d/99-lab-334-1-host.conf
#             sysctl --system
#             cp -a /var/lib/lab-334-1/backup/clients.conf.orig <raddb>/clients.conf
#             cp -a /var/lib/lab-334-1/backup/authorize.orig    <raddb>/mods-config/files/authorize
#             systemctl restart freeradius 2>/dev/null || systemctl restart radiusd 2>/dev/null
#             rm -rf /srv/lab-334-1 /etc/lab-334-1 /var/lib/lab-334-1 \
#                    /usr/local/bin/lab-334-1-verify /var/log/lab-334-1*.log
#
# =============================================================================