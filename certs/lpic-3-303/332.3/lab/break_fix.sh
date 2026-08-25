#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-3 303 Security  |  exam 303-300, version 3.0.0
#  Topic 332.3 - Resource Control                              (exam weight: 5)
#
#  BREAK & FIX LAB - "the service that will not stay up"
#
#  WHAT IT DOES
#    Builds a small self-contained workload unit, proves it healthy, and then
#    breaks it with four *real* resource-control misconfigurations. Each fault
#    lives in a different mechanism and is found with a different tool - that
#    is the whole point of the exercise:
#
#      1. a unit drop-in in /etc with a crippling MemoryMax= / MemorySwapMax=
#      2. a RUNTIME-only property (MemoryHigh=) that survives deleting /etc
#      3. a .slice drop-in with CPUQuota= and TasksMax= starving the subtree
#      4. a PAM limits.d file capping the user's nproc / nofile / fsize
#
#  SAFETY
#    * DISPOSABLE LAB VM ONLY. Run as root.
#    * Creates one system user, two unit files, two drop-in dirs, one
#      limits.d file and - only if pam_limits.so is missing from the su
#      stack - one line in /etc/pam.d/su (backed up first).
#    * Never writes a limit for '*' or for root, so you cannot lock the box.
#    * Never touches a pre-existing user/unit/limits file: it aborts instead.
#    * --reset removes exactly what it created and restores the backups.
#
#  USAGE
#    ./332.3-break-and-fix.sh --break [--force]   install + break + briefing
#    ./332.3-break-and-fix.sh --brief             print the briefing again
#    ./332.3-break-and-fix.sh --check             grade your repair
#    ./332.3-break-and-fix.sh --reset             tear the lab down
#
#  REFERENCE SOURCES (all official)
#    LPI 303-300 objectives . https://www.lpi.org/our-certifications/exam-303-objectives/
#    systemd.resource-control(5) https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html
#    systemd.slice(5) ....... https://www.freedesktop.org/software/systemd/man/systemd.slice.html
#    systemd-cgls(1)/cgtop(1) https://www.freedesktop.org/software/systemd/man/systemd-cgls.html
#    cgroup v2 kernel doc ... https://docs.kernel.org/admin-guide/cgroup-v2.html
#    limits.conf(5) ......... https://man7.org/linux/man-pages/man5/limits.conf.5.html
#    pam_limits(8) .......... https://man7.org/linux/man-pages/man8/pam_limits.8.html
#    getrlimit(2)/prlimit(1)  https://man7.org/linux/man-pages/man2/getrlimit.2.html
# =============================================================================

set -uo pipefail

LAB_ID="lpic303-332-3"
LAB_USER="lpic303lab"
LAB_GECOS="LPIC-3 303 topic 332.3 resource-control lab user"
UNIT="lpic303-workload.service"
SLICE="lpic303lab.slice"
WORKDIR="/usr/local/lib/${LAB_ID}"
STATE_DIR="/var/lib/${LAB_ID}"
BACKUP_DIR="${STATE_DIR}/backups"
BACKUP_LIST="${STATE_DIR}/backups.list"
MANIFEST="${STATE_DIR}/created.list"
LIMITS_FILE="/etc/security/limits.d/99-${LAB_ID}.conf"
UNIT_DROPIN="/etc/systemd/system/${UNIT}.d"
SLICE_DROPIN="/etc/systemd/system/${SLICE}.d"
RUNTIME_STATE="/run/${LAB_ID}/state"
TARGET_MB=192
FORCE=0
ACTION="help"

# ----------------------------------------------------------------------------
# output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
say()  { printf '%s[ lab ]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[fail ]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "-----------------------------------------------------------------------------"; }

record()  { mkdir -p "$STATE_DIR"; printf '%s\n' "$1" >> "$MANIFEST"; }

backup_file() {
    local src="$1" dest
    [[ -e "$src" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    dest="${BACKUP_DIR}/${src//\//_}"
    cp -a -- "$src" "$dest" || die "cannot back up $src"
    printf '%s\t%s\n' "$src" "$dest" >> "$BACKUP_LIST"
    say "backed up $src -> $dest"
}

# ----------------------------------------------------------------------------
# cgroup helpers - ask systemd where the unit lives, then read the kernel files
# ----------------------------------------------------------------------------
cgroup_v2() { [[ -f /sys/fs/cgroup/cgroup.controllers ]]; }

cg_path() {
    # $1 = unit name -> absolute path of its cgroup directory (v2), or empty
    local rel
    rel="$(systemctl show -p ControlGroup --value "$1" 2>/dev/null)"
    [[ -n "$rel" && "$rel" != "/" ]] || return 1
    cgroup_v2 || return 1
    printf '/sys/fs/cgroup%s\n' "$rel"
}

cg_read() {
    # $1 = unit, $2 = cgroup attribute file -> value or empty
    local base
    base="$(cg_path "$1")" || return 1
    [[ -r "${base}/$2" ]] || return 1
    cat "${base}/$2"
}

# ----------------------------------------------------------------------------
# preflight
# ----------------------------------------------------------------------------
need_root() { [[ "$(id -u)" -eq 0 ]] || die "run this as root on a disposable lab VM"; }

confirm() {
    (( FORCE )) && return 0
    [[ "${LPIC303_LAB_CONFIRM:-}" == "yes" ]] && return 0
    hr
    printf 'This will DELIBERATELY break resource control on THIS machine:\n'
    printf '  host   : %s\n' "$(hostname)"
    printf '  creates: user %s, %s, %s, %s\n' "$LAB_USER" "$UNIT" "$SLICE" "$LIMITS_FILE"
    printf 'Only run it on a throwaway lab VM.\n'
    hr
    local ans=""
    read -r -p 'Type exactly "BREAK MY LAB VM" to continue: ' ans
    [[ "$ans" == "BREAK MY LAB VM" ]] || die "aborted, nothing was changed"
}

preflight() {
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found - this lab needs systemd"
    [[ -d /run/systemd/system ]] || die "systemd is not the running init"
    command -v useradd  >/dev/null 2>&1 || die "useradd not found (shadow-utils)"

    if id "$LAB_USER" >/dev/null 2>&1; then
        getent passwd "$LAB_USER" | grep -q "$LAB_GECOS" \
            || die "user $LAB_USER already exists and is not ours - aborting"
    fi
    for f in "$LIMITS_FILE" "$UNIT_DROPIN" "$SLICE_DROPIN"; do
        [[ -e "$f" && ! -e "${STATE_DIR}/installed" ]] && die "$f already exists - run --reset first"
    done

    local avail_kb
    avail_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    (( avail_kb > 786432 )) || die "need ~768 MiB of available RAM, have $((avail_kb/1024)) MiB"

    if cgroup_v2; then
        ok "cgroup v2 (unified) detected - /sys/fs/cgroup/<slice>/<unit>/"
    else
        warn "cgroup v1 or hybrid detected. The lab still works (systemd translates the"
        warn "properties), but the kernel files differ: memory.limit_in_bytes instead of"
        warn "memory.max, cpu.cfs_quota_us instead of cpu.max, and the controllers are"
        warn "mounted separately under /sys/fs/cgroup/<controller>/. See cgroups(7)."
    fi

    if systemd-detect-virt -c >/dev/null 2>&1; then
        warn "running inside a container ($(systemd-detect-virt -c)). Resource control may"
        warn "be restricted by the host's cgroup delegation. A real VM is recommended."
    fi

    # UnitPath precedence: install the "vendor" units where a drop-in in /etc
    # can legitimately override them (systemd.unit(5), Unit File Load Path).
    if systemd-analyze unit-paths 2>/dev/null | grep -qx '/usr/local/lib/systemd/system'; then
        UNIT_DIR="/usr/local/lib/systemd/system"
    else
        UNIT_DIR="/etc/systemd/system"
        warn "/usr/local/lib/systemd/system is not in the unit load path; using /etc."
    fi
    say "unit files will be installed in ${UNIT_DIR}"
}

# ----------------------------------------------------------------------------
# lab installation (the HEALTHY baseline)
# ----------------------------------------------------------------------------
install_lab() {
    mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$WORKDIR" "$UNIT_DIR"
    record "$WORKDIR"
    record "$STATE_DIR"

    if ! id "$LAB_USER" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash --comment "$LAB_GECOS" "$LAB_USER" \
            || die "useradd $LAB_USER failed"
        passwd -l "$LAB_USER" >/dev/null 2>&1
        ok "created unprivileged lab user: $LAB_USER (password locked)"
    fi

    cat > "${WORKDIR}/workload.sh" <<'WORKLOAD'
#!/usr/bin/env bash
# Memory + CPU workload for the LPIC-3 303 / 332.3 Resource Control lab.
# It allocates N MiB of anonymous memory, then holds it and burns a little CPU
# so that both memory limits and CPU throttling are directly observable.
set -u
target_mb="${1:-192}"
state="${RUNTIME_DIRECTORY:-/tmp}/state"

echo "workload: pid=$$ uid=$(id -u) target=${target_mb} MiB"
echo "STARTING 0" > "$state"

# one megabyte of non-shareable, non-reclaimable-without-swap payload
chunk="$(head -c 1048576 /dev/zero | tr '\0' 'x')"

declare -a buf=()
for (( i = 0; i < target_mb; i++ )); do
    buf[i]="$chunk"
    if (( (i + 1) % 8 == 0 )); then
        echo "workload: allocated $((i + 1)) MiB"
        echo "ALLOCATING $((i + 1))" > "$state"
    fi
done

echo "workload: ALLOCATED ${target_mb} MiB - entering steady state"
echo "ALLOCATED ${target_mb}" > "$state"

start="$SECONDS"; beat=0
while :; do
    for (( j = 0; j < 200000; j++ )); do :; done   # measurable CPU, no busy spin
    beat=$((beat + 1))
    echo "workload: heartbeat ${beat} (alive $((SECONDS - start))s, ${#buf[@]} MiB held)"
    echo "HEARTBEAT ${beat}" > "$state"
    sleep 1
done
WORKLOAD
    chmod 0755 "${WORKDIR}/workload.sh"
    record "${WORKDIR}/workload.sh"

    cat > "${UNIT_DIR}/${SLICE}" <<SLICEUNIT
[Unit]
Description=LPIC-3 303 / 332.3 resource-control lab slice
Documentation=man:systemd.slice(5) man:systemd.resource-control(5)
Before=slices.target

[Slice]
# Accounting only: enabling it costs a little CPU but makes the subtree visible
# in systemd-cgtop and populates cpu.stat / memory.current / pids.current.
CPUAccounting=yes
MemoryAccounting=yes
TasksAccounting=yes
IOAccounting=yes
SLICEUNIT
    record "${UNIT_DIR}/${SLICE}"

    cat > "${UNIT_DIR}/${UNIT}" <<UNITFILE
[Unit]
Description=LPIC-3 303 / 332.3 lab workload (memory + CPU)
Documentation=https://www.lpi.org/our-certifications/exam-303-objectives/
After=network.target

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
Slice=${SLICE}
RuntimeDirectory=${LAB_ID}
ExecStart=${WORKDIR}/workload.sh ${TARGET_MB}
Restart=on-failure
RestartSec=5s
# NOTE: no PAMName= here. A plain systemd service never traverses the PAM
# stack, so /etc/security/limits.conf does NOT apply to it - see pam_limits(8).

[Install]
WantedBy=multi-user.target
UNITFILE
    record "${UNIT_DIR}/${UNIT}"

    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1
    touch "${STATE_DIR}/installed"
    ok "installed ${UNIT} and ${SLICE}"
}

wait_for_state() {
    # $1 = token to wait for, $2 = timeout seconds
    local token="$1" timeout="$2" i
    for (( i = 0; i < timeout; i++ )); do
        [[ -r "$RUNTIME_STATE" ]] && grep -q "^${token}" "$RUNTIME_STATE" && return 0
        systemctl is-failed --quiet "$UNIT" && return 1
        sleep 1
    done
    return 1
}

baseline() {
    say "starting the workload UNRESTRICTED to prove the VM is healthy..."
    systemctl restart "$UNIT" || die "the unit does not start even unrestricted - investigate before breaking"
    if wait_for_state "ALLOCATED" 150; then
        ok "baseline healthy: ${TARGET_MB} MiB allocated, unit active"
        say "memory.current now: $(cg_read "$UNIT" memory.current 2>/dev/null || echo 'n/a (cgroup v1)')"
    else
        systemctl status "$UNIT" --no-pager -l | sed 's/^/    /'
        die "baseline failed - the fault would not be attributable to this lab. Run --reset."
    fi
}

# ----------------------------------------------------------------------------
# the four faults
# ----------------------------------------------------------------------------
ensure_pam_limits() {
    local su_file="/etc/pam.d/su"
    if grep -Rqs 'pam_limits\.so' /etc/pam.d/ 2>/dev/null; then
        if grep -Rqs 'pam_limits\.so' "$su_file" /etc/pam.d/system-auth \
               /etc/pam.d/common-session /etc/pam.d/system-login 2>/dev/null; then
            say "pam_limits.so already active in the su stack"
            return 0
        fi
    fi
    [[ -f "$su_file" ]] || { warn "no /etc/pam.d/su - fault 4 may not be observable via su"; return 0; }
    backup_file "$su_file"
    printf 'session    required    pam_limits.so    # added by %s lab\n' "$LAB_ID" >> "$su_file"
    warn "pam_limits.so was missing from the su stack; appended it to $su_file (backed up)"
}

apply_faults() {
    say "applying fault 1/4 - unit drop-in with a crippling memory ceiling"
    mkdir -p "$UNIT_DROPIN"
    cat > "${UNIT_DROPIN}/10-memory-limits.conf" <<'DROPIN'
# "Hardening" applied during a memory incident and never revisited.
[Service]
MemoryAccounting=yes
MemoryMax=24M
MemorySwapMax=0
DROPIN
    record "${UNIT_DROPIN}/10-memory-limits.conf"

    say "applying fault 2/4 - a RUNTIME-only property (survives deleting /etc)"
    systemctl daemon-reload
    systemctl set-property --runtime "$UNIT" MemoryHigh=32M >/dev/null 2>&1 \
        || warn "set-property --runtime failed (old systemd?) - fault 2 skipped"

    say "applying fault 3/4 - slice drop-in with CPUQuota= and TasksMax="
    mkdir -p "$SLICE_DROPIN"
    cat > "${SLICE_DROPIN}/10-cpu-tasks.conf" <<'SDROPIN'
# Copy-pasted from a "noisy neighbour" runbook onto the wrong slice.
[Slice]
CPUQuota=5%
TasksMax=8
SDROPIN
    record "${SLICE_DROPIN}/10-cpu-tasks.conf"

    say "applying fault 4/4 - PAM limits for ${LAB_USER} (login sessions only)"
    mkdir -p /etc/security/limits.d
    cat > "$LIMITS_FILE" <<LIMITS
# LPIC-3 303 / 332.3 lab. Deliberately hostile, scoped to one throwaway user.
# Format: <domain> <type> <item> <value>   - see limits.conf(5)
${LAB_USER}   hard   nproc    12
${LAB_USER}   soft   nproc    12
${LAB_USER}   hard   nofile   16
${LAB_USER}   soft   nofile   16
${LAB_USER}   hard   fsize    1024
${LAB_USER}   soft   fsize    1024
LIMITS
    chmod 0644 "$LIMITS_FILE"
    record "$LIMITS_FILE"
    ensure_pam_limits

    systemctl daemon-reload
    systemctl restart "$SLICE" >/dev/null 2>&1
    systemctl reset-failed "$UNIT" >/dev/null 2>&1
    systemctl restart "$UNIT" >/dev/null 2>&1
    say "faults applied; giving the unit 45 s to misbehave..."
    sleep 45
    ok "the lab is now broken - read the briefing below"
}

# ----------------------------------------------------------------------------
# briefing
# ----------------------------------------------------------------------------
briefing() {
    hr
    cat <<'BRIEF'
 LPIC-3 303-300 v3.0.0  |  Topic 332.3 Resource Control  |  BREAK & FIX

 THE STORY
   lpic303-workload.service is a memory-resident worker that must hold 192 MiB
   and emit a heartbeat every second. Last quarter somebody "hardened" the box
   during an incident. Nobody wrote it down. The service has not been healthy
   since, and the operator account lpic303lab can barely work interactively.

 THE SYMPTOMS YOU WILL SEE
   1) The unit never reaches its steady state. It is killed while allocating
      and restarted, over and over:

        # systemctl status lpic303-workload.service
          Active: activating (auto-restart) (Result: oom-kill)
        # journalctl -u lpic303-workload.service -b | tail
          workload: allocated 16 MiB
          systemd[1]: lpic303-workload.service: A process of this unit has been
            killed by the OOM killer.
          systemd[1]: lpic303-workload.service: Failed with result 'oom-kill'.

      After enough retries it may stop trying altogether:
          "Start request repeated too quickly."  ->  Active: failed

   2) If you widen the memory ceiling but miss the *second* memory fault, the
      unit stays "active" yet makes almost no progress: allocation crawls, the
      heartbeat is minutes apart, and memory pressure is pinned near 100%.

   3) Even with memory fixed, the worker is ~20x slower than it should be, and
      you cannot start ANY second process in its slice:

        # systemd-run --slice=lpic303lab.slice -p User=lpic303lab --wait --pipe \
            /bin/bash -c 'for i in $(seq 1 20); do sleep 5 & done; wait; echo ok'
          bash: fork: retry: Resource temporarily unavailable

   4) Interactively, the operator account is crippled - and note that this is a
      DIFFERENT mechanism from 1-3, with a different blast radius:

        # su - lpic303lab -c 'for i in $(seq 1 30); do sleep 3 & done; wait'
          bash: fork: retry: Resource temporarily unavailable
        # su - lpic303lab -c 'dd if=/dev/zero of=/tmp/p bs=1M count=5'
          File size limit exceeded (core dumped)
        # su - lpic303lab -c 'ulimit -n'
          16

 WHAT YOU MUST ACHIEVE  (run --check to be graded)
   A. lpic303-workload.service is active and has been running >= 60 s with
      ZERO OOM kills, and the journal shows "ALLOCATED 192 MiB".
   B. The unit still carries a DELIBERATE, PERSISTENT memory ceiling between
      256M and 1G. "Fixing" it by removing all resource control is a FAIL:
      this topic is about controlling resources, not abandoning them.
      MemoryHigh must be infinity or >= 256M.
   C. The slice allows at least 50% CPU (or no quota) and at least 64 tasks.
   D. User lpic303lab gets nproc >= 100, nofile >= 1024, fsize unlimited, and
      can really spawn 30 processes and write a 5 MiB file.
   E. Your fix must survive `systemctl daemon-reload` and a reboot.

 RULES
   * Do not mask, disable or edit the ExecStart of the unit.
   * Do not delete or recreate the user, and do not give it a login password.
   * Do not raise limits globally with '*' in limits.conf.
   * Fix the configuration, not the workload.

 TOOLBOX (all of it is exam material)
   systemctl cat|show|set-property|revert|status|daemon-reload
   systemd-cgls   systemd-cgtop   systemd-run   systemd-analyze unit-paths
   journalctl -u <unit> -b
   /sys/fs/cgroup/<slice>/<unit>/{memory.max,memory.high,memory.current,
        memory.events,memory.pressure,cpu.max,cpu.stat,pids.max,pids.events}
   ulimit -a / -H / -S     prlimit --pid <pid>     loginctl user-status
   /etc/security/limits.conf, /etc/security/limits.d/, pam_limits(8)

 HINT THAT COSTS YOU NOTHING
   Ask systemd what is in effect, not the filesystem what is on disk. One of
   the four faults is invisible to `grep -r /etc/systemd` on purpose.

 WHEN YOU ARE DONE
   ./332.3-break-and-fix.sh --check     grade yourself
   ./332.3-break-and-fix.sh --reset     remove the whole lab
   The full worked solution is at the bottom of this script, commented out.
BRIEF
    hr
}

# ----------------------------------------------------------------------------
# grading
# ----------------------------------------------------------------------------
PASS=0
FAIL=0
check() {
    # $1 = description, $2 = 0/1 result, $3 = observed detail
    if (( $2 == 0 )); then
        printf '%s  PASS %s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1))
    else
        printf '%s  FAIL %s %s\n' "$C_R" "$C_0" "$1"; FAIL=$((FAIL+1))
    fi
    [[ -n "${3:-}" ]] && printf '         observed: %s\n' "$3"
}

bytes_of() {
    # "infinity" -> -1 ; "12345" -> 12345 ; anything else -> -2
    case "$1" in
        infinity|max) echo -1 ;;
        ''|*[!0-9]*)  echo -2 ;;
        *)            echo "$1" ;;
    esac
}

do_check() {
    [[ -e "${STATE_DIR}/installed" ]] || die "the lab is not installed - run --break first"
    hr; say "grading topic 332.3 repair"; hr

    # ---- A: the unit is genuinely healthy -----------------------------------
    local active age mono now oomk detail
    active="$(systemctl is-active "$UNIT" 2>/dev/null)"
    mono="$(systemctl show -p ActiveEnterTimestampMonotonic --value "$UNIT" 2>/dev/null)"
    now="$(awk '{printf "%d", $1*1000000}' /proc/uptime)"
    [[ "$mono" =~ ^[0-9]+$ && "$mono" -gt 0 ]] && age=$(( (now - mono) / 1000000 )) || age=0
    if [[ "$active" == "active" && $age -ge 60 ]]; then
        check "A1 unit active and stable for >= 60 s" 0 "active for ${age}s"
    else
        check "A1 unit active and stable for >= 60 s" 1 "state=${active}, uptime=${age}s"
    fi

    if [[ -r "$RUNTIME_STATE" ]] && grep -Eq '^(ALLOCATED|HEARTBEAT)' "$RUNTIME_STATE"; then
        check "A2 workload reached its steady state (192 MiB held)" 0 "$(cat "$RUNTIME_STATE")"
    else
        check "A2 workload reached its steady state (192 MiB held)" 1 \
              "${RUNTIME_STATE}: $( [[ -r "$RUNTIME_STATE" ]] && cat "$RUNTIME_STATE" || echo 'absent' )"
    fi

    oomk="$(cg_read "$UNIT" memory.events 2>/dev/null | awk '/^oom_kill /{print $2}')"
    if [[ -z "$oomk" ]]; then
        oomk="$(journalctl -u "$UNIT" -b --no-pager 2>/dev/null | grep -c 'killed by the OOM killer')"
        detail="journal OOM messages this boot: ${oomk}"
    else
        detail="memory.events oom_kill=${oomk}"
    fi
    [[ "${oomk:-1}" == "0" ]] && check "A3 no OOM kill in the current cgroup" 0 "$detail" \
                              || check "A3 no OOM kill in the current cgroup" 1 "$detail"

    # ---- B: deliberate, right-sized, persistent memory control --------------
    local mmax mhigh nmax nhigh
    mmax="$(systemctl show -p MemoryMax --value "$UNIT" 2>/dev/null)"
    mhigh="$(systemctl show -p MemoryHigh --value "$UNIT" 2>/dev/null)"
    nmax="$(bytes_of "$mmax")"; nhigh="$(bytes_of "$mhigh")"
    if (( nmax >= 268435456 && nmax <= 1073741824 )); then
        check "B1 MemoryMax right-sized to 256M..1G (not removed)" 0 "MemoryMax=${mmax}"
    else
        check "B1 MemoryMax right-sized to 256M..1G (not removed)" 1 "MemoryMax=${mmax}"
    fi
    if (( nhigh == -1 || nhigh >= 268435456 )); then
        check "B2 MemoryHigh cleared or >= 256M (runtime fault handled)" 0 "MemoryHigh=${mhigh}"
    else
        check "B2 MemoryHigh cleared or >= 256M (runtime fault handled)" 1 "MemoryHigh=${mhigh}"
    fi
    if [[ -d "$UNIT_DROPIN" ]] && grep -Rqs 'MemoryMax=24M' "$UNIT_DROPIN"; then
        check "B3 the crippling drop-in is gone" 1 "${UNIT_DROPIN}/ still sets MemoryMax=24M"
    else
        check "B3 the crippling drop-in is gone" 0 ""
    fi

    # ---- C: the slice no longer starves the subtree -------------------------
    local cpumax quota period pids
    cpumax="$(cg_read "$SLICE" cpu.max 2>/dev/null)"
    if [[ -n "$cpumax" ]]; then
        quota="${cpumax%% *}"; period="${cpumax##* }"
        if [[ "$quota" == "max" ]] || (( quota * 100 / period >= 50 )); then
            check "C1 slice CPU quota >= 50% or unlimited" 0 "cpu.max = ${cpumax}"
        else
            check "C1 slice CPU quota >= 50% or unlimited" 1 "cpu.max = ${cpumax} (~$((quota*100/period))%)"
        fi
    else
        cpumax="$(systemctl show -p CPUQuotaPerSecUSec --value "$SLICE" 2>/dev/null)"
        [[ "$cpumax" == "infinity" ]] \
            && check "C1 slice CPU quota unlimited" 0 "CPUQuotaPerSecUSec=${cpumax}" \
            || check "C1 slice CPU quota unlimited" 1 "CPUQuotaPerSecUSec=${cpumax} (cgroup v1: check by hand)"
    fi

    pids="$(cg_read "$SLICE" pids.max 2>/dev/null)"
    [[ -z "$pids" ]] && pids="$(systemctl show -p TasksMax --value "$SLICE" 2>/dev/null)"
    if [[ "$pids" == "max" || "$pids" == "infinity" ]] || { [[ "$pids" =~ ^[0-9]+$ ]] && (( pids >= 64 )); }; then
        check "C2 slice TasksMax >= 64 or unlimited" 0 "pids.max/TasksMax = ${pids}"
    else
        check "C2 slice TasksMax >= 64 or unlimited" 1 "pids.max/TasksMax = ${pids}"
    fi

    # ---- D: PAM limits for the interactive user -----------------------------
    local u_nproc u_nofile u_fsize
    u_nproc="$(su - "$LAB_USER" -c 'ulimit -Hu' 2>/dev/null | tr -d '[:space:]')"
    u_nofile="$(su - "$LAB_USER" -c 'ulimit -Hn' 2>/dev/null | tr -d '[:space:]')"
    u_fsize="$(su - "$LAB_USER" -c 'ulimit -Hf' 2>/dev/null | tr -d '[:space:]')"
    { [[ "$u_nproc" == "unlimited" ]] || { [[ "$u_nproc" =~ ^[0-9]+$ ]] && (( u_nproc >= 100 )); }; } \
        && check "D1 nproc >= 100 for ${LAB_USER}" 0 "ulimit -Hu = ${u_nproc}" \
        || check "D1 nproc >= 100 for ${LAB_USER}" 1 "ulimit -Hu = ${u_nproc}"
    { [[ "$u_nofile" == "unlimited" ]] || { [[ "$u_nofile" =~ ^[0-9]+$ ]] && (( u_nofile >= 1024 )); }; } \
        && check "D2 nofile >= 1024 for ${LAB_USER}" 0 "ulimit -Hn = ${u_nofile}" \
        || check "D2 nofile >= 1024 for ${LAB_USER}" 1 "ulimit -Hn = ${u_nofile}"
    [[ "$u_fsize" == "unlimited" ]] \
        && check "D3 fsize unlimited for ${LAB_USER}" 0 "ulimit -Hf = ${u_fsize}" \
        || check "D3 fsize unlimited for ${LAB_USER}" 1 "ulimit -Hf = ${u_fsize}"

    su - "$LAB_USER" -c 'for i in $(seq 1 30); do sleep 3 & done; wait; echo SPAWN_OK' 2>/dev/null \
        | grep -q SPAWN_OK \
        && check "D4 the user can really fork 30 processes" 0 "" \
        || check "D4 the user can really fork 30 processes" 1 "fork still refused"

    su - "$LAB_USER" -c 'dd if=/dev/zero of="$HOME/.probe" bs=1M count=5 status=none && echo WRITE_OK; rm -f "$HOME/.probe"' 2>/dev/null \
        | grep -q WRITE_OK \
        && check "D5 the user can really write a 5 MiB file" 0 "" \
        || check "D5 the user can really write a 5 MiB file" 1 "SIGXFSZ / write refused"

    # ---- E: persistence -----------------------------------------------------
    if grep -Rqs 'Memory\(Max\|High\)' /etc/systemd/system/"${UNIT}".d/ 2>/dev/null \
       || grep -Rqs 'MemoryMax' /etc/systemd/system.control/"${UNIT}".d/ 2>/dev/null; then
        check "E1 the memory ceiling is written to disk under /etc (survives reboot)" 0 ""
    else
        check "E1 the memory ceiling is written to disk under /etc (survives reboot)" 1 \
              "nothing persistent found - did you use 'set-property --runtime'?"
    fi

    hr
    if (( FAIL == 0 )); then
        printf '%s ALL %d CHECKS PASSED - topic 332.3 objective met.%s\n' "$C_G" "$PASS" "$C_0"
    else
        printf '%s %d passed, %d failed - keep digging.%s\n' "$C_Y" "$PASS" "$FAIL" "$C_0"
    fi
    hr
    return $(( FAIL > 0 ))
}

# ----------------------------------------------------------------------------
# teardown - this is the LAB teardown, NOT the answer to the exercise
# ----------------------------------------------------------------------------
do_reset() {
    say "tearing down the ${LAB_ID} lab"
    systemctl disable --now "$UNIT" >/dev/null 2>&1
    systemctl reset-failed "$UNIT" >/dev/null 2>&1
    systemctl revert "$UNIT" "$SLICE" >/dev/null 2>&1
    rm -rf -- "$UNIT_DROPIN" "$SLICE_DROPIN" \
              "/run/systemd/system.control/${UNIT}.d" \
              "/etc/systemd/system.control/${UNIT}.d"
    systemctl stop "$SLICE" >/dev/null 2>&1
    rm -f -- "/usr/local/lib/systemd/system/${UNIT}" "/usr/local/lib/systemd/system/${SLICE}" \
             "/etc/systemd/system/${UNIT}" "/etc/systemd/system/${SLICE}"
    systemctl daemon-reload
    rm -f -- "$LIMITS_FILE"
    rm -rf -- "$WORKDIR"

    if [[ -f "$BACKUP_LIST" ]]; then
        while IFS=$'\t' read -r orig bak; do
            [[ -n "${orig:-}" && -e "${bak:-}" ]] || continue
            cp -a -- "$bak" "$orig" && say "restored $orig"
        done < "$BACKUP_LIST"
    fi

    if id "$LAB_USER" >/dev/null 2>&1 && getent passwd "$LAB_USER" | grep -q "$LAB_GECOS"; then
        loginctl terminate-user "$LAB_USER" >/dev/null 2>&1
        pkill -KILL -u "$LAB_USER" >/dev/null 2>&1
        sleep 1
        userdel -r "$LAB_USER" >/dev/null 2>&1 && say "removed user $LAB_USER"
    fi

    rm -rf -- "$STATE_DIR"
    ok "lab removed. 'systemd-cgls' should no longer show ${SLICE}."
}

usage() {
    sed -n '2,48p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
}

# ----------------------------------------------------------------------------
# dispatch
# ----------------------------------------------------------------------------
while (( $# )); do
    case "$1" in
        --break|break) ACTION="break" ;;
        --brief|brief) ACTION="brief" ;;
        --check|check) ACTION="check" ;;
        --reset|reset) ACTION="reset" ;;
        --force|-y)    FORCE=1 ;;
        -h|--help)     ACTION="help" ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

case "$ACTION" in
    break) need_root; confirm; preflight; install_lab; baseline; apply_faults; briefing ;;
    brief) briefing ;;
    check) need_root; do_check ;;
    reset) need_root; do_reset ;;
    help|*) usage ;;
esac

# =============================================================================
# =============================================================================
#
#   S O L U T I O N   -   do not read until you have tried --check
#
#   Topic 332.3 Resource Control. Four faults, four mechanisms, four tools.
#   Everything below is copy-pasteable and shows the output you should get.
#
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0 - Characterise the failure before touching anything
# -----------------------------------------------------------------------------
#
#   # systemctl status lpic303-workload.service --no-pager -l
#     * lpic303-workload.service - LPIC-3 303 / 332.3 lab workload (memory + CPU)
#        Loaded: loaded (/usr/local/lib/systemd/system/lpic303-workload.service; enabled)
#       Drop-In: /etc/systemd/system/lpic303-workload.service.d
#                `-10-memory-limits.conf
#                /run/systemd/system.control/lpic303-workload.service.d
#                `-50-MemoryHigh.conf
#        Active: activating (auto-restart) (Result: oom-kill)
#
#   Two things are already visible, and both matter:
#     - "Result: oom-kill" is a CGROUP OOM kill, not the global OOM killer.
#       The machine has plenty of free RAM; the *cgroup* ran out.
#     - the Drop-In list has TWO directories, and the second one is under /run.
#
#   # journalctl -u lpic303-workload.service -b --no-pager | tail -n 12
#     workload: allocated 8 MiB
#     workload: allocated 16 MiB
#     systemd[1]: lpic303-workload.service: A process of this unit has been
#       killed by the OOM killer.
#     systemd[1]: lpic303-workload.service: Main process exited, code=killed,
#       status=9/KILL
#     systemd[1]: lpic303-workload.service: Failed with result 'oom-kill'.
#
#   It dies at ~16-24 MiB every time. That is a hard ceiling, i.e. memory.max.
#
# -----------------------------------------------------------------------------
# STEP 1 - Ask systemd what is in effect (never grep /etc and call it done)
# -----------------------------------------------------------------------------
#
#   # systemctl cat lpic303-workload.service
#     ...
#     # /etc/systemd/system/lpic303-workload.service.d/10-memory-limits.conf
#     [Service]
#     MemoryAccounting=yes
#     MemoryMax=24M
#     MemorySwapMax=0
#     # /run/systemd/system.control/lpic303-workload.service.d/50-MemoryHigh.conf
#     [Service]
#     MemoryHigh=33554432
#
#   # systemctl show lpic303-workload.service \
#       -p MemoryMax -p MemoryHigh -p MemorySwapMax -p Slice -p ControlGroup
#     MemoryMax=25165824
#     MemoryHigh=33554432
#     MemorySwapMax=0
#     Slice=lpic303lab.slice
#     ControlGroup=/lpic303lab.slice/lpic303-workload.service
#
#   KEY LESSON: `systemctl show` merges vendor unit + /etc drop-ins + /run
#   drop-ins (created by `systemctl set-property --runtime`) + transient
#   properties. `grep -r /etc/systemd` would have missed MemoryHigh entirely,
#   and you would have "fixed" the unit only to watch it stall instead of die.
#   Precedence, lowest to highest: /usr/lib -> /usr/local/lib -> /run -> /etc,
#   with *.d drop-ins layered on top of the unit file - systemd.unit(5).
#
# -----------------------------------------------------------------------------
# STEP 2 - Read the kernel's own accounting (cgroup v2 interface files)
# -----------------------------------------------------------------------------
#
#   # CG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value lpic303-workload.service)
#   # echo "$CG"
#     /sys/fs/cgroup/lpic303lab.slice/lpic303-workload.service
#
#   # cat "$CG"/memory.max "$CG"/memory.high "$CG"/memory.swap.max "$CG"/memory.current
#     25165824
#     33554432
#     0
#     24903680
#
#   # cat "$CG"/memory.events
#     low 0
#     high 4127          <- times the process was throttled by memory.high
#     max 8912           <- times allocation hit memory.max and reclaim ran
#     oom 41
#     oom_kill 7         <- the smoking gun
#
#   # cat "$CG"/memory.pressure
#     some avg10=99.80 avg60=98.11 avg300=71.22 total=...
#     full avg10=97.44 ...
#
#   PSI at ~100% means the task spends essentially all its time waiting on
#   memory. memory.high does NOT kill: it throttles and forces reclaim. With
#   MemorySwapMax=0 there is nowhere to reclaim anonymous pages to, so the
#   process simply stalls. memory.max DOES kill. Two different failure shapes,
#   and both were present at once.
#
#   Slice level:
#   # cat /sys/fs/cgroup/lpic303lab.slice/cpu.max
#     5000 100000                   <- 5 ms of CPU per 100 ms period = 5%
#   # cat /sys/fs/cgroup/lpic303lab.slice/cpu.stat
#     nr_periods 3121
#     nr_throttled 3098             <- throttled in 99% of periods
#     throttled_usec 291204551
#   # cat /sys/fs/cgroup/lpic303lab.slice/pids.max
#     8
#   # cat /sys/fs/cgroup/lpic303lab.slice/pids.events
#     max 143                       <- forks refused 143 times
#
#   Topology view:
#   # systemd-cgls /lpic303lab.slice
#   # systemd-cgtop --order=memory --iterations=3
#
#   (cgroup v1 / hybrid equivalents: memory.limit_in_bytes,
#    memory.memsw.limit_in_bytes, memory.failcnt, cpu.cfs_quota_us /
#    cpu.cfs_period_us, cpu.stat, pids.max - each under its own controller
#    mount in /sys/fs/cgroup/<controller>/. See cgroups(7).)
#
# -----------------------------------------------------------------------------
# STEP 3 - Fix fault 1 and fault 2 (unit-level memory)
# -----------------------------------------------------------------------------
#
#   The workload legitimately needs ~200 MiB. Do NOT delete resource control;
#   right-size it. Replace the drop-in rather than removing it:
#
#   # systemctl edit lpic303-workload.service        # writes override.conf in /etc
#   ...or non-interactively:
#   # rm -f /etc/systemd/system/lpic303-workload.service.d/10-memory-limits.conf
#   # cat > /etc/systemd/system/lpic303-workload.service.d/10-memory-limits.conf <<'EOF'
#   [Service]
#   MemoryAccounting=yes
#   MemoryMax=512M
#   MemoryHigh=384M
#   MemorySwapMax=infinity
#   EOF
#
#   Now clear the RUNTIME drop-in. Deleting the /etc file does not touch /run:
#
#   # ls /run/systemd/system.control/lpic303-workload.service.d/
#     50-MemoryHigh.conf
#   # systemctl set-property --runtime lpic303-workload.service MemoryHigh=infinity
#   ...or drop every override on the unit in one go (drop-ins in /etc and /run):
#   # systemctl revert lpic303-workload.service
#     (CAUTION: revert only restores a *vendor* unit file. It is safe here
#      because the unit ships in /usr/local/lib/systemd/system. If the unit
#      itself lived only in /etc, revert would take it with it - check
#      `systemctl cat` first, and prefer removing the drop-in you know about.)
#
#   # systemctl daemon-reload
#   # systemctl reset-failed lpic303-workload.service     # clears the rate limit
#   # systemctl restart lpic303-workload.service
#   # systemctl show lpic303-workload.service -p MemoryMax -p MemoryHigh
#     MemoryMax=536870912
#     MemoryHigh=402653184
#
#   Note: "Start request repeated too quickly" is StartLimitIntervalSec= /
#   StartLimitBurst= (systemd.unit(5)), not a resource limit. reset-failed
#   clears it; raising the limits without clearing it leaves the unit failed.
#
# -----------------------------------------------------------------------------
# STEP 4 - Fix fault 3 (slice-level CPU and tasks)
# -----------------------------------------------------------------------------
#
#   A limit on a slice applies to the ENTIRE subtree, not to one unit. That is
#   why the service was slow even after the memory fix, and why a brand-new
#   scope started in the same slice could not fork.
#
#   # systemctl cat lpic303lab.slice
#     # /etc/systemd/system/lpic303lab.slice.d/10-cpu-tasks.conf
#     [Slice]
#     CPUQuota=5%
#     TasksMax=8
#
#   # rm -f /etc/systemd/system/lpic303lab.slice.d/10-cpu-tasks.conf
#   # rmdir /etc/systemd/system/lpic303lab.slice.d 2>/dev/null
#   # systemctl daemon-reload
#
#   Then set a sane, persistent policy. `set-property` without --runtime writes
#   /etc/systemd/system.control/<unit>.d/ and survives reboot:
#
#   # systemctl set-property lpic303lab.slice CPUQuota=200% TasksMax=512 \
#         CPUWeight=100 IOWeight=100 MemoryMax=1G
#   # cat /sys/fs/cgroup/lpic303lab.slice/cpu.max
#     200000 100000
#   # cat /sys/fs/cgroup/lpic303lab.slice/pids.max
#     512
#
#   Verify the throttling actually stopped (nr_throttled must stop growing):
#   # cat /sys/fs/cgroup/lpic303lab.slice/cpu.stat; sleep 10
#   # cat /sys/fs/cgroup/lpic303lab.slice/cpu.stat
#
#   Reproduce the task test that used to fail:
#   # systemd-run --slice=lpic303lab.slice -p User=lpic303lab --wait --pipe \
#       /bin/bash -c 'for i in $(seq 1 20); do sleep 5 & done; wait; echo ok'
#     ok
#
# -----------------------------------------------------------------------------
# STEP 5 - Fix fault 4 (PAM limits - a completely different mechanism)
# -----------------------------------------------------------------------------
#
#   cgroups limit a *cgroup*. RLIMIT limits a *process* and is inherited across
#   fork/exec. pam_limits(8) applies /etc/security/limits.conf and limits.d/*
#   at PAM session setup - so it affects login, ssh, su, sudo... and NOT a
#   plain systemd service, which never traverses the PAM stack unless the unit
#   sets PAMName=. That is why the service kept running as lpic303lab while
#   `su - lpic303lab` was crippled.
#
#   # cat /etc/security/limits.d/99-lpic303-332-3.conf
#     lpic303lab   hard   nproc    12
#     lpic303lab   soft   nproc    12
#     lpic303lab   hard   nofile   16
#     lpic303lab   soft   nofile   16
#     lpic303lab   hard   fsize    1024
#     lpic303lab   soft   fsize    1024
#
#   Replace it with something workable (again: control, do not abandon):
#
#   # cat > /etc/security/limits.d/99-lpic303-332-3.conf <<'EOF'
#   # LPIC-3 303 / 332.3 - operator account, right-sized 2026-08-24
#   lpic303lab   soft   nproc    512
#   lpic303lab   hard   nproc    1024
#   lpic303lab   soft   nofile   4096
#   lpic303lab   hard   nofile   8192
#   lpic303lab   soft   fsize    unlimited
#   lpic303lab   hard   fsize    unlimited
#   EOF
#
#   Limits are read at session setup, so you need a NEW session to see them:
#   # su - lpic303lab -c 'ulimit -Su; ulimit -Hu; ulimit -Sn; ulimit -Hn; ulimit -Hf'
#     512
#     1024
#     4096
#     8192
#     unlimited
#   # su - lpic303lab -c 'for i in $(seq 1 30); do sleep 3 & done; wait; echo ok'
#     ok
#   # su - lpic303lab -c 'dd if=/dev/zero of=/tmp/p bs=1M count=5 status=none && echo ok; rm -f /tmp/p'
#     ok
#
#   Gotchas worth knowing for the exam:
#     - RLIMIT_NPROC (nproc) counts EVERY process of that UID on the machine,
#       not per session. Setting it too low locks the user out of their own
#       shell; setting it on '*' or root can lock YOU out. Never do that.
#     - A hard limit can only be lowered by an unprivileged process, never
#       raised: `ulimit -n 8192` fails if the hard limit is 16.
#     - Inspect a *running* process instead of guessing:
#         # prlimit --pid "$(systemctl show -p MainPID --value lpic303-workload.service)"
#         # cat /proc/<pid>/limits
#     - Change one live process without restarting it:
#         # prlimit --pid <pid> --nofile=4096:8192
#     - systemd services take their rlimits from LimitNOFILE=, LimitNPROC=,
#       LimitFSIZE=... in the unit, or from DefaultLimit*= in
#       /etc/systemd/system.conf - NOT from limits.conf.
#     - User *sessions* also sit in user-<uid>.slice, whose defaults come from
#       /etc/systemd/logind.conf and can be inspected with
#       `loginctl user-status lpic303lab` and `systemd-cgls /user.slice`.
#
# -----------------------------------------------------------------------------
# STEP 6 - Prove it, including across a daemon-reload and a reboot
# -----------------------------------------------------------------------------
#
#   # systemctl daemon-reload
#   # systemctl restart lpic303-workload.service
#   # sleep 70
#   # journalctl -u lpic303-workload.service -b --no-pager | grep ALLOCATED
#     workload: ALLOCATED 192 MiB - entering steady state
#   # CG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value lpic303-workload.service)
#   # grep -E 'oom_kill|^high' "$CG"/memory.events
#     high 0
#     oom_kill 0
#   # systemd-cgtop --order=cpu --iterations=1 | head
#   # ./332.3-break-and-fix.sh --check
#     ALL 12 CHECKS PASSED - topic 332.3 objective met.
#   # reboot        # then re-run --check: everything must still pass
#
# -----------------------------------------------------------------------------
# STEP 7 - What you were actually being examined on
# -----------------------------------------------------------------------------
#
#   1. Effective configuration != files on disk. Four sources merge into one
#      unit: vendor unit, /etc drop-ins, /run drop-ins (--runtime), transient
#      properties. `systemctl cat` + `systemctl show` are the source of truth.
#   2. memory.max kills, memory.high throttles. "Active but frozen" and
#      "killed by the OOM killer" are different diagnoses with different files.
#      MemorySwapMax=0 turns a survivable limit into a fatal one.
#   3. A .slice limit applies to its whole subtree. Limiting the wrong node
#      starves units you never intended to touch.
#   4. cgroup limits and RLIMIT/PAM limits are independent subsystems with
#      different scopes and different tools. A service ignores limits.conf;
#      an interactive session ignores the unit's MemoryMax.
#   5. Correct resource control means right-sizing with headroom, written
#      persistently, verified against the kernel's own counters - not deleting
#      every limit until the alert stops.
#
#   Sources:
#     https://www.lpi.org/our-certifications/exam-303-objectives/
#     https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html
#     https://www.freedesktop.org/software/systemd/man/systemd.slice.html
#     https://www.freedesktop.org/software/systemd/man/systemctl.html
#     https://docs.kernel.org/admin-guide/cgroup-v2.html
#     https://docs.kernel.org/accounting/psi.html
#     https://man7.org/linux/man-pages/man5/limits.conf.5.html
#     https://man7.org/linux/man-pages/man8/pam_limits.8.html
#     https://man7.org/linux/man-pages/man2/getrlimit.2.html
#     https://man7.org/linux/man-pages/man7/cgroups.7.html
# =============================================================================