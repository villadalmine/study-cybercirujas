# 4.1 — How Google Cloud Helps Organizations Transition to the Cloud

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12)
**Domain weight:** 6.0
**Reading profile:** Platform Architect / SRE. The exam asks this at a business-outcome level; this material teaches the machinery underneath, so that the business answer is one you can defend in a design review.

---

## 1. Motivation: the architectural problem a "cloud transition" actually is

A migration is almost never a technology problem in isolation. It is a **dependency-graph problem executed under a change freeze, with a rollback clock**.

Consider the canonical production case. An organization runs 1,400 VMs across three VMware clusters in two colocation facilities. Storage is 800 TB on NFS and iSCSI. Databases are 60 MySQL 8.0 instances, 22 PostgreSQL 14 instances, and one Oracle RAC pair nobody is allowed to touch. There is an MPLS WAN, a pair of physical load balancers, and a hardware HSM. Business constraints: the hardware lease expires in 14 months, the finance-close window forbids changes for 5 business days each month, and the payments service has a 99.95% availability SLO with a 21.6 min/month error budget.

The naive framing — "move the VMs" — fails on four fronts that every real program hits:

| Failure mode | Concrete symptom | Root cause |
|---|---|---|
| **Unknown dependency graph** | An app moves cleanly; a batch job in a *different* datacenter breaks at 02:00 because it mounted an NFS export by IP. | Discovery was inventory-based (a CMDB), not traffic-based. Nobody captured L4 flows. |
| **Latency inversion / split-brain** | App tier in Google Cloud, database still on-prem. p99 goes from 40 ms to 900 ms. | A chatty ORM issuing 300 round trips per request now pays 12 ms RTT per hop instead of 0.2 ms. |
| **Data gravity** | 800 TB over a 1 Gbps link is ~74 days at 100% utilization — and the source keeps changing. | The transfer method was chosen without computing time-to-transfer against the delta rate. |
| **Governance debt materializing at scale** | 300 projects created ad hoc; no consistent IAM, no org policy, public IPs everywhere, six months of remediation. | The landing zone was retrofitted instead of being the first deliverable. |

Google Cloud's answer is not a single product. It is a **staged program model with tooling attached to each stage**, and the exam expects you to be able to name the stage and the tool.

### The four phases

```
   ASSESS            PLAN              DEPLOY             OPTIMIZE
   ──────            ────              ──────             ────────
 Inventory        Landing zone      Move workloads      Rightsize
 Dependencies     Identity          Move data           Autoscale
 TCO baseline     Network design    Cut over            Commit discounts
 Fit analysis     Resource hier.    Validate            Modernize further
 Skills gap       Migration waves   Rollback ready      SLO/error budget

 Migration        Cloud Setup /     M2VM, M2C, DMS,     Active Assist,
 Center,          landing-zone      Storage Transfer,   Recommender,
 StratoZone       blueprints,       Transfer Appliance, CUDs, FinOps Hub,
 discovery        Terraform CFT     BigQuery DTS        GKE Autopilot
```

Two orthogonal frameworks sit alongside it, and both are directly examinable:

- **Google Cloud Adoption Framework (CAF)** — measures *organizational* readiness on four themes (**Learn, Lead, Scale, Secure**) across three maturity phases (**Tactical → Strategic → Transformational**). Output: a set of *epics* (workstreams) to close gaps.
- **CAMP** — the cultural/DevOps model: **C**ulture, **A**utomation, **M**easurement, **S**haring. This is where SRE practice (SLOs, error budgets, blameless postmortems, toil reduction) formally enters the migration program.

> **Exam framing:** CAF measures *readiness*; the four phases describe *execution*. A question that says "the CTO wants to know if the organization is ready" points at CAF. A question that says "the team has an inventory and needs to move 400 VMs" points at Assess→Deploy tooling.

---

## 2. Migration strategy: the trade-off table you must be able to reproduce

Google's guidance names four principal paths (the industry "6 Rs" collapse into these plus *retire* and *retain*):

| Strategy | Google's term | What changes | Time to first workload | Cost of change | Cloud-native benefit realized | Typical failure |
|---|---|---|---|---|---|---|
| **Rehost** | Lift and shift | Nothing above the hypervisor | Days–weeks | Lowest | Lowest — you pay cloud prices for datacenter architecture | "Lift and shift and forget": 3× the bill, none of the elasticity |
| **Replatform** | Move and improve *(or improve and move)* | Managed runtime/DB swap; app code mostly intact | Weeks–months | Medium | Medium–high: patching, HA, backup become managed | Hidden incompatibilities (stored procs, filesystem assumptions) |
| **Refactor / re-architect** | Rip and replace / *invent* | Application decomposed; often to containers or serverless | Months–quarters | Highest | Highest | Scope explosion; the migration deadline is missed while a rewrite happens |
| **Retire** | — | Workload deleted | Immediate | Negative (savings) | N/A | Nobody owns the decision; it stays "just in case" |
| **Retain** | — | Stays on-prem / hybrid | N/A | N/A | N/A via hybrid runtime (GKE Enterprise) | Becomes a permanent latency anchor for everything else |

**The architect's rule:** strategy is chosen *per workload*, not per program, and the choice is a function of three measurable inputs — **remaining lease/refresh time**, **change budget**, and **dependency fan-in**.

### Decision heuristic (production-usable)

```
if workload has no owner and <1 request/day for 90 days      -> RETIRE
elif regulatory/hardware pin (HSM, licence, latency <2ms)    -> RETAIN (hybrid via GKE Enterprise)
elif deadline < 6 months and dependency fan-in > 10          -> REHOST  (then replatform in Optimize)
elif stateful managed equivalent exists (MySQL/PG/Redis/Kafka)-> REPLATFORM (Cloud SQL / Memorystore / Managed Kafka)
elif team owns the code AND release cadence > weekly         -> REFACTOR (GKE / Cloud Run)
else                                                          -> REHOST
```

Note the sequencing implication: **rehost first, modernize second** is not laziness, it is error-budget management. You do not want two simultaneous sources of novel failure (new infrastructure *and* new application topology) sharing one rollback window.

### Google Cloud tool per strategy

| Strategy | Primary Google tooling | Secondary |
|---|---|---|
| Rehost (VMware/AWS/Azure/physical → Compute Engine) | **Migrate to Virtual Machines (M2VM)** | Google Cloud VMware Engine (rehost *with* vSphere intact) |
| Rehost with zero re-IP | **Google Cloud VMware Engine (GCVE)** | Cloud Interconnect + HCX |
| Replatform (DB) | **Database Migration Service (DMS)** | Datastream (CDC to BigQuery), `pg_dump`/`mysqldump` for cold moves |
| Replatform (app → container, no rewrite) | **Migrate to Containers (M2C)** | Cloud Build + Artifact Registry |
| Refactor | GKE / GKE Autopilot / Cloud Run / Cloud Functions | Apigee for API-first decomposition |
| Bulk data | **Storage Transfer Service**, **Transfer Appliance**, BigQuery Data Transfer Service | `gcloud storage rsync`, Datastream |
| Hybrid / retain | **GKE Enterprise** (fleets, Config Sync, Cloud Service Mesh) | Cloud Interconnect, Network Connectivity Center |

---

## 3. Phase 1 — ASSESS: discovery that produces a defensible plan

### 3.1 Migration Center

Migration Center is the free, first-party assessment service (built on the StratoZone acquisition). It provides:

- **Asset inventory** — from a deployed *discovery client*, from vCenter/AWS/Azure exports, or from manual CSV/RVTools import.
- **Guest-level collection** — installed software, running processes, open ports, CPU/memory/disk utilization time series.
- **Network dependency mapping** — observed L4 flows, which is the only reliable way to build migration *waves*.
- **Fit assessment** — which VMs fit Compute Engine machine families, which fit sole-tenant, which fit GKE.
- **TCO / pricing reports** — driven by *preference sets* (commitment level, region, licence model, sizing aggressiveness).

Cost model: assessment is at no charge; you pay only for what you eventually run.

### 3.2 CLI walkthrough

```bash
$ gcloud config set project acme-migration-prog
Updated property [core/project].

$ gcloud services enable migrationcenter.googleapis.com \
    compute.googleapis.com \
    cloudresourcemanager.googleapis.com
Operation "operations/acat.p2-812394871-3f1c9e0d-..." finished successfully.
```

Create the group that will hold the wave, then a discovery client:

```bash
$ gcloud migration-center groups create wave-01-payments \
    --location=us-central1 \
    --display-name="Wave 01 - Payments" \
    --description="Payments API + MySQL, colo-A"
Create request issued for: [wave-01-payments]
Waiting for operation [projects/acme-migration-prog/locations/us-central1/operations/op-71a2] to complete... done.
Created group [wave-01-payments].

$ gcloud migration-center discovery-clients create colo-a-collector \
    --location=us-central1 \
    --display-name="colo-A vCenter collector" \
    --service-account=mc-collector@acme-migration-prog.iam.gserviceaccount.com
Created discovery client [colo-a-collector].
registrationToken: 8f2c1d9e-4b7a-4c11-9d3e-...
```

Once collection has run for at least a full business cycle (**minimum 2 weeks; 4 weeks if you have a monthly close**), inspect assets:

```bash
$ gcloud migration-center assets list --location=us-central1 \
    --filter='attributes.osFamily="LINUX"' \
    --format='table(name.basename(), machineDetails.coreCount, machineDetails.memoryMb, machineDetails.platform.vmwareDetails.osid)'
NAME                 CORE_COUNT  MEMORY_MB  OSID
pay-api-01           8           32768      rhel8_64Guest
pay-api-02           8           32768      rhel8_64Guest
pay-api-03           8           32768      rhel8_64Guest
pay-mysql-01         16          131072     rhel8_64Guest
pay-mysql-02         16          131072     rhel8_64Guest
pay-batch-01         4           16384      ubuntu64Guest
...
Listed 143 items.
```

Add assets to the group and generate the TCO report:

```bash
$ gcloud migration-center groups add-assets wave-01-payments \
    --location=us-central1 \
    --assets-from-file=wave01-assets.txt
Updated group [wave-01-payments]: 143 assets added.

$ gcloud migration-center preference-sets create prod-committed-3y \
    --location=us-central1 \
    --display-name="Prod, 3y CUD, us-central1" \
    --virtual-machine-preferences-file=prefs.yaml
Created preference set [prod-committed-3y].

$ gcloud migration-center reports create tco-wave-01 \
    --location=us-central1 \
    --report-config=rc-wave-01
Waiting for report generation... done.
state: SUCCEEDED
```

`prefs.yaml`:

```yaml
targetProduct: COMPUTE_ENGINE
commitmentPlan: COMMITMENT_PLAN_THREE_YEARS
sizingOptimizationStrategy: SIZING_OPTIMIZATION_STRATEGY_MODERATE
regionPreferences:
  preferredRegions:
    - us-central1
    - us-east4
computeEnginePreferences:
  licenseType: LICENSE_TYPE_BRING_YOUR_OWN_LICENSE
  machinePreferences:
    allowedMachineSeries:
      - code: "n2"
      - code: "n2d"
      - code: "c3"
vmwareEnginePreferences:
  commitmentPlan: ON_DEMAND
  cpuOvercommitRatio: 4.0
```

### 3.3 What "assess" must output before Plan may start

A wave is not ready until all six artifacts exist. This is the gate; enforce it.

| Artifact | Source | Accept criterion |
|---|---|---|
| Asset inventory | Migration Center | 100% of in-scope IPs reconciled against DHCP/DNS |
| Dependency map | MC network flows (≥14 days) | No unexplained inbound flow on a port the app team cannot name |
| Utilization percentiles | MC guest collection | p95 CPU/mem, not average — averages hide the close-window spike |
| Strategy decision | Architecture review | One of rehost/replatform/refactor/retire/retain *per workload* |
| Data volume + delta rate | Storage inventory | GB total **and** GB/day change rate (drives §5) |
| Rollback definition | App owner | Explicit: what state is discarded, and the maximum time to revert |

---

## 4. Phase 2 — PLAN: the landing zone is the first deliverable

Google's landing zone guidance frames four decisions: **identity onboarding, resource hierarchy, network design, security controls**. Every one of them is expensive to change after 200 projects exist.

### 4.1 Resource hierarchy

```
Organization: acme.com
├── Folder: bootstrap            (Terraform state, CI service accounts, seed project)
├── Folder: common               (logging sink, org-wide monitoring, DNS, Interconnect)
├── Folder: environments
│   ├── Folder: prod
│   │   ├── Folder: payments
│   │   │   ├── Project: pay-prod-host      (Shared VPC host)
│   │   │   ├── Project: pay-prod-app       (service project)
│   │   │   └── Project: pay-prod-data      (service project)
│   │   └── Folder: identity
│   ├── Folder: nonprod
│   └── Folder: dev
└── Folder: migration-staging    (M2VM targets, quarantine before promotion)
```

Policy inherits downward; the `migration-staging` folder exists so in-flight rehosted VMs — which will initially violate hardening standards — do not force you to weaken production policy.

### 4.2 Full landing-zone Terraform

```hcl
# ---------------------------------------------------------------------------
# landing-zone/main.tf
# Minimal but complete migration landing zone: hierarchy, org policy,
# Shared VPC, hybrid connectivity prerequisites, logging.
# Terraform >= 1.6, google provider >= 5.x
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
  backend "gcs" {
    bucket = "acme-tfstate-bootstrap"
    prefix = "landing-zone"
  }
}

provider "google" {
  billing_project       = var.seed_project_id
  user_project_override = true
}

variable "org_id"          { type = string }
variable "billing_account" { type = string }
variable "seed_project_id" { type = string }
variable "region"          { type = string  default = "us-central1" }

# ------------------------- Resource hierarchy ------------------------------

resource "google_folder" "common" {
  display_name = "common"
  parent       = "organizations/${var.org_id}"
}

resource "google_folder" "environments" {
  display_name = "environments"
  parent       = "organizations/${var.org_id}"
}

resource "google_folder" "prod" {
  display_name = "prod"
  parent       = google_folder.environments.name
}

resource "google_folder" "migration_staging" {
  display_name = "migration-staging"
  parent       = "organizations/${var.org_id}"
}

# ------------------------- Organization policies ---------------------------
# v2 org policy API. Applied at prod; migration-staging gets an exception
# for external IPs only while replication is in flight.

resource "google_org_policy_policy" "no_external_ip" {
  name   = "${google_folder.prod.name}/policies/compute.vmExternalIpAccess"
  parent = google_folder.prod.name

  spec {
    inherit_from_parent = false
    rules {
      deny_all = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "require_shielded_vm" {
  name   = "${google_folder.prod.name}/policies/compute.requireShieldedVm"
  parent = google_folder.prod.name

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "disable_sa_key_creation" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "restrict_locations" {
  name   = "${google_folder.prod.name}/policies/gcp.resourceLocations"
  parent = google_folder.prod.name

  spec {
    rules {
      values {
        allowed_values = [
          "in:us-central1-locations",
          "in:us-east4-locations",
        ]
      }
    }
  }
}

resource "google_org_policy_policy" "sql_no_public_ip" {
  name   = "${google_folder.prod.name}/policies/sql.restrictPublicIp"
  parent = google_folder.prod.name

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# Exception: M2VM sole-tenant / staging instances may need egress while
# replication bootstraps. Scoped to the staging folder ONLY.
resource "google_org_policy_policy" "staging_external_ip_exception" {
  name   = "${google_folder.migration_staging.name}/policies/compute.vmExternalIpAccess"
  parent = google_folder.migration_staging.name

  spec {
    inherit_from_parent = false
    rules {
      allow_all = "TRUE"
    }
  }
}

# ------------------------- Shared VPC host project -------------------------

resource "google_project" "net_host" {
  name            = "pay-prod-host"
  project_id      = "acme-pay-prod-host"
  folder_id       = google_folder.prod.name
  billing_account = var.billing_account
}

resource "google_project_service" "host_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dns.googleapis.com",
    "networkconnectivity.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
  project            = google_project.net_host.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_shared_vpc_host_project" "host" {
  project    = google_project.net_host.project_id
  depends_on = [google_project_service.host_apis]
}

resource "google_compute_network" "vpc" {
  project                         = google_project.net_host.project_id
  name                            = "vpc-prod"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false
  mtu                             = 1460
  depends_on                      = [google_compute_shared_vpc_host_project.host]
}

resource "google_compute_subnetwork" "app" {
  project                  = google_project.net_host.project_id
  name                     = "sn-prod-app-usc1"
  ip_cidr_range            = "10.40.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.44.0.0/14"
  }
  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.48.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Landing subnet for rehosted VMs — deliberately separate so that the
# on-prem-equivalent address plan can be routed and later retired.
resource "google_compute_subnetwork" "migration_landing" {
  project                  = google_project.net_host.project_id
  name                     = "sn-migration-landing-usc1"
  ip_cidr_range            = "10.60.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# ------------------------- Firewall ----------------------------------------

resource "google_compute_firewall" "allow_iap_ssh" {
  project   = google_project.net_host.project_id
  name      = "allow-iap-ssh-rdp"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 1000

  # IAP TCP forwarding range — removes the need for bastion public IPs.
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }
}

resource "google_compute_firewall" "allow_onprem_to_app" {
  project       = google_project.net_host.project_id
  name          = "allow-onprem-to-app"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 1100
  source_ranges = ["10.10.0.0/16", "10.11.0.0/16"] # colo-A, colo-B

  allow {
    protocol = "tcp"
    ports    = ["443", "3306", "5432"]
  }
  target_tags = ["migrated"]
}

resource "google_compute_firewall" "deny_all_ingress" {
  project   = google_project.net_host.project_id
  name      = "deny-all-ingress"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 65000

  deny { protocol = "all" }
  source_ranges = ["0.0.0.0/0"]
}

# ------------------------- Centralized logging -----------------------------

resource "google_project" "logging" {
  name            = "acme-common-logging"
  project_id      = "acme-common-logging"
  folder_id       = google_folder.common.name
  billing_account = var.billing_account
}

resource "google_logging_project_bucket_config" "audit" {
  project        = google_project.logging.project_id
  location       = "us"
  retention_days = 400
  bucket_id      = "org-audit"
}

resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-sink"
  org_id           = var.org_id
  include_children = true
  destination      = "logging.googleapis.com/projects/${google_project.logging.project_id}/locations/us/buckets/org-audit"

  filter = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR logName:"cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"cloudaudit.googleapis.com%2Fpolicy"
  EOT
}

output "host_project"    { value = google_project.net_host.project_id }
output "vpc_self_link"   { value = google_compute_network.vpc.self_link }
output "landing_subnet"  { value = google_compute_subnetwork.migration_landing.self_link }
```

Apply and verify:

```bash
$ terraform apply -auto-approve
...
Apply complete! Resources: 23 added, 0 changed, 0 destroyed.

Outputs:
host_project = "acme-pay-prod-host"
landing_subnet = "https://www.googleapis.com/compute/v1/projects/acme-pay-prod-host/regions/us-central1/subnetworks/sn-migration-landing-usc1"
vpc_self_link = "https://www.googleapis.com/compute/v1/projects/acme-pay-prod-host/global/networks/vpc-prod"

$ gcloud org-policies describe compute.vmExternalIpAccess \
    --folder=$(terraform output -raw prod_folder_id) --effective
name: folders/482910371829/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

> Google publishes this as opinionated, reusable Terraform: the **Cloud Foundation Toolkit** blueprints and the **Fabric FAST** stages. On the exam, the concept name is *landing zone*; the productized fast path is *Cloud Setup* in the console plus CFT blueprints.

### 4.3 Hybrid connectivity: the trade-off table

Every migration is hybrid for its whole duration. This choice sets your migration throughput ceiling.

| Option | Bandwidth | SLA | Provisioning lead time | Traffic path | Cost shape | When it is the right answer |
|---|---|---|---|---|---|---|
| **HA VPN** | ~3 Gbps per tunnel; scale by adding tunnels | 99.99% (two interfaces, two peers) | Minutes | Over public internet, IPsec-encrypted | Hourly tunnel + egress | Default start; dev/test; <1 TB/day |
| **Classic VPN** | ~3 Gbps per tunnel | 99.9% | Minutes | Public internet | Same | Legacy only — deprecated for new designs |
| **Dedicated Interconnect** | 10 or 100 Gbps circuits, up to 8 (or 2×100G) per attachment set | 99.9% / 99.99% depending on topology | **Weeks–months** (cross-connect, LOA-CFA) | Private, does not traverse internet | Circuit + attachment + egress at reduced rate | Bulk data, sustained >5 TB/day, latency-sensitive hybrid |
| **Partner Interconnect** | 50 Mbps – 50 Gbps VLAN attachments | 99.9% / 99.99% | Days | Private via service provider | Attachment + partner fee | You are not in a colocation facility that peers with Google |
| **Cross-Cloud Interconnect** | 10 / 100 Gbps | 99.9% / 99.99% | Weeks | Private to AWS/Azure/OCI | Circuit-based | Multicloud migration, not on-prem |
| **Direct/Carrier Peering** | Variable | None | Days | Public Google services only, **not VPC** | Egress only | Access to Google APIs — *not* a VPC connectivity option |

Two facts that decide real designs:

1. **Encryption:** Interconnect is private but **not encrypted by default**. If you need encryption over Interconnect, layer HA VPN over it or use MACsec where available.
2. **MTU/MSS:** Cloud VPN caps the encrypted payload around 1460 bytes; a VPC configured for 8896-byte jumbo frames talking over VPN will blackhole large TCP segments unless MSS clamping is right. This is the single most common "the tunnel is up but the app hangs" bug.

### 4.4 HA VPN, complete and deployable

```hcl
# ---------------------------------------------------------------------------
# hybrid/ha-vpn.tf — 99.99% HA VPN to on-prem, BGP over two interfaces.
# ---------------------------------------------------------------------------

variable "onprem_peer_ip_a" { type = string } # colo-A primary router
variable "onprem_peer_ip_b" { type = string } # colo-A secondary router
variable "onprem_asn"       { type = number  default = 65010 }
variable "shared_secret"    { type = string  sensitive = true }

resource "google_compute_ha_vpn_gateway" "onprem" {
  project = var.host_project
  name    = "ha-vpn-gw-onprem-usc1"
  region  = var.region
  network = var.vpc_self_link
}

resource "google_compute_external_vpn_gateway" "onprem" {
  project         = var.host_project
  name            = "peer-gw-colo-a"
  redundancy_type = "TWO_IPS_REDUNDANCY"
  description     = "colo-A edge routers"

  interface {
    id         = 0
    ip_address = var.onprem_peer_ip_a
  }
  interface {
    id         = 1
    ip_address = var.onprem_peer_ip_b
  }
}

resource "google_compute_router" "cr" {
  project = var.host_project
  name    = "cr-hybrid-usc1"
  region  = var.region
  network = var.vpc_self_link

  bgp {
    asn               = 64514
    advertise_mode    = "CUSTOM"
    advertised_groups = ["ALL_SUBNETS"]

    # Advertise the Private Google Access ranges so on-prem clients can
    # reach *.googleapis.com privately during and after migration.
    advertised_ip_ranges {
      range       = "199.36.153.8/30"
      description = "private.googleapis.com"
    }
    advertised_ip_ranges {
      range       = "199.36.153.4/30"
      description = "restricted.googleapis.com"
    }
  }
}

resource "google_compute_vpn_tunnel" "t0" {
  project                         = var.host_project
  name                            = "tun-onprem-if0"
  region                          = var.region
  vpn_gateway                     = google_compute_ha_vpn_gateway.onprem.id
  vpn_gateway_interface           = 0
  peer_external_gateway           = google_compute_external_vpn_gateway.onprem.id
  peer_external_gateway_interface = 0
  shared_secret                   = var.shared_secret
  router                          = google_compute_router.cr.id
  ike_version                     = 2
}

resource "google_compute_vpn_tunnel" "t1" {
  project                         = var.host_project
  name                            = "tun-onprem-if1"
  region                          = var.region
  vpn_gateway                     = google_compute_ha_vpn_gateway.onprem.id
  vpn_gateway_interface           = 1
  peer_external_gateway           = google_compute_external_vpn_gateway.onprem.id
  peer_external_gateway_interface = 1
  shared_secret                   = var.shared_secret
  router                          = google_compute_router.cr.id
  ike_version                     = 2
}

resource "google_compute_router_interface" "if0" {
  project    = var.host_project
  name       = "ri-if0"
  router     = google_compute_router.cr.name
  region     = var.region
  ip_range   = "169.254.10.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.t0.name
}

resource "google_compute_router_interface" "if1" {
  project    = var.host_project
  name       = "ri-if1"
  router     = google_compute_router.cr.name
  region     = var.region
  ip_range   = "169.254.11.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.t1.name
}

resource "google_compute_router_peer" "peer0" {
  project                   = var.host_project
  name                      = "bgp-peer-if0"
  router                    = google_compute_router.cr.name
  region                    = var.region
  peer_ip_address           = "169.254.10.2"
  peer_asn                  = var.onprem_asn
  interface                 = google_compute_router_interface.if0.name
  advertised_route_priority = 100

  bfd {
    session_initialization_mode = "ACTIVE"
    min_transmit_interval       = 1000
    min_receive_interval        = 1000
    multiplier                  = 5
  }
}

resource "google_compute_router_peer" "peer1" {
  project                   = var.host_project
  name                      = "bgp-peer-if1"
  router                    = google_compute_router.cr.name
  region                    = var.region
  peer_ip_address           = "169.254.11.2"
  peer_asn                  = var.onprem_asn
  interface                 = google_compute_router_interface.if1.name
  advertised_route_priority = 200

  bfd {
    session_initialization_mode = "ACTIVE"
    min_transmit_interval       = 1000
    min_receive_interval        = 1000
    multiplier                  = 5
  }
}

# Cloud NAT for migrated VMs that need outbound package repos but no
# inbound exposure. Keeps compute.vmExternalIpAccess = deny satisfiable.
resource "google_compute_router_nat" "nat" {
  project                            = var.host_project
  name                               = "nat-usc1"
  router                             = google_compute_router.cr.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

Verification — this is the command you run before declaring the network done:

```bash
$ gcloud compute routers get-status cr-hybrid-usc1 \
    --region=us-central1 --project=acme-pay-prod-host \
    --format="yaml(result.bgpPeerStatus)"
result:
  bgpPeerStatus:
  - advertisedRoutes:
    - destRange: 10.40.0.0/20
    - destRange: 10.60.0.0/20
    - destRange: 199.36.153.8/30
    ipAddress: 169.254.10.1
    linkedVpnTunnel: .../tunnels/tun-onprem-if0
    name: bgp-peer-if0
    numLearnedRoutes: 14
    peerIpAddress: 169.254.10.2
    state: Established
    status: UP
    uptime: 3 hours, 12 minutes
  - advertisedRoutes:
    - destRange: 10.40.0.0/20
    - destRange: 10.60.0.0/20
    ipAddress: 169.254.11.1
    name: bgp-peer-if1
    numLearnedRoutes: 14
    peerIpAddress: 169.254.11.2
    state: Established
    status: UP
    uptime: 3 hours, 12 minutes
```

Both `Established`, both learning routes: the 99.99% topology is real, not aspirational.

---

## 5. Phase 3 — DEPLOY (data): choose by time-to-transfer, not by preference

### 5.1 The arithmetic that makes the decision

```
transfer_days  =  total_bytes / (link_bps * utilization * 0.9 /8)      # 0.9 = protocol overhead
feasible       =  transfer_days < window_days  AND  delta_rate < drain_rate
```

800 TB over 1 Gbps at 70% usable utilization:

```
800e12 * 8 / (1e9 * 0.7 * 0.9) = 1.0e7 s ≈ 118 days
```

Not feasible. Over a 10 Gbps Dedicated Interconnect: ~12 days — feasible, but the Interconnect itself has a multi-week lead time. **Transfer Appliance** exists exactly for this quadrant.

| Method | Sweet spot | Throughput | Online? | Consistency model | Notes |
|---|---|---|---|---|---|
| `gcloud storage cp/rsync` | < 1 TB, ad hoc | Link-bound, single host | Yes | Per-object | Parallel composite uploads; no managed retry/reporting |
| **Storage Transfer Service** (cloud→cloud) | S3 / Azure Blob / another GCS bucket, any size | Google-managed fleet, very high | Yes | Per-object, with `deleteObjectsUniqueInSink` for sync semantics | No egress from your own network at all |
| **Storage Transfer Service** (agent-based, on-prem → GCS) | 100 GB – hundreds of TB with good link | Scales with agent count | Yes | POSIX filesystem → objects | Agents run in Docker on your hosts; parallelizable |
| **Transfer Appliance** | 100 TB – multi-PB, poor/expensive link | Shipping-bound | No | Point-in-time snapshot | AES-256 encrypted; you hold the key. TA300/TA40 form factors |
| **BigQuery Data Transfer Service** | Analytics sources (S3, Redshift, Teradata, SaaS) | Managed | Yes | Scheduled batch | Landing directly into BigQuery, not GCS |
| **Datastream** | Ongoing CDC from Oracle/MySQL/PostgreSQL/SQL Server | Log-based, low latency | Yes | Change stream | Feeds BigQuery/GCS; used for *replatform-then-cut* |
| **Database Migration Service** | Managed-DB replatform with minimal downtime | Full dump + CDC | Yes | Transactionally consistent at promote | The only one that gives you a *promote* verb |

### 5.2 Storage Transfer Service, agent-based, complete

Install and start agents on-prem (one per host, several per host for parallelism):

```bash
$ gcloud transfer agents install \
    --pool=colo-a-pool \
    --count=8 \
    --mount-directories=/srv/nfs/payments,/srv/nfs/archive \
    --creds-file=/etc/gcp/sts-agent-sa.json
Checking for Docker...  [OK] Docker 26.1.3
Pulling image gcr.io/cloud-ingest/tsop-agent:latest ...  [OK]
Starting 8 agents in pool 'colo-a-pool'...
Agent IDs: transfer_service_agent_2f0a..., ...
[OK] 8 agents running. Verify at:
     https://console.cloud.google.com/transfer/agents
```

Create the job:

```bash
$ gcloud transfer jobs create \
    posix:///srv/nfs/payments \
    gs://acme-pay-archive/payments \
    --source-agent-pool=projects/acme-migration-prog/agentPools/colo-a-pool \
    --name=payments-nfs-to-gcs \
    --description="Wave 01 payments NFS export" \
    --overwrite-when=different \
    --schedule-repeats-every=6h \
    --log-actions=copy,delete \
    --log-action-states=succeeded,failed \
    --notification-pubsub-topic=projects/acme-migration-prog/topics/sts-events \
    --notification-event-types=transfer_operation_success,transfer_operation_failed
Created job [transferJobs/payments-nfs-to-gcs].
```

Monitor and validate:

```bash
$ gcloud transfer operations list --job-names=payments-nfs-to-gcs --format=json | jq -r '.[0].metadata.counters'
{
  "bytesCopiedToSink": "41203847284736",
  "bytesFoundFromSource": "88104857600000",
  "objectsCopiedToSink": "18402911",
  "objectsFoundFromSource": "39112044",
  "objectsFromSourceFailed": "17"
}

$ gcloud transfer operations describe transferOperations/transferJobs-payments-nfs-to-gcs-8817 \
    --format="value(errorBreakdowns)"
errorCode: PERMISSION_DENIED
errorCount: 17
errorLogEntries:
  url: posix:///srv/nfs/payments/.snapshot/hourly.0
  errorDetails: ['open /srv/nfs/payments/.snapshot/hourly.0: permission denied']
```

Diagnosis: NetApp snapshot directories, not real data. Exclude them and the job goes green:

```bash
$ gcloud transfer jobs update payments-nfs-to-gcs \
    --exclude-prefixes='.snapshot/'
Updated job [transferJobs/payments-nfs-to-gcs].
```

Final integrity check — object count and a checksum spot-check:

```bash
$ gcloud storage ls -r gs://acme-pay-archive/payments/** | wc -l
39112027

$ gcloud storage hash gs://acme-pay-archive/payments/2026/01/ledger-0001.parquet --hex
---
crc32c_hash: 3f2b9c11
digest_format: hex
md5_hash: 9c1185a5c5e9fc54612808977ee8f548
url: gs://acme-pay-archive/payments/2026/01/ledger-0001.parquet

$ md5sum /srv/nfs/payments/2026/01/ledger-0001.parquet
9c1185a5c5e9fc54612808977ee8f548  /srv/nfs/payments/2026/01/ledger-0001.parquet
```

### 5.3 Database Migration Service: near-zero-downtime replatform

DMS does **full dump + continuous CDC + promote**. The promote is the cutover.

```bash
# 1. Source connection profile (on-prem MySQL 8.0)
$ gcloud database-migration connection-profiles create mysql src-pay-mysql \
    --region=us-central1 \
    --host=10.10.4.21 --port=3306 \
    --username=dms_user --password-file=/run/secrets/dms_pw \
    --display-name="colo-A pay-mysql-01" \
    --ssl-type=SERVER_CLIENT \
    --ca-certificate=/etc/ssl/onprem-ca.pem \
    --client-certificate=/etc/ssl/dms-client.pem \
    --private-key=/etc/ssl/dms-client.key
Created connection profile [src-pay-mysql].

# 2. Destination: DMS creates the Cloud SQL instance for you
$ gcloud database-migration connection-profiles create cloudsql dst-pay-mysql \
    --region=us-central1 \
    --source-id=src-pay-mysql \
    --tier=db-custom-16-65536 \
    --edition=ENTERPRISE_PLUS \
    --storage-auto-resize \
    --data-disk-size=2000 \
    --availability-type=REGIONAL \
    --database-version=MYSQL_8_0_36 \
    --no-enable-ip-v4 \
    --private-network=projects/acme-pay-prod-host/global/networks/vpc-prod
Created connection profile [dst-pay-mysql] and Cloud SQL instance [pay-mysql-prod].

# 3. Migration job — CONTINUOUS = dump then CDC
$ gcloud database-migration migration-jobs create mj-pay-mysql \
    --region=us-central1 \
    --type=CONTINUOUS \
    --source=src-pay-mysql \
    --destination=dst-pay-mysql \
    --peer-vpc=projects/acme-pay-prod-host/global/networks/vpc-prod \
    --display-name="Wave01 payments MySQL"
Created migration job [mj-pay-mysql].

# 4. Verify BEFORE starting — this is the step teams skip
$ gcloud database-migration migration-jobs verify mj-pay-mysql --region=us-central1
Waiting for verification... done.
state: NOT_STARTED
phase: FULL_DUMP
error: null
[OK] Source binary logging enabled (log_bin=ON, binlog_format=ROW, binlog_row_image=FULL)
[OK] Source binlog retention 168h >= required
[OK] Replication user has REPLICATION SLAVE, REPLICATION CLIENT, SELECT
[WARN] 3 tables use the MyISAM engine and will not be replicated by CDC:
       payments.audit_legacy, payments.tmp_import, payments.zip_lookup
[OK] Connectivity from destination to 10.10.4.21:3306

$ gcloud database-migration migration-jobs start mj-pay-mysql --region=us-central1
Started migration job [mj-pay-mysql].
```

Watch replication lag — this number is your cutover gate:

```bash
$ watch -n30 'gcloud database-migration migration-jobs describe mj-pay-mysql \
    --region=us-central1 --format="value(state,phase)"'
RUNNING  CDC

$ gcloud monitoring time-series list \
   --filter='metric.type="database.googleapis.com/mysql/replication/seconds_behind_master"' \
   --format='value(points[0].value.int64Value)'
2
```

Promote only when lag is stable and low, and only inside the change window:

```bash
$ gcloud database-migration migration-jobs promote mj-pay-mysql --region=us-central1
This will stop replication and make the destination a standalone,
writable Cloud SQL instance. This cannot be undone. Continue (Y/n)?  Y
Waiting for promotion... done.
state: COMPLETED
phase: PROMOTE_IN_PROGRESS -> COMPLETED
```

**Rollback reality check:** after `promote`, DMS gives you nothing back. Your rollback is "re-point the app at on-prem and reconcile writes." Therefore the runbook must define, before promote: (a) app is in read-only or stopped, (b) the promote window length, (c) the exact DNS/config change and its TTL.

---

## 6. Phase 3 — DEPLOY (compute): Migrate to Virtual Machines

M2VM replicates VM disks continuously from VMware/AWS/Azure/physical into Compute Engine while the source keeps running, then does a short cutover.

Lifecycle: `Source → Migrating VM → replication cycles → Clone job (test, non-disruptive) → Cutover job (final, disruptive)`.

```bash
$ gcloud services enable vmmigration.googleapis.com
Operation finished successfully.

$ gcloud migration vms sources create vmware colo-a-vcenter \
    --location=us-central1 \
    --vcenter-ip=10.10.1.10 \
    --vcenter-username=svc-m2vm@vsphere.local \
    --vcenter-password-file=/run/secrets/vcenter_pw \
    --vcenter-thumbprint=A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:A1:B2:C3:D4
Created source [colo-a-vcenter].

$ gcloud migration vms sources list --location=us-central1
NAME             TYPE     STATE   CREATE_TIME
colo-a-vcenter   VMWARE   ACTIVE  2026-09-01T09:12:44Z

$ gcloud migration vms sources list-inventory colo-a-vcenter --location=us-central1 \
    --format='table(vmId, displayName, vmwareVmDetails.cpuCount, vmwareVmDetails.memoryMb, vmwareVmDetails.committedStorageMb)'
VM_ID       DISPLAY_NAME   CPU_COUNT  MEMORY_MB  COMMITTED_STORAGE_MB
vm-2201     pay-api-01     8          32768      204800
vm-2202     pay-api-02     8          32768      204800
vm-2203     pay-api-03     8          32768      204800
vm-2251     pay-batch-01   4          16384      512000
```

Create the migrating VM with an explicit target shape (do **not** accept 1:1 sizing blindly — use the p95 from Migration Center):

```bash
$ cat > pay-api-01-target.yaml <<'EOF'
targetProject: projects/acme-migration-prog/locations/global/targetProjects/pay-prod-app
name: pay-api-01
machineType: n2-standard-8
machineTypeSeries: n2
zone: us-central1-a
network: projects/acme-pay-prod-host/global/networks/vpc-prod
subnetwork: projects/acme-pay-prod-host/regions/us-central1/subnetworks/sn-migration-landing-usc1
networkInterfaces:
  - network: projects/acme-pay-prod-host/global/networks/vpc-prod
    subnetwork: projects/acme-pay-prod-host/regions/us-central1/subnetworks/sn-migration-landing-usc1
    internalIp: 10.60.0.21
serviceAccount: sa-pay-api@acme-pay-prod-app.iam.gserviceaccount.com
diskType: COMPUTE_ENGINE_DISK_TYPE_BALANCED
licenseType: COMPUTE_ENGINE_LICENSE_TYPE_DEFAULT
bootOption: COMPUTE_ENGINE_BOOT_OPTION_EFI
labels:
  wave: "01"
  source: colo-a
  migrated-by: m2vm
additionalLicenses: []
metadata:
  enable-oslogin: "TRUE"
  block-project-ssh-keys: "TRUE"
networkTags:
  - migrated
  - pay-api
EOF

$ gcloud migration vms migrating-vms create pay-api-01 \
    --location=us-central1 \
    --source=colo-a-vcenter \
    --source-vm-id=vm-2201 \
    --compute-engine-target-defaults-from-file=pay-api-01-target.yaml \
    --replication-schedule="0 */4 * * *"
Created migrating VM [pay-api-01].

$ gcloud migration vms migrating-vms start-migration pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter
Started migration for [pay-api-01].
```

Track replication:

```bash
$ gcloud migration vms migrating-vms describe pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter \
    --format="yaml(state, currentSyncInfo, lastSync, recentCloneJobs)"
state: ACTIVE
currentSyncInfo:
  progressPercent: 100
  startTime: '2026-09-06T04:00:00Z'
  endTime: '2026-09-06T05:41:12Z'
  state: SUCCEEDED
lastSync:
  lastSyncTime: '2026-09-06T05:41:12Z'
```

**Always clone before you cut over.** A clone job builds a real instance from the last replication point *without* touching the source — this is your dress rehearsal, and it is free of production risk:

```bash
$ gcloud migration vms clone-jobs create rehearsal-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01
Created clone job [rehearsal-01].

$ gcloud migration vms clone-jobs describe rehearsal-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01 \
    --format="value(state)"
SUCCEEDED

$ gcloud compute ssh pay-api-01 --zone=us-central1-a --tunnel-through-iap \
    --project=acme-pay-prod-app --command='systemctl is-system-running; systemctl --failed --no-legend'
degraded
  nfs-mount-archive.mount  loaded failed failed  /srv/archive
```

There is the classic finding: an fstab entry pointing at an on-prem NFS IP that has no route yet. Fix it in the source (so the fix survives the next replication cycle), re-clone, re-verify. Then cut over:

```bash
$ gcloud migration vms cutover-jobs create cutover-pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01
Cutover will shut down the source VM after a final replication cycle. Continue (Y/n)? Y
Created cutover job [cutover-pay-api-01].

$ gcloud migration vms cutover-jobs describe cutover-pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01 \
    --format="yaml(state, steps)"
state: SUCCEEDED
steps:
- previousReplicationCycle: {state: SUCCEEDED}
- shuttingDownSourceVm:    {state: SUCCEEDED}
- finalSync:               {state: SUCCEEDED}
- instantiatingMigratedVm: {state: SUCCEEDED}
```

Finalize to stop billing for replication storage:

```bash
$ gcloud migration vms migrating-vms finalize-migration pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter
Finalized migration for [pay-api-01]. Replication resources released.
```

| M2VM job type | Source impact | Produces | Use for |
|---|---|---|---|
| Replication cycle | Snapshot on source (brief) | Cloud-side disk state | Continuous, background |
| **Clone job** | None | A real, bootable GCE instance | Test/validation, repeatable |
| **Cutover job** | **Source is shut down** | The production instance | The one-way door |
| Finalize | None | Releases replication resources | After acceptance |

---

## 7. Phase 3 — DEPLOY (modernize in place): Migrate to Containers

M2C converts a running VM workload into container artifacts — a Dockerfile-equivalent image plus Kubernetes manifests — without a rewrite. It fits *stateless-ish, Linux, single-app* VMs; it does not fit databases or anything with kernel modules.

```bash
$ migctl setup install --json-key=m2c-install-sa.json
Installing Migrate to Containers on cluster 'm2c-processing'...
[OK] CRDs applied
[OK] Namespace v2k-system ready
[OK] Deployment migctl-controller available

$ migctl source create ce colo-a-src \
    --project=acme-migration-prog --json-key=m2c-src-sa.json
Created source [colo-a-src].

$ migctl migration create pay-web \
    --source colo-a-src \
    --vm-id pay-web-04 \
    --intent Image
Created migration [pay-web].

$ migctl migration status pay-web
NAME     CURRENT-OPERATION  PROGRESS  STEP              STATUS
pay-web  GenerateArtifacts  100%      Copying files     Completed

$ migctl migration get-artifacts pay-web
Artifacts written to ./pay-web/
  Dockerfile
  deployment_spec.yaml
  migration.yaml
```

The generated `deployment_spec.yaml` — reviewed and hardened, which is the part that is your job, not the tool's:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pay-web
  namespace: payments
  labels:
    app: pay-web
    migrated-from: pay-web-04
    wave: "01"
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
      app: pay-web
  template:
    metadata:
      labels:
        app: pay-web
      annotations:
        anthos-migrate.gcr.io/source: "pay-web-04"
    spec:
      serviceAccountName: pay-web
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: pay-web
      containers:
        - name: pay-web
          image: us-central1-docker.pkg.dev/acme-pay-prod-app/migrated/pay-web:v1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: DB_HOST
              value: "10.40.2.3"          # Cloud SQL private IP after DMS promote
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:MaxRAMPercentage=75.0"
          envFrom:
            - configMapRef:
                name: pay-web-config
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              memory: "2Gi"               # no CPU limit: avoids CFS throttling
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            failureThreshold: 60          # 5 min for legacy JVM warm-up
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 4
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]   # drain LB before exit
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: run
              mountPath: /var/run
      volumes:
        - name: tmp
          emptyDir: { sizeLimit: 512Mi }
        - name: run
          emptyDir: { medium: Memory, sizeLimit: 64Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: pay-web
  namespace: payments
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"default": "pay-web-backendconfig"}'
spec:
  type: ClusterIP
  selector:
    app: pay-web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: pay-web-backendconfig
  namespace: payments
spec:
  timeoutSec: 30
  connectionDraining:
    drainingTimeoutSec: 60
  healthCheck:
    type: HTTP
    requestPath: /readyz
    port: 8080
    checkIntervalSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
  logging:
    enable: true
    sampleRate: 1.0
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: pay-web
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: pay-web
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pay-web
  namespace: payments
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: pay-web
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pay-web-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: pay-web
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 10.40.2.3/32        # Cloud SQL private IP
      ports:
        - protocol: TCP
          port: 3306
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

M2C fit table — memorize the exclusions:

| Workload shape | M2C fit | Why |
|---|---|---|
| Stateless Linux app server (Tomcat, JBoss, nginx, Node) | **Good** | Filesystem is mostly code + config |
| Windows IIS / .NET Framework app | Good (Windows support) | Containerized IIS images |
| MySQL/PostgreSQL/Oracle on a VM | **Bad** | Use DMS / Cloud SQL / Bare Metal Solution instead |
| Anything with a custom kernel module, GPU driver pinning, or `/dev` access | **Bad** | Container shares the node kernel |
| App with hard-coded local state in `/var/lib/app` | Conditional | Needs a PersistentVolume or refactor |
| Multi-service "everything" VM | Conditional | Decompose first; one container per process |

---

## 8. Retain and hybrid: GKE Enterprise as the consistency layer

For workloads that cannot move (regulatory, latency, licence), Google's answer is to make the *control plane* consistent rather than forcing the workload to move. Fleets + Config Sync give you one policy source across on-prem, Google Cloud, and other clouds.

```bash
$ gcloud container fleet memberships register colo-a-cluster \
    --context=onprem-colo-a \
    --kubeconfig=$HOME/.kube/config \
    --enable-workload-identity \
    --project=acme-fleet-host
Waiting for membership to be created...done.
Finished registering the cluster [colo-a-cluster] with the fleet.

$ gcloud container fleet memberships list --project=acme-fleet-host
NAME             UNIQUE_ID                             LOCATION
colo-a-cluster   4c1b8a7e-...                          global
gke-usc1-prod    9e2d31af-...                          us-central1
```

Enable Config Sync fleet-wide:

```yaml
# apply-spec.yaml
applySpecVersion: 1
spec:
  configmanagement:
    version: 1.19.0
    configSync:
      enabled: true
      sourceFormat: unstructured
      syncRepo: https://github.com/acme/platform-config
      syncBranch: main
      policyDir: clusters/
      secretType: gcpserviceaccount
      gcpServiceAccountEmail: config-sync@acme-fleet-host.iam.gserviceaccount.com
      preventDrift: true
    policyController:
      enabled: true
      templateLibraryInstalled: true
      referentialRulesEnabled: true
      auditIntervalSeconds: 60
```

```bash
$ gcloud beta container fleet config-management apply \
    --membership=colo-a-cluster --config=apply-spec.yaml --project=acme-fleet-host
Waiting for Feature Config Management to be updated...done.

$ gcloud beta container fleet config-management status --project=acme-fleet-host
Name             Status  Last_Synced_Token  Sync_Branch  Last_Synced_Time      Policy_Controller
colo-a-cluster   SYNCED  8f21ad3            main         2026-09-08T11:04:12Z  INSTALLED
gke-usc1-prod    SYNCED  8f21ad3            main         2026-09-08T11:04:09Z  INSTALLED
```

The `RootSync` object that drives it:

```yaml
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: root-sync
  namespace: config-management-system
spec:
  sourceFormat: unstructured
  sourceType: git
  git:
    repo: https://github.com/acme/platform-config
    branch: main
    dir: clusters/base
    auth: gcpserviceaccount
    gcpServiceAccountEmail: config-sync@acme-fleet-host.iam.gserviceaccount.com
    period: 30s
  override:
    resources:
      - containerName: reconciler
        cpuRequest: 100m
        memoryRequest: 512Mi
        memoryLimit: 1Gi
```

The exam-level point: **GKE Enterprise (formerly Anthos) is how Google Cloud supports organizations whose transition is partial or permanent-hybrid** — one API, one policy set, one observability plane, whether the cluster is in a Google region, in your colo, or in AWS.

---

## 9. Cutover: an SRE runbook, not an event

Cutover is a change with a defined blast radius and a rollback clock. Write it this way:

```yaml
# runbook/wave-01-cutover.yaml  (documentation-as-code; reviewed in PR)
wave: "01"
service: payments-api
slo:
  availability: 99.95%
  monthly_error_budget_minutes: 21.6
  budget_consumed_before_cutover: 4.1
  budget_allocated_to_cutover: 8.0     # hard stop: abort if exceeded

preconditions:
  - id: PRE-1
    check: "DMS replication lag < 5s sustained 30 min"
    cmd: "gcloud database-migration migration-jobs describe mj-pay-mysql --region=us-central1 --format='value(phase)'"
    expect: "CDC"
  - id: PRE-2
    check: "M2VM clone rehearsal passed with zero failed units"
    cmd: "gcloud compute ssh pay-api-01 --tunnel-through-iap --command='systemctl --failed --no-legend | wc -l'"
    expect: "0"
  - id: PRE-3
    check: "BGP sessions Established on both interfaces"
    cmd: "gcloud compute routers get-status cr-hybrid-usc1 --region=us-central1 --format='value(result.bgpPeerStatus[].state)'"
    expect: "Established;Established"
  - id: PRE-4
    check: "DNS TTL lowered to 60s at least 24h ago"
    cmd: "dig +noall +answer api.pay.acme.com"
    expect: "ttl<=60"
  - id: PRE-5
    check: "Rollback tested in staging within last 7 days"

steps:
  - t: "T-00:00"
    action: "Enable maintenance page; drain LB backends on-prem"
  - t: "T-00:03"
    action: "Confirm zero in-flight writes (SHOW PROCESSLIST)"
  - t: "T-00:05"
    action: "gcloud database-migration migration-jobs promote mj-pay-mysql"
  - t: "T-00:12"
    action: "Point app config at Cloud SQL private IP; restart app tier"
  - t: "T-00:15"
    action: "Shift 10% of traffic via weighted DNS / LB traffic split"
  - t: "T-00:25"
    action: "Verify golden signals at 10%; compare p99 and error rate to baseline"
  - t: "T-00:40"
    action: "Shift to 50%"
  - t: "T-01:00"
    action: "Shift to 100%; remove maintenance page"
  - t: "T-24:00"
    action: "Raise DNS TTL to 3600; finalize M2VM; decommission source"

abort_criteria:
  - "error rate > 1% for 5 consecutive minutes"
  - "p99 latency > 2x baseline for 10 minutes"
  - "any data integrity check fails"
  - "cumulative error budget burn > 8.0 minutes"

rollback:
  rto_minutes: 15
  procedure:
    - "Revert DNS weight to 100% on-prem (TTL 60s => propagation <= 2 min)"
    - "Re-enable on-prem LB backends"
    - "Set Cloud SQL instance read-only; export delta writes for reconciliation"
    - "Open incident; do not retry same day"
  data_loss_window: "writes accepted by Cloud SQL after promote; reconcile from binlog"
```

Baseline the golden signals *before* you touch anything — a cutover without a pre-change baseline cannot be judged:

```bash
$ gcloud monitoring time-series list \
    --filter='metric.type="loadbalancing.googleapis.com/https/total_latencies" AND resource.labels.forwarding_rule_name="pay-api-fr"' \
    --interval-start-time="2026-09-01T00:00:00Z" \
    --interval-end-time="2026-09-08T00:00:00Z" \
    --aggregation-alignment-period=300s \
    --aggregation-per-series-aligner=ALIGN_PERCENTILE_99 \
    --format='value(points[].value.distributionValue.mean)' | head -5
118.4
121.0
117.9
203.7
119.2
```

---

## 10. Phase 4 — OPTIMIZE: where the business case is actually won

A rehost that stops here costs more than the datacenter. Optimization is not optional, and Google ships it as tooling rather than advice.

| Lever | Google tooling | Typical realized saving | Risk |
|---|---|---|---|
| Rightsizing | **Active Assist / Recommender** (`google.compute.instance.MachineTypeRecommender`) | 15–40% on compute | Under-sizing a spiky workload; use p95 over ≥14 days |
| Idle resource reclamation | Recommender: idle VM, idle disk, idle IP, idle Cloud SQL | 5–15% | Deleting something with a quarterly duty cycle |
| Committed Use Discounts | Spend-based / resource-based CUDs, 1y or 3y | Up to ~55% (resource-based, 3y) | Commitment is non-cancellable; commit to the *floor*, not the peak |
| Spot VMs | Spot VM / GKE Spot node pools | Up to ~91% | Preemption; only for fault-tolerant/batch |
| Autoscaling | MIG autoscaler, GKE cluster autoscaler, **GKE Autopilot**, Cloud Run scale-to-zero | Highly variable | Cold start; scaling on the wrong signal |
| Storage tiering | Object Lifecycle Management → Nearline/Coldline/Archive; Autoclass | 40–80% on cold data | Early-deletion and retrieval fees |
| Network | Standard vs Premium Tier, Cloud CDN | 10–25% egress | Standard Tier changes latency and SLA |

```bash
$ gcloud recommender recommendations list \
    --project=acme-pay-prod-app \
    --location=us-central1-a \
    --recommender=google.compute.instance.MachineTypeRecommender \
    --format='table(name.basename(), primaryImpact.costProjection.cost.units, description)'
NAME                                  UNITS  DESCRIPTION
b1f2-3a9c-...                         -412   Save cost by changing machine type from n2-standard-16 to n2-standard-8.
c8d1-7e02-...                         -197   Save cost by changing machine type from n2-standard-8 to n2-standard-4.
Listed 34 items.

$ gcloud recommender recommendations list \
    --project=acme-pay-prod-app --location=global \
    --recommender=google.cloudsql.instance.IdleRecommender \
    --format='value(description)'
Save cost by stopping idle Cloud SQL instance pay-mysql-uat-old.

$ gcloud storage buckets update gs://acme-pay-archive \
    --lifecycle-file=lifecycle.json
Updating gs://acme-pay-archive/...
  Completed 1
```

```json
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "SetStorageClass", "storageClass": "NEARLINE" },
        "condition": { "age": 30, "matchesStorageClass": ["STANDARD"] }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "age": 120, "matchesStorageClass": ["NEARLINE"] }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "age": 365, "matchesStorageClass": ["COLDLINE"] }
      },
      {
        "action": { "type": "Delete" },
        "condition": { "age": 2555, "isLive": true }
      },
      {
        "action": { "type": "Delete" },
        "condition": { "daysSinceNoncurrentTime": 30 }
      }
    ]
  }
}
```

Governance so the savings do not evaporate — budgets with programmatic alerts:

```bash
$ gcloud billing budgets create \
    --billing-account=01ABCD-234567-89EFGH \
    --display-name="Wave 01 payments" \
    --filter-projects=projects/acme-pay-prod-app \
    --budget-amount=48000USD \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=0.8 \
    --threshold-rule=percent=1.0,basis=forecasted-spend \
    --all-updates-rule-pubsub-topic=projects/acme-common-billing/topics/budget-alerts
Created budget [billingAccounts/01ABCD-234567-89EFGH/budgets/8b21-...].
```

---

## 11. Verification and failure diagnosis

### 11.1 Verification ladder — run in this order

| Layer | What you assert | Command |
|---|---|---|
| L0 Policy | The landing zone enforces what you designed | `gcloud org-policies describe <constraint> --folder=<id> --effective` |
| L1 Reachability | BGP up, routes exchanged | `gcloud compute routers get-status <router> --region=<r>` |
| L2 Path | The specific 5-tuple is permitted end to end | `gcloud network-management connectivity-tests create ... && ... describe` |
| L3 Data plane | The VM/pod actually answers | `curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' http://<ip>/readyz` |
| L4 Data integrity | Row/object counts and checksums match | `SELECT COUNT(*)` both sides; `gcloud storage hash` |
| L5 Behaviour | Golden signals within baseline | Cloud Monitoring MQL/PromQL vs pre-cutover baseline |
| L6 Cost | Actuals match the TCO projection | Billing export → BigQuery; Recommender delta |

Connectivity Tests is the highest-value underused tool — it evaluates the *configuration* (routes, firewall, policies) without needing traffic:

```bash
$ gcloud network-management connectivity-tests create pay-app-to-sql \
    --source-instance=projects/acme-pay-prod-app/zones/us-central1-a/instances/pay-api-01 \
    --destination-ip-address=10.40.2.3 \
    --destination-port=3306 \
    --protocol=TCP \
    --project=acme-pay-prod-app
Created connectivity test [pay-app-to-sql].

$ gcloud network-management connectivity-tests describe pay-app-to-sql \
    --project=acme-pay-prod-app --format="yaml(reachabilityDetails)"
reachabilityDetails:
  result: UNREACHABLE
  traces:
  - steps:
    - description: Initial state - packet originating from instance pay-api-01
      state: START_FROM_INSTANCE
    - description: Config checking state - verify route
      state: APPLY_ROUTE
      route: {destIpRange: 10.40.0.0/20, nextHopType: NEXT_HOP_NETWORK}
    - description: Config checking state - verify egress firewall rule
      state: APPLY_EGRESS_FIREWALL_RULE
      firewall: {displayName: deny-all-egress, action: DENY, priority: 65000}
    - description: Packet could be dropped
      state: DROP
      causeCode: FIREWALL_RULE
  verifyTime: '2026-09-08T11:52:03Z'
```

The tool named the exact rule. That is a two-minute diagnosis instead of a two-hour packet capture.

### 11.2 Failure catalogue

| Symptom | Most likely cause | Diagnostic command | Fix |
|---|---|---|---|
| M2VM replication stuck at <100% for hours | vSphere CBT disabled/reset, or datastore snapshot quota exhausted | `gcloud migration vms migrating-vms describe <vm> --format='yaml(error,currentSyncInfo)'` | Enable CBT on the source VM, remove stale snapshots, restart the cycle |
| M2VM cutover: instance boots to emergency shell | Boot option mismatch (BIOS vs UEFI) or `/etc/fstab` references gone disks | Serial console: `gcloud compute instances get-serial-port-output <vm>` | Set `bootOption: COMPUTE_ENGINE_BOOT_OPTION_EFI` correctly; use UUIDs in fstab **before** the final cycle |
| Migrated VM boots but no network | NIC renamed (`ens192` → `ens4`); static config references old name | Serial console output; `ip -br link` | Use DHCP + guest environment; install `google-guest-agent` in source before migration |
| Cannot SSH into migrated VM | OS Login not enabled, no external IP by policy, no IAP firewall rule | `gcloud compute ssh <vm> --tunnel-through-iap --troubleshoot` | Allow 35.235.240.0/20 on 22; grant `roles/iap.tunnelResourceAccessor` |
| DMS job `FAILED` in `FULL_DUMP` | Insufficient grants, or tables without a primary key (PostgreSQL logical replication) | `gcloud database-migration migration-jobs describe <mj> --format='yaml(error)'` | Grant `REPLICATION SLAVE, REPLICATION CLIENT, SELECT`; add PKs or exclude those tables |
| DMS CDC lag grows without bound | Destination tier undersized, or a long-running transaction on the source | Monitor `seconds_behind_master`; `SHOW ENGINE INNODB STATUS` on source | Scale the Cloud SQL tier; kill the long transaction; retry cutover next window |
| DMS: binlog gap error | Source `binlog_expire_logs_seconds` too short vs. dump duration | Source: `SHOW VARIABLES LIKE 'binlog_expire%'` | Raise retention to ≥ 7 days **before** starting; restart the job |
| STS agent-based job transfers 0 bytes | Agent cannot see the mount, or mount path not in `--mount-directories` | `docker logs <agent-container>`; `gcloud transfer agents list` | Re-install agents with the correct mount list; check UID/GID on the export |
| BGP session flaps every few minutes | MD5/ASN mismatch, or on-prem BFD interval mismatch | `gcloud compute routers get-status` → `state: Connect`/`Idle` | Align ASN, BFD timers; check on-prem `show ip bgp neighbors` |
| Tunnel UP, BGP Established, but large transfers hang | MTU/MSS: 1500-byte packets with DF over a 1460-byte VPN path | `ping -M do -s 1400 <peer>` then `-s 1460` | MSS clamp to 1360 on the on-prem edge; set VPC MTU consistently |
| App works from GCE but not from GKE pod | NetworkPolicy egress deny, or IP masquerade excluding the on-prem range | `kubectl exec -it <pod> -- nc -vz 10.10.4.21 3306`; `kubectl -n kube-system get cm ip-masq-agent -o yaml` | Add the egress rule; add the CIDR to `nonMasqueradeCIDRs` |
| `Private Google Access` fails from on-prem | Missing route advertisement for 199.36.153.8/30 or missing DNS forwarding zone | `dig storage.googleapis.com @<onprem-resolver>` | Advertise the range on Cloud Router; create the private DNS zone + response policy |
| Config Sync stuck `PENDING` | Repo unreachable, or a manifest fails Policy Controller admission | `nomos status`; `kubectl -n config-management-system logs deploy/root-reconciler` | Fix the repo auth or the offending manifest; `preventDrift` reports it |
| Post-migration bill 3× the TCO projection | Sizing was 1:1, no CUDs, egress not modelled, snapshots never expired | Billing export in BigQuery grouped by SKU; `gcloud recommender recommendations list` | Rightsize, apply CUDs, add lifecycle policies, review egress topology |

```bash
$ nomos status
Connecting to clusters...
*colo-a-cluster
  --------------------
  <root>   https://github.com/acme/platform-config/clusters@main
  ERROR    KNV1021: The below resource is invalid: admission webhook
           "validation.gatekeeper.sh" denied the request: [require-resource-limits]
           container <pay-web> has no memory limit
  Last Synced Token: 7a92be1
```

---

## 12. Exam lens: what CDL actually asks about this objective

The Digital Leader exam does not ask you to write the Terraform. It asks you to pick the right *named* Google answer for a business scenario. Map these:

| Scenario cue in the question | Correct answer |
|---|---|
| "Assess readiness, identify skills and cultural gaps" | **Google Cloud Adoption Framework** (Learn, Lead, Scale, Secure; Tactical/Strategic/Transformational) |
| "Inventory servers and estimate cost before deciding" | **Migration Center** (free assessment, TCO report) |
| "Move VMs as-is, minimal changes, tight deadline" | **Rehost / lift and shift** with **Migrate to VMs** |
| "Keep VMware tooling and skills, move out of the datacenter fast" | **Google Cloud VMware Engine** |
| "Move MySQL to a managed service with minimal downtime" | **Database Migration Service** |
| "Containerize existing apps without rewriting them" | **Migrate to Containers** |
| "Petabytes of data, poor network link" | **Transfer Appliance** |
| "Ongoing sync from AWS S3 to Cloud Storage" | **Storage Transfer Service** |
| "Some workloads must stay on-prem for compliance" | **Hybrid / GKE Enterprise**; strategy = *retain* |
| "Consistent policy across on-prem, Google Cloud, and other clouds" | **GKE Enterprise fleets + Config Sync + Policy Controller** |
| "Reduce spend after migrating" | **Active Assist / Recommender**, **committed use discounts**, autoscaling |
| "Change how teams work — culture, automation, measurement, sharing" | **CAMP** / DevOps + SRE practices |
| "Private, high-bandwidth connection to Google, not over the internet" | **Dedicated (or Partner) Interconnect** |
| "Encrypted connection over the public internet, quickly" | **Cloud HA VPN** |

Three distinctions the exam likes to test:

1. **CAF ≠ the four migration phases.** CAF assesses the organization; Assess/Plan/Deploy/Optimize executes the migration.
2. **Rehost is not failure.** It is the correct first move under a deadline; modernization belongs to Optimize.
3. **TCO includes what you stop paying for.** Datacenter power, cooling, hardware refresh, licence true-ups, and the staff hours spent on patching — the exam frames this as capex→opex and as reduced operational toil.

---

## 13. Summary

- A cloud transition is a **staged program** — Assess, Plan, Deploy, Optimize — with a Google tool bound to each stage; naming the stage first is how you pick the tool.
- **Assess is the gate.** Migration Center gives you inventory, dependencies, fit and TCO for free; a wave without a dependency map is a wave that will page you.
- **The landing zone is the first deliverable**, not the last: resource hierarchy, identity, network, and org policy applied before workload one.
- **Strategy is per workload**: rehost / replatform / refactor / retire / retain, chosen from deadline, change budget and dependency fan-in.
- **Data movement is arithmetic**, not preference: compute time-to-transfer against the change window before choosing STS vs Transfer Appliance vs Interconnect.
- **Every cutover needs a rehearsal (clone job), a baseline, abort criteria, and a rollback with a stated RTO** — otherwise it is an outage with a project plan attached.
- **Hybrid is a destination, not a defect.** GKE Enterprise makes "retain" a governed state rather than a permanent exception.
- **Optimize is where the business case is realized.** Rightsizing, CUDs, autoscaling and storage tiering are the difference between a migration that pays for itself and one that becomes a cost incident.

---

## 14. References

Official Google sources. All URLs are Google-published documentation; the exam guide is the authoritative scope definition.

**Exam scope**
- Cloud Digital Leader exam guide (PDF) — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Frameworks and program model**
- Migration to Google Cloud: getting started — https://cloud.google.com/architecture/migration-to-gcp-getting-started
- Migration to Google Cloud: assessing and discovering your workloads — https://cloud.google.com/architecture/migration-to-gcp-assessing-and-discovering-your-workloads
- Migration to Google Cloud: planning and building your foundation — https://cloud.google.com/architecture/migration-to-google-cloud-building-your-foundation
- Migration to Google Cloud: deploying your workloads — https://cloud.google.com/architecture/migration-to-google-cloud-deploying-your-workloads
- Migration to Google Cloud: optimizing your environment — https://cloud.google.com/architecture/migration-to-google-cloud-optimizing-your-environment
- Google Cloud Adoption Framework — https://cloud.google.com/adoption-framework
- Google Cloud Architecture Framework — https://cloud.google.com/architecture/framework
- DevOps / DORA capabilities (CAMP) — https://cloud.google.com/devops

**Landing zone and foundation**
- Landing zone design in Google Cloud — https://cloud.google.com/architecture/landing-zones
- Google Cloud enterprise foundations blueprint — https://cloud.google.com/architecture/security-foundations
- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Organization Policy Service — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints reference — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Cloud Foundation Toolkit — https://cloud.google.com/foundation-toolkit

**Assessment**
- Migration Center overview — https://cloud.google.com/migration-center/docs/migration-center-overview
- Discovery client — https://cloud.google.com/migration-center/docs/discovery-client-overview
- `gcloud migration-center` reference — https://cloud.google.com/sdk/gcloud/reference/migration-center

**Compute migration**
- Migrate to Virtual Machines — https://cloud.google.com/migrate/virtual-machines/docs/5.0/get-started/migrate-to-vms-overview
- Migrating VMs from VMware — https://cloud.google.com/migrate/virtual-machines/docs/5.0/migrate/vmware-migration-overview
- `gcloud migration vms` reference — https://cloud.google.com/sdk/gcloud/reference/migration/vms
- Google Cloud VMware Engine — https://cloud.google.com/vmware-engine/docs/overview
- Migrate to Containers — https://cloud.google.com/migrate/containers/docs/migrate-to-containers-overview
- Migrate to Containers: what can be migrated — https://cloud.google.com/migrate/containers/docs/migration-planning

**Data and database migration**
- Storage Transfer Service overview — https://cloud.google.com/storage-transfer/docs/overview
- Transfer from on-premises (agent-based) — https://cloud.google.com/storage-transfer/docs/on-prem-overview
- Transfer Appliance — https://cloud.google.com/transfer-appliance/docs/4.0/overview
- Database Migration Service — https://cloud.google.com/database-migration/docs
- DMS for MySQL: prerequisites and configuration — https://cloud.google.com/database-migration/docs/mysql/configure-source-database
- Datastream overview — https://cloud.google.com/datastream/docs/overview
- BigQuery Data Transfer Service — https://cloud.google.com/bigquery/docs/dts-introduction

**Hybrid connectivity**
- Network Connectivity products overview — https://cloud.google.com/network-connectivity/docs/how-to/choose-product
- Cloud VPN overview / HA VPN topologies — https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview and https://cloud.google.com/network-connectivity/docs/vpn/concepts/topologies
- Cloud Interconnect overview — https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview
- Cloud Router and BGP — https://cloud.google.com/network-connectivity/docs/router/concepts/overview
- Maximum transmission unit (MTU) — https://cloud.google.com/vpc/docs/mtu
- Private Google Access for on-premises hosts — https://cloud.google.com/vpc/docs/private-google-access-hybrid

**Hybrid and multicloud runtime**
- GKE Enterprise overview — https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview
- Fleet management — https://cloud.google.com/kubernetes-engine/fleet-management/docs/fleet-concepts
- Config Sync — https://cloud.google.com/kubernetes-engine/enterprise/config-sync/docs/overview
- Policy Controller — https://cloud.google.com/kubernetes-engine/enterprise/policy-controller/docs/overview

**Verification, diagnosis and optimization**
- Connectivity Tests — https://cloud.google.com/network-intelligence-center/docs/connectivity-tests/concepts/overview
- VPC Flow Logs — https://cloud.google.com/vpc/docs/flow-logs
- IAP TCP forwarding — https://cloud.google.com/iap/docs/using-tcp-forwarding
- Active Assist / Recommender — https://cloud.google.com/recommender/docs/overview
- Committed use discounts — https://cloud.google.com/docs/cus-and-suds and https://cloud.google.com/compute/docs/instances/committed-use-discounts-overview
- Object Lifecycle Management — https://cloud.google.com/storage/docs/lifecycle
- Cloud Billing budgets and alerts — https://cloud.google.com/billing/docs/how-to/budgets
- Google Cloud SLAs — https://cloud.google.com/terms/sla
- SRE practice: SLOs and error budgets — https://sre.google/workbook/implementing-slos/