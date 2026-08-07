#!/bin/bash
# ==============================================================================
# LPI DevOps Tools Engineer (701-100) - Topic 4.1: Ansible Break & Fix Lab
# Target Environment: Disposable Lab VM (Ubuntu/Debian/RHEL)
# Author: Senior SRE & Principal Platform Architect
# Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/ansible-break-fix-lab"

echo "[+] Initializing disposable lab environment in ${LAB_DIR}..."

# Clean up previous lab iterations
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}"/{inventory,roles/webserver/{tasks,handlers,vars},group_vars,vault}

# 1. Create misconfigured ansible.cfg
cat <<'EOF' > "${LAB_DIR}/ansible.cfg"
[defaults]
inventory = ./inventory/hosts.yaml
roles_path = ./external_roles:./galaxy_roles
vault_password_file = ./vault/.vault_pass
remote_user = devops
host_key_checking = False
stdout_callback = yaml

[privilege_escalation]
become = False
become_method = sudo
become_user = root
EOF

# 2. Create vault password file with insecure permissions
echo "SuperSecretLabPass123!" > "${LAB_DIR}/vault/.vault_pass"
chmod 666 "${LAB_DIR}/vault/.vault_pass"

# 3. Create broken YAML inventory file (syntax error: missing colon on host key)
cat <<'EOF' > "${LAB_DIR}/inventory/hosts.yaml"
all:
  children:
    webservers:
      hosts:
        localhost:
          ansible_connection: local
          ansible_python_interpreter: /usr/bin/python3
        app_node_01
          ansible_host: 127.0.0.1
EOF

# 4. Create role task with handler mismatch
cat <<'EOF' > "${LAB_DIR}/roles/webserver/tasks/main.yml"
---
- name: Ensure Nginx package is present
  ansible.builtin.package:
    name: nginx
    state: present

- name: Deploy web application configuration
  ansible.builtin.copy:
    content: "server { listen 8080; location / { return 200 'OK'; } }"
    dest: /etc/nginx/conf.d/app.conf
    owner: root
    group: root
    mode: '0644'
  notify: Restart_Nginx_Service
EOF

# 5. Create role handler file
cat <<'EOF' > "${LAB_DIR}/roles/webserver/handlers/main.yml"
---
- name: Restart Nginx Service
  ansible.builtin.service:
    name: nginx
    state: restarted
EOF

# 6. Create top-level site playbook
cat <<'EOF' > "${LAB_DIR}/site.yml"
---
- name: Provision Production Web Infrastructure
  hosts: webservers
  roles:
    - webserver
EOF

echo ""
echo "========================================================================"
echo "           LPI DEVOPS (701-100) TOPIC 4.1: ANSIBLE BREAK & FIX          "
echo "========================================================================"
echo "SCENARIO:"
echo "An automated deployment pipeline failed while executing Ansible playbooks"
echo "inside the lab directory: ${LAB_DIR}"
echo ""
echo "SYMPTOMS OBSERVED:"
echo "1. Parsing inventory/hosts.yaml raises a YAML syntax exception."
echo "2. Ansible cannot locate the 'webserver' role during playbook execution."
echo "3. Privilege escalation fails when writing to privileged paths (/etc/nginx)."
echo "4. Ansible throws a security warning/error regarding vault password file permissions."
echo "5. The task handler notification fails to trigger the service restart handler."
echo ""
echo "STUDENT OBJECTIVE:"
echo "Change directory to '${LAB_DIR}' and resolve all architectural,"
echo "configuration, and syntax errors until the following commands pass clean:"
echo "   ansible-playbook site.yml --syntax-check"
echo "   ansible-playbook site.yml --check"
echo "========================================================================"
echo ""

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (EXAM STUDY GUIDE & DIAGNOSTIC REASONING)
# ==============================================================================
#
# ISSUE 1: Inventory YAML Syntax Mismatch
# File: /tmp/ansible-break-fix-lab/inventory/hosts.yaml
# Diagnostic: Running 'ansible-playbook site.yml --syntax-check' throws a YAML parsing error.
# Root Cause: Key 'app_node_01' lacks a trailing colon, breaking dictionary structure.
# Fix: Update hosts.yaml to valid syntax:
#   all:
#     children:
#       webservers:
#         hosts:
#           localhost:
#             ansible_connection: local
#             ansible_python_interpreter: /usr/bin/python3
#           app_node_01:
#             ansible_host: 127.0.0.1
#
# ISSUE 2: Missing Role Path in ansible.cfg
# File: /tmp/ansible-break-fix-lab/ansible.cfg
# Diagnostic: Ansible reports 'ERROR! the role "webserver" was not found'.
# Root Cause: 'roles_path' is set to './external_roles:./galaxy_roles', omitting './roles'.
# Fix: Update 'roles_path' in ansible.cfg:
#   roles_path = ./roles:./external_roles:./galaxy_roles
#
# ISSUE 3: Privilege Escalation Disabled
# File: /tmp/ansible-break-fix-lab/ansible.cfg
# Diagnostic: System package and file management tasks fail with Permission Denied.
# Root Cause: [privilege_escalation] section has 'become = False'.
# Fix: Enable become in ansible.cfg:
#   [privilege_escalation]
#   become = True
#   become_method = sudo
#   become_user = root
#
# ISSUE 4: Insecure Vault Password File Permissions
# File: /tmp/ansible-break-fix-lab/vault/.vault_pass
# Diagnostic: Ansible issues a security risk warning for vault password file permissions.
# Root Cause: File permissions are set to world-readable/writable (0666).
# Fix: Restrict POSIX file permissions:
#   chmod 600 /tmp/ansible-break-fix-lab/vault/.vault_pass
#
# ISSUE 5: Handler Notification Identifier Mismatch
# File: /tmp/ansible-break-fix-lab/roles/webserver/tasks/main.yml
# Diagnostic: Handler 'Restart Nginx Service' is never executed after config copy.
# Root Cause: Task notifies 'Restart_Nginx_Service' (underscores), while handler
#             name is defined as 'Restart Nginx Service' (spaces).
# Fix: Align notify directive string exact match in roles/webserver/tasks/main.yml:
#   notify: Restart Nginx Service
#
# VERIFICATION COMMANDS:
#   cd /tmp/ansible-break-fix-lab
#   ansible-playbook site.yml --syntax-check
#   ansible-playbook site.yml --check
# ==============================================================================