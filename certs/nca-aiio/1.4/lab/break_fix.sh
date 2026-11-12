#!/usr/bin/env bash
# =============================================================================
#  NCA-AIIO | Topic 1.4 - Factors behind the recent rapid improvement and
#  adoption of AI
#  BREAK & FIX LAB: "The inference SLO that nobody can explain"
# -----------------------------------------------------------------------------
#  What this lab teaches (mapped to the exam objective):
#    The leap in AI capability and adoption came from several factors that
#    reinforce each other:
#      1. Massively parallel accelerated compute (GPUs): thousands of cores
#         running the same math (matrix multiply) at once.
#      2. Reduced and mixed numeric precision (FP32 -> TF32/FP16/BF16/FP8 on
#         Tensor Cores): fewer bytes per number means more math per cycle and
#         per byte of memory bandwidth.
#      3. A mature software stack that keeps the hardware busy: CUDA libraries,
#         TensorRT kernel selection, Triton dynamic batching.
#      4. Infrastructure that exposes that compute to workloads without
#         starving it (Kubernetes + NVIDIA GPU Operator, resource policies).
#    The lab VM has no GPU, so we reproduce the same physics on CPU with NumPy:
#    a two-layer MLP "inference service" (GEMM + ReLU + GEMM) runs as a systemd
#    unit. Setup measures what THIS VM can deliver when configured correctly,
#    then sabotages the service in four realistic ways at once. You must find
#    and undo every one of them.
#
#  SAFETY:
#    - Run ONLY on a disposable lab VM, as root.
#    - Everything lives in /opt/aiio-lab, /etc/aiio-lab, /var/lib/aiio-lab,
#      /etc/systemd/system/aiio-infer.service(.d) and
#      /usr/local/bin/aiio-lab-check. No existing service or file is touched.
#    - It may install the distro package python3-numpy (and python3).
#    - Undo everything with:   sudo ./this-script.sh cleanup
#
#  Usage:
#    sudo ./aiio-1.4-break-fix.sh            # set up and break
#    sudo AIIO_LAB_YES=1 ./aiio-1.4-break-fix.sh   # without the prompt
#    sudo ./aiio-1.4-break-fix.sh cleanup    # remove the lab
#
#  References:
#    https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#    https://developer.nvidia.com/topics/ai/ai-inference
#    https://developer.nvidia.com/tensorrt
#    https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
#    https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
#    https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
# =============================================================================
set -euo pipefail

LAB_DIR=/opt/aiio-lab
CONF_DIR=/etc/aiio-lab
STATE_DIR=/var/lib/aiio-lab
UNIT=aiio-infer.service
UNIT_FILE=/etc/systemd/system/${UNIT}
DROPIN_DIR=/etc/systemd/system/${UNIT}.d
DROPIN_FILE=${DROPIN_DIR}/10-capacity-guard.conf
CHECK_BIN=/usr/local/bin/aiio-lab-check
SLO_RATIO=0.65   # SLO = 65% of the healthy baseline measured on this VM

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run as root (sudo). This lab writes systemd units."
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found: this lab needs systemd."
  [[ -d /run/systemd/system ]] || die "systemd is not PID 1 here (container?). Use a full lab VM."
}

cleanup() {
  require_root
  log "Removing the lab..."
  systemctl stop "${UNIT}" 2>/dev/null || true
  rm -f  "${DROPIN_FILE}"
  rmdir  "${DROPIN_DIR}" 2>/dev/null || true
  rm -f  "${UNIT_FILE}" "${CHECK_BIN}"
  rm -rf "${LAB_DIR}" "${CONF_DIR}" "${STATE_DIR}"
  systemctl daemon-reload
  systemctl reset-failed "${UNIT}" 2>/dev/null || true
  log "Done. python3-numpy (if it was installed) was left in place."
}

confirm() {
  [[ "${AIIO_LAB_YES:-0}" == "1" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "Non-interactive shell: re-run with AIIO_LAB_YES=1 once you are sure this is a disposable VM."
  fi
  echo "This will install a deliberately BROKEN service on this machine."
  read -r -p "Is this a disposable lab VM? Type 'yes' to continue: " ans
  [[ "${ans}" == "yes" ]] || die "Aborted."
}

ensure_deps() {
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import numpy' >/dev/null 2>&1; then
    log "Installing python3 + NumPy from the distro repositories..."
    if command -v dnf >/dev/null 2>&1; then
      dnf -y -q install python3 python3-numpy
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-numpy
    elif command -v zypper >/dev/null 2>&1; then
      zypper -n -q install python3 python3-numpy
    else
      die "No supported package manager. Install python3 and NumPy, then re-run."
    fi
  fi
  python3 -c 'import numpy' >/dev/null 2>&1 || die "NumPy still not importable; cannot continue."
}

write_bench() {
  install -d -m 0755 "${LAB_DIR}" "${CONF_DIR}" "${STATE_DIR}"

  cat > "${LAB_DIR}/bench.py" <<'PYEOF'
#!/usr/bin/env python3
"""Simulated batched-inference service: a 2-layer MLP (GEMM -> ReLU -> GEMM).

Each worker is one process with single-threaded BLAS, so parallelism comes
only from the number of workers and the CPUs the service is allowed to use.
DO NOT EDIT THIS FILE: the lab is about the platform, not the code.
"""
import os
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
           "BLIS_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_v] = "1"

import argparse
import multiprocessing as mp
import time

import numpy as np

DIM = 512
HIDDEN = 2048
ALLOWED_DTYPES = ("float16", "float32", "float64")


def load_conf(path):
    conf = {}
    with open(path) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if "=" not in line:
                continue
            key, val = line.split("=", 1)
            conf[key.strip().upper()] = val.strip()
    return conf


def cgroup_cpu_max():
    try:
        with open("/proc/self/cgroup") as fh:
            for line in fh:
                if line.startswith("0::"):
                    rel = line.strip().split("::", 1)[1]
                    with open("/sys/fs/cgroup" + rel + "/cpu.max") as g:
                        return g.read().strip()
    except OSError:
        pass
    return "n/a"


def worker(idx, dtype_name, batch, duration, barrier, queue):
    dt = np.dtype(dtype_name)
    rng = np.random.default_rng(1000 + idx)
    w1 = (rng.standard_normal((DIM, HIDDEN)) * 0.02).astype(dt)
    w2 = (rng.standard_normal((HIDDEN, DIM)) * 0.02).astype(dt)
    x = rng.standard_normal((batch, DIM)).astype(dt)
    barrier.wait()
    done = 0
    t0 = time.perf_counter()
    deadline = t0 + duration
    while time.perf_counter() < deadline:
        h = x @ w1
        np.maximum(h, 0, out=h)
        _ = h @ w2
        done += batch
    queue.put((done, time.perf_counter() - t0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--out")
    ap.add_argument("--duration", type=float, default=6.0)
    args = ap.parse_args()

    conf = load_conf(args.config)
    workers = int(conf.get("WORKERS", "1"))
    dtype = conf.get("DTYPE", "float32").lower()
    batch = int(conf.get("BATCH_SIZE", "1"))
    if not 1 <= workers <= 256:
        raise SystemExit("WORKERS must be between 1 and 256")
    if dtype not in ALLOWED_DTYPES:
        raise SystemExit("DTYPE must be one of " + ", ".join(ALLOWED_DTYPES))
    if not 1 <= batch <= 4096:
        raise SystemExit("BATCH_SIZE must be between 1 and 4096")

    ctx = mp.get_context("fork")
    barrier = ctx.Barrier(workers + 1)
    queue = ctx.Queue()
    procs = [ctx.Process(target=worker,
                         args=(i, dtype, batch, args.duration, barrier, queue))
             for i in range(workers)]
    for p in procs:
        p.start()
    barrier.wait()
    results = [queue.get(timeout=args.duration + 300) for _ in procs]
    for p in procs:
        p.join()

    samples = sum(r[0] for r in results)
    elapsed = max(r[1] for r in results)
    affinity = sorted(os.sched_getaffinity(0))
    report = [
        ("workers", workers),
        ("dtype", dtype),
        ("batch_size", batch),
        ("host_cpus", os.cpu_count()),
        ("visible_cpus", len(affinity)),
        ("cgroup_cpu_max", cgroup_cpu_max()),
        ("samples", samples),
        ("elapsed_s", "%.2f" % elapsed),
        ("throughput_sps", "%.1f" % (samples / elapsed)),
    ]
    text = "\n".join("%s=%s" % kv for kv in report) + "\n"
    print(text, end="")
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)


if __name__ == "__main__":
    main()
PYEOF

  cat > "${LAB_DIR}/check.py" <<'PYEOF'
#!/usr/bin/env python3
"""SLO validator for the aiio-infer service. Reads the last run and the unit."""
import subprocess
import sys

STATE = "/var/lib/aiio-lab"
CONF = "/etc/aiio-lab/infer.conf"
UNIT = "aiio-infer.service"


def kv(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip().upper()] = v.strip()
    return out


def cpulist(text):
    cpus = set()
    for part in text.replace(",", " ").split():
        if "-" in part:
            a, b = part.split("-", 1)
            cpus.update(range(int(a), int(b) + 1))
        elif part:
            cpus.add(int(part))
    return cpus


def unit_prop(name):
    return subprocess.run(["systemctl", "show", "-p", name, "--value", UNIT],
                          capture_output=True, text=True).stdout.strip()


base = kv(STATE + "/baseline")
conf = kv(CONF)
run = kv(STATE + "/last_run.txt")

need_workers = int(base["BASE_WORKERS"])
target = float(base["TARGET_SPS"])
tput = float(run["THROUGHPUT_SPS"])

open_issues = 0
try:
    if int(conf.get("WORKERS", "1")) < need_workers:
        open_issues += 1
except ValueError:
    open_issues += 1

dtype = conf.get("DTYPE", "").lower()
if dtype != "float32":
    open_issues += 1

try:
    if int(conf.get("BATCH_SIZE", "1")) < 32:
        open_issues += 1
except ValueError:
    open_issues += 1

limited = unit_prop("CPUQuotaPerSecUSec") not in ("", "infinity")
for prop in ("CPUAffinity", "AllowedCPUs"):
    val = unit_prop(prop)
    if val and len(cpulist(val)) < need_workers:
        limited = True
if limited:
    open_issues += 1

pct = 100.0 * tput / target if target else 0.0
print("Last run      : %.1f samples/s (workers=%s dtype=%s batch=%s visible_cpus=%s cpu.max=%s)"
      % (tput, run.get("WORKERS"), run.get("DTYPE"), run.get("BATCH_SIZE"),
         run.get("VISIBLE_CPUS"), run.get("CGROUP_CPU_MAX")))
print("SLO           : >= %.1f samples/s  (you are at %.0f%% of the SLO)" % (target, pct))
print("Root causes still present: %d" % open_issues)
if dtype == "float16":
    print("Note: FP16 only pays off when the hardware executes it natively "
          "(Tensor Cores on GPUs). On this CPU NumPy emulates it in software.")
if tput >= target and open_issues == 0:
    print("RESULT: PASS - the inference SLO is restored.")
    sys.exit(0)
print("RESULT: FAIL")
sys.exit(1)
PYEOF

  chmod 0755 "${LAB_DIR}/bench.py" "${LAB_DIR}/check.py"

  cat > "${CHECK_BIN}" <<EOF
#!/usr/bin/env bash
# Runs the inference service once and validates it against the SLO.
set -uo pipefail
[[ \${EUID} -eq 0 ]] || { echo "run as root (sudo aiio-lab-check)" >&2; exit 2; }
echo "Running ${UNIT} (takes ~10 s)..."
if ! systemctl start ${UNIT}; then
  echo "The service failed. Inspect: journalctl -u ${UNIT} -n 30 --no-pager" >&2
  exit 1
fi
exec python3 -I ${LAB_DIR}/check.py
EOF
  chmod 0755 "${CHECK_BIN}"
}

measure_baseline() {
  local ncpu base_workers tmp best t i
  ncpu=$(nproc)
  base_workers=$(( ncpu < 8 ? ncpu : 8 ))
  tmp=$(mktemp -d)
  cat > "${tmp}/good.conf" <<EOF
WORKERS=${base_workers}
DTYPE=float32
BATCH_SIZE=64
EOF
  log "Measuring the HEALTHY baseline on this VM (${base_workers} workers, FP32, batch 64)..."
  best=0
  for i in 1 2; do
    python3 -I "${LAB_DIR}/bench.py" --config "${tmp}/good.conf" \
      --out "${tmp}/out" --duration 5 >/dev/null
    t=$(awk -F= '/^throughput_sps=/{print $2}' "${tmp}/out")
    best=$(python3 -c "print(max(float('${best}'), float('${t}')))")
  done
  rm -rf "${tmp}"
  python3 - "${best}" "${base_workers}" "${SLO_RATIO}" > "${STATE_DIR}/baseline" <<'PYEOF'
import sys
best, workers, ratio = float(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
print("BASELINE_SPS=%.1f" % best)
print("BASE_WORKERS=%d" % workers)
print("TARGET_SPS=%.1f" % (best * ratio))
PYEOF
  chmod 0644 "${STATE_DIR}/baseline"
}

install_broken_service() {
  local py
  py=$(command -v python3)

  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=AIIO lab - batched inference service (simulated accelerator workload)
Documentation=https://developer.nvidia.com/topics/ai/ai-inference

[Service]
Type=oneshot
ExecStart=${py} -I ${LAB_DIR}/bench.py --config ${CONF_DIR}/infer.conf --out ${STATE_DIR}/last_run.txt
StandardOutput=journal
StandardError=journal
EOF

  # --- BREAK 1: a "temporary" capacity guard pinned the service to CPU 0
  #               and capped it at half a core.
  install -d -m 0755 "${DROPIN_DIR}"
  cat > "${DROPIN_FILE}" <<'EOF'
# INC-4471 (noisy neighbour on shared node) - temporary guard, remove after RCA.
# Owner: on-call rotation. RCA: never written.
[Service]
CPUAffinity=0
CPUQuota=50%
EOF

  # --- BREAK 2, 3, 4: workers, precision and batching "made safe".
  cat > "${CONF_DIR}/infer.conf" <<'EOF'
# aiio-infer runtime configuration
# Edited by on-call during INC-4471 "to reduce risk". Previous values not recorded.
WORKERS=1
DTYPE=float64
BATCH_SIZE=1
EOF
  chmod 0644 "${CONF_DIR}/infer.conf"

  systemctl daemon-reload
  log "Running the (now broken) service once so the journal has evidence..."
  systemctl start "${UNIT}" || warn "The broken run failed; check journalctl -u ${UNIT}."
}

briefing() {
  local base target broken
  base=$(awk -F= '/^BASELINE_SPS=/{print $2}' "${STATE_DIR}/baseline")
  target=$(awk -F= '/^TARGET_SPS=/{print $2}' "${STATE_DIR}/baseline")
  broken=$(awk -F= '/^throughput_sps=/{print $2}' "${STATE_DIR}/last_run.txt" 2>/dev/null || echo "?")
  cat <<EOF

=============================================================================
 TICKET AIIO-1.4  |  Priority: P2  |  Service: ${UNIT}
=============================================================================
 SYMPTOM
   The batch inference service now delivers ~${broken} samples/s.
   On this exact VM, correctly configured, it delivered ~${base} samples/s.
   The product SLO is >= ${target} samples/s. Customers see queueing and
   timeouts; finance asks why we "need more hardware".

 CONTEXT
   During incident INC-4471 the on-call engineer applied several "safe"
   changes to both the service runtime config and the systemd unit. Nobody
   reverted them. The hardware is fine; the platform is starving it.

 YOUR MISSION
   Restore the SLO by removing EVERY root cause. Think in terms of the
   factors that made modern AI fast and cheap enough to adopt:
     - how much parallel compute the workload is actually allowed to use,
     - how many bytes each number costs (numeric precision),
     - whether the hardware gets work in units big enough to stay busy.

 RULES
   - Do not edit ${LAB_DIR}/*.py or ${STATE_DIR}/baseline (honor system).
   - You MAY change ${CONF_DIR}/infer.conf and the systemd config of the unit.
   - Validate with:   sudo aiio-lab-check
     (PASS needs the SLO met AND zero root causes left.)

 USEFUL STARTING POINTS
   systemctl status ${UNIT}       journalctl -u ${UNIT} -n 30 --no-pager
   cat ${STATE_DIR}/last_run.txt   nproc     lscpu

 CLEANUP WHEN DONE
   sudo $0 cleanup
=============================================================================
EOF
}

main() {
  if [[ "${1:-}" == "cleanup" ]]; then
    cleanup
    exit 0
  fi
  [[ -z "${1:-}" ]] || die "Unknown argument '${1}'. Use no argument (setup) or 'cleanup'."

  require_root
  require_systemd
  local ncpu
  ncpu=$(nproc)
  (( ncpu >= 2 )) || die "This VM has ${ncpu} vCPU. The parallelism fault needs >= 2 vCPUs; resize the VM."
  confirm
  ensure_deps
  write_bench
  measure_baseline
  install_broken_service
  briefing
}

main "$@"

# =============================================================================
#  SOLUTION (do not read before trying)
# =============================================================================
#
# --- Step 1: gather evidence before touching anything ------------------------
#   cat /var/lib/aiio-lab/last_run.txt
#     workers=1
#     dtype=float64
#     batch_size=1
#     host_cpus=4
#     visible_cpus=1                <- the process sees ONE CPU of 4
#     cgroup_cpu_max=50000 100000   <- CFS quota: 50 ms of CPU per 100 ms
#     ...
#     throughput_sps=900.3          <- (example; numbers depend on the VM)
#
#   Every line of that telemetry is a clue. The service is told to use one
#   worker, compute in FP64, process one sample per call, and the kernel is
#   allowed to give it half of one core.
#
# --- Step 2: find where the unit is being limited ----------------------------
#   systemctl cat aiio-infer.service
#     # /etc/systemd/system/aiio-infer.service
#     ...
#     # /etc/systemd/system/aiio-infer.service.d/10-capacity-guard.conf
#     [Service]
#     CPUAffinity=0
#     CPUQuota=50%
#
#   systemctl show -p CPUQuotaPerSecUSec -p CPUAffinity aiio-infer.service
#     CPUQuotaPerSecUSec=500ms
#     CPUAffinity=0
#
#   Lesson: always use 'systemctl cat', never just the main unit file.
#   Drop-ins silently override it. The Kubernetes analogue is a LimitRange or
#   a CPU limit added to a Pod spec: the CFS quota throttles the container
#   (container_cpu_cfs_throttled_seconds_total grows) while the node looks idle.
#   With GPUs the equivalent mistake is a Pod that does not request
#   nvidia.com/gpu, or a node where the GPU Operator's device plugin is not
#   running, so the accelerator exists but the workload never gets it.
#
# --- Step 3: remove the capacity guard ---------------------------------------
#   rm /etc/systemd/system/aiio-infer.service.d/10-capacity-guard.conf
#   rmdir /etc/systemd/system/aiio-infer.service.d
#   systemctl daemon-reload
#   systemctl show -p CPUQuotaPerSecUSec -p CPUAffinity aiio-infer.service
#     CPUQuotaPerSecUSec=infinity
#     CPUAffinity=
#
#   (Prefer deleting the specific drop-in over 'systemctl revert': for a unit
#   with no vendor copy you want to be certain exactly what gets removed.)
#
# --- Step 4: restore the runtime configuration -------------------------------
#   Number of workers: use the parallelism you have (the baseline used
#   min(nproc, 8)). Precision: FP32. Batch: 64 (anything >= 32 is accepted).
#
#   W=$(nproc); [ "$W" -gt 8 ] && W=8
#   sed -i -e "s/^WORKERS=.*/WORKERS=${W}/" \
#          -e 's/^DTYPE=.*/DTYPE=float32/' \
#          -e 's/^BATCH_SIZE=.*/BATCH_SIZE=64/' /etc/aiio-lab/infer.conf
#   cat /etc/aiio-lab/infer.conf
#
# --- Step 5: validate ---------------------------------------------------------
#   sudo aiio-lab-check
#     Running aiio-infer.service (takes ~10 s)...
#     Last run      : 41210.7 samples/s (workers=4 dtype=float32 batch=64 visible_cpus=4 cpu.max=max 100000)
#     SLO           : >= 26100.0 samples/s  (you are at 158% of the SLO)
#     Root causes still present: 0
#     RESULT: PASS - the inference SLO is restored.
#
#   Fixing faults one at a time and re-running aiio-lab-check is the best way
#   to learn: note how much EACH factor contributes on your VM.
#
# --- Why each fix matters (the exam objective behind it) ---------------------
#   1) Parallel compute. Neural-network inference is dominated by matrix
#      multiplies, which are embarrassingly parallel. A CPU gives you a few
#      cores; a GPU gives you thousands, plus Tensor Cores that execute whole
#      matrix tiles per instruction. That gap is the main hardware factor in
#      the AI boom. Here, WORKERS=1 plus CPUAffinity=0 plus a 50% quota
#      reduced the parallel capacity to half a core.
#
#   2) Numeric precision. FP64 doubles the bytes per value versus FP32: half
#      the SIMD lanes per instruction and twice the memory traffic. Deep
#      learning tolerates lower precision, which is why GPUs added TF32, FP16,
#      BF16 and FP8 and why TensorRT can calibrate a model to INT8/FP8 with
#      minimal accuracy loss. Trap: DTYPE=float16 is SLOWER here because this
#      CPU has no native FP16 matrix units and NumPy emulates it. Lower
#      precision is a factor only when hardware AND software support it
#      together (hardware/software co-design).
#
#   3) Batching. With BATCH_SIZE=1 every call is a matrix-vector product:
#      little math per byte of weights read (low arithmetic intensity) and the
#      Python/BLAS call overhead dominates. With batch 64 the same weights are
#      reused 64 times per load and the cores stay busy. On GPUs this is what
#      Triton dynamic batching and TensorRT kernel/batch optimization deliver,
#      and why the same GPU serves far more users once the software stack is
#      tuned.
#
#   4) Infrastructure. The hardware was never the problem: an undocumented
#      platform policy was. Mature orchestration (Kubernetes, GPU Operator,
#      monitoring) is itself an adoption factor: it makes accelerated compute
#      schedulable, observable and shareable. A config left behind by an
#      incident is a reminder to make that platform observable and reviewed.
#
#   Data is the remaining factor in the objective (huge datasets plus storage
#   fast enough to feed accelerators). This lab does not break it, but the same
#   reasoning applies: if storage or the data loader cannot keep up, expensive
#   accelerators sit idle exactly like the half-core service above.
#
# --- Cleanup ------------------------------------------------------------------
#   sudo ./aiio-1.4-break-fix.sh cleanup
# =============================================================================