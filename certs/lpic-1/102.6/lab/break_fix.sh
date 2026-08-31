#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (Exam 102-500) — Topic 102.6: Linux as a virtualization guest
#  Weight: 1.56
#
#  BREAK & FIX LAB — "The guest that lost its identity"
#
#  Reference: LPI Exam 102 Objectives
#             https://www.lpi.org/our-certifications/exam-102-objectives/
#             (Topic index: https://www.lpi.org/our-certifications/exam-101-objectives/)
#
#  WARNING — DISPOSABLE LAB VM ONLY
#  ---------------------------------
#  This script deliberately damages the cloud-init / machine-id / virtualization
#  guest configuration of the machine it runs on. It is designed for a THROWAWAY
#  virtual machine (a snapshot you can roll back). It will REFUSE to run on
#  bare metal and refuses to run unless you pass --i-am-in-a-disposable-vm.
#
#  Everything it touches is backed up under /root/breakfix-102.6/backup and can
#  be restored with:  bash "$0" --restore
# =============================================================================

set -o nounset
set -o pipefail

readonly LAB_ID="lpic1-102.6-virtualization-guest"
readonly LAB_ROOT="/root/breakfix-102.6"
readonly BACKUP_DIR="${LAB_ROOT}/backup"
readonly STATE_FILE="${LAB_ROOT}/state.env"
readonly BRIEF_FILE="${LAB_ROOT}/STUDENT_BRIEF.txt"

# --- Cosmetics ---------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m';    C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# =============================================================================
#  SECTION 0 — Safety interlocks
# =============================================================================

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This lab must run as root (try: sudo $0 --break --i-am-in-a-disposable-vm)"
}

# Detect the hypervisor the way the exam expects you to: systemd-detect-virt
# first, then the DMI product/vendor strings exposed through sysfs, then the
# CPU hypervisor feature flag. Any one of them is enough to prove we are a guest.
detect_virt() {
    local v=""

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v="$(systemd-detect-virt --vm 2>/dev/null || true)"
        [ "$v" = "none" ] && v=""
    fi

    if [ -z "$v" ] && [ -r /sys/class/dmi/id/product_name ]; then
        case "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" in
            *KVM*|*QEMU*)                 v="kvm"        ;;
            *VirtualBox*)                 v="oracle"     ;;
            *VMware*)                     v="vmware"     ;;
            *"Virtual Machine"*)          v="microsoft"  ;;
            *Bochs*)                      v="bochs"      ;;
        esac
    fi

    if [ -z "$v" ] && [ -r /sys/class/dmi/id/sys_vendor ]; then
        case "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" in
            *QEMU*|*"Red Hat"*)  v="kvm"       ;;
            *innotek*|*Oracle*)  v="oracle"    ;;
            *VMware*)            v="vmware"    ;;
            *Microsoft*)         v="microsoft" ;;
            *Xen*)               v="xen"       ;;
            *Amazon*)            v="amazon"    ;;
        esac
    fi

    # Xen PV guests advertise themselves here even without DMI.
    if [ -z "$v" ] && [ -d /proc/xen ]; then
        v="xen"
    fi

    # Last resort: the CPUID hypervisor bit. Present in every HVM guest.
    if [ -z "$v" ] && grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
        v="unknown-hypervisor"
    fi

    printf '%s' "$v"
}

require_disposable_vm() {
    local virt
    virt="$(detect_virt)"

    if [ -z "$virt" ]; then
        die "No hypervisor detected (systemd-detect-virt/DMI/CPUID all say bare metal).
    Refusing to break a physical machine. Run this inside a disposable guest."
    fi

    ok "Hypervisor detected: ${virt}"

    if [ "${CONFIRMED:-0}" != "1" ]; then
        die "Refusing to proceed without the explicit flag --i-am-in-a-disposable-vm.
    Take a snapshot of this VM FIRST, then re-run."
    fi
}

# =============================================================================
#  SECTION 1 — Backup helpers (so --restore is always possible)
# =============================================================================

backup_path() {
    # /etc/machine-id  ->  /root/breakfix-102.6/backup/etc/machine-id
    printf '%s%s' "$BACKUP_DIR" "$1"
}

save_file() {
    local src="$1" dst
    dst="$(backup_path "$src")"
    mkdir -p "$(dirname "$dst")"
    if [ -e "$src" ] || [ -L "$src" ]; then
        cp -a "$src" "$dst"
        printf 'EXISTED %s\n' "$src" >> "${BACKUP_DIR}/.manifest"
    else
        printf 'ABSENT  %s\n' "$src" >> "${BACKUP_DIR}/.manifest"
    fi
}

save_unit_state() {
    local unit="$1" enabled active
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || echo unknown)"
    active="$(systemctl is-active  "$unit" 2>/dev/null || echo unknown)"
    printf 'UNIT %s enabled=%s active=%s\n' "$unit" "$enabled" "$active" \
        >> "${BACKUP_DIR}/.manifest"
}

# =============================================================================
#  SECTION 2 — The breakage
#
#  Three faults, all classic 102.6 material, all recoverable with commands the
#  objective names. Nothing here touches the bootloader, the kernel, or the
#  root filesystem layout, so the VM always comes back up and stays reachable
#  on its console.
#
#   FAULT 1 — /etc/machine-id is cloned/zeroed.
#             This is exactly what happens when a VM template is duplicated
#             without being generalised. Consequences the student can observe:
#             journalctl loses its machine identity, systemd-networkd/
#             NetworkManager derive DHCP DUIDs from it (so clones fight over
#             the same lease), and D-Bus complains.
#
#   FAULT 2 — cloud-init is disabled AND its instance state is poisoned.
#             The guest stops consuming its datasource: no SSH key injection,
#             no hostname from metadata, no user-data on next boot.
#
#   FAULT 3 — The paravirtualised guest agent (qemu-guest-agent /
#             open-vm-tools / virtualbox-guest-utils / xe-guest-utilities)
#             is stopped and masked, so the hypervisor loses the ability to
#             freeze filesystems, read the guest IP, or trigger a clean
#             ACPI shutdown.
# =============================================================================

break_machine_id() {
    info "FAULT 1 — cloning /etc/machine-id (template-not-generalised scenario)"

    save_file /etc/machine-id
    save_file /var/lib/dbus/machine-id

    # A machine-id of all zeros is the documented "uninitialised" marker; a
    # *duplicated* one is worse in practice because nothing complains loudly.
    # We use a fixed, obviously-fake value so the student can recognise it.
    printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > /etc/machine-id
    chmod 0444 /etc/machine-id

    if [ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
        printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > /var/lib/dbus/machine-id
    fi

    ok "machine-id is now the same on every clone of this template."
}

break_cloud_init() {
    info "FAULT 2 — disabling cloud-init and poisoning its instance state"

    if ! command -v cloud-init >/dev/null 2>&1 && [ ! -d /var/lib/cloud ]; then
        warn "cloud-init is not installed here — planting the disable flag anyway"
        warn "so the student still finds /etc/cloud/cloud-init.disabled."
    fi

    mkdir -p /etc/cloud
    save_file /etc/cloud/cloud-init.disabled
    save_file /etc/cloud/cloud.cfg.d/99-lab-datasource.cfg
    save_file /var/lib/cloud/instance

    # The canonical kill switch: cloud-init's own generator checks for this file
    # and, when present, skips every stage on boot.
    : > /etc/cloud/cloud-init.disabled

    # Second, subtler fault: pin the datasource to NoCloud with an empty seed,
    # so even after the flag file is removed the guest finds no metadata.
    mkdir -p /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/99-lab-datasource.cfg <<'EOF'
# Installed by the LPIC-1 102.6 break&fix lab.
# Forces cloud-init to look only at a NoCloud seed that does not exist.
datasource_list: [ NoCloud ]
datasource:
  NoCloud:
    seedfrom: /var/lib/cloud/seed/nowhere/
EOF

    # Third: make the "instance" symlink dangle, which is what a half-copied
    # template looks like. cloud-init then thinks it already ran for an
    # instance-id it can no longer read.
    if [ -e /var/lib/cloud/instance ] || [ -L /var/lib/cloud/instance ]; then
        rm -f /var/lib/cloud/instance
        ln -s /var/lib/cloud/instances/i-0000000000000dead /var/lib/cloud/instance
    fi

    for u in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
        if systemctl list-unit-files "$u" >/dev/null 2>&1; then
            save_unit_state "$u"
        fi
    done

    ok "cloud-init will not run on the next boot, and would find no datasource if it did."
}

break_guest_agent() {
    info "FAULT 3 — stopping and masking the paravirtualised guest agent"

    local candidates=(
        qemu-guest-agent.service
        open-vm-tools.service
        vmtoolsd.service
        vboxadd-service.service
        virtualbox-guest-utils.service
        xe-linux-distribution.service
        walinuxagent.service
        amazon-ssm-agent.service
    )

    local found=0 u
    for u in "${candidates[@]}"; do
        if systemctl list-unit-files --no-legend "$u" 2>/dev/null | grep -q .; then
            found=1
            save_unit_state "$u"
            systemctl stop "$u"  >/dev/null 2>&1 || true
            systemctl mask "$u"  >/dev/null 2>&1 || true
            printf 'MASKED %s\n' "$u" >> "${BACKUP_DIR}/.manifest"
            ok "masked ${u}"
        fi
    done

    if [ "$found" -eq 0 ]; then
        warn "No guest agent unit present on this VM."
        warn "The student's job for FAULT 3 becomes: install the correct agent"
        warn "for the detected hypervisor and enable it."
        printf 'NOAGENT\n' >> "${BACKUP_DIR}/.manifest"
    fi
}

# =============================================================================
#  SECTION 3 — The student brief
# =============================================================================

write_brief() {
    local virt="$1"
    cat > "$BRIEF_FILE" <<EOF
=============================================================================
 LPIC-1 102.6 — BREAK & FIX: "The guest that lost its identity"
 Detected hypervisor: ${virt}
=============================================================================

SCENARIO
--------
Your team cloned a golden image to create this VM. The clone was taken from a
running machine that was never generalised, and somebody "cleaned up" the boot
by switching off things that looked noisy. The VM boots, you can log in on the
console — and everything else about it is wrong.

SYMPTOMS YOU WILL OBSERVE
-------------------------
 1. IDENTITY
      \$ cat /etc/machine-id
      deadbeefdeadbeefdeadbeefdeadbeef

    Every clone of this template reports the SAME id. Practical fallout:
      - 'hostnamectl' shows an identical "Machine ID" on all clones.
      - 'journalctl --list-boots' / remote log collectors merge the hosts.
      - DHCPv6 / systemd-networkd derive the client DUID and the default
        IAID from the machine-id, so two clones request the same lease and
        keep stealing the address from each other.
      - 'systemd-id128 machine-id' returns the cloned value too.

 2. NO METADATA / NO KEY INJECTION
      \$ cloud-init status --long
      status: disabled

      \$ systemctl status cloud-init.service
      ... Active: inactive (dead)

    The guest ignores the hypervisor's datasource entirely: the hostname from
    metadata is never applied, injected SSH keys never land in
    ~/.ssh/authorized_keys, and user-data is silently discarded. If you clear
    only the obvious flag and reboot, cloud-init still finds nothing, because
    a drop-in under /etc/cloud/cloud.cfg.d/ pins it to a seed that does not
    exist. Look for a dangling /var/lib/cloud/instance symlink as well.

 3. HYPERVISOR CANNOT TALK TO THE GUEST
      \$ systemctl status qemu-guest-agent    # or open-vm-tools / vboxadd-service
      ... Loaded: masked (Reason: Unit ... is masked.)

    From the host side: 'virsh domifaddr <vm> --source agent' returns nothing,
    'virsh shutdown' does not shut the guest down cleanly, and consistent
    (filesystem-frozen) snapshots are impossible. On VMware the vSphere client
    shows "VMware Tools: not running"; on VirtualBox shared folders and the
    additions-based clipboard stop working.

YOUR OBJECTIVE
--------------
Bring the guest back to a state where all of the following are TRUE, and be
able to explain WHY each command works:

  [ ] /etc/machine-id contains a unique, freshly generated 32-character
      lowercase hex ID, and /var/lib/dbus/machine-id agrees with it.
  [ ] 'hostnamectl' prints that new Machine ID.
  [ ] cloud-init is enabled, its datasource is auto-detected again (not pinned
      to a non-existent NoCloud seed), and 'cloud-init status --long' reports
      a real status instead of 'disabled'.
  [ ] /var/lib/cloud/instance points at a directory that actually exists, or
      the stale per-instance state has been cleared so the next boot is treated
      as a first boot.
  [ ] The guest agent for THIS hypervisor (${virt}) is unmasked, enabled and
      active, and survives a reboot.
  [ ] You can state which tool proved to you that this is a virtual machine,
      and name at least two independent sources of that evidence.

RULES
-----
  - Do NOT reinstall the OS and do NOT roll back the snapshot; fix it in place.
  - You may reboot as many times as you like.
  - Everything the lab modified is backed up under ${BACKUP_DIR}
    — treat that directory as the answer key you are NOT supposed to read.

CHECK YOUR WORK
---------------
      sudo bash $0 --verify

CONCEPTS UNDER TEST (LPI 102.6)
-------------------------------
  Terms: virtual machine, container, D-Bus machine id, cloud-init, user-data,
  Full Virtualization vs Paravirtualization, hypervisor guest drivers
  (virtio / vmw_pvscsi / vmxnet3 / xen-blkfront / hv_vmbus).
  Files: /etc/machine-id, /var/lib/dbus/machine-id, /etc/cloud/,
         /var/lib/cloud/, /sys/class/dmi/id/, /proc/cpuinfo.
  Tools: systemd-detect-virt, systemd-machine-id-setup, dbus-uuidgen,
         hostnamectl, dmidecode, lsmod, lspci, cloud-init.

Official objectives: https://www.lpi.org/our-certifications/exam-102-objectives/
=============================================================================
EOF
    chmod 0644 "$BRIEF_FILE"
}

# =============================================================================
#  SECTION 4 — Verification (what "fixed" means, mechanically)
# =============================================================================

verify() {
    local fails=0 mid

    say ""
    say "${C_BLU}== LPIC-1 102.6 break&fix — verification ==${C_RST}"
    say ""

    # --- Check 1: unique, well-formed machine-id ---------------------------
    mid="$(cat /etc/machine-id 2>/dev/null | tr -d '[:space:]')"
    if [ "$mid" = "deadbeefdeadbeefdeadbeefdeadbeef" ]; then
        warn "machine-id is still the cloned lab value."; fails=$((fails+1))
    elif [ -z "$mid" ]; then
        warn "/etc/machine-id is empty (systemd will generate a transient one at boot)."
        fails=$((fails+1))
    elif [ "$mid" = "00000000000000000000000000000000" ]; then
        warn "machine-id is all zeros — that is the 'uninitialised' marker, not a fix."
        fails=$((fails+1))
    elif ! printf '%s' "$mid" | grep -Eq '^[0-9a-f]{32}$'; then
        warn "machine-id is not 32 lowercase hex characters: '${mid}'"; fails=$((fails+1))
    else
        ok "machine-id is unique and well-formed: ${mid}"
    fi

    # --- Check 2: D-Bus id agrees ------------------------------------------
    if [ -e /var/lib/dbus/machine-id ]; then
        local dbid
        dbid="$(cat /var/lib/dbus/machine-id 2>/dev/null | tr -d '[:space:]')"
        if [ "$dbid" = "$mid" ]; then
            ok "/var/lib/dbus/machine-id matches /etc/machine-id"
        else
            warn "/var/lib/dbus/machine-id ('${dbid}') does not match /etc/machine-id"
            fails=$((fails+1))
        fi
    else
        ok "/var/lib/dbus/machine-id absent (D-Bus reads /etc/machine-id directly)"
    fi

    # --- Check 3: cloud-init re-enabled ------------------------------------
    if [ -e /etc/cloud/cloud-init.disabled ]; then
        warn "/etc/cloud/cloud-init.disabled still present — cloud-init is switched off."
        fails=$((fails+1))
    else
        ok "cloud-init kill switch removed"
    fi

    if [ -e /etc/cloud/cloud.cfg.d/99-lab-datasource.cfg ]; then
        warn "The lab drop-in 99-lab-datasource.cfg still pins a non-existent NoCloud seed."
        fails=$((fails+1))
    else
        ok "no bogus datasource drop-in under /etc/cloud/cloud.cfg.d/"
    fi

    if [ -L /var/lib/cloud/instance ] && [ ! -e /var/lib/cloud/instance ]; then
        warn "/var/lib/cloud/instance is a dangling symlink."
        fails=$((fails+1))
    else
        ok "/var/lib/cloud/instance is sane (resolved or cleared)"
    fi

    # --- Check 4: guest agent restored -------------------------------------
    local masked_units
    masked_units="$(grep -h '^MASKED ' "${BACKUP_DIR}/.manifest" 2>/dev/null | awk '{print $2}' | sort -u)"
    if [ -n "$masked_units" ]; then
        local u
        while read -r u; do
            [ -n "$u" ] || continue
            if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "masked" ]; then
                warn "${u} is still masked."; fails=$((fails+1))
            elif [ "$(systemctl is-active "$u" 2>/dev/null)" != "active" ]; then
                warn "${u} is unmasked but not running."; fails=$((fails+1))
            else
                ok "${u} is unmasked, enabled and active"
            fi
        done <<< "$masked_units"
    else
        if grep -q '^NOAGENT' "${BACKUP_DIR}/.manifest" 2>/dev/null; then
            warn "No agent was masked; install the agent for $(detect_virt) to complete the lab."
        fi
    fi

    say ""
    if [ "$fails" -eq 0 ]; then
        say "${C_GRN}ALL CHECKS PASSED — the guest has its identity back.${C_RST}"
        say "${C_DIM}Reboot once more and re-run --verify to prove the fix is persistent.${C_RST}"
        return 0
    fi
    say "${C_RED}${fails} check(s) still failing. Read ${BRIEF_FILE} again.${C_RST}"
    return 1
}

# =============================================================================
#  SECTION 5 — Restore (instructor escape hatch)
# =============================================================================

restore() {
    require_root
    [ -f "${BACKUP_DIR}/.manifest" ] || die "No lab backup found under ${BACKUP_DIR}"

    info "Restoring from ${BACKUP_DIR}"

    local kind path src
    while read -r kind path; do
        case "$kind" in
            EXISTED)
                src="$(backup_path "$path")"
                if [ -e "$src" ] || [ -L "$src" ]; then
                    mkdir -p "$(dirname "$path")"
                    chmod u+w "$path" 2>/dev/null || true
                    rm -rf "$path"
                    cp -a "$src" "$path"
                    ok "restored ${path}"
                fi
                ;;
            ABSENT)
                if [ -e "$path" ] || [ -L "$path" ]; then
                    rm -rf "$path"
                    ok "removed ${path} (did not exist before the lab)"
                fi
                ;;
            MASKED)
                systemctl unmask "$path" >/dev/null 2>&1 || true
                systemctl enable --now "$path" >/dev/null 2>&1 || true
                ok "unmasked and started ${path}"
                ;;
        esac
    done < "${BACKUP_DIR}/.manifest"

    ok "Restore complete. Run --verify to confirm."
}

# =============================================================================
#  SECTION 6 — Entry point
# =============================================================================

do_break() {
    require_root
    require_disposable_vm

    local virt
    virt="$(detect_virt)"

    mkdir -p "$BACKUP_DIR"
    : > "${BACKUP_DIR}/.manifest"

    {
        printf 'LAB_ID=%s\n' "$LAB_ID"
        printf 'HYPERVISOR=%s\n' "$virt"
        printf 'HOSTNAME=%s\n' "$(hostname)"
    } > "$STATE_FILE"

    say ""
    warn "Breaking this guest in 5 seconds. Ctrl-C now if you have no snapshot."
    sleep 5
    say ""

    break_machine_id
    break_cloud_init
    break_guest_agent

    write_brief "$virt"

    say ""
    say "${C_YEL}=====================================================================${C_RST}"
    cat "$BRIEF_FILE"
    say "${C_YEL}=====================================================================${C_RST}"
    say ""
    ok "Brief saved to ${BRIEF_FILE}"
    info "Reboot now to see the full effect:  systemctl reboot"
    info "Then check your work with:          sudo bash $0 --verify"
}

usage() {
    cat <<EOF
LPIC-1 102.6 — Linux as a virtualization guest — break & fix lab

Usage:
  sudo bash $0 --break --i-am-in-a-disposable-vm   Break the guest (DESTRUCTIVE)
  sudo bash $0 --verify                            Check the student's fix
  sudo bash $0 --restore                           Instructor rollback
  bash $0 --brief                                  Reprint the student brief
  bash $0 --help                                   This message
EOF
}

main() {
    local action=""
    CONFIRMED=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --break)                    action="break"   ;;
            --verify)                   action="verify"  ;;
            --restore)                  action="restore" ;;
            --brief)                    action="brief"   ;;
            --i-am-in-a-disposable-vm)  CONFIRMED=1      ;;
            -h|--help)                  usage; exit 0    ;;
            *)                          die "Unknown argument: $1 (try --help)" ;;
        esac
        shift
    done

    case "$action" in
        break)   do_break ;;
        verify)  verify   ;;
        restore) restore  ;;
        brief)   [ -f "$BRIEF_FILE" ] && cat "$BRIEF_FILE" || die "No brief yet — run --break first." ;;
        *)       usage; exit 1 ;;
    esac
}

main "$@"

# =============================================================================
# =============================================================================
##
##                      S O L U T I O N   —   DO NOT READ
##                      UNTIL YOU HAVE TRIED THE LAB
##
# =============================================================================
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Prove where you are. Never fix a guest without identifying the
#          hypervisor first: the correct agent, the correct drivers and the
#          correct datasource all depend on it.
# ---------------------------------------------------------------------------
#
#   $ systemd-detect-virt
#   kvm
#
#   $ systemd-detect-virt --vm ; systemd-detect-virt --container
#   kvm
#   none
#
#   Exit status matters: 0 means "virtualised", 1 means "bare metal". That is
#   what makes it scriptable:  systemd-detect-virt -q && echo "I am a guest"
#
#   Independent corroboration (the objective expects more than one source):
#
#   $ cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name
#   QEMU
#   Standard PC (Q35 + ICH9, 2009)
#
#   $ sudo dmidecode -s system-manufacturer ; sudo dmidecode -s system-product-name
#   QEMU
#   Standard PC (Q35 + ICH9, 2009)
#
#   $ grep -o -m1 hypervisor /proc/cpuinfo        # CPUID feature bit, HVM guests
#   hypervisor
#
#   $ lsmod | grep -E 'virtio|vmw|vbox|xen|hv_'
#   virtio_net             57344  0
#   virtio_blk             20480  3
#   virtio_pci             28672  0
#
#   Reading of those drivers, which is exam material:
#     virtio_*      -> KVM/QEMU paravirtualised devices (the fast path)
#     vmw_pvscsi, vmxnet3, vmwgfx -> VMware paravirtualised devices
#     xen-blkfront, xen-netfront  -> Xen PV front-end drivers (/proc/xen exists)
#     hv_vmbus, hv_netvsc, hv_storvsc -> Hyper-V / Azure integration services
#     vboxguest, vboxsf           -> VirtualBox Guest Additions
#   Full Virtualization emulates real hardware (e1000, IDE) and is slow;
#   Paravirtualization replaces it with a guest driver that talks to the
#   hypervisor over a ring buffer. Those drivers are why the guest is fast.
#
# ---------------------------------------------------------------------------
# STEP 1 — FAULT 1: give the machine a unique identity again.
# ---------------------------------------------------------------------------
#
#   Symptom recap: every clone reports deadbeef... as its machine-id, so
#   journald, D-Bus and DHCPv6 DUIDs collide across hosts.
#
#   The lab made the file read-only, so first restore write permission:
#
#   $ sudo chmod 0644 /etc/machine-id
#
#   The canonical, systemd-blessed procedure — truncate to empty, then let
#   systemd generate a new one:
#
#   $ sudo truncate -s 0 /etc/machine-id          # NOT 'rm': keep the inode/mount
#   $ sudo rm -f /var/lib/dbus/machine-id
#   $ sudo systemd-machine-id-setup
#   Initializing machine ID from random generator.
#
#   $ cat /etc/machine-id
#   9f3c1a7e5b2d4c86a0e1f7d3b95c4a20
#
#   Keep D-Bus in agreement. On modern distributions /var/lib/dbus/machine-id
#   is (or should be) a symlink to /etc/machine-id:
#
#   $ sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
#     # or, on systems where D-Bus owns its own copy:
#   $ sudo dbus-uuidgen --ensure=/var/lib/dbus/machine-id
#
#   Verify through the tool the exam names:
#
#   $ hostnamectl
#      Static hostname: lab-guest
#            Icon name: computer-vm
#              Chassis: vm
#           Machine ID: 9f3c1a7e5b2d4c86a0e1f7d3b95c4a20
#              Boot ID: 3d0c8e12f4a94b7f8c1d2e3f4a5b6c7d
#       Virtualization: kvm
#     Operating System: Debian GNU/Linux 12 (bookworm)
#
#   Note "Chassis: vm" and "Virtualization: kvm" — hostnamectl is a second,
#   independent confirmation that this is a guest.
#
#   Why this matters beyond cosmetics: the machine-id seeds
#   /etc/machine-id-derived application IDs (systemd-id128), the journal's
#   per-machine directory under /var/log/journal/<machine-id>/, and — the one
#   that bites in production — the DHCPv6 DUID-EN / IAID that systemd-networkd
#   computes, which is why two clones fight over one lease.
#
#   Related generalisation steps for a real template (not required by the
#   verifier, but state them out loud):
#     - remove /etc/ssh/ssh_host_*_key* and let them regenerate on first boot,
#       otherwise every clone shares the same host key fingerprint;
#     - clear persistent NIC naming rules and stale DHCP leases;
#     - clear the journal:  sudo journalctl --rotate && sudo journalctl --vacuum-time=1s
#
# ---------------------------------------------------------------------------
# STEP 2 — FAULT 2: make the guest consume its datasource again.
# ---------------------------------------------------------------------------
#
#   Symptom recap: 'cloud-init status --long' says "disabled"; no SSH key
#   injection, no hostname from metadata, no user-data.
#
#   2a. Remove the kill switch. cloud-init's systemd generator checks for this
#       exact path and, if present, disables all four stage units:
#
#   $ sudo rm -f /etc/cloud/cloud-init.disabled
#
#       (The other supported kill switch is the kernel command line argument
#        cloud-init=disabled — check /proc/cmdline if the flag file is absent.)
#
#   2b. Find and remove the bogus datasource pin. Configuration is merged from
#       /etc/cloud/cloud.cfg plus every *.cfg in /etc/cloud/cloud.cfg.d/, in
#       lexical order — a 99-* drop-in wins over everything:
#
#   $ ls -l /etc/cloud/cloud.cfg.d/
#   -rw-r--r-- 1 root root  31 Aug 26 10:12 05_logging.cfg
#   -rw-r--r-- 1 root root 214 Aug 26 10:12 99-lab-datasource.cfg
#
#   $ cat /etc/cloud/cloud.cfg.d/99-lab-datasource.cfg
#   datasource_list: [ NoCloud ]
#   datasource:
#     NoCloud:
#       seedfrom: /var/lib/cloud/seed/nowhere/
#
#   $ sudo rm -f /etc/cloud/cloud.cfg.d/99-lab-datasource.cfg
#
#       Sanity-check the merged result before rebooting:
#   $ sudo cloud-init schema --system   # validates the effective configuration
#
#   2c. Repair the per-instance state. /var/lib/cloud/instance is a symlink to
#       /var/lib/cloud/instances/<instance-id>/; when it dangles, cloud-init's
#       "have I already run for this instance?" logic is broken:
#
#   $ ls -l /var/lib/cloud/instance
#   lrwxrwxrwx 1 root root 44 Aug 26 10:12 /var/lib/cloud/instance -> \
#       /var/lib/cloud/instances/i-0000000000000dead
#
#       The clean fix is to declare this a first boot and let cloud-init
#       rebuild its state from the real datasource:
#
#   $ sudo cloud-init clean --logs
#         # removes /var/lib/cloud/instance*, /var/lib/cloud/sem/,
#         # and the cloud-init logs; the next boot runs every module again.
#
#       Add --seed only if you also want /var/lib/cloud/seed removed, and
#       --reboot if you want it to reboot immediately.
#
#   2d. Re-enable and re-run the four stage units, in their boot order:
#
#   $ sudo systemctl enable --now cloud-init-local.service \
#                                 cloud-init.service \
#                                 cloud-config.service \
#                                 cloud-final.service
#   $ sudo systemctl reboot
#
#       After the reboot:
#
#   $ cloud-init status --long
#   status: done
#   extended_status: done
#   boot_status_code: enabled-by-generator
#   last_update: Wed, 26 Aug 2026 10:31:07 +0000
#   detail: DataSourceNoCloud [seed=/dev/vdb][dsmode=net]
#
#   $ cloud-init query --all | head -n 12       # what the datasource gave us
#   $ sudo cloud-init analyze blame | head      # which module cost boot time
#
#       The four stages, and why the order is fixed (exam-relevant):
#         cloud-init-local  — before the network is up; finds a LOCAL datasource
#                             (NoCloud on a CIDATA volume, ConfigDrive) and can
#                             still configure networking.
#         cloud-init        — after networking; reaches the metadata service
#                             (EC2/OpenStack 169.254.169.254, Azure IMDS) and
#                             handles disks/filesystems/mounts.
#         cloud-config      — the cc_* modules: users, groups, ssh keys, ntp,
#                             package installs from user-data.
#         cloud-final       — runcmd, scripts-user, phone_home; the last thing
#                             before the boot is declared finished.
#
#       user-data vs meta-data vs vendor-data: meta-data is the platform's
#       facts (instance-id, hostname, public keys); user-data is what YOU
#       supplied (a #cloud-config YAML document or a #!/bin/sh script);
#       vendor-data is the provider's defaults, overridable by user-data.
#
# ---------------------------------------------------------------------------
# STEP 3 — FAULT 3: restore the paravirtualised guest agent.
# ---------------------------------------------------------------------------
#
#   Symptom recap: the unit is "masked", so the hypervisor cannot read the
#   guest IP, cannot quiesce the filesystems for a consistent snapshot, and
#   'virsh shutdown' has no clean path into the guest.
#
#   Find what is masked — masked units are symlinks to /dev/null:
#
#   $ systemctl list-unit-files --state=masked
#   UNIT FILE                  STATE   PRESET
#   qemu-guest-agent.service   masked  enabled
#
#   $ systemctl status qemu-guest-agent
#   ○ qemu-guest-agent.service
#        Loaded: masked (Reason: Unit qemu-guest-agent.service is masked.)
#        Active: inactive (dead)
#
#   Unmask, enable, start — 'unmask' alone is not enough, it only removes the
#   /dev/null symlink:
#
#   $ sudo systemctl unmask qemu-guest-agent.service
#   Removed "/etc/systemd/system/qemu-guest-agent.service".
#   $ sudo systemctl enable --now qemu-guest-agent.service
#   $ systemctl is-active qemu-guest-agent.service
#   active
#
#   If the package is missing entirely, install the agent that matches the
#   hypervisor you identified in STEP 0:
#
#     KVM/QEMU     apt install qemu-guest-agent      | dnf install qemu-guest-agent
#                  (talks over the virtio-serial channel
#                   org.qemu.guest_agent.0 — check: ls /dev/virtio-ports/)
#     VMware       apt install open-vm-tools         | dnf install open-vm-tools
#                  (service: vmtoolsd; verify with 'vmware-toolbox-cmd -v')
#     VirtualBox   apt install virtualbox-guest-utils
#     Xen          apt install xe-guest-utilities
#     Hyper-V      the hv_* modules are in-tree; ensure hv_kvp_daemon /
#                  hv_vss_daemon are enabled
#
#   Prove it from the HOST side, which is the only proof that counts:
#
#   host$ virsh qemu-agent-command lab-guest '{"execute":"guest-ping"}'
#   {"return":{}}
#   host$ virsh domifaddr lab-guest --source agent
#    Name       MAC address          Protocol     Address
#   -----------------------------------------------------------
#    enp1s0     52:54:00:9a:1b:2c    ipv4         192.168.122.87/24
#
#   That --source agent path is exactly what fails when the agent is masked:
#   'error: Guest agent is not responding: QEMU guest agent is not connected'.
#
# ---------------------------------------------------------------------------
# STEP 4 — Confirm, then confirm again after a reboot.
# ---------------------------------------------------------------------------
#
#   $ sudo bash breakfix-102.6.sh --verify
#   [+] machine-id is unique and well-formed: 9f3c1a7e5b2d4c86a0e1f7d3b95c4a20
#   [+] /var/lib/dbus/machine-id matches /etc/machine-id
#   [+] cloud-init kill switch removed
#   [+] no bogus datasource drop-in under /etc/cloud/cloud.cfg.d/
#   [+] /var/lib/cloud/instance is sane (resolved or cleared)
#   [+] qemu-guest-agent.service is unmasked, enabled and active
#
#   ALL CHECKS PASSED — the guest has its identity back.
#
#   $ sudo systemctl reboot && sudo bash breakfix-102.6.sh --verify
#
#   A fix that does not survive a reboot is not a fix. This is the single most
#   common mistake at this objective: 'systemctl start' without 'enable', or a
#   machine-id written by hand that systemd-machine-id-setup overwrites at the
#   next boot because /etc was mounted read-only when it ran.
#
# ---------------------------------------------------------------------------
# SOURCES
# ---------------------------------------------------------------------------
#   LPI Exam 102 objectives (102.6 Linux as a virtualization guest)
#     https://www.lpi.org/our-certifications/exam-102-objectives/
#   LPI certification index
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#   machine-id(5)
#     https://www.freedesktop.org/software/systemd/man/latest/machine-id.html
#   systemd-machine-id-setup(1)
#     https://www.freedesktop.org/software/systemd/man/latest/systemd-machine-id-setup.html
#   systemd-detect-virt(1)
#     https://www.freedesktop.org/software/systemd/man/latest/systemd-detect-virt.html
#   hostnamectl(1)
#     https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html
#   cloud-init — boot stages
#     https://cloudinit.readthedocs.io/en/latest/explanation/boot.html
#   cloud-init — datasources
#     https://cloudinit.readthedocs.io/en/latest/reference/datasources.html
#   cloud-init — CLI (status, clean, query, analyze, schema)
#     https://cloudinit.readthedocs.io/en/latest/reference/cli.html
#   QEMU guest agent
#     https://wiki.qemu.org/Features/GuestAgent
#   libvirt — domain XML, channels and the guest agent
#     https://libvirt.org/formatdomain.html#channel
#   open-vm-tools
#     https://github.com/vmware/open-vm-tools
#   Linux virtio drivers (kernel documentation)
#     https://docs.kernel.org/driver-api/virtio/virtio.html
# =============================================================================