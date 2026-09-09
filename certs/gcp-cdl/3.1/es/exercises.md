# gcp-cdl · Tema 3.1 — Ejercicios Guiados

## Describir conceptos fundamentales de IA y ML y cómo generan valor de negocio

**Examen:** Google Cloud Digital Leader (versión 2026-08-12) · **Peso del dominio:** 9.0%
**Fuente oficial del objetivo:** <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>

---

### Por qué un examen de *leader* incluye un laboratorio *práctico*

El examen Cloud Digital Leader se basa en escenarios y vocabulario, no en comandos. Nunca te van a pedir que escribas SQL en el examen. Pero el modo de fallo de estudiar este dominio a partir de diapositivas es que "entrenamiento", "inferencia", "grounding", "calidad de datos" y "valor de negocio" quedan abstractos — y los distractores del examen están construidos precisamente sobre la frontera entre ellos ("entrenar un modelo personalizado" vs. "llamar a una API preentrenada" vs. "hacer un prompt a un modelo fundacional con grounding").

Estos ejercicios hacen que cada concepto sea **observable**: vas a entrenar un modelo y ver cómo cuesta dinero una vez y predice barato para siempre; vas a corromper un dataset y ver cómo la métrica de negocio se derrumba mientras la accuracy se mantiene alta; vas a hacer que un modelo fundacional alucine y después lo vas a fundamentar con grounding. Los comandos son el andamiaje — la salida relevante para el examen es el vocabulario y las reglas de decisión.

Los pasos marcados **[CORE]** mapean directamente a objetivos del examen. Los pasos marcados **[DEPTH]** son contexto de producción que hace que los conceptos CORE se fijen; salteálos si andás corto de tiempo, pero sí leé sus preguntas de checkpoint.

---

### Requisitos previos

| Requisito | Verificación |
|---|---|
| Proyecto de Google Cloud con **facturación habilitada** | `gcloud beta billing projects describe $PROJECT_ID` |
| CLI `gcloud` ≥ 470 y `bq` | `gcloud version` |
| Roles IAM en el proyecto | `roles/bigquery.admin`, `roles/aiplatform.user`, `roles/serviceusage.serviceUsageAdmin`, `roles/resourcemanager.projectIamAdmin` |
| Presupuesto | **< USD 2** si seguís los pasos tal como están escritos y completás el Ejercicio 9 (limpieza). El laboratorio evita deliberadamente AutoML y el entrenamiento personalizado, que son las superficies caras. |

> **La disciplina de costos es en sí misma parte de este dominio.** Cada paso que gasta dinero declara qué gasta y por qué. Antes de ejecutar nada, configurá una alerta de presupuesto: <https://cloud.google.com/billing/docs/how-to/budgets>

> **Advertencia sobre cambios de nombres.** Google publica IDs de modelos y superficies de CLI más rápido de lo que cualquier material de estudio puede seguir. Si un nombre de modelo o un subcomando `gcloud` de este laboratorio es rechazado, ejecutá `gcloud components update` y tomá el nombre actual de la referencia de Model Garden: <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/models>. Los *conceptos* son estables; los *identificadores* no. Esa distinción vale la pena internalizarla antes del examen, que evalúa los primeros.

---

## Ejercicio 1 — Bootstrap y la taxonomía de la IA **[CORE]**

**Objetivo:** Establecer el entorno y materializar el anidamiento IA ⊃ ML ⊃ Deep Learning ⊃ IA Generativa, que es el concepto más evaluado de este objetivo.

### Pasos

1. Exportá las variables que reutilizan todos los ejercicios posteriores:

    ```bash
    export PROJECT_ID="$(gcloud config get-value project)"
    export LOCATION="us-central1"
    export BQ_LOCATION="US"
    export DATASET="cdl_ai_lab"
    export GEN_MODEL="gemini-2.5-flash"
    export EMB_MODEL="text-embedding-005"
    echo "project=$PROJECT_ID region=$LOCATION"
    ```

2. Habilitá exactamente las APIs que este laboratorio necesita. Notá que **habilitar una API no cuesta nada** — pagás por las llamadas, no por la disponibilidad. Este es un tema recurrente del CDL.

    ```bash
    gcloud services enable \
      aiplatform.googleapis.com \
      bigquery.googleapis.com \
      bigqueryconnection.googleapis.com \
      language.googleapis.com \
      --project="$PROJECT_ID"
    ```

3. Confirmá que están activas:

    ```bash
    gcloud services list --enabled --project="$PROJECT_ID" \
      --filter="config.name~(aiplatform|bigquery|language)" \
      --format="table(config.name, config.title)"
    ```

    Salida esperada (abreviada):

    ```
    NAME                              TITLE
    aiplatform.googleapis.com         Vertex AI API
    bigquery.googleapis.com           BigQuery API
    bigqueryconnection.googleapis.com BigQuery Connection API
    language.googleapis.com           Cloud Natural Language API
    ```

4. Creá el dataset de trabajo. `--location` es inmutable después de la creación y debe coincidir con la ubicación de cualquier tabla contra la que hagas un join:

    ```bash
    bq --location="$BQ_LOCATION" mk --dataset \
      --description="CDL 3.1 guided exercises - safe to delete" \
      "${PROJECT_ID}:${DATASET}"
    ```

5. Mirá el catálogo de modelos. Model Garden es la respuesta concreta a "de dónde salen los modelos fundacionales en Google Cloud":

    ```bash
    gcloud ai model-garden models list --limit=15 2>/dev/null \
      || echo "CLI surface unavailable - use the console: https://console.cloud.google.com/vertex-ai/model-garden"
    ```

    Deberías ver una mezcla de modelos propios de Google (`google/gemini-*`, `google/imagen-*`), modelos de pesos abiertos (`meta/llama*`, `mistral-ai/*`) y modelos de socios. **El catálogo en sí mismo es el punto pedagógico:** el posicionamiento de Google Cloud es que alquilás el modelo, no tenés que construirlo.

6. Fijá la taxonomía con tus propias palabras antes de continuar. Escribí esta tabla a mano — no la leas solamente:

    | Capa | Definición | Propiedad distintiva | Superficie en Google Cloud |
    |---|---|---|---|
    | **Inteligencia Artificial** | Cualquier sistema que realiza tareas que normalmente requieren inteligencia humana | El paraguas; incluye motores de reglas escritos a mano sin ningún aprendizaje | — |
    | **Machine Learning** | Sistemas que *aprenden una función a partir de datos* en lugar de ser programados explícitamente | El comportamiento se deriva de ejemplos, no de código | BigQuery ML, entrenamiento en Vertex AI |
    | **Deep Learning** | ML que usa redes neuronales multicapa | Aprende sus propias representaciones de características a partir de datos crudos | Entrenamiento personalizado en Vertex AI, GPUs/TPUs |
    | **IA Generativa** | Modelos de deep learning que producen contenido *nuevo* (texto, imagen, audio, código) | La salida es contenido generado, no una etiqueta ni un número | Gemini, Imagen, Veo vía Vertex AI |
    | **Modelo fundacional / LLM** | Un modelo muy grande preentrenado con datos amplios, adaptable a muchas tareas | Preentrenamiento agnóstico de tarea + adaptación específica por tarea | Model Garden, Vertex AI |

> **Fuentes:** Descripción general de Vertex AI <https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform> · Model Garden <https://cloud.google.com/vertex-ai/generative-ai/docs/model-garden/explore-models> · Glosario de ML de Google <https://developers.google.com/machine-learning/glossary>

### Checkpoint 1

- **Q1.1** Una empresa de logística opera un sistema de despacho compuesto por 4.000 reglas `if/then` escritas a mano y mantenidas por expertos del dominio. ¿Es IA? ¿Es ML? Justificá con una oración.
- **Q1.2** ¿Por qué la IA generativa se dibuja *dentro* del deep learning y no al lado?
- **Q1.3** Tu CFO pregunta: "Habilitamos la API de Vertex AI el trimestre pasado y no usamos nada. ¿Cuánto costó eso?" Respondé, y enunciá el principio general de precios de Google Cloud que ilustra.
- **Q1.4** En una oración, ¿qué hace que un modelo sea *fundacional*, en oposición a simplemente grande?

---

## Ejercicio 2 — Datos: estructurados vs. no estructurados, y la etiqueta **[CORE]**

**Objetivo:** Ver con tus propios ojos las dos formas de datos que el examen distingue, e identificar la *etiqueta* — el concepto que separa el aprendizaje supervisado de todo lo demás.

### Pasos

1. Inspeccioná un dataset **estructurado**. Estructura significa: esquema fijo, columnas tipadas, las filas son registros.

    ```bash
    bq show --schema --format=prettyjson \
      bigquery-public-data:ml_datasets.census_adult_income | head -40
    ```

    Salida esperada (abreviada):

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

2. Mirá las filas reales y el balance de clases de la columna que vamos a predecir:

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

    Salida esperada:

    ```
    +----------------+-------+-------+
    | income_bracket | rows  |  pct  |
    +----------------+-------+-------+
    |  <=50K         | 24720 | 75.92 |
    |  >50K          |  7841 | 24.08 |
    +----------------+-------+-------+
    ```

    Acaban de pasar dos cosas, y las dos importan. Primero, `income_bracket` es la **etiqueta**: lo que queremos que el modelo prediga para las filas donde no lo sabemos. Todas las demás columnas son **características** (features). Segundo, mirá con atención los valores — llevan un **espacio inicial** (`" <=50K"`). Ese es un defecto de calidad de datos real y no documentado en un dataset público ampliamente usado, y va a romper silenciosamente cualquier filtro `WHERE income_bracket = '>50K'` que escribas. El Ejercicio 4 trata exactamente de esta clase de problema.

3. Ahora la forma **no estructurada**. Enviá texto libre a una API preentrenada y observá que la entrada no tiene esquema alguno:

    ```bash
    gcloud ml language analyze-sentiment \
      --content="The onboarding flow was confusing and I nearly gave up, but support fixed it in four minutes and I would still recommend you." \
      --format=json | head -30
    ```

    Salida esperada (abreviada):

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

    Leé los dos números con cuidado. `score` va de −1.0 (negativo) a +1.0 (positivo); `magnitude` no tiene cota y mide la *intensidad emocional*. Un score de documento cercano a **0.1 con magnitude 1.6** no significa "neutral, a nadie le importó" — significa "fuertemente mixto": una oración muy negativa y una muy positiva que se cancelan. Reportarle solo el score del documento a un stakeholder de negocio sería activamente engañoso. Esta es una instancia pequeña y concreta de la lección más importante de todo el dominio: **la salida de un modelo es un número, y convertirlo en una decisión es una elección de diseño humana.**

4. **[DEPTH]** Confirmá que no entrenaste nada en el paso 3:

    ```bash
    bq ls "${PROJECT_ID}:${DATASET}"
    ```

    Salida esperada:

    ```
    (empty)
    ```

    Acabás de hacer NLP de nivel productivo con cero datos de entrenamiento, cero artefactos de modelo y cero experiencia en ML. Esa es la propuesta de valor de una API preentrenada, y es la respuesta correcta del examen cada vez que un escenario dice "tarea común, sin datos únicos, hay que salir rápido".

> **Fuentes:** Sentiment de Natural Language <https://cloud.google.com/natural-language/docs/analyzing-sentiment> · Datasets públicos de BigQuery <https://cloud.google.com/bigquery/public-data>

### Checkpoint 2

- **Q2.1** Clasificá cada uno como estructurado o no estructurado: (a) una tabla `orders` de Cloud SQL; (b) 40.000 facturas PDF escaneadas; (c) un flujo de logs JSON con un esquema consistente; (d) grabaciones de audio de un call center.
- **Q2.2** En el paso 2 encontraste la etiqueta. Si el dataset *no* tuviera columna `income_bracket`, ¿qué categoría de ML podrías seguir aplicando, y qué produciría?
- **Q2.3** El balance de clases es aproximadamente 76/24. Un colega propone un modelo que siempre predice `<=50K`. ¿Qué accuracy alcanza, y por qué ese número es peligroso?
- **Q2.4** Reescribí el resultado de sentiment del paso 3 como un resumen de una línea para un product manager que no lo induzca a error.
- **Q2.5** ¿Qué producto nombrarías para (b) en Q2.1 — 40.000 facturas escaneadas donde el negocio quiere extraer los totales por línea — y por qué no un modelo fundacional de propósito general?

---

## Ejercicio 3 — Entrenamiento vs. inferencia: la asimetría de costos **[CORE]**

**Objetivo:** Entrenar un modelo real de clasificación supervisada, después ejecutar inferencia con él, y medir la diferencia. El examen evalúa repetidamente que son fases separadas con perfiles de costo separados.

> **Costo:** la sentencia `CREATE MODEL` de abajo escanea aproximadamente 4 MB. El nivel gratuito on-demand de BigQuery cubre 1 TiB de procesamiento de consultas por mes, así que esto es efectivamente gratis. Verificá en <https://cloud.google.com/bigquery/pricing>.

### Pasos

1. Entrená un modelo de regresión logística. Leé el bloque de opciones antes de ejecutarlo — cada opción es una decisión de diseño que un líder debería poder nombrar:

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

    Notá cuatro cosas:
    - `TRIM(...)` — desactivamos el defecto del espacio inicial encontrado en el Ejercicio 2.
    - `auto_class_weights = TRUE` — compensa el desbalance 76/24 para que la clase minoritaria no sea ignorada.
    - `data_split_eval_fraction = 0.20` — el 20% de las filas queda **reservado** y nunca se ve durante el entrenamiento. Evaluar con datos con los que el modelo entrenó mide memorización, no aprendizaje.
    - Excluimos deliberadamente `race` y `sex`. Guardá ese pensamiento hasta el Ejercicio 8.

    Salida esperada:

    ```
    Waiting on bqjob_r3f8a2c1d0e94b7f_00000193c2a1_1 ... (18s) Current status: DONE
    ```

2. Inspeccioná el artefacto entrenado — el entrenamiento produjo una *cosa* que ahora existe:

    ```bash
    bq show --format=prettyjson "${PROJECT_ID}:${DATASET}.income_logreg" \
      | grep -E '"(modelType|creationTime|trainingRuns|location)"' | head
    bq ls --models "${PROJECT_ID}:${DATASET}"
    ```

    Salida esperada:

    ```
                 Id              Model Type      Labels   Creation Time
     ----------------------- ----------------- -------- -----------------
      income_logreg           LOGISTIC_REGRESSION        07 Sep 09:14:22
    ```

3. Evaluá sobre la partición reservada:

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

    Salida esperada (tus números van a diferir levemente — la partición es aleatoria):

    ```
    +----------+-----------+--------+--------+---------+----------+
    | accuracy | precision | recall |   f1   | roc_auc | log_loss |
    +----------+-----------+--------+--------+---------+----------+
    |   0.8003 |    0.5468 | 0.8412 | 0.6627 |  0.8934 |   0.4327 |
    +----------+-----------+--------+--------+---------+----------+
    ```

    Una accuracy de 0.80 contra una línea base de 0.76 parece poco impresionante. **El ROC AUC de 0.89 es el titular honesto**: dice que el modelo ordena a una persona de altos ingresos tomada al azar por encima de una de bajos ingresos tomada al azar el 89% de las veces, independientemente de cualquier umbral. Una precision de 0.55 con un recall de 0.84 te dice que `auto_class_weights` hizo su trabajo — el modelo tira una red amplia, capturando el 84% de las personas de altos ingresos reales al precio de que casi la mitad de sus llamadas positivas estén equivocadas. Si ese intercambio es bueno depende enteramente de una economía que todavía no especificaste. El Ejercicio 5 la especifica.

4. Mirá dónde están realmente los errores:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT * FROM ML.CONFUSION_MATRIX(MODEL `'"${DATASET}"'.income_logreg`)'
    ```

    Salida esperada:

    ```
    +----------------+------+------+
    | expected_label |  _0  |  _1  |
    +----------------+------+------+
    | 0              | 3866 | 1080 |
    | 1              |  249 | 1318 |
    +----------------+------+------+
    ```

    Leélo como una matriz 2×2: las filas son la verdad, las columnas la predicción. **1318** verdaderos positivos, **1080** falsos positivos, **249** falsos negativos, **3866** verdaderos negativos.

5. Ahora ejecutá **inferencia** sobre filas que el modelo nunca vio, y cronometrala:

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

    Salida esperada:

    ```
    +-----+--------------------+----------------+------------+---------------+
    | age |     occupation     | hours_per_week | prediction | prob_over_50k |
    +-----+--------------------+----------------+------------+---------------+
    |  44 |  Exec-managerial   |             50 |          1 |        0.9127 |
    |  22 |  Handlers-cleaners |             20 |          0 |        0.0143 |
    +-----+--------------------+----------------+------------+---------------+

    real    0m2.417s
    ```

    **Esta es la asimetría.** El entrenamiento leyó 32.561 filas, ejecutó un bucle de optimización y produjo un artefacto persistente. La inferencia leyó dos filas e hizo aritmética contra los pesos almacenados. El entrenamiento es *episódico, caro, y produce un activo*. La inferencia es *continua, barata por llamada, y produce una decisión* — pero se ejecuta millones de veces, así que igualmente suele dominar el costo de por vida.

6. **[DEPTH]** Preguntale al modelo qué aprendió:

    ```bash
    bq query --use_legacy_sql=false --format=pretty '
    SELECT feature, ROUND(attribution, 4) AS attribution
    FROM ML.GLOBAL_EXPLAIN(MODEL `'"${DATASET}"'.income_logreg`)
    ORDER BY ABS(attribution) DESC LIMIT 6'
    ```

    Salida esperada:

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

    Que `marital_status` supere a `education_num` debería incomodarte, y esa incomodidad es el punto. **La explicabilidad no es un lujo; es cómo descubrís que tu modelo aprendió un proxy de algo que no tenías intención de usar.**

> **Fuentes:** `CREATE MODEL` para GLM <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create-glm> · `ML.EVALUATE` <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-evaluate> · `ML.CONFUSION_MATRIX` <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-confusion> · Introducción a BQML <https://cloud.google.com/bigquery/docs/bqml-introduction>

### Checkpoint 3

- **Q3.1** Enunciá la diferencia entre entrenamiento e inferencia en una oración cada uno, y después explicá por qué los perfiles de costo difieren en *forma*, no solo en magnitud.
- **Q3.2** ¿Por qué la partición reservada del 20% es innegociable? Nombrá la falla que previene.
- **Q3.3** A partir de la matriz de confusión, calculá precision y recall a mano y confirmá que coinciden con `ML.EVALUATE`.
- **Q3.4** La accuracy es 0.80 y la línea base de siempre-predecir-`<=50K` es 0.76. Argumentá que el modelo es valioso de todos modos, usando una métrica del paso 3.
- **Q3.5** ¿Qué le aporta `enable_global_explain` a un negocio *regulado*, más allá de la curiosidad?
- **Q3.6** Un stakeholder dice: "El modelo ya está entrenado, así que nuestros costos de IA quedaron atrás." Corregilo.

---

## Ejercicio 4 — Calidad de datos: la restricción que realmente decide el resultado **[CORE]**

**Objetivo:** Probar empíricamente que la calidad del modelo está acotada por la calidad de los datos, y aprender las dimensiones que Google Cloud usa para describirla. Este es el ejercicio de mayor rendimiento de todo el tema.

### Pasos

1. Perfilá los datos de origen a lo largo de las dimensiones de calidad estándar antes de confiar en ellos:

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

    Salida esperada:

    ```
    +------------+--------------------+-------------------+-----------------+----------+------------------+-------------------+-------------------+
    | total_rows | occupation_unknown | workclass_unknown | country_unknown | age_null | age_out_of_range | implausible_hours | distinct_profiles |
    +------------+--------------------+-------------------+-----------------+----------+------------------+-------------------+-------------------+
    |      32561 |               1843 |              1836 |             583 |        0 |                0 |               340 |             25794 |
    +------------+--------------------+-------------------+-----------------+----------+------------------+-------------------+-------------------+
    ```

    Notá que `"?"` es un **valor faltante disfrazado de valor presente**. `COUNTIF(occupation IS NULL)` devuelve 0 y toda verificación ingenua de completitud pasa, mientras que el 5,7% de la columna está realmente ausente. La ausencia que se esconde de `IS NULL` es el defecto de calidad de datos más común en pipelines reales.

2. Mapeá lo que mediste sobre las dimensiones que usa el instrumental de calidad de datos de Google Cloud (calidad de datos automática de Dataplex):

    | Dimensión | Pregunta que plantea | Tu hallazgo de arriba |
    |---|---|---|
    | **Completitud** | ¿Están presentes los valores requeridos? | 1.843 ocupaciones con centinela `"?"` — falla, de forma invisible |
    | **Validez** | ¿Los valores se ajustan al dominio/formato permitido? | Espacio en blanco inicial en cada categórica; 340 filas > 90 h/semana |
    | **Exactitud** | ¿Los valores coinciden con el mundo real? | No verificable desde dentro de los datos — necesita una referencia externa |
    | **Consistencia** | ¿Los valores relacionados concuerdan entre sistemas? | No verificable acá — tabla única |
    | **Unicidad** | ¿Hay duplicados no intencionales? | 25.794 perfiles distintos de 32.561 filas |
    | **Oportunidad / frescura** | ¿Los datos son lo bastante recientes para ser verdaderos *ahora*? | Extracto censal de 1994 — **obsoleto por tres décadas** |

    Mirá bien la última fila. Este dataset se usa en todas partes como corpus de enseñanza, y todo modelo entrenado con él es un modelo del mercado laboral de Estados Unidos de **1994**. Sería indefendible en producción para cualquier decisión sobre una persona hoy. *La frescura es una dimensión de calidad de datos, y los datos obsoletos producen un modelo que está confiada y precisamente equivocado.*

3. Ahora demostrá el vínculo causal. Dañá los datos deliberadamente y reentrená. Primero construí una copia corrupta donde se destruye el 60% de los valores de `education_num`:

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

4. Reentrená con los datos degradados usando opciones **idénticas**:

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

5. Compará los dos modelos lado a lado:

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

    Salida esperada:

    ```
    +----------+---------+----------+-----------+--------+
    | dataset  | roc_auc | accuracy | precision | recall |
    +----------+---------+----------+-----------+--------+
    | clean    |  0.8934 |   0.8003 |    0.5468 | 0.8412 |
    | degraded |  0.8571 |   0.7784 |    0.5140 | 0.8206 |
    +----------+---------+----------+-----------+--------+
    ```

    Mismo algoritmo, mismos hiperparámetros, mismo código, mismo cómputo — **y un modelo peor**, porque la entrada era peor. Ninguna cantidad de ajuste del modelo recupera información que no está en los datos. Esto es lo que "basura entra, basura sale" significa cuantitativamente, y es por eso que la guía del examen ubica la calidad de datos *dentro* del objetivo de IA en lugar de al lado.

6. **[DEPTH]** Ahora la falla más sutil y peligrosa — la **fuga de datos** (data leakage). Entrená un modelo que incluya una característica que no existiría en el momento de la predicción:

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

    Salida esperada:

    ```
    +---------+----------+
    | roc_auc | accuracy |
    +---------+----------+
    |     1.0 |      1.0 |
    +---------+----------+
    ```

    Un modelo perfecto. También es completamente inútil: `tax_bracket_filed` es una copia de la respuesta, y en producción no se conocería hasta *después* del momento en que necesitabas la predicción. **Una métrica de evaluación sospechosamente perfecta es un reporte de bug, no un reporte de éxito.** La fuga es la razón por la que los resultados offline y los de producción divergen, y se detecta haciendo una pregunta sobre cada característica: *¿este valor realmente estaría disponible, con este contenido, en el instante en que se necesita la predicción?*

> **Fuentes:** Calidad de datos automática de Dataplex <https://cloud.google.com/dataplex/docs/auto-data-quality-overview> · Dimensiones de calidad de datos <https://cloud.google.com/dataplex/docs/data-quality-overview>

### Checkpoint 4

- **Q4.1** ¿Por qué `COUNTIF(occupation IS NULL)` devolvió 0 mientras 1.843 valores estaban genuinamente ausentes? ¿Qué enseña esto sobre las verificaciones automáticas de calidad?
- **Q4.2** ¿Qué dimensión de calidad viola la antigüedad de 1994 de este dataset, y por qué es la más peligrosa para una decisión de *negocio*?
- **Q4.3** En el paso 5 el modelo degradado perdió ~0,036 de ROC AUC. Explicale a un ejecutivo no técnico por qué "simplemente usá un algoritmo mejor" no lo recupera.
- **Q4.4** Tu equipo reporta un modelo de fraude con 99,98% de accuracy sobre un dataset donde el 0,02% de las transacciones son fraudulentas. Dá dos explicaciones distintas, una benigna y una alarmante.
- **Q4.5** Definí fuga de datos en una oración, y dá la única pregunta de prueba que la detecta.
- **Q4.6** La característica principal del modelo limpio fue `marital_status`. Nombrá un riesgo de negocio que esto crea y que una revisión puramente estadística no revelaría.

---

## Ejercicio 5 — Convertir un modelo en dinero: la economía del umbral **[CORE]**

**Objetivo:** Esta es la mitad de "cómo generan valor de negocio" del objetivo, y es la parte que la mayoría de los candidatos saltea. Un modelo emite una probabilidad. **Un resultado de negocio requiere un umbral, y el umbral lo fija la economía, no el científico de datos.**

### Escenario

Una firma de servicios financieros usa el modelo para seleccionar prospectos para un producto premium de asesoría.

| Evento | Significado | Valor |
|---|---|---|
| **Verdadero positivo** | El modelo dice alto ingreso, y lo es → la campaña convierte | **+ USD 180** de margen |
| **Falso positivo** | El modelo dice alto ingreso, y no lo es → contacto desperdiciado | **− USD 25** de costo |
| **Falso negativo** | El modelo dice que no, y lo era → oportunidad perdida | **− USD 40** atribuidos |
| **Verdadero negativo** | Correctamente omitido | **USD 0** |

### Pasos

1. Puntuá la población de evaluación una vez, conservando la probabilidad cruda en lugar de la decisión 0/1:

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

2. Barré el umbral de decisión y calculá la ganancia esperada en cada punto:

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

    Salida esperada (abreviada — tus cifras exactas van a diferir):

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

3. Leé la forma de esa curva, porque es toda la lección:

    - La ganancia **alcanza su pico cerca del umbral 0.20**, no en el estadísticamente natural 0.50.
    - En 0.50 — el valor por defecto con el que viene toda herramienta — la firma deja aproximadamente **USD 43.000 sobre la mesa** respecto del óptimo.
    - El óptimo es *bajo* porque un falso positivo cuesta USD 25 mientras que un verdadero positivo perdido cuesta USD 220 en margen no obtenido más atribución. **Cuando las omisiones son mucho más caras que las falsas alarmas, el modelo correcto es uno deliberadamente gatillo fácil.**
    - Cambiá un solo número de la economía — digamos que el contacto pasa a ser una visita presencial de USD 300 — y el óptimo se desplaza marcadamente hacia la derecha, sin ningún reentrenamiento.

4. **[DEPTH]** Calculá la línea base honesta. El valor es *incremental*, nunca absoluto:

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

    Salida esperada:

    ```
    +------------------+-----------+------------+
    |     strategy     | contacted | profit_usd |
    +------------------+-----------+------------+
    | contact everyone |      6512 |     158685 |
    | contact nobody   |         0 |     -62680 |
    +------------------+-----------+------------+
    ```

    **El verdadero valor de negocio del modelo es USD 200.620 − USD 158.685 ≈ USD 41.935**, no USD 200.620. La estrategia ingenua de "contactar a todos" ya captura la mayor parte del margen disponible. Cualquier caso de ROI que compare el modelo contra *cero* en lugar de contra *el proceso actual* está inflado, y esta es la forma más común en que se exageran los casos de negocio de IA. Contra esos ~USD 42k de margen anual incremental todavía tenés que restar entrenamiento, servicio, monitoreo y el tiempo de ingeniería para mantenerlo vivo.

> **Fuentes:** `ML.PREDICT` de BQML <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-predict> · Encuadre de valor de negocio en la guía del examen, Sección 3.

### Checkpoint 5

- **Q5.1** ¿Por qué el umbral que maximiza la ganancia es 0.20 y no 0.50? Dá la regla económica en una oración.
- **Q5.2** El costo de contacto sube de USD 25 a USD 120. Sin volver a ejecutar nada, predecí en qué dirección se mueve el umbral óptimo y por qué.
- **Q5.3** El modelo no fue reentrenado entre los umbrales 0.20 y 0.90. ¿Qué cambió exactamente?
- **Q5.4** Enunciá el valor de negocio incremental del modelo del paso 4, y explicá por qué citar la cifra bruta induce a error.
- **Q5.5** Un proveedor promociona "predicción de churn con 94% de accuracy". Enumerá tres preguntas que tenés que hacer antes de que ese número signifique algo financieramente.
- **Q5.6** ¿Cuál es el único insumo de negocio que, si el equipo de finanzas lo estima mal, más distorsiona el umbral óptimo acá?

---

## Ejercicio 6 — IA generativa: modelos fundacionales, tokens y alucinación **[CORE]**

**Objetivo:** Llamar a un modelo fundacional directamente, observar el precio basado en tokens, y reproducir una alucinación — el riesgo que el examen espera que sepas nombrar.

> **Costo:** un puñado de llamadas `generateContent` sobre un modelo de nivel Flash cuesta muy por debajo de USD 0,01. Confirmá las tarifas actuales en <https://cloud.google.com/vertex-ai/generative-ai/pricing>.

### Pasos

1. Hacé una llamada y leé todo el sobre de la respuesta, no solo el texto:

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

    Salida esperada (abreviada):

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

2. Extraé la unidad de facturación. **Se te cobra por token, de entrada y de salida, no por request:**

    ```bash
    python3 -c "
    import json; u = json.load(open('/tmp/resp.json'))['usageMetadata']
    print(f\"input={u['promptTokenCount']}  output={u['candidatesTokenCount']}  total={u['totalTokenCount']}\")"
    ```

    Salida esperada:

    ```
    input=27  output=61  total=88
    ```

3. Dimensioná una carga de trabajo antes de comprometerte con ella. Usá `:countTokens`, que es gratis y no ejecuta el modelo:

    ```bash
    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:countTokens" \
      -d @/tmp/req.json
    ```

    Salida esperada:

    ```json
    { "totalTokens": 27, "totalBillableCharacters": 108 }
    ```

    Ahora hacé la aritmética que realmente le piden a un líder. Tomá las tarifas *actuales* por millón de tokens de entrada y de salida de la página de precios de arriba — llamalas `$R_in` y `$R_out` — y estimá 500.000 tickets de soporte por mes con aproximadamente 800 tokens de entrada + 200 de salida cada uno:

    ```
    monthly input tokens  = 500,000 × 800 = 400,000,000  = 400 M
    monthly output tokens = 500,000 × 200 = 100,000,000  = 100 M
    monthly cost ≈ 400 × R_in + 100 × R_out
    ```

    Completá vos mismo las tarifas de hoy. **El hábito importa más que el número**: volumen de tokens × tarifa publicada, dimensionado *antes* del piloto, es como se defienden los presupuestos de IA generativa. Notá también la asimetría — los tokens de salida tienen un precio sustancialmente más alto que los de entrada, así que "hacé la respuesta más corta" es una palanca de costos real e inmediata.

4. Ahora inducí una alucinación. Preguntá por algo que plausiblemente podría existir pero no existe:

    ```bash
    curl -s -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${GEN_MODEL}:generateContent" \
      -d '{"contents":[{"role":"user","parts":[{"text":"Summarize the refund terms in section 7.4 of the Northwind Dynamics Enterprise Support Agreement, revision C."}]}],
           "generationConfig":{"temperature":0.9}}' \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['candidates'][0]['content']['parts'][0]['text'])"
    ```

    Comportamiento esperado: el modelo frecuentemente va a producir un resumen fluido, bien estructurado y redactado profesionalmente de un documento que **no existe** — créditos prorrateados, ventanas de aviso de 30 días, exclusiones nombradas. Ocasionalmente se va a negar. Ejecutalo dos o tres veces con `temperature: 0.9` y observá la variación.

    Esto es **alucinación**, y notá su forma real: la salida no está corrompida, es *confiada y plausible*. Un modelo fundacional está entrenado para producir continuaciones que suenen probables, no para saber si una fuente existe. La fluidez no es evidencia de verdad. Para el examen, tenés que poder decir: *la alucinación es el riesgo de que la IA generativa produzca salida confiada y coherente que es factualmente incorrecta.*

5. **[DEPTH]** Observá cómo la temperatura controla el compromiso entre determinismo y variedad:

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

    En `0.0` las dos ejecuciones son casi idénticas; en `1.0` divergen. **Temperatura baja para extracción, clasificación y trabajo de cumplimiento; temperatura más alta para ideación y redacción publicitaria.**

> **Fuentes:** Referencia de la API de inferencia <https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference> · Modelos Gemini <https://cloud.google.com/vertex-ai/generative-ai/docs/learn/models> · Precios de IA generativa <https://cloud.google.com/vertex-ai/generative-ai/pricing>

### Checkpoint 6

- **Q6.1** ¿Cuál es la unidad de facturación de una llamada a Gemini, y por qué "cantidad de llamadas a la API" falla como proxy de presupuesto?
- **Q6.2** ¿Por qué existe `:countTokens` como un endpoint gratuito separado? Nombrá la práctica de negocio que habilita.
- **Q6.3** Definí alucinación en términos del examen. ¿Por qué la *fluidez* de la salida es la parte peligrosa?
- **Q6.4** Para cada uno, elegí temperatura baja o alta y justificá en una cláusula: (a) extraer totales de facturas; (b) generar eslóganes publicitarios; (c) clasificar tickets de soporte en 12 categorías; (d) redactar candidatos a nombre de producto.
- **Q6.5** Los tokens de salida cuestan más que los de entrada. Nombrá dos palancas concretas de ingeniería que esta forma de precios justifica.

---

## Ejercicio 7 — Grounding y RAG: la solución a la alucinación **[CORE]**

**Objetivo:** Restringir un modelo fundacional a *tus* datos. La Generación Aumentada por Recuperación (RAG) es la respuesta a un escenario de examen muy común: "queremos que el modelo responda a partir de nuestros documentos internos".

> **Costo:** generar embeddings de un puñado de cadenas cortas cuesta una fracción de centavo.

### Pasos

1. Creá una conexión de BigQuery para que BigQuery pueda llamar a Vertex AI en tu nombre:

    ```bash
    bq mk --connection --location="$BQ_LOCATION" --project_id="$PROJECT_ID" \
      --connection_type=CLOUD_RESOURCE vertex_conn

    export CONN_SA=$(bq show --format=json --connection \
      "${PROJECT_ID}.${BQ_LOCATION}.vertex_conn" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['cloudResource']['serviceAccountId'])")
    echo "connection service account: $CONN_SA"
    ```

    Salida esperada:

    ```
    connection service account: bqcx-123456789012-ab3d@gcp-sa-bigquery-condel.iam.gserviceaccount.com
    ```

    Esa cuenta de servicio creada automáticamente es la identidad que BigQuery asume. Arranca con **cero permisos** — mínimo privilegio por defecto.

2. Otorgale exactamente un rol:

    ```bash
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${CONN_SA}" \
      --role="roles/aiplatform.user" --condition=None --quiet >/dev/null
    echo "granted"
    ```

3. Registrá el modelo de embeddings como modelo remoto:

    ```bash
    bq query --use_legacy_sql=false '
    CREATE OR REPLACE MODEL `'"${DATASET}"'.embedder`
    REMOTE WITH CONNECTION `'"${PROJECT_ID}.${BQ_LOCATION}"'.vertex_conn`
    OPTIONS (ENDPOINT = "'"${EMB_MODEL}"'")'
    ```

4. Creá una pequeña base de conocimiento privada — hechos que ningún modelo fundacional puede conocer, porque los acabás de inventar:

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

5. Generá los embeddings — convertí texto en vectores para que el *significado* se vuelva distancia medible:

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

    Salida esperada:

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

    Cada política es ahora un punto en un espacio de 768 dimensiones. El texto semánticamente similar aterriza cerca — ese es todo el mecanismo detrás de la búsqueda semántica.

6. Recuperá por significado, no por palabra clave. Notá que la consulta no usa ninguna de las palabras del documento:

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

    Salida esperada:

    ```
    +---------+----------+------------------------------------------------------------------------+
    | doc_id  | distance |                                snippet                                 |
    +---------+----------+------------------------------------------------------------------------+
    | POL-001 |   0.1832 | Northwind Dynamics issues refunds for annual Enterprise Support within  |
    | POL-003 |   0.4417 | Northwind Dynamics customers on the Standard tier receive two named su  |
    +---------+----------+------------------------------------------------------------------------+
    ```

    La consulta dijo "money back", el documento dice "refunds"; la consulta dijo "how long", el documento dice "45 calendar days". Un índice de palabras clave no habría devuelto nada. **Los embeddings hacen coincidir significado.**

7. Ahora cerrá el círculo: pasale el pasaje recuperado al modelo como contexto y hacé la misma pregunta que alucinó en el Ejercicio 6:

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

    Salida esperada (la sustancia, no la redacción):

    ```
    Refunds for annual Enterprise Support are issued within 45 calendar days of the
    renewal date, pro-rated by unused months, less a 4% administrative retention.
    ```

    **Los números inventados desaparecieron.** El modelo ahora reporta 45 días y 4% porque esos hechos fueron colocados en su ventana de contexto, no porque los supiera. No se reentrenó nada — los pesos del modelo son idénticos byte a byte a los del Ejercicio 6.

8. Verificá que la barrera de protección realmente se sostenga preguntando algo fuera de la base de conocimiento:

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

    Salida esperada:

    ```
    NOT IN POLICY
    ```

    Un sistema que puede decir "no sé" vale más en un negocio regulado que uno que acierta un poco más seguido pero nunca se abstiene.

> **Fuentes:** `ML.GENERATE_EMBEDDING` <https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-generate-embedding> · Búsqueda vectorial en BigQuery <https://cloud.google.com/bigquery/docs/vector-search> · Descripción general de grounding <https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview>

### Checkpoint 7

- **Q7.1** En el paso 7, ¿cambiaron los pesos del modelo? Entonces, ¿qué cambió, y cuál es el nombre general de esta técnica?
- **Q7.2** Explicá en términos de negocio por qué una búsqueda basada en embeddings encontró POL-001 cuando la consulta no compartía ninguna palabra clave con él.
- **Q7.3** Dá dos ventajas concretas de RAG frente a hacer fine-tuning de un modelo con los mismos documentos de políticas.
- **Q7.4** Nombrá un escenario donde RAG *no* es suficiente y el fine-tuning o el tuning es la mejor respuesta.
- **Q7.5** A la cuenta de servicio de la conexión se le otorgó `roles/aiplatform.user` y nada más. Nombrá el principio de seguridad, y decí qué se rompe si en cambio otorgás `roles/owner`.
- **Q7.6** Tu chatbot RAG responde preguntas de clientes a partir de una wiki interna. Alguien edita una página de la wiki. ¿Qué tiene que pasar para que el chatbot refleje el cambio, y cuál es la obligación operativa correspondiente?

---

## Ejercicio 8 — IA Responsable: filtros de seguridad, sesgo y la decisión humana **[CORE]**

**Objetivo:** Observar los controles de seguridad de la plataforma, y después demostrar que un modelo técnicamente sólido puede ser socialmente inaceptable — la razón por la que la IA Responsable es un tema de gobernanza, no de ingeniería.

### Pasos

1. Inspeccioná las calificaciones de seguridad que Vertex AI adjunta a cada respuesta por defecto:

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

    Salida esperada:

    ```
    finishReason: STOP
      HARM_CATEGORY_HATE_SPEECH                NEGLIGIBLE
      HARM_CATEGORY_DANGEROUS_CONTENT          NEGLIGIBLE
      HARM_CATEGORY_HARASSMENT                 NEGLIGIBLE
      HARM_CATEGORY_SEXUALLY_EXPLICIT          NEGLIGIBLE
    ```

    Cada llamada es puntuada en las cuatro categorías, lo hayas pedido o no. La seguridad es un valor por defecto de la plataforma, no un complemento que se compra.

2. Enviá un bloque explícito de `safetySettings` para ver que los umbrales son configurables por request:

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

    Salida esperada:

    ```
    promptFeedback: none
    finishReason: STOP
    ```

    Cuando una respuesta *sí* es bloqueada vas a ver `finishReason: SAFETY` y ningún `parts` — una aplicación que asume que `parts[0].text` siempre existe va a fallar en producción. Endurecer el umbral a `BLOCK_LOW_AND_ABOVE` reduce la salida dañina *y* aumenta los bloqueos falsos sobre contenido legítimo. **No existe una configuración que sea simplemente "segura"; existe un dial con costos en ambos extremos, y elegir dónde ponerlo es una decisión de negocio.**

3. Ahora la lección más difícil. Reentrená el modelo de ingresos **incluyendo** los atributos demográficos que excluimos deliberadamente en el Ejercicio 3:

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

    Salida esperada:

    ```
    +----------------------+---------+
    |        model         | roc_auc |
    +----------------------+---------+
    | without demographics |  0.8934 |
    | with race and sex    |  0.9012 |
    +----------------------+---------+
    ```

    **El modelo discriminatorio es mediblemente mejor.** Agregar `race` y `sex` mejoró el ROC AUC. Todo criterio estadístico lo prefiere. Si tu proceso de selección de modelos es "maximizar AUC", este modelo sale a producción.

4. Medí la disparidad que la métrica agregada ocultó:

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

    Salida esperada:

    ```
    +--------+-------+--------------------+-------------+
    |  sex   |   n   | avg_predicted_prob | actual_rate |
    +--------+-------+--------------------+-------------+
    | Male   | 21790 |             0.3814 |      0.3057 |
    | Female | 10771 |             0.1502 |      0.1095 |
    +--------+-------+--------------------+-------------+
    ```

    El modelo asigna a las mujeres aproximadamente el 40% del puntaje que asigna a los hombres. No está funcionando mal — aprendió fielmente un patrón **histórico** de un mercado laboral de 1994 moldeado por décadas de acceso desigual. Y eso es precisamente el peligro: **un modelo de ML entrenado con resultados históricos va a reproducir y operacionalizar la inequidad histórica, a escala, con la apariencia de objetividad matemática.** En un contexto de préstamos, contratación o seguros esto es una exposición legal, no meramente ética.

5. Reconocé que la solución no es puramente técnica. Quitar `race` y `sex` — que es lo que hizo el modelo del Ejercicio 3 — **no** elimina la disparidad, porque `relationship` (con valores como `Husband` y `Wife`) y `occupation` siguen siendo proxies correlacionados. Confirmalo:

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

    Salida esperada:

    ```
    +--------+--------------------+
    |  sex   | avg_predicted_prob |
    +--------+--------------------+
    | Male   |             0.3702 |
    | Female |             0.1631 |
    +--------+--------------------+
    ```

    Apenas se movió. **"Sacamos el atributo protegido" no es una defensa** — es la mitigación más común y menos efectiva, porque los proxies correlacionados llevan la misma señal. La mitigación real requiere medir resultados por grupo, fijar restricciones de equidad, documentar el uso previsto del modelo y — el control decisivo — **mantener a una persona responsable de la decisión.**

6. Leé la posición publicada actual de Google y notá la versión:

    ```bash
    echo "Google AI Principles ............ https://ai.google/principles/"
    echo "Responsible AI on Google Cloud .. https://cloud.google.com/responsible-ai"
    echo "Safety filter configuration ..... https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/configure-safety-filters"
    ```

    Una nota del instructor que vale la pena llevar al examen: **Google revisó sus Principios de IA en febrero de 2025**, reestructurándolos alrededor de innovación audaz, desarrollo y despliegue responsables, y progreso colaborativo. Buena parte del material de estudio de Cloud Digital Leader todavía enseña la formulación original de 2018 — siete principios más cuatro aplicaciones que Google no va a perseguir. Leé la redacción actual en el enlace de arriba en lugar de confiar en cualquier resumen secundario, incluido este; si un ítem del examen cita el texto de un principio, respondé desde el encuadre que la propia pregunta establece.

> **Fuentes:** Principios de IA de Google <https://ai.google/principles/> · IA Responsable <https://cloud.google.com/responsible-ai> · Filtros de seguridad <https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/configure-safety-filters>

### Checkpoint 8

- **Q8.1** El modelo con `race` y `sex` tuvo un ROC AUC *más alto*. Explicale a un ingeniero que quiere ponerlo en producción por qué "rinde mejor" no es un argumento suficiente.
- **Q8.2** En el paso 5, quitar los atributos protegidos apenas cambió la disparidad. Nombrá el mecanismo y decí por qué "no recolectamos ese campo" falla como respuesta de cumplimiento.
- **Q8.3** Endurecer un umbral de seguridad de `BLOCK_MEDIUM_AND_ABOVE` a `BLOCK_LOW_AND_ABOVE` reduce la salida dañina. ¿Qué cuesta, y quién debería decidirlo?
- **Q8.4** Tu aplicación lee `candidates[0].content.parts[0].text`. Describí el incidente de producción que esto causa y el `finishReason` que verías en los logs.
- **Q8.5** Dá el argumento más fuerte para mantener a una persona en el circuito en decisiones de alto riesgo, formulado de modo que un ejecutivo enfocado en costos lo acepte.
- **Q8.6** El modelo fue entrenado con datos de 1994. Conectá este hecho con las dimensiones de calidad de datos del Ejercicio 4 *y* con la equidad, en una oración.

---

## Ejercicio 9 — Elegir el nivel correcto de la escalera de IA, y limpieza **[CORE]**

**Objetivo:** Consolidar todo en el marco de decisión que el examen realmente evalúa, y después eliminar todos los recursos facturables.

### Pasos

1. Reconstruí la escalera a partir de lo que construiste. Cada peldaño cambia control por esfuerzo:

    | Peldaño | Lo que aportás vos | Lo que aporta Google | Lo construiste en | Tiempo hasta el valor |
    |---|---|---|---|---|
    | **1. API preentrenada** (Vision, Speech, Translation, Natural Language, Document AI) | Una llamada a la API | Modelo, datos de entrenamiento, operaciones | Ej. 2, paso 3 | Horas |
    | **2. Modelo fundacional + prompt** (Gemini vía Vertex AI) | Un prompt | Modelo, serving, seguridad | Ej. 6 | Horas |
    | **3. Modelo fundacional + grounding / RAG** | Tus documentos + recuperación | Modelo, embeddings, búsqueda vectorial | Ej. 7 | Días |
    | **4. Tuning** (fine-tuning supervisado / adaptadores) | Ejemplos etiquetados de tu tarea | Modelo base, infraestructura de tuning | — | Semanas |
    | **5. AutoML** (Vertex AI) | Dataset etiquetado + objetivo | Búsqueda de arquitectura, entrenamiento, serving | — | Días–semanas |
    | **6. Entrenamiento personalizado** (Vertex AI, BigQuery ML) | Datos, características, algoritmo, código | Cómputo gestionado, MLOps | Ej. 3 | Semanas–meses |

    **El valor por defecto correcto es el peldaño más bajo que resuelve el problema.** La mayoría de los proyectos de IA empresarial fallidos arrancaron tres peldaños demasiado arriba.

2. Practicá el mapeo. Para cada escenario, nombrá el peldaño y el producto de Google Cloud, y después verificate contra la clave de respuestas:

    | # | Escenario |
    |---|---|
    | a | Transcribir 12.000 horas de audio de call center a texto para análisis. |
    | b | Responder preguntas de RR.HH. de empleados a partir de un manual interno de 400 páginas, con citas. |
    | c | Predecir cuáles de 2 millones de suscriptores se van a dar de baja el mes que viene, a partir de 5 años de historial de facturación en BigQuery. |
    | d | Extraer proveedor, fecha y totales por línea de 40.000 facturas escaneadas en formatos mixtos. |
    | e | Detectar un defecto de fabricación visible solo para tus inspectores entrenados, a partir de 8.000 fotografías etiquetadas de tus propias piezas. |
    | f | Redactar una primera versión de copy de marketing en seis idiomas para el lanzamiento de un producto. |
    | g | Recomendar productos en un sitio de comercio electrónico según el comportamiento de navegación. |
    | h | Clasificar los tickets de soporte entrantes en tus 12 categorías internas, con 3.000 ejemplos históricos etiquetados. |

3. Confirmá lo que realmente gastaste:

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

    Salida esperada (abreviada):

    ```
    +-------------------------+--------------+----------------+
    |         job_id          | mb_processed | statement_type |
    +-------------------------+--------------+----------------+
    | bqjob_r3f8a2c1d0e94b7f  |         4.12 | CREATE_MODEL   |
    | bqjob_r7c2b9e4a1f08d3a  |         4.12 | CREATE_MODEL   |
    | bqjob_r1a4d6f9b2c73e05  |         3.88 | SELECT         |
    +-------------------------+--------------+----------------+
    ```

    Megabytes de un solo dígito. Cada conclusión de este laboratorio costó menos que un café — vale la pena recordarlo cuando alguien afirma que una prueba de concepto requiere un presupuesto de seis cifras.

4. **Limpiá.** Hacelo aunque los números parezcan triviales; dejar recursos atrás es cómo el gasto de laboratorio se convierte en gasto de producción:

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

5. Verificá que no sobrevivió nada:

    ```bash
    bq ls --datasets --project_id="$PROJECT_ID" | grep -c "$DATASET" || echo "dataset removed"
    bq ls --connection --location="$BQ_LOCATION" --project_id="$PROJECT_ID" 2>/dev/null | grep -c vertex_conn || echo "connection removed"
    ```

    Salida esperada:

    ```
    dataset removed
    connection removed
    ```

> **Fuentes:** Descripción general de Vertex AI <https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform> · Document AI <https://cloud.google.com/document-ai/docs/overview> · Speech-to-Text <https://cloud.google.com/speech-to-text/docs> · Arquitectura de MLOps <https://cloud.google.com/architecture/mlops-continuous-delivery-and-automation-pipelines-in-machine-learning>

### Checkpoint 9

- **Q9.1** Enunciá en una oración la regla de selección por defecto de la escalera, y el modo de fallo que previene.
- **Q9.2** Dá tu peldaño + producto para los ocho escenarios del paso 2.
- **Q9.3** Un equipo propone entrenar de forma personalizada un modelo de sentiment con 500 reseñas etiquetadas. Dá las dos objeciones más fuertes.
- **Q9.4** El peldaño 3 (RAG) y el peldaño 4 (tuning) adaptan ambos un modelo fundacional a tu negocio. Enunciá en una línea la regla para elegir entre ellos.
- **Q9.5** ¿Por qué el paso de limpieza revoca la vinculación de IAM además de eliminar la conexión?
- **Q9.6** Todo lo que construiste se midió sobre datos que nunca cambian. Nombrá qué requiere adicionalmente un despliegue en producción, y la capacidad de Google Cloud que lo aborda.

---

<details>
<summary><strong>Respuestas — abrir solo después de haber intentado todos los checkpoints</strong></summary>

### Checkpoint 1

**A1.1** **Sí** es IA, y **no** es ML. Califica como IA porque realiza una tarea que de otro modo requeriría juicio humano; no es ML porque su comportamiento fue escrito por personas, no aprendido de datos — presentado con nuevos datos de despacho no cambia nada hasta que una persona edita una regla. Esta es la forma más limpia de sostener la distinción: *los sistemas de ML cambian su comportamiento al ser expuestos a datos; los motores de reglas cambian solo al ser editados.*

**A1.2** Porque la IA generativa está construida a partir de redes neuronales profundas — es un *uso* del deep learning distinguido por su tipo de salida. La taxonomía anida por mecanismo en el nivel ML/DL y por salida en el nivel GenAI: el DL que emite una etiqueta es discriminativo; el DL que emite contenido nuevo es generativo.

**A1.3** No costó **nada**. Los servicios de IA de Google Cloud tienen precio por consumo: pagás por llamada a la API, por token, por hora-nodo o por byte procesado. Habilitar una API no genera ningún cargo. El principio general es **pagás por lo que consumís, no por aquello a lo que tenés acceso** — razón por la cual habilitar servicios para evaluación no conlleva riesgo financiero, aunque sí conlleva una consideración de superficie de seguridad.

**A1.4** Está entrenado una vez con datos amplios y generales y después se lo *adapta* a muchas tareas posteriores sin reentrenar desde cero — el "fundamento" es el preentrenamiento reutilizable, no la cantidad de parámetros. Un modelo meramente grande entrenado para una sola tarea no es un modelo fundacional.

### Checkpoint 2

**A2.1** (a) Estructurado. (b) No estructurado — un escaneo son píxeles; la estructura lógica de la factura no es legible por máquina hasta que se la extrae. (c) **Semiestructurado**, y estructurado en la práctica para analítica: BigQuery lo ingiere y lo consulta de forma nativa. (d) No estructurado.

**A2.2** **Aprendizaje no supervisado** — principalmente clustering. Produciría *agrupamientos* de registros similares sin nombres ni significado. Crucialmente, no puede decirte quién gana más de 50K, porque nada en los datos dice cómo se ve ganar más de 50K; una persona tiene que interpretar cada cluster después. La etiqueta es exactamente lo que separa supervisado de no supervisado.

**A2.3** Alcanza **75,92% de accuracy** siendo completamente inútil — identifica cero personas de altos ingresos, que es lo único que el negocio quería. Esta es la **paradoja de la accuracy** sobre datos desbalanceados: con clases sesgadas, la accuracy está dominada por la clase mayoritaria y esconde el fracaso total en la clase que importa. Pedí siempre la línea base de la clase mayoritaria antes de aceptar cualquier cifra de accuracy.

**A2.4** Algo así como: *"Feedback fuertemente mixto — el cliente estuvo frustrado por el onboarding y encantado con el soporte; un score promedio cercano a cero acá significa dos reacciones opuestas fuertes que se cancelan, no indiferencia."* El error a evitar es reportar "sentiment neutral", que pierde tanto el riesgo de churn como el logro del soporte.

**A2.5** **Document AI** — construido específicamente para extraer campos estructurados de documentos, con procesadores preentrenados para facturas, recibos y formularios. Un modelo fundacional general puede leer una factura, pero Document AI devuelve campos tipados y anclados posicionalmente con puntajes de confianza por campo, tiene precio por página para exactamente esta carga de trabajo, y no alucina un total que no está en la página. Usá el servicio especializado cuando existe un servicio especializado.

### Checkpoint 3

**A3.1** El *entrenamiento* es el proceso de aprender parámetros a partir de datos históricos, produciendo un artefacto de modelo reutilizable. La *inferencia* es aplicar ese modelo terminado a datos nuevos para producir una predicción. Las formas de costo difieren: el entrenamiento es un costo **episódico, similar a un gasto de capital** — grande, acotado, repetido solo cuando reentrenás; la inferencia es un costo **operativo, por transacción** — mínimo individualmente, no acotado en agregado, escalando directamente con el volumen del negocio. Como la inferencia es recurrente, suele dominar el costo total de propiedad aunque el entrenamiento tenga la línea de factura más grande.

**A3.2** Previene que el **sobreajuste** (overfitting) pase inadvertido. Un modelo puede memorizar sus datos de entrenamiento y puntuar casi perfecto sobre ellos mientras generaliza pésimo. Evaluar sobre datos retenidos del entrenamiento es la única forma de medir el desempeño sobre entradas que el modelo genuinamente nunca vio — que es la única condición que existe en producción.

**A3.3** Precision = TP / (TP + FP) = 1318 / (1318 + 1080) = 1318 / 2398 = **0,5496**. Recall = TP / (TP + FN) = 1318 / (1318 + 249) = 1318 / 1567 = **0,8411**. Coinciden con `ML.EVALUATE` salvo redondeo. En palabras: el 55% de las personas que marcó eran de altos ingresos; encontró al 84% de las personas de altos ingresos que existían.

**A3.4** **El ROC AUC de 0,89.** La línea base alcanza 0,76 de accuracy pero *no tiene ninguna capacidad de ordenamiento* — su AUC es 0,5, equivalente a tirar una moneda. El modelo puede ordenar a una persona de altos ingresos tomada al azar por encima de una de bajos ingresos tomada al azar el 89% de las veces, y el ordenamiento es lo que realmente crea valor: le permite al negocio gastar un presupuesto limitado de contacto primero en los prospectos de mayor probabilidad. La accuracy mide una decisión en un umbral fijo; el AUC mide la calidad del ordenamiento subyacente, que es lo que se monetiza.

**A3.5** La explicabilidad es un requisito **regulatorio y operativo**, no una curiosidad. Los regímenes de servicios financieros, seguros, salud y empleo requieren cada vez más una explicación para una decisión automatizada adversa. Más allá del cumplimiento habilita tres cosas: detectar proxies de atributos protegidos antes del lanzamiento, depurar el drift viendo *cuál* característica cambió su influencia, y — en la práctica lo más importante — ganarse la confianza de los expertos del dominio cuya adopción determina si el modelo se usa o no.

**A3.6** El entrenamiento es el menor de los costos recurrentes. Los costos continuos son: **inferencia**, cobrada por predicción para siempre y escalando con el volumen del negocio; **reentrenamiento**, porque el mundo cambia y el modelo se degrada; **monitoreo**, para detectar esa degradación antes que los clientes; operación del **pipeline de datos** para mantener las entradas fluyendo y limpias; y **tiempo de ingeniería**, habitualmente la línea más grande de todas. Un modelo es un sistema que hay que operar, no un artefacto que está terminado.

### Checkpoint 4

**A4.1** Porque la ausencia estaba codificada como la **cadena centinela `"?"`**, que desde la perspectiva de SQL es un valor presente. La lección: las verificaciones automáticas de calidad solo detectan los defectos que fueron escritas para buscar. La verificación genérica de nulos es necesaria y ni de cerca suficiente — hay que perfilar las distribuciones reales de valores, y cualquier valor categórico de alta frecuencia sin explicación (`"?"`, `"N/A"`, `"UNKNOWN"`, `-1`, `1900-01-01`) es un indicador de datos faltantes disfrazado.

**A4.2** **Oportunidad / frescura.** Es la dimensión más peligrosa para decisiones de negocio porque falla *silenciosa y confiadamente*: los datos incompletos o inválidos habitualmente se anuncian con errores o métricas degradadas, mientras que los datos obsoletos producen un modelo internamente consistente, estadísticamente excelente, y que describe un mundo que ya no existe. Un modelo de ingresos de 1994 puntuaría alto en toda métrica offline y sería indefendible para cualquier decisión sobre una persona en 2026.

**A4.3** Porque el algoritmo no perdió la información — la perdieron los **datos**. Un algoritmo solo puede encontrar patrones que están presentes en lo que se le da; cuando el 60% de una columna predictiva se destruye, esa señal predictiva ya no existe en ninguna parte del dataset, y ninguna sofisticación del modelo puede reconstruirla. La analogía que funciona con ejecutivos: un analista mejor no puede recuperar cifras arrancadas del libro contable. Por esto la inversión en ingeniería y gobernanza de datos suele rendir más que la inversión en modelos.

**A4.4** *Benigna:* la métrica simplemente no es informativa — predecir siempre "no es fraude" puntúa 99,98%, así que el número refleja el desbalance de clases y no habilidad; el equipo debería estar reportando precision, recall y AUC sobre la clase de fraude. *Alarmante:* **fuga de datos** — una característica está codificando la respuesta, como un campo `chargeback_flag`, `investigation_opened` o `account_frozen` que solo se completa *después* de que el fraude fue descubierto. Offline parece perfecto; en producción el campo está vacío en el momento del scoring y el modelo se derrumba.

**A4.5** La fuga de datos es la presencia, en los datos de entrenamiento, de información que no estaría disponible en el momento en que debe hacerse una predicción real. La pregunta de detección: **"En el instante en que se necesita esta predicción, ¿existiría esta característica, con este valor exacto, sin conocer el resultado?"** Si la respuesta es no o "todavía no", hay fuga.

**A4.6** `marital_status` es un fuerte **proxy del sexo y de los roles históricos del hogar** — sus categorías interactúan con valores de `relationship` como `Husband` y `Wife`. Un modelo que se apoya en ella puede producir resultados sistemáticamente distintos para varones y mujeres aunque el sexo nunca haya sido provisto, creando exposición a discriminación en cualquier uso de préstamos, contratación o fijación de precios. Una revisión puramente estadística ve una característica útil de alta atribución y la aprueba; solo una revisión que pregunta qué *significa socialmente* una característica detecta esto. El Ejercicio 8 lo demuestra empíricamente.

### Checkpoint 5

**A5.1** Porque el costo de una omisión (USD 40 de pérdida atribuida más USD 180 de margen no obtenido = USD 220 de valor sacrificado) supera enormemente el costo de una falsa alarma (USD 25). La regla: **bajá el umbral cuando los falsos negativos cuestan más que los falsos positivos; subilo cuando los falsos positivos cuestan más.** El umbral lo fija la razón entre los costos de error, no la convención estadística — 0,50 es un valor por defecto, nunca una respuesta.

**A5.2** Se mueve **hacia arriba (derecha)** — hacia mayor selectividad. A medida que el contacto desperdiciado se vuelve más caro, cada falso positivo destruye más valor, así que el modelo tiene que estar más seguro antes de recomendar el contacto. Notá que esto ocurrió **sin ningún reentrenamiento**: las mismas probabilidades, leídas contra una economía diferente, producen una política óptima diferente.

**A5.3** Solo la **regla de decisión** aplicada a la salida del modelo. El modelo, sus pesos, y la probabilidad asignada a cada individuo son idénticos en cada umbral. Esta es la ilustración más nítida del punto central del dominio: **el modelo produce una probabilidad; el negocio produce la decisión.** El umbral es un artefacto de negocio y debería ser propiedad del negocio, revisado y versionado por él, no enterrado en el notebook de un científico de datos.

**A5.4** El valor incremental es aproximadamente **USD 41.935** (USD 200.620 en el umbral óptimo, menos USD 158.685 del enfoque existente de "contactar a todos"). Citar los USD 200.620 brutos induce a error porque le acredita al modelo un margen que el negocio *ya* estaba capturando sin él. Todo caso de negocio de IA debe medirse contra el **proceso actual**, no contra no hacer nada — y el residuo todavía debe cubrir el costo de entrenamiento, servicio, monitoreo e ingeniería antes de que el proyecto sea realmente rentable.

**A5.5** (1) *¿Cuál es la tasa base?* — 94% de accuracy sobre una población con 6% de churn puede ser peor que predecir "nadie se da de baja". (2) *¿Cuáles son precision y recall sobre la clase de churn específicamente, y en qué umbral?* — el agregado esconde el único desempeño que importa. (3) *¿Cuánto nos cuesta cada tipo de error en moneda?* — sin el costo de una oferta de retención desperdiciada frente al valor de vida de un cliente perdido, ninguna cifra de accuracy puede convertirse en dinero. Una cuarta que vale la pena: *¿qué logra nuestro proceso actual?*

**A5.6** El **costo atribuido a un falso negativo** (los USD 40 más los USD 180 de margen no obtenido). Es a la vez el término más grande de la función de ganancia y el número más blando — los valores de oportunidad perdida se estiman, no se observan, e inflarlos empuja el umbral óptimo hacia abajo, haciendo que el negocio contacte a muchas más personas de las que es realmente rentable. Merece un análisis de sensibilidad antes de que alguien comprometa un presupuesto de campaña.

### Checkpoint 6

**A6.1** El **token** — unidades de sub-palabra, facturadas por separado para la entrada (prompt) y la salida (completion), y con precios distintos para cada una. "Llamadas a la API" falla como proxy de presupuesto porque el costo por llamada varía en órdenes de magnitud: resumir una pregunta de una línea y resumir un contrato de 200 páginas son ambas una llamada. Presupuestá sobre **volumen de tokens esperado × tarifa publicada**, y tratá el tamaño de la ventana de contexto como un impulsor directo de costo.

**A6.2** Porque necesitás dimensionar y costear una carga de trabajo **antes** de pagar por ejecutarla. `:countTokens` es gratis y no invoca al modelo, así que podés medir prompts reales contra documentos reales y producir un pronóstico de costo defendible para un piloto. También habilita un control en tiempo de ejecución: verificar la cantidad de tokens antes del envío y rechazar o truncar entradas sobredimensionadas, evitando que un único documento patológico genere un cargo sin límite.

**A6.3** La alucinación es la IA generativa produciendo salida **fluida, confiada y factualmente incorrecta** — contenido que es estadísticamente plausible en lugar de verificado. La fluidez es la parte peligrosa porque las personas usan la coherencia y la confianza como sustitutos de la exactitud: una respuesta corrompida se chequea, mientras que una respuesta bien formateada que cita un número de cláusula específico se pega en un correo a un cliente. La confianza es el mecanismo de entrega del error.

**A6.4** (a) **Baja** (≈0) — la extracción debe ser determinista y reproducible; la misma factura debe dar el mismo total siempre. (b) **Alta** (≈0,9) — la variedad es el entregable. (c) **Baja** — la clasificación en una taxonomía fija debe ser estable y auditable. (d) **Alta** — querés un conjunto diverso de candidatos entre los cuales elegir.

**A6.5** (1) **Limitar la longitud de la salida** — `maxOutputTokens` más instrucciones en el prompt como "respondé en tres oraciones" o "devolvé solo JSON"; un modelo verborrágico es un sobrecosto directo. (2) **Diseñar esquemas de salida escuetos** — devolver JSON estructurado con códigos en lugar de narrativa en prosa, y dejar que la aplicación renderice localmente y gratis el texto legible por humanos. Palancas relacionadas que vale la pena nombrar: elegir un modelo de nivel Flash para tareas simples de alto volumen, agrupar en lotes, y cachear el contexto repetido.

### Checkpoint 7

**A7.1** No — los pesos son idénticos byte a byte. Lo que cambió es la **entrada**: se colocó texto recuperado relevante en la ventana de contexto del prompt, y la instrucción restringió al modelo a responder solo a partir de él. La técnica es **grounding**, y este patrón específico de recuperar-y-luego-generar es **Generación Aumentada por Recuperación (RAG)**. Vale la pena enunciar la distinción con precisión para el examen: el grounding cambia lo que el modelo *ve*; el tuning cambia lo que el modelo *es*.

**A7.2** Los embeddings convierten texto en vectores numéricos posicionados de modo que **el significado similar aterriza en coordenadas cercanas**. "Money back" y "refund" expresan el mismo concepto, así que sus vectores quedan cerca aunque no compartan ningún carácter. La búsqueda por palabra clave hace coincidir cadenas; la búsqueda vectorial hace coincidir significado. En términos de negocio: los clientes no formulan sus preguntas con el vocabulario de tu documentación, y la búsqueda semántica es lo que cierra esa brecha.

**A7.3** (1) **Frescura** — actualizás un documento y la próxima consulta lo refleja de inmediato, sin reentrenamiento; un modelo ajustado queda congelado en su instantánea de tuning. (2) **Atribución y auditabilidad** — RAG devuelve el pasaje fuente, así que la respuesta es citable y una persona puede verificarla, lo que suele ser un requisito duro en entornos regulados. Puntos fuertes adicionales: costo y tiempo hasta el valor dramáticamente menores, y el control de acceso puede aplicarse en el momento de la recuperación de modo que cada usuario solo recupere los documentos a los que tiene derecho.

**A7.4** Cuando necesitás cambiar el **comportamiento, formato, tono o vocabulario de dominio** del modelo en lugar de proveerle hechos. Ejemplos: producir consistentemente salida en un formato estructurado propietario, adoptar un registro clínico o legal especializado, o manejar un dominio cuya terminología está mal representada en el preentrenamiento. Regla práctica: *hechos → RAG; comportamiento y estilo → tuning.* Las dos se componen — un modelo ajustado consumiendo contexto con grounding es común.

**A7.5** **Mínimo privilegio.** La conexión necesita exactamente una capacidad — invocar predicciones de Vertex AI — así que recibe exactamente `roles/aiplatform.user`. Otorgar `roles/owner` significaría que cualquier sentencia SQL que referencie esa conexión se ejecuta con control total del proyecto, incluyendo leer todos los datasets, alterar la política de IAM y borrar recursos; una única consulta defectuosa o maliciosa se convierte en un compromiso total del proyecto. También destruye el significado del rastro de auditoría, ya que toda acción aparece como una identidad omnipotente.

**A7.6** La página modificada debe ser **re-embebida** y su vector actualizado en el índice — el chatbot responde desde el almacén vectorial, no desde la wiki, así que un índice sin refrescar sirve políticas desactualizadas con toda confianza. La obligación operativa es un **pipeline que mantenga los embeddings sincronizados con la fuente de verdad**, con un SLA de frescura definido y monitoreo sobre él. Este es el costo rutinariamente subestimado de RAG: el índice de recuperación es un sistema de datos productivo que requiere el mismo cuidado que cualquier otro.

### Checkpoint 8

**A8.1** Porque "rinde mejor" mide solo la exactitud predictiva, y la exactitud predictiva no es el único requisito que un sistema en producción debe satisfacer. El modelo demográfico logra su AUC más alto **aprendiendo discriminación histórica y aplicándola hacia adelante** — es más exacto reproduciendo un pasado injusto. Eso crea exposición legal bajo la legislación antidiscriminatoria en préstamos, contratación, vivienda y seguros; riesgo reputacional; y un fracaso ético genuino independientemente de si alguien demanda. Los criterios de selección de modelos deben incluir restricciones de equidad, documentación de uso previsto y responsabilidad humana junto con el AUC. Una mejora de 0,008 en AUC no es una defensa en un procedimiento regulatorio.

**A8.2** El mecanismo son las **variables proxy** (a veces llamadas codificación redundante): otras características correlacionan con el atributo protegido y llevan la misma información. Acá `relationship` (`Husband`/`Wife`) y `occupation` reconstruyen el sexo casi perfectamente, así que la disparidad sobrevive a quitar la columna `sex`. "No recolectamos ese campo" falla como cumplimiento porque los reguladores y los tribunales evalúan el **impacto dispar sobre los resultados**, no el esquema de entrada — un modelo que produce resultados sistemáticamente peores para un grupo protegido es un problema sin importar qué columnas leyó. El único control significativo es medir resultados por grupo, lo que paradójicamente requiere recolectar el atributo para auditoría mientras se lo excluye de las características.

**A8.3** Cuesta **falsos positivos sobre contenido legítimo** — un servicio médico bloqueando descripciones clínicas, un equipo de seguridad bloqueando discusión de inteligencia de amenazas, una editora de videojuegos bloqueando resúmenes argumentales ordinarios. Cada respuesta bloqueada erróneamente es una experiencia de usuario rota y un ticket de soporte. La decisión le corresponde al **dueño de negocio de la aplicación en consulta con legales, riesgo y trust-and-safety**, informado por el perfil de daño real del caso de uso — no a quien esté escribiendo el cliente de la API. Un producto educativo para chicos y un asistente interno de investigación en seguridad justifican configuraciones opuestas.

**A8.4** La respuesta fue **bloqueada por un filtro de seguridad**, así que `candidates[0].content` no tiene arreglo `parts`; el código lanza un `KeyError`/`IndexError` y, si no se maneja, devuelve un 500 al usuario o mata al worker. Los logs muestran **`finishReason: SAFETY`** — y posiblemente un `promptFeedback.blockReason` poblado cuando lo bloqueado fue el *prompt* y no la respuesta. Manejo correcto: siempre ramificar según `finishReason` (`STOP`, `MAX_TOKENS`, `SAFETY`, `RECITATION`, otros) antes de tocar `parts`, y devolver un mensaje de fallback diseñado. Notá que esto también significa que los filtros de seguridad son una preocupación de **confiabilidad**, no solo de ética.

**A8.5** **La organización sigue siendo legal y reputacionalmente responsable de la decisión, haya sido o no una máquina la que la tomó.** No podés delegar la responsabilidad en un modelo — ningún regulador, tribunal ni cliente acepta "lo decidió el algoritmo" como defensa. Un revisor humano en las decisiones de alto riesgo no es entonces sobrecarga; es el control que mantiene el riesgo asegurable y la decisión defendible, y es mucho más barato que un solo acuerdo por discriminación, una sola acción regulatoria, o una sola pérdida de licencia para operar. Presentalo como fijación del precio de transferencia de riesgo, no como gasto en ética.

**A8.6** La antigüedad de 1994 viola la **oportunidad/frescura**, y como esos datos obsoletos codifican un mercado laboral moldeado por décadas de acceso desigual, la falla de frescura y la falla de equidad son el mismo defecto visto dos veces: el modelo no está meramente describiendo un mundo desactualizado, está **proyectando la inequidad histórica hacia adelante como una predicción sobre personas de hoy**.

### Checkpoint 9

**A9.1** **Elegí el peldaño más bajo de la escalera que resuelva el problema.** Previene el modo de fallo dominante de la IA empresarial: equipos construyendo modelos personalizados para problemas ya resueltos por una API preentrenada o un modelo fundacional bien prompteado, gastando meses y salarios de especialistas para alcanzar — a menudo para quedarse cortos de — un resultado disponible desde el día uno. Escalá un peldaño solo cuando tengas evidencia de que el inferior es insuficiente.

**A9.2**
- **(a)** Peldaño 1 — **Speech-to-Text**. La transcripción es una tarea universal sin ventaja de datos propietarios.
- **(b)** Peldaño 3 — **RAG en Vertex AI** (Vertex AI Search / grounding con Gemini). Los hechos son privados y cambian; se requieren citas.
- **(c)** Peldaño 6 — **BigQuery ML**. Los datos ya están en BigQuery, la tarea es clasificación binaria tabular, y entrenar in situ evita mover 5 años de historial de facturación a ninguna parte.
- **(d)** Peldaño 1 — **Document AI** (procesador de facturas). Construido a propósito, devuelve campos tipados con puntajes de confianza.
- **(e)** Peldaño 5 — **Vertex AI AutoML (clasificación de imágenes)**. El defecto es específico de tus piezas, así que ningún modelo preentrenado lo conoce; 8.000 imágenes etiquetadas alcanzan para AutoML y no justifican trabajo de arquitectura personalizada.
- **(f)** Peldaño 2 — **Gemini vía Vertex AI**, temperatura alta. Tarea generativa, no se necesitan hechos propietarios. (Translation API es la respuesta de peldaño 1 si el copy ya existe y solo necesita traducción.)
- **(g)** Peldaño 1/5 — **Vertex AI Search for commerce / Recommendations**, un servicio gestionado de recomendaciones. Construir un recomendador desde cero es una sobre-escalada clásica.
- **(h)** Peldaño 2 o 4 — arrancá con **Gemini más un prompt bien diseñado que enumere las 12 categorías** y medilo contra los 3.000 ejemplos etiquetados; escalá a **tuning supervisado** solo si la exactitud basada en prompt es insuficiente. El mejor primer uso del conjunto etiquetado es como conjunto de *evaluación*, no de entrenamiento.

**A9.3** (1) **El dataset es demasiado chico** para que el entrenamiento personalizado supere a las alternativas — 500 ejemplos van a sobreajustar y generalizar mal. (2) **El problema ya está resuelto en el peldaño 1 y el peldaño 2**: la API de Natural Language devuelve sentiment con cero datos de entrenamiento, y un modelo fundacional prompteado maneja sentiment matizado o específico del dominio; cualquiera de los dos sale en horas en lugar de meses. Una tercera objeción que vale la pena agregar: las 500 etiquetas son mucho más valiosas como **conjunto de evaluación** para medir la opción llave en mano que elijas que como datos de entrenamiento.

**A9.4** **Si la brecha es de conocimiento, usá RAG; si la brecha es de comportamiento, usá tuning.** Hechos faltantes o cambiantes → recuperación. Formato, tono, registro o estilo de razonamiento específico del dominio equivocados → tuning. Cuando faltan ambos, ajustá para el comportamiento y hacé grounding para los hechos.

**A9.5** Porque eliminar la conexión remueve el *recurso* pero no la **vinculación de política de IAM**, que referencia al principal de la cuenta de servicio en la política del proyecto. Si queda atrás, se convierte en una concesión huérfana — un permiso adjunto a ningún recurso revisable, ensuciando la política y erosionando gradualmente el sentido de una revisión de accesos. Limpiar significa restaurar la postura de seguridad, no solo detener la facturación.

**A9.6** Requiere **monitoreo de drift y reentrenamiento continuo** — las distribuciones de datos en producción se desplazan (comportamiento del cliente, mix de productos, estacionalidad, cambios de esquema aguas arriba), así que un modelo que era exacto al lanzamiento se degrada silenciosamente mientras sigue devolviendo predicciones confiadas. Google Cloud lo aborda con **Vertex AI Model Monitoring** para el sesgo entrenamiento-servicio y el drift de predicción, dentro de la práctica más amplia de **MLOps** de pipelines de entrenar–evaluar–desplegar automatizados, versionados y repetibles (Vertex AI Pipelines, Model Registry). El punto que resume esto para el examen: **desplegar un modelo es el comienzo de su costo y su riesgo, no el final.**

</details>