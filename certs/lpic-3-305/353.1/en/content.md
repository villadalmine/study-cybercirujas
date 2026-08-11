# Topic 353.1 — Cloud Management Tools

**Certification:** LPIC-3 305 · **Exam:** 305-300 (v3.0) · **Objective weight:** 3.33
**Profile:** SRE / Platform Architect · **Language:** English

> **Objective scope (LPI 353.1).** Understand common offerings in public clouds; basic feature knowledge of **OpenStack** and **Terraform**; awareness of **CloudStack**, **Eucalyptus** and **OpenNebula**. Terms: IaaS/PaaS/SaaS, public/private/hybrid cloud, OpenStack, Terraform, CloudStack, Eucalyptus, OpenNebula.

---

## 1. The production problem: what "cloud management" actually manages

An SRE inherits a fleet, not a single host. The moment you have more than a handful of virtual machines the operational failure modes are no longer *"the VM is down"* — they become:

- **Configuration drift.** VM #47 was patched by hand at 03:00 during an incident and is now the only host in the fleet that still boots. Nobody knows why it is different, and nobody can rebuild it.
- **Snowflake infrastructure.** Every environment (dev, staging, prod) was clicked into existence through a web console by different people at different times. They are *supposed* to be identical. They are not, and the divergence only surfaces during a failover.
- **No reproducibility / no rollback.** There is no artifact that says "this is what prod is." You cannot diff it, review it, or recreate it in another region after a datacenter loss.
- **Undefined blast radius.** A change to a shared network or security group is applied live, by hand, with no plan and no preview of what it will touch.

Cloud management tools exist to convert infrastructure from a *manually-operated system* into a *declaratively-defined, version-controlled, machine-reconciled system*. They split cleanly into **two architectural layers**, and conflating them is the most common conceptual error the exam (and production) punishes:

| Layer | Question it answers | Objective 353.1 members |
|---|---|---|
| **Cloud platform (the control plane / the IaaS itself)** | "Where do compute, network and storage *come from*?" It **is** the cloud: it runs on your hardware, exposes an API, and hands out VMs, networks and volumes. | **OpenStack, CloudStack, OpenNebula, Eucalyptus** |
| **Provisioning / IaC tool (the client)** | "How do I *describe and drive* resources on top of a cloud API — declaratively, reproducibly, reviewably?" It owns no hardware; it talks to a cloud's API. | **Terraform** |

OpenStack **is a cloud**. Terraform **drives** a cloud. You run Terraform *against* OpenStack (or AWS, or Azure). You do not run OpenStack against Terraform. Keep this asymmetry in mind for every comparison that follows.

---

## 2. Service and deployment models (IaaS / PaaS / SaaS · public / private / hybrid)

### 2.1 Service models — the NIST layering

The service model defines **where the management boundary sits** — i.e. what the provider operates and what you operate. This is the "shared responsibility" line.

| Layer you consume | Model | Provider operates | You operate | Canonical examples |
|---|---|---|---|---|
| Virtual hardware (compute, block/object storage, virtual networks) | **IaaS** | Physical DC, hypervisor, host network, storage backend | OS, patching, runtime, app, data, firewall rules | OpenStack (Nova), AWS EC2, GCP Compute Engine |
| Managed runtime / platform | **PaaS** | Everything up to and including the OS + runtime + autoscaling | App code, config, data | Cloud Foundry, OpenShift (as a platform), Heroku, App Engine |
| Finished application | **SaaS** | Entire stack | Your data and user config only | Gmail, Salesforce, Nextcloud (hosted) |

```
     control moves DOWN ▼                            responsibility moves UP ▲
  ┌───────────┬───────────┬───────────┐
  │   IaaS    │   PaaS    │   SaaS    │
  ├───────────┼───────────┼───────────┤
  │ Data      │ Data      │ Data      │   ← you
  │ App       │ App       │ ░App░     │
  │ Runtime   │ ░Runtime░ │ ░Runtime░ │
  │ OS        │ ░OS░      │ ░OS░      │
  │ Virt.     │ ░Virt.░   │ ░Virt.░   │   ░ = provider-operated
  │ HW/Net    │ ░HW/Net░  │ ░HW/Net░  │
  └───────────┴───────────┴───────────┘
```

**Why an SRE cares:** the model dictates your on-call surface. On IaaS a kernel CVE is *your* 2 a.m. page; on PaaS it is the provider's. LPIC-3 305 lives almost entirely in the **IaaS** layer, because that is the layer OpenStack/CloudStack/OpenNebula/Eucalyptus implement.

### 2.2 Deployment models

| Model | Where it runs | Tenancy | Primary driver | SRE trade-off |
|---|---|---|---|---|
| **Public cloud** | Provider's DC | Multi-tenant | Elastic capacity, opex, no CapEx | Data residency, egress cost, noisy-neighbor, vendor lock-in |
| **Private cloud** | Your DC (or dedicated) | Single-org | Data sovereignty, regulatory, predictable cost at scale | You own the control plane's uptime — OpenStack becomes *your* pager |
| **Hybrid cloud** | Both, integrated | Mixed | Burst-to-public, DR, gradual migration | Networking + identity federation complexity; two failure domains |
| **Multi-cloud** | ≥2 public providers | Mixed | Avoid lock-in, best-of-breed | Lowest-common-denominator abstractions; this is Terraform's core value proposition |

The private/hybrid axis is precisely *why OpenStack exists*: it is the way to build a **public-cloud-like IaaS API on hardware you own**, so the same tooling (Terraform, Heat, cloud-init) works on-prem and in a public cloud.

---

## 3. OpenStack — the reference open-source private IaaS

OpenStack is **basic feature knowledge** on the exam, but as a Platform Architect you must understand its control-plane decomposition, because every operational failure maps to one component.

### 3.1 Architecture: a set of cooperating services behind one identity and one message bus

OpenStack is not one program; it is a **collection of independent services**, each exposing a REST API, coordinated through a shared **message queue** (AMQP — RabbitMQ by default) and a shared **SQL database** (MariaDB/Galera in production for HA). Every API call is authenticated by **Keystone**.

```
                         ┌──────────────────────────────────────────┐
        openstack CLI /  │              Horizon (Dashboard)          │
        Terraform / Heat └───────────────────┬──────────────────────┘
                    │                         │  (all REST, token-authed)
                    ▼                         ▼
          ┌───────────────┐  auth token  ┌─────────────────────────────────┐
          │   Keystone    │◄────────────►│  Nova  Neutron  Glance  Cinder   │
          │  (Identity,   │              │  Swift  Placement  Heat  Octavia │
          │  catalog,     │              │  Ironic  Designate  Barbican ... │
          │  tokens)      │              └───────────────┬─────────────────┘
          └───────────────┘                              │
                    ▲                                     │ RPC over AMQP
                    │                                     ▼
          ┌─────────┴───────────────────────────────────────────────────┐
          │   RabbitMQ (message bus)      MariaDB/Galera (state)          │
          └───────────────────────────────────────────────────────────────┘
                                       │
        ┌──────────────────┬───────────┴──────────┬──────────────────┐
        ▼                  ▼                       ▼                  ▼
   nova-compute       neutron agents          cinder-volume      compute nodes
   (libvirt/KVM)      (OVS/OVN, L3, DHCP)     (LVM/Ceph)         (hypervisors)
```

### 3.2 The core services you must be able to name and place

| Service | Project name | Function (IaaS primitive it provides) | Analogous AWS service |
|---|---|---|---|
| Identity | **Keystone** | AuthN/AuthZ, service catalog, token issuance, projects/domains | IAM + STS |
| Compute | **Nova** | Lifecycle of VM instances, scheduling onto hypervisors (libvirt/KVM) | EC2 |
| Placement | **Placement** | Tracks resource inventory/usage; Nova scheduler queries it | (internal) |
| Networking | **Neutron** | Virtual networks, subnets, routers, ports, SGs, floating IPs (OVS/OVN) | VPC |
| Image | **Glance** | Stores/serves VM base images (qcow2, raw) | AMI registry |
| Block storage | **Cinder** | Persistent block volumes attachable to instances | EBS |
| Object storage | **Swift** | Eventually-consistent object store (S3-like) | S3 |
| Orchestration | **Heat** | Declarative stacks via HOT templates; native IaC | CloudFormation |
| Dashboard | **Horizon** | Web UI over the APIs | Console |
| Load balancing | **Octavia** | LBaaS (Amphora VMs / OVN) | ELB/ALB |
| Bare metal | **Ironic** | Provisions physical machines through the Nova API | — |
| DNS | **Designate** | DNSaaS | Route 53 |
| Key mgmt | **Barbican** | Secrets/keys, volume encryption | KMS |
| Telemetry | **Ceilometer/Gnocchi/Aodh** | Metering, time-series, alarms (drives autoscaling) | CloudWatch |

**Release cadence (context for versioning).** OpenStack ships every 6 months with an alphabetical, then date-based, codename: … *Wallaby, Xena, Yoga, Zed*, then the switch to date-based — *2023.1 Antelope, 2023.2 Bobcat, 2024.1 Caracal, 2024.2 Dalmatian, …*. Alternating releases are **SLURP** ("Skip-Level Upgrade Release Process") targets, letting operators upgrade once a year across two releases instead of every six months — a real production concern for control-plane maintenance windows.

### 3.3 Authentication and the `openstack` unified client

Everything starts by sourcing credentials. The canonical mechanism is an **RC file** (or `clouds.yaml`) that populates the `OS_*` environment variables consumed by the CLI and by Terraform's provider.

```bash
$ cat admin-openrc.sh
export OS_AUTH_URL=https://keystone.cloud.example.net:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USERNAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PASSWORD=REDACTED
export OS_REGION_NAME=RegionOne

$ source admin-openrc.sh
$ openstack token issue
+------------+------------------------------------------------------------+
| Field      | Value                                                      |
+------------+------------------------------------------------------------+
| expires    | 2026-08-11T14:07:52+0000                                   |
| id         | gAAAAABm...q7Xk                                            |
| project_id | 4e2c1f0a9b7d4c6e8a1b2c3d4e5f6a7b                           |
| user_id    | 9f8e7d6c5b4a39281706f5e4d3c2b1a0                           |
+------------+------------------------------------------------------------+
```

Discovering the deployment — the two commands you run first on any unfamiliar OpenStack:

```bash
$ openstack service list
+----------------------------------+-----------+----------------+
| ID                               | Name      | Type           |
+----------------------------------+-----------+----------------+
| 1b0f...                          | keystone  | identity       |
| 2c1a...                          | nova      | compute        |
| 3d2b...                          | placement | placement      |
| 4e3c...                          | neutron   | network        |
| 5f4d...                          | glance    | image          |
| 6a5e...                          | cinder    | block-storage  |
| 7b6f...                          | swift     | object-store   |
| 8c70...                          | heat      | orchestration  |
+----------------------------------+-----------+----------------+

$ openstack endpoint list --service compute
+--------+-----------+--------------+--------------+---------+-----------+-------------------------------------------+
| ID     | Region    | Service Name | Service Type | Enabled | Interface | URL                                       |
+--------+-----------+--------------+--------------+---------+-----------+-------------------------------------------+
| a1b2.. | RegionOne | nova         | compute      | True    | public    | https://nova.cloud.example.net:8774/v2.1  |
| c3d4.. | RegionOne | nova         | compute      | True    | internal  | http://10.0.0.11:8774/v2.1                |
| e5f6.. | RegionOne | nova         | compute      | True    | admin     | http://10.0.0.11:8774/v2.1                |
+--------+-----------+--------------+--------------+---------+-----------+-------------------------------------------+
```

Inspecting compute capacity (a Platform Architect's first health check):

```bash
$ openstack hypervisor list
+----+---------------------+-----------------+--------------+-------+
| ID | Hypervisor Hostname | Hypervisor Type | Host IP      | State |
+----+---------------------+-----------------+--------------+-------+
|  1 | cmp01.cloud.local   | QEMU            | 10.0.0.21    | up    |
|  2 | cmp02.cloud.local   | QEMU            | 10.0.0.22    | up    |
|  3 | cmp03.cloud.local   | QEMU            | 10.0.0.23    | down  |
+----+---------------------+-----------------+--------------+-------+

$ openstack flavor list
+----+-----------+-------+------+-----------+-------+-----------+
| ID | Name      |   RAM | Disk | Ephemeral | VCPUs | Is Public |
+----+-----------+-------+------+-----------+-------+-----------+
| 1  | m1.small  |  2048 |   20 |         0 |     1 | True      |
| 2  | m1.medium |  4096 |   40 |         0 |     2 | True      |
| 3  | m1.large  |  8192 |   80 |         0 |     4 | True      |
+----+-----------+-------+------+-----------+-------+-----------+
```

Launching an instance imperatively (the thing IaC replaces):

```bash
$ openstack server create \
    --image ubuntu-22.04 \
    --flavor m1.small \
    --network private-net \
    --key-name sre-key \
    --security-group web-sg \
    --user-data cloud-init.yaml \
    web01
+-------------------------------------+-----------------------------------------------+
| Field                               | Value                                         |
+-------------------------------------+-----------------------------------------------+
| OS-DCF:diskConfig                   | MANUAL                                         |
| OS-EXT-STS:power_state              | NOSTATE                                        |
| OS-EXT-STS:vm_state                 | building                                      |
| id                                  | 7c9e6679-7425-40de-944b-e07fc1f90ae7          |
| name                                | web01                                         |
| status                              | BUILD                                         |
+-------------------------------------+-----------------------------------------------+

$ openstack server list
+--------+-------+--------+----------------------------------+--------------+----------+
| ID     | Name  | Status | Networks                         | Image        | Flavor   |
+--------+-------+--------+----------------------------------+--------------+----------+
| 7c9e.. | web01 | ACTIVE | private-net=192.168.100.14       | ubuntu-22.04 | m1.small |
+--------+-------+--------+----------------------------------+--------------+----------+
```

### 3.4 Heat — OpenStack's *native* IaC (a complete, valid HOT template)

Heat consumes **HOT** (Heat Orchestration Template) YAML and materialises it as a **stack**. Unlike Terraform, Heat is a *service inside the cloud* — the state lives server-side in Heat's DB, and Heat can wire in autoscaling via Aodh alarms. The template below is complete and syntactically valid: it builds an isolated tenant network, a router to the external network, a security group, and a server with a floating IP.

```yaml
heat_template_version: 2018-08-31

description: >
  Reference web tier: private network + router to the external network,
  a security group allowing SSH/HTTP/HTTPS, one Nova instance and a
  floating IP for external reachability. Demonstrates parameters,
  intrinsic functions (get_param / get_resource / get_attr) and outputs.

parameters:
  image:
    type: string
    label: Base image
    description: Name or UUID of a Glance image
    default: ubuntu-22.04
  flavor:
    type: string
    default: m1.small
    constraints:
      - custom_constraint: nova.flavor
  key_name:
    type: string
    description: Existing Nova keypair for SSH
    default: sre-key
  public_net:
    type: string
    description: Name/UUID of the external (provider) network for floating IPs
    default: public
  private_cidr:
    type: string
    default: 192.168.100.0/24

resources:

  private_net:
    type: OS::Neutron::Net
    properties:
      name: heat-private-net

  private_subnet:
    type: OS::Neutron::Subnet
    properties:
      name: heat-private-subnet
      network_id: { get_resource: private_net }
      cidr: { get_param: private_cidr }
      ip_version: 4
      dns_nameservers: [ "1.1.1.1", "9.9.9.9" ]
      enable_dhcp: true

  router:
    type: OS::Neutron::Router
    properties:
      name: heat-router
      external_gateway_info:
        network: { get_param: public_net }

  router_interface:
    type: OS::Neutron::RouterInterface
    properties:
      router_id: { get_resource: router }
      subnet_id: { get_resource: private_subnet }

  web_secgroup:
    type: OS::Neutron::SecurityGroup
    properties:
      name: heat-web-sg
      rules:
        - { protocol: tcp, port_range_min: 22,  port_range_max: 22,  remote_ip_prefix: 0.0.0.0/0 }
        - { protocol: tcp, port_range_min: 80,  port_range_max: 80,  remote_ip_prefix: 0.0.0.0/0 }
        - { protocol: tcp, port_range_min: 443, port_range_max: 443, remote_ip_prefix: 0.0.0.0/0 }
        - { protocol: icmp, remote_ip_prefix: 0.0.0.0/0 }

  web_port:
    type: OS::Neutron::Port
    properties:
      network_id: { get_resource: private_net }
      security_groups: [ { get_resource: web_secgroup } ]
      fixed_ips:
        - subnet_id: { get_resource: private_subnet }

  web_server:
    type: OS::Nova::Server
    properties:
      name: heat-web01
      image: { get_param: image }
      flavor: { get_param: flavor }
      key_name: { get_param: key_name }
      networks:
        - port: { get_resource: web_port }
      user_data_format: RAW
      user_data: |
        #cloud-config
        package_update: true
        packages:
          - nginx
        runcmd:
          - systemctl enable --now nginx

  web_floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network: { get_param: public_net }

  web_floating_ip_assoc:
    type: OS::Neutron::FloatingIPAssociation
    properties:
      floatingip_id: { get_resource: web_floating_ip }
      port_id: { get_resource: web_port }

outputs:
  instance_name:
    description: Nova instance name
    value: { get_attr: [ web_server, name ] }
  private_ip:
    description: Fixed IP on the tenant network
    value: { get_attr: [ web_port, fixed_ips, 0, ip_address ] }
  public_ip:
    description: Floating IP reachable from outside
    value: { get_attr: [ web_floating_ip, floating_ip_address ] }
```

Driving it:

```bash
$ openstack stack create -t web-tier.yaml \
    --parameter public_net=public web-tier
+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| id                  | 0e1f2a3b-4c5d-6e7f-8a9b-0c1d2e3f4a5b |
| stack_name          | web-tier                             |
| stack_status        | CREATE_IN_PROGRESS                   |
| creation_time       | 2026-08-11T13:40:02Z                 |
+---------------------+--------------------------------------+

$ openstack stack list
+--------+------------+-----------------+----------------------+
| ID     | Stack Name | Stack Status    | Creation Time        |
+--------+------------+-----------------+----------------------+
| 0e1f.. | web-tier   | CREATE_COMPLETE | 2026-08-11T13:40:02Z |
+--------+------------+-----------------+----------------------+

$ openstack stack output show web-tier public_ip
+--------------+----------------------------------+
| Field        | Value                            |
+--------------+----------------------------------+
| description  | Floating IP reachable from outside|
| output_key   | public_ip                        |
| output_value | 203.0.113.42                     |
+--------------+----------------------------------+
```

---

## 4. Terraform — declarative, provider-agnostic infrastructure as code

Terraform is the exam's second **basic feature knowledge** item and the industry-standard IaC provisioner. Its architecture is what makes it different from Heat: Terraform is a **client-side binary** that reconciles a **declared desired state (HCL)** against a **recorded actual state (the state file)** by calling **provider plugins** that translate resources into a target cloud's API.

### 4.1 Architecture and core concepts

```
   *.tf (HCL)  ── desired state ──┐
                                  ▼
                        ┌──────────────────┐    provider plugin (gRPC)
   terraform state ────►│  Terraform Core  │───────────────►  OpenStack / AWS / ...
   (actual state)       │  (graph + diff)  │◄───────────────  cloud REST API
                        └──────────────────┘   refresh (read live state)
                                  │
                                  ▼
                     plan  =  desired  Δ  (actual ∪ live)
```

| Concept | What it is | Why it matters operationally |
|---|---|---|
| **Provider** | Plugin implementing CRUD for a cloud's resources (`openstack`, `aws`, `google`…) | One tool, many clouds — the multi-cloud value proposition |
| **Resource** | A declared managed object (`openstack_compute_instance_v2`) | The unit Terraform creates/updates/destroys |
| **Data source** | Read-only lookup of pre-existing objects | Reference infra you don't manage |
| **State** | JSON mapping HCL addresses → real resource IDs | **The source of truth for what Terraform believes exists.** Loss/corruption = orphaned resources |
| **Backend** | Where state lives (local file, Swift, S3, Consul, TFE) | Remote + **locking** is mandatory for a team; local state races |
| **Plan** | Computed diff before any change | The reviewable, blast-radius-bounding artifact Heat/console lack |
| **Module** | Reusable parameterised group of resources | DRY across environments |

### 4.2 A complete Terraform configuration for the OpenStack provider

Equivalent infrastructure to the Heat stack above, expressed as reviewable HCL with a **remote, locked state backend** (Swift), variables, and outputs.

```hcl
# versions.tf — pin the core and provider; never float in production
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.1"
    }
  }

  # Remote, lock-capable state in OpenStack Swift.
  backend "swift" {
    container         = "terraform-state"
    state_name        = "web-tier/terraform.tfstate"
    lock              = true
    # auth comes from the standard OS_* env vars (same as the CLI)
  }
}

provider "openstack" {
  # Reads OS_AUTH_URL / OS_USERNAME / OS_PASSWORD / OS_PROJECT_NAME /
  # OS_*_DOMAIN_NAME / OS_REGION_NAME from the sourced RC file.
}
```

```hcl
# variables.tf
variable "image_name" {
  type    = string
  default = "ubuntu-22.04"
}

variable "flavor_name" {
  type    = string
  default = "m1.small"
}

variable "key_pair" {
  type    = string
  default = "sre-key"
}

variable "public_network" {
  type    = string
  default = "public"
}

variable "private_cidr" {
  type    = string
  default = "192.168.100.0/24"
}
```

```hcl
# main.tf
# --- Look up objects we do NOT manage ---------------------------------------
data "openstack_images_image_v2" "base" {
  name        = var.image_name
  most_recent = true
}

data "openstack_networking_network_v2" "public" {
  name = var.public_network
}

# --- Tenant network + subnet ------------------------------------------------
resource "openstack_networking_network_v2" "private" {
  name           = "tf-private-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private" {
  name            = "tf-private-subnet"
  network_id      = openstack_networking_network_v2.private.id
  cidr            = var.private_cidr
  ip_version      = 4
  dns_nameservers = ["1.1.1.1", "9.9.9.9"]
}

# --- Router to the external network ----------------------------------------
resource "openstack_networking_router_v2" "router" {
  name                = "tf-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.public.id
}

resource "openstack_networking_router_interface_v2" "router_iface" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.private.id
}

# --- Security group ---------------------------------------------------------
resource "openstack_networking_secgroup_v2" "web" {
  name        = "tf-web-sg"
  description = "SSH/HTTP/HTTPS ingress"
}

locals {
  ingress_ports = [22, 80, 443]
}

resource "openstack_networking_secgroup_rule_v2" "web_ingress" {
  for_each          = toset([for p in local.ingress_ports : tostring(p)])
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.web.id
}

# --- Port + instance --------------------------------------------------------
resource "openstack_networking_port_v2" "web" {
  name               = "tf-web-port"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.web.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_compute_instance_v2" "web" {
  name        = "tf-web01"
  image_id    = data.openstack_images_image_v2.base.id
  flavor_name = var.flavor_name
  key_pair    = var.key_pair

  network {
    port = openstack_networking_port_v2.web.id
  }

  user_data = <<-EOT
    #cloud-config
    package_update: true
    packages: [nginx]
    runcmd:
      - systemctl enable --now nginx
  EOT
}

# --- Floating IP ------------------------------------------------------------
resource "openstack_networking_floatingip_v2" "web" {
  pool = var.public_network
}

resource "openstack_networking_floatingip_associate_v2" "web" {
  floating_ip = openstack_networking_floatingip_v2.web.address
  port_id     = openstack_networking_port_v2.web.id
}
```

```hcl
# outputs.tf
output "private_ip" {
  value = openstack_networking_port_v2.web.all_fixed_ips[0]
}

output "public_ip" {
  description = "Floating IP reachable from outside"
  value       = openstack_networking_floatingip_v2.web.address
}
```

### 4.3 The plan/apply workflow with real terminal output

```bash
$ terraform init
Initializing the backend...
Successfully configured the backend "swift"! Terraform will automatically
use this backend unless the backend configuration changes.

Initializing provider plugins...
- Finding terraform-provider-openstack/openstack versions matching "~> 2.1"...
- Installing terraform-provider-openstack/openstack v2.1.0...
- Installed terraform-provider-openstack/openstack v2.1.0 (signed)

Terraform has been successfully initialized!
```

```bash
$ terraform plan
data.openstack_networking_network_v2.public: Reading...
data.openstack_images_image_v2.base: Reading...
data.openstack_images_image_v2.base: Read complete after 1s [id=b7c2...]
data.openstack_networking_network_v2.public: Read complete after 1s [id=9a1f...]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # openstack_compute_instance_v2.web will be created
  + resource "openstack_compute_instance_v2" "web" {
      + access_ip_v4        = (known after apply)
      + flavor_name         = "m1.small"
      + id                  = (known after apply)
      + image_id            = "b7c2f0e1-..."
      + name                = "tf-web01"
      + key_pair            = "sre-key"
      + user_data           = "8f3c...==" # sensitive value hashed
      + network {
          + port = (known after apply)
        }
    }

  # ... (network, subnet, router, secgroup, port, floating IP elided) ...

Plan: 11 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + private_ip = (known after apply)
  + public_ip  = (known after apply)
```

```bash
$ terraform apply -auto-approve
openstack_networking_network_v2.private: Creating...
openstack_networking_secgroup_v2.web: Creating...
openstack_networking_network_v2.private: Creation complete after 3s [id=1c2d...]
openstack_networking_subnet_v2.private: Creating...
openstack_networking_subnet_v2.private: Creation complete after 2s [id=3e4f...]
openstack_compute_instance_v2.web: Creating...
openstack_compute_instance_v2.web: Still creating... [10s elapsed]
openstack_compute_instance_v2.web: Creation complete after 24s [id=7c9e6679-...]
openstack_networking_floatingip_associate_v2.web: Creation complete after 2s

Apply complete! Resources: 11 added, 0 changed, 0 destroyed.

Outputs:

private_ip = "192.168.100.14"
public_ip  = "203.0.113.42"
```

### 4.4 State, drift and surgical operations

State is the crux of Terraform operations. The commands below are the ones you reach for during an incident.

```bash
# What does Terraform believe exists?
$ terraform state list
data.openstack_images_image_v2.base
data.openstack_networking_network_v2.public
openstack_compute_instance_v2.web
openstack_networking_floatingip_associate_v2.web
openstack_networking_floatingip_v2.web
openstack_networking_network_v2.private
openstack_networking_port_v2.web
openstack_networking_router_interface_v2.router_iface
openstack_networking_router_v2.router
openstack_networking_secgroup_rule_v2.web_ingress["22"]
openstack_networking_secgroup_v2.web
openstack_networking_subnet_v2.private

# Detect drift: someone changed the SG by hand in Horizon
$ terraform plan
openstack_networking_secgroup_v2.web: Refreshing state... [id=5a6b...]
  ...
  # openstack_networking_secgroup_rule_v2.web_ingress["443"] has been deleted
  #   (out-of-band change)
Plan: 1 to add, 0 to change, 0 to destroy.   # Terraform will re-add it

# Adopt an already-existing resource into state (no re-create)
$ terraform import openstack_compute_instance_v2.legacy 7c9e6679-7425-40de-944b-e07fc1f90ae7
Import successful!

# Force replacement of one resource (modern replacement for `terraform taint`)
$ terraform apply -replace="openstack_compute_instance_v2.web"

# Destroy the whole stack
$ terraform destroy -auto-approve
Destroy complete! Resources: 11 destroyed.
```

> **Licensing footnote (a real production/architecture decision).** In August 2023 HashiCorp relicensed Terraform from MPL 2.0 to the **BUSL 1.1** business-source licence. The Linux Foundation forked the last MPL version as **OpenTofu** (`tofu` CLI), a drop-in-compatible open-source successor. For any organisation with policy constraints on non-OSI licences, OpenTofu is the state-compatible replacement; the HCL, providers and workflow shown above are identical.

---

## 5. CloudStack — awareness (integrated, "batteries-included" IaaS)

Apache CloudStack is a **turnkey** IaaS: where OpenStack is a toolkit of ~25 independently-deployed services, CloudStack ships as a **single Management Server** (Java) plus agents, presenting one coherent product. It is the choice when you want a cloud *appliance* rather than a platform you assemble.

**Physical/logical hierarchy (know this vocabulary):**

```
Region  ─┬─ Zone        (≈ a datacenter; has its own secondary storage)
         │    └─ Pod    (≈ a rack; an L2 broadcast/management domain)
         │         └─ Cluster  (hosts sharing a hypervisor type + primary storage)
         │              └─ Host (a physical hypervisor: KVM / XenServer / VMware / Hyper-V)
         └─ Primary storage (per-cluster, VM disks) · Secondary storage (per-zone, templates/ISOs/snapshots)
```

Key features: a native **web UI + REST-ish query API** (signed URL requests), multi-hypervisor support out of the box, virtual routers for per-tenant networking/DHCP/NAT, and an AWS-compatible EC2/S3 "CloudBridge" façade.

```bash
# CloudStack's API is a signed query API; cloudmonkey is the official CLI
$ cmk list zones filter=name,allocationstate
{
  "count": 1,
  "zone": [ { "name": "zone-cordoba", "allocationstate": "Enabled" } ]
}
$ cmk list hosts type=Routing filter=name,state,hypervisor
{
  "count": 2,
  "host": [
    { "name": "kvm01", "state": "Up", "hypervisor": "KVM" },
    { "name": "kvm02", "state": "Up", "hypervisor": "KVM" }
  ]
}
```

---

## 6. Eucalyptus and OpenNebula — awareness

### 6.1 Eucalyptus — the AWS-API-compatible private cloud

Eucalyptus's differentiator is **bug-for-bug AWS API compatibility**: it re-implements the **EC2, S3, EBS, IAM, Auto Scaling, ELB and CloudFormation** APIs on your own hardware, so tooling written for AWS (the `aws`/`euca2ools` CLIs, SDKs, CloudFormation templates) works unchanged on-prem. Historically its purpose was **hybrid burst** — dev/test on-prem against the same API surface as production AWS. Its component vocabulary: **CLC** (Cloud Controller), **CC** (Cluster Controller), **NC** (Node Controller), **SC** (Storage Controller), **Walrus** (S3-compatible object store). Its commercial trajectory ended (HPE acquisition, then the project wound down), so for the exam treat it as **"the AWS-compatible private cloud"** and understand that "API compatibility with the incumbent public cloud" is the architectural idea.

```bash
$ euca-describe-instances
RESERVATION  r-a1b2c3d4  000123456789  default
INSTANCE     i-0abc1234  emi-5f6e7d8c  10.0.0.31  euca-web01  running  sre-key  0  m1.small
```

### 6.2 OpenNebula — the lightweight, opinionated cloud manager

OpenNebula targets **simplicity and small operational footprint**: a single **front-end** node (the `oned` daemon + Sunstone/FireEdge web UI + scheduler) drives a set of virtualization **hosts** (KVM, LXC system containers, or Firecracker microVMs) over plain SSH — no heavy message bus or SQL cluster to operate. It is the pragmatic choice for edge and mid-size private clouds, and its **datacenter federation** and hybrid drivers let one control plane span sites and burst to public providers.

```bash
$ onehost list
  ID NAME              CLUSTER    TVM      ALLOCATED_CPU      ALLOCATED_MEM STAT
   0 kvm-node01        default      3   300 / 800 (37%)   6G / 32G (18%)   on
   1 kvm-node02        default      2   200 / 800 (25%)   4G / 32G (12%)   on
$ onevm list
  ID USER     GROUP    NAME            STAT  CPU     MEM        HOST             TIME
  12 oneadmin oneadmin web01           runn    1    2G   kvm-node01     0d 04h11
```

---

## 7. Comparative trade-off analysis

### 7.1 The four cloud *platforms* (the IaaS control planes)

| Dimension | **OpenStack** | **CloudStack** | **OpenNebula** | **Eucalyptus** |
|---|---|---|---|---|
| Governance | OpenInfra Foundation | Apache Software Foundation | OpenNebula Systems (OSI: Apache 2.0) | Historic; effectively EOL |
| Architecture | ~25 loosely-coupled services (assemble-it-yourself) | Single Management Server + agents (integrated) | Front-end + hosts over SSH (minimal) | CLC/CC/NC/SC + Walrus |
| Operational complexity | **High** (RabbitMQ + Galera + many agents) | Medium | **Low** | Medium |
| Hypervisors | KVM (primary), Xen, VMware, Hyper-V, Ironic bare metal | KVM, XenServer, VMware, Hyper-V, Ovm | KVM, LXC, Firecracker, VMware | KVM, Xen |
| Native IaC | **Heat** (HOT) | none native (use Terraform) | templates + OneFlow | CloudFormation-compatible |
| API style | OpenStack native REST (+ EC2 compat) | Signed query API + EC2/S3 façade | XML-RPC + REST (Sunstone) | **AWS EC2/S3/IAM native** |
| Terraform provider | `openstack` (mature) | `cloudstack` | `opennebula` | AWS provider via EC2 API |
| Sweet spot | Large multi-tenant private/telco cloud, public-cloud parity | Turnkey enterprise/hosting private cloud | Edge, SMB, low-ops private cloud | AWS hybrid burst (legacy) |
| Main risk | Day-2 operational burden of the control plane | Smaller ecosystem than OpenStack | Fewer advanced networking/storage integrations | Project is dormant |

### 7.2 Provisioning tool: Terraform vs Heat vs cloud-native (CloudFormation)

| Dimension | **Terraform / OpenTofu** | **OpenStack Heat** | **AWS CloudFormation** |
|---|---|---|---|
| Scope | Multi-cloud, provider-agnostic | OpenStack only | AWS only |
| Where state lives | **Client-side** state file (backend of your choosing) | **Server-side** in the Heat DB (the stack) | Server-side (AWS-managed) |
| Language | HCL (+ JSON) | HOT (YAML) | YAML/JSON |
| Change preview | `terraform plan` (explicit, diffable) | `stack update --dry-run` (limited) | Change Sets |
| Drift handling | `plan`/`refresh` detect; re-apply reconciles | Limited; stack-centric | Drift detection API |
| Autoscaling primitives | Via provider resources | **Native** (Aodh alarms + AutoScalingGroup) | Native |
| Best used when | You need one workflow across OpenStack **and** public clouds, with reviewable plans and remote locked state | You are 100% OpenStack and want the orchestration to live inside the cloud (self-healing stacks, tenant-owned) | You are 100% AWS |

**Architect's rule of thumb:** if the estate is single-cloud OpenStack and you want tenant-scoped, self-healing, autoscaling stacks, **Heat** keeps orchestration inside the platform. If you have (or will have) more than one cloud, or you want the reviewability of an explicit `plan` and state you control, **Terraform/OpenTofu** is the standard. They coexist: Terraform can even manage a `openstack_orchestration_stack_v1` (a Heat stack) as one of its resources.

---

## 8. Verification and failure-diagnosis guide

### 8.1 OpenStack control-plane triage

Failures almost always trace to one of the three shared substrates — **Keystone (auth)**, **RabbitMQ (RPC)**, **Galera/DB (state)** — or to an agent being down.

```bash
# 1) Is auth working at all? (401/403 → Keystone or RC file wrong)
$ openstack token issue
# HTTP 401 Unauthorized  ->  bad OS_PASSWORD / expired / clock skew

# 2) Are all API services registered and reachable?
$ openstack endpoint list          # missing interface => catalog misconfig

# 3) Nova control services (a 'down' agent explains 'No valid host was found')
$ openstack compute service list
+----+----------------+-------------------+----------+---------+-------+
| ID | Binary         | Host              | Zone     | Status  | State |
+----+----------------+-------------------+----------+---------+-------+
|  1 | nova-conductor | ctl01             | internal | enabled | up    |
|  2 | nova-scheduler | ctl01             | internal | enabled | up    |
|  3 | nova-compute   | cmp01.cloud.local | nova     | enabled | up    |
|  4 | nova-compute   | cmp03.cloud.local | nova     | enabled | down  |   ← agent down
+----+----------------+-------------------+----------+---------+-------+

# 4) Neutron agents (a 'down' L3/DHCP/OVS agent breaks tenant networking)
$ openstack network agent list
+--------+--------------------+-------------------+-------+-------+
| ID     | Agent Type         | Host              | Alive | State |
+--------+--------------------+-------------------+-------+-------+
| a1..   | Open vSwitch agent | cmp01.cloud.local | :-)   | UP    |
| b2..   | L3 agent           | ctl01             | :-)   | UP    |
| c3..   | DHCP agent         | ctl01             | XXX   | DOWN  |   ← no leases
+--------+--------------------+-------------------+-------+-------+

# 5) Why did THIS instance fail? fault + scheduling reason
$ openstack server show web01 -c status -c fault
+--------+---------------------------------------------------------------+
| Field  | Value                                                         |
+--------+---------------------------------------------------------------+
| status | ERROR                                                         |
| fault  | {'code': 500, 'message': 'No valid host was found. There are  |
|        |  not enough hosts available.'}                               |
+--------+---------------------------------------------------------------+
```

| Symptom | Most likely cause | Where to look |
|---|---|---|
| `401 Unauthorized` on every call | Bad creds / clock skew / expired token | RC file, Keystone log, NTP on nodes |
| Instances stuck in `BUILD` | RabbitMQ partition; conductor can't reach compute | `rabbitmqctl cluster_status`, `nova-conductor` log |
| `No valid host was found` | No capacity / host aggregate / down `nova-compute` | `openstack compute service list`, Placement inventory |
| Instance `ACTIVE` but unreachable | Down DHCP/L3 agent, missing floating-IP assoc or SG rule | `openstack network agent list`, SG rules, router gateway |
| API 500s intermittently | Galera node out of sync / DB deadlocks | `SHOW STATUS LIKE 'wsrep_%'`, service DB logs |

### 8.2 Terraform verification & recovery

```bash
# Static + provider-schema validation before any API call (CI gate)
$ terraform fmt -check -recursive
$ terraform validate
Success! The configuration is valid.

# Reconcile state to reality WITHOUT changing infra (drift report)
$ terraform plan -refresh-only

# State is locked by a crashed run — inspect, then force-unlock (surgically!)
$ terraform force-unlock 9db4f3a1-...   # only after confirming no run is live

# A resource exists but Terraform forgot it → import instead of re-create
$ terraform import openstack_compute_instance_v2.web <uuid>

# Corrupt/partial state after an interrupted apply → pull, inspect, backup
$ terraform state pull > backup.tfstate
$ terraform state rm openstack_networking_floatingip_associate_v2.web  # detach a bad entry
```

| Symptom | Cause | Fix |
|---|---|---|
| `Error acquiring the state lock` | Prior run crashed holding the lock | Confirm no active run, then `terraform force-unlock <ID>` |
| Plan wants to destroy+recreate everything | State lost / wrong backend / wrong workspace | Check `terraform workspace show`, restore/point backend, `import` |
| "Resource already exists" (409) on apply | Object created out-of-band; not in state | `terraform import` it, then re-plan |
| Perpetual diff on an unchanged attribute | Provider/API normalises a value; drift illusion | `ignore_changes` lifecycle or fix the literal to match API canonical form |
| Auth error from provider | `OS_*` env unset / wrong region | `source openrc`, verify with `openstack token issue` first |

---

## 9. References

- LPI — Exam 305-300 Objectives (LPIC-3 Virtualization and Containerization, v3.0): https://www.lpi.org/our-certifications/exam-305-objectives/
- NIST SP 800-145, *The NIST Definition of Cloud Computing* (IaaS/PaaS/SaaS, deployment models): https://csrc.nist.gov/publications/detail/sp/800-145/final
- OpenStack documentation (project overview, service list, releases): https://docs.openstack.org/
- OpenStack — Heat Orchestration Template (HOT) specification: https://docs.openstack.org/heat/latest/template_guide/hot_spec.html
- OpenStackClient (`openstack`) command reference: https://docs.openstack.org/python-openstackclient/latest/
- OpenStack releases and SLURP cadence: https://releases.openstack.org/
- Terraform documentation (workflow, state, backends): https://developer.hashicorp.com/terraform/docs
- Terraform OpenStack provider: https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs
- OpenTofu (MPL-licensed Terraform fork): https://opentofu.org/docs/
- Apache CloudStack documentation (zones/pods/clusters/hosts): https://docs.cloudstack.apache.org/
- OpenNebula documentation (front-end/hosts architecture): https://docs.opennebula.io/
- Eucalyptus (AWS-compatible components — archived): https://github.com/eucalyptus/eucalyptus/wiki
- cloud-init (consumed as `user_data` by all of the above): https://cloudinit.readthedocs.io/