# LPIC-3 Exam 305-300 (v3.0) — Topic 1.3: VM Deployment and Provisioning

**Weight:** 33.34% (Topic 1 sub-weight)  
**Target Audience:** Senior SREs, Cloud Infrastructure Engineers, Systems Architects  

---

## 1. Architectural Overview & Internal Mechanics

VM deployment and provisioning in modern enterprise environments relies on decoupled image management, metadata injection, hypervisor orchestrators, and declarative configuration management.

```
+-----------------------------------------------------------------------------------+
|                                 BUILD PHASE                                       |
|  +-------------------+      +------------------+      +------------------------+  |
|  | Base OS ISO/Img   | ---> | Packer / QEMU    | ---> | virt-sysprep           |  |
|  +-------------------+      +------------------+      +------------------------+  |
|                                                                   |               |
|                                                          Golden QCOW2 Image       |
+-------------------------------------------------------------------|---------------+
                                                                    v
+-----------------------------------------------------------------------------------+
|                              PROVISIONING PHASE                                   |
|  +-------------------+      +------------------+      +------------------------+  |
|  | cloud-config      | ---> | cloud-localds    | ---> | seed.iso (NoCloud)     |  |
|  | (user/vendor-data)|      +------------------+      +------------------------+  |
|  +-------------------+                                            |               |
+-------------------------------------------------------------------|---------------+
                                                                    v
+-----------------------------------------------------------------------------------+
|                                RUNTIME PHASE                                      |
|  +-----------------------------------------------------------------------------+  |
|  | virt-install --disk golden.qcow2 --disk seed.iso,device=cdrom               |  |
|  +-----------------------------------------------------------------------------+  |
|                                       |                                           |
|                                       v                                           |
|  +-----------------------------------------------------------------------------+  |
|  | Target VM Boot (libvirt / QEMU-KVM)                                         |  |
|  |  1. Kernel boots, cloud-init stage 'generator' identifies NoCloud ISO         |  |
|  |  2. Stage 'local' mounts ISO, parses meta-data & user-data                    |  |
|  |  3. Stage 'network' applies networking configuration                        |  |
|  |  4. Stage 'config' runs modules (users, ssh-keys, write_files)               |  |
|  |  5. Stage 'final' executes runcmd scripts & package installations           |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### 1.1 `libguestfs` Mechanics
`libguestfs` tools (`virt-builder`, `virt-customize`, `virt-sysprep`, `guestfish`) do not operate directly via open standard filesystem calls on host-mounted files. Instead, `libguestfs` launches a minimal temporary QEMU/KVM appliance (a small Linux kernel and initrd running inside a dedicated background QEMU process). This appliance attaches the target guest disk image raw or QCOW2 format, preventing host kernel panic or filesystem corruption risks associated with loop-mounting guest filesystems directly on the hypervisor host.

### 1.2 `cloud-init` Data Source Mechanics
`cloud-init` activates during the guest boot process across four distinct systemd targets/stages:
1. **`cloud-init-local.service`**: Detects available datasources (e.g., NoCloud ISO, ConfigDrive, OpenStack Metadata API at `169.254.169.254`). Reads network metadata and applies early network configuration before network interfaces are brought up.
2. **`cloud-init.service`**: Fetches `user-data` and `vendor-data`. Processes hostnames, SSH authorized keys, and mount points.
3. **`cloud-config.service`**: Executes configuration modules such as `write_files`, user creation, and package updates.
4. **`cloud-final.service`**: Executes late-stage scripts specified under `runcmd`, Ansible pulls, or custom initialization commands.

---

## 2. Guided Hands-On Exercises

---

### Exercise 1: Image Building and Sysprepping with `libguestfs` Tools

#### Objective
Understand how to build base VM disk images dynamically, inject packages without booting the guest, and sanitize master templates for production cloning using `virt-builder`, `virt-customize`, `virt-sysprep`, and `guestfish`.

#### Step 1: Build a clean base image using `virt-builder`
Execute `virt-builder` to generate an Ubuntu 22.04 QCOW2 disk image, setting the root password and embedding an SRE administrator SSH public key directly into the offline filesystem.

```bash
virt-builder ubuntu-22.04 \
  --format qcow2 \
  --output /var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --size 20G \
  --root-password password:ArchEnterprise2026! \
  --ssh-inject root:file:$HOME/.ssh/id_rsa.pub \
  --hostname golden-tpl-01
```

**Expected Output:**
```text
[   1.2] Downloading: http://builder.libguestfs.org/ubuntu-22.04.xz
[   4.5] Planning how to build image
[   4.5] Extracting template
[  12.1] Formatting /dev/sda1 as ext4
[  14.3] Setting root password
[  15.0] Injecting SSH key for root
[  15.2] Setting hostname: golden-tpl-01
[  16.1] Finishing off
Output file: /var/lib/libvirt/images/ubuntu-golden-base.qcow2
```

#### Step 2: Inject system configurations using `virt-customize`
Customize the offline disk image by installing mandatory monitoring packages, enabling the `qemu-guest-agent`, and setting timezone parameters.

```bash
virt-customize -a /var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --install qemu-guest-agent,curl,htop,net-tools \
  --timezone "UTC" \
  --run-command 'systemctl enable qemu-guest-agent'
```

**Expected Output:**
```text
[   0.0] Starting virt-customize
[   1.5] Examining the guest ...
[   6.2] Running apt-get update
[  18.4] Installing packages: qemu-guest-agent curl htop net-tools
[  24.1] Setting timezone to UTC
[  24.3] Running command: systemctl enable qemu-guest-agent
[  25.0] Finishing off
```

#### Step 3: Sanitize the template using `virt-sysprep` and inspect via `guestfish`
Prepare the image for production template cloning by removing persistent MAC addresses, machine-ids, cloud-init artifacts, and SSH host keys. Afterwards, use `guestfish` to inspect `/etc/machine-id`.

```bash
virt-sysprep -a /var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --enable machine-id,ssh-hostkeys,udev-persistent-net,logfiles,cloud-init

guestfish --ro -a /var/lib/libvirt/images/ubuntu-golden-base.qcow2 -m /dev/sda1 cat /etc/machine-id
```

**Expected Output:**
```text
[   0.0] Examining the guest ...
[   2.1] Performing operations: machine-id * ssh-hostkeys * udev-persistent-net * logfiles * cloud-init *
[   2.1] Clearing /etc/machine-id ...
[   2.2] Removing SSH host keys ...
[   2.4] Purging udev persistent net rules ...
[   2.7] Removing log files ...
[   3.0] Resetting cloud-init state ...
```
*(The `guestfish` output will display an empty string or a newline, confirming `/etc/machine-id` has been reset).*

---

#### Concept Verification Questions — Exercise 1

1. **Why is it critical to purge `/etc/machine-id` and SSH host keys using `virt-sysprep` before deploying multiple VMs cloned from a master QCOW2 image?**
2. **What occurs under the hood if you run `virt-customize` or `guestfish` on a QCOW2 image currently attached to an active, running libvirt KVM virtual machine?**

---

### Exercise 2: Declarative Provisioning with `cloud-init` and `cloud-localds`

#### Objective
Master local cloud-init image provisioning by creating standard `user-data` and `meta-data` manifests, compiling a NoCloud ISO seed drive, provisioning via `virt-install`, and troubleshooting deployment logs.

#### Step 1: Draft the syntactically valid `#cloud-config` manifest
Create a file named `user-data.yaml`. This manifest provisions an `sre-admin` user, configures sudo privileges, injects an SSH key, creates a configuration file, and executes initialization commands.

```yaml
#cloud-config
version: v1
hostname: prod-node-01
fqdn: prod-node-01.infra.internal
manage_etc_hosts: true

users:
  - name: sre-admin
    gecos: SRE Engineer
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, docker]
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5qP... sre-key@infrastructure

packages:
  - nginx
  - jq

write_files:
  - path: /etc/sysctl.d/99-kubernetes-cri.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.ipv4.ip_forward                 = 1
      net.bridge.bridge-nf-call-ip6tables = 1

runcmd:
  - [ sysctl, --system ]
  - [ systemctl, enable, --now, nginx ]
  - echo "VM Provisioned Successfully on $(date)" > /var/log/provisioning.log
```

Create a matching `meta-data.yaml`:
```yaml
instance-id: i-prod-node-01-2026
local-hostname: prod-node-01
```

#### Step 2: Generate the NoCloud ISO seed drive using `cloud-localds`
Compile `user-data.yaml` and `meta-data.yaml` into a VFAT/ISO9660 formatted seed image compatible with the `cloud-init` NoCloud datasource.

```bash
cloud-localds -v /var/lib/libvirt/images/seed-prod-node-01.iso user-data.yaml meta-data.yaml
```

**Expected Output:**
```text
cloud-localds: outputting to /var/lib/libvirt/images/seed-prod-node-01.iso
cloud-localds: user-data file: user-data.yaml
cloud-localds: meta-data file: meta-data.yaml
```

#### Step 3: Instantiate the VM using `virt-install`
Attach the golden base disk created in Exercise 1 alongside the `seed-prod-node-01.iso` drive.

```bash
virt-install \
  --name prod-node-01 \
  --ram 2048 \
  --vcpus 2 \
  --os-variant ubuntu22.04 \
  --disk path=/var/lib/libvirt/images/prod-node-01.qcow2,size=20,backing_store=/var/lib/libvirt/images/ubuntu-golden-base.qcow2 \
  --disk path=/var/lib/libvirt/images/seed-prod-node-01.iso,device=cdrom \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

**Expected Output:**
```text
Starting install...
Allocating 'prod-node-01.qcow2'                                      |  20 GB  00:00:01 
Creating domain...                                                   |    0 B  00:00:00 
Domain creation completed.
```

#### Step 4: Validate cloud-init runtime execution and diagnostics
Access the VM or inspect logs to trace execution stages, check status, and analyze module latency.

```bash
# Connect to guest serial console
virsh console prod-node-01

# Inside the guest, run cloud-init diagnostic suite:
cloud-init status --wait --long
cloud-init analyze show
cloud-init query metadata.instance_id
```

**Expected Output:**
```text
# cloud-init status --wait --long
status: done
extended_status: done
boot_status_code: enabled
detail: finished at Thu, 06 Aug 2026 17:15:32 +0000. Datasource DataSourceNoCloud [seed=/dev/sr0][msrc=/dev/sr0]. Up 42.12 seconds

# cloud-init analyze show
-- Boot Record 01 --
stage: init-local
  start: 17:14:50.120000
  finish: 17:14:51.450000
  duration: 1.33s
stage: init
  start: 17:14:53.100000
  finish: 17:14:58.200000
  duration: 5.10s
stage: modules-config
  start: 17:15:01.000000
  finish: 17:15:15.800000
  duration: 14.80s
stage: modules-final
  start: 17:15:16.000000
  finish: 17:15:32.000000
  duration: 16.00s

# cloud-init query metadata.instance_id
i-prod-node-01-2026
```

---

#### Concept Verification Questions — Exercise 2

1. **What is the structural difference in debugging information found in `/var/log/cloud-init.log` versus `/var/log/cloud-init-output.log`?**
2. **If `cloud-init status` reports `status: error`, which command line options allow an SRE to reset `cloud-init` state completely and force re-execution of all boot modules without rebuilding the VM?**

---

### Exercise 3: Automated KVM Image Pipelines with HashiCorp Packer

#### Objective
Build custom production guest images completely unattended via HashiCorp Packer using the `qemu` plugin, defining HCL2 builders and provisioners.

#### Step 1: Author a Packer HCL2 Template
Save the following manifest as `ubuntu-kvm.pkr.hcl`.

```hcl
packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_checksum" {
  type    = string
  default = "sha256:5e38b0a3da12ee021556980743b678a739197a102b82503cadb12778abe2bb12"
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso"
}

source "qemu" "ubuntu_amd64" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "output-ubuntu-qemu"
  shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
  disk_size        = "15000M"
  format           = "qcow2"
  accelerator      = "kvm"
  http_directory   = "http"
  ssh_username     = "packer"
  ssh_password     = "UbuntuPacker2026!"
  ssh_timeout      = "20m"
  vm_name          = "ubuntu-2204-hardened.qcow2"
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  boot_wait        = "5s"
  boot_command     = [
    "<wait>e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<F10>"
  ]
}

build {
  sources = ["source.qemu.ubuntu_amd64"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y auditd fail2ban",
      "sudo systemctl enable auditd",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo truncate -s 0 /etc/machine-id"
    ]
  }
}
```

#### Step 2: Validate and execute the build pipeline
Prepare the build workspace, validate HCL syntax, and execute Packer to produce the target QCOW2 image.

```bash
mkdir -p http
touch http/user-data http/meta-data

packer init ubuntu-kvm.pkr.hcl
packer validate ubuntu-kvm.pkr.hcl
packer build ubuntu-kvm.pkr.hcl
```

**Expected Output:**
```text
qemu.ubuntu_amd64: output will be in directory: output-ubuntu-qemu
==> qemu.ubuntu_amd64: Downloading ISO...
==> qemu.ubuntu_amd64: Starting HTTP server on port 8123
==> qemu.ubuntu_amd64: Starting VM, formatting disk image...
==> qemu.ubuntu_amd64: Typing the boot command...
==> qemu.ubuntu_amd64: Waiting for SSH to become available...
==> qemu.ubuntu_amd64: Connected to SSH!
==> qemu.ubuntu_amd64: Provisioning with shell script...
    qemu.ubuntu_amd64: Setting up auditd...
==> qemu.ubuntu_amd64: Gracefully halting virtual machine...
==> qemu.ubuntu_amd64: Deleting unnecessary files...
Build 'qemu.ubuntu_amd64' finished after 7 minutes 12 seconds.

==> Builds finished. The artifacts of successful builds are:
--> qemu.ubuntu_amd64: VM files in directory: output-ubuntu-qemu
```

---

#### Concept Verification Questions — Exercise 3

1. **What function does the `http_directory` parameter and `{{ .HTTPIP }}:{{ .HTTPPort }}` construct serve during automated VM image generation with Packer?**
2. **In enterprise CI/CD image pipelines, why should the `accelerator = "kvm"` option be configured, and what fallback issue occurs if KVM hardware virtualization extensions (`/dev/kvm`) are not exposed in the build worker environment?**

---

### Exercise 4: Multi-Node Orchestration with Vagrant and `vagrant-libvirt`

#### Objective
Configure declaratively managed multi-node infrastructure using HashiCorp Vagrant targeted at a native Linux `libvirt` hypervisor backend.

#### Step 1: Write a production-grade multi-node `Vagrantfile`
Create a `Vagrantfile` supporting two nodes (Control Plane and Worker node) with private networking, custom memory allocation, and inline provisioners.

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vagrant.plugins = "vagrant-libvirt"
  config.vm.box = "generic/ubuntu2204"

  # Global Provider Settings for KVM/libvirt
  config.vm.provider :libvirt do |lv|
    lv.driver = "kvm"
    lv.connect_via_ssh = false
    lv.storage_pool_name = "default"
  end

  # Node 1: Control Plane
  config.vm.define "k8s-control" do |control|
    control.vm.hostname = "control-plane.infra.internal"
    control.vm.network "private_network", ip: "192.168.50.10"
    
    control.vm.provider :libvirt do |v|
      v.memory = 4096
      v.cpus = 2
      v.nested = true
    end

    control.vm.provision "shell", inline: <<-SHELL
      apt-get update && apt-get install -y curl transport-https ca-certificates
      echo "Control Plane Prepared"
    SHELL
  end

  # Node 2: Worker Node
  config.vm.define "k8s-worker" do |worker|
    worker.vm.hostname = "worker-01.infra.internal"
    worker.vm.network "private_network", ip: "192.168.50.11"

    worker.vm.provider :libvirt do |v|
      v.memory = 2048
      v.cpus = 2
    end

    worker.vm.provision "shell", inline: <<-SHELL
      apt-get update && apt-get install -y curl
      echo "Worker Node Prepared"
    SHELL
  end
end
```

#### Step 2: Bring up machines and verify network interfaces
Launch the environment specifically utilizing the `libvirt` provider, and check domain statuses under `virsh`.

```bash
vagrant up --provider=libvirt
vagrant status
virsh -c qemu:///system list --all
```

**Expected Output:**
```text
Bringing machine 'k8s-control' up with 'libvirt' provider...
Bringing machine 'k8s-worker' up with 'libvirt' provider...
==> k8s-control: Creating image (mapping backend box image...)
==> k8s-control: Creating domain with the following settings...
==> k8s-control:  -- Name:              vagrantfile_k8s-control
==> k8s-control:  -- Memory:            4096 MB
==> k8s-control:  -- CPUs:              2
==> k8s-control: Starting domain.
==> k8s-control: Waiting for domain to get an IP address...
==> k8s-control: Running provisioner: shell...
==> k8s-worker: Creating domain with the following settings...
==> k8s-worker: Starting domain.

Current machine states:

k8s-control               running (libvirt)
k8s-worker                running (libvirt)

 virsh -c qemu:///system list --all
 Id   Name                      State
-----------------------------------------
 1    vagrantfile_k8s-control   running
 2    vagrantfile_k8s-worker    running
```

---

#### Concept Verification Questions — Exercise 4

1. **How does `vagrant-libvirt` handle synchronized folders by default versus when `config.vm.synced_folder ".", "/vagrant", type: "nfs"` is explicitly configured?**
2. **What subcommand destroys all underlying KVM domain storage volumes and libvirt network bindings managed by Vagrant without leaving orphaned QCOW2 files in the storage pool?**

---

## 3. Official References

- **LPIC-3 Exam 305-300 Detailed Objectives**: [https://www.lpi.org/our-certifications/lpic-3-305-overview/](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
- **Libguestfs Tools & Commands Documentation**: [https://libguestfs.org/](https://libguestfs.org/)
- **Cloud-init Datasources & Configuration Reference**: [https://cloudinit.readthedocs.io/](https://cloudinit.readthedocs.io/)
- **HashiCorp Packer QEMU Builder Documentation**: [https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu)
- **Vagrant Libvirt Provider Specification**: [https://github.com/vagrant-libvirt/vagrant-libvirt](https://github.com/vagrant-libvirt/vagrant-libvirt)

---

## 4. Verification Solutions

<details>
<summary>Click to expand Solutions & Detailed Explanations</summary>

### Exercise 1 Solutions

1. **Purging Machine-IDs & Host Keys:**  
   Operating system instances generate unique identifiers (`/etc/machine-id` for systemd-based Linux systems, and OpenSSH host keys under `/etc/ssh/ssh_host_*`) to ensure unique cryptographic identities across network topologies. If multiple cloned virtual machines retain identical machine-ids:
   - Systemd-journald and remote logging aggregators (e.g., Fluentd, Loki) collapse logs into a single host stream.
   - DHCP clients leveraging DUID (DHCP Unique Identifier) based on `/etc/machine-id` will be assigned duplicate IP addresses by network DHCP servers.
   - Identical SSH host keys expose host traffic to Man-In-The-Middle (MITM) attacks and trigger host key verification failures.

2. **Modifying Active Images (Concurrency Hazards):**  
   Running `virt-customize`, `virt-sysprep`, or `guestfish` in write mode against an active, running guest OS disk leads to instant filesystem corruption. The host's `libguestfs` temporary QEMU appliance mounts the underlying block structures without coordinating with the active VM kernel's page cache or journal state. This concurrently modifies block allocation tables, resulting in corrupted inodes, unrecoverable ext4/xfs errors, and guest kernel panics. `libguestfs` locks disk files via `virt-locking` or `flock` when integrated with libvirt to prevent concurrent attachment.

---

### Exercise 2 Solutions

1. **Log File Diagnostics (`cloud-init.log` vs `cloud-init-output.log`):**  
   - `/var/log/cloud-init.log`: Contains detailed internal Python tracebacks, module execution timelines, data source resolution steps, state decision trees, and configuration parsing logs generated directly by the `cloud-init` framework.
   - `/var/log/cloud-init-output.log`: Captures stdout and stderr streams emitted by sub-processes launched *by* cloud-init during execution (e.g., raw outputs from shell scripts under `runcmd`, package outputs from `apt`/`yum`, and output from `write_files` hooks).

2. **Resetting Cloud-init State:**  
   To purge cached metadata and force cloud-init to run again from scratch upon the next system reboot, execute:
   ```bash
   cloud-init clean --logs --reboot
   ```
   To clean local state without immediate reboot and re-run modules manually:
   ```bash
   cloud-init clean
   cloud-init init --local
   cloud-init init
   cloud-init modules --mode=config
   cloud-init modules --mode=final
   ```

---

### Exercise 3 Solutions

1. **Packer HTTP Directory Mechanics:**  
   During headless installation of an OS (e.g., Ubuntu Subiquity / Red Hat Kickstart), the installer requires access to answer files (`user-data`, `ks.cfg`). The `http_directory` parameter instructs Packer to launch a temporary HTTP server bound to an ephemeral host port. The `{{ .HTTPIP }}` and `{{ .HTTPPort }}` template variables dynamically inject the host IP address and auto-selected port into the VM's boot command, allowing the guest kernel installer to download preseed files directly over the virtual network.

2. **KVM Hardware Acceleration vs Emulation:**  
   The `accelerator = "kvm"` directive instructs QEMU to pass CPU virtualization instructions directly to physical CPU hardware flags (`/dev/kvm` via VT-x or AMD-V). If KVM extensions are missing (e.g., when running inside an nested VM worker without nested virtualization enabled), QEMU falls back to software-emulated CPU instructions (`TCG` mode). This causes image build execution times to drop dramatically (taking up to 10-15x longer), frequently triggering step timeouts in SSH handshake phases.

---

### Exercise 4 Solutions

1. **Vagrant Shared Folder Types:**  
   By default, `vagrant-libvirt` uses `rsync` for folder synchronization, which performs a one-way copy of files from the host to the guest upon invocation of `vagrant up` or `vagrant reload` (host-to-guest sync only, non-realtime). When `type: "nfs"` is explicitly configured, Vagrant configures host-level NFS kernel daemons (`nfs-kernel-server`), creating a real-time bi-directional mount over the private network bridge with significantly higher disk I/O throughput.

2. **Clean Environment Destruction:**  
   To completely purge VM instances along with their storage volumes, network interfaces, and ephemeral metadata, run:
   ```bash
   vagrant destroy -f
   ```
   To purge leftover storage pools manually at the hypervisor level:
   ```bash
   virsh volume-wipe --pool default <volume-name>.qcow2
   virsh volume-delete --pool default <volume-name>.qcow2
   ```

</details>