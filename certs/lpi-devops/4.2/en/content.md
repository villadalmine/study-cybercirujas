# LPI DevOps Tools Engineer (Exam 701-100)
## Topic 704.2: Other Configuration Management Tools
**Exam Weight:** 2 (Topic Weight Relative: 3.34)  
**Target Audience:** SREs, DevOps Engineers, and Platform Architects

---

### 1. Architectural Motivation & Production Problem Statement

In large-scale enterprise infrastructure, managing state across thousands of heterogeneous compute instances via imperative shell scripts introduces severe configuration drift, operational opacity, and non-deterministic deployment failures. 

Traditional configuration management addresses this via **declarative state convergence** and **idempotency**:
* **Idempotency:** A operation executed $N$ times yields the exact same system state as an operation executed once ($f(f(x)) = f(x)$).
* **State Convergence:** The configuration engine compares the *desired state* defined in continuous delivery code against the *actual state* discovered on the target host, executing only the delta mutation operations necessary to align actual state with desired state.

#### Architectural Paradigms: Pull vs. Push & Agent vs. Agentless

```
[ Centralized Server ] <--- TLS Pull (30m Interval) --- [ Node Agent (Puppet/Chef) ]
     (Catalog/Cookbook)                                        (Local Evaluation Engine)

[ CI/CD Control Plane ] --- SSH/WinRM Push (Ad-hoc) ---> [ Target Node (Ansible) ]
     (Playbooks/Modules)                                       (Ephemeral Python Exec)
```

1. **Pull Architecture (Puppet / Chef-Client):**
   * **Mechanics:** A background daemon (`puppet-agent` or `chef-client`) executes periodically (default: 30 minutes) on the target host. It gathers host state ("facts" or "attributes"), sends them to a centralized server (Puppet Server or Chef Server), receives a compiled execution plan (Catalog or Compiled Node Object), and applies state mutations locally.
   * **Production Trade-offs:** High autonomous scalability (no persistent SSH connection limits on control plane), self-healing configuration drift remediation, but requires agent lifecycle management, PKI infrastructure for mutual TLS certificate trust, and centralized server memory footprint.

2. **Push Architecture (Ansible / Chef-Solo / Puppet Apply):**
   * **Mechanics:** An orchestration machine pushes configuration instructions over transient management protocols (SSH/WinRM) or executes locally (`puppet apply`, `chef-solo`).
   * **Production Trade-offs:** Zero agent footprint on target nodes, simpler bootstrap phase, but suffers from scalability bottlenecks when pushing to tens of thousands of instances concurrently without orchestrator sharding.

---

### 2. Technical Comparison & Trade-off Matrix

| Architectural Axis | Puppet | Chef | Ansible |
| :--- | :--- | :--- | :--- |
| **Execution Model** | Declarative DSL (Puppet Code) | Imperative DSL (Ruby DSL) | Declarative / Procedural (YAML) |
| **Primary Topology** | Master/Agent (Pull) or Masterless (`puppet apply`) | Client/Server (Pull) or Local (`chef-solo`) | Control Node / Agentless (Push via SSH) |
| **State Resolution Engine** | Graph-based DAG (Directed Acyclic Graph) | Sequential Resource Collection & Execution | Sequential Playbook Task Execution |
| **Discovery Mechanism** | Facter (System Facts) | Ohai (System Attributes) | Ansible Facts (Gathers Facts) |
| **Core Abstraction Unit** | Classes, Manifests (`.pp`), Modules | Recipes (`.rb`), Cookbooks, Resources | Tasks, Roles, Playbooks (`.yml`) |
| **State Compilation** | Master compiles Manifests into JSON **Catalog** | Server merges Node Attributes & Recipes into **Node Object** | Control node renders Jinja2 templates into module params |
| **Order Guarantee** | Resource relationships (`before`, `require`, `notify`) | Linear execution order by default | Linear step-by-step top-to-bottom |
| **PKI / Trust Layer** | Built-in Puppet CA / X.509 Client Certificates | Chef Server Client Keys / RSA Keypair authentication | SSH Public Key Infrastructure / Vault |

---

### 3. Complete, Syntactically Valid Manifests & Infrastructure Configurations

#### 3.1 Puppet Enterprise Manifest: Production Nginx Web Server

Below is a complete Puppet module structure and manifest demonstrating object-oriented classes, Hiera data integration, resource attributes, and explicit dependency ordering graph nodes (`require`, `notify`).

##### Directory Structure:
```text
/etc/puppetlabs/code/environments/production/
├── manifests/
│   └── site.pp
└── modules/
    └── nginx_app/
        └── manifests/
            └── init.pp
```

##### File: `/etc/puppetlabs/code/environments/production/modules/nginx_app/manifests/init.pp`
```puppet
# Class: nginx_app
# Manages the installation, configuration, and service state of Nginx web server.
class nginx_app (
  String $package_name              = 'nginx',
  String $service_name              = 'nginx',
  String $config_path               = '/etc/nginx/nginx.conf',
  String $doc_root                  = '/var/www/html',
  Enum['running', 'stopped'] $state = 'running',
  Boolean $enable_service           = true,
) {

  # Ensure the doc root directory exists prior to configuration
  file { $doc_root:
    ensure => 'directory',
    owner  => 'www-data',
    group  => 'www-data',
    mode   => '0755',
  }

  # Manage Package Installation
  package { 'nginx_package':
    ensure => 'present',
    name   => $package_name,
  }

  # Manage Configuration File with Notification to Service
  file { 'nginx_config':
    ensure  => 'file',
    path    => $config_path,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @(CONF),
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        root /var/www/html;
        index index.html index.htm;
        server_name _;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
| CONF
    require => Package['nginx_package'],
    notify  => Service['nginx_service'],
  }

  # Manage Application Index File
  file { "${doc_root}/index.html":
    ensure  => 'file',
    owner   => 'www-data',
    group   => 'www-data',
    mode    => '0644',
    content => "<html><body><h1>Deployed via Puppet Manifest</h1></body></html>\n",
    require => File[$doc_root],
  }

  # Service Control Engine
  service { 'nginx_service':
    ensure     => $state,
    name       => $service_name,
    enable     => $enable_service,
    hasrestart => true,
    hasstatus  => true,
    require    => Package['nginx_package'],
  }
}
```

##### File: `/etc/puppetlabs/code/environments/production/manifests/site.pp`
```puppet
node default {
  include nginx_app
}
```

---

#### 3.2 Chef Standalone (Chef-Solo / Local Mode) Cookbook

Chef uses Ruby DSL to describe system resources sequentially within recipes contained in cookbooks.

##### Directory Structure:
```text
/var/chef/cookbooks/
└── webserver/
    ├── attributes/
    │   └── default.rb
    ├── metadata.rb
    ├── recipes/
    │   └── default.rb
    └── templates/
        └── nginx.conf.erb
```

##### File: `/var/chef/cookbooks/webserver/metadata.rb`
```ruby
name             'webserver'
maintainer       'SRE Platform Team'
maintainer_email 'sre@company.internal'
license          'Apache-2.0'
description      'Installs and configures production Nginx webserver'
version          '1.0.0'
chef_version     '>= 16.0'
supports         'ubuntu'
```

##### File: `/var/chef/cookbooks/webserver/attributes/default.rb`
```ruby
default['webserver']['package_name']  = 'nginx'
default['webserver']['service_name']  = 'nginx'
default['webserver']['config_path']   = '/etc/nginx/nginx.conf'
default['webserver']['doc_root']      = '/var/www/html'
default['webserver']['port']          = 80
default['webserver']['worker_conns']  = 1024
```

##### File: `/var/chef/cookbooks/webserver/templates/nginx.conf.erb`
```erb
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections <%= node['webserver']['worker_conns'] %>;
}

http {
    sendfile on;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen <%= node['webserver']['port'] %> default_server;
        root <%= node['webserver']['doc_root'] %>;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
```

##### File: `/var/chef/cookbooks/webserver/recipes/default.rb`
```ruby
# Update package repositories on Debian/Ubuntu systems
apt_update 'update_sources' do
  action :update
end

# Install Package Resource
package node['webserver']['package_name'] do
  action :install
end

# Create Web Root Directory
directory node['webserver']['doc_root'] do
  owner 'www-data'
  group 'www-data'
  mode '0755'
  recursive true
  action :create
end

# Deploy Template Resource with Service Notification
template node['webserver']['config_path'] do
  source 'nginx.conf.erb'
  owner 'root'
  group 'root'
  mode '0644'
  notifies :reload, "service[#{node['webserver']['service_name']}]", :immediately
end

# Deploy Index HTML Document
file "#{node['webserver']['doc_root']}/index.html" do
  content '<html><body><h1>Deployed via Chef Recipe</h1></body></html>'
  owner 'www-data'
  group 'www-data'
  mode '0644'
  action :create
end

# Enable and Start Service Resource
service node['webserver']['service_name'] do
  supports status: true, restart: true, reload: true
  action [:enable, :start]
end
```

##### File: `/var/chef/solo.rb`
```ruby
file_cache_path "/var/chef/cache"
cookbook_path   ["/var/chef/cookbooks"]
log_level       :info
log_location    STDOUT
```

##### File: `/var/chef/solo.json`
```json
{
  "run_list": [
    "recipe[webserver::default]"
  ]
}
```

---

### 4. Real CLI Commands & Expected Terminal Outputs

#### 4.1 Puppet CLI Diagnostics & Execution

##### Dry-run Catalog Application (`puppet apply --noop`)
Validates syntax and shows intended modifications without mutating system state:

```bash
$ puppet apply --noop --environment=production /etc/puppetlabs/code/environments/production/manifests/site.pp
```
```text
Notice: Compiled catalog for node01.production.internal in environment production in 0.18 seconds
Notice: /Stage[main]/Nginx_app/File[/var/www/html]/ensure: current_value 'absent', should be 'directory' (noop)
Notice: /Stage[main]/Nginx_app/Package[nginx_package]/ensure: current_value 'purged', should be 'present' (noop)
Notice: /Stage[main]/Nginx_app/File[nginx_config]/ensure: current_value 'absent', should be 'file' (noop)
Notice: /Stage[main]/Nginx_app/File[/var/www/html/index.html]/ensure: current_value 'absent', should be 'file' (noop)
Notice: /Stage[main]/Nginx_app/Service[nginx_service]/ensure: current_value 'stopped', should be 'running' (noop)
Notice: Class[Nginx_app]: Would have triggered 'refresh' from 1 event
Notice: Stage[main]: Would have triggered 'refresh' from 1 event
Notice: Applied catalog in 0.05 seconds
```

##### Full Puppet Execution (`puppet apply`)

```bash
$ puppet apply /etc/puppetlabs/code/environments/production/manifests/site.pp
```
```text
Notice: Compiled catalog for node01.production.internal in environment production in 0.22 seconds
Notice: /Stage[main]/Nginx_app/File[/var/www/html]/ensure: created
Notice: /Stage[main]/Nginx_app/Package[nginx_package]/ensure: created
Notice: /Stage[main]/Nginx_app/File[nginx_config]/ensure: defined content as '{sha256}a289063c5a176bfb8db1726a8d67ec7e4663806f0e6530663c0a256a06df5c76'
Notice: /Stage[main]/Nginx_app/File[/var/www/html/index.html]/ensure: created
Notice: /Stage[main]/Nginx_app/Service[nginx_service]/ensure: change from 'stopped' to 'running'
Notice: /Stage[main]/Nginx_app/Service[nginx_service]: Triggered 'refresh' from 1 event
Notice: Applied catalog in 3.41 seconds
```

##### Facter System Attribute Inspection

```bash
$ facter os.family networking.ip
```
```json
{
  "networking.ip": "192.168.1.50",
  "os.family": "Debian"
}
```

##### Puppet Agent Client-Server Run

```bash
$ puppet agent --test --debug
```
```text
Debug: Retrieving pluginfacts
Debug: Retrieving plugin
Debug: Loading facts from /var/puppet/lib/facter/custom_fact.rb
Info: Caching catalog for node01.production.internal
Info: Applying configuration version '1723015482'
Notice: Applied catalog in 0.48 seconds
```

---

#### 4.2 Chef CLI Diagnostics & Execution

##### Local Execution via `chef-solo`

```bash
$ chef-solo -c /var/chef/solo.rb -j /var/chef/solo.json
```
```text
[2026-08-07T08:30:10+00:00] INFO: Started chef-zero at http://127.0.0.1:8889 with pid 14205
[2026-08-07T08:30:10+00:00] INFO: *** Chef Infra Client 17.10.3 ***
[2026-08-07T08:30:10+00:00] INFO: Platform: x86_64-linux
[2026-08-07T08:30:10+00:00] INFO: Run List expands to [recipe[webserver::default]]
[2026-08-07T08:30:10+00:00] INFO: Starting Chef Infra Client Run for node01.production.internal
[2026-08-07T08:30:12+00:00] INFO: Processing apt_update[update_sources] action update (webserver::default line 2)
[2026-08-07T08:30:13+00:00] INFO: Processing package[nginx] action install (webserver::default line 7)
[2026-08-07T08:30:15+00:00] INFO: Processing directory[/var/www/html] action create (webserver::default line 12)
[2026-08-07T08:30:15+00:00] INFO: Processing template[/etc/nginx/nginx.conf] action create (webserver::default line 20)
[2026-08-07T08:30:15+00:00] INFO: template[/etc/nginx/nginx.conf] updated file content
[2026-08-07T08:30:15+00:00] INFO: template[/etc/nginx/nginx.conf] sending reload action to service[nginx] (immediately)
[2026-08-07T08:30:15+00:00] INFO: Processing service[nginx] action reload (webserver::default line 37)
[2026-08-07T08:30:15+00:00] INFO: service[nginx] reloaded
[2026-08-07T08:30:15+00:00] INFO: Processing file[/var/www/html/index.html] action create (webserver::default line 29)
[2026-08-07T08:30:15+00:00] INFO: Processing service[nginx] action enable (webserver::default line 37)
[2026-08-07T08:30:15+00:00] INFO: Processing service[nginx] action start (webserver::default line 37)
[2026-08-07T08:30:15+00:00] INFO: Chef Infra Client Run complete 6/7 resources updated in 05 seconds
```

##### Local Execution via `chef-client --local-mode`

```bash
$ chef-client --local-mode --override-runlist 'recipe[webserver::default]'
```
```text
[2026-08-07T08:32:00+00:00] INFO: Starting Chef Infra Client, version 17.10.3 in local mode
[2026-08-07T08:32:01+00:00] INFO: Converging 6 resources
[2026-08-07T08:32:01+00:00] INFO: Chef Infra Client Run complete 0/6 resources updated in 01 seconds
```

##### Ohai System Attribute Discovery

```bash
$ ohai platform platform_version ipaddress
```
```json
[
  "ubuntu",
  "22.04",
  "192.168.1.50"
]
```

---

### 5. Verification, Troubleshooting & Failure Diagnostics Guide

#### 5.1 Puppet Diagnostics Flowchart & Common Errors

```
                      [ Run Puppet Command ]
                                |
                   Did Catalog Compilation Succeed?
                             /        \
                          (No)        (Yes)
                           /            \
          [ Check Syntax/Graph ]      Does Execution Converge?
          - puppet parser validate       /             \
          - Check Circular Dependency  (No)           (Yes)
                                        /               \
                       [ Trace OS/Resource Error ]  [ State Verified ]
                       - Check /var/log/syslog
                       - Verify file permissions
```

##### Error 1: Catalog Compilation Failure (Dependency Cycle)
* **Symptom:**
  ```text
  Error: Could not compile catalog for node node01.production.internal: Found 1 dependency cycle:
  (File[/var/www/html] => Package[nginx_package] => File[/var/www/html])
  Cycle graph written to /var/puppet/state/graphs/cycles.dot.
  ```
* **Root Cause:** Resource dependency loop created via mutually referencing `require` or `before` meta-parameters.
* **Resolution:** Inspect relationships using `puppet parser validate` and graph visualizing tool:
  ```bash
  $ dot -Tpng /var/puppet/state/graphs/cycles.dot -o cycle.png
  ```
  Remove the circular dependency logic from manifest files.

##### Error 2: TLS Certificate Verification Failure (Master-Agent Pull)
* **Symptom:**
  ```text
  Error: Could not request certificate from CA server: SSL_connect returned=1 errno=0 state=error: certificate verify failed: [certificate revoked for puppet-master.internal]
  ```
* **Root Cause:** Time drift between agent and master, or stale client certificate on Puppet CA.
* **Resolution:**
  1. Synchronize system clocks via NTP/chrony: `$ chronyc tracking`
  2. Clear local client SSL state on node: `$ rm -rf /etc/puppetlabs/puppet/ssl`
  3. Clean certificate on Puppet Server: `$ puppetserver ca clean --certname node01.production.internal`
  4. Re-issue certificate request: `$ puppet agent -t`

---

#### 5.2 Chef Diagnostics & Common Errors

##### Error 1: Recipe Compilation Failure (Ruby Syntax Error)
* **Symptom:**
  ```text
  ================================================================================
  Recipe Compile Error in /var/chef/cookbooks/webserver/recipes/default.rb
  ================================================================================
  SyntaxError
  -----------
  /var/chef/cookbooks/webserver/recipes/default.rb:22: syntax error, unexpected end-of-input, expecting `end'
  ```
* **Root Cause:** Unclosed Ruby block (`do ... end`) inside recipe logic.
* **Resolution:** Run Ruby linter / Foodcritic / Cookstyle analysis:
  ```bash
  $ cookstyle /var/chef/cookbooks/webserver
  ```

##### Error 2: Resource Convergence Execution Failure
* **Symptom:**
  ```text
  ================================================================================
  Error Executing Resource Block
  ================================================================================
  Mixlib::ShellOut::ShellCommandFailed
  ------------------------------------
  template[/etc/nginx/nginx.conf] (webserver::default line 20) had an error:
  Errno::ENOENT: No such file or directory @ rb_sysopen - /etc/nginx/nginx.conf.tmp2026-8712
  ```
* **Root Cause:** Parent directory `/etc/nginx` does not exist prior to writing template because package resource was skipped or failed during execution.
* **Resolution:** Ensure explicit execution order in recipe or verify repository access for package installation.

---

### 6. References

* **LPI DevOps Tools Engineer Official Overview & Objectives:**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **LPI Wiki Objectives V1 (Topic 704.2):**  
  [https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1)
* **Puppet Language Specification & Architecture Docs:**  
  [https://www.puppet.com/docs/puppet/7/architecture.html](https://www.puppet.com/docs/puppet/7/architecture.html)
* **Chef Infra Documentation & Resources:**  
  [https://docs.chef.io/chef_overview/](https://docs.chef.io/chef_overview/)