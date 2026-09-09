# 1.1 — Why and How the Cloud Is Revolutionizing Business

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12)
**Exam weight:** 9.0 — treat this as a foundational objective whose vocabulary is reused by every later section.
**Reader profile:** SRE / Platform Architect. Every business claim in this document is reduced to an engineering mechanism, and every mechanism is reduced to a command you can run and an artifact you can diff.

---

## 1. Motivation: the production problem the cloud actually solves

The Cloud Digital Leader exam states the objective in business language — "the cloud is revolutionizing business." That sentence is only useful to an engineer once it is translated into the failure it removes. The failure is **capacity as a design-time constant**.

### 1.1 The peak-provisioning trap

In a colocation or on-premises estate, the quantity of compute is fixed months before the traffic arrives. That produces a chain of coupled constraints:

| Constraint | On-premises reality | Consequence for the business |
|---|---|---|
| Procurement lead time | 8–16 weeks (quote → PO → ship → rack → cable → image → burn-in) | A product decision made in March cannot be served until June. Time-to-market is bounded by logistics, not engineering. |
| Sizing input | A forecast, made once, by people who do not yet have the product | Forecast error is capitalised. You are wrong for 3–5 years. |
| Depreciation horizon | 3–5 years straight-line | The hardware must be defended even when the architecture that justified it is dead. |
| Failure-domain granularity | The rack, the row, the room, the building | Redundancy costs 2× the *entire* estate, so it is usually skipped. |
| Utilisation | Typically 15–30 % average on a peak-sized fleet | 70–85 % of the capital is idle at any instant. |

Consider a retail platform whose baseline is 4 000 requests/second and whose Black Friday peak is 48 000 rps — a 12× ratio, which is unremarkable for retail, ticketing, tax filing, or election-night media.

Let the per-instance service capacity be 400 rps at the target latency SLO.

```
peak fleet      = ceil(48000 / 400)         = 120 instances
baseline fleet  = ceil(4000 / 400)          =  10 instances
N+1 zone redundancy factor (3 zones, survive 1) = 1.5

on-prem procurement = 120 * 1.5             = 180 instances, owned for 5 years
utilisation         = mean(demand) / provisioned
                    ~ (10 * 1.5) / 180      = 8.3 % annualised
```

The business pays for 180 machine-years to consume roughly 15 machine-years of work. That is the arithmetic behind "the cloud revolutionised business": not a discount on a server, but the **removal of the multiplication by peak**.

### 1.2 What actually changed — five shifts

The exam expects you to describe the transformation. Describe it as five mechanical shifts, each of which is independently verifiable:

| Shift | Before | After | Mechanism in Google Cloud | How you prove it (§4) |
|---|---|---|---|---|
| Capacity becomes a runtime variable | Fixed at purchase | Adjusted per minute by a control loop | Managed Instance Group autoscaler, GKE cluster autoscaler, Cloud Run request-based scaling | `gcloud compute instance-groups managed describe` |
| Cost becomes telemetry | A quarterly invoice, opaque | A per-SKU, per-resource, per-label event stream | Cloud Billing export to BigQuery, per-second billing | `bq query` over the billing export |
| Reliability becomes a contract plus a budget | "The datacentre is up" | Financially-backed SLA + internally-chosen SLO + error budget | Zones/regions, Cloud Monitoring SLOs | `google_monitoring_slo` + burn-rate alerts |
| Data gravity inverts | Move data to the compute you own | Move compute to the data, elastically, and separate storage from compute | BigQuery (storage/compute decoupled), Cloud Storage | Query slot/bytes accounting |
| Security becomes a shared, *documented* responsibility | Implicit, per-team, undocumented | Explicit boundary per service model + default encryption at rest and in transit | Shared responsibility / shared fate model, org policy, IAM | `gcloud org-policies describe` |

> **Exam framing.** The CDL exam calls this bundle *digital transformation*: using data and technology to change how an organisation operates and delivers value, not merely to relocate existing servers. Relocation without change is *lift-and-shift* / *rehost* — a valid first step, explicitly **not** a transformation.

### 1.3 The economic restatement: CapEx → OpEx and TCO

| Dimension | CapEx model (own the hardware) | OpEx model (consume a service) |
|---|---|---|
| Cash flow | Large up-front outlay, depreciated | Metered, monthly, proportional to use |
| Unit of billing | The asset | vCPU-second, GiB-month, request, byte scanned |
| Risk of being wrong | Stranded capital, held for years | One billing cycle |
| Financial visibility | Cost centre, allocated by heuristic | Attributable per label/project/service |
| Failure mode | Under-provisioning outage, or over-provisioning waste | **Unbounded spend** — the new failure mode |
| Who is accountable | Procurement / finance | The engineering team that owns the label |

Total Cost of Ownership (TCO) is the term the exam uses. The engineering point is that the on-premises TCO contains terms that never appear on an invoice and are therefore systematically under-counted: power and cooling, datacentre space, network transit contracts, hardware refresh, spares inventory, capacity-planning labour, physical security, decommissioning and disposal, and the opportunity cost of the engineers doing all of it instead of shipping product. Google publishes these as *undifferentiated heavy lifting*; SRE literature calls the same quantity **toil**.

The honest counter-point, which a Principal engineer must state: **the cloud does not automatically reduce cost.** It converts a *capacity* risk into a *spend* risk. A misconfigured autoscaler with `maxReplicas: 5000`, an unbounded BigQuery scan, or a forgotten multi-region replica will produce an invoice no procurement process would ever have approved. Sections 3 and 5 exist because of this.

---

## 2. Technical comparisons and trade-offs

### 2.1 The five essential characteristics (NIST SP 800-145) mapped to mechanisms

The CDL exam's definition of cloud computing derives from NIST. Each abstract characteristic corresponds to a concrete control surface:

| NIST characteristic | Plain meaning | Google Cloud mechanism | Observable proof |
|---|---|---|---|
| On-demand self-service | No human in the provisioning path | Resource Manager + IAM + API | `gcloud compute instances create` returns in seconds, no ticket |
| Broad network access | Reachable over standard protocols | Global VPC, Cloud Load Balancing with a single global anycast VIP | One IP resolves in every region |
| Resource pooling | Multi-tenant, location-abstracted | Regions/zones, Andromeda SDN, live migration | Host maintenance without instance downtime |
| Rapid elasticity | Grows and **shrinks** automatically | Autoscalers (MIG, GKE, Cloud Run) | Replica count follows load, both directions |
| Measured service | Metered, reportable, attributable | Per-second billing, billing export, labels | Per-SKU rows in BigQuery |

The distinction the exam tests: **scalability** is the ability to grow; **elasticity** is the ability to grow *and shrink automatically in response to demand*. On-premises can be scalable. Only a metered, API-driven, pooled system can be elastic — because shrinking must return money.

### 2.2 Service models: control versus toil

| | Colo / on-prem | IaaS (Compute Engine) | Containers (GKE Standard) | Containers (GKE Autopilot) | PaaS/Serverless (Cloud Run) | FaaS (Cloud Run functions) | Fully managed data (BigQuery) |
|---|---|---|---|---|---|---|---|
| You manage | Everything | OS, runtime, app | Node OS, workloads | Workloads | Container image | Function source | Query + schema |
| Billing unit | Asset + power | vCPU/RAM-second (1-min min) | Node-seconds | Pod vCPU/RAM-seconds | Request + vCPU/RAM-second | Invocation + GB-s | Bytes scanned or slot-hours |
| Scale-out latency | Weeks | 30–60 s (warm image) | 60–120 s (node add) | ~60 s | 0.1–3 s (cold start) | 0.1–2 s | Instant (slots) |
| Scale-to-zero | No | No | No (node floor) | Near | **Yes** (`minScale: 0`) | Yes | Yes |
| Failure domain you own | Rack/room | Zone (you choose spread) | Zone/region | Region | Region (managed) | Region | Multi-region option |
| Undifferentiated toil | Maximum | High | Medium | Low | Very low | Very low | Minimal |
| Exit cost / portability | N/A | Low (VM images) | Low (OCI + K8s API) | Low–medium | Medium (Knative API helps) | Medium–high | High (SQL dialect + data gravity) |
| Best fit | Regulated fixed workload | Legacy, licensed, kernel-dependent | Complex platforms, custom scheduling | Standard microservices | Stateless HTTP, spiky | Event glue | Analytics at scale |

**Trade-off to internalise:** moving down this table monotonically decreases toil and monotonically increases coupling to a provider's control plane. The correct architectural answer is not "always serverless"; it is "pay for control only where control produces differentiated value."

### 2.3 Deployment models: public, hybrid, multicloud

The exam requires you to differentiate these and to state a valid reason for each.

| Model | Definition | Legitimate drivers | Real costs | Google Cloud products |
|---|---|---|---|---|
| Public cloud | All workloads on a provider's infrastructure | Maximum elasticity, lowest toil, fastest iteration | Provider dependency; egress economics | Full platform |
| Private cloud | Cloud-like self-service on dedicated infrastructure | Data residency, latency to factory-floor systems, sunk hardware | You still own capacity planning | Google Distributed Cloud |
| Hybrid | Public + private, deliberately connected, workloads split by constraint | Migration in flight; mainframe/ERP anchor; regulator requires on-soil data; sub-5 ms plant latency | Two control planes, two security models, WAN as a hard dependency | Cloud VPN, Cloud Interconnect, GKE Enterprise (fleets), Google Distributed Cloud, VMware Engine |
| Multicloud | Two or more public providers | Vendor negotiation leverage, jurisdictional/regulatory mandate, acquisition, provider-specific capability | Lowest-common-denominator architecture, duplicated tooling and skills, cross-cloud egress, doubled on-call surface | GKE Enterprise multi-cluster, BigQuery Omni, Cloud Interconnect |

**The architect's warning that the exam will not give you:** multicloud used as a *portability insurance policy* is usually a net negative. It forces every service down to the intersection of all providers' capabilities — the exact managed services that produce the elasticity in §1. Multicloud is justified by a *constraint* (law, contract, acquisition, a capability that exists in only one place), rarely by a *preference*.

### 2.4 Geography: zones, regions, and what the SLA actually buys

| Construct | Definition | Independent failure of | Typical inter-latency |
|---|---|---|---|
| Zone | A deployment area within a region; an isolated failure domain (power, cooling, network) | Power/hardware/rack events | < 1 ms intra-zone |
| Region | ≥ 3 zones in one metro | Zone-level events, not metro events | ~1–2 ms inter-zone |
| Multi-region | Data replicated across regions | Metro/geographic events | 10–150 ms, continent-dependent |

Availability targets, expressed as monthly error budget — the SRE translation of an SLA:

| Target | Downtime / 30-day month | Downtime / year |
|---|---|---|
| 99.5 % | 3 h 39 m | 1 d 19 h |
| 99.9 % ("three nines") | 43 m 12 s | 8 h 45 m |
| 99.95 % | 21 m 36 s | 4 h 22 m |
| 99.99 % ("four nines") | 4 m 19 s | 52 m 35 s |
| 99.999 % ("five nines") | 25.9 s | 5 m 15 s |

Indicative Google Cloud SLA tiers (**always verify against the live SLA page before quoting to a customer — these are contractual and change**):

| Service | Configuration | Published target |
|---|---|---|
| Compute Engine | Single instance | 99.9 % |
| Compute Engine | Instances across ≥ 2 zones behind a load balancer | 99.99 % |
| GKE | Zonal cluster control plane | 99.5 % |
| GKE | Regional cluster control plane | 99.95 % |
| Cloud Run | Regional | 99.95 % |
| Cloud Storage | Regional, Standard class | 99.9 % |
| Cloud Storage | Multi-region / dual-region, Standard class | 99.95 % |
| Cloud Spanner | Regional | 99.99 % |
| Cloud Spanner | Multi-region | 99.999 % |

Two properties of an SLA that engineers routinely misread, and that separate a Digital Leader from a marketing summary:

1. **An SLA is a refund schedule, not a reliability guarantee.** The remedy is a service credit — a percentage of that service's monthly bill. It never compensates the revenue lost during the outage. Design to your SLO; the SLA only bounds the vendor's liability.
2. **An SLA is void if you do not meet its architectural preconditions.** The 99.99 % Compute Engine figure requires instances in *multiple zones* behind load balancing. A single VM in one zone is contractually 99.9 %, whatever the marketing deck said.

### 2.5 Pricing mechanisms — how "measured service" becomes money

| Mechanism | What it is | Typical saving | Commitment / risk |
|---|---|---|---|
| On-demand | Per-second billing, 1-minute minimum | Baseline | None |
| Sustained Use Discounts (SUD) | Automatic, applied as an instance runs a larger share of the month (N-, C-, M-series; E2 excluded because its rate already embeds it) | up to ~30 % | None — automatic, no action |
| Committed Use Discounts — resource-based | Commit to vCPU/RAM in a region for 1 or 3 years | ~37 % / ~55 % | Pay whether or not you use it |
| Committed Use Discounts — spend-based (flexible) | Commit to an hourly spend across eligible services | ~28 % / ~46 % | Pay whether or not you use it |
| Spot VMs | Preempt-able surplus capacity, 30 s termination notice, no max runtime | 60–91 % | Can vanish at any moment |
| Autoscaling to zero | Serverless `minScale: 0` | 100 % of idle | Cold-start latency |
| Storage class / Autoclass | Standard → Nearline → Coldline → Archive | up to ~95 % on cold data | Retrieval fees, minimum storage durations |

**Correct layering** for a steady production estate: commit (CUD) to the *measured p10 floor*, autoscale on-demand between p10 and p95, absorb the tail and all batch on Spot. Committing to the peak reproduces the on-premises mistake with a contract instead of a purchase order.

---

## 3. Complete infrastructure — elasticity as code

The following is a coherent, deployable set. Nothing is elided. Together they encode the whole argument of §1: bounded elasticity, attributable cost, enforced spend guardrails, and a declared reliability objective.

### 3.1 Terraform — governed project with a hard financial guardrail

```hcl
# ---------------------------------------------------------------------------
# versions.tf
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "acme-tfstate-prod"
    prefix = "platform/retail-frontend"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# variables.tf
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "Target Google Cloud project ID."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID, format XXXXXX-XXXXXX-XXXXXX."
  type        = string
}

variable "region" {
  description = "Primary region for the regional MIG."
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "Zones the regional MIG spreads across. Three zones survive one zone loss at N+1."
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-f"]
}

variable "monthly_budget_usd" {
  description = "Monthly budget ceiling used for alerting. NOTE: a budget alerts, it does not cap."
  type        = number
  default     = 5000
}

# ---------------------------------------------------------------------------
# billing.tf  --  cost becomes telemetry, and telemetry becomes an alert
# ---------------------------------------------------------------------------
resource "google_pubsub_topic" "budget_events" {
  project = var.project_id
  name    = "billing-budget-events"

  labels = {
    owner   = "platform-sre"
    purpose = "finops"
  }
}

resource "google_billing_budget" "retail_frontend" {
  billing_account = var.billing_account
  display_name    = "retail-frontend-monthly"

  budget_filter {
    projects               = ["projects/${var.project_id}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  # Actual spend thresholds.
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # Forecast threshold: fires when the month is PROJECTED to exceed the budget,
  # which is the only threshold that arrives early enough to act on.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    pubsub_topic                     = google_pubsub_topic.budget_events.id
    schema_version                   = "1.0"
    disable_default_iam_recipients   = false
  }
}

# ---------------------------------------------------------------------------
# network.tf  --  a global VPC with one regional subnet
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "retail-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "frontend" {
  project                  = var.project_id
  name                     = "retail-frontend-${var.region}"
  ip_cidr_range            = "10.20.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_health_checks" {
  project = var.project_id
  name    = "allow-gcp-health-checks"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  # Documented Google health-check probe ranges. Without these the MIG will
  # mark every backend UNHEALTHY and autohealing will recreate instances forever.
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["retail-frontend"]
}

# ---------------------------------------------------------------------------
# compute.tf  --  the elasticity mechanism itself
# ---------------------------------------------------------------------------
resource "google_compute_health_check" "frontend" {
  project             = var.project_id
  name                = "retail-frontend-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_instance_template" "frontend" {
  project      = var.project_id
  name_prefix  = "retail-frontend-"
  machine_type = "e2-standard-4"
  region       = var.region
  tags         = ["retail-frontend"]

  labels = {
    owner       = "platform-sre"
    environment = "prod"
    service     = "retail-frontend"
    cost-center = "cc-4417"
  }

  disk {
    source_image = "projects/debian-cloud/global/images/family/debian-12"
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    disk_size_gb = 50
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.frontend.id
    # No access_config block: no external IP. Egress via Cloud NAT.
  }

  scheduling {
    provisioning_model  = "STANDARD"
    automatic_restart   = true
    on_host_maintenance = "MIGRATE" # live migration: maintenance without downtime
  }

  service_account {
    email  = google_service_account.frontend.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(logger -t startup) 2>&1
    apt-get update -qq
    apt-get install -y -qq docker.io
    systemctl enable --now docker
    docker run -d --restart=always -p 8080:8080 \
      us-central1-docker.pkg.dev/${var.project_id}/apps/retail-frontend:v2.14.0
  EOT

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_account" "frontend" {
  project      = var.project_id
  account_id   = "retail-frontend"
  display_name = "Retail frontend runtime identity"
}

resource "google_compute_region_instance_group_manager" "frontend" {
  project                    = var.project_id
  name                       = "retail-frontend-mig"
  region                     = var.region
  base_instance_name         = "retail-frontend"
  distribution_policy_zones  = var.zones
  target_size                = 10 # initial; the autoscaler owns it thereafter

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.frontend.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.frontend.id
    initial_delay_sec = 300 # must exceed worst-case boot + app warm-up
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3 # >= number of zones for a regional MIG
    max_unavailable_fixed        = 0 # zero-downtime rollout
    replacement_method           = "SUBSTITUTE"
  }
}

resource "google_compute_region_autoscaler" "frontend" {
  project = var.project_id
  name    = "retail-frontend-autoscaler"
  region  = var.region
  target  = google_compute_region_instance_group_manager.frontend.id

  autoscaling_policy {
    # min = measured p10 floor; max = a DELIBERATE ceiling, not a guess.
    # 200 * e2-standard-4 is the blast radius of a runaway loop. Price it.
    min_replicas = 10
    max_replicas = 200

    # Time to wait after a new instance before its metrics are trusted.
    # Too low => oscillation. Must be >= boot + warm-up.
    cooldown_period = 120

    mode = "ON"

    cpu_utilization {
      target            = 0.6
      predictive_method = "OPTIMIZE_AVAILABILITY" # pre-warms ahead of learned demand
    }

    load_balancing_utilization {
      target = 0.8
    }

    # Scale-IN control: protects against a metric dip triggering a mass
    # shrink that cannot be undone fast enough when load returns.
    scale_in_control {
      time_window_sec = 600

      max_scaled_in_replicas {
        percent = 20
      }
    }
  }
}

# ---------------------------------------------------------------------------
# slo.tf  --  reliability declared as a measurable objective
# ---------------------------------------------------------------------------
resource "google_monitoring_custom_service" "retail_frontend" {
  project      = var.project_id
  service_id   = "retail-frontend"
  display_name = "Retail Frontend"
}

resource "google_monitoring_slo" "availability" {
  project = var.project_id
  service = google_monitoring_custom_service.retail_frontend.service_id
  slo_id  = "availability-99-9"

  display_name        = "99.9% of HTTP requests non-5xx over 28 days"
  goal                = 0.999
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      total_service_filter = join(" AND ", [
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
        "resource.type=\"https_lb_rule\"",
      ])
      bad_service_filter = join(" AND ", [
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
        "resource.type=\"https_lb_rule\"",
        "metric.label.\"response_code_class\"=\"500\"",
      ])
    }
  }
}
```

### 3.2 GKE — cluster autoscaler plus workload autoscaler

Two independent control loops. Confusing them is the single most common autoscaling incident in production: the HPA adds Pods, and the cluster autoscaler adds Nodes to hold them. If the HPA is misconfigured the Nodes never arrive; if the Node pool ceiling is reached the Pods stay `Pending` forever.

```yaml
# deployment.yaml
# Resource REQUESTS are mandatory. The HPA computes utilisation as
# usage/request, and the cluster autoscaler bin-packs on requests.
# A Pod with no requests is invisible to both loops.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: retail-frontend
  namespace: retail
  labels:
    app: retail-frontend
    cost-center: cc-4417
spec:
  replicas: 6
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: retail-frontend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: retail-frontend
        cost-center: cc-4417
    spec:
      serviceAccountName: retail-frontend
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: retail-frontend
      containers:
        - name: app
          image: us-central1-docker.pkg.dev/acme-prod/apps/retail-frontend:v2.14.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              # No CPU limit on purpose: CFS throttling at the limit inflates
              # tail latency. Memory IS limited, because OOM is preferable to
              # a node-wide memory-pressure eviction cascade.
              memory: "1Gi"
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
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 5
          lifecycle:
            preStop:
              exec:
                # Drain window: let the load balancer notice NotReady before exit.
                command: ["/bin/sh", "-c", "sleep 15"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
# hpa.yaml -- the WORKLOAD control loop
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: retail-frontend
  namespace: retail
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: retail-frontend
  minReplicas: 6
  maxReplicas: 300
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "400"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0        # react to a spike immediately
      selectPolicy: Max
      policies:
        - type: Percent
          value: 100                        # allow doubling
          periodSeconds: 30
        - type: Pods
          value: 20
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 600       # shrink slowly and deliberately
      selectPolicy: Min
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
---
# pdb.yaml -- without this, a node upgrade or scale-in can remove every replica
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: retail-frontend
  namespace: retail
spec:
  minAvailable: 80%
  selector:
    matchLabels:
      app: retail-frontend
---
# resourcequota.yaml -- the namespace-level spend guardrail
apiVersion: v1
kind: ResourceQuota
metadata:
  name: retail-quota
  namespace: retail
spec:
  hard:
    requests.cpu: "300"
    requests.memory: 600Gi
    limits.memory: 900Gi
    count/deployments.apps: "40"
```

### 3.3 Cloud Run — scale to zero, the purest form of elasticity

```yaml
# service.yaml  --  deploy with: gcloud run services replace service.yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: retail-checkout
  namespace: acme-prod
  labels:
    cloud.googleapis.com/location: us-central1
    cost-center: cc-4417
  annotations:
    run.googleapis.com/ingress: internal-and-cloud-load-balancing
spec:
  template:
    metadata:
      annotations:
        # minScale 2 buys away the cold start for the latency-critical path.
        # minScale 0 would be free at idle but adds p99 cold-start latency.
        autoscaling.knative.dev/minScale: "2"
        # The financial blast radius. Choose it; do not inherit the default.
        autoscaling.knative.dev/maxScale: "1000"
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/cpu-throttling: "false"
        run.googleapis.com/startup-cpu-boost: "true"
        run.googleapis.com/vpc-access-egress: private-ranges-only
    spec:
      serviceAccountName: retail-checkout@acme-prod.iam.gserviceaccount.com
      # Requests handled simultaneously per instance. This is the single
      # biggest cost lever on Cloud Run: 80 concurrent requests on one
      # instance costs ~1/80th of 80 instances at concurrency 1.
      containerConcurrency: 80
      timeoutSeconds: 60
      containers:
        - image: us-central1-docker.pkg.dev/acme-prod/apps/retail-checkout:v3.2.1
          ports:
            - name: http1
              containerPort: 8080
          resources:
            limits:
              cpu: "2"
              memory: 1Gi
          env:
            - name: SPANNER_INSTANCE
              value: retail-prod
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: checkout-db-password
                  key: latest
          startupProbe:
            tcpSocket:
              port: 8080
            failureThreshold: 10
            periodSeconds: 3
  traffic:
    - percent: 100
      latestRevision: true
```

---

## 4. CLI: making the abstraction observable

### 4.1 Bootstrap and inspect the elasticity mechanism

```console
$ gcloud config set project acme-prod
Updated property [core/project].

$ terraform apply -auto-approve
...
Apply complete! Resources: 14 added, 0 changed, 0 destroyed.

$ gcloud compute instance-groups managed describe retail-frontend-mig \
    --region=us-central1 \
    --format="yaml(name, targetSize, currentActions, status.isStable)"
currentActions:
  abandoning: 0
  creating: 0
  deleting: 0
  none: 10
  recreating: 0
  refreshing: 0
  restarting: 0
  verifying: 0
name: retail-frontend-mig
status:
  isStable: true
targetSize: 10
```

`status.isStable: true` is the assertion to gate a deploy pipeline on. Any non-zero value outside `none` means the group is mid-reconciliation.

### 4.2 Watching elasticity under real load

```console
$ gcloud compute instance-groups managed list-instances retail-frontend-mig \
    --region=us-central1 \
    --format="table(name, zone.basename(), status, instanceHealth[0].detailedHealthState)" \
  | head -6
NAME                    ZONE            STATUS   DETAILED_HEALTH_STATE
retail-frontend-2k4x    us-central1-a   RUNNING  HEALTHY
retail-frontend-7bqn    us-central1-b   RUNNING  HEALTHY
retail-frontend-9wlm    us-central1-f   RUNNING  HEALTHY
retail-frontend-c3tt    us-central1-a   RUNNING  HEALTHY
retail-frontend-dz8p    us-central1-b   RUNNING  HEALTHY

$ # Load test starts here (48k rps ramp).
$ watch -n 30 'gcloud compute instance-groups managed describe \
    retail-frontend-mig --region=us-central1 --format="value(targetSize)"'

# t+00:00   10
# t+02:00   20
# t+04:00   40
# t+06:00   80
# t+08:00  124
# t+10:00  124      <- steady state at 60% CPU target
# ... load test ends ...
# t+22:00  100      <- scale_in_control: max 20% per 600s window
# t+32:00   80
# t+42:00   64
```

Read that trace as the answer to the exam objective. Peak-provisioned capacity was never purchased. The scale-out took **eight minutes**, not eight weeks. The scale-in is deliberately slower than the scale-out — asymmetry is correct, because being too small costs revenue and being too big only costs money.

### 4.3 Cost as telemetry — querying the billing export

```console
$ bq query --use_legacy_sql=false --format=prettyjson '
WITH daily AS (
  SELECT
    DATE(usage_start_time, "America/Argentina/Buenos_Aires") AS day,
    service.description                                      AS service,
    (SELECT value FROM UNNEST(labels) WHERE key = "service")  AS svc_label,
    SUM(cost)                                                AS gross,
    SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits
  FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_01ABCD_2EF345_6789AB`
  WHERE DATE(_PARTITIONTIME) BETWEEN "2026-08-25" AND "2026-08-31"
    AND project.id = "acme-prod"
  GROUP BY day, service, svc_label
)
SELECT day, service, svc_label,
       ROUND(gross, 2)            AS gross_usd,
       ROUND(credits, 2)          AS credits_usd,
       ROUND(gross + credits, 2)  AS net_usd
FROM daily
WHERE gross > 5
ORDER BY net_usd DESC
LIMIT 5'
Waiting on bqjob_r5b2f19d0c8a4e7f1_0000019a2c7f_1 ... (2s) Current status: DONE
[
  {
    "day": "2026-08-29",
    "service": "Compute Engine",
    "svc_label": "retail-frontend",
    "gross_usd": "1842.66",
    "credits_usd": "-503.14",
    "net_usd": "1339.52"
  },
  {
    "day": "2026-08-29",
    "service": "BigQuery",
    "svc_label": "analytics-etl",
    "gross_usd": "912.40",
    "credits_usd": "0.0",
    "net_usd": "912.40"
  },
  {
    "day": "2026-08-30",
    "service": "Compute Engine",
    "svc_label": "retail-frontend",
    "gross_usd": "701.03",
    "credits_usd": "-197.88",
    "net_usd": "503.15"
  }
]
```

The `-503.14` credit line is Sustained Use Discount plus committed-use credit applied automatically. **This query is the whole "measured service" characteristic made concrete**: cost attributed to a day, a service, and a label, at resource granularity — the thing an on-premises estate structurally cannot produce.

### 4.4 Active Assist — the platform recommending your own right-sizing

```console
$ gcloud recommender recommendations list \
    --project=acme-prod \
    --location=us-central1-a \
    --recommender=google.compute.instance.MachineTypeRecommender \
    --format="table(name.basename(), priority, primaryImpact.costProjection.cost.units, description)"
NAME                                  PRIORITY  UNITS  DESCRIPTION
b47f2c91-0e33-4f6a-9c21-7ad5e1cf88a0  P2        -41    Save cost by changing machine type from e2-standard-8 to e2-standard-4.
d90a1b74-55c8-4e12-b3ff-2c9d0e6a1177  P3        -18    Save cost by changing machine type from n2-standard-4 to n2-standard-2.

$ gcloud recommender recommendations list \
    --project=acme-prod --location=global \
    --recommender=google.cloudbilling.commitment.SpendBasedCommitmentRecommender \
    --format="value(description)"
Save $2,184.00/month by purchasing a 1-year spend-based commitment of $9.12/hour for Compute Engine.
```

### 4.5 Verifying the guardrail exists

```console
$ gcloud billing budgets list --billing-account=01ABCD-2EF345-6789AB \
    --format="table(displayName, amount.specifiedAmount.units, thresholdRules[].thresholdPercent)"
DISPLAY_NAME              UNITS  THRESHOLD_PERCENT
retail-frontend-monthly   5000   [0.5, 0.9, 1.0, 1.0]

$ gcloud compute regions describe us-central1 \
    --flatten="quotas[]" \
    --format="table(quotas.metric, quotas.limit, quotas.usage)" \
  | grep -E "CPUS|IN_USE_ADDRESSES"
CPUS                        2400.0   496.0
CPUS_ALL_REGIONS            4800.0   612.0
IN_USE_ADDRESSES              75.0    12.0
```

Read this before a peak event, not during it. `max_replicas: 200 × e2-standard-4 = 800 vCPU` must fit inside the regional `CPUS` quota **with** whatever else runs in that region. This is the single most common cause of a failed scale-out.

---

## 5. Verification and failure diagnosis

### 5.1 The pre-peak readiness checklist

```console
$ # 1. Is the group stable and fully healthy?
$ gcloud compute instance-groups managed describe retail-frontend-mig \
    --region=us-central1 --format="value(status.isStable)"
True

$ # 2. Is the autoscaler ON, and does its ceiling fit inside quota?
$ gcloud compute region-autoscalers describe retail-frontend-autoscaler \
    --region=us-central1 \
    --format="value(autoscalingPolicy.mode, autoscalingPolicy.maxNumReplicas)"
ON      200

$ # 3. Are backends actually HEALTHY from the load balancer's point of view?
$ gcloud compute backend-services get-health retail-frontend-bes --global \
    --format="value(status.healthStatus[].healthState)" | sort | uniq -c
     10 HEALTHY

$ # 4. Does the SLO have error budget left to spend?
$ gcloud alpha monitoring slos list \
    --service=retail-frontend --project=acme-prod \
    --format="table(displayName, goal, rollingPeriod)"
DISPLAY_NAME                                        GOAL   ROLLING_PERIOD
99.9% of HTTP requests non-5xx over 28 days         0.999  2419200s
```

### 5.2 Failure catalogue — symptom, mechanism, command

| Symptom | Actual cause | Diagnostic command | Fix |
|---|---|---|---|
| MIG will not exceed N instances | Regional `CPUS` quota exhausted | `gcloud compute operations list --filter="error.errors.code=QUOTA_EXCEEDED" --limit=5` | Request quota increase **days** in advance; it is not instant |
| `ZONE_RESOURCE_POOL_EXHAUSTED` on create | That machine family is momentarily unavailable in that zone | `gcloud compute operations describe <op> --zone=<zone>` | Spread across ≥ 3 zones (regional MIG); consider a second machine family |
| Pods stuck `Pending`, no new Nodes | Node pool at `maxNodeCount`, or Pod is unschedulable for a reason autoscaling cannot fix | `kubectl describe pod <p>` → look for `pod didn't trigger scale-up` | Raise the pool ceiling **or** fix affinity/taint/PVC-zone conflict |
| HPA shows `<unknown>/60%` | Container has no `resources.requests.cpu`; utilisation is undefined | `kubectl get hpa -n retail` | Add requests. This is non-negotiable for autoscaling |
| Autoscaler oscillates (flapping) | `cooldown_period` shorter than boot + warm-up; metrics from unwarmed instances | Compare `initial_delay_sec` and `cooldown_period` against measured boot time | Set cooldown > p99 warm-up; add `scale_in_control` |
| Node upgrade hangs on drain | A PDB that can never be satisfied (`minAvailable` ≥ `replicas`) | `kubectl get pdb -n retail -o wide` | `ALLOWED DISRUPTIONS` must be ≥ 1 |
| Budget exceeded, no alert fired | Only `CURRENT_SPEND` thresholds configured; data lags | `gcloud billing budgets describe <id>` | Add a `FORECASTED_SPEND` rule |
| Budget alert fired, spend continued | **Budgets alert; they do not cap.** By design | — | Enforce with quota, `maxScale`/`max_replicas`, `ResourceQuota`, and a Pub/Sub-triggered kill switch |
| Batch jobs die at random | Spot VM preemption — expected behaviour | `gcloud compute operations list --filter="operationType=compute.instances.preempted"` | Checkpoint; handle the 30 s `ACPI G2` notice; mixed Spot/Standard MIG |
| Hybrid workload intermittently unreachable | Single Cloud Interconnect attachment; no redundancy | `gcloud compute interconnects attachments describe <a> --region=<r>` | Two attachments in different edge availability domains for the 99.9/99.99 % topology |
| Cloud Run p99 spikes at low traffic | Cold starts at `minScale: 0` | Cloud Monitoring `run.googleapis.com/container/startup_latencies` | `minScale: >0` and `startup-cpu-boost` for latency-critical paths |

### 5.3 Reproducing the two most instructive failures

**Autoscaling blocked by a missing resource request:**

```console
$ kubectl get hpa -n retail
NAME              REFERENCE                    TARGETS              MINPODS  MAXPODS  REPLICAS  AGE
retail-frontend   Deployment/retail-frontend   <unknown>/60%, 0/400 6        300      6         14m

$ kubectl describe hpa retail-frontend -n retail | tail -6
Conditions:
  Type            Status  Reason                   Message
  ----            ------  ------                   -------
  AbleToScale     True    SucceededGetScale        the HPA controller was able to get the target's current scale
  ScalingActive   False   FailedGetResourceMetric  failed to get cpu utilization: missing request for cpu in container app of Pod retail-frontend-6d4b9c7f88-x2pql
```

`<unknown>` means the loop is dead, not idle. The Deployment will never scale, and the incident will present as a latency SLO burn under load with no scaling activity in the timeline.

**Cluster autoscaler at its ceiling:**

```console
$ kubectl get pods -n retail --field-selector=status.phase=Pending
NAME                               READY   STATUS    RESTARTS   AGE
retail-frontend-6d4b9c7f88-4jnwq   0/1     Pending   0          3m21s
retail-frontend-6d4b9c7f88-h7ptl   0/1     Pending   0          3m21s

$ kubectl describe pod retail-frontend-6d4b9c7f88-4jnwq -n retail | tail -5
Events:
  Type     Reason             Age    From                Message
  ----     ------             ----   ----                -------
  Warning  FailedScheduling   3m10s  default-scheduler   0/48 nodes are available: 48 Insufficient cpu.
  Normal   NotTriggerScaleUp  3m05s  cluster-autoscaler  pod didn't trigger scale-up: 1 max node group size reached
```

`max node group size reached` is not a bug — it is a **guardrail doing exactly what it was configured to do**. This is the decisive point of §1.3: elasticity without a ceiling is an unbounded liability, and a ceiling that is hit during a peak is a capacity-planning failure that has simply moved from procurement to a Terraform variable. The planning did not disappear; it became a code review with a two-minute feedback loop instead of a purchase order with a twelve-week one.

### 5.4 Proving the transformation quantitatively

Close the loop by comparing the actual bill against the counterfactual:

```console
$ bq query --use_legacy_sql=false --format=csv '
SELECT
  ROUND(SUM(cost), 2)                                   AS actual_elastic_usd,
  ROUND(MAX(peak_vcpu) * 24 * 30 * 0.0316, 2)           AS peak_provisioned_usd
FROM (
  SELECT cost,
         SUM(CAST(usage.amount AS FLOAT64)) OVER (PARTITION BY usage_start_time) AS peak_vcpu
  FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_01ABCD_2EF345_6789AB`
  WHERE service.description = "Compute Engine"
    AND sku.description LIKE "%Core running%"
    AND DATE(_PARTITIONTIME) BETWEEN "2026-08-01" AND "2026-08-31"
)'
actual_elastic_usd,peak_provisioned_usd
18442.19,71308.80
```

Roughly **4×**, on one service, in one month, without a single procurement conversation. That ratio — not the technology — is the sentence "the cloud is revolutionising business."

---

## 6. Exam-oriented distillation

Terms that appear verbatim in Cloud Digital Leader questions, with the precise distinction each one tests:

| Term | Precise meaning | Common distractor |
|---|---|---|
| Digital transformation | Changing how the organisation operates and delivers value using data and technology | "Moving VMs to the cloud" — that is rehosting |
| Rehost (lift-and-shift) | Move as-is, no re-architecture | Fastest, lowest benefit ceiling |
| Replatform (move-and-improve) | Move with targeted modernisation (e.g. VM → managed DB) | The usual pragmatic middle |
| Refactor / rearchitect | Rebuild cloud-native | Highest benefit, highest cost |
| Scalability | Can grow | Not the same as elasticity |
| Elasticity | Grows **and shrinks** automatically with demand | The one that returns money |
| Agility | Speed of experimentation and delivery | Enabled by self-service, not by hardware |
| CapEx → OpEx | Fixed asset purchase → metered consumption | Not automatically cheaper |
| TCO | All costs, including power, space, labour, refresh, disposal | Not just the invoice |
| Shared responsibility | Provider secures *of* the cloud; you secure *in* the cloud; the boundary moves with the service model | Not "the cloud is secure" |
| Shared fate | Google's active posture: opinionated blueprints, guardrails, risk protection — going beyond a static responsibility line | Distinct from shared responsibility |
| Hybrid | Public + private, connected on purpose | Not the same as multicloud |
| Multicloud | Two or more public providers | Justified by constraint, not preference |
| Data as a competitive asset | Value comes from acting on data, not storing it | The reason managed analytics/AI matter |
| Sustainability | Google Cloud reports customer-attributed emissions; region choice changes the carbon profile | Verifiable via Carbon Footprint export |

**Three claims a Digital Leader must be able to defend under challenge:**

1. *Cloud is not automatically cheaper.* It is cheaper when demand is variable, when capacity would otherwise be peak-provisioned, and when guardrails are enforced. A flat, fully-utilised, fully-depreciated workload may be cheaper on-premises — and saying so is a mark of competence, not disloyalty.
2. *An SLA is not an SLO.* The SLA is the vendor's refund schedule with architectural preconditions. The SLO is your own target, and its complement is the error budget you spend on change.
3. *Elasticity requires a ceiling.* Capacity planning did not disappear; it changed from a 12-week procurement cycle into a reviewed, versioned, instantly-reversible variable. That change of feedback-loop latency — from months to minutes — is the entire mechanism behind the word "revolutionising."

---

## 7. References

**Exam definition**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Cloud definitions and architecture guidance**
- NIST SP 800-145, *The NIST Definition of Cloud Computing* — https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-145.pdf
- Google Cloud Well-Architected Framework — https://cloud.google.com/architecture/framework
- Cost optimization pillar — https://cloud.google.com/architecture/framework/cost-optimization
- Reliability pillar — https://cloud.google.com/architecture/framework/reliability
- Hybrid and multicloud architecture patterns — https://cloud.google.com/architecture/hybrid-multicloud-patterns
- Landing zone design — https://cloud.google.com/architecture/landing-zones

**Elasticity mechanisms**
- Regions and zones — https://cloud.google.com/compute/docs/regions-zones
- Managed instance groups — https://cloud.google.com/compute/docs/instance-groups
- Autoscaling groups of instances — https://cloud.google.com/compute/docs/autoscaler
- Scale-in controls — https://cloud.google.com/compute/docs/autoscaler/understanding-autoscaler-decisions
- Live migration — https://cloud.google.com/compute/docs/instances/live-migration-process
- GKE cluster autoscaler — https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler
- Horizontal Pod autoscaling in GKE — https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler
- GKE Autopilot overview — https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview
- Cloud Run autoscaling — https://cloud.google.com/run/docs/about-instance-autoscaling
- Cloud Run YAML reference — https://cloud.google.com/run/docs/reference/yaml/v1

**Cost, metering and governance**
- Google Cloud pricing model — https://cloud.google.com/pricing
- Sustained use discounts — https://cloud.google.com/compute/docs/sustained-use-discounts
- Committed use discounts — https://cloud.google.com/docs/cuds
- Spot VMs — https://cloud.google.com/compute/docs/instances/spot
- Cloud Billing budgets and alerts — https://cloud.google.com/billing/docs/how-to/budgets
- Programmatic budget notifications — https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
- Billing export to BigQuery — https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- Active Assist and Recommender — https://cloud.google.com/recommender/docs/overview
- Quotas and limits — https://cloud.google.com/docs/quotas

**Reliability, SLAs and SLOs**
- Google Cloud service level agreements — https://cloud.google.com/terms/sla
- Compute Engine SLA — https://cloud.google.com/compute/sla
- GKE SLA — https://cloud.google.com/kubernetes-engine/sla
- Cloud Run SLA — https://cloud.google.com/run/sla
- Service monitoring / SLOs — https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- SRE Book, *Embracing Risk* (error budgets) — https://sre.google/sre-book/embracing-risk/
- SRE Workbook, *Implementing SLOs* — https://sre.google/workbook/implementing-slos/

**Hybrid, multicloud and connectivity**
- GKE Enterprise overview — https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview
- Google Distributed Cloud — https://cloud.google.com/distributed-cloud
- Google Cloud VMware Engine — https://cloud.google.com/vmware-engine/docs/overview
- Cloud Interconnect — https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview
- BigQuery Omni — https://cloud.google.com/bigquery/docs/omni-introduction

**Security model and sustainability**
- Shared responsibility and shared fate — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google security overview — https://cloud.google.com/docs/security/overview/whitepaper
- Carbon Footprint — https://cloud.google.com/carbon-footprint
- Carbon Footprint BigQuery export — https://cloud.google.com/carbon-footprint/docs/export

**Tooling**
- Terraform `google_billing_budget` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/billing_budget
- Terraform `google_compute_region_autoscaler` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_region_autoscaler
- Terraform `google_monitoring_slo` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_slo