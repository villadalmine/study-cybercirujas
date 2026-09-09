# Topic 2.1 — Guided Exercises
## Describe the intrinsic role that data plays in an organization's digital transformation

**Certification:** Google Cloud Digital Leader (exam guide version 2026-08-12) · **Section 2 weight:** 6.0

---

### What you are going to build

These exercises are not a slideshow. You will stand up a miniature version of the exact architecture an enterprise builds when it stops treating data as exhaust and starts treating it as an asset — and at each step you will be asked *why the business cares*, because that is what the exam tests.

```
                 ┌──────────────────────────────────────────────────────────┐
                 │  SOURCES (siloed today)                                  │
                 │  finance CSV   support NDJSON   call transcript TXT      │
                 │  + operational system of record (public dataset)         │
                 └───────────────┬──────────────────────────────────────────┘
                                 │  gcloud storage cp
                 ┌───────────────▼──────────────────────────────────────────┐
   DATA LAKE     │  gs://…-cdl-data-lake   (raw, schema-on-read)            │
                 └───────────────┬──────────────────────────────────────────┘
                                 │  external tables  /  bq load
                 ┌───────────────▼──────────────────────────────────────────┐
   WAREHOUSE     │  BigQuery  cdl_lake  (federated)  ·  cdl_warehouse (native)│
                 └───┬───────────────────────────────┬──────────────────────┘
                     │                               │
   GOVERNANCE  ◄─────┤ authorized views · policy tags │─────►  ACTIVATION
   residency, IAM,   │ lifecycle, retention          │        CAC / ROAS,
   column masking    └───────────────┬───────────────┘        decision memo
                                     │
                 ┌───────────────────▼──────────────────────────────────────┐
   VELOCITY      │  Pub/Sub topic ──► BigQuery subscription (streaming)      │
                 └──────────────────────────────────────────────────────────┘
```

### Prerequisites

| Requirement | Check |
|---|---|
| Google Cloud project with billing enabled | `gcloud billing projects describe $(gcloud config get-value project)` |
| `gcloud` ≥ 460 and `bq` CLI (both ship in Cloud Shell) | `gcloud version` |
| Roles on the project | `roles/bigquery.admin`, `roles/storage.admin`, `roles/pubsub.admin`, `roles/datacatalog.admin` |
| Time | ~150 minutes |

### Cost guardrails — read before you start

Every query in this lab is dry-run costed first. On-demand BigQuery bills **bytes scanned**, not rows returned, and the first 1 TiB per month is free; Cloud Storage gives 5 GiB-months free in US regions. Executed as written, this lab scans well under 5 GiB and stores under 100 MiB. It is designed to land inside the free tier, but *verify the current figures yourself* — pricing is versioned, your memory is not: <https://cloud.google.com/bigquery/pricing>.

> **All command outputs below are illustrative.** `bigquery-public-data.thelook_ecommerce` is a synthetic dataset that is regenerated and rolls forward in time, so row counts and dates on your run **will** differ. Several steps deliberately make you re-measure instead of trusting the printed number. That habit *is* part of the objective.

---

## Exercise 0 — Prepare the lab environment

**Concept anchor:** before data can be an asset it needs a place to live, an owner, and a bill. Those three things are the practical content of "data strategy."

1. Open Cloud Shell (or a local shell with `gcloud` authenticated) and pin your variables. Every later exercise assumes these are exported.

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export BQ_LOCATION="US"                 # must match the public dataset's location
export BUCKET="gs://${PROJECT_ID}-cdl-data-lake"
echo "project=$PROJECT_ID number=$PROJECT_NUMBER bucket=$BUCKET"
```

2. Enable the APIs the lab uses. Enabling an API is itself a governance act — it is the moment a capability becomes available *and* billable in that project.

```bash
gcloud services enable \
  bigquery.googleapis.com \
  storage.googleapis.com \
  pubsub.googleapis.com \
  datacatalog.googleapis.com \
  bigquerydatapolicy.googleapis.com
```

```
Operation "operations/acat.p2-000000000000-xxxxxxxx" finished successfully.
```

3. Create the landing zone — the data lake — with uniform bucket-level access, so permissions are expressed **only** through IAM and never through per-object ACLs.

```bash
gcloud storage buckets create "$BUCKET" \
  --location="$BQ_LOCATION" \
  --uniform-bucket-level-access \
  --public-access-prevention
```

```
Creating gs://my-project-cdl-data-lake/...
```

4. Create the two BigQuery datasets that will represent the two halves of the modern data platform.

```bash
bq --location="$BQ_LOCATION" mk -d \
  --description "Raw zone: federated, schema-on-read" "${PROJECT_ID}:cdl_lake"

bq --location="$BQ_LOCATION" mk -d \
  --description "Curated zone: native, schema-on-write, governed" "${PROJECT_ID}:cdl_warehouse"

bq ls --format=pretty
```

```
  datasetId
 ----------------
  cdl_lake
  cdl_warehouse
```

### Check your understanding

- **Q0.1** — You created the bucket and both datasets in the `US` multi-region. What concrete operation would fail later if you had put the bucket in `europe-west1` and the datasets in `US`?
- **Q0.2** — `--public-access-prevention` and `--uniform-bucket-level-access` were set at creation time, not afterwards. Why does the *order* matter for a data governance programme, and what class of incident is each flag preventing?
- **Q0.3** — In digital-transformation language, what is the difference between "we enabled the BigQuery API" and "we have a data strategy"?

---

## Exercise 1 — Inventory the data: three shapes, one landing zone

**Concept anchor:** the exam expects you to distinguish **structured**, **semi-structured** and **unstructured** data, and to know that the majority of enterprise data is the third kind — the kind traditional databases were never able to hold.

1. Generate one file of each shape. These stand in for three departments that today do not talk to each other: Finance, Support, and the contact centre.

```bash
mkdir -p ~/cdl21 && cd ~/cdl21

# STRUCTURED — fixed schema, one row per fact. Lives in a spreadsheet on someone's laptop today.
cat > marketing_spend.csv <<'CSV'
channel,month,spend_usd,impressions
Search,2026-06,42000,3100000
Search,2026-07,45500,3350000
Search,2026-08,44100,3280000
Organic,2026-06,8000,1900000
Organic,2026-07,8200,2010000
Organic,2026-08,8100,1980000
Facebook,2026-06,31000,5200000
Facebook,2026-07,36800,6100000
Facebook,2026-08,39400,6450000
Email,2026-06,6500,880000
Email,2026-07,6700,910000
Email,2026-08,6600,905000
Display,2026-06,27500,9800000
Display,2026-07,26900,9600000
Display,2026-08,28300,10100000
CSV

# SEMI-STRUCTURED — self-describing, nested, ragged. Newline-delimited JSON.
cat > support_tickets.json <<'JSON'
{"ticket_id":"T-1001","opened_at":"2026-06-03T09:12:00Z","channel":"Email","priority":"P2","tags":["shipping","delay"],"customer":{"segment":"retail","country":"US"},"csat":3}
{"ticket_id":"T-1002","opened_at":"2026-06-04T14:41:00Z","channel":"Phone","priority":"P1","tags":["payment","declined","urgent"],"customer":{"segment":"retail","country":"BR"},"csat":2}
{"ticket_id":"T-1003","opened_at":"2026-07-11T08:05:00Z","channel":"Chat","priority":"P3","tags":["sizing"],"customer":{"segment":"wholesale","country":"US"},"csat":5}
{"ticket_id":"T-1004","opened_at":"2026-07-19T17:33:00Z","channel":"Email","priority":"P2","tags":["shipping","damage"],"customer":{"segment":"retail","country":"DE"}}
{"ticket_id":"T-1005","opened_at":"2026-08-02T11:20:00Z","channel":"Phone","priority":"P1","tags":["payment","declined"],"customer":{"segment":"retail","country":"US"},"csat":1}
JSON

# UNSTRUCTURED — no schema at all. The single largest data class in most enterprises.
cat > call_2026-08-02.txt <<'TXT'
[00:00] Agent: Thank you for calling, how can I help?
[00:04] Customer: My card was declined three times on checkout and I have been
        charged twice anyway. This is the second time this month.
[00:21] Agent: I am seeing two pending authorisations on the order.
[00:38] Customer: If this is not fixed today I am cancelling the account.
TXT
```

2. Land all three in the lake, partitioned by source system — not by content type. Prefixes are the lake's only navigational structure.

```bash
gcloud storage cp marketing_spend.csv   "$BUCKET/raw/finance/"
gcloud storage cp support_tickets.json  "$BUCKET/raw/support/"
gcloud storage cp call_2026-08-02.txt   "$BUCKET/raw/contact-center/"
```

3. Ask object storage what it thinks it is holding.

```bash
gcloud storage ls --long --recursive "$BUCKET/raw/**"
```

```
       681  2026-09-06T12:04:11Z  gs://my-project-cdl-data-lake/raw/contact-center/call_2026-08-02.txt
       542  2026-09-06T12:04:09Z  gs://my-project-cdl-data-lake/raw/finance/marketing_spend.csv
      1104  2026-09-06T12:04:10Z  gs://my-project-cdl-data-lake/raw/support/support_tickets.json
TOTAL: 3 objects, 2327 bytes.
```

4. Inspect the metadata of the unstructured object specifically.

```bash
gcloud storage objects describe "$BUCKET/raw/contact-center/call_2026-08-02.txt" \
  --format="yaml(name,size,content_type,storage_class,time_created,md5_hash)"
```

```yaml
content_type: text/plain
md5_hash: 9v2c1s0kQe5m3d7hZ1kQ9A==
name: raw/contact-center/call_2026-08-02.txt
size: '681'
storage_class: STANDARD
time_created: '2026-09-06T12:04:11Z'
```

### Check your understanding

- **Q1.1** — Classify each of the three files as structured, semi-structured or unstructured, and name the *property* that decides the classification. It is not the file extension.
- **Q1.2** — Cloud Storage returned exactly the same metadata fields for all three objects: size, content type, hash, class. What does that uniformity tell you about why object storage — not a relational database — became the foundation of the data lake pattern?
- **Q1.3** — `T-1004` has no `csat` field while the other four tickets do. In a relational table that row would be impossible or would carry a `NULL`. What is the business consequence of a storage layer that accepts ragged records without complaint — name one benefit and one risk.
- **Q1.4** — The call transcript contains the single most valuable sentence in the entire lab ("this is the second time this month", "I am cancelling the account"). Which of the three files is *hardest* to turn into a number on a dashboard, and which Google Cloud capability class closes that gap?
- **Q1.5** — Nothing in this exercise queried anything. In the data value chain **data → information → insight → action**, which stage have you completed, and what is the value of stopping here?

---

## Exercise 2 — Data lake vs data warehouse: schema-on-read vs schema-on-write

**Concept anchor:** the lake and the warehouse are not competing products, they are two different moments in the life of a fact. The exam wants the trade-off, not a winner.

1. Create an **external table** over the raw CSV. Note that nothing is copied and nothing is validated — the schema is invented at query time.

```bash
bq mkdef --source_format=CSV --autodetect \
  "$BUCKET/raw/finance/*.csv" > /tmp/spend_def.json

bq mk --external_table_definition=/tmp/spend_def.json \
  "${PROJECT_ID}:cdl_lake.marketing_spend_ext"

cat /tmp/spend_def.json
```

```json
{
  "autodetect": true,
  "csvOptions": { "encoding": "UTF-8", "quote": "\"" },
  "sourceFormat": "CSV",
  "sourceUris": [ "gs://my-project-cdl-data-lake/raw/finance/*.csv" ]
}
```

2. Do the same for the nested JSON, and look at what autodetect made of the nested `customer` object and the missing `csat`.

```bash
bq mkdef --source_format=NEWLINE_DELIMITED_JSON --autodetect \
  "$BUCKET/raw/support/*.json" > /tmp/tickets_def.json

bq mk --external_table_definition=/tmp/tickets_def.json \
  "${PROJECT_ID}:cdl_lake.support_tickets_ext"

bq show --schema --format=prettyjson "${PROJECT_ID}:cdl_lake.support_tickets_ext"
```

```json
[
  {"name": "ticket_id", "type": "STRING", "mode": "NULLABLE"},
  {"name": "opened_at", "type": "TIMESTAMP", "mode": "NULLABLE"},
  {"name": "channel",   "type": "STRING", "mode": "NULLABLE"},
  {"name": "priority",  "type": "STRING", "mode": "NULLABLE"},
  {"name": "tags",      "type": "STRING", "mode": "REPEATED"},
  {"name": "customer",  "type": "RECORD", "mode": "NULLABLE",
   "fields": [
     {"name": "segment", "type": "STRING", "mode": "NULLABLE"},
     {"name": "country", "type": "STRING", "mode": "NULLABLE"}]},
  {"name": "csat",      "type": "INT64",  "mode": "NULLABLE"}
]
```

3. Query the semi-structured external table with the nesting flattened. `UNNEST` is how a warehouse reads a document without first destroying its shape.

```bash
bq query --use_legacy_sql=false --format=pretty '
SELECT
  tag,
  COUNT(*)          AS tickets,
  ROUND(AVG(csat),2) AS avg_csat,
  COUNTIF(csat IS NULL) AS csat_missing
FROM `'"$PROJECT_ID"'.cdl_lake.support_tickets_ext`, UNNEST(tags) AS tag
GROUP BY tag
ORDER BY tickets DESC'
```

```
+----------+---------+----------+--------------+
|   tag    | tickets | avg_csat | csat_missing |
+----------+---------+----------+--------------+
| shipping |       2 |      3.0 |            1 |
| payment  |       2 |      1.5 |            0 |
| declined |       2 |      1.5 |            0 |
| delay    |       1 |      3.0 |            0 |
| damage   |       1 |     NULL |            1 |
| sizing   |       1 |      5.0 |            0 |
| urgent   |       1 |      2.0 |            0 |
+----------+---------+----------+--------------+
```

4. Now promote the finance file into the **warehouse**: a native, managed, columnar table. This is schema-on-write — the load either conforms or it fails.

```bash
bq load \
  --source_format=CSV \
  --skip_leading_rows=1 \
  --autodetect \
  --replace \
  "${PROJECT_ID}:cdl_warehouse.marketing_spend" \
  "$BUCKET/raw/finance/marketing_spend.csv"

bq show --format=prettyjson "${PROJECT_ID}:cdl_warehouse.marketing_spend" \
  | grep -E '"(numRows|numBytes|type)"'
```

```
  "numBytes": "465",
  "numRows": "15",
  "type": "TABLE"
```

5. Cost-estimate both paths without running them. `--dry_run` is the single most useful habit in BigQuery.

```bash
bq query --use_legacy_sql=false --dry_run \
  'SELECT SUM(spend_usd) FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend`'

bq query --use_legacy_sql=false --dry_run \
  'SELECT SUM(spend_usd) FROM `'"$PROJECT_ID"'.cdl_lake.marketing_spend_ext`'
```

```
Query successfully validated. Assuming the tables are not modified,
running this query will process 168 bytes of data.

Query successfully validated. Assuming the tables are not modified,
running this query will process 0 bytes of data.
```

> For a **native** table BigQuery knows the exact compressed size of each column and returns a precise, billable byte count — here only the `spend_usd` column is read, not the whole row. For an **external** table it has not parsed the objects, so the estimate is not a reliable cost signal; you may see `0`, or the full object size, depending on format. Predictable cost is a warehouse property.

### Check your understanding

- **Q2.1** — `bq mkdef --autodetect` inferred `csat` as `INT64` from five rows, one of which had no `csat` at all. Describe the failure mode when a sixth ticket arrives tomorrow with `"csat":"n/a"`. At which moment does the failure surface in the lake pattern versus the warehouse pattern, and which is cheaper for the business?
- **Q2.2** — Contrast the two dry-run outputs. Which of the two storage patterns lets a CFO forecast next quarter's analytics bill, and why?
- **Q2.3** — The external table stores zero bytes of its own and the native table duplicated the data. Give one business scenario where paying twice for storage is unambiguously the right call, and one where it is waste.
- **Q2.4** — Map these four Google Cloud products to the role they play with data: **Cloud SQL**, **Cloud Storage**, **BigQuery**, **Cloud Spanner**. Use the terms *transactional system of record (OLTP)*, *analytical warehouse (OLAP)*, *object/data lake*, *globally distributed relational*.
- **Q2.5** — An executive says "let's just put everything in the data lake and decide later." State the strongest argument in favour and the failure this strategy is famous for producing.

---

## Exercise 3 — From data to information: the query that answers a business question

**Concept anchor:** raw data has no value. Value appears only when a question is asked of it — and the exam frames this as *data-driven decision-making*.

1. First, find out what the operational system of record actually contains. Never write a business query against a schema you have not verified.

```bash
bq query --use_legacy_sql=false --format=pretty '
SELECT
  MIN(created_at) AS first_user,
  MAX(created_at) AS last_user,
  COUNT(*)        AS total_users,
  COUNT(DISTINCT traffic_source) AS channels
FROM `bigquery-public-data.thelook_ecommerce.users`'
```

```
+---------------------+---------------------+-------------+----------+
|     first_user      |      last_user      | total_users | channels |
+---------------------+---------------------+-------------+----------+
| 2019-01-02 03:14:07 | 2026-09-05 22:51:33 |      100482 |        5 |
+---------------------+---------------------+-------------+----------+
```

2. Confirm the channel names — they must match your finance CSV exactly or the join in Exercise 4 will silently drop rows.

```bash
bq query --use_legacy_sql=false --format=pretty '
SELECT traffic_source, COUNT(*) AS users
FROM `bigquery-public-data.thelook_ecommerce.users`
GROUP BY traffic_source ORDER BY users DESC'
```

```
+----------------+-------+
| traffic_source | users |
+----------------+-------+
| Search         | 70119 |
| Organic        | 15053 |
| Facebook       |  7521 |
| Email          |  5028 |
| Display        |  2761 |
+----------------+-------+
```

> **If your `last_user` is earlier than 2026-08-31**, the synthetic dataset has rolled to different dates. Adjust the `'2026-06-01'`/`'2026-08-31'` literals in the next steps to the last three complete months you actually have, and edit `marketing_spend.csv` to match, then re-run the `bq load` from Exercise 2 step 4.

3. Dry-run the business question before you run it.

```bash
export Q_NEWCUST='
SELECT
  traffic_source AS channel,
  FORMAT_DATE("%Y-%m", DATE(created_at)) AS month,
  COUNT(*) AS new_customers
FROM `bigquery-public-data.thelook_ecommerce.users`
WHERE DATE(created_at) BETWEEN "2026-06-01" AND "2026-08-31"
GROUP BY channel, month'

bq query --use_legacy_sql=false --dry_run "$Q_NEWCUST"
bq query --use_legacy_sql=false --format=pretty "$Q_NEWCUST"
```

```
Query successfully validated. Assuming the tables are not modified,
running this query will process 2411896 bytes of data.

+----------+---------+---------------+
| channel  |  month  | new_customers |
+----------+---------+---------------+
| Search   | 2026-06 |          1602 |
| Search   | 2026-07 |          1655 |
| Search   | 2026-08 |          1698 |
| Organic  | 2026-06 |           343 |
| ...      | ...     |           ... |
| Display  | 2026-08 |            64 |
+----------+---------+---------------+
```

4. Note what BigQuery did *not* read. The `users` table has ~15 columns; the query touched two.

```bash
bq show --format=prettyjson bigquery-public-data:thelook_ecommerce.users \
  | grep -E '"(numRows|numBytes)"'
```

```
  "numBytes": "18874368",
  "numRows": "100482"
```

### Check your understanding

- **Q3.1** — The full `users` table is ~18 MB but the dry run reported ~2.4 MB. Explain the mechanism, and state why *columnar storage* is an economic fact and not a technical detail.
- **Q3.2** — Step 1 and step 2 produced no business insight whatsoever. Why is running them before the "real" query a professional obligation rather than a delay?
- **Q3.3** — At this point you have counts of new customers per channel per month. Is that **data**, **information**, or **insight**? Justify using the value-chain definitions, and state precisely what is still missing to reach *action*.
- **Q3.4** — The dataset is synthetic and rolls forward, which is why the lab told you to verify `MIN`/`MAX` instead of trusting the printed dates. Name the equivalent real-world hazard in an enterprise warehouse and the governance discipline that addresses it.

---

## Exercise 4 — Breaking the silo: the join that neither system could do alone

**Concept anchor:** this is the heart of objective 2.1. Marketing spend lives in Finance. Customer acquisition lives in the e-commerce platform. Neither department can compute **cost per acquired customer**. The value is created by the *join*, not by either dataset.

1. Compute CAC (Customer Acquisition Cost) by joining your uploaded finance data to the operational system of record.

```bash
bq query --use_legacy_sql=false --format=pretty '
WITH new_users AS (
  SELECT
    traffic_source AS channel,
    FORMAT_DATE("%Y-%m", DATE(created_at)) AS month,
    COUNT(*) AS new_customers
  FROM `bigquery-public-data.thelook_ecommerce.users`
  WHERE DATE(created_at) BETWEEN "2026-06-01" AND "2026-08-31"
  GROUP BY channel, month
)
SELECT
  s.channel,
  SUM(s.spend_usd)                                          AS spend_usd,
  SUM(n.new_customers)                                      AS new_customers,
  ROUND(SUM(s.spend_usd) / NULLIF(SUM(n.new_customers),0),2) AS cac_usd
FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend` s
JOIN new_users n USING (channel, month)
GROUP BY s.channel
ORDER BY cac_usd'
```

```
+----------+-----------+---------------+---------+
| channel  | spend_usd | new_customers | cac_usd |
+----------+-----------+---------------+---------+
| Search   |    131600 |          4955 |   26.56 |
| Organic  |     24300 |          1031 |   23.57 |
| Email    |     19800 |           341 |   58.06 |
| Facebook |    107200 |           522 |  205.36 |
| Display  |     82700 |           190 |  435.26 |
+----------+-----------+---------------+---------+
```

2. CAC alone is a trap: a channel can be expensive to acquire and still be the most profitable. Add the revenue side to get **ROAS** (Return on Ad Spend).

```bash
bq query --use_legacy_sql=false --format=pretty '
WITH cohort AS (
  SELECT id AS user_id, traffic_source AS channel,
         FORMAT_DATE("%Y-%m", DATE(created_at)) AS month
  FROM `bigquery-public-data.thelook_ecommerce.users`
  WHERE DATE(created_at) BETWEEN "2026-06-01" AND "2026-08-31"
),
revenue AS (
  SELECT c.channel, c.month, SUM(oi.sale_price) AS revenue_usd
  FROM cohort c
  JOIN `bigquery-public-data.thelook_ecommerce.order_items` oi
    ON oi.user_id = c.user_id
  WHERE oi.status NOT IN ("Cancelled","Returned")
  GROUP BY c.channel, c.month
)
SELECT
  s.channel,
  SUM(s.spend_usd)                    AS spend_usd,
  ROUND(SUM(r.revenue_usd),2)         AS revenue_usd,
  ROUND(SUM(r.revenue_usd)/SUM(s.spend_usd),2) AS roas
FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend` s
JOIN revenue r USING (channel, month)
GROUP BY s.channel
ORDER BY roas DESC'
```

```
+----------+-----------+-------------+------+
| channel  | spend_usd | revenue_usd | roas |
+----------+-----------+-------------+------+
| Organic  |     24300 |   118442.51 | 4.87 |
| Search   |    131600 |   541903.77 | 4.12 |
| Email    |     19800 |    39118.06 | 1.98 |
| Facebook |    107200 |    61550.44 | 0.57 |
| Display  |     82700 |    21987.90 | 0.27 |
+----------+-----------+-------------+------+
```

3. Persist the joined result as a curated table. This is the moment a one-off query becomes a shared organisational fact.

```bash
bq query --use_legacy_sql=false --format=pretty '
CREATE OR REPLACE TABLE `'"$PROJECT_ID"'.cdl_warehouse.channel_performance`
OPTIONS(description="Channel CAC/ROAS. Source: finance CSV + thelook_ecommerce. Owner: growth-analytics@") AS
WITH cohort AS (
  SELECT id AS user_id, traffic_source AS channel,
         FORMAT_DATE("%Y-%m", DATE(created_at)) AS month
  FROM `bigquery-public-data.thelook_ecommerce.users`
  WHERE DATE(created_at) BETWEEN "2026-06-01" AND "2026-08-31"
),
rev AS (
  SELECT c.channel, c.month,
         COUNT(DISTINCT c.user_id) AS new_customers,
         SUM(oi.sale_price)        AS revenue_usd
  FROM cohort c
  LEFT JOIN `bigquery-public-data.thelook_ecommerce.order_items` oi
    ON oi.user_id = c.user_id AND oi.status NOT IN ("Cancelled","Returned")
  GROUP BY c.channel, c.month
)
SELECT s.channel, s.month, s.spend_usd, s.impressions,
       rev.new_customers,
       IFNULL(rev.revenue_usd,0) AS revenue_usd,
       ROUND(s.spend_usd / NULLIF(rev.new_customers,0),2) AS cac_usd,
       ROUND(IFNULL(rev.revenue_usd,0) / NULLIF(s.spend_usd,0),2) AS roas
FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend` s
LEFT JOIN rev ON rev.channel = s.channel AND rev.month = s.month'
```

```
Created my-project.cdl_warehouse.channel_performance
```

### Check your understanding

- **Q4.1** — Rank the five channels by CAC and then by ROAS. Which channel changes position most dramatically between the two rankings, and what wrong decision would a CAC-only dashboard have produced?
- **Q4.2** — Neither the Finance team nor the e-commerce team could compute either number on their own. Name the phenomenon in one term, and explain why it is described as an *organisational* problem more often than a *technical* one.
- **Q4.3** — Step 3 replaced an inner `JOIN` with a `LEFT JOIN` and wrapped revenue in `IFNULL(...,0)`. Which channel-month rows would silently disappear under the inner join, and how does silent row loss destroy trust in a dashboard faster than an obvious error?
- **Q4.4** — The `CREATE TABLE` carries `OPTIONS(description=...)` naming a source and an owner. Which two governance properties does that one line establish, and why is an undocumented curated table sometimes worse than no table at all?
- **Q4.5** — Your CFO asks: "we already had both these numbers in two spreadsheets — what did the cloud actually add?" Give the two-sentence answer an architect should give.

---

## Exercise 5 — Data quality: what one duplicated row does to a decision

**Concept anchor:** governance is not paperwork. Bad data does not produce *no* decision, it produces a *confidently wrong* one — which is strictly more expensive.

1. Create a realistically dirty version of the finance file. One duplicated row (a double export), one NULL spend (a failed extract), one month typo (manual entry).

```bash
cd ~/cdl21
cat > marketing_spend_dirty.csv <<'CSV'
channel,month,spend_usd,impressions
Search,2026-06,42000,3100000
Search,2026-06,42000,3100000
Search,2026-07,45500,3350000
Search,2026-08,44100,3280000
Organic,2026-06,8000,1900000
Organic,2026-07,8200,2010000
Organic,2026-08,8100,1980000
Facebook,2026-06,31000,5200000
Facebook,2026-07,36800,6100000
Facebook,2026-08,39400,6450000
Email,2026-06,6500,880000
Email,2026-07,,910000
Email,2026-08,6600,905000
Display,2026-06,27500,9800000
Display,2026-7,26900,9600000
Display,2026-08,28300,10100000
CSV

gcloud storage cp marketing_spend_dirty.csv "$BUCKET/raw/finance-dirty/"

bq load --source_format=CSV --skip_leading_rows=1 --autodetect --replace \
  "${PROJECT_ID}:cdl_warehouse.marketing_spend_dirty" \
  "$BUCKET/raw/finance-dirty/marketing_spend_dirty.csv"
```

```
Waiting on bqjob_r4f1a... (1s) Current status: DONE
```

> Observe: the load **succeeded**. Schema-on-write validates *types*, not *truth*.

2. Profile the table before trusting it. This four-metric block is the minimum viable data-quality check and should exist for every curated table.

```bash
bq query --use_legacy_sql=false --format=pretty '
SELECT
  COUNT(*)                                              AS rows_total,
  COUNT(*) - COUNT(DISTINCT FORMAT("%s|%s", channel, month)) AS duplicate_keys,
  COUNTIF(spend_usd IS NULL)                            AS null_spend,
  COUNTIF(NOT REGEXP_CONTAINS(month, r"^\d{4}-\d{2}$")) AS malformed_month,
  ROUND(SUM(spend_usd),2)                               AS spend_total
FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend_dirty`'
```

```
+------------+----------------+------------+-----------------+-------------+
| rows_total | duplicate_keys | null_spend | malformed_month | spend_total |
+------------+----------------+------------+-----------------+-------------+
|         16 |              1 |          1 |               1 |    399900.0 |
+------------+----------------+------------+-----------------+-------------+
```

3. Now watch the KPI move. Recompute Search CAC from the dirty table and compare to the clean one.

```bash
bq query --use_legacy_sql=false --format=pretty '
WITH new_users AS (
  SELECT traffic_source AS channel,
         FORMAT_DATE("%Y-%m", DATE(created_at)) AS month,
         COUNT(*) AS new_customers
  FROM `bigquery-public-data.thelook_ecommerce.users`
  WHERE DATE(created_at) BETWEEN "2026-06-01" AND "2026-08-31"
  GROUP BY channel, month
),
dirty AS (
  SELECT s.channel, SUM(s.spend_usd) sp, SUM(n.new_customers) nc
  FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend_dirty` s
  JOIN new_users n USING (channel, month) GROUP BY 1
),
clean AS (
  SELECT s.channel, SUM(s.spend_usd) sp, SUM(n.new_customers) nc
  FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend` s
  JOIN new_users n USING (channel, month) GROUP BY 1
)
SELECT clean.channel,
       ROUND(clean.sp/clean.nc,2) AS cac_clean,
       ROUND(dirty.sp/dirty.nc,2) AS cac_dirty,
       ROUND(100*((dirty.sp/dirty.nc)/(clean.sp/clean.nc)-1),1) AS pct_error
FROM clean JOIN dirty USING (channel)
ORDER BY ABS(pct_error) DESC'
```

```
+----------+-----------+-----------+-----------+
| channel  | cac_clean | cac_dirty | pct_error |
+----------+-----------+-----------+-----------+
| Display  |    435.26 |    287.11 |     -34.0 |
| Email    |     58.06 |     38.44 |     -33.8 |
| Search   |     26.56 |     33.06 |      24.5 |
| Organic  |     23.57 |     23.57 |       0.0 |
+----------+-----------+-----------+-----------+
```

4. Write the quality rule as an enforceable assertion rather than a convention in a wiki.

```bash
bq query --use_legacy_sql=false '
ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT FORMAT("%s|%s", channel, month))
     AND COUNTIF(spend_usd IS NULL) = 0
  FROM `'"$PROJECT_ID"'.cdl_warehouse.marketing_spend_dirty`
) AS "marketing_spend: duplicate or NULL spend rows detected — do not publish"'
```

```
Error in query string: ASSERT failed: marketing_spend: duplicate or NULL
spend rows detected — do not publish
```

### Check your understanding

- **Q5.1** — Only one Search row was duplicated, yet **Display** and **Email** show a ~34 % error and Display and Search move in *opposite directions*. Trace the mechanism. Why is an error that propagates to untouched rows more dangerous than one that stays local?
- **Q5.2** — Trace each of the three defects to the human or system process that produced it: the duplicate, the NULL, the `2026-7`. Which of the three would a stricter *schema* have caught, and which two require a *rule*?
- **Q5.3** — Based on `cac_dirty` alone, which channel would a growth team have doubled down on, and what is the real-world cost of that decision over a quarter?
- **Q5.4** — The `ASSERT` failed the job with a non-zero exit. Explain why *failing loudly and publishing nothing* is the correct default for a data pipeline, and contrast it with the alternative of publishing a dashboard with a warning banner.
- **Q5.5** — Give the one-sentence version of why "data quality" is listed as a *digital transformation* topic and not an IT hygiene topic.

---

## Exercise 6 — Governance I: least privilege, authorized views, column-level security

**Concept anchor:** the value of data rises with how many people can use it, and the risk rises with how many people can see all of it. Governance is what makes those two curves separable.

1. Build a curated customer table containing genuine PII.

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE `'"$PROJECT_ID"'.cdl_warehouse.customers`
OPTIONS(description="Customer master. Contains PII: email. Owner: data-privacy@") AS
SELECT id, first_name, last_name, email, age, gender, country, state,
       traffic_source, created_at
FROM `bigquery-public-data.thelook_ecommerce.users`
LIMIT 50000'

bq query --use_legacy_sql=false --format=pretty '
SELECT country, COUNT(*) c FROM `'"$PROJECT_ID"'.cdl_warehouse.customers`
GROUP BY country ORDER BY c DESC LIMIT 5'
```

```
+---------------+-------+
|    country    |   c   |
+---------------+-------+
| China         | 17204 |
| United States | 10339 |
| Brasil        |  7011 |
| South Korea   |  3588 |
| Germany       |  3132 |
+---------------+-------+
```

2. Create an **authorized view** that exposes analysis-grade data with no PII. Analysts get the view; nobody gets the base table.

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE VIEW `'"$PROJECT_ID"'.cdl_warehouse.customers_analytics`
OPTIONS(description="PII-free projection of cdl_warehouse.customers for analysts") AS
SELECT
  id,
  CASE WHEN age < 25 THEN "18-24"
       WHEN age < 35 THEN "25-34"
       WHEN age < 50 THEN "35-49"
       ELSE "50+" END AS age_band,
  gender, country, traffic_source,
  DATE(created_at) AS signup_date
FROM `'"$PROJECT_ID"'.cdl_warehouse.customers`'
```

3. Grant at the smallest scope that works. `GRANT` at the *schema* level is the DCL equivalent of the principle of least privilege.

```bash
# Replace with a real principal in your organisation, or a test service account.
export ANALYST="user:analyst@example.com"

bq query --use_legacy_sql=false '
GRANT `roles/bigquery.dataViewer`
ON SCHEMA `'"$PROJECT_ID"'.cdl_warehouse`
TO "'"$ANALYST"'"'

bq query --use_legacy_sql=false --format=pretty '
SELECT grantee, role, object_name
FROM `'"$PROJECT_ID"'`.`region-us`.INFORMATION_SCHEMA.OBJECT_PRIVILEGES
WHERE object_name = "cdl_warehouse"'
```

```
+---------------------------+----------------------------+--------------+
|          grantee          |            role            | object_name  |
+---------------------------+----------------------------+--------------+
| user:analyst@example.com  | roles/bigquery.dataViewer  | cdl_warehouse|
+---------------------------+----------------------------+--------------+
```

4. Add **column-level security** so the `email` column is protected even from people who legitimately hold table access.

```bash
gcloud data-catalog taxonomies create \
  --location=us --project="$PROJECT_ID" \
  --display-name="cdl-pii" \
  --activated-policy-types=FINE_GRAINED_ACCESS_CONTROL

export TAXONOMY="$(gcloud data-catalog taxonomies list --location=us \
  --project="$PROJECT_ID" --filter='displayName=cdl-pii' --format='value(name)')"

gcloud data-catalog taxonomies policy-tags create \
  --location=us --taxonomy="${TAXONOMY##*/}" \
  --display-name="high-sensitivity--email"

export POLICY_TAG="$(gcloud data-catalog taxonomies policy-tags list \
  --location=us --taxonomy="${TAXONOMY##*/}" --format='value(name)')"
echo "$POLICY_TAG"
```

```
projects/my-project/locations/us/taxonomies/1234567890123456789/policyTags/9876543210987654321
```

5. Attach the tag to the column by patching the table schema.

```bash
bq show --schema --format=prettyjson "${PROJECT_ID}:cdl_warehouse.customers" > /tmp/cust_schema.json

python3 - "$POLICY_TAG" <<'PY'
import json, sys
tag = sys.argv[1]
s = json.load(open('/tmp/cust_schema.json'))
for f in s:
    if f['name'] == 'email':
        f['policyTags'] = {'names': [tag]}
json.dump(s, open('/tmp/cust_schema.json','w'), indent=2)
print("tagged email ->", tag)
PY

bq update --schema /tmp/cust_schema.json "${PROJECT_ID}:cdl_warehouse.customers"
```

```
Table 'my-project:cdl_warehouse.customers' successfully updated.
```

6. Test the control against yourself. You are the project owner — that is exactly the point.

```bash
bq query --use_legacy_sql=false \
  'SELECT email FROM `'"$PROJECT_ID"'.cdl_warehouse.customers` LIMIT 5'
```

```
Access Denied: BigQuery BigQuery: User does not have permission to access
policy tag "cdl-pii : high-sensitivity--email" on column
cdl_warehouse.customers.email.
```

```bash
bq query --use_legacy_sql=false --format=pretty \
  'SELECT * EXCEPT(email) FROM `'"$PROJECT_ID"'.cdl_warehouse.customers` LIMIT 3'
```

```
+-------+------------+-----------+-----+--------+---------------+
|  id   | first_name | last_name | age | gender |    country    |
+-------+------------+-----------+-----+--------+---------------+
| 41022 | Maria      | Santos    |  34 | F      | Brasil        |
| 68113 | Wei        | Zhang     |  27 | M      | China         |
| 10485 | Anna       | Keller    |  51 | F      | Germany       |
+-------+------------+-----------+-----+--------+---------------+
```

7. Grant yourself the fine-grained reader role only when there is a documented reason, and observe access return.

```bash
gcloud data-catalog taxonomies policy-tags add-iam-policy-binding "$POLICY_TAG" \
  --location=us \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/datacatalog.categoryFineGrainedReader"
```

> If your `gcloud` build does not expose `policy-tags add-iam-policy-binding`, do the same grant in the Console under **Dataplex → Policy tags → cdl-pii → high-sensitivity--email → Manage permissions**. The IAM effect is identical.

### Check your understanding

- **Q6.1** — Step 6 denied *you*, the project Owner. Which principle does that demonstrate, and why is "the admin can always read everything" an unacceptable posture under GDPR-class regulation?
- **Q6.2** — You now have two independent controls over `email`: the authorized view (which omits it) and the policy tag (which blocks it). Are they redundant? Give the scenario each one catches that the other does not.
- **Q6.3** — The view converts `age` into `age_band`. Name the privacy technique, and explain why it *increases* the number of teams that can safely use the table.
- **Q6.4** — Rank these grants from least to most privileged for an analyst who needs channel performance: `roles/bigquery.admin` on the project · `roles/bigquery.dataViewer` on `cdl_warehouse` · `roles/bigquery.dataViewer` on `customers_analytics` only. Which would you actually issue, and what is the operational cost of the most restrictive choice?
- **Q6.5** — A business unit argues that governance controls slow analytics down and reduce the value of the data platform. Rebut it in two sentences using this exercise as evidence.

---

## Exercise 7 — Governance II: residency, retention, lifecycle — where data is allowed to live

**Concept anchor:** for regulated industries, *where* a byte physically sits is a legal fact before it is a technical one. Cloud makes location an explicit, enforceable configuration.

1. Create an EU-resident dataset and bucket, representing a subsidiary bound by EU data residency.

```bash
bq --location=EU mk -d --description "EU-resident zone" "${PROJECT_ID}:cdl_warehouse_eu"

gcloud storage buckets create "gs://${PROJECT_ID}-cdl-eu" \
  --location=europe-west1 --uniform-bucket-level-access --public-access-prevention
```

2. Attempt to copy US data into the EU dataset. This must fail — and the failure is the deliverable.

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE `'"$PROJECT_ID"'.cdl_warehouse_eu.customers_copy` AS
SELECT * EXCEPT(email) FROM `'"$PROJECT_ID"'.cdl_warehouse.customers`'
```

```
BigQuery error in query operation: Not found: Dataset
my-project:cdl_warehouse was not found in location EU
```

> BigQuery will not silently move data across locations. The engine treats a region as a hard boundary — the same boundary the regulator is describing in prose.

3. Confirm the same boundary applies to Cloud Storage and BigQuery together.

```bash
gcloud storage cp ~/cdl21/marketing_spend.csv "gs://${PROJECT_ID}-cdl-eu/raw/finance/"

bq mkdef --source_format=CSV --autodetect \
  "gs://${PROJECT_ID}-cdl-eu/raw/finance/*.csv" > /tmp/eu_def.json
bq mk --external_table_definition=/tmp/eu_def.json \
  "${PROJECT_ID}:cdl_lake.spend_eu_ext"

bq query --use_legacy_sql=false \
  'SELECT COUNT(*) FROM `'"$PROJECT_ID"'.cdl_lake.spend_eu_ext`'
```

```
BigQuery error in query operation: Cannot read and write in different
locations. Source: EU, Destination: US
```

4. Express the retention policy as code. Raw data cools, then it is deleted — because keeping data past its legal purpose is a *liability*, not an asset.

```bash
cat > /tmp/lifecycle.json <<'JSON'
{
  "lifecycle": {
    "rule": [
      { "action": { "type": "SetStorageClass", "storageClass": "NEARLINE" },
        "condition": { "age": 30, "matchesPrefix": ["raw/"] } },
      { "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "age": 90, "matchesPrefix": ["raw/"] } },
      { "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "age": 365, "matchesPrefix": ["raw/finance/"] } },
      { "action": { "type": "Delete" },
        "condition": { "age": 2555, "matchesPrefix": ["raw/"] } }
    ]
  }
}
JSON

gcloud storage buckets update "$BUCKET" --lifecycle-file=/tmp/lifecycle.json
gcloud storage buckets describe "$BUCKET" --format="yaml(lifecycle_config)"
```

```yaml
lifecycle_config:
  rule:
  - action: {storageClass: NEARLINE, type: SetStorageClass}
    condition: {age: 30, matchesPrefix: [raw/]}
  - action: {storageClass: COLDLINE, type: SetStorageClass}
    condition: {age: 90, matchesPrefix: [raw/]}
  - action: {storageClass: ARCHIVE, type: SetStorageClass}
    condition: {age: 365, matchesPrefix: [raw/finance/]}
  - action: {type: Delete}
    condition: {age: 2555, matchesPrefix: [raw/]}
```

5. Add a retention policy on the EU bucket — the "cannot be deleted early" half of compliance, which is the mirror image of step 4.

```bash
gcloud storage buckets update "gs://${PROJECT_ID}-cdl-eu" --retention-period=2555d
gcloud storage buckets describe "gs://${PROJECT_ID}-cdl-eu" \
  --format="yaml(retention_policy)"
```

```yaml
retention_policy:
  effective_time: '2026-09-06T12:41:03Z'
  is_locked: false
  retention_period: '220752000'
```

> **Do not run `--lock-retention-period` in a lab account.** Locking is irreversible: the bucket and every object in it become undeletable until the period expires — seven years, in this configuration. That irreversibility is precisely what makes it acceptable evidence to an auditor.

### Check your understanding

- **Q7.1** — Two different error messages appeared in steps 2 and 3. State what each one proves about how location is enforced, and why an engineering control beats a written policy for a regulator.
- **Q7.2** — Step 4 deletes at 2555 days; step 5 forbids deletion before 2555 days. Describe the compliance requirement that needs *both*, and name the risk each one alone leaves open.
- **Q7.3** — The lifecycle rules move objects STANDARD → NEARLINE → COLDLINE → ARCHIVE. What is the trade-off being purchased at each hop, and why is it safe for `raw/` but would be dangerous for a table backing a live dashboard?
- **Q7.4** — Explain why "we keep all our data forever, just in case" is a *risk* position and not a *value* position, using two distinct arguments (one financial, one legal).
- **Q7.5** — A multinational wants a single global customer 360 view but is subject to EU residency. Given what you just observed, sketch the two architectural options and name the trade-off each accepts.

---

## Exercise 8 — Velocity: batch, streaming, and the shelf life of an insight

**Concept anchor:** data has a half-life. A fraud signal is worth a great deal for ninety seconds and nothing the next morning; a board revenue number is worth the same on Tuesday as on Monday. Velocity is a business requirement, not a technology preference.

1. Create the streaming ingestion path.

```bash
gcloud pubsub topics create orders-stream

bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE `'"$PROJECT_ID"'.cdl_warehouse.orders_stream` (
  order_id   STRING  NOT NULL,
  channel    STRING,
  amount_usd NUMERIC,
  created_at TIMESTAMP
)
PARTITION BY DATE(created_at)
OPTIONS(description="Real-time order events via Pub/Sub BigQuery subscription")'
```

2. Grant the Pub/Sub service agent permission to write. Nothing streams until this identity exists and is authorized.

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor" \
  --condition=None
```

3. Create the BigQuery subscription — managed streaming ingestion with no code and no pipeline to operate.

```bash
gcloud pubsub subscriptions create orders-to-bq \
  --topic=orders-stream \
  --bigquery-table="${PROJECT_ID}:cdl_warehouse.orders_stream" \
  --use-table-schema
```

```
Created subscription [projects/my-project/subscriptions/orders-to-bq].
```

4. Publish events and time the round trip yourself.

```bash
for i in 1 2 3 4 5; do
  gcloud pubsub topics publish orders-stream --message="$(cat <<EOF
{"order_id":"O-90${i}","channel":"Search","amount_usd":$((40 + i * 7)).50,"created_at":"2026-09-06T13:0${i}:00Z"}
EOF
)"
done

sleep 15

bq query --use_legacy_sql=false --format=pretty '
SELECT order_id, channel, amount_usd, created_at
FROM `'"$PROJECT_ID"'.cdl_warehouse.orders_stream`
ORDER BY created_at'
```

```
+----------+---------+------------+---------------------+
| order_id | channel | amount_usd |     created_at      |
+----------+---------+------------+---------------------+
| O-901    | Search  |      47.50 | 2026-09-06 13:01:00 |
| O-902    | Search  |      54.50 | 2026-09-06 13:02:00 |
| O-903    | Search  |      61.50 | 2026-09-06 13:03:00 |
| O-904    | Search  |      68.50 | 2026-09-06 13:04:00 |
| O-905    | Search  |      75.50 | 2026-09-06 13:05:00 |
| O-906    | Display |     129.00 | 2026-09-06 13:06:00 |
+----------+---------+------------+---------------------+
```

5. Publish a malformed message and find out where bad data goes in a streaming world.

```bash
gcloud pubsub topics publish orders-stream --message='{"order_id":"O-BAD","amount_usd":"forty dollars"}'
sleep 10
gcloud pubsub subscriptions describe orders-to-bq \
  --format="yaml(bigqueryConfig,deadLetterPolicy)"
```

```yaml
bigqueryConfig:
  state: ACTIVE
  table: my-project.cdl_warehouse.orders_stream
  useTableSchema: true
```

> The message could not be parsed into the table schema. With no dead-letter topic configured it is retried and eventually dropped — **silently**. In batch, a bad row fails a job someone is watching; in streaming, a bad row disappears unless you built somewhere for it to go.

6. Compare the two ingestion paths you have now built, side by side.

| | **Batch** (`bq load`, Ex. 2) | **Streaming** (Pub/Sub → BigQuery, Ex. 8) |
|---|---|---|
| Latency to queryable | minutes to hours | seconds |
| Failure surface | job fails, visible, re-runnable | message dropped, needs dead-letter topic |
| Cost model | free load, pay storage | pay per ingested byte + storage |
| Correction | reload the file | replay from the topic, if retention allows |
| Fits | financial close, board reporting, ML training sets | fraud, inventory, personalisation, alerting |

### Check your understanding

- **Q8.1** — For each of these, decide batch or streaming and justify in one line: (a) monthly board revenue pack, (b) card-fraud scoring at checkout, (c) "customers also bought" on a product page, (d) annual regulatory filing, (e) warehouse stock-out alerting.
- **Q8.2** — Step 5's bad message vanished without an error anyone would see. Name the Pub/Sub feature that fixes it, and explain why *undetected* loss is worse for trust than a loud pipeline failure.
- **Q8.3** — The `orders_stream` table is `PARTITION BY DATE(created_at)`. Explain how that one clause changes both the cost and the speed of "yesterday's orders", and connect it to the columnar-billing point from Q3.1.
- **Q8.4** — You wrote no pipeline code, deployed no server, and the subscription scales itself. Name the two operating-model shifts this represents for an IT department, in the vocabulary the exam uses.
- **Q8.5** — An executive asks to "make everything real-time." Give the two questions you would ask before agreeing, and state the cost dimension they are probing.

---

## Exercise 9 — Capstone: the value chain end to end, and what it cost

**Concept anchor:** you can now assemble the argument the objective actually asks for — *why* data is intrinsic to digital transformation, evidenced by artefacts you built rather than asserted.

1. Inventory everything you created and place each artefact in the value chain.

```bash
bq ls --format=pretty "${PROJECT_ID}:cdl_lake"
bq ls --format=pretty "${PROJECT_ID}:cdl_warehouse"
gcloud storage ls --recursive "$BUCKET/**"
gcloud pubsub subscriptions list --format="value(name,bigqueryConfig.table)"
```

2. Measure what the whole lab consumed. Spend that is not measured is not managed.

```bash
bq query --use_legacy_sql=false --format=pretty '
SELECT
  COUNT(*)                                   AS jobs,
  SUM(total_bytes_processed)                 AS bytes_scanned,
  ROUND(SUM(total_bytes_processed)/POW(2,30),3) AS gib_scanned,
  ROUND(SUM(total_bytes_billed)/POW(2,40) * 6.25, 4) AS approx_usd_on_demand
FROM `'"$PROJECT_ID"'`.`region-us`.INFORMATION_SCHEMA.JOBS_BY_USER
WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
  AND job_type = "QUERY" AND state = "DONE"'
```

```
+------+---------------+-------------+----------------------+
| jobs | bytes_scanned | gib_scanned | approx_usd_on_demand |
+------+---------------+-------------+----------------------+
|   27 |     104857600 |       0.098 |               0.0006 |
+------+---------------+-------------+----------------------+
```

> The `6.25` is the on-demand USD-per-TiB rate at the time of writing; confirm it against <https://cloud.google.com/bigquery/pricing> rather than trusting the constant. `total_bytes_billed` differs from `total_bytes_processed` because of the 10 MB per-table minimum.

3. Read back the artefact you would actually hand to a business stakeholder.

```bash
bq query --use_legacy_sql=false --format=pretty '
SELECT channel,
       SUM(spend_usd)   AS spend,
       SUM(new_customers) AS customers,
       ROUND(SUM(spend_usd)/NULLIF(SUM(new_customers),0),2) AS cac,
       ROUND(SUM(revenue_usd)/NULLIF(SUM(spend_usd),0),2)   AS roas
FROM `'"$PROJECT_ID"'.cdl_warehouse.channel_performance`
GROUP BY channel ORDER BY roas DESC'
```

4. Fill in this table from your own run. It is the exam objective, expressed as evidence.

| Value-chain stage | Artefact you built | Google Cloud product | Business capability unlocked |
|---|---|---|---|
| Source / silo | 3 files, 3 departments | — | *(you fill in)* |
| Ingest | `gcloud storage cp`, Pub/Sub topic | | |
| Store (raw) | `gs://…/raw/**` | | |
| Store (curated) | `cdl_warehouse.*` native tables | | |
| Process | external tables, `CREATE TABLE AS` | | |
| Analyse | CAC / ROAS queries | | |
| Activate | `channel_performance` | | |
| Govern | authorized view, policy tag, lifecycle, residency | | |
| Assure | `ASSERT`, profiling query | | |

### Check your understanding — exam-level

- **Q9.1** — In two sentences, using the ROAS table as your evidence, state why data is *intrinsic* to digital transformation rather than a supporting function of it.
- **Q9.2** — Name the four barriers to becoming data-driven that this lab demonstrated concretely, and cite the exercise that demonstrated each.
- **Q9.3** — A company says: "we have twelve years of history in an on-premises data warehouse, we already are data-driven." Give three questions that test the claim, each targeting a different property you exercised in this lab.
- **Q9.4** — Place each product in the value chain in one word: **Pub/Sub**, **Cloud Storage**, **Dataflow**, **BigQuery**, **Dataplex Universal Catalog**, **Looker**, **Vertex AI**, **Cloud SQL**.
- **Q9.5** — The whole lab cost under one US cent to query. Which resource was actually scarce here, and what does that shift imply about where the bottleneck in a data programme now sits?
- **Q9.6** — Which single artefact from Exercise 9 step 1 would you delete first if the CISO ordered an immediate reduction in data risk, and what business capability would you lose?

---

## Cleanup

Run this when finished. Everything created is destroyed; nothing outside the lab is touched.

```bash
gcloud pubsub subscriptions delete orders-to-bq --quiet
gcloud pubsub topics delete orders-stream --quiet

bq rm -r -f -d "${PROJECT_ID}:cdl_lake"
bq rm -r -f -d "${PROJECT_ID}:cdl_warehouse"
bq rm -r -f -d "${PROJECT_ID}:cdl_warehouse_eu"

# The policy tag must be detached from any live schema before the taxonomy is deleted.
gcloud data-catalog taxonomies delete "${TAXONOMY##*/}" --location=us --quiet

gcloud storage rm --recursive "$BUCKET"
# The EU bucket carries an UNLOCKED 2555d retention policy: clear it before deleting.
gcloud storage buckets update "gs://${PROJECT_ID}-cdl-eu" --clear-retention-period
gcloud storage rm --recursive "gs://${PROJECT_ID}-cdl-eu"

rm -rf ~/cdl21
```

> If you had run `--lock-retention-period` in Exercise 7 step 5, this cleanup would fail and the bucket would remain, billable, for seven years. That is the lesson, not a footnote.

---

## Answer key

<details>
<summary><b>Click to reveal all answers (Exercises 0–9)</b></summary>

### Exercise 0

**Q0.1** — Any operation that reads and writes across the two locations: creating a BigQuery external table over that bucket, or `bq load`ing from it into a `US` dataset. BigQuery requires the dataset and the Cloud Storage bucket to be in compatible locations; you would get `Cannot read and write in different locations. Source: EU, Destination: US` — which is exactly the error you deliberately produce in Exercise 7 step 3. Location is chosen once, at creation, and a dataset's location cannot be changed afterwards. (<https://cloud.google.com/bigquery/docs/locations>)

**Q0.2** — Both flags are far easier to set on an empty bucket than to retrofit onto one holding a million objects with heterogeneous per-object ACLs, where turning uniform access on can revoke access that something in production silently depends on. Governance applied at creation is a design decision; governance applied later is a migration project with an outage attached. **Uniform bucket-level access** prevents the "one object was granted to `allUsers` by a script three years ago and nobody can audit it" class of incident by removing per-object ACLs entirely. **Public access prevention** blocks the single most common cloud data breach: a storage bucket unintentionally exposed to the internet.

**Q0.3** — Enabling an API creates a *capability*. A data strategy answers questions the API cannot: which decisions the organisation intends to make with data, who owns each dataset, what quality bar it must meet, how long it may be retained, who may see it, and how the value is measured. The technology is the cheap part — this lab's compute cost under a cent — while the ownership, quality and governance answers are the expensive part and the part that determines whether the platform gets used.

### Exercise 1

**Q1.1** —
- `marketing_spend.csv` → **structured**: a fixed, pre-declared schema; every record has the same fields in the same order, and the schema lives outside the data.
- `support_tickets.json` → **semi-structured**: it carries its own schema inline (self-describing keys), permits nesting (`customer.segment`), repetition (`tags`), and ragged records (`T-1004` has no `csat`).
- `call_2026-08-02.txt` → **unstructured**: no schema at all, inline or external. It has *meaning* but no fields.

The deciding property is **where the schema lives**, not the extension: external and fixed → structured; inline and flexible → semi-structured; absent → unstructured. A `.json` file could be a rigid schema, and a `.csv` column could contain free text.

**Q1.2** — Cloud Storage is completely indifferent to content: it stores bytes plus metadata and never validates. That indifference is the whole point. A relational database rejects anything that does not fit its schema, which means it can only hold data you already understood at design time. Object storage accepts anything at very low cost, which lets an organisation land data *before* knowing what question it will answer — the defining property of the data lake pattern, and the reason it became the foundation layer rather than the database. (<https://cloud.google.com/learn/what-is-a-data-lake>)

**Q1.3** — **Benefit:** the source system can evolve — add `csat`, add a field, change a producer — without breaking ingestion or requiring a schema migration. Data keeps arriving during change instead of being lost, and time-to-ingest for a new source drops from weeks to hours. **Risk:** nothing detects that `csat` is missing. It silently becomes `NULL`, `AVG(csat)` is computed over an unannounced subset, and the reported figure is a *survivorship-biased* average that looks entirely legitimate on a dashboard. Flexibility at ingest is paid for with mandatory quality checks downstream — which is Exercise 5.

**Q1.4** — The **call transcript** is hardest: it contains the churn signal ("second time this month", "I am cancelling the account") in a form no `GROUP BY` can reach. The gap is closed by **AI/ML applied to unstructured data** — natural-language understanding for sentiment, entity and intent extraction; speech-to-text upstream of it; document understanding for scanned artefacts. This is why AI is not a separate topic from data: AI is the only mechanism that converts the *largest* category of enterprise data (commonly estimated at 80–90 % of the total) into rows a business can act on. (<https://cloud.google.com/use-cases/ai-data-analytics>)

**Q1.5** — Only the first stage: **data**. There is no information, no insight, no action. And that is still worth doing, for three reasons: the data exists in one durable, addressable, access-controlled place instead of on three laptops; it is now available to questions nobody has asked yet, including questions that will only be asked in two years; and landing it is cheap (fractions of a cent per GB-month) while *not* landing it is irreversible — data not captured today cannot be captured retroactively.

### Exercise 2

**Q2.1** — With `"csat":"n/a"`, autodetect's `INT64` inference no longer holds. **In the lake (external table, schema-on-read):** nothing happens at ingest — the file lands fine. The error surfaces at *query time*, for whoever happens to run the query, possibly weeks later, possibly a board member: `Could not parse 'n/a' as INT64`. Or worse, autodetect re-samples and silently promotes the column to `STRING`, which breaks every downstream `AVG(csat)` without any error at all. **In the warehouse (schema-on-write):** the `bq load` job fails immediately, with a named job ID, an owner, and a re-runnable artefact.

Warehouse failure is cheaper by a wide margin: it is detected in seconds by the person who caused it, it is contained (nothing bad was published), and the fix is obvious. Lake failure is detected late, by the wrong person, after decisions may already have been taken on the bad number. **Cost of defect ∝ time to detection.**

**Q2.2** — The **native table**. BigQuery maintains exact per-column compressed statistics, so `--dry_run` returns a precise, contractual byte count *before* the query runs — which is the basis of a cost estimate, a query-size guardrail (`--maximum_bytes_billed`), a chargeback model, and a quarterly forecast. For external tables BigQuery has not read or catalogued the objects, so the estimate is not a usable cost signal. Predictable spend is an argument *for* the curated warehouse layer, independent of performance.

**Q2.3** —
- **Right call:** any dataset that many people query repeatedly. Curating it once into a native table means the parse, type-cast and compression happen once rather than on every query. Duplicated storage costs cents per GB-month; the re-parsing avoided costs far more in query time, in compute, and in analyst hours. It also gives you a stable, described, governable object to grant access on and attach policy tags to.
- **Waste:** a large raw archive queried once or twice a year for compliance lookup, or one still in exploratory triage where nobody has decided what matters. Copying petabytes to serve two queries a year is pure cost — leave it in the lake and query it in place.

**Q2.4** —
- **Cloud SQL** — transactional system of record (OLTP): managed MySQL/PostgreSQL/SQL Server, row-oriented, optimised for many small reads and writes; where the order is *placed*. (<https://cloud.google.com/sql/docs/introduction>)
- **Cloud Storage** — object/data lake: the raw, schema-agnostic landing zone for any byte, any shape. (<https://cloud.google.com/storage/docs/introduction>)
- **BigQuery** — analytical warehouse (OLAP): columnar, serverless, separates storage from compute, optimised for scanning billions of rows to answer one question; where the order is *analysed*. (<https://cloud.google.com/bigquery/docs/introduction>)
- **Cloud Spanner** — globally distributed relational: OLTP semantics with strong external consistency and horizontal scale across regions; for a system of record that cannot be sharded and cannot go down. (<https://cloud.google.com/spanner/docs/overview>)

The recurring exam distinction: **OLTP runs the business, OLAP understands it.**

**Q2.5** — **In favour:** storage is cheap and the cost of *not* having data is unbounded and irreversible. You cannot retroactively collect last year's clickstream. Landing everything preserves optionality for questions the organisation has not thought of yet, and that optionality is genuinely valuable. **Famous failure:** the **data swamp** — a lake with no catalogue, no ownership, no quality metrics and no lineage, where the data is technically present and practically unusable, because nobody can tell which of the eleven `customers_final_v3` files is authoritative or whether it is complete. The fix is not to store less, it is to attach governance metadata *at landing time* — cataloguing, ownership, quality contracts, lifecycle. (<https://cloud.google.com/dataplex/docs/introduction>)

### Exercise 3

**Q3.1** — BigQuery stores data **column by column**, not row by row. The query referenced only `traffic_source` and `created_at`, so only those two columns' blocks were read; the other ~13 columns were never touched and were never billed. On-demand BigQuery bills bytes *scanned*, so the storage layout translates directly into the invoice: `SELECT *` on this table would have cost roughly 8× more than `SELECT traffic_source, created_at` for identical business value. That is why `SELECT *` is an anti-pattern in a warehouse rather than a style preference, and why partitioning and clustering — which prune whole blocks before the scan begins — are cost controls first and performance controls second. (<https://cloud.google.com/bigquery/docs/best-practices-costs>)

**Q3.2** — Because the alternative is publishing a number derived from an assumption you never tested. Concretely: had `traffic_source` contained `'facebook'` rather than `'Facebook'`, the join in Exercise 4 would have matched zero rows for that channel and returned a *shorter table* rather than an error — and a shorter table looks exactly like a correct table. Verifying cardinality, date range and domain values costs one cheap query and is the difference between an analysis and a guess. This is the analytical equivalent of reading the API contract before calling it.

**Q3.3** — It is **information**: data that has been aggregated, contextualised and given a unit ("1,602 new Search customers in June 2026"). It is not yet **insight**, because insight requires comparison against something that makes the number *mean* something — a target, a prior period, a cost, or another channel. Missing to reach **action**: the *cost* side (Exercise 4's join produces CAC, which finally makes channels comparable), a **decision rule** or threshold that says what to do at a given value, and an **owner** with the budget authority to act. A number nobody is empowered to act on is a report, not a decision.

**Q3.4** — The real-world equivalent is **schema and semantic drift**: an upstream team renames a column, changes a unit from cents to dollars, adds a sixth traffic source, or backfills history — all without telling anyone downstream, because they do not know who is downstream. The disciplines that address it: **data lineage** (know who consumes what before you change it), **data contracts** (the producer commits to a schema and a semantic, with a deprecation window), **freshness and volume monitoring** (alert when a table stops updating or its row count halves), and **cataloguing** so consumers are discoverable at all. This is the operational content of data governance. (<https://cloud.google.com/dataplex/docs/introduction>)

### Exercise 4

**Q4.1** — By CAC (cheapest first): Organic 23.57, Search 26.56, Email 58.06, Facebook 205.36, Display 435.26. By ROAS (best first): Organic 4.87, Search 4.12, Email 1.98, Facebook 0.57, Display 0.27. **Email** moves most sharply in *interpretation*: at $58 CAC it looks mid-pack and defensible, but at ROAS 1.98 it is only marginally profitable once you account for what those customers actually spend. The wrong decision from a CAC-only dashboard is more subtle and more expensive than "cut Display": it is **over-investing in Email** — a channel with acceptable acquisition cost that acquires low-value customers. CAC measures what you pay; ROAS measures what you get. A channel can be cheap to acquire and destroy value, or expensive to acquire and be the best investment you have. Never optimise a cost metric without its value counterpart.

**Q4.2** — The phenomenon is **data silos**. It is called organisational rather than technical because the technical fix here was one `JOIN` running in under two seconds — the difficulty was never the SQL. The real obstacles are that Finance and E-commerce have different owners, different budgets, different tools, different definitions of "customer", and no shared incentive to expose their data; that each team's KPIs are measured within its own boundary, so integration is uncompensated work; and that "our data is sensitive" is an unfalsifiable and career-safe reason to decline. That is why breaking silos is a **transformation** programme with executive sponsorship rather than a data-engineering ticket.

**Q4.3** — Under `JOIN` (inner), any channel-month with spend but *zero* attributable new customers or *zero* revenue vanishes from the result — a launched-but-failing channel, or a month where the extract ran early. The output is a valid-looking table with fewer rows. Silent row loss is corrosive because the failure is invisible: totals are lower but nothing is red, no job failed, no alert fired, and the number is *plausible*. A dashboard that is obviously broken gets fixed in an hour; a dashboard that is quietly 8 % low gets acted on for a quarter and then discovers the error, at which point every number the platform ever produced is suspect. The `LEFT JOIN` plus `IFNULL(...,0)` makes the failing channel appear with `revenue_usd = 0` and `roas = 0.0` — which is the *true* and actionable statement.

**Q4.4** — It establishes **provenance/lineage** (which sources this was derived from, so a consumer can judge whether it answers their question and an engineer knows what breaks it) and **ownership/stewardship** (a named team accountable for correctness, freshness and access decisions). An undocumented curated table is worse than none because it carries the *authority* of the warehouse — someone will find `channel_performance`, assume it is official, and use it — while carrying none of the *accountability*. Nobody can say what date range it covers, whether it still refreshes, or who to ask. Discoverability without provenance manufactures confident wrong answers at scale; this is precisely how a lake becomes a swamp.

**Q4.5** — "The spreadsheets each held half a number, and neither team could compute the whole one without a meeting — so the number effectively did not exist, and the decision was made on instinct. What the platform added is that the number now exists continuously, is governed and reproducible, refreshes without anyone's calendar, and can be joined to the *next* dataset without another negotiation."

### Exercise 5

**Q5.1** — The mechanism is the aggregation boundary. The duplicated Search row inflates Search spend, so Search CAC rises (26.56 → 33.06 — a genuine, local error). Display and Email did not change in absolute terms, but a **denominator or ranking shifted**: with total spend inflated by 42,000, every share-of-spend, index and relative comparison in the same report re-weights, and a channel whose absolute figures are untouched appears 34 % better or worse. Under a `SUM(...) OVER ()`, a percentage-of-total, or a normalisation step, one bad row contaminates *every* row in the report.

That propagation is what makes it dangerous. A locally wrong number can be spotted by the person who owns that channel — "our Search spend was never 174k". A globally propagated distortion has no such owner: the Display manager sees a number that is wrong for reasons entirely outside their data, cannot detect it by inspection, and has no reason to distrust it. This is why data quality must be enforced *at ingest*, before aggregation, not audited afterwards at the report.

**Q5.2** —
- **Duplicate row** → a process defect: an ETL job re-ran without idempotency, or someone exported the report twice and appended both. Requires a **rule** (uniqueness constraint on the business key `channel+month`, or idempotent merge-on-key ingestion). A schema cannot catch it: both rows are perfectly well-typed.
- **NULL `spend_usd`** → an upstream extract failure or an un-entered cell. A **stricter schema catches this one**: declaring the column `REQUIRED`/`NOT NULL` would have rejected the load outright. This is the one defect that a schema-on-write contract genuinely prevents.
- **`2026-7`** → manual entry without validation. Requires a **rule** (regex/format validation, or better, typing the column as `DATE` so the parse fails). As loaded into a `STRING` column it is a legal value; only a business rule knows the canonical format is `YYYY-MM`. Its real damage is that it *fails to join* — the row silently disappears from the CAC report rather than producing an error.

The general lesson: schemas enforce **shape**, rules enforce **meaning**, and the majority of real data defects are meaning defects.

**Q5.3** — **Display**, at an apparent CAC of $287 versus its true $435 — and worse, a team looking only at the dirty numbers sees Display and Email as the improving channels while Search appears to be degrading. The real cost over a quarter: budget shifted *away* from the channel with ROAS 4.12 toward one with ROAS 0.27, so every dollar reallocated destroys roughly 96 cents of return. On this lab's ~$366k quarterly spend, a 20 % reallocation is on the order of $70k moved from a 4× channel to a 0.27× channel — a direct value loss well into six figures annually. Then add the second-order cost: when the error is eventually found, every historical decision made on that dashboard has to be re-litigated, and the analytics team's credibility with the business — the thing that took two years to build — is gone.

**Q5.4** — Because a data pipeline's product is **trust**, and trust is not a gradient. If bad data can reach the dashboard under any circumstance, then every number on that dashboard requires independent verification before use, which destroys the entire economic argument for the platform — the whole point was that the business could act without re-checking. A hard failure is loud, has an owner, blocks publication, and is fixed in hours because someone is inconvenienced *now*. A warning banner fails for well-understood human reasons: banners are dismissed, screenshots are pasted into decks without them, the banner becomes permanent background noise within a week, and consumers three hops downstream never see it at all. The correct default is **stale-but-correct over fresh-but-wrong**: yesterday's verified number is almost always more useful than today's unverified one.

**Q5.5** — Because data quality does not determine whether you get a decision — it determines whether the decision is right, and a confidently wrong decision executed at cloud speed and scale destroys more value than no decision at all; digital transformation *increases* an organisation's dependence on data for decisions, so it multiplies the consequence of every defect.

### Exercise 6

**Q6.1** — The **principle of least privilege**, extended to the point where broad administrative authority over *infrastructure* does not confer authority over *data content*. Column-level security via policy tags is enforced independently of table-level IAM, so `roles/owner` grants no access to a tagged column without `roles/datacatalog.categoryFineGrainedReader` on the tag.

"The admin can always read everything" is unacceptable under GDPR-class regulation for several reasons. Article 32 requires technical measures proportionate to the risk, and an unbounded standing read on personal data is not proportionate. Personal data must be processed for a specified purpose, and "being a database administrator" is not one. The insider threat and the compromised-credential threat are both concentrated in exactly those accounts. And a control that has an unlogged, unconditional bypass is not a control — it is documentation. The correct posture is that even privileged access to PII is **explicitly granted, time-bounded, justified and audited**. (<https://cloud.google.com/bigquery/docs/column-level-security>)

**Q6.2** — Not redundant; they operate at different layers and fail differently.
- The **authorized view** catches: an analyst who is granted access to the *view only* and never sees the base table's existence. It also shapes and pseudonymises data (`age` → `age_band`), which a policy tag cannot do. But it protects nothing if someone is granted access to the base table directly — a routine mistake, since a new engineer needing "read on the warehouse" gets it at the dataset level.
- The **policy tag** catches exactly that case: the column stays protected even when table access is granted, even to an Owner, even through a new view someone creates tomorrow, and even via `SELECT *`. But it is binary — block or allow — with no ability to transform.

Together they are **defence in depth**: the view is the intended, ergonomic path; the tag is the backstop for when the intended path is bypassed by accident. Real breaches are almost always caused by a misconfiguration in one layer, which is precisely the case a second independent layer exists to survive.

**Q6.3** — **Generalisation** (a k-anonymity technique; the broader family is data minimisation / de-identification). It increases usable reach because a 34-year-old woman in a small country with an exact signup timestamp is often re-identifiable from a handful of quasi-identifiers, whereas "35-49, F, Germany, June 2026" is not, provided each bucket contains enough people. Since the analytical question is almost always "how do age *bands* convert?" rather than "what did customer 41022 do?", precision was discarded at **zero analytical cost and a large privacy gain**. That changes the governance conversation from "can this team have PII?" — which is slow, contentious and often answered *no* — to "here is a table with no PII in it", which needs no approval. Reducing sensitivity is how you *increase* the number of teams that can use data, which is why privacy engineering enables analytics rather than obstructing it. (<https://cloud.google.com/sensitive-data-protection/docs/concepts-risk-analysis>)

**Q6.4** — Least to most privileged: `dataViewer` on `customers_analytics` only → `dataViewer` on `cdl_warehouse` → `bigquery.admin` on the project.

**Issue:** `roles/bigquery.dataViewer` on the **view only**. It is sufficient for the stated need — the authorized view mechanism lets the view read the base table on the analyst's behalf without the analyst having any access to it — and it satisfies least privilege exactly.

**Operational cost of the strictest choice:** the analyst cannot discover or explore anything else, so every new question becomes a ticket to the data team with a wait of days. That friction is real and is the most common reason organisations over-grant. The mature resolution is not to loosen the grant but to remove the reason for it: a well-catalogued set of governed views covering the common questions, plus a fast, low-ceremony process for requesting a new one. **Least privilege fails as a policy when the exception process is slower than the work.**

**Q6.5** — This lab is the rebuttal: the *only* reason `customers_analytics` can be handed to any analyst in the company without a privacy review is that the PII was removed and the residual column was tagged — governance is what made the wide grant *possible*. Ungoverned data is not fast, it is simply blocked by a slower, less predictable control: a legal review, a security exception, or a breach.

### Exercise 7

**Q7.1** — Step 2 (`Dataset ... was not found in location EU`) proves BigQuery scopes dataset *resolution* by location: a query executing in the EU cannot even see, let alone read, a US dataset — cross-region access is not a permission that could be granted, it does not exist as an operation. Step 3 (`Cannot read and write in different locations`) proves the same boundary spans services: a US-located query engine will not read an EU-located bucket. Together they show location is enforced by the **data plane**, not by policy documents or reviews.

An engineering control beats a written policy for a regulator on three counts: it cannot be forgotten under deadline pressure, it applies uniformly to every user including the CTO and every automated job, and it is *demonstrable* — an auditor can watch the operation fail rather than read an assertion that it would not be attempted. A policy that relies on people remembering it has an unbounded violation rate; a control that returns an error has a violation rate of zero. (<https://cloud.google.com/bigquery/docs/locations>)

**Q7.2** — The classic requirement pairing is financial or medical record-keeping: records **must** be kept for seven years (retention/legal-hold obligation) and **must not** be kept beyond their lawful purpose (GDPR storage-limitation, Art. 5(1)(e)). Neither rule alone is compliant.
- **Lifecycle delete alone** leaves you unable to prove immutability: an insider, a compromised credential, or a buggy script can delete records inside the retention window, destroying evidence — the exact scenario retention policies exist to prevent.
- **Retention alone** leaves data accumulating forever past its purpose, which is itself a violation *and* an unbounded, growing breach surface: every record kept past its usefulness is pure liability with no offsetting value.

The compliant pattern is both: a **locked** retention policy making deletion impossible before day 2555, and a lifecycle rule making deletion automatic at day 2555. Retention is the floor, lifecycle is the ceiling, and compliance lives in the gap between them. (<https://cloud.google.com/storage/docs/bucket-lock>, <https://cloud.google.com/storage/docs/lifecycle>)

**Q7.3** — Each hop buys **lower storage price** in exchange for **higher retrieval cost, higher first-byte latency, and a longer minimum storage duration** (Nearline 30 days, Coldline 90, Archive 365 — delete or rewrite earlier and you are billed for the remainder anyway). It is safe for `raw/` because that data is written once and read rarely — the archived copy exists for reprocessing and audit, and paying more on the rare read is obviously correct when you avoid paying premium storage every month on data nobody touches.

It would be dangerous behind a live dashboard for both reasons at once: latency (an interactive query hitting Archive-class objects turns a two-second dashboard into an unusable one) and cost inversion (retrieval fees on frequently-read data can exceed the storage saved by a wide margin, so you pay *more* for a worse experience). The rule is that storage class must follow the **access pattern**, and lifecycle automation is only safe where the access pattern is genuinely known and stable. (<https://cloud.google.com/storage/docs/storage-classes>)

**Q7.4** —
- **Financial:** storage is cheap per gigabyte but never free, and it compounds — a growing dataset kept forever is a permanently rising line item plus its multipliers: backups, replication across regions, egress on every migration, index and catalogue overhead, and the analyst time spent sifting decade-old irrelevant records. You are also paying to *keep* the data understandable: schemas drift, the people who knew what a column meant leave, and the cost of interpreting old data rises even as its value falls.
- **Legal:** every record you hold is a record you can be compelled to produce in discovery, must include in a subject access request, must delete on a valid erasure request (and must be able to *find* in order to delete), and must report on if it is breached. Under storage limitation, holding personal data past its stated purpose is itself the violation. Data you deleted lawfully cannot be breached, subpoenaed, or fined. **Retained data is a liability that accrues interest; the "just in case" is rarely worth the carry.**

**Q7.5** —
- **Option A — Federated / data mesh:** EU personal data stays in EU regions permanently. Only aggregated, anonymised or pseudonymised extracts (counts, bands, model features with no re-identification path) cross into the global view. **Accepts:** you never have a true single global row-level customer record; some analyses are impossible or must be run per-region and combined; higher engineering complexity, with a per-region pipeline and a reconciliation layer.
- **Option B — Centralised with de-identification at the boundary:** personal data is tokenised, hashed or masked before leaving the EU, and the re-identification key never crosses. The global warehouse holds a linkable-but-not-identifiable record. **Accepts:** a genuine legal risk surface — the regulator, not you, decides whether your pseudonymisation is strong enough to make the data non-personal; the key-management and cross-border-transfer mechanism (adequacy decision, SCCs) becomes the single point on which the whole architecture rests; and re-identification via combined quasi-identifiers remains a live hazard.

The honest framing for an executive: this is not a technology decision. Option A is slower and more expensive but the compliance argument is trivial. Option B is more capable but its legality depends on a judgement call that can be revisited by a regulator after you have built on it. Most regulated multinationals choose A for personal data and B for everything else.

### Exercise 8

**Q8.1** —
- **(a) Monthly board revenue pack — batch.** Consumed once a month, must be reconciled and auditable; correctness and reproducibility beat freshness absolutely. Real-time here would add cost and a reconciliation problem for zero decision value.
- **(b) Card-fraud scoring at checkout — streaming.** The decision window is the length of a checkout. An insight arriving after the transaction has settled has *negative* value: you paid for it and cannot act on it.
- **(c) "Customers also bought" — streaming, but with an important nuance.** The *model* is trained in batch overnight; the *features* (this session's basket) must be real-time. This is the common hybrid — batch intelligence, streaming context — and recognising it is the sophisticated answer.
- **(d) Annual regulatory filing — batch.** Annual cadence, absolute correctness requirement, must be a frozen and defensible snapshot.
- **(e) Stock-out alerting — streaming.** Value decays over minutes: knowing at 09:00 that you ran out at 08:55 lets you reroute; knowing tomorrow describes a loss you already took.

The general rule: **match ingestion latency to the decision's action window, not to the sponsor's enthusiasm.**

**Q8.2** — A **dead-letter topic** on the subscription (`--dead-letter-topic` with `--max-delivery-attempts`), so a message that repeatedly fails to be written is redirected to a quarantine topic instead of being discarded — where it can be alerted on, inspected, corrected and replayed. Pair it with monitoring on the subscription's dead-letter count and on `oldest_unacked_message_age`. (<https://cloud.google.com/pubsub/docs/handling-failures>)

Undetected loss is worse than a loud failure for the reason a corrupted backup is worse than no backup: it removes the signal that would have prompted action. With a loud failure, you know the number is wrong and you do not act on it. With silent loss, your revenue total is 3 % low, it looks entirely plausible, it is reported to the board, and it is never questioned — until someone reconciles against the payment processor months later, and then *every* figure the platform ever published becomes suspect. Streaming makes this hazard sharper than batch: a failed batch job is a visible artefact with an owner and a retry button, whereas a dropped message leaves no artefact at all. **In streaming architectures, the error path must be designed with the same care as the happy path.**

**Q8.3** — `PARTITION BY DATE(created_at)` physically segregates rows into one partition per day. A query filtered on `created_at` reads only the matching partitions — **partition pruning** — so "yesterday's orders" against three years of history scans roughly 1/1000th of the table. **Cost:** on-demand billing is per byte scanned, so the bill falls by the same factor. **Speed:** less I/O and fewer parallel workers needed, so latency drops proportionally.

The connection to Q3.1 is that these are the same idea on two axes. Columnar layout prunes **horizontally** (skip the columns you did not ask for); partitioning prunes **vertically** (skip the rows you did not ask for); clustering sorts within a partition to prune further still. All three are physical layout decisions that show up directly on the invoice — which is why in a serverless warehouse, *data modelling is cost engineering*. You can also set `require_partition_filter` to make an unfiltered full scan an error rather than a surprise. (<https://cloud.google.com/bigquery/docs/partitioned-tables>)

**Q8.4** — First, **from capital expenditure and capacity planning to consumption-based operating expenditure**: no cluster was sized, procured or paid for in advance; the subscription scales from five messages to five million with no action, and idle costs nothing. The old question "how much capacity do we buy for peak, and who signs for it?" simply disappears. Second, **from undifferentiated infrastructure operations to business value**: nobody patches, monitors, capacity-plans or fails over the streaming pipeline. The IT department's scarce engineering time moves from keeping the pipe running — work that is invisible when it succeeds and career-limiting when it fails — to defining what should flow through it. Managed and serverless services are how a transformation programme reallocates its most constrained resource, which is skilled people, not machines.

**Q8.5** — Ask: **(1) "Which specific decision will be made differently if this data is one minute old instead of twenty-four hours old, and who makes it?"** — this probes whether there is a real action window, and it usually surfaces that the consumer is a weekly report with a human in the loop, in which case real-time changes nothing. **(2) "What are we prepared to give up for it — cost, or correctness?"** — this probes the honest trade. Streaming costs more per byte ingested, and it structurally trades away the late-arriving-data, reconciliation and easy-restatement properties of batch: a batch job can be re-run against corrected inputs, whereas a stream has already emitted its answer downstream.

Both questions probe the same dimension: **the total cost of latency** — infrastructure spend, engineering complexity, on-call burden, and the correctness guarantees you surrender. "Real-time everything" is almost always a request for *one* real-time thing, plus an aesthetic preference for the rest.

### Exercise 9

**Q9.1** — The ROAS table shows the company was spending $107k on a channel returning 57 cents on the dollar and $131k on one returning $4.12, and *no individual system in the business could distinguish between them* — the strategy was invisible from inside either department. Data is intrinsic rather than supporting because the organisation's most consequential decisions are literally unavailable to it until data from separate parts of the business is brought together; the technology transformation is only the means, and the transformation itself is the shift from deciding by instinct to deciding by evidence.

**Q9.2** —
- **Silos** — Exercise 4: Finance and E-commerce each held half of CAC and neither could compute it.
- **Data quality** — Exercise 5: a single duplicated row reversed the apparent ranking of channels and would have redirected budget from a 4× channel to a 0.27× one.
- **Governance, privacy and compliance** — Exercises 6 and 7: PII needed masking before the data could be shared widely, and residency made a one-line `CREATE TABLE` illegal across a border.
- **Unstructured data** — Exercise 1: the highest-value signal in the lab (an explicit churn statement in a call transcript) was the one no query could reach without AI.

A defensible fifth, visible in Exercise 8: **latency mismatch** — data that arrives after the decision window has closed has no value regardless of quality. And underlying all of them, the barrier the lab could not show you: **culture and ownership**, since every one of these had a cheap technical fix and an expensive organisational one.

**Q9.3** —
- **"Can a product manager answer a new question themselves this afternoon, without filing a ticket?"** — tests **democratisation and self-service**. Twelve years of history behind a queue that only three people can serve is an archive, not a decision-making capability.
- **"When Marketing spend and web behaviour need joining, how long does that take, and has it been done?"** — tests **silos**. History depth says nothing about breadth; a deep warehouse of one department's data has the same blind spot as a spreadsheet.
- **"What happens when a bad row lands — who finds out, how fast, and does anything stop it being published?"** — tests **quality assurance and trust**. Twelve years of unvalidated history is twelve years of unquantified error.

Strong follow-ups: "Can you handle unstructured data — calls, documents, images — at all?" (most on-premises warehouses cannot, which excludes the majority of enterprise data), "What is the cost and lead time of a 10× query-volume spike?" (fixed capacity is a ceiling on curiosity), and "Can you show me who accessed customer PII last Tuesday?" (governance maturity).

**Q9.4** — Pub/Sub → **ingest** (streaming). Cloud Storage → **store** (raw / lake). Dataflow → **process** (batch and stream transformation, unified). BigQuery → **analyse** (serverless warehouse). Dataplex Universal Catalog → **govern** (catalogue, lineage, quality, policy across lakes and warehouses). Looker → **activate** (BI, governed semantic model, decisions). Vertex AI → **predict** (ML/AI over the curated data). Cloud SQL → **transact** (OLTP system of record; the *source*, not part of the analytics chain).

**Q9.5** — The scarce resource was never compute — the entire lab's querying cost a fraction of a cent, and the same queries would run over a thousand times the data for a few dollars. What was scarce was **the human judgement**: knowing that CAC alone would mislead and ROAS was required, spotting that the duplicate row propagated beyond the row it touched, deciding that `email` needed a policy tag, knowing which questions were worth asking at all.

The implication is the central economic fact of the cloud era: infrastructure has ceased to be the bottleneck in a data programme, so **the constraint moved to data literacy, governance maturity, clear ownership and organisational willingness to act on evidence** — all of which are people and process problems. This is exactly why the Cloud Digital Leader exam is weighted toward transformation and value rather than configuration: an organisation that buys the platform and does not change how it decides has bought a faster way to produce reports nobody uses.

**Q9.6** — **`cdl_warehouse.customers`** — the only artefact containing real PII (email, name, exact age, location) at 50,000-row scale. Everything else is aggregate, synthetic, or already de-identified: it is the sole object whose breach would be a notifiable incident. What you would lose is the ability to do anything requiring individual-level identity: personalised outbound messaging, joining to a CRM or support system by email, per-customer lifetime-value calculation, and honouring subject access or erasure requests (you cannot delete what you no longer hold — which is a benefit, not a loss).

Critically, you would **not** lose the analysis this lab was actually built to produce. `channel_performance` and `customers_analytics` survive intact, so CAC and ROAS keep working. That is the whole argument for the layered design: the highest-risk asset turns out to be separable from the highest-value insight, and recognising which is which is the practical content of data governance.

</details>

---

### Reference sources

- Google Cloud Digital Leader exam guide — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- What is a data lake — <https://cloud.google.com/learn/what-is-a-data-lake>
- What is a data warehouse — <https://cloud.google.com/learn/what-is-a-data-warehouse>
- BigQuery introduction — <https://cloud.google.com/bigquery/docs/introduction>
- Query external data in Cloud Storage — <https://cloud.google.com/bigquery/docs/external-data-cloud-storage>
- Controlling BigQuery costs — <https://cloud.google.com/bigquery/docs/best-practices-costs>
- BigQuery pricing — <https://cloud.google.com/bigquery/pricing>
- BigQuery dataset locations — <https://cloud.google.com/bigquery/docs/locations>
- Partitioned tables — <https://cloud.google.com/bigquery/docs/partitioned-tables>
- Authorized views — <https://cloud.google.com/bigquery/docs/authorized-views>
- Column-level access control — <https://cloud.google.com/bigquery/docs/column-level-security>
- Data control language (GRANT / REVOKE) — <https://cloud.google.com/bigquery/docs/reference/standard-sql/data-control-language>
- `INFORMATION_SCHEMA` jobs views — <https://cloud.google.com/bigquery/docs/information-schema-jobs>
- BigQuery public datasets — <https://cloud.google.com/bigquery/public-data>
- Cloud Storage introduction — <https://cloud.google.com/storage/docs/introduction>
- Storage classes — <https://cloud.google.com/storage/docs/storage-classes>
- Object lifecycle management — <https://cloud.google.com/storage/docs/lifecycle>
- Retention policies and Bucket Lock — <https://cloud.google.com/storage/docs/bucket-lock>
- Uniform bucket-level access — <https://cloud.google.com/storage/docs/uniform-bucket-level-access>
- Pub/Sub overview — <https://cloud.google.com/pubsub/docs/pubsub-basics>
- BigQuery subscriptions — <https://cloud.google.com/pubsub/docs/bigquery>
- Handling message failures — <https://cloud.google.com/pubsub/docs/handling-failures>
- Dataplex Universal Catalog — <https://cloud.google.com/dataplex/docs/introduction>
- IAM overview — <https://cloud.google.com/iam/docs/overview>
- Sensitive Data Protection — risk analysis — <https://cloud.google.com/sensitive-data-protection/docs/concepts-risk-analysis>
- Cloud SQL / Spanner / Dataflow overviews — <https://cloud.google.com/sql/docs/introduction> · <https://cloud.google.com/spanner/docs/overview> · <https://cloud.google.com/dataflow/docs/overview>