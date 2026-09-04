# Topic 3.7 — AI/ML and Analytics Services

## Guided Exercises — AWS Certified Cloud Practitioner (CLF-C02, v1.0)

> **Domain 3, Task 3.7** — *Identify AWS artificial intelligence and machine learning (AI/ML) services and analytics services.* Weight in the exam: **4.25%** (Domain 3 = 34%, split across eight tasks).
>
> The exam asks you to **identify** the right service for a described workload. It does not ask you to train a model or tune a Spark job. But identification learned from a slide deck evaporates under exam pressure, because the distractors are the *neighbouring* services — Kinesis Data Streams vs. Data Firehose, Athena vs. Redshift, Rekognition vs. Textract. These exercises make you touch each service from the CLI so that the boundary between neighbours becomes a thing you have seen, not a thing you memorised.

---

## Lab conventions and prerequisites

You need:

| Requirement | Check |
|---|---|
| An AWS account you own or are authorised to use | — |
| AWS CLI **v2** installed | `aws --version` → `aws-cli/2.x.x …` |
| An IAM principal with admin-ish rights for the lab | `aws sts get-caller-identity` |
| `jq` | `jq --version` |
| Region `us-east-1` (widest AI/ML service coverage) | `aws configure get region` |

**Cost.** Everything below is designed to run for **well under US$1**, and most of it inside the Free Tier. The two line items that can surprise you:

| Service | What you pay in this lab | Order of magnitude |
|---|---|---|
| Amazon Athena | Per **TB scanned**, 10 MB minimum per query | ~$5.00 / TB → our queries cost fractions of a cent |
| AWS Glue crawler | Per **DPU-hour**, per second, 10-minute minimum | ~$0.44 / DPU-hour → ~$0.07 per crawler run |
| Amazon Data Firehose | Per **GB ingested** | ~$0.029 / GB → effectively $0 for 30 records |
| Comprehend / Translate / Polly / Rekognition / Textract / Transcribe | Free Tier covers this lab comfortably | ~$0 |
| Amazon Bedrock | Per **token**, on-demand | < $0.01 for one short prompt |
| Amazon S3 | Storage + requests | < $0.01 |

**Exercise 8 is the teardown. Do not skip it.** A forgotten Firehose delivery stream is harmless; a forgotten Redshift cluster or OpenSearch domain is not — which is precisely why this lab never creates one.

Set your shell up once:

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="clf37-lab-${ACCOUNT_ID}"
export DB=clf37
echo "account=$ACCOUNT_ID bucket=$BUCKET region=$AWS_REGION"
```

---

## Exercise 0 — Preflight: identity, region, and a cost guardrail

A production architect never starts a lab without a budget alarm. Neither will you.

1. **Confirm who you are and where you are.** The region matters more for AI/ML than for almost any other category: services and models are not available everywhere.

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDAEXAMPLEEXAMPLE1",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/lab-admin"
   }
   ```

2. **Create the lab bucket.** S3 is the substrate under every analytics and most AI services in this topic — the data lake, the Athena results location, the Firehose destination, and the input for Rekognition, Textract and Transcribe.

   ```bash
   aws s3 mb "s3://${BUCKET}" --region "$AWS_REGION"
   ```

   ```
   make_bucket: clf37-lab-123456789012
   ```

3. **Create a $5 monthly budget with an email alert**, so any mistake in this lab reaches you before it reaches your card.

   ```bash
   cat > /tmp/budget.json <<'EOF'
   {
     "BudgetName": "clf37-lab-guardrail",
     "BudgetLimit": { "Amount": "5", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST"
   }
   EOF

   cat > /tmp/notify.json <<'EOF'
   [
     {
       "Notification": {
         "NotificationType": "ACTUAL",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 80,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "EMAIL", "Address": "you@example.com" }
       ]
     }
   ]
   EOF

   aws budgets create-budget \
     --account-id "$ACCOUNT_ID" \
     --budget file:///tmp/budget.json \
     --notifications-with-subscribers file:///tmp/notify.json
   ```

   No output on success. Verify:

   ```bash
   aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
     --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount}' --output table
   ```

   ```
   ----------------------------------------
   |            DescribeBudgets           |
   +----------------------+---------------+
   |         Limit        |     Name      |
   +----------------------+---------------+
   |  5.0                 | clf37-lab-... |
   +----------------------+---------------+
   ```

**Comprehension check — Block 0**

- **Q0.1** AWS Budgets is not an analytics service in the exam-guide sense, yet it appears in almost every well-architected lab. Which Domain-3 category does it belong to, and which *pillar* of cost management does a budget alert implement — visibility, control, or optimisation?
- **Q0.2** You ran `aws s3 mb` with `--region us-east-1`. Why does the region of this bucket matter for the Rekognition and Textract steps later, but *not* for the Comprehend step?
- **Q0.3** Why is S3 — a storage service, covered in task 3.6 — the correct starting point for a task-3.7 lab?

---

## Exercise 1 — The serverless analytics core: S3 + AWS Glue + Amazon Athena

This is the single most exam-relevant pattern in the whole topic: **S3 is the data lake, Glue is the catalogue and the ETL, Athena is the SQL query engine.** Learn this triangle and half of the analytics questions answer themselves.

### 1a. Put raw data in the lake

1. Generate a small CSV of e-commerce orders.

   ```bash
   cat > /tmp/orders.csv <<'EOF'
   order_id,order_ts,region,category,units,unit_price_usd
   1001,2026-09-01T09:14:02Z,us-east-1,laptops,2,1299.00
   1002,2026-09-01T09:41:55Z,eu-west-1,monitors,4,219.50
   1003,2026-09-01T10:02:11Z,us-east-1,keyboards,11,89.99
   1004,2026-09-02T11:20:00Z,ap-south-1,laptops,1,1499.00
   1005,2026-09-02T12:00:47Z,eu-west-1,laptops,3,1299.00
   1006,2026-09-02T14:33:20Z,us-east-1,monitors,7,219.50
   1007,2026-09-03T08:05:09Z,ap-south-1,keyboards,25,89.99
   1008,2026-09-03T16:44:31Z,us-east-1,laptops,5,1349.00
   EOF

   aws s3 cp /tmp/orders.csv "s3://${BUCKET}/raw/orders/orders.csv"
   ```

   ```
   upload: /tmp/orders.csv to s3://clf37-lab-123456789012/raw/orders/orders.csv
   ```

   > **Production detail:** the object is under a `raw/orders/` **prefix**, not at the bucket root. A Glue crawler points at a prefix and treats *every object under it* as one table. An object dropped at the root would force the crawler to catalogue the whole bucket — including your Athena result files, which is a classic self-inflicted wound.

2. **Nothing has been "ingested".** Confirm that the data is simply sitting in object storage — no cluster, no database, no loading step:

   ```bash
   aws s3 ls "s3://${BUCKET}/raw/orders/" --human-readable
   ```

   ```
   2026-09-04 12:01:33  512 Bytes orders.csv
   ```

### 1b. Catalogue it with AWS Glue

3. Create the Glue **database** — a logical container of table *metadata*. It holds no data.

   ```bash
   aws glue create-database --database-input "{\"Name\":\"${DB}\"}"
   aws glue get-database --name "$DB" --query 'Database.{Name:Name,Created:CreateTime}'
   ```

   ```json
   {
       "Name": "clf37",
       "Created": "2026-09-04T12:03:10-03:00"
   }
   ```

4. Create the IAM role the crawler will assume. Note the two attachments — this is where most first crawler runs fail.

   ```bash
   aws iam create-role --role-name AWSGlueServiceRole-clf37 \
     --assume-role-policy-document '{
       "Version":"2012-10-17",
       "Statement":[{"Effect":"Allow",
         "Principal":{"Service":"glue.amazonaws.com"},
         "Action":"sts:AssumeRole"}]}' \
     --query 'Role.Arn' --output text
   ```

   ```
   arn:aws:iam::123456789012:role/AWSGlueServiceRole-clf37
   ```

   ```bash
   aws iam attach-role-policy --role-name AWSGlueServiceRole-clf37 \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

   aws iam put-role-policy --role-name AWSGlueServiceRole-clf37 \
     --policy-name LabBucketRead \
     --policy-document "{
       \"Version\":\"2012-10-17\",
       \"Statement\":[{
         \"Effect\":\"Allow\",
         \"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
         \"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]}]}"
   ```

   > **Why the inline policy?** The AWS-managed `AWSGlueServiceRole` policy grants S3 access **only to buckets whose name begins with `aws-glue-`**. Ours does not. Skipping this step produces a crawler that runs, succeeds, and creates zero tables — a silent failure that has cost many engineers an afternoon.

5. Create and start the crawler.

   ```bash
   aws glue create-crawler \
     --name clf37-orders-crawler \
     --role AWSGlueServiceRole-clf37 \
     --database-name "$DB" \
     --targets "{\"S3Targets\":[{\"Path\":\"s3://${BUCKET}/raw/orders/\"}]}"

   aws glue start-crawler --name clf37-orders-crawler
   ```

6. Poll until it returns to `READY` (typically 60–120 s — the crawler has a cold start).

   ```bash
   while true; do
     STATE=$(aws glue get-crawler --name clf37-orders-crawler --query 'Crawler.State' --output text)
     echo "$(date +%T) $STATE"
     [ "$STATE" = "READY" ] && break
     sleep 15
   done
   ```

   ```
   12:06:11 RUNNING
   12:06:26 RUNNING
   12:06:41 STOPPING
   12:06:56 READY
   ```

7. Inspect what the crawler **inferred**. It read the objects and derived a schema — you never wrote a `CREATE TABLE`.

   ```bash
   aws glue get-table --database-name "$DB" --name orders \
     --query 'Table.StorageDescriptor.Columns[].{Column:Name,Type:Type}' --output table
   ```

   ```
   ----------------------------------
   |            GetTable            |
   +-------------------+------------+
   |      Column       |    Type    |
   +-------------------+------------+
   |  order_id         |  bigint    |
   |  order_ts         |  string    |
   |  region           |  string    |
   |  category         |  string    |
   |  units            |  bigint    |
   |  unit_price_usd   |  double    |
   +-------------------+------------+
   ```

**Comprehension check — Block 1a/1b**

- **Q1.1** The Glue Data Catalog now contains a table called `orders`. Where do the *rows* of that table physically live? What would `aws glue delete-table` destroy?
- **Q1.2** The crawler typed `order_ts` as `string`, not `timestamp`. What does that tell you about schema *inference* versus schema *definition*, and which one is "schema-on-read"?
- **Q1.3** Name the two distinct roles AWS Glue plays in this architecture. (Hint: one of them you have used; the other is what the "ETL" in Glue's marketing refers to.)
- **Q1.4** A colleague says "we need to load the CSV into Glue before we can query it." Correct the statement in one sentence.

### 1c. Query it with Athena

8. Run a SQL query against S3. There is no cluster to start, no endpoint to connect to.

   ```bash
   QID=$(aws athena start-query-execution \
     --work-group primary \
     --query-string "SELECT region, SUM(units * unit_price_usd) AS revenue_usd
                     FROM ${DB}.orders GROUP BY region ORDER BY revenue_usd DESC" \
     --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
     --query QueryExecutionId --output text)
   echo "$QID"
   ```

   ```
   8f0c1a4e-2b77-4a51-9c3e-1de6a2c4b900
   ```

9. Poll for completion and read the **statistics**, not just the rows. The statistics are the whole pricing model.

   ```bash
   aws athena get-query-execution --query-execution-id "$QID" \
     --query 'QueryExecution.{State:Status.State,ScannedBytes:Statistics.DataScannedInBytes,Millis:Statistics.TotalExecutionTimeInMillis}'
   ```

   ```json
   {
       "State": "SUCCEEDED",
       "ScannedBytes": 512,
       "Millis": 1284
   }
   ```

10. Fetch the results.

    ```bash
    aws athena get-query-results --query-execution-id "$QID" \
      --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
    ```

    ```
    region  revenue_usd
    us-east-1       12036.87
    eu-west-1       4775.00
    ap-south-1      3748.75
    ```

11. **Feel the pricing model.** Athena bills per byte scanned. Create a columnar, compressed copy of the same data with CTAS (Create Table As Select) — this is the single highest-leverage cost optimisation in the entire service.

    ```bash
    QID2=$(aws athena start-query-execution \
      --work-group primary \
      --query-string "CREATE TABLE ${DB}.orders_parquet
                      WITH (format='PARQUET',
                            external_location='s3://${BUCKET}/curated/orders_parquet/')
                      AS SELECT * FROM ${DB}.orders" \
      --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
      --query QueryExecutionId --output text)

    sleep 20
    aws athena get-query-execution --query-execution-id "$QID2" \
      --query 'QueryExecution.Status.State' --output text
    ```

    ```
    SUCCEEDED
    ```

12. Query one column from each table and compare bytes scanned.

    ```bash
    for T in orders orders_parquet; do
      Q=$(aws athena start-query-execution --work-group primary \
        --query-string "SELECT SUM(units) FROM ${DB}.${T}" \
        --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
        --query QueryExecutionId --output text)
      sleep 8
      B=$(aws athena get-query-execution --query-execution-id "$Q" \
        --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)
      echo "${T}: ${B} bytes scanned"
    done
    ```

    ```
    orders: 512 bytes scanned
    orders_parquet: 74 bytes scanned
    ```

    > At 512 bytes the saving is a rounding error. At 5 TB of CSV logs it is the difference between a $25 query and a $0.40 query, run hundreds of times a day. The exam will not ask you to compute this, but it *will* ask "how do you reduce Athena cost?" — and the answer is columnar format, compression, and partitioning.

**Comprehension check — Block 1c**

- **Q1.5** Athena's price is quoted per terabyte scanned. Name three ways to reduce that number without changing the SQL.
- **Q1.6** You never provisioned an instance, a node, or a cluster for Athena. What does that make it, in AWS's own service-model vocabulary, and what is the operational consequence for a team with no data engineers?
- **Q1.7** A team runs the *same* dashboard query 400 times an hour over 2 TB of data, all day, every day. Athena is now the wrong tool. Which analytics service should they move to, and what is the fundamental economic difference between the two?
- **Q1.8** Athena needed a `--result-configuration OutputLocation`. Where do Athena query results go, and why is that occasionally a governance question rather than a technical one?

---

## Exercise 2 — Streaming ingestion: Amazon Data Firehose

The exam's streaming family is small but the distinctions are sharp. Firehose is the **easy** one: no consumers to write, no shards to manage, near-real-time delivery straight into a destination.

1. Create the delivery role Firehose will assume to write into your bucket.

   ```bash
   aws iam create-role --role-name FirehoseToS3-clf37 \
     --assume-role-policy-document "{
       \"Version\":\"2012-10-17\",
       \"Statement\":[{\"Effect\":\"Allow\",
         \"Principal\":{\"Service\":\"firehose.amazonaws.com\"},
         \"Action\":\"sts:AssumeRole\",
         \"Condition\":{\"StringEquals\":{\"sts:ExternalId\":\"${ACCOUNT_ID}\"}}}]}" \
     --query 'Role.Arn' --output text

   aws iam put-role-policy --role-name FirehoseToS3-clf37 \
     --policy-name WriteLabBucket \
     --policy-document "{
       \"Version\":\"2012-10-17\",
       \"Statement\":[{
         \"Effect\":\"Allow\",
         \"Action\":[\"s3:AbortMultipartUpload\",\"s3:GetBucketLocation\",
                     \"s3:GetObject\",\"s3:ListBucket\",
                     \"s3:ListBucketMultipartUploads\",\"s3:PutObject\"],
         \"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]}]}"

   sleep 10   # IAM is eventually consistent; Firehose creation fails if you race it
   ```

2. Create the delivery stream with a **DirectPut** source and an S3 destination.

   ```bash
   cat > /tmp/fh.json <<EOF
   {
     "RoleARN": "arn:aws:iam::${ACCOUNT_ID}:role/FirehoseToS3-clf37",
     "BucketARN": "arn:aws:s3:::${BUCKET}",
     "Prefix": "stream/clicks/",
     "ErrorOutputPrefix": "stream/errors/",
     "BufferingHints": { "SizeInMBs": 1, "IntervalInSeconds": 60 },
     "CompressionFormat": "UNCOMPRESSED"
   }
   EOF

   aws firehose create-delivery-stream \
     --delivery-stream-name clf37-clicks \
     --delivery-stream-type DirectPut \
     --extended-s3-destination-configuration file:///tmp/fh.json \
     --query DeliveryStreamARN --output text
   ```

   ```
   arn:aws:firehose:us-east-1:123456789012:deliverystream/clf37-clicks
   ```

3. Wait for `ACTIVE`.

   ```bash
   aws firehose describe-delivery-stream --delivery-stream-name clf37-clicks \
     --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text
   ```

   ```
   ACTIVE
   ```

4. Put 30 records. Read the two production details in the comment before running it.

   ```bash
   for i in $(seq 1 30); do
     line=$(printf '{"ts":"%s","user":"u%s","page":"/pricing","latency_ms":%s}' \
             "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((i % 5))" "$((150 + i * 7))")
     aws firehose put-record \
       --cli-binary-format raw-in-base64-out \
       --delivery-stream-name clf37-clicks \
       --record "$(jq -nc --arg d "$line" '{Data: ($d + "\n")}')" \
       --query RecordId --output text >/dev/null
   done
   echo "30 records sent"
   ```

   ```
   30 records sent
   ```

   > **Detail 1 — `--cli-binary-format raw-in-base64-out`.** `Record.Data` is a *blob*. AWS CLI v2 expects blob arguments to be base64-encoded by default; this flag tells it to accept raw text. Without it you get `Invalid base64` or, worse, silently corrupted records.
   >
   > **Detail 2 — the appended `\n`.** Firehose concatenates records into an object byte-for-byte, with **no delimiter of its own**. If you omit the newline, all 30 JSON documents land as one unparseable line and Athena returns zero rows over a file that is visibly full of data. This is one of the most common real-world Firehose-to-Athena bugs.

5. Wait out the buffer (60 s or 1 MB, whichever comes first) and look at what landed.

   ```bash
   sleep 90
   aws s3 ls "s3://${BUCKET}/stream/clicks/" --recursive
   ```

   ```
   2026-09-04 12:22:41       2130 stream/clicks/2026/09/04/15/clf37-clicks-1-2026-09-04-15-21-08-9f0a...
   ```

6. Confirm the newline delimiting worked.

   ```bash
   aws s3 cp "s3://${BUCKET}/$(aws s3api list-objects-v2 --bucket "$BUCKET" \
     --prefix stream/clicks/ --query 'Contents[0].Key' --output text)" - | head -3
   ```

   ```
   {"ts":"2026-09-04T15:21:03Z","user":"u1","page":"/pricing","latency_ms":157}
   {"ts":"2026-09-04T15:21:04Z","user":"u2","page":"/pricing","latency_ms":164}
   {"ts":"2026-09-04T15:21:05Z","user":"u3","page":"/pricing","latency_ms":171}
   ```

7. Query the stream output with Athena, closing the loop back to Exercise 1. Define the table by hand this time — schema-on-read, no crawler.

   ```bash
   QID3=$(aws athena start-query-execution --work-group primary \
     --query-string "CREATE EXTERNAL TABLE IF NOT EXISTS ${DB}.clicks (
                       ts string, user string, page string, latency_ms int)
                     ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
                     LOCATION 's3://${BUCKET}/stream/clicks/'" \
     --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
     --query QueryExecutionId --output text)

   sleep 10

   QID4=$(aws athena start-query-execution --work-group primary \
     --query-string "SELECT user, COUNT(*) n, AVG(latency_ms) avg_ms
                     FROM ${DB}.clicks GROUP BY user ORDER BY user" \
     --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
     --query QueryExecutionId --output text)

   sleep 10
   aws athena get-query-results --query-execution-id "$QID4" \
     --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
   ```

   ```
   user    n       avg_ms
   u0      6       234.0
   u1      6       206.5
   u2      6       213.5
   u3      6       220.5
   u4      6       227.5
   ```

**Comprehension check — Block 2**

- **Q2.1** You wrote **no consumer application** and managed **no shards**. State the single sentence that distinguishes Amazon Data Firehose from Amazon Kinesis Data Streams.
- **Q2.2** Records took up to 60 seconds to appear in S3. Is Firehose "real-time"? What is the correct term, and which buffering parameters control it?
- **Q2.3** A trading platform needs sub-second custom processing of a market feed, with the ability to replay the last 24 hours of events and to have three independent applications consume the same stream. Firehose or Data Streams? Justify with two properties.
- **Q2.4** The team already runs Apache Kafka on-premises and wants to lift it to AWS with minimal application rewriting. Which service, and why is it not Kinesis?
- **Q2.5** They now want a continuous 5-minute tumbling-window aggregation over that stream, written in SQL or Apache Flink, before the data lands anywhere. Which service?
- **Q2.6** Name the Kinesis family member designed for ingesting and processing **video** feeds from connected cameras.

---

## Exercise 3 — Pre-trained AI services: the "no ML expertise required" tier

The AI services tier is defined by a single property: **you send data to an API and get an inference back.** No training data, no model, no ML knowledge. The exam tests whether you can map a business phrase to the right API.

### 3a. Amazon Comprehend — NLP over text

1. Sentiment.

   ```bash
   aws comprehend detect-sentiment --language-code en \
     --text "The checkout page timed out three times and support never answered. Terrible."
   ```

   ```json
   {
       "Sentiment": "NEGATIVE",
       "SentimentScore": {
           "Positive": 0.0011,
           "Negative": 0.9942,
           "Neutral": 0.0044,
           "Mixed": 0.0003
       }
   }
   ```

2. Entities.

   ```bash
   aws comprehend detect-entities --language-code en \
     --text "Ana Ruiz opened a support case with Contoso Ltd in Barcelona on 3 September 2026." \
     --query 'Entities[].{Text:Text,Type:Type,Score:Score}' --output table
   ```

   ```
   ------------------------------------------------------
   |                   DetectEntities                   |
   +---------------+--------------+---------------------+
   |     Score     |     Text     |        Type         |
   +---------------+--------------+---------------------+
   |  0.9994       |  Ana Ruiz    |  PERSON             |
   |  0.9971       |  Contoso Ltd |  ORGANIZATION       |
   |  0.9988       |  Barcelona   |  LOCATION           |
   |  0.9932       |  3 September 2026 | DATE           |
   +---------------+--------------+---------------------+
   ```

3. PII detection — the compliance-flavoured call that appears in governance questions.

   ```bash
   aws comprehend detect-pii-entities --language-code en \
     --text "Contact me at ana.ruiz@example.com or on +34 600 123 456." \
     --query 'Entities[].Type' --output text
   ```

   ```
   EMAIL   PHONE
   ```

4. Language identification — note that you do **not** pass a language code here.

   ```bash
   aws comprehend detect-dominant-language \
     --text "El pedido llegó roto y nadie contestó el correo." \
     --query 'Languages[0]'
   ```

   ```json
   {
       "LanguageCode": "es",
       "Score": 0.9989
   }
   ```

### 3b. Amazon Translate — machine translation

5. ```bash
   aws translate translate-text \
     --source-language-code auto \
     --target-language-code en \
     --text "El pedido llegó roto y nadie contestó el correo." \
     --query '{Out:TranslatedText,Detected:SourceLanguageCode}'
   ```

   ```json
   {
       "Out": "The order arrived broken and no one answered the email.",
       "Detected": "es"
   }
   ```

   > `--source-language-code auto` makes Translate call Comprehend's language detection internally. This is a real composition pattern, not a trick: the AI services are designed to chain.

### 3c. Amazon Polly — text to speech

6. ```bash
   aws polly synthesize-speech \
     --engine neural \
     --voice-id Joanna \
     --output-format mp3 \
     --text "Your order number 1008 has shipped and arrives on Friday." \
     /tmp/speech.mp3
   ```

   ```json
   {
       "ContentType": "audio/mpeg",
       "RequestCharacters": "57"
   }
   ```

7. See which voices exist — evidence that this is a catalogue of pre-trained models, not something you train.

   ```bash
   aws polly describe-voices --language-code en-US \
     --query 'Voices[?SupportedEngines[?@==`neural`]].{Id:Id,Gender:Gender}' --output table
   ```

   ```
   ---------------------------
   |     DescribeVoices      |
   +----------+--------------+
   |  Gender  |      Id      |
   +----------+--------------+
   |  Female  |  Danielle    |
   |  Male    |  Gregory     |
   |  Female  |  Ivy         |
   |  Female  |  Joanna      |
   |  Female  |  Kendra      |
   |  Male    |  Matthew     |
   |  ...     |  ...         |
   +----------+--------------+
   ```

### 3d. Amazon Transcribe — speech to text (closing the loop with Polly)

8. Upload the audio Polly just produced and transcribe it back.

   ```bash
   aws s3 cp /tmp/speech.mp3 "s3://${BUCKET}/audio/speech.mp3"

   aws transcribe start-transcription-job \
     --transcription-job-name clf37-job-1 \
     --language-code en-US \
     --media "MediaFileUri=s3://${BUCKET}/audio/speech.mp3" \
     --output-bucket-name "$BUCKET" \
     --output-key "transcripts/" \
     --query 'TranscriptionJob.TranscriptionJobStatus' --output text
   ```

   ```
   IN_PROGRESS
   ```

9. Poll — Transcribe is **asynchronous batch**, unlike everything else in this exercise.

   ```bash
   while true; do
     S=$(aws transcribe get-transcription-job --transcription-job-name clf37-job-1 \
          --query 'TranscriptionJob.TranscriptionJobStatus' --output text)
     echo "$(date +%T) $S"
     [ "$S" != "IN_PROGRESS" ] && break
     sleep 15
   done

   aws s3 cp "s3://${BUCKET}/transcripts/clf37-job-1.json" - | jq -r '.results.transcripts[0].transcript'
   ```

   ```
   12:41:07 IN_PROGRESS
   12:41:22 IN_PROGRESS
   12:41:37 COMPLETED
   Your order number 1008 has shipped and arrives on Friday.
   ```

### 3e. Amazon Rekognition — computer vision

10. Upload any photograph you own (JPEG or PNG, under 15 MB) and label it.

    ```bash
    aws s3 cp ~/Pictures/photo.jpg "s3://${BUCKET}/images/photo.jpg"

    aws rekognition detect-labels \
      --image "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"images/photo.jpg\"}}" \
      --max-labels 8 \
      --query 'Labels[].{Label:Name,Confidence:Confidence}' --output table
    ```

    ```
    -------------------------------
    |         DetectLabels        |
    +-------------+---------------+
    | Confidence  |     Label     |
    +-------------+---------------+
    |  99.4       |  Person       |
    |  98.7       |  Clothing     |
    |  95.1       |  Outdoors     |
    |  91.6       |  City         |
    |  88.0       |  Building     |
    +-------------+---------------+
    ```

11. Content moderation — the same service, a different API, a different business problem.

    ```bash
    aws rekognition detect-moderation-labels \
      --image "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"images/photo.jpg\"}}" \
      --query 'ModerationLabels'
    ```

    ```json
    []
    ```

    > **Region gotcha:** the S3 bucket must be in the **same region** as the Rekognition endpoint you are calling. A cross-region object returns `InvalidS3ObjectException`, whose message does not mention regions at all.

### 3f. Amazon Textract — document text and structure

12. Upload any scanned invoice, receipt, or single-page PDF you have and extract the text.

    ```bash
    aws s3 cp ~/Documents/invoice.png "s3://${BUCKET}/docs/invoice.png"

    aws textract detect-document-text \
      --document "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"docs/invoice.png\"}}" \
      --query 'Blocks[?BlockType==`LINE`].Text' --output text | head -8
    ```

    ```
    ACME SUPPLIES S.L.
    Invoice #  INV-2026-0912
    Date 2026-09-01
    Bill To: Contoso Ltd
    Description  Qty  Unit  Amount
    Laptop stand  2  39.00  78.00
    Subtotal  78.00
    Total EUR  94.38
    ```

13. Ask for structure, not just characters — this is the line between Textract and plain OCR.

    ```bash
    aws textract analyze-document \
      --document "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"docs/invoice.png\"}}" \
      --feature-types '["FORMS","TABLES"]' \
      --query 'Blocks[].BlockType' --output text | tr '\t' '\n' | sort | uniq -c
    ```

    ```
        14 CELL
         1 PAGE
        22 LINE
         9 KEY_VALUE_SET
         2 TABLE
        61 WORD
    ```

**Comprehension check — Block 3**

- **Q3.1** For each of the six services above, write the one-line business trigger phrase an exam question would use. (e.g. "…wants to know whether customers are angry" → ?)
- **Q3.2** Rekognition returned `Person` at 99.4% and `Building` at 88.0%. What is that number, and what design decision does it force on the application consuming the API?
- **Q3.3** Transcribe returned `IN_PROGRESS` and needed polling; Comprehend returned an answer immediately. What architectural difference does that reflect, and what does it imply about how you invoke the two from a Lambda function?
- **Q3.4** A hospital wants to extract diagnoses and medication names from clinical notes, and separately to extract fields from scanned insurance claim forms. Two different services — name both, and name their healthcare-specialised variants.
- **Q3.5** Distinguish, in one sentence each: **Amazon Textract**, **Amazon Rekognition** (`detect-text` API), and **Amazon Comprehend**. All three "read text". What is each actually for?
- **Q3.6** None of these services required you to supply training data. What is the trade-off you accepted in exchange, and which service would you move to if a pre-trained model is not accurate enough for your domain?

---

## Exercise 4 — Generative AI: Amazon Bedrock (and where Amazon Q sits)

Bedrock is the managed access layer to **foundation models** — Anthropic, Amazon, Meta, Mistral, Cohere, AI21, Stability and others — behind one API, one IAM boundary, and one bill.

1. See the catalogue. This call needs no model access grant.

   ```bash
   aws bedrock list-foundation-models \
     --query 'modelSummaries[].{Provider:providerName,Model:modelId}' --output table | head -20
   ```

   ```
   ------------------------------------------------------------
   |                  ListFoundationModels                    |
   +-------------------------------+--------------------------+
   |            Model              |        Provider          |
   +-------------------------------+--------------------------+
   |  amazon.titan-embed-text-v2:0 |  Amazon                  |
   |  amazon.nova-lite-v1:0        |  Amazon                  |
   |  amazon.nova-pro-v1:0         |  Amazon                  |
   |  anthropic.claude-opus-5      |  Anthropic               |
   |  cohere.embed-english-v3      |  Cohere                  |
   |  meta.llama3-1-70b-instruct-v1:0 | Meta                  |
   |  mistral.mistral-large-2407-v1:0 | Mistral AI            |
   |  stability.sd3-5-large-v1:0   |  Stability AI            |
   +-------------------------------+--------------------------+
   ```

   > **Multiple providers behind one API is the point of Bedrock**, and it is exactly what an exam question means by "access foundation models from Amazon and leading AI companies through a single API."

2. Count how many providers your region offers. This is the "choice of model" claim, verified rather than believed.

   ```bash
   aws bedrock list-foundation-models --query 'modelSummaries[].providerName' --output text \
     | tr '\t' '\n' | sort -u
   ```

3. List cross-region **inference profiles**. Several current models are invoked through a profile ID (geo-prefixed, e.g. `us.`) rather than the bare model ID — the profile routes your request across regions for capacity.

   ```bash
   aws bedrock list-inference-profiles \
     --query 'inferenceProfileSummaries[].{Id:inferenceProfileId,Name:inferenceProfileName}' \
     --output table | head -12
   ```

4. **Grant model access.** On a fresh account, invocation fails until you request access to a model in the Bedrock console (*Model access* → *Modify model access*). This is a console-only step by design — it carries the provider's EULA acceptance. Attempting to invoke without it:

   ```
   An error occurred (AccessDeniedException) when calling the Converse operation:
   You don't have access to the model with the specified model ID.
   ```

5. Once access is granted, invoke a model with the **Converse** API — the model-agnostic entry point.

   ```bash
   aws bedrock-runtime converse \
     --model-id "anthropic.claude-opus-5" \
     --messages '[{"role":"user","content":[{"text":"In one sentence: what does Amazon Athena charge for?"}]}]' \
     --inference-config '{"maxTokens":200,"temperature":0.2}' \
     --query '{Text:output.message.content[0].text,In:usage.inputTokens,Out:usage.outputTokens}'
   ```

   ```json
   {
       "Text": "Amazon Athena charges per terabyte of data scanned by each query, with a 10 MB minimum per query.",
       "In": 24,
       "Out": 23
   }
   ```

   > `usage.inputTokens` / `usage.outputTokens` **is the bill**. Bedrock on-demand pricing is per token, per model. If a question mentions predictable high-volume throughput instead, the answer is **Provisioned Throughput**.

6. Swap the model ID and re-run the identical command. Nothing else changes — that portability is Bedrock's core value proposition.

   ```bash
   aws bedrock-runtime converse \
     --model-id "amazon.nova-lite-v1:0" \
     --messages '[{"role":"user","content":[{"text":"In one sentence: what does Amazon Athena charge for?"}]}]' \
     --inference-config '{"maxTokens":200}' \
     --query 'output.message.content[0].text' --output text
   ```

**Comprehension check — Block 4**

- **Q4.1** Bedrock is described as "serverless". Given that a foundation model is one of the largest artefacts in computing, what exactly is serverless about it, and what are you *not* managing?
- **Q4.2** Your company wants a chatbot grounded in its own 40,000 internal PDFs. Name the Bedrock capability that does this without retraining a model, and name the *separate, fully managed* service in the exam guide that does enterprise document search with the same goal.
- **Q4.3** Distinguish **Amazon Q Developer** from **Amazon Q Business** in one line each.
- **Q4.4** A regulated customer asks whether their prompts are used to train the underlying foundation models. What is the correct answer for Bedrock, and which security property of the service does it rest on?
- **Q4.5** Rank these three by "how much ML work do I do myself", lowest first: Amazon Rekognition, Amazon Bedrock, Amazon SageMaker AI.

---

## Exercise 5 — Amazon SageMaker AI: the build-your-own tier

SageMaker is the **only** service in this topic where *you* bring data, choose an algorithm, train, and deploy. Everything you create here costs money by the instance-hour, so this exercise is deliberately read-only.

1. Confirm there is nothing running (and learn the CLI verbs that show where cost hides).

   ```bash
   aws sagemaker list-domains --query 'Domains[].{Name:DomainName,Status:Status}' --output table
   aws sagemaker list-notebook-instances --query 'NotebookInstances[].{Name:NotebookInstanceName,Status:NotebookInstanceStatus,Type:InstanceType}' --output table
   aws sagemaker list-endpoints --query 'Endpoints[].{Name:EndpointName,Status:EndpointStatus}' --output table
   aws sagemaker list-training-jobs --max-results 5 --query 'TrainingJobSummaries[].{Name:TrainingJobName,Status:TrainingJobStatus}' --output table
   ```

   ```
   -------------------
   |   ListDomains   |
   +-----------------+
   |      None       |
   +-----------------+
   ```

   > **The endpoint is the expensive one.** A SageMaker real-time inference endpoint is a provisioned instance that bills 24/7 whether or not anyone calls it. `list-endpoints` returning empty is a cost audit, not a formality. If a question describes "sporadic, unpredictable inference traffic and we don't want to pay while idle", the answer is **Serverless Inference** or **Asynchronous Inference**, not a real-time endpoint.

2. Map the lifecycle to the API surface. Run each and read the verb, not the (empty) output:

   ```bash
   aws sagemaker list-labeling-jobs   --max-results 3 --query 'LabelingJobSummaryList[].LabelingJobName'   # label
   aws sagemaker list-processing-jobs --max-results 3 --query 'ProcessingJobSummaries[].ProcessingJobName' # prepare
   aws sagemaker list-training-jobs   --max-results 3 --query 'TrainingJobSummaries[].TrainingJobName'     # train
   aws sagemaker list-models          --max-results 3 --query 'Models[].ModelName'                         # package
   aws sagemaker list-endpoints       --max-results 3 --query 'Endpoints[].EndpointName'                   # deploy
   ```

   ```
   []
   []
   []
   []
   []
   ```

   Those five verbs *are* the ML lifecycle: **label → prepare → train → package → deploy**, and SageMaker has a managed capability for each — Ground Truth, Data Wrangler / Processing, Training Jobs, Model Registry, Endpoints.

3. **Do not create a domain or an endpoint for this lab.** If you want to explore the console, use SageMaker Studio's *JumpStart* catalogue in read-only mode and close it without deploying.

**Comprehension check — Block 5**

- **Q5.1** A retailer wants to predict which customers will churn next quarter, using seven years of their own transaction history. Rekognition, Bedrock, or SageMaker AI? Why can the other two not do it?
- **Q5.2** What is Amazon SageMaker Ground Truth for, and which unglamorous, expensive step of the ML lifecycle does it address?
- **Q5.3** A team has a trained SageMaker model and highly variable traffic — hundreds of requests some minutes, zero for hours. Name the inference option that avoids paying for idle capacity.
- **Q5.4** Explain, in cost terms, why `aws sagemaker list-endpoints` is the first command to run when investigating an unexpected ML bill.
- **Q5.5** A workflow needs a human to review low-confidence predictions before they are acted upon. Which service provides that human-review loop?

---

## Exercise 6 — Warehouse, search, BI and governance: the rest of the analytics family

These services are the expensive half of the topic. You will **identify** them from the CLI without provisioning any of them.

1. Confirm nothing is running, and learn each service's "is it costing me money" command.

   ```bash
   aws redshift describe-clusters            --query 'Clusters[].{Id:ClusterIdentifier,Status:ClusterStatus,Node:NodeType}' --output table
   aws redshift-serverless list-workgroups   --query 'workgroups[].{Name:workgroupName,Status:status}' --output table
   aws emr list-clusters --active            --query 'Clusters[].{Name:Name,State:Status.State}' --output table
   aws opensearch list-domain-names          --query 'DomainNames[].DomainName' --output table
   aws kafka list-clusters-v2                --query 'ClusterInfoList[].{Name:ClusterName,State:State}' --output table
   ```

   ```
   ------------------
   | DescribeClusters|
   +----------------+
   |      None      |
   +----------------+
   ...
   ```

2. Check the governance layer over the data lake you built in Exercise 1.

   ```bash
   aws lakeformation get-data-lake-settings \
     --query 'DataLakeSettings.DataLakeAdmins[].DataLakePrincipalIdentifier' --output text
   ```

   ```
   arn:aws:iam::123456789012:user/lab-admin
   ```

   > Lake Formation sits **on top of** the Glue Data Catalog and adds fine-grained permissions — table, column, row and cell level — enforced across Athena, Redshift Spectrum, EMR and QuickSight. Without it, your only lever is S3 bucket policy, which is all-or-nothing per prefix.

3. Check the BI layer.

   ```bash
   aws quicksight describe-account-subscription --aws-account-id "$ACCOUNT_ID" \
     --query 'AccountInfo.{Edition:Edition,Status:AccountSubscriptionStatus}' 2>&1 | head -3
   ```

   If QuickSight was never enabled:

   ```
   An error occurred (ResourceNotFoundException) when calling the
   DescribeAccountSubscription operation: Account not found.
   ```

   That error is the expected, correct outcome — QuickSight requires an explicit per-account subscription and has its own per-user pricing. **Do not subscribe for this lab.**

4. Check third-party data.

   ```bash
   aws dataexchange list-data-sets --max-results 3 \
     --query 'DataSets[].{Name:Name,Origin:Origin}' --output table
   ```

   ```
   ---------------
   | ListDataSets|
   +-------------+
   |    None     |
   +-------------+
   ```

   AWS Data Exchange is how you **subscribe to** third-party datasets (weather, financial, demographic) and have them delivered into your own S3 — the answer whenever a question says "we need external data we don't produce ourselves."

**Comprehension check — Block 6**

- **Q6.1** Match each workload to exactly one service — Athena, Redshift, EMR, OpenSearch Service, QuickSight, Lake Formation, Data Exchange, Glue:
   a. Petabyte-scale data warehouse with complex joins, feeding a BI team's daily dashboards
   b. Ad-hoc SQL over 400 GB of JSON logs in S3, queried twice a week
   c. Full-text search and log analytics with an interactive dashboard over application logs
   d. Managed Apache Spark and Hadoop for a data-science team's existing PySpark jobs
   e. Interactive, embeddable business dashboards for 300 non-technical users
   f. Column-level access control so analysts see orders but not credit card numbers
   g. Central metadata catalogue plus a serverless ETL job that converts CSV to Parquet
   h. Subscribing to a licensed third-party demographic dataset
- **Q6.2** Athena and Redshift both "run SQL". Give the two decisive discriminators an exam question will hinge on.
- **Q6.3** OpenSearch Dashboards and QuickSight both "show dashboards". What data does each sit on top of, and which one is the general-purpose BI tool?
- **Q6.4** Glue and EMR both "do ETL". Which one is serverless, which one gives you cluster-level control, and which one would a team with existing Hadoop/Spark code choose?
- **Q6.5** You already have a Glue Data Catalog. What does adding Lake Formation buy you that Glue alone does not?

---

## Exercise 7 — Exam drill: scenario → service

Answer each in writing before opening the answers. Aim for the service name plus a five-word reason.

1. A call centre wants transcripts of every recorded call, then wants to know which calls were angry.
2. A media company must auto-generate subtitles in Spanish, French and Japanese for English video.
3. A bank must detect probable fraudulent online account registrations, using its own historical fraud labels, without hiring an ML team.
4. A retailer wants "customers who bought this also bought…" recommendations on its product pages.
5. An enterprise wants employees to ask natural-language questions and get answers sourced from SharePoint, Confluence and S3.
6. A telco wants an automated voice-and-chat bot that understands intent and slots ("book a technician for Tuesday").
7. A logistics firm wants to extract line items from 200,000 scanned bills of lading.
8. A security team wants to detect whether uploaded user avatars contain inappropriate imagery.
9. A SaaS product wants to add a "summarise this ticket thread" button using a large language model, with a choice of model vendors.
10. A game studio streams 500,000 telemetry events per second and needs three independent consumer applications plus 24-hour replay.
11. The same studio wants those events simply landed in S3, compressed, with no code written.
12. A finance team wants a dashboard of daily revenue by region, built by an analyst, refreshed automatically, viewed by 200 people.
13. A data engineer needs to convert 8 TB of daily CSV into partitioned Parquet on a schedule.
14. A research team wants to run their existing Apache Spark and Hive jobs on managed clusters with Spot Instances.
15. A compliance officer requires that analysts querying the data lake never see the `ssn` column.

---

## Exercise 8 — Teardown and cost verification

Do this now, in this order. Dependencies matter: Athena tables reference S3 objects, and the crawler references the database.

1. Drop the Athena/Glue tables and database.

   ```bash
   for T in orders orders_parquet clicks; do
     aws glue delete-table --database-name "$DB" --name "$T" 2>/dev/null
   done
   aws glue delete-crawler --name clf37-orders-crawler
   aws glue delete-database --name "$DB"
   ```

2. Delete the Firehose delivery stream.

   ```bash
   aws firehose delete-delivery-stream --delivery-stream-name clf37-clicks
   aws firehose list-delivery-streams --query 'DeliveryStreamNames'
   ```

   ```json
   []
   ```

3. Delete the Transcribe job record.

   ```bash
   aws transcribe delete-transcription-job --transcription-job-name clf37-job-1
   ```

4. Empty and remove the bucket. **Look before you delete** — this is irreversible.

   ```bash
   aws s3 ls "s3://${BUCKET}" --recursive --summarize | tail -3
   aws s3 rb "s3://${BUCKET}" --force
   ```

   ```
   Total Objects: 14
      Total Size: 5.1 KiB
   remove_bucket: clf37-lab-123456789012
   ```

5. Remove the IAM roles.

   ```bash
   aws iam delete-role-policy --role-name AWSGlueServiceRole-clf37 --policy-name LabBucketRead
   aws iam detach-role-policy --role-name AWSGlueServiceRole-clf37 \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
   aws iam delete-role --role-name AWSGlueServiceRole-clf37

   aws iam delete-role-policy --role-name FirehoseToS3-clf37 --policy-name WriteLabBucket
   aws iam delete-role --role-name FirehoseToS3-clf37
   ```

6. Verify the spend. Cost data lags by up to 24 hours, so run this tomorrow.

   ```bash
   aws ce get-cost-and-usage \
     --time-period "Start=$(date -u -d '3 days ago' +%F),End=$(date -u +%F)" \
     --granularity DAILY --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=SERVICE \
     --query 'ResultsByTime[-1].Groups[?Metrics.UnblendedCost.Amount!=`0`].{Service:Keys[0],USD:Metrics.UnblendedCost.Amount}' \
     --output table
   ```

   ```
   -------------------------------------------------
   |               GetCostAndUsage                 |
   +----------------------------+------------------+
   |          Service           |       USD        |
   +----------------------------+------------------+
   |  AWS Glue                  |  0.0733          |
   |  Amazon Athena             |  0.0000148       |
   |  Amazon Kinesis Firehose   |  0.0000001       |
   |  Amazon Simple Storage...  |  0.0000021       |
   +----------------------------+------------------+
   ```

   > Each `GetCostAndUsage` API request costs $0.01 — more than most of the lab. Cost Explorer bills for *asking about* your bill, which is a favourite piece of AWS trivia.

7. Optionally delete the budget:

   ```bash
   aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name clf37-lab-guardrail
   ```

**Comprehension check — Block 8**

- **Q8.1** AWS Glue dominated the bill at $0.073 while Athena cost fractions of a cent. Explain both, in terms of each service's pricing dimension.
- **Q8.2** You deleted the Glue tables but the S3 objects survived until step 4. What does that prove about the relationship between the Data Catalog and the data?
- **Q8.3** Which resource in this entire lab would have been the most expensive to forget, and why was it deliberately never created?

---

## Sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide, v1.0 — Domain 3, Task 3.7 and the in-scope service appendix: <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon Athena — What is Athena: <https://docs.aws.amazon.com/athena/latest/ug/what-is.html>
- AWS Glue — What is AWS Glue: <https://docs.aws.amazon.com/glue/latest/dg/what-is-glue.html>
- Amazon Data Firehose — What is Amazon Data Firehose: <https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html>
- Amazon Kinesis Data Streams — Developer Guide introduction: <https://docs.aws.amazon.com/streams/latest/dev/introduction.html>
- Amazon Managed Streaming for Apache Kafka: <https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html>
- Amazon Redshift — Management Guide: <https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html>
- Amazon EMR — What is Amazon EMR: <https://docs.aws.amazon.com/emr/latest/ManagementGuide/emr-what-is-emr.html>
- Amazon OpenSearch Service: <https://docs.aws.amazon.com/opensearch-service/latest/developerguide/what-is.html>
- Amazon QuickSight — User Guide: <https://docs.aws.amazon.com/quicksight/latest/user/welcome.html>
- AWS Lake Formation: <https://docs.aws.amazon.com/lake-formation/latest/dg/what-is-lake-formation.html>
- AWS Data Exchange: <https://docs.aws.amazon.com/data-exchange/latest/userguide/what-is.html>
- Amazon Comprehend: <https://docs.aws.amazon.com/comprehend/latest/dg/what-is.html>
- Amazon Translate: <https://docs.aws.amazon.com/translate/latest/dg/what-is.html>
- Amazon Polly: <https://docs.aws.amazon.com/polly/latest/dg/what-is.html>
- Amazon Transcribe: <https://docs.aws.amazon.com/transcribe/latest/dg/what-is.html>
- Amazon Rekognition: <https://docs.aws.amazon.com/rekognition/latest/dg/what-is.html>
- Amazon Textract: <https://docs.aws.amazon.com/textract/latest/dg/what-is.html>
- Amazon Lex V2: <https://docs.aws.amazon.com/lexv2/latest/dg/what-is.html>
- Amazon Kendra: <https://docs.aws.amazon.com/kendra/latest/dg/what-is-kendra.html>
- Amazon Personalize: <https://docs.aws.amazon.com/personalize/latest/dg/what-is-personalize.html>
- Amazon Fraud Detector: <https://docs.aws.amazon.com/frauddetector/latest/ug/what-is-frauddetector.html>
- Amazon Augmented AI (A2I): <https://docs.aws.amazon.com/sagemaker/latest/dg/a2i-use-augmented-ai-a2i-human-review-loops.html>
- Amazon SageMaker AI: <https://docs.aws.amazon.com/sagemaker/latest/dg/whatis.html>
- Amazon Bedrock: <https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html>
- Amazon Q Business: <https://docs.aws.amazon.com/amazonq/latest/qbusiness-ug/what-is.html>
- Athena pricing (cost model): <https://aws.amazon.com/athena/pricing/> · Glue pricing: <https://aws.amazon.com/glue/pricing/> · Firehose pricing: <https://aws.amazon.com/firehose/pricing/>

---

<details>
<summary><strong>Answers</strong> — open only after attempting every block</summary>

### Block 0 — Preflight

**Q0.1** AWS Budgets belongs to the **Cloud Economics / billing and cost management** category (task 3.8 and Domain 4 territory, not 3.7). A budget **alert** implements **visibility** — it tells you that spend crossed a threshold. It does not stop anything. Control would be an SCP or a hard quota; optimisation would be right-sizing, Savings Plans, or in this topic converting CSV to Parquet. The distinction matters on the exam: "notify me when I exceed $X" is Budgets; "prevent me from launching X" is Service Control Policies or IAM.

**Q0.2** Rekognition and Textract read the image from S3 through an `S3Object` reference, and both require the object to be in the **same region as the API endpoint** you call — a cross-region object fails with `InvalidS3ObjectException`. Comprehend, in the calls we used, takes the text **inline in the request body** (`--text`), so S3 is not involved at all and the bucket's region is irrelevant. The general principle: when an AI service pulls data from S3 rather than receiving it in the payload, co-locate the bucket.

**Q0.3** Because in AWS, S3 **is** the data lake. Every analytics service in this topic either reads from S3 (Athena, Redshift Spectrum, EMR, Glue, QuickSight via SPICE ingestion), writes to it (Firehose, Glue ETL, Transcribe output), or catalogues it (Glue Data Catalog, Lake Formation). The decoupling of storage from compute — durable, cheap, region-scoped object storage that many independent engines query — is the architectural premise of the whole category.

---

### Block 1a/1b — S3 and Glue

**Q1.1** The rows live **in S3**, in `s3://<bucket>/raw/orders/orders.csv`, exactly where you put them. The Glue table is pure **metadata**: a name, a column list with types, a serialisation format, and a location pointer. `aws glue delete-table` destroys only that metadata — the CSV is untouched and any other engine (EMR, Redshift Spectrum, a Spark job, `aws s3 cp`) can still read it. This is the defining property of a data lake as opposed to a database.

**Q1.2** It shows that the crawler **inferred** the schema by sampling the data, and inference is heuristic — `2026-09-01T09:14:02Z` is a valid ISO-8601 timestamp but the crawler saw a quoted string in a CSV and typed it conservatively as `string`. A **defined** schema is one you write yourself (as we did with `CREATE EXTERNAL TABLE` in Exercise 2), where you assert the type. Both are **schema-on-read**: the schema is applied at query time by the engine, and the underlying file never changes. Schema-on-write is the warehouse model — Redshift validates and rewrites data at load time, so a bad row is rejected at ingestion, not discovered at query time.

**Q1.3** (a) The **AWS Glue Data Catalog** — a central, persistent metadata repository (databases, tables, schemas, partitions) shared by Athena, EMR, Redshift Spectrum and others. (b) **Glue ETL** — serverless Apache Spark jobs that extract, transform and load data, plus the crawlers that populate the catalogue. A third, exam-visible member: **AWS Glue DataBrew**, a visual, no-code data-preparation tool for analysts.

**Q1.4** "Nothing is loaded into Glue — the crawler only recorded the file's schema in the Data Catalog; the CSV stays in S3 and Athena reads it there at query time."

---

### Block 1c — Athena

**Q1.5** (a) Store data in a **columnar format** — Parquet or ORC — so a query touching two columns reads only those columns. (b) **Compress** it (Snappy, GZIP): fewer bytes on disk, fewer bytes scanned. (c) **Partition** it by a column that appears in your `WHERE` clauses (date, region), so Athena prunes whole prefixes without opening them. Bonus: **bucketing**, and simply avoiding `SELECT *`.

**Q1.6** It makes Athena **serverless**. The operational consequence is that a team with no data engineers can query terabytes in S3 on day one — there is no cluster to size, patch, scale, back up, or leave running overnight — and the cost falls to zero when nobody queries. The trade-off is that you cannot tune the engine, and per-query cost grows linearly with data scanned rather than being amortised over an owned cluster.

**Q1.7** Move to **Amazon Redshift** (or Redshift Serverless). The economic difference: Athena charges **per query, per byte scanned** — brilliant for infrequent, unpredictable queries, punishing for repetitive high-volume ones. Redshift charges for **provisioned capacity over time** (node-hours or RPU-hours), which is a fixed cost you amortise across unlimited queries, and it adds columnar storage, sort/distribution keys, result caching and materialised views that make repeated dashboard queries dramatically faster. 400 identical scans of 2 TB/hour on Athena would cost roughly $4,000/hour; a Redshift cluster serving that pattern is a few dollars an hour.

**Q1.8** Athena writes every query's result set — plus metadata and a manifest — as objects in the S3 location you specify. It is a governance question because those result objects **contain the query output**: if the source table holds PII, the results bucket now holds PII too, under a prefix nobody thinks to review. Result locations need the same encryption, bucket policy, lifecycle rules and access logging as the source data. (Workgroups exist partly to enforce a result location and encryption centrally, so users cannot choose their own.)

---

### Block 2 — Streaming

**Q2.1** **Amazon Data Firehose delivers streaming data to a destination for you, with no consumer code and no shard management; Amazon Kinesis Data Streams gives you a durable, replayable stream that your own applications read at your own pace.** Firehose is delivery-as-a-service; Data Streams is a stream you own.

**Q2.2** It is **near-real-time**, not real-time. Latency is governed by the **buffering hints** — `SizeInMBs` and `IntervalInSeconds` — and Firehose flushes when *either* threshold is reached. We set 1 MB / 60 s, so 30 tiny records waited the full minute. Kinesis Data Streams, by contrast, makes records available to consumers within milliseconds.

**Q2.3** **Kinesis Data Streams.** Two properties: (a) **retention and replay** — records are retained (24 hours by default, extendable up to 365 days) and a consumer can re-read from any point, which Firehose cannot do because it has no consumer-visible stream; (b) **multiple independent consumers** — several applications can read the same stream at their own offsets, each with its own checkpoint, and with enhanced fan-out each gets dedicated throughput. Firehose has exactly one destination and no consumer offsets. Sub-second custom processing also rules Firehose out on latency alone.

**Q2.4** **Amazon MSK** (Managed Streaming for Apache Kafka). It runs actual open-source Apache Kafka, so existing producers, consumers, Kafka Connect connectors and Kafka client libraries work unchanged. Kinesis is a different API with different semantics (shards, not partitions; a different SDK) — migrating to it is an application rewrite, which is exactly what the requirement excludes. MSK is also the right answer to any question containing "open source", "avoid vendor lock-in", or "existing Kafka".

**Q2.5** **Amazon Managed Service for Apache Flink** (the service formerly branded Amazon Kinesis Data Analytics). It performs continuous, stateful, windowed processing on a stream — aggregations, joins, anomaly detection — before the data reaches a destination.

**Q2.6** **Amazon Kinesis Video Streams.**

---

### Block 3 — Pre-trained AI services

**Q3.1**
| Service | Exam trigger phrase |
|---|---|
| **Amazon Comprehend** | "…wants to know whether customers are angry" / "extract entities, key phrases, topics, or PII from text" |
| **Amazon Translate** | "…localise content into 12 languages" / "translate customer messages in real time" |
| **Amazon Polly** | "…turn articles into audio" / "give the IVR a natural-sounding voice" |
| **Amazon Transcribe** | "…convert recorded calls or meetings into searchable text" / "generate captions" |
| **Amazon Rekognition** | "…identify objects, faces, or unsafe content in images and video" |
| **Amazon Textract** | "…extract text, form fields, and tables from scanned documents" |

**Q3.2** It is a **confidence score** — the model's estimated probability that the label is correct — not a guarantee. It forces you to choose a **confidence threshold** and decide what happens below it: reject, ignore, or route to a human. That last option is exactly what **Amazon Augmented AI (A2I)** exists for. Any application that treats an 88% label as a fact has silently accepted a 12% error rate.

**Q3.3** Transcribe is **asynchronous batch**: you start a job, the service processes a media file that may be hours long, and you poll or receive an event when it completes. Comprehend's `detect-*` APIs are **synchronous**: request in, inference out, in one call. From Lambda, the synchronous call is a plain SDK call inside the handler; the asynchronous one must **not** be waited on with `sleep` — a Lambda blocking for 15 minutes on a poll loop burns duration cost and can hit the timeout. The correct pattern is start-job-and-return, then have completion trigger a second Lambda via EventBridge or an S3 event on the output location. (Comprehend also has async batch APIs — `start-sentiment-detection-job` — for large document sets.)

**Q3.4** Clinical notes → **Amazon Comprehend Medical** (extracts medical entities, medication, dosage, PHI, and codes them to ICD-10-CM / RxNorm). Scanned insurance claim forms → **Amazon Textract**, and its healthcare-oriented capability **Amazon Textract Analyze Health** / the medical document analysis features. The general rule: unstructured **text you already have** → Comprehend; **pixels of a document** → Textract.

**Q3.5**
- **Amazon Textract** — extracts text *and structure* (key–value form fields, tables, cells) from scanned documents and PDFs. It understands that "Total EUR" and "94.38" are a pair.
- **Amazon Rekognition `detect-text`** — finds text that happens to appear *in a scene*: a street sign, a jersey number, a licence plate, a caption burned into a video frame. No document structure, no forms.
- **Amazon Comprehend** — does not read images at all. It takes text that is already digital and tells you what it *means*: sentiment, entities, key phrases, language, PII, topics.

**Q3.6** You accepted a **general-purpose model you cannot control** — trained on someone else's data, tuned for the average case, with no visibility into or influence over its behaviour on your specific domain (medical jargon, an unusual accent, your product's part numbers). If it is not accurate enough, the escalation path is: **customisation within the service where it exists** (Comprehend custom classification and custom entity recognition, Rekognition Custom Labels, Transcribe custom vocabulary and language models, Translate Active Custom Translation) → and if that is still insufficient, **Amazon SageMaker AI**, where you train your own model on your own data.

---

### Block 4 — Bedrock and Amazon Q

**Q4.1** Serverless here means you provision, patch, scale and pay for **no inference infrastructure**. You are not managing GPU instances, model weights, container images, autoscaling groups, or model-server software; the model is invoked through an HTTPS API and billed per token. What is *not* abstracted away is model choice, prompt design, and — for high steady throughput — the decision to buy Provisioned Throughput instead of on-demand.

**Q4.2** **Knowledge Bases for Amazon Bedrock**, which implements **Retrieval Augmented Generation (RAG)**: the documents are chunked, embedded into a vector store, and the relevant passages are retrieved and injected into the prompt at query time — the foundation model itself is never retrained. The separate fully managed service is **Amazon Kendra**, an intelligent enterprise search service with connectors to SharePoint, Confluence, S3, Salesforce and others, returning ranked answers to natural-language questions. Exam heuristic: "search across enterprise repositories" → Kendra; "a generative assistant grounded in my documents" → Bedrock Knowledge Bases or Amazon Q Business.

**Q4.3**
- **Amazon Q Developer** — a generative-AI assistant for software development and for operating AWS: code suggestions in the IDE, code transformation and upgrades, and answering questions about your AWS account and resources.
- **Amazon Q Business** — a generative-AI assistant for employees, connected to enterprise content (documents, wikis, ticketing, chat), answering questions and taking actions while respecting each user's existing permissions.

**Q4.4** No — your prompts and completions are **not** used to train the underlying foundation models, and are not shared with the model providers. It rests on Bedrock's tenancy and data-handling guarantees: your data stays within your AWS account boundary and region, in transit and at rest encryption applies, you can keep traffic on **AWS PrivateLink** so it never traverses the public internet, and for customised models the fine-tuned copy is private to you. This is the standard answer to "can we use generative AI with regulated data".

**Q4.5** Lowest ML work first:
1. **Amazon Rekognition** — call an API, get a label. No data, no model, no prompt.
2. **Amazon Bedrock** — choose a model and write a prompt; optionally add RAG or fine-tuning. No training infrastructure.
3. **Amazon SageMaker AI** — bring data, engineer features, choose an algorithm, train, evaluate, deploy, monitor.

---

### Block 5 — SageMaker AI

**Q5.1** **Amazon SageMaker AI.** Churn prediction on seven years of *proprietary* transaction history is a supervised learning problem on data only this retailer has, with a target variable (churned / did not churn) only they can label. Rekognition cannot do it because it is a fixed computer-vision API — wrong modality entirely, and not customisable to tabular business data. Bedrock cannot do it well because foundation models are trained on general corpora and have no knowledge of this retailer's customers; you could prompt one with a handful of examples, but you cannot get a calibrated per-customer probability learned from millions of historical rows. SageMaker is the only tier where "train on my data" is the product.

**Q5.2** **SageMaker Ground Truth** builds **labelled training datasets** — it orchestrates human annotators (your own workforce, a vendor, or Amazon Mechanical Turk) and uses active learning to auto-label the easy examples so humans only see the hard ones. It addresses **data labelling**, which is routinely the most expensive, slowest and least glamorous step of any supervised ML project, and the one most often underestimated in project plans.

**Q5.3** **SageMaker Serverless Inference.** It provisions and scales compute on demand and scales to zero between requests, so you pay only for inference duration rather than for an always-on endpoint. (For large payloads or long-running inference with tolerance for delay, **Asynchronous Inference** is the sibling answer; for offline scoring of a whole dataset, **Batch Transform**.)

**Q5.4** Because a **real-time inference endpoint is a provisioned instance that bills continuously**, 24 hours a day, regardless of whether a single prediction is requested. Training jobs are bounded — they start, they finish, they stop billing. Notebook instances also bill while running, but they are usually visible to their owner. A forgotten endpoint from a proof-of-concept six months ago is the classic silent ML cost, which is why `list-endpoints` is the first place to look.

**Q5.5** **Amazon Augmented AI (A2I)** — it builds human review workflows into ML predictions, routing low-confidence results (from Rekognition, Textract, or your own SageMaker model) to human reviewers before they are acted on.

---

### Block 6 — Warehouse, search, BI, governance

**Q6.1**
a. **Amazon Redshift** — petabyte-scale data warehouse, complex joins, BI workload.
b. **Amazon Athena** — ad-hoc, infrequent SQL directly over S3; nothing to run between queries.
c. **Amazon OpenSearch Service** — full-text search and log analytics, with OpenSearch Dashboards.
d. **Amazon EMR** — managed Hadoop/Spark clusters for existing PySpark jobs.
e. **Amazon QuickSight** — serverless, embeddable BI for non-technical users, priced per user.
f. **AWS Lake Formation** — fine-grained (column-level) permissions over the data lake.
g. **AWS Glue** — the Data Catalog plus serverless Spark ETL.
h. **AWS Data Exchange** — subscribe to licensed third-party datasets.

**Q6.2** (a) **Where the data lives and who owns the compute**: Athena queries data *in place* in S3 with no infrastructure; Redshift loads data into a *provisioned* warehouse (or Redshift Serverless capacity) that you size and pay for over time. (b) **Query pattern and pricing**: Athena is pay-per-query, best for ad-hoc and infrequent analysis; Redshift is pay-for-capacity, best for sustained, repetitive, high-concurrency analytical workloads with complex joins. Redshift also does schema-on-write with sort/distribution keys; Athena is schema-on-read. (Redshift Spectrum blurs the line by letting Redshift query S3 directly — that is a "we have both" answer, not a discriminator.)

**Q6.3** **OpenSearch Dashboards** sits on data indexed in an **OpenSearch domain** — logs, metrics, documents, traces — and is the operational search/observability front end. **Amazon QuickSight** is the **general-purpose business intelligence** tool: it connects to Redshift, Athena, RDS, S3, SaaS sources and more, has SPICE for fast in-memory aggregation, per-user pricing, embedding, and ML Insights. "Engineers investigating logs" → OpenSearch Dashboards. "The finance department's monthly dashboard" → QuickSight.

**Q6.4** **AWS Glue is serverless** — you submit a job, AWS runs Spark, you pay per DPU-second, and there is no cluster to configure. **Amazon EMR gives you cluster-level control** — instance types, node counts, Spot Instances, bootstrap actions, and the choice of frameworks (Spark, Hive, Presto, HBase, Flink) with specific versions. A team with existing Hadoop/Spark code, custom libraries, or a need to tune the cluster chooses **EMR**; a team that just wants an ETL job to run chooses **Glue**.

**Q6.5** **Fine-grained, centrally administered access control.** Glue's catalogue tells engines *where the data is and what shape it has*, but permission is enforced by IAM and S3 bucket policies — effectively all-or-nothing per prefix. Lake Formation adds **table-, column-, row- and cell-level permissions**, granted to IAM principals in one place and enforced consistently across Athena, Redshift Spectrum, EMR, Glue and QuickSight. It also adds tag-based access control (LF-Tags) and centralised audit of data access. In short: Glue = catalogue; Lake Formation = catalogue **plus governance**.

---

### Block 7 — Scenario drill

1. **Amazon Transcribe** then **Amazon Comprehend** — speech to text, then sentiment on the text. (Amazon Connect Contact Lens packages both for call centres.)
2. **Amazon Transcribe** (generate the English transcript/captions) then **Amazon Translate** (localise them). Transcribe alone gives you subtitles in the spoken language only.
3. **Amazon Fraud Detector** — purpose-built, trained on *your* historical fraud data, no ML expertise required. Not SageMaker (that requires an ML team); not Comprehend (wrong modality).
4. **Amazon Personalize** — real-time personalised recommendations from your interaction data, using the same technology as Amazon.com.
5. **Amazon Kendra** (intelligent enterprise search with those connectors) or **Amazon Q Business** if a conversational generative assistant is wanted. Both are acceptable; Kendra is the classic exam answer for "search across repositories", Q Business for "assistant".
6. **Amazon Lex** — conversational interfaces with intent and slot recognition, for voice and text; it is the engine behind Alexa. Pair with Polly for the voice output.
7. **Amazon Textract** — form and table extraction from scanned documents at scale (asynchronous batch APIs for multi-page documents).
8. **Amazon Rekognition** — `DetectModerationLabels` for inappropriate image content.
9. **Amazon Bedrock** — summarisation via a foundation model, with a choice of providers behind one API.
10. **Amazon Kinesis Data Streams** — high throughput, multiple independent consumers, configurable retention for replay.
11. **Amazon Data Firehose** — zero-code delivery to S3 with built-in compression and format conversion.
12. **Amazon QuickSight** — serverless BI, analyst-built, scheduled refresh, per-user pricing that suits 200 viewers (reader pricing).
13. **AWS Glue** — serverless Spark ETL with scheduled or event-driven triggers, writing partitioned Parquet. (EMR is defensible if they need cluster control, but "on a schedule, converting formats" is Glue's core job.)
14. **Amazon EMR** — managed clusters running their existing Spark and Hive, with Spot Instance support in task nodes.
15. **AWS Lake Formation** — column-level permissions denying access to `ssn` while allowing the rest of the table.

---

### Block 8 — Teardown and cost

**Q8.1** **Glue** bills per **DPU-hour with a 10-minute minimum per crawler run**, charged per second thereafter. Our crawler ran for well under a minute of useful work but was billed the 10-minute floor at roughly $0.44/DPU-hour → ≈$0.073. **Athena** bills per **byte scanned** at ~$5/TB with a 10 MB minimum per query; a handful of queries over a 512-byte file rounds to essentially nothing. The lesson generalises: in serverless analytics, the cost driver is whichever dimension the service actually meters — time for Glue, bytes for Athena, GB ingested for Firehose, tokens for Bedrock, instance-hours for Redshift/EMR/OpenSearch/SageMaker endpoints.

**Q8.2** It proves they are **completely decoupled**. The Data Catalog holds metadata; S3 holds data. Deleting a table removes the ability to query it *by that name in Athena*, and removes nothing else — you could have re-run the crawler and recreated the identical table in two minutes. Conversely, deleting the S3 objects while leaving the table in place gives you a queryable table that returns zero rows. Both halves must be cleaned up, and only the S3 deletion is genuinely destructive.

**Q8.3** A **SageMaker real-time inference endpoint**, or equally an **Amazon Redshift provisioned cluster** or an **Amazon OpenSearch Service domain** — all three are always-on provisioned instances that bill by the hour indefinitely, whether idle or not, and can reach hundreds or thousands of dollars a month. The lab deliberately used only serverless and pay-per-request services (S3, Glue, Athena, Firehose, the AI service APIs, Bedrock on-demand) precisely so that forgetting a teardown step costs cents rather than a rent payment. That asymmetry — *pay-per-use services fail cheap, provisioned services fail expensive* — is worth carrying into any real AWS account.

</details>