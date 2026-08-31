#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (Exams 101-500 / 102-500, version 5.0)
#  Topic 108.4 - Manage printers and printing        (exam weight: 0.0)
#
#  BREAK & FIX LABORATORY - CUPS print queue incident simulator
# =============================================================================
#
#  WHAT THIS SCRIPT DOES
#    1. Builds a self-contained CUPS print queue ("lab-printer") whose device
#       URI is a plain file, so nothing is ever sent to real hardware.
#    2. Proves the queue works end to end (baseline).
#    3. Introduces FIVE layered, controlled faults, all of them realistic and
#       all of them reversible.
#    4. Tells the student the symptoms and the objectives - not the commands.
#    5. Can verify the repair (--verify) and undo everything (--restore).
#
#  DESTRUCTIVE. RUN ONLY ON A DISPOSABLE LAB VM.
#    It stops and disables the CUPS service, rewrites /etc/cups/lpoptions and
#    changes the device URI of a queue. Every file it touches is backed up
#    under /var/lib/lpic-lab/108.4/backup, but do not run it on a machine that
#    prints anything you care about.
#
#  REQUIREMENTS
#    - root
#    - packages: cups (scheduler) and cups-client (lp, lpstat, lpadmin,
#      cupsenable, cupsdisable, cupsaccept, cupsreject, cancel, lpq, lprm)
#      Debian/Ubuntu : apt-get install -y cups cups-client
#      RHEL/Fedora   : dnf install -y cups cups-client
#      openSUSE      : zypper install -y cups cups-client
#      Alpine        : apk add cups cups-client
#
#  USAGE
#    ./108.4-break-and-fix.sh --break     # set up the lab and break it (default)
#    ./108.4-break-and-fix.sh --verify    # grade the repair
#    ./108.4-break-and-fix.sh --hints     # three escalating hints
#    ./108.4-break-and-fix.sh --restore   # put everything back to working state
#    ./108.4-break-and-fix.sh --purge     # remove the lab queue and all lab files
#
#    Add --yes (or export LPIC_LAB_CONFIRM=yes) to acknowledge this is a lab VM.
#
#  Reference: LPI Exam 101/102 objectives - https://www.lpi.org/our-certifications/exam-101-objectives/
#             CUPS documentation          - https://openprinting.github.io/cups/
#             cupsd.conf(5), cups-files.conf(5), lpadmin(8), lpstat(1), lp(1)
# =============================================================================

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
export LC_ALL=C

# ------------------------------- constants ----------------------------------
readonly PRINTER="lab-printer"
readonly SPOOL_DIR="/var/spool/cups-lab"
readonly OUT_FILE="/var/spool/cups-lab/lab-printer.out"
readonly GOOD_URI="file:///var/spool/cups-lab/lab-printer.out"
readonly BAD_URI="file:///var/spool/cups-lab-typo/lab-printer.out"
readonly GHOST="office-laser-2f"

readonly LAB_DIR="/var/lib/lpic-lab/108.4"
readonly BACKUP_DIR="${LAB_DIR}/backup"
readonly STATE_FILE="${LAB_DIR}/state.env"

readonly CUPSD_CONF="/etc/cups/cupsd.conf"
readonly CUPS_FILES_CONF="/etc/cups/cups-files.conf"
readonly LPOPTIONS="/etc/cups/lpoptions"

MODE="break"
FORCE="no"
CONFIRM="${LPIC_LAB_CONFIRM:-no}"

# --------------------------------- output -----------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

info()  { printf '%s[ .. ]%s %s\n'  "${C_BLU}" "${C_OFF}" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "${C_GRN}" "${C_OFF}" "$*"; }
warn()  { printf '%s[ !! ]%s %s\n'  "${C_YEL}" "${C_OFF}" "$*" >&2; }
fail()  { printf '%s[FAIL]%s %s\n'  "${C_RED}" "${C_OFF}" "$*"; }
die()   { printf '%s[STOP]%s %s\n'  "${C_RED}" "${C_OFF}" "$*" >&2; exit 1; }
rule()  { printf '%s%s%s\n' "${C_BLD}" "-------------------------------------------------------------------------------" "${C_OFF}"; }
title() { rule; printf '%s%s%s\n' "${C_BLD}" "$*" "${C_OFF}"; rule; }

trap 'rc=$?; [[ $rc -ne 0 ]] && printf "%s[STOP]%s aborted at line %s (exit %s)\n" "${C_RED}" "${C_OFF}" "${LINENO}" "${rc}" >&2; exit $rc' ERR

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------ preflight -----------------------------------
usage() {
    sed -n '3,45p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --break|break)     MODE="break"   ;;
            --verify|verify)   MODE="verify"  ;;
            --restore|restore) MODE="restore" ;;
            --purge|purge)     MODE="purge"   ;;
            --hints|hints)     MODE="hints"   ;;
            --yes|-y)          CONFIRM="yes"  ;;
            --force)           FORCE="yes"    ;;
            -h|--help)         usage          ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
        shift
    done
}

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "this lab must run as root (sudo $0 $*)"
}

need_lab_confirmation() {
    [[ "${MODE}" == "break" || "${MODE}" == "purge" ]] || return 0
    if [[ "${CONFIRM}" != "yes" ]]; then
        cat <<'EOF'

  This script deliberately breaks the printing subsystem of this machine:
  it stops and disables cupsd, rewrites /etc/cups/lpoptions and repoints a
  print queue at a non-existent device.

  Run it ONLY on a throwaway lab VM. Re-run with --yes to confirm.

EOF
        exit 1
    fi
}

need_cups() {
    local missing=()
    have cupsd     || missing+=("cupsd (package: cups)")
    have lpstat    || missing+=("lpstat (package: cups-client)")
    have lpadmin   || missing+=("lpadmin (package: cups-client)")
    have cupsenable|| missing+=("cupsenable (package: cups-client)")
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '%s\n' "Missing components:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        cat <<'EOF' >&2

Install them, then re-run:
  Debian/Ubuntu : apt-get install -y cups cups-client
  RHEL/Fedora   : dnf install -y cups cups-client
  openSUSE      : zypper install -y cups cups-client
  Alpine        : apk add cups cups-client
EOF
        exit 1
    fi
}

guard_real_printers() {
    [[ "${MODE}" == "break" ]] || return 0
    local others
    others="$(lpstat -p 2>/dev/null | awk '$1=="printer"{print $2}' | grep -vx "${PRINTER}" || true)"
    if [[ -n "${others}" && "${FORCE}" != "yes" ]]; then
        warn "this machine already has print queues configured:"
        printf '        %s\n' ${others} >&2
        die "refusing to run on what looks like a real workstation (override with --force)"
    fi
}

# --------------------------- service abstraction ----------------------------
unit_exists() {
    have systemctl || return 1
    systemctl list-unit-files "$1" >/dev/null 2>&1 && \
        systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"
}

cups_units() {
    local u
    for u in cups.service cups.socket cups.path cupsd.service; do
        unit_exists "$u" && printf '%s\n' "$u"
    done
}

cups_start() {
    if have systemctl; then
        local u
        for u in $(cups_units); do systemctl start "$u" >/dev/null 2>&1 || true; done
    elif [[ -x /etc/init.d/cups ]]; then
        /etc/init.d/cups start >/dev/null 2>&1 || true
    elif have rc-service; then
        rc-service cupsd start >/dev/null 2>&1 || true
    fi
    wait_for_scheduler 20
}

cups_stop() {
    if have systemctl; then
        local u
        for u in $(cups_units); do systemctl stop "$u" >/dev/null 2>&1 || true; done
    elif [[ -x /etc/init.d/cups ]]; then
        /etc/init.d/cups stop >/dev/null 2>&1 || true
    elif have rc-service; then
        rc-service cupsd stop >/dev/null 2>&1 || true
    fi
}

cups_restart() { cups_stop; sleep 1; cups_start; }

scheduler_running() { lpstat -r 2>/dev/null | grep -qi 'is running'; }

wait_for_scheduler() {
    local n="${1:-20}"
    while (( n-- > 0 )); do
        scheduler_running && return 0
        sleep 1
    done
    return 1
}

# ------------------------------ state / backup ------------------------------
backup_file() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    local dest="${BACKUP_DIR}${f}"
    mkdir -p "$(dirname "${dest}")"
    [[ -e "${dest}" ]] || cp -a "$f" "${dest}"
}

restore_file() {
    local f="$1" dest="${BACKUP_DIR}${f}"
    if [[ -e "${dest}" ]]; then
        cp -a "${dest}" "$f"
    else
        rm -f "$f"
    fi
}

save_state() {
    mkdir -p "${LAB_DIR}"
    printf '%s=%q\n' "$1" "$2" >> "${STATE_FILE}"
}

load_state() {
    [[ -f "${STATE_FILE}" ]] && . "${STATE_FILE}" || true
}

# ------------------------------ lab build -----------------------------------
enable_file_device() {
    # The "file" backend is refused unless FileDevice is enabled in
    # cups-files.conf. This is what keeps the lab off real hardware.
    backup_file "${CUPS_FILES_CONF}"
    if [[ -f "${CUPS_FILES_CONF}" ]]; then
        if grep -qiE '^[[:space:]]*FileDevice' "${CUPS_FILES_CONF}"; then
            sed -i -E 's/^[[:space:]]*FileDevice.*/FileDevice Yes/I' "${CUPS_FILES_CONF}"
        else
            printf '\n# added by LPIC-1 108.4 lab\nFileDevice Yes\n' >> "${CUPS_FILES_CONF}"
        fi
    else
        printf 'FileDevice Yes\n' > "${CUPS_FILES_CONF}"
    fi
}

prepare_spool() {
    mkdir -p "${SPOOL_DIR}"
    chown root:lp "${SPOOL_DIR}" 2>/dev/null || true
    chmod 0775 "${SPOOL_DIR}"
    : > "${OUT_FILE}"
    chown root:lp "${OUT_FILE}" 2>/dev/null || true
    chmod 0664 "${OUT_FILE}"
    # SELinux (Fedora/RHEL): cupsd_t may write to print_spool_t, not var_spool_t.
    if have getenforce && [[ "$(getenforce 2>/dev/null || echo Disabled)" == "Enforcing" ]]; then
        if have chcon; then
            chcon -R -t print_spool_t "${SPOOL_DIR}" 2>/dev/null \
                && ok "SELinux label print_spool_t applied to ${SPOOL_DIR}" \
                || warn "could not relabel ${SPOOL_DIR} for SELinux; check 'ausearch -m avc -ts recent' if jobs fail"
        fi
    fi
}

pick_driver_args() {
    # Modern CUPS deprecates raw queues; fall back to a text-only PPD.
    local ppd
    for ppd in /usr/share/ppd/cupsfilters/textonly.ppd \
               /usr/share/ppd/cupsfilters/Generic-Text_Only.ppd \
               /usr/share/cups/model/textonly.ppd; do
        [[ -f "${ppd}" ]] && { printf -- '-P\n%s\n' "${ppd}"; return 0; }
    done
    printf -- '-m\nraw\n'
}

create_queue() {
    if lpstat -p "${PRINTER}" >/dev/null 2>&1; then
        info "queue ${PRINTER} already exists, reusing it"
    else
        local args=()
        mapfile -t args < <(pick_driver_args)
        info "creating queue ${PRINTER} -> ${GOOD_URI}"
        lpadmin -p "${PRINTER}" -E -v "${GOOD_URI}" "${args[@]}" \
                -D "LPIC-1 108.4 lab queue" -L "lab VM" 2>/dev/null \
            || die "lpadmin failed to create ${PRINTER}; check /var/log/cups/error_log"
    fi
    lpadmin -p "${PRINTER}" -o printer-error-policy=stop-printer 2>/dev/null || true
    cupsenable "${PRINTER}" 2>/dev/null || true
    cupsaccept "${PRINTER}" 2>/dev/null || true
    lpadmin -d "${PRINTER}" 2>/dev/null || true
}

submit_job() {
    local title="$1" src="${2:-/etc/hostname}"
    lp -d "${PRINTER}" -t "${title}" "${src}" >/dev/null 2>&1 || return 1
}

out_stamp() { stat -c '%Y:%s' "${OUT_FILE}" 2>/dev/null || echo "0:0"; }

wait_for_output() {
    local before="$1" n="${2:-25}" now
    while (( n-- > 0 )); do
        now="$(out_stamp)"
        [[ "${now}" != "${before}" && "${now##*:}" -gt 0 ]] && return 0
        sleep 1
    done
    return 1
}

baseline_check() {
    info "running baseline print test (this must succeed before we break anything)"
    local before; before="$(out_stamp)"
    submit_job "baseline-$$" || die "baseline job was rejected; the lab queue is not usable"
    if wait_for_output "${before}" 25; then
        ok "baseline OK - bytes reached ${OUT_FILE}"
    else
        cancel -a "${PRINTER}" >/dev/null 2>&1 || true
        die "baseline job never reached the device; inspect 'journalctl -u cups' or /var/log/cups/error_log"
    fi
}

# -------------------------------- the breakage ------------------------------
apply_faults() {
    title "Injecting faults"

    # -- FAULT 1: queue paused (jobs accepted, nothing prints) ---------------
    cupsdisable -r "scheduled maintenance - lab fault 1" "${PRINTER}"
    ok "fault 1 applied: queue paused"

    # -- backlog: two jobs parked in the queue so lpq/lpstat -o have content --
    submit_job "monthly-report" /etc/hostname   || true
    submit_job "payroll-export" /etc/os-release || true
    ok "two jobs parked in the queue"

    # -- FAULT 2: queue rejecting new jobs -----------------------------------
    cupsreject -r "queue closed by helpdesk - lab fault 2" "${PRINTER}"
    ok "fault 2 applied: queue not accepting jobs"

    # -- FAULT 3: system default destination points at a ghost printer -------
    backup_file "${LPOPTIONS}"
    save_state LPOPTIONS_EXISTED "$([[ -e "${LPOPTIONS}" ]] && echo yes || echo no)"
    printf 'Default %s\n' "${GHOST}" > "${LPOPTIONS}"
    chmod 0644 "${LPOPTIONS}"
    ok "fault 3 applied: default destination = ${GHOST} (does not exist)"

    # -- FAULT 4: device URI repointed at a path that does not exist ---------
    save_state ORIGINAL_URI "${GOOD_URI}"
    lpadmin -p "${PRINTER}" -v "${BAD_URI}"
    ok "fault 4 applied: device URI = ${BAD_URI}"

    # -- FAULT 5: scheduler stopped and disabled (incl. socket activation) ---
    if have systemctl; then
        local u
        for u in $(cups_units); do
            save_state "ENABLED_${u//[.-]/_}" "$(systemctl is-enabled "$u" 2>/dev/null || echo unknown)"
            systemctl disable "$u" >/dev/null 2>&1 || true
        done
    fi
    cups_stop
    ok "fault 5 applied: cupsd stopped and disabled"

    save_state FAULTS_APPLIED "yes"
}

briefing() {
    cat <<'EOF'

===============================================================================
 LPIC-1 108.4 - BREAK & FIX: "nobody in the office can print"
===============================================================================

SCENARIO
  It is Monday morning. The print server (this VM) serves one queue,
  "lab-printer", which writes to a file device instead of real hardware
  (/var/spool/cups-lab/lab-printer.out). It worked on Friday. This morning a
  colleague "did some maintenance". Nothing prints, and the ticket queue is
  filling up.

  There is MORE THAN ONE FAULT - five, in fact - and they are layered:
  until you clear the outer one you cannot even observe the inner ones.
  Work outside in, exactly as you would in production.

SYMPTOMS YOU WILL SEE (in this order, as you peel the layers)

  1. Any client command fails to talk to the server:
       # lpstat -r
       lpstat: Scheduler is not running
       # lpstat -t
       lpstat: Unable to connect to server: Connection refused
     Note: on systemd distributions cupsd is normally socket-activated, so
     "starting the service" is not automatically the whole answer.

  2. Once the scheduler answers, the queue reports itself paused:
       # lpstat -p lab-printer
       printer lab-printer disabled since <date> -
               scheduled maintenance - lab fault 1
     Two jobs are already parked in it and never move (lpq / lpstat -o).

  3. New submissions are refused outright:
       # lp -d lab-printer /etc/hostname
       lp: Destination "lab-printer" is not accepting jobs.

  4. Printing without -d goes nowhere, because the system default points at a
     printer that does not exist:
       # lpstat -d
       system default destination: office-laser-2f
       # lp /etc/hostname
       lp: Error - The printer or class does not exist.

  5. When you finally release the queue, the job leaves "pending", turns into
     an error, and the queue stops itself again. The scheduler log is explicit:
       # journalctl -u cups -n 20      (or: tail -n 20 /var/log/cups/error_log)
       E [..] [Job 3] Unable to open file "/var/spool/cups-lab-typo/..."
       ...printer-state-message="Unable to open device file ..."
     Because printer-error-policy is stop-printer, one bad job takes the whole
     queue down - a classic production trap.

YOUR OBJECTIVES (all five must hold at the same time)
  A. The CUPS scheduler is running AND starts again after a reboot.
  B. The queue "lab-printer" is enabled (not paused).
  C. The queue "lab-printer" is accepting jobs.
  D. "lpstat -d" reports lab-printer as the system default destination.
  E. A freshly submitted job actually reaches the device: the file
     /var/spool/cups-lab/lab-printer.out is rewritten with new content.
     (You will have to correct the device URI and clear the failed jobs.)

TOOLBOX FOR THIS OBJECTIVE
  lpstat  lpq  lpr  lp  lprm  cancel  lpadmin  lpinfo  lpoptions
  cupsenable  cupsdisable  cupsaccept  cupsreject  cupsctl
  /etc/cups/cupsd.conf   /etc/cups/printers.conf   /etc/cups/lpoptions
  /var/spool/cups/       /var/log/cups/error_log   http://localhost:631/

RULES
  - Do not delete and recreate the queue; repair it in place.
  - Do not edit /etc/cups/printers.conf by hand while cupsd is running:
    the scheduler owns that file and will overwrite you. Use lpadmin.
  - Every change must survive a reboot.

GRADE YOURSELF
  # <this script> --verify        # pass/fail per objective, end-to-end test
  # <this script> --hints         # three escalating hints
  # <this script> --restore       # give up and put the machine back together
===============================================================================

EOF
}

hints() {
    cat <<'EOF'

HINT 1 (orientation)
  Ask the scheduler what it thinks before you change anything:
  "lpstat -t" is the one-shot overview (scheduler, default destination, device
  URIs, queue acceptance, queue state, pending jobs). If it cannot connect,
  the problem is not the queue yet - it is the service, and on systemd the
  unit that answers first is not necessarily cups.service.

HINT 2 (the three queue-level switches)
  A CUPS queue has TWO independent boolean states and the manuals keep them
  apart on purpose:
    - enabled / disabled  -> may the queue send jobs to the device?  (cupsenable/cupsdisable)
    - accepting / rejecting -> may clients put new jobs in?          (cupsaccept/cupsreject)
  "lpstat -p" shows the first, "lpstat -a" shows the second. A third,
  separate setting is which queue is the default destination.

HINT 3 (why the job still fails)
  Compare what the queue points at with what actually exists:
    "lpstat -v"   shows the device URI of every queue
    "lpinfo -v"   shows the URIs the scheduler can actually reach
  Fix it with "lpadmin -p <queue> -v <uri>". Then remember that a failed job
  is still sitting in the spool and that printer-error-policy=stop-printer
  paused the queue a second time: clear the jobs, then release the queue.

EOF
}

# --------------------------------- grading ----------------------------------
verify() {
    title "Grading LPIC-1 108.4 lab"
    local pass=0 total=5

    # A - scheduler running and persistent
    local a_run="no" a_persist="no"
    scheduler_running && a_run="yes"
    if have systemctl; then
        local u
        for u in $(cups_units); do
            case "$(systemctl is-enabled "$u" 2>/dev/null || true)" in
                enabled|enabled-runtime|static|indirect) a_persist="yes" ;;
            esac
        done
    else
        a_persist="yes"   # non-systemd: cannot check reliably, do not penalise
    fi
    if [[ "${a_run}" == "yes" && "${a_persist}" == "yes" ]]; then
        ok "A. scheduler is running and will start at boot"; ((pass++))
    elif [[ "${a_run}" == "yes" ]]; then
        fail "A. scheduler runs now but no cups unit is enabled -> it dies at reboot"
    else
        fail "A. scheduler is NOT running (lpstat -r)"
    fi

    if [[ "${a_run}" != "yes" ]]; then
        fail "remaining checks skipped: the scheduler must answer first"
        printf '\nScore: %s/%s\n\n' "${pass}" "${total}"
        return 1
    fi

    # B - enabled
    if lpstat -p "${PRINTER}" 2>/dev/null | grep -q 'is idle\|now printing\|is processing'; then
        ok "B. queue ${PRINTER} is enabled"; ((pass++))
    else
        fail "B. queue ${PRINTER} is still paused: $(lpstat -p "${PRINTER}" 2>&1 | head -n1)"
    fi

    # C - accepting
    if lpstat -a "${PRINTER}" 2>/dev/null | grep -q 'accepting requests'; then
        ok "C. queue ${PRINTER} is accepting jobs"; ((pass++))
    else
        fail "C. queue ${PRINTER} is rejecting jobs: $(lpstat -a "${PRINTER}" 2>&1 | head -n1)"
    fi

    # D - default destination
    if lpstat -d 2>/dev/null | grep -q "destination: ${PRINTER}\$"; then
        ok "D. system default destination is ${PRINTER}"; ((pass++))
    else
        fail "D. default destination is wrong: $(lpstat -d 2>&1 | head -n1)"
    fi

    # E - end-to-end
    info "E. submitting a real job (up to 30 s)..."
    local before; before="$(out_stamp)"
    if submit_job "grading-$$" /etc/os-release && wait_for_output "${before}" 30; then
        ok "E. end-to-end printing works - ${OUT_FILE} was rewritten"
        printf '     %s\n' "$(head -n1 "${OUT_FILE}" 2>/dev/null | tr -d '\r')"
        ((pass++))
    else
        fail "E. the job never reached the device"
        printf '     device URI now: %s\n' "$(lpstat -v "${PRINTER}" 2>&1 | head -n1)"
        printf '     pending jobs  : %s\n' "$(lpstat -o "${PRINTER}" 2>/dev/null | wc -l)"
        printf '     last log lines:\n'
        (journalctl -u cups -n 5 --no-pager 2>/dev/null || tail -n 5 /var/log/cups/error_log 2>/dev/null || true) | sed 's/^/       /'
    fi

    rule
    if [[ ${pass} -eq ${total} ]]; then
        printf '%sScore: %s/%s - PASS. The print service is healthy.%s\n\n' "${C_GRN}" "${pass}" "${total}" "${C_OFF}"
        return 0
    fi
    printf '%sScore: %s/%s - keep going (--hints for guidance).%s\n\n' "${C_YEL}" "${pass}" "${total}" "${C_OFF}"
    return 1
}

# --------------------------------- restore ----------------------------------
restore() {
    title "Restoring the machine to a working state"
    load_state
    if have systemctl; then
        local u
        for u in $(cups_units); do systemctl enable "$u" >/dev/null 2>&1 || true; done
    fi
    cups_start || warn "scheduler did not come up; check 'systemctl status cups'"
    wait_for_scheduler 20 || die "cupsd is not answering; cannot restore the queue"

    restore_file "${LPOPTIONS}"
    lpadmin -p "${PRINTER}" -v "${GOOD_URI}" 2>/dev/null || true
    cancel -a "${PRINTER}" >/dev/null 2>&1 || true
    cupsaccept "${PRINTER}" 2>/dev/null || true
    cupsenable "${PRINTER}" 2>/dev/null || true
    lpadmin -d "${PRINTER}" 2>/dev/null || true
    prepare_spool
    rm -f "${STATE_FILE}"
    ok "queue ${PRINTER} restored (uri=${GOOD_URI}, enabled, accepting, default)"
    info "run '--verify' to confirm, or '--purge' to remove the lab entirely"
}

purge() {
    title "Purging the lab"
    cups_start || true
    if wait_for_scheduler 15; then
        cancel -a "${PRINTER}" >/dev/null 2>&1 || true
        lpadmin -x "${PRINTER}" 2>/dev/null || true
    fi
    restore_file "${LPOPTIONS}"
    restore_file "${CUPS_FILES_CONF}"
    rm -rf "${SPOOL_DIR}" "${LAB_DIR}"
    cups_restart || true
    ok "lab queue, spool directory, backups and state removed"
}

# ----------------------------------- main -----------------------------------
main() {
    parse_args "$@"
    need_root "$@"
    need_lab_confirmation
    need_cups

    case "${MODE}" in
        hints)   hints ;;
        verify)  verify ;;
        restore) restore ;;
        purge)   purge ;;
        break)
            guard_real_printers
            mkdir -p "${LAB_DIR}" "${BACKUP_DIR}"
            title "Building the lab"
            backup_file "${CUPSD_CONF}"
            enable_file_device
            prepare_spool
            cups_restart || true
            wait_for_scheduler 25 || die "cupsd will not start; fix the base system before running this lab"
            ok "scheduler is running"
            create_queue
            baseline_check
            cancel -a "${PRINTER}" >/dev/null 2>&1 || true
            apply_faults
            briefing
            ;;
    esac
}

main "$@"
exit 0

# =============================================================================
#  SOLUTION - do not read until you have tried it
# =============================================================================
#
#  STEP 0 - Observe before touching anything
#  -----------------------------------------
#    # lpstat -t
#    lpstat: Scheduler is not running
#
#  "lpstat -t" is the single most useful command of this objective: it prints
#  the scheduler status, the default destination, every device URI, every
#  queue's acceptance state, every queue's enabled state and all pending jobs.
#  When it cannot connect, stop diagnosing the queue and go one layer down.
#
#    # systemctl status cups.service cups.socket cups.path
#    # systemctl is-enabled cups.service cups.socket
#    disabled
#    disabled
#
#
#  STEP 1 - FAULT 5: bring the scheduler back, permanently
#  ------------------------------------------------------
#    # systemctl enable --now cups.socket cups.service
#    # systemctl start cups.path 2>/dev/null || true
#    # lpstat -r
#    scheduler is running
#
#  Why the socket too: on systemd distributions cupsd is socket-activated.
#  cups.socket owns /run/cups/cups.sock and TCP 631 and starts cups.service on
#  the first client connection. Enabling only cups.service leaves the machine
#  working now and broken after the next reboot for anything that relies on
#  activation - and "enabled" is objective A of this lab.
#  On a SysV/OpenRC box the equivalent is:
#    # /etc/init.d/cups start ; update-rc.d cups enable      (Debian)
#    # rc-update add cupsd default ; rc-service cupsd start  (Alpine/OpenRC)
#
#
#  STEP 2 - FAULT 1: the queue is paused
#  -------------------------------------
#    # lpstat -p lab-printer
#    printer lab-printer disabled since ... - scheduled maintenance - lab fault 1
#    # lpq -P lab-printer
#    lab-printer is not ready
#    Rank    Owner   Job     File(s)                 Total Size
#    1st     root    1       monthly-report          1024 bytes
#    2nd     root    2       payroll-export          2048 bytes
#
#  Release it:
#    # cupsenable lab-printer
#    # lpstat -p lab-printer
#    printer lab-printer is idle.  enabled since ...
#
#  "disabled" means: the queue keeps ACCEPTING jobs but does not SEND them to
#  the device. That is exactly what you want while you service a printer -
#  users see no error, the work waits. It is also why a paused queue is such a
#  common silent outage.
#
#
#  STEP 3 - FAULT 2: the queue refuses new jobs
#  --------------------------------------------
#    # lpstat -a lab-printer
#    lab-printer not accepting requests since ... - queue closed by helpdesk - lab fault 2
#    # lp -d lab-printer /etc/hostname
#    lp: Destination "lab-printer" is not accepting jobs.
#
#    # cupsaccept lab-printer
#    # lpstat -a lab-printer
#    lab-printer accepting requests since ...
#
#  enabled/disabled and accepting/rejecting are ORTHOGONAL. Memorise the pairs:
#     cupsenable / cupsdisable  -> printing to the device   (lpstat -p)
#     cupsaccept / cupsreject   -> intake of new jobs        (lpstat -a)
#  The legacy System V equivalents are "enable/disable" and "accept/reject";
#  CUPS ships the cups*-prefixed names to avoid clashing with the shell builtin
#  "enable". Both accept "-r 'reason'", and the reason is what the user sees.
#
#
#  STEP 4 - FAULT 3: the default destination points at a ghost
#  ----------------------------------------------------------
#    # lpstat -d
#    system default destination: office-laser-2f
#    # lp /etc/hostname
#    lp: Error - The printer or class does not exist.
#    # grep -r Default /etc/cups/lpoptions ~/.cups/lpoptions 2>/dev/null
#    /etc/cups/lpoptions:Default office-laser-2f
#
#  Fix it. Either set the SERVER-side default (applies to every user):
#    # lpadmin -d lab-printer
#  or the CLIENT-side default in lpoptions (this is what was tampered with):
#    # lpoptions -d lab-printer          # writes ~/.cups/lpoptions for this user
#    # sed -i 's/^Default .*/Default lab-printer/' /etc/cups/lpoptions   # system-wide
#  Cleanest here is to delete the injected line and let the server default win:
#    # rm -f /etc/cups/lpoptions
#    # lpadmin -d lab-printer
#    # lpstat -d
#    system default destination: lab-printer
#
#  Precedence, highest first: the -d/-P option on the command line, then
#  $PRINTER / $LPDEST in the environment, then ~/.cups/lpoptions, then
#  /etc/cups/lpoptions, then the scheduler's default from printers.conf.
#
#
#  STEP 5 - FAULT 4: the device URI points nowhere
#  -----------------------------------------------
#  Submit a job now and it fails, and the queue stops itself again:
#    # lp -d lab-printer /etc/hostname
#    request id is lab-printer-3 (1 file(s))
#    # lpstat -p lab-printer
#    printer lab-printer disabled since ... -
#            Unable to open device file "/var/spool/cups-lab-typo/lab-printer.out"
#    # journalctl -u cups -n 20 --no-pager        # or: tail -20 /var/log/cups/error_log
#    E [...] [Job 3] Unable to open file "/var/spool/cups-lab-typo/lab-printer.out": No such file or directory
#
#  Compare configured URI against reachable URIs:
#    # lpstat -v
#    device for lab-printer: file:///var/spool/cups-lab-typo/lab-printer.out
#    # lpinfo -v | grep -i file
#    file file:///...
#
#  Repoint it (never hand-edit /etc/cups/printers.conf while cupsd runs - the
#  scheduler rewrites that file from memory and your edit disappears):
#    # lpadmin -p lab-printer -v file:///var/spool/cups-lab/lab-printer.out
#    # lpstat -v lab-printer
#    device for lab-printer: file:///var/spool/cups-lab/lab-printer.out
#
#  Clear the poisoned jobs and release the queue again:
#    # lpstat -o lab-printer            # or: lpq -P lab-printer
#    # cancel -a lab-printer            # or: lprm -P lab-printer -   /  cancel lab-printer-3
#    # cupsenable lab-printer
#
#  Note the trap you just walked into: printer-error-policy=stop-printer means
#  a single unprintable job pauses the queue for everybody. In production you
#  often prefer:
#    # lpadmin -p lab-printer -o printer-error-policy=retry-job
#  (values: abort-job, retry-job, retry-current-job, stop-printer)
#
#
#  STEP 6 - Prove it end to end
#  ----------------------------
#    # lp -d lab-printer -t proof /etc/os-release
#    request id is lab-printer-4 (1 file(s))
#    # sleep 3; head -n2 /var/spool/cups-lab/lab-printer.out
#    NAME="Debian GNU/Linux"
#    VERSION_ID="12"
#    # lpstat -t
#    scheduler is running
#    system default destination: lab-printer
#    device for lab-printer: file:///var/spool/cups-lab/lab-printer.out
#    lab-printer accepting requests since ...
#    printer lab-printer is idle.  enabled since ...
#
#    # <this script> --verify
#    Score: 5/5 - PASS
#
#
#  APPENDIX - the rest of the 108.4 toolbox, and what to check next time
#  --------------------------------------------------------------------
#  Legacy BSD/SysV front-ends, all implemented by CUPS:
#    lpr -P queue file / lp -d queue file      submit
#    lpq -P queue      / lpstat -o queue       list jobs
#    lprm -P queue 3   / cancel queue-3        remove a job
#    lpc status                                terse per-queue status
#  Queue administration:
#    lpadmin -p q -E -v <uri> -m everywhere    create/modify (driverless IPP)
#    lpadmin -x q                              delete a queue
#    lpadmin -p q -c group                     add the queue to a class
#    lpoptions -p q -l                         list options and their defaults
#    lpinfo -v / lpinfo -m                     available devices / models
#    cupsctl --debug-logging                   raise LogLevel without editing files
#    cupsctl --remote-any / --share-printers   sharing switches (cupsd.conf)
#  Files that matter:
#    /etc/cups/cupsd.conf     Listen/Port, Browsing, access control, LogLevel
#    /etc/cups/cups-files.conf  User/Group, ErrorLog, FileDevice, SystemGroup
#    /etc/cups/printers.conf  queue database - owned by cupsd, not by you
#    /etc/cups/ppd/<q>.ppd    per-queue driver
#    /var/spool/cups/         c<NNNNN> control files, d<NNNNN>-001 data files
#    /var/log/cups/{error,access,page}_log   (or the journal on systemd distros)
#  Two more failure modes worth rehearsing on this VM:
#    - "Unable to connect to server" after editing cupsd.conf: run
#      "cupsd -t" to test the configuration before restarting.
#    - Remote clients rejected: Listen bound to localhost only, or the
#      <Location /> block still says "Order allow,deny / Allow localhost".
#
#  Sources:
#    LPI 101/102 objectives - https://www.lpi.org/our-certifications/exam-101-objectives/
#    CUPS documentation     - https://openprinting.github.io/cups/
#    man pages              - cupsd.conf(5) cups-files.conf(5) lpadmin(8)
#                             lpstat(1) lp(1) lpr(1) cupsenable(8) cupsaccept(8)
# =============================================================================