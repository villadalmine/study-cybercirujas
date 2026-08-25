#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-3 303 "Security"  --  exam 303-300, version 3.0.0
#  Topic 331.4 : DNS and Cryptography            (exam weight: 8.33)
#
#  BREAK & FIX laboratory : a self-contained DNSSEC + DANE production incident
#
#  What this script builds, breaks and grades
#  ------------------------------------------
#  It stands up a miniature, hermetic DNS island inside ONE lab VM:
#
#      * an AUTHORITATIVE BIND instance  (127.0.0.1:5301) serving the
#        DNSSEC-signed zone  dnslab.internal
#      * a VALIDATING RECURSIVE BIND instance (127.0.0.1:5302) that trusts that
#        zone through a locally configured trust anchor (static-key), because
#        there is no signed parent to publish a DS record for us
#      * a TLS endpoint (openssl s_server on 127.0.0.1:8443) whose certificate
#        is pinned in DNS with a DANE TLSA record (usage 3, DANE-EE)
#
#  Then it injects a realistic, layered failure and hands the VM to you.
#
#  Safety properties (read them, they are the reason this is runnable at all)
#  -------------------------------------------------------------------------
#   1. It NEVER touches /etc/bind, /etc/named.conf, /etc/resolv.conf or the
#      system resolver. Nothing listens on port 53. Your VM keeps resolving.
#   2. Every artifact lives under ONE directory (printed at startup) and the
#      `clean` subcommand removes it plus the two named processes it started.
#   3. It starts private `named` instances with `-c <lab config>` on high
#      ports; it does not enable, start, mask or reconfigure any systemd unit.
#   4. It installs nothing. If a tool is missing it prints the exact package
#      command and exits.
#   5. It is idempotent: re-running `setup` rebuilds a clean baseline.
#
#  Still: run it on a DISPOSABLE lab VM with a snapshot. That is the deal.
#
#  Usage
#  -----
#      sudo ./331.4-break-fix-dns-crypto.sh              # setup + break + brief
#      sudo ./331.4-break-fix-dns-crypto.sh setup        # healthy baseline only
#      sudo ./331.4-break-fix-dns-crypto.sh break        # inject the faults
#      sudo ./331.4-break-fix-dns-crypto.sh brief        # reprint the briefing
#      sudo ./331.4-break-fix-dns-crypto.sh status       # ports / pids / state
#      sudo ./331.4-break-fix-dns-crypto.sh hint [1|2|3] # progressive hints
#      sudo ./331.4-break-fix-dns-crypto.sh verify       # grade your fix
#      sudo ./331.4-break-fix-dns-crypto.sh clean        # tear the lab down
#
#      LAB_LEVEL=hard sudo ./331.4-break-fix-dns-crypto.sh   # 3 faults, not 2
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there first. The whole point of the exercise is the diagnosis,
#  not the repair: the repair is four commands.
#
#  Official objective reference:
#      https://www.lpi.org/our-certifications/exam-303-objectives/
#  Upstream documentation used by this lab:
#      https://bind9.readthedocs.io/en/latest/dnssec-guide.html
#      https://bind9.readthedocs.io/en/latest/manpages.html
#      https://www.openssl.org/docs/man3.0/man1/openssl-s_client.html
#      RFC 4033/4034/4035 (DNSSEC), RFC 6698 + RFC 7671 (DANE), RFC 8945 (TSIG)
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Tunables (all overridable from the environment)
# ---------------------------------------------------------------------------
ZONE="${LAB_ZONE:-dnslab.internal}"
AUTH_PORT="${LAB_AUTH_PORT:-5301}"
RES_PORT="${LAB_RES_PORT:-5302}"
AUTH_CTRL="${LAB_AUTH_CTRL:-5953}"
RES_CTRL="${LAB_RES_CTRL:-5954}"
TLS_PORT="${LAB_TLS_PORT:-8443}"
LEVEL="${LAB_LEVEL:-normal}"          # normal = 2 faults, hard = 3 faults
ALGO="${LAB_ALGO:-ECDSAP256SHA256}"   # DNSSEC algorithm 13; RSASHA256 also fine

if [[ -z "${LAB_ROOT:-}" ]]; then
    # Prefer a directory the distro's MAC policy already lets named write into:
    # Debian/Ubuntu AppArmor allows /var/cache/bind/** rw, RHEL SELinux labels
    # /var/named. Falling back to /var/tmp works on unconfined systems.
    if   [[ -d /var/cache/bind ]]; then LAB_ROOT=/var/cache/bind/lab-331-4
    elif [[ -d /var/named     ]]; then LAB_ROOT=/var/named/lab-331-4
    else                               LAB_ROOT=/var/tmp/lab-331-4
    fi
fi

AUTH_DIR="$LAB_ROOT/auth"
RES_DIR="$LAB_ROOT/resolver"
KEY_DIR="$AUTH_DIR/keys"
DECOY_DIR="$LAB_ROOT/decoy-keys"
TLS_DIR="$LAB_ROOT/tls"
ZONE_SRC="$AUTH_DIR/db.$ZONE"
ZONE_SIGNED="$AUTH_DIR/db.$ZONE.signed"
STATE="$LAB_ROOT/.lab-state"
TLSA_OWNER="_${TLS_PORT}._tcp.www.$ZONE"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    B=$(tput bold); R=$(tput setaf 1); G=$(tput setaf 2); Y=$(tput setaf 3)
    C=$(tput setaf 6); N=$(tput sgr0)
else
    B=""; R=""; G=""; Y=""; C=""; N=""
fi
log()  { printf '%s[lab]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '%s[fail]%s %s\n' "$R" "$N" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[stop]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$B" "----------------------------------------------------------------------" "$N"; }

trap 'bad "line $LINENO failed: ${BASH_COMMAND}"' ERR

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
need_root() { [[ "$(id -u)" -eq 0 ]] || die "run as root (named binds ports and writes under $LAB_ROOT)"; }

check_deps() {
    local missing=() t
    for t in named named-checkconf named-checkzone dnssec-keygen dnssec-signzone dig openssl rndc; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if ((${#missing[@]})); then
        bad "missing tools: ${missing[*]}"
        echo "  Debian/Ubuntu : apt-get install -y bind9 bind9-utils bind9-dnsutils openssl"
        echo "  RHEL/Fedora   : dnf install -y bind bind-utils openssl"
        exit 1
    fi
    command -v delv >/dev/null 2>&1 || warn "delv not found - the lab works, but you lose the best single DNSSEC debugging tool"
    command -v tsig-keygen >/dev/null 2>&1 || warn "tsig-keygen not found - falling back to rndc-confgen for the control channel key"
}

check_ports() {
    command -v ss >/dev/null 2>&1 || return 0
    local p
    for p in "$AUTH_PORT" "$RES_PORT" "$AUTH_CTRL" "$RES_CTRL" "$TLS_PORT"; do
        if ss -lntu 2>/dev/null | grep -qE "[:.]${p}\b"; then
            # our own leftovers are fine; setup stops them first
            [[ -f "$STATE" ]] || die "port $p is already in use - set LAB_*_PORT or free it"
        fi
    done
}

confirm() {
    [[ "${LAB_CONFIRM:-}" == "yes" || "${1:-}" == "--yes" ]] && return 0
    [[ -t 0 ]] || die "non-interactive: re-run with LAB_CONFIRM=yes if this really is a disposable VM"
    rule
    cat <<EOF
${B}This is a BREAK & FIX lab.${N} It will start two private BIND instances and a
TLS server on high loopback ports under:

    $LAB_ROOT

It does NOT modify the system resolver, /etc/bind, /etc/named.conf or port 53,
and 'clean' removes everything it created. Even so: use a snapshotted lab VM.
EOF
    rule
    read -r -p "Type BREAK to continue: " a
    [[ "$a" == "BREAK" ]] || die "aborted"
}

relax_mac() {
    # AppArmor (Debian/Ubuntu): the shipped usr.sbin.named profile does not know
    # about our lab paths. On a lab VM, complain mode is the least invasive fix.
    if command -v aa-status >/dev/null 2>&1 && aa-status --enabled 2>/dev/null; then
        if aa-status 2>/dev/null | grep -q 'usr.sbin.named'; then
            if command -v aa-complain >/dev/null 2>&1; then
                aa-complain /usr/sbin/named >/dev/null 2>&1 && \
                    warn "AppArmor profile usr.sbin.named set to complain mode (restore: aa-enforce /usr/sbin/named)" || true
            else
                warn "AppArmor confines named; if it fails to start: apt-get install apparmor-utils && aa-complain /usr/sbin/named"
            fi
        fi
    fi
    # SELinux (RHEL/Fedora): named_t may only bind dns_port_t, and only write
    # named_cache_t. Label the lab tree and the ports properly instead of
    # disabling enforcement.
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
        chcon -R -t named_cache_t "$LAB_ROOT" >/dev/null 2>&1 || true
        if command -v semanage >/dev/null 2>&1; then
            local p
            for p in "$AUTH_PORT" "$RES_PORT"; do
                semanage port -a -t dns_port_t -p udp "$p" >/dev/null 2>&1 || true
                semanage port -a -t dns_port_t -p tcp "$p" >/dev/null 2>&1 || true
            done
            semanage port -a -t rndc_port_t -p tcp "$AUTH_CTRL" >/dev/null 2>&1 || true
            semanage port -a -t rndc_port_t -p tcp "$RES_CTRL"  >/dev/null 2>&1 || true
        else
            warn "SELinux enforcing without semanage: install policycoreutils-python-utils, or named may be denied these ports"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Process control
# ---------------------------------------------------------------------------
stop_pidfile() {
    local pf="$1"
    [[ -f "$pf" ]] || return 0
    local pid; pid="$(cat "$pf" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
}

stop_lab() {
    stop_pidfile "$AUTH_DIR/named.pid"
    stop_pidfile "$RES_DIR/named.pid"
    stop_pidfile "$TLS_DIR/s_server.pid"
}

wait_for_dns() {
    local port="$1" i
    for i in $(seq 1 40); do
        if dig +tries=1 +timeout=1 +short @127.0.0.1 -p "$port" "$ZONE" SOA >/dev/null 2>&1; then return 0; fi
        sleep 0.25
    done
    return 1
}

# ---------------------------------------------------------------------------
# Crypto helpers  (DANE TLSA 3 1 1 = DANE-EE / SubjectPublicKeyInfo / SHA-256)
# ---------------------------------------------------------------------------
spki_sha256_pem() {
    openssl x509 -in "$1" -noout -pubkey \
        | openssl pkey -pubin -outform DER \
        | openssl dgst -sha256 | awk '{print tolower($NF)}'
}

spki_sha256_live() {
    echo Q | openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername "www.$ZONE" 2>/dev/null \
        | openssl x509 -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 2>/dev/null | awk '{print tolower($NF)}'
}

tlsa_from_dns() {   # $1 = port to query; prints "3 1 1 <hex>" on one line
    dig +tries=1 +timeout=3 +short @127.0.0.1 -p "$1" TLSA "$TLSA_OWNER" 2>/dev/null \
        | head -1 \
        | awk '{ s=""; for (i=4; i<=NF; i++) s = s $i; if (NF>=4) print $1" "$2" "$3" "tolower(s) }'
}

make_cert() {   # $1 = basename under $TLS_DIR
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -keyout "$TLS_DIR/$1.key" -out "$TLS_DIR/$1.crt" \
        -subj "/CN=www.$ZONE/O=DNS Crypto Lab 331.4" \
        -addext "subjectAltName=DNS:www.$ZONE" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
    chmod 600 "$TLS_DIR/$1.key"
}

start_tls_server() {  # $1 = cert basename
    stop_pidfile "$TLS_DIR/s_server.pid"
    nohup openssl s_server -accept "127.0.0.1:$TLS_PORT" \
        -cert "$TLS_DIR/$1.crt" -key "$TLS_DIR/$1.key" \
        -www -no_ticket >>"$TLS_DIR/s_server.log" 2>&1 &
    echo $! >"$TLS_DIR/s_server.pid"
    echo "$1" >"$TLS_DIR/.serving"
    sleep 0.7
    kill -0 "$(cat "$TLS_DIR/s_server.pid")" 2>/dev/null || die "openssl s_server failed to start - see $TLS_DIR/s_server.log"
}

# ---------------------------------------------------------------------------
# Zone construction and signing
# ---------------------------------------------------------------------------
write_zone_source() {  # $1 = TLSA hex to publish
    cat >"$ZONE_SRC" <<EOF
\$ORIGIN $ZONE.
\$TTL 300
@       IN SOA  ns1.$ZONE. hostmaster.$ZONE. (
                $(date -u +%Y%m%d)01 ; serial
                3600       ; refresh
                900        ; retry
                604800     ; expire
                300 )      ; negative TTL
@       IN NS   ns1.$ZONE.
ns1     IN A    127.0.0.1
www     IN A    127.0.0.1
api     IN A    127.0.0.1
@       IN TXT  "LPIC-3 303 topic 331.4 break-and-fix lab zone"

; DANE pin for the TLS endpoint on port $TLS_PORT (RFC 6698).
; 3 = DANE-EE, 1 = SubjectPublicKeyInfo, 1 = SHA-256
_${TLS_PORT}._tcp.www  IN TLSA 3 1 1 $1
EOF
    named-checkzone -q "$ZONE" "$ZONE_SRC" || die "the generated zone file does not parse - this is a lab bug"
}

gen_keys() {
    rm -rf "$KEY_DIR"; mkdir -p "$KEY_DIR"
    # Publish/activate slightly in the past so any signature window we ask for
    # is covered by the key's own timing metadata.
    KSK="$(dnssec-keygen -q -a "$ALGO" -f KSK -P now-60d -A now-60d -K "$KEY_DIR" "$ZONE" 2>/dev/null \
           || dnssec-keygen -q -a "$ALGO" -f KSK -K "$KEY_DIR" "$ZONE")"
    ZSK="$(dnssec-keygen -q -a "$ALGO"        -P now-60d -A now-60d -K "$KEY_DIR" "$ZONE" 2>/dev/null \
           || dnssec-keygen -q -a "$ALGO"        -K "$KEY_DIR" "$ZONE")"
    printf '%s\n' "$KSK" >"$KEY_DIR/.ksk"
    printf '%s\n' "$ZSK" >"$KEY_DIR/.zsk"
    # The DS the parent WOULD publish, if this zone had a signed parent.
    dnssec-dsfromkey -a SHA-256 "$KEY_DIR/$KSK.key" >"$AUTH_DIR/dsset-manual.txt" 2>/dev/null || true
}

sign_zone() {   # optional $1 = inception, $2 = expiration (YYYYMMDDHHMMSS)
    local args=(-q -S -K "$KEY_DIR" -o "$ZONE" -N INCREMENT -f "$ZONE_SIGNED")
    if [[ -n "${1:-}" && -n "${2:-}" ]]; then args+=(-P -s "$1" -e "$2"); fi
    ( cd "$AUTH_DIR" && dnssec-signzone "${args[@]}" "$ZONE_SRC" >/dev/null )
}

dnskey_rdata() {  # $1 = .key file -> "flags proto alg base64"
    awk '!/^;/ { for (i=1; i<=NF; i++) if ($i=="DNSKEY") {
            s=""; for (j=i+4; j<=NF; j++) s = s $j;
            print $(i+1)" "$(i+2)" "$(i+3)" "s; exit } }' "$1"
}

write_trust_anchor() {   # $1 = .key file whose DNSKEY becomes the anchor
    local rd; rd="$(dnskey_rdata "$1")"
    local flags proto alg key
    read -r flags proto alg key <<<"$rd"
    cat >"$RES_DIR/trust-anchor.conf" <<EOF
// Locally configured DNSSEC trust anchor.
// In the real world the parent zone publishes a DS record and the chain of
// trust is followed from the root. $ZONE has no signed parent, so the
// validating resolver is told the KSK explicitly. This is exactly what an
// enterprise does for an internal-only signed zone.
trust-anchors {
    "$ZONE." static-key $flags $proto $alg "$key";
};
EOF
}

# ---------------------------------------------------------------------------
# named configuration
# ---------------------------------------------------------------------------
write_rndc_key() {
    if command -v tsig-keygen >/dev/null 2>&1; then
        tsig-keygen -a hmac-sha256 rndc-key >"$LAB_ROOT/rndc.key"
    else
        rndc-confgen -a -A hmac-sha256 -c "$LAB_ROOT/rndc.key" >/dev/null 2>&1
    fi
    chmod 640 "$LAB_ROOT/rndc.key"
    local which port
    for which in auth res; do
        [[ "$which" == auth ]] && port="$AUTH_CTRL" || port="$RES_CTRL"
        cat >"$LAB_ROOT/rndc-$which.conf" <<EOF
include "$LAB_ROOT/rndc.key";
options {
    default-key    "rndc-key";
    default-server 127.0.0.1;
    default-port   $port;
};
EOF
    done
}

write_named_confs() {
    cat >"$LAB_ROOT/named-auth.conf" <<EOF
// Authoritative server for $ZONE - lab instance, loopback only.
include "$LAB_ROOT/rndc.key";
controls {
    inet 127.0.0.1 port $AUTH_CTRL allow { 127.0.0.1; } keys { "rndc-key"; };
};
options {
    directory       "$AUTH_DIR";
    pid-file        "$AUTH_DIR/named.pid";
    session-keyfile none;
    listen-on port $AUTH_PORT { 127.0.0.1; };
    listen-on-v6    { none; };
    recursion       no;          // authoritative servers do not recurse
    dnssec-validation no;        // ... and do not validate; they only serve
    allow-query     { 127.0.0.1; };
    allow-transfer  { none; };
    notify          no;
};
logging {
    channel lab { file "$AUTH_DIR/named.log" versions 3 size 5m;
                  severity dynamic; print-time yes; print-category yes; print-severity yes; };
    category default   { lab; };
    category general   { lab; };
    category dnssec    { lab; };
    category queries   { lab; };
};
zone "$ZONE" IN {
    type primary;
    file "$ZONE_SIGNED";        // the SIGNED file is what is served
};
EOF

    cat >"$LAB_ROOT/named-res.conf" <<EOF
// Validating recursive resolver - lab instance, loopback only.
include "$LAB_ROOT/rndc.key";
include "$RES_DIR/trust-anchor.conf";
controls {
    inet 127.0.0.1 port $RES_CTRL allow { 127.0.0.1; } keys { "rndc-key"; };
};
options {
    directory       "$RES_DIR";
    pid-file        "$RES_DIR/named.pid";
    session-keyfile none;
    listen-on port $RES_PORT { 127.0.0.1; };
    listen-on-v6    { none; };
    recursion       yes;
    allow-query     { 127.0.0.1; };
    allow-recursion { 127.0.0.1; };
    dnssec-validation yes;       // validate using the configured trust anchors
    // Hermetic lab: never talk to the Internet, send everything to our
    // authoritative instance. 'forward only' means no root priming either.
    forwarders { 127.0.0.1 port $AUTH_PORT; };
    forward only;
};
logging {
    channel lab { file "$RES_DIR/named.log" versions 3 size 5m;
                  severity dynamic; print-time yes; print-category yes; print-severity yes; };
    category default    { lab; };
    category general    { lab; };
    category dnssec     { lab; };   // <- validation verdicts land here
    category resolver   { lab; };
    category queries    { lab; };
};
EOF
    named-checkconf "$LAB_ROOT/named-auth.conf" || die "generated authoritative config is invalid - lab bug"
    named-checkconf "$LAB_ROOT/named-res.conf"  || die "generated resolver config is invalid - lab bug"
}

start_named() {
    named -c "$LAB_ROOT/named-auth.conf"
    wait_for_dns "$AUTH_PORT" || die "authoritative named did not come up - see $AUTH_DIR/named.log"
    named -c "$LAB_ROOT/named-res.conf"
    wait_for_dns "$RES_PORT"  || die "resolver named did not come up - see $RES_DIR/named.log"
}

# ---------------------------------------------------------------------------
# setup : healthy baseline
# ---------------------------------------------------------------------------
cmd_setup() {
    need_root; check_deps; check_ports
    log "building lab in $LAB_ROOT"
    stop_lab || true
    rm -rf "$LAB_ROOT"
    mkdir -p "$AUTH_DIR" "$RES_DIR" "$KEY_DIR" "$DECOY_DIR" "$TLS_DIR"
    chmod 755 "$LAB_ROOT"
    relax_mac

    log "generating the TLS keypair and certificate for www.$ZONE"
    make_cert server1
    local hex; hex="$(spki_sha256_pem "$TLS_DIR/server1.crt")"

    log "writing the zone, DANE pin 3 1 1 ${hex:0:16}..."
    write_zone_source "$hex"

    log "generating DNSSEC keys (KSK + ZSK, algorithm $ALGO)"
    gen_keys
    log "signing the zone"
    sign_zone
    write_trust_anchor "$KEY_DIR/$(cat "$KEY_DIR/.ksk").key"

    log "writing named configurations and the rndc/TSIG control key"
    write_rndc_key
    write_named_confs

    log "starting both name servers and the TLS endpoint"
    start_named
    start_tls_server server1

    write_readme
    echo "healthy" >"$STATE"

    # Prove the baseline before we break it: nothing is more confusing than a
    # lab that was already broken for a reason the exercise did not intend.
    if quiet_all_checks; then
        ok "baseline is green: validated answers (AD bit) and a matching DANE pin"
    else
        die "baseline self-test failed - inspect $RES_DIR/named.log and $AUTH_DIR/named.log"
    fi
}

write_readme() {
    cat >"$LAB_ROOT/README-lab.txt" <<EOF
LPIC-3 303 / topic 331.4 - DNS and Cryptography - break & fix lab
=================================================================
zone                 : $ZONE
authoritative named  : 127.0.0.1:$AUTH_PORT   (rndc -c $LAB_ROOT/rndc-auth.conf ...)
validating resolver  : 127.0.0.1:$RES_PORT   (rndc -c $LAB_ROOT/rndc-res.conf ...)
TLS endpoint (DANE)  : 127.0.0.1:$TLS_PORT
TLSA owner name      : $TLSA_OWNER

files
  $LAB_ROOT/named-auth.conf     authoritative configuration
  $LAB_ROOT/named-res.conf      resolver configuration (validation + forwarding)
  $RES_DIR/trust-anchor.conf    the static-key trust anchor for $ZONE
  $ZONE_SRC                     UNSIGNED zone source  <- edit this one
  $ZONE_SIGNED                  SIGNED zone           <- generated, served
  $KEY_DIR                      K$ZONE.+*.key / .private (KSK + ZSK)
  $AUTH_DIR/dsset-manual.txt    the DS the parent would publish
  $TLS_DIR/server*.crt|.key     TLS keypairs
  $AUTH_DIR/named.log           authoritative log
  $RES_DIR/named.log            resolver log (category dnssec lives here)

useful
  dig @127.0.0.1 -p $RES_PORT +dnssec www.$ZONE A
  dig @127.0.0.1 -p $RES_PORT +cd +dnssec www.$ZONE A      # bypass validation
  dig @127.0.0.1 -p $AUTH_PORT +dnssec +norec www.$ZONE A  # raw, from the source
  delv @127.0.0.1 -p $RES_PORT +rtrace www.$ZONE A
  rndc -c $LAB_ROOT/rndc-res.conf trace 3        # raise debug level
  rndc -c $LAB_ROOT/rndc-res.conf flush
  rndc -c $LAB_ROOT/rndc-auth.conf reload $ZONE
  tail -f $RES_DIR/named.log
EOF
}

# ---------------------------------------------------------------------------
# break : inject the incident
# ---------------------------------------------------------------------------
cmd_break() {
    need_root
    [[ -f "$STATE" ]] || die "no lab found - run 'setup' first"

    # ---- FAULT 1 -----------------------------------------------------------
    # The zone was re-signed by a cron job whose clock/validity window was
    # wrong, so every RRSIG in the zone is already expired. The authoritative
    # server happily serves them (it does not validate what it serves); the
    # validating resolver refuses the whole zone.
    local s e
    s="$(date -u -d '40 days ago' +%Y%m%d%H%M%S)"
    e="$(date -u -d '10 days ago' +%Y%m%d%H%M%S)"
    sign_zone "$s" "$e"
    rndc -c "$LAB_ROOT/rndc-auth.conf" reload "$ZONE" >/dev/null 2>&1 || true

    # ---- FAULT 2 -----------------------------------------------------------
    # The TLS certificate was rotated (new keypair) and nobody updated the DANE
    # TLSA record, which still pins the SubjectPublicKeyInfo of the old key.
    make_cert server2
    start_tls_server server2

    # ---- FAULT 3 (hard mode only) -----------------------------------------
    # A KSK rollover happened and the resolver's static trust anchor was never
    # updated: it still holds a key that no longer signs the DNSKEY RRset.
    if [[ "$LEVEL" == "hard" ]]; then
        rm -rf "$DECOY_DIR"; mkdir -p "$DECOY_DIR"
        local dk
        dk="$(dnssec-keygen -q -a "$ALGO" -f KSK -K "$DECOY_DIR" "$ZONE")"
        write_trust_anchor "$DECOY_DIR/$dk.key"
        stop_pidfile "$RES_DIR/named.pid"
        named -c "$LAB_ROOT/named-res.conf"
        wait_for_dns "$RES_PORT" >/dev/null 2>&1 || true
    fi

    rndc -c "$LAB_ROOT/rndc-res.conf" flush >/dev/null 2>&1 || true
    echo "broken:$LEVEL" >"$STATE"
    cmd_brief
}

# ---------------------------------------------------------------------------
# brief : the student-facing incident report
# ---------------------------------------------------------------------------
cmd_brief() {
    local nfaults=2; [[ "$LEVEL" == "hard" ]] && nfaults=3
    rule
    cat <<EOF
${B}INCIDENT - topic 331.4, DNS and Cryptography${N}

You are the on-call platform engineer. At 03:12 the internal service
${B}www.$ZONE${N} started failing for every client that uses the company
validating resolver, and the DANE-based TLS monitor for the same host went red.

Nothing about the service itself changed. The name still exists. The web
endpoint still answers TLS. And yet clients cannot use either.

${B}SYMPTOM 1 - the resolver refuses to answer${N}

    dig @127.0.0.1 -p $RES_PORT www.$ZONE A

  -> ${R}status: SERVFAIL${N}, ANSWER: 0

  But the same question, asked with validation switched off, works:

    dig @127.0.0.1 -p $RES_PORT +cd www.$ZONE A        # +cd = Checking Disabled
    dig @127.0.0.1 -p $AUTH_PORT +norec www.$ZONE A    # straight from the source

  -> ${G}status: NOERROR${N}, and the A record is right there.

  A SERVFAIL that disappears with +cd is not a "DNS is down" incident.
  It is a validation verdict. The data is being ${B}rejected${N}, not lost.

${B}SYMPTOM 2 - the DANE-pinned TLS check fails${N}

    RR=\$(dig +short @127.0.0.1 -p $AUTH_PORT TLSA $TLSA_OWNER)
    echo Q | openssl s_client -connect 127.0.0.1:$TLS_PORT \\
        -servername www.$ZONE \\
        -dane_tls_domain www.$ZONE -dane_tls_rrdata "\$RR" 2>&1 | tail -20

  -> ${R}Verify return code: 65 (No matching DANE TLSA records)${N}

  The handshake completes. The certificate is served. DANE still says no.

${B}YOUR MISSION${N}

There are ${B}$nfaults independent faults${N}. Fix them so that ALL of the
following are simultaneously true:

  1. ${C}dig @127.0.0.1 -p $RES_PORT +dnssec www.$ZONE A${N} returns NOERROR
     ${B}with the ad flag set${N} - i.e. the resolver cryptographically
     validated the answer, it did not merely relay it.
  2. The RRSIGs served for the zone are inside their validity window.
  3. The TLSA record at $TLSA_OWNER matches the
     certificate the server is ${B}actually presenting right now${N}, and
     openssl reports ${G}Verify return code: 0${N} with
     "matched EE certificate at depth 0".
  4. You did it without weakening security.

${B}RULES - these are what separate a fix from a cover-up${N}

  * Do NOT set dnssec-validation to no, and do NOT delete the trust anchor.
    Turning off validation makes the alarm stop, not the problem.
  * Do NOT tell clients to use +cd. That is the DNS equivalent of
    curl --insecure.
  * Do NOT delete the TLSA record. Removing a pin to make a pin failure go
    away is how DANE deployments die.
  * Keep the zone signed. Unsigning it "fixes" symptom 1 the wrong way -
    and the grader checks for RRSIGs.

${B}WHERE TO LOOK${N}

  file map and cheat-sheet : $LAB_ROOT/README-lab.txt
  resolver log             : tail -f $RES_DIR/named.log
  raise resolver verbosity : rndc -c $LAB_ROOT/rndc-res.conf trace 3
  authoritative log        : tail -f $AUTH_DIR/named.log

  Two tools do 90% of DNSSEC diagnosis:
     dig +dnssec        shows you RRSIG rdata: type covered, algorithm,
                        ${B}expiration, inception${N}, key tag, signer.
     delv +rtrace       does the validation itself and tells you, in words,
                        which step failed and why.

${B}GRADE YOURSELF${N}

  $0 verify        # runs 6 checks, prints the reproducer for each failure
  $0 hint 1        # progressive hints (1 = nudge, 3 = nearly the answer)
  $0 clean         # tear the whole lab down

The complete step-by-step solution is at the end of this script, commented out.
Read it only after 'verify' passes, or after you have genuinely stalled.
EOF
    rule
}

# ---------------------------------------------------------------------------
# hint
# ---------------------------------------------------------------------------
cmd_hint() {
    local n="${1:-1}"
    rule
    case "$n" in
      1)
        cat <<EOF
${B}HINT 1/3 - where the truth is${N}

* A SERVFAIL that becomes NOERROR under +cd means the validator rejected the
  data. The validator wrote down why. Read the resolver log, category dnssec:

      rndc -c $LAB_ROOT/rndc-res.conf trace 3
      dig @127.0.0.1 -p $RES_PORT www.$ZONE A
      grep -iE 'valid|rrsig|expire|no.*key|bogus' $RES_DIR/named.log | tail -30

* Then ask the authoritative server for the signatures themselves and read the
  rdata field by field. An RRSIG carries its own expiration and inception as
  YYYYMMDDHHMMSS in UTC:

      dig @127.0.0.1 -p $AUTH_PORT +dnssec +norec +multiline www.$ZONE A
      date -u +%Y%m%d%H%M%S

* For the TLS half: a TLSA 3 1 1 record is a SHA-256 hash of the server's
  ${B}SubjectPublicKeyInfo${N}, not of the certificate. Compute the hash of what
  is being served and compare it, byte for byte, with what DNS publishes.
EOF
        ;;
      2)
        cat <<EOF
${B}HINT 2/3 - name the two (or three) faults${N}

FAULT A - every RRSIG in the zone has an expiration date in the past. A
  signature is only valid inside [inception, expiration]; outside it the
  validator MUST treat the data as bogus (RFC 4035 s5.3.1). Nothing is corrupt;
  the zone is simply stale. Signed zones are perishable goods - this is why
  production re-signs on a schedule, or uses BIND's dnssec-policy for
  automatic maintenance.

      dig @127.0.0.1 -p $AUTH_PORT +dnssec +norec www.$ZONE A | awk '\$4=="RRSIG"'
                                                # field 9 = expiration (UTC)

FAULT B - the certificate on port $TLS_PORT was rotated to a NEW keypair, so its
  SubjectPublicKeyInfo hash no longer equals the one pinned in the TLSA record.
  Either the DNS pin or the served certificate must change; in this story the
  rotation was intentional, so DNS is what is out of date.

      echo Q | openssl s_client -connect 127.0.0.1:$TLS_PORT 2>/dev/null \\
        | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER \\
        | openssl dgst -sha256
      dig +short @127.0.0.1 -p $AUTH_PORT TLSA $TLSA_OWNER

$( [[ "$LEVEL" == hard ]] && cat <<'EOH'
FAULT C (hard mode) - the resolver's static trust anchor does not correspond to
  any DNSKEY currently in the zone. Compare key tags: the anchor's tag versus
  the tags of the published DNSKEYs and of the RRSIG that covers the DNSKEY
  RRset. If they do not intersect, the chain of trust starts nowhere.

      dig +short @127.0.0.1 -p AUTHPORT DNSKEY ZONE | while read -r k; do
          echo "$k" | ... ; done      # or simply:
      dnssec-dsfromkey -a SHA-256 KEYDIR/K*.key      # key tag is in the output
      grep -A2 trust-anchors RESDIR/trust-anchor.conf
EOH
)

Fixing A does not fix B. They are independent layers: DNSSEC protects the
${B}integrity of the pin${N}; DANE is the pin. A correct DNSSEC deployment that
publishes a wrong pin is still a broken TLS deployment.
EOF
        ;;
      *)
        cat <<EOF
${B}HINT 3/3 - the shape of the repair${N}

For FAULT A - re-sign the zone with a sane validity window and reload:
      cd $AUTH_DIR
      dnssec-signzone -S -K keys -o $ZONE -N INCREMENT -f db.$ZONE.signed db.$ZONE
      rndc -c $LAB_ROOT/rndc-auth.conf reload $ZONE
      rndc -c $LAB_ROOT/rndc-res.conf flush
  (-S is smart signing: it picks up the keys from the key directory. Default
   validity is now-1h .. now+30d. -N INCREMENT bumps the SOA serial for you.)

For FAULT B - recompute the TLSA rdata from the live certificate, edit the
  ${B}unsigned${N} source zone ($ZONE_SRC), then re-sign and reload. Editing the
  .signed file directly is the classic beginner mistake: the next signing run
  overwrites it, and your edit is unsigned anyway.

$( [[ "$LEVEL" == hard ]] && echo "For FAULT C - rebuild trust-anchor.conf from the CURRENT KSK
  ($KEY_DIR/K$ZONE.+*.key, the one with flags 257) and restart the resolver
  (a trust anchor change needs a restart or 'rndc reconfig' + flush)." )

Then: $0 verify
EOF
        ;;
    esac
    rule
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
    rule
    printf '%slab state%s   : %s\n' "$B" "$N" "$( [[ -f "$STATE" ]] && cat "$STATE" || echo 'not built' )"
    printf '%slab root%s    : %s\n' "$B" "$N" "$LAB_ROOT"
    local p
    for p in "auth:$AUTH_DIR/named.pid" "resolver:$RES_DIR/named.pid" "s_server:$TLS_DIR/s_server.pid"; do
        local name="${p%%:*}" pf="${p#*:}" pid=""
        [[ -f "$pf" ]] && pid="$(cat "$pf")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            printf '%-12s : running (pid %s)\n' "$name" "$pid"
        else
            printf '%-12s : %sdown%s\n' "$name" "$R" "$N"
        fi
    done
    echo
    echo "zone answers (authoritative, no validation):"
    dig +tries=1 +timeout=2 @127.0.0.1 -p "$AUTH_PORT" +norec +noall +answer "www.$ZONE" A 2>/dev/null || true
    echo "zone answers (validating resolver):"
    dig +tries=1 +timeout=2 @127.0.0.1 -p "$RES_PORT" +noall +comments "www.$ZONE" A 2>/dev/null | grep -E 'status|flags' || true
    rule
}

# ---------------------------------------------------------------------------
# verify : the grader
# ---------------------------------------------------------------------------
PASS=0; FAIL=0
check() {  # $1 = description, $2 = reproducer command shown on failure; stdin unused
    local desc="$1" repro="$2"; shift 2
    if "$@"; then ok "$desc"; PASS=$((PASS+1)); return 0
    else bad "$desc"; printf '        reproduce: %s\n' "$repro"; FAIL=$((FAIL+1)); return 1; fi
}

c_guardrails() {
    grep -qE '^[[:space:]]*dnssec-validation[[:space:]]+(yes|auto)[[:space:]]*;' "$LAB_ROOT/named-res.conf" || return 1
    grep -q 'static-key' "$RES_DIR/trust-anchor.conf" 2>/dev/null || return 1
    grep -q 'RRSIG' "$ZONE_SIGNED" 2>/dev/null || return 1
    dig +tries=1 +timeout=2 +short @127.0.0.1 -p "$AUTH_PORT" "$ZONE" SOA >/dev/null 2>&1 || return 1
    [[ -n "$(spki_sha256_live)" ]] || return 1
}
c_sigs_current() {
    local exp now
    exp="$(dig +tries=1 +timeout=3 @127.0.0.1 -p "$AUTH_PORT" +dnssec +norec +noall +answer "www.$ZONE" A 2>/dev/null \
           | awk '$4=="RRSIG" {print $9; exit}')"
    [[ -n "$exp" ]] || return 1
    now="$(date -u +%Y%m%d%H%M%S)"
    [[ "$exp" > "$now" ]]
}
c_validated_a() {
    local out
    out="$(dig +tries=1 +timeout=4 @127.0.0.1 -p "$RES_PORT" +dnssec "www.$ZONE" A 2>/dev/null || true)"
    grep -q 'status: NOERROR' <<<"$out" && grep -qE 'flags:[^;]* ad[ ;]' <<<"$out"
}
c_validated_tlsa() {
    local out
    out="$(dig +tries=1 +timeout=4 @127.0.0.1 -p "$RES_PORT" +dnssec TLSA "$TLSA_OWNER" 2>/dev/null || true)"
    grep -q 'status: NOERROR' <<<"$out" && grep -qE 'flags:[^;]* ad[ ;]' <<<"$out" && grep -q 'IN.*TLSA' <<<"$out"
}
c_pin_matches() {
    local rr live u s m hex
    rr="$(tlsa_from_dns "$RES_PORT")"; [[ -n "$rr" ]] || return 1
    read -r u s m hex <<<"$rr"
    [[ "$u $s $m" == "3 1 1" ]] || return 1
    live="$(spki_sha256_live)"; [[ -n "$live" ]] || return 1
    [[ "$hex" == "$live" ]]
}
c_dane_handshake() {
    local rr out
    rr="$(dig +tries=1 +timeout=3 +short @127.0.0.1 -p "$RES_PORT" TLSA "$TLSA_OWNER" 2>/dev/null | head -1)"
    [[ -n "$rr" ]] || return 1
    out="$(echo Q | openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername "www.$ZONE" \
            -dane_tls_domain "www.$ZONE" -dane_tls_rrdata "$rr" 2>&1 || true)"
    grep -q 'Verify return code: 0' <<<"$out" && grep -qi 'matched EE certificate' <<<"$out"
}

quiet_all_checks() {
    c_guardrails && c_sigs_current && c_validated_a && c_validated_tlsa && c_pin_matches && c_dane_handshake
}

cmd_verify() {
    [[ -f "$STATE" ]] || die "no lab found - run 'setup' first"
    PASS=0; FAIL=0
    rule
    printf '%sGRADING topic 331.4 break & fix%s\n\n' "$B" "$N"
    check "guardrails intact (validation on, anchor present, zone still signed, services up)" \
          "grep -n dnssec-validation $LAB_ROOT/named-res.conf ; grep -c RRSIG $ZONE_SIGNED" c_guardrails || true
    check "RRSIGs are inside their validity window" \
          "dig @127.0.0.1 -p $AUTH_PORT +dnssec +norec www.$ZONE A | awk '\$4==\"RRSIG\"' ; date -u +%Y%m%d%H%M%S" c_sigs_current || true
    check "resolver returns NOERROR + AD for www.$ZONE A (cryptographically validated)" \
          "dig @127.0.0.1 -p $RES_PORT +dnssec www.$ZONE A" c_validated_a || true
    check "resolver returns NOERROR + AD for the TLSA record" \
          "dig @127.0.0.1 -p $RES_PORT +dnssec TLSA $TLSA_OWNER" c_validated_tlsa || true
    check "published TLSA 3 1 1 equals the SPKI SHA-256 of the live certificate" \
          "dig +short @127.0.0.1 -p $RES_PORT TLSA $TLSA_OWNER ; echo Q | openssl s_client -connect 127.0.0.1:$TLS_PORT 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256" c_pin_matches || true
    check "openssl DANE verification succeeds (return code 0, matched EE certificate)" \
          "RR=\$(dig +short @127.0.0.1 -p $RES_PORT TLSA $TLSA_OWNER); echo Q | openssl s_client -connect 127.0.0.1:$TLS_PORT -servername www.$ZONE -dane_tls_domain www.$ZONE -dane_tls_rrdata \"\$RR\"" c_dane_handshake || true
    echo
    if (( FAIL == 0 )); then
        printf '%s%s  ALL %d CHECKS PASSED  %s\n' "$B" "$G" "$PASS" "$N"
        cat <<EOF

What you just exercised, and why the exam cares:

  * A validator's SERVFAIL is a ${B}verdict${N}, not an outage. +cd is the
    single fastest way to separate "data missing" from "data rejected".
  * Signed zones expire. An RRSIG is only valid between inception and
    expiration; re-signing is an operational duty, which is precisely why BIND
    grew 'dnssec-policy' for automatic key and signature maintenance.
  * The chain of trust ends at something you configured: a DS in the parent, or
    a local trust anchor. When there is no signed parent, the anchor IS the
    chain, and a KSK rollover that forgets the anchor is a self-inflicted
    outage across every internal zone at once.
  * DANE moves certificate trust into DNS, so DNS integrity becomes TLS
    integrity: a TLSA 3 1 1 record pins SHA-256 of the SubjectPublicKeyInfo,
    NOT of the certificate. Rotating a key without republishing the pin breaks
    every DANE-aware client - which is why the safe rollover order is
    ${B}publish the new TLSA first, wait for TTL, then switch the cert${N}
    (RFC 7671, section 8).

  Tear down with: $0 clean
EOF
    else
        printf '%s  %d passed, %d failed%s - fix the failures above, then re-run verify\n' "$R" "$PASS" "$FAIL" "$N"
        printf '  stuck? %s hint 1 | 2 | 3\n' "$0"
    fi
    rule
    (( FAIL == 0 ))
}

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
cmd_clean() {
    need_root
    log "stopping lab processes"
    stop_lab || true
    if [[ -d "$LAB_ROOT" ]]; then
        rm -rf "$LAB_ROOT"
        ok "removed $LAB_ROOT"
    fi
    if command -v aa-enforce >/dev/null 2>&1 && [[ -e /etc/apparmor.d/usr.sbin.named ]]; then
        aa-enforce /usr/sbin/named >/dev/null 2>&1 && log "AppArmor profile usr.sbin.named restored to enforce mode" || true
    fi
    ok "lab removed. Your system resolver and port 53 were never touched."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    case "${1:-run}" in
        run)    confirm "${2:-}"; cmd_setup; cmd_break ;;
        setup)  confirm "${2:-}"; cmd_setup; log "healthy baseline ready. Inject the incident with: $0 break" ;;
        break)  cmd_break ;;
        brief)  cmd_brief ;;
        status) cmd_status ;;
        hint)   cmd_hint "${2:-1}" ;;
        verify) cmd_verify ;;
        clean)  cmd_clean ;;
        *)      sed -n '/^#  Usage/,/^#  The full step/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//' ;;
    esac
}
main "$@"
exit $?

# =============================================================================
# ===========================  SOLUTION  =======================================
# =============================================================================
# Everything below is commented out on purpose. Read it after 'verify' passes,
# or when you have truly stalled. Paths assume the defaults printed by the lab:
#   LAB=/var/cache/bind/lab-331-4 (or /var/named/lab-331-4, or /var/tmp/...)
#   ZONE=dnslab.internal, auth 127.0.0.1:5301, resolver 127.0.0.1:5302, TLS 8443
#
#   LAB=$(ls -d /var/cache/bind/lab-331-4 /var/named/lab-331-4 /var/tmp/lab-331-4 2>/dev/null | head -1)
#   ZONE=dnslab.internal
#   RNDC_AUTH="rndc -c $LAB/rndc-auth.conf"
#   RNDC_RES="rndc -c $LAB/rndc-res.conf"
#
# -----------------------------------------------------------------------------
# STEP 0 - Establish WHERE the failure is, before touching anything
# -----------------------------------------------------------------------------
#   dig @127.0.0.1 -p 5302 www.$ZONE A            # SERVFAIL
#   dig @127.0.0.1 -p 5302 +cd www.$ZONE A        # NOERROR  <- data exists
#   dig @127.0.0.1 -p 5301 +norec www.$ZONE A     # NOERROR  <- source is fine
#
# Reading: the authoritative server has the data, the resolver can reach it, and
# the answer only survives when validation is disabled (+cd, Checking Disabled).
# Therefore the failure is the validator rejecting the data. Never "restart
# named and see"; the verdict is already written down.
#
#   $RNDC_RES trace 3                             # debug level 3
#   dig @127.0.0.1 -p 5302 www.$ZONE A >/dev/null
#   tail -40 $LAB/resolver/named.log
#
# You will see lines of the form:
#     validating dnslab.internal/A: verify failed due to bad signature
#     ... RRSIG has expired
#     validating dnslab.internal/A: no valid signature found
#     broken trust chain resolving 'www.dnslab.internal/A/IN'
#   $RNDC_RES trace 0                             # back to normal afterwards
#
# The same conclusion in one command, in plain language:
#   delv @127.0.0.1 -p 5302 +rtrace www.$ZONE A
#     ;; resolution failed: SERVFAIL       (and with +vtrace, the failing step)
#
# -----------------------------------------------------------------------------
# STEP 1 - FAULT A: every RRSIG in the zone is expired
# -----------------------------------------------------------------------------
# Read the signature's own metadata. RRSIG rdata order (RFC 4034 s3.1):
#   type-covered  algorithm  labels  original-TTL  EXPIRATION  INCEPTION
#   key-tag  signer-name  signature
#
#   dig @127.0.0.1 -p 5301 +dnssec +norec +multiline www.$ZONE A
#   dig @127.0.0.1 -p 5301 +dnssec +norec +noall +answer www.$ZONE A | awk '$4=="RRSIG"{print $9,$10}'
#   date -u +%Y%m%d%H%M%S
#
# Expiration is in the past -> RFC 4035 s5.3.1 requires the validator to treat
# the RRset as bogus. Nothing is corrupt; the zone is stale.
#
# Fix - re-sign with the default (sane) validity window and reload:
#
#   cd $LAB/auth
#   dnssec-signzone -S -K keys -o $ZONE -N INCREMENT -f db.$ZONE.signed db.$ZONE
#       # -S  smart signing: find the keys in -K, publish the DNSKEY RRset
#       # -N INCREMENT  bump the SOA serial (secondaries need this)
#       # default validity: now-1h .. now+30d ; override with -s / -e
#       # add -3 $(openssl rand -hex 8) if you want NSEC3 instead of NSEC
#   named-checkzone -D -o /dev/null $ZONE db.$ZONE.signed | tail -1   # sanity
#   $RNDC_AUTH reload $ZONE
#   $RNDC_RES flush                # drop the cached SERVFAIL / bogus state
#   dig @127.0.0.1 -p 5302 +dnssec www.$ZONE A | grep -E 'flags|status'
#       # -> status: NOERROR ... flags: qr rd ra ad     <- the 'ad' bit is the goal
#
# The 'ad' (Authenticated Data) flag is the only proof that validation actually
# happened. NOERROR without 'ad' means "insecure", not "verified".
#
# In production you do not re-sign by hand. Either a scheduled re-signing job,
# or - much better on BIND 9.16+ - inline, automatic maintenance:
#     zone "example.com" { type primary; file "db.example.com";
#                          dnssec-policy default; inline-signing yes; };
# which keeps signatures fresh and rolls the ZSK for you.
#
# -----------------------------------------------------------------------------
# STEP 2 - (hard mode) FAULT C: the trust anchor no longer matches any DNSKEY
# -----------------------------------------------------------------------------
# If step 1 did not restore the 'ad' flag, the chain of trust itself is broken.
# With no signed parent there is no DS record: the resolver's configured anchor
# IS the entry point, so compare key tags.
#
#   # tag of the KSK the zone is actually using (flags 257):
#   dnssec-dsfromkey -a SHA-256 $LAB/auth/keys/K$ZONE.+*.key
#       # output: dnslab.internal. IN DS <KEYTAG> 13 2 <digest>
#   # what the resolver was told to trust:
#   cat $LAB/resolver/trust-anchor.conf
#   # what actually signs the DNSKEY RRset:
#   dig @127.0.0.1 -p 5301 +dnssec +norec $ZONE DNSKEY | awk '$4=="RRSIG"{print "signed by key tag",$11}'
#
# Different tags -> the anchor is from a KSK that no longer exists (a rollover
# where the anchor update was forgotten). Rebuild the anchor from the current
# KSK - the .key file line is DNSKEY rdata, and static-key takes the same
# fields (flags protocol algorithm "base64"):
#
#   KSKFILE=$(grep -l 'key-signing key' $LAB/auth/keys/K$ZONE.+*.key)
#   awk '!/^;/{for(i=1;i<=NF;i++) if($i=="DNSKEY"){s="";for(j=i+4;j<=NF;j++)s=s $j;
#        printf "trust-anchors {\n    \"'$ZONE'.\" static-key %s %s %s \"%s\";\n};\n",
#        $(i+1),$(i+2),$(i+3),s; exit}}' "$KSKFILE" > $LAB/resolver/trust-anchor.conf
#   named-checkconf $LAB/named-res.conf
#   # a trust-anchors change requires a reconfig + flush (or a restart):
#   $RNDC_RES reconfig && $RNDC_RES flush
#   dig @127.0.0.1 -p 5302 +dnssec www.$ZONE A | grep flags     # expect 'ad'
#
# Operational lesson: this is why RFC 5011 automated anchor rollover exists, and
# why BIND writes anchors as 'initial-key' (managed, auto-updating) rather than
# 'static-key' (frozen) wherever the zone supports it. A static anchor is a
# manual dependency you must include in every key-rollover runbook.
#
# -----------------------------------------------------------------------------
# STEP 3 - FAULT B: the DANE pin does not match the served certificate
# -----------------------------------------------------------------------------
# Now that DNS validates, the TLS monitor is still red. Compare the two halves.
#
#   # what DNS pins (usage 3 = DANE-EE, selector 1 = SPKI, mtype 1 = SHA-256):
#   dig +short @127.0.0.1 -p 5302 TLSA _8443._tcp.www.$ZONE
#   # what the server is actually presenting, hashed the same way:
#   echo Q | openssl s_client -connect 127.0.0.1:8443 2>/dev/null \
#     | openssl x509 -pubkey -noout \
#     | openssl pkey -pubin -outform DER \
#     | openssl dgst -sha256
#
# The hashes differ: the certificate/keypair was rotated and the pin was not
# republished. Note the selector - hashing the whole certificate (selector 0)
# would give yet another value; TLSA 3 1 1 hashes only the SubjectPublicKeyInfo,
# which is why selector 1 survives certificate renewal with the SAME key.
#
# Fix - regenerate the rdata from the live endpoint and publish it in the
# UNSIGNED source zone, then re-sign. Never edit db.$ZONE.signed: the next
# signing run overwrites it, and an edit there is unsigned data anyway.
#
#   HEX=$(echo Q | openssl s_client -connect 127.0.0.1:8443 2>/dev/null \
#         | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER \
#         | openssl dgst -sha256 | awk '{print $NF}')
#   echo "$HEX"
#   cd $LAB/auth
#   sed -i -E "s|^(_8443\._tcp\.www[[:space:]]+IN TLSA 3 1 1 ).*|\1$HEX|" db.$ZONE
#   grep TLSA db.$ZONE
#   named-checkzone $ZONE db.$ZONE
#   dnssec-signzone -S -K keys -o $ZONE -N INCREMENT -f db.$ZONE.signed db.$ZONE
#   $RNDC_AUTH reload $ZONE
#   $RNDC_RES flush
#
# Verify DANE end to end, taking the rdata from DNS (never from a local file -
# the point of DANE is that DNS is the authority):
#
#   RR=$(dig +short @127.0.0.1 -p 5302 TLSA _8443._tcp.www.$ZONE)
#   echo Q | openssl s_client -connect 127.0.0.1:8443 -servername www.$ZONE \
#       -dane_tls_domain www.$ZONE -dane_tls_rrdata "$RR" 2>&1 | \
#       grep -E 'DANE TLSA|Verify return code'
#     # -> DANE TLSA 3 1 1 ...ee1... matched EE certificate at depth 0
#     # -> Verify return code: 0 (ok)
#
# (A DANE-aware client would fetch that TLSA record through a VALIDATING
#  resolver and refuse to proceed on SERVFAIL. openssl s_client does no DNS
#  itself, hence -dane_tls_rrdata; tools such as 'danetool --check' or
#  hash-slinger's 'tlsa' do the lookup for you.)
#
# -----------------------------------------------------------------------------
# STEP 4 - Confirm and close
# -----------------------------------------------------------------------------
#   ./331.4-break-fix-dns-crypto.sh verify        # all six checks green
#   ./331.4-break-fix-dns-crypto.sh clean         # remove the lab
#
# -----------------------------------------------------------------------------
# WHAT THE EXAM EXPECTS YOU TO CARRY OUT OF THIS
# -----------------------------------------------------------------------------
# * dnssec-keygen / dnssec-signzone / dnssec-settime / dnssec-dsfromkey and what
#   each artifact is: K<zone>.+<alg>+<tag>.key (public DNSKEY, safe to publish),
#   .private (never leaves the signer), dsset-* (what the parent publishes),
#   db.zone.signed (what named serves).
# * KSK (flags 257, signs the DNSKEY RRset, anchored by the parent's DS) versus
#   ZSK (flags 256, signs everything else, rolled often and cheaply).
# * RRSIG / DNSKEY / DS / NSEC / NSEC3 / NSEC3PARAM and, for DANE, TLSA - plus
#   the sibling records SSHFP, OPENPGPKEY and SMIMEA which use the same idea.
# * dig +dnssec / +cd / +multiline and delv (+rtrace, +vtrace, -a anchorfile):
#   dig shows you the bytes, delv performs the validation and names the failure.
# * The AD flag means validated; the CD flag means "do not validate for me".
#   A client that sets CD to make an error disappear has disabled the control.
# * Signatures expire, keys roll, anchors go stale: DNSSEC failures are
#   overwhelmingly ${operational}, not cryptographic. dnssec-policy exists
#   precisely to take those duties away from humans.
# * DANE rollover order (RFC 7671 s8): publish the new TLSA record, wait at
#   least the record's TTL so caches converge, THEN deploy the new certificate,
#   and only afterwards withdraw the old TLSA record. This lab is what happens
#   when that order is reversed.
# * rndc talks to named over an authenticated channel using a TSIG key
#   (hmac-sha256) - the same mechanism (RFC 8945) that authenticates zone
#   transfers and dynamic updates.
#
# Objectives: https://www.lpi.org/our-certifications/exam-303-objectives/
# BIND DNSSEC guide: https://bind9.readthedocs.io/en/latest/dnssec-guide.html
# =============================================================================