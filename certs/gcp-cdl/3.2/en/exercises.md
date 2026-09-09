# Topic 3.2 — Guided Exercises

## Explain how Google Cloud's AI offerings can create business value

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12) · **Exam weight:** 9.0
**Official exam guide:** <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>

---

### How to use this lab

The Cloud Digital Leader exam is not a coding exam, but the questions are written by people who have shipped these services. The fastest way to answer *"which Google Cloud AI offering creates value here?"* correctly is to have once seen the service answer you, seen its bill, and seen it fail. That is what these exercises do: every claim you will be asked about on the exam is turned into a command you run and an output you inspect.

**Rules of engagement**

| Rule | Why |
|---|---|
| Never trust a price you remember. Fetch it. | Google Cloud SKU prices change; the exam tests the *model* (pay‑per‑use, no upfront), not the number. |
| Never trust a model ID you remember. List it. | Gemini model IDs are versioned and retired on a published schedule. |
| Pin the region on every AI call. | Data residency is a business‑value and compliance argument, not a detail. |
| Delete what you create. | Several resources in this lab bill per hour of existence, not per call. |

**Cost:** the whole lab runs for well under **US$5** if you follow the cleanup steps. Steps that bill are marked 💵. Steps that are free are marked 🆓. New accounts have free credits; several APIs also have a perpetual monthly free tier.

---

## Exercise 0 — Bootstrap: the environment and the mental map

**Business scenario.** You have been asked by a CFO: *"Everyone is selling us AI. What are we actually buying from Google, and at which layer?"* Before you can answer that, you need a project where the AI APIs are on.

**What you will prove.** That Google Cloud's AI portfolio is a **stack of four layers**, that you can buy at any one of them, and that the layer you buy at is the single biggest driver of cost, time‑to‑value, and required skills.

### Steps

1. Set your working variables. Use a **dedicated project** so the billing export in Exercise 8 is clean.

   ```bash
   export PROJECT_ID="cdl-ai-lab-$(date +%s | tail -c 6)"
   export REGION="us-central1"
   export BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"   # gcloud billing accounts list

   gcloud projects create "$PROJECT_ID" --name="CDL AI Lab"
   gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
   gcloud config set project "$PROJECT_ID"
   gcloud config set ai/region "$REGION"
   ```

2. 🆓 Enable the APIs for every layer of the stack you are about to touch.

   ```bash
   gcloud services enable \
     aiplatform.googleapis.com \
     documentai.googleapis.com \
     discoveryengine.googleapis.com \
     dialogflow.googleapis.com \
     vision.googleapis.com \
     translate.googleapis.com \
     bigquery.googleapis.com \
     bigqueryconnection.googleapis.com \
     cloudbilling.googleapis.com \
     cloudquotas.googleapis.com \
     monitoring.googleapis.com
   ```

   Expected output:

   ```
   Operation "operations/acat.p2-472...-a1b2c3d4-..." finished successfully.
   ```

3. 🆓 Confirm what is now on. Enabling an API costs nothing — **you are billed per unit of consumption, not per service enabled.** This is the first business‑value fact of the topic.

   ```bash
   gcloud services list --enabled --format="table(config.name)" | grep -E "aiplatform|documentai|discoveryengine"
   ```

   ```
   CONFIG.NAME
   aiplatform.googleapis.com
   discoveryengine.googleapis.com
   documentai.googleapis.com
   ```

4. 🆓 Now draw the map. Write this file — you will keep annotating it as the lab proceeds. It is the answer to the CFO's question.

   ```yaml
   # ai-stack-map.yaml — the four layers you can buy at on Google Cloud
   layers:
     - id: 1-infrastructure
       what: "AI-optimized compute and storage: TPU (Trillium and later), NVIDIA GPUs, AI Hypercomputer"
       you_buy: "capacity, by the hour or by commitment"
       who_uses_it: "ML platform teams training or serving their own foundation models"
       time_to_value: "months"
       docs: "https://cloud.google.com/ai-hypercomputer/docs/overview"

     - id: 2-models
       what: "Foundation models: Gemini (Google), plus Model Garden — Gemma, third-party and open models"
       you_buy: "tokens, or dedicated throughput (Provisioned Throughput)"
       who_uses_it: "developers calling an API; no training required"
       time_to_value: "hours"
       docs: "https://cloud.google.com/vertex-ai/generative-ai/docs/model-garden/explore-models"

     - id: 3-platform
       what: "Vertex AI: one managed platform for building, tuning, evaluating, deploying, grounding and governing models"
       you_buy: "managed services — training jobs, endpoints, pipelines, evaluation, RAG Engine, Feature Store"
       who_uses_it: "data science and ML engineering teams"
       time_to_value: "weeks"
       docs: "https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform"

     - id: 4-agents-and-apps
       what: >-
         Ready-made AI applications and agents: Gemini for Google Cloud / Google Workspace,
         Google Agentspace, Customer Engagement Suite (CCaaS), Vertex AI Search,
         Vertex AI Agent Builder / Conversational Agents, and pre-trained task APIs
         (Document AI, Vision, Speech-to-Text, Translation)
       you_buy: "an outcome — a parsed invoice, a deflected call, a licensed seat"
       who_uses_it: "business units; little or no ML skill required"
       time_to_value: "days"
       docs: "https://cloud.google.com/products/ai"

   decision_rule:
     - "Buy at the HIGHEST layer that solves the problem."
     - "Descend a layer only when the layer above is proven insufficient — each step down
        adds skills, calendar time and undifferentiated engineering."
   ```

5. 🆓 Verify layer 2 is real rather than marketing: list what is actually offered in Model Garden.

   ```bash
   gcloud ai model-garden models list --limit=15
   ```

   Representative output (the catalogue changes continuously — this is exactly why you list it instead of memorising it):

   ```
   MODEL_ID                                    SUPPORTED_ACTIONS
   google/gemini@gemini-2.5-flash              openOrderedDeploy, openNotebook
   google/gemma3@gemma-3-27b-it                openOrderedDeploy, openNotebook
   anthropic/claude@claude-...                 openOrderedDeploy
   meta/llama3@llama-3...                      openOrderedDeploy, openNotebook
   ...
   ```

   > **Read this as a business fact, not a list.** Model Garden means the model is a *replaceable component*. A first‑party Google model, an open model you self‑host, and a third‑party model all sit behind the same platform, the same IAM, the same VPC Service Controls perimeter and the same billing. That is what "avoiding model lock‑in" concretely means, and it is a recurring CDL exam theme.

### Comprehension check — Exercise 0

- **Q1.** Enabling `aiplatform.googleapis.com` produced no charge. State the pricing model this demonstrates and name one business consequence for a company that wants to *pilot* AI in three departments at once.
- **Q2.** A retailer wants a chatbot on its support site within one quarter, with a two‑person team and no ML engineers. Which layer of `ai-stack-map.yaml` should they buy at, and what specifically would they be spending calendar time on if they chose layer 1 instead?
- **Q3.** Your CTO says: "If we standardise on Gemini we are locked into Google." Using only what step 5 printed, give the counter‑argument — and then state the part of the lock‑in concern that is *legitimate*.

---

## Exercise 1 — Build vs. buy: pre-trained API, tuned model, or custom model

**Business scenario.** An insurer wants to automatically tag photographs uploaded with claims. Three options are on the table: call a pre‑trained API, train a custom model on Vertex AI with their own labelled images, or build from scratch. Each has a different cost curve and a different break‑even.

**What you will prove.** That the pre‑trained API returns useful output in one command with **zero training data and zero ML skill**, and that this sets the *bar* every custom option must beat.

### Steps

1. 💵 Call the pre‑trained Vision API on a public image. No model, no training, no endpoint.

   ```bash
   gcloud ml vision detect-labels gs://cloud-samples-data/vision/label/setagaya.jpeg
   ```

   Representative output (abridged):

   ```json
   {
     "responses": [
       {
         "labelAnnotations": [
           { "description": "Street",      "mid": "/m/01c8br", "score": 0.9375, "topicality": 0.9375 },
           { "description": "Neighbourhood","mid": "/m/01n32",  "score": 0.9202, "topicality": 0.9202 },
           { "description": "Urban area",  "mid": "/m/018p4k", "score": 0.9008, "topicality": 0.9008 },
           { "description": "Building",    "mid": "/m/0cgh4",  "score": 0.8821, "topicality": 0.8821 }
         ]
       }
     ]
   }
   ```

2. 🆓 Note the two numbers that matter to the business, and where they came from:

   ```text
   Time from zero to first prediction : ~1 command  (minutes)
   Labelled training images required  : 0
   Data scientists required           : 0
   Confidence signal available        : yes — "score", per label
   ```

   The `score` field is the hook for the whole build/buy argument: it lets you build a **confidence threshold and a human‑in‑the‑loop fallback** without any model work. High‑confidence predictions auto‑process; low‑confidence ones route to a human.

3. 🆓 Now quantify the alternative. Fetch the *real, current* prices instead of quoting a number — this is the technique, and it is examinable behaviour for a Digital Leader.

   ```bash
   export API_KEY="$(gcloud services api-keys create --display-name=cdl-catalog \
     --format='value(response.keyString)')"

   # 1. find the service ID for Vertex AI in the public price catalogue
   curl -s "https://cloudbilling.googleapis.com/v1/services?key=${API_KEY}&pageSize=200" \
     | jq -r '.services[] | select(.displayName | test("Vertex AI|Cloud Vision|Document AI"))
              | "\(.serviceId)\t\(.displayName)"'
   ```

   Representative output:

   ```
   C1F7-477B-6E67   Cloud Vision API
   93D7-7A6C-...    Document AI
   6F81-5844-456A   Vertex AI
   ```

4. 💵 Pull the SKUs and read the unit of billing. **The unit is the business model.**

   ```bash
   curl -s "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?key=${API_KEY}&pageSize=500" \
     | jq -r '.skus[]
              | select(.description | test("Gemini|Training|Prediction"; "i"))
              | "\(.description) | \(.category.usageUnitDescription)"' | head -20
   ```

   Representative output:

   ```
   Gemini ... Input Token ... | 1 thousand tokens
   Gemini ... Output Token ... | 1 thousand tokens
   Vertex AI Custom Training ... n1-standard-4 ... | hour
   Vertex AI Online Prediction ... | hour
   ```

5. 🆓 Write the decision down as code so it can be reviewed like any other architecture decision.

   ```yaml
   # adr-001-image-tagging.yaml — Architecture Decision Record
   decision: "Start on the pre-trained Vision API. Re-evaluate at 90 days."
   options:
     pre_trained_api:
       unit_of_cost: "per image analysed"
       fixed_cost: "none — no endpoint is running when no image arrives"
       training_data_needed: 0
       time_to_first_value: "hours"
       ceiling: "generic labels only; cannot learn 'hail damage on a 2019 Corolla bumper'"
     automl_or_tuned_model:
       unit_of_cost: "training node-hours (one-off) + serving node-hours (continuous) + per prediction"
       fixed_cost: "an endpoint bills while it is UP, even at zero traffic"
       training_data_needed: "hundreds to thousands of labelled images per class"
       time_to_first_value: "weeks (labelling dominates, not training)"
       ceiling: "learns your domain vocabulary"
     custom_from_scratch:
       unit_of_cost: "GPU/TPU hours + an ML team"
       time_to_first_value: "months"
       justified_when: "the model IS the product, or no vendor model can express the task"
   trigger_to_revisit:
     - "Vision API confidence < 0.7 on more than 20% of production traffic"
     - "Business needs a label the generic taxonomy does not contain"
   ```

### Comprehension check — Exercise 1

- **Q4.** In step 4 the custom‑training and online‑prediction SKUs are billed *per hour*, while the Gemini SKUs are billed *per thousand tokens*. Explain the cash‑flow difference for a workload with spiky, unpredictable traffic, and say which option a startup with no traffic yet should prefer.
- **Q5.** The pre‑trained API needed zero labelled images. Name the business cost that a custom model introduces which is usually *larger* than the compute cost, and which never appears on the Google Cloud invoice.
- **Q6.** The ADR sets a trigger at "confidence < 0.7 on more than 20% of traffic". Why is defining that trigger *before* launch a governance improvement rather than mere tidiness?

---

## Exercise 2 — Bring AI to the data: BigQuery ML

**Business scenario.** A telco has seven years of subscriber history in BigQuery. The data team writes SQL. The proposal on the table is to export the data to a separate ML platform. You need to show what that export costs — and what the alternative is.

**What you will prove.** That a production‑grade model can be trained, evaluated and served **without the data ever leaving BigQuery**, using only SQL — collapsing the data‑movement, duplication and governance problem to zero.

### Steps

1. 💵 Create a dataset in a pinned location.

   ```bash
   bq --location=US mk --dataset "${PROJECT_ID}:cdl_ai"
   ```

   ```
   Dataset '<PROJECT_ID>:cdl_ai' successfully created.
   ```

2. 💵 Train a classifier. One statement. The data stays where it is.

   ```bash
   bq query --use_legacy_sql=false '
   CREATE OR REPLACE MODEL `cdl_ai.income_propensity`
   OPTIONS (
     model_type            = "LOGISTIC_REG",
     input_label_cols      = ["label"],
     auto_class_weights    = TRUE,
     data_split_method     = "AUTO_SPLIT",
     enable_global_explain = TRUE
   ) AS
   SELECT
     age,
     workclass,
     education_num,
     marital_status,
     occupation,
     hours_per_week,
     IF(income_bracket = " >50K", 1, 0) AS label
   FROM `bigquery-public-data.ml_datasets.census_adult_income`
   WHERE age IS NOT NULL;'
   ```

   ```
   Waiting on bqjob_r5c2...  ... (58s) Current status: DONE
   ```

3. 🆓 Evaluate it. The exam cares that you know an evaluation step exists and is separate from training.

   ```bash
   bq query --use_legacy_sql=false '
   SELECT * FROM ML.EVALUATE(MODEL `cdl_ai.income_propensity`);'
   ```

   Representative output:

   ```
   +---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
   |      precision      |       recall        |      accuracy       |      f1_score       |      log_loss       |       roc_auc       |
   +---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
   | 0.6284...           | 0.8351...           | 0.7936...           | 0.7171...           | 0.4402...           | 0.8734...           |
   +---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
   ```

4. 🆓 Serve predictions the same way you query a table — meaning any existing dashboard, report or scheduled query becomes an ML consumer with no new infrastructure.

   ```bash
   bq query --use_legacy_sql=false '
   SELECT
     predicted_label,
     COUNT(*) AS n,
     ROUND(AVG(p.prob), 3) AS avg_confidence
   FROM ML.PREDICT(MODEL `cdl_ai.income_propensity`,
     (SELECT age, workclass, education_num, marital_status, occupation, hours_per_week
      FROM `bigquery-public-data.ml_datasets.census_adult_income` LIMIT 5000)),
     UNNEST(predicted_label_probs) AS p
   WHERE p.label = predicted_label
   GROUP BY predicted_label ORDER BY n DESC;'
   ```

   ```
   +-----------------+------+----------------+
   | predicted_label |  n   | avg_confidence |
   +-----------------+------+----------------+
   |               0 | 3355 |          0.842 |
   |               1 | 1645 |          0.719 |
   +-----------------+------+----------------+
   ```

5. 💵 Now the generative half. Register **Gemini as a remote model** inside BigQuery, so unstructured text columns become queryable. First the connection and its IAM grant:

   ```bash
   bq mk --connection --location=US --project_id="$PROJECT_ID" \
        --connection_type=CLOUD_RESOURCE cdl_ai_conn

   export CONN_SA="$(bq show --format=json --connection "${PROJECT_ID}.US.cdl_ai_conn" \
     | jq -r '.cloudResource.serviceAccountId')"
   echo "$CONN_SA"

   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="serviceAccount:${CONN_SA}" \
     --role="roles/aiplatform.user" --condition=None
   ```

   ```
   bqcx-472...-ab1c@gcp-sa-bigquery-condel.iam.gserviceaccount.com
   ```

   > IAM propagation is eventually consistent. Wait ~60 s before step 6 or the first call fails with `PERMISSION_DENIED`.

6. 💵 Create the remote model and run generative AI **as a SQL function over a table**.

   ```bash
   bq query --use_legacy_sql=false '
   CREATE OR REPLACE MODEL `cdl_ai.gemini`
   REMOTE WITH CONNECTION `US.cdl_ai_conn`
   OPTIONS (ENDPOINT = "gemini-2.5-flash");'

   bq query --use_legacy_sql=false '
   SELECT
     ml_generate_text_llm_result AS sentiment,
     review
   FROM ML.GENERATE_TEXT(
     MODEL `cdl_ai.gemini`,
     (SELECT
        "The technician arrived two hours late but fixed the fibre in ten minutes." AS review,
        CONCAT("Classify the sentiment of this support review as exactly one word ",
               "(POSITIVE, NEGATIVE or MIXED): ",
               "The technician arrived two hours late but fixed the fibre in ten minutes.") AS prompt),
     STRUCT(0.0 AS temperature, 20 AS max_output_tokens, TRUE AS flatten_json_output));'
   ```

   ```
   +-----------+--------------------------------------------------------------------------+
   | sentiment |                                  review                                  |
   +-----------+--------------------------------------------------------------------------+
   | MIXED     | The technician arrived two hours late but fixed the fibre in ten minutes. |
   +-----------+--------------------------------------------------------------------------+
   ```

   > `ENDPOINT` names a model that is versioned and eventually retired. Check the current identifiers and their retirement dates at <https://cloud.google.com/vertex-ai/generative-ai/docs/models> before you hard‑code one into a scheduled query.

### Comprehension check — Exercise 2

- **Q7.** Nothing in this exercise moved data out of BigQuery. List three distinct business costs avoided by that fact — one financial, one operational, one regulatory.
- **Q8.** The telco's team writes SQL, not Python. Quantify, in the vocabulary a CFO understands, what BigQuery ML changed about the *staffing* requirement for this project.
- **Q9.** Step 6 turned a free‑text column into a classified column with a `SELECT`. Name two business processes in a telco that this unlocks, and state which layer of `ai-stack-map.yaml` you were operating at.
- **Q10.** `ML.EVALUATE` reported `roc_auc ≈ 0.87` but `precision ≈ 0.63`. Explain to a marketing director why deploying this model to a campaign that costs €40 per contact still requires a business decision, not just an engineering one.

---

## Exercise 3 — Buying an outcome: Document AI and the payback calculation

**Business scenario.** A logistics company processes ~40,000 supplier invoices a month by hand. Two clerks, three days of the month, plus a 4% keying‑error rate that produces payment disputes. The CFO wants a payback period, not a demo.

**What you will prove.** That a pre‑trained specialised parser turns an unstructured PDF into typed, confidence‑scored fields with no training, and that you can compute a defensible break‑even from real published rates.

### Steps

1. 💵 Create an Invoice Parser processor. Note the `us` (or `eu`) location — that is your **data residency** control.

   ```bash
   export DOCAI_LOCATION="us"

   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     "https://${DOCAI_LOCATION}-documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${DOCAI_LOCATION}/processors" \
     -d '{
           "type": "INVOICE_PROCESSOR",
           "displayName": "cdl-invoice-parser"
         }' | jq '{name, type, state}'
   ```

   ```json
   {
     "name": "projects/472.../locations/us/processors/a1b2c3d4e5f6a7b8",
     "type": "INVOICE_PROCESSOR",
     "state": "ENABLED"
   }
   ```

   ```bash
   export PROCESSOR_ID="a1b2c3d4e5f6a7b8"
   ```

2. 🆓 List the processor types available to you. This is the "buy an outcome" catalogue.

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://${DOCAI_LOCATION}-documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${DOCAI_LOCATION}/processorTypes" \
     | jq -r '.processorTypes[] | "\(.type)\t\(.category)"' | sort | head -12
   ```

   ```
   BANK_STATEMENT_PROCESSOR      SPECIALIZED
   CUSTOM_EXTRACTION_PROCESSOR   CUSTOM
   EXPENSE_PROCESSOR             SPECIALIZED
   FORM_PARSER_PROCESSOR         GENERAL
   INVOICE_PROCESSOR             SPECIALIZED
   OCR_PROCESSOR                 GENERAL
   ...
   ```

3. 💵 Process one invoice synchronously and read the **typed entities** — not raw text, but `invoice_id`, `total_amount`, `supplier_name`, each with a confidence.

   ```bash
   gsutil cp gs://cloud-samples-data/documentai/invoice.pdf .
   export DOC_B64="$(base64 -w0 invoice.pdf)"

   cat > request.json <<EOF
   {
     "skipHumanReview": true,
     "rawDocument": { "mimeType": "application/pdf", "content": "${DOC_B64}" }
   }
   EOF

   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     "https://${DOCAI_LOCATION}-documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${DOCAI_LOCATION}/processors/${PROCESSOR_ID}:process" \
     -d @request.json \
     | jq -r '.document.entities[] | "\(.type)\t\(.mentionText)\tconf=\(.confidence)"'
   ```

   Representative output:

   ```
   invoice_id        19482                       conf=0.9614
   invoice_date      2020-01-01                  conf=0.9421
   due_date          2020-02-01                  conf=0.9017
   supplier_name     Anderson & Sons             conf=0.8833
   total_amount      $2,300.00                   conf=0.9776
   currency          USD                         conf=0.9502
   line_item/...     Consulting services         conf=0.8321
   ```

4. 🆓 Build the payback model. **Fetch the rate, do not recall it** — open <https://cloud.google.com/document-ai/pricing> and substitute the current published price per page for the Invoice Parser.

   ```yaml
   # payback-invoices.yaml — substitute RATE from the live pricing page before presenting
   volume:
     invoices_per_month: 40000
     avg_pages_per_invoice: 1.4
     pages_per_month: 56000

   current_manual_process:
     clerk_fte_fraction: 0.30          # 2 clerks x 3 days of a 20-day month
     fully_loaded_cost_per_fte_month: 4200      # your HR figure, not Google's
     labour_cost_per_month: 2520
     keying_error_rate: 0.04
     disputes_per_month: 1600
     avg_dispute_handling_cost: 11
     error_cost_per_month: 17600
     total_current_cost_per_month: 20120

   automated_process:
     docai_rate_per_page: RATE         # <-- from cloud.google.com/document-ai/pricing
     docai_cost_per_month: "56000 * RATE"
     confidence_threshold: 0.85
     expected_auto_approval_rate: 0.82           # measure this on a real sample, do not assume
     residual_human_review_pages: 10080
     residual_labour_cost: 454
     integration_one_off_cost: 25000             # engineering, testing, change management

   break_even_formula: >
     months_to_payback = integration_one_off_cost /
       (total_current_cost_per_month - docai_cost_per_month - residual_labour_cost)

   honesty_notes:
     - "expected_auto_approval_rate is the ONLY number here that Google cannot tell you.
        Measure it by running 500 of YOUR OWN invoices through the processor and
        counting how many clear the confidence threshold."
     - "The one-off integration cost, not the per-page price, usually dominates year one."
   ```

5. 🆓 Cleanup — a processor is free to keep, but delete it so the project stays inspectable.

   ```bash
   curl -s -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://${DOCAI_LOCATION}-documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${DOCAI_LOCATION}/processors/${PROCESSOR_ID}" \
     | jq '.metadata.commonMetadata.state'
   ```

   ```
   "RUNNING"
   ```

### Comprehension check — Exercise 3

- **Q11.** The processor emitted `total_amount ... conf=0.9776` and `line_item/... conf=0.8321`. Design, in one sentence, the operational rule that turns those two numbers into a *straight‑through processing* policy — and explain why "let the AI approve everything" is the wrong answer even at 97% confidence.
- **Q12.** In `payback-invoices.yaml`, which single input is the largest source of error in the business case, and what is the cheapest experiment that removes that uncertainty?
- **Q13.** The company also considered training a custom document model. Given step 2's output, argue for the specialised pre‑trained processor — and name the one circumstance under which `CUSTOM_EXTRACTION_PROCESSOR` becomes the right call.
- **Q14.** Why does the choice of `us` versus `eu` in the endpoint hostname belong in a *business‑value* discussion and not only in an architecture review?

---

## Exercise 4 — Grounding: turning a plausible answer into a defensible one

**Business scenario.** Legal has blocked the customer‑facing assistant. Their objection: *"If it invents a refund policy, we are contractually bound by what it said."* Grounding is the technical answer to a legal objection — and therefore a business‑value lever.

**What you will prove.** That an ungrounded generation is confident and unverifiable, and that the *same* model, grounded, returns **citations you can audit** — and that this is what makes enterprise deployment legally approvable.

### Steps

1. 💵 Ask an ungrounded question. Observe: a fluent answer, and nothing to check it against.

   ```bash
   cat > ungrounded.json <<'EOF'
   {
     "contents": [{ "role": "user", "parts": [{
       "text": "In two sentences, what is Google Cloud'\''s stated commitment about using a customer'\''s data to train its foundation models?"
     }]}],
     "generationConfig": { "temperature": 0.2, "maxOutputTokens": 256 }
   }
   EOF

   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/google/models/gemini-2.5-flash:generateContent" \
     -d @ungrounded.json \
     | jq '{text: .candidates[0].content.parts[0].text,
            grounding: (.candidates[0].groundingMetadata // "NONE"),
            tokens: .usageMetadata}'
   ```

   Representative output:

   ```json
   {
     "text": "Google Cloud states that customer data is customer data ... your prompts and responses are not used to train foundation models ...",
     "grounding": "NONE",
     "tokens": { "promptTokenCount": 31, "candidatesTokenCount": 58, "totalTokenCount": 89 }
   }
   ```

   > `"grounding": "NONE"` is the whole point. The sentence may well be correct — but **the response carries no evidence**, so nobody downstream can verify it, and no auditor will accept it.

2. 💵 Now run the identical prompt with grounding enabled.

   ```bash
   cat > grounded.json <<'EOF'
   {
     "contents": [{ "role": "user", "parts": [{
       "text": "In two sentences, what is Google Cloud'\''s stated commitment about using a customer'\''s data to train its foundation models?"
     }]}],
     "tools": [{ "googleSearch": {} }],
     "generationConfig": { "temperature": 0.2, "maxOutputTokens": 256 }
   }
   EOF

   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/google/models/gemini-2.5-flash:generateContent" \
     -d @grounded.json \
     | jq '{
         text: .candidates[0].content.parts[0].text,
         sources: [.candidates[0].groundingMetadata.groundingChunks[]?.web.uri],
         supports: (.candidates[0].groundingMetadata.groundingSupports | length)
       }'
   ```

   Representative output:

   ```json
   {
     "text": "Google Cloud commits that customer data is used only to provide the service ...",
     "sources": [
       "https://cloud.google.com/terms/service-terms",
       "https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance"
     ],
     "supports": 4
   }
   ```

   > Older API surfaces name this tool `googleSearchRetrieval`; current Gemini versions use `googleSearch`. If you get `INVALID_ARGUMENT: Unknown name "googleSearch"`, your model version predates the rename — check <https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview>.

3. 💵 Ground on **your own corpus** instead of the web — this is the enterprise pattern. Create a Vertex AI Search data store:

   ```bash
   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -H "X-Goog-User-Project: ${PROJECT_ID}" \
     "https://discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/collections/default_collection/dataStores?dataStoreId=cdl-policies" \
     -d '{
           "displayName": "Refund and warranty policies",
           "industryVertical": "GENERIC",
           "solutionTypes": ["SOLUTION_TYPE_SEARCH"],
           "contentConfig": "CONTENT_REQUIRED"
         }' | jq '{name: .name, done: .done}'
   ```

   ```json
   { "name": "projects/472.../operations/create-data-store-1234...", "done": false }
   ```

4. 🆓 Wire it into a generation request. You do not have to run this against a populated store to learn the shape — the shape is the exam answer.

   ```json
   {
     "contents": [{ "role": "user", "parts": [{ "text": "What is our refund window for enterprise contracts?" }]}],
     "tools": [{
       "retrieval": {
         "vertexAiSearch": {
           "datastore": "projects/PROJECT_ID/locations/global/collections/default_collection/dataStores/cdl-policies"
         }
       }
     }],
     "generationConfig": { "temperature": 0.0 }
   }
   ```

5. 🆓 Record the argument that unblocks Legal:

   ```yaml
   # grounding-value.yaml
   without_grounding:
     answer_quality: "fluent, sometimes correct"
     verifiable: false
     failure_mode: "confident fabrication — indistinguishable from a correct answer at read time"
     business_exposure: "the enterprise is bound by statements it cannot trace"
   with_grounding:
     answer_quality: "constrained to retrieved passages"
     verifiable: true            # groundingChunks[].uri is auditable
     failure_mode: "refusal or 'not found' — a SAFE failure"
     business_exposure: "traceable to a document the enterprise itself owns and versions"
   why_this_is_business_value:
     - "It converts an unbounded liability into a document-control problem the company already knows how to run."
     - "The knowledge base becomes the control surface: fix the PDF, the answer changes. No retraining."
     - "Freshness without fine-tuning — new policy is live the moment it is indexed."
   ```

### Comprehension check — Exercise 4

- **Q15.** Step 1 and step 2 sent the *same* prompt to the *same* model. State precisely what changed in the response payload, and why that difference is what a compliance officer signs off on.
- **Q16.** A grounded assistant answers "I could not find that in the policy documents." A stakeholder calls this a regression versus the ungrounded version, which always answered. Rebut them in business terms.
- **Q17.** Marketing wants the assistant to reflect a pricing change published this morning. Compare the cost and lead time of (a) fine‑tuning a model on the new pricing versus (b) updating the grounding data store. Which one should be the default operating model, and why?
- **Q18.** Name the layer of `ai-stack-map.yaml` that Vertex AI Search occupies, and explain what a company would have had to build itself in 2019 to get the same capability.

---

## Exercise 5 — Deflection as a KPI: Conversational Agents and the Customer Engagement Suite

**Business scenario.** A utility's contact centre handles 220,000 calls a quarter. 61% are three questions: *where is my bill, when is the outage over, how do I change my direct debit.* The board wants "AI in the call centre." You need to convert that into a measurable KPI.

**What you will prove.** That a conversational agent is provisioned as a managed resource with an SLA and a region, and that its value is expressed as **containment/deflection rate**, not as "we have a chatbot."

### Steps

1. 💵 Create a Conversational Agent (Dialogflow CX) in a pinned region.

   ```bash
   export CX_REGION="us-central1"

   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -H "X-Goog-User-Project: ${PROJECT_ID}" \
     "https://${CX_REGION}-dialogflow.googleapis.com/v3/projects/${PROJECT_ID}/locations/${CX_REGION}/agents" \
     -d '{
           "displayName": "utility-tier-1",
           "defaultLanguageCode": "en",
           "supportedLanguageCodes": ["es", "pt"],
           "timeZone": "America/Chicago",
           "enableStackdriverLogging": true,
           "advancedSettings": {
             "loggingSettings": {
               "enableStackdriverLogging": true,
               "enableInteractionLogging": true
             }
           }
         }' | jq '{name, displayName, supportedLanguageCodes, startFlow}'
   ```

   ```json
   {
     "name": "projects/472.../locations/us-central1/agents/8f2a1c6d-...",
     "displayName": "utility-tier-1",
     "supportedLanguageCodes": ["es", "pt"],
     "startFlow": "projects/472.../agents/8f2a1c6d-.../flows/00000000-0000-0000-0000-000000000000"
   }
   ```

   ```bash
   export AGENT_ID="8f2a1c6d-..."
   ```

2. 🆓 Read the two settings that carry the most business weight and say why:

   ```text
   supportedLanguageCodes : ["en","es","pt"]  -> one agent serves three markets.
                                                 The alternative is three vendor contracts,
                                                 three staffing pools, three sets of hours.
   enableInteractionLogging: true             -> without it you CANNOT compute deflection rate.
                                                 An unmeasured agent cannot be defended at
                                                 the next budget review.
   ```

3. 💵 Send a turn and inspect what the runtime returns.

   ```bash
   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -H "X-Goog-User-Project: ${PROJECT_ID}" \
     "https://${CX_REGION}-dialogflow.googleapis.com/v3/projects/${PROJECT_ID}/locations/${CX_REGION}/agents/${AGENT_ID}/sessions/session-001:detectIntent" \
     -d '{
           "queryInput": {
             "text": { "text": "when will the power be back on in postcode 60601" },
             "languageCode": "en"
           },
           "queryParams": { "timeZone": "America/Chicago" }
         }' | jq '{
             intent: .queryResult.intent.displayName,
             confidence: .queryResult.intentDetectionConfidence,
             reply: [.queryResult.responseMessages[].text.text[]?],
             currentPage: .queryResult.currentPage.displayName
           }'
   ```

   Representative output on a brand‑new, untrained agent:

   ```json
   {
     "intent": "Default Negative Intent",
     "confidence": 0,
     "reply": ["I didn't get that. Can you say it again?"],
     "currentPage": "Start Page"
   }
   ```

   > **This failure is the lesson.** The platform was provisioned in seconds; the *value* is not in the platform, it is in the flows, the grounded data store and the backend integration you have not built yet. "We bought Dialogflow" is not a deliverable.

4. 🆓 Define the KPI before building anything else.

   ```yaml
   # kpi-contact-centre.yaml
   primary_kpi:
     name: containment_rate
     definition: "sessions resolved by the agent with no human transfer / total sessions"
     baseline_today: 0.00
     target_q1: 0.35
     measured_from: "Dialogflow CX interaction logs -> BigQuery -> scheduled query"

   guardrail_kpis:
     - name: csat_of_contained_sessions
       rule: "must not fall below the human-handled baseline. A deflected ANGRY customer is a churned customer."
     - name: escalation_latency
       rule: "time from 'agent cannot help' to a human answering. Must be < 30s or containment is just queuing."
     - name: false_containment_rate
       rule: "sessions ended by the customer hanging up in frustration. Counts as a FAILURE, not a success."

   value_model:
     calls_per_quarter: 220000
     addressable_share: 0.61
     containment_at_target: 0.35
     calls_deflected_per_quarter: 46970
     cost_per_human_handled_call: 5.40     # your finance figure
     gross_saving_per_quarter: 253638
     minus: "Conversational Agents / CCaaS licensing + build + ongoing flow maintenance"

   what_the_board_should_be_told:
     - "The saving is real but it is NOT headcount-free: someone must own the flows forever."
     - "Containment without the guardrail KPIs is a metric that improves while the business gets worse."
   ```

5. 🆓 Cleanup.

   ```bash
   curl -s -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "X-Goog-User-Project: ${PROJECT_ID}" \
     "https://${CX_REGION}-dialogflow.googleapis.com/v3/projects/${PROJECT_ID}/locations/${CX_REGION}/agents/${AGENT_ID}"
   ```

### Comprehension check — Exercise 5

- **Q19.** The agent existed within seconds but answered nothing useful. Generalise this into a rule about where the cost and the risk actually sit in an enterprise AI project.
- **Q20.** `kpi-contact-centre.yaml` counts a frustrated hang‑up as a *failure* even though it is technically a contained session. Explain the perverse incentive this guardrail prevents.
- **Q21.** The agent supports `en`, `es` and `pt` from one configuration. Express that as a business‑value statement for a company entering two new markets, and identify what it does *not* remove the need for.
- **Q22.** Which is the stronger board‑level statement — "we deployed a Google Cloud AI chatbot" or "we contained 35% of tier‑1 contacts at flat CSAT" — and what does the difference tell you about how to frame *any* AI investment?

---

## Exercise 6 — Responsible AI is a business control, not an ethics slide

**Business scenario.** Risk Committee asks: *"What stops this thing from saying something that ends up on the news?"* Your answer must be a configuration, not a promise.

**What you will prove.** That safety filtering, data residency and data‑governance commitments are **configurable, inspectable platform controls** — and that this is precisely why an enterprise chooses a managed platform over a raw model.

### Steps

1. 💵 Send a request with explicit safety settings and inspect the safety verdict the platform returns on *every* response.

   ```bash
   cat > safety.json <<'EOF'
   {
     "contents": [{ "role": "user", "parts": [{
       "text": "Write a short, professional apology to a customer whose delivery was lost."
     }]}],
     "safetySettings": [
       { "category": "HARM_CATEGORY_HATE_SPEECH",       "threshold": "BLOCK_LOW_AND_ABOVE" },
       { "category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_LOW_AND_ABOVE" },
       { "category": "HARM_CATEGORY_HARASSMENT",        "threshold": "BLOCK_LOW_AND_ABOVE" },
       { "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_LOW_AND_ABOVE" }
     ],
     "generationConfig": { "temperature": 0.3, "maxOutputTokens": 256 }
   }
   EOF

   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/google/models/gemini-2.5-flash:generateContent" \
     -d @safety.json \
     | jq '{ finishReason: .candidates[0].finishReason,
             ratings: [.candidates[0].safetyRatings[]? | {category, probability, blocked}] }'
   ```

   Representative output:

   ```json
   {
     "finishReason": "STOP",
     "ratings": [
       { "category": "HARM_CATEGORY_HATE_SPEECH",       "probability": "NEGLIGIBLE", "blocked": null },
       { "category": "HARM_CATEGORY_DANGEROUS_CONTENT", "probability": "NEGLIGIBLE", "blocked": null }
     ]
   }
   ```

2. 🆓 Learn to read the two failure signals your application code must handle. They are different, and confusing them is a production incident:

   ```text
   finishReason: "STOP"    -> the model finished normally.
   finishReason: "SAFETY"  -> the OUTPUT was blocked. candidates[0].content is absent.
   promptFeedback.blockReason: "SAFETY"  -> the INPUT was blocked. There is no candidate at all.
   finishReason: "MAX_TOKENS" -> truncated. NOT an error, but the answer is incomplete —
                                 shipping it to a customer as-is is a quality defect.
   ```

   Any production wrapper must branch on all four. An application that renders `.candidates[0].content.parts[0].text` unconditionally will throw a null‑pointer exception the first time a filter fires.

3. 🆓 Prove the residency control. The region is in the hostname *and* in the resource path — the request cannot silently drift to another continent.

   ```bash
   echo "https://europe-west4-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/europe-west4/publishers/google/models/gemini-2.5-flash:generateContent"
   ```

   Read the ML processing and data‑residency commitments at
   <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations> and
   <https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance>.

4. 🆓 Enumerate the enterprise controls that come with the *platform* rather than with the *model*, and note which are exam‑relevant:

   ```yaml
   # responsible-ai-controls.yaml
   controls:
     - control: "Configurable safety filters (safetySettings)"
       protects_against: "harmful, harassing or explicit output reaching a customer"
       evidence: "safetyRatings on every response; finishReason=SAFETY when enforced"
     - control: "Grounding + citations"
       protects_against: "fabricated statements the company is then held to"
       evidence: "groundingMetadata.groundingChunks[].uri"    # Exercise 4
     - control: "Data governance commitment"
       protects_against: "customer prompts and data training a shared model"
       evidence: "https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance"
     - control: "Regional endpoints / data residency"
       protects_against: "cross-border transfer breaching GDPR or a sovereignty clause"
       evidence: "the region appears in the hostname AND the resource name"
     - control: "IAM + VPC Service Controls perimeter"
       protects_against: "exfiltration of prompts and corpora via the AI API"
       evidence: "gcloud access-context-manager perimeters describe ..."
     - control: "CMEK"
       protects_against: "loss of key custody"
       evidence: "encryptionSpec.kmsKeyName on the resource"
     - control: "Cloud Audit Logs"
       protects_against: "'who asked the model what, and when' being unanswerable"
       evidence: "Data Access logs, once explicitly enabled"
     - control: "SynthID watermarking on generated media"
       protects_against: "generated assets being indistinguishable from real ones"
       evidence: "https://deepmind.google/technologies/synthid/"

   the_argument:
     - "None of these controls are properties of the MODEL. They are properties of the PLATFORM."
     - "This is the concrete reason an enterprise pays for Vertex AI rather than calling a raw model API:
        it inherits the same IAM, VPC-SC, CMEK, audit logging and residency model as the rest of its cloud."
   ```

### Comprehension check — Exercise 6

- **Q23.** `finishReason: "SAFETY"` and `promptFeedback.blockReason: "SAFETY"` are different events. Describe the user‑visible behaviour of each, and the distinct product decision each one forces on you.
- **Q24.** The Risk Committee asks for "zero possibility of a harmful output." Explain why `BLOCK_LOW_AND_ABOVE` on every category is not a costless answer, and name the trade‑off you are actually managing.
- **Q25.** From `responsible-ai-controls.yaml`, pick the three controls that would appear in a *procurement* questionnaire rather than an engineering design doc, and justify each in one line.
- **Q26.** A competitor offers a slightly better benchmark score with none of these controls. Construct the argument a Digital Leader makes to the board — without claiming the competitor's model is worse.

---

## Exercise 7 — Prove the value: measure tokens, spend and quota

**Business scenario.** Six months in, the CFO asks for cost per outcome — not total AI spend. If you cannot produce it, the budget is cut by default.

**What you will prove.** That consumption is measurable at three levels — per call, per project, per SKU — and that this is what makes an AI programme defensible at renewal.

### Steps

1. 💵 Every generative call already tells you its own cost basis. Capture it.

   ```bash
   curl -s -X POST \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/google/models/gemini-2.5-flash:generateContent" \
     -d '{"contents":[{"role":"user","parts":[{"text":"Summarise this ticket in one line: customer reports intermittent fibre dropouts every evening after 20:00."}]}]}' \
     | jq '.usageMetadata'
   ```

   ```json
   {
     "promptTokenCount": 26,
     "candidatesTokenCount": 19,
     "totalTokenCount": 45
   }
   ```

   > **The unit of AI cost is the token, and the token count is returned on every single call.** Log `usageMetadata` alongside your own business key (ticket ID, customer, department) and you have cost attribution by construction — no allocation model needed.

2. 🆓 Confirm the platform metrics exist for dashboarding and alerting.

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/metricDescriptors?filter=metric.type%3Dstarts_with(%22aiplatform.googleapis.com%2Fpublisher%22)" \
     | jq -r '.metricDescriptors[] | "\(.type)\t\(.metricKind)/\(.valueType)"'
   ```

   Representative output:

   ```
   aiplatform.googleapis.com/publisher/online_serving/token_count            DELTA/INT64
   aiplatform.googleapis.com/publisher/online_serving/model_invocation_count DELTA/INT64
   aiplatform.googleapis.com/publisher/online_serving/first_token_latencies  DELTA/DISTRIBUTION
   ```

3. 🆓 Check your quota — the constraint that will actually stop a launch, and the one most often discovered on go‑live day.

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "X-Goog-User-Project: ${PROJECT_ID}" \
     "https://cloudquotas.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/services/aiplatform.googleapis.com/quotaInfos?pageSize=200" \
     | jq -r '.quotaInfos[] | select(.metricDisplayName | test("token|request"; "i"))
              | "\(.quotaDisplayName)\t\(.quotaId)"' | head
   ```

   ```
   Online prediction requests per minute per region       OnlinePredictionRequestsPerMinutePerRegion
   Generate content requests per minute per base model    ...
   ```

4. 💵 Wire billing to BigQuery and write the query that answers the CFO. Enable the export once (Console: **Billing → Billing export → BigQuery export**), then:

   ```sql
   -- ai-spend-by-service.sql — run after 24h of export data
   SELECT
     service.description                      AS service,
     sku.description                          AS sku,
     project.id                               AS project,
     FORMAT_DATE('%Y-%m', DATE(usage_start_time)) AS month,
     ROUND(SUM(cost), 2)                      AS cost,
     ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS credits,
     ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS net_cost,
     SUM(usage.amount)                        AS usage_amount,
     ANY_VALUE(usage.unit)                    AS usage_unit
   FROM `PROJECT.DATASET.gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX`
   WHERE service.description IN ('Vertex AI', 'Document AI', 'Cloud Vision API', 'Dialogflow')
     AND DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
   GROUP BY service, sku, project, month
   ORDER BY net_cost DESC;
   ```

   Representative result shape:

   ```
   +------------+----------------------------------+-----------+---------+--------+---------+----------+--------------+-------------------+
   | service    | sku                              | project   | month   | cost   | credits | net_cost | usage_amount | usage_unit        |
   +------------+----------------------------------+-----------+---------+--------+---------+----------+--------------+-------------------+
   | Vertex AI  | Gemini ... Output Token ...      | cdl-ai-.. | 2026-09 |  12.41 |  -12.41 |     0.00 |      412000  | thousand tokens   |
   | Vertex AI  | Gemini ... Input Token ...       | cdl-ai-.. | 2026-09 |   3.07 |   -3.07 |     0.00 |     1024000  | thousand tokens   |
   | Document AI| Invoice Parser ...               | cdl-ai-.. | 2026-09 |   0.60 |   -0.60 |     0.00 |           6  | page              |
   +------------+----------------------------------+-----------+---------+--------+---------+----------+--------------+-------------------+
   ```

5. 🆓 Assemble the sentence the CFO actually wants:

   ```yaml
   # cost-per-outcome.yaml
   metric: "net AI cost per successfully automated outcome"
   formula: "net_cost_from_billing_export / count_of_outcomes_from_application_logs"
   worked_example:
     process: "invoice straight-through processing"
     invoices_auto_approved_this_month: 32800
     net_ai_cost_this_month: 5320
     cost_per_automated_invoice: 0.162
     manual_cost_per_invoice: 0.503
     saving_per_invoice: 0.341
     monthly_saving: 11185
   why_this_metric_wins_the_budget_argument:
     - "'We spent 5,320 on AI' invites a cut."
     - "'We spent 0.162 to avoid 0.503, 32,800 times' invites an increase in volume."
     - "It also tells you WHEN TO STOP: if cost_per_automated_invoice ever exceeds
        manual_cost_per_invoice, the automation should be switched off. Very few
        AI programmes define that exit condition. Yours now does."
   ```

6. 🆓 Cleanup the whole lab.

   ```bash
   bq rm -r -f -d "${PROJECT_ID}:cdl_ai"
   bq rm --connection --force "${PROJECT_ID}.US.cdl_ai_conn"
   gcloud projects delete "$PROJECT_ID"
   ```

### Comprehension check — Exercise 7

- **Q27.** Step 1 returned `promptTokenCount` and `candidatesTokenCount` separately. Why does that split matter commercially, and what does it imply about a prompt that stuffs a 40‑page document into context on every request?
- **Q28.** In step 4 `net_cost` is 0.00 while `cost` is 12.41. Explain what happened, and the trap this creates for a pilot that is judged on its billing export.
- **Q29.** The quota in step 3 is per minute, per region, per model. Describe a launch‑day failure this causes and the two ways to prevent it before it happens.
- **Q30.** `cost-per-outcome.yaml` defines an *exit condition*. Argue why including a kill criterion strengthens rather than weakens the funding request.

---

## Synthesis — the exam‑shaped summary

Fill this in from memory before you read the answers. Every row is a question the CDL exam asks in some form.

| Business need | Google Cloud offering | Layer | Unit of value |
|---|---|---|---|
| Extract fields from invoices, no ML team | | | |
| Predict churn where the data already lives | | | |
| Answer customer questions from *our* documents, with citations | | | |
| Deflect tier‑1 contact‑centre volume in three languages | | | |
| Try a third‑party or open model without leaving our governance perimeter | | | |
| Raise developer throughput on existing codebases | | | |
| Let staff search and act across internal enterprise data | | | |
| Train a frontier model ourselves | | | |

- **Q31.** Complete the table.

---

<details>
<summary><strong>Answers</strong> — attempt every question before opening</summary>

### Exercise 0

**Q1.** It demonstrates **consumption‑based (pay‑per‑use) pricing with no upfront commitment and no per‑service licence**. The business consequence: three departments can pilot in parallel at genuinely zero cost until they generate traffic, so the decision to experiment no longer requires a capital request or a procurement cycle. The constraint moves from *budget approval* to *engineering attention*, which is a far shorter loop. The corollary — and the thing to warn the CFO about — is that cost then scales with success rather than being capped by a licence, so a runaway job or an unbounded prompt is now a financial event. Budget alerts and quota limits are the compensating control (Exercise 7).

**Q2.** **Layer 4 (agents and applications)** — Conversational Agents / Customer Engagement Suite, grounded on a Vertex AI Search data store over their existing help‑centre content. At layer 1 the two‑person team would be spending the quarter on: provisioning and quota‑securing GPU/TPU capacity, selecting and hosting a base model, building a serving stack with autoscaling and health checks, building safety filtering, building retrieval, and building observability — none of which is the chatbot, and all of which Google already operates. They would very likely reach the end of the quarter with infrastructure and no product.

**Q3.** *Counter‑argument:* Model Garden shows first‑party (Gemini), Google open (Gemma), third‑party commercial and open‑weight models all addressable through the **same platform, the same IAM, the same VPC‑SC perimeter and the same billing**. The model is a swappable component behind a stable interface, so switching models is a config change, not a re‑platforming. *The legitimate part:* the lock‑in is not at the model layer, it is at the **platform and data‑gravity layer** — your grounding data stores, evaluation harnesses, pipelines, tuning artifacts, IAM policy and BigQuery corpus. Migrating those is real work. The honest position is: model portability is high, platform portability is moderate, and that is a deliberate trade you are making in exchange for the governance controls in Exercise 6.

### Exercise 1

**Q4.** Per‑hour SKUs bill for **existence**; per‑token SKUs bill for **use**. A dedicated prediction endpoint costs the same at 03:00 with zero requests as it does at peak — so with spiky, unpredictable traffic you pay for the peak's capacity across all 168 hours of the week and your unit cost per prediction becomes a function of your idle time. A per‑token API costs exactly zero at zero traffic and scales linearly with demand. A startup with no traffic yet should unambiguously prefer the per‑token/per‑call model: it converts a fixed cost into a variable one and removes the need to forecast demand it cannot forecast. The crossover comes at high, *steady, predictable* volume, where dedicated capacity (or Provisioned Throughput) can beat per‑token pricing on unit economics.

**Q5.** **Data labelling** — sourcing, labelling, adjudicating and continuously re‑labelling thousands of domain‑specific images, plus the subject‑matter‑expert time to define the taxonomy in the first place. It is paid in staff time or to a labelling vendor, it recurs whenever the taxonomy or the product line changes, and it appears nowhere on the cloud invoice. It routinely exceeds the training compute cost by an order of magnitude and is the single most common reason custom‑model projects slip.

**Q6.** Because it converts "is the AI good enough?" from a recurring subjective argument into a **pre‑agreed, measurable exit condition**. Defined before launch, it is a neutral engineering threshold; defined after launch, whoever proposes it is implicitly attacking or defending the project, and the discussion becomes political. It also means the *monitoring for it* gets built as part of v1 rather than being retrofitted, so the trigger can actually fire.

### Exercise 2

**Q7.** *Financial:* no egress charges, no second copy of a multi‑terabyte dataset to store, and no ETL pipeline to build and operate — the pipeline is the largest recurring engineering cost avoided. *Operational:* no synchronisation lag or drift between the warehouse and the ML copy; the model trains on exactly the data the business reports on, which eliminates the "the dashboard and the model disagree" class of incident. *Regulatory:* the data never crosses a trust or jurisdictional boundary, so the existing BigQuery access controls, column‑level security, row‑level security, audit logs and residency guarantees continue to apply unchanged — no new system needs to be assessed, certified or added to the data map.

**Q8.** The project no longer requires hiring ML engineers or retraining the analytics team in Python; the **existing SQL‑fluent analysts become the ML delivery team**. In CFO terms: it removes a hiring dependency from the critical path (an ML engineer search runs months in a competitive market), eliminates the salary premium and the ramp‑up period, and removes the key‑person risk of a one‑ML‑engineer team. The project's start date moves from "when we hire" to "next sprint."

**Q9.** Examples: (a) automatic triage and routing of inbound support tickets by sentiment and topic, so escalations reach a supervisor without a human reading the queue; (b) churn early‑warning by scoring free‑text call notes and chat transcripts at scale — signal that was previously unreadable because nobody could read a million notes; (c) automated summarisation of field technician reports into structured fault codes. You were operating at **layer 2/3** consumed through the data platform — calling a foundation model through a managed platform, with no model of your own.

**Q10.** `roc_auc ≈ 0.87` says the model *ranks* customers well. `precision ≈ 0.63` says that of everyone the model flags, roughly 37% are false positives — at €40 per contact, that is roughly €15 of spend per flagged customer producing nothing. Whether that is a good trade depends entirely on the margin of a conversion and the cost of a missed one, which is a commercial judgement, not a model metric. The right move is to use the model's *probability* rather than its label: rank the base, contact from the top down, and stop where marginal expected revenue equals €40. That also reframes the conversation — the model does not decide who to contact, it decides the *order*, and the business sets the cut‑off.

### Exercise 3

**Q11.** *Rule:* auto‑post the invoice when every field required for posting clears the confidence threshold **and** the extracted line items sum to the extracted total; otherwise route to a human with the low‑confidence fields highlighted. "Approve everything at 97%" is wrong because 97% confidence across, say, six required fields still leaves a meaningful compound probability of at least one field being wrong, and the errors are **not evenly distributed in cost** — a wrong `total_amount` on a €400,000 invoice is a materially different event from a wrong line‑item description. Confidence is per‑field and uniform; business impact is per‑field and wildly non‑uniform. The threshold must therefore be set per field by value at risk, and paired with an independent arithmetic cross‑check that catches errors the model is confidently wrong about.

**Q12.** **`expected_auto_approval_rate` (0.82).** Every saving in the model is multiplied by it, and it is the only figure that depends on the messiness of *this company's* supplier documents — Google cannot supply it and no benchmark substitutes for it. Cheapest experiment: run 300–500 of the company's own real invoices, spanning their actual supplier mix, through the processor and count how many clear the threshold with correct values. That costs a few euros of API calls and a day of a clerk's time spot‑checking, and it converts the largest assumption in the business case into a measured number.

**Q13.** The specialised `INVOICE_PROCESSOR` is pre‑trained on the invoice *concept* — it already knows what `due_date`, `supplier_name` and `total_amount` mean across arbitrary layouts from suppliers you have never seen, with **zero training data and zero labelling**. A custom model would require labelling thousands of documents to reach the same baseline, and would generalise worse to a new supplier's template. `CUSTOM_EXTRACTION_PROCESSOR` becomes correct when the document is **proprietary or industry‑specific with fields no general processor models** — a bespoke bill of lading, a regulator's return, an internal claim form — i.e. when there is genuinely no pre‑trained equivalent of the concept you need extracted.

**Q14.** Because the region determines **where the document is processed and stored**, and that determines whether the deployment is lawful in the target market — GDPR and sector or sovereignty requirements can make `us` a non‑starter for EU personal data regardless of price or accuracy. A control that decides *whether you can sell in a market at all* is a business‑value control: it is the difference between a solution that ships to the whole company and one that stops at the border of a major region. It is also a procurement gate — the residency answer is required before contract, not after design.

### Exercise 4

**Q15.** The response gained `groundingMetadata` — `groundingChunks[].uri` (the source documents) and `groundingSupports` (which spans of the answer are backed by which source). The prompt, the model and the temperature were identical. A compliance officer signs off on that because it makes the answer **auditable after the fact**: when a customer disputes what the assistant told them, the company can reconstruct which document the statement came from and which version was live. It converts an unfalsifiable model output into evidence, and it makes the failure mode reviewable rather than invisible.

**Q16.** "I could not find that" is a **safe, bounded, correctable** failure; a confident invention is an **unbounded liability**. The ungrounded version did not answer more questions — it answered the same questions plus some it answered *wrongly*, indistinguishably. Furthermore, every "not found" is free product telemetry: it names a real customer question the knowledge base does not cover, so the gap list writes itself and each fix is a document edit. The regression is that the coverage gap became *visible*; it was always there.

**Q17.** (a) Fine‑tuning: needs a curated training set, a tuning job, evaluation against regressions, a deployment, and a rollback plan — days to weeks, real cost, and it must be repeated for the *next* price change. It also risks degrading unrelated behaviour. (b) Updating the data store: re‑index the new pricing document — minutes, negligible cost, immediately reversible by re‑indexing the previous version. **Grounding must be the default operating model** because pricing, policy and catalogue are *volatile facts*, and volatile facts belong in retrievable documents, not baked into weights. Reserve tuning for changing the model's *behaviour* — tone, output format, domain style, task adherence — which is stable over time.

**Q18.** **Layer 4 (agents and applications)**, sitting on layer 3 platform services. In 2019 an enterprise wanting the same capability would have had to build and operate: a document ingestion and parsing pipeline, a chunking strategy, an embedding model, a vector index with its own scaling and re‑indexing story, a retrieval and re‑ranking layer, relevance tuning, access‑control propagation from the source systems into the index, and the serving infrastructure for all of it — a multi‑team, multi‑quarter platform effort, and one that most companies did badly. It is now a managed resource created with one API call, which is the clearest single illustration of what "AI creates business value by collapsing time‑to‑value" concretely means.

### Exercise 5

**Q19.** **Provisioning the platform is free and instant; the cost and the risk are in the domain knowledge, the flow design, the grounding corpus and the backend integrations.** The generalisable rule: for enterprise AI, the vendor supplies the *capability*, the enterprise supplies the *context*, and the context is the expensive half. Any plan, budget or timeline that treats "adopt the AI service" as the project has mis‑sized the work by an order of magnitude — and any vendor comparison decided on provisioning speed is comparing the cheapest part.

**Q20.** Without it, the team is rewarded for **preventing escalation rather than resolving problems**. Containment rate rises fastest by making the human path hard to reach — burying the "talk to an agent" option, long deflection loops, refusing to escalate — which drives containment up and customer satisfaction, retention and complaint volume in the wrong direction. The guardrail forces containment to be earned by *resolving* the contact, which is the outcome the business actually wanted when it approved the project. It is the standard Goodhart failure: the metric stops being a proxy for the goal the moment it becomes the target.

**Q21.** *Value statement:* "Entering two new markets requires no new contact‑centre vendor, no new staffing pool, and no new out‑of‑hours rota for tier‑1 contacts — the same agent configuration serves all three languages 24/7, so the marginal cost of the third market's tier‑1 support is close to zero." *What it does not remove:* the need for **native‑speaker review of the flows and the grounding content**, market‑specific legal and regulatory phrasing, local escalation paths to humans who speak the language, and localised business rules (billing cycles, consumer‑protection wording, holidays). Machine translation of an interface is not localisation of a service.

**Q22.** The second. A board funds **business outcomes**, not technology adoption — "we deployed a chatbot" is unfalsifiable and has no follow‑on ask attached, while "we contained 35% of tier‑1 contacts at flat CSAT" is measurable, comparable quarter over quarter, and implies its own next step (raise to 50%, extend to tier 2, add a market). The general lesson: **frame every AI investment by the business metric it moves and the guardrail that proves it did not move something else the wrong way.** Technology named in a board statement is a smell that nobody measured the outcome.

### Exercise 6

**Q23.** `finishReason: "SAFETY"` — the model generated a response and the *output* was blocked; there is no usable text in the candidate, but the request itself was legitimate. User‑visible: the assistant appears to hang or return nothing. Product decision: you need a graceful fallback response and, usually, an escalation path — the user asked a fair question and deserves an answer from somewhere. `promptFeedback.blockReason: "SAFETY"` — the *input* was blocked before generation; there is no candidate at all. User‑visible: an immediate refusal. Product decision: this is about the user's own input, so it belongs in your abuse/misuse handling — count it, rate‑limit repeat offenders, and do not offer a retry that simply re‑submits the same prompt. Confusing the two produces either an application crash (dereferencing an absent candidate) or an abuse path treated as a system error.

**Q24.** Maximum filtering raises **false positives** — legitimate business content gets blocked. An insurer discussing self‑harm coverage, a pharmacy discussing overdose thresholds, a security team discussing an attack technique, a bank discussing fraud: all are ordinary domain conversation that aggressive `DANGEROUS_CONTENT` settings will suppress. Every false positive is a failed customer interaction and, at volume, a product that staff route around. The trade‑off you are managing is **harm risk versus utility**, and the correct answer is not a global maximum but a per‑use‑case setting: strict on a public, unauthenticated, consumer‑facing surface; more permissive on an internal, authenticated, logged tool used by trained staff — with the *grounding* and *audit* controls, not the filter, doing the heavy lifting in the second case. Also note that filters govern *harmfulness*, not *accuracy*: they will never block a polite, confident falsehood, which is why Exercise 4 exists.

**Q25.** (1) **Data governance commitment** — "is our data used to train your models?" is on every enterprise procurement questionnaire and a wrong answer ends the deal. (2) **Data residency / regional endpoints** — required to answer the GDPR and sovereignty section and to complete a data‑transfer impact assessment. (3) **CMEK** — key custody is a standard control‑framework requirement in regulated sectors (finance, health, public), often mandated by the customer's own regulator. The others (safety filters, grounding, IAM/VPC‑SC configuration, audit log detail) are design‑time engineering choices; these three are contractual properties of the provider that a buyer verifies before signing.

**Q26.** The argument is not "their model is worse" — concede the benchmark. It is that **a benchmark score is not the deployable unit**. What ships to customers is a *system*, and the system's cost is dominated by the controls around the model: residency, IAM integration, VPC‑SC, CMEK, audit logging, safety configuration, grounding, evaluation and SLA. Choosing the higher‑scoring model means the enterprise builds and then *operates and certifies* those controls itself, at its own risk, on its own liability, forever — and must re‑certify them at the next audit. Add that the model layer is the most rapidly commoditising and most easily swapped part of the stack (Model Garden, Q3), so today's benchmark lead is the least durable thing being compared. The decision is therefore between a marginal, perishable quality gain and a permanent, compounding governance cost — and the board is being asked to approve the *system*, not the leaderboard.

### Exercise 7

**Q27.** Input and output tokens are priced differently, and output is typically the more expensive of the two — so the *shape* of a workload, not just its volume, determines its cost. A prompt that stuffs a 40‑page document into context on every request pays that input cost on **every single call**, forever, for content that never changes. That is the economic argument for retrieval (send only the relevant passages, per Exercise 4) and for context caching (pay once for a shared prefix rather than per request). It also explains a counterintuitive result teams hit in production: a "cheap" summarisation feature can cost more than a "expensive" generation feature purely because of context size.

**Q28.** Free trial credits (or committed‑use/promotional credits) offset the gross `cost` to a `net_cost` of zero. The trap: a pilot judged on its billing export appears to cost **nothing**, so nobody builds a cost model, nobody sets the per‑outcome metric, and the unit economics are never tested — and then the credits expire, the true cost appears at production volume, and the programme faces an emergency review with no baseline to defend itself. Always evaluate a pilot on **gross `cost`** and treat credits as a separate, temporary line. This is exactly why the query returns `cost`, `credits` and `net_cost` as three columns rather than one.

**Q29.** *Failure:* the marketing launch drives traffic well above the pilot's rate; the per‑minute per‑region per‑model quota is exceeded and the service returns `429 RESOURCE_EXHAUSTED` at exactly the moment of maximum visibility. Because the quota is per *model*, a last‑minute switch to a newer model can also silently move you onto a different, lower quota bucket. *Prevention:* (1) Request a quota increase in advance, sized from a load test at projected peak — not average — and remember that increases take time to be reviewed, so this is a launch‑checklist item, not a launch‑day one. (2) Build backpressure into the client: exponential backoff with jitter, a request queue, graceful degradation to a cached or simpler response, and a Cloud Monitoring alert on the token/invocation metrics from step 2 firing well below the ceiling. For predictable high‑volume workloads, Provisioned Throughput reserves capacity instead of competing for shared quota.

**Q30.** Because it demonstrates that the request is a **business case rather than an enthusiasm**, and it changes who carries the risk. A funder's unstated fear is an initiative that can never be killed because no one agreed what failure looks like; a pre‑declared kill criterion removes that fear and makes approval cheaper. It also disciplines the team — the metric must actually be instrumented for the criterion to be checkable, so measurement gets built. And in the common case where the metric is comfortably met, the exit condition becomes the strongest possible evidence at renewal: the project was continuously tested against a standard it could have failed, and did not.

### Synthesis

**Q31.**

| Business need | Google Cloud offering | Layer | Unit of value |
|---|---|---|---|
| Extract fields from invoices, no ML team | **Document AI** (specialised pre‑trained processors) | 4 | per page processed → per invoice auto‑posted |
| Predict churn where the data already lives | **BigQuery ML** (+ Vertex AI for MLOps at scale) | 3 | per query/slot; no data movement |
| Answer customer questions from *our* documents, with citations | **Vertex AI Search** + grounded Gemini (Vertex AI Agent Builder / RAG Engine) | 4 on 3 | per query, with an auditable citation |
| Deflect tier‑1 contact‑centre volume in three languages | **Conversational Agents (Dialogflow CX) / Customer Engagement Suite (CCaaS)** | 4 | per contained session (containment rate) |
| Try a third‑party or open model without leaving our governance perimeter | **Model Garden on Vertex AI** | 2 via 3 | per token or per deployed endpoint‑hour |
| Raise developer throughput on existing codebases | **Gemini Code Assist / Gemini for Google Cloud** | 4 | per seat → delivery throughput and change lead time |
| Let staff search and act across internal enterprise data | **Google Agentspace** | 4 | per seat → hours of search and hand‑off avoided |
| Train a frontier model ourselves | **AI Hypercomputer** — TPU / GPU capacity, Cluster Director | 1 | per accelerator‑hour or committed capacity |

The pattern to carry into the exam: **read the constraint in the question — team skills, calendar time, data location, regulatory exposure — and pick the highest layer that satisfies it.** Almost every wrong answer in this domain is a solution built one or more layers lower than the question required.

</details>

---

## Official sources

- Cloud Digital Leader exam guide — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Google Cloud AI and ML products — <https://cloud.google.com/products/ai>
- Vertex AI introduction — <https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform>
- Model Garden — <https://cloud.google.com/vertex-ai/generative-ai/docs/model-garden/explore-models>
- Gemini models and versioning/retirement — <https://cloud.google.com/vertex-ai/generative-ai/docs/models>
- Generative AI locations and data residency — <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations>
- Generative AI data governance — <https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance>
- Configure safety filters — <https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/configure-safety-filters>
- Grounding overview — <https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview>
- Vertex AI Search / Agent Builder — <https://cloud.google.com/generative-ai-app-builder/docs/introduction>
- BigQuery ML introduction — <https://cloud.google.com/bigquery/docs/bqml-introduction>
- `ML.GENERATE_TEXT` — <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-generate-text>
- Document AI overview and processor list — <https://cloud.google.com/document-ai/docs/overview>
- Document AI pricing — <https://cloud.google.com/document-ai/pricing>
- Conversational Agents (Dialogflow CX) — <https://cloud.google.com/dialogflow/cx/docs>
- Customer Engagement Suite — <https://cloud.google.com/solutions/customer-engagement-ai>
- Google Agentspace — <https://cloud.google.com/products/agentspace>
- Gemini for Google Cloud — <https://cloud.google.com/products/gemini>
- AI Hypercomputer — <https://cloud.google.com/ai-hypercomputer/docs/overview>
- Responsible AI on Vertex AI — <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/responsible-ai>
- Cloud Billing Catalog API — <https://cloud.google.com/billing/docs/reference/rest/v1/services.skus/list>
- Billing export to BigQuery — <https://cloud.google.com/billing/docs/how-to/export-data-bigquery>
- Cloud Quotas API — <https://cloud.google.com/docs/quotas/api-overview>
- VPC Service Controls with Vertex AI — <https://cloud.google.com/vertex-ai/docs/general/vpc-service-controls>