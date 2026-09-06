# 1.1 — Describe cloud computing

**Certification:** AZ-900 (Microsoft Azure Fundamentals), exam version 2026-07-20
**Domain:** Describe cloud concepts (25–30% of the exam) · **Topic weight: 9.4**
**Audience profile:** Platform Architect / SRE. This module treats the fundamentals as *operational contracts*, not vocabulary.

---

## 1. The production problem this topic actually solves

Fundamentals material usually opens with "cloud computing is renting someone else's computers." That framing is useless the first time you are on call. Here is the framing that survives a postmortem.

Consider a real platform incident shape. You run a payments API. It is a three-tier system: Azure Front Door → App Service (Linux, P1v3, 3 instances) → Azure SQL Database (Business Critical). At 02:14 UTC, error rate goes to 100% in one region. You page. You find:

1. The **data plane** is fine — the App Service instances are healthy, SQL is accepting connections.
2. The **control plane** is degraded — your autoscale rules cannot add instances, your Terraform pipeline is returning HTTP 429, and the portal blade spins forever.
3. Your **incident bridge** asks: "Is this ours or Microsoft's?"

That last question is the entire content of this topic. Answering it correctly, at 02:14, under load, requires you to have internalised four things long before the page:

| Question at 02:14 | The fundamental concept that answers it |
|---|---|
| "Whose fault is this layer?" | **Shared responsibility model** |
| "Can I fail over to on-prem / another region / another provider?" | **Cloud deployment models** (public / private / hybrid / multicloud) |
| "The mitigation is to scale out 10×. What does that cost, and who approves it?" | **Consumption-based model** |
| "Should this tier have been serverless so it self-heals?" | **Serverless** and its scaling mechanics |

A second, quieter production problem sits underneath: **risk does not transfer with responsibility.** When Microsoft takes over patching the hypervisor, they take the *operational task*. Your customers still page *you* when it fails, and your error budget still burns. The shared responsibility model is a contract boundary, not a risk boundary. Engineers who confuse the two build platforms with no compensating controls at the layers they "don't own."

Everything below is built to make those four answers mechanical.

---

## 2. What "cloud computing" is, formally

### 2.1 The definition the exam wants

> **Cloud computing is the delivery of computing services over the internet — including compute, storage, databases, networking, software, analytics and intelligence — on a pay-as-you-go basis.**

That is the AZ-900 answer. Memorise it. Now here is the definition an architect uses.

### 2.2 NIST SP 800-145 — the five essential characteristics, mapped to Azure primitives

Microsoft's definition is a marketing simplification of NIST SP 800-145, which is still the load-bearing standard. A service is *cloud* only if it has **all five**:

| NIST characteristic | What it means mechanically | Azure implementation | How you prove it (§10) |
|---|---|---|---|
| **On-demand self-service** | A consumer can provision capacity unilaterally, without human interaction with the provider | Azure Resource Manager (ARM) REST API at `management.azure.com`; no ticket, no Microsoft employee in the path | `az group create` completes in seconds |
| **Broad network access** | Capabilities available over the network via standard mechanisms | HTTPS/TLS control plane; data planes on standard protocols; Private Link for private data planes | `curl` the ARM endpoint from anywhere |
| **Resource pooling** | Multi-tenant model; physical/virtual resources dynamically assigned; consumer has no control or knowledge of exact location beyond a coarse abstraction | Azure Hypervisor over pooled hosts; you pick a **region** and optionally an **availability zone**, never a rack | `az vm list-skus` shows capacity by region/zone, never by host |
| **Rapid elasticity** | Capabilities can be elastically provisioned and released, often automatically, appearing unlimited | VMSS autoscale, App Service autoscale, Functions scale controller, KEDA in Container Apps/AKS | Scale-out event visible in Activity Log |
| **Measured service** | Resource use is monitored, controlled and reported, providing transparency for both parties | Usage meters → `Microsoft.Consumption` / `Microsoft.CostManagement` | `az consumption usage list` |

**Architect's note.** "Appearing unlimited" is the characteristic that fails first in production. Elasticity is bounded by *regional capacity*, *subscription quota* and *control-plane throughput*. A capacity error (`AllocationFailed`, `ZonalAllocationFailed`) is a real failure mode, especially for large SKUs, GPU SKUs and Spot. Elasticity is a *statistical* promise, not a guarantee — design for allocation failure the same way you design for disk failure.

### 2.3 The internal architecture: control plane vs data plane

This is the single most useful mental model in Azure, and it is invisible in most fundamentals material.

```
                       ┌──────────────────────────────────────────────┐
   az / Terraform      │        CONTROL PLANE (management.azure.com)  │
   Bicep / Portal ────▶│                                              │
   GitHub Actions      │  1. TLS terminate                            │
                       │  2. AuthN  → Microsoft Entra ID (JWT)        │
                       │  3. AuthZ  → Azure RBAC (roleAssignments)    │
                       │  4. Admission → Azure Policy (deny/modify/   │
                       │                 append/audit)                │
                       │  5. Throttle → token bucket per principal /  │
                       │                region / resource provider    │
                       │  6. Dispatch → Resource Provider (RP)        │
                       │                Microsoft.Compute, .Web, .App │
                       └───────────────────────┬──────────────────────┘
                                               │  asynchronous
                                               ▼
                       ┌──────────────────────────────────────────────┐
                       │        DATA PLANE (per-service endpoints)    │
                       │  <acct>.blob.core.windows.net                │
                       │  <server>.database.windows.net               │
                       │  <app>.azurewebsites.net                     │
                       │  <cluster-fqdn>:443 (Kubernetes API)         │
                       │                                              │
                       │  Own auth (SAS, keys, Entra tokens, mTLS)    │
                       │  Own SLA. Own throttling. Own failure modes. │
                       └──────────────────────────────────────────────┘
```

Consequences you must be able to state:

- **The two planes fail independently.** A full ARM outage does not stop a running VM from serving traffic, and does not stop blob reads. Conversely, a healthy control plane tells you nothing about data-plane health.
- **Every ARM write is idempotent and declarative.** ARM/Bicep templates are *desired state*; re-submitting the same template is safe. This is why `what-if` is meaningful and why partial deployments are resumable.
- **ARM is rate-limited.** ARM returns `x-ms-ratelimit-remaining-subscription-reads` / `-writes` headers and `429 TooManyRequests` with `Retry-After` when the bucket empties. A tight reconciliation loop (a badly written operator, a CI matrix of 200 parallel deployments) will throttle itself out of existence. **Your automation must honour `Retry-After`.**
- **Resource Providers must be registered per subscription** before you can create their resources. A "resource type not found" error on a brand-new subscription is almost always an unregistered RP, not a typo.

---

## 3. The shared responsibility model

### 3.1 The canonical table (the exam answer)

**C = customer always retains · S = shared · M = Microsoft**

| Responsibility layer | On-premises | IaaS | PaaS | SaaS |
|---|:---:|:---:|:---:|:---:|
| Information and data | C | C | C | C |
| Devices (mobile and PCs) | C | C | C | C |
| Accounts and identities | C | C | C | C |
| Identity and directory infrastructure | C | **S** | **S** | **S** |
| Applications | C | C | **S** | M |
| Network controls | C | C | **S** | M |
| Operating system | C | C | M | M |
| Physical hosts | C | M | M | M |
| Physical network | C | M | M | M |
| Physical datacenter | C | M | M | M |

**The three rows that never move, in any model:** *information and data*, *devices*, *accounts and identities*. If an exam item asks "which responsibility is always the customer's regardless of cloud service model?", the answer is one of those three.

The rule you can derive the rest of the table from: **the further right you move (IaaS → PaaS → SaaS), the more Microsoft absorbs, starting from the bottom of the stack and moving up.**

### 3.2 What "Microsoft manages the host" actually means

Fundamentals content states it and stops. As an SRE you need the mechanics, because they leak into your availability numbers.

**Host maintenance.** Microsoft patches the host OS and hypervisor continuously. Most updates use **memory-preserving maintenance** (in-place live migration / VM-preserving update) with a pause of a few seconds — no reboot, no OS-visible event other than a clock jump. Updates that *cannot* be done live are scheduled and surfaced to you in advance; you can self-initiate them in a maintenance window. Rebootless is the common case, not the guaranteed case.

**How you find out.** Azure Instance Metadata Service (IMDS) exposes **Scheduled Events** on the non-routable link-local address `169.254.169.254`. This is the customer's hook into a Microsoft-owned responsibility — the single clearest example that "Microsoft's layer" still requires an action from you.

```bash
$ curl -s -H "Metadata: true" \
    "http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01" | jq .
```
```json
{
  "DocumentIncarnation": 17,
  "Events": [
    {
      "EventId": "c1a4b1f0-9e2b-4c1a-9a1f-2f7c0e9d55aa",
      "EventStatus": "Scheduled",
      "EventType": "Reboot",
      "ResourceType": "VirtualMachine",
      "Resources": [ "web-prod-vmss_7" ],
      "NotBefore": "Fri, 04 Sep 2026 03:41:12 GMT",
      "Description": "Host server is undergoing maintenance.",
      "EventSource": "Platform",
      "DurationInSeconds": 420
    }
  ]
}
```

`EventType` values you must recognise: `Freeze` (brief pause, VM keeps running), `Reboot`, `Redeploy` (moved to a new host, ephemeral disk lost), `Preempt` (**Spot eviction — 30 seconds notice**), `Terminate` (scheduled delete).

The production pattern: a small agent polls this endpoint every ~5–15 s, and on a `Preempt` or `Reboot` it drains the node (cordon+drain in Kubernetes, deregister from the load balancer, checkpoint in-flight work), then **acknowledges** the event to start it immediately rather than waiting out the notice window.

**Fault domains and update domains.** Inside a region, a scale unit is partitioned into **fault domains** (distinct power/network/rack — protects against *unplanned* hardware failure) and **update domains** (batched maintenance groups — protects against *planned* platform updates). An availability set spreads across up to 3 FDs and up to 20 UDs *within one datacenter*. **Availability zones** are the stronger primitive: physically separate datacenters within a region, each with independent power, cooling and networking, connected by high-throughput, low-latency (sub-2 ms round-trip) private fibre. Zones protect against datacenter-level loss; availability sets do not.

### 3.3 SLA is a credit, not a guarantee — and it composes multiplicatively

An SLA is a **financial instrument**: breach it and Microsoft issues a service credit against your bill. It does not restore your revenue and it does not refill your error budget. Treat published SLAs as *inputs to a reliability model*, never as a reliability promise.

| Deployment shape (VM example) | SLA | Max allowed downtime / 30-day month |
|---|---:|---:|
| Single VM, all Premium SSD / Ultra Disk | 99.9% | 43.2 min |
| Two or more VMs in an **availability set** | 99.95% | 21.6 min |
| Two or more VMs across **≥2 availability zones** | 99.99% | 4.32 min |
| Theoretical "five nines" | 99.999% | 26 s |

**Serial composition (dependencies multiply):**

| Chain | Computation | Composite | Downtime / month |
|---|---|---:|---:|
| Front Door (99.99) → App Service (99.95) → SQL (99.99) | 0.9999 × 0.9995 × 0.9999 | **99.93%** | 30.2 min |
| Four independent 99.99% services in series | 0.9999⁴ | **99.96%** | 17.3 min |

**Parallel composition (independent redundancy compounds the *failure* probability):**

| Chain | Computation | Composite | Downtime / month |
|---|---|---:|---:|
| Two independent 99.9% regions, active/active | 1 − (0.001)² | **99.9999%** | 2.6 s |

The two lessons: **every dependency you add lowers your ceiling**, and **the only way to exceed a component's SLA is redundancy across an independent failure domain.** A single-region "highly available" design is capped by the region.

### 3.4 The non-delegable layer: a worked failure

The most common shared-responsibility incident is not exotic. It is: *a public storage account*.

Microsoft is responsible for the durability, encryption-at-rest, physical security and availability of Azure Storage. It is 100% the customer's responsibility to decide whether `allowBlobPublicAccess` is `true`. Every layer Microsoft owns can be perfect and the data still leaks. Detection is free and takes one command:

```bash
$ az storage account list \
    --query "[?allowBlobPublicAccess==\`true\`].{name:name, rg:resourceGroup, tls:minimumTlsVersion}" \
    -o table
```
```
Name                 Rg                Tls
-------------------  ----------------  ----------
stplatlegacyexport   rg-data-prod      TLS1_0
```

Two customer-owned failures in one row. Prevention belongs in the control plane, as admission policy — see §9.4.

---

## 4. Cloud deployment models

### 4.1 Definitions

- **Public cloud** — infrastructure owned and operated by the provider, offered to the general public over the internet. Multi-tenant. No CapEx. You do not own or control the hardware. *Azure public regions.*
- **Private cloud** — cloud infrastructure provisioned for exclusive use by a single organisation. It may be on your premises or hosted by a third party. **A private cloud is still a cloud** — it must have all five NIST characteristics (self-service, pooling, elasticity, metering). A rack of hand-configured VMware hosts with a ticket queue is *not* a private cloud; it is a datacenter. *Azure Local (formerly Azure Stack HCI), Azure Stack Hub.*
- **Hybrid cloud** — a composition of two or more distinct clouds (public + private) that remain unique entities but are bound together by technology enabling data and application portability. *Azure Arc, Azure Local, ExpressRoute, VPN Gateway, Azure Stack Edge.*
- **Multicloud** — using two or more public cloud providers. Note: multicloud is **not** in the classic NIST taxonomy and is not the same as hybrid. Hybrid = public + private. Multicloud = multiple publics.

### 4.2 Trade-off matrix

| Dimension | Public | Private | Hybrid |
|---|---|---|---|
| **Capital model** | Pure OpEx; zero CapEx | CapEx-heavy (hardware, facility, refresh cycle every 3–5 yrs) | Mixed; you carry both cost structures |
| **Elasticity ceiling** | Effectively regional capacity; quota-bounded | Hard-bounded by racks you bought. Bursting requires pre-purchased headroom | Elastic for the public portion, fixed for the private portion ("cloud bursting") |
| **Time to provision** | Seconds to minutes | Weeks to months for new capacity | Seconds in public, months in private |
| **Data residency / sovereignty** | Region-bound; EU Data Boundary; sovereign clouds available | Absolute — data never leaves your building | Per-workload placement decision |
| **Latency to on-prem systems** | WAN (10–80 ms typical); ExpressRoute improves determinism, not physics | LAN (sub-ms) | Placement decision per component |
| **Patching / lifecycle burden** | Microsoft to the hypervisor and below | **You own everything**, including firmware, BIOS, hypervisor, control plane | Two operating models to staff |
| **Regulatory fit** | Strong (broad compliance portfolio) but requires shared-responsibility evidence | Strongest for "must not leave premises" mandates (classified, some healthcare/defence) | Best fit when only *some* data is restricted |
| **Blast radius of a provider outage** | You are exposed to region/service outages | You are your own provider — your outages | Failover target exists but is capacity-limited |
| **Operational complexity** | Lowest | High | **Highest** — two planes, two identity paths, two toolchains |
| **Consistency of tooling** | Native ARM/Bicep/Terraform | Depends on stack | Azure Arc projects on-prem/other-cloud resources **into ARM**, giving one control plane |

### 4.3 Use cases — the decision rule

| Choose | When |
|---|---|
| **Public** | Variable/unpredictable demand; new products with unknown scale; global reach without global datacenters; anything where time-to-market dominates; you want to stop doing undifferentiated infrastructure work. **Default choice.** |
| **Private** | A hard legal/contractual mandate that data must not leave a physical boundary; extreme low-latency coupling to physical plant (factory-floor control loops, trading colocation); a fully depreciated datacenter with years of useful life left and stable, flat demand. |
| **Hybrid** | Migration in flight (the common case — hybrid is usually a *phase*, not a destination); regulated data pinned on-prem while compute/analytics runs in Azure; disaster recovery where Azure is the DR target for on-prem production (**Azure as a DR site is one of the highest-ROI hybrid patterns** — you pay for storage continuously and compute only during a failover or drill); edge sites needing local autonomy with central governance. |
| **Multicloud** | Genuine regulatory demand for provider diversity; acquisition integration; a specific service only one provider offers. **Be honest:** multicloud for "avoiding lock-in" typically converts provider risk into integration complexity, staffing cost and lowest-common-denominator architecture. |

### 4.4 The hybrid technology that matters: Azure Arc

Azure Arc is how the *control plane* becomes hybrid. It projects non-Azure resources into ARM as first-class resource types:

| Arc resource type | ARM type | What you gain |
|---|---|---|
| Servers (any physical/virtual Windows/Linux, anywhere) | `Microsoft.HybridCompute/machines` | Azure Policy, Update Manager, Defender for Cloud, Machine Configuration, Azure Monitor agents, RBAC, tags |
| Kubernetes clusters (any CNCF-conformant cluster) | `Microsoft.Kubernetes/connectedClusters` | GitOps (Flux) config, Policy for Kubernetes (Gatekeeper), Defender, Monitor, cluster connect |
| Data services | `Microsoft.AzureArcData/*` | Managed SQL MI / PostgreSQL on your own hardware |

Once Arc-enabled, an on-prem RHEL box is subject to the *same* RBAC assignment and the *same* Azure Policy definition as an Azure VM. That is the operational payoff: **one governance plane, two (or more) substrates.**

---

## 5. The consumption-based model

### 5.1 CapEx vs OpEx

| | **CapEx** (capital expenditure) | **OpEx** (operational expenditure) |
|---|---|---|
| Cash timing | Large up-front outlay | Continuous, usage-proportional |
| Accounting | Capitalised, depreciated over useful life (typ. 3–5 yrs) | Expensed in the period incurred |
| Approval path | Budget cycle, procurement, board sign-off | Often within an engineering budget |
| Failure cost of a wrong estimate | Stranded hardware; you own it for 5 years | Change it next hour |
| Typical of | On-premises / private cloud | Public cloud |

The architectural consequence is not financial, it is **behavioural**: CapEx forces you to size for peak *years in advance* and eat the idle. OpEx lets you size for *now*. That inversion is why cloud makes experimentation cheap — the cost of a wrong architecture drops from "a purchase order" to "a `terraform destroy`."

The other half of the honesty: OpEx has no natural ceiling. An unbounded autoscale rule plus a retry storm is a *financial* incident. Budgets and quotas are the compensating control (§9.1).

### 5.2 How metering actually works

**Consumption-based ("pay-as-you-go") = you pay only for what you use, when you use it, with no up-front cost and no penalty for stopping.**

The pipeline underneath:

```
Resource emits usage
   │   e.g. VM heartbeat, blob GB-hours, Function GB-seconds, egress GB
   ▼
Meter record  { meterId, meterCategory, meterName, unit, quantity, resourceUri, tags }
   │   aggregated hourly per resource
   ▼
Rating engine — quantity × unit price from your price sheet
   │   price sheet varies by agreement: MCA / EA / CSP / PAYG, and by region
   ▼
Cost records (actual + amortised)
   │
   ├──▶ Microsoft.Consumption      → usage details, budgets, reservation recs
   ├──▶ Microsoft.CostManagement   → query API, exports (incl. FOCUS 1.0), alerts
   └──▶ Invoice (billing account → billing profile → invoice section)
```

Three details that catch engineers out:

1. **Meters are not resources.** One VM emits several meters simultaneously — compute hours, managed disk (provisioned capacity, billed even when the VM is *stopped-deallocated*), disk transactions, public IP, egress bandwidth. "I deallocated the VM so it's free" is wrong: the OS disk and the static public IP keep billing.
2. **"Stopped" ≠ "Stopped (deallocated)."** `Stopped` from inside the guest keeps the compute reservation and keeps billing. Only `az vm deallocate` (portal "Stop") releases it.
3. **Cost data is not real-time.** Usage typically lands in Cost Management within hours, not seconds. Budget alerts are therefore a *detective* control with hours of latency — never your only guard against runaway spend. **Quotas and hard resource limits are the preventive control.**

### 5.3 The billing hierarchy

```
Microsoft Customer Agreement (MCA)              Enterprise Agreement (EA)
  Billing account                                 Billing account (Enrollment)
    └─ Billing profile   (= one invoice, one currency, one PO)
         └─ Invoice section (= cost allocation unit)
              └─ Subscription      ◀── the RBAC + quota + policy boundary
                   └─ Resource group  ◀── lifecycle + deployment boundary
                        └─ Resource   ◀── the thing that emits meters
```

**Design rule:** the *subscription* is your primary blast-radius and quota boundary; the *resource group* is your lifecycle boundary (everything in it should be created and deleted together); the *tag* is your cost-allocation dimension. Get tags wrong and chargeback is unrecoverable after the fact — you cannot retro-tag historical usage records.

---

## 6. Comparing cloud pricing models

### 6.1 The compute pricing matrix

Prices are **illustrative list prices** for a Linux `Standard_D4s_v5` in a US region and exist only to make the arithmetic concrete. **Always verify against the Azure Pricing Calculator and your own price sheet** — regional and agreement pricing differ materially.

| Model | Commitment | Illustrative discount vs PAYG | Capacity guarantee | Flexibility | Best for |
|---|---|---:|---|---|---|
| **Pay-as-you-go** | None | 0% (baseline ≈ $0.192/hr ≈ $140/mo) | None (best-effort allocation) | Total | Unpredictable, spiky, short-lived, dev |
| **Reservation (Reserved Instance)** 1 yr | Up-front or monthly, 1 yr | ~30–40% | No (unless you buy a separate capacity reservation) | Instance-size flexibility within a series; scope changeable; self-service exchange/refund subject to policy and an annual refund cap | Steady baseline you are sure about for a year |
| **Reservation** 3 yr | 3 yr | ~55–65% (≈ $0.073/hr ≈ $53/mo) | No | Same as above, longer lock | Long-lived, immovable baseline |
| **Savings plan for compute** 1/3 yr | Fixed **$/hour** spend, not a specific SKU | ~11–17% (1 yr) / ~28–65% (3 yr), lower than an equivalent RI | No | **Highest** — auto-applies across VM series, regions, App Service, Container Instances, Functions Premium | Steady *spend* with a shifting *shape* |
| **Spot VMs** | None | Up to ~90% | **None — evictable with 30 s notice** | Evicted on capacity pressure or price threshold; `--max-price -1` = pay up to PAYG | Batch, CI runners, rendering, fault-tolerant stateless workers, ML training with checkpoints |
| **Azure Hybrid Benefit** | Existing licences + Software Assurance / subscription | Removes the Windows Server / SQL Server / RHEL / SLES licence component | n/a | Stackable **on top of** reservations and savings plans | Anyone already holding eligible licences |
| **Dev/Test subscription** | EA or MCA benefit | Discounted Windows/SQL rates; no licence charge for eligible non-production use | n/a | **Non-production use only** — enforced by contract | Dev, test, QA, staging |
| **Free tier** | None | 100% within the grant | n/a | $200 credit for 30 days; 12 months of selected services; a set of always-free services with monthly grants | Learning, prototypes |

**Reservations and savings plans stack with Hybrid Benefit; they do not stack with each other on the same resource-hour.** Reservation discount is applied first; savings plan absorbs what the reservation did not cover.

### 6.2 The break-even arithmetic every architect should be able to do on a whiteboard

**Reservation break-even utilisation.** A reservation bills for every hour of the term whether or not you use it. So:

$$
\text{PAYG cost} = P_{payg} \times H \times u
\qquad
\text{RI cost} = P_{ri} \times H
$$

Setting them equal gives the break-even utilisation:

$$
u^{*} = \frac{P_{ri}}{P_{payg}} = 1 - d
$$

where *d* is the reservation discount. With a 62% three-year discount, $u^{*} = 0.38$.

> **Read that carefully: a resource that runs only 38% of the hours in three years still breaks even on a 3-year reservation.** This is why "we only run it during business hours so we won't reserve it" is usually wrong arithmetic — 40 hrs/week is 24% utilisation, which is *below* break-even, but 24/5 (120 hrs/week ≈ 71%) is far above it.

**Spot break-even.** Spot has no SLA, so the calculation is not price but *expected work completed per dollar*:

$$
\text{effective cost} = \frac{P_{spot}}{1 - w}
$$

where *w* is the fraction of work lost to eviction (work done since the last checkpoint). At a 90% discount, Spot stays cheaper than PAYG until you lose **more than 90% of your work** to evictions — which is why the only real requirement is *checkpointing*, not eviction rate.

**Serverless vs always-on break-even.** Consumption-plan Functions bill on **GB-seconds** (observed memory × execution time) plus **executions**. Two rounding rules drive the bill and are commonly missed:

- observed memory is **rounded up to the nearest 128 MB**, minimum 128 MB;
- execution time has a **100 ms minimum**.

Worked example — a 512 MB function averaging 200 ms:

```
GB-s per execution = 0.5 GB × 0.2 s               = 0.1 GB-s
Per 1,000,000 executions:
  compute     = 100,000 GB-s × $0.000016/GB-s     = $1.60
  executions  = 1M × $0.20 per 1M                 = $0.20
  ------------------------------------------------------
  total                                            ≈ $1.80 / million
```

Against an always-warm Premium plan instance at roughly $0.20/hr ≈ **$146/month**, consumption stays cheaper until roughly **80 million executions/month** at that duration profile. The crossover collapses fast as duration grows: at 2 s average duration the same function costs ~$16.20/million and crosses over near 9M executions.

**The corollary:** serverless is cheap for *short, spiky* work and expensive for *long, constant* work. Duration, not request count, is the variable that flips the decision.

### 6.3 Cost factors and levers

| Factor | Mechanism | Lever |
|---|---|---|
| **Compute** | Per-second or per-hour by SKU, OS, region | Right-size; deallocate on schedule; reservations/savings plans; Spot; Hybrid Benefit |
| **Storage** | Provisioned (managed disks — billed on the *provisioned* tier, not consumed bytes) vs consumed (blob GB-month) + transactions | Access tiers (Hot/Cool/Cold/Archive) + lifecycle management policies; delete orphaned disks and snapshots |
| **Networking** | **Ingress is free. Egress to the internet is charged**, with a monthly free grant. Cross-region and cross-zone traffic is charged. Intra-VNet, same-zone is free | Keep chatty tiers co-located; use Private Link/service endpoints; put a CDN in front of static egress |
| **Region** | Prices differ per region for the same SKU | Deploy where latency and residency allow the cheaper region |
| **Licensing** | Windows/SQL/RHEL licence embedded in the meter | Azure Hybrid Benefit; Linux where the workload permits |
| **Support plan** | Basic (free) / Developer / Standard / Professional Direct — % of spend or flat | Match plan to actual response-time requirement |
| **Idle** | Provisioned-but-unused capacity | Scale-to-zero (serverless), auto-shutdown schedules, dev/test lifecycle automation |

---

## 7. Serverless

### 7.1 Definition and the two properties that define it

**Serverless** means the cloud provider fully manages the infrastructure, provisioning and scaling; the customer deploys code or configuration and is billed only for actual execution. There are still servers — you neither see, size, patch nor pay for idle ones.

Two properties are diagnostic. If a service lacks either, it is *managed*, not serverless:

1. **Scale to zero** — when there is no work, there are no billable instances.
2. **Billing granularity equals execution granularity** — you are billed per invocation/second/request-unit, not per provisioned hour.

Azure App Service on a P1v3 plan is *fully managed*, but it costs the same at 0 RPS as at 500 RPS. **It is not serverless.**

### 7.2 The Azure serverless portfolio

| Service | Unit of work | Billing unit | Scales to zero | Max execution | Notes |
|---|---|---|---|---|---|
| **Functions — Consumption** | Function invocation | GB-s + executions | Yes | 5 min default, **10 min hard max** (`functionTimeout` in `host.json`) | Scale-out limit 200 instances (Windows) / 100 (Linux); no VNet integration |
| **Functions — Flex Consumption** | Function invocation | On-demand GB-s + always-ready baseline + executions | Yes (with optional always-ready instances) | 30 min default; can be unbounded | Per-instance concurrency, VNet integration, instance memory 512 / 2048 / 4096 MB, higher instance ceiling |
| **Functions — Premium (EPn)** | Function invocation | Provisioned vCPU-s + GB-s | **No** (min instances ≥ 1) | Unbounded (`-1`) | Pre-warmed instances eliminate cold start; VNet; the "serverless programming model without serverless economics" |
| **Functions — Dedicated (App Service plan)** | Function invocation | App Service plan hours | No | Unbounded | Reuse existing plan capacity |
| **Azure Container Apps (Consumption)** | HTTP request / event | vCPU-s + GiB-s + requests | **Yes** (`minReplicas: 0`) | n/a (long-running OK) | KEDA scalers, Envoy ingress, revisions, Dapr sidecars |
| **Azure Container Instances** | Container group | vCPU-s + GB-s while running | Only by deleting the group | n/a | Simplest burst-container primitive; no orchestration |
| **Logic Apps (Consumption)** | Workflow action | Per action executed | Yes | Long-running with checkpoints | 1,400+ connectors; low-code integration |
| **Cosmos DB serverless** | Database operation | Consumed RUs + storage | Yes | n/a | Single-region write, capped burst (~5,000 RU/s per container), storage cap ~1 TB |
| **Azure SQL Database serverless** | Query | vCore-seconds + storage | Auto-pause (min 60 min idle delay) | n/a | Storage is billed even while paused; resume adds latency to the first query |
| **Event Grid / Service Bus / Event Hubs** | Message | Operations / throughput units | Partly | n/a | The event backbone serverless compute binds to |

### 7.3 Internal mechanics: how a Consumption-plan Function scales

This is the part fundamentals material never covers, and it is exactly where production incidents live.

```
   Event source (queue depth, HTTP RPS, Event Hub lag, Cosmos change feed)
        │
        ▼
   ┌────────────────────────────────────────────────────────────────┐
   │  SCALE CONTROLLER  (a Microsoft-owned component, outside your  │
   │  app — you cannot see it, log into it, or configure it)        │
   │                                                                │
   │  • Polls each trigger's backlog signal on a heuristic per      │
   │    trigger type (queue length, unprocessed events, RPS)        │
   │  • Adds AT MOST 1 instance per second for HTTP triggers        │
   │  • Adds AT MOST 1 instance per 30 seconds for non-HTTP         │
   │  • Ceiling: 200 instances (Windows) / 100 (Linux)              │
   │  • Removes instances after a cooldown; scales to 0 when idle   │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
       Instance N  ── cold start ──▶  worker running
        │  1. Allocate a worker on a shared, multi-tenant pool
        │  2. Mount the app package (run-from-package / blob container)
        │  3. Start the language worker (dotnet-isolated, node, python, java)
        │  4. Load the host, index bindings, JIT / import modules
        │  5. Execute your function
        └─ Steps 1–4 are the COLD START. Steps 3–4 are the part you control.
```

**Cold start is a design constraint, not a bug.** Its magnitude ranges from a few hundred milliseconds to several seconds depending on runtime, package size and dependency graph. What you control:

| Lever | Effect |
|---|---|
| Smaller deployment package; run-from-package | Cuts mount + extract time |
| Trim the dependency graph (the biggest win in Python/Node/Java) | Cuts import/JIT time |
| ReadyToRun / AOT (.NET) | Cuts JIT time |
| Move initialisation out of the handler into module/static scope | Amortises across warm invocations on the same instance |
| **Flex Consumption `alwaysReady`** | Keeps *N* instances warm; you pay a reduced baseline for them |
| **Premium plan pre-warmed instances** | Eliminates cold start; you pay for always-on capacity |

**The scale-rate constraint is the sharper trap.** At 1 new instance per second for HTTP, a load step from 0 to 5,000 RPS cannot be met instantly. If each instance handles ~100 RPS you need ~50 instances, i.e. ~50 seconds of ramp during which the queue grows. For non-HTTP triggers at 1 instance per 30 seconds, that same ramp is **25 minutes**. Design accordingly: pre-warm before known spikes, or use Container Apps/KEDA where you control the polling interval and cooldown.

### 7.4 Serverless trade-offs

| Advantage | The cost that comes with it |
|---|---|
| No infrastructure management | No infrastructure *access* — no SSH, no host metrics, no custom kernel tuning |
| Scale to zero → true consumption billing | **Cold start** on the first request after idle |
| Automatic elasticity | Bounded scale *rate* and a hard instance ceiling |
| Cheap for spiky, low-duty-cycle workloads | Expensive for constant, long-running workloads (§6.2) |
| Fast time to first deploy | Vendor-specific triggers/bindings deepen coupling (mitigate by keeping business logic in a plain, trigger-free module and making the handler a thin adapter) |
| Per-function scaling isolates hot paths | Statelessness is mandatory — no in-memory session, no local disk assumptions; durable state must be externalised (Durable Functions, a store, a queue) |
| Event-driven by construction | Downstream systems must survive the *fan-out*: 200 concurrent instances × a connection each will exhaust a database connection pool. **Connection pooling and downstream rate limiting are non-optional.** |

That last row is the most common production serverless incident: the function tier scales beautifully and murders the database behind it. The mitigation is an explicit concurrency ceiling (host-level `maxConcurrentRequests` / `batchSize`, or a queue with a bounded consumer), not more database capacity.

---

## 8. Complete infrastructure manifests

All manifests below are complete and syntactically valid as shown.

### 8.1 Bicep — consumption-based serverless platform with cost guardrails

`main.bicep`:

```bicep
targetScope = 'resourceGroup'

@description('Base name; all resources derive from this.')
@minLength(3)
@maxLength(11)
param baseName string

@description('Azure region. Must support Flex Consumption.')
param location string = resourceGroup().location

@description('Monthly budget ceiling in the billing currency.')
param monthlyBudget int = 2500

@description('Budget window start, first day of a month, ISO-8601.')
param budgetStartDate string = '2026-09-01'

@description('Budget window end, ISO-8601.')
param budgetEndDate string = '2027-09-01'

@description('Where budget and anomaly alerts are delivered.')
param alertEmails array = [
  'sre-oncall@example.com'
]

@description('Cost-allocation tags applied to every resource.')
param costTags object = {
  'cost-center': 'PLAT-4471'
  owner: 'platform-sre'
  environment: 'prod'
  'data-classification': 'internal'
}

var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('st${baseName}${substring(suffix, 0, 6)}')
var planName = 'plan-${baseName}-flex'
var functionAppName = 'func-${baseName}-${substring(suffix, 0, 4)}'
var workspaceName = 'log-${baseName}'
var insightsName = 'appi-${baseName}'
var deploymentContainer = 'app-package'

// ---------------------------------------------------------------------------
// Observability — required to make "measured service" actionable
// ---------------------------------------------------------------------------

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: costTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: insightsName
  location: location
  tags: costTags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Storage — deployment package container. Identity-based access only:
// no connection strings, no account keys anywhere in configuration.
// ---------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: costTags
  sku: {
    name: 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    encryption: {
      requireInfrastructureEncryption: false
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainer
  properties: {
    publicAccess: 'None'
  }
}

// ---------------------------------------------------------------------------
// Flex Consumption plan (FC1) — scale to zero, per-instance concurrency
// ---------------------------------------------------------------------------

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: costTags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
    size: 'FC'
    family: 'FC'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: costTags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        // Hard ceiling. This is the preventive cost control, and it is also
        // what protects the downstream database from a 1000-way fan-out.
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
        // alwaysReady trades a small fixed cost for zero cold start on the
        // latency-critical HTTP surface. Remove it to be strictly pay-per-use.
        alwaysReady: [
          {
            name: 'http'
            instanceCount: 1
          }
        ]
        triggers: {
          http: {
            perInstanceConcurrency: 16
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.12'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: insights.properties.ConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'Authorization=AAD'
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC — the function's managed identity needs data-plane access to storage.
// Control-plane RBAC (this assignment) and data-plane authorization are
// distinct concerns; this is the bridge between them.
// ---------------------------------------------------------------------------

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource blobOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageBlobDataOwnerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Consumption budget — the detective control on OpEx.
// Forecast alerts fire BEFORE the money is spent; actual alerts fire after.
// Both are needed: forecast catches trends, actual catches step changes.
// ---------------------------------------------------------------------------

resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: '${baseName}-monthly'
  properties: {
    category: 'Cost'
    amount: monthlyBudget
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
      endDate: budgetEndDate
    }
    notifications: {
      Actual_GreaterThan_50: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: alertEmails
        locale: 'en-us'
      }
      Actual_GreaterThan_90: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 90
        thresholdType: 'Actual'
        contactEmails: alertEmails
        locale: 'en-us'
      }
      Forecast_GreaterThan_100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: alertEmails
        locale: 'en-us'
      }
    }
  }
}

output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
output storageAccountName string = storage.name
output appInsightsConnectionString string = insights.properties.ConnectionString
output budgetId string = budget.id
```

`main.bicepparam`:

```bicep
using './main.bicep'

param baseName = 'payments'
param location = 'eastus'
param monthlyBudget = 2500
param budgetStartDate = '2026-09-01'
param budgetEndDate = '2027-09-01'
param alertEmails = [
  'sre-oncall@example.com'
  'finops@example.com'
]
param costTags = {
  'cost-center': 'PLAT-4471'
  owner: 'platform-sre'
  environment: 'prod'
  'data-classification': 'internal'
}
```

### 8.2 Terraform — the same consumption controls, plus reservation-eligible baseline

`main.tf`:

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
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

variable "base_name" {
  description = "Base name for all resources."
  type        = string
  default     = "payments"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "monthly_budget" {
  description = "Monthly budget ceiling."
  type        = number
  default     = 2500
}

variable "cost_tags" {
  description = "Cost-allocation tags applied to every resource."
  type        = map(string)
  default = {
    cost-center         = "PLAT-4471"
    owner               = "platform-sre"
    environment         = "prod"
    data-classification = "internal"
    provisioner         = "terraform"
  }
}

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "platform" {
  name     = "rg-${var.base_name}-prod"
  location = var.location
  tags     = var.cost_tags
}

# ---------------------------------------------------------------------------
# Steady-state baseline: zone-redundant VMSS.
# This is the RESERVATION-ELIGIBLE tier. It runs 24/7, so at any discount
# above ~38% a three-year reservation beats pay-as-you-go (see 6.2).
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "platform" {
  name                = "vnet-${var.base_name}"
  address_space       = ["10.40.0.0/16"]
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.cost_tags
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.platform.name
  address_prefixes     = ["10.40.1.0/24"]
}

resource "azurerm_orchestrated_virtual_machine_scale_set" "baseline" {
  name                        = "vmss-${var.base_name}-baseline"
  location                    = azurerm_resource_group.platform.location
  resource_group_name         = azurerm_resource_group.platform.name
  platform_fault_domain_count = 1

  # Zone redundancy is what lifts the composite SLA from 99.95% to 99.99%.
  zones = ["1", "2", "3"]

  sku_name  = "Standard_D4s_v5"
  instances = 3

  os_profile {
    linux_configuration {
      admin_username                  = "azureuser"
      disable_password_authentication = true
      admin_ssh_key {
        username   = "azureuser"
        public_key = file("~/.ssh/id_ed25519.pub")
      }
    }
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic-baseline"
    primary = true

    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = azurerm_subnet.workload.id
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.cost_tags, {
    pricing-model = "reserved-3yr"
    workload-tier = "baseline"
  })
}

# ---------------------------------------------------------------------------
# Burst tier: Spot. No SLA, evictable with 30 s notice.
# Every workload placed here MUST checkpoint and MUST handle Preempt.
# ---------------------------------------------------------------------------

resource "azurerm_orchestrated_virtual_machine_scale_set" "burst" {
  name                        = "vmss-${var.base_name}-burst"
  location                    = azurerm_resource_group.platform.location
  resource_group_name         = azurerm_resource_group.platform.name
  platform_fault_domain_count = 1
  zones                       = ["1", "2", "3"]

  sku_name  = "Standard_D4s_v5"
  instances = 0

  priority        = "Spot"
  eviction_policy = "Delete"
  max_bid_price   = -1 # -1 = never evicted on price, only on capacity

  os_profile {
    linux_configuration {
      admin_username                  = "azureuser"
      disable_password_authentication = true
      admin_ssh_key {
        username   = "azureuser"
        public_key = file("~/.ssh/id_ed25519.pub")
      }
    }
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic-burst"
    primary = true

    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = azurerm_subnet.workload.id
    }
  }

  tags = merge(var.cost_tags, {
    pricing-model = "spot"
    workload-tier = "burst"
    checkpointing = "required"
  })
}

resource "azurerm_consumption_budget_resource_group" "platform" {
  name              = "${var.base_name}-monthly"
  resource_group_id = azurerm_resource_group.platform.id
  amount            = var.monthly_budget
  time_grain        = "Monthly"

  time_period {
    start_date = "2026-09-01T00:00:00Z"
    end_date   = "2027-09-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = 90
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = ["sre-oncall@example.com"]
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = ["sre-oncall@example.com", "finops@example.com"]
  }
}

output "resource_group" {
  value = azurerm_resource_group.platform.name
}

output "baseline_vmss_id" {
  value = azurerm_orchestrated_virtual_machine_scale_set.baseline.id
}

output "burst_vmss_id" {
  value = azurerm_orchestrated_virtual_machine_scale_set.burst.id
}
```

### 8.3 Azure Container Apps — scale-to-zero serverless containers

`containerapp.yaml` (consumed by `az containerapp create --yaml`):

```yaml
location: eastus
type: Microsoft.App/containerApps
tags:
  cost-center: PLAT-4471
  owner: platform-sre
  environment: prod
  pricing-model: consumption
identity:
  type: SystemAssigned
properties:
  managedEnvironmentId: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-payments-prod/providers/Microsoft.App/managedEnvironments/cae-payments
  workloadProfileName: Consumption
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      targetPort: 8080
      transport: auto
      allowInsecure: false
      clientCertificateMode: ignore
      traffic:
        - latestRevision: true
          weight: 100
    dapr:
      enabled: false
    registries: []
  template:
    revisionSuffix: v1
    containers:
      - name: settlement-worker
        image: mcr.microsoft.com/k8se/quickstart:latest
        resources:
          # Consumption profile: cpu and memory must follow the allowed
          # ratio — memory (GiB) = cpu * 2. 0.5 vCPU -> 1.0Gi.
          cpu: 0.5
          memory: 1.0Gi
        env:
          - name: LOG_LEVEL
            value: info
          - name: MAX_INFLIGHT
            value: "8"
        probes:
          - type: Liveness
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          - type: Readiness
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 3
          - type: Startup
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 20
    scale:
      # minReplicas: 0 is the line that makes this SERVERLESS rather than
      # merely managed. At zero replicas the only charge is storage/registry.
      minReplicas: 0
      maxReplicas: 30
      rules:
        - name: http-concurrency
          http:
            metadata:
              concurrentRequests: "40"
        - name: queue-depth
          custom:
            type: azure-servicebus
            metadata:
              queueName: settlements
              namespace: sb-payments-prod
              messageCount: "20"
            identity: system
```

### 8.4 Azure Policy — enforcing cost allocation at the control plane

Chargeback is impossible without tags, and tags are impossible to backfill onto historical usage records. Enforce at admission time. `policy-require-cost-center.json`:

```json
{
  "properties": {
    "displayName": "Require a cost-center tag on resource groups",
    "policyType": "Custom",
    "mode": "All",
    "description": "Denies creation of a resource group without a cost-center tag. Cost allocation is only possible if the dimension exists at the moment usage is metered; it cannot be applied retroactively.",
    "metadata": {
      "version": "1.0.0",
      "category": "Tags"
    },
    "parameters": {
      "tagName": {
        "type": "String",
        "metadata": {
          "displayName": "Tag name",
          "description": "Name of the tag required on the resource group."
        },
        "defaultValue": "cost-center"
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "equals": "Microsoft.Resources/subscriptions/resourceGroups"
          },
          {
            "field": "[concat('tags[', parameters('tagName'), ']')]",
            "exists": "false"
          }
        ]
      },
      "then": {
        "effect": "deny"
      }
    }
  }
}
```

### 8.5 Hybrid — KEDA scale-to-zero on an Arc-enabled cluster

The same serverless *behaviour* on your own hardware. This is what makes "hybrid" a real architecture rather than a slide.

`keda-scaledobject.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: settlement
  labels:
    cost-center: PLAT-4471
    workload-tier: burst
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: settlement-worker
  namespace: settlement
  labels:
    app: settlement-worker
spec:
  replicas: 0
  selector:
    matchLabels:
      app: settlement-worker
  template:
    metadata:
      labels:
        app: settlement-worker
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: settlement-worker
      terminationGracePeriodSeconds: 60
      containers:
        - name: worker
          image: ghcr.io/example/settlement-worker:1.14.2
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
          env:
            - name: SERVICEBUS_NAMESPACE
              value: sb-payments-prod.servicebus.windows.net
            - name: QUEUE_NAME
              value: settlements
            - name: MAX_INFLIGHT
              value: "8"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "/app/drain.sh && sleep 15"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: settlement-worker
  namespace: settlement
  annotations:
    azure.workload.identity/client-id: 00000000-0000-0000-0000-000000000000
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: servicebus-auth
  namespace: settlement
spec:
  podIdentity:
    provider: azure-workload
    identityId: 00000000-0000-0000-0000-000000000000
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: settlement-worker
  namespace: settlement
spec:
  scaleTargetRef:
    name: settlement-worker
  # Unlike the Functions scale controller, every one of these knobs is yours.
  # This is the concrete trade-off of hybrid serverless: more control,
  # more to operate.
  pollingInterval: 15
  cooldownPeriod: 120
  minReplicaCount: 0
  maxReplicaCount: 30
  fallback:
    failureThreshold: 3
    replicas: 2
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 180
          policies:
            - type: Percent
              value: 50
              periodSeconds: 60
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
            - type: Percent
              value: 100
              periodSeconds: 15
  triggers:
    - type: azure-servicebus
      metadata:
        queueName: settlements
        namespace: sb-payments-prod
        messageCount: "20"
      authenticationRef:
        name: servicebus-auth
```

---

## 9. CLI: provisioning and verification

### 9.1 Establish context and prove self-service

```bash
$ az login --use-device-code
$ az account set --subscription "plat-payments-prod"
$ az account show -o table
```
```
Name                 CloudName    SubscriptionId                        TenantId                              State    IsDefault
-------------------  -----------  ------------------------------------  ------------------------------------  -------  -----------
plat-payments-prod   AzureCloud   1f9c3b62-7a41-4d0e-9b8c-2e5a7d13f004  72f988bf-86f1-41af-91ab-2d7cd011db47  Enabled  True
```

```bash
$ time az group create --name rg-payments-prod --location eastus \
    --tags cost-center=PLAT-4471 owner=platform-sre environment=prod -o table
```
```
Location    Name
----------  ----------------
eastus      rg-payments-prod

real    0m3.412s
user    0m1.088s
sys     0m0.141s
```

Three seconds, no ticket, no human at Microsoft. That is **on-demand self-service**, demonstrated rather than asserted.

### 9.2 Verify resource pooling and elasticity bounds

```bash
$ az account list-locations \
    --query "[?metadata.regionType=='Physical'].{Region:name, Geo:metadata.geographyGroup, Paired:metadata.pairedRegion[0].name}" \
    -o table | head -12
```
```
Region        Geo             Paired
------------  --------------  --------------
eastus        US              westus
eastus2       US              centralus
southcentralus US             northcentralus
westus2       US              westcentralus
westus3       US              eastus
westeurope    Europe          northeurope
northeurope   Europe          westeurope
uksouth       Europe          ukwest
swedencentral Europe          swedensouth
japaneast     Asia Pacific    japanwest
australiaeast Asia Pacific    australiasoutheast
brazilsouth   Latin America   southcentralus
```

Which zones actually have your SKU — the elasticity ceiling made concrete:

```bash
$ az vm list-skus --location eastus --resource-type virtualMachines \
    --query "[?name=='Standard_D4s_v5'].{SKU:name, Zones:locationInfo[0].zones, Restrictions:restrictions[].reasonCode}" \
    -o json
```
```json
[
  {
    "SKU": "Standard_D4s_v5",
    "Zones": [ "1", "2", "3" ],
    "Restrictions": []
  }
]
```

An empty `Restrictions` array means no subscription-level or zone-level capacity restriction is currently applied. `NotAvailableForSubscription` here is the early warning that an `AllocationFailed` is waiting for you at deploy time.

Current quota headroom — the real elasticity ceiling:

```bash
$ az vm list-usage --location eastus \
    --query "[?contains(localName, 'DSv5') || localName=='Total Regional vCPUs'].{Name:localName, Used:currentValue, Limit:limit}" \
    -o table
```
```
Name                          Used    Limit
----------------------------  ------  -------
Total Regional vCPUs          212     350
Standard DSv5 Family vCPUs    136     200
```

### 9.3 Deploy, with a dry run first

`what-if` is the control-plane equivalent of `terraform plan`. Never deploy to production without it.

```bash
$ az deployment group what-if \
    --resource-group rg-payments-prod \
    --template-file main.bicep \
    --parameters main.bicepparam
```
```
Note: The result may contain false positive predictions (noise).

Resource and property changes are indicated with these symbols:
  + Create
  ~ Modify

The deployment will update the following scope:

Scope: /subscriptions/1f9c3b62-.../resourceGroups/rg-payments-prod

  + Microsoft.Consumption/budgets/payments-monthly
  + Microsoft.Insights/components/appi-payments
  + Microsoft.OperationalInsights/workspaces/log-payments
  + Microsoft.Storage/storageAccounts/stpaymentsk3h9x2
  + Microsoft.Storage/storageAccounts/stpaymentsk3h9x2/blobServices/default
  + Microsoft.Storage/storageAccounts/stpaymentsk3h9x2/blobServices/default/containers/app-package
  + Microsoft.Web/serverfarms/plan-payments-flex
  + Microsoft.Web/sites/func-payments-k3h9

Resource changes: 8 to create.
```

```bash
$ az deployment group create \
    --name payments-$(git rev-parse --short HEAD) \
    --resource-group rg-payments-prod \
    --template-file main.bicep \
    --parameters main.bicepparam \
    --query "properties.{state:provisioningState, duration:duration, outputs:outputs}" \
    -o jsonc
```
```jsonc
{
  "state": "Succeeded",
  "duration": "PT2M17.8841203S",
  "outputs": {
    "budgetId": {
      "type": "String",
      "value": "/subscriptions/1f9c3b62-.../resourceGroups/rg-payments-prod/providers/Microsoft.Consumption/budgets/payments-monthly"
    },
    "functionAppHostname": {
      "type": "String",
      "value": "func-payments-k3h9.azurewebsites.net"
    },
    "functionAppName": {
      "type": "String",
      "value": "func-payments-k3h9"
    },
    "functionAppPrincipalId": {
      "type": "String",
      "value": "8b41d7e2-5c93-4a1e-b7f0-3d2a9e64c118"
    },
    "storageAccountName": {
      "type": "String",
      "value": "stpaymentsk3h9x2"
    }
  }
}
```

### 9.4 Apply the cost-allocation policy

```bash
$ az policy definition create \
    --name require-cost-center-tag \
    --display-name "Require a cost-center tag on resource groups" \
    --mode All \
    --rules @<(jq '.properties.policyRule' policy-require-cost-center.json) \
    --params @<(jq '.properties.parameters' policy-require-cost-center.json) \
    --query "{name:name, mode:mode}" -o table
```
```
Name                     Mode
-----------------------  ------
require-cost-center-tag  All
```

```bash
$ az policy assignment create \
    --name enforce-cost-center \
    --display-name "Enforce cost-center tag" \
    --policy require-cost-center-tag \
    --scope "/subscriptions/$(az account show --query id -o tsv)" \
    --query "{name:name, enforcementMode:enforcementMode}" -o table
```
```
Name                 EnforcementMode
-------------------  -----------------
enforce-cost-center  Default
```

Prove the control plane denies, not merely audits:

```bash
$ az group create --name rg-untagged-test --location eastus
```
```
(RequestDisallowedByPolicy) Resource 'rg-untagged-test' was disallowed by policy.
Policy identifiers: '[{"policyAssignment":{"name":"Enforce cost-center tag",
"id":"/subscriptions/1f9c3b62-.../providers/Microsoft.Authorization/policyAssignments/enforce-cost-center"},
"policyDefinition":{"name":"Require a cost-center tag on resource groups",
"id":"/subscriptions/1f9c3b62-.../providers/Microsoft.Authorization/policyDefinitions/require-cost-center-tag"}}]'
Code: RequestDisallowedByPolicy
```

### 9.5 Prove "measured service"

Raw usage records:

```bash
$ az consumption usage list \
    --start-date 2026-09-01 --end-date 2026-09-04 \
    --query "[?contains(instanceName, 'func-payments')].{Date:usageStart, Meter:meterDetails.meterName, Qty:usageQuantity, Unit:meterDetails.unitOfMeasure, Cost:pretaxCost}" \
    -o table
```
```
Date                 Meter                        Qty        Unit             Cost
-------------------  ---------------------------  ---------  ---------------  ---------
2026-09-01T00:00:00  Standard Execution Time      41823.0    10 GB Seconds    0.0669
2026-09-01T00:00:00  Standard Total Executions    2.14       10K              0.0004
2026-09-02T00:00:00  Standard Execution Time      52190.0    10 GB Seconds    0.0835
2026-09-02T00:00:00  Standard Total Executions    2.67       10K              0.0005
2026-09-03T00:00:00  Standard Execution Time      48771.0    10 GB Seconds    0.0780
2026-09-03T00:00:00  Standard Total Executions    2.49       10K              0.0005
```

Aggregated, grouped by service and by your cost-allocation tag. `cost-query.json`:

```json
{
  "type": "ActualCost",
  "timeframe": "MonthToDate",
  "dataset": {
    "granularity": "None",
    "aggregation": {
      "totalCost": { "name": "Cost", "function": "Sum" }
    },
    "grouping": [
      { "type": "Dimension", "name": "ServiceName" },
      { "type": "TagKey", "name": "cost-center" }
    ],
    "filter": {
      "dimensions": {
        "name": "ResourceGroupName",
        "operator": "In",
        "values": [ "rg-payments-prod" ]
      }
    }
  }
}
```

```bash
$ SUB=$(az account show --query id -o tsv)
$ az rest --method post \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
    --headers "Content-Type=application/json" \
    --body @cost-query.json \
    --query "properties.rows" -o json
```
```json
[
  [ 812.4471, "Virtual Machines",             "cost-center", "PLAT-4471", "USD" ],
  [ 194.0233, "Azure SQL Database",           "cost-center", "PLAT-4471", "USD" ],
  [  61.8890, "Storage",                      "cost-center", "PLAT-4471", "USD" ],
  [  22.3104, "Log Analytics",                "cost-center", "PLAT-4471", "USD" ],
  [   9.7712, "Bandwidth",                    "cost-center", "PLAT-4471", "USD" ],
  [   4.9021, "Azure App Service",            "cost-center", "PLAT-4471", "USD" ]
]
```

Reservation recommendations, derived from *your* measured usage rather than a guess:

```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Consumption/reservationRecommendations?api-version=2023-05-01&\$filter=properties/scope eq 'Single' and properties/lookBackPeriod eq 'Last30Days'" \
    --query "value[?properties.term=='P3Y'].{SKU:properties.skuName, Region:location, Qty:properties.recommendedQuantity, NetSavings:properties.netSavings, Term:properties.term}" \
    -o table
```
```
SKU              Region    Qty    NetSavings    Term
---------------  --------  -----  ------------  ------
Standard_D4s_v5  eastus    3      1622.41       P3Y
Standard_E8s_v5  eastus    1      1094.77       P3Y
```

Verify the budget guardrail actually exists:

```bash
$ az consumption budget list --resource-group rg-payments-prod \
    --query "[].{Name:name, Amount:amount, Grain:timeGrain, Current:currentSpend.amount, Forecast:forecastSpend.amount}" \
    -o table
```
```
Name              Amount    Grain      Current    Forecast
----------------  --------  ---------  ---------  ----------
payments-monthly  2500.0    Monthly    1105.34    2711.06
```

The forecast exceeds the budget. The `Forecast_GreaterThan_100` notification will fire — days before the money is spent. That is the whole point of a forecast threshold.

### 9.6 Deploy and exercise the serverless tier

```bash
$ func azure functionapp publish func-payments-k3h9 --python
```
```
Getting site publishing info...
[2026-09-04T11:02:18.441Z] Starting the function app deployment...
Creating archive for current directory...
Performing remote build for functions project.
Uploading 4.31 MB [######################################] 100%
Remote build succeeded!
Syncing triggers...
Functions in func-payments-k3h9:
    settle - [httpTrigger]
        Invoke url: https://func-payments-k3h9.azurewebsites.net/api/settle
    reconcile - [serviceBusTrigger]
```

Prove scale-to-zero, then measure the cold start:

```bash
$ az monitor metrics list \
    --resource "/subscriptions/$SUB/resourceGroups/rg-payments-prod/providers/Microsoft.Web/sites/func-payments-k3h9" \
    --metric FunctionExecutionCount \
    --interval PT1H --start-time 2026-09-04T02:00:00Z --end-time 2026-09-04T06:00:00Z \
    --aggregation Total \
    --query "value[0].timeseries[0].data[].{time:timeStamp, executions:total}" -o table
```
```
Time                        Executions
--------------------------  ------------
2026-09-04T02:00:00+00:00   0.0
2026-09-04T03:00:00+00:00   0.0
2026-09-04T04:00:00+00:00   0.0
2026-09-04T05:00:00+00:00   0.0
```

Four hours, zero executions, zero on-demand compute charge. Compare an App Service P1v3 over the same window: 4 hours × $0.20 = **$0.80 for doing nothing**, every night, forever.

```bash
$ for i in 1 2 3; do
    curl -s -o /dev/null -w "attempt %{http_code}  total=%{time_total}s  ttfb=%{time_starttransfer}s\n" \
      "https://func-payments-k3h9.azurewebsites.net/api/settle?ref=probe-$i"
  done
```
```
attempt 200  total=2.874312s  ttfb=2.861044s     <-- cold start
attempt 200  total=0.081447s  ttfb=0.079902s     <-- warm
attempt 200  total=0.074219s  ttfb=0.072890s     <-- warm
```

A ~2.8 s cold start against ~80 ms warm. **That 35× gap is the price of scale-to-zero**, and it is the number that belongs in your latency SLO discussion — not a footnote.

### 9.7 Deploy and verify the hybrid path

```bash
$ az connectedk8s connect --name onprem-edge-01 \
    --resource-group rg-payments-prod \
    --location eastus \
    --tags cost-center=PLAT-4471 environment=prod
```
```
This operation might take a while...

Step: 11:31:04: Do node validations
Step: 11:31:09: Checking if user can create ClusterRoleBindings
Step: 11:31:12: Determining the location for the connected cluster resource
Step: 11:31:41: Azure resource provisioning has begun.
Step: 11:33:02: Azure resource provisioning has finished.
Step: 11:33:04: Starting to install Azure arc agents on the Kubernetes cluster.
Step: 11:35:47: Azure Arc agents have been installed successfully.
```

```bash
$ az connectedk8s show -n onprem-edge-01 -g rg-payments-prod \
    --query "{name:name, distribution:distribution, agentVersion:agentVersion, connectivityStatus:connectivityStatus, lastConnectivityTime:lastConnectivityTime, totalNodeCount:totalNodeCount}" \
    -o jsonc
```
```jsonc
{
  "agentVersion": "1.19.4",
  "connectivityStatus": "Connected",
  "distribution": "k3s",
  "lastConnectivityTime": "2026-09-04T11:38:22.104000+00:00",
  "name": "onprem-edge-01",
  "totalNodeCount": 5
}
```

The on-prem cluster is now an ARM resource. Confirm one governance plane spans both substrates:

```bash
$ az resource list --resource-group rg-payments-prod \
    --query "[].{Name:name, Type:type, Location:location}" -o table
```
```
Name                  Type                                          Location
--------------------  --------------------------------------------  ----------
vmss-payments-baseline Microsoft.Compute/virtualMachineScaleSets    eastus
func-payments-k3h9    Microsoft.Web/sites                           eastus
stpaymentsk3h9x2      Microsoft.Storage/storageAccounts             eastus
onprem-edge-01        Microsoft.Kubernetes/connectedClusters         eastus
```

The last row is a cluster in your own building, addressable with the same RBAC, the same tags and the same Policy assignments as the rows above it.

---

## 10. Verification and failure diagnosis

### 10.1 The verification ladder

Rung order matters: everything above a rung is worthless if the rung below it is broken.

| # | Question | Command | Cost |
|---|---|---|---|
| 1 | Am I authenticated, in the right tenant and subscription? | `az account show -o table` | free |
| 2 | Is the resource provider registered? | `az provider show -n <NS> --query registrationState -o tsv` | free |
| 3 | Do I have the RBAC to do this? | `az role assignment list --assignee <id> --scope <scope> -o table` | free |
| 4 | Will Policy deny this? | `az deployment group what-if …` | free |
| 5 | Is there quota and zonal capacity? | `az vm list-usage`, `az vm list-skus … locationInfo[0].zones` | free |
| 6 | Did the control plane accept it? | `az deployment operation group list --query "[?properties.provisioningState!='Succeeded']"` | free |
| 7 | Is the data plane actually serving? | `curl`, `nc -vz`, service-specific probe | free |
| 8 | Is it costing what I predicted? | `az consumption usage list`, Cost Management query | free (hours of latency) |
| 9 | Is my composite SLA what I think? | multiply the component SLAs by hand | free |

### 10.2 Failure catalogue

---

**Symptom: `MissingSubscriptionRegistration`**

```
(MissingSubscriptionRegistration) The subscription is not registered to use
namespace 'Microsoft.App'. See https://aka.ms/rps-not-found for how to register
subscriptions.
Code: MissingSubscriptionRegistration
```

**Cause.** Resource providers are opt-in *per subscription*. A fresh or SPN-provisioned subscription has only a default set registered. This is a self-service *provisioning* boundary, and it is the most common "it works in my subscription" failure.

**Diagnosis and fix:**
```bash
$ az provider show -n Microsoft.App --query registrationState -o tsv
NotRegistered

$ az provider register --namespace Microsoft.App --wait
$ az provider show -n Microsoft.App --query registrationState -o tsv
Registered
```

**Prevention.** Register every provider you depend on in the landing-zone bootstrap, before any workload deployment. `az provider list --query "[?registrationState=='Registered'].namespace" -o tsv` gives the baseline to codify.

---

**Symptom: `429 TooManyRequests` from ARM; automation stalls; portal blades hang**

**Cause.** Control-plane throttling. ARM applies a token-bucket limit per principal, per region, per resource provider. A CI matrix, a reconciliation loop with no backoff, or a monitoring script polling every second will drain the bucket.

**Diagnosis:**
```bash
$ az rest --method get \
    --url "https://management.azure.com/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" \
    --debug 2>&1 | grep -i 'x-ms-ratelimit'
```
```
msrest.http_logger:     'x-ms-ratelimit-remaining-subscription-reads': '11842'
msrest.http_logger:     'x-ms-ratelimit-remaining-subscription-global-reads': '3711'
```

A value trending toward zero across successive calls is the leading indicator. When throttled you get:

```
(TooManyRequests) The request is being throttled. Retry after 27 seconds.
Code: TooManyRequests
```

Find the noisy caller in the Activity Log:
```bash
$ az monitor activity-log list --offset 1h \
    --query "[?httpRequest!=null].{caller:caller, op:operationName.value, status:status.value}" \
    -o table | sort | uniq -c | sort -rn | head -5
```
```
   4127 mysvc-ci@example.com  Microsoft.Compute/virtualMachines/read  Succeeded
    118 alice@example.com     Microsoft.Web/sites/read                Succeeded
```

**Fix.** Honour `Retry-After`. Add exponential backoff with jitter. Batch reads with Azure Resource Graph (`az graph query -q "Resources | where type =~ 'microsoft.compute/virtualmachines'"`) instead of per-resource `GET`s — Resource Graph is a separate, far higher-throughput read path built precisely for this.

**Critical incident note.** During ARM throttling, **already-running workloads are unaffected.** Do not declare a customer-facing outage on control-plane symptoms alone. Verify the data plane independently (§10.1 rung 7) before you escalate.

---

**Symptom: `AllocationFailed` / `ZonalAllocationFailed`**

```
(ZonalAllocationFailed) Allocation failed. We do not have sufficient capacity for
the requested VM size in this zone. Read more about improving likelihood of
allocation success at http://aka.ms/allocation-guidance
Code: ZonalAllocationFailed
```

**Cause.** "Rapid elasticity" is statistical. Regional/zonal capacity for a specific SKU family is finite at that moment. Most likely on large SKUs, GPU SKUs, and newly announced series.

**Diagnosis:**
```bash
$ az vm list-skus --location eastus --size Standard_ND96 --all \
    --query "[].{SKU:name, Zone:locationInfo[0].zones, Reason:restrictions[0].reasonCode}" -o table
```
```
SKU                       Zone            Reason
------------------------  --------------  -------------------------------
Standard_ND96asr_v4       ['1', '2']      NotAvailableForSubscription
```

**Fix, in order of preference.** (1) Try a different zone or an adjacent SKU in the same family. (2) Try another region. (3) For workloads that must have guaranteed capacity, buy a **Capacity Reservation** — note that a *reservation* (billing discount) and a *capacity reservation* (guaranteed allocation) are **different products**; buying a Reserved Instance does **not** guarantee capacity. (4) Retry with backoff; capacity is transient.

---

**Symptom: unexplained cost spike; budget forecast breached**

**Diagnosis — narrow by dimension, then by resource:**
```bash
$ cat spike-query.json
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": { "from": "2026-08-25T00:00:00Z", "to": "2026-09-03T23:59:59Z" },
  "dataset": {
    "granularity": "Daily",
    "aggregation": { "totalCost": { "name": "Cost", "function": "Sum" } },
    "grouping": [ { "type": "Dimension", "name": "MeterCategory" } ]
  }
}

$ az rest --method post \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
    --body @spike-query.json --query "properties.rows" -o tsv | sort -k2
```
```
41.2201   20260825  Bandwidth   USD
39.8817   20260826  Bandwidth   USD
40.5514   20260827  Bandwidth   USD
38.9903   20260828  Bandwidth   USD
417.6620  20260829  Bandwidth   USD
502.1188  20260830  Bandwidth   USD
498.7745  20260831  Bandwidth   USD
```

A 10× jump in the **Bandwidth** meter on 2026-08-29. Bandwidth means **egress**. Correlate with a deployment:

```bash
$ az monitor activity-log list --offset 10d \
    --query "[?operationName.value=='Microsoft.Resources/deployments/write' && status.value=='Succeeded'].{time:eventTimestamp, rg:resourceGroupName, name:resourceId}" \
    -o table | grep '2026-08-29'
```
```
2026-08-29T09:14:02+00:00  rg-payments-prod  .../deployments/payments-a91f3c2
```

**Root cause pattern.** A deployment moved a component across regions (or a cache was disabled), converting free intra-region traffic into charged cross-region or internet egress. This is the single most common surprise on an Azure bill and it is invisible in architecture diagrams — **egress does not appear as a box, only as an arrow.**

**Prevention.** Budget forecast alerts (§8.1), Cost Management anomaly alerts, and a CI check that fails a plan introducing a cross-region data path.

---

**Symptom: p99 latency has a long tail; p50 is fine**

**Cause.** Cold starts on a scale-to-zero tier, or scale-out ramp lag.

**Diagnosis (Application Insights / Log Analytics KQL). This is a heuristic — it attributes to "cold" any request served within 10 s of a host start on the same role instance:**

```kusto
let window = 24h;
let coldWindow = 10s;
let hostStarts =
    traces
    | where timestamp > ago(window)
    | where message startswith "Host started"
    | project startTime = timestamp, cloud_RoleInstance;
requests
| where timestamp > ago(window)
| where cloud_RoleName == "func-payments-k3h9"
| join kind=leftouter hostStarts on cloud_RoleInstance
| extend isCold = isnotempty(startTime) and (timestamp - startTime) between (0s .. coldWindow)
| summarize
    total          = count(),
    coldCount      = countif(isCold),
    p50_warm_ms    = percentileif(duration, 50, not(isCold)),
    p95_warm_ms    = percentileif(duration, 95, not(isCold)),
    p95_cold_ms    = percentileif(duration, 95, isCold)
  by bin(timestamp, 1h)
| extend coldPct = round(100.0 * coldCount / total, 2)
| order by timestamp asc
```

| timestamp | total | coldCount | p50_warm_ms | p95_warm_ms | p95_cold_ms | coldPct |
|---|---:|---:|---:|---:|---:|---:|
| 2026-09-04T02:00 | 14 | 9 | 78 | 141 | 3104 | 64.29 |
| 2026-09-04T03:00 | 11 | 8 | 81 | 152 | 2988 | 72.73 |
| 2026-09-04T09:00 | 21411 | 37 | 74 | 138 | 2871 | 0.17 |
| 2026-09-04T10:00 | 26890 | 12 | 72 | 131 | 2790 | 0.04 |

Read it correctly: cold starts are **64–73% of requests in the overnight trough** and **under 0.2% during business hours**. The absolute number of affected users is small; the *rate* is terrible for anyone hitting the API at 03:00.

**Fix, ranked by cost:**

| Fix | Cost | Effect |
|---|---|---|
| Trim dependencies / shrink package | Free | Reduces cold start magnitude by 30–60% in practice |
| Move init to module scope | Free | Amortises across warm invocations |
| Flex Consumption `alwaysReady: 1` | Small fixed baseline | Removes cold start for the first *N* concurrent requests |
| Premium plan, pre-warmed instances | Full always-on cost | Removes cold start entirely; **stops being serverless** |
| Accept it | Free | Correct answer for async/batch tiers; wrong for synchronous user-facing paths |

---

**Symptom: functions succeed under light load, fail with connection errors under burst**

```
[Error] Function 'settle' failed: (18456) Login failed for user 'app'.
Reason: The server is not currently available for connection.
```
or
```
FATAL: remaining connection slots are reserved for non-replication superuser connections
```

**Cause.** The fan-out problem from §7.4. The scale controller added instances; each opened a connection pool; the aggregate exceeded the database's connection limit.

**Diagnosis:**
```bash
$ az monitor metrics list \
    --resource "/subscriptions/$SUB/resourceGroups/rg-payments-prod/providers/Microsoft.Sql/servers/sql-payments/databases/payments" \
    --metric connection_failed sessions_percent \
    --interval PT5M --aggregation Maximum \
    --start-time 2026-09-04T09:00:00Z --end-time 2026-09-04T10:00:00Z \
    --query "value[].{metric:name.value, max:timeseries[0].data[-1].maximum}" -o table
```
```
Metric             Max
-----------------  ------
connection_failed  418.0
sessions_percent   100.0
```

**Fix.** Cap concurrency at the *source*, not the sink:
- Flex Consumption: lower `maximumInstanceCount` and `perInstanceConcurrency` (both are in §8.1).
- Consumption plan: set `functionAppScaleLimit`, and for queue triggers reduce `batchSize` in `host.json`.
- Reuse a single module-scope connection pool per instance; never open a connection inside the handler.
- Put a bounded queue between the function and the database, so backpressure is expressed as latency rather than errors.

`host.json`:

```json
{
  "version": "2.0",
  "functionTimeout": "00:05:00",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": true,
        "maxTelemetryItemsPerSecond": 20,
        "excludedTypes": "Request;Exception"
      }
    },
    "logLevel": {
      "default": "Information",
      "Host.Results": "Information",
      "Function": "Information",
      "Host.Aggregator": "Information"
    }
  },
  "extensions": {
    "http": {
      "routePrefix": "api",
      "maxConcurrentRequests": 16,
      "maxOutstandingRequests": 64,
      "dynamicThrottlesEnabled": true
    },
    "serviceBus": {
      "prefetchCount": 0,
      "messageHandlerOptions": {
        "autoComplete": false,
        "maxConcurrentCalls": 8,
        "maxAutoRenewDuration": "00:05:00"
      }
    }
  },
  "retry": {
    "strategy": "exponentialBackoff",
    "maxRetryCount": 5,
    "minimumInterval": "00:00:02",
    "maximumInterval": "00:01:00"
  }
}
```

---

**Symptom: Spot instances vanish mid-job; work is lost**

**Cause.** Working as designed. Spot has no SLA and is evicted on capacity pressure with 30 seconds notice.

**Diagnosis:**
```bash
$ az monitor activity-log list --offset 6h \
    --query "[?contains(operationName.value, 'preempt') || contains(operationName.value, 'deallocate')].{time:eventTimestamp, op:operationName.localizedValue, res:resourceId}" \
    -o table
```
```
Time                        Op                          Res
--------------------------  --------------------------  -------------------------------
2026-09-04T07:12:44+00:00   Preempt Virtual Machine     .../vmss-payments-burst_4
2026-09-04T07:12:44+00:00   Preempt Virtual Machine     .../vmss-payments-burst_7
```

**Fix.** Not "stop using Spot" — the economics are too good (§6.2). Instead:
1. Poll Scheduled Events (§3.2) and act on `Preempt` within the 30-second window: cordon+drain, checkpoint, requeue.
2. Make the work idempotent and re-runnable so a lost unit is retried, not corrupted.
3. Mix priorities: a baseline of regular/reserved instances plus a Spot burst tier (§8.2).
4. Never place stateful or latency-critical tiers on Spot.

---

**Symptom: hybrid — Arc-connected resources show `Disconnected`**

**Cause.** The Arc agent lost outbound connectivity to Azure. Arc requires outbound HTTPS (443) to a defined set of endpoints; the agent heartbeats regularly and is marked `Disconnected` after a sustained gap.

**Diagnosis, on the machine:**
```bash
$ sudo azcmagent show
```
```
Resource Name          : onprem-app-07
Resource Group Name    : rg-payments-prod
Subscription ID        : 1f9c3b62-7a41-4d0e-9b8c-2e5a7d13f004
Agent Version          : 1.49.02623.1234
Agent Status           : Disconnected
Agent Last Heartbeat   : 2026-09-04T04:11:07Z
Dependent Service Status:
  Agent Service (himdsd)               : active
  GC Service (gcad)                    : active
  Extension Service (extd)             : active
```

```bash
$ sudo azcmagent check --location eastus
```
```
Checking connectivity to endpoints...

Endpoint                                         Reachable
-----------------------------------------------  ----------
https://management.azure.com                     true
https://login.microsoftonline.com                true
https://eastus.his.arc.azure.com                 false
https://gbl.his.arc.azure.com                    true
https://<GUID>.agentsvc.azure-automation.net     false

2 of 5 endpoints are not reachable.
```

**Fix.** Two regional endpoints are blocked at the egress firewall. Allow-list them (or use the `AzureArcInfrastructure` service tag / Arc gateway), then `sudo azcmagent connect --resource-group … --tenant-id … --location eastus`.

**The lesson.** Hybrid moves the responsibility for *network reachability to the control plane* back to you. In pure public cloud, that path is Microsoft's. This is exactly the shared-responsibility shift the model predicts — hybrid does not split the difference on operational burden, it **adds** a layer.

---

## 11. Exam-focused summary

Compressed answers. Every one is derived from the sections above.

| Prompt | Answer |
|---|---|
| Define cloud computing | Delivery of computing services (compute, storage, databases, networking, software, analytics, intelligence) over the internet, on a pay-as-you-go basis |
| Five NIST characteristics | On-demand self-service · broad network access · resource pooling · rapid elasticity · measured service |
| Which responsibilities are *always* the customer's? | Information and data · devices · accounts and identities |
| Which responsibilities are *always* Microsoft's in any cloud model? | Physical hosts · physical network · physical datacenter |
| Who owns the OS in IaaS? PaaS? | IaaS: **customer**. PaaS: **Microsoft** |
| Who owns applications in PaaS? | **Shared** |
| Public cloud | Provider-owned, multi-tenant, no CapEx, no hardware control |
| Private cloud | Single-organisation, may be on-prem or hosted, full control, CapEx, you patch everything |
| Hybrid cloud | Public + private, bound together, workload placed per requirement; enabled by Azure Arc / Azure Local / ExpressRoute |
| Multicloud | Two or more *public* providers — not the same as hybrid |
| CapEx vs OpEx | CapEx = up-front capital, depreciated; OpEx = ongoing operational, expensed as incurred. Cloud is OpEx |
| Consumption-based model | Pay only for what you use, no up-front cost, no penalty for stopping, stop paying when you stop using |
| Pay-as-you-go | No commitment, highest unit price, maximum flexibility |
| Reserved instances | 1 or 3 year commitment to a specific resource type/region; largest discount; commits you to the shape |
| Savings plan | 1 or 3 year commitment to an hourly *spend*; smaller discount than an RI, far more flexible across services and regions |
| Spot | Unused capacity at a deep discount, **evictable with 30 s notice, no SLA** |
| Azure Hybrid Benefit | Apply eligible existing Windows Server / SQL Server / RHEL / SLES licences to remove the licence charge |
| Serverless | Provider fully manages infrastructure; scales automatically including **to zero**; billed per execution, not per provisioned hour |
| Serverless benefits | No infrastructure management, automatic scaling, true consumption billing, fast time to value |
| Serverless drawbacks | Cold start, execution time limits, statelessness required, bounded scale rate, deeper platform coupling |
| Azure serverless services to name | Azure Functions (Consumption / Flex Consumption), Azure Container Apps, Azure Logic Apps (Consumption), Azure Container Instances, Cosmos DB serverless, Azure SQL Database serverless |
| Is an App Service Premium plan serverless? | **No** — it does not scale to zero and it bills for provisioned capacity |

**The five sentences worth carrying into the exam room and into production:**

1. An SLA is a service credit, not a guarantee, and serial dependencies multiply it downward.
2. Responsibility can be delegated to Microsoft; **risk cannot** — your customers still page you.
3. Control plane and data plane fail independently; diagnose them independently.
4. "Elastic" means *statistically available*, bounded by quota, regional capacity and scale rate.
5. Serverless trades cold-start latency and long-run cost for zero idle cost and zero infrastructure work — that trade is only correct for short, spiky workloads.

---

## Referencias

**Microsoft official — certification and study path**
- AZ-900 study guide (skills measured, authoritative scope): https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Certified: Azure Fundamentals: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/
- Learn module — Describe cloud computing: https://learn.microsoft.com/en-us/training/modules/describe-cloud-compute/
- Learn module — Describe the benefits of using cloud services: https://learn.microsoft.com/en-us/training/modules/describe-benefits-use-cloud-services/
- Learn module — Describe cloud service types: https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/

**Shared responsibility, reliability and SLA**
- Shared responsibility in the cloud: https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
- Service Level Agreements (SLA) for Online Services: https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services
- Business continuity management in Azure: https://learn.microsoft.com/en-us/azure/reliability/business-continuity-management-program
- Availability zones and regions: https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Availability sets, fault domains and update domains: https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Maintenance and updates for VMs in Azure: https://learn.microsoft.com/en-us/azure/virtual-machines/maintenance-and-updates
- Scheduled Events for Linux VMs: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/scheduled-events
- Azure Instance Metadata Service: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service

**Control plane, Azure Resource Manager and governance**
- Azure Resource Manager overview: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Control plane and data plane operations: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/control-plane-and-data-plane
- Throttling Resource Manager requests: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling
- Azure subscription and service limits, quotas and constraints: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
- Resource providers and resource types: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types
- Bicep documentation: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
- Deployment what-if operation: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
- Azure Policy overview: https://learn.microsoft.com/en-us/azure/governance/policy/overview
- Azure Resource Graph overview: https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview

**Deployment models and hybrid**
- NIST SP 800-145, *The NIST Definition of Cloud Computing*: https://csrc.nist.gov/publications/detail/sp/800-145/final
- Azure Arc overview: https://learn.microsoft.com/en-us/azure/azure-arc/overview
- Azure Arc-enabled servers: https://learn.microsoft.com/en-us/azure/azure-arc/servers/overview
- Azure Arc-enabled Kubernetes: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview
- Arc-enabled servers network requirements: https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements
- Azure Local (formerly Azure Stack HCI): https://learn.microsoft.com/en-us/azure/azure-local/overview
- Azure geographies, regions and region pairs: https://learn.microsoft.com/en-us/azure/reliability/regions-overview

**Pricing, consumption and cost management**
- Azure pricing overview: https://azure.microsoft.com/en-us/pricing/
- Azure Pricing Calculator: https://azure.microsoft.com/en-us/pricing/calculator/
- Total Cost of Ownership (TCO) Calculator: https://azure.microsoft.com/en-us/pricing/tco/calculator/
- Cost Management + Billing documentation: https://learn.microsoft.com/en-us/azure/cost-management-billing/
- Understand Azure reservations discount: https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations
- Azure savings plan for compute: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview
- Azure Spot Virtual Machines: https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms
- Azure Hybrid Benefit: https://learn.microsoft.com/en-us/azure/cost-management-billing/scope-level/overview-azure-hybrid-benefit-scope
- Create and manage budgets: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
- Cost Management Query API: https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage
- Bandwidth (data transfer) pricing: https://azure.microsoft.com/en-us/pricing/details/bandwidth/
- Azure free account and always-free services: https://azure.microsoft.com/en-us/free/

**Serverless**
- Serverless on Azure: https://azure.microsoft.com/en-us/solutions/serverless/
- Azure Functions hosting options: https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Azure Functions Consumption plan: https://learn.microsoft.com/en-us/azure/azure-functions/consumption-plan
- Azure Functions Flex Consumption plan: https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan
- Event-driven scaling in Azure Functions: https://learn.microsoft.com/en-us/azure/azure-functions/event-driven-scaling
- Performance and reliability best practices for Azure Functions: https://learn.microsoft.com/en-us/azure/azure-functions/functions-best-practices
- `host.json` reference (v2): https://learn.microsoft.com/en-us/azure/azure-functions/functions-host-json
- Azure Container Apps overview: https://learn.microsoft.com/en-us/azure/container-apps/overview
- Scaling in Azure Container Apps: https://learn.microsoft.com/en-us/azure/container-apps/scale-app
- Azure Container Apps billing: https://learn.microsoft.com/en-us/azure/container-apps/billing
- Azure Cosmos DB serverless: https://learn.microsoft.com/en-us/azure/cosmos-db/serverless
- Azure SQL Database serverless tier: https://learn.microsoft.com/en-us/azure/azure-sql/database/serverless-tier-overview
- KEDA (Kubernetes Event-driven Autoscaling): https://keda.sh/docs/latest/concepts/

**Tooling**
- Azure CLI reference: https://learn.microsoft.com/en-us/cli/azure/reference-index
- `az consumption`: https://learn.microsoft.com/en-us/cli/azure/consumption
- `az costmanagement`: https://learn.microsoft.com/en-us/cli/azure/costmanagement
- `az connectedk8s`: https://learn.microsoft.com/en-us/cli/azure/connectedk8s
- Terraform AzureRM provider: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs
- Kusto Query Language reference: https://learn.microsoft.com/en-us/azure/data-explorer/kusto/query/