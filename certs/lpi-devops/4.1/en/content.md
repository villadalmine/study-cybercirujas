# LPI DevOps Tools Engineer (701-100) — Topic 704.1: Ansible Advanced Production Study Guide

**Target Exam:** LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)  
**Topic Weight:** 13.33 (Topic 704.1: Ansible)  
**Audience Level:** Principal Platform Architect / Senior SRE  

---

## 1. Production Motivation & Architectural Mechanics

### 1.1 The Infrastructure State Drift & Configuration Challenge
In enterprise multi-cloud environments, managed nodes naturally suffer from **configuration drift**—unintended structural divergence between running compute instances caused by manual standard-operating-procedure (SOP) executions, unversioned emergency patches, or partial script failures.

Traditional imperative shell scripts (`bash`, `python`) fail to provide reliability at scale because:
1. **Lack of State Awareness:** Executing `mkdir -p /etc/app` or `useradd appuser` repeatedly can produce side effects, append duplicate lines to configuration files, or crash upon unexpected precondition states.
2. **Brittle Error Handling:** Partial script execution leaves nodes in indeterminate states (neither dirty nor clean), requiring manual intervention to unwind changes.
3. **High Maintenance Overhead:** Imperative scripts must explicitly check current state, compute delta state, apply mutations, and verify target state across varied Linux distributions (Debian/Ubuntu `apt` vs. RHEL/Rocky `dnf/yum`).

Ansible resolves configuration drift by providing a **declarative, desired-state configuration model**. Operators define *what* state the system should occupy; Ansible’s engine calculates the diff between the live system state (discovered via facts) and the target state, applying only the necessary mutations.

```
                  +-----------------------------------+
                  |      Control Node (Ansible)       |
                  |  - Playbooks & Roles (YAML)       |
                  |  - Inventory & Variables          |
                  |  - Connection Engine (OpenSSH)    |
                  +-----------------+-----------------+
                                    |
                 SSH (Port 22) / SFTP / PSRP (No Agent)
                                    |
       +----------------------------+----------------------------+
       |                                                         |
       v                                                         v
+-----------------------+                               +-----------------------+
|  Managed Node (Web 1) |                               |  Managed Node (DB 1)  |
| - Python Runtime      |                               | - Python Runtime      |
| - Systemd Service     |                               | - PostgreSQL Service  |
| - Live /etc/ app.conf |                               | - Live /etc/ pg.conf  |
+-----------------------+                               +-----------------------+
```

---

### 1.2 Ansible Control Plane & Agentless Architecture
Ansible operates on an **agentless push architecture**. Unlike pull-based models (Puppet, Chef) or persistent agent frameworks (SaltStack), managed nodes require zero long-running daemons or background listening ports.

#### Key Architectural Prerequisites
* **Control Node:** Unix/Linux host running Python 3.9+ with `ansible-core` installed.
* **Managed Nodes:** Standard Unix/Linux host running POSIX tools, an SSH daemon (`sshd`), and Python 3.8+ (`/usr/bin/python3`). Windows targets require WinRM or PowerShell Remoting (PSRP).

#### Complete Execution Engine Lifecycle
1. **Target Resolution & Pattern Expansion:** Ansible parses the inventory (`hosts.yml` or dynamic inventory plugins), resolving target host groups (e.g., `webservers:&production:!canary`).
2. **Fact Gathering Phase (`setup` module):** Ansible establishes an OpenSSH transport session to managed nodes and executes a lightweight Python payload (`ansible.module_utils.fact_collector`) to gather system context (`ansible_facts` such as IPv4 addresses, OS family, CPU topology, kernel parameters, mount points).
3. **Template & Variable Compilation:** Ansible compiles variables (precedence hierarchy across 22 levels), evaluates Jinja2 expressions (`{{ hostvars[item]['ansible_default_ipv4']['address'] }}`), and evaluates conditional statements (`when:`).
4. **Module Payload Generation:** Ansible generates an ephemeral, self-contained Python script embedding the specific task parameters and shared utility libraries (`AnsibleModule`).
5. **Payload Transport & In-Memory Execution:** Ansible transfers the zipped Python payload over SFTP/SCP to an ephemeral temporary directory on the target host (typically `~/.ansible/tmp/ansible-tmp-XXXXX/`).
6. **Remote Execution & Result Deserialization:** The target Python interpreter executes the module payload, which writes a structured JSON string to `stdout` containing key attributes:
   * `changed`: `true` | `false`
   * `failed`: `true` | `false`
   * `rc`: return code (for command tasks)
   * `msg`: detailed contextual message
7. **Cleanup & State Aggregation:** The temporary payload directory is removed (`rm -rf`), SSH multiplexing sockets (`ControlMaster`) are preserved or closed based on configuration, and the local CLI callback plugin formats output to stdout.

---

### 1.3 Idempotency, Immutability & State Determinism
**Idempotency** is the mathematical property $f(f(x)) = f(x)$. In SRE and Platform Engineering, an idempotent operation guarantees that applying a configuration manifest once achieves the desired target state, and applying it $N$ subsequent times without external state changes yields zero side effects and identical system state (`changed=false`).

#### Native Idempotent Modules vs. Shell Wrappers
Native Ansible modules (e.g., `ansible.builtin.copy`, `ansible.builtin.systemd`, `ansible.builtin.user`) inspect remote target attributes before applying changes. If file checksums (`sha256`), service status, or user attributes match target attributes, no mutation is executed.

Raw execution modules (`ansible.builtin.command`, `ansible.builtin.shell`, `ansible.builtin.raw`) execute raw binaries on target hosts and **cannot natively infer idempotency**. By default, these modules return `changed=true` on every run.

To enforce state determinism when using command modules, SREs must declare `creates`, `removes`, `changed_when`, or `failed_when` attributes:

```yaml
- name: Extract application archive idempotently
  ansible.builtin.command:
    cmd: tar -xzf /tmp/app-v1.4.2.tar.gz -C /opt/application/
    creates: /opt/application/bin/executable_v1.4.2

- name: Re-index search engine index idempotently via CLI
  ansible.builtin.shell:
    cmd: /opt/app/bin/cli reindex --status
  register: reindex_check
  changed_when: "'REINDEX_REQUIRED' in reindex_check.stdout"
  failed_when: reindex_check.rc != 0 and reindex_check.rc != 2
```

---

### 1.4 Concurrency & Execution Engine Strategy
Ansible controls worker parallelism and target host execution ordering using two distinct architectural dials: **Forks** and **Execution Strategies**.

#### Workers and Concurrency (`forks`)
The `forks` parameter in `ansible.cfg` defines the maximum number of parallel Python worker processes spawned by the control node to manage SSH sessions simultaneously.
* **Default:** `forks = 5` (Suitable for small dev environments).
* **Enterprise Production:** `forks = 50` or higher (tuned against control node CPU cores and bandwidth: $\text{Forks} \approx 2 \times \text{CPU Cores}$).

#### Strategy Plugins
Declared in `ansible.cfg` or directly in a playbook via the `strategy:` directive:

1. `strategy: linear` (Default): Synchronous stage-gate execution. Task 1 must complete on **all** active hosts before Task 2 begins on **any** host. Slow hosts (stragglers) hold back execution across the batch.
2. `strategy: free`: Asynchronous task execution per host. Each host runs tasks through the playbook as fast as possible, independent of other hosts' progress.
3. `strategy: host_pinned`: Similar to `free`, but ensures hosts in a batch complete the entire playbook before the next set of hosts (up to `forks`) begins.

#### Rolling Updates via `serial`
To avoid taking an entire cluster offline during application deployments, the `serial` directive limits how many hosts are processed through an entire playbook tier at one time:

```yaml
- name: Rolling Upgrade Web Tier
  hosts: webservers
  serial:
    - 1        # Canary host deployment
    - "20%"    # Initial batch size
    - "100%"   # Remaining cluster nodes
  strategy: linear
  tasks:
    - name: Upgrade web application
      ansible.builtin.include_role:
        name: zero_downtime_app
```

---

## 2. Technical Comparatives & Trade-off Matrix

### 2.1 Configuration Management & Infrastructure Orchestration Architecture

| Feature / Dimension | Ansible | Terraform | Puppet | SaltStack |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Paradigm** | Configuration Management & App Deployment | Immutable Infrastructure Provisioning | System Configuration Management | Real-Time Orchestration & Configuration |
| **Execution Architecture** | Push-based via SSH/WinRM (Agentless) | Push-based via Provider APIs (Agentless) | Pull-based via `puppet-agent` daemon | Hybrid (Push/Pull via `salt-minion` ZMQ) |
| **State Storage** | State-less (Discovered at runtime via `setup` facts) | Remote State File (`.tfstate` with locking) | Central Master catalog & local cached catalog | State-less or Event-driven cached state |
| **DSL / Format** | YAML + Jinja2 Templating | HCL (HashiCorp Configuration Language) | Puppet DSL (Ruby-like declarative syntax) | YAML + Jinja2 / Python DSL |
| **Idempotency Engine** | Native module state verification | Resource Graph Dependency Engine (`tf plan`) | Resource Catalog compilation & enforcement | High-state compiler (`state.apply`) |
| **Bootstrapping Cost** | Zero on target (Requires Python + SSH only) | Zero on target (API key / Cloud credentials) | High (Requires puppet-agent PKI signing) | Medium (Requires minion package & master keys) |
| **SRE Operational Use** | OS hardening, rolling deploys, day-2 ops | Cloud VPC, IAM, K8s cluster bootstrap | Enforcing persistent desktop/VM compliance | Ultra-fast parallel command execution |

---

### 2.2 Inventory Architecture: Static vs. Dynamic Inventories

| Property | Static INI / YAML Inventory | Dynamic Inventory Plugin / Script |
| :--- | :--- | :--- |
| **Source of Truth** | Git repository / Hardcoded files | Cloud Provider API (AWS EC2, GCP, Azure, K8s) |
| **Adaptability** | Low (Requires explicit Git commits to add hosts) | High (Auto-discovers ephemeral autoscaling instances) |
| **Grouping Capability** | Manual explicit group assignment | Automatic dynamic grouping by tags, regions, VPCs |
| **Performance Overhead** | Microseconds (Local file parsing) | Network latency (API requests to Cloud Providers) |
| **Caching Support** | N/A | Supported (File-based, Redis cache with TTL) |
| **Best Used For** | Fixed bare-metal, static infrastructure, network devices | Cloud-native, autoscaled server pools, dynamic K8s nodes |

---

### 2.3 Execution Strategies: Linear vs. Free vs. Host-Pinned

| Strategy | Synchronization Model | Blast Radius Risk | Failure Impact | Ideal Use Case |
| :--- | :--- | :--- | :--- | :--- |
| `linear` | Strict barrier sync at every task | High if `serial` isn't set; low with canary `serial` | Halts execution for all hosts on barrier failure | Structural migrations, DB scheme upgrades |
| `free` | No barrier sync; hosts run independently | High; fast hosts reach destructive tasks early | Host-isolated failure; others continue | Independent node patching, log rotation, compliance |
| `host_pinned` | Batch-level host isolation up to `forks` | Medium; constrained to active batch pool | Isolates failure within active batch slot | Large scale non-interdependent application rollouts |

---

## 3. Complete Production-Grade Manifests & Infrastructure Architecture

The following manifests represent a complete, syntactically valid enterprise production setup for zero-downtime rolling application updates.

### 3.1 Hardened Control Node Configuration: `ansible.cfg`
```ini
[defaults]
inventory               = ./inventory/production
roles_path              = ./roles
remote_user             = deploy-agent
private_key_file        = ~/.ssh/id_ed25519_deploy
host_key_checking       = True
forks                   = 50
strategy                = linear
gathering               = smart
fact_caching            = jsonfile
fact_caching_connection = ./cache/facts
fact_caching_timeout    = 86400
stdout_callback         = yaml
callbacks_enabled       = ansible.posix.profile_tasks, ansible.posix.timer
timeout                 = 30
retry_files_enabled     = False
vault_identity_list     = prod@.vault_pass

[privilege_escalation]
become                  = True
become_method           = sudo
become_user             = root
become_ask_pass         = False

[ssh_connection]
ssh_args                = -o FastRemoteAuth=yes -o ControlMaster=auto -o ControlPersist=60m -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/known_hosts
pipelining              = True
scp_if_ssh              = smart
retries                 = 3
```

---

### 3.2 Dynamic & Hierarchical Inventory: `inventory/production/hosts.yml`
```yaml
---
all:
  vars:
    ansible_python_interpreter: /usr/bin/python3
    environment_tier: production
    domain_name: platform.internal
    ntp_servers:
      - 0.pool.ntp.org
      - 1.pool.ntp.org

  children:
    loadbalancers:
      hosts:
        lb01.platform.internal:
          ansible_host: 10.100.10.11
          lb_role: primary
        lb02.platform.internal:
          ansible_host: 10.100.10.12
          lb_role: secondary

    webservers:
      vars:
        app_port: 8080
        max_connections: 4096
      hosts:
        web01.platform.internal:
          ansible_host: 10.100.20.21
          rack_id: rack-a1
        web02.platform.internal:
          ansible_host: 10.100.20.22
          rack_id: rack-a2
        web03.platform.internal:
          ansible_host: 10.100.20.23
          rack_id: rack-b1

    databases:
      vars:
        db_port: 5432
      hosts:
        db01.platform.internal:
          ansible_host: 10.100.30.31
          db_role: primary
```

---

### 3.3 Vault Encrypted Data File: `inventory/production/group_vars/webservers/vault.yml`

#### Decrypted Representation (Reference Structure)
```yaml
---
vault_db_password: "SuperSecretProductionDBPassword2026!"
vault_api_jwt_secret: "e9a8f4c2b1a5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0"
```

#### Complete Syntactically Valid Encrypted File
```yaml
$ANSIBLE_VAULT;1.2;AES256;prod
63313063383838393666613337373336306534346537383637303038313437313837373732383234
6666323139353935663731343936303233373035363063620a323330366633653139393130383335
32363531303732646237666436626435343431613136363063653632343831333333333333333333
3034336136313136330a383262663964313535383566363033623930353531326432653239333230
36343535383237303131346539396338323637373539336130336437343236323439396163353431
32313638633939343734393732366164343436323431396263303839633238343736343538636437
62326533353335393738353334633731333036303632303038616138653832633833363836353664
393166343233323030303038313930323830
```

---

### 3.4 Production Role Tasks with Error Recovery: `roles/zero_downtime_app/tasks/main.yml`
```yaml
---
- name: Execute Zero Downtime Application Deployment
  block:
    - name: Deregister node from Upstream NGINX Load Balancer
      ansible.builtin.file:
        path: "/var/www/html/healthcheck.html"
        state: absent
      delegate_to: "{{ item }}"
      loop: "{{ groups['loadbalancers'] }}"
      tags: lb_drain

    - name: Wait for active connections to drain (Cool down)
      ansible.builtin.pause:
        seconds: 15
      tags: lb_drain

    - name: Ensure target application directory structure exists
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: www-data
        group: www-data
        mode: '0755'
      loop:
        - /opt/app/releases
        - /opt/app/shared/log
        - /etc/app

    - name: Render dynamic application configuration from Jinja2
      ansible.builtin.template:
        src: app.conf.j2
        dest: /etc/app/app.conf
        owner: root
        group: www-data
        mode: '0640'
        validate: '/usr/local/bin/app-cli config-check --file %s'
      notify: Restart Application Service

    - name: Deploy application binary artifact
      ansible.builtin.copy:
        src: files/app-v2.1.0-linux-amd64
        dest: /opt/app/releases/app-v2.1.0
        owner: www-data
        group: www-data
        mode: '0755'

    - name: Update current symlink to new release
      ansible.builtin.file:
        src: /opt/app/releases/app-v2.1.0
        dest: /opt/app/current
        state: link
      notify: Reload Application Service

    - name: Flush handlers to force immediate service restart/reload
      ansible.builtin.meta: flush_handlers

    - name: Validate local endpoint responsiveness
      ansible.builtin.uri:
        url: "http://127.0.0.1:{{ app_port }}/healthz"
        status_code: 200
        return_content: yes
      register: healthcheck_response
      until: "healthcheck_response.status == 200 and 'OK' in healthcheck_response.content"
      retries: 10
      delay: 3

  rescue:
    - name: CRITICAL - Emergency Rollback Initiated
      ansible.builtin.debug:
        msg: "Healthcheck failed on {{ inventory_hostname }}. Reverting symlink to previous release."

    - name: Rollback application symlink to legacy binary
      ansible.builtin.file:
        src: /opt/app/releases/app-v2.0.0
        dest: /opt/app/current
        state: link

    - name: Restart application service under rollback state
      ansible.builtin.systemd:
        name: platform-app
        state: restarted
        enabled: yes

    - name: Fail the playbook execution for current batch
      ansible.builtin.fail:
        msg: "Deployment aborted due to failed application health checks on {{ inventory_hostname }}."

  always:
    - name: Restore node into Upstream NGINX Load Balancer
      ansible.builtin.file:
        path: "/var/www/html/healthcheck.html"
        state: touch
        owner: www-data
        group: www-data
        mode: '0644'
      delegate_to: "{{ item }}"
      loop: "{{ groups['loadbalancers'] }}"
      tags: lb_drain
```

---

### 3.5 Role Handlers: `roles/zero_downtime_app/handlers/main.yml`
```yaml
---
- name: Restart Application Service
  ansible.builtin.systemd:
    name: platform-app
    state: restarted
    daemon_reload: yes

- name: Reload Application Service
  ansible.builtin.systemd:
    name: platform-app
    state: reloaded
```

---

### 3.6 Advanced Jinja2 Template: `roles/zero_downtime_app/templates/app.conf.j2`
```jinja2
# System Generated Configuration via Ansible Control Plane
# Host: {{ inventory_hostname }} | Environment: {{ environment_tier }}
# Generated At: {{ ansible_date_time.iso8601 }}

[server]
bind_address = "{{ ansible_default_ipv4.address }}"
port = {{ app_port }}
max_workers = {{ ansible_processor_vcpus * 2 }}
max_connections = {{ max_connections }}

[database]
host = "{{ hostvars[groups['databases'][0]]['ansible_host'] }}"
port = {{ hostvars[groups['databases'][0]]['db_port'] }}
name = "platform_prod"
username = "app_rw"
password = "{{ vault_db_password }}"

[upstream_clusters]
{% for host in groups['webservers'] %}
cluster_node_{{ loop.index }} = "{{ hostvars[host]['ansible_host'] }}:{{ hostvars[host]['app_port'] }}"
{% endfor %}

[features]
enable_telemetry = {% if environment_tier == 'production' %}true{% else %}false{% endif %}
jwt_secret = "{{ vault_api_jwt_secret }}"
```

---

### 3.7 Master Orchestration Playbook: `site.yml`
```yaml
---
- name: Master Infrastructure & Application Deployment
  hosts: all
  gather_facts: yes
  become: yes

  tasks:
    - name: Assert baseline operating system compatibility
      ansible.builtin.assert:
        that:
          - ansible_os_family == "RedHat" or ansible_os_family == "Debian"
          - ansible_memtotal_mb >= 2048
        fail_msg: "Host {{ inventory_hostname }} does not satisfy minimum production hardware requirements."

- name: Configure Web Application Tier
  hosts: webservers
  serial:
    - 1
    - "50%"
  vars_files:
    - inventory/production/group_vars/webservers/vault.yml

  roles:
    - role: zero_downtime_app
      tags: ["application", "deploy"]
```

---

## 4. Real CLI Executions & Terminal Outputs ($)

### 4.1 Graphing Dynamic Inventory Topology
```bash
$ ansible-inventory -i inventory/production/hosts.yml --graph
```
```text
@all:
  |--@databases:
  |  |--db01.platform.internal
  |--@loadbalancers:
  |  |--lb01.platform.internal
  |  |--lb02.platform.internal
  |--@ungrouped:
  |--@webservers:
  |  |--web01.platform.internal
  |  |--web02.platform.internal
  |  |--web03.platform.internal
```

---

### 4.2 Inline Variable Encryption via Ansible Vault
```bash
$ ansible-vault encrypt_string --vault-id prod@.vault_pass 'SuperSecretProductionDBPassword2026!' --name 'vault_db_password'
```
```text
vault_db_password: !vault |
          $ANSIBLE_VAULT;1.2;AES256;prod
          33383637303861343763323030373238323830303831323334353637383930313233343536373839
          30313233343536373839303132333435363738393031323334353637383930313233343536373839
          65396138663463326231613564366537663861396230633164326533663461356236633764386539
Encryption successful
```

---

### 4.3 Syntactical Playbook Verification
```bash
$ ansible-playbook -i inventory/production/hosts.yml site.yml --syntax-check
```
```text
playbook: site.yml
```

---

### 4.4 Dry-Run Execution with Configuration Difference Tracking
```bash
$ ansible-playbook -i inventory/production/hosts.yml site.yml --check --diff --limit "web01.platform.internal"
```
```text
PLAY [Master Infrastructure & Application Deployment] ******************************************************************

TASK [Gathering Facts] *************************************************************************************************
ok: [web01.platform.internal]

TASK [Assert baseline operating system compatibility] ******************************************************************
ok: [web01.platform.internal] => {
    "changed": false,
    "msg": "All assertions passed"
}

PLAY [Configure Web Application Tier] **********************************************************************************

TASK [Gathering Facts] *************************************************************************************************
ok: [web01.platform.internal]

TASK [zero_downtime_app : Render dynamic application configuration from Jinja2] ****************************************
--- before: /etc/app/app.conf
+++ after: /home/deploy-agent/.ansible/tmp/ansible-local-4123985x_z/app.conf.j2
@@ -4,3 +4,3 @@
 [server]
-max_connections = 1024
+max_connections = 4096

changed: [web01.platform.internal]

PLAY RECAP *************************************************************************************************************
web01.platform.internal    : ok=3    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

---

### 4.5 Targeted Execution with High Verbosity Profiling
```bash
$ ansible-playbook -i inventory/production/hosts.yml site.yml --tags "deploy" --limit "webservers[0]" -vvv
```
```text
ansible-playbook [core 2.15.2]
  config file = /home/deploy-agent/platform-infra/ansible.cfg
  configured module search path = ['/home/deploy-agent/.ansible/plugins/modules', '/usr/share/ansible/plugins/modules']
  ansible python module location = /usr/lib/python3.11/site-packages/ansible
  ansible collection location = /home/deploy-agent/.ansible/collections:/usr/share/ansible/collections
  executable location = /usr/bin/ansible-playbook
  python version = 3.11.2 (main, May 13 2023, 09:28:56) [GCC 12.2.0] (/usr/bin/python3)
  jinja version = 3.1.2
  libyaml = True
Using /home/deploy-agent/platform-infra/ansible.cfg as config file
host_list additions connected to birthday party: [u'web01.platform.internal']
parsed /home/deploy-agent/platform-infra/inventory/production/hosts.yml inventory source

PLAYBOOK: site.yml *****************************************************************************************************
1 plays in site.yml

PLAY [Configure Web Application Tier] **********************************************************************************

TASK [zero_downtime_app : Deploy application binary artifact] **********************************************************
task path: /home/deploy-agent/platform-infra/roles/zero_downtime_app/tasks/main.yml:28
<10.100.20.21> ESTABLISH SSH CONNECTION FOR USER: deploy-agent
<10.100.20.21> SSH: EXEC ssh -o FastRemoteAuth=yes -o ControlMaster=auto -o ControlPersist=60m -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/known_hosts -o KbdInteractiveAuthentication=no -o PreferredAuthentications=gssapi-with-mic,gssapi-keyex,hostbased,publickey -o PasswordAuthentication=no -o 'User="deploy-agent"' -o ConnectTimeout=30 -o 'ControlPath="/home/deploy-agent/.ansible/cp/3c41a29f87"' 10.100.20.21 '/bin/sh -c '"'"'echo ~deploy-agent && sleep 0'"'"''
<10.100.20.21> (0, b'/home/deploy-agent\n', b'')
<10.100.20.21> PUT /home/deploy-agent/platform-infra/roles/zero_downtime_app/files/app-v2.1.0-linux-amd64 TO /home/deploy-agent/.ansible/tmp/ansible-tmp-1691400000.12-8941-213/source
<10.100.20.21> SSH: EXEC sftp -b - -o FastRemoteAuth=yes -o ControlMaster=auto -o ControlPersist=60m -o StrictHostKeyChecking=yes [10.100.20.21] <<< $'put /home/deploy-agent/platform-infra/roles/zero_downtime_app/files/app-v2.1.0-linux-amd64 /home/deploy-agent/.ansible/tmp/ansible-tmp-1691400000.12-8941-213/source'
changed: [web01.platform.internal] => {
    "changed": true,
    "checksum": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "dest": "/opt/app/releases/app-v2.1.0",
    "gid": 33,
    "group": "www-data",
    "mode": "0755",
    "owner": "www-data",
    "size": 18492016,
    "state": "file",
    "uid": 33
}

Monday 07 August 2026  08:22:17 -0400 (0:00:01.842) ------- 0:00:01.842 ******* 
=============================================================================== 
zero_downtime_app : Deploy application binary artifact ------------------ 1.84s

PLAY RECAP *************************************************************************************************************
web01.platform.internal    : ok=1    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

---

## 5. Verification, Failure Diagnostics & Troubleshooting Guide

### 5.1 Diagnostic Matrix: Common Production Failures

```
                             [Ansible Failure Encountered]
                                           |
                    +----------------------+----------------------+
                    |                                             |
           [SSH / Transport Error]                       [Task Execution Error]
                    |                                             |
        +-----------+-----------+                     +-----------+-----------+
        |                       |                     |                       |
[Host Key Unverified]   [Permission Denied]     [Unreachable Host]   [Become Escalation Failed]
        |                       |                     |                       |
 Fix: Add host key to   Fix: Correct identity   Fix: ControlMaster       Fix: Check NOPASSWD in
 `known_hosts` or set    key permissions         stale socket cleanup    `/etc/sudoers` on target
 `host_key_checking=False` `chmod 600 id_rsa`    `rm -rf ~/.ansible/cp`  node for deploy user
```

| Symptom / Error | Root Cause | SRE Remediation Command / Fix |
| :--- | :--- | :--- |
| `Host key verification failed.` | The SSH host public key of the target node is not present in the control node's `known_hosts` file. | Run `ssh-keyscan -H target_ip >> ~/.ssh/known_hosts` or explicitly configure `host_key_checking = True` with strict host key pre-seeding during node provisioning. |
| `Permission denied (publickey).` | SSH daemon rejected the key presented by the control node, or file permissions on `~/.ssh` on target are too permissive. | Verify identity file path in `ansible.cfg`. Fix permissions on target: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`. |
| `Timeout (12s) waiting for privilege escalation prompt` | Target node `sudo` requires a password, but Ansible is executed without `--ask-become-pass` (`-K`) and `become_ask_pass` is set to `False`. | Configure passwordless sudo for the deployment user on target nodes via `/etc/sudoers.d/deploy-agent`: `deploy-agent ALL=(ALL) NOPASSWD: ALL`. |
| `Fatal: [host]: UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh..."}` | Stale ControlMaster multiplexing socket, target host offline, or security group dropping port 22. | Purge stale SSH sockets: `rm -rf ~/.ansible/cp/*`. Test transport independently: `ansible webservers -m ping -vvv`. |
| `ModuleFailure: No module named 'docker'` | The target host's Python environment lacks the library dependencies required by a specific Ansible module (e.g., `community.docker`). | Install dependencies on target node prior to executing module using `ansible.builtin.pip: name=docker state=present`. |

---

### 5.2 Performance Profiling & Optimization Guidelines

#### 1. Task Profile Analytics (`ansible.posix.profile_tasks`)
Enabling `profile_tasks` in `ansible.cfg` prints execution durations for every task, highlighting bottlenecks in deployment pipelines:

```ini
[defaults]
callbacks_enabled = ansible.posix.profile_tasks
```

#### 2. SSH Connection Pipelining (`pipelining = True`)
By default, Ansible transfers Python module files via SFTP/SCP to disk on the managed node, then executes them in a separate SSH invocation.  
Enabling `pipelining = True` in `ansible.cfg` executes Python modules directly over an open SSH `stdin` stream without writing temporary files to target disks, reducing network round-trips by up to **60%**.

*Requirement:* Target nodes must have `requiretty` disabled in `/etc/sudoers` (standard on modern Linux distros).

#### 3. High-Performance Fact Caching
Gathering facts takes 2-5 seconds per host per playbook run. In large environments (1,000+ hosts), configure Redis-backed persistent fact caching in `ansible.cfg`:

```ini
[defaults]
gathering               = smart
fact_caching            = redis
fact_caching_connection = 127.0.0.1:6379:0
fact_caching_timeout    = 86400
```

---

## 6. References

* **LPI DevOps Tools Engineer (701-100) Official Certification Overview & Objectives**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

* **Red Hat Ansible Core Documentation & User Guide**  
  [https://docs.ansible.com/ansible/latest/user_guide/index.html](https://docs.ansible.com/ansible/latest/user_guide/index.html)

* **Ansible Architecture & Technical Key Concepts**  
  [https://docs.ansible.com/ansible/latest/network/getting_started/basic_concepts.html](https://docs.ansible.com/ansible/latest/network/getting_started/basic_concepts.html)

* **Ansible Inventory Plugins & Dynamic Sources Guide**  
  [https://docs.ansible.com/ansible/latest/plugins/inventory.html](https://docs.ansible.com/ansible/latest/plugins/inventory.html)

* **Ansible Playbook Best Practices & Sample Architectural Layouts**  
  [https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)

* **Ansible Vault User Guide & Encryption Security Protocols**  
  [https://docs.ansible.com/ansible/latest/vault_guide/index.html](https://docs.ansible.com/ansible/latest/vault_guide/index.html)