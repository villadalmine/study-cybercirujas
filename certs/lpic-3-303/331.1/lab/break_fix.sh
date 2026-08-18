#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-3 303 (Security, exam 303-300 v3.0.0)
#  Topic 331.1 - X.509 Certificates and Public Key Infrastructures  (weight 8.34)
#
#  BREAK & FIX LAB:  "The leaked key incident"
#
#  This script builds a complete two-tier PKI (Root CA -> Intermediate CA ->
#  TLS server certificate), publishes it through nginx, installs the root as a
#  system trust anchor... and then breaks the deployment in three controlled,
#  layered ways that mirror a real post-incident mess:
#
#     1. the private key on disk does not match the deployed certificate
#     2. the served chain is incomplete (intermediate CA missing)
#     3. the deployed leaf certificate has no subjectAltName AND its serial
#        is listed in the Intermediate CA's CRL (revoked, keyCompromise)
#
#  Everything the script touches is listed in show_blast_radius(). It is meant
#  for a DISPOSABLE lab VM and nothing else. `cleanup` reverses every change.
#
#  Reference: https://www.lpi.org/our-certifications/exam-303-objectives/
#             (331.1 - X.509 Certificates and Public Key Infrastructures)
#
#  Usage:
#     sudo ./331.1-break-and-fix.sh break      # build the PKI and inject faults
#     sudo ./331.1-break-and-fix.sh verify     # grade your repair (10 checks)
#     sudo ./331.1-break-and-fix.sh hint [1-3] # progressive hints
#     sudo ./331.1-break-and-fix.sh solution   # print the commented walkthrough
#     sudo ./331.1-break-and-fix.sh cleanup    # remove every trace of the lab
#
#  Environment overrides:
#     PKILAB_PORT=8443            TLS port (default 443)
#     PKILAB_CONFIRM=yes-destroy-this-vm   skip the interactive confirmation
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Constants. LAB is hard-wired into the openssl.cnf files further down; if you
# change it here, the `dir` entries in build_pki() must change with it.
# ------------------------------------------------------------------------------
readonly LAB="/etc/pki/lab"
readonly LAB_HOST="pki-lab.example"
readonly WEBROOT="/var/www/pkilab"
readonly NGINX_CONF="/etc/nginx/conf.d/pkilab.conf"
readonly HOSTS_TAG="# pkilab-lab"
readonly MISSION="/root/pkilab-mission.txt"
readonly HINT_STATE="/root/.pkilab-hints"
PORT="${PKILAB_PORT:-443}"

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
    C_Y=$'\033[33m'; C_C=$'\033[36m'
else
    C_RST=''; C_B=''; C_R=''; C_G=''; C_Y=''; C_C=''
fi

info() { printf '%s[*]%s %s\n' "$C_C" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*"; }
fail() { printf '%s[-]%s %s\n' "$C_R" "$C_RST" "$*"; }
die()  { fail "$*"; exit 1; }
rule() { printf '%s%s%s\n' "$C_B" "$(printf '=%.0s' {1..78})" "$C_RST"; }

trap 'fail "aborted at line $LINENO (command: $BASH_COMMAND)"' ERR

url() { if [[ "$PORT" == "443" ]]; then echo "https://$LAB_HOST/"; else echo "https://$LAB_HOST:$PORT/"; fi; }

# ------------------------------------------------------------------------------
# Guards
# ------------------------------------------------------------------------------
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "run as root (sudo $0 $*)"
}

require_tools() {
    local missing=()
    for t in openssl curl awk sed grep; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
    info "openssl: $(openssl version)"
}

show_blast_radius() {
    cat <<EOF
This script will CREATE or OVERWRITE, on this machine:

  $LAB/                      complete lab PKI (root CA, intermediate CA, leaf)
  $WEBROOT/                  static page served over TLS
  $NGINX_CONF                nginx vhost on port ${PORT} (TLS) and 80 (CRL DP)
  /etc/hosts                 one tagged line: 127.0.0.1 $LAB_HOST
  system trust store         one extra anchor: PKI Lab Root CA
  $MISSION                   your mission briefing

It will also START/RESTART nginx. Nothing outside that list is touched, and
'$0 cleanup' removes all of it.
EOF
}

confirm_disposable() {
    rule
    printf '%s DISPOSABLE LAB VM ONLY %s\n' "$C_B$C_Y" "$C_RST"
    rule
    show_blast_radius
    rule
    if [[ "${PKILAB_CONFIRM:-}" == "yes-destroy-this-vm" ]]; then
        warn "PKILAB_CONFIRM set - proceeding without prompting"
        return 0
    fi
    [[ -t 0 ]] || die "no TTY: set PKILAB_CONFIRM=yes-destroy-this-vm to run unattended"
    local answer
    read -r -p "Type exactly 'BREAK MY LAB VM' to continue: " answer
    [[ "$answer" == "BREAK MY LAB VM" ]] || die "not confirmed - nothing was modified"
}

check_port_free() {
    if command -v ss >/dev/null 2>&1; then
        if ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
            # nginx re-runs of this lab are fine; a foreign listener is not.
            if ! ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -q 'nginx'; then
                die "port $PORT is already taken by a non-nginx process (set PKILAB_PORT=8443)"
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# Package / distro plumbing
# ------------------------------------------------------------------------------
install_nginx() {
    command -v nginx >/dev/null 2>&1 && { info "nginx already installed"; return 0; }
    info "installing nginx..."
    if   command -v dnf     >/dev/null 2>&1; then dnf install -y nginx >/dev/null
    elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null
    elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install nginx >/dev/null
    elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm nginx >/dev/null
    else die "no supported package manager found - install nginx manually and re-run"
    fi
    command -v nginx >/dev/null 2>&1 || die "nginx installation failed"
    ok "nginx installed"
}

# Returns the distro's local trust-anchor directory and the extraction command.
trust_anchor_dir() {
    if   [[ -d /etc/pki/ca-trust/source/anchors ]];      then echo /etc/pki/ca-trust/source/anchors
    elif [[ -d /usr/local/share/ca-certificates ]];      then echo /usr/local/share/ca-certificates
    elif [[ -d /etc/pki/trust/anchors ]];                then echo /etc/pki/trust/anchors
    elif [[ -d /etc/ca-certificates/trust-source/anchors ]]; then echo /etc/ca-certificates/trust-source/anchors
    else echo ""; fi
}

trust_update() {
    if   command -v update-ca-trust        >/dev/null 2>&1; then update-ca-trust extract
    elif command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/dev/null 2>&1
    elif command -v trust                  >/dev/null 2>&1; then trust extract-compat
    else warn "no trust-store update tool found; curl will need --cacert"; fi
}

# ==============================================================================
# PKI construction
# ==============================================================================
write_openssl_configs() {
    # ---- Root CA -------------------------------------------------------------
    # Note the escaped \$dir: those must survive bash and be expanded by OpenSSL.
    cat > "$LAB/root/openssl.cnf" <<EOF
# Root CA - offline trust anchor for the lab PKI (LPIC-3 331.1)
[ ca ]
default_ca        = CA_default

[ CA_default ]
dir               = $LAB/root
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/ca.key.pem
certificate       = \$dir/certs/ca.cert.pem
crlnumber         = \$dir/crlnumber
crl               = $LAB/crl/root.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 3650
preserve          = no
email_in_dn       = no
policy            = policy_strict
copy_extensions   = none

# A root CA only ever signs its own subordinates: the DN must line up.
[ policy_strict ]
countryName            = match
stateOrProvinceName    = match
organizationName       = match
organizationalUnitName = optional
commonName             = supplied
emailAddress           = optional

[ req ]
default_bits       = 4096
default_md         = sha256
string_mask        = utf8only
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
countryName            = AR
stateOrProvinceName    = Buenos Aires
organizationName       = PKI Lab
organizationalUnitName = Lab Root
commonName             = PKI Lab Root CA

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
crlDistributionPoints  = URI:http://$LAB_HOST/crl/root.crl.pem

[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF

    # ---- Intermediate (issuing) CA ------------------------------------------
    cat > "$LAB/intermediate/openssl.cnf" <<EOF
# Intermediate / issuing CA - signs end-entity (leaf) certificates
[ ca ]
default_ca        = CA_default

[ CA_default ]
dir               = $LAB/intermediate
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/intermediate.key.pem
certificate       = \$dir/certs/intermediate.cert.pem
crlnumber         = \$dir/crlnumber
crl               = $LAB/crl/intermediate.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 365
preserve          = no
email_in_dn       = no
policy            = policy_loose
copy_extensions   = none

# An issuing CA serves many subjects: only the CN is mandatory.
[ policy_loose ]
countryName            = optional
stateOrProvinceName    = optional
localityName           = optional
organizationName       = optional
organizationalUnitName = optional
commonName             = supplied
emailAddress           = optional

[ req ]
default_bits       = 2048
default_md         = sha256
string_mask        = utf8only
distinguished_name = req_distinguished_name
prompt             = no

[ req_distinguished_name ]
countryName            = AR
stateOrProvinceName    = Buenos Aires
organizationName       = PKI Lab
organizationalUnitName = Lab Issuing
commonName             = $LAB_HOST

# CORRECT end-entity profile: this is the one you are supposed to use.
[ server_cert ]
basicConstraints       = CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = @alt_names
crlDistributionPoints  = URI:http://$LAB_HOST/crl/intermediate.crl.pem
authorityInfoAccess    = caIssuers;URI:http://$LAB_HOST/crl/intermediate.cert.pem

[ alt_names ]
DNS.1 = $LAB_HOST
DNS.2 = www.$LAB_HOST
DNS.3 = localhost
IP.1  = 127.0.0.1

# BROKEN profile used to mint the certificate currently in production:
# no subjectAltName at all, so the identity lives only in the CN. Every
# RFC 6125 compliant client (curl, browsers, Go, Java 11+) rejects it.
[ server_cert_nosan ]
basicConstraints       = CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
crlDistributionPoints  = URI:http://$LAB_HOST/crl/intermediate.crl.pem

[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF
}

init_ca_dir() {
    local d="$1"
    mkdir -p "$d"/{certs,crl,csr,newcerts,private}
    chmod 700 "$d/private"
    : > "$d/index.txt"
    echo 'unique_subject = no' > "$d/index.txt.attr"   # allow re-issuing the same CN
    echo 1000 > "$d/serial"
    echo 1000 > "$d/crlnumber"
}

pubkey_fp_cert() { openssl x509 -in "$1" -noout -pubkey | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
pubkey_fp_key()  { openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }

build_pki() {
    info "building the lab PKI under $LAB ..."
    rm -rf "$LAB"
    mkdir -p "$LAB"/{root,intermediate,server,private,crl}
    chmod 700 "$LAB/private"
    init_ca_dir "$LAB/root"
    init_ca_dir "$LAB/intermediate"
    write_openssl_configs

    # ---- 1. Root CA key + self-signed certificate ---------------------------
    (umask 077; openssl genrsa -out "$LAB/root/private/ca.key.pem" 4096 2>/dev/null)
    chmod 400 "$LAB/root/private/ca.key.pem"
    openssl req -config "$LAB/root/openssl.cnf" \
        -key "$LAB/root/private/ca.key.pem" \
        -new -x509 -days 7300 -sha256 -extensions v3_ca \
        -subj "/C=AR/ST=Buenos Aires/O=PKI Lab/OU=Lab Root/CN=PKI Lab Root CA" \
        -out "$LAB/root/certs/ca.cert.pem"
    ok "root CA: $(openssl x509 -noout -subject -in "$LAB/root/certs/ca.cert.pem" | sed 's/^subject=//')"

    # ---- 2. Intermediate CA: key -> CSR -> signed by the root ---------------
    (umask 077; openssl genrsa -out "$LAB/intermediate/private/intermediate.key.pem" 4096 2>/dev/null)
    chmod 400 "$LAB/intermediate/private/intermediate.key.pem"
    openssl req -config "$LAB/intermediate/openssl.cnf" -new -sha256 \
        -key "$LAB/intermediate/private/intermediate.key.pem" \
        -subj "/C=AR/ST=Buenos Aires/O=PKI Lab/OU=Lab Issuing/CN=PKI Lab Intermediate CA" \
        -out "$LAB/intermediate/csr/intermediate.csr.pem"
    openssl ca -batch -config "$LAB/root/openssl.cnf" \
        -extensions v3_intermediate_ca -days 3650 -notext -md sha256 \
        -in  "$LAB/intermediate/csr/intermediate.csr.pem" \
        -out "$LAB/intermediate/certs/intermediate.cert.pem" >/dev/null 2>&1
    chmod 444 "$LAB/intermediate/certs/intermediate.cert.pem"
    # The chain file is intermediate-first: that is the order TLS requires.
    cat "$LAB/intermediate/certs/intermediate.cert.pem" \
        "$LAB/root/certs/ca.cert.pem" > "$LAB/intermediate/certs/ca-chain.cert.pem"
    ok "intermediate CA signed (pathlen:0)"

    # ---- 3. End-entity certificate, minted with the BROKEN profile ----------
    (umask 077; openssl genrsa -out "$LAB/private/server.key" 2048 2>/dev/null)
    chmod 400 "$LAB/private/server.key"
    openssl req -config "$LAB/intermediate/openssl.cnf" -new -sha256 \
        -key "$LAB/private/server.key" \
        -subj "/C=AR/ST=Buenos Aires/O=PKI Lab/OU=Web/CN=$LAB_HOST" \
        -out "$LAB/server/server.csr"
    openssl ca -batch -config "$LAB/intermediate/openssl.cnf" \
        -extensions server_cert_nosan -days 365 -notext -md sha256 \
        -in "$LAB/server/server.csr" -out "$LAB/server/server.crt" >/dev/null 2>&1
    chmod 444 "$LAB/server/server.crt"

    # Fingerprint of the key that is about to be declared compromised. The
    # grader uses it to prove you rotated the key instead of reusing it.
    pubkey_fp_key "$LAB/private/server.key" > "$LAB/.compromised-key.sha256"

    # PKCS#12 archive: leaf + key + chain, protected by a password on disk.
    # This is the only surviving copy of the key that matches server.crt.
    echo 'Lab-P12-Passw0rd' > "$LAB/private/p12.pass"
    chmod 400 "$LAB/private/p12.pass"
    openssl pkcs12 -export \
        -inkey "$LAB/private/server.key" \
        -in    "$LAB/server/server.crt" \
        -certfile "$LAB/intermediate/certs/ca-chain.cert.pem" \
        -name "$LAB_HOST" \
        -passout "file:$LAB/private/p12.pass" \
        -out "$LAB/private/server-archive.p12"
    chmod 400 "$LAB/private/server-archive.p12"

    # ---- 4. Revoke the leaf (simulated key compromise) and publish CRLs -----
    openssl ca -config "$LAB/intermediate/openssl.cnf" \
        -revoke "$LAB/server/server.crt" -crl_reason keyCompromise >/dev/null 2>&1
    openssl ca -batch -config "$LAB/intermediate/openssl.cnf" \
        -gencrl -out "$LAB/crl/intermediate.crl.pem" >/dev/null 2>&1
    openssl ca -batch -config "$LAB/root/openssl.cnf" \
        -gencrl -out "$LAB/crl/root.crl.pem" >/dev/null 2>&1
    cp "$LAB/intermediate/certs/intermediate.cert.pem" "$LAB/crl/intermediate.cert.pem"
    cp "$LAB/root/certs/ca.cert.pem" "$LAB/crl/root.cert.pem"
    chmod 644 "$LAB/crl"/*.pem
    ok "CRLs published (leaf serial $(openssl x509 -noout -serial -in "$LAB/server/server.crt" | cut -d= -f2) revoked: keyCompromise)"

    # ---- 5. Deploy ----------------------------------------------------------
    cat "$LAB/server/server.crt" \
        "$LAB/intermediate/certs/intermediate.cert.pem" > "$LAB/server/fullchain.crt"
    chmod 444 "$LAB/server/fullchain.crt"
}

install_trust_anchor() {
    local dir; dir="$(trust_anchor_dir)"
    [[ -n "$dir" ]] || { warn "unknown trust store layout - skipping anchor install"; return 0; }
    cp "$LAB/root/certs/ca.cert.pem" "$dir/pkilab-root.crt"
    trust_update
    ok "root CA installed as a system trust anchor ($dir/pkilab-root.crt)"
}

deploy_endpoint() {
    mkdir -p "$WEBROOT"
    cat > "$WEBROOT/index.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>PKI Lab</title></head>
<body><h1>pki-lab.example is serving TLS</h1>
<p>LPIC-3 303 / 331.1 - X.509 Certificates and Public Key Infrastructures</p>
</body></html>
EOF

    cat > "$NGINX_CONF" <<EOF
# LPIC-3 331.1 lab endpoint - created by the break & fix script
server {
    listen ${PORT} ssl;
    server_name ${LAB_HOST} www.${LAB_HOST};

    # The server must present leaf + every intermediate, in that order.
    # The root is NOT sent: the client is expected to already trust it.
    ssl_certificate     ${LAB}/server/fullchain.crt;
    ssl_certificate_key ${LAB}/private/server.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:pkilab:1m;

    root  ${WEBROOT};
    index index.html;
}

server {
    # CRL distribution point referenced by crlDistributionPoints in the certs.
    listen 80;
    server_name ${LAB_HOST} www.${LAB_HOST};
    location /crl/ {
        alias ${LAB}/crl/;
        autoindex on;
        default_type application/x-pem-file;
    }
}
EOF

    grep -q "$HOSTS_TAG" /etc/hosts || \
        echo "127.0.0.1 ${LAB_HOST} www.${LAB_HOST}  ${HOSTS_TAG}" >> /etc/hosts

    command -v restorecon >/dev/null 2>&1 && restorecon -R "$LAB" "$WEBROOT" >/dev/null 2>&1 || true
    systemctl enable nginx >/dev/null 2>&1 || true
}

# ==============================================================================
# Fault injection
# ==============================================================================
inject_faults() {
    rule
    info "injecting faults ..."

    # FAULT 1 - key/certificate mismatch.
    # After the "incident" someone rotated the key file but never re-issued the
    # certificate, so the modulus of server.key no longer matches server.crt.
    (umask 077; openssl genrsa -out "$LAB/private/server.key" 2048 2>/dev/null)
    chmod 400 "$LAB/private/server.key"

    # FAULT 2 - truncated chain: only the leaf is deployed, no intermediate.
    cp "$LAB/server/server.crt" "$LAB/server/fullchain.crt"
    chmod 444 "$LAB/server/fullchain.crt"

    # FAULT 3 - already baked into the artifacts: the leaf has no
    # subjectAltName and its serial sits in the Intermediate CA's CRL.

    ok "3 faults injected"

    # Let the failure be observable exactly as the student will meet it.
    systemctl restart nginx >/dev/null 2>&1 || true
}

# ==============================================================================
# Mission briefing
# ==============================================================================
write_mission() {
    local u; u="$(url)"
    cat > "$MISSION" <<EOF
================================================================================
 LPIC-3 303 / 331.1  -  BREAK & FIX  -  "The leaked key incident"
================================================================================

BACKGROUND
  ${LAB_HOST} is an internal service fronted by nginx. Its PKI is two tiers:

      PKI Lab Root CA          $LAB/root/          (offline trust anchor)
        └── PKI Lab Intermediate CA   $LAB/intermediate/   (issuing CA)
              └── ${LAB_HOST}         $LAB/server/         (end entity)

  The root is already installed in this machine's system trust store, so a
  correctly deployed service must validate with plain 'curl https://...',
  with no -k and no --cacert.

  Last night the end-entity private key was found in a public paste. The key
  was revoked (reason: keyCompromise) and someone dropped a freshly generated
  key onto the server "to rotate it". They did not re-issue the certificate,
  and they did not finish. Then they went home.

SYMPTOMS YOU WILL SEE (in this order, each one hides the next)
  1) The service is DOWN. 'systemctl status nginx' is failed and the journal
     shows something like:
        nginx: [emerg] SSL_CTX_use_PrivateKey_file("$LAB/private/server.key")
        failed (SSL: error:05800074:x509 certificate routines::key values mismatch)

  2) Once it starts, clients still refuse the connection:
        curl: (60) SSL certificate problem: unable to get local issuer certificate
        openssl s_client ... -> verify error:num=20:unable to get local issuer certificate
     even though the root CA is trusted by this machine.

  3) Once the chain validates, the identity check still fails:
        curl: (60) SSL: no alternative certificate subject name matches
              target host name 'pki-lab.example'
     and any revocation-aware validation fails as well:
        openssl verify -crl_check_all ... -> error 23 at 0 depth lookup:
        certificate revoked

YOUR MISSION
  Phase A - restore service:   nginx must start and complete a TLS handshake.
  Phase B - make it compliant: the endpoint must pass all ten grader checks.

SUCCESS CRITERIA (this is exactly what '$0 verify' asserts)
  1.  TLS handshake on ${u} succeeds
  2.  The server sends leaf + intermediate (>= 2 certificates)
  3.  The chain verifies against the root using ONLY what the server sent
  4.  The leaf carries a subjectAltName with DNS:${LAB_HOST}
  5.  Hostname verification passes (openssl verify -verify_hostname)
  6.  'curl https://${LAB_HOST}${PORT:+}' succeeds against the SYSTEM trust store
  7.  basicConstraints CA:FALSE, keyUsage digitalSignature+keyEncipherment,
      extendedKeyUsage serverAuth
  8.  The leaf is issued by the Intermediate CA (not by the root, not self-signed)
  9.  'openssl verify -crl_check_all' passes: the served certificate is NOT
      listed in any CRL, and both CRLs are current
  10. The served certificate does NOT reuse the compromised public key

RULES OF ENGAGEMENT
  - Do not turn verification off. Fixing this with 'ssl_verify_client off',
    'curl -k', or by deleting the CRLs is not a fix.
  - Do not re-create the CA. The root and intermediate keys are intact and
    must stay as they are; only the end entity is broken.
  - Everything you need is on the box. In particular:
        $LAB/private/server-archive.p12   PKCS#12 archive (leaf + key + chain)
        $LAB/private/p12.pass             its password, in a file
        $LAB/intermediate/openssl.cnf     has a correct [ server_cert ] profile
                                          and an [ alt_names ] section

USEFUL STARTING POINTS
  journalctl -u nginx -n 30 --no-pager
  nginx -t
  openssl x509 -noout -text -in $LAB/server/server.crt
  openssl x509 -noout -modulus -in $LAB/server/server.crt | openssl sha256
  openssl rsa  -noout -modulus -in $LAB/private/server.key | openssl sha256
  openssl s_client -connect 127.0.0.1:${PORT} -servername ${LAB_HOST} -showcerts </dev/null
  openssl crl -noout -text -in $LAB/crl/intermediate.crl.pem
  openssl ca -config $LAB/intermediate/openssl.cnf -status <serial>

GRADE YOURSELF
  $0 verify
  $0 hint 1 | 2 | 3
  $0 solution     (full walkthrough - only after you have tried)
================================================================================
EOF
    chmod 600 "$MISSION"
}

# ==============================================================================
# Grader
# ==============================================================================
TMPD=""
setup_tmp() {
    TMPD="$(mktemp -d /tmp/pkilab-verify.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$TMPD'" EXIT
}

PASS=0; FAILED=0
check() {
    local name="$1"; shift
    if "$@" >"$TMPD/out" 2>&1; then
        ok "$name"; PASS=$((PASS+1)); return 0
    else
        fail "$name"
        sed 's/^/        /' "$TMPD/out" | head -6
        FAILED=$((FAILED+1)); return 1
    fi
}

fetch_chain() {
    openssl s_client -connect "127.0.0.1:$PORT" -servername "$LAB_HOST" \
        -showcerts </dev/null >"$TMPD/sclient.txt" 2>"$TMPD/sclient.err" || return 1
    awk '/-----BEGIN CERTIFICATE-----/{n++} n{print > "'"$TMPD"'/cert-" n ".pem"}' "$TMPD/sclient.txt"
    [[ -s "$TMPD/cert-1.pem" ]] || return 1
    cp "$TMPD/cert-1.pem" "$TMPD/leaf.pem"
    : > "$TMPD/untrusted.pem"
    local i=2
    while [[ -f "$TMPD/cert-$i.pem" ]]; do cat "$TMPD/cert-$i.pem" >> "$TMPD/untrusted.pem"; i=$((i+1)); done
    echo $((i-1)) > "$TMPD/chain_count"
    return 0
}

cmd_verify() {
    require_root
    [[ -d "$LAB" ]] || die "lab not found - run '$0 break' first"
    setup_tmp
    rule
    printf '%s GRADING %s   endpoint: %s\n' "$C_B" "$C_RST" "$(url)"
    rule

    # --- service up -----------------------------------------------------------
    if systemctl is-active --quiet nginx; then ok "nginx is active"; PASS=$((PASS+1))
    else fail "nginx is not active (systemctl status nginx; journalctl -u nginx -n 30)"; FAILED=$((FAILED+1)); fi

    # --- 1. handshake ---------------------------------------------------------
    if fetch_chain; then
        ok "1. TLS handshake completed and a certificate was received"; PASS=$((PASS+1))
    else
        fail "1. TLS handshake failed"
        sed 's/^/        /' "$TMPD/sclient.err" 2>/dev/null | head -5
        FAILED=$((FAILED+1))
        rule; printf '%sscore: %d passed / %d failed%s\n' "$C_R" "$PASS" "$FAILED" "$C_RST"
        exit 1
    fi

    local n; n="$(cat "$TMPD/chain_count")"
    local root="$LAB/root/certs/ca.cert.pem"

    # --- 2. chain completeness ------------------------------------------------
    if [[ "$n" -ge 2 ]]; then ok "2. server sent $n certificates (leaf + intermediate)"; PASS=$((PASS+1))
    else fail "2. server sent only $n certificate - the intermediate is missing from ssl_certificate"; FAILED=$((FAILED+1)); fi

    # --- 3. chain validates using only what the server sent -------------------
    check "3. chain verifies against the root using only the served chain" \
        openssl verify -CAfile "$root" -untrusted "$TMPD/untrusted.pem" "$TMPD/leaf.pem"

    # --- 4. subjectAltName ----------------------------------------------------
    if openssl x509 -in "$TMPD/leaf.pem" -noout -text \
        | grep -A1 'Subject Alternative Name' | grep -q "DNS:$LAB_HOST"; then
        ok "4. leaf carries subjectAltName DNS:$LAB_HOST"; PASS=$((PASS+1))
    else
        fail "4. leaf has no subjectAltName matching $LAB_HOST (CN alone is not an identity since RFC 6125)"; FAILED=$((FAILED+1))
    fi

    # --- 5. hostname verification --------------------------------------------
    check "5. hostname verification passes (-verify_hostname $LAB_HOST)" \
        openssl verify -CAfile "$root" -untrusted "$TMPD/untrusted.pem" \
                       -verify_hostname "$LAB_HOST" "$TMPD/leaf.pem"

    # --- 6. real client against the system trust store ------------------------
    check "6. curl succeeds against the system trust store (no -k, no --cacert)" \
        curl -sS --max-time 10 -o /dev/null "$(url)"

    # --- 7. end-entity profile ------------------------------------------------
    openssl x509 -in "$TMPD/leaf.pem" -noout -text > "$TMPD/leaf.txt"
    local prof_ok=1
    grep -q 'CA:FALSE' "$TMPD/leaf.txt" || { prof_ok=0; echo "        missing basicConstraints CA:FALSE"; }
    grep -q 'Digital Signature' "$TMPD/leaf.txt" || { prof_ok=0; echo "        missing keyUsage digitalSignature"; }
    grep -q 'TLS Web Server Authentication' "$TMPD/leaf.txt" || { prof_ok=0; echo "        missing extendedKeyUsage serverAuth"; }
    if [[ "$prof_ok" -eq 1 ]]; then ok "7. end-entity profile is correct (CA:FALSE, digitalSignature, serverAuth)"; PASS=$((PASS+1))
    else fail "7. end-entity profile is wrong - re-issue with -extensions server_cert"; FAILED=$((FAILED+1)); fi

    # --- 8. issued by the intermediate ---------------------------------------
    local leaf_issuer int_subject
    leaf_issuer="$(openssl x509 -in "$TMPD/leaf.pem" -noout -issuer_hash)"
    int_subject="$(openssl x509 -in "$LAB/intermediate/certs/intermediate.cert.pem" -noout -subject_hash)"
    if [[ "$leaf_issuer" == "$int_subject" ]]; then ok "8. leaf is issued by the Intermediate CA"; PASS=$((PASS+1))
    else fail "8. leaf is NOT issued by the Intermediate CA (issuer_hash $leaf_issuer)"; FAILED=$((FAILED+1)); fi

    # --- 9. revocation --------------------------------------------------------
    cat "$LAB/crl/root.crl.pem" "$LAB/crl/intermediate.crl.pem" > "$TMPD/all.crl" 2>/dev/null || true
    if openssl verify -crl_check_all -CAfile "$root" -untrusted "$TMPD/untrusted.pem" \
        -CRLfile "$TMPD/all.crl" "$TMPD/leaf.pem" >"$TMPD/out" 2>&1; then
        ok "9. revocation check passes (serial $(openssl x509 -in "$TMPD/leaf.pem" -noout -serial | cut -d= -f2) not on any CRL)"
        PASS=$((PASS+1))
    else
        fail "9. revocation check FAILED"
        sed 's/^/        /' "$TMPD/out" | head -4
        FAILED=$((FAILED+1))
    fi

    # --- 10. key rotation -----------------------------------------------------
    local served_fp bad_fp
    served_fp="$(pubkey_fp_cert "$TMPD/leaf.pem")"
    bad_fp="$(cat "$LAB/.compromised-key.sha256" 2>/dev/null || echo none)"
    if [[ "$served_fp" != "$bad_fp" ]]; then ok "10. the compromised key was rotated out"; PASS=$((PASS+1))
    else fail "10. the served certificate still binds the COMPROMISED public key - generate a new key pair"; FAILED=$((FAILED+1)); fi

    # --- expiry (informational) ----------------------------------------------
    if openssl x509 -in "$TMPD/leaf.pem" -noout -checkend 86400 >/dev/null 2>&1; then
        info "notAfter: $(openssl x509 -in "$TMPD/leaf.pem" -noout -enddate | cut -d= -f2)"
    else
        warn "the served certificate expires within 24 h"
    fi

    rule
    if [[ "$FAILED" -eq 0 ]]; then
        printf '%s ALL CHECKS PASSED (%d/%d). The PKI is healthy.%s\n' "$C_G$C_B" "$PASS" "$PASS" "$C_RST"
        rule; exit 0
    else
        printf '%s %d passed / %d failed - keep going ('"$0"' hint 1)%s\n' "$C_Y" "$PASS" "$FAILED" "$C_RST"
        rule; exit 1
    fi
}

# ==============================================================================
# Hints
# ==============================================================================
cmd_hint() {
    local n="${1:-1}"
    rule
    case "$n" in
      1) cat <<EOF
HINT 1/3 - get the service to start

  nginx refuses to load a keypair whose public parts disagree. Prove it:

      openssl x509 -noout -modulus -in $LAB/server/server.crt | openssl sha256
      openssl rsa  -noout -modulus -in $LAB/private/server.key | openssl sha256

  Two different digests = mismatch. You have two legitimate ways out:
    (a) recover the key that DOES match, from the PKCS#12 archive
        ($LAB/private/server-archive.p12, password in p12.pass) - fastest
        way back online, but that key is the compromised one; or
    (b) skip straight to issuing a brand-new keypair and certificate.

  Option (b) is where you must end up anyway (criterion 10).
EOF
        ;;
      2) cat <<EOF
HINT 2/3 - make the chain and the identity valid

  Look at what the server actually sends:

      openssl s_client -connect 127.0.0.1:$PORT -servername $LAB_HOST \\
          -showcerts </dev/null | grep -c 'BEGIN CERTIFICATE'

  One certificate is not a chain. 'ssl_certificate' in nginx must point at a
  file containing leaf FIRST, then every intermediate. The root is never sent.

  Then look at the leaf itself:

      openssl x509 -noout -text -in $LAB/server/server.crt | grep -A1 'Alternative'

  Nothing. Since RFC 6125 the CN is not an identity; the name must be in
  subjectAltName. Extensions do NOT travel from the CSR by default
  (copy_extensions = none), so the SAN has to come from the signing profile:
  [ server_cert ] + [ alt_names ] already exist in
  $LAB/intermediate/openssl.cnf.
EOF
        ;;
      3) cat <<EOF
HINT 3/3 - revocation and rotation

      openssl crl -noout -text -in $LAB/crl/intermediate.crl.pem
      openssl x509 -noout -serial -in $LAB/server/server.crt

  The serial you are serving is on the CRL with reason keyCompromise. A
  revocation is permanent: there is no un-revoke, and re-signing the same CSR
  would only mint a new serial around the SAME leaked public key. The only
  correct remedy is a new key pair -> new CSR -> new certificate signed with
  'openssl ca -extensions server_cert' -> new fullchain -> reload nginx.

  Sequence of commands, in order:
      openssl genrsa
      openssl req -new -key ... -out ...csr
      openssl ca -config .../intermediate/openssl.cnf -extensions server_cert
      cat newleaf intermediate > fullchain
      nginx -t && systemctl restart nginx
EOF
        ;;
      *) die "hints are 1, 2 or 3" ;;
    esac
    rule
    echo "$n" > "$HINT_STATE"
}

# ==============================================================================
# Solution printer - prints the commented block at the bottom of this file
# ==============================================================================
cmd_solution() {
    rule
    warn "printing the full walkthrough"
    rule
    sed -n '/^# >>> SOLUTION <<</,$p' "$0" | sed 's/^# \{0,1\}//'
}

# ==============================================================================
# Cleanup
# ==============================================================================
cmd_cleanup() {
    require_root
    info "removing the lab ..."
    systemctl stop nginx >/dev/null 2>&1 || true
    rm -f "$NGINX_CONF"
    rm -rf "$WEBROOT"
    [[ "$LAB" == "/etc/pki/lab" ]] && rm -rf "$LAB"
    sed -i "/${HOSTS_TAG}\$/d" /etc/hosts
    local dir; dir="$(trust_anchor_dir)"
    [[ -n "$dir" ]] && rm -f "$dir/pkilab-root.crt"
    trust_update
    rm -f "$MISSION" "$HINT_STATE"
    systemctl start nginx >/dev/null 2>&1 || true
    ok "lab removed (trust anchor, vhost, hosts entry, $LAB, mission file)"
}

# ==============================================================================
# break
# ==============================================================================
cmd_break() {
    require_root
    require_tools
    confirm_disposable
    check_port_free
    install_nginx
    build_pki
    install_trust_anchor
    deploy_endpoint
    inject_faults
    write_mission
    echo
    cat "$MISSION"
    echo
    rule
    warn "the service is DOWN on purpose. Start with: journalctl -u nginx -n 30 --no-pager"
    info "this briefing is saved at $MISSION"
    info "grade yourself with: $0 verify"
    rule
}

usage() {
    cat <<EOF
LPIC-3 303 / 331.1 - X.509 Certificates and Public Key Infrastructures
break & fix lab (disposable VM only)

  $0 break      build the PKI, deploy it, inject 3 faults, print the briefing
  $0 verify     grade the current state (10 checks)
  $0 hint [N]   progressive hints, N = 1..3
  $0 solution   print the full step-by-step walkthrough
  $0 cleanup    undo everything this script created
EOF
}

main() {
    case "${1:-break}" in
        break)    cmd_break ;;
        verify)   cmd_verify ;;
        hint)     cmd_hint "${2:-1}" ;;
        solution) cmd_solution ;;
        cleanup)  cmd_cleanup ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
exit $?

# >>> SOLUTION <<<
# ==============================================================================
#  STEP-BY-STEP SOLUTION - 331.1 break & fix "The leaked key incident"
#  (do not read this until you have worked the three symptoms yourself)
# ==============================================================================
#
#  ---------------------------------------------------------------------------
#  STEP 0 - Read the failure, do not guess it
#  ---------------------------------------------------------------------------
#      systemctl status nginx --no-pager
#      journalctl -u nginx -n 30 --no-pager
#      nginx -t
#
#  Expected:
#      nginx: [emerg] SSL_CTX_use_PrivateKey_file("/etc/pki/lab/private/server.key")
#      failed (SSL: error:05800074:x509 certificate routines::key values mismatch)
#      nginx: configuration file /etc/nginx/nginx.conf test failed
#
#  "key values mismatch" is unambiguous: the certificate's SubjectPublicKeyInfo
#  and the private key are not two halves of the same pair.
#
#  ---------------------------------------------------------------------------
#  STEP 1 - Prove the mismatch (the canonical modulus comparison)
#  ---------------------------------------------------------------------------
#      openssl x509 -noout -modulus -in /etc/pki/lab/server/server.crt | openssl sha256
#      openssl rsa  -noout -modulus -in /etc/pki/lab/private/server.key | openssl sha256
#
#  Expected: two DIFFERENT digests. The algorithm-agnostic equivalent, which
#  also works for EC keys, is to compare the public keys themselves:
#
#      openssl x509 -in /etc/pki/lab/server/server.crt -noout -pubkey | openssl sha256
#      openssl pkey -in /etc/pki/lab/private/server.key -pubout        | openssl sha256
#
#  ---------------------------------------------------------------------------
#  STEP 2 - (Phase A, optional) Recover the matching key from the PKCS#12
#  ---------------------------------------------------------------------------
#  This is the "get it back online now" move. Inspect the archive first:
#
#      openssl pkcs12 -info -nokeys -in /etc/pki/lab/private/server-archive.p12 \
#          -passin file:/etc/pki/lab/private/p12.pass
#
#  Extract the private key (-nodes / -noenc writes it unencrypted, which is
#  what nginx needs since it cannot prompt for a passphrase at boot):
#
#      umask 077
#      openssl pkcs12 -in /etc/pki/lab/private/server-archive.p12 \
#          -passin file:/etc/pki/lab/private/p12.pass \
#          -nocerts -nodes -out /etc/pki/lab/private/server-recovered.key
#      chmod 400 /etc/pki/lab/private/server-recovered.key
#
#  Confirm it matches the deployed certificate, then point nginx at it:
#      openssl pkey -in /etc/pki/lab/private/server-recovered.key -pubout | openssl sha256
#      # -> same digest as the certificate's pubkey
#
#  Note for the exam: on OpenSSL 3.x, -nodes is spelled -noenc (both accepted),
#  and reading a legacy RC2-encrypted .p12 may require -legacy.
#
#  ---------------------------------------------------------------------------
#  STEP 3 - Understand why STEP 2 is not the end
#  ---------------------------------------------------------------------------
#      openssl x509 -noout -serial -in /etc/pki/lab/server/server.crt
#      openssl crl  -noout -text  -in /etc/pki/lab/crl/intermediate.crl.pem
#      openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
#          -status <serial-from-above>
#
#  Expected: that serial appears under "Revoked Certificates" with
#  "CRL entry extensions: X509v3 CRL Reason Code: Key Compromise", and
#  'openssl ca -status' answers "Revoked (K)".
#
#      openssl x509 -noout -text -in /etc/pki/lab/server/server.crt \
#          | grep -A1 'Subject Alternative Name'
#
#  Expected: no output at all - there is no SAN extension.
#
#  Two structural defects, one remedy: issue a NEW certificate over a NEW key
#  pair, using the correct extension profile. Revocation cannot be undone, and
#  re-signing the same CSR would just re-bind the leaked public key.
#
#  ---------------------------------------------------------------------------
#  STEP 4 - New key pair (the compromised one must never come back)
#  ---------------------------------------------------------------------------
#      umask 077
#      openssl genrsa -out /etc/pki/lab/private/server-new.key 2048
#      chmod 400 /etc/pki/lab/private/server-new.key
#
#  EC is equally valid and cheaper on the handshake:
#      openssl ecparam -name prime256v1 -genkey -noout \
#          -out /etc/pki/lab/private/server-new.key
#
#  ---------------------------------------------------------------------------
#  STEP 5 - New CSR
#  ---------------------------------------------------------------------------
#      openssl req -config /etc/pki/lab/intermediate/openssl.cnf \
#          -new -sha256 \
#          -key /etc/pki/lab/private/server-new.key \
#          -subj "/C=AR/ST=Buenos Aires/O=PKI Lab/OU=Web/CN=pki-lab.example" \
#          -out /etc/pki/lab/server/server-new.csr
#
#      openssl req -noout -text -verify -in /etc/pki/lab/server/server-new.csr
#      # "Certificate request self-signature verify OK" proves the CSR was
#      # signed by the key it carries - that is a proof of possession, nothing
#      # more. A CSR is a request, not a certificate: it asserts identity, the
#      # CA decides it.
#
#  ---------------------------------------------------------------------------
#  STEP 6 - Sign it with the CORRECT profile
#  ---------------------------------------------------------------------------
#  The lab CA runs with copy_extensions = none, so extensions in the CSR are
#  deliberately ignored (otherwise any requester could ask for CA:TRUE). The
#  SAN must therefore come from the CA's own profile:
#
#      openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
#          -extensions server_cert -days 365 -notext -md sha256 \
#          -in  /etc/pki/lab/server/server-new.csr \
#          -out /etc/pki/lab/server/server-new.crt
#
#  Answer 'y' twice (or add -batch). The issuing CA records the new row in
#  /etc/pki/lab/intermediate/index.txt with flag V and increments serial.
#
#  Verify the profile before deploying it:
#      openssl x509 -noout -text -in /etc/pki/lab/server/server-new.crt | sed -n '/X509v3/,/Signature Algorithm/p'
#  Expected to contain:
#      X509v3 Basic Constraints: CA:FALSE
#      X509v3 Key Usage: critical  Digital Signature, Key Encipherment
#      X509v3 Extended Key Usage:  TLS Web Server Authentication
#      X509v3 Subject Alternative Name:
#          DNS:pki-lab.example, DNS:www.pki-lab.example, DNS:localhost, IP Address:127.0.0.1
#      X509v3 CRL Distribution Points: URI:http://pki-lab.example/crl/intermediate.crl.pem
#
#  If you need a SAN that is not in [ alt_names ], either edit that section or
#  sign with an ad-hoc extension file:
#      printf 'subjectAltName=DNS:pki-lab.example,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > /tmp/ext.cnf
#      openssl ca -config .../openssl.cnf -extfile /tmp/ext.cnf -in ... -out ...
#
#  ---------------------------------------------------------------------------
#  STEP 7 - Build a real chain file (this is fault 2)
#  ---------------------------------------------------------------------------
#  Order matters and is defined by TLS: leaf first, then each issuer upwards.
#  The root is intentionally NOT included - sending it wastes bytes and proves
#  nothing, because a client that does not already trust it will not start
#  trusting it just because the server offered it.
#
#      cat /etc/pki/lab/server/server-new.crt \
#          /etc/pki/lab/intermediate/certs/intermediate.cert.pem \
#          > /etc/pki/lab/server/fullchain.crt
#      chmod 444 /etc/pki/lab/server/fullchain.crt
#
#  Offline validation before touching the service:
#      openssl verify -CAfile /etc/pki/lab/root/certs/ca.cert.pem \
#          -untrusted /etc/pki/lab/intermediate/certs/intermediate.cert.pem \
#          -verify_hostname pki-lab.example \
#          /etc/pki/lab/server/server-new.crt
#      # -> server-new.crt: OK
#
#  ---------------------------------------------------------------------------
#  STEP 8 - Point nginx at the new key and reload
#  ---------------------------------------------------------------------------
#      # /etc/nginx/conf.d/pkilab.conf
#      #   ssl_certificate     /etc/pki/lab/server/fullchain.crt;
#      #   ssl_certificate_key /etc/pki/lab/private/server-new.key;
#      sed -i 's#private/server.key#private/server-new.key#' /etc/nginx/conf.d/pkilab.conf
#      nginx -t && systemctl restart nginx
#
#  On RHEL/Fedora with SELinux enforcing, if nginx cannot read the material:
#      restorecon -Rv /etc/pki/lab
#      ausearch -m avc -ts recent | audit2why
#
#  ---------------------------------------------------------------------------
#  STEP 9 - Revoke the old leaf properly and refresh the CRL
#  ---------------------------------------------------------------------------
#  It is already revoked in this lab, but this is the operation you must know,
#  and the CRL should be regenerated whenever the database changes:
#
#      openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
#          -revoke /etc/pki/lab/server/server.crt -crl_reason keyCompromise
#      openssl ca -config /etc/pki/lab/intermediate/openssl.cnf \
#          -gencrl -out /etc/pki/lab/crl/intermediate.crl.pem
#      openssl crl -noout -text -in /etc/pki/lab/crl/intermediate.crl.pem \
#          | head -20
#
#  Valid -crl_reason values: unspecified, keyCompromise, CACompromise,
#  affiliationChanged, superseded, cessationOfOperation, certificateHold,
#  removeFromCRL. Only certificateHold is reversible.
#
#  A CRL has a nextUpdate; once it passes, strict validators treat the CRL as
#  missing and -crl_check fails. Regenerating the CRL on a timer (default
#  default_crl_days = 30 here) is an operational duty, not an optional chore.
#
#  ---------------------------------------------------------------------------
#  STEP 10 - Validate the running endpoint the way a client does
#  ---------------------------------------------------------------------------
#      openssl s_client -connect 127.0.0.1:443 -servername pki-lab.example \
#          -showcerts -verify_return_error </dev/null | head -40
#  Expected:
#      depth=2 ... CN = PKI Lab Root CA
#      depth=1 ... CN = PKI Lab Intermediate CA
#      depth=0 ... CN = pki-lab.example
#      Verify return code: 0 (ok)
#
#      curl -v https://pki-lab.example/ -o /dev/null
#      # no -k, no --cacert: it must validate against the system trust store
#
#  Full revocation-aware validation:
#      cat /etc/pki/lab/crl/root.crl.pem /etc/pki/lab/crl/intermediate.crl.pem > /tmp/all.crl
#      openssl verify -crl_check_all \
#          -CAfile /etc/pki/lab/root/certs/ca.cert.pem \
#          -untrusted /etc/pki/lab/intermediate/certs/intermediate.cert.pem \
#          -CRLfile /tmp/all.crl \
#          /etc/pki/lab/server/server-new.crt
#      # -> OK   (with the OLD certificate this prints:
#      #          error 23 at 0 depth lookup: certificate revoked)
#
#  Finally:
#      ./331.1-break-and-fix.sh verify     # 10/10
#
#  ---------------------------------------------------------------------------
#  WHY EACH FAULT LOOKED THE WAY IT DID (exam-level takeaways)
#  ---------------------------------------------------------------------------
#  * key values mismatch  -> a certificate binds a PUBLIC key to a name; the
#    private key is never inside it. Any TLS server verifies the pairing at
#    load time, which is why the failure is at startup, not at handshake.
#
#  * unable to get local issuer certificate (X509_V_ERR = 20) -> the client
#    trusts the root but cannot BUILD the path, because the server did not
#    send the intermediate. Trusting the root is not enough; chain assembly is
#    the server's responsibility. Error 21 (unable to verify the first
#    certificate) is the same disease seen from a different angle, and error 2
#    is the equivalent when the missing link is above a trusted anchor.
#
#  * hostname mismatch -> since RFC 6125 / CA-Browser Forum baseline, identity
#    lives in subjectAltName; commonName is legacy and ignored by modern
#    clients. And because copy_extensions defaults to none, a SAN present in
#    the CSR is silently dropped by 'openssl ca' - the CA profile decides.
#
#  * certificate revoked (X509_V_ERR = 23) -> revocation is a statement about
#    a SERIAL made by the ISSUER, distributed either as a CRL (pull the whole
#    list, crlDistributionPoints) or per-certificate over OCSP
#    (authorityInfoAccess OCSP;URI, plus OCSP stapling on the server side).
#    Re-issuing over the same key pair defeats the purpose of the revocation:
#    keyCompromise means the KEY is burned, not just that certificate.
#
#  ---------------------------------------------------------------------------
#  RELATED COMMANDS WORTH DRILLING FOR 331.1
#  ---------------------------------------------------------------------------
#      openssl x509 -in c.pem -noout -text -certopt no_sigdump,no_pubkey
#      openssl x509 -in c.der -inform DER -out c.pem -outform PEM     # DER <-> PEM
#      openssl x509 -in c.pem -noout -fingerprint -sha256
#      openssl x509 -in c.pem -noout -dates -subject -issuer -serial
#      openssl x509 -in c.pem -noout -checkend 2592000                # expires in 30 d?
#      openssl req  -in r.csr -noout -text -verify
#      openssl crl  -in crl.pem -noout -lastupdate -nextupdate
#      openssl ocsp -issuer int.pem -cert leaf.pem -url http://ocsp.example -text
#      openssl pkcs12 -export -inkey k.pem -in c.pem -certfile chain.pem -out b.p12
#      openssl pkcs8 -topk8 -in k.pem -out k8.pem -v2 aes256          # PKCS#1 -> PKCS#8
#      openssl s_client -connect h:443 -servername h -status          # OCSP stapling
#      openssl verify -CApath /etc/ssl/certs -purpose sslserver c.pem
#      trust list / update-ca-trust extract   (RHEL) | update-ca-certificates (Debian)
#
#  Source: LPI 303-300 exam objectives, topic 331.1
#          https://www.lpi.org/our-certifications/exam-303-objectives/
#  OpenSSL manual pages: x509(1), req(1), ca(1), crl(1), verify(1),
#          pkcs12(1), s_client(1), config(5), x509v3_config(5)
# ==============================================================================