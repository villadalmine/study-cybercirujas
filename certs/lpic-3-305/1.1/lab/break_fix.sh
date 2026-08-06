#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Exam 305-300 (v3.0) - Topic 1.1: Full Virtualization
# Break & Fix Laboratory Scenario: QEMU/KVM Hypervisor Acceleration & Disk Format Mismatch
# ==============================================================================
# Target Certification: LPIC-3 Virtualization and Containerization (Exam 305-300)
# Topic 1.1: Full Virtualization (Weight: 33.33)
# Official Reference: https://www.lpi.org/our-certifications/lpic-3-305-overview/
# Additional References:
#   - QEMU Documentation: https://www.qemu.org/docs/master/
#   - Libvirt Domain XML Architecture: https://libvirt.org/formatdomain.html
#   - Linux KVM Subsystem Documentation: https://www.kernel.org/doc/html/latest/virt/kvm/index.html
# ==============================================================================

set -euo pipefail

LAB_DOMAIN="lpic3-prod-db01"
LAB_DIR="/var/lib/libvirt/images/lpic3-lab"
DOM_XML="/etc/libvirt/qemu/${LAB_DOMAIN}.xml"

RED='\030[0;31m'
GREEN='\032[0;32m'
NC='\033[0m'

check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be run as root to modify libvirt and hypervisor configurations.${NC}" >&2
        exit 1
    fi

    for cmd in virsh qemu-img qemu-system-x86_64 systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}[ERROR] Required virtualization tool '$cmd' is not installed.${NC}" >&2
            exit 1
        fi
    done

    if ! systemctl is-active --quiet libvirtd; then
        echo -e "${RED}[ERROR] libvirtd service is not running. Please start libvirtd first.${NC}" >&2
        exit 1
    fi
}

provision_lab_environment() {
    echo -e "[+] Provisioning disposable lab domain: ${LAB_DOMAIN}..."
    mkdir -p "${LAB_DIR}"

    if virsh dominfo "${LAB_DOMAIN}" &>/dev/null; then
        virsh destroy "${LAB_DOMAIN}" &>/dev/null || true
        virsh undefine "${LAB_DOMAIN}" --remove-all-storage &>/dev/null || true
    fi

    qemu-img create -f qcow2 "${LAB_DIR}/${LAB_DOMAIN}.qcow2" 100M >/dev/null

    cat <<EOF > "${DOM_XML}"
<domain type='kvm'>
  <name>${LAB_DOMAIN}</name>
  <memory unit='KiB'>524288</memory>
  <vcpu placement='static'>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-latest'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${LAB_DIR}/${LAB_DOMAIN}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='user'>
      <model type='virtio'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
EOF

    virsh define "${DOM_XML}" >/dev/null
}

inject_breakage() {
    echo -e "[+] Injecting realistic production failure into ${LAB_DOMAIN}..."

    # Breakage 1: Alter character device node permissions on /dev/kvm
    # Strips group read/write, preventing libvirt QEMU unprivileged worker process from using hardware virtualization capabilities.
    if [[ -c /dev/kvm ]]; then
        chmod 0600 /dev/kvm
        chown root:root /dev/kvm
    fi

    # Breakage 2: Introduce driver storage type mismatch in Domain XML schema
    # Sets the disk driver type to 'raw' while backing file remains 'qcow2' format image header.
    virsh dumpxml "${LAB_DOMAIN}" > /tmp/${LAB_DOMAIN}_temp.xml
    sed -i "s/<driver name='qemu' type='qcow2'\/>/<driver name='qemu' type='raw'\/>/g" /tmp/${LAB_DOMAIN}_temp.xml
    sed -i "s/<domain type='kvm'>/<domain type='qemu'>/g" /tmp/${LAB_DOMAIN}_temp.xml
    virsh define /tmp/${LAB_DOMAIN}_temp.xml >/dev/null
    rm -f /tmp/${LAB_DOMAIN}_temp.xml

    # Breakage 3: Disable Nested Virtualization in module runtime configuration
    if [[ -d /sys/module/kvm_intel ]]; then
        modprobe -r kvm_intel 2>/dev/null || true
        modprobe kvm_intel nested=0 2>/dev/null || true
    elif [[ -d /sys/module/kvm_amd ]]; then
        modprobe -r kvm_amd 2>/dev/null || true
        modprobe kvm_amd nested=0 2>/dev/null || true
    fi
}

display_student_instructions() {
    cat << "EOF"

==============================================================================
                LPIC-3 305: BREAK & FIX TROUBLESHOOTING SCENARIO
==============================================================================
SYSTEM ALERT: Domain 'lpic3-prod-db01' is failing to execute correctly under
production hypervisor policies. Operations reported severe startup errors,
loss of hardware acceleration, and potential storage corruption warnings.

YOUR MISSION:
Diagnose the full virtualization stack, root-cause all injected failures across
KVM kernel modules, device nodes, hypervisor Domain XML parameters, and storage
driver specifications. Restore the domain to a fully operational state under
hardware-accelerated (KVM) mode with valid virtio storage bindings.

OBSERVED SYMPTOMS:
1. Running `virsh start lpic3-prod-db01` fails or falls back to software (TCG)
   emulation mode with severe performance penalties.
2. System logs (journalctl / libvirt domain logs) report permission errors accessing
   hypervisor acceleration nodes.
3. The guest storage fails to boot or hangs during disk initialization due to
   storage driver image header parser errors.

DIAGNOSTIC GUIDELINES:
- Inspect /dev/kvm character device ownership and permissions.
- Validate KVM kernel module runtime parameters (`nested` virtualization state).
- Inspect `virsh dumpxml lpic3-prod-db01` for hypervisor type and storage driver declarations.
- Verify backing image formats using `qemu-img info`.

Do NOT destroy or re-create the domain manually without fixing the root cause!
==============================================================================
EOF
}

check_prerequisites
provision_lab_environment
inject_breakage
display_student_instructions

exit 0

# ==============================================================================
#                            SOLUTION & STEP-BY-STEP FIX
#                      (Do not read until attempting diagnosis!)
# ==============================================================================
#
# ROOT CAUSE ANALYSIS:
# 1. Device Node Permissions: /dev/kvm permissions were modified to 0600 root:root.
#    QEMU processes run under 'libvirt-qemu' or 'qemu' unprivileged user account,
#    preventing access to ioctl() interface of /dev/kvm for ioctl(KVM_CREATE_VM).
# 2. Domain XML Hypervisor Type Mismatch: The domain was configured with
#    <domain type='qemu'> instead of <domain type='kvm'>, enforcing TCG binary
#    translation mode instead of hardware-assisted virtualization.
# 3. Storage Driver Type Mismatch: The disk driver was defined as type='raw' in
#    the XML while the file on disk is formatted as qcow2. Parsing qcow2 metadata
#    as raw data leads to silent corruption or boot failure.
# 4. Nested Virtualization Disabled: KVM kernel module parameter `nested` was set
#    to 0/N, blocking L1 hypervisor pass-through capabilities to L2 guests.
#
# STEP-BY-STEP DIAGNOSIS & REPAIR PROCEDURE:
#
# Step 1: Diagnose /dev/kvm Permissions
# Command:
#   ls -la /dev/kvm
# Expected Broken Output:
#   crw------- 1 root root 10, 232 Aug 6 12:00 /dev/kvm
# Fix Command:
#   chmod 0666 /dev/kvm
#   chown root:kvm /dev/kvm
# Verify:
#   ls -la /dev/kvm
#   # Output should reflect: crw-rw----+ 1 root kvm 10, 232 /dev/kvm
#
# Step 2: Verify and Enable Nested Virtualization in Kernel Modules
# Command:
#   cat /sys/module/kvm_intel/parameters/nested  # or kvm_amd
# Expected Broken Output:
#   N (or 0)
# Fix Command:
#   modprobe -r kvm_intel
#   modprobe kvm_intel nested=1
#   echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-nested.conf
# Verify:
#   cat /sys/module/kvm_intel/parameters/nested
#   # Output: Y (or 1)
#
# Step 3: Inspect Storage Format Mismatch
# Command:
#   qemu-img info /var/lib/libvirt/images/lpic3-lab/lpic3-prod-db01.qcow2
# Expected Output:
#   file format: qcow2
# Command:
#   virsh dumpxml lpic3-prod-db01 | grep -E "(driver|domain type)"
# Expected Broken Output:
#   <domain type='qemu'>
#   <driver name='qemu' type='raw'/>
#
# Step 4: Fix Domain XML Configuration via virsh edit
# Command:
#   virsh edit lpic3-prod-db01
# Modifications required in the editor:
#   a) Change domain root tag:
#      From: <domain type='qemu'>
#      To:   <domain type='kvm'>
#   b) Change disk driver element:
#      From: <driver name='qemu' type='raw'/>
#      To:   <driver name='qemu' type='qcow2'/>
# Save and exit the editor.
#
# Step 5: Verify Domain Startup and Hypervisor Acceleration
# Command:
#   virsh start lpic3-prod-db01
# Expected Output:
#   Domain 'lpic3-prod-db01' started
#
# Command:
#   virsh qemu-monitor-command lpic3-prod-db01 --hmp "info kvm"
# Expected Output:
#   kvm support: enabled
#
# OFFICIAL DOCUMENTATION REFERENCES:
# - LPI 305-300 Exam Objectives: https://www.lpi.org/our-certifications/lpic-3-305-overview/
# - Libvirt Domain XML Format: https://libvirt.org/formatdomain.html#elementsDisks
# - QEMU Security & Permissions Architecture: https://www.qemu.org/docs/master/system/security.html
# ==============================================================================