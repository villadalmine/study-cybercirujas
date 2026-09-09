# Topic 2.2 — Determine which Google Cloud data management products are applicable to different business use cases

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12)
**Domain weight:** 6.0
**Audience profile:** Platform Architect / Senior SRE. This module treats the exam objective as an architectural selection problem, not a product catalogue exercise. The exam asks *which product*; production asks *why, at what consistency, at what tail latency, at what blast radius, and at what unit cost*. Both answers come from the same reasoning.

---

## 1. Motivation: the production architectural problem

### 1.1 The failure mode this objective exists to prevent

Almost every catastrophic data-platform incident in a cloud migration traces back to one class of mistake: **a workload placed on a storage engine whose consistency, scaling, and failure semantics do not match the business transaction it serves.** The mistake is rarely visible on day one. It surfaces at 3× traffic, at the first regional event, or at the first audit.

Four canonical incidents, all of which are the *same* mistake wearing different clothes:

| Incident | What was built | Why it broke | Correct placement |
|---|---|---|---|
| Payment ledger double-spend | Global payment ledger on a wide-column store with eventual cross-region replication; application read from the nearest replica and wrote to the nearest cluster | The engine guarantees atomicity only **per row**; there is no cross-row, cross-region transaction. Two regions accepted overlapping debits. | **Spanner** — externally consistent, cross-row/cross-region ACID |
| Analytics query storm takes down checkout | BI dashboards pointed at the OLTP primary (Cloud SQL) because "the data is already there" | Analytical scans consumed the primary's buffer pool and IOPS; row-store engine must read whole rows to aggregate one column. Lock contention and connection exhaustion followed. | **BigQuery** (or AlloyDB columnar engine / read pool) — OLAP separated from OLTP |
| $340k/month object storage bill | 900 TB of IoT telemetry written to Standard class, never lifecycled, then "fixed" by a bulk class change | Nearline/Coldline/Archive carry **minimum storage durations** (30/90/365 days) and retrieval fees; an early bulk transition triggered early-deletion charges on top of retrieval. | **Autoclass** or lifecycle rules applied *at bucket creation*, before data lands |
| Global session store melts at launch | User sessions in a relational database, one row per session, 400k writes/sec target | Row-store OLTP with synchronous replication cannot absorb that write rate at single-digit-millisecond p99 without vertical limits. | **Memorystore** (ephemeral) + **Bigtable/Firestore** (durable) |

### 1.2 The four axes that decide everything

Every Google Cloud data product is a point in this space. Memorize the axes, not the marketing.

1. **Structure** — structured (fixed schema, relational), semi-structured (documents, JSON, wide-column), unstructured (objects: video, images, PDFs, model weights).
2. **Access pattern** — OLTP (many small reads/writes, point lookups, transactions) vs OLAP (few huge scans, aggregations, columnar projections) vs HTAP (both) vs caching (sub-millisecond, non-durable) vs archival (write-once, read-rarely).
3. **Consistency & scope of atomicity** — strong within a row / within an entity group / within a region / **externally consistent globally**; vs eventual.
4. **Scale-out topology** — vertical (one primary, bigger machine), read-scaled (primary + replicas), horizontally sharded by the service itself (Spanner, Bigtable, BigQuery, Firestore), or shared-nothing object storage (Cloud Storage).

A fifth, non-negotiable operational axis in production: **blast radius** — zonal, regional, or multi-regional — and the SLA that follows from it.

### 1.3 The decision tree (this is the exam answer in compressed form)

```
Is the data unstructured (files, blobs, media, backups, model artifacts)?
├─ YES → Cloud Storage (object)
│         ├─ POSIX semantics required by a legacy app? → Filestore / NetApp Volumes
│         ├─ HPC/AI training scratch, sub-ms, TB/s? → Parallelstore
│         └─ Boot disk / raw block for a VM? → Persistent Disk / Hyperdisk
└─ NO → structured or semi-structured
   │
   ├─ Primary purpose is ANALYTICS (scan, aggregate, join across history, ML/BI)?
   │   └─ YES → BigQuery  (+ BI Engine for sub-second dashboards,
   │                        + BigLake/Omni for data in GCS/S3/Azure,
   │                        + Analytics Hub to share it)
   │
   └─ Primary purpose is OPERATIONAL (an app serving users/transactions)?
       │
       ├─ Needs RELATIONAL / SQL / joins / referential integrity?
       │   ├─ Lift-and-shift an existing MySQL / PostgreSQL / SQL Server engine,
       │   │  regional scale is enough → Cloud SQL
       │   ├─ PostgreSQL-compatible but needs 4× OLTP throughput, HTAP,
       │   │  99.99% SLA, near-zero-downtime scaling → AlloyDB for PostgreSQL
       │   └─ Needs horizontal write scale AND global strong consistency
       │      AND 99.999% (five nines) → Spanner
       │
       └─ Non-relational?
           ├─ Documents, mobile/web SDKs, realtime listeners, offline sync → Firestore
           ├─ Huge key-ordered/time-series/wide-column, >1 TB, high write
           │  throughput, single-digit-ms, no joins → Bigtable
           └─ Ephemeral, sub-millisecond, cache / session / leaderboard → Memorystore
```

> **Exam trap #1:** "Which product for a *globally consistent, horizontally scalable relational* database?" → **Spanner**, always. "Which for *migrating an existing MySQL 8 database with minimal changes*?" → **Cloud SQL**, always. The distractor is that both are "relational SQL". The discriminator is *global strong consistency + horizontal write scale* vs *compatibility + minimal refactor*.

---

## 2. Product-by-product technical mechanics

### 2.1 Cloud Storage — object storage as a durability substrate

**Internals.** Cloud Storage is a flat namespace (no real directories; `/` is a character in the object name) over Colossus, Google's distributed filesystem. Objects are erasure-coded across failure domains; the 11-nines durability figure is a property of that coding plus continuous background integrity verification via CRC32C/MD5 checksums, not of replication count alone. Metadata lives in a strongly consistent metadata service — which is why Cloud Storage offers **strong read-after-write consistency** for object PUTs and DELETEs, and strongly consistent bucket/object listing. There is no eventual-consistency window to design around (a common holdover assumption from other clouds).

Key mechanics an SRE must internalize:

- **Location type is immutable.** `region` / `dual-region` / `multi-region` is set at bucket creation and cannot be changed. Moving 500 TB between location types means a `gcloud storage cp` (or Storage Transfer Service) job plus a cutover, not a config flag.
- **Storage class is per *object***, with a bucket-level default. Lifecycle rules mutate object classes.
- **Minimum storage duration** — Nearline 30 days, Coldline 90 days, Archive 365 days. Delete or transition earlier and you are billed for the remainder. This is the single most common cost surprise.
- **Autoclass** moves objects between classes based on access, with **no retrieval or early-deletion fees**, in exchange for a small per-object management fee. For unpredictable access patterns it is almost always cheaper than hand-tuned lifecycle rules — and it can only be enabled on a bucket, so decide at creation.
- **Turbo replication** (dual-region only) gives an RPO of 15 minutes with an SLO, versus best-effort asynchronous replication otherwise.
- **Retention policy + Bucket Lock** makes objects immutable for a period, and *locking* the policy makes it irrevocable — the mechanism behind WORM/ransomware-resistant and regulatory (SEC 17a-4-style) archives. **Object Retention Lock** does the same per object.
- **Soft delete** retains deleted/overwritten objects for a retention window (default 7 days on new buckets) and is the first thing to check after an accidental `rm -r`.

| Class | Min. duration | Typical use | Retrieval cost | Availability SLA (multi-region) |
|---|---|---|---|---|
| Standard | none | Hot serving, active analytics, GKE artefacts | none | 99.95% |
| Nearline | 30 d | Monthly reporting, backups read ~monthly | low | 99.9% |
| Coldline | 90 d | Quarterly DR copies | medium | 99.9% |
| Archive | 365 d | Legal hold, 7-year retention, tape replacement | high | 99.9% |
| Autoclass | n/a (managed) | Unknown/erratic access | none | class-dependent |

> Regional buckets carry a 99.9% availability SLA; dual-region and multi-region Standard carry 99.95%. Durability (11 nines) is *not* availability — conflating them is exam trap #2.

**File and block, for completeness** (the objective covers "data management products", and storage tiering questions appear):

| Need | Product | Interface | Notes |
|---|---|---|---|
| Shared POSIX filesystem for lift-and-shift | **Filestore** | NFSv3 | Basic/Zonal/Regional/Enterprise tiers; Enterprise is regionally redundant and GKE-integrated |
| Enterprise NAS features (snapshots, SnapMirror, multiprotocol) | **NetApp Volumes** | NFS + SMB | For workloads already on ONTAP |
| HPC/AI scratch, TB/s aggregate | **Parallelstore** | DAOS-based | Ephemeral, feeds GPU/TPU training |
| Raw block for a VM | **Persistent Disk / Hyperdisk** | block | Hyperdisk decouples provisioned IOPS/throughput from capacity |
| Object-as-filesystem for GKE/AI | **Cloud Storage FUSE** | mount | Not POSIX-complete; no atomic rename semantics for directories — never place a database on it |

### 2.2 Cloud SQL — managed MySQL, PostgreSQL, SQL Server

**Architecture.** A Cloud SQL instance is a Google-managed VM running the actual upstream engine binary against a regional or zonal persistent disk. **High availability is storage-level, not engine-level**: an HA (`REGIONAL`) instance keeps a standby in a second zone and writes are synchronously replicated at the block layer to a regional PD. On failover, the standby VM attaches the same regional disk and the instance's IP is re-pointed. Consequences that matter operationally:

- Failover is typically tens of seconds to a couple of minutes, and **connections are dropped** — the application must reconnect and retry. There is no transparent connection failover.
- The standby is **not readable**. Read scale requires explicit read replicas, which use *engine-native asynchronous* replication (binlog / streaming WAL) and therefore have replica lag you must monitor.
- Synchronous regional replication means the write path pays a cross-zone round trip. HA costs write latency; this is the price of the SLA.
- **Enterprise Plus** edition adds a larger machine family, a local NVMe **data cache**, near-zero-downtime planned maintenance and failover, and a **99.99%** SLA (vs 99.95% for Enterprise HA).

**Backup/recovery.** Automated backups plus write-ahead-log/binlog archiving enable **point-in-time recovery (PITR)**, which restores *to a new instance* — never in place. Rehearse this: the restore duration on a multi-TB instance is measured in hours and is the real RTO, regardless of what the backup dashboard says.

**Connectivity — the part teams get wrong.** Three options, in decreasing order of preference:

1. **Private Service Access (PSA)** — a VPC peering to the Google-managed producer network; the instance gets a private RFC 1918 address from a range you reserve. Requires no public IP at all.
2. **Cloud SQL Auth Proxy / Language Connectors** — a client-side shim that establishes a mutually-authenticated TLS tunnel using IAM, so no IP allowlisting and no static credentials. In Kubernetes this runs as a **sidecar** with Workload Identity.
3. Public IP with authorized networks — acceptable only with `require_ssl` and tight CIDRs; treat as legacy.

### 2.3 AlloyDB for PostgreSQL — disaggregated storage and the HTAP case

AlloyDB is where the exam's "PostgreSQL but bigger" answer lives, and architecturally it is the most interesting of the relational options.

**Disaggregated architecture.** The compute node runs PostgreSQL, but the storage layer is replaced. Instead of the engine writing full 8 KiB pages to a disk, it ships **WAL records** to a regional **Log Processing Service (LPS)**. The LPS materializes pages asynchronously and in parallel across zones, and the storage layer serves pages back to compute. Implications:

- **Writes are log-only** from the engine's perspective — no full-page writes, no checkpoint storms, no vacuum-driven write amplification against a single disk.
- **Read pools scale independently** of the primary and share the same storage layer, so adding read capacity does not replay WAL on each replica and does not create per-replica lag from replication apply.
- **Backups are storage-layer and continuous**, so PITR is cheap and restore is fast.
- The **columnar engine** keeps an in-memory columnar representation of hot columns; the planner can choose columnar or row access per query. This is what makes AlloyDB genuinely HTAP — analytical queries can run on the operational database without a separate warehouse, up to a point.
- **Index Advisor** and query insights are built in.
- SLA is **99.99%**, inclusive of maintenance (AlloyDB explicitly does not exclude maintenance windows from its availability commitment — a real differentiator in DR paperwork).

**When AlloyDB is *not* the answer:** if you need write throughput beyond one primary node's ceiling, or global strong consistency across continents, AlloyDB does not solve it — Spanner does. AlloyDB scales *up* and scales *reads out*; it does not shard writes.

### 2.4 Spanner — TrueTime, Paxos, and external consistency

**Why it exists.** Spanner is the only product in the portfolio that provides **horizontally scalable, strongly consistent, relational transactions across regions**. If a question contains "global", "strongly consistent", "relational", and "scale horizontally" — or mentions five nines — the answer is Spanner.

**Internals worth knowing even for a leader-level exam, because they explain the trade-offs:**

- **TrueTime** is a globally distributed clock API backed by GPS receivers and atomic clocks in every datacenter. It returns an *interval* `[earliest, latest]` with a bounded uncertainty ε (single-digit milliseconds). Spanner assigns each committed transaction a timestamp and *waits out* the uncertainty before acknowledging (commit-wait). This is what buys **external consistency (linearizability)**: if transaction T1 commits before T2 starts in real time, T1's timestamp is strictly less than T2's, globally. No other managed relational database offers this.
- Data is range-partitioned into **splits**; each split is replicated by a **Paxos group**, with a leader per group. Writes go to the leader and need a quorum; reads at a timestamp can be served by any up-to-date replica.
- **Replica types**: read-write (voting, full data), read-only (non-voting, serve stale/timestamped reads locally), and **witness** (votes, no data — used to form quorums cheaply in a third region). A multi-region config like `nam3` uses read-write replicas in two regions plus a witness in a third.
- **Capacity** is expressed in **processing units** (PU); 1000 PU = 1 node. Storage scales to **10 TB per node**. Autoscaler is available.
- **Interleaved tables** physically colocate child rows with their parent row, turning a join into a local scan — the single most important schema-design lever.
- **Hotspotting** is the dominant failure mode. Monotonically increasing keys (timestamps, sequences, `AUTO_INCREMENT`) concentrate all writes on one split's leader. Mitigations: UUIDv4 / bit-reversed sequences, hashed key prefixes, or `AUTO_INCREMENT`-style bit-reversed positive sequences. **Key Visualizer** is the diagnostic tool.
- Reads: **strong reads** (default, may cross regions to the leader) vs **stale reads** (`exact_staleness` / `max_staleness`) which are served locally and are dramatically cheaper in latency. Choosing bounded staleness for read paths that tolerate it is the standard optimization.
- **PostgreSQL interface** and GoogleSQL dialect are both supported; **PITR** via `version_retention_period` (up to 7 days).
- SLA: **99.999%** multi-region, **99.99%** regional.
- Hard limit to remember: **80,000 mutations per commit** — bulk loaders must batch.

**The honest trade-off:** Spanner is expensive at small scale, imposes schema-design discipline (no arbitrary secondary-index-free query patterns, no cross-split joins for free), and its minimum viable footprint is larger than a Cloud SQL instance. Do not choose it for a departmental app.

### 2.5 Bigtable — wide-column, key-ordered, petabyte-scale

**Internals.** Bigtable is a sparse, sorted, three-dimensional map: `(row key, column family:qualifier, timestamp) → value`. Data is split into **tablets** by contiguous row-key range; tablets are stored as immutable **SSTables** on Colossus with a write-ahead log and an in-memory memtable. **Compute and storage are separated** — nodes hold no data, only tablet ownership and caches. Therefore:

- **Rebalancing is metadata-only.** Adding nodes reassigns tablet pointers, not bytes; capacity changes take effect in minutes, though the cache warms gradually.
- **Atomicity is per row only.** No multi-row transactions, no joins, no secondary indexes. The row key *is* the index; you design one row key per query pattern, and you denormalize.
- **Row key design is the whole game.** Sequential keys (raw timestamps, sequential device IDs) create a hot tablet. Standard patterns: field promotion (`deviceId#reversedTimestamp`), salting, and key reversal.
- **Replication** across clusters is **eventually consistent** (multi-primary). An **app profile** selects routing: **single-cluster routing** (gives read-your-writes and row-level transaction support) vs **multi-cluster routing** (automatic failover, higher availability, but no cross-cluster consistency guarantee and no single-row read-modify-write).
- **Capacity heuristics**: ~10,000 QPS per node for 1 KB rows on SSD; 5 TB/node SSD, 16 TB/node HDD. Keep average CPU under ~70% (60% if replicated for failover headroom) and watch the **hottest node**, not the average. Autoscaling targets a CPU utilization figure.
- Interfaces: HBase-compatible API, `cbt`/`gcloud bigtable`, and it is the storage engine behind OpenTSDB/JanusGraph-style workloads.
- SLA: 99.9% single cluster, 99.99% multi-cluster routing in one region, **99.999%** multi-cluster routing across regions.

**Use it for:** time-series/IoT telemetry, financial tick data, ad-tech user profiles, personalization feature stores, graph adjacency, monitoring backends — anything measured in TB-to-PB with high sustained write rates and known access keys.

### 2.6 Firestore — documents, realtime, and mobile/web

Firestore is a document database with two mutually exclusive modes chosen **at database creation**:

| | **Native mode** | **Datastore mode** |
|---|---|---|
| Clients | Mobile/web SDKs with realtime listeners and offline persistence | Server-side only |
| Consistency | Strong | Strong |
| Security | Firebase Security Rules (client-direct access) | IAM only |
| Best for | Consumer apps, chat, collaborative UIs, live dashboards | Server backends migrating from App Engine Datastore |

Mechanics: documents up to 1 MiB, automatic indexing of single fields, **explicit composite indexes** required for multi-field queries (the query fails with a link to create the index — this is by design and is the most common first-week error). Sustained writes to a *single document* are limited to roughly one per second; hot document/hot index-range design errors are the failure mode. Traffic ramps must follow the **500/50/5 rule**: start at 500 ops/sec, then increase by 50% every 5 minutes, so the backend can split ranges ahead of you. Multi-region configurations carry a **99.999%** SLA; regional, 99.99%.

### 2.7 Memorystore — caching, explicitly non-durable

Managed Redis, Valkey, and Memcached. Design rules:

- It is a **cache or an ephemeral store**, not a system of record. Even with persistence (RDB/AOF) and Standard-tier HA replicas, treat data as reconstructible.
- Standard tier = primary + replica with automatic failover; **read replicas** can serve reads. Memorystore for Redis Cluster shards horizontally for multi-TB, higher-throughput cases with a 99.99% SLA.
- **Eviction policy** (`maxmemory-policy`) and the **`maxmemory-gb` headroom** are the two tunables that decide whether you get a cache or an outage. `noeviction` on a full instance turns cache pressure into write errors in the application.
- Patterns: cache-aside (read-through with TTL), session store, rate limiter, leaderboard (sorted sets), pub/sub fan-out for non-durable signalling.

### 2.8 BigQuery — the analytics answer

**Architecture.** BigQuery is four decoupled systems: **Dremel** (multi-level serving tree execution engine), **Colossus** (storage, with the **Capacitor** columnar format), **Jupiter** (petabit datacenter network that makes shuffle across the tree feasible), and **Borg** (orchestration). Because storage and compute are separate and communicate over Jupiter, you can scan a petabyte without provisioning a cluster, and storage costs the same whether you query it or not.

Operational levers:

- **Pricing/compute model**: **on-demand** (billed per TB scanned) vs **Editions** — Standard / Enterprise / Enterprise Plus — with **reservations** of **slots** (a slot is a unit of CPU+RAM+network), **autoscaling** between a baseline and a maximum, and 1-/3-year commitments for discounts. Editions plus autoscaling is the standard production choice because it bounds cost and isolates workloads.
- **Partitioning** (by ingestion time, a DATE/TIMESTAMP column, or an integer range) prunes bytes scanned; **`require_partition_filter`** is the guardrail that prevents a junior analyst's `SELECT *` from scanning five years. **Clustering** (up to 4 columns, order matters) sorts within partitions for further block pruning.
- **Storage billing**: logical vs **physical (compressed) bytes** — switching a dataset to physical billing typically cuts storage cost substantially for well-compressing data, at a higher per-GB rate.
- **Time travel** (2–7 days, default 7) plus a 7-day **fail-safe** window is your undelete path.
- **Streaming ingest**: the **Storage Write API** (exactly-once, cheaper, the current recommendation) supersedes the legacy `insertAll` streaming API.
- **BI Engine** is an in-memory acceleration layer for sub-second dashboards; **materialized views** are incrementally maintained and automatically substituted by the optimizer.
- **BigLake / external tables / Omni** query data in place in GCS, Amazon S3, or Azure Blob with unified governance — the answer for "we cannot move the data".
- **Analytics Hub** publishes datasets as shareable listings (zero-copy) — the answer for "share data with partners without copying it".
- **BigQuery ML** trains models with SQL; **Dataplex** provides the governance/catalog/lineage plane; **Looker / Looker Studio** the semantic and BI layer.
- SLA: 99.99%.

> **Exam trap #3:** "Real-time streaming analytics dashboard" is a *pipeline* question, not just a storage question: **Pub/Sub** (ingest, durable decoupling) → **Dataflow** (Apache Beam, unified stream/batch, windowing and exactly-once) → **BigQuery** (analyze) → **Looker** (visualize). Memorize that chain; it is worth multiple questions across the domain.

### 2.9 Getting data in — migration and integration products

| Need | Product | Mechanism |
|---|---|---|
| Homogeneous or heterogeneous DB migration with minimal downtime (Oracle/SQL Server → PostgreSQL/AlloyDB; MySQL → Cloud SQL) | **Database Migration Service** | Continuous replication + cutover; Gemini-assisted schema/code conversion for heterogeneous |
| Ongoing change data capture into BigQuery/GCS | **Datastream** | Serverless CDC from Oracle, MySQL, PostgreSQL, SQL Server |
| Bulk object transfer from S3/Azure/HTTP/on-prem to GCS | **Storage Transfer Service** | Managed, incremental, bandwidth-throttled, agent-based for on-prem |
| Offline transfer of very large datasets (limited/no bandwidth) | **Transfer Appliance** | Physical shippable appliance |
| Batch/stream ETL and ELT | **Dataflow** (Beam) / **Dataproc** (Spark/Hadoop) / **Data Fusion** (visual, CDAP) / **Dataform** (SQL-based ELT in BigQuery) | choose by team skill set: Beam code / existing Spark / no-code / SQL |
| Orchestration | **Cloud Composer** (managed Airflow) | DAG scheduling across the above |
| Governance, catalog, lineage, quality, data mesh | **Dataplex** (incl. Data Catalog) | Metadata plane over BigQuery + GCS |
| Application-consistent backup of VMs/DBs across clouds | **Backup and DR Service** | Centralized policy, immutable vault |

---

## 3. Comparative trade-off tables

### 3.1 Operational (OLTP) databases

| Dimension | Cloud SQL | AlloyDB | Spanner | Bigtable | Firestore | Memorystore |
|---|---|---|---|---|---|---|
| Data model | Relational | Relational (PG) | Relational (GoogleSQL/PG) | Wide-column | Document | Key–value / structures |
| Engine compatibility | MySQL, PostgreSQL, SQL Server | PostgreSQL wire-compatible | Custom (PG interface) | HBase API | Proprietary + Firebase SDK | Redis / Valkey / Memcached |
| Transactions | Full ACID, single instance | Full ACID, single primary | **ACID, cross-row, cross-region, externally consistent** | **Single-row only** | ACID multi-doc (≤500 docs/txn) | Lua/MULTI, non-durable |
| Write scaling | Vertical (one primary) | Vertical primary, log-disaggregated storage | **Horizontal (add nodes/PU)** | **Horizontal (add nodes)** | **Horizontal (automatic)** | Horizontal (Cluster) |
| Read scaling | ≤10 async read replicas | Read pools (multiple instances × nodes), shared storage | Read-only replicas, stale reads | Replicated clusters | Automatic | Read replicas |
| Joins / ad-hoc SQL | Yes | Yes | Yes (design-constrained) | **No** | Limited queries, no joins | No |
| Consistency across regions | Async replica (lag) | Cross-region replicas (async) | **Strong (external)** | **Eventual** | Strong (multi-region) | n/a |
| Typical p99 point read | 1–10 ms | 1–5 ms (columnar for analytics) | 5–15 ms (strong), <5 ms (stale/local) | <10 ms | 10–50 ms | **<1 ms** |
| Practical size ceiling | ~64 TB | Multi-TB, auto-grown | **Petabytes** (10 TB/node) | **Petabytes** (5 TB/node SSD) | Petabytes | ~TB (RAM-bound) |
| SLA (best config) | 99.95% / **99.99%** (Enterprise Plus) | **99.99%** (incl. maintenance) | **99.999%** | **99.999%** | **99.999%** | 99.9% / 99.99% (Cluster) |
| Schema change cost | Engine-native DDL, locking risk | Engine-native, near-zero-downtime ops | Online, background-validated | Schemaless per row | Schemaless | n/a |
| Chief risk | Vertical ceiling, failover drops connections | Single-primary write ceiling | Hotspotting from monotonic keys, cost floor | Bad row-key design, no joins | Hot documents, missing composite indexes | Data loss (by design), eviction |

### 3.2 Analytical stores

| Dimension | BigQuery | AlloyDB columnar engine | Bigtable + Dataflow | Cloud SQL read replica |
|---|---|---|---|---|
| Best for | Warehouse, lakehouse, PB scans, BI, ML | Operational reporting on live OLTP data | Real-time aggregation on time series | Small reporting offload |
| Compute model | Serverless slots (on-demand or reservations) | Attached to the AlloyDB instance | Provisioned nodes + Dataflow workers | Instance-sized |
| Freshness | Seconds (Storage Write API) to minutes | **Real-time — same transaction state** | Seconds | Replica lag |
| Concurrency | Very high, isolated by reservation | Bounded by instance | Bounded by nodes | Bounded by replica |
| Federation | GCS, S3, Azure (BigLake/Omni), Spanner, Bigtable, Cloud SQL | No | No | No |
| Cost driver | Bytes scanned **or** slot-hours + storage | Instance hours | Node-hours + pipeline | Instance hours |
| Anti-pattern | Single-row OLTP updates, sub-100 ms point lookups | Petabyte historical scans | Ad-hoc SQL exploration | Any real analytics at scale |

### 3.3 Consistency semantics — the discriminator table

| Product | Atomicity scope | Read semantics | Cross-region write behaviour |
|---|---|---|---|
| Spanner | Arbitrary rows/tables, any region | Strong (default) or bounded-stale | Synchronous Paxos quorum; externally consistent |
| Cloud SQL / AlloyDB | Whole instance | Strong on primary; eventual on replicas | Asynchronous; failover implies possible data loss window |
| Firestore | ≤500 documents per transaction | Strong | Synchronous within multi-region config |
| Bigtable | **One row** | Read-your-writes only with single-cluster routing | Eventual, multi-primary; last-write-wins by timestamp |
| Cloud Storage | One object | Strong read-after-write; strongly consistent listing | Async (dual-region turbo replication: 15-min RPO SLO) |
| Memorystore | Single node/shard | Strong on primary; replicas may lag | n/a |
| BigQuery | Statement/job level (ACID DML) | Snapshot isolation, time travel | Dataset is regional; cross-region needs replication/Omni |

---

## 4. Reference architecture as complete infrastructure code

The scenario: a retail platform. Orders must be globally consistent (Spanner). The product catalogue is a lift-and-shift PostgreSQL app with heavy reporting (AlloyDB with a read pool). Clickstream telemetry is high-volume time series (Bigtable). Sessions are cached (Memorystore). Media and raw event archives live in Cloud Storage with lifecycle governance. Everything lands in BigQuery for analytics. Workloads run on GKE with Workload Identity — **no service-account keys anywhere**.

### 4.1 Terraform — network foundation and Private Service Access

```hcl
# ---------------------------------------------------------------------------
# versions.tf
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.12"
    }
  }

  backend "gcs" {
    bucket = "acme-retail-tfstate"
    prefix = "data-platform/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# variables.tf
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "Target project for the data platform."
  type        = string
}

variable "region" {
  description = "Primary region for regional resources."
  type        = string
  default     = "europe-west1"
}

variable "secondary_region" {
  description = "Region used for DR replicas and dual-region storage."
  type        = string
  default     = "europe-west4"
}

variable "spanner_config" {
  description = "Spanner instance configuration. Multi-region for 99.999% SLA."
  type        = string
  default     = "eur5" # Netherlands + Belgium read-write, witness in a third zone set
}

variable "authorized_cidrs" {
  description = "Operator CIDRs permitted through the bastion path."
  type        = list(string)
  default     = []
}

locals {
  labels = {
    env        = "prod"
    system     = "retail-data-platform"
    managed_by = "terraform"
    cost_center = "retail-eng"
  }
}

# ---------------------------------------------------------------------------
# network.tf — VPC, subnets, and the PSA range consumed by Cloud SQL/AlloyDB
# ---------------------------------------------------------------------------
resource "google_compute_network" "data" {
  name                            = "vpc-data-prod"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "gke" {
  name                     = "snet-gke-${var.region}"
  ip_cidr_range            = "10.20.0.0/20"
  region                   = var.region
  network                  = google_compute_network.data.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.60.0.0/14"
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.64.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Reserved range handed to the Google-managed producer VPC. Size it generously:
# it cannot be shrunk while services are attached, and every managed instance
# in the peering draws addresses from it.
resource "google_compute_global_address" "psa_range" {
  name          = "psa-managed-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  address       = "10.128.0.0"
  network       = google_compute_network.data.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.data.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}

# Export custom routes so managed instances can be reached from peered/on-prem
# networks reachable via this VPC.
resource "google_compute_network_peering_routes_config" "psa_routes" {
  peering              = google_service_networking_connection.psa.peering
  network              = google_compute_network.data.name
  import_custom_routes = true
  export_custom_routes = true
}

resource "google_compute_router" "nat" {
  name    = "cr-data-${var.region}"
  region  = var.region
  network = google_compute_network.data.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-data-${var.region}"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

### 4.2 Terraform — Cloud SQL (HA, Enterprise Plus, private-only)

```hcl
# ---------------------------------------------------------------------------
# cloudsql.tf
# ---------------------------------------------------------------------------
resource "google_sql_database_instance" "catalog_legacy" {
  # Instance names are tombstoned for ~1 week after deletion; suffix them.
  name                = "sql-catalog-prod-a1"
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = true

  settings {
    tier              = "db-perf-optimized-N-8" # Enterprise Plus machine family
    edition           = "ENTERPRISE_PLUS"       # 99.99% SLA + data cache
    availability_type = "REGIONAL"              # synchronous standby in a 2nd zone
    disk_type         = "PD_SSD"
    disk_size         = 500
    disk_autoresize   = true
    disk_autoresize_limit = 4000

    data_cache_config {
      data_cache_enabled = true # local NVMe read cache
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      location                       = var.region
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled                                  = false # no public IP
      private_network                               = google_compute_network.data.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 4500
      record_application_tags = true
      record_client_address   = false
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000" # log statements slower than 1s
    }

    database_flags {
      name  = "max_connections"
      value = "800"
    }

    user_labels = local.labels
  }

  depends_on = [google_service_networking_connection.psa]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_sql_database" "catalog" {
  name     = "catalog"
  instance = google_sql_database_instance.catalog_legacy.name
  charset  = "UTF8"
}

# Cross-region read replica: DR target and analytics offload.
resource "google_sql_database_instance" "catalog_replica_dr" {
  name                 = "sql-catalog-prod-a1-replica-ew4"
  database_version     = "POSTGRES_16"
  region               = var.secondary_region
  master_instance_name = google_sql_database_instance.catalog_legacy.name
  deletion_protection  = false

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = "db-perf-optimized-N-4"
    edition           = "ENTERPRISE_PLUS"
    availability_type = "ZONAL"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.data.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    user_labels = merge(local.labels, { role = "dr-replica" })
  }
}

# IAM database authentication: the GKE workload's Google SA becomes a DB user.
# No password is ever created, stored, or rotated.
resource "google_sql_user" "app_iam" {
  name     = trimsuffix(google_service_account.catalog_app.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.catalog_legacy.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}
```

### 4.3 Terraform — AlloyDB with a read pool

```hcl
# ---------------------------------------------------------------------------
# alloydb.tf
# ---------------------------------------------------------------------------
resource "google_alloydb_cluster" "catalog" {
  cluster_id = "alloydb-catalog-prod"
  location   = var.region
  network_config {
    network = google_compute_network.data.id
  }

  initial_user {
    user     = "postgres"
    password = google_secret_manager_secret_version.alloydb_root.secret_data
  }

  continuous_backup_config {
    enabled              = true
    recovery_window_days = 14
  }

  automated_backup_policy {
    location      = var.region
    backup_window = "3600s"
    enabled       = true

    weekly_schedule {
      days_of_week = ["MONDAY", "THURSDAY"]
      start_times {
        hours = 2
      }
    }

    quantity_based_retention {
      count = 20
    }
  }

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.catalog.name
  instance_id   = "primary"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 16
  }

  # Enable the columnar engine so operational reporting stays on the OLTP DB.
  database_flags = {
    "google_columnar_engine.enabled"      = "on"
    "google_columnar_engine.memory_size_in_mb" = "8192"
    "alloydb.enable_pgaudit"              = "on"
    "password.enforce_complexity"         = "on"
  }

  availability_type = "REGIONAL"
  labels            = local.labels
}

resource "google_alloydb_instance" "read_pool" {
  cluster       = google_alloydb_cluster.catalog.name
  instance_id   = "read-pool-analytics"
  instance_type = "READ_POOL"

  read_pool_config {
    node_count = 3
  }

  machine_config {
    cpu_count = 8
  }

  database_flags = {
    "google_columnar_engine.enabled" = "on"
  }

  labels = merge(local.labels, { role = "read-pool" })

  depends_on = [google_alloydb_instance.primary]
}
```

### 4.4 Terraform — Spanner (multi-region, autoscaled, PITR)

```hcl
# ---------------------------------------------------------------------------
# spanner.tf
# ---------------------------------------------------------------------------
resource "google_spanner_instance" "orders" {
  name         = "spanner-orders-prod"
  config       = var.spanner_config # eur5 => multi-region, 99.999% SLA
  display_name = "Retail Orders (multi-region)"

  autoscaling_config {
    autoscaling_limits {
      # Processing units: 1000 PU == 1 node. Start at 2000 PU, cap at 20000.
      min_processing_units = 2000
      max_processing_units = 20000
    }

    autoscaling_targets {
      # 45% for multi-region (leader work is remote); 65% is the
      # regional-configuration recommendation.
      high_priority_cpu_utilization_percent = 45
      storage_utilization_percent           = 90
    }
  }

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_spanner_database" "orders" {
  instance = google_spanner_instance.orders.name
  name     = "orders"

  # PITR window. Costs storage; 7 days is the maximum.
  version_retention_period = "7d"

  database_dialect = "GOOGLE_STANDARD_SQL"

  ddl = [
    # Customers is the parent; Orders is INTERLEAVED so a customer's orders
    # live in the same split and the join is a local scan, not a distributed one.
    <<-EOT
    CREATE TABLE Customers (
      CustomerId   STRING(36) NOT NULL,
      Email        STRING(320) NOT NULL,
      DisplayName  STRING(200),
      CountryCode  STRING(2) NOT NULL,
      CreatedAt    TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
    ) PRIMARY KEY (CustomerId)
    EOT
    ,
    <<-EOT
    CREATE TABLE Orders (
      CustomerId    STRING(36) NOT NULL,
      OrderId       STRING(36) NOT NULL,
      Status        STRING(20) NOT NULL,
      CurrencyCode  STRING(3) NOT NULL,
      TotalMinor    INT64 NOT NULL,
      PlacedAt      TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
      UpdatedAt     TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
    ) PRIMARY KEY (CustomerId, OrderId),
      INTERLEAVE IN PARENT Customers ON DELETE CASCADE
    EOT
    ,
    <<-EOT
    CREATE TABLE OrderLines (
      CustomerId   STRING(36) NOT NULL,
      OrderId      STRING(36) NOT NULL,
      LineNo       INT64 NOT NULL,
      Sku          STRING(64) NOT NULL,
      Quantity     INT64 NOT NULL,
      UnitMinor    INT64 NOT NULL,
    ) PRIMARY KEY (CustomerId, OrderId, LineNo),
      INTERLEAVE IN PARENT Orders ON DELETE CASCADE
    EOT
    ,
    # Secondary index on a timestamp would hotspot on write. STORING makes it
    # a covering index; the shard key prefix spreads the write load across
    # splits so the "recent orders" query does not serialize on one leader.
    <<-EOT
    CREATE INDEX OrdersByStatusShard
      ON Orders (Status, PlacedAt DESC)
      STORING (TotalMinor, CurrencyCode)
    EOT
    ,
    # Row-deletion policy: Spanner garbage-collects expired rows in the
    # background, so no cron job is needed to prune history.
    <<-EOT
    CREATE TABLE OrderAuditLog (
      AuditId    STRING(36) NOT NULL,
      OrderId    STRING(36) NOT NULL,
      Actor      STRING(320),
      Action     STRING(40) NOT NULL,
      OccurredAt TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
    ) PRIMARY KEY (AuditId),
      ROW DELETION POLICY (OLDER_THAN(OccurredAt, INTERVAL 400 DAY))
    EOT
  ]

  deletion_protection = true
}

resource "google_spanner_database_iam_member" "app_rw" {
  instance = google_spanner_instance.orders.name
  database = google_spanner_database.orders.name
  role     = "roles/spanner.databaseUser"
  member   = "serviceAccount:${google_service_account.orders_app.email}"
}

# Scheduled backups, retained 35 days.
resource "google_spanner_backup_schedule" "orders_daily" {
  provider = google-beta
  instance = google_spanner_instance.orders.name
  database = google_spanner_database.orders.name
  name     = "daily-full"

  retention_duration = "3024000s" # 35 days

  spec {
    cron_spec {
      text = "0 1 * * *"
    }
  }

  full_backup_spec {}
}
```

### 4.5 Terraform — Bigtable (replicated, autoscaled, app profiles)

```hcl
# ---------------------------------------------------------------------------
# bigtable.tf
# ---------------------------------------------------------------------------
resource "google_bigtable_instance" "telemetry" {
  name          = "bt-telemetry-prod"
  deletion_protection = true

  # Two clusters in two regions with multi-cluster routing => 99.999% SLA.
  cluster {
    cluster_id   = "bt-telemetry-ew1-a"
    zone         = "${var.region}-b"
    storage_type = "SSD"

    autoscaling_config {
      min_nodes      = 3
      max_nodes      = 30
      cpu_target     = 60 # headroom for absorbing the other cluster's traffic
      storage_target = 4096 # GiB per node before scaling out
    }
  }

  cluster {
    cluster_id   = "bt-telemetry-ew4-a"
    zone         = "${var.secondary_region}-a"
    storage_type = "SSD"

    autoscaling_config {
      min_nodes      = 3
      max_nodes      = 30
      cpu_target     = 60
      storage_target = 4096
    }
  }

  labels = local.labels
}

# Serving profile: automatic failover, highest availability.
# Cost: no read-your-writes across clusters, no single-row read-modify-write.
resource "google_bigtable_app_profile" "serving" {
  instance       = google_bigtable_instance.telemetry.name
  app_profile_id = "serving-multi"

  multi_cluster_routing_use_any = true

  standard_isolation {
    priority = "PRIORITY_HIGH"
  }

  ignore_warnings = true
}

# Batch/ETL profile: pinned to one cluster so Dataflow scans never
# compete with the serving path, and single-row transactions are available.
resource "google_bigtable_app_profile" "batch" {
  instance       = google_bigtable_instance.telemetry.name
  app_profile_id = "batch-etl"

  single_cluster_routing {
    cluster_id                 = "bt-telemetry-ew4-a"
    allow_transactional_writes = true
  }

  standard_isolation {
    priority = "PRIORITY_LOW"
  }

  ignore_warnings = true
}

resource "google_bigtable_table" "device_events" {
  name          = "device_events"
  instance_name = google_bigtable_instance.telemetry.name

  # Row key contract (documented here because Bigtable cannot enforce it):
  #   <tenantId>#<deviceId>#<reverseTimestampMillis>
  # - tenantId + deviceId spread writes across tablets (no monotonic prefix)
  # - reverse timestamp puts the newest row first, so "latest N readings"
  #   is a prefix scan with a limit rather than a full-range sort.

  column_family {
    family = "metrics"
  }

  column_family {
    family = "meta"
  }

  # Split points pre-created so the first write burst does not hammer one tablet.
  split_keys = ["t01#", "t02#", "t03#", "t04#", "t05#", "t06#", "t07#"]

  change_stream_retention = "24h0m0s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigtable_gc_policy" "metrics_gc" {
  instance_name = google_bigtable_instance.telemetry.name
  table         = google_bigtable_table.device_events.name
  column_family = "metrics"

  gc_rules = jsonencode({
    mode = "union"
    rules = [
      { max_age = "2160h" },   # 90 days
      { max_version = 3 }
    ]
  })

  deletion_policy = "ABANDON"
}
```

### 4.6 Terraform — Memorystore, Cloud Storage, BigQuery

```hcl
# ---------------------------------------------------------------------------
# memorystore.tf
# ---------------------------------------------------------------------------
resource "google_redis_instance" "sessions" {
  name               = "redis-sessions-prod"
  tier               = "STANDARD_HA" # primary + replica, automatic failover
  memory_size_gb     = 26
  region             = var.region
  location_id        = "${var.region}-b"
  alternative_location_id = "${var.region}-c"

  redis_version      = "REDIS_7_2"
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  authorized_network = google_compute_network.data.id
  reserved_ip_range  = google_compute_global_address.psa_range.name

  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  read_replicas_mode = "READ_REPLICAS_ENABLED"
  replica_count      = 2

  redis_configs = {
    # allkeys-lru: this is a CACHE. Never `noeviction` here — a full instance
    # would start returning OOM errors to the application instead of evicting.
    "maxmemory-policy"    = "allkeys-lru"
    "notify-keyspace-events" = "Ex"
  }

  persistence_config {
    persistence_mode    = "RDB"
    rdb_snapshot_period = "TWELVE_HOURS"
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 4
        minutes = 0
      }
    }
  }

  labels = local.labels
  depends_on = [google_service_networking_connection.psa]
}

# ---------------------------------------------------------------------------
# storage.tf
# ---------------------------------------------------------------------------

# Hot media: dual-region with turbo replication (15-min RPO SLO).
resource "google_storage_bucket" "media" {
  name                        = "${var.project_id}-media-prod"
  location                    = "EUR4" # dual-region: europe-north1 + europe-west4
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  custom_placement_config {
    data_locations = ["EUROPE-NORTH1", "EUROPE-WEST4"]
  }

  rpo = "ASYNC_TURBO"

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age                = 30
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = local.labels
}

# Raw event archive: Autoclass, so unpredictable access never incurs
# retrieval or early-deletion fees.
resource "google_storage_bucket" "event_archive" {
  name                        = "${var.project_id}-event-archive-prod"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  autoclass {
    enabled                = true
    terminal_storage_class = "ARCHIVE"
  }

  lifecycle_rule {
    condition {
      age = 2555 # ~7 years, the regulatory retention period
    }
    action {
      type = "Delete"
    }
  }

  labels = local.labels
}

# Compliance vault: retention policy that will be LOCKED. Once locked, the
# policy cannot be shortened or removed — by anyone, including project owners.
resource "google_storage_bucket" "compliance_vault" {
  name                        = "${var.project_id}-compliance-vault"
  location                    = var.region
  storage_class               = "ARCHIVE"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  retention_policy {
    is_locked        = true
    retention_period = 220752000 # 7 years in seconds
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.storage.id
  }

  labels = merge(local.labels, { compliance = "worm" })

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# bigquery.tf
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "analytics" {
  dataset_id                      = "retail_analytics"
  location                        = "EU" # multi-region; must match query jobs
  description                     = "Curated retail analytics marts."
  default_table_expiration_ms     = null
  default_partition_expiration_ms = null
  max_time_travel_hours           = 168 # 7 days
  storage_billing_model           = "PHYSICAL" # compressed-byte billing

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery.id
  }

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_table" "fact_orders" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "fact_orders"
  deletion_protection = true

  # Partition on the event date; require a filter so no query can accidentally
  # scan the entire history.
  time_partitioning {
    type                     = "DAY"
    field                    = "placed_at"
    expiration_ms            = 94608000000 # 3 years
    require_partition_filter = true
  }

  # Cluster order matters: most-selective, most-frequently-filtered first.
  clustering = ["country_code", "channel", "sku"]

  schema = jsonencode([
    { name = "order_id",     type = "STRING",    mode = "REQUIRED" },
    { name = "customer_id",  type = "STRING",    mode = "REQUIRED" },
    { name = "placed_at",    type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "country_code", type = "STRING",    mode = "REQUIRED" },
    { name = "channel",      type = "STRING",    mode = "REQUIRED" },
    { name = "sku",          type = "STRING",    mode = "REQUIRED" },
    { name = "quantity",     type = "INT64",     mode = "REQUIRED" },
    { name = "total_minor",  type = "INT64",     mode = "REQUIRED" },
    { name = "currency",     type = "STRING",    mode = "REQUIRED" },
    {
      name = "shipping", type = "RECORD", mode = "NULLABLE",
      fields = [
        { name = "carrier", type = "STRING", mode = "NULLABLE" },
        { name = "eta",     type = "DATE",   mode = "NULLABLE" },
      ]
    },
  ])

  labels = local.labels
}

# Incrementally maintained materialized view; the optimizer substitutes it
# automatically for matching queries.
resource "google_bigquery_table" "mv_daily_revenue" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "mv_daily_revenue"
  deletion_protection = false

  materialized_view {
    query = <<-SQL
      SELECT
        DATE(placed_at)                AS order_date,
        country_code,
        channel,
        COUNT(*)                       AS orders,
        SUM(total_minor) / 100.0       AS revenue
      FROM `${var.project_id}.retail_analytics.fact_orders`
      GROUP BY order_date, country_code, channel
    SQL

    enable_refresh      = true
    refresh_interval_ms = 1800000 # 30 minutes
  }

  labels = local.labels
}

# Editions reservation: bounds cost and isolates workloads. Autoscaling adds
# slots above the baseline only when queued work justifies it.
resource "google_bigquery_reservation" "analytics" {
  name              = "res-analytics-eu"
  location          = "EU"
  edition           = "ENTERPRISE"
  slot_capacity     = 200   # baseline, always-on
  autoscale {
    max_slots = 1000        # ceiling for burst
  }
  ignore_idle_slots = false  # let other reservations borrow idle slots
  concurrency       = 0      # 0 = let BigQuery decide
}

resource "google_bigquery_reservation_assignment" "bi_workload" {
  location    = "EU"
  reservation = google_bigquery_reservation.analytics.id
  assignee    = "projects/${var.project_id}"
  job_type    = "QUERY"
}

# ---------------------------------------------------------------------------
# iam.tf — Workload Identity, least privilege, no keys
# ---------------------------------------------------------------------------
resource "google_service_account" "orders_app" {
  account_id   = "sa-orders-app"
  display_name = "Orders service (Spanner writer)"
}

resource "google_service_account" "catalog_app" {
  account_id   = "sa-catalog-app"
  display_name = "Catalog service (Cloud SQL / AlloyDB client)"
}

resource "google_project_iam_member" "catalog_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.catalog_app.email}"
}

resource "google_project_iam_member" "catalog_sql_iam_login" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.catalog_app.email}"
}

# Bind the Kubernetes SA to the Google SA (Workload Identity Federation for GKE).
resource "google_service_account_iam_member" "orders_wi" {
  service_account_id = google_service_account.orders_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[retail/orders-api]"
}

resource "google_service_account_iam_member" "catalog_wi" {
  service_account_id = google_service_account.catalog_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[retail/catalog-api]"
}
```

### 4.7 Kubernetes manifests — the application that consumes all of it

```yaml
# ---------------------------------------------------------------------------
# k8s/00-namespace-and-identity.yaml
# ---------------------------------------------------------------------------
apiVersion: v1
kind: Namespace
metadata:
  name: retail
  labels:
    app.kubernetes.io/part-of: retail-data-platform
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog-api
  namespace: retail
  annotations:
    # Workload Identity: pods using this KSA obtain tokens for this Google SA.
    # No JSON key is ever mounted.
    iam.gke.io/gcp-service-account: sa-catalog-app@acme-retail-prod.iam.gserviceaccount.com
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders-api
  namespace: retail
  annotations:
    iam.gke.io/gcp-service-account: sa-orders-app@acme-retail-prod.iam.gserviceaccount.com
---
# ---------------------------------------------------------------------------
# k8s/10-catalog-config.yaml
# ---------------------------------------------------------------------------
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalog-config
  namespace: retail
data:
  # The app connects to 127.0.0.1 — the Cloud SQL Auth Proxy sidecar terminates
  # locally and tunnels over mTLS. No database IP appears in app config.
  PGHOST: "127.0.0.1"
  PGPORT: "5432"
  PGDATABASE: "catalog"
  PGSSLMODE: "disable"          # the proxy already provides mTLS on the wire
  PGAPPNAME: "catalog-api"
  DB_POOL_MAX: "20"             # per pod; pods x pool <= instance max_connections
  DB_POOL_MIN: "2"
  DB_STATEMENT_TIMEOUT_MS: "8000"
  REDIS_HOST: "10.128.4.19"     # Memorystore PSA address
  REDIS_PORT: "6379"
  REDIS_TLS: "true"
  CACHE_TTL_SECONDS: "300"
---
# ---------------------------------------------------------------------------
# k8s/20-catalog-deployment.yaml
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
  namespace: retail
  labels:
    app.kubernetes.io/name: catalog-api
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
      app.kubernetes.io/name: catalog-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: catalog-api
    spec:
      serviceAccountName: catalog-api
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: catalog-api
      containers:
        # ---- Application ------------------------------------------------
        - name: app
          image: europe-west1-docker.pkg.dev/acme-retail-prod/apps/catalog-api:1.42.0
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: catalog-config
          env:
            - name: REDIS_AUTH
              valueFrom:
                secretKeyRef:
                  name: redis-auth
                  key: auth-string
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            periodSeconds: 10
            failureThreshold: 6
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp

        # ---- Cloud SQL Auth Proxy sidecar --------------------------------
        # Declared as a native sidecar (restartPolicy: Always on an init
        # container) so it starts BEFORE the app and is terminated AFTER it.
        # With the old plain-container pattern the proxy could die first and
        # the app's in-flight transactions would fail during shutdown.
      initContainers:
        - name: cloud-sql-proxy
          restartPolicy: Always
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1
          args:
            - "--structured-logs"
            - "--private-ip"
            - "--auto-iam-authn"
            - "--port=5432"
            - "--health-check"
            - "--http-address=0.0.0.0"
            - "--http-port=9801"
            - "--max-sigterm-delay=30s"
            - "--min-sigterm-delay=5s"
            - "acme-retail-prod:europe-west1:sql-catalog-prod-a1"
          ports:
            - name: proxy-health
              containerPort: 9801
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              memory: "256Mi"
          startupProbe:
            httpGet:
              path: /startup
              port: proxy-health
            periodSeconds: 1
            failureThreshold: 60
          livenessProbe:
            httpGet:
              path: /liveness
              port: proxy-health
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readiness
              port: proxy-health
            periodSeconds: 5
            failureThreshold: 3
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: catalog-api
  namespace: retail
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: catalog-api
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalog-api
  namespace: retail
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: catalog-api
  namespace: retail
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: catalog-api
  minReplicas: 6
  # Ceiling chosen so maxReplicas x DB_POOL_MAX (24 x 20 = 480) stays well
  # under the instance's max_connections=800, leaving room for the replica,
  # migrations, and operator sessions. An HPA that ignores the database's
  # connection budget converts a traffic spike into a connection-refused outage.
  maxReplicas: 24
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
---
# ---------------------------------------------------------------------------
# k8s/30-orders-deployment.yaml — Spanner client, no proxy needed
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: retail
spec:
  replicas: 8
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders-api
    spec:
      serviceAccountName: orders-api
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: europe-west1-docker.pkg.dev/acme-retail-prod/apps/orders-api:2.7.3
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: SPANNER_PROJECT
              value: "acme-retail-prod"
            - name: SPANNER_INSTANCE
              value: "spanner-orders-prod"
            - name: SPANNER_DATABASE
              value: "orders"
            # Session pool: Spanner sessions are a per-node resource. Sizing
            # them too high across many pods exhausts the instance's session
            # limit; too low serializes requests behind session acquisition.
            - name: SPANNER_MIN_SESSIONS
              value: "25"
            - name: SPANNER_MAX_SESSIONS
              value: "100"
            # Read paths that tolerate staleness use a bounded-stale snapshot,
            # served by the nearest replica instead of the leader region.
            - name: SPANNER_READ_STALENESS_MS
              value: "10000"
            - name: GOOGLE_CLOUD_ENABLE_DIRECT_PATH
              value: "true"
          resources:
            requests:
              cpu: "750m"
              memory: "768Mi"
            limits:
              memory: "1536Mi"
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

---

## 5. CLI: commands and real terminal output

### 5.1 Enabling the platform and inspecting Cloud SQL

```console
$ gcloud config set project acme-retail-prod
Updated property [core/project].

$ gcloud services enable \
    sqladmin.googleapis.com \
    alloydb.googleapis.com \
    spanner.googleapis.com \
    bigtable.googleapis.com \
    bigtableadmin.googleapis.com \
    redis.googleapis.com \
    bigquery.googleapis.com \
    datastream.googleapis.com \
    servicenetworking.googleapis.com
Operation "operations/acat.p2-482913044517-8b1f0e3a-2c19-4d6d-9a11-7f0e2c8a4d31" finished successfully.

$ gcloud sql instances describe sql-catalog-prod-a1 \
    --format='table(name, databaseVersion, settings.edition, settings.tier,
                    settings.availabilityType, gceZone, secondaryGceZone, state)'
NAME                 DATABASE_VERSION  EDITION          TIER                   AVAILABILITY_TYPE  GCE_ZONE         SECONDARY_GCE_ZONE  STATE
sql-catalog-prod-a1  POSTGRES_16       ENTERPRISE_PLUS  db-perf-optimized-N-8  REGIONAL           europe-west1-b   europe-west1-c      RUNNABLE

$ gcloud sql instances describe sql-catalog-prod-a1 \
    --format='value(ipAddresses)'
{'ipAddress': '10.128.0.5', 'type': 'PRIVATE'}
```

Note there is no `PRIMARY` public address: `ipv4_enabled = false` held.

### 5.2 Rehearsing the Cloud SQL failover (this is the number your RTO rests on)

```console
$ date -u +%FT%TZ && gcloud sql instances failover sql-catalog-prod-a1 --async
2026-09-06T09:14:02Z
Failover in progress. Operation: projects/acme-retail-prod/operations/8e1a...c4
```

```console
$ gcloud sql operations wait 8e1a2f70-5d31-4c9b-9a02-1f77c4bb90c4 \
    --project acme-retail-prod
Waiting for [operations/8e1a2f70-...] to complete...done.
NAME                                  TYPE      START                     END                       ERROR  STATUS
8e1a2f70-5d31-4c9b-9a02-1f77c4bb90c4  FAILOVER  2026-09-06T09:14:03.114Z  2026-09-06T09:15:11.882Z  -      DONE
```

```console
$ gcloud sql instances describe sql-catalog-prod-a1 \
    --format='value(gceZone, secondaryGceZone)'
europe-west1-c  europe-west1-b
```

The zones swapped and the wall-clock cost was **68 seconds**. During that window the application logged connection resets — expected, because Cloud SQL failover does not preserve TCP sessions. Verify the application's retry behaviour, not just the instance state:

```console
$ kubectl -n retail logs deploy/catalog-api -c app --since=5m \
    | grep -c 'ECONNRESET\|connection terminated'
412

$ kubectl -n retail logs deploy/catalog-api -c app --since=5m \
    | grep -c 'FATAL\|unrecoverable'
0
```

412 reconnects, zero unrecoverable errors: the retry/backoff path works. Had the second count been non-zero, the failover would have been a customer-visible outage regardless of the 99.99% SLA.

### 5.3 Spanner: instance state, a transaction, and hotspot inspection

```console
$ gcloud spanner instances describe spanner-orders-prod \
    --format='table(name.basename(), config.basename(), processingUnits, state)'
NAME                 CONFIG  PROCESSING_UNITS  STATE
spanner-orders-prod  eur5    2000              READY

$ gcloud spanner databases ddl describe orders --instance=spanner-orders-prod | head -20
CREATE TABLE Customers (
  CustomerId STRING(36) NOT NULL,
  Email STRING(320) NOT NULL,
  DisplayName STRING(200),
  CountryCode STRING(2) NOT NULL,
  CreatedAt TIMESTAMP NOT NULL OPTIONS (
    allow_commit_timestamp = true
  ),
) PRIMARY KEY(CustomerId);
CREATE TABLE Orders (
  CustomerId STRING(36) NOT NULL,
  OrderId STRING(36) NOT NULL,
  Status STRING(20) NOT NULL,
  CurrencyCode STRING(3) NOT NULL,
  TotalMinor INT64 NOT NULL,
  PlacedAt TIMESTAMP NOT NULL OPTIONS (
    allow_commit_timestamp = true
  ),
```

```console
$ gcloud spanner rows insert --instance=spanner-orders-prod --database=orders \
    --table=Customers \
    --data=CustomerId=8f2c1d0a-4b7e-4c11-9c2f-1a3b5d7e9f00,Email=ana@example.com,DisplayName='Ana R.',CountryCode=ES,CreatedAt='spanner.commit_timestamp()'
commitTimestamp: '2026-09-06T09:31:44.812993Z'
```

An explicit read-only, bounded-stale query — served locally, no leader round trip:

```console
$ gcloud spanner databases execute-sql orders \
    --instance=spanner-orders-prod \
    --read-timestamp=2026-09-06T09:31:00Z \
    --sql='SELECT CountryCode, COUNT(*) AS c FROM Customers GROUP BY CountryCode ORDER BY c DESC LIMIT 5'
CountryCode  c
ES           418223
FR           301774
DE           288910
NL           142055
BE            77318
```

Query plan and CPU attribution via the system tables — this is how you find the query that is burning the instance:

```console
$ gcloud spanner databases execute-sql orders --instance=spanner-orders-prod --sql="
SELECT
  text_fingerprint,
  SUBSTR(text, 0, 60) AS q,
  execution_count,
  ROUND(avg_latency_seconds * 1000, 2) AS avg_ms,
  ROUND(avg_cpu_seconds * 1000, 2)     AS avg_cpu_ms,
  avg_rows_scanned
FROM SPANNER_SYS.QUERY_STATS_TOP_MINUTE
ORDER BY avg_cpu_seconds * execution_count DESC
LIMIT 5"
text_fingerprint      q                                                             execution_count  avg_ms  avg_cpu_ms  avg_rows_scanned
-2298471039918842731  SELECT * FROM Orders WHERE Status = @status ORDER BY Pla       14028            186.44  91.03       210488.0
 7710338204411890013  SELECT o.OrderId, l.Sku FROM Orders o JOIN OrderLines l         9944             12.07   4.61          38.0
-4419028837710294411  SELECT TotalMinor FROM Orders WHERE CustomerId = @cid AN        812337            3.11   0.94           1.0
 1120038847710028841  INSERT INTO Orders (CustomerId, OrderId, Status, Currenc        409112            8.82   2.10           0.0
 6620194471029388441  SELECT COUNT(*) FROM OrderLines WHERE Sku = @sku                 1204          944.51  512.77      8804122.0
```

Two findings: the top query scans 210k rows per execution (missing/unused index), and the `OrderLines WHERE Sku` scan at 8.8M rows/execution is a full-table scan on a non-key column — that belongs in BigQuery or needs a secondary index.

Lock contention, the other Spanner classic:

```console
$ gcloud spanner databases execute-sql orders --instance=spanner-orders-prod --sql="
SELECT
  row_range_start_key,
  lock_wait_seconds,
  sample_lock_requests
FROM SPANNER_SYS.LOCK_STATS_TOP_MINUTE
ORDER BY lock_wait_seconds DESC
LIMIT 3"
row_range_start_key                          lock_wait_seconds  sample_lock_requests
Orders(8f2c1d0a-4b7e-4c11-9c2f-1a3b5d7e9f00) 41.882             [{'lock_mode': 'WriterShared', 'column': 'Orders.Status'}]
OrdersByStatusShard('PENDING')               28.114             [{'lock_mode': 'WriterShared', 'column': 'Orders.Status'}]
Orders(0000-inventory-counter)                9.220             [{'lock_mode': 'WriterShared', 'column': 'Orders.TotalMinor'}]
```

The second row is the diagnostic worth internalizing: `OrdersByStatusShard('PENDING')` shows every new order writing to the same index-key prefix. The index is a hotspot. The fix is a sharded index key (`MOD(FARM_FINGERPRINT(OrderId), 32)` as the leading column) or an index on a naturally distributed column.

### 5.4 Bigtable: schema, write, scan, and hot-tablet detection

```console
$ gcloud bigtable instances describe bt-telemetry-prod \
    --format='table(displayName, state)'
DISPLAY_NAME       STATE
bt-telemetry-prod  READY

$ gcloud bigtable clusters list --instances=bt-telemetry-prod \
    --format='table(name.basename(), zone.basename(), defaultStorageType, state)'
NAME                ZONE             DEFAULT_STORAGE_TYPE  STATE
bt-telemetry-ew1-a  europe-west1-b   SSD                   READY
bt-telemetry-ew4-a  europe-west4-a   SSD                   READY

$ cbt -instance=bt-telemetry-prod -app-profile=batch-etl \
    set device_events 't03#dev-8817#9223370552000000000' \
    metrics:temp_c=21.4 metrics:humidity=48 meta:fw=3.2.1

$ cbt -instance=bt-telemetry-prod -app-profile=batch-etl \
    read device_events prefix='t03#dev-8817#' count=2
----------------------------------------
t03#dev-8817#9223370552000000000
  meta:fw                                  @ 2026/09/06-09:44:12.310000
    "3.2.1"
  metrics:humidity                         @ 2026/09/06-09:44:12.310000
    "48"
  metrics:temp_c                           @ 2026/09/06-09:44:12.310000
    "21.4"
----------------------------------------
t03#dev-8817#9223370551940000000
  metrics:humidity                         @ 2026/09/06-09:43:12.104000
    "47"
  metrics:temp_c                           @ 2026/09/06-09:43:12.104000
    "21.3"
```

The reverse timestamp means the newest row sorts first, so `prefix + count=2` is a bounded prefix scan — not a range scan plus a sort.

Hot tablet detection, the single most valuable Bigtable diagnostic:

```console
$ gcloud bigtable hot-tablets list --cluster=bt-telemetry-ew1-a \
    --start-time=2026-09-06T08:00:00Z --end-time=2026-09-06T09:00:00Z \
    --format='table(tableName.basename(), startKey, endKey, nodeCpuUsagePercent)'
TABLE_NAME     START_KEY   END_KEY     NODE_CPU_USAGE_PERCENT
device_events  t01#        t01#dev-2   0.61
device_events  t07#dev-9   t08#        0.07
```

A tablet consuming 61% of a node's CPU is a hotspot: tenant `t01` is dominating. Remedy is a finer key prefix or a dedicated table/instance for that tenant.

Per-node CPU — average hides the problem, so read the max:

```console
$ gcloud monitoring time-series list \
    --filter='metric.type="bigtable.googleapis.com/cluster/cpu_load_hottest_node"
              AND resource.labels.instance="bt-telemetry-prod"' \
    --interval-end-time=2026-09-06T09:00:00Z \
    --interval-start-time=2026-09-06T08:00:00Z \
    --format='value(points[0].value.doubleValue)'
0.87
```

0.87 on the hottest node with a 0.60 autoscaling target means autoscaling added nodes but the *distribution* is wrong — adding nodes cannot fix a single hot tablet, because a tablet is owned by exactly one node. This is the lesson: **Bigtable capacity problems are usually key-design problems.**

### 5.5 BigQuery: cost control, partition pruning, and slot forensics

Dry-run before you spend — always, in CI:

```console
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country_code, SUM(total_minor)/100 AS revenue
   FROM `acme-retail-prod.retail_analytics.fact_orders`
   WHERE placed_at >= TIMESTAMP("2026-09-01")
   GROUP BY country_code'
Query successfully validated. Assuming the tables are not modified,
running this query will process 4823119872 bytes of data.
```

4.82 GB. Now the same query without the partition filter:

```console
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country_code, SUM(total_minor)/100 AS revenue
   FROM `acme-retail-prod.retail_analytics.fact_orders`
   GROUP BY country_code'
BigQuery error in query operation: Cannot query over table
'acme-retail-prod.retail_analytics.fact_orders' without a filter over
column(s) 'placed_at' that can be used for partition elimination.
```

`require_partition_filter` did its job: a 1.4 TB scan was refused, not billed. This one table setting is the highest-leverage cost control in BigQuery.

```console
$ bq query --use_legacy_sql=false --maximum_bytes_billed=10000000000 \
  'SELECT country_code, channel, COUNT(*) AS orders, SUM(total_minor)/100 AS revenue
   FROM `acme-retail-prod.retail_analytics.fact_orders`
   WHERE placed_at >= TIMESTAMP("2026-09-01")
     AND country_code IN ("ES","FR")
   GROUP BY country_code, channel
   ORDER BY revenue DESC'
+--------------+--------+--------+-------------+
| country_code | channel| orders |   revenue   |
+--------------+--------+--------+-------------+
| ES           | web    | 418223 | 8842119.47  |
| FR           | web    | 301774 | 6120884.10  |
| ES           | mobile | 244019 | 4011772.85  |
| FR           | mobile | 188441 | 3097441.22  |
| ES           | store  |  91002 | 2884019.03  |
| FR           | store  |  70118 | 2011884.71  |
+--------------+--------+--------+-------------+
```

Slot contention and the top spenders, from `INFORMATION_SCHEMA`:

```console
$ bq query --use_legacy_sql=false --nouse_cache '
SELECT
  user_email,
  job_id,
  ROUND(total_bytes_processed / POW(1024,4), 3) AS tib_processed,
  ROUND(total_slot_ms / 1000 / 3600, 2)         AS slot_hours,
  TIMESTAMP_DIFF(end_time, start_time, SECOND)  AS wall_s,
  reservation_id
FROM `region-eu`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND job_type = "QUERY" AND state = "DONE"
ORDER BY total_slot_ms DESC
LIMIT 5'
+---------------------------+------------------------------+---------------+------------+--------+---------------------------------------+
|        user_email         |            job_id            | tib_processed | slot_hours | wall_s |            reservation_id             |
+---------------------------+------------------------------+---------------+------------+--------+---------------------------------------+
| dbt-runner@acme...         | bqjob_r4f1a09c2d8b1e7c_1     |        18.442 |     412.77 |   1840 | acme-retail-prod:EU.res-analytics-eu  |
| looker-sa@acme...          | bqjob_r7712bb0a4c19f001_1    |         2.108 |      61.04 |    212 | acme-retail-prod:EU.res-analytics-eu  |
| analyst.jm@acme...         | bqjob_r91c0ff2a771b0e44_1    |         1.884 |      48.19 |    904 | acme-retail-prod:EU.res-analytics-eu  |
| dbt-runner@acme...         | bqjob_r0a18cc4471bb0e12_1    |         0.771 |      19.88 |    141 | acme-retail-prod:EU.res-analytics-eu  |
| ml-pipeline@acme...        | bqjob_r6b120e8871cc0f31_1    |         0.402 |      11.02 |     94  | acme-retail-prod:EU.res-analytics-eu  |
+---------------------------+------------------------------+---------------+------------+--------+---------------------------------------+
```

Queue-time analysis — is the reservation undersized, or is one job starving the rest?

```console
$ bq query --use_legacy_sql=false '
SELECT
  TIMESTAMP_TRUNC(period_start, MINUTE) AS minute,
  SUM(period_slot_ms) / 1000 / 60       AS avg_slots_used,
  COUNTIF(job_id IS NOT NULL)           AS concurrent_jobs
FROM `region-eu`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
WHERE period_start > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
GROUP BY minute
ORDER BY avg_slots_used DESC
LIMIT 5'
+---------------------+----------------+-----------------+
|       minute        | avg_slots_used | concurrent_jobs |
+---------------------+----------------+-----------------+
| 2026-09-06 08:12:00 |         998.44 |              37 |
| 2026-09-06 08:13:00 |         999.81 |              41 |
| 2026-09-06 08:14:00 |         999.92 |              44 |
| 2026-09-06 08:11:00 |         961.07 |              29 |
| 2026-09-06 07:41:00 |         722.19 |              14 |
+---------------------+----------------+-----------------+
```

Pinned at the 1000-slot autoscale ceiling for four consecutive minutes with 44 concurrent jobs: the reservation is saturated. The correct response is *not* automatically "raise `max_slots`" — it is to move the `dbt-runner` batch job to its own reservation so interactive BI is never queued behind a 412-slot-hour transformation. Workload isolation before capacity.

### 5.6 Cloud Storage: lifecycle, classes, and cost verification

```console
$ gcloud storage buckets describe gs://acme-retail-prod-event-archive-prod \
    --format='yaml(name, location, locationType, storageClass, autoclass,
                   uniform_bucket_level_access, public_access_prevention)'
autoclass:
  enabled: true
  terminalStorageClass: ARCHIVE
  terminalStorageClassUpdateTime: '2026-03-11T10:02:41.118000+00:00'
  toggleTime: '2026-03-11T10:02:41.118000+00:00'
location: EUROPE-WEST1
locationType: region
name: acme-retail-prod-event-archive-prod
public_access_prevention: enforced
storageClass: STANDARD
uniform_bucket_level_access: true
```

Class distribution — verify the policy is actually working rather than trusting that it is:

```console
$ gcloud storage ls -L --recursive gs://acme-retail-prod-event-archive-prod/2025/ \
    | awk '/Storage class:/ {print $3}' | sort | uniq -c
   1204 ARCHIVE
    881 COLDLINE
     92 NEARLINE
      7 STANDARD
```

Autoclass has demoted the 2025 data as intended. Compare against a bucket without a policy:

```console
$ gcloud storage du --summarize --readable-sizes gs://acme-retail-prod-media-prod
14.72TiB     gs://acme-retail-prod-media-prod

$ gcloud storage buckets describe gs://acme-retail-prod-media-prod \
    --format='value(rpo)'
ASYNC_TURBO
```

Confirm the compliance vault's lock is real — this is an auditable control:

```console
$ gcloud storage buckets describe gs://acme-retail-prod-compliance-vault \
    --format='yaml(retentionPolicy)'
retentionPolicy:
  effectiveTime: '2026-02-02T08:11:22.918000+00:00'
  isLocked: true
  retentionPeriod: '220752000'

$ gcloud storage rm gs://acme-retail-prod-compliance-vault/2026/02/ledger-0001.json
Removing objects:
ERROR: [gs://acme-retail-prod-compliance-vault/2026/02/ledger-0001.json]
403 Object 'ledger-0001.json' is subject to bucket's retention policy or
object retention settings and cannot be deleted or overwritten until
2033-02-02T08:11:22.918Z
```

The 403 is the control working. A locked retention policy cannot be shortened or removed by anyone, including an org admin — which is precisely why it satisfies WORM requirements and why you must be certain about the period before locking.

### 5.7 AlloyDB and Memorystore

```console
$ gcloud alloydb clusters describe alloydb-catalog-prod --region=europe-west1 \
    --format='table(name.basename(), state, databaseVersion,
                    continuousBackupConfig.recoveryWindowDays)'
NAME                  STATE  DATABASE_VERSION  RECOVERY_WINDOW_DAYS
alloydb-catalog-prod  READY  POSTGRES_16       14

$ gcloud alloydb instances list --cluster=alloydb-catalog-prod --region=europe-west1 \
    --format='table(name.basename(), instanceType, state, ipAddress,
                    machineConfig.cpuCount, readPoolConfig.nodeCount)'
NAME                  INSTANCE_TYPE  STATE  IP_ADDRESS   CPU_COUNT  NODE_COUNT
primary               PRIMARY        READY  10.128.8.2   16         -
read-pool-analytics   READ_POOL      READY  10.128.8.9   8          3
```

Verify the columnar engine is populated (otherwise you are paying for RAM and still doing row scans):

```console
$ psql "host=10.128.8.2 user=postgres dbname=catalog sslmode=require" -c "
SELECT relation_name, columnar_unit_count,
       pg_size_pretty(size_in_bytes) AS size, status
FROM g_columnar_relations
ORDER BY size_in_bytes DESC LIMIT 5;"
 relation_name   | columnar_unit_count |  size   | status
-----------------+---------------------+---------+--------
 order_items     |                 184 | 2841 MB | Usable
 products        |                  31 |  412 MB | Usable
 price_history      |               22 |  288 MB | Usable
 inventory_snapshots|                9 |   94 MB | Usable
 categories      |                   1 |  1088 kB| Usable
(5 rows)
```

```console
$ gcloud redis instances describe redis-sessions-prod --region=europe-west1 \
    --format='table(name.basename(), tier, memorySizeGb, state, host, port,
                    replicaCount, readEndpoint)'
NAME                 TIER         MEMORY_SIZE_GB  STATE  HOST        PORT  REPLICA_COUNT  READ_ENDPOINT
redis-sessions-prod  STANDARD_HA  26              READY  10.128.4.19 6379  2              10.128.4.22

$ redis-cli -h 10.128.4.19 --tls --insecure -a "$REDIS_AUTH" INFO stats \
    | grep -E 'keyspace_hits|keyspace_misses|evicted_keys|expired_keys'
keyspace_hits:1884219044
keyspace_misses:41028811
evicted_keys:0
expired_keys:88104221
```

Hit ratio = 1,884,219,044 / (1,884,219,044 + 41,028,811) = **97.87%**, with zero evictions. The cache is correctly sized: keys leave by TTL expiry, not by memory pressure. A non-zero `evicted_keys` with a falling hit ratio is the signal to grow the instance or shorten TTLs — and if you ever see `OOM command not allowed when used memory > 'maxmemory'` in application logs, someone set `noeviction` on a cache.

### 5.8 Datastream: CDC from the OLTP database into BigQuery

```console
$ gcloud datastream streams describe catalog-to-bq --location=europe-west1 \
    --format='yaml(displayName, state, sourceConfig.postgresqlSourceConfig.publication,
                   destinationConfig.bigqueryDestinationConfig.dataFreshness)'
destinationConfig:
  bigqueryDestinationConfig:
    dataFreshness: 900s
displayName: catalog-to-bq
sourceConfig:
  postgresqlSourceConfig:
    publication: datastream_pub
state: RUNNING

$ gcloud datastream streams list --location=europe-west1 \
    --format='table(name.basename(), state, updateTime)'
NAME            STATE     UPDATE_TIME
catalog-to-bq   RUNNING   2026-09-06T09:02:11.884Z
orders-to-bq    RUNNING   2026-09-06T09:02:44.109Z
```

Replication freshness must be verified against the *data*, not the stream state:

```console
$ bq query --use_legacy_sql=false '
SELECT
  MAX(datastream_metadata.source_timestamp) AS last_source_event,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(),
                 MAX(datastream_metadata.source_timestamp), SECOND) AS lag_seconds
FROM `acme-retail-prod.raw_catalog.public_products`'
+---------------------------+-------------+
|     last_source_event     | lag_seconds |
+---------------------------+-------------+
| 2026-09-06 09:47:12 UTC   |         143 |
+---------------------------+-------------+
```

143 s against a 900 s freshness target: healthy. A `RUNNING` stream with growing `lag_seconds` usually means replication-slot backpressure on the source — check `pg_replication_slots.confirmed_flush_lsn` before blaming Datastream.

---

## 6. Verification and failure diagnosis

### 6.1 Verification ladder — run these before declaring a data platform ready

```console
# 1. No managed database is reachable from the internet.
$ gcloud sql instances list --format='value(name, ipAddresses.filter("type=PRIMARY"))'
sql-catalog-prod-a1
sql-catalog-prod-a1-replica-ew4
# (empty second column == no public IP; a value here is a finding)

# 2. Every bucket denies public access and enforces uniform IAM.
$ gcloud storage buckets list \
    --format='table(name, iamConfiguration.publicAccessPrevention,
                    iamConfiguration.uniformBucketLevelAccess.enabled)'
NAME                                  PUBLIC_ACCESS_PREVENTION  ENABLED
acme-retail-prod-compliance-vault     enforced                  True
acme-retail-prod-event-archive-prod   enforced                  True
acme-retail-prod-media-prod           enforced                  True

# 3. No service-account keys exist (Workload Identity only).
$ for sa in $(gcloud iam service-accounts list --format='value(email)'); do
    n=$(gcloud iam service-accounts keys list --iam-account="$sa" \
          --managed-by=user --format='value(name)' | wc -l)
    [ "$n" -gt 0 ] && echo "FINDING: $sa has $n user-managed key(s)"
  done
# (no output == pass)

# 4. Deletion protection is on for every stateful resource.
$ gcloud sql instances describe sql-catalog-prod-a1 --format='value(settings.deletionProtectionEnabled)'
True
$ gcloud spanner databases describe orders --instance=spanner-orders-prod --format='value(enableDropProtection)'
True

# 5. Backups actually completed recently — not merely "configured".
$ gcloud sql backups list --instance=sql-catalog-prod-a1 --limit=3 \
    --format='table(id, windowStartTime, type, status)'
ID            WINDOW_START_TIME         TYPE       STATUS
1757144400000 2026-09-06T02:00:00.000Z  AUTOMATED  SUCCESSFUL
1757058000000 2026-09-05T02:00:00.000Z  AUTOMATED  SUCCESSFUL
1756971600000 2026-09-04T02:00:00.000Z  AUTOMATED  SUCCESSFUL

$ gcloud spanner backups list --instance=spanner-orders-prod --limit=2 \
    --format='table(name.basename(), state, sizeBytes, expireTime)'
NAME                    STATE  SIZE_BYTES     EXPIRE_TIME
daily-full-20260906010  READY  418223994112   2026-10-11T01:00:00Z
daily-full-20260905010  READY  411882004480   2026-10-10T01:00:00Z

# 6. PITR windows are what the RPO promises.
$ gcloud spanner databases describe orders --instance=spanner-orders-prod \
    --format='value(versionRetentionPeriod, earliestVersionTime)'
7d  2026-08-30T09:52:11.418Z
```

### 6.2 A restore is not proven until it is performed

Backups that have never been restored are a belief, not a control. Rehearse quarterly:

```console
$ gcloud sql instances clone sql-catalog-prod-a1 sql-catalog-drill-20260906 \
    --point-in-time='2026-09-06T06:00:00.000Z'
Cloning Cloud SQL instance...done.
Created [https://sqladmin.googleapis.com/sql/v1beta4/projects/acme-retail-prod/instances/sql-catalog-drill-20260906].

$ gcloud sql instances describe sql-catalog-drill-20260906 --format='value(state)'
RUNNABLE

$ psql "host=10.128.0.31 user=drill dbname=catalog sslmode=require" -c \
    "SELECT COUNT(*) AS rows, MAX(updated_at) AS newest FROM products;"
  rows   |             newest
---------+-------------------------------
 4881204 | 2026-09-06 05:59:58.114882+00

$ gcloud sql instances delete sql-catalog-drill-20260906 --quiet
Deleted [https://sqladmin.googleapis.com/sql/v1beta4/projects/acme-retail-prod/instances/sql-catalog-drill-20260906].
```

`newest` sits just under the requested PITR timestamp: the restore landed at the intended point in time. Record the **wall-clock duration** of the clone — that, not the backup's existence, is your RTO.

### 6.3 Failure catalogue — symptom → probe → root cause → remediation

| Symptom | Probe | Likely root cause | Remediation |
|---|---|---|---|
| App: `could not connect to server: Connection timed out` to Cloud SQL private IP | `gcloud compute networks peerings list --network=vpc-data-prod`; check route export | PSA peering missing, or custom routes not exported to the peered/on-prem network | Create `google_service_networking_connection`; set `export_custom_routes = true` |
| Proxy sidecar: `failed to get instance: googleapi: Error 403: Cloud SQL Admin API has not been used` | `gcloud services list --enabled \| grep sqladmin` | `sqladmin.googleapis.com` disabled | Enable the API; note the proxy needs the *Admin* API even for data-plane connections |
| Proxy: `Refusing to connect; missing IAM permission cloudsql.instances.connect` | `gcloud projects get-iam-policy` for the Google SA | KSA→GSA Workload Identity binding or `roles/cloudsql.client` missing | Add `roles/iam.workloadIdentityUser` on the GSA for `PROJECT.svc.id.goog[ns/ksa]`, plus `roles/cloudsql.client` |
| `FATAL: remaining connection slots are reserved` | `SELECT count(*) FROM pg_stat_activity;` vs `max_connections` | HPA `maxReplicas` × per-pod pool exceeds the instance budget | Reduce pool, add a pooler (PgBouncer), or raise `max_connections` with matching RAM |
| Cloud SQL read replica lag growing without bound | `SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));` | Long transaction on primary, replica undersized, or a single-threaded apply bottleneck | Size the replica ≥ primary; kill long transactions; for MySQL enable parallel replication |
| Spanner p99 latency doubles with flat QPS | `SPANNER_SYS.LOCK_STATS_TOP_MINUTE`, Key Visualizer | Hotspot on a monotonic key or index prefix | Bit-reverse/hash the leading key column; shard the index; pre-split |
| Spanner `ABORTED: Transaction was aborted due to ... lock conflict` | `LOCK_STATS_TOP_MINUTE` sample requests | Read-write transaction holding locks too long; read-modify-write on a contended row | Shorten transactions; move reads outside the RW txn using a stale read; use blind writes where safe |
| Spanner `RESOURCE_EXHAUSTED: The transaction contains too many mutations` | count mutations in the batch | >80,000 mutations per commit | Chunk the batch (and remember each secondary index multiplies mutations) |
| Bigtable p99 spikes while average CPU is low | `gcloud bigtable hot-tablets list`; `cpu_load_hottest_node` | Hot tablet — one node owns the busy key range | Redesign the row key; pre-split; salt the prefix. Adding nodes will *not* help |
| Bigtable: reads miss data just written | check the app profile in use | Multi-cluster routing gives no read-your-writes across clusters | Use single-cluster routing for the read-after-write path, or read from the cluster written to |
| Firestore: `FAILED_PRECONDITION: The query requires an index` | the error message contains a create-index URL | Missing composite index for a multi-field query | Add the composite index (Terraform `google_firestore_index`), not a code workaround |
| Firestore write throughput plateaus, latency climbs during a launch | check ops/sec ramp | 500/50/5 rule violated; backend had no time to split ranges | Ramp: 500 ops/sec, +50% every 5 min. Pre-warm before the campaign |
| BigQuery `Quota exceeded: Your project exceeded quota for free query bytes scanned` or a surprise bill | `INFORMATION_SCHEMA.JOBS_BY_PROJECT` ordered by `total_bytes_billed` | Unpartitioned/unfiltered scans; `SELECT *` in a BI tool | `require_partition_filter`, clustering, `--maximum_bytes_billed`, custom quotas, move to Editions reservations |
| BigQuery interactive dashboards suddenly slow | `JOBS_TIMELINE_BY_PROJECT` slot usage per minute | Reservation saturated; a batch job monopolizing slots | Separate reservations per workload; assign batch jobs to their own; enable autoscaling ceiling |
| BigQuery `Not found: Dataset ... was not found in location EU` | `bq show --format=prettyjson dataset` | Job location ≠ dataset location; datasets are location-bound and cannot be joined across regions | Run the job in the dataset's location; replicate the dataset or use cross-region dataset replication |
| Memorystore: `OOM command not allowed when used memory > 'maxmemory'` | `redis-cli INFO memory`; `CONFIG GET maxmemory-policy` | `noeviction` on a cache, or undersized instance | Set `allkeys-lru`; increase `memory_size_gb`; audit TTLs |
| Memorystore hit ratio collapses after a maintenance event | `INFO stats`, instance events | Failover/restart cleared the cache (or replica promoted cold) | Warm the cache on start; ensure the app degrades to the database gracefully instead of stampeding it |
| GCS: unexpected `Early delete` and `Class B operation` charges | Billing export grouped by SKU | Objects transitioned or deleted before the class minimum duration | Use **Autoclass** (no early-delete/retrieval fees) or align lifecycle ages with 30/90/365-day minimums |
| GCS `403 ... retention policy` on a legitimate delete | `buckets describe --format='yaml(retentionPolicy)'` | Locked retention policy — irreversible by design | Nothing to do until expiry; this is the control working. Plan the period before locking |
| Object deleted by mistake, versioning off | `gcloud storage ls --soft-deleted gs://bucket/prefix` | soft delete window still open | `gcloud storage restore`; then enable versioning |
| AlloyDB analytical query still row-scanning | `SELECT * FROM g_columnar_relations;` and `EXPLAIN` | Columnar engine not populated for that relation, or memory too small | Add the relation to the columnar store; raise `google_columnar_engine.memory_size_in_mb` |
| Datastream stream `RUNNING` but data stale | `pg_replication_slots`, BigQuery `source_timestamp` lag | Replication slot backpressure, or DDL change unsupported by the stream | Resolve source-side slot lag; re-backfill the affected object |

### 6.4 SLO instrumentation worth having on day one

```console
$ gcloud alpha monitoring policies list \
    --format='table(displayName, enabled, conditions[0].displayName)'
DISPLAY_NAME                          ENABLED  CONDITION
Cloud SQL replica lag > 60s           True     cloudsql.googleapis.com/database/replication/replica_lag
Cloud SQL connections > 80% of max    True     cloudsql.googleapis.com/database/postgresql/num_backends
Spanner high-priority CPU > 65%       True     spanner.googleapis.com/instance/cpu/utilization_by_priority
Spanner storage > 85% of limit        True     spanner.googleapis.com/instance/storage/utilization
Bigtable hottest node CPU > 80%       True     bigtable.googleapis.com/cluster/cpu_load_hottest_node
Bigtable replication latency > 5m     True     bigtable.googleapis.com/replication/latency
BigQuery reservation slots pinned     True     bigquery.googleapis.com/slots/allocated_for_reservation
Memorystore evicted keys > 0          True     redis.googleapis.com/stats/evicted_keys
Memorystore memory usage ratio > 0.8  True     redis.googleapis.com/stats/memory/usage_ratio
GCS bucket total bytes anomaly        True     storage.googleapis.com/storage/total_bytes
```

Note which metrics are *distribution* metrics rather than averages: `cpu_load_hottest_node` for Bigtable and `cpu/utilization_by_priority` for Spanner exist precisely because the mean is misleading in a sharded system.

---

## 7. Cost model and the economics behind the choice

Selection is only half the objective; a leader must be able to defend the unit economics.

| Product | Primary cost drivers | Dominant optimization lever | Common waste |
|---|---|---|---|
| Cloud Storage | GB-month by class, network egress, operations (Class A/B), retrieval | Lifecycle/Autoclass at bucket creation; keep compute in the same region as data | Standard class forever; cross-region reads; per-object churn generating Class A ops |
| Cloud SQL | vCPU+RAM hours, disk GB, HA doubles compute, backup storage, egress | Right-size, committed use discounts, stop non-prod out of hours | HA on non-production; oversized disks (disk cannot shrink) |
| AlloyDB | vCPU+RAM per instance (primary + each read-pool node), storage, backups | Scale the read pool to demand; columnar engine to avoid a separate warehouse | Read pool sized for peak 24/7 |
| Spanner | Processing units/nodes, storage GB, network for multi-region, backups | Autoscaler with PU granularity; stale reads to avoid leader traffic | Provisioning nodes for a workload that Cloud SQL could serve |
| Bigtable | Node-hours per cluster (replication multiplies), storage GB (SSD vs HDD) | Autoscaling with a correct CPU target; HDD for scan-heavy cold data | Replicated clusters sized identically for peak; SSD for archival |
| Firestore | Document reads/writes/deletes, storage, egress | Query shape — fewer, denormalized reads; bundle static data | N+1 read patterns from mobile clients |
| Memorystore | Provisioned GB-hours per node/replica | Size to working set, not to total dataset | Treating it as the system of record and over-provisioning for durability |
| BigQuery | On-demand bytes scanned **or** slot-hours; storage (logical vs physical); streaming | Partition + cluster + `require_partition_filter`; Editions with autoscale; physical storage billing; materialized views | `SELECT *`; unpartitioned tables; scheduled queries nobody reads |

**The structural insight:** BigQuery's separation of storage and compute means idle analytical data is nearly free, whereas an idle Cloud SQL/AlloyDB/Spanner/Bigtable instance bills continuously for provisioned capacity. That asymmetry — not query syntax — is the real reason cold historical data belongs in BigQuery or Cloud Storage and not in the operational database.

---

## 8. Exam-oriented mapping: business use case → product

| Business use case (as the exam phrases it) | Answer | Discriminating phrase |
|---|---|---|
| Store user-uploaded photos and videos, serve globally | Cloud Storage | "unstructured", "objects", "media" |
| 7-year immutable regulatory archive, cheapest possible | Cloud Storage Archive + locked retention policy | "compliance", "rarely accessed", "immutable" |
| Lift-and-shift an on-prem MySQL e-commerce database | Cloud SQL | "existing", "minimal changes", "MySQL/PostgreSQL/SQL Server" |
| Migrate Oracle to an open-source engine with less downtime | Database Migration Service → AlloyDB / Cloud SQL for PostgreSQL | "heterogeneous", "Oracle", "reduce licensing" |
| PostgreSQL app needing far higher throughput and 99.99%, plus reporting on live data | AlloyDB | "PostgreSQL-compatible", "HTAP", "4× faster transactions" |
| Global banking ledger, strongly consistent across continents, five nines | Spanner | "global", "strong consistency", "relational", "horizontal scale", "99.999%" |
| Inventory across 40 countries with a single consistent view and SQL | Spanner | "single global view", "consistent", "SQL" |
| IoT platform ingesting millions of sensor readings per second | Bigtable | "time series", "high write throughput", "TB–PB", "low latency", "key lookups" |
| Ad-tech user-profile store for real-time personalization | Bigtable | "single-digit ms", "huge", "no joins" |
| Mobile app with realtime sync and offline support | Firestore (Native mode) | "mobile/web SDK", "realtime", "offline" |
| Serverless backend document store for a web app, server-side only | Firestore (Datastore mode) | "document", "server-side", "App Engine legacy" |
| Sub-millisecond session store / leaderboard / cache | Memorystore | "cache", "in-memory", "sub-millisecond" |
| Petabyte-scale data warehouse for BI and ad-hoc SQL analytics | BigQuery | "analytics", "warehouse", "SQL over huge datasets", "serverless" |
| Analyze data already in Amazon S3 without moving it | BigQuery Omni / BigLake | "in place", "multi-cloud", "avoid egress" |
| Share a curated dataset with partners without copying it | Analytics Hub | "share", "exchange", "no duplication" |
| Real-time clickstream pipeline into a dashboard | Pub/Sub → Dataflow → BigQuery → Looker | "streaming", "real-time", "ingest and transform" |
| Existing Spark/Hadoop jobs moved to the cloud as-is | Dataproc | "Spark", "Hadoop", "existing jobs" |
| ETL built by analysts without writing code | Cloud Data Fusion | "visual", "no-code", "graphical pipelines" |
| Catalog, classify, and govern data across the estate | Dataplex (with Data Catalog) | "governance", "metadata", "lineage", "discover" |
| Move 500 TB to the cloud over a poor WAN link | Transfer Appliance | "limited bandwidth", "petabyte-scale offline" |
| Continuously sync an on-prem bucket to GCS | Storage Transfer Service | "recurring", "incremental", "from another cloud/on-prem" |
| Shared NFS filesystem for a legacy application | Filestore | "file share", "NFS", "POSIX" |

### 8.1 Distractor pairs the exam relies on

| If you see… | It is NOT… | Because |
|---|---|---|
| "globally consistent relational" | Cloud SQL | Cloud SQL has one primary; cross-region replicas are asynchronous |
| "minimal application changes, existing MySQL" | Spanner | Spanner is not MySQL-compatible and would require refactoring |
| "petabyte analytics with SQL" | Bigtable | Bigtable has no SQL joins/ad-hoc analytics engine |
| "single-digit-ms point lookups at millions of QPS" | BigQuery | BigQuery is a scan engine; per-row lookup latency is far higher |
| "realtime mobile sync, offline" | Bigtable / Cloud SQL | Only Firestore ships client SDKs with listeners and offline persistence |
| "durable system of record" | Memorystore | Memorystore is a cache; durability is not its contract |
| "unstructured media files" | any database | Blobs belong in Cloud Storage; store the *pointer* in the database |
| "11 nines durability means it's always reachable" | availability | Durability ≠ availability; availability is 99.9–99.95% per bucket type |

---

## 9. Summary judgements for an architect

1. **Choose by consistency scope and access pattern first, by familiarity second.** Familiarity (Cloud SQL) is a legitimate criterion, but only after you have confirmed the workload fits inside one primary's write ceiling and one region's blast radius.
2. **The ceiling you hit is usually not the one you provisioned for.** Cloud SQL runs out of *write* headroom, Spanner and Bigtable run out of *key distribution*, BigQuery runs out of *slots*, Memorystore runs out of *memory policy*. Each has a distinct diagnostic (`pg_stat_activity`, `LOCK_STATS`/Key Visualizer, `JOBS_TIMELINE`, `INFO memory`). Instrument all four before launch.
3. **Never point BI at the OLTP primary.** Use AlloyDB read pools with the columnar engine for operational reporting, and BigQuery via Datastream CDC for anything historical.
4. **Set the irreversible decisions correctly the first time.** Bucket location type and Autoclass, Firestore mode, BigQuery dataset location, Spanner instance config, a locked retention policy — all are creation-time and effectively immutable. Everything else is tunable later.
5. **A backup is a hypothesis until restored.** Rehearse PITR on a schedule and record the wall-clock time; that number is your RTO, not the one in the runbook.
6. **Identity, not network position, is the access-control boundary.** Workload Identity + IAM database authentication + the Cloud SQL connectors eliminate static credentials entirely; a JSON key in a Secret is a finding, not a design.

---

## Referencias

**Exam guide**
- Cloud Digital Leader exam guide (official PDF): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification overview: https://cloud.google.com/learn/certification/cloud-digital-leader

**Product selection and architecture guidance**
- Google Cloud databases overview: https://cloud.google.com/products/databases
- Choose a database service (Architecture Framework): https://cloud.google.com/architecture/framework/system-design/databases
- Google Cloud Architecture Framework: https://cloud.google.com/architecture/framework
- Data lifecycle on Google Cloud: https://cloud.google.com/architecture/data-lifecycle-cloud-platform
- Design storage for data analytics: https://cloud.google.com/architecture/framework/system-design/storage

**Cloud Storage**
- Documentation: https://cloud.google.com/storage/docs
- Storage classes: https://cloud.google.com/storage/docs/storage-classes
- Autoclass: https://cloud.google.com/storage/docs/autoclass
- Object Lifecycle Management: https://cloud.google.com/storage/docs/lifecycle
- Bucket locations and dual-region/turbo replication: https://cloud.google.com/storage/docs/locations
- Retention policies and Bucket Lock: https://cloud.google.com/storage/docs/bucket-lock
- Soft delete: https://cloud.google.com/storage/docs/soft-delete
- Consistency model: https://cloud.google.com/storage/docs/consistency
- Cloud Storage SLA: https://cloud.google.com/storage/sla

**Cloud SQL**
- Documentation: https://cloud.google.com/sql/docs
- High availability: https://cloud.google.com/sql/docs/postgres/high-availability
- Cloud SQL editions (Enterprise / Enterprise Plus): https://cloud.google.com/sql/docs/editions-intro
- Point-in-time recovery: https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr
- Cloud SQL Auth Proxy: https://cloud.google.com/sql/docs/postgres/connect-auth-proxy
- Connect from GKE: https://cloud.google.com/sql/docs/postgres/connect-kubernetes-engine
- IAM database authentication: https://cloud.google.com/sql/docs/postgres/authentication
- Cloud SQL SLA: https://cloud.google.com/sql/sla

**AlloyDB for PostgreSQL**
- Documentation: https://cloud.google.com/alloydb/docs
- Architecture and storage layer: https://cloud.google.com/alloydb/docs/overview
- Columnar engine: https://cloud.google.com/alloydb/docs/columnar-engine/about
- Read pool instances: https://cloud.google.com/alloydb/docs/instance-read-pool-create
- AlloyDB SLA: https://cloud.google.com/alloydb/sla

**Spanner**
- Documentation: https://cloud.google.com/spanner/docs
- TrueTime and external consistency: https://cloud.google.com/spanner/docs/true-time-external-consistency
- Replication and instance configurations: https://cloud.google.com/spanner/docs/replication
- Schema design best practices: https://cloud.google.com/spanner/docs/schema-design
- Avoid hotspots / choose a primary key: https://cloud.google.com/spanner/docs/schema-design#primary-key-prevent-hotspots
- Key Visualizer: https://cloud.google.com/spanner/docs/key-visualizer
- Read types (strong vs stale): https://cloud.google.com/spanner/docs/reads
- Quotas and limits: https://cloud.google.com/spanner/quotas
- Spanner SLA: https://cloud.google.com/spanner/sla

**Bigtable**
- Documentation: https://cloud.google.com/bigtable/docs
- Storage model / overview: https://cloud.google.com/bigtable/docs/overview
- Schema and row key design: https://cloud.google.com/bigtable/docs/schema-design
- Time-series schema design: https://cloud.google.com/bigtable/docs/schema-design-time-series
- Replication overview: https://cloud.google.com/bigtable/docs/replication-overview
- App profiles and routing: https://cloud.google.com/bigtable/docs/app-profiles
- Hot tablets: https://cloud.google.com/bigtable/docs/viewing-hot-tablets
- Autoscaling: https://cloud.google.com/bigtable/docs/autoscaling
- Bigtable SLA: https://cloud.google.com/bigtable/sla

**Firestore**
- Documentation: https://cloud.google.com/firestore/docs
- Choose Native mode or Datastore mode: https://cloud.google.com/firestore/docs/firestore-or-datastore
- Best practices (incl. the 500/50/5 rule): https://cloud.google.com/firestore/docs/best-practices
- Index types and composite indexes: https://cloud.google.com/firestore/docs/concepts/index-overview
- Firestore SLA: https://cloud.google.com/firestore/sla

**Memorystore**
- Documentation: https://cloud.google.com/memorystore/docs
- Memorystore for Redis Cluster: https://cloud.google.com/memorystore/docs/cluster
- Memory management best practices: https://cloud.google.com/memorystore/docs/redis/memory-management-best-practices
- Memorystore SLA: https://cloud.google.com/memorystore/sla

**BigQuery**
- Documentation: https://cloud.google.com/bigquery/docs
- BigQuery architecture / under the hood: https://cloud.google.com/bigquery/docs/introduction
- Partitioned tables: https://cloud.google.com/bigquery/docs/partitioned-tables
- Clustered tables: https://cloud.google.com/bigquery/docs/clustered-tables
- Editions, reservations and slots: https://cloud.google.com/bigquery/docs/reservations-intro
- Control costs: https://cloud.google.com/bigquery/docs/best-practices-costs
- Storage Write API: https://cloud.google.com/bigquery/docs/write-api
- INFORMATION_SCHEMA jobs views: https://cloud.google.com/bigquery/docs/information-schema-jobs
- Materialized views: https://cloud.google.com/bigquery/docs/materialized-views-intro
- BI Engine: https://cloud.google.com/bigquery/docs/bi-engine-intro
- BigLake: https://cloud.google.com/biglake/docs
- BigQuery Omni: https://cloud.google.com/bigquery/docs/omni-introduction
- Analytics Hub: https://cloud.google.com/bigquery/docs/analytics-hub-introduction
- BigQuery ML: https://cloud.google.com/bigquery/docs/bqml-introduction
- BigQuery SLA: https://cloud.google.com/bigquery/sla

**Data movement, integration and governance**
- Database Migration Service: https://cloud.google.com/database-migration/docs
- Datastream: https://cloud.google.com/datastream/docs
- Storage Transfer Service: https://cloud.google.com/storage-transfer/docs
- Transfer Appliance: https://cloud.google.com/transfer-appliance/docs
- Pub/Sub: https://cloud.google.com/pubsub/docs
- Dataflow: https://cloud.google.com/dataflow/docs
- Dataproc: https://cloud.google.com/dataproc/docs
- Cloud Data Fusion: https://cloud.google.com/data-fusion/docs
- Dataform: https://cloud.google.com/dataform/docs
- Cloud Composer: https://cloud.google.com/composer/docs
- Dataplex: https://cloud.google.com/dataplex/docs
- Backup and DR Service: https://cloud.google.com/backup-disaster-recovery/docs

**Networking, identity and file/block storage**
- Private Service Access: https://cloud.google.com/vpc/docs/private-services-access
- Workload Identity Federation for GKE: https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
- Filestore: https://cloud.google.com/filestore/docs
- Google Cloud NetApp Volumes: https://cloud.google.com/netapp/volumes/docs
- Parallelstore: https://cloud.google.com/parallelstore/docs
- Hyperdisk: https://cloud.google.com/compute/docs/disks/hyperdisk
- Cloud Storage FUSE: https://cloud.google.com/storage/docs/cloud-storage-fuse/overview

**Terraform provider reference**
- `hashicorp/google` provider: https://registry.terraform.io/providers/hashicorp/google/latest/docs