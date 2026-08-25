#!/usr/bin/env bash
#
# lab-331.2-break-and-fix.sh
#
# LPIC-3 Security — exam 303-300, version 3.0.0
# Topic 331.2 — X.509 Certificates for Encryption, Signing and Authentication (weight 6.67)
#
# WHAT THIS IS
#   A self-contained break & fix lab. It builds a real two-tier PKI with OpenSSL
#   (offline root CA -> issuing intermediate CA -> server leaf + client leaf),
#   deploys it on nginx over TLS and mutual TLS, proves the baseline works, and
#   then injects ONE controlled, reversible fault. You get the symptom and the
#   definition of done; you do not get the cause. The full step-by-step solution
#   is at the bottom of this file, commented out.
#
# WHERE IT IS SAFE TO RUN
#   A disposable lab VM ONLY. Outside of $LAB_ROOT this script touches exactly
#   three things, all backed up first:
#       /etc/nginx/conf.d/lab-331-2.conf   (created by us, removed by 'destroy')
#       /etc/hosts                         (three 127.0.0.1 aliases appended)
#       the nginx service                  (restarted/reloaded)
#   It refuses to run unless you assert the host is disposable.
#
# REFERENCES (official)
#   LPI 303-300 objectives .... https://www.lpi.org/our-certifications/exam-303-objectives/
#   openssl-ca(1) ............. https://docs.openssl.org/master/man1/openssl-ca/
#   openssl-req(1) ............ https://docs.openssl.org/master/man1/openssl-req/
#   openssl-x509(1) ........... https://docs.openssl.org/master/man1/openssl-x509/
#   openssl-verify(1) ......... https://docs.openssl.org/master/man1/openssl-verify/
#   openssl-s_client(1) ....... https://docs.openssl.org/master/man1/openssl-s_client/
#   x509v3_config(5) .......... https://docs.openssl.org/master/man5/x509v3_config/
#   config(5) (openssl.cnf) ... https://docs.openssl.org/master/man5/config/
#   nginx ngx_http_ssl_module . https://nginx.org/en/docs/http/ngx_http_ssl_module.html
#   RFC 5280 (PKIX) ........... https://www.rfc-editor.org/rfc/rfc5280
#   RFC 6125 (name checking) .. https://www.rfc-editor.org/rfc/rfc6125
#   CA/B Forum Baseline Reqs .. https://cabforum.org/working-groups/server/baseline-requirements/documents/
#
set -Eeuo pipefail

readonly LAB_ID="331.2"
readonly LAB_ROOT="/opt/lab-331.2"
readonly PKI="${LAB_ROOT}/pki"
readonly ROOTCA="${PKI}/root"
readonly INTCA="${PKI}/intermediate"
readonly DEPLOY="${LAB_ROOT}/deploy"
readonly CLIENTDIR="${LAB_ROOT}/client"
readonly WWW="${LAB_ROOT}/www"
readonly STATEDIR="${LAB_ROOT}/state"
readonly BACKUP="${LAB_ROOT}/backup"
readonly LOG="${LAB_ROOT}/lab.log"
readonly NGX_CONF="/etc/nginx/conf.d/lab-331-2.conf"
readonly HOST_TLS="lab331.example.internal"
readonly HOST_MTLS="mtls331.example.internal"
readonly HOST_BAD="wrong331.example.internal"
readonly PORT="8443"
readonly MARKER="LAB-331.2-CONTENT-OK"
readonly FAULT_MIN=1
readonly FAULT_MAX=7

# $ENV::LAB_SAN is dereferenced at config-parse time by OpenSSL, so it must
# always be set, even for issuances that do not use the server_cert section.
export LAB_SAN="DNS:${HOST_TLS}"

if [[ -t 1 ]]; then
    C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
    C_B=$'\033[1;34m'; C_C=$'\033[1;36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_D=""; C_0=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
hdr()  { printf '\n%s== %s %s\n' "$C_C" "$*" "$C_0"; }
rule() { printf '%s%s%s\n' "$C_D" "------------------------------------------------------------------------" "$C_0"; }

on_err() {
    local rc=$? line=${BASH_LINENO[0]:-?}
    err "aborted at line ${line} (exit ${rc})"
    [[ -f "$LOG" ]] && { err "last 20 lines of ${LOG}:"; tail -n 20 "$LOG" >&2 || true; }
    exit "$rc"
}
trap on_err ERR

# --------------------------------------------------------------------------
# Guards
# --------------------------------------------------------------------------

FORCE_LAB=0

require_root() {
    [[ ${EUID} -eq 0 ]] || die "run as root (this configures nginx and writes under ${LAB_ROOT})"
}

require_disposable_vm() {
    if [[ -e /etc/teach-plat-lab ]] || [[ "${LAB_DISPOSABLE:-}" == "yes" ]] || [[ ${FORCE_LAB} -eq 1 ]]; then
        return 0
    fi
    cat <<EOF
${C_R}REFUSING TO RUN.${C_0}

This lab installs nginx if missing, writes ${NGX_CONF},
appends aliases to /etc/hosts and restarts nginx. Run it on a THROWAWAY VM,
never on a host you care about.

Assert that this host is disposable with any one of:

    touch /etc/teach-plat-lab
    LAB_DISPOSABLE=yes $0 <command>
    $0 --i-am-in-a-disposable-vm <command>
EOF
    exit 2
}

require_tools() {
    local missing=()
    for t in openssl curl awk sed grep date systemctl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
    local v; v="$(openssl version | awk '{print $2}')"
    case "$v" in
        3.*|1.1.1*) : ;;
        *) warn "OpenSSL ${v} is older than 1.1.1; -addext and -CRLfile may be unavailable" ;;
    esac
}

ensure_nginx() {
    command -v nginx >/dev/null 2>&1 && return 0
    info "nginx not present, installing"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >>"$LOG" 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q nginx >>"$LOG" 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install nginx >>"$LOG" 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm nginx >>"$LOG" 2>&1
    else
        die "no supported package manager found; install nginx manually and re-run"
    fi
    command -v nginx >/dev/null 2>&1 || die "nginx installation failed, see ${LOG}"
    ok "nginx installed"
}

# nginx runs as httpd_t; material under /opt is default_t and would be denied.
selinux_fixup() {
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null || echo Disabled)" == "Enforcing" ]] || return 0
    command -v chcon >/dev/null 2>&1 || return 0
    chcon -R -t cert_t "$DEPLOY" 2>>"$LOG" || true
    chcon -R -t httpd_sys_content_t "$WWW" 2>>"$LOG" || true
    command -v setsebool >/dev/null 2>&1 && setsebool -P httpd_read_user_content on 2>>"$LOG" || true
}

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

state_set()  { printf '%s\n' "$2" > "${STATEDIR}/$1"; }
state_get()  { [[ -f "${STATEDIR}/$1" ]] && cat "${STATEDIR}/$1" || printf '%s' "${2:-}"; }
state_clear(){ rm -f "${STATEDIR}/$1"; }

# --------------------------------------------------------------------------
# PKI construction
# --------------------------------------------------------------------------

write_ca_conf() {
    # write_ca_conf <ca_dir> <human_name> <default_days>
    local dir="$1" name="$2" days="$3"
    cat > "${dir}/openssl.cnf" <<CFG
# OpenSSL CA configuration for the ${name} — lab ${LAB_ID}
# Reference: https://docs.openssl.org/master/man5/config/

[ ca ]
default_ca              = CA_default

[ CA_default ]
dir                     = ${dir}
certs                   = \$dir/certs
crl_dir                 = \$dir/crl
new_certs_dir           = \$dir/newcerts
database                = \$dir/index.txt
serial                  = \$dir/serial
crlnumber               = \$dir/crlnumber
private_key             = \$dir/private/ca.key
certificate             = \$dir/ca.crt
crl                     = \$dir/crl/ca.crl
default_md              = sha256
default_days            = ${days}
default_crl_days        = 30
preserve                = no
email_in_dn             = no
name_opt                = ca_default
cert_opt                = ca_default
copy_extensions         = none
unique_subject          = no
policy                  = policy_loose

# 'supplied' = must be present; 'optional' = may be absent; 'match' = must equal
# the corresponding field of the CA certificate.
[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits            = 2048
distinguished_name      = req_distinguished_name
string_mask             = utf8only
default_md              = sha256
prompt                  = no

[ req_distinguished_name ]
C                       = AR
O                       = Teach-Plat Lab ${LAB_ID}
CN                      = placeholder

# --- issuance profiles (X.509v3 extensions, see x509v3_config(5)) ----------

[ v3_intermediate_ca ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
basicConstraints        = critical, CA:true, pathlen:0
keyUsage                = critical, digitalSignature, cRLSign, keyCertSign

[ server_cert ]
basicConstraints        = critical, CA:FALSE
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
keyUsage                = critical, digitalSignature, keyEncipherment
extendedKeyUsage        = serverAuth
subjectAltName          = \$ENV::LAB_SAN
crlDistributionPoints   = URI:http://crl.${HOST_TLS}/intermediate.crl

[ client_cert ]
basicConstraints        = critical, CA:FALSE
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
keyUsage                = critical, digitalSignature, keyEncipherment
extendedKeyUsage        = clientAuth
crlDistributionPoints   = URI:http://crl.${HOST_TLS}/intermediate.crl
CFG
}

init_ca_dir() {
    local dir="$1"
    mkdir -p "${dir}"/{certs,crl,newcerts,csr,private}
    chmod 700 "${dir}/private"
    : > "${dir}/index.txt"
    # openssl ca(1) defaults index.txt.attr to unique_subject=yes, which blocks
    # re-issuing a certificate for the same DN — exactly what a renewal is.
    printf 'unique_subject = no\n' > "${dir}/index.txt.attr"
    printf '1000\n' > "${dir}/serial"
    printf '1000\n' > "${dir}/crlnumber"
}

ca_sign() {
    # ca_sign <ca_dir> <csr> <out_crt> <ext_section> [extra openssl ca args...]
    local cadir="$1" csr="$2" out="$3" ext="$4"; shift 4
    openssl ca -batch -config "${cadir}/openssl.cnf" \
        -extensions "$ext" -notext -md sha256 \
        -in "$csr" -out "$out" "$@" >>"$LOG" 2>&1
}

gen_crl() {
    openssl ca -batch -config "${INTCA}/openssl.cnf" \
        -gencrl -out "${INTCA}/crl/intermediate.crl" >>"$LOG" 2>&1
    install -m 0644 "${INTCA}/crl/intermediate.crl" "${DEPLOY}/intermediate.crl"
}

build_pki() {
    hdr "Building the two-tier PKI"

    init_ca_dir "$ROOTCA"
    write_ca_conf "$ROOTCA" "Lab ${LAB_ID} Root CA" 3650

    info "root CA: 4096-bit RSA, self-signed, 10 years, pathlen:1"
    openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
        -keyout "${ROOTCA}/private/ca.key" -out "${ROOTCA}/ca.crt" \
        -subj "/C=AR/O=Teach-Plat Lab ${LAB_ID}/CN=Lab ${LAB_ID} Root CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" >>"$LOG" 2>&1
    chmod 400 "${ROOTCA}/private/ca.key"

    init_ca_dir "$INTCA"
    write_ca_conf "$INTCA" "Lab ${LAB_ID} Issuing CA" 825

    info "intermediate CA: 3072-bit RSA, signed by the root, pathlen:0"
    openssl req -new -nodes -newkey rsa:3072 -sha256 \
        -keyout "${INTCA}/private/ca.key" -out "${INTCA}/csr/ca.csr" \
        -subj "/C=AR/O=Teach-Plat Lab ${LAB_ID}/CN=Lab ${LAB_ID} Issuing CA" >>"$LOG" 2>&1
    chmod 400 "${INTCA}/private/ca.key"
    ca_sign "$ROOTCA" "${INTCA}/csr/ca.csr" "${INTCA}/ca.crt" v3_intermediate_ca -days 1825

    # The trust anchor bundle a relying party needs: root + intermediate.
    cat "${INTCA}/ca.crt" "${ROOTCA}/ca.crt" > "${DEPLOY}/ca-chain.pem"
    install -m 0644 "${ROOTCA}/ca.crt" "${DEPLOY}/root-ca.pem"
    install -m 0644 "${INTCA}/ca.crt"  "${DEPLOY}/intermediate-ca.pem"

    openssl verify -CAfile "${ROOTCA}/ca.crt" "${INTCA}/ca.crt" >>"$LOG" 2>&1 \
        || die "intermediate does not verify against the root, see ${LOG}"
    ok "root -> intermediate chain verifies"

    gen_crl
    ok "empty CRL generated (${DEPLOY}/intermediate.crl)"
}

issue_server_cert() {
    # issue_server_cert [san] [extra openssl ca args...]
    local san="${1:-DNS:${HOST_TLS},DNS:${HOST_MTLS},IP:127.0.0.1}"; shift || true
    export LAB_SAN="$san"
    openssl req -new -nodes -newkey rsa:2048 -sha256 \
        -keyout "${PKI}/server.key" -out "${INTCA}/csr/server.csr" \
        -subj "/C=AR/O=Teach-Plat Lab ${LAB_ID}/CN=${HOST_TLS}" >>"$LOG" 2>&1
    chmod 400 "${PKI}/server.key"
    ca_sign "$INTCA" "${INTCA}/csr/server.csr" "${PKI}/server.crt" server_cert "$@"
    export LAB_SAN="DNS:${HOST_TLS}"
}

issue_client_cert() {
    local cn="${1:-student}"
    mkdir -p "$CLIENTDIR"
    openssl req -new -nodes -newkey rsa:2048 -sha256 \
        -keyout "${CLIENTDIR}/client.key" -out "${INTCA}/csr/client.csr" \
        -subj "/C=AR/O=Teach-Plat Lab ${LAB_ID}/OU=Students/CN=${cn}" >>"$LOG" 2>&1
    chmod 400 "${CLIENTDIR}/client.key"
    ca_sign "$INTCA" "${INTCA}/csr/client.csr" "${CLIENTDIR}/client.crt" client_cert -days 365
}

deploy_server_material() {
    # What nginx serves: leaf FIRST, then intermediate. The root is never sent.
    cat "${PKI}/server.crt" "${INTCA}/ca.crt" > "${DEPLOY}/server-fullchain.pem"
    install -m 0640 "${PKI}/server.key" "${DEPLOY}/server.key"
    chmod 0644 "${DEPLOY}/server-fullchain.pem"
    selinux_fixup
}

# --------------------------------------------------------------------------
# Service
# --------------------------------------------------------------------------

write_nginx_conf() {
    # write_nginx_conf [client_ca_file] [verify_depth] [password_file_directive]
    local client_ca="${1:-${DEPLOY}/ca-chain.pem}"
    local depth="${2:-2}"
    local pwline="${3:-}"
    cat > "$NGX_CONF" <<NGX
# lab ${LAB_ID} — generated by lab-331.2-break-and-fix.sh, safe to delete
# https://nginx.org/en/docs/http/ngx_http_ssl_module.html

server {
    listen ${PORT} ssl;
    listen [::]:${PORT} ssl;
    server_name ${HOST_TLS};

    ssl_certificate     ${DEPLOY}/server-fullchain.pem;
    ssl_certificate_key ${DEPLOY}/server.key;
${pwline}
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:LAB331:1m;

    root ${WWW};
    index index.html;

    location = /health { default_type text/plain; return 200 "${MARKER}\n"; }
}

server {
    listen ${PORT} ssl;
    listen [::]:${PORT} ssl;
    server_name ${HOST_MTLS};

    ssl_certificate     ${DEPLOY}/server-fullchain.pem;
    ssl_certificate_key ${DEPLOY}/server.key;
${pwline}
    ssl_protocols       TLSv1.2 TLSv1.3;

    # Mutual TLS: the client must present a certificate this CA store can chain.
    ssl_verify_client       on;
    ssl_client_certificate  ${client_ca};
    ssl_verify_depth        ${depth};
    ssl_crl                 ${DEPLOY}/intermediate.crl;

    root ${WWW};
    index index.html;

    location = /whoami {
        default_type text/plain;
        return 200 "${MARKER} verify=\$ssl_client_verify dn=\$ssl_client_s_dn\n";
    }
}
NGX
    state_set client_ca "$client_ca"
    state_set verify_depth "$depth"
}

nginx_test() { nginx -t </dev/null >>"$LOG" 2>&1; }

nginx_apply() {
    if ! nginx_test; then
        return 1
    fi
    systemctl reload nginx >>"$LOG" 2>&1 || systemctl restart nginx >>"$LOG" 2>&1
}

nginx_restart_allow_fail() {
    systemctl restart nginx >>"$LOG" 2>&1 || true
}

write_hosts() {
    [[ -f "${BACKUP}/hosts.orig" ]] || cp -a /etc/hosts "${BACKUP}/hosts.orig"
    if ! grep -q "lab-${LAB_ID}" /etc/hosts; then
        printf '127.0.0.1 %s %s %s # lab-%s\n' \
            "$HOST_TLS" "$HOST_MTLS" "$HOST_BAD" "$LAB_ID" >> /etc/hosts
    fi
}

write_content() {
    mkdir -p "$WWW"
    cat > "${WWW}/index.html" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>LPIC-3 303 — lab ${LAB_ID}</title></head>
<body><h1>${MARKER}</h1>
<p>X.509 Certificates for Encryption, Signing and Authentication.</p></body></html>
HTML
}

# --------------------------------------------------------------------------
# Probes — every check is a command the student can run by hand
# --------------------------------------------------------------------------

CURL_TLS=(curl -sS --max-time 8 --cacert "${DEPLOY}/ca-chain.pem")

probe_https() {
    "${CURL_TLS[@]}" --resolve "${HOST_TLS}:${PORT}:127.0.0.1" \
        "https://${HOST_TLS}:${PORT}/health" 2>&1
}

probe_mtls() {
    "${CURL_TLS[@]}" --resolve "${HOST_MTLS}:${PORT}:127.0.0.1" \
        --cert "${CLIENTDIR}/client.crt" --key "${CLIENTDIR}/client.key" \
        "https://${HOST_MTLS}:${PORT}/whoami" 2>&1
}

probe_mtls_anonymous() {
    "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' \
        --resolve "${HOST_MTLS}:${PORT}:127.0.0.1" \
        "https://${HOST_MTLS}:${PORT}/whoami" 2>&1
}

probe_sclient() {
    openssl s_client -connect "127.0.0.1:${PORT}" -servername "${HOST_TLS}" \
        -CAfile "${DEPLOY}/ca-chain.pem" -showcerts -brief </dev/null 2>&1
}

pubkey_fp() {
    # Same public key in cert and key => same SPKI digest. Modulus comparison is
    # the classic RSA-only idiom; this one works for EC and Ed25519 too.
    case "$1" in
        cert) openssl x509 -in "$2" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}' ;;
        key)  openssl pkey -in "$2" -pubout 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}' ;;
    esac
}

CHECKS_PASS=0
CHECKS_FAIL=0
check() {
    # check <label> <command...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  %s PASS %s %s\n' "$C_G" "$C_0" "$label"; CHECKS_PASS=$((CHECKS_PASS+1))
    else
        printf '  %s FAIL %s %s\n' "$C_R" "$C_0" "$label"; CHECKS_FAIL=$((CHECKS_FAIL+1))
    fi
}

_chain_complete() { probe_sclient | grep -qE 'Verification: OK'; }
_chain_two_certs(){ [[ $(probe_sclient | grep -c 'BEGIN CERTIFICATE') -ge 2 ]]; }
_https_ok()       { probe_https | grep -q "$MARKER"; }
_mtls_ok()        { probe_mtls  | grep -q 'verify=SUCCESS'; }
_mtls_closed()    { [[ "$(probe_mtls_anonymous)" != "200" ]]; }
_pair_matches()   { [[ "$(pubkey_fp cert "${DEPLOY}/server-fullchain.pem")" == "$(pubkey_fp key "${DEPLOY}/server.key")" ]]; }
_not_expired()    { openssl x509 -in "${DEPLOY}/server-fullchain.pem" -noout -checkend 86400; }
_san_correct()    { openssl x509 -in "${DEPLOY}/server-fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${HOST_TLS}"; }
_key_unencrypted(){ ! grep -q 'ENCRYPTED' "${DEPLOY}/server.key"; }
_client_not_revoked() {
    openssl verify -crl_check -CAfile "${DEPLOY}/ca-chain.pem" \
        -CRLfile "${DEPLOY}/intermediate.crl" "${CLIENTDIR}/client.crt"
}
_nginx_up()       { systemctl is-active --quiet nginx; }

run_checks() {
    CHECKS_PASS=0; CHECKS_FAIL=0
    hdr "Verification"
    check "nginx is active"                                   _nginx_up
    check "nginx configuration parses"                        nginx_test
    check "server key matches the deployed certificate"       _pair_matches
    check "server key is usable without a passphrase prompt"  _key_unencrypted
    check "leaf certificate is valid for at least 24h more"   _not_expired
    check "leaf SAN contains DNS:${HOST_TLS}"                 _san_correct
    check "server sends leaf + intermediate (chain complete)" _chain_two_certs
    check "s_client reports Verification: OK"                 _chain_complete
    check "HTTPS GET /health returns the lab marker"          _https_ok
    check "client certificate is not revoked by the CRL"      _client_not_revoked
    check "mTLS with the client certificate returns SUCCESS"  _mtls_ok
    check "mTLS without a certificate is rejected"            _mtls_closed
    rule
    if ((CHECKS_FAIL == 0)); then
        printf '%s ALL %d CHECKS PASSED — the lab is healthy. %s\n' "$C_G" "$CHECKS_PASS" "$C_0"
        return 0
    fi
    printf '%s %d passed, %d FAILED — not fixed yet. %s\n' "$C_Y" "$CHECKS_PASS" "$CHECKS_FAIL" "$C_0"
    return 1
}

# --------------------------------------------------------------------------
# Backup / restore of the deployed material
# --------------------------------------------------------------------------

snapshot() {
    rm -rf "${BACKUP}/deploy" "${BACKUP}/client" "${BACKUP}/pki-leaf" "${BACKUP}/nginx"
    mkdir -p "${BACKUP}/pki-leaf" "${BACKUP}/nginx"
    cp -a "$DEPLOY" "${BACKUP}/deploy"
    cp -a "$CLIENTDIR" "${BACKUP}/client"
    cp -a "${PKI}/server.crt" "${PKI}/server.key" "${BACKUP}/pki-leaf/"
    cp -a "$NGX_CONF" "${BACKUP}/nginx/lab.conf"
    cp -a "${INTCA}/index.txt" "${BACKUP}/index.txt"
    cp -a "${INTCA}/crl/intermediate.crl" "${BACKUP}/intermediate.crl"
}

rollback() {
    [[ -d "${BACKUP}/deploy" ]] || die "no snapshot found — run '$0 setup' first"
    rm -rf "$DEPLOY" "$CLIENTDIR"
    cp -a "${BACKUP}/deploy" "$DEPLOY"
    cp -a "${BACKUP}/client" "$CLIENTDIR"
    cp -a "${BACKUP}/pki-leaf/server.crt" "${PKI}/server.crt"
    cp -a "${BACKUP}/pki-leaf/server.key" "${PKI}/server.key"
    cp -a "${BACKUP}/index.txt" "${INTCA}/index.txt"
    cp -a "${BACKUP}/intermediate.crl" "${INTCA}/crl/intermediate.crl"
    cp -a "${BACKUP}/intermediate.crl" "${DEPLOY}/intermediate.crl"
    cp -a "${BACKUP}/nginx/lab.conf" "$NGX_CONF"
    selinux_fixup
    nginx_apply || nginx_restart_allow_fail
}

# --------------------------------------------------------------------------
# Faults
# --------------------------------------------------------------------------

brief() {
    # brief <title> <symptom> <evidence> <objective> <toolbox>
    rule
    printf '%s BROKEN: %s %s\n' "$C_R" "$1" "$C_0"
    rule
    printf '\n%sSYMPTOM YOU WILL SEE%s\n%s\n' "$C_Y" "$C_0" "$2"
    printf '\n%sREPRODUCE IT%s\n%s\n' "$C_Y" "$C_0" "$3"
    printf '\n%sYOUR OBJECTIVE (definition of done)%s\n%s\n' "$C_Y" "$C_0" "$4"
    printf '\n%sTOOLBOX%s\n%s\n' "$C_Y" "$C_0" "$5"
    cat <<EOF

${C_C}Everything you need is on this box${C_0}
  Root CA key/cert ......... ${ROOTCA}/private/ca.key , ${ROOTCA}/ca.crt
  Issuing CA key/cert ...... ${INTCA}/private/ca.key , ${INTCA}/ca.crt
  Issuing CA config ........ ${INTCA}/openssl.cnf   (profiles: server_cert, client_cert)
  CA database / CRL ........ ${INTCA}/index.txt , ${INTCA}/crl/intermediate.crl
  Deployed to nginx ........ ${DEPLOY}/
  Client identity .......... ${CLIENTDIR}/
  nginx vhost .............. ${NGX_CONF}
  Lab log .................. ${LOG}

When you think it is fixed:   $0 verify
Stuck?                        $0 hint      (three escalating hints)
Give up / reset the lab:      $0 reset
EOF
    rule
}

fault_1_break() {
    # Deploy the leaf only: the intermediate is no longer sent in the handshake.
    cp "${PKI}/server.crt" "${DEPLOY}/server-fullchain.pem"
    chmod 0644 "${DEPLOY}/server-fullchain.pem"
    selinux_fixup
    nginx_apply || true
    brief "TLS chain of trust" \
"curl aborts before any HTTP response:
    curl: (60) SSL certificate problem: unable to get local issuer certificate
and openssl s_client reports
    Verify return code: 20 (unable to get local issuer certificate)
even though you are passing the correct CA file. Browsers on other hosts fail
too — this is the classic 'works in my browser, fails in curl/java/python' bug." \
"    curl -v --cacert ${DEPLOY}/ca-chain.pem \\
        --resolve ${HOST_TLS}:${PORT}:127.0.0.1 https://${HOST_TLS}:${PORT}/health
    openssl s_client -connect 127.0.0.1:${PORT} -servername ${HOST_TLS} \\
        -CAfile ${DEPLOY}/ca-chain.pem -showcerts </dev/null" \
"'$0 verify' passes, and 'openssl s_client ... -showcerts' shows MORE THAN ONE
certificate coming from the server, ending with 'Verify return code: 0 (ok)'.
Do not add anything to the system trust store and do not use --insecure: the
relying party's trust anchor must stay exactly ${DEPLOY}/ca-chain.pem." \
"    openssl s_client -showcerts        # what the server actually sends
    openssl x509 -noout -subject -issuer -in <file>
    openssl verify -CAfile <root> -untrusted <intermediate> <leaf>
    RFC 5280 §6 path construction; nginx ssl_certificate expects a concatenation"
}

fault_2_break() {
    # Replace the private key with a brand new, unrelated one.
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "${DEPLOY}/server.key" >>"$LOG" 2>&1
    chmod 0640 "${DEPLOY}/server.key"
    selinux_fixup
    nginx_restart_allow_fail
    brief "server key / certificate pairing" \
"nginx refuses to start at all and the TCP port is closed:
    nginx: [emerg] SSL_CTX_use_PrivateKey_file(\"${DEPLOY}/server.key\") failed
    (SSL: error:05800074:x509 certificate routines::key values mismatch)
Every client gets 'Connection refused' — this looks like a network problem and
is not one." \
"    systemctl status nginx --no-pager
    journalctl -u nginx -n 30 --no-pager
    nginx -t </dev/null
    ss -lntp | grep ${PORT}" \
"nginx starts, the port listens, and the deployed key provably belongs to the
deployed certificate: the SHA-256 of 'openssl x509 -pubkey' must equal the
SHA-256 of 'openssl pkey -pubout'. Then '$0 verify' passes." \
"    openssl x509 -in cert.pem -noout -pubkey | openssl sha256
    openssl pkey  -in key.pem  -pubout       | openssl sha256
    openssl rsa -in key.pem -noout -modulus | openssl md5     # RSA-only idiom
    openssl req -in csr.pem -noout -modulus | openssl md5     # match the CSR too
Either restore the matching key, or build a CSR from the key you have and issue
a new certificate with 'openssl ca -config ${INTCA}/openssl.cnf'."
}

fault_3_break() {
    local sd ed
    sd="$(date -u -d '400 days ago' +%Y%m%d%H%M%SZ)"
    ed="$(date -u -d '35 days ago'  +%Y%m%d%H%M%SZ)"
    issue_server_cert "DNS:${HOST_TLS},DNS:${HOST_MTLS},IP:127.0.0.1" \
        -startdate "$sd" -enddate "$ed"
    deploy_server_material
    nginx_apply || true
    brief "certificate validity window" \
"The handshake completes but the peer rejects the identity:
    curl: (60) SSL certificate problem: certificate has expired
    Verify return code: 10 (certificate has expired)
Monitoring shows the service 'up' (nginx is running, the port answers) while
100% of real clients fail. Note that nginx itself never complains." \
"    curl -v --cacert ${DEPLOY}/ca-chain.pem \\
        --resolve ${HOST_TLS}:${PORT}:127.0.0.1 https://${HOST_TLS}:${PORT}/health
    openssl x509 -in ${DEPLOY}/server-fullchain.pem -noout -dates
    openssl x509 -in ${DEPLOY}/server-fullchain.pem -noout -checkend 0 ; echo \$?" \
"The deployed leaf has notBefore in the past and notAfter comfortably in the
future ('openssl x509 -checkend 2592000' returns 0), the SAN and the chain are
unchanged, nginx has re-read the material, and '$0 verify' passes.
Reuse the existing key or generate a new one — but the CN/SAN must not change." \
"    openssl x509 -noout -dates -serial -in <cert>
    openssl req -new -key <key> -out <csr> -subj '/CN=...'
    openssl ca -config ${INTCA}/openssl.cnf -extensions server_cert -days 397 -in <csr> -out <crt>
    cat ${INTCA}/index.txt          # V/E/R status, expiry, serial, DN
    systemctl reload nginx          # a reload is what re-reads the PEM files"
}

fault_4_break() {
    issue_server_cert "DNS:${HOST_BAD}" -days 397
    deploy_server_material
    nginx_apply || true
    brief "subjectAltName / hostname verification" \
"The chain is trusted and the dates are fine, yet clients still refuse:
    curl: (60) SSL: no alternative certificate subject name matches
          target host name '${HOST_TLS}'
Python requests raises CertificateError, Java throws
SSLPeerUnverifiedException. 'openssl verify' on the file says 'OK', which is
the trap: openssl verify does NOT check names." \
"    curl -v --cacert ${DEPLOY}/ca-chain.pem \\
        --resolve ${HOST_TLS}:${PORT}:127.0.0.1 https://${HOST_TLS}:${PORT}/health
    openssl x509 -in ${DEPLOY}/server-fullchain.pem -noout -subject -ext subjectAltName
    openssl s_client -connect 127.0.0.1:${PORT} -servername ${HOST_TLS} \\
        -verify_hostname ${HOST_TLS} -CAfile ${DEPLOY}/ca-chain.pem </dev/null" \
"The deployed leaf carries a subjectAltName extension listing BOTH
DNS:${HOST_TLS} and DNS:${HOST_MTLS} (IP:127.0.0.1 is welcome), it still chains
to the same CA, and '$0 verify' passes. Putting the name only in the CN is not
a fix: since RFC 6125 / the CA-Browser Forum Baseline Requirements, clients
ignore CN entirely when a SAN is present, and modern clients ignore it always." \
"    openssl x509 -noout -text -in <cert> | sed -n '/X509v3 extensions/,/Signature/p'
    openssl req -new -key <key> -subj '/CN=${HOST_TLS}' \\
        -addext 'subjectAltName=DNS:${HOST_TLS},DNS:${HOST_MTLS},IP:127.0.0.1' -out <csr>
    # the issuing profile reads the SAN from \$ENV::LAB_SAN — see [ server_cert ]
    LAB_SAN='DNS:a,DNS:b' openssl ca -config ${INTCA}/openssl.cnf -extensions server_cert ...
    openssl s_client -verify_hostname <name>    # the only openssl name check"
}

fault_5_break() {
    openssl ca -batch -config "${INTCA}/openssl.cnf" \
        -revoke "${CLIENTDIR}/client.crt" -crl_reason keyCompromise >>"$LOG" 2>&1
    gen_crl
    nginx_apply || true
    brief "certificate revocation (CRL) on the mTLS endpoint" \
"Anonymous HTTPS still works, but the authenticated endpoint rejects the very
client certificate that worked five minutes ago:
    curl: (56) OpenSSL SSL_read: ... alert certificate revoked
    HTTP/1.1 400 Bad Request — 'The SSL certificate error'
and nginx's error log records
    client SSL certificate verify error: (23:certificate revoked)
The certificate file itself is intact, in date, and chains correctly." \
"    curl -v --cacert ${DEPLOY}/ca-chain.pem \\
        --resolve ${HOST_MTLS}:${PORT}:127.0.0.1 \\
        --cert ${CLIENTDIR}/client.crt --key ${CLIENTDIR}/client.key \\
        https://${HOST_MTLS}:${PORT}/whoami
    tail -n 20 /var/log/nginx/error.log
    openssl crl -in ${DEPLOY}/intermediate.crl -noout -text
    openssl verify -crl_check -CAfile ${DEPLOY}/ca-chain.pem \\
        -CRLfile ${DEPLOY}/intermediate.crl ${CLIENTDIR}/client.crt" \
"${CLIENTDIR}/client.crt + client.key authenticate again with
verify=SUCCESS, WITHOUT weakening the server: ssl_verify_client must stay 'on'
and the ssl_crl directive must stay in place and keep pointing at a current
CRL. Revocation is irreversible by design — think about what a real PKI
operator does for a user whose key was compromised. '$0 verify' must pass,
including the 'client certificate is not revoked' check." \
"    openssl ca -config ${INTCA}/openssl.cnf -revoke <crt> -crl_reason keyCompromise
    openssl ca -config ${INTCA}/openssl.cnf -gencrl -out <crl>
    openssl crl -in <crl> -noout -lastupdate -nextupdate -text
    grep '^R' ${INTCA}/index.txt        # revoked entries, by serial
    openssl x509 -in <crt> -noout -serial
    systemctl reload nginx              # nginx caches the CRL at load time"
}

fault_6_break() {
    openssl pkey -in "${PKI}/server.key" -aes-256-cbc \
        -passout pass:"L4bP4ssphr4se" -out "${DEPLOY}/server.key" >>"$LOG" 2>&1
    chmod 0640 "${DEPLOY}/server.key"
    selinux_fixup
    nginx_restart_allow_fail
    brief "encrypted private key with no passphrase source" \
"nginx will not come up; the unit hangs or fails immediately and journald shows
    nginx: [emerg] PEM_read_bio_PrivateKey(\"${DEPLOY}/server.key\") failed
    (SSL: error:0700006C:...:bad decrypt / error:0480006C:PEM routines::no start line)
Run 'nginx -t' from a terminal and it asks 'Enter PEM pass phrase:' instead.
This is the number-one failure of a first unattended reboot after someone
regenerated a key by hand." \
"    systemctl status nginx --no-pager ; journalctl -u nginx -n 30 --no-pager
    nginx -t </dev/null
    head -3 ${DEPLOY}/server.key
    openssl pkey -in ${DEPLOY}/server.key -noout ; echo \$?" \
"nginx starts unattended — 'systemctl restart nginx' must succeed with no
terminal and no prompt — the key still matches the deployed certificate, and
'$0 verify' passes. The passphrase in play is: L4bP4ssphr4se
There are two legitimate outcomes; choose one and be able to argue the
trade-off between them in an exam answer:
  (a) store the key unencrypted, protected by file permissions and ownership;
  (b) keep it encrypted and give nginx a passphrase source (ssl_password_file),
      which only moves the secret, so the file mode matters just as much." \
"    openssl pkey -in enc.key -out plain.key                 # decrypt (asks)
    openssl pkey -in enc.key -passin pass:XXX -out plain.key # decrypt (batch)
    openssl rsa  -in enc.key -aes256 -out enc2.key           # re-encrypt
    ssl_password_file /path/file;   # nginx, one passphrase per line, chmod 600
    https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_password_file"
}

fault_7_break() {
    write_nginx_conf "${DEPLOY}/root-ca.pem" 1
    nginx_apply || true
    brief "mTLS client trust store and verification depth" \
"Server TLS is perfect. Client authentication is not:
    HTTP/1.1 400 Bad Request — 'The SSL certificate error'
    client SSL certificate verify error: (20:unable to get local issuer
    certificate)  — or (21:unable to verify the first certificate)
The client certificate is valid, in date, not revoked, and
'openssl verify -CAfile ${DEPLOY}/ca-chain.pem ${CLIENTDIR}/client.crt'
succeeds from the shell. The rejection happens only over the wire." \
"    curl -v --cacert ${DEPLOY}/ca-chain.pem \\
        --resolve ${HOST_MTLS}:${PORT}:127.0.0.1 \\
        --cert ${CLIENTDIR}/client.crt --key ${CLIENTDIR}/client.key \\
        https://${HOST_MTLS}:${PORT}/whoami
    tail -n 20 /var/log/nginx/error.log
    grep -nE 'ssl_client_certificate|ssl_verify_depth|ssl_verify_client' ${NGX_CONF}
    openssl s_client -connect 127.0.0.1:${PORT} -servername ${HOST_MTLS} </dev/null \\
        | sed -n '/Acceptable client certificate CA names/,/^---/p'" \
"The unchanged ${CLIENTDIR}/client.crt authenticates and /whoami returns
verify=SUCCESS, while an anonymous request is still refused. Do NOT set
ssl_verify_client to optional/off and do not re-issue the client certificate
from the root — fix the server's trust configuration so the path
leaf -> issuing CA -> root CA can be built and is allowed to be that long.
'$0 verify' must pass, both the mTLS check and the 'mTLS without a certificate
is rejected' check." \
"    ssl_client_certificate <file>;   # trust store AND the CA-names hint sent
    ssl_verify_depth <n>;            # max intermediates between leaf and anchor
    openssl verify -verbose -CAfile <anchors> -untrusted <inter> <leaf>
    openssl x509 -noout -issuer -subject -in <leaf>
    nginx -t </dev/null && systemctl reload nginx"
}

hint_for() {
    case "$1" in
      1) cat <<'H'
1. Ask what the server actually puts on the wire, not what is on disk.
   Count the certificates in `openssl s_client -showcerts` output.
2. nginx has no directive for an intermediate. Read the note under
   `ssl_certificate` in the nginx docs and look at how the working file was
   originally assembled.
3. Order is normative: the server's own certificate first, then each CA that
   signed the previous one, up to but NOT including the root.
H
        ;;
      2) cat <<'H'
1. nginx said what is wrong in one line. Read it literally: it compared two
   things and they differ.
2. A certificate is a signed wrapper around a public key. Extract that public
   key from the certificate, extract it from the private key, compare digests.
3. If no key on the box matches the certificate, invert the problem: keep the
   key you have, build a CSR from it, and re-issue with the issuing CA. The
   backup taken at setup time is under /opt/lab-331.2/backup/.
H
        ;;
      3) cat <<'H'
1. `openssl x509 -noout -dates` on the deployed leaf. Compare with `date -u`.
2. Renewal is not repair: you cannot edit notAfter, you must have the CA issue
   a new certificate. The CSR only carries the subject and the public key —
   validity comes from the CA (`-days`) at signing time.
3. The issuing CA lives at /opt/lab-331.2/pki/intermediate with its own
   openssl.cnf, index.txt and serial. Use `-extensions server_cert`, re-assemble
   the fullchain, and reload nginx — a running worker holds the old PEM in memory.
H
        ;;
      4) cat <<'H'
1. `openssl x509 -noout -ext subjectAltName` on the deployed leaf, then compare
   with the name curl is asking for.
2. CN is decorative for name matching in every modern client. The SAN is the
   authority. It is an X.509v3 extension, so it is added by the CA at signing
   time from the extension profile — not copied from the CSR (copy_extensions
   is deliberately 'none' in this CA, and that default exists for a reason).
3. The [ server_cert ] profile reads `subjectAltName = $ENV::LAB_SAN`. Export
   LAB_SAN with every name you need before running `openssl ca`.
H
        ;;
      5) cat <<'H'
1. `openssl crl -in .../intermediate.crl -noout -text` and look for a serial.
   Then `openssl x509 -noout -serial` on your client certificate.
2. Revocation binds a SERIAL NUMBER, not a subject or a key. Nothing removes an
   entry from a CRL. So what does a CA do for a user who is still legitimate?
3. Issue a fresh client certificate (new key and CSR is the correct practice
   after a keyCompromise reason), regenerate the CRL so it stays current, copy
   it where nginx reads it, and reload nginx so the CRL is re-parsed.
H
        ;;
      6) cat <<'H'
1. `head -3` the key file. "Proc-Type: 4,ENCRYPTED" or "BEGIN ENCRYPTED PRIVATE
   KEY" tells you the whole story.
2. A daemon started by systemd has no terminal, so it cannot answer a prompt.
   Either remove the need to answer, or answer it from a file.
3. Decrypt: `openssl pkey -in key -passin pass:L4bP4ssphr4se -out key.new`,
   then chmod 0640 / restore the SELinux label. Or keep it encrypted and add
   `ssl_password_file` (chmod 600, root-owned) to both server blocks.
H
        ;;
      7) cat <<'H'
1. The failure is server-side, in the nginx error log, not in curl's own
   verification. Diff the mTLS server block against the anonymous one.
2. `ssl_client_certificate` is the client trust store. If it holds only the
   root, nginx cannot bridge from a leaf signed by the intermediate — the
   client sends one certificate and nothing supplies the middle link.
3. Point `ssl_client_certificate` at the full CA bundle (intermediate + root)
   and raise `ssl_verify_depth` to at least 2, since the chain is now
   leaf(0) -> intermediate(1) -> root(2). `nginx -t` then reload.
H
        ;;
      *) say "no hints for fault '$1'" ;;
    esac
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

cmd_setup() {
    require_root; require_disposable_vm; require_tools
    mkdir -p "$LAB_ROOT" "$PKI" "$DEPLOY" "$CLIENTDIR" "$WWW" "$STATEDIR" "$BACKUP"
    : > "$LOG"
    ensure_nginx

    hdr "LPIC-3 303 — topic ${LAB_ID} — break & fix lab"
    say "Building a disposable PKI and TLS/mTLS service under ${LAB_ROOT}."

    build_pki
    info "issuing the server leaf (SAN: ${HOST_TLS}, ${HOST_MTLS}, 127.0.0.1)"
    issue_server_cert "DNS:${HOST_TLS},DNS:${HOST_MTLS},IP:127.0.0.1" -days 397
    info "issuing the client leaf (CN=student, extendedKeyUsage=clientAuth)"
    issue_client_cert "student"

    write_content
    deploy_server_material
    write_nginx_conf
    write_hosts

    nginx_test || die "nginx configuration is invalid, see ${LOG}"
    systemctl enable --now nginx >>"$LOG" 2>&1 || true
    systemctl restart nginx >>"$LOG" 2>&1

    sleep 1
    hdr "Baseline"
    if run_checks; then
        snapshot
        state_set fault "none"
        ok "snapshot taken — '$0 reset' will always bring you back here"
        cat <<EOF

${C_C}Endpoints${C_0}
  anonymous TLS ... https://${HOST_TLS}:${PORT}/health
  mutual TLS ...... https://${HOST_MTLS}:${PORT}/whoami   (client cert required)

${C_C}Next${C_0}
  $0 break            # inject a random fault
  $0 break --fault N  # inject fault N (${FAULT_MIN}..${FAULT_MAX})
  $0 list             # what each fault exercises
EOF
    else
        die "baseline is not healthy; inspect ${LOG} before continuing"
    fi
}

cmd_break() {
    require_root; require_disposable_vm
    [[ -d "${BACKUP}/deploy" ]] || die "run '$0 setup' first"
    local n="${1:-}"
    if [[ -z "$n" ]]; then
        n=$(( (RANDOM % (FAULT_MAX - FAULT_MIN + 1)) + FAULT_MIN ))
    fi
    [[ "$n" =~ ^[1-7]$ ]] || die "fault must be an integer ${FAULT_MIN}..${FAULT_MAX}"

    local cur; cur="$(state_get fault none)"
    [[ "$cur" == "none" ]] || { warn "fault ${cur} is still active — resetting first"; rollback; }

    info "injecting fault ${n} (reversible: '$0 reset')"
    state_set fault "$n"
    "fault_${n}_break"
}

cmd_verify() {
    require_root
    [[ -d "${BACKUP}/deploy" ]] || die "run '$0 setup' first"
    if run_checks; then
        local f; f="$(state_get fault none)"
        if [[ "$f" != "none" ]]; then
            printf '\n%sFault %s repaired.%s Clear the marker with: %s clear\n' "$C_G" "$f" "$C_0" "$0"
        fi
        return 0
    fi
    return 1
}

cmd_hint() {
    local f; f="$(state_get fault none)"
    [[ "$f" != "none" ]] || die "no fault is active"
    hdr "Hints for fault ${f}"
    hint_for "$f"
}

cmd_reset() {
    require_root; require_disposable_vm
    info "rolling back to the healthy snapshot"
    rollback
    state_set fault "none"
    sleep 1
    run_checks || warn "still failing after rollback — inspect ${LOG}"
}

cmd_clear() { state_set fault "none"; ok "fault marker cleared"; }

cmd_status() {
    hdr "Lab ${LAB_ID} status"
    printf '  active fault ...... %s\n' "$(state_get fault none)"
    printf '  nginx ............. %s\n' "$(systemctl is-active nginx 2>/dev/null || echo unknown)"
    printf '  listening ......... %s\n' "$(ss -lnt 2>/dev/null | grep -c ":${PORT}") socket(s) on ${PORT}"
    if [[ -f "${DEPLOY}/server-fullchain.pem" ]]; then
        printf '  deployed leaf ..... %s\n' "$(openssl x509 -in "${DEPLOY}/server-fullchain.pem" -noout -subject 2>/dev/null)"
        printf '  validity .......... %s\n' "$(openssl x509 -in "${DEPLOY}/server-fullchain.pem" -noout -enddate 2>/dev/null)"
        printf '  SAN ............... %s\n' "$(openssl x509 -in "${DEPLOY}/server-fullchain.pem" -noout -ext subjectAltName 2>/dev/null | tail -1 | sed 's/^ *//')"
        printf '  certs in file ..... %s\n' "$(grep -c 'BEGIN CERTIFICATE' "${DEPLOY}/server-fullchain.pem")"
    fi
    printf '  CA database ....... %s issued, %s revoked\n' \
        "$(grep -c . "${INTCA}/index.txt" 2>/dev/null || echo 0)" \
        "$(grep -c '^R' "${INTCA}/index.txt" 2>/dev/null || echo 0)"
}

cmd_list() {
    cat <<EOF
Faults available for topic ${LAB_ID}:

  1  incomplete chain of trust      leaf served without its intermediate
  2  key / certificate mismatch     private key does not belong to the cert
  3  expired certificate            validity window in the past, renewal needed
  4  wrong subjectAltName           RFC 6125 hostname verification fails
  5  revoked client certificate     CRL enforcement on the mTLS endpoint
  6  encrypted key, no passphrase   unattended start impossible
  7  mTLS trust store / depth       ssl_client_certificate + ssl_verify_depth

  $0 break --fault N     inject one
  $0 break               inject a random one
EOF
}

cmd_destroy() {
    require_root; require_disposable_vm
    warn "removing ${LAB_ROOT}, ${NGX_CONF} and the /etc/hosts aliases"
    rm -f "$NGX_CONF"
    [[ -f "${BACKUP}/hosts.orig" ]] && cp -a "${BACKUP}/hosts.orig" /etc/hosts
    systemctl reload nginx >>"$LOG" 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
    rm -rf "$LAB_ROOT"
    ok "lab removed (nginx itself was left installed)"
}

cmd_solution() {
    if [[ "${1:-}" != "--spoil" ]]; then
        warn "this prints the full answer key; re-run with: $0 solution --spoil"
        exit 1
    fi
    sed -n '/^# ==== SOLUTION KEY/,$p' "${BASH_SOURCE[0]}"
}

usage() {
    cat <<EOF
lab-331.2-break-and-fix.sh — LPIC-3 303 (303-300 v3.0.0), topic ${LAB_ID}
X.509 Certificates for Encryption, Signing and Authentication

Usage: $0 [--i-am-in-a-disposable-vm] <command> [options]

  setup                  build the PKI, the TLS/mTLS service, prove the baseline
  list                   describe the seven faults
  break [--fault N]      inject a fault (random if N is omitted)
  verify                 run the twelve objective checks
  hint                   three escalating hints for the active fault
  status                 current state of the deployed material
  reset                  roll back to the healthy snapshot
  clear                  clear the fault marker after a manual fix
  destroy                remove everything this lab created
  solution --spoil       print the answer key

Environment: LAB_DISPOSABLE=yes acknowledges the host is throwaway.
EOF
}

main() {
    local args=()
    while (($#)); do
        case "$1" in
            --i-am-in-a-disposable-vm) FORCE_LAB=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    set -- "${args[@]:-}"
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        setup)    cmd_setup ;;
        list)     cmd_list ;;
        break)
            local n=""
            while (($#)); do
                case "$1" in
                    --fault) n="${2:-}"; shift 2 ;;
                    --fault=*) n="${1#*=}"; shift ;;
                    *) shift ;;
                esac
            done
            cmd_break "$n" ;;
        verify)   cmd_verify ;;
        hint)     cmd_hint ;;
        status)   cmd_status ;;
        reset)    cmd_reset ;;
        clear)    cmd_clear ;;
        destroy)  cmd_destroy ;;
        solution) cmd_solution "${1:-}" ;;
        ""|help)  usage ;;
        *)        usage; exit 1 ;;
    esac
}

main "$@"
exit $?

# ==== SOLUTION KEY ========================================================
#
# Read only after you have tried. Every command below is meant to be typed by
# hand on the lab VM; nothing here is automated by the script.
#
# Shared shorthand used throughout:
#     PKI=/opt/lab-331.2/pki
#     INT=$PKI/intermediate                 # the issuing CA
#     DEP=/opt/lab-331.2/deploy             # what nginx reads
#     CLI=/opt/lab-331.2/client             # the client identity
#     H=lab331.example.internal ; M=mtls331.example.internal ; P=8443
#     CURL="curl -sS --cacert $DEP/ca-chain.pem --resolve"
#
# --------------------------------------------------------------------------
# FAULT 1 — incomplete chain of trust
# --------------------------------------------------------------------------
# Diagnose. Count what the server sends; one certificate means no intermediate:
#     openssl s_client -connect 127.0.0.1:$P -servername $H \
#         -CAfile $DEP/ca-chain.pem -showcerts </dev/null | grep -c 'BEGIN CERT'
#     openssl x509 -in $DEP/server-fullchain.pem -noout -subject -issuer
# The leaf's issuer is the issuing CA, which the client does not have in its
# anchor set as a *sent* certificate; the client only trusts the root. RFC 5280
# §6 path building needs the middle link, and TLS says the server supplies it.
#
# Fix. Rebuild the file nginx serves, leaf first, then the intermediate:
#     cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem
#     chmod 0644 $DEP/server-fullchain.pem
#     nginx -t </dev/null && systemctl reload nginx
#
# Prove it, offline and on the wire:
#     openssl verify -CAfile $DEP/root-ca.pem -untrusted $INT/ca.crt $PKI/server.crt
#     openssl s_client -connect 127.0.0.1:$P -servername $H \
#         -CAfile $DEP/ca-chain.pem </dev/null 2>&1 | grep 'Verify return code'
#     # -> Verify return code: 0 (ok)
#
# Note. Never ship the root in ssl_certificate: it wastes handshake bytes and a
# client that does not already trust it will not start trusting it because the
# server sent it. Order matters — OpenSSL reads the file sequentially.
#
# --------------------------------------------------------------------------
# FAULT 2 — key / certificate mismatch
# --------------------------------------------------------------------------
# Diagnose. The algorithm-agnostic comparison (works for RSA, EC, Ed25519):
#     openssl x509 -in $DEP/server-fullchain.pem -noout -pubkey | openssl sha256
#     openssl pkey  -in $DEP/server.key          -pubout        | openssl sha256
# Different digests => the key does not belong to the certificate. The RSA-only
# idiom you will still meet in the field, and in the exam:
#     openssl x509 -noout -modulus -in cert.pem | openssl md5
#     openssl rsa  -noout -modulus -in key.pem  | openssl md5
#     openssl req  -noout -modulus -in csr.pem  | openssl md5
#
# Fix A — restore the key that matches (fastest, correct here):
#     install -m 0640 /opt/lab-331.2/backup/pki-leaf/server.key $DEP/server.key
#     install -m 0400 /opt/lab-331.2/backup/pki-leaf/server.key $PKI/server.key
#
# Fix B — keep the new key and re-issue the certificate for it. This is what you
# do in production when the old key is genuinely gone:
#     cp $DEP/server.key $PKI/server.key
#     openssl req -new -key $PKI/server.key -out $INT/csr/server.csr \
#         -subj "/C=AR/O=Teach-Plat Lab 331.2/CN=$H"
#     export LAB_SAN="DNS:$H,DNS:$M,IP:127.0.0.1"
#     openssl ca -batch -config $INT/openssl.cnf -extensions server_cert \
#         -days 397 -notext -md sha256 -in $INT/csr/server.csr -out $PKI/server.crt
#     cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem
#
# Then, either way:
#     chmod 0640 $DEP/server.key
#     command -v restorecon >/dev/null && chcon -t cert_t $DEP/server.key
#     nginx -t </dev/null && systemctl restart nginx
#     ss -lnt | grep $P
#
# --------------------------------------------------------------------------
# FAULT 3 — expired certificate
# --------------------------------------------------------------------------
# Diagnose.
#     openssl x509 -in $DEP/server-fullchain.pem -noout -dates -serial
#     openssl x509 -in $DEP/server-fullchain.pem -noout -checkend 0 ; echo $?  # 1 = expired
#     date -u
#     grep -E '^[VER]' $INT/index.txt        # V=valid E=expired R=revoked
#
# Fix — renewal is re-issuance. Reuse the key (the SAN and CN must not change):
#     openssl req -new -key $PKI/server.key -out $INT/csr/server.csr \
#         -subj "/C=AR/O=Teach-Plat Lab 331.2/CN=$H"
#     export LAB_SAN="DNS:$H,DNS:$M,IP:127.0.0.1"
#     openssl ca -batch -config $INT/openssl.cnf -extensions server_cert \
#         -days 397 -notext -md sha256 -in $INT/csr/server.csr -out $PKI/server.crt
#     cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem
#     nginx -t </dev/null && systemctl reload nginx
#
# Prove it:
#     openssl x509 -in $DEP/server-fullchain.pem -noout -dates
#     openssl x509 -in $DEP/server-fullchain.pem -noout -checkend 2592000 ; echo $?  # 0
#     $CURL $H:$P:127.0.0.1 https://$H:$P/health
#
# Notes.
#   * `openssl ca` refuses a second certificate for the same DN unless
#     index.txt.attr says `unique_subject = no`. This lab sets it; a default CA
#     does not, and that is the error you will hit on a real renewal.
#   * A reload, not a restart, is enough — but a reload IS required: workers
#     hold the parsed PEM in memory and never re-read it on their own.
#   * 397 days is the CA/Browser Forum maximum for public TLS certificates; an
#     internal CA may go longer, but matching the public limit keeps your
#     rotation muscle honest.
#
# --------------------------------------------------------------------------
# FAULT 4 — wrong subjectAltName
# --------------------------------------------------------------------------
# Diagnose. openssl verify says OK because it checks the PATH, never the NAME:
#     openssl verify -CAfile $DEP/ca-chain.pem $PKI/server.crt          # OK — misleading
#     openssl x509 -in $DEP/server-fullchain.pem -noout -subject -ext subjectAltName
#     openssl s_client -connect 127.0.0.1:$P -servername $H \
#         -verify_hostname $H -CAfile $DEP/ca-chain.pem </dev/null 2>&1 | tail -5
#
# Fix — re-issue with the correct SAN. Two equivalent routes:
#
#   Route 1, SAN from the CA's issuance profile (what a real CA does — note
#   copy_extensions=none, so anything in the CSR is deliberately ignored):
#     openssl req -new -key $PKI/server.key -out $INT/csr/server.csr \
#         -subj "/C=AR/O=Teach-Plat Lab 331.2/CN=$H"
#     export LAB_SAN="DNS:$H,DNS:$M,IP:127.0.0.1"
#     openssl ca -batch -config $INT/openssl.cnf -extensions server_cert \
#         -days 397 -notext -md sha256 -in $INT/csr/server.csr -out $PKI/server.crt
#
#   Route 2, SAN from an explicit extension file (handy for one-offs):
#     cat > /tmp/san.ext <<'EOF'
#     basicConstraints = critical, CA:FALSE
#     keyUsage         = critical, digitalSignature, keyEncipherment
#     extendedKeyUsage = serverAuth
#     subjectAltName   = DNS:lab331.example.internal,DNS:mtls331.example.internal,IP:127.0.0.1
#     subjectKeyIdentifier   = hash
#     authorityKeyIdentifier = keyid,issuer
#     EOF
#     openssl x509 -req -in $INT/csr/server.csr -CA $INT/ca.crt \
#         -CAkey $INT/private/ca.key -CAcreateserial -days 397 -sha256 \
#         -extfile /tmp/san.ext -out $PKI/server.crt
#     # (x509 -req bypasses the CA database — fine for a lab, wrong for a real CA,
#     #  because the certificate is then not recorded in index.txt and can never
#     #  be revoked through `openssl ca -revoke`.)
#
# Deploy and prove:
#     cat $PKI/server.crt $INT/ca.crt > $DEP/server-fullchain.pem
#     nginx -t </dev/null && systemctl reload nginx
#     openssl x509 -in $DEP/server-fullchain.pem -noout -ext subjectAltName
#     $CURL $H:$P:127.0.0.1 https://$H:$P/health
#
# Note. CN has not been a valid source of hostname identity since RFC 6125 and
# the Baseline Requirements; Chrome dropped CN fallback in 2017, Go in 1.15.
# If a name is not in the SAN, it does not exist as far as the client is
# concerned. Wildcards (DNS:*.example.internal) match one label only, never the
# bare domain, and never a dotted sublabel.
#
# --------------------------------------------------------------------------
# FAULT 5 — revoked client certificate
# --------------------------------------------------------------------------
# Diagnose.
#     openssl x509 -in $CLI/client.crt -noout -serial
#     openssl crl  -in $DEP/intermediate.crl -noout -text | grep -A2 'Serial Number'
#     openssl verify -crl_check -CAfile $DEP/ca-chain.pem \
#         -CRLfile $DEP/intermediate.crl $CLI/client.crt
#     # -> error 23 at 0 depth lookup: certificate revoked
#     grep '^R' $INT/index.txt
#     tail -n 20 /var/log/nginx/error.log
#
# Fix — you cannot un-revoke. Issue a new identity. Because the recorded reason
# was keyCompromise, a new KEY is mandatory, not just a new certificate:
#     openssl req -new -nodes -newkey rsa:2048 -sha256 \
#         -keyout $CLI/client.key -out $INT/csr/client.csr \
#         -subj "/C=AR/O=Teach-Plat Lab 331.2/OU=Students/CN=student"
#     chmod 400 $CLI/client.key
#     openssl ca -batch -config $INT/openssl.cnf -extensions client_cert \
#         -days 365 -notext -md sha256 -in $INT/csr/client.csr -out $CLI/client.crt
#
# Keep the CRL current and let nginx re-read it (nginx parses ssl_crl at
# configuration load; an expired CRL fails every client, so regenerate before
# nextUpdate — that is a cron job in production, or move to OCSP):
#     openssl ca -batch -config $INT/openssl.cnf -gencrl -out $INT/crl/intermediate.crl
#     install -m 0644 $INT/crl/intermediate.crl $DEP/intermediate.crl
#     nginx -t </dev/null && systemctl reload nginx
#
# Prove it:
#     openssl verify -crl_check -CAfile $DEP/ca-chain.pem \
#         -CRLfile $DEP/intermediate.crl $CLI/client.crt        # -> OK
#     openssl crl -in $DEP/intermediate.crl -noout -lastupdate -nextupdate
#     $CURL $M:$P:127.0.0.1 --cert $CLI/client.crt --key $CLI/client.key \
#         https://$M:$P/whoami                                  # -> verify=SUCCESS
#     $CURL $M:$P:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://$M:$P/whoami  # -> 400
#
# Note. `-crl_check` validates only the leaf's CRL; `-crl_check_all` demands a
# CRL for every CA in the path, which means you also need the root's CRL. Reason
# codes matter operationally: only `certificateHold` is reversible, via
# `openssl ca -config ... -crl_reason removeFromCRL`.
#
# --------------------------------------------------------------------------
# FAULT 6 — encrypted key with no passphrase source
# --------------------------------------------------------------------------
# Diagnose.
#     head -3 $DEP/server.key                 # BEGIN ENCRYPTED PRIVATE KEY
#     openssl pkey -in $DEP/server.key -noout ; echo $?    # prompts / fails
#     journalctl -u nginx -n 30 --no-pager
#
# Fix A — remove the passphrase (the common production choice; the key is then
# protected by the filesystem, so ownership and mode carry the whole weight):
#     openssl pkey -in $DEP/server.key -passin pass:L4bP4ssphr4se -out /tmp/plain.key
#     install -o root -g root -m 0640 /tmp/plain.key $DEP/server.key
#     install -o root -g root -m 0400 /tmp/plain.key $PKI/server.key
#     shred -u /tmp/plain.key
#     command -v chcon >/dev/null && chcon -t cert_t $DEP/server.key
#     systemctl restart nginx
#
# Fix B — keep it encrypted and feed nginx the passphrase. Add to BOTH server
# blocks in /etc/nginx/conf.d/lab-331-2.conf, next to ssl_certificate_key:
#     printf 'L4bP4ssphr4se\n' > /etc/nginx/ssl_passwords
#     chown root:root /etc/nginx/ssl_passwords && chmod 0600 /etc/nginx/ssl_passwords
#     # ssl_password_file /etc/nginx/ssl_passwords;
#     nginx -t </dev/null && systemctl restart nginx
#
# Prove it — the test that matters is the unattended one:
#     systemctl restart nginx && systemctl is-active nginx
#     openssl x509 -in $DEP/server-fullchain.pem -noout -pubkey | openssl sha256
#     openssl pkey -in $DEP/server.key -pubout | openssl sha256     # same digest
#
# Note. Argue the trade-off out loud: Fix B does not protect the key from
# anyone who can read the filesystem as root — it only stops a casual copy of
# the key file alone from being useful. Real protection at rest means an HSM,
# a TPM, or a KMS-fronted key, not a passphrase in a sibling file.
#
# --------------------------------------------------------------------------
# FAULT 7 — mTLS trust store and verification depth
# --------------------------------------------------------------------------
# Diagnose. The client certificate is fine; the server's trust store is not:
#     openssl verify -CAfile $DEP/ca-chain.pem $CLI/client.crt      # OK
#     openssl x509 -in $CLI/client.crt -noout -issuer               # the issuing CA
#     grep -nE 'ssl_client_certificate|ssl_verify_depth' /etc/nginx/conf.d/lab-331-2.conf
#     # ssl_client_certificate points at root-ca.pem, depth is 1
#     openssl s_client -connect 127.0.0.1:$P -servername $M </dev/null 2>&1 \
#         | sed -n '/Acceptable client certificate CA names/,/^---/p'
#     tail -n 20 /var/log/nginx/error.log     # (20:unable to get local issuer certificate)
#
# Fix — two independent problems, both must be corrected. In the $M server block:
#     ssl_client_certificate /opt/lab-331.2/deploy/ca-chain.pem;   # intermediate + root
#     ssl_verify_depth       2;                                    # leaf(0) int(1) root(2)
# Apply with:
#     nginx -t </dev/null && systemctl reload nginx
#
# Prove both halves — authentication works AND anonymity is still refused:
#     $CURL $M:$P:127.0.0.1 --cert $CLI/client.crt --key $CLI/client.key \
#         https://$M:$P/whoami                       # -> verify=SUCCESS dn=...
#     $CURL $M:$P:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://$M:$P/whoami   # -> 400
#
# Notes.
#   * ssl_client_certificate does two jobs at once: it is the trust store, and
#     its subjects are broadcast in the CertificateRequest as acceptable CA
#     names. Loading a large bundle leaks your internal CA topology and can blow
#     past client-side handshake limits — ssl_trusted_certificate lets you trust
#     without advertising.
#   * ssl_verify_depth counts intermediates between the leaf and the trust
#     anchor. A two-tier PKI needs at least 2. The symptom of getting this wrong
#     is indistinguishable from a missing CA, which is why you check both.
#   * Neither `ssl_verify_client optional` nor re-issuing clients directly off
#     the root is a fix: the first disables the control you were asked to keep,
#     the second destroys the reason a two-tier PKI exists — the root stays
#     offline so that compromising the online issuer does not end the PKI.
#
# --------------------------------------------------------------------------
# GENERAL DIAGNOSTIC LADDER for any X.509/TLS incident
# --------------------------------------------------------------------------
#   1. Is the process up and the port open?          systemctl status / ss -lntp
#   2. Does the config even parse?                   nginx -t </dev/null
#   3. What is ON DISK?                              openssl x509 -noout -text
#   4. Does the key match the cert?                  -pubkey | sha256 both sides
#   5. What goes ON THE WIRE?                        openssl s_client -showcerts
#   6. Does the PATH build?                          openssl verify -untrusted
#   7. Is it in DATE?                                openssl x509 -checkend
#   8. Does the NAME match?                          -verify_hostname / curl
#   9. Is it REVOKED?                                openssl verify -crl_check
#  10. For client auth, repeat 3-9 from the server's point of view, in the
#      server's error log — the client only ever sees "400" or a TLS alert.
#
# Verify codes worth memorising for 303-300:
#   10 certificate has expired            19 self-signed certificate in chain
#   18 self-signed certificate            20 unable to get local issuer certificate
#   21 unable to verify the first certificate
#   23 certificate revoked                24 invalid CA certificate
#   26 unsupported certificate purpose (keyUsage / extendedKeyUsage mismatch)
#   62 hostname mismatch
# ==== END SOLUTION KEY ====================================================