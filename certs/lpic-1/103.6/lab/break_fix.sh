#!/usr/bin/env bash
# =============================================================================
#  LPIC-1 v5.0  ·  Exam 101-500  ·  Topic 103.6 "Modify process execution
#  priorities"  (exam weight: 3.12)          ---  BREAK & FIX LAB  ---
#
#  Objective 103.6 -- key files, terms and utilities: nice, ps, renice, top
#  Source: https://www.lpi.org/our-certifications/exam-101-objectives/
#
#  WHAT THIS SCRIPT DOES
#    It builds a small, self-contained CPU-contention scenario, then breaks it
#    on purpose by inverting the scheduling priorities of two workloads:
#      * a latency-sensitive "report generator"  -> started at nice 19
#      * a bulk "batch cruncher" (user lpicbatch) -> started at nice -20
#    plus a login-time handicap applied through pam_limits. The student must
#    restore sane priorities at runtime AND persist the fix, without killing
#    the batch job.
#
#  SAFETY MODEL  (read before running)
#    * DISPOSABLE LAB VM ONLY. Requires root and an explicit confirmation.
#    * Every workload is a pure bash arithmetic loop: no disk writes beyond a
#      few bytes in /run, no network, no memory growth, no package changes.
#    * All lab processes are pinned with taskset to ONE cpu (the last one), so
#      a >=2 vCPU VM stays usable while the lab runs.
#    * A watchdog auto-resets the lab after LAB_TTL_MIN minutes (default 90).
#    * Everything it touches is enumerated in reset(): /opt/lpic-lab-1036,
#      /run/lpic1036, /etc/systemd/system/lpic1036-lab.service,
#      /etc/security/limits.d/99-lpic1036-lab.conf, users lpicbatch/lpicops,
#      /usr/local/bin/lab1036.  Nothing is enabled at boot.
#
#  USAGE
#    ./lab-103.6-break-and-fix.sh break     # arm the lab and print the brief
#    lab1036 brief                          # re-print the mission brief
#    lab1036 status                         # live priority table + throughput
#    lab1036 monitor                        # refreshing view (Ctrl-C to quit)
#    lab1036 restart                        # restart the workloads (persistence test)
#    lab1036 check                          # grade the fix
#    lab1036 reset                          # remove every trace of the lab
#    lab1036 solution                       # print the step-by-step solution
#
#  The full commented solution lives at the bottom of this file.
# =============================================================================

set -Eeuo pipefail

SELF="$(readlink -f "$0")"

LAB_ID="lpic1036"
LAB_ROOT="/opt/lpic-lab-1036"
RUN_DIR="/run/lpic1036"
RATE_FILE="$RUN_DIR/report.rate"
ETC_DIR="$LAB_ROOT/etc"
BIN_DIR="$LAB_ROOT/bin"
CONF="$ETC_DIR/priorities.conf"
STATE="$ETC_DIR/lab.state"
ENVFILE="$ETC_DIR/lab-env.sh"
UNIT_NAME="${LAB_ID}-lab.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
WATCHDOG_UNIT="${LAB_ID}-watchdog"
LIMITS_FILE="/etc/security/limits.d/99-${LAB_ID}-lab.conf"
SHORTCUT="/usr/local/bin/lab1036"
BATCH_USER="lpicbatch"
OPS_USER="lpicops"

LAB_TTL_MIN="${LAB_TTL_MIN:-90}"
PASS_RATIO="${PASS_RATIO:-0.60}"
SAMPLE_INTERVAL=5
BASELINE_SECONDS=18
BATCH_WORKERS_BROKEN=2

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_HDR=$'\033[1m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_BAD=""; C_WARN=""; C_HDR=""; C_OFF=""; }

say()  { printf '%s\n' "$*"; }
hdr()  { printf '%s%s%s\n' "$C_HDR" "$*" "$C_OFF"; }
warn() { printf '%s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

trap 'rc=$?; [[ $rc -ne 0 ]] && printf "%s[trap]%s failed at line %s (exit %s)\n" "$C_BAD" "$C_OFF" "$LINENO" "$rc" >&2; exit $rc' ERR

need_root() { [[ $(id -u) -eq 0 ]] || die "run as root (this lab manipulates scheduling priorities and system users)."; }

use_systemd() { [[ -d /run/systemd/system ]] && have systemctl; }

confirm_lab() {
    local forced="${1:-no}"
    [[ "$forced" == "force" ]] && return 0
    [[ "${LPIC_LAB_CONFIRM:-}" == "1" ]] && return 0
    hdr "=== DESTRUCTIVE LAB SETUP ==="
    say "Host      : $(hostname -f 2>/dev/null || hostname)"
    say "Kernel    : $(uname -r)"
    say "CPUs      : $(nproc)"
    say "Uptime    : $(uptime -p 2>/dev/null || true)"
    say ""
    say "This will create system users, saturate one CPU with busy loops and"
    say "install a deliberately wrong /etc/security/limits.d drop-in."
    say "Run it ONLY on a throwaway lab VM you can rebuild."
    say ""
    printf 'Type exactly BREAK to continue: '
    local answer; read -r answer
    [[ "$answer" == "BREAK" ]] || die "aborted by the operator."
}

# ---------------------------------------------------------------------------
# Installation of the lab payload
# ---------------------------------------------------------------------------

pick_lab_cpu() {
    local last=$(( $(nproc) - 1 ))
    (( last < 0 )) && last=0
    if taskset -c "$last" true 2>/dev/null; then printf '%s' "$last"; else printf ''; fi
}

install_files() {
    mkdir -p "$BIN_DIR" "$ETC_DIR" "$RUN_DIR"
    chmod 755 "$LAB_ROOT" "$BIN_DIR" "$ETC_DIR" "$RUN_DIR"

    cat > "$ENVFILE" <<'EOF'
# LPIC-1 103.6 lab -- shared constants (sourced by the lab workloads).
LAB_ROOT=/opt/lpic-lab-1036
RUN_DIR=/run/lpic1036
RATE_FILE=/run/lpic1036/report.rate
CONF=/opt/lpic-lab-1036/etc/priorities.conf
BATCH_USER=lpicbatch
OPS_USER=lpicops
EOF

    cat > "$BIN_DIR/report-worker.sh" <<'EOF'
#!/usr/bin/env bash
# LPIC-1 103.6 lab -- latency-sensitive workload ("report generator").
# Pure bash arithmetic loop: no I/O, no network, no memory growth. It counts
# how many fixed work units it completes and publishes the rate to RATE_FILE.
set -u
. /opt/lpic-lab-1036/etc/lab-env.sh
mkdir -p "$RUN_DIR" 2>/dev/null || true
UNIT_ITER=${UNIT_ITER:-120000}
INTERVAL=${SAMPLE_INTERVAL:-5}
units=0
window=$SECONDS
while :; do
    for ((i = 0; i < UNIT_ITER; i++)); do :; done
    units=$((units + 1))
    elapsed=$((SECONDS - window))
    if ((elapsed >= INTERVAL)); then
        printf '%s %s %s\n' "$units" "$elapsed" "$$" > "$RATE_FILE.$$"
        mv -f "$RATE_FILE.$$" "$RATE_FILE"
        units=0
        window=$SECONDS
    fi
done
EOF

    cat > "$BIN_DIR/batch-worker.sh" <<'EOF'
#!/usr/bin/env bash
# LPIC-1 103.6 lab -- bulk workload ("nightly batch cruncher"), runs as an
# unprivileged service account. Legitimate work: it must keep running, it just
# must not outrank the interactive workload.
set -u
WORKER_ID="${1:-0}"
while :; do
    for ((i = 0; i < 120000; i++)); do :; done
done
EOF

    cat > "$BIN_DIR/lab-supervisor.sh" <<'EOF'
#!/usr/bin/env bash
# LPIC-1 103.6 lab -- workload supervisor.
#
# Every workload is started from THIS process on purpose: same session, same
# cgroup. nice only arbitrates between tasks that compete inside the same
# scheduling group -- with cgroup v2 the split between two systemd services is
# governed by CPUWeight=, and the kernel autogrouping feature groups tasks by
# session id. Keeping one session makes nice mean exactly what the exam says.
set -u
. /opt/lpic-lab-1036/etc/lab-env.sh
# shellcheck disable=SC1090
. "$CONF"

: "${REPORT_NICE:=0}"
: "${BATCH_NICE:=0}"
: "${BATCH_WORKERS:=0}"
: "${LAB_CPU:=}"

mkdir -p "$RUN_DIR" 2>/dev/null || true
chmod 755 "$RUN_DIR" 2>/dev/null || true
rm -f "$RATE_FILE" 2>/dev/null || true

cleanup() {
    trap - EXIT TERM INT
    pkill -TERM -P $$ 2>/dev/null || true
    pkill -TERM -f "$LAB_ROOT/bin/(report|batch)-worker\.sh" 2>/dev/null || true
    exit 0
}
trap cleanup EXIT TERM INT

pin() {
    if [[ -n "$LAB_CPU" ]]; then taskset -c "$LAB_CPU" "$@"; else "$@"; fi
}

DROP=()
if setpriv --reuid="$BATCH_USER" --regid="$BATCH_USER" --init-groups -- true 2>/dev/null; then
    DROP=(setpriv --reuid="$BATCH_USER" --regid="$BATCH_USER" --init-groups --)
elif command -v runuser >/dev/null 2>&1; then
    DROP=(runuser -u "$BATCH_USER" --)
else
    echo "supervisor: no setpriv/runuser, batch workers stay root-owned" >&2
fi

pin nice -n "$REPORT_NICE" "$LAB_ROOT/bin/report-worker.sh" &

for ((n = 1; n <= BATCH_WORKERS; n++)); do
    pin nice -n "$BATCH_NICE" ${DROP[@]+"${DROP[@]}"} "$LAB_ROOT/bin/batch-worker.sh" "$n" &
done

wait
EOF

    chmod 755 "$BIN_DIR"/*.sh
    cp -f "$SELF" "$BIN_DIR/lab1036.sh"
    chmod 755 "$BIN_DIR/lab1036.sh"
    ln -sf "$BIN_DIR/lab1036.sh" "$SHORTCUT"

    if use_systemd; then
        cat > "$UNIT_PATH" <<EOF
[Unit]
Description=LPIC-1 103.6 break&fix lab workloads
Documentation=https://www.lpi.org/our-certifications/exam-101-objectives/
After=multi-user.target

[Service]
Type=simple
ExecStart=$BIN_DIR/lab-supervisor.sh
KillMode=control-group
TimeoutStopSec=15
Restart=no
# NOTE: no Nice= here on purpose. The priorities are applied by the supervisor
# from $CONF -- that file is the persistence surface of this lab.

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

create_users() {
    local nologin
    nologin="$(command -v nologin || echo /sbin/nologin)"
    if ! id -u "$BATCH_USER" >/dev/null 2>&1; then
        useradd -r -M -s "$nologin" "$BATCH_USER"
        echo "CREATED_BATCH_USER=1" >> "$STATE"
    fi
    if ! id -u "$OPS_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$OPS_USER"
        passwd -l "$OPS_USER" >/dev/null 2>&1 || true
        echo "CREATED_OPS_USER=1" >> "$STATE"
    fi
}

write_conf() {
    local report_nice="$1" batch_nice="$2" workers="$3" cpu="$4"
    cat > "$CONF" <<EOF
# LPIC-1 103.6 lab -- scheduling priorities applied at workload start-up.
# nice range: -20 (most favourable) .. 19 (least favourable); 0 is the default.
# Only a process with CAP_SYS_NICE (root) may set a value below the current one.
REPORT_NICE=$report_nice
BATCH_NICE=$batch_nice
BATCH_WORKERS=$workers
LAB_CPU=$cpu
EOF
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

start_lab() {
    if use_systemd; then
        systemctl start "$UNIT_NAME"
    else
        mkdir -p "$RUN_DIR"
        setsid nohup "$BIN_DIR/lab-supervisor.sh" >"$RUN_DIR/supervisor.log" 2>&1 &
        echo $! > "$RUN_DIR/supervisor.pid"
        disown || true
    fi
}

stop_lab() {
    if use_systemd; then
        systemctl stop "$UNIT_NAME" 2>/dev/null || true
    elif [[ -r "$RUN_DIR/supervisor.pid" ]]; then
        kill "$(cat "$RUN_DIR/supervisor.pid")" 2>/dev/null || true
        rm -f "$RUN_DIR/supervisor.pid"
    fi
    pkill -TERM -f "$BIN_DIR/lab-supervisor\.sh" 2>/dev/null || true
    pkill -TERM -f "$BIN_DIR/(report|batch)-worker\.sh" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "$BIN_DIR/(report|batch)-worker\.sh" 2>/dev/null || true
    return 0
}

arm_watchdog() {
    if use_systemd && have systemd-run; then
        systemctl stop "$WATCHDOG_UNIT.timer" 2>/dev/null || true
        systemd-run --unit="$WATCHDOG_UNIT" --on-active="${LAB_TTL_MIN}min" \
            --description="LPIC-1 103.6 lab auto-reset" \
            "$BIN_DIR/lab1036.sh" reset --force >/dev/null 2>&1 || warn "could not arm the systemd watchdog"
    else
        setsid nohup bash -c "sleep $((LAB_TTL_MIN * 60)); '$BIN_DIR/lab1036.sh' reset --force" \
            >/dev/null 2>&1 & disown || true
    fi
}

disarm_watchdog() {
    if use_systemd; then
        systemctl stop "$WATCHDOG_UNIT.timer" 2>/dev/null || true
        systemctl stop "$WATCHDOG_UNIT.service" 2>/dev/null || true
        systemctl reset-failed "$WATCHDOG_UNIT.service" 2>/dev/null || true
    fi
    pkill -f "sleep $((LAB_TTL_MIN * 60))" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Measurement helpers
# ---------------------------------------------------------------------------

read_rate() {
    local units elapsed wpid now mtime age
    if [[ ! -r "$RATE_FILE" ]]; then printf '0.000'; return 0; fi
    read -r units elapsed wpid < "$RATE_FILE" || { printf '0.000'; return 0; }
    now=$(date +%s); mtime=$(stat -c %Y "$RATE_FILE" 2>/dev/null || echo "$now")
    age=$((now - mtime))
    if (( age > 30 )); then printf '0.000'; return 0; fi   # stale sample == starved
    awk -v u="${units:-0}" -v e="${elapsed:-1}" 'BEGIN { if (e <= 0) e = 1; printf "%.3f", u / e }'
}

rate_age() {
    local now mtime
    [[ -r "$RATE_FILE" ]] || { printf '%s' "-1"; return 0; }
    now=$(date +%s); mtime=$(stat -c %Y "$RATE_FILE" 2>/dev/null || echo "$now")
    printf '%s' "$((now - mtime))"
}

state_get() { local k="$1"; [[ -r "$STATE" ]] || return 0; awk -F= -v k="$k" '$1==k {v=$2} END {print v}' "$STATE"; }
state_set() { local k="$1" v="$2"; touch "$STATE"; sed -i "/^$k=/d" "$STATE"; printf '%s=%s\n' "$k" "$v" >> "$STATE"; }

conf_get() { local k="$1"; [[ -r "$CONF" ]] || return 0; awk -F= -v k="$k" '$1==k {v=$2} END {print v}' "$CONF"; }

report_pids() { pgrep -f "$BIN_DIR/report-worker\.sh" 2>/dev/null || true; }
batch_pids()  { pgrep -u "$BATCH_USER" -f "$BIN_DIR/batch-worker\.sh" 2>/dev/null || true; }

nice_of() { ps -o ni= -p "$1" 2>/dev/null | tr -d ' ' || true; }

measure_baseline() {
    say "Measuring the uncontended baseline throughput (${BASELINE_SECONDS}s, one worker, no batch load)..."
    write_conf 0 0 0 "$(pick_lab_cpu)"
    start_lab
    sleep "$BASELINE_SECONDS"
    local base; base="$(read_rate)"
    stop_lab
    awk -v b="$base" 'BEGIN { exit !(b > 0) }' || die "baseline measurement returned 0 units/s -- the lab workload never ran. Check 'journalctl -u $UNIT_NAME'."
    state_set BASELINE_RATE "$base"
    say "Baseline: $base work units/s"
}

# ---------------------------------------------------------------------------
# The breakage
# ---------------------------------------------------------------------------

apply_breakage() {
    local cpu; cpu="$(pick_lab_cpu)"
    write_conf 19 -20 "$BATCH_WORKERS_BROKEN" "$cpu"

    cat > "$LIMITS_FILE" <<EOF
# LPIC-1 103.6 lab -- deliberately wrong pam_limits drop-in (fault #3).
# 'priority' sets the nice value every process of a NEW login session starts at.
# 'nice' sets the ceiling the user is allowed to lower its nice value down to
# (RLIMIT_NICE, visible as 'ulimit -e'; ceiling = 20 - rlimit).
$OPS_USER        hard    priority        19
$OPS_USER        hard    nice            19
EOF
    chmod 644 "$LIMITS_FILE"

    local observed=""
    observed="$(su - "$OPS_USER" -c 'nice' 2>/dev/null | tr -d ' ')" || true
    if [[ "$observed" == "19" ]]; then
        state_set BREAK3_ACTIVE 1
    else
        state_set BREAK3_ACTIVE 0
        warn "pam_limits does not apply to 'su -' on this system (login shell nice = '${observed:-unknown}')."
        warn "Fault #3 is inert here and will NOT be graded. Faults #1 and #2 are unaffected."
    fi
}

# ---------------------------------------------------------------------------
# Student-facing views
# ---------------------------------------------------------------------------

lab_ps() {
    local pids
    pids="$(pgrep -f "$BIN_DIR/(report|batch)-worker\.sh" 2>/dev/null | tr '\n' ',' || true)"
    pids="${pids%,}"
    if [[ -z "$pids" ]]; then
        say "  (no lab worker processes are running -- 'lab1036 restart' brings them back)"
        return 0
    fi
    ps -o pid,user,ni,pri,psr,sid,pcpu,etimes,args -p "$pids" 2>/dev/null | sed 's/^/  /'
}

do_status() {
    [[ -r "$CONF" ]] || die "the lab is not installed. Run: $SELF break"
    local base cur ratio age
    base="$(state_get BASELINE_RATE)"; base="${base:-0}"
    cur="$(read_rate)"
    age="$(rate_age)"
    ratio="$(awk -v c="$cur" -v b="$base" 'BEGIN { if (b <= 0) print "0.00"; else printf "%.2f", c / b }')"

    hdr "=== LPIC-1 103.6 lab status ==="
    say ""
    hdr "Scheduling picture (NI = nice value, PRI = procps-derived scale, PSR = cpu, SID = session):"
    lab_ps
    say ""
    hdr "Report generator throughput:"
    printf '  baseline (uncontended) : %s units/s\n' "$base"
    printf '  current                : %s units/s   (sample age: %ss)\n' "$cur" "$age"
    printf '  ratio                  : %s   (target: >= %s)\n' "$ratio" "$PASS_RATIO"
    say ""
    hdr "Start-up configuration ($CONF):"
    sed -n '/^[A-Z]/p' "$CONF" | sed 's/^/  /'
    say ""
    hdr "Login-time limits ($LIMITS_FILE):"
    if [[ -r "$LIMITS_FILE" ]]; then grep -v '^#' "$LIMITS_FILE" | grep -v '^[[:space:]]*$' | sed 's/^/  /' || true
    else say "  (file removed)"; fi
    printf '  su - %s -c nice  => %s\n' "$OPS_USER" "$(su - "$OPS_USER" -c 'nice' 2>/dev/null | tr -d ' ' || echo 'n/a')"
    say ""
    say "Grade your fix with:  lab1036 check"
}

do_monitor() {
    say "Refreshing every 3s -- Ctrl-C to quit."
    while :; do
        clear 2>/dev/null || true
        do_status
        sleep 3
    done
}

print_brief() {
    local cpu; cpu="$(conf_get LAB_CPU)"
    cat <<EOF

$(hdr "############################################################")
$(hdr "#  LPIC-1 103.6 -- BREAK & FIX -- INCIDENT BRIEF            #")
$(hdr "############################################################")

  SCENARIO
    A reporting node runs two workloads on the same host:

      * report-worker.sh  -- the interactive/latency-sensitive job that
        produces customer-facing reports. Its throughput is published to
        $RATE_FILE and is what the business measures.

      * batch-worker.sh   -- a bulk cruncher owned by the service account
        '$BATCH_USER'. It is legitimate work with no deadline. It MUST keep
        running; it simply must not outrank the reporting job.

    Somebody "tuned" the node last night. Everything is still running and
    nothing is logging errors -- the reports just stopped coming out.

  SYMPTOM YOU WILL SEE
    * 'lab1036 status' shows the report generator at a small fraction of its
      baseline throughput (often 0.000 units/s, with a stale sample age),
      while the box is 100% busy on cpu ${cpu:-N/A}.
    * 'top' shows the batch processes at the very top with a PR/NI pair far
      below the normal 20/0, and the report process near the bottom.
    * 'uptime' shows a high load average with no I/O wait: this is pure CPU
      starvation caused by scheduling weight, not a hung disk or a leak.
    * Bonus: a shell opened for the operator account '$OPS_USER' starts
      handicapped, and that user cannot fix its own priority.

  YOUR MISSION  (all of it is graded by 'lab1036 check')
    1. Restore the report generator to a nice value of 0 or better.
    2. Demote the batch workers to nice >= 10 WITHOUT killing or stopping
       them -- at least one must still be alive at the end.
    3. Get the report generator's throughput back to >= $PASS_RATIO of its
       measured baseline.
    4. Make the fix survive a restart: 'lab1036 restart' must bring the
       workloads back with the correct priorities.
    5. Make a fresh login session of '$OPS_USER' start at nice <= 0 again.

  RULES OF ENGAGEMENT
    * Do not edit or delete the worker scripts; do not reboot.
    * 'kill', 'systemctl stop' and cpu pinning are not the fix.
    * Use the 103.6 toolbox: nice, renice, ps, top (plus the files that decide
      priorities at start-up and at login).

  USEFUL STARTING POINTS
    lab1036 status
    top          # look at the PR and NI columns
    ps -eo pid,user,ni,pri,psr,pcpu,comm --sort=-pcpu | head
    $(use_systemd && echo "systemctl cat $UNIT_NAME" || echo "cat $RUN_DIR/supervisor.log")
    ls -l $ETC_DIR /etc/security/limits.d/

  WHEN YOU ARE DONE          lab1036 check
  IF YOU ARE STUCK           lab1036 solution
  TO REMOVE THE LAB          lab1036 reset
  AUTO-RESET WATCHDOG        fires in ${LAB_TTL_MIN} minutes

EOF
}

# ---------------------------------------------------------------------------
# Grading
# ---------------------------------------------------------------------------

PASS_COUNT=0; FAIL_COUNT=0
grade() {
    local ok="$1" title="$2" detail="$3"
    if [[ "$ok" == "yes" ]]; then
        printf '  [%sPASS%s] %-52s %s\n' "$C_OK" "$C_OFF" "$title" "$detail"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  [%sFAIL%s] %-52s %s\n' "$C_BAD" "$C_OFF" "$title" "$detail"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

do_check() {
    [[ -r "$CONF" ]] || die "the lab is not installed. Run: $SELF break"
    hdr "=== Grading topic 103.6 lab ==="
    say ""

    local rpids bpids ok detail
    rpids="$(report_pids)"; bpids="$(batch_pids)"

    # 1. the reporting workload is alive
    if [[ -n "$rpids" ]]; then
        grade yes "report generator is running" "pid(s): $(echo "$rpids" | tr '\n' ' ')"
    else
        grade no  "report generator is running" "not found -- run 'lab1036 restart'"
    fi

    # 2. runtime nice of the reporting workload
    ok=yes; detail=""
    if [[ -z "$rpids" ]]; then ok=no; detail="no process"; else
        while read -r p; do
            [[ -n "$p" ]] || continue
            local n; n="$(nice_of "$p")"
            detail+="pid $p ni=$n  "
            [[ -n "$n" ]] && (( n <= 0 )) || ok=no
        done <<< "$rpids"
    fi
    grade "$ok" "report generator runs at nice <= 0" "$detail"

    # 3. the batch workload still exists and has been demoted
    if [[ -n "$bpids" ]]; then
        ok=yes; detail=""
        while read -r p; do
            [[ -n "$p" ]] || continue
            local n; n="$(nice_of "$p")"
            detail+="pid $p ni=$n  "
            [[ -n "$n" ]] && (( n >= 10 )) || ok=no
        done <<< "$bpids"
        grade "$ok" "batch workers still alive at nice >= 10" "$detail"
    else
        grade no "batch workers still alive at nice >= 10" "no $BATCH_USER worker running (killing it is not the fix)"
    fi

    # 4. measured throughput
    local base cur ratio
    base="$(state_get BASELINE_RATE)"; base="${base:-0}"
    cur="$(read_rate)"
    ratio="$(awk -v c="$cur" -v b="$base" 'BEGIN { if (b <= 0) print 0; else printf "%.3f", c / b }')"
    if awk -v r="$ratio" -v t="$PASS_RATIO" 'BEGIN { exit !(r >= t) }'; then
        grade yes "throughput recovered" "$cur/$base units/s = ${ratio} of baseline"
    else
        grade no  "throughput recovered" "$cur/$base units/s = ${ratio} of baseline (need >= $PASS_RATIO; wait ~15s after a renice)"
    fi

    # 5. persistence
    local cr cb
    cr="$(conf_get REPORT_NICE)"; cb="$(conf_get BATCH_NICE)"
    if [[ -n "$cr" && -n "$cb" ]] && (( cr <= 0 )) && (( cb >= 10 )); then
        grade yes "start-up priorities are persisted" "REPORT_NICE=$cr BATCH_NICE=$cb"
    else
        grade no  "start-up priorities are persisted" "REPORT_NICE=${cr:-?} BATCH_NICE=${cb:-?} in $CONF"
    fi

    # 6. login-time handicap (only if pam_limits demonstrably applies here)
    if [[ "$(state_get BREAK3_ACTIVE)" == "1" ]]; then
        local opsnice; opsnice="$(su - "$OPS_USER" -c 'nice' 2>/dev/null | tr -d ' ' || echo '')"
        if [[ -n "$opsnice" ]] && (( opsnice <= 0 )); then
            grade yes "new login session of $OPS_USER starts at nice <= 0" "nice = $opsnice"
        else
            grade no  "new login session of $OPS_USER starts at nice <= 0" "nice = ${opsnice:-unknown} (see $LIMITS_FILE)"
        fi
    else
        printf '  [%sSKIP%s] %-52s %s\n' "$C_WARN" "$C_OFF" "login-time handicap" "pam_limits inert on this host"
    fi

    # informational: scheduling-group sanity
    local rsid bsid
    rsid="$(ps -o sid= -p "$(echo "$rpids" | head -n1)" 2>/dev/null | tr -d ' ' || true)"
    bsid="$(ps -o sid= -p "$(echo "$bpids" | head -n1)" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "$rsid" && -n "$bsid" && "$rsid" != "$bsid" ]]; then
        warn "workers are in different sessions ($rsid vs $bsid): with kernel autogrouping enabled, nice no longer arbitrates between them. Run 'lab1036 restart'."
    fi

    say ""
    if (( FAIL_COUNT == 0 )); then
        printf '%sALL CHECKS PASSED (%s/%s).%s Topic 103.6 objective met. Clean up with: lab1036 reset\n' \
            "$C_OK" "$PASS_COUNT" "$((PASS_COUNT + FAIL_COUNT))" "$C_OFF"
        return 0
    fi
    printf '%s%s of %s checks failed.%s Keep going -- hints: lab1036 solution\n' \
        "$C_BAD" "$FAIL_COUNT" "$((PASS_COUNT + FAIL_COUNT))" "$C_OFF"
    return 1
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

do_reset() {
    need_root
    disarm_watchdog
    stop_lab
    pkill -KILL -u "$BATCH_USER" 2>/dev/null || true

    if use_systemd; then
        systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
        rm -f "$UNIT_PATH"
        systemctl daemon-reload || true
    fi

    rm -f "$LIMITS_FILE" "$SHORTCUT"
    rm -rf "$RUN_DIR"

    [[ "$(state_get CREATED_BATCH_USER)" == "1" ]] && userdel "$BATCH_USER" 2>/dev/null || true
    [[ "$(state_get CREATED_OPS_USER)"   == "1" ]] && userdel -r "$OPS_USER" 2>/dev/null || true

    if [[ "$LAB_ROOT" == "/opt/lpic-lab-1036" && -d "$LAB_ROOT" ]]; then
        rm -rf "$LAB_ROOT"
    fi
    say "Lab removed. Verify with: ps -eo pid,ni,comm --sort=-pcpu | head ; ls /etc/security/limits.d/"
}

do_break() {
    need_root
    for t in nice renice ps pgrep pkill taskset awk useradd; do
        have "$t" || die "missing required tool: $t"
    done
    (( $(nproc) < 2 )) && [[ "${1:-}" != "--force" ]] && \
        die "this VM has a single vCPU: the lab would make your own shell crawl. Re-run with --force if that is acceptable."

    confirm_lab "${LAB_CONFIRM_MODE:-ask}"

    [[ -d "$LAB_ROOT" ]] && { warn "a previous lab instance was found -- resetting it first."; do_reset; }

    mkdir -p "$ETC_DIR"; : > "$STATE"
    install_files
    create_users
    measure_baseline
    apply_breakage
    start_lab
    sleep 8
    arm_watchdog
    print_brief
}

do_solution() {
    sed -n '/^#== SOLUTION START ==/,/^#== SOLUTION END ==/p' "$SELF" | sed -e '1d;$d' -e 's/^#\{1,2\} \{0,1\}//'
}

# ---------------------------------------------------------------------------
main() {
    local cmd="${1:-break}"; shift || true
    case "$cmd" in
        break|arm)     do_break "$@" ;;
        brief)         print_brief ;;
        status)        do_status ;;
        monitor|watch) do_monitor ;;
        check|grade)   do_check ;;
        restart)       need_root; stop_lab; sleep 1; start_lab; sleep 8; say "Workloads restarted from $CONF."; do_status ;;
        reset|clean)   [[ "${1:-}" == "--force" ]] && LAB_CONFIRM_MODE=force; do_reset ;;
        solution)      do_solution ;;
        *)             die "unknown command '$cmd'. Use: break | brief | status | monitor | restart | check | reset | solution" ;;
    esac
}
main "$@"
exit $?

#== SOLUTION START ==
# =============================================================================
#  STEP-BY-STEP SOLUTION  --  LPIC-1 103.6 "Modify process execution priorities"
# =============================================================================
#
#  STEP 0 -- OBSERVE THE SYMPTOM BEFORE TOUCHING ANYTHING
#
#    # lab1036 status
#    # uptime
#     14:22:31 up 12 min, load average: 3.04, 2.51, 1.32
#    # top -b -n 1 | head -n 12
#    top - 14:22:34 up 12 min,  1 user,  load average: 3.04, 2.51, 1.32
#    Tasks: 118 total,   4 running, 114 sleeping,   0 stopped,   0 zombie
#    %Cpu(s): 49.9 us,  0.2 sy,  0.0 ni, 49.8 id,  0.0 wa,  0.0 hi,  0.1 si
#      PID USER      PR  NI    VIRT    RES  %CPU  COMMAND
#     1841 lpicbatch  0 -20    8452   3712  49.7  batch-worker.sh
#     1842 lpicbatch  0 -20    8452   3716  49.6  batch-worker.sh
#     1839 root      39  19    8452   3708   0.2  report-worker.sh
#
#    Read the two priority columns, not %CPU:
#      NI = the nice value you control (-20 .. 19, default 0).
#      PR in top = 20 + NI for normal tasks, so LOWER PR is BETTER;
#         "rt" means a realtime policy, which outranks every nice value.
#    %Cpu(s) shows ~0.0 wa: nothing is blocked on I/O. This is scheduler
#    starvation, and the cause is written in the NI column.
#
#    # ps -eo pid,user,ni,pri,psr,pcpu,etimes,comm --sort=-pcpu | head -n 5
#      PID USER       NI PRI PSR %CPU ETIMES COMMAND
#     1841 lpicbatch -20  39   3 49.7    620 batch-worker.sh
#     1842 lpicbatch -20  39   3 49.6    620 batch-worker.sh
#     1839 root       19   0   3  0.2    638 report-worker.sh
#
#    Note PSR: everything is on the same cpu, so the three tasks really are
#    competing. (ps's PRI is procps' own inverted scale -- higher = better --
#    and its arithmetic differs between procps versions. NI is the field to
#    trust and the one the exam asks about.)
#
#  STEP 1 -- IMMEDIATE MITIGATION AT RUNTIME (renice, no restart)
#
#    Demote the whole batch account in one shot -- renice can target a user
#    (-u), a process group (-g) or PIDs (-p, the default):
#
#      # renice -n 19 -u lpicbatch
#      1001 (user ID) old priority -20, new priority 19
#
#    Promote the reporting job back to the default. Lowering a nice value
#    requires CAP_SYS_NICE, i.e. root:
#
#      # renice -n 0 -p $(pgrep -f report-worker.sh)
#      1839 (process ID) old priority 19, new priority 0
#
#    Prove the classic exam trap first if you want to see it:
#      $ renice -n 0 -p 1839          # as a normal user
#      renice: failed to set priority for 1839 (process ID): Permission denied
#    An unprivileged user may only RAISE its nice value (lower its priority),
#    and the move is irreversible for that user -- even going back to a value
#    it had a second ago is denied.
#
#    Verify, then wait ~10-15 s for a fresh throughput sample:
#      # ps -o pid,user,ni,comm -p $(pgrep -f 'worker\.sh' | tr '\n' ',' | sed 's/,$//')
#      # lab1036 status        # ratio climbs back to ~0.95-1.00
#
#    top can do the same interactively: press 'r', type the PID, then the new
#    nice value (a negative value is only accepted when top runs as root).
#
#  STEP 2 -- MAKE THE FIX SURVIVE A RESTART
#
#    renice only changes running processes. Find where the values come from:
#
#      # systemctl cat lpic1036-lab.service     # no Nice= in the unit...
#      # grep -n '' /opt/lpic-lab-1036/etc/priorities.conf
#      1:REPORT_NICE=19
#      2:BATCH_NICE=-20
#
#      # sed -i 's/^REPORT_NICE=.*/REPORT_NICE=0/;  s/^BATCH_NICE=.*/BATCH_NICE=19/' \
#            /opt/lpic-lab-1036/etc/priorities.conf
#      # lab1036 restart
#      # ps -eo pid,user,ni,comm --sort=-pcpu | head -n 4     # 0 and 19 now
#
#    In the real world the equivalent surfaces are, in order of preference:
#      * systemd:      systemctl edit <unit>   ->  [Service] / Nice=19
#                      systemctl daemon-reload && systemctl restart <unit>
#                      (check it took effect: systemctl show -p Nice <unit>)
#      * SysV / cron:  wrap the command with 'nice -n 19 /path/cmd'
#      * per user:     the 'priority' item in /etc/security/limits.conf
#
#  STEP 3 -- FIX THE LOGIN-TIME HANDICAP (pam_limits)
#
#      # su - lpicops -c 'nice; ulimit -e'
#      19
#      1
#      # cat /etc/security/limits.d/99-lpic1036-lab.conf
#      lpicops        hard    priority        19
#      lpicops        hard    nice            19
#
#    Two different knobs, both set by pam_limits at session open:
#      'priority' = the nice value every process of the session STARTS at.
#      'nice'     = the floor the user is allowed to renice down to; it is
#                   stored as RLIMIT_NICE (ulimit -e) with the mapping
#                   rlimit = 20 - nice, so ceiling_nice = 20 - ulimit -e.
#                   ulimit -e 1  =>  cannot go below nice 19.
#
#      # rm -f /etc/security/limits.d/99-lpic1036-lab.conf
#        # ...or keep the file and set: lpicops hard priority 0 / hard nice 0
#      # su - lpicops -c 'nice; ulimit -e'
#      0
#      20
#
#    pam_limits is evaluated when the session is created: already-open shells
#    keep the old limits. You must log in again -- that is the whole gotcha.
#
#  STEP 4 -- VERIFY AND CLEAN UP
#
#      # lab1036 check       # every criterion must report PASS
#      # lab1036 reset       # removes users, unit, limits file and /opt tree
#
# -----------------------------------------------------------------------------
#  CONCEPT NOTES AND EXAM TRAPS (103.6)
# -----------------------------------------------------------------------------
#  * Range and default: nice goes from -20 (most favourable to the process)
#    to +19 (least favourable); a process inherits its parent's value, and a
#    normal login shell sits at 0. "Nicer" means friendlier to everyone else,
#    therefore a HIGHER number means LOWER priority.
#  * 'nice' starts a command with a modified value; 'renice' changes one that
#    is already running. Both are in coreutils/util-linux respectively.
#  * 'nice cmd' with no option applies an increment of +10, not 0.
#  * A negative value needs '-n': 'nice -n -5 cmd'. The legacy form 'nice -5
#    cmd' means +5, which is the single most common misread on the exam.
#  * util-linux 'renice -n N -p PID' sets an ABSOLUTE value (identical to
#    'renice N -p PID'), while POSIX defines -n as a relative increment. Do
#    not assume portability across Unixes -- read 'man renice' on the box.
#  * renice targets: -p PID (default), -u USER (every process of that user),
#    -g PGID (a whole process group).
#  * Privilege rules: only root (CAP_SYS_NICE) may lower a nice value or go
#    below the RLIMIT_NICE ceiling. A non-root user can only increase it, and
#    cannot undo the increase.
#  * Inheritance is by fork/exec at spawn time. Renicing a parent does NOT
#    renice its already-running children -- that is why 'renice -u' exists.
#  * nice is a WEIGHT, not a reservation. On CFS/EEVDF a nice difference of 1
#    is roughly a 1.25x share ratio; nice 19 vs nice 0 is about 1:68. If a cpu
#    is idle, a nice-19 task still uses 100% of it.
#  * Scope matters in production: nice only arbitrates inside one scheduling
#    group. With cgroup v2 the split between two systemd services is decided
#    by CPUWeight= (systemd), and kernel autogrouping
#    (/proc/sys/kernel/sched_autogroup_enabled, /proc/<pid>/autogroup) groups
#    tasks by session id. This lab deliberately runs every workload inside one
#    service and one session so that nice behaves exactly as documented.
#  * nice does not touch disk priority -- that is ionice(1) with the CFQ/BFQ
#    class model -- and it never outranks a realtime policy set with chrt(1)
#    (SCHED_FIFO/SCHED_RR), which top displays as PR "rt".
#  * Inspection cheat sheet:
#      ps -eo pid,user,ni,pri,psr,pcpu,comm --sort=-pcpu
#      ps -l                       # NI column of the current session
#      top / htop                  # PR and NI columns, 'r' to renice
#      ulimit -e                   # RLIMIT_NICE of the current shell
#      cat /proc/<pid>/stat        # field 19 is the raw nice value
#
#  REFERENCES
#    LPI exam 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
#    nice(1)     https://man7.org/linux/man-pages/man1/nice.1.html
#    renice(1)   https://man7.org/linux/man-pages/man1/renice.1.html
#    ps(1)       https://man7.org/linux/man-pages/man1/ps.1.html
#    top(1)      https://man7.org/linux/man-pages/man1/top.1.html
#    sched(7)    https://man7.org/linux/man-pages/man7/sched.7.html
#    getrlimit(2) RLIMIT_NICE  https://man7.org/linux/man-pages/man2/getrlimit.2.html
#    limits.conf(5) https://man7.org/linux/man-pages/man5/limits.conf.5.html
#    systemd.exec(5) Nice=   https://www.freedesktop.org/software/systemd/man/systemd.exec.html
#== SOLUTION END ==