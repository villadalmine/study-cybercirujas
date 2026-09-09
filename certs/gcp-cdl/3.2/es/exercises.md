# Tema 3.2 — Ejercicios Guiados

## Explicar cómo las ofertas de IA de Google Cloud pueden crear valor de negocio

**Certificación:** Google Cloud Digital Leader (versión del examen 2026-08-12) · **Peso en el examen:** 9.0
**Guía oficial del examen:** <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>

---

### Cómo usar este laboratorio

El examen Cloud Digital Leader no es un examen de programación, pero las preguntas las escribe gente que ha puesto estos servicios en producción. La forma más rápida de responder correctamente *"¿qué oferta de IA de Google Cloud crea valor acá?"* es haber visto alguna vez al servicio responderte, haber visto su factura y haberlo visto fallar. Eso es lo que hacen estos ejercicios: cada afirmación sobre la que te van a preguntar en el examen se convierte en un comando que ejecutás y una salida que inspeccionás.

**Reglas de enfrentamiento**

| Regla | Por qué |
|---|---|
| Nunca confíes en un precio que recordás. Consultalo. | Los precios de las SKU de Google Cloud cambian; el examen evalúa el *modelo* (pago por uso, sin pago inicial), no el número. |
| Nunca confíes en un ID de modelo que recordás. Listalo. | Los IDs de los modelos Gemini están versionados y se retiran según un calendario publicado. |
| Fijá la región en cada llamada de IA. | La residencia de datos es un argumento de valor de negocio y de cumplimiento, no un detalle. |
| Borrá lo que creás. | Varios recursos de este laboratorio facturan por hora de existencia, no por llamada. |

**Costo:** el laboratorio completo cuesta bastante menos de **US$5** si seguís los pasos de limpieza. Los pasos que facturan están marcados con 💵. Los pasos gratuitos están marcados con 🆓. Las cuentas nuevas tienen créditos gratuitos; varias APIs también tienen una capa gratuita mensual perpetua.

---

## Ejercicio 0 — Bootstrap: el entorno y el mapa mental

**Escenario de negocio.** Un CFO te pregunta: *"Todo el mundo nos quiere vender IA. ¿Qué le estamos comprando realmente a Google, y en qué capa?"* Antes de poder responder eso, necesitás un proyecto donde las APIs de IA estén activadas.

**Qué vas a demostrar.** Que el portafolio de IA de Google Cloud es una **pila de cuatro capas**, que podés comprar en cualquiera de ellas, y que la capa en la que comprás es el mayor factor que determina el costo, el tiempo hasta obtener valor y las habilidades requeridas.

### Pasos

1. Configurá tus variables de trabajo. Usá un **proyecto dedicado** para que la exportación de facturación del Ejercicio 8 quede limpia.

   ```bash
   export PROJECT_ID="cdl-ai-lab-$(date +%s | tail -c 6)"
   export REGION="us-central1"
   export BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"   # gcloud billing accounts list

   gcloud projects create "$PROJECT_ID" --name="CDL AI Lab"
   gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
   gcloud config set project "$PROJECT_ID"
   gcloud config set ai/region "$REGION"
   ```

2. 🆓 Activá las APIs de cada capa de la pila que vas a tocar.

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

   Salida esperada:

   ```
   Operation "operations/acat.p2-472...-a1b2c3d4-..." finished successfully.
   ```

3. 🆓 Confirmá qué quedó activado. Activar una API no cuesta nada — **se te factura por unidad de consumo, no por servicio activado.** Este es el primer hecho de valor de negocio del tema.

   ```bash
   gcloud services list --enabled --format="table(config.name)" | grep -E "aiplatform|documentai|discoveryengine"
   ```

   ```
   CONFIG.NAME
   aiplatform.googleapis.com
   discoveryengine.googleapis.com
   documentai.googleapis.com
   ```

4. 🆓 Ahora dibujá el mapa. Escribí este archivo — lo vas a seguir anotando a medida que avanza el laboratorio. Es la respuesta a la pregunta del CFO.

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

5. 🆓 Verificá que la capa 2 sea real y no marketing: listá lo que realmente se ofrece en Model Garden.

   ```bash
   gcloud ai model-garden models list --limit=15
   ```

   Salida representativa (el catálogo cambia continuamente — precisamente por eso lo listás en vez de memorizarlo):

   ```
   MODEL_ID                                    SUPPORTED_ACTIONS
   google/gemini@gemini-2.5-flash              openOrderedDeploy, openNotebook
   google/gemma3@gemma-3-27b-it                openOrderedDeploy, openNotebook
   anthropic/claude@claude-...                 openOrderedDeploy
   meta/llama3@llama-3...                      openOrderedDeploy, openNotebook
   ...
   ```

   > **Leé esto como un hecho de negocio, no como una lista.** Model Garden significa que el modelo es un *componente reemplazable*. Un modelo propio de Google, un modelo abierto que hospedás vos mismo y un modelo de terceros están todos detrás de la misma plataforma, el mismo IAM, el mismo perímetro de VPC Service Controls y la misma facturación. Eso es lo que significa concretamente "evitar el lock-in de modelo", y es un tema recurrente en el examen CDL.

### Verificación de comprensión — Ejercicio 0

- **Q1.** Activar `aiplatform.googleapis.com` no generó ningún cargo. Enunciá el modelo de precios que esto demuestra y nombrá una consecuencia de negocio para una empresa que quiere *pilotear* IA en tres departamentos a la vez.
- **Q2.** Un retailer quiere un chatbot en su sitio de soporte dentro de un trimestre, con un equipo de dos personas y sin ingenieros de ML. ¿En qué capa de `ai-stack-map.yaml` debería comprar, y en qué específicamente estaría gastando tiempo de calendario si eligiera la capa 1?
- **Q3.** Tu CTO dice: "Si nos estandarizamos en Gemini quedamos atados a Google". Usando solamente lo que imprimió el paso 5, dá el contraargumento — y después enunciá la parte de la preocupación por el lock-in que sí es *legítima*.

---

## Ejercicio 1 — Construir vs. comprar: API preentrenada, modelo ajustado o modelo propio

**Escenario de negocio.** Una aseguradora quiere etiquetar automáticamente las fotografías que se suben con los siniestros. Hay tres opciones sobre la mesa: llamar a una API preentrenada, entrenar un modelo propio en Vertex AI con sus imágenes etiquetadas, o construir desde cero. Cada una tiene una curva de costo distinta y un punto de equilibrio distinto.

**Qué vas a demostrar.** Que la API preentrenada devuelve salida útil en un solo comando con **cero datos de entrenamiento y cero habilidad de ML**, y que esto fija el *listón* que toda opción propia debe superar.

### Pasos

1. 💵 Llamá a la Vision API preentrenada sobre una imagen pública. Sin modelo, sin entrenamiento, sin endpoint.

   ```bash
   gcloud ml vision detect-labels gs://cloud-samples-data/vision/label/setagaya.jpeg
   ```

   Salida representativa (abreviada):

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

2. 🆓 Anotá los dos números que le importan al negocio, y de dónde salieron:

   ```text
   Time from zero to first prediction : ~1 command  (minutes)
   Labelled training images required  : 0
   Data scientists required           : 0
   Confidence signal available        : yes — "score", per label
   ```

   El campo `score` es el gancho de todo el argumento construir/comprar: te permite armar un **umbral de confianza y un fallback con humano en el circuito** sin ningún trabajo de modelado. Las predicciones de alta confianza se procesan automáticamente; las de baja confianza se derivan a una persona.

3. 🆓 Ahora cuantificá la alternativa. Consultá los precios *reales y actuales* en vez de citar un número — esta es la técnica, y es una conducta evaluable para un Digital Leader.

   ```bash
   export API_KEY="$(gcloud services api-keys create --display-name=cdl-catalog \
     --format='value(response.keyString)')"

   # 1. find the service ID for Vertex AI in the public price catalogue
   curl -s "https://cloudbilling.googleapis.com/v1/services?key=${API_KEY}&pageSize=200" \
     | jq -r '.services[] | select(.displayName | test("Vertex AI|Cloud Vision|Document AI"))
              | "\(.serviceId)\t\(.displayName)"'
   ```

   Salida representativa:

   ```
   C1F7-477B-6E67   Cloud Vision API
   93D7-7A6C-...    Document AI
   6F81-5844-456A   Vertex AI
   ```

4. 💵 Traé las SKUs y leé la unidad de facturación. **La unidad es el modelo de negocio.**

   ```bash
   curl -s "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?key=${API_KEY}&pageSize=500" \
     | jq -r '.skus[]
              | select(.description | test("Gemini|Training|Prediction"; "i"))
              | "\(.description) | \(.category.usageUnitDescription)"' | head -20
   ```

   Salida representativa:

   ```
   Gemini ... Input Token ... | 1 thousand tokens
   Gemini ... Output Token ... | 1 thousand tokens
   Vertex AI Custom Training ... n1-standard-4 ... | hour
   Vertex AI Online Prediction ... | hour
   ```

5. 🆓 Escribí la decisión como código, para que pueda revisarse como cualquier otra decisión de arquitectura.

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

### Verificación de comprensión — Ejercicio 1

- **Q4.** En el paso 4 las SKUs de entrenamiento propio y de predicción online se facturan *por hora*, mientras que las SKUs de Gemini se facturan *por mil tokens*. Explicá la diferencia de flujo de caja para una carga de trabajo con tráfico irregular e impredecible, y decí qué opción debería preferir una startup que todavía no tiene tráfico.
- **Q5.** La API preentrenada no necesitó ninguna imagen etiquetada. Nombrá el costo de negocio que introduce un modelo propio que suele ser *mayor* que el costo de cómputo, y que nunca aparece en la factura de Google Cloud.
- **Q6.** El ADR fija un disparador en "confianza < 0.7 en más del 20% del tráfico". ¿Por qué definir ese disparador *antes* del lanzamiento es una mejora de gobernanza y no mera prolijidad?

---

## Ejercicio 2 — Llevar la IA a los datos: BigQuery ML

**Escenario de negocio.** Una telco tiene siete años de historial de abonados en BigQuery. El equipo de datos escribe SQL. La propuesta sobre la mesa es exportar los datos a una plataforma de ML separada. Necesitás mostrar cuánto cuesta esa exportación — y cuál es la alternativa.

**Qué vas a demostrar.** Que se puede entrenar, evaluar y servir un modelo de calidad productiva **sin que los datos salgan nunca de BigQuery**, usando solo SQL — reduciendo a cero el problema de movimiento, duplicación y gobernanza de datos.

### Pasos

1. 💵 Creá un dataset en una ubicación fija.

   ```bash
   bq --location=US mk --dataset "${PROJECT_ID}:cdl_ai"
   ```

   ```
   Dataset '<PROJECT_ID>:cdl_ai' successfully created.
   ```

2. 💵 Entrená un clasificador. Una sola sentencia. Los datos se quedan donde están.

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

3. 🆓 Evalualo. Al examen le importa que sepas que existe un paso de evaluación y que está separado del entrenamiento.

   ```bash
   bq query --use_legacy_sql=false '
   SELECT * FROM ML.EVALUATE(MODEL `cdl_ai.income_propensity`);'
   ```

   Salida representativa:

   ```
   +---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
   |      precision      |       recall        |      accuracy       |      f1_score       |      log_loss       |       roc_auc       |
   +---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
   | 0.6284...           | 0.8351...           | 0.7936...           | 0.7171...           | 0.4402...           | 0.8734...           |
   +---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
   ```

4. 🆓 Serví predicciones de la misma manera en que consultás una tabla — o sea que cualquier dashboard, reporte o consulta programada existente se convierte en consumidor de ML sin infraestructura nueva.

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

5. 💵 Ahora la mitad generativa. Registrá **Gemini como modelo remoto** dentro de BigQuery, para que las columnas de texto no estructurado se vuelvan consultables. Primero la conexión y su permiso IAM:

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

   > La propagación de IAM es de consistencia eventual. Esperá ~60 s antes del paso 6 o la primera llamada falla con `PERMISSION_DENIED`.

6. 💵 Creá el modelo remoto y ejecutá IA generativa **como una función SQL sobre una tabla**.

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

   > `ENDPOINT` nombra un modelo que está versionado y que eventualmente se retira. Verificá los identificadores actuales y sus fechas de retiro en <https://cloud.google.com/vertex-ai/generative-ai/docs/models> antes de dejarlo fijo en una consulta programada.

### Verificación de comprensión — Ejercicio 2

- **Q7.** Nada en este ejercicio sacó datos de BigQuery. Enumerá tres costos de negocio distintos que se evitan gracias a eso — uno financiero, uno operativo y uno regulatorio.
- **Q8.** El equipo de la telco escribe SQL, no Python. Cuantificá, en el vocabulario que entiende un CFO, qué cambió BigQuery ML respecto del requisito de *dotación de personal* de este proyecto.
- **Q9.** El paso 6 convirtió una columna de texto libre en una columna clasificada con un `SELECT`. Nombrá dos procesos de negocio de una telco que esto habilita, y decí en qué capa de `ai-stack-map.yaml` estabas operando.
- **Q10.** `ML.EVALUATE` reportó `roc_auc ≈ 0.87` pero `precision ≈ 0.63`. Explicale a un director de marketing por qué desplegar este modelo en una campaña que cuesta €40 por contacto sigue requiriendo una decisión de negocio, no solo de ingeniería.

---

## Ejercicio 3 — Comprar un resultado: Document AI y el cálculo de repago

**Escenario de negocio.** Una empresa de logística procesa a mano ~40.000 facturas de proveedores por mes. Dos administrativos, tres días del mes, más una tasa de error de tipeo del 4% que produce disputas de pago. El CFO quiere un período de repago, no una demo.

**Qué vas a demostrar.** Que un parser especializado preentrenado convierte un PDF no estructurado en campos tipados con puntaje de confianza sin ningún entrenamiento, y que podés calcular un punto de equilibrio defendible a partir de tarifas publicadas reales.

### Pasos

1. 💵 Creá un procesador Invoice Parser. Fijate en la ubicación `us` (o `eu`) — ese es tu control de **residencia de datos**.

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

2. 🆓 Listá los tipos de procesador disponibles para vos. Este es el catálogo de "comprar un resultado".

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

3. 💵 Procesá una factura de forma síncrona y leé las **entidades tipadas** — no texto crudo, sino `invoice_id`, `total_amount`, `supplier_name`, cada una con su confianza.

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

   Salida representativa:

   ```
   invoice_id        19482                       conf=0.9614
   invoice_date      2020-01-01                  conf=0.9421
   due_date          2020-02-01                  conf=0.9017
   supplier_name     Anderson & Sons             conf=0.8833
   total_amount      $2,300.00                   conf=0.9776
   currency          USD                         conf=0.9502
   line_item/...     Consulting services         conf=0.8321
   ```

4. 🆓 Armá el modelo de repago. **Consultá la tarifa, no la recuerdes** — abrí <https://cloud.google.com/document-ai/pricing> y sustituí el precio publicado actual por página para el Invoice Parser.

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

5. 🆓 Limpieza — mantener un procesador es gratis, pero borralo para que el proyecto quede inspeccionable.

   ```bash
   curl -s -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://${DOCAI_LOCATION}-documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${DOCAI_LOCATION}/processors/${PROCESSOR_ID}" \
     | jq '.metadata.commonMetadata.state'
   ```

   ```
   "RUNNING"
   ```

### Verificación de comprensión — Ejercicio 3

- **Q11.** El procesador emitió `total_amount ... conf=0.9776` y `line_item/... conf=0.8321`. Diseñá, en una oración, la regla operativa que convierte esos dos números en una política de *procesamiento directo sin intervención* — y explicá por qué "que la IA apruebe todo" es la respuesta equivocada incluso con 97% de confianza.
- **Q12.** En `payback-invoices.yaml`, ¿cuál es el único input que constituye la mayor fuente de error del caso de negocio, y cuál es el experimento más barato que elimina esa incertidumbre?
- **Q13.** La empresa también consideró entrenar un modelo de documentos propio. Dada la salida del paso 2, argumentá a favor del procesador especializado preentrenado — y nombrá la única circunstancia en la que `CUSTOM_EXTRACTION_PROCESSOR` pasa a ser la opción correcta.
- **Q14.** ¿Por qué la elección entre `us` y `eu` en el hostname del endpoint pertenece a una discusión de *valor de negocio* y no solo a una revisión de arquitectura?

---

## Ejercicio 4 — Grounding: convertir una respuesta plausible en una defendible

**Escenario de negocio.** Legales bloqueó el asistente de cara al cliente. Su objeción: *"Si inventa una política de reembolso, quedamos contractualmente obligados por lo que dijo."* El grounding es la respuesta técnica a una objeción legal — y por lo tanto una palanca de valor de negocio.

**Qué vas a demostrar.** Que una generación sin grounding es confiada y no verificable, y que el *mismo* modelo, con grounding, devuelve **citas que podés auditar** — y que eso es lo que hace que un despliegue empresarial sea legalmente aprobable.

### Pasos

1. 💵 Hacé una pregunta sin grounding. Observá: una respuesta fluida, y nada contra qué contrastarla.

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

   Salida representativa:

   ```json
   {
     "text": "Google Cloud states that customer data is customer data ... your prompts and responses are not used to train foundation models ...",
     "grounding": "NONE",
     "tokens": { "promptTokenCount": 31, "candidatesTokenCount": 58, "totalTokenCount": 89 }
   }
   ```

   > `"grounding": "NONE"` es todo el punto. La oración puede muy bien ser correcta — pero **la respuesta no lleva evidencia**, así que nadie aguas abajo puede verificarla, y ningún auditor la va a aceptar.

2. 💵 Ahora ejecutá el prompt idéntico con grounding activado.

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

   Salida representativa:

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

   > Las superficies de API más viejas llaman a esta herramienta `googleSearchRetrieval`; las versiones actuales de Gemini usan `googleSearch`. Si obtenés `INVALID_ARGUMENT: Unknown name "googleSearch"`, tu versión de modelo es anterior al cambio de nombre — verificá en <https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview>.

3. 💵 Hacé grounding sobre **tu propio corpus** en vez de la web — este es el patrón empresarial. Creá un data store de Vertex AI Search:

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

4. 🆓 Conectalo a una solicitud de generación. No hace falta ejecutar esto contra un store poblado para aprender la forma — la forma es la respuesta del examen.

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

5. 🆓 Registrá el argumento que desbloquea a Legales:

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

### Verificación de comprensión — Ejercicio 4

- **Q15.** El paso 1 y el paso 2 enviaron el *mismo* prompt al *mismo* modelo. Enunciá con precisión qué cambió en el payload de respuesta, y por qué esa diferencia es lo que firma un oficial de cumplimiento.
- **Q16.** Un asistente con grounding responde "No pude encontrar eso en los documentos de política". Un stakeholder lo llama un retroceso respecto de la versión sin grounding, que siempre respondía. Refutalo en términos de negocio.
- **Q17.** Marketing quiere que el asistente refleje un cambio de precios publicado esta mañana. Compará el costo y el plazo de (a) hacer fine-tuning de un modelo con los precios nuevos versus (b) actualizar el data store de grounding. ¿Cuál debería ser el modelo operativo por defecto, y por qué?
- **Q18.** Nombrá la capa de `ai-stack-map.yaml` que ocupa Vertex AI Search, y explicá qué habría tenido que construir por su cuenta una empresa en 2019 para obtener la misma capacidad.

---

## Ejercicio 5 — La derivación como KPI: Conversational Agents y la Customer Engagement Suite

**Escenario de negocio.** El contact center de una empresa de servicios públicos maneja 220.000 llamadas por trimestre. El 61% son tres preguntas: *dónde está mi factura, cuándo termina el corte, cómo cambio mi débito automático.* El directorio quiere "IA en el call center". Necesitás convertir eso en un KPI medible.

**Qué vas a demostrar.** Que un agente conversacional se aprovisiona como recurso gestionado con SLA y región, y que su valor se expresa como **tasa de contención/derivación**, no como "tenemos un chatbot".

### Pasos

1. 💵 Creá un Conversational Agent (Dialogflow CX) en una región fija.

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

2. 🆓 Leé los dos ajustes que cargan más peso de negocio y por qué:

   ```text
   supportedLanguageCodes : ["en","es","pt"]  -> one agent serves three markets.
                                                 The alternative is three vendor contracts,
                                                 three staffing pools, three sets of hours.
   enableInteractionLogging: true             -> without it you CANNOT compute deflection rate.
                                                 An unmeasured agent cannot be defended at
                                                 the next budget review.
   ```

3. 💵 Enviá un turno de conversación e inspeccioná lo que devuelve el runtime.

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

   Salida representativa en un agente recién creado y sin entrenar:

   ```json
   {
     "intent": "Default Negative Intent",
     "confidence": 0,
     "reply": ["I didn't get that. Can you say it again?"],
     "currentPage": "Start Page"
   }
   ```

   > **Esta falla es la lección.** La plataforma se aprovisionó en segundos; el *valor* no está en la plataforma, está en los flujos, el data store con grounding y la integración de backend que todavía no construiste. "Compramos Dialogflow" no es un entregable.

4. 🆓 Definí el KPI antes de construir cualquier otra cosa.

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

5. 🆓 Limpieza.

   ```bash
   curl -s -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "X-Goog-User-Project: ${PROJECT_ID}" \
     "https://${CX_REGION}-dialogflow.googleapis.com/v3/projects/${PROJECT_ID}/locations/${CX_REGION}/agents/${AGENT_ID}"
   ```

### Verificación de comprensión — Ejercicio 5

- **Q19.** El agente existió en cuestión de segundos pero no respondió nada útil. Generalizá esto en una regla sobre dónde residen realmente el costo y el riesgo en un proyecto de IA empresarial.
- **Q20.** `kpi-contact-centre.yaml` cuenta un corte de llamada por frustración como un *fracaso* aunque técnicamente sea una sesión contenida. Explicá el incentivo perverso que previene esta salvaguarda.
- **Q21.** El agente soporta `en`, `es` y `pt` desde una sola configuración. Expresá eso como una declaración de valor de negocio para una empresa que entra en dos mercados nuevos, e identificá qué es lo que *no* elimina.
- **Q22.** ¿Cuál es la declaración más fuerte a nivel directorio — "desplegamos un chatbot de IA de Google Cloud" o "contuvimos el 35% de los contactos de nivel 1 con CSAT estable" — y qué te dice esa diferencia sobre cómo enmarcar *cualquier* inversión en IA?

---

## Ejercicio 6 — La IA responsable es un control de negocio, no una diapositiva de ética

**Escenario de negocio.** El Comité de Riesgos pregunta: *"¿Qué impide que esta cosa diga algo que termine en las noticias?"* Tu respuesta tiene que ser una configuración, no una promesa.

**Qué vas a demostrar.** Que el filtrado de seguridad, la residencia de datos y los compromisos de gobernanza de datos son **controles de plataforma configurables e inspeccionables** — y que precisamente por eso una empresa elige una plataforma gestionada por sobre un modelo crudo.

### Pasos

1. 💵 Enviá una solicitud con ajustes de seguridad explícitos e inspeccioná el veredicto de seguridad que la plataforma devuelve en *cada* respuesta.

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

   Salida representativa:

   ```json
   {
     "finishReason": "STOP",
     "ratings": [
       { "category": "HARM_CATEGORY_HATE_SPEECH",       "probability": "NEGLIGIBLE", "blocked": null },
       { "category": "HARM_CATEGORY_DANGEROUS_CONTENT", "probability": "NEGLIGIBLE", "blocked": null }
     ]
   }
   ```

2. 🆓 Aprendé a leer las dos señales de falla que tu código de aplicación debe manejar. Son distintas, y confundirlas es un incidente en producción:

   ```text
   finishReason: "STOP"    -> the model finished normally.
   finishReason: "SAFETY"  -> the OUTPUT was blocked. candidates[0].content is absent.
   promptFeedback.blockReason: "SAFETY"  -> the INPUT was blocked. There is no candidate at all.
   finishReason: "MAX_TOKENS" -> truncated. NOT an error, but the answer is incomplete —
                                 shipping it to a customer as-is is a quality defect.
   ```

   Cualquier wrapper de producción tiene que ramificar sobre los cuatro casos. Una aplicación que renderiza `.candidates[0].content.parts[0].text` incondicionalmente va a lanzar una excepción de puntero nulo la primera vez que se dispare un filtro.

3. 🆓 Demostrá el control de residencia. La región está en el hostname *y* en la ruta del recurso — la solicitud no puede derivar silenciosamente a otro continente.

   ```bash
   echo "https://europe-west4-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/europe-west4/publishers/google/models/gemini-2.5-flash:generateContent"
   ```

   Leé los compromisos de procesamiento de ML y residencia de datos en
   <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations> y
   <https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance>.

4. 🆓 Enumerá los controles empresariales que vienen con la *plataforma* y no con el *modelo*, y señalá cuáles son relevantes para el examen:

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

### Verificación de comprensión — Ejercicio 6

- **Q23.** `finishReason: "SAFETY"` y `promptFeedback.blockReason: "SAFETY"` son eventos distintos. Describí el comportamiento visible para el usuario de cada uno, y la decisión de producto diferente que fuerza cada uno.
- **Q24.** El Comité de Riesgos pide "cero posibilidad de una salida dañina". Explicá por qué `BLOCK_LOW_AND_ABOVE` en todas las categorías no es una respuesta sin costo, y nombrá el trade-off que en realidad estás gestionando.
- **Q25.** De `responsible-ai-controls.yaml`, elegí los tres controles que aparecerían en un cuestionario de *compras* y no en un documento de diseño de ingeniería, y justificá cada uno en una línea.
- **Q26.** Un competidor ofrece un puntaje de benchmark levemente mejor sin ninguno de estos controles. Construí el argumento que un Digital Leader le presenta al directorio — sin afirmar que el modelo del competidor sea peor.

---

## Ejercicio 7 — Demostrar el valor: medir tokens, gasto y cuota

**Escenario de negocio.** A los seis meses, el CFO pide el costo por resultado — no el gasto total en IA. Si no podés producirlo, el presupuesto se recorta por defecto.

**Qué vas a demostrar.** Que el consumo es medible en tres niveles — por llamada, por proyecto y por SKU — y que eso es lo que hace defendible un programa de IA en la renovación.

### Pasos

1. 💵 Cada llamada generativa ya te dice su propia base de costo. Capturala.

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

   > **La unidad de costo de la IA es el token, y el conteo de tokens se devuelve en cada una de las llamadas.** Registrá `usageMetadata` junto con tu propia clave de negocio (ID de ticket, cliente, departamento) y tenés atribución de costos por construcción — sin necesidad de ningún modelo de prorrateo.

2. 🆓 Confirmá que existen las métricas de plataforma para dashboards y alertas.

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/metricDescriptors?filter=metric.type%3Dstarts_with(%22aiplatform.googleapis.com%2Fpublisher%22)" \
     | jq -r '.metricDescriptors[] | "\(.type)\t\(.metricKind)/\(.valueType)"'
   ```

   Salida representativa:

   ```
   aiplatform.googleapis.com/publisher/online_serving/token_count            DELTA/INT64
   aiplatform.googleapis.com/publisher/online_serving/model_invocation_count DELTA/INT64
   aiplatform.googleapis.com/publisher/online_serving/first_token_latencies  DELTA/DISTRIBUTION
   ```

3. 🆓 Verificá tu cuota — la restricción que realmente va a frenar un lanzamiento, y la que más a menudo se descubre el día del go-live.

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

4. 💵 Conectá la facturación a BigQuery y escribí la consulta que le responde al CFO. Activá la exportación una vez (Consola: **Facturación → Exportación de facturación → Exportación a BigQuery**), y luego:

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

   Forma representativa del resultado:

   ```
   +------------+----------------------------------+-----------+---------+--------+---------+----------+--------------+-------------------+
   | service    | sku                              | project   | month   | cost   | credits | net_cost | usage_amount | usage_unit        |
   +------------+----------------------------------+-----------+---------+--------+---------+----------+--------------+-------------------+
   | Vertex AI  | Gemini ... Output Token ...      | cdl-ai-.. | 2026-09 |  12.41 |  -12.41 |     0.00 |      412000  | thousand tokens   |
   | Vertex AI  | Gemini ... Input Token ...       | cdl-ai-.. | 2026-09 |   3.07 |   -3.07 |     0.00 |     1024000  | thousand tokens   |
   | Document AI| Invoice Parser ...               | cdl-ai-.. | 2026-09 |   0.60 |   -0.60 |     0.00 |           6  | page              |
   +------------+----------------------------------+-----------+---------+--------+---------+----------+--------------+-------------------+
   ```

5. 🆓 Armá la oración que el CFO realmente quiere:

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

6. 🆓 Limpieza de todo el laboratorio.

   ```bash
   bq rm -r -f -d "${PROJECT_ID}:cdl_ai"
   bq rm --connection --force "${PROJECT_ID}.US.cdl_ai_conn"
   gcloud projects delete "$PROJECT_ID"
   ```

### Verificación de comprensión — Ejercicio 7

- **Q27.** El paso 1 devolvió `promptTokenCount` y `candidatesTokenCount` por separado. ¿Por qué importa comercialmente esa separación, y qué implica para un prompt que mete un documento de 40 páginas en el contexto en cada solicitud?
- **Q28.** En el paso 4 `net_cost` es 0.00 mientras que `cost` es 12.41. Explicá qué pasó, y la trampa que esto crea para un piloto que se juzga por su exportación de facturación.
- **Q29.** La cuota del paso 3 es por minuto, por región y por modelo. Describí una falla del día del lanzamiento que esto provoca y las dos formas de prevenirla antes de que ocurra.
- **Q30.** `cost-per-outcome.yaml` define una *condición de salida*. Argumentá por qué incluir un criterio de cancelación fortalece en vez de debilitar el pedido de financiamiento.

---

## Síntesis — el resumen con forma de examen

Completá esto de memoria antes de leer las respuestas. Cada fila es una pregunta que el examen CDL hace de alguna forma.

| Necesidad de negocio | Oferta de Google Cloud | Capa | Unidad de valor |
|---|---|---|---|
| Extraer campos de facturas, sin equipo de ML | | | |
| Predecir la baja de clientes donde ya viven los datos | | | |
| Responder preguntas de clientes desde *nuestros* documentos, con citas | | | |
| Derivar volumen de contact center de nivel 1 en tres idiomas | | | |
| Probar un modelo de terceros o abierto sin salir de nuestro perímetro de gobernanza | | | |
| Aumentar la productividad de los desarrolladores sobre bases de código existentes | | | |
| Permitir que el personal busque y actúe sobre datos empresariales internos | | | |
| Entrenar nosotros mismos un modelo de frontera | | | |

- **Q31.** Completá la tabla.

---

<details>
<summary><strong>Respuestas</strong> — intentá todas las preguntas antes de abrir</summary>

### Ejercicio 0

**Q1.** Demuestra un **modelo de precios basado en consumo (pago por uso), sin compromiso inicial y sin licencia por servicio**. La consecuencia de negocio: tres departamentos pueden pilotear en paralelo a costo genuinamente cero hasta que generen tráfico, así que la decisión de experimentar ya no requiere una solicitud de capital ni un ciclo de compras. La restricción se mueve de la *aprobación de presupuesto* a la *atención de ingeniería*, que es un ciclo mucho más corto. El corolario — y lo que hay que advertirle al CFO — es que entonces el costo escala con el éxito en vez de estar acotado por una licencia, así que un job descontrolado o un prompt sin límites es ahora un evento financiero. Las alertas de presupuesto y los límites de cuota son el control compensatorio (Ejercicio 7).

**Q2.** **Capa 4 (agentes y aplicaciones)** — Conversational Agents / Customer Engagement Suite, con grounding sobre un data store de Vertex AI Search construido sobre el contenido existente de su centro de ayuda. En la capa 1 el equipo de dos personas se pasaría el trimestre en: aprovisionar y asegurar cuota de capacidad GPU/TPU, seleccionar y hospedar un modelo base, construir un stack de serving con autoescalado y health checks, construir el filtrado de seguridad, construir la recuperación de información y construir la observabilidad — nada de lo cual es el chatbot, y todo lo cual Google ya opera. Muy probablemente llegarían al final del trimestre con infraestructura y sin producto.

**Q3.** *Contraargumento:* Model Garden muestra modelos propios (Gemini), abiertos de Google (Gemma), comerciales de terceros y de pesos abiertos, todos accesibles a través de la **misma plataforma, el mismo IAM, el mismo perímetro de VPC-SC y la misma facturación**. El modelo es un componente intercambiable detrás de una interfaz estable, así que cambiar de modelo es un cambio de configuración, no una replataformización. *La parte legítima:* el lock-in no está en la capa del modelo, está en la **capa de plataforma y gravedad de datos** — tus data stores de grounding, los arneses de evaluación, los pipelines, los artefactos de ajuste, la política de IAM y el corpus en BigQuery. Migrar eso es trabajo real. La posición honesta es: la portabilidad del modelo es alta, la portabilidad de plataforma es moderada, y ese es un trade deliberado que estás haciendo a cambio de los controles de gobernanza del Ejercicio 6.

### Ejercicio 1

**Q4.** Las SKUs por hora facturan por **existencia**; las SKUs por token facturan por **uso**. Un endpoint de predicción dedicado cuesta lo mismo a las 03:00 con cero solicitudes que en el pico — así que con tráfico irregular e impredecible pagás la capacidad del pico durante las 168 horas de la semana y tu costo unitario por predicción se vuelve una función de tu tiempo ocioso. Una API por token cuesta exactamente cero con cero tráfico y escala linealmente con la demanda. Una startup que todavía no tiene tráfico debería preferir sin ambigüedad el modelo por token / por llamada: convierte un costo fijo en uno variable y elimina la necesidad de pronosticar una demanda que no puede pronosticar. El punto de cruce llega con volumen alto, *estable y predecible*, donde la capacidad dedicada (o Provisioned Throughput) puede superar al precio por token en economía unitaria.

**Q5.** **El etiquetado de datos** — conseguir, etiquetar, dirimir y reetiquetar continuamente miles de imágenes específicas del dominio, más el tiempo de los expertos de dominio para definir la taxonomía en primer lugar. Se paga en horas de personal o a un proveedor de etiquetado, se repite cada vez que cambian la taxonomía o la línea de productos, y no aparece en ningún lado de la factura de la nube. Rutinariamente supera el costo de cómputo del entrenamiento en un orden de magnitud y es la razón más común por la que se atrasan los proyectos de modelo propio.

**Q6.** Porque convierte "¿la IA es lo bastante buena?" de una discusión subjetiva recurrente en una **condición de salida medible y acordada de antemano**. Definida antes del lanzamiento, es un umbral de ingeniería neutral; definida después del lanzamiento, quien la proponga está implícitamente atacando o defendiendo el proyecto, y la discusión se vuelve política. También significa que el *monitoreo* correspondiente se construye como parte de la v1 en vez de agregarse a posteriori, así que el disparador efectivamente puede dispararse.

### Ejercicio 2

**Q7.** *Financiero:* sin cargos de egreso, sin una segunda copia de un dataset de varios terabytes que almacenar, y sin un pipeline de ETL que construir y operar — el pipeline es el mayor costo recurrente de ingeniería que se evita. *Operativo:* sin retraso de sincronización ni deriva entre el warehouse y la copia de ML; el modelo entrena exactamente sobre los datos con los que el negocio reporta, lo que elimina la clase de incidente "el dashboard y el modelo no coinciden". *Regulatorio:* los datos nunca cruzan una frontera de confianza o jurisdiccional, así que los controles de acceso existentes de BigQuery, la seguridad a nivel de columna, la seguridad a nivel de fila, los logs de auditoría y las garantías de residencia siguen aplicando sin cambios — no hay que evaluar, certificar ni agregar al mapa de datos ningún sistema nuevo.

**Q8.** El proyecto ya no requiere contratar ingenieros de ML ni recapacitar al equipo de analítica en Python; los **analistas que ya dominan SQL se convierten en el equipo de entrega de ML**. En términos de CFO: quita una dependencia de contratación de la ruta crítica (buscar un ingeniero de ML lleva meses en un mercado competitivo), elimina el premio salarial y el período de arranque, y quita el riesgo de persona clave de un equipo de un solo ingeniero de ML. La fecha de inicio del proyecto pasa de "cuando contratemos" a "el próximo sprint".

**Q9.** Ejemplos: (a) triaje y ruteo automático de tickets de soporte entrantes por sentimiento y tema, para que las escalaciones lleguen a un supervisor sin que un humano lea la cola; (b) alerta temprana de baja de clientes puntuando notas de llamadas y transcripciones de chat en texto libre a escala — señal que antes era ilegible porque nadie podía leer un millón de notas; (c) resumen automatizado de los reportes de técnicos de campo en códigos de falla estructurados. Estabas operando en la **capa 2/3** consumida a través de la plataforma de datos — llamando a un modelo fundacional a través de una plataforma gestionada, sin ningún modelo propio.

**Q10.** `roc_auc ≈ 0.87` dice que el modelo *ordena* bien a los clientes. `precision ≈ 0.63` dice que de todos los que el modelo marca, aproximadamente el 37% son falsos positivos — a €40 por contacto, eso es aproximadamente €15 de gasto por cliente marcado que no produce nada. Si eso es un buen trade depende enteramente del margen de una conversión y del costo de una oportunidad perdida, que es un juicio comercial, no una métrica de modelo. La jugada correcta es usar la *probabilidad* del modelo en vez de su etiqueta: ordená la base, contactá de arriba hacia abajo, y frená donde el ingreso marginal esperado iguale los €40. Eso además reencuadra la conversación — el modelo no decide a quién contactar, decide el *orden*, y el negocio fija el corte.

### Ejercicio 3

**Q11.** *Regla:* contabilizá la factura automáticamente cuando todos los campos requeridos para la contabilización superen el umbral de confianza **y** los ítems de línea extraídos sumen el total extraído; en caso contrario derivala a una persona con los campos de baja confianza resaltados. "Aprobar todo al 97%" es incorrecto porque un 97% de confianza sobre, digamos, seis campos requeridos deja igualmente una probabilidad compuesta significativa de que al menos un campo esté mal, y los errores **no se distribuyen uniformemente en costo** — un `total_amount` equivocado en una factura de €400.000 es un evento materialmente distinto de una descripción de ítem de línea equivocada. La confianza es por campo y uniforme; el impacto de negocio es por campo y salvajemente no uniforme. Por lo tanto el umbral debe fijarse por campo según el valor en riesgo, y acompañarse de una verificación aritmética independiente que atrape los errores sobre los que el modelo está confiadamente equivocado.

**Q12.** **`expected_auto_approval_rate` (0,82).** Todos los ahorros del modelo se multiplican por él, y es la única cifra que depende del desorden de los documentos de proveedores de *esta empresa en particular* — Google no puede proporcionarla y ningún benchmark la sustituye. Experimento más barato: pasar 300–500 facturas reales propias de la empresa, que cubran su mezcla real de proveedores, por el procesador y contar cuántas superan el umbral con valores correctos. Eso cuesta unos pocos euros de llamadas a la API y un día de un administrativo verificando por muestreo, y convierte la mayor suposición del caso de negocio en un número medido.

**Q13.** El `INVOICE_PROCESSOR` especializado está preentrenado sobre el *concepto* de factura — ya sabe qué significan `due_date`, `supplier_name` y `total_amount` a través de layouts arbitrarios de proveedores que nunca viste, con **cero datos de entrenamiento y cero etiquetado**. Un modelo propio requeriría etiquetar miles de documentos para alcanzar la misma línea de base, y generalizaría peor ante la plantilla de un proveedor nuevo. `CUSTOM_EXTRACTION_PROCESSOR` pasa a ser lo correcto cuando el documento es **propietario o específico de una industria, con campos que ningún procesador general modela** — un conocimiento de embarque a medida, una declaración ante un regulador, un formulario interno de siniestro — es decir, cuando genuinamente no existe un equivalente preentrenado del concepto que necesitás extraer.

**Q14.** Porque la región determina **dónde se procesa y se almacena el documento**, y eso determina si el despliegue es lícito en el mercado objetivo — el RGPD y los requisitos sectoriales o de soberanía pueden hacer que `us` sea inviable para datos personales de la UE independientemente del precio o la exactitud. Un control que decide *si podés vender en un mercado o no* es un control de valor de negocio: es la diferencia entre una solución que se despliega a toda la empresa y una que se detiene en la frontera de una región importante. También es una barrera de compras — la respuesta sobre residencia se exige antes del contrato, no después del diseño.

### Ejercicio 4

**Q15.** La respuesta ganó `groundingMetadata` — `groundingChunks[].uri` (los documentos fuente) y `groundingSupports` (qué fragmentos de la respuesta están respaldados por qué fuente). El prompt, el modelo y la temperatura eran idénticos. Un oficial de cumplimiento lo firma porque eso hace la respuesta **auditable a posteriori**: cuando un cliente disputa lo que le dijo el asistente, la empresa puede reconstruir de qué documento salió la afirmación y qué versión estaba vigente. Convierte una salida de modelo infalsable en evidencia, y hace que el modo de falla sea revisable en vez de invisible.

**Q16.** "No pude encontrar eso" es una falla **segura, acotada y corregible**; una invención confiada es una **responsabilidad ilimitada**. La versión sin grounding no respondía más preguntas — respondía las mismas preguntas más algunas que respondía *mal*, de forma indistinguible. Además, cada "no encontrado" es telemetría de producto gratis: nombra una pregunta real de un cliente que la base de conocimiento no cubre, así que la lista de brechas se escribe sola y cada arreglo es una edición de documento. El retroceso es que la brecha de cobertura se volvió *visible*; siempre estuvo ahí.

**Q17.** (a) Fine-tuning: necesita un conjunto de entrenamiento curado, un job de ajuste, evaluación contra regresiones, un despliegue y un plan de rollback — días a semanas, costo real, y hay que repetirlo para el *próximo* cambio de precios. Además arriesga degradar comportamientos no relacionados. (b) Actualizar el data store: reindexar el documento de precios nuevo — minutos, costo insignificante, inmediatamente reversible reindexando la versión anterior. **El grounding debe ser el modelo operativo por defecto** porque los precios, las políticas y el catálogo son *hechos volátiles*, y los hechos volátiles pertenecen a documentos recuperables, no horneados en los pesos. Reservá el ajuste para cambiar el *comportamiento* del modelo — tono, formato de salida, estilo de dominio, adherencia a la tarea — que es estable en el tiempo.

**Q18.** **Capa 4 (agentes y aplicaciones)**, apoyada sobre servicios de plataforma de la capa 3. En 2019 una empresa que quisiera la misma capacidad habría tenido que construir y operar: un pipeline de ingesta y parseo de documentos, una estrategia de fragmentación, un modelo de embeddings, un índice vectorial con su propia historia de escalado y reindexación, una capa de recuperación y reordenamiento, ajuste de relevancia, propagación del control de acceso desde los sistemas de origen hacia el índice, y la infraestructura de serving para todo eso — un esfuerzo de plataforma de varios equipos y varios trimestres, y que la mayoría de las empresas hacía mal. Ahora es un recurso gestionado creado con una sola llamada a la API, que es la ilustración más clara de lo que significa concretamente "la IA crea valor de negocio colapsando el tiempo hasta obtener valor".

### Ejercicio 5

**Q19.** **Aprovisionar la plataforma es gratis e instantáneo; el costo y el riesgo están en el conocimiento del dominio, el diseño de los flujos, el corpus de grounding y las integraciones de backend.** La regla generalizable: en la IA empresarial, el proveedor aporta la *capacidad*, la empresa aporta el *contexto*, y el contexto es la mitad cara. Cualquier plan, presupuesto o cronograma que trate "adoptar el servicio de IA" como si fuera el proyecto dimensionó mal el trabajo en un orden de magnitud — y cualquier comparación de proveedores decidida por la velocidad de aprovisionamiento está comparando la parte más barata.

**Q20.** Sin ella, se premia al equipo por **prevenir la escalación en vez de resolver problemas**. La tasa de contención sube más rápido si se hace difícil llegar a la vía humana — enterrando la opción de "hablar con un agente", con largos bucles de derivación, negándose a escalar — lo que empuja la contención hacia arriba y la satisfacción del cliente, la retención y el volumen de quejas en la dirección equivocada. La salvaguarda obliga a que la contención se gane *resolviendo* el contacto, que es el resultado que el negocio realmente quería cuando aprobó el proyecto. Es la falla clásica de Goodhart: la métrica deja de ser un proxy del objetivo en el momento en que se convierte en el objetivo.

**Q21.** *Declaración de valor:* "Entrar en dos mercados nuevos no requiere un nuevo proveedor de contact center, ni una nueva dotación de personal, ni un nuevo turno fuera de horario para los contactos de nivel 1 — la misma configuración de agente atiende los tres idiomas 24/7, así que el costo marginal del soporte de nivel 1 del tercer mercado es cercano a cero." *Lo que no elimina:* la necesidad de **revisión por hablantes nativos de los flujos y del contenido de grounding**, el fraseo legal y regulatorio específico de cada mercado, rutas locales de escalación a humanos que hablen el idioma, y reglas de negocio localizadas (ciclos de facturación, redacción de protección al consumidor, feriados). La traducción automática de una interfaz no es la localización de un servicio.

**Q22.** La segunda. Un directorio financia **resultados de negocio**, no adopción de tecnología — "desplegamos un chatbot" es infalsable y no trae ningún pedido siguiente adosado, mientras que "contuvimos el 35% de los contactos de nivel 1 con CSAT estable" es medible, comparable trimestre a trimestre, e implica su propio paso siguiente (subir al 50%, extender a nivel 2, agregar un mercado). La lección general: **enmarcá cada inversión en IA por la métrica de negocio que mueve y la salvaguarda que prueba que no movió otra cosa en la dirección equivocada.** La tecnología nombrada en una declaración al directorio es señal de que nadie midió el resultado.

### Ejercicio 6

**Q23.** `finishReason: "SAFETY"` — el modelo generó una respuesta y la *salida* fue bloqueada; no hay texto usable en el candidato, pero la solicitud en sí era legítima. Visible para el usuario: el asistente parece colgarse o no devolver nada. Decisión de producto: necesitás una respuesta de fallback elegante y, normalmente, una vía de escalación — el usuario hizo una pregunta razonable y merece una respuesta de algún lado. `promptFeedback.blockReason: "SAFETY"` — la *entrada* fue bloqueada antes de generar; no hay candidato en absoluto. Visible para el usuario: un rechazo inmediato. Decisión de producto: esto es sobre la entrada del propio usuario, así que pertenece a tu manejo de abuso/mal uso — contabilizalo, aplicá límites de tasa a los reincidentes, y no ofrezcas un reintento que simplemente reenvíe el mismo prompt. Confundir ambos produce o bien una caída de la aplicación (desreferenciar un candidato ausente) o bien una vía de abuso tratada como error de sistema.

**Q24.** El filtrado máximo eleva los **falsos positivos** — se bloquea contenido de negocio legítimo. Una aseguradora hablando de cobertura por autolesiones, una farmacia hablando de umbrales de sobredosis, un equipo de seguridad hablando de una técnica de ataque, un banco hablando de fraude: todas son conversaciones de dominio ordinarias que una configuración agresiva de `DANGEROUS_CONTENT` va a suprimir. Cada falso positivo es una interacción con el cliente fallida y, a escala, un producto que el personal esquiva. El trade-off que estás gestionando es **riesgo de daño versus utilidad**, y la respuesta correcta no es un máximo global sino un ajuste por caso de uso: estricto en una superficie pública, no autenticada y de cara al consumidor; más permisivo en una herramienta interna, autenticada y registrada, usada por personal capacitado — con los controles de *grounding* y *auditoría*, no el filtro, haciendo el trabajo pesado en el segundo caso. Notá además que los filtros gobiernan la *nocividad*, no la *exactitud*: nunca van a bloquear una falsedad cortés y confiada, que es justamente por lo que existe el Ejercicio 4.

**Q25.** (1) **Compromiso de gobernanza de datos** — "¿usan nuestros datos para entrenar sus modelos?" está en todo cuestionario de compras empresarial y una respuesta equivocada termina el trato. (2) **Residencia de datos / endpoints regionales** — requerido para responder la sección de RGPD y soberanía y para completar una evaluación de impacto de transferencia de datos. (3) **CMEK** — la custodia de claves es un requisito estándar de los marcos de control en sectores regulados (finanzas, salud, público), a menudo exigido por el propio regulador del cliente. Los demás (filtros de seguridad, grounding, configuración de IAM/VPC-SC, detalle de logs de auditoría) son decisiones de ingeniería en tiempo de diseño; estos tres son propiedades contractuales del proveedor que un comprador verifica antes de firmar.

**Q26.** El argumento no es "su modelo es peor" — concedé el benchmark. Es que **un puntaje de benchmark no es la unidad desplegable**. Lo que llega a los clientes es un *sistema*, y el costo del sistema está dominado por los controles que rodean al modelo: residencia, integración con IAM, VPC-SC, CMEK, logs de auditoría, configuración de seguridad, grounding, evaluación y SLA. Elegir el modelo con mejor puntaje significa que la empresa construye y luego *opera y certifica* esos controles por su cuenta, a su propio riesgo, bajo su propia responsabilidad, para siempre — y debe recertificarlos en la próxima auditoría. Agregá que la capa del modelo es la parte que más rápido se commoditiza y la más fácilmente intercambiable de la pila (Model Garden, Q3), así que la ventaja de benchmark de hoy es lo menos duradero de todo lo que se está comparando. La decisión es entonces entre una ganancia de calidad marginal y perecedera y un costo de gobernanza permanente y acumulativo — y al directorio se le está pidiendo que apruebe el *sistema*, no la tabla de posiciones.

### Ejercicio 7

**Q27.** Los tokens de entrada y de salida tienen precios distintos, y la salida suele ser la más cara de las dos — así que la *forma* de una carga de trabajo, no solo su volumen, determina su costo. Un prompt que mete un documento de 40 páginas en el contexto en cada solicitud paga ese costo de entrada en **cada una de las llamadas**, para siempre, por contenido que nunca cambia. Ese es el argumento económico a favor de la recuperación de información (enviar solo los pasajes relevantes, según el Ejercicio 4) y del caché de contexto (pagar una vez por un prefijo compartido en vez de por solicitud). También explica un resultado contraintuitivo que los equipos encuentran en producción: una funcionalidad de resumen "barata" puede costar más que una funcionalidad de generación "cara" puramente por el tamaño del contexto.

**Q28.** Los créditos de prueba gratuita (o créditos de uso comprometido o promocionales) compensan el `cost` bruto hasta dejar un `net_cost` de cero. La trampa: un piloto juzgado por su exportación de facturación parece no costar **nada**, así que nadie construye un modelo de costos, nadie fija la métrica por resultado y la economía unitaria nunca se pone a prueba — y después los créditos vencen, el costo verdadero aparece con volumen productivo, y el programa enfrenta una revisión de emergencia sin una línea de base con la que defenderse. Evaluá siempre un piloto por el `cost` **bruto** y tratá los créditos como una línea separada y temporal. Precisamente por eso la consulta devuelve `cost`, `credits` y `net_cost` como tres columnas y no como una.

**Q29.** *Falla:* el lanzamiento de marketing genera tráfico muy por encima del ritmo del piloto; se excede la cuota por minuto, por región y por modelo, y el servicio devuelve `429 RESOURCE_EXHAUSTED` justo en el momento de máxima visibilidad. Como la cuota es por *modelo*, un cambio de último momento a un modelo más nuevo también puede moverte silenciosamente a un bucket de cuota distinto y más bajo. *Prevención:* (1) Solicitá un aumento de cuota con anticipación, dimensionado a partir de una prueba de carga al pico proyectado — no al promedio — y recordá que los aumentos tardan en revisarse, así que esto es un ítem de la lista de verificación previa al lanzamiento, no del día del lanzamiento. (2) Incorporá contrapresión en el cliente: retroceso exponencial con jitter, una cola de solicitudes, degradación elegante a una respuesta cacheada o más simple, y una alerta de Cloud Monitoring sobre las métricas de tokens/invocaciones del paso 2 que se dispare bastante por debajo del techo. Para cargas de trabajo de alto volumen predecibles, Provisioned Throughput reserva capacidad en vez de competir por la cuota compartida.

**Q30.** Porque demuestra que el pedido es un **caso de negocio y no un entusiasmo**, y cambia quién carga con el riesgo. El miedo no declarado de quien financia es una iniciativa que nunca se puede cancelar porque nadie acordó cómo se ve el fracaso; un criterio de cancelación declarado de antemano elimina ese miedo y abarata la aprobación. También disciplina al equipo — la métrica tiene que estar efectivamente instrumentada para que el criterio sea verificable, así que la medición se construye. Y en el caso habitual en que la métrica se cumple holgadamente, la condición de salida se convierte en la evidencia más fuerte posible en la renovación: el proyecto se puso continuamente a prueba contra un estándar que podría haber reprobado, y no reprobó.

### Síntesis

**Q31.**

| Necesidad de negocio | Oferta de Google Cloud | Capa | Unidad de valor |
|---|---|---|---|
| Extraer campos de facturas, sin equipo de ML | **Document AI** (procesadores especializados preentrenados) | 4 | por página procesada → por factura contabilizada automáticamente |
| Predecir la baja de clientes donde ya viven los datos | **BigQuery ML** (+ Vertex AI para MLOps a escala) | 3 | por consulta/slot; sin movimiento de datos |
| Responder preguntas de clientes desde *nuestros* documentos, con citas | **Vertex AI Search** + Gemini con grounding (Vertex AI Agent Builder / RAG Engine) | 4 sobre 3 | por consulta, con una cita auditable |
| Derivar volumen de contact center de nivel 1 en tres idiomas | **Conversational Agents (Dialogflow CX) / Customer Engagement Suite (CCaaS)** | 4 | por sesión contenida (tasa de contención) |
| Probar un modelo de terceros o abierto sin salir de nuestro perímetro de gobernanza | **Model Garden en Vertex AI** | 2 vía 3 | por token o por hora de endpoint desplegado |
| Aumentar la productividad de los desarrolladores sobre bases de código existentes | **Gemini Code Assist / Gemini for Google Cloud** | 4 | por asiento → productividad de entrega y tiempo de ciclo del cambio |
| Permitir que el personal busque y actúe sobre datos empresariales internos | **Google Agentspace** | 4 | por asiento → horas de búsqueda y traspasos evitados |
| Entrenar nosotros mismos un modelo de frontera | **AI Hypercomputer** — capacidad TPU / GPU, Cluster Director | 1 | por hora de acelerador o capacidad comprometida |

El patrón para llevarse al examen: **leé la restricción que plantea la pregunta — habilidades del equipo, tiempo de calendario, ubicación de los datos, exposición regulatoria — y elegí la capa más alta que la satisfaga.** Casi toda respuesta incorrecta en este dominio es una solución construida una o más capas por debajo de lo que la pregunta requería.

</details>

---

## Fuentes oficiales

- Guía del examen Cloud Digital Leader — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Productos de IA y ML de Google Cloud — <https://cloud.google.com/products/ai>
- Introducción a Vertex AI — <https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform>
- Model Garden — <https://cloud.google.com/vertex-ai/generative-ai/docs/model-garden/explore-models>
- Modelos Gemini y versionado/retiro — <https://cloud.google.com/vertex-ai/generative-ai/docs/models>
- Ubicaciones de IA generativa y residencia de datos — <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations>
- Gobernanza de datos de IA generativa — <https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance>
- Configurar filtros de seguridad — <https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/configure-safety-filters>
- Descripción general del grounding — <https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview>
- Vertex AI Search / Agent Builder — <https://cloud.google.com/generative-ai-app-builder/docs/introduction>
- Introducción a BigQuery ML — <https://cloud.google.com/bigquery/docs/bqml-introduction>
- `ML.GENERATE_TEXT` — <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-generate-text>
- Descripción general de Document AI y lista de procesadores — <https://cloud.google.com/document-ai/docs/overview>
- Precios de Document AI — <https://cloud.google.com/document-ai/pricing>
- Conversational Agents (Dialogflow CX) — <https://cloud.google.com/dialogflow/cx/docs>
- Customer Engagement Suite — <https://cloud.google.com/solutions/customer-engagement-ai>
- Google Agentspace — <https://cloud.google.com/products/agentspace>
- Gemini for Google Cloud — <https://cloud.google.com/products/gemini>
- AI Hypercomputer — <https://cloud.google.com/ai-hypercomputer/docs/overview>
- IA responsable en Vertex AI — <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/responsible-ai>
- Cloud Billing Catalog API — <https://cloud.google.com/billing/docs/reference/rest/v1/services.skus/list>
- Exportación de facturación a BigQuery — <https://cloud.google.com/billing/docs/how-to/export-data-bigquery>
- Cloud Quotas API — <https://cloud.google.com/docs/quotas/api-overview>
- VPC Service Controls con Vertex AI — <https://cloud.google.com/vertex-ai/docs/general/vpc-service-controls>