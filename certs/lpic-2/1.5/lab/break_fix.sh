#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 (Exams 201-450 & 202-450 v4.5) - Topic 201.1 / 105.1 (Weight 7)
# Advanced Storage Device Administration: Break & Fix Production Scenario
# ==============================================================================
# Reference: https://www.lpi.org/our-certifications/lpic-2-overview/
#
# DESCRIPTION:
# This script creates an isolated storage lab using loopback devices, builds a
# Software RAID 5 array with LVM, writes test data, and introduces a critical
# multi-layer storage degradation and metadata misconfiguration failure.
#
# PREREQUISITES:
# - Linux OS (Ubuntu/Debian, RHEL/Fedora/Rocky, SLES, Arch)
# - Root privileges (run via sudo or root user)
# - Required tools: mdadm, lvm2 (pvs, vgs, lvs), losetup, blockdev, ext4 utils
# ==============================================================================

set -euo pipefail

# Color Palette for CLI formatting
RED='\030[0;31m'
GREEN='\030[0;32m'
YELLOW='\030[0;33m'
BLUE='\030[0;34m'
CYAN='\030[0;36m'
BOLD='\030[1m'
NC='\030[0m'

LAB_DIR="/var/tmp/lpic2_storage_lab"
MD_DEV="/dev/md66"
VG_NAME="vg_production"
LV_NAME="lv_financials"
MOUNT_POINT="/mnt/production_finance"

check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed as root (sudo).${NC}" >&2
        exit 1
    fi

    local missing_tools=()
    for tool in mdadm losetup pvcreate vgcreate lvcreate mkfs.ext4 blkid; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo -e "${RED}[ERROR] Missing required storage administration utilities: ${missing_tools[*]}${NC}" >&2
        echo "Please install 'mdadm', 'lvm2', and 'e2fsprogs' packages before continuing."
        exit 1
    fi
}

cleanup_previous_lab() {
    echo -e "${YELLOW}[SETUP] Cleaning up existing lab resources if present...${NC}"
    
    # 1. Unmount filesystem
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount -f "$MOUNT_POINT" 2>/dev/null || true
    fi

    # 2. Deactivate LVM components
    if vgdisplay "$VG_NAME" &>/dev/null; then
        vgchange -an "$VG_NAME" 2>/dev/null || true
        vgremove -ff "$VG_NAME" 2>/dev/null || true
    fi

    # 3. Stop RAID array
    if [[ -b "$MD_DEV" ]] || mdadm --detail "$MD_DEV" &>/dev/null; then
        mdadm --stop "$MD_DEV" 2>/dev/null || true
    fi

    # 4. Detach associated loop devices
    for img in "${LAB_DIR}"/disk*.img; do
        if [[ -f "$img" ]]; then
            local loop_dev
            loop_dev=$(losetup -j "$img" | cut -d: -f1)
            if [[ -n "$loop_dev" ]]; then
                # Wipe metadata signatures if needed
                mdadm --zero-superblock "$loop_dev" 2>/dev/null || true
                losetup -d "$loop_dev" 2>/dev/null || true
            fi
        fi
    done

    rm -rf "$LAB_DIR" "$MOUNT_POINT"
}

setup_production_environment() {
    echo -e "${CYAN}[LAB INIT] Constructing baseline storage environment...${NC}"
    mkdir -p "$LAB_DIR" "$MOUNT_POINT"

    # Create 4 raw disk images (300MB each)
    local loop_devices=()
    for i in {1..4}; do
        local img="${LAB_DIR}/disk${i}.img"
        dd if=/dev/zero of="$img" bs=1M count=300 status=none
        local dev
        dev=$(losetup -f --show "$img")
        loop_devices+=("$dev")
        echo -e "  -> Created virtual block device ${BOLD}${dev}${NC} backed by disk${i}.img"
    done

    # Assigning to variables for explicit handling
    LOOP1="${loop_devices[0]}"
    LOOP2="${loop_devices[1]}"
    LOOP3="${loop_devices[2]}"
    LOOP4="${loop_devices[3]}"

    echo -e "${CYAN}[RAID CREATION] Provisioning Software RAID 5 array (${MD_DEV}) with 3 active devices and 1 hot spare...${NC}"
    mdadm --create "$MD_DEV" \
        --level=5 \
        --raid-devices=3 \
        --spare-devices=1 \
        --metadata=1.2 \
        --name="lpic2:finance" \
        --run "$LOOP1" "$LOOP2" "$LOOP3" "$LOOP4" &>/dev/null

    # Wait for sync completion or initial state stabilization
    sleep 3

    echo -e "${CYAN}[LVM STACK] Layering Logical Volume Manager over Software RAID...${NC}"
    pvcreate -y "$MD_DEV" &>/dev/null
    vgcreate "$VG_NAME" "$MD_DEV" &>/dev/null
    lvcreate -l 100%FREE -n "$LV_NAME" "$VG_NAME" &>/dev/null

    echo -e "${CYAN}[FILESYSTEM] Formatting EXT4 with custom journal and labeling...${NC}"
    mkfs.ext4 -F -L "FINANCE_DATA" "/dev/${VG_NAME}/${LV_NAME}" &>/dev/null

    mount "/dev/${VG_NAME}/${LV_NAME}" "$MOUNT_POINT"
    echo "TRANSACTION_ID: 99482-SECURE-FINANCIAL-LOG" > "${MOUNT_POINT}/ledger.dat"
    echo "BALANCE: 15400000.00 USD" >> "${MOUNT_POINT}/ledger.dat"
    md5sum "${MOUNT_POINT}/ledger.dat" > "${MOUNT_POINT}/ledger.dat.md5"
    sync

    umount "$MOUNT_POINT"
    vgchange -an "$VG_NAME" &>/dev/null
}

inject_failures() {
    echo -e "${RED}[BREAKING SYSTEM] Injecting hardware component failure and metadata corruption...${NC}"

    # Step 1: Simulate disk failure on component 2
    mdadm --manage "$MD_DEV" --fail "$LOOP2" &>/dev/null || true
    mdadm --manage "$MD_DEV" --remove "$LOOP2" &>/dev/null || true

    # Step 2: Stop array completely
    mdadm --stop "$MD_DEV" &>/dev/null || true

    # Step 3: Zero out the header of LOOP2 and detach loop mapping (simulating total disk death)
    losetup -d "$LOOP2" &>/dev/null || true
    dd if=/dev/zero of="${LAB_DIR}/disk2.img" bs=1M count=20 status=none

    # Step 4: Corrupt mdadm configuration file to break automatic scanning & assembly
    local mdadm_conf=""
    if [[ -f /etc/mdadm/mdadm.conf ]]; then
        mdadm_conf="/etc/mdadm/mdadm.conf"
    elif [[ -f /etc/mdadm.conf ]]; then
        mdadm_conf="/etc/mdadm.conf"
    else
        mkdir -p /etc/mdadm
        mdadm_conf="/etc/mdadm/mdadm.conf"
    fi

    # Backup original configuration
    if [[ -f "$mdadm_conf" ]]; then
        cp "$mdadm_conf" "${mdadm_conf}.bak_lpic2"
    fi

    cat << 'EOF' > "$mdadm_conf"
# LPIC-2 LAB AUTOMATED CONFIGURATION (CORRUPTED)
# Standard dev scan intentionally restricted
DEVICE /dev/std_non_existent*
ARRAY /dev/md66 level=raid5 num-devices=3 metadata=1.2 UUID=a1b2c3d4:e5f60000:11223344:55667788 devices=/dev/nonexistent1,/dev/nonexistent2
EOF

    # Step 5: Re-attach disk2.img as a completely blank new raw disk (mimicking replaced bare metal drive)
    NEW_BLANK_LOOP=$(losetup -f --show "${LAB_DIR}/disk2.img")
}

display_challenge_banner() {
    echo ""
    echo -e "${BOLD}${RED}==============================================================================${NC}"
    echo -e "${BOLD}${RED}           LPIC-2 BREAK & FIX LAB: ADVANCED STORAGE ADMINISTRATION           ${NC}"
    echo -e "${BOLD}${RED}==============================================================================${NC}"
    echo -e "${BOLD}SCENARIO INCIDENT REPORT:${NC}"
    echo -e "An emergency alert was triggered on production host '${HOSTNAME}'. A storage node"
    echo -e "experienced a disk failure, following which an inexperienced sysadmin attempted"
    echo -e "manual intervention. The financial data volume (${BOLD}${MOUNT_POINT}${NC}) is unmounted,"
    echo -e "the RAID array (${BOLD}${MD_DEV}${NC}) is inactive/missing, LVM VG '${BOLD}${VG_NAME}${NC}' is offline,"
    echo -e "and '/etc/mdadm/mdadm.conf' contains invalid array descriptors."
    echo ""
    echo -e "${BOLD}SYSTEM SYMPTOMS:${NC}"
    echo -e " 1. Running 'mount ${MOUNT_POINT}' fails because the logical volume is unavailable."
    echo -e " 2. 'vgchange -ay ${VG_NAME}' fails to locate Physical Volume metadata."
    echo -e " 3. Automated RAID assembly ('mdadm --assemble --scan') fails due to broken configuration."
    echo -e " 4. One disk was physically replaced (represented by loopback device: ${BOLD}${NEW_BLANK_LOOP}${NC})."
    echo ""
    echo -e "${BOLD}STUDENT OBJECTIVES:${NC}"
    echo -e " [1] Inspect block devices, UUIDs, and software RAID superblocks."
    echo -e " [2] Fix or generate a valid '/etc/mdadm/mdadm.conf' file using 'mdadm --detail --scan'."
    echo -e " [3] Assemble the degraded RAID 5 array (${MD_DEV}) using the surviving component disks."
    echo -e " [4] Add the newly replaced blank disk (${NEW_BLANK_LOOP}) as a spare / rebuild component."
    echo -e " [5] Verify RAID sync/rebuild progress using '/proc/mdstat' or 'mdadm --detail'."
    echo -e " [6] Activate the LVM Volume Group '${VG_NAME}' and Logical Volume '${LV_NAME}'."
    echo -e " [7] Mount the filesystem at '${MOUNT_POINT}' and verify file integrity via checksums:"
    echo -e "     ${CYAN}md5sum -c ${MOUNT_POINT}/ledger.dat.md5${NC}"
    echo ""
    echo -e "${BOLD}DIAGNOSTIC HINTS & COMMANDS TO USE:${NC}"
    echo -e " - ${YELLOW}lsblk -f${NC} / ${YELLOW}blkid${NC}"
    echo -e " - ${YELLOW}mdadm --examine /dev/loop*${NC}"
    echo -e " - ${YELLOW}mdadm --assemble --scan --verbose${NC}"
    echo -e " - ${YELLOW}mdadm --detail --scan${NC}"
    echo -e " - ${YELLOW}pvs${NC} / ${YELLOW}vgs${NC} / ${YELLOW}lvs${NC}"
    echo -e " - ${YELLOW}vgchange -ay${NC}"
    echo -e "${BOLD}${RED}==============================================================================${NC}"
    echo ""
}

main() {
    check_prerequisites
    cleanup_previous_lab
    setup_production_environment
    inject_failures
    display_challenge_banner
}

main "$@"

# ==============================================================================
#                      STEP-BY-STEP SOLUTION & VERIFICATION GUIDE
# ==============================================================================
# (Keep commented out. Use this section to study the exact solution mechanics)
#
# STEP 1: DIAGNOSE SUPERBLOCKS & LOCATE SURVIVING RAID COMPONENTS
# ------------------------------------------------------------------------------
# Inspect available loopback block devices to identify which ones belong to the array:
#   # mdadm --examine /dev/loop*
#
# You will observe:
#   - Three devices (e.g., /dev/loop1, /dev/loop3, /dev/loop4) contain valid 
#     RAID 5 superblocks (Array UUID, Device Role, Metadata 1.2).
#   - One device (e.g., /dev/loop2) has no RAID superblock (blank replacement).
#
# STEP 2: FIX /etc/mdadm/mdadm.conf CONFIGURATION
# ------------------------------------------------------------------------------
# Backup the broken configuration and auto-generate clean scan directives:
#   # cp /etc/mdadm/mdadm.conf /etc/mdadm/mdadm.conf.broken
#   # echo "DEVICE partitions /dev/loop*" > /etc/mdadm/mdadm.conf
#   # mdadm --detail --scan >> /etc/mdadm/mdadm.conf
#
# Verify the configuration syntax:
#   # cat /etc/mdadm/mdadm.conf
#
# STEP 3: ASSEMBLE THE DEGRADED SOFTWARE RAID ARRAY
# ------------------------------------------------------------------------------
# Assemble the array using the surviving devices or via auto-assembly:
#   # mdadm --assemble --scan --verbose
#   OR explicitly:
#   # mdadm --assemble /dev/md66 /dev/loop1 /dev/loop3 /dev/loop4
#
# Check array status:
#   # cat /proc/mdstat
#   # mdadm --detail /dev/md66
# (The state should show 'clean, degraded' with 3 working devices).
#
# STEP 4: RECOVER DEGRADATION BY HOT-ADDING REPLACEMENT DISK
# ------------------------------------------------------------------------------
# Hot-add the new blank disk back into the array to initiate rebuild:
#   # mdadm --manage /dev/md66 --add /dev/loop2
#
# Monitor rebuild activity:
#   # cat /proc/mdstat
#   # mdadm --detail /dev/md66
# (Observe 'rebuild = XX.X%' until state returns to 'active, clean').
#
# STEP 5: ACTIVATE LVM VOLUMES OVER THE RECOVERED RAID ARRAY
# ------------------------------------------------------------------------------
# Scan physical volumes and activate the volume group:
#   # pvscan
#   # vgscan
#   # vgchange -ay vg_production
#   # lvs
#
# STEP 6: MOUNT FILESYSTEM AND VERIFY DATA INTEGRITY
# ------------------------------------------------------------------------------
# Mount the recovered logical volume:
#   # mount /dev/vg_production/lv_financials /mnt/production_finance
#
# Validate data integrity using MD5 checksum:
#   # cd /mnt/production_finance
#   # cat ledger.dat
#   # md5sum -c ledger.dat.md5
#
# EXPECTED OUTPUT FOR CHECKSUM VERIFICATION:
#   ledger.dat: OK
#
# STEP 7: CLEANUP LAB (WHEN FINISHED TESTING)
# ------------------------------------------------------------------------------
# Restore original mdadm.conf if backup exists:
#   # test -f /etc/mdadm/mdadm.conf.bak_lpic2 && mv /etc/mdadm/mdadm.conf.bak_lpic2 /etc/mdadm/mdadm.conf
# Unmount and tear down loop devices:
#   # umount /mnt/production_finance
#   # vgchange -an vg_production
#   # mdadm --stop /dev/md66
#   # losetup -D
# ==============================================================================