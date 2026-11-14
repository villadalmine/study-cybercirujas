#!/usr/bin/env bash
# lab-resources: cpus=1 ram_mb=256
#
# NCA-AIIO 3.4 - Identify the key considerations for virtualizing accelerated
# infrastructure.
#
# Break & fix: full GPU passthrough (VFIO) of an NVIDIA H100 PCIe to a KVM/libvirt
# inference VM on a two-socket host.
#
# What this lab practices (the considerations the exam asks about):
#   * Sharing model. Whole-GPU passthrough (VFIO, one VM owns the GPU, near-native
#     performance, no live migration); NVIDIA vGPU (a vGPU Manager on the hypervisor,
#     a licensed guest driver from the same release branch, time-sliced or
#     MIG-backed profiles); MIG (hardware partitions with isolated SMs, L2 and memory;
#     up to 7 instances on A100/H100); plain time-slicing (no memory/fault isolation).
#     https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
#   * Host prerequisites. VT-d/AMD-Vi enabled in the BIOS and in the kernel
#     (intel_iommu=on, iommu=pt), clean IOMMU groups (ACS), and the GPU claimed by
#     vfio-pci before nvidia/nouveau can bind it.
#   * Topology. A VM's vCPUs and memory have to stay on the NUMA node that owns the
#     GPU's PCIe root port. If they don't, every DMA crosses the inter-socket link.
#     Use 1G hugepages and locked memory for predictable latency.
#   * Firmware. GPUs with large BARs (the H100 BAR1 is 128 GiB) need UEFI/OVMF and
#     a 64-bit MMIO window in the guest. SeaBIOS cannot map them.
#   * Operations. Passthrough VMs are pinned to their host (no live migration), so
#     plan maintenance windows. Monitor with DCGM inside the guest for passthrough,
#     and on the host for vGPU/MIG.
#     https://developer.nvidia.com/dcgm
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#     https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
#     https://kubernetes.io/docs/home/
#
# The disposable lab VM has no GPU and no nested KVM, so the GPU host is SIMULATED
# inside a sandbox directory ($LAB): grub, modprobe.d, sysfs, dmesg, the libvirt
# domain, and tiny lab-* tools that behave like the real commands. Nothing outside
# $LAB is touched, and root is not required. The script never waits for input.
#
# Usage: ./lab.sh [break|verify|cleanup]     (no argument = break)

set -euo pipefail

LAB="${AIIO_LAB_DIR:-/var/tmp/aiio-virt-lab}"
MARKER=".aiio-virt-lab"

safe_lab_path() {
  case "$LAB" in
    ""|"/"|"/var"|"/var/tmp"|"/tmp"|"/opt"|"${HOME:-/nonexistent}")
      echo "Refusing to use LAB=$LAB" >&2; exit 2 ;;
  esac
  if [[ -e "$LAB" && ! -f "$LAB/$MARKER" ]]; then
    echo "$LAB exists and was not created by this lab; refusing to touch it." >&2
    echo "Set AIIO_LAB_DIR to another path." >&2
    exit 2
  fi
}

write_tools() {
  mkdir -p "$LAB/bin"

  cat > "$LAB/bin/_lib.sh" <<'LIB'
# shellcheck shell=bash
# Shared helpers for the simulated GPU host. Every lab-* tool sources this file.
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_SIM="gpu-host-07"
VM="llm-inference-01"
BDF="0000:17:00.0"
GPU_ID="10de:2331"
GRUB="$LAB/etc/default/grub"
VFIO="$LAB/etc/modprobe.d/vfio.conf"
CMDLINE="$LAB/proc/cmdline"
DMESG="$LAB/var/log/dmesg"
DEV="$LAB/sys/bus/pci/devices/$BDF"
NODES="$LAB/sys/devices/system/node"
XML_SRC="$LAB/vm/$VM.xml"
XML_DEF="$LAB/var/lib/libvirt/qemu/$VM.xml"

# Kernel parameters that the next boot would get (both GRUB variables are used).
grub_cmdline() {
  local v line out=""
  for v in GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX; do
    line=$(grep -E "^[[:space:]]*${v}=" "$GRUB" 2>/dev/null | tail -n1 || true)
    line=${line#*=}
    line=${line//\"/}
    line=${line//\'/}
    out="$out $line"
  done
  printf '%s\n' "$out" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

iommu_enabled() { local c=" $* "; [[ $c == *" intel_iommu=on "* ]]; }
iommu_pt()      { local c=" $* "; [[ $c == *" iommu=pt "* ]]; }

vfio_ids() {
  { grep -E '^[[:space:]]*options[[:space:]]+vfio-pci' "$VFIO" 2>/dev/null || true; } \
    | { grep -oE 'ids=[^[:space:]]+' || true; } | tail -n1 | cut -d= -f2
}
vfio_ok() { local ids=",$(vfio_ids),"; [[ $ids == *",$GPU_ID,"* ]]; }
driver_bound() { cat "$DEV/driver" 2>/dev/null || echo none; }

expand_cpus() {
  local part a b i out=""
  local IFS=','
  for part in $1; do
    part=${part// /}
    if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
      for ((i=a; i<=b; i++)); do out+="$i "; done
    elif [[ $part =~ ^[0-9]+$ ]]; then
      out+="$part "
    fi
  done
  printf '%s\n' "${out% }"
}

xml_nodeset() {
  { grep -oE "<memory[[:space:]]+[^>]*nodeset=['\"][^'\"]+['\"]" "${1:-$XML_DEF}" || true; } \
    | { grep -oE "nodeset=['\"][^'\"]+" || true; } | head -n1 | sed -E "s/nodeset=['\"]//"
}
xml_cpusets() {
  { grep -oE "<(vcpupin|emulatorpin)[^>]*cpuset=['\"][^'\"]+['\"]" "${1:-$XML_DEF}" || true; } \
    | { grep -oE "cpuset=['\"][^'\"]+" || true; } | sed -E "s/cpuset=['\"]//"
}
xml_efi() {
  grep -qE "<os[^>]*firmware=['\"]efi['\"]" "${1:-$XML_DEF}" \
    || grep -qE "<loader[^>]*>[^<]*(OVMF|edk2)" "${1:-$XML_DEF}"
}
xml_hostdev() {
  grep -qE "<address[^>]*bus=['\"]0x17['\"][^>]*slot=['\"]0x00['\"][^>]*function=['\"]0x0['\"]" "${1:-$XML_DEF}"
}

# Prints one line per NUMA problem; the return code is the number of problems.
numa_report() {
  local xml="${1:-$XML_DEF}" gnode node_cpus nodeset vcpus pins cs c n=0
  gnode=$(cat "$DEV/numa_node")
  node_cpus=" $(expand_cpus "$(cat "$NODES/node$gnode/cpulist")") "
  nodeset=$(xml_nodeset "$xml")
  if [[ "$nodeset" != "$gnode" ]]; then
    echo "numatune <memory nodeset='${nodeset:-none}'/> but the GPU ($BDF) is attached to NUMA node $gnode"
    n=$((n+1))
  fi
  vcpus=$({ grep -oE '<vcpu( [^>]*)?>[[:space:]]*[0-9]+' "$xml" || true; } | grep -oE '[0-9]+$' | head -n1)
  pins=$(grep -cE '<vcpupin[[:space:]]' "$xml" || true)
  if [[ -z "$vcpus" || "$pins" != "$vcpus" ]]; then
    echo "$pins <vcpupin> entries for ${vcpus:-?} vCPUs: unpinned vCPUs can run on the remote socket"
    n=$((n+1))
  fi
  while read -r cs; do
    [[ -n "$cs" ]] || continue
    for c in $(expand_cpus "$cs"); do
      if [[ "$node_cpus" != *" $c "* ]]; then
        echo "cpuset='$cs' uses host CPU $c, which is not on NUMA node $gnode"
        n=$((n+1)); break
      fi
    done
  done < <(xml_cpusets "$xml")
  return "$n"
}
LIB

  cat > "$LAB/bin/lab-reboot" <<'REBOOT'
#!/usr/bin/env bash
# Simulates: grub-mkconfig/update-grub + update-initramfs/dracut + reboot.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
quiet=0; [[ "${1:-}" == "--quiet" ]] && quiet=1

c=$(grub_cmdline)
printf 'BOOT_IMAGE=/boot/vmlinuz-6.8.0-45-generic root=UUID=6b1f0c2e-41d7-4f0e-9a43-2a7c1d8e5f10 ro %s\n' "$c" > "$CMDLINE"

{
  echo "[    0.000000] Linux version 6.8.0-45-generic (buildd@lcy02-amd64-075) #45-Ubuntu SMP PREEMPT_DYNAMIC"
  echo "[    0.000000] Command line: $(cat "$CMDLINE")"
  echo "[    0.398112] DMAR: Host address width 46"
  echo "[    0.398130] DMAR: DRHD base: 0x000000fbffc000 flags: 0x0"
  if iommu_enabled "$c"; then
    echo "[    0.398201] DMAR: IOMMU enabled"
    if iommu_pt "$c"; then
      echo "[    1.180344] iommu: Default domain type: Passthrough (set via kernel command line)"
    else
      echo "[    1.180344] iommu: Default domain type: Translated"
    fi
    echo "[    1.204551] pci $BDF: Adding to iommu group 23"
  fi
  for id in $(vfio_ids | tr ',' ' '); do
    echo "[    3.102938] vfio_pci: add [${id}[ffffffff:ffffffff]] class 0x000000/00000000"
  done
  if iommu_enabled "$c" && vfio_ok; then
    :
  elif vfio_ok; then
    echo "[    3.103012] vfio-pci: probe of $BDF failed with error -22"
  else
    echo "[    4.392210] nvidia: loading out-of-tree module taints kernel."
    echo "[    4.551203] nvidia $BDF: enabling device (0000 -> 0002)"
    echo "[    4.601877] NVRM: loading NVIDIA UNIX x86_64 Kernel Module  550.90.07  Fri May 31 09:35:42 UTC 2024"
  fi
} > "$DMESG"

if iommu_enabled "$c"; then echo 23 > "$DEV/iommu_group"; else rm -f "$DEV/iommu_group"; fi
if iommu_enabled "$c" && vfio_ok; then
  echo vfio-pci > "$DEV/driver"
elif vfio_ok; then
  echo none > "$DEV/driver"
else
  echo nvidia > "$DEV/driver"
fi

if [[ $quiet -eq 0 ]]; then
  echo "[sim] grub-mkconfig -o /boot/grub/grub.cfg ... done"
  echo "[sim] update-initramfs -u -k all ... done"
  echo "[sim] systemctl reboot ... $HOST_SIM is back up"
  echo "[sim] /proc/cmdline: $(cat "$CMDLINE")"
fi
REBOOT

  cat > "$LAB/bin/lab-topo" <<'TOPO'
#!/usr/bin/env bash
# Prints what lspci, sysfs, numactl and dmesg would show on the simulated host.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
d=$(driver_bound)
echo "\$ lspci -nnk -s 17:00.0"
echo "17:00.0 3D controller [0302]: NVIDIA Corporation GH100 [H100 PCIe] [$GPU_ID] (rev a1)"
echo "	Subsystem: NVIDIA Corporation Device [10de:1626]"
[[ "$d" != none ]] && echo "	Kernel driver in use: $d"
echo "	Kernel modules: nvidiafb, nouveau, nvidia_drm, nvidia, vfio-pci"
echo
echo "\$ cat /sys/bus/pci/devices/$BDF/numa_node"
cat "$DEV/numa_node"
echo
echo "\$ find /sys/kernel/iommu_groups/ -type l"
if [[ -f "$DEV/iommu_group" ]]; then
  echo "/sys/kernel/iommu_groups/$(cat "$DEV/iommu_group")/devices/$BDF"
fi
echo
echo "\$ numactl -H"
echo "available: 2 nodes (0-1)"
echo "node 0 cpus: $(expand_cpus "$(cat "$NODES/node0/cpulist")")"
echo "node 0 size: 257579 MB"
echo "node 0 free: 191230 MB"
echo "node 1 cpus: $(expand_cpus "$(cat "$NODES/node1/cpulist")")"
echo "node 1 size: 258041 MB"
echo "node 1 free: 189874 MB"
echo "node distances:"
echo "node   0   1"
echo "  0:  10  21"
echo "  1:  21  10"
echo
echo "\$ cat /proc/cmdline"
cat "$CMDLINE"
echo
echo "\$ dmesg | grep -iE 'dmar|iommu|vfio|nvrm|nvidia'"
grep -iE 'dmar|iommu|vfio|nvrm|nvidia' "$DMESG" | grep -v 'Command line' || true
TOPO

  cat > "$LAB/bin/lab-virsh" <<'VIRSH'
#!/usr/bin/env bash
# Minimal libvirt simulator: define | start | dumpxml
set -uo pipefail
. "$(dirname "$0")/_lib.sh"

case "${1:-help}" in
  define)
    src="${2:-$XML_SRC}"
    [[ -f "$src" ]] || { echo "error: Failed to open file '$src': No such file or directory"; exit 1; }
    if command -v xmllint >/dev/null 2>&1; then
      xmllint --noout "$src" || { echo "error: Failed to define domain from $src"; exit 1; }
    elif command -v python3 >/dev/null 2>&1; then
      python3 -I -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$src" \
        || { echo "error: Failed to define domain from $src"; exit 1; }
    fi
    grep -q "<name>$VM</name>" "$src" || { echo "error: domain name must stay '$VM'"; exit 1; }
    mkdir -p "$(dirname "$XML_DEF")"
    cp "$src" "$XML_DEF"
    echo "Domain '$VM' defined from $src"
    ;;
  dumpxml)
    cat "$XML_DEF"
    ;;
  start)
    c=$(cat "$CMDLINE")
    if ! iommu_enabled "$c"; then
      echo "error: Failed to start domain '$VM'"
      echo "error: unsupported configuration: host doesn't support passthrough of host PCI devices"
      exit 1
    fi
    if xml_hostdev "$XML_DEF"; then
      d=$(driver_bound)
      if [[ "$d" != vfio-pci ]]; then
        echo "error: Failed to start domain '$VM'"
        echo "error: internal error: PCI device $BDF (hostdev managed='no') is bound to '$d', expected 'vfio-pci'"
        exit 1
      fi
    fi
    echo "Domain '$VM' started"
    echo "--- guest console (simulated) ---"
    if ! xml_hostdev "$XML_DEF"; then
      echo "guest\$ nvidia-smi"
      echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver. Make sure that the latest NVIDIA driver is installed and running."
      exit 0
    fi
    if ! xml_efi "$XML_DEF"; then
      echo "[    2.904117] pci 0000:01:00.0: BAR 1: no space for [mem size 0x2000000000 64bit pref]"
      echo "[    2.904121] pci 0000:01:00.0: BAR 1: failed to assign [mem size 0x2000000000 64bit pref]"
      echo "[    5.118402] NVRM: This PCI I/O region assigned to your NVIDIA device is invalid:"
      echo "               NVRM: BAR1 is 0M @ 0x0 (PCI:0000:01:00.0)"
      echo "[    5.118460] nvidia: probe of 0000:01:00.0 failed with error -1"
      echo "guest\$ nvidia-smi"
      echo "No devices were found"
      exit 0
    fi
    echo "guest\$ nvidia-smi --query-gpu=name,pci.bus_id,memory.total,driver_version --format=csv"
    echo "name, pci.bus_id, memory.total [MiB], driver_version"
    echo "NVIDIA H100 PCIe, 00000000:01:00.0, 81559 MiB, 550.90.07"
    echo "guest\$ ./bandwidthTest --memory=pinned --htod"
    if numa_report "$XML_DEF" >/dev/null; then
      echo " Host to Device Bandwidth, 1 Device(s), PINNED Memory Transfers"
      echo "   Transfer Size (Bytes)	Bandwidth(GB/s)"
      echo "   32000000			54.9"
      echo "Result = PASS"
    else
      echo " Host to Device Bandwidth, 1 Device(s), PINNED Memory Transfers"
      echo "   Transfer Size (Bytes)	Bandwidth(GB/s)"
      echo "   32000000			38.2"
      echo "Result = PASS"
      echo "[sim] SLO alert: H2D bandwidth 38.2 GB/s < 50 GB/s baseline; p99 token latency +31%"
      echo "[sim] host\$ numastat -p qemu-system-x86_64  ->  guest memory resident on node $(xml_nodeset "$XML_DEF")"
    fi
    ;;
  *)
    echo "usage: lab-virsh define [file] | start | dumpxml"
    ;;
esac
VIRSH

  cat > "$LAB/bin/lab-preflight" <<'PRE'
#!/usr/bin/env bash
# Platform-team preflight for a GPU passthrough VM. Exit 0 = ready for production.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
fail=0
pass() { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '[WARN] %s\n' "$*"; }
note() { printf '       %s\n' "$*"; }

echo "gpu-virt-preflight  host=$HOST_SIM  vm=$VM  gpu=$BDF [$GPU_ID]"
echo

running=$(cat "$CMDLINE")
configured=$(grub_cmdline)
missing=""
iommu_enabled "$running" || missing+=" intel_iommu=on"
iommu_pt "$running" || missing+=" iommu=pt"
if [[ -z "$missing" ]]; then
  pass "IOMMU: running kernel has intel_iommu=on iommu=pt"
else
  bad "IOMMU: running kernel cmdline is missing:$missing"
  if iommu_enabled "$configured" && iommu_pt "$configured"; then
    note "etc/default/grub already has it, but the host has not booted with it (regenerate + reboot)"
  else
    note "check: etc/default/grub, /proc/cmdline, dmesg | grep -i dmar   (lab-topo)"
  fi
fi

d=$(driver_bound)
if [[ "$d" == vfio-pci ]]; then
  pass "VFIO: $BDF is bound to vfio-pci (IOMMU group $(cat "$DEV/iommu_group" 2>/dev/null || echo '?'))"
else
  bad "VFIO: $BDF is bound to '$d'; a managed='no' passthrough hostdev must sit on vfio-pci"
  if vfio_ok; then
    note "etc/modprobe.d/vfio.conf already claims $GPU_ID; binding only changes at boot (initramfs + reboot)"
  else
    note "etc/modprobe.d/vfio.conf claims ids='$(vfio_ids)'; compare with the [vendor:device] from lspci -nn"
  fi
fi

if xml_hostdev "$XML_DEF"; then
  pass "Domain: hostdev 0000:17:00.0 is attached to $VM"
else
  bad "Domain: the defined $VM has no hostdev for 0000:17:00.0 (the GPU must stay attached)"
fi

if xml_efi "$XML_DEF"; then
  pass "Firmware: UEFI/OVMF (needed to map the 128 GiB BAR1 of the H100)"
else
  bad "Firmware: legacy BIOS (SeaBIOS); large 64-bit GPU BARs cannot be mapped in the guest"
fi

mapfile -t probs < <(numa_report "$XML_DEF")
if [[ ${#probs[@]} -eq 0 ]]; then
  pass "NUMA: vCPUs, emulator threads and guest memory are on the GPU's node ($(cat "$DEV/numa_node"))"
else
  bad "NUMA: VM placement does not follow the GPU's PCIe locality"
  for p in "${probs[@]}"; do note "$p"; done
fi

if [[ -f "$XML_SRC" ]] && ! cmp -s "$XML_SRC" "$XML_DEF"; then
  warn "vm/$VM.xml differs from the defined domain; libvirt runs the defined copy (lab-virsh define)"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "RESULT: READY - $VM can go to production"
  exit 0
fi
echo "RESULT: NOT READY - $fail check(s) failed"
exit 1
PRE

  chmod +x "$LAB/bin/lab-reboot" "$LAB/bin/lab-topo" "$LAB/bin/lab-virsh" "$LAB/bin/lab-preflight"
}

build_lab() {
  mkdir -p "$LAB"/{etc/default,etc/modprobe.d,proc,var/log,var/lib/libvirt/qemu,vm} \
           "$LAB/sys/bus/pci/devices/0000:17:00.0" \
           "$LAB/sys/devices/system/node/node0" "$LAB/sys/devices/system/node/node1"
  touch "$LAB/$MARKER"

  cat > "$LAB/etc/default/grub" <<'GRUB'
# /etc/default/grub (simulated) - gpu-host-07, 2x Xeon, 1x H100 PCIe
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`( . /etc/os-release; echo ${NAME:-Ubuntu} ) 2>/dev/null || echo Ubuntu`
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 default_hugepagesz=1G hugepagesz=1G hugepages=128"
GRUB

  cat > "$LAB/etc/modprobe.d/vfio.conf" <<'VFIO'
# /etc/modprobe.d/vfio.conf (simulated)
# Claim the passthrough GPU with vfio-pci before nvidia/nouveau can bind it.
options vfio-pci ids=10de:2330
softdep nvidia pre: vfio-pci
softdep nouveau pre: vfio-pci
VFIO

  local dev="$LAB/sys/bus/pci/devices/0000:17:00.0"
  echo 0x10de > "$dev/vendor"
  echo 0x2331 > "$dev/device"
  echo 0x030200 > "$dev/class"
  echo 0 > "$dev/numa_node"
  echo "0-15" > "$LAB/sys/devices/system/node/node0/cpulist"
  echo "16-31" > "$LAB/sys/devices/system/node/node1/cpulist"

  cat > "$LAB/vm/llm-inference-01.xml" <<'XML'
<domain type='kvm'>
  <name>llm-inference-01</name>
  <description>Inference VM: 1x H100 PCIe via VFIO passthrough (whole GPU, no vGPU/MIG)</description>
  <memory unit='GiB'>64</memory>
  <currentMemory unit='GiB'>64</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='1' unit='GiB'/>
    </hugepages>
    <locked/>
  </memoryBacking>
  <vcpu placement='static'>8</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='16'/>
    <vcpupin vcpu='1' cpuset='17'/>
    <vcpupin vcpu='2' cpuset='18'/>
    <vcpupin vcpu='3' cpuset='19'/>
    <vcpupin vcpu='4' cpuset='20'/>
    <vcpupin vcpu='5' cpuset='21'/>
    <vcpupin vcpu='6' cpuset='22'/>
    <vcpupin vcpu='7' cpuset='23'/>
    <emulatorpin cpuset='24-25'/>
  </cputune>
  <numatune>
    <memory mode='strict' nodeset='1'/>
  </numatune>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='off'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'/>
      <source file='/var/lib/libvirt/images/llm-inference-01.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <source bridge='br0'/>
      <model type='virtio'/>
    </interface>
    <hostdev mode='subsystem' type='pci' managed='no'>
      <source>
        <address domain='0x0000' bus='0x17' slot='0x00' function='0x0'/>
      </source>
    </hostdev>
    <console type='pty'/>
  </devices>
</domain>
XML

  write_tools
  "$LAB/bin/lab-reboot" --quiet
  "$LAB/bin/lab-virsh" define "$LAB/vm/llm-inference-01.xml" >/dev/null
}

do_break() {
  safe_lab_path
  rm -rf "$LAB"
  build_lab
  cat <<EOF
=====================================================================
 NCA-AIIO 3.4 - Virtualizing accelerated infrastructure (break & fix)
=====================================================================
Scenario
  gpu-host-07 is a two-socket KVM host with one NVIDIA H100 PCIe. The
  platform team wants to hand the WHOLE GPU to the inference VM
  'llm-inference-01' through VFIO passthrough. The previous engineer left
  the host and the domain half configured, and the VM never got a usable GPU.

Simulated host (no GPU in this lab VM): $LAB
  etc/default/grub            kernel parameters for the next boot
  etc/modprobe.d/vfio.conf    which PCI IDs vfio-pci claims at boot
  vm/llm-inference-01.xml     the domain XML you edit
  bin/lab-topo                lspci -nnk / numa_node / iommu groups / numactl -H / dmesg
  bin/lab-reboot              regenerate grub + initramfs and reboot the host
  bin/lab-virsh               define <file> | start | dumpxml
  bin/lab-preflight           the platform team's go/no-go check

  export PATH="$LAB/bin:\$PATH"

Symptoms you will see
  \$ lab-virsh start
    error: unsupported configuration: host doesn't support passthrough of host PCI devices
  Fix that and the next layer appears: the GPU is held by the wrong driver,
  then 'No devices were found' inside the guest, then a VM that works but is
  slow (H2D bandwidth well below baseline).

Goal
  lab-preflight reports READY: IOMMU on (and in passthrough mode) in the
  RUNNING kernel, GPU bound to vfio-pci, UEFI firmware, and vCPUs, emulator
  threads and guest memory on the same NUMA node as the GPU. lab-virsh start
  must show ~55 GB/s. Keep the hostdev attached and the domain name unchanged.

Check your work:  $0 verify
Reset the lab:    $0 break        Remove it:  $0 cleanup
EOF
}

do_verify() {
  if [[ ! -f "$LAB/$MARKER" ]]; then
    echo "Lab not prepared. Run: $0 break" >&2
    exit 2
  fi
  write_tools
  if "$LAB/bin/lab-preflight"; then
    echo
    echo "VERIFY: OK - the passthrough VM is production ready."
    exit 0
  fi
  echo
  echo "VERIFY: NOT FIXED yet."
  exit 1
}

do_cleanup() {
  safe_lab_path
  rm -rf "$LAB"
  echo "Lab removed ($LAB). The VM is as it was before."
}

case "${1:-break}" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *) echo "usage: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# SOLUTION (step by step)
# ---------------------------------------------------------------------------
# 0) export PATH="/var/tmp/aiio-virt-lab/bin:$PATH"; cd /var/tmp/aiio-virt-lab
#    lab-topo
#      - lspci -nn shows the real ID [10de:2331] (H100 PCIe; 10de:2330 is the SXM5 part)
#      - numa_node = 0 -> the GPU hangs off socket 0, whose CPUs are 0-15
#      - dmesg has no "DMAR: IOMMU enabled", and there is no iommu group for the device
#
# 1) Enable the IOMMU. Edit etc/default/grub:
#      GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 default_hugepagesz=1G hugepagesz=1G hugepages=128 intel_iommu=on iommu=pt"
#    intel_iommu=on enables DMA remapping, which VFIO requires. iommu=pt keeps
#    host-owned devices in identity mapping, so they pay no translation cost.
#    On AMD use amd_iommu=on (enabled by default on recent kernels) plus iommu=pt.
#    VT-d / AMD-Vi must also be enabled in the BIOS/BMC.
#
# 2) Claim the right device with vfio-pci. Edit etc/modprobe.d/vfio.conf:
#      options vfio-pci ids=10de:2331
#
# 3) Apply both changes. Kernel parameters and initramfs only take effect at boot:
#      lab-reboot
#    Real host: sudo update-grub (or grub2-mkconfig -o /boot/grub2/grub.cfg)
#               sudo update-initramfs -u -k all   (or: sudo dracut -f)
#               sudo systemctl reboot
#    Check:     cat /proc/cmdline; dmesg | grep -iE 'dmar|iommu'
#               lspci -nnk -s 17:00.0   -> "Kernel driver in use: vfio-pci"
#               find /sys/kernel/iommu_groups/ -type l  (the group must hold only
#               the GPU, or every member must go to vfio-pci; otherwise you need ACS)
#
# 4) Fix the domain XML (vm/llm-inference-01.xml):
#    a) UEFI firmware, so the guest can map the 128 GiB BAR1:
#         <os firmware='efi'>
#           <type arch='x86_64' machine='q35'>hvm</type>
#           <boot dev='hd'/>
#         </os>
#       (On older QEMU/OVMF you may also have to enlarge the 64-bit MMIO window, e.g.
#        -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=262144 through <qemu:commandline>.)
#    b) Place the VM on the GPU's NUMA node (0 -> CPUs 0-15). Leave CPUs 0-1 for the host:
#         <cputune>
#           <vcpupin vcpu='0' cpuset='2'/>
#           <vcpupin vcpu='1' cpuset='3'/>
#           <vcpupin vcpu='2' cpuset='4'/>
#           <vcpupin vcpu='3' cpuset='5'/>
#           <vcpupin vcpu='4' cpuset='6'/>
#           <vcpupin vcpu='5' cpuset='7'/>
#           <vcpupin vcpu='6' cpuset='8'/>
#           <vcpupin vcpu='7' cpuset='9'/>
#           <emulatorpin cpuset='10-11'/>
#         </cputune>
#         <numatune>
#           <memory mode='strict' nodeset='0'/>
#         </numatune>
#       The 1G hugepages (128 in total, ~64 per node) cover the 64 GiB guest on node 0.
#
# 5) Libvirt runs its own copy of the domain, so editing the file is not enough:
#      lab-virsh define vm/llm-inference-01.xml      (real: virsh define ... or virsh edit)
#      lab-virsh start                               -> NVIDIA H100 PCIe, ~54.9 GB/s
#      lab-preflight                                 -> RESULT: READY
#
# 6) ./lab.sh verify   -> exit 0
#
# Operational takeaways: a passthrough VM cannot be live-migrated (one VM per GPU,
# so drain it for host maintenance). If you need sharing or mobility, evaluate
# vGPU (licensed, the guest driver must match the host vGPU Manager branch) or
# MIG-backed vGPU for hardware isolation. Run DCGM inside the guest for
# passthrough GPUs.