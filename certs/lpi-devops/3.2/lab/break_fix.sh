#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (701-100) - Topic 3.2: Cloud Deployment
# LAB EXERCISE: Break & Fix - Cloud-Init & IaaS Provisioning Readiness
# ==============================================================================
#
# OBJECTIVE:
# Diagnose and repair a broken cloud instance provisioning configuration.
# This script simulates a production IaaS deployment scenario where cloud-init
# fails to provision the 'devops-admin' user, misconfigures SSH key injection,
# breaks sudoers authorization, and fails disk formatting/mounting.
#
# SYMPTOMS:
# 1. 'cloud-init status --long' reports status 'error' or shows schema validation errors.
# 2. Automated remote management (e.g., via Ansible) fails due to missing user
#    'devops-admin' and SSH key authentication failure.
# 3. Sudo elevation for cloud automation accounts fails or requires a password.
# 4. Secondary data volume is not formatted or mounted at /var/log/app.
# 5. Cloud-init logs (/var/log/cloud-init.log) contain YAML parser exceptions.
#
# STUDENT GOAL:
# 1. Identify all syntax, module, and configuration errors in /etc/cloud/cloud.cfg.d/.
# 2. Validate configuration using 'cloud-init schema --config-file <file>'.
# 3. Clean previous failed state with 'cloud-init clean'.
# 4. Force re-execution of cloud-init stages ('cloud-init init', 'cloud-init modules').
# 5. Verify successful user creation, SSH key injection, sudo privilege, and volume mount.
# ==============================================================================

set -euo pipefail

# Ensure script is executed as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    exit 1
fi

echo "----------------------------------------------------------------------"
echo " LPI 701-100 Topic 3.2: Cloud Deployment - Break & Fix Environment Setup"
echo "----------------------------------------------------------------------"

# Ensure cloud-init is installed
if ! command -v cloud-init &> /dev/null; then
    echo "[+] Installing cloud-init package..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq cloud-init
    elif command -v dnf &> /dev/null; then
        dnf install -y -q cloud-init
    elif command -v yum &> /dev/null; then
        yum install -y -q cloud-init
    else
        echo "ERROR: Unsupported package manager. Please install cloud-init manually." >&2
        exit 1
    fi
fi

# Create backup directory for original cloud-init configs
BACKUP_DIR="/var/backups/cloud-init-lpi-lab"
mkdir -p "${BACKUP_DIR}"

if [[ ! -f "${BACKUP_DIR}/cloud.cfg.orig" ]] && [[ -f "/etc/cloud/cloud.cfg" ]]; then
    cp "/etc/cloud/cloud.cfg" "${BACKUP_DIR}/cloud.cfg.orig"
fi

echo "[+] Preparing loopback device to simulate secondary cloud storage volume..."
IMG_FILE="/var/tmp/cloud-secondary-vol.img"
LOOP_DEV=""

# Cleanup existing loop device if previously configured
EXISTING_LOOP=$(losetup -j "${IMG_FILE}" | cut -d: -f1 || true)
if [[ -n "${EXISTING_LOOP}" ]]; then
    umount /var/log/app 2>/dev/null || true
    losetup -d "${EXISTING_LOOP}" 2>/dev/null || true
fi

dd if=/dev/zero of="${IMG_FILE}" bs=1M count=100 status=none
LOOP_DEV=$(losetup --find --show "${IMG_FILE}")

echo "[+] Injecting artificial defects into cloud-init configuration files..."

# Ensure cloud.cfg.d directory exists
mkdir -p /etc/cloud/cloud.cfg.d/

# ------------------------------------------------------------------------------
# INTENTIONAL BUG 1: Invalid YAML syntax (Tab characters used for indentation)
# INTENTIONAL BUG 2: Malformed user specification (missing ssh_authorized_keys type)
# INTENTIONAL BUG 3: Broken sudo directive (invalid string format causing parse error)
# ------------------------------------------------------------------------------
cat << 'EOF' > /etc/cloud/cloud.cfg.d/99-devops-provisioning.cfg
# Custom Cloud-Init User & Authorization Config
users:
  - default
	- name: devops-admin
	  gecos: DevOps Automation Account
	  primary_group: devops
	  groups: [wheel, sudo, docker]
	  selinux_user: staff_u
	  expiredate: '2030-12-31'
	  sudo: ALL=(ALL) NOPASSWD:ALL
	  ssh_authorized_keys:
	    - AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vRz... devops-key@ci
EOF

# ------------------------------------------------------------------------------
# INTENTIONAL BUG 4: Broken Mount Directive & File System Definition
# ------------------------------------------------------------------------------
cat << EOF > /etc/cloud/cloud.cfg.d/90-storage-mounts.cfg
# Custom Cloud-Init Disk & Mount Config
disk_setup:
  ${LOOP_DEV}:
    table_type: 'gpt'
    layout: true
    overwrite: false

fs_setup:
  - label: app_logs
    filesystem: 'ext4_invalid'
    device: '${LOOP_DEV}'
    partition: 'auto'

mounts:
  - [ "${LOOP_DEV}", "/var/log/app", "auto", "defaults,nofail", "0", "0" ]
EOF

# ------------------------------------------------------------------------------
# INTENTIONAL BUG 5: Disabling critical module execution stage in main config
# ------------------------------------------------------------------------------
cat << 'EOF' > /etc/cloud/cloud.cfg.d/05_disable_modules.cfg
# Cloud-init module override
cloud_final_modules:
  - rightscale_userdata
  - scripts-per-once
  - scripts-per-boot
  - scripts-per-instance
  - keys-to-console
  - phone-home
  - final-message
EOF

# Clean existing cloud-init cache and force system into uninitialized state
echo "[+] Resetting cloud-init state..."
cloud-init clean --logs --seed || true
rm -rf /var/lib/cloud/data /var/lib/cloud/instance /var/lib/cloud/instances /var/lib/cloud/sem

# Clean up devops-admin user if previously created
if id "devops-admin" &>/dev/null; then
    userdel -r devops-admin 2>/dev/null || true
fi
rm -f /etc/sudoers.d/99-devops-admin-cloud-init

echo "----------------------------------------------------------------------"
echo " [!] LAB ENVIRONMENT IS BROKEN AND READY FOR DIAGNOSIS"
echo "----------------------------------------------------------------------"
echo "Issue Description:"
echo "  The cloud instance failed to initialize users and storage during boot."
echo "  Automated deployment pipelines cannot log in via SSH or format disk."
echo ""
echo "Observed Symptoms:"
echo "  1. Running 'cloud-init status --long' reports errors."
echo "  2. Running 'cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-devops-provisioning.cfg' fails."
echo "  3. User 'devops-admin' is missing from /etc/passwd."
echo "  4. Target storage '${LOOP_DEV}' is unformatted and not mounted at /var/log/app."
echo ""
echo "Your Mission:"
echo "  Fix all issues in /etc/cloud/cloud.cfg.d/, clean cloud-init state, and"
echo "  successfully execute cloud-init stages to fully provision the system."
echo "----------------------------------------------------------------------"

exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (UNCOMMENTED FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# STEP 1: Diagnose Cloud-Init Configuration Errors
# ------------------------------------------------------------------------------
# Execute schema verification on custom configuration files:
#   # cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-devops-provisioning.cfg
#
# Output will highlight YAML syntax errors due to TAB indentation and invalid fields.
# Check cloud-init log files for historical details:
#   # cat /var/log/cloud-init.log | grep -E "EVAL|ERROR|YAMLError"
#
# STEP 2: Fix /etc/cloud/cloud.cfg.d/99-devops-provisioning.cfg
# ------------------------------------------------------------------------------
# Edit the file to replace tabs with spaces, fix the 'sudo' syntax (must be a string or list),
# and supply a valid SSH public key prefix (e.g., 'ssh-rsa' or 'ssh-ed25519'):
#
#   # cat << 'EOF' > /etc/cloud/cloud.cfg.d/99-devops-provisioning.cfg
#   # cloud-config
#   users:
#     - default
#     - name: devops-admin
#       gecos: DevOps Automation Account
#       groups: [sudo, wheel]
#       sudo: "ALL=(ALL) NOPASSWD:ALL"
#       shell: /bin/bash
#       ssh_authorized_keys:
#         - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vRz... devops-key@ci
#   EOF
#
# STEP 3: Fix /etc/cloud/cloud.cfg.d/90-storage-mounts.cfg
# ------------------------------------------------------------------------------
# Correct the filesystem type from 'ext4_invalid' to 'ext4', and ensure the device
# reference matches the active block device:
#
#   # LOOP_DEV=$(losetup -j /var/tmp/cloud-secondary-vol.img | cut -d: -f1)
#   # cat << EOF > /etc/cloud/cloud.cfg.d/90-storage-mounts.cfg
#   # cloud-config
#   disk_setup:
#     ${LOOP_DEV}:
#       table_type: 'gpt'
#       layout: true
#       overwrite: false
#
#   fs_setup:
#     - label: app_logs
#       filesystem: 'ext4'
#       device: '${LOOP_DEV}'
#       partition: 'auto'
#
#   mounts:
#     - [ "${LOOP_DEV}", "/var/log/app", "ext4", "defaults,nofail", "0", "2" ]
#   EOF
#
# STEP 4: Fix /etc/cloud/cloud.cfg.d/05_disable_modules.cfg
# ------------------------------------------------------------------------------
# Restore required modules ('users-groups', 'ssh', 'mounts') into the cloud_final_modules array:
#
#   # cat << 'EOF' > /etc/cloud/cloud.cfg.d/05_disable_modules.cfg
#   # cloud-config
#   cloud_final_modules:
#     - disk_setup
#     - mounts
#     - set-passwords
#     - users-groups
#     - ssh
#     - scripts-vendor
#     - scripts-per-once
#     - scripts-per-boot
#     - scripts-per-instance
#     - scripts-user
#     - keys-to-console
#     - final-message
#   EOF
#
# STEP 5: Validate Schema & Reset Cloud-Init
# ------------------------------------------------------------------------------
# Run schema check to confirm all cloud-config files adhere to valid schema:
#   # cloud-init schema --system
#
# Reset the cloud-init state and logs:
#   # cloud-init clean --logs
#
# STEP 6: Execute Cloud-Init Stages & Verify Results
# ------------------------------------------------------------------------------
# Trigger the cloud-init initialization stages manually:
#   # cloud-init init --local
#   # cloud-init init
#   # cloud-init modules --mode config
#   # cloud-init modules --mode final
#
# Verify status:
#   # cloud-init status --long
#   (Expected output: status: done)
#
# Verify User Creation & SSH Key:
#   # id devops-admin
#   # cat /home/devops-admin/.ssh/authorized_keys
#
# Verify Sudo Rights:
#   # sudo -u devops-admin sudo -n id
#   (Expected output: uid=0(root) gid=0(root)...)
#
# Verify Disk Mount:
#   # df -h /var/log/app
#   (Expected output: Mounted on /var/log/app with filesystem ext4)
# ==============================================================================