#!/usr/bin/env bash
#
# break-and-fix_351.1_virtualization-concepts.sh
#
# LPIC-3 305 (Virtualization and Containerization) — Exam 305-300, version 3.0
# Topic 351.1: Virtualization Concepts and Theory  (exam weight: 10)
# Reference: https://www.lpi.org/our-certifications/exam-305-objectives/
#
# WHAT THIS DRILL TEACHES
#   Objective 351.1 asks you to understand full virtualization vs paravirtualization,
#   Type-1 vs Type-2 hypervisors, hardware-assisted virtualization (Intel VT-x / AMD-V,
#   exposed as the `vmx` / `svm` CPU flags) and the KVM kernel modules that turn a Linux
#   host into a Type-2 (hosted) hypervisor. This script disables hardware-assisted
#   virtualization on the host so the student experiences — and must reason about — the
#   difference between an accelerated guest (KVM) and pure software emulation (QEMU TCG).
#
# SAFETY / SCOPE
#   * Run ONLY on a disposable lab VM you can throw away. It edits module config and
#     unloads kernel modules. It touches nothing outside /etc/modprobe.d and the kvm
#     modules, and it prints the exact commands to undo everything.
#   * It is idempotent: running it twice leaves the same broken state, not a worse one.
#   * It refuses to run if hardware virtualization was not available to begin with
#     (nothing to break) and it never deletes data.
#
set -euo pipefail

# ----------------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------------
readonly BREAK_TAG="351.1-vt-disabled"
readonly BLACKLIST_FILE="/etc/modprobe.d/zz-lab-break-${BREAK_TAG}.conf"
readonly STATE_DIR="/var/tmp/lpic3-break-fix"
readonly STATE_FILE="${STATE_DIR}/${BREAK_TAG}.state"

# ----------------------------------------------------------------------------------
# Cosmetics
# ----------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYA=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_CYA=''; C_BLD=''; C_RST=''
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_CYA" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
rule() { printf '%s\n' "------------------------------------------------------------------------"; }

# ----------------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "This drill must run as root (it manipulates kernel modules)."

command -v modprobe >/dev/null 2>&1 || die "modprobe not found; are you on a Linux host with kmod?"

# Detect the CPU virtualization technology and pick the vendor KVM module.
if grep -qw vmx /proc/cpuinfo; then
    CPU_VENDOR="Intel VT-x"; KVM_FLAG="vmx"; KVM_VMOD="kvm_intel"
elif grep -qw svm /proc/cpuinfo; then
    CPU_VENDOR="AMD-V";      KVM_FLAG="svm"; KVM_VMOD="kvm_amd"
else
    die "Neither 'vmx' nor 'svm' in /proc/cpuinfo. This host has no hardware-assisted
     virtualization exposed (bare-metal BIOS toggle off, or a nested VM without it).
     There is nothing for this drill to disable — enable nested virtualization on the
     outer hypervisor first, then re-run."
fi

# There must be something working to break, otherwise the exercise is meaningless.
if [[ ! -e /dev/kvm ]] || ! lsmod | grep -qw "$KVM_VMOD"; then
    die "/dev/kvm or the ${KVM_VMOD} module is already absent. KVM acceleration is not
     currently active, so there is nothing to break. Load it first with:
         modprobe ${KVM_VMOD}
     and confirm 'virt-host-validate' passes, then re-run this drill."
fi

# ----------------------------------------------------------------------------------
# Consent gate — this is a controlled break, but still a break.
# ----------------------------------------------------------------------------------
rule
say "${C_BLD}LPIC-3 305 :: 351.1 Virtualization Concepts and Theory :: BREAK & FIX${C_RST}"
rule
info "Detected hardware virtualization : ${C_BLD}${CPU_VENDOR}${C_RST} (CPU flag '${KVM_FLAG}')"
info "Vendor KVM kernel module         : ${C_BLD}${KVM_VMOD}${C_RST}"
say  ""
warn "This will DISABLE hardware-accelerated virtualization on this host."
warn "Run it only on a THROWAWAY lab VM. Confirm to proceed."
say  ""
if [[ "${I_UNDERSTAND:-}" != "yes" ]]; then
    read -r -p "Type 'break' to arm the fault (anything else aborts): " reply
    [[ "$reply" == "break" ]] || die "Aborted by user. Nothing changed."
fi

# ----------------------------------------------------------------------------------
# Record the pristine state so we can teach exactly what changed.
# ----------------------------------------------------------------------------------
mkdir -p "$STATE_DIR"
{
    echo "# Pre-break snapshot for ${BREAK_TAG}"
    echo "cpu_vendor=${CPU_VENDOR}"
    echo "kvm_flag=${KVM_FLAG}"
    echo "kvm_vmod=${KVM_VMOD}"
    echo "dev_kvm_present=yes"
    echo "modules_loaded=$(lsmod | awk '/^kvm/{printf "%s ",$1}')"
} > "$STATE_FILE"
ok "Saved pre-break state to ${STATE_FILE}"

# ----------------------------------------------------------------------------------
# THE BREAK
#   Two layers, on purpose:
#     1) blacklist  -> keeps the vendor module from auto-loading at boot.
#     2) install .. /bin/true -> defeats even an explicit `modprobe kvm_intel`,
#        which returns success while loading nothing. This is the instructive twist:
#        the naive fix "just modprobe it again" appears to work and does nothing.
# ----------------------------------------------------------------------------------
info "Writing module override: ${BLACKLIST_FILE}"
cat > "$BLACKLIST_FILE" <<EOF
# Injected by LPIC-3 351.1 break & fix drill on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Purpose: disable hardware-assisted virtualization (${CPU_VENDOR}) to force QEMU
# to fall back to software emulation (TCG). Remove this file to restore KVM.
blacklist ${KVM_VMOD}
install ${KVM_VMOD} /bin/true
EOF

info "Unloading the vendor KVM module (and the generic kvm core if idle)..."
# Attempt a clean unload. If a guest is running, the module is busy; warn instead of forcing.
if modprobe -r "$KVM_VMOD" 2>/dev/null; then
    ok "Unloaded ${KVM_VMOD}."
    # /dev/kvm is registered by the generic 'kvm' module; drop it too for a stark symptom.
    modprobe -r kvm 2>/dev/null && ok "Unloaded kvm core (/dev/kvm removed)." \
        || warn "kvm core still in use; /dev/kvm may persist but acceleration is gone."
else
    warn "${KVM_VMOD} is in use (a guest is likely running). The blacklist is in place,"
    warn "so the fault becomes fully active on next reboot. Shut down guests to see it now."
fi

# ----------------------------------------------------------------------------------
# Brief the student
# ----------------------------------------------------------------------------------
rule
say "${C_BLD}FAULT INJECTED.${C_RST}"
rule
say "${C_BLD}Symptoms you will observe:${C_RST}"
say "  * ${C_YEL}virt-host-validate${C_RST} reports:"
say "        QEMU: Checking for hardware virtualization : ${C_RED}FAIL${C_RST} (or WARN)"
say "  * ${C_YEL}ls -l /dev/kvm${C_RST}          -> 'No such file or directory'"
say "  * ${C_YEL}lsmod | grep kvm${C_RST}        -> the ${KVM_VMOD} module is gone"
say "  * ${C_YEL}virsh start <domain>${C_RST}    -> fails, or the guest boots crawlingly slow"
say "        because libvirt/QEMU falls back to TCG (pure software emulation)."
say "  * QEMU launched with ${C_YEL}-enable-kvm${C_RST} errors: 'Could not access KVM kernel module'."
say ""
say "${C_BLD}Your goal:${C_RST}"
say "  Restore hardware-assisted virtualization ${C_BLD}without rebooting${C_RST}. Success ="
say "    1. ${C_GRN}/dev/kvm${C_RST} exists again,"
say "    2. ${C_GRN}${KVM_VMOD}${C_RST} shows up in 'lsmod',"
say "    3. ${C_GRN}virt-host-validate${C_RST} prints PASS for KVM hardware virtualization."
say ""
say "${C_BLD}Concepts under test (351.1):${C_RST}"
say "  full virtualization vs paravirtualization; Type-1 (bare-metal) vs Type-2 (hosted)"
say "  hypervisors; Intel VT-x/AMD-V ('${KVM_FLAG}') as the enabler of hardware-assisted"
say "  full virtualization; KVM as the Type-2 hypervisor kernel component; QEMU/TCG as"
say "  the software-emulation fallback when acceleration is unavailable."
say ""
warn "Hint: a plain 'modprobe ${KVM_VMOD}' will look like it worked and change nothing."
warn "Ask yourself WHY, and where module loading policy actually lives."
rule
ok "Drill armed. The step-by-step solution is at the bottom of this script (commented)."

exit 0

# =================================================================================
# ============================  SOLUTION  (do not peek early)  =====================
# =================================================================================
#
# STEP 0 — Reproduce and name the symptom
#   # virt-host-validate qemu
#   #   QEMU: Checking for hardware virtualization : FAIL (Only emulated CPUs are available)
#   # ls -l /dev/kvm
#   #   ls: cannot access '/dev/kvm': No such file or directory
#   # lsmod | grep kvm            # kvm_intel / kvm_amd absent
#   Conclusion: the vendor KVM module is not loaded, so /dev/kvm was never created.
#
# STEP 1 — Confirm the hardware itself still supports it (rule out a BIOS/firmware cause)
#   # grep -Ewo 'vmx|svm' /proc/cpuinfo | sort -u
#   If 'vmx' (Intel) or 'svm' (AMD) is present, the CPU is capable; the fault is in software.
#   (If it were EMPTY, the cause would be VT-x/AMD-V disabled in BIOS or missing nested
#    virtualization on the outer hypervisor — a different, hardware/firmware-layer fix.)
#
# STEP 2 — Try the naive fix and watch it fail silently (the teaching moment)
#   # modprobe kvm_intel        # (or kvm_amd)   -> returns 0, prints nothing
#   # lsmod | grep kvm          -> STILL absent
#   The exit status is success but nothing loaded. That means a modprobe *policy* is
#   intercepting the load, not a hardware or dependency problem.
#
# STEP 3 — Inspect the effective modprobe configuration
#   # modprobe -c | grep -E 'kvm_intel|kvm_amd'
#   #   blacklist kvm_intel
#   #   install kvm_intel /bin/true
#   # grep -RniE 'kvm_intel|kvm_amd' /etc/modprobe.d/
#   The 'install <mod> /bin/true' line is the culprit: modprobe runs /bin/true instead of
#   inserting the module, which is why it "succeeds" without loading anything. 'blacklist'
#   alone would only stop *automatic* loading; the install line also blocks the manual one.
#
# STEP 4 — Remove the injected override
#   # rm -f /etc/modprobe.d/zz-lab-break-351.1-vt-disabled.conf
#   (Regenerating the initramfs is unnecessary here: these directives affect userspace
#    modprobe, not the initrd. You would only rebuild it — dracut -f  /  update-initramfs -u
#    — if the blacklist had been baked into the initramfs for a boot-critical module.)
#
# STEP 5 — Load the modules and recreate /dev/kvm
#   # modprobe kvm_intel        # (or kvm_amd)   -> now actually loads; pulls in kvm too
#   # lsmod | grep kvm
#   #   kvm_intel  ...
#   #   kvm        ...  1 kvm_intel
#   # ls -l /dev/kvm
#   #   crw-rw----+ 1 root kvm 10, 232 ... /dev/kvm
#
# STEP 6 — Verify the fix against the objective's definition of "working"
#   # virt-host-validate qemu
#   #   QEMU: Checking for hardware virtualization : PASS
#   #   QEMU: Checking if device /dev/kvm exists    : PASS
#   #   QEMU: Checking if device /dev/kvm is accessible : PASS
#   # kvm-ok                     # if cpu-checker is installed:
#   #   INFO: /dev/kvm exists
#   #   KVM acceleration can be used
#   A guest started now runs with KVM acceleration instead of TCG emulation.
#
# STEP 7 — (Optional) prove the difference the objective is really about
#   Boot a tiny guest twice and compare:
#     Accelerated : qemu-system-x86_64 -enable-kvm -m 512 -nographic ...   (near-native speed)
#     Emulated    : qemu-system-x86_64 -accel tcg  -m 512 -nographic ...   (10-50x slower)
#   That gap IS the practical meaning of "hardware-assisted full virtualization" vs pure
#   software emulation in objective 351.1.
#
# ONE-LINER RESTORE:
#   rm -f /etc/modprobe.d/zz-lab-break-351.1-vt-disabled.conf && modprobe kvm_intel && \
#     virt-host-validate qemu ; ls -l /dev/kvm     # swap kvm_intel -> kvm_amd on AMD hosts
#
# Sources:
#   * LPI Exam 305-300 Objectives, 351.1 — https://www.lpi.org/our-certifications/exam-305-objectives/
#   * KVM (Kernel-based Virtual Machine)     — https://www.linux-kvm.org/page/Main_Page
#   * libvirt virt-host-validate(1)          — https://libvirt.org/manpages/virt-host-validate.html
#   * modprobe.d(5) blacklist/install syntax — https://man7.org/linux/man-pages/man5/modprobe.d.5.html
# =================================================================================