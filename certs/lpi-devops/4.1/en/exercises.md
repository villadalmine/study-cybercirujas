# LPI DevOps Tools Engineer (Exam 701-100) — Topic 4.1: Ansible Advanced Production Guide & Lab Exercises

**Target Certification:** LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)  
**Topic 4.1:** Configuration Management with Ansible  
**Weight:** 13.33  
**Official References:**
* LPI DevOps Certification Overview: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* Ansible Core Engine Architecture: [https://docs.ansible.com/ansible/latest/reference_manual/architecture.html](https://docs.ansible.com/ansible/latest/reference_manual/architecture.html)
* Ansible Inventory Design: [https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html)
* Ansible Vault Guide: [https://docs.ansible.com/ansible/latest/vault_guide/index.html](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
* Ansible Roles & Reusability: [https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html)

---

## 1. Deep Technical Architecture & Internal Mechanics

### 1.1 Architecture & Remote Execution Engine
Ansible operates on an **agentless, push-based architecture**. Unlike agent-driven models (such as Puppet or Chef) that require a persistent client daemon on managed nodes, Ansible relies on standard network protocols—primarily **OpenSSH** for Linux/Unix and **WinRM/PSRP** for Windows.

```
+-------------------------------------------------------------------------+
|                           CONTROL NODE                                  |
|                                                                         |
|  +-------------------+   +--------------------+   +------------------+  |
|  | Ansible Playbook  | --> | Jinja2 & Core Engine| --> | Module Execution |  |
|  +-------------------+   +--------------------+   |  Payload Builder |  |
|                                                   +--------+---------+  |
+------------------------------------------------------------|------------+
                                                             | (SFTP/SCP)
                                                             v
+-------------------------------------------------------------------------+
|                            MANAGED NODE                                 |
|                                                                         |
|  1. Write payload to transient path: ~/.ansible/tmp/ansible-tmp-XXX/   |
|  2. Execute Python interpreter: /usr/bin/python3 payload.py             |
|  3. Return JSON response payload via stdout over SSH                    |
|  4. Delete transient directory (or retain if ANSIBLE_KEEP_REMOTE_FILES=1)|
+-------------------------------------------------------------------------+
```

#### Execution Lifecycle Sequence
1. **Inventory Parsing & Configuration Resolution**: Ansible loads settings following a strict precedence hierarchy (`ANSIBLE_CONFIG` env var > `./ansible.cfg` > `~/.ansible.cfg` > `/etc/ansible/ansible.cfg`).
2. **Fact Gathering (`setup` module)**: If `gather_facts: true`, Ansible generates an ephemeral Python payload, transfers it via SFTP/SCP to the target's temporary directory (`~/.ansible/tmp/ansible-tmp-*`), executes it, and reads JSON-formatted system telemetry (`ansible_facts`).
3. **Module Payload Generation**: For each task, Ansible bundles module code, argument specs, and internal dependencies (like `ansible.module_utils.basic`) into a single zipped Python file (ZIP wrapper file carrying `#!/usr/bin/python`).
4. **SSH Transport & Multiplexing**: Connections use SSH connection pooling (`ControlMaster=auto -o ControlPersist=60s`) to drastically reduce handshaking overhead across serialized or parallel play executions.
5. **Execution & Cleanup**: The remote node runs the standalone payload using the remote Python interpreter (`ansible_python_interpreter`), outputs a structured JSON response to `stdout`, and deletes the remote temporary directory.

### 1.2 Architectural Trade-Offs

| Architecture Feature | Advantages | Trade-offs & Production Risks |
| :--- | :--- | :--- |
| **Agentless (SSH/Python)** | Low operational footprint; no daemon memory overhead; zero remote bootstrapping needed. | High SSH connection overhead at scale (>1,000 nodes); sensitive to SSH rate-limiting (`MaxStartups`). Requires Python on managed hosts. |
| **Push-Based Control** | Immediate execution control; no waiting for client pull intervals; easy integration with CI/CD. | Control node is a single point of failure (SPOF) during deployments; network partitions disrupt execution midway. |
| **Declarative Idempotency** | Tasks declare desired state rather than steps; safe to re-run playbooks multiple times without unintended state drift. | Imperative overrides (e.g., `command`, `shell`) bypass idempotency unless explicitly managed via `changed_when` / `creates`. |

---

## 2. Guided Production Exercises

---

### Guided Exercise 1: Multi-Environment Inventory Hierarchy & Variables Precedence

#### Scenario
You are designing a production configuration management strategy for an Enterprise E-Commerce Platform. The architecture segregates infrastructure into `staging` and `production` environments using static INI/YAML inventories combined with hierarchical `group_vars` and `host_vars`.

#### Step 1: Create the Project Directory Structure
Run the following commands on your control node:

```bash
mkdir -p enterprise_ansible/inventory/{staging,production}/group_vars
mkdir -p enterprise_ansible/inventory/{staging,production}/host_vars
cd enterprise_ansible
```

#### Step 2: Define Staging and Production Inventories
Create the production inventory at `inventory/production/hosts.yml`:

```yaml
---
all:
  children:
    webservers:
      hosts:
        web-prod-01.internal.net:
          ansible_host: 192.168.10.11
        web-prod-02.internal.net:
          ansible_host: 192.168.10.12
    dbservers:
      hosts:
        db-prod-01.internal.net:
          ansible_host: 192.168.10.21
  vars:
    ansible_user: deploy_admin
    ansible_port: 22
```

Create the staging inventory at `inventory/staging/hosts.ini`:

```ini
[webservers]
web-stage-01.internal.net ansible_host=172.16.10.11

[dbservers]
db-stage-01.internal.net ansible_host=172.16.10.21

[all:vars]
ansible_user=stage_admin
ansible_port=2222
```

#### Step 3: Configure Environment-Specific Variables (`group_vars`)
Create `inventory/production/group_vars/webservers.yml`:

```yaml
---
http_port: 443
max_clients: 500
enable_debug: false
db_endpoint: "db-prod-01.internal.net"
```

Create `inventory/staging/group_vars/webservers.yml`:

```yaml
---
http_port: 8080
max_clients: 50
enable_debug: true
db_endpoint: "db-stage-01.internal.net"
```

#### Step 4: Validate Inventory Structure via CLI
Execute `ansible-inventory` to inspect the unified graph output for production:

```bash
ansible-inventory -i inventory/production/hosts.yml --graph
```

##### Expected Output:
```text
@all:
  |--@dbservers:
  |  |--db-prod-01.internal.net
  |--@ungrouped:
  |--@webservers:
  |  |--web-prod-01.internal.net
  |  |--web-prod-02.internal.net
```

Execute `ansible-inventory` to dump variable resolution for a specific production host:

```bash
ansible-inventory -i inventory/production/hosts.yml --host web-prod-01.internal.net
```

##### Expected Output:
```json
{
    "ansible_host": "192.168.10.11",
    "ansible_port": 22,
    "ansible_user": "deploy_admin",
    "db_endpoint": "db-prod-01.internal.net",
    "enable_debug": false,
    "http_port": 443,
    "max_clients": 500
}
```

---

#### Verification Questions — Exercise 1

1. **Question 1.1**: If a variable `http_port: 80` is defined in `inventory/production/group_vars/all.yml`, and `http_port: 443` is defined in `inventory/production/group_vars/webservers.yml`, which value will apply to `web-prod-01.internal.net`, and why?
2. **Question 1.2**: In Ansible variable precedence, where does a variable defined inside a playbook task's `vars:` block rank relative to variables set inside `host_vars` files?

---

### Guided Exercise 2: Advanced Playbooks, Jinja2 Templating & Control Flow

#### Scenario
You must write a fully idempotent, production-grade playbook that deploys NGINX with dynamic virtual host configuration, custom handler execution, complex conditional logic (`when`), state registration (`register`), loop controls (`loop_control`), and failure handling (`block`/`rescue`).

#### Step 1: Create `ansible.cfg` Engine Configuration
Create `ansible.cfg` in the project root to enforce strict operational behavior:

```ini
[defaults]
inventory = ./inventory/production/hosts.yml
remote_user = deploy_admin
host_key_checking = False
stdout_callback = yaml
callbacks_enabled = timer, profile_tasks
forks = 10

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
```

#### Step 2: Write the Dynamic Jinja2 Template
Create `templates/nginx_vhost.conf.j2`:

```jinja2
# Generated by Ansible - DO NOT EDIT MANUALLY
# Host: {{ inventory_hostname }}
# Environment: {{ env_name | default('production') }}

server {
    listen {{ http_port | mandatory }};
    server_name {{ ansible_fqdn | default(inventory_hostname) }};

    access_log /var/log/nginx/{{ inventory_hostname }}_access.log;
    error_log /var/log/nginx/{{ inventory_hostname }}_error.log;

    location / {
        proxy_pass http://{{ db_endpoint }}:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }

{% if enable_debug %}
    location /stub_status {
        stub_status on;
        allow 127.0.0.1;
        deny all;
    }
{% endif %}
}
```

#### Step 3: Write the Complete Ansible Playbook
Create `site_webserver.yml`:

```yaml
---
- name: Deploy and Configure NGINX Web Tier
  hosts: webservers
  gather_facts: true
  vars:
    env_name: production
    required_packages:
      - nginx
      - curl
      - ufw

  handlers:
    - name: Reload Nginx Service
      ansible.builtin.systemd:
        name: nginx
        state: reloaded
      listen: "trigger_nginx_reload"

    - name: Restart Nginx Service
      ansible.builtin.systemd:
        name: nginx
        state: restarted
      listen: "trigger_nginx_restart"

  tasks:
    - name: Robust Package Installation with Rescue Fallback
      block:
        - name: Install required baseline packages
          ansible.builtin.apt:
            name: "{{ item }}"
            state: present
            update_cache: true
          loop: "{{ required_packages }}"
          loop_control:
            label: "Package: {{ item }}"
      rescue:
        - name: Log package installation error
          ansible.builtin.debug:
            msg: "APT installation failed. Attempting repository repair."

        - name: Fix broken APT dependencies
          ansible.builtin.command: apt-get install -f -y
          changed_when: true

        - name: Retry package installation
          ansible.builtin.apt:
            name: "{{ required_packages }}"
            state: present

    - name: Generate Virtual Host Configuration
      ansible.builtin.template:
        src: templates/nginx_vhost.conf.j2
        dest: /etc/nginx/sites-available/app_vhost.conf
        owner: root
        group: root
        mode: '0644'
        validate: '/usr/sbin/nginx -t -c /etc/nginx/nginx.conf'
      notify: "trigger_nginx_reload"

    - name: Enable Virtual Host Symlink
      ansible.builtin.file:
        src: /etc/nginx/sites-available/app_vhost.conf
        dest: /etc/nginx/sites-enabled/app_vhost.conf
        state: link
      notify: "trigger_nginx_reload"

    - name: Check NGINX Syntax Integrity
      ansible.builtin.command: nginx -t
      register: nginx_check
      changed_when: false
      failed_when: nginx_check.rc != 0

    - name: Ensure NGINX is Enabled and Started
      ansible.builtin.systemd:
        name: nginx
        enabled: true
        state: started
```

#### Step 4: Execute Dry-Run Syntax and Execution Checks
Perform syntax validation:

```bash
ansible-playbook site_webserver.yml --syntax-check
```

##### Expected Output:
```text
playbook: site_webserver.yml
```

Perform dry-run execution (`--check` mode) with diff display:

```bash
ansible-playbook site_webserver.yml --check --diff -i inventory/staging/hosts.ini
```

##### Expected Output (Truncated):
```text
PLAY [Deploy and Configure NGINX Web Tier] *************************************************

TASK [Gathering Facts] *********************************************************************
ok: [web-stage-01.internal.net]

TASK [Install required baseline packages] **************************************************
ok: [web-stage-01.internal.net] => (item=Package: nginx)
ok: [web-stage-01.internal.net] => (item=Package: curl)
ok: [web-stage-01.internal.net] => (item=Package: ufw)

TASK [Generate Virtual Host Configuration] *************************************************
--- before
+++ after: /home/deploy/enterprise_ansible/templates/nginx_vhost.conf.j2
@@ -0,0 +1,21 @@
+# Generated by Ansible - DO NOT EDIT MANUALLY
+# Host: web-stage-01.internal.net
+# Environment: production
+
+server {
+    listen 8080;
+    server_name web-stage-01.internal.net;
+...
changed: [web-stage-01.internal.net]

RUNNING HANDLER [Reload Nginx Service] *****************************************************
changed: [web-stage-01.internal.net]

PLAY RECAP *********************************************************************************
web-stage-01.internal.net  : ok=5    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

---

#### Verification Questions — Exercise 2

1. **Question 2.1**: If three distinct tasks in a playbook trigger the handler `notify: "trigger_nginx_reload"`, how many times will the `Reload Nginx Service` handler run during playbook execution, and at what point in the play execution lifecycle?
2. **Question 2.2**: Why is `changed_when: false` used on the `ansible.builtin.command: nginx -t` task, and what would happen to playbook idempotency if this parameter were omitted?

---

### Guided Exercise 3: Security & Secret Management using Ansible Vault

#### Scenario
Production deployments require passing sensitive database master passwords and TLS private keys without exposing credentials in plain-text git repositories. You will manage encrypted variable files using `ansible-vault` and integrate them seamlessly into playbook workflows.

#### Step 1: Create an Encrypted Secret File
Create a password file on the control node to store the Vault decryption secret securely:

```bash
echo "SuperSecretVaultKey2026!" > ~/.ansible_vault_pass
chmod 600 ~/.ansible_vault_pass
```

Create an encrypted payload file `inventory/production/group_vars/dbservers/vault.yml`:

```bash
ansible-vault create inventory/production/group_vars/dbservers/vault.yml --vault-password-file ~/.ansible_vault_pass
```

When the editor opens, paste the following YAML structure and save:

```yaml
---
vault_db_master_user: "db_admin_prod"
vault_db_master_password: "P@ssw0rd_Production_Secured_99!"
vault_api_token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30"
```

#### Step 2: Verify Encryption Status
Inspect the encrypted file directly via standard text tools to confirm plain-text strings are unreadable:

```bash
cat inventory/production/group_vars/dbservers/vault.yml
```

##### Expected Output:
```text
$ANSIBLE_VAULT;1.1;AES256
36343763373763326162393233343162343232336237303037323631333333333939316533353434
3730346162363135323937396637373336343534303437340a323334323537333230303130633230
...
```

#### Step 3: Reference Vault Variables inside Unencrypted Code
Create `inventory/production/group_vars/dbservers/vars.yml` mapping vault variables to operational properties:

```yaml
---
db_user: "{{ vault_db_master_user }}"
db_pass: "{{ vault_db_master_password }}"
db_port: 5432
```

#### Step 4: Write Playbook Utilizing Vault Secrets
Create `site_database.yml`:

```yaml
---
- name: Configure Production Database Tier
  hosts: dbservers
  gather_facts: false
  tasks:
    - name: Validate Database Credentials Binding
      ansible.builtin.debug:
        msg: "Connecting user {{ db_user }} to database with password payload length {{ db_pass | length }}"

    - name: Ensure Secret Masking in Task Logs
      ansible.builtin.no_log: true
      ansible.builtin.command:
        cmd: "echo 'Initializing DB with user {{ db_user }} and pass {{ db_pass }}'"
```

#### Step 5: Execute Playbook with Vault Decryption
Run the playbook, passing the vault password file:

```bash
ansible-playbook site_database.yml -i inventory/production/hosts.yml --vault-password-file ~/.ansible_vault_pass
```

##### Expected Output:
```text
PLAY [Configure Production Database Tier] **************************************************

TASK [Validate Database Credentials Binding] ***********************************************
ok: [db-prod-01.internal.net] => {
    "msg": "Connecting user db_admin_prod to database with password payload length 31"
}

TASK [Ensure Secret Masking in Task Logs] **************************************************
censored decision made for sensitive values: result log suppressed

PLAY RECAP *********************************************************************************
db-prod-01.internal.net    : ok=2    changed=1    unreachable=0    failed=0    skipped=0
```

---

#### Verification Questions — Exercise 3

1. **Question 3.1**: What is the purpose of setting `no_log: true` on a task that consumes decrypted `ansible-vault` variables?
2. **Question 3.2**: If a user runs `ansible-vault rekey inventory/production/group_vars/dbservers/vault.yml`, what operational change occurs within the file, and is the underlying plain-text content altered?

---

### Guided Exercise 4: Enterprise Roles and Ansible Galaxy Architecture

#### Scenario
To ensure modularity and code reuse, you are tasked with encapsulating PostgreSQL database provisioning into a standardized Ansible Role adhering to official directory layout conventions. You will also manage external role dependencies via Ansible Galaxy.

#### Step 1: Initialize Role Directory Structure
Execute `ansible-galaxy` to generate a compliant skeleton:

```bash
mkdir -p roles
ansible-galaxy role init roles/db_postgres
```

Inspect the generated directory hierarchy:

```bash
tree roles/db_postgres
```

##### Expected Output:
```text
roles/db_postgres
├── README.md
├── defaults
│   └── main.yml
├── files
├── handlers
│   └── main.yml
├── meta
│   └── main.yml
├── tasks
│   └── main.yml
├── templates
├── tests
│   ├── inventory
│   └── test.yml
└── vars
    └── main.yml
```

#### Step 2: Implement Role Logic across Structural Components
Define default lower-precedence variables in `roles/db_postgres/defaults/main.yml`:

```yaml
---
postgres_port: 5432
postgres_max_connections: 100
postgres_shared_buffers: "128MB"
```

Define role execution handlers in `roles/db_postgres/handlers/main.yml`:

```yaml
---
- name: Restart Postgres
  ansible.builtin.systemd:
    name: postgresql
    state: restarted
```

Define operational tasks in `roles/db_postgres/tasks/main.yml`:

```yaml
---
- name: Install PostgreSQL server packages
  ansible.builtin.apt:
    name:
      - postgresql
      - postgresql-contrib
    state: present
    update_cache: true

- name: Configure postgresql.conf Parameters
  ansible.builtin.lineinfile:
    path: "/etc/postgresql/14/main/postgresql.conf"
    regexp: "^#?{{ item.param }}"
    line: "{{ item.param }} = {{ item.val }}"
    state: present
  loop:
    - { param: 'port', val: '{{ postgres_port }}' }
    - { param: 'max_connections', val: '{{ postgres_max_connections }}' }
    - { param: 'shared_buffers', val: "'{{ postgres_shared_buffers }}'" }
  notify: Restart Postgres

- name: Ensure PostgreSQL service is started
  ansible.builtin.systemd:
    name: postgresql
    state: started
    enabled: true
```

#### Step 3: Define Galaxy External Dependencies (`requirements.yml`)
Create `requirements.yml` in the project root to fetch external infrastructure roles:

```yaml
---
roles:
  - name: geerlingguy.security
    version: 1.6.0
  - src: git+https://github.com/geerlingguy/ansible-role-firewall.git
    scm: git
    version: master
    name: firewall
```

#### Step 4: Install External Roles via Ansible Galaxy CLI
Run `ansible-galaxy` to install dependencies into a localized `roles/` directory:

```bash
ansible-galaxy install -r requirements.yml -p ./roles/
```

##### Expected Output:
```text
- downloading role 'security', image geerlingguy.security
- downloading role from https://github.com/geerlingguy/ansible-role-firewall.git
- extracting geerlingguy.security to /home/deploy/enterprise_ansible/roles/geerlingguy.security
- geerlingguy.security (1.6.0) was installed successfully
- firewall (master) was installed successfully
```

---

#### Verification Questions — Exercise 4

1. **Question 4.1**: What is the structural difference in variable precedence between `defaults/main.yml` and `vars/main.yml` within an Ansible role?
2. **Question 4.2**: How does Ansible determine the resolution order when both a playbook variable `postgres_port: 5433` and a role `vars/main.yml` variable `postgres_port: 5432` are defined?

---

### Guided Exercise 5: Advanced Troubleshooting, Execution Profiling & Remote Payload Debugging

#### Scenario
A task in a complex playbook is failing on a remote host during payload execution. You must apply advanced diagnostic techniques: inspecting module documentation via CLI, profiling execution bottlenecks, enabling verbose connection tracing, and retaining remote transient execution artifacts.

#### Step 1: Query Module Documentation via `ansible-doc`
Inspect interface parameters, return values, and examples for the `ansible.builtin.template` module directly in the terminal:

```bash
ansible-doc ansible.builtin.template
```

Query specific snippets for quick syntax verification:

```bash
ansible-doc -s ansible.builtin.apt
```

##### Expected Output:
```yaml
- name: Manage libcurl3 package version in the cache
  ansible.builtin.apt:
      allow_downgrade:     # Only has an effect if raw specs defined...
      autoclean:           # If yes, remove useless packages from the local repository.
      autoremove:          # If yes, remove unused dependency packages.
      cache_valid_time:    # Update the apt cache if its older than the cache_valid_time in seconds.
      dpkg_options:        # Add dpkg options to apt command.
      force:               # Force package installation.
      name:                # A list of package names, or a package name with version.
...
```

#### Step 2: Configure Performance Profiling Callbacks
Edit `ansible.cfg` to include execution profiling plugins to identify slow tasks:

```ini
[defaults]
callbacks_enabled = timer, profile_tasks, profile_roles
```

Execute `site_webserver.yml` to inspect task duration metrics:

```bash
ansible-playbook site_webserver.yml -i inventory/staging/hosts.ini
```

##### Expected Output (Profiling Footer):
```text
PLAY RECAP *********************************************************************************
web-stage-01.internal.net  : ok=5    changed=0    unreachable=0    failed=0    skipped=0

Thursday 07 August 2026  12:45:10 +0000 (0:00:00.082)       0:00:04.112 **************** 
=============================================================================== 
Install required baseline packages -------------------------------------- 2.45s
Gathering Facts --------------------------------------------------------- 1.12s
Generate Virtual Host Configuration ------------------------------------- 0.31s
Ensure NGINX is Enabled and Started ------------------------------------- 0.15s
Check NGINX Syntax Integrity -------------------------------------------- 0.08s
```

#### Step 3: Retain and Inspect Remote Execution Payloads
To diagnose python-level remote failures, instruct Ansible to bypass transient directory deletion by setting `ANSIBLE_KEEP_REMOTE_FILES=1` along with high verbosity (`-vvv`):

```bash
ANSIBLE_KEEP_REMOTE_FILES=1 ansible webservers -i inventory/staging/hosts.ini -m ping -vvv
```

##### Expected Output (Tracing Remote Artifact Path):
```text
ansible 2.15.0
  config file = /home/deploy/enterprise_ansible/ansible.cfg
  configured module search path = ['/home/deploy/.ansible/plugins/modules']
  ansible python module location = /usr/lib/python3/dist-packages/ansible
...
<172.16.10.11> ESTABLISH SSH CONNECTION FOR USER: stage_admin
<172.16.10.11> EXEC /bin/sh -c 'mkdir -p "$( echo ~/.ansible/tmp/ansible-tmp-169141231.12-991823 )" && echo "$( echo ~/.ansible/tmp/ansible-tmp-169141231.12-991823 )"'
<172.16.10.11> PUT /tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py TO /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py
<172.16.10.11> EXEC /bin/sh -c 'chmod u+x /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/ /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py'
<172.16.10.11> EXEC /bin/sh -c '/usr/bin/python3 /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py'
web-stage-01.internal.net | SUCCESS => {
    "changed": false,
    "invocation": {
        "module_args": {
            "data": "pong"
        }
    },
    "keep_remote_files": true,
    "ping": "pong"
}
```

#### Step 4: Debug Remote Payload Manually
SSH into the target host and execute the preserved `AnsiballZ` python payload manually in debug mode:

```bash
ssh -p 2222 stage_admin@172.16.10.11
python3 ~/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py explode
```

##### Expected Output:
```text
Module expanded into:
/home/stage_admin/debug_dir/ansible_module_ping.py
```

---

#### Verification Questions — Exercise 5

1. **Question 5.1**: What internal transformation does Ansible perform on module files when compiling them into an `AnsiballZ` wrapper before SSH transmission?
2. **Question 5.2**: How does setting `forks = 50` in `ansible.cfg` alter the parallel execution model of Ansible when running playbooks across 200 managed nodes?

---

## 3. Verification Answers & Comprehensive Explanations

<details>
<summary>Click to expand Answers and Detailed Explanations</summary>

### Exercise 1 Answers

* **Answer 1.1**: The value `http_port: 443` from `group_vars/webservers.yml` will apply.
  * **Architectural Explanation**: In Ansible's variable precedence hierarchy, parent group variables (`group_vars/all.yml`) have lower precedence than specific child group variables (`group_vars/webservers.yml`). Child groups inherit from parent groups but explicitly override overlapping keys.
* **Answer 1.2**: A variable defined inside a task's `vars:` block has significantly higher precedence than variables in `host_vars` files.
  * **Architectural Explanation**: Task-level variables (`task vars`) rank near the top of the 22-level precedence hierarchy (level 17), overriding inventory variables, `group_vars`, `host_vars`, play `vars`, and role variables. Only extra vars (`-e` / `--extra-vars`) outrank task-level vars.

---

### Exercise 2 Answers

* **Answer 2.1**: The handler will run **exactly once** at the very end of the play execution (after all tasks in the play complete).
  * **Architectural Explanation**: Handlers are deduplicated by name. Regardless of how many tasks notify a handler during execution, Ansible queues the notification and executes the handler once during the handler flush phase. If a task fails midway before the handler flush phase, handlers will not run unless `flush_handlers` is explicitly called or `meta: flush_handlers` is used.
* **Answer 2.2**: `changed_when: false` informs Ansible's core engine that the command execution is read-only and does not mutate target system state.
  * **Architectural Explanation**: The `command` and `shell` modules cannot natively determine state changes and default to reporting `changed: true` on exit code 0. Omitting `changed_when: false` would cause Ansible to mark the task as `changed` on every run, breaking playbook idempotency reporting and unnecessarily triggering dependent handlers down the execution graph.

---

### Exercise 3 Answers

* **Answer 3.1**: `no_log: true` instructs Ansible to sanitize and suppress task parameters, stdout, and stderr from CLI log output, syslog, and display callbacks.
  * **Architectural Explanation**: Even if a file is encrypted on disk with `ansible-vault`, once Ansible decrypts the variable in memory and passes it to a module, standard task logging would print the unencrypted secret string in plain text to standard output or CI/CD logs. Setting `no_log: true` enforces secret masking at runtime.
* **Answer 3.2**: `ansible-vault rekey` changes the underlying symmetric encryption key (or password) used to protect the payload; it does **not** alter the plain-text content.
  * **Architectural Explanation**: The command decrypts the AES-256 cipher stream using the old key in memory, generates a new salt/key derivation payload (PBKDF2/HMAC), and re-encrypts the original plain-text data structure with the new key.

---

### Exercise 4 Answers

* **Answer 4.1**: `defaults/main.yml` has the lowest variable precedence inside a role (Precedence Level 2), whereas `vars/main.yml` has a very high variable precedence (Precedence Level 15).
  * **Architectural Explanation**: `defaults/main.yml` is designed to provide fallback values easily overridden by inventory, group_vars, or play parameters. Conversely, `vars/main.yml` is designed for role-internal immutability; variables defined there override inventory `host_vars`, `group_vars`, and play `vars`.
* **Answer 4.2**: The value `postgres_port: 5432` from the role's `vars/main.yml` will take precedence over the playbook variable `postgres_port: 5433` (unless the playbook variable is set within the role invocation `vars:` block).
  * **Architectural Explanation**: Role `vars/main.yml` (Level 15) outranks standard play `vars:` definitions (Level 12). To override a role variable declared in `vars/main.yml`, an engineer must use extra vars (`-e`) or pass it directly in the task/role parameter block.

---

### Exercise 5 Answers

* **Answer 5.1**: Ansible encapsulates the module code, utility libraries (`ansible.module_utils`), and JSON parameter payload into a single, base64-encoded, zip-compressed Python script (`AnsiballZ` wrapper bundle).
  * **Architectural Explanation**: This bundling ensures that complex module dependencies are transmitted over SSH as a single payload, preventing multiple round-trip file transfers and ensuring atomic execution on the managed node.
* **Answer 5.2**: Increasing `forks = 50` allows Ansible to spawn up to 50 parallel worker processes on the control node, processing 50 managed hosts concurrently per task batch instead of the default 5.
  * **Architectural Explanation**: Ansible executes plays across hosts in parallel batches defined by `forks`. For 200 nodes with `forks = 50`, Ansible completes each task across all hosts in 4 parallel waves (batches of 50), drastically reducing total playbook execution time, provided the control node has sufficient CPU cores, memory, and SSH socket bandwidth.

</details>