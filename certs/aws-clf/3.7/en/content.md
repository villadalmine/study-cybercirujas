# 3.7 — AWS AI/ML and Analytics Services

**Certification:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Domain:** 3 — Cloud Technology and Services
**Task statement weight:** 4.25 % of the exam
**Audience profile:** Platform Architect / SRE. The exam asks *which service*; production asks *at what cost, with what failure mode, and who owns the data*. This unit answers both, and marks clearly which is which.

---

## 1. Motivation: the architectural problem this domain exists to solve

### 1.1 The two pipelines that always show up

Every data-bearing platform eventually grows two pipelines that look different but share a substrate:

```
                     ┌──────────────────────────────────────────────┐
   producers ───────►│  INGEST      Kinesis Data Streams / MSK /    │
   (apps, agents,    │              Data Firehose / DMS / DataSync  │
    IoT, logs, CDC)  └───────────────┬──────────────────────────────┘
                                     │
                     ┌───────────────▼──────────────────────────────┐
                     │  STORE       Amazon S3 (object, 11 nines)    │
                     │              + open table format (Iceberg)   │
                     └───────────────┬──────────────────────────────┘
                                     │
                     ┌───────────────▼──────────────────────────────┐
                     │  CATALOG &   AWS Glue Data Catalog           │
                     │  GOVERN      AWS Lake Formation (LF-Tags)    │
                     └───────┬───────────────────────┬──────────────┘
                             │                       │
        ┌────────────────────▼─────┐     ┌───────────▼────────────────┐
        │ ANALYTICS PLANE          │     │ AI/ML PLANE                │
        │ Athena · EMR · Redshift  │     │ Bedrock (FM API)           │
        │ OpenSearch · MSAF (Flink)│     │ SageMaker AI (build/train) │
        │ QuickSight (BI)          │     │ AI services (Comprehend,   │
        │                          │     │   Textract, Rekognition…)  │
        └──────────────────────────┘     └────────────────────────────┘
```

The architectural decision that governs both planes is **separation of storage and compute**. S3 is the durable, cheap, format-neutral floor; every engine above it is elastic and disposable. That is the whole reason a data lake beats a monolithic warehouse for a platform team: you can run Athena, EMR Spark, Redshift Spectrum and a Bedrock Knowledge Base over *the same bytes* without copying them, and you can delete an engine on Friday without losing data.

### 1.2 The three failure modes this domain is really about

| Failure mode | What it looks like in production | Which service choice prevents it |
|---|---|---|
| **Data gravity / copy sprawl** | Six teams each maintain a private extract of `events`; four disagree on last month's numbers | One S3 lake + Glue Data Catalog as the single metastore; Lake Formation for grants instead of per-team copies |
| **Undifferentiated heavy lifting** | An SRE team runs a 40-node Kafka cluster and a GPU fleet to do sentiment analysis on 200 k tickets/month | MSK (managed Kafka) or Firehose (no cluster at all); Comprehend instead of a self-hosted model |
| **Unbounded, invisible cost** | A single un-partitioned Athena query scans 14 TB; a forgotten Kendra Developer index bills ~$800/month while idle | Workgroup `BytesScannedCutoffPerQuery`, partition projection, Budgets + `AWS::CE::AnomalyMonitor`, and knowing which services bill for *existence* vs *use* |

That last column is the SRE-relevant part of task statement 3.7. The exam tests recognition; the job tests the third column.

### 1.3 The single most important axis: how much of the ML stack do you own?

AWS layers AI/ML in three tiers. **Almost every CLF-C02 scenario question is asking you to place a requirement on this ladder.**

```
  ┌─────────────────────────────────────────────────────────────────┐
  │ TIER 3 — AI SERVICES / APPLICATIONS                             │
  │ You call an API. AWS owns the model, training data, ops.        │
  │ Rekognition · Textract · Transcribe · Translate · Polly ·       │
  │ Comprehend · Lex · Kendra · Personalize · Fraud Detector ·      │
  │ Amazon Q (Developer / Business)                                 │
  │ Skill needed: none in ML. Time to value: hours.                 │
  ├─────────────────────────────────────────────────────────────────┤
  │ TIER 2 — MANAGED FM / PLATFORM                                  │
  │ You own the prompt, the data, the guardrails, the evaluation.   │
  │ AWS owns the model weights and the serving fleet.               │
  │ Amazon Bedrock (FM API, Knowledge Bases, Agents, Guardrails)    │
  │ Amazon SageMaker AI (notebooks, training jobs, endpoints,       │
  │   Feature Store, Pipelines, Model Monitor, JumpStart)           │
  │ Skill needed: ML/prompt engineering. Time to value: days–weeks. │
  ├─────────────────────────────────────────────────────────────────┤
  │ TIER 1 — INFRASTRUCTURE & FRAMEWORKS                            │
  │ You own everything above the hypervisor.                        │
  │ EC2 P5/G6/Trn2/Inf2 · EKS + Neuron/NVIDIA device plugins ·      │
  │ AWS Trainium / AWS Inferentia · Deep Learning AMIs & Containers │
  │ Skill needed: deep. Time to value: weeks–months.                │
  └─────────────────────────────────────────────────────────────────┘
```

**Exam heuristic:** the correct answer is the *highest tier that satisfies the stated requirement*. "Extract text from scanned invoices" → Tier 3 (Textract), not "train a model on SageMaker". "Fine-tune on our proprietary labelled dataset with custom loss" → Tier 2 (SageMaker AI). Only an explicit "we need a custom CUDA kernel / specific framework build" pushes you to Tier 1.

---

## 2. The AI/ML services, with trade-offs

### 2.1 Tier 3 — AI services (managed API, no ML expertise)

| Service | Modality | Core job | Sync / Async | Custom-model support | Classic exam trigger phrase |
|---|---|---|---|---|---|
| **Amazon Rekognition** | Image, video | Object/scene labels, faces, moderation, text-in-image, PPE | Both (async for stored video) | Custom Labels | "detect inappropriate images", "count people in video" |
| **Amazon Textract** | Document | OCR + **structure**: forms (key/value), tables, signatures, queries | Sync (1 page) / Async (multi-page PDF) | Adapters (Custom Queries) | "extract fields from scanned forms/invoices" |
| **Amazon Transcribe** | Audio → text | ASR, speaker diarization, PII redaction, medical/call analytics | Both (streaming + batch) | Custom vocabulary, custom language model | "generate subtitles", "transcribe support calls" |
| **Amazon Polly** | Text → audio | TTS; standard / neural / long-form / generative engines; SSML; speech marks | Sync (+ async for long) | Brand Voice (custom, via AWS) | "convert articles to speech", "IVR prompts" |
| **Amazon Translate** | Text → text | Neural MT, 75+ languages, formality & profanity controls | Both | Active Custom Translation, custom terminology | "localise the UI/content into N languages" |
| **Amazon Comprehend** | Text | Sentiment, entities, key phrases, language, **PII detection**, topic modelling | Both | Custom classification, custom entity recognition | "analyse sentiment of reviews", "find PII in documents" |
| **Amazon Lex** | Conversational | ASR + NLU bots, intents/slots; powers Connect IVR | Sync | Bot-level (you author intents) | "build a chatbot", "voice IVR" |
| **Amazon Kendra** | Search | Enterprise semantic search over connectors (S3, SharePoint, Confluence…), ACL-aware | Sync | Relevance tuning, custom synonyms | "natural-language search across internal docs" |
| **Amazon Personalize** | Recommendation | Real-time personalisation, similar-items, ranking | Sync (campaign) / batch | You bring interactions dataset | "product recommendations like Amazon.com" |
| **Amazon Fraud Detector** | Tabular | Online fraud/abuse scoring from historical fraud data | Sync | You bring labelled events | "detect fraudulent new accounts/payments" |
| **Amazon Augmented AI (A2I)** | Human loop | Routes low-confidence predictions to human reviewers | Async workflow | n/a | "human review when confidence is low" |

> **Currency warning (SRE-relevant, exam-irrelevant).** AWS has closed several older AI services to new customers or announced end-of-support after the CLF-C02 v1.0 exam guide was published — among them **Amazon Forecast**, **Amazon Lookout for Metrics**, **Amazon Monitron**, and **Amazon DeepComposer**; **Amazon CodeGuru Reviewer** and **Amazon CodeWhisperer** were folded into **Amazon Q Developer**. For the exam, treat them as "the forecasting service", "the anomaly-detection service", etc. For a real design, check the service FAQ page before you build on one. Renames you *will* see on the exam under the old name: **Kinesis Data Firehose → Amazon Data Firehose**, **Kinesis Data Analytics → Amazon Managed Service for Apache Flink**, **Amazon Elasticsearch Service → Amazon OpenSearch Service**, **Amazon SageMaker → Amazon SageMaker AI** (the ML platform).

### 2.2 Tier 2 — Bedrock vs SageMaker AI: the decision that actually costs money

| Dimension | **Amazon Bedrock** | **Amazon SageMaker AI** |
|---|---|---|
| Unit of work | An API call to a hosted foundation model | A training job, a processing job, an endpoint you size |
| What you provision | Nothing (on-demand) or *Provisioned Throughput* in Model Units | Instances: `ml.g6.xlarge`, `ml.p5.48xlarge`, `ml.m5.large`… |
| Billing shape | **Per token** (input/output), or per MU-hour if provisioned | **Per instance-second**, whether or not traffic arrives |
| Idle cost | **Zero** on-demand | Full endpoint cost 24×7 unless serverless/async |
| Cold start | None (on-demand) | Endpoint create/update: minutes; Serverless Inference: seconds |
| Model choice | Anthropic, Meta, Mistral, Cohere, AI21, Stability, Amazon Nova/Titan, DeepSeek… | Anything you can containerise; JumpStart for pre-built |
| Customisation | Prompting → RAG (Knowledge Bases) → fine-tuning → continued pre-training | Full: custom architectures, custom loss, distributed training |
| Data isolation | Your prompts/completions are **not** used to train the base models; fine-tuned copies are private to your account | Your VPC, your containers, your weights |
| Safety controls | **Guardrails** (content filters, denied topics, PII, contextual grounding) as a first-class, model-independent resource | You build it |
| Fit for | GenAI features, RAG, agents, summarisation, classification-by-prompt | Classical ML (tabular, forecasting, CV), custom deep learning, strict latency/cost at high sustained QPS |

**The crossover.** On-demand Bedrock beats a dedicated endpoint until utilisation is high and sustained. A rough production rule: if a `ml.g6.xlarge`-class endpoint would sit above ~60 % utilisation 24×7, a self-hosted or provisioned-throughput option starts to win; below that, per-token on-demand wins, and it wins *enormously* for spiky workloads (a nightly batch job that runs 20 minutes pays for 20 minutes, not 24 hours).

**Bedrock production features you must know exist:**

| Feature | Problem it solves |
|---|---|
| **Knowledge Bases** | Managed RAG: S3 → chunk → embed → vector store (OpenSearch Serverless / Aurora pgvector / Pinecone / Neptune Analytics) → `RetrieveAndGenerate` with citations |
| **Agents** | Multi-step tool use: action groups backed by Lambda + OpenAPI schema |
| **Guardrails** | Model-independent policy: content filters, denied topics, word filters, PII anonymise/block, **contextual grounding** (hallucination check against retrieved context) |
| **Model Evaluation** | Automatic + human evaluation jobs to compare candidate models on your data |
| **Provisioned Throughput** | Guaranteed TPS, required for some custom/fine-tuned models |
| **Cross-region inference profiles** | Routes a request across regions in a geography for capacity/throttle resilience; model IDs prefixed `us.`, `eu.`, `apac.` |
| **Batch inference** | ~50 % cheaper for latency-tolerant bulk jobs, S3-in / S3-out |
| **Prompt caching / Prompt management / Flows** | Cost reduction on repeated context; versioned prompts; visual orchestration |

**Amazon Q** sits above Bedrock as a finished application: **Q Developer** (in-IDE coding, `/dev`, code transformation, CLI agent) and **Q Business** (enterprise assistant over connectors with identity-aware ACLs, IAM Identity Center integrated). Exam cue: "employees ask questions in natural language over company documents, respecting existing permissions" → **Amazon Q Business** (or Kendra if the requirement says *search results*, not *generated answers*).

### 2.3 Tier 1 — accelerator economics

| Chip / family | Purpose | Instance | Notes |
|---|---|---|---|
| **AWS Trainium** (Trn1/Trn2) | Training | `trn1.32xlarge`, `trn2.48xlarge` | AWS silicon; best $/token trained via Neuron SDK |
| **AWS Inferentia** (Inf1/Inf2) | Inference | `inf2.xlarge` … `inf2.48xlarge` | AWS silicon; lowest $/inference for supported models |
| **NVIDIA** | Both | `g6`/`g6e` (L4/L40S), `p5`/`p5e` (H100/H200) | Widest framework compatibility; highest price |

Exam-level takeaway: **Trainium = train, Inferentia = infer, both = AWS-designed silicon for lower cost.** Platform-level takeaway: Neuron requires model compilation (`torch-neuronx`) and not every architecture is supported — validate before you commit a fleet.

---

## 3. The analytics services, with trade-offs

### 3.1 Ingest: the Kinesis family and MSK (the most-missed exam question in this domain)

| Service | Model | You manage | Retention | Replay | Consumers | Use it when |
|---|---|---|---|---|---|---|
| **Kinesis Data Streams** | Ordered shards, pull | Shard count (provisioned) or nothing (on-demand) | 24 h → 365 d | **Yes** | Many, independent, at their own pace | Multiple teams need the same stream; you need replay and ordering per key |
| **Amazon Data Firehose** *(ex-Kinesis Data Firehose)* | Buffered delivery, push | **Nothing** | None (transient) | **No** | Exactly one destination | "Just land it in S3/Redshift/OpenSearch/Splunk/Iceberg" with format conversion |
| **Managed Service for Apache Flink** *(ex-Kinesis Data Analytics)* | Stateful stream processing | Parallelism / KPUs | n/a | via source | n/a | Windowed aggregations, joins, anomaly detection **on the stream** |
| **Kinesis Video Streams** | Media ingest | Nothing | Configurable | Yes | Rekognition Video, HLS/DASH players | Camera/media pipelines |
| **Amazon MSK** | Apache Kafka | Broker sizing (or MSK Serverless) | Configurable | **Yes** | Kafka ecosystem | You already have Kafka clients/Connect/Streams and want compatibility |

The canonical trap: *"stream data to S3 with minimal operational overhead / no code"* → **Data Firehose**. *"Multiple applications must process the same records, and we must be able to reprocess the last 3 days"* → **Kinesis Data Streams**. *"Existing Kafka producers must work unchanged"* → **MSK**.

**Capacity model detail that bites SREs:** a Kinesis Data Streams shard is 1 MB/s or 1 000 records/s **in**, 2 MB/s **out** shared across standard consumers (Enhanced Fan-Out gives each consumer its own 2 MB/s). Hot partition keys create hot shards, and a hot shard throttles *even when the stream average is 5 % utilised*. **On-Demand** mode removes shard management (scales to 200 MB/s in, doubling within 15 min of a new peak) at roughly a 30–40 % premium at steady high utilisation — it is the correct default for unknown or spiky traffic and the wrong default for a flat, predictable 24×7 firehose.

### 3.2 Query & process

| Service | Engine | Provisioning | Billing | Latency class | Best at | Weak at |
|---|---|---|---|---|---|---|
| **Amazon Athena** | Trino/Presto (SQL), also Spark | **Serverless** | **Per TB scanned** (≈$5/TB, 10 MB minimum per query) | Seconds → minutes | Ad-hoc SQL over S3, log analysis, one-off exploration | High-concurrency dashboards; repeated full scans get expensive fast |
| **Amazon Redshift** | MPP columnar warehouse | Provisioned (RA3) or **Serverless** (RPUs) | Node-hours, or RPU-hours | Sub-second → seconds | Complex joins, BI concurrency, materialised views, Zero-ETL from Aurora/RDS/DynamoDB | Semi-structured sprawl; idle provisioned clusters |
| **Amazon EMR** | Spark, Hive, Trino, HBase, Flink | Clusters (EC2/EKS) or **EMR Serverless** | Instance-hours + EMR fee | Minutes → hours | Heavy ETL, ML feature engineering, code-first pipelines, Spot economics | Anything a SQL engine already does; operational surface |
| **AWS Glue** | Serverless Spark + Data Catalog | **Serverless** | **DPU-hours** (≈$0.44/DPU-h) | Minutes | Catalogued ETL, crawlers, streaming ETL, DataBrew (no-code prep) | Long-running interactive work; very large custom Spark tuning |
| **Amazon OpenSearch Service** | Lucene / OpenSearch | Domains or **Serverless** | Instance-hours or OCUs | **Milliseconds** | Log search, observability, full-text, **vector search** for RAG | Large analytical joins; cost at high retention |
| **Amazon QuickSight** | BI + SPICE in-memory engine | Serverless | **Per user/month** + SPICE GB | Sub-second (SPICE) | Dashboards, embedded analytics, **Q** (NL questions), pixel-perfect reports | Being a query engine — it reads *from* the ones above |

**The Athena-vs-Redshift boundary, stated properly.** Athena's cost is a function of *bytes scanned*; Redshift's is a function of *time provisioned*. A query run once a day over 50 GB is trivially cheap on Athena and absurd on a 24×7 cluster. The same query run 4 000 times a day by a dashboard is the reverse. Redshift Serverless (auto-pause, per-second RPU billing, 8-RPU floor) collapses much of that gap — the modern rule is: **Athena for exploration and infrequent scans; Redshift for governed, concurrent, joined BI; EMR/Glue for transformation; OpenSearch for needle-in-haystack and sub-second search.**

### 3.3 Catalog, govern, share

| Service | Role |
|---|---|
| **AWS Glue Data Catalog** | The Hive-compatible metastore. **One catalog per account per region**, shared by Athena, EMR, Redshift Spectrum, Glue, Lake Formation. Tables = schema + S3 location + partitions + SerDe |
| **AWS Glue crawlers** | Infer schema and partitions from S3. Convenient; also the #1 source of surprise tables and schema drift |
| **AWS Lake Formation** | Fine-grained authorisation (database/table/**column**/row/cell) via LF-Tags, layered over Glue Catalog + S3. Replaces "write 200 S3 bucket policies" |
| **Amazon DataZone / SageMaker Catalog** | Business data catalog, domains, publish/subscribe workflows, data products across accounts |
| **AWS Data Exchange** | Find, subscribe to and use **third-party** datasets (delivered to S3, Redshift, or via API) |
| **AWS Clean Rooms** | Two parties join data for analysis **without either party copying or seeing the other's raw rows** |
| **AWS Glue DataBrew** | Visual, no-code data preparation (250+ transforms) for analysts |

Exam cues: "purchase/subscribe to external market data" → **Data Exchange**. "collaborate with a partner on overlapping customers without sharing PII" → **Clean Rooms**. "grant a team access to only the non-PII columns of a table" → **Lake Formation**.

### 3.4 Cost model summary — which services bill for *existence*

This table is the one that saves real money. List prices, `us-east-1`, and they change — the **shape** is the durable part, the numbers are for calibration only (verify in §8).

| Service | Bills while idle? | Dominant cost driver | Blast-radius control |
|---|---|---|---|
| Athena | No | Bytes scanned | Workgroup `BytesScannedCutoffPerQuery`; partitioning; columnar format |
| Glue jobs / crawlers | No | DPU-hours (1-min minimum) | `MaxCapacity`/worker count; crawler schedule; use partition projection instead |
| Data Firehose | No | GB ingested (~$0.029/GB first 500 TB) | Buffering hints; compression |
| Kinesis Data Streams (provisioned) | **Yes** — per shard-hour | Shard-hours (~$0.015) + PUT units | Right-size shards; On-Demand for spiky |
| Kinesis Data Streams (on-demand) | **Yes** — per stream-hour (~$0.04) | GB in/out | Delete unused streams |
| Redshift provisioned | **Yes** — node-hours | Node type × count | Pause cluster; RA3 + Spectrum |
| Redshift Serverless | No (auto-pause) | RPU-hours (~$0.36) | Base RPU floor, max RPU cap, usage limits |
| EMR cluster | **Yes** — instance-hours | Instances + EMR uplift | Auto-termination, Spot task nodes, EMR Serverless |
| OpenSearch domain | **Yes** — instance + EBS hours | Node count/type, storage | UltraWarm/Cold tiers; OpenSearch Serverless OCUs |
| QuickSight | **Yes** — per user/month | Authors, Readers, SPICE GB | Reader capacity pricing; remove dormant authors |
| Kendra | **Yes** — per index-hour (Developer ≈ $1.13/h ≈ **$820/mo idle**) | Index edition | Delete dev indexes nightly; this is the classic bill shock |
| SageMaker real-time endpoint | **Yes** — instance-hours | Instance type × count | Serverless Inference; Async Inference (scales to zero); auto-scaling |
| Bedrock on-demand | **No** | Input/output tokens | Guardrails + `maxTokens`; batch mode; prompt caching |
| Bedrock Provisioned Throughput | **Yes** — MU-hours | Model units × commitment | Only buy after measuring sustained TPS |

---

## 4. Complete infrastructure: three production-grade manifests

### 4.1 Stack A — Streaming lakehouse: Kinesis → Firehose (Parquet, dynamic partitions) → Glue Catalog → Athena

Full, deployable CloudFormation. This is the reference implementation of the ingest→store→catalog→query path.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Streaming lakehouse - Kinesis Data Streams -> Amazon Data Firehose
  (JSON -> Parquet, dynamic partitioning) -> S3 -> Glue Data Catalog -> Athena.
  Cost guardrails and delivery-freshness alarms included.

Parameters:
  ProjectName:
    Type: String
    Default: teach-plat
    AllowedPattern: '^[a-z][a-z0-9-]{2,32}$'
    Description: Lowercase prefix used for every resource name.
  RetentionHours:
    Type: Number
    Default: 24
    MinValue: 24
    MaxValue: 8760
    Description: Kinesis stream retention. 24h is free; beyond that is billed extra.
  AthenaScanCapBytes:
    Type: Number
    Default: 107374182400   # 100 GiB per query = ~USD 0.50 at 5 USD/TB
    Description: Hard per-query scan ceiling enforced by the Athena workgroup.
  DataFreshnessThresholdSeconds:
    Type: Number
    Default: 900
    Description: Alarm if Firehose has undelivered data older than this.

Resources:

  # ---------------------------------------------------------------- KMS ----
  LakeKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for ${ProjectName} lakehouse at-rest encryption'
      EnableKeyRotation: true
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnableAccountRoot
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowServiceUse
            Effect: Allow
            Principal:
              Service:
                - firehose.amazonaws.com
                - athena.amazonaws.com
                - glue.amazonaws.com
            Action:
              - kms:Decrypt
              - kms:GenerateDataKey
              - kms:DescribeKey
            Resource: '*'
            Condition:
              StringEquals:
                'kms:CallerAccount': !Ref AWS::AccountId

  LakeKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/${ProjectName}-lake'
      TargetKeyId: !Ref LakeKey

  # ----------------------------------------------------------------- S3 ----
  LakeBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${ProjectName}-lake-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - BucketKeyEnabled: true          # cuts KMS request cost by ~99%
            ServerSideEncryptionByDefault:
              SSEAlgorithm: aws:kms
              KMSMasterKeyID: !Ref LakeKey
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      VersioningConfiguration:
        Status: Enabled
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: expire-athena-results
            Status: Enabled
            Prefix: athena-results/
            ExpirationInDays: 14
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 3
          - Id: tier-curated-data
            Status: Enabled
            Prefix: curated/
            Transitions:
              - StorageClass: INTELLIGENT_TIERING
                TransitionInDays: 0
            NoncurrentVersionExpirationInDays: 30
          - Id: expire-quarantine
            Status: Enabled
            Prefix: quarantine/
            ExpirationInDays: 30

  LakeBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref LakeBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt LakeBucket.Arn
              - !Sub '${LakeBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  # --------------------------------------------------------- Glue meta ----
  GlueDatabase:
    Type: AWS::Glue::Database
    Properties:
      CatalogId: !Ref AWS::AccountId
      DatabaseInput:
        Name: !Sub '${ProjectName}_lakehouse'
        Description: Curated event tables backed by S3 Parquet.
        LocationUri: !Sub 's3://${LakeBucket}/curated/'

  # The schema is declared explicitly: Firehose data-format conversion READS
  # this table to build the Parquet writer. A crawler cannot be the source of
  # truth here, because it would run AFTER the data is already written.
  EventsTable:
    Type: AWS::Glue::Table
    Properties:
      CatalogId: !Ref AWS::AccountId
      DatabaseName: !Ref GlueDatabase
      TableInput:
        Name: events
        TableType: EXTERNAL_TABLE
        Parameters:
          classification: parquet
          'parquet.compression': SNAPPY
          # Partition projection: Athena derives partitions from the prefix
          # pattern instead of reading them from the catalog. No crawler, no
          # MSCK REPAIR, no per-partition GetPartitions latency.
          'projection.enabled': 'true'
          'projection.dt.type': date
          'projection.dt.range': '2026-01-01,NOW'
          'projection.dt.format': 'yyyy-MM-dd'
          'projection.dt.interval': '1'
          'projection.dt.interval.unit': DAYS
          'projection.tenant.type': injected
          'storage.location.template':
            !Sub 's3://${LakeBucket}/curated/events/dt=${!dt}/tenant=${!tenant}'
        PartitionKeys:
          - { Name: dt,     Type: string }
          - { Name: tenant, Type: string }
        StorageDescriptor:
          Location: !Sub 's3://${LakeBucket}/curated/events/'
          InputFormat: org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat
          OutputFormat: org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat
          Compressed: true
          SerdeInfo:
            SerializationLibrary: org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe
            Parameters:
              'serialization.format': '1'
          Columns:
            - { Name: event_id,   Type: string }
            - { Name: event_time, Type: string }
            - { Name: tenant_id,  Type: string }
            - { Name: user_id,    Type: string }
            - { Name: action,     Type: string }
            - { Name: cert_id,    Type: string }
            - { Name: topic_id,   Type: string }
            - { Name: latency_ms, Type: bigint }
            - { Name: status,     Type: string }
            - { Name: attributes, Type: 'map<string,string>' }

  # ------------------------------------------------------------ Kinesis ----
  IngestStream:
    Type: AWS::Kinesis::Stream
    Properties:
      Name: !Sub '${ProjectName}-events'
      StreamModeDetails:
        StreamMode: ON_DEMAND        # no shard management; scales with traffic
      RetentionPeriodHours: !Ref RetentionHours
      StreamEncryption:
        EncryptionType: KMS
        KeyId: !Ref LakeKey

  # ----------------------------------------------------------- Firehose ----
  FirehoseLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/kinesisfirehose/${ProjectName}'
      RetentionInDays: 30

  FirehoseLogStream:
    Type: AWS::Logs::LogStream
    Properties:
      LogGroupName: !Ref FirehoseLogGroup
      LogStreamName: S3Delivery

  FirehoseRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Service: firehose.amazonaws.com }
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'sts:ExternalId': !Ref AWS::AccountId
      Policies:
        - PolicyName: firehose-delivery
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - s3:AbortMultipartUpload
                  - s3:GetBucketLocation
                  - s3:GetObject
                  - s3:ListBucket
                  - s3:ListBucketMultipartUploads
                  - s3:PutObject
                Resource:
                  - !GetAtt LakeBucket.Arn
                  - !Sub '${LakeBucket.Arn}/*'
              - Effect: Allow
                Action:
                  - kinesis:DescribeStream
                  - kinesis:GetShardIterator
                  - kinesis:GetRecords
                  - kinesis:ListShards
                Resource: !GetAtt IngestStream.Arn
              - Effect: Allow            # required for data-format conversion
                Action:
                  - glue:GetTable
                  - glue:GetTableVersion
                  - glue:GetTableVersions
                Resource:
                  - !Sub 'arn:${AWS::Partition}:glue:${AWS::Region}:${AWS::AccountId}:catalog'
                  - !Sub 'arn:${AWS::Partition}:glue:${AWS::Region}:${AWS::AccountId}:database/${GlueDatabase}'
                  - !Sub 'arn:${AWS::Partition}:glue:${AWS::Region}:${AWS::AccountId}:table/${GlueDatabase}/events'
              - Effect: Allow
                Action:
                  - kms:Decrypt
                  - kms:GenerateDataKey
                Resource: !GetAtt LakeKey.Arn
              - Effect: Allow
                Action:
                  - logs:PutLogEvents
                Resource: !GetAtt FirehoseLogGroup.Arn

  DeliveryStream:
    Type: AWS::KinesisFirehose::DeliveryStream
    Properties:
      DeliveryStreamName: !Sub '${ProjectName}-events-to-lake'
      DeliveryStreamType: KinesisStreamAsSource
      KinesisStreamSourceConfiguration:
        KinesisStreamARN: !GetAtt IngestStream.Arn
        RoleARN: !GetAtt FirehoseRole.Arn
      ExtendedS3DestinationConfiguration:
        BucketARN: !GetAtt LakeBucket.Arn
        RoleARN: !GetAtt FirehoseRole.Arn
        # Prefix keys MUST match the Glue PartitionKeys, in the same order.
        Prefix: 'curated/events/dt=!{partitionKeyFromQuery:dt}/tenant=!{partitionKeyFromQuery:tenant}/'
        # CRITICAL: the error prefix lives OUTSIDE the table location.
        # Quarantined JSON under a Parquet table location breaks every query
        # with HIVE_CURSOR_ERROR: Not valid Parquet file.
        ErrorOutputPrefix: 'quarantine/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/'
        BufferingHints:
          IntervalInSeconds: 60      # dynamic partitioning requires >= 60
          SizeInMBs: 128             # target ~128 MB objects: fewer, larger files
        CompressionFormat: UNCOMPRESSED   # MUST be UNCOMPRESSED when converting
                                          # to Parquet (Parquet compresses itself)
        EncryptionConfiguration:
          KMSEncryptionConfig:
            AWSKMSKeyARN: !GetAtt LakeKey.Arn
        DynamicPartitioningConfiguration:
          Enabled: true                   # cannot be enabled after creation
          RetryOptions:
            DurationInSeconds: 300
        ProcessingConfiguration:
          Enabled: true
          Processors:
            - Type: MetadataExtraction
              Parameters:
                - ParameterName: MetadataExtractionQuery
                  ParameterValue: '{dt:.event_time[0:10],tenant:.tenant_id}'
                - ParameterName: JsonParsingEngine
                  ParameterValue: JQ-1.6
        DataFormatConversionConfiguration:
          Enabled: true
          SchemaConfiguration:
            CatalogId: !Ref AWS::AccountId
            DatabaseName: !Ref GlueDatabase
            TableName: events
            Region: !Ref AWS::Region
            RoleARN: !GetAtt FirehoseRole.Arn
            VersionId: LATEST
          InputFormatConfiguration:
            Deserializer:
              OpenXJsonSerDe:
                CaseInsensitive: false
          OutputFormatConfiguration:
            Serializer:
              ParquetSerDe:
                Compression: SNAPPY
                WriterVersion: V1
        CloudWatchLoggingOptions:
          Enabled: true
          LogGroupName: !Ref FirehoseLogGroup
          LogStreamName: !Ref FirehoseLogStream
      Tags:
        - { Key: Project, Value: !Ref ProjectName }
        - { Key: DataClassification, Value: internal }

  # ------------------------------------------------------------- Athena ----
  AnalyticsWorkGroup:
    Type: AWS::Athena::WorkGroup
    Properties:
      Name: !Sub '${ProjectName}-analytics'
      Description: Governed workgroup with a hard per-query scan ceiling.
      State: ENABLED
      RecursiveDeleteOption: true
      WorkGroupConfiguration:
        EnforceWorkGroupConfiguration: true      # users cannot override
        PublishCloudWatchMetricsEnabled: true
        BytesScannedCutoffPerQuery: !Ref AthenaScanCapBytes
        RequesterPaysEnabled: false
        EngineVersion:
          SelectedEngineVersion: AUTO
        ResultConfiguration:
          OutputLocation: !Sub 's3://${LakeBucket}/athena-results/'
          EncryptionConfiguration:
            EncryptionOption: SSE_KMS
            KmsKey: !GetAtt LakeKey.Arn
          ExpectedBucketOwner: !Ref AWS::AccountId

  # ------------------------------------------------------------- Alarms ----
  AlarmTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Sub '${ProjectName}-analytics-alarms'
      KmsMasterKeyId: !Ref LakeKey

  FirehoseFreshnessAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-firehose-data-freshness'
      AlarmDescription: >
        Oldest undelivered record exceeds the freshness SLO. Root causes, in
        order of frequency: S3/KMS permission denial, Glue schema mismatch,
        dynamic-partition key missing from the payload.
      Namespace: AWS/Firehose
      MetricName: DeliveryToS3.DataFreshness
      Dimensions:
        - Name: DeliveryStreamName
          Value: !Ref DeliveryStream
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 2
      Threshold: !Ref DataFreshnessThresholdSeconds
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching
      AlarmActions: [ !Ref AlarmTopic ]

  FirehoseConversionFailureAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-firehose-format-conversion-failed'
      Namespace: AWS/Firehose
      MetricName: FailedConversion.Records
      Dimensions:
        - Name: DeliveryStreamName
          Value: !Ref DeliveryStream
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [ !Ref AlarmTopic ]

  KinesisIteratorAgeAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-kinesis-consumer-lag'
      AlarmDescription: Consumers are falling behind; data loss once age > retention.
      Namespace: AWS/Kinesis
      MetricName: GetRecords.IteratorAgeMilliseconds
      Dimensions:
        - Name: StreamName
          Value: !Ref IngestStream
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 2
      Threshold: 600000          # 10 minutes
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [ !Ref AlarmTopic ]

  KinesisWriteThrottleAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-kinesis-write-throttled'
      AlarmDescription: Hot partition key or insufficient capacity.
      Namespace: AWS/Kinesis
      MetricName: WriteProvisionedThroughputExceeded
      Dimensions:
        - Name: StreamName
          Value: !Ref IngestStream
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 3
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [ !Ref AlarmTopic ]

Outputs:
  LakeBucketName:
    Value: !Ref LakeBucket
    Export: { Name: !Sub '${AWS::StackName}-LakeBucket' }
  StreamName:
    Value: !Ref IngestStream
    Export: { Name: !Sub '${AWS::StackName}-StreamName' }
  DeliveryStreamName:
    Value: !Ref DeliveryStream
  GlueDatabaseName:
    Value: !Ref GlueDatabase
  AthenaWorkGroup:
    Value: !Ref AnalyticsWorkGroup
  SampleQuery:
    Description: Partition-pruned query - scans one day of one tenant only.
    Value: !Sub >-
      SELECT action, count(*) AS n, approx_percentile(latency_ms, 0.95) AS p95
      FROM "${GlueDatabase}"."events"
      WHERE dt = '2026-09-03' AND tenant = 'tenant-7f3a'
      GROUP BY action ORDER BY n DESC;
```

Three details in that template are the ones people get wrong, and each has a matching failure signature in §6: `CompressionFormat: UNCOMPRESSED` with Parquet conversion, `ErrorOutputPrefix` outside the table location, and the Firehose role needing `glue:GetTableVersions` (plural) for schema lookup.

### 4.2 Stack B — Bedrock Knowledge Base with Guardrails (managed RAG)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Managed RAG on Amazon Bedrock: S3 corpus -> Knowledge Base -> OpenSearch
  Serverless vector collection, fronted by a Guardrail with PII anonymisation
  and contextual grounding.

Parameters:
  ProjectName:
    Type: String
    Default: teach-plat
  EmbeddingModelId:
    Type: String
    Default: amazon.titan-embed-text-v2:0
  VectorIndexName:
    Type: String
    Default: bedrock-kb-index
    Description: >
      MUST already exist in the collection. CloudFormation does not create
      OpenSearch indexes; see the runbook in section 6.
  GroundingThreshold:
    Type: Number
    Default: 0.75
    Description: Below this, the answer is treated as ungrounded and blocked.

Resources:

  CorpusBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub '${ProjectName}-kb-corpus-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault: { SSEAlgorithm: AES256 }
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      VersioningConfiguration: { Status: Enabled }

  # ------------------------------------------- OpenSearch Serverless -------
  VectorCollectionEncryptionPolicy:
    Type: AWS::OpenSearchServerless::SecurityPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb-enc'
      Type: encryption
      Policy: !Sub '{"Rules":[{"ResourceType":"collection","Resource":["collection/${ProjectName}-kb"]}],"AWSOwnedKey":true}'

  VectorCollectionNetworkPolicy:
    Type: AWS::OpenSearchServerless::SecurityPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb-net'
      Type: network
      Policy: !Sub '[{"Rules":[{"ResourceType":"collection","Resource":["collection/${ProjectName}-kb"]},{"ResourceType":"dashboard","Resource":["collection/${ProjectName}-kb"]}],"AllowFromPublic":true}]'

  VectorCollection:
    Type: AWS::OpenSearchServerless::Collection
    DependsOn:
      - VectorCollectionEncryptionPolicy
      - VectorCollectionNetworkPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb'
      Type: VECTORSEARCH
      Description: Vector store for the Bedrock Knowledge Base.

  VectorDataAccessPolicy:
    Type: AWS::OpenSearchServerless::AccessPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb-access'
      Type: data
      Policy: !Sub
        - '[{"Rules":[{"ResourceType":"index","Resource":["index/${ProjectName}-kb/*"],"Permission":["aoss:*"]},{"ResourceType":"collection","Resource":["collection/${ProjectName}-kb"],"Permission":["aoss:*"]}],"Principal":["${RoleArn}"]}]'
        - RoleArn: !GetAtt KnowledgeBaseRole.Arn

  # ------------------------------------------------------------- IAM ------
  KnowledgeBaseRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub 'AmazonBedrockExecutionRoleForKnowledgeBase_${ProjectName}'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Service: bedrock.amazonaws.com }
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref AWS::AccountId
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:bedrock:${AWS::Region}:${AWS::AccountId}:knowledge-base/*'
      Policies:
        - PolicyName: kb-permissions
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: 'bedrock:InvokeModel'
                Resource: !Sub 'arn:${AWS::Partition}:bedrock:${AWS::Region}::foundation-model/${EmbeddingModelId}'
              - Effect: Allow
                Action: 'aoss:APIAccessAll'
                Resource: !GetAtt VectorCollection.Arn
              - Effect: Allow
                Action: [ 's3:GetObject', 's3:ListBucket' ]
                Resource:
                  - !GetAtt CorpusBucket.Arn
                  - !Sub '${CorpusBucket.Arn}/*'
                Condition:
                  StringEquals:
                    's3:ResourceAccount': !Ref AWS::AccountId

  # ------------------------------------------------------- Knowledge Base --
  KnowledgeBase:
    Type: AWS::Bedrock::KnowledgeBase
    DependsOn: VectorDataAccessPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb'
      Description: Certification syllabi and study material corpus.
      RoleArn: !GetAtt KnowledgeBaseRole.Arn
      KnowledgeBaseConfiguration:
        Type: VECTOR
        VectorKnowledgeBaseConfiguration:
          EmbeddingModelArn: !Sub 'arn:${AWS::Partition}:bedrock:${AWS::Region}::foundation-model/${EmbeddingModelId}'
      StorageConfiguration:
        Type: OPENSEARCH_SERVERLESS
        OpensearchServerlessConfiguration:
          CollectionArn: !GetAtt VectorCollection.Arn
          VectorIndexName: !Ref VectorIndexName
          FieldMapping:
            VectorField: bedrock-knowledge-base-default-vector
            TextField: AMAZON_BEDROCK_TEXT_CHUNK
            MetadataField: AMAZON_BEDROCK_METADATA

  CorpusDataSource:
    Type: AWS::Bedrock::DataSource
    Properties:
      Name: !Sub '${ProjectName}-corpus'
      KnowledgeBaseId: !Ref KnowledgeBase
      DataDeletionPolicy: RETAIN
      DataSourceConfiguration:
        Type: S3
        S3Configuration:
          BucketArn: !GetAtt CorpusBucket.Arn
          InclusionPrefixes:
            - 'certs/'
      VectorIngestionConfiguration:
        ChunkingConfiguration:
          ChunkingStrategy: FIXED_SIZE
          FixedSizeChunkingConfiguration:
            MaxTokens: 512
            OverlapPercentage: 20

  # ------------------------------------------------------------ Guardrail --
  ContentGuardrail:
    Type: AWS::Bedrock::Guardrail
    Properties:
      Name: !Sub '${ProjectName}-guardrail'
      Description: Safety and grounding policy applied to every model call.
      BlockedInputMessaging: 'That request is outside the scope of this assistant.'
      BlockedOutputsMessaging: 'I could not produce a grounded answer from the available material.'
      ContentPolicyConfig:
        FiltersConfig:
          - { Type: HATE,          InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: INSULTS,       InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: SEXUAL,        InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: VIOLENCE,      InputStrength: MEDIUM, OutputStrength: MEDIUM }
          - { Type: MISCONDUCT,    InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: PROMPT_ATTACK, InputStrength: HIGH,   OutputStrength: NONE }
      SensitiveInformationPolicyConfig:
        PiiEntitiesConfig:
          - { Type: EMAIL,               Action: ANONYMIZE }
          - { Type: PHONE,               Action: ANONYMIZE }
          - { Type: NAME,                Action: ANONYMIZE }
          - { Type: CREDIT_DEBIT_CARD_NUMBER, Action: BLOCK }
          - { Type: AWS_ACCESS_KEY,      Action: BLOCK }
          - { Type: AWS_SECRET_KEY,      Action: BLOCK }
        RegexesConfig:
          - Name: internal-ticket-id
            Description: Redact internal ticket identifiers.
            Pattern: 'TP-[0-9]{6}'
            Action: ANONYMIZE
      TopicPolicyConfig:
        TopicsConfig:
          - Name: ExamAnswerLeakage
            Type: DENY
            Definition: >
              Requests to reproduce verbatim questions or answer keys from a
              live certification exam, or to obtain exam content under NDA.
            Examples:
              - 'Give me the real CLF-C02 questions from the exam.'
              - 'What were the answers on the test you took yesterday?'
      ContextualGroundingPolicyConfig:
        FiltersConfig:
          - { Type: GROUNDING, Threshold: !Ref GroundingThreshold }
          - { Type: RELEVANCE, Threshold: 0.60 }

  GuardrailVersion:
    Type: AWS::Bedrock::GuardrailVersion
    Properties:
      GuardrailIdentifier: !GetAtt ContentGuardrail.GuardrailId
      Description: Initial immutable version pinned by the application.

Outputs:
  KnowledgeBaseId:
    Value: !Ref KnowledgeBase
  DataSourceId:
    Value: !GetAtt CorpusDataSource.DataSourceId
  GuardrailId:
    Value: !GetAtt ContentGuardrail.GuardrailId
  GuardrailVersion:
    Value: !GetAtt GuardrailVersion.Version
  CollectionEndpoint:
    Value: !GetAtt VectorCollection.CollectionEndpoint
```

### 4.3 Stack C — Kubernetes: an inference gateway on EKS calling Bedrock, plus an Inferentia node pool

The platform-team pattern: keep the application in EKS, keep the model in Bedrock, authenticate with IRSA — no long-lived keys anywhere.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ai-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
# IRSA: the trust policy on this IAM role binds the OIDC subject
# system:serviceaccount:ai-platform:rag-gateway. No secrets in the cluster.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rag-gateway
  namespace: ai-platform
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/eks-ai-platform-rag-gateway
    eks.amazonaws.com/sts-regional-endpoints: "true"
automountServiceAccountToken: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rag-gateway-config
  namespace: ai-platform
data:
  AWS_REGION: "eu-west-1"
  # Cross-region inference profile: the "eu." prefix lets Bedrock route the
  # request across EU regions when the home region is at capacity.
  BEDROCK_MODEL_ID: "eu.anthropic.claude-sonnet-4-20250514-v1:0"
  BEDROCK_KB_ID: "KBQ7X3P1AZ"
  BEDROCK_GUARDRAIL_ID: "gr-9k2mfp0qra41"
  BEDROCK_GUARDRAIL_VERSION: "1"
  MAX_OUTPUT_TOKENS: "1024"
  REQUEST_TIMEOUT_SECONDS: "60"
  RETRY_MAX_ATTEMPTS: "5"
  RETRY_MODE: "adaptive"        # botocore client-side throttle backoff
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-gateway
  namespace: ai-platform
  labels:
    app.kubernetes.io/name: rag-gateway
    app.kubernetes.io/component: inference-gateway
spec:
  replicas: 3
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: rag-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rag-gateway
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: rag-gateway
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: rag-gateway
      containers:
        - name: gateway
          image: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/rag-gateway:1.4.2
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http,    containerPort: 8080 }
            - { name: metrics, containerPort: 9090 }
          envFrom:
            - configMapRef:
                name: rag-gateway-config
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2",  memory: 1Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ "ALL" ]
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            # Must verify STS assume-role + a Bedrock control-plane call, not
            # just that the process is listening. An IRSA misconfiguration is
            # otherwise invisible until the first user request fails.
            httpGet: { path: /readyz, port: http }
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 20
            failureThreshold: 3
      volumes:
        - name: tmp
          emptyDir: { sizeLimit: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: rag-gateway
  namespace: ai-platform
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: rag-gateway
  ports:
    - { name: http, port: 80, targetPort: http }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: rag-gateway
  namespace: ai-platform
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: rag-gateway
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rag-gateway
  namespace: ai-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rag-gateway
  minReplicas: 3
  maxReplicas: 20
  metrics:
    # Bedrock calls are I/O-bound: CPU is a poor signal. Scale on in-flight
    # requests per pod, exported by the gateway itself.
    - type: Pods
      pods:
        metric: { name: bedrock_inflight_requests }
        target:
          type: AverageValue
          averageValue: "8"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - { type: Percent, value: 25, periodSeconds: 60 }
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }
---
# Egress-only network policy: the gateway talks to AWS APIs and nothing else.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rag-gateway-egress
  namespace: ai-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: rag-gateway
  policyTypes: [ Egress ]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [ 169.254.169.254/32 ]
      ports:
        - { protocol: TCP, port: 443 }
---
# Optional Tier-1 path: self-hosted inference on AWS Inferentia, for the
# workloads where per-token Bedrock pricing loses to sustained utilisation.
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: neuron-inference
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-teach-plat
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: teach-plat }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: teach-plat }
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi        # Neuron-compiled artefacts are large
        volumeType: gp3
        throughput: 250
        deleteOnTermination: true
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required          # IMDSv2 only
    httpPutResponseHopLimit: 1
  tags:
    Project: teach-plat
    Workload: neuron-inference
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: neuron-inference
spec:
  template:
    metadata:
      labels:
        workload: neuron-inference
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: neuron-inference
      taints:
        - key: aws.amazon.com/neuron
          value: "true"
          effect: NoSchedule
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: [ "inf2" ]
        - key: karpenter.sh/capacity-type
          operator: In
          values: [ "on-demand" ]   # accelerator Spot reclaim is disruptive
        - key: kubernetes.io/arch
          operator: In
          values: [ "amd64" ]
      expireAfter: 720h
      terminationGracePeriod: 5m
  limits:
    cpu: "192"
    aws.amazon.com/neuron: "16"     # hard ceiling on accelerator spend
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 10m
    budgets:
      - nodes: "10%"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embedder-neuron
  namespace: ai-platform
spec:
  replicas: 2
  selector:
    matchLabels: { app.kubernetes.io/name: embedder-neuron }
  template:
    metadata:
      labels: { app.kubernetes.io/name: embedder-neuron }
    spec:
      nodeSelector:
        workload: neuron-inference
      tolerations:
        - key: aws.amazon.com/neuron
          operator: Exists
          effect: NoSchedule
      containers:
        - name: server
          image: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/embedder-neuron:0.9.1
          ports:
            - { name: http, containerPort: 8080 }
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
              aws.amazon.com/neuron: 1   # exposed by the Neuron device plugin
            limits:
              cpu: "8"
              memory: 24Gi
              aws.amazon.com/neuron: 1
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            initialDelaySeconds: 60      # Neuron model load is slow
            periodSeconds: 10
```

---

## 5. CLI: real commands and real output

Region assumed `eu-west-1`, account `123456789012`, AWS CLI v2.

### 5.1 Verify the ingest path end to end

```console
$ aws kinesis describe-stream-summary --stream-name teach-plat-events \
    --query 'StreamDescriptionSummary.{Mode:StreamModeDetails.StreamMode,Shards:OpenShardCount,Retention:RetentionPeriodHours,Status:StreamStatus,Enc:EncryptionType}'
{
    "Mode": "ON_DEMAND",
    "Shards": 4,
    "Retention": 24,
    "Status": "ACTIVE",
    "Enc": "KMS"
}

$ aws kinesis put-record \
    --stream-name teach-plat-events \
    --partition-key "tenant-7f3a" \
    --cli-binary-format raw-in-base64-out \
    --data '{"event_id":"e-0191c3","event_time":"2026-09-04T11:02:31Z","tenant_id":"tenant-7f3a","user_id":"u-4412","action":"lab.start","cert_id":"aws-clf","topic_id":"3.7","latency_ms":184,"status":"ok","attributes":{"region":"eu-west-1"}}'
{
    "ShardId": "shardId-000000000002",
    "SequenceNumber": "49661398472039485710294857102948571029485710294857102914",
    "EncryptionType": "KMS"
}
```

Confirm Firehose is consuming and where it writes:

```console
$ aws firehose describe-delivery-stream --delivery-stream-name teach-plat-events-to-lake \
    --query 'DeliveryStreamDescription.{Status:DeliveryStreamStatus,Type:DeliveryStreamType,Prefix:Destinations[0].ExtendedS3DestinationDescription.Prefix,Errors:Destinations[0].ExtendedS3DestinationDescription.ErrorOutputPrefix,DynPart:Destinations[0].ExtendedS3DestinationDescription.DynamicPartitioningConfiguration.Enabled}'
{
    "Status": "ACTIVE",
    "Type": "KinesisStreamAsSource",
    "Prefix": "curated/events/dt=!{partitionKeyFromQuery:dt}/tenant=!{partitionKeyFromQuery:tenant}/",
    "Errors": "quarantine/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/",
    "DynPart": true
}
```

Wait one buffering interval, then prove objects landed in the right partition:

```console
$ aws s3 ls s3://teach-plat-lake-123456789012-eu-west-1/curated/events/dt=2026-09-04/tenant=tenant-7f3a/ --human-readable
2026-09-04 11:04:12   14.8 MiB teach-plat-events-to-lake-3-2026-09-04-11-03-11-1f0c9a3e-...parquet
2026-09-04 11:05:14   15.2 MiB teach-plat-events-to-lake-3-2026-09-04-11-04-12-8b41d772-...parquet

$ aws s3 ls s3://teach-plat-lake-123456789012-eu-west-1/quarantine/ --recursive --summarize | tail -3

Total Objects: 0
   Total Size: 0
```

Zero quarantined objects is the pass condition. Anything there means records were rejected — §6.2.

### 5.2 Athena: prove partition pruning and measure the query's cost

```console
$ QID=$(aws athena start-query-execution \
    --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT action, count(*) AS n, approx_percentile(latency_ms, 0.95) AS p95 FROM events WHERE dt='2026-09-03' AND tenant='tenant-7f3a' GROUP BY action ORDER BY n DESC" \
    --query QueryExecutionId --output text)

$ aws athena get-query-execution --query-execution-id "$QID" \
    --query 'QueryExecution.{State:Status.State,ScannedBytes:Statistics.DataScannedInBytes,QueueMs:Statistics.QueryQueueTimeInMillis,EngineMs:Statistics.EngineExecutionTimeInMillis,TotalMs:Statistics.TotalExecutionTimeInMillis}'
{
    "State": "SUCCEEDED",
    "ScannedBytes": 44040192,
    "QueueMs": 118,
    "EngineMs": 1_642,
    "TotalMs": 1_940
}
```

44 040 192 B = 42 MiB ≈ **$0.0002** at $5/TB. Now the same query with the partition predicate removed:

```console
$ QID2=$(aws athena start-query-execution \
    --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT action, count(*) AS n FROM events GROUP BY action" \
    --query QueryExecutionId --output text)

$ aws athena get-query-execution --query-execution-id "$QID2" \
    --query 'QueryExecution.Status.{State:State,Reason:StateChangeReason}'
{
    "State": "FAILED",
    "Reason": "Query exhausted resources at this scale factor: bytes scanned limit exceeded. This query scanned more than the 107374182400 bytes allowed by workgroup teach-plat-analytics."
}
```

The workgroup ceiling did its job: an unbounded scan failed at $0.50 instead of succeeding at $60. **This is the single highest-leverage cost control in the analytics domain.**

Fetch results:

```console
$ aws athena get-query-results --query-execution-id "$QID" \
    --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
action  n       p95
lab.start       48210   184.0
topic.view      31877   62.0
lab.complete    27044   211.0
quiz.submit     19338   97.0
video.play      11205   143.0
```

### 5.3 Glue: catalog inspection and a crawler run

```console
$ aws glue get-table --database-name teach_plat_lakehouse --name events \
    --query 'Table.{Cols:StorageDescriptor.Columns[].Name,Parts:PartitionKeys[].Name,Loc:StorageDescriptor.Location,Projection:Parameters."projection.enabled"}'
{
    "Cols": ["event_id","event_time","tenant_id","user_id","action","cert_id","topic_id","latency_ms","status","attributes"],
    "Parts": ["dt","tenant"],
    "Loc": "s3://teach-plat-lake-123456789012-eu-west-1/curated/events/",
    "Projection": "true"
}

$ aws glue start-crawler --name teach-plat-events-crawler
$ aws glue get-crawler --name teach-plat-events-crawler \
    --query 'Crawler.{State:State,LastStatus:LastCrawl.Status,Msg:LastCrawl.ErrorMessage,LogGroup:LastCrawl.LogGroup}'
{
    "State": "READY",
    "LastStatus": "SUCCEEDED",
    "Msg": null,
    "LogGroup": "/aws-glue/crawlers"
}
```

With partition projection enabled you should not need the crawler at all for partition discovery — that is the point. Keep it for schema-drift detection, on a daily schedule, not hourly.

### 5.4 Bedrock: list, invoke, and see a guardrail fire

```console
$ aws bedrock list-foundation-models --by-provider anthropic \
    --by-inference-type ON_DEMAND \
    --query 'modelSummaries[].{Id:modelId,Name:modelName,In:inputModalities,Stream:responseStreamingSupported}' \
    --output table
---------------------------------------------------------------------------------------------
|                                    ListFoundationModels                                    |
+--------------------------------------------------+------------------+-----------+---------+
|                        Id                        |       Name       |    In     | Stream  |
+--------------------------------------------------+------------------+-----------+---------+
|  anthropic.claude-3-5-haiku-20241022-v1:0        |  Claude 3.5 Haiku|  TEXT     |  True   |
|  anthropic.claude-3-7-sonnet-20250219-v1:0       |  Claude 3.7 Sonnet| TEXT,IMAGE| True   |
|  anthropic.claude-sonnet-4-20250514-v1:0         |  Claude Sonnet 4 |TEXT,IMAGE |  True   |
+--------------------------------------------------+------------------+-----------+---------+

$ aws bedrock-runtime converse \
    --model-id eu.anthropic.claude-sonnet-4-20250514-v1:0 \
    --messages '[{"role":"user","content":[{"text":"In one sentence: when does Amazon Athena cost more than Amazon Redshift Serverless?"}]}]' \
    --inference-config '{"maxTokens":200,"temperature":0}' \
    --query '{Text:output.message.content[0].text,Stop:stopReason,In:usage.inputTokens,Out:usage.outputTokens,LatencyMs:metrics.latencyMs}'
{
    "Text": "Athena costs more once the same data is scanned repeatedly at high concurrency, because you pay per terabyte scanned on every query while Redshift Serverless amortises a provisioned RPU-hour across many queries.",
    "Stop": "end_turn",
    "In": 27,
    "Out": 41,
    "LatencyMs": 1183
}
```

At the Sonnet-class list price, 27 in + 41 out ≈ **$0.0007**. Now with the guardrail attached, sending something the PII policy must catch:

```console
$ aws bedrock-runtime converse \
    --model-id eu.anthropic.claude-sonnet-4-20250514-v1:0 \
    --guardrail-config '{"guardrailIdentifier":"gr-9k2mfp0qra41","guardrailVersion":"1","trace":"enabled"}' \
    --messages '[{"role":"user","content":[{"guardContent":{"text":{"text":"Summarise this ticket: user villadalmine@example.com on TP-004417 reports lab timeouts."}}}]}]' \
    --query '{Stop:stopReason,Text:output.message.content[0].text,Pii:trace.guardrail.inputAssessment.*.sensitiveInformationPolicy.piiEntities[].{T:type,A:action}}'
{
    "Stop": "end_turn",
    "Text": "The ticket reports that a user ({EMAIL}) experienced lab environment timeouts on ticket {internal-ticket-id}.",
    "Pii": [
        { "T": "EMAIL", "A": "ANONYMIZED" }
    ]
}
```

The email never reached the model. Note `guardContent` — only text wrapped in it is evaluated, which lets you exempt system instructions from the filter.

Query the Knowledge Base with citations:

```console
$ aws bedrock-agent-runtime retrieve-and-generate \
    --input '{"text":"Which AWS service converts speech to text in real time?"}' \
    --retrieve-and-generate-configuration '{
        "type":"KNOWLEDGE_BASE",
        "knowledgeBaseConfiguration":{
            "knowledgeBaseId":"KBQ7X3P1AZ",
            "modelArn":"arn:aws:bedrock:eu-west-1:123456789012:inference-profile/eu.anthropic.claude-sonnet-4-20250514-v1:0",
            "retrievalConfiguration":{"vectorSearchConfiguration":{"numberOfResults":5}}
        }}' \
    --query '{Answer:output.text,Sources:citations[].retrievedReferences[].location.s3Location.uri}'
{
    "Answer": "Amazon Transcribe performs automatic speech recognition and supports streaming transcription for real-time audio.",
    "Sources": [
        "s3://teach-plat-kb-corpus-123456789012-eu-west-1/certs/aws-clf/3.7/en/content.md",
        "s3://teach-plat-kb-corpus-123456789012-eu-west-1/certs/aws-clf/3.7/en/exercises.md"
    ]
}
```

### 5.5 The Tier-3 AI services in one pass

```console
$ aws comprehend detect-sentiment --language-code en \
    --text "The lab environment kept timing out, but support fixed it within ten minutes."
{
    "Sentiment": "MIXED",
    "SentimentScore": {
        "Positive": 0.28415,
        "Negative": 0.11037,
        "Neutral": 0.05762,
        "Mixed": 0.54786
    }
}

$ aws comprehend detect-pii-entities --language-code en \
    --text "Contact a.rivas@example.org or +34 600 123 456 about invoice INV-88213." \
    --query 'Entities[].{Type:Type,Score:Score,Begin:BeginOffset,End:EndOffset}'
[
    { "Type": "EMAIL",  "Score": 0.99938, "Begin": 8,  "End": 27 },
    { "Type": "PHONE",  "Score": 0.99127, "Begin": 31, "End": 46 }
]

$ aws rekognition detect-labels \
    --image '{"S3Object":{"Bucket":"teach-plat-media","Name":"lab-rack-01.jpg"}}' \
    --max-labels 5 --min-confidence 80 \
    --query 'Labels[].{Name:Name,Conf:Confidence}' --output table
------------------------------
|        DetectLabels        |
+------------------+---------+
|       Name       |  Conf   |
+------------------+---------+
|  Computer Hardware| 99.42  |
|  Server           | 97.83  |
|  Electronics      | 96.15  |
|  Cable            | 91.07  |
|  Data Center      | 88.64  |
+------------------+---------+

$ aws textract analyze-document \
    --document '{"S3Object":{"Bucket":"teach-plat-media","Name":"invoice-2026-08.png"}}' \
    --feature-types '["FORMS","TABLES"]' \
    --query 'length(Blocks[?BlockType==`KEY_VALUE_SET`])'
34

$ aws polly synthesize-speech --engine neural --voice-id Ruth --language-code en-US \
    --output-format mp3 \
    --text "Amazon Athena charges per terabyte of data scanned." \
    /tmp/narration.mp3
{
    "ContentType": "audio/mpeg",
    "RequestCharacters": "51"
}

$ aws translate translate-text --source-language-code en --target-language-code es \
    --text "Separation of storage and compute is the defining property of a data lake." \
    --query 'TranslatedText' --output text
La separación del almacenamiento y el cómputo es la propiedad que define un lago de datos.

$ aws transcribe start-transcription-job \
    --transcription-job-name lab-walkthrough-2026-09-04 \
    --language-code en-US \
    --media '{"MediaFileUri":"s3://teach-plat-media/audio/lab-walkthrough.mp4"}' \
    --output-bucket-name teach-plat-media \
    --settings '{"ShowSpeakerLabels":true,"MaxSpeakerLabels":3}' \
    --query 'TranscriptionJob.{Name:TranscriptionJobName,Status:TranscriptionJobStatus}'
{
    "Name": "lab-walkthrough-2026-09-04",
    "Status": "IN_PROGRESS"
}
```

### 5.6 Redshift Serverless via the Data API (no drivers, no VPC path, IAM-authenticated)

```console
$ aws redshift-serverless get-workgroup --workgroup-name teach-plat-wg \
    --query 'workgroup.{Status:status,BaseRPU:baseCapacity,MaxRPU:maxCapacity,Public:publiclyAccessible,Endpoint:endpoint.address}'
{
    "Status": "AVAILABLE",
    "BaseRPU": 8,
    "MaxRPU": 64,
    "Public": false,
    "Endpoint": "teach-plat-wg.123456789012.eu-west-1.redshift-serverless.amazonaws.com"
}

$ SID=$(aws redshift-data execute-statement \
    --workgroup-name teach-plat-wg --database analytics \
    --sql "SELECT cert_id, count(DISTINCT user_id) AS learners FROM lakehouse.events WHERE dt >= '2026-08-01' GROUP BY cert_id ORDER BY learners DESC LIMIT 5" \
    --query Id --output text)

$ aws redshift-data describe-statement --id "$SID" \
    --query '{Status:Status,DurationNs:Duration,Rows:ResultRows,Bytes:ResultSize}'
{
    "Status": "FINISHED",
    "DurationNs": 412874193,
    "Rows": 5,
    "Bytes": 187
}
```

`Duration` is **nanoseconds** — 412 874 193 ns = 0.41 s. Misreading it as milliseconds is a common false alarm in dashboards.

### 5.7 Lake Formation: prove the column grant is real

```console
$ aws lakeformation list-permissions \
    --resource '{"Table":{"CatalogId":"123456789012","DatabaseName":"teach_plat_lakehouse","Name":"events"}}' \
    --query 'PrincipalResourcePermissions[].{Principal:Principal.DataLakePrincipalIdentifier,Perms:Permissions,Cols:Resource.TableWithColumns.ColumnNames}'
[
    {
        "Principal": "arn:aws:iam::123456789012:role/analytics-readonly",
        "Perms": ["SELECT"],
        "Cols": ["dt","tenant","action","latency_ms","status"]
    }
]
```

`user_id` is absent from the grant. A query selecting it under that role fails at the engine, not at S3:

```console
$ aws athena start-query-execution --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT user_id FROM events WHERE dt='2026-09-03' LIMIT 1" \
    --query QueryExecutionId --output text
b7c1a930-4f2e-4a11-9c88-0d61f3ae2210

$ aws athena get-query-execution --query-execution-id b7c1a930-4f2e-4a11-9c88-0d61f3ae2210 \
    --query 'QueryExecution.Status.StateChangeReason' --output text
COLUMN_NOT_FOUND: line 1:8: Column 'user_id' cannot be resolved
```

Lake Formation removes the column from the schema the principal sees rather than returning "access denied" — this surprises people and is exactly the intended behaviour.

### 5.8 SageMaker AI endpoint health

```console
$ aws sagemaker describe-endpoint --endpoint-name churn-rt \
    --query '{Status:EndpointStatus,Reason:FailureReason,Variants:ProductionVariants[].{V:VariantName,Instances:CurrentInstanceCount,Desired:DesiredInstanceCount,Weight:CurrentWeight}}'
{
    "Status": "InService",
    "Reason": null,
    "Variants": [
        { "V": "blue",  "Instances": 2, "Desired": 2, "Weight": 0.9 },
        { "V": "green", "Instances": 1, "Desired": 1, "Weight": 0.1 }
    ]
}

$ aws cloudwatch get-metric-statistics --namespace AWS/SageMaker \
    --metric-name ModelLatency \
    --dimensions Name=EndpointName,Value=churn-rt Name=VariantName,Value=blue \
    --start-time 2026-09-04T10:00:00Z --end-time 2026-09-04T11:00:00Z \
    --period 300 --statistics Average p99 \
    --query 'sort_by(Datapoints,&Timestamp)[-3:].{T:Timestamp,Avg:Average,P99:p99,U:Unit}' --output table
-------------------------------------------------------------------
|                      GetMetricStatistics                        |
+--------------------------+---------+---------+------------------+
|            T             |   Avg   |   P99   |        U         |
+--------------------------+---------+---------+------------------+
|  2026-09-04T10:50:00Z    |  8412.0 | 21903.0 |  Microseconds    |
|  2026-09-04T10:55:00Z    |  8177.0 | 20488.0 |  Microseconds    |
|  2026-09-04T11:00:00Z    |  9310.0 | 34771.0 |  Microseconds    |
+--------------------------+---------+---------+------------------+
```

`ModelLatency` is in **microseconds** and measures only the container. `OverheadLatency` is the SageMaker-side add-on. If client-observed latency exceeds `ModelLatency + OverheadLatency`, the problem is on your side of the endpoint — network, serialization, or a client without connection reuse.

---

## 6. Verification and failure diagnosis

### 6.1 The metrics that matter, per service

| Service | Golden signal | Namespace / metric | What a breach means |
|---|---|---|---|
| Kinesis Data Streams | Consumer lag | `AWS/Kinesis` · `GetRecords.IteratorAgeMilliseconds` | Consumers slower than producers; **data loss** once age > retention |
| Kinesis Data Streams | Write throttling | `WriteProvisionedThroughputExceeded` | Hot partition key or too few shards |
| Kinesis Data Streams | Read throttling | `ReadProvisionedThroughputExceeded` | Too many standard consumers sharing 2 MB/s; use Enhanced Fan-Out |
| Data Firehose | Delivery freshness | `AWS/Firehose` · `DeliveryToS3.DataFreshness` | Destination unreachable, IAM denial, or schema conversion failing |
| Data Firehose | Conversion errors | `FailedConversion.Records` | Payload does not match the Glue schema |
| Data Firehose | Source throttling | `ThrottledRecords` | Firehose quota exceeded (5 000 rec/s or 5 MiB/s per stream, region-dependent) |
| Athena | Cost | `AWS/Athena` · `ProcessedBytes` | Partition pruning is not happening |
| Athena | Contention | `QueryQueueTime` | Concurrency quota reached; move dashboards to Redshift |
| Glue | Memory pressure | `glue.ALL.jvm.heap.usage` > 0.9 | Skewed join or too few DPUs; expect OOM |
| Glue | Disk spill | `glue.driver.BlockManager.disk.diskSpaceUsed_MB` rising | Shuffle exceeding memory |
| Redshift Serverless | Capacity | `AWS/Redshift-Serverless` · `ComputeCapacity` at `MaxRPU` | Raise the cap or fix the query |
| OpenSearch | Cluster health | `AWS/ES` · `ClusterStatus.red`, `JVMMemoryPressure` > 80 % | Unassigned shards / GC death spiral |
| Bedrock | Throttles | `AWS/Bedrock` · `InvocationThrottles` | Account TPM/RPM quota; use inference profiles or request an increase |
| Bedrock | Cost | `InputTokenCount` + `OutputTokenCount` | Prompt bloat; enable prompt caching |
| SageMaker endpoint | Latency split | `AWS/SageMaker` · `ModelLatency`, `OverheadLatency` | Container vs platform attribution |
| SageMaker endpoint | Saturation | `InvocationsPerInstance`, `CPUUtilization` | Auto-scaling target missing |

### 6.2 Runbook — symptom → cause → command

**Athena / lakehouse**

| Symptom | Root cause | Diagnosis and fix |
|---|---|---|
| `HIVE_PARTITION_SCHEMA_MISMATCH: ... declared as type 'bigint', but partition ... as type 'string'` | A crawler re-inferred a column type after upstream drift | `aws glue get-partition --database-name … --partition-values …` and compare `StorageDescriptor.Columns` to the table's. Fix upstream, then drop and re-add the partition. Long term: declare the schema explicitly (as in §4.1) and stop letting a crawler own it |
| `HIVE_CURSOR_ERROR: Not valid Parquet file` | JSON quarantine or `_temporary` files under the table's S3 location | `aws s3 ls s3://…/curated/events/ --recursive \| grep -v '\.parquet$'`. Move `ErrorOutputPrefix` outside the table prefix |
| `Insufficient permissions to execute the query. Amazon S3 access denied on s3://…` | Athena's caller lacks `s3:GetObject`, or lacks `kms:Decrypt` on the bucket CMK | Decrypt is the usual one. `aws kms describe-key --key-id alias/teach-plat-lake` and check the key policy, not just the IAM policy |
| Query returns **0 rows** but data is in S3 | Partitions not registered, or projection template does not match the real prefix | `SELECT DISTINCT dt FROM events LIMIT 5`, then `aws s3 ls s3://…/curated/events/`. The template's key **names and order** must match `PartitionKeys` exactly |
| `COLUMN_NOT_FOUND` for a column that exists | Lake Formation column-level grant excludes it | `aws lakeformation list-permissions --resource '{"Table":…}'` (§5.7) |
| Cost spike with no traffic change | Someone removed the partition predicate, or many small files | `aws athena list-query-executions` + `batch-get-query-execution`, sort by `DataScannedInBytes`. Also check object count: thousands of 200 KB Parquet files cost more in request overhead than they save |

**Kinesis / Firehose**

| Symptom | Root cause | Diagnosis and fix |
|---|---|---|
| `ProvisionedThroughputExceededException: Rate exceeded for shard shardId-000000000001` | Hot partition key — one tenant dominates | Check per-shard `IncomingBytes` (dimension `ShardId`). Fix the key: `tenant_id#<random 0..N>` or switch to `ON_DEMAND` |
| `DataFreshness` climbing, no objects in S3 | Firehose role denied on S3 or KMS | `aws logs tail /aws/kinesisfirehose/teach-plat --since 30m --format short` — the log line names the exact denied action |
| Records land under `quarantine/format-conversion-failed/` | Payload does not match the Glue schema | Read a quarantined object: it contains `rawData` (base64) plus the error. Common causes: `latency_ms` sent as a string, or a new field that the Glue table lacks (`OpenXJsonSerDe` tolerates extras only if `CaseInsensitive`/mapping allow) |
| Records land under `quarantine/processing-failed/` | The jq `MetadataExtractionQuery` returned null for a partition key | Every record must produce **every** dynamic partition key. Add a fallback: `{dt:(.event_time[0:10] // "unknown"),tenant:(.tenant_id // "unknown")}` |
| Firehose delivers, but objects are tiny and numerous | `BufferingHints` too aggressive | Raise `SizeInMBs` toward 128 and `IntervalInSeconds` to 300 if the freshness SLO allows. Object count drives Athena request cost and Glue job time |
| `DeliveryStream` cannot be updated to add dynamic partitioning | It is create-time only | Create a new delivery stream and cut over. Verify with `describe-delivery-stream` before deleting the old one |
| Consumer `IteratorAge` grows monotonically | Consumer throughput below producer rate | Scale consumers to ≤ shard count (one consumer per shard for standard consumers), or adopt Enhanced Fan-Out. Watch retention: at 24 h, an age of 20 h means you are 4 h from permanent loss |

**Bedrock**

| Error / symptom | Cause | Fix |
|---|---|---|
| `AccessDeniedException: You don't have access to the model with the specified model ID.` | Model access not enabled for the account/region | Bedrock console → *Model access* → request access. This is an account-level, per-region toggle, not IAM |
| `ValidationException: Invocation of model ID anthropic.claude-sonnet-4-… with on-demand throughput isn't supported. Retry your request with the ID or ARN of an inference profile that contains this model.` | Newer models are only reachable through inference profiles | Prefix the ID with the geography: `eu.anthropic.claude-sonnet-4-…`. `aws bedrock list-inference-profiles --query 'inferenceProfileSummaries[].inferenceProfileId'` |
| `ThrottlingException: Too many requests, please wait before trying again.` | Account TPM/RPM quota | `retry_mode = adaptive` in the client, cross-region inference profile, or Service Quotas increase. Provisioned Throughput if the load is sustained |
| `ResourceNotFoundException` on `retrieve-and-generate` | Data source never ingested, or the vector index does not exist | `aws bedrock-agent list-ingestion-jobs --knowledge-base-id … --data-source-id …`; a KB with zero completed ingestion jobs returns nothing forever |
| KB creation fails: *"The knowledge base storage configuration provided is invalid… no such index"* | CloudFormation does **not** create the OpenSearch Serverless vector index | Create the index first (`PUT /bedrock-kb-index` with a `knn_vector` field of the embedding model's dimension — 1024 for `titan-embed-text-v2`), then create the KB. This is the #1 stack-rollback in §4.2 |
| Answers are confidently wrong | No contextual grounding filter | Set `ContextualGroundingPolicyConfig` (§4.2) and inspect `trace.guardrail.outputAssessments[].contextualGroundingPolicy` |
| `stopReason: "max_tokens"`, truncated answers | `maxTokens` too low | Raise it — but note it is also your cost ceiling; truncation is sometimes the correct trade |

**SageMaker AI**

| Symptom | Cause | Fix |
|---|---|---|
| Endpoint stuck `Creating` → `Failed`, `FailureReason: "...did not pass the ping health check"` | Container not answering `GET /ping` with 200 within the startup window | `aws logs tail /aws/sagemaker/Endpoints/<name> --since 20m`. Usually a model artefact path or missing dependency |
| `ModelError: Received server error (503)` at invoke time | Container OOM or single-threaded worker saturated | Raise `InvocationsPerInstance` target on auto-scaling, or move to a larger instance. Check `MemoryUtilization` |
| Endpoint costs money with no traffic | Real-time endpoints bill per instance-hour regardless | Switch to **Serverless Inference** (scales to zero, cold-start acceptable) or **Asynchronous Inference** (queue-backed, scales to zero, large payloads) |
| Training job `ResourceLimitExceeded` | Per-instance-type service quota is 0 by default for GPU types | `aws service-quotas list-service-quotas --service-code sagemaker --query "Quotas[?contains(QuotaName,'ml.g6')]"` and request an increase |

### 6.3 A verification checklist you can run before declaring the pipeline healthy

```console
# 1. Producer path accepts writes
$ aws kinesis put-record --stream-name teach-plat-events --partition-key smoke \
    --cli-binary-format raw-in-base64-out \
    --data '{"event_id":"smoke","event_time":"2026-09-04T11:30:00Z","tenant_id":"smoke","action":"healthcheck","latency_ms":1,"status":"ok"}' >/dev/null && echo OK
OK

# 2. Nothing is being quarantined
$ test "$(aws s3 ls s3://teach-plat-lake-123456789012-eu-west-1/quarantine/ --recursive | wc -l)" -eq 0 && echo "no rejects"
no rejects

# 3. Delivery is fresh (seconds of undelivered backlog)
$ aws cloudwatch get-metric-statistics --namespace AWS/Firehose \
    --metric-name DeliveryToS3.DataFreshness \
    --dimensions Name=DeliveryStreamName,Value=teach-plat-events-to-lake \
    --start-time "$(date -u -d '15 min ago' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
    --period 300 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum'
73.0

# 4. The catalog resolves and the query engine can read the data
$ aws athena start-query-execution --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT count(*) FROM events WHERE dt = date_format(current_date, '%Y-%m-%d')" \
    --query QueryExecutionId --output text
9f2a44e1-5b03-4c8d-a1e0-77c2b6f4e5aa

# 5. Cost guardrail is actually enforced (not just configured)
$ aws athena get-work-group --work-group teach-plat-analytics \
    --query 'WorkGroup.Configuration.{Cap:BytesScannedCutoffPerQuery,Enforced:EnforceWorkGroupConfiguration}'
{
    "Cap": 107374182400,
    "Enforced": true
}

# 6. The model path is reachable with the identity the app actually uses
$ kubectl -n ai-platform exec deploy/rag-gateway -- \
    aws sts get-caller-identity --query Arn --output text
arn:aws:sts::123456789012:assumed-role/eks-ai-platform-rag-gateway/botocore-session-1757000000
```

Step 6 is the one people skip. `aws bedrock-runtime converse` working from your laptop proves nothing about whether the pod's IRSA role can do it.

---

## 7. Exam-focused decision cheat sheet

Map the requirement phrase to the service. These are the discriminators CLF-C02 actually uses.

| If the question says… | Answer |
|---|---|
| "run SQL directly on data in S3, no infrastructure" | **Amazon Athena** |
| "petabyte-scale data warehouse for BI" | **Amazon Redshift** |
| "managed Hadoop/Spark/Hive clusters" | **Amazon EMR** |
| "serverless ETL and a data catalog" | **AWS Glue** |
| "prepare data visually without writing code" | **AWS Glue DataBrew** |
| "business intelligence dashboards, ML-powered insights" | **Amazon QuickSight** |
| "search and analyse log data, operational analytics" | **Amazon OpenSearch Service** |
| "load streaming data into S3/Redshift/OpenSearch with no code" | **Amazon Data Firehose** |
| "multiple consumers, ordered records, replay" | **Amazon Kinesis Data Streams** |
| "real-time processing/aggregation of a stream" | **Amazon Managed Service for Apache Flink** |
| "fully managed Apache Kafka" | **Amazon MSK** |
| "centrally govern and secure a data lake, column-level access" | **AWS Lake Formation** |
| "find and subscribe to third-party datasets" | **AWS Data Exchange** |
| "analyse combined data with a partner without sharing raw data" | **AWS Clean Rooms** |
| "build, train and deploy ML models" | **Amazon SageMaker AI** |
| "access foundation models via API, build generative AI apps" | **Amazon Bedrock** |
| "generative AI assistant for developers / for the enterprise" | **Amazon Q Developer / Amazon Q Business** |
| "extract text and data from scanned documents" | **Amazon Textract** |
| "analyse images and video, content moderation" | **Amazon Rekognition** |
| "convert speech to text" | **Amazon Transcribe** |
| "convert text to lifelike speech" | **Amazon Polly** |
| "translate text between languages" | **Amazon Translate** |
| "find insights, sentiment, entities and PII in text" | **Amazon Comprehend** |
| "build a chatbot / voice interface" | **Amazon Lex** |
| "intelligent enterprise search across repositories" | **Amazon Kendra** |
| "real-time product recommendations" | **Amazon Personalize** |
| "detect online fraud without ML expertise" | **Amazon Fraud Detector** |
| "human review of low-confidence ML predictions" | **Amazon Augmented AI (A2I)** |
| "purpose-built chip to train models at lower cost" | **AWS Trainium** |
| "purpose-built chip for low-cost inference" | **AWS Inferentia** |

**Three distinctions worth memorising because they are deliberately confusable:**

1. **Kendra vs Q Business.** Kendra *returns documents* (search); Q Business *generates an answer* (assistant) — and Q Business can use Kendra as its retriever.
2. **Comprehend vs Bedrock.** Comprehend is a fixed-purpose NLP API (sentiment, entities, PII) with no prompt; Bedrock is a general foundation model you instruct. If the requirement names a specific NLP task, Comprehend is the cheaper, more deterministic answer.
3. **Data Firehose vs Data Streams.** Firehose = delivery, buffered, one destination, no replay. Streams = a durable log, many consumers, replay. If the scenario needs *reprocessing*, it is Streams.

---

## 8. Referencias

**Exam guide (authoritative scope for this task statement)**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Certification page and sample questions — https://aws.amazon.com/certification/certified-cloud-practitioner/

**AI/ML**
- Amazon Bedrock User Guide — https://docs.aws.amazon.com/bedrock/latest/userguide/
- Bedrock Guardrails — https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html
- Bedrock Knowledge Bases — https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html
- Bedrock cross-region inference — https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html
- Bedrock data protection / privacy — https://docs.aws.amazon.com/bedrock/latest/userguide/data-protection.html
- Amazon SageMaker AI Developer Guide — https://docs.aws.amazon.com/sagemaker/latest/dg/
- SageMaker Serverless Inference — https://docs.aws.amazon.com/sagemaker/latest/dg/serverless-endpoints.html
- SageMaker Asynchronous Inference — https://docs.aws.amazon.com/sagemaker/latest/dg/async-inference.html
- Amazon Q Developer — https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/
- Amazon Q Business — https://docs.aws.amazon.com/amazonq/latest/qbusiness-ug/
- Amazon Comprehend — https://docs.aws.amazon.com/comprehend/latest/dg/
- Amazon Textract — https://docs.aws.amazon.com/textract/latest/dg/
- Amazon Rekognition — https://docs.aws.amazon.com/rekognition/latest/dg/
- Amazon Transcribe — https://docs.aws.amazon.com/transcribe/latest/dg/
- Amazon Polly — https://docs.aws.amazon.com/polly/latest/dg/
- Amazon Translate — https://docs.aws.amazon.com/translate/latest/dg/
- Amazon Lex V2 — https://docs.aws.amazon.com/lexv2/latest/dg/
- Amazon Kendra — https://docs.aws.amazon.com/kendra/latest/dg/
- Amazon Personalize — https://docs.aws.amazon.com/personalize/latest/dg/
- Amazon Fraud Detector — https://docs.aws.amazon.com/frauddetector/latest/ug/
- Amazon Augmented AI (A2I) — https://docs.aws.amazon.com/sagemaker/latest/dg/a2i-use-augmented-ai-a2i-human-review-loops.html
- AWS Trainium — https://aws.amazon.com/ai/machine-learning/trainium/
- AWS Inferentia — https://aws.amazon.com/ai/machine-learning/inferentia/
- AWS Neuron SDK documentation — https://awsdocs-neuron.readthedocs-hosted.com/

**Analytics**
- Amazon Athena User Guide — https://docs.aws.amazon.com/athena/latest/ug/
- Athena partition projection — https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html
- Athena workgroups and data-usage controls — https://docs.aws.amazon.com/athena/latest/ug/workgroups-setting-control-limits-cloudwatch.html
- Athena troubleshooting — https://docs.aws.amazon.com/athena/latest/ug/troubleshooting-athena.html
- Amazon Redshift Management Guide — https://docs.aws.amazon.com/redshift/latest/mgmt/
- Redshift Serverless — https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-whatis.html
- Redshift Data API — https://docs.aws.amazon.com/redshift/latest/mgmt/data-api.html
- Amazon EMR — https://docs.aws.amazon.com/emr/latest/ManagementGuide/
- EMR Serverless — https://docs.aws.amazon.com/emr/latest/EMR-Serverless-UserGuide/
- AWS Glue Developer Guide — https://docs.aws.amazon.com/glue/latest/dg/
- AWS Glue DataBrew — https://docs.aws.amazon.com/databrew/latest/dg/
- Amazon Kinesis Data Streams — https://docs.aws.amazon.com/streams/latest/dev/
- Kinesis Data Streams CloudWatch monitoring — https://docs.aws.amazon.com/streams/latest/dev/monitoring-with-cloudwatch.html
- Amazon Data Firehose — https://docs.aws.amazon.com/firehose/latest/dev/
- Firehose dynamic partitioning — https://docs.aws.amazon.com/firehose/latest/dev/dynamic-partitioning.html
- Firehose record format conversion — https://docs.aws.amazon.com/firehose/latest/dev/record-format-conversion.html
- Amazon Managed Service for Apache Flink — https://docs.aws.amazon.com/managed-flink/latest/java/
- Amazon MSK — https://docs.aws.amazon.com/msk/latest/developerguide/
- Amazon OpenSearch Service — https://docs.aws.amazon.com/opensearch-service/latest/developerguide/
- OpenSearch Serverless vector search — https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-vector-search.html
- Amazon QuickSight — https://docs.aws.amazon.com/quicksight/latest/user/
- AWS Lake Formation — https://docs.aws.amazon.com/lake-formation/latest/dg/
- Amazon DataZone — https://docs.aws.amazon.com/datazone/latest/userguide/
- AWS Data Exchange — https://docs.aws.amazon.com/data-exchange/latest/userguide/
- AWS Clean Rooms — https://docs.aws.amazon.com/clean-rooms/latest/userguide/

**Infrastructure as code and Kubernetes**
- `AWS::KinesisFirehose::DeliveryStream` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-kinesisfirehose-deliverystream.html
- `AWS::Glue::Table` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-glue-table.html
- `AWS::Athena::WorkGroup` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-athena-workgroup.html
- `AWS::Bedrock::KnowledgeBase` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-bedrock-knowledgebase.html
- `AWS::Bedrock::Guardrail` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-bedrock-guardrail.html
- IAM roles for service accounts (IRSA) on EKS — https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- EKS Pod Identity — https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- Karpenter documentation — https://karpenter.sh/docs/
- AWS Neuron device plugin for Kubernetes — https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/

**Pricing (verify before quoting — figures in this unit are `us-east-1` list prices used for calibration)**
- Athena — https://aws.amazon.com/athena/pricing/
- Redshift — https://aws.amazon.com/redshift/pricing/
- Glue — https://aws.amazon.com/glue/pricing/
- Kinesis Data Streams — https://aws.amazon.com/kinesis/data-streams/pricing/
- Amazon Data Firehose — https://aws.amazon.com/firehose/pricing/
- OpenSearch Service — https://aws.amazon.com/opensearch-service/pricing/
- QuickSight — https://aws.amazon.com/quicksight/pricing/
- Bedrock — https://aws.amazon.com/bedrock/pricing/
- SageMaker — https://aws.amazon.com/sagemaker/pricing/
- Kendra — https://aws.amazon.com/kendra/pricing/