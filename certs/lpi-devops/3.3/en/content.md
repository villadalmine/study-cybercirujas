# LPI DevOps Tools Engineer (Exam 701-100) | Topic 3.3: System Image Creation

## 1. Motivation and Production Architectural Problem

### 1.1 The Enterprise Anti-Pattern: Configuration Drift & Boot-Time Provisioning
In high-availability, cloud-native enterprise environments, reliance on mutable infrastructure and boot-time configuration management (e.g., executing raw shell scripts or heavy configuration management roles inside `cloud-init` at instance launch) introduces three critical failure modes:

1. **Autoscaling Latency and SLA Violations:** Executing dynamic package installation (`apt-get update && apt-get install`), dependency resolution, compilation, and security hardening on a newly launched Virtual Machine (VM) or Cloud Instance can take between 8 to 15 minutes. During sudden traffic spikes, an Elastic Load Balancer (ELB) or Autoscaling Group (ASG) will fail to scale horizontally in time to absorb the load, leading to elevated latency, queue saturation, and HTTP 504 Gateway Timeouts.
2. **Non-Deterministic Builds & Supply Chain Vulnerabilities:** Relying on external package repositories, distribution mirrors, or third-party artifact hosts during instance initialization creates non-deterministic runtime environments. If an upstream repository updates a minor package version, alters a GPG signing key, or experiences an outage, newly launched instances will diverge from existing fleet nodes (Configuration Drift) or fail to boot entirely, breaking fleet homogeneity.
3. **Elevated Blast Radius During Outages:** When an ASG replaces unhealthy nodes during an incident, any transient network partitioning or third-party mirror rate-limiting prevents boot completion, converting a localized node degradation into a catastrophic service failure.

```
Mutable Boot-Time Provisioning (Anti-Pattern):
[ ASG Trigger ] ──► [ Launch Raw Instance ] ──► [ Cloud-Init ] ──► [ Apt Update/Install ] ──► [ Run Ansible ] ──► [ Ready (8-15 min) ]
                                                                             │                       │
                                                                             ▼                       ▼
                                                                     [ Mirror Outage ]       [ Dependency Drift ]
                                                                       (Boot Failure)         (Inconsistent Fleet)

Immutable Golden Image Architecture (Production Target):
[ ASG Trigger ] ──► [ Launch Pre-Baked AMI ] ──► [ Mount Storage / Runtime Secrets ] ──► [ Ready (< 45 sec) ]
```

### 1.2 The Immutable Infrastructure Paradigm
To solve these architectural bottlenecks, SRE and Platform Engineering teams adopt the **Immutable Infrastructure** paradigm using system image pre-baking tools such as **HashiCorp Packer**. 

In an immutable workflow:
- System images (AMIs, QCOW2 files, VHDs, Container images) are built, fully provisioned, patched, scanned for vulnerabilities, and baked offline within a CI/CD pipeline prior to deployment.
- Deployed instances are treated as ephemeral artifacts. Configuration updates, kernel patches, or application code deployments are executed not by modifying running instances in-place, but by instantiating new virtual machine instances from updated Golden Images and gracefully terminating old nodes.

### 1.3 Internal Mechanics of Automated System Image Creation
Tools like HashiCorp Packer abstract cloud-provider hypervisors and virtualization drivers to generate identical system images across multiple target platforms (AWS EBS, QEMU/KVM, VMware vSphere, VirtualBox, Docker).

The low-level mechanics of an automated image build involve five discrete phases:

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                PACKER ENGINE EXECUTOR                                    │
└──────────────────────────────────────────────────────────────────────────────────────────┘
           │
           ├── 1. INFRASTRUCTURE PROVISIONING (Builder)
           │      └── Provision temporary hypervisor resource (EC2 Instance / QEMU VM / Docker Container)
           │      └── Create ephemeral SSH/WinRM key pairs & security rules
           │
           ├── 2. TRANSPORT INTEGRATION
           │      └── Establish secure remote control tunnel (SSH / WinRM / Docker Exec)
           │
           ├── 3. PROVISIONING EXECUTION
           │      └── Inject files, execute shell scripts, configuration management (Ansible/Chef)
           │      └── Apply OS hardening, CIS benchmarks, and artifact cleanup
           │
           ├── 4. HYPERVISOR SNAPSHOTTING & RATIONING
           │      └── Stop provisioning target cleanly
           │      └── Issue hypervisor block-level snapshot call (e.g., EBS CreateSnapshot)
           │      └── Register target machine image (AMI / QCOW2 registration)
           │
           └── 5. RESOURCE SANITIZATION
                  └── Terminate ephemeral instance, security groups, and temporary key pairs
```

---

## 2. Technical Comparisons & Trade-off Matrices

### 2.1 Image Strategy Architectural Trade-off Matrix

| Metric / Dimension | Golden Image (Pre-Baked) | Dynamic Provisioning (Cloud-Init Only) | Hybrid (Baked Base + Boot-Time App Config) |
| :--- | :--- | :--- | :--- |
| **Boot-to-Ready Time** | Extremely Low (< 45 seconds) | High (8–15 minutes) | Moderate (1–3 minutes) |
| **Fleet Homogeneity** | 100% Deterministic | Low (Vulnerable to package mirror drift) | High for OS, Moderate for App layer |
| **CI/CD Pipeline Complexity** | High (Requires automated image build pipelines) | Low (Only requires cloud-config deployment) | Moderate |
| **Vulnerability Patching Speed** | Requires full image bake & rolling replacement | Applied instantly on new instance launch | Base OS pre-baked; App patched at boot |
| **Storage & Registry Cost** | Higher (Multiple large image snapshots stored) | Minimal (Base distribution images used) | Moderate |
| **Production Risk Profile** | Low (Vulnerabilities caught during image scan) | High (Boot failures during incident recovery) | Low-Moderate |

### 2.2 HashiCorp Packer Builder Drivers Comparison

| Builder Driver | Underlying Hypervisor / API | Target Output Artifact | Target Production Use-Case | Performance / Build Overhead |
| :--- | :--- | :--- | :--- | :--- |
| `amazon-ebs` | AWS EC2 API & EBS Snapshot Engine | Amazon Machine Image (AMI) | AWS Cloud Native Workloads (ASG, EKS Nodes) | Cloud API network bound (~5-10 min) |
| `qemu` | KVM / QEMU Hardware Emulation | QCOW2 / RAW Block Image | OpenStack, Proxmox, Bare-Metal Virtualization | CPU/Disk IO bound on build host |
| `virtualbox-iso` | VirtualBox Hypervisor | OVA / OVF Package | Local Developer Environment (Vagrant Boxes) | High local CPU/RAM overhead |
| `docker` | Docker Engine / Containerd | Container Image Manifest | Containerized Microservices & Kubernetes | Extremely fast (Layer caching supported) |

### 2.3 Provisioner Execution Strategy Comparison

| Provisioner Type | Internal Mechanics | Dependency Prerequisites | Ideal Use Case | Security Impact |
| :--- | :--- | :--- | :--- | :--- |
| `shell` | Transports inline scripts or bash files via SSH/WinRM stream | None (Standard POSIX shell) | OS bootstrap, directory creation, final artifact cleanup | Low attack surface; requires shell idempotency discipline |
| `ansible-local` | Uploads Ansible Playbooks and runs `ansible-playbook` on target | Python & Ansible installed on temporary builder VM | Enterprise configuration management reuse | Requires temporary Ansible installation (must be purged during cleanup) |
| `file` | Uploads local binary artifacts or configs via SFTP/SCP | Valid SSH/WinRM connection | Injecting pre-compiled binaries, systemd units, certificates | Fast; no runtime overhead on target machine |

---

## 3. Production Infrastructure & Manifests

### 3.1 Production HashiCorp Packer HCL2 Template (`ubuntu-hardened.pkr.hcl`)
This complete, syntactically valid HCL2 template provisions an encrypted, security-hardened AWS AMI based on Ubuntu 22.04 LTS. It integrates the AWS EBS builder, local file uploaders, shell execution provisioners, and an artifact manifest post-processor.

```hcl
packer {
  required_version = ">= 1.9.0"
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "app_version" {
  type    = string
  default = "1.0.0"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

source "amazon-ebs" "ubuntu-hardened" {
  ami_name                    = "golden-ubuntu-22.04-amd64-${var.app_version}-build-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  instance_type               = var.instance_type
  region                      = var.aws_region
  encrypt_boot                = true
  kms_key_id                  = "alias/aws/ebs"
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical Official AWS Account ID
  }

  ssh_username = "ubuntu"
  ssh_timeout  = "10m"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name          = "Golden-Ubuntu-22.04-AMI"
    Environment   = var.environment
    AppVersion    = var.app_version
    ManagedBy     = "Packer"
    BaseOS        = "Ubuntu-22.04"
    CreationDate  = formatdate("YYYY-MM-DD", timestamp())
  }
}

build {
  name = "production-ami-builder"
  sources = [
    "source.amazon-ebs.ubuntu-hardened"
  ]

  # Provisioner 1: Stage production configuration files
  provisioner "file" {
    source      = "files/limits.conf"
    destination = "/tmp/limits.conf"
  }

  # Provisioner 2: Base System Setup and Security Hardening
  provisioner "shell" {
    inline = [
      "echo '==> Waiting for cloud-init to complete process lock...'",
      "cloud-init status --wait",
      "echo '==> Applying OS updates...'",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y auditd fail2ban curl jq unzip systemd-journal-remote",
      "sudo mv /tmp/limits.conf /etc/security/limits.d/99-realtime-limits.conf",
      "sudo chown root:root /etc/security/limits.d/99-realtime-limits.conf",
      "sudo chmod 0644 /etc/security/limits.d/99-realtime-limits.conf"
    ]
  }

  # Provisioner 3: Execute Production Hardening & Machine Sanitization Script
  provisioner "shell" {
    script          = "scripts/cleanup.sh"
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
  }

  # Post-Processor: Output Build Metadata for CI/CD Pipeline Consumption
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
    custom_data = {
      build_environment = var.environment
      application_ver   = var.app_version
    }
  }
}
```

---

### 3.2 Production System Sanitization & Image Hardening Script (`scripts/cleanup.sh`)
This shell script is executed as the final provisioner step. It strips instance identity signatures (host keys, `/etc/machine-id`, cloud-init state) and zeros out empty disk sectors to enable sparse volume compression and prevent security identity leaks across instances cloned from the image.

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "========================================================="
echo " STARTING PRODUCTION IMAGE HARDENING & SANITIZATION"
echo "========================================================="

# 1. Stop Logging and Monitoring Services
echo "==> Stopping syslog and audit daemons..."
systemctl stop auditd || true
systemctl stop rsyslog || true

# 2. Remove Ephemeral SSH Host Keys (Must be regenerated on first boot by cloud-init)
echo "==> Purging existing SSH host key pairs..."
rm -f /etc/ssh/ssh_host_*

# 3. Reset Machine-ID (Crucial to prevent DHCP IP collision & duplicate journald IDs)
echo "==> Resetting /etc/machine-id..."
truncate -s 0 /etc/machine-id
if [ -f /var/lib/dbus/machine-id ]; then
    rm -f /var/lib/dbus/machine-id
    ln -s /etc/machine-id /var/lib/dbus/machine-id
fi

# 4. Clean Cloud-Init Execution State & Artifact Logs
echo "==> Cleaning cloud-init cache and log artifacts..."
cloud-init clean --logs --seed

# 5. Purge Package Manager Cache and Temporary Files
echo "==> Cleaning APT package manager cache..."
apt-get autoremove --purge -y
apt-get clean -y
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

# 6. Purge Shell History & User Logs
echo "==> Clearing system logs and user history files..."
find /var/log -type f -exec truncate -s 0 {} \;
rm -f /root/.bash_history
rm -f /home/ubuntu/.bash_history
rm -rf /root/.ssh/authorized_keys
rm -rf /home/ubuntu/.ssh/authorized_keys

# 7. Fill Free Storage Sectors with Zeroes to Maximize EBS Compression
echo "==> Zeroing out empty disk sectors..."
dd if=/dev/zero of=/EMPTY bs=1M status=progress || true
sync
rm -f /EMPTY
sync

echo "========================================================="
echo " SANITIZATION COMPLETE - IMAGE READY FOR SNAPSHOT"
echo "========================================================="
```

---

### 3.3 Production Cloud-Init User-Data Manifest (`cloud-config.yaml`)
When launching a VM instance from the baked Golden Image, cloud-init processes this declarative `#cloud-config` user-data manifest to set instance-specific parameters (hostname, SSH keys, dynamic systemd configuration) without modifying system binaries.

```yaml
#cloud-config
version: v1
hostname: node-prod-app-01
fqdn: node-prod-app-01.internal.net
manage_etc_hosts: true

users:
  - name: sysadmin
    gecos: System Administrator
    groups: sudo, systemd-journal
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCz7x71a2B... sysadmin@ops

package_update: false
package_upgrade: false

write_files:
  - path: /etc/sysctl.d/99-production-tuning.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.core.somaxconn = 65535
      net.ipv4.tcp_max_syn_backlog = 8192
      vm.max_map_count = 262144

  - path: /etc/systemd/system/app-exporter.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Production Node Exporter
      After=network.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/node_exporter
      Restart=always
      RestartSec=5s

      [Install]
      WantedBy=multi-user.target

runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now app-exporter.service
  - [ ssh-keygen, -A ]  # Regenerate SSH Host Keys on First Boot
  - systemctl restart ssh
```

---

## 4. Real CLI Commands and Expected Terminal Outputs

### 4.1 Step 1: Initialize Plugins and Validate Packer Syntax
Run `packer init` to download required provider plugins, followed by `packer fmt` and `packer validate` to check HCL syntax and cloud provider API credentials.

```bash
$ packer init ubuntu-hardened.pkr.hcl
Installed plugin github.com/hashicorp/amazon v1.2.8 in "/home/sre-user/.packer.d/plugins/github.com/hashicorp/amazon/packer-plugin-amazon_v1.2.8_x5.0_linux_amd64"

$ packer fmt -check ubuntu-hardened.pkr.hcl
ubuntu-hardened.pkr.hcl

$ packer validate -var="app_version=2.4.1" -var="aws_region=us-east-1" ubuntu-hardened.pkr.hcl
The configuration is valid.
```

---

### 4.2 Step 2: Execute Packer Build Pipeline
Execute the image construction process. Packer outputs live execution steps, including instance creation, provisioning over SSH, snapshotting, registration, and cleanup.

```bash
$ packer build -var="app_version=2.4.1" -var="aws_region=us-east-1" ubuntu-hardened.pkr.hcl
amazon-ebs.ubuntu-hardened: output will be in this color.

==> amazon-ebs.ubuntu-hardened: Prevalidated AMI Name: golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000
    amazon-ebs.ubuntu-hardened: Found AMI: ami-0c7217cdde317cfec
==> amazon-ebs.ubuntu-hardened: Creating temporary keypair: packer_66b36488-82a1-039c-502a-9f5b24479e0f
==> amazon-ebs.ubuntu-hardened: Creating temporary security group for packer...
==> amazon-ebs.ubuntu-hardened: Authorizing access to port 22 the temporary security group...
==> amazon-ebs.ubuntu-hardened: Launching a source AWS instance...
    amazon-ebs.ubuntu-hardened: Instance ID: i-0a91f4e8bc12a45d0
==> amazon-ebs.ubuntu-hardened: Waiting for instance (i-0a91f4e8bc12a45d0) to become ready...
==> amazon-ebs.ubuntu-hardened: Using SSH communicator to connect: 54.210.12.84
==> amazon-ebs.ubuntu-hardened: Waiting for SSH to become available...
==> amazon-ebs.ubuntu-hardened: Connected to SSH!
==> amazon-ebs.ubuntu-hardened: Uploading files/limits.conf -> /tmp/limits.conf
files/limits.conf 48B / 48B [========================================================================================================================] 100.00% 0s
==> amazon-ebs.ubuntu-hardened: Provisioning with shell script: inline commands
    amazon-ebs.ubuntu-hardened: ==> Waiting for cloud-init to complete process lock...
    amazon-ebs.ubuntu-hardened: status: done
    amazon-ebs.ubuntu-hardened: ==> Applying OS updates...
    amazon-ebs.ubuntu-hardened: Hit:1 http://archive.ubuntu.com/ubuntu jammy Insecure
    amazon-ebs.ubuntu-hardened: Reading package lists... Done
    amazon-ebs.ubuntu-hardened: Building dependency tree... Done
    amazon-ebs.ubuntu-hardened: Upgrading packages... Done
==> amazon-ebs.ubuntu-hardened: Provisioning with shell script: scripts/cleanup.sh
    amazon-ebs.ubuntu-hardened: =========================================================
    amazon-ebs.ubuntu-hardened:  STARTING PRODUCTION IMAGE HARDENING & SANITIZATION
    amazon-ebs.ubuntu-hardened: =========================================================
    amazon-ebs.ubuntu-hardened: ==> Stopping syslog and audit daemons...
    amazon-ebs.ubuntu-hardened: ==> Purging existing SSH host key pairs...
    amazon-ebs.ubuntu-hardened: ==> Resetting /etc/machine-id...
    amazon-ebs.ubuntu-hardened: ==> Cleaning cloud-init cache and log artifacts...
    amazon-ebs.ubuntu-hardened: ==> Cleaning APT package manager cache...
    amazon-ebs.ubuntu-hardened: ==> Clearing system logs and user history files...
    amazon-ebs.ubuntu-hardened: ==> Zeroing out empty disk sectors...
    amazon-ebs.ubuntu-hardened: 20971520000 bytes (21 GB, 20 GiB) copied, 18.23 s, 1.2 GB/s
    amazon-ebs.ubuntu-hardened: dd: error writing '/EMPTY': No space left on device
    amazon-ebs.ubuntu-hardened: =========================================================
    amazon-ebs.ubuntu-hardened:  SANITIZATION COMPLETE - IMAGE READY FOR SNAPSHOT
    amazon-ebs.ubuntu-hardened: =========================================================
==> amazon-ebs.ubuntu-hardened: Stopping the source instance...
    amazon-ebs.ubuntu-hardened: Stopping instance
==> amazon-ebs.ubuntu-hardened: Waiting for the instance to stop...
==> amazon-ebs.ubuntu-hardened: Creating AMI golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000 from instance i-0a91f4e8bc12a45d0
    amazon-ebs.ubuntu-hardened: AMI: ami-05e8391bc47a9e10f
==> amazon-ebs.ubuntu-hardened: Waiting for AMI to become ready...
==> amazon-ebs.ubuntu-hardened: Adding tags to AMI (ami-05e8391bc47a9e10f)...
==> amazon-ebs.ubuntu-hardened: Terminating the source AWS instance...
    amazon-ebs.ubuntu-hardened: Terminating instance
==> amazon-ebs.ubuntu-hardened: Cleaning up any extra volumes...
==> amazon-ebs.ubuntu-hardened: Destroying temporary keypair...
==> amazon-ebs.ubuntu-hardened: Destroying temporary security group...
==> amazon-ebs.ubuntu-hardened: Running post-processor: manifest
Build 'amazon-ebs.ubuntu-hardened' finished after 6 minutes 42 seconds.

==> Builds finished. The artifacts of successful builds are:
--> amazon-ebs.ubuntu-hardened: AMIs were created:
us-east-1: ami-05e8391bc47a9e10f
```

---

### 4.3 Step 3: Inspect Generated Artifact Metadata via AWS CLI
Verify the state, block device mapping, encryption status, and tags of the output image using the AWS CLI.

```bash
$ aws ec2 describe-images --image-ids ami-05e8391bc47a9e10f --output json
{
    "Images": [
        {
            "Architecture": "x86_64",
            "CreationDate": "2026-08-07T12:36:42.000Z",
            "ImageId": "ami-05e8391bc47a9e10f",
            "ImagePath": "",
            "ImageLocation": "123456789012/golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000",
            "State": "available",
            "BlockDeviceMappings": [
                {
                    "DeviceName": "/dev/sda1",
                    "Ebs": {
                        "DeleteOnTermination": true,
                        "SnapshotId": "snap-08cf92bdf11a4e21",
                        "VolumeSize": 20,
                        "VolumeType": "gp3",
                        "Encrypted": true,
                        "Iops": 3000,
                        "Throughput": 125
                    }
                }
            ],
            "EnaSupport": true,
            "Hypervisor": "xen",
            "Name": "golden-ubuntu-22.04-amd64-2.4.1-build-20260807123000",
            "RootDeviceName": "/dev/sda1",
            "RootDeviceType": "ebs",
            "VirtualizationType": "hvm",
            "Tags": [
                {
                    "Key": "AppVersion",
                    "Value": "2.4.1"
                },
                {
                    "Key": "Environment",
                    "Value": "production"
                },
                {
                    "Key": "ManagedBy",
                    "Value": "Packer"
                }
            ]
        }
    ]
}
```

---

## 5. Verification, Troubleshooting & Failure Diagnostics Guide

### 5.1 Failure Matrix & Root Cause Diagnostic Procedures

```
                       [ PACKER BUILD / RUNTIME FAILURE ]
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        ▼                              ▼                              ▼
 [ SSH Timeout Failure ]     [ Machine-ID Collision ]       [ Cloud-Init Lockout ]
        │                              │                              │
        ├── Check Security Group       ├── Inspect /etc/machine-id    ├── Run cloud-init status
        ├── Check Public IP assignment ├── Verify DHCP logs           ├── Inspect /var/log/cloud-init.log
        └── Verify ssh_username        └── Ensure sanitization run    └── Check systemd dependencies
```

#### Diagnostic Scenario A: Ephemeral SSH Transport Timeout During Build
* **Symptom:** `packer build` hangs at `Waiting for SSH to become available...` and eventually times out.
* **Root Cause 1:** The target VPC/Subnet selected by Packer lacks an attached Internet Gateway (IGW) or `associate_public_ip_address` is set to `false`.
* **Root Cause 2:** The default AMI `ssh_username` does not match the base image default (e.g., specifying `root` or `admin` instead of `ubuntu` or `ec2-user`).
* **Diagnostic Command:**
  ```bash
  PACKER_LOG=1 PACKER_LOG_PATH="packer-debug.log" packer build -on-error=ask ubuntu-hardened.pkr.hcl
  ```
  *(Note: `-on-error=ask` halts execution on error without immediately terminating the temporary EC2 instance, allowing direct SSH inspection).*

#### Diagnostic Scenario B: Duplicate Machine-ID Causing Network/DHCP Collisions
* **Symptom:** Instances launched from the baked AMI receive identical private IP addresses from the network DHCP server or overwrite each other's central logging streams in `systemd-journald`.
* **Root Cause:** `/etc/machine-id` was not truncated during the image build process. Every instance cloned from the snapshot inherits the exact same unique 128-bit machine identifier.
* **Verification Command on Running Instance:**
  ```bash
  $ cat /etc/machine-id
  # If the string returned matches across multiple instances, sanitization failed.
  ```
* **Remediation:** Ensure `truncate -s 0 /etc/machine-id` is present in the final cleanup shell provisioner.

#### Diagnostic Scenario C: Apt Package Lock Race Condition
* **Symptom:** Shell provisioner fails with `E: Could not get lock /var/lib/dpkg/lock-frontend - open (11: Resource temporarily unavailable)`.
* **Root Cause:** Canonical base images execute automatic `apt-daily.service` and `cloud-init` updates in the background upon booting. If Packer runs `apt-get` concurrently, package locks fail.
* **Remediation:** Enforce a cloud-init completion barrier in the first shell provisioner:
  ```bash
  cloud-init status --wait
  ```

---

### 5.2 Deep-Dive Low-Level Troubleshooting Workflow

When debugging cloud-init execution failures on newly instantiated Golden Images, SREs must navigate the four stages of cloud-init execution (`generator`, `local`, `init`, `modules:config`, `modules:final`).

```bash
# 1. Query Consolidated Cloud-Init Status
$ cloud-init status --long
status: error
extended_status: error
boot_status_code: enabled-error
detail: DataSourceNotFound - No supported datasource found

# 2. Inspect Cloud-Init Log Streams for Exception Tracebacks
$ grep -E "(ERROR|WARNING)" /var/log/cloud-init.log
2026-08-07 12:40:15,123 - cc_final.py[ERROR]: Failed executing module final
Traceback (most recent call last):
  File "/usr/lib/python3/dist-packages/cloudinit/config/cc_final.py", line 85, in handle
    subp.subp(req)
ProcessExecutionError: Unexpected error while running command: systemctl restart app-exporter.service

# 3. Analyze Systemd Unit Dependency Trees & Failures
$ journalctl -u cloud-final.service -u app-exporter.service --no-pager -n 50
Aug 07 12:40:15 node-prod-app-01 systemd[1]: Failed to start Production Node Exporter.
Aug 07 12:40:15 node-prod-app-01 systemd[1]: app-exporter.service: Main process exited, code=exited, status=203/EXEC
```

---

## 6. References

- **Linux Professional Institute (LPI) DevOps Tools Engineer Overview:**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **LPI Wiki - Objective 703.3 System Image Creation:**  
  [https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0#703.3_System_Image_Creation](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0#703.3_System_Image_Creation)
- **HashiCorp Packer Official Documentation:**  
  [https://developer.hashicorp.com/packer/docs](https://developer.hashicorp.com/packer/docs)
- **HashiCorp Packer Amazon EBS Builder Plugin:**  
  [https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs)
- **Cloud-Init Official Documentation:**  
  [https://cloudinit.readthedocs.io/en/latest/](https://cloudinit.readthedocs.io/en/latest/)