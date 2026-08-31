#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1  (Exam 101-500 / 102-500, version 5.0)
#  Topic 103.5 - Create, monitor and kill processes            Weight: 6.25
#
#  BREAK & FIX LABORATORY - "The night the queue stopped moving"
#
#  Key knowledge exercised (LPI objective 103.5):
#     &   bg   fg   jobs   disown   nohup   setsid
#     ps  top  free  uptime  pgrep  pkill  killall  watch  kill
#     screen / tmux (detached execution), signals, process states, /proc
#
#  Official references:
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#     https://man7.org/linux/man-pages/man7/signal.7.html
#     https://man7.org/linux/man-pages/man1/ps.1.html
#     https://man7.org/linux/man-pages/man1/kill.1.html
#     https://man7.org/linux/man-pages/man1/pgrep.1.html
#     https://man7.org/linux/man-pages/man5/proc_pid_status.5.html
#     https://www.gnu.org/software/bash/manual/bash.html#Job-Control
#
#  WHAT THIS SCRIPT DOES
#     It starts four unprivileged, self-terminating processes under
#     /var/tmp/lpic1-103.5-lab and then puts the "service" into a broken
#     state that can only be diagnosed with process-management tooling.
#     Nothing outside that directory is touched, no package is installed,
#     no system unit is modified, no file is deleted. Every lab process
#     dies on its own after LAB_TTL seconds (default 7200) even if you
#     walk away.
#
#     One CPU core WILL sit at 100% until you fix fault 2. That is the
#     symptom, not a bug.
#
#  RUN IT ONLY ON A DISPOSABLE LABORATORY VM.
#
#  USAGE
#     ./lpic1-103.5-break-and-fix.sh break     # inject the incident (default)
#     ./lpic1-103.5-break-and-fix.sh status    # dashboard of the lab service
#     ./lpic1-103.5-break-and-fix.sh verify    # grade your repair (exit 0 = fixed)
#     ./lpic1-103.5-break-and-fix.sh clean     # tear everything down
#
#     Environment: LAB_DIR, LAB_TTL, LAB_ASSUME_YES=1
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until `verify` defeats you.
# =============================================================================

set -uo pipefail

LAB_ID="lpic1-103.5"
LAB_DIR="${LAB_DIR:-/var/tmp/${LAB_ID}-lab}"
BIN_DIR="$LAB_DIR/bin"
STATE_DIR="$LAB_DIR/state"
PID_DIR="$LAB_DIR/.internal"
LAB_TTL="${LAB_TTL:-7200}"
ASSUME_YES="${LAB_ASSUME_YES:-0}"

# Patterns used with `pgrep -f` / `pkill -f`: they match the full command line,
# which is what lets us find detached processes that own no terminal.
P_HEARTBEAT="lab-heartbeat.sh"
P_AGENT="lab-report-agent.sh"
P_SUPERVISOR="lab-queue-supervisor.sh"
P_WORKER="lab-queue-worker.sh"
P_ZOMBIE="lab-zombie-parent"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_B="$(tput bold)"; C_R="$(tput setaf 1)"; C_G="$(tput setaf 2)"
    C_Y="$(tput setaf 3)"; C_C="$(tput setaf 6)"; C_0="$(tput sgr0)"
else
    C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""
fi

log()   { printf '%s[lab]%s %s\n' "$C_C" "$C_0" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()   { printf '%s[fatal]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
rule()  { printf '%s\n' "-----------------------------------------------------------------------"; }
title() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; rule; }

# --- pid helpers -------------------------------------------------------------
# `pgrep -u <uid> -f <pattern>` restricts the search to processes owned by the
# invoking user: a pattern that can never reach a system daemon by accident.
lab_pids()  { pgrep -u "$(id -u)" -f "$1" 2>/dev/null; }
lab_pid1()  { lab_pids "$1" | head -n 1; }
lab_alive() { [ -n "$(lab_pid1 "$1")" ]; }
proc_stat() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' '; }

require_tools() {
    local missing=""
    for t in ps pgrep pkill kill sleep date awk sed; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] || die "missing required tools:$missing (install procps-ng / coreutils)"
    command -v setsid >/dev/null 2>&1 && HAVE_SETSID=1 || HAVE_SETSID=0
}

confirm_disposable() {
    [ "$ASSUME_YES" = "1" ] && return 0
    cat <<EOF

${C_Y}${C_B}READ THIS BEFORE CONTINUING${C_0}

  This script starts CPU-burning and signal-ignoring processes on THIS host,
  under $LAB_DIR. It is safe and self-limiting (every process exits after
  ${LAB_TTL}s), but it is meant for a THROWAWAY LABORATORY VM, not for a
  workstation you care about and certainly not for anything in production.

EOF
    if [ ! -t 0 ]; then
        die "no terminal available for confirmation: re-run with LAB_ASSUME_YES=1 if this really is a lab VM"
    fi
    local answer=""
    read -r -p "Type LAB to confirm this is a disposable lab VM: " answer
    [ "$answer" = "LAB" ] || die "aborted - nothing was started"
    if [ "$(id -u)" -eq 0 ]; then
        warn "you are root: the lab works, but an unprivileged user is safer -"
        warn "a mistyped 'pkill -f' pattern as root can reach system daemons."
    fi
}

# --- payloads ----------------------------------------------------------------
# Four small programs. None of them is buggy. The incident is entirely about
# process state, signal disposition, process hierarchy and reaping.
write_payloads() {
    mkdir -p "$BIN_DIR" "$STATE_DIR" "$PID_DIR" || die "cannot create $LAB_DIR"

    cat >"$BIN_DIR/lab-heartbeat.sh" <<'PAYLOAD'
#!/usr/bin/env bash
# lab-heartbeat.sh - monitoring agent. Refreshes state/heartbeat every 2 seconds.
# Health checks that only ask "does the PID exist?" cannot detect its failure
# mode: the process is present, the file simply stops advancing.
state_dir="$1"; deadline="$2"
trap 'exit 0' TERM INT
while [ "$(date +%s)" -lt "$deadline" ]; do
    date +%s >"$state_dir/heartbeat"
    sleep 2
done
PAYLOAD

    cat >"$BIN_DIR/lab-report-agent.sh" <<'PAYLOAD'
#!/usr/bin/env bash
# lab-report-agent.sh - "nightly report builder". Pins exactly one core with a
# fork-free busy loop and installs handlers for every catchable termination
# signal, logging them and continuing. SIGKILL (9) and SIGSTOP (19) are the two
# signals that can never be caught, blocked or ignored - see signal(7).
state_dir="$1"; deadline="$2"
log="$state_dir/report-agent.log"
note() { printf '%s %s\n' "$(date -Is)" "$1" >>"$log"; }
trap 'note "caught SIGTERM - ignoring, report is 43% complete"' TERM
trap 'note "caught SIGHUP  - ignoring, no configuration to reload"' HUP
trap 'note "caught SIGINT  - ignoring"' INT
trap 'note "caught SIGQUIT - ignoring"' QUIT
note "started pid $$ - consuming one core on purpose"
budget=$(( deadline - $(date +%s) ))
[ "$budget" -lt 1 ] && budget=1
while [ "$SECONDS" -lt "$budget" ]; do :; done
note "deadline reached, exiting pid $$"
PAYLOAD

    cat >"$BIN_DIR/lab-queue-supervisor.sh" <<'PAYLOAD'
#!/usr/bin/env bash
# lab-queue-supervisor.sh - a minimal process supervisor. It starts a worker,
# waits for it, and starts another one 2 seconds after the previous one dies.
# Killing the child is therefore not a repair; it is a respawn trigger.
state_dir="$1"; deadline="$2"; worker="$3"
log="$state_dir/supervisor.log"
wpid=""
trap 'if [ -n "$wpid" ]; then kill "$wpid" 2>/dev/null; fi
      printf "%s supervisor pid %s stopping on SIGTERM\n" "$(date -Is)" "$$" >>"$log"
      exit 0' TERM
printf '%s supervisor pid %s started\n' "$(date -Is)" "$$" >>"$log"
while [ "$(date +%s)" -lt "$deadline" ]; do
    "$worker" "$state_dir" "$deadline" &
    wpid=$!
    printf '%s started worker pid %s\n' "$(date -Is)" "$wpid" >>"$log"
    wait "$wpid"; rc=$?
    printf '%s worker pid %s exited (rc=%s) - respawning in 2s\n' \
        "$(date -Is)" "$wpid" "$rc" >>"$log"
    sleep 2
done
PAYLOAD

    cat >"$BIN_DIR/lab-queue-worker.sh" <<'PAYLOAD'
#!/usr/bin/env bash
# lab-queue-worker.sh - consumes one fake job every 3 seconds. Terminates
# politely on SIGTERM; it is the supervisor that brings it back from the dead.
state_dir="$1"; deadline="$2"
trap 'exit 0' TERM INT
while [ "$(date +%s)" -lt "$deadline" ]; do
    printf '%s pid %s processed job %s\n' "$(date -Is)" "$$" "$RANDOM" \
        >>"$state_dir/processed.log"
    sleep 3
done
PAYLOAD

    cat >"$BIN_DIR/lab-zombie-parent.py" <<'PAYLOAD'
#!/usr/bin/env python3
"""lab-zombie-parent - forks a child, the child exits immediately, and the
parent never calls wait(). The child stays in the process table as <defunct>
(state Z): no memory, no CPU, nothing to signal - only an exit status waiting
to be collected. See proc_pid_status(5) and signal(7)."""
import os
import sys
import time

deadline = int(sys.argv[1])
if os.fork() == 0:
    os._exit(0)                      # this child is the zombie
while time.time() < deadline:        # parent never reaps it
    time.sleep(1)
PAYLOAD

    cat >"$BIN_DIR/lab-zombie-parent.pl" <<'PAYLOAD'
#!/usr/bin/env perl
# lab-zombie-parent - Perl fallback: same semantics as the Python version.
my $deadline = shift;
my $pid = fork();
exit 0 unless $pid;                  # the child exits and becomes <defunct>
sleep 1 while time() < $deadline;    # the parent never wait()s
PAYLOAD

    chmod +x "$BIN_DIR"/lab-*.sh "$BIN_DIR"/lab-zombie-parent.* 2>/dev/null || true
}

# --- process launcher --------------------------------------------------------
# setsid(1) puts each process in a brand new session with no controlling
# terminal: it survives the shell that started it and does NOT appear in the
# `jobs` table of any shell. That is why job control alone cannot fix this lab.
start_detached() {
    local tag="$1"; shift
    if [ "$HAVE_SETSID" = "1" ]; then
        setsid "$@" >>"$STATE_DIR/$tag.out" 2>&1 </dev/null &
    else
        nohup "$@" >>"$STATE_DIR/$tag.out" 2>&1 </dev/null &
        disown 2>/dev/null || true
    fi
}

start_stack() {
    local deadline=$(( $(date +%s) + LAB_TTL ))
    : >"$STATE_DIR/processed.log"
    : >"$STATE_DIR/supervisor.log"
    : >"$STATE_DIR/report-agent.log"
    echo "$deadline" >"$STATE_DIR/deadline"

    start_detached heartbeat  bash "$BIN_DIR/lab-heartbeat.sh"  "$STATE_DIR" "$deadline"
    start_detached agent      bash "$BIN_DIR/lab-report-agent.sh" "$STATE_DIR" "$deadline"
    start_detached supervisor bash "$BIN_DIR/lab-queue-supervisor.sh" \
                              "$STATE_DIR" "$deadline" "$BIN_DIR/lab-queue-worker.sh"

    if command -v python3 >/dev/null 2>&1; then
        start_detached zombie python3 "$BIN_DIR/lab-zombie-parent.py" "$deadline"
    elif command -v perl >/dev/null 2>&1; then
        start_detached zombie perl "$BIN_DIR/lab-zombie-parent.pl" "$deadline"
    else
        warn "neither python3 nor perl found: fault 4 (zombie reaping) is SKIPPED"
        echo "skipped" >"$STATE_DIR/zombie.skipped"
    fi
    sleep 4
}

inject_fault() {
    local hb; hb="$(lab_pid1 "$P_HEARTBEAT")"
    [ -n "$hb" ] || die "the heartbeat agent did not start - run '$0 clean' and retry"
    # SIGSTOP: the process is not killed, not signalled out of existence, and
    # not removed from the process table. It is simply taken off the scheduler.
    kill -STOP "$hb" || die "could not stop pid $hb"
    echo "$hb" >"$PID_DIR/heartbeat.pid"
}

# --- student-facing output ---------------------------------------------------
briefing() {
    cat <<EOF

${C_B}=====================================================================${C_0}
${C_B} INCIDENT BRIEFING - topic 103.5, create / monitor / kill processes${C_0}
${C_B}=====================================================================${C_0}

You are on call. The batch platform under $LAB_DIR is degraded.
Four independent problems are in front of you. Nothing is broken at the
source-code level: every program in bin/ is correct. The incident lives in
process state, signal disposition, process hierarchy and reaping.

${C_B}SYMPTOMS YOU WILL SEE${C_0}

  1. ${C_Y}Stale heartbeat.${C_0} state/heartbeat stopped advancing seconds after
     boot, yet the monitoring agent's PID is still in the process table and
     is consuming no CPU at all. A restart script that only checks "is the
     PID alive?" reports the service as healthy.

  2. ${C_Y}One core pinned at 100%.${C_0} 'lab-report-agent' is eating a full CPU.
     'kill <pid>' returns success, exits 0, prints nothing - and the process
     keeps running. So does 'pkill', 'killall' and Ctrl-C's signal.
     state/report-agent.log is worth reading.

  3. ${C_Y}An immortal worker.${C_0} 'lab-queue-worker' keeps appending to
     state/processed.log. You kill it, it dies, and roughly two seconds later
     the same program is back with a different PID.

  4. ${C_Y}A defunct entry.${C_0} 'ps' shows a process marked <defunct> in state Z.
     'kill -9' on it changes nothing whatsoever.
     (Skipped automatically if this host has neither python3 nor perl.)

${C_B}WHAT YOU MUST ACHIEVE${C_0}

  A. The heartbeat agent must be RUNNING AGAIN and state/heartbeat must be
     refreshing - fewer than 10 seconds old. ${C_R}Do not kill it.${C_0}
  B. 'lab-report-agent' must be gone from the process table.
  C. Both 'lab-queue-supervisor' and 'lab-queue-worker' must be gone, and
     they must stay gone - no respawn.
  D. No <defunct> entry must remain, and its parent must be gone too.

${C_B}RULES OF ENGAGEMENT${C_0}

  * No reboot, no 'systemctl restart', no deleting $LAB_DIR.
  * ${C_R}A blanket 'pkill -9 -f lab-' will FAIL the grader${C_0}: objective A needs a
    live, running heartbeat. Blast radius is part of the exercise.
  * Everything runs as $(id -un) and self-terminates in $((LAB_TTL/60)) minutes.

${C_B}TOOLING WORTH REMEMBERING (objective 103.5)${C_0}

  ps -eo pid,ppid,stat,ni,pcpu,etime,args --sort=-pcpu
  ps -ejH        pstree -p        top (then 'k' to kill, 'r' to renice)
  pgrep -a -u \$(id -u) -f PATTERN        pkill -f PATTERN        killall
  kill -l        kill -s CONT PID        kill -9 PID        kill -SIGCONT %1
  jobs / bg / fg / disown        nohup        setsid        screen / tmux
  watch -n1 'ps ...'        uptime        free -h
  grep -E 'State|PPid|SigIgn|SigCgt' /proc/PID/status

${C_B}COMMANDS${C_0}

  $0 status      snapshot of every lab process and file
  $0 verify      grade your repair (exit 0 when all four objectives pass)
  $0 clean       tear the lab down when you are done

EOF
}

status() {
    local now hb_age hb_val zcount
    now="$(date +%s)"
    title "LAB PROCESSES  ($(date -Is))"
    if ! ps -u "$(id -u)" -o pid=,ppid=,stat=,ni=,pcpu=,etime=,args= 2>/dev/null \
        | grep -E 'lab-(heartbeat|report-agent|queue-supervisor|queue-worker|zombie-parent)|<defunct>' \
        | grep -v grep; then
        printf '  (no lab process found)\n'
    fi

    title "HEARTBEAT FILE"
    if [ -r "$STATE_DIR/heartbeat" ]; then
        hb_val="$(cat "$STATE_DIR/heartbeat" 2>/dev/null || echo 0)"
        hb_age=$(( now - hb_val ))
        printf '  %s/heartbeat  ->  %s seconds old\n' "$STATE_DIR" "$hb_age"
    else
        printf '  %s/heartbeat  ->  missing\n' "$STATE_DIR"
    fi

    title "QUEUE"
    printf '  jobs processed : %s\n' "$(wc -l <"$STATE_DIR/processed.log" 2>/dev/null || echo 0)"
    printf '  respawns       : %s\n' "$(grep -c 'respawning' "$STATE_DIR/supervisor.log" 2>/dev/null || echo 0)"
    printf '  distinct worker PIDs seen: %s\n' \
        "$(awk '/processed job/ {print $3}' "$STATE_DIR/processed.log" 2>/dev/null | sort -u | wc -l)"

    title "SYSTEM"
    zcount="$(ps -eo stat= 2>/dev/null | grep -c '^Z')"
    printf '  %s\n' "$(uptime)"
    printf '  zombies on this host: %s\n' "$zcount"
    command -v free >/dev/null 2>&1 && free -h | sed 's/^/  /'
    printf '\n'
}

# --- grading -----------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
result() { # result PASS|FAIL "objective" "detail"
    if [ "$1" = "PASS" ]; then
        PASS_COUNT=$((PASS_COUNT+1))
        printf '  %s[PASS]%s %-46s %s\n' "$C_G" "$C_0" "$2" "$3"
    else
        FAIL_COUNT=$((FAIL_COUNT+1))
        printf '  %s[FAIL]%s %-46s %s\n' "$C_R" "$C_0" "$2" "$3"
    fi
}

verify() {
    title "GRADING - topic 103.5"

    # A - heartbeat alive, scheduled, and actually writing
    local hb st age now
    hb="$(lab_pid1 "$P_HEARTBEAT")"
    now="$(date +%s)"
    if [ -z "$hb" ]; then
        result FAIL "A. heartbeat agent running and refreshing" "no lab-heartbeat process (did you kill it?)"
    else
        st="$(proc_stat "$hb")"
        age=$(( now - $(cat "$STATE_DIR/heartbeat" 2>/dev/null || echo 0) ))
        if [ "${st:0:1}" = "T" ]; then
            result FAIL "A. heartbeat agent running and refreshing" "pid $hb is in state $st (stopped)"
        elif [ "$age" -gt 10 ]; then
            result FAIL "A. heartbeat agent running and refreshing" "pid $hb state $st but file is ${age}s old"
        else
            result PASS "A. heartbeat agent running and refreshing" "pid $hb state $st, file ${age}s old"
        fi
    fi

    # B - the signal-ignoring CPU hog must be gone
    if lab_alive "$P_AGENT"; then
        result FAIL "B. lab-report-agent terminated" "still alive: $(lab_pids "$P_AGENT" | tr '\n' ' ')"
    else
        result PASS "B. lab-report-agent terminated" "no matching process"
    fi

    # C - supervisor AND worker gone; wait out one respawn window before judging
    if lab_alive "$P_SUPERVISOR" || lab_alive "$P_WORKER"; then
        result FAIL "C. queue supervisor and worker terminated" \
            "supervisor='$(lab_pids "$P_SUPERVISOR" | tr '\n' ' ')' worker='$(lab_pids "$P_WORKER" | tr '\n' ' ')'"
    else
        sleep 3   # if the supervisor were alive, a new worker would appear here
        if lab_alive "$P_WORKER"; then
            result FAIL "C. queue supervisor and worker terminated" "a worker respawned - the parent is still running"
        else
            result PASS "C. queue supervisor and worker terminated" \
                "$(grep -c 'respawning' "$STATE_DIR/supervisor.log" 2>/dev/null || echo 0) respawn(s) logged before you stopped it"
        fi
    fi

    # D - zombie's parent reaped (init then reaps the defunct child)
    if [ -f "$STATE_DIR/zombie.skipped" ]; then
        result PASS "D. defunct process cleared" "skipped on this host (no python3/perl)"
    elif lab_alive "$P_ZOMBIE"; then
        result FAIL "D. defunct process cleared" "parent $(lab_pid1 "$P_ZOMBIE") still holds the <defunct> child"
    else
        result PASS "D. defunct process cleared" "parent gone, child reaped by init"
    fi

    rule
    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf '%s%s ALL %s OBJECTIVES PASSED - incident closed.%s\n\n' "$C_G" "$C_B" "$PASS_COUNT" "$C_0"
        printf 'Run "%s clean" to tear the lab down.\n\n' "$0"
        return 0
    fi
    printf '%s%s %s objective(s) still failing.%s Re-read the symptoms, then "%s status".\n\n' \
        "$C_R" "$C_B" "$FAIL_COUNT" "$C_0" "$0"
    return 1
}

clean() {
    title "TEARDOWN"
    local p
    for p in "$P_HEARTBEAT" "$P_AGENT" "$P_SUPERVISOR" "$P_WORKER" "$P_ZOMBIE"; do
        # SIGCONT first: a process stopped with SIGSTOP will never process a
        # pending SIGTERM until it is resumed. SIGKILL needs no such courtesy.
        pkill -CONT -u "$(id -u)" -f "$p" 2>/dev/null
        pkill -TERM -u "$(id -u)" -f "$p" 2>/dev/null
    done
    sleep 2
    for p in "$P_HEARTBEAT" "$P_AGENT" "$P_SUPERVISOR" "$P_WORKER" "$P_ZOMBIE"; do
        pkill -KILL -u "$(id -u)" -f "$p" 2>/dev/null
    done
    case "$LAB_DIR" in
        /var/tmp/*|/tmp/*|"$HOME"/*)
            rm -rf -- "$LAB_DIR" && log "removed $LAB_DIR" ;;
        *)  warn "refusing to remove '$LAB_DIR' automatically - delete it yourself" ;;
    esac
    log "lab processes stopped."
}

do_break() {
    if lab_alive "$P_HEARTBEAT" || lab_alive "$P_AGENT" || lab_alive "$P_SUPERVISOR"; then
        die "a lab is already running - run '$0 clean' first"
    fi
    confirm_disposable
    write_payloads
    log "starting the batch platform under $LAB_DIR ..."
    start_stack
    log "injecting the fault ..."
    inject_fault
    log "done. The incident is live."
    briefing
}

usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

require_tools
case "${1:-break}" in
    break|start|"")  do_break ;;
    status|st)       status ;;
    verify|check)    verify ;;
    clean|stop)      clean ;;
    help|-h|--help)  usage ;;
    *)               die "unknown action '$1' (break | status | verify | clean | help)" ;;
esac

# =============================================================================
# =============================================================================
#
#                        S O L U T I O N   -   S P O I L E R
#
#   Everything below is commented out. It is the incident walkthrough as a
#   senior SRE would run it: triage first, one fault at a time, least
#   destructive action that actually works, verification after each step.
#
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 - TRIAGE: how loaded is the box, and by whom?
# ---------------------------------------------------------------------------
#
#   $ uptime
#    03:14:07 up 1:22,  2 users,  load average: 1.04, 0.71, 0.33
#
#   Load ~1.0 on an otherwise idle VM means one runnable task is permanently on
#   the run queue. Load average counts RUNNING + UNINTERRUPTIBLE tasks, so it is
#   not automatically "CPU": confirm with a per-process view sorted by CPU.
#
#   $ free -h        # memory is fine - this is not an OOM/swap incident
#   $ top -b -n1 | head -15
#   $ ps -eo pid,ppid,stat,ni,pcpu,etime,args --sort=-pcpu | head -12
#
#     PID  PPID STAT  NI %CPU     ELAPSED COMMAND
#    4213     1 Rs     0 99.4       05:12 bash .../bin/lab-report-agent.sh ...
#    4207     1 Ts     0  0.0       05:14 bash .../bin/lab-heartbeat.sh ...
#    4210     1 Ss     0  0.0       05:14 bash .../bin/lab-queue-supervisor.sh ...
#    4390  4210 Ss     0  0.1       00:03 bash .../bin/lab-queue-worker.sh ...
#    4221     1 Ss     0  0.0       05:14 python3 .../bin/lab-zombie-parent.py ...
#    4222  4221 Z      0  0.0       05:14 [python3] <defunct>
#
#   Read the STAT column - it is the whole diagnosis (ps(1), "PROCESS STATE CODES"):
#       R running or runnable     S interruptible sleep   D uninterruptible sleep
#       T stopped by a job-control signal (SIGSTOP/SIGTSTP)   t traced/stopped
#       Z defunct ("zombie"): terminated, not yet reaped by its parent
#       s = session leader   + = foreground process group   l = multi-threaded
#
#   PPID 1 everywhere means these processes were detached (setsid) and adopted
#   by init/systemd. They belong to no shell's job table:
#
#   $ jobs
#   (prints nothing - jobs/bg/fg only ever see the CURRENT shell's children)
#
#   That is precisely why 'jobs', 'bg' and 'fg' cannot solve this lab and 'kill'
#   with a PID can. Job specs (%1) are shell-local; PIDs are system-wide.
#
# ---------------------------------------------------------------------------
# FAULT 1 - Stale heartbeat: a process in state T (SIGSTOP'ed, not dead)
# ---------------------------------------------------------------------------
#
#   $ date +%s; cat state/heartbeat        # ~5 minutes of drift
#   $ pgrep -a -u $(id -u) -f lab-heartbeat.sh
#   4207 bash /var/tmp/lpic1-103.5-lab/bin/lab-heartbeat.sh /var/tmp/.../state 176...
#
#   $ ps -o pid,stat,wchan:20,args -p 4207
#     PID STAT WCHAN                COMMAND
#    4207 Ts   do_signal_stop       bash .../lab-heartbeat.sh ...
#
#   $ grep -E '^(State|PPid):' /proc/4207/status
#   State:  T (stopped)
#   PPid:   1
#
#   Diagnosis: the process was suspended with SIGSTOP (19) - or SIGTSTP (20),
#   SIGTTIN (21), SIGTTOU (22), the four job-control stop signals. A stopped
#   process is fully alive: it holds its PID, memory and open files, it just is
#   not scheduled. Health checks based on "PID exists" or "pidfile present" go
#   green while the service does nothing. Note also that a SIGTERM sent now
#   stays PENDING and is only delivered once the process runs again.
#
#   Repair - resume it, do NOT kill it (objective A requires it alive):
#
#   $ kill -CONT 4207            # or: kill -s SIGCONT 4207   /  kill -18 4207
#   $ pkill -CONT -u $(id -u) -f lab-heartbeat.sh     # same thing, by pattern
#
#   Verify the file starts moving again:
#
#   $ watch -n1 'date +%s; cat /var/tmp/lpic1-103.5-lab/state/heartbeat'
#   $ ps -o pid,stat= -p 4207        # STAT must now be S (sleeping), not T
#
#   Signal numbers are not portable trivia - check them on the host itself:
#   $ kill -l | tr ' ' '\n' | head -20
#   $ kill -l 19                     # -> STOP        $ kill -l STOP   # -> 19
#   (On x86_64 Linux: 1 HUP, 2 INT, 3 QUIT, 9 KILL, 15 TERM, 17 CHLD,
#    18 CONT, 19 STOP, 20 TSTP. On other architectures they DIFFER: always
#    use names, never numbers, in scripts you expect to be portable.)
#
# ---------------------------------------------------------------------------
# FAULT 2 - The CPU hog that ignores SIGTERM
# ---------------------------------------------------------------------------
#
#   $ pgrep -a -f lab-report-agent.sh
#   4213 bash /var/tmp/lpic1-103.5-lab/bin/lab-report-agent.sh ...
#
#   $ kill 4213 ; echo "exit status: $?"
#   exit status: 0                     # the SIGNAL was delivered successfully
#   $ ps -o pid,stat,pcpu= -p 4213
#    4213 Rs  99.1                     # ...and the process is still there
#
#   'kill' returning 0 means "the signal was queued to the process", never "the
#   process died". Ask the process what it does with signals:
#
#   $ tail -3 state/report-agent.log
#   2026-08-26T03:19:41-03:00 caught SIGTERM - ignoring, report is 43% complete
#
#   $ grep -E 'SigIgn|SigCgt' /proc/4213/status
#   SigIgn: 0000000000000000
#   SigCgt: 0000000000014007
#
#   Decode the mask: it is a 64-bit hex bitmap where bit (n-1) set means signal
#   n is CAUGHT (SigCgt) or IGNORED (SigIgn). 0x14007 = bits 0,1,2,14,16 ->
#   signals 1 (HUP), 2 (INT), 3 (QUIT), 15 (TERM) and 17 (CHLD). Every polite
#   termination signal is handled by the program, so no polite signal will ever
#   end it. Bits 8 (KILL) and 18 (STOP) can never appear in those masks: the
#   kernel refuses to let a process catch, block or ignore SIGKILL and SIGSTOP.
#
#   Repair - escalate, after confirming there is no state to lose:
#
#   $ kill -9 4213                     # SIGKILL: uncatchable, unblockable
#   $ pkill -9 -u $(id -u) -f lab-report-agent.sh     # equivalent, by pattern
#   $ pgrep -f lab-report-agent.sh || echo "gone"
#   gone
#   $ uptime                           # load average starts decaying: 0.9, 0.8...
#
#   Production note: SIGKILL is the correct tool here and the wrong tool by
#   default. The process never runs cleanup, never flushes buffers, never
#   removes its pidfile or lock. The escalation ladder is SIGTERM -> wait a
#   documented grace period -> SIGKILL (this is exactly what systemd's
#   TimeoutStopSec/KillMode implements). If the process had merely been slow
#   rather than deliberately deaf, the right answer would have been to renice
#   it instead of killing it:
#
#   $ renice -n 19 -p 4213             # any user may LOWER priority
#   $ sudo renice -n -5 -p 4213        # only root may RAISE it (nice < 0)
#   $ nice -n 19 ./heavy-job.sh        # start it de-prioritised in the first place
#   (Interactively, top's 'k' sends a signal and 'r' renices a PID.)
#
# ---------------------------------------------------------------------------
# FAULT 3 - The immortal worker: kill the child, the parent rebuilds it
# ---------------------------------------------------------------------------
#
#   $ pkill -f lab-queue-worker.sh ; sleep 3 ; pgrep -a -f lab-queue-worker.sh
#   4501 bash .../lab-queue-worker.sh ...        # different PID, same program
#
#   Never fight a supervisor. Look UP the tree instead of at the symptom:
#
#   $ ps -eo pid,ppid,stat,args | grep -E 'lab-queue' | grep -v grep
#    4210     1 Ss  bash .../lab-queue-supervisor.sh ...
#    4501  4210 Ss  bash .../lab-queue-worker.sh ...
#
#   $ ps -o ppid= -p 4501           # the direct question: who is my parent?
#    4210
#   $ pstree -p 4210                # or the picture
#   lab-queue-super(4210)---lab-queue-work(4501)---sleep(4533)
#   $ ps -ejH | less                # forest view without pstree installed
#   $ tail -4 state/supervisor.log
#   ... worker pid 4390 exited (rc=143) - respawning in 2s
#
#   rc=143 = 128 + 15 = "terminated by signal 15 (SIGTERM)" - the shell's
#   convention for a signal death, and useful evidence in any postmortem.
#
#   Repair - stop the parent first, then the child (order is the entire lesson):
#
#   $ kill -TERM 4210                 # supervisor traps TERM and exits cleanly
#   $ sleep 3
#   $ pgrep -a -f 'lab-queue'         # expect no output
#   $ pkill -f lab-queue-worker.sh    # only if a worker outlived its parent
#
#   Equivalent single command, because the pattern matches both and the
#   supervisor takes its worker down with it:
#
#   $ pkill -f lab-queue              # -f matches the FULL command line
#
#   Be deliberate about pattern width. Always dry-run a pattern with pgrep
#   before handing it to pkill:
#
#   $ pgrep -a -u $(id -u) -f lab-queue     # LOOK first
#   $ pkill      -u $(id -u) -f lab-queue   # then act
#
#   killall(1) is the blunter relative: it matches the process NAME, not the
#   command line, so 'killall bash' here would kill your own shell. In this lab
#   every payload runs under 'bash', which is exactly why pgrep/pkill -f is the
#   right instrument and killall is not.
#
# ---------------------------------------------------------------------------
# FAULT 4 - The <defunct> entry that kill -9 cannot touch
# ---------------------------------------------------------------------------
#
#   $ ps -eo pid,ppid,stat,args | awk '$3 ~ /^Z/'
#    4222  4221 Z    [python3] <defunct>
#
#   $ kill -9 4222 ; ps -o pid,stat= -p 4222
#    4222 Z                            # nothing changed, and nothing will
#
#   A zombie is not a running process. It has already terminated: its memory,
#   file descriptors and threads are gone. What remains is one entry in the
#   process table holding the exit status, kept alive on purpose so the parent
#   can collect it with wait()/waitpid(). Signals have no target - there is no
#   code left to run a handler. A zombie consumes one PID and a few hundred
#   bytes; a few are harmless, thousands exhaust the PID space.
#
#   The bug is always in the PARENT (PPID 4221), which is not reaping:
#
#   $ ps -o pid,stat,args -p 4221
#    4221 Ss   python3 .../bin/lab-zombie-parent.py 176...
#
#   Repair - remove the parent. The kernel re-parents the orphaned zombie to
#   PID 1 (or the nearest subreaper), and init reaps it immediately:
#
#   $ kill -TERM 4221                 # polite first
#   $ sleep 1 ; ps -p 4222 -o pid,stat= || echo "reaped"
#   reaped
#   $ ps -eo stat= | grep -c '^Z'
#   0
#
#   (If the parent itself were stopped in state T, it could not reap either -
#   SIGCONT it first. A parent that ignores SIGCHLD or sets SA_NOCLDWAIT never
#   creates zombies at all; one that installs a handler and forgets to wait()
#   creates them forever.)
#
# ---------------------------------------------------------------------------
# STEP 5 - VERIFY, then close
# ---------------------------------------------------------------------------
#
#   $ ./lpic1-103.5-break-and-fix.sh verify
#     [PASS] A. heartbeat agent running and refreshing   pid 4207 state Ss, file 2s old
#     [PASS] B. lab-report-agent terminated              no matching process
#     [PASS] C. queue supervisor and worker terminated   3 respawn(s) logged
#     [PASS] D. defunct process cleared                  parent gone, child reaped by init
#     ALL 4 OBJECTIVES PASSED - incident closed.
#
#   $ ./lpic1-103.5-break-and-fix.sh clean
#
#   The complete repair, as a runbook (note that it never uses a blanket -9):
#
#     pkill -CONT -u $(id -u) -f lab-heartbeat.sh      # A: resume, do not kill
#     pkill -9    -u $(id -u) -f lab-report-agent.sh   # B: uncatchable, by design
#     pkill -TERM -u $(id -u) -f lab-queue-supervisor  # C: parent before child
#     pkill -TERM -u $(id -u) -f lab-queue-worker.sh   #    stragglers only
#     pkill -TERM -u $(id -u) -f lab-zombie-parent     # D: reap by killing the parent
#
# ---------------------------------------------------------------------------
# WHY 'pkill -9 -f lab-' WOULD HAVE FAILED
# ---------------------------------------------------------------------------
#
#   It kills the heartbeat agent (objective A demands it alive), it destroys
#   the evidence you need for a postmortem, and it uses the one signal no
#   process can defend itself against on three targets that would have exited
#   cleanly with SIGTERM. In production it also takes down anything else whose
#   command line happens to contain the string. Match narrowly, look before you
#   act (pgrep -a), escalate only when the polite signal is provably ignored.
#
# ---------------------------------------------------------------------------
# 103.5 REFERENCE CARD - what the exam actually asks about
# ---------------------------------------------------------------------------
#
#   Foreground / background, per shell:
#     cmd &            run in background      jobs -l    list with PIDs
#     Ctrl-Z           SIGTSTP -> state T     bg %1      resume in background (SIGCONT)
#     fg %1            bring to foreground    disown -h %1   detach from the job table
#     Ctrl-C           SIGINT                 Ctrl-\     SIGQUIT (+ core dump)
#
#   Surviving the terminal (SIGHUP on hangup):
#     nohup cmd &      ignore SIGHUP, output to nohup.out
#     setsid cmd       new session, no controlling terminal, PPID becomes 1
#     screen / tmux    a session you can detach from and reattach to later
#                      (tmux new -s lab / Ctrl-b d / tmux attach -t lab)
#
#   Monitoring:
#     ps aux           BSD syntax        ps -ef        UNIX syntax
#     ps -eo pid,ppid,stat,ni,pcpu,pmem,etime,args --sort=-pcpu    (custom)
#     ps -ejH / pstree -p     hierarchy       ps -C name     by command name
#     top / htop       live view; top -b -n1 for scripts and cron
#     watch -n2 'pgrep -a -f myapp'    poll any command on an interval
#     uptime           load average (1/5/15 min)      free -h   memory + swap
#     /proc/<pid>/{status,cmdline,fd,limits}          the source of truth
#
#   Signalling:
#     kill -l                     list signals on THIS architecture
#     kill -s TERM PID            polite stop (default of kill)
#     kill -9 PID                 SIGKILL - uncatchable, no cleanup
#     kill -CONT / -STOP PID      resume / suspend (state T)
#     kill -HUP PID               classic "reload configuration" convention
#     kill -0 PID                 send nothing: just test existence/permission
#     pgrep -a -u USER -f PAT     find     pkill -SIG -f PAT     act
#     killall -SIG name           by process NAME, not command line
#     Exit status 128+N in a shell means "died from signal N" (143 = TERM).
#
#   Sources: LPI 101-500 objectives (https://www.lpi.org/our-certifications/
#   exam-101-objectives/), signal(7), ps(1), kill(1), pgrep(1), proc(5) at
#   https://man7.org/linux/man-pages/, and the Bash manual's Job Control
#   chapter at https://www.gnu.org/software/bash/manual/bash.html#Job-Control
# =============================================================================