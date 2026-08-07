# LPI DevOps Tools Engineer (Exam 701-100, v1.0)
## Topic 704.2: Other Configuration Management Tools
**Exam Weight:** 3.34 (Topic 704.2 Objective Weight: 2 out of 60 total exam weight)  
**Primary Reference:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

---

## 1. Architecture & Internal Mechanics

### 1.1 Puppet Architecture & Catalog Compilation Model

Puppet operates primarily on an **agent/server (master)** pull model or a **standalone agent (`puppet apply`)** model using a declarative Domain-Specific Language (DSL).

```
   +-------------------+                     +-------------------+
   |   Puppet Agent    |                     |   Puppet Server   |
   +-------------------+                     +-------------------+
             |                                         |
             | --- 1. Send System Facts (Facter) ----> |
             |                                         | --- 2. Parse Manifests (.pp)
             |                                         | --- 3. Evaluate Classes/Modules
             |                                         | --- 4. Build Resource DAG
             | <--- 5. Return Compiled JSON Catalog -- |
             |                                         |
             | --- 6. Enforce State (RAL) ------------ |
             | --- 7. Report Execution Summary ------> |
```

1. **Fact Collection (Facter):** The Puppet agent runs `facter` to discover node attributes (IP address, operating system, kernel version, custom facts) and sends them to the Puppet Server encoded in JSON.
2. **Manifest Parsing & AST Generation:** Puppet Server parses `.pp` manifests, evaluates logic based on incoming node facts, and generates an Abstract Syntax Tree (AST).
3. **Directed Acyclic Graph (DAG) & Catalog Compilation:** Puppet resolves class inheritance, relationships (`before`, `require`, `notify`, `subscribe`), and variables to compile a **Catalog**—a complete JSON representation of the target configuration graph containing every resource and its expected parameters.
4. **Resource Abstraction Layer (RAL):** The client receives the catalog and translates abstract resources (e.g., `package { 'nginx': ensure => installed }`) into system-native provider calls (e.g., `apt-get install`, `yum install`, or `zypper install`) via its internal RAL.
5. **State Convergence & Idempotency:** The agent inspects the current state of each resource against the catalog state. If a drift is detected, Puppet applies the exact changes required to achieve parity and submits a report to the Puppet Server.

---

### 1.2 Chef Architecture & Two-Phase Execution Lifecycle

Chef uses an imperative/declarative Ruby-based DSL operating on a **Chef Infra Server / Chef Client** model or standalone execution (`chef-apply` / `chef-client --local-mode`).

```
   +-------------------+                     +-------------------+
   |    Chef Client    |                     |    Chef Server    |
   +-------------------+                     +-------------------+
             |                                         |
             | --- 1. Authenticate & Fetch Node Object>|
             | --- 2. Run Ohai (Fact Discovery) -----> |
             | <--- 3. Download Cookbooks/Recipes ---- |
             |                                         |
   [ Phase 1: Compile Phase ]                          |
   - Evaluates Ruby code, attributes, & recipes        |
   - Constructs Resource Collection Array in memory    |
                                                       |
   [ Phase 2: Converge Phase ]                         |
   - Iterates sequentially through Resource Collection |
   - Checks provider state & executes resource updates |
   - Flushes delayed notifications (`notifies`)         |
             |                                         |
             | --- 4. Upload Updated Node Object -----> |
```

1. **Ohai Attribute Discovery:** `ohai` queries system state and constructs a multi-layered JSON structure of system attributes (`node['platform']`, `node['ipaddress']`).
2. **Two-Phase Lifecycle Execution:**
   - **Phase 1: Compile Phase:** Chef Client parses `recipes/*.rb` and evaluates standard Ruby constructs (loops, conditionals, helper methods). It instantiates resource objects without executing system changes and pushes them into an ordered `Resource Collection` array.
   - **Phase 2: Converge Phase:** Chef Client walks through the `Resource Collection` array in linear sequence. For each resource, the assigned Provider checks current state against target attributes, executes native system commands if needed, and queues deferred notifications (e.g., `notifies :restart, 'service[nginx]', :delayed`).

---

### 1.3 Technical Trade-Off Matrix

| Architectural Feature | Puppet | Chef | Ansible |
| :--- | :--- | :--- | :--- |
| **Execution Paradigm** | Pull (Daemon/Cron) or Push (`puppet apply`) | Pull (Daemon/Cron) or Push (`chef-apply`) | Push (SSH/WinRM Agentless) |
| **Language Paradigm** | Declarative DSL (HCL-like AST model) | Pure Ruby DSL (Imperative + Declarative) | YAML Declarative Playbooks |
| **Dependency Model** | Graph-based (DAG resolution via metadata) | Sequential linear array (top-to-bottom) | Sequential linear execution |
| **Fact Discovery Engine** | `facter` | `ohai` | `setup` module (Gathers Facts) |
| **State Abstraction** | Resource Abstraction Layer (RAL) | Providers (`Chef::Provider`) | Modules (`ansible.builtin.*`) |

---

## 2. Complete Syntactically Valid Manifests & Recipes

### 2.1 Production Puppet Manifest (`/etc/puppetlabs/code/environments/production/manifests/site.pp`)

```puppet
# Class definition enforcing secure webserver state
class role::webserver (
  String $package_name = 'nginx',
  String $service_name = 'nginx',
  String $port         = '8080',
) {

  # Ensure package installation via platform RAL provider
  package { 'nginx_package':
    ensure => installed,
    name   => $package_name,
    before => File['nginx_config'],
  }

  # Manage configuration file state
  file { 'nginx_config':
    ensure  => file,
    path    => '/etc/nginx/conf.d/app.conf',
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "server {\n    listen ${port};\n    server_name _;\n    location / {\n        root /var/www/html;\n        index index.html;\n    }\n}\n",
    require => Package['nginx_package'],
    notify  => Service['nginx_service'],
  }

  # Manage web root directory
  file { '/var/www/html':
    ensure => directory,
    owner  => 'www-data',
    group  => 'www-data',
    mode   => '0755',
  }

  # Enforce running service state and register subscription
  service { 'nginx_service':
    ensure     => running,
    name       => $service_name,
    enable     => true,
    hasrestart => true,
    hasstatus  => true,
    subscribe  => File['nginx_config'],
  }
}

# Node mapping applying the class
node default {
  include role::webserver
}
```

---

### 2.2 Production Chef Recipe (`/var/chef/cookbooks/webserver/recipes/default.rb`)

```ruby
# frozen_string_literal: true

# Extract platform-specific parameters from node attributes
pkg_name = node['platform_family'] == 'rhel' ? 'httpd' : 'nginx'
svc_name = node['platform_family'] == 'rhel' ? 'httpd' : 'nginx'

# Install package during Converge Phase
package 'webserver_package' do
  package_name pkg_name
  action :install
end

# Create web root directory
directory '/var/www/html' do
  owner 'www-data'
  group 'www-data'
  mode '0755'
  recursive true
  action :create
end

# Render configuration file and signal delayed service restart
file '/etc/nginx/conf.d/app.conf' do
  owner 'root'
  group 'root'
  mode '0644'
  content lazy {
    port_num = node['webserver']['listen_port'] || '8080'
    "server {\n    listen #{port_num};\n    server_name _;\n    location / {\n        root /var/www/html;\n        index index.html;\n    }\n}\n"
  }
  action :create
  notifies :restart, "service[#{svc_name}]", :delayed
end

# Define service resource with explicit actions
service svc_name do
  supports status: true, restart: true
  action [:enable, :start]
end
```

---

## 3. Real CLI Commands & Output Signatures

### 3.1 Puppet Inspection and Dry-Run CLI

#### Command 1: Fact Inspection via `facter`
```bash
facter os.family os.name architecture ipaddress
```
**Expected Output:**
```json
{
  "architecture": "x86_64",
  "ipaddress": "192.168.122.45",
  "os": {
    "family": "Debian",
    "name": "Ubuntu"
  }
}
```

#### Command 2: Resource Inspection via `puppet resource`
```bash
puppet resource service nginx
```
**Expected Output:**
```puppet
service { 'nginx':
  ensure => 'running',
  enable => 'true',
}
```

#### Command 3: Dry-run Manifest Evaluation (`puppet apply --noop`)
```bash
puppet apply --noop --verbose /etc/puppetlabs/code/environments/production/manifests/site.pp
```
**Expected Output:**
```text
Info: Loading facts
Info: Applying configuration version '1723032400'
Notice: /Stage[main]/Role::Webserver/File[nginx_config]/ensure: current_value 'absent', should be 'file' (noop)
Notice: /Stage[main]/Role::Webserver/Service[nginx_service]: Would have triggered 'refresh' from 1 event
Notice: Class[Role::Webserver]: Would have triggered 'refresh' from 1 event
Notice: Stage[main]: Would have triggered 'refresh' from 1 event
Notice: Applied catalog in 0.14 seconds
```

---

### 3.2 Chef Inspection and Execution CLI

#### Command 1: Attribute Discovery via `ohai`
```bash
ohai platform platform_version ipaddress
```
**Expected Output:**
```json
{
  "platform": "ubuntu",
  "platform_version": "22.04",
  "ipaddress": "192.168.122.45"
}
```

#### Command 2: Standalone Recipe Execution via `chef-apply`
```bash
chef-apply -e "package 'curl' do action :install end"
```
**Expected Output:**
```text
Recipe: (checksum file)
  * package[curl] action install
    - install version 7.81.0-1ubuntu1.16 of package curl
```

#### Command 3: Local Mode Execution via `chef-client --local-mode`
```bash
chef-client --local-mode --override-runlist 'recipe[webserver]'
```
**Expected Output:**
```text
[2026-08-07T08:24:44+00:00] INFO: Started chef-client in local mode
[2026-08-07T08:24:44+00:00] INFO: Processing package[webserver_package] action install
[2026-08-07T08:24:45+00:00] INFO: package[webserver_package] installed nginx version 1.18.0-0ubuntu1.4
[2026-08-07T08:24:45+00:00] INFO: Processing file[/etc/nginx/conf.d/app.conf] action create
[2026-08-07T08:24:45+00:00] INFO: file[/etc/nginx/conf.d/app.conf] updated file content
[2026-08-07T08:24:45+00:00] INFO: file[/etc/nginx/conf.d/app.conf] sending restart action to service[nginx] (delayed)
[2026-08-07T08:24:45+00:00] INFO: Processing service[nginx] action enable
[2026-08-07T08:24:45+00:00] INFO: Processing service[nginx] action start
[2026-08-07T08:24:45+00:00] INFO: Processing service[nginx] action restart
[2026-08-07T08:24:45+00:00] INFO: service[nginx] restarted
[2026-08-07T08:24:45+00:00] INFO: Chef Infra Client Run complete
```

---

## 4. Guided Hands-On Lab Exercises

### Exercise 1: Puppet Catalog Inspection, Dependency Graphing, and Dry-Run Validation

In this exercise, you will create a standalone Puppet manifest containing explicit dependency chain syntax, query the local system state with `facter` and `puppet resource`, and execute a non-destructive dry-run catalog evaluation.

#### Step 1: Create a Puppet manifest workspace
Create a directory named `/tmp/puppet_lab` and open a file named `/tmp/puppet_lab/check_sshd.pp`.

```bash
mkdir -p /tmp/puppet_lab
cat << 'EOF' > /tmp/puppet_lab/check_sshd.pp
package { 'openssh-server':
  ensure => installed,
  before => File['/tmp/puppet_lab/sshd_banner'],
}

file { '/tmp/puppet_lab/sshd_banner':
  ensure  => file,
  content => "Authorized Access Only\n",
  owner   => 'root',
  mode    => '0644',
  notify  => Service['ssh_service'],
}

service { 'ssh_service':
  ensure     => running,
  name       => $facts['os']['family'] ? {
    'RedHat' => 'sshd',
    default  => 'ssh',
  },
  enable     => true,
  hasstatus  => true,
  hasrestart => true,
}
EOF
```

#### Step 2: Query system facts using Facter
Run `facter` to evaluate the dynamic decision path used by the `$facts['os']['family']` lookup in the manifest:

```bash
facter os.family
```

#### Step 3: Inspect the live system service resource via Puppet RAL
Query the existing live configuration state of the SSH service directly through Puppet's Resource Abstraction Layer without writing code:

```bash
puppet resource service ssh || puppet resource service sshd
```

#### Step 4: Run a dry-run evaluation using `--noop`
Execute `puppet apply` in dry-run mode to compile the JSON catalog and simulate dependency ordering without modifying system state:

```bash
puppet apply --noop --verbose /tmp/puppet_lab/check_sshd.pp
```

---

#### Question 1.1
During catalog compilation in Step 4, what component translates the generic declaration `package { 'openssh-server': ensure => installed }` into native operational commands such as `apt-get install` or `yum install`?
- A) Puppet Server AST Engine
- B) Facter Provider Core
- C) Resource Abstraction Layer (RAL)
- D) Directed Acyclic Graph (DAG) Compiler

#### Question 1.2
If the file resource `/tmp/puppet_lab/sshd_banner` is updated on a node, how does Puppet enforce the ordering defined by `notify => Service['ssh_service']`?
- A) Puppet re-compiles the catalog from scratch and restarts all defined resources.
- B) Puppet executes the Service resource after the File resource and sends a refresh event to trigger a service restart.
- C) Puppet stops the Service resource before modifying the File resource, then starts it back up.
- D) Puppet immediately triggers a synchronous HTTP POST call to Puppet Server to verify license compliance.

---

### Exercise 2: Chef Two-Phase Execution Lifecycle and Lazy Evaluation Debugging

In this exercise, you will analyze the distinction between Chef's Compile Phase and Converge Phase by writing a recipe with variable mutations and lazy property evaluation.

#### Step 1: Create a Chef workspace directory
Create `/tmp/chef_lab` and open a recipe file named `/tmp/chef_lab/lifecycle.rb`.

```bash
mkdir -p /tmp/chef_lab
cat << 'EOF' > /tmp/chef_lab/lifecycle.rb
target_file = '/tmp/chef_lab/dynamic_config.txt'
run_state_var = 'INITIAL_COMPILE_VALUE'

puts "=== [COMPILE PHASE] Evaluating Ruby code. run_state_var = #{run_state_var} ==="

ruby_block 'mutate_variable_at_converge' do
  block do
    run_state_var = 'MUTATED_IN_CONVERGE_PHASE'
    puts "=== [CONVERGE PHASE] Executed ruby_block. run_state_var is now = #{run_state_var} ==="
  end
  action :run
end

file target_file do
  owner 'root'
  mode '0644'
  content lazy { "Final state: #{run_state_var}\n" }
  action :create
end
EOF
```

#### Step 2: Query system facts using Ohai
Run `ohai` to verify node operating system properties used by Chef recipes:

```bash
ohai platform platform_family
```

#### Step 3: Execute the recipe using `chef-apply`
Run `chef-apply` to observe the console logs emitted across the two distinct phases:

```bash
chef-apply /tmp/chef_lab/lifecycle.rb
```

#### Step 4: Verify generated file content
Verify that the `lazy` evaluation block successfully captured the value mutated during the Converge Phase:

```bash
cat /tmp/chef_lab/dynamic_config.txt
```

---

#### Question 2.1
What would be written to `/tmp/chef_lab/dynamic_config.txt` if the `content` property in Exercise 2, Step 1 did **NOT** use the `lazy { ... }` block wrapper?
- A) `Final state: MUTATED_IN_CONVERGE_PHASE`
- B) `Final state: INITIAL_COMPILE_VALUE`
- C) The execution would fail with a syntax error during the Compile Phase.
- D) The file would be created completely empty (0 bytes).

#### Question 2.2
Which statement accurately describes Chef's execution behavior when evaluating a standard recipe containing `package`, `template`, and `service` resources?
- A) Chef executes system shell commands line-by-line as soon as each resource block is parsed in Ruby.
- B) Chef parses all resources into a Directed Acyclic Graph (DAG) and executes them concurrently using thread pools.
- C) Chef builds an ordered Resource Collection array during the Compile Phase, then sequentially evaluates system state and applies updates during the Converge Phase.
- D) Chef uploads the recipe to the Chef Server, which compiles an immutable binary payload and pushes it back via SSH.

---

## 5. Official References

- **Linux Professional Institute (LPI):** [LPI DevOps Tools Engineer Exam 701-100 Objectives Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **Puppet Architecture & Catalog Compilation Documentation:** [Puppet Core Architecture & Catalog Compilation](https://www.puppet.com/docs/puppet/7/architecture.html)
- **Chef Infra Execution & Two-Phase Lifecycle Documentation:** [Chef Infra Client Overview & Lifecycle](https://docs.chef.io/chef_overview/)

---

<details>
<summary><strong>Answers & Solutions</strong></summary>

### Exercise 1 Answer Key

#### Question 1.1
- **Correct Answer:** **C) Resource Abstraction Layer (RAL)**
- **Explanation:** The Resource Abstraction Layer (RAL) decouples Puppet’s high-level declarative syntax (`package`) from platform-dependent package managers. It uses system facts to select the appropriate **Provider** (such as `apt`, `yum`, or `zypper`) to execute native package management commands on the target host.

#### Question 1.2
- **Correct Answer:** **B) Puppet executes the Service resource after the File resource and sends a refresh event to trigger a service restart.**
- **Explanation:** In Puppet, `notify` establishes both an execution dependency (the target resource runs after the notifying resource) and sends a refresh event. When the service resource receives this event, its provider executes its restart command (if `hasrestart => true`).

---

### Exercise 2 Answer Key

#### Question 2.1
- **Correct Answer:** **B) Final state: INITIAL_COMPILE_VALUE**
- **Explanation:** Without `lazy { ... }`, Chef evaluates the Ruby variable `run_state_var` during the **Compile Phase** when the file resource is first instantiated into memory. At that point in time, `run_state_var` holds `'INITIAL_COMPILE_VALUE'`. Wrapping the content inside `lazy` defers evaluation until the **Converge Phase**, after `ruby_block` has executed and mutated the variable to `'MUTATED_IN_CONVERGE_PHASE'`.

#### Question 2.2
- **Correct Answer:** **C) Chef builds an ordered Resource Collection array during the Compile Phase, then sequentially evaluates system state and applies updates during the Converge Phase.**
- **Explanation:** Chef strictly uses a two-phase execution lifecycle. In Phase 1 (Compile Phase), Ruby code is evaluated to populate the `Resource Collection` array. In Phase 2 (Converge Phase), Chef iterates sequentially through the array, invoking providers to inspect and align system state idempotently.
</details>