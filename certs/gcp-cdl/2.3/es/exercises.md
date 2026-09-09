# Tema 2.3 — Ejercicios guiados

## Smart analytics, business intelligence y streaming analytics: valor en casos de uso de negocio reales

**Certificación:** Google Cloud Digital Leader (versión del examen 2026-08-12) · **Sección 2.3** · **Peso en el examen: 6.0**

Estos ejercicios se construyen alrededor de una afirmación que el examen evalúa una y otra vez con distintos disfraces: *el valor de una plataforma de analítica no es "guardamos datos", es el **tiempo hasta la respuesta**, el **costo por respuesta** y **quién tiene permitido preguntar**.* Cada bloque de abajo te hace producir un número medible para uno de esos tres, y después te pide traducirlo al lenguaje que un CFO o un responsable de línea de negocio realmente compra.

Vas a ejecutar comandos reales. Donde un paso cuesta dinero más allá de la capa gratuita está marcado con **`[$]`** y señalado como opcional.

---

## Prerrequisitos

### Bloque 0.1 — Entorno y controles de costo

1. Abrí Cloud Shell (o una shell local con la CLI de `gcloud` y `bq` instaladas) y confirmá tu identidad y proyecto:

```bash
gcloud auth list
gcloud config list project
```

Salida esperada:

```
              Credentialed Accounts
ACTIVE  ACCOUNT
*       you@example.com

[core]
project = my-cdl-project
```

2. Exportá las variables que reutilizan todos los bloques posteriores:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export REGION="us-central1"
export BQ_LOCATION="US"
export DS="cdl_23_analytics"

echo "$PROJECT_ID / $PROJECT_NUMBER / $REGION / $BQ_LOCATION / $DS"
```

3. Habilitá las APIs que se usan en este tema:

```bash
gcloud services enable \
  bigquery.googleapis.com \
  bigqueryconnection.googleapis.com \
  pubsub.googleapis.com \
  dataflow.googleapis.com \
  datalineage.googleapis.com
```

Salida esperada (la primera ejecución tarda 30–60 s, después silencio si todo va bien):

```
Operation "operations/acat.p2-123456789012-8f2b...-c1e0" finished successfully.
```

4. Creá el dataset que va a contener todo lo que construyas. Prestá atención a la **location** explícita: es una propiedad permanente del dataset y no se puede cambiar después:

```bash
bq --location="$BQ_LOCATION" mk -d \
  --description "CDL 2.3 exercises" \
  "${PROJECT_ID}:${DS}"
```

Salida esperada:

```
Dataset 'my-cdl-project:cdl_23_analytics' successfully created.
```

5. Confirmá tu posición en la capa gratuita antes de gastar nada. La capa gratuita de BigQuery cubre **1 TiB de bytes procesados por consulta al mes** y **10 GiB de almacenamiento activo**; un `--dry_run` no cuesta absolutamente nada.

**Verificación de comprensión — Bloque 0.1**

- **Q0.1** — Creaste el dataset en la multirregión `US`. Más adelante una filial necesita que las mismas tablas estén físicamente almacenadas en `europe-west1` por un requisito de residencia de datos. ¿Cuál es la respuesta técnicamente correcta más corta, y qué implica eso sobre la *primera* decisión de cualquier proyecto de analítica?
- **Q0.2** — ¿Por qué un `--dry_run` es una funcionalidad estratégicamente importante para un negocio, y no solo una comodidad para el desarrollador?
- **Q0.3** — ¿Cuál de estas es una decisión de *servicio gestionado* y cuál es una decisión de *arquitectura*: (a) elegir BigQuery en lugar de un clúster Hadoop autogestionado, (b) particionar una tabla por día?

---

## Ejercicio 1 — Tiempo hasta la respuesta: consultar un dataset público a escala de petabytes sin infraestructura

El hecho de negocio más subestimado sobre BigQuery es que una analista de negocio puede consultar un dataset de varios terabytes **sin que nadie tenga que aprovisionar, dimensionar, parchear o escalar un clúster antes**. Esa es la propuesta de valor "serverless" de la sección 2.3.

### Bloque 1.1 — Hacerle una pregunta a datos que nunca cargaste

1. Estimá, sin ejecutarla, el costo de escanear una tabla pública grande:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT term, COUNT(*) AS appearances
 FROM `bigquery-public-data.google_trends.top_terms`
 GROUP BY term
 ORDER BY appearances DESC
 LIMIT 10'
```

Salida esperada (tu conteo de bytes va a diferir — el dataset crece a diario):

```
Query successfully validated. Assuming the tables are not modified, running this query will process 41837294518 bytes of data.
```

2. **No ejecutes esa consulta.** Convertí la estimación a dinero y a consumo de la capa gratuita:

```bash
python3 -c "b=41837294518; t=b/2**40; print(f'{t:.3f} TiB -> approx \${t*6.25:.2f} on-demand')"
```

Salida esperada:

```
0.038 TiB -> approx $0.24 on-demand
```

3. Ahora agregá un filtro sobre la **columna de particionamiento** de la tabla (`refresh_date`) y volvé a hacer un dry-run:

```bash
bq query --use_legacy_sql=false --dry_run \
'SELECT term, rank, refresh_date
 FROM `bigquery-public-data.google_trends.top_terms`
 WHERE refresh_date = DATE_SUB(CURRENT_DATE(), INTERVAL 2 DAY)
   AND rank <= 5
 ORDER BY rank'
```

Salida esperada — de uno a tres órdenes de magnitud más chica:

```
Query successfully validated. Assuming the tables are not modified, running this query will process 24117248 bytes of data.
```

4. Ejecutá la barata y mirá el tiempo de reloj:

```bash
time bq query --use_legacy_sql=false --format=pretty \
'SELECT term, rank, refresh_date
 FROM `bigquery-public-data.google_trends.top_terms`
 WHERE refresh_date = DATE_SUB(CURRENT_DATE(), INTERVAL 2 DAY)
   AND rank <= 5
 ORDER BY rank'
```

Salida esperada:

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

**Verificación de comprensión — Bloque 1.1**

- **Q1.1** — Nunca creaste un clúster, nunca dimensionaste una máquina y nunca esperaste una carga de datos. Nombrá las dos líneas de costo que un data warehouse on-premises equivalente tendría y que acá no aparecieron en absoluto.
- **Q1.2** — Los pasos 1 y 3 usan la *misma tabla*. Explicá, en una sola frase que un interlocutor no técnico aceptaría, por qué una cuesta ~1.700× más que la otra.
- **Q1.3** — Marketing quiere enriquecer los datos de sus campañas con Google Trends. En el modelo clásico on-premises, ¿cuál es la tarea de varias semanas que este ejercicio hizo desaparecer por completo? ¿Cómo se llama la capacidad general que hace que datasets de terceros sean consultables en el lugar?

---

## Ejercicio 2 — Costo por respuesta: particionamiento y clustering como palanca de negocio

Cada refresco de dashboard es una consulta, y cada consulta es una factura. Este bloque convierte una decisión de esquema en un porcentaje sobre una factura.

### Bloque 2.1 — Construir una tabla ingenua y una tabla diseñada

1. Creá una copia deliberadamente ingenua de una tabla de hechos de pedidos de retail (sin particionamiento, sin clustering), enriquecida con el país del cliente:

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

Salida esperada:

```
Waiting on bqjob_r2a91f0c7de3b45f8_0000019a3f31a7c2_1 ... (7s) Current status: DONE
```

2. Creá la gemela diseñada — mismas filas, particionada por día y clusterizada por las dos columnas por las que más filtran los analistas:

```bash
bq query --use_legacy_sql=false --nouse_cache "
CREATE OR REPLACE TABLE \`${PROJECT_ID}.${DS}.orders_part\`
PARTITION BY order_day
CLUSTER BY country, status
AS SELECT * FROM \`${PROJECT_ID}.${DS}.orders_naive\`
"
```

3. Confirmá que ambas contienen la misma cantidad de filas y compará sus metadatos:

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

Salida esperada:

```
+---------------+------------+-------------+
|  table_name   | total_rows | logical_mib |
+---------------+------------+-------------+
| orders_naive  |     125226 |        8.94 |
| orders_part   |     125226 |        9.12 |
+---------------+------------+-------------+
```

### Bloque 2.2 — Medir la diferencia como la mide finanzas

4. Hacé un dry-run de la *misma pregunta de negocio* — "últimos 7 días de pedidos completados en Brasil" — contra ambas tablas:

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

Salida esperada (los números exactos varían con el contenido actual del dataset público):

```
orders_naive   6710886 bytes
orders_part    139264 bytes
```

5. Convertí esa proporción en una cifra anual para una carga de trabajo de BI realista — 40 analistas, 25 refrescos de dashboard cada uno por día hábil:

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

Salida esperada:

```
                 naive: $95,367.43/year
 partitioned+clustered: $1,979.05/year
```

**Verificación de comprensión — Bloque 2.1 / 2.2**

- **Q2.1** — Las dos tablas almacenan las mismas filas y cuestan esencialmente lo mismo de *almacenar*. ¿De dónde sale, exactamente, el ahorro de ~48×?
- **Q2.2** — Tanto el particionamiento como el clustering reducen los bytes escaneados. Enunciá la diferencia mecánica entre ambos, y dá la regla práctica sobre qué columna va en cada uno.
- **Q2.3** — Tu director dice "particionemos y clustericemos todas las tablas por todo". Dá dos razones por las que eso está mal.
- **Q2.4** — Un colega argumenta que con el modelo de precios de **BigQuery Editions (basado en capacidad/slots)** todo este ejercicio no sirve, porque no te facturan por byte. ¿La optimización ahora es inútil? Explicá qué te compra en cambio.

---

## Ejercicio 3 — Streaming analytics: de datos de hace horas a datos de hace segundos

La analítica por lotes responde *"¿qué pasó ayer?"*. La analítica en streaming responde *"¿qué está pasando ahora mismo, y hay que actuar?"*. Este bloque construye el camino de streaming de grado productivo más corto posible: **Pub/Sub → BigQuery**, sin código y sin pipeline que operar.

### Bloque 3.1 — Un topic de ingesta validado por esquema

1. Definí el contrato de eventos como un esquema Avro. En producción este es el artefacto más importante del pipeline: es lo que impide que una release de la app móvil corrompa el warehouse en silencio.

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

Salida esperada:

```
Created schema [clickstream-schema].
```

2. Creá el topic y **asociale el esquema**, eligiendo JSON en el cable:

```bash
gcloud pubsub topics create clickstream \
  --schema=clickstream-schema \
  --message-encoding=json
```

Salida esperada:

```
Created topic [projects/my-cdl-project/topics/clickstream].
```

3. Creá la tabla de destino. Los nombres de columna deben coincidir con los nombres de campo del esquema:

```bash
bq mk --table \
  --time_partitioning_type=DAY \
  "${PROJECT_ID}:${DS}.clickstream_raw" \
  event_id:STRING,event_ts:STRING,user_id:STRING,product_id:STRING,action:STRING,revenue:FLOAT
```

Salida esperada:

```
Table 'my-cdl-project:cdl_23_analytics.clickstream_raw' successfully created.
```

4. Otorgale al service agent de Pub/Sub permiso para escribir en BigQuery. Este es el paso que todo el mundo olvida, y si se omite falla *en silencio* hacia un vacío sin dead-letter:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor" \
  --condition=None
```

Salida esperada (truncada):

```
Updated IAM policy for project [my-cdl-project].
bindings:
- members:
  - serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com
  role: roles/bigquery.dataEditor
```

5. Creá una **suscripción de BigQuery** — Pub/Sub escribe directamente en la tabla, sin ningún job de Dataflow en el medio:

```bash
gcloud pubsub subscriptions create clickstream-to-bq \
  --topic=clickstream \
  --bigquery-table="${PROJECT_ID}:${DS}.clickstream_raw" \
  --use-topic-schema
```

Salida esperada:

```
Created subscription [projects/my-cdl-project/subscriptions/clickstream-to-bq].
```

### Bloque 3.2 — Emitir tráfico y medir la latencia extremo a extremo

6. Publicá una ráfaga de eventos de clickstream sintéticos:

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

Salida esperada:

```
published 60 events
```

7. Probá que el esquema se *aplica*, no es decorativo — publicá un mensaje que viola el contrato:

```bash
gcloud pubsub topics publish clickstream \
  --message '{"event_id":"bad-1","revenue":"not-a-number"}'
```

Salida esperada:

```
ERROR: (gcloud.pubsub.topics.publish) INVALID_ARGUMENT: Invalid data in message: Message failed schema validation.
```

8. Consultá el warehouse de inmediato — sin job de carga, sin ventana de ETL:

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

Salida esperada:

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

**Verificación de comprensión — Bloque 3.1 / 3.2**

- **Q3.1** — `worst_age_seconds` está dominado por lo que tardó tu bucle `for`, no por Pub/Sub. ¿Qué afirmación *arquitectónica* sustenta ese número para el negocio, y cuál sería el número equivalente en un warehouse de lotes nocturnos?
- **Q3.2** — El paso 7 fue rechazado en el *topic*. Nombrá el modo de falla de negocio que esta única funcionalidad previene, y decí quién lo habría descubierto en su lugar, y cuándo.
- **Q3.3** — ¿Qué desacopla exactamente Pub/Sub, y por qué importa eso durante un pico de tráfico de Black Friday cuando BigQuery, o un consumidor aguas abajo, se enlentece brevemente?
- **Q3.4** — Construiste esto sin una línea de código de pipeline. Nombrá dos requisitos concretos que te obligarían a poner **Dataflow** entre Pub/Sub y BigQuery en lugar de usar una suscripción de BigQuery.

---

## Ejercicio 4 — Ventanas, watermarks y datos tardíos: la parte difícil del streaming

La analítica en streaming no es "lotes, pero más rápido". Es una pregunta distinta: *¿sobre qué porción de un flujo no acotado estoy agregando, y cuándo decido que esa porción está terminada?* La sección 2.3 espera que puedas explicar el windowing a una audiencia de negocio.

### Bloque 4.1 — Ventanas tumbling (fijas) en SQL

1. Agregá el clickstream en vivo en cubetas fijas de un minuto:

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

Salida esperada:

```
+---------------------+--------+-----------+---------+
|    window_start     | events | checkouts | revenue |
+---------------------+--------+-----------+---------+
| 2026-09-06 14:22:00 |     38 |         7 |   812.9 |
| 2026-09-06 14:23:00 |     22 |         4 |   472.0 |
+---------------------+--------+-----------+---------+
```

### Bloque 4.2 — Ventanas de sesión: definidas por la actividad, no por el reloj

2. Agrupá los eventos de cada usuario en sesiones con un hueco de inactividad de 30 segundos — la forma de ventana que un reloj fijo no puede expresar:

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

Salida esperada:

```
+---------+------------+---------------------+------------+--------+-----------+
| user_id | session_no |    session_start    | duration_s | events | checkouts |
+---------+------------+---------------------+------------+--------+-----------+
| u-7     |          1 | 2026-09-06 14:22:03 |         41 |      8 |         2 |
| u-3     |          1 | 2026-09-06 14:22:05 |         38 |      6 |         1 |
| u-11    |          1 | 2026-09-06 14:22:11 |         33 |      5 |         0 |
+---------+------------+---------------------+------------+--------+-----------+
```

3. Estudiá la taxonomía de ventanas antes de responder — estos tres nombres aparecen textualmente en los escenarios del examen:

| Ventana | Definición | Pregunta de negocio que responde |
|---|---|---|
| **Tumbling (fija)** | Porciones no solapadas, de igual longitud | "Ingresos por minuto", "pedidos por hora" |
| **Hopping (deslizante)** | Longitud fija, emitida cada *N* < longitud — las ventanas se solapan | "Tasa de error móvil de 5 minutos, refrescada cada 30 s" |
| **Sesión** | Delimitada por un hueco de inactividad, por clave | "¿Cuánto dura una sesión de compra antes del checkout?" |
| **Global** | El flujo no acotado completo, liberado por un trigger | "Total acumulado de por vida" |

### Bloque 4.3 — `[$]` Opcional: un pipeline de streaming real con Dataflow

> **Advertencia de costo.** Un job de streaming de Dataflow mantiene al menos una VM de worker de forma continua. Esperá aproximadamente unos pocos centavos de dólar por hora por vCPU más cargos de procesamiento de datos de Streaming Engine — poco, pero **no se detiene solo**. Hacé el paso 7 el mismo día.

4. Creá una suscripción pull y un bucket de staging para el job:

```bash
gcloud pubsub subscriptions create clickstream-dataflow --topic=clickstream
gsutil mb -l "$REGION" "gs://${PROJECT_ID}-dfstage"
bq mk --table "${PROJECT_ID}:${DS}.clickstream_df" \
  event_id:STRING,event_ts:STRING,user_id:STRING,product_id:STRING,action:STRING,revenue:FLOAT
```

5. Lanzá la plantilla provista por Google — sin código Beam escrito por vos:

```bash
gcloud dataflow jobs run "cdl23-pubsub-to-bq" \
  --gcs-location gs://dataflow-templates/latest/PubSub_Subscription_to_BigQuery \
  --region "$REGION" \
  --staging-location "gs://${PROJECT_ID}-dfstage/tmp" \
  --parameters "inputSubscription=projects/${PROJECT_ID}/subscriptions/clickstream-dataflow,outputTableSpec=${PROJECT_ID}:${DS}.clickstream_df"
```

Salida esperada:

```
createTime: '2026-09-06T14:31:02.884512Z'
currentStateTime: '1970-01-01T00:00:00Z'
id: 2026-09-06_07_31_02-4471928365109842177
location: us-central1
name: cdl23-pubsub-to-bq
projectId: my-cdl-project
type: JOB_TYPE_STREAMING
```

6. Miralo levantarse, después publicá algunos eventos más (volvé a correr el paso 6 del Bloque 3.2) y confirmá que aterrizan en `clickstream_df`:

```bash
gcloud dataflow jobs list --region "$REGION" --status active \
  --format='table(id, name, state, type)'
```

Salida esperada:

```
JOB_ID                                    NAME                STATE    TYPE
2026-09-06_07_31_02-4471928365109842177   cdl23-pubsub-to-bq  Running  Streaming
```

7. **Drenar y detener el job — no te saltees esto:**

```bash
JOB_ID="$(gcloud dataflow jobs list --region "$REGION" --status active \
  --filter='name=cdl23-pubsub-to-bq' --format='value(id)')"
gcloud dataflow jobs drain "$JOB_ID" --region "$REGION"
```

Salida esperada:

```
Started draining job [2026-09-06_07_31_02-4471928365109842177]
```

**Verificación de comprensión — Bloque 4.1 / 4.2 / 4.3**

- **Q4.1** — Un equipo de pagos quiere una alerta cuando la tasa de rechazos supere el 3% "en los últimos 5 minutos, verificado de forma continua". ¿Qué tipo de ventana, con qué parámetros?
- **Q4.2** — ¿Por qué una ventana de *sesión* no se puede calcular simplemente esperando a que el reloj avance? ¿Qué necesita el sistema en cambio?
- **Q4.3** — Una app móvil almacena eventos en buffer mientras está sin conexión y los sube 20 minutos después. Definí **tiempo de evento** vs. **tiempo de procesamiento**, y después explicá qué es un **watermark** y qué pasa con esos eventos por defecto.
- **Q4.4** — En el Bloque 4.3 ejecutaste un pipeline de streaming sin escribir una línea de Java ni de Python. Nombrá las dos cosas distintas que una *plantilla* de Dataflow elimina del plan de proyecto.
- **Q4.5** — ¿Por qué `drain` y no `cancel`? ¿Cuál usarías si el pipeline estuviera escribiendo registros corruptos?

---

## Ejercicio 5 — La capa de BI: quién tiene realmente permitido hacer una pregunta

Un warehouse que nadie puede consultar es un centro de costos. Este bloque construye la capa de servicio y fuerza la decisión Looker vs. Looker Studio vs. Connected Sheets que evalúa la sección 2.3.

### Bloque 5.1 — Pre-agregar con una vista materializada

1. Creá una vista materializada sobre la tabla de hechos. BigQuery la mantiene actualizada incrementalmente y — algo crítico — **reescribe automáticamente las consultas que califican contra la tabla base para que la usen**:

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

2. Hacé un dry-run de una consulta con forma de dashboard **contra la tabla base** y confirmá que el optimizador eligió la vista:

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

Salida esperada — muchísimos menos bytes que las particiones de 30 días de la tabla base:

```
Query successfully validated. Assuming the tables are not modified, running this query will process 31457 bytes of data.
```

### Bloque 5.2 — `[$]` Opcional: BI Engine, la capa de aceleración en memoria

> **Advertencia de costo.** Una reserva de BI Engine se factura por GiB por hora mientras exista. Borrala al final del bloque.

3. En la consola de Cloud, andá a **BigQuery → Administration → BI Engine → Create reservation**, elegí la location `US`, tamaño **1 GiB**, y confirmá.

4. Verificalo desde SQL:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT project_id, size_gb, preferred_tables
FROM \`region-us.INFORMATION_SCHEMA.BI_CAPACITIES\`"
```

Salida esperada:

```
+----------------+---------+------------------+
|   project_id   | size_gb | preferred_tables |
+----------------+---------+------------------+
| my-cdl-project |       1 | NULL             |
+----------------+---------+------------------+
```

5. Ejecutá la misma consulta de dashboard dos veces y compará el tiempo transcurrido; después borrá la reserva en la consola (poné el tamaño en 0 / **Delete**).

### Bloque 5.3 — Poner un gráfico frente a una persona

6. Abrí **https://lookerstudio.google.com** → **Create → Data source → BigQuery** → tu proyecto → `cdl_23_analytics` → `mv_daily_sales` → **Connect**.

7. Agregá un gráfico de **serie temporal**: dimensión `order_day`, métrica `orders`, dimensión de desglose `country`. Agregá un control de rango de fechas.

8. Hacé clic en **Share** y observá el modelo de compartición — es estilo Google Drive, por persona o por enlace.

9. Ahora inspeccioná la alternativa en la consola: BigQuery → tu tabla → **Export → Explore with Sheets** (Connected Sheets). Notá que la planilla no descarga las filas; emite consultas a BigQuery detrás de una interfaz de tabla dinámica familiar.

**Verificación de comprensión — Bloque 5.1 / 5.2 / 5.3**

- **Q5.1** — Una vista materializada y una consulta programada que escribe una tabla de resumen ambas pre-agregan. Dá las dos propiedades que tiene la vista materializada y que la tabla programada no tiene.
- **Q5.2** — El particionamiento, las vistas materializadas y BI Engine aceleran los dashboards. Ordenalos según *cuándo* actúan en el ciclo de vida de la consulta, y decí a cuál recurrirías **último**.
- **Q5.3** — Los 30 analistas de finanzas viven en planillas y se niegan a usar herramientas nuevas, pero no paran de exportar CSVs de 5 millones de filas que quedan desactualizados y se filtran. ¿Qué proponés, y qué dos problemas resuelve a la vez?
- **Q5.4** — Dos escenarios de BI. (a) Una startup de 12 personas quiere dashboards gratuitos y autoservicio esta semana. (b) Un retailer de 4.000 empleados necesita una única definición gobernada de "ingreso neto" aplicada de forma idéntica en finanzas, operaciones y un portal de partners embebido, con lógica de métricas versionada. ¿Cuál de **Looker** y **Looker Studio** para cada uno, y cuál es la única palabra que los separa?

---

## Ejercicio 6 — Smart analytics: predicción donde ya viven los datos

"Smart analytics" es el término de Google para la analítica que incluye machine learning sin una plataforma de ML separada, sin un equipo de data science y sin un paso de exportación de datos. Demostralo en SQL.

### Bloque 6.1 — Entrenar un pronóstico de demanda sin salir de BigQuery

1. Entrená un modelo de series temporales. Notá que no hay Python, ni notebook, ni feature store, ni movimiento de datos:

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

Salida esperada (el entrenamiento tarda 1–3 minutos):

```
Waiting on bqjob_r7bd41c02fa9e5d31_0000019a3f5c11ab_1 ... (94s) Current status: DONE
```

2. Inspeccioná qué eligió `auto_arima` por vos:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT non_seasonal_p, non_seasonal_d, non_seasonal_q, has_drift,
       ROUND(log_likelihood,1) AS log_lik, ROUND(aic,1) AS aic, seasonal_periods
FROM ML.ARIMA_EVALUATE(MODEL \`${PROJECT_ID}.${DS}.revenue_forecast\`)
LIMIT 3"
```

Salida esperada:

```
+----------------+----------------+----------------+-----------+----------+--------+------------------+
| non_seasonal_p | non_seasonal_d | non_seasonal_q | has_drift | log_lik  |  aic   | seasonal_periods |
+----------------+----------------+----------------+-----------+----------+--------+------------------+
|              1 |              1 |              2 |     false | -5218.4  | 10444.8| ["WEEKLY"]       |
|              2 |              1 |              1 |     false | -5219.9  | 10447.7| ["WEEKLY"]       |
+----------------+----------------+----------------+-----------+----------+--------+------------------+
```

3. Producí un pronóstico a 30 días con intervalo de confianza — la forma que un planificador puede usar de verdad:

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

Salida esperada:

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

4. Apuntá Looker Studio (Bloque 5.3) a una vista sobre `ML.FORECAST` para ver la predicción aterrizar en el mismo dashboard que el histórico — para el usuario de negocio no hay frontera visible entre "reporting" e "IA".

**Verificación de comprensión — Bloque 6.1**

- **Q6.1** — Describí el flujo de trabajo clásico previo a BigQuery ML para este mismo pronóstico. Nombrá los tres pasos que desaparecieron y los dos *riesgos* que desaparecieron con ellos.
- **Q6.2** — La salida tiene columnas `worst_case` y `best_case`. ¿Por qué entregar solo un pronóstico puntual suele ser peor que no entregar ningún pronóstico, para un comprador de inventario?
- **Q6.3** — ¿Cuándo BigQuery ML deja de ser la herramienta correcta, y a qué te movés?
- **Q6.4** — Dá un caso de uso de negocio concreto para cada uno: (a) `ARIMA_PLUS`, (b) `LOGISTIC_REG`, (c) `KMEANS`, (d) `MATRIX_FACTORIZATION`.

---

## Ejercicio 7 — Gobernanza: hacer los datos compartibles *y* seguros

El valor de la analítica escala con la cantidad de personas a las que se les permite hacer preguntas — que es precisamente la razón por la cual las plataformas sin gobernanza terminan bloqueadas y mueren. Este bloque muestra los controles que te permiten abrir el acceso en lugar de cerrarlo.

### Bloque 7.1 — Seguridad a nivel de fila

1. Confirmá tu vista sin restricciones de los datos:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT country, COUNT(*) AS orders
FROM \`${PROJECT_ID}.${DS}.orders_part\`
GROUP BY country ORDER BY orders DESC LIMIT 5"
```

Salida esperada:

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

2. Aplicá una política de acceso a filas acotada a tu propia cuenta:

```bash
MY_EMAIL="$(gcloud config get-value account)"
bq query --use_legacy_sql=false "
CREATE OR REPLACE ROW ACCESS POLICY brasil_only
ON \`${PROJECT_ID}.${DS}.orders_part\`
GRANT TO ('user:${MY_EMAIL}')
FILTER USING (country = 'Brasil')"
```

3. Volvé a ejecutar la consulta del paso 1, sin cambiarla:

```bash
bq query --use_legacy_sql=false --format=pretty "
SELECT country, COUNT(*) AS orders
FROM \`${PROJECT_ID}.${DS}.orders_part\`
GROUP BY country ORDER BY orders DESC LIMIT 5"
```

Salida esperada:

```
+---------+--------+
| country | orders |
+---------+--------+
| Brasil  |  15342 |
+---------+--------+
```

4. Quitá la política:

```bash
bq query --use_legacy_sql=false "
DROP ROW ACCESS POLICY brasil_only ON \`${PROJECT_ID}.${DS}.orders_part\`"
```

### Bloque 7.2 — Compartir un agregado sin compartir las filas

5. Creá un segundo dataset que va a funcionar como la superficie "compartida con proveedores", y una **vista autorizada** sobre la tabla de hechos:

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

6. Autorizá la vista contra el dataset de origen en la consola: **BigQuery → `cdl_23_analytics` → Sharing → Authorize views → Add** `cdl_23_analytics_shared.v_supplier_demand`. Un proveedor al que se le otorgue `roles/bigquery.dataViewer` **únicamente** sobre `cdl_23_analytics_shared` ya puede leer el agregado sin ningún acceso a `orders_part`.

7. Mirá el grafo de linaje que se registró para las tablas que creaste: **BigQuery → `orders_part` → pestaña Lineage**.

**Verificación de comprensión — Bloque 7.1 / 7.2**

- **Q7.1** — En el paso 3 el *texto de la consulta no cambió* y a la analista *no se le avisó nada*. ¿Por qué la aplicación en la capa de datos, en vez de en la herramienta de BI, es el único diseño defendible en cuanto tenés más de una herramienta de BI?
- **Q7.2** — Distinguí seguridad a nivel de fila, seguridad a nivel de columna (policy tags) y enmascaramiento dinámico de datos, con un caso de uso para cada uno.
- **Q7.3** — Un retailer quiere darles a 400 proveedores un feed diario de demanda. Compará (a) mandar CSVs por email, (b) vistas autorizadas, (c) un listing de **Analytics Hub**, en costo, frescura y copias de datos.
- **Q7.4** — ¿Qué agrega **Dataplex** encima de los permisos de BigQuery, y por qué una organización con 200 datasets lo necesita mientras que una con 5 no?

---

## Ejercicio 8 — La habilidad del examen: mapear un caso de uso de negocio al producto correcto

Acá no hay CLI. Este es el ejercicio que decide los 6.0 puntos del examen. Para cada escenario, escribí **un producto principal** y una frase de justificación. Después verificate en las respuestas.

### Bloque 8.1 — El ejercicio de decisión

1. Copiá esta tabla y completá las dos últimas columnas antes de leer las respuestas.

| # | Escenario de negocio | Producto | Por qué |
|---|---|---|---|
| 1 | Un banco debe marcar transacciones con tarjeta probablemente fraudulentas dentro de los 2 segundos de la autorización, enriqueciendo cada evento con un perfil de cliente de 90 días. | | |
| 2 | Una empresa de medios tiene un parque Hadoop/Spark on-premises de 400 nodos con años de jobs Spark a medida, y quiere salir del datacenter en 6 meses con una reescritura mínima de código. | | |
| 3 | Un retailer necesita que sus bases de datos OLTP Oracle y MySQL se repliquen continuamente al warehouse con impacto casi nulo en los sistemas transaccionales. | | |
| 4 | Analistas de negocio sin habilidades de programación deben construir y programar sus propios pipelines de ETL a través de una interfaz de arrastrar y soltar. | | |
| 5 | Un equipo de ingeniería de datos necesita orquestar un DAG nocturno de 40 pasos con dependencias entre BigQuery, Cloud Storage y una API externa, con reintentos y SLAs. | | |
| 6 | Una plataforma de ad-tech debe servir una búsqueda de perfil de usuario en menos de 10 ms a 900.000 lecturas por segundo. | | |
| 7 | El CFO quiere una única definición gobernada de "margen neto", idéntica en cada dashboard, planilla y en el portal de partners de cara al cliente. | | |
| 8 | Un product manager quiere un gráfico gratuito, rápido y compartible de las altas del último trimestre a partir de una tabla existente en BigQuery. | | |
| 9 | Un consorcio farmacéutico quiere publicar un dataset curado a 60 organizaciones socias sin que ninguna de ellas lo copie, y sin cargos de egreso para el publicador. | | |
| 10 | Una empresa tiene datos en BigQuery, pero también en Amazon S3, y quiere una única consulta SQL sobre ambos sin construir un pipeline de copia. | | |
| 11 | Una firma de logística quiere predecir entregas tardías; las características ya están en BigQuery y el equipo sabe SQL, no Python. | | |
| 12 | Una telco debe calcular un conteo móvil de 5 minutos de llamadas caídas por antena y disparar una alerta, a partir de un flujo de 2 millones de eventos por segundo. | | |

**Verificación de comprensión — Bloque 8.1**

- **Q8.1** — Los escenarios 2 y 4 son ambos "transformar datos". Enunciá el criterio más importante que separa Dataproc de Cloud Data Fusion acá.
- **Q8.2** — Los escenarios 5 y 12 involucran ambos "pipelines". ¿Por qué Cloud Composer es la respuesta equivocada para el 12 y Dataflow la respuesta equivocada para el 5?
- **Q8.3** — Los escenarios 7 y 8 son ambos "BI". Un interlocutor dice "las dos son dashboards, elegí la gratis". Dá la refutación en una frase.

---

## Ejercicio 9 — Convertirlo en un caso de negocio

### Bloque 9.1 — Los modelos de precios que tenés que poder comparar

1. Estudiá los dos modelos de cómputo de BigQuery. **Verificá los precios de lista actuales en la página de precios antes de citárselos a nadie** — estos son ilustrativos:

| Modelo | Se factura por | Encaje típico |
|---|---|---|
| **On-demand** | Bytes procesados (~$6,25 / TiB, US; 1 TiB/mes gratis) | Cargas de trabajo con picos, exploratorias, impredecibles; volumen bajo |
| **Editions (Standard / Enterprise / Enterprise Plus)** | Slot-horas, con autoescalado y compromisos opcionales | Cargas estables, de alto volumen, predecibles; cuando se requiere un techo de costo |

2. Calculá el punto de cruce para una carga de trabajo de 900 TiB escaneados por mes:

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

Salida esperada:

```
  500 slots baseline: $   21,600/mo   vs on-demand $5,625/mo
 1000 slots baseline: $   43,200/mo   vs on-demand $5,625/mo
 1500 slots baseline: $   64,800/mo   vs on-demand $5,625/mo
```

3. Ahora modelá la dirección *contraria* — una carga de trabajo de 40.000 TiB/mes contra una línea base autoescalada de 2.000 slots:

```bash
python3 -c "print(f'on-demand: \${40000*6.25:,.0f}/mo   editions@2000 slots: \${2000*0.06*24*30:,.0f}/mo')"
```

Salida esperada:

```
on-demand: $250,000/mo   editions@2000 slots: $86,400/mo
```

4. Verificá cuánto costaron realmente tus propios ejercicios hasta ahora:

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

Salida esperada:

```
+------------+------+------------+------------+
|    day     | jobs | gib_billed | approx_usd |
+------------+------+------------+------------+
| 2026-09-06 |   27 |      1.842 |     0.0112 |
+------------+------+------------+------------+
```

**Verificación de comprensión — Bloque 9.1**

- **Q9.1** — A 900 TiB/mes gana on-demand, y a 40.000 TiB/mes ganan las editions. Enunciá la regla general en una frase, y nombrá la razón *no financiera* por la que una empresa podría elegir editions incluso cuando on-demand es más barato.
- **Q9.2** — BigQuery factura almacenamiento y cómputo por separado. Nombrá dos decisiones de negocio que eso habilita y que un appliance acoplado (donde almacenamiento y cómputo son una sola caja) prohíbe.
- **Q9.3** — Escribí el caso de negocio de un párrafo para el Ejercicio 3 (streaming de clickstream hacia BigQuery) tal como se lo presentarías al COO de un retailer. Tiene que contener una decisión que se vuelve posible, no una tecnología que se vuelve disponible.

---

## Limpieza

Ejecutá esto para evitar cargos continuos. Es destructivo — leelo primero.

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

Confirmá que no quedó nada corriendo:

```bash
gcloud dataflow jobs list --region "$REGION" --status active
bq ls --datasets "$PROJECT_ID"
```

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Bloque 0.1

**A0.1** — No podés cambiar la location de un dataset; tenés que crear un dataset nuevo en `europe-west1` y copiar los datos (copia de dataset entre regiones de BigQuery, o exportar/importar). La implicancia: **la location es la decisión primera y menos reversible de un proyecto de analítica**, y la determinan la regulación y el lugar donde viven los sistemas que producen los datos, no la conveniencia. Notá además que una consulta no puede hacer joins entre tablas de distintas locations — toda la arquitectura aguas abajo hereda esta elección.

**A0.2** — Un dry run te da el precio de una pregunta *antes* de pagarla. Eso convierte un costo ilimitado e impredecible en uno gobernado: los equipos pueden fijar límites de bytes por consulta (`maximum_bytes_billed`), la CI puede rechazar un cambio de dashboard que multiplicaría la factura por 100, y un responsable de finanzas puede proyectar el gasto. On-premises, la pregunta equivalente ("¿cuánto va a costar este reporte?") no tiene respuesta alguna, porque el costo quedó hundido en hardware años atrás.

**A0.3** — (a) es una decisión de **servicio gestionado**: estás eligiendo dejar de ser dueño del aprovisionamiento, el parcheo, el escalado y la planificación de capacidad del clúster. (b) es una decisión de **arquitectura**: es trabajo de diseño que seguís teniendo a cargo, dentro del servicio gestionado. El examen evalúa una y otra vez que "serverless" elimina las *operaciones*, no el *diseño*.

### Ejercicio 1

**A1.1** — (i) **Gasto de capital y planificación de capacidad** — el clúster dimensionado para el pico que está ocioso la mayor parte del año. (ii) **Mano de obra de operaciones** — parcheo, actualizaciones, fallas de nodos, expansión de almacenamiento, backup y la guardia 24/7 para el clúster en sí. Una tercera, si la querés: el **proyecto de carga de datos** — consultaste los datos sin haberlos ingerido nunca.

**A1.2** — "La tabla está archivada por fecha, como un estante de carpetas fechadas. La primera consulta bajó todas las carpetas del estante para leerlas todas; la segunda pidió un día específico, así que se abrió una sola carpeta. Pagás por lo que se lee, no por lo que se almacena." (Técnicamente: el pruning de particiones elimina todas las particiones que no coinciden con el predicado sobre `refresh_date` antes de leer dato alguno.)

**A1.3** — Lo que desaparece es el **proyecto de ingesta**: negociar un feed, construir un pipeline de ETL, programarlo, monitorearlo, guardar una segunda copia y reconciliarla. La capacidad es la de los **datasets públicos de BigQuery** y, en su forma comercial/de partners, **Analytics Hub** — los datos se *comparten en el lugar* y los consulta el consumidor, que paga su propio cómputo. No se hace ninguna copia, así que no hay copia que quede desactualizada.

### Ejercicio 2

**A2.1** — Enteramente de los **bytes leídos**. Particionar por `order_day` permite que BigQuery se saltee toda partición fuera del rango de 7 días; clusterizar por `(country, status)` ordena los datos dentro de cada partición en bloques, así que la capa de almacenamiento se saltea los bloques cuyo rango mín/máx no puede contener `'Brasil'`/`'Complete'`. Mismas filas, misma factura de almacenamiento, ~48× menos escaneo. Notá que la tabla ingenua *además* es más lenta, porque leer menos datos es más rápido.

**A2.2** — El **particionamiento** divide físicamente la tabla en segmentos separados según una columna (una fecha/timestamp, un rango de enteros o el tiempo de ingesta), y el pruning es exacto — la partición se lee o no se lee. El **clustering** ordena las filas dentro de cada partición por hasta cuatro columnas y hace pruning a granularidad de bloque, así que el beneficio es estadístico y es más fuerte en la columna de clustering *inicial*. Regla práctica: **particioná por la columna del filtro temporal presente en toda cláusula `WHERE`; clusterizá por las columnas de alta cardinalidad usadas para filtrar y hacer joins**, ordenadas de la más a la menos filtrada.

**A2.3** — (i) Una tabla puede tener **una sola columna de particionamiento**, y BigQuery limita las particiones por tabla (4.000 por defecto), así que particionar por una columna de alta cardinalidad es imposible o crea particiones diminutas e ineficientes cuyo overhead de metadatos puede volver las consultas *más lentas*. (ii) El clustering solo ayuda a consultas que filtran o agregan por las columnas de clustering iniciales — clusterizar por columnas que nadie filtra no aporta nada y agrega costo del lado de la escritura. Las tablas chicas (menos de ~1 GB) en general no deberían particionarse en absoluto.

**A2.4** — Vale *más*, no menos. Con precios por capacidad tenés un pool fijo de slots; una consulta que escanea 48× más datos ocupa slots 48× más tiempo, así que (i) demora todas las demás consultas encoladas detrás, (ii) te obliga a comprar una línea base más grande o dispara autoescalado que pagás, y (iii) degrada la latencia de los dashboards justo en las horas pico. Con on-demand, el desperdicio aparece como factura; con editions, aparece como **contención y latencia** — que el negocio siente más directamente.

### Ejercicio 3

**A3.1** — La afirmación es: **el warehouse es consultable a segundos de que el evento ocurrió, sin ninguna ventana de lotes.** En un warehouse de lotes nocturnos la cifra equivalente es la edad *promedio* de los datos, alrededor de 12 horas y hasta 24 — lo que significa que ninguna decisión operativa (precios, reasignación de inventario, retención por fraude, dotación de personal en tienda) puede tomarse sobre esos datos. El streaming cambia la *clase de pregunta* que el warehouse puede responder, de retrospectiva a operativa.

**A3.2** — Previene una **ruptura silenciosa de esquema**: una release móvil que empieza a mandar `revenue` como string, o que elimina un campo, de otro modo fluiría hacia el warehouse y corrompería todos los reportes y modelos aguas abajo. Sin aplicación de esquema, quienes lo descubren son los **usuarios de negocio**, semanas más tarde, cuando un número se ve raro — y para entonces los datos malos ya están dentro de modelos, dashboards y posiblemente estados financieros. Aplicarlo en el topic lo convierte en un fallo de build del *publicador*, de inmediato.

**A3.3** — Pub/Sub desacopla **productores de consumidores** en el tiempo, en throughput y en cantidad. Los productores publican y reciben un ack sin saber quién lee, cuántos lectores hay ni si están sanos; Pub/Sub almacena en buffer (con una ventana de retención configurable) y entrega cuando el consumidor puede seguir el ritmo. En Black Friday, un consumidor lento causa un **backlog creciente**, no eventos perdidos ni una página de checkout trabada — el sistema de cara al cliente nunca queda rehén del sistema de analítica. Agregar un segundo consumidor (detección de fraude, un dashboard en tiempo real) más adelante no requiere ningún cambio en el publicador.

**A3.4** — Dos cualesquiera de: (i) **transformación o enriquecimiento en vuelo** — join contra un dataset de referencia, conversión de moneda, enmascaramiento de PII antes de aterrizar; (ii) **agregación por ventanas** — querés totales por minuto en BigQuery, no eventos crudos; (iii) **múltiples destinos o ruteo condicional** — el mismo flujo hacia BigQuery, Bigtable y Cloud Storage, o registros malos a una tabla de dead-letter; (iv) **deduplicación compleja o semántica exactly-once** más allá de lo que da la suscripción; (v) **inferencia de ML online** sobre cada evento.

### Ejercicio 4

**A4.1** — Una **ventana hopping (deslizante)** de 5 minutos de longitud con un período de 30 segundos (o menor). La *longitud* de la ventana es la definición de negocio de "reciente"; el *período* es cada cuánto reevaluás y podés alertar. Una ventana tumbling de 5 minutos sería incorrecta porque un pico que cruza un límite podría diluirse entre dos ventanas y no llegar nunca a disparar el umbral, y te enterarías hasta 5 minutos tarde.

**A4.2** — Porque el límite lo define el **dato**, no el reloj: una sesión termina cuando una clave particular estuvo en silencio durante la duración del hueco, así que la longitud y el momento de fin de la ventana difieren por usuario y son imposibles de saber de antemano. El sistema debe mantener **estado por clave** más un temporizador, y sostener ese estado hasta que transcurra el hueco. Esta es exactamente la razón por la que las ventanas de sesión son una funcionalidad de un motor de streaming gestionado (Dataflow/Beam) y no algo que le pegues a un cron.

**A4.3** — El **tiempo de evento** es cuándo el evento ocurrió realmente (estampado por el productor); el **tiempo de procesamiento** es cuándo el pipeline lo vio. Divergen con la latencia de red, el buffering sin conexión, los reintentos y los backlogs. Un **watermark** es la estimación corriente del pipeline de "el tiempo de evento hasta el cual creo haber visto todo" — es cómo el sistema decide que una ventana puede cerrarse y emitirse. Los datos que llegan después de que el watermark pasó su ventana son **datos tardíos**, y por defecto Dataflow los **descarta**. Eso se cambia con `withAllowedLateness` más un trigger y un modo de acumulación, de modo que los registros tardíos o bien actualizan el resultado emitido previamente o aterrizan en un flujo de corrección separado. La consecuencia de negocio: un buffer sin conexión de 20 minutos implica que tenés que aceptar una tolerancia de tardanza de 20 minutos (y por lo tanto correcciones tardías sobre números ya publicados) o aceptar que esos eventos nunca aparezcan.

**A4.4** — (i) El **proyecto de desarrollo** — escribir, testear y mantener código Apache Beam, y las habilidades especializadas para hacerlo. (ii) El **proyecto de operaciones** — Dataflow autoescala los workers, maneja las fallas de worker y el rebalanceo, y administra el estado y el checkpointing; nadie dimensiona ni cuida un clúster de streaming. Lo que sigue siendo tuyo es la *semántica*: qué ventana, qué tolerancia a tardanza, qué esquema.

**A4.5** — **Drain** deja de aceptar entrada nueva pero termina de procesar todo lo que está en vuelo, cerrando y emitiendo las ventanas abiertas, de modo que no se pierden datos en tránsito — es la elección correcta para un job sano. **Cancel** detiene de inmediato y descarta el estado en vuelo en buffer. Usás cancel cuando el pipeline está produciendo salida corrupta, porque drenar volcaría esa corrupción al destino.

### Ejercicio 5

**A5.1** — (i) **Refresco incremental automático**: BigQuery actualiza solo las particiones cambiadas de una vista materializada a medida que cambia la tabla base, en vez de recalcular todo según un cronograma; los datos están frescos entre refrescos porque BigQuery lee el delta desde la tabla base. (ii) **Reescritura automática de consultas**: las consultas escritas contra la *tabla base* son redirigidas silenciosamente a la vista por el optimizador, así que ningún dashboard, reporte o usuario necesita saber que la vista existe. Una tabla de resumen programada no te da ninguna de las dos — cada consumidor debe apuntarse a ella manualmente, y queda desactualizada entre ejecuciones.

**A5.2** — Orden de actuación: **particionamiento/clustering** actúa en la capa de almacenamiento (qué bytes se leen), las **vistas materializadas** actúan en la capa de planificación de consultas (qué cómputo se saltea), **BI Engine** actúa en la capa de ejecución (una caché en memoria de los datos que sirven la consulta). Recurrí a **BI Engine último** — es una reserva paga y siempre encendida que vuelve rápida una consulta ineficiente sin volverla *barata*, y tapará con gusto un problema de esquema que el particionamiento habría arreglado gratis.

**A5.3** — **Connected Sheets.** Resuelve (i) el problema de **desactualización/consistencia** — la planilla consulta BigQuery en vivo en lugar de guardar un extracto congelado, así que todos ven una única versión de la verdad; y (ii) el problema de **gobernanza/fuga** — las filas nunca salen de BigQuery ni aterrizan en un adjunto de email, así que IAM, la seguridad a nivel de fila y el logging de auditoría siguen aplicando. También elimina el límite de filas: los analistas hacen tablas dinámicas sobre miles de millones de filas a través de una interfaz de planilla. El costo de gestión del cambio es casi nulo, que es la verdadera razón por la que funciona.

**A5.4** — (a) **Looker Studio** — gratuito, autoservicio, rápido de poner en marcha, compartición como un Google Doc. (b) **Looker** — capa de modelado semántico gobernada (LookML), versionada en Git, con analítica embebida para el portal de partners. La palabra que los separa es **gobernanza** (equivalentemente: el *modelo semántico*). Looker Studio deja que cada autor defina "ingreso neto" a su manera; Looker lo define una vez, centralmente, y cada consumidor lo hereda.

### Ejercicio 6

**A6.1** — Flujo clásico: exportar/extraer datos del warehouse → moverlos a un entorno de data science → construir features → entrenar en Python/R → serializar el modelo → construir y operar un servicio de servido/inferencia → programar un job que escriba las predicciones de vuelta. Los tres pasos que desaparecieron son el **movimiento/exportación de datos**, **un entorno de entrenamiento separado** y **un camino de servido de predicciones separado** — el modelo es un objeto dentro del dataset y `ML.FORECAST` es simplemente SQL. Los dos riesgos que desaparecieron son (i) el **riesgo de gobernanza de datos** — una copia de datos de producción en una laptop o en un segundo sistema, fuera de tu frontera de IAM y auditoría; y (ii) el **desvío entre entrenamiento y servido** (training/serving skew) — features calculadas de una forma en el notebook y de otra en producción, que es la causa más común de modelos que se degradan en silencio.

**A6.2** — Porque un pronóstico puntual transmite una falsa precisión y esconde el riesgo que el comprador está gestionando realmente. La decisión de un comprador de inventario es asimétrica: quedarse sin stock cuesta una venta perdida y un cliente perdido, mientras que sobre-stockearse cuesta costo de mantenimiento y liquidación. Necesitan la **distribución** — "con 80% de confianza los ingresos caen entre 35k y 47k" — para elegir un nivel de servicio. Un número solo invita al comprador a planificar para un escenario con, en el mejor caso, un 50% de probabilidad de ser superado, sin ninguna señal sobre la volatilidad. Publicar un intervalo además vuelve honesto al modelo: cuando el intervalo es enorme, todos ven que el pronóstico todavía no es confiable.

**A6.3** — BigQuery ML deja de ser lo correcto cuando necesitás (i) **datos no estructurados** — imágenes, audio, video, texto libre más allá de embeddings simples; (ii) **arquitecturas o frameworks a medida** — deep learning específico, funciones de pérdida personalizadas, entrenamiento distribuido en GPU/TPU; (iii) **servido online de baja latencia** — inferencia por request en milisegundos desde una aplicación; o (iv) un **ciclo de vida completo de MLOps** — seguimiento de experimentos, registro de modelos, evaluación continua y pipelines de reentrenamiento. Te movés a **Vertex AI**. Notá que se componen: los modelos de BigQuery ML pueden registrarse en Vertex AI y servirse desde ahí, y Vertex AI puede leer datos de entrenamiento directamente de BigQuery.

**A6.4** — (a) **ARIMA_PLUS** — pronosticar demanda diaria por SKU, volumen de call center o gasto en la nube, con efectos de feriados y estacionalidad. (b) **LOGISTIC_REG** — predecir qué suscriptores se van a dar de baja el mes que viene, o si una transacción es fraudulenta (clasificación binaria con una probabilidad sobre la que podés fijar un umbral según el costo de negocio). (c) **KMEANS** — segmentación no supervisada de clientes para marketing, descubriendo agrupamientos naturales que nadie etiquetó de antemano. (d) **MATRIX_FACTORIZATION** — un motor de recomendación de productos a partir del historial de compras o vistas ("clientes como vos también compraron").

### Ejercicio 7

**A7.1** — Porque la herramienta de BI no es la única puerta. La misma tabla es alcanzable desde la consola de BigQuery, la CLI `bq`, Connected Sheets, un notebook de Python, una segunda herramienta de BI, una exportación programada y la API. Filtrar en la herramienta de BI asegura **una** de esas puertas y deja el resto abiertas, y cada herramienta nueva reabre la cuestión. Aplicar en la capa de datos significa que la política la evalúa el propio motor, aplica de forma idéntica a todo camino de acceso, no puede eludirse reescribiendo la consulta, y se audita en un solo lugar. También significa que la política sobrevive a un cambio de proveedor de BI.

**A7.2** — La **seguridad a nivel de fila** (row access policies) controla *qué filas* ve un principal, en base a un predicado de filtro — p. ej., un gerente regional de ventas ve solo los pedidos de su región. La **seguridad a nivel de columna** (policy tags de Dataplex/Data Catalog más IAM) controla *qué columnas* puede leer un principal — p. ej., solo el equipo de fraude puede seleccionar `card_number`; el resto recibe un error de acceso denegado sobre esa columna. El **enmascaramiento dinámico de datos** aplica un policy tag pero devuelve un valor *transformado* en lugar de un error — p. ej., los analistas ven `****1234` o un hash, así que la consulta igual corre y los joins siguen funcionando, sin exponer el valor crudo. Usá enmascaramiento cuando la columna debe seguir siendo utilizable; usá denegación a nivel de columna cuando no debe tocarse.

**A7.3** — (a) **CSV por email**: el costo es trabajo humano y escala linealmente con 400 proveedores; la frescura es cuando alguien se acordó de mandarlo; creás 400 copias incontroladas sin revocación, sin auditoría y con riesgo real de fuga. (b) **Vistas autorizadas**: la frescura es en vivo, una sola copia, revocable por proveedor, auditada — pero tenés que administrar 400 grants de IAM y cada proveedor debe ser alcanzable en tu modelo de identidad de Google Cloud, y *vos* pagás sus consultas salvo que consulten desde su propio proyecto. (c) **Analytics Hub**: la frescura es en vivo, sigue habiendo exactamente una copia de los datos (un listing es un puntero, no una réplica), los suscriptores lo agregan a su propio proyecto como dataset vinculado y **pagan su propio cómputo**, el onboarding es autoservicio en vez de un ticket por proveedor, y conservás una lista de suscriptores que podés revocar. Para 400 socios, (c) es la respuesta; (b) es el mecanismo con el que construirías (c) a mano.

**A7.4** — Dataplex agrega la capa *por encima* de los datasets individuales: un **catálogo y búsqueda** unificados sobre BigQuery y Cloud Storage, **metadatos de negocio y policy tags** que viajan con los datos, reglas de **calidad y perfilado de datos**, **linaje**, y **lakes/zones** que te permiten aplicar gobernanza de forma consistente entre muchos proyectos. Una organización con 5 datasets puede tener el mapa en la cabeza de una persona y otorgar IAM directamente. Una con 200 datasets no puede responder "¿de dónde sale este número, quién es el dueño, es confiable, y contiene PII?" sin un catálogo — y versiones irresolubles de esas preguntas son exactamente lo que hace que el liderazgo deje de confiar en la plataforma.

### Ejercicio 8

**A8.1 — la tabla del ejercicio**

| # | Producto | Por qué |
|---|---|---|
| 1 | **Dataflow** (+ ingesta con **Pub/Sub**, **Bigtable** para la búsqueda de perfil) | Procesamiento de flujos con estado y sub-segundo, con enriquecimiento contra un almacén de baja latencia; un warehouse no puede responder dentro de la ventana de autorización. |
| 2 | **Dataproc** | Hadoop/Spark gestionado: los jobs existentes de Spark y Hive se migran tal cual con reescritura mínima, que es la restricción. (Reescribir a Dataflow es la mejor respuesta *a largo plazo* pero viola el requisito de 6 meses / reescritura mínima.) |
| 3 | **Datastream** | Captura de cambios (CDC) serverless desde Oracle/MySQL/PostgreSQL hacia BigQuery, basada en logs, así que no carga el origen con consultas. |
| 4 | **Cloud Data Fusion** | Constructor gráfico de pipelines de ETL sin código (basado en CDAP) apuntado exactamente a quienes no programan, con conectores y programación. |
| 5 | **Cloud Composer** | Apache Airflow gestionado: orquestación de DAGs con dependencias, reintentos, SLAs y operadores heterogéneos. Programa el *trabajo*; no procesa los datos él mismo. |
| 6 | **Bigtable** | Lecturas de milisegundos de un dígito con throughput clave-valor masivo y sostenido, y escalado lineal; BigQuery es un warehouse, no un almacén de servido de baja latencia. |
| 7 | **Looker** | Capa semántica LookML: una definición de métrica gobernada, versionada, consumida por dashboards, Sheets y portales embebidos por igual. |
| 8 | **Looker Studio** | Visualización gratuita, inmediata y compartible directamente sobre BigQuery; no hace falta capa de modelado para un gráfico puntual. |
| 9 | **Analytics Hub** | Publicás una vez como listing; los suscriptores obtienen un dataset vinculado que consulta en el lugar con su propio cómputo. Sin copias, sin egreso del publicador. |
| 10 | **BigQuery Omni** (con tablas **BigLake**) | Ejecuta cómputo de BigQuery en AWS/Azure contra los datos en el lugar, unibles con datos de BigQuery mediante una única interfaz SQL — sin pipeline de copia. |
| 11 | **BigQuery ML** | Entrenar y predecir en SQL donde ya están los datos; encaja con las habilidades del equipo y evita el movimiento de datos. |
| 12 | **Dataflow** (alimentado por **Pub/Sub**) | Ventanas hopping, watermarks y autoescalado a millones de eventos/segundo; esto es procesamiento de flujos, no orquestación. |

**A8.1 (pregunta)** — El criterio es **quién hace el trabajo y qué ya existe**. Dataproc existe para preservar una **inversión existente en código y habilidades de Hadoop/Spark** — su valor es la compatibilidad para migrar. Data Fusion existe para que **gente que no puede escribir código** cree pipelines nuevos — su valor es la interfaz visual. Si el escenario menciona jobs Spark/Hive existentes o un parque Hadoop, es Dataproc; si menciona usuarios no técnicos, arrastrar y soltar, o "sin escribir código", es Data Fusion.

**A8.2** — Composer es incorrecto para el 12 porque Airflow es un **planificador/orquestador**: dispara tareas según un cronograma o dependencias, con granularidad por tarea medida en segundos a minutos. No tiene noción de ventanas, watermarks ni estado por evento, y no puede procesar 2 M de eventos/segundo. Dataflow es incorrecto para el 5 porque un DAG de 40 pasos que abarca jobs de BigQuery, Cloud Storage y una API externa con reintentos y SLAs es **coordinación de flujos de trabajo entre sistemas heterogéneos**, no un grafo de procesamiento de datos — estarías reimplementando Airflow dentro de un pipeline. En la práctica se componen: Composer *lanza* jobs de Dataflow.

**A8.3** — "Producen una imagen que se ve igual pero resuelven problemas opuestos: Looker Studio deja que cualquiera defina una métrica, y Looker garantiza que todos usen la *misma* definición — para el margen neto de un CFO que aparece en un portal de cara a los partners, una definición inconsistente es un riesgo de reporte, no una preferencia de interfaz."

### Ejercicio 9

**A9.1** — La regla: **on-demand gana cuando el consumo es bajo o con picos en relación con la capacidad de slots que tendrías que reservar; las editions ganan cuando el consumo es lo bastante alto y estable como para mantener ocupada una línea base de slots.** El punto de cruce es esencialmente "¿escaneás suficientes datos por slot-hora como para superar los $6,25/TiB?". La razón no financiera para elegir editions igual es la **predictibilidad de costos y la gestión de cargas de trabajo**: las editions dan un techo duro al gasto (una consulta descontrolada no puede producir una factura sorpresa — simplemente se encola), más asignaciones de reservas que aíslan la carga de BI de la carga ad-hoc de los analistas, y funcionalidades atadas al nivel de edition. Muchas organizaciones eligen editions para hacer el número *conocible*, no para hacerlo más chico.

**A9.2** — Dos cualesquiera de: (i) **Mantener todo el histórico en línea.** Como almacenar datos no cuesta cómputo hasta que se consultan, y el almacenamiento de largo plazo se descuenta automáticamente tras 90 días sin modificación, nunca enfrentás la decisión de "archivarlo en cinta o borrarlo" que fuerza un appliance acoplado — así que una pregunta sobre datos de hace 7 años sigue siendo respondible. (ii) **Escalar el cómputo para algo puntual.** Un cierre de trimestre o una corrida de entrenamiento de ML puede consumir cómputo enorme durante horas y luego liberarlo, sin comprar hardware que queda ocioso el resto del año. (iii) **Compartir datos sin duplicarlos** — los suscriptores de Analytics Hub traen su propio cómputo a tu almacenamiento, lo cual solo es coherente cuando ambos se facturan por separado. (iv) **Imputar costos con precisión** — cada equipo paga por las preguntas que hace, no por una porción de una caja.

**A9.3** — Ejemplo: *"Hoy nuestro clickstream llega al warehouse en un lote nocturno, así que lo más temprano que alguien puede reaccionar a un problema de merchandising es a la mañana siguiente. Al enviar esos mismos eventos por streaming a través de Pub/Sub hacia BigQuery, quedan consultables en segundos, con validación de esquema en la puerta para que una release defectuosa de la app no pueda corromper el reporting. Concretamente, esto significa que cuando la conversión de agregar-al-carrito-a-checkout de un producto promocionado se derrumba a las 10 de la mañana — porque un precio está mal, el stock está mal informado o el paso de pago está fallando en un dispositivo — lo detectamos en minutos y retiramos o corregimos la promoción esa misma mañana, en lugar de leerlo en el reporte de mañana después de un día entero de margen perdido. La decisión que se vuelve posible es la intervención de merchandising intradiaria; el pipeline funciona sin un clúster dedicado ni un equipo de ETL, y el mismo flujo alimenta después controles de fraude en tiempo real y reasignación de inventario sin cambiar nada del lado de la publicación."*

</details>

---

## Fuentes oficiales

- Google Cloud, *Cloud Digital Leader — Exam Guide*: https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Descripción general de BigQuery: https://cloud.google.com/bigquery/docs/introduction
- Tablas particionadas: https://cloud.google.com/bigquery/docs/partitioned-tables · Tablas clusterizadas: https://cloud.google.com/bigquery/docs/clustered-tables
- Vistas materializadas: https://cloud.google.com/bigquery/docs/materialized-views-intro · BI Engine: https://cloud.google.com/bigquery/docs/bi-engine-intro
- Precios de BigQuery: https://cloud.google.com/bigquery/pricing · Editions: https://cloud.google.com/bigquery/docs/editions-intro
- `CREATE MODEL` de BigQuery ML: https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create · Modelos de series temporales: https://cloud.google.com/bigquery/docs/arima-single-time-series-forecasting-tutorial
- Seguridad a nivel de fila: https://cloud.google.com/bigquery/docs/row-level-security-intro · Vistas autorizadas: https://cloud.google.com/bigquery/docs/authorized-views · Seguridad a nivel de columna: https://cloud.google.com/bigquery/docs/column-level-security-intro
- Analytics Hub: https://cloud.google.com/bigquery/docs/analytics-hub-introduction · BigQuery Omni: https://cloud.google.com/bigquery/docs/omni-introduction
- Descripción general de Pub/Sub: https://cloud.google.com/pubsub/docs/overview · Suscripciones de BigQuery: https://cloud.google.com/pubsub/docs/bigquery · Esquemas: https://cloud.google.com/pubsub/docs/schemas
- Descripción general de Dataflow: https://cloud.google.com/dataflow/docs/overview · Pipelines de streaming: https://cloud.google.com/dataflow/docs/concepts/streaming-pipelines · Windowing en Beam: https://beam.apache.org/documentation/programming-guide/#windowing
- Dataproc: https://cloud.google.com/dataproc/docs/concepts/overview · Cloud Data Fusion: https://cloud.google.com/data-fusion/docs/concepts/overview · Datastream: https://cloud.google.com/datastream/docs/overview · Cloud Composer: https://cloud.google.com/composer/docs/concepts/overview
- Bigtable: https://cloud.google.com/bigtable/docs/overview · Dataplex: https://cloud.google.com/dataplex/docs/introduction
- Looker: https://cloud.google.com/looker/docs/intro · Looker Studio: https://cloud.google.com/looker/docs/studio · Connected Sheets: https://cloud.google.com/bigquery/docs/connected-sheets