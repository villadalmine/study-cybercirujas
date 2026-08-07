# LPI DevOps Tools Engineer (701-100) Study Guide
## Topic 3.1: Virtual Machine Deployment (Weight: 6.67)

---

## 1. Motivation and Production Architectural Problem

### 1.1 Context & Production Problem Statement
Modern SRE and Platform Engineering teams face a foundational architectural tension: **Immutable Infrastructure vs. Mutable Lifecycle Management**. In hybrid-cloud and enterprise virtualized environments, deploying Virtual Machines (VMs) purely through manual baseline installs or imperative shell scripts leads to severe operational risks:

1. **Configuration Drift**: Over time, VMs deployed from generic ISOs diverge in patch levels, kernel parameters, and system libraries.
2. **Cold-Boot Latency**: Dynamically installing security updates, runtime dependencies, and monitoring agents during initial boot prolongs deployment windows from seconds to tens of minutes.
3. **Hypervisor & Environment Lock-in**: Developers running desktop hypervisors (e.g., Oracle VirtualBox) often encounter "works on my machine" failures when staging and production infrastructure run on Type-1 hypervisors (e.g., KVM/QEMU managed by `libvirt`) or AWS EC2 instances.

### 1.2 Architectural Solution: The 3-Tier VM Delivery Pipeline
To resolve these challenges at scale, production architecture decouples VM creation into three distinct, deterministic lifecycle phases:

```
+------------------+      +-------------------+      +----------------------+
| 1. BUILD PHASE   |      | 2. PACKAGING      |      | 3. PROVISION PHASE   |
| (Packer)         | ---> | (Vagrant / AMI)   | ---> | (Cloud-init)         |
| Bake static image|      | Artifact Registry |      | Dynamic boot config  |
+------------------+      +-------------------+      +----------------------+
```

1. **Bake Phase (Packer)**: Automates the creation of identical, pre-hardened "Golden Images" across multiple hypervisor target formats (`qemu/kvm`, `virtualbox`, `amazon-ebs`) directly from upstream ISOs.
2. **Distribution & Local Orchestration Phase (Vagrant)**: Provides declarative, reproducible VM instances for local development, test harnesses, and CI/CD pipelines, abstracting hypervisor-specific configurations via providers.
3. **Initialization Phase (Cloud-init)**: Standardizes early-boot runtime configuration (hostname, network interfaces, SSH keys, user creation, dynamic secret fetching) without requiring image rebuilding.

---

## 2. Technical Comparisons & Trade-Off Tables

### 2.1 Virtual Machine Provisioning & Lifecycle Tools

| Criterion | HashiCorp Packer | Vagrant | Cloud-init | Terraform / Ansible |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Scope** | Static Golden Image Baking | Local/Ephemeral VM Orchestration | Runtime OS Engine Initialization | Infrastructure / Config Management |
| **Lifecycle Phase** | Pre-deployment (Build) | Local Dev / CI Test Execution | First-boot Execution | Day-1 Infra & Day-2 Config |
| **Execution Point** | Build Server / Pipeline | Local Workstation / CI Runner | Guest OS Kernel Init (`systemd`) | Master Control Plane / Agentless SSH |
| **Artifact Output** | QCOW2, VMDK, AMI, Box | Running VM Instances | Mutated Guest Operating System | Provisioned Cloud/Infra Resources |
| **State Tracking** | Stateless (Build & Destroy) | Local State (`.vagrant/`) | Local State (`/var/lib/cloud/`) | Statefile (`terraform.tfstate`) |

### 2.2 Hypervisors & Management Abstractions

| Feature / Metric | KVM / QEMU (`libvirt`) | Oracle VirtualBox (`VBoxManage`) | AWS EC2 (Nitro Hypervisor) |
| :--- | :--- | :--- | :--- |
| **Hypervisor Type** | Type-1 (Kernel-integrated) | Type-2 (Hosted) | Type-1 (Custom Bare-Metal ASIC) |
| **Target Workload** | Production Linux / Private Cloud | Local Desktop Development | Public Cloud Infrastructure |
| **Management Interface**| `virsh`, `libvirtd`, C API | `VBoxManage`, GUI | AWS CLI, EC2 API |
| **Vagrant Provider** | `vagrant-libvirt` (Plugin) | `virtualbox` (Built-in) | `vagrant-aws` (Plugin) |
| **Packer Builder** | `qemu` | `virtualbox-iso` / `virtualbox-ovf` | `amazon-ebs` / `amazon-chroot` |
| **Disk Image Formats** | QCOW2, RAW | VDI, VMDK | EBS Volumes, AMI |

### 2.3 Cloud-init Execution Stages vs. Ansible Provisioning

| Stage / Tool | Boot Timing | Typical Use Cases | Failure Handling |
| :--- | :--- | :--- | :--- |
| **`bootcmd`** | Early boot (before networking) | Storage formatting, network route setup | Blocking execution; errors stall init |
| **`write_files`** | Mid boot (disk mounted) | Injecting `/etc/` config, systemd units | Overwrites existing files if configured |
| **`runcmd`** | Late boot (after networking) | Package updates, systemd service start | Shell exit codes logged to output file |
| **Ansible Provisioner**| Post-SSH initialization | Complex orchestration, state idempotency | Task-level rollback or execution halt |

---

## 3. Production Infrastructure Manifests

### 3.1 HashiCorp Packer HCL2 Golden Image Template
This manifest (`ubuntu-2204-golden.pkr.hcl`) bakes an Ubuntu 22.04 LTS QCOW2 image for KVM/QEMU, hardens the OS, installs production agents, and outputs a Vagrant box.

```hcl
packer {
  required_version = ">= 1.8.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
    vagrant = {
      version = ">= 1.0.2"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "iso_checksum" {
  type    = string
  default = "file:https://releases.ubuntu.com/22.04/SHA256SUMS"
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso"
}

source "qemu" "ubuntu_core" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "build-ubuntu-2204"
  shutdown_command = "echo 'vagrant' | sudo -S shutdown -P now"
  disk_size        = "20480M"
  format           = "qcow2"
  accelerator      = "kvm"
  http_directory   = "http"
  ssh_username     = "vagrant"
  ssh_password     = "vagrant"
  ssh_timeout      = "20m"
  cpus             = 2
  memory           = 2048
  boot_wait        = "5s"
  boot_command     = [
    "<wait>e<wait><down><down><down><end>",
    " autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<F10>"
  ]
}

build {
  name = "production-ubuntu-golden-image"
  sources = ["source.qemu.ubuntu_core"]

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y cloud-init qemu-guest-agent curl htop net-tools",
      "sudo systemctl enable qemu-guest-agent",
      "sudo rm -f /etc/udev/rules.d/70-persistent-net.rules",
      "sudo cloud-init clean --logs --seed"
    ]
  }

  post-processor "vagrant" {
    keep_input_artifact = false
    output              = "output/ubuntu-2204-golden.box"
  }
}
```

---

### 3.2 Declarative Vagrantfile Manifest
This production-grade `Vagrantfile` configures a dual-machine topology (`web` and `db`) using hypervisor provider overrides (Libvirt & VirtualBox), custom network interfaces, synced folders, and Cloud-init user-data injection.

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vagrant.plugins = ["vagrant-libvirt"]

  # Global Box Settings
  config.vm.box = "ubuntu/jammy64"
  config.vm.box_check_update = true

  # Synced Folders Configuration (NFS for Libvirt, standard for VirtualBox)
  config.vm.synced_folder "./app", "/var/www/html", Type: "nfs",
    nfs_version: 4,
    nfs_udp: false

  # =========================================================================
  # Database Server Instance Definition
  # =========================================================================
  config.vm.define "db" do |db|
    db.vm.hostname = "db-01.internal.net"
    db.vm.network "private_network", ip: "192.168.56.10"

    # Libvirt (KVM/QEMU) Provider Settings
    db.vm.provider :libvirt do |lv, override|
      lv.memory = "2048"
      lv.cpus = 2
      lv.driver = "kvm"
      lv.storage :file, size: "10G", type: "qcow2"
    end

    # VirtualBox Fallback Provider Settings
    db.vm.provider :virtualbox do |vbox, override|
      vbox.name = "prod-db-01"
      vbox.memory = "2048"
      vbox.cpus = 2
      vbox.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end

    # Provisioner: Inline Shell script for initial database setup
    db.vm.provision "shell", inline: <<-SHELL
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y postgresql postgresql-contrib
      systemctl enable --now postgresql
    SHELL
  end

  # =========================================================================
  # Web Application Server Instance Definition
  # =========================================================================
  config.vm.define "web" do |web|
    web.vm.hostname = "web-01.internal.net"
    web.vm.network "private_network", ip: "192.168.56.11"
    web.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true

    # Injecting Cloud-init User Data during provisioning
    web.vm.provision "shell", inline: <<-SHELL
      cat <<'EOF' > /etc/cloud/cloud.cfg.d/99-custom-user-data.cfg
#cloud-config
packages:
  - nginx
runcmd:
  - systemctl enable --now nginx
EOF
      cloud-init clean --logs
      cloud-init init
      cloud-init modules --mode final
    SHELL
  end
end
```

---

### 3.3 Production Cloud-init `user-data` Manifest (`#cloud-config`)
This `#cloud-config` document provides deterministic system bootstrapping: setting host parameters, managing users and SSH access, creating custom systemd services, installing packages, and running post-boot verification steps.

```yaml
#cloud-config
hostname: node-01
fqdn: node-01.production.internal
manage_etc_hosts: true

users:
  - default
  - name: sysadmin
    gecos: System Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [users, wheel, docker]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCz7VpW... sysadmin@infrastructure.local

package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - git
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release

write_files:
  - path: /etc/sysctl.d/99-kubernetes-cri.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.ipv4.ip_forward                 = 1
      net.bridge.bridge-nf-call-ip6tables = 1

  - path: /etc/systemd/system/healthcheck.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Production Node Healthcheck Service
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/curl -s -f http://localhost/healthz || exit 1
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

bootcmd:
  - [ modprobe, overlay ]
  - [ modprobe, br_netfilter ]

runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now healthcheck.service
  - echo "Bootstrap completed successfully at $(date)" > /var/log/bootstrap.log

final_message: "System initialization complete via cloud-init after $UPTIME seconds."
```

---

## 4. Real CLI Commands and Expected Terminal Output

### 4.1 HashiCorp Packer Operations

#### Validate Packer Manifest Syntax
```bash
$ packer validate ubuntu-2204-golden.pkr.hcl
```
**Output:**
```text
The configuration is valid.
```

#### Execute Golden Image Build
```bash
$ packer build ubuntu-2204-golden.pkr.hcl
```
**Output:**
```text
production-ubuntu-golden-image.qemu.ubuntu_core: output will be in this color.

==> production-ubuntu-golden-image.qemu.ubuntu_core: Downloading ISO...
    production-ubuntu-golden-image.qemu.ubuntu_core: ISO: https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso
==> production-ubuntu-golden-image.qemu.ubuntu_core: Starting HTTP server on port 8543
==> production-ubuntu-golden-image.qemu.ubuntu_core: Starting VM, waiting for boot sequence...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Waiting 5s for boot...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Typing the boot command over VNC...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Using ssh communicator to connect: 127.0.0.1
==> production-ubuntu-golden-image.qemu.ubuntu_core: Waiting for SSH to become available...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Connected to SSH!
==> production-ubuntu-golden-image.qemu.ubuntu_core: Provisioning with shell script...
    production-ubuntu-golden-image.qemu.ubuntu_core: Get:1 http://archive.ubuntu.com/ubuntu jammy InRelease [270 kB]
    production-ubuntu-golden-image.qemu.ubuntu_core: Reading package lists... Done
    production-ubuntu-golden-image.qemu.ubuntu_core: qemu-guest-agent is already the newest version.
==> production-ubuntu-golden-image.qemu.ubuntu_core: Gracefully halting virtual machine...
==> production-ubuntu-golden-image.qemu.ubuntu_core: Running post-processor: vagrant
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Creating Vagrant box for 'qemu' provider
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Author: Vagrant
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Compression level: 6
    production-ubuntu-golden-image.qemu.ubuntu_core (vagrant): Creating box: output/ubuntu-2204-golden.box
Build 'production-ubuntu-golden-image.qemu.ubuntu_core' finished after 7 minutes 34 seconds.

==> Builds finished. The artifacts of successful builds are:
--> production-ubuntu-golden-image.qemu.ubuntu_core: VM files in directory: build-ubuntu-2204
--> production-ubuntu-golden-image.qemu.ubuntu_core: 'vagrant' provider box: output/ubuntu-2204-golden.box
```

---

### 4.2 Vagrant Operations & Lifecycle

#### Vagrant Box Management
```bash
$ vagrant box add production/ubuntu-2204 output/ubuntu-2204-golden.box
```
**Output:**
```text
==> box: Box file allocated successfully.
==> box: Adding box 'production/ubuntu-2204' (v0) for provider: qemu
    box: Downloading: file:///home/deploy/output/ubuntu-2204-golden.box
==> box: Successfully added box 'production/ubuntu-2204' (v0) for 'qemu'!
```

#### Bring Up Multi-VM Topology (Targeting Libvirt)
```bash
$ vagrant up --provider=libvirt
```
**Output:**
```text
Bring machine 'db' up with 'libvirt' provider...
Bring machine 'web' up with 'libvirt' provider...
==> db: Registering domain in libvirt's QEMU control panel...
==> db: Creating storage pool volume...
==> db: Creating domain if not exists...
==> db: Starting domain.
==> db: Waiting for domain to get an IP address...
==> db: Waiting for SSH to become available...
    db: SSH address: 192.168.121.144:22
    db: SSH username: vagrant
    db: SSH key inserted: /home/user/.vagrant.d/insecure_private_key
==> db: Forwarding ports...
==> db: Setting hostname...
==> db: Configuring and enabling network interfaces...
==> db: Running provisioner: shell...
    db: Running inline script
==> web: Registering domain in libvirt's QEMU control panel...
==> web: Starting domain.
==> web: Waiting for SSH to become available...
==> web: Forwarding ports...
    web: 80 (guest) => 8080 (host) (adapter eth0)
```

#### Inspect Active Vagrant Environments
```bash
$ vagrant status
```
**Output:**
```text
Current machine states:

db                        running (libvirt)
web                       running (libvirt)

This environment represents multiple VMs. The VMs are all listed
above along with their current state. To control a specific machine,
pass its name as an argument to `vagrant`. e.g. `vagrant up web`
```

#### Query Active Forwarded Network Ports
```bash
$ vagrant port
```
**Output:**
```text
The forwarded ports for this environment are listed below. For
details on specific machines, please run `vagrant port <machine-name>`.

web:
  80 (guest) => 8080 (host)
```

---

### 4.3 Hypervisor Inspection Commands

#### Query `libvirt` KVM Domains
```bash
$ virsh list --all
```
**Output:**
```text
 Id   Name                   State
--------------------------------------
 1    vagrant_db             running
 2    vagrant_web            running
 -    template_ubuntu_2204   shut off
```

#### Query Specific KVM Domain Architecture Metadata
```bash
$ virsh dominfo vagrant_web
```
**Output:**
```text
Id:             2
Name:           vagrant_web
UUID:           a8f34bc1-829d-4e92-b2d9-11c5e408d3e2
OS Type:        hvm
State:          running
CPU(s):         2
CPU time:       14.2s
Max memory:     2097152 KiB
Used memory:    2097152 KiB
Persistent:     yes
Autostart:      disable
Managed save:   no
Security model: apparmor
Security DOI:   0
```

#### Query Oracle VirtualBox VMs (`VBoxManage`)
```bash
$ VBoxManage list vms
```
**Output:**
```text
"prod-db-01" {5a9632eb-0c7f-4b08-9b88-df092b13c2f9}
"prod-web-01" {c2184e49-8d76-4318-971c-43f11059f13e}
```

---

## 5. Verification and Fault Diagnostics Guide

### 5.1 Cloud-init Diagnostics Framework

#### Check Execution Status & Boot Stages
```bash
$ cloud-init status --long
```
**Output:**
```text
status: done
extended_status: done
boot_status_code: enabled-by-sysv-init
last_update: Fri, 07 Aug 2026 08:30:12 +0000
detail:
DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud-net][token=nocloud]
```

#### Trace Execution Timestamps across Boot Modules
```bash
$ cloud-init analyze boot
```
**Output:**
```text
-- Boot Record 01 --
1. 00.12000s (kernel) init initialized
2. 01.45000s (user-data) unconfigured
3. 02.11000s (init-network) bring up network interfaces
4. 04.89000s (modules-config) write_files completed
5. 08.34000s (modules-final) runcmd executed successfully
Finished stage: (final) in 09.21000s
```

#### Inspection of Log Files
Primary log locations for troubleshooting:
- Main detailed trace log: `/var/log/cloud-init.log`
- Console STDOUT/STDERR output log: `/var/log/cloud-init-output.log`

```bash
$ grep -i "error" /var/log/cloud-init.log
```
**Output:**
```text
2026-08-07 08:30:05,112 - util.py[WARNING]: Failed running /var/lib/cloud/instance/scripts/runcmd-1 [1]
2026-08-07 08:30:05,115 - cc_runcmd.py[ERROR]: Script failed with return code 1
```

#### Force Cloud-init Re-execution (Debugging)
To re-run `cloud-init` without re-creating the VM instance:
```bash
# 1. Clear state metadata and logs
$ sudo cloud-init clean --logs --seed

# 2. Re-trigger stage execution
$ sudo cloud-init init
$ sudo cloud-init modules --mode=config
$ sudo cloud-init modules --mode=final
```

---

### 5.2 SRE Failure Diagnostics Decision Matrix

```
                      +---------------------------------+
                      | VM Failed Boot / Provisioning   |
                      +---------------------------------+
                                       |
           +---------------------------+---------------------------+
           |                                                       |
 [Vagrant / Hypervisor Level]                             [OS / Cloud-init Level]
           |                                                       |
+--------------------------+                             +--------------------------+
| Symptom:                 |                             | Symptom:                 |
| - SSH Timeout            |                             | - Stuck at Boot          |
| - Driver Mismatch        |                             | - Missing Services       |
| - Provider Error         |                             | - User Key Rejection     |
+--------------------------+                             +--------------------------+
           |                                                       |
           v                                                       v
+--------------------------+                             +--------------------------+
| Action:                  |                             | Action:                  |
| VAGRANT_LOG=debug        |                             | Check /var/log/          |
| virsh console <domain>   |                             | cloud-init-output.log    |
| VBoxManage showvminfo    |                             | Verify #cloud-config YAML|
+--------------------------+                             +--------------------------+
```

#### Common Failure Modes and Remediation

##### Failure Mode 1: Vagrant SSH Timeout on `vagrant up`
* **Root Cause**: The network interface configuration inside the box lost its DHCP client assignment, or hypervisor network bridge is down.
* **Diagnosis Command**:
  ```bash
  $ VAGRANT_LOG=debug vagrant up
  ```
* **KVM Console Emergency Access**:
  ```bash
  $ virsh console vagrant_web
  ```
  *(Press `Enter` to access serial TTY console and review kernel dmesg output)*.

##### Failure Mode 2: Cloud-init Invalid YAML Syntax
* **Root Cause**: Missing `#cloud-config` header on line 1, or improper space indentation.
* **Diagnosis Command**:
  ```bash
  $ cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-custom-user-data.cfg
  ```
* **Expected Output on Error**:
  ```text
  Error: Cloud-config schema errors: line 12: key 'user' is not valid under 'users'
  ```

##### Failure Mode 3: Packer Shell Provisioner Timeout
* **Root Cause**: Interactive APT prompts blocking execution indefinitely (e.g., `debconf` asking for keyboard configuration).
* **Remediation**: Pass explicit non-interactive flags inside the Packer shell block:
  ```hcl
  environment_vars = [
    "DEBIAN_FRONTEND=noninteractive",
    "NEEDRESTART_MODE=a"
  ]
  ```

---

## 6. References

- [LPI DevOps Tools Engineer Official Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- [LPI 701-100 Detailed Exam Objectives](https://wiki.lpi.org/wiki/LPIC-OT_Topic_701)
- [HashiCorp Packer Documentation](https://developer.hashicorp.com/packer/docs)
- [HashiCorp Vagrant Documentation](https://developer.hashicorp.com/vagrant/docs)
- [Cloud-init Official Documentation](https://cloudinit.readthedocs.io/en/latest/)
- [Libvirt KVM Virtualization Management Architecture](https://libvirt.org/documentation.html)