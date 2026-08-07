#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
# Topic 3.1: Virtual Machine Deployment (Weight: 6.67)
# Hands-On "Break & Fix" Production Laboratory Script
#
# Reference:
# Official LPI Overview: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_devops_topic31_lab"

echo "======================================================================"
echo " Setting up LPI 701-100 Topic 3.1: Virtual Machine Deployment Lab"
echo "======================================================================"

# Clean up previous lab run if existing
if [ -d "${LAB_DIR}" ]; stream
  echo "[*] Cleaning up existing lab directory at ${LAB_DIR}..."
  rm -rf "${LAB_DIR}"
fi

mkdir -p "${LAB_DIR}/cloud-init"
mkdir -p "${LAB_DIR}/scripts"
mkdir -p "${LAB_DIR}/html"

# Create test HTML page
cat << 'EOF' > "${LAB_DIR}/html/index.html"
<!DOCTYPE html>
<html>
<head><title>Production VM Test</title></head>
<body><h1>LPI 701-100 VM Deployment Successful</h1></body>
</html>
EOF

# Inject Broken Vagrantfile
cat << 'EOF' > "${LAB_DIR}/Vagrantfile"
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.hostname = "web-node-01"

  # Forward HTTP port
  config.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true

  # Private network IP assignment
  config.vm.network "private_network", ip: "192.168.56.100"

  # BUG #1: Invalid provider customization type string passed to VirtualBox memory command
  config.vm.provider "virtualbox" do |vb|
    vb.name = "lpi-701-web-node"
    vb.memory = "2048MB" # Should be integer 2048, string "2048MB" causes VirtualBox command failure
    vb.cpus = 2
  end

  # BUG #2: Synced folder configured with non-existent owner and invalid mount options for default box
  config.vm.synced_folder "./html", "/var/www/html",
    owner: "webadmin",
    group: "webadmin",
    create: true,
    mount_options: ["dmode=777", "fmode=666"]

  # Provisioning using Cloud-init user-data file
  config.vm.provision "file", source: "./cloud-init/user-data", destination: "/tmp/user-data"

  # Shell provisioner running bootstrap script
  # BUG #3: Relative script path points to wrong location and script lacks execution logic
  config.vm.provision "shell", path: "bootstrap.sh"
end
EOF

# Inject Broken cloud-init user-data (Contains YAML formatting bugs and invalid keys)
# Note: Real tabs '\t' are injected deliberately to break YAML parser
cat << 'EOF' > "${LAB_DIR}/cloud-init/user-data"
#cloud-config

hostname: web-node-01
fqdn: web-node-01.production.local
manage_etc_hosts: true

users:
  - name: devops
    gecos: DevOps Automation User
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
	# BUG #4: The line above uses TAB characters for indentation (\t) which violates YAML spec
    ssh_authorized_keys:
      # BUG #5: ssh_authorized_keys expected a list of strings, but given an invalid key format string
      ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3... devops@controlplane

packages:
  - nginx
  - curl
  - git

# BUG #6: Incorrect top-level key directive. 'run_commands' is invalid in cloud-config (must be 'runcmd')
run_commands:
  - systemctl enable --now nginx
  - cp /tmp/user-data /etc/cloud/cloud.cfg.d/99-custom-user-data.cfg
EOF

# Inject Broken Bootstrap Shell Script
cat << 'EOF' > "${LAB_DIR}/scripts/bootstrap.sh"
#!/usr/bin/env bash
set -e

echo "[*] Running VM Bootstrap Script..."

# BUG #7: User 'webadmin' does not exist yet when chown is executed
chown -R webadmin:webadmin /var/www/html

# Validate nginx configuration
nginx -t && systemctl reload nginx
EOF

chmod 644 "${LAB_DIR}/scripts/bootstrap.sh"

cat << EOF

======================================================================
 [!] BREAK & FIX LAB ENVIRONMENT READY
======================================================================
 Lab Location: ${LAB_DIR}
 Exam Topic:   LPI 701-100 Topic 3.1 (Virtual Machine Deployment)

 SCENARIO DESCRIPTION:
 You are deployed to configure an automated Virtual Machine deployment pipeline
 using Vagrant and Cloud-init for a production web node.
 However, the previous engineer left broken configuration files (Vagrantfile,
 cloud-init user-data, and bootstrap shell script).

 YOUR OBJECTIVES:
 1. Navigate to the lab directory: cd ${LAB_DIR}
 2. Diagnose why 'vagrant validate' and 'vagrant up' fail.
 3. Fix all Vagrantfile syntax, parameter type, synced folder, and provisioner path errors.
 4. Fix the cloud-init YAML user-data syntax errors (tab indentation, key schema).
 5. Ensure user creation, permissions, and shell script provisioning complete cleanly.
 6. Verify that 'vagrant up' succeeds, HTTP port 8080 forwards to guest port 80,
    and cloud-init provisions the node properly.

 SYMPTOMS YOU WILL ENCOUNTER:
 - 'vagrant up' throws VM provider errors regarding memory specification.
 - Synced folder mounting fails with missing user/group or mount error.
 - Cloud-init fails or produces ScannerError / YAMLError when parsing user-data.
 - Shell provisioner fails to locate or execute 'bootstrap.sh'.

 Good luck! When finished or if stuck, check the solution commented at the bottom of this script.
======================================================================
EOF

exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (LPI 701-100 TOPIC 3.1)
# ==============================================================================
#
# ROOT CAUSE ANALYSIS & DIAGNOSTICS:
#
# 1. Vagrantfile Provider Parameter Type Error (Bug #1):
#    - In Vagrant, 'vb.memory' expects an Integer representing size in Megabytes (e.g., 2048).
#    - Passing a String ("2048MB") causes VirtualBox VBoxManage command generation to fail
#      or Ruby type handling issues within Vagrant provider plugins.
#    - Diagnostic command: vagrant validate
#
# 2. Synced Folder User & Mount Options Misconfiguration (Bug #2):
#    - The Vagrantfile specifies 'owner: "webadmin", group: "webadmin"'.
#    - Standard Ubuntu base boxes do not have the 'webadmin' system user created during initial boot.
#    - Mount options 'dmode=777, fmode=666' are valid for vboxsf, but missing system users break mount.
#    - Solution: Change owner/group to 'www-data' (created by nginx) or 'vagrant' (default box user).
#
# 3. Provisioner Script Path Error (Bug #3):
#    - The Vagrantfile references 'path: "bootstrap.sh"', but the file is located at 'scripts/bootstrap.sh'.
#    - Diagnostic: 'vagrant up' fails stating script file does not exist.
#
# 4. Cloud-Init YAML Tab Indentation Syntax Error (Bug #4):
#    - The YAML specification strictly prohibits hard TAB (\t) characters for indentation.
#    - Cloud-init uses standard Python PyYAML to parse user-data during boot stage.
#    - Diagnostic inside guest VM: sudo cloud-init status --long / cat /var/log/cloud-init.log
#      Shows: "yaml.scanner.ScannerError: found character '\t' that cannot start any token"
#
# 5. Cloud-Init Invalid Schema & Directives (Bugs #5 & #6):
#    - 'ssh_authorized_keys' directive expects a YAML array of string keys under a user entry.
#    - 'run_commands' is an invalid key in cloud-config YAML. The correct key is 'runcmd'.
#
# 6. Bootstrap Script Permissions & Uncreated User (Bug #7):
#    - 'bootstrap.sh' was created with 0644 permissions (not executable) and attempts to chown
#      to non-existent user 'webadmin'.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP REPAIR INSTRUCTIONS:
# ------------------------------------------------------------------------------
#
# STEP 1: Fix Vagrantfile
# Edit /tmp/lpi_devops_topic31_lab/Vagrantfile to match the clean manifest below:
#
# ```ruby
# Vagrant.configure("2") do |config|
#   config.vm.box = "ubuntu/focal64"
#   config.vm.hostname = "web-node-01"
#
#   config.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true
#   config.vm.network "private_network", ip: "192.168.56.100"
#
#   config.vm.provider "virtualbox" do |vb|
#     vb.name = "lpi-701-web-node"
#     vb.memory = 2048  # Fixed: Integer 2048 instead of string "2048MB"
#     vb.cpus = 2
#   end
#
#   # Fixed: Owner and group set to standard 'vagrant' or 'www-data'
#   config.vm.synced_folder "./html", "/var/www/html",
#     owner: "vagrant",
#     group: "vagrant",
#     create: true,
#     mount_options: ["dmode=0755", "fmode=0644"]
#
#   config.vm.provision "file", source: "./cloud-init/user-data", destination: "/tmp/user-data"
#
#   # Fixed: Corrected script path
#   config.vm.provision "shell", path: "scripts/bootstrap.sh"
# end
# ```
#
# STEP 2: Fix cloud-init user-data
# Edit /tmp/lpi_devops_topic31_lab/cloud-init/user-data (Remove TABs, fix keys):
#
# ```yaml
# #cloud-config
# hostname: web-node-01
# fqdn: web-node-01.production.local
# manage_etc_hosts: true
#
# users:
#   - name: devops
#     gecos: DevOps Automation User
#     sudo: ALL=(ALL) NOPASSWD:ALL
#     shell: /bin/bash
#     ssh_authorized_keys:
#       - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3... devops@controlplane
#
# packages:
#   - nginx
#   - curl
#   - git
#
# # Fixed: Changed 'run_commands' to standard cloud-init directive 'runcmd'
# runcmd:
#   - systemctl enable --now nginx
#   - cp /tmp/user-data /etc/cloud/cloud.cfg.d/99-custom-user-data.cfg
# ```
#
# STEP 3: Fix Bootstrap Shell Script
# Edit /tmp/lpi_devops_topic31_lab/scripts/bootstrap.sh:
#
# ```bash
# #!/usr/bin/env bash
# set -e
#
# echo "[*] Running VM Bootstrap Script..."
#
# # Fixed: Ensure permissions match existing vagrant/www-data user
# chown -R vagrant:vagrant /var/www/html || chown -R www-data:www-data /var/www/html
#
# systemctl reload nginx || systemctl start nginx
# ```
# Make executable:
# chmod +x /tmp/lpi_devops_topic31_lab/scripts/bootstrap.sh
#
# STEP 4: Validate & Provision
# cd /tmp/lpi_devops_topic31_lab
# vagrant validate
# vagrant up
#
# STEP 5: Verification Commands
# vagrant status
# vagrant ssh -c "sudo cloud-init status --long"
# vagrant ssh -c "curl -s http://localhost"
# curl -I http://localhost:8080
#
# ==============================================================================