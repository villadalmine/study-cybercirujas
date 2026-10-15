#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-2 (201-450) — Topic 200.1: Measure and Troubleshoot Resource Usage
#  Break & Fix laboratory script — weight 5.0
#
#  Reference objective: https://www.lpi.org/our-certifications/exam-201-objectives/
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It plants THREE independent, reversible resource-usage faults on a
#  throwaway lab VM, and then tells the student which symptom to look for.
#  The student must measure first (vmstat, iostat, sar, top, ps, pmap,
#  iotop, uptime, free, /proc) and only then repair.
#
#  Fault 1 — CPU run-queue saturation by a low-visibility process
#            (renamed busy loops + a nice-19 decoy; load average climbs,
#            %steal is zero, so it is NOT the hypervisor).
#  Fault 2 — Memory pressure: an anonymous-memory hog plus a swappiness
#            and overcommit tuning change that makes the box swap early.
#            Symptom: si/so columns in `vmstat` never go quiet.
#  Fault 3 — I/O wait: a synchronous write loop plus a dirty-ratio change
#            that stalls writers. Symptom: %wa in top, high await in
#            `iostat -xz 1`, with low %util attribution confusion.
#
#  SAFETY MODEL
#  ------------
#  * Refuses to run unless the operator confirms a disposable VM.
#  * Refuses to run on a host with an active SSH session count > 1 unless
#    forced, so you do not break a shared box.
#  * Every tunable it changes is saved to a restore file BEFORE changing.
#  * All payload processes live in their own cgroup/scope-free PID file list
#    and are capped: the memory hog is sized from MemAvailable, never more
#    than 60% of it, and the CPU hogs never exceed (nproc - 1).
#  * The I/O payload writes ONLY inside its own directory under /var/tmp,
#    is size-capped, and is deleted by `--fix`.
#  * `--fix` (the instructor escape hatch) reverts everything.
#  * No package is removed, no system binary is modified, no systemd unit
#    is masked, nothing is written outside the lab directory except the
#    three sysctl values that --fix restores.
#
#  USAGE
#  -----
#    sudo ./200.1-break-and-fix.sh --break         # plant the faults
#    sudo ./200.1-break-and-fix.sh --status        # see what is planted
#    sudo ./200.1-break-and-fix.sh --verify        # did the student fix it?
#    sudo ./200.1-break-and-fix.sh --fix           # instructor restore
#
#  The step-by-step solution is at the END of this file, commented out.
#  Do not read it until you have measured. Measuring is the exam objective;
#  killing the process is the trivial part.
# ============================================================================

set -o errexit
set -o nounset
set -o pipefail

readonly LAB_ID="lpic2-200.1"
readonly LAB_DIR="/var/tmp/${LAB_ID}"
readonly STATE_DIR="${LAB_DIR}/state"
readonly IO_DIR="${LAB_DIR}/io-payload"
readonly PID_FILE="${STATE_DIR}/payload.pids"
readonly SYSCTL_BACKUP="${STATE_DIR}/sysctl.before"
readonly MARKER="${STATE_DIR}/planted.at"
readonly LOGTAG="${LAB_ID}"

# The decoy names. They are deliberately boring so that `top` sorted by
# name tells the student nothing and they are forced to sort by %CPU or
# read /proc/<pid>/cmdline. This mirrors real incidents where the offender
# is named like something legitimate.
readonly CPU_DECOY_NAME="kworker-flush-helper"
readonly MEM_DECOY_NAME="indexer-cache-warm"
readonly IO_DECOY_NAME="journal-rotate-agent"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must run as root (it changes sysctl values). Use sudo."
    fi
}

require_linux_tools() {
    # The lab is only useful if the measuring tools exist. We do NOT install
    # them silently: on the exam the student is expected to know which
    # package provides which tool.
    local missing=()
    local t
    for t in vmstat iostat sar top ps free awk; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        warn "Missing measurement tools: ${missing[*]}"
        warn "Install them before starting the lab:"
        warn "  Debian/Ubuntu: apt-get install -y procps sysstat"
        warn "  RHEL/Fedora:   dnf install -y procps-ng sysstat"
        warn "vmstat/free/top/ps come from procps(-ng); iostat/sar/pidstat from sysstat."
        die "Refusing to plant faults you cannot measure."
    fi
}

confirm_disposable() {
    if [ "${LAB_FORCE:-0}" = "1" ]; then
        warn "LAB_FORCE=1 — skipping the disposable-VM confirmation."
        return 0
    fi

    local sessions
    sessions="$(who 2>/dev/null | wc -l || printf '0')"
    if [ "${sessions}" -gt 1 ]; then
        warn "There are ${sessions} login sessions on this host."
        warn "That usually means this is NOT a private throwaway VM."
    fi

    rule
    printf 'This script will deliberately saturate CPU, memory and disk I/O\n'
    printf 'on THIS machine (%s) and change 3 sysctl values.\n' "$(hostname)"
    printf 'Only run it on a disposable lab VM you can discard or snapshot.\n'
    rule
    printf 'Type exactly: I have a snapshot\n> '
    local answer
    IFS= read -r answer || true
    if [ "${answer}" != "I have a snapshot" ]; then
        die "Not confirmed. Nothing was changed."
    fi
}

# ---------------------------------------------------------------------------
# Sizing: never take the box past the point of no return
# ---------------------------------------------------------------------------

mem_available_kb() {
    awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo
}

mem_total_kb() {
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo
}

# Memory hog size = 60% of MemAvailable, clamped to [256 MiB, 2048 MiB].
# 60% is enough to push the box into reclaim and swap (helped by the
# swappiness change) while leaving the kernel, sshd and the student's
# shell room to breathe. We want a sick VM, not a dead one.
hog_size_mib() {
    local avail_kb size_mib
    avail_kb="$(mem_available_kb)"
    size_mib=$(( avail_kb * 60 / 100 / 1024 ))
    [ "${size_mib}" -lt 256 ]  && size_mib=256
    [ "${size_mib}" -gt 2048 ] && size_mib=2048
    printf '%s' "${size_mib}"
}

# CPU hogs = nproc - 1, clamped to [1, 4]. Leaving one CPU free keeps the
# shell responsive, which is the point: the student must diagnose a loaded
# system, not fight a frozen one.
cpu_hog_count() {
    local n
    n="$(nproc 2>/dev/null || printf '1')"
    n=$(( n - 1 ))
    [ "${n}" -lt 1 ] && n=1
    [ "${n}" -gt 4 ] && n=4
    printf '%s' "${n}"
}

# ---------------------------------------------------------------------------
# sysctl handling — save before change, always
# ---------------------------------------------------------------------------

# The three values we touch and why:
#   vm.swappiness=100            -> the kernel evicts anonymous pages eagerly,
#                                   so si/so appear in vmstat instead of the
#                                   box merely dropping page cache.
#   vm.dirty_ratio=5             -> a writer is throttled much sooner, so
#                                   synchronous writes translate into visible
#                                   %wa / await instead of being absorbed.
#   vm.dirty_background_ratio=2  -> flusher threads start early and stay busy.
readonly -a SYSCTL_KEYS=(
    vm.swappiness
    vm.dirty_ratio
    vm.dirty_background_ratio
)
readonly -a SYSCTL_BROKEN=(
    100
    5
    2
)

save_sysctl() {
    : > "${SYSCTL_BACKUP}"
    local k v
    for k in "${SYSCTL_KEYS[@]}"; do
        v="$(sysctl -n "${k}" 2>/dev/null || printf 'UNKNOWN')"
        printf '%s=%s\n' "${k}" "${v}" >> "${SYSCTL_BACKUP}"
    done
    chmod 0600 "${SYSCTL_BACKUP}"
    log "Saved original sysctl values to ${SYSCTL_BACKUP}"
}

apply_broken_sysctl() {
    local i
    for i in "${!SYSCTL_KEYS[@]}"; do
        sysctl -q -w "${SYSCTL_KEYS[$i]}=${SYSCTL_BROKEN[$i]}" 2>/dev/null \
            || warn "Could not set ${SYSCTL_KEYS[$i]} (container without a writable sysfs?)"
    done
    log "Applied the lab's (bad) VM tuning."
}

restore_sysctl() {
    if [ ! -f "${SYSCTL_BACKUP}" ]; then
        warn "No sysctl backup found; leaving current values as they are."
        return 0
    fi
    local line key value
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        if [ "${value}" = "UNKNOWN" ]; then
            warn "Original value of ${key} was unknown; not restoring it."
            continue
        fi
        sysctl -q -w "${key}=${value}" 2>/dev/null \
            || warn "Could not restore ${key}=${value}"
    done < "${SYSCTL_BACKUP}"
    log "Restored the original sysctl values."
}

# ---------------------------------------------------------------------------
# Payload launchers
# ---------------------------------------------------------------------------

register_pid() {
    printf '%s %s\n' "$1" "$2" >> "${PID_FILE}"
}

# A CPU hog that is a *separate script* with a misleading name. Writing it
# to disk (instead of `bash -c`) is what makes `ps` show a plausible-looking
# command and forces the student to inspect /proc/<pid>/ rather than guess.
write_cpu_payload() {
    cat > "${LAB_DIR}/${CPU_DECOY_NAME}" <<'PAYLOAD'
#!/usr/bin/env bash
# Lab payload: pure user-space CPU burner. No syscalls in the hot loop,
# so it shows up as %us (user time), not %sy — a distinction the student
# is expected to read off `vmstat 1` / `top`.
trap 'exit 0' TERM INT
x=0
while :; do
    x=$(( (x + 1) % 1000000 ))
done
PAYLOAD
    chmod 0755 "${LAB_DIR}/${CPU_DECOY_NAME}"
}

# The memory hog allocates anonymous memory and *touches* it (so it is
# resident, not just mapped) and then holds it. Touching matters: an
# untouched mapping inflates VSZ but not RSS, and the exam objective is
# precisely about telling those apart.
write_mem_payload() {
    cat > "${LAB_DIR}/${MEM_DECOY_NAME}" <<'PAYLOAD'
#!/usr/bin/env bash
# Lab payload: anonymous memory hog. Size in MiB comes from $1.
# Implemented in bash on purpose: a bash array of strings is anonymous
# heap memory, visible in RSS, in /proc/<pid>/status (VmRSS) and in
# `pmap -x <pid>` as [anon] / [heap]. No tmpfs, no file-backed cheat.
trap 'exit 0' TERM INT
size_mib="${1:-256}"
chunk="$(printf 'A%.0s' $(seq 1 1024))"   # 1 KiB string
declare -a hold=()
i=0
target=$(( size_mib * 1024 ))             # number of 1 KiB chunks
while [ "${i}" -lt "${target}" ]; do
    hold+=("${chunk}")
    i=$(( i + 1 ))
done
# Hold the allocation. The sleep loop keeps the process alive without
# burning CPU, so this fault is cleanly separable from fault 1.
while :; do
    sleep 3600 &
    wait $! 2>/dev/null || exit 0
done
PAYLOAD
    chmod 0755 "${LAB_DIR}/${MEM_DECOY_NAME}"
}

# The I/O hog does synchronous writes with conv=fdatasync so each dd
# invocation forces a flush. Combined with vm.dirty_ratio=5 this produces
# real device-level await, not just page-cache churn.
write_io_payload() {
    cat > "${LAB_DIR}/${IO_DECOY_NAME}" <<'PAYLOAD'
#!/usr/bin/env bash
# Lab payload: synchronous write loop. Target directory in $1.
# Size-capped: it rewrites the SAME file, so disk usage stays at ~64 MiB
# no matter how long the lab runs. Filling a student's disk is not a
# teaching moment, it is a different outage.
trap 'rm -f "${1:-/var/tmp}/churn.dat"; exit 0' TERM INT
dir="${1:-/var/tmp}"
mkdir -p "${dir}"
while :; do
    dd if=/dev/zero of="${dir}/churn.dat" bs=1M count=64 \
       conv=fdatasync oflag=append 2>/dev/null || true
    rm -f "${dir}/churn.dat"
    sync
done
PAYLOAD
    chmod 0755 "${LAB_DIR}/${IO_DECOY_NAME}"
}

start_cpu_faults() {
    local count i pid
    count="$(cpu_hog_count)"
    write_cpu_payload
    for i in $(seq 1 "${count}"); do
        setsid "${LAB_DIR}/${CPU_DECOY_NAME}" >/dev/null 2>&1 &
        pid=$!
        register_pid "cpu" "${pid}"
    done
    # The nice-19 decoy. It consumes CPU but yields to everything else, so
    # it is NOT the cause of the latency: it is there to teach the student
    # to read the NI column before killing the first thing they see.
    setsid nice -n 19 "${LAB_DIR}/${CPU_DECOY_NAME}" >/dev/null 2>&1 &
    pid=$!
    register_pid "cpu-decoy-nice19" "${pid}"
    log "Started ${count} CPU hog(s) + 1 nice-19 decoy."
}

start_mem_fault() {
    local size pid
    size="$(hog_size_mib)"
    write_mem_payload
    setsid "${LAB_DIR}/${MEM_DECOY_NAME}" "${size}" >/dev/null 2>&1 &
    pid=$!
    register_pid "mem" "${pid}"
    log "Started memory hog targeting ~${size} MiB of anonymous memory."
}

start_io_fault() {
    local pid
    mkdir -p "${IO_DIR}"
    write_io_payload
    setsid "${LAB_DIR}/${IO_DECOY_NAME}" "${IO_DIR}" >/dev/null 2>&1 &
    pid=$!
    register_pid "io" "${pid}"
    log "Started synchronous I/O writer in ${IO_DIR} (capped at ~64 MiB)."
}

# ---------------------------------------------------------------------------
# The briefing the student actually reads
# ---------------------------------------------------------------------------

print_briefing() {
    cat <<'BRIEF'

======================================================================
 LPIC-2 200.1 — Measure and Troubleshoot Resource Usage
 INCIDENT BRIEFING
======================================================================

You are on call. A single-purpose application server has been paged for
"everything is slow". The application owner says nothing was deployed.
You have shell access and nothing else: no Prometheus, no Grafana, no
APM. Only the tools on the box.

WHAT YOU WILL SEE
-----------------
  1. `uptime` shows a load average far above the CPU count, and it is
     still climbing when you look again a minute later.
  2. `free -m` shows very little free memory and a swap figure that is
     growing. `vmstat 1` shows non-zero si/so columns that never settle.
  3. `top` shows a significant %wa, and interactive commands (even `ls`
     in a cold directory) stall for noticeable fractions of a second.
  4. Nothing in `/var/log` complains. No OOM kill has happened yet.

WHAT YOU MUST ACHIEVE
---------------------
  A. Quantify, with evidence you could paste into a ticket, how the load
     average decomposes: how much is runnable-on-CPU (r) versus blocked
     on I/O (b). State which one dominates.
  B. Identify every offending process BY PID and BY FULL COMMAND LINE,
     and state for each one whether it is burning CPU, resident memory,
     or disk I/O. Three different culprits exist. One of them looks
     guilty in `top` but is NOT causing user-visible latency — say which
     and justify it from a single column of `top`/`ps` output.
  C. Show the memory hog's ANONYMOUS resident footprint specifically,
     distinguishing VSZ from RSS, and name the file under /proc you read
     it from.
  D. Find the three kernel VM tunables that were changed away from this
     distribution's defaults, and explain in one line each why the change
     amplifies the symptom.
  E. Return the system to health: load average back under the CPU count,
     si/so at 0, %wa near 0, and the tunables back to their defaults.
     Make the sysctl fix survive a reboot check (hint: it currently
     would not, because nothing was written to /etc/sysctl.d/).

RULES OF ENGAGEMENT
-------------------
  * `reboot` is not a fix. A reboot here would restore the tunables
     (they were set at runtime only) and hide the whole lesson.
  * Do not use `pkill -f` as your first move. Measure first. On the exam
     and in production, "what was it" matters more than "it stopped".
  * Keep a transcript. Part B expects command output, not conclusions.

TOOLS WORTH REACHING FOR
------------------------
  uptime, /proc/loadavg, /proc/pressure/* (PSI, if your kernel has it)
  vmstat 1 10        — r, b, si, so, wa columns
  top -o %CPU / -o %MEM, then press 'f' to add the NI column
  ps -eo pid,ppid,ni,pcpu,pmem,rss,vsz,stat,comm,args --sort=-pcpu
  pidstat 1 / pidstat -d 1    (sysstat)
  iostat -xz 1       — r/s, w/s, await, aqu-sz, %util per device
  sar -q / sar -r / sar -b    (historical, if sysstat collection is on)
  pmap -x <pid>, /proc/<pid>/status, /proc/<pid>/smaps_rollup
  iotop -o -P       (if installed)
  sysctl -a | grep -E 'swappiness|dirty_'

WHEN YOU THINK YOU ARE DONE
---------------------------
  Run:  sudo ./200.1-break-and-fix.sh --verify

======================================================================

BRIEF
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

do_break() {
    require_root
    require_linux_tools

    if [ -f "${MARKER}" ]; then
        die "The lab is already planted (see ${MARKER}). Run --status or --fix."
    fi

    confirm_disposable

    mkdir -p "${LAB_DIR}" "${STATE_DIR}" "${IO_DIR}"
    chmod 0755 "${LAB_DIR}"
    : > "${PID_FILE}"

    log "Recording a healthy baseline before breaking anything."
    {
        printf '=== baseline captured %s ===\n' "$(date -Is)"
        printf '\n--- uptime ---\n';            uptime
        printf '\n--- free -m ---\n';           free -m
        printf '\n--- vmstat 1 3 ---\n';        vmstat 1 3
        printf '\n--- nproc ---\n';             nproc
        printf '\n--- sysctl (vm) ---\n';       sysctl -a 2>/dev/null | grep -E 'vm.swappiness|vm.dirty_ratio|vm.dirty_background_ratio'
    } > "${STATE_DIR}/baseline.txt" 2>&1 || true
    log "Baseline saved to ${STATE_DIR}/baseline.txt (the student may read it)."

    save_sysctl
    apply_broken_sysctl

    start_cpu_faults
    start_mem_fault
    start_io_fault

    date -Is > "${MARKER}"
    logger -t "${LOGTAG}" "break & fix lab planted on $(hostname)" 2>/dev/null || true

    log "Waiting 20s for the symptoms to develop before briefing the student."
    sleep 20

    print_briefing
}

do_status() {
    rule
    printf 'Lab %s status\n' "${LAB_ID}"
    rule
    if [ ! -f "${MARKER}" ]; then
        printf 'Not planted.\n'
        return 0
    fi
    printf 'Planted at: %s\n' "$(cat "${MARKER}")"
    printf '\nRegistered payloads (role pid alive?):\n'
    local role pid
    while read -r role pid; do
        [ -z "${role:-}" ] && continue
        if kill -0 "${pid}" 2>/dev/null; then
            printf '  %-20s %-8s ALIVE\n' "${role}" "${pid}"
        else
            printf '  %-20s %-8s gone\n' "${role}" "${pid}"
        fi
    done < "${PID_FILE}"
    printf '\nCurrent vm tunables:\n'
    sysctl -n vm.swappiness vm.dirty_ratio vm.dirty_background_ratio 2>/dev/null \
        | paste -d' ' - - - \
        | awk '{printf "  swappiness=%s dirty_ratio=%s dirty_background_ratio=%s\n", $1, $2, $3}'
    printf '\nOriginal values (to restore):\n'
    sed 's/^/  /' "${SYSCTL_BACKUP}" 2>/dev/null || printf '  (no backup file)\n'
    rule
}

do_verify() {
    require_root
    [ -f "${MARKER}" ] || die "The lab was never planted on this host."

    local failures=0
    local role pid

    rule
    printf 'Verifying the repair\n'
    rule

    # 1. No payload process may survive.
    local alive=0
    while read -r role pid; do
        [ -z "${role:-}" ] && continue
        if kill -0 "${pid}" 2>/dev/null; then
            printf 'FAIL  payload still running: role=%s pid=%s\n' "${role}" "${pid}"
            alive=$(( alive + 1 ))
        fi
    done < "${PID_FILE}"
    if [ "${alive}" -eq 0 ]; then
        printf 'PASS  no lab payload process is running.\n'
    else
        failures=$(( failures + 1 ))
    fi

    # 2. Load average must be below the CPU count. We read the 1-minute
    #    figure: it decays with a ~60s time constant, so this also checks
    #    that the student waited and re-measured instead of declaring
    #    victory the instant they ran kill.
    local cpus load1
    cpus="$(nproc)"
    load1="$(awk '{print $1}' /proc/loadavg)"
    if awk -v l="${load1}" -v c="${cpus}" 'BEGIN { exit !(l < c) }'; then
        printf 'PASS  loadavg(1m)=%s is below nproc=%s.\n' "${load1}" "${cpus}"
    else
        printf 'FAIL  loadavg(1m)=%s is not below nproc=%s (wait ~2 min and re-run).\n' \
            "${load1}" "${cpus}"
        failures=$(( failures + 1 ))
    fi

    # 3. The tunables must match what was saved before the break.
    local line key want have bad=0
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        key="${line%%=*}"
        want="${line#*=}"
        [ "${want}" = "UNKNOWN" ] && continue
        have="$(sysctl -n "${key}" 2>/dev/null || printf 'UNKNOWN')"
        if [ "${have}" != "${want}" ]; then
            printf 'FAIL  %s is %s, should be %s\n' "${key}" "${have}" "${want}"
            bad=$(( bad + 1 ))
        fi
    done < "${SYSCTL_BACKUP}"
    if [ "${bad}" -eq 0 ]; then
        printf 'PASS  all three vm tunables are back to their original values.\n'
    else
        failures=$(( failures + 1 ))
    fi

    # 4. Persistence: the fix should survive a reboot.
    if grep -rqs -E 'vm\.(swappiness|dirty_ratio|dirty_background_ratio)' \
            /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null; then
        printf 'PASS  a persistent sysctl entry exists under /etc/sysctl.d/ or /etc/sysctl.conf.\n'
    else
        printf 'NOTE  no persistent sysctl entry found. Acceptable only if you argued\n'
        printf '      that the DEFAULTS need no file — say so in your write-up.\n'
    fi

    # 5. The I/O payload directory must be gone or empty.
    if [ -d "${IO_DIR}" ] && [ -n "$(ls -A "${IO_DIR}" 2>/dev/null)" ]; then
        printf 'FAIL  %s still holds payload files.\n' "${IO_DIR}"
        failures=$(( failures + 1 ))
    else
        printf 'PASS  the I/O payload left no files behind.\n'
    fi

    rule
    if [ "${failures}" -eq 0 ]; then
        printf 'RESULT: repaired. Now write the one-paragraph ticket note:\n'
        printf '        what the symptom was, which column proved it, what you changed.\n'
        rule
        return 0
    fi
    printf 'RESULT: %s check group(s) still failing. Keep measuring.\n' "${failures}"
    rule
    return 1
}

do_fix() {
    require_root
    [ -f "${MARKER}" ] || warn "No marker file; cleaning up whatever is there anyway."

    log "Instructor restore: terminating payloads."
    if [ -f "${PID_FILE}" ]; then
        local role pid
        while read -r role pid; do
            [ -z "${role:-}" ] && continue
            if kill -0 "${pid}" 2>/dev/null; then
                kill -TERM "${pid}" 2>/dev/null || true
            fi
        done < "${PID_FILE}"
        sleep 2
        while read -r role pid; do
            [ -z "${role:-}" ] && continue
            if kill -0 "${pid}" 2>/dev/null; then
                warn "pid ${pid} (${role}) ignored SIGTERM; sending SIGKILL."
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done < "${PID_FILE}"
    fi

    # Catch any orphaned children of the payload scripts by their own
    # distinctive names only. Scoped on purpose: never a bare pkill.
    local name
    for name in "${CPU_DECOY_NAME}" "${MEM_DECOY_NAME}" "${IO_DECOY_NAME}"; do
        pkill -TERM -f "${LAB_DIR}/${name}" 2>/dev/null || true
    done
    sleep 1
    for name in "${CPU_DECOY_NAME}" "${MEM_DECOY_NAME}" "${IO_DECOY_NAME}"; do
        pkill -KILL -f "${LAB_DIR}/${name}" 2>/dev/null || true
    done

    restore_sysctl

    log "Removing the I/O payload data."
    rm -rf -- "${IO_DIR}"

    log "Clearing the planted marker (state and baseline are kept for review)."
    rm -f -- "${MARKER}"

    log "Done. Verify with: uptime; free -m; vmstat 1 5"
    log "Payload scripts and baseline remain in ${LAB_DIR} for review; remove with:"
    log "  rm -rf -- ${LAB_DIR}"
}

usage() {
    cat <<USAGE
LPIC-2 200.1 break & fix — Measure and Troubleshoot Resource Usage

  --break    Plant the faults (asks for confirmation; needs root)
  --status   Show what is planted and which payloads are alive
  --verify   Check whether the student's repair is complete
  --fix      Instructor restore: kill payloads, restore sysctl, clean up
  --help     This text

Environment:
  LAB_FORCE=1   Skip the interactive disposable-VM confirmation.

Run this ONLY on a disposable lab VM.
USAGE
}

main() {
    case "${1:---help}" in
        --break)  do_break  ;;
        --status) do_status ;;
        --verify) do_verify ;;
        --fix)    do_fix    ;;
        --help|-h) usage    ;;
        *) usage; exit 2    ;;
    esac
}

main "${@:-}"

# ============================================================================
#                        S O L U T I O N   —   S P O I L E R
# ============================================================================
#
# Everything below is commented. Read it only after you have produced your own
# transcript. The objective 200.1 is not "kill the process": it is being able
# to say which subsystem is saturated and prove it from a named column.
#
# ----------------------------------------------------------------------------
# STEP 0 — Frame the problem before touching anything
# ----------------------------------------------------------------------------
#
#   $ uptime
#    14:02:11 up 36 min,  2 users,  load average: 6.41, 4.02, 1.77
#
#   $ nproc
#   4
#
# Load 6.41 on 4 CPUs. But load average counts tasks in state R (runnable)
# AND state D (uninterruptible sleep, i.e. blocked on I/O). It does not tell
# you which. This is the single most common misreading on this objective:
# a load of 6 can mean "CPU is full" or "the disk is full of waiting", and
# the remedy is completely different.
#
#   $ cat /proc/loadavg
#   6.41 4.02 1.77 7/312 4812
#          ^^^^^ 7 runnable/running out of 312 total tasks, last PID 4812
#
# ----------------------------------------------------------------------------
# STEP 1 — Decompose the load with vmstat (answers requirement A)
# ----------------------------------------------------------------------------
#
#   $ vmstat 1 5
#   procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
#    r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
#    5  2 412672  51204   3120 128440  184  520   120 65780 1820 3140 71 12  4 13  0
#    4  3 418816  48960   3104 126112  212  608    96 66120 1904 3288 69 13  5 13  0
#    5  2 423936  47112   3096 124908  196  576   108 65904 1876 3202 72 11  4 13  0
#    6  2 429056  46088   3088 123744  224  640   112 66048 1912 3270 70 12  5 13  0
#    5  3 434176  45032   3080 122596  208  592   104 65996 1888 3244 71 12  4 13  0
#
# Read it column by column — ALWAYS discard the first vmstat line, it is an
# average since boot, not a sample:
#
#   r = 5-6   -> more runnable tasks than CPUs. Real CPU saturation.
#   b = 2-3   -> tasks blocked in uninterruptible sleep. Real I/O waiting.
#   us = ~70  -> the CPU burn is USER time, not kernel time. So it is an
#                application loop, not a driver/syscall storm.
#   sy = ~12  -> some kernel time, consistent with the write path.
#   wa = ~13  -> idle-but-waiting-for-I/O. Non-trivial.
#   st = 0    -> %steal is ZERO. The hypervisor is NOT stealing our CPU.
#                This rules out "the cloud provider is throttling us",
#                which is the other classic wrong answer here.
#   si/so     -> both non-zero and SUSTAINED. The box is swapping IN and
#                OUT continuously. swpd is growing sample over sample.
#                A one-off so spike is normal; sustained si+so is thrashing.
#
# Answer to A: the load decomposes as ~5-6 runnable (CPU-bound, user time)
# plus ~2-3 blocked (I/O). CPU dominates numerically, but the %wa and the
# sustained si/so say there are two independent problems, not one.
#
# If your kernel has PSI (4.20+), this is even more direct, because PSI
# measures time lost to each resource rather than counting tasks:
#
#   $ cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io
#   some avg10=78.42 avg60=61.30 avg300=28.14 total=...
#   some avg10=31.07 avg60=22.88 avg300=9.41  total=...
#   full avg10=12.55 avg60=9.02  avg300=3.77  total=...
#   some avg10=44.19 avg60=35.60 avg300=15.02 total=...
#   full avg10=18.73 avg60=14.21 avg300=6.10  total=...
#
# ----------------------------------------------------------------------------
# STEP 2 — Name the CPU culprits (requirement B)
# ----------------------------------------------------------------------------
#
#   $ ps -eo pid,ppid,ni,pcpu,pmem,rss,vsz,stat,comm,args --sort=-pcpu | head -8
#     PID  PPID  NI %CPU %MEM   RSS    VSZ STAT COMMAND         COMMAND
#    4788     1   0 99.4  0.1  3684   8912 Rs   kworker-flush-h /var/tmp/lpic2-200.1/kworker-flush-helper
#    4789     1   0 99.1  0.1  3680   8912 Rs   kworker-flush-h /var/tmp/lpic2-200.1/kworker-flush-helper
#    4790     1   0 98.8  0.1  3688   8912 Rs   kworker-flush-h /var/tmp/lpic2-200.1/kworker-flush-helper
#    4791     1  19 71.2  0.1  3680   8912 RNs  kworker-flush-h /var/tmp/lpic2-200.1/kworker-flush-helper
#    4802     1   0  8.3 46.2 942088 1049216 Ss indexer-cache-w /var/tmp/lpic2-200.1/indexer-cache-warm 1228
#    4810     1   0  4.1  0.1  2112   5944 Ds  journal-rotate-a /var/tmp/lpic2-200.1/journal-rotate-agent /var/tmp/...
#
# Two things to notice, and both are the lesson:
#
#   (a) `comm` is TRUNCATED to 15 characters and looks like a kernel worker.
#       `args` (the full command line, from /proc/<pid>/cmdline) shows the
#       real path under /var/tmp. A genuine kernel thread has PPID 2 and
#       appears in brackets in ps output ([kworker/0:1]); these have PPID 1
#       and a real executable. NEVER identify a process by `comm` alone.
#
#   (b) PID 4791 has NI = 19 and STAT "RNs" (N = low priority). It is the
#       decoy. It burns whatever CPU is otherwise idle and yields to every
#       normal-priority task, so it does NOT create user-visible latency.
#       Killing it changes nothing a user can feel. That is the single
#       column requirement B asks you to justify from: NI (nice value).
#
# Confirm the kernel-thread question directly:
#
#   $ ps -o pid,ppid,comm -p 4788
#     PID  PPID COMMAND
#    4788     1 kworker-flush-h
#
# PPID 1, not 2. Not a kernel thread.
#
# Per-process CPU over time, which is better evidence than one ps snapshot:
#
#   $ pidstat -u 1 3 -p 4788,4789,4790,4791
#   Average:   UID  PID   %usr %system  %guest  %wait   %CPU  CPU  Command
#   Average:     0 4788  99.00    0.33    0.00   0.00  99.33    -  kworker-flush-h
#
# %usr ~99, %system ~0 -> it never enters the kernel. A pure user-space
# loop. Matches us=70 in vmstat.
#
# ----------------------------------------------------------------------------
# STEP 3 — The memory hog, VSZ vs RSS (requirement C)
# ----------------------------------------------------------------------------
#
#   $ free -m
#                  total        used        free      shared  buff/cache   available
#   Mem:            1987        1802          44          12         141          62
#   Swap:           2047         424        1623
#
#   $ grep -E '^(Vm(RSS|Size|Swap)|RssAnon|RssFile|RssShmem)' /proc/4802/status
#   VmSize:  1049216 kB
#   VmRSS:    942088 kB
#   RssAnon:  938904 kB
#   RssFile:     3184 kB
#   RssShmem:       0 kB
#   VmSwap:    102400 kB
#
# This is the distinction the objective wants:
#   VmSize (= VSZ)  virtual address space RESERVED. Can be enormous and
#                   cost nothing; it includes mappings never touched.
#   VmRSS  (= RSS)  pages actually RESIDENT in physical RAM. This is what
#                   competes for memory.
#   RssAnon         the part of RSS that is ANONYMOUS (heap/stack, not
#                   backed by a file). Anonymous pages are the only ones
#                   that can go to SWAP — file-backed pages are just
#                   dropped and re-read. 938 MiB anonymous is why we swap.
#   VmSwap          how much of this process is already swapped out.
#
# The file requirement C asks for: /proc/4802/status (and the cheaper
# aggregate /proc/4802/smaps_rollup).
#
#   $ cat /proc/4802/smaps_rollup
#   00400000-7ffd... ---p 00000000 00:00 0           [rollup]
#   Rss:              942088 kB
#   Pss:              940012 kB
#   Anonymous:        938904 kB
#   Swap:             102400 kB
#
#   $ pmap -x 4802 | tail -3
#   00007f... 1024000  938904  938904 rw---   [ anon ]
#   ...
#   total kB         1049216  942088  940112
#
# Beware of RSS double counting across processes: RSS counts shared pages
# in full for every process that maps them, so summing RSS over all
# processes overshoots. PSS (proportional set size, in smaps_rollup)
# divides shared pages among their users, which is why `smem` exists.
#
# Sort by memory without parsing top:
#
#   $ ps -eo pid,rss,args --sort=-rss | head -4
#     PID   RSS COMMAND
#    4802 942088 /var/tmp/lpic2-200.1/indexer-cache-warm 1228
#
# ----------------------------------------------------------------------------
# STEP 4 — The I/O culprit (requirement B, third process)
# ----------------------------------------------------------------------------
#
#   $ iostat -xz 1 3
#   Device   r/s   rkB/s  w/s     wkB/s  rrqm/s wrqm/s  r_await w_await aqu-sz  %util
#   sda     0.00    0.00  184.00  67584.00   0.00  12.00    0.00   41.60   7.65  99.20
#
# Read these, not %util alone:
#   w_await 41.6 ms  -> each write takes 41 ms to complete. On an SSD that
#                       should be sub-millisecond. The device is the
#                       bottleneck for whoever is waiting on it.
#   aqu-sz 7.65      -> average 7.65 requests in flight/queued. Deep queue.
#   %util 99.2       -> the device was busy ~all the time. On modern
#                       multi-queue NVMe, %util is NOT a saturation
#                       measure (a device can be 100% "utilized" and still
#                       have headroom); await and aqu-sz are the honest
#                       numbers. On a single-queue spindle, %util still
#                       means what it used to.
#
# Attribute the I/O to a PID:
#
#   $ pidstat -d 1 3
#   Time        UID  PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
#   14:09:01      0 4810      0.00  65536.00      0.00      82  journal-rotate-a
#
#   $ iotop -o -P -b -n 2
#   TID  PRIO  USER  DISK READ  DISK WRITE  SWAPIN   IO>    COMMAND
#   4810 be/4  root  0.00 B/s   64.02 M/s   0.00 %  96.11 % journal-rotate-agent
#
# And its state, which is why it contributes to load without using CPU:
#
#   $ ps -o pid,stat,wchan:20,args -p 4810
#     PID STAT WCHAN                ARGS
#    4810 Ds   wait_on_page_writeba /var/tmp/lpic2-200.1/journal-rotate-agent ...
#
# STAT D = uninterruptible sleep. It cannot be killed with SIGTERM while
# it is inside that syscall; the signal is delivered when the syscall
# returns. This is also why `kill -9` sometimes "does not work" on an I/O
# bound process — the process is not ignoring you, it is not scheduled.
#
# What the writer is actually doing, if you want to prove it:
#
#   $ cat /proc/4810/io
#   rchar: 2048
#   wchar: 7247757312
#   write_bytes: 7247757312
#   ...
#
#   $ ls -l /proc/4810/fd
#   lrwx------ 1 root root 64 Oct 15 14:09 1 -> /dev/null
#   lrwx------ 1 root root 64 Oct 15 14:09 3 -> /var/tmp/lpic2-200.1/io-payload/churn.dat
#
# (Or, for the whole system: `lsof +D /var/tmp/lpic2-200.1`, and
# `strace -c -p 4810` to see the write/fdatasync syscall mix.)
#
# ----------------------------------------------------------------------------
# STEP 5 — The three tunables (requirement D)
# ----------------------------------------------------------------------------
#
#   $ sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio
#   vm.swappiness = 100
#   vm.dirty_ratio = 5
#   vm.dirty_background_ratio = 2
#
# Compare against the upstream kernel defaults (60 / 20 / 10 on most
# distributions; check YOUR baseline file, distributions do override):
#
#   $ cat /var/tmp/lpic2-200.1/state/sysctl.before
#   vm.swappiness=60
#   vm.dirty_ratio=20
#   vm.dirty_background_ratio=10
#
# One line each:
#   vm.swappiness=100           The kernel weights evicting anonymous pages
#                               as highly as dropping page cache, so under
#                               pressure it swaps aggressively instead of
#                               shrinking cache. This is what turns memory
#                               pressure into the sustained si/so you saw.
#                               (0 does not disable swap; it only makes the
#                               kernel avoid it until reclaim is desperate.)
#   vm.dirty_ratio=5            A process is BLOCKED (throttled, synchronous
#                               writeback) once dirty pages exceed 5% of
#                               available memory instead of 20%. Writers hit
#                               the wall four times sooner -> state D, %wa.
#   vm.dirty_background_ratio=2 Flusher threads wake at 2% instead of 10%,
#                               so the device is being pushed almost
#                               continuously, keeping aqu-sz and await high.
#
# ----------------------------------------------------------------------------
# STEP 6 — Repair, in the right order (requirement E)
# ----------------------------------------------------------------------------
#
# Stop the offenders first — the tunables only amplify; the processes are
# the cause. Terminate politely, escalate only if needed, and verify.
#
#   # The CPU loops (note: identify by full path, not by comm)
#   $ sudo pkill -TERM -f '/var/tmp/lpic2-200.1/kworker-flush-helper'
#
#   # The memory hog
#   $ sudo pkill -TERM -f '/var/tmp/lpic2-200.1/indexer-cache-warm'
#
#   # The I/O writer. In state D it may not die immediately; give it a
#   # moment to leave the syscall before escalating.
#   $ sudo pkill -TERM -f '/var/tmp/lpic2-200.1/journal-rotate-agent'
#   $ sleep 3
#   $ pgrep -af 'lpic2-200.1' || echo "all payloads gone"
#   $ sudo pkill -KILL -f '/var/tmp/lpic2-200.1/'   # only if something survived
#
# In production you would almost never go straight to SIGKILL on a writer:
# it loses buffered data. SIGTERM, then wait, then escalate.
#
# Restore the tunables at runtime:
#
#   $ sudo sysctl -w vm.swappiness=60
#   $ sudo sysctl -w vm.dirty_ratio=20
#   $ sudo sysctl -w vm.dirty_background_ratio=10
#
# Make it survive a reboot. /etc/sysctl.conf still works but the modern,
# packaging-friendly place is a drop-in file; files are read in lexical
# order, so a numeric prefix makes precedence explicit:
#
#   $ sudo tee /etc/sysctl.d/90-lpic2-200.1-restore.conf >/dev/null <<'EOF'
#   # Restored after the 200.1 resource-usage incident.
#   vm.swappiness = 60
#   vm.dirty_ratio = 20
#   vm.dirty_background_ratio = 10
#   EOF
#   $ sudo sysctl --system        # re-read every sysctl.d file now
#
# Clean up the payload's data and reclaim swap sanity. Do NOT reach for
# swapoff/swapon reflexively: it forces every swapped page back into RAM
# at once and can OOM a tight box. Only do it once the hog is gone and
# `free -m` shows headroom:
#
#   $ rm -rf /var/tmp/lpic2-200.1/io-payload
#   $ free -m                     # confirm available > swap used
#   $ sudo swapoff -a && sudo swapon -a    # optional: drop stale swap
#
# ----------------------------------------------------------------------------
# STEP 7 — Prove the system is healthy again
# ----------------------------------------------------------------------------
#
# Load average is an exponentially damped moving average with a 60 s time
# constant for the 1-minute figure. It does NOT drop the instant you kill
# the processes: expect ~1 minute to fall to ~37% of the excess, several
# minutes to look clean. Re-measure, do not re-declare.
#
#   $ vmstat 1 5
#   procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
#    r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
#    0  0      0 1284112   4120 412880    0    0     0     0  142  288  0  1 99  0  0
#    0  0      0 1284112   4120 412880    0    0     0     0  138  276  0  0 100 0  0
#
#   r=0, b=0, si=0, so=0, bo=0, wa=0, id~100. That is the proof.
#
#   $ uptime
#    14:16:40 up 51 min,  2 users,  load average: 0.21, 2.44, 2.01
#          1-minute figure already under nproc; the 5/15-minute figures
#          still carry the incident, which is expected and is itself
#          evidence of when the incident ended.
#
#   $ sar -q 1 3     # run queue and load, if sysstat collection is enabled
#   $ sar -r 1 3     # memory
#   $ sar -b 1 3     # I/O transfer rate
#   $ sar -W 1 3     # swapping (pswpin/s, pswpout/s) — should be 0.00
#
# Historical sar data (from the collector, /var/log/sa/saNN) is the one
# thing that answers "when did this start?" after the fact:
#
#   $ sar -q -f /var/log/sa/sa15 -s 13:30:00 -e 14:20:00
#
# Then:
#
#   $ sudo ./200.1-break-and-fix.sh --verify
#
# ----------------------------------------------------------------------------
# STEP 8 — What the exam actually tests here, condensed
# ----------------------------------------------------------------------------
#
#   * Load average mixes R and D states. vmstat's r and b columns separate
#     them. Never diagnose from load average alone.
#   * Discard vmstat's first line (since-boot average).
#   * us vs sy vs wa vs st: user loop, kernel/syscall work, idle-waiting-on-
#     disk, and hypervisor theft. Each one points somewhere different.
#   * si/so (swap in/out, vmstat) vs the static "used swap" in free: a large
#     swpd with si=so=0 is harmless history; small sustained si+so is active
#     thrashing and far worse.
#   * buff/cache is NOT lost memory. `available` in `free -m` is the number
#     that matters, and it already accounts for reclaimable cache.
#   * VSZ vs RSS vs anonymous RSS vs PSS; only anonymous pages swap.
#   * %util is a weak saturation signal on multi-queue devices; await and
#     aqu-sz from `iostat -xz 1` are the real ones.
#   * State D explains load without CPU use, and explains why a process
#     seems to ignore signals.
#   * Attribute per process: pidstat -u / -d, iotop -o -P, /proc/<pid>/io,
#     /proc/<pid>/status, pmap -x.
#   * sar is the only one of these that answers questions about the past.
#
# Source for the objective list:
#   https://www.lpi.org/our-certifications/exam-201-objectives/
#
# ============================================================================