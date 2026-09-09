# Topic 2.3 — Guided Exercises

## Smart analytics, business intelligence, and streaming analytics: value in real business use cases

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12) · **Section 2.3** · **Exam weight: 6.0**

These exercises are built around one claim the exam keeps testing in different disguises: *the value of an analytics platform is not "we store data", it is **time-to-answer**, **cost-per-answer**, and **who is allowed to ask**.* Every block below makes you produce a measurable number for one of those three, then asks you to translate it into the language a CFO or a line-of-business owner actually buys.

You will run real commands. Where a step costs money beyond the free tier it is flagged **`[$]`** and marked optional.

---

## Prerequisites

### Block 0.1 — Environment and cost guardrails

1. Open Cloud Shell (or a local shell with the `gcloud` CLI and `bq` installed) and confirm your identity and project:

```bash
gcloud auth list
gcloud config list project
```

Expected output:

```
              Credentialed Accounts
ACTIVE  ACCOUNT
*       you@example.com

[core]
project = my-cdl-project
```

2. Export the variables every later block reuses:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export REGION="us-central1"
export BQ_LOCATION="US"
export DS="cdl_23_analytics"

echo "$PROJECT_ID / $PROJECT_NUMBER / $REGION / $BQ_LOCATION / $DS"
```

3. Enable the APIs used in this topic:

```bash
gcloud services enable \
  bigquery.googleapis.com \
  bigqueryconnection.googleapis.com \
  pubsub.googleapis.com \
  dataflow.googleapis.com \
  datalineage.googleapis.com
```

Expected output (first run takes 30–60 s, then silence on success):

```
Operation "operations/acat.p2-123456789012-8f2b...-c1e0" finished successfully.
```

4. Create the dataset that will hold everything you build. Note the explicit **location** — it is a permanent property of the dataset and cannot be changed later:

```bash
bq --location="$BQ_LOCATION" mk -d \
  --description "CDL 2.3 exercises" \
  "${PROJECT_ID}:${DS}"
```

Expected output:

```
Dataset 'my-cdl-project:cdl_23_analytics' successfully created.
```

5. Confirm your free-tier position before spending anything. BigQuery's free tier covers **1 TiB of query bytes processed per month** and **10 GiB of active storage**; a `--dry_run` costs nothing at all.

**Comprehension check — Block 0.1**

- **Q0.1** — You created the dataset in the `US` multi-region. A subsidiary later needs the same tables to be physically stored in `europe-west1` for a data-residency requirement. What is the shortest technically correct answer, and what does that imply about the *first* decision in any analytics project?
- **Q0.2** — Why is a `--dry_run` a strategically important feature for a business, not just a developer convenience?
- **Q0.3** — Which of these is a *managed service* decision and which is an *architecture* decision: (a) choosing BigQuery over a self-managed Hadoop cluster, (b) partitioning a table by day?

---

## Exercise 1 — Time-to-answer: query a petabyte-scale public dataset with no infrastructure

The most under-appreciated business fact about BigQuery is that a business analyst can query a multi-terabyte dataset **without anyone provisioning, sizing, patching, or scaling a cluster first**. That is the "serverless" value proposition in section 2.3.

### Block 1.1 — Ask a question of data you never loaded

1. Estimate, without running it, the cost of scanning a large public table:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT term, COUNT(*) AS appearances
 FROM `bigquery-public-data.google_trends.top_terms`
 GROUP BY term
 ORDER BY appearances DESC
 LIMIT 10'
```

Expected output (your byte count will differ — the dataset grows daily):

```
Query successfully validated. Assuming the tables are not modified, running this query will process 41837294518 bytes of data.
```

2. **Do not run that query.** Convert the estimate to money and to free-tier consumption:

```bash
python3 -c "b=41837294518; t=b/2**40; print(f'{t:.3f} TiB -> approx \${t*6.25:.2f} on-demand')"
```

Expected output:

```
0.038 TiB -> approx $0.24 on-demand
```

3. Now add a filter on the table's **partitioning column** (`refresh_date`) and dry-run again:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT term, rank, refresh_date
 FROM `bigquery-public-data.google_trends.top_terms`
 WHERE refresh_date = DATE_SUB(CURRENT_DATE(), INTERVAL 2 DAY)
   AND rank <= 5
 ORDER BY rank'
```

Expected output — one to three orders of magnitude smaller:

```
Query successfully validated. Assuming the tables are not modified, running this query will process 24117248 bytes of data.
```

4. Run the cheap one and look at the wall-clock time:

```bash
time bq query --use_legacy_sql=false --format=pretty \
'SELECT term, rank, refresh_date
 FROM `bigquery-public-data.google_trends.top_terms`
 WHERE refresh_date = DATE_SUB(CURRENT_DATE(), INTERVAL 2 DAY)
   AND rank <= 5
 ORDER BY rank'
```

Expected output:

```
Waiting on bqjob_r5c2ab1e9f4d7c8a1_0000019a3f2b1c04_1 ... (2s) Current status: DONE
+-------------------+------+--------------+
|       term        | rank | refresh_date |
+-------------------+------+--------------+
| nba playoffs      |    1 | 2026-09-04   |
| hurricane tracker |    2 | 2026-09-04   |
| iphone 18         |    3 | 2026-09-04   |
| us open           |    4 | 2026-09-04   |
| stock market      |    5 | 2026-09-04   |
+-------------------+------+--------------+

real    0m6.412s
```

**Comprehension check — Block 1.1**

- **Q1.1** — You never created a cluster, never sized a machine, and never waited for a data load. Name the two cost lines an equivalent on-premises data warehouse would have that did not appear here at all.
- **Q1.2** — Steps 1 and 3 are the *same table*. Explain, in one sentence a non-technical stakeholder would accept, why one costs ~1,700× more than the other.
- **Q1.3** — Marketing wants to enrich their campaign data with Google Trends. In the classic on-premises model, what is the multi-week task that this exercise made disappear entirely? What is the name of the general capability that makes third-party datasets queryable in place?

---

## Exercise 2 — Cost-per-answer: partitioning and clustering as a business lever

Every dashboard refresh is a query, and every query is a bill. This block turns a schema decision into a percentage on an invoice.

### Block 2.1 — Build a naive table and an engineered table

1. Create a deliberately naive copy of a retail orders fact table (no partitioning, no clustering), enriched with customer country:

```bash
bq query --use_legacy_sql=false --nouse_cache "
CREATE OR REPLACE TABLE \`${PROJECT_ID}.${DS}.orders_naive\` AS
SELECT
  o.order_id,
  o.user_id,
  o.status,
  TIMESTAMP(o.created_at) AS created_at,
  DATE(o.created_at)      AS order_day,
  u.country,
  u.traffic_source,
  o.num_of_item
FROM \`bigquery-public-data.thelook_ecommerce.orders\` o
JOIN \`bigquery-public-data.thelook_ecommerce.users\` u
  ON o.user_id = u.id
"
```

Expected output:

```
Waiting on bqjob_r2a91f0c7de3b45f8_0000019a3f31a7c2_1 ... (7s) Current status: DONE
```

2. Create the engineered twin — same rows, partitioned by day and clustered by the two columns analysts filter on most:

```bash
bq query --use_legacy_sql=false --nouse_cache "
CREATE OR REPLACE TABLE \`${PROJECT_ID}.${DS}.orders_part\`
PARTITION BY order_day
CLUSTER BY country, status
AS SELECT * FROM \`${PROJECT_ID}.${DS}.orders_naive\`
"
```

3. Confirm both hold the same number of rows and compare their metadata:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT table_name, row_count, ROUND(size_bytes/1024/1024, 2) AS size_mib
FROM \`${PROJECT_ID}.${DS}.__TABLES__\`
WHERE table_id IS NOT NULL
" 2>/dev/null \
|| bq query --use_legacy_sql=false --format=pretty "
SELECT table_name, total_rows, ROUND(total_logical_bytes/1024/1024,2) AS logical_mib
FROM \`${PROJECT_ID}.${DS}.INFORMATION_SCHEMA.TABLE_STORAGE\`
WHERE table_name IN ('orders_naive','orders_part')
"
```

Expected output:

```
+---------------+------------+-------------+
|  table_name   | total_rows | logical_mib |
+---------------+------------+-------------+
| orders_naive  |     125226 |        8.94 |
| orders_part   |     125226 |        9.12 |
+---------------+------------+-------------+
```

### Block 2.2 — Measure the difference the way finance measures it

4. Dry-run the *same business question* — "last 7 days of completed orders in Brasil" — against both tables:

```bash
for T in orders_naive orders_part; do
  printf '%-14s ' "$T"
  bq query --use_legacy_sql=false --dry_run "
    SELECT country, status, COUNT(*) AS orders, SUM(num_of_item) AS items
    FROM \`${PROJECT_ID}.${DS}.${T}\`
    WHERE order_day BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY) AND CURRENT_DATE()
      AND country = 'Brasil'
      AND status  = 'Complete'
    GROUP BY country, status" 2>&1 | grep -o '[0-9]* bytes'
done
```

Expected output (exact numbers vary with the public dataset's current contents):

```
orders_naive   6710886 bytes
orders_part    139264 bytes
```

5. Turn that ratio into an annual figure for a realistic BI workload — 40 analysts, 25 dashboard refreshes each per working day:

```bash
python3 - <<'EOF'
naive, part = 6_710_886, 139_264
scale = 5000                      # production fact table is 5000x this sample
queries = 40 * 25 * 250           # analysts * refreshes/day * working days
price = 6.25 / 2**40              # USD per byte, on-demand US
for name, b in (("naive", naive), ("partitioned+clustered", part)):
    print(f"{name:>22}: ${b*scale*queries*price:,.2f}/year")
EOF
```

Expected output:

```
                 naive: $95,367.43/year
 partitioned+clustered: $1,979.05/year
```

**Comprehension check — Block 2.1 / 2.2**

- **Q2.1** — The two tables store the same rows and cost essentially the same to *store*. Where, precisely, does the ~48× saving come from?
- **Q2.2** — Partitioning and clustering both reduce scanned bytes. State the mechanical difference between them, and give the rule of thumb for which column goes in which.
- **Q2.3** — Your director says "let's just partition and cluster every table by everything." Give two reasons that is wrong.
- **Q2.4** — A colleague argues that on **BigQuery Editions (capacity/slot-based) pricing** this whole exercise is pointless, because you are not billed per byte. Is the optimization now worthless? Explain what it buys you instead.

---

## Exercise 3 — Streaming analytics: from hours-old to seconds-old

Batch analytics answers *"what happened yesterday?"*. Streaming analytics answers *"what is happening right now, and should we act?"*. This block builds the shortest possible production-grade streaming path: **Pub/Sub → BigQuery** with no code and no pipeline to operate.

### Block 3.1 — A schema-validated ingestion topic

1. Define the event contract as an Avro schema. In production this is the single most important artifact in the pipeline: it is what stops a mobile-app release from silently corrupting the warehouse.

```bash
cat > /tmp/clickstream.avsc <<'EOF'
{
  "type": "record",
  "name": "ClickEvent",
  "fields": [
    {"name": "event_id",   "type": "string"},
    {"name": "event_ts",   "type": "string"},
    {"name": "user_id",    "type": "string"},
    {"name": "product_id", "type": "string"},
    {"name": "action",     "type": "string"},
    {"name": "revenue",    "type": "double"}
  ]
}
EOF

gcloud pubsub schemas create clickstream-schema \
  --type=avro \
  --definition-file=/tmp/clickstream.avsc
```

Expected output:

```
Created schema [clickstream-schema].
```

2. Create the topic and **bind the schema to it**, choosing JSON on the wire:

```bash
gcloud pubsub topics create clickstream \
  --schema=clickstream-schema \
  --message-encoding=json
```

Expected output:

```
Created topic [projects/my-cdl-project/topics/clickstream].
```

3. Create the destination table. Column names must match the schema field names:

```bash
bq mk --table \
  --time_partitioning_type=DAY \
  "${PROJECT_ID}:${DS}.clickstream_raw" \
  event_id:STRING,event_ts:STRING,user_id:STRING,product_id:STRING,action:STRING,revenue:FLOAT
```

Expected output:

```
Table 'my-cdl-project:cdl_23_analytics.clickstream_raw' successfully created.
```

4. Grant the Pub/Sub service agent permission to write into BigQuery. This is the step everyone forgets, and it fails *silently* into a dead-letter-less void if skipped:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor" \
  --condition=None
```

Expected output (truncated):

```
Updated IAM policy for project [my-cdl-project].
bindings:
- members:
  - serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com
  role: roles/bigquery.dataEditor
```

5. Create a **BigQuery subscription** — Pub/Sub writes directly to the table, with no Dataflow job in between:

```bash
gcloud pubsub subscriptions create clickstream-to-bq \
  --topic=clickstream \
  --bigquery-table="${PROJECT_ID}:${DS}.clickstream_raw" \
  --use-topic-schema
```

Expected output:

```
Created subscription [projects/my-cdl-project/subscriptions/clickstream-to-bq].
```

### Block 3.2 — Emit traffic and measure end-to-end latency

6. Publish a burst of synthetic clickstream events:

```bash
ACTIONS=(view add_to_cart checkout view view search)
for i in $(seq 1 60); do
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  A="${ACTIONS[$((RANDOM % 6))]}"
  REV=0
  [ "$A" = "checkout" ] && REV="$(( (RANDOM % 200) + 20 )).99"
  gcloud pubsub topics publish clickstream --message \
    "{\"event_id\":\"e-$i\",\"event_ts\":\"$TS\",\"user_id\":\"u-$((RANDOM%12))\",\"product_id\":\"p-$((RANDOM%40))\",\"action\":\"$A\",\"revenue\":$REV}" \
    >/dev/null
done
echo "published 60 events"
```

Expected output:

```
published 60 events
```

7. Prove the schema is *enforced*, not decorative — publish a message that violates the contract:

```bash
gcloud pubsub topics publish clickstream \
  --message '{"event_id":"bad-1","revenue":"not-a-number"}'
```

Expected output:

```
ERROR: (gcloud.pubsub.topics.publish) INVALID_ARGUMENT: Invalid data in message: Message failed schema validation.
```

8. Query the warehouse immediately — no load job, no ETL window:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT
  action,
  COUNT(*)                       AS events,
  ROUND(SUM(revenue), 2)         AS revenue,
  MAX(TIMESTAMP_DIFF(CURRENT_TIMESTAMP(),
      PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', event_ts), SECOND)) AS worst_age_seconds
FROM \`${PROJECT_ID}.${DS}.clickstream_raw\`
GROUP BY action
ORDER BY events DESC"
```

Expected output:

```
+--------------+--------+---------+-------------------+
|    action    | events | revenue | worst_age_seconds |
+--------------+--------+---------+-------------------+
| view         |     29 |     0.0 |                74 |
| checkout     |     11 |  1284.9 |                71 |
| add_to_cart  |     10 |     0.0 |                69 |
| search       |     10 |     0.0 |                66 |
+--------------+--------+---------+-------------------+
```

**Comprehension check — Block 3.1 / 3.2**

- **Q3.1** — `worst_age_seconds` is dominated by how long your `for` loop took, not by Pub/Sub. What is the *architectural* claim this number supports for the business, and what would the equivalent number be in a nightly-batch warehouse?
- **Q3.2** — Step 7 was rejected at the *topic*. Name the business failure mode that this single feature prevents, and say who would otherwise have discovered it, when.
- **Q3.3** — What exactly does Pub/Sub decouple, and why does that matter during a Black Friday traffic spike when BigQuery, or a downstream consumer, briefly slows down?
- **Q3.4** — You built this with zero pipeline code. Name two concrete requirements that would force you to put **Dataflow** between Pub/Sub and BigQuery instead of using a BigQuery subscription.

---

## Exercise 4 — Windows, watermarks and late data: the hard part of streaming

Streaming analytics is not "batch, but faster". It is a different question: *over what slice of an unbounded stream am I aggregating, and when do I decide that slice is finished?* Section 2.3 expects you to be able to explain windowing to a business audience.

### Block 4.1 — Tumbling (fixed) windows in SQL

1. Aggregate the live clickstream into fixed one-minute buckets:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT
  TIMESTAMP_BUCKET(PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', event_ts), INTERVAL 1 MINUTE) AS window_start,
  COUNT(*)                                                    AS events,
  COUNTIF(action = 'checkout')                                AS checkouts,
  ROUND(SUM(revenue), 2)                                      AS revenue
FROM \`${PROJECT_ID}.${DS}.clickstream_raw\`
GROUP BY window_start
ORDER BY window_start"
```

Expected output:

```
+---------------------+--------+-----------+---------+
|    window_start     | events | checkouts | revenue |
+---------------------+--------+-----------+---------+
| 2026-09-06 14:22:00 |     38 |         7 |   812.9 |
| 2026-09-06 14:23:00 |     22 |         4 |   472.0 |
+---------------------+--------+-----------+---------+
```

### Block 4.2 — Session windows: activity-defined, not clock-defined

2. Group each user's events into sessions with a 30-second inactivity gap — the shape of window a fixed clock cannot express:

```bash
bq query --use_legacy_sql=false --format=pretty "
WITH ev AS (
  SELECT user_id, action, revenue,
         PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', event_ts) AS ts
  FROM \`${PROJECT_ID}.${DS}.clickstream_raw\`
),
gapped AS (
  SELECT *,
    IF(TIMESTAMP_DIFF(ts, LAG(ts) OVER (PARTITION BY user_id ORDER BY ts), SECOND) > 30
       OR LAG(ts) OVER (PARTITION BY user_id ORDER BY ts) IS NULL, 1, 0) AS new_session
  FROM ev
),
sessions AS (
  SELECT *, SUM(new_session) OVER (PARTITION BY user_id ORDER BY ts) AS session_no
  FROM gapped
)
SELECT user_id, session_no,
       MIN(ts) AS session_start,
       TIMESTAMP_DIFF(MAX(ts), MIN(ts), SECOND) AS duration_s,
       COUNT(*) AS events,
       COUNTIF(action='checkout') AS checkouts
FROM sessions
GROUP BY user_id, session_no
ORDER BY events DESC
LIMIT 5"
```

Expected output:

```
+---------+------------+---------------------+------------+--------+-----------+
| user_id | session_no |    session_start    | duration_s | events | checkouts |
+---------+------------+---------------------+------------+--------+-----------+
| u-7     |          1 | 2026-09-06 14:22:03 |         41 |      8 |         2 |
| u-3     |          1 | 2026-09-06 14:22:05 |         38 |      6 |         1 |
| u-11    |          1 | 2026-09-06 14:22:11 |         33 |      5 |         0 |
+---------+------------+---------------------+------------+--------+-----------+
```

3. Study the window taxonomy before answering — these three names appear verbatim in exam scenarios:

| Window | Definition | Business question it answers |
|---|---|---|
| **Tumbling (fixed)** | Non-overlapping, equal-length slices | "Revenue per minute", "orders per hour" |
| **Hopping (sliding)** | Fixed length, emitted every *N* < length — windows overlap | "Rolling 5-minute error rate, refreshed every 30 s" |
| **Session** | Bounded by a gap of inactivity, per key | "How long is a shopping session before checkout?" |
| **Global** | The whole unbounded stream, released by a trigger | "Running lifetime total" |

### Block 4.3 — `[$]` Optional: a real streaming pipeline with Dataflow

> **Cost warning.** A streaming Dataflow job holds at least one worker VM continuously. Expect roughly a few US cents per hour per vCPU plus Streaming Engine data-processing charges — small, but **it does not stop by itself**. Do step 7 the same day.

4. Create a pull subscription and a staging bucket for the job:

```bash
gcloud pubsub subscriptions create clickstream-dataflow --topic=clickstream
gsutil mb -l "$REGION" "gs://${PROJECT_ID}-dfstage"
bq mk --table "${PROJECT_ID}:${DS}.clickstream_df" \
  event_id:STRING,event_ts:STRING,user_id:STRING,product_id:STRING,action:STRING,revenue:FLOAT
```

5. Launch the Google-provided template — no Beam code written by you:

```bash
gcloud dataflow jobs run "cdl23-pubsub-to-bq" \
  --gcs-location gs://dataflow-templates/latest/PubSub_Subscription_to_BigQuery \
  --region "$REGION" \
  --staging-location "gs://${PROJECT_ID}-dfstage/tmp" \
  --parameters "inputSubscription=projects/${PROJECT_ID}/subscriptions/clickstream-dataflow,outputTableSpec=${PROJECT_ID}:${DS}.clickstream_df"
```

Expected output:

```
createTime: '2026-09-06T14:31:02.884512Z'
currentStateTime: '1970-01-01T00:00:00Z'
id: 2026-09-06_07_31_02-4471928365109842177
location: us-central1
name: cdl23-pubsub-to-bq
projectId: my-cdl-project
type: JOB_TYPE_STREAMING
```

6. Watch it come up, then publish a few more events (re-run Block 3.2 step 6) and confirm they land in `clickstream_df`:

```bash
gcloud dataflow jobs list --region "$REGION" --status active \
  --format='table(id, name, state, type)'
```

Expected output:

```
JOB_ID                                    NAME                STATE    TYPE
2026-09-06_07_31_02-4471928365109842177   cdl23-pubsub-to-bq  Running  Streaming
```

7. **Drain and stop the job — do not skip this:**

```bash
JOB_ID="$(gcloud dataflow jobs list --region "$REGION" --status active \
  --filter='name=cdl23-pubsub-to-bq' --format='value(id)')"
gcloud dataflow jobs drain "$JOB_ID" --region "$REGION"
```

Expected output:

```
Started draining job [2026-09-06_07_31_02-4471928365109842177]
```

**Comprehension check — Block 4.1 / 4.2 / 4.3**

- **Q4.1** — A payments team wants an alert when the decline rate exceeds 3% "over the last 5 minutes, checked continuously". Which window type, with which parameters?
- **Q4.2** — Why can a *session* window not be computed by simply waiting for a clock to tick? What does the system need instead?
- **Q4.3** — A mobile app buffers events while offline and uploads them 20 minutes later. Define **event time** vs **processing time**, then explain what a **watermark** is and what happens to those events by default.
- **Q4.4** — In Block 4.3 you ran a streaming pipeline without writing a line of Java or Python. Name the two distinct things a Dataflow *template* removes from the project plan.
- **Q4.5** — Why `drain` rather than `cancel`? Which one would you use if the pipeline were writing corrupt records?

---

## Exercise 5 — The BI layer: who is actually allowed to ask a question

A warehouse nobody can query is a cost centre. This block builds the serving layer and forces the Looker vs. Looker Studio vs. Connected Sheets decision that section 2.3 tests.

### Block 5.1 — Pre-aggregate with a materialized view

1. Create a materialized view over the fact table. BigQuery keeps it incrementally fresh and — critically — **rewrites qualifying queries against the base table to use it automatically**:

```bash
bq query --use_legacy_sql=false "
CREATE MATERIALIZED VIEW \`${PROJECT_ID}.${DS}.mv_daily_sales\`
PARTITION BY order_day
CLUSTER BY country
AS
SELECT
  order_day,
  country,
  status,
  COUNT(*)           AS orders,
  SUM(num_of_item)   AS items
FROM \`${PROJECT_ID}.${DS}.orders_part\`
GROUP BY order_day, country, status"
```

2. Dry-run a dashboard-shaped query **against the base table** and confirm the optimizer picked the view:

```bash
bq query --use_legacy_sql=false --dry_run "
SELECT country, SUM(orders) AS orders
FROM (
  SELECT order_day, country, status, COUNT(*) AS orders, SUM(num_of_item) AS items
  FROM \`${PROJECT_ID}.${DS}.orders_part\`
  GROUP BY order_day, country, status)
WHERE order_day >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY country
ORDER BY orders DESC"
```

Expected output — far fewer bytes than the base table's 30-day partitions:

```
Query successfully validated. Assuming the tables are not modified, running this query will process 31457 bytes of data.
```

### Block 5.2 — `[$]` Optional: BI Engine, the in-memory acceleration layer

> **Cost warning.** A BI Engine reservation is billed per GiB per hour for as long as it exists. Delete it at the end of the block.

3. In the Cloud console, go to **BigQuery → Administration → BI Engine → Create reservation**, choose location `US`, size **1 GiB**, and confirm.

4. Verify it from SQL:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT project_id, size_gb, preferred_tables
FROM \`region-us.INFORMATION_SCHEMA.BI_CAPACITIES\`"
```

Expected output:

```
+----------------+---------+------------------+
|   project_id   | size_gb | preferred_tables |
+----------------+---------+------------------+
| my-cdl-project |       1 | NULL             |
+----------------+---------+------------------+
```

5. Run the same dashboard query twice and compare elapsed time; then delete the reservation in the console (set size to 0 / **Delete**).

### Block 5.3 — Put a chart in front of a human

6. Open **https://lookerstudio.google.com** → **Create → Data source → BigQuery** → your project → `cdl_23_analytics` → `mv_daily_sales` → **Connect**.

7. Add a **time series** chart: dimension `order_day`, metric `orders`, breakdown dimension `country`. Add a date-range control.

8. Click **Share** and observe the sharing model — it is Google-Drive-style, per-person or per-link.

9. Now inspect the alternative in the console: BigQuery → your table → **Export → Explore with Sheets** (Connected Sheets). Note that the spreadsheet does not download the rows; it issues BigQuery queries behind a familiar pivot-table interface.

**Comprehension check — Block 5.1 / 5.2 / 5.3**

- **Q5.1** — A materialized view and a scheduled query that writes a summary table both pre-aggregate. Give the two properties the materialized view has that the scheduled table does not.
- **Q5.2** — Partitioning, materialized views, and BI Engine all make dashboards faster. Order them by *when* they act in the query lifecycle, and say which one you would reach for **last**.
- **Q5.3** — Finance's 30 analysts live in spreadsheets and refuse new tools, but keep exporting 5-million-row CSVs that go stale and leak. What do you propose, and what are the two problems it solves at once?
- **Q5.4** — Two BI scenarios. (a) A 12-person startup wants free, self-serve dashboards this week. (b) A 4,000-employee retailer needs one governed definition of "net revenue" enforced identically across finance, ops, and an embedded partner portal, with version-controlled metric logic. Which of **Looker** and **Looker Studio** for each, and what is the one word that separates them?

---

## Exercise 6 — Smart analytics: prediction where the data already lives

"Smart analytics" is Google's term for analytics that includes machine learning without a separate ML platform, a data-science team, or a data-export step. Prove it in SQL.

### Block 6.1 — Train a demand forecast without leaving BigQuery

1. Train a time-series model. Note there is no Python, no notebook, no feature store, and no data movement:

```bash
bq query --use_legacy_sql=false "
CREATE OR REPLACE MODEL \`${PROJECT_ID}.${DS}.revenue_forecast\`
OPTIONS(
  model_type                = 'ARIMA_PLUS',
  time_series_timestamp_col = 'order_day',
  time_series_data_col      = 'revenue',
  data_frequency            = 'DAILY',
  holiday_region            = 'US',
  auto_arima                = TRUE
) AS
SELECT
  DATE(created_at)       AS order_day,
  SUM(sale_price)        AS revenue
FROM \`bigquery-public-data.thelook_ecommerce.order_items\`
WHERE DATE(created_at) BETWEEN '2023-01-01' AND '2024-12-31'
GROUP BY order_day"
```

Expected output (training takes 1–3 minutes):

```
Waiting on bqjob_r7bd41c02fa9e5d31_0000019a3f5c11ab_1 ... (94s) Current status: DONE
```

2. Inspect what `auto_arima` selected on your behalf:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT non_seasonal_p, non_seasonal_d, non_seasonal_q, has_drift,
       ROUND(log_likelihood,1) AS log_lik, ROUND(aic,1) AS aic, seasonal_periods
FROM ML.ARIMA_EVALUATE(MODEL \`${PROJECT_ID}.${DS}.revenue_forecast\`)
LIMIT 3"
```

Expected output:

```
+----------------+----------------+----------------+-----------+----------+--------+------------------+
| non_seasonal_p | non_seasonal_d | non_seasonal_q | has_drift | log_lik  |  aic   | seasonal_periods |
+----------------+----------------+----------------+-----------+----------+--------+------------------+
|              1 |              1 |              2 |     false | -5218.4  | 10444.8| ["WEEKLY"]       |
|              2 |              1 |              1 |     false | -5219.9  | 10447.7| ["WEEKLY"]       |
+----------------+----------------+----------------+-----------+----------+--------+------------------+
```

3. Produce a 30-day forecast with a confidence interval — the form a planner can actually use:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT
  DATE(forecast_timestamp)                AS day,
  ROUND(forecast_value, 0)                AS expected_revenue,
  ROUND(prediction_interval_lower_bound,0) AS worst_case,
  ROUND(prediction_interval_upper_bound,0) AS best_case
FROM ML.FORECAST(MODEL \`${PROJECT_ID}.${DS}.revenue_forecast\`,
                 STRUCT(30 AS horizon, 0.80 AS confidence_level))
ORDER BY day
LIMIT 5"
```

Expected output:

```
+------------+------------------+------------+-----------+
|    day     | expected_revenue | worst_case | best_case |
+------------+------------------+------------+-----------+
| 2025-01-01 |            41287 |      35104 |     47470 |
| 2025-01-02 |            42910 |      36502 |     49318 |
| 2025-01-03 |            44655 |      38017 |     51293 |
| 2025-01-04 |            47201 |      40331 |     54071 |
| 2025-01-05 |            46018 |      39002 |     53034 |
+------------+------------------+------------+-----------+
```

4. Point Looker Studio (Block 5.3) at a view over `ML.FORECAST` to see prediction land in the same dashboard as history — for the business user there is no visible boundary between "reporting" and "AI".

**Comprehension check — Block 6.1**

- **Q6.1** — Describe the classic pre-BigQuery-ML workflow for this same forecast. Name the three steps that disappeared and the two *risks* that disappeared with them.
- **Q6.2** — The output has `worst_case` and `best_case` columns. Why is shipping a point forecast alone often worse than shipping no forecast at all, for an inventory buyer?
- **Q6.3** — When does BigQuery ML stop being the right tool, and what do you move to?
- **Q6.4** — Give a concrete business use case for each: (a) `ARIMA_PLUS`, (b) `LOGISTIC_REG`, (c) `KMEANS`, (d) `MATRIX_FACTORIZATION`.

---

## Exercise 7 — Governance: making data shareable *and* safe

Analytics value scales with the number of people allowed to ask questions — which is precisely why ungoverned platforms get locked down and die. This block shows the controls that let you open access instead.

### Block 7.1 — Row-level security

1. Confirm your unrestricted view of the data:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT country, COUNT(*) AS orders
FROM \`${PROJECT_ID}.${DS}.orders_part\`
GROUP BY country ORDER BY orders DESC LIMIT 5"
```

Expected output:

```
+----------------+--------+
|    country     | orders |
+----------------+--------+
| China          |  32104 |
| United States  |  27890 |
| Brasil         |  15342 |
| South Korea    |   8891 |
| France         |   7756 |
+----------------+--------+
```

2. Apply a row access policy scoped to your own account:

```bash
MY_EMAIL="$(gcloud config get-value account)"
bq query --use_legacy_sql=false "
CREATE OR REPLACE ROW ACCESS POLICY brasil_only
ON \`${PROJECT_ID}.${DS}.orders_part\`
GRANT TO ('user:${MY_EMAIL}')
FILTER USING (country = 'Brasil')"
```

3. Re-run the query from step 1, unchanged:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT country, COUNT(*) AS orders
FROM \`${PROJECT_ID}.${DS}.orders_part\`
GROUP BY country ORDER BY orders DESC LIMIT 5"
```

Expected output:

```
+---------+--------+
| country | orders |
+---------+--------+
| Brasil  |  15342 |
+---------+--------+
```

4. Remove the policy:

```bash
bq query --use_legacy_sql=false "
DROP ROW ACCESS POLICY brasil_only ON \`${PROJECT_ID}.${DS}.orders_part\`"
```

### Block 7.2 — Sharing an aggregate without sharing the rows

5. Create a second dataset that will act as the "shared with suppliers" surface, and an **authorized view** over the fact table:

```bash
bq --location="$BQ_LOCATION" mk -d "${PROJECT_ID}:${DS}_shared"

bq query --use_legacy_sql=false "
CREATE OR REPLACE VIEW \`${PROJECT_ID}.${DS}_shared.v_supplier_demand\` AS
SELECT order_day, country, SUM(num_of_item) AS items
FROM \`${PROJECT_ID}.${DS}.orders_part\`
WHERE status = 'Complete'
GROUP BY order_day, country"

bq update --view_udf_resource="" \
  --authorized_view_use_legacy_sql=false \
  "${PROJECT_ID}:${DS}_shared.v_supplier_demand" 2>/dev/null || true
```

6. Authorize the view against the source dataset in the console: **BigQuery → `cdl_23_analytics` → Sharing → Authorize views → Add** `cdl_23_analytics_shared.v_supplier_demand`. A supplier granted `roles/bigquery.dataViewer` on `cdl_23_analytics_shared` **only** can now read the aggregate without any access to `orders_part`.

7. Look at the lineage graph that was recorded for the tables you created: **BigQuery → `orders_part` → Lineage** tab.

**Comprehension check — Block 7.1 / 7.2**

- **Q7.1** — In step 3 the *query text did not change* and the *analyst was not told anything*. Why is enforcement at the data layer rather than in the BI tool the only defensible design once you have more than one BI tool?
- **Q7.2** — Distinguish row-level security, column-level security (policy tags), and dynamic data masking, with one use case each.
- **Q7.3** — A retailer wants to give 400 suppliers a daily demand feed. Compare (a) emailing CSVs, (b) authorized views, (c) an **Analytics Hub** listing, on cost, freshness, and copies-of-data.
- **Q7.4** — What does **Dataplex** add on top of BigQuery permissions, and why does a 200-dataset organization need it while a 5-dataset one does not?

---

## Exercise 8 — The exam skill: mapping a business use case to the right product

No CLI here. This is the drill that decides the 6.0 exam points. For each scenario, write **one primary product**, and one sentence of justification. Then check yourself in the answers.

### Block 8.1 — The decision drill

1. Copy this table and fill the last two columns before reading the answers.

| # | Business scenario | Product | Why |
|---|---|---|---|
| 1 | A bank must flag likely-fraudulent card transactions within 2 seconds of authorization, enriching each event with a 90-day customer profile. | | |
| 2 | A media company has a 400-node on-premises Hadoop/Spark estate with years of custom Spark jobs, and wants to exit the data centre in 6 months with minimal code rewrite. | | |
| 3 | A retailer needs its Oracle and MySQL OLTP databases continuously replicated into the warehouse with near-zero impact on the transactional systems. | | |
| 4 | Business analysts with no coding skills must build and schedule their own ETL pipelines through a drag-and-drop interface. | | |
| 5 | A data engineering team needs to orchestrate a 40-step nightly DAG with dependencies across BigQuery, Cloud Storage, and an external API, with retries and SLAs. | | |
| 6 | An ad-tech platform must serve a user-profile lookup in under 10 ms at 900,000 reads per second. | | |
| 7 | The CFO wants one governed definition of "net margin", identical in every dashboard, spreadsheet, and the customer-facing partner portal. | | |
| 8 | A product manager wants a free, quick, shareable chart of last quarter's signups from an existing BigQuery table. | | |
| 9 | A pharma consortium wants to publish a curated dataset to 60 partner organizations without any of them copying it, and without egress charges to the publisher. | | |
| 10 | A company has data in BigQuery, but also in Amazon S3, and wants a single SQL query across both without building a copy pipeline. | | |
| 11 | A logistics firm wants to predict late deliveries; the features are already in BigQuery and the team knows SQL, not Python. | | |
| 12 | A telco must compute a rolling 5-minute count of dropped calls per cell tower and push an alert, from a 2-million-events-per-second stream. | | |

**Comprehension check — Block 8.1**

- **Q8.1** — Scenarios 2 and 4 are both "get data transformed". State the single most important criterion that separates Dataproc from Cloud Data Fusion here.
- **Q8.2** — Scenarios 5 and 12 both involve "pipelines". Why is Cloud Composer the wrong answer for 12 and Dataflow the wrong answer for 5?
- **Q8.3** — Scenarios 7 and 8 are both "BI". A stakeholder says "they're both dashboards, just pick the free one." Give the one-sentence rebuttal.

---

## Exercise 9 — Turning it into a business case

### Block 9.1 — The pricing models you must be able to compare

1. Study the two BigQuery compute models. **Verify current list prices on the pricing page before quoting them to anyone** — these are illustrative:

| Model | Billed on | Typical fit |
|---|---|---|
| **On-demand** | Bytes processed (~$6.25 / TiB, US; 1 TiB/month free) | Spiky, exploratory, unpredictable workloads; low volume |
| **Editions (Standard / Enterprise / Enterprise Plus)** | Slot-hours, with autoscaling and optional commitments | Steady, high-volume, predictable; cost ceiling required |

2. Compute the crossover point for a workload of 900 TiB scanned per month:

```bash
python3 - <<'EOF'
tib_per_month = 900
on_demand = tib_per_month * 6.25
# Enterprise edition, pay-as-you-go, ~ $0.06 per slot-hour (us-central1)
for slots in (500, 1000, 1500):
    editions = slots * 0.06 * 24 * 30
    print(f"{slots:>5} slots baseline: ${editions:>10,.0f}/mo   vs on-demand ${on_demand:,.0f}/mo")
EOF
```

Expected output:

```
  500 slots baseline: $   21,600/mo   vs on-demand $5,625/mo
 1000 slots baseline: $   43,200/mo   vs on-demand $5,625/mo
 1500 slots baseline: $   64,800/mo   vs on-demand $5,625/mo
```

3. Now model the *other* direction — a workload of 40,000 TiB/month against an autoscaled 2,000-slot baseline:

```bash
python3 -c "print(f'on-demand: \${40000*6.25:,.0f}/mo   editions@2000 slots: \${2000*0.06*24*30:,.0f}/mo')"
```

Expected output:

```
on-demand: $250,000/mo   editions@2000 slots: $86,400/mo
```

4. Check what your own exercises actually cost so far:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT
  DATE(creation_time)                                              AS day,
  COUNT(*)                                                         AS jobs,
  ROUND(SUM(total_bytes_billed)/POW(1024,3), 3)                    AS gib_billed,
  ROUND(SUM(total_bytes_billed)/POW(1024,4) * 6.25, 4)             AS approx_usd
FROM \`region-us\`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND job_type = 'QUERY'
GROUP BY day"
```

Expected output:

```
+------------+------+------------+------------+
|    day     | jobs | gib_billed | approx_usd |
+------------+------+------------+------------+
| 2026-09-06 |   27 |      1.842 |     0.0112 |
+------------+------+------------+------------+
```

**Comprehension check — Block 9.1**

- **Q9.1** — At 900 TiB/month on-demand wins, and at 40,000 TiB/month editions win. State the general rule in one sentence, and name the *non-financial* reason a company might choose editions even when on-demand is cheaper.
- **Q9.2** — BigQuery bills storage and compute separately. Name two business decisions this enables that a coupled appliance (where storage and compute are one box) forbids.
- **Q9.3** — Write the one-paragraph business case for Exercise 3 (streaming clickstream to BigQuery) as you would present it to a retail COO. It must contain a decision that becomes possible, not a technology that becomes available.

---

## Cleanup

Run this to avoid ongoing charges. It is destructive — read it first.

```bash
# Dataflow (if you ran Block 4.3)
JOB_ID="$(gcloud dataflow jobs list --region "$REGION" --status active \
  --filter='name=cdl23-pubsub-to-bq' --format='value(id)' 2>/dev/null)"
[ -n "$JOB_ID" ] && gcloud dataflow jobs cancel "$JOB_ID" --region "$REGION"

# Pub/Sub
gcloud pubsub subscriptions delete clickstream-to-bq --quiet
gcloud pubsub subscriptions delete clickstream-dataflow --quiet 2>/dev/null
gcloud pubsub topics delete clickstream --quiet
gcloud pubsub schemas delete clickstream-schema --quiet

# BigQuery (removes tables, views, materialized views and models)
bq rm -r -f -d "${PROJECT_ID}:${DS}"
bq rm -r -f -d "${PROJECT_ID}:${DS}_shared"

# Storage
gsutil -m rm -r "gs://${PROJECT_ID}-dfstage" 2>/dev/null

# BI Engine: delete the reservation in the console if you created one.
```

Confirm nothing is left running:

```bash
gcloud dataflow jobs list --region "$REGION" --status active
bq ls --datasets "$PROJECT_ID"
```

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 0.1

**A0.1** — You cannot change a dataset's location; you must create a new dataset in `europe-west1` and copy the data (BigQuery cross-region dataset copy, or export/import). The implication: **location is the first and least reversible decision in an analytics project**, and it is driven by regulation and by where the data-producing systems live, not by convenience. Note also that a query cannot join tables across locations — the whole downstream architecture inherits this choice.

**A0.2** — A dry run gives you the price of a question *before* you pay it. That converts an unbounded, unpredictable cost into a governed one: teams can set per-query byte limits (`maximum_bytes_billed`), CI can reject a dashboard change that would 100× the bill, and a finance owner can forecast spend. On-premises, the equivalent question ("how much will this report cost?") has no answer at all, because the cost was sunk into hardware years earlier.

**A0.3** — (a) is a **managed service** decision: you are choosing to stop owning cluster provisioning, patching, scaling and capacity planning. (b) is an **architecture** decision: it is design work you still own, inside the managed service. The exam repeatedly tests that "serverless" removes *operations*, not *design*.

### Exercise 1

**A1.1** — (i) **Capital expenditure and capacity planning** — the cluster sized for peak that sits idle most of the year. (ii) **Operations labour** — patching, upgrades, node failures, storage expansion, backup, and the 24/7 on-call rotation for the cluster itself. A third, if you want it: the **data-loading project** — you queried the data without ever ingesting it.

**A1.2** — "The table is filed by date, like a shelf of dated folders. The first query pulled every folder off the shelf to read them all; the second asked for one specific day, so only one folder was opened. You pay for what is read, not for what is stored." (Technically: partition pruning eliminates all partitions not matching the `refresh_date` predicate before any data is read.)

**A1.3** — What disappears is the **ingestion project**: negotiating a feed, building an ETL pipeline, scheduling it, monitoring it, storing a second copy, and reconciling it. The capability is **BigQuery public datasets** and, in the commercial/partner form, **Analytics Hub** — data is *shared in place* and queried by the consumer, who pays for their own compute. No copy is made, so there is no copy to go stale.

### Exercise 2

**A2.1** — Entirely from **bytes read**. Partitioning by `order_day` lets BigQuery skip every partition outside the 7-day range; clustering by `(country, status)` sorts the data inside each partition into blocks, so the storage layer skips blocks whose min/max range cannot contain `'Brasil'`/`'Complete'`. Same rows, same storage bill, ~48× less scanning. Note the naive table is *also* slower, because reading less data is faster data.

**A2.2** — **Partitioning** physically splits the table into separate segments on one column (a date/timestamp, an integer range, or ingestion time), and pruning is exact — the partition is either read or not. **Clustering** sorts rows within each partition by up to four columns and prunes at block granularity, so the benefit is statistical and strongest on the *leading* clustering column. Rule of thumb: **partition on the column in every `WHERE` clause's time filter; cluster on the high-cardinality columns used for filtering and joining**, ordered from most to least frequently filtered.

**A2.3** — (i) A table can have **only one partitioning column**, and BigQuery caps partitions per table (4,000 by default), so partitioning on a high-cardinality column is impossible or creates tiny, inefficient partitions with metadata overhead that can make queries *slower*. (ii) Clustering only helps queries that filter or aggregate on the leading clustering columns — clustering on columns nobody filters on buys nothing and adds write-side cost. Small tables (under ~1 GB) generally should not be partitioned at all.

**A2.4** — It is worth *more*, not less. On capacity pricing you have a fixed pool of slots; a query that scans 48× more data occupies slots 48× longer, so it (i) delays every other query queued behind it, (ii) forces you to buy a larger baseline or triggers autoscaling you pay for, and (iii) degrades dashboard latency at exactly the busy hours. Under on-demand, waste shows up as a bill; under editions, it shows up as **contention and latency** — which the business feels more directly.

### Exercise 3

**A3.1** — The claim is: **the warehouse is queryable within seconds of the event happening, with no batch window at all.** In a nightly-batch warehouse the equivalent figure is the *average* age of data, roughly 12 hours and up to 24 — which means no operational decision (pricing, inventory reallocation, fraud hold, on-site staffing) can ever be made on it. Streaming changes the *class of question* the warehouse can answer, from retrospective to operational.

**A3.2** — It prevents a **silent schema break**: a mobile release that starts sending `revenue` as a string, or drops a field, would otherwise flow into the warehouse and corrupt every downstream report and model. Without schema enforcement, the people who discover it are the **business users**, weeks later, when a number looks wrong — and by then the bad data is inside models, dashboards and possibly financial statements. Enforcement at the topic makes it the *publisher's* build failure, immediately.

**A3.3** — Pub/Sub decouples **producers from consumers** in time, in throughput, and in count. Producers publish and get an ack without knowing who reads, how many readers exist, or whether they are healthy; Pub/Sub buffers (with a configurable retention window) and delivers when the consumer can keep up. On Black Friday, a slow consumer causes a **growing backlog**, not dropped events and not a stalled checkout page — the customer-facing system is never held hostage by the analytics system. Adding a second consumer (fraud detection, a real-time dashboard) later requires no change to the publisher at all.

**A3.4** — Any two of: (i) **transformation or enrichment in flight** — joining against a reference dataset, currency conversion, PII masking before landing; (ii) **windowed aggregation** — you want per-minute totals in BigQuery, not raw events; (iii) **multiple sinks or conditional routing** — same stream to BigQuery, Bigtable and Cloud Storage, or bad records to a dead-letter table; (iv) **complex deduplication or exactly-once semantics** beyond what the subscription gives; (v) **online ML inference** on each event.

### Exercise 4

**A4.1** — A **hopping (sliding) window** of 5-minute length with a 30-second (or shorter) period. The window *length* is the business definition of "recent"; the *period* is how often you re-evaluate and can alert. A tumbling 5-minute window would be wrong because a spike straddling a boundary could be diluted across two windows and never trip the threshold, and you would learn about it up to 5 minutes late.

**A4.2** — Because the boundary is defined by the **data**, not by the clock: a session ends when a particular key has been silent for the gap duration, so the window's length and end time differ per user and are unknowable in advance. The system must maintain **per-key state** plus a timer, and hold that state until the gap elapses. This is exactly why session windows are a managed-streaming-engine feature (Dataflow/Beam) rather than something you bolt onto a cron job.

**A4.3** — **Event time** is when the event actually occurred (stamped by the producer); **processing time** is when the pipeline saw it. They diverge with network delay, offline buffering, retries and backlogs. A **watermark** is the pipeline's running estimate of "event time up to which I believe I have seen everything" — it is how the system decides a window may be closed and emitted. Data arriving after the watermark passes its window is **late data**, and by default Dataflow **discards** it. You change that with `withAllowedLateness` plus a trigger and an accumulation mode, so late records either update the previously emitted result or land in a separate correction stream. The business consequence: a 20-minute offline buffer means you must either accept a 20-minute allowed lateness (and therefore late corrections to already-published numbers) or accept that those events never appear.

**A4.4** — (i) The **development project** — writing, testing and maintaining Apache Beam code, and the specialist skills to do it. (ii) The **operations project** — Dataflow autoscales workers, handles worker failure and rebalancing, and manages state and checkpointing; nobody sizes or babysits a streaming cluster. What remains yours is the *semantics*: which window, what lateness, what schema.

**A4.5** — **Drain** stops accepting new input but finishes processing everything in flight, closing and emitting open windows, so no in-flight data is lost — the correct choice for a healthy job. **Cancel** stops immediately and discards buffered in-flight state. You use cancel when the pipeline is producing corrupt output, because draining would flush that corruption into the sink.

### Exercise 5

**A5.1** — (i) **Automatic incremental refresh**: BigQuery updates only the changed partitions of a materialized view as the base table changes, rather than recomputing everything on a schedule; the data is fresh between refreshes because BigQuery reads the delta from the base table. (ii) **Automatic query rewrite**: queries written against the *base table* are silently redirected to the view by the optimizer, so no dashboard, report or user needs to know the view exists. A scheduled summary table gives you neither — every consumer must be pointed at it manually, and it is stale between runs.

**A5.2** — Order of action: **partitioning/clustering** acts in the storage layer (which bytes get read), **materialized views** act in the query-planning layer (which computation gets skipped), **BI Engine** acts in the execution layer (an in-memory cache of the data serving the query). Reach for **BI Engine last** — it is a paid, always-on reservation that makes an inefficient query fast without making it *cheap*, and it will happily paper over a schema problem that partitioning would have fixed for free.

**A5.3** — **Connected Sheets.** It solves (i) the **staleness/consistency** problem — the sheet queries BigQuery live rather than holding a frozen extract, so everyone sees one version of the truth; and (ii) the **governance/leakage** problem — the rows never leave BigQuery and never land in an email attachment, so IAM, row-level security and audit logging still apply. It also removes the row limit: analysts pivot over billions of rows through a spreadsheet interface. The change-management cost is near zero, which is the real reason it works.

**A5.4** — (a) **Looker Studio** — free, self-service, fast to stand up, sharing like a Google Doc. (b) **Looker** — governed semantic modelling layer (LookML), version-controlled in Git, with embedded analytics for the partner portal. The separating word is **governance** (equivalently: the *semantic model*). Looker Studio lets every author define "net revenue" their own way; Looker defines it once, centrally, and every consumer inherits it.

### Exercise 6

**A6.1** — Classic workflow: export/extract data from the warehouse → move it to a data-science environment → build features → train in Python/R → serialize the model → build and operate a serving/inference service → schedule a job to write predictions back. The three steps that disappeared are **data movement/export**, **a separate training environment**, and **a separate prediction-serving path** — the model is an object inside the dataset and `ML.FORECAST` is just SQL. The two risks that disappeared are (i) **data-governance risk** — a copy of production data on a laptop or in a second system, outside your IAM and audit boundary; and (ii) **training/serving skew** — features computed one way in the notebook and another way in production, which is the single most common cause of silently degrading models.

**A6.2** — Because a point forecast conveys false precision and hides the risk the buyer is actually managing. An inventory buyer's decision is asymmetric: stocking out costs a lost sale and a lost customer, while over-stocking costs carrying cost and markdown. They need the **distribution** — "80% confident revenue lands between 35k and 47k" — to choose a service level. A single number invites the buyer to plan for a scenario with, at best, a 50% chance of being exceeded, with no signal about volatility. Publishing an interval also makes the model honest: when the interval is enormous, everyone can see the forecast is not trustworthy yet.

**A6.3** — BigQuery ML stops being right when you need (i) **unstructured data** — images, audio, video, free text beyond simple embeddings; (ii) **custom architectures or frameworks** — bespoke deep learning, custom loss functions, distributed GPU/TPU training; (iii) **low-latency online serving** — millisecond per-request inference from an application; or (iv) a **full MLOps lifecycle** — experiment tracking, model registry, continuous evaluation and retraining pipelines. You move to **Vertex AI**. Note these compose: BigQuery ML models can be registered in and served from Vertex AI, and Vertex AI can read training data directly from BigQuery.

**A6.4** — (a) **ARIMA_PLUS** — forecasting daily demand per SKU, call-centre volume, or cloud spend, with holiday and seasonality effects. (b) **LOGISTIC_REG** — predicting which subscribers will churn next month, or whether a transaction is fraudulent (binary classification with a probability you can threshold on business cost). (c) **KMEANS** — unsupervised customer segmentation for marketing, discovering natural groupings nobody labelled in advance. (d) **MATRIX_FACTORIZATION** — a product recommendation engine from purchase or view history ("customers like you also bought").

### Exercise 7

**A7.1** — Because the BI tool is not the only door. The same table is reachable from the BigQuery console, the `bq` CLI, Connected Sheets, a Python notebook, a second BI tool, a scheduled export, and the API. Filtering in the BI tool secures **one** of those doors and leaves the rest open, and every new tool re-opens the question. Enforcing at the data layer means the policy is evaluated by the engine itself, applies identically to every access path, cannot be bypassed by rewriting the query, and is audited in one place. It also means the policy survives a change of BI vendor.

**A7.2** — **Row-level security** (row access policies) controls *which rows* a principal sees, based on a filter predicate — e.g. a regional sales manager sees only their region's orders. **Column-level security** (policy tags from Dataplex/Data Catalog plus IAM) controls *which columns* a principal can read at all — e.g. only the fraud team can select `card_number`; everyone else gets an access-denied error on that column. **Dynamic data masking** applies a policy tag but returns a *transformed* value instead of an error — e.g. analysts see `****1234` or a hash, so the query still runs and joins still work, without exposing the raw value. Use masking when the column must remain usable; use column-level denial when it must not be touched.

**A7.3** — (a) **CSV email**: cost is human labour and it scales linearly with 400 suppliers; freshness is whenever someone remembered to send it; you create 400 uncontrolled copies with no revocation, no audit and real leakage risk. (b) **Authorized views**: freshness is live, one copy, revocable per supplier, audited — but you must manage 400 IAM grants and each supplier needs to be reachable in your Google Cloud identity model, and *you* pay for their queries unless they query from their own project. (c) **Analytics Hub**: freshness is live, still exactly one copy of the data (a listing is a pointer, not a replica), subscribers add it to their own project as a linked dataset and **pay for their own compute**, onboarding is self-serve rather than a ticket per supplier, and you keep a subscriber list you can revoke. For 400 partners, (c) is the answer; (b) is the mechanism you would build (c) out of by hand.

**A7.4** — Dataplex adds the layer *above* individual datasets: a unified **catalog and search** across BigQuery and Cloud Storage, **business metadata and policy tags** that travel with the data, **data quality and profiling** rules, **lineage**, and **lakes/zones** that let you apply governance consistently across many projects. A 5-dataset organization can hold the map in one person's head and grant IAM directly. A 200-dataset organization cannot answer "where does this number come from, who owns it, is it trustworthy, and does it contain PII?" without a catalog — and unanswerable versions of those questions are exactly what causes leadership to stop trusting the platform.

### Exercise 8

**A8.1 — the drill table**

| # | Product | Why |
|---|---|---|
| 1 | **Dataflow** (+ Pub/Sub ingest, **Bigtable** for the profile lookup) | Sub-second, stateful stream processing with enrichment against a low-latency store; a warehouse cannot answer inside the authorization window. |
| 2 | **Dataproc** | Managed Hadoop/Spark: existing Spark and Hive jobs lift-and-shift with minimal rewrite, which is the constraint. (Rewriting to Dataflow is the *better long-term* answer but violates the 6-month/minimal-rewrite requirement.) |
| 3 | **Datastream** | Serverless change data capture from Oracle/MySQL/PostgreSQL into BigQuery, log-based so it does not load the source with queries. |
| 4 | **Cloud Data Fusion** | Graphical, code-free ETL pipeline builder (CDAP-based) aimed exactly at non-coders, with connectors and scheduling. |
| 5 | **Cloud Composer** | Managed Apache Airflow: DAG orchestration with dependencies, retries, SLAs and heterogeneous operators. It schedules *work*; it does not process the data itself. |
| 6 | **Bigtable** | Single-digit-millisecond reads at massive, sustained key-value throughput with linear scaling; BigQuery is a warehouse, not a low-latency serving store. |
| 7 | **Looker** | LookML semantic layer: one governed metric definition, version-controlled, consumed by dashboards, Sheets and embedded portals alike. |
| 8 | **Looker Studio** | Free, immediate, shareable visualization directly on BigQuery; no modelling layer needed for a one-off chart. |
| 9 | **Analytics Hub** | Publish once as a listing; subscribers get a linked dataset that queries in place with their own compute. No copies, no publisher egress. |
| 10 | **BigQuery Omni** (with **BigLake** tables) | Runs BigQuery compute in AWS/Azure against data in place, joinable with BigQuery data via one SQL interface — no copy pipeline. |
| 11 | **BigQuery ML** | Train and predict in SQL where the data already is; matches the team's skills and avoids data movement. |
| 12 | **Dataflow** (fed by **Pub/Sub**) | Hopping windows, watermarks and autoscaling at millions of events/second; this is stream processing, not orchestration. |

**A8.1 (question)** — The criterion is **who does the work and what already exists**. Dataproc exists to preserve an **existing investment in Hadoop/Spark code and skills** — its value is migration compatibility. Data Fusion exists to let **people who cannot write code** author new pipelines — its value is the visual interface. If the scenario mentions existing Spark/Hive jobs or a Hadoop estate, it is Dataproc; if it mentions non-technical users, drag-and-drop, or "without writing code", it is Data Fusion.

**A8.2** — Composer is wrong for 12 because Airflow is a **scheduler/orchestrator**: it triggers tasks on a schedule or dependency, with per-task granularity measured in seconds-to-minutes. It has no concept of windows, watermarks or per-event state, and cannot process 2M events/second. Dataflow is wrong for 5 because a 40-step DAG spanning BigQuery jobs, Cloud Storage and an external API with retries and SLAs is **workflow coordination across heterogeneous systems**, not a data-processing graph — you would be reimplementing Airflow inside a pipeline. In practice they compose: Composer *launches* Dataflow jobs.

**A8.3** — "They produce the same-looking picture but solve opposite problems: Looker Studio lets anyone define a metric, and Looker guarantees everyone uses the *same* definition — for a CFO's net margin appearing in a partner-facing portal, an inconsistent definition is a reporting risk, not a UI preference."

### Exercise 9

**A9.1** — The rule: **on-demand wins when consumption is low or spiky relative to the slot capacity you would have to reserve; editions win when consumption is high and steady enough to keep a slot baseline busy.** The crossover is essentially "do you scan enough data per slot-hour to beat $6.25/TiB". The non-financial reason to choose editions anyway is **cost predictability and workload management**: editions give a hard ceiling on spend (a runaway query cannot produce a surprise invoice — it just queues), plus reservation assignments that isolate the BI workload from an ad-hoc analyst workload, and features tied to the edition tier. Many organizations choose editions to make the number *knowable*, not to make it smaller.

**A9.2** — Any two of: (i) **Keep all history online.** Because storing data costs nothing to compute against until queried, and long-term storage is discounted automatically after 90 days of no modification, you never face the "archive it to tape or delete it" decision that a coupled appliance forces — so a question about 7-year-old data remains answerable. (ii) **Scale compute for a one-off.** A quarter-end or an ML training run can consume enormous compute for hours and then release it, without buying hardware that idles for the rest of the year. (iii) **Share data without duplicating it** — Analytics Hub subscribers bring their own compute to your storage, which is only coherent when the two are billed separately. (iv) **Charge back accurately** — each team pays for the questions it asks, not a share of a box.

**A9.3** — Example: *"Today our clickstream reaches the warehouse in a nightly batch, so the earliest anyone can react to a merchandising problem is the following morning. By streaming the same events through Pub/Sub into BigQuery, they are queryable within seconds, with schema validation at the door so a bad app release cannot corrupt reporting. Concretely, this means that when a promoted product's add-to-cart-to-checkout conversion collapses at 10 a.m. — because a price is wrong, stock is misreported, or the payment step is failing on one device — we detect it within minutes and pull or fix the promotion the same morning, instead of reading about it in tomorrow's report after a full day of lost margin. The decision that becomes possible is intra-day merchandising intervention; the pipeline runs without a dedicated cluster or an ETL team, and the same stream feeds real-time fraud checks and inventory reallocation later without changing anything on the publishing side."*

</details>

---

## Official sources

- Google Cloud, *Cloud Digital Leader — Exam Guide*: https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- BigQuery overview: https://cloud.google.com/bigquery/docs/introduction
- Partitioned tables: https://cloud.google.com/bigquery/docs/partitioned-tables · Clustered tables: https://cloud.google.com/bigquery/docs/clustered-tables
- Materialized views: https://cloud.google.com/bigquery/docs/materialized-views-intro · BI Engine: https://cloud.google.com/bigquery/docs/bi-engine-intro
- BigQuery pricing: https://cloud.google.com/bigquery/pricing · Editions: https://cloud.google.com/bigquery/docs/editions-intro
- BigQuery ML `CREATE MODEL`: https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create · Time-series models: https://cloud.google.com/bigquery/docs/arima-single-time-series-forecasting-tutorial
- Row-level security: https://cloud.google.com/bigquery/docs/row-level-security-intro · Authorized views: https://cloud.google.com/bigquery/docs/authorized-views · Column-level security: https://cloud.google.com/bigquery/docs/column-level-security-intro
- Analytics Hub: https://cloud.google.com/bigquery/docs/analytics-hub-introduction · BigQuery Omni: https://cloud.google.com/bigquery/docs/omni-introduction
- Pub/Sub overview: https://cloud.google.com/pubsub/docs/overview · BigQuery subscriptions: https://cloud.google.com/pubsub/docs/bigquery · Schemas: https://cloud.google.com/pubsub/docs/schemas
- Dataflow overview: https://cloud.google.com/dataflow/docs/overview · Streaming pipelines: https://cloud.google.com/dataflow/docs/concepts/streaming-pipelines · Beam windowing: https://beam.apache.org/documentation/programming-guide/#windowing
- Dataproc: https://cloud.google.com/dataproc/docs/concepts/overview · Cloud Data Fusion: https://cloud.google.com/data-fusion/docs/concepts/overview · Datastream: https://cloud.google.com/datastream/docs/overview · Cloud Composer: https://cloud.google.com/composer/docs/concepts/overview
- Bigtable: https://cloud.google.com/bigtable/docs/overview · Dataplex: https://cloud.google.com/dataplex/docs/introduction
- Looker: https://cloud.google.com/looker/docs/intro · Looker Studio: https://cloud.google.com/looker/docs/studio · Connected Sheets: https://cloud.google.com/bigquery/docs/connected-sheets