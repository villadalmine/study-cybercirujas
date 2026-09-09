# 1.2 — Describe fundamental cloud concepts

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12)
**Exam weight:** 9.0
**Audience profile:** Platform Architect / SRE. This objective is scored as vocabulary, but it is *practised* as capacity planning, failure-domain design and unit economics. The material below teaches the second thing, because it is the only reliable way to answer the first without memorising.

---

## 1. Motivation: the architectural problem this objective exists to solve

Every "fundamental cloud concept" in the exam guide is a formal name for one of two production failures that predate cloud computing:

**Failure 1 — the peak-provisioning tax.** On-premises capacity is a step function purchased in advance against a forecast. The forecast must cover peak, so the fleet is sized for the worst hour of the worst day of the year. A retail platform whose Black Friday peak is 4× its median load runs at ~25% average utilisation for 364 days to survive one. You pay 100% of the capex to use 25% of the capacity, and you pay it 18 months before the traffic arrives, on a depreciation schedule that outlives the architecture.

**Failure 2 — the correlated-failure blind spot.** A "highly available" pair of servers in the same rack shares a top-of-rack switch, a PDU, a cooling loop, a building and a utility feed. The availability arithmetic assumed independent failures; the physical layout guaranteed dependent ones. Every real outage post-mortem in this class ends with the same sentence: *we had two of everything, in one of somewhere.*

Cloud computing does not delete either problem. It **converts them into API-addressable parameters**:

| Pre-cloud problem | Cloud concept that names it | The parameter you now control |
|---|---|---|
| Capacity bought 18 months early | On-demand self-service + rapid elasticity | `--min-replicas` / `--max-replicas`, seconds to provision |
| 25% average utilisation | Resource pooling + measured service | Per-second billing, Spot, committed-use discounts |
| Two of everything in one building | Regions and zones | `--zone`, `--region`, `topologySpreadConstraints` |
| "Who patched the kernel?" | Shared responsibility model | Choice of IaaS / PaaS / SaaS |
| "The regulator says the data cannot leave the country" | Deployment models + data residency | Org policy `gcp.resourceLocations` |
| Capex depreciation vs. actual usage | TCO, capex → opex | Billing export, budgets, FinOps unit cost |

**The exam-relevant framing:** these concepts are not marketing. Each one is a control surface with a default that is wrong for production, and knowing which default is wrong is the difference between a Digital Leader who can scope a migration and one who signs off on a lift-and-shift that triples the bill.

---

## 2. The five essential characteristics (NIST SP 800-145), mapped to real control surfaces

NIST SP 800-145 is the definition Google's own documentation and the exam guide track. Memorise the five names; understand them through the mechanism.

| NIST characteristic | Plain definition | Google Cloud mechanism | How you *prove* it is working | Failure mode when it is not |
|---|---|---|---|---|
| **On-demand self-service** | A consumer can provision capacity unilaterally, without human interaction from the provider | Cloud Console, `gcloud`, REST API, Terraform, Deployment Manager | A `gcloud compute instances create` returns `RUNNING` in <60 s with no ticket | An internal "cloud" that requires a change-approval board is IaaS-shaped, not on-demand — the elasticity benefit evaporates |
| **Broad network access** | Capabilities available over the network via standard mechanisms, from heterogeneous clients | Global anycast front-end, Cloud Load Balancing, Premium/Standard network tiers, Cloud CDN | `curl -sI https://<GLB-IP>` resolves to the same VIP from three continents | Regional-only endpoints; clients in APAC paying a 250 ms RTT penalty to reach `us-central1` |
| **Resource pooling** | Multi-tenant model; physical/virtual resources dynamically assigned; location independence at an abstract level (country/region/DC) | Live Migration, custom machine types, GKE bin-packing, shared VPC | Two VMs on the same host survive a host maintenance event without reboot | Noisy-neighbour contention; or the opposite — regulatory requirement for single-tenancy, solved with **sole-tenant nodes** |
| **Rapid elasticity** | Capabilities provision and release elastically, appearing unlimited to the consumer | Managed Instance Groups + autoscaler, GKE Cluster Autoscaler + HPA, Cloud Run concurrency scaling to zero | Load test drives replicas from 3 → 40 → 3 without human action | Autoscaler cools down slower than traffic ramps; or a quota ceiling silently caps growth (see §8.2) |
| **Measured service** | Resource use is metered, controlled and reported — transparency for provider and consumer | Cloud Billing BigQuery export, per-second billing, Cloud Monitoring, budgets and alerts | A BigQuery query attributes >95% of spend to a labelled team/service | Untagged resources; a bill you can describe but not decompose — the single most common FinOps failure |

> **The exam trap.** *Rapid elasticity* is about the **speed and automation** of scaling. *Resource pooling* is about **multi-tenancy and location abstraction**. *Measured service* is about **metering and pay-per-use**. Questions describing "you only pay for the seconds you consume" test measured service, not elasticity.

### 2.1 Proving "measured service" — the billing export query

Measured service is worthless if you cannot attribute it. This is the query every platform team runs weekly:

```sql
-- Cost attribution by service, SKU, project and region for a billing period.
-- Requires the detailed (resource-level) Cloud Billing export to BigQuery.
SELECT
  service.description                              AS service,
  sku.description                                  AS sku,
  project.id                                       AS project,
  IFNULL(location.region, 'global')                AS region,
  (SELECT value FROM UNNEST(labels) WHERE key = 'team')     AS team,
  ROUND(SUM(usage.amount_in_pricing_units), 2)     AS usage_units,
  ANY_VALUE(usage.pricing_unit)                    AS unit,
  ROUND(SUM(cost), 2)                              AS gross_cost_usd,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS credits_usd,
  ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS net_cost_usd
FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_0123AB_4567CD_89EFGH`
WHERE DATE(_PARTITIONTIME) BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY service, sku, project, region, team
HAVING net_cost_usd > 50
ORDER BY net_cost_usd DESC
LIMIT 15;
```

```
$ bq query --use_legacy_sql=false --format=pretty < cost_attribution.sql
+---------------------+--------------------------------------------+-------------------+-------------+---------+-------------+----------+----------------+-------------+--------------+
|       service       |                    sku                     |      project      |   region    |  team   | usage_units |   unit   | gross_cost_usd | credits_usd | net_cost_usd |
+---------------------+--------------------------------------------+-------------------+-------------+---------+-------------+----------+----------------+-------------+--------------+
| Compute Engine      | N2 Instance Core running in Americas       | acme-prod-platform| us-central1 | platform|   198412.50 | hour     |       6272.99  |    -2071.05 |      4201.94 |
| Compute Engine      | N2 Instance Ram running in Americas        | acme-prod-platform| us-central1 | platform|   793650.00 | gibibyte |       3362.79  |    -1109.72 |      2253.07 |
| Networking          | Network Internet Egress from Americas to...| acme-prod-edge    | us-central1 | edge    |    15360.00 | gibibyte |       1791.36  |        0.00 |      1791.36 |
| Cloud Storage       | Standard Storage US Multi-region           | acme-prod-data    | us          | data    |    81920.00 | gibibyte |       2211.84  |        0.00 |      2211.84 |
| BigQuery            | Analysis (on demand)                       | acme-prod-data    | US          | data    |      284.10 | tebibyte |       1775.63  |        0.00 |      1775.63 |
| Kubernetes Engine   | Autopilot Pod Memory Requests (Regular)    | acme-prod-apps    | us-central1 | apps    |   410880.00 | gibibyte |       1808.00  |        0.00 |      1808.00 |
| Cloud SQL           | Cloud SQL for PostgreSQL: Regional - vCPU  | acme-prod-apps    | us-central1 | apps    |    11680.00 | hour     |        747.52  |        0.00 |       747.52 |
| Compute Engine      | Balanced PD Capacity                       | acme-prod-platform| us-central1 | platform|    20480.00 | gibibyte |       2048.00  |        0.00 |      2048.00 |
| Compute Engine      | Spot Preemptible N2 Instance Core          | acme-batch        | us-central1 | ml      |    87600.00 | hour     |        830.66  |        0.00 |       830.66 |
| Cloud Run           | CPU Allocation Time (Tier 1)               | acme-prod-api     | us-central1 | api     |   1204800.00| second   |        289.15  |        0.00 |       289.15 |
+---------------------+--------------------------------------------+-------------------+-------------+---------+-------------+----------+----------------+-------------+--------------+
```

Read that output as an architect, not an accountant. The line that should stop you is **Network Internet Egress: $1,791 for 15 TiB** — a cost line with no compute, no storage and no feature attached to it. Egress is the tax on data gravity, and it is invisible in every architecture diagram ever drawn. §7.4 covers it.

---

## 3. Service models: IaaS, PaaS, SaaS — and the two the exam guide implies

NIST names three. Production uses five rungs. The exam asks about the three; the architecture depends on all five.

```
                            You manage ▓   Google manages ░
  ┌───────────────┬──────────────────────────────────────────────────────────┐
  │ On-premises   │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ IaaS   (GCE)  │ ░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ CaaS   (GKE)  │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ PaaS   (Run)  │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ FaaS (Functions)│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ SaaS (Workspace)│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓ │
  └───────────────┴──────────────────────────────────────────────────────────┘
    Facility→Hardware→Network→Hypervisor→OS→Runtime→App→Config→Data→Access
```

### 3.1 Trade-off matrix

| Dimension | IaaS (Compute Engine) | CaaS (GKE Standard) | CaaS-managed (GKE Autopilot) | PaaS (Cloud Run) | FaaS (Cloud Run functions) | SaaS (Workspace, Looker) |
|---|---|---|---|---|---|---|
| **Unit of deployment** | VM disk image | Container + node pool | Container + Pod spec | Container image | Function source | Nothing — you configure |
| **You patch** | Guest OS, kernel, runtime, app | Node OS (or use auto-upgrade), image, app | Image, app | Image, app | Function code | Nothing |
| **Scale-to-zero** | No | No (nodes persist) | No (control plane persists) | **Yes** | **Yes** | N/A |
| **Provision latency (cold)** | 20–60 s (VM boot) | 30–120 s (node scale-up) | 30–120 s | ~0.1–3 s typical, image-size dependent | ~0.1–2 s | 0 |
| **Billing granularity** | Per second, 1-min minimum | Per second on nodes | Per second on Pod **requests** | Per 100 ms of CPU/memory + requests | Per 100 ms + invocations | Per seat / per user |
| **Max control (kernel modules, GPUs, custom NIC)** | Full | High | Constrained | Low (no privileged, no daemons) | Very low | None |
| **Portability / lock-in** | High portability (VM images) | Highest (plain Kubernetes) | High (Kubernetes API) | Medium (Knative-compatible) | Low (event contract) | Total lock-in |
| **Blast radius of your mistake** | Whole VM fleet | Cluster / namespace | Namespace | Single revision (traffic-split rollback) | Single function | Configuration only |
| **Who is paged at 03:00 for a kernel CVE** | You | You (unless auto-upgrade) | Google | Google | Google | Google |
| **Who is paged at 03:00 for your 500s** | You | You | You | You | You | Vendor |
| **Typical steady-state cost for a constant 4 vCPU workload** | Lowest with 3-yr CUD | Low | Medium | Higher | Highest | Flat per seat |
| **Typical cost for a spiky, 3%-duty-cycle workload** | Highest (idle VMs) | High | Medium | **Lowest** | **Lowest** | N/A |

> **The decision rule that survives contact with production:** choose the *highest* rung on the ladder that still satisfies your hard constraints (kernel access, licence affinity, sub-millisecond latency, sustained 100% duty cycle). Every rung you climb removes an on-call rotation. Every rung you climb also removes an escape hatch — so document *which constraint* forced you to stop climbing, because that constraint is the thing to re-examine in 18 months.

### 3.2 The same workload, four ways — complete, deployable definitions

The workload: a stateless HTTP API, `acme/checkout-api:1.14.2`, listening on `:8080`, `/healthz` for liveness, `/ready` for readiness, needs ~500 m CPU and 512 MiB per replica.

#### 3.2.1 IaaS — Compute Engine regional MIG with autoscaling (Terraform)

```hcl
# main.tf — IaaS: full control, you own the OS.
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region"     { type = string, default = "us-central1" }

# --- Instance template: immutable definition of one VM ------------------------
resource "google_compute_instance_template" "checkout" {
  name_prefix  = "checkout-api-"
  machine_type = "n2-standard-2"
  region       = var.region

  # Rolling replacement instead of in-place mutation.
  lifecycle {
    create_before_destroy = true
  }

  disk {
    source_image = "projects/cos-cloud/global/images/family/cos-stable"
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    disk_size_gb = 20
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block => no external IP. Egress via Cloud NAT.
  }

  service_account {
    email  = google_service_account.checkout.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    # Container-Optimized OS declarative container spec.
    "gce-container-declaration" = yamlencode({
      spec = {
        containers = [{
          name  = "checkout-api"
          image = "us-central1-docker.pkg.dev/${var.project_id}/apps/checkout-api:1.14.2"
          env = [
            { name = "PORT",     value = "8080" },
            { name = "LOG_LEVEL", value = "info" },
          ]
          securityContext = { privileged = false }
          stdin           = false
          tty             = false
        }]
        restartPolicy = "Always"
      }
    })
    "google-logging-enabled"    = "true"
    "google-monitoring-enabled" = "true"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  tags = ["checkout-api", "allow-health-check"]

  labels = {
    team        = "api"
    environment = "prod"
    cost-center = "cc-4471"
  }
}

# --- Regional MIG: spreads instances across all zones in the region -----------
resource "google_compute_region_instance_group_manager" "checkout" {
  name   = "checkout-api-mig"
  region = var.region

  base_instance_name        = "checkout-api"
  distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"]
  # EVEN is the default and the whole point: one zone loss removes ~1/4 of capacity.
  distribution_policy_target_shape = "EVEN"

  version {
    instance_template = google_compute_instance_template.checkout.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.checkout.id
    initial_delay_sec = 90     # Grace period: longer than worst-case cold start.
  }

  update_policy {
    type                           = "PROACTIVE"
    instance_redistribution_type   = "PROACTIVE"
    minimal_action                 = "REPLACE"
    max_surge_fixed                = 4   # Must be >= number of zones for regional MIGs.
    max_unavailable_fixed          = 0   # Zero-downtime rollout.
    replacement_method             = "SUBSTITUTE"
  }
}

# --- Rapid elasticity, expressed as code -------------------------------------
resource "google_compute_region_autoscaler" "checkout" {
  name   = "checkout-api-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.checkout.id

  autoscaling_policy {
    min_replicas    = 4    # One per zone: survives a zonal outage with capacity left.
    max_replicas    = 40
    cooldown_period = 90   # Must exceed boot + warm-up, or you thrash.

    cpu_utilization {
      target            = 0.60
      predictive_method = "OPTIMIZE_AVAILABILITY"  # Scales ahead of a learned daily cycle.
    }

    load_balancing_utilization {
      target = 0.70
    }

    scale_in_control {
      max_scaled_in_replicas {
        percent = 20     # Never remove more than 20% of the fleet per window.
      }
      time_window_sec = 300
    }
  }
}

resource "google_compute_health_check" "checkout" {
  name                = "checkout-api-hc"
  check_interval_sec  = 5
  timeout_sec         = 3
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }

  log_config { enable = true }
}

# --- Network plumbing ---------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "acme-prod-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "checkout-${var.region}"
  ip_cidr_range            = "10.20.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true   # Reach Google APIs without an external IP.

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_health_check" {
  name    = "allow-lb-health-check"
  network = google_compute_network.vpc.id

  # Google's published health-check and LB proxy ranges. Not arbitrary.
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["allow-health-check"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

resource "google_service_account" "checkout" {
  account_id   = "checkout-api"
  display_name = "checkout-api workload identity"
}

output "mig_self_link" {
  value = google_compute_region_instance_group_manager.checkout.self_link
}
```

#### 3.2.2 CaaS — GKE Deployment with correct failure-domain spreading

```yaml
# checkout-api.yaml — CaaS: you own the image and the Pod spec; Google owns the
# control plane (and, on Autopilot, the nodes).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/version: "1.14.2"
    team: api
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/version: "1.14.2"
    spec:
      serviceAccountName: checkout-api          # Bound via Workload Identity Federation.
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # --- Resource pooling made explicit: spread across ZONES, then NODES ----
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule        # Hard: never concentrate in one zone.
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway       # Soft: prefer node spread.
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      containers:
        - name: checkout-api
          image: us-central1-docker.pkg.dev/acme-prod-apps/apps/checkout-api:1.14.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: PORT
              value: "8080"
            - name: POD_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['topology.kubernetes.io/zone']
          resources:
            requests:                 # On Autopilot, requests ARE the billing unit.
              cpu: "500m"
              memory: "512Mi"
              ephemeral-storage: "1Gi"
            limits:
              cpu: "1000m"
              memory: "512Mi"         # limit == request for memory: avoids OOM surprises.
              ephemeral-storage: "1Gi"
          startupProbe:               # Protects slow starts from the liveness probe.
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /ready, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          lifecycle:
            preStop:
              exec:
                # Let the LB deprogram this endpoint before the process dies.
                command: ["/bin/sh", "-c", "sleep 15"]
      terminationGracePeriodSeconds: 45
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    cloud.google.com/neg: '{"ingress": true}'   # Container-native load balancing.
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
# --- Rapid elasticity at the Pod layer ---------------------------------------
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
  namespace: checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 6
  maxReplicas: 60
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
          name: http_requests_per_second     # Exported via Managed Service for Prometheus.
        target:
          type: AverageValue
          averageValue: "120"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 10
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300       # Scale in slowly; scale out fast.
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
# --- Guarantees the autoscaler and node upgrades cannot break the SLO ---------
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: checkout
spec:
  minAvailable: 4            # Survives a full zone drain in a 4-zone region.
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
```

#### 3.2.3 PaaS — Cloud Run service (Knative-style YAML, scale to zero)

```yaml
# service.yaml — PaaS: no nodes, no OS, no cluster. Deploy with:
#   gcloud run services replace service.yaml --region=us-central1
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: checkout-api
  namespace: "471829304517"        # Project number.
  labels:
    cloud.googleapis.com/location: us-central1
    team: api
  annotations:
    run.googleapis.com/ingress: internal-and-cloud-load-balancing
    run.googleapis.com/launch-stage: GA
spec:
  template:
    metadata:
      name: checkout-api-01142-abc          # Revision name: enables traffic splitting.
      annotations:
        autoscaling.knative.dev/minScale: "2"    # 0 = true scale-to-zero, at the cost
        autoscaling.knative.dev/maxScale: "100"  #     of cold starts on the first request.
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/cpu-throttling: "false"   # Always-allocated CPU: costs more,
                                                      # required for background work.
        run.googleapis.com/startup-cpu-boost: "true"
        run.googleapis.com/vpc-access-connector: projects/acme-prod-api/locations/us-central1/connectors/run-connector
        run.googleapis.com/vpc-access-egress: private-ranges-only
    spec:
      containerConcurrency: 80          # Requests served in parallel per instance.
      timeoutSeconds: 60
      serviceAccountName: checkout-api@acme-prod-api.iam.gserviceaccount.com
      containers:
        - name: checkout-api
          image: us-central1-docker.pkg.dev/acme-prod-api/apps/checkout-api:1.14.2
          ports:
            - name: http1
              containerPort: 8080
          env:
            - name: LOG_LEVEL
              value: info
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  key: latest
                  name: checkout-db-password    # Secret Manager, not a env literal.
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 0
            periodSeconds: 2
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
  traffic:
    - revisionName: checkout-api-01142-abc
      percent: 90
    - revisionName: checkout-api-01141-xyz
      percent: 10                        # Canary: the PaaS rollback primitive.
```

#### 3.2.4 SaaS — there is no manifest

That is the point. SaaS is consumed, not deployed. Your artefacts are IdP configuration, DLP rules, admin roles and an exit plan (data export). Google Workspace, Looker (as a hosted product), Google Security Operations and Apigee sit here.

```
$ gcloud identity groups memberships list \
    --group-email="checkout-oncall@acme.example" --format="table(preferredMemberKey.id,roles[0].name)"
ID                              NAME
alicia.moreno@acme.example      MEMBER
r.okonkwo@acme.example          MEMBER
sre-lead@acme.example           MANAGER
```

---

## 4. The shared responsibility model — and Google's "shared fate" extension

### 4.1 The classic matrix

The boundary moves with the service model. Everything **below** the line is Google's; everything **above** is yours. Nothing is ever shared in the sense of "someone will pick it up".

| Layer | On-prem | IaaS (GCE) | CaaS (GKE Std) | CaaS (Autopilot) | PaaS (Cloud Run) | SaaS |
|---|---|---|---|---|---|---|
| Physical facility, power, cooling | You | **Google** | **Google** | **Google** | **Google** | **Google** |
| Hardware, network fabric, physical security | You | **Google** | **Google** | **Google** | **Google** | **Google** |
| Hypervisor / host kernel | You | **Google** | **Google** | **Google** | **Google** | **Google** |
| Node OS + kernel patching | You | **You** | You (auto-upgrade available) | **Google** | **Google** | **Google** |
| Kubernetes control plane | n/a | n/a | **Google** | **Google** | n/a | n/a |
| Container runtime | You | You | **Google** | **Google** | **Google** | **Google** |
| **Container / VM image contents (CVEs in your base image)** | You | **You** | **You** | **You** | **You** | **Google** |
| Application code and dependencies | You | **You** | **You** | **You** | **You** | **Google** |
| Network controls (VPC, firewall, Cloud Armor) | You | **You** | **You** | **You** | **You** (ingress setting) | Configuration only |
| IAM policy / who can do what | You | **You** | **You** | **You** | **You** | **You** |
| Encryption **at rest** (default) | You | **Google** (always on) | **Google** | **Google** | **Google** | **Google** |
| Encryption key **management** (CMEK/CSEK) | You | You, if you opt in | You, if you opt in | You, if you opt in | You, if you opt in | Limited (CSE) |
| **Data content, classification, retention** | You | **You** | **You** | **You** | **You** | **You** |
| Identity source of truth (users, MFA) | You | **You** | **You** | **You** | **You** | **You** |

> **Two rows never move, at any rung: your data and your access management.** If an exam question describes a breach caused by a public storage bucket, an over-permissive IAM binding, or an unrotated service-account key, the answer is *customer responsibility* regardless of service model. Conversely, a hypervisor escape or a datacentre physical intrusion is *provider responsibility* at every rung above on-prem.

### 4.2 Shared fate — the part that distinguishes Google's framing

Google's Architecture Framework argues that shared *responsibility* alone leaves the customer holding a list of obligations with no help meeting them. **Shared fate** is the stated commitment to make the secure path the default and the easy one:

| Shared-fate mechanism | What it actually does | Where it shows up |
|---|---|---|
| Secure-by-default posture | Encryption at rest and in transit on by default; no public IP unless requested; Shielded VM defaults | All services |
| Security foundations blueprints | Opinionated, Terraform-delivered landing zone (org policies, VPC-SC, logging sinks) | `terraform-google-modules/cloud-foundation-fabric` |
| Assured Workloads | Enforces personnel-location, data-residency and support controls for regulated regimes (FedRAMP, IL4, EU regions, ITAR) as a *product*, not a checklist | `gcloud assured workloads` |
| Risk Protection Program | Cyber-insurance priced from your measured Security Command Center posture | Underwritten by third-party insurers |
| Policy Intelligence / Recommender | Machine-generated IAM least-privilege recommendations from 90 days of actual usage | `gcloud recommender` |

Diagnostic value: shared fate turns "are we compliant?" into a query.

```
$ gcloud recommender recommendations list \
    --project=acme-prod-platform \
    --location=global \
    --recommender=google.iam.policy.Recommender \
    --format="table(name.basename(),primaryImpact.category,description)" --limit=3
NAME                                  CATEGORY  DESCRIPTION
1a0f3c9e-9c1a-4f8b-b3d2-77f1c0a2e5b1  SECURITY  Replace the role roles/editor with roles/artifactregistry.writer on serviceAccount:ci-deployer@…
c72b8e41-2d33-4a19-9f01-5b6e2a83d4aa  SECURITY  Remove the role roles/owner from user:contractor@vendor.example (unused for 137 days)
9e14d7b6-08cd-4c22-8a55-1f0b7e93c6d0  SECURITY  Replace roles/storage.admin with roles/storage.objectViewer on serviceAccount:reporting@…
```

---

## 5. Deployment models: public, private, hybrid, multicloud

| Model | Definition | Google Cloud realisation | Chosen because | Real cost |
|---|---|---|---|---|
| **Public cloud** | Infrastructure provisioned for open use by the general public, owned by the provider | Google Cloud regions, standard projects | Elasticity, global reach, zero capex, managed services | Egress economics; noisy-neighbour perception; jurisdictional exposure |
| **Private cloud** | Provisioned for exclusive use by a single organisation; on- or off-premises | **Google Distributed Cloud** (connected and air-gapped), **sole-tenant nodes**, **Bare Metal Solution**, VMware Engine | Regulator mandates physical isolation or air-gap; licence terms bound to physical cores; sub-ms latency to plant floor | You are back on the capex/peak-provisioning treadmill for that footprint |
| **Hybrid cloud** | Composition of two or more distinct infrastructures bound by technology enabling data/app portability | GKE Enterprise (Anthos) + Cloud Interconnect / HA VPN, Config Sync, Cloud Service Mesh | Staged migration; a mainframe or licensed DB that cannot move; latency-bound edge | Two control planes, two failure models, one network path that is now on the critical path |
| **Multicloud** | Workloads across more than one public cloud provider | GKE Enterprise on AWS/Azure, BigQuery Omni, Cross-Cloud Interconnect | Negotiating leverage; regulatory concentration-risk rules (e.g. EU DORA); acquisition inheritance | **Lowest-common-denominator architecture**: you can only use features all providers share |

> **Architect's warning that the exam will not state but every migration proves:** multicloud as a *default posture* costs you the managed services that made cloud worth adopting. Multicloud as a *deliberate, per-workload decision* — analytics in BigQuery reading data in place on S3 via BigQuery Omni, while the transactional system stays put — is sound. "Multicloud for portability" with no exercised failover is a tax on every future feature.

### 5.1 Data residency as executable policy, not a slide

Deployment-model questions usually reduce to *where is the data allowed to be*. That is an Organization Policy constraint, and it is enforced at the API, not by review:

```yaml
# resource-locations.yaml — deny creation of any resource outside the EU.
# Apply with: gcloud org-policies set-policy resource-locations.yaml
name: organizations/613295847201/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:eu-locations          # Value group: all EU regions and multi-regions.
          - in:europe-west1-locations
        deniedValues:
          - in:us-locations
---
# Second policy: forbid external IPs on VMs (blast-radius reduction).
name: organizations/613295847201/policies/compute.vmExternalIpAccess
spec:
  rules:
    - enforce: true
```

```
$ gcloud org-policies set-policy resource-locations.yaml
Created policy [organizations/613295847201/policies/gcp.resourceLocations].

$ gcloud compute instances create test-us --zone=us-central1-a --project=acme-eu-prod
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Constraint constraints/gcp.resourceLocations violated for projects/acme-eu-prod.
   us-central1-a violates constraint constraints/gcp.resourceLocations.
```

That non-zero exit is the whole control. A policy that produces a PDF is not a control; a policy that produces an API error is.

### 5.2 Hybrid connectivity options — a decision table

| Option | Bandwidth | SLA | Latency profile | Encryption | Typical use |
|---|---|---|---|---|---|
| **HA VPN** (IPsec over internet) | Up to 3 Gbps per tunnel, 10 Gbps aggregate | 99.99% with two interfaces | Internet-variable, unpredictable tail | IPsec, always | Fast start, dev/test, low-volume replication |
| **Partner Interconnect** | 50 Mbps – 50 Gbps | 99.9% / 99.99% depending on topology | Predictable, provider-dependent | Not by default (add MACsec/IPsec) | No presence in a Google colocation facility |
| **Dedicated Interconnect** | 10 or 100 Gbps circuits | 99.9% / 99.99% depending on topology | Lowest, deterministic | Not by default (MACsec available) | Sustained multi-TB/day, egress-cost reduction |
| **Cross-Cloud Interconnect** | 10 or 100 Gbps | Same tiers | Deterministic, provider-to-provider | MACsec available | Multicloud data plane (GCP ↔ AWS/Azure/OCI) |
| **Direct/Carrier Peering** | Varies | No SLA | Varies | None | Public-facing content delivery, not VPC access |

The 99.99% tier is not a checkbox — it requires **four** interconnect connections across **two** metropolitan areas with **two** Cloud Routers. A 99.9% configuration marketed internally as "highly available" is the same correlated-failure mistake from §1, moved to the WAN.

---

## 6. Geography: regions, zones, and what actually fails together

### 6.1 The hierarchy and its failure semantics

```
  Multi-region  (e.g. "us", "eu", "asia")  ── async/sync replication across regions
    └── Region  (e.g. us-central1, europe-west4)  ── metro area, <1 ms inter-zone RTT
          └── Zone  (e.g. us-central1-a)  ── one or more clusters, independent
                │      power / cooling / networking failure domain
                └── Cluster / rack / host
```

- **Zone**: a deployment area *within* a region. A zone name (`us-central1-a`) maps to a **different physical cluster per project** — Google shuffles the letter-to-hardware mapping across organisations specifically so that everyone does not pile into `-a`.
- **Region**: an independent geographic area containing three or more zones. Inter-zone round-trip latency within a region is typically **sub-millisecond** — low enough for synchronous replication (this is why regional Persistent Disk and regional Cloud SQL HA exist).
- **Multi-region**: a set of regions used as one storage/serving locality (Cloud Storage `US`, Spanner `nam3`, BigQuery `EU`).
- Google Cloud currently operates **40+ regions and 120+ zones**, plus a much larger edge/PoP network. The count changes quarterly — the authoritative list is `gcloud compute regions list` and the geography docs.

### 6.2 Resource scope and the SLA it buys

| Scope | Example resources | Survives a **zone** loss? | Survives a **region** loss? | Representative published SLA |
|---|---|---|---|---|
| **Zonal** | VM instance, zonal PD, zonal MIG, GKE zonal cluster control plane | ❌ | ❌ | Compute Engine single instance: **99.9%** |
| **Regional** | Regional MIG, regional PD, regional GKE control plane, Cloud SQL HA, regional GCS bucket | ✅ | ❌ | Compute Engine, instances in ≥2 zones: **99.99%**; GKE regional control plane: **99.95%** (zonal: 99.5%) |
| **Multi-regional** | GCS multi-region bucket, Spanner multi-region, external Global Load Balancer, Cloud DNS | ✅ | ✅ | GCS Standard multi-region: **99.95%**; Spanner multi-region: **99.999%** |
| **Global** | VPC network, IAM policy, Cloud DNS zone, global HTTP(S) LB anycast IP, images/snapshots | ✅ | ✅ | Varies per service |

> **The arithmetic that matters.** Three zonal VMs in one zone give you 99.9% availability, not 99.9997%, because their failures are perfectly correlated at the zone boundary. Independence is what multiplies; sharing a failure domain destroys it. This is the single most valuable idea in this objective, and it is testable at every level of Google certification.

### 6.3 Latency budget arithmetic (the reason "just use one region" fails)

Speed of light in fibre ≈ 200,000 km/s ⇒ **~5 µs per km, one way**; **~10 µs per km round-trip**, before switching, queueing and TLS.

| Path | Great-circle distance | Theoretical RTT | Realistic observed RTT |
|---|---|---|---|
| Same zone (`us-central1-a` ↔ `us-central1-a`) | <1 km | ~0 | **0.1 – 0.3 ms** |
| Inter-zone, same region (`us-central1-a` ↔ `-c`) | ~10–50 km | 0.1–0.5 ms | **0.3 – 1.0 ms** |
| `us-central1` ↔ `us-east4` | ~1,500 km | 15 ms | **~25 – 35 ms** |
| `us-central1` ↔ `europe-west1` | ~7,000 km | 70 ms | **~95 – 110 ms** |
| `us-central1` ↔ `asia-southeast1` | ~15,500 km | 155 ms | **~180 – 210 ms** |
| `europe-west1` ↔ `australia-southeast1` | ~16,500 km | 165 ms | **~250 – 280 ms** |

A page that makes **12 sequential** backend calls to a database 100 ms away spends **1.2 s** in speed-of-light alone. No amount of CPU fixes that. This is why "broad network access" in NIST becomes, in practice, *global anycast front-end + regional backends + a CDN* — and why an exam scenario mentioning "users in Europe complain of slowness while the app runs in Iowa" is a **region placement / global load balancing** question, not a scaling question.

Measure it, do not assume it:

```
$ gcloud compute instances create probe-a --zone=us-central1-a \
    --machine-type=e2-micro --subnet=checkout-us-central1 --no-address
Created [https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-a/instances/probe-a].
NAME     ZONE           MACHINE_TYPE  PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP  STATUS
probe-a  us-central1-a  e2-micro                   10.20.0.14                RUNNING

$ gcloud compute ssh probe-a --zone=us-central1-a --tunnel-through-iap \
    --command="ping -c 5 -q 10.20.0.27"
PING 10.20.0.27 (10.20.0.27) 56(84) bytes of data.

--- 10.20.0.27 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4006ms
rtt min/avg/max/mdev = 0.412/0.507/0.688/0.094 ms      # <- inter-zone, same region

$ gcloud compute ssh probe-a --zone=us-central1-a --tunnel-through-iap \
    --command="ping -c 5 -q 10.60.1.9"
--- 10.60.1.9 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4007ms
rtt min/avg/max/mdev = 96.214/97.033/98.551/0.812 ms   # <- us-central1 -> europe-west1
```

### 6.4 Enumerating the geography

```
$ gcloud compute regions list --format="table(name,status,quotas[0].limit:label=CPU_QUOTA)" --limit=8
NAME                     STATUS  CPU_QUOTA
africa-south1            UP      24.0
asia-east1               UP      72.0
asia-northeast1          UP      72.0
asia-south1              UP      24.0
australia-southeast1     UP      24.0
europe-north1            UP      24.0
europe-west1             UP      72.0
us-central1              UP      600.0

$ gcloud compute zones list --filter="region:( us-central1 )" \
    --format="table(name,status,availableCpuPlatforms.list():label=CPU_PLATFORMS)"
NAME           STATUS  CPU_PLATFORMS
us-central1-a  UP      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Sapphire Rapids,AMD Genoa
us-central1-b  UP      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Sapphire Rapids,AMD Genoa
us-central1-c  UP      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake,Intel Sapphire Rapids,AMD Milan
us-central1-f  UP      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake

$ gcloud compute machine-types list --zones=us-central1-a --filter="name~^n2-standard" \
    --format="table(name,guestCpus,memoryMb)" --limit=5
NAME             CPUS  MEMORY_MB
n2-standard-2    2     8192
n2-standard-4    4     16384
n2-standard-8    8     32768
n2-standard-16   16    65536
n2-standard-32   32    131072
```

Note `us-central1-f` lacks Sapphire Rapids. If your MIG pins `--min-cpu-platform="Intel Sapphire Rapids"` and also lists `us-central1-f` in `distribution_policy_zones`, one quarter of your scale-out attempts will fail. That is a real, common, silent capacity bug.

---

## 7. Economics: capex, opex, TCO and the pricing models

### 7.1 Capex vs. opex

| | **Capex** (capital expenditure) | **Opex** (operating expenditure) |
|---|---|---|
| Definition | Up-front purchase of an asset, depreciated over its useful life | Ongoing expense consumed in the period it is incurred |
| Cash-flow shape | Large, lumpy, in advance | Small, continuous, in arrears |
| Accounting | Balance sheet; depreciation hits P&L over 3–5 years | P&L immediately |
| Decision latency | Procurement cycle: weeks to quarters | API call: seconds |
| Risk | Forecast risk is borne up front and is irreversible | Forecast risk is continuously re-priced |
| Cloud analogue | Physical servers, Bare Metal Solution term, on-prem licences | Compute Engine, Cloud Run, BigQuery on-demand |

Cloud shifts capex to opex — but this is a *shift*, not a discount. Committed-use discounts are a deliberate, partial move **back toward** capex (a fixed obligation for a lower unit rate), which is exactly the right trade for a genuinely steady baseline.

### 7.2 Compute pricing models

| Model | Discount vs. on-demand | Commitment | Interruptible | Best for |
|---|---|---|---|---|
| **On-demand** | 0% (baseline) | None | No | Unpredictable, short-lived, exploratory |
| **Sustained use discount (SUD)** | Automatic, up to ~30% (N1) / ~20% (N2, N2D, C2, C2D); **E2 is not eligible** — its list price already reflects it | None — applied automatically per month of runtime | No | Anything left running most of a month |
| **Resource-based CUD** | ~37% (1 yr) / ~55% (3 yr) for general-purpose; higher on memory-optimized 3 yr | Region + machine family, vCPU and RAM | No | Stable, well-forecast baseline in a known region |
| **Flexible / spend-based CUD** | ~28% (1 yr) / ~46% (3 yr) | A dollars-per-hour spend floor; portable across regions and eligible families | No | Baseline you cannot pin to one region or family |
| **Spot VMs** | 60–91% | None | **Yes** — 30 s ACPI shutdown notice, no maximum runtime | Batch, CI, rendering, ML training with checkpointing, stateless overflow |
| **Free tier / Always Free** | 100% within limits | None | No | Learning, tiny always-on utilities |

> Exact percentages and family eligibility change; the tables above are list-price behaviour at time of writing. Always confirm against the pricing pages linked in §10 before committing a three-year obligation.

The layering that a competent platform team actually runs:

```
   Fleet capacity
   ▲
   │  ░░░░░░░░░░░░░░░░  Spot          (batch + burst overflow, 60–91% off)
   │  ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  On-demand     (headroom above the committed floor)
   │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  3-yr CUD      (the true 24/7/365 baseline, ~55% off)
   └──────────────────────────────────────────────────────────► time
     Commit ONLY to the p5 of your annual load, never the p50.
```

Committing to the median is the classic FinOps own-goal: an unused commitment is billed anyway, so an over-commit is capex with none of the residual value.

### 7.3 A worked TCO comparison

*Scenario:* a workload requiring 200 vCPU / 800 GiB at steady state, bursting to 400 vCPU for ~6 h/day, plus a nightly batch tier, 20 TiB of block storage, 100 TiB of archival object storage and 15 TiB/month of internet egress.

**Option A — on-premises (4-year amortisation):**

| Line item | Basis | Annual |
|---|---|---|
| Servers (20 × 2-socket, 48 core, 512 GiB) | $18,000 each, 4-yr straight line | $90,000 |
| Storage array + SAN fabric | $260,000, 5-yr | $52,000 |
| Network (ToR, spine, firewalls) | $160,000, 5-yr | $32,000 |
| Colocation: 3 racks, power, cooling | $2,500/rack/month | $90,000 |
| Hypervisor + backup + monitoring licences | Renewal | $35,000 |
| Infrastructure ops staff | 1.5 FTE @ $120k fully loaded | $180,000 |
| DR site (cold, 40% of primary) | | $58,000 |
| **Total** | | **≈ $537,000/yr** |
| **Effective average utilisation** | Sized for peak | **≈ 28%** |
| **Cost per delivered vCPU-hour** | | **≈ $0.35** |

**Option B — Google Cloud, engineered (not lift-and-shift):**

| Line item | Configuration | Annual |
|---|---|---|
| Baseline compute | 12 × `n2-standard-16`, 3-yr resource CUD (~55% off ≈ $255/mo each) | $36,720 |
| Burst compute | 8 × `n2-standard-16`, on-demand @ ~$0.777/h, 6 h/day | $13,430 |
| Batch tier | 5 × `n2-standard-16` **Spot** @ ~70% off, 24/7 | $10,210 |
| Block storage | 20 TiB Balanced PD @ ~$0.10/GiB-mo | $24,576 |
| Object storage | 100 TiB Nearline @ ~$0.010/GiB-mo | $12,288 |
| **Internet egress** | 15 TiB/mo, Premium tier (10 TiB @ $0.12 + 5 TiB @ $0.11) | **$21,500** |
| Enhanced Support | Base + % of spend | ≈ $9,000 |
| Platform engineering | 0.5 FTE @ $150k — **cloud changes ops, it does not delete it** | $75,000 |
| **Total** | | **≈ $202,700/yr** |
| **Effective average utilisation** | Autoscaled | **≈ 65%** |
| **Cost per delivered vCPU-hour** | | **≈ $0.06** |

**Option C — the same workload lifted and shifted, no re-engineering:** 20 × `n2-standard-16` running 24/7 on-demand with no CUD, no Spot, no autoscaling, plus the same storage, egress and support ≈ **$228,000/yr in compute alone**, total ≈ **$300,000+**. Still cheaper than on-prem, but it forfeits roughly half the available saving and adds an egress line the datacentre never had.

**The three conclusions to carry into the exam and into a real business case:**

1. TCO must include **people, facilities, licences, DR and the cost of idle capacity** — a comparison of server price against VM price is not a TCO.
2. The saving comes from **eliminating idle capacity**, not from cheaper compute per hour. If you do not autoscale, you did not migrate; you rented someone else's idle servers.
3. **Egress and staffing are the two lines every naive model omits**, and they are the two that most often turn a projected saving into a projected wash.

### 7.4 Egress: the cost line with no feature attached

| Traffic path | Approximate list price | Architectural consequence |
|---|---|---|
| Same zone, internal IP | **Free** | Co-locate chatty services in one zone — then spread *replicas* across zones for availability |
| Between zones, same region | ~$0.01/GiB each direction | A cross-zone service mesh with mTLS and retries can quietly cost more than the compute |
| Between regions, same continent | ~$0.02–$0.05/GiB | Cross-region replication is a budget line, not a checkbox |
| Between continents | ~$0.05–$0.15/GiB | Data gravity is real: move compute to data, never data to compute |
| Internet egress, Premium tier | ~$0.12/GiB (0–10 TiB), ~$0.11 (10–150 TiB), ~$0.08 (>150 TiB) | Put a CDN in front of anything cacheable |
| Internet **ingress** | **Free** | Uploads are free; the asymmetry drives many designs |
| Egress to Cloud CDN cache fill | Reduced cache-fill rate | Cache hit ratio is a *cost* KPI, not just a latency KPI |
| Egress when **migrating off** Google Cloud | **Free**, on request | Reduces the lock-in argument materially — confirm current terms |

Guardrails, expressed as a budget with programmatic alerting:

```
$ gcloud billing budgets create \
    --billing-account=0123AB-4567CD-89EFGH \
    --display-name="acme-prod egress guardrail" \
    --budget-amount=2500USD \
    --filter-projects=projects/471829304517 \
    --filter-services=services/E505-1370-73D6 \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=0.9 \
    --threshold-rule=percent=1.0,basis=forecasted-spend \
    --all-updates-rule-pubsub-topic=projects/acme-prod-platform/topics/billing-alerts \
    --all-updates-rule-monitoring-notification-channels=projects/acme-prod-platform/notificationChannels/8827441905663210
Created budget [billingAccounts/0123AB-4567CD-89EFGH/budgets/9d1e77a4-3b0c-4f22-9a86-5e2c1f7b4d33].
```

Note `basis=forecasted-spend` on the 100% rule. Alerting on *actual* spend at 100% tells you the money is gone; alerting on *forecast* tells you it is about to be.

---

## 8. Verification and failure diagnosis

### 8.1 Verifying that elasticity is real

```
$ gcloud compute instance-groups managed describe checkout-api-mig \
    --region=us-central1 \
    --format="yaml(name,targetSize,status.isStable,currentActions,distributionPolicy.zones)"
currentActions:
  abandoning: 0
  creating: 0
  deleting: 0
  none: 6
  recreating: 0
  refreshing: 0
  restarting: 0
  verifying: 0
distributionPolicy:
  zones:
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-a
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-b
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-c
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-f
name: checkout-api-mig
status:
  isStable: true
targetSize: 6
```

Apply load, then confirm the autoscaler moved and **that the new instances landed in different zones**:

```
$ gcloud compute instance-groups managed list-instances checkout-api-mig \
    --region=us-central1 --format="table(name,zone.basename(),status,instanceHealth[0].detailedHealthState)"
NAME                ZONE           STATUS   DETAILED_HEALTH_STATE
checkout-api-4f2q   us-central1-a  RUNNING  HEALTHY
checkout-api-7k9m   us-central1-a  RUNNING  HEALTHY
checkout-api-b1xd   us-central1-b  RUNNING  HEALTHY
checkout-api-c8vr   us-central1-b  RUNNING  HEALTHY
checkout-api-h3lp   us-central1-c  RUNNING  HEALTHY
checkout-api-m5tw   us-central1-c  RUNNING  HEALTHY
checkout-api-q0zn   us-central1-f  RUNNING  HEALTHY
checkout-api-r6ya   us-central1-f  RUNNING  HEALTHY
checkout-api-s2jc   us-central1-a  RUNNING  TIMEOUT
checkout-api-t9wp   us-central1-b  RUNNING  HEALTHY
```

One `TIMEOUT` is the auto-healer about to do its job. Ten instances evenly spread over four zones is what "resource pooling + rapid elasticity + failure-domain awareness" looks like when it is true rather than asserted.

On GKE:

```
$ kubectl get pods -n checkout -o custom-columns=\
NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,STATUS:.status.phase
NAME                            NODE                                       ZONE           STATUS
checkout-api-6d4f8b9c7-2xkqz    gke-prod-default-pool-a1b2c3-9f4k          us-central1-a  Running
checkout-api-6d4f8b9c7-5mn8v    gke-prod-default-pool-d4e5f6-2p7r          us-central1-b  Running
checkout-api-6d4f8b9c7-7rt2w    gke-prod-default-pool-g7h8i9-6t1x          us-central1-c  Running
checkout-api-6d4f8b9c7-9wq4x    gke-prod-default-pool-a1b2c3-3m8n          us-central1-a  Running
checkout-api-6d4f8b9c7-bk7pl    gke-prod-default-pool-d4e5f6-8s2y          us-central1-b  Running
checkout-api-6d4f8b9c7-dz3hc    gke-prod-default-pool-g7h8i9-4v9z          us-central1-c  Running

$ kubectl get hpa checkout-api -n checkout
NAME           REFERENCE                 TARGETS                        MINPODS  MAXPODS  REPLICAS  AGE
checkout-api   Deployment/checkout-api   cpu: 41%/60%, 78/120 (avg)     6        60       6         14d

$ kubectl get pdb -n checkout
NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
checkout-api   4               N/A               2                     14d
```

### 8.2 Failure catalogue

#### F1 — Zonal resource exhaustion (a stockout, not a quota problem)

```
$ gcloud compute instances create burst-01 --zone=us-central1-a \
    --machine-type=c3-highmem-176 --project=acme-prod-platform
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - The zone 'projects/acme-prod-platform/zones/us-central1-a' does not have enough
   resources available to fulfill the request. '(resource type:compute)'.
   ZONE_RESOURCE_POOL_EXHAUSTED
```

**Diagnosis:** this is not your quota. It is physical capacity for that machine family in that zone at that moment.
**Fix, in order of preference:**
1. Use a **regional** MIG with multiple zones so the API retries elsewhere automatically — this is the entire reason regional MIGs exist.
2. Relax the machine family (`c3` → `n2`/`n2d`) or shape (fewer, larger vs. more, smaller).
3. For guaranteed capacity, buy a **future reservation** or an on-demand reservation.
4. Never treat "retry in a loop against the same zone" as a mitigation.

```
$ gcloud compute reservations create checkout-peak-nov \
    --zone=us-central1-b --vm-count=40 \
    --machine-type=n2-standard-16 --require-specific-reservation
Created [https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-b/reservations/checkout-peak-nov].
```

#### F2 — Quota ceiling silently capping elasticity

```
$ gcloud compute instances create burst-42 --zone=us-central1-a --machine-type=n2-standard-16
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Quota 'N2_CPUS' exceeded. Limit: 600.0 in region us-central1.

$ gcloud compute regions describe us-central1 \
    --format="table(quotas.metric,quotas.usage,quotas.limit)" | grep -E "N2_CPUS|IN_USE_ADDRESSES"
N2_CPUS                600.0   600.0
IN_USE_ADDRESSES        32.0    64.0
```

**Diagnosis:** the "appearance of unlimited capacity" in NIST's rapid-elasticity definition is bounded by per-project, per-region quotas. Autoscalers do **not** warn you in advance; they simply stop growing while your latency SLO burns.
**Fix:** alert on quota utilisation as a first-class SLI (`serviceruntime.googleapis.com/quota/allocation/usage` in Cloud Monitoring), and request increases before the peak season, not during it.

#### F3 — Cross-zone egress cost from a "highly available" design

Symptom: the Networking line in the billing export grows in lockstep with request volume, with no internet traffic to explain it.

```sql
SELECT sku.description, ROUND(SUM(cost),2) AS usd, ROUND(SUM(usage.amount)/POW(1024,3),1) AS gib
FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_0123AB_4567CD_89EFGH`
WHERE service.description = 'Networking'
  AND DATE(_PARTITIONTIME) BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY 1 ORDER BY usd DESC LIMIT 5;
```
```
+---------------------------------------------------------------+---------+----------+
| sku.description                                               | usd     | gib      |
+---------------------------------------------------------------+---------+----------+
| Network Inter Zone Data Transfer Out                          | 4128.77 | 412877.0 |
| Network Internet Egress from Americas to Americas             | 1791.36 |  15360.0 |
| Network Inter Region Data Transfer Out (Americas to Americas)  |  612.44 |  12248.8 |
+---------------------------------------------------------------+---------+----------+
```

**Diagnosis:** a stateless tier spread across three zones talking to a cache tier also spread across three zones sends ~2/3 of its traffic across a zone boundary by pure probability.
**Fix:** enable topology-aware routing so a client prefers a same-zone endpoint, while keeping cross-zone as failover.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis-cache
  namespace: checkout
spec:
  selector:
    app.kubernetes.io/name: redis-cache
  ports:
    - port: 6379
      targetPort: 6379
  # Prefer endpoints in the same zone; fall back to the whole region if none are ready.
  trafficDistribution: PreferClose
```

#### F4 — Cold starts blamed on the wrong layer

```
$ gcloud logging read \
    'resource.type="cloud_run_revision" AND
     resource.labels.service_name="checkout-api" AND
     httpRequest.latency>="2s"' \
    --limit=3 --format="table(timestamp,httpRequest.latency,labels.instanceId,textPayload)"
TIMESTAMP                       LATENCY   INSTANCE_ID                                TEXT_PAYLOAD
2026-09-05T03:14:22.881443Z     3.412s    00bf4b2f8d9c1a...  Default STARTUP TCP probe succeeded after 1 attempt
2026-09-05T03:14:19.204118Z     2.887s    00bf4b2f8d9c1a...  Container called exit(0) — scaled to zero
2026-09-05T02:58:41.663902Z     2.104s    00c71e3a5f2b8e...  Default STARTUP TCP probe succeeded after 1 attempt
```

**Diagnosis:** p99 latency spikes correlate perfectly with new `instanceId` values. This is scale-from-zero, not a slow database.
**Fix (and the trade-off you are choosing):**

| Lever | Effect | Cost |
|---|---|---|
| `minScale: 2` | Eliminates cold start for the first 2 concurrent requests | You pay for 2 idle instances 24/7 — you gave up scale-to-zero |
| `startup-cpu-boost: true` | Extra CPU during initialisation only | Small |
| Slimmer image (distroless, smaller layers) | Faster pull and start | Engineering time |
| Higher `containerConcurrency` | Fewer instances, fewer cold starts | Larger blast radius per instance; tail latency under load |

#### F5 — "It's a zonal outage" — triage sequence

```
$ gcloud compute operations list --filter="operationType~compute.instances AND status!=DONE" --limit=5
NAME                                     TYPE                       TARGET             STATUS
operation-1757043221-62f1a8b0c4d21-...   compute.instances.insert   burst-88           RUNNING

$ gcloud compute instances list --filter="zone:us-central1-a" \
    --format="table(name,status,lastStartTimestamp)" | head -5
NAME               STATUS       LAST_START_TIMESTAMP
checkout-api-4f2q  TERMINATED   2026-09-05T02:41:09.442-07:00
checkout-api-7k9m  TERMINATED   2026-09-05T02:41:11.083-07:00
checkout-api-s2jc  TERMINATED   2026-09-05T02:41:12.771-07:00

$ curl -s https://status.cloud.google.com/incidents.json | \
    jq -r '.[] | select(.end == null) | "\(.begin)  \(.service_name)  \(.external_desc[0:80])"'
2026-09-05T09:38:00Z  Google Compute Engine  We are investigating an issue with Compute Engine in us-central1-a affecting...
```

**Playbook:**
1. Confirm the blast radius is one zone (not one machine family, not one project).
2. Confirm the regional MIG / regional GKE control plane is redistributing — capacity should reappear in the surviving zones automatically.
3. Confirm the load balancer has **removed** the failed backends (`HEALTHY` count should drop, not requests fail).
4. Verify your zonal-scoped dependencies: zonal PD, zonal Cloud SQL, zonal NFS, a single-zone Memorystore instance. **These are the things that do not fail over, and they are always the reason the "regional" design still went down.**
5. Post-incident: every zonal resource on the critical path becomes a regional-upgrade ticket.

```
$ gcloud compute backend-services get-health checkout-api-backend --global \
    --format="table(status.healthStatus[].instance.basename(),status.healthStatus[].healthState)"
INSTANCE            HEALTH_STATE
checkout-api-b1xd   HEALTHY
checkout-api-c8vr   HEALTHY
checkout-api-h3lp   HEALTHY
checkout-api-m5tw   HEALTHY
checkout-api-q0zn   HEALTHY
checkout-api-r6ya   HEALTHY
checkout-api-4f2q   UNHEALTHY
```

#### F6 — Shared-responsibility gap found in an audit

```
$ gcloud scc findings list organizations/613295847201 \
    --filter="state=\"ACTIVE\" AND category=\"PUBLIC_BUCKET_ACL\"" \
    --format="table(finding.category,finding.resourceName,finding.severity)"
CATEGORY            RESOURCE_NAME                                              SEVERITY
PUBLIC_BUCKET_ACL   //storage.googleapis.com/projects/_/buckets/acme-exports   HIGH
```

**Diagnosis:** this is 100% customer responsibility at every service model. Google encrypted the object at rest and secured the datacentre; you granted `allUsers` read.
**Fix and prevention (the shared-fate move — make it structurally impossible, not merely forbidden):**

```
$ gcloud storage buckets update gs://acme-exports --no-public-access-prevention --dry-run
$ gcloud storage buckets update gs://acme-exports --public-access-prevention
Updating gs://acme-exports/...
  Completed 1

$ gcloud resource-manager org-policies enable-enforce \
    storage.publicAccessPrevention --organization=613295847201
Enabled constraint [constraints/storage.publicAccessPrevention] on [organizations/613295847201].
```

### 8.3 Pre-production checklist for this objective

| # | Check | Command / artefact | Pass condition |
|---|---|---|---|
| 1 | No single-zone critical path | `gcloud compute instances list --format="value(zone)" \| sort \| uniq -c` | Every tier present in ≥2 zones |
| 2 | Regional control plane on GKE | `gcloud container clusters describe … --format="value(location)"` | Value is a **region**, not a zone |
| 3 | PDB will not block a node drain | `kubectl get pdb -A` | `ALLOWED DISRUPTIONS ≥ 1` for every workload |
| 4 | Autoscaler ceiling above forecast peak | `gcloud compute region-autoscalers describe …` | `maxReplicas ≥ 1.5 × forecast peak` |
| 5 | Quota headroom above the ceiling | `gcloud compute regions describe <r>` | Usage/limit < 70% at forecast peak |
| 6 | Every resource labelled for cost attribution | Billing export query, §2.1 | ≥95% of spend carries a `team` label |
| 7 | Budget with **forecasted-spend** alert | `gcloud billing budgets list` | At least one rule uses `basis=forecasted-spend` |
| 8 | Data-residency policy enforced at the API | `gcloud org-policies describe gcp.resourceLocations …` | Out-of-region create returns non-zero |
| 9 | No public IPs unless justified | `constraints/compute.vmExternalIpAccess` | Enforced with an explicit allowlist |
| 10 | Commitment matches the true baseline | CUD utilisation report | Utilisation ≥ 95%, and commitment ≤ annual p5 load |

---

## 9. Exam-focused distinctions

These are the confusions that actually cost marks.

| If the question says… | It is testing… | Answer with… |
|---|---|---|
| "provision without contacting the provider" | On-demand self-service | Console/API/CLI self-service |
| "appears unlimited, scales in minutes" | Rapid elasticity | Autoscaling |
| "multi-tenant, resources dynamically assigned" | Resource pooling | Shared physical infrastructure, location abstraction |
| "pay only for what you use, usage is reported" | Measured service | Per-second billing, billing export |
| "access from laptops, phones and tablets over standard protocols" | Broad network access | Standard HTTP(S)/API access |
| "we need root and a custom kernel module" | Service model | **IaaS** |
| "we want to deploy code and never see a server" | Service model | **PaaS** / serverless |
| "we buy a licence per user and configure it" | Service model | **SaaS** |
| "some workloads stay in our datacentre permanently" | Deployment model | **Hybrid** |
| "we run on Google Cloud and AWS" | Deployment model | **Multicloud** |
| "regulator requires physical isolation / air-gap" | Deployment model | **Private** (Google Distributed Cloud, sole-tenant nodes) |
| "who patches the guest OS on a VM?" | Shared responsibility | **Customer** |
| "who secures the datacentre?" | Shared responsibility | **Google** |
| "who classifies and protects the data?" | Shared responsibility | **Customer, always** |
| "Google helps us be secure by default and shares the risk" | **Shared fate** | Blueprints, Assured Workloads, Risk Protection Program |
| "the app must survive losing a datacentre in the same city" | Geography | Multiple **zones** in one region |
| "the app must survive losing a whole geographic area" | Geography | Multiple **regions** / multi-region resources |
| "users worldwide, one endpoint" | Geography + network | **Global external Application Load Balancer** (anycast) |
| "we bought servers up front and depreciate them" | Economics | **Capex** |
| "we pay monthly for what we consumed" | Economics | **Opex** |
| "steady 24/7 baseline, want the lowest rate" | Pricing | **Committed use discount** |
| "batch job, restartable, cheapest possible" | Pricing | **Spot VMs** |
| "we left the VM running all month and got a discount automatically" | Pricing | **Sustained use discount** |
| "compare total cost including staff, power and licences" | Economics | **TCO** |

---

## 10. Referencias

**Exam and certification**
- Cloud Digital Leader exam guide (PDF, authoritative objective list): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification page: https://cloud.google.com/learn/certification/cloud-digital-leader

**Foundational definitions**
- NIST SP 800-145, *The NIST Definition of Cloud Computing*: https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-145.pdf
- What is cloud computing (Google Cloud): https://cloud.google.com/learn/what-is-cloud-computing
- IaaS vs. PaaS vs. SaaS: https://cloud.google.com/learn/paas-vs-iaas-vs-saas
- Hybrid and multicloud: https://cloud.google.com/learn/what-is-hybrid-cloud

**Geography, regions, zones, reliability**
- Google Cloud geography and regions: https://cloud.google.com/docs/geography-and-regions
- Regions and zones (Compute Engine): https://cloud.google.com/compute/docs/regions-zones
- Global, regional and zonal resources: https://cloud.google.com/compute/docs/regions-zones/global-regional-zonal-resources
- Regions with the lowest carbon impact: https://cloud.google.com/sustainability/region-carbon
- Architecture Framework — Reliability: https://cloud.google.com/architecture/framework/reliability
- Disaster recovery planning guide: https://cloud.google.com/architecture/dr-scenarios-planning-guide

**Service-level agreements**
- All Google Cloud SLAs: https://cloud.google.com/terms/sla/
- Compute Engine SLA: https://cloud.google.com/compute/sla
- Google Kubernetes Engine SLA: https://cloud.google.com/kubernetes-engine/sla
- Cloud Storage SLA: https://cloud.google.com/storage/sla
- Cloud Run SLA: https://cloud.google.com/run/sla
- Google Cloud Service Health dashboard: https://status.cloud.google.com/

**Shared responsibility and shared fate**
- Shared responsibility and shared fate on Google Cloud: https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Architecture Framework — Security, privacy and compliance: https://cloud.google.com/architecture/framework/security
- Assured Workloads overview: https://cloud.google.com/assured-workloads/docs/overview
- Risk Protection Program: https://cloud.google.com/security/products/risk-protection-program
- Security Command Center overview: https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Encryption at rest (whitepaper): https://cloud.google.com/docs/security/encryption/default-encryption

**Deployment models and connectivity**
- GKE Enterprise (Anthos) overview: https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview
- Google Distributed Cloud: https://cloud.google.com/distributed-cloud/docs
- Sole-tenant nodes: https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes
- Bare Metal Solution: https://cloud.google.com/bare-metal/docs
- Network Connectivity product overview: https://cloud.google.com/network-connectivity/docs
- Cloud Interconnect overview: https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview
- Cross-Cloud Interconnect: https://cloud.google.com/network-connectivity/docs/interconnect/concepts/cross-cloud-interconnect
- HA VPN topologies: https://cloud.google.com/network-connectivity/docs/vpn/concepts/topologies

**Economics, pricing and FinOps**
- Google Cloud pricing overview: https://cloud.google.com/pricing
- Pricing calculator: https://cloud.google.com/products/calculator
- Committed use discounts: https://cloud.google.com/docs/cuds
- Sustained use discounts: https://cloud.google.com/compute/docs/sustained-use-discounts
- Spot VMs: https://cloud.google.com/compute/docs/instances/spot
- Google Cloud free program (Always Free): https://cloud.google.com/free/docs/free-cloud-features
- VPC network pricing (egress and data transfer): https://cloud.google.com/vpc/network-pricing
- Export Cloud Billing data to BigQuery: https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- Create, edit or delete budgets and budget alerts: https://cloud.google.com/billing/docs/how-to/budgets
- Architecture Framework — Cost optimization: https://cloud.google.com/architecture/framework/cost-optimization

**Elasticity, scaling and policy enforcement**
- Autoscaling groups of instances: https://cloud.google.com/compute/docs/autoscaler
- Regional managed instance groups: https://cloud.google.com/compute/docs/instance-groups/regional-migs
- GKE cluster autoscaler: https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler
- GKE Autopilot overview: https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview
- Cloud Run: about instance autoscaling: https://cloud.google.com/run/docs/about-instance-autoscaling
- Organization Policy Service introduction: https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Restricting resource locations: https://cloud.google.com/resource-manager/docs/organization-policy/defining-locations
- Working with quotas: https://cloud.google.com/docs/quotas/view-manage
- Compute Engine reservations: https://cloud.google.com/compute/docs/instances/reservations-overview