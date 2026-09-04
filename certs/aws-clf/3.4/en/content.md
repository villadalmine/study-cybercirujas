# Topic 3.4 — Identify AWS Database Services

**Certification:** AWS Certified Cloud Practitioner (CLF-C02, exam guide v1.0)
**Domain 3:** Cloud Technology and Services — **Task Statement 3.4**
**Exam weight:** 4.25 %
**Reader profile:** Platform Architect / SRE. This module goes past the "which service for which workload" flashcard and into the storage engines, quorum protocols, failure envelopes and operational telemetry that decide whether the choice survives contact with production.

---

## 1. Motivation: the architectural problem behind the task statement

### 1.1 Why "identify the database service" is actually a durability-and-blast-radius decision

Every stateless tier in a modern platform is disposable. You can drain an EC2 Auto Scaling group, roll a Kubernetes Deployment, or blow away a Lambda version, and the only cost is latency during the roll. The database is the one tier where a wrong decision is *irreversible on the timescale of an incident*: you cannot re-shard a 4 TB DynamoDB table's partition key at 03:00, and you cannot retrofit synchronous cross-AZ replication onto a single-AZ RDS instance whose AZ has just gone dark.

So the real engineering question is not "SQL or NoSQL". It is a four-axis constraint problem:

| Axis | Question you are actually answering | What gets destroyed if you get it wrong |
|---|---|---|
| **Consistency model** | Does a read-after-write have to be linearizable, or is bounded staleness acceptable? | Correctness — double-charged customers, phantom inventory |
| **Failure domain** | Which correlated failures (AZ, Region, control-plane, human) must the data survive? | Durability — unrecoverable data loss |
| **Access pattern shape** | Point lookups by key, range scans, joins across 12 tables, graph traversals, time-window aggregations? | Latency and cost — a 40 ms p50 becomes a 4 s p99 under scan |
| **Operational surface** | Who patches, backs up, fails over, and holds the pager? | MTTR and headcount |

The CLF-C02 exam guide phrases this as *"Identify AWS database services"* and lists the sub-objectives: relational vs. non-relational, managed vs. unmanaged (EC2-hosted), migration tooling, and the purpose-built database family. Underneath that phrasing is the shared-responsibility boundary — the single most exam-relevant and production-relevant idea in this topic.

### 1.2 The shared responsibility boundary, drawn precisely

```
┌────────────────────────────────────────────────────────────────────────────┐
│  Self-managed on EC2          RDS / Aurora            DynamoDB / Serverless│
├────────────────────────────────────────────────────────────────────────────┤
│  App-side query tuning    ●        ●                          ●            │  ← YOU
│  Schema / index design    ●        ●                          ●            │  ← YOU
│  Data classification      ●        ●                          ●            │  ← YOU
│  IAM / network policy     ●        ●                          ●            │  ← YOU
├────────────────────────────────────────────────────────────────────────────┤
│  DB engine tuning         ●        ◐ (parameter groups)       ○            │
│  Backups / PITR           ●        ○ (toggle + retention)     ○ (toggle)   │
│  Minor version patching   ●        ○ (maintenance window)     ○            │
│  Failover orchestration   ●        ○                          ○            │
│  Replica provisioning     ●        ◐ (you pick count/size)    ○            │
├────────────────────────────────────────────────────────────────────────────┤
│  OS patching              ●        ○                          ○            │  ← AWS
│  Hypervisor / firmware    ○        ○                          ○            │  ← AWS
│  Physical facility        ○        ○                          ○            │  ← AWS
└────────────────────────────────────────────────────────────────────────────┘
   ● = customer   ◐ = shared   ○ = AWS
```

Exam heuristic: **the moment you can `ssh` into the box, OS patching is yours.** RDS gives you a port and an endpoint, never a shell. The exception is **RDS Custom** (Oracle and SQL Server), which deliberately re-opens OS/database access for legacy applications that need custom agents or third-party binaries — and correspondingly moves that responsibility back to you.

### 1.3 The production scenario used throughout this module

A multi-tenant SaaS platform, `orders-plat`, running on EKS, with four data-shaped workloads:

1. **Transactional order ledger** — strict ACID, joins across `orders / order_items / customers`, 2 000 write TPS peak, 30 000 read TPS peak, RPO ≤ 5 min, RTO ≤ 2 min, must survive a full AZ loss.
2. **Session and cart state** — sub-millisecond reads, 200 000 ops/s, tolerant of loss (rebuildable), spiky.
3. **Per-tenant event/audit feed** — append-heavy, ~50 kB/s per tenant, keyed lookups only, unbounded growth, 7-year retention.
4. **Executive reporting** — 900 GB of history, full-table aggregations, tolerant of 15-minute staleness, queried by 20 analysts.

Every service below gets evaluated against these four.

---

## 2. The AWS database portfolio: taxonomy and trade-off tables

### 2.1 Purpose-built taxonomy

AWS's stated position is **purpose-built databases**: reject the one-relational-engine-for-everything model and match the data model to the access pattern.

| Category | Service | Data model | Canonical access pattern |
|---|---|---|---|
| Relational (OLTP) | **Amazon RDS** | Rows, fixed schema, SQL | Joins, transactions, referential integrity |
| Relational (cloud-native OLTP) | **Amazon Aurora** | Same, MySQL/PostgreSQL wire-compatible | RDS patterns at higher throughput/availability |
| Key-value / document (NoSQL) | **Amazon DynamoDB** | Item collections, schemaless attributes | Single-digit-ms lookups by key at any scale |
| In-memory cache | **Amazon ElastiCache** (Valkey / Redis OSS / Memcached) | Key-value, structures | Microsecond reads, cache-aside, rate limiting |
| In-memory **durable** | **Amazon MemoryDB** | Redis/Valkey API + durable multi-AZ log | Redis as the primary datastore, not a cache |
| Document | **Amazon DocumentDB** (MongoDB compatibility) | JSON documents, CRUD + aggregation | Content catalogs, profiles, flexible schema |
| Graph | **Amazon Neptune** | Property graph + RDF | Traversals: fraud rings, recommendations, lineage |
| Wide-column | **Amazon Keyspaces** (for Apache Cassandra) | CQL tables, partitioned | Cassandra apps, serverless, no ring to operate |
| Time series | **Amazon Timestream** (LiveAnalytics / InfluxDB) | Measure + dimensions + timestamp | IoT/telemetry, time-window aggregation |
| Data warehouse (OLAP) | **Amazon Redshift** | Columnar MPP | Scans/aggregations over TB–PB |
| Migration | **AWS DMS** + **AWS Schema Conversion Tool** | — | Homogeneous & heterogeneous migration, CDC |

> **Honest currency note.** The CLF-C02 exam guide v1.0 is a frozen document. Two deltas matter as of this writing:
> - **Amazon QLDB** (Quantum Ledger Database) appears in older CLF-C02 in-scope lists. AWS announced its retirement, with **end of support on 2025-07-31**. It may still appear in exam question banks as a distractor for "immutable, cryptographically verifiable ledger". Recognize the concept; do not architect on it.
> - **Aurora DSQL** (serverless, active-active multi-Region distributed SQL, PostgreSQL-compatible) reached GA after the guide was frozen and is therefore **out of exam scope**, but it is the correct modern answer to "multi-Region strongly-consistent relational writes". Section 4.5 covers it as a footnote.

### 2.2 Relational vs. non-relational: the decision table

| Dimension | Relational (RDS / Aurora) | Non-relational (DynamoDB) |
|---|---|---|
| Schema | Fixed, enforced at write, `ALTER TABLE` is a migration event | Schema-on-read; only the key attributes are declared |
| Query flexibility | Ad-hoc SQL, joins, aggregates, window functions | Only the access patterns you indexed for; **no joins** |
| Consistency | ACID, serializable/RC isolation, single-writer | Per-item ACID; `TransactWriteItems` for multi-item ACID; strong or eventual reads selectable per call |
| Scaling model | **Vertical** for writes (bigger instance) + horizontal read replicas | **Horizontal** for both reads and writes, transparently |
| Practical write ceiling | Whatever one writer instance can do (`db.r6g.16xlarge` class) | Effectively unbounded; per-partition ceiling 1 000 WCU |
| Latency profile | Low ms, degrades with lock contention and plan regressions | Single-digit ms p99, flat vs. table size |
| Failure mode under load | Connection exhaustion, lock waits, replication lag | Throttling (`ProvisionedThroughputExceededException`), hot partitions |
| Cost model | Instance-hours (provisioned even when idle) + storage + I/O | Per-request or provisioned capacity; scales to near-zero |
| Operational leverage | Parameter groups, plans, `EXPLAIN`, vacuum tuning | Key design; almost no knobs (that's the point) |
| Best fit in `orders-plat` | **Workload 1** (order ledger) | **Workload 3** (audit feed) |

**The rule that resolves most exam questions:** if the prompt mentions *joins, complex queries, referential integrity, existing SQL application, or "lift and shift a MySQL/Oracle/SQL Server database"* → relational. If it mentions *millisecond latency at any scale, serverless, key-value, flexible schema, unpredictable/spiky traffic* → DynamoDB.

### 2.3 Where the four workloads land

| Workload | Service | Why | Rejected alternative and why |
|---|---|---|---|
| 1. Order ledger | **Aurora PostgreSQL**, Multi-AZ, 1 writer + 2 readers, RDS Proxy | Joins + ACID + AZ-loss survival + 30 k read TPS via readers | RDS Multi-AZ *instance*: 60–120 s failover blows the 2-min RTO budget with no margin; standby is not readable so reads cost more instances |
| 2. Session/cart | **ElastiCache (Valkey)**, cluster mode enabled | Microsecond p99, data is rebuildable | MemoryDB: durability you do not need, ~2× the cost |
| 3. Audit feed | **DynamoDB**, on-demand, PK = `TENANT#<id>`, SK = `TS#<iso>#<uuid>`, TTL, Streams | Unbounded append, keyed reads, no capacity planning | Aurora: an append-only table growing forever turns `VACUUM` and index bloat into a permanent operational tax |
| 4. Reporting | **Redshift Serverless**, loaded from S3 via zero-ETL / DMS | Columnar scans over 900 GB, concurrency isolation from OLTP | Running the reports against Aurora readers: a single 900 GB scan evicts the buffer cache and destroys OLTP p99 |

---

## 3. Amazon RDS — the managed relational baseline

### 3.1 Engines and what distinguishes them operationally

| Engine | License | Notable operational property |
|---|---|---|
| MySQL | Open source | Largest ecosystem; `binlog` drives DMS CDC |
| PostgreSQL | Open source | Extensions (`pg_stat_statements`, `PostGIS`, `pgvector`); autovacuum is the #1 ops concern |
| MariaDB | Open source | MySQL fork; drop-in for many MySQL apps |
| Oracle | BYOL or License Included | RDS Custom available for OS/DB access; Data Guard for replicas |
| SQL Server | License Included mostly | Max 16 TiB storage; no cross-Region automated backup replication on all editions |
| **Db2** | BYOL via AWS Marketplace | Newest addition; niche mainframe-adjacent estates |

### 3.2 Storage classes — the throughput decision

| Type | Backing | IOPS model | Use when |
|---|---|---|---|
| `gp3` | General Purpose SSD | Baseline 3 000 IOPS / 125 MiB/s, provisionable independently of size | **Default.** Decouples IOPS from capacity — this is the fix for the classic `gp2` trap |
| `gp2` | General Purpose SSD (legacy) | 3 IOPS per GiB, burst credits | Legacy only. A 100 GiB `gp2` volume is capped at 300 IOPS and silently throttles once burst balance drains |
| `io1` / `io2 Block Express` | Provisioned IOPS SSD | Up to 256 000 IOPS, 99.999 % durability (`io2`) | Latency-sensitive OLTP with a measured IOPS floor |
| Magnetic | Legacy | — | Deprecated. Never. |

Maximum allocated storage: **64 TiB** for MySQL, MariaDB, PostgreSQL, Oracle; **16 TiB** for SQL Server. Storage autoscaling can grow the volume but **cannot shrink it** — that asymmetry is a budget landmine.

### 3.3 High availability: the two Multi-AZ topologies

This distinction is frequently mis-taught. There are **two different products** named Multi-AZ.

| | **Multi-AZ DB instance** | **Multi-AZ DB cluster** |
|---|---|---|
| Topology | 1 primary + 1 standby | 1 writer + **2 readable** standbys, 3 AZs |
| Replication | Synchronous, block-level | **Semi-synchronous** — commit acks when ≥1 of 2 standbys has the log |
| Standby readable? | **No** — it exists only for failover | **Yes**, via a reader endpoint |
| Typical failover | 60–120 s | **< 35 s** |
| Engines | All RDS engines | MySQL 8.0.28+, PostgreSQL 13.4+ only |
| Storage | Any | `io1`, `io2`, `gp3` only |
| Failover trigger | AZ loss, primary failure, instance type change, patching, manual reboot-with-failover | Same |

**Critical exam and production point:** Multi-AZ is for **availability**, read replicas are for **read scalability**. They are orthogonal and commonly combined. Multi-AZ replication is synchronous (RPO = 0); read-replica replication is **asynchronous** (RPO > 0, replica lag is a real number you must alarm on).

### 3.4 Read replicas

- Asynchronous, engine-native replication (MySQL binlog / PostgreSQL streaming WAL).
- Up to **15** for MySQL, MariaDB, PostgreSQL; **5** for Oracle and SQL Server.
- Can be **cross-Region** (a disaster-recovery and read-locality tool).
- Can be **promoted** to a standalone writable instance — the promotion is one-way and breaks replication.
- Replicas of replicas (cascading) are supported on MySQL/MariaDB/PostgreSQL.

### 3.5 Backup and recovery semantics

| Mechanism | Retention | Granularity | Survives instance deletion? |
|---|---|---|---|
| Automated backups | 0–35 days (0 = disabled; **never** in production) | PITR to any second within retention, transaction logs shipped every ~5 min | No (unless "retain automated backups" is chosen) |
| Manual DB snapshots | Until you delete them | The instant of the snapshot | **Yes** |
| AWS Backup | Per backup plan/vault, cross-account, cross-Region | Snapshot-based | Yes, in the vault |

Restoring **always creates a new instance with a new endpoint**. There is no in-place restore. That single fact dictates your DR runbook: recovery involves a DNS/config cutover, and you must have rehearsed it.

---

## 4. Amazon Aurora — the decoupled-storage relational engine

### 4.1 The storage architecture (why Aurora is not "RDS but faster")

Aurora replaces the engine's storage layer with a purpose-built, log-structured, multi-tenant distributed storage fleet.

```
                    ┌───────────────────────────────────────┐
   Writer ─────────►│  Redo log records only (not pages)     │
   (1 per cluster)  └───────────────┬───────────────────────┘
                                    │  fan-out
      ┌─────────────────────────────┼─────────────────────────────┐
      │                             │                             │
   ┌──▼───┐  ┌──────┐          ┌────▼─┐  ┌──────┐          ┌──────▼┐  ┌──────┐
   │ seg  │  │ seg  │          │ seg  │  │ seg  │          │ seg   │  │ seg  │
   │ 10GB │  │ 10GB │          │ 10GB │  │ 10GB │          │ 10GB  │  │ 10GB │
   └──────┘  └──────┘          └──────┘  └──────┘          └───────┘  └──────┘
      AZ-a (2 copies)             AZ-b (2 copies)             AZ-c (2 copies)

   Write quorum: 4 of 6      Read quorum: 3 of 6
   Tolerates: loss of an entire AZ + 1 additional copy without losing WRITE availability
              loss of an entire AZ                      without losing READ  availability
```

Consequences that matter operationally:

- The writer ships **redo log records**, not dirty 8 kB/16 kB pages. Network amplification drops by roughly an order of magnitude versus a mirrored-EBS design — this is the actual source of Aurora's throughput advantage.
- Storage grows automatically in **10 GB segments up to 128 TiB**. You never provision or extend a volume.
- **All replicas read the same storage volume.** Adding an Aurora Replica does not copy data, so a replica comes online in minutes regardless of database size, and replica lag is typically **tens of milliseconds**, not seconds.
- Failover is a **promotion within a shared-storage cluster**, not a data-catch-up operation. Typically < 30 s, often ~10 s with RDS Proxy in front.

### 4.2 Endpoints — the part applications get wrong

| Endpoint | Resolves to | Use for |
|---|---|---|
| **Cluster (writer)** | Current writer, follows failover | All writes; the only endpoint that survives a failover for writes |
| **Reader** | DNS round-robin across available replicas | Read-only traffic |
| **Custom** | A named subset of instances you define | Isolating analytics readers from app readers |
| **Instance** | One specific instance | Diagnostics only — **never** in application config |

**Failure mode:** the reader endpoint load-balances *per DNS resolution*, not per connection. A JVM with `networkaddress.cache.ttl=-1` resolves once at startup and pins every connection to one replica for the process's lifetime. Set the JVM DNS TTL to 5–10 s or use a pooler.

### 4.3 Aurora feature matrix

| Feature | What it does | Constraint |
|---|---|---|
| **Aurora Replicas** | Up to 15 readers sharing the storage volume | Same Region as the cluster |
| **Backtrack** | Rewind the cluster in place, up to 72 h, without restore | **Aurora MySQL only**; must be enabled at creation |
| **Fast Database Cloning** | Copy-on-write clone of a multi-TB cluster in minutes | Same Region; diverging pages incur storage cost |
| **Global Database** | Up to 5 secondary Regions, physical storage-level replication, typical lag < 1 s | RPO ≈ 1 s; secondaries are read-only unless write forwarding is on |
| **Serverless v2** | Instance capacity in **ACUs** (~2 GiB RAM each), 0/0.5 → 256, scales in seconds | Mixes with provisioned instances in one cluster |
| **RDS Proxy** | Connection pooling, IAM auth, cuts failover time by up to 66 % | Adds ~5 ms; per-vCPU pricing |
| **I/O-Optimized** | Flat price, zero per-I/O charges | ~30 % higher instance/storage rate; wins when I/O > ~25 % of the bill |
| **Zero-ETL to Redshift** | Near-real-time replication into a warehouse, no DMS pipeline | Aurora MySQL/PostgreSQL sources |

### 4.4 RDS vs. Aurora: the honest trade-off

| Criterion | RDS (MySQL/PostgreSQL) | Aurora |
|---|---|---|
| Engine compatibility | The actual upstream engine | Wire-compatible reimplementation; **some extensions/plugins unsupported** |
| Storage max | 64 TiB, pre-allocated, cannot shrink | 128 TiB, auto-grows in 10 GB segments |
| Replica lag | Seconds (async, can diverge under load) | Typically < 100 ms (shared storage) |
| Failover | 60–120 s (instance) / < 35 s (cluster) | Typically < 30 s |
| Durability | 1 primary + 1 sync standby (Multi-AZ) | 6 copies / 3 AZs, 4-of-6 write quorum |
| Baseline cost | Lower for small, steady workloads | Higher instance rate; per-I/O charges on Standard |
| Point-in-time rewind | Restore-to-new-instance only | Restore **or** Backtrack (MySQL) |
| Choose it when | Cost-sensitive, needs exotic extensions, small footprint | HA/throughput matter, or you want the storage layer to stop being your problem |

### 4.5 Footnote: Aurora DSQL (out of CLF-C02 scope)

Aurora DSQL is a serverless, PostgreSQL-compatible **distributed** SQL database with active-active multi-Region writes and optimistic concurrency control, targeting 99.999 % multi-Region availability. It resolves the constraint that classic Aurora Global Database cannot: **strongly consistent writes in more than one Region simultaneously**. It postdates the frozen exam guide — know it for architecture work, not for the exam.

---

## 5. Amazon DynamoDB — the serverless key-value engine

### 5.1 The partitioning model, which is the whole service

```
   PutItem(pk = "TENANT#4711", sk = "TS#2026-09-04T10:00:00Z#a1b2")
              │
              ▼
       MD5(partition key)  ──►  hash space  ──►  Partition P17
                                                     │
                          ┌──────────────────────────┼──────────────────────────┐
                          ▼                          ▼                          ▼
                    Replica AZ-a              Replica AZ-b              Replica AZ-c
                    (leader for P17)
                          │
                  Quorum write: leader + 1 of 2 followers
```

Hard limits that shape every schema decision:

| Limit | Value | Consequence |
|---|---|---|
| Item size | **400 KB** | Large blobs go to S3; store the S3 key in the item |
| Partition capacity | **3 000 RCU / 1 000 WCU**, **10 GB** | A single hot key cannot exceed this — no amount of table capacity helps |
| Query result page | 1 MB | Pagination is mandatory, not optional |
| `BatchGetItem` | 100 items / 16 MB | |
| `BatchWriteItem` | 25 items / 16 MB | Not atomic — partial failures return `UnprocessedItems` |
| `TransactWriteItems` | 100 items / 4 MB | Atomic; **consumes 2× the capacity** |
| GSIs per table | 20 (default, adjustable) | |
| LSIs per table | 5, **declared at table creation only** | Cannot be added later — a schema migration |

Capacity unit arithmetic (memorize):

- **1 RCU** = one *strongly consistent* read of up to **4 KB/s**, or **two** *eventually consistent* reads of 4 KB/s.
- **1 WCU** = one write of up to **1 KB/s**.
- A transactional read costs **2 RCU**; a transactional write costs **2 WCU**.

### 5.2 Capacity modes

| Mode | Billing | Scaling | Choose when |
|---|---|---|---|
| **On-demand** | Per request (RRU/WRU) | Instant to 2× the previous peak; doubles automatically | Unknown, spiky, or new workloads; dev/test; sustained < ~15 % utilization |
| **Provisioned** | Per capacity-unit-hour | Application Auto Scaling on a utilization target (default 70 %) | Predictable, steady traffic — up to ~7× cheaper at high, flat utilization |

On-demand tables can now carry **maximum** read/write request-unit ceilings — use them as a runaway-cost circuit breaker.

### 5.3 Index types

| | **LSI** (Local Secondary Index) | **GSI** (Global Secondary Index) |
|---|---|---|
| Partition key | **Same as base table** | **Any attribute** |
| Sort key | Different | Any attribute |
| Created | **Only at table creation** | Any time, online |
| Consistency | Strong reads available | **Eventually consistent only** |
| Capacity | Shares the table's | **Its own** — a throttled GSI throttles base-table *writes* |
| Constraint | 10 GB per item collection (per partition key) | None |

**The GSI back-pressure failure mode:** an under-provisioned GSI cannot absorb index writes, and DynamoDB will throttle writes to the **base table** to protect it. Symptom: `WriteThrottleEvents` on the base table with base-table capacity nowhere near its ceiling. Always alarm on GSI throttling separately.

### 5.4 The DynamoDB ecosystem

| Feature | Purpose | Key detail |
|---|---|---|
| **DAX** | In-memory cache in front of DynamoDB | **Microsecond** reads; API-compatible (no app rewrite); item cache + query cache; write-through |
| **Streams** | Ordered change log per item | **24 h** retention; triggers Lambda; `NEW_AND_OLD_IMAGES` view options |
| **Kinesis Data Streams for DynamoDB** | Same changes into Kinesis | Up to **365 days** retention |
| **Global Tables** | Multi-Region, **multi-active** replication | **Last-writer-wins** conflict resolution — not suitable for counters or financial balances |
| **PITR** | Continuous backup | Restore to any second in the last **35 days**, to a **new table** |
| **On-demand backup** | Full snapshot | Retained until deleted; zero performance impact |
| **TTL** | Automatic expiry by epoch-seconds attribute | **Free**, but deletion is best-effort within ~48 h; a TTL delete appears in Streams |
| **Table classes** | Standard / Standard-IA | Standard-IA: ~60 % lower storage cost, ~25 % higher request cost — for archival access patterns |

**Exam trap:** DAX caches *DynamoDB* only. ElastiCache is generic. If a question says "microsecond latency for an existing DynamoDB application with no code changes", the answer is **DAX**, not ElastiCache.

---

## 6. In-memory: ElastiCache and MemoryDB

### 6.1 Engine comparison

| | **Valkey / Redis OSS** | **Memcached** | **MemoryDB** |
|---|---|---|---|
| Data structures | Strings, lists, sets, sorted sets, hashes, streams, HLL, geo | Strings only | Same as Valkey/Redis |
| Threading | Mostly single-threaded per shard (enhanced I/O aside) | **Multi-threaded** — scales vertically on cores | Multi-threaded |
| Replication | Yes, up to 5 replicas per shard | **No** | Yes |
| Multi-AZ + auto failover | Yes | No | Yes, by design |
| Persistence | Snapshots (RDB) / AOF | **None** | **Durable multi-AZ transaction log** |
| Durability guarantee | Cache semantics — data loss is expected | None | **Primary database semantics** |
| Read latency | Microseconds | Microseconds | Microseconds |
| Write latency | Microseconds | Microseconds | **Single-digit milliseconds** (log commit) |
| Pub/Sub, Lua, transactions | Yes | No | Yes |
| Use for | Cache-aside, sessions, leaderboards, rate limits, queues | Simple, horizontally-sharded object cache | Redis-API app where Redis **is** the system of record |

Valkey (the Linux Foundation fork of Redis after the license change) is the forward-looking default on ElastiCache and carries a lower price point than Redis OSS nodes.

### 6.2 Caching strategies and their failure modes

| Strategy | Mechanics | Failure mode |
|---|---|---|
| **Lazy loading / cache-aside** | Miss → read DB → populate cache | **Cache stampede**: N concurrent misses on the same hot key all hit the DB. Mitigate with a per-key mutex or `SETNX` lock |
| **Write-through** | Every write updates cache and DB | Cache fills with data never read; write latency doubles |
| **TTL on everything** | Bounded staleness | **Synchronized expiry** — thousands of keys expiring in the same second produce a thundering herd. Jitter the TTL: `ttl = base + rand(0, base*0.1)` |

---

## 7. Purpose-built engines

| Service | Model | Query language | Architecture notes |
|---|---|---|---|
| **DocumentDB** | JSON documents, MongoDB API compatibility | MongoDB query API / aggregation pipeline | Aurora-style separated storage: 6 copies / 3 AZs, up to 64 TiB, up to 15 replicas. Compatibility is per-version — validate your driver and operators |
| **Neptune** | Property graph + RDF triples | **Gremlin**, **openCypher**, **SPARQL** | Aurora-style storage. Answers "shortest path", "who is connected to whom", "fraud ring detection" — queries where a relational solution needs recursive CTEs and self-joins |
| **Keyspaces** | Wide-column | **CQL** (Cassandra 3.11 / 4.x compatible) | **Serverless** — no ring, no nodes, no compaction, no repair. On-demand or provisioned. Removes the single largest ops burden of self-managed Cassandra |
| **Timestream** | Time series | SQL with time-series functions (`INTERPOLATE`, `SPLINE`) | LiveAnalytics: tiered memory store → magnetic store with automatic movement. Also offered as managed **InfluxDB** |
| **Redshift** | Columnar MPP warehouse | PostgreSQL-dialect SQL | RA3 nodes with managed storage separate compute from storage; **Redshift Serverless** bills in RPUs; **Spectrum** queries S3 in place; Concurrency Scaling adds transient clusters for query bursts |

### 7.1 OLTP vs. OLAP — the boundary that decides Redshift questions

| | OLTP (RDS/Aurora/DynamoDB) | OLAP (Redshift) |
|---|---|---|
| Unit of work | Single row / small set | Millions of rows, few columns |
| Storage layout | **Row-oriented** | **Columnar** + compression + zone maps |
| Concurrency | Thousands of short transactions | Tens of long-running queries |
| Latency target | Milliseconds | Seconds to minutes |
| Data freshness | Now | Minutes to hours (or near-real-time via zero-ETL) |
| Question shape | "Get order 4711" | "Revenue by region by month for 3 years" |

If an exam prompt contains *data warehouse, business intelligence, analytics, complex queries over large historical datasets, petabyte scale* → **Redshift**. If it says *query data directly in S3 with SQL, serverless, pay per query scanned* → **Athena**, not Redshift.

---

## 8. Migration: AWS DMS and SCT

### 8.1 Component model

```
  Source                    DMS Replication Instance                Target
  ┌────────────┐            (or DMS Serverless)                  ┌────────────┐
  │ Oracle 19c │──endpoint─►┌──────────────────────┐──endpoint──►│  Aurora    │
  │ on-prem    │            │  Task: full load     │             │ PostgreSQL │
  │            │            │      + CDC (ongoing) │             │            │
  └────────────┘            │  Table mappings JSON │             └────────────┘
        │                   │  Transformation rules│
        │                   └──────────────────────┘
        │                              ▲
        └──── AWS SCT ─────────────────┘
              (schema, PL/SQL → PL/pgSQL, assessment report)
```

| Migration type | Schema conversion needed? | Tooling |
|---|---|---|
| **Homogeneous** (Oracle → Oracle, MySQL → Aurora MySQL) | No | DMS alone |
| **Heterogeneous** (Oracle → Aurora PostgreSQL, SQL Server → MySQL) | **Yes** | **SCT** (or DMS Schema Conversion) first, then DMS for data |

### 8.2 Task modes

| Mode | Behavior | Use for |
|---|---|---|
| Full load | One-time bulk copy | Static datasets, dev refreshes |
| Full load + CDC | Bulk copy, then stream ongoing changes from the source transaction log | **Near-zero-downtime cutover** — the canonical production pattern |
| CDC only | Changes from a specified LSN/SCN onward | Resuming after an out-of-band bulk load |

Key operational facts:
- DMS **does not** migrate secondary indexes, sequences, stored procedures, triggers, or foreign keys by default — SCT or a manual DDL pass handles those. Foreign keys and triggers are typically **disabled during full load** and re-enabled before cutover, or the load fails on ordering.
- The source database must have logical replication / supplemental logging enabled (`ARCHIVELOG` + supplemental logging for Oracle; `wal_level=logical` for PostgreSQL; `binlog_format=ROW` for MySQL).
- **DMS Fleet Advisor** discovers and sizes an on-prem estate; **DMS Serverless** removes replication-instance capacity planning.

---

## 9. Infrastructure as code — complete manifests

### 9.1 CloudFormation: production Aurora PostgreSQL cluster with Serverless v2, RDS Proxy, and alarms

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  orders-plat: production Aurora PostgreSQL cluster.
  1 provisioned writer + 2 Serverless v2 readers across 3 AZs,
  customer-managed KMS, Secrets Manager rotation, RDS Proxy,
  Performance Insights, Enhanced Monitoring and CloudWatch alarms.

Parameters:
  EnvName:
    Type: String
    Default: prod
    AllowedValues: [dev, staging, prod]
  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC hosting the EKS data plane.
  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least three private subnets in three distinct AZs.
  AppSecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id
    Description: Security group attached to the EKS worker nodes.
  EngineVersion:
    Type: String
    Default: '16.4'
  WriterInstanceClass:
    Type: String
    Default: db.r6g.2xlarge
  ReaderMinCapacity:
    Type: Number
    Default: 2
    Description: Minimum Aurora Capacity Units per Serverless v2 reader.
  ReaderMaxCapacity:
    Type: Number
    Default: 32
  BackupRetentionDays:
    Type: Number
    Default: 35
    MinValue: 7
    MaxValue: 35
  AlarmTopicArn:
    Type: String
    Description: SNS topic ARN that pages the on-call rotation.

Conditions:
  IsProd: !Equals [!Ref EnvName, prod]

Resources:

  # ---------------------------------------------------------------- encryption
  DatabaseKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for orders-plat ${EnvName} Aurora cluster'
      EnableKeyRotation: true
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnableIAMUserPermissions
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowRDSService
            Effect: Allow
            Principal:
              Service: rds.amazonaws.com
            Action:
              - kms:Decrypt
              - kms:GenerateDataKey*
              - kms:CreateGrant
              - kms:DescribeKey
            Resource: '*'

  DatabaseKmsAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/orders-plat-${EnvName}-aurora'
      TargetKeyId: !Ref DatabaseKmsKey

  # ------------------------------------------------------------------ secrets
  MasterUserSecret:
    Type: AWS::SecretsManager::Secret
    Properties:
      Name: !Sub 'orders-plat/${EnvName}/aurora/master'
      Description: Aurora PostgreSQL master credentials for orders-plat.
      KmsKeyId: !Ref DatabaseKmsKey
      GenerateSecretString:
        SecretStringTemplate: '{"username":"ordersadmin"}'
        GenerateStringKey: password
        PasswordLength: 40
        ExcludeCharacters: '"@/\ '
      Tags:
        - Key: Environment
          Value: !Ref EnvName

  MasterUserSecretAttachment:
    Type: AWS::SecretsManager::SecretTargetAttachment
    Properties:
      SecretId: !Ref MasterUserSecret
      TargetId: !Ref AuroraCluster
      TargetType: AWS::RDS::DBCluster

  # ------------------------------------------------------------- networking
  DbSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupName: !Sub 'orders-plat-${EnvName}-aurora'
      DBSubnetGroupDescription: Private subnets across three AZs.
      SubnetIds: !Ref PrivateSubnetIds

  DbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'orders-plat ${EnvName} Aurora ingress'
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 5432
          ToPort: 5432
          SourceSecurityGroupId: !Ref AppSecurityGroupId
          Description: PostgreSQL from EKS worker nodes.
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
          Description: Egress required for KMS/Secrets/CloudWatch endpoints.
      Tags:
        - Key: Name
          Value: !Sub 'orders-plat-${EnvName}-aurora-sg'

  ProxySecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'orders-plat ${EnvName} RDS Proxy'
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 5432
          ToPort: 5432
          SourceSecurityGroupId: !Ref AppSecurityGroupId
          Description: PostgreSQL from EKS worker nodes.

  ProxyToDbIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref DbSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      SourceSecurityGroupId: !Ref ProxySecurityGroup
      Description: PostgreSQL from RDS Proxy.

  # ------------------------------------------------------- parameter groups
  ClusterParameterGroup:
    Type: AWS::RDS::DBClusterParameterGroup
    Properties:
      Description: !Sub 'orders-plat ${EnvName} cluster parameters'
      Family: aurora-postgresql16
      Parameters:
        rds.force_ssl: '1'
        log_min_duration_statement: '1000'
        log_statement: ddl
        log_lock_waits: '1'
        log_temp_files: '0'
        shared_preload_libraries: 'pg_stat_statements,auto_explain'
        'auto_explain.log_min_duration': '3000'
        'auto_explain.log_analyze': '1'
        track_activity_query_size: '4096'

  DbParameterGroup:
    Type: AWS::RDS::DBParameterGroup
    Properties:
      Description: !Sub 'orders-plat ${EnvName} instance parameters'
      Family: aurora-postgresql16
      Parameters:
        idle_in_transaction_session_timeout: '300000'   # 5 min, in ms
        statement_timeout: '60000'                      # 60 s, in ms
        tcp_keepalives_idle: '60'
        tcp_keepalives_interval: '10'
        tcp_keepalives_count: '6'

  # ------------------------------------------------------------- monitoring
  EnhancedMonitoringRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: monitoring.rds.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole'

  # ---------------------------------------------------------------- cluster
  AuroraCluster:
    Type: AWS::RDS::DBCluster
    DeletionPolicy: Snapshot
    UpdateReplacePolicy: Snapshot
    Properties:
      DBClusterIdentifier: !Sub 'orders-plat-${EnvName}'
      Engine: aurora-postgresql
      EngineVersion: !Ref EngineVersion
      DatabaseName: orders
      MasterUsername: !Sub '{{resolve:secretsmanager:${MasterUserSecret}:SecretString:username}}'
      MasterUserPassword: !Sub '{{resolve:secretsmanager:${MasterUserSecret}:SecretString:password}}'
      DBSubnetGroupName: !Ref DbSubnetGroup
      VpcSecurityGroupIds:
        - !Ref DbSecurityGroup
      DBClusterParameterGroupName: !Ref ClusterParameterGroup
      StorageEncrypted: true
      KmsKeyId: !Ref DatabaseKmsKey
      StorageType: aurora-iopt1              # Aurora I/O-Optimized: flat pricing
      BackupRetentionPeriod: !Ref BackupRetentionDays
      PreferredBackupWindow: '03:00-04:00'
      PreferredMaintenanceWindow: 'sun:05:00-sun:06:00'
      CopyTagsToSnapshot: true
      DeletionProtection: !If [IsProd, true, false]
      EnableIAMDatabaseAuthentication: true
      EnableCloudwatchLogsExports:
        - postgresql
      ServerlessV2ScalingConfiguration:
        MinCapacity: !Ref ReaderMinCapacity
        MaxCapacity: !Ref ReaderMaxCapacity
      Tags:
        - Key: Environment
          Value: !Ref EnvName
        - Key: DataClassification
          Value: confidential

  WriterInstance:
    Type: AWS::RDS::DBInstance
    Properties:
      DBInstanceIdentifier: !Sub 'orders-plat-${EnvName}-writer'
      DBClusterIdentifier: !Ref AuroraCluster
      Engine: aurora-postgresql
      DBInstanceClass: !Ref WriterInstanceClass
      DBParameterGroupName: !Ref DbParameterGroup
      PromotionTier: 0
      AutoMinorVersionUpgrade: true
      EnablePerformanceInsights: true
      PerformanceInsightsKMSKeyId: !Ref DatabaseKmsKey
      PerformanceInsightsRetentionPeriod: 465     # 15 months
      MonitoringInterval: 10
      MonitoringRoleArn: !GetAtt EnhancedMonitoringRole.Arn
      PubliclyAccessible: false

  ReaderInstanceOne:
    Type: AWS::RDS::DBInstance
    DependsOn: WriterInstance
    Properties:
      DBInstanceIdentifier: !Sub 'orders-plat-${EnvName}-reader-1'
      DBClusterIdentifier: !Ref AuroraCluster
      Engine: aurora-postgresql
      DBInstanceClass: db.serverless
      DBParameterGroupName: !Ref DbParameterGroup
      PromotionTier: 1
      EnablePerformanceInsights: true
      PerformanceInsightsKMSKeyId: !Ref DatabaseKmsKey
      MonitoringInterval: 10
      MonitoringRoleArn: !GetAtt EnhancedMonitoringRole.Arn
      PubliclyAccessible: false

  ReaderInstanceTwo:
    Type: AWS::RDS::DBInstance
    DependsOn: WriterInstance
    Properties:
      DBInstanceIdentifier: !Sub 'orders-plat-${EnvName}-reader-2'
      DBClusterIdentifier: !Ref AuroraCluster
      Engine: aurora-postgresql
      DBInstanceClass: db.serverless
      DBParameterGroupName: !Ref DbParameterGroup
      PromotionTier: 1
      EnablePerformanceInsights: true
      PerformanceInsightsKMSKeyId: !Ref DatabaseKmsKey
      MonitoringInterval: 10
      MonitoringRoleArn: !GetAtt EnhancedMonitoringRole.Arn
      PubliclyAccessible: false

  # -------------------------------------------------------------- RDS Proxy
  ProxyRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: rds.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: read-master-secret
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - secretsmanager:GetSecretValue
                Resource: !Ref MasterUserSecret
              - Effect: Allow
                Action:
                  - kms:Decrypt
                Resource: !GetAtt DatabaseKmsKey.Arn
                Condition:
                  StringEquals:
                    'kms:ViaService': !Sub 'secretsmanager.${AWS::Region}.amazonaws.com'

  DbProxy:
    Type: AWS::RDS::DBProxy
    Properties:
      DBProxyName: !Sub 'orders-plat-${EnvName}-proxy'
      EngineFamily: POSTGRESQL
      RoleArn: !GetAtt ProxyRole.Arn
      VpcSubnetIds: !Ref PrivateSubnetIds
      VpcSecurityGroupIds:
        - !Ref ProxySecurityGroup
      RequireTLS: true
      IdleClientTimeout: 1800
      DebugLogging: false
      Auth:
        - AuthScheme: SECRETS
          SecretArn: !Ref MasterUserSecret
          IAMAuth: REQUIRED
          ClientPasswordAuthType: POSTGRES_SCRAM_SHA_256

  DbProxyTargetGroup:
    Type: AWS::RDS::DBProxyTargetGroup
    Properties:
      DBProxyName: !Ref DbProxy
      TargetGroupName: default
      DBClusterIdentifiers:
        - !Ref AuroraCluster
      ConnectionPoolConfigurationInfo:
        MaxConnectionsPercent: 90
        MaxIdleConnectionsPercent: 50
        ConnectionBorrowTimeout: 120

  # ----------------------------------------------------------------- alarms
  WriterCpuAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-writer-cpu-high'
      AlarmDescription: Writer CPU sustained above 80% for 15 minutes.
      Namespace: AWS/RDS
      MetricName: CPUUtilization
      Dimensions:
        - Name: DBInstanceIdentifier
          Value: !Ref WriterInstance
      Statistic: Average
      Period: 300
      EvaluationPeriods: 3
      Threshold: 80
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching
      AlarmActions: [!Ref AlarmTopicArn]
      OKActions: [!Ref AlarmTopicArn]

  ReplicaLagAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-replica-lag'
      AlarmDescription: Aurora replica lag above 1s — read-after-write may break.
      Namespace: AWS/RDS
      MetricName: AuroraReplicaLagMaximum
      Dimensions:
        - Name: DBClusterIdentifier
          Value: !Ref AuroraCluster
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 1000            # milliseconds
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopicArn]

  ConnectionSaturationAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-connections-high'
      AlarmDescription: Database connections approaching max_connections.
      Namespace: AWS/RDS
      MetricName: DatabaseConnections
      Dimensions:
        - Name: DBClusterIdentifier
          Value: !Ref AuroraCluster
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 1600
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopicArn]

  DeadlockAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub 'orders-plat-${EnvName}-deadlocks'
      AlarmDescription: Deadlocks detected on the writer.
      Namespace: AWS/RDS
      MetricName: Deadlocks
      Dimensions:
        - Name: DBClusterIdentifier
          Value: !Ref AuroraCluster
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopicArn]

  ClusterEventSubscription:
    Type: AWS::RDS::EventSubscription
    Properties:
      SnsTopicArn: !Ref AlarmTopicArn
      SourceType: db-cluster
      SourceIds:
        - !Ref AuroraCluster
      EventCategories:
        - failover
        - failure
        - maintenance
        - notification
      Enabled: true

Outputs:
  ClusterWriterEndpoint:
    Description: Writer endpoint — follows failover. Use for all writes.
    Value: !GetAtt AuroraCluster.Endpoint.Address
    Export:
      Name: !Sub '${AWS::StackName}-writer-endpoint'
  ClusterReaderEndpoint:
    Description: Reader endpoint — DNS round-robin across available readers.
    Value: !GetAtt AuroraCluster.ReadEndpoint.Address
    Export:
      Name: !Sub '${AWS::StackName}-reader-endpoint'
  ProxyEndpoint:
    Description: RDS Proxy endpoint — preferred for Lambda and short-lived pods.
    Value: !GetAtt DbProxy.Endpoint
    Export:
      Name: !Sub '${AWS::StackName}-proxy-endpoint'
  MasterSecretArn:
    Description: Secrets Manager ARN holding the master credentials.
    Value: !Ref MasterUserSecret
    Export:
      Name: !Sub '${AWS::StackName}-master-secret-arn'
  KmsKeyArn:
    Description: CMK protecting cluster storage, snapshots and Performance Insights.
    Value: !GetAtt DatabaseKmsKey.Arn
```

### 9.2 CloudFormation: DynamoDB audit table with GSI, autoscaling, TTL, PITR and Streams

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  orders-plat tenant audit feed. Single-table design with one GSI,
  provisioned capacity under Application Auto Scaling, TTL-based expiry,
  point-in-time recovery, KMS encryption and a Streams-driven consumer.

Parameters:
  EnvName:
    Type: String
    Default: prod
  TableReadMin:
    Type: Number
    Default: 50
  TableReadMax:
    Type: Number
    Default: 4000
  TableWriteMin:
    Type: Number
    Default: 100
  TableWriteMax:
    Type: Number
    Default: 8000
  TargetUtilization:
    Type: Number
    Default: 70

Resources:

  AuditKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for orders-plat ${EnvName} audit table'
      EnableKeyRotation: true
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'

  AuditTable:
    Type: AWS::DynamoDB::Table
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      TableName: !Sub 'orders-plat-${EnvName}-audit'
      BillingMode: PROVISIONED
      TableClass: STANDARD
      DeletionProtectionEnabled: true

      # PK groups all events of one tenant; SK gives chronological range queries.
      AttributeDefinitions:
        - AttributeName: pk            # TENANT#<tenant_id>
          AttributeType: S
        - AttributeName: sk            # TS#<iso8601>#<event_uuid>
          AttributeType: S
        - AttributeName: gsi1pk        # ACTOR#<principal_arn>
          AttributeType: S
        - AttributeName: gsi1sk        # TS#<iso8601>
          AttributeType: S
      KeySchema:
        - AttributeName: pk
          KeyType: HASH
        - AttributeName: sk
          KeyType: RANGE

      ProvisionedThroughput:
        ReadCapacityUnits: !Ref TableReadMin
        WriteCapacityUnits: !Ref TableWriteMin

      GlobalSecondaryIndexes:
        - IndexName: gsi1-actor-time
          KeySchema:
            - AttributeName: gsi1pk
              KeyType: HASH
            - AttributeName: gsi1sk
              KeyType: RANGE
          Projection:
            ProjectionType: INCLUDE
            NonKeyAttributes:
              - action
              - resource
              - outcome
          ProvisionedThroughput:
            ReadCapacityUnits: !Ref TableReadMin
            WriteCapacityUnits: !Ref TableWriteMin

      TimeToLiveSpecification:
        AttributeName: expires_at        # epoch seconds
        Enabled: true

      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: true

      SSESpecification:
        SSEEnabled: true
        SSEType: KMS
        KMSMasterKeyId: !Ref AuditKmsKey

      StreamSpecification:
        StreamViewType: NEW_AND_OLD_IMAGES

      ContributorInsightsSpecification:
        Enabled: true

      Tags:
        - Key: Environment
          Value: !Ref EnvName
        - Key: DataClassification
          Value: audit

  # ------------------------------------------------- Application Auto Scaling
  AutoScalingRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: application-autoscaling.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: dynamodb-autoscaling
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - dynamodb:DescribeTable
                  - dynamodb:UpdateTable
                Resource:
                  - !GetAtt AuditTable.Arn
                  - !Sub '${AuditTable.Arn}/index/*'
              - Effect: Allow
                Action:
                  - cloudwatch:PutMetricAlarm
                  - cloudwatch:DescribeAlarms
                  - cloudwatch:DeleteAlarms
                  - cloudwatch:GetMetricStatistics
                  - cloudwatch:SetAlarmState
                Resource: '*'

  TableWriteScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: dynamodb
      ResourceId: !Sub 'table/${AuditTable}'
      ScalableDimension: 'dynamodb:table:WriteCapacityUnits'
      MinCapacity: !Ref TableWriteMin
      MaxCapacity: !Ref TableWriteMax
      RoleARN: !GetAtt AutoScalingRole.Arn

  TableWriteScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: !Sub '${AuditTable}-write-target-tracking'
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref TableWriteScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: !Ref TargetUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: DynamoDBWriteCapacityUtilization

  TableReadScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: dynamodb
      ResourceId: !Sub 'table/${AuditTable}'
      ScalableDimension: 'dynamodb:table:ReadCapacityUnits'
      MinCapacity: !Ref TableReadMin
      MaxCapacity: !Ref TableReadMax
      RoleARN: !GetAtt AutoScalingRole.Arn

  TableReadScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: !Sub '${AuditTable}-read-target-tracking'
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref TableReadScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: !Ref TargetUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: DynamoDBReadCapacityUtilization

  # A throttled GSI back-pressures writes onto the BASE table. Scale it too.
  IndexWriteScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: dynamodb
      ResourceId: !Sub 'table/${AuditTable}/index/gsi1-actor-time'
      ScalableDimension: 'dynamodb:index:WriteCapacityUnits'
      MinCapacity: !Ref TableWriteMin
      MaxCapacity: !Ref TableWriteMax
      RoleARN: !GetAtt AutoScalingRole.Arn

  IndexWriteScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: !Sub '${AuditTable}-gsi1-write-target-tracking'
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref IndexWriteScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: !Ref TargetUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: DynamoDBWriteCapacityUtilization

  # ----------------------------------------------------------------- alarms
  WriteThrottleAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${AuditTable}-write-throttles'
      AlarmDescription: Writes are being rejected — capacity or hot partition.
      Namespace: AWS/DynamoDB
      MetricName: WriteThrottleEvents
      Dimensions:
        - Name: TableName
          Value: !Ref AuditTable
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 3
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

  SystemErrorAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${AuditTable}-system-errors'
      AlarmDescription: HTTP 500s from DynamoDB — service-side failures.
      Namespace: AWS/DynamoDB
      MetricName: SystemErrors
      Dimensions:
        - Name: TableName
          Value: !Ref AuditTable
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

Outputs:
  TableName:
    Value: !Ref AuditTable
  TableArn:
    Value: !GetAtt AuditTable.Arn
  StreamArn:
    Description: Feed this to a Lambda EventSourceMapping or Kinesis consumer.
    Value: !GetAtt AuditTable.StreamArn
```

### 9.3 Kubernetes: ACK (AWS Controllers for Kubernetes) + External Secrets

Declaring AWS databases from the same GitOps repository as the workloads keeps one reconciliation loop instead of two.

```yaml
---
# Subnet group — the ACK RDS controller reconciles this into a real AWS resource.
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBSubnetGroup
metadata:
  name: orders-plat-prod
  namespace: data
spec:
  name: orders-plat-prod
  description: Private subnets across three AZs for orders-plat.
  subnetIDs:
    - subnet-0a1b2c3d4e5f60718
    - subnet-0a1b2c3d4e5f60719
    - subnet-0a1b2c3d4e5f6071a
  tags:
    - key: Environment
      value: prod
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBClusterParameterGroup
metadata:
  name: orders-plat-prod-cluster-pg
  namespace: data
spec:
  name: orders-plat-prod-cluster-pg
  description: orders-plat cluster parameters (TLS enforced, slow-query logging).
  family: aurora-postgresql16
  parameterOverrides:
    rds.force_ssl: "1"
    log_min_duration_statement: "1000"
    shared_preload_libraries: "pg_stat_statements,auto_explain"
---
apiVersion: v1
kind: Secret
metadata:
  name: aurora-master-password
  namespace: data
type: Opaque
stringData:
  # In practice this Secret is itself produced by External Secrets from
  # Secrets Manager; it is inlined here only to show the reference shape.
  password: "REPLACED-BY-EXTERNAL-SECRETS"
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBCluster
metadata:
  name: orders-plat-prod
  namespace: data
spec:
  dbClusterIdentifier: orders-plat-prod
  engine: aurora-postgresql
  engineVersion: "16.4"
  databaseName: orders
  masterUsername: ordersadmin
  masterUserPassword:
    namespace: data
    name: aurora-master-password
    key: password
  dbSubnetGroupName: orders-plat-prod
  dbClusterParameterGroupName: orders-plat-prod-cluster-pg
  vpcSecurityGroupIDs:
    - sg-0f1e2d3c4b5a69788
  storageEncrypted: true
  kmsKeyID: arn:aws:kms:eu-west-1:111122223333:key/1c9d2f4e-8a3b-4c5d-9e0f-1a2b3c4d5e6f
  backupRetentionPeriod: 35
  preferredBackupWindow: "03:00-04:00"
  preferredMaintenanceWindow: "sun:05:00-sun:06:00"
  deletionProtection: true
  enableIAMDatabaseAuthentication: true
  enableCloudwatchLogsExports:
    - postgresql
  serverlessV2ScalingConfiguration:
    minCapacity: 2
    maxCapacity: 32
  tags:
    - key: Environment
      value: prod
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: orders-plat-prod-writer
  namespace: data
spec:
  dbInstanceIdentifier: orders-plat-prod-writer
  dbClusterIdentifier: orders-plat-prod
  engine: aurora-postgresql
  dbInstanceClass: db.r6g.2xlarge
  promotionTier: 0
  enablePerformanceInsights: true
  performanceInsightsRetentionPeriod: 465
  monitoringInterval: 10
  publiclyAccessible: false
---
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: orders-plat-prod-reader-1
  namespace: data
spec:
  dbInstanceIdentifier: orders-plat-prod-reader-1
  dbClusterIdentifier: orders-plat-prod
  engine: aurora-postgresql
  dbInstanceClass: db.serverless
  promotionTier: 1
  enablePerformanceInsights: true
  publiclyAccessible: false
---
# DynamoDB audit table, same GitOps repo, same reconciliation loop.
apiVersion: dynamodb.services.k8s.aws/v1alpha1
kind: Table
metadata:
  name: orders-plat-prod-audit
  namespace: data
spec:
  tableName: orders-plat-prod-audit
  billingMode: PAY_PER_REQUEST
  attributeDefinitions:
    - attributeName: pk
      attributeType: S
    - attributeName: sk
      attributeType: S
    - attributeName: gsi1pk
      attributeType: S
    - attributeName: gsi1sk
      attributeType: S
  keySchema:
    - attributeName: pk
      keyType: HASH
    - attributeName: sk
      keyType: RANGE
  globalSecondaryIndexes:
    - indexName: gsi1-actor-time
      keySchema:
        - attributeName: gsi1pk
          keyType: HASH
        - attributeName: gsi1sk
          keyType: RANGE
      projection:
        projectionType: INCLUDE
        nonKeyAttributes: [action, resource, outcome]
  timeToLive:
    attributeName: expires_at
    enabled: true
  pointInTimeRecovery:
    enabled: true
  sseSpecification:
    enabled: true
    sseType: KMS
  streamSpecification:
    streamEnabled: true
    streamViewType: NEW_AND_OLD_IMAGES
  tags:
    - key: Environment
      value: prod
---
# Pull the rotated master credential out of Secrets Manager into the cluster.
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: orders-db-credentials
  namespace: orders
spec:
  refreshInterval: 15m       # shorter than the Secrets Manager rotation period
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: orders-db
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        # libpq DSN assembled from the JSON that Secrets Manager stores.
        DATABASE_URL: >-
          postgresql://{{ .username }}:{{ .password }}@{{ .host }}:{{ .port }}/orders?sslmode=verify-full&sslrootcert=/etc/ssl/certs/rds-global-bundle.pem
  dataFrom:
    - extract:
        key: orders-plat/prod/aurora/master
---
# Application deployment: reads the DSN, mounts the RDS CA bundle, and
# points writes at the proxy endpoint.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: orders
spec:
  replicas: 6
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
    spec:
      serviceAccountName: orders-api
      containers:
        - name: api
          image: registry.internal/orders-api:1.42.0
          ports:
            - containerPort: 8080
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: orders-db
                  key: DATABASE_URL
            - name: DATABASE_READ_HOST
              value: orders-plat-prod.cluster-ro-cxyz123abc.eu-west-1.rds.amazonaws.com
            - name: PGPOOL_MAX_CONNS
              value: "20"
            # Force short JVM/DNS caching so the reader endpoint rebalances.
            - name: AWS_STS_REGIONAL_ENDPOINTS
              value: regional
          volumeMounts:
            - name: rds-ca
              mountPath: /etc/ssl/certs/rds-global-bundle.pem
              subPath: rds-global-bundle.pem
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz/db
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              memory: 1Gi
      volumes:
        - name: rds-ca
          configMap:
            name: rds-ca-bundle
```

### 9.4 DMS: replication task with table mappings and settings

```json
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "include-orders-schema",
      "object-locator": {
        "schema-name": "ORDERS",
        "table-name": "%"
      },
      "rule-action": "include",
      "filters": []
    },
    {
      "rule-type": "selection",
      "rule-id": "2",
      "rule-name": "exclude-staging-tables",
      "object-locator": {
        "schema-name": "ORDERS",
        "table-name": "STG_%"
      },
      "rule-action": "exclude",
      "filters": []
    },
    {
      "rule-type": "transformation",
      "rule-id": "3",
      "rule-name": "lowercase-schema",
      "rule-target": "schema",
      "object-locator": { "schema-name": "ORDERS" },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "4",
      "rule-name": "lowercase-tables",
      "rule-target": "table",
      "object-locator": { "schema-name": "ORDERS", "table-name": "%" },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "5",
      "rule-name": "lowercase-columns",
      "rule-target": "column",
      "object-locator": {
        "schema-name": "ORDERS",
        "table-name": "%",
        "column-name": "%"
      },
      "rule-action": "convert-lowercase"
    }
  ]
}
```

```json
{
  "TargetMetadata": {
    "TargetSchema": "",
    "SupportLobs": true,
    "FullLobMode": false,
    "LobChunkSize": 64,
    "LimitedSizeLobMode": true,
    "LobMaxSize": 32,
    "BatchApplyEnabled": true,
    "ParallelLoadThreads": 8,
    "ParallelLoadBufferSize": 200
  },
  "FullLoadSettings": {
    "TargetTablePrepMode": "DROP_AND_CREATE",
    "MaxFullLoadSubTasks": 8,
    "TransactionConsistencyTimeout": 600,
    "CommitRate": 10000,
    "StopTaskCachedChangesApplied": false,
    "StopTaskCachedChangesNotApplied": false
  },
  "Logging": {
    "EnableLogging": true,
    "LogComponents": [
      { "Id": "SOURCE_UNLOAD",  "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_LOAD",    "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DETAILED_DEBUG" },
      { "Id": "TARGET_APPLY",   "Severity": "LOGGER_SEVERITY_DETAILED_DEBUG" }
    ]
  },
  "ValidationSettings": {
    "EnableValidation": true,
    "ValidationMode": "ROW_LEVEL",
    "ThreadCount": 5,
    "PartitionSize": 10000,
    "FailureMaxCount": 10000,
    "HandleCollationDiff": true,
    "RecordFailureDelayLimitInMinutes": 0,
    "TableFailureMaxCount": 1000
  },
  "ErrorBehavior": {
    "DataErrorPolicy": "LOG_ERROR",
    "TableErrorPolicy": "SUSPEND_TABLE",
    "ApplyErrorDeletePolicy": "IGNORE_RECORD",
    "ApplyErrorInsertPolicy": "LOG_ERROR",
    "ApplyErrorUpdatePolicy": "LOG_ERROR",
    "FullLoadIgnoreConflicts": true
  },
  "ChangeProcessingTuning": {
    "BatchApplyPreserveTransaction": true,
    "BatchApplyTimeoutMin": 1,
    "BatchApplyTimeoutMax": 30,
    "MinTransactionSize": 1000,
    "CommitTimeout": 1,
    "MemoryLimitTotal": 1024,
    "MemoryKeepTime": 60,
    "StatementCacheSize": 50
  }
}
```

---

## 10. CLI: commands and real terminal output

### 10.1 Deploying and inspecting the Aurora cluster

```
$ aws cloudformation deploy \
    --stack-name orders-plat-prod-aurora \
    --template-file aurora-cluster.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        EnvName=prod \
        VpcId=vpc-0d1e2f3a4b5c6d7e8 \
        PrivateSubnetIds=subnet-0a1b2c3d4e5f60718,subnet-0a1b2c3d4e5f60719,subnet-0a1b2c3d4e5f6071a \
        AppSecurityGroupId=sg-0aa11bb22cc33dd44 \
        AlarmTopicArn=arn:aws:sns:eu-west-1:111122223333:oncall-data \
    --tags Environment=prod Owner=platform-sre

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - orders-plat-prod-aurora
```

```
$ aws rds describe-db-clusters \
    --db-cluster-identifier orders-plat-prod \
    --query 'DBClusters[0].{Status:Status,Engine:EngineVersion,MultiAZ:MultiAZ,
             Writer:Endpoint,Reader:ReaderEndpoint,Storage:StorageType,
             Backup:BackupRetentionPeriod,Encrypted:StorageEncrypted,
             Members:DBClusterMembers[].{Id:DBInstanceIdentifier,IsWriter:IsClusterWriter,Tier:PromotionTier}}' \
    --output table

------------------------------------------------------------------------------------
|                                DescribeDBClusters                                |
+------------+---------------------------------------------------------------------+
|  Backup    |  35                                                                 |
|  Encrypted |  True                                                               |
|  Engine    |  16.4                                                               |
|  MultiAZ   |  True                                                               |
|  Reader    |  orders-plat-prod.cluster-ro-cxyz123abc.eu-west-1.rds.amazonaws.com |
|  Status    |  available                                                          |
|  Storage   |  aurora-iopt1                                                       |
|  Writer    |  orders-plat-prod.cluster-cxyz123abc.eu-west-1.rds.amazonaws.com    |
+------------+---------------------------------------------------------------------+
||                                    Members                                     ||
|+----------------------------------+--------------+------------------------------+|
||               Id                 |   IsWriter   |             Tier             ||
|+----------------------------------+--------------+------------------------------+|
||  orders-plat-prod-writer         |  True        |  0                           ||
||  orders-plat-prod-reader-1       |  False       |  1                           ||
||  orders-plat-prod-reader-2       |  False       |  1                           ||
|+----------------------------------+--------------+------------------------------+|
```

Confirm the members really are in three distinct AZs — this is the check people skip:

```
$ aws rds describe-db-instances \
    --filters Name=db-cluster-id,Values=orders-plat-prod \
    --query 'DBInstances[].{Id:DBInstanceIdentifier,AZ:AvailabilityZone,
             Class:DBInstanceClass,Status:DBInstanceStatus,PI:PerformanceInsightsEnabled}' \
    --output table

--------------------------------------------------------------------------------
|                              DescribeDBInstances                             |
+----------------+---------------+----------------------+-----------+----------+
|      AZ        |    Class      |         Id           |    PI     |  Status  |
+----------------+---------------+----------------------+-----------+----------+
|  eu-west-1a    |  db.r6g.2xl   |  orders-plat-prod-w..|  True     |  available|
|  eu-west-1b    |  db.serverless|  orders-plat-prod-r1 |  True     |  available|
|  eu-west-1c    |  db.serverless|  orders-plat-prod-r2 |  True     |  available|
+----------------+---------------+----------------------+-----------+----------+
```

### 10.2 Connecting with IAM authentication and TLS

```
$ export PGHOST=orders-plat-prod-proxy.proxy-cxyz123abc.eu-west-1.rds.amazonaws.com
$ export PGPASSWORD="$(aws rds generate-db-auth-token \
      --hostname "$PGHOST" --port 5432 --username orders_app --region eu-west-1)"

$ psql "host=$PGHOST port=5432 dbname=orders user=orders_app \
        sslmode=verify-full sslrootcert=/etc/ssl/certs/rds-global-bundle.pem"

psql (16.4, server 16.4)
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off)
Type "help" for help.

orders=> SELECT current_setting('server_version'),
                pg_is_in_recovery() AS is_reader,
                inet_server_addr()  AS backend_ip;
 current_setting | is_reader |  backend_ip
-----------------+-----------+---------------
 16.4            | f         | 10.42.11.204
(1 row)
```

> The IAM auth token is valid for **15 minutes**. Long-lived pods must regenerate it before every new connection, not once at boot — the classic "works for 15 minutes after deploy, then `PAM authentication failed`" incident.

### 10.3 Rehearsing failover (do this in staging on a schedule)

```
$ date -u +%FT%TZ && aws rds failover-db-cluster \
    --db-cluster-identifier orders-plat-staging \
    --target-db-instance-identifier orders-plat-staging-reader-1 \
    --query 'DBCluster.Status' --output text
2026-09-04T09:41:07Z
failing-over
```

```
$ while true; do
    printf '%s ' "$(date -u +%T)"
    psql -h orders-plat-staging.cluster-cxyz123abc.eu-west-1.rds.amazonaws.com \
         -U ordersadmin -d orders -tAc \
         "select case when pg_is_in_recovery() then 'READER' else 'WRITER' end" \
         2>&1 | tr -d '\n'
    echo
    sleep 1
  done

09:41:08 WRITER
09:41:09 WRITER
09:41:10 psql: error: connection to server ... failed: server closed the connection unexpectedly
09:41:11 psql: error: connection to server ... failed: Connection refused
09:41:12 psql: error: connection to server ... failed: Connection refused
...
09:41:26 psql: error: connection to server ... failed: Connection refused
09:41:27 WRITER
09:41:28 WRITER
```

**Measured RTO: 19 seconds.** Record this number; it is the only failover figure you should quote in a design review, because the marketing "typically under 30 seconds" is a distribution, not your SLO.

Confirm the promotion in the event stream:

```
$ aws rds describe-events \
    --source-identifier orders-plat-staging \
    --source-type db-cluster \
    --duration 10 \
    --query 'Events[].{Time:Date,Message:Message}' --output table

------------------------------------------------------------------------------------
|                                  DescribeEvents                                  |
+---------------------------+------------------------------------------------------+
|  2026-09-04T09:41:08Z     |  Started cross AZ failover to DB instance:            |
|                           |  orders-plat-staging-reader-1                         |
|  2026-09-04T09:41:24Z     |  Completed failover to DB instance:                   |
|                           |  orders-plat-staging-reader-1                         |
+---------------------------+------------------------------------------------------+
```

### 10.4 DynamoDB: capacity accounting made visible

```
$ aws dynamodb describe-table --table-name orders-plat-prod-audit \
    --query 'Table.{Status:TableStatus,Items:ItemCount,Bytes:TableSizeBytes,
             Billing:BillingModeSummary.BillingMode,
             RCU:ProvisionedThroughput.ReadCapacityUnits,
             WCU:ProvisionedThroughput.WriteCapacityUnits,
             Stream:LatestStreamArn,Indexes:GlobalSecondaryIndexes[].IndexName}' \
    --output json
{
    "Status": "ACTIVE",
    "Items": 418293774,
    "Bytes": 902334119488,
    "Billing": "PROVISIONED",
    "RCU": 400,
    "WCU": 2200,
    "Stream": "arn:aws:dynamodb:eu-west-1:111122223333:table/orders-plat-prod-audit/stream/2026-08-19T11:04:22.117",
    "Indexes": [
        "gsi1-actor-time"
    ]
}
```

Always ask for consumed capacity when you profile a query — it converts an opinion into a number:

```
$ aws dynamodb query \
    --table-name orders-plat-prod-audit \
    --key-condition-expression "pk = :t AND sk BETWEEN :a AND :b" \
    --expression-attribute-values '{
        ":t": {"S": "TENANT#4711"},
        ":a": {"S": "TS#2026-09-04T00:00:00Z"},
        ":b": {"S": "TS#2026-09-04T23:59:59Z"}
    }' \
    --return-consumed-capacity INDEXES \
    --max-items 5 \
    --query '{Count:Count,Scanned:ScannedCount,Capacity:ConsumedCapacity}' \
    --output json
{
    "Count": 5,
    "Scanned": 5,
    "Capacity": {
        "TableName": "orders-plat-prod-audit",
        "CapacityUnits": 3.5,
        "Table": {
            "CapacityUnits": 3.5
        }
    }
}
```

`Count == ScannedCount` means the key condition did all the filtering. When `ScannedCount` is orders of magnitude larger than `Count`, you are paying for rows a `FilterExpression` discarded **after** they were read and billed — that is a schema bug, not a capacity problem.

Watch throttling live:

```
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/DynamoDB \
    --metric-name ThrottledRequests \
    --dimensions Name=TableName,Value=orders-plat-prod-audit \
    --start-time 2026-09-04T08:00:00Z --end-time 2026-09-04T10:00:00Z \
    --period 300 --statistics Sum \
    --query 'sort_by(Datapoints,&Timestamp)[?Sum>`0`].[Timestamp,Sum]' \
    --output text

2026-09-04T08:45:00Z    1842.0
2026-09-04T08:50:00Z    9317.0
2026-09-04T08:55:00Z    8804.0
2026-09-04T09:00:00Z    212.0
```

Then find *which key* is hot:

```
$ aws cloudwatch get-metric-data --cli-input-json file://hot-key-query.json \
    --query 'MetricDataResults[0].{Label:Label,Max:max(Values)}' --output json
{
    "Label": "MostAccessedKeys - pk=TENANT#4711",
    "Max": 3021.0
}
```

3 021 > the 3 000 RCU per-partition ceiling. No amount of table-level capacity fixes this; the key must be **write-sharded** (`TENANT#4711#<0..9>`) or the read must go through DAX.

### 10.5 ElastiCache

```
$ aws elasticache describe-replication-groups \
    --replication-group-id orders-plat-prod-sessions \
    --query 'ReplicationGroups[0].{Status:Status,Engine:Engine,
             Shards:length(NodeGroups),MultiAZ:MultiAZ,
             Failover:AutomaticFailover,Encrypted:AtRestEncryptionEnabled,
             TLS:TransitEncryptionEnabled,Endpoint:ConfigurationEndpoint.Address}' \
    --output table

------------------------------------------------------------------------------------
|                            DescribeReplicationGroups                             |
+-------------+--------------------------------------------------------------------+
|  Encrypted  |  True                                                              |
|  Endpoint   |  orders-plat-prod-sessions.abc123.clustercfg.euw1.cache.amazonaws.com|
|  Engine     |  valkey                                                            |
|  Failover   |  enabled                                                           |
|  MultiAZ    |  enabled                                                           |
|  Shards     |  3                                                                 |
|  Status     |  available                                                         |
|  TLS        |  True                                                              |
+-------------+--------------------------------------------------------------------+
```

```
$ redis-cli --tls -h orders-plat-prod-sessions.abc123.clustercfg.euw1.cache.amazonaws.com -p 6379 \
    INFO stats | egrep 'keyspace_hits|keyspace_misses|evicted_keys|expired_keys'
keyspace_hits:884215663
keyspace_misses:19042771
evicted_keys:0
expired_keys:41228390
```

Hit ratio = 884215663 / (884215663 + 19042771) ≈ **97.9 %**. `evicted_keys:0` means memory pressure is not forcing eviction — if that number climbs, the cache is undersized and `maxmemory-policy` is silently deciding what your users lose.

### 10.6 DMS cutover

```
$ aws dms describe-replication-tasks \
    --filters Name=replication-task-id,Values=oracle-to-aurora-orders \
    --query 'ReplicationTasks[0].{Status:Status,Migration:MigrationType,
             Pct:ReplicationTaskStats.FullLoadProgressPercent,
             Tables:ReplicationTaskStats.TablesLoaded,
             Errored:ReplicationTaskStats.TablesErrored,
             LagSec:ReplicationTaskStats.ElapsedTimeMillis}' --output json
{
    "Status": "running",
    "Migration": "full-load-and-cdc",
    "Pct": 100,
    "Tables": 147,
    "Errored": 0,
    "LagSec": 5184000
}
```

```
$ aws dms describe-table-statistics \
    --replication-task-arn arn:aws:dms:eu-west-1:111122223333:task:ORACLE2AURORA \
    --query 'TableStatistics[?ValidationState!=`Validated`].[SchemaName,TableName,
             ValidationState,ValidationFailedRecords]' --output table

-----------------------------------------------------------------------------
|                          DescribeTableStatistics                          |
+----------+----------------+-----------------------+----------------------+
|  orders  |  order_items   |  Mismatched records   |  312                 |
+----------+----------------+-----------------------+----------------------+
```

312 mismatched rows means **do not cut over**. Inspect `awsdms_validation_failures_v1` on the target before anyone declares the migration done:

```
$ psql -h orders-plat-prod.cluster-cxyz123abc.eu-west-1.rds.amazonaws.com -U ordersadmin -d orders \
    -c "SELECT table_name, failure_type, count(*)
        FROM awsdms_validation_failures_v1
        GROUP BY 1,2 ORDER BY 3 DESC LIMIT 5;"

 table_name  |   failure_type    | count
-------------+-------------------+-------
 order_items | RECORD_DIFF       |   298
 order_items | MISSING_TARGET    |    14
(2 rows)
```

`RECORD_DIFF` at this volume on a `NUMBER` → `numeric` mapping is almost always a **precision/scale truncation** introduced by SCT defaults. Fix the target DDL, reload the table, re-validate.

---

## 11. Verification and failure diagnosis

### 11.1 Pre-production acceptance gate

Run every item; a "yes" that was not produced by a command is not a yes.

| # | Assertion | Command | Pass condition |
|---|---|---|---|
| 1 | Cluster members occupy ≥ 3 AZs | `aws rds describe-db-instances --filters Name=db-cluster-id,...` | 3 distinct `AvailabilityZone` values |
| 2 | Storage encrypted with a CMK | `aws rds describe-db-clusters --query 'DBClusters[0].[StorageEncrypted,KmsKeyId]'` | `True` + a customer key ARN, not `alias/aws/rds` |
| 3 | Backup retention ≥ 7 days | same query, `BackupRetentionPeriod` | ≥ 7 (35 for regulated data) |
| 4 | Deletion protection on | `DeletionProtection` | `true` |
| 5 | Not publicly accessible | `aws rds describe-db-instances ... PubliclyAccessible` | `false` on every member |
| 6 | TLS enforced at the engine | `SHOW rds.force_ssl;` | `on` |
| 7 | Failover RTO measured, not assumed | staging failover + the 1 s probe loop in §10.3 | Observed RTO < SLO with margin |
| 8 | PITR restore rehearsed | `aws rds restore-db-cluster-to-point-in-time` into a scratch cluster, then row counts | Counts match the source at the target timestamp |
| 9 | DynamoDB PITR enabled | `aws dynamodb describe-continuous-backups` | `PointInTimeRecoveryStatus: ENABLED` |
| 10 | GSI throttling has its own alarm | `aws cloudwatch describe-alarms --alarm-name-prefix ...` | An alarm dimensioned on `GlobalSecondaryIndexName` exists |

A restore rehearsal that has never been performed is not a backup strategy — it is an untested assertion about a code path that only executes during your worst hour.

### 11.2 Failure diagnosis matrix

| Symptom | Primary signal | Root cause | Remediation |
|---|---|---|---|
| `FATAL: remaining connection slots are reserved` | `DatabaseConnections` at ceiling; app pods in `CrashLoopBackOff` | Connection storm — every pod opens its own pool; `max_connections` scales with instance memory | Put **RDS Proxy** in front; cap per-pod pool size; set `idle_in_transaction_session_timeout` |
| Reads return stale data after a write | `AuroraReplicaLag` > 0 (normal), app reads from the reader endpoint | Reader replication is asynchronous — read-after-write is not guaranteed | Route read-your-own-write traffic to the **writer** endpoint; or use the session's LSN with `pg_wal_lsn_diff` gating |
| Writes fine, reads suddenly 10× slower | `BufferCacheHitRatio` collapses; `ReadIOPS` spikes | A reporting query scanned a large table and evicted the working set | Move analytics to a **custom endpoint** with dedicated readers, or to Redshift |
| App loses the DB for minutes after a failover | Failover event completed in ~20 s but the app recovered in ~300 s | **DNS caching.** JVM `networkaddress.cache.ttl=-1`, or a driver holding dead sockets | Set JVM DNS TTL to 5–10 s; enable driver-level connection validation; use RDS Proxy (it holds the DB side across failover) |
| `ProvisionedThroughputExceededException` at low table utilization | `ThrottledRequests` > 0, `ConsumedWriteCapacityUnits` ≪ provisioned | **Hot partition** — a single PK exceeds 1 000 WCU / 3 000 RCU | Write-shard the key (`PK#<n>`), or add a high-cardinality prefix; verify with CloudWatch Contributor Insights |
| Base-table writes throttled, base capacity idle | `WriteThrottleEvents` on the table, GSI `OnlineIndexThrottleEvents` > 0 | **GSI back-pressure** — the index cannot absorb writes | Scale the GSI independently, or drop unused GSIs |
| Query latency fine, cost 20× the estimate | `ScannedCount ≫ Count` | `FilterExpression` discarding rows **after** they were read and billed | Redesign the key/GSI so the key condition does the filtering |
| `Storage-full` and instance in `storage-full` state | `FreeStorageSpace` → 0 | RDS volume exhausted (Aurora auto-grows; RDS does **not**) | Enable **storage autoscaling** with a max; on Aurora, look for bloat/temp files instead |
| PostgreSQL disk grows with no data growth | `TransactionLogsDiskUsage`, `OldestReplicationSlotLag` climbing | **Orphaned replication slot** (a dead DMS task or logical subscriber) pinning WAL | `SELECT pg_drop_replication_slot('<slot>');` after confirming the consumer is gone |
| Aurora Serverless v2 pinned at max ACU | `ServerlessDatabaseCapacity` == `MaxCapacity` continuously | Scaling cannot reclaim memory held by long-running sessions/temp tables | Raise `MaxCapacity` and fix the query; Serverless v2 scales up fast but down slowly under memory pressure |
| Cache p99 spikes hourly on the hour | `evicted_keys` and DB `ReadIOPS` spike together | **Synchronized TTL expiry** → thundering herd on the origin | Jitter TTLs; add a per-key regeneration lock |
| `SSL error: certificate verify failed` after a Region rollout | Sudden connection failures on new pods only | Missing or stale **RDS CA bundle**; `rds-ca-2019` expired, `rds-ca-rsa2048-g1` required | Mount the global CA bundle; rotate the instance CA in a maintenance window |
| DMS CDC lag climbing without bound | `CDCLatencySource` vs `CDCLatencyTarget` | Source-side: log reader can't keep up. Target-side: missing PK/index makes `UPDATE`/`DELETE` a full scan | Add primary keys on the target; enable `BatchApplyEnabled`; size up the replication instance |

### 11.3 Diagnostic query toolkit

```
-- Aurora PostgreSQL: what is actually running right now, oldest first.
orders=> SELECT pid, now() - query_start AS runtime, state, wait_event_type,
                wait_event, left(query, 80) AS query
         FROM pg_stat_activity
         WHERE state <> 'idle' AND pid <> pg_backend_pid()
         ORDER BY query_start;

  pid  |    runtime      | state  | wait_event_type |   wait_event    |                query
-------+-----------------+--------+-----------------+-----------------+--------------------------------------
 18234 | 00:04:12.881003 | active | IO              | DataFileRead    | SELECT o.*, c.name FROM orders o JOIN
 19011 | 00:00:31.220417 | active | Lock            | transactionid   | UPDATE inventory SET qty = qty - 1 WH
 19044 | 00:00:31.109882 | active | Lock            | transactionid   | UPDATE inventory SET qty = qty - 1 WH
(3 rows)
```

Two sessions waiting on `Lock / transactionid` against the same row is a contention hotspot one step away from a deadlock.

```
-- Top statements by total time — requires pg_stat_statements in
-- shared_preload_libraries (set in the cluster parameter group above).
orders=> SELECT calls,
                round(total_exec_time::numeric, 1)          AS total_ms,
                round(mean_exec_time::numeric, 2)           AS mean_ms,
                round(100 * shared_blks_hit::numeric
                      / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct,
                left(query, 60) AS query
         FROM pg_stat_statements
         ORDER BY total_exec_time DESC LIMIT 5;

  calls   |  total_ms   | mean_ms | hit_pct |                    query
----------+-------------+---------+---------+----------------------------------------------
  1204881 |  8842119.4  |    7.34 |    99.8 | SELECT * FROM orders WHERE customer_id = $1
    31207 |  4410882.1  |  141.34 |    62.1 | SELECT o.*, c.name FROM orders o JOIN custo
      412 |  2201338.9  | 5342.57 |     3.2 | SELECT date_trunc('month', created_at), sum
```

Row 3 — 412 calls, 5.3 s mean, **3.2 % buffer hit ratio** — is the reporting query that belongs in Redshift. It is not slow because the database is undersized; it is slow because it is an OLAP query on an OLTP engine.

```
-- Replication slots: the silent disk-filler.
orders=> SELECT slot_name, plugin, active,
                pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
         FROM pg_replication_slots ORDER BY 4 DESC;

     slot_name      |  plugin  | active | retained_wal
--------------------+----------+--------+--------------
 dms_orders_task_01 | pgoutput | f      | 412 GB
 logical_analytics  | pgoutput | t      | 84 MB
(2 rows)
```

An **inactive** slot retaining 412 GB of WAL is an incident with a countdown timer. Confirm the consumer is truly dead, then drop it.

### 11.4 Metrics that must be on the dashboard

| Service | Metric | Why it matters |
|---|---|---|
| RDS / Aurora | `CPUUtilization`, `DatabaseConnections`, `FreeableMemory` | Saturation |
| | `AuroraReplicaLagMaximum` / `ReplicaLag` | Correctness of read routing |
| | `Deadlocks`, `BufferCacheHitRatio` | Contention and working-set fit |
| | `FreeStorageSpace` (RDS), `VolumeBytesUsed` (Aurora) | Capacity |
| | `ServerlessDatabaseCapacity` | Serverless v2 headroom and cost |
| | `TransactionLogsDiskUsage`, `OldestReplicationSlotLag` | The slot trap |
| DynamoDB | `ThrottledRequests`, `ReadThrottleEvents`, `WriteThrottleEvents` | Capacity and hot keys |
| | `ConsumedRead/WriteCapacityUnits` vs provisioned | Right-sizing |
| | `SuccessfulRequestLatency` (per operation) | Client-visible latency |
| | `UserErrors` vs `SystemErrors` | 4xx (your bug) vs 5xx (AWS) |
| | `AgeOfOldestUnprocessedRecord` (Streams consumers) | Pipeline health |
| ElastiCache | `CacheHitRate`, `Evictions`, `DatabaseMemoryUsagePercentage` | Cache effectiveness and sizing |
| | `CurrConnections`, `ReplicationLag` | Saturation and HA |
| DMS | `CDCLatencySource`, `CDCLatencyTarget`, `FullLoadThroughputRowsTarget` | Cutover readiness |

---

## 12. Exam-focused synthesis

### 12.1 Keyword → service mapping

| Prompt phrase | Answer |
|---|---|
| "relational, joins, complex SQL, existing MySQL/Oracle app" | **Amazon RDS** |
| "MySQL/PostgreSQL-compatible, 5×/3× throughput, cloud-native, 6 copies across 3 AZs" | **Amazon Aurora** |
| "single-digit millisecond, any scale, key-value, serverless, NoSQL" | **Amazon DynamoDB** |
| "microsecond reads for an existing DynamoDB app, no code changes" | **DynamoDB Accelerator (DAX)** |
| "in-memory cache, reduce database load, session store" | **Amazon ElastiCache** |
| "Redis-compatible but must be durable and the primary database" | **Amazon MemoryDB** |
| "MongoDB-compatible, JSON documents" | **Amazon DocumentDB** |
| "highly connected data, relationships, social/fraud/recommendation graph" | **Amazon Neptune** |
| "Apache Cassandra-compatible, CQL, serverless" | **Amazon Keyspaces** |
| "IoT/time-series measurements, trillions of events per day" | **Amazon Timestream** |
| "data warehouse, business intelligence, petabyte-scale analytics" | **Amazon Redshift** |
| "SQL directly on S3, serverless, pay per query" | **Amazon Athena** (not a database service, common distractor) |
| "migrate a database to AWS with minimal downtime" | **AWS DMS** |
| "convert an Oracle schema and stored procedures to PostgreSQL" | **AWS SCT** (then DMS) |
| "connection pooling, many Lambda functions overwhelming the database" | **Amazon RDS Proxy** |
| "immutable, cryptographically verifiable transaction log" | **Amazon QLDB** (retired 2025-07-31 — legacy answer only) |
| "full control of the OS and database engine, custom agents" | **Database on EC2** (or RDS Custom) |

### 12.2 The five most-missed distinctions

1. **Multi-AZ ≠ read replica.** Multi-AZ = synchronous, availability, standby unreadable (instance mode). Read replica = asynchronous, read scaling, readable, promotable.
2. **DAX ≠ ElastiCache.** DAX is DynamoDB-specific and API-transparent; ElastiCache is generic and requires application changes.
3. **Redshift ≠ RDS.** Redshift is OLAP/columnar for analytics; it is not a transactional database and never the answer to "high-volume transactional workload".
4. **`GSI` ≠ `LSI`.** LSI shares the base partition key and can only be created with the table; GSI has its own key, its own capacity, and eventual consistency.
5. **Aurora Serverless v2 ≠ DynamoDB on-demand.** Serverless v2 scales *instance capacity* for a provisioned cluster; DynamoDB on-demand is a *per-request* billing model with no instances at all.

### 12.3 Cost drivers, briefly

| Service | You pay for |
|---|---|
| RDS / Aurora | Instance-hours (or ACU-hours) + storage GB-month + I/O (Aurora Standard only) + backup storage **beyond** the DB size + data transfer |
| DynamoDB | RRU/WRU (on-demand) **or** RCU/WCU-hours (provisioned) + storage GB-month + optional PITR, Streams, Global Tables replication |
| ElastiCache | Node-hours (or ECPU/GB for Serverless) + backup storage |
| Redshift | Node-hours (or RPU-hours) + managed storage + Spectrum bytes scanned |
| DMS | Replication-instance hours (or DCU-hours for Serverless) + storage; **no charge for the target service's ingestion beyond its own rates** |

Two levers with outsized effect: **Reserved Instances / Savings Plans** on steady RDS and Redshift capacity (up to ~69 % versus on-demand), and **Aurora I/O-Optimized** when per-I/O charges exceed roughly 25 % of the cluster bill.

---

## 13. Referencias

**Exam guide**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Shared responsibility**
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/

**Amazon RDS**
- Amazon RDS User Guide — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html
- Multi-AZ deployments — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html
- Multi-AZ DB cluster deployments — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/multi-az-db-clusters-concepts.html
- Working with read replicas — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html
- RDS storage types — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Storage.html
- Backing up and restoring — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_CommonTasks.BackupRestore.html
- Amazon RDS Proxy — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html
- IAM database authentication — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html
- Amazon RDS Custom — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-custom.html

**Amazon Aurora**
- Aurora User Guide — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html
- Aurora storage and reliability — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.StorageReliability.html
- Aurora connection management (endpoints) — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html
- Aurora Serverless v2 — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html
- Aurora Global Database — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html
- Backtracking an Aurora DB cluster — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Managing.Backtrack.html
- Aurora I/O-Optimized — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-storage-type.html
- Aurora DSQL — https://docs.aws.amazon.com/aurora-dsql/latest/userguide/what-is-aurora-dsql.html

**Amazon DynamoDB**
- DynamoDB Developer Guide — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html
- Read/write capacity mode — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadWriteCapacityMode.html
- Partitions and data distribution — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.Partitions.html
- Service quotas — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Limits.html
- Best practices for designing partition keys — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-design.html
- Global tables — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html
- Point-in-time recovery — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/PointInTimeRecovery.html
- DynamoDB Accelerator (DAX) — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DAX.html
- DynamoDB Streams — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html

**In-memory**
- Amazon ElastiCache documentation — https://docs.aws.amazon.com/elasticache/
- Valkey and Redis OSS vs Memcached — https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/SelectEngine.html
- Caching strategies — https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Strategies.html
- Amazon MemoryDB — https://docs.aws.amazon.com/memorydb/latest/devguide/what-is-memorydb.html

**Purpose-built**
- Amazon DocumentDB — https://docs.aws.amazon.com/documentdb/latest/developerguide/what-is.html
- Amazon Neptune — https://docs.aws.amazon.com/neptune/latest/userguide/intro.html
- Amazon Keyspaces (for Apache Cassandra) — https://docs.aws.amazon.com/keyspaces/latest/devguide/what-is-keyspaces.html
- Amazon Timestream — https://docs.aws.amazon.com/timestream/latest/developerguide/what-is-timestream.html
- Amazon Redshift — https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html
- Redshift Serverless — https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-whatis.html
- Amazon QLDB end of support — https://docs.aws.amazon.com/qldb/latest/developerguide/what-is.html

**Migration**
- AWS Database Migration Service User Guide — https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html
- DMS task settings — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TaskSettings.html
- DMS data validation — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Validating.html
- AWS Schema Conversion Tool — https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html

**Automation and observability**
- AWS CloudFormation `AWS::RDS::DBCluster` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-rds-dbcluster.html
- AWS CloudFormation `AWS::DynamoDB::Table` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dynamodb-table.html
- AWS Controllers for Kubernetes (ACK) — https://aws-controllers-k8s.github.io/community/docs/community/overview/
- Monitoring Amazon RDS with CloudWatch — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/monitoring-cloudwatch.html
- Amazon RDS Performance Insights — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.html
- Monitoring DynamoDB with CloudWatch — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/monitoring-cloudwatch.html

**Framework guidance**
- AWS Well-Architected Framework — Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- AWS Well-Architected Framework — Performance Efficiency Pillar — https://docs.aws.amazon.com/wellarchitected/latest/performance-efficiency-pillar/welcome.html
- Purpose-built databases on AWS — https://aws.amazon.com/products/databases/