# 2.2 Describe Azure compute and networking services

**Exam:** AZ-900 (Microsoft Azure Fundamentals), syllabus version 2026-07-20
**Domain weight:** 9.62 — the single heaviest sub-topic of "Describe Azure architecture and services"
**Audience profile:** SRE / Platform Architect. The exam asks *what* each service is; this material also covers *why the platform is built that way*, where it breaks in production, and how you prove it.

---

## 1. Motivation: the architectural problem behind "compute and networking"

Every production incident that begins with "the app is down" resolves to one of four questions:

1. **Is the workload running?** (compute lifecycle, placement, capacity)
2. **Can the packet reach it?** (routing, filtering, name resolution)
3. **Is the platform sending traffic to a healthy instance?** (probes, load-balancing plane)
4. **Will the answer change if a rack, a datacenter, or a region fails?** (fault-domain topology)

Azure's compute and networking catalogue is not a menu of interchangeable products — it is a set of answers to those four questions at different points on a **control/abstraction trade-off curve**. At one end you own the kernel and the routing table (Virtual Machines + Virtual Network); at the other end you own a container image and a scale rule (Azure Container Apps, Azure Functions). Everything in between is a negotiation about which failure modes you want to be responsible for.

### 1.1 The production scenario used throughout

A payments platform migrating from an on-premises datacenter. Requirements:

| Requirement | Consequence |
|---|---|
| Public checkout API, TLS-terminated, WAF-inspected, global | Front Door Premium → App Gateway/Container Apps origin |
| Internal batch settlement, runs 03:00–05:00, spiky | Event-driven scale-to-zero (Functions or Container Apps) |
| Legacy AIX-replacement pricing engine, licensed per-core | Virtual Machines with constrained-core SKUs; no autoscale |
| No workload may egress to the public Internet unaudited | NAT Gateway + UDR to Azure Firewall; no instance-level public IPs |
| PCI scope must be network-isolable | Subnet segmentation + NSG/ASG + Private Endpoints for PaaS |
| RTO 15 min / RPO 0 for the API tier | Zone-redundant deployment inside one region, multi-region active/passive |
| Hybrid: settlement must reach the on-prem mainframe over private links | ExpressRoute with VPN failover |

Nothing in this document is an abstract feature list; each service is placed against this topology.

---

## 2. Azure compute services

### 2.1 The compute ladder

```
                   You manage                              Azure manages
IaaS   VM                 OS, patching, runtime, scaling  | hypervisor, host, fabric
       VM Scale Set       OS image, scale rules           | instance lifecycle, FD/UD spread
PaaS   AKS                node pools, workloads, CNI      | control plane, etcd, API server
       App Service        app code, plan sizing           | OS, runtime, patching, TLS
       Container Apps     image, scale rule, revision     | K8s, KEDA, Envoy, Dapr, nodes
FaaS   Functions          function code, trigger          | everything, incl. instance count
       ACI                image, container group          | everything, no orchestration
```

**Architectural rule of thumb:** move *down* the ladder only when a concrete requirement forces it — a kernel module, a licensed binary, a sub-millisecond latency budget, a non-HTTP protocol, or a compliance control that requires host-level agents. Each rung down transfers a class of failure (patching, capacity, node health) from Microsoft's SRE team to yours.

### 2.2 Azure Virtual Machines (IaaS)

A VM is a guest OS on the Azure hypervisor, composed of: a **VM resource**, one or more **NICs**, **managed disks** (OS + data), an optional **public IP**, and membership in a **placement construct** (availability set, availability zone, scale set, or dedicated host).

**VM SKU families** — the letter is the workload contract, not marketing:

| Family | Purpose | Typical production use | Notes |
|---|---|---|---|
| B | Burstable, CPU credits | dev/test, low-traffic agents | credit exhaustion = silent throttling; never for prod DB |
| D / Dv5 / Dasv5 | General purpose | web tier, app servers | balanced vCPU:RAM 1:4 |
| E / Ev5 / Easv5 | Memory optimised | in-memory caches, SQL | 1:8 |
| F / Fsv2 | Compute optimised | batch, encoding, game servers | 1:2 |
| L / Lsv3 | Storage optimised | NoSQL, local NVMe | ephemeral local disk, not durable |
| M | Very large memory | SAP HANA | up to multi-TB RAM |
| N (NC/ND/NV) | GPU | training, inference, viz | quota is per-family, request early |
| H | HPC, InfiniBand | CFD, simulation | RDMA fabric |

**Constrained-core SKUs** (e.g. `Standard_E32-8s_v5`) expose 8 vCPUs to the OS while retaining the full memory and I/O of the 32-vCPU size. This exists *solely* to reduce per-core licensing (Oracle, SQL Server) without reducing RAM/IOPS. It is the correct answer to the "licensed per-core pricing engine" requirement above.

**Disk types and their SLA consequence:**

| Disk | Max IOPS/disk (approx.) | Latency | Used for |
|---|---|---|---|
| Standard HDD | 2,000 | ms | backups, cold data |
| Standard SSD | 6,000 | low ms | dev/test, light prod |
| Premium SSD v1 | 20,000 | sub-ms | production OS + data |
| Premium SSD v2 | 80,000, IOPS decoupled from size | sub-ms | production, tunable |
| Ultra Disk | 400,000 | sub-ms, configurable | tier-1 databases |

The disk choice is **not** merely performance — the single-instance VM SLA is defined by it (see §2.4).

### 2.3 Placement: availability sets, availability zones, scale sets

This is the highest-yield concept in the whole domain, and the one most often answered wrong.

**Fault Domain (FD):** a rack — shared power and top-of-rack switch. Losing an FD is a physical failure.
**Update Domain (UD):** a maintenance group — Azure reboots one UD at a time during planned host maintenance.

| Construct | Protects against | Scope | Max spread |
|---|---|---|---|
| Availability Set | rack failure + planned host maintenance | single datacenter | up to 3 FD, up to 20 UD |
| Availability Zone | datacenter failure (power, cooling, network) | region, ≥3 zones | 3 zones |
| Region pair | regional disaster | ≥2 regions | n/a |

An availability set does **not** survive a datacenter outage. An availability zone deployment does. You cannot place a VM in both an availability set and an availability zone.

**Virtual Machine Scale Sets (VMSS)** — two orchestration modes:

| | Uniform | Flexible |
|---|---|---|
| Instance model | identical, VMSS-managed, not real `Microsoft.Compute/virtualMachines` | real VM objects, individually addressable |
| Mixed SKUs / spot+regular mix | no | yes |
| Attach existing VM | no | yes |
| Fault domain control | implicit | explicit `platformFaultDomainCount` |
| Availability set–style semantics | no | yes (FD spread without a set) |
| Recommended for new work | legacy | **yes — the default since 2023** |

Flexible orchestration is the modern answer: it gives you scale-set autoscaling and upgrade policies while each instance remains a first-class VM you can `az vm run-command` against, tag individually, and attach a distinct NIC to.

### 2.4 SLA arithmetic (why placement is a business decision)

Microsoft publishes availability commitments that depend entirely on topology:

| Topology | Committed monthly uptime | Approx. downtime/month |
|---|---|---|
| Single VM, Standard HDD | 95% | ~36 h |
| Single VM, Standard SSD (all disks) | 99.5% | ~3.6 h |
| Single VM, Premium SSD / Ultra (all disks) | 99.9% | ~43 min |
| ≥2 VMs in one availability set | 99.95% | ~22 min |
| ≥2 VMs across ≥2 availability zones | 99.99% | ~4.4 min |

Two consequences engineers routinely miss:

1. **A single VM with a Standard HDD data disk drops the whole VM to the lowest tier.** The SLA says *all* OS and data disks must meet the tier. One forgotten HDD scratch disk costs you two nines on paper.
2. **Composite SLA multiplies.** A request path of Front Door (99.99) → App Gateway (99.95) → VM set (99.99) → SQL DB (99.99) yields `0.9999 × 0.9995 × 0.9999 × 0.9999 ≈ 99.92%`. Adding components *reduces* availability unless each is independently redundant. Always verify the current figures in the live SLA document (§8) — they are contractual and change.

### 2.5 Containers

| Service | Abstraction | Scale to zero | Ingress | Best for |
|---|---|---|---|---|
| **Azure Container Instances (ACI)** | a container group (1..n containers sharing lifecycle, network, volumes) | n/a (per-second billing, you start/stop) | public IP or VNet injection | short-lived jobs, CI runners, AKS virtual-node burst |
| **Azure Container Apps** | serverless containers on a managed Kubernetes + KEDA + Envoy + Dapr | **yes** | built-in HTTP/TCP ingress, split traffic by revision | microservices, event-driven APIs, background workers |
| **Azure Kubernetes Service (AKS)** | managed Kubernetes control plane | no (nodes ≥1, unless virtual nodes) | anything you install | full K8s API, operators, CRDs, service mesh, multi-tenant platforms |
| **Azure Red Hat OpenShift** | managed OpenShift | no | OpenShift routes | organisations standardised on OpenShift |

**When to choose AKS over Container Apps:** you need the Kubernetes API itself — CRDs, admission webhooks, operators, DaemonSets, node-level tuning, a service mesh you control, or GPU node pools with device plugins. If your requirement list is "run this container, scale it on a queue, give it HTTPS and a private endpoint", Container Apps removes an entire class of on-call work (node upgrades, CNI IP exhaustion, cluster autoscaler tuning) at the cost of the K8s API surface.

**AKS pricing tiers** matter for SLA:

| Tier | Control-plane commitment | Notes |
|---|---|---|
| Free | best-effort SLO, no financial SLA | dev/test only |
| Standard | financially-backed SLA (higher with availability zones) | production default |
| Premium | Standard + long-term support for older K8s minors | slow-moving regulated estates |

### 2.6 Azure App Service

PaaS for HTTP workloads (Web Apps, API Apps, WebJobs, Logic-app-adjacent hosting). You deploy code or a container; Azure owns the OS, runtime patching, TLS termination, and scale-out.

**App Service Plan tiers:**

| Tier | Scale-out | Custom domain + TLS | VNet integration | Zone redundancy | Use |
|---|---|---|---|---|---|
| Free (F1) / Shared (D1) | none | limited | no | no | experiments |
| Basic (B1–B3) | manual | yes | yes (regional) | no | dev/test |
| Standard (S1–S3) | autoscale | yes | yes | no | small prod |
| Premium v3 (P0v3–P5v3) | autoscale, more RAM/CPU | yes | yes | **yes** | production default |
| Isolated v2 (I1v2+) | autoscale, dedicated | yes | injected into your VNet | yes | PCI/regulated, private-only |

Key production features: **deployment slots** (staged swap with warm-up, and the swap is a routing change, not a redeploy), **regional VNet integration** for outbound to private resources, **Private Endpoint** for inbound-private, and **Always On** (without it, the Free/Basic app unloads after 20 minutes of idle and the first request pays a cold start).

### 2.7 Azure Functions

Event-driven code. The unit is a *trigger* + *bindings*, not a server.

| Hosting plan | Scale to zero | Cold start | Max duration (default/max) | VNet | Use |
|---|---|---|---|---|---|
| Consumption | yes | yes | 5 min / 10 min | limited | spiky, cheap, tolerant of latency |
| Flex Consumption | yes | reduced (always-ready instances) | configurable | yes | modern default for serverless |
| Premium (Elastic) | no (pre-warmed) | none | 30 min / unbounded | yes | latency-sensitive, private networking |
| Dedicated (App Service plan) | no | none | 30 min / unbounded | yes | reuse existing plan capacity |
| Container Apps hosting | yes | yes | n/a | yes | Functions alongside other containers |

**The 10-minute wall is an architecture constraint, not a knob.** If your settlement job takes 40 minutes, Consumption is wrong: use Durable Functions fan-out/fan-in, a Container Apps job, or a Batch pool. Choosing Consumption and then discovering the timeout in production is the classic serverless outage.

### 2.8 Azure Virtual Desktop

VDI/DaaS: Windows 10/11 **multi-session** (a Windows client SKU that permits concurrent users — unavailable on-prem), pooled or personal host pools, FSLogix profile containers on Azure Files, and per-user licensing. Architecturally it is a VMSS-like fleet of session hosts plus a Microsoft-managed brokering/gateway control plane; you own the session hosts and the golden image.

### 2.9 Compute decision table for the reference platform

| Workload | Choice | Reason |
|---|---|---|
| Checkout API | Container Apps (Consumption workload profile) | HTTP, scale-to-low, revision-based canary, no K8s ops |
| Settlement batch (03:00–05:00) | Container Apps **Job** (scheduled) or Durable Functions | exceeds 10 min → not plain Consumption |
| Pricing engine (licensed per-core) | VM, constrained-core `Standard_E32-8s_v5`, zone-redundant pair | licensing + no autoscale + memory-bound |
| Platform services, operators, mesh | AKS Standard tier, 3 zones | needs the Kubernetes API |
| Ad-hoc data fixes / CI agents | ACI | per-second billing, no idle cost |

---

## 3. Azure networking services

### 3.1 Virtual Network fundamentals

A **VNet** is an isolated L3 broadcast-free network with a private address space you control. Subnets partition it; a NIC lives in exactly one subnet.

**Azure reserves 5 IP addresses in every subnet:**

| Address | Purpose |
|---|---|
| `x.x.x.0` | network address |
| `x.x.x.1` | default gateway |
| `x.x.x.2` | Azure DNS mapping |
| `x.x.x.3` | Azure DNS mapping (reserved for future) |
| `x.x.x.255` (last) | broadcast |

So a `/24` yields **251** usable addresses, not 254. The smallest supported subnet is `/29` (3 usable). Get this wrong when sizing an AKS Azure-CNI subnet and you will hit IP exhaustion at scale-out — the pods each consume a VNet IP.

**Reserved subnet names** (the name is load-bearing; Azure matches on the exact string):

| Name | Minimum size | Service |
|---|---|---|
| `GatewaySubnet` | `/29` (use `/27`) | VPN Gateway / ExpressRoute Gateway |
| `AzureFirewallSubnet` | `/26` | Azure Firewall |
| `AzureBastionSubnet` | `/26` | Azure Bastion |
| `RouteServerSubnet` | `/27` | Azure Route Server |
| (dedicated, any name) | `/24` recommended | Application Gateway v2 |

**168.63.129.16** is Azure's platform virtual IP, reachable from every VNet. It serves DNS, delivers DHCP leases, sources **load balancer health probes**, and carries the guest-agent heartbeat. Blocking it in an NSG or a host firewall breaks health probes and agent extensions — and the symptom is "the load balancer says my healthy VM is unhealthy". Memorise the address.

### 3.2 Network Security Groups and Application Security Groups

An **NSG** is a stateful 5-tuple filter attachable to a **subnet** and/or a **NIC**. Rules have a priority 100–4096, lowest number wins, evaluation stops at first match. Because it is stateful, an allowed inbound flow's return traffic is permitted automatically — you do not write a mirrored outbound rule.

**Default rules (cannot be deleted, only overridden by lower priority numbers):**

| Direction | Priority | Name | Effect |
|---|---|---|---|
| Inbound | 65000 | `AllowVnetInBound` | VirtualNetwork → VirtualNetwork allow |
| Inbound | 65001 | `AllowAzureLoadBalancerInBound` | probes from `AzureLoadBalancer` tag |
| Inbound | 65500 | `DenyAllInBound` | deny |
| Outbound | 65000 | `AllowVnetOutBound` | allow |
| Outbound | 65001 | `AllowInternetOutBound` | allow |
| Outbound | 65500 | `DenyAllOutBound` | deny |

**Evaluation order when both a subnet NSG and a NIC NSG exist:** inbound traffic hits the **subnet NSG first, then the NIC NSG**; outbound is the reverse (NIC, then subnet). Both must allow. This is the number-one cause of "I added an allow rule and it still doesn't work".

**Service tags** (`Internet`, `VirtualNetwork`, `AzureLoadBalancer`, `Storage`, `Sql`, `AzureActiveDirectory`, `AzureCloud.<region>`) are Microsoft-maintained prefix sets — use them instead of hardcoding CIDRs that change.

**Application Security Groups (ASG)** let you write rules against *workload roles* instead of IPs: put NICs into `asg-web` and `asg-db`, then write "allow 5432 from `asg-web` to `asg-db`". The rule survives re-IPing and scale-out. This is how you keep a PCI segmentation model readable.

### 3.3 Connectivity between networks

| Option | Layer | Transitive | Bandwidth | Encryption | Use |
|---|---|---|---|---|---|
| **VNet peering** (regional) | Azure backbone | **no** | VM-NIC limited | not by default (option available on supported SKUs) | hub-spoke, spoke-to-shared-services |
| **Global VNet peering** | Azure backbone | no | VM-NIC limited | as above | cross-region private |
| **Site-to-Site VPN** | IPsec/IKEv2 over Internet | via gateway transit | ~650 Mbps – 10 Gbps by SKU | yes | branch offices, ER backup |
| **Point-to-Site VPN** | IPsec / OpenVPN / SSTP | n/a | per-client | yes | developers, jump access |
| **ExpressRoute** | private circuit via provider | via ER + Global Reach | 50 Mbps – 100 Gbps | no (add MACsec/IPsec) | datacenter interconnect, predictable latency |
| **Virtual WAN** | managed hub mesh | **yes (any-to-any)** | scales with hub | per-link | many branches/regions |

**Peering is non-transitive.** Spoke-A ↔ Hub ↔ Spoke-B does **not** give Spoke-A ↔ Spoke-B. You get spoke-to-spoke only by (a) routing through an NVA/Azure Firewall in the hub with UDRs, (b) direct spoke-to-spoke peering (n² problem), or (c) Virtual WAN, which implements transit for you.

**Gateway transit** is the peering flag that lets a spoke use the hub's VPN/ExpressRoute gateway — without it every spoke needs its own gateway (expensive and slow to provision).

**ExpressRoute peering types:** *Private peering* (your VNets, RFC1918) and *Microsoft peering* (Microsoft 365 / public PaaS endpoints over the circuit). Public peering is deprecated. **ExpressRoute Global Reach** connects two on-prem sites *to each other* through the Microsoft backbone.

### 3.4 Load balancing: choosing the right plane

Four services, distinguished by **layer** and **scope**:

| Service | OSI layer | Scope | Protocols | Key capabilities |
|---|---|---|---|---|
| **Azure Load Balancer** (Standard) | L4 | regional (zone-redundant or zonal) | TCP, UDP | ultra-low latency, HA ports, outbound rules, 1000s of flows, no payload inspection |
| **Application Gateway** (v2) | L7 | regional | HTTP/S, HTTP/2, WebSocket | WAF, URL-path & host routing, TLS termination/re-encryption, cookie affinity, header/URL rewrite, autoscaling |
| **Azure Front Door** (Std/Premium) | L7 | **global**, anycast | HTTP/S | edge TLS, caching/CDN, WAF at edge, split TCP, Private Link origins (Premium), global failover |
| **Traffic Manager** | DNS (L7-ish, no data path) | **global** | any (it only answers DNS) | routing methods below; traffic never traverses it |

**Traffic Manager routing methods:** Priority (active/passive), Weighted (canary/blue-green by percentage), Performance (lowest network latency), Geographic (data-sovereignty routing), MultiValue (return several healthy endpoints), Subnet (map client CIDR → endpoint). Because it is DNS, failover is bounded by **TTL**: a 300-second TTL means up to 5 minutes of clients still resolving the dead endpoint. Front Door, by contrast, fails over inside the anycast data path in seconds — this is the decisive difference for an RTO of 15 minutes with sub-minute expectations.

**Canonical composition for the reference platform:**

```
Client
  └─ Azure Front Door Premium      (global anycast, WAF, TLS, caching, origin failover)
       ├─ origin: region primary → Application Gateway WAF_v2 (zone-redundant)
       │                              └─ backend pool: VMSS Flexible (3 zones)
       └─ origin: region secondary → App Gateway (warm standby)
Internal
  └─ Internal Standard Load Balancer (HA ports) → Azure Firewall → spokes
```

**Standard Load Balancer is "secure by default":** unlike the retired Basic SKU, it does not permit inbound traffic unless an NSG explicitly allows it. Add to this the retirement of **default outbound access** — VMs deployed in new subnets no longer receive an implicit outbound SNAT address — and the practical rule becomes: **always define egress explicitly**, via NAT Gateway (preferred), load-balancer outbound rules, or an instance public IP. NAT Gateway provides ~64,512 SNAT ports per attached public IP and eliminates the SNAT-exhaustion failure mode that plagues load-balancer-based egress under high connection churn.

### 3.5 Private access to PaaS: Service Endpoints vs Private Endpoints

| | Service Endpoint | Private Endpoint |
|---|---|---|
| Mechanism | subnet identity extended to the PaaS firewall; traffic stays on backbone but uses the **public** endpoint | a **NIC with a private IP in your subnet**, mapped to a specific PaaS resource via Private Link |
| DNS change needed | no | **yes** — `privatelink.*` private DNS zone |
| Reachable from on-prem (VPN/ER) | no | **yes** |
| Granularity | whole service in the region | one specific resource (this storage account, this blob sub-resource) |
| Data-exfiltration control | weak (any account in the service is reachable) | strong |
| Cost | free | per-endpoint + per-GB |

For anything in PCI scope, Private Endpoint is the answer. The failure mode to anticipate: the private endpoint is created but DNS still resolves the public A record, so traffic leaves via the Internet path and the storage firewall denies it. **Verify DNS, not just the endpoint object.**

### 3.6 Azure DNS, Bastion, Firewall

- **Azure DNS** — authoritative hosting for public zones; **Private DNS zones** resolve names inside VNets and are the mandatory companion to Private Endpoints (auto-registration of VM records is optional per virtual-network link).
- **Azure Bastion** — managed jump host: RDP/SSH over TLS in the portal or via native client, no public IP on the target VM, no bastion VM to patch. Requires the `AzureBastionSubnet` (`/26`+). SKUs: Developer (shared, no subnet, dev only), Basic, Standard (scale units, native client, IP-based connection), Premium (session recording, private-only deployment).
- **Azure Firewall** — stateful FQDN-aware NVA with threat intelligence, DNAT/SNAT, network + application rule collections, and a Premium tier adding TLS inspection and IDPS. It is the hub's forced-tunnelling target for the "no unaudited egress" requirement.

---

## 4. Infrastructure and manifests (complete, deployable)

### 4.1 Hub-and-spoke network — Bicep

`network-hub-spoke.bicep`:

```bicep
targetScope = 'resourceGroup'

@description('Deployment region for all networking resources.')
param location string = resourceGroup().location

@description('Environment discriminator used in resource names.')
@allowed([ 'dev', 'stg', 'prod' ])
param env string = 'prod'

param hubAddressSpace string   = '10.0.0.0/22'
param spokeAddressSpace string = '10.10.0.0/20'

var hubName   = 'vnet-hub-${env}-${location}'
var spokeName = 'vnet-app-${env}-${location}'

// ---------------------------------------------------------------- ASGs
resource asgWeb 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-web-${env}'
  location: location
}

resource asgApp 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-app-${env}'
  location: location
}

resource asgData 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-data-${env}'
  location: location
}

// ---------------------------------------------------------------- NSGs
resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-web-${env}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-AppGw-Management'
        properties: {
          description: 'Application Gateway v2 health/management plane. Mandatory.'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Allow-LB-Probe'
        properties: {
          description: 'Health probes originate from 168.63.129.16 (AzureLoadBalancer tag).'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Https-From-Internet'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgWeb.id } ]
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-app-${env}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Web-To-App-8080'
        properties: {
          description: 'Role-based rule: survives re-IP and scale-out.'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceApplicationSecurityGroups: [ { id: asgWeb.id } ]
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgApp.id } ]
          destinationPortRange: '8080'
        }
      }
      {
        name: 'Allow-LB-Probe'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Direct-Internet-Egress'
        properties: {
          description: 'Egress must traverse the hub firewall via UDR, never break out locally.'
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- Egress
resource pipNat 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-nat-${env}'
  location: location
  sku: { name: 'Standard' }
  zones: [ '1', '2', '3' ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource natGw 'Microsoft.Network/natGateways@2023-11-01' = {
  name: 'natgw-${env}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [ { id: pipNat.id } ]
  }
}

// ---------------------------------------------------------------- Routing
resource rtSpoke 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'rt-spoke-${env}'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.1.4'   // AzureFirewallSubnet private IP
        }
      }
      {
        name: 'onprem-via-firewall'
        properties: {
          addressPrefix: '192.168.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.1.4'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- VNets
resource hub 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: hubName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ hubAddressSpace ] }
    subnets: [
      { name: 'GatewaySubnet',      properties: { addressPrefix: '10.0.0.0/27' } }
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: '10.0.1.0/26' } }
      { name: 'AzureBastionSubnet',  properties: { addressPrefix: '10.0.2.0/26' } }
      {
        name: 'snet-shared'
        properties: {
          addressPrefix: '10.0.3.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource spoke 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: spokeName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ spokeAddressSpace ] }
    subnets: [
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: '10.10.0.0/24'   // dedicated, /24 recommended
          networkSecurityGroup: { id: nsgWeb.id }
        }
      }
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: { id: nsgApp.id }
          routeTable: { id: rtSpoke.id }
          natGateway: { id: natGw.id }
        }
      }
      {
        name: 'snet-aks-nodes'
        properties: {
          addressPrefix: '10.10.8.0/21'   // sized for Azure CNI pod IPs
          routeTable: { id: rtSpoke.id }
          natGateway: { id: natGw.id }
        }
      }
      {
        name: 'snet-pep'
        properties: {
          addressPrefix: '10.10.2.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- Peering
resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hub
  name: 'peer-hub-to-spoke'
  properties: {
    remoteVirtualNetwork: { id: spoke.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true        // hub owns the VPN/ER gateway
    useRemoteGateways: false
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spoke
  name: 'peer-spoke-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true          // consume the hub gateway; no gateway per spoke
  }
}

output hubId string   = hub.id
output spokeId string = spoke.id
output asgWebId string  = asgWeb.id
output asgAppId string  = asgApp.id
output asgDataId string = asgData.id
output natGatewayPublicIp string = pipNat.properties.ipAddress
```

### 4.2 Zone-redundant VMSS behind a Standard Load Balancer — Terraform

`vmss-lb.tf`:

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
}

variable "resource_group_name" { type = string  default = "rg-platform-prod" }
variable "location"            { type = string  default = "westeurope" }
variable "subnet_id"           { type = string }
variable "instance_sku"        { type = string  default = "Standard_D4as_v5" }

# ----------------------------------------------------------- Load Balancer
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb-pricing-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"          # Basic SKU is retired
  zones               = ["1", "2", "3"]     # zone-redundant frontend
}

resource "azurerm_lb" "pricing" {
  name                = "lb-pricing-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "fe-public"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "pricing" {
  name            = "bepool-pricing"
  loadbalancer_id = azurerm_lb.pricing.id
}

resource "azurerm_lb_probe" "http" {
  name                = "probe-health-8080"
  loadbalancer_id     = azurerm_lb.pricing.id
  protocol            = "Http"
  port                = 8080
  request_path        = "/healthz"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "https" {
  name                           = "rule-https"
  loadbalancer_id                = azurerm_lb.pricing.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 8443
  frontend_ip_configuration_name = "fe-public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.pricing.id]
  probe_id                       = azurerm_lb_probe.http.id
  idle_timeout_in_minutes        = 15
  enable_tcp_reset               = true
  disable_outbound_snat          = true   # egress handled by NAT Gateway
}

# ----------------------------------------------------------- Scale Set
resource "azurerm_linux_virtual_machine_scale_set" "pricing" {
  name                = "vmss-pricing-prod"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.instance_sku
  instances           = 3
  zones               = ["1", "2", "3"]
  zone_balance        = true              # refuse to converge into a single zone

  admin_username                  = "azureuser"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_ed25519.pub")
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"   # Premium on ALL disks or the SLA tier drops
    caching              = "ReadWrite"
  }

  data_disk {
    lun                  = 0
    caching              = "None"
    create_option        = "Empty"
    disk_size_gb         = 256
    storage_account_type = "Premium_LRS"
  }

  network_interface {
    name    = "nic-pricing"
    primary = true

    ip_configuration {
      name                                   = "ipconfig1"
      primary                                = true
      subnet_id                              = var.subnet_id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.pricing.id]
      # no public_ip_address block: instances are private-only
    }
  }

  health_probe_id = azurerm_lb_probe.http.id

  upgrade_mode = "Rolling"
  rolling_upgrade_policy {
    max_batch_instance_percent              = 20
    max_unhealthy_instance_percent          = 20
    max_unhealthy_upgraded_instance_percent = 20
    pause_time_between_batches              = "PT2M"
  }

  automatic_instance_repair {
    enabled      = true
    grace_period = "PT30M"
  }

  boot_diagnostics {}   # managed storage — required for serial console triage

  identity { type = "SystemAssigned" }

  tags = {
    workload    = "pricing-engine"
    criticality = "tier-1"
    owner       = "platform-sre"
  }
}

# ----------------------------------------------------------- Autoscale
resource "azurerm_monitor_autoscale_setting" "pricing" {
  name                = "autoscale-vmss-pricing"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.pricing.id

  profile {
    name = "cpu-based"

    capacity {
      default = 3
      minimum = 3      # never below 3: one instance per zone
      maximum = 30
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.pricing.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "3"          # scale in multiples of 3 to stay zone-balanced
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.pricing.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT15M"   # longer window down: avoid flapping
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "3"
        cooldown  = "PT15M"
      }
    }
  }
}

output "lb_public_ip" { value = azurerm_public_ip.lb.ip_address }
```

### 4.3 Azure Container Apps — full YAML manifest

`checkout-api.containerapp.yaml`, applied with `az containerapp create --yaml`:

```yaml
location: westeurope
name: ca-checkout-api
resourceGroup: rg-platform-prod
type: Microsoft.App/containerApps
tags:
  workload: checkout-api
  criticality: tier-1
  owner: platform-sre
identity:
  type: SystemAssigned
properties:
  managedEnvironmentId: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform-prod/providers/Microsoft.App/managedEnvironments/cae-prod-weu
  workloadProfileName: Consumption
  configuration:
    activeRevisionsMode: Multiple        # required for weighted canary
    maxInactiveRevisions: 5
    ingress:
      external: false                    # only reachable from the VNet / App Gateway
      targetPort: 8080
      exposedPort: 0
      transport: auto                    # negotiates HTTP/2 where possible
      allowInsecure: false
      clientCertificateMode: require     # mTLS from the gateway
      stickySessions:
        affinity: none
      corsPolicy:
        allowedOrigins:
          - https://checkout.example.com
        allowedMethods: [ GET, POST, OPTIONS ]
        allowCredentials: true
        maxAge: 600
      ipSecurityRestrictions:
        - name: allow-appgw-subnet
          description: Application Gateway subnet only
          ipAddressRange: 10.10.0.0/24
          action: Allow
      traffic:
        - revisionName: ca-checkout-api--v1-14-1
          weight: 90
          label: stable
        - latestRevision: true
          weight: 10
          label: canary
    registries:
      - server: acrplatprod.azurecr.io
        identity: system                 # managed identity, no admin password
    secrets:
      - name: servicebus-connection
        keyVaultUrl: https://kv-plat-prod.vault.azure.net/secrets/sb-checkout-conn
        identity: system
      - name: appinsights-connection
        keyVaultUrl: https://kv-plat-prod.vault.azure.net/secrets/ai-connstring
        identity: system
    dapr:
      enabled: true
      appId: checkout
      appPort: 8080
      appProtocol: http
      enableApiLogging: true
    maxInactiveRevisions: 5
  template:
    revisionSuffix: v1-14-2
    terminationGracePeriodSeconds: 45    # let in-flight payments drain
    containers:
      - name: checkout-api
        image: acrplatprod.azurecr.io/checkout-api:1.14.2
        resources:
          cpu: 1.0
          memory: 2Gi
        env:
          - name: ASPNETCORE_URLS
            value: http://+:8080
          - name: SERVICEBUS_CONNECTION
            secretRef: servicebus-connection
          - name: APPLICATIONINSIGHTS_CONNECTION_STRING
            secretRef: appinsights-connection
          - name: OTEL_SERVICE_NAME
            value: checkout-api
        probes:
          - type: Startup
            httpGet:
              path: /healthz/startup
              port: 8080
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 30        # 150 s budget for JIT + cache warm
          - type: Liveness
            httpGet:
              path: /healthz/live
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          - type: Readiness
            httpGet:
              path: /healthz/ready
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
            successThreshold: 1
        volumeMounts:
          - volumeName: tmp
            mountPath: /tmp
    initContainers:
      - name: schema-check
        image: acrplatprod.azurecr.io/schema-check:1.4.0
        resources:
          cpu: 0.25
          memory: 0.5Gi
        env:
          - name: MODE
            value: verify-only
    volumes:
      - name: tmp
        storageType: EmptyDir
    scale:
      minReplicas: 2                     # no scale-to-zero on a tier-1 API
      maxReplicas: 40
      cooldownPeriod: 300
      pollingInterval: 15
      rules:
        - name: http-concurrency
          http:
            metadata:
              concurrentRequests: "50"
        - name: servicebus-backlog
          custom:
            type: azure-servicebus
            metadata:
              queueName: checkout-events
              messageCount: "20"
            auth:
              - secretRef: servicebus-connection
                triggerParameter: connection
```

### 4.4 AKS workload with an internal load balancer and zone spreading

`checkout-aks.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: payments
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/part-of: payments
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: checkout-api
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      nodeSelector:
        agentpool: apps
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: checkout-api
          image: acrplatprod.azurecr.io/checkout-api:1.14.2
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              memory: "1Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ "ALL" ]
          startupProbe:
            httpGet: { path: /healthz/startup, port: http }
            periodSeconds: 5
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: [ "/bin/sh", "-c", "sleep 10" ]  # let endpoints drain
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: payments
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-app"
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz/ready"
    service.beta.kubernetes.io/azure-load-balancer-health-probe-interval: "5"
    service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "15"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local     # preserves client IP; probes only healthy nodes
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: payments
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-api-default-deny
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  policyTypes: [ Ingress, Egress ]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.10.2.0/24     # private endpoints subnet only
      ports:
        - protocol: TCP
          port: 443
```

---

## 5. CLI: build, inspect, verify

### 5.1 Provisioning the network

```console
$ az group create --name rg-platform-prod --location westeurope -o table
Location    Name
----------  ----------------
westeurope  rg-platform-prod

$ az deployment group create \
    --resource-group rg-platform-prod \
    --name net-hub-spoke-$(date +%Y%m%d%H%M) \
    --template-file network-hub-spoke.bicep \
    --parameters env=prod location=westeurope \
    --query "properties.outputs" -o jsonc
{
  "asgAppId": {
    "type": "String",
    "value": "/subscriptions/.../applicationSecurityGroups/asg-app-prod"
  },
  "asgWebId": {
    "type": "String",
    "value": "/subscriptions/.../applicationSecurityGroups/asg-web-prod"
  },
  "hubId": {
    "type": "String",
    "value": "/subscriptions/.../virtualNetworks/vnet-hub-prod-westeurope"
  },
  "natGatewayPublicIp": {
    "type": "String",
    "value": "20.61.144.87"
  },
  "spokeId": {
    "type": "String",
    "value": "/subscriptions/.../virtualNetworks/vnet-app-prod-westeurope"
  }
}
```

Confirm subnet layout and usable-address arithmetic:

```console
$ az network vnet subnet list -g rg-platform-prod --vnet-name vnet-app-prod-westeurope \
    -o table --query "[].{Name:name, Prefix:addressPrefix, NSG:networkSecurityGroup.id, NAT:natGateway.id}"
Name           Prefix         NSG                                        NAT
-------------  -------------  -----------------------------------------  ----------------------------
snet-appgw     10.10.0.0/24   .../networkSecurityGroups/nsg-web-prod
snet-app       10.10.1.0/24   .../networkSecurityGroups/nsg-app-prod     .../natGateways/natgw-prod
snet-aks-nodes 10.10.8.0/21                                              .../natGateways/natgw-prod
snet-pep       10.10.2.0/24

$ az network vnet subnet show -g rg-platform-prod --vnet-name vnet-app-prod-westeurope \
    -n snet-app --query "{prefix:addressPrefix, available:availableIpAddressCount}" -o json
{
  "available": 251,
  "prefix": "10.10.1.0/24"
}
```

`251`, not `254` — the 5 reserved addresses, minus none consumed yet. Confirming this number is the fastest way to prove you understand Azure subnet arithmetic.

### 5.2 Peering state — the check that catches half of all connectivity tickets

```console
$ az network vnet peering list -g rg-platform-prod --vnet-name vnet-app-prod-westeurope \
    -o table --query "[].{Name:name, State:peeringState, Sync:peeringSyncLevel, UseRemoteGw:useRemoteGateways, Forwarded:allowForwardedTraffic}"
Name             State      Sync             UseRemoteGw    Forwarded
---------------  ---------  ---------------  -------------  -----------
peer-spoke-to-hub  Connected  FullyInSync      True           True
```

`peeringState` must be **`Connected` on both sides**. A one-sided `Initiated` means the reverse peering was never created and no traffic flows. `peeringSyncLevel: RemoteNotInSync` means an address space was added after peering was established — run `az network vnet peering sync` on both sides or the new prefix is invisible.

### 5.3 Compute: deploy and inspect

```console
$ terraform apply -auto-approve -var subnet_id=$(az network vnet subnet show \
    -g rg-platform-prod --vnet-name vnet-app-prod-westeurope -n snet-app --query id -o tsv)
...
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.

Outputs:

lb_public_ip = "20.61.150.14"

$ az vmss list-instances -g rg-platform-prod -n vmss-pricing-prod \
    -o table --query "[].{Id:instanceId, Name:name, Zone:zones[0], State:provisioningState}"
Id    Name                 Zone    State
----  -------------------  ------  ----------
0     vmss-pricing-prod_0  1       Succeeded
1     vmss-pricing-prod_1  2       Succeeded
2     vmss-pricing-prod_2  3       Succeeded
```

One instance per zone — this is what earns the 99.99% tier. If all three land in zone 1, `zone_balance` was not set and you have an availability-set-grade deployment wearing an availability-zone label.

Verify backend health at the load balancer:

```console
$ az network lb address-pool address list -g rg-platform-prod \
    --lb-name lb-pricing-prod --pool-name bepool-pricing -o table
Name                          IpAddress    VirtualNetwork
----------------------------  -----------  --------------------------
vmss-pricing-prod_0-nic       10.10.1.4    vnet-app-prod-westeurope
vmss-pricing-prod_1-nic       10.10.1.5    vnet-app-prod-westeurope
vmss-pricing-prod_2-nic       10.10.1.6    vnet-app-prod-westeurope

$ az monitor metrics list --resource $(az network lb show -g rg-platform-prod \
    -n lb-pricing-prod --query id -o tsv) \
    --metric DipAvailability --interval PT1M --aggregation Average -o table
Timestamp            Name                        Average
-------------------  --------------------------  ---------
2026-09-04 09:41:00  Health Probe Status         100.0
2026-09-04 09:42:00  Health Probe Status         100.0
2026-09-04 09:43:00  Health Probe Status         66.67
```

`DipAvailability` below 100 means at least one backend is failing probes. `66.67` with three instances = exactly one instance down. This metric is the single best load-balancer alerting signal.

### 5.4 Container Apps

```console
$ az containerapp env create \
    --name cae-prod-weu --resource-group rg-platform-prod --location westeurope \
    --infrastructure-subnet-resource-id $(az network vnet subnet show \
        -g rg-platform-prod --vnet-name vnet-app-prod-westeurope -n snet-aks-nodes --query id -o tsv) \
    --internal-only true --enable-workload-profiles true -o table
Name          Location     ResourceGroup     ProvisioningState
------------  -----------  ----------------  -------------------
cae-prod-weu  West Europe  rg-platform-prod  Succeeded

$ az containerapp create --yaml checkout-api.containerapp.yaml -o none
$ az containerapp revision list -n ca-checkout-api -g rg-platform-prod \
    -o table --query "[].{Revision:name, Active:properties.active, Replicas:properties.replicas, Traffic:properties.trafficWeight, Health:properties.healthState}"
Revision                      Active    Replicas    Traffic    Health
----------------------------  --------  ----------  ---------  ---------
ca-checkout-api--v1-14-1      True      4           90         Healthy
ca-checkout-api--v1-14-2      True      2           10         Healthy
```

Shift the canary after the SLO burn-rate check passes:

```console
$ az containerapp ingress traffic set -n ca-checkout-api -g rg-platform-prod \
    --revision-weight ca-checkout-api--v1-14-1=0 ca-checkout-api--v1-14-2=100 -o table
RevisionName                  Weight    Label
----------------------------  --------  -------
ca-checkout-api--v1-14-1      0         stable
ca-checkout-api--v1-14-2      100       canary
```

Traffic weighting is a control-plane routing change: no pods restart, and rollback is the same command with the weights reversed. This is why `activeRevisionsMode: Multiple` is set in the manifest.

### 5.5 Azure Container Instances — the throwaway job

```console
$ az container create \
    --resource-group rg-platform-prod --name aci-reconcile-20260904 \
    --image acrplatprod.azurecr.io/reconcile:2.3.0 \
    --vnet vnet-app-prod-westeurope --subnet snet-app \
    --cpu 2 --memory 4 --restart-policy Never \
    --assign-identity --acr-identity system \
    --environment-variables RUN_DATE=2026-09-03 -o table
Name                     ResourceGroup     Status    Image                                        IP:ports    CPU/Memory        OsType
-----------------------  ----------------  --------  -------------------------------------------  ----------  ----------------  --------
aci-reconcile-20260904   rg-platform-prod  Running   acrplatprod.azurecr.io/reconcile:2.3.0                   2.0 core/4.0 gb   Linux

$ az container logs -g rg-platform-prod -n aci-reconcile-20260904 --tail 5
[2026-09-04T03:14:22Z] loaded 1,284,911 settlement rows
[2026-09-04T03:19:07Z] matched 1,284,903 (99.9994%)
[2026-09-04T03:19:07Z] unmatched 8 -> queue: reconcile-exceptions
[2026-09-04T03:19:08Z] wrote report blob: reports/2026-09-03.parquet
[2026-09-04T03:19:08Z] exit 0

$ az container show -g rg-platform-prod -n aci-reconcile-20260904 \
    --query "containers[0].instanceView.currentState" -o json
{
  "detailStatus": "Completed",
  "exitCode": 0,
  "finishTime": "2026-09-04T03:19:09.000000+00:00",
  "startTime": "2026-09-04T03:14:11.000000+00:00",
  "state": "Terminated"
}
```

Billed for 298 seconds of 2 vCPU + 4 GB. This is the ACI value proposition: no idle cost, no orchestrator.

### 5.6 App Service with slots

```console
$ az appservice plan create -g rg-platform-prod -n asp-portal-prod \
    --sku P1v3 --is-linux --zone-redundant --number-of-workers 3 -o table
Name             Location    Status    Sku    Workers
---------------  ----------  --------  -----  ---------
asp-portal-prod  West Europe  Ready     P1v3   3

$ az webapp create -g rg-platform-prod -p asp-portal-prod -n app-portal-prod \
    --runtime "PYTHON:3.12" -o none
$ az webapp deployment slot create -g rg-platform-prod -n app-portal-prod --slot staging -o none
$ az webapp config set -g rg-platform-prod -n app-portal-prod --always-on true -o none

$ az webapp deployment slot swap -g rg-platform-prod -n app-portal-prod \
    --slot staging --target-slot production --verbose
Command ran in 41.208 seconds.

$ az webapp show -g rg-platform-prod -n app-portal-prod \
    --query "{state:state, host:defaultHostName, https:httpsOnly, tls:siteConfig.minTlsVersion}" -o json
{
  "host": "app-portal-prod.azurewebsites.net",
  "https": true,
  "state": "Running",
  "tls": "1.2"
}
```

The swap warms the staging instances first, then flips the routing — production never serves a cold worker. That warm-up is why a swap is safer than a redeploy, and why rollback is a second swap taking the same ~40 seconds.

---

## 6. Verification and failure diagnosis

### 6.1 The triage ladder

Work top-down; each rung eliminates a layer.

| # | Question | Command | Failure signature |
|---|---|---|---|
| 1 | Is the resource provisioned? | `az resource show --ids <id> --query provisioningState` | `Failed` → read `az monitor activity-log` |
| 2 | Does the instance run? | `az vmss get-instance-view` / `az containerapp replica list` | `PowerState/stopped`, `CrashLoopBackOff` |
| 3 | Does DNS resolve to what you expect? | `nslookup <fqdn> 168.63.129.16` | public IP where a private endpoint IP was expected |
| 4 | Which NSG rule decides this packet? | `az network watcher test-ip-flow` | `Deny` + the deciding rule name |
| 5 | Where does the packet actually go? | `az network watcher show-next-hop` | `None` (blackhole) or the wrong NVA |
| 6 | Does the path work end to end? | `az network watcher test-connectivity` | per-hop `ConnectionStatus` |
| 7 | Is the backend healthy to the LB? | `DipAvailability` / `show-backend-health` | probe timeouts |
| 8 | What is on the wire? | `az network watcher packet-capture create` | SYN with no SYN-ACK = filtered |

### 6.2 NSG: prove which rule is responsible

Never reason about NSG precedence from the portal blade — ask the platform.

```console
$ az network watcher test-ip-flow \
    --vm vmss-pricing-prod_0 --nic vmss-pricing-prod_0-nic \
    --resource-group rg-platform-prod \
    --direction Inbound --protocol TCP \
    --local 10.10.1.4:8080 --remote 10.10.0.7:51422 -o json
{
  "access": "Allow",
  "ruleName": "UserRule_Allow-Web-To-App-8080"
}

$ az network watcher test-ip-flow \
    --vm vmss-pricing-prod_0 --nic vmss-pricing-prod_0-nic \
    --resource-group rg-platform-prod \
    --direction Outbound --protocol TCP \
    --local 10.10.1.4:44012 --remote 13.107.42.14:443 -o json
{
  "access": "Deny",
  "ruleName": "UserRule_Deny-Direct-Internet-Egress"
}
```

The second result is intentional in this design — egress must traverse the firewall via UDR — but this is exactly the output you would see for an accidental outage. When a rule is denying, dump the **effective** rule set (subnet + NIC merged, in evaluation order):

```console
$ az network nic list-effective-nsg --name vmss-pricing-prod_0-nic -g rg-platform-prod \
    --query "value[].{NSG:networkSecurityGroup.id, Assoc:association.subnet.id}" -o table
NSG                                       Assoc
----------------------------------------  ----------------------------------------
.../networkSecurityGroups/nsg-app-prod    .../subnets/snet-app

$ az network nic list-effective-nsg --name vmss-pricing-prod_0-nic -g rg-platform-prod \
    --query "value[0].effectiveSecurityRules[?direction=='Inbound'] | \
             sort_by(@, &priority)[].{P:priority, Name:name, Access:access, Src:sourceAddressPrefix, Port:destinationPortRange}" \
    -o table
P      Name                                        Access    Src                 Port
-----  ------------------------------------------  --------  ------------------  ---------
100    UserRule_Allow-Web-To-App-8080              Allow     10.10.0.0/24        8080-8080
110    UserRule_Allow-LB-Probe                     Allow     AzureLoadBalancer   0-65535
65000  DefaultRule_AllowVnetInBound                Allow     VirtualNetwork      0-65535
65001  DefaultRule_AllowAzureLoadBalancerInBound   Allow     AzureLoadBalancer   0-65535
65500  DefaultRule_DenyAllInBound                  Deny      *                   0-65535
```

Note the ASG rule renders as a resolved prefix — this is how you confirm your ASG membership actually took effect.

### 6.3 Routing: find the blackhole

```console
$ az network watcher show-next-hop \
    --resource-group rg-platform-prod --vm vmss-pricing-prod_0 \
    --source-ip 10.10.1.4 --dest-ip 8.8.8.8 -o json
{
  "nextHopIpAddress": "10.0.1.4",
  "nextHopType": "VirtualAppliance",
  "routeTableId": "/subscriptions/.../routeTables/rt-spoke-prod"
}

$ az network nic show-effective-route-table --name vmss-pricing-prod_0-nic \
    -g rg-platform-prod -o table
Source                 State    Address Prefix    Next Hop Type          Next Hop IP
---------------------  -------  ----------------  ---------------------  -------------
Default                Active   10.10.0.0/20      VnetLocal
Default                Active   10.0.0.0/22       VNetPeering
User                   Active   0.0.0.0/0         VirtualAppliance       10.0.1.4
User                   Active   192.168.0.0/16    VirtualAppliance       10.0.1.4
Default                Invalid  0.0.0.0/0         Internet
Default                Active   20.61.144.87/32   NatGateway
```

Read this carefully:

- The `User` route at `0.0.0.0/0` **overrides** the system Internet route, which is now `Invalid` — forced tunnelling is working.
- `nextHopType: None` on any prefix is a **blackhole**: packets are silently dropped. Common causes are a UDR pointing at an NVA that has been deleted, or a peering that was removed while its routes were still referenced.
- `VNetPeering` present but no route to the second spoke's prefix is the visible proof that peering is non-transitive.

### 6.4 End-to-end connectivity with per-hop attribution

```console
$ az network watcher test-connectivity \
    --resource-group rg-platform-prod --source-resource vmss-pricing-prod_0 \
    --dest-address checkout.internal.example.com --dest-port 443 -o jsonc
{
  "avgLatencyInMs": 3,
  "connectionStatus": "Reachable",
  "hops": [
    {
      "address": "10.10.1.4",
      "nextHopIds": [ "hop-2" ],
      "resourceId": "/subscriptions/.../networkInterfaces/vmss-pricing-prod_0-nic",
      "type": "Source",
      "issues": []
    },
    {
      "address": "10.0.1.4",
      "nextHopIds": [ "hop-3" ],
      "resourceId": "/subscriptions/.../azureFirewalls/afw-hub-prod",
      "type": "VirtualAppliance",
      "issues": []
    },
    {
      "address": "10.10.0.20",
      "nextHopIds": [],
      "resourceId": "/subscriptions/.../applicationGateways/agw-prod",
      "type": "VnetLocal",
      "issues": []
    }
  ],
  "maxLatencyInMs": 9,
  "minLatencyInMs": 2,
  "probesFailed": 0,
  "probesSent": 66
}
```

When it fails, the `issues` array names the culprit resource and type (`NetworkSecurityRule`, `UserDefinedRoute`, `DnsResolution`, `Socket`) — attribution, not guesswork.

### 6.5 Load balancer says "unhealthy" but the app is up

The most common Azure networking false alarm. Checklist, in order:

1. **Is `168.63.129.16` reachable from the guest?** Probes originate there, not from the frontend IP.
   ```console
   $ ssh azureuser@10.10.1.4 -- curl -s -o /dev/null -w '%{http_code}\n' http://168.63.129.16/
   200
   ```
2. **Does an NSG allow the `AzureLoadBalancer` service tag inbound?** The default rule at 65001 does — unless you added a `Deny` at a lower priority. That is the trap: a well-meaning `Deny-All` at priority 4000 kills probes.
3. **Is the app listening on the probe port on `0.0.0.0`, not `127.0.0.1`?**
   ```console
   $ ss -tlnp | grep 8080
   LISTEN 0  4096  0.0.0.0:8080  0.0.0.0:*  users:(("pricing",pid=1412,fd=7))
   ```
   `127.0.0.1:8080` here means every probe fails while `curl localhost` succeeds — the classic "it works when I SSH in" report.
4. **Does the probe path return exactly 200?** HTTP probes accept **only** `200`. A `301` redirect to HTTPS marks the instance down.
   ```console
   $ curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://10.10.1.4:8080/healthz
   200 0.004
   ```
5. **Is the host firewall blocking?** `iptables`/`nftables`/`ufw` inside the guest is invisible to Network Watcher.
   ```console
   $ sudo nft list ruleset | grep -A3 'chain input'
   chain input {
       type filter hook input priority filter; policy drop;
       iif "lo" accept
       ct state established,related accept
   }
   ```
   Policy `drop` with no rule for `168.63.129.16` → probes die silently.

### 6.6 Application Gateway backend health

```console
$ az network application-gateway show-backend-health \
    -g rg-platform-prod -n agw-prod \
    --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{Addr:address, Health:health, Why:healthProbeLog}" -o table
Addr        Health     Why
----------  ---------  ----------------------------------------------------------------
10.10.1.4   Healthy
10.10.1.5   Healthy
10.10.1.6   Unhealthy  Backend server certificate is not whitelisted with Application Gateway.
```

`healthProbeLog` gives the literal cause. The three recurring ones:

| Message fragment | Root cause |
|---|---|
| `certificate is not whitelisted` | end-to-end TLS with a self-signed backend cert and no trusted root uploaded |
| `Backend server timed out` | NSG deny, wrong port, or an app that takes longer than `timeout` to answer |
| `The backend health status could not be retrieved` | the App Gateway subnet lacks the `GatewayManager` inbound rule on `65200-65535` |

That last one is why the Bicep in §4.1 opens `65200-65535` from `GatewayManager` — omit it and the gateway enters a permanently degraded state with no useful error.

### 6.7 SNAT port exhaustion

The signature: intermittent outbound connection failures under load, latency spikes at exactly the point where connection rate rises, and application logs full of connect timeouts to an endpoint that is demonstrably up.

```console
$ az monitor metrics list \
    --resource $(az network nat gateway show -g rg-platform-prod -n natgw-prod --query id -o tsv) \
    --metric SNATConnectionCount TotalConnectionCount \
    --interval PT1M --aggregation Total -o table
Timestamp            Name                        Total
-------------------  --------------------------  -------
2026-09-04 10:12:00  SNAT Connection Count       48213
2026-09-04 10:13:00  SNAT Connection Count       61904
2026-09-04 10:14:00  Total Connection Count      64498
```

Approaching 64,512 per public IP is the ceiling. Remedies, in order of preference: (1) attach additional public IPs or a public IP prefix to the NAT Gateway, (2) enable connection pooling / HTTP keep-alive in the application, (3) reduce `idleTimeoutInMinutes` so ports recycle faster, (4) replace Internet-bound PaaS calls with **Private Endpoints**, which do not consume SNAT ports at all. Option 4 is the architectural fix; the others buy time.

### 6.8 Private Endpoint resolving to the wrong address

```console
$ nslookup stgpaymentsprod.blob.core.windows.net 168.63.129.16
Server:   168.63.129.16
Address:  168.63.129.16#53

Non-authoritative answer:
stgpaymentsprod.blob.core.windows.net  canonical name = stgpaymentsprod.privatelink.blob.core.windows.net.
Name:    stgpaymentsprod.privatelink.blob.core.windows.net
Address: 10.10.2.7
```

Correct: the public name CNAMEs to `privatelink.*`, which resolves to a **private** address in `snet-pep`. If the final address is public (e.g. `20.x.x.x`), the private DNS zone is missing its **virtual network link** to the querying VNet — the endpoint exists, but nothing uses it. Verify the link, not just the endpoint:

```console
$ az network private-dns link vnet list -g rg-platform-prod \
    -z privatelink.blob.core.windows.net -o table
Name                    ResourceGroup     RegistrationEnabled    VirtualNetwork
----------------------  ----------------  ---------------------  --------------------------
link-vnet-app-prod      rg-platform-prod  False                  vnet-app-prod-westeurope
link-vnet-hub-prod      rg-platform-prod  False                  vnet-hub-prod-westeurope
```

### 6.9 Compute-side triage

```console
# VM/VMSS: why is the instance not healthy?
$ az vmss get-instance-view -g rg-platform-prod -n vmss-pricing-prod --instance-id 1 \
    --query "{power:statuses[?starts_with(code,'PowerState')].displayStatus | [0], \
              prov:statuses[?starts_with(code,'ProvisioningState')].displayStatus | [0], \
              ext:extensions[].{name:name, status:statuses[0].displayStatus}}" -o jsonc
{
  "ext": [
    { "name": "ApplicationHealthLinux", "status": "Provisioning succeeded" }
  ],
  "power": "VM running",
  "prov": "Provisioning succeeded"
}

# Boot problems: read the console before opening a support case
$ az vm boot-diagnostics get-boot-log --ids $(az vmss list-instances -g rg-platform-prod \
    -n vmss-pricing-prod --query "[1].id" -o tsv) | tail -12
[   14.882431] cloud-init[891]: Cloud-init v. 24.1 finished
[   15.104220] systemd[1]: Reached target Multi-User System.
[  312.771002] pricing[1412]: FATAL: could not bind to 0.0.0.0:8080: Address already in use

# Container Apps: replicas and their container states
$ az containerapp replica list -n ca-checkout-api -g rg-platform-prod \
    --revision ca-checkout-api--v1-14-2 \
    -o table --query "[].{Replica:name, State:properties.runningState, Reason:properties.runningStateDetails}"
Replica                              State     Reason
-----------------------------------  --------  -----------------------------------------
ca-checkout-api--v1-14-2-6c9f-abcde  Running
ca-checkout-api--v1-14-2-6c9f-fghij  Running

$ az containerapp logs show -n ca-checkout-api -g rg-platform-prod --tail 3 --follow false
{"TimeStamp":"2026-09-04T10:21:03","Log":"listening on :8080"}
{"TimeStamp":"2026-09-04T10:21:04","Log":"servicebus: connected via managed identity"}
{"TimeStamp":"2026-09-04T10:21:09","Log":"readiness ok"}

# AKS: zone distribution of the actual pods
$ kubectl get pods -n payments -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone' 2>/dev/null \
  || kubectl get pods -n payments -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE
checkout-api-7d4b8c9f6-2xk9p    1/1     Running   0          12m   10.10.8.41   aks-apps-19238471-vmss000000
checkout-api-7d4b8c9f6-5tq4w    1/1     Running   0          12m   10.10.8.88   aks-apps-19238471-vmss000001
checkout-api-7d4b8c9f6-9wm2h    1/1     Running   0          12m   10.10.9.13   aks-apps-19238471-vmss000002

$ kubectl get nodes -L topology.kubernetes.io/zone
NAME                           STATUS   ROLES   AGE   VERSION   ZONE
aks-apps-19238471-vmss000000   Ready    agent   9d    v1.31.3   westeurope-1
aks-apps-19238471-vmss000001   Ready    agent   9d    v1.31.3   westeurope-2
aks-apps-19238471-vmss000002   Ready    agent   9d    v1.31.3   westeurope-3
```

### 6.10 Standing verification: NSG flow logs and Connection Monitor

Point-in-time commands prove the current state; flow logs prove what happened at 03:14 last Tuesday.

```console
$ az network watcher flow-log create \
    --resource-group NetworkWatcherRG --name fl-nsg-app-prod \
    --nsg nsg-app-prod --location westeurope \
    --storage-account stgflowlogsprod --enabled true \
    --retention 90 --format JSON --log-version 2 \
    --workspace $(az monitor log-analytics workspace show -g rg-observability \
        -n law-platform-prod --query id -o tsv) \
    --interval 10 --traffic-analytics true -o table
Name             Enabled    Location     ProvisioningState    RetentionDays
---------------  ---------  -----------  -------------------  ---------------
fl-nsg-app-prod  True       West Europe  Succeeded            90
```

Then the retrospective query in Log Analytics (KQL):

```kusto
AzureNetworkAnalytics_CL
| where TimeGenerated between (datetime(2026-09-04 03:00) .. datetime(2026-09-04 04:00))
| where FlowStatus_s == "D"                       // denied
| where DestPort_d in (443, 5432, 8080)
| summarize Denied = count() by SrcIP_s, DestIP_s, DestPort_d, NSGRule_s
| top 20 by Denied desc
```

Deploy **Connection Monitor** for continuous synthetic probing across the topology (VM → PaaS, VM → on-prem, spoke → spoke) so path degradation is detected before a user reports it, rather than reconstructed afterwards.

---

## 7. Exam-relevant distinctions worth memorising

| If the question says… | The answer is… | Because |
|---|---|---|
| "protect against a datacenter failure within a region" | Availability Zones | availability sets are single-datacenter |
| "protect against rack failure and planned maintenance, one datacenter" | Availability Set | FD + UD spread |
| "route users to the closest region, minimum latency, DNS-level" | Traffic Manager (Performance) | it only answers DNS |
| "global HTTP entry point with WAF and caching" | Azure Front Door | edge, anycast, L7 |
| "URL-path routing and WAF inside one region" | Application Gateway | regional L7 |
| "load balance non-HTTP TCP/UDP at ultra-low latency" | Azure Load Balancer | L4 |
| "connect two VNets privately, low overhead" | VNet peering | backbone, non-transitive |
| "connect on-prem with a dedicated private circuit" | ExpressRoute | not over the Internet |
| "connect on-prem over the Internet, encrypted" | Site-to-Site VPN | IPsec |
| "individual laptops connect to a VNet" | Point-to-Site VPN | per-client |
| "RDP/SSH without a public IP on the VM" | Azure Bastion | managed jump host |
| "run a container for 4 minutes, pay only for that" | ACI | per-second billing |
| "run containers with scale-to-zero and HTTPS, no Kubernetes to manage" | Container Apps | serverless containers |
| "need the Kubernetes API, operators, CRDs" | AKS | managed K8s |
| "run event-driven code, no server management" | Azure Functions | FaaS |
| "host a web app, Azure patches the OS" | App Service | PaaS |
| "Windows 11 multi-session desktops for remote staff" | Azure Virtual Desktop | only Azure offers multi-session Windows client |
| "reduce per-core software licensing but keep the RAM" | constrained-core VM SKU | vCPUs masked, memory retained |
| "a private IP in my subnet for a PaaS service" | Private Endpoint | Private Link NIC |
| "restrict a storage account to a subnet without changing DNS" | Service Endpoint | subnet identity on the PaaS firewall |

---

## 8. References

Official Microsoft documentation, current at the time of writing. Verify SLA figures and retirement dates against the live pages — they are contractual and change.

**Exam and study guide**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Azure Fundamentals certification — https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Compute**
- Azure Virtual Machines documentation — https://learn.microsoft.com/en-us/azure/virtual-machines/
- Sizes for virtual machines in Azure — https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview
- Constrained vCPU capable VM sizes — https://learn.microsoft.com/en-us/azure/virtual-machines/constrained-vcpu
- Availability options for Azure VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Availability sets overview — https://learn.microsoft.com/en-us/azure/virtual-machines/availability-set-overview
- What are Azure availability zones? — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Virtual Machine Scale Sets overview — https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview
- Orchestration modes for scale sets — https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes
- Azure managed disk types — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types
- Azure Kubernetes Service documentation — https://learn.microsoft.com/en-us/azure/aks/
- AKS pricing tiers and SLA — https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers
- Azure Container Apps overview — https://learn.microsoft.com/en-us/azure/container-apps/overview
- Container Apps YAML/ARM specification — https://learn.microsoft.com/en-us/azure/container-apps/azure-resource-manager-api-spec
- Container Apps scale rules — https://learn.microsoft.com/en-us/azure/container-apps/scale-app
- Azure Container Instances overview — https://learn.microsoft.com/en-us/azure/container-instances/container-instances-overview
- Container groups in ACI — https://learn.microsoft.com/en-us/azure/container-instances/container-instances-container-groups
- Azure App Service overview — https://learn.microsoft.com/en-us/azure/app-service/overview
- App Service plan overview — https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans
- Deployment slots — https://learn.microsoft.com/en-us/azure/app-service/deploy-staging-slots
- Azure Functions overview — https://learn.microsoft.com/en-us/azure/azure-functions/functions-overview
- Azure Functions hosting options — https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Azure Virtual Desktop overview — https://learn.microsoft.com/en-us/azure/virtual-desktop/overview

**Networking**
- Azure Virtual Network overview — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview
- Plan virtual networks — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-vnet-plan-design-arm
- Network security groups — https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Application security groups — https://learn.microsoft.com/en-us/azure/virtual-network/application-security-groups
- Virtual network service tags — https://learn.microsoft.com/en-us/azure/virtual-network/service-tags-overview
- What is IP address 168.63.129.16? — https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16
- Virtual network traffic routing (UDR) — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview
- Virtual network peering — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
- Azure VPN Gateway — https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways
- VPN Gateway SKUs — https://learn.microsoft.com/en-us/azure/vpn-gateway/about-gateway-skus
- Azure ExpressRoute overview — https://learn.microsoft.com/en-us/azure/expressroute/expressroute-introduction
- ExpressRoute circuits and peering — https://learn.microsoft.com/en-us/azure/expressroute/expressroute-circuit-peerings
- Azure Virtual WAN overview — https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-about
- Azure Load Balancer overview — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-overview
- Load Balancer health probes — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-custom-probe-overview
- Load Balancer SKU comparison — https://learn.microsoft.com/en-us/azure/load-balancer/skus
- Basic Load Balancer retirement — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-basic-upgrade-guidance
- Default outbound access retirement — https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access
- Azure NAT Gateway overview — https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview
- SNAT with NAT Gateway — https://learn.microsoft.com/en-us/azure/nat-gateway/nat-gateway-resource
- Application Gateway overview — https://learn.microsoft.com/en-us/azure/application-gateway/overview
- Application Gateway infrastructure configuration — https://learn.microsoft.com/en-us/azure/application-gateway/configuration-infrastructure
- Application Gateway backend health troubleshooting — https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-backend-health-troubleshooting
- Azure Front Door overview — https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview
- Azure Traffic Manager routing methods — https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-routing-methods
- Load-balancing options decision guide — https://learn.microsoft.com/en-us/azure/architecture/guide/technology-choices/load-balancing-overview
- Azure DNS overview — https://learn.microsoft.com/en-us/azure/dns/dns-overview
- Azure Private DNS zones — https://learn.microsoft.com/en-us/azure/dns/private-dns-overview
- Azure Private Link / Private Endpoint — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview
- Private Endpoint DNS configuration — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
- Virtual network service endpoints — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-service-endpoints-overview
- Azure Bastion overview — https://learn.microsoft.com/en-us/azure/bastion/bastion-overview
- Azure Firewall overview — https://learn.microsoft.com/en-us/azure/firewall/overview

**Diagnostics and reliability**
- Azure Network Watcher overview — https://learn.microsoft.com/en-us/azure/network-watcher/network-watcher-overview
- IP flow verify — https://learn.microsoft.com/en-us/azure/network-watcher/ip-flow-verify-overview
- Next hop — https://learn.microsoft.com/en-us/azure/network-watcher/next-hop-overview
- Connection troubleshoot — https://learn.microsoft.com/en-us/azure/network-watcher/connection-troubleshoot-overview
- NSG flow logs — https://learn.microsoft.com/en-us/azure/network-watcher/nsg-flow-logs-overview
- Connection Monitor — https://learn.microsoft.com/en-us/azure/network-watcher/connection-monitor-overview
- Azure Load Balancer metrics and diagnostics — https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-standard-diagnostics
- Boot diagnostics — https://learn.microsoft.com/en-us/azure/virtual-machines/boot-diagnostics
- Azure reliability documentation — https://learn.microsoft.com/en-us/azure/reliability/
- Service Level Agreements for Microsoft Online Services — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services

**Tooling references**
- Azure CLI `az network` reference — https://learn.microsoft.com/en-us/cli/azure/network
- Azure CLI `az vmss` reference — https://learn.microsoft.com/en-us/cli/azure/vmss
- Azure CLI `az containerapp` reference — https://learn.microsoft.com/en-us/cli/azure/containerapp
- Bicep documentation — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
- Azure Resource Manager template reference (`Microsoft.Network`) — https://learn.microsoft.com/en-us/azure/templates/microsoft.network/allversions