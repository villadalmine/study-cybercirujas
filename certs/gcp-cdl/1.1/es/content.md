# 1.1 — Por qué y cómo la nube está revolucionando los negocios

**Certificación:** Google Cloud Digital Leader (versión de examen 2026-08-12)
**Peso en el examen:** 9.0 — tratá este objetivo como fundacional: su vocabulario se reutiliza en todas las secciones posteriores.
**Perfil del lector:** SRE / Arquitecto de Plataforma. Toda afirmación de negocio en este documento se reduce a un mecanismo de ingeniería, y todo mecanismo se reduce a un comando que podés ejecutar y a un artefacto que podés diffear.

---

## 1. Motivación: el problema de producción que la nube realmente resuelve

El examen Cloud Digital Leader enuncia el objetivo en lenguaje de negocio — "la nube está revolucionando los negocios". Esa frase sólo le sirve a un ingeniero una vez que se traduce a la falla que elimina. La falla es **la capacidad como constante de tiempo de diseño**.

### 1.1 La trampa del aprovisionamiento por pico

En un parque de colocation o on-premises, la cantidad de cómputo queda fija meses antes de que llegue el tráfico. Eso produce una cadena de restricciones acopladas:

| Restricción | Realidad on-premises | Consecuencia para el negocio |
|---|---|---|
| Plazo de aprovisionamiento | 8–16 semanas (cotización → OC → envío → rackeo → cableado → imagen → burn-in) | Una decisión de producto tomada en marzo no se puede servir hasta junio. El time-to-market lo acota la logística, no la ingeniería. |
| Insumo de dimensionamiento | Un pronóstico, hecho una sola vez, por gente que todavía no tiene el producto | El error de pronóstico se capitaliza. Te equivocás por 3–5 años. |
| Horizonte de depreciación | 3–5 años lineal | Hay que defender el hardware incluso cuando la arquitectura que lo justificaba ya está muerta. |
| Granularidad del dominio de falla | El rack, la fila, la sala, el edificio | La redundancia cuesta 2× *todo* el parque, así que en general se saltea. |
| Utilización | Típicamente 15–30 % promedio sobre una flota dimensionada al pico | 70–85 % del capital está ocioso en cualquier instante. |

Considerá una plataforma de retail cuya línea base es de 4 000 requests/segundo y cuyo pico de Black Friday es de 48 000 rps — una relación de 12×, que no tiene nada de excepcional en retail, ticketing, presentación de impuestos o medios en noche de elecciones.

Sea la capacidad de servicio por instancia de 400 rps al SLO de latencia objetivo.

```
peak fleet      = ceil(48000 / 400)         = 120 instances
baseline fleet  = ceil(4000 / 400)          =  10 instances
N+1 zone redundancy factor (3 zones, survive 1) = 1.5

on-prem procurement = 120 * 1.5             = 180 instances, owned for 5 years
utilisation         = mean(demand) / provisioned
                    ~ (10 * 1.5) / 180      = 8.3 % annualised
```

El negocio paga por 180 máquinas-año para consumir aproximadamente 15 máquinas-año de trabajo. Esa es la aritmética detrás de "la nube revolucionó los negocios": no un descuento sobre un servidor, sino la **eliminación de la multiplicación por el pico**.

### 1.2 Qué cambió realmente — cinco desplazamientos

El examen espera que describas la transformación. Describila como cinco desplazamientos mecánicos, cada uno verificable de forma independiente:

| Desplazamiento | Antes | Después | Mecanismo en Google Cloud | Cómo lo probás (§4) |
|---|---|---|---|---|
| La capacidad pasa a ser una variable de runtime | Fija en el momento de la compra | Ajustada por minuto por un lazo de control | Autoscaler de Managed Instance Group, cluster autoscaler de GKE, escalado por request de Cloud Run | `gcloud compute instance-groups managed describe` |
| El costo pasa a ser telemetría | Una factura trimestral, opaca | Un flujo de eventos por SKU, por recurso, por label | Exportación de Cloud Billing a BigQuery, facturación por segundo | `bq query` sobre la exportación de facturación |
| La confiabilidad pasa a ser un contrato más un presupuesto | "El datacenter está arriba" | SLA respaldado financieramente + SLO elegido internamente + error budget | Zonas/regiones, SLOs de Cloud Monitoring | `google_monitoring_slo` + alertas de burn-rate |
| La gravedad de los datos se invierte | Llevar los datos al cómputo que poseés | Llevar el cómputo a los datos, elásticamente, y separar storage de cómputo | BigQuery (storage/cómputo desacoplados), Cloud Storage | Contabilidad de slots/bytes de consulta |
| La seguridad pasa a ser una responsabilidad compartida y *documentada* | Implícita, por equipo, sin documentar | Frontera explícita por modelo de servicio + cifrado por defecto en reposo y en tránsito | Modelo de responsabilidad compartida / destino compartido, org policy, IAM | `gcloud org-policies describe` |

> **Encuadre de examen.** El examen CDL llama a este conjunto *transformación digital*: usar datos y tecnología para cambiar cómo opera una organización y cómo entrega valor, no meramente para reubicar servidores existentes. La reubicación sin cambio es *lift-and-shift* / *rehost* — un primer paso válido, explícitamente **no** una transformación.

### 1.3 La reformulación económica: CapEx → OpEx y TCO

| Dimensión | Modelo CapEx (poseer el hardware) | Modelo OpEx (consumir un servicio) |
|---|---|---|
| Flujo de caja | Gran desembolso inicial, depreciado | Medido, mensual, proporcional al uso |
| Unidad de facturación | El activo | vCPU-segundo, GiB-mes, request, byte escaneado |
| Riesgo de equivocarse | Capital inmovilizado, retenido por años | Un ciclo de facturación |
| Visibilidad financiera | Centro de costo, asignado por heurística |Atribuible por label/proyecto/servicio |
| Modo de falla | Caída por sub-aprovisionamiento, o desperdicio por sobre-aprovisionamiento | **Gasto sin límite** — el nuevo modo de falla |
| Quién es responsable | Compras / finanzas | El equipo de ingeniería dueño del label |

Total Cost of Ownership (TCO) es el término que usa el examen. El punto de ingeniería es que el TCO on-premises contiene términos que nunca aparecen en una factura y que por lo tanto se subcontabilizan sistemáticamente: energía y refrigeración, espacio de datacenter, contratos de tránsito de red, refresco de hardware, inventario de repuestos, mano de obra de planificación de capacidad, seguridad física, desmantelamiento y disposición, y el costo de oportunidad de los ingenieros haciendo todo eso en lugar de sacar producto. Google publica esto como *undifferentiated heavy lifting*; la literatura de SRE llama a esa misma cantidad **toil**.

El contrapunto honesto, que un ingeniero Principal debe enunciar: **la nube no reduce el costo automáticamente.** Convierte un riesgo de *capacidad* en un riesgo de *gasto*. Un autoscaler mal configurado con `maxReplicas: 5000`, un escaneo de BigQuery sin límite, o una réplica multi-región olvidada van a producir una factura que ningún proceso de compras habría aprobado jamás. Las secciones 3 y 5 existen por esto.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Las cinco características esenciales (NIST SP 800-145) mapeadas a mecanismos

La definición de cloud computing del examen CDL deriva del NIST. Cada característica abstracta corresponde a una superficie de control concreta:

| Característica NIST | Significado llano | Mecanismo en Google Cloud | Prueba observable |
|---|---|---|---|
| On-demand self-service | Ningún humano en el camino de aprovisionamiento | Resource Manager + IAM + API | `gcloud compute instances create` retorna en segundos, sin ticket |
| Broad network access | Alcanzable sobre protocolos estándar | VPC global, Cloud Load Balancing con una única VIP anycast global | Una IP resuelve en todas las regiones |
| Resource pooling | Multi-tenant, con la ubicación abstraída | Regiones/zonas, SDN Andromeda, live migration | Mantenimiento del host sin downtime de la instancia |
| Rapid elasticity | Crece y **se achica** automáticamente | Autoscalers (MIG, GKE, Cloud Run) | La cantidad de réplicas sigue a la carga, en ambos sentidos |
| Measured service | Medido, reportable, atribuible | Facturación por segundo, exportación de facturación, labels | Filas por SKU en BigQuery |

La distinción que el examen evalúa: **escalabilidad** es la capacidad de crecer; **elasticidad** es la capacidad de crecer *y achicarse automáticamente en respuesta a la demanda*. On-premises puede ser escalable. Sólo un sistema medido, dirigido por API y agrupado (pooled) puede ser elástico — porque achicarse tiene que devolver dinero.

### 2.2 Modelos de servicio: control versus toil

| | Colo / on-prem | IaaS (Compute Engine) | Contenedores (GKE Standard) | Contenedores (GKE Autopilot) | PaaS/Serverless (Cloud Run) | FaaS (Cloud Run functions) | Datos totalmente gestionados (BigQuery) |
|---|---|---|---|---|---|---|---|
| Vos gestionás | Todo | SO, runtime, app | SO del nodo, workloads | Workloads | Imagen del contenedor | Código fuente de la función | Consulta + esquema |
| Unidad de facturación | Activo + energía | vCPU/RAM-segundo (mín. 1 min) | Nodo-segundos | vCPU/RAM-segundos de Pod | Request + vCPU/RAM-segundo | Invocación + GB-s | Bytes escaneados u horas de slot |
| Latencia de scale-out | Semanas | 30–60 s (imagen tibia) | 60–120 s (alta de nodo) | ~60 s | 0,1–3 s (cold start) | 0,1–2 s | Instantánea (slots) |
| Scale-to-zero | No | No | No (piso de nodos) | Casi | **Sí** (`minScale: 0`) | Sí | Sí |
| Dominio de falla que poseés | Rack/sala | Zona (elegís la dispersión) | Zona/región | Región | Región (gestionada) | Región | Opción multi-región |
| Toil indiferenciado | Máximo | Alto | Medio | Bajo | Muy bajo | Muy bajo | Mínimo |
| Costo de salida / portabilidad | N/A | Bajo (imágenes de VM) | Bajo (OCI + API de K8s) | Bajo–medio | Medio (la API de Knative ayuda) | Medio–alto | Alto (dialecto SQL + gravedad de datos) |
| Mejor encaje | Workload fijo regulado | Legacy, licenciado, dependiente del kernel | Plataformas complejas, scheduling custom | Microservicios estándar | HTTP sin estado, con picos | Pegamento de eventos | Analítica a escala |

**Trade-off a internalizar:** bajar por esta tabla decrece monótonamente el toil y aumenta monótonamente el acoplamiento al plano de control de un proveedor. La respuesta arquitectónica correcta no es "siempre serverless"; es "pagá por control sólo donde el control produce valor diferenciado".

### 2.3 Modelos de despliegue: público, híbrido, multicloud

El examen exige que los diferencies y que enuncies una razón válida para cada uno.

| Modelo | Definición | Impulsores legítimos | Costos reales | Productos de Google Cloud |
|---|---|---|---|---|
| Nube pública | Todos los workloads sobre la infraestructura de un proveedor | Máxima elasticidad, mínimo toil, iteración más rápida | Dependencia del proveedor; economía del egreso | Plataforma completa |
| Nube privada | Autoservicio tipo nube sobre infraestructura dedicada | Residencia de datos, latencia a sistemas de planta, hardware ya invertido | Seguís siendo dueño de la planificación de capacidad | Google Distributed Cloud |
| Híbrida | Pública + privada, conectadas deliberadamente, workloads repartidos por restricción | Migración en curso; anclaje de mainframe/ERP; el regulador exige datos en suelo local; latencia de planta sub-5 ms | Dos planos de control, dos modelos de seguridad, la WAN como dependencia dura | Cloud VPN, Cloud Interconnect, GKE Enterprise (fleets), Google Distributed Cloud, VMware Engine |
| Multicloud | Dos o más proveedores públicos | Poder de negociación con el proveedor, mandato jurisdiccional/regulatorio, adquisición, capacidad específica de un proveedor | Arquitectura de mínimo común denominador, herramientas y habilidades duplicadas, egreso entre nubes, superficie de guardia duplicada | GKE Enterprise multi-cluster, BigQuery Omni, Cloud Interconnect |

**La advertencia del arquitecto que el examen no te va a dar:** multicloud usado como *póliza de seguro de portabilidad* suele ser un neto negativo. Fuerza a cada servicio a bajar hasta la intersección de las capacidades de todos los proveedores — exactamente los servicios gestionados que producen la elasticidad de §1. Multicloud se justifica por una *restricción* (ley, contrato, adquisición, una capacidad que existe en un solo lugar), rara vez por una *preferencia*.

### 2.4 Geografía: zonas, regiones, y qué compra realmente el SLA

| Construcción | Definición | Falla independiente de | Latencia típica entre ellas |
|---|---|---|---|
| Zona | Un área de despliegue dentro de una región; un dominio de falla aislado (energía, refrigeración, red) | Eventos de energía/hardware/rack | < 1 ms intra-zona |
| Región | ≥ 3 zonas en una misma metrópolis | Eventos a nivel de zona, no eventos metropolitanos | ~1–2 ms entre zonas |
| Multi-región | Datos replicados entre regiones | Eventos metropolitanos/geográficos | 10–150 ms, dependiente del continente |

Objetivos de disponibilidad, expresados como error budget mensual — la traducción SRE de un SLA:

| Objetivo | Downtime / mes de 30 días | Downtime / año |
|---|---|---|
| 99,5 % | 3 h 39 m | 1 d 19 h |
| 99,9 % ("tres nueves") | 43 m 12 s | 8 h 45 m |
| 99,95 % | 21 m 36 s | 4 h 22 m |
| 99,99 % ("cuatro nueves") | 4 m 19 s | 52 m 35 s |
| 99,999 % ("cinco nueves") | 25,9 s | 5 m 15 s |

Niveles indicativos de SLA de Google Cloud (**verificá siempre contra la página de SLA en vivo antes de citarlos a un cliente — son contractuales y cambian**):

| Servicio | Configuración | Objetivo publicado |
|---|---|---|
| Compute Engine | Instancia única | 99,9 % |
| Compute Engine | Instancias en ≥ 2 zonas detrás de un load balancer | 99,99 % |
| GKE | Plano de control de cluster zonal | 99,5 % |
| GKE | Plano de control de cluster regional | 99,95 % |
| Cloud Run | Regional | 99,95 % |
| Cloud Storage | Regional, clase Standard | 99,9 % |
| Cloud Storage | Multi-región / dual-región, clase Standard | 99,95 % |
| Cloud Spanner | Regional | 99,99 % |
| Cloud Spanner | Multi-región | 99,999 % |

Dos propiedades de un SLA que los ingenieros suelen leer mal, y que separan a un Digital Leader de un resumen de marketing:

1. **Un SLA es un esquema de reembolso, no una garantía de confiabilidad.** El remedio es un crédito de servicio — un porcentaje de la factura mensual de ese servicio. Nunca compensa los ingresos perdidos durante la caída. Diseñá para tu SLO; el SLA sólo acota la responsabilidad del proveedor.
2. **Un SLA es nulo si no cumplís sus precondiciones arquitectónicas.** La cifra de 99,99 % de Compute Engine requiere instancias en *múltiples zonas* detrás de balanceo de carga. Una única VM en una zona es contractualmente 99,9 %, diga lo que diga la presentación de marketing.

### 2.5 Mecanismos de precio — cómo el "measured service" se vuelve dinero

| Mecanismo | Qué es | Ahorro típico | Compromiso / riesgo |
|---|---|---|---|
| On-demand | Facturación por segundo, mínimo de 1 minuto | Línea base | Ninguno |
| Sustained Use Discounts (SUD) | Automático, aplicado a medida que una instancia corre una porción mayor del mes (series N, C, M; E2 excluida porque su tarifa ya lo incorpora) | hasta ~30 % | Ninguno — automático, sin acción |
| Committed Use Discounts — basados en recursos | Comprometer vCPU/RAM en una región por 1 o 3 años | ~37 % / ~55 % | Pagás lo uses o no |
| Committed Use Discounts — basados en gasto (flexibles) | Comprometer un gasto por hora entre servicios elegibles | ~28 % / ~46 % | Pagás lo uses o no |
| Spot VMs | Capacidad excedente interrumpible, aviso de terminación de 30 s, sin runtime máximo | 60–91 % | Puede desaparecer en cualquier momento |
| Autoscaling a cero | `minScale: 0` serverless | 100 % del ocio | Latencia de cold start |
| Clase de storage / Autoclass | Standard → Nearline → Coldline → Archive | hasta ~95 % sobre datos fríos | Cargos de recuperación, duraciones mínimas de almacenamiento |

**Estratificación correcta** para un parque de producción estable: comprometer (CUD) el *piso p10 medido*, autoescalar on-demand entre p10 y p95, absorber la cola y todo el batch en Spot. Comprometer al pico reproduce el error on-premises con un contrato en lugar de una orden de compra.

---

## 3. Infraestructura completa — la elasticidad como código

Lo que sigue es un conjunto coherente y desplegable. No se omite nada. En conjunto codifican todo el argumento de §1: elasticidad acotada, costo atribuible, guardrails de gasto aplicados, y un objetivo de confiabilidad declarado.

### 3.1 Terraform — proyecto gobernado con un guardrail financiero duro

```hcl
# ---------------------------------------------------------------------------
# versions.tf
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "acme-tfstate-prod"
    prefix = "platform/retail-frontend"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# variables.tf
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "Target Google Cloud project ID."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID, format XXXXXX-XXXXXX-XXXXXX."
  type        = string
}

variable "region" {
  description = "Primary region for the regional MIG."
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "Zones the regional MIG spreads across. Three zones survive one zone loss at N+1."
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-f"]
}

variable "monthly_budget_usd" {
  description = "Monthly budget ceiling used for alerting. NOTE: a budget alerts, it does not cap."
  type        = number
  default     = 5000
}

# ---------------------------------------------------------------------------
# billing.tf  --  cost becomes telemetry, and telemetry becomes an alert
# ---------------------------------------------------------------------------
resource "google_pubsub_topic" "budget_events" {
  project = var.project_id
  name    = "billing-budget-events"

  labels = {
    owner   = "platform-sre"
    purpose = "finops"
  }
}

resource "google_billing_budget" "retail_frontend" {
  billing_account = var.billing_account
  display_name    = "retail-frontend-monthly"

  budget_filter {
    projects               = ["projects/${var.project_id}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  # Actual spend thresholds.
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # Forecast threshold: fires when the month is PROJECTED to exceed the budget,
  # which is the only threshold that arrives early enough to act on.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    pubsub_topic                     = google_pubsub_topic.budget_events.id
    schema_version                   = "1.0"
    disable_default_iam_recipients   = false
  }
}

# ---------------------------------------------------------------------------
# network.tf  --  a global VPC with one regional subnet
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "retail-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "frontend" {
  project                  = var.project_id
  name                     = "retail-frontend-${var.region}"
  ip_cidr_range            = "10.20.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_health_checks" {
  project = var.project_id
  name    = "allow-gcp-health-checks"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  # Documented Google health-check probe ranges. Without these the MIG will
  # mark every backend UNHEALTHY and autohealing will recreate instances forever.
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["retail-frontend"]
}

# ---------------------------------------------------------------------------
# compute.tf  --  the elasticity mechanism itself
# ---------------------------------------------------------------------------
resource "google_compute_health_check" "frontend" {
  project             = var.project_id
  name                = "retail-frontend-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_instance_template" "frontend" {
  project      = var.project_id
  name_prefix  = "retail-frontend-"
  machine_type = "e2-standard-4"
  region       = var.region
  tags         = ["retail-frontend"]

  labels = {
    owner       = "platform-sre"
    environment = "prod"
    service     = "retail-frontend"
    cost-center = "cc-4417"
  }

  disk {
    source_image = "projects/debian-cloud/global/images/family/debian-12"
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    disk_size_gb = 50
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.frontend.id
    # No access_config block: no external IP. Egress via Cloud NAT.
  }

  scheduling {
    provisioning_model  = "STANDARD"
    automatic_restart   = true
    on_host_maintenance = "MIGRATE" # live migration: maintenance without downtime
  }

  service_account {
    email  = google_service_account.frontend.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(logger -t startup) 2>&1
    apt-get update -qq
    apt-get install -y -qq docker.io
    systemctl enable --now docker
    docker run -d --restart=always -p 8080:8080 \
      us-central1-docker.pkg.dev/${var.project_id}/apps/retail-frontend:v2.14.0
  EOT

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_account" "frontend" {
  project      = var.project_id
  account_id   = "retail-frontend"
  display_name = "Retail frontend runtime identity"
}

resource "google_compute_region_instance_group_manager" "frontend" {
  project                    = var.project_id
  name                       = "retail-frontend-mig"
  region                     = var.region
  base_instance_name         = "retail-frontend"
  distribution_policy_zones  = var.zones
  target_size                = 10 # initial; the autoscaler owns it thereafter

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.frontend.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.frontend.id
    initial_delay_sec = 300 # must exceed worst-case boot + app warm-up
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3 # >= number of zones for a regional MIG
    max_unavailable_fixed        = 0 # zero-downtime rollout
    replacement_method           = "SUBSTITUTE"
  }
}

resource "google_compute_region_autoscaler" "frontend" {
  project = var.project_id
  name    = "retail-frontend-autoscaler"
  region  = var.region
  target  = google_compute_region_instance_group_manager.frontend.id

  autoscaling_policy {
    # min = measured p10 floor; max = a DELIBERATE ceiling, not a guess.
    # 200 * e2-standard-4 is the blast radius of a runaway loop. Price it.
    min_replicas = 10
    max_replicas = 200

    # Time to wait after a new instance before its metrics are trusted.
    # Too low => oscillation. Must be >= boot + warm-up.
    cooldown_period = 120

    mode = "ON"

    cpu_utilization {
      target            = 0.6
      predictive_method = "OPTIMIZE_AVAILABILITY" # pre-warms ahead of learned demand
    }

    load_balancing_utilization {
      target = 0.8
    }

    # Scale-IN control: protects against a metric dip triggering a mass
    # shrink that cannot be undone fast enough when load returns.
    scale_in_control {
      time_window_sec = 600

      max_scaled_in_replicas {
        percent = 20
      }
    }
  }
}

# ---------------------------------------------------------------------------
# slo.tf  --  reliability declared as a measurable objective
# ---------------------------------------------------------------------------
resource "google_monitoring_custom_service" "retail_frontend" {
  project      = var.project_id
  service_id   = "retail-frontend"
  display_name = "Retail Frontend"
}

resource "google_monitoring_slo" "availability" {
  project = var.project_id
  service = google_monitoring_custom_service.retail_frontend.service_id
  slo_id  = "availability-99-9"

  display_name        = "99.9% of HTTP requests non-5xx over 28 days"
  goal                = 0.999
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      total_service_filter = join(" AND ", [
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
        "resource.type=\"https_lb_rule\"",
      ])
      bad_service_filter = join(" AND ", [
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
        "resource.type=\"https_lb_rule\"",
        "metric.label.\"response_code_class\"=\"500\"",
      ])
    }
  }
}
```

### 3.2 GKE — cluster autoscaler más autoscaler de workload

Dos lazos de control independientes. Confundirlos es el incidente de autoscaling más común en producción: el HPA agrega Pods, y el cluster autoscaler agrega Nodes para alojarlos. Si el HPA está mal configurado los Nodes nunca llegan; si se alcanza el techo del node pool los Pods quedan `Pending` para siempre.

```yaml
# deployment.yaml
# Resource REQUESTS are mandatory. The HPA computes utilisation as
# usage/request, and the cluster autoscaler bin-packs on requests.
# A Pod with no requests is invisible to both loops.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: retail-frontend
  namespace: retail
  labels:
    app: retail-frontend
    cost-center: cc-4417
spec:
  replicas: 6
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: retail-frontend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: retail-frontend
        cost-center: cc-4417
    spec:
      serviceAccountName: retail-frontend
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: retail-frontend
      containers:
        - name: app
          image: us-central1-docker.pkg.dev/acme-prod/apps/retail-frontend:v2.14.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              # No CPU limit on purpose: CFS throttling at the limit inflates
              # tail latency. Memory IS limited, because OOM is preferable to
              # a node-wide memory-pressure eviction cascade.
              memory: "1Gi"
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 5
          lifecycle:
            preStop:
              exec:
                # Drain window: let the load balancer notice NotReady before exit.
                command: ["/bin/sh", "-c", "sleep 15"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
# hpa.yaml -- the WORKLOAD control loop
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: retail-frontend
  namespace: retail
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: retail-frontend
  minReplicas: 6
  maxReplicas: 300
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "400"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0        # react to a spike immediately
      selectPolicy: Max
      policies:
        - type: Percent
          value: 100                        # allow doubling
          periodSeconds: 30
        - type: Pods
          value: 20
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 600       # shrink slowly and deliberately
      selectPolicy: Min
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
---
# pdb.yaml -- without this, a node upgrade or scale-in can remove every replica
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: retail-frontend
  namespace: retail
spec:
  minAvailable: 80%
  selector:
    matchLabels:
      app: retail-frontend
---
# resourcequota.yaml -- the namespace-level spend guardrail
apiVersion: v1
kind: ResourceQuota
metadata:
  name: retail-quota
  namespace: retail
spec:
  hard:
    requests.cpu: "300"
    requests.memory: 600Gi
    limits.memory: 900Gi
    count/deployments.apps: "40"
```

### 3.3 Cloud Run — escalar a cero, la forma más pura de elasticidad

```yaml
# service.yaml  --  deploy with: gcloud run services replace service.yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: retail-checkout
  namespace: acme-prod
  labels:
    cloud.googleapis.com/location: us-central1
    cost-center: cc-4417
  annotations:
    run.googleapis.com/ingress: internal-and-cloud-load-balancing
spec:
  template:
    metadata:
      annotations:
        # minScale 2 buys away the cold start for the latency-critical path.
        # minScale 0 would be free at idle but adds p99 cold-start latency.
        autoscaling.knative.dev/minScale: "2"
        # The financial blast radius. Choose it; do not inherit the default.
        autoscaling.knative.dev/maxScale: "1000"
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/cpu-throttling: "false"
        run.googleapis.com/startup-cpu-boost: "true"
        run.googleapis.com/vpc-access-egress: private-ranges-only
    spec:
      serviceAccountName: retail-checkout@acme-prod.iam.gserviceaccount.com
      # Requests handled simultaneously per instance. This is the single
      # biggest cost lever on Cloud Run: 80 concurrent requests on one
      # instance costs ~1/80th of 80 instances at concurrency 1.
      containerConcurrency: 80
      timeoutSeconds: 60
      containers:
        - image: us-central1-docker.pkg.dev/acme-prod/apps/retail-checkout:v3.2.1
          ports:
            - name: http1
              containerPort: 8080
          resources:
            limits:
              cpu: "2"
              memory: 1Gi
          env:
            - name: SPANNER_INSTANCE
              value: retail-prod
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: checkout-db-password
                  key: latest
          startupProbe:
            tcpSocket:
              port: 8080
            failureThreshold: 10
            periodSeconds: 3
  traffic:
    - percent: 100
      latestRevision: true
```

---

## 4. CLI: hacer observable la abstracción

### 4.1 Bootstrap e inspección del mecanismo de elasticidad

```console
$ gcloud config set project acme-prod
Updated property [core/project].

$ terraform apply -auto-approve
...
Apply complete! Resources: 14 added, 0 changed, 0 destroyed.

$ gcloud compute instance-groups managed describe retail-frontend-mig \
    --region=us-central1 \
    --format="yaml(name, targetSize, currentActions, status.isStable)"
currentActions:
  abandoning: 0
  creating: 0
  deleting: 0
  none: 10
  recreating: 0
  refreshing: 0
  restarting: 0
  verifying: 0
name: retail-frontend-mig
status:
  isStable: true
targetSize: 10
```

`status.isStable: true` es la aserción sobre la que conviene condicionar un pipeline de despliegue. Cualquier valor distinto de cero fuera de `none` significa que el grupo está en medio de una reconciliación.

### 4.2 Observando la elasticidad bajo carga real

```console
$ gcloud compute instance-groups managed list-instances retail-frontend-mig \
    --region=us-central1 \
    --format="table(name, zone.basename(), status, instanceHealth[0].detailedHealthState)" \
  | head -6
NAME                    ZONE            STATUS   DETAILED_HEALTH_STATE
retail-frontend-2k4x    us-central1-a   RUNNING  HEALTHY
retail-frontend-7bqn    us-central1-b   RUNNING  HEALTHY
retail-frontend-9wlm    us-central1-f   RUNNING  HEALTHY
retail-frontend-c3tt    us-central1-a   RUNNING  HEALTHY
retail-frontend-dz8p    us-central1-b   RUNNING  HEALTHY

$ # Load test starts here (48k rps ramp).
$ watch -n 30 'gcloud compute instance-groups managed describe \
    retail-frontend-mig --region=us-central1 --format="value(targetSize)"'

# t+00:00   10
# t+02:00   20
# t+04:00   40
# t+06:00   80
# t+08:00  124
# t+10:00  124      <- steady state at 60% CPU target
# ... load test ends ...
# t+22:00  100      <- scale_in_control: max 20% per 600s window
# t+32:00   80
# t+42:00   64
```

Leé esa traza como la respuesta al objetivo del examen. La capacidad dimensionada al pico nunca se compró. El scale-out tardó **ocho minutos**, no ocho semanas. El scale-in es deliberadamente más lento que el scale-out — la asimetría es correcta, porque quedarse chico cuesta ingresos y quedarse grande sólo cuesta dinero.

### 4.3 El costo como telemetría — consultando la exportación de facturación

```console
$ bq query --use_legacy_sql=false --format=prettyjson '
WITH daily AS (
  SELECT
    DATE(usage_start_time, "America/Argentina/Buenos_Aires") AS day,
    service.description                                      AS service,
    (SELECT value FROM UNNEST(labels) WHERE key = "service")  AS svc_label,
    SUM(cost)                                                AS gross,
    SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits
  FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_01ABCD_2EF345_6789AB`
  WHERE DATE(_PARTITIONTIME) BETWEEN "2026-08-25" AND "2026-08-31"
    AND project.id = "acme-prod"
  GROUP BY day, service, svc_label
)
SELECT day, service, svc_label,
       ROUND(gross, 2)            AS gross_usd,
       ROUND(credits, 2)          AS credits_usd,
       ROUND(gross + credits, 2)  AS net_usd
FROM daily
WHERE gross > 5
ORDER BY net_usd DESC
LIMIT 5'
Waiting on bqjob_r5b2f19d0c8a4e7f1_0000019a2c7f_1 ... (2s) Current status: DONE
[
  {
    "day": "2026-08-29",
    "service": "Compute Engine",
    "svc_label": "retail-frontend",
    "gross_usd": "1842.66",
    "credits_usd": "-503.14",
    "net_usd": "1339.52"
  },
  {
    "day": "2026-08-29",
    "service": "BigQuery",
    "svc_label": "analytics-etl",
    "gross_usd": "912.40",
    "credits_usd": "0.0",
    "net_usd": "912.40"
  },
  {
    "day": "2026-08-30",
    "service": "Compute Engine",
    "svc_label": "retail-frontend",
    "gross_usd": "701.03",
    "credits_usd": "-197.88",
    "net_usd": "503.15"
  }
]
```

La línea de crédito `-503.14` es el Sustained Use Discount más el crédito de uso comprometido aplicados automáticamente. **Esta consulta es toda la característica "measured service" hecha concreta**: costo atribuido a un día, un servicio y un label, con granularidad de recurso — justo lo que un parque on-premises estructuralmente no puede producir.

### 4.4 Active Assist — la plataforma recomendándote tu propio right-sizing

```console
$ gcloud recommender recommendations list \
    --project=acme-prod \
    --location=us-central1-a \
    --recommender=google.compute.instance.MachineTypeRecommender \
    --format="table(name.basename(), priority, primaryImpact.costProjection.cost.units, description)"
NAME                                  PRIORITY  UNITS  DESCRIPTION
b47f2c91-0e33-4f6a-9c21-7ad5e1cf88a0  P2        -41    Save cost by changing machine type from e2-standard-8 to e2-standard-4.
d90a1b74-55c8-4e12-b3ff-2c9d0e6a1177  P3        -18    Save cost by changing machine type from n2-standard-4 to n2-standard-2.

$ gcloud recommender recommendations list \
    --project=acme-prod --location=global \
    --recommender=google.cloudbilling.commitment.SpendBasedCommitmentRecommender \
    --format="value(description)"
Save $2,184.00/month by purchasing a 1-year spend-based commitment of $9.12/hour for Compute Engine.
```

### 4.5 Verificar que el guardrail existe

```console
$ gcloud billing budgets list --billing-account=01ABCD-2EF345-6789AB \
    --format="table(displayName, amount.specifiedAmount.units, thresholdRules[].thresholdPercent)"
DISPLAY_NAME              UNITS  THRESHOLD_PERCENT
retail-frontend-monthly   5000   [0.5, 0.9, 1.0, 1.0]

$ gcloud compute regions describe us-central1 \
    --flatten="quotas[]" \
    --format="table(quotas.metric, quotas.limit, quotas.usage)" \
  | grep -E "CPUS|IN_USE_ADDRESSES"
CPUS                        2400.0   496.0
CPUS_ALL_REGIONS            4800.0   612.0
IN_USE_ADDRESSES              75.0    12.0
```

Leé esto antes de un evento de pico, no durante. `max_replicas: 200 × e2-standard-4 = 800 vCPU` tiene que caber dentro de la cuota regional de `CPUS` **junto con** todo lo demás que corra en esa región. Ésta es la causa más común de un scale-out fallido.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 La checklist de preparación previa al pico

```console
$ # 1. Is the group stable and fully healthy?
$ gcloud compute instance-groups managed describe retail-frontend-mig \
    --region=us-central1 --format="value(status.isStable)"
True

$ # 2. Is the autoscaler ON, and does its ceiling fit inside quota?
$ gcloud compute region-autoscalers describe retail-frontend-autoscaler \
    --region=us-central1 \
    --format="value(autoscalingPolicy.mode, autoscalingPolicy.maxNumReplicas)"
ON      200

$ # 3. Are backends actually HEALTHY from the load balancer's point of view?
$ gcloud compute backend-services get-health retail-frontend-bes --global \
    --format="value(status.healthStatus[].healthState)" | sort | uniq -c
     10 HEALTHY

$ # 4. Does the SLO have error budget left to spend?
$ gcloud alpha monitoring slos list \
    --service=retail-frontend --project=acme-prod \
    --format="table(displayName, goal, rollingPeriod)"
DISPLAY_NAME                                        GOAL   ROLLING_PERIOD
99.9% of HTTP requests non-5xx over 28 days         0.999  2419200s
```

### 5.2 Catálogo de fallas — síntoma, mecanismo, comando

| Síntoma | Causa real | Comando de diagnóstico | Solución |
|---|---|---|---|
| El MIG no supera N instancias | Cuota regional de `CPUS` agotada | `gcloud compute operations list --filter="error.errors.code=QUOTA_EXCEEDED" --limit=5` | Pedí aumento de cuota con **días** de anticipación; no es instantáneo |
| `ZONE_RESOURCE_POOL_EXHAUSTED` al crear | Esa familia de máquina está momentáneamente no disponible en esa zona | `gcloud compute operations describe <op> --zone=<zone>` | Dispersar en ≥ 3 zonas (MIG regional); considerar una segunda familia de máquina |
| Pods atascados en `Pending`, sin nuevos Nodes | Node pool en `maxNodeCount`, o el Pod es inschedulable por una razón que el autoscaling no puede arreglar | `kubectl describe pod <p>` → buscar `pod didn't trigger scale-up` | Subir el techo del pool **o** arreglar el conflicto de affinity/taint/zona del PVC |
| El HPA muestra `<unknown>/60%` | El contenedor no tiene `resources.requests.cpu`; la utilización queda indefinida | `kubectl get hpa -n retail` | Agregar requests. Esto no es negociable para el autoscaling |
| El autoscaler oscila (flapping) | `cooldown_period` menor que boot + warm-up; métricas de instancias sin calentar | Comparar `initial_delay_sec` y `cooldown_period` contra el tiempo de boot medido | Fijar cooldown > p99 del warm-up; agregar `scale_in_control` |
| El upgrade de nodo se cuelga en el drain | Un PDB que nunca puede satisfacerse (`minAvailable` ≥ `replicas`) | `kubectl get pdb -n retail -o wide` | `ALLOWED DISRUPTIONS` debe ser ≥ 1 |
| Presupuesto excedido, ninguna alerta disparó | Sólo hay umbrales `CURRENT_SPEND` configurados; los datos tienen retraso | `gcloud billing budgets describe <id>` | Agregar una regla `FORECASTED_SPEND` |
| La alerta de presupuesto disparó, el gasto siguió | **Los budgets alertan; no ponen techo.** Por diseño | — | Aplicar con cuota, `maxScale`/`max_replicas`, `ResourceQuota`, y un kill switch disparado por Pub/Sub |
| Los jobs batch mueren al azar | Preemption de Spot VM — comportamiento esperado | `gcloud compute operations list --filter="operationType=compute.instances.preempted"` | Checkpointing; manejar el aviso `ACPI G2` de 30 s; MIG mixto Spot/Standard |
| Workload híbrido inalcanzable de forma intermitente | Un único attachment de Cloud Interconnect; sin redundancia | `gcloud compute interconnects attachments describe <a> --region=<r>` | Dos attachments en distintos edge availability domains para la topología de 99,9/99,99 % |
| El p99 de Cloud Run pega picos con poco tráfico | Cold starts con `minScale: 0` | Cloud Monitoring `run.googleapis.com/container/startup_latencies` | `minScale: >0` y `startup-cpu-boost` para los caminos críticos en latencia |

### 5.3 Reproduciendo las dos fallas más instructivas

**Autoscaling bloqueado por un resource request faltante:**

```console
$ kubectl get hpa -n retail
NAME              REFERENCE                    TARGETS              MINPODS  MAXPODS  REPLICAS  AGE
retail-frontend   Deployment/retail-frontend   <unknown>/60%, 0/400 6        300      6         14m

$ kubectl describe hpa retail-frontend -n retail | tail -6
Conditions:
  Type            Status  Reason                   Message
  ----            ------  ------                   -------
  AbleToScale     True    SucceededGetScale        the HPA controller was able to get the target's current scale
  ScalingActive   False   FailedGetResourceMetric  failed to get cpu utilization: missing request for cpu in container app of Pod retail-frontend-6d4b9c7f88-x2pql
```

`<unknown>` significa que el lazo está muerto, no ocioso. El Deployment nunca va a escalar, y el incidente se va a presentar como un burn del SLO de latencia bajo carga sin ninguna actividad de escalado en la línea de tiempo.

**Cluster autoscaler en su techo:**

```console
$ kubectl get pods -n retail --field-selector=status.phase=Pending
NAME                               READY   STATUS    RESTARTS   AGE
retail-frontend-6d4b9c7f88-4jnwq   0/1     Pending   0          3m21s
retail-frontend-6d4b9c7f88-h7ptl   0/1     Pending   0          3m21s

$ kubectl describe pod retail-frontend-6d4b9c7f88-4jnwq -n retail | tail -5
Events:
  Type     Reason             Age    From                Message
  ----     ------             ----   ----                -------
  Warning  FailedScheduling   3m10s  default-scheduler   0/48 nodes are available: 48 Insufficient cpu.
  Normal   NotTriggerScaleUp  3m05s  cluster-autoscaler  pod didn't trigger scale-up: 1 max node group size reached
```

`max node group size reached` no es un bug — es un **guardrail haciendo exactamente lo que fue configurado para hacer**. Éste es el punto decisivo de §1.3: la elasticidad sin techo es un pasivo sin límite, y un techo que se golpea durante un pico es una falla de planificación de capacidad que simplemente se movió desde compras a una variable de Terraform. La planificación no desapareció; se convirtió en una revisión de código con un lazo de feedback de dos minutos en lugar de una orden de compra con uno de doce semanas.

### 5.4 Probar la transformación cuantitativamente

Cerrá el lazo comparando la factura real contra el contrafáctico:

```console
$ bq query --use_legacy_sql=false --format=csv '
SELECT
  ROUND(SUM(cost), 2)                                   AS actual_elastic_usd,
  ROUND(MAX(peak_vcpu) * 24 * 30 * 0.0316, 2)           AS peak_provisioned_usd
FROM (
  SELECT cost,
         SUM(CAST(usage.amount AS FLOAT64)) OVER (PARTITION BY usage_start_time) AS peak_vcpu
  FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_01ABCD_2EF345_6789AB`
  WHERE service.description = "Compute Engine"
    AND sku.description LIKE "%Core running%"
    AND DATE(_PARTITIONTIME) BETWEEN "2026-08-01" AND "2026-08-31"
)'
actual_elastic_usd,peak_provisioned_usd
18442.19,71308.80
```

Aproximadamente **4×**, sobre un servicio, en un mes, sin una sola conversación con compras. Esa relación — no la tecnología — es la frase "la nube está revolucionando los negocios".

---

## 6. Destilación orientada al examen

Términos que aparecen textualmente en las preguntas de Cloud Digital Leader, con la distinción precisa que cada uno evalúa:

| Término | Significado preciso | Distractor común |
|---|---|---|
| Digital transformation | Cambiar cómo opera la organización y cómo entrega valor usando datos y tecnología | "Mover VMs a la nube" — eso es rehosting |
| Rehost (lift-and-shift) | Mover tal cual, sin re-arquitectura | Lo más rápido, con el techo de beneficio más bajo |
| Replatform (move-and-improve) | Mover con modernización puntual (p. ej. VM → base de datos gestionada) | El punto medio pragmático habitual |
| Refactor / rearchitect | Reconstruir cloud-native | Máximo beneficio, máximo costo |
| Scalability | Puede crecer | No es lo mismo que elasticidad |
| Elasticity | Crece **y se achica** automáticamente con la demanda | La que devuelve dinero |
| Agility | Velocidad de experimentación y entrega | Habilitada por el autoservicio, no por el hardware |
| CapEx → OpEx | Compra de activo fijo → consumo medido | No es automáticamente más barato |
| TCO | Todos los costos, incluidos energía, espacio, mano de obra, refresco, disposición | No sólo la factura |
| Shared responsibility | El proveedor asegura *de* la nube; vos asegurás *en* la nube; la frontera se mueve con el modelo de servicio | No es "la nube es segura" |
| Shared fate | La postura activa de Google: blueprints opinados, guardrails, protección de riesgo — yendo más allá de una línea estática de responsabilidad | Distinto de shared responsibility |
| Hybrid | Pública + privada, conectadas a propósito | No es lo mismo que multicloud |
| Multicloud | Dos o más proveedores públicos | Justificado por restricción, no por preferencia |
| Data as a competitive asset | El valor viene de actuar sobre los datos, no de almacenarlos | La razón por la que importan la analítica y la IA gestionadas |
| Sustainability | Google Cloud reporta emisiones atribuidas al cliente; la elección de región cambia el perfil de carbono | Verificable vía la exportación de Carbon Footprint |

**Tres afirmaciones que un Digital Leader debe poder defender ante un cuestionamiento:**

1. *La nube no es automáticamente más barata.* Es más barata cuando la demanda es variable, cuando la capacidad de otro modo se dimensionaría al pico, y cuando los guardrails se aplican. Un workload plano, totalmente utilizado y totalmente depreciado puede ser más barato on-premises — y decirlo es una marca de competencia, no de deslealtad.
2. *Un SLA no es un SLO.* El SLA es el esquema de reembolso del proveedor con precondiciones arquitectónicas. El SLO es tu propio objetivo, y su complemento es el error budget que gastás en cambios.
3. *La elasticidad requiere un techo.* La planificación de capacidad no desapareció; cambió de un ciclo de compras de 12 semanas a una variable revisada, versionada e instantáneamente reversible. Ese cambio en la latencia del lazo de feedback — de meses a minutos — es todo el mecanismo detrás de la palabra "revolucionando".

---

## 7. Referencias

**Definición del examen**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Definiciones de nube y guías de arquitectura**
- NIST SP 800-145, *The NIST Definition of Cloud Computing* — https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-145.pdf
- Google Cloud Well-Architected Framework — https://cloud.google.com/architecture/framework
- Cost optimization pillar — https://cloud.google.com/architecture/framework/cost-optimization
- Reliability pillar — https://cloud.google.com/architecture/framework/reliability
- Hybrid and multicloud architecture patterns — https://cloud.google.com/architecture/hybrid-multicloud-patterns
- Landing zone design — https://cloud.google.com/architecture/landing-zones

**Mecanismos de elasticidad**
- Regions and zones — https://cloud.google.com/compute/docs/regions-zones
- Managed instance groups — https://cloud.google.com/compute/docs/instance-groups
- Autoscaling groups of instances — https://cloud.google.com/compute/docs/autoscaler
- Scale-in controls — https://cloud.google.com/compute/docs/autoscaler/understanding-autoscaler-decisions
- Live migration — https://cloud.google.com/compute/docs/instances/live-migration-process
- GKE cluster autoscaler — https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler
- Horizontal Pod autoscaling in GKE — https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler
- GKE Autopilot overview — https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview
- Cloud Run autoscaling — https://cloud.google.com/run/docs/about-instance-autoscaling
- Cloud Run YAML reference — https://cloud.google.com/run/docs/reference/yaml/v1

**Costo, medición y gobernanza**
- Google Cloud pricing model — https://cloud.google.com/pricing
- Sustained use discounts — https://cloud.google.com/compute/docs/sustained-use-discounts
- Committed use discounts — https://cloud.google.com/docs/cuds
- Spot VMs — https://cloud.google.com/compute/docs/instances/spot
- Cloud Billing budgets and alerts — https://cloud.google.com/billing/docs/how-to/budgets
- Programmatic budget notifications — https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
- Billing export to BigQuery — https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- Active Assist and Recommender — https://cloud.google.com/recommender/docs/overview
- Quotas and limits — https://cloud.google.com/docs/quotas

**Confiabilidad, SLAs y SLOs**
- Google Cloud service level agreements — https://cloud.google.com/terms/sla
- Compute Engine SLA — https://cloud.google.com/compute/sla
- GKE SLA — https://cloud.google.com/kubernetes-engine/sla
- Cloud Run SLA — https://cloud.google.com/run/sla
- Service monitoring / SLOs — https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- SRE Book, *Embracing Risk* (error budgets) — https://sre.google/sre-book/embracing-risk/
- SRE Workbook, *Implementing SLOs* — https://sre.google/workbook/implementing-slos/

**Híbrido, multicloud y conectividad**
- GKE Enterprise overview — https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview
- Google Distributed Cloud — https://cloud.google.com/distributed-cloud
- Google Cloud VMware Engine — https://cloud.google.com/vmware-engine/docs/overview
- Cloud Interconnect — https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview
- BigQuery Omni — https://cloud.google.com/bigquery/docs/omni-introduction

**Modelo de seguridad y sostenibilidad**
- Shared responsibility and shared fate — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google security overview — https://cloud.google.com/docs/security/overview/whitepaper
- Carbon Footprint — https://cloud.google.com/carbon-footprint
- Carbon Footprint BigQuery export — https://cloud.google.com/carbon-footprint/docs/export

**Herramientas**
- Terraform `google_billing_budget` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/billing_budget
- Terraform `google_compute_region_autoscaler` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_region_autoscaler
- Terraform `google_monitoring_slo` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_slo