#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-1 (LPI 101-500 / 102-500, syllabus version 5.0)
#  Topic 102.1 — Design hard disk layout   (exam weight: 3.13)
#  Reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#             https://www.lpi.org/our-certifications/exam-102-objectives/
#
#  BREAK & FIX LAB — controlled damage on a DISPOSABLE lab VM.
#
#  What this exercises, mapped to the objective's key knowledge areas:
#    * Allocate filesystems and swap space to separate partitions or disks
#    * Tailor the design to the intended use of the system
#    * Ensure the /boot partition conforms to the hardware architecture
#    * Knowledge of basic features of LVM
#    Terms: / , /var , /home , /boot , /boot/efi , swap , mount points,
#           partitions, PV/VG/LV, UUID, /etc/fstab
#
#  SAFETY MODEL — read this before running:
#    - Every byte written by this lab lives inside ONE sparse image file under
#      /var/tmp, exposed through a loop device. No real disk (/dev/sd*,
#      /dev/nvme*, /dev/vd*) is ever touched, opened or partitioned.
#    - The ONLY change outside that image is a clearly delimited block appended
#      to /etc/fstab, backed up first and removed by --cleanup.
#    - The lab fstab data entries carry `nofail` on purpose, so a reboot in the
#      middle of the exercise cannot wedge the VM into an emergency shell.
#      The swap entry deliberately does NOT: a failing swap unit is loud but
#      never fatal to boot, which is exactly the symptom we want you to see.
#    - Run it anyway ONLY on a VM you are willing to throw away.
#
#  USAGE:
#    sudo LPIC_LAB_CONFIRM=yes ./lpic1-102.1-break-and-fix.sh --setup
#    sudo ./lpic1-102.1-break-and-fix.sh --brief     # reprint the mission
#    sudo ./lpic1-102.1-break-and-fix.sh --status    # current state, no grading
#    sudo ./lpic1-102.1-break-and-fix.sh --verify    # grade your repair
#    sudo ./lpic1-102.1-break-and-fix.sh --reset     # re-break, keep the disk
#    sudo ./lpic1-102.1-break-and-fix.sh --cleanup   # remove every trace
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there first.
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

readonly LAB_ID="lpic1-102.1"
readonly LAB_DIR="/var/tmp/${LAB_ID}"
readonly IMG="${LAB_DIR}/disk.img"
readonly IMG_SIZE="3G"
readonly VG="lpiclab"
readonly MNT="/mnt/lpic-lab"
readonly FSTAB="/etc/fstab"
readonly FSTAB_BACKUP="${LAB_DIR}/fstab.pre-lab"
readonly MARK_START="# >>> ${LAB_ID} LAB >>>"
readonly MARK_END="# <<< ${LAB_ID} LAB <<<"
readonly SENTINEL_NAME="lab-sentinel.txt"
readonly PAYLOAD="${MNT}/var/lib/lab-payload.dat"
readonly PAYLOAD_SUM="${LAB_DIR}/payload.sha256"
readonly PAYLOAD_MB=200
readonly MIN_FREE_BYTES=$((200 * 1024 * 1024))   # 200 MiB free required on /var

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s[ lab ]%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()    { printf '%s[  ok ]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf '%s[warn ]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '%s[fail ]%s %s\n' "${C_RED}"    "${C_RESET}" "$*"; }
die()   { fail "$*"; exit 1; }
rule()  { printf '%s\n' "--------------------------------------------------------------------------"; }

trap 'rc=$?; [[ $rc -ne 0 ]] && fail "aborted at line ${LINENO} (exit ${rc})"; exit $rc' ERR

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "must run as root (partitioning, LVM and /etc/fstab)."
}

require_tools() {
    local missing=()
    local t
    for t in losetup parted partprobe udevadm blkid lsblk findmnt mountpoint \
             mkfs.ext4 mkfs.vfat mkswap swapon swapoff resize2fs sha256sum \
             pvcreate vgcreate lvcreate lvextend vgs lvs awk sed dd; do
        command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
    done
    if ((${#missing[@]})); then
        fail "missing required tools: ${missing[*]}"
        cat <<'HINT'
       Debian/Ubuntu : apt install -y util-linux parted lvm2 e2fsprogs dosfstools coreutils
       RHEL/Fedora   : dnf install -y util-linux parted lvm2 e2fsprogs dosfstools coreutils
       openSUSE      : zypper install -y util-linux parted lvm2 e2fsprogs dosfstools coreutils
HINT
        exit 1
    fi
}

require_confirmation() {
    local arg="${1:-}"
    if [[ "${LPIC_LAB_CONFIRM:-}" == "yes" || "${arg}" == "--yes-destroy-this-vm" ]]; then
        return 0
    fi
    cat <<EOF
${C_BOLD}Refusing to build the lab without an explicit confirmation.${C_RESET}

This script creates a loop-backed disk, an LVM volume group named '${VG}',
mount points under ${MNT}, and appends a marked block to ${FSTAB}.
It never writes to a physical disk, but it is still a destructive exercise.

Re-run it on a THROWAWAY VM as:

    sudo LPIC_LAB_CONFIRM=yes \$0 --setup
EOF
    exit 1
}

assert_safe_target() {
    # Belt and braces: nothing but a loop device may ever reach parted/pvcreate.
    local dev="$1"
    [[ "${dev}" == /dev/loop[0-9]* ]] \
        || die "internal safety check failed: '${dev}' is not a loop device. Nothing was changed."
}

check_free_space() {
    local avail
    avail=$(df -B1 --output=avail /var/tmp | tail -n1 | tr -d ' ')
    (( avail > 4 * 1024 * 1024 * 1024 )) \
        || die "/var/tmp needs at least 4 GiB free to host the ${IMG_SIZE} lab image."
}

# ------------------------------------------------------------------------------
# Loop device / fstab plumbing
# ------------------------------------------------------------------------------
loop_dev() {
    [[ -f "${IMG}" ]] || return 1
    losetup -j "${IMG}" 2>/dev/null | cut -d: -f1 | head -n1
}

lab_exists() { [[ -f "${IMG}" ]]; }

fstab_lineno() {
    # Print the 1-based line number of the first non-comment fstab entry whose
    # mount point (field 2) equals $1. Empty output means "not present".
    awk -v t="$1" '!/^[[:space:]]*#/ && NF>=2 && $2==t {print NR; exit}' "${FSTAB}"
}

fstab_field() {
    # $1 = mount point, $2 = field index -> value of that field
    awk -v t="$1" -v n="$2" '!/^[[:space:]]*#/ && NF>=2 && $2==t {print $n; exit}' "${FSTAB}"
}

fstab_swap_source() {
    awk '!/^[[:space:]]*#/ && NF>=3 && $3=="swap" && $1 ~ /LABSWAP|lpiclab|UUID=/ {print $1}' "${FSTAB}" \
        | head -n1
}

remove_fstab_block() {
    if grep -qF "${MARK_START}" "${FSTAB}"; then
        sed -i "\|${MARK_START}|,\|${MARK_END}|d" "${FSTAB}"
        ok "removed the lab block from ${FSTAB}"
    fi
}

# ------------------------------------------------------------------------------
# Build the lab disk: a realistic, deliberately opinionated layout
#
#   loopX      3 GiB   GPT
#     p1     260 MiB   vfat, esp flag   -> /boot/efi analogue
#     p2     512 MiB   ext4             -> /boot analogue  (OUTSIDE LVM, on purpose)
#     p3     rest      LVM PV           -> VG 'lpiclab'
#         lv_var    256M ext4  -> /var        (undersized on purpose)
#         lv_varlog 128M ext4  -> /var/log
#         lv_home   256M ext4  -> /home
#         lv_swap   256M swap
#         ~1.3 GiB of the VG is left FREE — you will need it.
# ------------------------------------------------------------------------------
build_disk() {
    info "creating backing image ${IMG} (${IMG_SIZE}, sparse)"
    mkdir -p "${LAB_DIR}"
    if ! fallocate -l "${IMG_SIZE}" "${IMG}" 2>/dev/null; then
        truncate -s "${IMG_SIZE}" "${IMG}"
    fi

    local loop
    loop=$(losetup --find --show --partscan "${IMG}")
    assert_safe_target "${loop}"
    ok "image attached to ${loop}"

    info "writing a GPT label and three partitions"
    parted -s "${loop}" mklabel gpt
    parted -s "${loop}" mkpart ESPLAB  fat32 1MiB    261MiB
    parted -s "${loop}" set 1 esp on
    parted -s "${loop}" mkpart BOOTLAB ext4  261MiB  773MiB
    parted -s "${loop}" mkpart PVLAB          773MiB 100%
    parted -s "${loop}" set 3 lvm on
    partprobe "${loop}"
    udevadm settle --timeout=15 || true

    local p1="${loop}p1" p2="${loop}p2" p3="${loop}p3"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -b "${p1}" && -b "${p2}" && -b "${p3}" ]] && break
        sleep 0.5
    done
    [[ -b "${p3}" ]] || die "partition nodes never appeared under ${loop}; is the loop module built with max_part support?"

    info "formatting the firmware/boot partitions"
    mkfs.vfat -F32 -n ESPLAB "${p1}" >/dev/null
    mkfs.ext4 -q -F -L BOOTLAB "${p2}"

    info "building the LVM stack on ${p3}"
    pvcreate -f -y "${p3}" >/dev/null
    vgcreate "${VG}" "${p3}" >/dev/null
    lvcreate -q -y -n lv_var    -L 256M "${VG}" >/dev/null
    lvcreate -q -y -n lv_varlog -L 128M "${VG}" >/dev/null
    lvcreate -q -y -n lv_home   -L 256M "${VG}" >/dev/null
    lvcreate -q -y -n lv_swap   -L 256M "${VG}" >/dev/null
    udevadm settle --timeout=15 || true

    # -m 0 removes the 5% root reserve so "100% full" really means 100% full.
    mkfs.ext4 -q -F -m 0 -L LABVAR    "/dev/${VG}/lv_var"
    mkfs.ext4 -q -F -m 0 -L LABVARLOG "/dev/${VG}/lv_varlog"
    mkfs.ext4 -q -F -m 0 -L LABHOME   "/dev/${VG}/lv_home"
    mkswap -L LABSWAP "/dev/${VG}/lv_swap" >/dev/null
    ok "layout created; $(vgs --noheadings -o vg_free "${VG}" | tr -d ' ') still free in VG ${VG}"
}

seed_log_volume() {
    # Put a marker file INSIDE lv_varlog while it is mounted somewhere neutral.
    # Once the volume is shadowed by a later mount, this file becomes invisible
    # without ever being deleted — that is the whole point of fault 3.
    local tmp="${LAB_DIR}/seed"
    mkdir -p "${tmp}"
    mount "/dev/${VG}/lv_varlog" "${tmp}"
    cat > "${tmp}/${SENTINEL_NAME}" <<EOF
${LAB_ID} sentinel
This file lives on /dev/${VG}/lv_varlog (label LABVARLOG).
If you cannot see it at ${MNT}/var/log/${SENTINEL_NAME}, the volume is
mounted but SHADOWED by a filesystem mounted over its parent directory.
EOF
    mkdir -p "${tmp}/journal"
    printf 'lab log volume, seeded at setup\n' > "${tmp}/journal/lab.log"
    sync
    umount "${tmp}"
    rmdir "${tmp}"
}

write_fstab_block() {
    local esp_uuid boot_uuid var_uuid log_uuid home_uuid stale_swap_uuid loop
    loop=$(loop_dev)
    esp_uuid=$(blkid -s UUID -o value "${loop}p1")
    boot_uuid=$(blkid -s UUID -o value "${loop}p2")
    var_uuid=$(blkid -s UUID -o value "/dev/${VG}/lv_var")
    log_uuid=$(blkid -s UUID -o value "/dev/${VG}/lv_varlog")
    home_uuid=$(blkid -s UUID -o value "/dev/${VG}/lv_home")
    stale_swap_uuid=$(blkid -s UUID -o value "/dev/${VG}/lv_swap")

    cp -a "${FSTAB}" "${FSTAB_BACKUP}"
    ok "backed up ${FSTAB} to ${FSTAB_BACKUP}"

    {
        printf '%s\n' "${MARK_START}"
        printf '%s\n' "# Disposable lab entries. Remove with: ${0} --cleanup"
        printf '%-46s %-26s %-6s %-42s %s\n' "UUID=${boot_uuid}" "${MNT}/boot"     "ext4" "defaults,nofail"                        "0 2"
        printf '%-46s %-26s %-6s %-42s %s\n' "UUID=${esp_uuid}"  "${MNT}/boot/efi" "vfat" "umask=0077,shortname=winnt,nofail"      "0 2"
        printf '%-46s %-26s %-6s %-42s %s\n' "UUID=${log_uuid}"  "${MNT}/var/log"  "ext4" "defaults,nofail"                        "0 2"
        printf '%-46s %-26s %-6s %-42s %s\n' "UUID=${var_uuid}"  "${MNT}/var"      "ext4" "defaults,nofail"                        "0 2"
        printf '%-46s %-26s %-6s %-42s %s\n' "UUID=${home_uuid}" "${MNT}/home"     "ext4" "defaults,nofail"                        "0 2"
        printf '%-46s %-26s %-6s %-42s %s\n' "UUID=${stale_swap_uuid}" "none"      "swap" "sw"                                     "0 0"
        printf '%s\n' "${MARK_END}"
    } >> "${FSTAB}"
    ok "appended the lab block to ${FSTAB}"
}

# ------------------------------------------------------------------------------
# The three faults
# ------------------------------------------------------------------------------
break_fault_1_stale_swap_uuid() {
    # Story: someone re-ran mkswap on the logical volume after /etc/fstab had
    # already been written. mkswap generates a NEW UUID every time, so the
    # fstab entry now points at a signature that no longer exists anywhere.
    info "FAULT 1: regenerating the swap signature so its UUID drifts from fstab"
    swapoff "/dev/${VG}/lv_swap" 2>/dev/null || true
    mkswap -f -L LABSWAP "/dev/${VG}/lv_swap" >/dev/null
    udevadm settle --timeout=10 || true
}

break_fault_2_undersized_var() {
    # Story: /var was sized for a toy workload. The application payload is
    # legitimate data that must survive; the junk is disposable — but deleting
    # the junk alone will NOT buy you the headroom the mission requires.
    info "FAULT 2: filling the undersized /var volume to 100%"
    mkdir -p "${MNT}/var"
    mount "/dev/${VG}/lv_var" "${MNT}/var"
    mkdir -p "${MNT}/var/lib" "${MNT}/var/tmp" "${MNT}/var/log"
    dd if=/dev/urandom of="${PAYLOAD}" bs=1M count="${PAYLOAD_MB}" status=none
    sha256sum "${PAYLOAD}" | awk '{print $1}' > "${PAYLOAD_SUM}"
    # Now consume every remaining block.
    dd if=/dev/zero of="${MNT}/var/tmp/junk.dat" bs=1M count=4096 status=none 2>/dev/null || true
    sync
    umount "${MNT}/var"
}

break_fault_3_shadowed_mount() {
    # Story: /etc/fstab lists /var/log BEFORE /var. `mount -a` walks the file
    # top to bottom, so the log volume is mounted onto a directory of the ROOT
    # filesystem, and the /var volume is then mounted on top of it. The log
    # volume is still mounted — and completely unreachable.
    info "FAULT 3: mounting ${MNT}/var/log first, then shadowing it with ${MNT}/var"
    mkdir -p "${MNT}/boot/efi" "${MNT}/home" "${MNT}/var/log"
    mount "/dev/${VG}/lv_varlog" "${MNT}/var/log"     # onto the rootfs directory
    mount "/dev/${VG}/lv_var"    "${MNT}/var"          # shadows the line above
    mount "/dev/${VG}/lv_home"   "${MNT}/home"
    local loop; loop=$(loop_dev)
    mount "${loop}p2" "${MNT}/boot"
    mount "${loop}p1" "${MNT}/boot/efi"
}

apply_breakage() {
    break_fault_1_stale_swap_uuid
    break_fault_2_undersized_var
    break_fault_3_shadowed_mount
    systemctl daemon-reload 2>/dev/null || true
}

unmount_lab() {
    swapoff "/dev/${VG}/lv_swap" 2>/dev/null || true
    # Deepest paths first; repeat because shadowed mounts only become visible
    # once whatever covers them has been detached.
    local pass target
    for pass in 1 2 3; do
        while read -r target; do
            [[ -n "${target}" ]] || continue
            umount "${target}" 2>/dev/null || true
        done < <(findmnt -rno TARGET | grep -E "^${MNT}(/|$)" | sort -r)
    done
    ! findmnt -rno TARGET | grep -qE "^${MNT}(/|$)"
}

# ------------------------------------------------------------------------------
# The mission brief
# ------------------------------------------------------------------------------
print_brief() {
    rule
    printf '%s\n' "${C_BOLD} LPIC-1 102.1 — Design hard disk layout — BREAK & FIX${C_RESET}"
    rule
    cat <<EOF

 A colleague handed you a machine whose storage layout was "designed" in a
 hurry. Nothing is on fire, everything looks green in a casual glance, and the
 application is already losing data. Three separate design mistakes are live at
 the same time. Your job is to find and repair all three WITHOUT reinstalling,
 WITHOUT recreating a filesystem, and WITHOUT losing the payload file.

 The whole system under test lives under ${MNT} on the volume group '${VG}'.

 ${C_BOLD}SYMPTOM 1 — the swap you configured is not there${C_RESET}
   'free -h' reports 0B of swap even though a swap logical volume exists and
   /etc/fstab has a swap line. 'swapon -a' complains, and systemd shows a
   failed .swap unit:

       \$ free -h
                      total        used        free      shared  buff/cache
       Mem:           1.9Gi       310Mi       1.2Gi       0.0Ki       400Mi
       Swap:             0B          0B          0B
       \$ swapon -a
       swapon: cannot find the device for UUID=1f0c9a2e-....
       \$ systemctl --failed
       UNIT              LOAD   ACTIVE SUB    DESCRIPTION
       dev-disk-by\\x2duuid-1f0c...swap loaded failed failed

   GOAL: swap from /dev/${VG}/lv_swap is active, and it comes back after a
   reboot — i.e. /etc/fstab is correct, not just a hand-typed 'swapon'.

 ${C_BOLD}SYMPTOM 2 — ${MNT}/var is 100% full${C_RESET}
   Any write into it fails with ENOSPC:

       \$ df -h ${MNT}/var
       Filesystem                  Size  Used Avail Use% Mounted on
       /dev/mapper/${VG}-lv_var    233M  233M     0 100% ${MNT}/var
       \$ touch ${MNT}/var/lib/new
       touch: cannot touch '${MNT}/var/lib/new': No space left on device

   GOAL: at least 200 MiB free on ${MNT}/var, with
   ${PAYLOAD} byte-for-byte intact (its sha256 was recorded at setup).
   Deleting the junk file alone will not get you there — the volume is simply
   too small. This is what LVM is for.

 ${C_BOLD}SYMPTOM 3 — the log volume is mounted, and its data is gone${C_RESET}
   'lsblk' and 'findmnt' both show /dev/${VG}/lv_varlog mounted at
   ${MNT}/var/log, yet the directory is empty and every byte written to it
   actually lands on the /var filesystem:

       \$ findmnt -rno SOURCE,TARGET | grep lab
       /dev/mapper/${VG}-lv_varlog  ${MNT}/var/log
       /dev/mapper/${VG}-lv_var     ${MNT}/var
       \$ ls ${MNT}/var/log
       (empty — the seeded ${SENTINEL_NAME} is nowhere to be found)
       \$ mountpoint ${MNT}/var/log
       ${MNT}/var/log is not a mountpoint

   GOAL: ${MNT}/var/log is a real mount point again, ${SENTINEL_NAME} is
   readable there, and the ordering is fixed in /etc/fstab so 'mount -a'
   reproduces the correct tree instead of the broken one.

 ${C_BOLD}DESIGN QUESTIONS to answer out loud while you work${C_RESET}
   1. Why is /boot a plain partition here instead of a logical volume?
   2. Why must the ESP (${MNT}/boot/efi) be FAT32, and what decides whether a
      machine needs one at all?
   3. Why does isolating /var onto its own volume matter on a server that
      writes logs, mail spools and container images?
   4. Why is 'UUID=' preferred over '/dev/sdb2' in fstab — and why is
      '/dev/${VG}/lv_swap' an acceptable exception?

 ${C_BOLD}USEFUL RECON${C_RESET}
   lsblk -f
   findmnt -R ${MNT}
   df -hT ${MNT}/var ${MNT}/var/log ${MNT}/home
   free -h ; swapon --show
   pvs ; vgs ; lvs -o +lv_path
   blkid /dev/${VG}/lv_swap
   grep -n ${MNT} /etc/fstab
   systemctl --failed ; journalctl -b -p err

 When you think you are done:   sudo ${0} --verify
 To start over from scratch:    sudo ${0} --reset
 To erase the lab entirely:     sudo ${0} --cleanup

EOF
    rule
}

# ------------------------------------------------------------------------------
# Status (informational, ungraded)
# ------------------------------------------------------------------------------
show_status() {
    lab_exists || die "no lab found. Run --setup first."
    rule
    info "loop device : $(loop_dev || echo '(detached)')"
    rule
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$(loop_dev)" 2>/dev/null || true
    rule
    findmnt -R "${MNT}" 2>/dev/null || warn "nothing mounted under ${MNT}"
    rule
    vgs "${VG}" 2>/dev/null || true
    lvs -o lv_name,lv_size,lv_path "${VG}" 2>/dev/null || true
    rule
    swapon --show || warn "no swap active at all"
    rule
    grep -n "${MNT}\|swap" "${FSTAB}" | sed -n '1,40p' || true
    rule
}

# ------------------------------------------------------------------------------
# Grading
# ------------------------------------------------------------------------------
PASS=0
CHECK=0
check_pass() { CHECK=$((CHECK+1)); PASS=$((PASS+1)); ok "$*"; }
check_fail() { CHECK=$((CHECK+1)); fail "$*"; }

verify_swap() {
    local lv="/dev/${VG}/lv_swap" real active found=0 line src cur_uuid
    real=$(readlink -f "${lv}")

    while read -r line; do
        [[ -n "${line}" ]] || continue
        active=$(readlink -f "${line}" 2>/dev/null || echo "${line}")
        [[ "${active}" == "${real}" ]] && found=1
    done < <(swapon --show=NAME --noheadings --raw 2>/dev/null || true)

    if (( found )); then
        check_pass "swap is active on ${lv}"
    else
        check_fail "swap from ${lv} is NOT active ('swapon --show' does not list it)"
    fi

    cur_uuid=$(blkid -s UUID -o value "${lv}" 2>/dev/null || echo "")
    src=$(fstab_swap_source)
    if [[ -z "${src}" ]]; then
        check_fail "no swap entry for the lab volume found in ${FSTAB} — the fix would not survive a reboot"
    elif [[ "${src}" == "UUID=${cur_uuid}" ]]; then
        check_pass "${FSTAB} references the CURRENT swap UUID (${cur_uuid})"
    elif [[ "$(readlink -f "${src#UUID=}" 2>/dev/null || echo "${src}")" == "${real}" ]]; then
        check_pass "${FSTAB} references the swap LV by device path (${src}) — stable for LVM, though UUID= is the house style"
    else
        check_fail "${FSTAB} still points at '${src}'; the live signature is UUID=${cur_uuid}"
    fi
}

verify_var_capacity() {
    local avail size want_sum have_sum
    if ! mountpoint -q "${MNT}/var"; then
        check_fail "${MNT}/var is not mounted at all"
        return
    fi
    avail=$(df -B1 --output=avail "${MNT}/var" | tail -n1 | tr -d ' ')
    size=$(df -B1 --output=size "${MNT}/var" | tail -n1 | tr -d ' ')
    if (( avail >= MIN_FREE_BYTES )); then
        check_pass "${MNT}/var has $((avail/1024/1024)) MiB free on a $((size/1024/1024)) MiB filesystem (>= 200 MiB required)"
    else
        check_fail "${MNT}/var has only $((avail/1024/1024)) MiB free; 200 MiB required. Grow the LV and then the filesystem."
    fi

    if [[ ! -f "${PAYLOAD}" ]]; then
        check_fail "the payload ${PAYLOAD} is GONE — freeing space by deleting production data is not a fix"
        return
    fi
    want_sum=$(cat "${PAYLOAD_SUM}")
    have_sum=$(sha256sum "${PAYLOAD}" | awk '{print $1}')
    if [[ "${want_sum}" == "${have_sum}" ]]; then
        check_pass "payload intact (sha256 matches the value recorded at setup)"
    else
        check_fail "payload checksum mismatch — the file was truncated or rewritten"
    fi
}

verify_mount_order() {
    local src want var_ln log_ln
    want=$(readlink -f "/dev/${VG}/lv_varlog")

    if mountpoint -q "${MNT}/var/log"; then
        src=$(readlink -f "$(findmnt -nro SOURCE "${MNT}/var/log")")
        if [[ "${src}" == "${want}" ]]; then
            check_pass "${MNT}/var/log is a real, reachable mount point backed by lv_varlog"
        else
            check_fail "${MNT}/var/log is a mount point but is backed by ${src}, not lv_varlog"
        fi
    else
        check_fail "${MNT}/var/log is NOT a mount point (mountpoint compares st_dev with its parent — a shadowed mount fails here)"
    fi

    if [[ -f "${MNT}/var/log/${SENTINEL_NAME}" ]]; then
        check_pass "${SENTINEL_NAME} is readable — the log volume's data is reachable again"
    else
        check_fail "${SENTINEL_NAME} is still invisible under ${MNT}/var/log"
    fi

    var_ln=$(fstab_lineno "${MNT}/var")
    log_ln=$(fstab_lineno "${MNT}/var/log")
    if [[ -z "${var_ln}" || -z "${log_ln}" ]]; then
        check_fail "one of the ${MNT}/var or ${MNT}/var/log entries is missing from ${FSTAB}"
    elif (( var_ln < log_ln )); then
        check_pass "${FSTAB} lists ${MNT}/var (line ${var_ln}) before ${MNT}/var/log (line ${log_ln})"
    else
        check_fail "${FSTAB} still lists ${MNT}/var/log (line ${log_ln}) before its parent ${MNT}/var (line ${var_ln}) — 'mount -a' will re-break it"
    fi
}

run_verify() {
    lab_exists || die "no lab found. Run --setup first."
    PASS=0; CHECK=0
    rule
    printf '%s\n' "${C_BOLD} Grading ${LAB_ID}${C_RESET}"
    rule
    info "Fault 1 — swap space"      ; verify_swap
    rule
    info "Fault 2 — /var capacity"   ; verify_var_capacity
    rule
    info "Fault 3 — mount ordering"  ; verify_mount_order
    rule
    if (( PASS == CHECK )); then
        ok "${PASS}/${CHECK} checks passed. Layout repaired."
        cat <<EOF

 Last thing a real operator does: prove it survives a boot.

     sudo umount -R ${MNT} && sudo swapoff -a
     sudo systemctl daemon-reload
     sudo mount -a && sudo swapon -a
     findmnt -R ${MNT} ; free -h

 If that reproduces the correct tree, the design is genuinely fixed and not
 just hand-patched in memory. Then: sudo ${0} --cleanup
EOF
        rule
        return 0
    fi
    fail "${PASS}/${CHECK} checks passed. Keep going — 'sudo ${0} --brief' reprints the mission."
    rule
    return 1
}

# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------
do_setup() {
    require_confirmation "${1:-}"
    if lab_exists; then
        die "a lab already exists at ${IMG}. Use --reset to re-break it, or --cleanup to remove it."
    fi
    if vgs "${VG}" >/dev/null 2>&1; then
        die "a volume group named '${VG}' already exists on this system. Refusing to touch it."
    fi
    check_free_space
    build_disk
    seed_log_volume
    write_fstab_block
    apply_breakage
    ok "lab is live and broken by design."
    print_brief
}

do_reset() {
    lab_exists || die "no lab found. Run --setup first."
    info "resetting: unmounting, wiping lab filesystems, re-applying the three faults"
    unmount_lab || warn "some lab mounts refused to detach; close any shells sitting inside ${MNT}"
    mkfs.ext4 -q -F -m 0 -L LABVAR    "/dev/${VG}/lv_var"
    mkfs.ext4 -q -F -m 0 -L LABVARLOG "/dev/${VG}/lv_varlog"
    mkfs.ext4 -q -F -m 0 -L LABHOME   "/dev/${VG}/lv_home"
    mkswap -L LABSWAP "/dev/${VG}/lv_swap" >/dev/null
    remove_fstab_block
    seed_log_volume
    write_fstab_block
    apply_breakage
    ok "lab reset."
    print_brief
}

do_cleanup() {
    info "tearing the lab down"
    unmount_lab || warn "some lab mounts refused to detach; close any shells sitting inside ${MNT}"
    remove_fstab_block
    systemctl daemon-reload 2>/dev/null || true

    if vgs "${VG}" >/dev/null 2>&1; then
        vgchange -an "${VG}" >/dev/null 2>&1 || true
        vgremove -f -y "${VG}" >/dev/null 2>&1 || true
        ok "volume group ${VG} removed"
    fi

    local loop
    loop=$(loop_dev || true)
    if [[ -n "${loop}" ]]; then
        assert_safe_target "${loop}"
        pvremove -f -y "${loop}p3" >/dev/null 2>&1 || true
        losetup -d "${loop}" || warn "could not detach ${loop}; something still holds it"
        ok "detached ${loop}"
    fi

    rm -f "${IMG}" "${PAYLOAD_SUM}"
    rmdir "${MNT}/boot/efi" "${MNT}/boot" "${MNT}/var/log" "${MNT}/var" "${MNT}/home" "${MNT}" 2>/dev/null || true
    ok "lab removed. Your pre-lab ${FSTAB} copy is kept at ${FSTAB_BACKUP}"
}

usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    require_root
    require_tools
    case "${1:---setup}" in
        --setup)   do_setup "${2:-}" ;;
        --brief)   print_brief ;;
        --status)  show_status ;;
        --verify)  run_verify ;;
        --reset)   do_reset ;;
        --cleanup) do_cleanup ;;
        -h|--help) usage ;;
        *)         die "unknown option '$1'. Try --help." ;;
    esac
}

main "$@"
exit 0

# ==============================================================================
#  S O L U T I O N  —  do not read until you have tried it yourself
# ==============================================================================
#
# ------------------------------------------------------------------------------
# STEP 0 — Recon before touching anything
# ------------------------------------------------------------------------------
#   lsblk -f                                  # tree, filesystems, labels, UUIDs
#   findmnt -R /mnt/lpic-lab                  # the mount TREE, not just a list
#   findmnt -rno SOURCE,TARGET,FSTYPE | grep lpiclab
#   df -hT /mnt/lpic-lab/var /mnt/lpic-lab/var/log
#   free -h ; swapon --show
#   pvs ; vgs ; lvs -o +lv_path
#   grep -n lpic-lab /etc/fstab
#   systemctl --failed
#   journalctl -b -p err --no-pager | tail -30
#
#   Read the fstab block top to bottom. `mount -a` is a sequential walk of that
#   file: an entry whose parent directory is mounted LATER is a design bug, not
#   a runtime accident.
#
# ------------------------------------------------------------------------------
# STEP 1 — Fault 1: the swap UUID drifted
# ------------------------------------------------------------------------------
#   Read the truth from the device, not from fstab:
#
#     blkid /dev/lpiclab/lv_swap
#     # /dev/lpiclab/lv_swap: LABEL="LABSWAP" UUID="b3d1..." TYPE="swap"
#
#   Compare with what fstab claims:
#
#     grep -n swap /etc/fstab
#
#   They differ, because mkswap was re-run after fstab was written and mkswap
#   mints a fresh UUID every single time. Repair fstab in place:
#
#     NEW=$(blkid -s UUID -o value /dev/lpiclab/lv_swap)
#     sed -i "s|^UUID=[0-9a-f-]\+\(\s\+none\s\+swap\)|UUID=${NEW}\1|" /etc/fstab
#     # or just edit it with vi — the point is that the value comes from blkid
#
#   Tell systemd the file changed, then activate:
#
#     systemctl daemon-reload
#     swapon -a
#     swapon --show
#     # NAME                     TYPE      SIZE USED PRIO
#     # /dev/dm-3                partition 256M   0B   -2
#     free -h        # Swap: now 256Mi
#
#   Also legitimate for LVM: replace the UUID with the stable device-mapper
#   path 'UUID=' -> '/dev/lpiclab/lv_swap'. LVM names are stable across reboots
#   in a way '/dev/sdb2' is not, which is exactly why the UUID rule exists.
#   Reference: mkswap(8), swapon(8), fstab(5), blkid(8).
#
# ------------------------------------------------------------------------------
# STEP 2 — Fault 2: /var was designed too small
# ------------------------------------------------------------------------------
#   Confirm the diagnosis first — full filesystem, or exhausted inodes?
#
#     df -h  /mnt/lpic-lab/var      # blocks
#     df -ih /mnt/lpic-lab/var      # inodes  (a classic /var failure mode too)
#     du -xh --max-depth=2 /mnt/lpic-lab/var | sort -h | tail
#
#   The junk file is disposable; the payload is not. Reclaim the junk, but note
#   that alone still leaves you short of the 200 MiB target — a 256 MiB volume
#   holding a 200 MiB payload cannot be made to fit. Grow the volume:
#
#     vgs                                  # confirm the VG has free extents
#     #   VG       #PV #LV #SN Attr   VSize  VFree
#     #   lpiclab    1   4   0 wz--n- <2.20g <1.31g
#
#     rm -f /mnt/lpic-lab/var/tmp/junk.dat
#     lvextend -L +512M /dev/lpiclab/lv_var        # or: -l +50%FREE
#     resize2fs /dev/lpiclab/lv_var                # ext4 grows ONLINE, mounted
#
#   One-shot equivalent (does both, and is what you should use in production):
#
#     lvextend -r -L +512M /dev/lpiclab/lv_var
#
#   Verify:
#
#     df -h /mnt/lpic-lab/var
#     # /dev/mapper/lpiclab-lv_var  740M  201M  539M  28% /mnt/lpic-lab/var
#     sha256sum /mnt/lpic-lab/var/lib/lab-payload.dat
#     cat /var/tmp/lpic1-102.1/payload.sha256
#
#   Notes worth internalising:
#     * ext4 and XFS grow online; ext4 can also SHRINK, but only unmounted, and
#       XFS cannot shrink at all. That asymmetry is a layout-design decision:
#       start small, grow on demand.
#     * 'lvextend -l +100%FREE' consumes the whole VG and leaves you no room for
#       snapshots or for the next emergency. Leaving free extents in the VG is
#       deliberate capacity planning, not waste.
#     * The reason /var is a separate volume at all is precisely this: runaway
#       logs, mail spools or container images fill /var, not /, so the system
#       stays bootable and repairable.
#     Reference: lvextend(8), resize2fs(8), lvm(8).
#
# ------------------------------------------------------------------------------
# STEP 3 — Fault 3: a shadowed mount caused by fstab ordering
# ------------------------------------------------------------------------------
#   Prove the shadowing rather than guessing:
#
#     mountpoint /mnt/lpic-lab/var/log
#     # /mnt/lpic-lab/var/log is not a mountpoint      <- yet findmnt lists it
#     findmnt -rno SOURCE,TARGET | grep lpiclab
#     stat -c '%D %n' /mnt/lpic-lab/var /mnt/lpic-lab/var/log
#     # identical device IDs => /var/log is just a directory inside /var
#
#   The log volume was mounted onto the rootfs directory /mnt/lpic-lab/var/log,
#   and then /mnt/lpic-lab/var was mounted over the top of it. The data was
#   never deleted — it is unreachable.
#
#   Unwind in the right order (detach the coverer first, then the covered):
#
#     umount /mnt/lpic-lab/var        # this REVEALS the log mount underneath
#     mountpoint /mnt/lpic-lab/var/log   # now it IS a mount point
#     umount /mnt/lpic-lab/var/log
#
#     # or, in one go, since umount -R walks the real mount table:
#     umount -R /mnt/lpic-lab/var
#
#   Fix the CAUSE in /etc/fstab: the parent must be listed before the child.
#   Move the /mnt/lpic-lab/var line above the /mnt/lpic-lab/var/log line, so
#   the block reads:
#
#     UUID=<boot>  /mnt/lpic-lab/boot      ext4  defaults,nofail                   0 2
#     UUID=<esp>   /mnt/lpic-lab/boot/efi  vfat  umask=0077,shortname=winnt,nofail 0 2
#     UUID=<var>   /mnt/lpic-lab/var       ext4  defaults,nofail                   0 2
#     UUID=<log>   /mnt/lpic-lab/var/log   ext4  defaults,nofail                   0 2
#     UUID=<home>  /mnt/lpic-lab/home      ext4  defaults,nofail                   0 2
#
#   Then remount from the file, which is the only remount that proves anything:
#
#     systemctl daemon-reload
#     mount -a
#     findmnt -R /mnt/lpic-lab
#     ls -l /mnt/lpic-lab/var/log/lab-sentinel.txt     # the data is back
#
#   Production nuance you should be able to state: systemd's fstab generator
#   emits RequiresMountsFor= / After= dependencies derived from the PATHS, so on
#   a systemd boot the ordering would be corrected automatically even with a
#   badly ordered fstab. Plain `mount -a`, rescue shells, initramfs scripts,
#   containers and non-systemd inits have no such safety net — which is why the
#   file must be correct on its own terms. Reference: fstab(5),
#   systemd-fstab-generator(8), mount(8) ("over-mounting"/shadowed mounts).
#
# ------------------------------------------------------------------------------
# STEP 4 — Prove it survives a boot
# ------------------------------------------------------------------------------
#     sudo ./lpic1-102.1-break-and-fix.sh --verify
#     umount -R /mnt/lpic-lab ; swapoff -a
#     systemctl daemon-reload ; mount -a ; swapon -a
#     findmnt -R /mnt/lpic-lab ; free -h ; df -h /mnt/lpic-lab/var
#     # or simply: reboot
#
#   A layout fix that only exists in the running kernel's mount table is not a
#   fix. `mount -a` from a cold state is the acceptance test.
#
# ------------------------------------------------------------------------------
# ANSWERS to the design questions
# ------------------------------------------------------------------------------
#  1. /boot is a plain partition because the bootloader must read the kernel and
#     initramfs before the system can assemble LVM. GRUB2 can read LVM, but only
#     for simple linear volumes; RAID levels, thin pools, cache and many
#     encryption layers are out of reach, and firmware is out of reach entirely.
#     A plain ext4 /boot removes an entire class of unbootable systems. Size it
#     with kernel retention in mind: distributions keep 3-5 kernels, each kernel
#     plus initramfs runs 60-150 MiB, so 512 MiB-1 GiB is the modern floor and
#     "/boot is full during dnf/apt upgrade" is a layout bug, not bad luck.
#
#  2. The EFI System Partition must be FAT (FAT32 in practice) because the UEFI
#     specification requires firmware to implement exactly that filesystem — the
#     firmware, not Linux, reads it. It needs the GPT 'esp' flag (GUID
#     C12A7328-F81F-11D2-BA4B-00A0C93EC93B), is mounted at /boot/efi (or /efi on
#     some distributions), and 260 MiB is the practical minimum because FAT32
#     itself has a floor. Whether you need one at all is decided by the firmware
#     mode: check `ls /sys/firmware/efi` — if that directory exists you booted
#     UEFI and you need an ESP; a legacy BIOS/MBR machine instead needs the
#     bootloader in the MBR gap, or a ~1 MiB BIOS boot partition (ef02) when the
#     disk is GPT. On other architectures the answer changes again: PowerPC PReP
#     needs a 'prep' partition, some ARM boards need a raw offset region.
#
#  3. /var is where the system writes without asking permission: logs, mail
#     spools, print queues, package caches, databases, container image layers.
#     If it shares a filesystem with /, one runaway process makes the machine
#     unloggable-into, unrepairable and often unbootable — you cannot even write
#     the log entry explaining why. On its own volume the damage is bounded to
#     one service, `df` names the culprit immediately, and (as in step 2) LVM
#     lets you grow it online without downtime. The same argument applies to
#     /home on multi-user machines and to /tmp, which is why /tmp is frequently
#     a tmpfs. It also lets you mount with intent: nodev,nosuid on /var and
#     /home, and noexec where the workload allows it.
#
#  4. Kernel device names are enumeration-order artefacts: add a disk, change a
#     controller, boot with a different driver load order, and /dev/sdb2 is now
#     someone else. A UUID or LABEL is written into the filesystem superblock
#     and travels with the data, so fstab keeps meaning what you meant. LVM
#     paths (/dev/<vg>/<lv>, /dev/mapper/<vg>-<lv>) are the acceptable exception
#     because they are not enumeration-order names at all — they are derived
#     from metadata stored on the PV and are as stable as a UUID, with the added
#     benefit of being readable in an emergency. Never use bare /dev/sd*
#     anywhere in fstab or in a bootloader command line.
#
# ------------------------------------------------------------------------------
# SIZING RULES OF THUMB the exam expects you to reason about
# ------------------------------------------------------------------------------
#   /boot      512 MiB - 1 GiB, plain partition, outside LVM
#   /boot/efi  260 MiB - 512 MiB, FAT32, esp flag, UEFI systems only
#   /          15-30 GiB for a server, more if you keep /var and /usr inside it
#   /var       sized for the workload: a log-heavy or container host wants tens
#              of GiB; consider a separate /var/log and /var/lib/containers
#   /home      whatever the users need — its own volume so quotas and reinstalls
#              are independent of the OS
#   swap       hibernation requires >= RAM; without hibernation, modern guidance
#              is a few GiB regardless of RAM size, and swap on a logical volume
#              (or a swapfile) so it can be resized later. Swap is not a
#              substitute for RAM; it is pressure relief and a place for cold
#              anonymous pages.
#   Leave free extents in the VG. A VG at 100% allocation cannot take a snapshot
#   and cannot absorb the growth you failed to predict.
#
#  Official objective text: https://www.lpi.org/our-certifications/exam-101-objectives/
#  man pages cited: fstab(5), mount(8), umount(8), mountpoint(1), blkid(8),
#  mkswap(8), swapon(8), lvextend(8), resize2fs(8), parted(8), lsblk(8),
#  findmnt(8), systemd-fstab-generator(8)
# ==============================================================================