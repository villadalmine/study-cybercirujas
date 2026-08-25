#!/usr/bin/env bash
#
# =====================================================================================
#  LPIC-3 303 Security  --  Exam 303-300, version 3.0.0
#  Topic 334.4: Virtual Private Networks   (exam weight: 6.67)
#
#  BREAK & FIX LABORATORY
#
#  Reference (official objectives):
#      https://www.lpi.org/our-certifications/exam-303-objectives/
#  Upstream documentation used to build this lab:
#      OpenVPN 2.6 manual .......... https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/
#      OpenVPN HOWTO ............... https://openvpn.net/community-resources/how-to/
#      strongSwan swanctl.conf ..... https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html
#      strongSwan IPsec/XFRM ....... https://docs.strongswan.org/docs/latest/howtos/kernelModules.html
#      Linux ip-xfrm(8) ............ https://man7.org/linux/man-pages/man8/ip-xfrm.8.html
#      RFC 4301 (IPsec arch.) ...... https://www.rfc-editor.org/rfc/rfc4301
#      RFC 7296 (IKEv2) ............ https://www.rfc-editor.org/rfc/rfc7296
#
#  WHAT THIS SCRIPT DOES
#      1. Builds a complete, WORKING VPN lab inside two Linux network namespaces
#         (no host interfaces, no /etc files, no systemd units are touched).
#      2. Verifies the lab is green.
#      3. Sabotages exactly one thing, in a controlled and fully reversible way.
#      4. Tells you the symptom you will observe and the objective you must reach.
#      5. Grades your repair (`check`) and can reveal the answer (`solve`).
#
#  BLAST RADIUS
#      Everything lives in:  /opt/vpn334-lab  and the netns vpn-left / vpn-right.
#      `clean` removes both. Nothing under /etc, /usr or systemd is modified.
#      Modules tun / esp4 / xfrm_user may be loaded. Run this on a DISPOSABLE VM.
#
#  USAGE
#      ./334.4-vpn-break-fix.sh setup [1..5|random]   build the lab and break it
#      ./334.4-vpn-break-fix.sh brief                 re-print the mission
#      ./334.4-vpn-break-fix.sh status                dump the live diagnostics
#      ./334.4-vpn-break-fix.sh logs                  tail the OpenVPN logs
#      ./334.4-vpn-break-fix.sh restart               restart server and client
#      ./334.4-vpn-break-fix.sh shell left|right      drop into the namespace
#      ./334.4-vpn-break-fix.sh hint                  progressive hints (1..3)
#      ./334.4-vpn-break-fix.sh check                 grade the repair
#      ./334.4-vpn-break-fix.sh solve                 apply the official fix
#      ./334.4-vpn-break-fix.sh clean                 tear the whole lab down
#
#  Set I_UNDERSTAND_THIS_IS_A_LAB_VM=yes to skip the interactive safety prompt.
# =====================================================================================

set -Eeuo pipefail

LAB=/opt/vpn334-lab
PKI=$LAB/pki
SRV=$LAB/server
CLI=$LAB/client
CCD=$SRV/ccd
NS_L=vpn-left            # VPN gateway A  -- OpenVPN server / IPsec left
NS_R=vpn-right           # VPN gateway B  -- OpenVPN client / IPsec right

TRANSPORT_L=10.10.0.1    # "public" address of gateway A
TRANSPORT_R=10.10.0.2    # "public" address of gateway B
LAN_L=172.16.10.1        # protected network behind A  (172.16.10.0/24)
LAN_R=172.16.20.1        # protected network behind B  (172.16.20.0/24)
VPN_NET=10.8.0.0
VPN_MASK=255.255.255.0
VPN_SRV_IP=10.8.0.1

if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[0m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'
else
  B=""; R=""; RED=""; GRN=""; YEL=""; CYA=""
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$B$CYA" "$*" "$R"; printf '%s\n' "$(printf '%.0s-' {1..78})"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$GRN" "$R" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$R" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$YEL" "$R" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

nsl() { ip netns exec "$NS_L" "$@"; }
nsr() { ip netns exec "$NS_R" "$@"; }

# -------------------------------------------------------------------------------------
# Preflight
# -------------------------------------------------------------------------------------

require_root() { [[ $EUID -eq 0 ]] || die "this lab manipulates network namespaces; run it as root"; }

require_cmds() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]})); then
    say "Missing commands: ${missing[*]}"
    say "  Debian/Ubuntu : apt-get install -y openvpn openssl iproute2 iputils-ping tcpdump"
    say "  RHEL/Fedora   : dnf install -y openvpn openssl iproute iputils tcpdump"
    say "  SUSE          : zypper install -y openvpn openssl iproute2 iputils tcpdump"
    die "install the missing packages and re-run"
  fi
}

safety_guard() {
  [[ ${I_UNDERSTAND_THIS_IS_A_LAB_VM:-no} == yes ]] && return 0
  head1 "SAFETY CHECK"
  say "This script creates network namespaces, loads kernel modules (tun, esp4,"
  say "xfrm_user) and writes under ${LAB}. It does not touch /etc or systemd,"
  say "but it is still meant for a DISPOSABLE lab VM, never a production host."
  if ip link show type tun 2>/dev/null | grep -q .; then
    warn "this host already has TUN interfaces in the root namespace (a real VPN?)."
    warn "the lab stays inside its own namespaces, but double-check where you are."
  fi
  say ""
  read -r -p "Type LAB to continue: " answer
  [[ $answer == LAB ]] || die "aborted by user"
}

# -------------------------------------------------------------------------------------
# Topology
#
#            netns vpn-left                        netns vpn-right
#     172.16.10.0/24 (on lo)                 172.16.20.0/24 (on lo)
#              |                                        |
#        [ veth-l ] 10.10.0.1/24  <---------->  10.10.0.2/24 [ veth-r ]
#              \______________ untrusted transit ______________/
#
#  Scenarios 1-4 build an OpenVPN tunnel (10.8.0.0/24) on top of the transit link.
#  Scenario 5 builds a manually keyed IPsec ESP tunnel-mode SA pair instead.
# -------------------------------------------------------------------------------------

build_topology() {
  modprobe -q tun || true
  ip netns add "$NS_L"
  ip netns add "$NS_R"
  ip link add veth-l type veth peer name veth-r
  ip link set veth-l netns "$NS_L"
  ip link set veth-r netns "$NS_R"

  nsl ip link set lo up
  nsl ip addr add "$TRANSPORT_L/24" dev veth-l
  nsl ip link set veth-l up
  nsl ip addr add "$LAN_L/24" dev lo          # the "protected LAN" behind gateway A
  nsl sysctl -qw net.ipv4.ip_forward=1

  nsr ip link set lo up
  nsr ip addr add "$TRANSPORT_R/24" dev veth-r
  nsr ip link set veth-r up
  nsr ip addr add "$LAN_R/24" dev lo          # the "protected LAN" behind gateway B
  nsr sysctl -qw net.ipv4.ip_forward=1

  nsr ping -c1 -W2 "$TRANSPORT_L" >/dev/null 2>&1 \
    || die "transit link is dead; the lab cannot continue"
}

# -------------------------------------------------------------------------------------
# PKI  --  a minimal X.509 CA built with plain openssl (objective 331.1 / 331.2)
# -------------------------------------------------------------------------------------

build_pki() {
  mkdir -p "$PKI"
  cd "$PKI"

  cat > server.ext <<'EOF'
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = DNS:vpn-server
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

  cat > client.ext <<'EOF'
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

  # Deliberately WRONG EKU -- signed by the same CA, used by scenario 3.
  cat > badeku.ext <<'EOF'
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

  # Root CA (EC P-256: instant to generate, and 2026-appropriate).
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key 2>/dev/null
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -out ca.crt \
      -subj "/O=teach-plat/OU=334.4 lab/CN=teach-plat 334.4 Lab CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

  _leaf() {  # $1 = base name, $2 = CN, $3 = extension file
    openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null
    openssl req -new -key "$1.key" -out "$1.csr" -subj "/O=teach-plat/CN=$2" 2>/dev/null
    openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
        -days 825 -sha256 -extfile "$3" -out "$1.crt" 2>/dev/null
    rm -f "$1.csr"
  }

  _leaf server     vpn-server "$PKI/server.ext"
  _leaf client     vpn-client "$PKI/client.ext"
  _leaf client-bad vpn-client "$PKI/badeku.ext"     # same CN, wrong extendedKeyUsage

  # tls-crypt static key: authenticates and encrypts the whole control channel,
  # so an attacker who does not hold it cannot even reach the TLS stack.
  openvpn --genkey secret tc.key >/dev/null 2>&1 \
    || openvpn --genkey --secret tc.key >/dev/null 2>&1 \
    || die "cannot generate the tls-crypt key"
  cp tc.key tc-client.key
  chmod 600 ./*.key
  cd - >/dev/null
}

# -------------------------------------------------------------------------------------
# OpenVPN configuration
# -------------------------------------------------------------------------------------

build_openvpn() {
  mkdir -p "$SRV" "$CLI" "$CCD"

  cat > "$SRV/server.conf" <<EOF
# --- OpenVPN server, gateway A (netns $NS_L) ------------------------------------
dev tun0
dev-type tun
proto udp4
local $TRANSPORT_L
port 1194

topology subnet
server $VPN_NET $VPN_MASK

ca   $PKI/ca.crt
cert $PKI/server.crt
key  $PKI/server.key
dh   none                       # ECDHE only; no static DH parameters needed (2.4+)
tls-crypt $PKI/tc.key

tls-version-min 1.2
remote-cert-tls client          # the peer certificate MUST carry EKU clientAuth
data-ciphers AES-256-GCM        # the only data-channel cipher this server accepts
data-ciphers-fallback AES-256-GCM

client-config-dir $CCD
route 172.16.20.0 255.255.255.0             # kernel route: LAN B is behind the tun
push "route 172.16.10.0 255.255.255.0"      # tell the client how to reach LAN A

keepalive 10 30
persist-key
persist-tun
verb 4
status $SRV/status.log 5
log    $SRV/server.log
writepid $SRV/openvpn.pid
EOF

  # Internal route: bind LAN B to the certificate whose CN is vpn-client.
  cat > "$CCD/vpn-client" <<'EOF'
iroute 172.16.20.0 255.255.255.0
EOF

  cat > "$CLI/client.conf" <<EOF
# --- OpenVPN client, gateway B (netns $NS_R) ------------------------------------
client
dev tun0
dev-type tun
proto udp4
remote $TRANSPORT_L 1194
nobind

ca   $PKI/ca.crt
cert $PKI/client.crt
key  $PKI/client.key
tls-crypt $PKI/tc-client.key

tls-version-min 1.2
remote-cert-tls server          # the server certificate MUST carry EKU serverAuth
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM

resolv-retry 5
keepalive 10 30
persist-key
persist-tun
verb 3
log $CLI/client.log
writepid $CLI/openvpn.pid
EOF
}

start_server() {
  nsl openvpn --config "$SRV/server.conf" --daemon ovpn-lab-server
}

start_client() {
  nsr openvpn --config "$CLI/client.conf" --daemon ovpn-lab-client
}

stop_vpn() {
  local p
  for p in "$SRV/openvpn.pid" "$CLI/openvpn.pid"; do
    [[ -f $p ]] && { kill "$(cat "$p")" 2>/dev/null || true; rm -f "$p"; }
  done
  sleep 1
}

# Return 0 when the data channel carries traffic end to end.
tunnel_up() {
  local i
  for ((i = 0; i < ${1:-25}; i++)); do
    if nsr ping -c1 -W1 "$VPN_SRV_IP" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

lan_to_lan() {
  nsr ping -c2 -W2 -I "$LAN_R" "$LAN_L" >/dev/null 2>&1
}

# -------------------------------------------------------------------------------------
# Manually keyed IPsec (scenario 5)
#
#  This is the exact kernel state that strongSwan's charon installs through the
#  XFRM interface once IKEv2 finishes; keying it by hand removes the daemon from
#  the picture so the SAD/SPD themselves are what you read and repair.
# -------------------------------------------------------------------------------------

hexkey() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

build_ipsec() {
  modprobe -q esp4    || true
  modprobe -q xfrm_user || true
  modprobe -q af_key  || true

  mkdir -p "$LAB/ipsec"
  {
    echo "KEY_AUTH_LR=0x$(hexkey 32)"   # A -> B  integrity key (hmac-sha256)
    echo "KEY_ENC_LR=0x$(hexkey 32)"    # A -> B  confidentiality key (aes-256-cbc)
    echo "KEY_AUTH_RL=0x$(hexkey 32)"   # B -> A
    echo "KEY_ENC_RL=0x$(hexkey 32)"
  } > "$LAB/ipsec/keys.env"
  # shellcheck disable=SC1091
  source "$LAB/ipsec/keys.env"

  local ns
  for ns in "$NS_L" "$NS_R"; do
    ip netns exec "$ns" ip xfrm state flush
    ip netns exec "$ns" ip xfrm policy flush
  done

  # --- Security Associations (SAD). Identical on both peers. -----------------
  for ns in "$NS_L" "$NS_R"; do
    ip netns exec "$ns" ip xfrm state add \
        src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp spi 0x0334a001 reqid 3341 mode tunnel \
        auth-trunc 'hmac(sha256)' "$KEY_AUTH_LR" 128 enc 'cbc(aes)' "$KEY_ENC_LR"
    ip netns exec "$ns" ip xfrm state add \
        src "$TRANSPORT_R" dst "$TRANSPORT_L" proto esp spi 0x0334b001 reqid 3342 mode tunnel \
        auth-trunc 'hmac(sha256)' "$KEY_AUTH_RL" 128 enc 'cbc(aes)' "$KEY_ENC_RL"
  done

  # --- Security Policies (SPD), mirrored per direction. ----------------------
  nsl ip xfrm policy add src 172.16.10.0/24 dst 172.16.20.0/24 dir out \
      tmpl src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp reqid 3341 mode tunnel
  nsl ip xfrm policy add src 172.16.20.0/24 dst 172.16.10.0/24 dir in \
      tmpl src "$TRANSPORT_R" dst "$TRANSPORT_L" proto esp reqid 3342 mode tunnel
  nsl ip xfrm policy add src 172.16.20.0/24 dst 172.16.10.0/24 dir fwd \
      tmpl src "$TRANSPORT_R" dst "$TRANSPORT_L" proto esp reqid 3342 mode tunnel

  nsr ip xfrm policy add src 172.16.20.0/24 dst 172.16.10.0/24 dir out \
      tmpl src "$TRANSPORT_R" dst "$TRANSPORT_L" proto esp reqid 3342 mode tunnel
  nsr ip xfrm policy add src 172.16.10.0/24 dst 172.16.20.0/24 dir in \
      tmpl src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp reqid 3341 mode tunnel
  nsr ip xfrm policy add src 172.16.10.0/24 dst 172.16.20.0/24 dir fwd \
      tmpl src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp reqid 3341 mode tunnel

  nsl ip route add 172.16.20.0/24 via "$TRANSPORT_R" dev veth-l src "$LAN_L"
  nsr ip route add 172.16.10.0/24 via "$TRANSPORT_L" dev veth-r src "$LAN_R"
}

ipsec_works() {
  nsl ping -c2 -W2 -I "$LAN_L" "$LAN_R" >/dev/null 2>&1
}

# -------------------------------------------------------------------------------------
# The five breakages
# -------------------------------------------------------------------------------------

SCEN_NAME=(
  ""
  "OpenVPN data-channel cipher negotiation"
  "OpenVPN tls-crypt control-channel key"
  "X.509 extendedKeyUsage on the client certificate"
  "OpenVPN internal routing (iroute / client-config-dir)"
  "IPsec ESP tunnel-mode Security Association"
)

break_1() {   # data-ciphers mismatch: the client offers only a cipher the server refuses
  sed -i 's/^data-ciphers .*/data-ciphers AES-128-CBC/;         s/^data-ciphers-fallback .*/data-ciphers-fallback AES-128-CBC/' "$CLI/client.conf"
}

break_2() {   # tls-crypt key mismatch: the client holds a different static key
  openvpn --genkey secret "$PKI/tc-client.key" >/dev/null 2>&1 \
    || openvpn --genkey --secret "$PKI/tc-client.key" >/dev/null 2>&1
  chmod 600 "$PKI/tc-client.key"
}

break_3() {   # the client presents a certificate whose EKU is serverAuth
  sed -i "s#^cert .*#cert $PKI/client-bad.crt#; s#^key .*#key $PKI/client-bad.key#" "$CLI/client.conf"
}

break_4() {   # the server no longer knows which client owns 172.16.20.0/24
  rm -f "$CCD/vpn-client"
}

break_5() {   # gateway B's inbound SA is keyed with the wrong integrity secret
  # shellcheck disable=SC1091
  source "$LAB/ipsec/keys.env"
  local wrong_auth="0x$(hexkey 32)"
  nsr ip xfrm state delete src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp spi 0x0334a001
  nsr ip xfrm state add \
      src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp spi 0x0334a001 reqid 3341 mode tunnel \
      auth-trunc 'hmac(sha256)' "$wrong_auth" 128 enc 'cbc(aes)' "$KEY_ENC_LR"
}

# -------------------------------------------------------------------------------------
# Mission briefing
# -------------------------------------------------------------------------------------

brief() {
  local s; s=$(cat "$LAB/scenario" 2>/dev/null) || die "no lab is running; run: $0 setup"
  head1 "MISSION -- 334.4 Virtual Private Networks / scenario ${s}: ${SCEN_NAME[$s]}"

  cat <<EOF
Topology (everything is inside network namespaces, nothing on the host):

    netns ${NS_L}  "gateway A"                netns ${NS_R}  "gateway B"
    LAN 172.16.10.0/24 (on lo)                LAN 172.16.20.0/24 (on lo)
    transit ${TRANSPORT_L}/24  <===== untrusted link =====>  ${TRANSPORT_R}/24

Enter a side with:   $0 shell left      /  $0 shell right
Config tree:         ${LAB}
EOF

  case "$s" in
    1) cat <<EOF

SYMPTOM
  The client attempts the connection, the TLS handshake succeeds, and then the
  session is torn down immediately and retried in a loop. In ${SRV}/server.log
  you will see a line close to:

      OPTIONS ERROR: failed to negotiate cipher with client.
      Add the client's cipher to --data-ciphers ... or disable NCP
  and on the client side:
      OPTIONS ERROR: failed to negotiate cipher with server

  'ip -n ${NS_R} addr show tun0' either never appears or appears and disappears.

OBJECTIVE
  Restore the tunnel WITHOUT weakening the server. The negotiated data channel
  must end up on AES-256-GCM (AEAD). Adding a legacy CBC cipher to the server to
  make the error go away is the wrong answer and the grader will reject it.

SUCCESS CRITERIA
  * ip netns exec ${NS_R} ping -c2 ${VPN_SRV_IP}    succeeds
  * neither config mentions AES-128-CBC any more
EOF
    ;;
    2) cat <<EOF

SYMPTOM
  The client never completes the handshake. After 60 seconds ${CLI}/client.log
  reports:

      TLS Error: TLS key negotiation failed to occur within 60 seconds
      (check your network connectivity)
      TLS Error: TLS handshake failed

  The transit link is perfectly healthy: 'ping ${TRANSPORT_L}' from ${NS_R}
  works, and tcpdump shows UDP/1194 datagrams LEAVING gateway B, but the server
  answers nothing. At verb 4 the server may log a control-channel authentication
  failure instead of a TLS error.

OBJECTIVE
  Find out why the server silently discards packets that are visibly arriving,
  and make the tunnel come up again while KEEPING control-channel protection
  enabled. Removing tls-crypt from both ends "fixes" the symptom and destroys
  the security property; the grader will reject it.

SUCCESS CRITERIA
  * ip netns exec ${NS_R} ping -c2 ${VPN_SRV_IP}    succeeds
  * both server.conf and client.conf still use tls-crypt
EOF
    ;;
    3) cat <<EOF

SYMPTOM
  The control channel starts, the client is authenticated as far as the chain of
  trust goes, and then the server drops it. ${SRV}/server.log shows something
  very close to:

      VERIFY OK: depth=1, ... CN=teach-plat 334.4 Lab CA
      VERIFY EKU ERROR: require extendedKeyUsage TLS Web Client Authentication
      VERIFY ERROR: ... CN=vpn-client
      TLS Error: TLS object -> incoming plaintext read error

  Note what this is NOT: 'openssl verify -CAfile ca.crt <cert>' returns OK.
  The certificate is genuinely signed by the right CA.

OBJECTIVE
  Explain why a certificate that verifies against the CA is still refused, and
  make gateway B present a certificate acceptable to 'remote-cert-tls client'.
  Do not remove 'remote-cert-tls client' from the server.

SUCCESS CRITERIA
  * ip netns exec ${NS_R} ping -c2 ${VPN_SRV_IP}    succeeds
  * the certificate referenced by client.conf carries extendedKeyUsage clientAuth
  * the server still enforces remote-cert-tls client
EOF
    ;;
    4) cat <<EOF

SYMPTOM
  This one is nastier because the VPN looks healthy. The tunnel comes up, tun0
  exists on both sides, and

      ip netns exec ${NS_R} ping ${VPN_SRV_IP}

  works perfectly. But LAN-to-LAN traffic dies:

      ip netns exec ${NS_R} ping -I ${LAN_R} ${LAN_L}     -> 100% packet loss

  and ${SRV}/server.log fills with:

      MULTI: bad source address from client [172.16.20.1], packet dropped

  The client's routing table already contains 172.16.10.0/24 via the tunnel, and
  the server's kernel table already contains 172.16.20.0/24 dev tun0.

OBJECTIVE
  Understand the difference between the server's KERNEL routing table and
  OpenVPN's INTERNAL routing table, and restore reachability between the two
  protected networks.

SUCCESS CRITERIA
  * ip netns exec ${NS_R} ping -c2 -I ${LAN_R} ${LAN_L}   succeeds
  * ip netns exec ${NS_R} ping -c2 ${VPN_SRV_IP}          still succeeds
EOF
    ;;
    5) cat <<EOF

SYMPTOM
  No daemon is involved here: this is a manually keyed IPsec ESP tunnel, exactly
  the kernel state that strongSwan's charon installs over XFRM after IKEv2.

      ip netns exec ${NS_L} ping -I ${LAN_L} ${LAN_R}     -> 100% packet loss

  Diagnostics you should run:
      ip netns exec ${NS_L} ip -s xfrm state          # outbound counters climbing
      ip netns exec ${NS_R} ip -s xfrm state          # inbound SA at zero packets
      ip netns exec ${NS_R} cat /proc/net/xfrm_stat   # one error counter climbing
      ip netns exec ${NS_R} tcpdump -ni veth-r esp    # ESP IS arriving

  So the ciphertext reaches gateway B, gateway B has a matching SA for that SPI,
  and the plaintext still never surfaces.

OBJECTIVE
  Identify which SA parameter is inconsistent between the two peers, prove it
  with the SAD dumps, and repair gateway B so both protected networks talk again
  THROUGH ESP -- not by deleting the policies and falling back to cleartext.

SUCCESS CRITERIA
  * ip netns exec ${NS_L} ping -c2 -I ${LAN_L} ${LAN_R}   succeeds
  * both namespaces still hold tunnel-mode policies and two ESP states each
EOF
    ;;
  esac

  cat <<EOF

TOOLBOX
  $0 status            consolidated diagnostics (interfaces, routes, SAs, logs)
  $0 logs              last 40 lines of both OpenVPN logs
  $0 restart           restart server and client after editing a config
  $0 hint              progressive hints
  $0 check             grade your repair
  $0 solve             reveal and apply the official fix
  $0 clean             destroy the lab

EOF
}

# -------------------------------------------------------------------------------------
# Diagnostics / hints / grading
# -------------------------------------------------------------------------------------

status() {
  local s; s=$(cat "$LAB/scenario" 2>/dev/null) || die "no lab is running"
  head1 "INTERFACES / ROUTES -- $NS_L"
  nsl ip -br addr; echo; nsl ip route
  head1 "INTERFACES / ROUTES -- $NS_R"
  nsr ip -br addr; echo; nsr ip route
  if [[ $s == 5 ]]; then
    head1 "XFRM STATE -- $NS_L"; nsl ip -s xfrm state
    head1 "XFRM POLICY -- $NS_L"; nsl ip xfrm policy
    head1 "XFRM STATE -- $NS_R"; nsr ip -s xfrm state
    head1 "XFRM POLICY -- $NS_R"; nsr ip xfrm policy
    head1 "XFRM ERROR COUNTERS -- $NS_R"; nsr grep -v ' 0$' /proc/net/xfrm_stat || say "(all zero)"
  else
    head1 "OPENVPN SERVER STATUS"; cat "$SRV/status.log" 2>/dev/null || say "(no status file yet)"
    logs
  fi
}

logs() {
  head1 "SERVER LOG (tail) -- $SRV/server.log"; tail -n 40 "$SRV/server.log" 2>/dev/null || say "(empty)"
  head1 "CLIENT LOG (tail) -- $CLI/client.log"; tail -n 40 "$CLI/client.log" 2>/dev/null || say "(empty)"
}

restart() {
  local s; s=$(cat "$LAB/scenario" 2>/dev/null) || die "no lab is running"
  [[ $s == 5 ]] && { say "scenario 5 has no daemon to restart; edit the SAD/SPD with ip xfrm"; return 0; }
  stop_vpn
  : > "$SRV/server.log"; : > "$CLI/client.log"
  start_server; sleep 2; start_client
  say "server and client restarted; give it a few seconds, then run: $0 check"
}

hint() {
  local s n
  s=$(cat "$LAB/scenario" 2>/dev/null) || die "no lab is running"
  n=$(( $(cat "$LAB/hint" 2>/dev/null || echo 0) + 1 )); (( n > 3 )) && n=3
  echo "$n" > "$LAB/hint"
  head1 "HINT $n/3"
  case "$s$n" in
    11) say "Read the FIRST error, not the reconnect loop. Which side rejects which list?" ;;
    12) say "Since 2.5, OpenVPN negotiates the data cipher (NCP). 'data-ciphers' is an" ; say "ordered list of what a peer is willing to use; the intersection must be non-empty." ;;
    13) say "diff the data-ciphers lines of server.conf and client.conf. Fix the CLIENT." ;;
    21) say "Prove the packets leave: ip netns exec $NS_R tcpdump -ni veth-r udp port 1194" ;;
    22) say "The control channel is wrapped by tls-crypt BEFORE any TLS byte is parsed." ; say "A peer that cannot unwrap a packet drops it silently -- by design, it is an" ; say "anti-DoS / anti-scan feature (see the OpenVPN 2.6 manual, --tls-crypt)." ;;
    23) say "Compare the two static keys byte for byte:" ; say "  cmp $PKI/tc.key $PKI/tc-client.key" ; say "Both endpoints must hold the SAME tls-crypt key file." ;;
    31) say "Inspect what gateway B actually presents:" ; say "  grep '^cert' $CLI/client.conf" ; say "  openssl x509 -noout -text -in <that file> | grep -A1 'Extended Key Usage'" ;;
    32) say "'remote-cert-tls client' is shorthand for --remote-cert-eku 'TLS Web Client" ; say "Authentication' plus a keyUsage check. Chain validity is necessary, not sufficient." ;;
    33) say "$PKI/client.crt was issued with the right EKU. Point client.conf at it" ; say "(cert AND key) and restart." ;;
    41) say "Look at the server log message: it names the offending SOURCE address." ;;
    42) say "OpenVPN keeps two routing tables: the kernel's (--route, tells the OS to send" ; say "the subnet into tun0) and its own internal one (--iroute, tells OpenVPN WHICH" ; say "connected client owns that subnet). Only the second one is missing." ;;
    43) say "Recreate $CCD/vpn-client -- the file name must equal the client certificate" ; say "CN (vpn-client) -- containing: iroute 172.16.20.0 255.255.255.0 ; then restart." ;;
    51) say "The SPI matches and the packets arrive, so it is not a policy/SPI problem." ; say "Dump both SADs and compare them field by field." ;;
    52) say "  ip netns exec $NS_L ip xfrm state | grep -A4 0x0334a001" ; say "  ip netns exec $NS_R ip xfrm state | grep -A4 0x0334a001" ; say "An SA is a one-way contract: SPI, algorithms AND key material must be identical" ; say "on both peers. One of them is not." ;;
    53) say "Replace gateway B's inbound SA (src $TRANSPORT_L dst $TRANSPORT_R spi 0x0334a001)" ; say "with one whose auth-trunc key equals the one in gateway A's outbound SA:" ; say "  ip xfrm state delete src ... dst ... proto esp spi 0x0334a001" ; say "  ip xfrm state add    src ... (same params, correct keys)" ;;
  esac
}

check() {
  local s pass=1
  s=$(cat "$LAB/scenario" 2>/dev/null) || die "no lab is running"
  head1 "GRADING scenario $s -- ${SCEN_NAME[$s]}"

  case "$s" in
    1)
      if tunnel_up 20; then ok "data channel is up (ping $VPN_SRV_IP)"; else bad "the tunnel is still down"; pass=0; fi
      if grep -qi 'AES-128-CBC' "$SRV/server.conf" "$CLI/client.conf"; then
        bad "AES-128-CBC is still configured: you weakened the peer instead of aligning it"; pass=0
      else ok "no legacy CBC cipher survives in either configuration"; fi
      ;;
    2)
      if tunnel_up 20; then ok "data channel is up"; else bad "the handshake still fails"; pass=0; fi
      if grep -q '^tls-crypt' "$SRV/server.conf" && grep -q '^tls-crypt' "$CLI/client.conf"; then
        ok "control-channel protection (tls-crypt) is still enabled on both ends"
      else bad "tls-crypt was removed: the symptom is gone and so is the security property"; pass=0; fi
      ;;
    3)
      local cfile; cfile=$(awk '$1=="cert"{print $2}' "$CLI/client.conf" | tail -n1)
      if tunnel_up 20; then ok "data channel is up"; else bad "the server still rejects the client certificate"; pass=0; fi
      if [[ -n $cfile ]] && openssl x509 -noout -text -in "$cfile" 2>/dev/null | grep -q 'TLS Web Client Authentication'; then
        ok "client certificate carries extendedKeyUsage clientAuth ($cfile)"
      else bad "the certificate in client.conf still lacks EKU clientAuth"; pass=0; fi
      if grep -q '^remote-cert-tls client' "$SRV/server.conf"; then
        ok "the server still enforces remote-cert-tls client"
      else bad "you disabled the server-side EKU check instead of fixing the certificate"; pass=0; fi
      ;;
    4)
      if tunnel_up 20; then ok "data channel is up"; else bad "the tunnel is down"; pass=0; fi
      if lan_to_lan; then ok "LAN B ($LAN_R) reaches LAN A ($LAN_L) through the tunnel"
      else bad "LAN-to-LAN traffic is still dropped"; pass=0; fi
      ;;
    5)
      if ipsec_works; then ok "LAN A ($LAN_L) reaches LAN B ($LAN_R)"; else bad "still 100% packet loss"; pass=0; fi
      if nsl ip xfrm policy show | grep -q 'mode tunnel' && nsr ip xfrm policy show | grep -q 'mode tunnel'; then
        ok "tunnel-mode policies are still installed on both peers"
      else bad "the SPD was emptied: traffic would be flowing in cleartext"; pass=0; fi
      local n_l n_r
      n_l=$(nsl ip xfrm state show | grep -c 'proto esp' || true)
      n_r=$(nsr ip xfrm state show | grep -c 'proto esp' || true)
      if (( n_l >= 2 && n_r >= 2 )); then ok "both peers hold the two ESP SAs ($n_l / $n_r)"
      else bad "missing ESP SAs (left=$n_l right=$n_r)"; pass=0; fi
      ;;
  esac

  echo
  if (( pass )); then
    printf '  %sPASS%s -- objective 334.4 exercised: %s\n\n' "$B$GRN" "$R" "${SCEN_NAME[$s]}"
  else
    printf '  %sNOT YET%s -- run "%s hint" or "%s status" and try again.\n\n' "$B$RED" "$R" "$0" "$0"
    return 1
  fi
}

solve() {
  local s; s=$(cat "$LAB/scenario" 2>/dev/null) || die "no lab is running"
  head1 "OFFICIAL FIX -- scenario $s"
  case "$s" in
    1) say "sed -i 's/^data-ciphers .*/data-ciphers AES-256-GCM/; s/^data-ciphers-fallback .*/data-ciphers-fallback AES-256-GCM/' $CLI/client.conf"
       sed -i 's/^data-ciphers .*/data-ciphers AES-256-GCM/; s/^data-ciphers-fallback .*/data-ciphers-fallback AES-256-GCM/' "$CLI/client.conf"; restart ;;
    2) say "cp $PKI/tc.key $PKI/tc-client.key   # the same static key on both peers"
       cp "$PKI/tc.key" "$PKI/tc-client.key"; chmod 600 "$PKI/tc-client.key"; restart ;;
    3) say "point client.conf back at the certificate issued with EKU clientAuth"
       sed -i "s#^cert .*#cert $PKI/client.crt#; s#^key .*#key $PKI/client.key#" "$CLI/client.conf"; restart ;;
    4) say "recreate $CCD/vpn-client with: iroute 172.16.20.0 255.255.255.0"
       printf 'iroute 172.16.20.0 255.255.255.0\n' > "$CCD/vpn-client"; restart ;;
    5) # shellcheck disable=SC1091
       source "$LAB/ipsec/keys.env"
       say "re-install gateway B's inbound SA with the key gateway A actually uses"
       nsr ip xfrm state delete src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp spi 0x0334a001 || true
       nsr ip xfrm state add src "$TRANSPORT_L" dst "$TRANSPORT_R" proto esp spi 0x0334a001 \
           reqid 3341 mode tunnel auth-trunc 'hmac(sha256)' "$KEY_AUTH_LR" 128 enc 'cbc(aes)' "$KEY_ENC_LR" ;;
  esac
  say ""
  say "now run: $0 check"
}

# -------------------------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------------------------

clean() {
  stop_vpn 2>/dev/null || true
  pkill -f 'openvpn --config /opt/vpn334-lab' 2>/dev/null || true
  ip netns del "$NS_L" 2>/dev/null || true
  ip netns del "$NS_R" 2>/dev/null || true
  ip link del veth-l 2>/dev/null || true
  rm -rf "$LAB"
  ok "lab removed (namespaces, veth pair and $LAB)"
}

setup() {
  local want=${1:-random} s
  case "$want" in
    1|2|3|4|5) s=$want ;;
    random|"") s=$(( (RANDOM % 5) + 1 )) ;;
    *) die "unknown scenario '$want' (use 1..5 or random)" ;;
  esac

  safety_guard
  require_cmds ip openssl ping awk sed grep od
  [[ $s == 5 ]] || require_cmds openvpn

  head1 "BUILDING THE LAB"
  clean >/dev/null 2>&1 || true
  mkdir -p "$LAB"
  build_topology;                 ok "namespaces, transit link and protected LANs up"

  if [[ $s == 5 ]]; then
    build_ipsec;                  ok "manually keyed IPsec ESP tunnel installed"
    ipsec_works || die "the reference IPsec tunnel did not come up; aborting"
    ok "reference state verified GREEN (172.16.10.1 <-> 172.16.20.1 over ESP)"
  else
    build_pki;                    ok "X.509 CA, server/client certificates and tls-crypt key generated"
    build_openvpn;                ok "OpenVPN server and client configured"
    start_server; sleep 2; start_client
    tunnel_up 30 || { logs; die "the reference tunnel did not come up; aborting"; }
    lan_to_lan   || { logs; die "LAN-to-LAN routing did not come up; aborting"; }
    ok "reference state verified GREEN (data channel + LAN-to-LAN)"
  fi

  head1 "BREAKING ONE THING"
  echo "$s" > "$LAB/scenario"; echo 0 > "$LAB/hint"
  "break_$s"
  if [[ $s != 5 ]]; then
    stop_vpn; : > "$SRV/server.log"; : > "$CLI/client.log"
    start_server; sleep 2; start_client; sleep 6
  fi
  ok "sabotage applied: ${SCEN_NAME[$s]}"
  brief
}

main() {
  require_root
  case "${1:-setup}" in
    setup)   setup "${2:-random}" ;;
    brief)   brief ;;
    status)  status ;;
    logs)    logs ;;
    restart) restart ;;
    hint)    hint ;;
    check)   check ;;
    solve)   solve ;;
    clean)   clean ;;
    shell)
      case "${2:-}" in
        left)  say "you are now in $NS_L (exit to return)"; nsl bash ;;
        right) say "you are now in $NS_R (exit to return)"; nsr bash ;;
        *) die "usage: $0 shell left|right" ;;
      esac ;;
    -h|--help|help) sed -n '2,60p' "$0" ;;
    *) die "unknown command '${1}'; try: $0 --help" ;;
  esac
}

main "$@"

# =====================================================================================
#  SOLUTIONS -- read only after you have tried. One block per scenario, step by step.
# =====================================================================================
#
# -------------------------------------------------------------------------------------
# SCENARIO 1 -- data-channel cipher negotiation (NCP)
# -------------------------------------------------------------------------------------
# 1. Read the first error, not the reconnect loop:
#        tail -n 60 /opt/vpn334-lab/server/server.log
#        tail -n 60 /opt/vpn334-lab/client/client.log
#    Server: "OPTIONS ERROR: failed to negotiate cipher with client."
#    Client: "OPTIONS ERROR: failed to negotiate cipher with server."
#    The TLS handshake completed -- certificates are fine. The failure is at the
#    OCC/NCP option-negotiation step, after authentication.
#
# 2. Compare the two lists:
#        grep -H 'data-ciphers' /opt/vpn334-lab/server/server.conf \
#                               /opt/vpn334-lab/client/client.conf
#        server: data-ciphers AES-256-GCM
#        client: data-ciphers AES-128-CBC
#    Since OpenVPN 2.5 the data-channel cipher is NEGOTIATED (Negotiable Crypto
#    Parameters). --data-ciphers is an ordered preference list; the server picks
#    the first entry it also allows. Empty intersection => hard failure.
#    --cipher is deprecated and only sets the fallback for pre-2.4 peers; in 2.6
#    it exists as --data-ciphers-fallback.
#
# 3. Fix the CLIENT (never widen the server to a 64-bit-block-free-but-unauthenticated
#    CBC mode just to silence an error):
#        sed -i 's/^data-ciphers .*/data-ciphers AES-256-GCM/;\
#                s/^data-ciphers-fallback .*/data-ciphers-fallback AES-256-GCM/' \
#            /opt/vpn334-lab/client/client.conf
#
# 4. Restart and verify the negotiated cipher, do not assume it:
#        ./334.4-vpn-break-fix.sh restart
#        grep -E "Data Channel|Outgoing Data Channel" /opt/vpn334-lab/client/client.log
#        ip netns exec vpn-right ping -c2 10.8.0.1
#
# 5. Production note: AES-256-GCM and CHACHA20-POLY1305 are AEAD; they authenticate
#    the payload as part of the cipher. AES-256-CBC needs a separate --auth HMAC and
#    is the reason the old "cipher + auth" pair existed. Prefer
#        data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
#    Reference: https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/
#
# -------------------------------------------------------------------------------------
# SCENARIO 2 -- tls-crypt control-channel key mismatch
# -------------------------------------------------------------------------------------
# 1. Establish that the transport is healthy -- this is the step most students skip:
#        ip netns exec vpn-right ping -c2 10.10.0.1                       # OK
#        ip netns exec vpn-right timeout 5 tcpdump -ni veth-r udp port 1194
#    You will see outbound datagrams and ZERO replies. So the server process is
#    receiving and discarding, not the network dropping.
#
# 2. Client log says only:
#        TLS Error: TLS key negotiation failed to occur within 60 seconds
#        TLS Error: TLS handshake failed
#    That message is generic: it means "no valid control-channel packet came back".
#    Raise the server's verbosity to see the real cause:
#        sed -i 's/^verb .*/verb 5/' /opt/vpn334-lab/server/server.conf
#        ./334.4-vpn-break-fix.sh restart
#        grep -iE 'tls-crypt|unwrap|authenticat' /opt/vpn334-lab/server/server.log
#
# 3. --tls-crypt wraps AND authenticates every control-channel packet with a
#    pre-shared 2048-bit static key before TLS is parsed. A packet that fails the
#    HMAC is dropped SILENTLY and cheaply -- that is the point: it hides the TLS
#    stack from scanners and absorbs DoS. Same idea as the older --tls-auth, which
#    only authenticated (and needed --key-direction 0/1 -- a classic exam trap:
#    tls-auth requires OPPOSITE key directions on the two peers, tls-crypt does not).
#
# 4. Prove the keys differ and re-distribute the correct one:
#        cmp /opt/vpn334-lab/pki/tc.key /opt/vpn334-lab/pki/tc-client.key
#        cp  /opt/vpn334-lab/pki/tc.key /opt/vpn334-lab/pki/tc-client.key
#        chmod 600 /opt/vpn334-lab/pki/tc-client.key
#        ./334.4-vpn-break-fix.sh restart
#        ip netns exec vpn-right ping -c2 10.8.0.1
#
# 5. Regenerating with `openvpn --genkey secret ta.key` is how you ROTATE it, but
#    the new key must reach every client at the same time. For per-client keys use
#    --tls-crypt-v2 (2.5+), which lets each client hold a distinct wrapped key.
#
# -------------------------------------------------------------------------------------
# SCENARIO 3 -- X.509 extendedKeyUsage (EKU) on the client certificate
# -------------------------------------------------------------------------------------
# 1. The log distinguishes the two failures precisely:
#        VERIFY OK: depth=1, ... CN=teach-plat 334.4 Lab CA      <- chain is fine
#        VERIFY EKU ERROR: require extendedKeyUsage TLS Web Client Authentication
#    Chain validation and purpose validation are different checks (RFC 5280 s4.2.1.12).
#
# 2. Inspect what the client actually presents:
#        grep -E '^(cert|key) ' /opt/vpn334-lab/client/client.conf
#        openssl x509 -noout -subject -issuer -dates \
#            -ext extendedKeyUsage,keyUsage,basicConstraints \
#            -in /opt/vpn334-lab/pki/client-bad.crt
#    Output shows:  X509v3 Extended Key Usage: TLS Web Server Authentication
#    while  openssl verify -CAfile /opt/vpn334-lab/pki/ca.crt \
#                          /opt/vpn334-lab/pki/client-bad.crt   ->  OK
#    A perfectly valid certificate, issued for the wrong PURPOSE.
#
# 3. --remote-cert-tls client is shorthand for
#        --remote-cert-ku (digitalSignature / keyEncipherment)
#        --remote-cert-eku "TLS Web Client Authentication"
#    Keeping it is what stops a leaked SERVER certificate from being replayed as a
#    client credential -- the classic OpenVPN MITM described in the HOWTO.
#
# 4. Point the client at the correctly issued certificate and restart:
#        sed -i 's#^cert .*#cert /opt/vpn334-lab/pki/client.crt#;\
#                s#^key .*#key /opt/vpn334-lab/pki/client.key#' \
#            /opt/vpn334-lab/client/client.conf
#        ./334.4-vpn-break-fix.sh restart
#        openssl x509 -noout -ext extendedKeyUsage -in /opt/vpn334-lab/pki/client.crt
#        ip netns exec vpn-right ping -c2 10.8.0.1
#
# 5. If instead you must RE-ISSUE, the extension file is what matters:
#        printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\n%s\n' \
#               'extendedKeyUsage=clientAuth' > client.ext
#        openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
#                -days 825 -sha256 -extfile client.ext -out client.crt
#    With easy-rsa the equivalent is:  ./easyrsa build-client-full vpn-client nopass
#
# -------------------------------------------------------------------------------------
# SCENARIO 4 -- --route (kernel) vs --iroute (OpenVPN internal routing)
# -------------------------------------------------------------------------------------
# 1. Separate the two layers before touching anything:
#        ip netns exec vpn-right ping -c2 10.8.0.1              # tunnel OK
#        ip netns exec vpn-right ping -c2 -I 172.16.20.1 172.16.10.1   # LAN fails
#        ip netns exec vpn-right ip route            # 172.16.10.0/24 via 10.8.0.1 -> present
#        ip netns exec vpn-left  ip route            # 172.16.20.0/24 dev tun0     -> present
#    Both kernel tables are correct, so the problem is INSIDE openvpn.
#
# 2. The server log names the culprit:
#        grep -i 'bad source address' /opt/vpn334-lab/server/server.log
#        MULTI: bad source address from client [172.16.20.1], packet dropped
#    The multi-client server received a packet whose source is not in ANY connected
#    client's internal route list, so it refuses it (anti-spoofing).
#
# 3. The distinction that this objective exists to test:
#        --route  172.16.20.0 255.255.255.0   in server.conf
#                 -> tells the SERVER'S KERNEL to hand that subnet to tun0
#        --iroute 172.16.20.0 255.255.255.0   in the client-config-dir file
#                 -> tells OPENVPN which connected client owns that subnet
#    Both are required for a client-side LAN. Only the second one was removed.
#
# 4. Recreate the CCD entry. The FILE NAME must equal the client certificate's
#    common name (X509 CN = vpn-client) -- or the value of --username-as-common-name
#    when using --auth-user-pass-verify:
#        grep -H client-config-dir /opt/vpn334-lab/server/server.conf
#        printf 'iroute 172.16.20.0 255.255.255.0\n' \
#            > /opt/vpn334-lab/server/ccd/vpn-client
#        ./334.4-vpn-break-fix.sh restart
#
# 5. Verify at both layers, and read the internal table:
#        ip netns exec vpn-right ping -c2 -I 172.16.20.1 172.16.10.1
#        cat /opt/vpn334-lab/server/status.log      # ROUTING TABLE section lists
#                                                   # 172.16.20.0/24 -> vpn-client
#    Common variants of the same bug in production: the CCD file is named after the
#    wrong CN, --client-config-dir is a relative path and openvpn chrooted/chdir'd
#    away from it, or the file is unreadable after --user nobody drops privileges.
#
# -------------------------------------------------------------------------------------
# SCENARIO 5 -- IPsec ESP Security Association key mismatch (XFRM/SAD)
# -------------------------------------------------------------------------------------
# 1. Confirm ciphertext actually arrives, so this is not a routing/firewall issue:
#        ip netns exec vpn-right timeout 5 tcpdump -ni veth-r esp
#        -> ESP(spi=0x0334a001,seq=0x1), length 132     (packets ARE arriving)
#
# 2. Read the counters, which is what separates a guess from a diagnosis:
#        ip netns exec vpn-left  ip -s xfrm state     # outbound SA: packets climbing
#        ip netns exec vpn-right ip -s xfrm state     # inbound  SA: still 0 packets
#        ip netns exec vpn-right cat /proc/net/xfrm_stat | grep -v ' 0$'
#        ip netns exec vpn-right nstat -az | grep -i xfrm
#    Exactly one XfrmIn* error counter grows once per ping. The SA exists and the
#    SPI matches (otherwise you would see XfrmInNoStates); the packet is being
#    rejected during ESP processing => the crypto material disagrees.
#    Live view of every SA/policy event:  ip netns exec vpn-right ip xfrm monitor
#
# 3. Diff the two halves of the same one-way SA:
#        ip netns exec vpn-left  ip xfrm state get src 10.10.0.1 dst 10.10.0.2 \
#                                    proto esp spi 0x0334a001
#        ip netns exec vpn-right ip xfrm state get src 10.10.0.1 dst 10.10.0.2 \
#                                    proto esp spi 0x0334a001
#    The auth-trunc hmac(sha256) key differs. An SA is a UNIDIRECTIONAL contract:
#    (dst, SPI, protocol) identifies it, and mode, reqid, algorithms and key
#    material must be byte-identical on both peers (RFC 4301 s4.4.2).
#
# 4. Repair gateway B's inbound SA with the sender's key (states are immutable in
#    the relevant fields -- delete, then re-add):
#        AUTH=<the auth-trunc key printed by the vpn-left dump>
#        ENC=<the enc key printed by the vpn-left dump>
#        ip netns exec vpn-right ip xfrm state delete \
#            src 10.10.0.1 dst 10.10.0.2 proto esp spi 0x0334a001
#        ip netns exec vpn-right ip xfrm state add \
#            src 10.10.0.1 dst 10.10.0.2 proto esp spi 0x0334a001 reqid 3341 mode tunnel \
#            auth-trunc 'hmac(sha256)' $AUTH 128 enc 'cbc(aes)' $ENC
#        ip netns exec vpn-left ping -c2 -I 172.16.10.1 172.16.20.1
#
# 5. What this maps to in the real world -- you almost never key IPsec by hand:
#    charon installs exactly these SAD/SPD entries after IKEv2 (RFC 7296). The
#    equivalent troubleshooting on a strongSwan box is
#        swanctl --list-conns          # what is configured
#        swanctl --list-sas            # IKE_SA + CHILD_SA, with the negotiated proposal
#        swanctl --initiate --child net-net
#        swanctl --load-all            # after editing /etc/swanctl/swanctl.conf
#        journalctl -u strongswan -f   # or charon's filelog
#        ip xfrm state ; ip xfrm policy ; ip -s xfrm state    # the kernel's own view
#    and the classic causes of "IKE_SA established, no traffic passes" are: mismatched
#    proposals / esp_proposals, traffic selectors (local_ts/remote_ts) that do not
#    mirror, a missing NAT-T UDP/4500 hole, or a firewall dropping ESP (protocol 50)
#    -- never a "wrong password", which would have failed at IKE_AUTH instead.
#    Docs: https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html
#
# =====================================================================================
#  When you are done:   ./334.4-vpn-break-fix.sh clean
# =====================================================================================