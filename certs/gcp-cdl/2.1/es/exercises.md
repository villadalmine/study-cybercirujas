# Topic 2.1 — Ejercicios guiados
## Describir el rol intrínseco que juegan los datos en la transformación digital de una organización

**Certificación:** Google Cloud Digital Leader (guía de examen versión 2026-08-12) · **Peso de la sección 2:** 6.0

---

### Lo que vas a construir

Estos ejercicios no son una presentación de diapositivas. Vas a levantar una versión en miniatura de la arquitectura exacta que construye una empresa cuando deja de tratar a los datos como un desecho y empieza a tratarlos como un activo — y en cada paso se te va a preguntar *por qué le importa al negocio*, porque eso es lo que evalúa el examen.

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

### Requisitos previos

| Requisito | Verificación |
|---|---|
| Proyecto de Google Cloud con facturación habilitada | `gcloud billing projects describe $(gcloud config get-value project)` |
| `gcloud` ≥ 460 y la CLI `bq` (ambas vienen en Cloud Shell) | `gcloud version` |
| Roles sobre el proyecto | `roles/bigquery.admin`, `roles/storage.admin`, `roles/pubsub.admin`, `roles/datacatalog.admin` |
| Tiempo | ~150 minutos |

### Barreras de costo — leé esto antes de empezar

Toda consulta de este laboratorio se costea primero con dry-run. BigQuery on-demand factura **bytes escaneados**, no filas devueltas, y el primer 1 TiB por mes es gratis; Cloud Storage otorga 5 GiB-mes gratis en regiones de US. Ejecutado tal como está escrito, este laboratorio escanea bastante menos de 5 GiB y almacena menos de 100 MiB. Está diseñado para caer dentro del nivel gratuito, pero *verificá vos mismo las cifras actuales* — los precios están versionados, tu memoria no: <https://cloud.google.com/bigquery/pricing>.

> **Todas las salidas de comandos que siguen son ilustrativas.** `bigquery-public-data.thelook_ecommerce` es un dataset sintético que se regenera y avanza en el tiempo, así que los recuentos de filas y las fechas de tu ejecución **van a** diferir. Varios pasos te obligan deliberadamente a volver a medir en lugar de confiar en el número impreso. Ese hábito *es* parte del objetivo.

---

## Ejercicio 0 — Preparar el entorno del laboratorio

**Ancla conceptual:** antes de que los datos puedan ser un activo necesitan un lugar donde vivir, un dueño y una factura. Esas tres cosas son el contenido práctico de la "estrategia de datos".

1. Abrí Cloud Shell (o una shell local con `gcloud` autenticado) y fijá tus variables. Todos los ejercicios posteriores asumen que están exportadas.

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export BQ_LOCATION="US"                 # must match the public dataset's location
export BUCKET="gs://${PROJECT_ID}-cdl-data-lake"
echo "project=$PROJECT_ID number=$PROJECT_NUMBER bucket=$BUCKET"
```

2. Habilitá las APIs que usa el laboratorio. Habilitar una API es en sí mismo un acto de gobernanza — es el momento en que una capacidad pasa a estar disponible *y* facturable en ese proyecto.

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

3. Creá la zona de aterrizaje — el data lake — con uniform bucket-level access, para que los permisos se expresen **solo** a través de IAM y nunca mediante ACLs por objeto.

```bash
gcloud storage buckets create "$BUCKET" \
  --location="$BQ_LOCATION" \
  --uniform-bucket-level-access \
  --public-access-prevention
```

```
Creating gs://my-project-cdl-data-lake/...
```

4. Creá los dos datasets de BigQuery que van a representar las dos mitades de la plataforma de datos moderna.

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

### Comprobá lo que entendiste

- **Q0.1** — Creaste el bucket y ambos datasets en la multirregión `US`. ¿Qué operación concreta habría fallado más adelante si hubieras puesto el bucket en `europe-west1` y los datasets en `US`?
- **Q0.2** — `--public-access-prevention` y `--uniform-bucket-level-access` se establecieron en el momento de la creación, no después. ¿Por qué importa el *orden* para un programa de gobernanza de datos, y qué clase de incidente previene cada flag?
- **Q0.3** — En el lenguaje de la transformación digital, ¿cuál es la diferencia entre "habilitamos la API de BigQuery" y "tenemos una estrategia de datos"?

---

## Ejercicio 1 — Inventariar los datos: tres formas, una zona de aterrizaje

**Ancla conceptual:** el examen espera que distingas datos **estructurados**, **semiestructurados** y **no estructurados**, y que sepas que la mayoría de los datos empresariales son del tercer tipo — el que las bases de datos tradicionales nunca pudieron contener.

1. Generá un archivo de cada forma. Estos representan a tres departamentos que hoy no se hablan entre sí: Finanzas, Soporte y el centro de contacto.

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

2. Depositá los tres en el lake, particionados por sistema de origen — no por tipo de contenido. Los prefijos son la única estructura de navegación del lake.

```bash
gcloud storage cp marketing_spend.csv   "$BUCKET/raw/finance/"
gcloud storage cp support_tickets.json  "$BUCKET/raw/support/"
gcloud storage cp call_2026-08-02.txt   "$BUCKET/raw/contact-center/"
```

3. Preguntale al almacenamiento de objetos qué cree que está guardando.

```bash
gcloud storage ls --long --recursive "$BUCKET/raw/**"
```

```
       681  2026-09-06T12:04:11Z  gs://my-project-cdl-data-lake/raw/contact-center/call_2026-08-02.txt
       542  2026-09-06T12:04:09Z  gs://my-project-cdl-data-lake/raw/finance/marketing_spend.csv
      1104  2026-09-06T12:04:10Z  gs://my-project-cdl-data-lake/raw/support/support_tickets.json
TOTAL: 3 objects, 2327 bytes.
```

4. Inspeccioná específicamente los metadatos del objeto no estructurado.

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

### Comprobá lo que entendiste

- **Q1.1** — Clasificá cada uno de los tres archivos como estructurado, semiestructurado o no estructurado, y nombrá la *propiedad* que decide la clasificación. No es la extensión del archivo.
- **Q1.2** — Cloud Storage devolvió exactamente los mismos campos de metadatos para los tres objetos: tamaño, tipo de contenido, hash, clase. ¿Qué te dice esa uniformidad sobre por qué el almacenamiento de objetos — y no una base de datos relacional — se convirtió en el fundamento del patrón data lake?
- **Q1.3** — `T-1004` no tiene campo `csat` mientras que los otros cuatro tickets sí. En una tabla relacional esa fila sería imposible o llevaría un `NULL`. ¿Cuál es la consecuencia de negocio de una capa de almacenamiento que acepta registros irregulares sin quejarse — nombrá un beneficio y un riesgo.
- **Q1.4** — La transcripción de la llamada contiene la frase más valiosa de todo el laboratorio ("this is the second time this month", "I am cancelling the account"). ¿Cuál de los tres archivos es el *más difícil* de convertir en un número en un tablero, y qué clase de capacidad de Google Cloud cierra esa brecha?
- **Q1.5** — Nada en este ejercicio consultó nada. En la cadena de valor del dato **datos → información → insight → acción**, ¿qué etapa completaste, y cuál es el valor de detenerse acá?

---

## Ejercicio 2 — Data lake vs data warehouse: schema-on-read vs schema-on-write

**Ancla conceptual:** el lake y el warehouse no son productos que compiten, son dos momentos distintos en la vida de un hecho. El examen quiere el trade-off, no un ganador.

1. Creá una **external table** sobre el CSV crudo. Notá que no se copia nada y no se valida nada — el esquema se inventa en el momento de la consulta.

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

2. Hacé lo mismo con el JSON anidado, y mirá qué hizo autodetect con el objeto anidado `customer` y con el `csat` faltante.

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

3. Consultá la external table semiestructurada con el anidamiento aplanado. `UNNEST` es la forma en que un warehouse lee un documento sin destruir primero su forma.

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

4. Ahora promové el archivo de finanzas al **warehouse**: una tabla nativa, gestionada y columnar. Esto es schema-on-write — la carga o se ajusta o falla.

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

5. Estimá el costo de ambos caminos sin ejecutarlos. `--dry_run` es el hábito más útil en BigQuery.

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

> Para una tabla **nativa** BigQuery conoce el tamaño comprimido exacto de cada columna y devuelve un conteo de bytes preciso y facturable — acá solo se lee la columna `spend_usd`, no la fila entera. Para una tabla **external** no ha parseado los objetos, así que la estimación no es una señal de costo confiable; podés ver `0`, o el tamaño completo del objeto, según el formato. El costo predecible es una propiedad del warehouse.

### Comprobá lo que entendiste

- **Q2.1** — `bq mkdef --autodetect` infirió `csat` como `INT64` a partir de cinco filas, una de las cuales no tenía `csat` en absoluto. Describí el modo de falla cuando mañana llegue un sexto ticket con `"csat":"n/a"`. ¿En qué momento aparece la falla en el patrón lake versus el patrón warehouse, y cuál es más barato para el negocio?
- **Q2.2** — Contrastá las dos salidas de dry-run. ¿Cuál de los dos patrones de almacenamiento le permite a un CFO pronosticar la factura de analítica del próximo trimestre, y por qué?
- **Q2.3** — La external table no almacena bytes propios y la tabla nativa duplicó los datos. Dá un escenario de negocio donde pagar dos veces por el almacenamiento sea inequívocamente la decisión correcta, y uno donde sea desperdicio.
- **Q2.4** — Mapeá estos cuatro productos de Google Cloud al rol que juegan con los datos: **Cloud SQL**, **Cloud Storage**, **BigQuery**, **Cloud Spanner**. Usá los términos *sistema transaccional de registro (OLTP)*, *warehouse analítico (OLAP)*, *objetos/data lake*, *relacional distribuido globalmente*.
- **Q2.5** — Un ejecutivo dice "pongamos todo en el data lake y decidimos después". Enunciá el argumento más fuerte a favor y la falla que esta estrategia es famosa por producir.

---

## Ejercicio 3 — Del dato a la información: la consulta que responde una pregunta de negocio

**Ancla conceptual:** los datos crudos no tienen valor. El valor aparece solo cuando se les hace una pregunta — y el examen encuadra esto como *toma de decisiones basada en datos*.

1. Primero, averiguá qué contiene realmente el sistema operacional de registro. Nunca escribas una consulta de negocio contra un esquema que no verificaste.

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

2. Confirmá los nombres de los canales — tienen que coincidir exactamente con tu CSV de finanzas o el join del Ejercicio 4 va a descartar filas en silencio.

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

> **Si tu `last_user` es anterior a 2026-08-31**, el dataset sintético rotó a fechas distintas. Ajustá los literales `'2026-06-01'`/`'2026-08-31'` en los pasos siguientes a los últimos tres meses completos que realmente tengas, y editá `marketing_spend.csv` para que coincida; después volvé a ejecutar el `bq load` del Ejercicio 2 paso 4.

3. Hacé el dry-run de la pregunta de negocio antes de ejecutarla.

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

4. Fijate en lo que BigQuery *no* leyó. La tabla `users` tiene ~15 columnas; la consulta tocó dos.

```bash
bq show --format=prettyjson bigquery-public-data:thelook_ecommerce.users \
  | grep -E '"(numRows|numBytes)"'
```

```
  "numBytes": "18874368",
  "numRows": "100482"
```

### Comprobá lo que entendiste

- **Q3.1** — La tabla `users` completa pesa ~18 MB pero el dry run reportó ~2.4 MB. Explicá el mecanismo, y decí por qué el *almacenamiento columnar* es un hecho económico y no un detalle técnico.
- **Q3.2** — Los pasos 1 y 2 no produjeron ningún insight de negocio. ¿Por qué ejecutarlos antes de la consulta "real" es una obligación profesional y no una demora?
- **Q3.3** — A esta altura tenés recuentos de nuevos clientes por canal por mes. ¿Eso es **dato**, **información** o **insight**? Justificá usando las definiciones de la cadena de valor, y decí exactamente qué falta todavía para llegar a *acción*.
- **Q3.4** — El dataset es sintético y avanza en el tiempo, y por eso el laboratorio te dijo que verificaras `MIN`/`MAX` en lugar de confiar en las fechas impresas. Nombrá el peligro equivalente en el mundo real dentro de un warehouse empresarial y la disciplina de gobernanza que lo aborda.

---

## Ejercicio 4 — Romper el silo: el join que ningún sistema podía hacer solo

**Ancla conceptual:** este es el corazón del objetivo 2.1. El gasto de marketing vive en Finanzas. La adquisición de clientes vive en la plataforma de e-commerce. Ningún departamento puede calcular el **costo por cliente adquirido**. El valor lo crea el *join*, no ninguno de los dos datasets.

1. Calculá el CAC (Customer Acquisition Cost) uniendo tus datos de finanzas cargados con el sistema operacional de registro.

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

2. El CAC solo es una trampa: un canal puede ser caro de adquirir y aun así ser el más rentable. Agregá el lado de los ingresos para obtener el **ROAS** (Return on Ad Spend).

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

3. Persistí el resultado del join como una tabla curada. Este es el momento en que una consulta puntual se convierte en un hecho organizacional compartido.

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

### Comprobá lo que entendiste

- **Q4.1** — Ordená los cinco canales por CAC y después por ROAS. ¿Qué canal cambia de posición más drásticamente entre los dos ordenamientos, y qué decisión equivocada habría producido un tablero basado solo en CAC?
- **Q4.2** — Ni el equipo de Finanzas ni el de e-commerce podían calcular ninguno de los dos números por su cuenta. Nombrá el fenómeno en un término, y explicá por qué se describe como un problema *organizacional* más seguido que como uno *técnico*.
- **Q4.3** — El paso 3 reemplazó un `JOIN` interno por un `LEFT JOIN` y envolvió los ingresos en `IFNULL(...,0)`. ¿Qué filas canal-mes desaparecerían en silencio con el inner join, y cómo la pérdida silenciosa de filas destruye la confianza en un tablero más rápido que un error evidente?
- **Q4.4** — El `CREATE TABLE` lleva `OPTIONS(description=...)` nombrando una fuente y un dueño. ¿Qué dos propiedades de gobernanza establece esa única línea, y por qué una tabla curada sin documentar a veces es peor que ninguna tabla?
- **Q4.5** — Tu CFO pregunta: "ya teníamos estos dos números en dos planillas — ¿qué agregó realmente la nube?". Dá la respuesta de dos oraciones que debería dar un arquitecto.

---

## Ejercicio 5 — Calidad de datos: qué le hace una fila duplicada a una decisión

**Ancla conceptual:** la gobernanza no es papeleo. Los datos malos no producen *ninguna* decisión, producen una *decisión confiadamente equivocada* — que es estrictamente más cara.

1. Creá una versión realistamente sucia del archivo de finanzas. Una fila duplicada (una doble exportación), un spend NULL (una extracción fallida), un error de tipeo en el mes (carga manual).

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

> Observá: la carga **funcionó**. Schema-on-write valida *tipos*, no *verdad*.

2. Perfilá la tabla antes de confiar en ella. Este bloque de cuatro métricas es la verificación mínima viable de calidad de datos y debería existir para toda tabla curada.

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

3. Ahora mirá cómo se mueve el KPI. Recalculá el CAC de Search desde la tabla sucia y comparalo con la limpia.

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

4. Escribí la regla de calidad como una aserción exigible en lugar de una convención en un wiki.

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

### Comprobá lo que entendiste

- **Q5.1** — Solo se duplicó una fila de Search, y sin embargo **Display** y **Email** muestran un error de ~34 % y Display y Search se mueven en direcciones *opuestas*. Rastreá el mecanismo. ¿Por qué un error que se propaga a filas intactas es más peligroso que uno que se queda local?
- **Q5.2** — Rastreá cada uno de los tres defectos al proceso humano o de sistema que lo produjo: el duplicado, el NULL, el `2026-7`. ¿Cuál de los tres habría atrapado un *esquema* más estricto, y cuáles dos requieren una *regla*?
- **Q5.3** — Basándose solo en `cac_dirty`, ¿en qué canal habría redoblado la apuesta un equipo de crecimiento, y cuál es el costo en el mundo real de esa decisión a lo largo de un trimestre?
- **Q5.4** — El `ASSERT` hizo fallar el job con una salida distinta de cero. Explicá por qué *fallar ruidosamente y no publicar nada* es el comportamiento por defecto correcto para un pipeline de datos, y contrastalo con la alternativa de publicar un tablero con un cartel de advertencia.
- **Q5.5** — Dá la versión de una oración de por qué la "calidad de datos" figura como tema de *transformación digital* y no como tema de higiene de TI.

---

## Ejercicio 6 — Gobernanza I: mínimo privilegio, authorized views, seguridad a nivel de columna

**Ancla conceptual:** el valor de los datos sube con cuánta gente puede usarlos, y el riesgo sube con cuánta gente puede ver todo. La gobernanza es lo que hace que esas dos curvas sean separables.

1. Construí una tabla curada de clientes que contenga PII genuina.

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

2. Creá una **authorized view** que exponga datos aptos para análisis sin PII. Los analistas reciben la view; nadie recibe la tabla base.

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

3. Otorgá en el alcance más pequeño que funcione. `GRANT` a nivel de *schema* es el equivalente en DCL del principio de mínimo privilegio.

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

4. Agregá **seguridad a nivel de columna** para que la columna `email` esté protegida incluso frente a quienes legítimamente tienen acceso a la tabla.

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

5. Adjuntá el tag a la columna parcheando el esquema de la tabla.

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

6. Probá el control contra vos mismo. Sos el owner del proyecto — ese es exactamente el punto.

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

7. Otorgate a vos mismo el rol de lector de grano fino solo cuando haya una razón documentada, y observá cómo vuelve el acceso.

```bash
gcloud data-catalog taxonomies policy-tags add-iam-policy-binding "$POLICY_TAG" \
  --location=us \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/datacatalog.categoryFineGrainedReader"
```

> Si tu build de `gcloud` no expone `policy-tags add-iam-policy-binding`, hacé el mismo grant en la Consola bajo **Dataplex → Policy tags → cdl-pii → high-sensitivity--email → Manage permissions**. El efecto en IAM es idéntico.

### Comprobá lo que entendiste

- **Q6.1** — El paso 6 te denegó a *vos*, el Owner del proyecto. ¿Qué principio demuestra eso, y por qué "el admin siempre puede leer todo" es una postura inaceptable bajo regulaciones de clase GDPR?
- **Q6.2** — Ahora tenés dos controles independientes sobre `email`: la authorized view (que lo omite) y el policy tag (que lo bloquea). ¿Son redundantes? Dá el escenario que atrapa cada uno y que el otro no.
- **Q6.3** — La view convierte `age` en `age_band`. Nombrá la técnica de privacidad, y explicá por qué *aumenta* la cantidad de equipos que pueden usar la tabla de forma segura.
- **Q6.4** — Ordená estos grants de menos a más privilegiado para un analista que necesita el rendimiento por canal: `roles/bigquery.admin` sobre el proyecto · `roles/bigquery.dataViewer` sobre `cdl_warehouse` · `roles/bigquery.dataViewer` solo sobre `customers_analytics`. ¿Cuál emitirías realmente, y cuál es el costo operativo de la opción más restrictiva?
- **Q6.5** — Una unidad de negocio argumenta que los controles de gobernanza frenan la analítica y reducen el valor de la plataforma de datos. Refutalo en dos oraciones usando este ejercicio como evidencia.

---

## Ejercicio 7 — Gobernanza II: residencia, retención, ciclo de vida — dónde tienen permitido vivir los datos

**Ancla conceptual:** para las industrias reguladas, *dónde* se encuentra físicamente un byte es un hecho legal antes que técnico. La nube hace de la ubicación una configuración explícita y exigible.

1. Creá un dataset y un bucket residentes en la UE, representando una filial sujeta a residencia de datos en la UE.

```bash
bq --location=EU mk -d --description "EU-resident zone" "${PROJECT_ID}:cdl_warehouse_eu"

gcloud storage buckets create "gs://${PROJECT_ID}-cdl-eu" \
  --location=europe-west1 --uniform-bucket-level-access --public-access-prevention
```

2. Intentá copiar datos de US al dataset de la UE. Esto tiene que fallar — y la falla es el entregable.

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE `'"$PROJECT_ID"'.cdl_warehouse_eu.customers_copy` AS
SELECT * EXCEPT(email) FROM `'"$PROJECT_ID"'.cdl_warehouse.customers`'
```

```
BigQuery error in query operation: Not found: Dataset
my-project:cdl_warehouse was not found in location EU
```

> BigQuery no va a mover datos silenciosamente entre ubicaciones. El motor trata a una región como un límite duro — el mismo límite que el regulador describe en prosa.

3. Confirmá que el mismo límite aplica a Cloud Storage y BigQuery en conjunto.

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

4. Expresá la política de retención como código. Los datos crudos se enfrían y después se borran — porque conservar datos más allá de su propósito legal es un *pasivo*, no un activo.

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

5. Agregá una política de retención en el bucket de la UE — la mitad "no se puede borrar antes de tiempo" del cumplimiento, que es la imagen espejo del paso 4.

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

> **No ejecutes `--lock-retention-period` en una cuenta de laboratorio.** El bloqueo es irreversible: el bucket y todos sus objetos se vuelven imborrables hasta que expire el período — siete años, en esta configuración. Esa irreversibilidad es precisamente lo que la hace evidencia aceptable para un auditor.

### Comprobá lo que entendiste

- **Q7.1** — Aparecieron dos mensajes de error distintos en los pasos 2 y 3. Decí qué prueba cada uno sobre cómo se hace cumplir la ubicación, y por qué un control de ingeniería le gana a una política escrita ante un regulador.
- **Q7.2** — El paso 4 borra a los 2555 días; el paso 5 prohíbe borrar antes de los 2555 días. Describí el requisito de cumplimiento que necesita *ambos*, y nombrá el riesgo que cada uno por separado deja abierto.
- **Q7.3** — Las reglas de ciclo de vida mueven objetos STANDARD → NEARLINE → COLDLINE → ARCHIVE. ¿Qué trade-off se está comprando en cada salto, y por qué es seguro para `raw/` pero sería peligroso para una tabla que alimenta un tablero en vivo?
- **Q7.4** — Explicá por qué "guardamos todos nuestros datos para siempre, por las dudas" es una posición de *riesgo* y no de *valor*, usando dos argumentos distintos (uno financiero, uno legal).
- **Q7.5** — Una multinacional quiere una única vista global de cliente 360 pero está sujeta a residencia en la UE. Dado lo que acabás de observar, esbozá las dos opciones arquitectónicas y nombrá el trade-off que acepta cada una.

---

## Ejercicio 8 — Velocidad: batch, streaming y la vida útil de un insight

**Ancla conceptual:** los datos tienen una vida media. Una señal de fraude vale muchísimo durante noventa segundos y nada a la mañana siguiente; un número de ingresos para el directorio vale lo mismo el martes que el lunes. La velocidad es un requisito de negocio, no una preferencia tecnológica.

1. Creá el camino de ingesta en streaming.

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

2. Otorgale al service agent de Pub/Sub permiso para escribir. Nada fluye hasta que esa identidad exista y esté autorizada.

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor" \
  --condition=None
```

3. Creá la BigQuery subscription — ingesta en streaming gestionada, sin código y sin pipeline que operar.

```bash
gcloud pubsub subscriptions create orders-to-bq \
  --topic=orders-stream \
  --bigquery-table="${PROJECT_ID}:cdl_warehouse.orders_stream" \
  --use-table-schema
```

```
Created subscription [projects/my-project/subscriptions/orders-to-bq].
```

4. Publicá eventos y cronometrá vos mismo el viaje de ida y vuelta.

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

5. Publicá un mensaje malformado y averiguá adónde van los datos malos en un mundo de streaming.

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

> El mensaje no pudo parsearse contra el esquema de la tabla. Sin un dead-letter topic configurado se reintenta y finalmente se descarta — **en silencio**. En batch, una fila mala hace fallar un job que alguien está mirando; en streaming, una fila mala desaparece a menos que hayas construido algún lugar adonde pueda ir.

6. Compará los dos caminos de ingesta que ya construiste, lado a lado.

| | **Batch** (`bq load`, Ej. 2) | **Streaming** (Pub/Sub → BigQuery, Ej. 8) |
|---|---|---|
| Latencia hasta poder consultarse | minutos a horas | segundos |
| Superficie de falla | el job falla, es visible, es reejecutable | el mensaje se descarta, hace falta un dead-letter topic |
| Modelo de costo | carga gratis, se paga el almacenamiento | se paga por byte ingerido + almacenamiento |
| Corrección | recargar el archivo | reproducir desde el topic, si la retención lo permite |
| Encaja en | cierre financiero, reporte al directorio, sets de entrenamiento de ML | fraude, inventario, personalización, alertas |

### Comprobá lo que entendiste

- **Q8.1** — Para cada uno de estos, decidí batch o streaming y justificá en una línea: (a) paquete mensual de ingresos para el directorio, (b) scoring de fraude con tarjeta en el checkout, (c) "los clientes también compraron" en una página de producto, (d) presentación regulatoria anual, (e) alertas de quiebre de stock en depósito.
- **Q8.2** — El mensaje malo del paso 5 se desvaneció sin un error que alguien fuera a ver. Nombrá la característica de Pub/Sub que lo soluciona, y explicá por qué la pérdida *no detectada* es peor para la confianza que una falla ruidosa del pipeline.
- **Q8.3** — La tabla `orders_stream` es `PARTITION BY DATE(created_at)`. Explicá cómo esa única cláusula cambia tanto el costo como la velocidad de "los pedidos de ayer", y conectalo con el punto de facturación columnar de Q3.1.
- **Q8.4** — No escribiste código de pipeline, no desplegaste ningún servidor, y la subscription escala sola. Nombrá los dos cambios de modelo operativo que esto representa para un departamento de TI, en el vocabulario que usa el examen.
- **Q8.5** — Un ejecutivo pide "hacer todo en tiempo real". Dá las dos preguntas que harías antes de aceptar, y decí qué dimensión de costo están sondeando.

---

## Ejercicio 9 — Capstone: la cadena de valor de punta a punta, y cuánto costó

**Ancla conceptual:** ya podés armar el argumento que el objetivo realmente pide — *por qué* los datos son intrínsecos a la transformación digital, evidenciado por artefactos que construiste en lugar de afirmados.

1. Inventariá todo lo que creaste y ubicá cada artefacto en la cadena de valor.

```bash
bq ls --format=pretty "${PROJECT_ID}:cdl_lake"
bq ls --format=pretty "${PROJECT_ID}:cdl_warehouse"
gcloud storage ls --recursive "$BUCKET/**"
gcloud pubsub subscriptions list --format="value(name,bigqueryConfig.table)"
```

2. Medí lo que consumió todo el laboratorio. El gasto que no se mide no se gestiona.

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

> El `6.25` es la tarifa on-demand en USD por TiB al momento de escribir esto; confirmala contra <https://cloud.google.com/bigquery/pricing> en lugar de confiar en la constante. `total_bytes_billed` difiere de `total_bytes_processed` por el mínimo de 10 MB por tabla.

3. Releé el artefacto que realmente le entregarías a un stakeholder de negocio.

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

4. Completá esta tabla con tu propia ejecución. Es el objetivo del examen, expresado como evidencia.

| Etapa de la cadena de valor | Artefacto que construiste | Producto de Google Cloud | Capacidad de negocio desbloqueada |
|---|---|---|---|
| Origen / silo | 3 archivos, 3 departamentos | — | *(completás vos)* |
| Ingesta | `gcloud storage cp`, Pub/Sub topic | | |
| Almacenar (crudo) | `gs://…/raw/**` | | |
| Almacenar (curado) | tablas nativas `cdl_warehouse.*` | | |
| Procesar | external tables, `CREATE TABLE AS` | | |
| Analizar | consultas de CAC / ROAS | | |
| Activar | `channel_performance` | | |
| Gobernar | authorized view, policy tag, ciclo de vida, residencia | | |
| Asegurar | `ASSERT`, consulta de perfilado | | |

### Comprobá lo que entendiste — nivel examen

- **Q9.1** — En dos oraciones, usando la tabla de ROAS como evidencia, decí por qué los datos son *intrínsecos* a la transformación digital y no una función de apoyo de ella.
- **Q9.2** — Nombrá las cuatro barreras para volverse data-driven que este laboratorio demostró concretamente, y citá el ejercicio que demostró cada una.
- **Q9.3** — Una empresa dice: "tenemos doce años de historia en un data warehouse on-premises, ya somos data-driven". Dá tres preguntas que pongan a prueba esa afirmación, cada una apuntando a una propiedad distinta que ejercitaste en este laboratorio.
- **Q9.4** — Ubicá cada producto en la cadena de valor en una palabra: **Pub/Sub**, **Cloud Storage**, **Dataflow**, **BigQuery**, **Dataplex Universal Catalog**, **Looker**, **Vertex AI**, **Cloud SQL**.
- **Q9.5** — Todo el laboratorio costó menos de un centavo de dólar en consultas. ¿Qué recurso era realmente escaso acá, y qué implica ese cambio sobre dónde está ahora el cuello de botella de un programa de datos?
- **Q9.6** — ¿Qué único artefacto del Ejercicio 9 paso 1 borrarías primero si el CISO ordenara una reducción inmediata del riesgo de datos, y qué capacidad de negocio perderías?

---

## Limpieza

Ejecutá esto al terminar. Todo lo creado se destruye; nada fuera del laboratorio se toca.

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

> Si hubieras ejecutado `--lock-retention-period` en el Ejercicio 7 paso 5, esta limpieza fallaría y el bucket quedaría, facturable, durante siete años. Esa es la lección, no una nota al pie.

---

## Clave de respuestas

<details>
<summary><b>Hacé clic para revelar todas las respuestas (Ejercicios 0–9)</b></summary>

### Ejercicio 0

**Q0.1** — Cualquier operación que lea y escriba entre las dos ubicaciones: crear una external table de BigQuery sobre ese bucket, o hacer `bq load` desde él hacia un dataset en `US`. BigQuery requiere que el dataset y el bucket de Cloud Storage estén en ubicaciones compatibles; obtendrías `Cannot read and write in different locations. Source: EU, Destination: US` — que es exactamente el error que producís deliberadamente en el Ejercicio 7 paso 3. La ubicación se elige una vez, en la creación, y la ubicación de un dataset no se puede cambiar después. (<https://cloud.google.com/bigquery/docs/locations>)

**Q0.2** — Ambos flags son muchísimo más fáciles de aplicar sobre un bucket vacío que de adaptar a uno que ya contiene un millón de objetos con ACLs heterogéneas por objeto, donde activar el acceso uniforme puede revocar accesos de los que algo en producción depende silenciosamente. La gobernanza aplicada en la creación es una decisión de diseño; la gobernanza aplicada después es un proyecto de migración con una caída de servicio adjunta. **Uniform bucket-level access** previene la clase de incidente "a un objeto se le otorgó acceso a `allUsers` mediante un script hace tres años y nadie puede auditarlo", eliminando por completo las ACLs por objeto. **Public access prevention** bloquea la brecha de datos en la nube más común de todas: un bucket de almacenamiento expuesto a internet sin intención.

**Q0.3** — Habilitar una API crea una *capacidad*. Una estrategia de datos responde preguntas que la API no puede: qué decisiones pretende tomar la organización con los datos, quién es dueño de cada dataset, qué barra de calidad debe cumplir, cuánto tiempo puede retenerse, quién puede verlo y cómo se mide el valor. La tecnología es la parte barata — el cómputo de este laboratorio costó menos de un centavo — mientras que las respuestas sobre propiedad, calidad y gobernanza son la parte cara y la que determina si la plataforma se usa o no.

### Ejercicio 1

**Q1.1** —
- `marketing_spend.csv` → **estructurado**: un esquema fijo y predeclarado; cada registro tiene los mismos campos en el mismo orden, y el esquema vive fuera de los datos.
- `support_tickets.json` → **semiestructurado**: lleva su propio esquema en línea (claves autodescriptivas), permite anidamiento (`customer.segment`), repetición (`tags`) y registros irregulares (`T-1004` no tiene `csat`).
- `call_2026-08-02.txt` → **no estructurado**: sin esquema alguno, ni en línea ni externo. Tiene *significado* pero no campos.

La propiedad que decide es **dónde vive el esquema**, no la extensión: externo y fijo → estructurado; en línea y flexible → semiestructurado; ausente → no estructurado. Un archivo `.json` podría tener un esquema rígido, y una columna `.csv` podría contener texto libre.

**Q1.2** — Cloud Storage es completamente indiferente al contenido: almacena bytes más metadatos y nunca valida. Esa indiferencia es todo el punto. Una base de datos relacional rechaza cualquier cosa que no entre en su esquema, lo que significa que solo puede contener datos que ya entendías en el momento del diseño. El almacenamiento de objetos acepta cualquier cosa a muy bajo costo, lo que permite a una organización depositar datos *antes* de saber qué pregunta van a responder — la propiedad definitoria del patrón data lake, y la razón por la que se convirtió en la capa de base en lugar de la base de datos. (<https://cloud.google.com/learn/what-is-a-data-lake>)

**Q1.3** — **Beneficio:** el sistema de origen puede evolucionar — agregar `csat`, agregar un campo, cambiar un productor — sin romper la ingesta ni requerir una migración de esquema. Los datos siguen llegando durante el cambio en lugar de perderse, y el tiempo hasta ingerir una fuente nueva baja de semanas a horas. **Riesgo:** nada detecta que falta `csat`. Silenciosamente se vuelve `NULL`, `AVG(csat)` se calcula sobre un subconjunto no anunciado, y la cifra reportada es un promedio con *sesgo de supervivencia* que se ve perfectamente legítimo en un tablero. La flexibilidad en la ingesta se paga con verificaciones de calidad obligatorias aguas abajo — que es el Ejercicio 5.

**Q1.4** — La **transcripción de la llamada** es la más difícil: contiene la señal de churn ("second time this month", "I am cancelling the account") en una forma que ningún `GROUP BY` puede alcanzar. La brecha la cierra la **IA/ML aplicada a datos no estructurados** — comprensión de lenguaje natural para sentimiento, extracción de entidades e intención; speech-to-text aguas arriba; comprensión de documentos para artefactos escaneados. Por eso la IA no es un tema separado de los datos: la IA es el único mecanismo que convierte la categoría *más grande* de datos empresariales (comúnmente estimada en 80–90 % del total) en filas sobre las que un negocio puede actuar. (<https://cloud.google.com/use-cases/ai-data-analytics>)

**Q1.5** — Solo la primera etapa: **datos**. No hay información, ni insight, ni acción. Y aun así vale la pena hacerlo, por tres razones: los datos existen en un único lugar durable, direccionable y con control de acceso en lugar de en tres laptops; ahora están disponibles para preguntas que nadie hizo todavía, incluidas preguntas que recién se van a hacer dentro de dos años; y depositarlos es barato (fracciones de centavo por GB-mes) mientras que *no* depositarlos es irreversible — los datos no capturados hoy no se pueden capturar retroactivamente.

### Ejercicio 2

**Q2.1** — Con `"csat":"n/a"`, la inferencia `INT64` de autodetect deja de sostenerse. **En el lake (external table, schema-on-read):** no pasa nada en la ingesta — el archivo aterriza bien. El error aparece en *tiempo de consulta*, para quien casualmente ejecute la consulta, posiblemente semanas después, posiblemente un miembro del directorio: `Could not parse 'n/a' as INT64`. O peor: autodetect vuelve a muestrear y promueve silenciosamente la columna a `STRING`, lo que rompe todo `AVG(csat)` aguas abajo sin ningún error. **En el warehouse (schema-on-write):** el job de `bq load` falla de inmediato, con un ID de job nombrado, un dueño y un artefacto reejecutable.

La falla del warehouse es mucho más barata: se detecta en segundos por la persona que la causó, está contenida (no se publicó nada malo) y la corrección es obvia. La falla del lake se detecta tarde, por la persona equivocada, después de que ya se hayan tomado decisiones sobre el número malo. **El costo de un defecto ∝ el tiempo hasta su detección.**

**Q2.2** — La **tabla nativa**. BigQuery mantiene estadísticas comprimidas exactas por columna, así que `--dry_run` devuelve un conteo de bytes preciso y contractual *antes* de ejecutar la consulta — que es la base de una estimación de costo, de una barrera de tamaño de consulta (`--maximum_bytes_billed`), de un modelo de chargeback y de un pronóstico trimestral. Para las external tables BigQuery no leyó ni catalogó los objetos, así que la estimación no es una señal de costo utilizable. El gasto predecible es un argumento *a favor* de la capa curada del warehouse, independientemente del rendimiento.

**Q2.3** —
- **Decisión correcta:** cualquier dataset que mucha gente consulta repetidamente. Curarlo una vez en una tabla nativa hace que el parseo, el casteo de tipos y la compresión ocurran una sola vez en lugar de en cada consulta. El almacenamiento duplicado cuesta centavos por GB-mes; el re-parseo evitado cuesta mucho más en tiempo de consulta, en cómputo y en horas de analistas. También te da un objeto estable, descrito y gobernable sobre el cual otorgar accesos y adjuntar policy tags.
- **Desperdicio:** un archivo crudo grande consultado una o dos veces al año para búsquedas de cumplimiento, o uno que sigue en triaje exploratorio donde nadie decidió qué importa. Copiar petabytes para atender dos consultas al año es puro costo — dejalo en el lake y consultalo in situ.

**Q2.4** —
- **Cloud SQL** — sistema transaccional de registro (OLTP): MySQL/PostgreSQL/SQL Server gestionados, orientado a filas, optimizado para muchas lecturas y escrituras chicas; donde se *coloca* el pedido. (<https://cloud.google.com/sql/docs/introduction>)
- **Cloud Storage** — objetos/data lake: la zona de aterrizaje cruda y agnóstica al esquema para cualquier byte, de cualquier forma. (<https://cloud.google.com/storage/docs/introduction>)
- **BigQuery** — warehouse analítico (OLAP): columnar, serverless, separa almacenamiento de cómputo, optimizado para escanear miles de millones de filas para responder una pregunta; donde se *analiza* el pedido. (<https://cloud.google.com/bigquery/docs/introduction>)
- **Cloud Spanner** — relacional distribuido globalmente: semántica OLTP con consistencia externa fuerte y escala horizontal entre regiones; para un sistema de registro que no puede fragmentarse y no puede caerse. (<https://cloud.google.com/spanner/docs/overview>)

La distinción recurrente en el examen: **OLTP hace funcionar el negocio, OLAP lo entiende.**

**Q2.5** — **A favor:** el almacenamiento es barato y el costo de *no* tener los datos es ilimitado e irreversible. No podés recolectar retroactivamente el clickstream del año pasado. Depositar todo preserva la opcionalidad para preguntas que la organización todavía no pensó, y esa opcionalidad es genuinamente valiosa. **Falla famosa:** el **data swamp** — un lake sin catálogo, sin propiedad, sin métricas de calidad y sin linaje, donde los datos están técnicamente presentes y prácticamente son inutilizables, porque nadie puede decir cuál de los once archivos `customers_final_v3` es el autoritativo ni si está completo. La solución no es almacenar menos, es adjuntar metadatos de gobernanza *en el momento del aterrizaje* — catalogación, propiedad, contratos de calidad, ciclo de vida. (<https://cloud.google.com/dataplex/docs/introduction>)

### Ejercicio 3

**Q3.1** — BigQuery almacena los datos **columna por columna**, no fila por fila. La consulta referenció solo `traffic_source` y `created_at`, así que solo se leyeron los bloques de esas dos columnas; las otras ~13 columnas nunca se tocaron y nunca se facturaron. BigQuery on-demand factura bytes *escaneados*, así que la disposición del almacenamiento se traduce directamente en la factura: `SELECT *` sobre esta tabla habría costado aproximadamente 8× más que `SELECT traffic_source, created_at` para el mismo valor de negocio. Por eso `SELECT *` es un antipatrón en un warehouse y no una preferencia de estilo, y por eso el particionado y el clustering — que podan bloques enteros antes de que empiece el escaneo — son controles de costo primero y controles de rendimiento después. (<https://cloud.google.com/bigquery/docs/best-practices-costs>)

**Q3.2** — Porque la alternativa es publicar un número derivado de un supuesto que nunca probaste. Concretamente: si `traffic_source` hubiera contenido `'facebook'` en lugar de `'Facebook'`, el join del Ejercicio 4 habría matcheado cero filas para ese canal y habría devuelto una *tabla más corta* en lugar de un error — y una tabla más corta se ve exactamente igual que una tabla correcta. Verificar cardinalidad, rango de fechas y valores del dominio cuesta una consulta barata y es la diferencia entre un análisis y una adivinanza. Este es el equivalente analítico de leer el contrato de una API antes de llamarla.

**Q3.3** — Es **información**: datos agregados, contextualizados y con una unidad ("1.602 nuevos clientes de Search en junio de 2026"). Todavía no es **insight**, porque el insight requiere comparación contra algo que le dé *significado* al número — un objetivo, un período anterior, un costo u otro canal. Lo que falta para llegar a **acción**: el lado del *costo* (el join del Ejercicio 4 produce el CAC, que finalmente hace comparables a los canales), una **regla de decisión** o umbral que diga qué hacer ante un valor dado, y un **dueño** con autoridad presupuestaria para actuar. Un número sobre el que nadie está facultado para actuar es un reporte, no una decisión.

**Q3.4** — El equivalente en el mundo real es la **deriva de esquema y semántica**: un equipo aguas arriba renombra una columna, cambia una unidad de centavos a dólares, agrega una sexta fuente de tráfico o hace un backfill del historial — todo sin avisarle a nadie aguas abajo, porque no sabe quién está aguas abajo. Las disciplinas que lo abordan: **linaje de datos** (saber quién consume qué antes de cambiarlo), **contratos de datos** (el productor se compromete a un esquema y a una semántica, con una ventana de deprecación), **monitoreo de frescura y volumen** (alertar cuando una tabla deja de actualizarse o su cantidad de filas se reduce a la mitad) y **catalogación** para que los consumidores sean siquiera descubribles. Este es el contenido operativo de la gobernanza de datos. (<https://cloud.google.com/dataplex/docs/introduction>)

### Ejercicio 4

**Q4.1** — Por CAC (más barato primero): Organic 23.57, Search 26.56, Email 58.06, Facebook 205.36, Display 435.26. Por ROAS (mejor primero): Organic 4.87, Search 4.12, Email 1.98, Facebook 0.57, Display 0.27. **Email** es el que más se mueve en *interpretación*: con un CAC de $58 parece de gama media y defendible, pero con un ROAS de 1.98 apenas es marginalmente rentable una vez que tenés en cuenta lo que esos clientes realmente gastan. La decisión equivocada a partir de un tablero solo de CAC es más sutil y más cara que "cortar Display": es **sobreinvertir en Email** — un canal con un costo de adquisición aceptable que adquiere clientes de bajo valor. El CAC mide lo que pagás; el ROAS mide lo que obtenés. Un canal puede ser barato de adquirir y destruir valor, o caro de adquirir y ser la mejor inversión que tenés. Nunca optimices una métrica de costo sin su contraparte de valor.

**Q4.2** — El fenómeno son los **silos de datos**. Se lo llama organizacional y no técnico porque la solución técnica acá fue un `JOIN` que corrió en menos de dos segundos — la dificultad nunca fue el SQL. Los obstáculos reales son que Finanzas y E-commerce tienen dueños distintos, presupuestos distintos, herramientas distintas, definiciones distintas de "cliente" y ningún incentivo compartido para exponer sus datos; que los KPIs de cada equipo se miden dentro de su propio límite, así que integrar es trabajo no compensado; y que "nuestros datos son sensibles" es una razón infalsable y segura para la carrera con la cual negarse. Por eso romper silos es un programa de **transformación** con patrocinio ejecutivo y no un ticket de ingeniería de datos.

**Q4.3** — Con `JOIN` (interno), cualquier canal-mes con gasto pero *cero* nuevos clientes atribuibles o *cero* ingresos desaparece del resultado — un canal lanzado pero fracasando, o un mes donde la extracción corrió antes de tiempo. La salida es una tabla de aspecto válido con menos filas. La pérdida silenciosa de filas es corrosiva porque la falla es invisible: los totales son más bajos pero nada está en rojo, ningún job falló, ninguna alerta se disparó, y el número es *plausible*. Un tablero obviamente roto se arregla en una hora; un tablero que está calladamente 8 % bajo se usa para decidir durante un trimestre y después se descubre el error, momento en el cual todo número que la plataforma haya producido queda bajo sospecha. El `LEFT JOIN` más `IFNULL(...,0)` hace que el canal que fracasa aparezca con `revenue_usd = 0` y `roas = 0.0` — que es la afirmación *verdadera* y accionable.

**Q4.4** — Establece **procedencia/linaje** (de qué fuentes se derivó, para que un consumidor pueda juzgar si responde su pregunta y un ingeniero sepa qué la rompe) y **propiedad/administración** (un equipo nombrado, responsable de la corrección, la frescura y las decisiones de acceso). Una tabla curada sin documentar es peor que ninguna porque carga con la *autoridad* del warehouse — alguien va a encontrar `channel_performance`, va a asumir que es oficial y la va a usar — sin cargar con nada de la *responsabilidad*. Nadie puede decir qué rango de fechas cubre, si sigue refrescándose, ni a quién preguntarle. La descubribilidad sin procedencia fabrica respuestas confiadamente equivocadas a escala; así es precisamente como un lake se vuelve un swamp.

**Q4.5** — "Cada planilla tenía la mitad de un número, y ningún equipo podía calcular el número entero sin una reunión — así que el número efectivamente no existía, y la decisión se tomaba por instinto. Lo que agregó la plataforma es que ahora el número existe de forma continua, es gobernado y reproducible, se refresca sin depender de la agenda de nadie, y se puede unir al *próximo* dataset sin otra negociación."

### Ejercicio 5

**Q5.1** — El mecanismo es el límite de agregación. La fila duplicada de Search infla el gasto de Search, así que el CAC de Search sube (26.56 → 33.06 — un error genuino y local). Display y Email no cambiaron en términos absolutos, pero **un denominador o un ranking se corrió**: con el gasto total inflado en 42.000, cada participación sobre el gasto, cada índice y cada comparación relativa del mismo reporte se repondera, y un canal cuyas cifras absolutas están intactas aparece 34 % mejor o peor. Bajo un `SUM(...) OVER ()`, un porcentaje del total o un paso de normalización, una fila mala contamina *todas* las filas del reporte.

Esa propagación es lo que lo hace peligroso. Un número localmente erróneo lo puede detectar quien es dueño de ese canal — "nuestro gasto en Search nunca fue de 174k". Una distorsión propagada globalmente no tiene tal dueño: el gerente de Display ve un número que está mal por razones enteramente ajenas a sus datos, no puede detectarlo por inspección y no tiene motivo para desconfiar. Por eso la calidad de datos debe imponerse *en la ingesta*, antes de la agregación, y no auditarse después en el reporte.

**Q5.2** —
- **Fila duplicada** → un defecto de proceso: un job de ETL volvió a correr sin idempotencia, o alguien exportó el reporte dos veces y anexó ambos. Requiere una **regla** (restricción de unicidad sobre la clave de negocio `channel+month`, o ingesta idempotente con merge por clave). Un esquema no puede atraparlo: ambas filas están perfectamente bien tipadas.
- **`spend_usd` NULL** → una falla de extracción aguas arriba o una celda sin completar. Un **esquema más estricto sí atrapa este**: declarar la columna `REQUIRED`/`NOT NULL` habría rechazado la carga de plano. Este es el único defecto que un contrato schema-on-write previene genuinamente.
- **`2026-7`** → carga manual sin validación. Requiere una **regla** (validación de formato con regex, o mejor, tipar la columna como `DATE` para que el parseo falle). Tal como se cargó en una columna `STRING` es un valor legal; solo una regla de negocio sabe que el formato canónico es `YYYY-MM`. Su daño real es que *no matchea en el join* — la fila desaparece silenciosamente del reporte de CAC en lugar de producir un error.

La lección general: los esquemas imponen **forma**, las reglas imponen **significado**, y la mayoría de los defectos reales de datos son defectos de significado.

**Q5.3** — **Display**, con un CAC aparente de $287 versus su verdadero $435 — y peor, un equipo que mira solo los números sucios ve a Display y Email como los canales que mejoran mientras Search parece degradarse. El costo real a lo largo de un trimestre: presupuesto desviado *desde* el canal con ROAS 4.12 hacia uno con ROAS 0.27, así que cada dólar reasignado destruye aproximadamente 96 centavos de retorno. Sobre el gasto trimestral de ~$366k de este laboratorio, una reasignación del 20 % es del orden de $70k movidos desde un canal 4× a uno 0.27× — una pérdida directa de valor muy dentro de las seis cifras anuales. Y sumale el costo de segundo orden: cuando el error finalmente se descubre, cada decisión histórica tomada sobre ese tablero hay que volver a litigarla, y la credibilidad del equipo de analítica ante el negocio — eso que llevó dos años construir — desaparece.

**Q5.4** — Porque el producto de un pipeline de datos es la **confianza**, y la confianza no es un gradiente. Si los datos malos pueden llegar al tablero en alguna circunstancia, entonces cada número de ese tablero requiere verificación independiente antes de usarse, lo que destruye todo el argumento económico de la plataforma — el punto entero era que el negocio pudiera actuar sin volver a chequear. Una falla dura es ruidosa, tiene un dueño, bloquea la publicación y se arregla en horas porque hay alguien incomodado *ahora*. Un cartel de advertencia falla por razones humanas bien entendidas: los carteles se descartan, las capturas se pegan en presentaciones sin ellos, el cartel se vuelve ruido de fondo permanente en una semana, y los consumidores a tres saltos de distancia nunca lo ven. El comportamiento por defecto correcto es **viejo-pero-correcto por sobre fresco-pero-erróneo**: el número verificado de ayer es casi siempre más útil que el no verificado de hoy.

**Q5.5** — Porque la calidad de datos no determina si obtenés una decisión — determina si la decisión es correcta, y una decisión confiadamente equivocada ejecutada a velocidad y escala de nube destruye más valor que ninguna decisión; la transformación digital *aumenta* la dependencia de una organización respecto de los datos para decidir, así que multiplica la consecuencia de cada defecto.

### Ejercicio 6

**Q6.1** — El **principio de mínimo privilegio**, llevado al punto en que una autoridad administrativa amplia sobre la *infraestructura* no confiere autoridad sobre el *contenido de los datos*. La seguridad a nivel de columna vía policy tags se aplica independientemente del IAM a nivel de tabla, así que `roles/owner` no otorga ningún acceso a una columna etiquetada sin `roles/datacatalog.categoryFineGrainedReader` sobre el tag.

"El admin siempre puede leer todo" es inaceptable bajo regulaciones de clase GDPR por varias razones. El Artículo 32 exige medidas técnicas proporcionales al riesgo, y una lectura permanente e ilimitada sobre datos personales no es proporcional. Los datos personales deben procesarse con un propósito especificado, y "ser administrador de base de datos" no es uno. La amenaza interna y la amenaza de credenciales comprometidas están ambas concentradas exactamente en esas cuentas. Y un control que tiene un bypass incondicional y sin registro no es un control — es documentación. La postura correcta es que incluso el acceso privilegiado a PII sea **explícitamente otorgado, acotado en el tiempo, justificado y auditado**. (<https://cloud.google.com/bigquery/docs/column-level-security>)

**Q6.2** — No son redundantes; operan en capas distintas y fallan de maneras distintas.
- La **authorized view** cubre el caso de: un analista al que se le da acceso *solo a la view* y que nunca ve siquiera que la tabla base existe. También le da forma y seudonimiza los datos (`age` → `age_band`), algo que un policy tag no puede hacer. Pero no protege nada si a alguien se le da acceso directo a la tabla base — un error rutinario, ya que un ingeniero nuevo que necesita "lectura sobre el warehouse" la obtiene a nivel de dataset.
- El **policy tag** cubre exactamente ese caso: la columna sigue protegida incluso cuando se otorga acceso a la tabla, incluso a un Owner, incluso a través de una view nueva que alguien cree mañana, e incluso vía `SELECT *`. Pero es binario — bloquear o permitir — sin capacidad de transformar.

Juntos son **defensa en profundidad**: la view es el camino previsto y ergonómico; el tag es la red de contención para cuando ese camino se saltea por accidente. Las brechas reales casi siempre las causa una mala configuración en una capa, que es precisamente el caso que una segunda capa independiente existe para sobrevivir.

**Q6.3** — **Generalización** (una técnica de k-anonimato; la familia más amplia es minimización de datos / desidentificación). Aumenta el alcance utilizable porque una mujer de 34 años en un país chico con una marca temporal exacta de alta suele ser reidentificable a partir de un puñado de cuasi-identificadores, mientras que "35-49, F, Germany, junio 2026" no lo es, siempre que cada bucket contenga suficiente gente. Como la pregunta analítica casi siempre es "¿cómo convierten las *bandas* etarias?" en lugar de "¿qué hizo el cliente 41022?", se descartó precisión con **cero costo analítico y una gran ganancia de privacidad**. Eso cambia la conversación de gobernanza de "¿puede este equipo tener PII?" — que es lenta, conflictiva y a menudo se responde que *no* — a "acá hay una tabla sin PII", que no necesita aprobación. Reducir la sensibilidad es cómo se *aumenta* la cantidad de equipos que pueden usar los datos, y por eso la ingeniería de privacidad habilita la analítica en lugar de obstruirla. (<https://cloud.google.com/sensitive-data-protection/docs/concepts-risk-analysis>)

**Q6.4** — De menos a más privilegiado: `dataViewer` solo sobre `customers_analytics` → `dataViewer` sobre `cdl_warehouse` → `bigquery.admin` sobre el proyecto.

**Emitir:** `roles/bigquery.dataViewer` sobre la **view solamente**. Es suficiente para la necesidad enunciada — el mecanismo de authorized view permite que la view lea la tabla base en nombre del analista sin que el analista tenga acceso alguno a ella — y satisface el mínimo privilegio exactamente.

**Costo operativo de la opción más estricta:** el analista no puede descubrir ni explorar nada más, así que cada pregunta nueva se convierte en un ticket al equipo de datos con una espera de días. Esa fricción es real y es la razón más común por la que las organizaciones otorgan de más. La resolución madura no es aflojar el grant sino eliminar la razón de su existencia: un conjunto bien catalogado de views gobernadas que cubran las preguntas comunes, más un proceso rápido y de baja ceremonia para solicitar una nueva. **El mínimo privilegio fracasa como política cuando el proceso de excepción es más lento que el trabajo.**

**Q6.5** — Este laboratorio es la refutación: la *única* razón por la que `customers_analytics` se le puede entregar a cualquier analista de la empresa sin una revisión de privacidad es que la PII se removió y la columna residual se etiquetó — la gobernanza es lo que hizo *posible* ese acceso amplio. Los datos sin gobernar no son rápidos, simplemente están bloqueados por un control más lento y menos predecible: una revisión legal, una excepción de seguridad o una brecha.

### Ejercicio 7

**Q7.1** — El paso 2 (`Dataset ... was not found in location EU`) prueba que BigQuery acota la *resolución* de datasets por ubicación: una consulta que se ejecuta en la UE ni siquiera puede ver, mucho menos leer, un dataset de US — el acceso entre regiones no es un permiso que pudiera otorgarse, no existe como operación. El paso 3 (`Cannot read and write in different locations`) prueba que el mismo límite abarca varios servicios: un motor de consultas ubicado en US no va a leer un bucket ubicado en la UE. Juntos muestran que la ubicación se impone en el **plano de datos**, no mediante documentos de política ni revisiones.

Un control de ingeniería le gana a una política escrita ante un regulador por tres motivos: no puede olvidarse bajo presión de plazos, se aplica uniformemente a todos los usuarios incluido el CTO y a todo job automatizado, y es *demostrable* — un auditor puede ver la operación fallar en lugar de leer una afirmación de que no se intentaría. Una política que depende de que la gente la recuerde tiene una tasa de violación ilimitada; un control que devuelve un error tiene una tasa de violación de cero. (<https://cloud.google.com/bigquery/docs/locations>)

**Q7.2** — El emparejamiento clásico de requisitos es el registro financiero o médico: los registros **deben** conservarse siete años (obligación de retención/retención legal) y **no deben** conservarse más allá de su propósito lícito (limitación del plazo de conservación del GDPR, Art. 5(1)(e)). Ninguna regla por sí sola cumple.
- **Solo el borrado por ciclo de vida** te deja sin poder probar inmutabilidad: un insider, una credencial comprometida o un script con errores puede borrar registros dentro de la ventana de retención, destruyendo evidencia — exactamente el escenario que las políticas de retención existen para prevenir.
- **Solo la retención** deja los datos acumulándose para siempre más allá de su propósito, lo que es en sí una violación *y* una superficie de brecha ilimitada y creciente: cada registro conservado más allá de su utilidad es puro pasivo sin valor compensatorio.

El patrón que cumple es ambos: una política de retención **bloqueada** que haga imposible el borrado antes del día 2555, y una regla de ciclo de vida que haga automático el borrado en el día 2555. La retención es el piso, el ciclo de vida es el techo, y el cumplimiento vive en la brecha entre ambos. (<https://cloud.google.com/storage/docs/bucket-lock>, <https://cloud.google.com/storage/docs/lifecycle>)

**Q7.3** — Cada salto compra **menor precio de almacenamiento** a cambio de **mayor costo de recuperación, mayor latencia al primer byte y una duración mínima de almacenamiento más larga** (Nearline 30 días, Coldline 90, Archive 365 — si borrás o reescribís antes, igual te facturan el resto). Es seguro para `raw/` porque esos datos se escriben una vez y se leen rara vez — la copia archivada existe para reprocesamiento y auditoría, y pagar más en la lectura infrecuente es obviamente correcto cuando evitás pagar almacenamiento premium todos los meses por datos que nadie toca.

Sería peligroso detrás de un tablero en vivo por ambas razones a la vez: latencia (una consulta interactiva que golpea objetos de clase Archive convierte un tablero de dos segundos en uno inutilizable) e inversión de costos (las tarifas de recuperación sobre datos leídos con frecuencia pueden superar por mucho el almacenamiento ahorrado, así que pagás *más* por una peor experiencia). La regla es que la clase de almacenamiento debe seguir al **patrón de acceso**, y la automatización del ciclo de vida solo es segura donde el patrón de acceso es genuinamente conocido y estable. (<https://cloud.google.com/storage/docs/storage-classes>)

**Q7.4** —
- **Financiero:** el almacenamiento es barato por gigabyte pero nunca gratis, y se acumula — un dataset creciente conservado para siempre es una línea de costo en aumento permanente más sus multiplicadores: backups, replicación entre regiones, egreso en cada migración, sobrecarga de índices y catálogos, y el tiempo de analistas gastado tamizando registros irrelevantes de hace una década. También estás pagando por *mantener* los datos comprensibles: los esquemas derivan, la gente que sabía qué significaba una columna se va, y el costo de interpretar datos viejos sube justo mientras su valor cae.
- **Legal:** todo registro que tenés es un registro que te pueden obligar a producir en un proceso de discovery, que debés incluir en una solicitud de acceso del titular, que debés borrar ante una solicitud válida de supresión (y que debés poder *encontrar* para poder borrar), y sobre el que debés reportar si sufre una brecha. Bajo la limitación del plazo de conservación, retener datos personales más allá de su propósito declarado es en sí mismo la violación. Los datos que borraste lícitamente no pueden sufrir una brecha, ni ser citados judicialmente, ni ser multados. **Los datos retenidos son un pasivo que devenga intereses; el "por las dudas" rara vez justifica el acarreo.**

**Q7.5** —
- **Opción A — Federada / data mesh:** los datos personales de la UE se quedan en regiones de la UE permanentemente. Solo extractos agregados, anonimizados o seudonimizados (conteos, bandas, features de modelos sin camino de reidentificación) cruzan hacia la vista global. **Acepta:** nunca tenés un verdadero registro global único de cliente a nivel de fila; algunos análisis son imposibles o deben correrse por región y combinarse; mayor complejidad de ingeniería, con un pipeline por región y una capa de reconciliación.
- **Opción B — Centralizada con desidentificación en el borde:** los datos personales se tokenizan, hashean o enmascaran antes de salir de la UE, y la clave de reidentificación nunca cruza. El warehouse global contiene un registro vinculable pero no identificable. **Acepta:** una superficie de riesgo legal genuina — el regulador, no vos, decide si tu seudonimización es lo bastante fuerte como para volver no personales a esos datos; la gestión de claves y el mecanismo de transferencia transfronteriza (decisión de adecuación, SCCs) se vuelven el punto único sobre el que descansa toda la arquitectura; y la reidentificación mediante cuasi-identificadores combinados sigue siendo un peligro vivo.

El encuadre honesto para un ejecutivo: esto no es una decisión de tecnología. La opción A es más lenta y más cara pero el argumento de cumplimiento es trivial. La opción B es más capaz pero su legalidad depende de un juicio de valor que un regulador puede revisar después de que ya construiste sobre él. La mayoría de las multinacionales reguladas eligen A para datos personales y B para todo lo demás.

### Ejercicio 8

**Q8.1** —
- **(a) Paquete mensual de ingresos para el directorio — batch.** Se consume una vez al mes, debe ser reconciliable y auditable; la corrección y la reproducibilidad le ganan a la frescura de manera absoluta. El tiempo real acá agregaría costo y un problema de reconciliación por cero valor de decisión.
- **(b) Scoring de fraude con tarjeta en el checkout — streaming.** La ventana de decisión es la duración de un checkout. Un insight que llega después de que la transacción se liquidó tiene valor *negativo*: lo pagaste y no podés actuar sobre él.
- **(c) "Los clientes también compraron" — streaming, pero con un matiz importante.** El *modelo* se entrena en batch durante la noche; las *features* (el carrito de esta sesión) deben ser en tiempo real. Este es el híbrido común — inteligencia en batch, contexto en streaming — y reconocerlo es la respuesta sofisticada.
- **(d) Presentación regulatoria anual — batch.** Cadencia anual, requisito de corrección absoluta, debe ser una instantánea congelada y defendible.
- **(e) Alertas de quiebre de stock — streaming.** El valor decae en minutos: saber a las 09:00 que te quedaste sin stock a las 08:55 te permite redirigir; saberlo mañana describe una pérdida que ya te comiste.

La regla general: **hacé coincidir la latencia de ingesta con la ventana de acción de la decisión, no con el entusiasmo del patrocinador.**

**Q8.2** — Un **dead-letter topic** en la subscription (`--dead-letter-topic` con `--max-delivery-attempts`), para que un mensaje que falla repetidamente al escribirse sea redirigido a un topic de cuarentena en lugar de descartarse — donde puede alertarse, inspeccionarse, corregirse y reproducirse. Combinalo con monitoreo sobre el conteo de dead-letter de la subscription y sobre `oldest_unacked_message_age`. (<https://cloud.google.com/pubsub/docs/handling-failures>)

La pérdida no detectada es peor que una falla ruidosa por la misma razón por la que un backup corrupto es peor que ningún backup: elimina la señal que habría motivado la acción. Con una falla ruidosa, sabés que el número está mal y no actuás sobre él. Con pérdida silenciosa, tu total de ingresos está 3 % bajo, se ve totalmente plausible, se reporta al directorio y nunca se cuestiona — hasta que alguien lo reconcilia contra el procesador de pagos meses después, y ahí *toda* cifra que la plataforma haya publicado queda bajo sospecha. El streaming vuelve este peligro más agudo que el batch: un job batch fallido es un artefacto visible con un dueño y un botón de reintento, mientras que un mensaje descartado no deja artefacto alguno. **En las arquitecturas de streaming, el camino de error debe diseñarse con el mismo cuidado que el camino feliz.**

**Q8.3** — `PARTITION BY DATE(created_at)` segrega físicamente las filas en una partición por día. Una consulta filtrada por `created_at` lee solo las particiones que matchean — **poda de particiones** — así que "los pedidos de ayer" contra tres años de historia escanea aproximadamente 1/1000 de la tabla. **Costo:** la facturación on-demand es por byte escaneado, así que la factura cae en el mismo factor. **Velocidad:** menos I/O y menos workers paralelos necesarios, así que la latencia baja proporcionalmente.

La conexión con Q3.1 es que son la misma idea sobre dos ejes. La disposición columnar poda **horizontalmente** (saltear las columnas que no pediste); el particionado poda **verticalmente** (saltear las filas que no pediste); el clustering ordena dentro de una partición para podar todavía más. Las tres son decisiones de disposición física que aparecen directamente en la factura — por eso en un warehouse serverless, *el modelado de datos es ingeniería de costos*. También podés fijar `require_partition_filter` para que un escaneo completo sin filtro sea un error en lugar de una sorpresa. (<https://cloud.google.com/bigquery/docs/partitioned-tables>)

**Q8.4** — Primero, **del gasto de capital y la planificación de capacidad al gasto operativo basado en consumo**: ningún cluster fue dimensionado, adquirido ni pagado por adelantado; la subscription escala de cinco mensajes a cinco millones sin ninguna acción, y estar ocioso no cuesta nada. La vieja pregunta "¿cuánta capacidad compramos para el pico, y quién la firma?" simplemente desaparece. Segundo, **de las operaciones de infraestructura indiferenciada al valor de negocio**: nadie parchea, monitorea, planifica capacidad ni hace failover del pipeline de streaming. El escaso tiempo de ingeniería del departamento de TI se mueve de mantener el caño funcionando — trabajo que es invisible cuando sale bien y limitante para la carrera cuando falla — a definir qué debería fluir por él. Los servicios gestionados y serverless son la forma en que un programa de transformación reasigna su recurso más restringido, que son las personas capacitadas, no las máquinas.

**Q8.5** — Preguntá: **(1) "¿Qué decisión específica se va a tomar de otra manera si este dato tiene un minuto de antigüedad en lugar de veinticuatro horas, y quién la toma?"** — esto sondea si existe una ventana de acción real, y por lo general revela que el consumidor es un reporte semanal con un humano en el medio, en cuyo caso el tiempo real no cambia nada. **(2) "¿Qué estamos dispuestos a resignar a cambio — costo, o corrección?"** — esto sondea el intercambio honesto. El streaming cuesta más por byte ingerido, y estructuralmente resigna las propiedades de datos que llegan tarde, de reconciliación y de reformulación sencilla que tiene el batch: un job batch puede reejecutarse contra entradas corregidas, mientras que un stream ya emitió su respuesta aguas abajo.

Ambas preguntas sondean la misma dimensión: **el costo total de la latencia** — gasto de infraestructura, complejidad de ingeniería, carga de guardia y las garantías de corrección que cedés. "Todo en tiempo real" es casi siempre un pedido de *una* cosa en tiempo real, más una preferencia estética por el resto.

### Ejercicio 9

**Q9.1** — La tabla de ROAS muestra que la empresa gastaba $107k en un canal que devolvía 57 centavos por dólar y $131k en uno que devolvía $4.12, y *ningún sistema individual del negocio podía distinguir entre ambos* — la estrategia era invisible desde adentro de cualquiera de los dos departamentos. Los datos son intrínsecos y no de apoyo porque las decisiones más consecuentes de la organización son literalmente inaccesibles para ella hasta que datos de partes separadas del negocio se juntan; la transformación tecnológica es solo el medio, y la transformación en sí es el paso de decidir por instinto a decidir por evidencia.

**Q9.2** —
- **Silos** — Ejercicio 4: Finanzas y E-commerce tenían cada uno la mitad del CAC y ninguno podía calcularlo.
- **Calidad de datos** — Ejercicio 5: una sola fila duplicada revirtió el ranking aparente de los canales y habría redirigido presupuesto de un canal 4× a uno 0.27×.
- **Gobernanza, privacidad y cumplimiento** — Ejercicios 6 y 7: la PII necesitaba enmascaramiento antes de que los datos pudieran compartirse ampliamente, y la residencia volvió ilegal un `CREATE TABLE` de una línea a través de una frontera.
- **Datos no estructurados** — Ejercicio 1: la señal de mayor valor del laboratorio (una declaración explícita de churn en la transcripción de una llamada) fue la única que ninguna consulta podía alcanzar sin IA.

Una quinta defendible, visible en el Ejercicio 8: **desajuste de latencia** — los datos que llegan después de que la ventana de decisión se cerró no tienen valor sin importar su calidad. Y subyacente a todas ellas, la barrera que el laboratorio no pudo mostrarte: **cultura y propiedad**, ya que cada una de estas tenía una solución técnica barata y una organizacional cara.

**Q9.3** —
- **"¿Puede un product manager responder una pregunta nueva por sí mismo esta tarde, sin abrir un ticket?"** — evalúa **democratización y autoservicio**. Doce años de historia detrás de una cola que solo tres personas pueden atender es un archivo, no una capacidad de toma de decisiones.
- **"Cuando hay que unir el gasto de Marketing con el comportamiento web, ¿cuánto lleva, y ya se hizo?"** — evalúa **silos**. La profundidad histórica no dice nada sobre la amplitud; un warehouse profundo con los datos de un solo departamento tiene el mismo punto ciego que una planilla.
- **"¿Qué pasa cuando aterriza una fila mala — quién se entera, con qué rapidez, y algo impide que se publique?"** — evalúa **aseguramiento de calidad y confianza**. Doce años de historia sin validar son doce años de error no cuantificado.

Buenos seguimientos: "¿Pueden manejar datos no estructurados — llamadas, documentos, imágenes — siquiera?" (la mayoría de los warehouses on-premises no pueden, lo que excluye a la mayoría de los datos empresariales), "¿Cuál es el costo y el plazo de un pico de 10× en volumen de consultas?" (la capacidad fija es un techo para la curiosidad), y "¿Me pueden mostrar quién accedió a PII de clientes el martes pasado?" (madurez de gobernanza).

**Q9.4** — Pub/Sub → **ingerir** (streaming). Cloud Storage → **almacenar** (crudo / lake). Dataflow → **procesar** (transformación batch y stream, unificada). BigQuery → **analizar** (warehouse serverless). Dataplex Universal Catalog → **gobernar** (catálogo, linaje, calidad, política a través de lakes y warehouses). Looker → **activar** (BI, modelo semántico gobernado, decisiones). Vertex AI → **predecir** (ML/IA sobre los datos curados). Cloud SQL → **transaccionar** (sistema de registro OLTP; la *fuente*, no parte de la cadena analítica).

**Q9.5** — El recurso escaso nunca fue el cómputo — la consulta de todo el laboratorio costó una fracción de centavo, y las mismas consultas correrían sobre mil veces esos datos por unos pocos dólares. Lo escaso fue **el juicio humano**: saber que el CAC solo iba a llevar a error y que hacía falta el ROAS, notar que la fila duplicada se propagaba más allá de la fila que tocaba, decidir que `email` necesitaba un policy tag, saber qué preguntas valían la pena.

La implicancia es el hecho económico central de la era de la nube: la infraestructura dejó de ser el cuello de botella de un programa de datos, así que **la restricción se movió a la alfabetización de datos, la madurez de gobernanza, la propiedad clara y la disposición organizacional a actuar sobre la evidencia** — todos problemas de personas y procesos. Exactamente por esto el examen Cloud Digital Leader está ponderado hacia la transformación y el valor y no hacia la configuración: una organización que compra la plataforma y no cambia cómo decide compró una forma más rápida de producir reportes que nadie usa.

**Q9.6** — **`cdl_warehouse.customers`** — el único artefacto que contiene PII real (email, nombre, edad exacta, ubicación) a escala de 50.000 filas. Todo lo demás es agregado, sintético o ya desidentificado: es el único objeto cuya brecha sería un incidente notificable. Lo que perderías es la capacidad de hacer cualquier cosa que requiera identidad a nivel individual: mensajería saliente personalizada, unir con un CRM o un sistema de soporte por email, cálculo de valor de vida por cliente, y atender solicitudes de acceso o supresión del titular (no podés borrar lo que ya no tenés — lo cual es un beneficio, no una pérdida).

Crucialmente, **no** perderías el análisis que este laboratorio fue construido para producir. `channel_performance` y `customers_analytics` sobreviven intactos, así que el CAC y el ROAS siguen funcionando. Ese es el argumento entero del diseño en capas: el activo de mayor riesgo resulta ser separable del insight de mayor valor, y reconocer cuál es cuál es el contenido práctico de la gobernanza de datos.

</details>

---

### Fuentes de referencia

- Guía del examen Google Cloud Digital Leader — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Qué es un data lake — <https://cloud.google.com/learn/what-is-a-data-lake>
- Qué es un data warehouse — <https://cloud.google.com/learn/what-is-a-data-warehouse>
- Introducción a BigQuery — <https://cloud.google.com/bigquery/docs/introduction>
- Consultar datos externos en Cloud Storage — <https://cloud.google.com/bigquery/docs/external-data-cloud-storage>
- Controlar los costos de BigQuery — <https://cloud.google.com/bigquery/docs/best-practices-costs>
- Precios de BigQuery — <https://cloud.google.com/bigquery/pricing>
- Ubicaciones de datasets de BigQuery — <https://cloud.google.com/bigquery/docs/locations>
- Tablas particionadas — <https://cloud.google.com/bigquery/docs/partitioned-tables>
- Authorized views — <https://cloud.google.com/bigquery/docs/authorized-views>
- Control de acceso a nivel de columna — <https://cloud.google.com/bigquery/docs/column-level-security>
- Lenguaje de control de datos (GRANT / REVOKE) — <https://cloud.google.com/bigquery/docs/reference/standard-sql/data-control-language>
- Vistas `INFORMATION_SCHEMA` de jobs — <https://cloud.google.com/bigquery/docs/information-schema-jobs>
- Datasets públicos de BigQuery — <https://cloud.google.com/bigquery/public-data>
- Introducción a Cloud Storage — <https://cloud.google.com/storage/docs/introduction>
- Clases de almacenamiento — <https://cloud.google.com/storage/docs/storage-classes>
- Gestión del ciclo de vida de objetos — <https://cloud.google.com/storage/docs/lifecycle>
- Políticas de retención y Bucket Lock — <https://cloud.google.com/storage/docs/bucket-lock>
- Uniform bucket-level access — <https://cloud.google.com/storage/docs/uniform-bucket-level-access>
- Descripción general de Pub/Sub — <https://cloud.google.com/pubsub/docs/pubsub-basics>
- BigQuery subscriptions — <https://cloud.google.com/pubsub/docs/bigquery>
- Manejo de fallas de mensajes — <https://cloud.google.com/pubsub/docs/handling-failures>
- Dataplex Universal Catalog — <https://cloud.google.com/dataplex/docs/introduction>
- Descripción general de IAM — <https://cloud.google.com/iam/docs/overview>
- Sensitive Data Protection — análisis de riesgo — <https://cloud.google.com/sensitive-data-protection/docs/concepts-risk-analysis>
- Descripciones generales de Cloud SQL / Spanner / Dataflow — <https://cloud.google.com/sql/docs/introduction> · <https://cloud.google.com/spanner/docs/overview> · <https://cloud.google.com/dataflow/docs/overview>