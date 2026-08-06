#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Exam 305-300 (v3.0) | Topic 1.3: VM Deployment and Provisioning
# Weight: 33.34 (Topic 305.1)
# Break & Fix Scenario: Cloud-Init Datasource & User-Data Schema Corruption
#
# Official References:
#   - LPIC-3 305 Overview: https://www.lpi.org/our-certifications/lpic-3-305-overview/
#   - Cloud-Init Documentation: https://cloudinit.readthedocs.io/en/latest/
#   - Cloud-Init CLI Reference: https://cloudinit.readthedocs.io/en/latest/reference/cli.html
#   - Libguestfs / virt-builder: https://libguestfs.org/virt-builder.1.html
# ==============================================================================

set -euo pipefail

# 1. Privileged execution check
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This lab script must be executed with root privileges (sudo)." >&2
    exit 1
fi

CONFIG_DIR="/etc/cloud/cloud.cfg.d"
BROKEN_CONFIG="${CONFIG_DIR}/99-production-bootstrap.cfg"
LOG_INIT="/var/log/cloud-init.log"
LOG_OUT="/var/log/cloud-init-output.log"

echo "[+] Initializing LPIC-3 305 Break & Fix Environment..."

# 2. Ensure cloud-init is installed for testing environment
if ! command -v cloud-init &>/dev/null; then
    echo "[*] cloud-init package not detected. Installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq cloud-init python3-yaml >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q cloud-init python3-pyyaml >/dev/null
    else
        echo "[ERROR] Unsupported package manager. Please install cloud-init manually." >&2
        exit 1
    fi
fi

# 3. Inject controlled fault into Cloud-Init drop-in configuration
# Fault 1: Invalid datasource precedence ('UnknownDatasource' inserted before valid NoCloud/ConfigDrive)
# Fault 2: Hard tab character inserted into YAML indentation under 'users'
# Fault 3: Malformed key directive 'run_commands' instead of valid 'runcmd'
mkdir -p "${CONFIG_DIR}"

cat << 'EOF' > "${BROKEN_CONFIG}"
# Production VM Provisioning Manifest - LPIC-3 305 Lab
datasource_list: [ UnknownDatasource, NoCloud, ConfigDrive ]

# Cloud-config user definition
users:
  - name: sysadmin
    gecos: System Administrator
	primary_group: sysadmin
    groups: [ sudo, wheel ]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

# Post-provisioning hook execution
run_commands:
  - [ systemctl, enable, --now, sshd ]
  - echo "VM successfully provisioned" > /etc/motd
EOF

# Insert exact tab character (\t) on line 8 to break YAML parser explicitly
sed -i '8s/^    /\t/' "${BROKEN_CONFIG}"

# 4. Clear cloud-init cache and status logs to trigger broken state
cloud-init clean --logs --seed &>/dev/null || true
rm -rf /var/lib/cloud/data /var/lib/cloud/instance /var/lib/cloud/instances/* &>/dev/null || true

# 5. Output Scenario Briefing to the Student
cat << EOF

===============================================================================
  LPIC-3 305 (Exam 305-300 v3.0) - TOPIC 1.3: VM DEPLOYMENT & PROVISIONING
  LAB SCENARIO: AUTOMATED VM BOOTSTRAP FAILURE DIAGNOSTIC
===============================================================================

SCENARIO DESCRIPTION:
You are an SRE maintaining an automated KVM/QEMU cloud image deployment pipeline.
A newly provisioned virtual machine template failed to execute its initial
first-boot configuration stage via cloud-init. The system administrator account
'sysadmin' was not created, custom packages were not configured, and cloud-init
exited with an error state.

OBSERVED SYMPTOMS:
1. Running 'cloud-init status --long' reports an error state.
2. The user-data configuration drop-in file is located at:
   ${BROKEN_CONFIG}
3. System logs /var/log/cloud-init.log show schema/parser warnings and datasource failures.

STUDENT OBJECTIVE:
1. Perform root-cause analysis using official cloud-init diagnostic tooling.
2. Identify syntax errors, invalid schema directives, and broken datasource lists.
3. Repair ${BROKEN_CONFIG} so it strictly adheres to cloud-config syntax rules.
4. Purge local cloud-init state and trigger re-execution of all initialization stages.
5. Verify that 'cloud-init status --long' transitions to: "status: done".

COMMANDS TO BEGIN DIAGNOSTICS:
  $ sudo cloud-init status --long
  $ sudo cloud-init schema --config-file ${BROKEN_CONFIG}
  $ sudo tail -n 50 ${LOG_INIT}

===============================================================================
EOF

exit 0

# ==============================================================================
# COMPREHENSIVE STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION
# (Keep commented out for student self-assessment)
# ==============================================================================
#
# TECHNICAL BACKGROUND (LPIC-3 305 TOPIC 1.3):
# Cloud-init processes early stage VM metadata and user-data during system boot.
# Configuration files located in /etc/cloud/cloud.cfg.d/*.cfg use strict YAML syntax.
# Common causes of provisioning failures in production:
# 1. Invalid YAML formatting (YAML forbids TAB characters; spaces must be used).
# 2. Invalid schema keys (e.g., using 'run_commands' instead of the standard module key 'runcmd').
# 3. Invalid or unreachable datasource ordering (causing timeouts or failure to parse local metadata).
#
# DIAGNOSTIC AND REPAIR STEPS:
#
# STEP 1: Inspect cloud-init operational status and log output
#   # Check overall execution state:
#   $ sudo cloud-init status --long
#   # Expected Output: status: error
#
#   # Analyze execution log for parser or datasource exceptions:
#   $ sudo grep -Ei "(error|warning|yaml|tab)" /var/log/cloud-init.log
#   # Expected Log Output:
#   # ScannerError: found character '\t' that cannot start any token
#
# STEP 2: Validate the cloud-config drop-in file against the official schema
#   $ sudo cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-production-bootstrap.cfg
#   # Expected Output:
#   # Validating config /etc/cloud/cloud.cfg.d/99-production-bootstrap.cfg
#   # Cloud config schema errors: line 8: tab character found, run_commands: unrecognised key
#
# STEP 3: Edit and correct /etc/cloud/cloud.cfg.d/99-production-bootstrap.cfg
#   Replace the file contents with syntactically valid YAML and standard schema keys:
#
#   cat << 'FIX' | sudo tee /etc/cloud/cloud.cfg.d/99-production-bootstrap.cfg
#   # Production VM Provisioning Manifest - LPIC-3 305 Lab (REPAIRED)
#   datasource_list: [ NoCloud, ConfigDrive, OpenStack, None ]
#
#   users:
#     - name: sysadmin
#       gecos: System Administrator
#       primary_group: sysadmin
#       groups: [ sudo, wheel ]
#       shell: /bin/bash
#       sudo: ALL=(ALL) NOPASSWD:ALL
#
#   runcmd:
#     - [ systemctl, enable, --now, sshd ]
#     - echo "VM successfully provisioned" > /etc/motd
#   FIX
#
# STEP 4: Re-validate configuration schema
#   $ sudo cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-production-bootstrap.cfg
#   # Expected Output:
#   # Validating config /etc/cloud/cloud.cfg.d/99-production-bootstrap.cfg
#   # Read cloud-config schema: Valid
#
# STEP 5: Reset local cloud-init state and trigger manual stage execution
#   # Clean cached artifacts and log history:
#   $ sudo cloud-init clean --logs --seed
#
#   # Force re-initialization of local and net modules:
#   $ sudo cloud-init init --local
#   $ sudo cloud-init init
#   $ sudo cloud-init modules --mode config
#   $ sudo cloud-init modules --mode final
#
# STEP 6: Verify final operational status
#   $ sudo cloud-init status --long
#   # Expected Output:
#   # status: done
#   # extended_status: done
# ==============================================================================