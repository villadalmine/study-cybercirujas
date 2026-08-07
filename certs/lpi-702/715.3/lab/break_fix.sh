#!/usr/bin/env bash
# ==============================================================================
# LPI-702 (Exam 702-100 v1.0) - BSD Specialist
# Topic 715.3: Create, Monitor and Kill Processes
# Break & Fix Lab Scenario: Signal Trapping, Rogue Daemons & Process Supervision
# Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi702_lab_715_3"
WORKER_SCRIPT="${LAB_DIR}/rogue_worker.sh"
SUPERVISOR_PID_FILE="${LAB_DIR}/supervisor.pid"
LOG_FILE="${LAB_DIR}/output.log"

cleanup() {
    pkill -9 -f "${LAB_DIR}" 2>/dev/null || true
    rm -rf "${LAB_DIR}"
}

# Trap EXIT to clean up automatically when lab script finishes
trap cleanup EXIT

# Initialize Lab Directory
mkdir -p "${LAB_DIR}"

# Create rogue worker script that traps SIGTERM and spawns background children
cat << 'EOF' > "${WORKER_SCRIPT}"
#!/bin/sh
# Trapping SIGTERM (15) to ignore standard graceful kill requests
trap 'echo "[$(date)] SIGTERM (15) ignored by rogue worker (PID $$)" >> /tmp/lpi702_lab_715_3/output.log' TERM

# Spawn background child process (orphan hazard)
( while true; do sleep 1; done ) &

# Rogue worker loop logging activity
while true; do
    echo "[$(date)] Rogue worker running (PID $$)" >> /tmp/lpi702_lab_715_3/output.log
    sleep 2
done
EOF

chmod +x "${WORKER_SCRIPT}"

# Launch process under supervision
if command -v daemon >/dev/null 2>&1; then
    # FreeBSD daemon(8) utility with supervisor restart (-r) flag
    daemon -r -p "${SUPERVISOR_PID_FILE}" "${WORKER_SCRIPT}" >/dev/null 2>&1
else
    # POSIX fallback loop emulating BSD supervisor behavior
    (
        while true; do
            "${WORKER_SCRIPT}" &
            CHILD_PID=$!
            echo "${CHILD_PID}" > "${SUPERVISOR_PID_FILE}"
            wait "${CHILD_PID}" 2>/dev/null || true
            sleep 1
        done
    ) >/dev/null 2>&1 &
fi

sleep 2

# Display Lab Scenario Briefing
cat << 'EOF'
==============================================================================
LPI-702 Topic 715.3: Create, Monitor and Kill Processes - Break & Fix Lab
==============================================================================

SCENARIO REPORT:
A background worker process running on a production BSD node is malfunctioning.
1. The process continuously writes logs to /tmp/lpi702_lab_715_3/output.log.
2. Standard termination attempts (`kill <PID>` or `pkill -f rogue_worker`) fail:
   - Sending default SIGTERM (15) is ignored by the worker script.
   - Forcibly killing the worker PID causes it to instantly respawn with a 
     new PID due to an active supervisor daemon.
3. Orphaned child background tasks remain lingering in the process table.

YOUR OBJECTIVES:
1. Use BSD process monitoring commands (`ps`, `pgrep`, `top`, `procstat`) to 
   analyze the running processes, parent-child relationships (PPID), and 
   signal dispositions.
2. Identify why `kill` without specific flags fails to terminate the worker.
3. Identify the supervisor process responsible for automatic process resurrection.
4. Safely kill the supervisor first, then force-kill the rogue process and 
   clean up any orphaned child processes using correct BSD signal semantics.
5. Verify that no related processes are left running and log output stops.

ENVIRONMENT DETAILS:
- Lab Path: /tmp/lpi702_lab_715_3
- Target Script: rogue_worker.sh
- Output Log: /tmp/lpi702_lab_715_3/output.log

Press ENTER to hold the break state active while you inspect from another shell.
(Press ENTER a second time when finished to dismantle the lab environment)
EOF

read -r _ || true
echo "Lab environment actively held. Press ENTER to stop and clean up."
read -r _ || true

# ==============================================================================
# STEP-BY-STEP DIAGNOSIS AND SOLUTION (LPI-702 Topic 715.3 Reference Solution)
# ==============================================================================
#
# STEP 1: Process Discovery and Tree Inspection
# ---------------------------------------------
# Inspect process list using BSD output format modifiers to locate PIDs and PPIDs:
#
#   $ ps -ax -o pid,ppid,state,command | grep -E "rogue_worker|daemon"
#
# Expected output snippet:
#   PID   PPID STAT COMMAND
# 10420      1 Ss   daemon -r -p /tmp/lpi702_lab_715_3/supervisor.pid ...
# 10421  10420 S    /bin/sh /tmp/lpi702_lab_715_3/rogue_worker.sh
# 10422  10421 S    sleep 1
#
# Diagnostic Finding:
# - PID 10421 (`rogue_worker.sh`) has PPID 10420 (`daemon -r`).
# - `daemon -r` acts as a process supervisor on FreeBSD, auto-restarting the child
#   whenever it exits or is killed.
#
# STEP 2: Inspect Signal Dispositions with procstat(1)
# ----------------------------------------------------
# Check signal handling configuration for the worker process using BSD `procstat`:
#
#   $ procstat -s 10421
#
# Output snippet:
#   PID COMM             SIG          DISP
# 10421 rogue_worker.sh  TERM         C    (C = Caught/Trapped)
#
# Diagnostic Finding:
# - The process has explicit trap handlers for SIGTERM (signal 15).
# - Standard `kill 10421` (defaulting to SIGTERM) triggers the trap handler and 
#   fails to stop execution.
#
# STEP 3: Identify All Related Process Group PIDs
# -----------------------------------------------
# Use `pgrep` to list all PIDs matching the lab path:
#
#   $ pgrep -lf /tmp/lpi702_lab_715_3
#
# STEP 4: Execution of Solution
# ------------------------------
# Action 1: Terminate the supervisor process FIRST so it cannot respawn the worker.
#   $ kill -15 10420
#   (Or read supervisor PID directly: `kill $(cat /tmp/lpi702_lab_715_3/supervisor.pid)`)
#
# Action 2: Send un-trappable SIGKILL (signal 9) to the rogue worker process.
#   $ pkill -9 -f rogue_worker.sh
#
# Action 3: Kill lingering orphan child processes spawned by the script.
#   $ pkill -9 -f "sleep 1"
#
# STEP 5: Verification
# --------------------
# Confirm process table is clean:
#   $ pgrep -lf /tmp/lpi702_lab_715_3
#   (Output should be empty)
#
# Monitor log file to confirm writes have ceased:
#   $ tail -n 5 -f /tmp/lpi702_lab_715_3/output.log
# ==============================================================================