# Production SRE & Platform Architecture Guide: LPI 050-100 Topic 1.3

## Topic 1.3: On-Premises and Cloud Computing
**Exam Weight:** 2.5  
**Target Audience:** SREs, Platform Engineers, System Administrators  
**Reference Material & Official Sources:**
- [LPI Open Source Essentials Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- [NIST Special Publication 800-145: Definition of Cloud Computing](https://csrc.nist.gov/publications/detail/sp/800-145/final)
- [CNCF Cloud Native Definition](https://github.com/cncf/toc/blob/main/DEFINITION.md)

---

## Architectural Context & Technical Foundation

The transition from traditional **On-Premises Infrastructure** to **Cloud Computing** (Public, Private, and Hybrid) alters the fundamental operational primitives, financial models, and fault domain assumptions of enterprise systems.

```
+-----------------------------------------------------------------------------------+
|                            SHARED RESPONSIBILITY MODEL                            |
+----------------------+--------------------+--------------------+------------------+
| Component Layer      | On-Premises        | IaaS (Cloud)       | PaaS (Cloud)     |
+----------------------+--------------------+--------------------+------------------+
| Application Code     | Customer           | Customer           | Customer         |
| Data & Schema        | Customer           | Customer           | Customer         |
| Runtime & OS         | Customer           | Customer           | Provider Managed |
| Virtualization/KVM   | Customer           | Provider Managed   | Provider Managed |
| Physical Hardware    | Customer           | Provider Managed   | Provider Managed |
| Datacenter Facilities| Customer           | Provider Managed   | Provider Managed |
+----------------------+--------------------+--------------------+------------------+
```

### Key Differences: On-Premises vs. Cloud

1. **Hardware Abstraction & Hypervisor Isolation**:
   - **On-Premises**: Direct access to physical hardware, non-uniform memory access (NUMA) topologies, host network interfaces (NICs), and hardware RAID controllers. Upgrades require hardware procurement, rack-and-stack procedures, and physical maintenance windows.
   - **Cloud (IaaS)**: Hardware resources are abstracted into software-defined primitives (Compute Instance, Block Storage Volume, Software-Defined Network) mediated by bare-metal hypervisors (e.g., AWS Nitro, KVM, Firecracker microVMs). Provisioning occurs programmatically via REST APIs.

2. **Financial Dynamics**:
   - **CapEx (Capital Expenditure)**: High upfront investment in servers, switches, SANs, rack units, power/cooling infrastructure, and datacenter leases. Amortized over 3–5 year depreciation schedules.
   - **OpEx (Operational Expenditure)**: Utility-based consumption model (pay-as-you-go). Involves resource tagging, billing metrics (core-hours, GB/s network egress, IOPS), and cost optimization strategies (Reserved Instances, Spot Instances, Auto-scaling).

3. **Elasticity & Resource Pooling (NIST SP 800-145)**:
   - **On-Premises**: Peak capacity is strictly bounded by static physical capacity. Provisioning takes weeks/months. Over-provisioning is mandatory to handle traffic spikes.
   - **Cloud**: Multitenant resource pooling across regional Availability Zones (AZs). Features programmatic **Rapid Elasticity** allowing sub-minute scaling in response to metrics like CPU utilization or custom queue depth.

---

## Hands-on Guided Exercises

---

### Exercise 1: Low-Level Hardware vs. Cloud Abstraction Audit & API Metadata Introspection

In this exercise, you will run low-level system diagnostic tools to audit host hardware topology (NUMA nodes, hyperthreading, memory sockets) on an on-premises physical/virtual host, and contrast it with cloud instance metadata introspection via link-local API calls.

#### Step 1.1: Audit Local On-Premises CPU Architecture and Memory Controller Topology
Execute the following commands on a local Linux host to inspect NUMA (Non-Uniform Memory Access) layout and hardware abstraction primitives:

```bash
lscpu | grep -E "(Architecture|CPU\(s\)|Thread|Core|Socket|NUMA)"
```

**Expected Terminal Output:**
```text
Architecture:            x86_64
CPU(s):                  32
Thread(s) per core:      2
Core(s) per socket:      8
Socket(s):               2
NUMA node(s):            2
NUMA node0 CPU(s):       0-7,16-23
NUMA node1 CPU(s):       8-15,24-31
```

Next, inspect NUMA memory distribution across nodes using `numactl`:

```bash
numactl --hardware
```

**Expected Terminal Output:**
```text
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
node 0 size: 64320 MB
node 0 free: 41200 MB
node 1 cpus: 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
node 1 size: 64480 MB
node 1 free: 38900 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

#### Step 1.2: Introspect Cloud Hypervisor Identity via Instance Metadata Service (IMDSv2)
In a cloud computing environment (e.g., AWS EC2, GCP Compute Engine, Azure VM), hardware layout is masked by a hypervisor. The operating system communicates with a local metadata endpoint at non-routable link-local IPv4 address `169.254.169.254`.

Simulate or execute an IMDSv2 (Session Token-based) metadata query to discover the instance identity, region, instance type, and IAM credentials:

```bash
# 1. Generate an IMDSv2 Session Token (valid for 21600 seconds)
TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# 2. Fetch Instance Type, Availability Zone, and Hypervisor MAC Address
echo "Instance Type: $(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)"
echo "Availability Zone: $(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
echo "Local IPv4: $(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)"
```

**Expected Terminal Output:**
```text
Instance Type: c6i.2xlarge
Availability Zone: us-east-1a
Local IPv4: 10.0.1.42
```

#### Step 1.3: Provision Declarative Infrastructure via Terraform
Compare manual server provisioning with Infrastructure-as-Code (IaC) programmatic deployment. Review and inspect the following complete, syntactically valid HashiCorp HCL manifest (`main.tf`) that deploys an isolated cloud network and virtual server:

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
  region = "us-east-1"
}

resource "aws_vpc" "production_vpc" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "prod-cloud-vpc"
    Environment = "production"
  }
}

resource "aws_subnet" "public_subnet_a" {
  vpc_id                  = aws_vpc.production_vpc.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "prod-public-subnet-1a"
  }
}

resource "aws_instance" "app_server" {
  ami           = "ami-0c7217cdde317cfec" # Canonical Ubuntu 22.04 LTS x86_64
  instance_type = "t3.medium"
  subnet_id     = aws_subnet.public_subnet_a.id

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforce IMDSv2
    http_put_response_hop_limit = 1
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y nginx
              systemctl enable --now nginx
              EOF

  tags = {
    Name = "web-app-node-01"
  }
}

output "instance_public_ip" {
  description = "Public IP address of the provisioned cloud instance"
  value       = aws_instance.app_server.public_ip
}
```

Verify syntax validity using the Terraform CLI:

```bash
terraform fmt -check
terraform validate
```

**Expected Terminal Output:**
```text
Success! The configuration is valid.
```

---

#### Comprehension Check: Exercise 1

1. **Why does an SRE need to enforce `http_tokens = "required"` (IMDSv2) on cloud compute instances instead of legacy IMDSv1? What security risk does it mitigate?**
2. **Contrast how NUMA node memory distance affects latency on an on-premises physical bare-metal database server versus a vCPU-pinned cloud compute instance.**
3. **If a script running inside a Pod in a Kubernetes cluster makes an HTTP GET request to `http://169.254.169.254/latest/meta-data/`, which component responds, and why might this pose a security concern in a multi-tenant platform?**

---

### Exercise 2: Simulating Elasticity & Resource Pooling with Linux Control Groups (cgroups v2)

Cloud providers achieve **Resource Pooling** and **Rapid Elasticity** using OS kernel containerization mechanisms (cgroups and namespaces) or lightweight microVM hypervisors. In this exercise, you will create a custom cgroup v2 hierarchy to enforce CPU and Memory caps on a process, simulating cloud tenant resource throttling.

#### Step 2.1: Verify cgroups v2 Filesystem Mounting
Run `stat` on `/sys/fs/cgroup` to confirm your kernel is running cgroups v2:

```bash
stat -fc %T /sys/fs/cgroup
```

**Expected Terminal Output:**
```text
cgroup2fs
```

#### Step 2.2: Create a Tenant Resource Pool Control Group
Create a cgroup node named `tenant_cloud_pool` and inspect enabled controllers:

```bash
sudo mkdir -p /sys/fs/cgroup/tenant_cloud_pool
cat /sys/fs/cgroup/cgroup.subtree_control
```

**Expected Terminal Output:**
```text
cpuset cpu io memory pids
```

Enable `cpu` and `memory` controllers for child groups:

```bash
echo "+cpu +memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
```

#### Step 2.3: Set Hard Limits for Memory (OOM Killer) and CPU Quota
Configure a 256MB hard memory limit (`memory.max`) and restrict CPU consumption to 1.5 cores (`cpu.max` set to 150000 microseconds per 100000 microsecond period):

```bash
# Set hard limit of 268435456 bytes (256 MB)
echo "268435456" | sudo tee /sys/fs/cgroup/tenant_cloud_pool/memory.max

# Set CPU limit: quota=150000, period=100000 (150% of 1 CPU core)
echo "150000 100000" | sudo tee /sys/fs/cgroup/tenant_cloud_pool/cpu.max
```

Verify the configured limits:

```bash
cat /sys/fs/cgroup/tenant_cloud_pool/memory.max
cat /sys/fs/cgroup/tenant_cloud_pool/cpu.max
```

**Expected Terminal Output:**
```text
268435456
150000 100000
```

#### Step 2.4: Attach a Process and Test Resource Elasticity Limits
Launch a background stress process using `stress-ng` attached to the `tenant_cloud_pool` cgroup:

```bash
# Attach current shell PID to cgroup
echo $$ | sudo tee /sys/fs/cgroup/tenant_cloud_pool/cgroup.procs

# Run stress testing tool allocating 512MB RAM (exceeding 256MB hard limit)
stress-ng --vm 1 --vm-bytes 512M --timeout 10s
```

**Expected Terminal Output:**
```text
stress-ng: info:  [12845] dispatching stressor processes
stress-ng: fail:  [12845] stress-ng-vm: terminated by SIGKILL (OOM killed)
stress-ng: info:  [12845] unsuccessful run completed in 0.42s
```

Check the kernel Out-Of-Memory (OOM) events counter for the cgroup:

```bash
cat /sys/fs/cgroup/tenant_cloud_pool/memory.events
```

**Expected Terminal Output:**
```text
low 0
high 0
max 4
oom 1
oom_kill 1
oom_group_kill 0
```

---

#### Comprehension Check: Exercise 2

1. **How does cgroups v2 memory throttling (`memory.max` vs `memory.high`) align with NIST SP 800-145's definition of "Measured Service" and multi-tenant resource containment?**
2. **In a cloud environment, what is the main difference between "Vertical Scaling" (Scale Up) and "Horizontal Scaling" (Scale Out), and which one benefits more from cgroup-based micro-bin-packing?**
3. **An application team demands 100% dedicated hardware cores without any noisy-neighbor hypervisor overcommit. Which cloud provisioning model (Bare Metal Instances vs Dedicated Hosts vs Shared Multi-tenant Instances) must be selected, and what are the CapEx/OpEx implications?**

---

### Exercise 3: Hybrid Connectivity Setup & Network Latency/Throughput Diagnostics

A **Hybrid Cloud** architecture bridges on-premises data centers with public cloud Virtual Private Clouds (VPC) via secure encrypted tunnels (IPsec/WireGuard) or dedicated private lines (AWS Direct Connect / GCP Cloud Interconnect).

In this exercise, you will inspect a syntactically complete WireGuard overlay tunnel configuration and execute network diagnostics (`mtr`, `iperf3`, `tcpdump`) to evaluate hybrid link latency and throughput bottlenecks.

#### Step 3.1: Inspect On-Premises to Cloud Overlay Tunnel Configuration
Review the following complete WireGuard interface configuration file (`/etc/wireguard/wg0.conf`) representing an On-Premises Router connected to a Cloud Gateway:

```ini
[Interface]
# On-Premises Router Local Configuration
PrivateKey = uK3x8N4...[REDATED_PRIVATE_KEY]...8wA=
Address = 192.168.250.1/30
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Cloud Gateway Endpoint Configuration
PublicKey = 7bT9y...[REDATED_PUBLIC_KEY]...0xM=
Endpoint = 203.0.113.45:51820
AllowedIPs = 10.100.0.0/16, 192.168.250.2/32
PersistentKeepalive = 25
```

Verify tunnel interface status using `wg`:

```bash
sudo wg show wg0
```

**Expected Terminal Output:**
```text
interface: wg0
  public key: 4xK9p...[KEY]...9qA=
  listening port: 51820

peer: 7bT9y...[REDATED_PUBLIC_KEY]...0xM=
  endpoint: 203.0.113.45:51820
  allowed ips: 10.100.0.0/16, 192.168.250.2/32
  latest handshake: 12 seconds ago
  transfer: 1.42 MiB received, 4.88 MiB sent
  persistent keepalive: every 25 seconds
```

#### Step 3.2: Perform Network Route Tracing and Jitter Analysis via MTR
Execute `mtr` (My TraceRoute) in report mode to diagnose packet loss and latency variation across the hybrid network link to the cloud gateway (`10.100.1.42`):

```bash
mtr --report --report-cycles=10 --no-dns 10.100.1.42
```

**Expected Terminal Output:**
```text
Start: 2026-08-06T19:00:00+0000
HOST: on-prem-gw01                Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 192.168.1.1                0.0%    10    0.3   0.4   0.3   0.6   0.1
  2.|-- 192.168.250.2 (wg0)        0.0%    10   12.4  12.8  12.1  14.2   0.7
  3.|-- 10.100.1.42                0.0%    10   13.1  13.2  12.8  15.0   0.6
```

#### Step 3.3: Benchmark Hybrid Tunnel Bandwidth with iperf3
Run `iperf3` client against the target cloud instance server (`10.100.1.42`) over 4 parallel TCP streams:

```bash
iperf3 -c 10.100.1.42 -P 4 -t 10
```

**Expected Terminal Output:**
```text
Connecting to host 10.100.1.42, port 5201
[SUM]   0.00-10.00  sec  1.08 GBytes   930 Mbits/sec    0   sender
[SUM]   0.00-10.00  sec  1.07 GBytes   921 Mbits/sec        receiver
```

---

#### Comprehension Check: Exercise 3

1. **Why is `PersistentKeepalive = 25` critical in WireGuard configurations when connecting an on-premises network behind a NAT firewall to a public cloud gateway?**
2. **What are the primary operational trade-offs between traversing the public internet via an IPsec/WireGuard VPN versus deploying a dedicated connection like AWS Direct Connect / GCP Cloud Interconnect?**
3. **If network latency spikes significantly only during `iperf3` bandwidth saturation tests over a hybrid link, which network phenomenon (e.g., Bufferbloat, MTU Path Disjointness, TCP Window Scaling) is most likely occurring, and how can MTU clamping (`mss-clamping`) help?**

---

## <details><summary>Answers & Explanations</summary>

### Exercise 1 Solutions

1. **IMDSv2 vs IMDSv1 Security Enforcement**:
   - **IMDSv1** uses simple unauthenticated HTTP `GET` requests (`curl http://169.254.169.254/...`), making it vulnerable to **Server-Side Request Forgery (SSRF)** vulnerabilities in web applications. If an attacker exploits an SSRF flaw, they can read IMDSv1 endpoints and steal temporary IAM role credentials assigned to the instance.
   - **IMDSv2** enforces a session-oriented HTTP token mechanism requiring a `PUT` request with a custom header (`X-aws-ec2-metadata-token-ttl-seconds`) to generate a secret token before querying metadata. Most SSRF vectors cannot execute HTTP `PUT` calls or attach custom headers, mitigating credential theft.

2. **NUMA Memory Latency: On-Premises vs. Cloud**:
   - **On-Premises Bare Metal**: A physical server with multiple CPU sockets has distinct memory controllers attached to each socket (NUMA nodes). Accessing local memory attached to Socket 0 takes ~10ns, while accessing remote memory attached to Socket 1 over Ultra Path Interconnect (UPI) incurs a ~30%-50% latency penalty. SREs must use `numactl --membind` to pin memory to local NUMA nodes for high-performance databases.
   - **Cloud Instances**: Small/medium virtual machine instances run within single NUMA nodes managed by the hypervisor. However, large bare-metal or multi-socket instances (e.g., `u-12tb1.metal`) expose NUMA topology directly to the guest OS, requiring SREs to apply identical NUMA tuning rules as on-premises environments.

3. **Kubernetes Metadata Exposure**:
   - By default, Pods share the host network namespace or route egress traffic via host interfaces. An unprivileged application container inside a Pod can query `169.254.169.254` and receive the underlying Kubernetes worker node's IAM instance credentials.
   - **Mitigation**: SREs must implement NetworkPolicies blocking egress traffic to `169.254.169.254/32` or use metadata security tools (such as AWS IRSA / EKS Pod Identities or Azure Workload Identity) which restrict access and inject fine-grained IAM tokens directly into Pods instead of sharing node-level IAM credentials.

---

### Exercise 2 Solutions

1. **cgroups v2 and NIST Measured Service**:
   - NIST defines **Measured Service** as cloud systems automatically controlling and optimizing resource use by leveraging metering capabilities at a level of abstraction appropriate to the type of service (e.g., storage, processing, bandwidth).
   - In cgroups v2, `memory.high` acts as a throttling boundary where processes exceeding the threshold are slowed down and forced to reclaim memory without crashing immediately. `memory.max` enforces a strict hard limit that triggers the kernel OOM Killer if breached. This ensures predictable resource boundaries, multi-tenant isolation, and accurate utility metering without host instability.

2. **Vertical vs. Horizontal Scaling**:
   - **Vertical Scaling (Scale Up)**: Adding more CPU cores or RAM to an existing node. Limited by maximum physical hardware capacity and requires restarting instances (unless hot-plugging is supported).
   - **Horizontal Scaling (Scale Out)**: Adding more discrete compute instances/nodes to a distributed cluster (e.g., Kubernetes Worker Nodes, Auto Scaling Groups).
   - **Micro-bin-packing**: Horizontal scaling benefits exponentially from cgroup-based micro-bin-packing, as SREs can safely pack dozens of small containerized microservices onto fewer large cloud instances, optimizing resource utilization and reducing overall OpEx costs.

3. **Hardware Isolation Models**:
   - **Bare Metal Instances**: Offers direct access to physical hardware without a hypervisor. Highest cost model; incurs OpEx billed per hour/month.
   - **Dedicated Hosts**: Physical servers dedicated exclusively to a single customer, allowing enforcement of compliance policies and control over socket/core placement.
   - **Shared Multi-Tenant Instances**: Standard cloud instances running on shared hypervisors alongside other customers' VMs.
   - **Financial/Operational Trade-off**: Bare Metal and Dedicated Hosts eliminate noisy-neighbor issues and NUMA variance but drastically increase hourly costs and reduce resource pooling efficiency compared to shared multi-tenant VMs.

---

### Exercise 3 Solutions

1. **WireGuard PersistentKeepalive Necessity**:
   - Stateful NAT routers and firewalls drop idle connection tracking entries after a period of inactivity (typically 30–60 seconds).
   - Because WireGuard is silent when there is no traffic (sending no packet acknowledgments), a NAT router will clear the mapping. `PersistentKeepalive = 25` forces WireGuard to send an encrypted ping every 25 seconds, keeping the NAT mapping open so the cloud gateway can initiate outbound connections back to the on-premises subnet at any time.

2. **Public Internet VPN vs. Dedicated Cloud Interconnect**:
   - **IPsec/WireGuard Over Public Internet**: Fast implementation, low cost (uses existing internet lines), but subject to internet routing jitter, packet loss, non-guaranteed SLA, and variable latency.
   - **AWS Direct Connect / GCP Cloud Interconnect**: Physical fiber link directly into the cloud provider's Point of Presence (PoP). Provides deterministic single-digit millisecond latency, guaranteed SLA, high bandwidth (1Gbps–100Gbps), and lower data egress pricing, but requires months of circuit provisioning and high monthly fixed costs.

3. **Bufferbloat & MTU MSS Clamping**:
   - **Bufferbloat**: Occurs when intermediate network equipment buffers excessively large queues of packets, causing latency to spike drastically during high-throughput saturation (`iperf3`).
   - **MTU & MSS Clamping**: Encapsulation protocols (like WireGuard or IPsec) add headers (typically 20–60 bytes), reducing the effective MTU from 1500 bytes to 1420 bytes. If TCP packets do not account for header overhead, routers fragment packets, degrading performance.
   - **Solution**: Configure `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` on the router to dynamically lower the Maximum Segment Size (MSS), preventing packet fragmentation over the hybrid tunnel.

</details>