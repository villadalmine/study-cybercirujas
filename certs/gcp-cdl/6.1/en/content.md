# Topic 6.1 — How Google Cloud Supports an Organization's Ability to Control Cloud Costs

**Certification:** Google Cloud Digital Leader (exam guide version 2026-08-12)
**Domain 6 weight:** 5.0
**Profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation: cost is a production reliability property, not an accounting artifact

### 1.1 The architectural problem

In an on-premises datacenter, spend is **structurally bounded by physics**. You cannot consume a rack you did not buy. Capacity is a capex decision made once, months in advance, by a small set of people with purchase authority. The failure mode is *starvation*: a team waits eight weeks for hardware.

On Google Cloud the bound is inverted. Any principal holding `roles/compute.instanceAdmin` on a project linked to an active Cloud Billing account can, in a single API call, instantiate an `a3-highgpu-8g` instance and begin accruing thousands of dollars per day. The failure mode becomes *runaway consumption*: a misconfigured Cloud Composer DAG, a `for` loop in a CI job that never calls `terraform destroy`, a BigQuery `SELECT *` over a 400 TiB unpartitioned table scheduled hourly.

The single most important architectural fact for this objective:

> **Google Cloud provides no hard spending cap on a billing account.** Cloud Billing budgets are a *detection and notification* mechanism. They do not stop consumption. The only mechanisms that hard-stop consumption are **quotas**, **Organization Policy constraints**, and **removing the billing account link from a project** — and the last one is destructive.

This is a deliberate design decision, and it is the correct one for a platform whose primary contract is availability: a system that silently terminates production workloads when a budget threshold is crossed has converted a finance event into an outage. As a Platform Architect you own that trade-off explicitly rather than inheriting it accidentally.

### 1.2 The five-layer cost control model

Every Google Cloud cost-control capability slots into exactly one of five layers. Interviews, design reviews, and the CDL exam all reward being able to name the layer a given tool belongs to.

| Layer | Question it answers | Enforcement | Google Cloud mechanisms | Latency |
|---|---|---|---|---|
| **1. Prevent** | Can this spend happen at all? | Hard (API denial) | Quotas (allocation + rate), Organization Policy constraints, IAM (`roles/billing.user` scarcity), VPC Service Controls | Instant, synchronous |
| **2. Attribute** | Whose spend is this? | None (metadata) | Resource hierarchy, labels, tags, billing subaccounts, GKE cost allocation | Structural |
| **3. Detect** | Did spend deviate from plan? | None (signal) | Budgets & alerts, Pub/Sub budget notifications, Cost Table / Cost Breakdown reports, BigQuery billing export, Cost Anomaly Detection | Hours (billing export lag) |
| **4. Optimize** | Are we paying more than necessary for the same outcome? | Advisory | Active Assist / Recommender, FinOps Hub, CUD Recommender, rightsizing, Autoclass, VPA | Days |
| **5. Commit** | Can we buy the same capacity cheaper? | Contractual | SUD, CUD (resource-based + spend-based/flexible), Reservations, Spot VMs, Network Service Tiers, BigQuery Editions | Months (1y/3y terms) |

A cost program that only implements layer 3 (budgets) is the most common failure pattern in the field: it produces alerts that arrive 18 hours after a $40k mistake, addressed to a billing admin who cannot identify the owning team because layer 2 was never built.

---

## 2. Layer 2 first: the resource hierarchy is the cost attribution backbone

You cannot detect, optimize, or charge back spend you cannot attribute. Attribution is structural and must be designed **before** the first workload lands, because labels and hierarchy placement are largely non-retroactive in billing data.

### 2.1 The hierarchy

```
Organization  (1 per Cloud Identity / Workspace domain — the root IAM + policy anchor)
 └── Folder        (up to 10 levels of nesting; the natural boundary for
      └── Folder    Org Policy inheritance and for budget scoping)
           └── Project   (THE billing boundary — exactly one billing account per project)
                └── Resource   (VM, bucket, dataset, Cloud Run service …)
```

Key invariants to internalize:

| Invariant | Consequence for cost control |
|---|---|
| A project is linked to **exactly one** Cloud Billing account at a time. | The project is the atomic unit of chargeback. Two cost centers sharing a project is an architectural defect. |
| A billing account can fund **many** projects. | Consolidated invoicing and shared CUD/SUD pools live here. |
| IAM and Org Policy are **inherited downward** and are **additive** for IAM (a child cannot revoke an inherited allow) but **overridable** for Org Policy (a child can override with `inheritFromParent: false` if permitted). | Preventive guardrails belong on folders, not projects. |
| Billing IAM is on the **billing account**, which is a resource *outside* the project hierarchy. | `roles/owner` on a project does **not** grant the ability to view its cost. This surprises people constantly. |

### 2.2 Billing IAM — the least-privilege matrix

| Role | ID | Grants | Grant to |
|---|---|---|---|
| Billing Account Creator | `roles/billing.creator` | Create new billing accounts | Org-level finance only |
| Billing Account Administrator | `roles/billing.admin` | Full control: link/unlink projects, manage budgets, export, payment | 2–4 humans, break-glass |
| Billing Account User | `roles/billing.user` | **Link a project to this billing account** | Platform automation SA + landing-zone pipeline |
| Billing Account Costs Manager | `roles/billing.costsManager` | Manage budgets, view/export cost data — **not** pricing or payment | FinOps team, engineering leads |
| Billing Account Viewer | `roles/billing.viewer` | Read cost data and budgets | Any engineer who owns a service |
| Project Billing Manager | `roles/billing.projectManager` | Link/unlink **this project** to a billing account the principal is a `billing.user` on | App team leads in a self-serve landing zone |

The classic secure pattern: **project creation and billing linkage require two distinct roles held by two distinct principals** (`roles/resourcemanager.projectCreator` on the folder + `roles/billing.user` on the billing account). Granting only the former means a rogue actor can create projects but never make them cost money.

```bash
$ gcloud beta billing accounts get-iam-policy 01A2B3-C4D5E6-F7G8H9
bindings:
- members:
  - group:gcp-billing-admins@example.com
  role: roles/billing.admin
- members:
  - group:gcp-finops@example.com
  role: roles/billing.costsManager
- members:
  - serviceAccount:landing-zone@plat-automation.iam.gserviceaccount.com
  role: roles/billing.user
- members:
  - group:gcp-engineering-all@example.com
  role: roles/billing.viewer
etag: BwYb2xZ3q1M=
version: 1
```

### 2.3 Labels: the attribution primitive

Labels are key/value pairs propagated into the billing export. They are the mechanism by which showback and chargeback become queryable. Constraints you must design around:

| Property | Value | Design consequence |
|---|---|---|
| Max labels per resource | 64 | Budget them; do not encode free-form metadata |
| Key length / value length | 63 chars each | Use short canonical keys |
| Allowed chars | lowercase letters, digits, `-`, `_`, intl chars | Enforce a regex in CI |
| Retroactivity in billing export | **None** | An unlabeled resource is permanently unattributed for the period it ran unlabeled |
| Propagation to child resources | **Not automatic** (e.g. a GCE instance label does not label its attached disk) | Label every resource in Terraform via `default_labels` on the provider |
| Project labels | Exported as `project.labels` | Use for coarse attribution that survives resource-level label drift |

Standardize on a small, mandatory taxonomy and enforce it at the IaC layer:

```hcl
# terraform/provider.tf — every resource created by this provider block inherits these
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    cost-center    = var.cost_center      # "cc-4417"
    environment    = var.environment      # prod | staging | dev | sandbox
    owner-team     = var.owner_team       # "platform-sre"
    service        = var.service_name     # "checkout-api"
    data-class     = var.data_class       # public | internal | restricted
    managed-by     = "terraform"
    tf-workspace   = terraform.workspace
  }
}
```

Then close the loop with Cloud Asset Inventory to find drift — resources created outside Terraform are the leak:

```bash
$ gcloud asset search-all-resources \
    --scope='organizations/123456789012' \
    --asset-types='compute.googleapis.com/Instance,compute.googleapis.com/Disk,storage.googleapis.com/Bucket' \
    --query='NOT labels.cost-center:*' \
    --format='table(name.basename(), assetType, project, location)'

NAME                       ASSET_TYPE                            PROJECT           LOCATION
jenkins-agent-scratch-01   compute.googleapis.com/Instance       eng-ci-9931       us-central1-a
pd-jenkins-agent-scratch   compute.googleapis.com/Disk           eng-ci-9931       us-central1-a
dataproc-staging-4ab19c    storage.googleapis.com/Bucket         analytics-prd-01  us-central1
tmp-export-mbrennan        storage.googleapis.com/Bucket         analytics-prd-01  us

Listed 4 items.
```

> **Labels vs. Tags.** Google Cloud *tags* (`tagKeys`/`tagValues`, a Resource Manager resource) are a different primitive from labels: they are IAM-controlled, inheritable down the hierarchy, and usable in conditional IAM and Org Policy conditions. Tags **do** appear in the detailed billing export (`tags` column). Use **labels** for attribution/showback; use **tags** for policy-conditioned governance (e.g. "only resources tagged `env=prod` may use `n2-highmem`").

---

## 3. Layer 3: Cloud Billing export to BigQuery — the ground truth

The console reports are convenient; the BigQuery export is authoritative and is the only surface on which you can build custom unit economics, anomaly detection, and chargeback.

### 3.1 The three exports

| Export | Table name pattern | Granularity | Use it for |
|---|---|---|---|
| **Standard usage cost** | `gcp_billing_export_v1_<BA_ID>` | Service + SKU + project + day + labels | Chargeback, budgets validation, trend analysis |
| **Detailed usage cost** | `gcp_billing_export_resource_v1_<BA_ID>` | Adds `resource.name` / `resource.global_name` — **per individual resource** | Finding *which* VM/disk/bucket, GKE cost allocation, waste hunting |
| **Pricing** | `cloud_pricing_export` | List price per SKU, tiers, currency, effective dates | Modeling, `cost_at_list` reconciliation, pre-purchase what-if |

Underscores in the table name replace hyphens in the billing account ID: billing account `01A2B3-C4D5E6-F7G8H9` → `gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`.

### 3.2 Enabling it

Export configuration lives on the **billing account**, not the project, and is currently console/API-driven:

```bash
# 1. Create the sink dataset in a dedicated, tightly-scoped project.
$ gcloud config set project fin-billing-prd-01
Updated property [core/project].

$ bq --location=US mk --dataset \
    --description="Cloud Billing export (standard, detailed, pricing)" \
    --default_table_expiration=0 \
    fin-billing-prd-01:cloud_billing_export
Dataset 'fin-billing-prd-01:cloud_billing_export' successfully created.

# 2. Grant the billing export service the right to write.
$ gcloud projects add-iam-policy-binding fin-billing-prd-01 \
    --member='group:gcp-billing-admins@example.com' \
    --role='roles/bigquery.dataEditor' --condition=None
Updated IAM policy for project [fin-billing-prd-01].

# 3. Enable in console: Billing -> Billing export -> BigQuery export ->
#    edit "Standard usage cost", "Detailed usage cost", "Pricing".
# 4. Confirm tables materialize (first rows typically appear within a few hours;
#    detailed export can take up to ~24h for the first partition).
$ bq ls --max_results=50 fin-billing-prd-01:cloud_billing_export
                    tableId                        Type    Labels   Time Partitioning
 ------------------------------------------------ ------- -------- -------------------
  gcp_billing_export_resource_v1_01A2B3_C4D5E6_F7G8H9  TABLE            DAY (field: _PARTITIONTIME)
  gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9           TABLE            DAY (field: _PARTITIONTIME)
  cloud_pricing_export                                 TABLE            DAY (field: _PARTITIONTIME)
```

> **The export is not retroactive.** It begins capturing at the moment you enable it. Enabling billing export is therefore item #1 on any landing-zone build, before the first workload. There is no way to backfill.

### 3.3 The schema fields that matter

| Column | Type | Meaning / gotcha |
|---|---|---|
| `cost` | FLOAT64 | Cost **at your negotiated/list rate, before credits**. This is *not* what you pay. |
| `credits` | ARRAY<STRUCT> | Each has `name`, `amount` (negative), `type`, `id`. Types include `SUSTAINED_USAGE_DISCOUNT`, `COMMITTED_USAGE_DISCOUNT`, `DISCOUNT`, `PROMOTION`, `FREE_TIER`, `SUBSCRIPTION_BENEFIT`, `COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE`. |
| `cost_at_list` | FLOAT64 | Public list price. `cost_at_list - cost` = contractual/negotiated discount. |
| `usage.amount` / `usage.unit` | FLOAT64 / STRING | Raw consumption. Prefer `usage.amount_in_pricing_units`. |
| `invoice.month` | STRING `YYYYMM` | **Use this for finality.** Daily sums are restated by adjustments for weeks. |
| `adjustment_info` | STRUCT | Populated on corrections/refunds — rows can have negative cost. |
| `export_time` | TIMESTAMP | When the row landed. Use to detect export stalls. |
| `labels`, `system_labels`, `project.labels`, `tags` | ARRAY<STRUCT<key,value>> | Attribution. `system_labels` carries Google-set keys like `compute.googleapis.com/machine_spec`. |
| `resource.name` | STRING | **Detailed export only.** The individual resource. |
| `cost_type` | STRING | `regular`, `tax`, `adjustment`, `rounding_error`. Filter `= 'regular'` for engineering analysis. |

### 3.4 The one query every platform team should have

**Effective cost** is `cost + SUM(credits.amount)`. Getting this wrong overstates spend by the full value of your CUDs and SUDs — a routine 20–40% error.

```sql
-- Effective monthly cost by cost-center, environment, service and SKU.
-- Run against the STANDARD export; partition-pruned on _PARTITIONTIME.
DECLARE start_ts TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 DAY);

WITH enriched AS (
  SELECT
    invoice.month                                       AS invoice_month,
    project.id                                          AS project_id,
    service.description                                 AS service,
    sku.description                                     AS sku,
    location.region                                     AS region,
    (SELECT value FROM UNNEST(labels)         WHERE key = 'cost-center') AS cost_center,
    (SELECT value FROM UNNEST(labels)         WHERE key = 'environment') AS environment,
    (SELECT value FROM UNNEST(labels)         WHERE key = 'service')     AS service_label,
    (SELECT value FROM UNNEST(project.labels) WHERE key = 'cost-center') AS project_cost_center,
    cost,
    cost_at_list,
    IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0) AS credits_total,
    IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c
            WHERE c.type = 'COMMITTED_USAGE_DISCOUNT'), 0)      AS cud_credits,
    IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c
            WHERE c.type = 'SUSTAINED_USAGE_DISCOUNT'), 0)      AS sud_credits,
    usage.amount_in_pricing_units AS usage_units,
    usage.pricing_unit            AS usage_unit
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= start_ts
    AND cost_type = 'regular'
)
SELECT
  invoice_month,
  COALESCE(cost_center, project_cost_center, 'UNATTRIBUTED') AS cost_center,
  COALESCE(environment, 'unknown')                           AS environment,
  service,
  sku,
  region,
  ROUND(SUM(cost_at_list), 2)                       AS list_cost,
  ROUND(SUM(cost), 2)                               AS invoiced_before_credits,
  ROUND(SUM(cud_credits), 2)                        AS cud_credits,
  ROUND(SUM(sud_credits), 2)                        AS sud_credits,
  ROUND(SUM(cost) + SUM(credits_total), 2)          AS effective_cost,
  SAFE_DIVIDE(SUM(cost) + SUM(credits_total), NULLIF(SUM(cost_at_list), 0)) AS effective_rate_vs_list,
  ROUND(SUM(usage_units), 3)                        AS usage_units,
  ANY_VALUE(usage_unit)                             AS usage_unit
FROM enriched
GROUP BY invoice_month, cost_center, environment, service, sku, region
HAVING effective_cost > 1.0
ORDER BY invoice_month DESC, effective_cost DESC
LIMIT 200;
```

```
$ bq query --use_legacy_sql=false --maximum_bytes_billed=50000000000 < effective_cost.sql
+---------------+-------------+-------------+----------------------------+--------------------------------------------------+-------------+-----------+-------------------------+-------------+-------------+----------------+------------------------+
| invoice_month | cost_center | environment |          service           |                       sku                        |   region    | list_cost | invoiced_before_credits | cud_credits | sud_credits | effective_cost | effective_rate_vs_list |
+---------------+-------------+-------------+----------------------------+--------------------------------------------------+-------------+-----------+-------------------------+-------------+-------------+----------------+------------------------+
| 202609        | cc-4417     | prod        | Compute Engine             | N2 Instance Core running in Americas             | us-central1 |  61240.11 |                61240.11 |   -22318.44 |    -1180.02 |       37741.65 |     0.6162             |
| 202609        | cc-4417     | prod        | Compute Engine             | N2 Instance Ram running in Americas              | us-central1 |  33110.87 |                33110.87 |   -12071.55 |     -638.10 |       20401.22 |     0.6161             |
| 202609        | cc-2201     | prod        | BigQuery                   | Analysis (on-demand)                             | US          |  28904.00 |                28904.00 |        0.00 |        0.00 |       28904.00 |     1.0000             |
| 202609        | UNATTRIBUTED| unknown     | Networking                 | Network Internet Egress from Americas to China   | us-central1 |  14882.36 |                14882.36 |        0.00 |        0.00 |       14882.36 |     1.0000             |
| 202609        | cc-4417     | prod        | Cloud Storage              | Standard Storage US Multi-region                 | us          |   9120.44 |                 9120.44 |        0.00 |        0.00 |        9120.44 |     1.0000             |
| 202609        | cc-9002     | dev         | Compute Engine             | N2 Instance Core running in Americas             | us-central1 |   8003.19 |                 8003.19 |        0.00 |     -800.31 |        7202.88 |     0.9000             |
+---------------+-------------+-------------+----------------------------+--------------------------------------------------+-------------+-----------+-------------------------+-------------+-------------+----------------+------------------------+
```

Two findings jump out of that output and are typical of a first real query: a $14.8k **unattributed** internet-egress line (nobody knows which service is talking to China), and BigQuery on-demand at $28.9k with a `effective_rate_vs_list` of exactly 1.0 — no commitment coverage at all. Both are actionable within a day.

---

## 4. Layer 3: budgets and alerts — and what they cannot do

### 4.1 Semantics

A **budget** is a resource on the billing account with:

- an **amount** — either a `specifiedAmount` or `lastPeriodAmount` (auto-set to last calendar period's spend),
- a **filter** — projects / folders / subaccounts, services, SKUs, one label key/value, credit treatment,
- **threshold rules** — a percentage plus a `spendBasis` of `CURRENT_SPEND` or `FORECASTED_SPEND`,
- **notification rules** — default IAM recipients (billing admins/users), up to 5 Cloud Monitoring notification channels, and/or a Pub/Sub topic.

| Property | Reality | Why it matters operationally |
|---|---|---|
| Does it stop spend? | **No** | Budgets are observability. Treat as a paging signal, not a control. |
| Evaluation cadence | Several times per day, against exported cost data | An alert can lag real consumption by hours |
| `FORECASTED_SPEND` | Projects end-of-period spend from run rate | The *only* threshold that fires early enough to matter for slow leaks |
| `CURRENT_SPEND` at 100% | Fires after the money is gone | Useful for chargeback records, useless for prevention |
| Pub/Sub notifications | Sent on **every** budget update, not just threshold crossings | Your subscriber must be idempotent and threshold-aware |
| Filter on labels | **One** label key per budget | Drives a "one budget per cost-center" fan-out pattern |
| Budgets per billing account | Bounded (currently 1,000 order of magnitude) | Generate them from IaC, don't hand-create |

### 4.2 Full Terraform: budget + Pub/Sub + Monitoring channel + kill-switch wiring

```hcl
# ---------------------------------------------------------------------------
# terraform/budgets/main.tf
# Budget → Pub/Sub → Cloud Run function. Emits alerts; optionally hard-stops
# billing on non-production projects only.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 6.0" }
  }
}

variable "billing_account_id" {
  description = "Cloud Billing account ID, e.g. 01A2B3-C4D5E6-F7G8H9"
  type        = string
}

variable "ops_project_id" {
  description = "Project hosting the budget notification plumbing"
  type        = string
  default     = "fin-billing-prd-01"
}

# Cost centers driven from a single map so budgets are generated, not authored.
variable "cost_centers" {
  description = "Monthly USD budget per cost-center label value"
  type = map(object({
    monthly_usd  = number
    pagerduty    = bool
    hard_stop    = bool   # only ever true for sandbox/dev
    project_ids  = list(string)
  }))
  default = {
    "cc-4417" = { monthly_usd = 120000, pagerduty = true,  hard_stop = false, project_ids = ["checkout-prd-01", "checkout-prd-02"] }
    "cc-2201" = { monthly_usd = 45000,  pagerduty = true,  hard_stop = false, project_ids = ["analytics-prd-01"] }
    "cc-9002" = { monthly_usd = 6000,   pagerduty = false, hard_stop = true,  project_ids = ["eng-sandbox-01"] }
  }
}

# ---------------------------------------------------------------------------
# Notification transport
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "budget_alerts" {
  project = var.ops_project_id
  name    = "cloud-billing-budget-alerts"

  message_retention_duration = "604800s" # 7 days — replay window for debugging

  labels = {
    cost-center = "cc-0001"
    owner-team  = "platform-sre"
    managed-by  = "terraform"
  }
}

# The Cloud Billing budgets service agent must be able to publish here.
# Terraform does NOT add this binding for you (the console does). This is the
# single most common reason a Pub/Sub-wired budget silently never fires.
resource "google_pubsub_topic_iam_member" "budgets_publisher" {
  project = var.ops_project_id
  topic   = google_pubsub_topic.budget_alerts.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com"
}

resource "google_monitoring_notification_channel" "finops_email" {
  project      = var.ops_project_id
  display_name = "FinOps distribution list"
  type         = "email"
  labels = {
    email_address = "gcp-finops@example.com"
  }
}

resource "google_monitoring_notification_channel" "sre_pagerduty" {
  project      = var.ops_project_id
  display_name = "Platform SRE PagerDuty"
  type         = "pagerduty"
  sensitive_labels {
    service_key = var.pagerduty_service_key
  }
}

# ---------------------------------------------------------------------------
# Per-cost-center budgets
# ---------------------------------------------------------------------------

data "google_project" "targets" {
  for_each   = toset(flatten([for cc in var.cost_centers : cc.project_ids]))
  project_id = each.value
}

resource "google_billing_budget" "cost_center" {
  for_each = var.cost_centers

  billing_account = var.billing_account_id
  display_name    = "budget-${each.key}-monthly"

  budget_filter {
    # Budget filters take project NUMBERS in the form "projects/<number>".
    projects = [
      for p in each.value.project_ids : "projects/${data.google_project.targets[p].number}"
    ]

    calendar_period = "MONTH"

    # INCLUDE_ALL_CREDITS  -> budget tracks EFFECTIVE cost (post CUD/SUD).
    # EXCLUDE_ALL_CREDITS  -> budget tracks gross cost. Choose deliberately:
    # excluding credits makes the budget insensitive to commitment coverage
    # changes, which is what you want when the budget models raw consumption.
    credit_types_treatment = "INCLUDE_ALL_CREDITS"

    # Exactly one label key is supported per budget filter.
    labels = {
      "cost-center" = each.key
    }
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(each.value.monthly_usd)
    }
  }

  # 50% current  -> informational, email only
  # 80% current  -> engineering attention
  # 100% forecast-> the actionable one: run rate will blow the budget
  # 100% current -> the money is spent
  # 120% current -> containment / hard stop for non-prod
  threshold_rules { threshold_percent = 0.5  spend_basis = "CURRENT_SPEND"    }
  threshold_rules { threshold_percent = 0.8  spend_basis = "CURRENT_SPEND"    }
  threshold_rules { threshold_percent = 1.0  spend_basis = "FORECASTED_SPEND" }
  threshold_rules { threshold_percent = 1.0  spend_basis = "CURRENT_SPEND"    }
  threshold_rules { threshold_percent = 1.2  spend_basis = "CURRENT_SPEND"    }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alerts.id
    schema_version = "1.0"

    monitoring_notification_channels = compact([
      google_monitoring_notification_channel.finops_email.id,
      each.value.pagerduty ? google_monitoring_notification_channel.sre_pagerduty.id : "",
    ])

    # Suppress the blast to every billing admin/user; route through channels.
    disable_default_iam_recipients = true
  }
}

# ---------------------------------------------------------------------------
# Org-wide catch-all: forecast-based, covers everything including new projects
# that no cost-center budget has been written for yet.
# ---------------------------------------------------------------------------

resource "google_billing_budget" "org_catch_all" {
  billing_account = var.billing_account_id
  display_name    = "budget-org-catch-all"

  budget_filter {
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
    # No project filter => entire billing account.
  }

  # lastPeriodAmount auto-tracks last month's spend: a pure anomaly detector
  # that needs no maintenance as the estate grows.
  amount {
    last_period_amount = true
  }

  threshold_rules { threshold_percent = 1.15 spend_basis = "FORECASTED_SPEND" }
  threshold_rules { threshold_percent = 1.30 spend_basis = "CURRENT_SPEND"    }

  all_updates_rule {
    pubsub_topic                     = google_pubsub_topic.budget_alerts.id
    schema_version                   = "1.0"
    monitoring_notification_channels = [google_monitoring_notification_channel.sre_pagerduty.id]
    disable_default_iam_recipients   = true
  }
}

output "budget_topic" {
  value = google_pubsub_topic.budget_alerts.id
}
```

### 4.3 The Pub/Sub message contract

Every budget update publishes a message. `schemaVersion 1.0` payload (base64 in `message.data`):

```json
{
  "budgetDisplayName": "budget-cc-9002-monthly",
  "alertThresholdExceeded": 1.2,
  "costAmount": 7231.44,
  "costIntervalStart": "2026-09-01T00:00:00Z",
  "budgetAmount": 6000.0,
  "budgetAmountType": "SPECIFIED_AMOUNT",
  "currencyCode": "USD"
}
```

Message **attributes** carry routing metadata:

```
billingAccountId : 01A2B3-C4D5E6-F7G8H9
budgetId         : 8e2f1c44-7b90-4c1a-9d33-0a5e6b7c8d9e
schemaVersion    : 1.0
```

Critical subscriber semantics:

- `alertThresholdExceeded` is present **only** when a `CURRENT_SPEND` threshold was crossed; `forecastThresholdExceeded` appears for `FORECASTED_SPEND`. Messages arrive with **neither** field on routine updates — your handler must no-op on those.
- Delivery is at-least-once. The handler must be idempotent.
- The payload does **not** identify the project. Resolve it from `budgetId` via the Budgets API, or encode it in the budget `displayName` (as above).

### 4.4 The kill switch — Cloud Run function (Python, gen2)

This is the only automated hard stop available at the billing layer, and it is genuinely destructive: unlinking billing terminates VMs, makes buckets inaccessible, and can cause **irreversible data loss**. Deploy it **only** against sandbox/dev projects, never production.

```python
# functions/budget_killswitch/main.py
"""Disable Cloud Billing on a target project when a budget threshold is crossed.

DESTRUCTIVE. Unlinking the billing account stops all billable resources in the
project and may cause permanent data loss. Guarded by:
  * an allowlist of project IDs (PROTECTED projects can never be unlinked),
  * a minimum threshold below which we only log,
  * a dry-run mode that is the DEFAULT.
"""

from __future__ import annotations

import base64
import json
import logging
import os

import functions_framework
from googleapiclient import discovery
from googleapiclient.errors import HttpError

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("budget-killswitch")

# Comma-separated project IDs that MAY be unlinked. Empty => nothing may be.
ALLOWLIST: set[str] = {
    p.strip() for p in os.environ.get("KILLSWITCH_ALLOWLIST", "").split(",") if p.strip()
}
# Fraction of budget above which we act, e.g. "1.2" == 120%.
ACTION_THRESHOLD: float = float(os.environ.get("KILLSWITCH_THRESHOLD", "1.2"))
# Default TRUE. Must be explicitly set to "false" to actually unlink.
DRY_RUN: bool = os.environ.get("KILLSWITCH_DRY_RUN", "true").lower() != "false"

_billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
_budgets = discovery.build("billingbudgets", "v1", cache_discovery=False)


def _project_ids_for_budget(billing_account_id: str, budget_id: str) -> list[str]:
    """Resolve the budget's filtered projects. Budget filters store project NUMBERS."""
    name = f"billingAccounts/{billing_account_id}/budgets/{budget_id}"
    budget = _budgets.billingAccounts().budgets().get(name=name).execute()
    refs = budget.get("budgetFilter", {}).get("projects", [])
    crm = discovery.build("cloudresourcemanager", "v3", cache_discovery=False)
    ids = []
    for ref in refs:  # "projects/123456789012"
        number = ref.split("/")[-1]
        proj = crm.projects().get(name=f"projects/{number}").execute()
        ids.append(proj["projectId"])
    return ids


def _billing_enabled(project_id: str) -> bool:
    info = _billing.projects().getBillingInfo(name=f"projects/{project_id}").execute()
    return bool(info.get("billingEnabled", False))


def _disable_billing(project_id: str) -> dict:
    """Unlink by setting billingAccountName to the empty string."""
    return (
        _billing.projects()
        .updateBillingInfo(name=f"projects/{project_id}", body={"billingAccountName": ""})
        .execute()
    )


@functions_framework.cloud_event
def handle_budget_notification(cloud_event) -> None:
    attrs = cloud_event.data["message"].get("attributes", {})
    raw = cloud_event.data["message"].get("data")
    payload = json.loads(base64.b64decode(raw).decode("utf-8")) if raw else {}

    budget_name = payload.get("budgetDisplayName", "<unknown>")
    exceeded = payload.get("alertThresholdExceeded")  # None on routine updates
    cost = payload.get("costAmount")
    limit = payload.get("budgetAmount")

    # Routine budget update, no CURRENT_SPEND threshold crossed. No-op.
    if exceeded is None:
        log.info("budget=%s routine update cost=%s limit=%s — no action", budget_name, cost, limit)
        return

    if float(exceeded) < ACTION_THRESHOLD:
        log.warning(
            "budget=%s crossed %.0f%% (cost=%.2f limit=%.2f) — below action threshold %.0f%%",
            budget_name, float(exceeded) * 100, cost, limit, ACTION_THRESHOLD * 100,
        )
        return

    billing_account_id = attrs.get("billingAccountId")
    budget_id = attrs.get("budgetId")
    if not (billing_account_id and budget_id):
        log.error("budget=%s missing routing attributes; cannot resolve projects", budget_name)
        return

    try:
        targets = _project_ids_for_budget(billing_account_id, budget_id)
    except HttpError as exc:
        log.error("budget=%s failed to resolve projects: %s", budget_name, exc)
        return

    if not targets:
        log.error("budget=%s has no project filter — refusing to act on a whole billing account",
                  budget_name)
        return

    for project_id in targets:
        if project_id not in ALLOWLIST:
            log.critical(
                "budget=%s at %.0f%% but project=%s is NOT in the kill-switch allowlist. "
                "PAGE A HUMAN.", budget_name, float(exceeded) * 100, project_id,
            )
            continue

        if not _billing_enabled(project_id):
            log.info("project=%s billing already disabled — idempotent no-op", project_id)
            continue

        if DRY_RUN:
            log.critical("DRY RUN: would unlink billing from project=%s (budget=%s at %.0f%%)",
                         project_id, budget_name, float(exceeded) * 100)
            continue

        try:
            _disable_billing(project_id)
            log.critical("UNLINKED billing from project=%s (budget=%s cost=%.2f limit=%.2f)",
                         project_id, budget_name, cost, limit)
        except HttpError as exc:
            log.error("project=%s unlink FAILED: %s", project_id, exc)
```

```python
# functions/budget_killswitch/requirements.txt
functions-framework==3.*
google-api-python-client==2.*
```

Deployment — note the service account needs `roles/billing.projectManager` **on the target project** and `roles/billing.viewer` on the billing account:

```bash
$ gcloud iam service-accounts create budget-killswitch \
    --project=fin-billing-prd-01 \
    --display-name="Budget kill switch (sandbox only)"
Created service account [budget-killswitch].

$ gcloud beta billing accounts add-iam-policy-binding 01A2B3-C4D5E6-F7G8H9 \
    --member='serviceAccount:budget-killswitch@fin-billing-prd-01.iam.gserviceaccount.com' \
    --role='roles/billing.viewer'
Updated IAM policy for billing account [01A2B3-C4D5E6-F7G8H9].

$ gcloud projects add-iam-policy-binding eng-sandbox-01 \
    --member='serviceAccount:budget-killswitch@fin-billing-prd-01.iam.gserviceaccount.com' \
    --role='roles/billing.projectManager' --condition=None
Updated IAM policy for project [eng-sandbox-01].

$ gcloud functions deploy budget-killswitch \
    --gen2 \
    --project=fin-billing-prd-01 \
    --region=us-central1 \
    --runtime=python312 \
    --source=./functions/budget_killswitch \
    --entry-point=handle_budget_notification \
    --trigger-topic=cloud-billing-budget-alerts \
    --service-account=budget-killswitch@fin-billing-prd-01.iam.gserviceaccount.com \
    --set-env-vars='KILLSWITCH_ALLOWLIST=eng-sandbox-01,KILLSWITCH_THRESHOLD=1.2,KILLSWITCH_DRY_RUN=true' \
    --max-instances=3 \
    --no-allow-unauthenticated

Preparing function...done.
Updating function (may take a while)...
  [Build] done
  [Service] done
  [Trigger] done
Done.
You can view your function in the Cloud Console here:
https://console.cloud.google.com/functions/details/us-central1/budget-killswitch?project=fin-billing-prd-01

state: ACTIVE
updateTime: '2026-09-09T11:42:07.318Z'
```

Test it without waiting for a real budget event:

```bash
$ PAYLOAD=$(printf '%s' '{
  "budgetDisplayName":"budget-cc-9002-monthly",
  "alertThresholdExceeded":1.2,
  "costAmount":7231.44,
  "costIntervalStart":"2026-09-01T00:00:00Z",
  "budgetAmount":6000.0,
  "budgetAmountType":"SPECIFIED_AMOUNT",
  "currencyCode":"USD"}' | base64 -w0)

$ gcloud pubsub topics publish cloud-billing-budget-alerts \
    --project=fin-billing-prd-01 \
    --message="$(echo "$PAYLOAD" | base64 -d)" \
    --attribute=billingAccountId=01A2B3-C4D5E6-F7G8H9,budgetId=8e2f1c44-7b90-4c1a-9d33-0a5e6b7c8d9e,schemaVersion=1.0
messageIds:
- '12894471029371883'

$ gcloud functions logs read budget-killswitch --gen2 --region=us-central1 --limit=5
LEVEL  NAME               TIME_UTC                 LOG
       budget-killswitch  2026-09-09 11:44:12.881  CRITICAL:budget-killswitch:DRY RUN: would unlink billing from project=eng-sandbox-01 (budget=budget-cc-9002-monthly at 120%)
```

---

## 5. Layer 1: quotas and Organization Policy — the only real hard stops

### 5.1 Quotas

| Quota type | Measures | Example | Cost-control usefulness |
|---|---|---|---|
| **Rate quota** | Requests per time window, resets automatically | `compute.googleapis.com/read_requests` — 20,000/min | Indirect: caps API-driven spend and runaway control loops |
| **Allocation quota** | Concurrent resources held, no automatic reset | `CPUS_ALL_REGIONS`, `N2_CPUS` per region, `SSD_TOTAL_GB`, `IN_USE_ADDRESSES` | **Direct and hard.** The ceiling on how much infrastructure can exist |
| **Custom / consumer quota override** | Consumer-set limit below the Google default | BigQuery `QueryUsagePerDay` per project or per user | The canonical guardrail for on-demand BigQuery |

A **lowered allocation quota is the closest thing Google Cloud has to a spending cap**, because it bounds the number of billable resource-units that can simultaneously exist. The trade-off is explicit and severe:

| | Lowered quota | Budget alert |
|---|---|---|
| Stops overspend | Yes, synchronously | No |
| Failure surface | `RESOURCE_EXHAUSTED` / HTTP 429 on resource creation | Email/page |
| Blast radius | **Blocks autoscaling and failover** — a regional evacuation that needs 3× capacity will be denied | None |
| Recovery time | Quota increase request, minutes to days | N/A |
| Correct placement | Sandbox, dev, CI projects; per-region ceilings in prod set well above peak + failover headroom | Everywhere |

**Never set a prod quota at peak utilization.** Size it at `peak × failover_factor × growth_headroom` — typically 2.5–3×. A quota is a circuit breaker against runaway creation, not a capacity plan.

```bash
# Inspect current allocation quotas and usage for a region.
$ gcloud compute regions describe us-central1 \
    --project=eng-sandbox-01 \
    --format="table(quotas.metric, quotas.usage, quotas.limit)" \
  | head -20
METRIC                     USAGE   LIMIT
CPUS                       48.0    1000.0
DISKS_TOTAL_GB             4200.0  102400.0
IN_USE_ADDRESSES           6.0     56.0
LOCAL_SSD_TOTAL_GB         0.0     140000.0
N2_CPUS                    48.0    1000.0
NVIDIA_A100_GPUS           0.0     0.0
PREEMPTIBLE_CPUS           0.0     1000.0
SSD_TOTAL_GB               4200.0  102400.0
STATIC_ADDRESSES           2.0     28.0

# Cloud Quotas API: list quota info for a service.
$ gcloud alpha quotas info list \
    --service=compute.googleapis.com \
    --project=eng-sandbox-01 \
    --format="table(quotaId, metric, dimensions, details.value)" \
  | grep -i cpus | head
CPUS-per-project-region     compute.googleapis.com/cpus       {'region': 'us-central1'}  1000
N2-CPUS-per-project-region  compute.googleapis.com/n2_cpus    {'region': 'us-central1'}  1000

# Lower the sandbox CPU ceiling to a hard cost bound (~$1.4k/mo of N2 at list).
$ gcloud alpha quotas preferences create sandbox-cpu-cap \
    --project=eng-sandbox-01 \
    --service=compute.googleapis.com \
    --quota-id=CPUS-per-project-region \
    --preferred-value=32 \
    --dimensions=region=us-central1 \
    --justification="Cost guardrail: sandbox hard ceiling, approved CAB-2026-0417"
Created quota preference [sandbox-cpu-cap].
name: projects/eng-sandbox-01/locations/global/quotaPreferences/sandbox-cpu-cap
quotaConfig:
  preferredValue: '32'
  stateDetail: Quota decrease applied.
reconciling: false
```

What exceeding a quota looks like at the API — the signal your on-call will see:

```bash
$ gcloud compute instances create burst-worker-0042 \
    --project=eng-sandbox-01 --zone=us-central1-a --machine-type=n2-standard-16
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Quota 'CPUS' exceeded.  Limit: 32.0 in region us-central1.
   metric name = compute.googleapis.com/cpus
   limit name  = CPUS-per-project-region
   limit       = 32.0
   dimensions  = region: us-central1
```

BigQuery on-demand custom quota — a per-project daily bytes-scanned ceiling, arguably the single highest-ROI cost guardrail in the whole platform:

```bash
$ gcloud alpha services quota update \
    --service=bigquery.googleapis.com \
    --consumer=projects/analytics-prd-01 \
    --metric=bigquery.googleapis.com/quota/query/usage \
    --unit='1/d/{project}' \
    --value=51200          # 51,200 GiB = 50 TiB scanned per day, project-wide
Updated consumer quota override.
name: services/bigquery.googleapis.com/projects/847100294411/consumerQuotaMetrics/bigquery.googleapis.com%2Fquota%2Fquery%2Fusage/limits/%2Fd%2Fproject/consumerOverrides/Cl9QUk9KRUNU
overrideValue: '51200'
unit: 1/d/{project}
```

Query-level guard, which belongs in every scheduled query and CI job:

```bash
$ bq query --use_legacy_sql=false --maximum_bytes_billed=1099511627776 \
  'SELECT user_id, COUNT(*) FROM `analytics-prd-01.events.raw` GROUP BY 1'
Error in query string: Query exceeded limit for bytes billed: 1099511627776.
414284591104000 or higher required.
```

That error costs **$0.00** — the job is rejected before scanning. Without the flag, that query scans ~377 TiB and bills roughly $2,350 on the on-demand rate. This one flag is the difference.

### 5.2 Organization Policy — preventive guardrails

Org Policy constraints are evaluated at resource-create/update time, inherited down the hierarchy, and cannot be bypassed by project-level IAM. They are where architectural cost decisions get enforced rather than documented.

Cost-relevant built-in constraints:

| Constraint | Type | Cost effect |
|---|---|---|
| `constraints/gcp.resourceLocations` | List | Confines resources to approved regions — blocks accidental deployment into premium-priced regions and cross-region egress |
| `constraints/compute.vmExternalIpAccess` | List | No external IPs → forces egress through Cloud NAT/proxies where it is observable and rate-limitable |
| `constraints/gcp.restrictServiceUsage` | List | Whitelist which APIs may be enabled at all — prevents a team turning on an expensive managed service unilaterally |
| `constraints/compute.disableGlobalLoadBalancing` | Boolean | Blocks premium global LB in environments that only need regional |
| `constraints/compute.restrictCloudNATUsage` | List | Constrains where NAT (a per-hour + per-GB cost) may be created |
| `constraints/compute.storageResourceUseRestrictions` | List | Restricts which storage resources may be consumed |

Applied as YAML, one file per policy, in a policy-as-code repo:

```yaml
# orgpolicy/folders/nonprod/gcp.resourceLocations.yaml
# Confine all non-prod resources to two low-cost US regions.
name: folders/554433221100/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:us-central1-locations
          - in:us-east1-locations
          - in:us-locations          # multi-region for GCS/BQ
```

```yaml
# orgpolicy/folders/nonprod/compute.vmExternalIpAccess.yaml
# No public IPs anywhere in non-prod. Removes both an attack surface and an
# uncontrolled internet-egress path.
name: folders/554433221100/policies/compute.vmExternalIpAccess
spec:
  inheritFromParent: false
  rules:
    - denyAll: true
```

```yaml
# orgpolicy/folders/nonprod/gcp.restrictServiceUsage.yaml
# Only these APIs may be enabled. Anything not listed cannot be turned on,
# so it cannot generate a line item.
name: folders/554433221100/policies/gcp.restrictServiceUsage
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - services/compute.googleapis.com
          - services/container.googleapis.com
          - services/storage.googleapis.com
          - services/bigquery.googleapis.com
          - services/run.googleapis.com
          - services/cloudbuild.googleapis.com
          - services/artifactregistry.googleapis.com
          - services/logging.googleapis.com
          - services/monitoring.googleapis.com
          - services/secretmanager.googleapis.com
          - services/iam.googleapis.com
          - services/cloudresourcemanager.googleapis.com
```

**Custom constraints** are how you enforce machine-shape economics, which no built-in constraint covers:

```yaml
# orgpolicy/custom-constraints/restrictNonProdMachineTypes.yaml
# Define the constraint at the ORGANIZATION level (definitions are org-scoped);
# enforce it lower down with a policy binding.
name: organizations/123456789012/customConstraints/custom.restrictNonProdMachineTypes
resourceTypes:
  - compute.googleapis.com/Instance
methodTypes:
  - CREATE
  - UPDATE
condition: |
  resource.machineType.contains('/machineTypes/e2-') ||
  resource.machineType.contains('/machineTypes/t2d-') ||
  resource.machineType.contains('/machineTypes/n2-standard-2') ||
  resource.machineType.contains('/machineTypes/n2-standard-4') ||
  resource.machineType.contains('/machineTypes/n2-standard-8')
actionType: ALLOW
displayName: Non-prod cost-efficient machine types only
description: >-
  Non-production workloads may only run on E2, Tau T2D, or N2 standard shapes up
  to 8 vCPU. Memory-optimized (M1/M2/M3), accelerator-optimized (A2/A3/G2), and
  large N2/C2 shapes require an approved exception at the prod folder.
```

```yaml
# orgpolicy/custom-constraints/denyNonProdGpus.yaml
name: organizations/123456789012/customConstraints/custom.denyNonProdGpus
resourceTypes:
  - compute.googleapis.com/Instance
methodTypes:
  - CREATE
  - UPDATE
condition: "has(resource.guestAccelerators) && size(resource.guestAccelerators) > 0"
actionType: DENY
displayName: No GPUs outside the ML folder
description: >-
  Accelerators are the highest per-hour SKU family in the estate. Their use is
  confined to folders/778899001122 (ml-platform), which has its own budget,
  reservations, and Spot-first policy.
```

```yaml
# orgpolicy/folders/nonprod/custom.restrictNonProdMachineTypes.yaml
name: folders/554433221100/policies/custom.restrictNonProdMachineTypes
spec:
  rules:
    - enforce: true
```

Apply and verify:

```bash
$ gcloud org-policies set-custom-constraint \
    orgpolicy/custom-constraints/restrictNonProdMachineTypes.yaml
Created custom constraint [custom.restrictNonProdMachineTypes].

$ gcloud org-policies set-policy \
    orgpolicy/folders/nonprod/custom.restrictNonProdMachineTypes.yaml
Created policy [folders/554433221100/policies/custom.restrictNonProdMachineTypes].

$ gcloud org-policies describe custom.restrictNonProdMachineTypes \
    --folder=554433221100 --effective
name: folders/554433221100/policies/custom.restrictNonProdMachineTypes
spec:
  etag: CN2y3rwGEPjK8dED
  rules:
  - enforce: true
  updateTime: '2026-09-09T12:03:44.117292Z'

# The enforcement, observed from a developer's shell:
$ gcloud compute instances create ml-scratch-01 \
    --project=eng-sandbox-01 --zone=us-central1-a \
    --machine-type=m1-ultramem-40
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Operation denied by custom org policy:
   ["customConstraints/custom.restrictNonProdMachineTypes":
    "Non-production workloads may only run on E2, Tau T2D, or N2 standard shapes
     up to 8 vCPU. Memory-optimized (M1/M2/M3), accelerator-optimized (A2/A3/G2),
     and large N2/C2 shapes require an approved exception at the prod folder."].
```

A single `m1-ultramem-40` left running for a month is roughly $4,900 at list. This policy is a two-file change that prevents that class of mistake permanently, for every engineer, forever. This is what "the platform controls cost" actually means — not a dashboard.

---

## 6. Layer 5: pricing models and commitment engineering

### 6.1 Compute Engine discount mechanisms compared

| Mechanism | Discount | Commitment | Flexibility | Interruptible | Applies to | When to use |
|---|---|---|---|---|---|---|
| **Sustained Use Discount (SUD)** | Up to ~30% (N1) / ~20% (N2, N2D, C2, C2D, M1, M2) | None — automatic | Total | No | Predefined machine types running a significant fraction of the month. **E2 and Tau T2D/T2A are excluded** (already discounted). | Free money. Nothing to do. |
| **Resource-based CUD** | Up to ~55% general-purpose, up to ~70% memory-optimized | 1 or 3 years | Locked to **region + machine family**; vCPU and memory purchased separately | No | Compute Engine, Cloud SQL, and others | Steady-state baseline you are certain of, in a region you will not leave |
| **Spend-based / Flexible CUD** | ~28% (1y) / ~46% (3y) for Compute Flexible CUDs; varies by product | 1 or 3 years, `$/hour` | **Family- and region-agnostic** (Flexible CUD); portable across machine families | No | Compute (Flexible), Cloud Run, GKE Autopilot, Cloud SQL, Spanner, Bigtable, VMware Engine | Baseline whose *shape* will change but whose *magnitude* will not |
| **Reservations** | None by itself — **guarantees capacity** | Billed whether used or not | Zonal, specific shape | No | Compute Engine | Capacity assurance for failover/burst; combine with CUD to also get the discount |
| **Spot VMs** | 60–91% off on-demand | None | Total | **Yes** — 30s preemption notice, no max runtime | Compute Engine, GKE node pools, Dataproc, Batch | Fault-tolerant, checkpointable, horizontally scalable work |
| **Free tier** | Specified always-free monthly allowances | None | N/A | No | e2-micro, 5 GB GCS, 1 TiB BQ query/mo, etc. | Learning, tiny utilities |

> Discount percentages here are representative and vary by machine family, region, term and currency. Always confirm against the Compute Engine pricing page and the Pricing Calculator before committing.

### 6.2 The commitment coverage strategy

The mature pattern is a **three-tier capacity stack**:

```
                 ┌──────────────────────────────────────────┐
   Burst / batch │  Spot VMs  (60–91% off, preemptible)      │  ← elastic, cheap
                 ├──────────────────────────────────────────┤
   Variable      │  On-demand + SUD (automatic ~20–30%)      │  ← flexible buffer
                 ├──────────────────────────────────────────┤
   Baseline      │  CUD-covered (1y/3y, 28–70% off)          │  ← never idles
                 └──────────────────────────────────────────┘
```

**Never commit to 100% of current usage.** Target CUD coverage at the **P10–P25 of trailing 90-day hourly usage** — the floor your consumption genuinely never drops below. An over-committed CUD bills every hour whether you consume it or not, and it is not cancellable. The asymmetry is important: under-committing costs you a missed discount on the uncovered portion; over-committing costs you 100% of the unused commitment.

Compute the floor from the billing export:

```sql
-- Hourly vCPU-hours by machine family, last 90 days, with percentiles.
-- Commit at or below P10. Anything above P50 is variable load: leave on-demand
-- so SUD applies, or move it to Spot.
WITH hourly AS (
  SELECT
    TIMESTAMP_TRUNC(usage_start_time, HOUR) AS hour_ts,
    REGEXP_EXTRACT(sku.description, r'^(N1|N2|N2D|E2|C2|C2D|T2D|M1|M2|M3)') AS family,
    location.region AS region,
    SUM(usage.amount_in_pricing_units) AS vcpu_hours
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 92 DAY)
    AND service.description = 'Compute Engine'
    AND sku.description LIKE '%Instance Core running%'
    AND cost_type = 'regular'
  GROUP BY hour_ts, family, region
)
SELECT
  family,
  region,
  COUNT(*)                                                     AS observed_hours,
  ROUND(MIN(vcpu_hours), 1)                                    AS p0_floor,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(10)], 1)      AS p10,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(25)], 1)      AS p25,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(50)], 1)      AS p50,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(95)], 1)      AS p95,
  ROUND(MAX(vcpu_hours), 1)                                    AS peak,
  ROUND(SAFE_DIVIDE(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(10)],
                    APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(95)]), 3) AS floor_to_peak_ratio
FROM hourly
WHERE family IS NOT NULL
GROUP BY family, region
HAVING observed_hours > 2000
ORDER BY p50 DESC;
```

```
+--------+-------------+----------------+----------+--------+--------+--------+--------+--------+---------------------+
| family |   region    | observed_hours | p0_floor |  p10   |  p25   |  p50   |  p95   |  peak  | floor_to_peak_ratio |
+--------+-------------+----------------+----------+--------+--------+--------+--------+--------+---------------------+
| N2     | us-central1 |           2208 |    712.0 |  844.0 |  901.0 | 1188.0 | 2410.0 | 3102.0 |               0.350 |
| N2     | europe-west1|           2208 |    204.0 |  248.0 |  266.0 |  341.0 |  702.0 |  918.0 |               0.353 |
| E2     | us-central1 |           2208 |     88.0 |  106.0 |  121.0 |  204.0 |  588.0 |  744.0 |               0.180 |
| C2     | us-central1 |           1904 |      0.0 |    0.0 |   16.0 |  144.0 |  980.0 | 1240.0 |               0.000 |
+--------+-------------+----------------+----------+--------+--------+--------+--------+--------+---------------------+
```

Reading this like an architect: N2/us-central1 has a rock-solid 844 vCPU floor — commit 800 vCPU on a 3-year resource-based CUD. C2 has a P10 of **zero**: it is pure batch. Committing anything on C2 would be burning money; that workload belongs on Spot. E2 gets no SUD, so its 106 vCPU floor is a clean CUD candidate too.

Purchase and verify:

```bash
$ gcloud compute commitments create cud-n2-usc1-3y-2026q3 \
    --project=checkout-prd-01 \
    --region=us-central1 \
    --plan=THIRTY_SIX_MONTH \
    --type=GENERAL_PURPOSE_N2 \
    --resources=vcpu=800,memory=3200GB
Created [https://www.googleapis.com/compute/v1/projects/checkout-prd-01/regions/us-central1/commitments/cud-n2-usc1-3y-2026q3].

$ gcloud compute commitments list --project=checkout-prd-01 \
    --format="table(name, region, plan, status, startTimestamp.date('%Y-%m-%d'), endTimestamp.date('%Y-%m-%d'))"
NAME                   REGION       PLAN              STATUS  START_TIMESTAMP  END_TIMESTAMP
cud-n2-usc1-3y-2026q3  us-central1  THIRTY_SIX_MONTH  ACTIVE  2026-09-09       2029-09-09
```

> **Enable CUD sharing** on the billing account so a commitment purchased in one project applies across every project on that billing account. Without it, the commitment is stranded in the purchasing project and utilization craters when workloads move.

Track utilization continuously — an under-consumed CUD is the most expensive silent failure in cloud finance:

```sql
-- CUD utilization: are we consuming what we committed to?
SELECT
  invoice.month,
  sku.description AS sku,
  ROUND(SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE', -c.amount, 0)), 2) AS commitment_fee_paid,
  ROUND(SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT',             -c.amount, 0)), 2) AS discount_realized,
  ROUND(SAFE_DIVIDE(
    SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT', -c.amount, 0)),
    NULLIF(SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE', -c.amount, 0)), 0)), 3) AS utilization
FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`,
  UNNEST(credits) AS c
WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 120 DAY)
  AND c.type IN ('COMMITTED_USAGE_DISCOUNT', 'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE')
GROUP BY invoice.month, sku
ORDER BY invoice.month DESC, commitment_fee_paid DESC;
```

Anything with `utilization < 0.95` sustained for two months is money on the floor and warrants a workload-placement review.

---

## 7. Layer 4: Active Assist / Recommender — the optimization loop

Recommender is a family of ML- and heuristic-driven recommenders that surface waste. The ones that matter for cost:

| Recommender ID | Finds | Typical action |
|---|---|---|
| `google.compute.instance.IdleResourceRecommender` | VMs with near-zero CPU/network for 14 days | Stop or delete |
| `google.compute.disk.IdleResourceRecommender` | Persistent disks unattached for 15+ days | Snapshot and delete |
| `google.compute.address.IdleResourceRecommender` | Reserved static IPs not attached (billed while idle) | Release |
| `google.compute.image.IdleResourceRecommender` | Unused custom images | Delete |
| `google.compute.instance.MachineTypeRecommender` | Over-provisioned VMs (rightsizing) | Resize down |
| `google.compute.commitment.UsageCommitmentRecommender` | CUD purchase opportunities | Buy commitment |
| `google.cloudsql.instance.IdleRecommender` | Idle Cloud SQL instances | Stop/delete |
| `google.cloudsql.instance.OverprovisionedRecommender` | Oversized Cloud SQL | Downsize |
| `google.bigquery.table.PartitionClusterRecommender` | Tables that would benefit from partitioning/clustering | Reduce bytes scanned |
| `google.resourcemanager.projectUtilization.GeneralRecommender` | Unattended projects (no activity, still billing) | Reclaim |

```bash
$ gcloud recommender recommendations list \
    --project=analytics-prd-01 \
    --location=us-central1-a \
    --recommender=google.compute.instance.IdleResourceRecommender \
    --format="table(
        name.basename():label=ID,
        priority,
        primaryImpact.costProjection.cost.units:label=MONTHLY_USD,
        stateInfo.state,
        description)"

ID                                    PRIORITY  MONTHLY_USD  STATE   DESCRIPTION
b1f4e2a0-3c77-4a91-9c5e-88a1d2f30011  P2        -412         ACTIVE  Save cost by stopping idle VM 'legacy-etl-runner-03'.
7d90c4b1-5e12-4f88-b2a3-11c9e7f40022  P3        -186         ACTIVE  Save cost by stopping idle VM 'dashboard-poc-01'.
2c33a891-9b04-4d10-8f7c-6a2b0e5c0033  P2        -338         ACTIVE  Save cost by stopping idle VM 'spark-history-legacy'.

$ gcloud recommender recommendations describe b1f4e2a0-3c77-4a91-9c5e-88a1d2f30011 \
    --project=analytics-prd-01 --location=us-central1-a \
    --recommender=google.compute.instance.IdleResourceRecommender \
    --format="yaml(content.operationGroups, primaryImpact, associatedInsights)"
content:
  operationGroups:
  - operations:
    - action: test
      path: /status
      resource: //compute.googleapis.com/projects/analytics-prd-01/zones/us-central1-a/instances/legacy-etl-runner-03
      resourceType: compute.googleapis.com/Instance
      valueMatcher:
        matchesPattern: .*RUNNING.*
    - action: replace
      path: /status
      resource: //compute.googleapis.com/projects/analytics-prd-01/zones/us-central1-a/instances/legacy-etl-runner-03
      resourceType: compute.googleapis.com/Instance
      value: TERMINATED
primaryImpact:
  category: COST
  costProjection:
    cost:
      currencyCode: USD
      nanos: -220000000
      units: '-412'
    duration: 2592000s
```

Aggregate the whole estate rather than clicking through per-project. Export recommendations to BigQuery via the Recommender BigQuery Export, then:

```sql
-- Total addressable waste across the org, ranked by recommender.
SELECT
  recommender,
  COUNT(*)                                                       AS recommendation_count,
  ROUND(SUM(-(CAST(primary_impact.cost_projection.cost.units AS INT64)
              + CAST(primary_impact.cost_projection.cost.nanos AS FLOAT64)/1e9)), 2)
                                                                 AS monthly_savings_usd
FROM `fin-billing-prd-01.recommender_export.recommendations_export`
WHERE _PARTITIONDATE = CURRENT_DATE()
  AND state = 'ACTIVE'
  AND primary_impact.category = 'COST'
GROUP BY recommender
ORDER BY monthly_savings_usd DESC;
```

```
+-------------------------------------------------------------+----------------------+---------------------+
|                        recommender                          | recommendation_count | monthly_savings_usd |
+-------------------------------------------------------------+----------------------+---------------------+
| google.compute.commitment.UsageCommitmentRecommender         |                    6 |            18204.40 |
| google.compute.instance.MachineTypeRecommender               |                  114 |             7911.22 |
| google.compute.instance.IdleResourceRecommender              |                   41 |             4488.05 |
| google.compute.disk.IdleResourceRecommender                  |                  203 |             2107.66 |
| google.cloudsql.instance.OverprovisionedRecommender          |                    9 |             1844.90 |
| google.compute.address.IdleResourceRecommender               |                   77 |              554.40 |
| google.compute.image.IdleResourceRecommender                 |                   31 |              118.70 |
+-------------------------------------------------------------+----------------------+---------------------+
```

The **FinOps Hub** in the Cloud Billing console aggregates the same signal into a savings-opportunity view with an estimated total, plus a waste view (idle/underutilized resources). It is the right starting surface for a leadership conversation; the BigQuery export is the right surface for automation.

---

## 8. Service-specific cost architecture

### 8.1 BigQuery: the two pricing models

| | On-demand (per-TiB analysis) | Editions / capacity (slots) |
|---|---|---|
| Billed on | Bytes **scanned** (not returned) | Slot-hours reserved/autoscaled |
| Cost predictability | Poor — one bad query is unbounded | High — bounded by max reservation slots |
| Guardrails | `maximum_bytes_billed`, custom daily quota, partitioning/clustering | Reservation `max_slots`, autoscaler baseline |
| Concurrency behavior | Per-project slot fair-share, opaque | Explicit; queries queue rather than cost more |
| Best for | Ad-hoc/exploratory, spiky, low-volume | Steady, high-volume, predictable analytics; anything > ~$2k/mo on-demand |
| Commitment | None | 1y/3y slot commitments for further discount |

Partitioning and clustering are the highest-leverage BigQuery cost control, because on-demand bills bytes scanned and a partition filter eliminates them before the scan:

```sql
-- Partitioned + clustered fact table with a REQUIRED partition filter.
-- require_partition_filter is the guardrail: any query without a WHERE on
-- event_date is REJECTED, not silently full-scanned.
CREATE TABLE `analytics-prd-01.events.raw_v2`
(
  event_date   DATE      NOT NULL,
  event_ts     TIMESTAMP NOT NULL,
  user_id      STRING    NOT NULL,
  session_id   STRING,
  event_type   STRING    NOT NULL,
  country      STRING,
  device       STRING,
  revenue_usd  NUMERIC,
  payload      JSON
)
PARTITION BY event_date
CLUSTER BY event_type, country, user_id
OPTIONS (
  description                     = "Raw event stream. Partition filter REQUIRED.",
  partition_expiration_days       = 400,
  require_partition_filter        = TRUE,
  labels                          = [("cost-center", "cc-2201"), ("data-class", "internal")]
);
```

```bash
# Dry run is free and tells you the bill before you pay it. Put this in CI.
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country, SUM(revenue_usd)
   FROM `analytics-prd-01.events.raw_v2`
   WHERE event_date BETWEEN "2026-09-01" AND "2026-09-07"
     AND event_type = "purchase"
   GROUP BY country'
Query successfully validated. Assuming the tables are not modified,
running this query will process 41802336768 bytes of data.
# 41.8 GB ≈ 0.039 TiB ≈ $0.24 on-demand.

# Same query without the partition filter:
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country, SUM(revenue_usd) FROM `analytics-prd-01.events.raw_v2`
   WHERE event_type = "purchase" GROUP BY country'
Error in query string: Cannot query over table
'analytics-prd-01.events.raw_v2' without a filter over column(s) 'event_date'
that can be used for partition elimination.
```

That rejection saved a ~415 TiB scan (≈ $2,590) and cost nothing.

Switch to capacity pricing when on-demand becomes the dominant line:

```bash
$ bq mk --project_id=analytics-prd-01 --location=US \
    --reservation --slots=500 --edition=ENTERPRISE \
    --autoscale_max_slots=1500 \
    prod-analytics
Reservation 'analytics-prd-01:US.prod-analytics' successfully created.

$ bq mk --project_id=analytics-prd-01 --location=US \
    --reservation_assignment \
    --assignee_id=analytics-prd-01 --assignee_type=PROJECT \
    --job_type=QUERY --reservation_id=prod-analytics
Assignment successfully created.
```

With `--slots=500` baseline and `--autoscale_max_slots=1500`, the monthly cost is bounded: it cannot exceed the 1,500-slot rate no matter what SQL anyone writes. That is a **hard cost ceiling for analytics** — something on-demand structurally cannot give you.

### 8.2 Cloud Storage: classes, lifecycle, Autoclass

| Class | Min storage duration | Storage $/GB-mo (rep.) | Retrieval fee | Use for |
|---|---|---|---|---|
| Standard | none | ~$0.020 | none | Hot, frequently read |
| Nearline | 30 days | ~$0.010 | yes, per GB | ≤ ~1 access/month |
| Coldline | 90 days | ~$0.004 | higher | ≤ ~1 access/quarter |
| Archive | 365 days | ~$0.0012 | highest | ≤ ~1 access/year, compliance |

*Representative us-central1 regional prices; confirm on the pricing page.*

The trap: **early-deletion fees**. Deleting or rewriting a Coldline object after 10 days still bills the full 90-day minimum. Lifecycle rules that transition too aggressively can cost more than they save.

```json
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "SetStorageClass", "storageClass": "NEARLINE" },
        "condition": {
          "age": 30,
          "matchesPrefix": ["events/", "logs/"],
          "matchesStorageClass": ["STANDARD"]
        }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": {
          "age": 120,
          "matchesPrefix": ["events/", "logs/"],
          "matchesStorageClass": ["NEARLINE"]
        }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": {
          "age": 365,
          "matchesPrefix": ["events/", "logs/"],
          "matchesStorageClass": ["COLDLINE"]
        }
      },
      {
        "action": { "type": "Delete" },
        "condition": {
          "age": 2555,
          "matchesPrefix": ["events/", "logs/"]
        }
      },
      {
        "action": { "type": "Delete" },
        "condition": {
          "daysSinceNoncurrentTime": 14,
          "numNewerVersions": 3
        }
      },
      {
        "action": { "type": "AbortIncompleteMultipartUpload" },
        "condition": { "age": 7 }
      }
    ]
  }
}
```

```bash
$ gcloud storage buckets update gs://analytics-prd-01-events \
    --lifecycle-file=lifecycle.json
Updating gs://analytics-prd-01-events/...
  Completed 1

$ gcloud storage buckets describe gs://analytics-prd-01-events \
    --format="yaml(name, location, storageClass, autoclass, lifecycle_config)"
autoclass: null
lifecycle_config:
  rule:
  - action: {storageClass: NEARLINE, type: SetStorageClass}
    condition: {age: 30, matchesPrefix: [events/, logs/], matchesStorageClass: [STANDARD]}
  ...
location: US-CENTRAL1
name: analytics-prd-01-events
storageClass: STANDARD
```

The last two rules matter more than people expect: **abandoned multipart uploads** and **noncurrent object versions** are invisible in the console object listing but fully billed. They are a routine five-figure surprise on versioned buckets.

When access patterns are unknown or bimodal, **Autoclass** moves objects between classes automatically based on actual access, with no early-deletion or retrieval fees (it carries a per-object management fee instead):

```bash
$ gcloud storage buckets update gs://ml-datasets-prd-01 \
    --enable-autoclass --autoclass-terminal-storage-class=ARCHIVE
Updating gs://ml-datasets-prd-01/...
  Completed 1
```

### 8.3 GKE: cost model and containment

| | GKE Standard | GKE Autopilot |
|---|---|---|
| Billed for | **Nodes** (full VM cost, whether pods use them or not) + cluster management fee | **Pod resource requests** (vCPU/mem/storage) + cluster management fee |
| Waste mode | Unbid node headroom, poor bin-packing | Over-declared `requests` |
| Cost lever | Cluster autoscaler, node auto-provisioning, Spot node pools, bin-packing | Accurate `requests`, Spot pods, VPA |
| Predictability | Node-count driven | Request driven — directly attributable per workload |
| Best when | You need DaemonSets, privileged workloads, GPU tuning, custom OS | You want cost proportional to declared demand |

Enable **GKE cost allocation** so per-namespace and per-workload cost appears in the detailed billing export:

```bash
$ gcloud container clusters update prod-usc1 \
    --project=checkout-prd-01 --region=us-central1 \
    --enable-cost-allocation
Updating prod-usc1...done.

$ gcloud container clusters describe prod-usc1 \
    --region=us-central1 --format="yaml(costManagementConfig)"
costManagementConfig:
  enabled: true
```

Then in the detailed export, cost rows carry `goog-k8s-cluster-name`, `goog-k8s-cluster-location`, `goog-k8s-namespace`, `goog-k8s-workload-name`, `goog-k8s-workload-type`:

```sql
SELECT
  (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-cluster-name')  AS cluster,
  (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-namespace')     AS namespace,
  (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-workload-name') AS workload,
  ROUND(SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS effective_cost
FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_resource_v1_01A2B3_C4D5E6_F7G8H9`
WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key = 'goog-k8s-namespace')
GROUP BY cluster, namespace, workload
ORDER BY effective_cost DESC
LIMIT 25;
```

Namespace-level hard caps — the Kubernetes-native equivalent of a quota:

```yaml
---
# k8s/namespaces/team-checkout/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-checkout
  labels:
    cost-center: cc-4417
    owner-team: checkout
    environment: prod
---
# k8s/namespaces/team-checkout/resourcequota.yaml
# Hard ceiling on what this namespace can request. On Autopilot this is
# literally a hard cost cap, because Autopilot bills requests.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-checkout-quota
  namespace: team-checkout
spec:
  hard:
    requests.cpu: "240"
    requests.memory: "960Gi"
    requests.ephemeral-storage: "2000Gi"
    limits.cpu: "480"
    limits.memory: "1920Gi"
    requests.nvidia.com/gpu: "0"
    persistentvolumeclaims: "40"
    requests.storage: "8Ti"
    count/services.loadbalancers: "4"     # each forwarding rule is a real hourly SKU
    count/services.nodeports: "0"
    pods: "400"
---
# k8s/namespaces/team-checkout/limitrange.yaml
# Defaults + bounds. Prevents both unbounded pods (no requests at all) and
# absurd single-pod requests that would consume the whole quota.
apiVersion: v1
kind: LimitRange
metadata:
  name: team-checkout-limits
  namespace: team-checkout
spec:
  limits:
    - type: Container
      default:              # becomes limits if unspecified
        cpu: "500m"
        memory: "512Mi"
        ephemeral-storage: "1Gi"
      defaultRequest:       # becomes requests if unspecified — what Autopilot bills
        cpu: "100m"
        memory: "128Mi"
        ephemeral-storage: "512Mi"
      max:
        cpu: "8"
        memory: "32Gi"
        ephemeral-storage: "50Gi"
      min:
        cpu: "10m"
        memory: "16Mi"
      maxLimitRequestRatio: # cap burst ratio: stops 100m-request/8-CPU-limit abuse
        cpu: "4"
        memory: "2"
    - type: PersistentVolumeClaim
      max:
        storage: "1Ti"
      min:
        storage: "1Gi"
```

Spot node pool for interruption-tolerant work on GKE Standard:

```bash
$ gcloud container node-pools create batch-spot \
    --cluster=prod-usc1 --project=checkout-prd-01 --region=us-central1 \
    --spot \
    --machine-type=n2-standard-8 \
    --enable-autoscaling --min-nodes=0 --max-nodes=60 \
    --node-labels=workload-class=batch,cost-tier=spot \
    --node-taints=cloud.google.com/gke-spot=true:NoSchedule \
    --disk-type=pd-balanced --disk-size=100
Creating node pool batch-spot...done.
```

```yaml
# k8s/workloads/etl-batch.yaml
# Only workloads that explicitly tolerate the taint land on Spot nodes,
# so a Spot preemption can never take out a latency-critical service.
apiVersion: batch/v1
kind: Job
metadata:
  name: nightly-etl
  namespace: team-checkout
  labels:
    cost-center: cc-4417
    cost-tier: spot
spec:
  parallelism: 20
  completions: 20
  backoffLimit: 12          # generous: Spot preemption counts as a failure
  template:
    metadata:
      labels:
        cost-center: cc-4417
        cost-tier: spot
    spec:
      restartPolicy: OnFailure
      terminationGracePeriodSeconds: 25   # inside the ~30s Spot preemption notice
      nodeSelector:
        cloud.google.com/gke-spot: "true"
        workload-class: batch
      tolerations:
        - key: cloud.google.com/gke-spot
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: etl
          image: us-central1-docker.pkg.dev/checkout-prd-01/apps/etl:1.14.2
          resources:
            requests:
              cpu: "2"
              memory: "6Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
          env:
            - name: CHECKPOINT_URI
              value: gs://checkout-prd-01-etl-state/nightly/
          lifecycle:
            preStop:
              exec:
                # Flush progress on the preemption signal so restart is cheap.
                command: ["/bin/sh", "-c", "/app/checkpoint.sh --flush && sleep 5"]
```

### 8.4 Network egress — the line item nobody owns

Egress is charged asymmetrically and is invisible until the invoice arrives.

| Traffic | Charged? | Notes |
|---|---|---|
| Ingress from internet | Generally free | |
| Egress to internet | **Yes**, per GB, destination-dependent | Highest-variance line item |
| Egress between zones in a region | **Yes**, per GB | Multi-zone HA has a real running cost |
| Egress between regions | **Yes**, per GB, rate depends on region pair | Cross-region replication is not free |
| Egress within a zone (internal IP) | Free | Prefer same-zone chatty paths |
| Egress to Google APIs / services in-region | Generally free with Private Google Access | |
| Cloud CDN cache egress | Cheaper than origin egress | Cache-hit ratio is a cost KPI |
| Cloud Interconnect / Direct Peering egress | Reduced rate | Justified above a few TB/month |

**Network Service Tiers** are a first-class cost lever: Premium Tier routes over Google's backbone end-to-end; Standard Tier hands off to the public internet closer to the source, at a lower per-GB rate and lower/less consistent performance.

```bash
# Default a project to Standard tier for non-latency-sensitive estates.
$ gcloud compute project-info update --default-network-tier=STANDARD \
    --project=eng-sandbox-01
Updated [https://www.googleapis.com/compute/v1/projects/eng-sandbox-01].

$ gcloud compute project-info describe --project=eng-sandbox-01 \
    --format="value(defaultNetworkTier)"
STANDARD
```

Find the owner of unattributed egress from the detailed export:

```sql
SELECT
  project.id AS project_id,
  resource.name AS resource,
  sku.description AS sku,
  ROUND(SUM(usage.amount)/POW(1024,3), 1) AS gib,
  ROUND(SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS effective_cost
FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_resource_v1_01A2B3_C4D5E6_F7G8H9`
WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND (sku.description LIKE '%Egress%' OR sku.description LIKE '%Network Internet%')
  AND cost_type = 'regular'
GROUP BY project_id, resource, sku
ORDER BY effective_cost DESC
LIMIT 20;
```

### 8.5 Cloud Run: the request-driven cost model

| Setting | Cost effect |
|---|---|
| **CPU allocated during request only** (default) | You pay CPU/memory only while a request is in flight — scale-to-zero is genuine |
| **CPU always allocated** | Billed for the full instance lifetime; required for background work, more expensive |
| `--min-instances=N` | N instances billed 24/7 — this is the knob that silently turns a scale-to-zero service into a fixed cost |
| `--max-instances=N` | **A hard cost ceiling.** Bounds worst-case concurrent billed instances |
| `--concurrency=N` | Higher concurrency = fewer instances for the same traffic = lower cost, until latency degrades |

```bash
$ gcloud run deploy checkout-api \
    --project=checkout-prd-01 --region=us-central1 \
    --image=us-central1-docker.pkg.dev/checkout-prd-01/apps/checkout-api:2.8.1 \
    --cpu=1 --memory=512Mi \
    --concurrency=80 \
    --min-instances=2 \
    --max-instances=200 \
    --no-cpu-boost \
    --labels=cost-center=cc-4417,environment=prod,service=checkout-api
Deploying container to Cloud Run service [checkout-api] in project [checkout-prd-01] region [us-central1]
✓ Deploying... Done.
Service [checkout-api] revision [checkout-api-00042-hqz] has been deployed and is serving 100 percent of traffic.
```

`--max-instances=200` at 1 vCPU / 512 MiB is a computable worst-case monthly cost. Deploying without it means the worst case is unbounded — a Cloud Run service under a retry storm is a spend amplifier.

---

## 9. Verification and failure diagnosis

### 9.1 Landing-zone cost-control acceptance checklist

Run this before declaring an environment production-ready. Every line is a command, not an opinion.

```bash
# 1. Billing export is enabled and CURRENT (not stalled).
$ bq query --use_legacy_sql=false --format=prettyjson \
'SELECT MAX(export_time) AS latest_export,
        TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(export_time), HOUR) AS lag_hours
 FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
 WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY)'
[{"latest_export":"2026-09-09 09:15:22.410000 UTC","lag_hours":"3"}]
# PASS if lag_hours < 24. A value > 48 means the export is broken.

# 2. Every active project is inside the expected billing account.
$ gcloud beta billing projects list --billing-account=01A2B3-C4D5E6-F7G8H9 \
    --format="table(projectId, billingEnabled)"
PROJECT_ID          BILLING_ENABLED
checkout-prd-01     True
checkout-prd-02     True
analytics-prd-01    True
eng-sandbox-01      True
fin-billing-prd-01  True

# 3. Every project has at least one budget covering it.
$ gcloud billing budgets list --billing-account=01A2B3-C4D5E6-F7G8H9 \
    --format="table(displayName, amount.specifiedAmount.units, budgetFilter.projects)"
DISPLAY_NAME              UNITS   PROJECTS
budget-cc-4417-monthly    120000  ['projects/847100294411', 'projects/847100294412']
budget-cc-2201-monthly    45000   ['projects/311882004417']
budget-cc-9002-monthly    6000    ['projects/990022114455']
budget-org-catch-all              []

# 4. The budgets service agent can actually publish to the topic.
$ gcloud pubsub topics get-iam-policy cloud-billing-budget-alerts \
    --project=fin-billing-prd-01
bindings:
- members:
  - serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com
  role: roles/pubsub.publisher
etag: BwYb3D2yQ5w=

# 5. Cost-control org policies are effective at the folder.
$ for C in gcp.resourceLocations compute.vmExternalIpAccess gcp.restrictServiceUsage; do
    echo "== $C"
    gcloud org-policies describe "$C" --folder=554433221100 --effective \
      --format="yaml(spec.rules)" 2>&1 | head -8
  done
== gcp.resourceLocations
spec:
  rules:
  - values:
      allowedValues:
      - in:us-central1-locations
      - in:us-east1-locations
      - in:us-locations
== compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
== gcp.restrictServiceUsage
spec:
  rules:
  - values:
      allowedValues:
      - services/compute.googleapis.com

# 6. Label coverage as a percentage of spend. This is THE attribution KPI.
$ bq query --use_legacy_sql=false \
'SELECT
   ROUND(100 * SAFE_DIVIDE(
     SUM(IF((SELECT value FROM UNNEST(labels) WHERE key="cost-center") IS NOT NULL, cost, 0)),
     NULLIF(SUM(cost),0)), 2) AS pct_spend_attributed
 FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
 WHERE invoice.month = FORMAT_DATE("%Y%m", DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH))
   AND cost_type = "regular"'
+----------------------+
| pct_spend_attributed |
+----------------------+
|                88.41 |
+----------------------+
# Target > 95%. 88% means ~12% of the invoice has no owner.
```

### 9.2 Failure diagnosis runbook

| Symptom | Likely cause | Diagnostic | Fix |
|---|---|---|---|
| Budget alert never fired despite obvious overspend | Budgets service agent lacks `roles/pubsub.publisher` on the topic (Terraform-created budgets do not get this binding automatically) | `gcloud pubsub topics get-iam-policy <topic>` | Add `serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com` as publisher |
| Budget alert fired but nobody received email | `disable_default_iam_recipients: true` with no Monitoring channel attached, or the channel is unverified | `gcloud billing budgets describe <id> --format="yaml(notificationsRule)"` | Attach and verify a Monitoring notification channel |
| Budget shows far less spend than the invoice | `budget_filter` excludes projects/services, or `credit_types_treatment` mismatch, or the filter's single label key excludes unlabeled resources | Compare budget filter vs the Cost Table for the same period | Widen the filter; keep one unfiltered catch-all budget always |
| BigQuery export tables missing rows for last week | Export was disabled/reconfigured; or you queried without partition pruning and hit `_PARTITIONTIME` on a re-created table | `SELECT DATE(_PARTITIONTIME), COUNT(*) ... GROUP BY 1 ORDER BY 1` | Re-enable export; note it cannot backfill |
| Daily cost totals keep changing for past days | Normal — adjustments and restatements land for weeks | Group by `invoice.month`; check `adjustment_info` | Report finalized figures on `invoice.month`, not rolling daily |
| Reported spend is ~30% higher than the invoice | Summing `cost` without adding `credits` | Compare `SUM(cost)` vs `SUM(cost)+SUM(credits.amount)` | Always compute effective cost |
| CUD utilization dropped after a migration | Resource-based CUD is pinned to region + machine family; workload moved | CUD utilization query (§6.2); commitment analysis report | Enable CUD sharing across the billing account; prefer Flexible/spend-based CUDs where shape is volatile |
| Autoscaler stopped adding nodes during an incident | Allocation quota ceiling reached (`CPUS`, `IN_USE_ADDRESSES`, `SSD_TOTAL_GB`) | `gcloud compute regions describe <region>` — compare usage vs limit | Raise the quota; re-derive prod quota as peak × failover × headroom |
| `RESOURCE_EXHAUSTED` on BigQuery queries after hours | Custom daily `QueryUsagePerDay` quota exhausted by a runaway scheduled query | `gcloud alpha services quota list --service=bigquery.googleapis.com --consumer=projects/<id>` | Fix the query (partition filter); consider moving to Editions for bounded cost without hard denial |
| Storage bill grows while object count is flat | Noncurrent versions, incomplete multipart uploads, or soft-delete retention | `gcloud storage ls -a gs://bucket/**` vs `gcloud storage ls gs://bucket/**`; Storage Insights | Add `numNewerVersions` / `daysSinceNoncurrentTime` / `AbortIncompleteMultipartUpload` lifecycle rules |
| Cloud Run bill nonzero at zero traffic | `--min-instances > 0` or CPU always-allocated | `gcloud run services describe <svc> --format="yaml(spec.template.metadata.annotations)"` | Set `--min-instances=0` where cold start is acceptable; use request-scoped CPU |
| Large unattributed egress line item | Cross-region/cross-zone chatter or internet egress with no owning label | Egress query (§8.4) against the **detailed** export | Co-locate, add Cloud CDN, evaluate Standard tier, add Interconnect above a few TB/mo |
| A project disappeared / VMs terminated after a budget alert | The kill-switch function ran outside dry-run against a non-allowlisted project | `gcloud functions logs read budget-killswitch --gen2` | Re-link billing immediately: `gcloud beta billing projects link <p> --billing-account=<ba>`; restore data from snapshots; tighten the allowlist |

Emergency re-link after an accidental unlink:

```bash
$ gcloud beta billing projects link eng-sandbox-01 \
    --billing-account=01A2B3-C4D5E6-F7G8H9
billingAccountName: billingAccounts/01A2B3-C4D5E6-F7G8H9
billingEnabled: true
name: projects/eng-sandbox-01/billingInfo
projectId: eng-sandbox-01
```

Relinking restores the project's ability to run resources; it does **not** restore data already deleted. This is precisely why the kill switch defaults to dry-run and is allowlisted to non-production.

### 9.3 Cost anomaly detection you own

Budgets detect *thresholds*. They do not detect *shape changes* — a new SKU appearing, or a service tripling week-over-week while staying under budget. Add this:

```sql
-- Week-over-week SKU-level anomaly detector.
-- Run daily via a scheduled query; publish results to Pub/Sub / Monitoring.
WITH daily AS (
  SELECT
    DATE(usage_start_time) AS d,
    project.id             AS project_id,
    service.description    AS service,
    sku.description        AS sku,
    SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS eff_cost
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 35 DAY)
    AND cost_type = 'regular'
  GROUP BY d, project_id, service, sku
),
stats AS (
  SELECT
    project_id, service, sku,
    AVG(IF(d BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 28 DAY)
                 AND DATE_SUB(CURRENT_DATE(), INTERVAL 8 DAY), eff_cost, NULL))    AS baseline_mean,
    STDDEV(IF(d BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 28 DAY)
                    AND DATE_SUB(CURRENT_DATE(), INTERVAL 8 DAY), eff_cost, NULL)) AS baseline_stddev,
    AVG(IF(d >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY), eff_cost, NULL))         AS recent_mean
  FROM daily
  GROUP BY project_id, service, sku
)
SELECT
  project_id, service, sku,
  ROUND(baseline_mean, 2) AS baseline_daily_usd,
  ROUND(recent_mean, 2)   AS recent_daily_usd,
  ROUND(recent_mean - IFNULL(baseline_mean, 0), 2) AS delta_daily_usd,
  ROUND(SAFE_DIVIDE(recent_mean - baseline_mean, NULLIF(baseline_stddev, 0)), 2) AS z_score,
  CASE
    WHEN baseline_mean IS NULL AND recent_mean > 50 THEN 'NEW_SKU'
    WHEN SAFE_DIVIDE(recent_mean - baseline_mean, NULLIF(baseline_stddev,0)) > 3 THEN 'SPIKE'
    ELSE 'OK'
  END AS verdict
FROM stats
WHERE recent_mean > 50
  AND (baseline_mean IS NULL
       OR SAFE_DIVIDE(recent_mean - baseline_mean, NULLIF(baseline_stddev, 0)) > 3)
ORDER BY delta_daily_usd DESC;
```

```
+------------------+----------------+-------------------------------------------+--------------------+------------------+-----------------+---------+----------+
|    project_id    |    service     |                    sku                    | baseline_daily_usd | recent_daily_usd | delta_daily_usd | z_score | verdict  |
+------------------+----------------+-------------------------------------------+--------------------+------------------+-----------------+---------+----------+
| analytics-prd-01 | BigQuery       | Analysis (on-demand)                      |             311.40 |          1204.88 |          893.48 |    9.71 | SPIKE    |
| checkout-prd-01  | Networking     | Network Internet Egress Americas to China |               NULL |           496.10 |          496.10 |    NULL | NEW_SKU  |
| ml-platform-01   | Compute Engine | Nvidia L4 GPU attached to Spot VMs        |              22.10 |           388.02 |          365.92 |   14.02 | SPIKE    |
+------------------+----------------+-------------------------------------------+--------------------+------------------+-----------------+---------+----------+
```

The `NEW_SKU` row is the one budgets structurally cannot catch: a brand-new $496/day line that will not trip a monthly threshold until the second half of the month.

---

## 10. Pre-deployment: the Pricing Calculator and TCO

Cost control begins before any resource exists. The **Google Cloud Pricing Calculator** produces a shareable, versioned estimate for a proposed architecture; the **Total Cost of Ownership** framing is what the CDL exam expects you to articulate to a business stakeholder.

The business-level argument in the terms the exam uses:

| On-premises | Google Cloud |
|---|---|
| **Capex** — buy capacity up front, depreciate over 3–5 years | **Opex** — pay for consumption, monthly |
| Provision for peak + growth + failure → chronic over-provisioning | Provision for current demand, autoscale to peak |
| Idle capacity is sunk cost | Idle capacity can be released the same hour |
| TCO includes power, cooling, floorspace, hardware refresh, staff | TCO includes consumption, support, egress, and engineering effort |
| Cost of a failed experiment: a purchase order | Cost of a failed experiment: hours of runtime |

The corollary that matters technically: **elasticity converts a capacity problem into a cost-governance problem.** Everything in this topic exists because that conversion moved the control point from procurement to the API.

Practices that belong in design review, before deployment:

1. Model the architecture in the Pricing Calculator and attach the estimate to the design doc.
2. Compare regions — the same shape has materially different prices across regions; check whether latency or data residency actually requires the expensive one.
3. Compare service models: VM vs. GKE vs. Cloud Run vs. a fully managed service. Compute is rarely the biggest line; egress, storage-class mistakes, and idle managed instances usually are.
4. Identify the **committable baseline** and the **elastic fraction** up front; decide the CUD/Spot split in the design, not a year later.
5. Define the **unit economic metric** for the service (cost per 1,000 requests, per active user, per GB ingested). Absolute spend is meaningless without it — spend rising 40% while cost-per-request drops 15% is a successful quarter.

```sql
-- Unit economics: effective infrastructure cost per 1,000 requests.
-- Join billing export against a Cloud Monitoring-derived request-count table.
SELECT
  b.d AS day,
  ROUND(b.eff_cost, 2)                                       AS infra_cost_usd,
  r.request_count,
  ROUND(1000 * SAFE_DIVIDE(b.eff_cost, r.request_count), 4)  AS usd_per_1k_requests
FROM (
  SELECT DATE(usage_start_time) AS d,
         SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS eff_cost
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
    AND cost_type = 'regular'
    AND EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key='service' AND value='checkout-api')
  GROUP BY d
) b
JOIN `fin-billing-prd-01.slo.checkout_api_daily_requests` r ON r.d = b.d
ORDER BY day DESC
LIMIT 30;
```

---

## 11. Exam-focused synthesis

What the Cloud Digital Leader exam expects you to recognize for objective 6.1:

**Google Cloud's cost-control capabilities, by name:**

- **Resource hierarchy** (Organization → Folders → Projects) — the structure that makes cost attributable and policy inheritable.
- **Cloud Billing accounts** — self-serve vs. invoiced; one billing account funds many projects; a project has exactly one billing account. **Billing subaccounts** provide separate invoices under a parent (the reseller/BU-isolation pattern).
- **Billing IAM roles** — Billing Account Administrator, User, Viewer, Costs Manager, Project Billing Manager; project ownership does not confer cost visibility.
- **Budgets and alerts** — thresholds on current *or forecasted* spend; email, Cloud Monitoring channels, and **Pub/Sub** for programmatic response. **Budgets alert; they do not cap.**
- **Quotas** — rate and allocation quotas; the hard, synchronous limit on consumption.
- **Organization Policy constraints** — preventive guardrails (allowed regions, no external IPs, allowed services, custom machine-type constraints).
- **Labels** — the attribution primitive enabling showback and chargeback.
- **Cloud Billing reports, Cost Table, Cost Breakdown** — console analysis surfaces.
- **Billing export to BigQuery** — the programmable, authoritative cost dataset.
- **Pricing Calculator** — pre-deployment estimation.
- **Recommender / Active Assist and the FinOps Hub** — automated identification of idle and over-provisioned resources and of commitment opportunities.
- **Discounts** — Sustained Use Discounts (automatic), Committed Use Discounts (1y/3y, resource-based or spend-based/flexible), **Spot VMs**, and the **free tier**.
- **Per-second billing** with a one-minute minimum on Compute Engine, and **custom machine types** — pay for the shape you need, not the shape on the price list.

**The four sentences to be able to say without hesitating:**

1. Google Cloud has **no hard spending cap**; budgets are detection, quotas and Organization Policy are prevention, and unlinking billing is the destructive last resort.
2. Attribution (**hierarchy + labels**) must be designed before workloads deploy, because billing data is **not retroactively re-attributable**.
3. Discounts are layered: **SUD is automatic and free**, **CUD trades flexibility for 28–70% off a committed baseline**, and **Spot trades availability for 60–91% off elastic capacity**.
4. Cost is a **shared engineering responsibility with a hierarchy of enforcement points**, not a monthly finance report — which is exactly why Google Cloud exposes it through IAM, policy, quota and API surfaces rather than only through an invoice.

---

## 12. References

**Primary exam source**

- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Resource hierarchy, IAM and governance**

- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Cloud Billing access control (IAM roles) — https://cloud.google.com/billing/docs/how-to/billing-access
- Organization Policy Service overview — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints reference — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Custom organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints
- Creating and managing labels — https://cloud.google.com/resource-manager/docs/creating-managing-labels
- Tags overview — https://cloud.google.com/resource-manager/docs/tags/tags-overview

**Billing, budgets and export**

- Cloud Billing documentation — https://cloud.google.com/billing/docs
- Create, edit, or delete budgets and budget alerts — https://cloud.google.com/billing/docs/how-to/budgets
- Manage programmatic budget alert notifications — https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
- Manage cost or stop usage by disabling Cloud Billing — https://cloud.google.com/billing/docs/how-to/notify
- Export Cloud Billing data to BigQuery — https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- BigQuery billing export table schemas — https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables
- Cloud Billing reports — https://cloud.google.com/billing/docs/how-to/reports
- Cost table report — https://cloud.google.com/billing/docs/how-to/cost-table
- Cost breakdown report — https://cloud.google.com/billing/docs/how-to/cost-breakdown
- FinOps hub — https://cloud.google.com/billing/docs/how-to/finops-hub
- Cloud Billing Budget API — https://cloud.google.com/billing/docs/reference/budget/rest

**Quotas**

- Working with quotas — https://cloud.google.com/docs/quotas/overview
- View and manage quotas — https://cloud.google.com/docs/quotas/view-manage
- Compute Engine resource quotas — https://cloud.google.com/compute/resource-usage
- BigQuery custom cost controls — https://cloud.google.com/bigquery/docs/custom-quotas

**Pricing, discounts and commitments**

- Google Cloud Pricing Calculator — https://cloud.google.com/products/calculator
- Compute Engine pricing — https://cloud.google.com/compute/all-pricing
- Sustained use discounts — https://cloud.google.com/compute/docs/sustained-use-discounts
- Committed use discounts overview — https://cloud.google.com/docs/cuds
- Resource-based committed use discounts — https://cloud.google.com/compute/docs/instances/signing-up-committed-use-discounts
- Spend-based committed use discounts — https://cloud.google.com/docs/cuds-spend-based
- Spot VMs — https://cloud.google.com/compute/docs/instances/spot
- Reservations of Compute Engine zonal resources — https://cloud.google.com/compute/docs/instances/reservations-overview
- Google Cloud free program — https://cloud.google.com/free/docs/free-cloud-features

**Optimization / Active Assist**

- Recommender overview — https://cloud.google.com/recommender/docs/overview
- Recommenders reference — https://cloud.google.com/recommender/docs/recommenders
- Export recommendations to BigQuery — https://cloud.google.com/recommender/docs/bq-export/export-recommendations-to-bq

**Service-specific cost control**

- BigQuery pricing — https://cloud.google.com/bigquery/pricing
- BigQuery editions and reservations — https://cloud.google.com/bigquery/docs/reservations-intro
- Control BigQuery costs — https://cloud.google.com/bigquery/docs/best-practices-costs
- Cloud Storage classes — https://cloud.google.com/storage/docs/storage-classes
- Object Lifecycle Management — https://cloud.google.com/storage/docs/lifecycle
- Autoclass — https://cloud.google.com/storage/docs/autoclass
- GKE cost optimization best practices — https://cloud.google.com/kubernetes-engine/docs/best-practices/cost-optimization
- GKE cost allocation — https://cloud.google.com/kubernetes-engine/docs/how-to/cost-allocations
- GKE Autopilot pricing — https://cloud.google.com/kubernetes-engine/pricing
- Cloud Run pricing — https://cloud.google.com/run/pricing
- All Google Cloud network pricing — https://cloud.google.com/vpc/network-pricing
- Network Service Tiers — https://cloud.google.com/network-tiers/docs/overview