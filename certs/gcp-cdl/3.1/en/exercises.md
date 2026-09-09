# gcp-cdl · Topic 3.1 — Guided Exercises

## Describe fundamental AI and ML concepts and how they create business value

**Exam:** Google Cloud Digital Leader (version 2026-08-12) · **Domain weight:** 9.0%
**Official objective source:** <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>

---

### Why a *leader* exam gets a *hands-on* lab

The Cloud Digital Leader exam is scenario- and vocabulary-driven, not command-driven. You will never be asked to write SQL on the exam. But the failure mode of studying this domain from slides is that "training", "inference", "grounding", "data quality" and "business value" stay abstract — and the exam distractors are built precisely on the boundary between them ("train a custom model" vs. "call a pre-trained API" vs. "prompt a foundation model with grounding").

These exercises make each concept **observable**: you will train a model and watch it cost money once and predict cheaply forever; you will corrupt a dataset and watch the business metric collapse while accuracy stays high; you will make a foundation model hallucinate and then ground it. The commands are the scaffolding — the exam-relevant output is the vocabulary and the decision rules.

Steps marked **[CORE]** map directly to exam objectives. Steps marked **[DEPTH]** are production context that make the CORE concepts stick; skip them if you are short on time, but do read their checkpoint questions.

---

### Prerequisites

| Requirement | Check |
|---|---|
| Google Cloud project with **billing enabled** | `gcloud beta billing projects describe $PROJECT_ID` |
| `gcloud` CLI ≥ 470 and `bq` | `gcloud version` |
| IAM roles on the project | `roles/bigquery.admin`, `roles/aiplatform.user`, `roles/serviceusage.serviceUsageAdmin`, `roles/resourcemanager.projectIamAdmin` |
| Budget | **< USD 2** if you follow the steps as written and complete Exercise 9 (cleanup). The lab deliberately avoids AutoML and custom training, which are the expensive surfaces. |

> **Cost discipline is itself part of this domain.** Every step that spends money states what it spends and why. Before you run anything, set a budget alert: <https://cloud.google.com/billing/docs/how-to/budgets>

> **Naming churn warning.** Google ships model IDs and CLI surfaces faster than any courseware can track. If a model name or `gcloud` subcommand in this lab is rejected, run `gcloud components update` and take the current name from the Model Garden reference: <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/models>. The *concepts* are stable; the *identifiers* are not. That distinction is worth internalizing before the exam, which tests the former.

---

## Exercise 1 — Bootstrap and the AI taxonomy **[CORE]**

**Goal:** Establish the environment and materialize the nesting AI ⊃ ML ⊃ Deep Learning ⊃ Generative AI, which is the single most-tested concept in this objective.

### Steps

1. Export the variables every later exercise reuses:

    ```bash
    export PROJECT_ID="$(gcloud config get-value project)"
    export LOCATION="us-central1"
    export BQ_LOCATION="US"
    export DATASET="cdl_ai_lab"
    export GEN_MODEL="gemini-2.5-flash"
    export EMB_MODEL="text-embedding-005"
    echo "project=$PROJECT_ID region=$LOCATION"
    ```

2. Enable exactly the APIs this lab needs. Note that **enabling an API costs nothing** — you pay for calls, not for availability. This is a recurring CDL theme.

    ```bash
    gcloud services enable \
      aiplatform.googleapis.com \
      bigquery.googleapis.com \
      bigqueryconnection.googleapis.com \
      language.googleapis.com \
      --project="$PROJECT_ID"
    ```

3. Confirm they are active:

    ```bash
    gcloud services list --enabled --project="$PROJECT_ID" \
      --filter="config.name~(aiplatform|bigquery|language)" \
      --format="table(config.name, config.title)"
    ```

    Expected output (abridged):

    ```
    NAME                              TITLE
    aiplatform.googleapis.com         Vertex AI API
    bigquery.googleapis.com           BigQuery API
    bigqueryconnection.googleapis.com BigQuery Connection API
    language.googleapis.com           Cloud Natural Language API
    ```

4. Create the working dataset. `--location` is immutable after creation and must match the location of any table you join against:

    ```bash
    bq --location="$BQ_LOCATION" mk --dataset \
      --description="CDL 3.1 guided exercises - safe to delete" \
      "${PROJECT_ID}:${DATASET}"
    ```

5. Look at the model catalogue. Model Garden is the concrete answer to "where do foundation models come from on Google Cloud":

    ```bash
    gcloud ai model-garden models list --limit=15 2>/dev/null \
      || echo "CLI surface unavailable - use the console: https://console.cloud.google.com/vertex-ai/model-garden"
    ```

    You should see a mix of Google first-party models (`google/gemini-*`, `google/imagen-*`), open-weights models (`meta/llama*`, `mistral-ai/*`) and partner models. **The catalogue itself is the teaching point:** Google Cloud's positioning is that you rent the model, you do not have to build it.

6. Fix the taxonomy in your own words before continuing. Write this table out by hand — do not just read it:

    | Layer | Definition | Distinguishing property | Google Cloud surface |
    |---|---|---|---|
    | **Artificial Intelligence** | Any system performing tasks that normally require human intelligence | The umbrella; includes hand-written rule engines with no learning at all | — |
    | **Machine Learning** | Systems that *learn a function from data* instead of being explicitly programmed | Behaviour is derived from examples, not from code | BigQuery ML, Vertex AI training |
    | **Deep Learning** | ML using multi-layer neural networks | Learns its own feature representations from raw data | Vertex AI custom training, GPUs/TPUs |
    | **Generative AI** | Deep learning models that produce *new* content (text, image, audio, code) | Output is generated content, not a label or a number | Gemini, Imagen, Veo via Vertex AI |
    | **Foundation model / LLM** | A very large model pre-trained on broad data, adaptable to many tasks | Task-agnostic pre-training + task-specific adaptation | Model Garden, Vertex AI |

> **Sources:** Vertex AI overview <https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform> · Model Garden <https://cloud.google.com/vertex-ai/generative-ai/docs/model-garden/explore-models> · Google ML glossary <https://developers.google.com/machine-learning/glossary>

### Checkpoint 1

- **Q1.1** A logistics company runs a dispatch system consisting of 4,000 hand-written `if/then` rules maintained by domain experts. Is this AI? Is it ML? Justify with one sentence.
- **Q1.2** Why is generative AI drawn *inside* deep learning rather than beside it?
- **Q1.3** Your CFO asks: "We enabled the Vertex AI API last quarter and used nothing. What did that cost?" Answer, and state the general Google Cloud pricing principle it illustrates.
- **Q1.4** In one sentence, what makes a model a *foundation* model, as opposed to a large model?

---

## Exercise 2 — Data: structured vs. unstructured, and the label **[CORE]**

**Goal:** See with your own eyes the two data shapes the exam distinguishes, and identify the *label* — the concept that separates supervised learning from everything else.

### Steps

1. Inspect a **structured** dataset. Structure means: fixed schema, typed columns, rows are records.

    ```bash
    bq show --schema --format=prettyjson \
      bigquery-public-data:ml_datasets.census_adult_income | head -40
    ```

    Expected output (abridged):

    ```json
    [
      { "name": "age", "type": "INTEGER" },
      { "name": "workclass", "type": "STRING" },
      { "name": "functional_weight", "type": "INTEGER" },
      { "name": "education", "type": "STRING" },
      { "name": "education_num", "type": "INTEGER" },
      { "name": "marital_status", "type": "STRING" },
      { "name": "occupation", "type": "STRING" },
      { "name": "relationship", "type": "STRING" },
      { "name": "race", "type": "STRING" },
      { "name": "sex", "type": "STRING" },
      { "name": "capital_gain", "type": "INTEGER" },
      { "name": "capital_loss", "type": "INTEGER" },
      { "name": "hours_per_week", "type": "INTEGER" },
      { "name": "native_country", "type": "STRING" },
      { "name": "income_bracket", "type": "STRING" }
    ]
    ```

2. Look at the actual rows and the class balance of the column we will predict:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      income_bracket,
      COUNT(*) AS rows,
      ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
    FROM `bigquery-public-data.ml_datasets.census_adult_income`
    GROUP BY income_bracket
    ORDER BY rows DESC'
    ```

    Expected output:

    ```
    +----------------+-------+-------+
    | income_bracket | rows  |  pct  |
    +----------------+-------+-------+
    |  <=50K         | 24720 | 75.92 |
    |  >50K          |  7841 | 24.08 |
    +----------------+-------+-------+
    ```

    Two things just happened, and both matter. First, `income_bracket` is the **label**: the thing we want the model to predict for rows where we do not know it. Every other column is a **feature**. Second, look closely at the values — they carry a **leading space** (`" <=50K"`). That is a real, unannounced data-quality defect in a widely used public dataset, and it will silently break any `WHERE income_bracket = '>50K'` filter you write. Exercise 4 is about exactly this class of problem.

3. Now the **unstructured** shape. Send free text to a pre-trained API and observe that the input has no schema at all:

    ```bash
    gcloud ml language analyze-sentiment \
      --content="The onboarding flow was confusing and I nearly gave up, but support fixed it in four minutes and I would still recommend you." \
      --format=json | head -30
    ```

    Expected output (abridged):

    ```json
    {
      "documentSentiment": { "magnitude": 1.6, "score": 0.1 },
      "language": "en",
      "sentences": [
        {
          "sentiment": { "magnitude": 0.8, "score": -0.8 },
          "text": { "beginOffset": 0, "content": "The onboarding flow was confusing and I nearly gave up," }
        },
        {
          "sentiment": { "magnitude": 0.8, "score": 0.8 },
          "text": { "beginOffset": 55, "content": "but support fixed it in four minutes and I would still recommend you." }
        }
      ]
    }
    ```

    Read the two numbers carefully. `score` runs −1.0 (negative) to +1.0 (positive); `magnitude` is unbounded and measures *emotional intensity*. A document score near **0.1 with magnitude 1.6** does not mean "neutral, nobody cared" — it means "strongly mixed": a very negative sentence and a very positive sentence cancelling out. Reporting document score alone to a business stakeholder would be actively misleading. This is a small, concrete instance of the most important lesson in the whole domain: **a model output is a number, and turning it into a decision is a human design choice.**

4. **[DEPTH]** Confirm you did not train anything in step 3:

    ```bash
    bq ls "${PROJECT_ID}:${DATASET}"
    ```

    Expected output:

    ```
    (empty)
    ```

    You just did production-grade NLP with zero training data, zero model artifacts and zero ML expertise. That is the value proposition of a pre-trained API, and it is the correct exam answer whenever a scenario says "common task, no unique data, needs to ship fast".

> **Sources:** Natural Language sentiment <https://cloud.google.com/natural-language/docs/analyzing-sentiment> · BigQuery public datasets <https://cloud.google.com/bigquery/public-data>

### Checkpoint 2

- **Q2.1** Classify each as structured or unstructured: (a) a Cloud SQL `orders` table; (b) 40,000 scanned PDF invoices; (c) a JSON log stream with a consistent schema; (d) call-centre audio recordings.
- **Q2.2** In step 2 you found the label. If the dataset had *no* `income_bracket` column, which category of ML could you still apply, and what would it produce?
- **Q2.3** The class balance is roughly 76/24. A colleague proposes a model that always predicts `<=50K`. What accuracy does it achieve, and why is that number dangerous?
- **Q2.4** Rewrite the sentiment result of step 3 as a one-line summary for a product manager that does not mislead them.
- **Q2.5** Which product would you name for (b) in Q2.1 — 40,000 scanned invoices where the business wants line-item totals extracted — and why not a general-purpose foundation model?

---

## Exercise 3 — Training vs. inference: the cost asymmetry **[CORE]**

**Goal:** Train a real supervised classification model, then run inference with it, and measure the difference. The exam repeatedly tests that these are separate phases with separate cost profiles.

> **Cost:** the `CREATE MODEL` statement below scans roughly 4 MB. BigQuery's on-demand free tier covers 1 TiB of query processing per month, so this is effectively free. Verify at <https://cloud.google.com/bigquery/pricing>.

### Steps

1. Train a logistic regression model. Read the options block before running it — every option is a design decision a leader should be able to name:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE MODEL `'"${DATASET}"'.income_logreg`
    OPTIONS (
      model_type            = "LOGISTIC_REG",
      input_label_cols      = ["income_over_50k"],
      auto_class_weights    = TRUE,
      data_split_method     = "RANDOM",
      data_split_eval_fraction = 0.20,
      enable_global_explain = TRUE
    ) AS
    SELECT
      age,
      workclass,
      education_num,
      marital_status,
      occupation,
      relationship,
      hours_per_week,
      native_country,
      IF(TRIM(income_bracket) = ">50K", 1, 0) AS income_over_50k
    FROM `bigquery-public-data.ml_datasets.census_adult_income`
    WHERE age IS NOT NULL'
    ```

    Note four things:
    - `TRIM(...)` — we defused the leading-space defect found in Exercise 2.
    - `auto_class_weights = TRUE` — compensates for the 76/24 imbalance so the minority class is not ignored.
    - `data_split_eval_fraction = 0.20` — 20% of rows are **held out** and never seen during training. Evaluating on data the model trained on measures memorization, not learning.
    - We deliberately excluded `race` and `sex`. Hold that thought until Exercise 8.

    Expected output:

    ```
    Waiting on bqjob_r3f8a2c1d0e94b7f_00000193c2a1_1 ... (18s) Current status: DONE
    ```

2. Inspect the trained artifact — training produced a *thing* that now exists:

    ```bash
    bq show --format=prettyjson "${PROJECT_ID}:${DATASET}.income_logreg" \
      | grep -E '"(modelType|creationTime|trainingRuns|location)"' | head
    bq ls --models "${PROJECT_ID}:${DATASET}"
    ```

    Expected output:

    ```
                 Id              Model Type      Labels   Creation Time
     ----------------------- ----------------- -------- -----------------
      income_logreg           LOGISTIC_REGRESSION        07 Sep 09:14:22
    ```

3. Evaluate on the held-out split:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      ROUND(accuracy, 4)  AS accuracy,
      ROUND(precision, 4) AS precision,
      ROUND(recall, 4)    AS recall,
      ROUND(f1_score, 4)  AS f1,
      ROUND(roc_auc, 4)   AS roc_auc,
      ROUND(log_loss, 4)  AS log_loss
    FROM ML.EVALUATE(MODEL `'"${DATASET}"'.income_logreg`)'
    ```

    Expected output (your numbers will differ slightly — the split is random):

    ```
    +----------+-----------+--------+--------+---------+----------+
    | accuracy | precision | recall |   f1   | roc_auc | log_loss |
    +----------+-----------+--------+--------+---------+----------+
    |   0.8003 |    0.5468 | 0.8412 | 0.6627 |  0.8934 |   0.4327 |
    +----------+-----------+--------+--------+---------+----------+
    ```

    Accuracy 0.80 against a 0.76 baseline looks unimpressive. **ROC AUC 0.89 is the honest headline**: it says the model ranks a random high earner above a random low earner 89% of the time, independent of any threshold. Precision 0.55 with recall 0.84 tells you `auto_class_weights` did its job — the model casts a wide net, catching 84% of true high earners at the price of nearly half its positive calls being wrong. Whether that trade is good depends entirely on economics you have not specified yet. Exercise 5 specifies them.

4. See where the errors actually are:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT * FROM ML.CONFUSION_MATRIX(MODEL `'"${DATASET}"'.income_logreg`)'
    ```

    Expected output:

    ```
    +----------------+------+------+
    | expected_label |  _0  |  _1  |
    +----------------+------+------+
    | 0              | 3866 | 1080 |
    | 1              |  249 | 1318 |
    +----------------+------+------+
    ```

    Read it as a 2×2: rows are truth, columns are prediction. **1318** true positives, **1080** false positives, **249** false negatives, **3866** true negatives.

5. Now run **inference** on rows the model has never seen, and time it:

    ```bash
    time bq query --use_legacy_sql=false --format=pretty '
    SELECT
      age, occupation, hours_per_week,
      predicted_income_over_50k AS prediction,
      ROUND((SELECT p.prob FROM UNNEST(predicted_income_over_50k_probs) p
             WHERE p.label = 1), 4) AS prob_over_50k
    FROM ML.PREDICT(MODEL `'"${DATASET}"'.income_logreg`, (
      SELECT 44 AS age, " Private" AS workclass, 13 AS education_num,
             " Married-civ-spouse" AS marital_status, " Exec-managerial" AS occupation,
             " Husband" AS relationship, 50 AS hours_per_week, " United-States" AS native_country
      UNION ALL
      SELECT 22, " Private", 9, " Never-married", " Handlers-cleaners",
             " Own-child", 20, " United-States"))'
    ```

    Expected output:

    ```
    +-----+--------------------+----------------+------------+---------------+
    | age |     occupation     | hours_per_week | prediction | prob_over_50k |
    +-----+--------------------+----------------+------------+---------------+
    |  44 |  Exec-managerial   |             50 |          1 |        0.9127 |
    |  22 |  Handlers-cleaners |             20 |          0 |        0.0143 |
    +-----+--------------------+----------------+------------+---------------+

    real    0m2.417s
    ```

    **This is the asymmetry.** Training read 32,561 rows, ran an optimization loop, and produced a persistent artifact. Inference read two rows and did arithmetic against the stored weights. Training is *episodic, expensive, and produces an asset*. Inference is *continuous, cheap per call, and produces a decision* — but it runs millions of times, so it usually dominates lifetime cost anyway.

6. **[DEPTH]** Ask the model what it learned:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT feature, ROUND(attribution, 4) AS attribution
    FROM ML.GLOBAL_EXPLAIN(MODEL `'"${DATASET}"'.income_logreg`)
    ORDER BY ABS(attribution) DESC LIMIT 6'
    ```

    Expected output:

    ```
    +----------------+-------------+
    |    feature     | attribution |
    +----------------+-------------+
    | marital_status |      0.9312 |
    | education_num  |      0.6104 |
    | occupation     |      0.5877 |
    | age            |      0.4221 |
    | hours_per_week |      0.3915 |
    | relationship   |      0.3402 |
    +----------------+-------------+
    ```

    `marital_status` outranking `education_num` should make you uncomfortable, and that discomfort is the point. **Explainability is not a nice-to-have; it is how you discover that your model has learned a proxy for something you did not intend to use.**

> **Sources:** `CREATE MODEL` for GLM <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create-glm> · `ML.EVALUATE` <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-evaluate> · `ML.CONFUSION_MATRIX` <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-confusion> · BQML introduction <https://cloud.google.com/bigquery/docs/bqml-introduction>

### Checkpoint 3

- **Q3.1** State the difference between training and inference in one sentence each, then explain why the cost profiles differ in *shape*, not just magnitude.
- **Q3.2** Why is the 20% held-out split non-negotiable? Name the failure it prevents.
- **Q3.3** From the confusion matrix, compute precision and recall by hand and confirm they match `ML.EVALUATE`.
- **Q3.4** Accuracy is 0.80 and the always-predict-`<=50K` baseline is 0.76. Argue that this model is nevertheless valuable, using a metric from step 3.
- **Q3.5** What does `enable_global_explain` buy a *regulated* business, beyond curiosity?
- **Q3.6** A stakeholder says: "The model is trained, so our AI costs are behind us." Correct them.

---

## Exercise 4 — Data quality: the constraint that actually decides the outcome **[CORE]**

**Goal:** Prove empirically that model quality is bounded by data quality, and learn the dimensions Google Cloud uses to describe it. This is the highest-yield exercise in the whole topic.

### Steps

1. Profile the source data across the standard quality dimensions before trusting it:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      COUNT(*)                                                    AS total_rows,
      COUNTIF(TRIM(occupation) = "?")                             AS occupation_unknown,
      COUNTIF(TRIM(workclass)  = "?")                             AS workclass_unknown,
      COUNTIF(TRIM(native_country) = "?")                         AS country_unknown,
      COUNTIF(age IS NULL)                                        AS age_null,
      COUNTIF(age < 17 OR age > 90)                               AS age_out_of_range,
      COUNTIF(hours_per_week > 90)                                AS implausible_hours,
      COUNT(DISTINCT FORMAT("%t", (age, occupation, education_num,
            hours_per_week, marital_status)))                     AS distinct_profiles
    FROM `bigquery-public-data.ml_datasets.census_adult_income`'
    ```

    Expected output:

    ```
    +------------+--------------------+-------------------+-----------------+----------+------------------+-------------------+-------------------+
    | total_rows | occupation_unknown | workclass_unknown | country_unknown | age_null | age_out_of_range | implausible_hours | distinct_profiles |
    +------------+--------------------+-------------------+-----------------+----------+------------------+-------------------+-------------------+
    |      32561 |               1843 |              1836 |             583 |        0 |                0 |               340 |             25794 |
    +------------+--------------------+-------------------+-----------------+----------+------------------+-------------------+-------------------+
    ```

    Note that `"?"` is a **missing value disguised as a present one**. `COUNTIF(occupation IS NULL)` returns 0 and every naïve completeness check passes, while 5.7% of the column is actually absent. Missingness that hides from `IS NULL` is the single most common data-quality defect in real pipelines.

2. Map what you measured onto the dimensions Google Cloud's data-quality tooling uses (Dataplex auto data quality):

    | Dimension | Question it asks | Your finding above |
    |---|---|---|
    | **Completeness** | Are required values present? | 1,843 sentinel `"?"` occupations — fails, invisibly |
    | **Validity** | Do values conform to the allowed domain/format? | Leading whitespace on every categorical; 340 rows > 90 h/week |
    | **Accuracy** | Do values match the real world? | Not testable from inside the data — needs an external reference |
    | **Consistency** | Do related values agree across systems? | Not testable here — single table |
    | **Uniqueness** | Are there unintended duplicates? | 25,794 distinct profiles from 32,561 rows |
    | **Timeliness / freshness** | Is the data recent enough to be true *now*? | 1994 census extract — **stale by three decades** |

    Look hard at the last row. This dataset is used everywhere as a teaching corpus, and every model trained on it is a model of the **1994** United States labour market. It would be indefensible in production for any decision about a person today. *Freshness is a data-quality dimension, and stale data produces a model that is confidently, precisely wrong.*

3. Now demonstrate the causal link. Deliberately damage the data and retrain. First build a corrupted copy where 60% of `education_num` values are destroyed:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE TABLE `'"${DATASET}"'.census_degraded` AS
    SELECT
      age, workclass,
      IF(MOD(ABS(FARM_FINGERPRINT(FORMAT("%t", (age, occupation, hours_per_week)))), 10) < 6,
         NULL, education_num) AS education_num,
      marital_status, occupation, relationship, hours_per_week, native_country,
      IF(TRIM(income_bracket) = ">50K", 1, 0) AS income_over_50k
    FROM `bigquery-public-data.ml_datasets.census_adult_income`
    WHERE age IS NOT NULL'
    ```

4. Retrain on the degraded data with **identical** options:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE MODEL `'"${DATASET}"'.income_degraded`
    OPTIONS (
      model_type            = "LOGISTIC_REG",
      input_label_cols      = ["income_over_50k"],
      auto_class_weights    = TRUE,
      data_split_method     = "RANDOM",
      data_split_eval_fraction = 0.20
    ) AS SELECT * FROM `'"${DATASET}"'.census_degraded`'
    ```

5. Compare the two models side by side:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT "clean" AS dataset, ROUND(roc_auc,4) AS roc_auc, ROUND(accuracy,4) AS accuracy,
           ROUND(precision,4) AS precision, ROUND(recall,4) AS recall
    FROM ML.EVALUATE(MODEL `'"${DATASET}"'.income_logreg`)
    UNION ALL
    SELECT "degraded", ROUND(roc_auc,4), ROUND(accuracy,4),
           ROUND(precision,4), ROUND(recall,4)
    FROM ML.EVALUATE(MODEL `'"${DATASET}"'.income_degraded`)'
    ```

    Expected output:

    ```
    +----------+---------+----------+-----------+--------+
    | dataset  | roc_auc | accuracy | precision | recall |
    +----------+---------+----------+-----------+--------+
    | clean    |  0.8934 |   0.8003 |    0.5468 | 0.8412 |
    | degraded |  0.8571 |   0.7784 |    0.5140 | 0.8206 |
    +----------+---------+----------+-----------+--------+
    ```

    Same algorithm, same hyperparameters, same code, same compute — **and a worse model**, because the input was worse. No amount of model tuning recovers information that is not in the data. This is what "garbage in, garbage out" means quantitatively, and it is why the exam guide places data quality inside the AI objective rather than beside it.

6. **[DEPTH]** Now the subtler and more dangerous failure — **data leakage**. Train a model that includes a feature which would not exist at prediction time:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE MODEL `'"${DATASET}"'.income_leaky`
    OPTIONS (model_type="LOGISTIC_REG", input_label_cols=["income_over_50k"],
             data_split_method="RANDOM", data_split_eval_fraction=0.20) AS
    SELECT
      age, education_num, hours_per_week,
      capital_gain,
      IF(TRIM(income_bracket) = ">50K", 1, 0) AS income_over_50k,
      IF(TRIM(income_bracket) = ">50K", 1, 0) AS tax_bracket_filed
    FROM `bigquery-public-data.ml_datasets.census_adult_income`'

    bq query --use_legacy_sql=false --format=pretty '
    SELECT ROUND(roc_auc,4) AS roc_auc, ROUND(accuracy,4) AS accuracy
    FROM ML.EVALUATE(MODEL `'"${DATASET}"'.income_leaky`)'
    ```

    Expected output:

    ```
    +---------+----------+
    | roc_auc | accuracy |
    +---------+----------+
    |     1.0 |      1.0 |
    +---------+----------+
    ```

    A perfect model. It is also completely worthless: `tax_bracket_filed` is a copy of the answer, and in production it would not be known until *after* the moment you needed the prediction. **A suspiciously perfect evaluation metric is a bug report, not a success report.** Leakage is the reason offline results and production results diverge, and it is caught by asking one question about every feature: *would this value actually be available, with this content, at the instant the prediction is needed?*

> **Sources:** Dataplex auto data quality <https://cloud.google.com/dataplex/docs/auto-data-quality-overview> · Data quality dimensions <https://cloud.google.com/dataplex/docs/data-quality-overview>

### Checkpoint 4

- **Q4.1** Why did `COUNTIF(occupation IS NULL)` return 0 while 1,843 values were genuinely missing? What does this teach about automated quality checks?
- **Q4.2** Which quality dimension does the 1994 vintage of this dataset violate, and why is it the most dangerous one for a *business* decision?
- **Q4.3** In step 5 the degraded model lost ~0.036 ROC AUC. Explain to a non-technical executive why "just use a better algorithm" does not recover it.
- **Q4.4** Your team reports a fraud model with 99.98% accuracy on a dataset where 0.02% of transactions are fraudulent. Give two distinct explanations, one benign and one alarming.
- **Q4.5** Define data leakage in one sentence, and give the single test question that detects it.
- **Q4.6** The clean model's top feature was `marital_status`. Name one business risk this creates that a purely statistical review would not surface.

---

## Exercise 5 — Turning a model into money: threshold economics **[CORE]**

**Goal:** This is the "how they create business value" half of the objective, and it is the part most candidates skip. A model outputs a probability. **A business outcome requires a threshold, and the threshold is set by economics, not by the data scientist.**

### Scenario

A financial-services firm uses the model to select prospects for a premium advisory product.

| Event | Meaning | Value |
|---|---|---|
| **True positive** | Model says high-earner, they are → campaign converts | **+ USD 180** margin |
| **False positive** | Model says high-earner, they are not → wasted outreach | **− USD 25** cost |
| **False negative** | Model says no, they were → opportunity lost | **− USD 40** attributed |
| **True negative** | Correctly skipped | **USD 0** |

### Steps

1. Score the evaluation population once, keeping the raw probability rather than the 0/1 decision:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE TABLE `'"${DATASET}"'.scored` AS
    SELECT
      income_over_50k AS actual,
      (SELECT p.prob FROM UNNEST(predicted_income_over_50k_probs) p
       WHERE p.label = 1) AS prob_positive
    FROM ML.PREDICT(MODEL `'"${DATASET}"'.income_logreg`, (
      SELECT age, workclass, education_num, marital_status, occupation,
             relationship, hours_per_week, native_country,
             IF(TRIM(income_bracket) = ">50K", 1, 0) AS income_over_50k
      FROM `bigquery-public-data.ml_datasets.census_adult_income`
      WHERE MOD(ABS(FARM_FINGERPRINT(FORMAT("%t",
            (age, occupation, hours_per_week, capital_gain)))), 5) = 0))'
    ```

2. Sweep the decision threshold and compute expected profit at each point:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      ROUND(t, 2) AS threshold,
      COUNTIF(prob_positive >= t)                              AS contacted,
      COUNTIF(prob_positive >= t AND actual = 1)               AS tp,
      COUNTIF(prob_positive >= t AND actual = 0)               AS fp,
      COUNTIF(prob_positive <  t AND actual = 1)               AS fn,
      180 * COUNTIF(prob_positive >= t AND actual = 1)
      - 25 * COUNTIF(prob_positive >= t AND actual = 0)
      - 40 * COUNTIF(prob_positive <  t AND actual = 1)        AS expected_profit_usd
    FROM `'"${DATASET}"'.scored`, UNNEST(GENERATE_ARRAY(0.05, 0.95, 0.05)) AS t
    GROUP BY t
    ORDER BY t'
    ```

    Expected output (abridged — your exact figures will differ):

    ```
    +-----------+-----------+------+------+-----+---------------------+
    | threshold | contacted |  tp  |  fp  | fn  | expected_profit_usd |
    +-----------+-----------+------+------+-----+---------------------+
    |      0.10 |      4912 | 1497 | 3415 |  70 |              181165 |
    |      0.20 |      3401 | 1421 | 1980 | 146 |              200620 |
    |      0.30 |      2624 | 1318 | 1306 | 249 |              195110 |
    |      0.40 |      2078 | 1198 |  880 | 369 |              179800 |
    |      0.50 |      1673 | 1071 |  602 | 496 |              157150 |
    |      0.70 |       954 |  742 |  212 | 825 |              095180 |
    |      0.90 |       311 |  278 |   33 |1289 |              007590 |
    +-----------+-----------+------+------+-----+---------------------+
    ```

3. Read the shape of that curve, because it is the entire lesson:

    - Profit **peaks near threshold 0.20**, not at the statistically natural 0.50.
    - At 0.50 — the default every tool ships with — the firm leaves roughly **USD 43,000 on the table** versus the optimum.
    - The optimum is *low* because a false positive costs USD 25 while a missed true positive costs USD 220 in foregone margin plus attribution. **When misses are far more expensive than false alarms, the correct model is a deliberately trigger-happy one.**
    - Change one number in the economics — say outreach becomes a USD 300 in-person visit — and the optimum moves sharply right, with no retraining at all.

4. **[DEPTH]** Compute the honest baseline. Value is *incremental*, never absolute:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      "contact everyone"     AS strategy,
      COUNT(*)               AS contacted,
      180 * COUNTIF(actual = 1) - 25 * COUNTIF(actual = 0) AS profit_usd
    FROM `'"${DATASET}"'.scored`
    UNION ALL
    SELECT "contact nobody", 0, -40 * COUNTIF(actual = 1)
    FROM `'"${DATASET}"'.scored`'
    ```

    Expected output:

    ```
    +------------------+-----------+------------+
    |     strategy     | contacted | profit_usd |
    +------------------+-----------+------------+
    | contact everyone |      6512 |     158685 |
    | contact nobody   |         0 |     -62680 |
    +------------------+-----------+------------+
    ```

    **The model's true business value is USD 200,620 − USD 158,685 ≈ USD 41,935**, not USD 200,620. The naïve "contact everyone" strategy already captures most of the available margin. Any ROI case that compares the model against *zero* instead of against *the current process* is inflated, and this is the most common way AI business cases are overstated. Against that ~USD 42k of incremental annual margin you must still subtract training, serving, monitoring, and the engineering time to keep it alive.

> **Sources:** BQML `ML.PREDICT` <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-predict> · Business value framing in the exam guide, Section 3.

### Checkpoint 5

- **Q5.1** Why is the profit-maximizing threshold 0.20 rather than 0.50? Give the economic rule in one sentence.
- **Q5.2** Outreach cost rises from USD 25 to USD 120. Without rerunning anything, predict which direction the optimal threshold moves and why.
- **Q5.3** The model was not retrained between thresholds 0.20 and 0.90. What exactly changed?
- **Q5.4** State the model's incremental business value from step 4, and explain why quoting the gross figure is misleading.
- **Q5.5** A vendor pitches "94% accurate churn prediction." List three questions you must ask before that number means anything financially.
- **Q5.6** Which single business input, if the finance team gets it wrong, most distorts the optimal threshold here?

---

## Exercise 6 — Generative AI: foundation models, tokens, and hallucination **[CORE]**

**Goal:** Call a foundation model directly, observe token-based pricing, and reproduce a hallucination — the risk the exam expects you to name.

> **Cost:** a handful of `generateContent` calls on a Flash-tier model costs well under USD 0.01. Confirm current rates at <https://cloud.google.com/vertex-ai/generative-ai/pricing>.

### Steps

1. Make one call and read the whole response envelope, not just the text:

    ```bash
    cat > /tmp/req.json <<'EOF'
    {
      "contents": [{
        "role": "user",
        "parts": [{"text": "In exactly two sentences, explain the difference between training and inference to a non-technical executive."}]
      }],
      "generationConfig": { "temperature": 0.2, "maxOutputTokens": 256 }
    }
    EOF

    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
      -d @/tmp/req.json | tee /tmp/resp.json | python3 -m json.tool | head -40
    ```

    Expected output (abridged):

    ```json
    {
      "candidates": [{
        "content": {
          "role": "model",
          "parts": [{ "text": "Training is the one-time, compute-intensive process of ... Inference is what happens every time ..." }]
        },
        "finishReason": "STOP",
        "safetyRatings": [
          { "category": "HARM_CATEGORY_HATE_SPEECH", "probability": "NEGLIGIBLE" },
          { "category": "HARM_CATEGORY_DANGEROUS_CONTENT", "probability": "NEGLIGIBLE" }
        ]
      }],
      "usageMetadata": {
        "promptTokenCount": 27,
        "candidatesTokenCount": 61,
        "totalTokenCount": 88
      }
    }
    ```

2. Extract the billing unit. **You are billed per token, in and out, not per request:**

    ```bash
    python3 -c "
    import json; u = json.load(open('/tmp/resp.json'))['usageMetadata']
    print(f\"input={u['promptTokenCount']}  output={u['candidatesTokenCount']}  total={u['totalTokenCount']}\")"
    ```

    Expected output:

    ```
    input=27  output=61  total=88
    ```

3. Size a workload before committing to it. Use `:countTokens`, which is free and does not run the model:

    ```bash
    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:countTokens" \
      -d @/tmp/req.json
    ```

    Expected output:

    ```json
    { "totalTokens": 27, "totalBillableCharacters": 108 }
    ```

    Now do the arithmetic a leader is actually asked for. Take the *current* per-million-token input and output rates from the pricing page above — call them `$R_in` and `$R_out` — and estimate 500,000 support tickets per month at roughly 800 input + 200 output tokens each:

    ```
    monthly input tokens  = 500,000 × 800 = 400,000,000  = 400 M
    monthly output tokens = 500,000 × 200 = 100,000,000  = 100 M
    monthly cost ≈ 400 × R_in + 100 × R_out
    ```

    Fill in today's rates yourself. **The habit matters more than the number**: token volume × published rate, sized *before* the pilot, is how generative AI budgets are defended. Also note the asymmetry — output tokens are priced substantially higher than input tokens, so "make the answer shorter" is a real and immediate cost lever.

4. Now induce a hallucination. Ask about something that plausibly could exist but does not:

    ```bash
    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
      -d '{"contents":[{"role":"user","parts":[{"text":"Summarize the refund terms in section 7.4 of the Northwind Dynamics Enterprise Support Agreement, revision C."}]}],
           "generationConfig":{"temperature":0.9}}' \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['candidates'][0]['content']['parts'][0]['text'])"
    ```

    Expected behaviour: the model will often produce a fluent, well-structured, professionally worded summary of a document that **does not exist** — pro-rated credits, 30-day notice windows, named exclusions. Occasionally it will refuse. Run it two or three times at `temperature: 0.9` and observe the variation.

    This is **hallucination**, and note its actual shape: the output is not garbled, it is *confident and plausible*. A foundation model is trained to produce likely-sounding continuations, not to know whether a source exists. Fluency is not evidence of truth. For the exam, be able to say: *hallucination is the risk that generative AI produces confident, coherent output that is factually wrong.*

5. **[DEPTH]** Watch temperature control the trade-off between determinism and variety:

    ```bash
    for T in 0.0 1.0; do
      echo "--- temperature=$T ---"
      for i in 1 2; do
        curl -s -X POST \
          -H "Authorization: Bearer $(gcloud auth print-access-token)" \
          -H "Content-Type: application/json" \
          "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
          -d "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Name one benefit of cloud computing. Answer in five words.\"}]}],\"generationConfig\":{\"temperature\":$T,\"maxOutputTokens\":32}}" \
          | python3 -c "import sys,json; print(json.load(sys.stdin)['candidates'][0]['content']['parts'][0]['text'].strip())"
      done
    done
    ```

    At `0.0` the two runs are near-identical; at `1.0` they diverge. **Low temperature for extraction, classification and compliance work; higher temperature for ideation and copywriting.**

> **Sources:** Inference API reference <https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference> · Gemini models <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/models> · Generative AI pricing <https://cloud.google.com/vertex-ai/generative-ai/pricing>

### Checkpoint 6

- **Q6.1** What is the unit of billing for a Gemini call, and why does "number of API calls" fail as a budget proxy?
- **Q6.2** Why does `:countTokens` exist as a separate free endpoint? Name the business practice it enables.
- **Q6.3** Define hallucination in exam terms. Why is the *fluency* of the output the dangerous part?
- **Q6.4** For each, choose low or high temperature and justify in one clause: (a) extracting invoice totals; (b) generating ad slogans; (c) classifying support tickets into 12 categories; (d) drafting product name candidates.
- **Q6.5** Output tokens cost more than input tokens. Name two concrete engineering levers this pricing shape justifies.

---

## Exercise 7 — Grounding and RAG: the fix for hallucination **[CORE]**

**Goal:** Constrain a foundation model to *your* data. Retrieval-Augmented Generation is the answer to a very common exam scenario: "we want the model to answer from our internal documents."

> **Cost:** embedding a handful of short strings costs a fraction of a cent.

### Steps

1. Create a BigQuery connection so BigQuery may call Vertex AI on your behalf:

    ```bash
    bq mk --connection --location="$BQ_LOCATION" --project_id="$PROJECT_ID" \
      --connection_type=CLOUD_RESOURCE vertex_conn

    export CONN_SA=$(bq show --format=json --connection \
      "${PROJECT_ID}.${BQ_LOCATION}.vertex_conn" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['cloudResource']['serviceAccountId'])")
    echo "connection service account: $CONN_SA"
    ```

    Expected output:

    ```
    connection service account: bqcx-123456789012-ab3d@gcp-sa-bigquery-condel.iam.gserviceaccount.com
    ```

    That auto-created service account is the identity BigQuery assumes. It starts with **no permissions** — least privilege by default.

2. Grant it exactly one role:

    ```bash
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${CONN_SA}" \
      --role="roles/aiplatform.user" --condition=None --quiet >/dev/null
    echo "granted"
    ```

3. Register the embedding model as a remote model:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE MODEL `'"${DATASET}"'.embedder`
    REMOTE WITH CONNECTION `'"${PROJECT_ID}.${BQ_LOCATION}"'.vertex_conn`
    OPTIONS (ENDPOINT = "'"${EMB_MODEL}"'")'
    ```

4. Create a small private knowledge base — facts no foundation model can possibly know, because you just invented them:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE TABLE `'"${DATASET}"'.kb` (doc_id STRING, content STRING)
    AS SELECT * FROM UNNEST([
      STRUCT("POL-001" AS doc_id, "Northwind Dynamics issues refunds for annual Enterprise Support within 45 calendar days of the renewal date, pro-rated by unused months, minus a 4 percent administrative retention." AS content),
      STRUCT("POL-002", "Northwind Dynamics Priority-1 incidents carry a 22-minute response target during business hours and 55 minutes outside them, measured from ticket acknowledgement."),
      STRUCT("POL-003", "Northwind Dynamics customers on the Standard tier receive two named support contacts; Enterprise tier receives eight named contacts and one assigned technical account manager."),
      STRUCT("POL-004", "All Northwind Dynamics data residency commitments are limited to the europe-west4 and us-east4 regions; no other region is contractually covered.")
    ])'
    ```

5. Generate embeddings — turn text into vectors so that *meaning* becomes measurable distance:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE TABLE `'"${DATASET}"'.kb_embedded` AS
    SELECT doc_id, content, ml_generate_embedding_result AS embedding
    FROM ML.GENERATE_EMBEDDING(
      MODEL `'"${DATASET}"'.embedder`,
      (SELECT doc_id, content AS content FROM `'"${DATASET}"'.kb`),
      STRUCT(TRUE AS flatten_json_output, "RETRIEVAL_DOCUMENT" AS task_type))'

    bq query --use_legacy_sql=false --format=pretty '
    SELECT doc_id, ARRAY_LENGTH(embedding) AS dimensions
    FROM `'"${DATASET}"'.kb_embedded`'
    ```

    Expected output:

    ```
    +---------+------------+
    | doc_id  | dimensions |
    +---------+------------+
    | POL-001 |        768 |
    | POL-002 |        768 |
    | POL-003 |        768 |
    | POL-004 |        768 |
    +---------+------------+
    ```

    Each policy is now a point in 768-dimensional space. Semantically similar text lands nearby — that is the entire mechanism behind semantic search.

6. Retrieve by meaning, not by keyword. Note that the query uses none of the document's words:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      base.doc_id,
      ROUND(distance, 4) AS distance,
      SUBSTR(base.content, 1, 70) AS snippet
    FROM VECTOR_SEARCH(
      TABLE `'"${DATASET}"'.kb_embedded`, "embedding",
      (SELECT ml_generate_embedding_result AS embedding
       FROM ML.GENERATE_EMBEDDING(
         MODEL `'"${DATASET}"'.embedder`,
         (SELECT "How long do I have to get my money back after renewing?" AS content),
         STRUCT(TRUE AS flatten_json_output, "RETRIEVAL_QUERY" AS task_type))),
      top_k => 2, distance_type => "COSINE")'
    ```

    Expected output:

    ```
    +---------+----------+------------------------------------------------------------------------+
    | doc_id  | distance |                                snippet                                 |
    +---------+----------+------------------------------------------------------------------------+
    | POL-001 |   0.1832 | Northwind Dynamics issues refunds for annual Enterprise Support within  |
    | POL-003 |   0.4417 | Northwind Dynamics customers on the Standard tier receive two named su  |
    +---------+----------+------------------------------------------------------------------------+
    ```

    The query said "money back", the document says "refunds"; the query said "how long", the document says "45 calendar days". A keyword index would have returned nothing. **Embeddings match meaning.**

7. Now close the loop: feed the retrieved passage to the model as context and ask the same question that hallucinated in Exercise 6:

    ```bash
    export CTX=$(bq query --use_legacy_sql=false --format=csv --quiet '
    SELECT base.content FROM VECTOR_SEARCH(
      TABLE `'"${DATASET}"'.kb_embedded`, "embedding",
      (SELECT ml_generate_embedding_result AS embedding FROM ML.GENERATE_EMBEDDING(
        MODEL `'"${DATASET}"'.embedder`,
        (SELECT "refund terms after renewal" AS content),
        STRUCT(TRUE AS flatten_json_output, "RETRIEVAL_QUERY" AS task_type))),
      top_k => 1)' | tail -n +2 | tr -d '"')

    python3 - <<PY > /tmp/rag.json
    import json, os
    ctx = os.environ["CTX"]
    prompt = (
      "Answer ONLY from the context below. If the context does not contain the "
      "answer, reply exactly: NOT IN POLICY.\n\n"
      f"CONTEXT:\n{ctx}\n\nQUESTION: What are the refund terms after renewal?"
    )
    json.dump({"contents":[{"role":"user","parts":[{"text":prompt}]}],
               "generationConfig":{"temperature":0.0}}, open("/tmp/rag.json","w"))
    PY

    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
      -d @/tmp/rag.json \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['candidates'][0]['content']['parts'][0]['text'])"
    ```

    Expected output (substance, not wording):

    ```
    Refunds for annual Enterprise Support are issued within 45 calendar days of the
    renewal date, pro-rated by unused months, less a 4% administrative retention.
    ```

    **The invented numbers are gone.** The model now reports 45 days and 4% because those facts were placed in its context window, not because it knew them. Nothing was retrained — the model weights are byte-identical to Exercise 6.

8. Verify the guard rail actually holds by asking something outside the knowledge base:

    ```bash
    python3 - <<PY > /tmp/rag2.json
    import json, os
    prompt = ("Answer ONLY from the context below. If the context does not contain the "
              "answer, reply exactly: NOT IN POLICY.\n\nCONTEXT:\n" + os.environ["CTX"] +
              "\n\nQUESTION: What is the parental leave policy?")
    json.dump({"contents":[{"role":"user","parts":[{"text":prompt}]}],
               "generationConfig":{"temperature":0.0}}, open("/tmp/rag2.json","w"))
    PY

    curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
      -d @/tmp/rag2.json \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['candidates'][0]['content']['parts'][0]['text'])"
    ```

    Expected output:

    ```
    NOT IN POLICY
    ```

    A system that can say "I don't know" is worth more in a regulated business than one that is right slightly more often but never abstains.

> **Sources:** `ML.GENERATE_EMBEDDING` <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-generate-embedding> · BigQuery vector search <https://cloud.google.com/bigquery/docs/vector-search> · Grounding overview <https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview>

### Checkpoint 7

- **Q7.1** In step 7, did the model's weights change? Then what changed, and what is the general name for this technique?
- **Q7.2** Explain in business terms why an embedding-based search found POL-001 when the query shared no keywords with it.
- **Q7.3** Give two concrete advantages of RAG over fine-tuning a model on the same policy documents.
- **Q7.4** Name a scenario where RAG is *not* sufficient and fine-tuning or tuning is the better answer.
- **Q7.5** The connection's service account was granted `roles/aiplatform.user` and nothing else. Name the security principle, and state what breaks if you grant `roles/owner` instead.
- **Q7.6** Your RAG chatbot answers customer questions from an internal wiki. Someone edits a wiki page. What must happen for the chatbot to reflect the change, and what is the corresponding operational obligation?

---

## Exercise 8 — Responsible AI: safety filters, bias, and the human decision **[CORE]**

**Goal:** Observe platform safety controls, then demonstrate that a technically sound model can be socially unacceptable — the reason Responsible AI is a governance topic, not an engineering one.

### Steps

1. Inspect the safety ratings Vertex AI attaches to every response by default:

    ```bash
    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
      -d '{"contents":[{"role":"user","parts":[{"text":"Write a short, friendly welcome email for a new employee."}]}]}' \
      | python3 -c "
    import sys, json
    r = json.load(sys.stdin)['candidates'][0]
    print('finishReason:', r.get('finishReason'))
    for s in r.get('safetyRatings', []):
        print(f\"  {s['category']:40s} {s['probability']}\")"
    ```

    Expected output:

    ```
    finishReason: STOP
      HARM_CATEGORY_HATE_SPEECH                NEGLIGIBLE
      HARM_CATEGORY_DANGEROUS_CONTENT          NEGLIGIBLE
      HARM_CATEGORY_HARASSMENT                 NEGLIGIBLE
      HARM_CATEGORY_SEXUALLY_EXPLICIT          NEGLIGIBLE
    ```

    Every call is scored on all four categories, whether you asked for it or not. Safety is a default of the platform, not an add-on you purchase.

2. Send an explicit `safetySettings` block to see that thresholds are configurable per request:

    ```bash
    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
      -d '{
        "contents":[{"role":"user","parts":[{"text":"Summarize the plot of a crime thriller in three sentences."}]}],
        "safetySettings":[
          {"category":"HARM_CATEGORY_DANGEROUS_CONTENT","threshold":"BLOCK_LOW_AND_ABOVE"},
          {"category":"HARM_CATEGORY_HARASSMENT","threshold":"BLOCK_MEDIUM_AND_ABOVE"}
        ]}' | python3 -c "
    import sys, json
    d = json.load(sys.stdin)
    print('promptFeedback:', d.get('promptFeedback', 'none'))
    c = d.get('candidates', [{}])[0]
    print('finishReason:', c.get('finishReason'))"
    ```

    Expected output:

    ```
    promptFeedback: none
    finishReason: STOP
    ```

    When a response *is* blocked you will see `finishReason: SAFETY` and no `parts` — an application that assumes `parts[0].text` always exists will crash in production. Tightening the threshold to `BLOCK_LOW_AND_ABOVE` reduces harmful output *and* increases false blocks on legitimate content. **There is no setting that is simply "safe"; there is a dial with costs at both ends, and choosing where to set it is a business decision.**

3. Now the harder lesson. Retrain the income model **including** the demographic attributes we deliberately excluded in Exercise 3:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE MODEL `'"${DATASET}"'.income_with_demographics`
    OPTIONS (model_type="LOGISTIC_REG", input_label_cols=["income_over_50k"],
             auto_class_weights=TRUE, data_split_method="RANDOM",
             data_split_eval_fraction=0.20) AS
    SELECT age, workclass, education_num, marital_status, occupation,
           relationship, hours_per_week, native_country,
           race, sex,
           IF(TRIM(income_bracket) = ">50K", 1, 0) AS income_over_50k
    FROM `bigquery-public-data.ml_datasets.census_adult_income`'

    bq query --use_legacy_sql=false --format=pretty '
    SELECT "without demographics" AS model, ROUND(roc_auc,4) AS roc_auc
    FROM ML.EVALUATE(MODEL `'"${DATASET}"'.income_logreg`)
    UNION ALL
    SELECT "with race and sex", ROUND(roc_auc,4)
    FROM ML.EVALUATE(MODEL `'"${DATASET}"'.income_with_demographics`)'
    ```

    Expected output:

    ```
    +----------------------+---------+
    |        model         | roc_auc |
    +----------------------+---------+
    | without demographics |  0.8934 |
    | with race and sex    |  0.9012 |
    +----------------------+---------+
    ```

    **The discriminatory model is measurably better.** Adding `race` and `sex` improved ROC AUC. Every statistical criterion prefers it. If your model selection process is "maximize AUC", this model ships.

4. Measure the disparity the aggregate metric concealed:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      TRIM(sex) AS sex,
      COUNT(*) AS n,
      ROUND(AVG((SELECT p.prob FROM UNNEST(predicted_income_over_50k_probs) p
                 WHERE p.label = 1)), 4) AS avg_predicted_prob,
      ROUND(AVG(CAST(income_over_50k AS FLOAT64)), 4) AS actual_rate
    FROM ML.PREDICT(MODEL `'"${DATASET}"'.income_with_demographics`, (
      SELECT age, workclass, education_num, marital_status, occupation,
             relationship, hours_per_week, native_country, race, sex,
             IF(TRIM(income_bracket) = ">50K", 1, 0) AS income_over_50k
      FROM `bigquery-public-data.ml_datasets.census_adult_income`))
    GROUP BY sex ORDER BY n DESC'
    ```

    Expected output:

    ```
    +--------+-------+--------------------+-------------+
    |  sex   |   n   | avg_predicted_prob | actual_rate |
    +--------+-------+--------------------+-------------+
    | Male   | 21790 |             0.3814 |      0.3057 |
    | Female | 10771 |             0.1502 |      0.1095 |
    +--------+-------+--------------------+-------------+
    ```

    The model assigns women roughly 40% of the score it assigns men. It is not malfunctioning — it faithfully learned a **historical** pattern from a 1994 labour market shaped by decades of unequal access. And that is precisely the danger: **an ML model trained on historical outcomes will reproduce and operationalize historical inequity, at scale, with the appearance of mathematical objectivity.** In a lending, hiring or insurance context this is a legal exposure, not merely an ethical one.

5. Recognize that the fix is not purely technical. Dropping `race` and `sex` — which is what the Exercise 3 model did — does **not** eliminate the disparity, because `relationship` (with values like `Husband` and `Wife`) and `occupation` remain correlated proxies. Confirm it:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT TRIM(sex) AS sex,
           ROUND(AVG((SELECT p.prob FROM UNNEST(predicted_income_over_50k_probs) p
                      WHERE p.label = 1)), 4) AS avg_predicted_prob
    FROM ML.PREDICT(MODEL `'"${DATASET}"'.income_logreg`, (
      SELECT age, workclass, education_num, marital_status, occupation,
             relationship, hours_per_week, native_country, sex
      FROM `bigquery-public-data.ml_datasets.census_adult_income`))
    GROUP BY sex'
    ```

    Expected output:

    ```
    +--------+--------------------+
    |  sex   | avg_predicted_prob |
    +--------+--------------------+
    | Male   |             0.3702 |
    | Female |             0.1631 |
    +--------+--------------------+
    ```

    Barely moved. **"We removed the protected attribute" is not a defence** — it is the most common and least effective mitigation, because correlated proxies carry the same signal. Real mitigation requires measuring outcomes per group, setting fairness constraints, documenting the model's intended use, and — the decisive control — **keeping a human accountable for the decision.**

6. Read Google's current published position and note the version:

    ```bash
    echo "Google AI Principles ............ https://ai.google/principles/"
    echo "Responsible AI on Google Cloud .. https://cloud.google.com/responsible-ai"
    echo "Safety filter configuration ..... https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/configure-safety-filters"
    ```

    One instructor note worth carrying into the exam: **Google revised its AI Principles in February 2025**, restructuring them around bold innovation, responsible development and deployment, and collaborative progress. A large amount of Cloud Digital Leader courseware still teaches the original 2018 formulation — seven principles plus four applications Google will not pursue. Read the current wording at the link above rather than trusting any secondary summary, including this one; if an exam item quotes principle text, answer from the framing the question itself establishes.

> **Sources:** Google AI Principles <https://ai.google/principles/> · Responsible AI <https://cloud.google.com/responsible-ai> · Safety filters <https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/configure-safety-filters>

### Checkpoint 8

- **Q8.1** The model with `race` and `sex` had a *higher* ROC AUC. Explain to an engineer who wants to ship it why "it performs better" is not a sufficient argument.
- **Q8.2** In step 5, dropping the protected attributes barely changed the disparity. Name the mechanism and state why "we don't collect that field" fails as a compliance answer.
- **Q8.3** Tightening a safety threshold from `BLOCK_MEDIUM_AND_ABOVE` to `BLOCK_LOW_AND_ABOVE` reduces harmful output. What does it cost, and who should decide?
- **Q8.4** Your app reads `candidates[0].content.parts[0].text`. Describe the production incident this causes and the `finishReason` you would see in the logs.
- **Q8.5** Give the strongest single argument for keeping a human in the loop on high-stakes decisions, stated so a cost-focused executive accepts it.
- **Q8.6** The model was trained on 1994 data. Connect this fact to Exercise 4's data-quality dimensions *and* to fairness in one sentence.

---

## Exercise 9 — Choosing the right level of the AI ladder, and cleanup **[CORE]**

**Goal:** Consolidate everything into the decision framework the exam actually tests, then remove all billable resources.

### Steps

1. Reconstruct the ladder from what you built. Each rung trades control for effort:

    | Rung | What you supply | What Google supplies | You built it in | Time to value |
    |---|---|---|---|---|
    | **1. Pre-trained API** (Vision, Speech, Translation, Natural Language, Document AI) | An API call | Model, training data, ops | Ex. 2, step 3 | Hours |
    | **2. Foundation model + prompt** (Gemini via Vertex AI) | A prompt | Model, serving, safety | Ex. 6 | Hours |
    | **3. Foundation model + grounding / RAG** | Your documents + retrieval | Model, embeddings, vector search | Ex. 7 | Days |
    | **4. Tuning** (supervised fine-tuning / adapters) | Labelled examples of your task | Base model, tuning infrastructure | — | Weeks |
    | **5. AutoML** (Vertex AI) | Labelled dataset + objective | Architecture search, training, serving | — | Days–weeks |
    | **6. Custom training** (Vertex AI, BigQuery ML) | Data, features, algorithm, code | Managed compute, MLOps | Ex. 3 | Weeks–months |

    **The correct default is the lowest rung that solves the problem.** Most failed enterprise AI projects started three rungs too high.

2. Drill the mapping. For each scenario, name the rung and the Google Cloud product, then check yourself against the answer key:

    | # | Scenario |
    |---|---|
    | a | Transcribe 12,000 hours of call-centre audio into text for analysis. |
    | b | Answer employee HR questions from a 400-page internal handbook, with citations. |
    | c | Predict which of 2 million subscribers will churn next month, from 5 years of billing history in BigQuery. |
    | d | Extract vendor, date and line-item totals from 40,000 scanned invoices in mixed formats. |
    | e | Detect a manufacturing defect visible only to your trained inspectors, from 8,000 labelled photographs of your own parts. |
    | f | Draft first-pass marketing copy in six languages for a product launch. |
    | g | Recommend products on an e-commerce site based on browsing behaviour. |
    | h | Classify inbound support tickets into your 12 internal categories, with 3,000 historical labelled examples. |

3. Confirm what you actually spent:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT
      job_id,
      ROUND(total_bytes_processed / POW(1024,2), 2) AS mb_processed,
      statement_type
    FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
    WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
      AND state = "DONE" AND total_bytes_processed > 0
    ORDER BY total_bytes_processed DESC LIMIT 10'
    ```

    Expected output (abridged):

    ```
    +-------------------------+--------------+----------------+
    |         job_id          | mb_processed | statement_type |
    +-------------------------+--------------+----------------+
    | bqjob_r3f8a2c1d0e94b7f  |         4.12 | CREATE_MODEL   |
    | bqjob_r7c2b9e4a1f08d3a  |         4.12 | CREATE_MODEL   |
    | bqjob_r1a4d6f9b2c73e05  |         3.88 | SELECT         |
    +-------------------------+--------------+----------------+
    ```

    Single-digit megabytes. Every conclusion in this lab cost less than a cup of coffee — worth remembering when someone claims a proof-of-concept requires a six-figure budget.

4. **Clean up.** Do this even if the numbers look trivial; leaving resources behind is how lab spend becomes production spend:

    ```bash
    # Removes the dataset and every table and model inside it
    bq rm -r -f -d "${PROJECT_ID}:${DATASET}"

    # Remove the Vertex AI connection
    bq rm --connection --force "${PROJECT_ID}.${BQ_LOCATION}.vertex_conn"

    # Revoke the IAM binding created in Exercise 7
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${CONN_SA}" \
      --role="roles/aiplatform.user" --condition=None --quiet >/dev/null

    rm -f /tmp/req.json /tmp/resp.json /tmp/rag.json /tmp/rag2.json
    echo "cleanup complete"
    ```

5. Verify nothing survived:

    ```bash
    bq ls --datasets --project_id="$PROJECT_ID" | grep -c "$DATASET" || echo "dataset removed"
    bq ls --connection --location="$BQ_LOCATION" --project_id="$PROJECT_ID" 2>/dev/null | grep -c vertex_conn || echo "connection removed"
    ```

    Expected output:

    ```
    dataset removed
    connection removed
    ```

> **Sources:** Vertex AI overview <https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform> · Document AI <https://cloud.google.com/document-ai/docs/overview> · Speech-to-Text <https://cloud.google.com/speech-to-text/docs> · MLOps architecture <https://cloud.google.com/architecture/mlops-continuous-delivery-and-automation-pipelines-in-machine-learning>

### Checkpoint 9

- **Q9.1** State the ladder's default selection rule in one sentence, and the failure mode it prevents.
- **Q9.2** Give your rung + product for all eight scenarios in step 2.
- **Q9.3** A team proposes custom-training a sentiment model on 500 labelled reviews. Give the two strongest objections.
- **Q9.4** Rung 3 (RAG) and rung 4 (tuning) both adapt a foundation model to your business. State the one-line rule for choosing between them.
- **Q9.5** Why does the cleanup step revoke the IAM binding as well as deleting the connection?
- **Q9.6** Everything you built was measured on data that never changes. Name what a production deployment additionally requires, and the Google Cloud capability that addresses it.

---

<details>
<summary><strong>Answers — open only after attempting every checkpoint</strong></summary>

### Checkpoint 1

**A1.1** It **is** AI, and it is **not** ML. It qualifies as AI because it performs a task that would otherwise require human judgment; it is not ML because its behaviour was written by people, not learned from data — presented with new dispatch data it changes nothing until a human edits a rule. This is the cleanest way to hold the distinction: *ML systems change their behaviour by being shown data; rule engines change only by being edited.*

**A1.2** Because generative AI is built from deep neural networks — it is a *use* of deep learning distinguished by its output type. The taxonomy nests by mechanism at the ML/DL level and by output at the GenAI level: DL that emits a label is discriminative; DL that emits new content is generative.

**A1.3** It cost **nothing**. Google Cloud AI services are consumption-priced: you pay per API call, per token, per node-hour or per byte processed. Enabling an API creates no charge. The general principle is **pay for what you consume, not for what you have access to** — which is why enabling services for evaluation carries no financial risk, though it does carry a security-surface consideration.

**A1.4** It is trained once on broad, general data and then *adapted* to many downstream tasks without retraining from scratch — the "foundation" is the reusable pre-training, not the parameter count. A merely large model trained for one task is not a foundation model.

### Checkpoint 2

**A2.1** (a) Structured. (b) Unstructured — a scan is pixels; the invoice's logical structure is not machine-readable until extracted. (c) **Semi-structured**, and structured in practice for analytics: BigQuery ingests and queries it natively. (d) Unstructured.

**A2.2** **Unsupervised learning** — chiefly clustering. It would produce *groupings* of similar records without names or meaning. Critically, it cannot tell you who earns over 50K, because nothing in the data says what earning over 50K looks like; a human must interpret each cluster afterwards. The label is exactly what separates supervised from unsupervised.

**A2.3** It achieves **75.92% accuracy** while being completely useless — it identifies zero high earners, which is the only thing the business wanted. This is the **accuracy paradox** on imbalanced data: on skewed classes, accuracy is dominated by the majority class and hides total failure on the class that matters. Always ask for the majority-class baseline before accepting any accuracy figure.

**A2.4** Something like: *"Strongly mixed feedback — the customer was frustrated by onboarding and delighted by support; a near-zero average score here means two strong opposing reactions cancelling out, not indifference."* The error to avoid is reporting "neutral sentiment", which loses both the churn risk and the support win.

**A2.5** **Document AI** — purpose-built for extracting structured fields from documents, with pre-trained processors for invoices, receipts and forms. A general foundation model can read an invoice, but Document AI returns typed, positionally-anchored fields with per-field confidence scores, is priced per page for exactly this workload, and does not hallucinate a total that is not on the page. Use the specialized service when a specialized service exists.

### Checkpoint 3

**A3.1** *Training* is the process of learning parameters from historical data, producing a reusable model artifact. *Inference* is applying that finished model to new data to produce a prediction. The cost shapes differ: training is a **capital-like, episodic** cost — large, bounded, repeated only when you retrain; inference is an **operating, per-transaction** cost — tiny individually, unbounded in aggregate, scaling directly with business volume. Because inference recurs, it usually dominates total cost of ownership even though training has the bigger invoice line.

**A3.2** It prevents **overfitting** from going undetected. A model can memorize its training data and score near-perfectly on it while generalizing terribly. Evaluating on data withheld from training is the only way to measure performance on inputs the model has genuinely never seen — which is the only condition that exists in production.

**A3.3** Precision = TP / (TP + FP) = 1318 / (1318 + 1080) = 1318 / 2398 = **0.5496**. Recall = TP / (TP + FN) = 1318 / (1318 + 249) = 1318 / 1567 = **0.8411**. These match `ML.EVALUATE` to rounding. In words: 55% of the people it flagged were high earners; it found 84% of the high earners who existed.

**A3.4** **ROC AUC of 0.89.** The baseline achieves 0.76 accuracy but has *no ranking ability whatsoever* — its AUC is 0.5, equivalent to a coin flip. The model can rank a random high earner above a random low earner 89% of the time, and ranking is what actually creates value: it lets the business spend a limited outreach budget on the highest-probability prospects first. Accuracy measures a decision at one fixed threshold; AUC measures the quality of the underlying ordering, which is what you monetize.

**A3.5** Explainability is a **regulatory and operational** requirement, not curiosity. Financial services, insurance, healthcare and employment regimes increasingly require an explanation for an adverse automated decision. Beyond compliance it enables three things: detecting proxies for protected attributes before launch, debugging drift by seeing *which* feature's influence shifted, and — practically the most important — earning the trust of the domain experts whose adoption determines whether the model is used at all.

**A3.6** Training is the smallest recurring cost. Ongoing costs are: **inference**, charged per prediction forever and scaling with business volume; **retraining**, because the world changes and the model decays; **monitoring**, to detect that decay before customers do; **data pipeline** operation to keep inputs flowing and clean; and **engineering time**, usually the largest line of all. A model is a system that must be operated, not an artifact that is finished.

### Checkpoint 4

**A4.1** Because missingness was encoded as the **sentinel string `"?"`**, which is a present value from SQL's perspective. The lesson: automated quality checks only detect the defects they were written to look for. Generic null-checking is necessary and nowhere near sufficient — you must profile actual value distributions, and any unexplained high-frequency categorical value (`"?"`, `"N/A"`, `"UNKNOWN"`, `-1`, `1900-01-01`) is a missing-data flag in disguise.

**A4.2** **Timeliness / freshness.** It is the most dangerous dimension for business decisions because it fails *silently and confidently*: incomplete or invalid data usually announces itself with errors or degraded metrics, whereas stale data produces a model that is internally consistent, statistically excellent, and describing a world that no longer exists. A 1994 income model would score high on every offline metric and be indefensible for any decision about a person in 2026.

**A4.3** Because the algorithm did not lose the information — the **data** lost it. An algorithm can only find patterns that are present in what it is given; when 60% of a predictive column is destroyed, that predictive signal no longer exists anywhere in the dataset, and no amount of model sophistication can reconstruct it. The analogy that lands with executives: a better analyst cannot recover figures torn out of the ledger. This is why data engineering and governance investment usually returns more than model investment.

**A4.4** *Benign:* the metric is simply uninformative — always predicting "not fraud" scores 99.98%, so the number reflects class imbalance rather than skill; the team should be reporting precision, recall and AUC on the fraud class. *Alarming:* **data leakage** — a feature is encoding the answer, such as a `chargeback_flag`, `investigation_opened` or `account_frozen` field that is only populated *after* the fraud was discovered. Offline it looks perfect; in production the field is empty at scoring time and the model collapses.

**A4.5** Data leakage is the presence, in training data, of information that would not be available at the moment a real prediction must be made. The detection question: **"At the instant this prediction is needed, would this feature exist, with this exact value, without knowing the outcome?"** If the answer is no or "not yet", it leaks.

**A4.6** `marital_status` is a strong **proxy for sex and for historical household roles** — its categories interact with `relationship` values like `Husband` and `Wife`. A model leaning on it may produce systematically different outcomes for men and women even though sex was never supplied, creating discrimination exposure in any lending, hiring or pricing use. A purely statistical review sees a useful, high-attribution feature and approves it; only a review that asks what a feature *means socially* catches this. Exercise 8 demonstrates it empirically.

### Checkpoint 5

**A5.1** Because the cost of a miss (USD 40 attributed loss plus USD 180 of foregone margin = USD 220 of value forgone) vastly exceeds the cost of a false alarm (USD 25). The rule: **lower the threshold when false negatives cost more than false positives; raise it when false positives cost more.** The threshold is set by the ratio of error costs, not by statistical convention — 0.50 is a default, never an answer.

**A5.2** It moves **up (right)** — toward greater selectivity. As wasted outreach becomes more expensive, each false positive destroys more value, so the model must be more confident before recommending contact. Note that this happened with **no retraining**: the same probabilities, read against different economics, yield a different optimal policy.

**A5.3** Only the **decision rule** applied to the model's output. The model, its weights, and the probability assigned to each individual are identical at every threshold. This is the sharpest illustration of the domain's central point: **the model produces a probability; the business produces the decision.** The threshold is a business artifact and should be owned, reviewed and versioned by the business, not buried in a data scientist's notebook.

**A5.4** The incremental value is roughly **USD 41,935** (USD 200,620 at the optimal threshold, minus USD 158,685 for the existing "contact everyone" approach). Quoting the gross USD 200,620 is misleading because it credits the model with margin the business was *already* capturing without it. Any AI business case must be measured against the **current process**, not against doing nothing — and the residual must then still cover training, serving, monitoring and engineering cost before the project is actually profitable.

**A5.5** (1) *What is the base rate?* — 94% accuracy on a 6% churn population may be worse than predicting "nobody churns". (2) *What are precision and recall on the churn class specifically, and at which threshold?* — the aggregate hides the only performance that matters. (3) *What does each error type cost us in currency?* — without the cost of a wasted retention offer versus the lifetime value of a lost customer, no accuracy figure can be converted into money. A worthwhile fourth: *what does our current process achieve?*

**A5.6** The **cost attributed to a false negative** (the USD 40 plus the foregone USD 180 margin). It is both the largest term in the profit function and the softest number — foregone-opportunity values are estimated, not observed, and inflating them pushes the optimal threshold down, causing the business to contact far more people than is actually profitable. It deserves a sensitivity analysis before anyone commits to a campaign budget.

### Checkpoint 6

**A6.1** The **token** — sub-word units, billed separately for input (prompt) and output (completion), and priced differently for each. "API calls" fails as a budget proxy because cost per call varies by orders of magnitude: summarizing a one-line question and summarizing a 200-page contract are both one call. Budget on **expected token volume × published rate**, and treat context-window size as a direct cost driver.

**A6.2** Because you need to size and price a workload **before** paying to run it. `:countTokens` is free and does not invoke the model, so you can measure real prompts against real documents and produce a defensible cost forecast for a pilot. It also enables a runtime control: check the token count before dispatch and reject or truncate oversized inputs, preventing a single pathological document from generating an unbounded charge.

**A6.3** Hallucination is generative AI producing output that is **fluent, confident and factually wrong** — content that is statistically plausible rather than verified. The fluency is the dangerous part because humans use coherence and confidence as proxies for accuracy: a garbled answer gets checked, whereas a well-formatted answer citing a specific clause number gets pasted into a customer email. Confidence is the delivery mechanism for the error.

**A6.4** (a) **Low** (≈0) — extraction must be deterministic and reproducible; the same invoice must yield the same total every time. (b) **High** (≈0.9) — variety is the deliverable. (c) **Low** — classification into a fixed taxonomy must be stable and auditable. (d) **High** — you want a diverse candidate set to choose from.

**A6.5** (1) **Constrain output length** — `maxOutputTokens` plus prompt instructions like "answer in three sentences" or "return JSON only"; a verbose model is a direct cost overrun. (2) **Design output schemas to be terse** — return structured JSON with codes rather than prose narrative, and let the application render the human-readable text locally for free. Related levers worth naming: choosing a Flash-tier model for high-volume simple tasks, batching, and caching repeated context.

### Checkpoint 7

**A7.1** No — the weights are byte-identical. What changed is the **input**: relevant retrieved text was placed into the prompt's context window, and the instruction constrained the model to answer only from it. The technique is **grounding**, and this specific retrieve-then-generate pattern is **Retrieval-Augmented Generation (RAG)**. The distinction is worth stating precisely for the exam: grounding changes what the model *sees*; tuning changes what the model *is*.

**A7.2** Embeddings convert text into numeric vectors positioned so that **similar meaning lands in nearby coordinates**. "Money back" and "refund" express the same concept, so their vectors sit close together even though they share no characters. Keyword search matches strings; vector search matches meaning. In business terms: customers do not phrase questions using your documentation's vocabulary, and semantic search is what closes that gap.

**A7.3** (1) **Freshness** — update a document and the next query reflects it immediately, with no retraining; a tuned model is frozen at its tuning snapshot. (2) **Attribution and auditability** — RAG returns the source passage, so the answer is citable and a human can verify it, which is often a hard requirement in regulated settings. Additional strong points: dramatically lower cost and time to value, and access control can be applied at retrieval time so each user only retrieves documents they are entitled to see.

**A7.4** When you need to change the model's **behaviour, format, tone or domain vocabulary** rather than supply it facts. Examples: consistently producing output in a proprietary structured format, adopting a specialized clinical or legal register, or handling a domain whose terminology is poorly represented in pre-training. Rule of thumb: *facts → RAG; behaviour and style → tuning.* The two compose — a tuned model consuming grounded context is common.

**A7.5** **Least privilege.** The connection needs exactly one capability — invoking Vertex AI predictions — so it receives exactly `roles/aiplatform.user`. Granting `roles/owner` would mean any SQL statement referencing that connection executes with full project control, including reading every dataset, altering IAM policy and deleting resources; a single flawed or malicious query becomes a total project compromise. It also destroys the audit trail's meaning, since every action appears as an omnipotent identity.

**A7.6** The changed page must be **re-embedded** and its vector updated in the index — the chatbot answers from the vector store, not from the wiki, so an unrefreshed index serves confidently outdated policy. The operational obligation is a **pipeline that keeps embeddings synchronized with the source of truth**, with a defined freshness SLA and monitoring on it. This is the routinely underestimated cost of RAG: the retrieval index is a production data system requiring the same care as any other.

### Checkpoint 8

**A8.1** Because "performs better" measures only predictive accuracy, and predictive accuracy is not the only requirement a shipped system must satisfy. The demographic model achieves its higher AUC by **learning historical discrimination and applying it prospectively** — it is more accurate at reproducing an unjust past. That creates legal exposure under anti-discrimination law in lending, hiring, housing and insurance; reputational risk; and a genuine ethical failure independent of whether anyone sues. Model selection criteria must include fairness constraints, intended-use documentation and human accountability alongside AUC. A 0.008 AUC improvement is not a defence in a regulatory proceeding.

**A8.2** The mechanism is **proxy variables** (sometimes called redundant encoding): other features correlate with the protected attribute and carry the same information. Here `relationship` (`Husband`/`Wife`) and `occupation` reconstruct sex almost perfectly, so the disparity survives removing the `sex` column. "We don't collect that field" fails as compliance because regulators and courts assess **disparate impact on outcomes**, not the input schema — a model that produces systematically worse outcomes for a protected group is a problem regardless of which columns it read. The only meaningful control is measuring outcomes per group, which paradoxically requires collecting the attribute for auditing while excluding it from the features.

**A8.3** It costs **false positives on legitimate content** — a medical service blocking clinical descriptions, a security team blocking threat-intelligence discussion, a games publisher blocking ordinary plot summaries. Each wrongly blocked response is a broken user experience and a support ticket. The decision belongs to the **business owner of the application in consultation with legal, risk and trust-and-safety**, informed by the actual harm profile of the use case — not to whoever is writing the API client. A children's education product and an internal security-research assistant justify opposite settings.

**A8.4** The response was **blocked by a safety filter**, so `candidates[0].content` has no `parts` array; the code raises a `KeyError`/`IndexError` and, if unhandled, returns a 500 to the user or crashes the worker. The logs show **`finishReason: SAFETY`** — and possibly a populated `promptFeedback.blockReason` when the *prompt* rather than the response was blocked. Correct handling: always branch on `finishReason` (`STOP`, `MAX_TOKENS`, `SAFETY`, `RECITATION`, others) before touching `parts`, and return a designed fallback message. Note this also means safety filters are a **reliability** concern, not only an ethics one.

**A8.5** **The organization remains legally and reputationally accountable for the decision regardless of whether a machine made it.** You cannot delegate liability to a model — no regulator, court or customer accepts "the algorithm decided" as a defence. A human reviewer on high-stakes decisions is therefore not overhead; it is the control that keeps the risk insurable and the decision defensible, and it is far cheaper than one discrimination settlement, one regulatory action, or one loss of operating licence. Frame it as risk transfer pricing, not as ethics spending.

**A8.6** The 1994 vintage violates **timeliness/freshness**, and because that stale data encodes a labour market shaped by decades of unequal access, freshness failure and fairness failure are the same defect viewed twice: the model is not merely describing an outdated world, it is **projecting historical inequity forward as a prediction about people today**.

### Checkpoint 9

**A9.1** **Choose the lowest rung of the ladder that solves the problem.** It prevents the dominant failure mode of enterprise AI: teams building custom models for problems already solved by a pre-trained API or a well-prompted foundation model, spending months and specialist salaries to reach — often to fall short of — a result available on day one. Escalate a rung only when you have evidence the lower one is insufficient.

**A9.2**
- **(a)** Rung 1 — **Speech-to-Text**. Transcription is a universal task with no proprietary data advantage.
- **(b)** Rung 3 — **RAG on Vertex AI** (Vertex AI Search / grounding with Gemini). Facts are private and change; citations are required.
- **(c)** Rung 6 — **BigQuery ML**. The data is already in BigQuery, the task is tabular binary classification, and training in place avoids moving 5 years of billing history anywhere.
- **(d)** Rung 1 — **Document AI** (invoice processor). Purpose-built, returns typed fields with confidence scores.
- **(e)** Rung 5 — **Vertex AI AutoML (image classification)**. The defect is specific to your parts, so no pre-trained model knows it; 8,000 labelled images is enough for AutoML and does not justify custom architecture work.
- **(f)** Rung 2 — **Gemini via Vertex AI**, high temperature. Generative task, no proprietary facts needed. (Translation API is the rung-1 answer if the copy already exists and only needs translating.)
- **(g)** Rung 1/5 — **Vertex AI Search for commerce / Recommendations**, a managed recommendation service. Building a recommender from scratch is a classic over-escalation.
- **(h)** Rung 2 or 4 — start with **Gemini plus a well-designed prompt listing the 12 categories** and measure it against the 3,000 labelled examples; escalate to **supervised tuning** only if prompt-based accuracy is insufficient. The labelled set's best first use is as an *evaluation* set, not a training set.

**A9.3** (1) **The dataset is far too small** for custom training to beat alternatives — 500 examples will overfit and generalize poorly. (2) **The problem is already solved at rung 1 and rung 2**: the Natural Language API returns sentiment with zero training data, and a prompted foundation model handles nuanced or domain-specific sentiment; either ships in hours instead of months. A third objection worth adding: the 500 labels are far more valuable as an **evaluation set** to measure whichever off-the-shelf option you choose than as training data.

**A9.4** **If the gap is knowledge, use RAG; if the gap is behaviour, use tuning.** Missing or changing facts → retrieval. Wrong format, tone, register or domain-specific reasoning style → tuning. When both are missing, tune for behaviour and ground for facts.

**A9.5** Because deleting the connection removes the *resource* but not the **IAM policy binding**, which references the service account principal in the project's policy. Left behind, it becomes an orphaned grant — a permission attached to no reviewable resource, cluttering the policy and gradually eroding the meaning of an access review. Cleanup means restoring the security posture, not only stopping the billing.

**A9.6** It requires **monitoring for drift and continuous retraining** — production data distributions shift (customer behaviour, product mix, seasonality, upstream schema changes), so a model that was accurate at launch decays silently while continuing to return confident predictions. Google Cloud addresses this with **Vertex AI Model Monitoring** for training-serving skew and prediction drift, within the broader **MLOps** practice of automated, versioned, repeatable train–evaluate–deploy pipelines (Vertex AI Pipelines, Model Registry). The summarizing point for the exam: **deploying a model is the beginning of its cost and risk, not the end.**

</details>