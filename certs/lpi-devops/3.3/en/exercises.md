# LPI DevOps Tools Engineer (Exam 701-100)
## Topic 703.3: System Image Creation (Weight: 3.33)

---

### Official References
- **LPI DevOps Tools Engineer Overview & Objectives**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **HashiCorp Packer Documentation**: [https://developer.hashicorp.com/packer/docs](https://developer.hashicorp.com/packer/docs)
- **Packer HCL2 Language Specification**: [https://developer.hashicorp.com/packer/docs/templates/hcl_templates](https://developer.hashicorp.com/packer/docs/templates/hcl_templates)
- **Canonical Cloud-Init Documentation**: [https://cloudinit.readthedocs.io/en/latest/](https://cloudinit.readthedocs.io/en/latest/)

---

### Deep Architectural & Technical Foundation

#### 1. Immutable Infrastructure Paradigms: Bake vs. Fry vs. Warm Bake
In enterprise production architecture, system image creation is the foundational primitive of **Immutable Infrastructure**. Instead of mutating running servers in-place using configuration management tools (which introduces configuration drift, non-deterministic state, and prolonged deployment windows), immutable infrastructure treats running instances as disposable execution nodes built from static, pre-validated images.

```
       [ Bake Strategy (Golden Image) ]             [ Fry Strategy (Runtime Provisioning) ]
       
 +------------------------------------------+     +------------------------------------------+
 | Build Time (CI/CD Pipeline):             |     | Build Time:                              |
 |   1. Boot Base OS VM/Container           |     |   - Generic OS Base Image Only           |
 |   2. Install OS Updates & Dependencies   |     | Boot Time (EC2 / Compute Startup):       |
 |   3. Bake Application Binaries & Assets  |     |   1. Boot Generic OS                     |
 |   4. Execute CIS Hardening & Sanitization|     |   2. Execute Apt/Yum Updates (Slow!)     |
 |   5. Snapshot Image Artifact (AMI/QCOW2) |     |   3. Run Configuration Management        |
 +------------------------------------------+     |   4. Fetch & Compile Binaries            |
                      |                           +------------------------------------------+
 Boot Time: < 30 seconds (Instant Scale)          Boot Time: 10–25 minutes (High Failure Rate)
```

- **Fully Baked (Golden Image)**: All software, OS kernels, dependencies, security agents, and static assets are compiled into the system image prior to runtime deployment. 
  - *Trade-offs*: Fast startup/autoscaling (< 30s), deterministic execution, zero runtime dependency on external package repositories. Higher storage footprint and longer image build pipeline times.
- **Fried (Runtime Bootstrapping)**: Minimal OS image deployed; software and configuration are fetched at runtime via `cloud-init`, UserData scripts, or Ansible on boot.
  - *Trade-offs*: Fast image build pipeline. Slow autoscaling (minutes), vulnerable to external repository downtime or network timeouts during scaling events.
- **Warm Bake (Hybrid)**: Core runtime dependencies, OS security updates, and common tooling are pre-baked into a base image. Application code and environment-specific configuration are injected via `cloud-init` or ephemeral configuration containers at startup.

---

#### 2. HashiCorp Packer Architecture & Internal Execution Mechanics
Packer uses a declarative engine (written in Go) to automate the creation of identical machine images for multiple platforms from a single source specification.

```
 +-----------------------------------------------------------------------------------+
 |                                   PACKER CORE                                     |
 |  +--------------------+   +-----------------------+   +------------------------+  |
 |  |  HCL2 Template     |   | Variable Evaluation   |   | Plugin RPC Orchestrator|  |
 |  +--------------------+   +-----------------------+   +------------------------+  |
 +----------------------------------------+------------------------------------------+
                                          |
                        +-----------------+-----------------+
                        |                                   |
              [ BUILDER PLUGINS ]                 [ PROVISIONER PLUGINS ]
      +----------------------------------+ +-----------------------------------+
      | - amazon-ebs / qemu / docker     | | - shell / file / ansible-local    |
      | - Manages instance lifecycle     | | - Communicates over SSH/WinRM    |
      | - Provisions temporary SSH keys  | | - Executes scripts in target host |
      +----------------------------------+ +-----------------------------------+
                        |                                   |
                        +-----------------+-----------------+
                                          |
                                [ POST-PROCESSOR PLUGINS ]
                        +---------------------------------------+
                        | - manifest / checksum / vagrant       |
                        | - Compresses, signs, indexes output   |
                        +---------------------------------------+
```

Packer executes builds through four distinct structural components:

1. **Packer Core**: Reads HCL2 configurations, parses dependency graphs, manages concurrent builds, and establishes gRPC/RPC communication channels with external plugins.
2. **Builders**: Platform-specific plugins that create temporary compute resources, manage initial boot sequences (e.g., via VNC, ISO mounting, cloud provider APIs), establish winrm/ssh connections, and capture the final machine state into a image artifact (AMI, QCOW2, Docker layer, VHD).
3. **Provisioners**: Modules executed after initial OS access is established over SSH/WinRM. They adapt the machine state by running shell commands, copying local files, or executing configuration management tools like Ansible, Puppet, or Chef.
4. **Post-Processors**: Artifact manipulation plugins executed after image generation. They compute SHA-256 checksums, compress artifacts, output manifest JSON files, re-package images into Vagrant boxes, or push container images to registries.

---

### Hands-On Guided Exercises

---

#### Lab 1: Production-Grade Immutable Base Image with HCL2, Ansible, and Cloud-Init Sanitization

##### Exercise Objective
Construct a modular Packer HCL2 project that builds a hardened Ubuntu system image using the `docker` builder (emulating local compute isolation), configures system services via the `ansible-local` provisioner, executes image sanitization, and outputs an audited build manifest.

---

##### Step 1: Initialize Directory Structure and Define HCL2 Plugin Requirements
Create the workspace directory structure and define the required plugin sources and version constraints in `plugins.pkr.hcl`.

```bash
mkdir -p ~/packer-lab/{scripts,ansible}
cd ~/packer-lab
```

Write `plugins.pkr.hcl`:

```hcl
# plugins.pkr.hcl
packer {
  required_version = ">= 1.8.0"
  required_plugins {
    docker = {
      version = ">= 1.0.8"
      source  = "github.com/hashicorp/docker"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}
```

---

##### Step 2: Configure Declarative Build Inputs in `variables.pkr.hcl`
Define explicit, type-validated input variables for image metadata, target versioning, and environment tagging.

Write `variables.pkr.hcl`:

```hcl
# variables.pkr.hcl
variable "base_image" {
  type        = string
  description = "The upstream base container image tag."
  default     = "ubuntu:22.04"
}

variable "app_version" {
  type        = string
  description = "Application semver tag to bake into system metadata."
  default     = "2.4.0"
}

variable "build_environment" {
  type        = string
  description = "Deployment tier label."
  default     = "production"

  validation {
    condition     = contains(["staging", "production"], var.build_environment)
    error_message = "The build_environment variable must be either 'staging' or 'production'."
  }
}
```

---

##### Step 3: Define Source Builders and Build Pipeline in `build.pkr.hcl`
Create the primary Packer specification file that mounts provisioners, executes Ansible playbooks, sanitizes machine identity, and records artifact metadata.

Write `build.pkr.hcl`:

```hcl
# build.pkr.hcl
source "docker" "ubuntu_base" {
  image      = var.base_image
  commit     = true
  changes    = [
    "ENV APP_VERSION=${var.app_version}",
    "ENV BUILD_ENV=${var.build_environment}",
    "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]",
    "WORKDIR /var/www/app"
  ]
}

build {
  name = "hardened-ubuntu-build"
  sources = [
    "source.docker.ubuntu_base"
  ]

  # Provisioner 1: Bootstrap minimal dependencies required for Ansible
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update && apt-get install -y --no-install-recommends software-properties-common curl git python3-pip ansible",
      "mkdir -p /var/www/app /etc/cloud"
    ]
  }

  # Provisioner 2: Run local Ansible Playbook for system configuration
  provisioner "ansible-local" {
    playbook_file = "ansible/site.yml"
  }

  # Provisioner 3: Image Sanitization Script (Sanitize machine-id, SSH host keys, logs)
  provisioner "shell" {
    script = "scripts/cleanup.sh"
  }

  # Post-Processor: Output artifact metadata manifest
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
```

---

##### Step 4: Create the Local Ansible Playbook and Entrypoint Script
Create the system configuration playbook and runtime entrypoint script referenced by the Packer template.

Write `ansible/site.yml`:

```yaml
---
- name: Hardened Base Image Provisioning
  hosts: localhost
  connection: local
  tasks:
    - name: Create app execution group
      ansible.builtin.group:
        name: appuser
        gid: 2000
        state: present

    - name: Create app execution user
      ansible.builtin.user:
        name: appuser
        uid: 2000
        group: appuser
        shell: /bin/bash
        home: /home/appuser

    - name: Deploy application environment release tag
      ansible.builtin.copy:
        dest: /etc/build_release
        content: |
          BUILD_DATE={{ ansible_date_time.iso8601 }}
          SYS_IMAGE_VERSION=2.4.0
        mode: '0644'
```

Write `scripts/cleanup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Executing System Image Sanitization ==="

# 1. Clear Apt Caches & Unused Packages
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 2. Reset Systemd Machine ID (Forces regeneration on first boot)
if [ -f /etc/machine-id ]; then
    > /etc/machine-id
fi
if [ -f /var/lib/dbus/machine-id ]; then
    rm -f /var/lib/dbus/machine-id
fi

# 3. Purge SSH Host Keys (Prevents duplicate SSH host identity across instances)
rm -f /etc/ssh/ssh_host_*

# 4. Truncate system log files
find /var/log -type f -exec truncate -s 0 {} \;

# 5. Create entrypoint runtime script
cat << 'EOF' > /usr/local/bin/entrypoint.sh
#!/bin/bash
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    dpkg-reconfigure openssh-server 2>/dev/null || true
fi
exec "$@"
EOF
chmod +x /usr/local/bin/entrypoint.sh

echo "=== System Sanitization Complete ==="
```

Ensure `scripts/cleanup.sh` is executable:

```bash
chmod +x scripts/cleanup.sh
```

---

##### Step 5: Initialize Plugins, Validate Template Syntax, and Build Image
Run `packer init` to download required binaries, validate configuration syntax, format code, and execute the build pipeline with full stdout output.

Run command:
```bash
packer init .
packer fmt .
packer validate .
```

Expected output:
```text
The configuration is valid.
```

Run command:
```bash
packer build .
```

Expected output:
```text
hardened-ubuntu-build.docker.ubuntu_base: output will be in this color.

==> hardened-ubuntu-build.docker.ubuntu_base: Creating img folder...
==> hardened-ubuntu-build.docker.ubuntu_base: Pulling Docker image: ubuntu:22.04
    hardened-ubuntu-build.docker.ubuntu_base: 22.04: Pulling from library/ubuntu
    hardened-ubuntu-build.docker.ubuntu_base: Digest: sha256:aab4c9cd...
    hardened-ubuntu-build.docker.ubuntu_base: Status: Image is up to date for ubuntu:22.04
==> hardened-ubuntu-build.docker.ubuntu_base: Starting container...
    hardened-ubuntu-build.docker.ubuntu_base: Container ID: a1b2c3d4e5f6
==> hardened-ubuntu-build.docker.ubuntu_base: Provisioning with shell script...
    hardened-ubuntu-build.docker.ubuntu_base: Get:1 http://archive.ubuntu.com/ubuntu jammy InRelease
    hardened-ubuntu-build.docker.ubuntu_base: Setting up software-properties-common...
==> hardened-ubuntu-build.docker.ubuntu_base: Executing Ansible Locally...
    hardened-ubuntu-build.docker.ubuntu_base: PLAY [Hardened Base Image Provisioning] ********************************
    hardened-ubuntu-build.docker.ubuntu_base: TASK [Create app execution group] ***************************************
    hardened-ubuntu-build.docker.ubuntu_base: changed: [localhost]
    hardened-ubuntu-build.docker.ubuntu_base: TASK [Create app execution user] ****************************************
    hardened-ubuntu-build.docker.ubuntu_base: changed: [localhost]
    hardened-ubuntu-build.docker.ubuntu_base: TASK [Deploy application environment release tag] **********************
    hardened-ubuntu-build.docker.ubuntu_base: changed: [localhost]
==> hardened-ubuntu-build.docker.ubuntu_base: Provisioning with shell script: scripts/cleanup.sh
    hardened-ubuntu-build.docker.ubuntu_base: === Executing System Image Sanitization ===
    hardened-ubuntu-build.docker.ubuntu_base: === System Sanitization Complete ===
==> hardened-ubuntu-build.docker.ubuntu_base: Committing the container...
    hardened-ubuntu-build.docker.ubuntu_base: Image ID: sha256:8f9e0a1b2c3d4e5f...
==> hardened-ubuntu-build.docker.ubuntu_base: Killing the container: a1b2c3d4e5f6
==> hardened-ubuntu-build.docker.ubuntu_base: Running post-processor: manifest
Build 'hardened-ubuntu-build.docker.ubuntu_base' finished after 42 seconds.

==> Builds finished. The artifacts of successful builds are:
--> hardened-ubuntu-build.docker.ubuntu_base: Imported Docker image sha256:8f9e0a1b2c3d4e5f... with tags [hardened-ubuntu-build-1723018800]:latest
```

---

##### Step 6: Verify Build Artifact Metadata and Image Cleanliness
Inspect the generated `manifest.json` file and verify that local system security identifiers were stripped properly.

Run command:
```bash
cat manifest.json
```

Expected output:
```json
{
  "builds": [
    {
      "name": "hardened-ubuntu-build",
      "builder_type": "docker",
      "build_time": 1723018800,
      "files": null,
      "artifact_id": "sha256:8f9e0a1b2c3d4e5f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f",
      "packets": null,
      "custom_data": null
    }
  ],
  "last_run_uuid": "e4d3c2b1-a098-4765-8321-fedcba987654"
}
```

Run container to verify machine ID sanitization:
```bash
docker run --rm sha256:8f9e0a1b2c3d4e5f cat /etc/build_release
```

Expected output:
```text
BUILD_DATE=2026-08-07T12:00:00Z
SYS_IMAGE_VERSION=2.4.0
```

---

#### Verification Questions (Lab 1)

1. **Why is it critical to truncate `/etc/machine-id` and remove `/etc/ssh/ssh_host_*` during the image sanitization stage (`cleanup.sh`) before taking a final VM snapshot or committing a golden container image?**
   - A) To minimize overall disk image size by deleting temporary cache logs.
   - B) To ensure each booted instance generates a unique system identity, D-Bus UUID, and cryptographic SSH identity, avoiding man-in-the-middle vulnerabilities and IP/DHCP collisions across the cluster.
   - C) Because Packer's build engine fails validation if system configuration files exceed 4KB.
   - D) To allow `cloud-init` to reinstall python3 and ansible on the next system startup.

2. **In Packer HCL2, what is the exact functional distinction between a `source` block and a `build` block?**
   - A) `source` blocks define reusable builder configurations (infrastructure driver, base image, credentials); `build` blocks combine sources with provisioners and post-processors to run the build pipeline.
   - B) `source` blocks execute shell provisioners; `build` blocks execute post-processors only.
   - C) `source` blocks compile HCL into JSON; `build` blocks execute API requests against cloud providers.
   - D) `source` blocks are required only for local Docker builds; cloud builders (AWS AMI, QEMU) only require `build` blocks.

---

#### Lab 2: Multi-Target Image Matrix, Security Auditing, and Advanced Diagnostic Troubleshooting

##### Exercise Objective
Implement a multi-target build pipeline combining concurrent image targets (Docker base and QEMU/Cloud VM targets), integrate automated security compliance auditing, and execute real-world debugging workflows using Packer's engine inspection tools (`PACKER_LOG`, `-debug`, and `packer console`).

---

##### Step 1: Construct a Parallel Multi-Source Build Template
Create `multi-build.pkr.hcl` to define multiple execution targets that build concurrently from a unified provisioner baseline.

Write `multi-build.pkr.hcl`:

```hcl
# multi-build.pkr.hcl
packer {
  required_plugins {
    docker = {
      version = ">= 1.0.8"
      source  = "github.com/hashicorp/docker"
    }
  }
}

source "docker" "ubuntu_x86" {
  image  = "ubuntu:22.04"
  commit = true
}

source "docker" "alpine_edge" {
  image  = "alpine:latest"
  commit = true
}

build {
  name = "multi-arch-matrix"
  sources = [
    "source.docker.ubuntu_x86",
    "source.docker.alpine_edge"
  ]

  # Dynamic Provisioner execution targeting specific sources using source.type / source.name conditionals
  provisioner "shell" {
    only = ["docker.ubuntu_x86"]
    inline = [
      "apt-get update && apt-get install -y curl security-checks",
      "echo 'Ubuntu target verified' > /etc/target_marker"
    ]
  }

  provisioner "shell" {
    only = ["docker.alpine_edge"]
    inline = [
      "apk add --no-cache curl bash",
      "echo 'Alpine target verified' > /etc/target_marker"
    ]
  }

  # Shared Provisioner executed across ALL sources in the build matrix
  provisioner "shell" {
    inline = [
      "echo 'Executing common security assertion baseline'",
      "test -s /etc/target_marker"
    ]
  }

  post-processor "manifest" {
    output     = "matrix-manifest.json"
    strip_path = true
  }
}
```

---

##### Step 2: Debugging Build Failures via `PACKER_LOG` and Environment Tracing
When provisioners hang, SSH keys fail to negotiate, or cloud provider APIs return HTTP 40x/50x errors, standard Packer CLI output is insufficient. Set `PACKER_LOG=1` and redirect stderr/stdout to isolate internal gRPC plugin communication.

Execute a debug-level dry-run with detailed engine tracing:

Run command:
```bash
PACKER_LOG=1 PACKER_LOG_PATH="packer-debug.log" packer build multi-build.pkr.hcl
```

Inspect log output for gRPC call dispatching and SSH key negotiations:

Run command:
```bash
head -n 25 packer-debug.log
```

Expected log output snippet:
```text
2026/08/07 12:15:00 [INFO] Packer version: 1.10.0
2026/08/07 12:15:00 Checking plugin github.com/hashicorp/docker v1.0.8...
2026/08/07 12:15:00 Starting plugin /home/dalmine/.packer.d/plugins/github.com/hashicorp/docker/packer-plugin-docker_v1.0.8_x5.0_linux_amd64
2026/08/07 12:15:00 Waiting for RPC server to start...
2026/08/07 12:15:00 plugin address: /tmp/packer-plugin-3928104810
2026/08/07 12:15:00 ui: ==> multi-arch-matrix.docker.ubuntu_x86: Preparing build environment...
2026/08/07 12:15:01 [DEBUG] Docker client initialized with API version 1.41
2026/08/07 12:15:01 Executing provisioner: shell
2026/08/07 12:15:01 [DEBUG] Opening communicator stream over stdin/stdout...
```

---

##### Step 3: Interactive Troubleshooting with `packer build -debug`
When configuring complex cloud instances (e.g., AWS EC2, QEMU, OpenStack), script failures terminate the build VM immediately by default, destroying all forensic evidence. Using `-debug` pauses execution before every step, allowing engineers to inspect the live target machine over SSH.

Demonstrate interactive step pausing:

Run command:
```bash
packer build -debug multi-build.pkr.hcl
```

Expected output:
```text
==> multi-arch-matrix.docker.ubuntu_x86: Pausing at required step: Starting container.
==> multi-arch-matrix.docker.ubuntu_x86: Press enter to continue.
```

At this prompt, in a separate terminal session, inspect the temporary build container directly:

Run command (in secondary terminal):
```bash
docker ps --filter "ancestor=ubuntu:22.04"
```

Expected output:
```text
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS     NAMES
c9e8d7f6a5b4   ubuntu:22.04   "packer-builder-docker"  15 seconds ago   Up 14 seconds            pedantic_hawking
```

Enter the running VM/container build instance to debug live:
```bash
docker exec -it c9e8d7f6a5b4 /bin/bash
```

Inside the build target:
```bash
cat /etc/os-release
exit
```

Return to the primary terminal and press `Enter` to allow Packer to complete the build steps.

---

##### Step 4: Evaluate Expressions via `packer console`
`packer console` starts an interactive REPL environment for testing HCL2 variables, functions, and dynamic data evaluations prior to executing long-running image pipelines.

Run command:
```bash
packer console multi-build.pkr.hcl
```

Interactive REPL sessions:

```text
> var.base_image
"ubuntu:22.04"
> legacy_isotime("2006-01-02-150405")
"2026-08-07-122000"
> upper(var.build_environment)
"PRODUCTION"
> exit
```

---

#### Verification Questions (Lab 2)

1. **When troubleshooting an intermittent provisioner script failure during a Packer build targeting AWS EC2 or QEMU, which execution flag prevents Packer from immediately terminating the temporary VM instance upon error?**
   - A) `--force`
   - B) `-debug`
   - C) `-on-error=ask` or `-debug`
   - D) `PACKER_LOG=0`

2. **In a Packer HCL2 multi-source build definition containing 4 distinct source builders, how can an SRE restrict a specific security audit provisioner block to execute ONLY on the RHEL builder source named `source.qemu.rhel_8`?**
   - A) By adding `except = ["qemu.rhel_8"]` to the provisioner block.
   - B) By setting `only = ["source.qemu.rhel_8"]` inside the provisioner block.
   - C) By creating a separate `packer.hcl` file for every OS builder.
   - D) Provisioners cannot be conditionally filtered across sources within the same `build` block.

3. **What is the structural role of the `manifest` post-processor in a production system image build pipeline?**
   - A) It dynamically writes cloud-init UserData to the target image filesystem prior to system shutdown.
   - B) It generates a structured JSON file detailing built artifacts, builder types, completion timestamps, and artifact IDs (AMI IDs, image SHAs) for downstream deployment consumption.
   - C) It converts container layers into ISO 9660 bootable disk files.
   - D) It verifies GPG signatures of upstream Debian apt package mirrors.

---

### <details><summary>Answers & Comprehensive Explanations</summary>

#### Lab 1 Answers

##### Question 1
- **Correct Answer**: **B**
- **Deep Technical Explanation**:
  When a Linux operating system boots, `systemd` reads `/etc/machine-id` (or generates one if missing/empty) to uniquely identify the OS installation for logging (journald), D-Bus IPC communication, and network stack identifiers (DHCP Client ID). Similarly, SSH daemons use host key pairs stored in `/etc/ssh/ssh_host_*` to authenticate the server to connecting clients.
  
  If a golden system image is captured *without* purging these files:
  1. Every instance launched from that golden image shares the **exact same machine-id**. This causes severe network anomalies, such as DHCP servers assigning identical IP addresses to multiple VMs due to matching client identifiers.
  2. Every instance shares the **exact same SSH host private keys**. An attacker who compromises or intercepts one VM can perform man-in-the-middle (MITM) decryption against traffic routed to any other VM launched from the same base image.
  
  Truncating `/etc/machine-id` (setting it to 0 bytes) and deleting `/etc/ssh/ssh_host_*` forces `systemd` and `openssh-server` to regenerate unique machine IDs and host cryptographic key pairs during the initial boot sequence of newly provisioned instances.

##### Question 2
- **Correct Answer**: **A**
- **Deep Technical Explanation**:
  In Packer HCL2 syntax architecture:
  - The `source` block defines **how to create compute instances** on a specific virtualization provider or container engine. It includes hypervisor-level configuration, machine sizes, credentials, networking parameters, and base image specifications.
  - The `build` block defines **what to do with those compute instances**. It imports one or more `source` blocks, defines the sequential execution pipeline of `provisioner` blocks (which mutate the OS state), and configures `post-processor` blocks (which handle artifact packaging and indexing).
  
  This decoupling allows engineers to reuse a single standardized provisioning block (e.g., CIS Hardening script) across multiple hypervisor sources (e.g., AWS EBS, Azure Managed Disk, QEMU KVM, Docker) simultaneously.

---

#### Lab 2 Answers

##### Question 1
- **Correct Answer**: **C**
- **Deep Technical Explanation**:
  By default, if any command within a provisioner returns a non-zero exit code, Packer immediately aborts execution, sends API calls to destroy the temporary compute instance (EC2 VM, QEMU instance), and cleans up resources. This prevents incurring unnecessary cloud billing costs, but makes forensic debugging impossible.
  
  - Passing `-debug` forces Packer to pause execution after *every single step* and wait for manual user confirmation (Enter key). While paused, the user can inspect the live running build instance, read log files inside `/var/log`, or inspect system state via SSH.
  - Passing `-on-error=ask` configures Packer to run normally until an error occurs. When a provisioner fails, it halts cleanup and asks the operator interactively whether to retry the step, cleanup immediately, or preserve the instance for interactive SSH investigation.

##### Question 2
- **Correct Answer**: **B**
- **Deep Technical Explanation**:
  Within a Packer HCL2 `build` block, provisioners execute across all declared `sources` by default. To selectively run or skip provisioners based on the target builder:
  - The `only` meta-argument takes an array of source labels (formatted as `["source.type.name"]` or `["builder_type.source_name"]`). The provisioner executes **only** when the target matches one of the declared elements.
  - Conversely, the `except` meta-argument excludes declared sources.
  
  `except = ["qemu.rhel_8"]` would run the provisioner on *everything except* RHEL 8, which is the exact inverse of the question requirement.

##### Question 3
- **Correct Answer**: **B**
- **Deep Technical Explanation**:
  The `manifest` post-processor acts as the bridge between image creation (Packer) and infrastructure deployment (Terraform, Ansible, GitOps pipelines). 
  
  When Packer finishes building images across multi-region cloud targets (e.g., creating AMIs `ami-0a1b2c3d4e5f6` in `us-east-1` and `ami-0f9e8d7c6b5a4` in `eu-west-1`), the `manifest` post-processor writes these generated artifact identifiers, build timestamps, and SHA-256 checksums into a deterministic `manifest.json` file. CI/CD automation pipelines parse this JSON file (using tools like `jq`) to inject the newly baked AMI IDs directly into Terraform variable files or Kubernetes deployment manifests.

</details>