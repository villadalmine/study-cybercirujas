#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 1.1: Describe the NVIDIA software stack used in an AI environment
# BREAK & FIX LAB: "The GPU node that upgraded itself halfway"
# =============================================================================
#
# WHAT THIS LAB TEACHES
#   An NVIDIA AI node is a stack of independently versioned layers. Each layer
#   has a compatibility contract with the layer below it. Most "the GPU is
#   broken" tickets are not hardware failures. They are a broken contract
#   between two of these layers:
#
#   L5  Workloads & frameworks : PyTorch / TensorFlow / JAX, NeMo, Triton
#                                Inference Server, NGC containers, NVIDIA AI
#                                Enterprise.
#   L4  CUDA-X libraries       : cuDNN, cuBLAS, NCCL, TensorRT. Each is BUILT
#                                FOR a CUDA major version (cuda11 / cuda12 /
#                                cuda13 variants).
#   L3  CUDA Toolkit / runtime : nvcc, libcudart.so.<major>. Installed
#                                side-by-side in /usr/local/cuda-X.Y.
#                                /usr/local/cuda is just a symlink.
#   L2  User-mode driver       : libcuda.so.1 (CUDA Driver API) and
#                                libnvidia-ml.so.1 (NVML, used by nvidia-smi
#                                and DCGM). Ships WITH the driver and must
#                                match the kernel module EXACTLY.
#   L1  Kernel-mode driver     : nvidia.ko, nvidia-uvm.ko, nvidia-peermem.ko.
#                                The loaded version is visible in
#                                /proc/driver/nvidia/version.
#   L0  Hardware               : GPU (e.g. A100/H100), NVLink/NVSwitch,
#                                ConnectX NIC / BlueField DPU.
#
#   In containers the split is the same: the image brings L3-L5, and the host
#   provides L1-L2. The NVIDIA Container Toolkit injects the host's
#   libcuda/libnvidia-ml into the container. That is why every NGC image
#   publishes a "requires driver >= X" note. In Kubernetes, the GPU Operator
#   manages L1-L2 (driver container), the Container Toolkit, the device
#   plugin and DCGM-exporter.
#
# COMPATIBILITY RULES EXERCISED HERE (verify them in the official docs)
#   * Kernel module version == libcuda/libnvidia-ml version. A mismatch gives
#     "Failed to initialize NVML: Driver/library version mismatch" and
#     CUDA error 803.
#   * Backward compatibility: a driver runs any OLDER CUDA runtime.
#   * Minor version compatibility: within one major (12.x), a newer runtime
#     runs on an older 12.x driver (>= 525.60.13). PTX JIT of newer PTX and
#     new features are not covered.
#   * Across majors (13.x runtime on a 12.x driver) you get
#     cudaErrorInsufficientDriver (35), unless you install the
#     forward-compatibility package (cuda-compat) on supported data center
#     GPUs.
#   * CUDA-X libraries must match the runtime's CUDA major.
#
# OFFICIAL SOURCES
#   - NCA-AIIO exam guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   - CUDA Compatibility:
#     https://docs.nvidia.com/deploy/cuda-compatibility/
#   - CUDA Toolkit release notes (minimum driver per toolkit):
#     https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/
#   - CUDA Runtime API error codes:
#     https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__TYPES.html
#   - cuDNN support matrix:
#     https://docs.nvidia.com/deeplearning/cudnn/latest/reference/support-matrix.html
#   - NVIDIA Container Toolkit:
#     https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html
#   - NVIDIA GPU Operator:
#     https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
#   - NGC framework support matrix:
#     https://docs.nvidia.com/deeplearning/frameworks/support-matrix/index.html
#
# SAFETY
#   Everything happens inside a sandbox directory (default: ~/nvlab). The
#   script needs no root, needs no GPU, and does not touch any real driver,
#   package, ldconfig cache or /usr/local/cuda.
#   - The "libraries" are text stand-ins for ELF files.
#   - nvidia-smi, nvcc and the workload are mocks that apply the real
#     compatibility rules and print the real error messages.
#   - NVLAB_LD_LIBRARY_PATH plays the role of LD_LIBRARY_PATH / the ldconfig
#     cache, so the real dynamic loader is never involved.
#
# USAGE
#   bash nvlab-1.1.sh            # build the broken lab (same as: setup)
#   bash nvlab-1.1.sh check      # grade your fix
#   bash nvlab-1.1.sh reset      # delete the lab
#   NVLAB_ROOT=/path/to/dir bash nvlab-1.1.sh   # use a different sandbox
# =============================================================================
set -euo pipefail

LAB="${NVLAB_ROOT:-$HOME/nvlab}"
LAB="${LAB%/}"
MODE="${1:-setup}"
MARKER=".nvlab/marker"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

safe_lab_path() {
  [[ "$LAB" == /* ]] || die "NVLAB_ROOT must be an absolute path (got: $LAB)"
  case "$LAB" in
    ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/usr/local|/var|"$HOME")
      die "refusing to use $LAB as the lab root" ;;
  esac
}

case "$MODE" in
  setup|--setup) ;;
  check|--check)
    [[ -x "$LAB/bin/nvlab-check" ]] || die "no lab found at $LAB (run: bash $0 setup)"
    exec "$LAB/bin/nvlab-check" ;;
  reset|--reset)
    safe_lab_path
    [[ -f "$LAB/$MARKER" ]] || die "$LAB is not an nvlab directory; refusing to delete it"
    rm -rf -- "$LAB"
    echo "Removed $LAB"
    exit 0 ;;
  *)
    echo "usage: $0 [setup|check|reset]" >&2
    exit 2 ;;
esac

# ----------------------------------------------------------------------------- preflight
[[ ${EUID:-$(id -u)} -ne 0 ]] || die "run this as a regular user: the lab lives in your home directory and needs no privileges"
safe_lab_path
command -v sha256sum >/dev/null 2>&1 || die "sha256sum (coreutils) is required"
command -v readlink  >/dev/null 2>&1 || die "readlink (coreutils) is required"

if [[ -e "$LAB" ]]; then
  [[ -f "$LAB/$MARKER" ]] || die "$LAB exists and is not an nvlab directory; choose another NVLAB_ROOT"
  rm -rf -- "$LAB"
fi
mkdir -p "$LAB/.nvlab" "$LAB/bin"
echo "nvlab nca-aiio 1.1 created $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LAB/$MARKER"

if [[ -r /proc/driver/nvidia/version ]]; then
  echo "NOTE: a real NVIDIA driver is loaded on this machine. This lab does not touch it."
  echo "      The lab's mock nvidia-smi only shadows the real one in shells where you source $LAB/env.sh."
  echo
fi

# fakelib <relative path> KEY=VALUE...  -> text stand-in for a shared object
fakelib() {
  local f="$LAB/$1"
  shift
  mkdir -p "$(dirname "$f")"
  {
    echo "# nvlab: text stand-in for an ELF shared object. Version metadata below - do not edit."
    printf '%s\n' "$@"
  } > "$f"
}

# ----------------------------------------------------------------------------- L1: kernel module
# The loaded module. In real life you would see it with:
#   cat /proc/driver/nvidia/version
#   modinfo nvidia | grep ^version
mkdir -p "$LAB/proc/driver/nvidia"
cat > "$LAB/proc/driver/nvidia/version" <<'EOF'
NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.15  Tue Mar  5 22:23:56 UTC 2024
GCC version:  gcc version 12.3.0
EOF
# Only the 550 module exists: the DKMS build of the 560 module "failed" during the upgrade.
fakelib driver/kmod/550.54.15/nvidia.ko "COMPONENT=kernel-module" "VERSION=550.54.15"

# ----------------------------------------------------------------------------- L2: user-mode driver
# 550.54.15 is the CUDA 12.4 driver branch.
# 560.35.03 is the CUDA 12.6 branch: userspace leftovers from the partial upgrade.
for pair in 550.54.15:12.4 560.35.03:12.6; do
  dv="${pair%%:*}"
  cmax="${pair##*:}"
  fakelib "driver/lib/libcuda.so.$dv"      "COMPONENT=libcuda"      "VERSION=$dv" "DRIVER_CUDA_MAX=$cmax"
  fakelib "driver/lib/libnvidia-ml.so.$dv" "COMPONENT=libnvidia-ml" "VERSION=$dv"
done

# ----------------------------------------------------------------------------- L3: CUDA toolkits
# Toolkits are installed side by side, exactly like /usr/local/cuda-X.Y.
cat > "$LAB/.nvlab/nvcc.template" <<'NVCC'
#!/usr/bin/env bash
# nvlab mock of nvcc: reports the release of the toolkit it lives in.
TK="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
f="$(ls "$TK"/lib64/libcudart.so.*.*.* 2>/dev/null | head -n1)"
full="$(sed -n 's/^CUDA_RUNTIME_FULL=//p' "$f" 2>/dev/null)"
mm="${full%.*}"
case "${1:-}" in
  --version|-V)
    cat <<EOF
nvcc: NVIDIA (R) Cuda compiler driver
Copyright (c) NVIDIA Corporation
Cuda compilation tools, release $mm, V$full
Build cuda_$mm (nvlab simulated)
EOF
    ;;
  *)
    echo "nvcc (nvlab mock): only --version is implemented" >&2
    exit 1
    ;;
esac
NVCC

for full in 12.4.131 12.8.93 13.0.48; do
  mm="${full%.*}"
  maj="${full%%.*}"
  tk="usr/local/cuda-$mm"
  fakelib "$tk/lib64/libcudart.so.$full" "COMPONENT=libcudart" "CUDA_RUNTIME=$mm" "CUDA_RUNTIME_FULL=$full"
  ln -s "libcudart.so.$full" "$LAB/$tk/lib64/libcudart.so.$maj"
  mkdir -p "$LAB/$tk/bin"
  cp "$LAB/.nvlab/nvcc.template" "$LAB/$tk/bin/nvcc"
  chmod 0755 "$LAB/$tk/bin/nvcc"
done

# ----------------------------------------------------------------------------- L4: CUDA-X libraries
fakelib opt/cudnn/9.5.1-cuda12/lib/libcudnn.so.9.5.1 "COMPONENT=libcudnn" "VERSION=9.5.1" "BUILT_FOR_CUDA_MAJOR=12"
ln -s libcudnn.so.9.5.1 "$LAB/opt/cudnn/9.5.1-cuda12/lib/libcudnn.so.9"
fakelib opt/cudnn/8.9.7-cuda11/lib/libcudnn.so.8.9.7 "COMPONENT=libcudnn" "VERSION=8.9.7" "BUILT_FOR_CUDA_MAJOR=11"
ln -s libcudnn.so.8.9.7 "$LAB/opt/cudnn/8.9.7-cuda11/lib/libcudnn.so.8"
fakelib opt/nccl/2.21.5-cuda12/lib/libnccl.so.2.21.5 "COMPONENT=libnccl" "VERSION=2.21.5" "BUILT_FOR_CUDA_MAJOR=12"
ln -s libnccl.so.2.21.5 "$LAB/opt/nccl/2.21.5-cuda12/lib/libnccl.so.2"

# ----------------------------------------------------------------------------- mock: nvidia-smi
cat > "$LAB/bin/nvidia-smi" <<'SMI'
#!/usr/bin/env bash
# nvlab mock of nvidia-smi. Like the real one, it talks to the kernel module
# through NVML (libnvidia-ml.so.1). It finds NVML through the system library
# cache (here: driver/lib), not through LD_LIBRARY_PATH.
set -uo pipefail
LAB="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LIBDIR="$LAB/driver/lib"
meta() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }

kmod="$(sed -n 's/.*Kernel Module  *\([0-9][0-9.]*\).*/\1/p' "$LAB/proc/driver/nvidia/version" 2>/dev/null)"
if [[ -z "$kmod" ]]; then
  echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver. Make sure that the latest NVIDIA driver is installed and running."
  exit 9
fi
if [[ ! -e "$LIBDIR/libnvidia-ml.so.1" ]]; then
  echo "NVIDIA-SMI couldn't find libnvidia-ml.so library in your system. Please make sure that the NVIDIA Display Driver is properly installed and present in your system."
  echo "Please also try adding directory that contains libnvidia-ml.so to your system PATH."
  exit 12
fi
nvml="$(meta "$(readlink -f "$LIBDIR/libnvidia-ml.so.1")" VERSION)"
if [[ "$nvml" != "$kmod" ]]; then
  echo "Failed to initialize NVML: Driver/library version mismatch"
  echo "NVML library version: ${nvml%.*}"
  exit 18
fi

cudamax="N/A"
if [[ -e "$LIBDIR/libcuda.so.1" ]]; then
  cudamax="$(meta "$(readlink -f "$LIBDIR/libcuda.so.1")" DRIVER_CUDA_MAX)"
fi

if [[ "$*" == *--query-gpu* ]]; then
  case "$*" in
    *driver_version*) echo "$kmod" ;;
    *name*)           echo "NVIDIA A100-SXM4-80GB" ;;
    *)                echo "nvlab mock: supported fields are driver_version,name" >&2; exit 2 ;;
  esac
  exit 0
fi

date
echo "+-----------------------------------------------------------------------------------------+"
printf '| NVIDIA-SMI %-22s Driver Version: %-14s CUDA Version: %-9s|\n' "$kmod" "$kmod" "$cudamax"
echo "|-----------------------------------------+------------------------+----------------------+"
echo "| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |"
echo "| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |"
echo "|=========================================+========================+======================|"
echo "|   0  NVIDIA A100-SXM4-80GB          On  |   00000000:07:00.0 Off |                    0 |"
echo "| N/A   34C    P0             62W /  400W |       1MiB /  81920MiB |      0%      Default |"
echo "+-----------------------------------------+------------------------+----------------------+"
echo "(nvlab simulated output)"
SMI
chmod 0755 "$LAB/bin/nvidia-smi"

# ----------------------------------------------------------------------------- mock: workload
cat > "$LAB/bin/train-smoke" <<'SMOKE'
#!/usr/bin/env bash
# Pre-flight check of the kind many teams run before a training job:
#   1. JIT-compile a tiny kernel with $CUDA_HOME/bin/nvcc (links libcudart.so.<major>).
#   2. Initialize the CUDA driver.
#   3. Load cuDNN 9 and NCCL 2.
set -uo pipefail
LAB="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
meta() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }
find_lib() {
  local IFS=: d
  for d in ${NVLAB_LD_LIBRARY_PATH:-}; do
    if [[ -n "$d" && -e "$d/$1" ]]; then
      readlink -f "$d/$1"
      return 0
    fi
  done
  return 1
}
step() { printf '[train-smoke] %s\n' "$*"; }
fail() { printf '%s\n' "$@" >&2; printf '[train-smoke] FAILED\n' >&2; exit 1; }

[[ -n "${CUDA_HOME:-}" ]] || fail "CUDA_HOME is not set (did you 'source $LAB/env.sh'?)"
[[ -n "${NVLAB_LD_LIBRARY_PATH:-}" ]] || fail "NVLAB_LD_LIBRARY_PATH is not set (did you 'source $LAB/env.sh'?)"

step "nvcc -arch=sm_80 -o /tmp/preflight preflight.cu   (CUDA_HOME=$CUDA_HOME)"
[[ -x "$CUDA_HOME/bin/nvcc" ]] || fail "bash: $CUDA_HOME/bin/nvcc: No such file or directory"
rel="$("$CUDA_HOME/bin/nvcc" --version | sed -n 's/.*release \([0-9][0-9.]*\),.*/\1/p')"
rtmaj="${rel%%.*}"

step "loading libcudart.so.$rtmaj (CUDA runtime $rel, linked by nvcc)"
cudart="$(find_lib "libcudart.so.$rtmaj")" \
  || fail "/tmp/preflight: error while loading shared libraries: libcudart.so.$rtmaj: cannot open shared object file: No such file or directory"
rt="$(meta "$cudart" CUDA_RUNTIME)"

step "loading libcuda.so.1 (CUDA driver API - ships with the driver, not the toolkit)"
libcuda="$(find_lib libcuda.so.1)" \
  || fail "cudaGetDeviceCount() failed: cudaErrorInsufficientDriver (35): CUDA driver version is insufficient for CUDA runtime version"
drv="$(meta "$libcuda" VERSION)"
dmax="$(meta "$libcuda" DRIVER_CUDA_MAX)"
kmod="$(sed -n 's/.*Kernel Module  *\([0-9][0-9.]*\).*/\1/p' "$LAB/proc/driver/nvidia/version" 2>/dev/null)"

step "cuInit(0)"
[[ "$drv" == "$kmod" ]] \
  || fail "cudaGetDeviceCount() failed: cudaErrorSystemDriverMismatch (803): system has unsupported display driver / cuda driver combination"

IFS=. read -r dmaj dmin <<<"$dmax"
IFS=. read -r rmaj rmin <<<"$rt"
dmaj="${dmaj:-0}"; dmin="${dmin:-0}"; rmaj="${rmaj:-0}"; rmin="${rmin:-0}"
if (( rmaj > dmaj )); then
  fail "cudaGetDeviceCount() failed: cudaErrorInsufficientDriver (35): CUDA driver version is insufficient for CUDA runtime version"
elif (( rmaj == dmaj && rmin > dmin )); then
  step "WARNING: runtime $rt is newer than the driver's CUDA $dmax inside CUDA $rmaj.x (minor version compatibility)."
  step "         SASS for sm_80 runs. JIT of newer PTX would fail with cudaErrorUnsupportedPtxVersion (222)."
fi

step "loading libcudnn.so.9"
cudnn="$(find_lib libcudnn.so.9)" \
  || fail "Could not load library libcudnn.so.9. Error: libcudnn.so.9: cannot open shared object file: No such file or directory"
cm="$(meta "$cudnn" BUILT_FOR_CUDA_MAJOR)"
[[ "$cm" == "$rtmaj" ]] \
  || fail "Could not load library $(basename "$cudnn"). Error: libcublasLt.so.$cm: cannot open shared object file: No such file or directory"

step "loading libnccl.so.2"
nccl="$(find_lib libnccl.so.2)" \
  || fail "libnccl.so.2: cannot open shared object file: No such file or directory"
nm="$(meta "$nccl" BUILT_FOR_CUDA_MAJOR)"
[[ "$nm" == "$rtmaj" ]] \
  || fail "NCCL WARN Cuda failure 'CUDA driver version is insufficient for CUDA runtime version' (NCCL built for CUDA $nm, runtime is $rt)"

step "GPU 0: NVIDIA A100-SXM4-80GB (sm_80) | driver $drv (CUDA $dmax) | runtime $rt | cuDNN $(meta "$cudnn" VERSION) | NCCL $(meta "$nccl" VERSION)"
step "single-GPU all-reduce: OK"
step "PASSED"
SMOKE
chmod 0755 "$LAB/bin/train-smoke"

# ----------------------------------------------------------------------------- grader
cat > "$LAB/bin/nvlab-check" <<'CHECK'
#!/usr/bin/env bash
# Grades the PERSISTED configuration (env.sh + symlinks), not whatever your
# current shell happens to export.
set -uo pipefail
LAB="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck disable=SC1091
source "$LAB/env.sh"

pass=0
fail=0
ok() { printf '  [PASS] %s\n' "$*"; pass=$((pass + 1)); }
ko() { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }

echo "nvlab-check - NVIDIA software stack, layer by layer"

echo "Lab integrity"
if (cd "$LAB" && sha256sum -c --quiet --ignore-missing .nvlab/metadata.sha256 >/dev/null 2>&1); then
  ok "version metadata untouched"
else
  ko "a library/version file was edited. Fix links and configuration, not version strings (re-run setup to restore)"
fi
dangling="$(find "$LAB" -xtype l 2>/dev/null | sed "s|$LAB/||" | tr '\n' ' ')"
if [[ -z "$dangling" ]]; then
  ok "no dangling symlinks"
else
  ko "dangling symlinks: $dangling"
fi

echo "L1/L2  kernel module <-> user-mode driver (NVML + libcuda)"
if out="$("$LAB/bin/nvidia-smi" 2>&1)"; then
  ok "nvidia-smi: $(grep -o 'Driver Version: [0-9.]*' <<<"$out")"
else
  ko "nvidia-smi: $(head -n1 <<<"$out")"
fi
kmod="$(sed -n 's/.*Kernel Module  *\([0-9][0-9.]*\).*/\1/p' "$LAB/proc/driver/nvidia/version")"
lc="$(readlink -f "$LAB/driver/lib/libcuda.so.1" 2>/dev/null)"
lcv="$(sed -n 's/^VERSION=//p' "$lc" 2>/dev/null)"
if [[ "$lcv" == "$kmod" ]]; then
  ok "libcuda.so.1 = $lcv = kernel module"
else
  ko "libcuda.so.1 is '${lcv:-missing}' but the kernel module is $kmod"
fi

echo "L3     driver <-> CUDA toolkit selected by CUDA_HOME"
dmax="$(sed -n 's/^DRIVER_CUDA_MAX=//p' "$lc" 2>/dev/null)"
rel="$("$CUDA_HOME/bin/nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9.]*\),.*/\1/p')"
if [[ -z "$rel" || -z "$dmax" ]]; then
  ko "cannot determine driver CUDA version (${dmax:-?}) or toolkit release (${rel:-?})"
else
  IFS=. read -r dmaj dmin <<<"$dmax"
  IFS=. read -r rmaj rmin <<<"$rel"
  if (( rmaj > dmaj )); then
    ko "toolkit $rel needs a CUDA $rmaj.x driver; the driver supports CUDA $dmax"
  elif (( rmaj == dmaj && rmin > dmin )); then
    ok "toolkit $rel on driver CUDA $dmax (works via minor version compatibility; $dmax would be the cleanest match)"
  else
    ok "toolkit $rel on driver CUDA $dmax"
  fi
fi

echo "L4/L5  CUDA-X libraries + workload"
if out="$("$LAB/bin/train-smoke" 2>&1)"; then
  ok "train-smoke passed"
else
  ko "train-smoke: $(grep -v '^\[train-smoke\] FAILED' <<<"$out" | tail -n1)"
fi

echo
echo "Result: $pass passed, $fail failed"
if (( fail == 0 )); then
  echo "STACK HEALTHY - lab complete."
  exit 0
fi
exit 1
CHECK
chmod 0755 "$LAB/bin/nvlab-check"

# ----------------------------------------------------------------------------- THE BREAK
# Break 1 (L1/L2): userspace driver upgraded to 560 but the kernel module is still 550.
ln -s libcuda.so.560.35.03      "$LAB/driver/lib/libcuda.so.1"
ln -s libcuda.so.1              "$LAB/driver/lib/libcuda.so"
ln -s libnvidia-ml.so.560.35.03 "$LAB/driver/lib/libnvidia-ml.so.1"
# Break 2 (L3): /usr/local/cuda switched to CUDA 13.0 on a CUDA 12.4 driver.
ln -s cuda-13.0 "$LAB/usr/local/cuda"
# Break 3 (L4): library path points to a cuDNN build for CUDA 11.
{
  printf '# nvlab environment: plays the role of /etc/profile.d/cuda.sh + /etc/ld.so.conf.d/*.conf\n'
  printf 'export NVLAB_ROOT=%q\n' "$LAB"
  cat <<'ENV'
export CUDA_HOME="$NVLAB_ROOT/usr/local/cuda"
export PATH="$NVLAB_ROOT/bin:$CUDA_HOME/bin:$PATH"
# NVLAB_LD_LIBRARY_PATH stands in for LD_LIBRARY_PATH / the ldconfig cache (only the lab mocks read it)
export NVLAB_LD_LIBRARY_PATH="$NVLAB_ROOT/driver/lib:$CUDA_HOME/lib64:$NVLAB_ROOT/opt/cudnn/8.9.7-cuda11/lib:$NVLAB_ROOT/opt/nccl/2.21.5-cuda12/lib"
ENV
} > "$LAB/env.sh"

# Fingerprint every file except env.sh and .nvlab/, so the grader can detect edited version strings.
( cd "$LAB" && find . -type f ! -path './.nvlab/*' ! -path './env.sh' -print0 | sort -z | xargs -0 sha256sum ) > "$LAB/.nvlab/metadata.sha256"
rm -f "$LAB/.nvlab/nvcc.template"

# ----------------------------------------------------------------------------- BRIEFING
cat <<EOF
=============================================================================
 NCA-AIIO 1.1 - BREAK & FIX: "The GPU node that upgraded itself halfway"
 Lab root: $LAB
=============================================================================
SCENARIO
  Node dgx-lab-07 (1x A100-SXM4-80GB) ran three unsupervised changes overnight:
    * Unattended upgrades pulled the 560.35.03 driver userspace packages.
      The DKMS build of the new kernel module failed, and nobody rebooted.
    * An engineer pointed /usr/local/cuda at CUDA 13.0 "to try the new toolkit".
    * Someone "fixed" an import error by putting an old cuDNN tarball on the
      library path.
  This morning the training pre-flight check fails.

SYMPTOMS YOU WILL SEE (one layer at a time, from the bottom up)
  nvidia-smi   -> Failed to initialize NVML: Driver/library version mismatch
  train-smoke  -> cudaErrorSystemDriverMismatch (803), then
                  cudaErrorInsufficientDriver (35), then
                  Could not load library libcudnn.so.9

YOUR GOAL
  1. nvidia-smi reports Driver Version 550.54.15 / CUDA Version 12.4.
  2. The CUDA toolkit behind CUDA_HOME is compatible with that driver.
  3. train-smoke prints PASSED.
  4. 'bash $0 check' reports 0 failed, with no dangling symlinks.

RULES
  Fix layers, links and configuration (symlinks under driver/lib and
  usr/local, and env.sh). Do NOT edit the version metadata inside the fake
  libraries or proc/: the grader fingerprints those files. Only the 550
  kernel module exists, and you cannot "reboot into" 560.

START
  source $LAB/env.sh
  nvidia-smi
  train-smoke
  Useful: cat \$NVLAB_ROOT/proc/driver/nvidia/version ; ls -l \$NVLAB_ROOT/driver/lib
          nvcc --version ; ls -l \$NVLAB_ROOT/usr/local ; echo \$NVLAB_LD_LIBRARY_PATH | tr : '\n'

GRADE / RESET
  bash $0 check
  bash $0 reset     (then 'bash $0' to start over)
=============================================================================
EOF

# =============================================================================
# SOLUTION (step by step) - read it only after trying
# =============================================================================
#
# 0) Load the environment and read the symptoms bottom-up (L1 -> L5).
#      source ~/nvlab/env.sh
#      nvidia-smi
#        Failed to initialize NVML: Driver/library version mismatch
#        NVML library version: 560.35
#
# 1) L1/L2: kernel module vs user-mode driver.
#    Compare the loaded kernel module with the userspace libraries:
#      cat $NVLAB_ROOT/proc/driver/nvidia/version
#        NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.15 ...
#      ls -l $NVLAB_ROOT/driver/lib
#        libcuda.so.1 -> libcuda.so.560.35.03
#        libnvidia-ml.so.1 -> libnvidia-ml.so.560.35.03
#    Kernel 550 vs userspace 560 means NVML refuses to initialize and
#    cuInit returns 803. Only the 550 module exists, so roll the userspace
#    back to 550. Fix BOTH libraries: fixing only NVML makes nvidia-smi look
#    healthy while CUDA still fails with 803.
#      cd $NVLAB_ROOT/driver/lib
#      ln -sfn libcuda.so.550.54.15      libcuda.so.1
#      ln -sfn libnvidia-ml.so.550.54.15 libnvidia-ml.so.1
#      rm -f libcuda.so.560.35.03 libnvidia-ml.so.560.35.03   # optional cleanup of the leftovers
#      nvidia-smi
#        | NVIDIA-SMI 550.54.15   Driver Version: 550.54.15   CUDA Version: 12.4 |
#    Note: the "CUDA Version" in nvidia-smi is the HIGHEST CUDA version this
#    driver supports. It is NOT the installed toolkit.
#
#    Real-world equivalents:
#      - Diagnose:
#          dmesg | grep NVRM
#            NVRM: API mismatch: the client has the version 560.35.03, but
#            NVRM: this kernel module has the version 550.54.15.
#          modinfo nvidia | grep ^version
#          ldconfig -p | grep -E 'libcuda|libnvidia-ml'
#      - If the new module did build: reboot, or with no GPU processes
#        running:
#          rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia && modprobe nvidia
#      - If it did not build: fix DKMS (kernel headers) or downgrade the
#        userspace packages to the loaded branch.
#      - Prevent recurrence: apt-mark hold / dnf versionlock on the driver
#        packages, or let the GPU Operator's driver container manage the
#        driver on Kubernetes nodes.
#
# 2) L3: driver vs CUDA toolkit.
#      train-smoke
#        cudaGetDeviceCount() failed: cudaErrorInsufficientDriver (35):
#        CUDA driver version is insufficient for CUDA runtime version
#      nvcc --version | grep release
#        ... release 13.0, V13.0.48
#    A 13.x runtime cannot run on a driver whose maximum is CUDA 12.4.
#    Minor version compatibility only works inside the same major.
#    Point the default toolkit at a 12.x release:
#      ln -sfn cuda-12.4 $NVLAB_ROOT/usr/local/cuda    # exact match: cleanest choice
#      # cuda-12.8 also passes (minor version compatibility), with a warning
#      # about PTX JIT and new features
#      nvcc --version | grep release
#        ... release 12.4, V12.4.131
#    Real-world equivalents:
#      - On Debian/Ubuntu packages: update-alternatives --display cuda
#      - To really run CUDA 13 on this driver: upgrade the driver to the
#        branch the release notes require, or use forward compatibility
#        (cuda-compat-13-0 package, data center GPUs only).
#      - In containers: pick an NGC/CUDA image whose "requires driver >= X"
#        is satisfied by the host, e.g.:
#          docker run --rm --gpus all nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
#
# 3) L4: CUDA-X library vs runtime.
#      train-smoke
#        Could not load library libcudnn.so.9. Error: libcudnn.so.9: cannot
#        open shared object file: No such file or directory
#      echo $NVLAB_LD_LIBRARY_PATH | tr : '\n'
#        ... /opt/cudnn/8.9.7-cuda11/lib   <- cuDNN 8, built for CUDA 11
#    The workload needs cuDNN 9 built for the runtime's CUDA major (12).
#    Fix the PERSISTED config (the grader re-reads env.sh), then re-source it:
#      sed -i 's|opt/cudnn/8.9.7-cuda11/lib|opt/cudnn/9.5.1-cuda12/lib|' $NVLAB_ROOT/env.sh
#      source $NVLAB_ROOT/env.sh
#    Real-world equivalents:
#      - Library search order is LD_LIBRARY_PATH, then the ldconfig cache
#        (/etc/ld.so.conf.d/*.conf + ldconfig).
#      - Inspect what a binary resolves with:
#          ldd ./app | grep -E 'cudnn|cublas|cudart'
#      - Install the matching variant (cudnn9-cuda-12 vs cudnn9-cuda-13),
#        or use an NGC framework container, which ships a validated
#        L3-L5 combination.
#
# 4) Verify end to end.
#      train-smoke
#        [train-smoke] GPU 0: NVIDIA A100-SXM4-80GB (sm_80) | driver 550.54.15 (CUDA 12.4) | runtime 12.4 | cuDNN 9.5.1 | NCCL 2.21.5
#        [train-smoke] PASSED
#      bash nvlab-1.1.sh check
#        Result: 7 passed, 0 failed
#        STACK HEALTHY - lab complete.
#
# EXAM TAKEAWAYS (NCA-AIIO 1.1)
#   - Driver = kernel module + user-mode libraries (libcuda, NVML). They are
#     versioned together and must match exactly.
#   - The CUDA Toolkit is separate from the driver, and several versions can
#     coexist. nvidia-smi's "CUDA Version" is the driver's maximum supported
#     CUDA version, not the installed toolkit.
#   - CUDA-X libraries (cuDNN, cuBLAS, NCCL, TensorRT) sit on top of the
#     runtime and are built per CUDA major. Frameworks and NGC containers
#     sit on top of those.
#   - Containers carry L3-L5. The host carries L1-L2 and exposes them through
#     the NVIDIA Container Toolkit. The GPU Operator automates all of this on
#     Kubernetes.
#   - Always debug bottom-up:
#       /proc/driver/nvidia/version -> nvidia-smi -> nvcc / libcudart
#       -> CUDA-X libraries -> framework.
# =============================================================================