# 3.1 — Describe fundamental AI and ML concepts and how they create business value

**Certification:** Google Cloud Digital Leader (CDL) · Exam guide version 2026-08-12
**Domain weight:** 9.0 %
**Profile:** Principal Platform Architect / Senior SRE

---

## 0. How this objective is actually examined

The CDL blueprint phrases this objective in business language, but every question is really testing whether you can place a workload on the correct rung of Google's AI solution ladder and justify it with a cost, latency, data-gravity or governance argument. The three recurring question shapes are:

1. **Placement** — "A retailer wants X with no ML expertise in-house" → pick the highest-abstraction service that satisfies the constraint.
2. **Data readiness** — "The model performs poorly in production" → the answer is almost always about data quality, labeling, drift or skew, never about the algorithm.
3. **Value articulation** — "Which metric demonstrates business value?" → distinguish *model metrics* (AUC, RMSE, perplexity) from *business KPIs* (churn rate, cost per resolved ticket, gross margin).

Everything below is the production substrate underneath those three shapes. As an SRE you will be paged for the failure modes in §12 long before anyone asks you about AUC.

---

## 1. Motivation: the production architecture problem

### 1.1 The model is the smallest part of the system

Google's own research (Sculley et al., *Hidden Technical Debt in Machine Learning Systems*, NeurIPS 2015) established the canonical diagram: the box labelled "ML Code" is a tiny fraction of a real ML system. The surrounding boxes — configuration, data collection, feature extraction, data verification, machine resource management, analysis tools, process management tools, serving infrastructure, monitoring — are the platform engineer's problem.

This is why Google Cloud does not sell "a model". It sells **Vertex AI**, a platform whose components map one-to-one onto those boxes:

| Technical-debt box (2015 paper) | Google Cloud component |
|---|---|
| Data collection | Cloud Storage, BigQuery, Pub/Sub, Datastream |
| Data verification | Dataplex Universal Catalog, Dataform, BigQuery data quality scans |
| Feature extraction | Dataflow, BigQuery, Vertex AI Feature Store |
| ML code | Vertex AI Training, BigQuery ML, Model Garden |
| Configuration | Vertex AI Pipelines parameters, Artifact Registry, Cloud Build |
| Machine resource management | Vertex AI custom jobs, GKE, TPU/GPU node pools |
| Analysis tools | Vertex AI Experiments, TensorBoard, Vertex AI Model Evaluation |
| Process management | Vertex AI Pipelines (Kubeflow / TFX) |
| Serving infrastructure | Vertex AI Endpoints, GKE + KServe, Cloud Run |
| Monitoring | Vertex AI Model Monitoring, Cloud Monitoring, Cloud Logging |

### 1.2 CACE: Changing Anything Changes Everything

ML systems erode the module boundaries that classical software engineering depends on. A model consumes features; features come from upstream tables; tables come from upstream services. There is no interface contract that says "column `user_tenure_days` will remain in days". The moment an upstream team changes that column to months, your model silently degrades — **no exception is thrown, no HTTP 500 is emitted, no SLO burns**. Accuracy drops, revenue drops, and the first signal is a business dashboard three weeks later.

This is the defining operational difference between an ML service and a stateless microservice:

| Property | Stateless microservice | ML inference service |
|---|---|---|
| Failure signal | Exception, non-2xx, latency spike | Statistical distribution shift — silent |
| Correctness definition | Deterministic, testable | Probabilistic, only measurable against ground truth |
| Ground truth availability | Immediate | Delayed hours→months (label lag) |
| Rollback unit | Container image | Image **+** model artifact **+** feature definitions **+** preprocessing code |
| Reproducibility requirement | Same code → same output | Same code + same data + same seed + same library versions |
| Dominant cost | vCPU-seconds | Accelerator-hours (training) + tokens/QPS (serving) |
| Blast radius of a bad deploy | Errors, visible | Wrong-but-plausible answers, invisible |

The last row is why *Responsible AI* (§9) is an engineering control, not a compliance slide.

### 1.3 The two-loop architecture

Every production ML system is two loops running at different frequencies. Designing them separately is the single most important architectural decision.

```
                      ┌──────────────────── OUTER LOOP (training) ─────────────────────┐
                      │  hours → weeks                                                 │
  ┌──────────┐   ┌────▼─────┐   ┌───────────┐   ┌──────────┐   ┌──────────┐   ┌────────┴───┐
  │ Sources  │──▶│ Ingest   │──▶│ Feature   │──▶│ Train    │──▶│ Evaluate │──▶│ Model      │
  │ OLTP/IoT │   │ Pub/Sub  │   │ engineer  │   │ Vertex   │   │ + fairness│  │ Registry   │
  │ logs/SaaS│   │ Datastream│  │ Dataflow  │   │ AI       │   │ gates     │  │ (versioned)│
  └──────────┘   └────┬─────┘   └─────┬─────┘   └──────────┘   └──────────┘   └────────┬───┘
                      │               │                                                │
                      ▼               ▼                                                ▼
                 ┌─────────┐    ┌──────────────┐                               ┌──────────────┐
                 │ BigQuery│◀──▶│ Feature Store│──────────────────────────────▶│  Endpoint    │
                 │ / GCS   │    │ (offline+    │       low-latency reads        │  (online)    │
                 └─────────┘    │  online)     │                               └──────┬───────┘
                      ▲         └──────────────┘                                      │
                      │                                                                │
                      │         ┌──────────────── INNER LOOP (serving) ────────────────┤
                      │         │  milliseconds                                        │
                      │    ┌────▼────┐    ┌──────────┐    ┌───────────┐    ┌───────────▼──┐
                      └────┤ Ground  │◀───┤ Business │◀───┤  Client   │───▶│  Prediction  │
                    labels │ truth   │    │ outcome  │    │  app      │    │  + logging   │
                           └─────────┘    └──────────┘    └───────────┘    └──────────────┘
                                 │                                                  │
                                 └────────────── Model Monitoring ◀─────────────────┘
                                        skew / drift / attribution alerts
```

The **Feature Store** sits at the intersection deliberately: it is the only component that serves the *same* feature values to both loops, which is the structural cure for training-serving skew (§3.5).

---

## 2. Taxonomy: the concepts, precisely

### 2.1 Containment hierarchy

```
Artificial Intelligence  ── any technique making machines exhibit goal-directed behaviour
 └── Machine Learning    ── systems that infer rules from data instead of being programmed with them
      └── Deep Learning  ── ML using multi-layer neural networks; learns its own features
           └── Generative AI ── deep models that produce new content (text, image, audio, code)
                └── Foundation models / LLMs ── large, self-supervised, task-general, adaptable
                     └── Agents ── an LLM plus tools, memory and a control loop that takes actions
```

**Exam-critical distinction:** classical ML *predicts a label or value*; generative AI *produces new content*. Fraud scoring is ML. Drafting the fraud-investigation summary is generative AI. Most real systems are both.

### 2.2 Learning paradigms

| Paradigm | Data requirement | Canonical task | GCP surface | Production caveat |
|---|---|---|---|---|
| **Supervised** | Labeled examples (X, y) | Classification, regression, forecasting | AutoML Tabular, BigQuery ML, custom training | Labeling cost dominates; label lag delays evaluation |
| **Unsupervised** | Unlabeled X only | Clustering, anomaly detection, dimensionality reduction | `KMEANS`, `PCA` in BigQuery ML | No objective correctness metric — validation is human |
| **Semi-supervised** | Few labels + much unlabeled | Document classification at scale | Custom training | Pseudo-label errors compound silently |
| **Self-supervised** | Raw corpus; labels derived from the data itself | Pre-training LLMs, embeddings | Model Garden (consume, rarely train) | Pre-training is a capex-scale project, not a sprint |
| **Reinforcement learning** | Environment + reward signal | Control, bidding, RLHF alignment | Custom on Vertex AI | Reward hacking; needs a safe simulator |

### 2.3 Discriminative vs generative

| | Discriminative | Generative |
|---|---|---|
| Learns | P(y \| x) — the boundary | P(x) or P(x, y) — the distribution |
| Output | A label, score or number | New content |
| Evaluation | Accuracy, AUC-ROC, RMSE, MAE | Perplexity, BLEU/ROUGE, human preference, LLM-as-judge |
| Typical size | KB → hundreds of MB | GB → hundreds of GB |
| Latency profile | Single forward pass, ~1–20 ms | Autoregressive, N tokens × per-token cost |
| Failure mode | Misclassification | **Hallucination** — fluent, confident, wrong |
| Cost driver | QPS | Input tokens + output tokens |

### 2.4 Generative AI vocabulary the exam expects

| Term | Definition | Operational consequence |
|---|---|---|
| **Token** | Sub-word unit; ~4 chars English | Billing unit; context limits are in tokens, not characters |
| **Context window** | Max tokens per request (input + output) | Long-context reduces need for RAG chunking but raises per-call cost and TTFT |
| **Embedding** | Dense vector encoding semantic meaning | Enables similarity search; the substrate of RAG |
| **Vector search** | ANN retrieval over embeddings | Vertex AI Vector Search; also `VECTOR_SEARCH()` in BigQuery |
| **Prompt engineering** | Shaping input to steer output | Zero-cost; always attempt before tuning |
| **Grounding** | Constraining output to a trusted corpus | The primary hallucination control |
| **RAG** | Retrieve relevant docs → inject into prompt | Fresh data without retraining; cheapest correctness lever |
| **Fine-tuning (SFT/LoRA)** | Adapting weights on domain examples | Teaches *style/format/task*, not facts |
| **Distillation** | Training a small model on a large model's outputs | Cuts serving cost 5–20× at some quality loss |
| **Temperature / top-p / top-k** | Sampling randomness controls | Set temperature≈0 for extraction/classification, higher for ideation |
| **Hallucination** | Fluent output unsupported by evidence | Mitigate with grounding + citations + human-in-the-loop |
| **Agent** | LLM + tools + loop | Introduces non-determinism *and* side effects — needs sandboxing, budgets, audit |

**The adaptation ladder — always climb from the top:**

| Technique | Changes weights? | Cost | Latency impact | Fixes |
|---|---|---|---|---|
| Prompt engineering | No | ~0 | None | Format, tone, simple reasoning |
| Few-shot examples | No | Token cost per call | ↑ input tokens | Task pattern |
| RAG / grounding | No | Retrieval infra + tokens | +20–200 ms | **Factual accuracy, freshness** |
| Supervised fine-tuning (LoRA/PEFT) | Adapter only | Hundreds → low thousands USD | None (adapter merged) | Domain style, output schema, reduced prompt size |
| Full fine-tuning | Yes, all | High | None | Deep domain shift |
| Pre-training | Yes, from scratch | Capex-scale | — | Practically never justified |

> **Exam trap:** "The model gives outdated answers about our product catalogue." → **RAG/grounding**, not fine-tuning. Fine-tuning does not reliably install new facts.

---

## 3. The data foundation — where value is actually won or lost

### 3.1 Data types and where they live

| Type | Examples | Primary GCP store | Why |
|---|---|---|---|
| Structured | Transactions, telemetry rows | BigQuery, Cloud SQL, Spanner | SQL, columnar scan, BigQuery ML in place |
| Semi-structured | JSON events, logs | BigQuery (JSON type), Bigtable | Schema flexibility + query |
| Unstructured | PDFs, images, audio, video | Cloud Storage + Document AI / Vision API | Object storage + extraction to structure |
| Vector | Embeddings | Vertex AI Vector Search, BigQuery, AlloyDB `pgvector` | ANN retrieval for RAG |

### 3.2 Batch vs streaming

| Dimension | Batch | Streaming |
|---|---|---|
| Freshness | Minutes → days | Sub-second → seconds |
| GCP path | Cloud Storage → BigQuery / Dataflow batch | Pub/Sub → Dataflow streaming → BigQuery/Bigtable |
| Cost | Lower; amortised | Higher; always-on workers |
| Use with ML | Batch prediction, retraining | Online features, real-time fraud/personalisation |
| Failure mode | Late job → stale model | Backpressure, watermark lag → stale *features* under live traffic |

### 3.3 Data quality dimensions (the diagnostic checklist)

**Completeness · Accuracy · Consistency · Timeliness · Validity · Uniqueness**

Every one of these maps to an automatable check. Enforce them *before* the training job, not after — a failed data test costs seconds; a bad model costs an accelerator-day plus a production incident.

### 3.4 Labeling economics

Labels are the scarce input. For a supervised classifier, budget the label pipeline explicitly:

```
labels_needed ≈ 1,000–10,000 per class for tabular AutoML
cost_per_label = human_minutes × loaded_hourly_rate / 60
total = labels_needed × classes × cost_per_label × redundancy(2–3 for inter-rater agreement)
```

A 12-class support-ticket classifier at 2,000 labels/class, 20 s/label, $30/h loaded, 2× redundancy ≈ **$8,000 in labeling alone** — routinely larger than the compute budget, and it is a *recurring* cost because taxonomies drift.

### 3.5 Training-serving skew — the number one silent killer

Skew occurs when the feature computation path at training time differs from the path at serving time.

| Skew source | Concrete example | Structural fix |
|---|---|---|
| Different code paths | Training in SQL/PySpark, serving in Java | Single feature definition in Feature Store; shared transform library |
| Different data sources | Training on a nightly warehouse snapshot, serving from live OLTP | Serve from the same store that materialised training features |
| Time travel leakage | Training joined a value only known *after* the prediction moment | Point-in-time-correct joins (Feature Store enforces this) |
| Different defaults | Training imputes NULL→0, serving sends NULL through | Move imputation inside the model graph / serving container |

**Drift vs skew:**
- **Skew** = training distribution ≠ serving distribution *now*.
- **Data drift** = serving distribution changes *over time*.
- **Concept drift** = the relationship P(y|x) itself changes (COVID-era demand models; new fraud tactics).

Skew is a bug. Drift is physics — you plan for it with retraining triggers.

### 3.6 Governance controls (exam-relevant, SRE-owned)

| Control | Service | Enforcement point |
|---|---|---|
| Discovery & lineage | Dataplex Universal Catalog | Catalog, column-level lineage |
| PII discovery & redaction | Sensitive Data Protection (Cloud DLP) | Pre-ingest scan, de-identification templates |
| Perimeter | VPC Service Controls | Prevents exfiltration of training data/models |
| Encryption keys | CMEK (Cloud KMS) | Buckets, BigQuery datasets, Vertex resources |
| Access | IAM + BigQuery row/column-level security | Dataset, table, column |
| Residency | Regional resources + Org Policy `gcp.resourceLocations` | Project/folder |
| Data retention | Object lifecycle, BigQuery table expiration | Bucket/dataset |

---

## 4. The Google Cloud AI solution ladder — the core placement decision

```
 ABSTRACTION ▲
             │  ┌──────────────────────────────────────────────────────────────┐
        HIGH │  │ 1. Pre-built agents / applied AI                             │
             │  │    CCAI, Agentspace, Vertex AI Search, Document AI, Health AI│
             │  ├──────────────────────────────────────────────────────────────┤
             │  │ 2. Pre-trained APIs                                          │
             │  │    Vision, Speech-to-Text, Text-to-Speech, Translation,      │
             │  │    Natural Language, Video Intelligence                      │
             │  ├──────────────────────────────────────────────────────────────┤
             │  │ 3. Foundation models + adaptation                            │
             │  │    Gemini via Vertex AI Studio, Model Garden, RAG Engine,    │
             │  │    supervised tuning, Agent Builder / ADK                    │
             │  ├──────────────────────────────────────────────────────────────┤
             │  │ 4. Low-code custom models                                    │
             │  │    AutoML (tabular/image/text/video), BigQuery ML (SQL)      │
             │  ├──────────────────────────────────────────────────────────────┤
         LOW │  │ 5. Fully custom                                              │
             │  │    Vertex AI Training containers, GKE + GPU/TPU, Ray on VAI  │
             ▼  └──────────────────────────────────────────────────────────────┘
                CONTROL ▲ , TIME-TO-VALUE ▼ , TCO ▲ , REQUIRED SKILL ▲
```

### 4.1 Trade-off matrix

| Rung | Data you must supply | ML skill | Time to first value | Marginal cost model | Differentiation | Choose when |
|---|---|---|---|---|---|---|
| **1. Pre-built agents** | Your content/corpus | None | Days | Per query / per session / per seat | None | Solved vertical problem (contact centre, enterprise search) |
| **2. Pre-trained APIs** | None (send payload) | None | Hours | Per 1,000 units (image, minute, char) | None | Commodity perception task; no proprietary signal exists |
| **3. Foundation models** | Prompts + optional corpus | Prompt/RAG skills | Days | Per 1M input + output tokens | Medium (your data via RAG) | Language/multimodal, open-ended, generative |
| **4. AutoML / BigQuery ML** | Labeled tabular/media data | Analyst-level | Days–weeks | Node-hours (AutoML) or bytes scanned + slots (BQML) | **High** — your data | Proprietary structured data, standard task |
| **5. Custom training** | Everything | ML engineers + platform team | Weeks–months | Accelerator-hours + serving nodes | **Highest** | Novel architecture, extreme scale/latency, IP moat |

**Decision procedure (state it in this order — the exam rewards it):**

1. Is it a *solved* vertical problem? → rung 1.
2. Is it a *generic* perception task (OCR, transcription, translation, object detection)? → rung 2.
3. Is the output *generated content* or open-ended language? → rung 3.
4. Do you have *proprietary labeled structured data* and a standard task? → rung 4. Prefer **BigQuery ML** if the data is already in BigQuery — data gravity beats everything.
5. Only if 1–4 fail → rung 5.

> **Never descend a rung for prestige.** Rung 5 multiplies headcount, on-call surface and TCO by roughly an order of magnitude versus rung 4 for the same business KPI.

### 4.2 AutoML vs BigQuery ML vs custom

| | BigQuery ML | Vertex AI AutoML | Custom training |
|---|---|---|---|
| Interface | SQL | Console / API | Python + container |
| Data movement | **Zero** (data stays in BigQuery) | Export/import | Full pipeline |
| Model types | Linear/logistic, k-means, boosted trees, DNN, ARIMA_PLUS, matrix factorisation, PCA, autoencoder, remote Gemini models | Tabular, image, text, video | Anything |
| Feature engineering | `TRANSFORM` clause — persisted into the model, **eliminates serving skew** | Automatic | Yours to build |
| Typical training time | Minutes | 1–24 h (node-hours) | Hours–days |
| Serving | In-SQL `ML.PREDICT`, or export to Vertex Endpoint | Vertex Endpoint / batch | Any |
| Best for | Analyst teams, warehouse-resident data, fast baselines | Media + tabular, no code | Research-grade, extreme SLO |

---

## 5. Compute substrate: CPU vs GPU vs TPU

| | CPU | GPU (L4 / A100 / H100) | TPU (v5e / v5p / Trillium) |
|---|---|---|---|
| Parallelism model | Few fast general cores | Thousands of SIMT cores | Systolic array for dense matmul |
| Best fit | Small tabular models, preprocessing, low-QPS inference | Deep learning training & inference, custom CUDA kernels, mixed workloads | Very large dense transformer training and high-throughput serving |
| Ecosystem | Universal | CUDA — widest framework support | JAX / TensorFlow / PyTorch-XLA |
| Interconnect | — | NVLink / NVSwitch within host | Inter-Chip Interconnect, 2D/3D torus across pods |
| Cost/perf at scale | Poor for DL | Good | Best perf-per-dollar for supported large models |
| Elasticity trick | Preemptible/Spot | Spot GPUs, DWS (Dynamic Workload Scheduler) | Spot TPUs, queued resources |
| Watch out for | Nothing | Quota per region, driver/CUDA version pinning | Model must be XLA-compatible; sharding is a design task |

**Cost lever ranking for training (highest impact first):** Spot/DWS capacity → right-sized accelerator → mixed precision (bf16) → efficient data pipeline (input pipeline starvation wastes 100 % of the accelerator) → distributed strategy → smaller model/distillation.

---

## 6. Serving architectures

| Option | Latency | Autoscale to zero | Ops burden | Use when |
|---|---|---|---|---|
| **Vertex AI online Endpoint** | ~10–100 ms | No (min replicas ≥ 1 for dedicated) | Low | Standard online prediction, traffic splitting, built-in monitoring |
| **Vertex AI batch prediction** | Minutes–hours | N/A | Lowest | Scoring millions of rows nightly; cheapest per prediction |
| **BigQuery `ML.PREDICT`** | Query-time | N/A | Lowest | Scores consumed by analytics/BI; no data egress |
| **GKE + KServe / Triton** | Single-digit ms achievable | Yes (KServe/Knative) | High | Custom runtimes, multi-model, GPU sharing, strict cost control, hybrid |
| **Cloud Run (+ GPU)** | ~50–500 ms incl. cold start | **Yes** | Low | Spiky, low-average-QPS workloads |
| **Edge / on-device** | Sub-ms, offline | N/A | Medium | Air-gapped, privacy, bandwidth-constrained |

**Latency budget arithmetic for a 200 ms user-facing SLO:**

```
  client → LB               ~10 ms
  auth / API gateway        ~15 ms
  feature fetch (online FS) ~20 ms   ← Bigtable-backed, p99
  vector retrieval (RAG)    ~35 ms
  model forward pass        ~40 ms   ← the only part people optimise
  post-process + response   ~15 ms
  ------------------------------------
  budget consumed          ~135 ms
  headroom for p99 tail     ~65 ms
```

The model is 30 % of the budget. Optimising it in isolation is the classic misallocation.

---

## 7. MLOps maturity — the operating model

| Level | Description | Training trigger | Deployment unit | Typical cadence | Team shape |
|---|---|---|---|---|---|
| **0 — Manual** | Notebook → handoff → manual deploy | Human | Trained model artifact | Months | Data scientists only |
| **1 — ML pipeline automation** | Automated, parameterised training pipeline; continuous training (CT) | Schedule, data volume, drift alert | **The pipeline**, plus model | Weeks → days | + ML engineer |
| **2 — CI/CD pipeline automation** | Source-triggered build/test/deploy of pipeline components | Code commit, data, drift, performance | Pipeline *components* (containers) | Days → hours | + Platform/SRE |

**Level-2 required artifacts:**
- Source-controlled pipeline definition (KFP/TFX) and component containers in Artifact Registry.
- Model Registry with immutable versions, lineage back to data snapshot + code SHA.
- Automated evaluation **gates** (accuracy floor, fairness slices, latency, payload schema).
- Progressive delivery: shadow → canary (traffic split) → full, with automatic rollback.
- Model Monitoring with alerting into the same on-call rotation as the rest of the platform.

---

## 8. Business value — the part the exam actually grades

### 8.1 The value chain

```
Data asset ──▶ Model metric ──▶ Decision change ──▶ Operational KPI ──▶ Financial outcome
(clean,        (AUC 0.87)       (auto-route 62 %   (AHT −90 s,        (−$2.1 M/yr opex,
 governed)                       of tickets)        CSAT +4 pts)        +$0.9 M retained rev)
```

**A model metric is never the business case.** An AUC of 0.87 is worth exactly $0 until a decision changes. Every AI proposal must name (a) the decision, (b) who or what makes it today, (c) the counterfactual baseline, and (d) the measurement plan.

### 8.2 The four value archetypes

| Archetype | Mechanism | Example | Primary KPI |
|---|---|---|---|
| **Cost reduction** | Automate/assist human effort | Ticket triage, document extraction, code assist | Cost per transaction, handle time, FTE-hours |
| **Revenue growth** | Better targeting/personalisation | Recommendations, propensity, dynamic pricing | Conversion, AOV, LTV, attach rate |
| **Risk reduction** | Detect what humans miss | Fraud, AML, predictive maintenance, anomaly detection | Loss rate, false-negative rate, unplanned downtime |
| **New capability** | Products impossible without AI | Real-time translation, generative design, conversational products | New-product revenue, market entry |

### 8.3 Unit economics — the model every architect should be able to sketch

> Figures below are **illustrative arithmetic**, not quotes. Always recompute against the live pricing pages in §14 for your region and SKU.

```
Use case: classify 3,000,000 support tickets/month into 12 queues.

OPTION A — Vertex AI online Endpoint (AutoML tabular/text, n1-standard-4 replicas)
  Peak 40 QPS, avg 12 QPS → 3 replicas steady, 6 at peak (~4 avg replicas)
  Serving:      4 replicas × 730 h × $node_hour
  Training:     ~6 node-hours/retrain × 2 retrains/month
  Monitoring:   per-prediction sampling
  → Fixed monthly floor exists even at 03:00 traffic.

OPTION B — Vertex AI batch prediction, hourly windows
  3M rows/month, batched 4,200/hour
  → No always-on replicas; cost scales with rows, ~1 order of magnitude cheaper
  → Acceptable ONLY if a ≤60 min routing delay meets the business SLA.

OPTION C — Gemini via Vertex AI, zero-shot with a rubric prompt
  avg 900 input + 15 output tokens per ticket
  3M × 900  = 2.70 B input tokens/month
  3M × 15   = 0.045 B output tokens/month
  → cost = 2700 × $in_per_1M + 45 × $out_per_1M
  → Levers: prompt compression (−40 % input tokens), context caching for the
    shared rubric, batch API discount, distillation to a small model.

DECISION RULE
  Latency SLA ≤ seconds and QPS high & stable      → A
  Latency SLA in minutes/hours                     → B  (usually 5–20× cheaper)
  Taxonomy volatile / no labels / needs rationale  → C, then distil to A or B once
                                                     you have accumulated labels
```

The generalisable rule: **generative AI buys you time-to-value and flexibility; classical ML buys you unit cost.** Mature systems start at C to bootstrap labels and end at A/B for the steady-state volume.

### 8.4 Total cost of ownership — what proposals forget

| Cost line | Frequently omitted? | Notes |
|---|---|---|
| Training compute | No | Usually over-estimated |
| Serving compute | Sometimes | Dominates for online, always-on models |
| **Data labeling** | **Yes** | Often the largest single line; recurring |
| **Data pipeline engineering** | **Yes** | 40–60 % of total effort |
| Storage (raw + features + artifacts + logs) | Yes | Prediction logging at scale is non-trivial |
| Monitoring & evaluation | Yes | Includes human review panels for GenAI |
| **Retraining cadence** | **Yes** | Drift is perpetual; budget it as run-rate, not project |
| Governance, model cards, audit | Yes | Regulated industries: significant |
| On-call / incident load | Yes | New alert class, new runbooks |
| Model decommissioning | Yes | Shadow dependencies are hard to find |

### 8.5 KPI instrumentation

| Layer | Leading indicator | Lagging indicator | Owner |
|---|---|---|---|
| Data | Freshness lag, null rate, schema violations | Retraining failures | Data platform |
| Model | Prediction distribution stability, feature drift score, attribution drift | Accuracy/AUC on delayed labels | ML engineering |
| Service | p99 latency, error rate, replica saturation, cost/1k predictions | Monthly spend | SRE |
| Product | Adoption %, override/rejection rate, human-escalation rate | Conversion, churn, AHT, loss rate | Product |
| Business | Incremental margin per decision | Annualised P&L impact | Finance/Business |

**Override rate is the most underrated metric.** If agents override the model 45 % of the time, the model is producing zero decision change regardless of its AUC.

### 8.6 Measuring causally

Correlational dashboards ("users who saw recommendations converted 22 % more") are not evidence. Use:
1. **A/B test** — randomised holdout is the default and the strongest.
2. **Switchback / geo test** — when interference between users breaks A/B.
3. **Pre-post with a control group** — weakest; only when randomisation is impossible.

Always keep a permanent **holdout population** (1–5 %) with no model applied. It is the only way to know, twelve months in, what the model is worth.

---

## 9. Responsible AI as an engineering control

### 9.1 Google's AI Principles

The original 2018 framework enumerated **seven principles** — AI should (1) be socially beneficial, (2) avoid creating or reinforcing unfair bias, (3) be built and tested for safety, (4) be accountable to people, (5) incorporate privacy design principles, (6) uphold high standards of scientific excellence, (7) be made available for uses that accord with these principles — plus four application areas Google will not pursue (technologies causing overall harm, weapons, surveillance violating international norms, and uses contravening international law and human rights). Google restructured its published AI Principles in 2025 around **bold innovation, responsible development and deployment, and collaborative progress**; the underlying commitments (fairness, safety, privacy, accountability, human oversight) persist. For the exam, know that Google publishes binding AI Principles and can articulate fairness, safety, privacy, explainability and accountability as design requirements — verify the exact current wording at the URL in §14.

### 9.2 Bias taxonomy — and where it enters your pipeline

| Bias type | Enters at | Detection | Mitigation |
|---|---|---|---|
| Selection / sampling | Data collection | Compare training distribution to population | Reweighting, targeted collection |
| Historical | The world the data records | Sliced performance analysis | Re-frame label, add fairness constraint |
| Measurement | Instrumentation differences by group | Per-group feature distributions | Fix instrumentation, drop proxy features |
| Labeling | Human annotators | Inter-rater agreement by annotator cohort | Rubrics, diverse pools, adjudication |
| Aggregation | One model for heterogeneous groups | Sliced metrics | Per-segment models or group features |
| Deployment / feedback loop | Model output shapes future training data | Holdout comparison over time | Randomised exploration, permanent holdout |

**Fairness is a slice-level metric, never an aggregate.** Overall accuracy 94 % with 71 % on a protected slice is a governance failure that the headline number conceals. Wire sliced evaluation into the pipeline gate.

### 9.3 Explainability and human oversight

- **Vertex Explainable AI** provides feature attributions (sampled Shapley, integrated gradients, XRAI) for tabular and image models. Attribution *drift* is a leading indicator of concept drift — feature importances shift before accuracy visibly degrades.
- **Model Cards** document intended use, out-of-scope use, training data, evaluation slices and limitations. Treat them as required release artifacts, like a runbook.
- **Human-in-the-loop** placement by risk tier:

| Risk tier | Examples | Pattern |
|---|---|---|
| Low | Product recommendations, ranking | Fully automated, monitored |
| Medium | Ticket routing, spend categorisation | Automated with confidence threshold; low-confidence → human |
| High | Credit, hiring, medical, legal | **Human decides**; model advises with explanation, decision is logged and auditable |

### 9.4 GenAI-specific safety controls

Grounding to an authoritative corpus · citations returned with every answer · safety filters (harassment, hate, sexual, dangerous content) · prompt-injection defence for agents (never let retrieved text carry tool authority) · PII de-identification pre-prompt · output validation against a JSON schema · token and tool-call budgets per session · full request/response logging for audit.

---

## 10. Reference implementation — complete infrastructure

### 10.1 Terraform: platform foundation

```hcl
# ─────────────────────────────────────────────────────────────────────────────
# main.tf — Vertex AI platform foundation for a churn-prediction workload
# Terraform >= 1.6, google provider >= 5.30
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
    }
  }
  backend "gcs" {
    bucket = "acme-tfstate-prod"
    prefix = "ai-platform/churn"
  }
}

variable "project_id" {
  type        = string
  description = "Target Google Cloud project"
}

variable "region" {
  type        = string
  default     = "europe-west4"
  description = "Region for all regional resources; must satisfy data residency"
}

variable "kms_key_ring" {
  type        = string
  default     = "ai-platform"
}

locals {
  labels = {
    workload    = "churn-prediction"
    env         = "prod"
    cost_center = "cc-4471"
    data_class  = "confidential"
    owner       = "ml-platform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── 1. Enable the APIs the platform depends on ───────────────────────────────
resource "google_project_service" "required" {
  for_each = toset([
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
    "dataflow.googleapis.com",
    "dlp.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "notebooks.googleapis.com",
    "pubsub.googleapis.com",
    "storage.googleapis.com",
  ])
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# ── 2. Customer-managed encryption ───────────────────────────────────────────
resource "google_kms_key_ring" "ai" {
  name     = var.kms_key_ring
  location = var.region
  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "ai" {
  name            = "vertex-artifacts"
  key_ring        = google_kms_key_ring.ai.id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"
  lifecycle {
    prevent_destroy = true
  }
}

# ── 3. Identity: one service account per pipeline stage (least privilege) ────
resource "google_service_account" "training" {
  account_id   = "sa-vertex-training"
  display_name = "Vertex AI training jobs (churn)"
}

resource "google_service_account" "serving" {
  account_id   = "sa-vertex-serving"
  display_name = "Vertex AI online prediction (churn)"
}

resource "google_service_account" "pipeline" {
  account_id   = "sa-vertex-pipeline"
  display_name = "Vertex AI Pipelines orchestrator (churn)"
}

resource "google_project_iam_member" "training_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/bigquery.dataViewer",
    "roles/bigquery.jobUser",
    "roles/storage.objectAdmin",
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.training.email}"
}

resource "google_project_iam_member" "serving_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/storage.objectViewer",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.serving.email}"
}

resource "google_project_iam_member" "pipeline_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/storage.objectAdmin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.pipeline.email}"
}

resource "google_kms_crypto_key_iam_member" "vertex_sa_kms" {
  crypto_key_id = google_kms_crypto_key.ai.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
}

data "google_project" "this" {
  project_id = var.project_id
}

# ── 4. Storage: staging, artifacts, prediction logs ──────────────────────────
resource "google_storage_bucket" "staging" {
  name                        = "${var.project_id}-vertex-staging"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false
  public_access_prevention    = "enforced"
  labels                      = local.labels

  versioning { enabled = true }

  encryption {
    default_kms_key_name = google_kms_crypto_key.ai.id
  }

  lifecycle_rule {
    condition { age = 45 }
    action     { type = "Delete" }
  }

  depends_on = [google_kms_crypto_key_iam_member.vertex_sa_kms]
}

resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-model-artifacts"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels

  versioning { enabled = true }

  encryption {
    default_kms_key_name = google_kms_crypto_key.ai.id
  }

  # Model artifacts are the rollback surface: retain, do not delete.
  lifecycle_rule {
    condition { num_newer_versions = 20 }
    action     { type = "Delete" }
  }

  depends_on = [google_kms_crypto_key_iam_member.vertex_sa_kms]
}

# ── 5. BigQuery: feature and label warehouse ─────────────────────────────────
resource "google_bigquery_dataset" "ml" {
  dataset_id                 = "ml_churn"
  friendly_name              = "Churn ML feature and label store"
  location                   = "EU"
  delete_contents_on_destroy = false
  labels                     = local.labels

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.ai.id
  }

  access {
    role          = "OWNER"
    user_by_email = google_service_account.pipeline.email
  }
  access {
    role          = "READER"
    user_by_email = google_service_account.training.email
  }
}

# ── 6. Container registry for pipeline components ────────────────────────────
resource "google_artifact_registry_repository" "components" {
  location      = var.region
  repository_id = "ml-components"
  description   = "Pipeline component and serving container images"
  format        = "DOCKER"
  kms_key_name  = google_kms_crypto_key.ai.id
  labels        = local.labels

  cleanup_policies {
    id     = "keep-recent-tagged"
    action = "KEEP"
    most_recent_versions {
      keep_count = 30
    }
  }
}

# ── 7. Serving: model + endpoint ─────────────────────────────────────────────
resource "google_vertex_ai_endpoint" "churn" {
  name         = "churn-scoring-prod"
  display_name = "churn-scoring-prod"
  description  = "Online churn propensity scoring, p99 SLO 120 ms"
  location     = var.region
  region       = var.region
  labels       = local.labels

  encryption_spec {
    kms_key_name = google_kms_crypto_key.ai.id
  }
}

# ── 8. Retraining trigger topic (drift alerts fan out to here) ───────────────
resource "google_pubsub_topic" "retrain_trigger" {
  name   = "ml-churn-retrain-trigger"
  labels = local.labels
}

# ── 9. Alerting on the drift/skew signal ─────────────────────────────────────
resource "google_monitoring_notification_channel" "oncall" {
  display_name = "ML Platform on-call"
  type         = "pubsub"
  labels = {
    topic = google_pubsub_topic.retrain_trigger.id
  }
}

resource "google_monitoring_alert_policy" "prediction_latency" {
  display_name = "churn-endpoint p99 latency > 120ms"
  combiner     = "OR"

  conditions {
    display_name = "p99 prediction latency"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"aiplatform.googleapis.com/Endpoint\"",
        "metric.type = \"aiplatform.googleapis.com/prediction/online/response_latencies\"",
        "resource.label.endpoint_id = \"${google_vertex_ai_endpoint.churn.name}\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 120
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.oncall.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "Runbook: docs/runbooks/churn-endpoint-latency.md"
    mime_type = "text/markdown"
  }
}

output "endpoint_id" {
  value       = google_vertex_ai_endpoint.churn.id
  description = "Fully-qualified endpoint resource name"
}

output "artifact_bucket" {
  value = google_storage_bucket.artifacts.url
}
```

### 10.2 Vertex AI Pipeline (Kubeflow Pipelines v2) — training pipeline definition

```python
# pipeline.py — compiled with: kfp dsl-compile / compiler.Compiler()
# Produces churn_training_pipeline.yaml, submitted to Vertex AI Pipelines.
from kfp import dsl, compiler
from kfp.dsl import Dataset, Input, Metrics, Model, Output

PROJECT = "acme-ml-prod"
REGION = "europe-west4"
IMAGE = f"{REGION}-docker.pkg.dev/{PROJECT}/ml-components/churn-trainer:1.7.3"


@dsl.component(base_image=IMAGE, packages_to_install=["google-cloud-bigquery==3.25.0"])
def validate_data(
    bq_table: str,
    min_rows: int,
    max_null_ratio: float,
    validated: Output[Dataset],
) -> None:
    """Fail the pipeline BEFORE spending accelerator time on bad data."""
    from google.cloud import bigquery

    client = bigquery.Client()
    query = f"""
    SELECT
      COUNT(*)                                          AS row_count,
      COUNTIF(tenure_days IS NULL) / COUNT(*)           AS null_tenure,
      COUNTIF(monthly_spend IS NULL) / COUNT(*)         AS null_spend,
      COUNTIF(churned IS NULL) / COUNT(*)               AS null_label,
      COUNT(DISTINCT customer_id)                       AS distinct_customers,
      MAX(snapshot_date)                                AS freshest
    FROM `{bq_table}`
    """
    row = list(client.query(query).result())[0]

    if row.row_count < min_rows:
        raise ValueError(f"completeness: {row.row_count} rows < {min_rows}")
    for name in ("null_tenure", "null_spend", "null_label"):
        if getattr(row, name) > max_null_ratio:
            raise ValueError(f"completeness: {name}={getattr(row, name):.4f} > {max_null_ratio}")
    if row.distinct_customers != row.row_count:
        raise ValueError("uniqueness: duplicate customer_id in training snapshot")

    with open(validated.path, "w") as fh:
        fh.write(bq_table)


@dsl.component(base_image=IMAGE)
def train_model(
    validated: Input[Dataset],
    learning_rate: float,
    max_depth: int,
    n_estimators: int,
    model: Output[Model],
    metrics: Output[Metrics],
) -> None:
    import json, os, joblib
    import pandas as pd
    from google.cloud import bigquery
    from sklearn.ensemble import GradientBoostingClassifier
    from sklearn.metrics import roc_auc_score, average_precision_score
    from sklearn.model_selection import train_test_split

    table = open(validated.path).read().strip()
    df = bigquery.Client().query(f"SELECT * FROM `{table}`").to_dataframe()

    feature_cols = [c for c in df.columns if c not in ("customer_id", "churned", "snapshot_date")]
    X, y = df[feature_cols], df["churned"]
    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, stratify=y, random_state=42)

    clf = GradientBoostingClassifier(
        learning_rate=learning_rate, max_depth=max_depth,
        n_estimators=n_estimators, random_state=42,
    )
    clf.fit(X_tr, y_tr)

    proba = clf.predict_proba(X_te)[:, 1]
    auc = float(roc_auc_score(y_te, proba))
    pr_auc = float(average_precision_score(y_te, proba))

    metrics.log_metric("roc_auc", auc)
    metrics.log_metric("pr_auc", pr_auc)
    metrics.log_metric("train_rows", int(len(X_tr)))
    metrics.log_metric("positive_rate", float(y.mean()))

    os.makedirs(model.path, exist_ok=True)
    joblib.dump(clf, os.path.join(model.path, "model.joblib"))
    with open(os.path.join(model.path, "feature_order.json"), "w") as fh:
        json.dump(feature_cols, fh)  # serving must replay this exact order


@dsl.component(base_image=IMAGE)
def evaluate_fairness(
    validated: Input[Dataset],
    model: Input[Model],
    slice_column: str,
    min_slice_auc: float,
    max_auc_gap: float,
    report: Output[Metrics],
) -> bool:
    """Gate: no slice may fall below the floor, and the spread is bounded."""
    import json, joblib, os
    from google.cloud import bigquery
    from sklearn.metrics import roc_auc_score

    table = open(validated.path).read().strip()
    df = bigquery.Client().query(f"SELECT * FROM `{table}`").to_dataframe()
    clf = joblib.load(os.path.join(model.path, "model.joblib"))
    order = json.load(open(os.path.join(model.path, "feature_order.json")))

    slice_aucs = {}
    for value, grp in df.groupby(slice_column):
        if len(grp) < 500 or grp["churned"].nunique() < 2:
            continue
        slice_aucs[str(value)] = float(
            roc_auc_score(grp["churned"], clf.predict_proba(grp[order])[:, 1])
        )

    for name, auc in slice_aucs.items():
        report.log_metric(f"auc_{name}", auc)

    worst, best = min(slice_aucs.values()), max(slice_aucs.values())
    report.log_metric("worst_slice_auc", worst)
    report.log_metric("auc_gap", best - worst)

    return worst >= min_slice_auc and (best - worst) <= max_auc_gap


@dsl.component(base_image=IMAGE)
def register_and_deploy(
    project: str,
    region: str,
    endpoint_id: str,
    model: Input[Model],
    display_name: str,
    canary_percent: int,
) -> None:
    from google.cloud import aiplatform

    aiplatform.init(project=project, location=region)
    uploaded = aiplatform.Model.upload(
        display_name=display_name,
        artifact_uri=model.uri,
        serving_container_image_uri=(
            f"{region}-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest"
        ),
        labels={"workload": "churn-prediction", "env": "prod"},
    )
    endpoint = aiplatform.Endpoint(endpoint_id)
    uploaded.deploy(
        endpoint=endpoint,
        deployed_model_display_name=display_name,
        machine_type="n1-standard-4",
        min_replica_count=2,
        max_replica_count=10,
        traffic_percentage=canary_percent,   # progressive delivery, not big-bang
        enable_access_logging=True,
    )


@dsl.pipeline(
    name="churn-training-pipeline",
    description="Validated, gated, canary-deployed churn model",
    pipeline_root="gs://acme-ml-prod-vertex-staging/pipelines/churn",
)
def churn_pipeline(
    bq_table: str = "acme-ml-prod.ml_churn.training_snapshot",
    endpoint_id: str = "projects/acme-ml-prod/locations/europe-west4/endpoints/churn-scoring-prod",
    learning_rate: float = 0.05,
    max_depth: int = 4,
    n_estimators: int = 400,
    min_rows: int = 250000,
    max_null_ratio: float = 0.02,
    slice_column: str = "region_code",
    min_slice_auc: float = 0.78,
    max_auc_gap: float = 0.07,
    canary_percent: int = 10,
):
    v = validate_data(bq_table=bq_table, min_rows=min_rows, max_null_ratio=max_null_ratio)
    v.set_caching_options(False)  # data changes even when parameters do not

    t = train_model(
        validated=v.outputs["validated"],
        learning_rate=learning_rate,
        max_depth=max_depth,
        n_estimators=n_estimators,
    )
    t.set_cpu_limit("8").set_memory_limit("32G")
    t.set_retry(num_retries=2, backoff_duration="60s")

    f = evaluate_fairness(
        validated=v.outputs["validated"],
        model=t.outputs["model"],
        slice_column=slice_column,
        min_slice_auc=min_slice_auc,
        max_auc_gap=max_auc_gap,
    )

    with dsl.If(f.output == True, name="fairness-gate-passed"):
        register_and_deploy(
            project="acme-ml-prod",
            region="europe-west4",
            endpoint_id=endpoint_id,
            model=t.outputs["model"],
            display_name="churn-gbc",
            canary_percent=canary_percent,
        )


if __name__ == "__main__":
    compiler.Compiler().compile(
        pipeline_func=churn_pipeline,
        package_path="churn_training_pipeline.yaml",
    )
```

### 10.3 Vertex AI Model Monitoring job (drift + skew) — request payload

```yaml
# monitoring-job.yaml — POST to
#   https://europe-west4-aiplatform.googleapis.com/v1/projects/acme-ml-prod/
#   locations/europe-west4/modelDeploymentMonitoringJobs
displayName: churn-scoring-prod-monitoring
endpoint: projects/acme-ml-prod/locations/europe-west4/endpoints/churn-scoring-prod

# Sample 20% of live traffic; 100% is rarely necessary and costs storage.
loggingSamplingStrategy:
  randomSampleConfig:
    sampleRate: 0.2

modelDeploymentMonitoringScheduleConfig:
  monitorInterval: 3600s          # hourly analysis window

modelMonitoringAlertConfig:
  emailAlertConfig:
    userEmails:
      - ml-platform-oncall@acme.example
  enableLogging: true             # emits to Cloud Logging → alert policy → Pub/Sub

# The training baseline. Skew = live vs THIS. Drift = live vs previous window.
modelDeploymentMonitoringObjectiveConfigs:
  - deployedModelId: "4471029384756201984"
    objectiveConfig:
      trainingDataset:
        dataFormat: bigquery
        bigquerySource:
          inputUri: bq://acme-ml-prod.ml_churn.training_snapshot
        targetField: churned
      trainingPredictionSkewDetectionConfig:
        skewThresholds:
          tenure_days:        { value: 0.10 }
          monthly_spend:      { value: 0.10 }
          support_tickets_30d:{ value: 0.15 }
          region_code:        { value: 0.05 }
          plan_tier:          { value: 0.05 }
        attributionScoreSkewThresholds:
          tenure_days:   { value: 0.20 }
          monthly_spend: { value: 0.20 }
      predictionDriftDetectionConfig:
        driftThresholds:
          tenure_days:        { value: 0.10 }
          monthly_spend:      { value: 0.10 }
          support_tickets_30d:{ value: 0.15 }
          region_code:        { value: 0.05 }
          plan_tier:          { value: 0.05 }
        attributionScoreDriftThresholds:
          tenure_days:   { value: 0.20 }
          monthly_spend: { value: 0.20 }
      explanationConfig:
        enableFeatureAttributes: true

logTtl: 2592000s                  # 30 days of prediction logs
labels:
  workload: churn-prediction
  env: prod
```

### 10.4 Self-managed serving on GKE with KServe (rung 5 / cost-controlled)

```yaml
# ─── namespace + quota: an ML namespace without a quota WILL consume the cluster
apiVersion: v1
kind: Namespace
metadata:
  name: ml-serving
  labels:
    workload: churn-prediction
    env: prod
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ml-serving-quota
  namespace: ml-serving
spec:
  hard:
    requests.cpu: "64"
    requests.memory: 256Gi
    requests.nvidia.com/gpu: "8"
    limits.cpu: "128"
    limits.memory: 512Gi
    persistentvolumeclaims: "20"
---
# ─── Workload Identity: no service-account keys on disk, ever
apiVersion: v1
kind: ServiceAccount
metadata:
  name: churn-serving
  namespace: ml-serving
  annotations:
    iam.gke.io/gcp-service-account: sa-vertex-serving@acme-ml-prod.iam.gserviceaccount.com
---
# ─── KServe InferenceService: model server + transformer, autoscaled on concurrency
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: churn-scorer
  namespace: ml-serving
  annotations:
    serving.kserve.io/enable-prometheus-scraping: "true"
    autoscaling.knative.dev/class: kpa.autoscaling.knative.dev
    autoscaling.knative.dev/metric: concurrency
    autoscaling.knative.dev/target: "8"
    autoscaling.knative.dev/window: "60s"
spec:
  predictor:
    serviceAccountName: churn-serving
    minReplicas: 2
    maxReplicas: 20
    scaleTarget: 8
    scaleMetric: concurrency
    containerConcurrency: 16
    timeout: 5
    sklearn:
      protocolVersion: v2
      storageUri: gs://acme-ml-prod-model-artifacts/churn/v1.7.3/
      resources:
        requests:
          cpu: "2"
          memory: 4Gi
        limits:
          cpu: "4"
          memory: 8Gi
      env:
        - name: OMP_NUM_THREADS
          value: "2"                 # prevents BLAS thread storms under high replica count
    nodeSelector:
      cloud.google.com/compute-class: Balanced
    tolerations:
      - key: ml-serving
        operator: Equal
        value: "true"
        effect: NoSchedule
  transformer:
    serviceAccountName: churn-serving
    minReplicas: 2
    maxReplicas: 20
    containers:
      - name: kserve-container
        image: europe-west4-docker.pkg.dev/acme-ml-prod/ml-components/churn-transformer:1.7.3
        args:
          - --model_name=churn-scorer
          - --feature_store_endpoint=featurestore.googleapis.com
          - --feature_view=customer_online_v3
        resources:
          requests:
            cpu: "1"
            memory: 2Gi
          limits:
            cpu: "2"
            memory: 4Gi
        readinessProbe:
          httpGet:
            path: /v2/health/ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /v2/health/live
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 15
---
# ─── Canary via KServe canaryTrafficPercent is set on update; explicit PDB here
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: churn-scorer-pdb
  namespace: ml-serving
spec:
  minAvailable: 1
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: churn-scorer
---
# ─── Deny-by-default egress: a model server has no business calling the internet
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: churn-scorer-egress
  namespace: ml-serving
spec:
  podSelector:
    matchLabels:
      serving.kserve.io/inferenceservice: churn-scorer
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 199.36.153.8/30      # private.googleapis.com
      ports:
        - protocol: TCP
          port: 443
---
# ─── SLO burn-rate alert as code
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: churn-scorer-metrics
  namespace: ml-serving
spec:
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: churn-scorer
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

### 10.5 Cloud Build: CI for the pipeline components (MLOps level 2)

```yaml
# cloudbuild.yaml — triggered on push to main under ml/churn/**
substitutions:
  _REGION: europe-west4
  _REPO: ml-components
  _PIPELINE_ROOT: gs://acme-ml-prod-vertex-staging/pipelines/churn
  _SA: sa-vertex-pipeline@acme-ml-prod.iam.gserviceaccount.com

options:
  logging: CLOUD_LOGGING_ONLY
  machineType: E2_HIGHCPU_8
  dynamicSubstitutions: true

steps:
  - id: unit-tests
    name: python:3.12-slim
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir -r ml/churn/requirements-dev.txt
        pytest ml/churn/tests -q --junitxml=/workspace/junit.xml

  - id: data-contract-test
    name: python:3.12-slim
    waitFor: ['unit-tests']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir -r ml/churn/requirements-dev.txt
        python ml/churn/tests/assert_schema.py \
          --table acme-ml-prod.ml_churn.training_snapshot \
          --contract ml/churn/contracts/training_snapshot.yaml

  - id: build-trainer
    name: gcr.io/cloud-builders/docker
    waitFor: ['data-contract-test']
    args:
      - build
      - -t
      - ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-trainer:$SHORT_SHA
      - -t
      - ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-trainer:latest
      - -f
      - ml/churn/Dockerfile.trainer
      - ml/churn

  - id: build-transformer
    name: gcr.io/cloud-builders/docker
    waitFor: ['data-contract-test']
    args:
      - build
      - -t
      - ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-transformer:$SHORT_SHA
      - -f
      - ml/churn/Dockerfile.transformer
      - ml/churn

  - id: push
    name: gcr.io/cloud-builders/docker
    waitFor: ['build-trainer', 'build-transformer']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        docker push --all-tags ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-trainer
        docker push --all-tags ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-transformer

  - id: compile-pipeline
    name: python:3.12-slim
    waitFor: ['push']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir kfp==2.9.0 google-cloud-aiplatform==1.71.0
        python ml/churn/pipeline.py
        gsutil cp churn_training_pipeline.yaml \
          ${_PIPELINE_ROOT}/definitions/churn_training_pipeline_$SHORT_SHA.yaml

  - id: submit-pipeline
    name: python:3.12-slim
    waitFor: ['compile-pipeline']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir google-cloud-aiplatform==1.71.0
        python - <<'PY'
        import os
        from google.cloud import aiplatform
        aiplatform.init(project="acme-ml-prod", location="europe-west4",
                        staging_bucket="gs://acme-ml-prod-vertex-staging")
        job = aiplatform.PipelineJob(
            display_name=f"churn-training-{os.environ['SHORT_SHA']}",
            template_path="churn_training_pipeline.yaml",
            pipeline_root="gs://acme-ml-prod-vertex-staging/pipelines/churn",
            parameter_values={"canary_percent": 10},
            enable_caching=True,
        )
        job.submit(service_account="sa-vertex-pipeline@acme-ml-prod.iam.gserviceaccount.com")
        print(job.resource_name)
        PY

artifacts:
  objects:
    location: gs://acme-ml-prod-vertex-staging/builds/$SHORT_SHA/
    paths: ['churn_training_pipeline.yaml', 'junit.xml']

timeout: 2400s
```

---

## 11. CLI walkthrough

### 11.1 Establish the ladder empirically — pre-trained API first

```bash
$ gcloud config set project acme-ml-prod
Updated property [core/project].

$ gcloud services enable vision.googleapis.com aiplatform.googleapis.com \
    bigquery.googleapis.com
Operation "operations/acat.p2-812446903715-3f0a1c9e-4b21-4d77-9c8e-5a1f0b7e2d31" finished successfully.

$ gcloud ml vision detect-text gs://acme-docs-inbound/invoice-88213.pdf 2>/dev/null | head -20
{
  "responses": [
    {
      "fullTextAnnotation": {
        "text": "ACME SUPPLIES LTD\nInvoice 88213\nDate 2026-08-19\nTotal EUR 4,182.50\n"
      },
      "textAnnotations": [
        {
          "description": "ACME SUPPLIES LTD",
          "locale": "en",
          "boundingPoly": {
            "vertices": [
              { "x": 118, "y": 94 },
              { "x": 612, "y": 94 },
```

> Rung 2 solved OCR in one command and zero training. Only if the *business* question is "which GL account?" — a proprietary, learned mapping — do you descend to rung 4.

### 11.2 Rung 4: BigQuery ML — train where the data already is

```bash
$ bq query --use_legacy_sql=false --format=pretty '
CREATE OR REPLACE MODEL `acme-ml-prod.ml_churn.churn_baseline`
OPTIONS(
  model_type            = "BOOSTED_TREE_CLASSIFIER",
  input_label_cols      = ["churned"],
  auto_class_weights    = TRUE,
  max_iterations        = 50,
  early_stop            = TRUE,
  data_split_method     = "AUTO_SPLIT",
  enable_global_explain = TRUE
) AS
SELECT
  tenure_days,
  monthly_spend,
  support_tickets_30d,
  region_code,
  plan_tier,
  churned
FROM `acme-ml-prod.ml_churn.training_snapshot`
WHERE snapshot_date BETWEEN "2025-09-01" AND "2026-08-31";'

Waiting on bqjob_r5c9d1e77a4b3f02_0000019a3c1d8f21_1 ... (312s) Current status: DONE
Created acme-ml-prod.ml_churn.churn_baseline

$ bq query --use_legacy_sql=false --format=pretty '
SELECT * FROM ML.EVALUATE(MODEL `acme-ml-prod.ml_churn.churn_baseline`);'

+---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
|      precision      |       recall        |      accuracy       |      f1_score       |      log_loss       |       roc_auc       |
+---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
| 0.71483920571043321 | 0.66207812338129014 | 0.89412773981004812 | 0.68744186046511627 | 0.24917338402271055 | 0.87326114820044319 |
+---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+

$ bq query --use_legacy_sql=false --format=pretty '
SELECT * FROM ML.GLOBAL_EXPLAIN(MODEL `acme-ml-prod.ml_churn.churn_baseline`)
ORDER BY attribution DESC;'

+---------------------+----------------------+
|      feature        |     attribution      |
+---------------------+----------------------+
| support_tickets_30d |  0.41182930014772385 |
| tenure_days         |  0.28840117299102846 |
| monthly_spend       |  0.19203881744012093 |
| plan_tier           |  0.07118440229417755 |
| region_code         |  0.03654630712694921 |
+---------------------+----------------------+
```

**Read this as an architect, not a data scientist.** Accuracy 0.894 looks excellent but the positive class is ~8 % — a model that always predicts "not churned" would score 0.92. The meaningful numbers are **ROC-AUC 0.873** and **recall 0.662**: you catch two of every three churners. The business question follows immediately: *what does a missed churner cost versus a wasted retention offer?* That ratio, not the F1 score, sets the decision threshold.

### 11.3 Sliced evaluation — the fairness gate, in SQL

```bash
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  region_code,
  COUNT(*) AS n,
  ROUND(AVG(CAST(churned AS INT64)), 4) AS base_rate,
  ROUND(SUM(CASE WHEN predicted_churned = 1 AND churned THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN churned THEN 1 ELSE 0 END), 0), 4) AS recall
FROM ML.PREDICT(MODEL `acme-ml-prod.ml_churn.churn_baseline`,
      (SELECT * FROM `acme-ml-prod.ml_churn.holdout_snapshot`))
GROUP BY region_code
ORDER BY recall ASC;'

+-------------+--------+-----------+--------+
| region_code |   n    | base_rate | recall |
+-------------+--------+-----------+--------+
| NORDIC      |   4182 |    0.0391 | 0.4118 |
| IBERIA      |  11907 |    0.0722 | 0.5804 |
| BENELUX     |   9341 |    0.0810 | 0.6431 |
| DACH        |  28114 |    0.0847 | 0.6902 |
| UKI         |  31776 |    0.0918 | 0.7215 |
+-------------+--------+-----------+--------+
```

The aggregate 0.662 recall conceals **0.412 in NORDIC** — under-represented in training (4,182 rows) and with a different base rate. This is an aggregation/selection bias finding, and it is a release blocker, not a footnote. Remediation: targeted data collection for NORDIC, per-region thresholds, or a region-conditioned model.

### 11.4 Registry, endpoint and progressive delivery

```bash
$ gcloud ai models list --region=europe-west4 \
    --format="table(displayName, name.basename(), versionId, createTime.date('%Y-%m-%d %H:%M'))"
DISPLAY_NAME  NAME                 VERSION_ID  CREATE_TIME
churn-gbc     8830174562931081216  3           2026-08-28 04:11
churn-gbc     8830174562931081216  2           2026-08-07 04:09
churn-gbc     8830174562931081216  1           2026-07-17 04:12

$ gcloud ai endpoints describe churn-scoring-prod --region=europe-west4 \
    --format="yaml(displayName, deployedModels[].id, deployedModels[].displayName, trafficSplit)"
deployedModels:
- displayName: churn-gbc-v2
  id: '4471029384756201984'
- displayName: churn-gbc-v3
  id: '5590318472910385664'
displayName: churn-scoring-prod
trafficSplit:
  '4471029384756201984': 90
  '5590318472910385664': 10

# Canary healthy after 24 h of monitoring — promote.
$ gcloud ai endpoints update churn-scoring-prod --region=europe-west4 \
    --traffic-split=5590318472910385664=100
Updated Vertex AI endpoint [projects/812446903715/locations/europe-west4/endpoints/churn-scoring-prod].

# Rollback is a traffic-split write, not a redeploy — seconds, not minutes.
$ gcloud ai endpoints update churn-scoring-prod --region=europe-west4 \
    --traffic-split=4471029384756201984=100
Updated Vertex AI endpoint [projects/812446903715/locations/europe-west4/endpoints/churn-scoring-prod].
```

### 11.5 Online prediction and latency verification

```bash
$ cat > /tmp/instances.json <<'EOF'
{
  "instances": [
    {"tenure_days": 412, "monthly_spend": 89.90, "support_tickets_30d": 4,
     "region_code": "IBERIA", "plan_tier": "PRO"},
    {"tenure_days": 61,  "monthly_spend": 19.00, "support_tickets_30d": 0,
     "region_code": "UKI",    "plan_tier": "BASIC"}
  ]
}
EOF

$ gcloud ai endpoints predict churn-scoring-prod \
    --region=europe-west4 --json-request=/tmp/instances.json
[[0.1183, 0.8817], [0.9642, 0.0358]]

$ ENDPOINT=$(gcloud ai endpoints describe churn-scoring-prod \
    --region=europe-west4 --format="value(name)")
$ TOKEN=$(gcloud auth print-access-token)

$ for i in $(seq 1 10); do
    curl -s -o /dev/null -w "%{time_total}\n" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d @/tmp/instances.json \
      "https://europe-west4-aiplatform.googleapis.com/v1/${ENDPOINT}:predict"
  done | sort -n | awk '{a[NR]=$1} END {printf "p50=%.3fs p90=%.3fs max=%.3fs n=%d\n", a[int(NR*0.5)], a[int(NR*0.9)], a[NR], NR}'
p50=0.043s p90=0.071s max=0.118s n=10
```

### 11.6 Model Monitoring — creation and a real drift alert

```bash
$ curl -s -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    -d @monitoring-job.json \
    "https://europe-west4-aiplatform.googleapis.com/v1/projects/acme-ml-prod/locations/europe-west4/modelDeploymentMonitoringJobs" \
  | jq -r '.name, .state'
projects/812446903715/locations/europe-west4/modelDeploymentMonitoringJobs/2277104839561216000
JOB_STATE_PENDING

$ gcloud logging read '
  resource.type="aiplatform.googleapis.com/Endpoint"
  jsonPayload.anomaly_type="feature_drift"' \
  --limit=3 --freshness=6h --format=json | jq -r '.[].jsonPayload
    | "\(.feature_display_name)  observed=\(.deviation)  threshold=\(.threshold)"'
support_tickets_30d  observed=0.3418  threshold=0.15
monthly_spend        observed=0.1922  threshold=0.10
tenure_days          observed=0.0611  threshold=0.10
```

**Interpretation.** `support_tickets_30d` — the highest-attribution feature (§11.2) — has drifted 2.3× past its threshold. Two hypotheses, and they demand opposite responses:

- *The world changed* (a product incident spiked ticket volume) → concept drift → retrain on recent data and consider a shorter retraining cadence.
- *The pipeline changed* (an upstream team altered the ticket-counting window from 30 to 7 days) → this is a **bug**, and retraining would bake it in.

Distinguish them by checking the upstream data first, always:

```bash
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  DATE_TRUNC(snapshot_date, WEEK) AS wk,
  COUNT(*) AS rows,
  ROUND(AVG(support_tickets_30d), 3) AS avg_tickets,
  ROUND(APPROX_QUANTILES(support_tickets_30d, 100)[OFFSET(99)], 3) AS p99
FROM `acme-ml-prod.ml_churn.serving_features`
WHERE snapshot_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 8 WEEK)
GROUP BY wk ORDER BY wk;'

+------------+---------+-------------+-------+
|     wk     |  rows   | avg_tickets |  p99  |
+------------+---------+-------------+-------+
| 2026-07-13 | 1041882 |       1.114 |  11.0 |
| 2026-07-20 | 1043019 |       1.098 |  11.0 |
| 2026-07-27 | 1044771 |       1.121 |  12.0 |
| 2026-08-03 | 1046203 |       1.109 |  11.0 |
| 2026-08-10 | 1047558 |       0.312 |   3.0 |   ← step change, not a trend
| 2026-08-17 | 1048901 |       0.308 |   3.0 |
| 2026-08-24 | 1050334 |       0.315 |   3.0 |
| 2026-08-31 | 1051902 |       0.311 |   3.0 |
+------------+---------+-------------+-------+
```

A **step change** on a single week with stable row counts is an upstream schema/semantics change, not organic drift. Fix the pipeline; do not retrain.

### 11.7 Generative AI on the same platform

```bash
$ gcloud ai model-garden models list --region=europe-west4 --limit=5 \
    --format="table(name, supportedActions)"
NAME                                     SUPPORTED_ACTIONS
publishers/google/models/gemini-2.5-pro   PREDICT, DEPLOY_GKE
publishers/google/models/gemini-2.5-flash PREDICT, DEPLOY_GKE
publishers/google/models/text-embedding   PREDICT
publishers/meta/models/llama-3.3          DEPLOY, DEPLOY_GKE
publishers/anthropic/models/claude        PREDICT

# Zero-shot classification, grounded, deterministic — the bootstrap path
# for a taxonomy that has no labels yet.
$ cat > /tmp/gen.json <<'EOF'
{
  "contents": [{
    "role": "user",
    "parts": [{"text": "Classify this support ticket into exactly one of: BILLING, OUTAGE, HOWTO, BUG, ACCOUNT. Reply with only the label.\n\nTicket: \"Charged twice for the August invoice, the second charge is still pending.\""}]
  }],
  "generationConfig": { "temperature": 0, "maxOutputTokens": 8, "topP": 1 }
}
EOF

$ curl -s -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" -d @/tmp/gen.json \
    "https://europe-west4-aiplatform.googleapis.com/v1/projects/acme-ml-prod/locations/europe-west4/publishers/google/models/gemini-2.5-flash:generateContent" \
  | jq -r '.candidates[0].content.parts[0].text, .usageMetadata'
BILLING
{
  "promptTokenCount": 58,
  "candidatesTokenCount": 2,
  "totalTokenCount": 60
}
```

The `usageMetadata` block is the unit-economics instrument: 60 tokens × 3 M tickets is the number that goes into the §8.3 comparison, and it is measured, not estimated.

### 11.8 Cost attribution — proving the business case

```bash
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  service.description                       AS service,
  sku.description                           AS sku,
  ROUND(SUM(cost), 2)                       AS cost_usd,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS credits
FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_01ABCD_234567_89EFGH`
WHERE DATE(usage_start_time) BETWEEN "2026-08-01" AND "2026-08-31"
  AND EXISTS (SELECT 1 FROM UNNEST(labels) l
              WHERE l.key = "workload" AND l.value = "churn-prediction")
GROUP BY service, sku
ORDER BY cost_usd DESC
LIMIT 8;'

+-------------------+------------------------------------------+----------+---------+
|      service      |                   sku                    | cost_usd | credits |
+-------------------+------------------------------------------+----------+---------+
| Vertex AI         | Online Prediction n1-standard-4 (europe) |  1284.66 |    0.00 |
| BigQuery          | Analysis (on-demand)                     |   311.42 |  -18.20 |
| Vertex AI         | Model Monitoring prediction sampling     |   146.03 |    0.00 |
| Cloud Storage     | Standard Storage EU multi-region         |    88.71 |    0.00 |
| Vertex AI         | Custom Training n1-highmem-8             |    72.19 |  -30.11 |
| Cloud Logging     | Log Ingestion                            |    41.88 |    0.00 |
| Artifact Registry | Storage                                  |    12.44 |    0.00 |
| Pub/Sub           | Message Delivery                         |     3.07 |    0.00 |
+-------------------+------------------------------------------+----------+---------+
```

**Serving is 66 % of spend; training is 3.7 %.** That single fact redirects the optimisation effort — right-size replicas, evaluate batch prediction for the non-urgent share of traffic, and stop tuning the training job. Resource labels (`local.labels` in §10.1) are what make this query possible; without them the AI workload is invisible inside the project total and the ROI case cannot be defended.

---

## 12. Verification and failure diagnosis

### 12.1 Pre-flight verification ladder

Run top-to-bottom; each rung is cheap relative to the one below it.

| # | Question | Command | Pass criterion |
|---|---|---|---|
| 1 | Are the APIs enabled? | `gcloud services list --enabled --filter="aiplatform OR bigquery"` | All present |
| 2 | Does the SA have exactly the roles it needs? | `gcloud projects get-iam-policy $P --flatten="bindings[].members" --filter="bindings.members:sa-vertex-*"` | No `roles/editor`, no `roles/owner` |
| 3 | Is training data complete/valid? | `validate_data` component (§10.2) | Zero violations |
| 4 | Is there label leakage? | AUC ≈ 1.0 is a bug, not a triumph — audit feature timestamps | AUC plausible for the domain |
| 5 | Are sliced metrics acceptable? | §11.3 query | Worst slice ≥ floor; gap ≤ max |
| 6 | Does the serving container reproduce training scores? | Score 1,000 training rows through the endpoint, diff | Max abs delta < 1e-6 |
| 7 | Does the endpoint meet the latency SLO? | §11.5 loop, then load test | p99 within budget |
| 8 | Is monitoring live and alerting? | `gcloud ai model-deployment-monitoring-jobs list` | `JOB_STATE_RUNNING` |
| 9 | Is spend attributable? | §11.8 query | Non-empty result |
| 10 | Is rollback tested? | Traffic-split flip and back in staging | < 60 s, no errors |

Rung 6 is the one teams skip and the one that catches training-serving skew before customers do.

### 12.2 Failure catalogue

| Symptom | Most likely cause | Diagnostic command | Remediation |
|---|---|---|---|
| High offline accuracy, poor production results | **Training-serving skew** | Rung 6 above; compare feature distributions train vs serving logs | Unify feature computation; move preprocessing into the model artifact |
| AUC ≈ 0.99 in eval | **Label leakage** — a feature encodes the future | Inspect `ML.GLOBAL_EXPLAIN`; check timestamps of every feature vs prediction time | Remove leaking feature; enforce point-in-time joins |
| Accuracy decays gradually over weeks | **Concept drift** | Monitoring drift metrics; sliced accuracy over time | Shorten retraining cadence; add recency weighting |
| Accuracy drops as a step on one day | **Upstream pipeline change** | §11.6 weekly aggregate query | Fix upstream; do NOT retrain until fixed |
| Endpoint p99 spikes, p50 flat | Cold replicas / autoscale lag / GC pauses | `gcloud logging read` on endpoint; replica count metric | Raise `minReplicaCount`; pre-warm; tune concurrency target |
| Endpoint returns 429 | Quota or replica saturation | `gcloud ai endpoints describe`; Monitoring `replica_count` | Raise `maxReplicaCount`; request quota; add batching |
| Training job OOM-kills | Loading full dataset into memory | Job logs; peak memory metric | Stream/shard the data; larger `highmem` machine; reduce batch size |
| Accelerator utilisation < 30 % | **Input pipeline starvation** | TensorBoard profiler; `tf.data` metrics | Prefetch, parallel interleave, cache; store data in the same region |
| GPU quota errors on job submit | Regional accelerator quota | `gcloud compute regions describe $R --format="value(quotas)"` | Request quota; try another region; use DWS/Spot |
| Model deploy fails, container never ready | Health-check path or container contract mismatch | Endpoint deploy logs; run the container locally | Implement `/health` and `/predict` per the Vertex contract |
| Pipeline reuses a stale result | KFP caching on a data-dependent step | Check step's cache attribution in the run graph | `set_caching_options(False)` on data-reading steps |
| Provenance audit fails | Model uploaded outside the pipeline | Model Registry lineage | Prohibit manual upload with IAM; pipeline SA is the only writer |
| LLM answers confidently wrong | **No grounding** | Inspect whether retrieval returned anything | Add RAG/grounding; return citations; lower temperature; add abstention path |
| LLM cost 5× forecast | Prompt bloat / no caching / oversized model | `usageMetadata` per call, aggregated | Compress prompt, cache the shared context, route easy cases to a smaller model, batch |
| Agent takes an unsafe action | Prompt injection via retrieved content | Full tool-call audit log | Never grant tool authority from retrieved text; whitelist tools; require confirmation for writes |
| Fairness gate passes, regulator objects | Aggregate-only evaluation | Sliced metrics (§11.3) | Add protected-slice gates to the pipeline; publish a Model Card |

### 12.3 Runbook — "the model is wrong in production"

```
1. SCOPE      Is it all traffic or a slice? Query prediction logs grouped by
              slice keys. A slice-local failure is almost always data.

2. FRESHNESS  When did the feature pipeline last succeed?
              Stale features are the #1 cause. Check the Dataflow/scheduled
              query watermark before anything else.

3. IDENTITY   Which model version is serving?
              gcloud ai endpoints describe ... --format="yaml(trafficSplit)"
              Confirm it matches what the change log says.

4. SKEW       Replay 1,000 training rows through the live endpoint.
              Any delta > 1e-6 is a serving-path bug — stop here and fix it.

5. DRIFT      Compare live feature distributions to the training baseline.
              Step change → upstream bug. Gradual → concept drift.

6. MITIGATE   Roll back traffic split to the last known-good version.
              This is a seconds-long operation; do it before root-causing.

7. GROUND     Only after the above: retrain. Retraining on unfixed bad data
              converts a transient incident into a permanent regression.

8. POSTMORTEM Add the failure signal as a pipeline gate. Every ML incident
              should end with one new automated data or evaluation test.
```

---

## 13. Exam quick-recall

| Prompt in the question | Correct answer |
|---|---|
| "No ML expertise, needs it next week, generic task" | Pre-trained API |
| "No ML expertise, proprietary labeled data" | AutoML or BigQuery ML |
| "Data already in BigQuery, SQL-fluent analysts" | BigQuery ML |
| "Summarise / draft / converse / generate" | Gemini on Vertex AI |
| "Answers must come from *our* documents and cite them" | Grounding / RAG (Vertex AI Search) |
| "Wrong tone / wrong output format, facts are fine" | Fine-tuning |
| "Facts are stale" | RAG, **not** fine-tuning |
| "Model was fine, now degrading" | Drift → monitoring + retraining |
| "Great in testing, bad in production" | Training-serving skew |
| "Unified platform for the whole ML lifecycle" | Vertex AI |
| "Ensure the model does not disadvantage a group" | Responsible AI: sliced evaluation, bias mitigation, human oversight |
| "Reduce cost of scoring millions of rows nightly" | Batch prediction |
| "Which metric shows business value?" | The operational/financial KPI, never the model metric |
| "AI needs good data first" | Data governance, quality, labeling — the prerequisite |

---

## 14. References

**Exam and certification**
- Cloud Digital Leader exam guide (PDF) — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification page — https://cloud.google.com/learn/certification/cloud-digital-leader

**Core AI/ML platform**
- Vertex AI documentation — https://cloud.google.com/vertex-ai/docs
- Vertex AI Model Garden — https://cloud.google.com/vertex-ai/docs/start/explore-models
- Vertex AI Pipelines — https://cloud.google.com/vertex-ai/docs/pipelines/introduction
- Vertex AI Model Registry — https://cloud.google.com/vertex-ai/docs/model-registry/introduction
- Vertex AI Model Monitoring — https://cloud.google.com/vertex-ai/docs/model-monitoring/overview
- Vertex AI Feature Store — https://cloud.google.com/vertex-ai/docs/featurestore/latest/overview
- Vertex Explainable AI — https://cloud.google.com/vertex-ai/docs/explainable-ai/overview
- Vertex AI online prediction — https://cloud.google.com/vertex-ai/docs/predictions/get-online-predictions
- Vertex AI batch prediction — https://cloud.google.com/vertex-ai/docs/predictions/get-batch-predictions

**Generative AI**
- Generative AI on Vertex AI — https://cloud.google.com/vertex-ai/generative-ai/docs/learn/overview
- Grounding overview — https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview
- Vertex AI RAG Engine — https://cloud.google.com/vertex-ai/generative-ai/docs/rag-overview
- Model tuning — https://cloud.google.com/vertex-ai/generative-ai/docs/models/tune-models
- Vertex AI Agent Builder — https://cloud.google.com/products/agent-builder
- Prompt design strategies — https://cloud.google.com/vertex-ai/generative-ai/docs/learn/prompt-design-strategies

**Low-code / data-resident ML**
- BigQuery ML introduction — https://cloud.google.com/bigquery/docs/bqml-introduction
- BigQuery ML `CREATE MODEL` syntax — https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create
- AutoML on Vertex AI — https://cloud.google.com/vertex-ai/docs/training-overview

**Pre-trained APIs**
- Cloud Vision API — https://cloud.google.com/vision/docs
- Cloud Natural Language API — https://cloud.google.com/natural-language/docs
- Speech-to-Text — https://cloud.google.com/speech-to-text/docs
- Cloud Translation — https://cloud.google.com/translate/docs
- Document AI — https://cloud.google.com/document-ai/docs
- Contact Center AI — https://cloud.google.com/solutions/contact-center

**MLOps and architecture guidance**
- MLOps: continuous delivery and automation pipelines in ML — https://cloud.google.com/architecture/mlops-continuous-delivery-and-automation-pipelines-in-machine-learning
- Practitioners guide to MLOps (whitepaper) — https://services.google.com/fh/files/misc/practitioners_guide_to_mlops_whitepaper.pdf
- Architecture Framework: AI and ML perspective — https://cloud.google.com/architecture/framework/perspectives/ai-ml
- Rules of Machine Learning (Google) — https://developers.google.com/machine-learning/guides/rules-of-ml
- Hidden Technical Debt in Machine Learning Systems (Sculley et al., NeurIPS 2015) — https://papers.nips.cc/paper_files/paper/2015/file/86df7dcfd896fcaf2674f757a2463eba-Paper.pdf

**Data foundation and governance**
- Dataplex Universal Catalog — https://cloud.google.com/dataplex/docs
- Sensitive Data Protection (Cloud DLP) — https://cloud.google.com/sensitive-data-protection/docs
- VPC Service Controls — https://cloud.google.com/vpc-service-controls/docs/overview
- CMEK — https://cloud.google.com/kms/docs/cmek

**Responsible AI**
- Google AI Principles — https://ai.google/responsibility/principles/
- Responsible AI on Vertex AI — https://cloud.google.com/vertex-ai/generative-ai/docs/learn/responsible-ai
- People + AI Guidebook — https://pair.withgoogle.com/guidebook/
- Model Cards — https://modelcards.withgoogle.com/about
- Secure AI Framework (SAIF) — https://saif.google/

**Compute and cost**
- Cloud TPU documentation — https://cloud.google.com/tpu/docs
- GPUs on Google Cloud — https://cloud.google.com/compute/docs/gpus
- Vertex AI pricing — https://cloud.google.com/vertex-ai/pricing
- BigQuery pricing — https://cloud.google.com/bigquery/pricing
- Dynamic Workload Scheduler — https://cloud.google.com/blog/products/compute/introducing-dynamic-workload-scheduler

**Serving on Kubernetes**
- KServe documentation — https://kserve.github.io/website/
- AI/ML orchestration on GKE — https://cloud.google.com/kubernetes-engine/docs/integrations/ai-infra