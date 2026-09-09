# gcp-cdl — Topic 2.2

## Determine which Google Cloud data management products are applicable to different business use cases

**Exam weight: 6.0 · Exam version 2026-08-12**
**Format:** guided exercises. Execute every numbered step, then answer the checkpoint questions before moving on. The answer key is collapsed at the end — do not open it until you have written your own answers.

> **Reference:** [Cloud Digital Leader exam guide (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf), section 2.2.

---

## 0. Lab prerequisites

The CDL exam is a business-decision exam, but a decision you have never seen executed is a decision you cannot defend. Most of what follows runs **for free**: list/describe calls, `--dry-run` validation, and local emulators. Steps that create billable resources are marked **💸 BILLABLE** and every one of them has a teardown step.

### Steps

1. Verify the SDK and your active project:

```bash
gcloud version | head -3
gcloud config list
```

Expected:

```
Google Cloud SDK 5xx.0.0
bq 2.x.x
core 2026.xx.xx

[core]
account = you@example.com
disable_usage_reporting = False
project = cdl-lab-2026
```

2. Export the project once so every later command is copy-pasteable:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
echo "project=$PROJECT_ID region=$REGION"
```

3. Enable only the APIs the free parts of the lab need:

```bash
gcloud services enable storage.googleapis.com bigquery.googleapis.com \
  pubsub.googleapis.com --project="$PROJECT_ID"
```

Expected: `Operation "operations/acat.p2-...-...." finished successfully.`

4. Confirm which of the data services are already reachable in your org (this is a read-only inventory, no resources created):

```bash
gcloud services list --available --project="$PROJECT_ID" \
  --filter="config.name~(sqladmin|spanner|alloydb|bigtableadmin|firestore|redis|datastream|datafusion|dataflow|dataproc|dataplex|datamigration)" \
  --format="table(config.name, config.title)"
```

Expected (abridged):

```
NAME                          TITLE
alloydb.googleapis.com        AlloyDB API
bigtableadmin.googleapis.com  Cloud Bigtable Admin API
datamigration.googleapis.com  Database Migration API
dataflow.googleapis.com       Dataflow API
firestore.googleapis.com      Cloud Firestore API
spanner.googleapis.com        Cloud Spanner API
sqladmin.googleapis.com       Cloud SQL Admin API
```

### Checkpoint 0

- **Q1.** `gcloud services list --available` returned Spanner and AlloyDB even though you have never used them. What does that tell you about cost, and what does it *not* tell you?
- **Q2.** Why does a Cloud Digital Leader need to distinguish *enabling an API* from *provisioning an instance* when talking to a finance stakeholder?

---

## 1. Classify the workload before you name a product

Every 2.2 exam item is the same puzzle in different clothing: a business sentence hides a **workload class**, and the workload class picks the product. Learn the classification, not the catalogue.

The four questions that resolve almost every case:

| Question | If the answer is… | You are in… |
|---|---|---|
| What is the *shape* of the data? | Rows with a fixed schema and relations | Relational (Cloud SQL / AlloyDB / Spanner) |
| | Semi-structured documents, per-entity | Document (Firestore) |
| | Enormous, sparse, key-ordered rows | Wide-column (Bigtable) |
| | Opaque bytes: images, video, backups, logs | Object (Cloud Storage) |
| | POSIX file paths, shared mount | File (Filestore) |
| What is the *access pattern*? | Many small reads/writes, transactional | OLTP |
| | Few huge scans and aggregations | OLAP (BigQuery) |
| | Sub-millisecond lookups of hot values | Cache (Memorystore) |
| What is the *scale ceiling*? | Fits one machine's vertical growth | Cloud SQL / AlloyDB |
| | Must scale writes horizontally, globally | Spanner / Bigtable |
| What is the *operational contract*? | Team wants a managed engine, same SQL | Cloud SQL |
| | Team wants zero capacity planning | BigQuery, Firestore, Cloud Storage |

### Steps

1. Take these six business statements. For each, write down (a) data shape, (b) access pattern, (c) scale ceiling, (d) the product you would name, **before** reading anything else in this document:

   - **S1.** "Our WordPress site and our internal HR app both run MySQL 8 on a VM in a closet. We want backups, failover and patching to stop being my problem."
   - **S2.** "We sell tickets worldwide. At 09:00 in every timezone, a stampede of writes hits the same inventory table. A double-sold seat is a lawsuit."
   - **S3.** "Each of our 400,000 wind turbines emits 20 metrics every second. Engineers query 'turbine X, last 6 hours'."
   - **S4.** "Our mobile app must work on the subway with no signal and re-sync the user's cart when the train surfaces."
   - **S5.** "Marketing wants to join five years of clickstream with the CRM export and get an answer during the meeting. Nobody in marketing can size a cluster."
   - **S6.** "Legal requires we retain scanned contracts for 10 years. We will read them roughly never, but when the auditor asks, we have 48 hours."

2. Now record the *disqualifier* for each — the property of the workload that eliminates the second-best option. (Example for S6: BigQuery is eliminated not by price alone but because a scanned PDF is opaque bytes, not queryable rows.)

3. Keep this sheet. Exercise 9 grades it.

### Checkpoint 1

- **Q3.** Two workloads both say "relational" and "highly available". What single property separates a Cloud SQL answer from a Spanner answer?
- **Q4.** Why is "we have a lot of data" never sufficient to choose Bigtable over BigQuery?
- **Q5.** A stakeholder says "we need a database for our images." Rewrite that requirement correctly and name the product.

---

## 2. Object storage: classes, lifecycle and the cost of being wrong

Cloud Storage is the default landing zone for unstructured data and the substrate under almost every analytics pipeline. The exam tests **storage classes** and **lifecycle**, because that is where money is won or lost.

| Class | Minimum storage duration | Typical storage $/GB-month | Retrieval fee $/GB | Intended use |
|---|---|---|---|---|
| Standard | none | ~0.020 | none | Hot, in-flight, website assets |
| Nearline | 30 days | ~0.010 | ~0.01 | Accessed ≤ once/month |
| Coldline | 90 days | ~0.004 | ~0.02 | Accessed ≤ once/quarter |
| Archive | 365 days | ~0.0012 | ~0.05 | Compliance retention, DR |

> Figures are the published `us-central1` list prices at the time of writing; always re-verify on [Cloud Storage pricing](https://cloud.google.com/storage/pricing). What the exam expects you to know is the *ordering* and the *minimum duration*, not the decimals.
> Classes and their semantics: <https://cloud.google.com/storage/docs/storage-classes>

**The trap the exam loves:** early deletion. Delete or rewrite an Archive object after 20 days and you are still billed for 365 days of storage for it. A "cheap" class applied to churning data is more expensive than Standard.

### Steps

1. Create a bucket with the modern defaults (uniform bucket-level access, no ACL sprawl):

```bash
gcloud storage buckets create "gs://cdl-lab-raw-${PROJECT_ID}" \
  --location="$REGION" \
  --default-storage-class=STANDARD \
  --uniform-bucket-level-access
```

Expected:

```
Creating gs://cdl-lab-raw-cdl-lab-2026/...
```

2. Confirm what you actually got:

```bash
gcloud storage buckets describe "gs://cdl-lab-raw-${PROJECT_ID}" \
  --format="yaml(name,location,locationType,storageClass,iamConfiguration.uniformBucketLevelAccess.enabled)"
```

Expected:

```yaml
iamConfiguration:
  uniformBucketLevelAccess:
    enabled: true
location: US-CENTRAL1
locationType: region
name: cdl-lab-raw-cdl-lab-2026
storageClass: STANDARD
```

3. Upload a token object and inspect its class:

```bash
echo "contract-2026-0001 scanned placeholder" > /tmp/contract.txt
gcloud storage cp /tmp/contract.txt "gs://cdl-lab-raw-${PROJECT_ID}/contracts/2026/contract.txt"
gcloud storage objects describe \
  "gs://cdl-lab-raw-${PROJECT_ID}/contracts/2026/contract.txt" \
  --format="value(storage_class,size,time_created)"
```

Expected:

```
STANDARD	40	2026-09-06T14:22:11+00:00
```

4. Write a lifecycle policy that encodes the retention business rule from **S6** — hot for a month, cheap for a quarter, archived for a decade, deleted at ten years:

```bash
cat > /tmp/lifecycle.json <<'JSON'
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "SetStorageClass", "storageClass": "NEARLINE"},
        "condition": {"age": 30, "matchesPrefix": ["contracts/"]}
      },
      {
        "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
        "condition": {"age": 90, "matchesPrefix": ["contracts/"]}
      },
      {
        "action": {"type": "SetStorageClass", "storageClass": "ARCHIVE"},
        "condition": {"age": 365, "matchesPrefix": ["contracts/"]}
      },
      {
        "action": {"type": "Delete"},
        "condition": {"age": 3650, "matchesPrefix": ["contracts/"]}
      }
    ]
  }
}
JSON

gcloud storage buckets update "gs://cdl-lab-raw-${PROJECT_ID}" \
  --lifecycle-file=/tmp/lifecycle.json
```

Expected:

```
Updating gs://cdl-lab-raw-cdl-lab-2026/...
  Completed 1
```

5. Read the policy back — never trust a write you have not read:

```bash
gcloud storage buckets describe "gs://cdl-lab-raw-${PROJECT_ID}" \
  --format="json(lifecycle_config)" | head -20
```

6. Now consider the *other* answer. When the access pattern is unknown or erratic, the correct product decision is not a hand-written lifecycle — it is **Autoclass**, which moves each object between classes based on its own access history, with no early-deletion charges from the transitions themselves:

```bash
gcloud storage buckets create "gs://cdl-lab-auto-${PROJECT_ID}" \
  --location="$REGION" --uniform-bucket-level-access --enable-autoclass

gcloud storage buckets describe "gs://cdl-lab-auto-${PROJECT_ID}" \
  --format="value(autoclass.enabled,autoclass.toggleTime)"
```

Expected:

```
True	2026-09-06T14:31:02.551000+00:00
```

> Lifecycle reference: <https://cloud.google.com/storage/docs/lifecycle> · Autoclass: <https://cloud.google.com/storage/docs/autoclass>

7. Teardown for this exercise:

```bash
gcloud storage rm --recursive "gs://cdl-lab-raw-${PROJECT_ID}"
gcloud storage rm --recursive "gs://cdl-lab-auto-${PROJECT_ID}"
```

### Checkpoint 2

- **Q6.** A team stores 5 TB of ML training shards in Archive and re-reads the whole set every training run, twice a month. Compute qualitatively what goes wrong and name the two separate charges they are triggering.
- **Q7.** When is Autoclass the *better business answer* than the four-rule lifecycle policy you wrote in step 4, and when is it the worse one?
- **Q8.** A CDL question describes "an on-premises NFS share that 300 analysts mount, with POSIX permissions, that must move to Google Cloud unchanged." Why is Cloud Storage the wrong answer, and what is the right one?
- **Q9.** Multi-region vs. dual-region vs. region for a bucket: which one does a *low-latency single-region compute job* want, and which one does a *global content distribution* workload want?

---

## 3. Relational: Cloud SQL vs. AlloyDB vs. Spanner

All three speak SQL. They differ in **how they scale** and **what they guarantee**, and that is the whole exam question.

| | Cloud SQL | AlloyDB for PostgreSQL | Spanner |
|---|---|---|---|
| Engines | MySQL, PostgreSQL, SQL Server | PostgreSQL-compatible | GoogleSQL + PostgreSQL interface |
| Scaling model | Vertical (bigger machine) + read replicas | Vertical + read pools; columnar engine for analytics | **Horizontal**, transparently sharded |
| Writes | Single primary | Single primary | Multi-region, globally distributed |
| Consistency | Strong within instance | Strong within instance | **External consistency** across regions |
| Availability SLA | 99.95% (HA config) | 99.99% | 99.99% regional / **99.999%** multi-region |
| Lift-and-shift of an existing app? | Yes, the point of it | Yes, for demanding PostgreSQL | Usually requires design work |
| Typical trigger phrase | "managed MySQL", "stop patching" | "Postgres, but 4× faster HTOP + HTAP" | "global", "unlimited scale", "never goes down" |

> <https://cloud.google.com/sql/docs/introduction> · <https://cloud.google.com/alloydb/docs/overview> · <https://cloud.google.com/spanner/docs/overview>

### Steps

1. Inspect what "vertical scaling" concretely means — list the machine tiers Cloud SQL will sell you:

```bash
gcloud sql tiers list --format="table(tier, RAM, Disk, region.list())" | head -15
```

Expected (abridged):

```
TIER                 RAM         DISK              REGION
db-f1-micro          644245094   3758096384        us-central1,europe-west1,...
db-g1-small          1becomes... 
db-custom-1-3840     4026531840  10737418240       us-central1,...
db-custom-8-30720    32212254720 10737418240       us-central1,...
```

The list *ends*. That ceiling is the architectural fact behind "Cloud SQL scales vertically."

2. Now look at Spanner's units. Spanner does not sell you a machine; it sells **compute capacity** in nodes / processing units, and the placement is a *configuration*, not a zone:

```bash
gcloud spanner instance-configs list \
  --format="table(name.basename(), displayName, replicas.len())" | head -12
```

Expected (abridged):

```
NAME                     DISPLAY_NAME                       REPLICAS
regional-us-central1     us-central1                        3
nam3                     United States (northern Virginia/South Carolina)  5
nam-eur-asia1            Global: Americas, Europe, Asia     7
eur6                     Europe (Belgium/Netherlands)       5
```

Read the replica counts. **That column is the 99.999% SLA.** A multi-region config keeps a synchronous quorum across regions; the price of that quorum is commit latency, and the benefit is that losing a region loses nothing.

3. **💸 BILLABLE (optional, ~$0.03/hour, delete within the hour).** If you want to see an HA relational instance exist, create the smallest one:

```bash
gcloud sql instances create cdl-lab-pg \
  --database-version=POSTGRES_16 \
  --tier=db-g1-small \
  --region="$REGION" \
  --availability-type=REGIONAL \
  --storage-auto-increase \
  --backup-start-time=03:00
```

Expected (takes 4–8 minutes):

```
Creating Cloud SQL instance for POSTGRES_16...done.
Created [https://sqladmin.googleapis.com/sql/v1beta4/projects/cdl-lab-2026/instances/cdl-lab-pg].
NAME         DATABASE_VERSION  LOCATION       TIER          PRIMARY_ADDRESS  STATUS
cdl-lab-pg   POSTGRES_16       us-central1-a  db-g1-small   34.28.x.x        RUNNABLE
```

4. Verify that "regional availability" is a real, inspectable property and not a marketing word:

```bash
gcloud sql instances describe cdl-lab-pg \
  --format="value(settings.availabilityType, gceZone, secondaryGceZone, settings.backupConfiguration.enabled)"
```

Expected:

```
REGIONAL	us-central1-a	us-central1-c	True
```

A **synchronous standby in a second zone** is what the 99.95% SLA buys. Note what it is *not*: it is not a second region, and it is not additional read capacity — the standby serves no traffic.

5. Teardown immediately:

```bash
gcloud sql instances delete cdl-lab-pg --quiet
```

6. Free alternative to step 3–5 — run the **Spanner emulator** and see the horizontal model's API without paying for a node:

```bash
gcloud emulators spanner start &
sleep 5
gcloud config configurations create spanner-emu 2>/dev/null || gcloud config configurations activate spanner-emu
gcloud config set auth/disable_credentials true
gcloud config set project "$PROJECT_ID"
gcloud config set api_endpoint_overrides/spanner http://localhost:9020/

gcloud spanner instances create cdl-emu --config=emulator-config \
  --description="CDL lab" --nodes=1
gcloud spanner databases create inventory --instance=cdl-emu \
  --ddl="CREATE TABLE Seats (EventId STRING(36) NOT NULL, SeatId STRING(16) NOT NULL, SoldTo STRING(64)) PRIMARY KEY (EventId, SeatId)"
gcloud spanner databases ddl describe inventory --instance=cdl-emu
```

Expected:

```
CREATE TABLE Seats (
  EventId STRING(36) NOT NULL,
  SeatId STRING(16) NOT NULL,
  SoldTo STRING(64),
) PRIMARY KEY(EventId, SeatId);
```

Then restore your normal config:

```bash
gcloud config configurations activate default
```

> Spanner emulator: <https://cloud.google.com/spanner/docs/emulator>

### Checkpoint 3

- **Q10.** In step 4, `availabilityType=REGIONAL` gave you a standby in `us-central1-c`. A stakeholder asks: "so we survive a region outage?" Answer precisely, and say which product changes the answer.
- **Q11.** The ticketing company (S2) is currently on a single large PostgreSQL instance and is hitting write saturation. Rank Cloud SQL read replicas, AlloyDB, and Spanner as candidate answers, and state what makes each one wrong or right *for writes specifically*.
- **Q12.** A customer wants PostgreSQL, needs 4× transactional throughput and also wants to run analytical queries on the same live data without an ETL to BigQuery. Which product, and what is the specific feature that satisfies the second half of the sentence?
- **Q13.** Why does "we want to migrate our Oracle database with minimal code changes" *not* lead to Spanner in a CDL answer, and what two products are the realistic candidates?

---

## 4. Non-relational: Firestore, Bigtable, Memorystore

### Steps

1. **Bigtable** — the model is a sorted, sparse, wide-column map. The row key *is* the query plan. Start the emulator and build the turbine telemetry table from **S3**:

```bash
gcloud beta emulators bigtable start --host-port=localhost:8086 &
sleep 3
export BIGTABLE_EMULATOR_HOST=localhost:8086

cbt -project "$PROJECT_ID" -instance cdl-emu createtable telemetry families=metrics
cbt -project "$PROJECT_ID" -instance cdl-emu ls
```

Expected:

```
telemetry
```

2. Write two rows using a **reversed-timestamp, entity-prefixed** key — the canonical time-series design — and read back a range:

```bash
cbt -project "$PROJECT_ID" -instance cdl-emu set telemetry \
  "turbine-000042#20260906T140000" metrics:rpm=17.4 metrics:temp_c=41.2
cbt -project "$PROJECT_ID" -instance cdl-emu set telemetry \
  "turbine-000042#20260906T140001" metrics:rpm=17.6 metrics:temp_c=41.3

cbt -project "$PROJECT_ID" -instance cdl-emu read telemetry \
  prefix="turbine-000042#202609061400"
```

Expected:

```
----------------------------------------
turbine-000042#20260906T140000
  metrics:rpm                              @ 2026/09/06-14:03:11.000000
    "17.4"
  metrics:temp_c                           @ 2026/09/06-14:03:11.000000
    "41.2"
----------------------------------------
turbine-000042#20260906T140001
  metrics:rpm                              @ 2026/09/06-14:03:11.000000
    "17.6"
...
```

Notice what you did **not** do: no `JOIN`, no secondary index, no aggregation. You asked for a contiguous key range. That is the entire Bigtable access model, and it is why Bigtable is right for S3 and wrong for marketing's ad-hoc joins (S5).

3. Unset the emulator variable so later steps do not silently hit it:

```bash
unset BIGTABLE_EMULATOR_HOST
```

4. **Firestore** — document model, per-user documents, and the property that decides S4: **offline persistence with automatic sync**. Inspect the two modes:

```bash
gcloud firestore databases list --format="table(name.basename(), type, locationId, concurrencyMode)" 2>/dev/null \
  || echo "No Firestore database provisioned in this project"
```

Expected, once one exists:

```
NAME       TYPE                LOCATION_ID   CONCURRENCY_MODE
(default)  FIRESTORE_NATIVE    nam5          PESSIMISTIC
```

`FIRESTORE_NATIVE` is the mode that offers mobile/web SDKs, real-time listeners and offline caching; `DATASTORE_MODE` is the server-side, App Engine-lineage mode without them. For S4, only Native mode answers the requirement.

> <https://cloud.google.com/firestore/docs> · mode comparison: <https://cloud.google.com/datastore/docs/firestore-or-datastore>

5. **Memorystore** — not a system of record. It is a managed Redis/Valkey/Memcached in front of one. Inspect what the service sells:

```bash
gcloud redis regions list --format="value(locationId)" | head -5
gcloud redis instances list --region="$REGION" --format="table(name, tier, memorySizeGb, state)"
```

Expected (empty list is the correct output if you have provisioned nothing):

```
us-central1
us-east1
...
Listed 0 items.
```

The exam-relevant fact: `BASIC` tier has **no replica and no failover** — a cache whose loss is acceptable; `STANDARD_HA` adds a replica and automatic failover. Choosing `BASIC` for session state that must survive is a design error.

> <https://cloud.google.com/memorystore/docs/redis/redis-tiers>

### Checkpoint 4

- **Q14.** Rewrite the S3 row key `turbine-000042#20260906T140000` as `20260906T140000#turbine-000042` and explain, in operational terms, what happens to a fleet of writers at 14:00:01.
- **Q15.** A team proposes Bigtable to store 400 GB of product catalogue data that the web store queries by any of 12 attributes. Reject the proposal in one sentence and name a better product.
- **Q16.** Firestore Native vs. Datastore mode: which single business requirement in S4 makes the choice non-negotiable?
- **Q17.** A retailer puts the shopping cart in Memorystore `BASIC` to reduce Cloud SQL load. Describe the business incident that follows a node maintenance event, and the two-word fix.

---

## 5. Analytics: BigQuery, and the economics of a scan

BigQuery is serverless, columnar, and separates storage from compute. For CDL, three consequences matter: **nobody sizes a cluster**, **you pay for bytes scanned (on-demand) or for reserved slots (editions)**, and **schema design changes the bill by orders of magnitude**.

> <https://cloud.google.com/bigquery/docs/introduction> · <https://cloud.google.com/bigquery/pricing>

### Steps

1. Query a public dataset with **zero setup** — this is the "no cluster to size" claim, made concrete:

```bash
bq query --use_legacy_sql=false --max_rows=5 \
'SELECT starttime, tripduration, start_station_name
 FROM `bigquery-public-data.new_york_citibike.citibike_trips`
 WHERE tripduration IS NOT NULL
 ORDER BY starttime DESC
 LIMIT 5'
```

Expected:

```
+---------------------+--------------+--------------------------------+
|      starttime      | tripduration |       start_station_name       |
+---------------------+--------------+--------------------------------+
| 2018-05-31 23:59:56 |          301 | E 33 St & 1 Ave                |
| ...                                                                 |
+---------------------+--------------+--------------------------------+
```

2. Now the part the exam actually cares about. **Estimate cost before spending it** with `--dry_run`:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT COUNT(*) FROM `bigquery-public-data.new_york_citibike.citibike_trips`'
```

Expected:

```
Query successfully validated. Assuming the tables are not modified, running this
query will process 0 bytes of data.
```

Then compare against a query that touches real columns:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT start_station_name, AVG(tripduration)
 FROM `bigquery-public-data.new_york_citibike.citibike_trips`
 GROUP BY start_station_name'
```

Expected (your figure will differ):

```
Query successfully validated. Assuming the tables are not modified, running this
query will process 1246953984 bytes of data.
```

3. **Columnar storage, demonstrated.** Add one more column to the same query and re-run the dry run:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT start_station_name, usertype, AVG(tripduration)
 FROM `bigquery-public-data.new_york_citibike.citibike_trips`
 GROUP BY start_station_name, usertype'
```

The byte count rises by roughly the size of one column. In a row store it would not have moved. `SELECT *` is therefore not a style preference in BigQuery — it is a line item.

4. **Partitioning, demonstrated.** Public partitioned tables often *require* a partition filter, precisely to stop the accident you are about to see:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT SUM(views) FROM `bigquery-public-data.wikipedia.pageviews_2021`'
```

Expected — this is the guardrail firing, not a failure on your part:

```
Error in query string: Cannot query over table
'bigquery-public-data.wikipedia.pageviews_2021' without a filter over column(s)
'datehour' that can be used for partition elimination
```

Now supply the filter:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT SUM(views) FROM `bigquery-public-data.wikipedia.pageviews_2021`
 WHERE datehour BETWEEN "2021-03-01" AND "2021-03-02"'
```

Expected: a byte count several orders of magnitude smaller than the full table.

5. Convert bytes to money. On-demand pricing is billed per TiB scanned (list price ≈ **$6.25/TiB** in US regions, with the first 1 TiB per month free — re-verify on the pricing page):

```bash
BYTES=1246953984
python3 -c "b=$BYTES; print(f'{b/2**40:.6f} TiB  ->  \${b/2**40*6.25:.4f}')"
```

Expected:

```
0.001134 TiB  ->  $0.0071
```

6. Inspect table metadata to see storage and row counts without scanning anything:

```bash
bq show --format=prettyjson \
  bigquery-public-data:new_york_citibike.citibike_trips \
  | grep -E '"numBytes"|"numRows"|"type"'
```

Expected:

```
  "numBytes": "7217426947",
  "numRows": "58937715",
  "type": "TABLE"
```

7. Understand the second pricing model, because the exam contrasts them. **On-demand** = pay per byte scanned, no commitment, unpredictable monthly total. **BigQuery editions** (Standard / Enterprise / Enterprise Plus) = buy **slots** (compute capacity) with autoscaling and optional commitments, giving a predictable bill and workload isolation. List any reservations in the project:

```bash
bq ls --reservation --location="US" --project_id="$PROJECT_ID" 2>&1 | head -5
```

Expected in a fresh project:

```
No reservations found.
```

> <https://cloud.google.com/bigquery/docs/reservations-intro>

### Checkpoint 5

- **Q18.** Marketing (S5) runs 40 exploratory queries a day, each scanning 2 TiB, and the CFO wants a predictable monthly number. On-demand or editions? Justify with the mechanism, not the price.
- **Q19.** A team reports "BigQuery got expensive after we added the raw JSON payload column." Explain the causal chain in terms of columnar storage, and give two mitigations.
- **Q20.** In step 2, `SELECT COUNT(*)` processed **0 bytes**. What does that reveal about BigQuery's architecture, and why is it a poor benchmark of "BigQuery is cheap"?
- **Q21.** The company already keeps 300 TB of Parquet in Cloud Storage and does not want to load it into BigQuery storage. Name the capability that lets BigQuery query it in place, and state the trade-off.

---

## 6. Getting data in: Pub/Sub, Dataflow, Dataproc, Datastream, Data Fusion, Composer

A product decision here is a decision about **who writes the code** and **what shape the data arrives in**.

| Need | Product | Decisive trait |
|---|---|---|
| Decouple producers from consumers; absorb spikes | **Pub/Sub** | Global, serverless messaging; at-least-once delivery, retention |
| One pipeline for both streaming and batch, autoscaled | **Dataflow** | Managed Apache Beam; unified batch+stream, no cluster |
| We already have Spark/Hadoop jobs and Spark skills | **Dataproc** | Managed Spark/Hadoop; lift-and-shift of existing jobs |
| Replicate a live OLTP database into BigQuery continuously | **Datastream** | Serverless CDC (change data capture), low impact on source |
| Analysts must build ETL without writing code | **Cloud Data Fusion** | Graphical pipeline builder (CDAP) |
| Orchestrate a DAG of interdependent jobs on a schedule | **Cloud Composer** | Managed Apache Airflow |
| Query files in Cloud Storage as if they were tables | **BigLake / external tables** | Storage stays put, one governance model |
| Catalogue, classify and govern data across the estate | **Dataplex** | Unified metadata, data quality, lineage |

> <https://cloud.google.com/pubsub/docs/overview> · <https://cloud.google.com/dataflow/docs> · <https://cloud.google.com/dataproc/docs> · <https://cloud.google.com/datastream/docs/overview> · <https://cloud.google.com/data-fusion/docs> · <https://cloud.google.com/composer/docs> · <https://cloud.google.com/dataplex/docs>

### Steps

1. Build the decoupling layer for the turbine fleet — this is free at lab volume:

```bash
gcloud pubsub topics create turbine-telemetry
gcloud pubsub subscriptions create turbine-telemetry-archive \
  --topic=turbine-telemetry \
  --message-retention-duration=7d \
  --ack-deadline=30
```

Expected:

```
Created topic [projects/cdl-lab-2026/topics/turbine-telemetry].
Created subscription [projects/cdl-lab-2026/subscriptions/turbine-telemetry-archive].
```

2. Publish and pull, to see the buffering semantics with your own eyes:

```bash
gcloud pubsub topics publish turbine-telemetry \
  --message='{"turbine":"000042","rpm":17.4,"temp_c":41.2}' \
  --attribute=site=patagonia-3

gcloud pubsub subscriptions pull turbine-telemetry-archive --auto-ack --limit=1 \
  --format="table(message.data.decode(base64), message.attributes)"
```

Expected:

```
DATA                                                  ATTRIBUTES
{"turbine":"000042","rpm":17.4,"temp_c":41.2}         {'site': 'patagonia-3'}
```

3. Observe the property that makes Pub/Sub the shock absorber. Check the backlog metric that operations teams alert on:

```bash
gcloud pubsub subscriptions describe turbine-telemetry-archive \
  --format="value(messageRetentionDuration, ackDeadlineSeconds, expirationPolicy.ttl)"
```

Expected:

```
604800s	30	2678400s
```

Seven days of retention is the business answer to "what happens if the analytics pipeline is down for a weekend?" — nothing is lost, the backlog drains afterwards.

4. Inspect the Dataflow catalogue of Google-provided templates. The exam-relevant point is that the reference streaming path (Pub/Sub → BigQuery) requires **no code at all**:

```bash
gcloud dataflow jobs list --region="$REGION" --format="table(name,type,state)" 2>/dev/null
gcloud storage ls gs://dataflow-templates-"$REGION"/latest/ | grep -i -E "PubSub_to_BigQuery|GCS_Text_to_BigQuery" 
```

Expected:

```
gs://dataflow-templates-us-central1/latest/PubSub_to_BigQuery
gs://dataflow-templates-us-central1/latest/GCS_Text_to_BigQuery
```

5. Teardown:

```bash
gcloud pubsub subscriptions delete turbine-telemetry-archive --quiet
gcloud pubsub topics delete turbine-telemetry --quiet
```

### Checkpoint 6

- **Q22.** A retailer's existing nightly ETL is 4,000 lines of PySpark maintained by a team of Spark engineers. The mandate is "move to the cloud in one quarter." Dataflow or Dataproc? Give the business reason, then name the condition under which the other answer becomes correct.
- **Q23.** The finance team needs their operational Cloud SQL for PostgreSQL data available in BigQuery within minutes, and the DBA refuses anything that adds load to the primary. Name the product and the technique it uses.
- **Q24.** Why is Pub/Sub, not Dataflow, the answer to "our ingestion API falls over during flash sales"?
- **Q25.** A company has 60 data sources, three business units, and nobody can say which tables contain personal data. Name the product for the catalogue/governance problem, and the *separate* product for finding the personal data itself.

---

## 7. Migration: the bandwidth arithmetic that picks the product

The exam gives you a data volume, a time window and sometimes a link speed. There is a calculation behind the "right" answer.

| Situation | Product |
|---|---|
| Data already in another cloud or in an on-prem bucket/HTTP endpoint, network is adequate | **Storage Transfer Service** |
| Volume too large for the available link, or no usable link | **Transfer Appliance** (TA40 ≈ 40 TB, TA300 ≈ 300 TB usable) |
| Live database → managed database, minimal downtime | **Database Migration Service** |
| Continuous change replication into analytics | **Datastream** |
| Ongoing hybrid file access | **Filestore** / **Storage Transfer Service for on-prem** |

> <https://cloud.google.com/storage-transfer/docs/overview> · <https://cloud.google.com/transfer-appliance/docs> · <https://cloud.google.com/database-migration/docs>

### Steps

1. Do the arithmetic yourself. Save this helper:

```bash
cat > /tmp/transfer_time.py <<'PY'
import sys
tb, mbps = float(sys.argv[1]), float(sys.argv[2])
bytes_total = tb * 10**12
bytes_per_sec = mbps * 10**6 / 8
days = bytes_total / bytes_per_sec / 86400
print(f"{tb:g} TB over {mbps:g} Mbps (100% utilised) = {days:.1f} days")
print(f"realistic at 70% utilisation           = {days/0.7:.1f} days")
PY
```

2. Run the three cases the exam repeats:

```bash
python3 /tmp/transfer_time.py 10 100
python3 /tmp/transfer_time.py 100 1000
python3 /tmp/transfer_time.py 500 100
```

Expected:

```
10 TB over 100 Mbps (100% utilised) = 9.3 days
realistic at 70% utilisation           = 13.2 days

100 TB over 1000 Mbps (100% utilised) = 9.3 days
realistic at 70% utilisation           = 13.2 days

500 TB over 100 Mbps (100% utilised) = 463.0 days
realistic at 70% utilisation           = 661.4 days
```

The third line is the exam's Transfer Appliance question. When the honest estimate exceeds the business deadline — and, critically, when saturating the link would starve the production business — the answer is physical shipment.

3. Create a (free to define) Storage Transfer Service job description for the case where the network *is* adequate. List the service's job inventory first:

```bash
gcloud transfer jobs list --format="table(name.basename(), status, transferSpec.gcsDataSink.bucketName)" 2>&1 | head -5
```

Expected in a fresh project:

```
Listed 0 items.
```

4. Read the DMS decision, without provisioning it. DMS performs an initial full dump plus **continuous replication**, and you cut over when replication lag is near zero — that is what "minimal downtime migration" means concretely:

```bash
gcloud database-migration connection-profiles list --region="$REGION" \
  --format="table(name.basename(), provider, state)" 2>&1 | head -5
```

Expected:

```
Listed 0 items.
```

### Checkpoint 7

- **Q26.** A media company must move 900 TB of archive footage; their internet link is 500 Mbps and is also the link their 400 employees use. Compute the naive transfer time, then give the recommendation *and* the second-order reason that the arithmetic alone does not capture.
- **Q27.** A bank migrates a 2 TB MySQL database and can afford 15 minutes of downtime. Which product, and what is the *sequence* of events at cutover?
- **Q28.** What is the difference in intent between Storage Transfer Service and Datastream, given that both "move data continuously"?

---

## 8. Capstone: map eight business statements to products

### Steps

1. For each statement, write **one product** (or a minimal chain, e.g. `Pub/Sub → Dataflow → BigQuery`) plus **one sentence** naming the decisive property.

   - **C1.** "A global gaming leaderboard: 50 M players, writes from every continent, must never show a stale rank or lose a score."
   - **C2.** "Ten years of MRI images, opened only during litigation, retrieved within a day."
   - **C3.** "A hospital's legacy Java app on SQL Server 2019 must leave the datacenter this year; the vendor will not change a line of code."
   - **C4.** "Ad-tech: 4 million events/second of impression logs, queried by `advertiser_id` and time range for real-time bidding."
   - **C5.** "A retail BI team wants one governed definition of 'net revenue' that Sheets, Looker Studio and a Slack bot all read."
   - **C6.** "Session state for a web fleet: microsecond reads, rebuildable from the database if lost."
   - **C7.** "A logistics startup needs a mobile app where drivers update delivery status in tunnels and it syncs when they emerge."
   - **C8.** "Compliance requires we discover and mask credit-card numbers accidentally written into support-ticket exports before analysts see them."

2. For each, also write the **strongest wrong answer** and the sentence that eliminates it. If you cannot name a plausible wrong answer, you have not understood the trade-off.

3. Return to your Exercise 1 sheet (S1–S6) and grade it against the answer key.

### Checkpoint 8

- **Q29.** Across C1–C8, which two statements would change product if you added the constraint "the team has no data engineers and no budget for capacity planning"? Explain.
- **Q30.** Write the one-paragraph justification you would give a non-technical CFO for choosing Spanner over Cloud SQL for C1, using cost of failure rather than feature lists.

---

<details>
<summary><strong>Answer key — open only after writing your own answers</strong></summary>

### Checkpoint 0

**Q1.** It tells you that **enabling and listing APIs costs nothing** — Google Cloud bills for provisioned resources and consumed operations, not for the availability of a service in the catalogue. It does *not* tell you that you are permitted to use them (Organization Policy or IAM may block provisioning), nor that your project has quota, nor that anything is running. `--available` is a catalogue listing; `gcloud services list --enabled` is what is switched on in this project.

**Q2.** Because a finance stakeholder's mental model of "we turned on Spanner" is "we started paying for Spanner." Enabling an API creates no charge; a Spanner instance with one node in a multi-region config is a four-figure monthly commitment from the moment it exists. The CDL role is precisely to keep those two facts separate in the conversation — and to point out that the meaningful cost control is not "don't enable APIs" but budgets, quotas, Organization Policy constraints on resource location/size, and labels for cost attribution.

### Checkpoint 1

**Q3.** **Whether writes must scale horizontally beyond one primary, or the data must be strongly consistent across regions.** Cloud SQL (and AlloyDB) has exactly one write primary; you scale it by making the machine bigger and adding read replicas. Spanner shards writes across nodes and maintains external consistency across regions. "Highly available" alone is satisfied by Cloud SQL's regional HA; "globally consistent writes at unbounded scale" is not.

**Q4.** Because volume is not an access pattern. Bigtable is chosen when the queries are **key-range lookups at low latency and very high write throughput** — a known entity, a time slice. BigQuery is chosen when the queries are **ad-hoc scans, joins and aggregations over the whole corpus**. A petabyte queried by analysts with arbitrary SQL is BigQuery; a terabyte hammered by a bidding engine at 4 M writes/second on a known key is Bigtable. Many architectures use both: Bigtable for the serving path, BigQuery for the analytical path.

**Q5.** "We need durable, cheap, scalable storage for image *files*, with metadata about those images stored somewhere queryable." The images go to **Cloud Storage**; the metadata (owner, tags, dimensions, storage URI) goes to a database — Firestore or Cloud SQL depending on the query pattern. Storing binary blobs in a relational database is the anti-pattern being tested.

### Checkpoint 2

**Q6.** Two separate charges, both avoidable:
1. **Retrieval fees.** Archive retrieval is ~$0.05/GB. 5 TB × 2 per month ≈ 10,000 GB × $0.05 = **~$500/month in retrieval alone**, against a storage saving of roughly (0.020 − 0.0012) × 5,000 ≈ $94/month. The "cheap" class costs them ~5× what Standard would.
2. **Early-deletion charges**, if training shards are rewritten or replaced before 365 days: each object is still billed for the remainder of its 365-day minimum.
The rule: cold classes are for data you *store* often and *read* rarely. Read frequency, not size, picks the class.

**Q7.** Autoclass is better when the access pattern is **unknown, per-object, or drifting** — a data lake where some objects go cold in a week and others stay hot for a year, and no human can write a correct age rule. It removes the early-deletion penalty risk from transitions and the "we set Coldline and then had to re-read everything" failure. It is worse when the pattern is **known and deterministic** (regulatory retention, as in step 4) — there, an explicit lifecycle rule reaches the cheapest class immediately and predictably, whereas Autoclass charges a small per-object management fee and only demotes after an observed idle period. Known rule → lifecycle. Unknown behaviour → Autoclass.

**Q8.** Cloud Storage is an **object store**: flat namespace, no POSIX semantics, no file locking, no partial in-place writes, no `mount` that behaves like NFS (Cloud Storage FUSE approximates it but does not provide POSIX guarantees or the performance profile). The requirement says "mount, POSIX permissions, unchanged." The answer is **Filestore** — managed NFS. See <https://cloud.google.com/filestore/docs/overview>.

**Q9.** A single-region compute job wants a **regional** bucket in the *same region as the compute*: lowest latency, highest throughput, no cross-region egress. Global content distribution wants **multi-region** (highest availability, data served from the continent-wide footprint, typically fronted by Cloud CDN). **Dual-region** is the middle case: two named regions with predictable low latency to both, chosen when you need regional performance *and* geographic redundancy for DR — the usual answer to "we must survive losing a region but our compute is in one of them."

### Checkpoint 3

**Q10.** No. `REGIONAL` availability means a **synchronous standby in a second zone of the same region**; it survives a zone failure with automatic failover, not a region failure. Surviving a region failure with Cloud SQL requires a **cross-region read replica** that you promote manually (an RPO/RTO measured in minutes, with data loss possible because replication is asynchronous). The product that changes the answer to "yes, automatically, with no data loss" is **Spanner in a multi-region configuration**, where the synchronous quorum spans regions — the `nam3`/`nam-eur-asia1` configs you listed in step 2.

**Q11.**
- **Cloud SQL read replicas — wrong.** Replicas serve reads. The stated saturation is on *writes*; adding replicas adds replication load to the primary and solves nothing.
- **AlloyDB — right if the write volume fits one primary.** It materially raises the ceiling (a faster primary, better write path, read pools that offload reporting) while staying PostgreSQL-compatible, so the application changes little. This is the correct first move if the growth curve is 2–5×, not 100×.
- **Spanner — right if writes must scale without a ceiling, or must be globally consistent.** The stampede in S2 is exactly the profile: concurrent writes to hot inventory rows from every region, and a correctness requirement ("double-sold seat is a lawsuit") that demands external consistency. The cost is migration effort and schema design (interleaving, avoiding hotspots).
The exam's tiebreaker is usually the phrase "global" or "unlimited scale."

**Q12.** **AlloyDB for PostgreSQL.** The second half — analytics on live transactional data without ETL — is satisfied by its **columnar engine**, which keeps a columnar representation of hot data in memory alongside the row store, so analytical queries run against the operational database (HTAP). See <https://cloud.google.com/alloydb/docs/columnar-engine/about>.

**Q13.** Because Spanner is not Oracle-compatible; moving to it is a **re-architecture**, which contradicts "minimal code changes." The realistic candidates are **Cloud SQL for SQL Server / PostgreSQL** or **Bare Metal Solution for Oracle** (running Oracle itself on dedicated hardware adjacent to Google Cloud) when the licence and the code must stay untouched; if some conversion is acceptable, **DMS with Oracle→PostgreSQL conversion** into Cloud SQL or AlloyDB. See <https://cloud.google.com/bare-metal/docs> and <https://cloud.google.com/database-migration/docs/oracle-to-postgresql>.

### Checkpoint 4

**Q14.** You create a **hotspot**. Bigtable stores rows in lexicographic key order and splits that keyspace into contiguous tablets served by individual nodes. With the timestamp first, every writer in the fleet at 14:00:01 produces keys sharing the same prefix, so all 400,000 writes per second land in one tablet on **one node**, while the rest of the cluster idles. Throughput collapses to single-node throughput and latency spikes. Putting the entity identifier first distributes writes across the keyspace; the trailing timestamp still gives you cheap `prefix=turbine-X` time-range scans. This is the single most important Bigtable design rule: <https://cloud.google.com/bigtable/docs/schema-design>.

**Q15.** Bigtable has no efficient query path other than the row key (and row-key prefix/range), so serving 12 arbitrary attribute filters would require 12 denormalised copies of the table — use **Firestore** (automatic indexing on document fields, ideal for a catalogue of this size), or Cloud SQL if the catalogue is genuinely relational and joins are needed.

**Q16.** "Must work on the subway with no signal and re-sync when the train surfaces." **Offline persistence with automatic conflict-resolving synchronisation and real-time listeners** exists only in Firestore **Native mode**, via the mobile/web client SDKs. Datastore mode is a server-side API with no client SDKs and no offline support.

**Q17.** Memorystore `BASIC` has a single node and **no replica and no automatic failover**; a maintenance event or node failure means the instance restarts empty. Every customer's shopping cart is lost mid-session at once — abandoned carts, support calls, direct revenue loss. Worse, the cart was being used as a *system of record*, not a cache, so there is nothing to rebuild from. The two-word fix is **`STANDARD_HA`** (replica + automatic failover); the architectural fix is to keep the durable cart in a database and treat Memorystore as a cache in front of it. See <https://cloud.google.com/memorystore/docs/redis/redis-tiers>.

### Checkpoint 5

**Q18.** **Editions with a slot commitment (Enterprise, plus autoscaling).** The mechanism: on-demand bills per byte scanned, so the monthly total is a function of analyst behaviour — an exploratory team that discovers `SELECT *` can multiply the bill without any change in business value, and the CFO cannot forecast it. Editions bill for **capacity (slots) over time**; a baseline commitment plus an autoscaling ceiling converts an unbounded variable cost into a bounded one, and adds workload isolation so marketing's exploration cannot slow the finance close. The secondary control, valid in either model, is **custom quotas** on bytes billed per user/project.

**Q19.** BigQuery stores each column separately, and you are billed for the bytes of the **columns your query touches**. A raw JSON payload column is large, poorly compressible, and — critically — gets pulled in by every `SELECT *`, so queries that never needed it now scan it. Mitigations: (1) stop using `SELECT *`; select named columns. (2) Move the raw payload to a separate table (or to Cloud Storage with an external/BigLake table) joined only when needed. (3) Parse the JSON into typed columns at ingest, or use the native `JSON` type so BigQuery can prune sub-fields. (4) Add **partitioning** (usually by ingestion date) and **clustering** on the common filter columns, and consider `require_partition_filter = true`. (5) Switch to editions if the workload is steady, so scan volume stops being the billing unit.

**Q20.** `COUNT(*)` is answered from **table metadata**, not from data: BigQuery keeps row counts in its metastore, so no columns are read and no bytes are billed. It reveals the storage/metadata separation — and it is a poor benchmark precisely because it exercises none of the scan path. Any cost or performance claim must be made with a query that reads real columns. (The same caution applies to cached query results, which are also free and can make a repeated query look impossibly cheap.)

**Q21.** **BigLake tables** (or plain external tables) — BigQuery queries the Parquet in place in Cloud Storage. Trade-offs: query performance is generally lower than native BigQuery storage (no clustering on native storage layout, remote reads, and the cost model shifts toward scanned object bytes), and some features behave differently. The gain is no data movement, no duplicate copy, other engines (Spark, Trino) can still read the files, and BigLake adds fine-grained access control and a single governance model over the lake. See <https://cloud.google.com/bigquery/docs/biglake-intro>.

### Checkpoint 6

**Q22.** **Dataproc.** The business reason is time-to-value and risk: Dataproc runs their existing PySpark essentially unchanged on managed clusters, so a one-quarter deadline is achievable and the team's skills remain valuable. Dataflow would require rewriting 4,000 lines into Apache Beam — a rewrite with its own defect risk, on a deadline. The condition that flips the answer: if the mandate is *not* a deadline-driven lift-and-shift but a long-term move to serverless with no cluster management, or the workload becomes **streaming**, then **Dataflow** is correct — it is unified batch+stream and autoscales without cluster sizing, whereas Dataproc still means thinking about clusters (even with autoscaling and serverless Spark).

**Q23.** **Datastream**, using **change data capture (CDC)** — it reads the database's replication log (PostgreSQL logical decoding / MySQL binlog / Oracle redo) rather than querying tables, so the load on the primary is minimal and no `SELECT` scans compete with production traffic. The standard pattern is Datastream → BigQuery (a built-in destination) for near-real-time replication. See <https://cloud.google.com/datastream/docs/overview>.

**Q24.** Because the failure is a **rate mismatch**, not a transformation problem. Pub/Sub decouples the producers from the consumers and absorbs the spike in a durable, retained buffer; consumers drain it at whatever rate they can sustain, and nothing is dropped. Dataflow is a *processing* layer — it can autoscale, but if it is the front door it is still coupled to the producer's rate and to its own downstream sinks. The idiomatic architecture is Pub/Sub as the shock absorber, Dataflow as the consumer.

**Q25.** Governance/catalogue: **Dataplex** (unified metadata, data catalogue, data quality and lineage across BigQuery, Cloud Storage and beyond) — and it is Dataplex Universal Catalog that has absorbed the former standalone Data Catalog. Finding and classifying the personal data itself: **Sensitive Data Protection** (formerly Cloud DLP), which inspects, classifies and can de-identify/mask PII. They answer different questions: "what data do we have and who owns it" vs. "does this column contain a credit-card number." See <https://cloud.google.com/dataplex/docs> and <https://cloud.google.com/sensitive-data-protection/docs>.

### Checkpoint 7

**Q26.** 900 TB at 500 Mbps ≈ 900×10¹²/(62.5×10⁶) s ≈ 14.4 M s ≈ **167 days at 100% utilisation**, ~238 days at a realistic 70%. Recommendation: **Transfer Appliance** — 900 TB is three TA300 units, shipped and ingested in weeks. The second-order reason the arithmetic misses: the link is **shared with 400 employees**. Even if 167 days were acceptable, saturating that circuit degrades every other business function for half a year; the transfer would have to be throttled, which makes the real timeline worse still. Bandwidth is not free capacity lying idle — it is production infrastructure.

**Q27.** **Database Migration Service (DMS).** The sequence: (1) create source and destination connection profiles; (2) DMS performs an initial **full dump** of the 2 TB into the Cloud SQL destination while the source stays live; (3) DMS then applies **continuous change replication** from the source's binlog, so the destination converges and tracks the source; (4) monitor **replication lag** until it is near zero; (5) at the chosen window, stop writes to the source, let the last changes drain, **promote** the destination, and repoint the application. Downtime is only steps 5's drain-and-repoint — minutes, not the hours a dump-and-restore of 2 TB would take.

**Q28.** **Storage Transfer Service** moves **files/objects** between storage systems — S3, Azure Blob, on-prem filesystems, HTTP endpoints, other Cloud Storage buckets — as a bulk or scheduled copy job; the unit is an object and the intent is *relocation or ongoing synchronisation of a file corpus*. **Datastream** moves **database row changes** via CDC from an OLTP source into an analytics destination; the unit is a transaction and the intent is *keeping an analytical copy fresh*. Wrong-tool symptoms: using Storage Transfer for database freshness gives you stale nightly dumps and heavy source load; using Datastream to move a media archive is a category error — there are no rows.

### Checkpoint 8 — Capstone mapping

| # | Product | Decisive property | Strongest wrong answer, and why it fails |
|---|---|---|---|
| **C1** | **Spanner** | Globally distributed writes with external consistency and 99.999% multi-region SLA; "never stale, never lost" is a consistency guarantee, not a performance goal | *Bigtable* — enormous write throughput and low latency, but no cross-row transactions or global strong consistency, so a rank can be read stale or a score lost in a race |
| **C2** | **Cloud Storage, Archive class** | Opaque binary objects, near-zero read frequency, ≥365-day retention, retrieval within a day is far inside Archive's millisecond-to-seconds first-byte latency | *Coldline* — correct shape, wrong economics: at ten-year retention and near-zero reads, Archive is ~3× cheaper to store and the retrieval premium is almost never paid |
| **C3** | **Cloud SQL for SQL Server** | Managed SQL Server keeps the engine, the dialect and the drivers identical, so "not a line of code" is literally satisfiable | *AlloyDB / Cloud SQL for PostgreSQL* — cheaper and more capable, but it is a different engine; the vendor constraint forbids it. (If the licence or version is unsupported, the fallback is SQL Server on Compute Engine, not a different engine.) |
| **C4** | **Bigtable** | Millions of writes/second with single-digit-millisecond reads on a key range; the query is literally `advertiser_id` + time range, which is a row-key prefix scan | *BigQuery* — it will store and analyse these events happily, but it is not a low-latency serving store for a real-time bidding path. The real architecture is both: Bigtable serving, BigQuery analytics |
| **C5** | **Looker** (semantic layer, LookML) | One governed, version-controlled definition of a metric, consumed by Sheets, Looker Studio, embedded apps and APIs — the requirement is *governance of the definition*, not a chart | *Looker Studio alone* — free and good at dashboards, but each report re-implements its own "net revenue", which is exactly the problem being solved |
| **C6** | **Memorystore** (Redis/Valkey) | Sub-millisecond in-memory reads, explicitly rebuildable — the requirement states the data is disposable, which is what makes a cache the right system | *Firestore* — durable and fast, but milliseconds not microseconds, and you would be paying for durability the requirement says it does not need |
| **C7** | **Firestore (Native mode)** | Offline persistence in the mobile SDK with automatic sync and conflict resolution on reconnect; real-time listeners for dispatcher views | *Cloud SQL* — a mobile client cannot hold a connection in a tunnel; you would be hand-building the offline queue and sync layer Firestore ships |
| **C8** | **Sensitive Data Protection** (ex-Cloud DLP) | Purpose-built inspection, classification and de-identification/masking of PII such as `CREDIT_CARD_NUMBER`, runnable over BigQuery and Cloud Storage before analysts get access | *BigQuery column-level access control* — necessary but insufficient: it protects columns you have already identified, and the problem is that the card numbers are hiding inside free-text ticket bodies |

**Q29.** **C3 and C4** are the two that move.
- **C3**: the constraint "no data engineers, no capacity planning" pushes even harder toward **Cloud SQL** over any self-managed SQL Server on Compute Engine — the answer does not change product, but the *justification* changes from "vendor constraint" to "operational capacity", which is the more durable argument.
- **C4** is the real change: **Bigtable requires genuine schema-design skill** (row-key design, hotspot avoidance, cluster sizing / autoscaling policy). A team with no data engineers will build a hotspotted table and conclude the product is slow. Without that skill, the honest recommendation is **BigQuery** for the analytical half plus a simpler serving store (Firestore, or Memorystore in front of it) for the low-latency half — accepting a worse ceiling in exchange for a system the team can actually operate. Naming a product a team cannot run is a failed recommendation regardless of its benchmark numbers.

*(A defensible alternative answer names **C5** — Looker carries real modelling and LookML cost, and a team with no data engineers may be better served by Looker Studio on a well-designed BigQuery view. Credit that if you also named the governance regression it causes.)*

**Q30.** Model answer:

> Both products would store the leaderboard correctly on an ordinary day. The difference shows up on the worst day. With Cloud SQL, every score in the world is written through a single primary database in a single region: if that region has an outage, the leaderboard is unavailable to all 50 million players until we promote a replica by hand, and any score written in the last seconds before the failure may be gone. With Spanner, the same write is committed to a quorum of replicas in multiple regions before we acknowledge it, so losing an entire region costs us neither availability nor a single score — the published availability target is 99.999%, roughly five minutes of downtime a year, against Cloud SQL's 99.95%, roughly four and a half hours. Spanner also removes a second, quieter risk: because Cloud SQL scales by making one machine bigger, our growth has a ceiling we would eventually hit during a launch — the worst possible moment — while Spanner adds capacity by adding nodes, with no rewrite. We pay more per month for Spanner. What we are buying is that a regional outage and a viral growth spike both become non-events instead of incidents, and for a product whose entire value is a live global ranking, an hour of wrong or missing ranks costs more in player trust than the difference in the annual bill.

</details>

---

## Sources

- Cloud Digital Leader exam guide — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Cloud Storage classes / lifecycle / Autoclass — <https://cloud.google.com/storage/docs/storage-classes>, <https://cloud.google.com/storage/docs/lifecycle>, <https://cloud.google.com/storage/docs/autoclass>
- Filestore — <https://cloud.google.com/filestore/docs/overview>
- Cloud SQL — <https://cloud.google.com/sql/docs/introduction>
- AlloyDB for PostgreSQL — <https://cloud.google.com/alloydb/docs/overview>
- Spanner (incl. emulator) — <https://cloud.google.com/spanner/docs/overview>, <https://cloud.google.com/spanner/docs/emulator>
- Bigtable schema design — <https://cloud.google.com/bigtable/docs/schema-design>
- Firestore, and Native vs. Datastore mode — <https://cloud.google.com/firestore/docs>, <https://cloud.google.com/datastore/docs/firestore-or-datastore>
- Memorystore tiers — <https://cloud.google.com/memorystore/docs/redis/redis-tiers>
- BigQuery introduction, pricing, reservations, BigLake — <https://cloud.google.com/bigquery/docs/introduction>, <https://cloud.google.com/bigquery/pricing>, <https://cloud.google.com/bigquery/docs/reservations-intro>, <https://cloud.google.com/bigquery/docs/biglake-intro>
- Pub/Sub — <https://cloud.google.com/pubsub/docs/overview>
- Dataflow / Dataproc / Data Fusion / Composer — <https://cloud.google.com/dataflow/docs>, <https://cloud.google.com/dataproc/docs>, <https://cloud.google.com/data-fusion/docs>, <https://cloud.google.com/composer/docs>
- Datastream — <https://cloud.google.com/datastream/docs/overview>
- Dataplex — <https://cloud.google.com/dataplex/docs>
- Sensitive Data Protection — <https://cloud.google.com/sensitive-data-protection/docs>
- Database Migration Service — <https://cloud.google.com/database-migration/docs>
- Storage Transfer Service / Transfer Appliance — <https://cloud.google.com/storage-transfer/docs/overview>, <https://cloud.google.com/transfer-appliance/docs>
- Looker — <https://cloud.google.com/looker/docs>