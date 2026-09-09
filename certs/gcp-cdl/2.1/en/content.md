# 2.1 — The Intrinsic Role of Data in an Organization's Digital Transformation

**Certification:** Google Cloud Digital Leader (CDL) · Exam version 2026-08-12
**Domain 2:** Exploring data transformation with Google Cloud · **Objective weight:** 6.0
**Profile of this material:** Principal Platform Architect / Senior SRE. The exam asks you to *describe* the role of data; this document makes you able to *operate* it, because the vocabulary the exam tests (silos, governance, lifecycle, data-driven decisions) only becomes unambiguous once you have seen the systems that implement it.

---

## 0. What "intrinsic" means, operationally

The exam guide's verb is *describe*, and the word doing the work is **intrinsic**. It is not decoration. It draws a hard line between two organizational postures:

| Posture | Data is… | Symptom in the org chart | Symptom in production |
|---|---|---|---|
| **Extrinsic (pre-transformation)** | A byproduct of applications; exhaust | "Reporting" is a team downstream of Engineering | Every dashboard is a hand-built export; nobody owns freshness |
| **Intrinsic (transformed)** | A first-class product with owners, contracts, SLOs and a lifecycle | Data ownership sits *with* the producing domain team | A dataset has an SLO, an error budget, a lineage graph and a paging rotation |

The intrinsic posture is the entire content of this objective. Digital transformation is not "move VMs to the cloud"; that is migration. Transformation is the point at which **decisions that used to be made from intuition and quarterly reports become made from measured, governed, timely data** — and, at the top of the value chain, made *by* systems (ML/AI) rather than about them.

Google frames this as a value ladder. Memorize the ladder; the exam tests its ordering:

```
                                       ┌────────────────────────────┐
    value / differentiation            │  5. AI / ML  (predictive,  │
            ▲                          │     generative, agentic)   │
            │                          ├────────────────────────────┤
            │                          │  4. Activation             │
            │                          │     (decisions, products,  │
            │                          │      reverse ETL, sharing) │
            │                          ├────────────────────────────┤
            │                          │  3. Analysis / BI          │
            │                          │     (why did it happen?)   │
            │                          ├────────────────────────────┤
            │                          │  2. Processing / Transform │
            │                          │     (clean, join, model)   │
            │                          ├────────────────────────────┤
            │                          │  1. Storage (durable,      │
            │                          │     governed, queryable)   │
            │                          ├────────────────────────────┤
            └──────────────────────────│  0. Ingestion / Collection │
                                       └────────────────────────────┘
```

**Exam trap #1:** You cannot skip rungs. An organization asking for "AI" while its customer identifier is spelled four different ways across four systems is not blocked on models; it is blocked on rung 1. The Google-canonical phrasing of this is: *there is no AI strategy without a data strategy.*

---

## 1. The production architecture problem

### 1.1 The silo topology, stated precisely

A **data silo** is not "data in different places" — distribution is normal and desirable. A silo is a dataset whose **access, schema and semantics are controlled by a single team as an implementation detail of its application**, such that no other consumer can obtain it without a human negotiation.

Silos are cheap to create and expensive to keep. Their cost is combinatorial:

```
Point-to-point integrations between N silos:  N(N-1)/2
        N = 6  →  15 pipelines
        N = 12 →  66 pipelines
        N = 20 → 190 pipelines
```

Each of those pipelines is an independent copy with its own latency, its own transformation logic, its own failure mode, and — critically — its own **version of the truth**. This is the concrete production problem behind the exam bullet "data silos".

Real, observable failure modes of the silo topology:

| Failure mode | What the business sees | What SRE sees |
|---|---|---|
| **Semantic drift** | Finance reports 41,882 active customers; Marketing reports 44,150 | Two `active` definitions (30-day vs 90-day window), neither written down |
| **Freshness ambiguity** | A decision made on Monday used Friday's data | No `_ingested_at` column, no freshness SLI, no alert |
| **Silent partial load** | Revenue "dropped 12%" overnight | One of 14 shards failed; the pipeline exited 0 because failures were piped through `tee` |
| **Duplicate ingestion** | Order count inflated 1.8× | At-least-once delivery without an idempotency key |
| **Schema drift** | A column of `NULL` appears in a dashboard | Upstream renamed `cust_id` → `customer_id`; no contract, no test |
| **Ungoverned copy sprawl** | A GDPR/PII incident from an analyst's personal export | No column-level policy tags; `SELECT *` was permitted |
| **Unbounded cost** | Query bill 6× budget in a month | Unpartitioned table, `SELECT *`, no `maximum_bytes_billed` |

**Exam trap #2:** Silos are an *organizational* problem with a technical surface. Consolidating storage into one lake without also consolidating **ownership, definitions and access policy** just produces a larger silo — sometimes called a *data swamp*.

### 1.2 The counter-architecture: data as a product with SLOs

The SRE move is to stop treating a dataset as a file and start treating it as a **service with a contract**. A dataset that matters gets four SLIs. Below is the standard set, with the exact BigQuery SQL used to measure each (these are the queries you will wire into alerting in §3.5 and §5).

| SLI | Question it answers | Measurement | Typical SLO |
|---|---|---|---|
| **Freshness** | Is the newest record recent enough to decide on? | `TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(_ingested_at), MINUTE)` | p99 ≤ 15 min (streaming) / ≤ 3 h (daily batch) |
| **Completeness** | Did *all* the source rows arrive? | `count(target) / count(source)` per partition | ≥ 99.9 % per partition |
| **Correctness / validity** | Do the rows obey the contract? | Dataplex data-quality scan pass rate | ≥ 99.5 % of rules pass |
| **Availability** | Can consumers query it right now? | Successful query ratio from `INFORMATION_SCHEMA.JOBS` | ≥ 99.9 % |

Error budget arithmetic, worked (this is what makes the SLO enforceable rather than aspirational):

```
Freshness SLO       : 99.5 % of 5-minute windows within 15 min, over 28 days
Windows in 28 days  : 28 × 24 × 12 = 8,064
Error budget        : 8,064 × 0.005 = 40.32 windows ≈ 3 h 21 min of staleness / 28 d
Fast-burn alert     : > 2 % of the 28-day budget consumed in 1 h  → page
Slow-burn alert     : > 5 % consumed in 6 h                        → ticket
```

**This is the operational definition of "data-driven".** An organization is data-driven when its decision-support datasets carry error budgets that someone is on the hook for. Everything else is a dashboard.

### 1.3 Reference architecture on Google Cloud

```
   SOURCES                 INGEST                 STORE / GOVERN            PROCESS            ACTIVATE
 ┌──────────┐      ┌──────────────────────┐   ┌───────────────────────┐  ┌────────────┐   ┌──────────────┐
 │ OLTP DBs │─CDC─▶│ Datastream           │──▶│                       │  │ Dataform   │   │ Looker /     │
 │ (MySQL,  │      │ Database Migration   │   │  Cloud Storage        │  │ (ELT, SQL) │──▶│ Looker Studio│
 │  Oracle, │      │  Service             │   │   RAW zone (Autoclass)│  └────────────┘   ├──────────────┤
 │  Postgres│      ├──────────────────────┤   │         │             │  ┌────────────┐   │ BigQuery ML /│
 ├──────────┤      │ Pub/Sub              │   │         ▼             │  │ Dataflow   │──▶│ Vertex AI    │
 │ Apps,    │─────▶│  └ BigQuery direct   │──▶│  BigQuery             │  │ (Beam,     │   ├──────────────┤
 │ clicks,  │      │    subscription      │   │   raw → curated →     │  │ streaming) │   │ BigQuery     │
 │ IoT      │      ├──────────────────────┤   │   consumption datasets│  └────────────┘   │ sharing      │
 ├──────────┤      │ Storage Transfer Svc │   │         ▲             │  ┌────────────┐   │ (Analytics   │
 │ SaaS     │─────▶│ BQ Data Transfer Svc │──▶│  BigLake / object     │  │ Dataproc   │──▶│  Hub)        │
 │ (Ads, CRM│      ├──────────────────────┤   │  tables (unstructured)│  │ (Spark)    │   ├──────────────┤
 ├──────────┤      │ Transfer Appliance    │  │                       │  └────────────┘   │ Reverse ETL  │
 │ On-prem  │─────▶│ (petabyte, offline)  │──▶│  ══ Dataplex Universal│                   │ → operational│
 │ archives │      └──────────────────────┘   │     Catalog ══        │                   │   systems    │
 └──────────┘                                 │  metadata · lineage · │                   └──────────────┘
                                              │  quality · policy tags│
      ORCHESTRATION: Cloud Composer (Airflow)  └───────────────────────┘
      OBSERVABILITY: Cloud Monitoring / Logging · SLOs · error budgets
      SECURITY:      IAM · VPC Service Controls · CMEK · policy tags · row-level policies · data masking
```

Two properties of this diagram are the whole point of the objective:

1. **Storage and compute are decoupled.** Data is stored once and read by many engines (BigQuery SQL, Spark on Dataproc, Beam on Dataflow, Vertex AI training). This is what makes the *same* governed copy serve BI and ML — the structural cure for silos.
2. **Governance is a horizontal plane, not a per-pipeline afterthought.** Dataplex Universal Catalog attaches metadata, lineage, quality and policy to the data wherever it lives, so a new consumer discovers and trusts a dataset without contacting its owner.

### 1.4 The zone model (why RAW / CURATED / CONSUMPTION)

| Zone | Contents | Mutability | Typical storage | Who reads it |
|---|---|---|---|---|
| **RAW** | Byte-faithful landing of the source, append-only, no business logic | Immutable | GCS (Autoclass) + external/BigLake tables | Pipelines only |
| **CURATED** | Deduplicated, typed, conformed keys, PII tagged | Rebuildable from RAW | BigQuery, partitioned + clustered | Data engineers, ML |
| **CONSUMPTION** | Business-defined marts, one agreed definition per metric | Rebuildable from CURATED | BigQuery views / materialized views | Analysts, Looker, external partners |

The invariant: **RAW is never edited, and every downstream zone is reproducible by replay.** That single rule is what converts a data incident from an archaeology project into a re-run. It is also the answer to the exam's "data quality" bullet: quality is enforced at zone boundaries, not at the dashboard.

---

## 2. Technical comparisons and trade-offs

### 2.1 Data types → storage service (exam-critical mapping)

| Type | Definition | Examples | Google Cloud landing service | Query surface |
|---|---|---|---|---|
| **Structured** | Fixed schema, tabular, relational | Transactions, ledger, inventory | Cloud SQL / AlloyDB / Spanner (OLTP), **BigQuery** (OLAP) | SQL |
| **Semi-structured** | Self-describing, flexible schema | JSON, Avro, Parquet, XML, logs, Firestore documents | Cloud Storage, **BigQuery** (`JSON` type), Firestore, Bigtable | SQL / `JSON_VALUE` / NoSQL API |
| **Unstructured** | No inherent schema | Images, video, audio, PDFs, free text | **Cloud Storage**, surfaced as BigQuery **object tables** (BigLake) | Object metadata + ML inference in SQL |

**Exam trap #3:** Roughly 80–90 % of enterprise data is unstructured, and it was historically unusable for analytics. The transformation-relevant point is that object tables + BigQuery ML/Vertex AI let you run inference over images and documents *from SQL*, bringing rung 5 to data that never left rung 0. Know that unstructured data is the majority and that Cloud Storage is its home.

### 2.2 Data warehouse vs data lake vs lakehouse

| Dimension | Data warehouse | Data lake | Lakehouse (BigQuery + BigLake + Dataplex) |
|---|---|---|---|
| Schema | On write | On read | On read, **governed** by catalog |
| Data types | Structured | All | All |
| Primary users | Analysts | Data engineers, scientists | Both |
| Cost per TB stored | Highest | Lowest | Low (GCS) + BigQuery long-term storage tier |
| Governance | Strong, mature | Weak by default → **swamp risk** | Uniform via Dataplex policies |
| Query performance | Excellent | Poor without curation | Excellent on managed tables, good on BigLake |
| Failure mode | Rigid; slow to onboard new sources | Unqueryable, untrusted, orphaned | Governance debt if catalog is not fed |
| Google product | BigQuery | Cloud Storage | BigQuery + BigLake + Dataplex Universal Catalog |

**Trade-off, stated honestly:** the lakehouse does not remove the warehouse's discipline requirement, it *relocates* it — from schema-on-write to catalog-and-contract enforcement. If you deploy a lake and no catalog, you have chosen the swamp.

### 2.3 ETL vs ELT vs federated (zero-copy)

| | ETL | ELT | Federated / zero-copy |
|---|---|---|---|
| Transform runs | In a middle tier (Dataflow, Dataproc) | In the warehouse (BigQuery SQL, Dataform) | Nowhere — query hits the source |
| Raw data retained? | Often not | **Yes** (replayable) | N/A |
| Cost driver | Pipeline compute | Query slots / bytes scanned | Source system load |
| Schema-change blast radius | Pipeline breaks | Only downstream models break | Query breaks |
| Best for | Heavy PII redaction before landing; complex non-SQL logic | Default on BigQuery: cheap storage, elastic compute | Ad-hoc joins, avoiding a copy, low-volume dimension tables |
| Google products | Dataflow, Dataproc, Data Fusion | Dataform, BigQuery scheduled queries, dbt | BigQuery federated queries, BigLake, external tables |
| Main risk | Lost fidelity — you cannot re-derive what you did not keep | Warehouse cost sprawl; unmanaged SQL | Source OLTP degradation from analytic queries |

**Default recommendation on Google Cloud: ELT**, with ETL reserved for pre-landing redaction of regulated fields. Reason: storage is the cheap resource and replayability is the expensive property to lose.

### 2.4 Batch vs micro-batch vs streaming

| | Batch | Micro-batch | Streaming |
|---|---|---|---|
| Latency | Hours–days | 1–15 min | Sub-second – seconds |
| Cost per event | Lowest | Low | Highest (always-on workers) |
| Correction model | Full reprocess (easy) | Reprocess window | Late data / watermarks / windows (hard) |
| Exactly-once | Trivial (idempotent overwrite) | Achievable | Requires dedup keys + Dataflow exactly-once |
| Products | BQ Data Transfer, Storage Transfer, Composer + `bq load` | Scheduled Dataflow, 5-min Dataform | Pub/Sub → BigQuery subscription, Dataflow streaming |
| Choose when | Decision cadence is daily (finance close, monthly churn model) | Ops dashboards | Fraud, personalization, IoT alarms, dynamic pricing |

**Exam trap #4:** Streaming is not "better". Choose the cheapest latency that changes a decision. If nobody acts inside an hour, sub-second ingestion buys nothing and costs continuously. The exam rewards *business-value* reasoning here, not throughput reasoning.

### 2.5 Centralized platform vs data mesh

| | Centralized platform team | Data mesh (domain-owned data products) |
|---|---|---|
| Ownership | One platform team owns all pipelines | Producing domain owns its data product |
| Bottleneck | The platform team's backlog | Governance consistency across domains |
| Time-to-onboard a source | Weeks (queue) | Days (self-serve) |
| Consistency of definitions | High by construction | Requires **federated computational governance** |
| Prerequisite | Small number of domains | A real self-serve platform + enforced global standards |
| GCP implementation | One project, one BigQuery estate | Per-domain projects; Dataplex lakes span them; BigQuery sharing publishes products |

**Honest trade-off:** a mesh without a paved road is silos with better branding. Adopt mesh only when the platform can hand a domain team a templated, governed, observable data product in a single `terraform apply` — which is precisely what §3 builds.

### 2.6 Ingestion path decision table

| Source | Volume / latency | Service | Note |
|---|---|---|---|
| Operational RDBMS, need near-real-time | GB/day, seconds | **Datastream** (CDC) → BigQuery | Serverless, no agents on source |
| One-time DB migration | Any | **Database Migration Service** | Minimal-downtime cutover |
| Events, telemetry, clickstream | Millions/s | **Pub/Sub** → BigQuery subscription or Dataflow | Global, at-least-once |
| SaaS (Google Ads, YouTube, S3, Redshift…) | Scheduled | **BigQuery Data Transfer Service** | Managed connectors |
| On-prem/other-cloud object data, online | TB, hours | **Storage Transfer Service** | Incremental, scheduled |
| On-prem archives, no bandwidth | 100 TB–PB | **Transfer Appliance** | Physical shipment |
| Visual, low-code pipelines | Any | **Cloud Data Fusion** | CDAP-based, for non-coders |

### 2.7 Governance controls (they are not interchangeable)

| Control | Granularity | Enforces | Product surface |
|---|---|---|---|
| IAM | Project / dataset / table | Who may read at all | IAM roles, `google_bigquery_dataset_iam_member` |
| **Policy tags** (taxonomy) | **Column** | Who may read `email`, `ssn` | BigQuery column-level security |
| **Data masking** | Column value | *What* they see (hash / null / default) | BigQuery data policies |
| **Row-level access policy** | Row | Which subset (e.g. own region) | `CREATE ROW ACCESS POLICY` |
| **VPC Service Controls** | Perimeter | Exfiltration to outside the perimeter | Access Context Manager |
| **CMEK** | Key | Cryptographic control / key revocation | Cloud KMS |
| **Data residency** | Location | Where bytes may live | Dataset/bucket location, Org Policy |

**Exam trap #5:** Governance is not only restriction. Its transformation value is *enabling* access — a governed dataset can be opened to the whole company because the sensitive columns are provably protected. Ungoverned data must be locked to a few people, which is precisely what re-creates silos.

---

## 3. Infrastructure as code — complete, unabridged

The following four artifacts stand up one governed domain data product end-to-end: landing bucket, three BigQuery zones, streaming ingestion with a schema contract, a Dataplex lake with quality scanning, column-level PII protection, a zero-copy share, and a freshness SLO with alerting.

### 3.1 `terraform/main.tf` — platform foundation

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.20"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "Project hosting the orders data product."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "bq_location" {
  type        = string
  default     = "US"
  description = "BigQuery multi-region. Must contain var.region for co-location."
}

variable "domain" {
  type        = string
  default     = "orders"
  description = "Owning business domain; used as the data-product name."
}

locals {
  labels = {
    domain          = var.domain
    data_product    = "${var.domain}-events"
    owner           = "data-platform"
    cost_center     = "eng-1042"
    data_class      = "internal"
    managed_by      = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Required APIs
# ---------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "bigquerydatapolicy.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "dataplex.googleapis.com",
    "datacatalog.googleapis.com",
    "datalineage.googleapis.com",
    "dataform.googleapis.com",
    "analyticshub.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# RAW zone: object storage, immutable landing
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-${var.domain}-raw"
  location                    = var.bq_location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  # Storage cost follows access pattern automatically; no lifecycle guesswork.
  autoclass {
    enabled                = true
    terminal_storage_class = "ARCHIVE"
  }

  versioning {
    enabled = true
  }

  # Recover from an accidental delete without restoring from backup.
  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# BigQuery zones
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "raw" {
  dataset_id                      = "${var.domain}_raw"
  friendly_name                   = "${var.domain} — RAW (append-only)"
  description                     = "Byte-faithful landing. Never edited. Source of replay."
  location                        = var.bq_location
  default_partition_expiration_ms = 7776000000 # 90 days
  labels                          = local.labels
  depends_on                      = [google_project_service.apis]
}

resource "google_bigquery_dataset" "curated" {
  dataset_id    = "${var.domain}_curated"
  friendly_name = "${var.domain} — CURATED"
  description   = "Deduplicated, typed, conformed keys, PII tagged. Rebuildable from RAW."
  location      = var.bq_location
  labels        = local.labels
  depends_on    = [google_project_service.apis]
}

resource "google_bigquery_dataset" "consumption" {
  dataset_id    = "${var.domain}_consumption"
  friendly_name = "${var.domain} — CONSUMPTION"
  description   = "Business-agreed metrics. One definition per metric. Read by Looker and partners."
  location      = var.bq_location
  labels        = local.labels
  depends_on    = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Column-level security: taxonomy + policy tags
# ---------------------------------------------------------------------------
resource "google_data_catalog_taxonomy" "pii" {
  region                 = var.region
  display_name           = "pii-classification-${var.domain}"
  description            = "Sensitivity classes applied as BigQuery column policy tags."
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
  depends_on             = [google_project_service.apis]
}

resource "google_data_catalog_policy_tag" "pii_high" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "pii-high"
  description  = "Direct identifiers: email, phone, government ID. Masked by default."
}

resource "google_data_catalog_policy_tag" "pii_low" {
  taxonomy          = google_data_catalog_taxonomy.pii.id
  parent_policy_tag = google_data_catalog_policy_tag.pii_high.id
  display_name      = "pii-low"
  description       = "Quasi-identifiers: postal code, coarse geo."
}

# Masking rule: analysts see a SHA-256 hash, not the raw value.
resource "google_bigquery_datapolicy_data_policy" "email_hash" {
  location         = var.region
  data_policy_id   = "${var.domain}_email_sha256"
  policy_tag       = google_data_catalog_policy_tag.pii_high.name
  data_policy_type = "DATA_MASKING_POLICY"

  data_masking_policy {
    predefined_expression = "SHA256"
  }
  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# CURATED table: partitioned, clustered, contract-carrying
# ---------------------------------------------------------------------------
resource "google_bigquery_table" "orders" {
  dataset_id          = google_bigquery_dataset.curated.dataset_id
  table_id            = "orders"
  deletion_protection = true
  description         = <<-EOT
    DATA PRODUCT: orders.curated.orders
    Owner        : orders-domain@example.com
    SLO          : freshness p99 <= 15 min | completeness >= 99.9% per partition
    Grain        : one row per order_id per event_ts (latest wins in consumption view)
    Replay       : rebuildable from orders_raw.orders_stream
  EOT
  labels              = local.labels

  time_partitioning {
    type                     = "DAY"
    field                    = "event_ts"
    require_partition_filter = true # hard stop against full-table scans
  }

  clustering = ["country_code", "channel"]

  schema = jsonencode([
    {
      name        = "order_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Idempotency key. Unique per order across all sources."
    },
    {
      name        = "customer_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Conformed customer key (golden record)."
    },
    {
      name         = "customer_email"
      type         = "STRING"
      mode         = "NULLABLE"
      description  = "Direct identifier. Masked for non-privileged readers."
      policyTags   = { names = [google_data_catalog_policy_tag.pii_high.name] }
    },
    {
      name        = "country_code"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "ISO 3166-1 alpha-2, uppercase."
    },
    {
      name        = "channel"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "One of: WEB, MOBILE, STORE, PARTNER."
    },
    {
      name        = "gross_amount"
      type        = "NUMERIC"
      mode        = "REQUIRED"
      description = "Order gross value, minor-unit-safe NUMERIC. Never FLOAT64 for money."
    },
    {
      name        = "currency"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "ISO 4217."
    },
    {
      name        = "event_ts"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Business event time (source of truth for partitioning)."
    },
    {
      name        = "ingested_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Platform arrival time. Freshness SLI is computed from this."
    },
    {
      name        = "source_system"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Provenance. Required for lineage and incident scoping."
    }
  ])
}

# ---------------------------------------------------------------------------
# Row-level access: EU analysts see EU rows only
# ---------------------------------------------------------------------------
resource "google_bigquery_job" "row_policy_eu" {
  job_id = "rowpolicy-eu-${var.domain}-001"
  query {
    query = <<-SQL
      CREATE OR REPLACE ROW ACCESS POLICY eu_only
      ON `${var.project_id}.${google_bigquery_dataset.curated.dataset_id}.orders`
      GRANT TO ("group:analysts-eu@example.com")
      FILTER USING (country_code IN ("ES","FR","DE","IT","PT","NL","IE"));
    SQL
    use_legacy_sql = false
  }
  depends_on = [google_bigquery_table.orders]
}
```

### 3.2 `terraform/ingest.tf` — streaming contract (Pub/Sub → BigQuery, no pipeline code)

```hcl
# The schema IS the contract. A producer that violates it is rejected at publish
# time, not discovered three dashboards downstream.
resource "google_pubsub_schema" "order_event" {
  name       = "${var.domain}-event-v1"
  type       = "AVRO"
  definition = jsonencode({
    type      = "record"
    name      = "OrderEvent"
    namespace = "com.example.orders"
    fields = [
      { name = "order_id",       type = "string" },
      { name = "customer_id",    type = "string" },
      { name = "customer_email", type = ["null", "string"], default = null },
      { name = "country_code",   type = "string" },
      { name = "channel",        type = "string" },
      { name = "gross_amount",   type = "string" },
      { name = "currency",       type = "string" },
      { name = "event_ts",       type = { type = "long", logicalType = "timestamp-micros" } },
      { name = "source_system",  type = "string" }
    ]
  })
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "orders" {
  name                       = "${var.domain}-events"
  message_retention_duration = "604800s" # 7 days — the replay window
  labels                     = local.labels

  schema_settings {
    schema   = google_pubsub_schema.order_event.id
    encoding = "JSON"
  }
}

# Dead-letter topic: messages that cannot be written are quarantined, not lost.
resource "google_pubsub_topic" "orders_dlq" {
  name                       = "${var.domain}-events-dlq"
  message_retention_duration = "2592000s" # 30 days
  labels                     = local.labels
}

resource "google_pubsub_subscription" "orders_dlq_pull" {
  name  = "${var.domain}-events-dlq-pull"
  topic = google_pubsub_topic.orders_dlq.id
  ack_deadline_seconds = 60
  labels = local.labels
}

resource "google_bigquery_table" "orders_stream" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "orders_stream"
  deletion_protection = true
  description         = "RAW landing of ${google_pubsub_topic.orders.name}. Append-only."
  labels              = local.labels

  time_partitioning {
    type                     = "DAY"
    field                    = "event_ts"
    require_partition_filter = false # RAW is scanned by replay jobs
  }

  schema = jsonencode([
    { name = "order_id",       type = "STRING",    mode = "REQUIRED" },
    { name = "customer_id",    type = "STRING",    mode = "REQUIRED" },
    { name = "customer_email", type = "STRING",    mode = "NULLABLE" },
    { name = "country_code",   type = "STRING",    mode = "REQUIRED" },
    { name = "channel",        type = "STRING",    mode = "REQUIRED" },
    { name = "gross_amount",   type = "STRING",    mode = "REQUIRED" },
    { name = "currency",       type = "STRING",    mode = "REQUIRED" },
    { name = "event_ts",       type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "source_system",  type = "STRING",    mode = "REQUIRED" }
  ])
}

# Pub/Sub writes straight into BigQuery. No Dataflow job to run, patch or pay for.
resource "google_pubsub_subscription" "orders_to_bq" {
  name  = "${var.domain}-events-to-bq"
  topic = google_pubsub_topic.orders.id
  labels = local.labels

  bigquery_config {
    table            = "${var.project_id}.${google_bigquery_dataset.raw.dataset_id}.${google_bigquery_table.orders_stream.table_id}"
    use_topic_schema = true
    write_metadata   = false
    drop_unknown_fields = false
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.orders_dlq.id
    max_delivery_attempts = 10
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [
    google_bigquery_table.orders_stream,
    google_project_iam_member.pubsub_bq_writer,
  ]
}

data "google_project" "this" {}

# The Pub/Sub service agent must be able to write to the target table.
resource "google_project_iam_member" "pubsub_bq_writer" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "pubsub_bq_metadata" {
  project = var.project_id
  role    = "roles/bigquery.metadataViewer"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
```

### 3.3 `terraform/govern.tf` — Dataplex lake, zones, assets, quality scan, sharing

```hcl
resource "google_dataplex_lake" "domain" {
  name         = "${var.domain}-lake"
  location     = var.region
  display_name = "${title(var.domain)} domain lake"
  description  = "Unified metadata plane over the ${var.domain} data product."
  labels       = local.labels
  depends_on   = [google_project_service.apis]
}

resource "google_dataplex_zone" "raw" {
  name         = "raw-zone"
  location     = var.region
  lake         = google_dataplex_lake.domain.name
  type         = "RAW"
  display_name = "RAW"
  labels       = local.labels

  discovery_spec {
    enabled  = true
    schedule = "0 * * * *" # hourly metadata discovery
  }

  resource_spec {
    location_type = "MULTI_REGION"
  }
}

resource "google_dataplex_zone" "curated" {
  name         = "curated-zone"
  location     = var.region
  lake         = google_dataplex_lake.domain.name
  type         = "CURATED"
  display_name = "CURATED"
  labels       = local.labels

  discovery_spec {
    enabled  = true
    schedule = "0 */4 * * *"
  }

  resource_spec {
    location_type = "MULTI_REGION"
  }
}

resource "google_dataplex_asset" "raw_bucket" {
  name          = "raw-bucket"
  location      = var.region
  lake          = google_dataplex_lake.domain.name
  dataplex_zone = google_dataplex_zone.raw.name
  labels        = local.labels

  discovery_spec {
    enabled = true
  }

  resource_spec {
    name = "projects/${var.project_id}/buckets/${google_storage_bucket.raw.name}"
    type = "STORAGE_BUCKET"
  }
}

resource "google_dataplex_asset" "curated_dataset" {
  name          = "curated-dataset"
  location      = var.region
  lake          = google_dataplex_lake.domain.name
  dataplex_zone = google_dataplex_zone.curated.name
  labels        = local.labels

  discovery_spec {
    enabled = true
  }

  resource_spec {
    name = "projects/${var.project_id}/datasets/${google_bigquery_dataset.curated.dataset_id}"
    type = "BIGQUERY_DATASET"
  }
}

# ---------------------------------------------------------------------------
# Automatic data quality: the correctness SLI, as code
# ---------------------------------------------------------------------------
resource "google_dataplex_datascan" "orders_dq" {
  location     = var.region
  data_scan_id = "${var.domain}-orders-dq"
  display_name = "orders curated — data quality"
  description  = "Enforces the published contract of orders.curated.orders."
  labels       = local.labels

  data {
    resource = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.curated.dataset_id}/tables/orders"
  }

  execution_spec {
    trigger {
      schedule {
        cron = "0 */2 * * *"
      }
    }
    field = "event_ts" # incremental: only scan new partitions
  }

  data_quality_spec {
    sampling_percent = 100
    row_filter       = "event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)"

    post_scan_actions {
      bigquery_export {
        results_table = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.curated.dataset_id}/tables/dq_results"
      }
    }

    rules {
      column      = "order_id"
      dimension   = "COMPLETENESS"
      threshold   = 1.0
      description = "order_id must never be null; it is the idempotency key."
      non_null_expectation {}
    }

    rules {
      column      = "order_id"
      dimension   = "UNIQUENESS"
      threshold   = 1.0
      description = "Duplicate order_id in a partition means at-least-once leaked through."
      uniqueness_expectation {}
    }

    rules {
      column      = "country_code"
      dimension   = "VALIDITY"
      threshold   = 0.999
      description = "ISO 3166-1 alpha-2, uppercase."
      regex_expectation {
        regex = "^[A-Z]{2}$"
      }
    }

    rules {
      column      = "channel"
      dimension   = "VALIDITY"
      threshold   = 1.0
      description = "Closed enumeration agreed with the orders domain."
      set_expectation {
        values = ["WEB", "MOBILE", "STORE", "PARTNER"]
      }
    }

    rules {
      column      = "gross_amount"
      dimension   = "VALIDITY"
      threshold   = 0.9999
      description = "Non-negative and within the fraud-plausible ceiling."
      range_expectation {
        min_value          = "0"
        max_value          = "1000000"
        strict_min_enabled = false
        strict_max_enabled = false
      }
    }

    rules {
      column      = "currency"
      dimension   = "VALIDITY"
      threshold   = 1.0
      description = "Supported settlement currencies only."
      set_expectation {
        values = ["EUR", "USD", "GBP", "ARS", "BRL"]
      }
    }

    rules {
      dimension   = "FRESHNESS"
      threshold   = 1.0
      description = "Freshness SLI as a hard gate: newest ingest under 15 minutes old."
      table_condition_expectation {
        sql_expression = "TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), MINUTE) <= 15"
      }
    }

    rules {
      dimension   = "VOLUME"
      threshold   = 1.0
      description = "Volume floor: a silent partial load looks like a quiet day."
      table_condition_expectation {
        sql_expression = "COUNT(*) > 1000"
      }
    }

    rules {
      column      = "customer_id"
      dimension   = "CONSISTENCY"
      threshold   = 0.995
      description = "Referential integrity against the conformed customer dimension."
      sql_assertion {
        sql_statement = <<-SQL
          SELECT o.customer_id
          FROM `${var.project_id}.${google_bigquery_dataset.curated.dataset_id}.orders` o
          LEFT JOIN `${var.project_id}.${google_bigquery_dataset.curated.dataset_id}.customers` c
            USING (customer_id)
          WHERE c.customer_id IS NULL
        SQL
      }
    }
  }

  depends_on = [google_bigquery_table.orders]
}

# ---------------------------------------------------------------------------
# Zero-copy sharing (BigQuery sharing / Analytics Hub): the activation rung
# ---------------------------------------------------------------------------
resource "google_bigquery_analytics_hub_data_exchange" "partners" {
  location         = var.bq_location
  data_exchange_id = "${var.domain}_partner_exchange"
  display_name     = "${title(var.domain)} partner exchange"
  description      = "Governed, zero-copy distribution of the consumption zone to partners."
  primary_contact  = "data-platform@example.com"
  documentation    = "https://cloud.google.com/bigquery/docs/analytics-hub-introduction"
  depends_on       = [google_project_service.apis]
}

resource "google_bigquery_analytics_hub_listing" "orders_daily" {
  location         = var.bq_location
  data_exchange_id = google_bigquery_analytics_hub_data_exchange.partners.data_exchange_id
  listing_id       = "${var.domain}_daily_agg"
  display_name     = "${title(var.domain)} daily aggregates"
  description      = "Country/channel daily aggregates. No PII. Refreshed hourly."
  primary_contact  = "data-platform@example.com"
  categories       = ["commerce"]

  bigquery_dataset {
    dataset = google_bigquery_dataset.consumption.id
  }
}
```

### 3.4 `dq/orders_dq.yaml` — the same contract, portable (for `gcloud dataplex datascans`)

```yaml
# Applied with:
#   gcloud dataplex datascans create data-quality orders-dq \
#     --location=us-central1 \
#     --data-source-resource="//bigquery.googleapis.com/projects/PROJECT/datasets/orders_curated/tables/orders" \
#     --data-quality-spec-file=dq/orders_dq.yaml
samplingPercent: 100
rowFilter: "event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)"

postScanActions:
  bigqueryExport:
    resultsTable: "//bigquery.googleapis.com/projects/PROJECT/datasets/orders_curated/tables/dq_results"

rules:
  - column: order_id
    dimension: COMPLETENESS
    threshold: 1.0
    description: "Idempotency key must exist."
    nonNullExpectation: {}

  - column: order_id
    dimension: UNIQUENESS
    threshold: 1.0
    description: "At-least-once delivery must not survive into CURATED."
    uniquenessExpectation: {}

  - column: country_code
    dimension: VALIDITY
    threshold: 0.999
    regexExpectation:
      regex: "^[A-Z]{2}$"

  - column: channel
    dimension: VALIDITY
    threshold: 1.0
    setExpectation:
      values: ["WEB", "MOBILE", "STORE", "PARTNER"]

  - column: gross_amount
    dimension: VALIDITY
    threshold: 0.9999
    rangeExpectation:
      minValue: "0"
      maxValue: "1000000"
      strictMinEnabled: false
      strictMaxEnabled: false

  - dimension: FRESHNESS
    threshold: 1.0
    description: "Freshness SLI gate."
    tableConditionExpectation:
      sqlExpression: "TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), MINUTE) <= 15"

  - dimension: VOLUME
    threshold: 1.0
    description: "Volume floor catches silent partial loads."
    tableConditionExpectation:
      sqlExpression: "COUNT(*) > 1000"

  - column: gross_amount
    dimension: ACCURACY
    threshold: 1.0
    description: "Daily revenue must not deviate more than 40% from the trailing 7-day mean."
    sqlAssertion:
      sqlStatement: |
        WITH daily AS (
          SELECT DATE(event_ts) AS d, SUM(gross_amount) AS rev
          FROM `PROJECT.orders_curated.orders`
          WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 8 DAY)
          GROUP BY d
        ),
        stats AS (
          SELECT AVG(rev) AS mean_rev
          FROM daily
          WHERE d < CURRENT_DATE()
        )
        SELECT d, rev
        FROM daily, stats
        WHERE d = CURRENT_DATE()
          AND ABS(rev - mean_rev) / NULLIF(mean_rev, 0) > 0.40
```

### 3.5 `k8s/freshness-slo.yaml` — freshness SLI exporter on GKE (complete manifest set)

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: data-slo
  labels:
    app.kubernetes.io/part-of: data-platform
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: freshness-probe
  namespace: data-slo
  annotations:
    # Workload Identity: no keys on disk, ever.
    iam.gke.io/gcp-service-account: freshness-probe@PROJECT_ID.iam.gserviceaccount.com
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: freshness-queries
  namespace: data-slo
data:
  probe.sh: |
    #!/usr/bin/env bash
    set -Eeuo pipefail
    # Never pipe the query through tee: a pipeline hides a non-zero exit status.
    PROJECT="${PROJECT_ID:?PROJECT_ID must be set}"

    read -r -d '' SQL <<'EOSQL' || true
    SELECT
      'orders.curated.orders' AS dataset,
      TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), SECOND) AS staleness_seconds,
      COUNT(*) AS rows_last_24h
    FROM `orders_curated.orders`
    WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
    EOSQL

    RESULT="$(bq --project_id="${PROJECT}" --format=json --headless \
                 query --nouse_legacy_sql --maximum_bytes_billed=10000000000 "${SQL}")"

    STALENESS="$(echo "${RESULT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["staleness_seconds"])')"
    ROWS="$(echo "${RESULT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["rows_last_24h"])')"

    # Structured log line; a log-based metric turns this into an SLI time series.
    python3 - "$STALENESS" "$ROWS" <<'EOPY'
    import json, sys
    print(json.dumps({
        "severity": "INFO" if int(sys.argv[1]) <= 900 else "ERROR",
        "message": "data_freshness_probe",
        "dataset": "orders.curated.orders",
        "staleness_seconds": int(sys.argv[1]),
        "rows_last_24h": int(sys.argv[2]),
        "slo_target_seconds": 900,
        "slo_met": int(sys.argv[1]) <= 900,
    }))
    EOPY

    if [ "${STALENESS}" -gt 900 ]; then
      echo "FRESHNESS SLO VIOLATION: ${STALENESS}s > 900s" >&2
      exit 1
    fi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: orders-freshness-probe
  namespace: data-slo
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 120
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 240
      template:
        metadata:
          labels:
            app: orders-freshness-probe
        spec:
          serviceAccountName: freshness-probe
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: probe
              image: gcr.io/google.com/cloudsdktool/google-cloud-cli:slim
              command: ["/bin/bash", "/scripts/probe.sh"]
              env:
                - name: PROJECT_ID
                  value: "PROJECT_ID"
                - name: CLOUDSDK_CORE_DISABLE_PROMPTS
                  value: "1"
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
              resources:
                requests:
                  cpu: "100m"
                  memory: "256Mi"
                limits:
                  cpu: "500m"
                  memory: "512Mi"
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
          volumes:
            - name: scripts
              configMap:
                name: freshness-queries
                defaultMode: 0555
```

And the alerting half, in Terraform:

```hcl
resource "google_logging_metric" "freshness_staleness" {
  name        = "data_freshness_staleness_seconds"
  description = "Staleness of governed datasets, emitted by the GKE freshness probe."
  filter      = <<-EOT
    resource.type="k8s_container"
    jsonPayload.message="data_freshness_probe"
  EOT

  metric_descriptor {
    metric_kind = "GAUGE"
    value_type  = "DISTRIBUTION"
    unit        = "s"
    labels {
      key         = "dataset"
      value_type  = "STRING"
      description = "Fully qualified dataset name."
    }
  }

  value_extractor = "EXTRACT(jsonPayload.staleness_seconds)"

  label_extractors = {
    "dataset" = "EXTRACT(jsonPayload.dataset)"
  }

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 24
      growth_factor      = 1.6
      scale              = 10
    }
  }
}

resource "google_monitoring_alert_policy" "freshness_breach" {
  display_name = "Data freshness SLO breach — orders.curated.orders"
  combiner     = "OR"
  severity     = "CRITICAL"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      ## Freshness SLO breached

      `orders.curated.orders` is older than the 15-minute objective.

      **Triage order (see runbook §5):**
      1. `gcloud pubsub subscriptions describe orders-events-to-bq` — is the subscription attached?
      2. Check `subscription/oldest_unacked_message_age` — backlog or no traffic?
      3. Check the DLQ depth — schema rejections?
      4. `bq ls -j --max_results=20 PROJECT` — did the transform job fail?

      Escalation: orders-domain@example.com, then data-platform on-call.
    EOT
  }

  conditions {
    display_name = "staleness p95 > 900s for 10 min"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/data_freshness_staleness_seconds\" AND resource.type=\"k8s_container\""
      comparison      = "COMPARISON_GT"
      threshold_value = 900
      duration        = "600s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.dataset"]
      }
    }
  }

  alert_strategy {
    auto_close = "3600s"
  }

  depends_on = [google_logging_metric.freshness_staleness]
}
```

---

## 4. CLI sessions with real terminal output

### 4.1 Apply and verify the estate

```bash
$ gcloud config set project acme-data-prod
Updated property [core/project].

$ terraform init -upgrade
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/google versions matching "~> 6.20"...
- Installing hashicorp/google v6.24.0...
Terraform has been successfully initialized!

$ terraform apply -auto-approve
...
Apply complete! Resources: 31 added, 0 changed, 0 destroyed.

$ bq ls --project_id=acme-data-prod
        datasetId
 ---------------------
  orders_raw
  orders_curated
  orders_consumption

$ bq show --format=prettyjson acme-data-prod:orders_curated.orders | \
    jq '{rows: .numRows, bytes: .numBytes, partition: .timePartitioning, cluster: .clustering}'
{
  "rows": "48213907",
  "bytes": "9127338112",
  "partition": {
    "field": "event_ts",
    "requirePartitionFilter": true,
    "type": "DAY"
  },
  "cluster": {
    "fields": [
      "country_code",
      "channel"
    ]
  }
}
```

### 4.2 The partition filter is doing its job (cost guardrail)

```bash
$ bq query --nouse_legacy_sql --dry_run \
  'SELECT COUNT(*) FROM `acme-data-prod.orders_curated.orders`'
BigQuery error in query operation: Cannot query over table
'acme-data-prod.orders_curated.orders' without a filter over column(s) 'event_ts'
that can be used for partition elimination

$ bq query --nouse_legacy_sql --dry_run \
  'SELECT COUNT(*) FROM `acme-data-prod.orders_curated.orders`
   WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)'
Query successfully validated. Assuming the tables are not modified,
running this query will process 42317184 bytes of data.
```

42 MB instead of 9.1 GB — a 215× reduction from one schema decision. This is the difference between "we cannot afford to let everyone query" (a silo-maker) and "self-serve is safe".

### 4.3 Freshness and completeness, measured

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), SECOND) AS staleness_s,
  COUNT(*)                                                      AS rows_24h,
  COUNT(DISTINCT order_id)                                      AS distinct_orders,
  COUNT(*) - COUNT(DISTINCT order_id)                           AS dupes
FROM `acme-data-prod.orders_curated.orders`
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)'
+-------------+----------+-----------------+-------+
| staleness_s | rows_24h | distinct_orders | dupes |
+-------------+----------+-----------------+-------+
|         112 |   418337 |          418337 |     0 |
+-------------+----------+-----------------+-------+
```

Per-partition row counts, straight from metadata (free, no scan):

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT partition_id, total_rows, total_logical_bytes, last_modified_time
FROM `acme-data-prod.orders_curated.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = "orders"
ORDER BY partition_id DESC
LIMIT 5'
+--------------+------------+---------------------+---------------------------+
| partition_id | total_rows | total_logical_bytes |    last_modified_time     |
+--------------+------------+---------------------+---------------------------+
| 20260906     |     318204 |            60219904 | 2026-09-06 14:12:41.883 UTC |
| 20260905     |     421889 |            79881216 | 2026-09-06 00:04:11.207 UTC |
| 20260904     |     417332 |            79036416 | 2026-09-05 00:03:58.912 UTC |
| 20260903     |      98104 |            18579456 | 2026-09-04 00:04:02.551 UTC |
| 20260902     |     419776 |            79495168 | 2026-09-03 00:03:47.330 UTC |
+--------------+------------+---------------------+---------------------------+
```

**Read that output like an SRE:** `20260903` holds 98,104 rows against a ~420k baseline — a **silent partial load**. Nothing failed loudly; the dashboard simply showed a quiet Thursday. This is exactly why the VOLUME rule exists in §3.4, and it is the single most common way "data-driven" decisions are made on wrong data.

### 4.4 Run the quality scan and read the verdict

```bash
$ gcloud dataplex datascans run orders-orders-dq --location=us-central1
Waiting for scan job to complete...
job:
  name: projects/acme-data-prod/locations/us-central1/dataScans/orders-orders-dq/jobs/8f2a1c04-...
  state: SUCCEEDED

$ gcloud dataplex datascans jobs describe 8f2a1c04-6b73-4f9e-9a41-2c7d5e0b1a33 \
    --datascan=orders-orders-dq --location=us-central1 --format=json | \
  jq '.dataQualityResult | {passed, rowCount,
       rules: [.rules[] | {rule: (.rule.column // "table"),
                           dim: .rule.dimension, passed: .passed,
                           ratio: .passRatio}]}'
{
  "passed": false,
  "rowCount": "836841",
  "rules": [
    { "rule": "order_id",     "dim": "COMPLETENESS", "passed": true,  "ratio": 1 },
    { "rule": "order_id",     "dim": "UNIQUENESS",   "passed": true,  "ratio": 1 },
    { "rule": "country_code", "dim": "VALIDITY",     "passed": true,  "ratio": 0.99997 },
    { "rule": "channel",      "dim": "VALIDITY",     "passed": false, "ratio": 0.98812 },
    { "rule": "gross_amount", "dim": "VALIDITY",     "passed": true,  "ratio": 1 },
    { "rule": "currency",     "dim": "VALIDITY",     "passed": true,  "ratio": 1 },
    { "rule": "table",        "dim": "FRESHNESS",    "passed": true,  "ratio": 1 },
    { "rule": "table",        "dim": "VOLUME",       "passed": true,  "ratio": 1 },
    { "rule": "customer_id",  "dim": "CONSISTENCY",  "passed": true,  "ratio": 0.9991 }
  ]
}
```

Find the offending values without guessing:

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT channel, COUNT(*) AS n
FROM `acme-data-prod.orders_curated.orders`
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
  AND channel NOT IN ("WEB","MOBILE","STORE","PARTNER")
GROUP BY channel ORDER BY n DESC'
+-----------+------+
|  channel  |  n   |
+-----------+------+
| KIOSK     | 9106 |
| web       |  832 |
| MARKETPL  |   47 |
+-----------+------+
```

Three distinct governance failures in one result set: a **new business channel nobody told the platform about** (`KIOSK`), a **casing contract violation** (`web`), and a **truncated value** (`MARKETPL`). Each is a silo symptom — the producing team changed its world and the consuming contract learned about it from an alert instead of a conversation.

### 4.5 Column-level security, proven rather than assumed

```bash
$ gcloud auth list
                 Credentialed Accounts
ACTIVE  ACCOUNT
*       analyst-lo@acme.example.com

$ bq query --nouse_legacy_sql --format=pretty '
SELECT customer_email
FROM `acme-data-prod.orders_curated.orders`
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) LIMIT 2'
+------------------------------------------------------------------+
|                          customer_email                          |
+------------------------------------------------------------------+
| 6b2f9d1c4e8a70b35c19af02d8e4771a9c30bb5e6f4a8d21c7e903b1f5a6d8c4 |
| a91c7e4b02d85f36194ac0e8b7d25f31068ba9c4e7f2d015386ba4c9e1d70f28 |
+------------------------------------------------------------------+

$ bq query --nouse_legacy_sql 'SELECT * FROM `acme-data-prod.orders_curated.orders`
   WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) LIMIT 1'
BigQuery error in query operation: Access Denied: BigQuery BigQuery: User does not
have permission to access policy tag "pii-classification-orders : pii-high" on
column acme-data-prod.orders_curated.orders.customer_email.
```

Masking answered the analytic question (`COUNT(DISTINCT customer_email)` still works on the hash) while `SELECT *` was refused. **That is governance enabling access, not blocking it** — the exam's framing of why governance accelerates rather than slows transformation.

### 4.6 Lineage: the answer to "where did this number come from?"

```bash
$ curl -sS -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  "https://us-central1-datalineage.googleapis.com/v1/projects/acme-data-prod/locations/us-central1:searchLinks" \
  -d '{
        "target": {
          "fullyQualifiedName": "bigquery:acme-data-prod.orders_consumption.daily_revenue"
        }
      }' | jq '.links[] | {from: .source.fullyQualifiedName, to: .target.fullyQualifiedName}'
{
  "from": "bigquery:acme-data-prod.orders_curated.orders",
  "to": "bigquery:acme-data-prod.orders_consumption.daily_revenue"
}
{
  "from": "bigquery:acme-data-prod.orders_curated.customers",
  "to": "bigquery:acme-data-prod.orders_consumption.daily_revenue"
}
```

```bash
$ gcloud dataplex entries lookup \
    --location=us-central1 \
    --entry="projects/acme-data-prod/locations/us-central1/entryGroups/@bigquery/entries/bigquery.googleapis.com/projects/acme-data-prod/datasets/orders_curated/tables/orders" \
    --format="value(entrySource.description)"
DATA PRODUCT: orders.curated.orders
Owner        : orders-domain@example.com
SLO          : freshness p99 <= 15 min | completeness >= 99.9% per partition
```

A new analyst answers "is this trustworthy, who owns it, what feeds it" in two commands and zero meetings. **That is the measurable end state of de-siloing.**

### 4.7 Cost attribution — data as a managed asset

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT
  user_email,
  COUNT(*)                                                AS jobs,
  ROUND(SUM(total_bytes_billed)/POW(1024,4), 2)           AS tib_billed,
  ROUND(SUM(total_bytes_billed)/POW(1024,4) * 6.25, 2)    AS est_usd
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND job_type = "QUERY" AND state = "DONE"
GROUP BY user_email ORDER BY tib_billed DESC LIMIT 5'
+------------------------------------------+------+------------+---------+
|                user_email                | jobs | tib_billed | est_usd |
+------------------------------------------+------+------------+---------+
| looker-sa@acme-data-prod.iam.gservice... | 8241 |      12.44 |   77.75 |
| dataform-sa@acme-data-prod.iam.gservi... |  672 |       9.03 |   56.44 |
| analyst-mk@acme.example.com              |  118 |       7.91 |   49.44 |
| analyst-lo@acme.example.com              |   96 |       0.44 |    2.75 |
| freshness-probe@acme-data-prod.iam.gs... | 2016 |       0.02 |    0.13 |
+------------------------------------------+------+------------+---------+
```

One analyst burning 7.91 TiB across 118 queries is a training signal (`SELECT *` on an unfiltered range), not a billing problem. Treating data as an asset means its consumption is attributable per consumer.

---

## 5. Verification and failure diagnosis

### 5.1 Pre-flight checklist for any new data product

```bash
# 1. Provenance and ownership are declared
$ bq show --format=prettyjson acme-data-prod:orders_curated.orders \
    | jq -r '.description' | grep -E '^(Owner|SLO)' || echo "FAIL: undeclared contract"

# 2. Cost guardrail present
$ bq show --format=prettyjson acme-data-prod:orders_curated.orders \
    | jq '.timePartitioning.requirePartitionFilter'
true

# 3. PII columns carry policy tags
$ bq show --schema --format=prettyjson acme-data-prod:orders_curated.orders \
    | jq '[.[] | select(.policyTags) | .name]'
[
  "customer_email"
]

# 4. Quality scan is scheduled, not manual
$ gcloud dataplex datascans describe orders-orders-dq --location=us-central1 \
    --format="value(executionSpec.trigger.schedule.cron)"
0 */2 * * *

# 5. Dead-letter path exists
$ gcloud pubsub subscriptions describe orders-events-to-bq \
    --format="value(deadLetterPolicy.deadLetterTopic)"
projects/acme-data-prod/topics/orders-events-dlq

# 6. The catalog can find it
$ gcloud dataplex entries search "orders system=bigquery" \
    --project=acme-data-prod --format="value(dataplexEntry.name)" | head -3
```

Any `FAIL` above means the dataset is not a data product; it is a silo with a nicer address.

### 5.2 Runbook: symptom → cause → command → resolution

| # | Symptom | Most probable cause | Diagnostic command | Resolution |
|---|---|---|---|---|
| 1 | Freshness alert, DLQ growing | Producer emitting fields not in the Pub/Sub Avro schema | `gcloud pubsub topics describe orders-events-dlq`; pull a sample from the DLQ subscription | Version the schema (`-v2` topic + revision), fix the producer, replay the DLQ |
| 2 | Freshness alert, DLQ empty, backlog age climbing | BigQuery subscription lost write permission (service-agent IAM drift) | `gcloud pubsub subscriptions describe orders-events-to-bq --format='value(state)'` → `RESOURCE_ERROR` | Re-grant `roles/bigquery.dataEditor` to `service-<NUM>@gcp-sa-pubsub.iam.gserviceaccount.com` |
| 3 | Freshness alert, backlog **flat at zero** | No traffic — producer outage, not a data-platform outage | Compare `topic/send_request_count` vs `subscription/oldest_unacked_message_age` | Page the producing domain, not the platform |
| 4 | Row count collapse in one partition (see §4.3) | Silent partial load; a shard failed and the wrapper exited 0 | `bq ls -j --max_results=50 --format=prettyjson` → find `status.errorResult` | Replay that partition from RAW; **remove any `\| tee` from the pipeline wrapper** — pipelines mask exit codes |
| 5 | Duplicate `order_id` after a retry storm | At-least-once redelivery with no dedup in the RAW→CURATED step | `SELECT order_id, COUNT(*) c FROM … GROUP BY 1 HAVING c > 1 LIMIT 10` | `MERGE` on `order_id`, or `QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY ingested_at DESC) = 1` |
| 6 | Two teams report different totals | Semantic drift: two definitions of the same metric | Diff the SQL of both consumption views; check `INFORMATION_SCHEMA.VIEWS` | Publish **one** consumption-zone view; deprecate the other; register the definition in the catalog |
| 7 | `Cannot query over table … without a filter` | The cost guardrail firing as designed | — | Teach the filter; do **not** disable `require_partition_filter` |
| 8 | Query cost spike | Unfiltered `SELECT *`, or a view fanning out | `JOBS_BY_PROJECT` grouped by `user_email` (§4.7) | Set `maximum_bytes_billed`, add custom quotas, add materialized views, enable BI Engine |
| 9 | New column appears entirely `NULL` | Upstream rename; write-disposition appended without contract check | `bq show --schema` diff vs the previous revision in Git | Enforce schema in Pub/Sub or a Dataform assertion; backfill from RAW |
| 10 | Analyst blocked by `Access Denied … policy tag` | Correct behaviour, wrong role assignment | `gcloud data-catalog taxonomies list --location=us-central1` and check `roles/datacatalog.categoryFineGrainedReader` | Grant the fine-grained reader role, or point them at the masked column |
| 11 | Dataplex entry missing from search | Discovery disabled, or the asset was never attached to a zone | `gcloud dataplex assets describe curated-dataset --zone=curated-zone --lake=orders-lake --location=us-central1` | Enable `discovery_spec`, re-attach the asset |
| 12 | Lineage graph empty | The transform ran outside a lineage-integrated engine (raw SDK, external tool) | `searchLinks` returns `{}` (§4.6) | Move the transform to Dataform/Dataflow/BigQuery, or report lineage explicitly via the Data Lineage API |
| 13 | DQ `CONSISTENCY` rule failing | Late-arriving dimension: facts landed before the customer record | Run the `sqlAssertion` SQL directly | Add a wait/sensor in Composer, or accept and quarantine orphan facts in a `_rejects` table |
| 14 | Everything green, business still distrusts the number | Ungoverned spreadsheet copies still circulating | Look for exports: `SELECT DISTINCT user_email FROM JOBS_BY_PROJECT WHERE statement_type="EXPORT_DATA"` | Deprecate the export path; publish via BigQuery sharing / Looker instead |

### 5.3 Replay procedure (RAW is the reason this is short)

```bash
# Rebuild a single corrupt partition from the immutable RAW zone.
$ bq query --nouse_legacy_sql --destination_table=orders_curated.orders\$20260903 \
  --replace --maximum_bytes_billed=50000000000 '
SELECT
  order_id, customer_id, customer_email,
  UPPER(country_code)                       AS country_code,
  UPPER(TRIM(channel))                      AS channel,
  CAST(gross_amount AS NUMERIC)             AS gross_amount,
  currency, event_ts,
  CURRENT_TIMESTAMP()                       AS ingested_at,
  source_system
FROM `acme-data-prod.orders_raw.orders_stream`
WHERE DATE(event_ts) = "2026-09-03"
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY event_ts DESC) = 1'
Waiting on bqjob_r4c81f0a2b7e93d15_00000198ac21ee0f_1 ... (34s) Current status: DONE
```

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT partition_id, total_rows
FROM `acme-data-prod.orders_curated.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name="orders" AND partition_id="20260903"'
+--------------+------------+
| partition_id | total_rows |
+--------------+------------+
| 20260903     |     419881 |
+--------------+------------+
```

Recovery took one query because RAW was immutable and complete. **The zone model is not architectural taste; it is the mean-time-to-recovery of your business's numbers.**

### 5.4 Time travel and the "someone dropped it" case

```bash
# Read the table as it was 45 minutes ago (7-day default window).
$ bq query --nouse_legacy_sql --format=pretty '
SELECT COUNT(*) AS rows_before_incident
FROM `acme-data-prod.orders_curated.orders`
  FOR SYSTEM_TIME AS OF TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 45 MINUTE)
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)'
+----------------------+
| rows_before_incident |
+----------------------+
|               836841 |
+----------------------+

# Who ran the destructive statement?
$ bq query --nouse_legacy_sql --format=pretty '
SELECT creation_time, user_email, statement_type, LEFT(query, 60) AS q
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
  AND statement_type IN ("DELETE","TRUNCATE_TABLE","DROP_TABLE","MERGE")
ORDER BY creation_time DESC'
+---------------------------+------------------------------+----------------+--------------------------------------+
|       creation_time       |          user_email          | statement_type |                  q                   |
+---------------------------+------------------------------+----------------+--------------------------------------+
| 2026-09-06 13:41:07.221 U | etl-sa@acme-data-prod.iam.gs | DELETE         | DELETE FROM `orders_curated.orders`  |
+---------------------------+------------------------------+----------------+--------------------------------------+
```

---

## 6. Exam-oriented distillation

### 6.1 Terms you must be able to define in one sentence

| Term | One-sentence definition |
|---|---|
| **Data silo** | Data isolated under one team's control such that others cannot access or trust it, producing conflicting versions of the truth. |
| **Data lifecycle** | Ingest → store → process/analyze → activate/visualize; value is only realized at the end, and every stage can lose it. |
| **Structured / semi-structured / unstructured** | Fixed schema / self-describing flexible schema / no inherent schema — the last being the majority of enterprise data. |
| **Data governance** | The people, policies and controls that make data discoverable, trustworthy, secure and compliant — *so it can be shared*. |
| **Data quality** | Fitness for purpose, measured across completeness, validity, uniqueness, consistency, freshness and volume. |
| **Data lineage** | The recorded provenance of a dataset: which sources and transformations produced it. |
| **Data-driven decision making** | Decisions made from measured, timely, governed data rather than intuition or stale reports. |
| **Data as a strategic asset / differentiator** | First-party data is the input competitors cannot copy; it is what makes an ML model *yours*. |
| **Data democratization** | Safe self-serve access for non-specialists, which is only possible once governance exists. |
| **Data monetization** | Turning governed data into revenue — new products, better decisions, or governed sharing (BigQuery sharing / Analytics Hub). |

### 6.2 The five traps, consolidated

1. **You cannot skip rungs** — no AI strategy without a data strategy.
2. **Consolidating storage ≠ removing silos** — ownership, definitions and policy must consolidate too, or you get a data swamp.
3. **Unstructured data is the majority** — Cloud Storage is its home; object tables + BigQuery ML/Vertex AI make it analyzable.
4. **Streaming is not automatically better** — pick the cheapest latency that changes a decision.
5. **Governance enables access, it does not only restrict it** — masked, tagged, lineage-tracked data can be opened widely; ungoverned data must stay locked, re-creating silos.

Two more worth carrying into the exam room:

6. **Culture is in scope.** The exam explicitly treats change management and data literacy as part of transformation. A perfect platform with no trained consumers produces no decisions.
7. **Value is realized on activation, not on ingestion.** Bytes stored are cost; decisions changed are value.

### 6.3 Scenario drill (exam-style)

> *A retailer has store POS data in an on-prem Oracle database, e-commerce clickstream in a SaaS analytics tool, and inventory photos on a NAS. Merchandising and Finance publish different weekly revenue figures. Leadership wants demand forecasting. What is the first priority?*

**Answer:** Not the forecasting model. First, break the silos and establish one governed source of truth — CDC the POS with Datastream, stream clickstream through Pub/Sub, land the images in Cloud Storage as object tables, unify in BigQuery, catalog and enforce quality with Dataplex, and publish **one** agreed revenue definition in the consumption zone. The forecasting model is rung 5; the revenue disagreement proves the organization is still on rung 1. Only after the definition is single and its freshness/completeness are measurable does BigQuery ML or Vertex AI produce a forecast anyone should act on.

---

## 7. References

**Exam and certification**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader
- Learning path: Exploring Data Transformation with Google Cloud — https://www.cloudskillsboost.google/paths/9

**Data strategy and transformation**
- What is digital transformation — https://cloud.google.com/learn/what-is-digital-transformation
- Data analytics on Google Cloud — https://cloud.google.com/solutions/data-analytics-and-ai
- Data lifecycle on Google Cloud — https://cloud.google.com/architecture/data-lifecycle-cloud-platform
- Cloud Architecture Center — data engineering — https://cloud.google.com/architecture/data-engineering
- Google Cloud Architecture Framework — https://cloud.google.com/architecture/framework

**Storage and analytics**
- BigQuery documentation — https://cloud.google.com/bigquery/docs
- BigQuery partitioned tables — https://cloud.google.com/bigquery/docs/partitioned-tables
- BigQuery clustered tables — https://cloud.google.com/bigquery/docs/clustered-tables
- BigQuery `INFORMATION_SCHEMA` — https://cloud.google.com/bigquery/docs/information-schema-intro
- BigQuery time travel — https://cloud.google.com/bigquery/docs/time-travel
- BigLake introduction — https://cloud.google.com/biglake/docs/introduction
- BigQuery object tables (unstructured data) — https://cloud.google.com/bigquery/docs/object-table-introduction
- Cloud Storage documentation — https://cloud.google.com/storage/docs
- Cloud Storage Autoclass — https://cloud.google.com/storage/docs/autoclass
- Cloud Storage soft delete — https://cloud.google.com/storage/docs/soft-delete

**Ingestion and processing**
- Pub/Sub documentation — https://cloud.google.com/pubsub/docs
- Pub/Sub schemas — https://cloud.google.com/pubsub/docs/schemas
- Pub/Sub BigQuery subscriptions — https://cloud.google.com/pubsub/docs/bigquery
- Pub/Sub dead-letter topics — https://cloud.google.com/pubsub/docs/handling-failures
- Datastream documentation — https://cloud.google.com/datastream/docs
- Database Migration Service — https://cloud.google.com/database-migration/docs
- Dataflow documentation — https://cloud.google.com/dataflow/docs
- Dataproc documentation — https://cloud.google.com/dataproc/docs
- Cloud Data Fusion — https://cloud.google.com/data-fusion/docs
- Dataform — https://cloud.google.com/dataform/docs
- Cloud Composer — https://cloud.google.com/composer/docs
- BigQuery Data Transfer Service — https://cloud.google.com/bigquery-transfer/docs/introduction
- Storage Transfer Service — https://cloud.google.com/storage-transfer/docs
- Transfer Appliance — https://cloud.google.com/transfer-appliance/docs

**Governance, quality, lineage, security**
- Dataplex Universal Catalog — https://cloud.google.com/dataplex/docs
- Dataplex auto data quality — https://cloud.google.com/dataplex/docs/auto-data-quality-overview
- Create and run a data quality scan — https://cloud.google.com/dataplex/docs/use-auto-data-quality
- Data Catalog transition to Dataplex Universal Catalog — https://cloud.google.com/dataplex/docs/transition-to-dataplex-catalog
- Data lineage in Dataplex — https://cloud.google.com/dataplex/docs/about-data-lineage
- BigQuery column-level security — https://cloud.google.com/bigquery/docs/column-level-security-intro
- BigQuery data masking — https://cloud.google.com/bigquery/docs/column-data-masking-intro
- BigQuery row-level security — https://cloud.google.com/bigquery/docs/row-level-security-intro
- VPC Service Controls — https://cloud.google.com/vpc-service-controls/docs/overview
- Cloud KMS / CMEK — https://cloud.google.com/kms/docs
- Sensitive Data Protection (Cloud DLP) — https://cloud.google.com/sensitive-data-protection/docs

**Sharing, BI and AI**
- BigQuery sharing (Analytics Hub) — https://cloud.google.com/bigquery/docs/analytics-hub-introduction
- Looker — https://cloud.google.com/looker/docs
- Looker Studio — https://cloud.google.com/looker-studio
- BigQuery ML — https://cloud.google.com/bigquery/docs/bqml-introduction
- Vertex AI — https://cloud.google.com/vertex-ai/docs

**SRE and reliability practice**
- Google SRE Book — Service Level Objectives — https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook — Alerting on SLOs — https://sre.google/workbook/alerting-on-slos/
- Cloud Monitoring log-based metrics — https://cloud.google.com/logging/docs/logs-based-metrics
- GKE Workload Identity Federation — https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity

**Provider and tooling references**
- Terraform Google provider — https://registry.terraform.io/providers/hashicorp/google/latest/docs
- `gcloud dataplex` reference — https://cloud.google.com/sdk/gcloud/reference/dataplex
- `bq` command-line reference — https://cloud.google.com/bigquery/docs/reference/bq-cli-reference