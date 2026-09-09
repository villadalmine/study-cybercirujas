# Tema 6.1 — Cómo Google Cloud da soporte a la capacidad de una organización para controlar los costos en la nube

**Certificación:** Google Cloud Digital Leader (guía de examen versión 2026-08-12)
**Peso del dominio 6:** 5.0
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. Motivación: el costo es una propiedad de fiabilidad en producción, no un artefacto contable

### 1.1 El problema arquitectónico

En un datacenter on-premises, el gasto está **estructuralmente acotado por la física**. No podés consumir un rack que no compraste. La capacidad es una decisión de capex que se toma una vez, meses antes, por un conjunto reducido de personas con autoridad de compra. El modo de fallo es la *inanición*: un equipo espera ocho semanas por hardware.

En Google Cloud la cota se invierte. Cualquier principal que tenga `roles/compute.instanceAdmin` sobre un proyecto vinculado a una cuenta activa de Cloud Billing puede, en una sola llamada a la API, instanciar una máquina `a3-highgpu-8g` y empezar a devengar miles de dólares por día. El modo de fallo pasa a ser el *consumo descontrolado*: un DAG de Cloud Composer mal configurado, un bucle `for` en un job de CI que nunca llama a `terraform destroy`, un `SELECT *` de BigQuery sobre una tabla sin particionar de 400 TiB programado cada hora.

El hecho arquitectónico más importante de este objetivo:

> **Google Cloud no ofrece ningún tope duro de gasto sobre una cuenta de facturación.** Los presupuestos de Cloud Billing son un mecanismo de *detección y notificación*. No detienen el consumo. Los únicos mecanismos que detienen el consumo de forma dura son las **cuotas**, las restricciones de **Organization Policy** y **desvincular la cuenta de facturación de un proyecto** — y esto último es destructivo.

Es una decisión de diseño deliberada, y es la correcta para una plataforma cuyo contrato principal es la disponibilidad: un sistema que termina silenciosamente cargas de trabajo de producción cuando se cruza un umbral presupuestario convirtió un evento financiero en una caída. Como Platform Architect vos sos dueño de ese trade-off de forma explícita, en lugar de heredarlo por accidente.

### 1.2 El modelo de control de costos en cinco capas

Toda capacidad de control de costos de Google Cloud encaja en exactamente una de cinco capas. Las entrevistas, las revisiones de diseño y el examen CDL premian poder nombrar la capa a la que pertenece cada herramienta.

| Capa | Pregunta que responde | Aplicación | Mecanismos de Google Cloud | Latencia |
|---|---|---|---|---|
| **1. Prevenir** | ¿Puede ocurrir este gasto siquiera? | Dura (denegación de la API) | Cuotas (de asignación y de tasa), restricciones de Organization Policy, IAM (escasez de `roles/billing.user`), VPC Service Controls | Instantánea, síncrona |
| **2. Atribuir** | ¿De quién es este gasto? | Ninguna (metadatos) | Jerarquía de recursos, labels, tags, subcuentas de facturación, asignación de costos de GKE | Estructural |
| **3. Detectar** | ¿El gasto se desvió del plan? | Ninguna (señal) | Presupuestos y alertas, notificaciones de presupuesto por Pub/Sub, informes Cost Table / Cost Breakdown, exportación de facturación a BigQuery, detección de anomalías de costo | Horas (latencia de la exportación de facturación) |
| **4. Optimizar** | ¿Estamos pagando más de lo necesario por el mismo resultado? | Consultiva | Active Assist / Recommender, FinOps Hub, CUD Recommender, rightsizing, Autoclass, VPA | Días |
| **5. Comprometer** | ¿Podemos comprar la misma capacidad más barata? | Contractual | SUD, CUD (basados en recursos + basados en gasto/flexibles), reservas, Spot VMs, Network Service Tiers, BigQuery Editions | Meses (plazos de 1 o 3 años) |

Un programa de costos que solo implementa la capa 3 (presupuestos) es el patrón de fallo más común en el campo: produce alertas que llegan 18 horas después de un error de $40k, dirigidas a un administrador de facturación que no puede identificar al equipo responsable porque la capa 2 nunca se construyó.

---

## 2. Primero la capa 2: la jerarquía de recursos es la columna vertebral de la atribución de costos

No podés detectar, optimizar ni imputar un gasto que no podés atribuir. La atribución es estructural y debe diseñarse **antes** de que aterrice la primera carga de trabajo, porque los labels y la ubicación en la jerarquía son en gran medida no retroactivos en los datos de facturación.

### 2.1 La jerarquía

```
Organization  (1 per Cloud Identity / Workspace domain — the root IAM + policy anchor)
 └── Folder        (up to 10 levels of nesting; the natural boundary for
      └── Folder    Org Policy inheritance and for budget scoping)
           └── Project   (THE billing boundary — exactly one billing account per project)
                └── Resource   (VM, bucket, dataset, Cloud Run service …)
```

Invariantes clave que hay que internalizar:

| Invariante | Consecuencia para el control de costos |
|---|---|
| Un proyecto está vinculado a **exactamente una** cuenta de Cloud Billing por vez. | El proyecto es la unidad atómica de imputación. Dos centros de costo compartiendo un proyecto es un defecto arquitectónico. |
| Una cuenta de facturación puede financiar **muchos** proyectos. | Acá viven la facturación consolidada y los pools compartidos de CUD/SUD. |
| IAM y Organization Policy se **heredan hacia abajo** y son **aditivos** en IAM (un hijo no puede revocar un allow heredado) pero **sobrescribibles** en Org Policy (un hijo puede sobrescribir con `inheritFromParent: false` si está permitido). | Las barreras preventivas van en las carpetas, no en los proyectos. |
| El IAM de facturación está sobre la **cuenta de facturación**, que es un recurso *fuera* de la jerarquía de proyectos. | `roles/owner` sobre un proyecto **no** otorga la capacidad de ver su costo. Esto sorprende a la gente constantemente. |

### 2.2 IAM de facturación — la matriz de mínimo privilegio

| Rol | ID | Otorga | Otorgar a |
|---|---|---|---|
| Billing Account Creator | `roles/billing.creator` | Crear nuevas cuentas de facturación | Solo finanzas a nivel organización |
| Billing Account Administrator | `roles/billing.admin` | Control total: vincular/desvincular proyectos, gestionar presupuestos, exportación, pagos | 2–4 personas, break-glass |
| Billing Account User | `roles/billing.user` | **Vincular un proyecto a esta cuenta de facturación** | SA de automatización de plataforma + pipeline de landing zone |
| Billing Account Costs Manager | `roles/billing.costsManager` | Gestionar presupuestos, ver/exportar datos de costo — **no** precios ni pagos | Equipo FinOps, líderes de ingeniería |
| Billing Account Viewer | `roles/billing.viewer` | Leer datos de costo y presupuestos | Cualquier ingeniero responsable de un servicio |
| Project Billing Manager | `roles/billing.projectManager` | Vincular/desvincular **este proyecto** a una cuenta de facturación sobre la cual el principal es `billing.user` | Líderes de equipos de aplicación en una landing zone autoservicio |

El patrón seguro clásico: **la creación de proyectos y la vinculación de facturación requieren dos roles distintos en manos de dos principals distintos** (`roles/resourcemanager.projectCreator` sobre la carpeta + `roles/billing.user` sobre la cuenta de facturación). Otorgar solo el primero significa que un actor malicioso puede crear proyectos pero nunca hacer que cuesten dinero.

```bash
$ gcloud beta billing accounts get-iam-policy 01A2B3-C4D5E6-F7G8H9
bindings:
- members:
  - group:gcp-billing-admins@example.com
  role: roles/billing.admin
- members:
  - group:gcp-finops@example.com
  role: roles/billing.costsManager
- members:
  - serviceAccount:landing-zone@plat-automation.iam.gserviceaccount.com
  role: roles/billing.user
- members:
  - group:gcp-engineering-all@example.com
  role: roles/billing.viewer
etag: BwYb2xZ3q1M=
version: 1
```

### 2.3 Labels: la primitiva de atribución

Los labels son pares clave/valor que se propagan a la exportación de facturación. Son el mecanismo por el cual el showback y el chargeback se vuelven consultables. Restricciones que hay que contemplar en el diseño:

| Propiedad | Valor | Consecuencia de diseño |
|---|---|---|
| Máximo de labels por recurso | 64 | Presupuestalos; no codifiques metadatos de formato libre |
| Longitud de clave / longitud de valor | 63 caracteres cada una | Usá claves canónicas cortas |
| Caracteres permitidos | letras minúsculas, dígitos, `-`, `_`, caracteres internacionales | Aplicá una regex en CI |
| Retroactividad en la exportación de facturación | **Ninguna** | Un recurso sin labels queda permanentemente sin atribuir durante el período en que corrió sin ellos |
| Propagación a recursos hijos | **No es automática** (p. ej., el label de una instancia de GCE no etiqueta su disco adjunto) | Etiquetá todos los recursos en Terraform vía `default_labels` en el provider |
| Labels de proyecto | Se exportan como `project.labels` | Usalos para atribución gruesa que sobrevive al drift de labels a nivel de recurso |

Estandarizá una taxonomía pequeña y obligatoria, y aplicala en la capa de IaC:

```hcl
# terraform/provider.tf — every resource created by this provider block inherits these
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    cost-center    = var.cost_center      # "cc-4417"
    environment    = var.environment      # prod | staging | dev | sandbox
    owner-team     = var.owner_team       # "platform-sre"
    service        = var.service_name     # "checkout-api"
    data-class     = var.data_class       # public | internal | restricted
    managed-by     = "terraform"
    tf-workspace   = terraform.workspace
  }
}
```

Después cerrá el círculo con Cloud Asset Inventory para encontrar el drift — los recursos creados fuera de Terraform son la fuga:

```bash
$ gcloud asset search-all-resources \
    --scope='organizations/123456789012' \
    --asset-types='compute.googleapis.com/Instance,compute.googleapis.com/Disk,storage.googleapis.com/Bucket' \
    --query='NOT labels.cost-center:*' \
    --format='table(name.basename(), assetType, project, location)'

NAME                       ASSET_TYPE                            PROJECT           LOCATION
jenkins-agent-scratch-01   compute.googleapis.com/Instance       eng-ci-9931       us-central1-a
pd-jenkins-agent-scratch   compute.googleapis.com/Disk           eng-ci-9931       us-central1-a
dataproc-staging-4ab19c    storage.googleapis.com/Bucket         analytics-prd-01  us-central1
tmp-export-mbrennan        storage.googleapis.com/Bucket         analytics-prd-01  us

Listed 4 items.
```

> **Labels vs. tags.** Los *tags* de Google Cloud (`tagKeys`/`tagValues`, un recurso de Resource Manager) son una primitiva distinta de los labels: están controlados por IAM, son heredables hacia abajo en la jerarquía y se pueden usar en IAM condicional y en condiciones de Organization Policy. Los tags **sí** aparecen en la exportación detallada de facturación (columna `tags`). Usá **labels** para atribución/showback; usá **tags** para gobernanza condicionada por política (p. ej., "solo los recursos con el tag `env=prod` pueden usar `n2-highmem`").

---

## 3. Capa 3: exportación de Cloud Billing a BigQuery — la fuente de verdad

Los informes de la consola son cómodos; la exportación a BigQuery es la autoritativa y es la única superficie sobre la que podés construir unit economics a medida, detección de anomalías e imputación de costos.

### 3.1 Las tres exportaciones

| Exportación | Patrón del nombre de tabla | Granularidad | Para qué usarla |
|---|---|---|---|
| **Standard usage cost** | `gcp_billing_export_v1_<BA_ID>` | Servicio + SKU + proyecto + día + labels | Chargeback, validación de presupuestos, análisis de tendencia |
| **Detailed usage cost** | `gcp_billing_export_resource_v1_<BA_ID>` | Agrega `resource.name` / `resource.global_name` — **por recurso individual** | Encontrar *qué* VM/disco/bucket, asignación de costos de GKE, caza de desperdicio |
| **Pricing** | `cloud_pricing_export` | Precio de lista por SKU, tramos, moneda, fechas de vigencia | Modelado, reconciliación de `cost_at_list`, análisis what-if previo a la compra |

Los guiones bajos en el nombre de la tabla reemplazan a los guiones del ID de cuenta de facturación: cuenta de facturación `01A2B3-C4D5E6-F7G8H9` → `gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`.

### 3.2 Cómo habilitarla

La configuración de exportación vive en la **cuenta de facturación**, no en el proyecto, y hoy se maneja por consola/API:

```bash
# 1. Create the sink dataset in a dedicated, tightly-scoped project.
$ gcloud config set project fin-billing-prd-01
Updated property [core/project].

$ bq --location=US mk --dataset \
    --description="Cloud Billing export (standard, detailed, pricing)" \
    --default_table_expiration=0 \
    fin-billing-prd-01:cloud_billing_export
Dataset 'fin-billing-prd-01:cloud_billing_export' successfully created.

# 2. Grant the billing export service the right to write.
$ gcloud projects add-iam-policy-binding fin-billing-prd-01 \
    --member='group:gcp-billing-admins@example.com' \
    --role='roles/bigquery.dataEditor' --condition=None
Updated IAM policy for project [fin-billing-prd-01].

# 3. Enable in console: Billing -> Billing export -> BigQuery export ->
#    edit "Standard usage cost", "Detailed usage cost", "Pricing".
# 4. Confirm tables materialize (first rows typically appear within a few hours;
#    detailed export can take up to ~24h for the first partition).
$ bq ls --max_results=50 fin-billing-prd-01:cloud_billing_export
                    tableId                        Type    Labels   Time Partitioning
 ------------------------------------------------ ------- -------- -------------------
  gcp_billing_export_resource_v1_01A2B3_C4D5E6_F7G8H9  TABLE            DAY (field: _PARTITIONTIME)
  gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9           TABLE            DAY (field: _PARTITIONTIME)
  cloud_pricing_export                                 TABLE            DAY (field: _PARTITIONTIME)
```

> **La exportación no es retroactiva.** Empieza a capturar en el momento en que la habilitás. Por eso habilitar la exportación de facturación es el ítem n.º 1 de cualquier construcción de landing zone, antes de la primera carga de trabajo. No hay forma de rellenar hacia atrás.

### 3.3 Los campos del esquema que importan

| Columna | Tipo | Significado / trampa |
|---|---|---|
| `cost` | FLOAT64 | Costo **a tu tarifa negociada/de lista, antes de créditos**. Esto *no* es lo que pagás. |
| `credits` | ARRAY<STRUCT> | Cada uno tiene `name`, `amount` (negativo), `type`, `id`. Los tipos incluyen `SUSTAINED_USAGE_DISCOUNT`, `COMMITTED_USAGE_DISCOUNT`, `DISCOUNT`, `PROMOTION`, `FREE_TIER`, `SUBSCRIPTION_BENEFIT`, `COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE`. |
| `cost_at_list` | FLOAT64 | Precio de lista público. `cost_at_list - cost` = descuento contractual/negociado. |
| `usage.amount` / `usage.unit` | FLOAT64 / STRING | Consumo bruto. Preferí `usage.amount_in_pricing_units`. |
| `invoice.month` | STRING `YYYYMM` | **Usalo para lo definitivo.** Las sumas diarias se reexpresan con ajustes durante semanas. |
| `adjustment_info` | STRUCT | Se completa en correcciones/reembolsos — las filas pueden tener costo negativo. |
| `export_time` | TIMESTAMP | Cuándo aterrizó la fila. Usalo para detectar exportaciones estancadas. |
| `labels`, `system_labels`, `project.labels`, `tags` | ARRAY<STRUCT<key,value>> | Atribución. `system_labels` lleva claves puestas por Google como `compute.googleapis.com/machine_spec`. |
| `resource.name` | STRING | **Solo en la exportación detallada.** El recurso individual. |
| `cost_type` | STRING | `regular`, `tax`, `adjustment`, `rounding_error`. Filtrá `= 'regular'` para análisis de ingeniería. |

### 3.4 La consulta que todo equipo de plataforma debería tener

El **costo efectivo** es `cost + SUM(credits.amount)`. Equivocarse en esto sobrestima el gasto por el valor completo de tus CUD y SUD — un error rutinario del 20–40%.

```sql
-- Effective monthly cost by cost-center, environment, service and SKU.
-- Run against the STANDARD export; partition-pruned on _PARTITIONTIME.
DECLARE start_ts TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 DAY);

WITH enriched AS (
  SELECT
    invoice.month                                       AS invoice_month,
    project.id                                          AS project_id,
    service.description                                 AS service,
    sku.description                                     AS sku,
    location.region                                     AS region,
    (SELECT value FROM UNNEST(labels)         WHERE key = 'cost-center') AS cost_center,
    (SELECT value FROM UNNEST(labels)         WHERE key = 'environment') AS environment,
    (SELECT value FROM UNNEST(labels)         WHERE key = 'service')     AS service_label,
    (SELECT value FROM UNNEST(project.labels) WHERE key = 'cost-center') AS project_cost_center,
    cost,
    cost_at_list,
    IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0) AS credits_total,
    IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c
            WHERE c.type = 'COMMITTED_USAGE_DISCOUNT'), 0)      AS cud_credits,
    IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c
            WHERE c.type = 'SUSTAINED_USAGE_DISCOUNT'), 0)      AS sud_credits,
    usage.amount_in_pricing_units AS usage_units,
    usage.pricing_unit            AS usage_unit
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= start_ts
    AND cost_type = 'regular'
)
SELECT
  invoice_month,
  COALESCE(cost_center, project_cost_center, 'UNATTRIBUTED') AS cost_center,
  COALESCE(environment, 'unknown')                           AS environment,
  service,
  sku,
  region,
  ROUND(SUM(cost_at_list), 2)                       AS list_cost,
  ROUND(SUM(cost), 2)                               AS invoiced_before_credits,
  ROUND(SUM(cud_credits), 2)                        AS cud_credits,
  ROUND(SUM(sud_credits), 2)                        AS sud_credits,
  ROUND(SUM(cost) + SUM(credits_total), 2)          AS effective_cost,
  SAFE_DIVIDE(SUM(cost) + SUM(credits_total), NULLIF(SUM(cost_at_list), 0)) AS effective_rate_vs_list,
  ROUND(SUM(usage_units), 3)                        AS usage_units,
  ANY_VALUE(usage_unit)                             AS usage_unit
FROM enriched
GROUP BY invoice_month, cost_center, environment, service, sku, region
HAVING effective_cost > 1.0
ORDER BY invoice_month DESC, effective_cost DESC
LIMIT 200;
```

```
$ bq query --use_legacy_sql=false --maximum_bytes_billed=50000000000 < effective_cost.sql
+---------------+-------------+-------------+----------------------------+--------------------------------------------------+-------------+-----------+-------------------------+-------------+-------------+----------------+------------------------+
| invoice_month | cost_center | environment |          service           |                       sku                        |   region    | list_cost | invoiced_before_credits | cud_credits | sud_credits | effective_cost | effective_rate_vs_list |
+---------------+-------------+-------------+----------------------------+--------------------------------------------------+-------------+-----------+-------------------------+-------------+-------------+----------------+------------------------+
| 202609        | cc-4417     | prod        | Compute Engine             | N2 Instance Core running in Americas             | us-central1 |  61240.11 |                61240.11 |   -22318.44 |    -1180.02 |       37741.65 |     0.6162             |
| 202609        | cc-4417     | prod        | Compute Engine             | N2 Instance Ram running in Americas              | us-central1 |  33110.87 |                33110.87 |   -12071.55 |     -638.10 |       20401.22 |     0.6161             |
| 202609        | cc-2201     | prod        | BigQuery                   | Analysis (on-demand)                             | US          |  28904.00 |                28904.00 |        0.00 |        0.00 |       28904.00 |     1.0000             |
| 202609        | UNATTRIBUTED| unknown     | Networking                 | Network Internet Egress from Americas to China   | us-central1 |  14882.36 |                14882.36 |        0.00 |        0.00 |       14882.36 |     1.0000             |
| 202609        | cc-4417     | prod        | Cloud Storage              | Standard Storage US Multi-region                 | us          |   9120.44 |                 9120.44 |        0.00 |        0.00 |        9120.44 |     1.0000             |
| 202609        | cc-9002     | dev         | Compute Engine             | N2 Instance Core running in Americas             | us-central1 |   8003.19 |                 8003.19 |        0.00 |     -800.31 |        7202.88 |     0.9000             |
+---------------+-------------+-------------+----------------------------+--------------------------------------------------+-------------+-----------+-------------------------+-------------+-------------+----------------+------------------------+
```

De esa salida saltan dos hallazgos, típicos de una primera consulta real: una línea de egress a internet **sin atribuir** de $14,8k (nadie sabe qué servicio está hablando con China), y BigQuery on-demand a $28,9k con un `effective_rate_vs_list` de exactamente 1.0 — cero cobertura de compromisos. Ambos son accionables en un día.

---

## 4. Capa 3: presupuestos y alertas — y lo que no pueden hacer

### 4.1 Semántica

Un **presupuesto** es un recurso sobre la cuenta de facturación con:

- un **importe** — ya sea `specifiedAmount` o `lastPeriodAmount` (fijado automáticamente al gasto del período calendario anterior),
- un **filtro** — proyectos / carpetas / subcuentas, servicios, SKUs, una clave/valor de label, tratamiento de créditos,
- **reglas de umbral** — un porcentaje más un `spendBasis` de `CURRENT_SPEND` o `FORECASTED_SPEND`,
- **reglas de notificación** — destinatarios IAM por defecto (administradores/usuarios de facturación), hasta 5 canales de notificación de Cloud Monitoring y/o un topic de Pub/Sub.

| Propiedad | Realidad | Por qué importa operativamente |
|---|---|---|
| ¿Detiene el gasto? | **No** | Los presupuestos son observabilidad. Tratalos como señal de paging, no como control. |
| Cadencia de evaluación | Varias veces por día, contra los datos de costo exportados | Una alerta puede ir horas por detrás del consumo real |
| `FORECASTED_SPEND` | Proyecta el gasto de fin de período a partir del ritmo actual | El *único* umbral que dispara con suficiente anticipación para importar ante fugas lentas |
| `CURRENT_SPEND` al 100% | Dispara después de que el dinero se fue | Útil para registros de imputación, inútil para prevenir |
| Notificaciones de Pub/Sub | Se envían en **cada** actualización del presupuesto, no solo al cruzar umbrales | Tu suscriptor debe ser idempotente y consciente de los umbrales |
| Filtrar por labels | **Una** clave de label por presupuesto | Motiva un patrón de fan-out de "un presupuesto por centro de costo" |
| Presupuestos por cuenta de facturación | Acotados (hoy del orden de 1.000) | Generalos desde IaC, no los crees a mano |

### 4.2 Terraform completo: presupuesto + Pub/Sub + canal de Monitoring + cableado del kill switch

```hcl
# ---------------------------------------------------------------------------
# terraform/budgets/main.tf
# Budget → Pub/Sub → Cloud Run function. Emits alerts; optionally hard-stops
# billing on non-production projects only.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 6.0" }
  }
}

variable "billing_account_id" {
  description = "Cloud Billing account ID, e.g. 01A2B3-C4D5E6-F7G8H9"
  type        = string
}

variable "ops_project_id" {
  description = "Project hosting the budget notification plumbing"
  type        = string
  default     = "fin-billing-prd-01"
}

# Cost centers driven from a single map so budgets are generated, not authored.
variable "cost_centers" {
  description = "Monthly USD budget per cost-center label value"
  type = map(object({
    monthly_usd  = number
    pagerduty    = bool
    hard_stop    = bool   # only ever true for sandbox/dev
    project_ids  = list(string)
  }))
  default = {
    "cc-4417" = { monthly_usd = 120000, pagerduty = true,  hard_stop = false, project_ids = ["checkout-prd-01", "checkout-prd-02"] }
    "cc-2201" = { monthly_usd = 45000,  pagerduty = true,  hard_stop = false, project_ids = ["analytics-prd-01"] }
    "cc-9002" = { monthly_usd = 6000,   pagerduty = false, hard_stop = true,  project_ids = ["eng-sandbox-01"] }
  }
}

# ---------------------------------------------------------------------------
# Notification transport
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "budget_alerts" {
  project = var.ops_project_id
  name    = "cloud-billing-budget-alerts"

  message_retention_duration = "604800s" # 7 days — replay window for debugging

  labels = {
    cost-center = "cc-0001"
    owner-team  = "platform-sre"
    managed-by  = "terraform"
  }
}

# The Cloud Billing budgets service agent must be able to publish here.
# Terraform does NOT add this binding for you (the console does). This is the
# single most common reason a Pub/Sub-wired budget silently never fires.
resource "google_pubsub_topic_iam_member" "budgets_publisher" {
  project = var.ops_project_id
  topic   = google_pubsub_topic.budget_alerts.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com"
}

resource "google_monitoring_notification_channel" "finops_email" {
  project      = var.ops_project_id
  display_name = "FinOps distribution list"
  type         = "email"
  labels = {
    email_address = "gcp-finops@example.com"
  }
}

resource "google_monitoring_notification_channel" "sre_pagerduty" {
  project      = var.ops_project_id
  display_name = "Platform SRE PagerDuty"
  type         = "pagerduty"
  sensitive_labels {
    service_key = var.pagerduty_service_key
  }
}

# ---------------------------------------------------------------------------
# Per-cost-center budgets
# ---------------------------------------------------------------------------

data "google_project" "targets" {
  for_each   = toset(flatten([for cc in var.cost_centers : cc.project_ids]))
  project_id = each.value
}

resource "google_billing_budget" "cost_center" {
  for_each = var.cost_centers

  billing_account = var.billing_account_id
  display_name    = "budget-${each.key}-monthly"

  budget_filter {
    # Budget filters take project NUMBERS in the form "projects/<number>".
    projects = [
      for p in each.value.project_ids : "projects/${data.google_project.targets[p].number}"
    ]

    calendar_period = "MONTH"

    # INCLUDE_ALL_CREDITS  -> budget tracks EFFECTIVE cost (post CUD/SUD).
    # EXCLUDE_ALL_CREDITS  -> budget tracks gross cost. Choose deliberately:
    # excluding credits makes the budget insensitive to commitment coverage
    # changes, which is what you want when the budget models raw consumption.
    credit_types_treatment = "INCLUDE_ALL_CREDITS"

    # Exactly one label key is supported per budget filter.
    labels = {
      "cost-center" = each.key
    }
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(each.value.monthly_usd)
    }
  }

  # 50% current  -> informational, email only
  # 80% current  -> engineering attention
  # 100% forecast-> the actionable one: run rate will blow the budget
  # 100% current -> the money is spent
  # 120% current -> containment / hard stop for non-prod
  threshold_rules { threshold_percent = 0.5  spend_basis = "CURRENT_SPEND"    }
  threshold_rules { threshold_percent = 0.8  spend_basis = "CURRENT_SPEND"    }
  threshold_rules { threshold_percent = 1.0  spend_basis = "FORECASTED_SPEND" }
  threshold_rules { threshold_percent = 1.0  spend_basis = "CURRENT_SPEND"    }
  threshold_rules { threshold_percent = 1.2  spend_basis = "CURRENT_SPEND"    }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alerts.id
    schema_version = "1.0"

    monitoring_notification_channels = compact([
      google_monitoring_notification_channel.finops_email.id,
      each.value.pagerduty ? google_monitoring_notification_channel.sre_pagerduty.id : "",
    ])

    # Suppress the blast to every billing admin/user; route through channels.
    disable_default_iam_recipients = true
  }
}

# ---------------------------------------------------------------------------
# Org-wide catch-all: forecast-based, covers everything including new projects
# that no cost-center budget has been written for yet.
# ---------------------------------------------------------------------------

resource "google_billing_budget" "org_catch_all" {
  billing_account = var.billing_account_id
  display_name    = "budget-org-catch-all"

  budget_filter {
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
    # No project filter => entire billing account.
  }

  # lastPeriodAmount auto-tracks last month's spend: a pure anomaly detector
  # that needs no maintenance as the estate grows.
  amount {
    last_period_amount = true
  }

  threshold_rules { threshold_percent = 1.15 spend_basis = "FORECASTED_SPEND" }
  threshold_rules { threshold_percent = 1.30 spend_basis = "CURRENT_SPEND"    }

  all_updates_rule {
    pubsub_topic                     = google_pubsub_topic.budget_alerts.id
    schema_version                   = "1.0"
    monitoring_notification_channels = [google_monitoring_notification_channel.sre_pagerduty.id]
    disable_default_iam_recipients   = true
  }
}

output "budget_topic" {
  value = google_pubsub_topic.budget_alerts.id
}
```

### 4.3 El contrato del mensaje de Pub/Sub

Cada actualización de presupuesto publica un mensaje. Payload de `schemaVersion 1.0` (en base64 dentro de `message.data`):

```json
{
  "budgetDisplayName": "budget-cc-9002-monthly",
  "alertThresholdExceeded": 1.2,
  "costAmount": 7231.44,
  "costIntervalStart": "2026-09-01T00:00:00Z",
  "budgetAmount": 6000.0,
  "budgetAmountType": "SPECIFIED_AMOUNT",
  "currencyCode": "USD"
}
```

Los **atributos** del mensaje llevan los metadatos de enrutamiento:

```
billingAccountId : 01A2B3-C4D5E6-F7G8H9
budgetId         : 8e2f1c44-7b90-4c1a-9d33-0a5e6b7c8d9e
schemaVersion    : 1.0
```

Semántica crítica del suscriptor:

- `alertThresholdExceeded` está presente **solo** cuando se cruzó un umbral de `CURRENT_SPEND`; `forecastThresholdExceeded` aparece para `FORECASTED_SPEND`. En las actualizaciones rutinarias llegan mensajes **sin ninguno** de los dos campos — tu handler debe no hacer nada en esos casos.
- La entrega es al-menos-una-vez. El handler debe ser idempotente.
- El payload **no** identifica el proyecto. Resolvelo desde `budgetId` vía la Budgets API, o codificalo en el `displayName` del presupuesto (como arriba).

### 4.4 El kill switch — Cloud Run function (Python, gen2)

Este es el único corte duro automatizado disponible en la capa de facturación, y es genuinamente destructivo: desvincular la facturación termina las VMs, hace inaccesibles los buckets y puede causar **pérdida irreversible de datos**. Desplegalo **solo** contra proyectos sandbox/dev, nunca contra producción.

```python
# functions/budget_killswitch/main.py
"""Disable Cloud Billing on a target project when a budget threshold is crossed.

DESTRUCTIVE. Unlinking the billing account stops all billable resources in the
project and may cause permanent data loss. Guarded by:
  * an allowlist of project IDs (PROTECTED projects can never be unlinked),
  * a minimum threshold below which we only log,
  * a dry-run mode that is the DEFAULT.
"""

from __future__ import annotations

import base64
import json
import logging
import os

import functions_framework
from googleapiclient import discovery
from googleapiclient.errors import HttpError

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("budget-killswitch")

# Comma-separated project IDs that MAY be unlinked. Empty => nothing may be.
ALLOWLIST: set[str] = {
    p.strip() for p in os.environ.get("KILLSWITCH_ALLOWLIST", "").split(",") if p.strip()
}
# Fraction of budget above which we act, e.g. "1.2" == 120%.
ACTION_THRESHOLD: float = float(os.environ.get("KILLSWITCH_THRESHOLD", "1.2"))
# Default TRUE. Must be explicitly set to "false" to actually unlink.
DRY_RUN: bool = os.environ.get("KILLSWITCH_DRY_RUN", "true").lower() != "false"

_billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
_budgets = discovery.build("billingbudgets", "v1", cache_discovery=False)


def _project_ids_for_budget(billing_account_id: str, budget_id: str) -> list[str]:
    """Resolve the budget's filtered projects. Budget filters store project NUMBERS."""
    name = f"billingAccounts/{billing_account_id}/budgets/{budget_id}"
    budget = _budgets.billingAccounts().budgets().get(name=name).execute()
    refs = budget.get("budgetFilter", {}).get("projects", [])
    crm = discovery.build("cloudresourcemanager", "v3", cache_discovery=False)
    ids = []
    for ref in refs:  # "projects/123456789012"
        number = ref.split("/")[-1]
        proj = crm.projects().get(name=f"projects/{number}").execute()
        ids.append(proj["projectId"])
    return ids


def _billing_enabled(project_id: str) -> bool:
    info = _billing.projects().getBillingInfo(name=f"projects/{project_id}").execute()
    return bool(info.get("billingEnabled", False))


def _disable_billing(project_id: str) -> dict:
    """Unlink by setting billingAccountName to the empty string."""
    return (
        _billing.projects()
        .updateBillingInfo(name=f"projects/{project_id}", body={"billingAccountName": ""})
        .execute()
    )


@functions_framework.cloud_event
def handle_budget_notification(cloud_event) -> None:
    attrs = cloud_event.data["message"].get("attributes", {})
    raw = cloud_event.data["message"].get("data")
    payload = json.loads(base64.b64decode(raw).decode("utf-8")) if raw else {}

    budget_name = payload.get("budgetDisplayName", "<unknown>")
    exceeded = payload.get("alertThresholdExceeded")  # None on routine updates
    cost = payload.get("costAmount")
    limit = payload.get("budgetAmount")

    # Routine budget update, no CURRENT_SPEND threshold crossed. No-op.
    if exceeded is None:
        log.info("budget=%s routine update cost=%s limit=%s — no action", budget_name, cost, limit)
        return

    if float(exceeded) < ACTION_THRESHOLD:
        log.warning(
            "budget=%s crossed %.0f%% (cost=%.2f limit=%.2f) — below action threshold %.0f%%",
            budget_name, float(exceeded) * 100, cost, limit, ACTION_THRESHOLD * 100,
        )
        return

    billing_account_id = attrs.get("billingAccountId")
    budget_id = attrs.get("budgetId")
    if not (billing_account_id and budget_id):
        log.error("budget=%s missing routing attributes; cannot resolve projects", budget_name)
        return

    try:
        targets = _project_ids_for_budget(billing_account_id, budget_id)
    except HttpError as exc:
        log.error("budget=%s failed to resolve projects: %s", budget_name, exc)
        return

    if not targets:
        log.error("budget=%s has no project filter — refusing to act on a whole billing account",
                  budget_name)
        return

    for project_id in targets:
        if project_id not in ALLOWLIST:
            log.critical(
                "budget=%s at %.0f%% but project=%s is NOT in the kill-switch allowlist. "
                "PAGE A HUMAN.", budget_name, float(exceeded) * 100, project_id,
            )
            continue

        if not _billing_enabled(project_id):
            log.info("project=%s billing already disabled — idempotent no-op", project_id)
            continue

        if DRY_RUN:
            log.critical("DRY RUN: would unlink billing from project=%s (budget=%s at %.0f%%)",
                         project_id, budget_name, float(exceeded) * 100)
            continue

        try:
            _disable_billing(project_id)
            log.critical("UNLINKED billing from project=%s (budget=%s cost=%.2f limit=%.2f)",
                         project_id, budget_name, cost, limit)
        except HttpError as exc:
            log.error("project=%s unlink FAILED: %s", project_id, exc)
```

```python
# functions/budget_killswitch/requirements.txt
functions-framework==3.*
google-api-python-client==2.*
```

Despliegue — notá que la service account necesita `roles/billing.projectManager` **sobre el proyecto destino** y `roles/billing.viewer` sobre la cuenta de facturación:

```bash
$ gcloud iam service-accounts create budget-killswitch \
    --project=fin-billing-prd-01 \
    --display-name="Budget kill switch (sandbox only)"
Created service account [budget-killswitch].

$ gcloud beta billing accounts add-iam-policy-binding 01A2B3-C4D5E6-F7G8H9 \
    --member='serviceAccount:budget-killswitch@fin-billing-prd-01.iam.gserviceaccount.com' \
    --role='roles/billing.viewer'
Updated IAM policy for billing account [01A2B3-C4D5E6-F7G8H9].

$ gcloud projects add-iam-policy-binding eng-sandbox-01 \
    --member='serviceAccount:budget-killswitch@fin-billing-prd-01.iam.gserviceaccount.com' \
    --role='roles/billing.projectManager' --condition=None
Updated IAM policy for project [eng-sandbox-01].

$ gcloud functions deploy budget-killswitch \
    --gen2 \
    --project=fin-billing-prd-01 \
    --region=us-central1 \
    --runtime=python312 \
    --source=./functions/budget_killswitch \
    --entry-point=handle_budget_notification \
    --trigger-topic=cloud-billing-budget-alerts \
    --service-account=budget-killswitch@fin-billing-prd-01.iam.gserviceaccount.com \
    --set-env-vars='KILLSWITCH_ALLOWLIST=eng-sandbox-01,KILLSWITCH_THRESHOLD=1.2,KILLSWITCH_DRY_RUN=true' \
    --max-instances=3 \
    --no-allow-unauthenticated

Preparing function...done.
Updating function (may take a while)...
  [Build] done
  [Service] done
  [Trigger] done
Done.
You can view your function in the Cloud Console here:
https://console.cloud.google.com/functions/details/us-central1/budget-killswitch?project=fin-billing-prd-01

state: ACTIVE
updateTime: '2026-09-09T11:42:07.318Z'
```

Probalo sin esperar un evento de presupuesto real:

```bash
$ PAYLOAD=$(printf '%s' '{
  "budgetDisplayName":"budget-cc-9002-monthly",
  "alertThresholdExceeded":1.2,
  "costAmount":7231.44,
  "costIntervalStart":"2026-09-01T00:00:00Z",
  "budgetAmount":6000.0,
  "budgetAmountType":"SPECIFIED_AMOUNT",
  "currencyCode":"USD"}' | base64 -w0)

$ gcloud pubsub topics publish cloud-billing-budget-alerts \
    --project=fin-billing-prd-01 \
    --message="$(echo "$PAYLOAD" | base64 -d)" \
    --attribute=billingAccountId=01A2B3-C4D5E6-F7G8H9,budgetId=8e2f1c44-7b90-4c1a-9d33-0a5e6b7c8d9e,schemaVersion=1.0
messageIds:
- '12894471029371883'

$ gcloud functions logs read budget-killswitch --gen2 --region=us-central1 --limit=5
LEVEL  NAME               TIME_UTC                 LOG
       budget-killswitch  2026-09-09 11:44:12.881  CRITICAL:budget-killswitch:DRY RUN: would unlink billing from project=eng-sandbox-01 (budget=budget-cc-9002-monthly at 120%)
```

---

## 5. Capa 1: cuotas y Organization Policy — los únicos cortes duros reales

### 5.1 Cuotas

| Tipo de cuota | Mide | Ejemplo | Utilidad para control de costos |
|---|---|---|---|
| **Cuota de tasa** | Solicitudes por ventana de tiempo, se reinicia automáticamente | `compute.googleapis.com/read_requests` — 20.000/min | Indirecta: acota el gasto impulsado por la API y los bucles de control descontrolados |
| **Cuota de asignación** | Recursos concurrentes retenidos, sin reinicio automático | `CPUS_ALL_REGIONS`, `N2_CPUS` por región, `SSD_TOTAL_GB`, `IN_USE_ADDRESSES` | **Directa y dura.** El techo de cuánta infraestructura puede existir |
| **Cuota personalizada / override de consumidor** | Límite fijado por el consumidor por debajo del default de Google | `QueryUsagePerDay` de BigQuery por proyecto o por usuario | La barrera canónica para BigQuery on-demand |

Una **cuota de asignación reducida es lo más parecido a un tope de gasto que tiene Google Cloud**, porque acota la cantidad de unidades de recurso facturables que pueden existir simultáneamente. El trade-off es explícito y severo:

| | Cuota reducida | Alerta de presupuesto |
|---|---|---|
| Detiene el sobregasto | Sí, de forma síncrona | No |
| Superficie de fallo | `RESOURCE_EXHAUSTED` / HTTP 429 al crear recursos | Email/page |
| Radio de impacto | **Bloquea el autoescalado y el failover** — una evacuación regional que necesita 3× de capacidad será denegada | Ninguno |
| Tiempo de recuperación | Solicitud de aumento de cuota, de minutos a días | N/A |
| Ubicación correcta | Proyectos sandbox, dev, CI; techos por región en prod fijados muy por encima del pico + margen de failover | En todas partes |

**Nunca fijes una cuota de prod en la utilización pico.** Dimensionala en `pico × factor_de_failover × margen_de_crecimiento` — típicamente 2,5–3×. Una cuota es un disyuntor contra la creación descontrolada, no un plan de capacidad.

```bash
# Inspect current allocation quotas and usage for a region.
$ gcloud compute regions describe us-central1 \
    --project=eng-sandbox-01 \
    --format="table(quotas.metric, quotas.usage, quotas.limit)" \
  | head -20
METRIC                     USAGE   LIMIT
CPUS                       48.0    1000.0
DISKS_TOTAL_GB             4200.0  102400.0
IN_USE_ADDRESSES           6.0     56.0
LOCAL_SSD_TOTAL_GB         0.0     140000.0
N2_CPUS                    48.0    1000.0
NVIDIA_A100_GPUS           0.0     0.0
PREEMPTIBLE_CPUS           0.0     1000.0
SSD_TOTAL_GB               4200.0  102400.0
STATIC_ADDRESSES           2.0     28.0

# Cloud Quotas API: list quota info for a service.
$ gcloud alpha quotas info list \
    --service=compute.googleapis.com \
    --project=eng-sandbox-01 \
    --format="table(quotaId, metric, dimensions, details.value)" \
  | grep -i cpus | head
CPUS-per-project-region     compute.googleapis.com/cpus       {'region': 'us-central1'}  1000
N2-CPUS-per-project-region  compute.googleapis.com/n2_cpus    {'region': 'us-central1'}  1000

# Lower the sandbox CPU ceiling to a hard cost bound (~$1.4k/mo of N2 at list).
$ gcloud alpha quotas preferences create sandbox-cpu-cap \
    --project=eng-sandbox-01 \
    --service=compute.googleapis.com \
    --quota-id=CPUS-per-project-region \
    --preferred-value=32 \
    --dimensions=region=us-central1 \
    --justification="Cost guardrail: sandbox hard ceiling, approved CAB-2026-0417"
Created quota preference [sandbox-cpu-cap].
name: projects/eng-sandbox-01/locations/global/quotaPreferences/sandbox-cpu-cap
quotaConfig:
  preferredValue: '32'
  stateDetail: Quota decrease applied.
reconciling: false
```

Cómo se ve exceder una cuota en la API — la señal que verá tu guardia:

```bash
$ gcloud compute instances create burst-worker-0042 \
    --project=eng-sandbox-01 --zone=us-central1-a --machine-type=n2-standard-16
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Quota 'CPUS' exceeded.  Limit: 32.0 in region us-central1.
   metric name = compute.googleapis.com/cpus
   limit name  = CPUS-per-project-region
   limit       = 32.0
   dimensions  = region: us-central1
```

Cuota personalizada de BigQuery on-demand — un techo diario de bytes escaneados por proyecto, posiblemente la barrera de costo con mayor ROI de toda la plataforma:

```bash
$ gcloud alpha services quota update \
    --service=bigquery.googleapis.com \
    --consumer=projects/analytics-prd-01 \
    --metric=bigquery.googleapis.com/quota/query/usage \
    --unit='1/d/{project}' \
    --value=51200          # 51,200 GiB = 50 TiB scanned per day, project-wide
Updated consumer quota override.
name: services/bigquery.googleapis.com/projects/847100294411/consumerQuotaMetrics/bigquery.googleapis.com%2Fquota%2Fquery%2Fusage/limits/%2Fd%2Fproject/consumerOverrides/Cl9QUk9KRUNU
overrideValue: '51200'
unit: 1/d/{project}
```

Guarda a nivel de consulta, que corresponde en toda consulta programada y en todo job de CI:

```bash
$ bq query --use_legacy_sql=false --maximum_bytes_billed=1099511627776 \
  'SELECT user_id, COUNT(*) FROM `analytics-prd-01.events.raw` GROUP BY 1'
Error in query string: Query exceeded limit for bytes billed: 1099511627776.
414284591104000 or higher required.
```

Ese error cuesta **$0.00** — el job se rechaza antes de escanear. Sin el flag, esa consulta escanea ~377 TiB y factura aproximadamente $2.350 a la tarifa on-demand. Este único flag es la diferencia.

### 5.2 Organization Policy — barreras preventivas

Las restricciones de Org Policy se evalúan en el momento de crear/actualizar el recurso, se heredan hacia abajo en la jerarquía y no pueden ser sorteadas por IAM a nivel de proyecto. Son el lugar donde las decisiones arquitectónicas de costo se aplican en vez de documentarse.

Restricciones integradas relevantes para el costo:

| Restricción | Tipo | Efecto en el costo |
|---|---|---|
| `constraints/gcp.resourceLocations` | Lista | Confina los recursos a regiones aprobadas — bloquea despliegues accidentales en regiones de precio premium y el egress entre regiones |
| `constraints/compute.vmExternalIpAccess` | Lista | Sin IPs externas → fuerza el egress a través de Cloud NAT/proxies, donde es observable y limitable |
| `constraints/gcp.restrictServiceUsage` | Lista | Lista blanca de qué APIs pueden habilitarse — evita que un equipo active unilateralmente un servicio administrado caro |
| `constraints/compute.disableGlobalLoadBalancing` | Booleana | Bloquea el LB global premium en entornos que solo necesitan regional |
| `constraints/compute.restrictCloudNATUsage` | Lista | Restringe dónde se puede crear NAT (un SKU con costo por hora + por GB) |
| `constraints/compute.storageResourceUseRestrictions` | Lista | Restringe qué recursos de almacenamiento se pueden consumir |

Aplicadas como YAML, un archivo por política, en un repositorio de policy-as-code:

```yaml
# orgpolicy/folders/nonprod/gcp.resourceLocations.yaml
# Confine all non-prod resources to two low-cost US regions.
name: folders/554433221100/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:us-central1-locations
          - in:us-east1-locations
          - in:us-locations          # multi-region for GCS/BQ
```

```yaml
# orgpolicy/folders/nonprod/compute.vmExternalIpAccess.yaml
# No public IPs anywhere in non-prod. Removes both an attack surface and an
# uncontrolled internet-egress path.
name: folders/554433221100/policies/compute.vmExternalIpAccess
spec:
  inheritFromParent: false
  rules:
    - denyAll: true
```

```yaml
# orgpolicy/folders/nonprod/gcp.restrictServiceUsage.yaml
# Only these APIs may be enabled. Anything not listed cannot be turned on,
# so it cannot generate a line item.
name: folders/554433221100/policies/gcp.restrictServiceUsage
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - services/compute.googleapis.com
          - services/container.googleapis.com
          - services/storage.googleapis.com
          - services/bigquery.googleapis.com
          - services/run.googleapis.com
          - services/cloudbuild.googleapis.com
          - services/artifactregistry.googleapis.com
          - services/logging.googleapis.com
          - services/monitoring.googleapis.com
          - services/secretmanager.googleapis.com
          - services/iam.googleapis.com
          - services/cloudresourcemanager.googleapis.com
```

Las **restricciones personalizadas** son la forma de imponer la economía de las formas de máquina, algo que ninguna restricción integrada cubre:

```yaml
# orgpolicy/custom-constraints/restrictNonProdMachineTypes.yaml
# Define the constraint at the ORGANIZATION level (definitions are org-scoped);
# enforce it lower down with a policy binding.
name: organizations/123456789012/customConstraints/custom.restrictNonProdMachineTypes
resourceTypes:
  - compute.googleapis.com/Instance
methodTypes:
  - CREATE
  - UPDATE
condition: |
  resource.machineType.contains('/machineTypes/e2-') ||
  resource.machineType.contains('/machineTypes/t2d-') ||
  resource.machineType.contains('/machineTypes/n2-standard-2') ||
  resource.machineType.contains('/machineTypes/n2-standard-4') ||
  resource.machineType.contains('/machineTypes/n2-standard-8')
actionType: ALLOW
displayName: Non-prod cost-efficient machine types only
description: >-
  Non-production workloads may only run on E2, Tau T2D, or N2 standard shapes up
  to 8 vCPU. Memory-optimized (M1/M2/M3), accelerator-optimized (A2/A3/G2), and
  large N2/C2 shapes require an approved exception at the prod folder.
```

```yaml
# orgpolicy/custom-constraints/denyNonProdGpus.yaml
name: organizations/123456789012/customConstraints/custom.denyNonProdGpus
resourceTypes:
  - compute.googleapis.com/Instance
methodTypes:
  - CREATE
  - UPDATE
condition: "has(resource.guestAccelerators) && size(resource.guestAccelerators) > 0"
actionType: DENY
displayName: No GPUs outside the ML folder
description: >-
  Accelerators are the highest per-hour SKU family in the estate. Their use is
  confined to folders/778899001122 (ml-platform), which has its own budget,
  reservations, and Spot-first policy.
```

```yaml
# orgpolicy/folders/nonprod/custom.restrictNonProdMachineTypes.yaml
name: folders/554433221100/policies/custom.restrictNonProdMachineTypes
spec:
  rules:
    - enforce: true
```

Aplicar y verificar:

```bash
$ gcloud org-policies set-custom-constraint \
    orgpolicy/custom-constraints/restrictNonProdMachineTypes.yaml
Created custom constraint [custom.restrictNonProdMachineTypes].

$ gcloud org-policies set-policy \
    orgpolicy/folders/nonprod/custom.restrictNonProdMachineTypes.yaml
Created policy [folders/554433221100/policies/custom.restrictNonProdMachineTypes].

$ gcloud org-policies describe custom.restrictNonProdMachineTypes \
    --folder=554433221100 --effective
name: folders/554433221100/policies/custom.restrictNonProdMachineTypes
spec:
  etag: CN2y3rwGEPjK8dED
  rules:
  - enforce: true
  updateTime: '2026-09-09T12:03:44.117292Z'

# The enforcement, observed from a developer's shell:
$ gcloud compute instances create ml-scratch-01 \
    --project=eng-sandbox-01 --zone=us-central1-a \
    --machine-type=m1-ultramem-40
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Operation denied by custom org policy:
   ["customConstraints/custom.restrictNonProdMachineTypes":
    "Non-production workloads may only run on E2, Tau T2D, or N2 standard shapes
     up to 8 vCPU. Memory-optimized (M1/M2/M3), accelerator-optimized (A2/A3/G2),
     and large N2/C2 shapes require an approved exception at the prod folder."].
```

Una sola `m1-ultramem-40` dejada corriendo durante un mes cuesta aproximadamente $4.900 a precio de lista. Esta política es un cambio de dos archivos que previene esa clase de error de forma permanente, para todos los ingenieros, para siempre. Esto es lo que realmente significa "la plataforma controla el costo" — no un dashboard.

---

## 6. Capa 5: modelos de precios e ingeniería de compromisos

### 6.1 Mecanismos de descuento de Compute Engine, comparados

| Mecanismo | Descuento | Compromiso | Flexibilidad | Interrumpible | Aplica a | Cuándo usarlo |
|---|---|---|---|---|---|---|
| **Sustained Use Discount (SUD)** | Hasta ~30% (N1) / ~20% (N2, N2D, C2, C2D, M1, M2) | Ninguno — automático | Total | No | Tipos de máquina predefinidos que corren una fracción significativa del mes. **E2 y Tau T2D/T2A quedan excluidos** (ya vienen con descuento). | Dinero gratis. No hay nada que hacer. |
| **CUD basado en recursos** | Hasta ~55% de propósito general, hasta ~70% optimizadas para memoria | 1 o 3 años | Atado a **región + familia de máquina**; vCPU y memoria se compran por separado | No | Compute Engine, Cloud SQL y otros | Línea base estable de la que estás seguro, en una región de la que no te vas a mover |
| **CUD basado en gasto / flexible** | ~28% (1 año) / ~46% (3 años) para Compute Flexible CUDs; varía según el producto | 1 o 3 años, `$/hora` | **Agnóstico de familia y región** (Flexible CUD); portable entre familias de máquina | No | Compute (Flexible), Cloud Run, GKE Autopilot, Cloud SQL, Spanner, Bigtable, VMware Engine | Línea base cuya *forma* va a cambiar pero cuya *magnitud* no |
| **Reservas** | Ninguno por sí solas — **garantizan capacidad** | Se facturan se usen o no | Zonal, forma específica | No | Compute Engine | Aseguramiento de capacidad para failover/burst; combinalas con CUD para además obtener el descuento |
| **Spot VMs** | 60–91% menos que on-demand | Ninguno | Total | **Sí** — aviso de preemption de 30 s, sin tiempo máximo de ejecución | Compute Engine, node pools de GKE, Dataproc, Batch | Trabajo tolerante a fallos, con checkpoints, escalable horizontalmente |
| **Free tier** | Asignaciones mensuales siempre gratuitas especificadas | Ninguno | N/A | No | e2-micro, 5 GB de GCS, 1 TiB de consultas BQ/mes, etc. | Aprendizaje, utilidades pequeñas |

> Los porcentajes de descuento acá son representativos y varían según familia de máquina, región, plazo y moneda. Confirmá siempre contra la página de precios de Compute Engine y la Pricing Calculator antes de comprometerte.

### 6.2 La estrategia de cobertura de compromisos

El patrón maduro es una **pila de capacidad de tres niveles**:

```
                 ┌──────────────────────────────────────────┐
   Burst / batch │  Spot VMs  (60–91% off, preemptible)      │  ← elastic, cheap
                 ├──────────────────────────────────────────┤
   Variable      │  On-demand + SUD (automatic ~20–30%)      │  ← flexible buffer
                 ├──────────────────────────────────────────┤
   Baseline      │  CUD-covered (1y/3y, 28–70% off)          │  ← never idles
                 └──────────────────────────────────────────┘
```

**Nunca te comprometas al 100% del uso actual.** Apuntá la cobertura de CUD al **P10–P25 del uso horario de los últimos 90 días** — el piso por debajo del cual tu consumo genuinamente nunca baja. Un CUD sobrecomprometido factura todas las horas lo consumas o no, y no es cancelable. La asimetría es importante: subcomprometerte te cuesta un descuento perdido sobre la porción no cubierta; sobrecomprometerte te cuesta el 100% del compromiso no usado.

Calculá el piso desde la exportación de facturación:

```sql
-- Hourly vCPU-hours by machine family, last 90 days, with percentiles.
-- Commit at or below P10. Anything above P50 is variable load: leave on-demand
-- so SUD applies, or move it to Spot.
WITH hourly AS (
  SELECT
    TIMESTAMP_TRUNC(usage_start_time, HOUR) AS hour_ts,
    REGEXP_EXTRACT(sku.description, r'^(N1|N2|N2D|E2|C2|C2D|T2D|M1|M2|M3)') AS family,
    location.region AS region,
    SUM(usage.amount_in_pricing_units) AS vcpu_hours
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 92 DAY)
    AND service.description = 'Compute Engine'
    AND sku.description LIKE '%Instance Core running%'
    AND cost_type = 'regular'
  GROUP BY hour_ts, family, region
)
SELECT
  family,
  region,
  COUNT(*)                                                     AS observed_hours,
  ROUND(MIN(vcpu_hours), 1)                                    AS p0_floor,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(10)], 1)      AS p10,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(25)], 1)      AS p25,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(50)], 1)      AS p50,
  ROUND(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(95)], 1)      AS p95,
  ROUND(MAX(vcpu_hours), 1)                                    AS peak,
  ROUND(SAFE_DIVIDE(APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(10)],
                    APPROX_QUANTILES(vcpu_hours, 100)[OFFSET(95)]), 3) AS floor_to_peak_ratio
FROM hourly
WHERE family IS NOT NULL
GROUP BY family, region
HAVING observed_hours > 2000
ORDER BY p50 DESC;
```

```
+--------+-------------+----------------+----------+--------+--------+--------+--------+--------+---------------------+
| family |   region    | observed_hours | p0_floor |  p10   |  p25   |  p50   |  p95   |  peak  | floor_to_peak_ratio |
+--------+-------------+----------------+----------+--------+--------+--------+--------+--------+---------------------+
| N2     | us-central1 |           2208 |    712.0 |  844.0 |  901.0 | 1188.0 | 2410.0 | 3102.0 |               0.350 |
| N2     | europe-west1|           2208 |    204.0 |  248.0 |  266.0 |  341.0 |  702.0 |  918.0 |               0.353 |
| E2     | us-central1 |           2208 |     88.0 |  106.0 |  121.0 |  204.0 |  588.0 |  744.0 |               0.180 |
| C2     | us-central1 |           1904 |      0.0 |    0.0 |   16.0 |  144.0 |  980.0 | 1240.0 |               0.000 |
+--------+-------------+----------------+----------+--------+--------+--------+--------+--------+---------------------+
```

Leyendo esto como arquitecto: N2/us-central1 tiene un piso sólido de 844 vCPU — comprometé 800 vCPU en un CUD basado en recursos a 3 años. C2 tiene un P10 de **cero**: es puro batch. Comprometer algo en C2 sería quemar plata; esa carga de trabajo va a Spot. E2 no recibe SUD, así que su piso de 106 vCPU también es un candidato limpio para CUD.

Comprar y verificar:

```bash
$ gcloud compute commitments create cud-n2-usc1-3y-2026q3 \
    --project=checkout-prd-01 \
    --region=us-central1 \
    --plan=THIRTY_SIX_MONTH \
    --type=GENERAL_PURPOSE_N2 \
    --resources=vcpu=800,memory=3200GB
Created [https://www.googleapis.com/compute/v1/projects/checkout-prd-01/regions/us-central1/commitments/cud-n2-usc1-3y-2026q3].

$ gcloud compute commitments list --project=checkout-prd-01 \
    --format="table(name, region, plan, status, startTimestamp.date('%Y-%m-%d'), endTimestamp.date('%Y-%m-%d'))"
NAME                   REGION       PLAN              STATUS  START_TIMESTAMP  END_TIMESTAMP
cud-n2-usc1-3y-2026q3  us-central1  THIRTY_SIX_MONTH  ACTIVE  2026-09-09       2029-09-09
```

> **Habilitá el uso compartido de CUD** en la cuenta de facturación para que un compromiso comprado en un proyecto se aplique a todos los proyectos de esa cuenta. Sin eso, el compromiso queda varado en el proyecto comprador y la utilización se desploma cuando las cargas de trabajo se mueven.

Monitoreá la utilización continuamente — un CUD subconsumido es el fallo silencioso más caro de las finanzas cloud:

```sql
-- CUD utilization: are we consuming what we committed to?
SELECT
  invoice.month,
  sku.description AS sku,
  ROUND(SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE', -c.amount, 0)), 2) AS commitment_fee_paid,
  ROUND(SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT',             -c.amount, 0)), 2) AS discount_realized,
  ROUND(SAFE_DIVIDE(
    SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT', -c.amount, 0)),
    NULLIF(SUM(IF(c.type = 'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE', -c.amount, 0)), 0)), 3) AS utilization
FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`,
  UNNEST(credits) AS c
WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 120 DAY)
  AND c.type IN ('COMMITTED_USAGE_DISCOUNT', 'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE')
GROUP BY invoice.month, sku
ORDER BY invoice.month DESC, commitment_fee_paid DESC;
```

Cualquier cosa con `utilization < 0.95` sostenida durante dos meses es plata tirada y amerita una revisión de ubicación de cargas de trabajo.

---

## 7. Capa 4: Active Assist / Recommender — el bucle de optimización

Recommender es una familia de recomendadores basados en ML y heurísticas que exponen el desperdicio. Los que importan para el costo:

| ID del recomendador | Encuentra | Acción típica |
|---|---|---|
| `google.compute.instance.IdleResourceRecommender` | VMs con CPU/red casi nulas durante 14 días | Detener o eliminar |
| `google.compute.disk.IdleResourceRecommender` | Discos persistentes sin adjuntar por 15+ días | Snapshot y eliminar |
| `google.compute.address.IdleResourceRecommender` | IPs estáticas reservadas sin adjuntar (se facturan mientras están ociosas) | Liberar |
| `google.compute.image.IdleResourceRecommender` | Imágenes personalizadas sin uso | Eliminar |
| `google.compute.instance.MachineTypeRecommender` | VMs sobreaprovisionadas (rightsizing) | Reducir el tamaño |
| `google.compute.commitment.UsageCommitmentRecommender` | Oportunidades de compra de CUD | Comprar compromiso |
| `google.cloudsql.instance.IdleRecommender` | Instancias de Cloud SQL ociosas | Detener/eliminar |
| `google.cloudsql.instance.OverprovisionedRecommender` | Cloud SQL sobredimensionado | Reducir tamaño |
| `google.bigquery.table.PartitionClusterRecommender` | Tablas que se beneficiarían de particionado/clustering | Reducir bytes escaneados |
| `google.resourcemanager.projectUtilization.GeneralRecommender` | Proyectos desatendidos (sin actividad, pero facturando) | Recuperar |

```bash
$ gcloud recommender recommendations list \
    --project=analytics-prd-01 \
    --location=us-central1-a \
    --recommender=google.compute.instance.IdleResourceRecommender \
    --format="table(
        name.basename():label=ID,
        priority,
        primaryImpact.costProjection.cost.units:label=MONTHLY_USD,
        stateInfo.state,
        description)"

ID                                    PRIORITY  MONTHLY_USD  STATE   DESCRIPTION
b1f4e2a0-3c77-4a91-9c5e-88a1d2f30011  P2        -412         ACTIVE  Save cost by stopping idle VM 'legacy-etl-runner-03'.
7d90c4b1-5e12-4f88-b2a3-11c9e7f40022  P3        -186         ACTIVE  Save cost by stopping idle VM 'dashboard-poc-01'.
2c33a891-9b04-4d10-8f7c-6a2b0e5c0033  P2        -338         ACTIVE  Save cost by stopping idle VM 'spark-history-legacy'.

$ gcloud recommender recommendations describe b1f4e2a0-3c77-4a91-9c5e-88a1d2f30011 \
    --project=analytics-prd-01 --location=us-central1-a \
    --recommender=google.compute.instance.IdleResourceRecommender \
    --format="yaml(content.operationGroups, primaryImpact, associatedInsights)"
content:
  operationGroups:
  - operations:
    - action: test
      path: /status
      resource: //compute.googleapis.com/projects/analytics-prd-01/zones/us-central1-a/instances/legacy-etl-runner-03
      resourceType: compute.googleapis.com/Instance
      valueMatcher:
        matchesPattern: .*RUNNING.*
    - action: replace
      path: /status
      resource: //compute.googleapis.com/projects/analytics-prd-01/zones/us-central1-a/instances/legacy-etl-runner-03
      resourceType: compute.googleapis.com/Instance
      value: TERMINATED
primaryImpact:
  category: COST
  costProjection:
    cost:
      currencyCode: USD
      nanos: -220000000
      units: '-412'
    duration: 2592000s
```

Agregá todo el parque en vez de ir clickeando proyecto por proyecto. Exportá las recomendaciones a BigQuery vía Recommender BigQuery Export, y después:

```sql
-- Total addressable waste across the org, ranked by recommender.
SELECT
  recommender,
  COUNT(*)                                                       AS recommendation_count,
  ROUND(SUM(-(CAST(primary_impact.cost_projection.cost.units AS INT64)
              + CAST(primary_impact.cost_projection.cost.nanos AS FLOAT64)/1e9)), 2)
                                                                 AS monthly_savings_usd
FROM `fin-billing-prd-01.recommender_export.recommendations_export`
WHERE _PARTITIONDATE = CURRENT_DATE()
  AND state = 'ACTIVE'
  AND primary_impact.category = 'COST'
GROUP BY recommender
ORDER BY monthly_savings_usd DESC;
```

```
+-------------------------------------------------------------+----------------------+---------------------+
|                        recommender                          | recommendation_count | monthly_savings_usd |
+-------------------------------------------------------------+----------------------+---------------------+
| google.compute.commitment.UsageCommitmentRecommender         |                    6 |            18204.40 |
| google.compute.instance.MachineTypeRecommender               |                  114 |             7911.22 |
| google.compute.instance.IdleResourceRecommender              |                   41 |             4488.05 |
| google.compute.disk.IdleResourceRecommender                  |                  203 |             2107.66 |
| google.cloudsql.instance.OverprovisionedRecommender          |                    9 |             1844.90 |
| google.compute.address.IdleResourceRecommender               |                   77 |              554.40 |
| google.compute.image.IdleResourceRecommender                 |                   31 |              118.70 |
+-------------------------------------------------------------+----------------------+---------------------+
```

El **FinOps Hub** de la consola de Cloud Billing agrega la misma señal en una vista de oportunidades de ahorro con un total estimado, más una vista de desperdicio (recursos ociosos/subutilizados). Es la superficie correcta para arrancar una conversación con la dirección; la exportación a BigQuery es la superficie correcta para automatizar.

---

## 8. Arquitectura de costos específica por servicio

### 8.1 BigQuery: los dos modelos de precios

| | On-demand (por TiB analizado) | Editions / capacidad (slots) |
|---|---|---|
| Se factura por | Bytes **escaneados** (no devueltos) | Slot-horas reservadas/autoescaladas |
| Predictibilidad del costo | Mala — una consulta mala es ilimitada | Alta — acotada por los slots máximos de la reserva |
| Barreras | `maximum_bytes_billed`, cuota diaria personalizada, particionado/clustering | `max_slots` de la reserva, línea base del autoescalador |
| Comportamiento de concurrencia | Reparto equitativo de slots por proyecto, opaco | Explícito; las consultas hacen cola en vez de costar más |
| Mejor para | Ad-hoc/exploratorio, con picos, bajo volumen | Analítica estable, de alto volumen y predecible; cualquier cosa por encima de ~$2k/mes on-demand |
| Compromiso | Ninguno | Compromisos de slots a 1 o 3 años para más descuento |

El particionado y el clustering son el control de costos de mayor apalancamiento en BigQuery, porque on-demand factura bytes escaneados y un filtro de partición los elimina antes del escaneo:

```sql
-- Partitioned + clustered fact table with a REQUIRED partition filter.
-- require_partition_filter is the guardrail: any query without a WHERE on
-- event_date is REJECTED, not silently full-scanned.
CREATE TABLE `analytics-prd-01.events.raw_v2`
(
  event_date   DATE      NOT NULL,
  event_ts     TIMESTAMP NOT NULL,
  user_id      STRING    NOT NULL,
  session_id   STRING,
  event_type   STRING    NOT NULL,
  country      STRING,
  device       STRING,
  revenue_usd  NUMERIC,
  payload      JSON
)
PARTITION BY event_date
CLUSTER BY event_type, country, user_id
OPTIONS (
  description                     = "Raw event stream. Partition filter REQUIRED.",
  partition_expiration_days       = 400,
  require_partition_filter        = TRUE,
  labels                          = [("cost-center", "cc-2201"), ("data-class", "internal")]
);
```

```bash
# Dry run is free and tells you the bill before you pay it. Put this in CI.
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country, SUM(revenue_usd)
   FROM `analytics-prd-01.events.raw_v2`
   WHERE event_date BETWEEN "2026-09-01" AND "2026-09-07"
     AND event_type = "purchase"
   GROUP BY country'
Query successfully validated. Assuming the tables are not modified,
running this query will process 41802336768 bytes of data.
# 41.8 GB ≈ 0.039 TiB ≈ $0.24 on-demand.

# Same query without the partition filter:
$ bq query --use_legacy_sql=false --dry_run \
  'SELECT country, SUM(revenue_usd) FROM `analytics-prd-01.events.raw_v2`
   WHERE event_type = "purchase" GROUP BY country'
Error in query string: Cannot query over table
'analytics-prd-01.events.raw_v2' without a filter over column(s) 'event_date'
that can be used for partition elimination.
```

Ese rechazo evitó un escaneo de ~415 TiB (≈ $2.590) y no costó nada.

Pasate a precios por capacidad cuando on-demand se vuelva la línea dominante:

```bash
$ bq mk --project_id=analytics-prd-01 --location=US \
    --reservation --slots=500 --edition=ENTERPRISE \
    --autoscale_max_slots=1500 \
    prod-analytics
Reservation 'analytics-prd-01:US.prod-analytics' successfully created.

$ bq mk --project_id=analytics-prd-01 --location=US \
    --reservation_assignment \
    --assignee_id=analytics-prd-01 --assignee_type=PROJECT \
    --job_type=QUERY --reservation_id=prod-analytics
Assignment successfully created.
```

Con una línea base de `--slots=500` y `--autoscale_max_slots=1500`, el costo mensual queda acotado: no puede superar la tarifa de 1.500 slots sin importar qué SQL escriba nadie. Eso es un **techo duro de costo para analítica** — algo que on-demand estructuralmente no te puede dar.

### 8.2 Cloud Storage: clases, ciclo de vida, Autoclass

| Clase | Duración mínima de almacenamiento | Almacenamiento $/GB-mes (rep.) | Cargo por recuperación | Usar para |
|---|---|---|---|---|
| Standard | ninguna | ~$0,020 | ninguno | Caliente, lectura frecuente |
| Nearline | 30 días | ~$0,010 | sí, por GB | ≤ ~1 acceso/mes |
| Coldline | 90 días | ~$0,004 | mayor | ≤ ~1 acceso/trimestre |
| Archive | 365 días | ~$0,0012 | el más alto | ≤ ~1 acceso/año, cumplimiento |

*Precios representativos de la región us-central1; confirmalos en la página de precios.*

La trampa: los **cargos por eliminación temprana**. Borrar o reescribir un objeto Coldline después de 10 días igual factura el mínimo completo de 90 días. Reglas de ciclo de vida que transicionan demasiado agresivamente pueden costar más de lo que ahorran.

```json
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "SetStorageClass", "storageClass": "NEARLINE" },
        "condition": {
          "age": 30,
          "matchesPrefix": ["events/", "logs/"],
          "matchesStorageClass": ["STANDARD"]
        }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": {
          "age": 120,
          "matchesPrefix": ["events/", "logs/"],
          "matchesStorageClass": ["NEARLINE"]
        }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": {
          "age": 365,
          "matchesPrefix": ["events/", "logs/"],
          "matchesStorageClass": ["COLDLINE"]
        }
      },
      {
        "action": { "type": "Delete" },
        "condition": {
          "age": 2555,
          "matchesPrefix": ["events/", "logs/"]
        }
      },
      {
        "action": { "type": "Delete" },
        "condition": {
          "daysSinceNoncurrentTime": 14,
          "numNewerVersions": 3
        }
      },
      {
        "action": { "type": "AbortIncompleteMultipartUpload" },
        "condition": { "age": 7 }
      }
    ]
  }
}
```

```bash
$ gcloud storage buckets update gs://analytics-prd-01-events \
    --lifecycle-file=lifecycle.json
Updating gs://analytics-prd-01-events/...
  Completed 1

$ gcloud storage buckets describe gs://analytics-prd-01-events \
    --format="yaml(name, location, storageClass, autoclass, lifecycle_config)"
autoclass: null
lifecycle_config:
  rule:
  - action: {storageClass: NEARLINE, type: SetStorageClass}
    condition: {age: 30, matchesPrefix: [events/, logs/], matchesStorageClass: [STANDARD]}
  ...
location: US-CENTRAL1
name: analytics-prd-01-events
storageClass: STANDARD
```

Las dos últimas reglas importan más de lo que la gente espera: las **cargas multiparte abandonadas** y las **versiones de objeto no vigentes** son invisibles en el listado de objetos de la consola pero se facturan por completo. Son una sorpresa rutinaria de cinco cifras en buckets versionados.

Cuando los patrones de acceso son desconocidos o bimodales, **Autoclass** mueve los objetos entre clases automáticamente según el acceso real, sin cargos por eliminación temprana ni por recuperación (a cambio, cobra una tarifa de gestión por objeto):

```bash
$ gcloud storage buckets update gs://ml-datasets-prd-01 \
    --enable-autoclass --autoclass-terminal-storage-class=ARCHIVE
Updating gs://ml-datasets-prd-01/...
  Completed 1
```

### 8.3 GKE: modelo de costo y contención

| | GKE Standard | GKE Autopilot |
|---|---|---|
| Se factura | **Nodos** (costo completo de la VM, los usen los pods o no) + tarifa de gestión del clúster | **Requests de recursos de los pods** (vCPU/memoria/almacenamiento) + tarifa de gestión del clúster |
| Modo de desperdicio | Headroom de nodos sin usar, mal bin-packing | `requests` sobredeclarados |
| Palanca de costo | Cluster autoscaler, node auto-provisioning, node pools Spot, bin-packing | `requests` precisos, pods Spot, VPA |
| Predictibilidad | Impulsada por el número de nodos | Impulsada por los requests — directamente atribuible por carga de trabajo |
| Mejor cuando | Necesitás DaemonSets, cargas privilegiadas, tuning de GPU, SO personalizado | Querés que el costo sea proporcional a la demanda declarada |

Habilitá la **asignación de costos de GKE** para que el costo por namespace y por carga de trabajo aparezca en la exportación detallada de facturación:

```bash
$ gcloud container clusters update prod-usc1 \
    --project=checkout-prd-01 --region=us-central1 \
    --enable-cost-allocation
Updating prod-usc1...done.

$ gcloud container clusters describe prod-usc1 \
    --region=us-central1 --format="yaml(costManagementConfig)"
costManagementConfig:
  enabled: true
```

Después, en la exportación detallada, las filas de costo llevan `goog-k8s-cluster-name`, `goog-k8s-cluster-location`, `goog-k8s-namespace`, `goog-k8s-workload-name`, `goog-k8s-workload-type`:

```sql
SELECT
  (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-cluster-name')  AS cluster,
  (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-namespace')     AS namespace,
  (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-workload-name') AS workload,
  ROUND(SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS effective_cost
FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_resource_v1_01A2B3_C4D5E6_F7G8H9`
WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key = 'goog-k8s-namespace')
GROUP BY cluster, namespace, workload
ORDER BY effective_cost DESC
LIMIT 25;
```

Topes duros a nivel de namespace — el equivalente nativo de Kubernetes a una cuota:

```yaml
---
# k8s/namespaces/team-checkout/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-checkout
  labels:
    cost-center: cc-4417
    owner-team: checkout
    environment: prod
---
# k8s/namespaces/team-checkout/resourcequota.yaml
# Hard ceiling on what this namespace can request. On Autopilot this is
# literally a hard cost cap, because Autopilot bills requests.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-checkout-quota
  namespace: team-checkout
spec:
  hard:
    requests.cpu: "240"
    requests.memory: "960Gi"
    requests.ephemeral-storage: "2000Gi"
    limits.cpu: "480"
    limits.memory: "1920Gi"
    requests.nvidia.com/gpu: "0"
    persistentvolumeclaims: "40"
    requests.storage: "8Ti"
    count/services.loadbalancers: "4"     # each forwarding rule is a real hourly SKU
    count/services.nodeports: "0"
    pods: "400"
---
# k8s/namespaces/team-checkout/limitrange.yaml
# Defaults + bounds. Prevents both unbounded pods (no requests at all) and
# absurd single-pod requests that would consume the whole quota.
apiVersion: v1
kind: LimitRange
metadata:
  name: team-checkout-limits
  namespace: team-checkout
spec:
  limits:
    - type: Container
      default:              # becomes limits if unspecified
        cpu: "500m"
        memory: "512Mi"
        ephemeral-storage: "1Gi"
      defaultRequest:       # becomes requests if unspecified — what Autopilot bills
        cpu: "100m"
        memory: "128Mi"
        ephemeral-storage: "512Mi"
      max:
        cpu: "8"
        memory: "32Gi"
        ephemeral-storage: "50Gi"
      min:
        cpu: "10m"
        memory: "16Mi"
      maxLimitRequestRatio: # cap burst ratio: stops 100m-request/8-CPU-limit abuse
        cpu: "4"
        memory: "2"
    - type: PersistentVolumeClaim
      max:
        storage: "1Ti"
      min:
        storage: "1Gi"
```

Node pool Spot para trabajo tolerante a interrupciones en GKE Standard:

```bash
$ gcloud container node-pools create batch-spot \
    --cluster=prod-usc1 --project=checkout-prd-01 --region=us-central1 \
    --spot \
    --machine-type=n2-standard-8 \
    --enable-autoscaling --min-nodes=0 --max-nodes=60 \
    --node-labels=workload-class=batch,cost-tier=spot \
    --node-taints=cloud.google.com/gke-spot=true:NoSchedule \
    --disk-type=pd-balanced --disk-size=100
Creating node pool batch-spot...done.
```

```yaml
# k8s/workloads/etl-batch.yaml
# Only workloads that explicitly tolerate the taint land on Spot nodes,
# so a Spot preemption can never take out a latency-critical service.
apiVersion: batch/v1
kind: Job
metadata:
  name: nightly-etl
  namespace: team-checkout
  labels:
    cost-center: cc-4417
    cost-tier: spot
spec:
  parallelism: 20
  completions: 20
  backoffLimit: 12          # generous: Spot preemption counts as a failure
  template:
    metadata:
      labels:
        cost-center: cc-4417
        cost-tier: spot
    spec:
      restartPolicy: OnFailure
      terminationGracePeriodSeconds: 25   # inside the ~30s Spot preemption notice
      nodeSelector:
        cloud.google.com/gke-spot: "true"
        workload-class: batch
      tolerations:
        - key: cloud.google.com/gke-spot
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: etl
          image: us-central1-docker.pkg.dev/checkout-prd-01/apps/etl:1.14.2
          resources:
            requests:
              cpu: "2"
              memory: "6Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
          env:
            - name: CHECKPOINT_URI
              value: gs://checkout-prd-01-etl-state/nightly/
          lifecycle:
            preStop:
              exec:
                # Flush progress on the preemption signal so restart is cheap.
                command: ["/bin/sh", "-c", "/app/checkpoint.sh --flush && sleep 5"]
```

### 8.4 Egress de red — la línea de factura que nadie reclama

El egress se cobra de forma asimétrica y es invisible hasta que llega la factura.

| Tráfico | ¿Se cobra? | Notas |
|---|---|---|
| Ingress desde internet | Generalmente gratis | |
| Egress hacia internet | **Sí**, por GB, según el destino | La línea de mayor varianza |
| Egress entre zonas de una región | **Sí**, por GB | La alta disponibilidad multizona tiene un costo real de operación |
| Egress entre regiones | **Sí**, por GB, la tarifa depende del par de regiones | La replicación entre regiones no es gratis |
| Egress dentro de una zona (IP interna) | Gratis | Preferí caminos "conversadores" en la misma zona |
| Egress hacia APIs/servicios de Google en la misma región | Generalmente gratis con Private Google Access | |
| Egress de caché de Cloud CDN | Más barato que el egress de origen | La tasa de aciertos de caché es un KPI de costo |
| Egress por Cloud Interconnect / Direct Peering | Tarifa reducida | Se justifica por encima de unos pocos TB/mes |

Los **Network Service Tiers** son una palanca de costo de primer nivel: el Premium Tier enruta por el backbone de Google de punta a punta; el Standard Tier entrega el tráfico a la internet pública más cerca del origen, con una tarifa por GB menor y un rendimiento más bajo/menos consistente.

```bash
# Default a project to Standard tier for non-latency-sensitive estates.
$ gcloud compute project-info update --default-network-tier=STANDARD \
    --project=eng-sandbox-01
Updated [https://www.googleapis.com/compute/v1/projects/eng-sandbox-01].

$ gcloud compute project-info describe --project=eng-sandbox-01 \
    --format="value(defaultNetworkTier)"
STANDARD
```

Encontrá al dueño del egress no atribuido desde la exportación detallada:

```sql
SELECT
  project.id AS project_id,
  resource.name AS resource,
  sku.description AS sku,
  ROUND(SUM(usage.amount)/POW(1024,3), 1) AS gib,
  ROUND(SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS effective_cost
FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_resource_v1_01A2B3_C4D5E6_F7G8H9`
WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND (sku.description LIKE '%Egress%' OR sku.description LIKE '%Network Internet%')
  AND cost_type = 'regular'
GROUP BY project_id, resource, sku
ORDER BY effective_cost DESC
LIMIT 20;
```

### 8.5 Cloud Run: el modelo de costo dirigido por solicitudes

| Ajuste | Efecto en el costo |
|---|---|
| **CPU asignada solo durante la solicitud** (por defecto) | Pagás CPU/memoria solo mientras hay una solicitud en vuelo — el escalado a cero es genuino |
| **CPU siempre asignada** | Se factura toda la vida de la instancia; necesario para trabajo en segundo plano, más caro |
| `--min-instances=N` | N instancias facturadas 24/7 — esta es la perilla que convierte silenciosamente un servicio con escalado a cero en un costo fijo |
| `--max-instances=N` | **Un techo duro de costo.** Acota el peor caso de instancias concurrentes facturadas |
| `--concurrency=N` | Mayor concurrencia = menos instancias para el mismo tráfico = menor costo, hasta que la latencia se degrada |

```bash
$ gcloud run deploy checkout-api \
    --project=checkout-prd-01 --region=us-central1 \
    --image=us-central1-docker.pkg.dev/checkout-prd-01/apps/checkout-api:2.8.1 \
    --cpu=1 --memory=512Mi \
    --concurrency=80 \
    --min-instances=2 \
    --max-instances=200 \
    --no-cpu-boost \
    --labels=cost-center=cc-4417,environment=prod,service=checkout-api
Deploying container to Cloud Run service [checkout-api] in project [checkout-prd-01] region [us-central1]
✓ Deploying... Done.
Service [checkout-api] revision [checkout-api-00042-hqz] has been deployed and is serving 100 percent of traffic.
```

`--max-instances=200` con 1 vCPU / 512 MiB es un peor caso de costo mensual calculable. Desplegar sin eso significa que el peor caso es ilimitado — un servicio de Cloud Run bajo una tormenta de reintentos es un amplificador de gasto.

---

## 9. Verificación y diagnóstico de fallos

### 9.1 Checklist de aceptación de control de costos de la landing zone

Ejecutalo antes de declarar un entorno listo para producción. Cada línea es un comando, no una opinión.

```bash
# 1. Billing export is enabled and CURRENT (not stalled).
$ bq query --use_legacy_sql=false --format=prettyjson \
'SELECT MAX(export_time) AS latest_export,
        TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(export_time), HOUR) AS lag_hours
 FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
 WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 3 DAY)'
[{"latest_export":"2026-09-09 09:15:22.410000 UTC","lag_hours":"3"}]
# PASS if lag_hours < 24. A value > 48 means the export is broken.

# 2. Every active project is inside the expected billing account.
$ gcloud beta billing projects list --billing-account=01A2B3-C4D5E6-F7G8H9 \
    --format="table(projectId, billingEnabled)"
PROJECT_ID          BILLING_ENABLED
checkout-prd-01     True
checkout-prd-02     True
analytics-prd-01    True
eng-sandbox-01      True
fin-billing-prd-01  True

# 3. Every project has at least one budget covering it.
$ gcloud billing budgets list --billing-account=01A2B3-C4D5E6-F7G8H9 \
    --format="table(displayName, amount.specifiedAmount.units, budgetFilter.projects)"
DISPLAY_NAME              UNITS   PROJECTS
budget-cc-4417-monthly    120000  ['projects/847100294411', 'projects/847100294412']
budget-cc-2201-monthly    45000   ['projects/311882004417']
budget-cc-9002-monthly    6000    ['projects/990022114455']
budget-org-catch-all              []

# 4. The budgets service agent can actually publish to the topic.
$ gcloud pubsub topics get-iam-policy cloud-billing-budget-alerts \
    --project=fin-billing-prd-01
bindings:
- members:
  - serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com
  role: roles/pubsub.publisher
etag: BwYb3D2yQ5w=

# 5. Cost-control org policies are effective at the folder.
$ for C in gcp.resourceLocations compute.vmExternalIpAccess gcp.restrictServiceUsage; do
    echo "== $C"
    gcloud org-policies describe "$C" --folder=554433221100 --effective \
      --format="yaml(spec.rules)" 2>&1 | head -8
  done
== gcp.resourceLocations
spec:
  rules:
  - values:
      allowedValues:
      - in:us-central1-locations
      - in:us-east1-locations
      - in:us-locations
== compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
== gcp.restrictServiceUsage
spec:
  rules:
  - values:
      allowedValues:
      - services/compute.googleapis.com

# 6. Label coverage as a percentage of spend. This is THE attribution KPI.
$ bq query --use_legacy_sql=false \
'SELECT
   ROUND(100 * SAFE_DIVIDE(
     SUM(IF((SELECT value FROM UNNEST(labels) WHERE key="cost-center") IS NOT NULL, cost, 0)),
     NULLIF(SUM(cost),0)), 2) AS pct_spend_attributed
 FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
 WHERE invoice.month = FORMAT_DATE("%Y%m", DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH))
   AND cost_type = "regular"'
+----------------------+
| pct_spend_attributed |
+----------------------+
|                88.41 |
+----------------------+
# Target > 95%. 88% means ~12% of the invoice has no owner.
```

### 9.2 Runbook de diagnóstico de fallos

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| La alerta de presupuesto nunca disparó pese a un sobregasto evidente | El agente de servicio de presupuestos no tiene `roles/pubsub.publisher` sobre el topic (los presupuestos creados con Terraform no obtienen este binding automáticamente) | `gcloud pubsub topics get-iam-policy <topic>` | Agregar `serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com` como publisher |
| La alerta disparó pero nadie recibió el email | `disable_default_iam_recipients: true` sin ningún canal de Monitoring adjunto, o el canal no está verificado | `gcloud billing budgets describe <id> --format="yaml(notificationsRule)"` | Adjuntar y verificar un canal de notificación de Monitoring |
| El presupuesto muestra mucho menos gasto que la factura | El `budget_filter` excluye proyectos/servicios, o hay una discrepancia de `credit_types_treatment`, o la única clave de label del filtro excluye recursos sin etiquetar | Comparar el filtro del presupuesto contra la Cost Table del mismo período | Ampliar el filtro; mantener siempre un presupuesto catch-all sin filtros |
| A las tablas de exportación de BigQuery les faltan filas de la semana pasada | La exportación fue deshabilitada/reconfigurada; o consultaste sin poda de particiones y pegaste contra `_PARTITIONTIME` en una tabla recreada | `SELECT DATE(_PARTITIONTIME), COUNT(*) ... GROUP BY 1 ORDER BY 1` | Rehabilitar la exportación; tené en cuenta que no puede rellenar hacia atrás |
| Los totales de costo diarios siguen cambiando para días pasados | Normal — los ajustes y reexpresiones llegan durante semanas | Agrupar por `invoice.month`; revisar `adjustment_info` | Reportar las cifras finales sobre `invoice.month`, no sobre el diario móvil |
| El gasto reportado es ~30% mayor que la factura | Sumar `cost` sin agregar `credits` | Comparar `SUM(cost)` contra `SUM(cost)+SUM(credits.amount)` | Calcular siempre el costo efectivo |
| La utilización de CUD cayó tras una migración | El CUD basado en recursos está atado a región + familia de máquina; la carga de trabajo se movió | Consulta de utilización de CUD (§6.2); informe de análisis de compromisos | Habilitar el uso compartido de CUD en la cuenta de facturación; preferir CUD flexibles/basados en gasto donde la forma es volátil |
| El autoescalador dejó de agregar nodos durante un incidente | Se alcanzó el techo de una cuota de asignación (`CPUS`, `IN_USE_ADDRESSES`, `SSD_TOTAL_GB`) | `gcloud compute regions describe <region>` — comparar uso contra límite | Subir la cuota; recalcular la cuota de prod como pico × failover × margen |
| `RESOURCE_EXHAUSTED` en consultas de BigQuery fuera de horario | La cuota diaria personalizada `QueryUsagePerDay` se agotó por una consulta programada descontrolada | `gcloud alpha services quota list --service=bigquery.googleapis.com --consumer=projects/<id>` | Arreglar la consulta (filtro de partición); considerar pasar a Editions para acotar el costo sin denegación dura |
| La factura de almacenamiento crece mientras el número de objetos se mantiene | Versiones no vigentes, cargas multiparte incompletas o retención de soft-delete | `gcloud storage ls -a gs://bucket/**` contra `gcloud storage ls gs://bucket/**`; Storage Insights | Agregar reglas de ciclo de vida `numNewerVersions` / `daysSinceNoncurrentTime` / `AbortIncompleteMultipartUpload` |
| La factura de Cloud Run no es cero con tráfico cero | `--min-instances > 0` o CPU siempre asignada | `gcloud run services describe <svc> --format="yaml(spec.template.metadata.annotations)"` | Poner `--min-instances=0` donde el arranque en frío sea aceptable; usar CPU acotada a la solicitud |
| Línea grande de egress sin atribuir | Chatter entre regiones/zonas o egress a internet sin label dueño | Consulta de egress (§8.4) contra la exportación **detallada** | Colocar los servicios juntos, agregar Cloud CDN, evaluar el Standard tier, agregar Interconnect por encima de unos pocos TB/mes |
| Un proyecto desapareció / las VMs terminaron tras una alerta de presupuesto | La función kill switch se ejecutó fuera de dry-run contra un proyecto que no estaba en la allowlist | `gcloud functions logs read budget-killswitch --gen2` | Re-vincular la facturación inmediatamente: `gcloud beta billing projects link <p> --billing-account=<ba>`; restaurar datos desde snapshots; endurecer la allowlist |

Re-vinculación de emergencia tras una desvinculación accidental:

```bash
$ gcloud beta billing projects link eng-sandbox-01 \
    --billing-account=01A2B3-C4D5E6-F7G8H9
billingAccountName: billingAccounts/01A2B3-C4D5E6-F7G8H9
billingEnabled: true
name: projects/eng-sandbox-01/billingInfo
projectId: eng-sandbox-01
```

Re-vincular restaura la capacidad del proyecto de ejecutar recursos; **no** restaura los datos ya eliminados. Precisamente por eso el kill switch viene en dry-run por defecto y está limitado por allowlist a entornos no productivos.

### 9.3 Detección de anomalías de costo propia

Los presupuestos detectan *umbrales*. No detectan *cambios de forma* — un SKU nuevo que aparece, o un servicio que se triplica semana a semana manteniéndose bajo presupuesto. Agregá esto:

```sql
-- Week-over-week SKU-level anomaly detector.
-- Run daily via a scheduled query; publish results to Pub/Sub / Monitoring.
WITH daily AS (
  SELECT
    DATE(usage_start_time) AS d,
    project.id             AS project_id,
    service.description    AS service,
    sku.description        AS sku,
    SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS eff_cost
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 35 DAY)
    AND cost_type = 'regular'
  GROUP BY d, project_id, service, sku
),
stats AS (
  SELECT
    project_id, service, sku,
    AVG(IF(d BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 28 DAY)
                 AND DATE_SUB(CURRENT_DATE(), INTERVAL 8 DAY), eff_cost, NULL))    AS baseline_mean,
    STDDEV(IF(d BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 28 DAY)
                    AND DATE_SUB(CURRENT_DATE(), INTERVAL 8 DAY), eff_cost, NULL)) AS baseline_stddev,
    AVG(IF(d >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY), eff_cost, NULL))         AS recent_mean
  FROM daily
  GROUP BY project_id, service, sku
)
SELECT
  project_id, service, sku,
  ROUND(baseline_mean, 2) AS baseline_daily_usd,
  ROUND(recent_mean, 2)   AS recent_daily_usd,
  ROUND(recent_mean - IFNULL(baseline_mean, 0), 2) AS delta_daily_usd,
  ROUND(SAFE_DIVIDE(recent_mean - baseline_mean, NULLIF(baseline_stddev, 0)), 2) AS z_score,
  CASE
    WHEN baseline_mean IS NULL AND recent_mean > 50 THEN 'NEW_SKU'
    WHEN SAFE_DIVIDE(recent_mean - baseline_mean, NULLIF(baseline_stddev,0)) > 3 THEN 'SPIKE'
    ELSE 'OK'
  END AS verdict
FROM stats
WHERE recent_mean > 50
  AND (baseline_mean IS NULL
       OR SAFE_DIVIDE(recent_mean - baseline_mean, NULLIF(baseline_stddev, 0)) > 3)
ORDER BY delta_daily_usd DESC;
```

```
+------------------+----------------+-------------------------------------------+--------------------+------------------+-----------------+---------+----------+
|    project_id    |    service     |                    sku                    | baseline_daily_usd | recent_daily_usd | delta_daily_usd | z_score | verdict  |
+------------------+----------------+-------------------------------------------+--------------------+------------------+-----------------+---------+----------+
| analytics-prd-01 | BigQuery       | Analysis (on-demand)                      |             311.40 |          1204.88 |          893.48 |    9.71 | SPIKE    |
| checkout-prd-01  | Networking     | Network Internet Egress Americas to China |               NULL |           496.10 |          496.10 |    NULL | NEW_SKU  |
| ml-platform-01   | Compute Engine | Nvidia L4 GPU attached to Spot VMs        |              22.10 |           388.02 |          365.92 |   14.02 | SPIKE    |
+------------------+----------------+-------------------------------------------+--------------------+------------------+-----------------+---------+----------+
```

La fila `NEW_SKU` es la que los presupuestos estructuralmente no pueden atrapar: una línea nueva de $496/día que no va a hacer saltar un umbral mensual hasta la segunda mitad del mes.

---

## 10. Previo al despliegue: la Pricing Calculator y el TCO

El control de costos empieza antes de que exista cualquier recurso. La **Google Cloud Pricing Calculator** produce una estimación compartible y versionada para una arquitectura propuesta; el encuadre de **Total Cost of Ownership** es lo que el examen CDL espera que le articules a un stakeholder de negocio.

El argumento a nivel de negocio, en los términos que usa el examen:

| On-premises | Google Cloud |
|---|---|
| **Capex** — comprar capacidad por adelantado, depreciar en 3–5 años | **Opex** — pagar por el consumo, mensualmente |
| Aprovisionar para pico + crecimiento + fallo → sobreaprovisionamiento crónico | Aprovisionar para la demanda actual, autoescalar hasta el pico |
| La capacidad ociosa es costo hundido | La capacidad ociosa se puede liberar en la misma hora |
| El TCO incluye energía, refrigeración, espacio, renovación de hardware, personal | El TCO incluye consumo, soporte, egress y esfuerzo de ingeniería |
| Costo de un experimento fallido: una orden de compra | Costo de un experimento fallido: horas de ejecución |

El corolario que importa técnicamente: **la elasticidad convierte un problema de capacidad en un problema de gobernanza de costos.** Todo lo que hay en este tema existe porque esa conversión movió el punto de control desde el área de compras hacia la API.

Prácticas que corresponden a la revisión de diseño, antes del despliegue:

1. Modelá la arquitectura en la Pricing Calculator y adjuntá la estimación al documento de diseño.
2. Compará regiones — la misma forma tiene precios materialmente distintos entre regiones; verificá si la latencia o la residencia de datos realmente exigen la cara.
3. Compará modelos de servicio: VM vs. GKE vs. Cloud Run vs. un servicio totalmente administrado. El cómputo rara vez es la línea más grande; suelen serlo el egress, los errores de clase de almacenamiento y las instancias administradas ociosas.
4. Identificá desde el principio la **línea base comprometible** y la **fracción elástica**; decidí la división CUD/Spot en el diseño, no un año después.
5. Definí la **métrica de economía unitaria** del servicio (costo por 1.000 solicitudes, por usuario activo, por GB ingerido). El gasto absoluto no significa nada sin ella — un gasto que sube 40% mientras el costo por solicitud baja 15% es un trimestre exitoso.

```sql
-- Unit economics: effective infrastructure cost per 1,000 requests.
-- Join billing export against a Cloud Monitoring-derived request-count table.
SELECT
  b.d AS day,
  ROUND(b.eff_cost, 2)                                       AS infra_cost_usd,
  r.request_count,
  ROUND(1000 * SAFE_DIVIDE(b.eff_cost, r.request_count), 4)  AS usd_per_1k_requests
FROM (
  SELECT DATE(usage_start_time) AS d,
         SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS eff_cost
  FROM `fin-billing-prd-01.cloud_billing_export.gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9`
  WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
    AND cost_type = 'regular'
    AND EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key='service' AND value='checkout-api')
  GROUP BY d
) b
JOIN `fin-billing-prd-01.slo.checkout_api_daily_requests` r ON r.d = b.d
ORDER BY day DESC
LIMIT 30;
```

---

## 11. Síntesis enfocada en el examen

Lo que el examen Cloud Digital Leader espera que reconozcas para el objetivo 6.1:

**Las capacidades de control de costos de Google Cloud, por nombre:**

- **Jerarquía de recursos** (Organization → Folders → Projects) — la estructura que hace que el costo sea atribuible y la política heredable.
- **Cuentas de Cloud Billing** — autoservicio vs. facturadas; una cuenta de facturación financia muchos proyectos; un proyecto tiene exactamente una cuenta de facturación. Las **subcuentas de facturación** proveen facturas separadas bajo una cuenta padre (el patrón de reseller/aislamiento por unidad de negocio).
- **Roles IAM de facturación** — Billing Account Administrator, User, Viewer, Costs Manager, Project Billing Manager; ser dueño de un proyecto no confiere visibilidad de costos.
- **Presupuestos y alertas** — umbrales sobre el gasto actual *o proyectado*; email, canales de Cloud Monitoring y **Pub/Sub** para respuesta programática. **Los presupuestos alertan; no topean.**
- **Cuotas** — cuotas de tasa y de asignación; el límite duro y síncrono del consumo.
- **Restricciones de Organization Policy** — barreras preventivas (regiones permitidas, sin IPs externas, servicios permitidos, restricciones personalizadas de tipo de máquina).
- **Labels** — la primitiva de atribución que habilita showback y chargeback.
- **Informes de Cloud Billing, Cost Table, Cost Breakdown** — superficies de análisis en la consola.
- **Exportación de facturación a BigQuery** — el dataset de costos programable y autoritativo.
- **Pricing Calculator** — estimación previa al despliegue.
- **Recommender / Active Assist y el FinOps Hub** — identificación automática de recursos ociosos y sobreaprovisionados y de oportunidades de compromiso.
- **Descuentos** — Sustained Use Discounts (automáticos), Committed Use Discounts (1 o 3 años, basados en recursos o en gasto/flexibles), **Spot VMs** y el **free tier**.
- **Facturación por segundo** con un mínimo de un minuto en Compute Engine, y **tipos de máquina personalizados** — pagás por la forma que necesitás, no por la que está en la lista de precios.

**Las cuatro frases que hay que poder decir sin titubear:**

1. Google Cloud **no tiene tope duro de gasto**; los presupuestos son detección, las cuotas y Organization Policy son prevención, y desvincular la facturación es el último recurso destructivo.
2. La atribución (**jerarquía + labels**) debe diseñarse antes de que se desplieguen las cargas de trabajo, porque los datos de facturación **no son re-atribuibles retroactivamente**.
3. Los descuentos están en capas: **el SUD es automático y gratis**, el **CUD cambia flexibilidad por un 28–70% de descuento sobre una línea base comprometida**, y **Spot cambia disponibilidad por un 60–91% de descuento sobre capacidad elástica**.
4. El costo es una **responsabilidad de ingeniería compartida con una jerarquía de puntos de aplicación**, no un informe financiero mensual — que es exactamente por qué Google Cloud lo expone a través de superficies de IAM, política, cuota y API en lugar de solo a través de una factura.

---

## 12. Referencias

**Fuente primaria del examen**

- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Jerarquía de recursos, IAM y gobernanza**

- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Cloud Billing access control (IAM roles) — https://cloud.google.com/billing/docs/how-to/billing-access
- Organization Policy Service overview — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints reference — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Custom organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints
- Creating and managing labels — https://cloud.google.com/resource-manager/docs/creating-managing-labels
- Tags overview — https://cloud.google.com/resource-manager/docs/tags/tags-overview

**Facturación, presupuestos y exportación**

- Cloud Billing documentation — https://cloud.google.com/billing/docs
- Create, edit, or delete budgets and budget alerts — https://cloud.google.com/billing/docs/how-to/budgets
- Manage programmatic budget alert notifications — https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
- Manage cost or stop usage by disabling Cloud Billing — https://cloud.google.com/billing/docs/how-to/notify
- Export Cloud Billing data to BigQuery — https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- BigQuery billing export table schemas — https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables
- Cloud Billing reports — https://cloud.google.com/billing/docs/how-to/reports
- Cost table report — https://cloud.google.com/billing/docs/how-to/cost-table
- Cost breakdown report — https://cloud.google.com/billing/docs/how-to/cost-breakdown
- FinOps hub — https://cloud.google.com/billing/docs/how-to/finops-hub
- Cloud Billing Budget API — https://cloud.google.com/billing/docs/reference/budget/rest

**Cuotas**

- Working with quotas — https://cloud.google.com/docs/quotas/overview
- View and manage quotas — https://cloud.google.com/docs/quotas/view-manage
- Compute Engine resource quotas — https://cloud.google.com/compute/resource-usage
- BigQuery custom cost controls — https://cloud.google.com/bigquery/docs/custom-quotas

**Precios, descuentos y compromisos**

- Google Cloud Pricing Calculator — https://cloud.google.com/products/calculator
- Compute Engine pricing — https://cloud.google.com/compute/all-pricing
- Sustained use discounts — https://cloud.google.com/compute/docs/sustained-use-discounts
- Committed use discounts overview — https://cloud.google.com/docs/cuds
- Resource-based committed use discounts — https://cloud.google.com/compute/docs/instances/signing-up-committed-use-discounts
- Spend-based committed use discounts — https://cloud.google.com/docs/cuds-spend-based
- Spot VMs — https://cloud.google.com/compute/docs/instances/spot
- Reservations of Compute Engine zonal resources — https://cloud.google.com/compute/docs/instances/reservations-overview
- Google Cloud free program — https://cloud.google.com/free/docs/free-cloud-features

**Optimización / Active Assist**

- Recommender overview — https://cloud.google.com/recommender/docs/overview
- Recommenders reference — https://cloud.google.com/recommender/docs/recommenders
- Export recommendations to BigQuery — https://cloud.google.com/recommender/docs/bq-export/export-recommendations-to-bq

**Control de costos específico por servicio**

- BigQuery pricing — https://cloud.google.com/bigquery/pricing
- BigQuery editions and reservations — https://cloud.google.com/bigquery/docs/reservations-intro
- Control BigQuery costs — https://cloud.google.com/bigquery/docs/best-practices-costs
- Cloud Storage classes — https://cloud.google.com/storage/docs/storage-classes
- Object Lifecycle Management — https://cloud.google.com/storage/docs/lifecycle
- Autoclass — https://cloud.google.com/storage/docs/autoclass
- GKE cost optimization best practices — https://cloud.google.com/kubernetes-engine/docs/best-practices/cost-optimization
- GKE cost allocation — https://cloud.google.com/kubernetes-engine/docs/how-to/cost-allocations
- GKE Autopilot pricing — https://cloud.google.com/kubernetes-engine/pricing
- Cloud Run pricing — https://cloud.google.com/run/pricing
- All Google Cloud network pricing — https://cloud.google.com/vpc/network-pricing
- Network Service Tiers — https://cloud.google.com/network-tiers/docs/overview