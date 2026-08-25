#!/usr/bin/env bash
#===============================================================================
# LPIC-3 303 Security  —  exam 303-300, version 3.0.0
# Topic 333.2  Mandatory Access Control   (exam weight: 8.33)
#
#   break-fix-333.2-mac.sh — a controlled "break & fix" lab
#
# WHAT THIS IS
#   This script deliberately misconfigures the Mandatory Access Control layer of
#   a THROWAWAY lab VM, tells you the symptom you are about to see and the goal
#   you must reach, and then gets out of the way. Nothing here is a simulation:
#   the kernel really denies the access, the daemon really fails, the audit
#   records are real. The step-by-step solution is at the bottom of this file,
#   commented out — do not read it until you have burned some time in
#   ausearch(8) / dmesg(1).
#
#   Two tracks, auto-detected:
#     SELinux  track (RHEL / CentOS Stream / Rocky / Alma / Fedora)
#     AppArmor track (Debian / Ubuntu / openSUSE)
#   Smack is covered in the commented appendix at the end (LPI lists it as an
#   objective, but almost no general-purpose distro ships it enabled).
#
# THE ONE RULE OF THE LAB
#   You may NOT fix anything by weakening the MAC layer. `setenforce 0`,
#   `SELINUX=disabled`, `aa-complain`, `aa-teardown`, `apparmor_parser -R`,
#   `chmod 777`, `systemctl disable apparmor` — all of these "work" and all of
#   them score zero. `verify` checks that the enforcement is still on.
#
# USAGE
#   sudo ./break-fix-333.2-mac.sh break     # arm the lab (default)
#   sudo ./break-fix-333.2-mac.sh verify    # score your fix
#   sudo ./break-fix-333.2-mac.sh hint      # which tool to reach for, no answers
#   sudo ./break-fix-333.2-mac.sh restore   # undo everything, back to clean
#
#   Environment:
#     LAB_FORCE=yes   skip the interactive "this destroys the VM" confirmation
#     LAB_MAC=selinux|apparmor    force a track instead of auto-detecting
#
# SAFETY
#   Run it on a disposable VM you can roll back with a snapshot. It refuses to
#   run on bare metal unless you set LAB_FORCE=yes, it never touches user data,
#   every change it makes is recorded in the state file and reversed by
#   `restore`. It does not open a single network port to the outside: all
#   verification is done over 127.0.0.1.
#
# REFERENCES (official)
#   LPI 303-300 objectives ....... https://www.lpi.org/our-certifications/exam-303-objectives/
#   SELinux project .............. https://selinuxproject.org/page/Main_Page
#   Red Hat, "Using SELinux" ..... https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/index
#   AppArmor upstream wiki ....... https://gitlab.com/apparmor/apparmor/-/wikis/home
#   Kernel LSM: AppArmor ......... https://www.kernel.org/doc/html/latest/admin-guide/LSM/apparmor.html
#   Kernel LSM: Smack ............ https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
#   man: selinux(8) semanage-port(8) semanage-fcontext(8) booleans(8)
#        restorecon(8) audit2why(8) apparmor.d(5) apparmor_parser(8) aa-status(8)
#===============================================================================

set -Eeuo pipefail

readonly LAB="333.2-mac"
readonly STATE_DIR="/var/lib/lpic303-lab"
readonly STATE="${STATE_DIR}/${LAB}.env"
readonly MARK="LPIC3-333.2"

# --- SELinux track objects ----------------------------------------------------
readonly SE_CONF="/etc/httpd/conf.d/lab333.conf"
readonly SE_DOCROOT="/var/www/html"
readonly SE_ALTDATA="/srv/webdata"
readonly SE_CGI="/var/www/cgi-bin/probe.cgi"
readonly SE_FCONTEXT_SPEC='/srv/webdata(/.*)?'

# --- AppArmor track objects ---------------------------------------------------
readonly AA_TOOL="/usr/local/bin/labreader"
readonly AA_PROFILE="/etc/apparmor.d/usr.local.bin.labreader"
readonly AA_DATA_DIR="/srv/labdata"
readonly AA_DATA="/srv/labdata/inventory.csv"
readonly AA_REPORT="/var/log/labreader.report"

#------------------------------------------------------------------------------
# output helpers
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[36m'; C_D=$'\033[2m';  C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

log()  { printf '%s[ lab ]%s %s\n'  "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n'  "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn ]%s %s\n'  "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[fail ]%s %s\n'  "$C_R" "$C_0" "$*"; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$C_D" "------------------------------------------------------------------------" "$C_0"; }
head1() { hr; printf '%s\n' "$*"; hr; }

trap 'err "unexpected error at line ${LINENO} (exit ${?})"' ERR

#------------------------------------------------------------------------------
# guards
#------------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "run me as root: sudo $0 ${1:-break}"
}

confirm_disposable() {
    local virt="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    fi
    if [[ "${LAB_FORCE:-no}" == "yes" ]]; then
        warn "LAB_FORCE=yes — skipping the confirmation prompt (virt=${virt})"
        return 0
    fi
    if [[ "${virt}" == "none" ]]; then
        err "systemd-detect-virt says this is NOT a virtual machine."
        err "This lab breaks the web server and the MAC policy of the running host."
        die "If you really are on a disposable machine, re-run with LAB_FORCE=yes"
    fi
    if [[ ! -t 0 ]]; then
        die "non-interactive shell: re-run with LAB_FORCE=yes if this VM is disposable"
    fi
    head1 "READ THIS BEFORE CONTINUING"
    cat <<EOF
  Hypervisor detected: ${virt}
  This script will deliberately break Mandatory Access Control configuration
  on THIS machine: file contexts / port labels / booleans (SELinux) or a
  confining profile (AppArmor). It is reversible with:  $0 restore
  It is still, by design, a broken system until you fix it.

  Take a VM snapshot now if you have not already.
EOF
    hr
    local ans=""
    read -r -p 'Type exactly: BREAK MY LAB VM > ' ans
    [[ "${ans}" == "BREAK MY LAB VM" ]] || die "aborted, nothing was changed"
}

#------------------------------------------------------------------------------
# misc helpers
#------------------------------------------------------------------------------
pkg_install() {
    local rc=0
    if   command -v dnf     >/dev/null 2>&1; then dnf -y install "$@"     >/dev/null 2>&1 || rc=$?
    elif command -v yum     >/dev/null 2>&1; then yum -y install "$@"     >/dev/null 2>&1 || rc=$?
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -y install "$@" >/dev/null 2>&1 || rc=$?
    elif command -v zypper  >/dev/null 2>&1; then zypper -n install "$@"  >/dev/null 2>&1 || rc=$?
    else rc=127
    fi
    return "${rc}"
}

http_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo "000"
}

ctx_type() {
    stat -c '%C' "$1" 2>/dev/null | awk -F: '{print $3}'
}

save_state() {
    mkdir -p "${STATE_DIR}"
    : >"${STATE}"
    local kv
    for kv in "$@"; do printf '%s\n' "${kv}" >>"${STATE}"; done
    chmod 0600 "${STATE}"
}

load_state() {
    # shellcheck disable=SC1090
    [[ -f "${STATE}" ]] && . "${STATE}" || true
}

detect_mac() {
    if [[ -n "${LAB_MAC:-}" ]]; then printf '%s\n' "${LAB_MAC}"; return; fi
    if [[ -d /sys/fs/selinux ]] && command -v getenforce >/dev/null 2>&1; then
        [[ "$(getenforce)" != "Disabled" ]] && { echo selinux; return; }
    fi
    if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
        [[ "$(cat /sys/module/apparmor/parameters/enabled)" == "Y" ]] && { echo apparmor; return; }
    fi
    echo none
}

PASS=0; FAILED=0
check() {  # check "<description>" <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${desc}"; PASS=$((PASS+1))
    else err "${desc}"; FAILED=$((FAILED+1)); fi
}
check_eq() {  # check_eq "<description>" "<expected>" "<actual>"
    local desc="$1" want="$2" got="$3"
    if [[ "${want}" == "${got}" ]]; then ok "${desc}  [${got}]"; PASS=$((PASS+1))
    else err "${desc}  [expected: ${want} / got: ${got:-<empty>}]"; FAILED=$((FAILED+1)); fi
}

#==============================================================================
#  SELINUX TRACK
#==============================================================================

se_require_tools() {
    command -v getenforce >/dev/null 2>&1 || die "getenforce missing — is this really an SELinux system?"
    if [[ "$(getenforce)" == "Disabled" ]]; then
        err "SELinux is disabled in the kernel. It cannot be turned on at runtime."
        err "Set SELINUX=enforcing in /etc/selinux/config, then:"
        err "    sudo fixfiles -F onboot && sudo reboot     # full relabel on next boot"
        die "re-run this lab after the reboot"
    fi
    if ! command -v semanage >/dev/null 2>&1; then
        log "semanage is missing, installing policycoreutils-python-utils ..."
        pkg_install policycoreutils-python-utils setools-console || true
    fi
    command -v semanage   >/dev/null 2>&1 || die "install policycoreutils-python-utils and re-run"
    command -v restorecon >/dev/null 2>&1 || die "install policycoreutils and re-run"
    if ! command -v httpd >/dev/null 2>&1; then
        log "installing httpd (the lab needs a confined daemon to abuse) ..."
        pkg_install httpd audit || true
    fi
    command -v httpd >/dev/null 2>&1 || die "httpd not installed and could not be installed (no network?)"
    command -v curl  >/dev/null 2>&1 || pkg_install curl || true
    systemctl is-active --quiet auditd 2>/dev/null || \
        warn "auditd is not running: AVC records will land in the kernel ring buffer (dmesg / journalctl -k), not in /var/log/audit/audit.log"
}

se_pick_port() {
    # A port that is NOT already in http_port_t and that nothing is listening on.
    local p labelled
    labelled="$(semanage port -l 2>/dev/null | awk '$1=="http_port_t"' || true)"
    for p in 8000 8888 9192 4000 6000; do
        printf '%s' "${labelled}" | grep -qw "${p}" && continue
        ss -lnt 2>/dev/null | grep -q ":${p}[[:space:]]" && continue
        printf '%s\n' "${p}"; return 0
    done
    printf '8000\n'
}

se_prepare_content() {
    mkdir -p "${SE_DOCROOT}" "${SE_ALTDATA}" /var/www/cgi-bin

    cat >"${SE_DOCROOT}/index.html" <<EOF
<!doctype html><html><head><title>${MARK}</title></head>
<body><h1>${MARK} docroot OK</h1></body></html>
EOF

    cat >"${SE_ALTDATA}/report.html" <<EOF
<!doctype html><html><head><title>${MARK}</title></head>
<body><h1>${MARK} alternate data dir OK</h1></body></html>
EOF

    cat >"${SE_CGI}" <<'EOF'
#!/bin/bash
printf 'Content-Type: text/plain\r\n\r\n'
printf 'LPIC3-333.2 CGI-OK\n'
printf 'running as domain: %s\n' "$(id -Z 2>/dev/null || echo unknown)"
EOF
    chmod 0755 "${SE_CGI}"

    # Everything starts life correctly labelled; the breakage is applied after.
    restorecon -R "${SE_DOCROOT}" /var/www/cgi-bin >/dev/null 2>&1 || true
}

se_write_httpd_conf() {
    local port="$1"
    cat >"${SE_CONF}" <<EOF
# ${MARK} lab — generated by break-fix-333.2-mac.sh, removed by 'restore'
Listen ${port}

Alias /data ${SE_ALTDATA}
<Directory "${SE_ALTDATA}">
    AllowOverride None
    Options None
    Require all granted
</Directory>
EOF
    # RHEL's stock httpd.conf already ships ScriptAlias /cgi-bin/; add it only if absent.
    if ! grep -rqs '^[[:space:]]*ScriptAlias[[:space:]]\+/cgi-bin/' /etc/httpd/conf /etc/httpd/conf.d; then
        cat >>"${SE_CONF}" <<'EOF'

ScriptAlias /cgi-bin/ "/var/www/cgi-bin/"
<Directory "/var/www/cgi-bin">
    AllowOverride None
    Options +ExecCGI
    Require all granted
</Directory>
EOF
    fi
}

se_break() {
    se_require_tools

    local mode_orig conf_orig bool_orig port
    mode_orig="$(getenforce)"
    conf_orig="$(awk -F= '/^SELINUX=/{print $2}' /etc/selinux/config 2>/dev/null | head -1 || true)"
    bool_orig="$(getsebool httpd_enable_cgi 2>/dev/null | awk '{print $3}' || echo on)"

    if [[ "${mode_orig}" != "Enforcing" ]]; then
        log "SELinux was ${mode_orig}; this lab only makes sense in Enforcing mode — switching"
        setenforce 1
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
    fi

    se_prepare_content
    port="$(se_pick_port)"
    se_write_httpd_conf "${port}"

    save_state \
        "LAB_TRACK=selinux" \
        "LAB_PORT=${port}" \
        "LAB_BOOL_ORIG=${bool_orig}" \
        "LAB_MODE_ORIG=${mode_orig}" \
        "LAB_CONF_ORIG=${conf_orig:-enforcing}" \
        "LAB_BROKEN_AT=$(date -Is)"

    head1 "ARMING THE SELINUX BREAKAGE"

    # BREAK 1 — the classic "I copied the site from my home directory" mislabel.
    log "break 1/4: relabelling ${SE_DOCROOT} with a type httpd_t may not read"
    chcon -R -t user_home_t "${SE_DOCROOT}" 2>/dev/null || \
        chcon -R -t samba_share_t "${SE_DOCROOT}"

    # BREAK 2 — content served from outside the default policy paths.
    #           /srv defaults to var_t, which httpd_t cannot read.
    log "break 2/4: ${SE_ALTDATA} left with the default /srv label (var_t)"
    semanage fcontext -d "${SE_FCONTEXT_SPEC}" >/dev/null 2>&1 || true
    restorecon -R "${SE_ALTDATA}" >/dev/null 2>&1 || true

    # BREAK 3 — a listening port outside http_port_t.
    log "break 3/4: httpd told to Listen on tcp/${port}, which is not labelled http_port_t"
    semanage port -d -t http_port_t -p tcp "${port}" >/dev/null 2>&1 || true

    # BREAK 4 — a policy boolean turned off.
    log "break 4/4: setsebool -P httpd_enable_cgi off"
    setsebool -P httpd_enable_cgi off

    systemctl enable httpd >/dev/null 2>&1 || true
    log "restarting httpd (it is expected to fail — that is break 3) ..."
    systemctl restart httpd >/dev/null 2>&1 || true

    se_brief
}

se_brief() {
    load_state
    head1 "TOPIC 333.2 — SELINUX BREAK & FIX BRIEFING"
    cat <<EOF
SCENARIO
  A web server on this VM serves three things:
      http://127.0.0.1:${LAB_PORT:-8000}/                  static site from ${SE_DOCROOT}
      http://127.0.0.1:${LAB_PORT:-8000}/data/report.html  alias onto ${SE_ALTDATA}
      http://127.0.0.1:${LAB_PORT:-8000}/cgi-bin/probe.cgi a CGI script
  Every file exists, every file is world-readable, the Apache configuration is
  syntactically valid ('apachectl configtest' returns 'Syntax OK'), and the
  service still does not work. DAC is not your problem here.

SYMPTOMS YOU WILL SEE — they surface in this order, one per layer you fix
  1. httpd will not start at all:
         Job for httpd.service failed ... see "systemctl status httpd"
         (13)Permission denied: AH00072: make_sock: could not bind to address
     Note the (13): the bind(2) itself is being refused, not the port being busy.
     'ss -lntp' shows nothing listening on tcp/${LAB_PORT:-8000}.
  2. Once it starts, http://127.0.0.1:${LAB_PORT:-8000}/ returns 403 Forbidden,
     and so does /data/report.html — for two DIFFERENT underlying reasons.
  3. /cgi-bin/probe.cgi returns 500 Internal Server Error; error_log says the
     script could not be executed.

WHAT YOU MUST ACHIEVE
  All three URLs return HTTP 200 with SELinux still in Enforcing mode, and the
  fix must SURVIVE A FULL FILESYSTEM RELABEL and a reboot. That last clause is
  the whole exam: 'verify' runs 'restorecon -R ${SE_ALTDATA}' and 'getsebool -P'
  style persistence checks on purpose. A fix that a relabel erases is not a fix.

FORBIDDEN (scored as zero by 'verify')
  setenforce 0 · SELINUX=permissive/disabled · chmod 777 · disabling httpd's
  confinement (permissive domains) · moving the content into someone else's
  policy by accident (e.g. labelling everything public_content_rw_t).

TOOLBOX — in the order a working sysadmin actually reaches for it
  systemctl status httpd ; journalctl -xeu httpd
  ausearch -m AVC,USER_AVC,SELINUX_ERR -ts recent
  ausearch -m AVC -ts recent | audit2why
  sealert -a /var/log/audit/audit.log          (needs setroubleshoot-server)
  ls -Zd DIR ; ps -eZ | grep httpd ; matchpathcon PATH
  semanage fcontext -l | grep ... ; semanage port -l | grep http
  getsebool -a | grep httpd ; semanage boolean -l -C
  restorecon -Rv PATH ; man -k selinux ; man httpd_selinux

  When you think you are done:   sudo $0 verify
  Stuck for more than 20 min:    sudo $0 hint
EOF
    hr
}

se_verify() {
    load_state
    se_require_tools
    local port="${LAB_PORT:-8000}"
    PASS=0; FAILED=0

    head1 "SCORING — SELINUX TRACK"

    check_eq "SELinux is still Enforcing (no cheating)" "Enforcing" "$(getenforce)"
    check_eq "/etc/selinux/config survives a reboot as enforcing" "enforcing" \
             "$(awk -F= '/^SELINUX=/{print $2}' /etc/selinux/config 2>/dev/null | head -1 || true)"
    check "httpd_t is a confined, non-permissive domain" \
          bash -c '! semanage permissive -l 2>/dev/null | grep -qw httpd_t'

    check "httpd.service is active" systemctl is-active --quiet httpd
    check_eq "tcp/${port} is labelled http_port_t" "yes" \
             "$(semanage port -l 2>/dev/null | awk '$1=="http_port_t"' | grep -qw "${port}" && echo yes || echo no)"

    check_eq "GET /  returns 200" "200" "$(http_code "http://127.0.0.1:${port}/")"
    check_eq "${SE_DOCROOT}/index.html carries httpd_sys_content_t" \
             "httpd_sys_content_t" "$(ctx_type "${SE_DOCROOT}/index.html")"

    log "persistence test: running 'restorecon -Rv ${SE_ALTDATA}' — a chcon-only"
    log "fix is erased by this, exactly as it would be by a reboot relabel."
    restorecon -Rv "${SE_ALTDATA}" 2>&1 | sed 's/^/       /' || true

    check_eq "a file context rule exists for ${SE_ALTDATA}" "yes" \
             "$(semanage fcontext -l 2>/dev/null | grep -q "${SE_ALTDATA}" && echo yes || echo no)"
    check_eq "${SE_ALTDATA}/report.html still httpd_sys_content_t after relabel" \
             "httpd_sys_content_t" "$(ctx_type "${SE_ALTDATA}/report.html")"
    check_eq "GET /data/report.html returns 200" "200" \
             "$(http_code "http://127.0.0.1:${port}/data/report.html")"

    check_eq "boolean httpd_enable_cgi is on" "on" \
             "$(getsebool httpd_enable_cgi 2>/dev/null | awk '{print $3}' || true)"
    check_eq "boolean httpd_enable_cgi is PERSISTED (setsebool -P)" "yes" \
             "$(semanage boolean -l 2>/dev/null | awk '$1=="httpd_enable_cgi"{gsub(/[(),]/,"",$0); print ($3=="on"||$4=="on")?"yes":"no"}' | head -1)"
    check_eq "GET /cgi-bin/probe.cgi returns 200" "200" \
             "$(http_code "http://127.0.0.1:${port}/cgi-bin/probe.cgi")"

    hr
    local recent
    recent="$(ausearch -m AVC -ts recent 2>/dev/null | grep -c 'denied' || true)"
    [[ -n "${recent}" && "${recent}" != "0" ]] && \
        warn "${recent} AVC denial line(s) still in the recent audit window — 'ausearch -m AVC -ts recent | audit2allow -w'"

    se_score
}

se_score() {
    hr
    if [[ ${FAILED} -eq 0 ]]; then
        ok "${PASS}/${PASS} checks passed. The system is fixed WITH SELinux enforcing."
        ok "Now prove it to yourself the brutal way:  sudo touch /.autorelabel && sudo reboot"
        ok "Clean the VM when you are done:  sudo $0 restore"
    else
        err "${FAILED} check(s) failing, ${PASS} passing. Keep going — 'sudo $0 hint'."
    fi
}

se_hint() {
    load_state
    head1 "HINTS — SELINUX TRACK (no answers, just the right tool)"
    cat <<EOF
1. Service will not start
   The message is (13)Permission denied on bind. DAC would give you EACCES only
   below port 1024, and tcp/${LAB_PORT:-8000} is not privileged. So who else can
   refuse a bind? Look for a name_bind denial:
       ausearch -m AVC -ts recent | grep name_bind
   Then read the tcontext of that record: the PORT itself has a type, and it is
   not the one httpd_t is allowed to bind. 'semanage port -l | grep ^http_port_t'
   shows which ports the policy considers "http". Ports are policy objects.

2. Two 403s, two different causes
   'ls -Zd' the two directories and compare each with what the policy says it
   SHOULD be: 'matchpathcon /var/www/html' and 'matchpathcon ${SE_ALTDATA}'.
   One of them has drifted from its correct default — a tool exists whose entire
   job is putting a path back to its default. The other has no useful default at
   all, because the policy has never heard of that path: you must first TEACH the
   policy the rule, then apply it. 'semanage fcontext' is that database;
   chcon writes the label straight onto the inode and the database never learns.
   Ask yourself which of the two survives 'restorecon -R'.

3. The 500 on the CGI
   Pipe the denial through the tool that explains WHY instead of what:
       ausearch -m AVC -ts recent | audit2why
   When a denial is caused by a tunable, audit2why names the boolean and prints
   the exact command. Read 'man httpd_selinux' for the full list of httpd
   tunables. Remember which flag makes a boolean survive a reboot.

4. Reflex worth building
   audit2allow -M mymodule is the LAST resort, not the first. If a boolean or a
   file context solves it, a custom policy module is technical debt you will be
   carrying at 3am two years from now.
EOF
    hr
}

se_restore() {
    load_state
    head1 "RESTORING — SELINUX TRACK"
    systemctl stop httpd >/dev/null 2>&1 || true
    rm -f "${SE_CONF}" "${SE_CGI}"
    [[ -n "${LAB_PORT:-}" ]] && semanage port -d -t http_port_t -p tcp "${LAB_PORT}" >/dev/null 2>&1 || true
    semanage fcontext -d "${SE_FCONTEXT_SPEC}" >/dev/null 2>&1 || true
    rm -rf "${SE_ALTDATA}"
    rm -f "${SE_DOCROOT}/index.html"
    restorecon -R /var/www >/dev/null 2>&1 || true
    setsebool -P httpd_enable_cgi "${LAB_BOOL_ORIG:-on}" >/dev/null 2>&1 || true
    systemctl restart httpd >/dev/null 2>&1 || true
    ok "SELinux lab objects removed; port label, fcontext rule and boolean reverted."
}

#==============================================================================
#  APPARMOR TRACK
#==============================================================================

aa_require_tools() {
    [[ -r /sys/module/apparmor/parameters/enabled ]] || die "AppArmor LSM not present in this kernel"
    [[ "$(cat /sys/module/apparmor/parameters/enabled)" == "Y" ]] || \
        die "AppArmor is disabled — add 'apparmor=1 security=apparmor' to the kernel cmdline and reboot"
    if ! command -v apparmor_parser >/dev/null 2>&1; then
        log "installing apparmor + apparmor-utils ..."
        pkg_install apparmor apparmor-utils apparmor-profiles || true
    fi
    command -v apparmor_parser >/dev/null 2>&1 || die "apparmor_parser missing and could not be installed"
    command -v aa-status >/dev/null 2>&1 || warn "aa-status missing — install apparmor-utils for aa-status/aa-logprof/aa-complain"
    [[ -f /etc/apparmor.d/abstractions/base ]] || die "abstractions/base missing — install the apparmor package properly"
}

aa_profile_mode() {
    local line
    line="$(grep -E "^${AA_TOOL} \(" /sys/kernel/security/apparmor/profiles 2>/dev/null | head -1 || true)"
    [[ -z "${line}" ]] && { echo "unloaded"; return; }
    printf '%s\n' "${line}" | sed -e 's/.*(\(.*\)).*/\1/'
}

aa_write_tool() {
    mkdir -p "${AA_DATA_DIR}"
    cat >"${AA_DATA}" <<EOF
sku,description,qty
A-1001,${MARK} widget,17
A-1002,${MARK} gadget,4
A-1003,${MARK} sprocket,231
EOF
    chmod 0644 "${AA_DATA}"
    rm -f "${AA_REPORT}"

    cat >"${AA_TOOL}" <<'EOF'
#!/bin/bash
# labreader — LPIC-3 333.2 lab tool. Deliberately confined by AppArmor.
# Three independent operations, each one mediated by a different rule type.
DATA=/srv/labdata/inventory.csv
REPORT=/var/log/labreader.report
rc=0

echo "== labreader =="
printf 'confinement: %s\n' "$(cat /proc/self/attr/current 2>/dev/null || echo '(cannot read /proc/self/attr/current)')"

echo "-- step 1: read the data file (open for read)"
if body="$(cat "$DATA" 2>&1)"; then
    echo "   OK   header: ${body%%$'\n'*}"
else
    echo "   FAIL $body"; rc=1
fi

echo "-- step 2: count records (execute a helper binary)"
if n="$(wc -l < "$DATA" 2>&1)"; then
    echo "   OK   $n lines"
else
    echo "   FAIL $n"; rc=1
fi

echo "-- step 3: write the report (open for write/create)"
if printf 'LPIC3-333.2 labreader report\ngenerated by: %s\n' "$0" >"$REPORT" 2>/tmp/labreader.err; then
    echo "   OK   wrote $REPORT"
else
    echo "   FAIL $(cat /tmp/labreader.err 2>/dev/null)"; rc=1
fi

echo "== exit ${rc} =="
exit "$rc"
EOF
    chmod 0755 "${AA_TOOL}"
}

aa_write_broken_profile() {
    local includes="" a
    for a in base bash consoles nameservice; do
        [[ -f "/etc/apparmor.d/abstractions/${a}" ]] && includes+="  #include <abstractions/${a}>"$'\n'
    done
    local tunables=""
    [[ -f /etc/apparmor.d/tunables/global ]] && tunables="#include <tunables/global>"

    cat >"${AA_PROFILE}" <<EOF
# ${MARK} lab profile — generated by break-fix-333.2-mac.sh
# THIS PROFILE IS DELIBERATELY WRONG IN THREE DIFFERENT WAYS.
${tunables}

${AA_TOOL} {
${includes}
  ${AA_TOOL} r,

  /{,usr/}bin/bash   mrix,
  /{,usr/}bin/cat    mrix,
  /{,usr/}bin/id     mrix,
  /{,usr/}bin/date   mrix,
  /{,usr/}bin/uname  mrix,

  /srv/labdata/ r,

  /var/log/labreader.report w,
  deny /var/log/labreader.report w,

  /tmp/labreader.err w,
  owner @{PROC}/@{pid}/attr/current r,
}
EOF
    # @{PROC}/@{pid} only exist when tunables/global was included.
    if [[ -z "${tunables}" ]]; then
        sed -i 's#^  owner @{PROC}.*#  owner /proc/*/attr/current r,#' "${AA_PROFILE}"
    fi
    apparmor_parser -r -W "${AA_PROFILE}" 2>/dev/null || apparmor_parser -r "${AA_PROFILE}"
}

aa_break() {
    aa_require_tools
    aa_write_tool
    head1 "ARMING THE APPARMOR BREAKAGE"
    log "break 1/3: no read rule covering ${AA_DATA}"
    log "break 2/3: an explicit 'deny' rule on ${AA_REPORT}"
    log "break 3/3: no exec rule for the helper binary the tool calls"
    aa_write_broken_profile
    log "profile loaded in mode: $(aa_profile_mode)"

    save_state \
        "LAB_TRACK=apparmor" \
        "LAB_BROKEN_AT=$(date -Is)"

    aa_brief
}

aa_brief() {
    head1 "TOPIC 333.2 — APPARMOR BREAK & FIX BRIEFING"
    cat <<EOF
SCENARIO
  ${AA_TOOL} is a small tool that (1) reads ${AA_DATA},
  (2) counts its records with an external helper, and (3) writes a report to
  ${AA_REPORT}. It is confined by the profile
  ${AA_PROFILE}, currently in ENFORCE mode.

  Run it now:      sudo ${AA_TOOL}

SYMPTOMS YOU WILL SEE
  All three steps report "Permission denied" — as root, on a world-readable file
  (0644), with the destination directory writable. Nothing in ls -l explains it.
  The kernel is refusing operations that DAC would allow, and it is logging one
  audit record per refusal with apparmor="DENIED".

WHAT YOU MUST ACHIEVE
  'sudo ${AA_TOOL}' exits 0 with all three steps OK, while the profile stays
  LOADED and in ENFORCE mode. Widening the profile is the job; removing it is not.

FORBIDDEN (scored as zero by 'verify')
  aa-complain · aa-disable · apparmor_parser -R · aa-teardown ·
  systemctl stop apparmor · deleting the profile · chmod on the data.

THE TRAP
  One of the three failures cannot be fixed by adding a rule, and aa-logprof will
  never propose the fix for it. AppArmor evaluates deny rules with priority over
  allow rules: a 'deny' subtracts permission permanently, no matter how many allow
  rules you stack after it. Read the profile with that in mind.

TOOLBOX
  aa-status                                  which profiles, which mode
  dmesg -T | grep -i apparmor                the DENIED records (fastest path)
  journalctl -k --since '-5 min' | grep DENIED
  ausearch -m AVC -ts recent                 same records, if auditd is running
  aa-logprof                                 interactive: replay denials, patch profile
  aa-complain / aa-enforce                   flip a profile's mode (diagnosis only!)
  apparmor_parser -r ${AA_PROFILE}           reload after editing
  apparmor_parser -Q -d ${AA_PROFILE}        parse/debug without loading
  man 5 apparmor.d                           the rule syntax, including deny and ix/Px/Cx/ux

  Read the fields in a DENIED line, they are a checklist:
      operation=   what was attempted (open / exec / mknod / capable / file_lock)
      profile=     which profile refused it
      name=        the object
      requested_mask= / denied_mask=   which permission letters were missing
      comm=        which binary was running when it happened

  When you think you are done:   sudo $0 verify
  Stuck for more than 20 min:    sudo $0 hint
EOF
    hr
}

aa_verify() {
    aa_require_tools
    PASS=0; FAILED=0
    head1 "SCORING — APPARMOR TRACK"

    check_eq "profile ${AA_TOOL} is loaded and in enforce mode" "enforce" "$(aa_profile_mode)"
    check "profile file still exists on disk" test -f "${AA_PROFILE}"
    check "AppArmor LSM still enabled" bash -c '[[ "$(cat /sys/module/apparmor/parameters/enabled)" == "Y" ]]'
    check "the tool was not simply moved out of confinement" test -x "${AA_TOOL}"
    check "the data file was not chmod-ed into oblivion" \
          bash -c "[[ \"\$(stat -c %a ${AA_DATA})\" == 644 ]]"

    log "running the confined tool ..."
    rm -f "${AA_REPORT}"
    local out rc=0
    out="$("${AA_TOOL}" 2>&1)" || rc=$?
    printf '%s\n' "${out}" | sed 's/^/       /'

    check_eq "${AA_TOOL} exits 0 under enforcement" "0" "${rc}"
    check "report file was created" test -s "${AA_REPORT}"
    check "report contains the lab marker" grep -q "${MARK}" "${AA_REPORT}"

    hr
    local denials
    denials="$(dmesg 2>/dev/null | grep -c "apparmor=\"DENIED\".*${AA_TOOL}" || true)"
    [[ -n "${denials}" && "${denials}" != "0" ]] && \
        warn "${denials} historical DENIED record(s) for this profile in dmesg (old ones are expected; check timestamps with dmesg -T)"

    if [[ ${FAILED} -eq 0 ]]; then
        ok "${PASS}/${PASS} checks passed. Fixed, with the profile still enforcing."
        ok "Extra credit: 'apparmor_parser -Q -d ${AA_PROFILE}' and read your own rules back."
        ok "Clean the VM when you are done:  sudo $0 restore"
    else
        err "${FAILED} check(s) failing, ${PASS} passing. Keep going — 'sudo $0 hint'."
    fi
}

aa_hint() {
    head1 "HINTS — APPARMOR TRACK (no answers, just the right tool)"
    cat <<EOF
0. Get the evidence first. Every refusal produced exactly one kernel audit line:
       dmesg -T | grep -i 'apparmor="DENIED"' | tail -20
   Do not guess from the tool's own error messages; read operation=, name= and
   denied_mask= from the kernel. Three distinct records, three distinct fixes.

1. operation="open" ... denied_mask="r"
   The profile grants read on the DIRECTORY, not on what is inside it. AppArmor
   paths are literal: '/srv/labdata/ r,' and '/srv/labdata/** r,' are different
   statements. man 5 apparmor.d, section on globbing: * does not cross /, ** does.

2. operation="exec" ... denied_mask="x"
   A confined process cannot execute anything the profile did not name. The
   profile lists a handful of helpers; the tool calls one that is missing. When
   you add it, you also choose what happens to the CHILD's confinement:
       ix  inherit this profile        Px  transition to the child's own profile
       Cx  transition to a child profile defined inside this one
       ux  run unconfined (audited: Ux/ux are the ones that end up in postmortems)
   Pick the one that keeps the helper as confined as its parent.

3. operation="open" ... denied_mask="w" — and the profile ALREADY has a w rule
   Stop adding rules and start deleting one. In AppArmor, deny is not "the
   absence of allow": it is a separate mask subtracted after the union of all
   allow rules, including the ones pulled in by #include. This is precisely why
   aa-logprof cannot help you here — it only ever proposes additions.
   Grep your profile for 'deny'.

4. Reload, do not restart. 'apparmor_parser -r <file>' replaces the loaded
   profile atomically for new AND running processes. 'systemctl reload apparmor'
   reloads everything in /etc/apparmor.d. Neither one needs a reboot.

5. Legitimate diagnostic workflow, if you want to see how it is done in the field:
       aa-complain ${AA_TOOL}     # log-only, nothing is blocked
       ${AA_TOOL}                 # exercise every code path
       aa-logprof                 # replay the log, accept the proposed rules
       aa-enforce ${AA_TOOL}      # back to enforcing — do not forget this step
   'verify' requires the profile to end in enforce mode, so complain mode is a
   step in the middle, never the destination.
EOF
    hr
}

aa_restore() {
    head1 "RESTORING — APPARMOR TRACK"
    apparmor_parser -R "${AA_PROFILE}" >/dev/null 2>&1 || true
    rm -f "${AA_PROFILE}" "${AA_TOOL}" "${AA_REPORT}" /tmp/labreader.err
    rm -rf "${AA_DATA_DIR}"
    ok "profile unloaded and removed, lab tool and data deleted."
}

#==============================================================================
#  DISPATCH
#==============================================================================

usage() {
    cat <<EOF
LPIC-3 303 · Topic 333.2 Mandatory Access Control — break & fix lab

  sudo $0 break      arm the lab (default) and print the briefing
  sudo $0 verify     score your fix
  sudo $0 hint       progressive hints, no answers
  sudo $0 brief      reprint the briefing
  sudo $0 restore    undo everything

  LAB_FORCE=yes      skip the disposable-VM confirmation
  LAB_MAC=selinux|apparmor   force a track (default: auto-detect)
EOF
}

main() {
    local cmd="${1:-break}"
    case "${cmd}" in
        -h|--help|help) usage; exit 0 ;;
    esac
    require_root "${cmd}"

    local mac
    mac="$(detect_mac)"
    load_state
    [[ -n "${LAB_TRACK:-}" && "${cmd}" != "break" ]] && mac="${LAB_TRACK}"

    if [[ "${mac}" == "none" ]]; then
        err "No active MAC framework found on this system."
        err "  SELinux:  ls /sys/fs/selinux   (RHEL family — 'getenforce')"
        err "  AppArmor: cat /sys/module/apparmor/parameters/enabled  (Debian/SUSE family)"
        err "Boot with 'security=selinux selinux=1' or 'security=apparmor apparmor=1',"
        err "or force a track with LAB_MAC=selinux|apparmor."
        exit 1
    fi

    case "${cmd}" in
        break)
            confirm_disposable
            [[ "${mac}" == "selinux" ]] && se_break || aa_break
            ;;
        verify|check|score)
            [[ "${mac}" == "selinux" ]] && se_verify || aa_verify
            ;;
        hint|hints)
            [[ "${mac}" == "selinux" ]] && se_hint || aa_hint
            ;;
        brief|briefing)
            [[ "${mac}" == "selinux" ]] && se_brief || aa_brief
            ;;
        restore|clean|reset)
            [[ "${mac}" == "selinux" ]] && se_restore || aa_restore
            rm -f "${STATE}"
            ;;
        *)
            usage; exit 2 ;;
    esac
}

main "$@"

#===============================================================================
#
#   S O L U T I O N   —   D O   N O T   R E A D   U N T I L   Y O U   H A V E
#   S P E N T   R E A L   T I M E   I N   T H E   A U D I T   L O G
#
#===============================================================================
#
#-------------------------------------------------------------------------------
# SELINUX TRACK — step by step
#-------------------------------------------------------------------------------
#
# STEP 0 — Confirm the enforcement layer is the one refusing you, before you
#          change anything. This reflex separates a 20-minute fix from a 3-hour one.
#
#   $ sudo getenforce
#   Enforcing
#   $ sudo ausearch -m AVC,USER_AVC,SELINUX_ERR -ts recent | head
#   ----
#   time->Sun Aug 24 11:02:41 2026
#   type=AVC msg=audit(1756033361.412:233): avc:  denied  { name_bind } for
#     pid=2481 comm="httpd" src=8000
#     scontext=system_u:system_r:httpd_t:s0
#     tcontext=system_u:object_r:soundd_port_t:s0 tclass=tcp_socket permissive=0
#
#   Read it as a sentence: the subject httpd_t asked for name_bind on an object
#   labelled soundd_port_t and the policy has no allow rule for that pair.
#   permissive=0 means the operation was actually blocked (permissive=1 would
#   mean "logged only"). If auditd is not running, the same records are in
#   'journalctl -k | grep avc' / 'dmesg | grep avc'.
#
# STEP 1 — The port. Ports are labelled objects, exactly like files.
#
#   $ sudo semanage port -l | grep '^http_port_t'
#   http_port_t    tcp   80, 81, 443, 488, 8008, 8009, 8443, 9000
#
#   8000 is absent — in the shipped targeted policy it belongs to soundd_port_t.
#   Add it to the http type (this writes to the local policy store under
#   /etc/selinux/targeted/, so it survives reboots and package updates):
#
#   $ sudo semanage port -a -t http_port_t -p tcp 8000
#   $ sudo semanage port -l | grep '^http_port_t'
#   http_port_t    tcp   8000, 80, 81, 443, 488, 8008, 8009, 8443, 9000
#
#   -a add, -m modify (use -m when the port already has a type you want to
#   change), -d delete, -l list. 'semanage port -l -C' lists ONLY local changes,
#   which is how you audit what a previous admin did to a box.
#
#   $ sudo systemctl restart httpd && ss -lntp | grep 8000
#   LISTEN 0 511 *:8000 *:* users:(("httpd",pid=2530,fd=4),...)
#
# STEP 2 — The docroot: a label that DRIFTED from its correct default.
#
#   $ ls -Zd /var/www/html /var/www/html/index.html
#   unconfined_u:object_r:user_home_t:s0 /var/www/html
#   unconfined_u:object_r:user_home_t:s0 /var/www/html/index.html
#   $ matchpathcon /var/www/html
#   /var/www/html has context unconfined_u:object_r:user_home_t:s0, should be
#   system_u:object_r:httpd_sys_content_t:s0
#
#   This is the signature of content copied (cp, not mv... actually the reverse:
#   'mv' PRESERVES the source label, 'cp' inherits the destination's — 'mv' from
#   a home directory is the usual culprit, and so is untarring an archive built
#   with --selinux). The policy already knows the right answer for this path, so
#   just apply it:
#
#   $ sudo restorecon -Rv /var/www/html
#   Relabeled /var/www/html from unconfined_u:object_r:user_home_t:s0 to
#     system_u:object_r:httpd_sys_content_t:s0
#   Relabeled /var/www/html/index.html from ... to ...:httpd_sys_content_t:s0
#
#   $ curl -sI http://127.0.0.1:8000/ | head -1
#   HTTP/1.1 200 OK
#
#   Note what you did NOT do: 'chcon -t httpd_sys_content_t' would also have
#   worked and would also have been wrong, because it writes only the inode and
#   teaches the policy nothing. Here the policy already had the right rule.
#
# STEP 3 — /srv/webdata: a path the policy has NEVER heard of.
#
#   $ ls -Zd /srv/webdata
#   system_u:object_r:var_t:s0 /srv/webdata
#   $ sudo ausearch -m AVC -ts recent | audit2allow -w
#   type=AVC msg=audit(...): avc: denied { getattr } for pid=2531 comm="httpd"
#     path="/srv/webdata/report.html" ... tcontext=...:var_t:s0 tclass=file
#     Was caused by:
#     Missing type enforcement (TE) allow rule.
#
#   Here 'restorecon' would be useless — the default for /srv IS var_t, so
#   restorecon would happily "restore" it to the wrong thing. You must first add
#   the rule to the file-context database, THEN apply it:
#
#   $ sudo semanage fcontext -a -t httpd_sys_content_t '/srv/webdata(/.*)?'
#   $ sudo semanage fcontext -l -C
#   SELinux fcontext        type      Context
#   /srv/webdata(/.*)?      all files system_u:object_r:httpd_sys_content_t:s0
#   $ sudo restorecon -Rv /srv/webdata
#   Relabeled /srv/webdata from system_u:object_r:var_t:s0 to
#     system_u:object_r:httpd_sys_content_t:s0
#   Relabeled /srv/webdata/report.html from ... to ...
#
#   $ curl -sI http://127.0.0.1:8000/data/report.html | head -1
#   HTTP/1.1 200 OK
#
#   The regex is a POSIX ERE anchored implicitly at both ends: '(/.*)?' means
#   "the directory itself, and everything under it". Quote it, or the shell
#   eats the parentheses. Useful variants:
#     -f  restrict to a file type (-f -d directories, -f -- regular files...)
#     -e  make one path an equivalency of another (the right tool when you move
#         a whole docroot: 'semanage fcontext -a -e /var/www /srv/www')
#   THIS is the answer to "why did my site break after a reboot?": someone used
#   chcon, and /.autorelabel, 'fixfiles -F relabel', or a policy update wiped it.
#   The persistence check in 'verify' exists to make you feel that difference.
#
# STEP 4 — The boolean. Never write a policy module for something a tunable
#          already covers.
#
#   $ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/cgi-bin/probe.cgi
#   500
#   $ sudo tail -2 /var/log/httpd/error_log
#   (13)Permission denied: AH01241: exec of '/var/www/cgi-bin/probe.cgi' failed
#   End of script output before headers: probe.cgi
#
#   $ sudo ausearch -m AVC -ts recent | audit2why
#   type=AVC msg=audit(...): avc: denied { execute } for pid=2570 comm="httpd"
#     name="probe.cgi" scontext=system_u:system_r:httpd_t:s0
#     tcontext=system_u:object_r:httpd_sys_script_exec_t:s0 tclass=file
#     Was caused by:
#     One of the following booleans was set incorrectly.
#     Description: Allow httpd to enable cgi
#     Allow access by executing: # setsebool -P httpd_enable_cgi 1
#
#   $ sudo setsebool -P httpd_enable_cgi on
#   $ getsebool httpd_enable_cgi
#   httpd_enable_cgi --> on
#   $ sudo semanage boolean -l -C
#   SELinux boolean     State  Default  Description
#   httpd_enable_cgi    (on   ,   on)   Allow httpd to enable cgi
#
#   -P is the whole point: without it the change lives in kernel memory only and
#   dies at the next boot (that is 'setsebool bool on' vs 'setsebool -P bool on',
#   and the two values in the parentheses above are current,persisted).
#   'semanage boolean -l -C' is how you review every tunable a previous admin
#   flipped on a machine you inherited. 'man httpd_selinux' documents the whole
#   httpd set; every confined service ships an equivalent man page
#   (man -k _selinux) generated by sepolicy manpage.
#
#   $ curl -s http://127.0.0.1:8000/cgi-bin/probe.cgi
#   LPIC3-333.2 CGI-OK
#   running as domain: system_u:system_r:httpd_sys_script_t:s0
#
#   That last line is worth ten minutes of study: the CGI did not run as httpd_t.
#   Executing a file labelled httpd_sys_script_exec_t caused a DOMAIN TRANSITION
#   into httpd_sys_script_t, which has far fewer privileges than its parent.
#   Type Enforcement is the whole model: subject type + object type + class ->
#   allowed permissions, plus type_transition rules that move a process between
#   domains at exec time. See 'sesearch -T -s httpd_t' to list those transitions.
#
# STEP 5 — Prove it survives, the way the exam and production both demand:
#
#   $ sudo touch /.autorelabel && sudo reboot     # full relabel from file_contexts
#   ... after boot ...
#   $ sudo /path/to/break-fix-333.2-mac.sh verify
#
# WHAT IF NOTHING ABOVE APPLIES? (the escalation ladder, in order)
#   1. boolean            setsebool -P ...
#   2. file context       semanage fcontext -a ... ; restorecon -Rv
#   3. port / interface / node label     semanage port|interface|node
#   4. login/user mapping semanage login -a -s staff_u -r 's0-s0:c0.c1023' bob
#   5. custom module      LAST resort, and never blindly:
#        $ sudo ausearch -m AVC -ts recent | audit2allow -M mylocalpolicy
#        $ cat mylocalpolicy.te        # <-- READ IT. Every single time.
#        $ sudo semodule -i mylocalpolicy.pp
#        $ sudo semodule -lfull | grep mylocal      # 400 mylocalpolicy pp
#      audit2allow will happily generate 'allow httpd_t shadow_t:file read;' if
#      that is what the log contains. It is a transcription tool, not an advisor.
#      Remove with 'semodule -r mylocalpolicy'.
#   Diagnostics-only, never a fix: 'semanage permissive -a httpd_t' makes ONE
#   domain permissive while the rest of the system stays enforcing — far better
#   than 'setenforce 0' when you must collect denials on a live box.
#   Undo it with 'semanage permissive -d httpd_t'.
#
#
#-------------------------------------------------------------------------------
# APPARMOR TRACK — step by step
#-------------------------------------------------------------------------------
#
# STEP 0 — Establish that AppArmor is the one saying no.
#
#   $ sudo aa-status
#   apparmor module is loaded.
#   42 profiles are loaded.
#   38 profiles are in enforce mode.
#      /usr/local/bin/labreader
#      /usr/sbin/cups-browsed
#      ...
#   4 profiles are in complain mode.
#   3 processes have profiles defined.
#
#   $ sudo dmesg -T | grep 'apparmor="DENIED"' | tail -3
#   [Sun Aug 24 11:41:07 2026] audit: type=1400 audit(1756035667.113:88):
#     apparmor="DENIED" operation="open" profile="/usr/local/bin/labreader"
#     name="/srv/labdata/inventory.csv" pid=4120 comm="cat"
#     requested_mask="r" denied_mask="r" fsuid=0 ouid=0
#   [Sun Aug 24 11:41:07 2026] ... apparmor="DENIED" operation="exec"
#     profile="/usr/local/bin/labreader" name="/usr/bin/wc" pid=4121 comm="bash"
#     requested_mask="x" denied_mask="x" fsuid=0 ouid=0
#   [Sun Aug 24 11:41:07 2026] ... apparmor="DENIED" operation="open"
#     profile="/usr/local/bin/labreader" name="/var/log/labreader.report"
#     pid=4122 comm="bash" requested_mask="wc" denied_mask="wc" fsuid=0 ouid=0
#
#   Three records, three different operations. fsuid=0 in every one: this is root
#   being refused, which is the entire point of Mandatory Access Control —
#   the policy is not negotiable by the object's owner, unlike DAC's mode bits.
#
# STEP 1 — Fix the read: path globbing, not directory permission.
#
#   The profile has '/srv/labdata/ r,' — that grants read on the directory inode
#   itself (listing it), and nothing else. AppArmor rules match PATHS literally:
#     /srv/labdata/       the directory
#     /srv/labdata/*      files directly inside it        (* does not cross '/')
#     /srv/labdata/**     everything below, recursively
#   Edit /etc/apparmor.d/usr.local.bin.labreader:
#
#       /srv/labdata/ r,
#       /srv/labdata/** r,          # <-- add this
#
#   Permission letters you must know cold (apparmor.d(5)):
#     r read · w write · a append · l link · k lock · m mmap PROT_EXEC
#     x execute, always qualified by a transition modifier:
#        ix inherit current profile · Px transition to the target's own profile
#        (Pix = try Px, fall back to ix) · Cx child profile defined inline
#        ux unconfined (uppercase U/P/C = scrub the environment first: recommended)
#
# STEP 2 — Fix the exec: name the helper AND choose its confinement.
#
#       /{,usr/}bin/wc mrix,        # <-- add this
#
#   'm' is there because the loader mmaps the binary with PROT_EXEC; forgetting
#   it produces a second, confusing denial with denied_mask="m". The '{,usr/}'
#   brace expansion covers both /bin and /usr/bin on merged-usr and non-merged
#   systems in one rule. 'ix' keeps wc inside labreader's profile — the least
#   privilege choice here. 'Px' would send it to a wc-specific profile (there is
#   none, and the exec would then be refused); 'ux' would run it unconfined and
#   punch a hole straight through your policy.
#
# STEP 3 — Fix the write: DELETE the deny rule. This is the trap.
#
#       /var/log/labreader.report w,
#       deny /var/log/labreader.report w,     # <-- DELETE THIS LINE
#
#   AppArmor computes the allow mask as the union of every allow rule (including
#   everything pulled in by #include), then SUBTRACTS the deny mask. Order in the
#   file is irrelevant; deny always wins. Consequences worth internalising:
#     - Adding allow rules can never override a deny. Not even in a later include.
#     - aa-logprof only ever PROPOSES ALLOW RULES, so it cannot fix a deny; you
#       will sit there accepting suggestions and the denial will keep happening.
#     - Deny rules are the correct tool when you include a broad abstraction and
#       need to carve one object back out (e.g. '#include <abstractions/base>'
#       plus 'deny /etc/shadow rwklx,'). By default a deny is also silent —
#       'audit deny ...' makes it log.
#
# STEP 4 — Reload and re-test. No reboot, no service restart.
#
#   $ sudo apparmor_parser -r /etc/apparmor.d/usr.local.bin.labreader
#   $ sudo /usr/local/bin/labreader
#   == labreader ==
#   confinement: /usr/local/bin/labreader (enforce)
#   -- step 1: read the data file (open for read)
#      OK   header: sku,description,qty
#   -- step 2: count records (execute a helper binary)
#      OK   4 lines
#   -- step 3: write the report (open for write/create)
#      OK   wrote /var/log/labreader.report
#   == exit 0 ==
#
#   apparmor_parser flags worth memorising:
#     -a add (fails if loaded) · -r replace (idempotent — use this) · -R remove
#     -Q dry-run parse, no load  · -d debug: dump the parsed rules
#     -T/-W skip/write the binary cache under /var/cache/apparmor
#   'systemctl reload apparmor' reloads every profile in /etc/apparmor.d.
#
# STEP 5 — The workflow you will actually use on a machine you did not build:
#
#   $ sudo aa-genprof /usr/local/bin/labreader   # profile from scratch, interactively
#   $ sudo aa-autodep /usr/local/bin/labreader   # skeleton profile, complain mode
#   $ sudo aa-complain /usr/local/bin/labreader  # log only, block nothing
#   ... exercise every code path of the program, including error paths ...
#   $ sudo aa-logprof                            # replay the log, patch the profile
#   $ sudo aa-enforce /usr/local/bin/labreader   # and back to enforcing
#   $ sudo aa-cleanprof /usr/local/bin/labreader # tidy redundant rules
#   Distribution convention: never edit a shipped profile in place — drop your
#   additions into /etc/apparmor.d/local/<profile-name>, which stock profiles
#   already pull in with '#include <local/usr.sbin.foo>'. That keeps package
#   upgrades from stomping your changes.
#
#
#-------------------------------------------------------------------------------
# APPENDIX A — SELinux vs AppArmor, the comparison the exam expects
#-------------------------------------------------------------------------------
#   Model            SELinux: label-based (every subject and object carries a
#                    security context user:role:type:level; access is decided by
#                    type enforcement plus RBAC and optional MLS/MCS).
#                    AppArmor: path-based (rules name filesystem paths; there are
#                    no labels on inodes at all).
#   Consequence      A hard link or a bind mount gives an object a SECOND path,
#                    and AppArmor mediates each path separately; SELinux follows
#                    the inode's label wherever it is reached from. Conversely,
#                    restoring a backup without labels breaks SELinux and does
#                    nothing to AppArmor.
#   Storage          SELinux labels live in the security.selinux extended
#                    attribute (getfattr -n security.selinux -m . FILE);
#                    AppArmor profiles live in /etc/apparmor.d as text.
#   Granularity      SELinux confines everything by default in the 'strict'
#                    policy; the shipped 'targeted' policy confines listed
#                    daemons and leaves user sessions in unconfined_t.
#                    AppArmor confines only what has a profile — no profile
#                    means no confinement, silently.
#   Runtime control  setenforce 0|1, /etc/selinux/config, per-domain permissive
#                    vs aa-complain/aa-enforce per profile.
#   Interfaces       /sys/fs/selinux · /etc/selinux/{config,targeted/}
#                    /sys/kernel/security/apparmor/{profiles,policy} · /etc/apparmor.d
#   Both are LSMs. Since Linux 5.1 several LSMs can stack, but SELinux and
#   AppArmor are still mutually exclusive as the "major" LSM: one machine, one
#   of the two. Check what is active with:
#       $ cat /sys/kernel/security/lsm
#       lockdown,capability,landlock,yama,apparmor,bpf
#
#-------------------------------------------------------------------------------
# APPENDIX B — Smack (Simplified Mandatory Access Control Kernel)
#-------------------------------------------------------------------------------
#   Also listed in objective 333.2. Practically absent from general-purpose
#   distributions (its home turf is Tizen, AGL and embedded), so this lab does
#   not break it — but you are expected to recognise the mechanics:
#
#     Model     every subject and object carries a single text LABEL (up to 255
#               chars). Access is allowed if a rule "subject-label object-label
#               access" exists, or if one of the built-in floating labels applies.
#     Storage   security.SMACK64 xattr (plus SMACK64EXEC, SMACK64MMAP,
#               SMACK64TRANSMUTE, SMACK64IPIN / SMACK64IPOUT for network).
#     Built-in labels
#         _  ("floor")     readable by everybody, writable only by ^
#         ^  ("hat")       may read everything, written by nobody
#         *  ("star")      accessible by everybody — the trash label
#         ?  ("huh")       read/write by ^, otherwise nothing
#         @  ("web")       network label with no access checks
#     Interfaces  /sys/fs/smackfs/{load2,access2,cipso2,netlabel,onlycap,ambient}
#     Tools       chsmack (show/set labels), smackctl / smackload (apply rules
#                 from /etc/smack/accesses.d/), smackaccess (test one rule)
#     Rule syntax written into /sys/fs/smackfs/load2:
#         subject_label object_label rwxatl      (- for a permission not granted)
#         e.g.   Alice   Bob   rw-
#     Quick recognition commands:
#         $ mount | grep smackfs
#         $ chsmack /etc/passwd
#         /etc/passwd access="_"
#         $ chsmack -a MyLabel /srv/data/file
#         $ echo -n 'Web Store rw--' | sudo tee /sys/fs/smackfs/load2
#     Enable with 'security=smack' on the kernel command line; like SELinux and
#     AppArmor it is the major LSM, so it excludes the other two.
#     Reference: https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
#
#===============================================================================
# End of lab. Clean up with:  sudo ./break-fix-333.2-mac.sh restore
#===============================================================================