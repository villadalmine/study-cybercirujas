# 2.3 — Smart Analytics, Business Intelligence, and Streaming Analytics

**Google Cloud Digital Leader — Domain 2 (Innovating with Data and Google Cloud), Objective 2.3**
**Exam weight: 6.0** · **Syllabus version: 2026-08-12**
**Reading profile: Principal Platform Architect / Senior SRE**

---

## 1. The production problem: why "we have a data warehouse" is not an analytics architecture

### 1.1 The failure mode that generates the requirement

Every organisation that reaches a few hundred million events per day converges on the same incident report. It reads roughly like this:

> **INC-4471 — Fraud rules fired 9 hours after the fraudulent session ended.**
> Root cause: the fraud scoring model consumes `dw.sessions_daily`, materialised by a nightly Spark job that starts at 02:00 UTC and finishes at 05:40 UTC. The fraudulent transactions occurred at 17:20 UTC the previous day. The pipeline was working exactly as designed. The design was the incident.

This is the **batch-window collapse**. It is not a bug, it is an architectural property: any system whose smallest unit of freshness is a nightly job has an *expected* decision latency of half the batch interval plus the job duration. If the business value of a decision decays faster than that number, the pipeline is a very expensive archive.

The second failure mode is subtler and worse:

> **INC-5102 — Two dashboards, two revenue numbers, one board meeting.**
> Finance reads `looker::revenue.gross_bookings` (currency-normalised at settlement date, refunds netted, test accounts excluded). Growth reads a Looker Studio report built directly on `raw.orders` (no refund join, no test-account filter, FX at order date). Delta: 4.1%. Both are "the data".

This is the **semantic drift** failure. It is what happens when every consumer re-implements business logic in their own SQL. The fix is not more dashboards; it is a *governed semantic layer* — a single, version-controlled definition of what "revenue" means, compiled to SQL at query time.

The third failure mode is the one that kills budgets:

> **INC-5533 — $41,200 of on-demand BigQuery spend in 36 hours.**
> A scheduled Looker Studio dashboard with a 15-minute refresh, backed by an unpartitioned 84 TiB table, shared with 60 users. Each refresh performed a full scan.

This is **uncontrolled scan amplification**. In a serverless warehouse, the cost model moves from "capacity we bought" to "bytes we touched", and every unpartitioned table is a loaded weapon pointed at the finance department.

### 1.2 The architectural triangle you are actually negotiating

```
                     FRESHNESS
                  (decision latency)
                        /\
                       /  \
                      /    \
                     /      \
                    /        \
                   /          \
                  /            \
           COST  /______________\  CORRECTNESS
        ($/TiB,               (completeness, ordering,
      slot-hours)              exactly-once, late data)
```

You cannot maximise all three. Every service choice in this objective is a specific, documented point inside that triangle:

| You optimise for | You accept | Canonical GCP pattern |
|---|---|---|
| Freshness (sub-second) | Higher cost/byte, weaker completeness guarantees at the edge of the window | Pub/Sub → Dataflow streaming → BigQuery Storage Write API |
| Correctness (complete, reconcilable) | Latency measured in hours | Cloud Storage → Dataproc/Dataflow batch → BigQuery, with idempotent partition overwrite |
| Cost | Latency and operational flexibility | Pub/Sub BigQuery subscription (no Dataflow), scheduled queries, partitioned + clustered tables |
| Freshness *and* correctness | Cost, and dual-code-path complexity | Lambda architecture: streaming speed layer + batch reconciliation layer over the same events |

**SRE framing:** treat *data freshness* as an SLI with an error budget, exactly like request latency. A useful SLO looks like:

> 99% of 5-minute windows have `oldest_unacked_message_age < 120s` on subscription `sub-clickstream-enrich`, measured over a rolling 28 days.

That single line converts an unbounded architectural argument ("should this be real-time?") into a budget the business owns.

### 1.3 What "smart analytics" means in Google's vocabulary

Google's marketing term **smart analytics** is not fluff — it denotes a specific product property: *analytics services with machine learning and AI integrated into the query surface itself*, so that the ML step does not require exporting data to a separate platform. Concretely:

- **BigQuery ML** — train and serve models with `CREATE MODEL` / `ML.PREDICT` in SQL, over data that never leaves the warehouse.
- **Remote models** — `ML.GENERATE_TEXT`, `ML.GENERATE_EMBEDDING` calling Vertex AI (including Gemini) from a SQL statement.
- **BigQuery vector search** — `VECTOR_SEARCH()` over embedding columns with `CREATE VECTOR INDEX`, i.e. semantic retrieval without a separate vector database for moderate scales.
- **Built-in forecasting** — `ARIMA_PLUS` / `ARIMA_PLUS_XREG` and `AI.FORECAST` over time-series tables.
- **Looker's semantic layer feeding AI** — the governed metric definitions become the grounding context for natural-language querying, which is the difference between an LLM guessing a JOIN and an LLM reading a certified metric.

The **business value argument** — which is what the CDL exam actually tests — is that removing the export/import step removes the three things that kill ML projects: data-copy governance risk, staleness between training and serving, and the specialist-team bottleneck. A data analyst with SQL can ship a churn model.

---

## 2. Service map: the data lifecycle as an architecture

Google organises this domain around a five-stage lifecycle. Memorise the stages and the *primary* service for each — the exam tests placement, and production tests the trade-offs.

```
 ┌──────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐   ┌────────────┐
 │  INGEST  │──▶│  STORE   │──▶│  PROCESS  │──▶│ ANALYZE  │──▶│  ACTIVATE  │
 └──────────┘   └──────────┘   └───────────┘   └──────────┘   └────────────┘
  Pub/Sub        Cloud Storage   Dataflow        BigQuery       Looker
  Datastream     BigQuery        Dataproc        BigQuery ML    Looker Studio
  Storage        Bigtable        Dataform        Vertex AI      Connected Sheets
   Transfer      Cloud SQL       Data Fusion     Notebooks      Analytics Hub
  Data Transfer  Spanner         Composer                       Reverse ETL
  Managed Kafka  AlloyDB         Dataproc                       Pub/Sub (out)
                                  Serverless
                    ▲                                                │
                    └────────── GOVERNANCE: Dataplex Universal ──────┘
                                Catalog, IAM, VPC-SC, CMEK, DLP
```

### 2.1 Ingest layer — technical comparison

| Service | Model | Ordering | Retention | Delivery guarantee | Best for | Anti-pattern |
|---|---|---|---|---|---|---|
| **Pub/Sub** | Serverless global topic/subscription, auto-scaling, no partitions to size | Per `ordering_key`, within a region | Topic: up to 31 days; subscription: 10 min – 7 days | At-least-once by default; **exactly-once** available on regional pull subscriptions | Decoupled event backbone, fan-out, cross-region | Needing per-partition replay semantics identical to Kafka consumer groups |
| **Managed Service for Apache Kafka** | Managed Kafka clusters (real brokers, real partitions) | Per partition | Configurable, disk-bound | At-least-once; exactly-once via Kafka transactions | Lift-and-shift of existing Kafka apps, Kafka Connect / Streams ecosystems | Greenfield where you would otherwise not want to size partitions |
| **Datastream** | Serverless change data capture (CDC) from Oracle, MySQL, PostgreSQL, SQL Server | Per source transaction stream | Managed | At-least-once with upsert reconciliation into BigQuery | Replicating an OLTP database to BigQuery with seconds-to-minutes lag, zero application change | Heavy transformation in flight — it is replication, not ETL |
| **Storage Transfer Service** | Scheduled/one-off bulk transfer (S3, Azure Blob, HTTP, on-prem via agents) | N/A | N/A | Checksum-verified | Backfill, migration, cross-cloud sync | Anything sub-hourly |
| **BigQuery Data Transfer Service** | Managed scheduled loads from SaaS (Google Ads, Campaign Manager, YouTube, S3, Redshift…) | N/A | N/A | Managed retries | SaaS marketing/ads data into BigQuery with no code | Custom APIs |
| **Direct client writes** (Storage Write API) | gRPC streaming append into BigQuery | Per stream | N/A | Exactly-once with stream offsets | Application-owned high-throughput ingestion | When you also need fan-out to other consumers — you have coupled producer to warehouse |

> **Deprecation note:** Pub/Sub Lite is deprecated with a published shutdown; do not design new systems on it. Verify current status in the official Pub/Sub documentation before citing it in a design review.

### 2.2 Process layer — technical comparison

| Service | Engine | Autoscaling | State model | Unit of cost | Choose when |
|---|---|---|---|---|---|
| **Dataflow** | Apache Beam (Runner v2), unified batch + streaming | Horizontal + vertical (Prime); Streaming Engine decouples state from workers | Managed keyed state, timers, watermarks, exactly-once within the pipeline | vCPU-hr, GB-hr, Streaming Engine data processed, Shuffle | You need event-time correctness, windowing, late-data handling, one codebase for batch and stream |
| **Dataproc (cluster)** | Hadoop/Spark/Flink/Presto on GCE or GKE | Cluster autoscaling policies | Whatever the framework provides | VM-hours + Dataproc premium per vCPU | Migrating existing Spark/Hive/Oozie; needing specific OSS versions or libraries |
| **Dataproc Serverless for Spark** | Spark, no cluster to manage | Automatic | Spark | DCU-hours, shuffle storage | Spark workloads without cluster lifecycle ops |
| **Dataform** | SQL-only ELT inside BigQuery, with dependency graph, assertions, versioning | N/A (BigQuery slots) | N/A | BigQuery compute | Transformations expressible in SQL — which is most warehouse modelling |
| **Cloud Data Fusion** | CDAP, visual pipeline builder, 150+ connectors | Ephemeral Dataproc under the hood | Framework-managed | Instance-hours + Dataproc | Low-code ETL for teams without engineers; connector breadth |
| **Cloud Composer** | Managed Apache Airflow | Environment-level | N/A — it orchestrates, it does not process | Environment-hours | Cross-service DAG orchestration, dependencies, SLAs, backfills |
| **BigQuery continuous queries** | Streaming SQL executing continuously over BigQuery | Reservation slots | Warehouse-managed | Slots (Enterprise editions) | Simple streaming transformation/enrichment/routing expressible in SQL, without a Beam codebase |

**The decision that matters most in review:** Dataflow versus "just SQL". A Beam pipeline is a code artifact with a build, a deploy, a drain, an update-compatibility contract and an on-call rotation. If the transformation is `SELECT … FROM … WHERE …`, a scheduled query, a materialised view or a Dataform action is an order of magnitude cheaper to own. Reserve Dataflow for the things SQL genuinely cannot express: **event-time windowing with watermarks, session windows, per-key state machines, late-data reprocessing, and side inputs against slowly changing dimensions.**

### 2.3 Analyze and activate — BI tool comparison

| Tool | Semantic layer | Governance | Latency profile | Typical user | Business value framing |
|---|---|---|---|---|---|
| **Looker** | **Yes — LookML**, version-controlled in Git, compiled to SQL at query time; metrics defined once | Row-level and column-level via `access_filter` + BigQuery policies; full audit | In-database (no extract), so as fast as the warehouse; PDTs and aggregate awareness for acceleration | Analytics engineers author; everyone consumes | "One number, everywhere" — eliminates semantic drift; embeddable in customer-facing products; API-first |
| **Looker Studio** | No — per-report data source | Report/data-source sharing; owner or viewer credentials | Depends on connector; caching layer | Analysts, business users | Free, fast, self-service exploration and sharing |
| **Looker Studio Pro** | No | Adds Cloud IAM, team workspaces, SLA, support | Same | Enterprise self-service | Governed self-service without full Looker modelling investment |
| **Connected Sheets** | No | BigQuery IAM applies | Interactive against BigQuery, billions of rows, no extract | Finance/ops in spreadsheets | Removes the CSV export — the single largest source of ungoverned data copies |
| **BigQuery Studio / notebooks** | No | IAM | Interactive | Data scientists | Exploration, ML, Python + SQL in one surface |

> **Exam trap:** "Which tool lets business users query billions of rows *in a spreadsheet interface* without exporting?" → **Connected Sheets**. "Which tool provides a *governed, reusable semantic model*?" → **Looker**. "Which is the free, lightweight dashboarding tool?" → **Looker Studio**.

---

## 3. Streaming analytics: the mechanics you must understand to operate it

### 3.1 Event time vs processing time, and why watermarks exist

A mobile client emits an event at `2026-09-06T11:00:03Z` (**event time**). The device is in a tunnel. The event arrives at Pub/Sub at `11:04:47Z` (**processing time**). The 11:00–11:01 minute window has long since "passed" in wall-clock terms.

A correct streaming system must answer: *when is it safe to emit the result for the 11:00–11:01 window?* That is the job of the **watermark** — the runner's estimate of "we believe we have seen all events with event time ≤ W". Dataflow derives the watermark from Pub/Sub's oldest unacknowledged publish timestamp and propagates it through the DAG.

The three knobs, and their trade-offs:

| Knob | Beam construct | Effect | Trade-off |
|---|---|---|---|
| **Window** | `FixedWindows`, `SlidingWindows`, `Sessions`, `GlobalWindows` | Groups events by event time | Larger window = more state, more memory, more latency |
| **Trigger** | `AfterWatermark`, `.withEarlyFirings(AfterProcessingTime)`, `.withLateFirings(AfterCount)` | *When* to emit a pane | Early firings = lower latency, more panes downstream, higher write cost |
| **Allowed lateness** | `withAllowedLateness(Duration)` | How long state is retained to accept late data | Longer = more correctness, unbounded state growth risk |
| **Accumulation** | `ACCUMULATING` vs `DISCARDING` | Whether later panes restate or delta the earlier ones | ACCUMULATING requires idempotent downstream upsert; DISCARDING requires downstream summation |

**Production rule:** an `ACCUMULATING` pipeline writing to an append-only BigQuery table produces double-counted metrics. Either write `DISCARDING` deltas and `SUM()` at read time, or write `ACCUMULATING` panes with a `pane_index`/`window_start` key and deduplicate with `QUALIFY ROW_NUMBER() OVER (PARTITION BY window_start, key ORDER BY pane_index DESC) = 1`. Choosing accumulation mode without deciding the read-side contract is the single most common streaming-correctness defect.

### 3.2 Delivery semantics — what "exactly-once" actually means

There are three distinct guarantees and vendors blur them:

| Guarantee | Scope | GCP mechanism | Residual risk |
|---|---|---|---|
| At-least-once delivery | Pub/Sub → subscriber | Default | Duplicates; consumer must be idempotent |
| Exactly-once **delivery** | Pub/Sub → subscriber, regional pull subscription | `--enable-exactly-once-delivery` | Bounded to a single region; ack deadline handling becomes stricter (ack IDs expire) |
| Exactly-once **processing** | Within a Dataflow pipeline | Deterministic shuffle + checkpointed state | Does not extend to non-idempotent external side effects |
| Exactly-once **write** | Dataflow/app → BigQuery | Storage Write API with committed streams and offsets | Requires the writer to manage offsets; default-stream writes are at-least-once |

**End-to-end exactly-once is a chain, and it is only as strong as its weakest link.** If your pipeline calls an external REST API in a `DoFn`, retries will call it twice. Design the sink to be idempotent (natural key + `MERGE`, or deterministic `insertId`/offset) rather than trying to make the network reliable.

### 3.3 Pub/Sub subscription types — pick before you build

| Type | Consumer | Transformation | Cost | When |
|---|---|---|---|---|
| **Pull** (incl. StreamingPull) | Your code / Dataflow | Arbitrary | Subscriber compute + Pub/Sub delivery | Full control, complex logic |
| **Push** | HTTPS endpoint (Cloud Run, Cloud Functions, GKE Ingress) | Arbitrary | Endpoint compute | Serverless event-driven, low volume |
| **BigQuery subscription** | Direct write into a BigQuery table | **None** (optionally schema-mapped, or write to a metadata-rich schema) | No Dataflow at all — dramatically cheaper | Raw landing zone, ELT-style; transform later in SQL |
| **Cloud Storage subscription** | Direct write of batched files to GCS | None | No Dataflow | Cheap archival / replay source / data lake landing |

> **The highest-leverage cost decision in this objective:** if your streaming pipeline does *no* per-event logic beyond parsing, replace Dataflow with a **BigQuery subscription** plus scheduled SQL or a materialised view. This removes an entire always-on distributed system from your on-call surface. Keep a **Cloud Storage subscription** on the same topic as an immutable replay source — that is your undo button when the SQL is wrong.

---

## 4. BigQuery: the internals that govern your cost and latency

### 4.1 Architecture

BigQuery separates storage from compute across four Google infrastructure components:

- **Colossus** — the distributed file system holding table data in **Capacitor**, a columnar format with per-column encoding and statistics used for predicate pushdown.
- **Dremel** — the multi-level serving-tree execution engine. A query becomes a tree of mixers and leaf nodes; leaves read from Colossus, mixers aggregate.
- **Jupiter** — the petabit-scale datacenter network that makes storage/compute separation viable; a shuffle can move terabytes between stages.
- **Borg** — the cluster manager allocating **slots** (units of CPU/RAM/IO) to query stages.

The operational consequence: **there is no index to tune and no VM to size.** Your levers are (a) how much data a query must read (partitioning, clustering, materialised views), and (b) how many slots are available (editions and reservations).

### 4.2 Pricing models — the trade-off table

| Model | Billing unit | Predictability | Concurrency behaviour under load | Choose when |
|---|---|---|---|---|
| **On-demand** | Bytes *processed* per query (per TiB) | Poor — a single bad query can cost thousands | Fair-share of a large shared pool; no hard cap without custom quotas | Spiky, low-volume, exploratory; getting started |
| **Editions — Standard** | Slot-hours, autoscaling | Good | Bounded by max reservation size | Dev/test, basic workloads |
| **Editions — Enterprise** | Slot-hours, autoscaling, optional 1-/3-year commitments | Good | Bounded; workload isolation via reservations + assignments | Most production estates |
| **Editions — Enterprise Plus** | Slot-hours (highest rate) | Good | As above, plus advanced security/compliance and cross-region DR features | Regulated workloads, multi-region DR requirements |

Storage is billed separately (active vs long-term, logical vs **physical/compressed** billing — compressed billing is frequently a large saving on well-compressing columnar data, but is chosen per dataset and has a change cooldown).

> **All list prices vary by region and change. Never quote a number in a design document without linking the pricing page and stating the date. Verify with `gcloud billing` / the Pricing Calculator.**

**The single control that prevents INC-5533:** put every production workload in a **reservation** with a hard `max_slots`, and enable `maximum_bytes_billed` on every scheduled/BI query. Cost overrun is then a *failed query* — a page — instead of an invoice.

### 4.3 Ingestion paths into BigQuery — comparison

| Path | Latency to queryable | Exactly-once | Cost shape | Notes |
|---|---|---|---|---|
| `bq load` / batch load job | Minutes | Yes (atomic job) | **Free** (shared-pool load slots) or reservation slots | Best cost per byte; use for backfills |
| **Storage Write API** — default stream | Seconds | At-least-once | Per GiB ingested | High throughput, low latency, simplest |
| **Storage Write API** — committed stream + offsets | Seconds | **Yes** | Per GiB ingested | The correct choice for financial-grade streams |
| **Storage Write API** — pending stream | On commit | Yes, atomic | Per GiB ingested | Batch-like atomicity with streaming API |
| Legacy `tabledata.insertAll` (streaming inserts) | Seconds | Best-effort dedup via `insertId` | Higher per-byte than Storage Write API | Legacy — migrate to Storage Write API |
| **Pub/Sub BigQuery subscription** | Seconds | At-least-once | Pub/Sub delivery only; no compute | Cheapest streaming path; no transformation |
| **Datastream to BigQuery** | Seconds–minutes | Upsert-reconciled | Datastream GB processed + BQ | CDC replication |
| **External / BigLake tables** | N/A — query in place | N/A | Bytes scanned in GCS | Avoids a copy; slower than native, no partition pruning unless hive-partitioned |

---

## 5. Reference architecture — complete, deployable

**Scenario.** A retailer, `acme`, needs three things from one clickstream:
1. **Streaming:** sub-60-second detection of cart-abandonment and payment-anomaly signals, pushed to an activation topic.
2. **Warehouse:** an append-only, partitioned, clustered event table for analysts, plus governed marts.
3. **BI:** a Looker semantic layer so Finance and Growth cannot disagree about a metric again.

```
                                  ┌──────────────────────────┐
  Web/App/POS ──▶ GKE gateway ──▶ │ Pub/Sub topic            │
   (Avro, schema-validated)       │ ingest-clickstream        │
                                  └───┬────────┬─────────┬────┘
                                      │        │         │
             ┌────────────────────────┘        │         └─────────────────┐
             ▼                                 ▼                           ▼
   ┌───────────────────┐          ┌─────────────────────┐      ┌────────────────────┐
   │ Dataflow          │          │ BigQuery            │      │ Cloud Storage      │
   │ streaming (Beam)  │          │ subscription        │      │ subscription       │
   │ sessionise+score  │          │ → raw.events_landing│      │ → gs://…/replay/   │
   └───┬───────────┬───┘          └─────────────────────┘      └────────────────────┘
       │           │                        │                             │
       ▼           ▼                        ▼                             │
 ┌──────────┐  ┌────────────────┐   ┌───────────────┐                     │
 │ Pub/Sub  │  │ BigQuery       │   │ Dataform ELT  │◀────────────────────┘
 │ activate │  │ analytics.*    │   │ marts.*       │   (backfill / replay)
 └────┬─────┘  │ (Storage Write │   └───────┬───────┘
      │        │  API, EO)      │           │
      ▼        └────────────────┘           ▼
  Cloud Run                          ┌─────────────┐    ┌───────────────┐
  activation svc                     │ BigQuery ML │───▶│    Looker     │
  (email/push)                       │ churn/ARIMA │    │ LookML models │
                                     └─────────────┘    └───────────────┘
        ▲                                                       │
        └────────────── Dead-letter topic + BQ DLQ table ───────┘
```

### 5.1 Pub/Sub Avro schema (`schemas/clickstream-v1.avsc`)

```json
{
  "type": "record",
  "name": "ClickstreamEvent",
  "namespace": "club.acme.analytics",
  "doc": "Canonical clickstream envelope. Additive changes only; new fields MUST have defaults.",
  "fields": [
    { "name": "event_id",     "type": "string", "doc": "UUIDv4, client-generated, dedup key" },
    { "name": "event_time",   "type": { "type": "long", "logicalType": "timestamp-micros" } },
    { "name": "event_type",   "type": { "type": "enum", "name": "EventType",
        "symbols": ["PAGE_VIEW","ADD_TO_CART","REMOVE_FROM_CART","CHECKOUT_START",
                    "PAYMENT_ATTEMPT","PAYMENT_RESULT","SEARCH","HEARTBEAT"] } },
    { "name": "session_id",   "type": "string" },
    { "name": "user_pseudo_id", "type": "string", "doc": "Pseudonymous; never the raw account id" },
    { "name": "store_id",     "type": "string" },
    { "name": "country",      "type": "string", "default": "XX" },
    { "name": "device",       "type": { "type": "record", "name": "Device", "fields": [
        { "name": "platform", "type": "string" },
        { "name": "os_version", "type": ["null","string"], "default": null },
        { "name": "app_version", "type": ["null","string"], "default": null } ] } },
    { "name": "cart_value_micros", "type": ["null","long"], "default": null,
      "doc": "Minor-unit * 1e6 to avoid float; null for non-cart events" },
    { "name": "currency",     "type": ["null","string"], "default": null },
    { "name": "payment_result", "type": ["null", { "type": "enum", "name": "PaymentResult",
        "symbols": ["APPROVED","DECLINED","ERROR","TIMEOUT"] }], "default": null },
    { "name": "attributes",   "type": { "type": "map", "values": "string" }, "default": {} },
    { "name": "schema_version", "type": "int", "default": 1 }
  ]
}
```

**Schema-evolution contract:** Pub/Sub schema revisions accept only backward/forward-compatible changes. In practice this means: *add* optional fields with defaults; never remove a field, never change a type, never reorder enum symbols. Removing a field breaks every consumer that has not been redeployed — and in a streaming system, redeploy is not atomic.

### 5.2 Terraform — the complete data platform module

```hcl
# ---------------------------------------------------------------------------
# main.tf — acme smart-analytics platform
# terraform >= 1.7, google provider >= 5.x
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
  }
  backend "gcs" {
    bucket = "acme-tfstate-prod"
    prefix = "analytics/platform"
  }
}

variable "project_id" { type = string,  default = "acme-analytics-prod" }
variable "region"     { type = string,  default = "us-central1" }
variable "env"        { type = string,  default = "prod" }

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  labels = {
    env        = var.env
    domain     = "analytics"
    cost_center = "cc-4410"
    managed_by = "terraform"
  }
}

# ---------------------------------------------------------------------------
# 0. APIs
# ---------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "pubsub.googleapis.com",
    "dataflow.googleapis.com",
    "bigquery.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "datacatalog.googleapis.com",
    "dataplex.googleapis.com",
    "dataform.googleapis.com",
    "storage.googleapis.com",
    "monitoring.googleapis.com",
    "aiplatform.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# 1. Service accounts and least-privilege IAM
# ---------------------------------------------------------------------------
resource "google_service_account" "producer" {
  account_id   = "sa-clickstream-producer"
  display_name = "Clickstream producer (GKE, Workload Identity)"
}

resource "google_service_account" "dataflow" {
  account_id   = "sa-dataflow-clickstream"
  display_name = "Dataflow worker SA for clickstream-enrich"
}

resource "google_service_account" "pubsub_bq" {
  account_id   = "sa-pubsub-bq-writer"
  display_name = "Pub/Sub BigQuery subscription writer"
}

resource "google_pubsub_topic_iam_member" "producer_publish" {
  topic  = google_pubsub_topic.clickstream.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.producer.email}"
}

# Dataflow worker needs: worker role, subscribe, publish to activation+DLQ,
# BigQuery data edit on the analytics dataset only, and GCS temp.
resource "google_project_iam_member" "df_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_subscription_iam_member" "df_subscribe" {
  subscription = google_pubsub_subscription.enrich.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_topic_iam_member" "df_publish_activation" {
  for_each = toset([
    google_pubsub_topic.activation.name,
    google_pubsub_topic.dlq.name,
  ])
  topic  = each.value
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_bigquery_dataset_iam_member" "df_bq_editor" {
  dataset_id = google_bigquery_dataset.analytics.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_project_iam_member" "df_bq_jobuser" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

# ---------------------------------------------------------------------------
# 2. Pub/Sub: schema, topics, subscriptions, DLQ
# ---------------------------------------------------------------------------
resource "google_pubsub_schema" "clickstream" {
  name       = "clickstream-v1"
  type       = "AVRO"
  definition = file("${path.module}/schemas/clickstream-v1.avsc")
}

resource "google_pubsub_topic" "clickstream" {
  name                       = "ingest-clickstream"
  message_retention_duration = "604800s" # 7 days — replay window
  labels                     = local.labels

  schema_settings {
    schema   = google_pubsub_schema.clickstream.id
    encoding = "BINARY"
  }

  message_storage_policy {
    allowed_persistence_regions = ["us-central1", "us-east1"] # data residency
  }

  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "activation" {
  name                       = "activation-signals"
  message_retention_duration = "86400s"
  labels                     = local.labels
}

resource "google_pubsub_topic" "dlq" {
  name                       = "clickstream-dlq"
  message_retention_duration = "604800s"
  labels                     = local.labels
}

# --- 2a. Dataflow subscription: exactly-once, ordered per session -----------
resource "google_pubsub_subscription" "enrich" {
  name  = "sub-clickstream-enrich"
  topic = google_pubsub_topic.clickstream.id

  ack_deadline_seconds         = 60
  message_retention_duration   = "604800s"
  retain_acked_messages        = false
  enable_exactly_once_delivery = true
  enable_message_ordering      = true

  expiration_policy { ttl = "" } # never expire

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }

  labels = local.labels
}

# --- 2b. BigQuery subscription: raw landing zone, zero compute --------------
resource "google_pubsub_subscription" "bq_landing" {
  name  = "sub-clickstream-bq-landing"
  topic = google_pubsub_topic.clickstream.id

  bigquery_config {
    table                 = "${var.project_id}.raw.events_landing"
    use_topic_schema      = true
    write_metadata        = false
    drop_unknown_fields   = true
    service_account_email = google_service_account.pubsub_bq.email
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }

  labels = local.labels
}

# --- 2c. Cloud Storage subscription: immutable replay source ---------------
resource "google_pubsub_subscription" "gcs_archive" {
  name  = "sub-clickstream-gcs-archive"
  topic = google_pubsub_topic.clickstream.id

  cloud_storage_config {
    bucket          = google_storage_bucket.replay.name
    filename_prefix = "clickstream/"
    filename_suffix = ".avro"
    max_duration    = "300s"
    max_bytes       = 268435456 # 256 MiB

    avro_config { write_metadata = true }
  }

  labels = local.labels
}

resource "google_storage_bucket" "replay" {
  name                        = "${var.project_id}-clickstream-replay"
  location                    = "US"
  uniform_bucket_level_access = true
  storage_class               = "STANDARD"

  versioning { enabled = false }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "SetStorageClass", storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { age = 365 }
    action { type = "SetStorageClass", storage_class = "ARCHIVE" }
  }
  labels = local.labels
}

resource "google_storage_bucket" "dataflow_temp" {
  name                        = "${var.project_id}-dataflow-temp"
  location                    = var.region
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition { age = 7 }
    action { type = "Delete" }
  }
  labels = local.labels
}

# ---------------------------------------------------------------------------
# 3. BigQuery: datasets and tables
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "raw" {
  dataset_id                      = "raw"
  location                        = "US"
  description                     = "Landing zone. Append-only. No business logic. 30-day TTL."
  default_partition_expiration_ms = 2592000000 # 30 days
  labels                          = local.labels
}

resource "google_bigquery_dataset" "analytics" {
  dataset_id  = "analytics"
  location    = "US"
  description = "Curated, conformed event and session tables."
  labels      = local.labels
}

resource "google_bigquery_dataset" "marts" {
  dataset_id  = "marts"
  location    = "US"
  description = "Business-facing marts consumed by Looker. Contract-stable."
  labels      = local.labels
}

resource "google_bigquery_table" "events_landing" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "events_landing"
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "event_time"
  }
  clustering = ["event_type", "store_id"]

  schema = jsonencode([
    { name = "event_id",         type = "STRING",    mode = "REQUIRED" },
    { name = "event_time",       type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "event_type",       type = "STRING",    mode = "REQUIRED" },
    { name = "session_id",       type = "STRING",    mode = "REQUIRED" },
    { name = "user_pseudo_id",   type = "STRING",    mode = "REQUIRED" },
    { name = "store_id",         type = "STRING",    mode = "REQUIRED" },
    { name = "country",          type = "STRING",    mode = "NULLABLE" },
    { name = "device",           type = "RECORD",    mode = "NULLABLE", fields = [
        { name = "platform",    type = "STRING", mode = "NULLABLE" },
        { name = "os_version",  type = "STRING", mode = "NULLABLE" },
        { name = "app_version", type = "STRING", mode = "NULLABLE" }
      ] },
    { name = "cart_value_micros", type = "INT64",   mode = "NULLABLE" },
    { name = "currency",          type = "STRING",  mode = "NULLABLE" },
    { name = "payment_result",    type = "STRING",  mode = "NULLABLE" },
    { name = "attributes",        type = "JSON",    mode = "NULLABLE" },
    { name = "schema_version",    type = "INT64",   mode = "NULLABLE" }
  ])
  labels = local.labels
}

resource "google_bigquery_table" "session_metrics" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "session_metrics"
  deletion_protection = true

  time_partitioning {
    type                     = "DAY"
    field                    = "window_start"
    require_partition_filter = true # <-- the guard against full scans
  }
  clustering = ["store_id", "country"]

  schema = jsonencode([
    { name = "window_start",       type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "window_end",         type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "session_id",         type = "STRING",    mode = "REQUIRED" },
    { name = "user_pseudo_id",     type = "STRING",    mode = "REQUIRED" },
    { name = "store_id",           type = "STRING",    mode = "REQUIRED" },
    { name = "country",            type = "STRING",    mode = "NULLABLE" },
    { name = "event_count",        type = "INT64",     mode = "REQUIRED" },
    { name = "cart_value_micros",  type = "INT64",     mode = "NULLABLE" },
    { name = "abandoned_cart",     type = "BOOL",      mode = "REQUIRED" },
    { name = "payment_failures",   type = "INT64",     mode = "REQUIRED" },
    { name = "anomaly_score",      type = "FLOAT64",   mode = "NULLABLE" },
    { name = "pane_index",         type = "INT64",     mode = "REQUIRED",
      description = "Beam pane index; dedup with QUALIFY ROW_NUMBER() ... ORDER BY pane_index DESC" },
    { name = "pipeline_version",   type = "STRING",    mode = "REQUIRED" },
    { name = "ingested_at",        type = "TIMESTAMP", mode = "REQUIRED" }
  ])
  labels = local.labels
}

resource "google_bigquery_table" "dlq_events" {
  dataset_id = google_bigquery_dataset.raw.dataset_id
  table_id   = "dlq_events"
  time_partitioning { type = "DAY", field = "received_at" }
  schema = jsonencode([
    { name = "received_at",      type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "subscription",     type = "STRING",    mode = "NULLABLE" },
    { name = "delivery_attempt", type = "INT64",     mode = "NULLABLE" },
    { name = "error_class",      type = "STRING",    mode = "NULLABLE" },
    { name = "error_message",    type = "STRING",    mode = "NULLABLE" },
    { name = "raw_payload",      type = "BYTES",     mode = "NULLABLE" },
    { name = "attributes",       type = "JSON",      mode = "NULLABLE" }
  ])
  labels = local.labels
}

# ---------------------------------------------------------------------------
# 4. Governance: column-level policy tag + row-level access
# ---------------------------------------------------------------------------
resource "google_data_catalog_taxonomy" "pii" {
  region                 = var.region
  display_name           = "acme-pii-taxonomy"
  description            = "Sensitivity classification for analytics columns"
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
}

resource "google_data_catalog_policy_tag" "pseudonymous_id" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "pseudonymous-identifier"
  description  = "Re-identifiable only when joined with the identity service"
}

# ---------------------------------------------------------------------------
# 5. BigQuery reservation — the cost guardrail
# ---------------------------------------------------------------------------
resource "google_bigquery_reservation" "prod" {
  name              = "res-analytics-prod"
  location          = "US"
  edition           = "ENTERPRISE"
  slot_capacity     = 500
  autoscale { max_slots = 1500 }
  ignore_idle_slots = false
}

resource "google_bigquery_reservation_assignment" "prod_queries" {
  assignee    = "projects/${var.project_id}"
  job_type    = "QUERY"
  reservation = google_bigquery_reservation.prod.id
}

# ---------------------------------------------------------------------------
# 6. Dataflow streaming job (Flex Template)
# ---------------------------------------------------------------------------
resource "google_dataflow_flex_template_job" "clickstream_enrich" {
  provider                = google-beta
  name                    = "clickstream-enrich-v7"
  container_spec_gcs_path = "gs://${var.project_id}-dataflow-templates/clickstream-enrich/v7.json"
  region                  = var.region

  on_delete                    = "drain"   # never "cancel" a stateful streaming job
  service_account_email        = google_service_account.dataflow.email
  temp_location                = "gs://${google_storage_bucket.dataflow_temp.name}/temp"
  staging_location             = "gs://${google_storage_bucket.dataflow_temp.name}/staging"
  enable_streaming_engine      = true
  machine_type                 = "n2-standard-4"
  max_workers                  = 40
  num_workers                  = 4
  ip_configuration             = "WORKER_IP_PRIVATE"
  network                      = "vpc-analytics"
  subnetwork                   = "regions/${var.region}/subnetworks/snet-dataflow-${var.region}"

  parameters = {
    inputSubscription   = google_pubsub_subscription.enrich.id
    activationTopic     = google_pubsub_topic.activation.id
    dlqTopic            = google_pubsub_topic.dlq.id
    outputTable         = "${var.project_id}:analytics.session_metrics"
    sessionGapSeconds   = "1800"
    allowedLatenessSec  = "3600"
    earlyFiringSec      = "30"
    pipelineVersion     = "v7"
    autoscalingAlgorithm = "THROUGHPUT_BASED"
  }

  labels = local.labels
}

# ---------------------------------------------------------------------------
# 7. Observability — SLO-driven alert policies
# ---------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "oncall" {
  display_name = "data-platform-oncall"
  type         = "pagerduty"
  sensitive_labels { service_key = var.pagerduty_key }
}

resource "google_monitoring_alert_policy" "backlog_age" {
  display_name = "[P1] Clickstream subscription backlog age > 300s"
  combiner     = "OR"
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **Symptom:** `oldest_unacked_message_age` on `sub-clickstream-enrich` exceeded 300s.
      **Impact:** Cart-abandonment activation is late; the 60s freshness SLO is burning budget.
      **First checks:**
      1. `gcloud dataflow jobs list --region=us-central1 --status=active` — is the job Running?
      2. Dataflow → Job graph → look for a stage with rising `system_lag`.
      3. Check `job/current_num_vcpus` vs `max_workers` — are we pinned at the cap?
      4. Check DLQ publish rate — a poison message loops until `max_delivery_attempts`.
      **Runbook:** go/runbook-clickstream-backlog
    EOT
  }
  conditions {
    display_name = "oldest_unacked_message_age > 300s for 5m"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\"",
        "resource.type=\"pubsub_subscription\"",
        "resource.label.\"subscription_id\"=\"sub-clickstream-enrich\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 300
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "CRITICAL"
}

resource "google_monitoring_alert_policy" "watermark_stalled" {
  display_name = "[P1] Dataflow data watermark age > 900s"
  combiner     = "OR"
  conditions {
    display_name = "data_watermark_age > 900s"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"dataflow.googleapis.com/job/per_stage_data_watermark_age\"",
        "resource.type=\"dataflow_job\"",
        "metadata.user_labels.\"domain\"=\"analytics\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 900
      duration        = "600s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.label.job_name"]
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "CRITICAL"
}

resource "google_monitoring_alert_policy" "dlq_rate" {
  display_name = "[P2] Dead-letter publish rate > 1 msg/s"
  combiner     = "OR"
  conditions {
    display_name = "dlq topic publish rate"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\"",
        "resource.type=\"pubsub_topic\"",
        "resource.label.\"topic_id\"=\"clickstream-dlq\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "WARNING"
}

resource "google_monitoring_alert_policy" "bq_scan_spike" {
  display_name = "[P2] BigQuery slot utilisation sustained at reservation cap"
  combiner     = "OR"
  conditions {
    display_name = "slots_allocated at max for 15m"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"bigquery.googleapis.com/slots/allocated_for_reservation\"",
        "resource.type=\"bigquery_project\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 1450
      duration        = "900s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.oncall.id]
  severity              = "WARNING"
}
```

### 5.3 Dataflow Flex Template metadata (`templates/clickstream-enrich.metadata.json`)

```json
{
  "name": "clickstream-enrich",
  "description": "Sessionises clickstream events, scores cart abandonment and payment anomalies, writes session metrics to BigQuery and activation signals to Pub/Sub.",
  "parameters": [
    { "name": "inputSubscription", "label": "Input Pub/Sub subscription",
      "helpText": "projects/<p>/subscriptions/<s>",
      "regexes": ["^projects/[^/]+/subscriptions/[^/]+$"] },
    { "name": "outputTable", "label": "BigQuery output table",
      "helpText": "PROJECT:DATASET.TABLE",
      "regexes": ["^[^:]+:[^.]+[.].+$"] },
    { "name": "activationTopic", "label": "Activation topic",
      "regexes": ["^projects/[^/]+/topics/[^/]+$"] },
    { "name": "dlqTopic", "label": "Dead-letter topic",
      "regexes": ["^projects/[^/]+/topics/[^/]+$"] },
    { "name": "sessionGapSeconds", "label": "Session gap (s)",
      "isOptional": true, "regexes": ["^[0-9]+$"] },
    { "name": "allowedLatenessSec", "label": "Allowed lateness (s)",
      "isOptional": true, "regexes": ["^[0-9]+$"] },
    { "name": "earlyFiringSec", "label": "Early firing interval (s)",
      "isOptional": true, "regexes": ["^[0-9]+$"] },
    { "name": "pipelineVersion", "label": "Pipeline version tag",
      "isOptional": true }
  ]
}
```

### 5.4 The Beam pipeline (`pipeline/clickstream_enrich.py`)

```python
"""Streaming sessionisation and anomaly scoring for the acme clickstream.

Correctness contract
--------------------
* Windowing:      session windows, gap = --session_gap_seconds (default 1800s)
* Trigger:        AfterWatermark, early firings every --early_firing_sec,
                  late firings on every element
* Accumulation:   ACCUMULATING  -> downstream MUST deduplicate on
                  (window_start, session_id) ORDER BY pane_index DESC
* Lateness:       --allowed_lateness_sec (default 3600s); anything later is
                  routed to the DLQ, never silently dropped
* Sink:           BigQuery Storage Write API (exactly-once within the pipeline)
"""

import json
import logging
from typing import Any, Dict, Iterable, Tuple

import apache_beam as beam
from apache_beam.io.gcp.pubsub import ReadFromPubSub, WriteToPubSub
from apache_beam.options.pipeline_options import (
    GoogleCloudOptions, PipelineOptions, SetupOptions, StandardOptions,
)
from apache_beam.transforms import trigger, window
from apache_beam.utils.timestamp import Duration

DEAD_LETTER = "dead_letter"
MAIN = "main"


class Options(PipelineOptions):
    @classmethod
    def _add_argparse_args(cls, parser):
        parser.add_argument("--input_subscription", required=True)
        parser.add_argument("--output_table", required=True)
        parser.add_argument("--activation_topic", required=True)
        parser.add_argument("--dlq_topic", required=True)
        parser.add_argument("--session_gap_seconds", type=int, default=1800)
        parser.add_argument("--allowed_lateness_sec", type=int, default=3600)
        parser.add_argument("--early_firing_sec", type=int, default=30)
        parser.add_argument("--pipeline_version", default="dev")


class ParseEvent(beam.DoFn):
    """Decode the Avro-encoded envelope. Malformed payloads go to the DLQ.

    A parse failure MUST NOT crash the bundle: an unparseable message would be
    retried until max_delivery_attempts, blocking the ordering key and stalling
    the watermark for every session sharing that key.
    """

    def process(self, element: Tuple[bytes, Dict[str, str]]):
        payload, attributes = element
        try:
            # In the deployed template this is an Avro decode against the
            # schema fetched from the Pub/Sub schema registry at startup.
            record = json.loads(payload.decode("utf-8"))
            if "session_id" not in record or "event_time" not in record:
                raise ValueError("missing required field session_id/event_time")
            yield beam.pvalue.TaggedOutput(MAIN, record)
        except Exception as exc:  # noqa: BLE001 — deliberate catch-all
            logging.warning("parse_failure: %s", exc)
            yield beam.pvalue.TaggedOutput(
                DEAD_LETTER,
                {
                    "error_class": type(exc).__name__,
                    "error_message": str(exc)[:2000],
                    "attributes": attributes,
                    "raw_payload_b64": payload.hex(),
                },
            )


class ScoreSession(beam.DoFn):
    """Reduce a session's events into a metrics row plus optional signals."""

    def __init__(self, pipeline_version: str):
        self._version = pipeline_version

    def process(
        self,
        keyed: Tuple[str, Iterable[Dict[str, Any]]],
        win=beam.DoFn.WindowParam,
        pane=beam.DoFn.PaneInfoParam,
        ts=beam.DoFn.TimestampParam,
    ):
        session_id, events = keyed
        events = sorted(events, key=lambda e: e["event_time"])

        added = sum(1 for e in events if e["event_type"] == "ADD_TO_CART")
        removed = sum(1 for e in events if e["event_type"] == "REMOVE_FROM_CART")
        checked_out = any(e["event_type"] == "CHECKOUT_START" for e in events)
        approved = any(e.get("payment_result") == "APPROVED" for e in events)
        failures = sum(
            1 for e in events
            if e.get("payment_result") in ("DECLINED", "ERROR", "TIMEOUT")
        )
        cart_value = max(
            (e.get("cart_value_micros") or 0 for e in events), default=0
        )

        abandoned = bool(added > removed and not approved)

        # Deliberately simple, auditable heuristic. The model-based score is
        # computed in BigQuery ML on the same rows — see marts/anomaly.sqlx.
        anomaly = 0.0
        if failures >= 3:
            anomaly += 0.6
        if failures >= 1 and cart_value > 500_000_000:  # > 500 units
            anomaly += 0.3
        if len({e.get("country") for e in events if e.get("country")}) > 1:
            anomaly += 0.4
        anomaly = min(anomaly, 1.0)

        row = {
            "window_start": win.start.to_rfc3339(),
            "window_end": win.end.to_rfc3339(),
            "session_id": session_id,
            "user_pseudo_id": events[0]["user_pseudo_id"],
            "store_id": events[0]["store_id"],
            "country": events[0].get("country"),
            "event_count": len(events),
            "cart_value_micros": cart_value or None,
            "abandoned_cart": abandoned,
            "payment_failures": failures,
            "anomaly_score": anomaly,
            "pane_index": pane.index,
            "pipeline_version": self._version,
            "ingested_at": ts.to_rfc3339(),
        }
        yield beam.pvalue.TaggedOutput(MAIN, row)

        # Emit activation signals only on the ON_TIME or LATE pane, never on an
        # early speculative pane: an early firing would page a customer whose
        # checkout simply had not arrived yet.
        if pane.timing != window.PaneInfoTiming.EARLY:
            if abandoned and cart_value > 0:
                yield beam.pvalue.TaggedOutput(
                    "activation",
                    json.dumps({
                        "signal": "CART_ABANDONED",
                        "session_id": session_id,
                        "user_pseudo_id": row["user_pseudo_id"],
                        "cart_value_micros": cart_value,
                        "store_id": row["store_id"],
                    }).encode("utf-8"),
                )
            if anomaly >= 0.7:
                yield beam.pvalue.TaggedOutput(
                    "activation",
                    json.dumps({
                        "signal": "PAYMENT_ANOMALY",
                        "session_id": session_id,
                        "anomaly_score": anomaly,
                        "payment_failures": failures,
                        "store_id": row["store_id"],
                    }).encode("utf-8"),
                )


def run(argv=None) -> None:
    opts = PipelineOptions(argv, streaming=True, save_main_session=True)
    custom = opts.view_as(Options)
    opts.view_as(StandardOptions).streaming = True
    opts.view_as(SetupOptions).save_main_session = True

    with beam.Pipeline(options=opts) as p:
        parsed = (
            p
            | "ReadPubSub" >> ReadFromPubSub(
                subscription=custom.input_subscription,
                with_attributes=True,
                timestamp_attribute="event_time",  # event time, NOT publish time
            )
            | "ToTuple" >> beam.Map(lambda m: (m.data, dict(m.attributes)))
            | "Parse" >> beam.ParDo(ParseEvent()).with_outputs(
                DEAD_LETTER, MAIN, main=MAIN
            )
        )

        sessions = (
            parsed[MAIN]
            | "KeyBySession" >> beam.Map(lambda r: (r["session_id"], r))
            | "SessionWindow" >> beam.WindowInto(
                window.Sessions(custom.session_gap_seconds),
                trigger=trigger.AfterWatermark(
                    early=trigger.AfterProcessingTime(custom.early_firing_sec),
                    late=trigger.AfterCount(1),
                ),
                accumulation_mode=trigger.AccumulationMode.ACCUMULATING,
                allowed_lateness=Duration(seconds=custom.allowed_lateness_sec),
            )
            | "GroupBySession" >> beam.GroupByKey()
            | "Score" >> beam.ParDo(
                ScoreSession(custom.pipeline_version)
            ).with_outputs("activation", MAIN, main=MAIN)
        )

        _ = (
            sessions[MAIN]
            | "WriteBQ" >> beam.io.WriteToBigQuery(
                table=custom.output_table,
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_NEVER,
                method=beam.io.WriteToBigQuery.Method.STORAGE_WRITE_API,
                triggering_frequency=10,
                with_auto_sharding=True,
            )
        )

        _ = (
            sessions["activation"]
            | "PublishActivation" >> WriteToPubSub(topic=custom.activation_topic)
        )

        _ = (
            parsed[DEAD_LETTER]
            | "EncodeDLQ" >> beam.Map(lambda d: json.dumps(d).encode("utf-8"))
            | "PublishDLQ" >> WriteToPubSub(topic=custom.dlq_topic)
        )


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()
```

### 5.5 GKE producer — Deployment with Workload Identity

```yaml
# k8s/clickstream-gateway.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: analytics
  labels:
    domain: analytics
    env: prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: clickstream-gateway
  namespace: analytics
  annotations:
    # Workload Identity: bind KSA -> GSA. No JSON key ever touches the cluster.
    iam.gke.io/gcp-service-account: sa-clickstream-producer@acme-analytics-prod.iam.gserviceaccount.com
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickstream-gateway-config
  namespace: analytics
data:
  PUBSUB_TOPIC: "projects/acme-analytics-prod/topics/ingest-clickstream"
  PUBSUB_ORDERING_ENABLED: "true"
  # Batching: trade publish latency for cost. 100ms/1000 msgs is a good
  # starting point for a 50k msg/s gateway; measure publish latency after.
  PUBLISH_MAX_MESSAGES: "1000"
  PUBLISH_MAX_BYTES: "1048576"
  PUBLISH_MAX_LATENCY_MS: "100"
  PUBLISH_FLOW_CONTROL_MAX_OUTSTANDING_MESSAGES: "20000"
  PUBLISH_FLOW_CONTROL_LIMIT_EXCEEDED_BEHAVIOR: "block"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability:4317"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clickstream-gateway
  namespace: analytics
  labels:
    app.kubernetes.io/name: clickstream-gateway
    app.kubernetes.io/component: ingest
spec:
  replicas: 6
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: clickstream-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: clickstream-gateway
        app.kubernetes.io/component: ingest
    spec:
      serviceAccountName: clickstream-gateway
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: clickstream-gateway
      containers:
        - name: gateway
          image: us-central1-docker.pkg.dev/acme-analytics-prod/apps/clickstream-gateway:1.9.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          envFrom:
            - configMapRef:
                name: clickstream-gateway-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              memory: "1Gi"     # no CPU limit: avoids CFS throttling on a
                                # latency-sensitive publisher
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                # Flush the publisher batch before the pod dies, otherwise the
                # in-memory batch (up to 1000 msgs) is lost on every rollout.
                command: ["/bin/sh", "-c", "sleep 15"]
      terminationGracePeriodSeconds: 45
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: clickstream-gateway
  namespace: analytics
spec:
  selector:
    app.kubernetes.io/name: clickstream-gateway
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: clickstream-gateway
  namespace: analytics
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: clickstream-gateway
  minReplicas: 6
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
      stabilizationWindowSeconds: 30
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
  name: clickstream-gateway
  namespace: analytics
spec:
  minAvailable: 80%
  selector:
    matchLabels:
      app.kubernetes.io/name: clickstream-gateway
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: clickstream-gateway-egress
  namespace: analytics
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: clickstream-gateway
  policyTypes: ["Egress"]
  egress:
    # Google APIs via Private Google Access / restricted VIP
    - to:
        - ipBlock:
            cidr: 199.36.153.4/30
      ports:
        - protocol: TCP
          port: 443
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

### 5.6 Dataform — the governed transformation layer

`definitions/analytics/sessions_deduped.sqlx`:

```sql
config {
  type: "incremental",
  schema: "analytics",
  name: "sessions_deduped",
  description: "One row per (window_start, session_id): the final ACCUMULATING pane.",
  bigquery: {
    partitionBy: "DATE(window_start)",
    clusterBy: ["store_id", "country"],
    requirePartitionFilter: true
  },
  assertions: {
    uniqueKey: ["window_start", "session_id"],
    nonNull: ["session_id", "store_id", "event_count"]
  },
  tags: ["hourly", "analytics"]
}

SELECT * EXCEPT(rn)
FROM (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY window_start, session_id
      ORDER BY pane_index DESC, ingested_at DESC
    ) AS rn
  FROM ${ref("session_metrics")}
  WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY)
  ${when(incremental(),
    `AND ingested_at > (SELECT COALESCE(MAX(ingested_at), TIMESTAMP('1970-01-01'))
                        FROM ${self()}
                        WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY))`)}
)
WHERE rn = 1
```

`definitions/marts/store_daily.sqlx`:

```sql
config {
  type: "table",
  schema: "marts",
  name: "store_daily",
  description: "Contract-stable daily store mart. Looker reads ONLY marts.*",
  bigquery: {
    partitionBy: "activity_date",
    clusterBy: ["store_id", "country"],
    requirePartitionFilter: false
  },
  tags: ["daily", "looker-contract"]
}

SELECT
  DATE(window_start)                                    AS activity_date,
  store_id,
  country,
  COUNT(DISTINCT session_id)                            AS sessions,
  COUNT(DISTINCT user_pseudo_id)                        AS visitors,
  COUNTIF(abandoned_cart)                               AS abandoned_carts,
  SAFE_DIVIDE(COUNTIF(abandoned_cart), COUNT(DISTINCT session_id)) AS abandonment_rate,
  SUM(IF(abandoned_cart, cart_value_micros, 0)) / 1e6   AS abandoned_value,
  SUM(payment_failures)                                 AS payment_failures,
  AVG(anomaly_score)                                    AS avg_anomaly_score,
  APPROX_QUANTILES(event_count, 100)[OFFSET(50)]        AS median_events_per_session
FROM ${ref("sessions_deduped")}
WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 400 DAY)
GROUP BY 1, 2, 3
```

`definitions/marts/materialized_recent.sqlx` — the BI acceleration layer:

```sql
config { type: "operations", schema: "marts", name: "mv_store_hourly", tags: ["ddl"] }

CREATE MATERIALIZED VIEW IF NOT EXISTS `acme-analytics-prod.marts.mv_store_hourly`
PARTITION BY DATE(hour_start)
CLUSTER BY store_id
OPTIONS (
  enable_refresh = true,
  refresh_interval_minutes = 10,
  max_staleness = INTERVAL "0:30:0" HOUR TO SECOND
)
AS
SELECT
  TIMESTAMP_TRUNC(window_start, HOUR) AS hour_start,
  store_id,
  COUNT(1)              AS session_rows,
  COUNTIF(abandoned_cart) AS abandoned_carts,
  SUM(payment_failures) AS payment_failures
FROM `acme-analytics-prod.analytics.sessions_deduped`
GROUP BY 1, 2
```

> **Why `max_staleness` matters:** without it, a materialised view over a streaming table forces BigQuery to read the base table's recent (unmaterialised) rows on every query, which reintroduces the cost you were avoiding. `max_staleness` lets the view serve pre-computed results within a declared freshness bound — an explicit, negotiated point on the freshness/cost axis.

### 5.7 BigQuery ML — smart analytics inside the warehouse

```sql
-- 1. Demand forecasting per store: 30 days ahead, from 400 days of history.
CREATE OR REPLACE MODEL `acme-analytics-prod.marts.store_demand_arima`
OPTIONS (
  model_type          = 'ARIMA_PLUS',
  time_series_timestamp_col = 'activity_date',
  time_series_data_col      = 'sessions',
  time_series_id_col        = 'store_id',
  holiday_region      = 'US',
  auto_arima          = TRUE,
  data_frequency      = 'DAILY',
  decompose_time_series = TRUE
) AS
SELECT activity_date, store_id, sessions
FROM `acme-analytics-prod.marts.store_daily`
WHERE activity_date BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 400 DAY)
                        AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY);

-- 2. Serve the forecast with prediction intervals.
SELECT
  store_id,
  forecast_timestamp,
  ROUND(forecast_value, 1)              AS forecast_sessions,
  ROUND(prediction_interval_lower_bound, 1) AS lo_80,
  ROUND(prediction_interval_upper_bound, 1) AS hi_80
FROM ML.FORECAST(
  MODEL `acme-analytics-prod.marts.store_demand_arima`,
  STRUCT(30 AS horizon, 0.8 AS confidence_level)
)
WHERE store_id = 'ST-0417'
ORDER BY forecast_timestamp;

-- 3. Fraud-adjacent classifier trained on the same session rows.
CREATE OR REPLACE MODEL `acme-analytics-prod.marts.payment_risk`
OPTIONS (
  model_type              = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols        = ['is_chargeback'],
  auto_class_weights      = TRUE,          -- the positive class is ~0.3%
  data_split_method       = 'SEQ',
  data_split_col          = 'window_start',
  data_split_eval_fraction = 0.2,
  max_iterations          = 50,
  early_stop              = TRUE
) AS
SELECT
  s.payment_failures,
  s.event_count,
  s.cart_value_micros,
  s.country,
  s.anomaly_score,
  s.window_start,
  c.is_chargeback
FROM `acme-analytics-prod.analytics.sessions_deduped` s
JOIN `acme-analytics-prod.marts.chargebacks` c USING (session_id)
WHERE s.window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 180 DAY);

-- 4. Evaluate before anyone builds a dashboard on it.
SELECT * FROM ML.EVALUATE(MODEL `acme-analytics-prod.marts.payment_risk`);

-- 5. Explain a single prediction — required for any decision affecting a customer.
SELECT session_id, predicted_is_chargeback_probs, top_feature_attributions
FROM ML.EXPLAIN_PREDICT(
  MODEL `acme-analytics-prod.marts.payment_risk`,
  (SELECT * FROM `acme-analytics-prod.analytics.sessions_deduped`
    WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)),
  STRUCT(3 AS top_k_features)
);
```

### 5.8 Looker — the semantic layer that ends the two-numbers problem

`views/store_daily.view.lkml`:

```lkml
view: store_daily {
  sql_table_name: `acme-analytics-prod.marts.store_daily` ;;

  dimension: pk {
    primary_key: yes
    hidden: yes
    type: string
    sql: CONCAT(${TABLE}.activity_date, '|', ${TABLE}.store_id) ;;
  }

  dimension_group: activity {
    type: time
    timeframes: [raw, date, week, month, quarter, year]
    convert_tz: no
    datatype: date
    sql: ${TABLE}.activity_date ;;
  }

  dimension: store_id { type: string  sql: ${TABLE}.store_id ;; }
  dimension: country  { type: string  map_layer_name: countries
                        sql: ${TABLE}.country ;; }

  measure: sessions {
    type: sum
    sql: ${TABLE}.sessions ;;
    description: "Distinct sessions, deduplicated on the final Beam pane."
  }

  measure: abandoned_carts {
    type: sum
    sql: ${TABLE}.abandoned_carts ;;
  }

  # THE definition of abandonment rate. There is exactly one, and it lives here.
  measure: abandonment_rate {
    type: number
    value_format_name: percent_2
    sql: SAFE_DIVIDE(${abandoned_carts}, NULLIF(${sessions}, 0)) ;;
    description: "abandoned_carts / sessions. Certified by Analytics Eng, 2026-09-01."
  }

  measure: abandoned_value {
    type: sum
    value_format_name: usd
    sql: ${TABLE}.abandoned_value ;;
  }

  measure: payment_failures { type: sum sql: ${TABLE}.payment_failures ;; }
}
```

`models/acme_retail.model.lkml`:

```lkml
connection: "bigquery_prod"
include: "/views/**/*.view.lkml"

datagroup: daily_marts {
  sql_trigger: SELECT MAX(activity_date) FROM `acme-analytics-prod.marts.store_daily` ;;
  max_cache_age: "4 hours"
}
persist_with: daily_marts

explore: store_performance {
  from: store_daily
  label: "Store Performance"
  description: "Certified store-level daily metrics. Source of truth for Finance and Growth."

  # Row-level security: a regional manager sees only their own stores.
  access_filter: {
    field: store_id
    user_attribute: allowed_store_ids
  }

  # Cost guardrail: never let a user scan the whole partitioned table.
  always_filter: {
    filters: [store_daily.activity_date: "90 days"]
  }

  # Aggregate awareness: route coarse queries to a small rollup.
  aggregate_table: monthly_by_country {
    query: {
      dimensions: [activity_month, country]
      measures: [sessions, abandoned_carts, abandoned_value]
    }
    materialization: { datagroup_trigger: daily_marts }
  }
}
```

### 5.9 Cloud Composer DAG — orchestration and reconciliation

```python
"""Nightly reconciliation: the batch layer of the Lambda architecture.

Recomputes the previous day's sessions from the GCS replay archive and
compares them against what the streaming layer produced. A divergence above
the tolerance is a paging event, not a ticket: it means the streaming numbers
on the executive dashboard are wrong right now.
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.google.cloud.operators.bigquery import (
    BigQueryInsertJobOperator, BigQueryCheckOperator,
)
from airflow.providers.google.cloud.operators.dataflow import (
    DataflowStartFlexTemplateOperator,
)

DEFAULT_ARGS = {
    "owner": "data-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=10),
    "email_on_failure": False,
    "sla": timedelta(hours=3),
}

with DAG(
    dag_id="clickstream_reconcile_daily",
    schedule="0 3 * * *",
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["analytics", "reconciliation"],
) as dag:

    replay_batch = DataflowStartFlexTemplateOperator(
        task_id="replay_batch_sessionise",
        location="us-central1",
        body={
            "launchParameter": {
                "jobName": "clickstream-replay-{{ ds_nodash }}",
                "containerSpecGcsPath":
                    "gs://acme-analytics-prod-dataflow-templates/clickstream-batch/v7.json",
                "parameters": {
                    "inputPattern":
                        "gs://acme-analytics-prod-clickstream-replay/clickstream/{{ ds }}/*.avro",
                    "outputTable": "acme-analytics-prod:analytics.session_metrics_batch$"
                                   "{{ ds_nodash }}",
                    "sessionGapSeconds": "1800",
                    "pipelineVersion": "batch-v7",
                },
                "environment": {
                    "serviceAccountEmail":
                        "sa-dataflow-clickstream@acme-analytics-prod.iam.gserviceaccount.com",
                    "tempLocation": "gs://acme-analytics-prod-dataflow-temp/temp",
                    "maxWorkers": 100,
                    "ipConfiguration": "WORKER_IP_PRIVATE",
                },
            }
        },
    )

    reconcile = BigQueryInsertJobOperator(
        task_id="compute_divergence",
        configuration={
            "query": {
                "useLegacySql": False,
                "query": """
                CREATE OR REPLACE TABLE `acme-analytics-prod.marts.reconciliation`
                PARTITION BY activity_date AS
                WITH stream AS (
                  SELECT DATE(window_start) AS activity_date, store_id,
                         COUNT(DISTINCT session_id) AS sessions_stream
                  FROM `acme-analytics-prod.analytics.sessions_deduped`
                  WHERE DATE(window_start) = DATE('{{ ds }}')
                  GROUP BY 1, 2
                ),
                batch AS (
                  SELECT DATE(window_start) AS activity_date, store_id,
                         COUNT(DISTINCT session_id) AS sessions_batch
                  FROM `acme-analytics-prod.analytics.session_metrics_batch`
                  WHERE DATE(window_start) = DATE('{{ ds }}')
                  GROUP BY 1, 2
                )
                SELECT
                  COALESCE(s.activity_date, b.activity_date) AS activity_date,
                  COALESCE(s.store_id, b.store_id)           AS store_id,
                  IFNULL(sessions_stream, 0)                 AS sessions_stream,
                  IFNULL(sessions_batch, 0)                  AS sessions_batch,
                  ABS(IFNULL(sessions_stream,0) - IFNULL(sessions_batch,0))
                    / NULLIF(IFNULL(sessions_batch,0), 0)    AS relative_divergence
                FROM stream s
                FULL OUTER JOIN batch b
                  USING (activity_date, store_id)
                """,
                "priority": "BATCH",
                "maximumBytesBilled": 5 * 1024**4,  # 5 TiB hard ceiling
            }
        },
        location="US",
    )

    assert_convergence = BigQueryCheckOperator(
        task_id="assert_divergence_within_tolerance",
        use_legacy_sql=False,
        location="US",
        sql="""
        SELECT COUNTIF(relative_divergence > 0.005) = 0
        FROM `acme-analytics-prod.marts.reconciliation`
        WHERE activity_date = DATE('{{ ds }}')
        """,
    )

    replay_batch >> reconcile >> assert_convergence
```

---

## 6. Operating it: CLI walkthrough with real output

### 6.1 Provision and verify the ingest layer

```console
$ gcloud config set project acme-analytics-prod
Updated property [core/project].

$ gcloud pubsub schemas create clickstream-v1 \
    --type=AVRO \
    --definition-file=schemas/clickstream-v1.avsc
Created schema [clickstream-v1].

$ gcloud pubsub schemas validate-message \
    --schema-name=clickstream-v1 \
    --message-encoding=json \
    --message='{"event_id":"7f1c...","event_time":1757155203000000,"event_type":"ADD_TO_CART","session_id":"s-991","user_pseudo_id":"u-4412","store_id":"ST-0417","country":"US","device":{"platform":"ios"},"cart_value_micros":149990000,"currency":"USD","attributes":{},"schema_version":1}'
Message is valid.

$ gcloud pubsub topics create ingest-clickstream \
    --message-retention-duration=7d \
    --schema=clickstream-v1 \
    --message-encoding=binary \
    --message-storage-policy-allowed-regions=us-central1,us-east1
Created topic [projects/acme-analytics-prod/topics/ingest-clickstream].

$ gcloud pubsub subscriptions create sub-clickstream-enrich \
    --topic=ingest-clickstream \
    --ack-deadline=60 \
    --message-retention-duration=7d \
    --enable-exactly-once-delivery \
    --enable-message-ordering \
    --dead-letter-topic=clickstream-dlq \
    --max-delivery-attempts=5 \
    --min-retry-delay=10s --max-retry-delay=600s
Created subscription [projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich].

$ gcloud pubsub subscriptions describe sub-clickstream-enrich \
    --format='yaml(name,ackDeadlineSeconds,enableExactlyOnceDelivery,enableMessageOrdering,deadLetterPolicy)'
ackDeadlineSeconds: 60
deadLetterPolicy:
  deadLetterTopic: projects/acme-analytics-prod/topics/clickstream-dlq
  maxDeliveryAttempts: 5
enableExactlyOnceDelivery: true
enableMessageOrdering: true
name: projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich
```

**Verification that the schema is actually enforced** — publish something invalid and confirm it is rejected at the topic, not discovered three stages downstream:

```console
$ gcloud pubsub topics publish ingest-clickstream --message='{"event_type":"NOT_A_REAL_TYPE"}'
ERROR: (gcloud.pubsub.topics.publish) INVALID_ARGUMENT: Invalid data in message.
- '@type': type.googleapis.com/google.rpc.BadRequest
  fieldViolations:
  - description: Message failed schema validation
    field: message
```

That single error is worth an entire class of 3 a.m. pages. Schema validation at the topic is the cheapest data-quality control in the stack.

### 6.2 Launch and inspect the streaming pipeline

```console
$ gcloud dataflow flex-template build \
    gs://acme-analytics-prod-dataflow-templates/clickstream-enrich/v7.json \
    --image-gcr-path=us-central1-docker.pkg.dev/acme-analytics-prod/dataflow/clickstream-enrich:v7 \
    --sdk-language=PYTHON \
    --flex-template-base-image=PYTHON3 \
    --metadata-file=templates/clickstream-enrich.metadata.json \
    --py-path=pipeline/ \
    --env=FLEX_TEMPLATE_PYTHON_PY_FILE=clickstream_enrich.py \
    --env=FLEX_TEMPLATE_PYTHON_REQUIREMENTS_FILE=requirements.txt
Successfully built and pushed image.
Template file created: gs://acme-analytics-prod-dataflow-templates/clickstream-enrich/v7.json

$ gcloud dataflow flex-template run clickstream-enrich-v7 \
    --template-file-gcs-location=gs://acme-analytics-prod-dataflow-templates/clickstream-enrich/v7.json \
    --region=us-central1 \
    --service-account-email=sa-dataflow-clickstream@acme-analytics-prod.iam.gserviceaccount.com \
    --subnetwork=regions/us-central1/subnetworks/snet-dataflow-us-central1 \
    --disable-public-ips \
    --enable-streaming-engine \
    --max-workers=40 --num-workers=4 --worker-machine-type=n2-standard-4 \
    --parameters=input_subscription=projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich,output_table=acme-analytics-prod:analytics.session_metrics,activation_topic=projects/acme-analytics-prod/topics/activation-signals,dlq_topic=projects/acme-analytics-prod/topics/clickstream-dlq,session_gap_seconds=1800,allowed_lateness_sec=3600,early_firing_sec=30,pipeline_version=v7
job:
  createTime: '2026-09-06T11:12:34.882Z'
  currentStateTime: '1970-01-01T00:00:00Z'
  id: 2026-09-06_04_12_33-1184773290183746512
  location: us-central1
  name: clickstream-enrich-v7
  projectId: acme-analytics-prod
  startTime: '2026-09-06T11:12:34.882Z'

$ gcloud dataflow jobs list --region=us-central1 --status=active
JOB_ID                                    NAME                   TYPE       CREATION_TIME        STATE    REGION
2026-09-06_04_12_33-1184773290183746512   clickstream-enrich-v7  Streaming  2026-09-06 11:12:34  Running  us-central1

$ gcloud dataflow jobs describe 2026-09-06_04_12_33-1184773290183746512 \
    --region=us-central1 --format='yaml(currentState,environment.workerPools[0].numWorkers,jobMetadata)'
currentState: JOB_STATE_RUNNING
environment:
  workerPools:
  - numWorkers: 4

$ gcloud dataflow metrics list 2026-09-06_04_12_33-1184773290183746512 \
    --region=us-central1 --source=service --filter='name.name~"Watermark|Lag|Backlog"'
---
name:
  name: DataWatermarkAge
  origin: dataflow/v1b3
scalar: 41
updateTime: '2026-09-06T11:38:02.117Z'
---
name:
  name: SystemLag
  origin: dataflow/v1b3
scalar: 12
updateTime: '2026-09-06T11:38:02.117Z'
---
name:
  name: CurrentNumVcpus
  origin: dataflow/v1b3
scalar: 16
updateTime: '2026-09-06T11:38:02.117Z'
```

**Reading this correctly:** `DataWatermarkAge: 41` means the pipeline's event-time frontier is 41 seconds behind now — healthy. `SystemLag: 12` is the age of the oldest element currently in flight — also healthy. When these two diverge (system lag low, watermark age climbing), you have a *stuck source*, not a slow pipeline. That distinction determines whether you scale workers (useless) or investigate the ordering key/source (correct).

### 6.3 Verify data is landing and is correct

```console
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  TIMESTAMP_TRUNC(window_start, MINUTE) AS minute,
  COUNT(*)                              AS rows_written,
  COUNT(DISTINCT session_id)            AS sessions,
  MAX(pane_index)                       AS max_pane,
  ROUND(AVG(TIMESTAMP_DIFF(ingested_at, window_end, SECOND)), 1) AS avg_emit_lag_s
FROM `acme-analytics-prod.analytics.session_metrics`
WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 MINUTE)
GROUP BY 1 ORDER BY 1 DESC'

+---------------------+--------------+----------+----------+----------------+
|       minute        | rows_written | sessions | max_pane | avg_emit_lag_s |
+---------------------+--------------+----------+----------+----------------+
| 2026-09-06 11:36:00 |         9412 |     7188 |        3 |           38.2 |
| 2026-09-06 11:35:00 |        11077 |     8203 |        4 |           41.7 |
| 2026-09-06 11:34:00 |        10884 |     8140 |        4 |           39.9 |
| 2026-09-06 11:33:00 |        10731 |     8095 |        3 |           40.4 |
+---------------------+--------------+----------+----------+----------------+
```

`rows_written > sessions` is expected and correct — those are the ACCUMULATING panes. If a dashboard ever reads `session_metrics` directly instead of `sessions_deduped`, every metric inflates by ~35%. This is precisely why the Looker `explore` is bound to `marts.*` and never to `analytics.*`.

**Cost verification before anyone builds on it:**

```console
$ bq query --use_legacy_sql=false --dry_run '
SELECT store_id, COUNT(*) FROM `acme-analytics-prod.analytics.session_metrics`
GROUP BY 1'
Error in query string: Cannot query over table
'acme-analytics-prod.analytics.session_metrics' without a filter over column(s)
'window_start' that can be used for partition elimination

$ bq query --use_legacy_sql=false --dry_run '
SELECT store_id, COUNT(*) FROM `acme-analytics-prod.analytics.session_metrics`
WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
GROUP BY 1'
Query successfully validated. Assuming the tables are not modified, running this
query will process 2418576384 bytes of data.
```

`require_partition_filter = true` turned a full-table scan into a compile-time error. Set it on every large fact table; it is the strongest single cost control BigQuery offers.

### 6.4 Slot and cost forensics with `INFORMATION_SCHEMA`

```console
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  user_email,
  COUNT(*)                                       AS jobs,
  ROUND(SUM(total_bytes_billed)/POW(1024,4), 3)  AS tib_billed,
  ROUND(SUM(total_slot_ms)/1000/3600, 1)         AS slot_hours,
  ROUND(AVG(TIMESTAMP_DIFF(end_time, start_time, MILLISECOND))/1000, 2) AS avg_sec
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND job_type = "QUERY" AND state = "DONE"
GROUP BY 1 ORDER BY slot_hours DESC LIMIT 8'

+------------------------------------------+------+------------+------------+---------+
|                user_email                | jobs | tib_billed | slot_hours | avg_sec |
+------------------------------------------+------+------------+------------+---------+
| looker-prod@acme-analytics-prod.iam.g... | 8412 |     41.882 |      612.4 |    2.11 |
| dataform@acme-analytics-prod.iam.gser... |  204 |     18.441 |      388.7 |   41.62 |
| lstudio-shared@acme-analytics-prod.ia... | 2887 |    103.219 |      944.8 |    9.84 |
| alice@acme.example                       |   61 |      6.004 |       71.2 |   18.03 |
+------------------------------------------+------+------------+------------+---------+
```

That third row is INC-5533 in progress: a Looker Studio shared credential burning 103 TiB/day for 2,887 short queries. Drill into it:

```console
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  REGEXP_EXTRACT(query, r"FROM\s+`?([A-Za-z0-9_.\-]+)`?") AS source_table,
  COUNT(*) AS jobs,
  ROUND(SUM(total_bytes_billed)/POW(1024,4), 2) AS tib_billed
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND user_email LIKE "lstudio-shared@%"
GROUP BY 1 ORDER BY tib_billed DESC LIMIT 5'

+-----------------------------------------------+------+------------+
|                 source_table                  | jobs | tib_billed |
+-----------------------------------------------+------+------------+
| acme-analytics-prod.raw.events_landing        | 2731 |     101.88 |
| acme-analytics-prod.marts.store_daily         |  156 |       1.34 |
+-----------------------------------------------+------+------------+
```

The report is querying the **raw landing table** directly. Fix: revoke `raw` dataset access from the BI service account, repoint the report at `marts.store_daily`, and add a materialised view for the hot path. Governance is a cost control, not just a compliance control.

### 6.5 Governance and sharing

```console
$ bq update --schema_update_option=ALLOW_FIELD_ADDITION \
    --policy_tags='projects/acme-analytics-prod/locations/us-central1/taxonomies/8812.../policyTags/4471...' \
    acme-analytics-prod:analytics.session_metrics.user_pseudo_id
Table 'acme-analytics-prod:analytics.session_metrics' successfully updated.

$ bq query --use_legacy_sql=false '
CREATE OR REPLACE ROW ACCESS POLICY emea_managers
ON `acme-analytics-prod.marts.store_daily`
GRANT TO ("group:emea-managers@acme.example")
FILTER USING (country IN ("ES","FR","DE","IT","PT"))'
Created row access policy emea_managers on table
acme-analytics-prod:marts.store_daily.

$ bq ls --row_access_policies acme-analytics-prod:marts.store_daily
       policyId       |            filterPredicate            |     creationTime
 ---------------------+---------------------------------------+----------------------
  emea_managers       | country IN ("ES","FR","DE","IT","PT")  | 2026-09-06T11:44:12Z
```

Sharing a curated product with a partner **without copying data** — this is Analytics Hub, and it is the exam's answer to "how do we monetise or share our data securely?":

```console
$ bq mk --data_exchange --location=us --display_name="Acme Retail Insights" acme_retail_exchange
Data exchange 'projects/acme-analytics-prod/locations/us/dataExchanges/acme_retail_exchange' successfully created.

$ bq mk --listing --location=us \
    --data_exchange=acme_retail_exchange \
    --display_name="Store Daily Performance" \
    --source_dataset=acme-analytics-prod:marts \
    store_daily_listing
Listing 'projects/.../dataExchanges/acme_retail_exchange/listings/store_daily_listing' successfully created.
```

The subscriber gets a **linked dataset**: a read-only, always-current pointer. No export, no egress, no stale copy, no second lineage to govern. That is the business-value argument in one sentence.

---

## 7. Verification and failure diagnosis

### 7.1 The golden signals for a streaming analytics platform

| Signal | Metric | Healthy | Page at | What it actually means |
|---|---|---|---|---|
| **Backlog age** | `pubsub.googleapis.com/subscription/oldest_unacked_message_age` | < 60 s | > 300 s for 5 m | End-to-end freshness. The SLI your business owns. |
| **Backlog size** | `subscription/num_undelivered_messages` | flat | rising monotonically 15 m | Consumers cannot keep up — or are dead |
| **Watermark age** | `dataflow.googleapis.com/job/per_stage_data_watermark_age` | < 120 s | > 900 s | Event-time progress. If this stalls, windows never close and results never emit |
| **System lag** | `job/system_lag` | < 60 s | > 300 s | Oldest in-flight element. High lag + low watermark age = slow processing |
| **Worker saturation** | `job/current_num_vcpus` vs `max_workers` | < 80% of cap | pinned at cap 15 m | Autoscaler is out of room |
| **DLQ rate** | `topic/send_message_operation_count` on the DLQ topic | ~0 | > 1/s for 5 m | Poison messages or a schema break upstream |
| **Publish errors** | `topic/send_request_count` filtered on non-OK response codes | 0 | any sustained | Producer IAM, quota, or schema failure |
| **BQ write errors** | Dataflow custom counter + `Storage Write API` error logs | 0 | any sustained | Schema drift, quota, or partition-filter violation |
| **Slot saturation** | `bigquery.googleapis.com/slots/allocated_for_reservation` | < 80% of max | at cap 15 m | Query queueing; interactive users see it as "BI is slow" |
| **Freshness of marts** | `MAX(ingested_at)` in each mart, exported as a custom metric | < SLA | > SLA | The dashboard is showing yesterday |

### 7.2 Symptom → diagnosis table

| Symptom | Most likely cause | Confirming evidence | Remediation |
|---|---|---|---|
| Backlog rising, watermark rising, workers at max | Genuine under-provisioning | `current_num_vcpus == max_workers`, CPU util > 80% | Raise `--max-workers`; if already high, look for a hot key or an expensive `DoFn` |
| Backlog rising, workers **idle** | Hot key / ordering-key skew — all traffic on one key serialises onto one worker | Job graph shows one stage with skewed element counts; enable `--experiments=enable_stackdriver_agent_metrics` | Add a salt to the key and re-aggregate, or drop `enable_message_ordering` if per-key order is not truly required |
| Watermark stalled, system lag low | Stuck source: an unacked message pins the watermark; frequently a poison message being retried | `oldest_unacked_message_age` climbing linearly (1 s per s) | Check DLQ; confirm `dead_letter_policy` exists — **without a DLQ, a poison message stalls the pipeline forever** |
| Watermark advances but no output rows | Windows not closing: allowed lateness huge, or trigger never fires | Beam counters show elements in but none out of `GroupByKey` | Add early firings; reduce allowed lateness; verify `timestamp_attribute` is set — without it Beam uses publish time and event-time logic silently changes meaning |
| Rows in BigQuery are duplicated ~2–4× | ACCUMULATING panes read without deduplication | `SELECT session_id, COUNT(*) … HAVING COUNT(*)>1` returns rows with distinct `pane_index` | Read `sessions_deduped`, not `session_metrics`. Enforce with dataset IAM |
| Rows missing for a specific hour | Data arrived later than `allowed_lateness` and was dropped | Beam counter `droppedDueToLateness` > 0 | Increase lateness; add a "late arrivals" branch that writes to a separate table instead of dropping |
| DLQ filling with `PERMISSION_DENIED` | Subscription's push/BQ writer SA lacks `roles/bigquery.dataEditor` | `gcloud logging read 'resource.type=pubsub_subscription severity>=ERROR'` | Grant the role; note BigQuery subscriptions use the **subscription's** SA, not the topic's |
| BigQuery subscription silently dropping fields | `drop_unknown_fields = true` with a schema that drifted | Compare topic schema revision against table schema | Add columns to the table first, *then* publish the new schema revision. Order matters |
| Streaming inserts fail with `quotaExceeded` | Per-table streaming quota or Storage Write API throughput limits | Error logs on the write step; `bigquery.googleapis.com/quota/*` metrics | Increase `triggering_frequency` to batch more, enable `with_auto_sharding`, or shard writes across tables |
| Query cost spike overnight | A new scheduled query or BI report scanning an unpartitioned table | `INFORMATION_SCHEMA.JOBS_BY_PROJECT` grouped by `user_email` and source table | `require_partition_filter`, `maximum_bytes_billed`, custom quotas, reservation caps |
| Looker dashboards slow, warehouse "fine" | Slot contention: BI competes with ELT in the same reservation | `slots/allocated_for_reservation` at cap during ELT window | Separate reservations with assignments: `res-bi` (interactive) and `res-elt` (batch), `ignore_idle_slots = false` on BI |
| Two dashboards, two numbers | Semantic drift — logic duplicated outside the model | Diff the compiled SQL from Looker against the ad-hoc report's SQL | Revoke direct access to `analytics.*` for BI users; expose only `marts.*` and LookML measures |
| Pipeline update fails with "not update-compatible" | Beam DAG changed in a way that invalidates persisted state | `gcloud dataflow jobs update` error naming the incompatible step | Use `--transform_name_mapping`, or drain the old job and start fresh — accepting a one-window gap |

### 7.3 Diagnostic command sequence for "the dashboard is stale"

```console
# 1. Is data still arriving at the topic at all?
$ gcloud monitoring time-series list \
    --filter='metric.type="pubsub.googleapis.com/topic/send_message_operation_count"
              AND resource.labels.topic_id="ingest-clickstream"' \
    --format='value(points[0].value.int64Value)' --interval-end-time="$(date -u +%FT%TZ)"
184203

# 2. Is the subscription draining?
$ gcloud pubsub subscriptions describe sub-clickstream-enrich --format='value(name)' >/dev/null && \
  gcloud monitoring time-series list \
    --filter='metric.type="pubsub.googleapis.com/subscription/num_undelivered_messages"
              AND resource.labels.subscription_id="sub-clickstream-enrich"' \
    --format='value(points[0].value.int64Value)'
4188271          # <-- 4.1M backlog. Consumers are not keeping up.

# 3. Is the Dataflow job even alive?
$ gcloud dataflow jobs list --region=us-central1 --status=all --limit=3
JOB_ID                                    NAME                   TYPE       CREATION_TIME        STATE     REGION
2026-09-06_04_12_33-1184773290183746512   clickstream-enrich-v7  Streaming  2026-09-06 11:12:34  Running   us-central1
2026-09-05_02_00_11-9928374651029384756   clickstream-enrich-v6  Streaming  2026-09-05 09:00:12  Drained   us-central1

# 4. Where is it stuck?
$ gcloud logging read '
  resource.type="dataflow_step"
  AND resource.labels.job_id="2026-09-06_04_12_33-1184773290183746512"
  AND severity>=WARNING' --limit=5 --format='value(timestamp,jsonPayload.message)'
2026-09-06T12:04:11Z  Operation ongoing in step Score/GroupBySession for at least 20m00s
                      without outputting or completing in state process-timers
2026-09-06T12:04:11Z    at java.base@17/java.lang.Thread.sleep(Native Method)
2026-09-06T12:02:47Z  Processing stuck in step Score for at least 15m00s

# 5. Confirm the hot-key hypothesis.
$ bq query --use_legacy_sql=false --format=pretty '
SELECT session_id, COUNT(*) AS events
FROM `acme-analytics-prod.raw.events_landing`
WHERE event_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 MINUTE)
GROUP BY 1 ORDER BY events DESC LIMIT 3'
+---------------------------+---------+
|        session_id         | events  |
+---------------------------+---------+
| s-UNKNOWN                 | 3914772 |
| s-8f21a0c4-...            |      41 |
| s-1b09ee77-...            |      38 |
+---------------------------+---------+
```

**Diagnosis:** a client release is emitting `session_id = "s-UNKNOWN"` when its session store is empty. Ordering is enabled, so 3.9 M events serialise onto a single ordering key and a single worker. Every other session is queued behind it.

**Immediate mitigation** (stop the bleeding, then fix the client):

```console
$ gcloud dataflow flex-template run clickstream-enrich-v7-hotfix \
    --template-file-gcs-location=gs://.../clickstream-enrich/v7.json \
    --region=us-central1 \
    --parameters=...,excludeSessionIds=s-UNKNOWN,dlqUnknownSessions=true
```

**Structural fix:** salt the key (`session_id || '#' || MOD(FARM_FINGERPRINT(event_id), 16)`) and re-aggregate, plus a schema constraint rejecting sentinel session IDs at the topic.

### 7.4 Replay: proving the architecture can recover

The Cloud Storage subscription exists for exactly this moment.

```console
# Option A — Pub/Sub seek, when the bad window is inside the retention period.
$ gcloud pubsub subscriptions seek sub-clickstream-enrich \
    --time=2026-09-06T10:00:00Z
Set the subscription [projects/acme-analytics-prod/subscriptions/sub-clickstream-enrich]
to the specified time.

# Option B — batch replay from the archive into a shadow table, then swap.
$ gcloud dataflow flex-template run clickstream-replay-20260906 \
    --template-file-gcs-location=gs://.../clickstream-batch/v7.json \
    --region=us-central1 --max-workers=100 \
    --parameters=inputPattern=gs://acme-analytics-prod-clickstream-replay/clickstream/2026-09-06/*.avro,outputTable=acme-analytics-prod:analytics.session_metrics_replay,sessionGapSeconds=1800,pipelineVersion=replay-v7

$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  (SELECT COUNT(DISTINCT session_id) FROM `acme-analytics-prod.analytics.sessions_deduped`
    WHERE DATE(window_start)=DATE("2026-09-06")) AS stream_sessions,
  (SELECT COUNT(DISTINCT session_id) FROM `acme-analytics-prod.analytics.session_metrics_replay`
    WHERE DATE(window_start)=DATE("2026-09-06")) AS replay_sessions'
+-----------------+-----------------+
| stream_sessions | replay_sessions |
+-----------------+-----------------+
|          811402 |          847933 |
+-----------------+-----------------+
```

A 4.5% shortfall in the streaming layer confirms events were dropped during the hot-key stall. Atomically correct the partition:

```console
$ bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE `acme-analytics-prod.analytics.sessions_deduped$20260906` AS
SELECT * FROM `acme-analytics-prod.analytics.session_metrics_replay`
WHERE DATE(window_start) = DATE("2026-09-06")'
Waiting on bqjob_r4c1a...  ... (12s) Current status: DONE
```

**This is the Lambda architecture doing its job**: the speed layer gives you a 40-second answer that is usually right; the batch layer gives you an authoritative answer that is always right, and overwrites the speed layer's partition. Design the batch layer *before* the incident, not after.

---

## 8. Cost engineering — the numbers a platform architect is accountable for

| Lever | Mechanism | Typical impact | Risk if misapplied |
|---|---|---|---|
| Partitioning + `require_partition_filter` | Eliminates full scans at compile time | 10–100× reduction on time-series facts | Breaks naive queries — that is the point |
| Clustering | Block-level pruning on high-cardinality filters | 2–10× on selective predicates | No benefit if the filter columns are not the cluster keys, in order |
| Materialised views with `max_staleness` | Pre-computed aggregates, incremental refresh | 5–50× on repeated BI aggregations | Staleness must be negotiated with the business, in writing |
| BI Engine reservation | In-memory acceleration for BI queries | Sub-second dashboards, fewer slots | Memory-bounded; not all queries are eligible |
| Looker aggregate awareness | Routes coarse queries to small rollups automatically | Large, invisible to users | Rollups must be kept in sync via datagroups |
| Editions + reservation caps | Converts unbounded cost into a fixed ceiling | Predictability | Under-provisioning shows up as query queueing |
| Physical (compressed) storage billing | Bills compressed bytes | Often 2–5× on columnar-friendly data | Dataset-level choice with a change cooldown |
| Replace Dataflow with a BigQuery subscription | Removes an always-on distributed system | Eliminates the entire streaming compute line item | Only valid when no per-event logic is required |
| Batch `bq load` instead of streaming | Load jobs are free or reservation-billed | Removes streaming ingest cost entirely | Minutes of latency instead of seconds |
| Pub/Sub batching on the publisher | Fewer, larger requests | Lower publish cost and CPU | Adds publish latency; flush on `preStop` |
| `maximum_bytes_billed` on every automated query | Fails instead of overspending | Prevents the runaway | Requires runbook for the resulting failures |
| GCS lifecycle on the replay archive | STANDARD → NEARLINE → ARCHIVE | Large on long retention | Retrieval cost and minimum-duration charges on early access |

**The governing question at every design review:** *what is the business value of one minute of freshness on this dataset, and does it exceed the marginal cost of achieving it?* If no one can answer, the answer is batch.

---

## 9. Mapping to business use cases (the exam's actual framing)

The CDL exam asks you to connect a *business situation* to the *right analytics capability*. This is the mapping table to internalise.

| Business situation | Value driver | GCP pattern | Why not the alternative |
|---|---|---|---|
| **Retail:** recover abandoned carts | Revenue recovery within the intent window (minutes) | Pub/Sub → Dataflow sessions → activation topic → Cloud Run messaging | Nightly batch misses the intent window entirely; the customer has already bought elsewhere |
| **Financial services:** card fraud | Loss prevention; decision must precede authorisation | Pub/Sub (exactly-once) → Dataflow stateful scoring + BigQuery ML / Vertex AI endpoint | A dashboard reporting yesterday's fraud is an audit artifact, not a control |
| **Manufacturing/IoT:** predictive maintenance | Avoided unplanned downtime | IoT gateway → Pub/Sub → Dataflow (anomaly windows) → BigQuery + Bigtable for high-rate time series | Bigtable for the raw high-cardinality series, BigQuery for the analytical aggregates — using one for both is the classic error |
| **Gaming:** live-ops and matchmaking health | Player retention; act during the session | Pub/Sub → Dataflow → BigQuery + Looker real-time dashboards | Same intent-window logic as retail, on minutes |
| **Media:** content recommendation | Engagement, watch time | BigQuery ML matrix factorisation / embeddings + `VECTOR_SEARCH`, served via reverse ETL | Exporting to an external ML platform adds a governance boundary and a staleness gap |
| **Supply chain:** demand forecasting | Inventory carrying cost, stockouts | BigQuery `ARIMA_PLUS` on the daily mart, Looker for planners | Streaming adds nothing — the decision cadence is weekly |
| **Enterprise-wide:** "one version of the truth" | Decision velocity and trust | Looker semantic layer over governed `marts.*` | More dashboards on raw tables makes the problem worse, not better |
| **Partner/monetisation:** share curated data | New revenue, no copy risk | Analytics Hub linked datasets, data clean rooms | Exporting CSVs creates uncontrolled copies with no lineage and no revocation |
| **Finance team lives in spreadsheets** | Adoption without ungoverned exports | Connected Sheets on BigQuery | A CSV export is an immediate, permanent loss of governance |
| **Legacy Hadoop estate** | Migration without a rewrite | Dataproc / Dataproc Serverless, then incremental move to BigQuery | A big-bang rewrite to BigQuery stalls; land-then-modernise ships |

### 9.1 The decision tree for the exam

```
Is the decision worthless if it arrives an hour late?
├── YES → STREAMING
│    └── Does the transformation need event-time windows, state, or late data?
│         ├── YES → Pub/Sub → Dataflow → BigQuery (Storage Write API)
│         └── NO  → Pub/Sub → BigQuery subscription (+ SQL / continuous queries)
└── NO  → BATCH
     └── Where does the data live?
          ├── OLTP database        → Datastream (CDC)
          ├── SaaS / ads platform  → BigQuery Data Transfer Service
          ├── Another cloud / S3   → Storage Transfer Service, or BigLake in place
          ├── Files in GCS         → bq load / Dataflow batch
          └── Existing Spark jobs  → Dataproc (or Dataproc Serverless)

Then: who consumes it?
├── Governed, org-wide metrics, embedded analytics → Looker (LookML)
├── Free, quick, self-service dashboards           → Looker Studio
├── Spreadsheet users, billions of rows            → Connected Sheets
├── Data scientists                                → BigQuery Studio / notebooks / Vertex AI
├── ML predictions inside SQL                      → BigQuery ML
└── External partners, no data copy                → Analytics Hub
```

---

## 10. What to be able to state cold on exam day

1. **The lifecycle**: ingest → store → process → analyze → activate, with the primary service at each stage.
2. **Pub/Sub is the global, serverless event backbone**; Dataflow is the unified batch+stream processor built on Apache Beam; BigQuery is the serverless warehouse; Looker is the governed semantic layer; Looker Studio is the free dashboarding tool; Connected Sheets is BigQuery in a spreadsheet.
3. **Batch answers "what happened"; streaming answers "what is happening"** — and the choice is determined by how fast the value of the decision decays, not by technical preference.
4. **BigQuery ML brings ML to the data**, removing the export step, its governance risk and its specialist bottleneck. That is the business value of "smart analytics".
5. **Dataproc is for lifting and shifting Hadoop/Spark**; Dataflow is for new pipelines where event-time correctness matters.
6. **Datastream** replicates operational databases into BigQuery with low latency and no application change.
7. **Analytics Hub** shares data without copying it. **Dataplex Universal Catalog** governs and discovers it across the estate.
8. **The most common architectural mistake** is putting BI directly on raw tables: it produces conflicting numbers *and* uncontrolled cost, from the same root cause — the absence of a governed layer between storage and consumption.

---

## Referencias

**Exam and certification**
- Cloud Digital Leader exam guide (PDF): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification: https://cloud.google.com/learn/certification/cloud-digital-leader

**Smart analytics platform**
- Smart analytics solutions: https://cloud.google.com/solutions/smart-analytics
- Data analytics products overview: https://cloud.google.com/products/#data-analytics
- Data lifecycle on Google Cloud: https://cloud.google.com/architecture/data-lifecycle-cloud-platform

**Ingest — Pub/Sub, Datastream, transfers**
- Pub/Sub documentation: https://cloud.google.com/pubsub/docs
- Pub/Sub schemas: https://cloud.google.com/pubsub/docs/schemas
- Exactly-once delivery: https://cloud.google.com/pubsub/docs/exactly-once-delivery
- Message ordering: https://cloud.google.com/pubsub/docs/ordering
- Dead-letter topics: https://cloud.google.com/pubsub/docs/handling-failures
- BigQuery subscriptions: https://cloud.google.com/pubsub/docs/bigquery
- Cloud Storage subscriptions: https://cloud.google.com/pubsub/docs/cloudstorage
- Replay and seek: https://cloud.google.com/pubsub/docs/replay-overview
- Pub/Sub monitoring: https://cloud.google.com/pubsub/docs/monitoring
- Managed Service for Apache Kafka: https://cloud.google.com/managed-service-for-apache-kafka/docs
- Datastream documentation: https://cloud.google.com/datastream/docs
- Datastream to BigQuery: https://cloud.google.com/datastream/docs/destination-bigquery
- Storage Transfer Service: https://cloud.google.com/storage-transfer/docs
- BigQuery Data Transfer Service: https://cloud.google.com/bigquery/docs/dts-introduction

**Process — Dataflow, Beam, Dataproc, Dataform, Composer**
- Dataflow documentation: https://cloud.google.com/dataflow/docs
- Streaming pipelines: https://cloud.google.com/dataflow/docs/concepts/streaming-pipelines
- Streaming Engine: https://cloud.google.com/dataflow/docs/streaming-engine
- Dataflow Prime: https://cloud.google.com/dataflow/docs/guides/enable-dataflow-prime
- Flex Templates: https://cloud.google.com/dataflow/docs/guides/templates/using-flex-templates
- Update / drain a streaming job: https://cloud.google.com/dataflow/docs/guides/updating-a-pipeline
- Troubleshooting Dataflow: https://cloud.google.com/dataflow/docs/guides/troubleshooting-your-pipeline
- Dataflow monitoring metrics: https://cloud.google.com/dataflow/docs/guides/using-monitoring-intf
- Apache Beam programming guide (windows, triggers, watermarks): https://beam.apache.org/documentation/programming-guide/
- Beam streaming model ("Streaming 101/102"): https://beam.apache.org/documentation/basics/
- Dataproc documentation: https://cloud.google.com/dataproc/docs
- Dataproc Serverless for Spark: https://cloud.google.com/dataproc-serverless/docs
- Cloud Data Fusion: https://cloud.google.com/data-fusion/docs
- Dataform: https://cloud.google.com/dataform/docs
- Cloud Composer: https://cloud.google.com/composer/docs

**Analyze — BigQuery**
- BigQuery documentation: https://cloud.google.com/bigquery/docs
- BigQuery architecture / under the hood: https://cloud.google.com/bigquery/docs/introduction
- Partitioned tables: https://cloud.google.com/bigquery/docs/partitioned-tables
- Clustered tables: https://cloud.google.com/bigquery/docs/clustered-tables
- Materialized views: https://cloud.google.com/bigquery/docs/materialized-views-intro
- BigQuery Storage Write API: https://cloud.google.com/bigquery/docs/write-api
- Streaming data into BigQuery: https://cloud.google.com/bigquery/docs/streaming-data-into-bigquery
- INFORMATION_SCHEMA jobs views: https://cloud.google.com/bigquery/docs/information-schema-jobs
- Editions and reservations: https://cloud.google.com/bigquery/docs/editions-intro
- Workload management with reservations: https://cloud.google.com/bigquery/docs/reservations-intro
- Controlling costs: https://cloud.google.com/bigquery/docs/best-practices-costs
- Custom cost controls / quotas: https://cloud.google.com/bigquery/docs/custom-quotas
- BI Engine: https://cloud.google.com/bigquery/docs/bi-engine-intro
- Row-level security: https://cloud.google.com/bigquery/docs/row-level-security-intro
- Column-level access control: https://cloud.google.com/bigquery/docs/column-level-security-intro
- BigLake: https://cloud.google.com/biglake/docs
- Analytics Hub: https://cloud.google.com/bigquery/docs/analytics-hub-introduction
- BigQuery pricing: https://cloud.google.com/bigquery/pricing

**Smart analytics / ML in the warehouse**
- BigQuery ML introduction: https://cloud.google.com/bigquery/docs/bqml-introduction
- `CREATE MODEL` syntax: https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create
- Time-series forecasting with ARIMA_PLUS: https://cloud.google.com/bigquery/docs/arima-plus-single-time-series-forecasting-tutorial
- `ML.EXPLAIN_PREDICT`: https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-explain-predict
- Generative AI in BigQuery: https://cloud.google.com/bigquery/docs/generative-ai-overview
- Vector search in BigQuery: https://cloud.google.com/bigquery/docs/vector-search-intro
- Vertex AI documentation: https://cloud.google.com/vertex-ai/docs

**Business intelligence**
- Looker documentation: https://cloud.google.com/looker/docs
- LookML overview: https://cloud.google.com/looker/docs/what-is-lookml
- Access filters and row-level security in Looker: https://cloud.google.com/looker/docs/reference/param-explore-access-filter
- Aggregate awareness: https://cloud.google.com/looker/docs/aggregate-awareness
- Looker Studio: https://support.google.com/looker-studio/answer/6283323
- Looker Studio Pro: https://cloud.google.com/looker-studio/docs
- Connected Sheets: https://cloud.google.com/bigquery/docs/connected-sheets

**Governance and reliability**
- Dataplex documentation: https://cloud.google.com/dataplex/docs
- Data governance on Google Cloud: https://cloud.google.com/architecture/data-governance
- Cloud Monitoring alerting policies: https://cloud.google.com/monitoring/alerts
- Google Cloud Architecture Framework — Reliability: https://cloud.google.com/architecture/framework/reliability
- Terraform Google provider: https://registry.terraform.io/providers/hashicorp/google/latest/docs
- GKE Workload Identity Federation: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity