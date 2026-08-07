# LPI DevOps Tools Engineer (Exam 701-100) — Topic 3.2: Cloud Deployment

## 1. Architectural Deep Dive & Internal Mechanics

### 1.1 Cloud Deployment Models & Service Abstractions

Modern cloud architecture relies on distinct abstraction layers. As an SRE or Platform Architect, choosing the correct model dictates the boundary of operational responsibility, multi-tenant isolation overhead, and failure domain management.

```
+-------------------------------------------------------------------------+
|                              SaaS Layer                                 |
| (Software-as-a-Service: Gmail, Salesforce, Auth0)                      |
| Managed: Application, Data, Runtime, Middleware, OS, Virtualization, Hardware |
+-------------------------------------------------------------------------+
|                              PaaS Layer                                 |
| (Platform-as-a-Service: AWS Elastic Beanstalk, Heroku, Cloud Foundry)   |
| Managed by User: Application, Data                                      |
| Managed by Cloud: Runtime, Middleware, OS, Virtualization, Hardware     |
+-------------------------------------------------------------------------+
|                              FaaS / Serverless                          |
| (Function-as-a-Service: AWS Lambda, Google Cloud Functions)             |
| Managed by User: Ephemeral Function Logic, Trigger Bindings             |
| Managed by Cloud: Event Bus, Runtime Container, Scaling, Infrastructure |
+-------------------------------------------------------------------------+
|                              IaaS Layer                                 |
| (Infrastructure-as-a-Service: AWS EC2, OpenStack Nova, GCP Compute)    |
| Managed by User: OS Config, App Code, Storage Volumes, Network Topology |
| Managed by Cloud: Hypervisor (KVM/Nitro), Physical Hardware, Datacenter |
+-------------------------------------------------------------------------+
```

#### Architectural Trade-offs & Production Considerations

| Metric / Dimension | IaaS (e.g., OpenStack, AWS EC2) | PaaS (e.g., Heroku, Beanstalk) | FaaS (e.g., AWS Lambda) |
| :--- | :--- | :--- | :--- |
| **Operational Overhead** | High (OS patching, agent install, kernel tuning) | Low (Focus on application packaging) | Minimal (No OS management, automatic scaling) |
| **Customization & Control** | Maximum (Custom kernels, kernel modules, sysctl) | Restricted (Constrained runtimes/buildpacks) | Highly Restricted (Stateless, short duration) |
| **Cold Start Latency** | Minutes (Full OS boot + cloud-init execution) | Seconds (Container instantiation) | Milliseconds to Seconds (Init phase / JIT compilation) |
| **Blast Radius Isolation** | Hardware/Hypervisor Level (KVM, Nitro, Xen) | Process / Container Namespace | MicroVM / Sandbox (Firecracker, gVisor) |
| **Vendor Lock-in Risk** | Low (Portable via OpenStack/Terraform) | Medium (Buildpack or platform-specific specs) | High (Event trigger schemas, provider SDKs) |

---

### 1.2 Instance Bootstrapping Engine: `cloud-init` Architecture

`cloud-init` is the canonical multi-distribution engine for early-stage initialization of cloud instances. It bridges the gap between raw machine image provisioners (such as OpenStack Glance or AWS AMI) and configuration management engines (Ansible, Puppet, Chef).

#### Boot Execution Sequence & Systemd Integration

`cloud-init` executes across **four deterministic boot stages** coordinated via systemd targets:

```
[System Power On / Kernel Boot]
              │
              ▼
┌────────────────────────────────────────────────────────┐
│ 1. Generator Stage (cloud-init-generator)              │
│    Inspects kernel command line & enables cloud-init   │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 2. Local Stage (cloud-init-local.service)              │
│    Reads local metadata (ConfigDrive, NoCloud).        │
│    Brings up loopback; blocks network initialization.  │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 3. Network Stage (cloud-init.service)                  │
│    Fetches remote metadata/user-data (IMDS / 169.254...).│
│    Applies network config (netplan/eni). Runs bootcmd. │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 4. Config Stage (cloud-config.service)                │
│    Executes modules: disk setup, user creation,        │
│    write_files, SSH host keys generation.             │
└─────────────────────────────┬──────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────┐
│ 5. Final Stage (cloud-final.service)                  │
│    Executes runcmd, scripts-per-boot, package installs,│
│    Chef/Puppet hooks. Writes /var/lib/cloud/data/result.│
└────────────────────────────────────────────────────────┘
```

1. **Generator (`cloud-init-generator`)**: Runs inside early initrd/systemd context to determine if `cloud-init` should be enabled on the booted image.
2. **Local (`cloud-init-local.service`)**: Searches local data sources (e.g., attached ConfigDrive ISOs, NoCloud volumes). Configures local networking fallback and blocks networking setup until configuration is parsed.
3. **Network (`cloud-init.service`)**: Queries remote Instance Metadata Services (IMDS at `169.254.169.254`), parses vendor-data and user-data, and writes final OS networking configs (e.g., Netplan or systemd-networkd). Runs early `bootcmd` modules.
4. **Config (`cloud-config.service`)**: Processes structural configuration directives such as `users`, `ssh_authorized_keys`, `write_files`, and disk partitioning options (`disk_setup`, `fs_setup`).
5. **Final (`cloud-final.service`)**: Runs late-boot actions including `packages`, `package_upgrade`, `runcmd`, and custom user scripts. Emits the system status file (`/var/lib/cloud/data/status.json`).

#### User-Data vs. Metadata vs. Vendor-Data

* **Metadata**: Provided by the cloud platform (e.g., OpenStack Keystone/Nova or AWS EC2). Contains non-sensitive instance attributes: `instance-id`, `hostname`, `local-ipv4`, `public-keys`, `ami-id`.
* **User-Data**: Provided by the operator at instance launch. Contains customized scripts or `cloud-config` YAML schemas executed on first boot.
* **Vendor-Data**: Provided by the cloud provider or imagebuilder to enforce security base images, telemetry agents, or default administrative accounts without overwriting user-supplied `user-data`.

---

### 1.3 Infrastructure as Code & Orchestration Mechanics: Terraform & Cloud APIs

Cloud orchestration automates resource management via RESTful APIs (OpenStack Compute/Nova, Networking/Neutron, AWS EC2, VPC). Tools like HashiCorp Terraform implement an imperative-to-declarative translation engine.

```
┌─────────────────────────────────────────────────────────┐
│               Terraform Code (.tf files)                │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│        Terraform Core (Graph Builder Engine)            │
│  Calculates Directed Acyclic Graph (DAG) of dependency   │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│       Provider Plugin (e.g., terraform-provider-aws)    │
│  Translates HCL state delta to OpenAPI / AWS Query API   │
└────────────────────────────┬────────────────────────────┘
                             │ gRPC
                             ▼
┌─────────────────────────────────────────────────────────┐
│          Cloud Control Plane (AWS API / OpenStack)      │
│  Provisions Security Groups, Subnets, Instances, Disks  │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│              Target Cloud Infrastructure                │
└─────────────────────────────────────────────────────────┘
```

#### Terraform State & Lifecycle Mechanics

* **State Management (`terraform.tfstate`)**: Acts as a private registry mapping declared HCL identifiers to real-world cloud Unique IDs (e.g., AWS `i-0a12b34c56def7890` or OpenStack UUIDs).
* **State Locking**: Prevents concurrent execution races by acquiring explicit locks on remote backends (AWS S3 + DynamoDB, HashiCorp Consul, or OpenStack Swift).
* **Drift Detection**: During `terraform plan`, Terraform queries live cloud APIs via `Read()` operations, compares real-world attributes with saved state, and formulates a structural diff tree.
* **Graph Evaluation (DAG)**: Constructs execution ordering automatically based on resource references (e.g., a Subnet depends on a VPC ID; an EC2 Instance depends on a Subnet ID).

---

## 2. Production Manifests & Blueprint Code

### Blueprint 2.1: Production Multi-Part Cloud-Init Manifest (`cloud-config.yaml`)

This syntactically valid YAML manifest configures OS user provisioning, directory structuring, system hardening, environment configuration, package deployment, and custom initialization scripts.

```yaml
#cloud-config
# ==============================================================================
# LPI 701-100 Production Cloud-Init Blueprint
# Objectives: 3.2 Cloud Deployment - System Initialization
# ==============================================================================

version: v1

# 1. User Account Provisioning & System Access Hardening
users:
  - default
  - name: sysadmin
    gecos: System Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, docker, wheel]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOm7Zp8q9rStuVwXyZ0123456789abcdefghijklmn sadmin@infra.company.internal

# 2. Package Repository & System Package Management
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - htop
  - net-tools
  - ufw

# 3. File System Creation & Custom File Injection
write_files:
  - path: /etc/sysctl.d/99-kubernetes-cri.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.ipv4.ip_forward                 = 1
      net.bridge.bridge-nf-call-ip6tables = 1

  - path: /opt/app/bin/healthcheck.sh
    permissions: '0755'
    owner: sysadmin:sysadmin
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      echo "[HEALTHCHECK] Verifying node boot initialization..."
      curl -f http://localhost:8080/health || exit 1
      echo "[HEALTHCHECK] Node is healthy."

  - path: /etc/systemd/system/node-exporter.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Node Exporter Agent
      After=network.target

      [Service]
      Type=simple
      User=nobody
      ExecStart=/usr/local/bin/node_exporter

      [Install]
      WantedBy=multi-user.target

# 4. Command Execution Pipeline (Run in cloud-final.service stage)
runcmd:
  - [ sysctl, --system ]
  - [ systemctl, daemon-reload ]
  - [ ufw, allow, "22/tcp" ]
  - [ ufw, allow, "80/tcp" ]
  - [ ufw, allow, "443/tcp" ]
  - [ ufw, --force, enable ]
  - echo "Cloud-Init execution completed on $(date -u)" > /var/log/cloud-init-bootstrap-complete.log

# 5. Output Management & Telemetry Logging
output:
  all: '| tee -a /var/log/cloud-init-output.log'
```

---

### Blueprint 2.2: Production Infrastructure-as-Code Terraform Module

This multi-file Terraform blueprint constructs an isolated VPC, subnet, gateway, route table, security group, and an IaaS compute instance with the injected `cloud-config` user-data payload.

#### `variables.tf`
```hcl
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Target AWS Region for deployment."
}

variable "environment" {
  type        = string
  default     = "production"
  description = "Deployment lifecycle stage identifier."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "Base CIDR block for the Virtual Private Cloud."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.100.1.0/24"
  description = "CIDR block for the public network subnet."
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "Compute instance hardware profile."
}
```

#### `main.tf`
```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Certification = "LPI-701-100"
    }
  }
}

# Fetch latest Ubuntu 22.04 LTS AMI from canonical
data "aws_ami" "ubuntu_lts" {
  most_recent = true
  owners      = ["099720109477"] # Canonical ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 1. Network Topology Definition
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "${var.environment}-public-subnet"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

# 2. Firewall / Security Group Definition
resource "aws_security_group" "web_sg" {
  name        = "${var.environment}-web-sg"
  description = "Control ingress/egress traffic for cloud instances."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow SSH from trusted management sources"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTP inbound"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment}-web-sg"
  }
}

# 3. Compute Instance Provisioning with Cloud-Init Payload
resource "aws_instance" "web_server" {
  ami                   = data.aws_ami.ubuntu_lts.id
  instance_type         = var.instance_type
  subnet_id             = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = file("${path.module}/cloud-config.yaml")

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.environment}-web-server"
  }
}
```

#### `outputs.tf`
```hcl
output "instance_id" {
  value       = aws_instance.web_server.id
  description = "AWS EC2 Unique Instance Identifier."
}

output "public_ip" {
  value       = aws_instance.web_server.public_ip
  description = "Assigned IPv4 Public Address."
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "Provisioned Virtual Private Cloud Identifier."
}
```

---

## 3. Hands-on Guided Lab Exercises

---

### Lab 3.2.1: Advanced Cloud-Init Engine Diagnostics & Boot Stage Profiling

#### Objective
Understand the execution internals of `cloud-init`, analyze boot timeline bottlenecks, inspect local cache states, query the metadata service (IMDSv2), and force a controlled, clean stage re-execution on a running Linux cloud server.

#### Step-by-Step Execution Sequence

1. **Verify `cloud-init` overall runtime status and detailed system state.**
   Query the status file emitted by `cloud-final.service`.
   ```bash
   sudo cloud-init status --long
   ```
   *Expected Execution Output:*
   ```text
   status: done
   extended_status: done
   boot_status_code: enabled-by-generator
   detail:
   DataSourceCloudInitLocal: DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud][token=/var/lib/cloud/seed/nocloud]
   ```

2. **Analyze stage performance metrics and boot bottlenecks.**
   Use the `cloud-init analyze` diagnostic subcommand to generate a high-precision performance breakdown of each boot stage.
   ```bash
   cloud-init analyze show
   ```
   *Expected Execution Output:*
   ```text
   -- Boot Record 01 --
   The total time elapsed since boot is 18.412s
   ------------------------------------------------------------
   01.002s (init-local)       : starting module init-local
   03.451s (init-network)     : starting search for data-sources
   04.810s (init-network)     : found data-source DataSourceNoCloud
   08.120s (config-modules)   : starting module write_files
   12.304s (config-modules)   : starting module package_update
   18.390s (final-modules)    : starting module runcmd
   ------------------------------------------------------------
   ```

3. **Inspect the underlying low-level logs to trace execution errors or step details.**
   Locate module outputs and system stdout/stderr streams.
   ```bash
   tail -n 25 /var/log/cloud-init.log
   ```
   *Expected Execution Output:*
   ```text
   2026-08-07 04:55:01,102 - handlers.py[DEBUG]: finish: init-network/config-write_files: SUCCESS: config-write_files ran successfully
   2026-08-07 04:55:02,410 - cc_package_update.py[DEBUG]: Running package update pipeline...
   2026-08-07 04:55:08,771 - cc_runcmd.py[DEBUG]: Running command ['sysctl', '--system']
   2026-08-07 04:55:09,004 - util.py[DEBUG]: Cloud-init v. 23.2.2-0ubuntu1~22.04.1 finished at Fri, 07 Aug 2026 04:55:09 +0000. Datasource DataSourceNoCloud. Up 18.41 seconds
   ```

4. **Query the Local Metadata Service (IMDSv2) via HTTP REST endpoints.**
   Obtain an IMDSv2 session token and query instance metadata.
   ```bash
   TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
   echo ""
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4
   echo ""
   ```
   *Expected Execution Output:*
   ```text
   i-03f41a8799b6c4e01
   10.100.1.45
   ```

5. **Perform a controlled `cloud-init` purge and force re-execution on next reboot.**
   Clean cached metadata, delete run logs, and purge instance state artifacts located in `/var/lib/cloud/`.
   ```bash
   sudo cloud-init clean --logs
   ls -la /var/lib/cloud/instance
   ```
   *Expected Execution Output:*
   ```text
   ls: cannot access '/var/lib/cloud/instance': No such file or directory
   ```

---

#### Verification Questions — Lab 3.2.1

**Question 1:** During which specific `cloud-init` boot stage are modules like `disk_setup`, `fs_setup`, and custom `users` executed, and which systemd service manages this stage?
* A) Local stage (`cloud-init-local.service`)
* B) Network stage (`cloud-init.service`)
* C) Config stage (`cloud-config.service`)
* D) Final stage (`cloud-final.service`)

**Question 2:** An SRE notices that a script inside the `runcmd` directive failed to complete successfully during first boot. Which log file contains the combined standard output (stdout) and standard error (stderr) of scripts executed by `runcmd`?
* A) `/var/log/cloud-init.log`
* B) `/var/log/cloud-init-output.log`
* C) `/var/log/syslog`
* D) `/var/lib/cloud/data/status.json`

**Question 3:** What is the technical function of the command `sudo cloud-init clean --logs`?
* A) It uninstalls the `cloud-init` python package and purges all configuration files from `/etc/cloud/`.
* B) It deletes runtime cached data in `/var/lib/cloud/` and log files in `/var/log/cloud-init*`, allowing `cloud-init` to re-run on subsequent boot.
* C) It parses `cloud-config.yaml` for syntax errors without executing any commands.
* D) It resets the instance hostname to default and releases the DHCP IP lease.

---

### Lab 3.2.2: Declarative Infrastructure Management with Terraform & Drift Remediation

#### Objective
Initialize a production Terraform directory, plan and provision cloud resources, inspect state graph dynamics, simulate out-of-band state drift, and reconcile real-world resources using declarative HCL execution plans.

#### Step-by-Step Execution Sequence

1. **Initialize the working directory and load provider binaries.**
   Download provider plugins defined in `main.tf`.
   ```bash
   terraform init
   ```
   *Expected Execution Output:*
   ```text
   Initializing the backend...

   Initializing provider plugins...
   - Finding hashicorp/aws versions matching "~> 5.0"...
   - Installing hashicorp/aws v5.35.0...
   - Installed hashicorp/aws v5.35.0 (signed by HashiCorp)

   Terraform has been successfully initialized!
   ```

2. **Generate and inspect an execution plan.**
   Run `terraform plan` to build the Directed Acyclic Graph (DAG) and output the resource creation plan to a binary file (`tfplan`).
   ```bash
   terraform plan -out=tfplan
   ```
   *Expected Execution Output:*
   ```text
   Terraform will perform the following actions:

     # aws_instance.web_server will be created
     + resource "aws_instance" "web_server" {
         + ami                          = "ami-0c7217cdde317cfec"
         + instance_type                = "t3.micro"
         + user_data                    = "a4b1c2..." # hash calculated
         + root_block_device {
             + delete_on_termination = true
             + encrypted             = true
             + volume_size           = 20
             + volume_type           = "gp3"
           }
       }

     # aws_vpc.main will be created
     + resource "aws_vpc" "main" {
         + cidr_block           = "10.100.0.0/16"
         + enable_dns_hostnames = true
       }

   Plan: 6 to add, 0 to change, 0 to destroy.
   ------------------------------------------------------------------------
   Saved the plan to: tfplan
   ```

3. **Apply the execution plan to provision resources.**
   Apply the compiled binary plan `tfplan`.
   ```bash
   terraform apply "tfplan"
   ```
   *Expected Execution Output:*
   ```text
   aws_vpc.main: Creating...
   aws_vpc.main: Creation complete after 3s [id=vpc-08f3214abc]
   aws_internet_gateway.gw: Creating...
   aws_subnet.public: Creating...
   aws_internet_gateway.gw: Creation complete after 2s [id=igw-09912a]
   aws_subnet.public: Creation complete after 3s [id=subnet-01123bc]
   aws_security_group.web_sg: Creating...
   aws_security_group.web_sg: Creation complete after 2s [id=sg-0a887ff]
   aws_instance.web_server: Creating...
   aws_instance.web_server: Still creating... [10s elapsed]
   aws_instance.web_server: Creation complete after 14s [id=i-03f41a8799b6c4e01]

   Apply complete! Resources: 6 added, 0 changed, 0 destroyed.

   Outputs:
   instance_id = "i-03f41a8799b6c4e01"
   public_ip = "54.210.12.88"
   vpc_id = "vpc-08f3214abc"
   ```

4. **Inspect resource state mapping.**
   Verify how HCL logical resource names correlate with actual Cloud infrastructure IDs inside `terraform.tfstate`.
   ```bash
   terraform state list
   terraform state show aws_instance.web_server
   ```
   *Expected Execution Output:*
   ```text
   aws_internet_gateway.gw
   aws_instance.web_server
   aws_route_table.public_rt
   aws_route_table_association.public_assoc
   aws_security_group.web_sg
   aws_subnet.public
   aws_vpc.main

   # aws_instance.web_server:
   resource "aws_instance" "web_server" {
       ami                          = "ami-0c7217cdde317cfec"
       arn                          = "arn:aws:ec2:us-east-1:123456789012:instance/i-03f41a8799b6c4e01"
       id                           = "i-03f41a8799b6c4e01"
       instance_state               = "running"
       instance_type                = "t3.micro"
       public_ip                    = "54.210.12.88"
       subnet_id                    = "subnet-01123bc"
       vpc_security_group_ids       = [
           "sg-0a887ff",
       ]
   }
   ```

5. **Simulate infrastructure drift and perform automated remediation.**
   Simulate an out-of-band manual modification (e.g., modifying security group tags or adding an out-of-band rule via AWS CLI). Then run `terraform plan` to verify Terraform's drift detection engine.
   ```bash
   # Simulate out-of-band manual modification using AWS CLI
   aws ec2 create-tags --resources sg-0a887ff --tags Key=Environment,Value=staging-manual-drift

   # Execute drift analysis
   terraform plan
   ```
   *Expected Execution Output:*
   ```text
   Note: Objects have changed outside of Terraform

   Terraform detected the following changes made outside of Terraform since the last "terraform apply":

     # aws_security_group.web_sg has changed
   ~ resource "aws_security_group" "web_sg" {
         id                     = "sg-0a887ff"
       ~ tags                   = {
           ~ "Environment" = "staging-manual-drift" -> "production"
             # (2 unchanged elements hidden)
         }
         # (7 unchanged attributes hidden)
     }

   Unless you have made equivalent changes to your configuration, your plan contents are targeted to
   restore the configured values.

   Plan: 0 to add, 1 to change, 0 to destroy.
   ```

---

#### Verification Questions — Lab 3.2.2

**Question 4:** What command allows an SRE to inspect the current attributes of a managed resource stored inside the state file without opening the raw `terraform.tfstate` JSON file manually?
* A) `terraform inspect aws_instance.web_server`
* B) `terraform state show aws_instance.web_server`
* C) `terraform get aws_instance.web_server`
* D) `terraform show -json`

**Question 5:** What happens during `terraform plan` when the real-world infrastructure state differs from the configuration defined in `.tf` files and stored in `.tfstate`?
* A) Terraform throws an unrecoverable exception and aborts execution.
* B) Terraform updates the local HCL code files automatically to match the cloud provider's real-world state.
* C) Terraform performs a refresh operation against provider APIs, detects the state drift, and prints an execution plan to bring real-world infrastructure back into alignment with HCL declarations.
* D) Terraform deletes the state file and performs a complete re-import of all resources.

**Question 6:** An architect sets `create_before_destroy = true` within the `lifecycle` block of an `aws_instance` resource in HCL. What is the operational effect when a modification requires replacing the compute instance?
* A) Terraform destroys the existing instance first, waits 5 minutes, and then launches the replacement instance.
* B) Terraform provisions the new replacement instance first, and only destroys the old instance after the new one is created, minimizing service downtime.
* C) Terraform prevents the instance from ever being deleted or modified under any circumstances.
* D) Terraform creates a snapshot backup of the attached root EBS volume before destroying the instance.

---

## 4. Verification Answers & Explanations

<details>
<summary>Click to expand Answer Key & Detailed Architectural Explanations</summary>

### Answer 1: C
**Explanation:**
`cloud-init` runs in four primary sequential boot stages handled by distinct systemd services:
1. `cloud-init-local.service` (Local stage): Locates local metadata/ConfigDrive without full network dependencies.
2. `cloud-init.service` (Network stage): Fetches remote metadata over HTTP (`169.254.169.254`), writes OS network configurations (Netplan/eni), and runs early `bootcmd`.
3. `cloud-config.service` (Config stage): Executes structural configuration modules including `disk_setup`, `fs_setup`, `mounts`, `users`, `groups`, and `write_files`.
4. `cloud-final.service` (Final stage): Executes late-stage provisioning actions like `packages`, `package_upgrade`, and `runcmd` scripts.

*Ref: LPI DevOps Tools Engineer Objective 3.2 — Bootstrapping instances with cloud-init.*

---

### Answer 2: B
**Explanation:**
* `/var/log/cloud-init-output.log` captures the raw standard output (`stdout`) and standard error (`stderr`) streams generated by subcommands, scripts, and modules executed during the initialization phase (including `runcmd` entries and user-data shell scripts).
* `/var/log/cloud-init.log` contains detailed debug trace logging produced internally by the `cloud-init` Python engine handlers, showing timestamped internal stage state transitions.

*Ref: LPI DevOps Tools Engineer Objective 3.2 — Debugging cloud-init logs.*

---

### Answer 3: B
**Explanation:**
The `cloud-init clean` command cleans instance-specific cached metadata stored under `/var/lib/cloud/` (such as `/var/lib/cloud/instance`, `/var/lib/cloud/instances/`, and seed data caches). Passing `--logs` also purges historical execution logs from `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`. Upon the next system boot, `cloud-init` detects the absence of state markers and re-triggers full instance bootstrapping as if it were a newly launched VM.

*Ref: LPI DevOps Tools Engineer Objective 3.2 — Re-bootstrapping and testing instance initialization.*

---

### Answer 4: B
**Explanation:**
The subcommand `terraform state show <RESOURCE_ADDRESS>` reads the recorded state entry from the state backend for a specific resource identifier and renders its key-value metadata attributes in a readable format. `terraform state list` lists all tracked resource addresses, whereas `terraform state show` outputs detailed attribute breakdowns.

*Ref: LPI DevOps Tools Engineer Objective 3.2 — Terraform state management.*

---

### Answer 5: C
**Explanation:**
Terraform follows a declarative design model. During `terraform plan`:
1. It queries provider APIs (`Read()` operations) to read current infrastructure state.
2. It compares live state against the desired state defined in `.tf` HCL files and stored in `.tfstate`.
3. It constructs an execution graph containing the structural delta (drift) and displays the specific create (`+`), update (`~`), or destroy (`-`) actions required to reconcile real-world infrastructure with the declared configuration.

*Ref: LPI DevOps Tools Engineer Objective 3.2 — Infrastructure as Code state lifecycle and drift detection.*

---

### Answer 6: B
**Explanation:**
By default, when a resource attribute modification requires resource replacement (such as changing an AMI ID or VPC subnet on certain cloud resources), Terraform destroys the existing resource first and then provisions the new replacement (`destroy-before-create`). Setting `lifecycle { create_before_destroy = true }` reverses this order: Terraform provisions the replacement resource first, updates dependent references, and subsequently deletes the legacy resource, reducing operational downtime.

*Ref: LPI DevOps Tools Engineer Objective 3.2 — Advanced IaC provisioning and lifecycle constraints.*

</details>

---

## 5. Official References & Documentation Links

* [LPI DevOps Tools Engineer Exam 701-100 Objectives](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0)
* [Linux Professional Institute Official Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* [Official Cloud-Init Documentation & Boot Stages](https://cloudinit.readthedocs.io/en/latest/explanation/boot.html)
* [HashiCorp Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
* [OpenStack Compute (Nova) Command-Line Documentation](https://docs.openstack.org/nova/latest/)
* [AWS EC2 Instance Metadata Service (IMDSv2) Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)