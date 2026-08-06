# Topic 1.3: On-Premises and Cloud Computing

**Exam**: LPI Open Source Essentials (050-100)  
**Topic Weight**: 2.5  
**Target Audience**: Principal Platform Architects, Senior SREs, Systems Engineers  

---

## 1. Architectural Motivation & Production Problem Statement

Modern enterprise platforms operate at the intersection of infrastructure control, dynamic scaling demands, compliance mandates, and strict financial models (CapEx vs. OpEx). Designing compute environments requires navigating trade-offs between physical bare-metal hardware (On-Premises), virtualized cloud infrastructure (IaaS), managed developer runtimes (PaaS), and turnkey cloud applications (SaaS).

### Production Dilemma: The Hybrid & Cloud Migration Challenge
Consider a financial services application processing thousands of transactions per second. 
- **Legacy Architecture**: Bare-metal deployments in colocation facilities guarantee deterministic I/O performance, compliance, and zero multi-tenant noisy-neighbor issues. However, lead times for purchasing, racking, and provisioning physical servers take weeks, blocking rapid scaling during high-traffic events.
- **Cloud-Native Architecture**: Infrastructure-as-a-Service (IaaS) and Platform-as-a-Service (PaaS) offer elasticity, automated API-driven provisioning, and globally distributed footprint. However, misconfigured egress topologies, uncontrolled API usage, or vendor lock-in create operational risks and unpredictable billing spikes.

### Operational Scenarios Across Service Models
1. **On-Premises / Private Cloud (Bare-Metal / OpenStack / VMware)**:
   - *Use Case*: Ultra-low latency kernel bypass workloads (e.g., eBPF/DPDK trading engines), strict data sovereignty regulations (GDPR, HIPAA, PCI-DSS), and high baseline load where long-term CapEx is cheaper than high-density cloud compute instances.
   - *SRE Impact*: High operational toil. Hardware lifecycle management, firmware upgrades, network fabric maintenance (BGP/spine-leaf), storage SAN/NAS provisioning, and hypervisor/container runtime management fall entirely on internal platform teams.
2. **Infrastructure as a Service (IaaS - e.g., OpenStack, AWS EC2, GCP Compute Engine)**:
   - *Use Case*: General-purpose workloads requiring full control over the operating system kernel, network topology (VPC/VNets), storage block volumes, and security group filtering.
   - *SRE Impact*: Shared responsibility model. Provider manages physical hardware and hypervisors; SREs manage OS patching, network routing, firewalling, instance scaling, and disaster recovery.
3. **Platform as a Service (PaaS - e.g., OpenShift, Heroku, AWS Elastic Beanstalk)**:
   - *Use Case*: Rapid application delivery where developers focus solely on code artifacts, deployment pipelines, and environment configuration while runtime environment management is abstracted.
   - *SRE Impact*: Reduced control over lower-level kernel primitives, custom sysctls, and physical network interfaces in exchange for built-in CI/CD integration, auto-scaling runtimes, and managed health monitoring.
4. **Software as a Service (SaaS - e.g., GitHub Enterprise Cloud, Salesforce, Microsoft 365)**:
   - *Use Case*: Ready-to-use application services without operational footprint management.
   - *SRE Impact*: Zero infrastructure control. Operational focus shifts to identity governance (OAuth2/SAML SSO), audit logging, API quota management, and SLA compliance monitoring.

---

## 2. Deep Technical Comparison & Trade-Off Matrix

| Dimension | On-Premises / Bare-Metal | Private Cloud (IaaS) | Public Cloud (IaaS) | Platform as a Service (PaaS) | Software as a Service (SaaS) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Control & Customization** | Complete control over hardware, BIOS/UEFI, CPU flags, and kernel modules. | High control over hypervisor allocation, network virtualization (Geneve/VXLAN), and storage backends (Ceph). | Full OS/Guest Kernel access; zero hardware/hypervisor access. | Restricted to app runtime, environment variables, and container limits. | Configuration only (SSO, webhooks, RBAC rules). |
| **Operational Overhead** | Extremely High (Hardware maintenance, power/cooling, SAN/NAS, cabling). | High (Managing Cloud Management Platform like OpenStack, hypervisors, storage clusters). | Moderate (OS patching, networking rules, systemd units, observability stack). | Low (Code execution, runtime tuning, application monitoring). | Negligible (User provisioning, backup verification). |
| **Financial Model** | Heavy CapEx (Server arrays, switch gear, storage arrays amortized over 3-5 years). | Heavy CapEx initially + OpEx for private cloud maintenance. | Pure OpEx (Pay-as-you-go, Reserved Instances, Savings Plans). | Pure OpEx (Billed per instance hour, execution duration, or memory consumption). | Subscription / Per-Seat / Utility-based OpEx. |
| **Elasticity & Provisioning Speed** | Low (Days to weeks for hardware procurement and provisioning). | Moderate-High (Minutes; constrained by physical rack capacity). | Ultra-High (Seconds to minutes via cloud API calls). | Ultra-High (Automatic trigger-based scaling, e.g., KEDA, Knative). | Instantaneous (Provisioning software accounts). |
| **Latency & Performance** | Sub-millisecond deterministic latency; dedicated fiber and bare-metal bus speed. | Low-latency; isolated host aggregations within local datacenters. | Variable (Dependent on cross-AZ routing, hypervisor queueing, noisy neighbors). | Abbreviated control over network stack; reliant on ingress routing layer. | Dependent on internet transit and vendor CDN performance. |
| **Blast Radius & Multi-Tenancy** | Air-gapped isolation per chassis/VLAN. | Isolated via hardware virtualized hypervisors (KVM, ESXi) and overlay networks. | Multi-tenant hypervisor isolation; security boundary defined by IAM & VPC architecture. | Multi-tenant runtime container isolation (namespaces, cgroups, seccomp). | Vendor multi-tenancy layer; tenant isolation managed via application logic. |

---

## 3. Infrastructure & Deployment Manifests

Below are complete, production-grade manifests demonstrating workload isolation and deployment configurations for hybrid compute environments.

### 3.1 Infrastructure-as-a-Service: Terraform Configuration for Private/Public Hybrid Gateways
This Terraform manifest defines a cloud network bridge connecting an On-Premises environment to a cloud Virtual Private Cloud (VPC) via IPsec VPN tunnel with strict routing controls.

```hcl
# main.tf - Production Cloud Gateway Setup for On-Premises Interconnect
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

variable "onprem_gateway_ip" {
  type        = string
  description = "Public IP address of the on-premises edge router"
  default     = "198.51.100.1"
}

variable "onprem_cidr_block" {
  type        = string
  description = "CIDR block for the on-premises datacenter network"
  default     = "10.100.0.0/16"
}

resource "aws_vpc" "hybrid_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "vpc-hybrid-production"
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

resource "aws_subnet" "private_compute" {
  vpc_id            = aws_vpc.hybrid_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "subnet-private-us-east-1a"
  }
}

resource "aws_customer_gateway" "onprem_cgw" {
  bgp_asn    = 65000
  ip_address = variable.onprem_gateway_ip
  type       = "ipsec.1"

  tags = {
    Name = "cgw-datacenter-east"
  }
}

resource "aws_vpn_gateway" "vpg" {
  vpc_id = aws_vpc.hybrid_vpc.id

  tags = {
    Name = "vpg-hybrid-production"
  }
}

resource "aws_vpn_connection" "onprem_ipsec" {
  vpn_gateway_id      = aws_vpn_gateway.vpg.id
  customer_gateway_id = aws_customer_gateway.onprem_cgw.id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = {
    Name = "vpn-onprem-ipsec-primary"
  }
}

resource "aws_vpn_connection_route" "onprem_route" {
  destination_cidr_block = variable.onprem_cidr_block
  vpn_connection_id      = aws_vpn_connection.onprem_ipsec.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.hybrid_vpc.id

  route {
    cidr_block     = variable.onprem_cidr_block
    gateway_id     = aws_vpn_gateway.vpg.id
  }

  tags = {
    Name = "rt-private-hybrid"
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_compute.id
  route_table_id = aws_route_table.private_rt.id
}
```

---

### 3.2 Platform-as-a-Service Container Workload: Production Kubernetes Deployment
A Kubernetes Deployment manifest enforcing SRE production readiness guidelines: compute resource requests/limits, liveness/readiness probes, pod topology spread constraints, and security contexts.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor-service
  namespace: production
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: financial-platform
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: payment-processor
        tier: backend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - payment-processor
                topologyKey: kubernetes.io/hostname
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payment-processor
      containers:
        - name: payment-api
          image: registry.internal.net/finance/payment-api:v2.4.1
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          ports:
            - name: http-metrics
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2000m"
              memory: "2Gi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
          env:
            - name: ENVIRONMENT
              value: "production"
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
```

---

## 4. Real CLI Execution Workflows & Expected Output

### 4.1 Hypervisor Resource & Virtualization Diagnostics (On-Premises KVM/QEMU)
Inspecting hypervisor compute topology, virtual machine statuses, and domain resource allocations via `virsh` and `numactl`.

```bash
$ virsh list --all
 Id   Name                   State
--------------------------------------
 1    kvm-prod-db-01         running
 2    kvm-prod-k8s-node-01   running
 3    kvm-prod-k8s-node-02   running
 -    kvm-stage-app-01       shut off

$ virsh vcpuinfo kvm-prod-db-01
VCPU:           0
CPU:            3
State:          running
CPU time:       14325.2s
CPU Affinity:   y---

VCPU:           1
CPU:            4
State:          running
CPU time:       13980.8s
CPU Affinity:   -y--

$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7
node 0 size: 64280 MB
node 0 free: 12430 MB
node 1 cpus: 8 9 10 11 12 13 14 15
node 1 size: 64490 MB
node 1 free: 18910 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

### 4.2 Cloud Compute API Diagnostics (OpenStack Private Cloud IaaS)
Interacting with the OpenStack Compute (Nova) and Network (Neutron) APIs to verify tenant quota, network topology, and server status.

```bash
$ openstack server list --flavor m1.large --status ACTIVE
+--------------------------------------+--------------------+--------+-----------------------------------+-------------------+----------------+
| ID                                   | Name               | Status | Networks                          | Image             | Flavor         |
+--------------------------------------+--------------------+--------+-----------------------------------+-------------------+----------------+
| a3b7c8d9-1234-5678-90ab-cdef12345678 | edge-router-prod-0 | ACTIVE | selfservice-net=10.20.0.14, 192.. | Ubuntu-22.04-LTS  | m1.large       |
| d9e8f7c6-4321-8765-ba09-fedc87654321 | k8s-worker-p-01    | ACTIVE | selfservice-net=10.20.0.22        | Rocky-Linux-9     | m1.large       |
+--------------------------------------+--------------------+--------+-----------------------------------+-------------------+----------------+

$ openstack quota show --usage tenant-production
+----------------------+--------+--------+-------+
| Resource             | In Use | Reserved| Limit |
+----------------------+--------+--------+-------+
| cores                |     48 |      0 |   100 |
| instances            |     12 |      0 |    20 |
| ram (MB)             |  98304 |      0 |204800 |
| floating-ips         |      4 |      0 |    10 |
| security-groups      |      8 |      0 |    25 |
+----------------------+--------+--------+-------+
```

### 4.3 Runtime Container Engine Operations (Podman/Docker On-Premises & IaaS)
Analyzing container socket connectivity, cgroup v2 resource limits, and runtime namespaces on an IaaS instance or bare-metal host.

```bash
$ podman ps --format "table {{.ID}} {{.Names}} {{.Status}} {{.Ports}}"
CONTAINER ID  NAMES                 STATUS                 PORTS
e7d8f9a0b1c2  ingress-envoy-proxy   Up 4 days ago          0.0.0.0:80->8080/tcp, 0.0.0.0:443->8443/tcp
f1e2d3c4b5a6  redis-cache-local     Up 2 days ago          127.0.0.1:6379->6379/tcp

$ podman inspect e7d8f9a0b1c2 --format '{{.HostConfig.CgroupMode}} | Memory: {{.HostConfig.Memory}} | NanoCpus: {{.HostConfig.NanoCpus}}'
unified | Memory: 1073741824 | NanoCpus: 2000000000

$ cat /sys/fs/cgroup/system.slice/libpod-e7d8f9a0b1c2.scope/memory.current
429512704
```

---

## 5. Production Verification & Failure Diagnosis Guide

When troubleshooting cloud and on-premises infrastructure, SREs must systematically isolate issues across physical layers, hypervisors, network overlays, and container runtimes.

```
                  +-------------------------------------------------+
                  |      Failure Reported: Workload Degradation      |
                  +-------------------------------------------------+
                                           |
                                           v
                  +-------------------------------------------------+
                  | Layer 1: Is it a Physical / Host Level Issue?   |
                  | (dmesg, journalctl, ip link, lscpu, SMART)      |
                  +-------------------------------------------------+
                                           |
                           +---------------+---------------+
                           |                               |
                        [ YES ]                         [ NO ]
                           |                               |
                           v                               v
         +----------------------------------+    +----------------------------------+
         | Hardware Fault / Host OOM        |    | Layer 2: Hypervisor / Quota Issue|
         | Action: Drain Host, Re-provision |    | (virsh, openstack quota, dmesg)  |
         +----------------------------------+    +----------------------------------+
                                                           |
                                           +---------------+---------------+
                                           |                               |
                                        [ YES ]                         [ NO ]
                                           |                               |
                                           v                               v
                         +-------------------+           +----------------------------------+
                         | Steal Time / Cap  |           | Layer 3: Network / Overlay Issue |
                         | Action: Rebalance |           | (ping, traceroute, tc, ip route) |
                         +-------------------+           +----------------------------------+
                                                                           |
                                                           +---------------+---------------+
                                                           |                               |
                                                        [ YES ]                         [ NO ]
                                                           |                               |
                                                           v                               v
                                         +-------------------+           +----------------------------------+
                                         | MTU / Drop / BGP  |           | Layer 4: Container / App Level   |
                                         | Action: Fix VXLAN |           | (kubectl, cgroups, strace)       |
                                         +-------------------+           +----------------------------------+
```

### 5.1 Scenario 1: High CPU Steal Time (`%st`) in IaaS Instances
- **Symptom**: Application response latencies spike intermittently on an IaaS virtual machine. Metrics show high CPU usage despite low application traffic.
- **Root Cause**: CPU overcommit on the underlying physical hypervisor host ("noisy neighbor" effect).
- **Diagnostic Workflow**:
  1. Inspect CPU execution state using `top` or `mpstat`:
     ```bash
     $ mpstat -P ALL 1 3
     Linux 5.15.0-101-generic (node-01)    08/06/2026      _x86_64_        (4 CPU)

     06:12:01 PM  CPU    %usr   %nice    %sys %iowait   %irq  %soft  %steal  %guest  %idle
     06:12:02 PM  all    8.50    0.00    2.10    0.00   0.00   0.40   42.00    0.00  47.00
     06:12:02 PM    0    7.00    0.00    1.00    0.00   0.00   0.00   45.00    0.00  47.00
     ```
  2. Notice `%steal` is at **42.00%**. This indicates the hypervisor scheduler is withholding CPU cycles from this guest instance to service other VMs on the physical host.
  3. **Remediation**:
     - Migrate instance to a dedicated host aggregate / pinned compute node.
     - Upsize to compute-optimized instance types with 1:1 physical-to-virtual CPU thread pinning (`vcpu_pin`).

---

### 5.2 Scenario 2: Network Overlay Path MTU Discovery (PMTUD) Blackhole in Hybrid Tunnel
- **Symptom**: Small packets (ICMP ping, TCP handshake) succeed between On-Premises and Public Cloud nodes over IPsec/VXLAN tunnels, but large payloads (HTTP GET, file transfers) hang indefinitely.
- **Root Cause**: Outer overlay encapsulations (IPsec/Geneve/VXLAN) add 50–80 bytes of header overhead. If `DF` (Don't Fragment) bit is set and ICMP "Fragmentation Needed" packets are blocked by firewalls, packets are silently dropped.
- **Diagnostic Workflow**:
  1. Test path MTU using `ping` with packet sizing and DF bit enabled:
     ```bash
     $ ping -c 2 -M do -s 1472 10.0.1.15
     PING 10.0.1.15 (10.0.1.15) 1472(1500) bytes of data.
     From 10.100.0.1 icmp_seq=1 Frag needed and DF set (mtu = 1420)
     ```
  2. Verify network interface configuration on host:
     ```bash
     $ ip link show eth0
     2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
         link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
     ```
  3. **Remediation**:
     - Adjust TCP Maximum Segment Size (MSS) clamping on edge routers:
       ```bash
       $ sudo iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
       ```
     - Or update interface MTU to account for overlay headers (e.g., set MTU to `1420` or enable jumbo frames `9000` across physical path).

---

### 5.3 Scenario 3: Container Storage I/O Starvation on Shared Disk Subsystems
- **Symptom**: Pods running in a managed Kubernetes cluster log disk write timeouts. Node status shows `DiskPressure`.
- **Root Cause**: Co-located container workloads exceeding shared block storage IOPS capacity.
- **Diagnostic Workflow**:
  1. Check disk I/O latency and queue depth using `iostat`:
     ```bash
     $ iostat -xz 1 3
     Linux 5.15.0-101-generic (k8s-node-02) 

     Device:            r/s     w/s     rkB/s     wkB/s  rrqm/s  wrqm/s  %util astat  await
     vda               2.00  850.00     16.00  10485.00    0.00  120.00  99.80  4.50  145.20
     ```
  2. Notice `%util` is **99.80%** and `await` (queue + service time) is **145.20 ms** (healthy baseline < 10ms).
  3. Identify processes hogging IOPS using `iotop`:
     ```bash
     $ sudo iotop -o -b -n 1
     TID  PRIO  USER     DISK READ  DISK WRITE  SWAPIN     IO>    COMMAND
     14205 be/4 10001       0.00 B/s   10.2 M/s  0.00 %  88.40 %  app-unthrottled-logger
     ```
  4. **Remediation**:
     - Apply StorageClass IOPS caps or move write-heavy logging workloads to decoupled network buffers (e.g., Fluentbit disk buffers with limits or Kafka).
     - Enforce `ephemeral-storage` requests/limits in Kubernetes pod specs to prevent single-pod disk hogging.

---

## 6. References

- Linux Professional Institute Open Source Essentials Certification:  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- NIST Special Publication 800-145 (The NIST Definition of Cloud Computing):  
  [https://csrc.nist.gov/publications/detail/sp/800-145/final](https://csrc.nist.gov/publications/detail/sp/800-145/final)
- CNCF Cloud Native Definition:  
  [https://github.com/cncf/toc/blob/main/DEFINITION.md](https://github.com/cncf/toc/blob/main/DEFINITION.md)
- Kubernetes Production Workload Documentation:  
  [https://kubernetes.io/docs/concepts/workloads/controllers/deployment/](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- Terraform AWS Provider Documentation:  
  [https://registry.terraform.io/providers/hashicorp/aws/latest/docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- Red Hat Enterprise Linux Virtualization Administration Guide (KVM/virsh):  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/index)