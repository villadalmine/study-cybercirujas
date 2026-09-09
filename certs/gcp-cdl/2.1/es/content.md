# 2.1 — El rol intrínseco de los datos en la transformación digital de una organización

**Certificación:** Google Cloud Digital Leader (CDL) · Versión del examen 2026-08-12
**Dominio 2:** Explorando la transformación de datos con Google Cloud · **Peso del objetivo:** 6.0
**Perfil de este material:** Principal Platform Architect / Senior SRE. El examen te pide *describir* el rol de los datos; este documento te vuelve capaz de *operarlos*, porque el vocabulario que el examen evalúa (silos, governance, ciclo de vida, decisiones data-driven) solo deja de ser ambiguo una vez que viste los sistemas que lo implementan.

---

## 0. Qué significa "intrínseco", operativamente

El verbo de la guía del examen es *describir*, y la palabra que hace el trabajo es **intrínseco**. No es decoración. Traza una línea dura entre dos posturas organizacionales:

| Postura | Los datos son… | Síntoma en el organigrama | Síntoma en producción |
|---|---|---|---|
| **Extrínseca (pre-transformación)** | Un subproducto de las aplicaciones; residuo | "Reporting" es un equipo aguas abajo de Ingeniería | Cada dashboard es una exportación hecha a mano; nadie es dueño de la frescura |
| **Intrínseca (transformada)** | Un producto de primera clase con dueños, contratos, SLOs y un ciclo de vida | La propiedad del dato reside *en* el equipo del dominio que lo produce | Un dataset tiene un SLO, un error budget, un grafo de lineage y una rotación de guardia |

La postura intrínseca es todo el contenido de este objetivo. La transformación digital no es "mover VMs a la nube"; eso es migración. La transformación es el punto en el que **las decisiones que antes se tomaban por intuición y reportes trimestrales pasan a tomarse a partir de datos medidos, gobernados y oportunos** — y, en la cima de la cadena de valor, a ser tomadas *por* sistemas (ML/AI) en lugar de ser tomadas sobre ellos.

Google enmarca esto como una escalera de valor. Memorizá la escalera; el examen evalúa su ordenamiento:

```
                                       ┌────────────────────────────┐
    value / differentiation            │  5. AI / ML  (predictive,  │
            ▲                          │     generative, agentic)   │
            │                          ├────────────────────────────┤
            │                          │  4. Activation             │
            │                          │     (decisions, products,  │
            │                          │      reverse ETL, sharing) │
            │                          ├────────────────────────────┤
            │                          │  3. Analysis / BI          │
            │                          │     (why did it happen?)   │
            │                          ├────────────────────────────┤
            │                          │  2. Processing / Transform │
            │                          │     (clean, join, model)   │
            │                          ├────────────────────────────┤
            │                          │  1. Storage (durable,      │
            │                          │     governed, queryable)   │
            │                          ├────────────────────────────┤
            └──────────────────────────│  0. Ingestion / Collection │
                                       └────────────────────────────┘
```

**Trampa de examen n.º 1:** No podés saltear escalones. Una organización que pide "AI" mientras su identificador de cliente se escribe de cuatro maneras distintas en cuatro sistemas no está bloqueada por los modelos; está bloqueada en el escalón 1. La formulación canónica de Google es: *no hay estrategia de AI sin estrategia de datos.*

---

## 1. El problema de arquitectura en producción

### 1.1 La topología de silos, enunciada con precisión

Un **data silo** no es "datos en lugares distintos" — la distribución es normal y deseable. Un silo es un dataset cuyo **acceso, esquema y semántica están controlados por un solo equipo como detalle de implementación de su aplicación**, de modo que ningún otro consumidor puede obtenerlo sin una negociación humana.

Los silos son baratos de crear y caros de mantener. Su costo es combinatorio:

```
Point-to-point integrations between N silos:  N(N-1)/2
        N = 6  →  15 pipelines
        N = 12 →  66 pipelines
        N = 20 → 190 pipelines
```

Cada uno de esos pipelines es una copia independiente con su propia latencia, su propia lógica de transformación, su propio modo de falla y — críticamente — su propia **versión de la verdad**. Este es el problema concreto de producción detrás del bullet del examen "data silos".

Modos de falla reales y observables de la topología de silos:

| Modo de falla | Lo que ve el negocio | Lo que ve el SRE |
|---|---|---|
| **Deriva semántica** | Finanzas reporta 41.882 clientes activos; Marketing reporta 44.150 | Dos definiciones de `active` (ventana de 30 días vs 90 días), ninguna escrita |
| **Ambigüedad de frescura** | Una decisión tomada el lunes usó datos del viernes | Sin columna `_ingested_at`, sin SLI de frescura, sin alerta |
| **Carga parcial silenciosa** | Los ingresos "cayeron 12%" de un día para el otro | Falló 1 de 14 shards; el pipeline salió con 0 porque las fallas pasaron por `tee` |
| **Ingesta duplicada** | Conteo de órdenes inflado 1,8× | Entrega at-least-once sin clave de idempotencia |
| **Deriva de esquema** | Aparece una columna de `NULL` en un dashboard | Aguas arriba renombraron `cust_id` → `customer_id`; sin contrato, sin test |
| **Proliferación de copias sin governance** | Un incidente de GDPR/PII por la exportación personal de un analista | Sin policy tags a nivel de columna; `SELECT *` estaba permitido |
| **Costo sin cota** | Factura de consultas 6× el presupuesto en un mes | Tabla sin particionar, `SELECT *`, sin `maximum_bytes_billed` |

**Trampa de examen n.º 2:** Los silos son un problema *organizacional* con una superficie técnica. Consolidar el almacenamiento en un único lake sin consolidar también **propiedad, definiciones y política de acceso** solo produce un silo más grande — a veces llamado *data swamp*.

### 1.2 La contra-arquitectura: datos como producto, con SLOs

El movimiento SRE es dejar de tratar un dataset como un archivo y empezar a tratarlo como un **servicio con un contrato**. Un dataset que importa recibe cuatro SLIs. Abajo está el conjunto estándar, con el SQL exacto de BigQuery usado para medir cada uno (estas son las consultas que vas a cablear al alerting en §3.5 y §5).

| SLI | Pregunta que responde | Medición | SLO típico |
|---|---|---|---|
| **Frescura** | ¿El registro más nuevo es lo bastante reciente como para decidir sobre él? | `TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(_ingested_at), MINUTE)` | p99 ≤ 15 min (streaming) / ≤ 3 h (batch diario) |
| **Completitud** | ¿Llegaron *todas* las filas de origen? | `count(target) / count(source)` por partición | ≥ 99,9 % por partición |
| **Corrección / validez** | ¿Las filas obedecen el contrato? | Tasa de aprobación del data-quality scan de Dataplex | ≥ 99,5 % de las reglas pasan |
| **Disponibilidad** | ¿Los consumidores pueden consultarlo ahora mismo? | Ratio de consultas exitosas desde `INFORMATION_SCHEMA.JOBS` | ≥ 99,9 % |

Aritmética del error budget, resuelta (esto es lo que hace al SLO exigible en lugar de aspiracional):

```
Freshness SLO       : 99.5 % of 5-minute windows within 15 min, over 28 days
Windows in 28 days  : 28 × 24 × 12 = 8,064
Error budget        : 8,064 × 0.005 = 40.32 windows ≈ 3 h 21 min of staleness / 28 d
Fast-burn alert     : > 2 % of the 28-day budget consumed in 1 h  → page
Slow-burn alert     : > 5 % consumed in 6 h                        → ticket
```

**Esta es la definición operativa de "data-driven".** Una organización es data-driven cuando sus datasets de soporte a la decisión llevan error budgets de los que alguien se hace responsable. Todo lo demás es un dashboard.

### 1.3 Arquitectura de referencia en Google Cloud

```
   SOURCES                 INGEST                 STORE / GOVERN            PROCESS            ACTIVATE
 ┌──────────┐      ┌──────────────────────┐   ┌───────────────────────┐  ┌────────────┐   ┌──────────────┐
 │ OLTP DBs │─CDC─▶│ Datastream           │──▶│                       │  │ Dataform   │   │ Looker /     │
 │ (MySQL,  │      │ Database Migration   │   │  Cloud Storage        │  │ (ELT, SQL) │──▶│ Looker Studio│
 │  Oracle, │      │  Service             │   │   RAW zone (Autoclass)│  └────────────┘   ├──────────────┤
 │  Postgres│      ├──────────────────────┤   │         │             │  ┌────────────┐   │ BigQuery ML /│
 ├──────────┤      │ Pub/Sub              │   │         ▼             │  │ Dataflow   │──▶│ Vertex AI    │
 │ Apps,    │─────▶│  └ BigQuery direct   │──▶│  BigQuery             │  │ (Beam,     │   ├──────────────┤
 │ clicks,  │      │    subscription      │   │   raw → curated →     │  │ streaming) │   │ BigQuery     │
 │ IoT      │      ├──────────────────────┤   │   consumption datasets│  └────────────┘   │ sharing      │
 ├──────────┤      │ Storage Transfer Svc │   │         ▲             │  ┌────────────┐   │ (Analytics   │
 │ SaaS     │─────▶│ BQ Data Transfer Svc │──▶│  BigLake / object     │  │ Dataproc   │──▶│  Hub)        │
 │ (Ads, CRM│      ├──────────────────────┤   │  tables (unstructured)│  │ (Spark)    │   ├──────────────┤
 ├──────────┤      │ Transfer Appliance    │  │                       │  └────────────┘   │ Reverse ETL  │
 │ On-prem  │─────▶│ (petabyte, offline)  │──▶│  ══ Dataplex Universal│                   │ → operational│
 │ archives │      └──────────────────────┘   │     Catalog ══        │                   │   systems    │
 └──────────┘                                 │  metadata · lineage · │                   └──────────────┘
                                              │  quality · policy tags│
      ORCHESTRATION: Cloud Composer (Airflow)  └───────────────────────┘
      OBSERVABILITY: Cloud Monitoring / Logging · SLOs · error budgets
      SECURITY:      IAM · VPC Service Controls · CMEK · policy tags · row-level policies · data masking
```

Dos propiedades de este diagrama son el punto central del objetivo:

1. **El almacenamiento y el cómputo están desacoplados.** Los datos se almacenan una vez y son leídos por muchos motores (BigQuery SQL, Spark en Dataproc, Beam en Dataflow, entrenamiento en Vertex AI). Esto es lo que hace que la *misma* copia gobernada sirva a BI y a ML — la cura estructural para los silos.
2. **La governance es un plano horizontal, no una ocurrencia tardía por pipeline.** Dataplex Universal Catalog adjunta metadatos, lineage, calidad y política a los datos dondequiera que vivan, de modo que un consumidor nuevo descubre y confía en un dataset sin contactar a su dueño.

### 1.4 El modelo de zonas (por qué RAW / CURATED / CONSUMPTION)

| Zona | Contenido | Mutabilidad | Almacenamiento típico | Quién la lee |
|---|---|---|---|---|
| **RAW** | Aterrizaje fiel byte a byte del origen, append-only, sin lógica de negocio | Inmutable | GCS (Autoclass) + tablas externas/BigLake | Solo pipelines |
| **CURATED** | Deduplicado, tipado, claves conformadas, PII etiquetada | Reconstruible desde RAW | BigQuery, particionado + clusterizado | Data engineers, ML |
| **CONSUMPTION** | Marts definidos por el negocio, una definición acordada por métrica | Reconstruible desde CURATED | Vistas / vistas materializadas de BigQuery | Analistas, Looker, socios externos |

El invariante: **RAW nunca se edita, y toda zona aguas abajo es reproducible por replay.** Esa única regla es lo que convierte un incidente de datos de un proyecto de arqueología en una re-ejecución. También es la respuesta al bullet de "data quality" del examen: la calidad se aplica en los límites entre zonas, no en el dashboard.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Tipos de datos → servicio de almacenamiento (mapeo crítico para el examen)

| Tipo | Definición | Ejemplos | Servicio de aterrizaje en Google Cloud | Superficie de consulta |
|---|---|---|---|---|
| **Estructurado** | Esquema fijo, tabular, relacional | Transacciones, libro mayor, inventario | Cloud SQL / AlloyDB / Spanner (OLTP), **BigQuery** (OLAP) | SQL |
| **Semiestructurado** | Autodescriptivo, esquema flexible | JSON, Avro, Parquet, XML, logs, documentos de Firestore | Cloud Storage, **BigQuery** (tipo `JSON`), Firestore, Bigtable | SQL / `JSON_VALUE` / API NoSQL |
| **No estructurado** | Sin esquema inherente | Imágenes, video, audio, PDFs, texto libre | **Cloud Storage**, expuesto como **object tables** de BigQuery (BigLake) | Metadatos de objeto + inferencia ML en SQL |

**Trampa de examen n.º 3:** Aproximadamente el 80–90 % de los datos empresariales son no estructurados, e históricamente eran inutilizables para analítica. El punto relevante para la transformación es que las object tables + BigQuery ML/Vertex AI te permiten correr inferencia sobre imágenes y documentos *desde SQL*, llevando el escalón 5 a datos que nunca salieron del escalón 0. Sabé que los datos no estructurados son la mayoría y que Cloud Storage es su hogar.

### 2.2 Data warehouse vs data lake vs lakehouse

| Dimensión | Data warehouse | Data lake | Lakehouse (BigQuery + BigLake + Dataplex) |
|---|---|---|---|
| Esquema | On write | On read | On read, **gobernado** por catálogo |
| Tipos de datos | Estructurados | Todos | Todos |
| Usuarios principales | Analistas | Data engineers, científicos | Ambos |
| Costo por TB almacenado | El más alto | El más bajo | Bajo (GCS) + tier de almacenamiento a largo plazo de BigQuery |
| Governance | Fuerte, madura | Débil por defecto → **riesgo de swamp** | Uniforme vía políticas de Dataplex |
| Rendimiento de consulta | Excelente | Pobre sin curación | Excelente en tablas gestionadas, bueno en BigLake |
| Modo de falla | Rígido; lento para incorporar fuentes nuevas | Inconsultable, sin confianza, huérfano | Deuda de governance si no se alimenta el catálogo |
| Producto de Google | BigQuery | Cloud Storage | BigQuery + BigLake + Dataplex Universal Catalog |

**Trade-off, dicho con honestidad:** el lakehouse no elimina el requisito de disciplina del warehouse, lo *reubica* — de schema-on-write a la aplicación de catálogo-y-contrato. Si desplegás un lake y ningún catálogo, elegiste el swamp.

### 2.3 ETL vs ELT vs federado (zero-copy)

| | ETL | ELT | Federado / zero-copy |
|---|---|---|---|
| Dónde corre la transformación | En una capa intermedia (Dataflow, Dataproc) | En el warehouse (BigQuery SQL, Dataform) | En ningún lado — la consulta va al origen |
| ¿Se conservan los datos crudos? | Con frecuencia no | **Sí** (replayable) | N/A |
| Driver de costo | Cómputo del pipeline | Slots de consulta / bytes escaneados | Carga del sistema de origen |
| Radio de impacto de un cambio de esquema | Se rompe el pipeline | Solo se rompen los modelos aguas abajo | Se rompe la consulta |
| Mejor para | Redacción pesada de PII antes de aterrizar; lógica compleja no-SQL | Por defecto en BigQuery: almacenamiento barato, cómputo elástico | Joins ad-hoc, evitar una copia, tablas de dimensión de bajo volumen |
| Productos de Google | Dataflow, Dataproc, Data Fusion | Dataform, consultas programadas de BigQuery, dbt | Consultas federadas de BigQuery, BigLake, tablas externas |
| Riesgo principal | Fidelidad perdida — no podés re-derivar lo que no guardaste | Descontrol del costo del warehouse; SQL sin gestionar | Degradación del OLTP de origen por consultas analíticas |

**Recomendación por defecto en Google Cloud: ELT**, con ETL reservado para la redacción previa al aterrizaje de campos regulados. Razón: el almacenamiento es el recurso barato y la replayability es la propiedad cara de perder.

### 2.4 Batch vs micro-batch vs streaming

| | Batch | Micro-batch | Streaming |
|---|---|---|---|
| Latencia | Horas–días | 1–15 min | Sub-segundo – segundos |
| Costo por evento | El más bajo | Bajo | El más alto (workers siempre encendidos) |
| Modelo de corrección | Reprocesamiento completo (fácil) | Reprocesar la ventana | Datos tardíos / watermarks / ventanas (difícil) |
| Exactly-once | Trivial (sobrescritura idempotente) | Alcanzable | Requiere claves de dedup + exactly-once de Dataflow |
| Productos | BQ Data Transfer, Storage Transfer, Composer + `bq load` | Dataflow programado, Dataform de 5 min | Pub/Sub → BigQuery subscription, Dataflow streaming |
| Elegilo cuando | La cadencia de decisión es diaria (cierre financiero, modelo mensual de churn) | Dashboards de operaciones | Fraude, personalización, alarmas de IoT, pricing dinámico |

**Trampa de examen n.º 4:** Streaming no es "mejor". Elegí la latencia más barata que cambie una decisión. Si nadie actúa dentro de una hora, la ingesta sub-segundo no compra nada y cuesta de forma continua. El examen premia el razonamiento por *valor de negocio* acá, no el razonamiento por throughput.

### 2.5 Plataforma centralizada vs data mesh

| | Equipo de plataforma centralizado | Data mesh (productos de datos con dueño de dominio) |
|---|---|---|
| Propiedad | Un equipo de plataforma es dueño de todos los pipelines | El dominio productor es dueño de su producto de datos |
| Cuello de botella | El backlog del equipo de plataforma | Consistencia de governance entre dominios |
| Tiempo para incorporar una fuente | Semanas (cola) | Días (autoservicio) |
| Consistencia de definiciones | Alta por construcción | Requiere **federated computational governance** |
| Prerrequisito | Cantidad pequeña de dominios | Una plataforma de autoservicio real + estándares globales aplicados |
| Implementación en GCP | Un proyecto, un estate de BigQuery | Proyectos por dominio; los lakes de Dataplex los abarcan; BigQuery sharing publica los productos |

**Trade-off honesto:** un mesh sin camino pavimentado es silos con mejor branding. Adoptá mesh solo cuando la plataforma pueda entregarle a un equipo de dominio un producto de datos templatizado, gobernado y observable en un único `terraform apply` — que es precisamente lo que construye §3.

### 2.6 Tabla de decisión de rutas de ingesta

| Fuente | Volumen / latencia | Servicio | Nota |
|---|---|---|---|
| RDBMS operacional, se necesita casi tiempo real | GB/día, segundos | **Datastream** (CDC) → BigQuery | Serverless, sin agentes en el origen |
| Migración de DB de una sola vez | Cualquiera | **Database Migration Service** | Cutover con downtime mínimo |
| Eventos, telemetría, clickstream | Millones/s | **Pub/Sub** → BigQuery subscription o Dataflow | Global, at-least-once |
| SaaS (Google Ads, YouTube, S3, Redshift…) | Programado | **BigQuery Data Transfer Service** | Conectores gestionados |
| Datos de objeto on-prem/otra nube, online | TB, horas | **Storage Transfer Service** | Incremental, programado |
| Archivos on-prem, sin ancho de banda | 100 TB–PB | **Transfer Appliance** | Envío físico |
| Pipelines visuales, low-code | Cualquiera | **Cloud Data Fusion** | Basado en CDAP, para no programadores |

### 2.7 Controles de governance (no son intercambiables)

| Control | Granularidad | Qué aplica | Superficie de producto |
|---|---|---|---|
| IAM | Proyecto / dataset / tabla | Quién puede leer, en absoluto | Roles de IAM, `google_bigquery_dataset_iam_member` |
| **Policy tags** (taxonomía) | **Columna** | Quién puede leer `email`, `ssn` | Seguridad a nivel de columna de BigQuery |
| **Data masking** | Valor de columna | *Qué* ven (hash / null / default) | Data policies de BigQuery |
| **Row-level access policy** | Fila | Qué subconjunto (p. ej. la propia región) | `CREATE ROW ACCESS POLICY` |
| **VPC Service Controls** | Perímetro | Exfiltración fuera del perímetro | Access Context Manager |
| **CMEK** | Clave | Control criptográfico / revocación de claves | Cloud KMS |
| **Residencia de datos** | Ubicación | Dónde pueden vivir los bytes | Ubicación del dataset/bucket, Org Policy |

**Trampa de examen n.º 5:** La governance no es solo restricción. Su valor transformacional es *habilitar* el acceso — un dataset gobernado puede abrirse a toda la compañía porque las columnas sensibles están demostrablemente protegidas. Los datos sin governance deben quedar cerrados a unas pocas personas, que es precisamente lo que vuelve a crear silos.

---

## 3. Infraestructura como código — completa, sin abreviar

Los siguientes cuatro artefactos levantan de punta a punta un producto de datos de un dominio gobernado: bucket de aterrizaje, tres zonas de BigQuery, ingesta en streaming con un contrato de esquema, un lake de Dataplex con escaneo de calidad, protección de PII a nivel de columna, un share zero-copy y un SLO de frescura con alerting.

### 3.1 `terraform/main.tf` — fundación de la plataforma

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.20"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "Project hosting the orders data product."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "bq_location" {
  type        = string
  default     = "US"
  description = "BigQuery multi-region. Must contain var.region for co-location."
}

variable "domain" {
  type        = string
  default     = "orders"
  description = "Owning business domain; used as the data-product name."
}

locals {
  labels = {
    domain          = var.domain
    data_product    = "${var.domain}-events"
    owner           = "data-platform"
    cost_center     = "eng-1042"
    data_class      = "internal"
    managed_by      = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Required APIs
# ---------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "bigquerydatapolicy.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "dataplex.googleapis.com",
    "datacatalog.googleapis.com",
    "datalineage.googleapis.com",
    "dataform.googleapis.com",
    "analyticshub.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# RAW zone: object storage, immutable landing
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-${var.domain}-raw"
  location                    = var.bq_location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  # Storage cost follows access pattern automatically; no lifecycle guesswork.
  autoclass {
    enabled                = true
    terminal_storage_class = "ARCHIVE"
  }

  versioning {
    enabled = true
  }

  # Recover from an accidental delete without restoring from backup.
  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# BigQuery zones
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "raw" {
  dataset_id                      = "${var.domain}_raw"
  friendly_name                   = "${var.domain} — RAW (append-only)"
  description                     = "Byte-faithful landing. Never edited. Source of replay."
  location                        = var.bq_location
  default_partition_expiration_ms = 7776000000 # 90 days
  labels                          = local.labels
  depends_on                      = [google_project_service.apis]
}

resource "google_bigquery_dataset" "curated" {
  dataset_id    = "${var.domain}_curated"
  friendly_name = "${var.domain} — CURATED"
  description   = "Deduplicated, typed, conformed keys, PII tagged. Rebuildable from RAW."
  location      = var.bq_location
  labels        = local.labels
  depends_on    = [google_project_service.apis]
}

resource "google_bigquery_dataset" "consumption" {
  dataset_id    = "${var.domain}_consumption"
  friendly_name = "${var.domain} — CONSUMPTION"
  description   = "Business-agreed metrics. One definition per metric. Read by Looker and partners."
  location      = var.bq_location
  labels        = local.labels
  depends_on    = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Column-level security: taxonomy + policy tags
# ---------------------------------------------------------------------------
resource "google_data_catalog_taxonomy" "pii" {
  region                 = var.region
  display_name           = "pii-classification-${var.domain}"
  description            = "Sensitivity classes applied as BigQuery column policy tags."
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
  depends_on             = [google_project_service.apis]
}

resource "google_data_catalog_policy_tag" "pii_high" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "pii-high"
  description  = "Direct identifiers: email, phone, government ID. Masked by default."
}

resource "google_data_catalog_policy_tag" "pii_low" {
  taxonomy          = google_data_catalog_taxonomy.pii.id
  parent_policy_tag = google_data_catalog_policy_tag.pii_high.id
  display_name      = "pii-low"
  description       = "Quasi-identifiers: postal code, coarse geo."
}

# Masking rule: analysts see a SHA-256 hash, not the raw value.
resource "google_bigquery_datapolicy_data_policy" "email_hash" {
  location         = var.region
  data_policy_id   = "${var.domain}_email_sha256"
  policy_tag       = google_data_catalog_policy_tag.pii_high.name
  data_policy_type = "DATA_MASKING_POLICY"

  data_masking_policy {
    predefined_expression = "SHA256"
  }
  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# CURATED table: partitioned, clustered, contract-carrying
# ---------------------------------------------------------------------------
resource "google_bigquery_table" "orders" {
  dataset_id          = google_bigquery_dataset.curated.dataset_id
  table_id            = "orders"
  deletion_protection = true
  description         = <<-EOT
    DATA PRODUCT: orders.curated.orders
    Owner        : orders-domain@example.com
    SLO          : freshness p99 <= 15 min | completeness >= 99.9% per partition
    Grain        : one row per order_id per event_ts (latest wins in consumption view)
    Replay       : rebuildable from orders_raw.orders_stream
  EOT
  labels              = local.labels

  time_partitioning {
    type                     = "DAY"
    field                    = "event_ts"
    require_partition_filter = true # hard stop against full-table scans
  }

  clustering = ["country_code", "channel"]

  schema = jsonencode([
    {
      name        = "order_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Idempotency key. Unique per order across all sources."
    },
    {
      name        = "customer_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Conformed customer key (golden record)."
    },
    {
      name         = "customer_email"
      type         = "STRING"
      mode         = "NULLABLE"
      description  = "Direct identifier. Masked for non-privileged readers."
      policyTags   = { names = [google_data_catalog_policy_tag.pii_high.name] }
    },
    {
      name        = "country_code"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "ISO 3166-1 alpha-2, uppercase."
    },
    {
      name        = "channel"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "One of: WEB, MOBILE, STORE, PARTNER."
    },
    {
      name        = "gross_amount"
      type        = "NUMERIC"
      mode        = "REQUIRED"
      description = "Order gross value, minor-unit-safe NUMERIC. Never FLOAT64 for money."
    },
    {
      name        = "currency"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "ISO 4217."
    },
    {
      name        = "event_ts"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Business event time (source of truth for partitioning)."
    },
    {
      name        = "ingested_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Platform arrival time. Freshness SLI is computed from this."
    },
    {
      name        = "source_system"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Provenance. Required for lineage and incident scoping."
    }
  ])
}

# ---------------------------------------------------------------------------
# Row-level access: EU analysts see EU rows only
# ---------------------------------------------------------------------------
resource "google_bigquery_job" "row_policy_eu" {
  job_id = "rowpolicy-eu-${var.domain}-001"
  query {
    query = <<-SQL
      CREATE OR REPLACE ROW ACCESS POLICY eu_only
      ON `${var.project_id}.${google_bigquery_dataset.curated.dataset_id}.orders`
      GRANT TO ("group:analysts-eu@example.com")
      FILTER USING (country_code IN ("ES","FR","DE","IT","PT","NL","IE"));
    SQL
    use_legacy_sql = false
  }
  depends_on = [google_bigquery_table.orders]
}
```

### 3.2 `terraform/ingest.tf` — contrato de streaming (Pub/Sub → BigQuery, sin código de pipeline)

```hcl
# The schema IS the contract. A producer that violates it is rejected at publish
# time, not discovered three dashboards downstream.
resource "google_pubsub_schema" "order_event" {
  name       = "${var.domain}-event-v1"
  type       = "AVRO"
  definition = jsonencode({
    type      = "record"
    name      = "OrderEvent"
    namespace = "com.example.orders"
    fields = [
      { name = "order_id",       type = "string" },
      { name = "customer_id",    type = "string" },
      { name = "customer_email", type = ["null", "string"], default = null },
      { name = "country_code",   type = "string" },
      { name = "channel",        type = "string" },
      { name = "gross_amount",   type = "string" },
      { name = "currency",       type = "string" },
      { name = "event_ts",       type = { type = "long", logicalType = "timestamp-micros" } },
      { name = "source_system",  type = "string" }
    ]
  })
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "orders" {
  name                       = "${var.domain}-events"
  message_retention_duration = "604800s" # 7 days — the replay window
  labels                     = local.labels

  schema_settings {
    schema   = google_pubsub_schema.order_event.id
    encoding = "JSON"
  }
}

# Dead-letter topic: messages that cannot be written are quarantined, not lost.
resource "google_pubsub_topic" "orders_dlq" {
  name                       = "${var.domain}-events-dlq"
  message_retention_duration = "2592000s" # 30 days
  labels                     = local.labels
}

resource "google_pubsub_subscription" "orders_dlq_pull" {
  name  = "${var.domain}-events-dlq-pull"
  topic = google_pubsub_topic.orders_dlq.id
  ack_deadline_seconds = 60
  labels = local.labels
}

resource "google_bigquery_table" "orders_stream" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "orders_stream"
  deletion_protection = true
  description         = "RAW landing of ${google_pubsub_topic.orders.name}. Append-only."
  labels              = local.labels

  time_partitioning {
    type                     = "DAY"
    field                    = "event_ts"
    require_partition_filter = false # RAW is scanned by replay jobs
  }

  schema = jsonencode([
    { name = "order_id",       type = "STRING",    mode = "REQUIRED" },
    { name = "customer_id",    type = "STRING",    mode = "REQUIRED" },
    { name = "customer_email", type = "STRING",    mode = "NULLABLE" },
    { name = "country_code",   type = "STRING",    mode = "REQUIRED" },
    { name = "channel",        type = "STRING",    mode = "REQUIRED" },
    { name = "gross_amount",   type = "STRING",    mode = "REQUIRED" },
    { name = "currency",       type = "STRING",    mode = "REQUIRED" },
    { name = "event_ts",       type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "source_system",  type = "STRING",    mode = "REQUIRED" }
  ])
}

# Pub/Sub writes straight into BigQuery. No Dataflow job to run, patch or pay for.
resource "google_pubsub_subscription" "orders_to_bq" {
  name  = "${var.domain}-events-to-bq"
  topic = google_pubsub_topic.orders.id
  labels = local.labels

  bigquery_config {
    table            = "${var.project_id}.${google_bigquery_dataset.raw.dataset_id}.${google_bigquery_table.orders_stream.table_id}"
    use_topic_schema = true
    write_metadata   = false
    drop_unknown_fields = false
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.orders_dlq.id
    max_delivery_attempts = 10
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [
    google_bigquery_table.orders_stream,
    google_project_iam_member.pubsub_bq_writer,
  ]
}

data "google_project" "this" {}

# The Pub/Sub service agent must be able to write to the target table.
resource "google_project_iam_member" "pubsub_bq_writer" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "pubsub_bq_metadata" {
  project = var.project_id
  role    = "roles/bigquery.metadataViewer"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
```

### 3.3 `terraform/govern.tf` — lake de Dataplex, zonas, assets, escaneo de calidad, sharing

```hcl
resource "google_dataplex_lake" "domain" {
  name         = "${var.domain}-lake"
  location     = var.region
  display_name = "${title(var.domain)} domain lake"
  description  = "Unified metadata plane over the ${var.domain} data product."
  labels       = local.labels
  depends_on   = [google_project_service.apis]
}

resource "google_dataplex_zone" "raw" {
  name         = "raw-zone"
  location     = var.region
  lake         = google_dataplex_lake.domain.name
  type         = "RAW"
  display_name = "RAW"
  labels       = local.labels

  discovery_spec {
    enabled  = true
    schedule = "0 * * * *" # hourly metadata discovery
  }

  resource_spec {
    location_type = "MULTI_REGION"
  }
}

resource "google_dataplex_zone" "curated" {
  name         = "curated-zone"
  location     = var.region
  lake         = google_dataplex_lake.domain.name
  type         = "CURATED"
  display_name = "CURATED"
  labels       = local.labels

  discovery_spec {
    enabled  = true
    schedule = "0 */4 * * *"
  }

  resource_spec {
    location_type = "MULTI_REGION"
  }
}

resource "google_dataplex_asset" "raw_bucket" {
  name          = "raw-bucket"
  location      = var.region
  lake          = google_dataplex_lake.domain.name
  dataplex_zone = google_dataplex_zone.raw.name
  labels        = local.labels

  discovery_spec {
    enabled = true
  }

  resource_spec {
    name = "projects/${var.project_id}/buckets/${google_storage_bucket.raw.name}"
    type = "STORAGE_BUCKET"
  }
}

resource "google_dataplex_asset" "curated_dataset" {
  name          = "curated-dataset"
  location      = var.region
  lake          = google_dataplex_lake.domain.name
  dataplex_zone = google_dataplex_zone.curated.name
  labels        = local.labels

  discovery_spec {
    enabled = true
  }

  resource_spec {
    name = "projects/${var.project_id}/datasets/${google_bigquery_dataset.curated.dataset_id}"
    type = "BIGQUERY_DATASET"
  }
}

# ---------------------------------------------------------------------------
# Automatic data quality: the correctness SLI, as code
# ---------------------------------------------------------------------------
resource "google_dataplex_datascan" "orders_dq" {
  location     = var.region
  data_scan_id = "${var.domain}-orders-dq"
  display_name = "orders curated — data quality"
  description  = "Enforces the published contract of orders.curated.orders."
  labels       = local.labels

  data {
    resource = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.curated.dataset_id}/tables/orders"
  }

  execution_spec {
    trigger {
      schedule {
        cron = "0 */2 * * *"
      }
    }
    field = "event_ts" # incremental: only scan new partitions
  }

  data_quality_spec {
    sampling_percent = 100
    row_filter       = "event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)"

    post_scan_actions {
      bigquery_export {
        results_table = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.curated.dataset_id}/tables/dq_results"
      }
    }

    rules {
      column      = "order_id"
      dimension   = "COMPLETENESS"
      threshold   = 1.0
      description = "order_id must never be null; it is the idempotency key."
      non_null_expectation {}
    }

    rules {
      column      = "order_id"
      dimension   = "UNIQUENESS"
      threshold   = 1.0
      description = "Duplicate order_id in a partition means at-least-once leaked through."
      uniqueness_expectation {}
    }

    rules {
      column      = "country_code"
      dimension   = "VALIDITY"
      threshold   = 0.999
      description = "ISO 3166-1 alpha-2, uppercase."
      regex_expectation {
        regex = "^[A-Z]{2}$"
      }
    }

    rules {
      column      = "channel"
      dimension   = "VALIDITY"
      threshold   = 1.0
      description = "Closed enumeration agreed with the orders domain."
      set_expectation {
        values = ["WEB", "MOBILE", "STORE", "PARTNER"]
      }
    }

    rules {
      column      = "gross_amount"
      dimension   = "VALIDITY"
      threshold   = 0.9999
      description = "Non-negative and within the fraud-plausible ceiling."
      range_expectation {
        min_value          = "0"
        max_value          = "1000000"
        strict_min_enabled = false
        strict_max_enabled = false
      }
    }

    rules {
      column      = "currency"
      dimension   = "VALIDITY"
      threshold   = 1.0
      description = "Supported settlement currencies only."
      set_expectation {
        values = ["EUR", "USD", "GBP", "ARS", "BRL"]
      }
    }

    rules {
      dimension   = "FRESHNESS"
      threshold   = 1.0
      description = "Freshness SLI as a hard gate: newest ingest under 15 minutes old."
      table_condition_expectation {
        sql_expression = "TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), MINUTE) <= 15"
      }
    }

    rules {
      dimension   = "VOLUME"
      threshold   = 1.0
      description = "Volume floor: a silent partial load looks like a quiet day."
      table_condition_expectation {
        sql_expression = "COUNT(*) > 1000"
      }
    }

    rules {
      column      = "customer_id"
      dimension   = "CONSISTENCY"
      threshold   = 0.995
      description = "Referential integrity against the conformed customer dimension."
      sql_assertion {
        sql_statement = <<-SQL
          SELECT o.customer_id
          FROM `${var.project_id}.${google_bigquery_dataset.curated.dataset_id}.orders` o
          LEFT JOIN `${var.project_id}.${google_bigquery_dataset.curated.dataset_id}.customers` c
            USING (customer_id)
          WHERE c.customer_id IS NULL
        SQL
      }
    }
  }

  depends_on = [google_bigquery_table.orders]
}

# ---------------------------------------------------------------------------
# Zero-copy sharing (BigQuery sharing / Analytics Hub): the activation rung
# ---------------------------------------------------------------------------
resource "google_bigquery_analytics_hub_data_exchange" "partners" {
  location         = var.bq_location
  data_exchange_id = "${var.domain}_partner_exchange"
  display_name     = "${title(var.domain)} partner exchange"
  description      = "Governed, zero-copy distribution of the consumption zone to partners."
  primary_contact  = "data-platform@example.com"
  documentation    = "https://cloud.google.com/bigquery/docs/analytics-hub-introduction"
  depends_on       = [google_project_service.apis]
}

resource "google_bigquery_analytics_hub_listing" "orders_daily" {
  location         = var.bq_location
  data_exchange_id = google_bigquery_analytics_hub_data_exchange.partners.data_exchange_id
  listing_id       = "${var.domain}_daily_agg"
  display_name     = "${title(var.domain)} daily aggregates"
  description      = "Country/channel daily aggregates. No PII. Refreshed hourly."
  primary_contact  = "data-platform@example.com"
  categories       = ["commerce"]

  bigquery_dataset {
    dataset = google_bigquery_dataset.consumption.id
  }
}
```

### 3.4 `dq/orders_dq.yaml` — el mismo contrato, portable (para `gcloud dataplex datascans`)

```yaml
# Applied with:
#   gcloud dataplex datascans create data-quality orders-dq \
#     --location=us-central1 \
#     --data-source-resource="//bigquery.googleapis.com/projects/PROJECT/datasets/orders_curated/tables/orders" \
#     --data-quality-spec-file=dq/orders_dq.yaml
samplingPercent: 100
rowFilter: "event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)"

postScanActions:
  bigqueryExport:
    resultsTable: "//bigquery.googleapis.com/projects/PROJECT/datasets/orders_curated/tables/dq_results"

rules:
  - column: order_id
    dimension: COMPLETENESS
    threshold: 1.0
    description: "Idempotency key must exist."
    nonNullExpectation: {}

  - column: order_id
    dimension: UNIQUENESS
    threshold: 1.0
    description: "At-least-once delivery must not survive into CURATED."
    uniquenessExpectation: {}

  - column: country_code
    dimension: VALIDITY
    threshold: 0.999
    regexExpectation:
      regex: "^[A-Z]{2}$"

  - column: channel
    dimension: VALIDITY
    threshold: 1.0
    setExpectation:
      values: ["WEB", "MOBILE", "STORE", "PARTNER"]

  - column: gross_amount
    dimension: VALIDITY
    threshold: 0.9999
    rangeExpectation:
      minValue: "0"
      maxValue: "1000000"
      strictMinEnabled: false
      strictMaxEnabled: false

  - dimension: FRESHNESS
    threshold: 1.0
    description: "Freshness SLI gate."
    tableConditionExpectation:
      sqlExpression: "TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), MINUTE) <= 15"

  - dimension: VOLUME
    threshold: 1.0
    description: "Volume floor catches silent partial loads."
    tableConditionExpectation:
      sqlExpression: "COUNT(*) > 1000"

  - column: gross_amount
    dimension: ACCURACY
    threshold: 1.0
    description: "Daily revenue must not deviate more than 40% from the trailing 7-day mean."
    sqlAssertion:
      sqlStatement: |
        WITH daily AS (
          SELECT DATE(event_ts) AS d, SUM(gross_amount) AS rev
          FROM `PROJECT.orders_curated.orders`
          WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 8 DAY)
          GROUP BY d
        ),
        stats AS (
          SELECT AVG(rev) AS mean_rev
          FROM daily
          WHERE d < CURRENT_DATE()
        )
        SELECT d, rev
        FROM daily, stats
        WHERE d = CURRENT_DATE()
          AND ABS(rev - mean_rev) / NULLIF(mean_rev, 0) > 0.40
```

### 3.5 `k8s/freshness-slo.yaml` — exportador del SLI de frescura en GKE (conjunto completo de manifiestos)

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: data-slo
  labels:
    app.kubernetes.io/part-of: data-platform
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: freshness-probe
  namespace: data-slo
  annotations:
    # Workload Identity: no keys on disk, ever.
    iam.gke.io/gcp-service-account: freshness-probe@PROJECT_ID.iam.gserviceaccount.com
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: freshness-queries
  namespace: data-slo
data:
  probe.sh: |
    #!/usr/bin/env bash
    set -Eeuo pipefail
    # Never pipe the query through tee: a pipeline hides a non-zero exit status.
    PROJECT="${PROJECT_ID:?PROJECT_ID must be set}"

    read -r -d '' SQL <<'EOSQL' || true
    SELECT
      'orders.curated.orders' AS dataset,
      TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), SECOND) AS staleness_seconds,
      COUNT(*) AS rows_last_24h
    FROM `orders_curated.orders`
    WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
    EOSQL

    RESULT="$(bq --project_id="${PROJECT}" --format=json --headless \
                 query --nouse_legacy_sql --maximum_bytes_billed=10000000000 "${SQL}")"

    STALENESS="$(echo "${RESULT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["staleness_seconds"])')"
    ROWS="$(echo "${RESULT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["rows_last_24h"])')"

    # Structured log line; a log-based metric turns this into an SLI time series.
    python3 - "$STALENESS" "$ROWS" <<'EOPY'
    import json, sys
    print(json.dumps({
        "severity": "INFO" if int(sys.argv[1]) <= 900 else "ERROR",
        "message": "data_freshness_probe",
        "dataset": "orders.curated.orders",
        "staleness_seconds": int(sys.argv[1]),
        "rows_last_24h": int(sys.argv[2]),
        "slo_target_seconds": 900,
        "slo_met": int(sys.argv[1]) <= 900,
    }))
    EOPY

    if [ "${STALENESS}" -gt 900 ]; then
      echo "FRESHNESS SLO VIOLATION: ${STALENESS}s > 900s" >&2
      exit 1
    fi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: orders-freshness-probe
  namespace: data-slo
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 120
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 240
      template:
        metadata:
          labels:
            app: orders-freshness-probe
        spec:
          serviceAccountName: freshness-probe
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: probe
              image: gcr.io/google.com/cloudsdktool/google-cloud-cli:slim
              command: ["/bin/bash", "/scripts/probe.sh"]
              env:
                - name: PROJECT_ID
                  value: "PROJECT_ID"
                - name: CLOUDSDK_CORE_DISABLE_PROMPTS
                  value: "1"
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
              resources:
                requests:
                  cpu: "100m"
                  memory: "256Mi"
                limits:
                  cpu: "500m"
                  memory: "512Mi"
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
          volumes:
            - name: scripts
              configMap:
                name: freshness-queries
                defaultMode: 0555
```

Y la mitad de alerting, en Terraform:

```hcl
resource "google_logging_metric" "freshness_staleness" {
  name        = "data_freshness_staleness_seconds"
  description = "Staleness of governed datasets, emitted by the GKE freshness probe."
  filter      = <<-EOT
    resource.type="k8s_container"
    jsonPayload.message="data_freshness_probe"
  EOT

  metric_descriptor {
    metric_kind = "GAUGE"
    value_type  = "DISTRIBUTION"
    unit        = "s"
    labels {
      key         = "dataset"
      value_type  = "STRING"
      description = "Fully qualified dataset name."
    }
  }

  value_extractor = "EXTRACT(jsonPayload.staleness_seconds)"

  label_extractors = {
    "dataset" = "EXTRACT(jsonPayload.dataset)"
  }

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 24
      growth_factor      = 1.6
      scale              = 10
    }
  }
}

resource "google_monitoring_alert_policy" "freshness_breach" {
  display_name = "Data freshness SLO breach — orders.curated.orders"
  combiner     = "OR"
  severity     = "CRITICAL"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      ## Freshness SLO breached

      `orders.curated.orders` is older than the 15-minute objective.

      **Triage order (see runbook §5):**
      1. `gcloud pubsub subscriptions describe orders-events-to-bq` — is the subscription attached?
      2. Check `subscription/oldest_unacked_message_age` — backlog or no traffic?
      3. Check the DLQ depth — schema rejections?
      4. `bq ls -j --max_results=20 PROJECT` — did the transform job fail?

      Escalation: orders-domain@example.com, then data-platform on-call.
    EOT
  }

  conditions {
    display_name = "staleness p95 > 900s for 10 min"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/data_freshness_staleness_seconds\" AND resource.type=\"k8s_container\""
      comparison      = "COMPARISON_GT"
      threshold_value = 900
      duration        = "600s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.dataset"]
      }
    }
  }

  alert_strategy {
    auto_close = "3600s"
  }

  depends_on = [google_logging_metric.freshness_staleness]
}
```

---

## 4. Sesiones de CLI con salida real de terminal

### 4.1 Aplicar y verificar el estate

```bash
$ gcloud config set project acme-data-prod
Updated property [core/project].

$ terraform init -upgrade
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/google versions matching "~> 6.20"...
- Installing hashicorp/google v6.24.0...
Terraform has been successfully initialized!

$ terraform apply -auto-approve
...
Apply complete! Resources: 31 added, 0 changed, 0 destroyed.

$ bq ls --project_id=acme-data-prod
        datasetId
 ---------------------
  orders_raw
  orders_curated
  orders_consumption

$ bq show --format=prettyjson acme-data-prod:orders_curated.orders | \
    jq '{rows: .numRows, bytes: .numBytes, partition: .timePartitioning, cluster: .clustering}'
{
  "rows": "48213907",
  "bytes": "9127338112",
  "partition": {
    "field": "event_ts",
    "requirePartitionFilter": true,
    "type": "DAY"
  },
  "cluster": {
    "fields": [
      "country_code",
      "channel"
    ]
  }
}
```

### 4.2 El filtro de partición está haciendo su trabajo (guardrail de costo)

```bash
$ bq query --nouse_legacy_sql --dry_run \
  'SELECT COUNT(*) FROM `acme-data-prod.orders_curated.orders`'
BigQuery error in query operation: Cannot query over table
'acme-data-prod.orders_curated.orders' without a filter over column(s) 'event_ts'
that can be used for partition elimination

$ bq query --nouse_legacy_sql --dry_run \
  'SELECT COUNT(*) FROM `acme-data-prod.orders_curated.orders`
   WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)'
Query successfully validated. Assuming the tables are not modified,
running this query will process 42317184 bytes of data.
```

42 MB en lugar de 9,1 GB — una reducción de 215× a partir de una sola decisión de esquema. Esta es la diferencia entre "no podemos permitirnos dejar que todos consulten" (un fabricante de silos) y "el autoservicio es seguro".

### 4.3 Frescura y completitud, medidas

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingested_at), SECOND) AS staleness_s,
  COUNT(*)                                                      AS rows_24h,
  COUNT(DISTINCT order_id)                                      AS distinct_orders,
  COUNT(*) - COUNT(DISTINCT order_id)                           AS dupes
FROM `acme-data-prod.orders_curated.orders`
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)'
+-------------+----------+-----------------+-------+
| staleness_s | rows_24h | distinct_orders | dupes |
+-------------+----------+-----------------+-------+
|         112 |   418337 |          418337 |     0 |
+-------------+----------+-----------------+-------+
```

Conteos de filas por partición, directo desde los metadatos (gratis, sin escaneo):

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT partition_id, total_rows, total_logical_bytes, last_modified_time
FROM `acme-data-prod.orders_curated.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = "orders"
ORDER BY partition_id DESC
LIMIT 5'
+--------------+------------+---------------------+---------------------------+
| partition_id | total_rows | total_logical_bytes |    last_modified_time     |
+--------------+------------+---------------------+---------------------------+
| 20260906     |     318204 |            60219904 | 2026-09-06 14:12:41.883 UTC |
| 20260905     |     421889 |            79881216 | 2026-09-06 00:04:11.207 UTC |
| 20260904     |     417332 |            79036416 | 2026-09-05 00:03:58.912 UTC |
| 20260903     |      98104 |            18579456 | 2026-09-04 00:04:02.551 UTC |
| 20260902     |     419776 |            79495168 | 2026-09-03 00:03:47.330 UTC |
+--------------+------------+---------------------+---------------------------+
```

**Leé esa salida como un SRE:** `20260903` tiene 98.104 filas contra una línea base de ~420k — una **carga parcial silenciosa**. Nada falló ruidosamente; el dashboard simplemente mostró un jueves tranquilo. Exactamente por esto existe la regla VOLUME en §3.4, y es la manera más común en que se toman decisiones "data-driven" sobre datos equivocados.

### 4.4 Ejecutar el escaneo de calidad y leer el veredicto

```bash
$ gcloud dataplex datascans run orders-orders-dq --location=us-central1
Waiting for scan job to complete...
job:
  name: projects/acme-data-prod/locations/us-central1/dataScans/orders-orders-dq/jobs/8f2a1c04-...
  state: SUCCEEDED

$ gcloud dataplex datascans jobs describe 8f2a1c04-6b73-4f9e-9a41-2c7d5e0b1a33 \
    --datascan=orders-orders-dq --location=us-central1 --format=json | \
  jq '.dataQualityResult | {passed, rowCount,
       rules: [.rules[] | {rule: (.rule.column // "table"),
                           dim: .rule.dimension, passed: .passed,
                           ratio: .passRatio}]}'
{
  "passed": false,
  "rowCount": "836841",
  "rules": [
    { "rule": "order_id",     "dim": "COMPLETENESS", "passed": true,  "ratio": 1 },
    { "rule": "order_id",     "dim": "UNIQUENESS",   "passed": true,  "ratio": 1 },
    { "rule": "country_code", "dim": "VALIDITY",     "passed": true,  "ratio": 0.99997 },
    { "rule": "channel",      "dim": "VALIDITY",     "passed": false, "ratio": 0.98812 },
    { "rule": "gross_amount", "dim": "VALIDITY",     "passed": true,  "ratio": 1 },
    { "rule": "currency",     "dim": "VALIDITY",     "passed": true,  "ratio": 1 },
    { "rule": "table",        "dim": "FRESHNESS",    "passed": true,  "ratio": 1 },
    { "rule": "table",        "dim": "VOLUME",       "passed": true,  "ratio": 1 },
    { "rule": "customer_id",  "dim": "CONSISTENCY",  "passed": true,  "ratio": 0.9991 }
  ]
}
```

Encontrá los valores ofensores sin adivinar:

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT channel, COUNT(*) AS n
FROM `acme-data-prod.orders_curated.orders`
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
  AND channel NOT IN ("WEB","MOBILE","STORE","PARTNER")
GROUP BY channel ORDER BY n DESC'
+-----------+------+
|  channel  |  n   |
+-----------+------+
| KIOSK     | 9106 |
| web       |  832 |
| MARKETPL  |   47 |
+-----------+------+
```

Tres fallas de governance distintas en un solo conjunto de resultados: un **nuevo canal de negocio del que nadie avisó a la plataforma** (`KIOSK`), una **violación del contrato de mayúsculas** (`web`) y un **valor truncado** (`MARKETPL`). Cada una es un síntoma de silo — el equipo productor cambió su mundo y el contrato consumidor se enteró por una alerta en lugar de por una conversación.

### 4.5 Seguridad a nivel de columna, probada en lugar de asumida

```bash
$ gcloud auth list
                 Credentialed Accounts
ACTIVE  ACCOUNT
*       analyst-lo@acme.example.com

$ bq query --nouse_legacy_sql --format=pretty '
SELECT customer_email
FROM `acme-data-prod.orders_curated.orders`
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) LIMIT 2'
+------------------------------------------------------------------+
|                          customer_email                          |
+------------------------------------------------------------------+
| 6b2f9d1c4e8a70b35c19af02d8e4771a9c30bb5e6f4a8d21c7e903b1f5a6d8c4 |
| a91c7e4b02d85f36194ac0e8b7d25f31068ba9c4e7f2d015386ba4c9e1d70f28 |
+------------------------------------------------------------------+

$ bq query --nouse_legacy_sql 'SELECT * FROM `acme-data-prod.orders_curated.orders`
   WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) LIMIT 1'
BigQuery error in query operation: Access Denied: BigQuery BigQuery: User does not
have permission to access policy tag "pii-classification-orders : pii-high" on
column acme-data-prod.orders_curated.orders.customer_email.
```

El enmascaramiento respondió la pregunta analítica (`COUNT(DISTINCT customer_email)` sigue funcionando sobre el hash) mientras que `SELECT *` fue rechazado. **Eso es governance habilitando el acceso, no bloqueándolo** — el encuadre del examen sobre por qué la governance acelera en lugar de frenar la transformación.

### 4.6 Lineage: la respuesta a "¿de dónde salió este número?"

```bash
$ curl -sS -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  "https://us-central1-datalineage.googleapis.com/v1/projects/acme-data-prod/locations/us-central1:searchLinks" \
  -d '{
        "target": {
          "fullyQualifiedName": "bigquery:acme-data-prod.orders_consumption.daily_revenue"
        }
      }' | jq '.links[] | {from: .source.fullyQualifiedName, to: .target.fullyQualifiedName}'
{
  "from": "bigquery:acme-data-prod.orders_curated.orders",
  "to": "bigquery:acme-data-prod.orders_consumption.daily_revenue"
}
{
  "from": "bigquery:acme-data-prod.orders_curated.customers",
  "to": "bigquery:acme-data-prod.orders_consumption.daily_revenue"
}
```

```bash
$ gcloud dataplex entries lookup \
    --location=us-central1 \
    --entry="projects/acme-data-prod/locations/us-central1/entryGroups/@bigquery/entries/bigquery.googleapis.com/projects/acme-data-prod/datasets/orders_curated/tables/orders" \
    --format="value(entrySource.description)"
DATA PRODUCT: orders.curated.orders
Owner        : orders-domain@example.com
SLO          : freshness p99 <= 15 min | completeness >= 99.9% per partition
```

Un analista nuevo responde "¿es confiable, quién es el dueño, qué lo alimenta?" en dos comandos y cero reuniones. **Ese es el estado final medible de la des-silización.**

### 4.7 Atribución de costo — los datos como activo gestionado

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT
  user_email,
  COUNT(*)                                                AS jobs,
  ROUND(SUM(total_bytes_billed)/POW(1024,4), 2)           AS tib_billed,
  ROUND(SUM(total_bytes_billed)/POW(1024,4) * 6.25, 2)    AS est_usd
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND job_type = "QUERY" AND state = "DONE"
GROUP BY user_email ORDER BY tib_billed DESC LIMIT 5'
+------------------------------------------+------+------------+---------+
|                user_email                | jobs | tib_billed | est_usd |
+------------------------------------------+------+------------+---------+
| looker-sa@acme-data-prod.iam.gservice... | 8241 |      12.44 |   77.75 |
| dataform-sa@acme-data-prod.iam.gservi... |  672 |       9.03 |   56.44 |
| analyst-mk@acme.example.com              |  118 |       7.91 |   49.44 |
| analyst-lo@acme.example.com              |   96 |       0.44 |    2.75 |
| freshness-probe@acme-data-prod.iam.gs... | 2016 |       0.02 |    0.13 |
+------------------------------------------+------+------------+---------+
```

Un analista quemando 7,91 TiB en 118 consultas es una señal de capacitación (`SELECT *` sobre un rango sin filtrar), no un problema de facturación. Tratar los datos como un activo significa que su consumo es atribuible por consumidor.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Checklist previo al vuelo para cualquier producto de datos nuevo

```bash
# 1. Provenance and ownership are declared
$ bq show --format=prettyjson acme-data-prod:orders_curated.orders \
    | jq -r '.description' | grep -E '^(Owner|SLO)' || echo "FAIL: undeclared contract"

# 2. Cost guardrail present
$ bq show --format=prettyjson acme-data-prod:orders_curated.orders \
    | jq '.timePartitioning.requirePartitionFilter'
true

# 3. PII columns carry policy tags
$ bq show --schema --format=prettyjson acme-data-prod:orders_curated.orders \
    | jq '[.[] | select(.policyTags) | .name]'
[
  "customer_email"
]

# 4. Quality scan is scheduled, not manual
$ gcloud dataplex datascans describe orders-orders-dq --location=us-central1 \
    --format="value(executionSpec.trigger.schedule.cron)"
0 */2 * * *

# 5. Dead-letter path exists
$ gcloud pubsub subscriptions describe orders-events-to-bq \
    --format="value(deadLetterPolicy.deadLetterTopic)"
projects/acme-data-prod/topics/orders-events-dlq

# 6. The catalog can find it
$ gcloud dataplex entries search "orders system=bigquery" \
    --project=acme-data-prod --format="value(dataplexEntry.name)" | head -3
```

Cualquier `FAIL` de arriba significa que el dataset no es un producto de datos; es un silo con una dirección más linda.

### 5.2 Runbook: síntoma → causa → comando → resolución

| # | Síntoma | Causa más probable | Comando de diagnóstico | Resolución |
|---|---|---|---|---|
| 1 | Alerta de frescura, DLQ creciendo | El productor emite campos que no están en el esquema Avro de Pub/Sub | `gcloud pubsub topics describe orders-events-dlq`; traer una muestra desde la suscripción del DLQ | Versionar el esquema (topic `-v2` + revisión), corregir el productor, hacer replay del DLQ |
| 2 | Alerta de frescura, DLQ vacío, edad del backlog subiendo | La BigQuery subscription perdió el permiso de escritura (deriva de IAM del service agent) | `gcloud pubsub subscriptions describe orders-events-to-bq --format='value(state)'` → `RESOURCE_ERROR` | Volver a otorgar `roles/bigquery.dataEditor` a `service-<NUM>@gcp-sa-pubsub.iam.gserviceaccount.com` |
| 3 | Alerta de frescura, backlog **plano en cero** | Sin tráfico — caída del productor, no de la plataforma de datos | Comparar `topic/send_request_count` vs `subscription/oldest_unacked_message_age` | Llamar al dominio productor, no a la plataforma |
| 4 | Colapso del conteo de filas en una partición (ver §4.3) | Carga parcial silenciosa; falló un shard y el wrapper salió con 0 | `bq ls -j --max_results=50 --format=prettyjson` → buscar `status.errorResult` | Hacer replay de esa partición desde RAW; **quitar cualquier `\| tee` del wrapper del pipeline** — los pipelines enmascaran los códigos de salida |
| 5 | `order_id` duplicado tras una tormenta de reintentos | Reentrega at-least-once sin dedup en el paso RAW→CURATED | `SELECT order_id, COUNT(*) c FROM … GROUP BY 1 HAVING c > 1 LIMIT 10` | `MERGE` sobre `order_id`, o `QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY ingested_at DESC) = 1` |
| 6 | Dos equipos reportan totales distintos | Deriva semántica: dos definiciones de la misma métrica | Diferenciar el SQL de ambas vistas de consumption; revisar `INFORMATION_SCHEMA.VIEWS` | Publicar **una** vista en la zona de consumption; deprecar la otra; registrar la definición en el catálogo |
| 7 | `Cannot query over table … without a filter` | El guardrail de costo disparando como fue diseñado | — | Enseñar el filtro; **no** deshabilitar `require_partition_filter` |
| 8 | Pico de costo de consultas | `SELECT *` sin filtrar, o una vista que se abre en abanico | `JOBS_BY_PROJECT` agrupado por `user_email` (§4.7) | Fijar `maximum_bytes_billed`, agregar cuotas personalizadas, agregar vistas materializadas, habilitar BI Engine |
| 9 | Una columna nueva aparece enteramente en `NULL` | Renombrado aguas arriba; write-disposition en append sin chequeo de contrato | Diff de `bq show --schema` contra la revisión anterior en Git | Aplicar el esquema en Pub/Sub o una assertion de Dataform; backfill desde RAW |
| 10 | Analista bloqueado por `Access Denied … policy tag` | Comportamiento correcto, asignación de rol equivocada | `gcloud data-catalog taxonomies list --location=us-central1` y verificar `roles/datacatalog.categoryFineGrainedReader` | Otorgar el rol de fine-grained reader, o dirigirlos a la columna enmascarada |
| 11 | Falta la entrada de Dataplex en la búsqueda | Discovery deshabilitado, o el asset nunca se adjuntó a una zona | `gcloud dataplex assets describe curated-dataset --zone=curated-zone --lake=orders-lake --location=us-central1` | Habilitar `discovery_spec`, volver a adjuntar el asset |
| 12 | Grafo de lineage vacío | La transformación corrió fuera de un motor integrado con lineage (SDK crudo, herramienta externa) | `searchLinks` devuelve `{}` (§4.6) | Mover la transformación a Dataform/Dataflow/BigQuery, o reportar el lineage explícitamente vía la Data Lineage API |
| 13 | Regla `CONSISTENCY` de DQ fallando | Dimensión de llegada tardía: los hechos aterrizaron antes que el registro del cliente | Correr el SQL de `sqlAssertion` directamente | Agregar un wait/sensor en Composer, o aceptar y poner en cuarentena los hechos huérfanos en una tabla `_rejects` |
| 14 | Todo en verde, el negocio sigue desconfiando del número | Siguen circulando copias en planillas sin governance | Buscar exportaciones: `SELECT DISTINCT user_email FROM JOBS_BY_PROJECT WHERE statement_type="EXPORT_DATA"` | Deprecar la ruta de exportación; publicar vía BigQuery sharing / Looker en su lugar |

### 5.3 Procedimiento de replay (RAW es la razón por la que esto es corto)

```bash
# Rebuild a single corrupt partition from the immutable RAW zone.
$ bq query --nouse_legacy_sql --destination_table=orders_curated.orders\$20260903 \
  --replace --maximum_bytes_billed=50000000000 '
SELECT
  order_id, customer_id, customer_email,
  UPPER(country_code)                       AS country_code,
  UPPER(TRIM(channel))                      AS channel,
  CAST(gross_amount AS NUMERIC)             AS gross_amount,
  currency, event_ts,
  CURRENT_TIMESTAMP()                       AS ingested_at,
  source_system
FROM `acme-data-prod.orders_raw.orders_stream`
WHERE DATE(event_ts) = "2026-09-03"
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY event_ts DESC) = 1'
Waiting on bqjob_r4c81f0a2b7e93d15_00000198ac21ee0f_1 ... (34s) Current status: DONE
```

```bash
$ bq query --nouse_legacy_sql --format=pretty '
SELECT partition_id, total_rows
FROM `acme-data-prod.orders_curated.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name="orders" AND partition_id="20260903"'
+--------------+------------+
| partition_id | total_rows |
+--------------+------------+
| 20260903     |     419881 |
+--------------+------------+
```

La recuperación tomó una consulta porque RAW era inmutable y completo. **El modelo de zonas no es un gusto arquitectónico; es el mean-time-to-recovery de los números de tu negocio.**

### 5.4 Time travel y el caso de "alguien la borró"

```bash
# Read the table as it was 45 minutes ago (7-day default window).
$ bq query --nouse_legacy_sql --format=pretty '
SELECT COUNT(*) AS rows_before_incident
FROM `acme-data-prod.orders_curated.orders`
  FOR SYSTEM_TIME AS OF TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 45 MINUTE)
WHERE event_ts >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)'
+----------------------+
| rows_before_incident |
+----------------------+
|               836841 |
+----------------------+

# Who ran the destructive statement?
$ bq query --nouse_legacy_sql --format=pretty '
SELECT creation_time, user_email, statement_type, LEFT(query, 60) AS q
FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
  AND statement_type IN ("DELETE","TRUNCATE_TABLE","DROP_TABLE","MERGE")
ORDER BY creation_time DESC'
+---------------------------+------------------------------+----------------+--------------------------------------+
|       creation_time       |          user_email          | statement_type |                  q                   |
+---------------------------+------------------------------+----------------+--------------------------------------+
| 2026-09-06 13:41:07.221 U | etl-sa@acme-data-prod.iam.gs | DELETE         | DELETE FROM `orders_curated.orders`  |
+---------------------------+------------------------------+----------------+--------------------------------------+
```

---

## 6. Destilado orientado al examen

### 6.1 Términos que tenés que poder definir en una oración

| Término | Definición en una oración |
|---|---|
| **Data silo** | Datos aislados bajo el control de un equipo de modo que otros no pueden accederlos ni confiar en ellos, produciendo versiones conflictivas de la verdad. |
| **Ciclo de vida del dato** | Ingesta → almacenamiento → procesamiento/análisis → activación/visualización; el valor solo se realiza al final, y cada etapa puede perderlo. |
| **Estructurado / semiestructurado / no estructurado** | Esquema fijo / esquema flexible autodescriptivo / sin esquema inherente — siendo el último la mayoría de los datos empresariales. |
| **Data governance** | Las personas, políticas y controles que hacen que los datos sean descubribles, confiables, seguros y compliant — *para que puedan compartirse*. |
| **Data quality** | Aptitud para el propósito, medida a través de completitud, validez, unicidad, consistencia, frescura y volumen. |
| **Data lineage** | La procedencia registrada de un dataset: qué fuentes y transformaciones lo produjeron. |
| **Toma de decisiones data-driven** | Decisiones tomadas a partir de datos medidos, oportunos y gobernados en lugar de intuición o reportes rancios. |
| **Datos como activo estratégico / diferenciador** | Los datos propios (first-party) son el insumo que los competidores no pueden copiar; es lo que hace que un modelo de ML sea *tuyo*. |
| **Democratización de datos** | Acceso seguro de autoservicio para no especialistas, algo posible solo una vez que existe la governance. |
| **Monetización de datos** | Convertir datos gobernados en ingresos — productos nuevos, mejores decisiones, o sharing gobernado (BigQuery sharing / Analytics Hub). |

### 6.2 Las cinco trampas, consolidadas

1. **No podés saltear escalones** — no hay estrategia de AI sin estrategia de datos.
2. **Consolidar el almacenamiento ≠ eliminar los silos** — la propiedad, las definiciones y la política también deben consolidarse, o terminás con un data swamp.
3. **Los datos no estructurados son la mayoría** — Cloud Storage es su hogar; las object tables + BigQuery ML/Vertex AI los vuelven analizables.
4. **Streaming no es automáticamente mejor** — elegí la latencia más barata que cambie una decisión.
5. **La governance habilita el acceso, no solo lo restringe** — datos enmascarados, etiquetados y con lineage rastreado pueden abrirse ampliamente; los datos sin governance deben quedar cerrados, recreando silos.

Dos más que vale la pena llevar al examen:

6. **La cultura está dentro del alcance.** El examen trata explícitamente la gestión del cambio y la alfabetización en datos como parte de la transformación. Una plataforma perfecta sin consumidores capacitados no produce decisiones.
7. **El valor se realiza en la activación, no en la ingesta.** Los bytes almacenados son costo; las decisiones cambiadas son valor.

### 6.3 Ejercicio de escenario (estilo examen)

> *Un retailer tiene datos de POS de tiendas en una base Oracle on-prem, clickstream de e-commerce en una herramienta SaaS de analítica, y fotos de inventario en un NAS. Merchandising y Finanzas publican cifras de ingresos semanales distintas. La dirección quiere pronóstico de demanda. ¿Cuál es la primera prioridad?*

**Respuesta:** No el modelo de pronóstico. Primero, romper los silos y establecer una única fuente de verdad gobernada — CDC del POS con Datastream, transmitir el clickstream a través de Pub/Sub, aterrizar las imágenes en Cloud Storage como object tables, unificar en BigQuery, catalogar y aplicar calidad con Dataplex, y publicar **una** definición acordada de ingresos en la zona de consumption. El modelo de pronóstico es el escalón 5; el desacuerdo sobre los ingresos prueba que la organización sigue en el escalón 1. Solo después de que la definición sea única y su frescura/completitud sean medibles, BigQuery ML o Vertex AI producen un pronóstico sobre el que alguien debería actuar.

---

## 7. Referencias

**Examen y certificación**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader
- Learning path: Exploring Data Transformation with Google Cloud — https://www.cloudskillsboost.google/paths/9

**Estrategia de datos y transformación**
- What is digital transformation — https://cloud.google.com/learn/what-is-digital-transformation
- Data analytics on Google Cloud — https://cloud.google.com/solutions/data-analytics-and-ai
- Data lifecycle on Google Cloud — https://cloud.google.com/architecture/data-lifecycle-cloud-platform
- Cloud Architecture Center — data engineering — https://cloud.google.com/architecture/data-engineering
- Google Cloud Architecture Framework — https://cloud.google.com/architecture/framework

**Almacenamiento y analítica**
- BigQuery documentation — https://cloud.google.com/bigquery/docs
- BigQuery partitioned tables — https://cloud.google.com/bigquery/docs/partitioned-tables
- BigQuery clustered tables — https://cloud.google.com/bigquery/docs/clustered-tables
- BigQuery `INFORMATION_SCHEMA` — https://cloud.google.com/bigquery/docs/information-schema-intro
- BigQuery time travel — https://cloud.google.com/bigquery/docs/time-travel
- BigLake introduction — https://cloud.google.com/biglake/docs/introduction
- BigQuery object tables (unstructured data) — https://cloud.google.com/bigquery/docs/object-table-introduction
- Cloud Storage documentation — https://cloud.google.com/storage/docs
- Cloud Storage Autoclass — https://cloud.google.com/storage/docs/autoclass
- Cloud Storage soft delete — https://cloud.google.com/storage/docs/soft-delete

**Ingesta y procesamiento**
- Pub/Sub documentation — https://cloud.google.com/pubsub/docs
- Pub/Sub schemas — https://cloud.google.com/pubsub/docs/schemas
- Pub/Sub BigQuery subscriptions — https://cloud.google.com/pubsub/docs/bigquery
- Pub/Sub dead-letter topics — https://cloud.google.com/pubsub/docs/handling-failures
- Datastream documentation — https://cloud.google.com/datastream/docs
- Database Migration Service — https://cloud.google.com/database-migration/docs
- Dataflow documentation — https://cloud.google.com/dataflow/docs
- Dataproc documentation — https://cloud.google.com/dataproc/docs
- Cloud Data Fusion — https://cloud.google.com/data-fusion/docs
- Dataform — https://cloud.google.com/dataform/docs
- Cloud Composer — https://cloud.google.com/composer/docs
- BigQuery Data Transfer Service — https://cloud.google.com/bigquery-transfer/docs/introduction
- Storage Transfer Service — https://cloud.google.com/storage-transfer/docs
- Transfer Appliance — https://cloud.google.com/transfer-appliance/docs

**Governance, calidad, lineage, seguridad**
- Dataplex Universal Catalog — https://cloud.google.com/dataplex/docs
- Dataplex auto data quality — https://cloud.google.com/dataplex/docs/auto-data-quality-overview
- Create and run a data quality scan — https://cloud.google.com/dataplex/docs/use-auto-data-quality
- Data Catalog transition to Dataplex Universal Catalog — https://cloud.google.com/dataplex/docs/transition-to-dataplex-catalog
- Data lineage in Dataplex — https://cloud.google.com/dataplex/docs/about-data-lineage
- BigQuery column-level security — https://cloud.google.com/bigquery/docs/column-level-security-intro
- BigQuery data masking — https://cloud.google.com/bigquery/docs/column-data-masking-intro
- BigQuery row-level security — https://cloud.google.com/bigquery/docs/row-level-security-intro
- VPC Service Controls — https://cloud.google.com/vpc-service-controls/docs/overview
- Cloud KMS / CMEK — https://cloud.google.com/kms/docs
- Sensitive Data Protection (Cloud DLP) — https://cloud.google.com/sensitive-data-protection/docs

**Sharing, BI y AI**
- BigQuery sharing (Analytics Hub) — https://cloud.google.com/bigquery/docs/analytics-hub-introduction
- Looker — https://cloud.google.com/looker/docs
- Looker Studio — https://cloud.google.com/looker-studio
- BigQuery ML — https://cloud.google.com/bigquery/docs/bqml-introduction
- Vertex AI — https://cloud.google.com/vertex-ai/docs

**Práctica de SRE y confiabilidad**
- Google SRE Book — Service Level Objectives — https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook — Alerting on SLOs — https://sre.google/workbook/alerting-on-slos/
- Cloud Monitoring log-based metrics — https://cloud.google.com/logging/docs/logs-based-metrics
- GKE Workload Identity Federation — https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity

**Referencias de proveedores y herramientas**
- Terraform Google provider — https://registry.terraform.io/providers/hashicorp/google/latest/docs
- `gcloud dataplex` reference — https://cloud.google.com/sdk/gcloud/reference/dataplex
- `bq` command-line reference — https://cloud.google.com/bigquery/docs/reference/bq-cli-reference