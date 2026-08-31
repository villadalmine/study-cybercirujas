#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-1 v5.0  —  Topic 108.2: System logging  —  BREAK & FIX LAB
# ==============================================================================
#
#  Certification : LPIC-1 (exams 101-500 + 102-500, version 5.0)
#  Objective     : 108.2 System logging
#  Key knowledge : systemd-journald, journalctl, /etc/systemd/journald.conf,
#                  /var/log/journal/, systemd-cat, rsyslogd, /etc/rsyslog.conf,
#                  /etc/rsyslog.d/, logger, facilities/severities, /var/log/,
#                  logrotate, /etc/logrotate.conf, /etc/logrotate.d/
#  Sources       : https://www.lpi.org/our-certifications/exam-101-objectives/
#                  https://www.lpi.org/our-certifications/exam-102-objectives/
#                  https://www.rsyslog.com/doc/configuration/index.html
#                  https://www.freedesktop.org/software/systemd/man/journald.conf.html
#                  https://www.freedesktop.org/software/systemd/man/journalctl.html
#                  https://linux.die.net/man/8/logrotate  (see also `man 8 logrotate`)
#
#  DANGER — READ THIS FIRST
#  ------------------------
#  This script deliberately DEGRADES the logging subsystem of the machine it
#  runs on. It is written for a DISPOSABLE laboratory virtual machine that you
#  can throw away. Do NOT run it on anything you care about, on a bastion, on a
#  build agent, or on any host that ships logs to a SIEM. Losing logs on a real
#  system means losing the audit trail.
#
#  Everything it touches is backed up under /root/lpic1-108.2-lab/backup/ and
#  can be undone with `--restore`. No package is removed, no log file is
#  deleted, no user account is modified.
#
#  Usage:
#      sudo ./108.2-break-and-fix.sh --break     # inject faults + print briefing
#      sudo ./108.2-break-and-fix.sh --brief     # re-print the briefing
#      sudo ./108.2-break-and-fix.sh --verify    # objective grading of your fix
#      sudo ./108.2-break-and-fix.sh --restore   # escape hatch: undo everything
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until you have genuinely tried.
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
LAB_ID="lpic1-108.2"
LAB_DIR="/root/${LAB_ID}-lab"
BACKUP_DIR="${LAB_DIR}/backup"
STATE_FILE="${LAB_DIR}/state.env"

RSYSLOG_MAIN="/etc/rsyslog.conf"
RSYSLOG_DROPIN="/etc/rsyslog.d/49-lab-remote-buffer.conf"

JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
JOURNALD_DROPIN="${JOURNALD_DROPIN_DIR}/99-lab-tuning.conf"

APP_LOG_DIR="/var/log/labapp"
APP_LOG="${APP_LOG_DIR}/app.log"
APP_MARKER="${APP_LOG_DIR}/.lab-created"
LOGROTATE_CONF="/etc/logrotate.d/labapp"

# Filled in by detect_platform()
SYSLOG_FILE=""
AUTH_FILE=""
ADM_GROUP="root"
RSYSLOG_PRESENT="no"
RSYSLOG_FALLBACK="no"

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED="$(tput setaf 1)"; C_GRN="$(tput setaf 2)"; C_YEL="$(tput setaf 3)"
    C_BLU="$(tput setaf 4)"; C_BLD="$(tput bold)"; C_RST="$(tput sgr0)"
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info()  { printf '%s[ INFO ]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[  OK  ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[ WARN ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
fail()  { printf '%s[ FAIL ]%s %s\n' "$C_RED" "$C_RST" "$*"; }
die()   { printf '%s[FATAL ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
rule()  { printf '%s%s%s\n' "$C_BLD" "------------------------------------------------------------------------------" "$C_RST"; }

# ------------------------------------------------------------------------------
# Environment guards
# ------------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "This lab must run as root (try: sudo $0 $*)."
}

require_systemd() {
    [ -d /run/systemd/system ] || die "systemd is not the running init; this lab targets systemd hosts."
    command -v systemctl  >/dev/null 2>&1 || die "systemctl not found."
    command -v journalctl >/dev/null 2>&1 || die "journalctl not found (systemd-journald missing)."
    command -v logger     >/dev/null 2>&1 || die "logger not found (install util-linux / bsdutils)."
    command -v logrotate  >/dev/null 2>&1 || die "logrotate not found (install the logrotate package)."
}

warn_if_container() {
    if [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
        warn "This looks like a container. journald/rsyslog behave differently there;"
        warn "the lab is designed for a full VM."
    fi
}

confirm_destructive() {
    # --force / -y skips the prompt (useful for automated classroom provisioning).
    if [ "${LAB_FORCE:-no}" = "yes" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        die "Not an interactive terminal. Re-run with --force if you really mean it."
    fi
    rule
    printf '%sThis will deliberately BREAK logging on this host: %s%s\n' "$C_BLD" "$(hostname -f 2>/dev/null || hostname)" "$C_RST"
    printf 'Run it ONLY on a disposable lab VM.\n'
    rule
    printf 'Type exactly  BREAK MY LAB VM  to continue: '
    local answer
    IFS= read -r answer
    [ "$answer" = "BREAK MY LAB VM" ] || die "Confirmation not given. Nothing was changed."
}

# ------------------------------------------------------------------------------
# Platform detection
# ------------------------------------------------------------------------------
detect_platform() {
    # Debian family keeps the catch-all log in /var/log/syslog, RHEL family in
    # /var/log/messages. Detect by file first, fall back to os-release.
    if [ -f /var/log/syslog ]; then
        SYSLOG_FILE="/var/log/syslog"; AUTH_FILE="/var/log/auth.log"
    elif [ -f /var/log/messages ]; then
        SYSLOG_FILE="/var/log/messages"; AUTH_FILE="/var/log/secure"
    elif [ -f /etc/debian_version ]; then
        SYSLOG_FILE="/var/log/syslog"; AUTH_FILE="/var/log/auth.log"
    else
        SYSLOG_FILE="/var/log/messages"; AUTH_FILE="/var/log/secure"
    fi

    if getent group adm >/dev/null 2>&1; then ADM_GROUP="adm"; else ADM_GROUP="root"; fi

    if command -v rsyslogd >/dev/null 2>&1 \
       && systemctl list-unit-files rsyslog.service >/dev/null 2>&1; then
        RSYSLOG_PRESENT="yes"
    else
        RSYSLOG_PRESENT="no"
    fi
}

save_state() {
    mkdir -p "$LAB_DIR"
    cat > "$STATE_FILE" <<EOF
# Generated by ${LAB_ID} break & fix lab. Do not edit.
SYSLOG_FILE='${SYSLOG_FILE}'
AUTH_FILE='${AUTH_FILE}'
ADM_GROUP='${ADM_GROUP}'
RSYSLOG_PRESENT='${RSYSLOG_PRESENT}'
RSYSLOG_FALLBACK='${RSYSLOG_FALLBACK}'
EOF
    chmod 0600 "$STATE_FILE"
}

load_state() {
    detect_platform
    # State written at break time wins over live detection.
    # shellcheck disable=SC1090
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    return 0
}

# ------------------------------------------------------------------------------
# Backup / restore of individual files
# ------------------------------------------------------------------------------
backup_file() {
    # Copy a pristine original exactly once, preserving mode/owner/timestamps.
    local src="$1"
    local dst="${BACKUP_DIR}/$(echo "$src" | sed 's|/|__|g')"
    mkdir -p "$BACKUP_DIR"
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
        cp -a "$src" "$dst"
        info "Backed up ${src} -> ${dst}"
    fi
}

restore_file() {
    local src="$1"
    local dst="${BACKUP_DIR}/$(echo "$src" | sed 's|/|__|g')"
    if [ -e "$dst" ]; then
        cp -a "$dst" "$src"
        ok "Restored ${src} from backup"
    fi
}

relabel() {
    # RHEL/Fedora: give new files under /etc the right SELinux context.
    command -v restorecon >/dev/null 2>&1 && restorecon -F "$1" >/dev/null 2>&1 || true
}

nonce() { printf 'LAB%s%s' "$$" "$(date +%s%N | tail -c 7)"; }

# ==============================================================================
#  FAULT 1 — rsyslog silently discards every message
# ==============================================================================
# A drop-in in /etc/rsyslog.d/ is parsed at the $IncludeConfig / include() point,
# which in both Debian and RHEL stock configurations sits BEFORE the RULES
# section. A `stop` there terminates processing of every message before any
# file action runs. The config is syntactically valid: `rsyslogd -N1` says OK,
# `systemctl status rsyslog` says active (running), and nothing is logged about
# it. That is exactly what makes it a good exercise.
# ------------------------------------------------------------------------------
break_rsyslog() {
    if [ "$RSYSLOG_PRESENT" != "yes" ]; then
        warn "rsyslog is not installed — FAULT 1 skipped."
        warn "This host logs only to the journal. Install rsyslog to practise this part."
        return 0
    fi

    info "Injecting FAULT 1 (rsyslog)..."
    cat > "$RSYSLOG_DROPIN" <<'EOF'
# Remote buffering profile — lab
# (Looks like a harmless forwarding tweak. It is not.)
$WorkDirectory /var/spool/rsyslog
$ActionQueueType LinkedList
$ActionQueueFileName labfwd
$ActionResumeRetryCount -1
$ActionQueueSaveOnShutdown on

*.* stop
EOF
    chmod 0644 "$RSYSLOG_DROPIN"
    relabel "$RSYSLOG_DROPIN"

    systemctl restart rsyslog.service || warn "Could not restart rsyslog.service"
    sleep 1

    # Verify the fault actually took effect. If this distribution includes
    # /etc/rsyslog.d/ AFTER the rules (non-standard), fall back to injecting the
    # same rule at the top of the main configuration file.
    local n; n="$(nonce)"
    logger -t lab-selftest -p user.notice "$n"
    sleep 2
    if [ -r "$SYSLOG_FILE" ] && grep -qs -- "$n" "$SYSLOG_FILE"; then
        warn "Drop-in did not take precedence on this distribution; using fallback."
        backup_file "$RSYSLOG_MAIN"
        sed -i '1i *.* stop' "$RSYSLOG_MAIN"
        RSYSLOG_FALLBACK="yes"
        systemctl restart rsyslog.service || true
        sleep 1
    fi
    ok "FAULT 1 armed: rsyslog accepts messages and writes none of them to disk."
}

# ==============================================================================
#  FAULT 2 — journald: volatile storage + brutal rate limiting
# ==============================================================================
# Storage=volatile parks the journal in /run/log/journal (tmpfs): every entry of
# the current boot dies at reboot, and /var/log/journal is ignored even if it
# exists. RateLimitBurst=15 per 30 s makes journald drop entries from any noisy
# unit and emit "Suppressed N messages from ...". Both are one-line settings in
# a drop-in, and both are invisible unless you look at the EFFECTIVE config.
# ------------------------------------------------------------------------------
break_journald() {
    info "Injecting FAULT 2 (systemd-journald)..."
    mkdir -p "$JOURNALD_DROPIN_DIR"
    cat > "$JOURNALD_DROPIN" <<'EOF'
# Journal tuning profile — lab
[Journal]
Storage=volatile
RateLimitIntervalSec=30s
RateLimitBurst=15
SystemMaxUse=16M
EOF
    chmod 0644 "$JOURNALD_DROPIN"
    relabel "$JOURNALD_DROPIN"

    systemctl restart systemd-journald.service || warn "Could not restart systemd-journald.service"
    sleep 1
    ok "FAULT 2 armed: journal is volatile and rate-limited to 15 messages / 30 s."
}

# ==============================================================================
#  FAULT 3 — logrotate refuses to rotate an application log
# ==============================================================================
# Since logrotate 3.8 a log whose parent directory is world-writable (or owned
# by someone other than the rotating user) is skipped unless the stanza declares
# `su <user> <group>`. The application keeps appending, the file grows without
# bound, and the failure is only visible if you actually run logrotate by hand.
# ------------------------------------------------------------------------------
break_logrotate() {
    info "Injecting FAULT 3 (logrotate)..."
    mkdir -p "$APP_LOG_DIR"
    : > "$APP_MARKER"

    # Seed a plausible application log if it does not exist yet.
    if [ ! -s "$APP_LOG" ]; then
        {
            for i in $(seq 1 2000); do
                printf '%s labapp[%d]: request id=%05d status=200 latency=%dms\n' \
                    "$(date '+%b %e %H:%M:%S')" "$$" "$i" $(( (i % 37) + 3 ))
            done
        } > "$APP_LOG"
    fi
    chown root:"$ADM_GROUP" "$APP_LOG" 2>/dev/null || true
    chmod 0640 "$APP_LOG"

    # The actual fault: world-writable parent directory, and a stanza with no `su`.
    chmod 0777 "$APP_LOG_DIR"

    cat > "$LOGROTATE_CONF" <<EOF
${APP_LOG_DIR}/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0640 root ${ADM_GROUP}
}
EOF
    chmod 0644 "$LOGROTATE_CONF"
    relabel "$LOGROTATE_CONF"
    ok "FAULT 3 armed: ${APP_LOG} will never be rotated."
}

# ==============================================================================
#  Student briefing
# ==============================================================================
briefing() {
    load_state
    rule
    printf '%s LPIC-1 108.2 — System logging — BREAK & FIX%s\n' "$C_BLD" "$C_RST"
    rule
    cat <<EOF

SCENARIO
  You are on call. A colleague "tuned logging" on this box last night and went
  on holiday. This morning the on-call rotation cannot see anything: the ticket
  says "we have no logs". Nothing crashed. Every service reports active
  (running). No error is printed anywhere. Three independent faults are in
  place; each one is a single configuration decision, all three are reversible.

WHAT YOU WILL OBSERVE

  Symptom 1 — the text logs are frozen
    \$ logger -p user.notice "hello from \$(whoami)"
    \$ tail -n 5 ${SYSLOG_FILE}
    ... your message is NOT there, and the file's mtime never advances.
    \$ journalctl -t logger -n 5        # but the journal DID receive it
    \$ systemctl status rsyslog          # active (running), zero errors
    \$ rsyslogd -N1                      # "End of config validation run. Bye."
    Syntactically valid is not the same thing as correct. Find out where the
    messages die.

  Symptom 2 — the journal forgets, and drops
    \$ journalctl --list-boots           # only one boot is listed
    \$ journalctl -b -1                  # "Specified boot ID ... does not exist"
    \$ for i in \$(seq 1 60); do logger -t burst "line \$i"; done
    \$ journalctl -t burst --no-pager | wc -l
    ... far fewer than 60, and somewhere you will find
        "Suppressed NN messages from /system.slice/..." or a similar notice.
    Where does the journal keep its data on this machine right now, and who
    decided that?

  Symptom 3 — one log file grows for ever
    \$ ls -lh ${APP_LOG_DIR}/
    ... app.log keeps growing, no app.log.1 / app.log.1.gz ever appears.
    \$ logrotate -d ${LOGROTATE_CONF}
    ... prints an error and rotates nothing. Read that error literally: it
    names both the condition and the directive that resolves it.

YOUR MISSION (this is what the grader checks)
  1. A message emitted with logger must land in ${SYSLOG_FILE} again,
     with rsyslog installed, enabled and running. Do not uninstall rsyslog and
     do not replace it with a cron job that copies the journal.
  2. The journal must store entries persistently under /var/log/journal, and
     must stop discarding bursts: 60 messages sent in a loop must all arrive.
  3. ${LOGROTATE_CONF} must still exist, must still cover
     ${APP_LOG_DIR}/*.log, and must rotate cleanly with no errors.
     Deleting the config or the log file is not a fix.

TOOLBOX YOU ARE EXPECTED TO REACH FOR
  journalctl -b / -p / -u / -t / -f / --since / --list-boots / --disk-usage
  systemd-analyze cat-config systemd/journald.conf
  systemctl status|restart systemd-journald rsyslog
  rsyslogd -N1 ; ls /etc/rsyslog.d/ ; less /etc/rsyslog.conf
  logger -p <facility>.<severity> -t <tag> ; systemd-cat
  logrotate -d (dry run) ; logrotate -f (force) ; /var/lib/logrotate/
  ls -l /var/log/ ; stat ; getfacl ; man 5 journald.conf ; man 8 logrotate

WHEN YOU THINK YOU ARE DONE
    sudo $0 --verify
  It grades all three objectives with real traffic, not by reading your files.
  (Objective 3 performs one forced rotation as proof — that is expected.)

ESCAPE HATCH
    sudo $0 --restore

EOF
    rule
}

# ==============================================================================
#  Grading
# ==============================================================================
effective_journald_setting() {
    # Effective value = last uncommented assignment across main config + drop-ins.
    local key="$1" out=""
    if command -v systemd-analyze >/dev/null 2>&1 \
       && out="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null)"; then
        :
    else
        out="$(cat /etc/systemd/journald.conf \
                   /etc/systemd/journald.conf.d/*.conf \
                   /usr/lib/systemd/journald.conf.d/*.conf 2>/dev/null || true)"
    fi
    printf '%s\n' "$out" \
        | grep -E "^[[:space:]]*${key}[[:space:]]*=" \
        | tail -n 1 | cut -d= -f2- | tr -d '[:space:]'
}

verify_rsyslog() {
    if [ "$RSYSLOG_PRESENT" != "yes" ]; then
        warn "OBJECTIVE 1 skipped: rsyslog was not installed when the lab was armed."
        return 0
    fi
    if ! systemctl is-active --quiet rsyslog.service; then
        fail "OBJECTIVE 1: rsyslog.service is not active."
        return 1
    fi
    local n; n="$(nonce)"
    logger -t lab-grader -p user.notice "grader probe $n"
    local i=0
    while [ "$i" -lt 15 ]; do
        if [ -r "$SYSLOG_FILE" ] && grep -qs -- "$n" "$SYSLOG_FILE"; then
            ok "OBJECTIVE 1: logger output reaches ${SYSLOG_FILE} again."
            return 0
        fi
        sleep 1; i=$((i + 1))
    done
    fail "OBJECTIVE 1: the probe never reached ${SYSLOG_FILE} (waited 15 s)."
    return 1
}

verify_journal_persistence() {
    local storage; storage="$(effective_journald_setting Storage)"
    case "$storage" in
        persistent)
            ;;
        ""|auto)
            if [ ! -d /var/log/journal ]; then
                fail "OBJECTIVE 2a: Storage=${storage:-auto} but /var/log/journal does not exist, so the journal is still volatile."
                return 1
            fi
            ;;
        *)
            fail "OBJECTIVE 2a: effective Storage=${storage} — the journal is not persistent."
            return 1
            ;;
    esac
    if [ ! -d /var/log/journal ]; then
        fail "OBJECTIVE 2a: /var/log/journal is missing."
        return 1
    fi
    if ! journalctl --header 2>/dev/null | grep -q '/var/log/journal/'; then
        fail "OBJECTIVE 2a: no active journal file under /var/log/journal (did you run 'journalctl --flush'?)."
        return 1
    fi
    ok "OBJECTIVE 2a: the journal is persistent under /var/log/journal."
    return 0
}

verify_journal_ratelimit() {
    local n tag i got
    n="$(nonce)"; tag="labgrade"
    for i in $(seq 1 60); do logger -t "$tag" "burst $i $n"; done
    journalctl --sync 2>/dev/null || sleep 2
    got="$(journalctl -t "$tag" -n 500 --no-pager 2>/dev/null | grep -c -- "$n" || true)"
    if [ "${got:-0}" -ge 55 ]; then
        ok "OBJECTIVE 2b: ${got}/60 burst messages stored — rate limiting is no longer dropping traffic."
        return 0
    fi
    fail "OBJECTIVE 2b: only ${got:-0}/60 burst messages survived — journald is still rate limiting."
    return 1
}

verify_logrotate() {
    if [ ! -f "$LOGROTATE_CONF" ]; then
        fail "OBJECTIVE 3: ${LOGROTATE_CONF} no longer exists — deleting the config is not a fix."
        return 1
    fi
    if ! grep -q "${APP_LOG_DIR}" "$LOGROTATE_CONF"; then
        fail "OBJECTIVE 3: ${LOGROTATE_CONF} no longer covers ${APP_LOG_DIR}."
        return 1
    fi
    if [ ! -f "$APP_LOG" ]; then
        fail "OBJECTIVE 3: ${APP_LOG} is gone — deleting the log is not a fix."
        return 1
    fi

    local dry rc=0
    dry="$(logrotate -d "$LOGROTATE_CONF" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$dry" | grep -qi '^error:'; then
        fail "OBJECTIVE 3: dry run still reports a problem:"
        printf '%s\n' "$dry" | grep -i 'error' | sed 's/^/         /'
        return 1
    fi

    info "OBJECTIVE 3: dry run clean — forcing one real rotation as proof."
    rc=0
    logrotate -f "$LOGROTATE_CONF" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "OBJECTIVE 3: forced rotation exited with status ${rc}."
        return 1
    fi
    # shellcheck disable=SC2012
    if ls "${APP_LOG}".1* >/dev/null 2>&1; then
        ok "OBJECTIVE 3: rotation works ($(ls -1 "${APP_LOG}".1* | head -n1))."
        return 0
    fi
    fail "OBJECTIVE 3: rotation produced no ${APP_LOG}.1 file."
    return 1
}

do_verify() {
    load_state
    rule
    printf '%s Grading LPIC-1 108.2 break & fix%s\n' "$C_BLD" "$C_RST"
    rule
    local score=0 total=0

    total=$((total + 1)); if verify_rsyslog;            then score=$((score + 1)); fi
    total=$((total + 1)); if verify_journal_persistence; then score=$((score + 1)); fi
    total=$((total + 1)); if verify_journal_ratelimit;   then score=$((score + 1)); fi
    total=$((total + 1)); if verify_logrotate;           then score=$((score + 1)); fi

    rule
    if [ "$score" -eq "$total" ]; then
        ok "ALL OBJECTIVES PASSED (${score}/${total}). Logging is healthy again."
        printf '\nRun  sudo %s --restore  to return the box to its pre-lab state.\n\n' "$0"
        return 0
    fi
    fail "${score}/${total} objectives passed. Keep digging — re-run --verify when ready."
    printf '\nHint order: follow the message, not the service. Emit one, then ask each\n'
    printf 'component in turn whether it received it and what it decided to do with it.\n\n'
    return 1
}

# ==============================================================================
#  Break / restore drivers
# ==============================================================================
do_break() {
    require_root
    require_systemd
    warn_if_container
    detect_platform

    if [ -f "$STATE_FILE" ]; then
        warn "The lab is already armed (state file ${STATE_FILE} exists)."
        warn "Use --brief to re-read the briefing, --verify to grade, --restore to undo."
        exit 0
    fi

    confirm_destructive

    mkdir -p "$LAB_DIR" "$BACKUP_DIR"
    chmod 0700 "$LAB_DIR"
    backup_file "$RSYSLOG_MAIN"
    [ -f "$JOURNALD_DROPIN" ]  && backup_file "$JOURNALD_DROPIN"
    [ -f "$LOGROTATE_CONF" ]   && backup_file "$LOGROTATE_CONF"
    backup_file /etc/systemd/journald.conf

    break_rsyslog
    break_journald
    break_logrotate

    save_state
    printf '\n'
    briefing
}

do_restore() {
    require_root
    load_state
    info "Restoring pre-lab state..."

    # FAULT 1
    if [ -f "$RSYSLOG_DROPIN" ]; then
        rm -f "$RSYSLOG_DROPIN"
        ok "Removed ${RSYSLOG_DROPIN}"
    fi
    if [ "$RSYSLOG_FALLBACK" = "yes" ]; then
        restore_file "$RSYSLOG_MAIN"
    fi
    if [ "$RSYSLOG_PRESENT" = "yes" ]; then
        systemctl restart rsyslog.service 2>/dev/null || warn "rsyslog.service restart failed"
    fi

    # FAULT 2 — remove the lab drop-in only; never touch the journal data itself.
    if [ -f "$JOURNALD_DROPIN" ]; then
        if [ -e "${BACKUP_DIR}/$(echo "$JOURNALD_DROPIN" | sed 's|/|__|g')" ]; then
            restore_file "$JOURNALD_DROPIN"
        else
            rm -f "$JOURNALD_DROPIN"
            ok "Removed ${JOURNALD_DROPIN}"
        fi
    fi
    rmdir "$JOURNALD_DROPIN_DIR" 2>/dev/null || true
    systemctl restart systemd-journald.service 2>/dev/null || warn "systemd-journald restart failed"

    # FAULT 3 — remove only artefacts this lab created.
    if [ -f "$LOGROTATE_CONF" ]; then
        if [ -e "${BACKUP_DIR}/$(echo "$LOGROTATE_CONF" | sed 's|/|__|g')" ]; then
            restore_file "$LOGROTATE_CONF"
        else
            rm -f "$LOGROTATE_CONF"
            ok "Removed ${LOGROTATE_CONF}"
        fi
    fi
    if [ -f "$APP_MARKER" ]; then
        rm -rf "$APP_LOG_DIR"
        ok "Removed lab-created ${APP_LOG_DIR}"
    else
        warn "${APP_LOG_DIR} was not created by this lab — left untouched."
    fi

    rm -f "$STATE_FILE"
    ok "Restore complete. Backups kept in ${BACKUP_DIR} (delete them by hand if you wish)."
    warn "If /var/log/journal now exists because you created it, it was left in place"
    warn "on purpose: this script never deletes log data."
}

usage() {
    cat <<EOF
LPIC-1 108.2 (System logging) — break & fix lab

  sudo $0 --break     inject the three faults and print the briefing
  sudo $0 --brief     re-print the briefing
  sudo $0 --verify    grade your fix with live traffic
  sudo $0 --restore   undo everything this lab changed
  sudo $0 --help      this text

Options: --force / -y   skip the interactive confirmation of --break
EOF
}

main() {
    local action=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --break|break)     action="break" ;;
            --verify|verify)   action="verify" ;;
            --restore|restore) action="restore" ;;
            --brief|brief)     action="brief" ;;
            --force|-y)        LAB_FORCE="yes" ;;
            --help|-h)         usage; exit 0 ;;
            *)                 usage; die "Unknown argument: $1" ;;
        esac
        shift
    done
    [ -n "$action" ] || { usage; exit 1; }

    case "$action" in
        break)   do_break ;;
        verify)  require_root; do_verify ;;
        restore) do_restore ;;
        brief)   require_root; briefing ;;
    esac
}

main "$@"

# ==============================================================================
#                            S O L U T I O N
#          Stop here unless you have already worked the problem.
# ==============================================================================
#
# METHOD FIRST. The exam tests commands, but production tests reasoning. A log
# message travels: application -> /dev/log (or the native journal socket) ->
# systemd-journald -> (imuxsock/imjournal) -> rsyslogd -> ruleset -> file on
# disk -> logrotate. Do not "restart things". Emit one message and ask each hop
# in turn whether it saw it. The first hop that did not is the broken one.
#
#     # emit a probe with a unique tag and a known facility.severity
#     logger -t probe -p user.notice "probe-$(date +%s)"
#     journalctl -t probe -n 5          # did journald get it?   -> yes
#     tail -n 5 /var/log/syslog         # did rsyslog write it?  -> no
#     # => the break is between journald and disk: it is rsyslog's ruleset.
#
# ------------------------------------------------------------------------------
# FAULT 1 — rsyslog discards everything
# ------------------------------------------------------------------------------
# Diagnosis
#     systemctl status rsyslog                 # active (running) — no clue here
#     rsyslogd -N1                             # config VALID — still no clue
#     ls -l /etc/rsyslog.d/                    # <-- the clue
#     grep -rn --color -E '(^|[^#])stop|~$' /etc/rsyslog.conf /etc/rsyslog.d/
#
#     You find /etc/rsyslog.d/49-lab-remote-buffer.conf ending in `*.* stop`.
#     Why does a file in /etc/rsyslog.d/ beat the rules in /etc/rsyslog.conf?
#     Because the stock configuration includes that directory ($IncludeConfig
#     on Debian, include(file=...) on RHEL) BEFORE its RULES section, and
#     rsyslog evaluates rules strictly in the order they are parsed. `stop`
#     ends processing of the message right there: no file action ever runs.
#     Nothing is logged about it, because discarding is a legitimate action.
#
# Fix
#     cp -a /etc/rsyslog.d/49-lab-remote-buffer.conf /root/   # keep evidence
#     rm -f /etc/rsyslog.d/49-lab-remote-buffer.conf
#     rsyslogd -N1                                            # validate first
#     systemctl restart rsyslog
#     logger -t probe -p user.notice "after-fix"
#     tail -n 3 /var/log/syslog        # (RHEL: /var/log/messages)
#
#     If the fallback path was used, the same `*.* stop` line is line 1 of
#     /etc/rsyslog.conf; delete that line and restart. Compare against the
#     backup:  diff /root/lpic1-108.2-lab/backup/__etc__rsyslog.conf /etc/rsyslog.conf
#
# What to remember: "config is valid" and "service is running" prove nothing
# about behaviour. rsyslog rules are ordered and `stop` (legacy `~`) is final.
#
# ------------------------------------------------------------------------------
# FAULT 2a — the journal is volatile
# ------------------------------------------------------------------------------
# Diagnosis
#     journalctl --list-boots                  # only boot 0 exists
#     journalctl --disk-usage                  # points at /run/log/journal
#     journalctl --header | grep 'File path'   # all files under /run -> tmpfs
#     systemd-analyze cat-config systemd/journald.conf | grep -n Storage
#         # shows /etc/systemd/journald.conf.d/99-lab-tuning.conf overriding
#         # the main file. Drop-ins are read after the main config and the LAST
#         # assignment wins — editing /etc/systemd/journald.conf would have had
#         # no effect at all, which is the trap.
#
# Fix
#     rm -f /etc/systemd/journald.conf.d/99-lab-tuning.conf
#     # or, if you must keep the drop-in, set inside it:
#     #     Storage=persistent
#     mkdir -p /var/log/journal
#     systemd-tmpfiles --create --prefix /var/log/journal   # correct owner/ACLs
#     systemctl restart systemd-journald
#     journalctl --flush                       # move /run/log/journal -> /var/log/journal
#     journalctl --header | grep -m1 'File path'   # now under /var/log/journal
#
#     Storage= values worth knowing (man 5 journald.conf):
#       volatile   /run/log/journal only — lost on reboot
#       persistent /var/log/journal, created automatically
#       auto       persistent IF /var/log/journal already exists (the default)
#       none       everything is dropped after forwarding
#     `auto` + a missing /var/log/journal is the single most common reason a
#     "default" system silently keeps no history across reboots.
#
# ------------------------------------------------------------------------------
# FAULT 2b — journald is rate limiting
# ------------------------------------------------------------------------------
# Diagnosis
#     for i in $(seq 1 60); do logger -t burst "line $i"; done
#     journalctl -t burst --no-pager | wc -l           # far fewer than 60
#     journalctl -b | grep -i suppress                 # "Suppressed NN messages"
#     systemd-analyze cat-config systemd/journald.conf | grep -i ratelimit
#         # RateLimitIntervalSec=30s / RateLimitBurst=15 in the same drop-in.
#
#     The limit is applied PER UNIT, so one chatty service cannot starve the
#     others — but a value this low silently truncates normal traffic, and the
#     entries are destroyed, not queued.
#
# Fix
#     # removing the drop-in above already fixed this; otherwise restore the
#     # upstream defaults (30 s / 10000) or disable the limiter explicitly:
#     #     RateLimitIntervalSec=30s
#     #     RateLimitBurst=10000
#     #     (RateLimitBurst=0 disables rate limiting entirely)
#     systemctl restart systemd-journald
#     for i in $(seq 1 60); do logger -t burst2 "line $i"; done
#     journalctl --sync && journalctl -t burst2 --no-pager | wc -l   # 60
#
# ------------------------------------------------------------------------------
# FAULT 3 — logrotate skips the application log
# ------------------------------------------------------------------------------
# Diagnosis
#     ls -lh /var/log/labapp/                  # app.log only, growing
#     logrotate -d /etc/logrotate.d/labapp     # -d = dry run, changes nothing
#         error: skipping "/var/log/labapp/app.log" because parent directory has
#         insecure permissions (0777 or wider) or is world writable ... Set "su"
#         directive in config file to tell logrotate which user/group should be
#         used for rotation.
#     ls -ld /var/log/labapp                   # drwxrwxrwx — there it is
#     # Also check state and cron/timer wiring while you are here:
#     cat /var/lib/logrotate/logrotate.status  # (Debian: /var/lib/logrotate/status)
#     systemctl list-timers logrotate.timer    # or /etc/cron.daily/logrotate
#
# Fix (either is correct; the first is the better one)
#     # A. remove the insecure permission — the directory never needed 0777
#     chmod 0755 /var/log/labapp
#     chown root:adm /var/log/labapp           # RHEL: root:root
#
#     # B. or tell logrotate which identity to rotate as, inside the stanza:
#     #     /var/log/labapp/*.log {
#     #         su root adm
#     #         daily
#     #         rotate 7
#     #         ...
#     #     }
#
#     logrotate -d /etc/logrotate.d/labapp     # clean dry run, no error:
#     logrotate -f /etc/logrotate.d/labapp     # force one rotation as proof
#     ls -l /var/log/labapp/                   # app.log + app.log.1
#
#     Note `delaycompress` in the stanza: app.log.1 stays uncompressed for one
#     cycle so a process still holding the old file descriptor can finish
#     writing. Without `copytruncate` or a post-rotate signal, a daemon that
#     keeps the fd open will keep writing to the ROTATED inode — that is the
#     other classic logrotate incident, and the reason `create` exists.
#
# ------------------------------------------------------------------------------
# GRADE AND CLEAN UP
# ------------------------------------------------------------------------------
#     sudo ./108.2-break-and-fix.sh --verify
#     sudo ./108.2-break-and-fix.sh --restore
#
# ------------------------------------------------------------------------------
# EXAM-RELEVANT TAKEAWAYS (108.2)
# ------------------------------------------------------------------------------
#   * journald and rsyslog are two independent sinks. Losing one does not lose
#     the other, and `journalctl` working is not evidence that /var/log is fine.
#   * rsyslog selectors are facility.severity; rules run in parse order; `stop`
#     is final; /etc/rsyslog.d/*.conf is included before the stock rules.
#   * `rsyslogd -N1` validates syntax only. Test behaviour with `logger`.
#   * journald configuration is layered: /usr/lib/systemd/journald.conf.d/ then
#     /etc/systemd/journald.conf then /etc/systemd/journald.conf.d/. Read the
#     effective result with `systemd-analyze cat-config systemd/journald.conf`.
#   * Persistence = Storage=persistent, or Storage=auto plus /var/log/journal;
#     `journalctl --flush` moves the runtime journal across.
#   * logrotate is driven by logrotate.timer (or /etc/cron.daily/logrotate),
#     keeps its bookkeeping in /var/lib/logrotate/, and `-d` is always safe.
# ==============================================================================