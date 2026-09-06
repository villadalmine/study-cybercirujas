# 1.2 Describe the benefits of using cloud services

**Certification:** Microsoft Azure Fundamentals (AZ-900) — syllabus version 2026-07-20
**Domain:** 1 — Describe cloud concepts
**Exam weight:** 9.4

The official study guide breaks this objective into four bullets:

- Describe the benefits of **high availability** and **scalability** in the cloud
- Describe the benefits of **reliability** and **predictability** in the cloud
- Describe the benefits of **security** and **governance** in the cloud
- Describe the benefits of **manageability** in the cloud

Those four words are the exam surface. This document treats them as what they actually are in production: four distinct engineering controls with measurable outputs, hard trade-offs, and specific failure modes. Every claim below is expressible as a command that returns a number.

---

## 1. The production problem: why "benefits" is an architecture question, not a marketing one

Consider a concrete system: a public-facing HTTP API serving 4,000 requests/second at peak, backed by a relational database, with a business requirement of **99.99% monthly availability** and a **contractual RPO of 15 minutes**.

Built on-premises, the constraint set looks like this:

- **Capacity is a purchase order.** Adding compute means a 6–14 week procurement cycle. You therefore size for *peak plus headroom plus growth*, and you pay for that silicon 24/7. Measured utilization in traditional enterprise datacenters typically sits well below 30%: you bought 100% of the capacity to use a third of it.
- **Redundancy is a second building.** 99.99% means surviving the loss of a power feed, a top-of-rack switch, a UPS, and a cooling loop. Achieving that on-prem means a second facility, a second network path, a second license set, and a team that can rehearse failover.
- **The failure domain is invisible.** You do not know, without a physical audit, whether the two "redundant" hypervisors are on the same PDU.
- **Cost is CapEx.** The money is spent before the first request is served, depreciated over 3–5 years, and unrecoverable if the product fails.

The cloud does not remove any of these problems. It **re-expresses them as API-addressable primitives with a contractual number attached**. That is the entire benefit set:

| On-prem problem | Cloud primitive | The number it buys you |
|---|---|---|
| Peak-sized fleet idle 70% of the time | Autoscale / consumption billing | Cost tracks load, not forecast |
| Second building for redundancy | Availability Zones | 99.99% VM SLA, deployed in one `az` command |
| Invisible failure domains | Zones + fault domains as declared metadata | You can *assert* isolation in a manifest |
| Procurement lead time | Elastic capacity | Minutes, bounded by quota — not weeks |
| CapEx sunk before revenue | OpEx / reservations / spot | Failure costs the run rate, not the balance sheet |
| Configuration drift across DCs | ARM/Bicep/Terraform + Azure Policy | Drift is detectable and deniable at the control plane |
| "Are we compliant?" answered by spreadsheet | Policy compliance state, Defender for Cloud | A queryable percentage |

**The critical mental model for the exam and for production:** the cloud provides *the capability* for high availability, not high availability itself. A single VM in Azure is less available than a well-run on-prem HA pair. The benefit is only realized when you deploy across the failure domains the platform exposes. This distinction — capability versus outcome — is where both real outages and exam distractors live.

---

## 2. High availability: the arithmetic

### 2.1 What an SLA number actually costs you in minutes

Availability is a percentage of a billing month. Translate it before you agree to it.

| SLA | Downtime / month (30 d) | Downtime / year | What it implies operationally |
|---|---|---|---|
| 99% ("two nines") | 7 h 12 min | 3.65 days | A single instance, manual recovery, business hours on-call |
| 99.5% | 3 h 36 min | 1.83 days | Standard HDD-backed single VM territory |
| 99.9% ("three nines") | 43.2 min | 8.76 h | One instance, but fast automated recovery. No human can hit this reliably at 03:00 |
| 99.95% | 21.6 min | 4.38 h | Redundancy inside one datacenter (availability set) |
| 99.99% ("four nines") | 4.32 min | 52.6 min | Zone redundancy is **mandatory**. Detection alone must be < 60 s |
| 99.999% ("five nines") | 25.9 s | 5.26 min | Multi-region active/active. No human in the recovery path at all |

Read the 99.99% row carefully: **4.32 minutes per month is less time than a human takes to read a page and open a laptop.** Anything above 99.95% is a statement about automation, not about hardware.

### 2.2 The Azure VM SLA ladder

Azure's compute SLA is not a single number — it is tiered by the failure domains you deploy across. This table is the single highest-yield fact in this objective.

| Deployment topology | Monthly SLA | Failure domain survived | Cost multiplier |
|---|---|---|---|
| Single VM, Standard HDD disks | 95% | Nothing meaningful | 1× |
| Single VM, Standard SSD disks | 99.5% | Nothing (host reboot = outage) | 1× |
| Single VM, **all** OS+data disks Premium SSD / Premium SSD v2 / Ultra | 99.9% | Nothing (planned host maintenance still hits you) | ~1.1× |
| 2+ VMs in an **availability set** (fault + update domains) | 99.95% | Rack/PDU/ToR switch, host update waves | 2× |
| 2+ VMs across 2+ **availability zones** | **99.99%** | Entire datacenter: power, cooling, network | 2–3× (plus inter-zone latency) |

**Mechanics that matter:**

- An **availability set** distributes VMs across *update domains* (patched in waves, so Azure never reboots all your instances at once) and *fault domains* (distinct rack, power, network). It protects against rack-level and maintenance-level failure. It does **not** protect against a datacenter losing power, because all fault domains are in the same building.
- An **availability zone** is a physically separate location within a region with independent power, cooling, and networking. Azure-enabled regions have a minimum of three zones, close enough that synchronous replication is viable (round-trip latency is engineered to stay in the low single-digit millisecond range) and far enough to be independent failure domains.
- **Zonal vs zone-redundant** is a distinction Azure services split on:
  - *Zonal* — the resource is pinned to one zone (a VM, a managed disk, a NAT Gateway). You get isolation, but you must deploy N of them yourself.
  - *Zone-redundant* — the service replicates across zones internally and presents one endpoint (ZRS storage, zone-redundant Application Gateway v2, Standard Load Balancer frontends, zone-redundant Azure SQL Database). You get resilience without owning the distribution logic.

- **Advanced trap — logical zones are per-subscription.** "Zone 1" is not a physical place. Azure maps logical zone identifiers to physical zones *differently for each subscription*, specifically to prevent every tenant from stacking into physical zone 1. Two subscriptions deploying to `eastus` zone 1 may land in different buildings. If you are correlating an outage across subscriptions, or deliberately co-locating latency-sensitive workloads owned by different subscriptions, you must resolve the physical mapping (command in §6.2).

### 2.3 Composite SLA: availability is multiplicative in series

The SLA of a system is not the SLA of its best component. Dependencies in series multiply.

A typical three-tier request path:

```
Application Gateway v2 (zone-redundant, 99.95%)
        │
        ▼
App Service Plan, Premium v3 (99.95%)
        │
        ▼
Azure SQL Database, zone-redundant Business Critical (99.99%)
```

$$\text{SLA}_{\text{composite}} = 0.9995 \times 0.9995 \times 0.9999 = 0.99890$$

**99.89%** — roughly **47.5 minutes of permitted downtime per month**. Every component met its SLA; the system missed 99.9%. This is why "we used only four-nines services" is not an availability argument.

Adding a redundant path in **parallel** inverts the math — you multiply the *failure* probabilities:

$$\text{SLA}_{\text{parallel}} = 1 - (1 - 0.99890)^2 = 0.99999879$$

But that parallel stack must be fronted by a global traffic router, which re-enters the series:

$$\text{SLA}_{\text{total}} = 0.9999 \times 0.99999879 \approx 0.99989$$

**Conclusion:** a second region moved you from 99.89% to 99.989% — a 10× reduction in expected downtime — and the ceiling is now set entirely by Azure Front Door's own 99.99%. Doubling the infrastructure spend bought exactly one nine, and no further architecture will exceed the front door. That is the trade-off table you take to the business:

| Architecture | Composite SLA | Downtime/month | Relative infra cost | Operational complexity |
|---|---|---|---|---|
| Single VM, Premium disks, one zone | 99.9% (compute only) | 43.2 min | 1× | Low |
| Availability set, single zone | 99.95% | 21.6 min | 2× | Low |
| Zone-redundant, single region, 3 tiers | 99.89% (composite) | 47.5 min | 2.5× | Medium |
| Zone-redundant + read replica, active/passive 2 regions | ~99.95% (failover time dominates) | ~22 min | 3.5× | High — failover must be rehearsed |
| Active/active 2 regions behind Front Door | ~99.989% | ~4.8 min | 5× | Very high — data consistency becomes the hard problem |

The row that traps teams is the fourth: **an active/passive region does not deliver its theoretical SLA unless failover is automatic and tested.** An untested DR region is a cost centre, not an availability control.

### 2.4 Global traffic distribution options

| Service | OSI layer | Scope | Failover mechanism | Health-check granularity | Use it for |
|---|---|---|---|---|---|
| Azure Load Balancer (Standard) | L4 (TCP/UDP) | Regional | Backend pool probe | Per-endpoint TCP/HTTP | Intra-region VM/VMSS distribution, zone-redundant frontend |
| Application Gateway v2 | L7 (HTTP) | Regional | Backend health probe + WAF | Per-path / per-backend-pool | Regional L7 routing, TLS termination, WAF |
| Azure Front Door | L7 (HTTP, anycast edge) | Global | Edge health probes + anycast withdrawal | Per-origin, per-route | Global HTTP entry point, edge caching, global WAF |
| Traffic Manager | DNS | Global | DNS record change | Per-endpoint | Non-HTTP protocols, or global routing where DNS TTL latency is acceptable |

**Trade-off to internalize:** Traffic Manager fails over by changing DNS answers, so recovery time is bounded below by client DNS TTL caching — and many resolvers and JVMs ignore TTLs. Front Door fails over inside the anycast edge, so client-side caching is irrelevant. If your RTO is measured in seconds, Traffic Manager is the wrong tool for HTTP.

---

## 3. Scalability and elasticity

### 3.1 The three words the exam separates

- **Scalability** — the capacity to add resources to handle increased load.
- **Elasticity** — the capacity to add *and remove* them automatically as load changes. Elasticity is scalability plus a control loop plus billing granularity.
- **Agility** — the speed at which you can provision anything at all. This is a lead-time property, not a capacity property.

An on-prem VMware cluster is scalable (you can add hosts) but not elastic (you cannot un-buy them at 03:00 when traffic drops).

### 3.2 Vertical vs horizontal

| Dimension | Vertical (scale up) | Horizontal (scale out) |
|---|---|---|
| Mechanism | Resize the instance: `Standard_D2s_v5 → Standard_D16s_v5` | Add instances behind a load balancer |
| Downtime | Yes — VM deallocate/reallocate cycle (typically 1–5 min) | No |
| Application requirement | None; works for stateful monoliths | Statelessness, or externalized session state |
| Upper bound | The largest SKU available in that region/zone (hard wall) | Subscription quota + backend pool limits (soft, raisable) |
| Availability effect | **Negative** — larger single point of failure | **Positive** — instance loss is absorbed |
| Granularity of cost | Coarse — SKU sizes roughly double | Fine — one instance at a time |
| Recovery from failure | Whole workload down | N−1 capacity, degraded |
| Typical use | Databases, licensing-bound software, legacy monoliths | Web tiers, APIs, stateless workers, containers |

**Production rule:** scale up until the machine is efficient, scale out for availability. A workload that can only scale vertically has a hard availability ceiling regardless of what SLA the platform offers.

### 3.3 Azure autoscale mechanics — and why autoscale silently does nothing

Azure Monitor autoscale evaluates a rule on a fixed cadence. Every field below is a real cause of "autoscale is enabled but the fleet never grew":

| Parameter | Meaning | Common misconfiguration |
|---|---|---|
| `timeGrain` | Sampling interval of the source metric (`PT1M`) | Set finer than the metric actually publishes → no data → no evaluation |
| `timeWindow` | Lookback window aggregated for the decision (`PT5M`, min 5 min) | Set to 5 min on a spiky workload → averages the spike away |
| `timeAggregation` | How samples in the window combine (`Average`, `Max`) | `Average` hides a saturated subset of instances |
| `statistic` | How instances combine (`Average`, `Max`, `Min`) | `Average` across 10 instances where 2 are pinned = no scale-out |
| `cooldown` | Suppression period after a scale action | Scale-out `PT5M` with a 4-min boot time → thrashing; scale-in `PT10M`+ is the safe asymmetry |
| `maximum` capacity | Hard ceiling | Already at max → autoscale evaluates, decides to scale, and fails |
| Subscription vCPU quota | Regional per-family limit | The single most common hard failure. See §6.5 |

**Design rule — asymmetric thresholds.** Scale out at CPU > 70% with a short cooldown; scale in at CPU < 30% with a long cooldown. If the two thresholds are close (out at 70, in at 60), a fleet that scales out immediately drops back under the scale-in threshold *because it scaled out*, and you get an oscillation loop that costs money and destabilizes connection pools. The gap between thresholds must exceed the load-per-instance delta that one scaling step produces.

### 3.4 Kubernetes/AKS scaling layers — three distinct control loops

| Layer | Component | Scales | Reacts to | Typical latency |
|---|---|---|---|---|
| Pod (metric) | HorizontalPodAutoscaler | Replica count | CPU/memory/custom metrics | 15–60 s |
| Pod (event) | KEDA | Replica count, incl. scale-to-zero | Queue depth, event source lag | 5–30 s |
| Node | Cluster Autoscaler | Node count in a node pool | **Unschedulable pods** | 1–4 min (VM provisioning) |
| Node (vertical) | VerticalPodAutoscaler | Pod resource requests | Historical usage | Minutes–hours |

The failure mode nobody predicts: **the Cluster Autoscaler is triggered by pending pods, not by utilization.** If your pods declare no resource `requests`, the scheduler believes the node has infinite room, pods are never `Pending`, and the Cluster Autoscaler never adds a node — while the existing nodes thrash into OOM. Resource requests are the input signal to node autoscaling; omitting them disables it.

---

## 4. Reliability and predictability

### 4.1 Reliability ≠ availability

- **Availability** — is it responding *now*?
- **Reliability** — will it continue to behave correctly over time, including through failure and recovery?

Reliability is what the Azure Well-Architected Framework's Reliability pillar covers: designing for failure, redundancy, and recovery. It is measured with two numbers that must be written into the design, not discovered during an incident:

| Metric | Definition | The question it answers | What drives it |
|---|---|---|---|
| **RTO** (Recovery Time Objective) | Maximum tolerable time to restore service | "How long can we be down?" | Failover automation, DNS/anycast, warm standby |
| **RPO** (Recovery Point Objective) | Maximum tolerable data loss, measured in time | "How much data can we lose?" | Replication mode: sync = 0, async = replication lag |

**The hard trade-off:** RPO = 0 requires synchronous replication, which means every write waits for the remote acknowledgement. Across availability zones (single-digit ms) that is usually acceptable. Across regions (tens to hundreds of ms) it is usually not — so cross-region replication is asynchronous, and cross-region RPO is therefore *never* zero. **You cannot buy RPO=0 across regions; you can only shrink the window.**

### 4.2 Storage redundancy — the durability/availability/cost matrix

| Option | Copies | Placement | Annual durability | Read SLA | Survives zone loss | Survives region loss | Relative cost |
|---|---|---|---|---|---|---|---|
| **LRS** | 3 | One datacenter | 11 nines | 99.9% (hot) | ✗ | ✗ | 1× |
| **ZRS** | 3 | Three AZs, one region | 12 nines | 99.9% (hot) | ✓ | ✗ | ~1.25× |
| **GRS** | 6 | 3 local + 3 in paired region (async) | 16 nines | 99.9% (hot) | ✗ | ✓ (failover) | ~2× |
| **GZRS** | 6 | 3 zones + 3 in paired region (async) | 16 nines | 99.9% (hot) | ✓ | ✓ (failover) | ~2.5× |
| **RA-GRS / RA-GZRS** | 6 | As above + readable secondary endpoint | 16 nines | **99.99%** read | as above | ✓ + immediate reads | ~2.2× / ~2.7× |

Two consequences engineers routinely miss:

1. **Geo-replication is asynchronous.** The secondary region lags. If the primary region is lost before replication completes, that delta is gone. GRS gives you a small, non-zero RPO — not zero.
2. **The `-RA-` variants exist because failover is not instant.** Without read-access, the secondary is invisible until a failover completes. With RA-GRS, your application can immediately read stale-but-available data from the secondary endpoint (`<account>-secondary.blob.core.windows.net`) while the primary is impaired. That is the difference between a degraded read-only mode and a hard outage.

### 4.3 Regions, region pairs, and sovereignty

- A **region** is a set of datacenters within a latency-defined perimeter.
- A **region pair** is a second region in the same geography (usually ≥ 300 miles away) used for geo-replication and staged platform updates — Azure does not deploy an update to both halves of a pair simultaneously.
- **Do not treat pairing as universal.** Newer regions ship without a traditional pair, some pairings are non-symmetric, and Azure has been moving toward availability-zone-based resilience as the primary model. Verify pairing per region against current documentation rather than assuming it.
- **Sovereign clouds** (Azure Government, Azure China operated by 21Vianet) are physically and logically separate instances of Azure with their own control planes and endpoints — a data residency and compliance benefit, not merely a region.

### 4.4 Predictability: the second half of the bullet

The exam splits predictability into two:

**Performance predictability** — autoscale, load balancing, and the Well-Architected Performance Efficiency pillar mean capacity tracks demand instead of degrading under it.

**Cost predictability** — cost tracks consumption and is *forecastable*, monitorable, and enforceable via budgets. This is where the CapEx→OpEx shift becomes concrete:

| Model | Commitment | Typical discount vs pay-as-you-go | Flexibility | Right for |
|---|---|---|---|---|
| **Pay-as-you-go** | None | baseline | Total | Spiky, unproven, or short-lived workloads |
| **Reserved Instances** | 1 or 3 years, specific VM series + region | up to ~72% | Instance-size flexibility within the series; exchange/refund policies apply | Steady-state baseline you are certain of |
| **Savings Plan for compute** | 1 or 3 years, hourly $ commitment | up to ~65% | Applies across series, regions, and some compute services | Steady spend with an uncertain shape |
| **Spot VMs** | None | up to ~90% | **Evictable with 30 s notice** | Batch, CI, rendering, fault-tolerant workers |
| **Azure Hybrid Benefit** | Existing Windows Server / SQL Server licenses with Software Assurance | Large; stacks with reservations | License-bound | Migrating existing licensed estates |
| **Dev/Test pricing** | Eligible subscription types | Reduced rates, no Windows license charge | Non-production only | Lower environments |

**Trade-off:** reservations give the deepest discount and the least flexibility; savings plans trade ~7 points of discount for the freedom to change VM family and region. Both are a bet on a *baseline*. The correct pattern is: reserve the floor, pay-as-you-go the variable band, spot the interruptible band.

**Capital shift, stated precisely:** CapEx is spent before revenue and depreciated; OpEx is spent as the service is consumed and is a deductible operating cost in the period incurred. The strategic benefit is not that cloud is cheaper — it frequently is not at steady state — it is that **the cost of being wrong is bounded by the run rate rather than by a depreciation schedule.**

---

## 5. Security, governance, and manageability

### 5.1 Shared responsibility — the table that decides who gets paged

| Responsibility | On-premises | IaaS | PaaS | SaaS |
|---|---|---|---|---|
| Information and data | Customer | Customer | Customer | Customer |
| Devices (mobile, endpoints) | Customer | Customer | Customer | Customer |
| Accounts and identities | Customer | Customer | Customer | Customer |
| Identity and directory infrastructure | Customer | **Shared** | **Shared** | Microsoft |
| Applications | Customer | Customer | **Shared** | Microsoft |
| Network controls | Customer | Customer | **Shared** | Microsoft |
| Operating system | Customer | **Customer** | Microsoft | Microsoft |
| Physical hosts | Customer | Microsoft | Microsoft | Microsoft |
| Physical network | Customer | Microsoft | Microsoft | Microsoft |
| Physical datacenter | Customer | Microsoft | Microsoft | Microsoft |

Two rows are absolute and are guaranteed exam material:

- **The bottom three are always Microsoft's**, in every service model.
- **The top three are always yours**, in every service model — including SaaS. Nobody else will classify your data or deprovision a leaver's account.

The middle rows are the ones that move, and the direction of movement *is* the IaaS→PaaS→SaaS gradient. Moving from IaaS to PaaS transfers OS patching to Microsoft — that is a real reduction in operational surface, and it is also a real reduction in control. You cannot install a kernel module on App Service.

### 5.2 Governance: the control plane hierarchy

```
Management group  ──► Policy, RBAC inherit downward
      │
      ├── Management group (e.g. "Production")
      │        │
      │        └── Subscription  ──► billing + quota boundary
      │                 │
      │                 └── Resource group  ──► lifecycle + lock boundary
      │                          │
      │                          └── Resource
```

| Control | Enforces | Effects / modes | Where it fires |
|---|---|---|---|
| **Azure Policy** | Resource *configuration* | `Deny`, `Audit`, `Modify`, `Append`, `DeployIfNotExists`, `AuditIfNotExists` | Control plane, at deployment time and continuously |
| **Azure RBAC** | *Who* may perform *which* operation on *which* scope | Role assignments (built-in or custom) | Every ARM request |
| **Resource locks** | Accidental deletion/modification | `CanNotDelete`, `ReadOnly` | Control plane, above RBAC — an Owner is still blocked |
| **Tags** | Metadata for cost allocation and ownership | Name/value pairs; **not inherited by default** — use a `Modify` policy to inherit from the RG | Metadata, queried by Cost Management |
| **Deployment Stacks** | Lifecycle of a managed resource set, with deny settings | `denySettingsMode: denyDelete / denyWriteAndDelete` | Control plane (successor to Azure Blueprints, retired 11 July 2026) |
| **Microsoft Defender for Cloud** | Security posture score, workload protection | Recommendations, regulatory compliance dashboards | Continuous assessment |
| **Cost Management budgets** | Spend thresholds | Alerts, action groups, automation triggers | Billing data (latency of hours) |
| **Azure Resource Graph** | Nothing — it *answers* | KQL over the whole estate | Read-only inventory at scale |

**The governance benefit stated precisely:** on-prem, "all production storage must be zone-redundant" is a document. In Azure it is a `Deny` policy assigned at a management group, and a non-compliant deployment **fails with an HTTP 403 at the control plane before the resource exists**. Policy is the mechanism that converts a standard into an invariant.

**RBAC vs Policy — a guaranteed exam distinction:** RBAC controls *who* can act. Policy controls *what* the resulting resource may look like. An Owner with full RBAC rights is still denied by a policy that forbids public blob access. They are orthogonal, and both are evaluated.

### 5.3 Security benefits that are structural, not configurable

- **Defense in depth** — physical → identity → perimeter → network → compute → application → data. Each layer assumes the one outside it has failed.
- **Zero Trust** — verify explicitly, use least-privilege access, assume breach. In Azure this is Microsoft Entra ID + Conditional Access + Privileged Identity Management (just-in-time role elevation) + Managed Identities.
- **Managed identities eliminate a credential class.** A workload with a system-assigned managed identity retrieves tokens from the instance metadata endpoint. There is no secret in the config file, no secret in the pipeline, no secret to rotate, and no secret to leak. This is a security benefit that has no on-prem equivalent.
- **Azure Key Vault / Managed HSM** — centralized secret, key, and certificate storage with hardware-backed keys, access policies or RBAC, and full audit logging.
- **DDoS Protection** — Azure's network absorbs volumetric attacks at a scale no single tenant could provision. The Basic tier is always-on and free; the Network/IP Protection tiers add tuned per-resource mitigation, telemetry, and cost-protection guarantees.
- **Compliance inheritance** — Microsoft's certifications (ISO 27001, SOC 1/2/3, PCI DSS, FedRAMP, HIPAA, and regional frameworks) apply to the platform layer. You inherit the audited controls for the physical and hypervisor layers and are audited only on your own layers. That is a genuine reduction in audit scope — not an exemption.

### 5.4 Manageability: two phrases the exam separates

**Management *of* the cloud** — how cloud resources manage themselves:
- Automatic scaling in response to demand
- Automatic instance repair and self-healing (`automaticRepairsPolicy`)
- Deploying from templates so an environment is recreated identically
- Platform monitoring, alerting, and automated remediation (`DeployIfNotExists` policies)

**Management *in* the cloud** — how *you* interact with it:
- Azure portal (GUI)
- Azure CLI (`az`) and Azure PowerShell (`Az` module)
- Azure Cloud Shell (browser-hosted, pre-authenticated)
- REST API and language SDKs
- ARM templates / Bicep / Terraform — declarative infrastructure as code

**The IaC benefit is idempotency, and idempotency is what makes DR real.** A declarative template applied twice produces the same result. That property is what allows "rebuild the environment in the paired region" to be a pipeline run instead of a two-week reconstruction from tribal memory.

---

## 6. Complete infrastructure manifests

### 6.1 Bicep — zone-redundant, self-healing, autoscaling web tier

Deploys: Log Analytics workspace, VNet, zone-redundant Standard Load Balancer with health probe and explicit outbound rule, VMSS in **Flexible** orchestration spread across zones 1/2/3, application health extension, automatic instance repair, asymmetric autoscale, and autoscale diagnostics shipped to Log Analytics.

```bicep
// ha-webtier.bicep
// Zone-redundant web tier: 99.99% compute SLA topology.
targetScope = 'resourceGroup'

@description('Azure region. Must be an availability-zone-enabled region.')
param location string = resourceGroup().location

@description('Prefix for all resource names.')
@minLength(3)
@maxLength(12)
param namePrefix string = 'hawt'

@description('VM size. Must be available in all three target zones.')
param vmSize string = 'Standard_D2as_v5'

@description('Local admin username for the scale set instances.')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user.')
@secure()
param sshPublicKey string

@description('Instance count boundaries for autoscale.')
param minCapacity int = 3
param maxCapacity int = 12
param defaultCapacity int = 3

var zones = ['1', '2', '3']
var lbName = '${namePrefix}-lb'
var vmssName = '${namePrefix}-vmss'

// cloud-init: nginx plus a dedicated /healthz endpoint distinct from '/'.
// The probe MUST NOT hit the application root: a root that returns 200 from a
// cached page will keep a broken instance in rotation.
var cloudInit = '''#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /var/www/html/healthz
    permissions: '0644'
    content: |
      ok
  - path: /etc/nginx/sites-available/default
    permissions: '0644'
    content: |
      server {
        listen 80 default_server;
        root /var/www/html;
        location /healthz {
          access_log off;
          try_files /healthz =503;
        }
        location / {
          try_files $uri $uri/ =404;
        }
      }
runcmd:
  - [ systemctl, enable, --now, nginx ]
  - [ systemctl, reload, nginx ]
'''

// ---------------------------------------------------------------- observability
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

// ---------------------------------------------------------------- network
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.42.0.0/16'] }
    subnets: [
      {
        name: 'web'
        properties: {
          addressPrefix: '10.42.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-http-from-lb'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'allow-http-from-internet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

// Standard SKU public IP with all three zones listed = zone-redundant frontend.
// Omitting `zones` on a Standard public IP in an AZ region yields a NON-zonal
// (regional) IP; listing a single zone pins it and makes it a SPOF.
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${namePrefix}-pip'
  location: location
  sku: { name: 'Standard', tier: 'Regional' }
  zones: zones
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: lbName
  location: location
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-public'
        properties: {
          publicIPAddress: { id: pip.id }
        }
      }
    ]
    backendAddressPools: [
      { name: 'be-web' }
    ]
    probes: [
      {
        name: 'probe-healthz'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/healthz'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-http'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          idleTimeoutInMinutes: 4
          enableFloatingIP: false
          enableTcpReset: true
          // Outbound SNAT is handled by an explicit outbound rule below, which
          // gives deterministic port allocation instead of implicit exhaustion.
          disableOutboundSnat: true
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'fe-public')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-web')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'probe-healthz')
          }
        }
      }
    ]
    outboundRules: [
      {
        name: 'ob-web'
        properties: {
          protocol: 'All'
          // 0 = automatic allocation based on backend pool size. Pin an explicit
          // value if you know your per-instance concurrent-flow requirement.
          allocatedOutboundPorts: 0
          idleTimeoutInMinutes: 4
          enableTcpReset: true
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'fe-public')
            }
          ]
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-web')
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- compute
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = {
  name: vmssName
  location: location
  // Listing three zones spreads instances round-robin across them.
  // This is the line that turns a 99.9% deployment into a 99.99% one.
  zones: zones
  sku: {
    name: vmSize
    capacity: defaultCapacity
  }
  properties: {
    orchestrationMode: 'Flexible'
    // Flexible orchestration requires singlePlacementGroup=false and, when
    // spanning availability zones, platformFaultDomainCount=1 (the zone IS the
    // fault domain; fault domains are not subdivided further).
    singlePlacementGroup: false
    platformFaultDomainCount: 1
    automaticRepairsPolicy: {
      enabled: true
      // Grace period must exceed worst-case boot + application warm-up, or the
      // platform will repair instances that were merely still starting.
      gracePeriod: 'PT30M'
      repairAction: 'Replace'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: namePrefix
        adminUsername: adminUsername
        customData: base64(cloudInit)
        linuxConfiguration: {
          disablePasswordAuthentication: true
          provisionVMAgent: true
          patchSettings: {
            patchMode: 'AutomaticByPlatform'
            assessmentMode: 'AutomaticByPlatform'
          }
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          // Premium SSD is a prerequisite for the 99.9% single-instance SLA and
          // the baseline for predictable IOPS.
          managedDisk: { storageAccountType: 'Premium_LRS' }
          deleteOption: 'Delete'
        }
      }
      networkProfile: {
        // Mandatory for Flexible orchestration.
        networkApiVersion: '2020-11-01'
        networkInterfaceConfigurations: [
          {
            name: '${namePrefix}-nic'
            properties: {
              primary: true
              enableAcceleratedNetworking: true
              deleteOption: 'Delete'
              ipConfigurations: [
                {
                  name: '${namePrefix}-ipcfg'
                  properties: {
                    primary: true
                    subnet: { id: vnet.properties.subnets[0].id }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-web')
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'AppHealth'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthLinux'
              typeHandlerVersion: '2.0'
              autoUpgradeMinorVersion: true
              settings: {
                protocol: 'http'
                port: 80
                requestPath: '/healthz'
                intervalInSeconds: 5
                numberOfProbes: 3
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ lb ]
}

// ---------------------------------------------------------------- elasticity
resource autoscale 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: '${namePrefix}-autoscale'
  location: location
  properties: {
    enabled: true
    targetResourceUri: vmss.id
    profiles: [
      {
        name: 'cpu-reactive'
        capacity: {
          minimum: string(minCapacity)
          maximum: string(maxCapacity)
          default: string(defaultCapacity)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
              dividePerInstance: false
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '2'
              // Short cooldown out: reacting late costs availability.
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              // 40-point gap from the scale-out threshold. Narrower gaps
              // produce oscillation: the fleet scales out, drops below the
              // scale-in threshold BECAUSE it scaled out, and scales back in.
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              // Long cooldown in: scaling in late costs money; scaling in
              // early costs availability. Asymmetry is deliberate.
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
    notifications: [
      {
        operation: 'Scale'
        email: {
          sendToSubscriptionAdministrator: true
          sendToSubscriptionCoAdministrators: false
          customEmails: []
        }
      }
    ]
  }
}

// Autoscale decisions are invisible without this. AutoscaleEvaluations records
// every evaluation including the ones that decided NOT to act — which is
// exactly what you need when "autoscale did nothing".
resource autoscaleDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'autoscale-to-law'
  scope: autoscale
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'AutoscaleEvaluations', enabled: true }
      { category: 'AutoscaleScaleActions', enabled: true }
    ]
  }
}

output publicIp string = pip.properties.ipAddress
output vmssResourceId string = vmss.id
output workspaceId string = law.id
output deployedZones array = zones
```

### 6.2 Azure Policy — turning "production must be zone-redundant" into an invariant

```json
{
  "properties": {
    "displayName": "Production storage accounts must be zone-redundant",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Denies creation or update of storage accounts in scopes tagged env=prod unless the SKU replicates across availability zones (ZRS, GZRS, or RA-GZRS).",
    "metadata": {
      "version": "1.0.0",
      "category": "Storage"
    },
    "parameters": {
      "allowedSkus": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed zone-redundant SKUs",
          "description": "Storage SKUs considered zone-resilient."
        },
        "defaultValue": [
          "Standard_ZRS",
          "Standard_GZRS",
          "Standard_RAGZRS",
          "Premium_ZRS"
        ]
      },
      "effect": {
        "type": "String",
        "allowedValues": [ "Audit", "Deny", "Disabled" ],
        "defaultValue": "Deny",
        "metadata": {
          "displayName": "Effect",
          "description": "Start at Audit, measure the non-compliance count, then flip to Deny."
        }
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "equals": "Microsoft.Storage/storageAccounts"
          },
          {
            "field": "tags['env']",
            "equals": "prod"
          },
          {
            "not": {
              "field": "Microsoft.Storage/storageAccounts/sku.name",
              "in": "[parameters('allowedSkus')]"
            }
          }
        ]
      },
      "then": {
        "effect": "[parameters('effect')]"
      }
    }
  }
}
```

Assign it at a management group so it is inherited by every present and future subscription:

```bash
$ az policy definition create \
    --name require-zrs-prod-storage \
    --display-name "Production storage accounts must be zone-redundant" \
    --management-group "mg-corp-production" \
    --rules @policy-rule.json \
    --params @policy-params.json \
    --mode Indexed
```

```bash
$ az policy assignment create \
    --name enforce-zrs-prod \
    --display-name "Enforce ZRS on production storage" \
    --scope "/providers/Microsoft.Management/managementGroups/mg-corp-production" \
    --policy require-zrs-prod-storage \
    --params '{"effect":{"value":"Audit"}}' \
    --enforcement-mode Default
```

> **Operational discipline:** never assign a `Deny` policy directly. Assign it as `Audit`, wait one full compliance evaluation cycle (up to ~24 h, or force one with `az policy state trigger-scan`), read the non-compliant count, remediate, and only then flip the parameter to `Deny`. A `Deny` assigned blind breaks in-flight deployments across every team under that scope.

### 6.3 Kubernetes on AKS — zone spreading, disruption budget, and horizontal scaling

The same availability principles expressed at the workload layer. `topologySpreadConstraints` is the Kubernetes equivalent of `zones: ['1','2','3']`.

```yaml
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: business-critical
value: 1000000
globalDefault: false
description: "Evicted last under node pressure; preempts best-effort workloads."
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: payments
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/component: api
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0        # never dip below the declared replica count
      maxSurge: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/component: api
    spec:
      priorityClassName: business-critical
      terminationGracePeriodSeconds: 60
      # Zone spreading: no zone may hold more than one pod above the minimum.
      # DoNotSchedule makes this a hard constraint - a pod stays Pending rather
      # than concentrating the fleet in a single zone. That Pending pod is also
      # the signal that drives the Cluster Autoscaler.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
        # Node spreading is best-effort: preferring node diversity is valuable,
        # but blocking a schedule on it would trade availability for tidiness.
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      containers:
        - name: api
          image: ghcr.io/example/checkout-api:1.14.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          # Requests are NOT a suggestion: they are the scheduler's input and
          # therefore the Cluster Autoscaler's trigger. Omit them and node
          # autoscaling silently never fires.
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              memory: "512Mi"        # no CPU limit: avoids CFS throttling
          startupProbe:
            httpGet: { path: /healthz/startup, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6      # deliberately slacker than readiness:
                                     # withdraw traffic before killing a process
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]  # drain endpoints first
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop: ["ALL"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: payments
spec:
  # Bounds VOLUNTARY disruption only: node drains, cluster upgrades, autoscaler
  # consolidation. It does not protect against a zone failure - nothing does
  # except having replicas in the other zones.
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 6          # >= 3 so every zone keeps a replica after scale-in
  maxReplicas: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0      # react immediately to load
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 4
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300    # asymmetric, same reasoning as VMSS
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
      selectPolicy: Min
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: payments
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz/ready
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

### 6.4 Terraform — zone-redundant storage with the reliability knobs set

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_storage_account" "app_data" {
  name                     = "stappdataprodeus01"
  resource_group_name      = azurerm_resource_group.prod.name
  location                 = azurerm_resource_group.prod.location
  account_tier             = "Standard"

  # GZRS: three synchronous copies across availability zones in the primary
  # region, plus asynchronous replication to the paired region.
  # Zone loss  -> transparent, RPO = 0.
  # Region loss -> customer-managed failover, RPO = replication lag (non-zero).
  account_replication_type = "GZRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false   # force Entra ID auth

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
    # Point-in-time restore requires versioning + change feed + soft delete.
    # This is the RPO control for logical corruption, which geo-replication
    # does NOT protect against: replication faithfully copies your mistakes.
    restore_policy {
      days = 29
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = {
    env        = "prod"
    owner      = "platform-sre"
    costcenter = "CC-4417"
    rpo        = "15m"
    rto        = "60m"
  }
}
```

> **Note the distinction encoded above:** GZRS defends against *infrastructure* failure. Versioning, soft delete, and point-in-time restore defend against *logical* failure — a bad deploy, a bad migration, ransomware. Replication is not backup: it copies the deletion at the same speed it copies the data.

---

## 7. CLI and expected terminal output

### 7.1 Establish context and confirm zone availability

```bash
$ az login --use-device-code
To sign in, use a web browser to open the page https://microsoft.com/devicelogin
and enter the code F7QK3M9RD to authenticate.

$ az account set --subscription "sub-platform-prod"
$ az account show --output table
EnvironmentName    IsDefault    Name                 State    TenantId
-----------------  -----------  -------------------  -------  ------------------------------------
AzureCloud         True         sub-platform-prod    Enabled  9c5f2a71-4d0e-4b3c-8a6f-1e2d3c4b5a60
```

Not every region has availability zones, and this determines whether a 99.99% SLA is even reachable:

```bash
$ az account list-locations \
    --query "[?metadata.regionType=='Physical'].{Region:name, Geo:metadata.geographyGroup, Paired:metadata.pairedRegion[0].name}" \
    --output table | head -12
Region              Geo             Paired
------------------  --------------  ------------------
eastus              US              westus
eastus2             US              centralus
westus2             US              westcentralus
westus3             US              eastus
northeurope         Europe          westeurope
westeurope          Europe          northeurope
uksouth             Europe          ukwest
brazilsouth         South America   southcentralus
```

### 7.2 Resolve the logical→physical zone mapping (the per-subscription shuffle)

```bash
$ SUB=$(az account show --query id -o tsv)
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
    --query "value[?name=='eastus'].availabilityZoneMappings[]" \
    --output table
LogicalZone    PhysicalZone
-------------  --------------
1              eastus-az3
2              eastus-az1
3              eastus-az2
```

**Read that output.** Logical zone 1 in this subscription is physical zone `eastus-az3`. A different subscription will produce a different permutation. If an Azure Service Health advisory names a physical zone, this command is how you determine whether it is *your* zone 1.

### 7.3 Verify the SKU exists in all three zones *before* deploying

```bash
$ az vm list-skus \
    --location eastus \
    --size Standard_D2as_v5 \
    --resource-type virtualMachines \
    --query "[].{Name:name, Zones:locationInfo[0].zones, Restrictions:restrictions[].reasonCode}" \
    --output table
Name              Zones      Restrictions
----------------  ---------  --------------
Standard_D2as_v5  ['1','2','3']
```

An empty `Zones` column, or a `Restrictions` value of `NotAvailableForSubscription`, means the deployment will fail at the zone you cannot see. Check this first — it is a 200 ms query that prevents a 20-minute failed deployment.

### 7.4 Check quota before autoscale needs it

```bash
$ az vm list-usage --location eastus \
    --query "[?contains(localName, 'DAv5') || contains(localName,'Total Regional')].{Name:localName, Used:currentValue, Limit:limit}" \
    --output table
Name                                  Used    Limit
------------------------------------  ------  -------
Total Regional vCPUs                  38      50
Standard DAv5 Family vCPUs            24      32
```

With `maxCapacity: 12` at `Standard_D2as_v5` (2 vCPU each), a full scale-out needs 24 vCPUs in the DAv5 family. Currently 24 of 32 are used. **The fleet will hit the quota wall at instance 4 of the scale-out and autoscale will log a failure, not raise an alert.** Raise quota ahead of the load event, not during it.

### 7.5 Deploy and verify zone distribution

```bash
$ az deployment group create \
    --resource-group rg-hawt-prod-eus \
    --name hawt-$(git rev-parse --short HEAD) \
    --template-file ha-webtier.bicep \
    --parameters namePrefix=hawt sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)" \
    --query "properties.{state:provisioningState, duration:duration, ip:outputs.publicIp.value}" \
    --output json
{
  "state": "Succeeded",
  "duration": "PT4M11.8836142S",
  "ip": "20.119.44.86"
}
```

The verification that matters is not "did it deploy" but "is it actually spread":

```bash
$ az vm list \
    --resource-group rg-hawt-prod-eus \
    --show-details \
    --query "[].{Name:name, Zone:zones[0], PowerState:powerState, PrivateIP:privateIps}" \
    --output table
Name           Zone    PowerState      PrivateIP
-------------  ------  --------------  -----------
hawt-vmss_0    1       VM running      10.42.1.4
hawt-vmss_1    2       VM running      10.42.1.5
hawt-vmss_2    3       VM running      10.42.1.6
```

One instance per zone. **This is the command that proves the 99.99% topology.** If all three report the same zone, you have paid for zone redundancy and received none.

### 7.6 Verify health and load balancer state

```bash
$ az vmss get-instance-view \
    --resource-group rg-hawt-prod-eus \
    --name hawt-vmss \
    --query "{repairs:orchestrationServices[0].serviceState, service:orchestrationServices[0].serviceName}" \
    --output table
Repairs    Service
---------  -----------------------
Running    AutomaticRepairs
```

```bash
$ for i in $(seq 1 6); do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://20.119.44.86/healthz; done
200 0.041s
200 0.038s
200 0.044s
200 0.037s
200 0.039s
200 0.043s
```

### 7.7 Confirm the autoscale rule is armed

```bash
$ az monitor autoscale show \
    --resource-group rg-hawt-prod-eus \
    --name hawt-autoscale \
    --query "{enabled:enabled, min:profiles[0].capacity.minimum, max:profiles[0].capacity.maximum, rules:profiles[0].rules[].{metric:metricTrigger.metricName, op:metricTrigger.operator, th:metricTrigger.threshold, dir:scaleAction.direction, cool:scaleAction.cooldown}}" \
    --output json
{
  "enabled": true,
  "max": "12",
  "min": "3",
  "rules": [
    {
      "cool": "0:05:00",
      "dir": "Increase",
      "metric": "Percentage CPU",
      "op": "GreaterThan",
      "th": 70.0
    },
    {
      "cool": "0:10:00",
      "dir": "Decrease",
      "metric": "Percentage CPU",
      "op": "LessThan",
      "th": 30.0
    }
  ]
}
```

### 7.8 Kubernetes-side zone verification

```bash
$ kubectl get nodes -L topology.kubernetes.io/zone,agentpool
NAME                              STATUS   ROLES   AGE   VERSION   ZONE          AGENTPOOL
aks-workload-14882730-vmss000000  Ready    agent   9d    v1.31.4   eastus-1      workload
aks-workload-14882730-vmss000001  Ready    agent   9d    v1.31.4   eastus-2      workload
aks-workload-14882730-vmss000002  Ready    agent   9d    v1.31.4   eastus-3      workload
aks-workload-14882730-vmss000003  Ready    agent   2d    v1.31.4   eastus-1      workload
aks-workload-14882730-vmss000004  Ready    agent   2d    v1.31.4   eastus-2      workload
aks-workload-14882730-vmss000005  Ready    agent   2d    v1.31.4   eastus-3      workload
```

```bash
$ kubectl -n payments get pods -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' --no-headers \
| while read n node s; do
    z=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
    printf '%-34s %-12s %s\n' "$n" "$z" "$s"
  done | sort -k2
checkout-api-7d9c5f8b64-2xkqp      eastus-1     Running
checkout-api-7d9c5f8b64-mv7rt      eastus-1     Running
checkout-api-7d9c5f8b64-9wz4l      eastus-2     Running
checkout-api-7d9c5f8b64-hq8dn      eastus-2     Running
checkout-api-7d9c5f8b64-4jf6s      eastus-3     Running
checkout-api-7d9c5f8b64-pk3vc      eastus-3     Running
```

Two pods per zone, six total, `minAvailable: 4`. Losing an entire zone leaves 4 pods — exactly the PDB floor. That is the design working.

### 7.9 Governance and cost verification

```bash
$ az policy state summarize \
    --management-group mg-corp-production \
    --query "value[0].results.{NonCompliant:nonCompliantResources, Policies:nonCompliantPolicies}" \
    --output table
NonCompliant    Policies
--------------  ----------
7               2
```

```bash
$ az graph query -q "
Resources
| where type =~ 'microsoft.storage/storageAccounts'
| where tags['env'] =~ 'prod'
| where sku.name !in ('Standard_ZRS','Standard_GZRS','Standard_RAGZRS','Premium_ZRS')
| project name, resourceGroup, location, sku=sku.name
| order by resourceGroup asc
" --output table
Name                  ResourceGroup        Location   Sku
--------------------  -------------------  ---------  -------------
stlegacyexports01     rg-data-prod-eus     eastus     Standard_LRS
stmediacache02        rg-web-prod-eus      eastus     Standard_LRS
```

Two production storage accounts are single-datacenter. Neither would survive a zone loss. This query — free, instant, estate-wide — is the manageability benefit made concrete: on-prem, the equivalent answer requires an audit.

```bash
$ az consumption usage list \
    --start-date 2026-08-01 --end-date 2026-08-31 \
    --query "[?contains(instanceName,'hawt')].{Date:usageStart, Meter:meterDetails.meterName, Qty:usageQuantity, Cost:pretaxCost}" \
    --output table | head -6
Date                 Meter                  Qty        Cost
-------------------  ---------------------  ---------  --------
2026-08-01T00:00:00  D2as v5 Vcpu Duration  72.000000  6.912000
2026-08-02T00:00:00  D2as v5 Vcpu Duration  96.000000  9.216000
2026-08-03T00:00:00  D2as v5 Vcpu Duration  72.000000  6.912000
2026-08-04T00:00:00  D2as v5 Vcpu Duration  144.00000  13.82400
2026-08-05T00:00:00  D2as v5 Vcpu Duration  72.000000  6.912000
```

Notice 2026-08-04: quantity doubled. That is autoscale responding to a load event, and it is visible as a line item. **Elasticity that you cannot see in the bill is not elasticity — it is an assumption.**

---

## 8. Verification and failure diagnosis

### 8.1 Diagnostic runbook

| Symptom | First command | Most likely cause | Fix |
|---|---|---|---|
| Deployment succeeded but all instances in one zone | `az vm list -d --query "[].zones"` | `zones` omitted on the VMSS, or region has no AZ support | Add `zones: ['1','2','3']`; verify region with `az account list-locations` |
| `SkuNotAvailable` on deploy | `az vm list-skus -l <r> --size <sku> --query "[].restrictions"` | SKU absent or restricted in the target zone / subscription | Change SKU or zone set; request capacity via support |
| Autoscale never scales out | `AutoscaleEvaluationsLog` KQL (§8.2) | Wrong metric, window too long, already at `maximum`, or quota | Fix rule; `az vm list-usage` for quota |
| Scale-out attempted and failed | `AutoscaleScaleActionsLog` + Activity Log | Regional vCPU / family quota exhausted | Raise quota **before** the event; add a second family |
| Fleet oscillates every 10 min | Compare thresholds in `az monitor autoscale show` | Thresholds too close; symmetric cooldowns | Widen the gap (≥ 30 points); lengthen the scale-in cooldown |
| Instances `Running` but LB returns 502 | `az network lb probe show`, then `curl` the probe path on a private IP | Probe path returns non-200, or NSG blocks `AzureLoadBalancer` tag | Fix probe path; add the NSG rule from §6.1 |
| Instances repaired in a loop | `az vmss get-instance-view` + health extension config | `gracePeriod` shorter than boot+warm-up time | Increase `gracePeriod`; add a `startupProbe`-equivalent delay |
| Pods `Pending`, node count flat | `kubectl describe pod` → Events | No resource `requests` (autoscaler blind), or zone constraint unsatisfiable | Add `requests`; verify a node pool exists in every zone |
| Intermittent outbound connection failures at high load | LB metric `SNAT Connection Count` / `Allocated SNAT Ports` | SNAT port exhaustion | Explicit outbound rule with pinned `allocatedOutboundPorts`, or NAT Gateway |
| Storage reads fail during a regional event | `az storage account show --query "statusOfPrimary"` | Primary region impaired | Read from `-secondary` endpoint (requires RA-GRS/RA-GZRS) |
| Unexplained cost jump | `az costmanagement query` grouped by ResourceId | Scale-in never fired; orphaned disks; egress | Verify scale-in rule; `az disk list --query "[?diskState=='Unattached']"` |
| "Is this outage ours or Azure's?" | Resource Health API (§8.3) | — | `Unavailable` + `PlatformInitiated` = Azure; else it is yours |

### 8.2 KQL: prove what autoscale decided, including the non-decisions

```kusto
// Every autoscale evaluation in the last 24 h, including "no action".
// This is the table that answers "autoscale is enabled but nothing happened".
AutoscaleEvaluationsLog
| where TimeGenerated > ago(24h)
| where ResourceId has "hawt-vmss"
| project TimeGenerated,
          MetricName = Metric,
          Observed   = ObservedValue,
          Threshold,
          Operator,
          Direction  = ScaleDirection,
          Fired      = EvaluationResult,
          Reason     = ProfileEvaluationReason
| order by TimeGenerated desc
| take 100
```

```kusto
// Attempted scale actions and their outcomes. A "Failed" row here with a
// quota message is the single most common cause of a capacity incident.
AutoscaleScaleActionsLog
| where TimeGenerated > ago(7d)
| project TimeGenerated, ResourceId, ScaleDirection,
          OldCapacity = OldInstancesCount,
          NewCapacity = NewInstancesCount,
          ResultType, ResultDescription
| where ResultType != "Succeeded"
| order by TimeGenerated desc
```

```kusto
// Zone balance over time: did the fleet drift into a single zone after a
// repair cycle? Flexible orchestration does not automatically rebalance.
Heartbeat
| where TimeGenerated > ago(1h)
| where Computer startswith "hawt"
| summarize arg_max(TimeGenerated, *) by Computer
| extend Zone = tostring(split(ResourceId, "/")[-1])
| summarize Instances = count() by Computer
```

```kusto
// Platform-initiated maintenance and health transitions - the audit trail you
// need when claiming an SLA credit.
AzureActivity
| where TimeGenerated > ago(30d)
| where CategoryValue in ("ResourceHealth", "ServiceHealth")
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          Level, Properties
| order by TimeGenerated desc
```

### 8.3 Attribute the outage: Resource Health

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-hawt-prod-eus/providers/Microsoft.Compute/virtualMachines/hawt-vmss_1/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01" \
    --query "properties.{status:availabilityState, reason:reasonType, summary:summary, since:occuredTime}" \
    --output json
{
  "reason": "Unplanned",
  "since": "2026-09-03T02:14:07.000Z",
  "status": "Unavailable",
  "summary": "We're sorry, your virtual machine isn't available because of an unexpected host failure. Azure has begun auto-recovery and the VM will be available shortly."
}
```

**This is the field that settles the argument.** `availabilityState: Unavailable` with `reasonType: Unplanned` is a platform-side failure — it counts against Azure's SLA and is the evidence for a service credit claim. `reasonType: UserInitiated` means someone on your team deallocated it, and no credit applies. Query Resource Health *before* writing the incident report, not after.

### 8.4 Validate the design, not just the deployment

The checks that actually confirm the benefits are realized:

```bash
# 1. Zone distribution is real (not just requested)
$ az vm list -g rg-hawt-prod-eus -d --query "[].zones[0]" -o tsv | sort | uniq -c
      1 1
      1 2
      1 3

# 2. Automatic repair is armed
$ az vmss get-instance-view -g rg-hawt-prod-eus -n hawt-vmss \
    --query "orchestrationServices[?serviceName=='AutomaticRepairs'].serviceState" -o tsv
Running

# 3. Autoscale ceiling fits inside quota (the check nobody runs)
$ MAX=$(az monitor autoscale show -g rg-hawt-prod-eus -n hawt-autoscale \
        --query "profiles[0].capacity.maximum" -o tsv)
$ echo "max instances: $MAX -> needs $((MAX * 2)) vCPU in the DAv5 family"
max instances: 12 -> needs 24 vCPU in the DAv5 family

# 4. Every production resource is tagged for cost allocation and ownership
$ az graph query -q "Resources | where isnull(tags['owner']) | summarize count() by type" -o table
Count_    Type
--------  ----------------------------------------
0

# 5. Governance is enforcing, not merely assigned
$ az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/mg-corp-production" \
    --query "[].{name:displayName, mode:enforcementMode}" -o table
Name                                     Mode
---------------------------------------  ---------
Enforce ZRS on production storage         Default
Require owner and costcenter tags         Default
```

A `DoNotEnforce` enforcement mode in check 5 means the policy evaluates and reports but **does not deny**. It is the governance equivalent of a disabled alarm, and it is the most common reason a "compliant" estate is not.

---

## 9. Exam mapping and the distinctions that get tested

| Exam wording | The precise answer | The distractor it is tested against |
|---|---|---|
| Benefit of **high availability** | Deploying across availability zones so a datacenter failure does not take the service down | Confusing it with scalability, or with disaster recovery |
| Benefit of **scalability** | Adding resources to meet demand; vertical = bigger, horizontal = more | Confusing scalability (capability) with elasticity (automatic, bidirectional) |
| Benefit of **elasticity** | Automatic scale **out and in** as demand changes, with matching billing | "Elasticity" used as a synonym for scalability |
| Benefit of **agility** | Rapid provisioning — deploy in minutes, not procurement weeks | Confusing with elasticity |
| Benefit of **reliability** | Distributed design that keeps working through failure and recovers | Confusing with availability (a point-in-time property) |
| Benefit of **predictability** | Both performance (autoscale, WAF pillars) **and** cost (consumption billing, budgets, TCO calculator) | Answering only the cost half |
| Benefit of **security** | Choice of control level (IaaS = most control) plus inherited platform compliance | Believing SaaS means you have no security responsibility |
| Benefit of **governance** | Templates, Policy, RBAC, and compliance auditing keep the estate consistent and standard-conformant | Confusing Policy (what a resource may be) with RBAC (who may act) |
| Benefit of **manageability** | Management **of** the cloud (autoscale, self-healing, templates) vs management **in** the cloud (portal, CLI, PowerShell, API) | Mixing the two lists |
| **Availability zone** | Physically separate location *within* a region; independent power/cooling/network | Confusing with a region, or with a fault domain |
| **Region pair** | Second region in the same geography for geo-replication and staged updates | Assuming every region has one, or that pairing is user-selectable |
| **CapEx vs OpEx** | CapEx = upfront capital, depreciated; OpEx = consumption cost in the period incurred | Believing cloud is always cheaper — it is more *flexible*, not automatically less expensive |

**The single highest-yield conceptual point:** the cloud gives you *access* to high availability, scalability, reliability, security, governance, and manageability. Every one of them is a deliberate architectural choice you must make and then verify with a command. A default deployment — one VM, one zone, LRS storage, no policy, no tags — has none of these benefits while running on infrastructure fully capable of all of them.

---

## References

- AZ-900 Microsoft Azure Fundamentals — official study guide: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Azure Fundamentals certification page: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/
- Benefits of high availability and scalability in the cloud (Learn module): https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/
- Azure regions, availability zones, and region pairs: https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Azure availability zones — region support: https://learn.microsoft.com/en-us/azure/reliability/availability-zones-region-support
- Azure region pairs and non-paired regions: https://learn.microsoft.com/en-us/azure/reliability/regions-paired
- Availability sets, fault domains, and update domains: https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Service Level Agreements (SLA) for Microsoft Online Services: https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Azure SLA portal: https://azure.microsoft.com/en-us/support/legal/sla/
- Azure Well-Architected Framework — Reliability pillar: https://learn.microsoft.com/en-us/azure/well-architected/reliability/
- Recommendations for defining reliability targets (RTO/RPO): https://learn.microsoft.com/en-us/azure/well-architected/reliability/metrics
- Azure Storage redundancy (LRS/ZRS/GRS/GZRS): https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy
- Storage account disaster recovery and failover: https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance
- Virtual Machine Scale Sets — orchestration modes: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes
- Automatic instance repairs for scale sets: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-automatic-instance-repairs
- Application Health extension: https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-health-extension
- Azure Monitor autoscale overview: https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-overview
- Troubleshooting Azure autoscale: https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-troubleshoot
- Best practices for Azure Monitor autoscale: https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-best-practices
- Azure Load Balancer — Standard SKU and availability zones: https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-standard-availability-zones
- Load Balancer outbound rules and SNAT: https://learn.microsoft.com/en-us/azure/load-balancer/outbound-rules
- Azure Front Door overview: https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview
- Traffic Manager routing methods: https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-routing-methods
- Shared responsibility in the cloud: https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
- Zero Trust guidance center: https://learn.microsoft.com/en-us/security/zero-trust/
- Azure Policy overview: https://learn.microsoft.com/en-us/azure/governance/policy/overview
- Azure Policy definition structure and effects: https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-basics
- Azure RBAC overview: https://learn.microsoft.com/en-us/azure/role-based-access-control/overview
- Lock resources to prevent unexpected changes: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Azure Deployment Stacks (Azure Blueprints successor): https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- Azure Blueprints deprecation notice: https://learn.microsoft.com/en-us/azure/governance/blueprints/overview
- Azure Resource Graph query language: https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview
- Bicep documentation: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
- Azure Resource Health overview: https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview
- Azure Service Health: https://learn.microsoft.com/en-us/azure/service-health/service-health-overview
- Azure Reservations: https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations
- Azure savings plan for compute: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview
- Azure Spot Virtual Machines: https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms
- Azure Hybrid Benefit: https://learn.microsoft.com/en-us/azure/cost-management-billing/scope-level/
- Microsoft Cost Management and Billing: https://learn.microsoft.com/en-us/azure/cost-management-billing/
- Azure compliance offerings: https://learn.microsoft.com/en-us/azure/compliance/
- Microsoft Defender for Cloud: https://learn.microsoft.com/en-us/azure/defender-for-cloud/defender-for-cloud-introduction
- Azure Key Vault basic concepts: https://learn.microsoft.com/en-us/azure/key-vault/general/basic-concepts
- Managed identities for Azure resources: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview
- Azure DDoS Protection overview: https://learn.microsoft.com/en-us/azure/ddos-protection/ddos-protection-overview
- AKS availability zones: https://learn.microsoft.com/en-us/azure/aks/availability-zones-overview
- AKS cluster autoscaler: https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler-overview
- KEDA on AKS: https://learn.microsoft.com/en-us/azure/aks/keda-about
- Kubernetes pod topology spread constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Kubernetes Horizontal Pod Autoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Azure CLI reference: https://learn.microsoft.com/en-us/cli/azure/reference-index