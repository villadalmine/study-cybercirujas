#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO 3.2 - AI cluster orchestration and job scheduling essentials
# Break & Fix lab: "The training job that never starts" (single-node Slurm)
#
# lab-resources: cpus=2 ram_mb=2048
#
# Scenario
#   You are the on-call operator of a small AI training cluster scheduled with
#   Slurm (the batch scheduler that NVIDIA Base Command Manager deploys and
#   that DGX SuperPOD reference architectures use for multi-node training).
#   A researcher submitted "llm-finetune" to the "train" partition an hour
#   ago. It is still PENDING, and the dashboard shows the only compute node
#   as not schedulable. Someone "tuned" slurm.conf last night.
#
#   The VM has no GPU, so the node is declared with CPUs and memory only. On a
#   real DGX node the same mechanics apply, plus Gres=gpu:8 and a gres.conf:
#   the node advertises its resources, slurmctld validates them against
#   slurm.conf, and a node that reports less than it was promised is pulled
#   out of service (DRAIN/INVAL) before it can take jobs.
#
# Modes (runner contract, teach/lab/spec.py)
#   ./break_fix.sh            same as "break": installs Slurm, builds the cluster, breaks it
#   ./break_fix.sh break      idem, idempotent
#   ./break_fix.sh verify     exit 0 only when the cluster schedules jobs again (persistently)
#   ./break_fix.sh cleanup    stops Slurm, restores previous files, removes what we installed
#
# References
#   Slurm slurm.conf (NodeName, RealMemory, PartitionName, State):
#     https://slurm.schedmd.com/slurm.conf.html
#   Slurm scontrol / sinfo / squeue: https://slurm.schedmd.com/scontrol.html
#   NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
#   NVIDIA AI Infrastructure and Operations Fundamentals:
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   Kubernetes scheduling (comparison point): https://kubernetes.io/docs/home/
#   GPU utilization with Run:ai: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
# =============================================================================
set -uo pipefail

LAB_NAME="nca-aiio-3.2-slurm"
STATE_DIR="/var/lib/study-lab/${LAB_NAME}"
PARTITION="train"
JOB_NAME="llm-finetune"
CLUSTER="aiio-lab"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
die()  { fail "$*"; exit 2; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root (sudo $0 ${1:-break})."
}

confirm() {
  # Never wait for a human when driven by the runner.
  if [ "${STUDY_LAB:-}" = "1" ] || [ "${LAB_DISPOSABLE:-}" = "yes" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "Not a terminal and STUDY_LAB/LAB_DISPOSABLE not set: refusing to modify this machine."
  fi
  printf '%s [y/N] ' "$1"
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) die "Aborted by user." ;; esac
}

conf_dir() {
  if [ -d /etc/slurm-llnl ] && [ ! -d /etc/slurm ]; then
    echo /etc/slurm-llnl
  else
    echo /etc/slurm
  fi
}

node_name() { hostname -s; }

install_packages() {
  mkdir -p "$STATE_DIR"
  if command -v slurmctld >/dev/null 2>&1 && command -v slurmd >/dev/null 2>&1 \
     && command -v munged >/dev/null 2>&1; then
    log "Slurm and MUNGE already present."
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || die "This lab needs a Debian/Ubuntu VM (apt-get not found)."
  log "Installing slurm-wlm and munge (this takes a minute)..."
  local before
  before="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || die "apt-get update failed (no network?)."
  apt-get install -y -qq slurm-wlm munge >/dev/null || die "apt-get install slurm-wlm munge failed."
  # Remember exactly which packages we added, so cleanup only removes those.
  comm -13 <(echo "$before") <(dpkg-query -W -f='${Package}\n' | sort) > "$STATE_DIR/installed-packages"
  log "Installed $(wc -l < "$STATE_DIR/installed-packages") packages."
}

setup_munge() {
  if [ ! -s /etc/munge/munge.key ]; then
    log "Creating MUNGE key."
    if command -v mungekey >/dev/null 2>&1; then
      mungekey -c -f -k /etc/munge/munge.key
    else
      dd if=/dev/urandom of=/etc/munge/munge.key bs=1024 count=1 status=none
    fi
    touch "$STATE_DIR/created-munge-key"
  fi
  chown munge:munge /etc/munge/munge.key
  chmod 0400 /etc/munge/munge.key
  systemctl enable --now munge >/dev/null 2>&1 || die "munge failed to start."
  munge -n | unmunge >/dev/null 2>&1 || die "MUNGE credential round-trip failed."
}

backup_conf() {
  local cd; cd="$(conf_dir)"
  mkdir -p "$cd" "$STATE_DIR"
  if [ -f "$cd/slurm.conf" ] && [ ! -f "$STATE_DIR/slurm.conf.orig" ] && [ ! -f "$STATE_DIR/no-orig" ]; then
    if ! grep -q "study-lab ${LAB_NAME}" "$cd/slurm.conf"; then
      cp -a "$cd/slurm.conf" "$STATE_DIR/slurm.conf.orig"
    fi
  elif [ ! -f "$cd/slurm.conf" ] && [ ! -f "$STATE_DIR/slurm.conf.orig" ]; then
    touch "$STATE_DIR/no-orig"
  fi
}

real_hw() {
  # Ask slurmd what the hardware really is: CPUs and RealMemory (MiB).
  local line
  line="$(slurmd -C 2>/dev/null | head -n1)"
  HW_CPUS="$(sed -n 's/.*CPUs=\([0-9]*\).*/\1/p' <<<"$line")"
  HW_MEM="$(sed -n 's/.*RealMemory=\([0-9]*\).*/\1/p' <<<"$line")"
  [ -n "$HW_CPUS" ] || HW_CPUS="$(nproc)"
  [ -n "$HW_MEM" ]  || HW_MEM="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
}

write_conf() {
  # $1 = RealMemory to declare, $2 = partition State
  local mem="$1" pstate="$2" cd node
  cd="$(conf_dir)"; node="$(node_name)"
  mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
  chown slurm:slurm /var/spool/slurmctld /var/log/slurm 2>/dev/null || true
  cat > "$cd/slurm.conf" <<EOF
# study-lab ${LAB_NAME} - managed by the lab script
ClusterName=${CLUSTER}
SlurmctldHost=${node}(127.0.0.1)
SlurmUser=slurm
AuthType=auth/munge
MpiDefault=none
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
JobAcctGatherType=jobacct_gather/none
AccountingStorageType=accounting_storage/none
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
ReturnToService=0
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldTimeout=60
SlurmdTimeout=60
#
# COMPUTE NODES
# On a DGX node this line would also carry: Gres=gpu:8
NodeName=${node} NodeAddr=127.0.0.1 CPUs=${HW_CPUS} RealMemory=${mem} State=UNKNOWN
#
# PARTITIONS
PartitionName=${PARTITION} Nodes=ALL Default=YES MaxTime=INFINITE State=${pstate}
EOF
  chmod 0644 "$cd/slurm.conf"
}

restart_slurm() {
  systemctl enable slurmctld slurmd >/dev/null 2>&1 || true
  systemctl restart slurmctld || die "slurmctld failed to start: journalctl -u slurmctld"
  local i
  for i in $(seq 1 30); do
    scontrol ping 2>/dev/null | grep -q 'UP' && break
    sleep 1
  done
  systemctl restart slurmd || die "slurmd failed to start: journalctl -u slurmd"
  sleep 3
}

queue_victim_job() {
  if squeue -h -n "$JOB_NAME" -o '%i' 2>/dev/null | grep -q .; then
    log "Job '$JOB_NAME' already queued."
    return 0
  fi
  sbatch -p "$PARTITION" -J "$JOB_NAME" -N1 -n1 --mem=128 \
         -o /tmp/${JOB_NAME}-%j.out --wrap "echo epoch 1/1 done on \$(hostname); sleep 5" >/dev/null \
    || die "sbatch failed."
}

do_break() {
  require_root break
  confirm "This installs Slurm and deliberately breaks it on THIS machine. Continue?"
  install_packages
  setup_munge
  backup_conf
  real_hw

  # Fault 1: the node is promised 8x the memory it really has.
  # Fault 2: the partition is administratively DOWN, persistently.
  local fake_mem=$(( HW_MEM * 8 ))
  write_conf "$fake_mem" "DOWN"
  # Start clean so the faults are what the student sees, not stale state.
  systemctl stop slurmd slurmctld >/dev/null 2>&1 || true
  rm -rf /var/spool/slurmctld/* 2>/dev/null || true
  restart_slurm
  queue_victim_job
  echo "broken" > "$STATE_DIR/state"

  cat <<EOF

=====================================================================
  LAB READY: "The training job that never starts"
=====================================================================
Symptoms you will see:
  \$ squeue
     JOBID PARTITION         NAME  USER ST  TIME NODES NODELIST(REASON)
         1     train llm-finetun  root PD  0:00     1 (PartitionDown)

  \$ sinfo -R      -> the node is out of service with a reason like
                    "Low RealMemory (reported:${HW_MEM} < 100.00% of configured:${fake_mem})"
  \$ sinfo         -> partition 'train' shows AVAIL=down, node in inval/drain

Your goal:
  1. Find out WHY the node was rejected (scontrol show node, sinfo -R,
     /var/log/slurm/slurmctld.log) and fix the node definition in
     $(conf_dir)/slurm.conf so it matches the real hardware (slurmd -C).
  2. Put the node back in service.
  3. Bring the 'train' partition UP - and make it survive a restart of
     slurmctld (a runtime-only fix does not count).
  4. '${JOB_NAME}' must run and a new job must be schedulable:
       srun -p ${PARTITION} -n1 --mem=64 hostname

Check your work with:  sudo $0 verify
Reset the machine with: sudo $0 cleanup
=====================================================================
EOF
}

do_verify() {
  require_root verify
  local rc=0 cd node conf_mem
  cd="$(conf_dir)"; node="$(node_name)"

  if [ ! -f "$STATE_DIR/state" ]; then
    fail "Lab not set up. Run: sudo $0 break"; return 1
  fi
  command -v scontrol >/dev/null 2>&1 || { fail "Slurm not installed."; return 1; }

  if ! scontrol ping 2>/dev/null | grep -q 'UP'; then
    fail "slurmctld is not responding (systemctl status slurmctld)."; return 1
  fi
  ok "slurmctld is up."

  real_hw
  conf_mem="$(sed -n "s/^NodeName=${node}.*RealMemory=\([0-9]*\).*/\1/p" "$cd/slurm.conf" | head -n1)"
  if [ -z "$conf_mem" ]; then
    fail "No RealMemory found for NodeName=${node} in $cd/slurm.conf."; rc=1
  elif [ "$conf_mem" -gt "$HW_MEM" ]; then
    fail "slurm.conf promises RealMemory=${conf_mem} MiB but the node has ${HW_MEM} MiB."; rc=1
  else
    ok "slurm.conf RealMemory=${conf_mem} <= real ${HW_MEM} MiB."
  fi

  if grep -Eq "^PartitionName=${PARTITION}\b.*State=(DOWN|INACTIVE|DRAIN)" "$cd/slurm.conf"; then
    fail "Partition '${PARTITION}' is still State=DOWN in slurm.conf: it will come back down on restart."; rc=1
  else
    ok "slurm.conf no longer forces '${PARTITION}' down."
  fi

  local pstate
  pstate="$(sinfo -h -p "$PARTITION" -o '%a' 2>/dev/null | head -n1)"
  if [ "$pstate" != "up" ]; then
    fail "Partition '${PARTITION}' availability is '${pstate:-unknown}' (expected up)."; rc=1
  else
    ok "Partition '${PARTITION}' is up."
  fi

  local nstate
  nstate="$(sinfo -h -n "$node" -o '%T' 2>/dev/null | head -n1)"
  case "$nstate" in
    idle|mixed|allocated|completing) ok "Node ${node} is schedulable (${nstate})." ;;
    *) fail "Node ${node} state is '${nstate:-unknown}' (expected idle/mixed/allocated). Check: sinfo -R"; rc=1 ;;
  esac

  if [ "$rc" -eq 0 ]; then
    if timeout 60 srun -p "$PARTITION" -N1 -n1 --mem=64 --immediate=30 hostname >/dev/null 2>&1; then
      ok "A test job ran on partition '${PARTITION}'."
    else
      fail "srun on '${PARTITION}' did not run within 60s."; rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if squeue -h -n "$JOB_NAME" -t PD -o '%i' | grep -q .; then
      fail "'${JOB_NAME}' is still PENDING: $(squeue -h -n "$JOB_NAME" -o '%r')"; rc=1
    else
      ok "'${JOB_NAME}' is no longer pending."
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    echo "fixed" > "$STATE_DIR/state"
    ok "Cluster is healthy and scheduling. Lab solved."
  else
    fail "Not fixed yet."
  fi
  return "$rc"
}

do_cleanup() {
  require_root cleanup
  local cd; cd="$(conf_dir)"
  if [ ! -d "$STATE_DIR" ]; then
    log "Nothing to clean up."
    return 0
  fi
  confirm "Stop Slurm and remove everything this lab created?"
  if command -v scancel >/dev/null 2>&1; then
    scancel -n "$JOB_NAME" >/dev/null 2>&1 || true
  fi
  systemctl stop slurmd slurmctld >/dev/null 2>&1 || true
  systemctl disable slurmd slurmctld >/dev/null 2>&1 || true

  if [ -f "$STATE_DIR/slurm.conf.orig" ]; then
    cp -a "$STATE_DIR/slurm.conf.orig" "$cd/slurm.conf"
    log "Restored original slurm.conf."
  elif [ -f "$cd/slurm.conf" ] && grep -q "study-lab ${LAB_NAME}" "$cd/slurm.conf"; then
    rm -f "$cd/slurm.conf"
    log "Removed lab slurm.conf."
  fi
  rm -rf /var/spool/slurmctld/* /var/spool/slurmd/* 2>/dev/null || true
  rm -f /tmp/${JOB_NAME}-*.out

  if [ -s "$STATE_DIR/installed-packages" ]; then
    log "Removing packages installed by the lab..."
    systemctl stop munge >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive xargs -a "$STATE_DIR/installed-packages" \
      apt-get purge -y -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
  elif [ -f "$STATE_DIR/created-munge-key" ]; then
    rm -f /etc/munge/munge.key
  fi
  rm -rf "$STATE_DIR"
  ok "Cleanup complete."
}

case "${1:-break}" in
  break)   do_break ;;
  verify)  do_verify; exit $? ;;
  cleanup) do_cleanup ;;
  *) echo "Usage: $0 [break|verify|cleanup]"; exit 2 ;;
esac

# =============================================================================
# SOLUTION (step by step) - try on your own first
# =============================================================================
# 1. Read the queue: the job tells you which gate it is stuck at.
#      squeue -o '%.6i %.9P %.12j %.2t %.10M %R'
#        JOBID PARTITION   NAME        ST  TIME  NODELIST(REASON)
#            1     train   llm-finetun PD  0:00  (PartitionDown)
#    Slurm evaluates the partition first; once it is up the reason would
#    change to (ReqNodeNotAvail...) or (Resources) because the node is out.
#
# 2. Look at the node and the reason the controller recorded:
#      sinfo -R
#        REASON                                             USER  TIMESTAMP  NODELIST
#        Low RealMemory (reported:1967 < 100.00% of ...)    slurm ...        lab-vm
#      scontrol show node $(hostname -s) | grep -E 'State|RealMemory|Reason'
#      grep -i realmemory /var/log/slurm/slurmctld.log
#    slurmd registers with the real hardware; slurmctld compares it with
#    slurm.conf and, if the node reports LESS than configured, marks it
#    INVAL/DRAIN so no job is placed on resources that do not exist (on a
#    GPU node the same happens when gres.conf finds fewer GPUs than Gres=gpu:8,
#    e.g. after a GPU falls off the bus - correlate with DCGM / nvidia-smi).
#
# 3. Ask the node what it really has and fix slurm.conf to match (declare a
#    little less memory than physical, to leave headroom for the OS):
#      slurmd -C
#        NodeName=lab-vm CPUs=2 ... RealMemory=1967
#      sudo sed -i -E 's/(RealMemory=)[0-9]+/\11900/' /etc/slurm/slurm.conf
#
# 4. Make the partition UP persistently (scontrol update alone is lost on
#    restart, because slurmctld re-reads State=DOWN from the file):
#      sudo sed -i -E 's/^(PartitionName=train .*State=)DOWN/\1UP/' /etc/slurm/slurm.conf
#
# 5. Node definition changes need a daemon restart (scontrol reconfigure is
#    not enough for RealMemory/CPUs in most Slurm versions):
#      sudo systemctl restart slurmctld slurmd
#
# 6. ReturnToService=0, so a node pulled out of service stays out until an
#    operator vouches for it:
#      sudo scontrol update NodeName=$(hostname -s) State=RESUME
#    (if the partition is still down at runtime:
#      sudo scontrol update PartitionName=train State=UP)
#
# 7. Confirm:
#      sinfo
#        PARTITION AVAIL TIMELIMIT NODES STATE NODELIST
#        train*    up    infinite      1 idle  lab-vm
#      squeue              # llm-finetune ran (or is running) and is gone
#      cat /tmp/llm-finetune-*.out
#        epoch 1/1 done on lab-vm
#      srun -p train -n1 --mem=64 hostname
#      sudo ./break_fix.sh verify
#
# Takeaways for NCA-AIIO 3.2
#   - The scheduler (Slurm, or kube-scheduler/Run:ai on Kubernetes) only
#     places jobs on resources a node advertises AND the control plane
#     accepts; config/hardware mismatches silently starve the queue.
#   - Pending reasons (PartitionDown, ReqNodeNotAvail, Resources, Priority)
#     are the first diagnostic: read them before touching anything.
#   - Fix in the source of truth (slurm.conf, managed by Base Command Manager
#     in production), not only at runtime, or the outage returns on restart.
# =============================================================================