# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
## Topic 3.1: Virtual Machine Deployment (Weight: 6.67)

### Official References
- **LPI DevOps Tools Engineer Overview & Objectives**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **Vagrant Official Documentation**: [https://developer.hashicorp.com/vagrant/docs](https://developer.hashicorp.com/vagrant/docs)
- **Cloud-init Official Documentation**: [https://cloudinit.readthedocs.io/en/latest/](https://cloudinit.readthedocs.io/en/latest/)

---

### Architectural Background & Internal Mechanics

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                     HOST MACHINE                                       │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                  Vagrant CLI                                     │  │
│  │   Reads Vagrantfile ──► Resolves Box Cache ──► Generates SSH & Network Specs     │  │
│  └────────────────────────┬──────────────────────────────────┬──────────────────────┘  │
│                           │                                  │                         │
│                           ▼                                  ▼                         │
│  ┌─────────────────────────────────┐               ┌────────────────────────────────┐  │
│  │  Hypervisor Provider (VirtualBox│               │   Virtual Storage Engine       │  │
│  │  / KVM-Libvirt / VMware)        │               │   Box Base Image (.vmdk / .qcow2)  │  │
│  └────────────────┬────────────────┘               └────────────────┬───────────────┘  │
└───────────────────┼─────────────────────────────────────────────────┼──────────────────┘
                    │                                                 │
                    ▼                                                 ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 GUEST VIRTUAL MACHINE                                  │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                          Early Boot & Kernel Initialization                      │  │
│  └────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                           │                                            │
│                                           ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                         Cloud-init Execution Stages (systemd)                    │  │
│  │                                                                                  │  │
│  │  1. cloud-init-local.service (Generator: Reads NoCloud / ConfigDrive metadata)   │  │
│  │  2. cloud-init.service       (Network: Applies network config & fetches remote) │  │
│  │  3. cloud-config.service     (Config: Processes write_files, users, bootcmd)    │  │
│  │  4. cloud-final.service      (Final: Executes packages, runcmd, user scripts)    │  │
│  └────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                           │                                            │
│                                           ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                      Vagrant Provisioners (Post Boot Layer)                      │  │
│  │       Shell Scripts ──► File Uploads ──► Ansible / Docker Configurations         │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Key Architecture Trade-Offs
1. **Vagrant Folder Synchronization Strategies**:
   - **VirtualBox Shared Folders (vboxfs)**: Default, no host configuration needed, but low I/O performance and lacks high-throughput file locking capabilities.
   - **NFS (Network File System)**: High performance, ideal for large codebases. Requires root access on the host (`sudoers` modification) and host-level daemon execution.
   - **Rsync**: Maximum read speed and zero host/guest runtime daemon overhead. Downside: One-way manual/triggered sync (`vagrant rsync-auto`), not real-time bi-directional binding.

2. **Cloud-init Boot Stages vs. Vagrant Provisioning**:
   - **Cloud-init**: Runs natively inside the guest OS during early boot via `systemd`. Ideal for OS-level bootstrapping (network interfaces, disk partition growth, base user accounts, early system properties).
   - **Vagrant Provisioners**: Run externally over SSH/WinRM after the VM network stack and SSH daemon are up. Ideal for environment customization, deployment workflows, and orchestrating cross-node state.

---

### Exercise 1: Multi-Machine Vagrant Topology with Advanced Synchronization & Provisioning

#### Step 1: Create a Multi-Machine Infrastructure Manifest
Create a workspace directory and define a multi-machine `Vagrantfile` deploying a load balancer (`lb01`) and two web servers (`app01`, `app02`) with isolated private networking, explicit resource caps, custom rsync options, and multi-stage provisioners.

Execute the following commands in your shell:

```bash
mkdir -p ~/sre-lab/vagrant-multi
cd ~/sre-lab/vagrant-multi
cat <<'EOF' > Vagrantfile
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.box_check_update = false

  # Global Provider Customization
  config.vm.provider "virtualbox" do |vb|
    vb.gui = false
    vb.linked_clone = true
  end

  # Web Application Nodes
  (1..2).each do |i|
    config.vm.define "app0#{i}" do |app|
      app.vm.hostname = "app0#{i}.production.internal"
      app.vm.network "private_network", ip: "192.168.56.1#{i}"
      
      app.vm.provider "virtualbox" do |vb|
        vb.memory = 1024
        vb.cpus = 1
        vb.name = "prod-app0#{i}"
      end

      # High-performance rsync folder sync configuration
      app.vm.synced_folder "./app", "/var/www/html", type: "rsync",
        rsync__args: ["--verbose", "--archive", "--delete", "-z"],
        rsync__exclude: [".git/", "node_modules/"]

      # Inline Shell Provisioner
      app.vm.provision "shell", inline: <<-SHELL
        set -euo pipefail
        apt-get update -qq
        apt-get install -y -qq nginx html2text
        echo "<h1>Node app0#{i} - Host: $(hostname)</h1>" > /var/www/html/index.html
        systemctl restart nginx
      SHELL
    end
  end

  # Load Balancer Node
  config.vm.define "lb01" do |lb|
    lb.vm.hostname = "lb01.production.internal"
    lb.vm.network "private_network", ip: "192.168.56.10"
    lb.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true

    lb.vm.provider "virtualbox" do |vb|
      vb.memory = 512
      vb.cpus = 1
      vb.name = "prod-lb01"
    end

    lb.vm.provision "shell", inline: <<-SHELL
      set -euo pipefail
      apt-get update -qq
      apt-get install -y -qq haproxy
      cat <<HAEXPR > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 2000
    user haproxy
    group haproxy

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    retries 3
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend http-in
    bind *:80
    default_backend web-backend

backend web-backend
    balance roundrobin
    server app01 192.168.56.11:80 check
    server app02 192.168.56.12:80 check
HAEXPR
      systemctl restart haproxy
    SHELL
  end
end
EOF
mkdir -p app
echo "<div>Base Application Code</div>" > app/index.html
```

#### Step 2: Provision the Multi-Machine Topology
Launch the environment and verify provisioning steps across all machines concurrently.

Execute:
```bash
vagrant up
```

Expected Output:
```text
Bringing machine 'app01' up with 'virtualbox' provider...
Bringing machine 'app02' up with 'virtualbox' provider...
Bringing machine 'lb01' up with 'virtualbox' provider...
==> app01: Importing base box 'ubuntu/focal64'...
==> app01: Matching MAC address for light network approval...
==> app01: Setting the name of the VM: prod-app01
==> app01: Clearing any previously set network interfaces...
==> app01: Preparing network interfaces based on configuration...
    app01: Adapter 1: nat
    app01: Adapter 2: hostonly
==> app01: Forwarding ports...
==> app01: Booting VM...
==> app01: Waiting for machine to boot. This may take a few minutes...
==> app01: Machine booted and ready!
==> app01: Setting hostname...
==> app01: Configuring and enabling network interfaces...
==> app01: Rsyncing folder: /home/student/sre-lab/vagrant-multi/app/ => /var/www/html
==> app01: Running provisioner: shell...
    app01: Running: inline script
...
==> lb01: Machine booted and ready!
==> lb01: Setting hostname...
==> lb01: Forwarding ports...
    lb01: 80 (guest) => 8080 (host) (adapter 1)
==> lb01: Running provisioner: shell...
    lb01: Running: inline script
```

#### Step 3: Inspect Cluster State, Port Mappings, and SSH Configurations
Run diagnostics to verify runtime parameters and extract the precise SSH configuration used by Vagrant for automated tooling integrations (e.g., Ansible/Terraform).

Execute:
```bash
vagrant status
vagrant port lb01
vagrant ssh-config app01
```

Expected Output:
```text
Current machine states:

app01                     running (virtualbox)
app02                     running (virtualbox)
lb01                      running (virtualbox)

The VMs are running. To stop this VM, you can run `vagrant halt` to
shut it down, or you can run `vagrant destroy` to delete it.

The forwarded ports for this VM are listed below. In the description column,
you can see the machine identifier and the provider identifier.

Forwarded ports list for 'lb01':
Port 80 (guest) => Port 8080 (host)

Host app01
  HostName 127.0.0.1
  User vagrant
  Port 2222
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  PasswordAuthentication no
  IdentityFile /home/student/sre-lab/vagrant-multi/.vagrant/machines/app01/virtualbox/private_key
  IdentitiesOnly yes
  LogLevel FATAL
```

#### Step 4: Verify End-to-End Load Balancing and Execute Triggered Synchronization
Validate HTTP traffic distribution through `lb01` and verify rsync folder behavior.

Execute:
```bash
curl -s http://localhost:8080
curl -s http://localhost:8080
echo "<h1>Production v2.0</h1>" > app/index.html
vagrant rsync app01
vagrant ssh app01 -c "cat /var/www/html/index.html"
```

Expected Output:
```text
<h1>Node app01 - Host: app01.production.internal</h1>
<h1>Node app02 - Host: app02.production.internal</h1>
==> app01: Rsyncing folder: /home/student/sre-lab/vagrant-multi/app/ => /var/www/html
<h1>Production v2.0</h1>
```

---

#### Verification Questions (Block 1)

1. **Question 1.1**: If you run `vagrant rsync-auto` in a terminal and then update `app/index.html`, what internal kernel mechanism on the Linux host enables Vagrant to detect file modifications, and how does this contrast with VirtualBox Shared Folders (`vboxfs`)?
2. **Question 1.2**: Inspecting `vagrant ssh-config app01` shows `HostName 127.0.0.1` and `Port 2222` instead of `192.168.56.11` and `Port 22`. Why does Vagrant default to communicating with the guest via localhost forwarded ports rather than the private network IP?
3. **Question 1.3**: In the `Vagrantfile`, `config.vm.provider "virtualbox" do |vb| vb.linked_clone = true end` is configured. What is the disk storage and performance impact of using linked clones over full clones when instantiating 10 identical nodes?

---

### Exercise 2: Cloud-Init Boot Stage Analysis & Production User-Data Provisioning

#### Step 1: Design a Production `#cloud-config` User-Data Manifest
Create a cloud-init initialization file that executes early boot setup, provisions secure system accounts, writes drop-in systemd configuration files, manages disk mount points, and runs final post-installation scripts.

Execute:
```bash
mkdir -p ~/sre-lab/cloud-init-lab
cd ~/sre-lab/cloud-init-lab

cat <<'EOF' > user-data.yaml
#cloud-config
version: v1
hostname: telemetry-node-01
fqdn: telemetry-node-01.infra.internal
manage_etc_hosts: true

# Early boot commands executed before packages or network initialization
bootcmd:
  - echo "bootcmd execution timestamp: $(date -u +%s)" >> /var/log/bootcmd-marker.log

# System Users Provisioning
users:
  - name: sysadmin
    gecos: System Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, adm]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExamplePublicKeyForLPI701DevOpsEng sysadmin@infra

# File Creation via write_files module
write_files:
  - path: /etc/systemd/system/node-exporter-health.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Node Exporter Healthcheck Service
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c 'echo "Node Exporter status: Active" > /tmp/exporter-health.log'

      [Install]
      WantedBy=multi-user.target

  - path: /etc/sysctl.d/99-custom-networking.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.core.somaxconn = 4096
      net.ipv4.tcp_tw_reuse = 1

# Package Installation
packages:
  - curl
  - jq
  - prometheus-node-exporter

# System Command Execution in cloud-final stage
runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now node-exporter-health.service
  - systemctl restart prometheus-node-exporter
  - [ sh, -c, 'echo "cloud-init completed at $(date)" > /etc/cloud-init-finished' ]
EOF
```

#### Step 2: Validate Cloud-Init Schema Syntax
Before injecting user-data into a Virtual Machine or Cloud Instance, validate its syntax against the official JSON schema engine integrated into `cloud-init`.

Execute:
```bash
cloud-init schema --config-file user-data.yaml
```

Expected Output:
```text
Valid cloud-config file user-data.yaml
```

#### Step 3: Simulate Cloud-Init Datasource Integration with Vagrant NoCloud Driver
Integrate the `user-data.yaml` manifest into a Vagrant environment using a local `NoCloud` drive layout (simulating AWS EC2 user-data or KVM Cloud-Init metadata ISOs).

Execute:
```bash
cat <<'EOF' > Vagrantfile
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.hostname = "telemetry-node-01"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = 1024
    vb.cpus = 1
  end

  # Inject cloud-init user-data using custom trigger and raw disk/file placement
  config.vm.provision "file", source: "user-data.yaml", destination: "/tmp/user-data.yaml"
  
  config.vm.provision "shell", inline: <<-SHELL
    set -euo pipefail
    mkdir -p /var/lib/cloud/seed/nocloud-net
    cp /tmp/user-data.yaml /var/lib/cloud/seed/nocloud-net/user-data
    echo "instance-id: i-local-lab-01" > /var/lib/cloud/seed/nocloud-net/meta-data
    
    # Force cloud-init re-initialization to simulate first-boot stages
    cloud-init clean --logs
    cloud-init init --local
    cloud-init init
    cloud-init modules --mode config
    cloud-init modules --mode final
  SHELL
end
EOF

vagrant up
```

Expected Output:
```text
==> default: Running provisioner: shell...
    default: Running: inline script
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'init-local' at Fri, 07 Aug 2026 04:50:00 +0000. Up 12.34 seconds.
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'init' at Fri, 07 Aug 2026 04:50:02 +0000. Up 14.56 seconds.
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'modules:config' at Fri, 07 Aug 2026 04:50:05 +0000. Up 17.89 seconds.
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'modules:final' at Fri, 07 Aug 2026 04:50:10 +0000. Up 22.11 seconds.
```

#### Step 4: Advanced Boot Stage Analysis and Execution Profiling
Inspect the internal stage execution sequence, query `cloud-init` systemd targets, and evaluate execution timestamps for each stage.

Execute:
```bash
vagrant ssh -c "cloud-init status --long"
vagrant ssh -c "cloud-init analyze boot"
vagrant ssh -c "cloud-init analyze show"
```

Expected Output:
```text
status: done
extended_status: done
boot_status_code: enabled
last_update: Fri, 07 Aug 2026 04:50:10 +0000
detail: DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud-net/][identified=true]

-- Boot Record --
  Stage 1: cloud-init-local.service started at 04:50:00 (duration: 0.85s)
  Stage 2: cloud-init.service started at 04:50:02 (duration: 2.10s)
  Stage 3: cloud-config.service started at 04:50:05 (duration: 3.24s)
  Stage 4: cloud-final.service started at 04:50:10 (duration: 5.40s)
Total time elapsed: 11.59s

-- Detail Analysis --
00:00.0000s - Generator read datasource NoCloud
00:00.8500s - Applied networking configuration
00:02.9500s - Wrote file /etc/systemd/system/node-exporter-health.service
00:03.1000s - Wrote file /etc/sysctl.d/99-custom-networking.conf
00:05.3400s - Installed packages: prometheus-node-exporter, jq, curl
00:10.7400s - Ran command: sysctl --system
00:11.5900s - Ran command: systemctl enable --now node-exporter-health.service
```

---

#### Verification Questions (Block 2)

1. **Question 2.1**: Explain the exact functional difference and execution timing between `bootcmd` and `runcmd` within the 4-stage lifecycle of cloud-init (`cloud-init-local.service` vs `cloud-final.service`).
2. **Question 2.2**: If a developer places a package installation command (`apt-get install -y nginx`) inside `bootcmd` instead of using the native `packages:` key or `runcmd:`, why will this operation fail on a standard cloud image?
3. **Question 2.3**: What diagnostic artifact files in `/var/log/` distinguish standard execution logs from stdout/stderr emitted by scripts specified under `runcmd`?

---

### Exercise 3: Advanced Diagnostic Workflows & Hybrid System Provisioning

#### Step 1: Simulate and Debug a Cloud-Init & Vagrant Provisioning Failure
Create an intentional failure scenario involving YAML syntax errors, missing systemd dependencies, and invalid provisioner paths to master diagnostic tools.

Execute:
```bash
cd ~/sre-lab/cloud-init-lab

cat <<'EOF' > broken-user-data.yaml
#cloud-config
version: v1
write_files:
  - path: /etc/broken.conf
    permissions: 0644
    owner: root:root
    content: |
      key=value
  # TAB character intentionally inserted below for syntax error failure
	bad_indentation: true
runcmd:
  - systemctl start non-existent-service.service
EOF
```

Run schema validation to capture syntax errors before deployment:

Execute:
```bash
cloud-init schema --config-file broken-user-data.yaml
```

Expected Output:
```text
Error: Cloud config schema errors: write_files.0.permissions: 644 is not of type 'string'
Line 9 Column 1: Found bad character '\t' (TAB) in indentation.
Invalid cloud-config file broken-user-data.yaml
```

#### Step 2: Fix Syntax and Debug Stage Errors via System Logs
Fix the YAML indentation, then execute the broken systemd command to analyze system-level error handling in cloud-init logs.

Execute:
```bash
cat <<'EOF' > user-data-runtime-error.yaml
#cloud-config
version: v1
runcmd:
  - systemctl start non-existent-daemon.service
EOF

# Simulate execution inside vagrant VM
vagrant ssh -c "sudo cloud-init clean --logs"
vagrant ssh -c "sudo cp /tmp/user-data.yaml /var/lib/cloud/seed/nocloud-net/user-data"
vagrant ssh -c "sudo cloud-init single --name runcmd"
```

Expected Output:
```text
...
Failed to start non-existent-daemon.service: Unit non-existent-daemon.service not found.
Unexpected error occurred handling section runcmd
```

#### Step 3: Execute Full Log Trace Extraction
Extract diagnostic details from `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log` using `grep` and system logs.

Execute:
```bash
vagrant ssh -c "sudo grep -C 3 'non-existent-daemon' /var/log/cloud-init.log"
vagrant ssh -c "sudo tail -n 20 /var/log/cloud-init-output.log"
```

Expected Output:
```text
2026-08-07 04:52:15,123 - subp.py[DEBUG]: Running command ['systemctl', 'start', 'non-existent-daemon.service'] with allowed return codes [0]
2026-08-07 04:52:15,130 - subp.py[WARNING]: Unexpected error occurred handling section runcmd: Failed running command ['systemctl', 'start', 'non-existent-daemon.service'] exit code(5)
2026-08-07 04:52:15,135 - util.py[WARNING]: Failed to run module runcmd (scripts-user in final stage)
...
Failed to start non-existent-daemon.service: Unit non-existent-daemon.service not found.
```

#### Step 4: Environment Cleanup
Destroy the lab virtual machines and remove temporary directories.

Execute:
```bash
cd ~/sre-lab/vagrant-multi && vagrant destroy -f
cd ~/sre-lab/cloud-init-lab && vagrant destroy -f
rm -rf ~/sre-lab
```

Expected Output:
```text
==> app01: Forcing shutdown of VM...
==> app01: Destroying VM and associated drives...
==> app02: Forcing shutdown of VM...
==> app02: Destroying VM and associated drives...
==> lb01: Forcing shutdown of VM...
==> lb01: Destroying VM and associated drives...
==> default: Forcing shutdown of VM...
==> default: Destroying VM and associated drives...
```

---

#### Verification Questions (Block 3)

1. **Question 3.1**: When debugging Vagrant lifecycle issues during VM instantiation (such as an SSH handshake timeout or provider initialization hang), what environment variable must be set, and how do you filter output for Vagrant's underlying interaction with VirtualBox/KVM?
2. **Question 3.2**: What is the difference between `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`?
3. **Question 3.3**: How does cloud-init ensure that `user-data` modules (like `packages` or `runcmd`) are executed **only once** on instance first-boot, and what exact command clears this state to force re-execution?

---

<details>
<summary>Answers & Deep-Dive Explanations</summary>

### Block 1 Answers

- **Answer 1.1**:
  - `vagrant rsync-auto` relies on host kernel filesystem monitoring APIs (**`inotify`** on Linux, `fsevents` on macOS, or `ReadDirectoryChangesW` on Windows). The host process opens an `inotify` watch on the local folder structure (`./app`). When a file descriptor mutation occurs, `inotify` triggers an event to Vagrant, which invokes the `rsync` binary to sync changes over SSH to the guest.
  - In contrast, VirtualBox Shared Folders (`vboxfs`) use a kernel driver module (`vboxsf`) loaded into the guest OS kernel. The guest kernel routes VFS operations directly to the VirtualBox hypervisor process via VirtualBox Guest Additions PCI device calls (`/dev/vboxguest`). `vboxfs` operates in real-time without explicit synchronization commands, but incurs high context-switch overhead across the hypervisor memory boundary during heavy read/write I/O.

- **Answer 1.2**:
  - Vagrant uses local port forwarding (`127.0.0.1:2222 -> Guest:22`) over the host NAT network adapter (Adapter 1 in VirtualBox) because NAT is guaranteed to function across all host operating systems without requiring elevated host privileges (`sudo`), custom host network adapters, or pre-existing network bridges.
  - Private networks (Host-Only interfaces) are secondary interfaces configured later in the boot sequence. Relying on host-only networks for early SSH connectivity can fail if host host-only adapters are misconfigured, blocked by host firewalls, or conflict with existing IP routes. NAT port forwarding ensures reliable default bootstrap management.

- **Answer 1.3**:
  - **Storage Impact**: A full clone duplicates the base OS disk snapshot (e.g., 2 GB base box disk $\times$ 10 VMs = 20 GB host disk usage). A linked clone creates a read-only base differential image (Master VM disk) shared across all instances, creating only small copy-on-write (CoW) delta files (`.vdi` or `.qcow2`) for each node. Storage requirement drops from 20 GB to ~2 GB + delta changes per node.
  - **Performance Impact**: Linked clones significantly decrease disk provisioning time (`vagrant up` completes in seconds instead of minutes because disk duplication is eliminated). However, all 10 nodes contend for the same shared base read storage cache on the host disk controller during heavy concurrent read operations.

---

### Block 2 Answers

- **Answer 2.1**:
  - **`bootcmd`**: Executes in Stage 1 (`cloud-init-local.service`) or early Stage 2 (`cloud-init.service`). It runs extremely early in the boot lifecycle before networking is configured, before disk expansion occurs, and before package indices are retrieved.
  - **`runcmd`**: Executes in Stage 4 (`cloud-final.service`), which runs at the end of system initialization after all network interfaces are online, system users are created, files written via `write_files` are flushed to disk, and packages defined under `packages:` have been installed.

- **Answer 2.2**:
  - Running `apt-get install -y nginx` inside `bootcmd` fails for two reasons:
    1. **Network Unavailability**: Stage 1 (`cloud-init-local.service`) runs before the network stack is initialized by `systemd-networkd` or `Netplan`, preventing access to external package repositories.
    2. **Unconfigured Storage/Mounts**: File systems or ephemeral disk partitions defined in cloud-init configuration may not be mounted yet.

- **Answer 2.3**:
  - **`/var/log/cloud-init.log`**: Contains cloud-init's structured internal python log output, module execution timings, datasource resolution details, and internal state machine transitions.
  - **`/var/log/cloud-init-output.log`**: Captures stdout and stderr streams emitted by processes spawned by cloud-init modules (e.g., standard console output from `apt-get`, output from shell commands under `runcmd`, and custom output from scripts).

---

### Block 3 Answers

- **Answer 3.1**:
  - Set the `VAGRANT_LOG=debug` environment variable (e.g., `VAGRANT_LOG=debug vagrant up`).
  - Filter VirtualBox or KVM provider low-level interaction calls by piping output through `grep`:
    ```bash
    VAGRANT_LOG=debug vagrant up 2>&1 | grep -i "VBoxManage"
    ```
  - This reveals the raw Hypervisor CLI calls (`VBoxManage modifyvm`, `VBoxManage hostonlyif`), showing exact hardware flags, lock files, or VM network binding failures.

- **Answer 3.2**:
  - `/var/log/cloud-init.log` is the core diagnostic trace log detailing *what* cloud-init attempted to execute, which modules succeeded or failed, and system traceback information.
  - `/var/log/cloud-init-output.log` is the raw console capturing *what happened during execution* of external scripts (capturing standard output/error emitted to `/dev/console` during boot stages).

- **Answer 3.3**:
  - Cloud-init tracks state execution using semaphore file flags stored in `/var/lib/cloud/instance/sem/` and `/var/lib/cloud/instances/<instance-id>/`. Once a module (e.g., `config-runcmd`) finishes successfully, a semaphore file is written. On subsequent boots, cloud-init detects these flags and skips single-run modules.
  - To force cloud-init to purge its execution history, clear cached metadata, remove logs, and reset all semaphores for re-execution on the next boot, run:
    ```bash
    sudo cloud-init clean --logs
    ```

</details>