#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (701-100) - Topic 3.3: System Image Creation
# Break & Fix Production Simulation Lab
# ==============================================================================
# Target Exam: LPI 701-100 (v1.0), Topic 3.3 (Weight 3.33 / Topic 701.3 Weight 4)
# Topic Description: System Image Creation (Packer, Cloud-init, Base Image Customization)
# ==============================================================================
# WARNING: Run this script only inside an isolated disposable lab VM or container.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_701_system_image_lab"
COLOR_RESET="\033[0m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_CYAN="\033[36m"

echo -e "${COLOR_CYAN}[+] Initializing LPI 701-100 Topic 3.3 Break & Fix Environment...${COLOR_RESET}"

# ------------------------------------------------------------------------------
# 1. Workspace Cleanup and Setup
# ------------------------------------------------------------------------------
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/scripts"
mkdir -p "${LAB_DIR}/http"

cd "${LAB_DIR}"

# ------------------------------------------------------------------------------
# 2. Inject Broken Packer HCL2 Template
# ------------------------------------------------------------------------------
# Breakages introduced:
# - Malformed variable block type definition.
# - Invalid builder source declaration (missing required image/communicator block).
# - Provisioner path error and unescaped cloud-init wait loop shell logic.
# - Invalid post-processor syntax.

cat << 'EOF' > template.pkr.hcl
packer {
  required_plugins {
    docker = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/docker"
    }
  }
}

variable "base_image" {
  type    = map(string)
  default = "ubuntu:22.04"
}

variable "environment" {
  type    = string
  default = "production"
}

source "docker" "ubuntu_custom" {
  image       = var.base_image
  commit      = "true"
  changes = [
    "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]",
    "ENV APP_ENV=${var.environment}"
  ]
}

build {
  name = "lpi-system-image-builder"
  sources = [
    "source.docker.ubuntu"
  ]

  provisioner "file" {
    source      = "http/user-data.yaml"
    destination = "etc/cloud/cloud.cfg.d/99-custom-user-data.cfg"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init completion...'",
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done",
      "cloud-init status --wait --long",
      "chmod +x /tmp/scripts/setup.sh",
      "/tmp/scripts/setup.sh"
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = "invalid-boolean-string"
  }
}
EOF

# ------------------------------------------------------------------------------
# 3. Inject Broken Cloud-init Configuration
# ------------------------------------------------------------------------------
# Breakages introduced:
# - Invalid YAML syntax (tab indentation instead of spaces under write_files).
# - Invalid cloud-config schema (path field missing leading slash, bad permission mode format).
# - Malformed runcmd array formatting.

cat << 'EOF' > http/user-data.yaml
#cloud-config
version: 1
users:
  - name: sysadmin
    gecos: SRE Engineer
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3... student@lpi-lab

package_update: true
packages:
  - curl
  - htop
  - jq
  - net-tools

write_files:
	- path: etc/motd
	  permissions: 644
	  owner: root:root
	  content: |
	    ===================================================
	    Welcome to Hardened LPI Production Image
	    Managed via Packer & Cloud-Init
	    ===================================================

runcmd:
  - [ echo, "Configuring system services..." ]
  - systemctl enable systemd-resolved
  - "echo 'BOOTSTRAP_COMPLETE=true' >> /etc/environment"
  - invalid_yaml_bare_key_without_colon_value
EOF

# ------------------------------------------------------------------------------
# 4. Inject Broken Shell Provisioner Script
# ------------------------------------------------------------------------------
cat << 'EOF' > scripts/setup.sh
#!/usr/bin/env bash
set -e

echo "Running image provisioning steps..."
mkdir -p /usr/local/bin

cat << 'ENTRY' > /usr/local/bin/entrypoint.sh
#!/bin/sh
echo "Starting containerized node..."
exec "$@"
ENTRY

# Subshell bug: exiting with error code due to uninitialized variable check
if [ -z "${REQUIRED_VAR}" ]; then
    echo "ERROR: REQUIRED_VAR is not set during image build!"
    exit 42
fi

echo "Provisioning complete."
EOF

chmod +x scripts/setup.sh

# ------------------------------------------------------------------------------
# 5. Display Lab Details and Symptoms
# ------------------------------------------------------------------------------
echo -e "\n${COLOR_RED}==============================================================================${COLOR_RESET}"
echo -e "${COLOR_RED}               LAB BROKEN - BREAK & FIX CHALLENGE ACTIVATED                   ${COLOR_RESET}"
echo -e "${COLOR_RED}==============================================================================${COLOR_RESET}\n"

echo -e "${COLOR_YELLOW}SCENARIO:${COLOR_RESET}"
echo "You are an SRE maintaining an automated golden image creation pipeline for cloud"
echo "deployments. The pipeline uses Packer HCL2 templates integrated with cloud-init"
echo "for initial boot configuration and guest OS hardening."
echo "The previous shift left behind an broken build pipeline in '${LAB_DIR}'."

echo -e "\n${COLOR_YELLOW}SYMPTOMS & OBSERVED ERRORS:${COLOR_RESET}"
echo "1. Running 'packer validate template.pkr.hcl' fails with multiple HCL validation,"
echo "   type mismatch, and source target resolution errors."
echo "2. Running cloud-init schema validation ('cloud-init schema --config-file http/user-data.yaml')"
echo "   fails with severe YAML syntax errors and schema rule violations."
echo "3. Provisioner execution crashes when attempting file transfers and shell execution."

echo -e "\n${COLOR_YELLOW}STUDENT OBJECTIVES:${COLOR_RESET}"
echo "1. Inspect '${LAB_DIR}/template.pkr.hcl' and fix all HCL2 Packer syntax, variable,"
echo "   source mapping, destination pathing, and post-processor errors."
echo "2. Inspect '${LAB_DIR}/http/user-data.yaml' and repair all cloud-config YAML"
echo "   indentation, schema, and command array format errors."
echo "3. Inspect '${LAB_DIR}/scripts/setup.sh' and fix execution bugs preventing a clean"
echo "   build process."
echo "4. Verify success by running 'packer validate template.pkr.hcl' and checking"
echo "   cloud-init syntax with 'cloud-init schema --config-file http/user-data.yaml'."

echo -e "\n${COLOR_GREEN}Workspace Path:${COLOR_RESET} ${LAB_DIR}"
echo -e "${COLOR_CYAN}Good luck! (Detailed step-by-step solution is commented at the end of this script file).${COLOR_RESET}\n"

# ==============================================================================
# SOLUTION & DEEP TECHNICAL EXPLANATION (KEEP COMMENTED OUT)
# ==============================================================================
#
# ------------------------------------------------------------------------------
# ROOT CAUSE ANALYSIS & DIAGNOSTICS:
# ------------------------------------------------------------------------------
# 1. Packer HCL2 Errors in `template.pkr.hcl`:
#    a. Variable Type Mismatch: `variable "base_image"` declares `type = map(string)`,
#       but its default value `"ubuntu:22.04"` is a string. Type must be `string`.
#    b. Source Reference Name Mismatch: Build block references `"source.docker.ubuntu"`,
#       but the defined source block is `source "docker" "ubuntu_custom"`.
#    c. Missing Destination Slash: Provisioner `"file"` has destination set to
#       `"etc/cloud/cloud.cfg.d/..."` (relative path). In Linux target containers/VMs,
#       file provisioners require absolute paths (e.g., `"/etc/cloud/cloud.cfg.d/..."`).
#    d. Unescaped HCL Variable inside Changes: `ENV APP_ENV=${var.environment}` inside
#       the changes array requires proper HCL interpolation `"${var.environment}"`.
#    e. Post-Processor Type Mismatch: `strip_path` in the manifest post-processor expects
#       a boolean (`true` or `false`), not a string `"invalid-boolean-string"`.
#
# 2. Cloud-Init Schema & YAML Errors in `http/user-data.yaml`:
#    a. Tab Character Indentation: YAML parser rejects tabs under `write_files:`.
#       YAML standard strictly mandates space-based indentation.
#    b. Missing Leading Slash in Path: `path: etc/motd` violates cloud-init schema.
#       All file targets must be absolute paths (e.g., `path: /etc/motd`).
#    c. Incorrect Octal Permissions: `permissions: 644` interpreted as decimal 644
#       or string error depending on parser. Cloud-init standard recommends string `'0644'`.
#    d. Invalid Bare Key in `runcmd`: `- invalid_yaml_bare_key_without_colon_value` is
#       invalid command list syntax in YAML.
#
# 3. Provisioner Shell Script Bug in `scripts/setup.sh`:
#    a. Strict mode `set -e` triggers immediate script failure on `[ -z "${REQUIRED_VAR}" ]`
#       exit 42 branch because the variable is intentionally unset during image build.
#
# ------------------------------------------------------------------------------
# DIAGNOSTIC COMMANDS:
# ------------------------------------------------------------------------------
# Step 1: Validate Packer HCL2 Template
#   $ cd /tmp/lpi_701_system_image_lab
#   $ packer validate template.pkr.hcl
#   $ packer fmt -check template.pkr.hcl
#
# Step 2: Validate Cloud-Init Configuration
#   $ cloud-init schema --config-file http/user-data.yaml
#   OR using python YAML parser validation:
#   $ python3 -c "import yaml; print(yaml.safe_load(open('http/user-data.yaml')))"
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP FIXES:
# ------------------------------------------------------------------------------
#
# FIX 1: Corrected `template.pkr.hcl`
# ----------------------------------
# cat << 'EOF' > /tmp/lpi_701_system_image_lab/template.pkr.hcl
# packer {
#   required_plugins {
#     docker = {
#       version = ">= 1.0.0"
#       source  = "github.com/hashicorp/docker"
#     }
#   }
# }
#
# variable "base_image" {
#   type    = string
#   default = "ubuntu:22.04"
# }
#
# variable "environment" {
#   type    = string
#   default = "production"
# }
#
# source "docker" "ubuntu_custom" {
#   image  = var.base_image
#   commit = true
#   changes = [
#     "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]",
#     "ENV APP_ENV=${var.environment}"
#   ]
# }
#
# build {
#   name = "lpi-system-image-builder"
#   sources = [
#     "source.docker.ubuntu_custom"
#   ]
#
#   provisioner "file" {
#     source      = "http/user-data.yaml"
#     destination = "/tmp/99-custom-user-data.cfg"
#   }
#
#   provisioner "file" {
#     source      = "scripts/setup.sh"
#     destination = "/tmp/setup.sh"
#   }
#
#   provisioner "shell" {
#     inline = [
#       "chmod +x /tmp/setup.sh",
#       "REQUIRED_VAR=build_time_value /tmp/setup.sh"
#     ]
#   }
#
#   post-processor "manifest" {
#     output     = "manifest.json"
#     strip_path = true
#   }
# }
# EOF
#
# FIX 2: Corrected `http/user-data.yaml`
# --------------------------------------
# cat << 'EOF' > /tmp/lpi_701_system_image_lab/http/user-data.yaml
# #cloud-config
# version: 1
# users:
#   - name: sysadmin
#     gecos: SRE Engineer
#     sudo: ALL=(ALL) NOPASSWD:ALL
#     groups: users, sudo
#     shell: /bin/bash
#     ssh_authorized_keys:
#       - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3... student@lpi-lab
#
# package_update: true
# packages:
#   - curl
#   - htop
#   - jq
#   - net-tools
#
# write_files:
#   - path: /etc/motd
#     permissions: '0644'
#     owner: root:root
#     content: |
#       ===================================================
#       Welcome to Hardened LPI Production Image
#       Managed via Packer & Cloud-Init
#       ===================================================
#
# runcmd:
#   - [ echo, "Configuring system services..." ]
#   - [ systemctl, enable, systemd-resolved ]
#   - "echo 'BOOTSTRAP_COMPLETE=true' >> /etc/environment"
# EOF
#
# FIX 3: Corrected `scripts/setup.sh`
# -----------------------------------
# cat << 'EOF' > /tmp/lpi_701_system_image_lab/scripts/setup.sh
# #!/usr/bin/env bash
# set -e
#
# echo "Running image provisioning steps..."
# mkdir -p /usr/local/bin
#
# cat << 'ENTRY' > /usr/local/bin/entrypoint.sh
# #!/bin/sh
# echo "Starting containerized node..."
# exec "$@"
# ENTRY
# chmod +x /usr/local/bin/entrypoint.sh
#
# REQUIRED_VAR="${REQUIRED_VAR:-default_build_value}"
# echo "REQUIRED_VAR is set to: ${REQUIRED_VAR}"
# echo "Provisioning complete."
# EOF
#
# ------------------------------------------------------------------------------
# OFFICIAL REFERENCES & CITATIONS:
# ------------------------------------------------------------------------------
# LPI DevOps Tools Engineer Overview:
# https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
#
# HashiCorp Packer Documentation (HCL2 Specification & Provisioners):
# https://developer.hashicorp.com/packer/docs/templates/hcl_templates
# https://developer.hashicorp.com/packer/docs/provisioners/shell
# https://developer.hashicorp.com/packer/docs/provisioners/file
#
# Cloud-init Official Documentation & Schema Reference:
# https://cloudinit.readthedocs.io/en/latest/reference/examples.html
# https://cloudinit.readthedocs.io/en/latest/reference/cli.html#schema
# ==============================================================================