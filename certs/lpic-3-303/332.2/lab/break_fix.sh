#!/usr/bin/env bash
# =============================================================================
#  LPIC-3 303-300 (Security, v3.0.0)  --  Topic 332.2: Host Intrusion Detection
#  Lab exercise: BREAK & FIX  --  "The sensors went dark"
# =============================================================================
#
#  Objective coverage (https://www.lpi.org/our-certifications/exam-303-objectives/):
#    - Linux Audit system: auditd, auditctl, ausearch, aureport, auditd.conf,
#      audit.rules, augenrules
#    - AIDE, including rule management: aide, aide.conf, database_in/database_out
#    - rkhunter, including updates: /etc/rkhunter.conf, --propupd, --config-check
#    - chkrootkit
#
#  Scenario
#  --------
#  A simulated intruder did what a competent intruder always does FIRST: it
#  blinded the host IDS stack, and only then installed persistence. Three
#  sensors were sabotaged (auditd, AIDE, rkhunter) and four artifacts were
#  planted. Your job is to restore the sensors from a known-good offline
#  baseline and then USE them to enumerate the damage.
#
#  The single most important lesson of this lab: after a suspected compromise
#  you NEVER re-baseline (`aide --init`, `rkhunter --propupd`) before you have
#  triaged the host. Re-baselining a compromised host promotes the intruder's
#  files to "known good" and destroys the only evidence you had.
#
#  !! DESTRUCTIVE !!
#  This script rewrites /etc/audit/*, /etc/rkhunter.conf, creates a system
#  account, a cron file and files under /usr/local/sbin and /dev. Run it ONLY
#  on a disposable lab VM you can throw away or snapshot-revert. It refuses to
#  run without an explicit confirmation.
#
#  Nothing planted here is dangerous: the fake daemon is an inert shell script
#  that only appends a timestamp to a log, the planted account is a locked
#  nologin system account with no privileges, and no SUID binary is created.
#  Every injected fault is reversible with:  sudo "$0" --restore
#
#  Usage:
#    sudo ./lab332-2-host-ids-breakfix.sh --break [--yes] [--no-install]
#    sudo ./lab332-2-host-ids-breakfix.sh --verify
#    sudo ./lab332-2-host-ids-breakfix.sh --restore
#
#  References:
#    AIDE            https://aide.github.io/
#    rkhunter        https://rkhunter.sourceforge.net/
#    chkrootkit      http://www.chkrootkit.org/
#    Linux audit     https://github.com/linux-audit/audit-userspace
#    man pages       auditctl(8) auditd.conf(5) audit.rules(7) ausearch(8)
#                    aureport(8) augenrules(8) aide(1) aide.conf(5) rkhunter(8)
# =============================================================================

set -euo pipefail

# ------------------------------- constants -----------------------------------
LAB_ID="lab332"
STATE_DIR="/var/lib/${LAB_ID}-breakfix"          # lab bookkeeping (not watched)
BACKUP_DIR="${STATE_DIR}/offline-baseline"       # student-visible "offsite" copy
RESTORE_DIR="${STATE_DIR}/.instructor-restore"   # pristine configs for --restore
BRIEFING="${STATE_DIR}/BRIEFING.txt"
BROKEN_AT="${STATE_DIR}/broken_at"

AIDE_CONF="/etc/aide/${LAB_ID}.conf"
AIDE_DB="/var/lib/aide/${LAB_ID}.db"
AIDE_DB_NEW="/var/lib/aide/${LAB_ID}.db.new"

AUDITD_CONF="/etc/audit/auditd.conf"
AUDIT_RULES_D="/etc/audit/rules.d"
RK_CONF="/etc/rkhunter.conf"
RK_DB_DIR="/var/lib/rkhunter/db"

FAKE_BIN="/usr/local/sbin/systemd-netlogd"       # masquerading "daemon"
HIDDEN_DIR="/dev/.${LAB_ID}-cache"               # hidden dir under /dev
CRON_FILE="/etc/cron.d/${LAB_ID}-beacon"         # cron persistence
LAB_USER="svc-telemetry"                         # planted (locked) account
BEACON_LOG="/var/log/${LAB_ID}-beacon.log"
VERIFIER="/usr/local/bin/${LAB_ID}-verify"

HAVE_AUDIT=0; HAVE_AIDE=0; HAVE_RKHUNTER=0; HAVE_CHKROOTKIT=0
ACTION="break"; ASSUME_YES=0; DO_INSTALL=1
PM=""; OS_ID=""

# ------------------------------- helpers -------------------------------------
c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'
c_blu=$'\033[1;34m'; c_off=$'\033[0m'

info() { printf '%s[*]%s %s\n' "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "This lab must run as root (sudo $0 $*)."; }

detect_os() {
    # shellcheck disable=SC1091
    [ -r /etc/os-release ] && . /etc/os-release && OS_ID="${ID:-unknown}"
    if   command -v apt-get >/dev/null 2>&1; then PM="apt"
    elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
    elif command -v yum     >/dev/null 2>&1; then PM="yum"
    elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
    else PM=""
    fi
}

pkg_install() {
    local pkgs=("$@")
    [ "$DO_INSTALL" -eq 1 ] || { warn "--no-install: skipping ${pkgs[*]}"; return 1; }
    case "$PM" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
        dnf)    dnf install -y "${pkgs[@]}" ;;
        yum)    yum install -y "${pkgs[@]}" ;;
        zypper) zypper --non-interactive install "${pkgs[@]}" ;;
        *)      return 1 ;;
    esac
}

confirm_disposable() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "${LAB332_I_UNDERSTAND:-}" = "yes" ] && return 0
    if [ ! -t 0 ]; then
        die "Refusing to run non-interactively without --yes or LAB332_I_UNDERSTAND=yes."
    fi
    cat <<EOF

${c_red}This script will deliberately sabotage the host IDS stack of THIS machine:
  * auditd will stop writing logs and will lose every rule
  * the AIDE lab configuration and its database will be broken
  * ${RK_CONF} will be tampered with and rkhunter's file-properties DB removed
  * four inert but suspicious artifacts will be planted

Only run this on a disposable lab VM (snapshot it first).${c_off}

Hostname : $(hostname)
OS       : ${OS_ID}

Type exactly: BREAK THIS LAB VM
EOF
    local answer=""
    read -r -p "> " answer
    [ "$answer" = "BREAK THIS LAB VM" ] || die "Not confirmed. Nothing was changed."
}

restart_auditd() {
    # RHEL refuses `systemctl restart auditd`; the SysV wrapper is the portable way.
    if service auditd restart >/dev/null 2>&1; then return 0; fi
    systemctl restart auditd >/dev/null 2>&1 && return 0
    systemctl restart audit  >/dev/null 2>&1 && return 0
    warn "Could not restart auditd; do it by hand: service auditd restart"
}

audit_log_path() {
    local p=""
    [ -r "$AUDITD_CONF" ] && p=$(awk -F= '/^[[:space:]]*log_file[[:space:]]*=/{gsub(/ /,"",$2);print $2}' "$AUDITD_CONF" | tail -n1)
    printf '%s\n' "${p:-/var/log/audit/audit.log}"
}

backup_file() {  # backup_file <path>  -> keeps a pristine copy for --restore
    local f="$1" dest="${RESTORE_DIR}${1}"
    [ -e "$f" ] || return 0
    mkdir -p "$(dirname "$dest")"
    [ -e "$dest" ] || cp -a "$f" "$dest"
}

set_kv() {       # set_kv <file> <key> <value>   (auditd.conf style: key = value)
    local f="$1" k="$2" v="$3"
    if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
        sed -i -E "s|^[[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|" "$f"
    else
        printf '%s = %s\n' "$k" "$v" >>"$f"
    fi
}

# ------------------------------ prerequisites --------------------------------
ensure_tools() {
    info "Checking prerequisites"
    local audit_pkg="auditd"
    case "$OS_ID" in
        rhel|centos|rocky|almalinux|fedora|opensuse*|sles) audit_pkg="audit" ;;
    esac

    command -v auditctl >/dev/null 2>&1 || pkg_install "$audit_pkg" || true
    command -v aide     >/dev/null 2>&1 || pkg_install aide          || true
    command -v rkhunter >/dev/null 2>&1 || pkg_install rkhunter      || true
    command -v chkrootkit >/dev/null 2>&1 || pkg_install chkrootkit  || true

    command -v auditctl   >/dev/null 2>&1 && HAVE_AUDIT=1
    command -v aide       >/dev/null 2>&1 && HAVE_AIDE=1
    command -v rkhunter   >/dev/null 2>&1 && HAVE_RKHUNTER=1
    command -v chkrootkit >/dev/null 2>&1 && HAVE_CHKROOTKIT=1

    [ "$HAVE_AUDIT" -eq 1 ]   || warn "auditd missing: the audit fault will be skipped."
    [ "$HAVE_AIDE" -eq 1 ]    || warn "aide missing: the AIDE fault will be skipped."
    [ "$HAVE_RKHUNTER" -eq 1 ]|| warn "rkhunter missing: the rkhunter fault will be skipped."
    [ "$HAVE_CHKROOTKIT" -eq 1 ] || warn "chkrootkit missing: the third-opinion step will be skipped."
    [ $((HAVE_AUDIT + HAVE_AIDE + HAVE_RKHUNTER)) -ge 1 ] || die "No IDS tooling available at all."
}

# --------------------------- AIDE lab configuration --------------------------
# A purpose-built ruleset instead of the distro-wide aide.conf: the exam asks
# for AIDE *rule management*, and a scoped config makes the lab run in seconds
# instead of minutes. In production you would extend the distro config instead.
write_aide_conf() {
    local ver newconf
    ver=$(aide --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -n1); ver="${ver:-0.16}"
    if [ "$(printf '%s\n0.17\n' "$ver" | sort -V | head -n1)" = "0.17" ]; then newconf=1; else newconf=0; fi
    info "AIDE ${ver} detected (config dialect: $([ "$newconf" -eq 1 ] && echo '>=0.17' || echo '0.16'))"

    mkdir -p /etc/aide /var/lib/aide
    {
        echo "# ${LAB_ID} - scoped AIDE policy for LPIC-3 303 topic 332.2"
        echo "# Docs: https://aide.github.io/  |  man 5 aide.conf"
        if [ "$newconf" -eq 1 ]; then
            echo "database_in=file:${AIDE_DB}"
            echo "database_out=file:${AIDE_DB_NEW}"
            echo "log_level=warning"
        else
            echo "database=file:${AIDE_DB}"
            echo "database_out=file:${AIDE_DB_NEW}"
            echo "verbose=5"
        fi
        cat <<'EOF'
gzip_dbout=no
report_url=stdout

# --- rule (attribute group) definitions -------------------------------------
# p permissions  i inode  n link count  u uid  g gid  s size  b block count
# m mtime        c ctime  sha256 content hash
LabBin  = p+i+n+u+g+s+b+m+c+sha256
LabConf = p+u+g+s+m+c+sha256
LabDir  = p+u+g

# --- selection lines ---------------------------------------------------------
EOF
        echo "/etc            LabConf"
        echo "/root           LabConf"
        echo "/usr/local      LabBin"
        echo "/usr/sbin       LabBin"
        echo "/dev            LabDir"
        cat <<'EOF'

# --- exclusions: volatile by design, not evidence ----------------------------
!/etc/mtab
!/etc/adjtime
!/etc/resolv.conf
!/etc/ld.so.cache
!/etc/blkid.tab
!/etc/lvm/archive
!/etc/lvm/backup
!/dev/pts
!/dev/shm
!/dev/mqueue
!/dev/hugepages
!/dev/core
EOF
    } >"$AIDE_CONF"
    chmod 0640 "$AIDE_CONF"
    backup_file "$AIDE_CONF"
}

baseline_aide() {
    [ "$HAVE_AIDE" -eq 1 ] || return 0
    write_aide_conf
    info "Initialising the AIDE baseline (this takes a moment)..."
    rm -f "$AIDE_DB" "$AIDE_DB_NEW"
    aide -c "$AIDE_CONF" --init >/dev/null 2>&1 || aide -c "$AIDE_CONF" --init || true
    [ -f "$AIDE_DB_NEW" ] || die "AIDE did not produce ${AIDE_DB_NEW}; check ${AIDE_CONF}."
    mv "$AIDE_DB_NEW" "$AIDE_DB"
    install -D -m 0400 "$AIDE_DB" "${BACKUP_DIR}/$(basename "$AIDE_DB")"
    ok "AIDE baseline stored, offline copy in ${BACKUP_DIR}/"
}

baseline_rkhunter() {
    [ "$HAVE_RKHUNTER" -eq 1 ] || return 0
    backup_file "$RK_CONF"
    info "Building the rkhunter file-properties baseline (--propupd)..."
    rkhunter --propupd --nocolors >/dev/null 2>&1 || warn "rkhunter --propupd returned non-zero"
    if [ -d "$RK_DB_DIR" ]; then
        mkdir -p "${BACKUP_DIR}/rkhunter-db"
        cp -a "${RK_DB_DIR}/." "${BACKUP_DIR}/rkhunter-db/" 2>/dev/null || true
        ok "rkhunter DB baseline copied to ${BACKUP_DIR}/rkhunter-db/"
    fi
}

# ------------------------------- the intrusion -------------------------------
plant_artifacts() {
    info "Planting the (inert) intrusion artifacts"

    # 1. A masquerading "daemon". Not SUID, no network, no privilege of any kind.
    cat >"$FAKE_BIN" <<EOF
#!/bin/sh
# ${LAB_ID} lab artifact - completely inert. It only timestamps a log file.
echo "\$(date -Is) beacon from \$(id -un)@\$(hostname)" >>"${BEACON_LOG}"
exit 0
EOF
    chmod 0755 "$FAKE_BIN"; chown root:root "$FAKE_BIN"

    # 2. Hidden directory under /dev - a classic rootkit hiding spot.
    mkdir -p "$HIDDEN_DIR"
    printf '%s\n' "${LAB_ID} staging area" >"${HIDDEN_DIR}/.stage"
    chmod 0700 "$HIDDEN_DIR"

    # 3. Cron persistence pointing at the fake daemon.
    cat >"$CRON_FILE" <<EOF
# ${LAB_ID} lab artifact
*/10 * * * * root ${FAKE_BIN}
EOF
    chmod 0644 "$CRON_FILE"

    # 4. A planted system account: locked, nologin, UID != 0. Safe by design.
    local nologin; nologin=$(command -v nologin || echo /usr/sbin/nologin)
    if ! id -u "$LAB_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell "$nologin" \
                --comment "${LAB_ID} planted account" "$LAB_USER"
        usermod -L "$LAB_USER" 2>/dev/null || true
    fi
    ok "Artifacts planted: ${FAKE_BIN}, ${HIDDEN_DIR}, ${CRON_FILE}, user ${LAB_USER}"
}

break_audit() {
    [ "$HAVE_AUDIT" -eq 1 ] || return 0
    info "FAULT 1: blinding the Linux Audit system"
    backup_file "$AUDITD_CONF"
    mkdir -p "${RESTORE_DIR}${AUDIT_RULES_D}"
    if [ -d "$AUDIT_RULES_D" ]; then
        cp -a "${AUDIT_RULES_D}/." "${RESTORE_DIR}${AUDIT_RULES_D}/" 2>/dev/null || true
        rm -f "${AUDIT_RULES_D}"/*.rules
    else
        mkdir -p "$AUDIT_RULES_D"
    fi

    # (a) the daemon runs but writes nothing
    set_kv "$AUDITD_CONF" "write_logs" "no"

    # (b) the only remaining ruleset does not compile
    cat >"${AUDIT_RULES_D}/99-${LAB_ID}.rules" <<'EOF'
## maintenance ruleset - do not edit
-D
-b 8192
-w /etc/passwd -p wq -k identity
-a always,exit -F arch=b64 -S execv -k persistence
EOF
    chmod 0640 "${AUDIT_RULES_D}/99-${LAB_ID}.rules"

    auditctl -D >/dev/null 2>&1 || true
    restart_auditd
    ok "auditd sabotaged (write_logs=no, rules.d wiped, one non-compiling ruleset left)"
}

break_aide() {
    [ "$HAVE_AIDE" -eq 1 ] || return 0
    info "FAULT 2: sabotaging AIDE"
    # (a) unknown attribute in a rule definition -> config parse error
    sed -i 's/^LabBin  = .*/LabBin  = p+i+n+u+g+s+b+m+c+sha257/' "$AIDE_CONF"
    # (b) the on-host database is destroyed; only the offline copy survives
    rm -f "$AIDE_DB" "$AIDE_DB_NEW"
    ok "AIDE sabotaged (bad rule attribute + on-host database deleted)"
}

break_rkhunter() {
    [ "$HAVE_RKHUNTER" -eq 1 ] || return 0
    info "FAULT 3: sabotaging rkhunter"
    cat >>"$RK_CONF" <<EOF

# --- added by the "maintenance" job -----------------------------------------
SCRIPTWHITELIST=/usr/bin/${LAB_ID}-nonexistent-helper
DISABLE_TESTS=properties filesystem hidden_procs
ALLOWHIDDENDIR=${HIDDEN_DIR}
EOF
    rm -f "${RK_DB_DIR}/rkhunter.dat"
    ok "rkhunter sabotaged (invalid whitelist, tests disabled, hiding place whitelisted, DB removed)"
}

# ------------------------------- the verifier --------------------------------
write_verifier() {
    cat >"$VERIFIER" <<'VEOF'
#!/usr/bin/env bash
# lab332-verify - checks whether the student has restored the IDS stack.
LAB_ID="lab332"
STATE_DIR="/var/lib/${LAB_ID}-breakfix"
BROKEN_AT="${STATE_DIR}/broken_at"
AIDE_CONF="/etc/aide/${LAB_ID}.conf"
AIDE_DB="/var/lib/aide/${LAB_ID}.db"
AUDITD_CONF="/etc/audit/auditd.conf"
RK_CONF="/etc/rkhunter.conf"
RK_DAT="/var/lib/rkhunter/db/rkhunter.dat"
FAKE_BIN="/usr/local/sbin/systemd-netlogd"
HIDDEN_DIR="/dev/.${LAB_ID}-cache"
CRON_FILE="/etc/cron.d/${LAB_ID}-beacon"
LAB_USER="svc-telemetry"

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 2; }
pass=0; fail=0
chk() { # chk "<label>" <0|1>
    if [ "$2" -eq 0 ]; then printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1))
    else printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); fi
}
has() { command -v "$1" >/dev/null 2>&1; }

echo
echo "=== ${LAB_ID} verification ==============================================="
echo "--- sensor: Linux Audit ---"
if has auditctl; then
    systemctl is-active --quiet auditd 2>/dev/null || service auditd status >/dev/null 2>&1
    chk "auditd is running" $?
    grep -qiE '^[[:space:]]*write_logs[[:space:]]*=[[:space:]]*no' "$AUDITD_CONF"; [ $? -ne 0 ]
    chk "auditd.conf: write_logs is not disabled" $?
    logf=$(awk -F= '/^[[:space:]]*log_file[[:space:]]*=/{gsub(/ /,"",$2);print $2}' "$AUDITD_CONF" | tail -n1)
    logf="${logf:-/var/log/audit/audit.log}"
    [ -f "$logf" ] && [ -n "$(find "$logf" -newer "$BROKEN_AT" 2>/dev/null)" ]
    chk "audit log has been written since the break" $?
    for k in identity ids-tamper persistence; do
        auditctl -l 2>/dev/null | grep -q -- "$k"; chk "rule loaded with key '$k'" $?
    done
    augenrules --check >/dev/null 2>&1; chk "rules.d compiles and matches the loaded set" $?
    ausearch -k identity --start recent >/dev/null 2>&1
    chk "ausearch -k identity returns recent events" $?
else chk "auditctl present" 1; fi

echo "--- sensor: AIDE ---"
if has aide; then
    [ -f "$AIDE_DB" ]; chk "known-good database restored at ${AIDE_DB}" $?
    out=$(aide -c "$AIDE_CONF" --check 2>&1); rc=$?
    [ "$rc" -lt 14 ]; chk "aide --check runs (exit ${rc}; >=14 means config/DB error)" $?
    printf '%s' "$out" | grep -qiE 'sha257|syntax|unknown attribute'; [ $? -ne 0 ]
    chk "no configuration parse error in ${AIDE_CONF}" $?
else chk "aide present" 1; fi

echo "--- sensor: rkhunter ---"
if has rkhunter; then
    rkhunter --config-check --nocolors >/dev/null 2>&1; chk "rkhunter --config-check is clean" $?
    [ -f "$RK_DAT" ]; chk "file-properties database present" $?
    grep -qE "^[[:space:]]*ALLOWHIDDENDIR=${HIDDEN_DIR//\//\\/}" "$RK_CONF"; [ $? -ne 0 ]
    chk "attacker's ALLOWHIDDENDIR entry removed" $?
    grep -qE '^[[:space:]]*DISABLE_TESTS=.*(properties|filesystem)' "$RK_CONF"; [ $? -ne 0 ]
    chk "properties/filesystem tests re-enabled" $?
else chk "rkhunter present" 1; fi

echo "--- incident cleanup ---"
[ ! -e "$FAKE_BIN" ];    chk "planted daemon removed"        $?
[ ! -e "$HIDDEN_DIR" ];  chk "hidden /dev directory removed" $?
[ ! -e "$CRON_FILE" ];   chk "cron persistence removed"      $?
id -u "$LAB_USER" >/dev/null 2>&1; [ $? -ne 0 ]
chk "planted account removed"        $?
echo "==========================================================================="
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
VEOF
    chmod 0755 "$VERIFIER"
}

# -------------------------------- briefing -----------------------------------
briefing() {
    cat <<EOF

${c_red}###########################################################################
#  LPIC-3 303-300  --  332.2 Host Intrusion Detection  --  INCIDENT BRIEFING
###########################################################################${c_off}

You are the on-call engineer. Monitoring says this host "looks quiet". It is
quiet because somebody turned the microphones off.

${c_yel}WHAT YOU WILL SEE (the symptoms)${c_off}

 1) Linux Audit
      # auditctl -l
      No rules
      # auditctl -s | grep -E 'enabled|lost|backlog'
      enabled 1 ...            <- the daemon is up, and yet nothing is recorded
      # augenrules --load
      There was an error in line 4 of /etc/audit/rules.d/99-${LAB_ID}.rules
      # touch /etc/passwd ; ausearch -k identity --start recent
      <no matches>
      ${AUDITD_CONF##*/} contains a directive that makes the daemon discard
      everything it collects; ${AUDIT_RULES_D}/ has been emptied and the only
      ruleset left does not compile (an invalid permission letter and a
      misspelled syscall).

 2) AIDE
      # aide -c ${AIDE_CONF} --check
      ... error at line 12: unknown attribute 'sha257'
      and, once that is fixed:
      Couldn't open file ${AIDE_DB} for reading
      The rule definition was corrupted and the on-host database was deleted.
      ${c_red}Do NOT run 'aide --init' to "fix" it.${c_off}

 3) rkhunter
      # rkhunter --check --sk
      Invalid SCRIPTWHITELIST configuration option: Non-existent pathname:
      /usr/bin/${LAB_ID}-nonexistent-helper
      It refuses to start at all. After you repair that line it will run and
      report almost nothing - which is the second half of the trap: the
      appended block also disables the very tests that would find the
      intrusion, and whitelists the intruder's hiding place.

 4) chkrootkit (untouched, use it as an independent second opinion)
      # chkrootkit -q
      The following suspicious files and directories were found: ...

${c_yel}YOUR MISSION${c_off}

 A. Restore auditd so that it writes again and loads a persistent ruleset
    (via ${AUDIT_RULES_D}/ + augenrules, not just live auditctl) providing:
       key 'identity'    -> writes/attribute changes on /etc/passwd, /etc/shadow,
                            /etc/group, /etc/gshadow
       key 'ids-tamper'  -> writes on /etc/audit/, /etc/aide/, /var/lib/aide/,
                            /etc/rkhunter.conf
       key 'persistence' -> writes and executions under /usr/local/sbin and
                            writes under /etc/cron.d
    Prove each one fires with ausearch.

 B. Restore AIDE: repair the rule definition, reinstate the ${c_grn}known-good${c_off}
    database from the offline baseline in ${BACKUP_DIR}/,
    run a check, and read the report. Re-baseline only AFTER cleanup.

 C. Restore rkhunter: make the configuration valid again, remove every
    directive the intruder appended, reinstate its file-properties database
    from ${BACKUP_DIR}/rkhunter-db/, and run a full check.

 D. Using the restored sensors, enumerate the four planted artifacts, explain
    for each which sensor should have caught it, remove them, and prove the
    host is clean with a second clean AIDE + rkhunter + chkrootkit run.

${c_yel}RULES OF ENGAGEMENT${c_off}
  * The offline baseline in ${BACKUP_DIR} is your only trusted copy.
  * Never re-baseline a host you have not triaged yet.
  * Do not use 'auditctl -e 2' during the lab: it locks the audit configuration
    until reboot. It is the right production hardening, the wrong lab setting.

${c_yel}SELF-CHECK${c_off}
  sudo ${VERIFIER}

${c_yel}GIVE UP / RESET${c_off}
  sudo $0 --restore     (undoes every injected fault and removes the artifacts)

This briefing is also saved at ${BRIEFING}

EOF
}

# --------------------------------- actions -----------------------------------
do_break() {
    need_root
    detect_os
    confirm_disposable
    ensure_tools

    mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$RESTORE_DIR"
    chmod 0700 "$RESTORE_DIR"

    if [ -f "${STATE_DIR}/state" ]; then
        die "A broken lab is already staged. Run '$0 --restore' first."
    fi

    write_verifier          # created BEFORE the baseline so it is not a false positive
    baseline_aide
    baseline_rkhunter
    plant_artifacts
    break_audit
    break_aide
    break_rkhunter

    date -Is >"${STATE_DIR}/state"
    : >"$BROKEN_AT"
    briefing | tee "$BRIEFING" >/dev/null
    briefing
}

do_restore() {
    need_root
    detect_os
    info "Restoring the host to its pre-lab state"

    # planted artifacts
    rm -f "$FAKE_BIN" "$CRON_FILE" "$BEACON_LOG"
    rm -rf "$HIDDEN_DIR"
    id -u "$LAB_USER" >/dev/null 2>&1 && userdel "$LAB_USER" 2>/dev/null || true

    # configs
    if [ -d "$RESTORE_DIR" ]; then
        rm -f "${AUDIT_RULES_D}"/*.rules 2>/dev/null || true
        (cd "$RESTORE_DIR" && find . -type f -print0 |
            while IFS= read -r -d '' f; do
                install -D -m "$(stat -c %a "$f")" "$f" "/${f#./}"
            done)
        ok "Original configuration files restored"
    fi

    # sensors
    if [ -f "${BACKUP_DIR}/$(basename "$AIDE_DB")" ]; then
        install -D -m 0600 "${BACKUP_DIR}/$(basename "$AIDE_DB")" "$AIDE_DB"
    fi
    if [ -d "${BACKUP_DIR}/rkhunter-db" ]; then
        mkdir -p "$RK_DB_DIR"; cp -a "${BACKUP_DIR}/rkhunter-db/." "${RK_DB_DIR}/"
    fi
    command -v augenrules >/dev/null 2>&1 && augenrules --load >/dev/null 2>&1 || true
    restart_auditd

    rm -f "$VERIFIER" "${STATE_DIR}/state" "$BROKEN_AT"
    ok "Lab reset complete. The offline baseline in ${BACKUP_DIR} was kept."
}

usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --break)      ACTION="break" ;;
        --restore)    ACTION="restore" ;;
        --verify)     ACTION="verify" ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --no-install) DO_INSTALL=0 ;;
        -h|--help)    usage ;;
        *)            die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

case "$ACTION" in
    break)   do_break ;;
    restore) do_restore ;;
    verify)  need_root; [ -x "$VERIFIER" ] || die "No staged lab found."; "$VERIFIER" ;;
esac

exit 0

# =============================================================================
#  ============================  S O L U T I O N  =============================
#  Do not read this until you have worked the incident. Every command below is
#  meant to be typed on the lab VM as root.
# =============================================================================
#
#  STEP 0 - Triage before you touch anything
#  ------------------------------------------------------------------------
#    # auditctl -s                     # enabled? lost? backlog?
#    # auditctl -l                     # "No rules" -> the sensor has no policy
#    # ls -l /var/log/audit/audit.log  # size and mtime frozen
#    # ls -l /var/lib/lab332-breakfix/offline-baseline/
#  Establish what you still trust: the offline baseline, and nothing on the
#  running filesystem. Write down the time of the last known-good audit event
#  (`aureport -ts this-week --summary`) - that is the left edge of your window.
#
#  STEP 1 - Repair the Linux Audit system
#  ------------------------------------------------------------------------
#  1a. Find why the daemon records nothing:
#        # grep -nE 'write_logs|log_file|log_format|flush' /etc/audit/auditd.conf
#        write_logs = no                 <-- the daemon collects and discards
#      Fix it and restart (note: on RHEL `systemctl restart auditd` is refused
#      by design; the SysV wrapper is the supported path):
#        # sed -i 's/^write_logs = no/write_logs = yes/' /etc/audit/auditd.conf
#        # service auditd restart
#        # auditctl -s | head -n 5
#
#  1b. Find why no rule loads:
#        # augenrules --check
#        # augenrules --load
#        There was an error in line 4 of /etc/audit/rules.d/99-lab332.rules
#      Line 4 is `-w /etc/passwd -p wq -k identity`: valid permission letters
#      are r, w, x, a - `q` does not exist. Line 5 is
#      `-a always,exit -F arch=b64 -S execv -k persistence`: the syscall is
#      `execve`. Delete the planted file (it is not yours) and write a real
#      policy. augenrules concatenates /etc/audit/rules.d/*.rules in name order:
#
#        # rm -f /etc/audit/rules.d/99-lab332.rules
#
#        # cat >/etc/audit/rules.d/10-base.rules <<'EOF'
#        -D
#        -b 8192
#        -f 1
#        EOF
#
#        # cat >/etc/audit/rules.d/40-identity.rules <<'EOF'
#        -w /etc/passwd  -p wa -k identity
#        -w /etc/shadow  -p wa -k identity
#        -w /etc/group   -p wa -k identity
#        -w /etc/gshadow -p wa -k identity
#        EOF
#
#        # cat >/etc/audit/rules.d/50-ids-tamper.rules <<'EOF'
#        -w /etc/audit/       -p wa -k ids-tamper
#        -w /etc/aide/        -p wa -k ids-tamper
#        -w /var/lib/aide/    -p wa -k ids-tamper
#        -w /etc/rkhunter.conf -p wa -k ids-tamper
#        EOF
#
#        # cat >/etc/audit/rules.d/60-persistence.rules <<'EOF'
#        -w /usr/local/sbin -p wax -k persistence
#        -w /etc/cron.d     -p wa  -k persistence
#        EOF
#
#      Equivalent syscall form for the execution half, if you prefer it:
#        -a always,exit -F arch=b64 -S execve -F dir=/usr/local/sbin -F key=persistence
#
#      Load and verify:
#        # augenrules --load
#        # auditctl -l
#        # auditctl -s | grep -E 'enabled|backlog'
#
#  1c. Prove the sensor actually fires (a rule that never fired is a hypothesis,
#      not a control):
#        # touch /etc/passwd
#        # ausearch -k identity --start recent -i | tail -n 20
#        # aureport -k --summary
#
#      Production note: a hardened host ends its ruleset with a
#      /etc/audit/rules.d/99-finalize.rules containing `-e 2`, which makes the
#      configuration immutable until reboot. Add it last, after you are sure
#      the policy is right - in this lab, do not.
#
#  STEP 2 - Repair AIDE
#  ------------------------------------------------------------------------
#  2a. Read the parse error, do not guess:
#        # aide -c /etc/aide/lab332.conf --check
#        ... unknown attribute 'sha257'
#      The rule definition was corrupted:
#        # grep -n '^LabBin' /etc/aide/lab332.conf
#        LabBin  = p+i+n+u+g+s+b+m+c+sha257
#      Restore the attribute group (this is "rule management": the group is the
#      unit of policy, the selection lines only apply it):
#        # sed -i 's/^LabBin  = .*/LabBin  = p+i+n+u+g+s+b+m+c+sha256/' \
#            /etc/aide/lab332.conf
#
#  2b. Now the database is missing:
#        # aide -c /etc/aide/lab332.conf --check
#        Couldn't open file /var/lib/aide/lab332.db for reading
#      The trap: `aide --init` would rebuild the database from the CURRENT,
#      compromised filesystem and declare the intruder's files legitimate.
#      Use the offline copy instead:
#        # install -m 0600 \
#            /var/lib/lab332-breakfix/offline-baseline/lab332.db \
#            /var/lib/aide/lab332.db
#        # aide -c /etc/aide/lab332.conf --check | tee /root/aide-incident.txt
#
#      Expected report (abridged):
#        Added entries:
#          f++++++++++++++++: /usr/local/sbin/systemd-netlogd
#          d++++++++++++++++: /dev/.lab332-cache
#          f++++++++++++++++: /etc/cron.d/lab332-beacon
#        Changed entries:
#          f ...    ....c...: /etc/passwd        <- the planted account
#          f ...    ....c...: /etc/shadow
#          f ...    .m.c....: /etc/audit/auditd.conf
#          f ...    .m.c....: /etc/rkhunter.conf
#          f ...    .m.c....: /etc/aide/lab332.conf
#      Read that report as a narrative: the last three lines are the intruder
#      disabling the sensors, the first four are what the sensors were meant to
#      catch. AIDE exit status is a bitmask - 1 new, 2 removed, 4 changed
#      (so 7 = all three), while >=14 means an operational error, not a finding.
#
#  STEP 3 - Repair rkhunter
#  ------------------------------------------------------------------------
#  3a. Make the configuration valid:
#        # rkhunter --config-check
#        Invalid SCRIPTWHITELIST configuration option: Non-existent pathname
#      Look at the tail of the file - the whole appended block is hostile:
#        # tail -n 10 /etc/rkhunter.conf
#        SCRIPTWHITELIST=/usr/bin/lab332-nonexistent-helper
#        DISABLE_TESTS=properties filesystem hidden_procs
#        ALLOWHIDDENDIR=/dev/.lab332-cache
#      Remove all three lines (the DISABLE_TESTS values are appended to the
#      default list, so this line silently switched off the file-properties and
#      filesystem tests; ALLOWHIDDENDIR whitelisted the hiding place itself):
#        # sed -i '/lab332-nonexistent-helper/d;
#                  /^DISABLE_TESTS=properties filesystem hidden_procs$/d;
#                  /^ALLOWHIDDENDIR=\/dev\/\.lab332-cache$/d' /etc/rkhunter.conf
#        # rkhunter --config-check && echo CONFIG OK
#
#  3b. Reinstate the properties database from the offline baseline - again,
#      NOT with --propupd, which would re-baseline the compromised host:
#        # cp -a /var/lib/lab332-breakfix/offline-baseline/rkhunter-db/. \
#              /var/lib/rkhunter/db/
#        # rkhunter --check --sk --nocolors --rwo
#      Expected warnings:
#        Warning: The file properties have changed: /etc/passwd
#        Warning: User 'svc-telemetry' has been added to the passwd file.
#        Warning: Hidden directory found: /dev/.lab332-cache
#        Warning: Suspicious file types found in /dev
#      Full log: /var/log/rkhunter.log ( `--rwo` = report warnings only ).
#
#  3c. Third opinion, no shared state with rkhunter:
#        # chkrootkit -q
#        The following suspicious files and directories were found:
#        /dev/.lab332-cache
#
#  STEP 4 - Enumerate and eradicate
#  ------------------------------------------------------------------------
#    Artifact                      Sensor that must catch it
#    ---------------------------   -----------------------------------------
#    /usr/local/sbin/systemd-netlogd  AIDE (added entry), audit key persistence
#    /dev/.lab332-cache               rkhunter filesystem test, chkrootkit, AIDE
#    /etc/cron.d/lab332-beacon        AIDE (added entry), audit key persistence
#    user svc-telemetry               rkhunter passwd check, AIDE on /etc/passwd,
#                                     audit key identity
#
#    Corroborate before deleting:
#      # stat /usr/local/sbin/systemd-netlogd /etc/cron.d/lab332-beacon
#      # cat /etc/cron.d/lab332-beacon
#      # getent passwd svc-telemetry
#      # awk -F: '$3==0 {print}' /etc/passwd      # any second UID-0 account?
#      # ls -la /dev/.lab332-cache
#      # ausearch -k persistence --start recent -i
#
#    Then eradicate:
#      # rm -f /usr/local/sbin/systemd-netlogd /etc/cron.d/lab332-beacon
#      # rm -rf /dev/.lab332-cache
#      # userdel svc-telemetry
#
#  STEP 5 - Re-baseline, in this order, and only now
#  ------------------------------------------------------------------------
#      # aide -c /etc/aide/lab332.conf --check      # expect only your own
#                                                   # /etc/audit + rkhunter.conf
#                                                   # repairs to be reported
#      # aide -c /etc/aide/lab332.conf --init
#      # mv /var/lib/aide/lab332.db.new /var/lib/aide/lab332.db
#      # cp -a /var/lib/aide/lab332.db  <off-host storage>
#      # rkhunter --propupd
#      # rkhunter --check --sk --rwo && echo "rkhunter clean"
#      # chkrootkit -q
#      # lab332-verify
#
#  STEP 6 - What the exam wants you to have internalised
#  ------------------------------------------------------------------------
#   * auditd can be alive and useless: `enabled 1` with `write_logs = no`, or
#     with an empty ruleset, or with a rules.d file that fails to compile.
#     `auditctl -l` and `augenrules --check` are the two questions to ask.
#   * Live rules (`auditctl -w ...`) die at the next restart. Persistence lives
#     in /etc/audit/rules.d/*.rules, compiled by augenrules into
#     /etc/audit/audit.rules. `-e 2` freezes it until reboot.
#   * An AIDE database on the machine it protects is a convenience, not a
#     control: the intruder can delete it, and can rewrite the config that
#     defines what "changed" means. Store the database and the config hash off
#     the host; consider running the check from read-only media.
#   * `aide --init` and `rkhunter --propupd` are baseline-creation commands.
#     Running either after a compromise launders the compromise. The correct
#     sequence is always: restore a trusted baseline -> check -> triage ->
#     eradicate -> re-baseline.
#   * The exclusion list is policy, not noise reduction: every `!` line and
#     every whitelist directive (SCRIPTWHITELIST, ALLOWHIDDENDIR,
#     DISABLE_TESTS) is a blind spot an attacker can widen. Review those files
#     with the same suspicion you give /etc/passwd - and put an audit watch on
#     them, which is exactly what the 'ids-tamper' key above is for.
#   * Keep independent detectors with independent state: AIDE (integrity DB),
#     rkhunter (properties DB + signatures), chkrootkit (no state at all),
#     auditd (kernel-side event stream). The sabotage of one is visible to the
#     others - that redundancy is the whole design.
# =============================================================================