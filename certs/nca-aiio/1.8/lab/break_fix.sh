#!/usr/bin/env bash
# =============================================================================
#  NCA-AIIO | Topic 1.8 | Compare and contrast GPU and CPU architectures
#  BREAK & FIX LAB: "The throughput job that runs on one core"
# =============================================================================
#
#  RUN THIS ONLY IN A DISPOSABLE LAB VM. It needs root, systemd, python3 and
#  at least 2 vCPUs. It does NOT need a GPU. Everything it creates lives in:
#     /opt/lab-gpucpu/                         (benchmark code)
#     /etc/lab-gpucpu/                         (benchmark config)
#     /var/lib/lab-gpucpu/                     (results)
#     /etc/systemd/system/lab-gpucpu-bench.service and its .service.d/ drop-ins
#  "sudo ./lab-1.8-break-fix.sh reset" removes all of it.
#
#  Usage:
#     sudo ./lab-1.8-break-fix.sh break    # build the lab and inject the faults
#     sudo ./lab-1.8-break-fix.sh status   # show the last benchmark result
#     sudo ./lab-1.8-break-fix.sh hint     # progressive hints
#     sudo ./lab-1.8-break-fix.sh verify   # grade your fix
#     sudo ./lab-1.8-break-fix.sh reset    # remove everything
#
# -----------------------------------------------------------------------------
#  WHY THIS LAB EXISTS (theory you need for the exam)
# -----------------------------------------------------------------------------
#  A CPU is a LATENCY-optimized processor: a few large, complex cores
#  (out-of-order execution, branch prediction, deep cache hierarchies,
#  high clock), each built to finish ONE instruction stream as fast as
#  possible. Server CPUs ship tens of cores (roughly 32-128+ per socket).
#
#  A GPU is a THROUGHPUT-optimized processor: many simple cores grouped in
#  Streaming Multiprocessors (SMs) running the SIMT model (Single
#  Instruction, Multiple Threads). Threads are scheduled in warps of 32;
#  while one warp waits on memory, the SM switches to another warp at
#  near-zero cost. The GPU hides latency with massive parallelism instead
#  of with big caches. Example, NVIDIA H100 SXM: 132 SMs, 16,896 FP32 CUDA
#  cores, 528 fourth-gen Tensor Cores, 80 GB HBM3 at ~3.35 TB/s. A dual-
#  socket CPU server with DDR5 sits in the hundreds of GB/s.
#
#  Consequences you are expected to know:
#   * Matrix multiply / convolution / attention = the same arithmetic over
#     millions of independent elements. That is data parallelism, which
#     is exactly what GPUs (and Tensor Cores for mixed precision
#     FP16/BF16/FP8/INT8) are built for. Training and high-volume inference
#     go to the GPU, with libraries such as cuDNN and TensorRT on top.
#   * Branch-heavy, serial, OS, orchestration, data loading/decoding,
#     tokenization and pre/post-processing stay on the CPU. A GPU server
#     still needs a strong CPU: if the CPU side is starved, the GPU sits
#     idle waiting for data ("CPU-bound input pipeline").
#   * Amdahl's law caps speedup: S(n) = 1 / ((1 - p) + p/n). If only a
#     fraction p of the work is parallel, adding cores (or a GPU) does not
#     speed up the serial part.
#   * Parallel hardware only helps if the software is ALLOWED to use it.
#     Thread counts, CPU affinity, cgroup quotas (Kubernetes CPU limits),
#     and in K8s the "nvidia.com/gpu" resource exposed by the NVIDIA
#     device plugin / GPU Operator, all decide how much parallel hardware
#     a workload actually gets.
#
#  This VM has no GPU, so the lab reproduces the core lesson on the CPU:
#  an embarrassingly parallel (GPU-style) workload has been configured so
#  it can only use ONE core of the machine. It behaves like a throughput
#  job forced onto a latency architecture. You must find every layer that
#  takes its parallelism away.
#
#  Official sources:
#   - NVIDIA AI Infrastructure and Operations study guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   - NVIDIA Academy, AI Infrastructure and Operations Fundamentals:
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   - NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
#   - NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
#   - Scaling storage for AI training and inferencing:
#     https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
#   - What are LLMs used for:
#     https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
#   - NVIDIA GPU Operator in Kubernetes:
#     https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
#   - CUDA C++ Programming Guide (SIMT, warps, SMs):
#     https://docs.nvidia.com/cuda/cuda-c-programming-guide/
# =============================================================================

set -euo pipefail

LAB=lab-gpucpu
UNIT=${LAB}-bench.service
UNIT_FILE=/etc/systemd/system/${UNIT}
DROPIN_DIR=/etc/systemd/system/${UNIT}.d
OPT_DIR=/opt/${LAB}
ETC_DIR=/etc/${LAB}
STATE_DIR=/var/lib/${LAB}
ENV_FILE=${ETC_DIR}/bench.env
BENCH=${OPT_DIR}/bench.py
BASELINE=${STATE_DIR}/baseline.json
RESULT=${STATE_DIR}/result.json

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_rst=$'\e[0m'
info() { printf '%s[INFO]%s %s\n' "$c_cyn" "$c_rst" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$c_grn" "$c_rst" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*"; }
die()  { fail "$*"; exit 1; }

preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 $*)."
  [[ -d /run/systemd/system ]] || die "systemd is not PID 1 on this machine; this lab needs systemd."
  command -v python3 >/dev/null || die "python3 not found. Install it (dnf/apt install python3)."
  NPROC=$(nproc)
  (( NPROC >= 2 )) || die "This VM has ${NPROC} vCPU. Give it at least 2 (ideally 4+) and retry."
  PY3=$(command -v python3)
}

write_bench() {
  install -d -m 0755 "$OPT_DIR" "$ETC_DIR" "$STATE_DIR"
  cat > "$BENCH" <<'PYEOF'
#!/usr/bin/env python3
"""Embarrassingly parallel integer workload (stand-in for a GPU-style kernel).

Each task is independent, like one tile of a matrix multiply. With N usable
cores the ideal wall time is T1/N. Do not edit this file: the lab is about
the platform configuration around it.
"""
import json
import multiprocessing as mp
import os
import time

ITERS = int(os.environ.get("BENCH_ITERS", "1000000"))


def work(seed):
    x = seed + 1
    acc = 0
    for _ in range(ITERS):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        acc ^= x
    return acc


def cgroup_cpu_max():
    try:
        with open("/proc/self/cgroup") as fh:
            for line in fh:
                if line.startswith("0::"):
                    path = line.strip().split("::", 1)[1]
                    with open(f"/sys/fs/cgroup{path}/cpu.max") as cm:
                        return cm.read().strip()
    except OSError:
        pass
    return "unknown"


def main():
    allowed = sorted(os.sched_getaffinity(0))
    req = os.environ.get("BENCH_WORKERS", "auto").strip()
    workers = len(allowed) if req == "auto" else max(1, int(req))
    tasks = int(os.environ.get("BENCH_TASKS", "32"))

    t0 = time.perf_counter()
    with mp.Pool(workers) as pool:
        res = pool.map(work, range(tasks), chunksize=1)
    elapsed = time.perf_counter() - t0

    checksum = 0
    for r in res:
        checksum ^= r

    out = {
        "timestamp": time.time(),
        "workers": workers,
        "allowed_cpus": allowed,
        "tasks": tasks,
        "iters": ITERS,
        "elapsed_s": round(elapsed, 3),
        "tasks_per_s": round(tasks / elapsed, 2),
        "cpu_max": cgroup_cpu_max(),
        "checksum": checksum,
    }
    path = os.environ.get("BENCH_OUT") or os.path.join(
        os.environ.get("STATE_DIRECTORY", "/var/lib/lab-gpucpu"), "result.json")
    with open(path, "w") as fh:
        json.dump(out, fh, indent=2)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
PYEOF
  chmod 0755 "$BENCH"
}

write_unit() {
  local tasks=$(( NPROC * 4 > 32 ? NPROC * 4 : 32 ))
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Lab 1.8 parallel throughput benchmark (GPU-style workload on CPU)
After=multi-user.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
StateDirectory=${LAB}
ExecStart=${PY3} ${BENCH}
EOF

  # Fault 1: the application layer. Looks like a harmless tuning comment.
  cat > "$ENV_FILE" <<EOF
# Benchmark settings
BENCH_TASKS=${tasks}
BENCH_ITERS=1000000
# Reduced worker count to keep p99 latency stable (see PERF-1142)
BENCH_WORKERS=1
EOF

  install -d -m 0755 "$DROPIN_DIR"
  # Fault 2: the scheduler layer. Pin the whole service to CPU 0.
  cat > "${DROPIN_DIR}/10-latency-tuning.conf" <<'EOF'
[Service]
# Pin to a single core for predictable latency (PERF-1142)
CPUAffinity=0
EOF
  # Fault 3: the cgroup layer. Hidden behind the other two: it only bites
  # once the student has fixed affinity and worker count.
  cat > "${DROPIN_DIR}/50-fair-share.conf" <<'EOF'
[Service]
# Fair share on the shared lab host
CPUQuota=100%
EOF
}

do_break() {
  preflight
  if [[ -f "$UNIT_FILE" ]]; then
    warn "Lab already present. Run '$0 reset' first if you want a clean start."
  fi
  info "Hardware on this VM:"
  lscpu 2>/dev/null | grep -E '^(Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|L3 cache)' || true
  if command -v nvidia-smi >/dev/null 2>&1; then
    info "An NVIDIA GPU is visible too (not required for this lab):"
    nvidia-smi --query-gpu=name,memory.total,clocks.max.sm --format=csv || true
  else
    info "No nvidia-smi: expected on a CPU-only lab VM."
  fi

  write_bench
  write_unit
  local tasks; tasks=$(grep -E '^BENCH_TASKS=' "$ENV_FILE" | cut -d= -f2)

  info "Measuring the single-core baseline T1 (${tasks} tasks, may take a little while)..."
  BENCH_WORKERS=1 BENCH_TASKS="$tasks" BENCH_ITERS=1000000 BENCH_OUT="$BASELINE" \
    "$PY3" "$BENCH" >/dev/null
  chmod 0444 "$BASELINE"

  systemctl daemon-reload
  info "Running the production service once..."
  systemctl start "$UNIT" || true

  cat <<EOF

${c_ylw}==================== INCIDENT TICKET ====================${c_rst}
 The data team moved its "tile compute" job onto a ${NPROC}-vCPU node.
 The job is embarrassingly parallel (every task independent, exactly the
 kind of work a GPU eats). Capacity planning promised it would scale with
 cores. It does not: wall time on ${NPROC} vCPUs is the same as on 1.

 SYMPTOMS you will see:
   * 'sudo $0 status' shows elapsed_s close to the single-core baseline.
   * 'top' / 'mpstat -P ALL 1' while the service runs: one CPU at 100%,
     the rest idle.
   * After you fix the obvious part, it is STILL slow. Keep digging.

 GOAL:
   * ${UNIT} uses all ${NPROC} vCPUs and reaches a speedup of at least
     $( "$PY3" -c "print(round(max(1.3, 0.45*min(${NPROC},8)),2))" )x over the single-core baseline.
   * Fix it through configuration only. Do NOT edit ${BENCH}, do NOT
     change BENCH_TASKS/BENCH_ITERS (the checksum must match the baseline),
     do NOT delete the unit file.
   * Then run: sudo $0 verify

 Starting points: systemctl cat, systemd-delta, systemctl show, /proc/<pid>/status,
 /sys/fs/cgroup. Think about every layer between the code and the cores.
${c_ylw}=========================================================${c_rst}
EOF
}

do_status() {
  preflight
  [[ -f "$BASELINE" ]] || die "Lab not initialized. Run: sudo $0 break"
  echo "--- baseline (1 worker, unrestricted) ---"; cat "$BASELINE"; echo
  if [[ -f "$RESULT" ]]; then
    echo "--- last service run ---"; cat "$RESULT"; echo
  else
    warn "No service result yet. Run: systemctl start ${UNIT}"
  fi
}

do_hint() {
  cat <<'EOF'
Hint 1: The service has more configuration than the unit file. Compare
        'systemctl cat lab-gpucpu-bench.service' with 'systemd-delta --type=extended'.
Hint 2: There are THREE layers that can take parallelism away from a process:
        the application (how many workers it starts), the scheduler (which
        CPUs it may run on) and the cgroup (how much CPU time it may consume).
Hint 3: Look at Cpus_allowed_list in /proc/<pid>/status while it runs, and
        at 'systemctl show -p CPUAffinity -p CPUQuotaPerSecUSec'.
        CPUQuota=100% means "one CPU's worth of time", no matter how many cores.
Hint 4: systemd does not see edited files until you run 'systemctl daemon-reload'.
EOF
}

do_verify() {
  preflight
  [[ -f "$BASELINE" && -f "$UNIT_FILE" ]] || die "Lab not initialized (or the unit was deleted). Run: sudo $0 break"
  [[ -f "$BENCH" ]] || die "${BENCH} is missing."

  local need; need=$(systemctl show -p NeedDaemonReload --value "$UNIT")
  if [[ "$need" == "yes" ]]; then
    fail "Unit files changed on disk but systemd still runs the old config."
    die  "Run 'systemctl daemon-reload' and verify again."
  fi

  info "Effective service settings:"
  systemctl show -p CPUAffinity -p CPUQuotaPerSecUSec -p Environment "$UNIT" | sed 's/^/    /'

  local start; start=$(date +%s)
  info "Running ${UNIT}..."
  if ! timeout 600 systemctl start "$UNIT"; then
    journalctl -u "$UNIT" -n 20 --no-pager || true
    die "The service failed. Read the journal above."
  fi

  "$PY3" - "$BASELINE" "$RESULT" "$NPROC" "$start" <<'PY'
import json, sys
G, R, X = "\033[32m", "\033[31m", "\033[0m"
b = json.load(open(sys.argv[1]))
r = json.load(open(sys.argv[2]))
n = int(sys.argv[3])
started = float(sys.argv[4])
good = True

def check(cond, msg_ok, msg_bad):
    global good
    print(f"{G}[ OK ]{X} {msg_ok}" if cond else f"{R}[FAIL]{X} {msg_bad}")
    good = good and cond

check(r["timestamp"] >= started, "Result produced by this run.",
      "result.json is stale: the service did not write a fresh result.")
check(r["tasks"] == b["tasks"] and r["iters"] == b["iters"] and r["checksum"] == b["checksum"],
      "Same amount of work as the baseline (checksum matches).",
      "Work changed (tasks/iters/checksum differ). Restore BENCH_TASKS/BENCH_ITERS.")
check(len(r["allowed_cpus"]) == n,
      f"Service may run on all {n} CPUs: {r['allowed_cpus']}.",
      f"Service may only run on CPUs {r['allowed_cpus']} (scheduler layer: CPU affinity).")
check(r["workers"] >= n,
      f"Application starts {r['workers']} workers.",
      f"Application starts only {r['workers']} worker(s) (application layer).")
cpu_max = r.get("cpu_max", "unknown")
quota_ok = cpu_max.startswith("max") or cpu_max == "unknown"
if not quota_ok:
    q, period = cpu_max.split()
    quota_ok = int(q) / int(period) >= n * 0.95
check(quota_ok, f"cgroup cpu.max = '{cpu_max}' (no throttling).",
      f"cgroup cpu.max = '{cpu_max}': the service is throttled (cgroup layer: CPUQuota).")

S = b["elapsed_s"] / r["elapsed_s"] if r["elapsed_s"] > 0 else 0
target = max(1.3, 0.45 * min(n, 8))
eff_n = min(n, r["workers"], len(r["allowed_cpus"]))
p = (1 - 1 / S) / (1 - 1 / eff_n) if S > 1 and eff_n > 1 else 0.0
print()
print(f"  T1 (baseline)        : {b['elapsed_s']:.2f} s")
print(f"  Tn (service, n={n:<3}) : {r['elapsed_s']:.2f} s")
print(f"  Speedup S = T1/Tn    : {S:.2f}x   (target >= {target:.2f}x, ideal {n}x)")
print(f"  Amdahl parallel frac : p ~ {min(p,1.0):.2f}")
print()
check(S >= target, "Throughput scales with cores.",
      "Speedup below target. Some layer still serializes the work.")
sys.exit(0 if good else 1)
PY
  local rc=$?
  if (( rc == 0 )); then
    ok "LAB COMPLETE. The parallel workload now uses the parallel hardware."
    echo "   Reflect: a GPU would push this same pattern from ${NPROC} lanes to thousands."
  else
    die "Not fixed yet. Try: sudo $0 hint"
  fi
}

do_reset() {
  [[ $EUID -eq 0 ]] || die "Run as root."
  systemctl stop "$UNIT" 2>/dev/null || true
  rm -rf "$DROPIN_DIR" "$UNIT_FILE" "$OPT_DIR" "$ETC_DIR" "$STATE_DIR"
  systemctl daemon-reload
  systemctl reset-failed "$UNIT" 2>/dev/null || true
  ok "Lab removed."
}

case "${1:-break}" in
  break)  do_break ;;
  status) do_status ;;
  hint)   do_hint ;;
  verify) do_verify ;;
  reset)  do_reset ;;
  *) echo "Usage: $0 {break|status|hint|verify|reset}"; exit 2 ;;
esac

# =============================================================================
#  SOLUTION (read only after trying)
# =============================================================================
#
#  STEP 1. Confirm the symptom: one core busy, the rest idle.
#    sudo systemctl start lab-gpucpu-bench.service &
#    mpstat -P ALL 1 3        # (sysstat) or: top, then press 1
#  Expected: one CPU at ~100% %usr, all others ~0%. Wall time in
#  'sudo ./lab-1.8-break-fix.sh status' is about the same as the baseline.
#
#  STEP 2. See ALL the configuration, not only the unit file.
#    systemctl cat lab-gpucpu-bench.service
#    systemd-delta --type=extended
#  Expected: the unit plus two drop-ins:
#    /etc/systemd/system/lab-gpucpu-bench.service.d/10-latency-tuning.conf -> CPUAffinity=0
#    /etc/systemd/system/lab-gpucpu-bench.service.d/50-fair-share.conf     -> CPUQuota=100%
#  and EnvironmentFile=/etc/lab-gpucpu/bench.env.
#
#  STEP 3. Inspect the effective values.
#    systemctl show -p CPUAffinity -p CPUQuotaPerSecUSec -p Environment lab-gpucpu-bench.service
#  Expected while broken:
#    CPUAffinity=0
#    CPUQuotaPerSecUSec=1s        <- 1 s of CPU per wall-clock second = 1 CPU
#  While it runs:
#    grep Cpus_allowed_list /proc/$(pgrep -of bench.py)/status   -> Cpus_allowed_list: 0
#
#  STEP 4. Fix the APPLICATION layer (worker count).
#    sudo sed -i 's/^BENCH_WORKERS=1$/BENCH_WORKERS=auto/' /etc/lab-gpucpu/bench.env
#  "auto" = one worker per CPU the process is allowed to use
#  (os.sched_getaffinity). Note: with CPUAffinity=0 still in place, "auto"
#  still yields 1 worker, and a hard-coded "BENCH_WORKERS=8" would only
#  oversubscribe CPU 0: more threads than cores does not add compute
#  throughput on a CPU. A GPU, by contrast, WANTS many more threads than
#  cores so warps can hide memory latency.
#
#  STEP 5. Fix the SCHEDULER layer (CPU affinity).
#    sudo rm /etc/systemd/system/lab-gpucpu-bench.service.d/10-latency-tuning.conf
#  (Pinning is a valid latency technique for a single-threaded, cache-
#  sensitive service. Applied to a throughput job, it throws away every
#  core but one.)
#
#  STEP 6. Reload and re-test. It is better but still far from Nx.
#    sudo systemctl daemon-reload
#    sudo systemctl start lab-gpucpu-bench.service
#    sudo ./lab-1.8-break-fix.sh status
#  mpstat now shows ALL CPUs busy, but each at about 100/N %: the cgroup
#  is throttling. Confirm while it runs:
#    cat /sys/fs/cgroup/system.slice/lab-gpucpu-bench.service/cpu.max   -> 100000 100000
#    cat /sys/fs/cgroup/system.slice/lab-gpucpu-bench.service/cpu.stat  -> nr_throttled grows
#
#  STEP 7. Fix the CGROUP layer (CPU quota).
#    sudo rm /etc/systemd/system/lab-gpucpu-bench.service.d/50-fair-share.conf
#    # Alternative if policy requires a quota: size it for the job,
#    # e.g. CPUQuota=$(( $(nproc) * 100 ))%
#    sudo systemctl daemon-reload
#
#  STEP 8. Verify.
#    sudo ./lab-1.8-break-fix.sh verify
#  Expected: all checks OK, cpu.max = 'max 100000', speedup close to N
#  (for example 3.6x on 4 vCPUs), Amdahl p around 0.95+. It is not exactly
#  Nx because of pool startup, process creation and result collection,
#  the serial part that Amdahl's law says no extra hardware can remove.
#
#  WHAT TO TAKE TO THE EXAM AND TO PRODUCTION
#   * CPU = few complex cores, latency-optimized, large caches, branch
#     prediction; GPU = many simple cores in SMs, SIMT warps of 32,
#     Tensor Cores, HBM bandwidth; throughput-optimized.
#   * Data-parallel math (training, batch inference) belongs on the GPU;
#     serial and control-heavy work (OS, scheduling, data loading,
#     tokenization, pre/post-processing) stays on the CPU.
#   * The same three layers exist on a GPU node in Kubernetes:
#       application -> DataLoader num_workers, batch size, CUDA streams
#       scheduler   -> pod requests for nvidia.com/gpu (device plugin / GPU
#                      Operator), CPU Manager / NUMA alignment with the GPU
#       cgroup      -> pod CPU limits (CFS quota). A tight CPU limit on a
#                      training pod throttles the input pipeline and leaves
#                      an expensive GPU idle: check nvidia-smi utilization
#                      together with container_cpu_cfs_throttled_periods_total.
#   * Always diagnose top to bottom: what the code asks for, what the
#     scheduler allows, what the cgroup grants, what the hardware offers.
# =============================================================================