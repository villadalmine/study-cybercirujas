# 4.2 — Google Cloud Infrastructure Offerings: Functionality, Business Use Cases, and Business Value

**Certification:** Google Cloud Digital Leader (exam guide version 2026-08-12)
**Section 4:** Modernizing infrastructure and applications with Google Cloud
**Exam weight:** 6.0 — this is a *breadth* objective with *depth* consequences. The exam asks you to match a business scenario to an infrastructure offering; production asks you to defend that match at a design review. This material teaches the second, which subsumes the first.

---

## 1. Motivation: the production architectural problem

### 1.1 The decision that actually gets made

No real organization asks "should we use the cloud?" They ask a much narrower, much harder question, usually under a deadline:

> *We have 1,400 VMs in two leased datacenters. The colo contract expires in 19 months. 60% of those VMs run a Java monolith and its satellites, 15% run Oracle on bare metal with a licensing agreement we cannot renegotiate, 10% are a VMware estate nobody has documented since 2019, and the rest are batch and build agents. We have 6 platform engineers. Where does each workload land, what does it cost, and what breaks?*

That question decomposes into exactly the three things this objective names:

| Exam vocabulary | Architect's translation | Failure mode when ignored |
|---|---|---|
| **Functionality** | What abstraction level does the offering expose, and what does it take away? | You pick Cloud Run for a workload that needs a persistent local disk and 6-hour requests. |
| **Business use case** | Which workload shape maps to it *without a rewrite*? | You "modernize" an Oracle RAC cluster to GKE, burn 14 months, and miss the colo exit. |
| **Business value** | TCO, time-to-market, risk transfer, and SLA — measured, not asserted. | You migrate 1:1 at on-demand pricing and your cloud bill is 2.4× the colo bill. |

### 1.2 The architectural pressure: the abstraction/control trade-off is not free

Every infrastructure offering sits on one axis — **how much of the operational surface Google absorbs** — and moving along that axis is never neutral. You trade control for elasticity and headcount, and you pay for the trade in *portability constraints* and *lock-in of operational assumptions*.

```
 More control                                                    More managed
 More ops burden                                                 Less ops burden
 ├──────────────┬─────────────┬──────────┬────────────┬──────────┬────────────┤
 Bare Metal     Compute       GKE        GKE          Cloud Run  Cloud Run
 Solution /     Engine        Standard   Autopilot               functions
 VMware Engine  (IaaS)        (CaaS)     (CaaS-managed) (serverless containers)
                                                                 App Engine std

 You patch OS  ──────────────►│ Google patches nodes ──────────►│ No node concept
 You size VMs  ──────────────────────────►│ Google sizes to Pod ►│ Scales to zero
 You own HA    ──────────►│ k8s owns Pod HA │────────────────────►│ Fully managed
```

The **anti-pattern this objective exists to prevent** is the "lift-and-shift into the wrong tier" — either direction:

- **Too far left:** everything on Compute Engine. You have recreated the datacenter, plus an egress bill. No elasticity benefit, no ops reduction, and you now pay a premium for someone else's hardware.
- **Too far right:** everything on Cloud Run/serverless. Stateful workloads, long-running jobs, GPU pipelines, and licensed appliances get force-fit; you end up building compensating machinery (external state stores, checkpointing, orchestration) that costs more than the VMs you avoided.

### 1.3 The second pressure: failure domains are a *purchased* property

In a colo, availability is something you build. In Google Cloud, availability is largely something you **select** — via placement across zones and regions — and then *fail to invalidate* with a bad design. The single most common production incident in a migrated estate is:

> A "cloud" service that is architecturally single-zone, running on infrastructure that offers 99.99% only if you spread it, delivering colo-grade availability at cloud-grade prices.

Sections 2 and 10 make that arithmetic explicit.

---

## 2. The substrate: what you are actually buying

You cannot reason about the offerings without the physical model underneath them. This is the part the exam states in one sentence and production tests every week.

### 2.1 Location hierarchy

| Construct | Definition | Failure-domain meaning | Products scoped here |
|---|---|---|---|
| **Multi-region** | A large geographic area (e.g. `US`, `EU`, `ASIA`) containing multiple regions | Survives loss of an entire region | Cloud Storage multi-region buckets, Spanner multi-region, BigQuery multi-region datasets |
| **Region** | An independent geographic area (e.g. `us-central1`, `europe-west1`, `southamerica-east1`) containing ≥3 zones | Survives loss of a zone; is itself a correlated-failure unit for a region-wide event | VPC subnets, regional MIGs, regional GKE control planes, Cloud Run services, regional Cloud Storage |
| **Zone** | An isolated deployment area within a region; independent power, cooling, networking. A zone name like `us-central1-a` is **project-scoped** — your `-a` is not necessarily another project's `-a` | The primary blast radius you design around | VM instances, zonal Persistent Disks, Local SSD, zonal GKE control planes, zonal MIGs |
| **Edge PoP / network edge location** | 180+ network edge locations peering with ISPs | Not a compute location; where traffic *enters* Google's backbone | Cloud CDN, Media CDN, Cloud Armor, global load balancing front ends |

> **Verify, don't memorize.** Region/zone counts change quarterly. The authoritative list is `gcloud compute regions list` and the locations page (§12). At time of this syllabus snapshot the fleet is 40+ regions and 120+ zones; treat exam questions as testing the *concept*, not the count.

### 2.2 The three internal systems whose behavior leaks into your design

You will never provision these directly, but every offering in this objective is an interface to one of them. Knowing them explains otherwise-arbitrary product limits.

| Internal system | What it is | Where it surfaces in the product |
|---|---|---|
| **Borg** | Google's cluster manager; the direct ancestor of Kubernetes | Why GKE Autopilot can bin-pack your Pods with no node visibility; why Cloud Run cold-starts are measured in hundreds of ms, not minutes |
| **Colossus** | The cluster-level distributed filesystem (successor to GFS) | Why Cloud Storage has no provisioned capacity and no IOPS to size; why Persistent Disk is network-attached and survives instance deletion |
| **Jupiter / Andromeda** | The datacenter fabric (petabit-scale bisection bandwidth) and the network virtualization stack | Why VPCs are **global** objects while subnets are regional; why an internal passthrough load balancer has no proxy VMs; why VM egress throughput scales with vCPU count |

**Design consequence you will use immediately:** because the VPC is a global software-defined construct, a VM in `us-central1` and a VM in `asia-southeast1` in the same VPC talk over RFC 1918 addresses with **no VPN, no peering, no gateway**. In AWS/Azure terms this collapses an entire transit-network design into a routing decision. This is a genuine differentiator and a frequent exam answer.

---

## 3. Compute offerings

For each offering: **Functionality → Business use case → Business value**, then the consolidated trade-off table.

### 3.1 Compute Engine (IaaS)

**Functionality.** Virtual machines on Google's infrastructure. You choose machine family, vCPU/memory, boot disk image, and placement. You get: custom machine types (arbitrary vCPU/memory within family ratios), live migration (host maintenance without VM restart — a genuine differentiator vs. reboot-based maintenance), per-second billing after a 1-minute minimum, and Managed Instance Groups (MIGs) for autohealing, autoscaling, and rolling updates.

**Business use case.** Lift-and-shift of existing VMs; commercial software with OS-level install requirements; workloads with specialized kernels, licensed agents, or GPU/TPU attachment; anything where the vendor support matrix names an operating system.

**Business value.** Fastest path off a datacenter lease with the lowest rewrite risk. Converts capex + refresh cycles into opex, and unlocks the discount instruments (§10) that make the opex defensible.

**Machine family selection** — this is where most cost decisions are actually made:

| Family | Series (examples) | Design point | Use when |
|---|---|---|---|
| General purpose | `E2`, `N2`, `N2D`, `N4`, `C4`, `T2D` | Balanced price/perf | Web tiers, app servers, dev/test. `E2` is the cost floor (no SUD, shared-core options); `T2D`/`N2D` are AMD-based and often the best $/perf for scale-out |
| Compute optimized | `C2`, `C2D`, `C3`, `C4` | Highest consistent per-core performance | Game servers, HPC, ad serving, single-threaded-latency-bound apps |
| Memory optimized | `M1`, `M2`, `M3`, `M4` | Up to multi-TB RAM | SAP HANA, large in-memory databases, analytics caches |
| Storage optimized | `Z3` | Very high local SSD density | Scale-out databases, hot-data analytics needing local NVMe |
| Accelerator optimized | `A2`, `A3`, `A4`, `G2` | NVIDIA GPU attached | Training and large-batch inference (`A*`), inference/graphics (`G2`) |

**Provisioning models** — the second cost lever:

| Model | Discount vs on-demand | Interruption | Max runtime | Correct workload |
|---|---|---|---|---|
| On-demand | baseline | none | unlimited | Steady, latency-critical, licensed |
| **Spot VMs** | ~60–91% | Yes, 30-second `ACPI G2 Soft Off` notice | unlimited (unlike legacy Preemptible's 24 h cap) | Batch, CI, render farms, fault-tolerant map/reduce, stateless scale-out with surge capacity |
| Sole-tenant nodes | premium (+) | none | unlimited | BYOL with physical-core licensing, compliance requiring physical isolation |
| Reservations | none (guarantees capacity) | none | unlimited | Guaranteeing stockout-proof capacity for DR or peak events; combines with CUDs |

### 3.2 Google Kubernetes Engine (GKE)

**Functionality.** Managed Kubernetes: Google runs the control plane (etcd, API server, scheduler, controller manager) with an SLA, and manages node lifecycle to a degree you choose.

| | **GKE Standard** | **GKE Autopilot** |
|---|---|---|
| Billing unit | Node VMs (whatever you provision, idle or not) | Pod resource requests (vCPU/mem/storage) |
| Node management | You size, upgrade windows, node pools, taints | Google provisions, sizes, patches, scales nodes |
| Node access | SSH available, DaemonSets, privileged Pods, hostPath | No SSH; privileged/hostPath restricted; DaemonSets allowed with constraints |
| Bin-packing risk | Yours (unallocated node capacity is your bill) | Google's |
| Best for | Custom kernels/drivers, GPU tuning, node-level agents, cost control at high steady utilization | Default choice for new workloads; teams without a dedicated k8s SRE function |
| Control-plane SLA | Regional 99.95% / zonal 99.5% | Regional 99.95% |

**Business use case.** Microservices platforms; multi-tenant internal platforms; workloads already containerized; hybrid/multicloud where Kubernetes is the portability contract (GKE Enterprise / Anthos extends the control plane to on-prem and other clouds).

**Business value.** Google authored Kubernetes; GKE is the reference implementation. Autopilot converts a variable, hard-to-attribute node bill into a per-Pod bill that maps 1:1 onto team chargeback — an underrated *financial* argument that wins budget conversations.

### 3.3 Cloud Run (serverless containers)

**Functionality.** Runs any stateless container that listens on `$PORT`, scaling 0→N on request or event volume. Concurrency up to 1000 requests per instance (this is the key economic difference vs. per-request FaaS). Two workload shapes: **Services** (request-driven) and **Jobs** (run-to-completion, array-parallel). Direct VPC egress or Serverless VPC Access connectors reach private resources.

**Business use case.** APIs and web front ends with spiky or unpredictable traffic; event consumers (Pub/Sub push, Eventarc); scheduled ETL as Jobs; internal tools that idle 22 hours a day.

**Business value.** Scale-to-zero eliminates the cost of idle. A dev/test estate of 40 internal apps on VMs runs ~$X/month regardless of use; on Cloud Run the same estate costs near zero overnight and on weekends. Deployment surface shrinks to `gcloud run deploy`, which removes an entire class of ops work.

### 3.4 Cloud Run functions

**Functionality.** Function-as-a-Service, event-driven, built on the Cloud Run infrastructure (this is what was previously branded Cloud Functions 2nd gen). Triggers: HTTP, Pub/Sub, Cloud Storage object events, Firestore, Eventarc (90+ sources).

**Business use case.** Glue code — thumbnail generation on upload, webhook receivers, small transformations, alert routing.

**Business value.** Lowest possible time-to-first-deploy for a discrete piece of business logic. The value case is developer minutes, not compute cents.

### 3.5 App Engine

**Functionality.** The original Google PaaS. **Standard environment**: sandboxed runtimes, scale to zero, sub-second instance start, tight language/version constraints. **Flexible environment**: your container on managed Compute Engine VMs, no scale-to-zero, more freedom.

**Business use case.** Existing App Engine estates; classic request/response web apps where the language runtime is supported and traffic is bursty. **For new builds, Cloud Run is the modern default** — say this out loud in a design review.

**Business value.** Zero infrastructure management with built-in versioning and traffic splitting.

### 3.6 Bare Metal Solution

**Functionality.** Certified, single-tenant physical hardware in a Google-managed facility **adjacent to** a Google Cloud region, connected over a low-latency (typically sub-2 ms), high-bandwidth link into your VPC via Partner Interconnect. You keep root and your existing licenses.

**Business use case.** Exactly one, essentially: **Oracle and other legacy workloads with hardware/licensing constraints that block virtualization**, where you still want the *rest* of the estate in Google Cloud with fast, private connectivity.

**Business value.** Removes the "we can't move because of Oracle" blocker without a database migration project. Lets the colo lease expire.

### 3.7 Google Cloud VMware Engine (GCVE)

**Functionality.** A dedicated, Google-managed VMware Cloud Foundation stack — vSphere, vCenter, vSAN, NSX — running on Google Cloud bare metal. You get your familiar vCenter with your existing VMs, tooling, and runbooks. HCX handles bulk and live migration.

**Business use case.** Large undocumented VMware estates on a hard deadline. Datacenter exit where re-platforming 800 VMs is not feasible in the available window. VMware-based DR into the cloud.

**Business value.** *Time.* This is the highest-velocity datacenter exit available: no OS conversion, no application re-testing, no retraining of the virtualization team. It is deliberately a **transitional** landing zone — you modernize *after* the lease is gone, workload by workload, instead of under duress.

### 3.8 Consolidated compute trade-off table

| Dimension | Bare Metal Solution | VMware Engine | Compute Engine | GKE Standard | GKE Autopilot | Cloud Run | Cloud Run functions | App Engine Std |
|---|---|---|---|---|---|---|---|---|
| Unit of deployment | Physical server | VM (vSphere) | VM | Container/node | Container/Pod | Container | Function | Code bundle |
| Scales to zero | No | No | No | No (nodes) | No (min nodes) | **Yes** | **Yes** | **Yes** |
| Billing granularity | Monthly/term | Node-hour (term) | Per second | Node-second | **Pod-second** | ~100 ms request/instance | ~100 ms | Instance-hour |
| OS patching | You | You (guest) | You (guest) | Google (nodes, auto-upgrade) | Google | Google | Google | Google |
| Max request/exec duration | n/a | n/a | n/a | n/a | n/a | 60 min (services) / 24 h (jobs) | 60 min | 10 min (auto scaling) |
| Persistent local state | Yes | Yes | Yes (PD/Local SSD) | Yes (PV) | Yes (PV) | No (ephemeral, in-memory FS) | No | No |
| GPU support | Yes | Limited | Yes | Yes | Yes | Yes (L4) | No | No |
| Typical migration effort from on-prem VM | None | **None** | Low (image import) | Medium (containerize) | Medium | High (statelessness required) | High (decompose) | High |
| Lock-in of operational model | Lowest | Lowest | Low | Low (k8s portable) | Medium | Medium (Knative-compatible) | High | High |

### 3.9 Decision procedure (use this, in order)

```
1. Does a vendor/licensing constraint forbid virtualization or require physical cores?
      → Bare Metal Solution (or sole-tenant nodes if virtualization is allowed)
2. Is it a large VMware estate under a hard datacenter-exit deadline?
      → Google Cloud VMware Engine (modernize later, not now)
3. Does it need OS-level control, a custom kernel, or an unsupported runtime?
      → Compute Engine  (+ MIG for HA/autoscaling, + Spot for fault-tolerant tiers)
4. Is it already containerized, or does the org run a platform for many teams?
      → GKE   → Autopilot unless you need node-level control → then Standard
5. Is it a stateless HTTP service or event consumer with variable traffic?
      → Cloud Run  (Jobs for run-to-completion batch)
6. Is it a single event-triggered snippet of glue logic?
      → Cloud Run functions
```

---

## 4. Storage offerings

**The architectural rule:** classify by *access pattern and lifetime*, never by size.

### 4.1 Object storage — Cloud Storage

**Functionality.** Globally consistent object store on Colossus. No provisioning: capacity, throughput, and IOPS are elastic. Location type (region / dual-region / multi-region) sets the durability and availability envelope; **storage class sets the price/retrieval trade-off**. Durability is 11 nines across all classes — the classes differ in *availability and access cost*, not durability.

| Class | Minimum storage duration | Storage cost | Retrieval cost | Designed for |
|---|---|---|---|---|
| **Standard** | none | highest | none | Hot data, website assets, active analytics, dataflow staging |
| **Nearline** | 30 days | lower | low | Backups and content accessed ~monthly |
| **Coldline** | 90 days | lower still | higher | Quarterly access, DR copies |
| **Archive** | 365 days | lowest | highest | Compliance retention, tape replacement; **millisecond first-byte latency, not hours** |

Key features an architect must know: **Object Lifecycle Management** (age/version-based transitions and deletion), **Autoclass** (automatic per-object class transitions with no retrieval charges on transition — the correct default when access patterns are unknown), **Object Versioning**, **Retention Policies with Bucket Lock** (WORM, for regulatory compliance), **Customer-Managed Encryption Keys (CMEK)** via Cloud KMS, and **Requester Pays**.

**Business value.** Replaces tape libraries, NAS tiers, and archival contracts with one API and a lifecycle policy. The Archive class delivering millisecond retrieval kills the classic "restore takes 12 hours" DR problem outright.

### 4.2 Block storage

| Product | Attach model | Durability scope | Performance model | Use when |
|---|---|---|---|---|
| **Persistent Disk** (`pd-standard`, `pd-balanced`, `pd-ssd`, `pd-extreme`) | Network-attached; survives VM deletion; multi-reader supported | Zonal, or **Regional PD** (synchronous replication across two zones in a region) | IOPS/throughput scale with size **and** with the VM's vCPU count | Boot disks, general databases, anything needing snapshots |
| **Hyperdisk** (`Balanced`, `Extreme`, `Throughput`, `ML`) | Network-attached, next-generation | Zonal (Balanced HA variant available) | **Independently provisioned** capacity, IOPS, and throughput — decoupled from disk size and VM size | High-IOPS databases; when PD forces you to over-provision capacity to buy IOPS. Required on newer families (e.g. `N4`) |
| **Local SSD** | Physically attached NVMe, 375 GiB per device | **Ephemeral** — data lost on stop/terminate/live-migrate-restart | Highest IOPS, lowest latency | Scratch space, caches, shuffle/spill, replicated scale-out DBs that reconstruct from peers |

> **Production trap:** engineers migrating from on-prem size a `pd-balanced` at 100 GB, get the IOPS ceiling that comes with 100 GB, and file a performance bug. On PD, **IOPS is bought with capacity**; on Hyperdisk it is bought directly. This single distinction is worth understanding for both the exam ("which offering lets you scale IOPS independently of size?") and for the 3 a.m. page.

### 4.3 File storage

| Product | Protocol | Use case |
|---|---|---|
| **Filestore** (Basic / Zonal / Regional / Enterprise) | NFSv3 | Lift-and-shift apps expecting a POSIX shared mount; GKE `ReadWriteMany` volumes; media/render pipelines; SAP shared filesystems |
| **NetApp Volumes** | NFS + SMB, with snapshots/replication | Enterprise file estates needing NetApp features and SMB for Windows workloads |
| **Parallelstore** | DAOS-based parallel FS | HPC and AI training requiring extreme aggregate throughput at low latency |

### 4.4 Storage decision table

| If the workload... | Use | Not |
|---|---|---|
| Reads/writes whole objects over HTTP | Cloud Storage | Filestore (paying for POSIX you don't use) |
| Is a database needing a block device with snapshots | PD Balanced / Hyperdisk Balanced | Local SSD (ephemeral) |
| Needs >100k IOPS on a modest dataset | **Hyperdisk Extreme** | pd-ssd inflated to 3 TB to buy IOPS |
| Needs a shared mount from many VMs/Pods simultaneously | Filestore / NetApp Volumes | PD (multi-writer is a narrow special case) |
| Is scratch/shuffle space that can be rebuilt | Local SSD | Hyperdisk (paying for durability you discard) |
| Must be retained 7 years for audit, rarely read | Cloud Storage **Archive** + Bucket Lock | Nearline (min-duration and price mismatch) |
| Has unknown or changing access patterns | Cloud Storage + **Autoclass** | Hand-written lifecycle rules you will forget to update |

---

## 5. Networking offerings

### 5.1 VPC — the property that changes designs

A **VPC network is a global resource**; **subnets are regional**. Consequences:

- One VPC can span every region on earth with no inter-region gateway.
- Routes and firewall rules are global objects; firewall rules are stateful and target instances by network tag or service account.
- **Shared VPC** lets a host project own the network while service projects attach workloads — the standard enterprise pattern separating a network team's authority from application teams' autonomy.
- **VPC Network Peering** connects VPCs (including across organizations) with private RFC 1918 connectivity, non-transitively.
- **Private Service Connect** exposes managed and third-party services on a private IP inside your VPC, removing public-IP paths to services like Cloud SQL or partner SaaS.

### 5.2 Network Service Tiers

| | **Premium Tier** (default) | **Standard Tier** |
|---|---|---|
| Path | Traffic enters/exits at the edge PoP nearest the user, then rides **Google's private backbone** ("cold potato" routing) | Traffic rides the public internet, entering/exiting near the *region* ("hot potato") |
| Latency/jitter | Lowest, most consistent | Internet-dependent |
| Load balancing | Supports **global** external load balancing with a single anycast IP | Regional load balancing only |
| Cost | Higher egress price | Lower egress price |
| Use for | Customer-facing production traffic | Bulk transfers, dev/test, cost-sensitive regional workloads |

This is a real, measurable, one-flag cost lever, and a recurring exam item.

### 5.3 Cloud Load Balancing

Google's load balancers are **software-defined, not VM-based** — there is nothing to pre-warm and nothing to scale. A global external Application Load Balancer presents **a single anycast IPv4/IPv6 address worldwide**.

| Load balancer | Scope | Layer | Typical use |
|---|---|---|---|
| Global external Application LB | Global (Premium Tier) | L7 HTTP(S) | Public web/API front door; integrates Cloud CDN, Cloud Armor, IAP, TLS certs |
| Regional external Application LB | Regional | L7 | Regional data-residency requirements; Standard Tier |
| Cross-region / regional internal Application LB | Internal | L7 | East-west microservice routing inside the VPC |
| External proxy Network LB | Global/regional | L4 proxy (TCP/SSL) | Non-HTTP TCP with TLS offload |
| External **passthrough** Network LB | Regional | L4 passthrough | Preserves client IP; UDP, non-TCP protocols, IP-protocol-level workloads |
| Internal passthrough Network LB | Regional | L4 passthrough | Internal service VIPs, HA appliance next-hops |

Companion services: **Cloud CDN** (caches at edge PoPs behind the global LB), **Cloud Armor** (WAF, L3–L7 DDoS, geo/rate rules, preconfigured OWASP rulesets), **Cloud DNS** (100% availability SLA, anycast, public and private zones), **Cloud NAT** (managed egress NAT with no NAT gateway VMs), **Network Connectivity Center** (hub-and-spoke transit across VPCs, Interconnects, VPNs, and SD-WAN).

### 5.4 Hybrid connectivity

| Option | Bandwidth | Private RFC 1918? | SLA | Use when |
|---|---|---|---|---|
| **Cloud VPN — HA VPN** | Up to ~3 Gbps per tunnel; scale with tunnels | Yes (IPsec over internet) | **99.99%** (two interfaces, correct topology) | Fast to stand up; moderate throughput; DR path |
| Cloud VPN — Classic VPN | ~1.5–3 Gbps/tunnel | Yes | 99.9% | Legacy; being superseded by HA VPN |
| **Dedicated Interconnect** | 10 Gbps or 100 Gbps circuits, bundled | Yes | 99.9% (single-region redundancy) / **99.99%** (multi-zone, 4-link topology) | High steady volume; predictable latency; reduced egress rate |
| **Partner Interconnect** | 50 Mbps – 50 Gbps | Yes | 99.9% / 99.99% by topology | You are not in a colo with a Google PoP; smaller increments |
| **Cross-Cloud Interconnect** | 10/100 Gbps | Yes | 99.9% / 99.99% | Direct private link to another public cloud |
| Direct / Carrier Peering | Varies | **No** — public IPs only | No SLA | Reaching Google public APIs at lower egress cost |

> **Business value framing for the exam:** Interconnect reduces *egress cost* and gives *deterministic latency*; HA VPN gives *speed of delivery* and *lower fixed cost*. Real estates run both — Interconnect primary, HA VPN as the standby path.

---

## 6. Migration and modernization paths

| Google tool | Stage | What it does |
|---|---|---|
| **Migration Center** | Assess | Discovers on-prem inventory, groups workloads, produces sizing and a **TCO report** — this is the artifact that gets budget approved |
| **Migrate to Virtual Machines** | Rehost | Streams on-prem/other-cloud VMs into Compute Engine with minimal downtime |
| **VMware Engine + HCX** | Rehost (VMware-native) | Bulk and live migration of vSphere VMs, unchanged |
| **Migrate to Containers** | Replatform | Converts VM workloads into container artifacts and GKE/Cloud Run manifests |
| **Database Migration Service** | Rehost/replatform DBs | Continuous replication into Cloud SQL / AlloyDB with minimal cutover downtime |
| **Storage Transfer Service** | Data | Online transfer from S3, Azure Blob, HTTP, on-prem POSIX to Cloud Storage |
| **Transfer Appliance** | Data | Physical shippable appliance (TA40 ≈ 40 TB, TA300 ≈ 300 TB) when the WAN math does not close |

**The WAN math, because someone will ask:** transferring 300 TB over a saturated 1 Gbps link ≈ 300 × 10¹² × 8 / 10⁹ s ≈ 2.4 M s ≈ **27.8 days at 100% utilization** — realistically 45–60 days. That is the entire business case for Transfer Appliance in one line.

**Modernization sequencing that actually works:**

```
Exit the datacenter first (rehost)  →  stabilize  →  modernize per workload (replatform/refactor)
```

Attempting refactor *during* the exit is the single most reliable way to miss the lease deadline. Say this in the design review; it is also the reasoning the exam rewards.

---

## 7. Complete infrastructure code

### 7.1 Terraform — landing zone, network, GKE Autopilot, MIG behind a global ALB

Complete and applyable. Replace the `project_id` default.

```hcl
# main.tf — Google Cloud infrastructure baseline
# Provides: VPC + subnet (with GKE secondary ranges), Cloud NAT, GKE Autopilot
# regional cluster, a Spot-backed regional MIG, and a global external
# Application Load Balancer with Cloud CDN and Cloud Armor.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  backend "gcs" {
    bucket = "tf-state-teachplat-prod"
    prefix = "infra/core"
  }
}

variable "project_id" {
  type        = string
  description = "Target Google Cloud project."
  default     = "teachplat-prod-001"
}

variable "region" {
  type    = string
  default = "us-central1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# Enable the APIs the rest of this configuration depends on.
# ---------------------------------------------------------------------------
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Network. The VPC is global; the subnet is regional. Secondary ranges back
# GKE Pods and Services (VPC-native / alias IP).
# ---------------------------------------------------------------------------
resource "google_compute_network" "core" {
  name                            = "core-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false
  depends_on                      = [google_project_service.required]
}

resource "google_compute_subnetwork" "workloads" {
  name                     = "workloads-${var.region}"
  ip_cidr_range            = "10.10.0.0/20" # 4096 node/VM addresses
  region                   = var.region
  network                  = google_compute_network.core.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/14" # 262144 Pod addresses — size this generously
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.24.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Egress for private nodes/VMs without public IPs.
resource "google_compute_router" "nat_router" {
  name    = "core-nat-router"
  region  = var.region
  network = google_compute_network.core.id
}

resource "google_compute_router_nat" "nat" {
  name                                = "core-nat"
  router                              = google_compute_router.nat_router.name
  region                              = var.region
  nat_ip_allocate_option              = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat  = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 128
  enable_dynamic_port_allocation      = true
  max_ports_per_vm                    = 8192

  log_config {
    enable = true
    filter = "ERRORS_ONLY" # surfaces port-exhaustion drops
  }
}

# ---------------------------------------------------------------------------
# Firewall: health checks and IAP SSH. These two source ranges are the ones
# people forget, and both failures look like "the app is down".
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_health_checks" {
  name          = "allow-gcp-health-checks"
  network       = google_compute_network.core.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["lb-backend"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "allow-iap-ssh"
  network       = google_compute_network.core.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding
  target_tags   = ["lb-backend"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ---------------------------------------------------------------------------
# GKE Autopilot, regional (99.95% control-plane SLA).
# ---------------------------------------------------------------------------
resource "google_container_cluster" "platform" {
  name             = "platform-autopilot"
  location         = var.region # region, not zone -> regional cluster
  enable_autopilot = true

  network    = google_compute_network.core.id
  subnetwork = google_compute_subnetwork.workloads.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  release_channel {
    channel = "REGULAR"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.10.0.0/20"
      display_name = "workloads-subnet"
    }
  }

  deletion_protection = true
}

# ---------------------------------------------------------------------------
# Compute Engine: regional MIG on Spot VMs, autohealed and autoscaled.
# The classic "cheap, fault-tolerant scale-out tier".
# ---------------------------------------------------------------------------
resource "google_service_account" "mig" {
  account_id   = "mig-workload"
  display_name = "Regional MIG workload identity"
}

resource "google_compute_instance_template" "web" {
  name_prefix  = "web-tpl-"
  machine_type = "n2d-standard-4"
  region       = var.region
  tags         = ["lb-backend"]

  scheduling {
    provisioning_model  = "SPOT"
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"

    instance_termination_action = "STOP"
  }

  disk {
    source_image = "projects/debian-cloud/global/images/family/debian-12"
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    disk_size_gb = 50
  }

  network_interface {
    network    = google_compute_network.core.id
    subnetwork = google_compute_subnetwork.workloads.id
    # No access_config block -> no external IP; egress via Cloud NAT.
  }

  service_account {
    email  = google_service_account.mig.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail
      apt-get update -qq
      apt-get install -y -qq nginx
      HOSTNAME_SELF="$(curl -s -H 'Metadata-Flavor: Google' \
        http://metadata.google.internal/computeMetadata/v1/instance/hostname)"
      ZONE_SELF="$(curl -s -H 'Metadata-Flavor: Google' \
        http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')"
      cat >/var/www/html/index.html <<HTML
      <!doctype html><html><body>
      <h1>ok</h1><p>host: $${HOSTNAME_SELF}</p><p>zone: $${ZONE_SELF}</p>
      </body></html>
HTML
      cat >/etc/nginx/sites-available/health <<'NGINX'
      server {
        listen 8080;
        location /healthz { return 200 'healthy\n'; add_header Content-Type text/plain; }
      }
NGINX
      ln -sf /etc/nginx/sites-available/health /etc/nginx/sites-enabled/health
      systemctl restart nginx
      systemctl enable nginx
    EOT
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_health_check" "web" {
  name                = "web-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_region_instance_group_manager" "web" {
  name                      = "web-mig"
  region                    = var.region
  base_instance_name        = "web"
  distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-f"]

  version {
    instance_template = google_compute_instance_template.web.id
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.web.id
    initial_delay_sec = 120
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }
}

resource "google_compute_region_autoscaler" "web" {
  name   = "web-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.web.id

  autoscaling_policy {
    min_replicas    = 3
    max_replicas    = 30
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}

# ---------------------------------------------------------------------------
# Global external Application Load Balancer + Cloud CDN + Cloud Armor.
# ---------------------------------------------------------------------------
resource "google_compute_security_policy" "edge" {
  name = "edge-armor-policy"

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default allow"
  }

  rule {
    action   = "rate_based_ban"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
      ban_duration_sec = 300
    }
    description = "per-IP rate limit"
  }
}

resource "google_compute_backend_service" "web" {
  name                  = "web-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.web.id]
  security_policy       = google_compute_security_policy.edge.id
  enable_cdn            = true

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    default_ttl       = 3600
    client_ttl        = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  backend {
    group           = google_compute_region_instance_group_manager.web.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }
}

resource "google_compute_url_map" "web" {
  name            = "web-urlmap"
  default_service = google_compute_backend_service.web.id
}

resource "google_compute_global_address" "web" {
  name       = "web-anycast-ip"
  ip_version = "IPV4"
}

resource "google_compute_managed_ssl_certificate" "web" {
  name = "web-cert"
  managed {
    domains = ["study.example.com"]
  }
}

resource "google_compute_target_https_proxy" "web" {
  name             = "web-https-proxy"
  url_map          = google_compute_url_map.web.id
  ssl_certificates = [google_compute_managed_ssl_certificate.web.id]
}

resource "google_compute_global_forwarding_rule" "web" {
  name                  = "web-fr-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.web.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.web.id
}

# ---------------------------------------------------------------------------
# Cloud Storage with tiering. Autoclass is preferred when access patterns
# are unknown; the explicit lifecycle rules below show the manual equivalent.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-artifacts"
  location                    = "US" # multi-region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}

output "load_balancer_ip" {
  value       = google_compute_global_address.web.address
  description = "Anycast IPv4 for the global external Application Load Balancer."
}

output "gke_endpoint" {
  value       = google_container_cluster.platform.endpoint
  description = "GKE Autopilot control-plane endpoint."
  sensitive   = true
}
```

### 7.2 Kubernetes manifests — production-grade workload on GKE Autopilot

```yaml
# workload.yaml — deploy with: kubectl apply -f workload.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: courseware
  labels:
    app.kubernetes.io/part-of: teach-plat
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: courseware-api
  namespace: courseware
  annotations:
    # Workload Identity: bind this KSA to a Google service account.
    iam.gke.io/gcp-service-account: courseware-api@teachplat-prod-001.iam.gserviceaccount.com
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: courseware-api
  namespace: courseware
  labels:
    app: courseware-api
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: courseware-api
  template:
    metadata:
      labels:
        app: courseware-api
    spec:
      serviceAccountName: courseware-api
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # Spread Pods across zones so a zonal outage cannot take the service down.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: courseware-api
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: courseware-api
      containers:
        - name: api
          image: us-central1-docker.pkg.dev/teachplat-prod-001/apps/courseware-api:1.14.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: PORT
              value: "8080"
            - name: GOMEMLIMIT
              value: "900MiB"
          # On Autopilot the *requests* are the bill. Set them deliberately.
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
              ephemeral-storage: "1Gi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
              ephemeral-storage: "1Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
      terminationGracePeriodSeconds: 60
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: courseware-api
  namespace: courseware
  annotations:
    # Container-native load balancing: the LB targets Pod IPs directly (NEGs),
    # removing the kube-proxy hop and giving accurate health and load data.
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"default": "courseware-api-backendconfig"}'
spec:
  type: ClusterIP
  selector:
    app: courseware-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: courseware-api-backendconfig
  namespace: courseware
spec:
  timeoutSec: 30
  connectionDraining:
    drainingTimeoutSec: 60
  healthCheck:
    checkIntervalSec: 5
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    type: HTTP
    requestPath: /readyz
    port: 8080
  logging:
    enable: true
    sampleRate: 1.0
  cdn:
    enabled: false
  securityPolicy:
    name: edge-armor-policy
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: courseware-api
  namespace: courseware
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: courseware-api
  minReplicas: 3
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: courseware-api
  namespace: courseware
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: courseware-api
```

**Gateway API front door** (the modern replacement for `Ingress` on GKE):

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-gateway
  namespace: courseware
spec:
  gatewayClassName: gke-l7-global-external-managed   # global anycast, Premium Tier
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        options:
          networking.gke.io/pre-shared-certs: web-cert
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: courseware-route
  namespace: courseware
spec:
  parentRefs:
    - name: external-gateway
  hostnames:
    - "study.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: courseware-api
          port: 80
      timeouts:
        request: 30s
---
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: courseware-api-policy
  namespace: courseware
spec:
  default:
    timeoutSec: 30
    connectionDraining:
      drainingTimeoutSec: 60
    securityPolicy: edge-armor-policy
    logging:
      enabled: true
      sampleRate: 1000000
  targetRef:
    group: ""
    kind: Service
    name: courseware-api
---
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: courseware-api-hc
  namespace: courseware
spec:
  default:
    checkIntervalSec: 5
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: HTTP
      httpHealthCheck:
        port: 8080
        requestPath: /readyz
  targetRef:
    group: ""
    kind: Service
    name: courseware-api
```

### 7.3 Cloud Run service — declarative YAML

```yaml
# service.yaml — deploy with:
#   gcloud run services replace service.yaml --region us-central1
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: courseware-web
  labels:
    cloud.googleapis.com/location: us-central1
  annotations:
    run.googleapis.com/ingress: all           # or internal-and-cloud-load-balancing
    run.googleapis.com/launch-stage: GA
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"    # 1 warm instance kills cold starts
        autoscaling.knative.dev/maxScale: "100"  # hard cost ceiling
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/cpu-throttling: "false"  # CPU always allocated
        run.googleapis.com/startup-cpu-boost: "true"
        # Direct VPC egress: reach private resources with no connector VMs.
        run.googleapis.com/network-interfaces: >-
          [{"network":"core-vpc","subnetwork":"workloads-us-central1"}]
        run.googleapis.com/vpc-access-egress: private-ranges-only
    spec:
      containerConcurrency: 80
      timeoutSeconds: 300
      serviceAccountName: courseware-web@teachplat-prod-001.iam.gserviceaccount.com
      containers:
        - image: us-central1-docker.pkg.dev/teachplat-prod-001/apps/courseware-web:2.3.0
          ports:
            - name: http1
              containerPort: 8080
          env:
            - name: API_BASE
              value: "https://study.example.com/api"
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: courseware-db-password
                  key: latest
          resources:
            limits:
              cpu: "2"
              memory: 1Gi
          startupProbe:
            httpGet:
              path: /healthz
            failureThreshold: 10
            periodSeconds: 3
          livenessProbe:
            httpGet:
              path: /healthz
            periodSeconds: 30
  traffic:
    - percent: 100
      latestRevision: true
```

---

## 8. CLI sessions with real output

### 8.1 Inventory: what am I buying, and where?

```console
$ gcloud config set project teachplat-prod-001
Updated property [core/project].

$ gcloud compute regions list --filter="name~us-central1 OR name~southamerica-east1" \
    --format="table(name, quotas[0].metric, quotas[0].limit, status)"
NAME                 METRIC  LIMIT   STATUS
southamerica-east1   CPUS    72.0    UP
us-central1          CPUS    2400.0  UP

$ gcloud compute zones list --filter="region:us-central1" --format="value(name,status)"
us-central1-a	UP
us-central1-b	UP
us-central1-c	UP
us-central1-f	UP

$ gcloud compute machine-types describe n2-standard-8 --zone us-central1-a \
    --format="yaml(name,guestCpus,memoryMb,maximumPersistentDisks)"
guestCpus: 8
maximumPersistentDisks: 128
memoryMb: 32768
name: n2-standard-8
```

### 8.2 Compute Engine: a Spot VM, and what preemption looks like

```console
$ gcloud compute instances create batch-worker-01 \
    --zone=us-central1-a \
    --machine-type=n2d-standard-16 \
    --provisioning-model=SPOT \
    --instance-termination-action=DELETE \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-type=pd-balanced --boot-disk-size=100GB \
    --subnet=workloads-us-central1 --no-address \
    --service-account=mig-workload@teachplat-prod-001.iam.gserviceaccount.com \
    --scopes=cloud-platform \
    --metadata=enable-oslogin=TRUE
Created [https://www.googleapis.com/compute/v1/projects/teachplat-prod-001/zones/us-central1-a/instances/batch-worker-01].
NAME             ZONE           MACHINE_TYPE     PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP  STATUS
batch-worker-01  us-central1-a  n2d-standard-16  true         10.10.0.14                RUNNING

$ gcloud compute instances describe batch-worker-01 --zone us-central1-a \
    --format="yaml(scheduling)"
scheduling:
  automaticRestart: false
  instanceTerminationAction: DELETE
  onHostMaintenance: TERMINATE
  preemptible: true
  provisioningModel: SPOT

# 41 minutes later the capacity is reclaimed. This is the audit trail:
$ gcloud compute operations list --filter="targetLink~batch-worker-01" \
    --format="table(name, operationType, status, statusMessage)"
NAME                                  OPERATION_TYPE  STATUS  STATUS_MESSAGE
systemevent-1757310488291-62f0a...    compute.instances.preempted  DONE  Instance was preempted.

$ gcloud logging read \
    'resource.type="gce_instance" AND protoPayload.methodName="compute.instances.preempted"' \
    --limit=1 --format="value(timestamp, protoPayload.resourceName)"
2026-09-08T11:48:08.291Z	projects/teachplat-prod-001/zones/us-central1-a/instances/batch-worker-01
```

> **Design lesson:** a Spot VM that is deleted mid-job costs you the whole job unless the job checkpoints. Spot is 60–91% cheaper **only if the workload is restartable**. Otherwise the effective cost is infinite.

### 8.3 GKE Autopilot: create, deploy, observe the per-Pod economics

```console
$ gcloud container clusters create-auto platform-autopilot \
    --region=us-central1 \
    --network=core-vpc --subnetwork=workloads-us-central1 \
    --cluster-secondary-range-name=pods \
    --services-secondary-range-name=services \
    --release-channel=regular \
    --enable-private-nodes --master-ipv4-cidr=172.16.0.0/28
Note: The Kubelet readonly port (10255) is now deprecated.
Creating cluster platform-autopilot in us-central1... Cluster is being health-checked...working.
Created [https://container.googleapis.com/v1/projects/teachplat-prod-001/zones/us-central1/clusters/platform-autopilot].
NAME                LOCATION     MASTER_VERSION      MASTER_IP      MACHINE_TYPE  NODE_VERSION        NUM_NODES  STATUS
platform-autopilot  us-central1  1.32.4-gke.1106006  34.72.118.204  e2-medium     1.32.4-gke.1106006  3          RUNNING

$ gcloud container clusters get-credentials platform-autopilot --region us-central1
Fetching cluster endpoint and auth data.
kubeconfig entry generated for platform-autopilot.

$ kubectl apply -f workload.yaml
namespace/courseware created
serviceaccount/courseware-api created
deployment.apps/courseware-api created
service/courseware-api created
backendconfig.cloud.google.com/courseware-api-backendconfig created
horizontalpodautoscaler.autoscaling/courseware-api created
poddisruptionbudget.policy/courseware-api created

$ kubectl -n courseware get pods -o wide
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE                                    NOMINATED NODE
courseware-api-6b8d4c9f77-4kv2p   1/1     Running   0          92s   10.20.1.37   gk3-platform-autopilot-nap-1f3k...-a   <none>
courseware-api-6b8d4c9f77-h9xqd   1/1     Running   0          92s   10.20.3.12   gk3-platform-autopilot-nap-8dj2...-b   <none>
courseware-api-6b8d4c9f77-t2mrb   1/1     Running   0          92s   10.20.5.61   gk3-platform-autopilot-nap-p0xw...-f   <none>

# Confirm the zonal spread the topologySpreadConstraints asked for:
$ kubectl -n courseware get pods -o json | \
    jq -r '.items[] | .spec.nodeName' | \
    xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' | sort | uniq -c
      1 us-central1-a
      1 us-central1-b
      1 us-central1-f

# Autopilot bills the requests, so read them back explicitly:
$ kubectl -n courseware get pods -o custom-columns=\
NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory
NAME                              CPU_REQ   MEM_REQ
courseware-api-6b8d4c9f77-4kv2p   500m      1Gi
courseware-api-6b8d4c9f77-h9xqd   500m      1Gi
courseware-api-6b8d4c9f77-t2mrb   500m      1Gi
```

### 8.4 Cloud Run: deploy, scale-to-zero, cold-start reality

```console
$ gcloud run deploy courseware-web \
    --source=. \
    --region=us-central1 \
    --allow-unauthenticated \
    --min-instances=0 --max-instances=100 \
    --concurrency=80 --cpu=2 --memory=1Gi \
    --execution-environment=gen2
Building using Buildpacks and deploying container to Cloud Run service [courseware-web] in project [teachplat-prod-001] region [us-central1]
✓ Building and deploying... Done.
  ✓ Uploading sources...
  ✓ Building Container... Logs are available at [https://console.cloud.google.com/cloud-build/builds/9f1c...].
  ✓ Creating Revision...
  ✓ Routing traffic...
  ✓ Setting IAM Policy...
Done.
Service [courseware-web] revision [courseware-web-00007-x4t] has been deployed
and is serving 100 percent of traffic.
Service URL: https://courseware-web-3n7qk2wjya-uc.a.run.app

# Cold start, zero instances running:
$ curl -o /dev/null -s -w 'connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
    https://courseware-web-3n7qk2wjya-uc.a.run.app/
connect=0.031s ttfb=1.842s total=1.849s

# Warm:
$ curl -o /dev/null -s -w 'connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
    https://courseware-web-3n7qk2wjya-uc.a.run.app/
connect=0.028s ttfb=0.061s total=0.064s

# Buy away the cold start with one warm instance — this is the cost/latency dial:
$ gcloud run services update courseware-web --region us-central1 --min-instances=1
OK Deploying... Done.
Service [courseware-web] revision [courseware-web-00008-b2m] is serving 100 percent of traffic.
```

### 8.5 Storage: classes, lifecycle, and what the tiering actually did

```console
$ gcloud storage buckets create gs://teachplat-prod-001-artifacts \
    --location=US --uniform-bucket-level-access --default-storage-class=STANDARD
Creating gs://teachplat-prod-001-artifacts/...

$ gcloud storage buckets update gs://teachplat-prod-001-artifacts --enable-autoclass
Updating gs://teachplat-prod-001-artifacts/...
  Completed 1

$ gcloud storage buckets describe gs://teachplat-prod-001-artifacts \
    --format="yaml(name,location,locationType,storageClass,autoclass)"
autoclass:
  enabled: true
  terminalStorageClass: ARCHIVE
  toggleTime: '2026-09-08T12:03:41.907000+00:00'
location: US
locationType: multi-region
name: teachplat-prod-001-artifacts
storageClass: STANDARD

$ gcloud storage cp ./course-bundle-2026Q3.tar.zst gs://teachplat-prod-001-artifacts/
Copying file://./course-bundle-2026Q3.tar.zst to gs://teachplat-prod-001-artifacts/course-bundle-2026Q3.tar.zst
  Completed files 1/1 | 4.1GiB/4.1GiB | 118.6MiB/s

$ gcloud storage ls -L gs://teachplat-prod-001-artifacts/course-bundle-2026Q3.tar.zst | \
    grep -E 'Storage class|Content-Length|Time created'
    Content-Length:          4402341888
    Storage class:           STANDARD
    Time created:            Tue, 08 Sep 2026 12:07:55 GMT
```

### 8.6 Load balancer: is it actually serving?

```console
$ gcloud compute backend-services get-health web-backend --global \
    --format="value(status.healthStatus[].instance.basename(), status.healthStatus[].healthState)"
web-4kv2	HEALTHY
web-h9xq	HEALTHY
web-t2mr	HEALTHY

$ gcloud compute forwarding-rules list --global \
    --format="table(name, IPAddress, portRange, target.basename())"
NAME          IP_ADDRESS      PORT_RANGE  TARGET
web-fr-https  34.117.204.61   443-443     web-https-proxy

$ gcloud compute ssl-certificates describe web-cert --global \
    --format="value(managed.status, managed.domainStatus)"
ACTIVE	{'study.example.com': 'ACTIVE'}

$ curl -sI https://study.example.com/ | head -n 6
HTTP/2 200
content-type: text/html
via: 1.1 google
age: 42
cache-control: public, max-age=3600
alt-svc: h3=":443"; ma=2592000
```

`age: 42` and `via: 1.1 google` together are the proof that Cloud CDN served this from an edge cache — that is the egress-cost saving made visible.

### 8.7 The cost levers, from the CLI

```console
$ gcloud recommender recommendations list \
    --project=teachplat-prod-001 \
    --location=us-central1-a \
    --recommender=google.compute.instance.MachineTypeRecommender \
    --format="table(description, primaryImpact.costProjection.cost.units)"
DESCRIPTION                                                          UNITS
Save cost by changing machine type from n2-standard-8 to n2-standard-4.  -117

$ gcloud compute commitments create prod-cud-3y \
    --region=us-central1 \
    --plan=THIRTY_SIX_MONTH \
    --resources=vcpu=200,memory=800GB \
    --type=GENERAL_PURPOSE_N2
Created [https://www.googleapis.com/compute/v1/projects/teachplat-prod-001/regions/us-central1/commitments/prod-cud-3y].

$ gcloud compute commitments list --format="table(name, region, plan, status, resources[].amount)"
NAME          REGION       PLAN              STATUS  AMOUNT
prod-cud-3y   us-central1  THIRTY_SIX_MONTH  ACTIVE  ['200', '819200']

$ gcloud compute project-info describe --format="value(quotas.filter(metric:CPUS).extract(metric,usage,limit))"
CPUS	412.0	2400.0
```

---

## 9. Verification and failure diagnosis

### 9.1 Verification checklist — run before declaring a landing zone "done"

```console
# 1. Are the workloads actually spread across zones? (the #1 silent SLA killer)
$ gcloud compute instances list --format="value(zone.basename())" | sort | uniq -c
     10 us-central1-a
     10 us-central1-b
     10 us-central1-f

# 2. Is the cluster regional, not zonal?
$ gcloud container clusters list --format="table(name, location, locationType, status)"
NAME                LOCATION     LOCATION_TYPE  STATUS
platform-autopilot  us-central1  REGION         RUNNING

# 3. Are all LB backends healthy, from the LB's own view (not curl)?
$ gcloud compute backend-services get-health web-backend --global | grep -c 'HEALTHY'
3

# 4. Do any VMs have public IPs they should not have?
$ gcloud compute instances list \
    --format="value(name, networkInterfaces[0].accessConfigs[0].natIP)" | grep -v '^\S*\s*$'
(no output — correct)

# 5. Is private egress working through Cloud NAT?
$ gcloud compute routers get-nat-mapping-info core-nat-router \
    --region us-central1 --format="value(instanceName, natIpPortRanges)" | head -3
web-4kv2	['34.72.9.14:1024-1151']
web-h9xq	['34.72.9.14:1152-1279']
web-t2mr	['34.72.9.14:1280-1407']

# 6. Is anything running that nobody claims? (cost hygiene)
$ gcloud compute disks list --filter="-users:*" --format="table(name, zone.basename(), sizeGb, type.basename())"
NAME                  ZONE           SIZE_GB  TYPE
orphan-data-2025      us-central1-b  2048     pd-ssd
```

That last one — an unattached 2 TB `pd-ssd` — is billed at full price forever. Orphaned disks, unused static IPs, and idle load balancers are the three most common line items in a "why is the bill higher than the datacenter" post-mortem.

### 9.2 Failure catalogue

| Symptom / error string | Root cause | Diagnosis | Fix |
|---|---|---|---|
| `ZONE_RESOURCE_POOL_EXHAUSTED` on instance create | Google is out of that machine type in that zone right now | `gcloud compute instances create ... --zone` fails; a sibling zone succeeds | Use a **regional MIG** with multiple `distribution_policy_zones`; for guaranteed capacity, buy a **reservation**; consider a different machine family |
| `QUOTA_EXCEEDED` / `Quota 'CPUS' exceeded. Limit: 24.0` | Project quota, not capacity | `gcloud compute project-info describe`, or Console → IAM → Quotas | Request a quota increase; quota is per-project **and** per-region |
| VM `RUNNING`, app unreachable, LB shows `UNHEALTHY` | Health-check source ranges blocked | `gcloud compute backend-services get-health ...`; check firewall | Allow **35.191.0.0/16** and **130.211.0.0/22** to the backend port |
| LB returns `502` with `failed_to_pick_backend` in logs | No healthy backend, or wrong `port_name` mapping | `gcloud logging read 'resource.type="http_load_balancer" AND jsonPayload.statusDetails!=""'` | Fix health check path/port; verify the MIG `named_port` matches the backend service `port_name` |
| LB returns `502` with `backend_connection_closed_before_data_sent_to_client` | Backend keepalive timeout shorter than the LB's | Compare app server keepalive vs. LB (`timeoutSec`) | Set backend keepalive **> 620 s**, or lower the LB timeout accordingly |
| GKE Pods `Pending`, event `IP_SPACE_EXHAUSTED` | Pod secondary range too small for nodes × max-pods-per-node | `kubectl describe pod`; `gcloud compute networks subnets describe` | Add a discontiguous Pod CIDR, or lower `--max-pods-per-node`. **Size Pod ranges at build time — this is painful to change later** |
| Spot VMs vanish in waves | Regional capacity reclaimed | `compute.instances.preempted` operations (§8.2) | Checkpoint the workload; mix Spot with an on-demand baseline; spread across zones and machine families |
| Cloud NAT: intermittent connection failures, `nat_allocation_failed` | NAT port exhaustion | `gcloud logging read 'resource.type="nat_gateway" AND jsonPayload.allocation_status="DROPPED"'` | Enable **dynamic port allocation**, raise `max_ports_per_vm`, add NAT IPs |
| Cloud Run: `503` under a traffic spike | `maxScale` ceiling reached, or backend (e.g. Cloud SQL) connection limit hit | Cloud Run metrics: instance count pinned at max; check `container_instance_count` | Raise `maxScale`; add connection pooling; raise `containerConcurrency` if the app is I/O-bound |
| Cloud Run: p99 latency spikes every few minutes | Cold starts from scale-to-zero | Compare cold vs. warm TTFB (§8.4) | `--min-instances=1..N`, `--startup-cpu-boost`, shrink the image |
| Autopilot rejects a Pod: `pods ... is forbidden: violates PodSecurity` / hostPath denied | Autopilot's node-security constraints | `kubectl describe replicaset` for the admission message | Remove privileged/hostPath requirements, or move that workload to **GKE Standard** |
| Interconnect/VPN path: large packets hang, small ones succeed | MTU mismatch / PMTUD blackhole | `ping -M do -s 1400 <peer>` succeeds, `-s 1500` fails | Align VPC MTU with the peer (1460 default; up to 8896 supported); ensure ICMP type 3 code 4 is permitted |
| Disk-bound DB, CPU idle, `await` high | PD IOPS ceiling tied to disk size / VM vCPU count | `iostat -x 1`; compare against the documented PD performance table | Grow the disk, switch to `pd-ssd`, or move to **Hyperdisk** and provision IOPS independently |
| "The cloud is more expensive than the datacenter" | On-demand pricing, no CUD/SUD, over-provisioned 1:1 sizing, orphaned resources | `gcloud recommender recommendations list`; billing export → BigQuery | Rightsize (§8.7), commit (CUDs), Spot the batch tier, delete orphans, set budget alerts |

### 9.3 The one diagnostic query to memorize

```console
$ gcloud logging read \
    'resource.type="http_load_balancer"
     AND httpRequest.status>=500
     AND timestamp>="2026-09-08T00:00:00Z"' \
    --limit=5 \
    --format="table(timestamp, httpRequest.status, jsonPayload.statusDetails, httpRequest.requestUrl)"
TIMESTAMP                       STATUS  STATUS_DETAILS               REQUEST_URL
2026-09-08T13:41:02.118Z        502     failed_to_pick_backend       https://study.example.com/api/topics
2026-09-08T13:41:02.402Z        502     failed_to_pick_backend       https://study.example.com/api/topics
2026-09-08T13:40:58.771Z        503     backend_connection_closed... https://study.example.com/api/render
```

`jsonPayload.statusDetails` is the field that turns "the site is 502-ing" into a specific, actionable root cause. It is the single highest-value field in Google Cloud load-balancer logging.

---

## 10. Business value, computed

### 10.1 TCO worked example

**Scenario:** 100 × `n2-standard-8` (8 vCPU / 32 GB) in `us-central1`, running 24×7. Illustrative on-demand price ≈ **$0.3885/hour** (8 × $0.031611 vCPU-hr + 32 × $0.004237 GB-hr). Always re-derive with the Pricing Calculator; prices change.

| Strategy | Per-VM effective $/hr | 100 VMs / month (730 h) | Annual | Δ vs on-demand |
|---|---|---|---|---|
| On-demand, no discount | 0.3885 | $28,361 | $340,332 | — |
| On-demand + sustained use discount (illustrative ~20% for N2 at 100% month) | 0.3108 | $22,688 | $272,256 | −20% |
| 1-year resource-based CUD (~37%) | 0.2448 | $17,870 | $214,440 | −37% |
| **3-year resource-based CUD (~55%)** | 0.1748 | $12,760 | $153,120 | **−55%** |
| 60 VMs on 3-yr CUD + 40 VMs Spot (~70% off) | mixed | $10,057 | $120,684 | **−65%** |
| Rightsized to `n2-standard-4` for the 40% of the fleet that is over-provisioned, then 3-yr CUD | mixed | $10,208 | $122,496 | −64% |

**The lesson the exam wants and production enforces:** the migration itself does not save money. **Rightsizing + commitment + provisioning model** saves money, and those are three separate deliberate acts. A 1:1 lift-and-shift at on-demand prices is the *most expensive* possible outcome, and it is the default one.

**Discount instrument reference:**

| Instrument | Applies automatically? | Term | Scope | Trade-off |
|---|---|---|---|---|
| Sustained use discount (SUD) | Yes | none | Eligible families (N1 historically up to ~30%; N2/N2D/C2/C2D up to ~20%); newer families often excluded — verify on the pricing page | None; free |
| Resource-based CUD | No — you purchase | 1 or 3 years | Specific vCPU/memory in one region and family | You pay whether you use it or not |
| Spend-based / flexible CUD | No — you purchase | 1 or 3 years | A $/hour spend commitment, flexible across families/regions | Lower discount than resource-based, far more flexibility |
| Spot VMs | No — a provisioning model | none | Any eligible VM | Preemption; requires restartable workloads |
| Reservations | No | none (or with CUD) | Specific zone/machine type | You pay for reserved capacity even when idle; guarantees availability |

### 10.2 Availability arithmetic — why placement *is* the SLA

Serial dependencies multiply. A three-tier stack, all in one zone:

```
A_total = A_compute × A_database × A_storage
        = 0.999 × 0.999 × 0.999
        = 0.997002  →  ~99.70%  →  ~2.6 hours of downtime per month
```

The same stack spread across zones within a region, fronted by a global LB:

```
A_total = A_LB × A_compute(multi-zone) × A_database(HA) × A_storage(regional)
        = 0.9999 × 0.9999 × 0.9995 × 0.999
        = 0.998301  →  ~99.83%
```

…and the dominant term is now the *lowest-SLA component*, not the compute layer. That is the correct engineering conclusion: **once you spread compute, your availability ceiling is set by your weakest managed dependency**, so the next investment goes there — not into more compute redundancy.

**Representative SLAs** (always confirm on the SLA page in §12, they are contractual and versioned):

| Service | SLA |
|---|---|
| Compute Engine, single instance | 99.9% |
| Compute Engine, multi-zone (LB across ≥2 zones) | 99.99% |
| GKE regional control plane / zonal control plane | 99.95% / 99.5% |
| Cloud Run | 99.95% |
| Cloud Load Balancing | 99.99% |
| Cloud DNS | 100% |
| Cloud Storage — multi-region Standard / regional Standard | 99.95% / 99.9% |
| Cloud SQL, HA configuration | 99.95% |
| HA VPN (two interfaces) / Dedicated Interconnect (99.99% topology) | 99.99% / 99.99% |

> **An SLA is a refund contract, not a promise of uptime.** Credits do not compensate for a lost quarter of revenue. Design to the SLO you actually need; use the SLA to pick the *architecture tier* that makes that SLO achievable.

### 10.3 Non-financial business value (state these explicitly in a design review)

| Value | Mechanism | How to measure it |
|---|---|---|
| **Time to market** | `gcloud run deploy` replaces a procurement cycle | Lead time for change (DORA) |
| **Elasticity** | Autoscaling absorbs peaks that used to require 12 months of peak-sized capex | Peak:trough capacity ratio; cost per peak event |
| **Risk transfer** | Google owns hardware failure, physical security, and (in managed tiers) patching | Reduction in unplanned ops hours |
| **Reach** | A global anycast IP puts your service on the backbone in every region at once | p95 latency by geography, before/after |
| **Sustainability** | Google matches its annual electricity consumption with renewable energy purchases and publishes per-region carbon data; Active Assist surfaces low-carbon region choices | Reported gross carbon footprint; region CFE% |
| **Focus** | Engineers stop racking, patching, and capacity-planning | % of engineering time on product vs. undifferentiated ops |

---

## 11. Exam-oriented mapping and traps

### 11.1 Scenario → answer

| Scenario in the question | Correct offering | Why |
|---|---|---|
| "Migrate our VMware datacenter in 12 months with minimal changes" | **Google Cloud VMware Engine** | Same hypervisor, same tooling, no re-platform |
| "We run Oracle on hardware we cannot virtualize due to licensing" | **Bare Metal Solution** | Physical, certified, adjacent to the region |
| "Our batch rendering can tolerate interruptions and we want it cheap" | Compute Engine with **Spot VMs** | 60–91% discount, restartable workload |
| "Predictable 24×7 production VMs for the next 3 years" | Compute Engine + **3-year committed use discount** | Steady state is exactly what CUDs price for |
| "A containerized microservice platform for many teams, minimal ops staff" | **GKE Autopilot** | Google manages nodes; per-Pod billing enables chargeback |
| "Spiky web API, idle at night, we don't want to manage servers" | **Cloud Run** | Scale to zero, per-request billing |
| "Resize an image whenever a file lands in a bucket" | **Cloud Run functions** | Event-driven, single-purpose |
| "Store 7 years of compliance records, accessed once a year" | **Cloud Storage Archive** + Bucket Lock | Lowest storage price, immutable retention |
| "Serve a global audience from one IP with DDoS protection" | Global external Application LB + **Cloud CDN** + **Cloud Armor** on Premium Tier | Anycast + edge caching + WAF |
| "500 TB to move and a 1 Gbps link" | **Transfer Appliance** | The WAN math does not close |
| "Dedicated private 10 Gbps to our colo with predictable latency" | **Dedicated Interconnect** | Physical circuit; lower egress rates |
| "Private connectivity in days, not months, moderate bandwidth" | **HA VPN** | IPsec over internet, 99.99% SLA |
| "Which region has the lowest carbon and meets EU data residency?" | Region selection using published carbon-free energy data + EU regions | Region choice is a first-class design decision |

### 11.2 Traps that catch experienced engineers

1. **"Multi-region" ≠ "multi-zone."** A regional Cloud Storage bucket survives a zone loss; it does not survive a region loss. Read the location type, not the region name.
2. **Zone letters are per-project.** `us-central1-a` in your project is not necessarily the same physical zone as in another project. Never coordinate a cross-project design around zone letters.
3. **Archive is not tape.** First-byte latency is milliseconds. Questions implying "hours to restore" are describing a competitor's product or an old mental model.
4. **The VPC is global.** Any answer requiring a gateway/VPN for two regions *inside the same VPC* is wrong.
5. **Global load balancing requires Premium Tier.** If the scenario says "cheapest egress" *and* "single global IP," those are in tension — read which one the question actually prioritizes.
6. **Preemptible ≠ Spot.** Spot is the current model, no 24-hour cap. Legacy Preemptible VMs had one.
7. **Autopilot is not "GKE but cheaper."** It is cheaper for spiky, well-sized workloads and can be *more* expensive for dense, highly-utilized fleets where you were already bin-packing well.
8. **Local SSD is ephemeral.** Any question pairing "local SSD" with "must survive restart" is a distractor.
9. **The SLA is conditional on your architecture.** 99.99% on Compute Engine requires instances in **two or more zones** behind a load balancer. A single VM never gets 99.99%, regardless of machine type.
10. **PD IOPS scale with size *and* vCPU count.** "Just make the disk faster" is not a valid answer on PD — it is on Hyperdisk.

---

## 12. References

**Exam guide**
- Cloud Digital Leader exam guide (PDF): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Certification page: https://cloud.google.com/learn/certification/cloud-digital-leader

**Global infrastructure**
- Global locations — regions and zones: https://cloud.google.com/about/locations
- Geography and regions concept: https://cloud.google.com/docs/geography-and-regions
- Regions and zones (Compute Engine): https://cloud.google.com/compute/docs/regions-zones
- Carbon-free energy for Google Cloud regions: https://cloud.google.com/sustainability/region-carbon

**Compute**
- Compute Engine documentation: https://cloud.google.com/compute/docs
- Machine families resource and comparison guide: https://cloud.google.com/compute/docs/machine-resource
- Spot VMs: https://cloud.google.com/compute/docs/instances/spot
- Managed instance groups: https://cloud.google.com/compute/docs/instance-groups
- Sole-tenant nodes: https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes
- Google Kubernetes Engine documentation: https://cloud.google.com/kubernetes-engine/docs
- GKE Autopilot overview: https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview
- Autopilot vs Standard comparison: https://cloud.google.com/kubernetes-engine/docs/resources/autopilot-standard-feature-comparison
- Cloud Run documentation: https://cloud.google.com/run/docs
- Cloud Run functions: https://cloud.google.com/functions/docs
- App Engine documentation: https://cloud.google.com/appengine/docs
- Bare Metal Solution: https://cloud.google.com/bare-metal/docs
- Google Cloud VMware Engine: https://cloud.google.com/vmware-engine/docs

**Storage**
- Cloud Storage documentation: https://cloud.google.com/storage/docs
- Storage classes: https://cloud.google.com/storage/docs/storage-classes
- Object Lifecycle Management: https://cloud.google.com/storage/docs/lifecycle
- Autoclass: https://cloud.google.com/storage/docs/autoclass
- Persistent Disk and Hyperdisk (storage options): https://cloud.google.com/compute/docs/disks
- Hyperdisk: https://cloud.google.com/compute/docs/disks/hyperdisks
- Local SSD: https://cloud.google.com/compute/docs/disks/local-ssd
- Filestore: https://cloud.google.com/filestore/docs
- Google Cloud NetApp Volumes: https://cloud.google.com/netapp/volumes/docs

**Networking**
- VPC overview: https://cloud.google.com/vpc/docs/vpc
- Shared VPC: https://cloud.google.com/vpc/docs/shared-vpc
- Network Service Tiers: https://cloud.google.com/network-tiers/docs/overview
- Cloud Load Balancing overview: https://cloud.google.com/load-balancing/docs/load-balancing-overview
- Choosing a load balancer: https://cloud.google.com/load-balancing/docs/choosing-load-balancer
- Cloud CDN: https://cloud.google.com/cdn/docs
- Cloud Armor: https://cloud.google.com/armor/docs
- Cloud DNS: https://cloud.google.com/dns/docs
- Cloud NAT: https://cloud.google.com/nat/docs/overview
- Cloud Interconnect: https://cloud.google.com/network-connectivity/docs/interconnect
- Cloud VPN (HA VPN): https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview
- Private Service Connect: https://cloud.google.com/vpc/docs/private-service-connect
- Network Connectivity Center: https://cloud.google.com/network-connectivity/docs/network-connectivity-center

**Migration**
- Migration Center: https://cloud.google.com/migration-center/docs
- Migrate to Virtual Machines: https://cloud.google.com/migrate/virtual-machines/docs
- Migrate to Containers: https://cloud.google.com/migrate/containers/docs
- Database Migration Service: https://cloud.google.com/database-migration/docs
- Storage Transfer Service: https://cloud.google.com/storage-transfer/docs
- Transfer Appliance: https://cloud.google.com/transfer-appliance/docs

**Cost and reliability**
- Google Cloud Pricing Calculator: https://cloud.google.com/products/calculator
- Committed use discounts: https://cloud.google.com/docs/cus-discounts
- Sustained use discounts: https://cloud.google.com/compute/docs/sustained-use-discounts
- Compute Engine pricing: https://cloud.google.com/compute/all-pricing
- Google Cloud service level agreements: https://cloud.google.com/terms/sla
- Architecture Framework — reliability: https://cloud.google.com/architecture/framework/reliability
- Architecture Framework — cost optimization: https://cloud.google.com/architecture/framework/cost-optimization
- Active Assist / Recommender: https://cloud.google.com/recommender/docs

**Reference architectures used in the manifests**
- GKE container-native load balancing (NEGs): https://cloud.google.com/kubernetes-engine/docs/concepts/container-native-load-balancing
- GKE Gateway API: https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api
- Cloud Run YAML reference: https://cloud.google.com/run/docs/reference/yaml/v1
- Terraform Google provider: https://registry.terraform.io/providers/hashicorp/google/latest/docs