# 6.2 — Operaciones modernas, fiabilidad y resiliencia en la nube

**Certificación:** Google Cloud Digital Leader (`gcp-cdl`) · Guía de examen versión 2026-08-12
**Dominio:** Sección 6 — *Escalar con Google Cloud Operations* · **Objetivo 6.2** · **Peso en el examen: 5.0**
**Perfil de audiencia de este documento:** Platform Architect / SRE. El examen te pide *describir* estos conceptos; este material te enseña a *operarlos*, porque las descripciones sólo dejan de ser ambiguas cuando ya viste la aritmética y los modos de fallo que hay detrás.

---

## 1. Motivación: el problema arquitectónico en producción

### 1.1 La afirmación que se rompe en producción

Un equipo migra un monolito a Google Cloud. La presentación de la migración dice:

> "El SLA de Google Cloud es 99.99%, así que nuestra disponibilidad mejora de 99.5% a 99.99%."

Esta frase contiene tres errores distintos, y cada uno mapea a un concepto del examen:

1. **Un SLA no es un SLO, y ninguno de los dos es un SLI.** El SLA del proveedor es un *contrato financiero sobre un recurso específico*, no una predicción sobre *tu aplicación*.
2. **La disponibilidad se compone multiplicativamente a lo largo del camino serial de la petición**, no tomando el mejor número del stack.
3. **La redundancia sólo ayuda cuando los fallos son independientes.** La mayoría de las caídas reales están correlacionadas: una config mala, un binario malo, un certificado vencido, una cuota agotada — empujados simultáneamente a todas las réplicas.

### 1.2 La aritmética de las dependencias seriales

Tomá un camino realista de petición de checkout en Google Cloud:

```
Client
  → Cloud DNS
  → Global external Application Load Balancer (+ Cloud Armor)
  → GKE Ingress / NEG
  → checkout-api Pod
      → auth-service      (internal)
      → catalog-service   (internal)
      → pricing-service   (internal)
      → Cloud SQL (orders)
      → Memorystore (session cache)
      → Pub/Sub (event emit)
      → payment provider  (third party, egress)
```

Si cada uno de los 12 saltos está disponible independientemente al **99.9%**, y *todos* deben tener éxito para que la petición tenga éxito:

```
A_serial = 0.999 ^ 12 = 0.98807  →  98.807%
```

Indisponibilidad = 1.193% de un mes de 30 días = **8 h 35 min de downtime por mes**, a partir de componentes que individualmente "cumplen tres nueves". Nadie en la cadena incumplió su objetivo. El *user journey* falló igual.

Este es el problema central de producción que describe el objetivo: **la fiabilidad es una propiedad del user journey, no de ningún componente**, y por lo tanto debe *medirse en el user journey* y *presupuestarse*, no afirmarse a partir de los SLA del proveedor.

### 1.3 La aritmética de la redundancia — y por qué rinde menos de lo esperado

Dos réplicas de un componente al 99.9%, fallando **independientemente**, en una topología paralela (cualquiera de las dos sirve):

```
A_parallel = 1 - (0.001)^2 = 0.999999  →  six nines
```

Ahora introducí un **factor de correlación** ρ — la fracción de fallos que golpea a ambas réplicas a la vez (misma imagen mala, misma zona, mismo despliegue de configuración, misma dependencia):

| Correlación ρ | Indisponibilidad efectiva | Disponibilidad efectiva | Downtime / 30 días |
|---|---|---|---|
| 0.00 (totalmente independiente) | 1.0 × 10⁻⁶ | 99.9999% | 2.6 s |
| 0.01 | ≈ 1.1 × 10⁻⁵ | 99.9989% | 47 s |
| 0.10 | ≈ 1.0 × 10⁻⁴ | 99.99% | 4.3 min |
| 0.50 | ≈ 5.0 × 10⁻⁴ | 99.95% | 21.6 min |
| 1.00 (totalmente correlacionado) | 1.0 × 10⁻³ | 99.9% | 43.2 min |

Aproximación: `U_eff ≈ ρ·U + (1-ρ)·U²`.

**Consecuencia arquitectónica:** duplicar instancias no te compra casi nada si la duplicada comparte la causa del fallo. El trabajo de ingeniería de la resiliencia es *descorrelacionar* — repartir entre zonas y regiones, escalonar los despliegues, aislar el blast radius y descartar carga con elegancia — no simplemente aumentar la cantidad de réplicas.

### 1.4 La tabla de nueves que tenés que poder reproducir

| Disponibilidad | Downtime / mes de 30 días | Downtime / año | Construcción típica de GCP que te lleva ahí |
|---|---|---|---|
| 99% ("dos nueves") | 7 h 12 min | 3 d 15 h | VM única, best-effort |
| 99.5% | 3 h 36 min | 1 d 19 h | Despliegue zonal único, recuperación manual |
| 99.9% ("tres nueves") | 43 min 12 s | 8 h 46 min | Zona única + MIG con autohealing |
| 99.95% | 21 min 36 s | 4 h 23 min | Despliegue regional (multi-zona) |
| 99.99% ("cuatro nueves") | 4 min 19 s | 52 min 36 s | Multi-zona + LB global + failover automatizado |
| 99.999% ("cinco nueves") | 25.9 s | 5 min 15 s | Multi-región activo/activo, p. ej. Spanner multi-región |

**Lectura de esta tabla relevante para el examen:** cada nueve adicional cuesta aproximadamente un orden de magnitud más, y por encima de ~99.99% el factor limitante ya no es la infraestructura — es el *tiempo de respuesta humano*. No podés paginar a una persona y recuperarte en 25 segundos. Cinco nueves requiere failover automatizado sin humano en el bucle.

---

## 2. El vocabulario de la fiabilidad, definido con precisión

Estos cuatro términos son las definiciones de mayor rendimiento del objetivo, y se confunden rutinariamente.

### 2.1 SLI / SLO / SLA / Error Budget

| Término | Qué es | Para quién es | Expresión formal | Consecuencia de la violación |
|---|---|---|---|---|
| **SLI** — Service Level Indicator | Una *medición* del comportamiento del servicio, expresada como ratio de eventos buenos sobre eventos válidos | Ingenieros | `good_events / valid_events` sobre una ventana | Ninguna — es sólo un número |
| **SLO** — Service Level Objective | Un *objetivo interno* para un SLI sobre una ventana | Ingeniería + producto | `SLI ≥ 99.9% over 30 rolling days` | Se disparan las políticas de error budget (congelar features, priorizar trabajo de fiabilidad) |
| **SLA** — Service Level Agreement | Un *contrato externo* con remedio financiero | Clientes, legales, finanzas | `SLA target < SLO target`, más el esquema de créditos | Créditos de servicio / penalización contractual |
| **Error budget** | La no fiabilidad permitida: `1 − SLO` | Ingeniería + producto | `(1 − 0.999) × valid_events` | Agotamiento = congelamiento de cambios acordado |

**El invariante que tenés que recordar:** `SLA target  <  SLO target  ≤  achievable SLI`.
El SLO es deliberadamente *más estricto* que el SLA para que el equipo sea alertado y reaccione **antes** de que se incumpla el contrato. Un equipo que fija SLO = SLA no tiene ningún margen de reacción.

### 2.2 Tipos de SLI — los cuatro que importan

| Tipo de SLI | Definición | Buen ejemplo de especificación | Error común |
|---|---|---|---|
| **Disponibilidad** | Fracción de peticiones válidas servidas con éxito | `count(status != 5xx) / count(status != 4xx-client-fault)` | Contar los 4xx del cliente como fallos tuyos |
| **Latencia** | Fracción de peticiones válidas más rápidas que un umbral | `count(latency < 300 ms) / count(all)` | Reportar una *media*; las medias esconden la cola |
| **Calidad / corrección** | Fracción de respuestas servidas sin degradación | `count(full_result) / count(all)` | No medir en absoluto las respuestas en modo degradado |
| **Frescura / durabilidad** (datos y batch) | Fracción de datos más jóvenes que un umbral | `count(records with age < 5 min) / count(all)` | Asumir que "éxito" del pipeline == datos frescos |

**La latencia debe expresarse como un ratio de umbral, nunca como un objetivo de percentil solo.** "p99 < 300 ms" y "99% de las peticiones < 300 ms" son la misma afirmación; pero "latencia media < 300 ms" es compatible con un 5% de usuarios esperando 10 segundos. El encuadre de las Golden Signals de Google existe precisamente para forzar la visión distribucional.

### 2.3 Matemática del error budget y burn rate

Para un SLO de 99.9% sobre una ventana móvil de 30 días:

```
Error budget            = 0.1% of valid requests
Budget in wall-clock    = 0.001 × 30 d = 43 min 12 s
```

**Burn rate** es el múltiplo de la velocidad de consumo *nominal*:

```
burn_rate = (fraction of budget consumed) / (fraction of window elapsed)
```

Un burn rate de 1 agota el presupuesto exactamente al final de la ventana. Un burn rate de 14.4 lo agota en 50 horas — y consume el 2% de él en una sola hora.

| Presupuesto consumido | En tiempo transcurrido | Burn rate | Tiempo hasta el agotamiento | Acción de alerta recomendada |
|---|---|---|---|---|
| 2% | 1 hora | **14.4** | ~2 días | **Página** (ventana larga 1 h / ventana corta 5 min) |
| 5% | 6 horas | **6** | ~5 días | **Página** (larga 6 h / corta 30 min) |
| 10% | 3 días | **1** | 30 días | **Ticket** (larga 3 d / corta 6 h) |
| 10% | 1 hora | 72 | ~10 horas | Página — clase de caída total |

**El alertado multi-ventana y multi-burn-rate** es la técnica que hace esto accionable, y es lo que implementás en §5:

* la **ventana larga** da precisión (no se dispara por un parpadeo de 15 segundos);
* la **ventana corta** (convencionalmente 1/12 de la larga) da *velocidad de reseteo* — impide que la alerta quede enganchada durante horas después de que el incidente terminó;
* ambas condiciones deben ser verdaderas simultáneamente (combinador `AND`).

| Estrategia de alertado | Tiempo de detección | Tasa de falsos positivos | Tiempo de reseteo | Veredicto |
|---|---|---|---|---|
| Umbral sobre la tasa de error cruda (`errors > 10/s`) | Rápido | Muy alta (escala con el tráfico) | Rápido | Rechazada: no centrada en el usuario, sin semántica de presupuesto |
| Ventana larga única sobre el consumo de presupuesto | Lento | Baja | Muy lento (enganchada) | Rechazada: la alerta sigue disparada después de la recuperación |
| Ventana corta única | Muy rápido | Alta | Rápido | Rechazada: paginación en cada parpadeo |
| **Multi-ventana multi-burn-rate** | Rápido para lo severo, lento para lo leve | Baja | Rápido | **Estándar adoptado** |

---

## 3. Operaciones modernas: DevOps, SRE e ingeniería de plataforma

### 3.1 Los tres modelos operativos comparados

| Dimensión | Ops tradicional (en silos) | DevOps | SRE (tal como lo practica Google) |
|---|---|---|---|
| Premisa central | El cambio es riesgo; minimizar el cambio | Propiedad compartida de la entrega | La fiabilidad es una *feature*, diseñada con datos |
| Quién opera producción | Equipo de ops separado | "You build it, you run it" | El equipo de ingeniería, con SRE como socio especialista |
| Estabilidad vs. velocidad | Planteado como un trade-off | Planteado como mutuamente reforzantes | **Arbitrado numéricamente por el error budget** |
| Aprobación de cambios | CAB / puertas manuales | Pipeline automatizado + tests | Automatizado + entrega progresiva + política de presupuesto |
| Respuesta a una caída | Encontrar quién la rompió | Retrospectiva | **Postmortem sin culpa**, ítems de acción sistémicos |
| Trabajo manual | Aceptado como parte del laburo | Reducido donde conviene | **Toil acotado (≤ 50%)**, medido explícitamente |
| Definición de "terminado" | Desplegado | Desplegado y monitoreado | Desplegado, instrumentado, con SLO y listo para guardia |

El encuadre a nivel examen: **SRE es una implementación concreta de los principios de DevOps**, y su mecanismo distintivo es el **error budget**, que convierte una discusión política imposible de ganar ("entregar más rápido" vs. "dejar de romper cosas") en un número compartido que ambas partes acordaron de antemano.

### 3.2 La política de error budget — el mecanismo real

Un error budget sin una *política* escrita es decoración. La política establece, antes del incidente, qué pasa en cada umbral:

| Presupuesto restante | Acción de política |
|---|---|
| > 50% | Operación normal. Entregar features. Experimentos riesgosos permitidos. |
| 25–50% | Trabajo de fiabilidad priorizado junto con las features. Porcentajes de canary reducidos. |
| 10–25% | Congelamiento de features en el servicio afectado, excepto arreglos de fiabilidad y parches de seguridad. |
| < 10% | Congelamiento total de cambios. Toda la capacidad de ingeniería a fiabilidad. Autoridad de rollback delegada a la guardia. |
| Agotado / negativo | Congelamiento + revisión obligatoria con la propiedad de producto antes de levantarlo. |

### 3.3 Toil — la definición que tenés que poder recitar

**Toil** es trabajo operativo que es: *manual, repetitivo, automatizable, táctico, carente de valor duradero y que escala linealmente con el crecimiento del servicio.*

La cláusula de escalado lineal es el discriminador. Diseñar un nuevo modelo de capacidad no es toil (produce valor duradero). Redimensionar manualmente 40 node pools cada trimestre sí es toil (crece con la flota).

**La economía:** si una tarea lleva `t` minutos, ocurre `n` veces por mes y automatizarla cuesta `C` minutos-ingeniero:

```
payback_months = C / (t × n)
```

Con `t = 20 min`, `n = 30/month`, `C = 2400 min` (una semana-ingeniero), el repago es de **4 meses** — y además elimina una clase de error humano y un despertador de guardia. La práctica SRE acota el toil al **50% del tiempo de un SRE**, con el resto reservado a ingeniería que reduce el toil futuro.

### 3.4 DORA — la capa de medición de las operaciones modernas

DORA (DevOps Research and Assessment, ahora parte de Google Cloud) mide el rendimiento de entrega con cuatro claves, más la fiabilidad como métrica de resultado.

| Métrica | Qué mide | ¿Throughput o estabilidad? | Banda de elite performer (cifras publicadas típicas) |
|---|---|---|---|
| **Deployment frequency** | Con qué frecuencia liberás a producción | Throughput | Bajo demanda, varias veces por día |
| **Lead time for changes** | Commit → corriendo en producción | Throughput | Menos de un día |
| **Change failure rate** | % de despliegues que causan degradación que requiere remediación | Estabilidad | 5–10% |
| **Failed deployment recovery time** (antes *time to restore service* / MTTR) | Tiempo para recuperarse de un despliegue fallido | Estabilidad | Menos de una hora |
| **Reliability** (quinta, de resultado) | Capacidad de cumplir o superar las expectativas del usuario — es decir, tus SLO | Resultado | Cumpliendo los objetivos de SLO |

El hallazgo de DORA contraintuitivo y relevante para el examen: **throughput y estabilidad suben juntos.** Los equipos que despliegan con más frecuencia tienen tasas de fallo de cambio *más bajas*, porque los lotes pequeños son más fáciles de testear, revisar, canariar y revertir. La suposición tradicional — que ralentizar las releases aumenta la seguridad — es contradicha por los datos.

### 3.5 Matriz de terminología — los acrónimos que se confunden

| Acrónimo | Expansión | Mide | Dominio |
|---|---|---|---|
| MTTR | Mean Time To Repair/Restore | Detección → servicio restaurado | Respuesta a incidentes |
| MTTD | Mean Time To Detect | Comienza el fallo → se dispara la alerta | Calidad de observabilidad |
| MTTA | Mean Time To Acknowledge | Se dispara la alerta → responde un humano | Salud de la guardia |
| MTBF | Mean Time Between Failures | Fallo → siguiente fallo | Fiabilidad de componentes |
| **RTO** | **Recovery Time Objective** | **Máximo *downtime* tolerable tras el desastre** | **Planificación de DR** |
| **RPO** | **Recovery Point Objective** | **Máxima *pérdida de datos* tolerable, en tiempo** | **Planificación de DR** |

**RTO vs. RPO es la distinción examinada con más frecuencia en este objetivo.**
*El RTO mira hacia adelante desde el desastre: cuánto falta hasta que vuelva a servir.*
*El RPO mira hacia atrás desde el desastre: cuántos datos estoy dispuesto a perder.*
El RPO está acotado por tu **intervalo de backup/replicación**: snapshots horarios ⇒ el RPO no puede ser mejor que 1 hora, por más rápido que restaures.

---

## 4. Observabilidad en Google Cloud

### 4.1 Monitoreo vs. observabilidad

| | Monitoreo | Observabilidad |
|---|---|---|
| Pregunta que responde | "¿Está ocurriendo la condición mala conocida?" | "¿Por qué está ocurriendo esta condición mala desconocida?" |
| Construido a partir de | Métricas, dashboards y alertas predefinidas | Telemetría de alta cardinalidad que podés consultar ad hoc |
| Falla cuando | El modo de fallo no fue anticipado | La cardinalidad/el costo explota, o falta contexto |
| Artefacto típico | Política de alerta, uptime check | Cascada de trazas, consulta de logs, flame graph de perfil |

Necesitás ambos. El monitoreo te dice *que* el SLO está quemándose; la observabilidad te dice *cuál de los 12 saltos* es el responsable.

### 4.2 Las cuatro Golden Signals → mapeo a métricas de Google Cloud

| Golden signal | Significado | Fuente de métrica en GCP (típica) |
|---|---|---|
| **Latencia** | Tiempo para servir una petición — *separá las exitosas de las fallidas* | `loadbalancing.googleapis.com/https/total_latencies`, `run.googleapis.com/request_latencies`, Cloud Trace |
| **Tráfico** | Demanda sobre el sistema | `loadbalancing.googleapis.com/https/request_count`, `pubsub.googleapis.com/subscription/num_undelivered_messages` |
| **Errores** | Tasa de peticiones fallidas, explícitas e implícitas | `response_code_class = 5xx`, grupos de Error Reporting, métricas basadas en logs |
| **Saturación** | Qué tan lleno está el recurso más restringido | `kubernetes.io/container/cpu/limit_utilization`, `memory/used_bytes`, profundidad del pool de conexiones, profundidad de cola |

**La latencia de las peticiones fallidas debe separarse de la de las exitosas.** Un servicio que falla rápido parece una *mejora* de latencia en un gráfico mezclado — una caída que se presenta como una victoria de rendimiento es una trampa clásica de dashboard.

### 4.3 El conjunto de productos de Google Cloud Observability

| Producto | Propósito | Señal | Nota operativa clave |
|---|---|---|---|
| **Cloud Logging** | Ingerir, almacenar, enrutar y consultar logs | Logs | Bucket `_Required` (400 d, gratis, retención inmutable); bucket `_Default` (30 d, configurable). Los **log sinks** enrutan a BigQuery/GCS/Pub/Sub. Las métricas basadas en logs convierten logs en series temporales. |
| **Cloud Monitoring** | Métricas, dashboards, uptime checks, políticas de alerta, **servicios de SLO/error budget** | Métricas | Objetos SLO nativos con selectores de burn rate; los metric scopes permiten que un proyecto observe a muchos. |
| **Cloud Trace** | Trazado distribuido entre servicios | Trazas | Cascada de latencia — la herramienta que identifica *qué salto* está lento en §1.2. |
| **Cloud Profiler** | Perfilado estadístico continuo de CPU/heap en producción | Perfiles | Bajo overhead; encuentra *por qué el código* está lento, después de que Trace encontró *dónde*. |
| **Error Reporting** | Agrega y deduplica crashes/excepciones en grupos | Errores | Convierte 40.000 stack traces en 3 issues con primera/última aparición. |
| **Cloud Debugger / snapshots** | Inspeccionar el estado en apps en ejecución | Estado | La disponibilidad varía según el runtime; verificá el soporte actual en la documentación antes de depender de esto. |
| **Managed Service for Prometheus** | Métricas globales, de largo plazo, compatibles con Prometheus | Métricas | Ingiere cargas PromQL sin que corras tu propio par HA de Prometheus. |
| **Personalized Service Health** | Señal de incidentes del lado de Google acotada a *tus* proyectos | Eventos | Distingue "Google está roto" de "nosotros estamos rotos" — crítico durante el triage. |

**Orden de triage que se desprende de esta tabla:** Monitoring (quema de SLO) → Personalized Service Health (¿somos nosotros?) → Trace (qué salto) → Logging/Error Reporting (qué error) → Profiler (por qué el código).

---

## 5. Infraestructura completa: SLOs y alertado por burn rate como código

Todo lo de §2 sólo se vuelve operativo cuando está declarado. El siguiente Terraform es completo y se aplica tal cual contra un proyecto con la API de Monitoring habilitada.

```hcl
# ---------------------------------------------------------------------------
# slo.tf — Service, SLOs and multi-window multi-burn-rate alerting
# Provider: hashicorp/google >= 5.0
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Project that owns the Monitoring workspace."
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "url_map_name" {
  type        = string
  description = "URL map fronting the checkout service."
  default     = "checkout-urlmap"
}

variable "oncall_channel_id" {
  type        = string
  description = "Existing notification channel ID for the paging rotation."
}

variable "ticket_channel_id" {
  type        = string
  description = "Existing notification channel ID for the ticket queue."
}

# ---------------------------------------------------------------------------
# 1. The Service. An SLO always hangs off a Service object in Cloud Monitoring.
#    Use google_monitoring_custom_service for anything Monitoring does not
#    auto-discover (GKE/App Engine/Cloud Run services can be discovered).
# ---------------------------------------------------------------------------
resource "google_monitoring_custom_service" "checkout" {
  project      = var.project_id
  service_id   = "checkout-api"
  display_name = "Checkout API (critical user journey)"

  user_labels = {
    tier            = "critical"
    owning_team     = "payments-platform"
    error_budget_pol = "cup-2026-01"
  }
}

# ---------------------------------------------------------------------------
# 2. Availability SLI/SLO — request-based, good/total ratio.
#    "Valid" excludes 4xx: client-side faults are not our budget to spend.
# ---------------------------------------------------------------------------
locals {
  lb_base_filter = join(" AND ", [
    "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
    "resource.type=\"https_lb_rule\"",
    "resource.label.\"project_id\"=\"${var.project_id}\"",
    "resource.label.\"url_map_name\"=\"${var.url_map_name}\"",
  ])

  lb_latency_base_filter = join(" AND ", [
    "metric.type=\"loadbalancing.googleapis.com/https/total_latencies\"",
    "resource.type=\"https_lb_rule\"",
    "resource.label.\"project_id\"=\"${var.project_id}\"",
    "resource.label.\"url_map_name\"=\"${var.url_map_name}\"",
  ])
}

resource "google_monitoring_slo" "checkout_availability" {
  project      = var.project_id
  service      = google_monitoring_custom_service.checkout.service_id
  slo_id       = "checkout-availability-30d"
  display_name = "99.9% of valid checkout requests succeed (30d rolling)"

  goal                = 0.999
  rolling_period_days = 30

  request_based_sli {
    good_total_ratio {
      # Good  = everything that is not a server-side failure.
      good_service_filter = join(" AND ", [
        local.lb_base_filter,
        "metric.label.\"response_code_class\"!=\"500\"",
        "metric.label.\"response_code_class\"!=\"400\"",
      ])

      # Total = valid requests. 4xx removed: a malformed client request is
      # not an availability failure of ours.
      total_service_filter = join(" AND ", [
        local.lb_base_filter,
        "metric.label.\"response_code_class\"!=\"400\"",
      ])
    }
  }
}

# ---------------------------------------------------------------------------
# 3. Latency SLI/SLO — distribution cut. 99% of requests under 300 ms.
# ---------------------------------------------------------------------------
resource "google_monitoring_slo" "checkout_latency" {
  project      = var.project_id
  service      = google_monitoring_custom_service.checkout.service_id
  slo_id       = "checkout-latency-300ms-30d"
  display_name = "99% of checkout requests complete in under 300 ms (30d rolling)"

  goal                = 0.99
  rolling_period_days = 30

  request_based_sli {
    distribution_cut {
      distribution_filter = local.lb_latency_base_filter

      range {
        min = 0
        max = 300 # milliseconds
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 4. FAST BURN — 14.4x. Consumes 2% of the 30-day budget in one hour.
#    Two conditions ANDed: 1h long window (precision) + 5m short window (reset).
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "checkout_availability_fast_burn" {
  project      = var.project_id
  display_name = "[PAGE] checkout availability — fast burn (14.4x)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "1h burn rate > 14.4"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"3600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 14.4
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "5m burn rate > 14.4"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"300s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 14.4
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.oncall_channel_id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Checkout availability budget burning at >14.4x"
    content   = <<-EOT
      ## Fast burn — page

      At this rate the 30-day error budget is exhausted in **~50 hours**.

      ### First five minutes
      1. Check Personalized Service Health: is this a Google-side incident?
         `gcloud beta service-health events list --location=global`
      2. Check for a recent rollout — most fast burns are change-induced:
         `gcloud deploy rollouts list --delivery-pipeline=checkout-api \
            --region=${var.region} --limit=5`
      3. If a rollout landed within the burn window, **roll back first,
         diagnose second**. Rollback authority is delegated to on-call.
      4. Identify the failing hop in Cloud Trace before touching any service.

      ### Escalation
      Payments Platform on-call → Platform SRE lead after 20 minutes.
    EOT
  }

  severity = "CRITICAL"
}

# ---------------------------------------------------------------------------
# 5. SLOW BURN — 6x over 6h. Page, but with a wider, less twitchy window.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "checkout_availability_slow_burn" {
  project      = var.project_id
  display_name = "[PAGE] checkout availability — slow burn (6x)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "6h burn rate > 6"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"21600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 6
      duration        = "0s"

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "30m burn rate > 6"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"1800s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 6
      duration        = "0s"

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.oncall_channel_id]

  alert_strategy {
    auto_close = "3600s"
  }

  severity = "ERROR"
}

# ---------------------------------------------------------------------------
# 6. GRADUAL BURN — 1x over 3 days. Ticket, never a page.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "checkout_availability_gradual_burn" {
  project      = var.project_id
  display_name = "[TICKET] checkout availability — gradual burn (1x)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "3d burn rate > 1"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"259200s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "0s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "6h burn rate > 1"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"21600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "0s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.ticket_channel_id]

  alert_strategy {
    auto_close = "86400s"
  }

  severity = "WARNING"
}

# ---------------------------------------------------------------------------
# 7. Black-box uptime check — catches whole-frontend failures that produce
#    no LB metrics at all (DNS gone, cert expired, forwarding rule deleted).
#    White-box SLOs go blind exactly when the system is most broken.
# ---------------------------------------------------------------------------
resource "google_monitoring_uptime_check_config" "checkout_https" {
  project      = var.project_id
  display_name = "checkout-api /healthz (global)"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path           = "/healthz"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = "checkout.example.com"
    }
  }

  selected_regions = ["EUROPE", "USA", "SOUTH_AMERICA", "ASIA_PACIFIC"]

  checker_type = "STATIC_IP_CHECKERS"
}

resource "google_monitoring_alert_policy" "checkout_uptime_down" {
  project      = var.project_id
  display_name = "[PAGE] checkout-api unreachable from multiple regions"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\"",
        "resource.type=\"uptime_url\"",
        "metric.label.\"check_id\"=\"${google_monitoring_uptime_check_config.checkout_https.uptime_check_id}\"",
      ])
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 3 # at least 3 probe regions failing → not a probe artefact
      }
    }
  }

  notification_channels = [var.oncall_channel_id]
  severity              = "CRITICAL"
}

output "availability_slo_name" {
  value       = google_monitoring_slo.checkout_availability.name
  description = "Fully qualified SLO resource name, used by select_slo_burn_rate()."
}
```

---

## 6. Resiliencia: dominios de fallo, topologías de redundancia y DR

### 6.1 Dominios de fallo de Google Cloud

| Alcance | Blast radius | Sobrevive a | No sobrevive a | Recursos de ejemplo |
|---|---|---|---|---|
| **Zonal** | Una zona | Fallo de una máquina/rack | Caída de zona | Instancia GCE, PD zonal, cluster GKE zonal, MIG zonal |
| **Regional** | Una región (≥3 zonas) | Caída de zona | Caída de región | MIG regional, PD regional, GKE regional, Cloud SQL HA, bucket GCS regional |
| **Multirregional** | Un conjunto definido de regiones | Caída de región | Evento correlacionado a escala continental (raro) | Bucket GCS multirregión, configuración multirregión de Spanner, dataset multirregión de BigQuery |
| **Global** | La red global de Google | Caída de región, de forma transparente | Incidente global del plano de control (muy raro) | Global external Application Load Balancer, Cloud DNS, VPC, IAM, Cloud CDN |

**La regla arquitectónica que se desprende:** un servicio es sólo tan resiliente como su *dependencia con estado menos resiliente*. Una capa sin estado, multirregión y con balanceo global que escribe en una única instancia **zonal** de Cloud SQL es un servicio zonal disfrazado de global.

### 6.2 SLAs de disponibilidad publicados — orientación

Estas son cifras contractuales publicadas por Google Cloud y cambian; confirmá siempre contra `cloud.google.com/terms/sla` antes de diseñar en base a ellas. Se muestran acá para ilustrar la *forma* de la curva costo/disponibilidad.

| Servicio / configuración | SLA mensual publicado típico |
|---|---|
| Compute Engine — instancia única | 99.9% |
| Compute Engine — instancias en ≥2 zonas de una región | 99.99% |
| GKE — plano de control de cluster zonal | 99.5% |
| GKE — plano de control de cluster regional | 99.95% |
| Cloud Run | 99.95% |
| Cloud SQL — configuración HA (regional) | 99.95% |
| Cloud Spanner — configuración regional | 99.99% |
| Cloud Spanner — configuración multirregión | 99.999% |
| Cloud Storage — Standard, regional | 99.9% |
| Cloud Storage — Standard, multirregión/dual-región | 99.95% |
| Global external Application Load Balancer | 99.99% |

Notá el patrón: **cruzar el límite de un dominio de fallo es lo que te compra un nueve.** Zonal → regional → multirregión, cada escalón hacia arriba.

### 6.3 Patrones de recuperación ante desastres — el trade-off RTO/RPO/costo

| Patrón | RTO | RPO | Costo en régimen | Qué corre realmente en la región de DR | Modo de fallo que *no* cubre |
|---|---|---|---|---|---|
| **Backup & restore** | Horas → días | Horas (= intervalo de backup) | El más bajo (~5% de prod) | Nada; backups en GCS | Cualquier cosa que necesite recuperación rápida; restauraciones no probadas |
| **Cold standby / pilot light** | Decenas de minutos → horas | Minutos → horas | Bajo (~15–25%) | Datos replicados, servicios core mínimos, imágenes pre-construidas | Capacidad no disponible en la región de DR al momento del failover |
| **Warm standby** | Minutos | Segundos → minutos | Medio (~50%) | Stack completo reducido, replicación continua | Retraso de escalado bajo carga real de producción |
| **Hot standby / activo-activo** | Casi cero | Casi cero | El más alto (2× o más) | Stack completo sirviendo tráfico en ambas regiones | Fallos lógicos correlacionados (una config/dato malo se replica al instante) |

**La trampa de la última fila:** la replicación activo-activo propaga la corrupción *lógica* a velocidad de replicación. Un `DELETE` sin cláusula `WHERE` llega a todas las regiones en milisegundos. El hot standby protege contra desastres de *infraestructura*; sólo la **recuperación a un punto en el tiempo y los backups inmutables** protegen contra los *lógicos*. Los diseños maduros corren ambos.

### 6.4 Patrones de resiliencia en el diseño de aplicaciones

| Patrón | Problema que resuelve | Implementación en GCP | Costo de equivocarse |
|---|---|---|---|
| **Health checks + autohealing** | Instancias enfermas siguen recibiendo tráfico | `auto_healing_policies` del MIG, liveness probes de GKE | Sondas agresivas causan tormentas de reinicio bajo carga |
| **Degradación elegante** | Fallo total cuando muere una dependencia | Servir resultados cacheados/parciales; feature flags | Pérdida silenciosa de calidad sin ningún SLI que la detecte |
| **Circuit breaker** | Los reintentos contra una dependencia muerta amplifican la caída | `circuitBreakers` del backend service, Envoy/Service Mesh | Umbral demasiado bajo ⇒ se abre en picos normales |
| **Backoff exponencial + jitter** | Tormentas de reintentos sincronizados (thundering herd) | Bibliotecas cliente; `retry` en Pub/Sub, Cloud Tasks | Los reintentos a intervalo fijo re-sincronizan a todos los clientes |
| **Load shedding** | La sobrecarga colapsa todo en lugar de degradar | Rate limiting de Cloud Armor, `maxRatePerEndpoint` | Descartar el tráfico equivocado (tirar bots, no checkouts) |
| **Bulkhead / aislamiento** | Un inquilino ruidoso deja sin recursos al resto | Node pools separados, cuotas por inquilino, backend services separados | Sobre-particionar desperdicia capacidad |
| **Presupuestos de timeout** | Los hilos se acumulan en llamadas lentas | `BackendConfig.timeoutSec`, deadlines de gRPC | Timeout interno > timeout externo ⇒ el llamador abandona primero, trabajo desperdiciado |
| **Idempotencia** | Los reintentos duplican efectos secundarios | Claves de idempotencia, deduplicación por `messageId` de Pub/Sub | Clientes cobrados dos veces |
| **Chaos / DiRT testing** | Un failover no probado no funciona | Game days programados de drenaje de zona | La primera prueba real es la caída real |

**Invariante del presupuesto de timeouts:** para una cadena de llamadas `A → B → C`, necesitás `timeout(A→B) > timeout(B→C) + processing(B)`. Violarlo significa que A abandona la petición mientras B y C siguen quemando capacidad en trabajo que nadie va a leer — un colapso clásico por amplificación de reintentos.

---

## 7. Manifiestos de carga de trabajo completos: un servicio GKE resiliente

Lo siguiente es un conjunto de manifiestos completo y sintácticamente válido. Codifica todos los patrones de resiliencia de §6.4 que corresponden a la capa de carga de trabajo.

```yaml
# ---------------------------------------------------------------------------
# checkout-api.yaml — resilient workload for GKE regional cluster
# Apply with: kubectl apply -f checkout-api.yaml
# ---------------------------------------------------------------------------
apiVersion: v1
kind: Namespace
metadata:
  name: checkout
  labels:
    app.kubernetes.io/part-of: payments-platform
    tier: critical
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-user-journey
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: >-
  Critical user journeys. Under node pressure these evict batch and internal
  tooling workloads rather than being evicted themselves.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    # Workload Identity Federation for GKE: no downloaded service account keys.
    iam.gke.io/gcp-service-account: checkout-api@example-prod.iam.gserviceaccount.com
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  labels:
    app: checkout-api
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/version: "2.14.0"
spec:
  # Baseline only. The HPA owns replicas after the first reconcile; keep this
  # value out of your GitOps diff loop or the HPA and Git will fight forever.
  replicas: 6
  revisionHistoryLimit: 10

  # Minimum time a new Pod must stay Ready before it counts toward the
  # rollout's available replicas. Without it, a Pod that becomes Ready and
  # then crash-loops still advances the rollout.
  minReadySeconds: 30

  # Fail the rollout instead of hanging forever on a broken image.
  progressDeadlineSeconds: 600

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%        # burst capacity during rollout
      maxUnavailable: 0    # never dip below the current replica count

  selector:
    matchLabels:
      app: checkout-api

  template:
    metadata:
      labels:
        app: checkout-api
        app.kubernetes.io/version: "2.14.0"
      annotations:
        # Forces a rollout when the ConfigMap changes; without this, config
        # changes silently apply only to Pods that happen to restart later.
        checksum/config: "e3b0c44298fc1c149afbf4c8996fb924"
    spec:
      serviceAccountName: checkout-api
      priorityClassName: critical-user-journey

      # Must exceed the longest in-flight request plus the preStop drain.
      terminationGracePeriodSeconds: 90

      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault

      # ---- Decorrelation, part 1: spread across zones -------------------
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: checkout-api
        # Softer constraint at node granularity: prefer spreading, but do not
        # block scheduling if the cluster is temporarily packed.
        - maxSkew: 2
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: checkout-api

      # ---- Decorrelation, part 2: never co-locate two replicas ----------
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: checkout-api

      containers:
        - name: checkout-api
          image: europe-west1-docker.pkg.dev/example-prod/apps/checkout-api:2.14.0
          imagePullPolicy: IfNotPresent

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP

          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['topology.kubernetes.io/zone']
            - name: OTEL_SERVICE_NAME
              value: checkout-api
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://opentelemetry-collector.observability:4317
            # Timeout budget: this must be SMALLER than the LB backend
            # timeout (30 s) so we fail before the caller abandons us.
            - name: UPSTREAM_TIMEOUT_MS
              value: "2500"
            - name: UPSTREAM_MAX_RETRIES
              value: "2"

          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              # Memory limit == request: memory is incompressible, so
              # overcommitting it converts a slowdown into an OOMKill.
              memory: "512Mi"
              # CPU limit deliberately omitted. A CPU limit throttles the
              # container even when the node is idle, which inflates tail
              # latency (the exact thing the latency SLO measures). The
              # request already guarantees a share under contention.

          # ---- Three distinct probes, three distinct jobs ---------------
          # startupProbe:   "has it finished booting?"   — suppresses the others
          # readinessProbe: "should it get traffic now?" — removes from Service
          # livenessProbe:  "is it unrecoverable?"       — restarts the container
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: http
            failureThreshold: 30
            periodSeconds: 5        # allows up to 150 s of cold start

          readinessProbe:
            httpGet:
              path: /healthz/ready   # MUST check downstream dependencies
              port: http
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 3
            successThreshold: 1
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /healthz/live    # MUST NOT check downstream dependencies
              port: http
            initialDelaySeconds: 0
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 4      # ~60 s before a restart

          lifecycle:
            preStop:
              exec:
                # Connection draining. Endpoint removal from the NEG is
                # eventually consistent; exiting immediately on SIGTERM
                # produces 502s for in-flight requests routed by a
                # not-yet-updated load balancer.
                command: ["/bin/sh", "-c", "sleep 20"]

          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: config
              mountPath: /etc/checkout
              readOnly: true

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
        - name: config
          configMap:
            name: checkout-api-config
---
# ---------------------------------------------------------------------------
# PodDisruptionBudget: bounds VOLUNTARY disruption only — node upgrades,
# cluster autoscaler scale-down, `kubectl drain`. It does NOT protect against
# node crashes or zone outages. That is what topology spread is for.
# ---------------------------------------------------------------------------
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: checkout
spec:
  # Percentage form, not an absolute count: this stays correct as the HPA
  # scales the Deployment between 6 and 60 replicas.
  maxUnavailable: 25%
  selector:
    matchLabels:
      app: checkout-api
  # Do not let Pods that are already broken block a node drain forever.
  unhealthyPodEvictionPolicy: AlwaysAllow
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
  namespace: checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api

  minReplicas: 6      # >= 3 zones x 2, so a zone loss never drops below quorum
  maxReplicas: 60

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # 60%, not 80%: the headroom absorbs the scale-up lag
          # (metric scrape + HPA period + scheduling + image pull + startup).
          averageUtilization: 60

    # Demand-side signal. Scaling on requests-per-pod reacts to the load
    # itself rather than to CPU, which is a lagging proxy for it.
    - type: Pods
      pods:
        metric:
          name: prometheus.googleapis.com|http_requests_per_second|gauge
        target:
          type: AverageValue
          averageValue: "80"

  behavior:
    scaleUp:
      # React fast to load. Under-provisioning is a user-visible outage;
      # brief over-provisioning is only a cost line.
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100          # allow doubling
          periodSeconds: 30
        - type: Pods
          value: 8
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      # React slowly. Aggressive scale-down causes flapping and turns a
      # traffic dip into an outage when traffic returns.
      stabilizationWindowSeconds: 600
      policies:
        - type: Percent
          value: 10
          periodSeconds: 120
      selectPolicy: Min
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    # Container-native load balancing: the LB targets Pod IPs directly via a
    # Network Endpoint Group, removing the kube-proxy hop. This both lowers
    # latency and makes LB health checks reflect real Pod health.
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"default": "checkout-api-backendconfig"}'
spec:
  type: ClusterIP
  selector:
    app: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: checkout-api-backendconfig
  namespace: checkout
spec:
  # Outer timeout of the budget chain. Inner call timeout is 2500 ms.
  timeoutSec: 30

  # Must be >= the preStop sleep, or the LB stops draining before the Pod
  # has finished serving in-flight requests.
  connectionDraining:
    drainingTimeoutSec: 60

  healthCheck:
    type: HTTP
    requestPath: /healthz/ready
    port: 8080
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3

  # Load shedding at the edge, before the request costs you a Pod.
  securityPolicy:
    name: checkout-edge-policy

  logging:
    enable: true
    sampleRate: 1.0   # full sampling on a critical journey; reduce if cost-bound

  # Edge caching for static/idempotent GETs.
  cdn:
    enabled: false
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-api-default-deny-egress
  namespace: checkout
spec:
  podSelector:
    matchLabels:
      app: checkout-api
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
        - podSelector:
            matchLabels:
              app: auth-service
        - podSelector:
            matchLabels:
              app: catalog-service
        - podSelector:
            matchLabels:
              app: pricing-service
      ports:
        - protocol: TCP
          port: 8080
    # Google APIs via Private Google Access
    - to:
        - ipBlock:
            cidr: 199.36.153.8/30
      ports:
        - protocol: TCP
          port: 443
```

### 7.1 La distinción entre sondas que causa caídas en cascada

Este es el detalle operativo de mayor valor del manifiesto anterior, y vale la pena enunciarlo como regla:

> **Una liveness probe nunca debe probar una dependencia downstream.**

Si `/healthz/live` llama a la base de datos y la base de datos tiene un parpadeo de 90 segundos, todos los Pods de la flota fallan liveness simultáneamente, todos los Pods se reinician simultáneamente, todas las cachés calientes y pools de conexiones se destruyen simultáneamente, y la flota entonces estampida contra la base de datos *en recuperación* con tráfico de reconexión. Un parpadeo recuperable de 90 segundos de una dependencia se convierte en una caída autoinfligida de 30 minutos.

| Sonda | Pregunta | ¿Puede verificar dependencias? | Acción ante el fallo | Postura correcta de umbrales |
|---|---|---|---|---|
| `startupProbe` | "¿Terminó de arrancar?" | No | Suprime las otras sondas hasta que pase | `failureThreshold` generoso |
| `readinessProbe` | "¿Puede servir *ahora mismo*?" | **Sí** | Se saca de los endpoints del Service; **no se reinicia** | Sensible — entrada y salida rápidas |
| `livenessProbe` | "¿Está permanentemente trabado?" | **No — sólo local al proceso** | **Se reinicia el contenedor** | Conservadora — umbral alto, período largo |

---

## 8. Entrega progresiva: hacer que el cambio sea seguro

### 8.1 Trade-offs de las estrategias de despliegue

| Estrategia | Blast radius ante una release mala | Velocidad de rollback | Costo de infra | ¿Requiere división de tráfico? | ¿Requiere retrocompatibilidad de esquema? |
|---|---|---|---|---|---|
| **Recreate** | 100% + ventana de downtime | Lenta (redesplegar) | 1× | No | Sí |
| **Rolling update** | Crece con cada lote (0→100%) | Media (revertir a través de los lotes) | ~1.25× | No | Sí |
| **Blue/green** | 100% en el cutover, 0% antes | **La más rápida** (invertir el puntero) | **2×** | Sí (todo o nada) | Sí |
| **Canary** | Acotado por el % de canary (p. ej. 5%) | Rápida (devolver el tráfico) | ~1.1× | Sí (ponderada) | Sí |
| **Feature flag / dark launch** | Acotado por la cohorte del flag | **Instantánea** (sin redespliegue) | 1× | No (in-process) | Sí |
| **Shadow / tráfico espejado** | **Cero** (las respuestas se descartan) | N/A | ~2× de cómputo | Sí (mirroring) | Sí |

**Canary es lo predeterminado para un journey crítico**, porque acota el blast radius *y* es barato. Blue/green compra el rollback más rápido pero duplica el costo y aun así expone al 100% de los usuarios en el instante del cutover.

**La restricción que aplica a todas las filas:** todas requieren que el *esquema de base de datos* sea retrocompatible con la versión anterior de la aplicación, porque durante cualquiera de estas estrategias corren dos versiones de la aplicación concurrentemente contra un mismo esquema. Este es el patrón **expand/contract** (cambio paralelo): expandir el esquema, desplegar código que escribe en ambos, hacer backfill, desplegar código que lee lo nuevo, contraer el esquema — cuatro despliegues separados, nunca uno.

### 8.2 Pipeline de Cloud Deploy con canary y rollback automatizados

```yaml
# ---------------------------------------------------------------------------
# clouddeploy.yaml
# Register with:
#   gcloud deploy apply --file=clouddeploy.yaml --region=europe-west1
# ---------------------------------------------------------------------------
apiVersion: deploy.cloud.google.com/v1
kind: DeliveryPipeline
metadata:
  name: checkout-api
  annotations:
    owning-team: payments-platform
  labels:
    tier: critical
description: >-
  Checkout API delivery pipeline. staging is fully automated; prod requires
  approval and rolls out as a 5/25/50/100 canary with verification at each step.
serialPipeline:
  stages:
    - targetId: staging
      profiles:
        - staging
      strategy:
        standard:
          verify: true

    - targetId: prod
      profiles:
        - prod
      strategy:
        canary:
          runtimeConfig:
            kubernetes:
              gatewayServiceMesh:
                httpRoute: checkout-api-route
                service: checkout-api
                deployment: checkout-api
                routeUpdateWaitTime: 60s
                podSelectorLabel: app
          canaryDeployment:
            percentages: [5, 25, 50]
            verify: true
            predeploy:
              actions:
                - snapshot-slo-baseline
            postdeploy:
              actions:
                - check-slo-burn
---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: staging
description: Regional GKE staging cluster (europe-west1)
requireApproval: false
gke:
  cluster: projects/example-staging/locations/europe-west1/clusters/apps-euw1
executionConfigs:
  - usages: [RENDER, DEPLOY, VERIFY, PREDEPLOY, POSTDEPLOY]
    serviceAccount: clouddeploy-exec@example-staging.iam.gserviceaccount.com
    artifactStorage: gs://example-staging-clouddeploy-artifacts
    executionTimeout: 3600s
---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: prod
description: Regional GKE production cluster (europe-west1)
# Human gate on the critical journey. The canary bounds the blast radius;
# the approval bounds *when* it happens (no Friday 18:00 promotions).
requireApproval: true
gke:
  cluster: projects/example-prod/locations/europe-west1/clusters/apps-euw1
executionConfigs:
  - usages: [RENDER, DEPLOY, VERIFY, PREDEPLOY, POSTDEPLOY]
    serviceAccount: clouddeploy-exec@example-prod.iam.gserviceaccount.com
    artifactStorage: gs://example-prod-clouddeploy-artifacts
    executionTimeout: 3600s
---
# ---------------------------------------------------------------------------
# Automation: advance the canary automatically when verification passes, and
# roll back automatically when a rollout job fails. This is the mechanism that
# takes the human out of the MTTR path for change-induced failure — the single
# largest category of production incidents.
# ---------------------------------------------------------------------------
apiVersion: deploy.cloud.google.com/v1
kind: Automation
metadata:
  name: checkout-api/auto-advance-and-repair
description: Advance verified canary phases; roll back on failure.
serviceAccount: clouddeploy-automation@example-prod.iam.gserviceaccount.com
selector:
  - target:
      id: prod
rules:
  - advanceRolloutRule:
      name: advance-verified-canary
      sourcePhases: ["canary-5", "canary-25", "canary-50"]
      wait: 10m          # soak each phase before advancing

  - repairRolloutRule:
      name: rollback-on-failure
      phases: ["canary-5", "canary-25", "canary-50", "stable"]
      jobs: ["deploy", "verify"]
      repairPhases:
        - retry:
            attempts: 1
            wait: 60s
            backoffMode: BACKOFF_MODE_LINEAR
        - rollback:
            destinationPhase: "stable"
            disableRollbackIfRolloutPending: true
---
# ---------------------------------------------------------------------------
# skaffold.yaml — the renderer Cloud Deploy invokes.
# ---------------------------------------------------------------------------
apiVersion: skaffold/v4beta7
kind: Config
metadata:
  name: checkout-api
manifests:
  kustomize:
    paths:
      - manifests/base
deploy:
  kubectl: {}
verify:
  - name: slo-smoke-test
    container:
      name: slo-smoke-test
      image: europe-west1-docker.pkg.dev/example-prod/tools/verifier:1.4.0
      command: ["/bin/sh"]
      args:
        - -c
        - |
          set -euo pipefail
          echo "Probing canary endpoint for 300s..."
          /usr/local/bin/probe \
            --url "https://checkout.example.com/api/v1/cart/health" \
            --duration 300s \
            --qps 20 \
            --max-error-rate 0.005 \
            --max-p99-latency 300ms
customActions:
  - name: snapshot-slo-baseline
    containers:
      - name: snapshot
        image: europe-west1-docker.pkg.dev/example-prod/tools/sloctl:1.2.0
        args: ["snapshot", "--slo", "checkout-availability-30d", "--out", "gs://example-prod-clouddeploy-artifacts/baselines"]
  - name: check-slo-burn
    containers:
      - name: burn
        image: europe-west1-docker.pkg.dev/example-prod/tools/sloctl:1.2.0
        args: ["burn", "--slo", "checkout-availability-30d", "--window", "600s", "--fail-above", "6.0"]
profiles:
  - name: staging
    manifests:
      kustomize:
        paths: ["manifests/overlays/staging"]
  - name: prod
    manifests:
      kustomize:
        paths: ["manifests/overlays/prod"]
```

---

## 9. Infraestructura regional con autohealing y DR entre regiones

```hcl
# ---------------------------------------------------------------------------
# resilient-infra.tf — regional MIG behind a global LB, plus Cloud SQL HA
# with a cross-region read replica for DR promotion.
# ---------------------------------------------------------------------------

# ---- Health check consumed by BOTH autohealing and the load balancer ------
# One definition, two consumers: prevents the split-brain state where the LB
# considers an instance healthy while autohealing is recreating it.
resource "google_compute_health_check" "checkout" {
  project             = var.project_id
  name                = "checkout-hc"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz/ready"
  }

  log_config {
    enable = true
  }
}

resource "google_compute_instance_template" "checkout" {
  project      = var.project_id
  name_prefix  = "checkout-tpl-"
  machine_type = "e2-standard-4"
  region       = var.region

  disk {
    source_image = "projects/cos-cloud/global/images/family/cos-stable"
    auto_delete  = true
    boot         = true
    disk_size_gb = 50
    disk_type    = "pd-balanced"
  }

  network_interface {
    network    = "projects/${var.project_id}/global/networks/prod-vpc"
    subnetwork = "projects/${var.project_id}/regions/${var.region}/subnetworks/prod-euw1"
    # No external IP: egress via Cloud NAT, ingress via the load balancer only.
  }

  service_account {
    email  = "checkout-vm@${var.project_id}.iam.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }

  tags = ["checkout", "allow-health-checks"]

  lifecycle {
    create_before_destroy = true
  }
}

# ---- Regional MIG: instances spread EVENLY across all zones in the region --
resource "google_compute_region_instance_group_manager" "checkout" {
  project = var.project_id
  name    = "checkout-mig"
  region  = var.region

  base_instance_name        = "checkout"
  distribution_policy_zones = [
    "${var.region}-b",
    "${var.region}-c",
    "${var.region}-d",
  ]
  # EVEN keeps the zone distribution balanced during scaling events, which is
  # what preserves survivability of a single-zone loss. BALANCED trades that
  # for higher chance of obtaining capacity.
  distribution_policy_target_shape = "EVEN"

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.checkout.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check = google_compute_health_check.checkout.id
    # Long enough for the application to boot and warm. Too short and the MIG
    # kills instances mid-startup, producing a permanent recreate loop.
    initial_delay_sec = 300
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3   # must be >= number of zones
    max_unavailable_fixed        = 0   # never reduce serving capacity
    replacement_method           = "SUBSTITUTE"
    # Canary at the infrastructure layer: 20% of instances get the new
    # template and stay there until a human or automation removes the cap.
    min_ready_sec                = 60
  }

  lifecycle {
    ignore_changes = [target_size] # the autoscaler owns this
  }
}

resource "google_compute_region_autoscaler" "checkout" {
  project = var.project_id
  name    = "checkout-autoscaler"
  region  = var.region
  target  = google_compute_region_instance_group_manager.checkout.id

  autoscaling_policy {
    min_replicas    = 6
    max_replicas    = 60
    cooldown_period = 90
    mode            = "ON"

    cpu_utilization {
      target            = 0.6
      predictive_method = "OPTIMIZE_AVAILABILITY" # pre-scales for learned cycles
    }

    load_balancing_utilization {
      target = 0.7
    }

    scale_in_control {
      time_window_sec = 600
      max_scaled_in_replicas {
        percent = 10 # bound how fast we can shed capacity
      }
    }
  }
}

# ---- Global backend service: circuit breaking + outlier detection ----------
resource "google_compute_backend_service" "checkout" {
  project               = var.project_id
  name                  = "checkout-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.checkout.id]
  locality_lb_policy    = "ROUND_ROBIN"

  backend {
    group           = google_compute_region_instance_group_manager.checkout.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    # Overflow headroom: allows the region to absorb 10% above target before
    # traffic spills to another region's backend.
    capacity_scaler = 1.0
  }

  # ---- Circuit breaker: bound the damage a slow backend can do ------------
  circuit_breakers {
    max_requests_per_connection = 100
    max_connections             = 2048
    max_pending_requests        = 512
    max_requests                = 2048
    max_retries                 = 3
  }

  # ---- Outlier detection: eject instances that are failing, not just down --
  # Health checks answer "is it up?". Outlier detection answers "is it
  # returning errors?" — a process can pass /healthz and still 500 on real work.
  outlier_detection {
    consecutive_errors                    = 5
    interval { seconds = 10 }
    base_ejection_time { seconds = 30 }
    max_ejection_percent                  = 50   # never eject the whole fleet
    enforcing_consecutive_errors          = 100
    consecutive_gateway_failure           = 3
    enforcing_consecutive_gateway_failure = 100
    success_rate_minimum_hosts            = 5
    success_rate_request_volume           = 100
    success_rate_stdev_factor             = 1900
  }

  connection_draining_timeout_sec = 60

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  security_policy = google_compute_security_policy.checkout_edge.id
}

# ---- Load shedding at the edge --------------------------------------------
resource "google_compute_security_policy" "checkout_edge" {
  project = var.project_id
  name    = "checkout-edge-policy"
  type    = "CLOUD_ARMOR"

  # Rate-based ban: sheds abusive traffic before it costs backend capacity.
  rule {
    action   = "rate_based_ban"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
      ban_duration_sec = 300
    }
    description = "Per-IP rate limit: 600 req/min, 5 minute ban on breach."
  }

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable          = true
      rule_visibility = "STANDARD"
    }
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow."
  }
}

# ---- Stateful tier: HA primary + cross-region replica for DR ---------------
resource "google_sql_database_instance" "orders_primary" {
  project             = var.project_id
  name                = "orders-primary-euw1"
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = true

  settings {
    tier = "db-custom-8-32768"

    # REGIONAL = synchronous replication to a standby in another zone,
    # automatic failover. This is what turns a zonal database into a
    # regional one, and it is the RPO=0 / RTO~60s configuration.
    availability_type = "REGIONAL"

    disk_type       = "PD_SSD"
    disk_size       = 500
    disk_autoresize = true

    backup_configuration {
      enabled    = true
      start_time = "02:00"
      location   = "eu" # multi-region backup location

      # PITR is the ONLY protection against logical corruption, which
      # replicates to the standby and to every read replica instantly.
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7      # Sunday
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.project_id}/global/networks/prod-vpc"
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }
}

# Cross-region replica: asynchronous. RPO is replication lag (seconds),
# RTO is promotion time (minutes) plus application reconfiguration.
resource "google_sql_database_instance" "orders_dr_replica" {
  project              = var.project_id
  name                 = "orders-replica-euw4"
  region               = "europe-west4"
  database_version     = "POSTGRES_15"
  master_instance_name = google_sql_database_instance.orders_primary.name
  deletion_protection  = true

  replica_configuration {
    failover_target = false # cross-region replicas are promoted manually
  }

  settings {
    tier              = "db-custom-8-32768"
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.project_id}/global/networks/prod-vpc"
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }
}

# Alert on replication lag — this IS your live RPO measurement.
resource "google_monitoring_alert_policy" "replica_lag" {
  project      = var.project_id
  display_name = "[TICKET] orders DR replica lag exceeds RPO (60s)"
  combiner     = "OR"

  conditions {
    display_name = "Replica lag > 60s for 10m"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"cloudsql.googleapis.com/database/replication/replica_lag\"",
        "resource.type=\"cloudsql_database\"",
        "resource.label.\"database_id\"=\"${var.project_id}:orders-replica-euw4\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 60
      duration        = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.ticket_channel_id]
  severity              = "WARNING"
}
```

---

## 10. CLI: operar y verificar el sistema

### 10.1 Confirmar que el SLO existe y leer el error budget en vivo

```
$ export PROJECT_ID=example-prod
$ gcloud config set project $PROJECT_ID
Updated property [core/project].

$ curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/services/checkout-api/serviceLevelObjectives" \
  | jq -r '.serviceLevelObjectives[] | "\(.displayName)\t goal=\(.goal)\t period=\(.rollingPeriod)"'
99.9% of valid checkout requests succeed (30d rolling)	 goal=0.999	 period=2592000s
99% of checkout requests complete in under 300 ms (30d rolling)	 goal=0.99	 period=2592000s
```

Leé el burn rate actual directamente de la serie temporal del SLO:

```
$ SLO="projects/${PROJECT_ID}/services/checkout-api/serviceLevelObjectives/checkout-availability-30d"
$ NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$ AGO=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)

$ curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/timeSeries" \
    --data-urlencode "filter=select_slo_burn_rate(\"${SLO}\", \"3600s\")" \
    --data-urlencode "interval.startTime=${AGO}" \
    --data-urlencode "interval.endTime=${NOW}" \
  | jq -r '.timeSeries[0].points[] | "\(.interval.endTime)  burn_rate=\(.value.doubleValue)"' | head -8
2026-09-09T14:00:00Z  burn_rate=18.42
2026-09-09T13:55:00Z  burn_rate=17.90
2026-09-09T13:50:00Z  burn_rate=16.03
2026-09-09T13:45:00Z  burn_rate=14.88
2026-09-09T13:40:00Z  burn_rate=9.71
2026-09-09T13:35:00Z  burn_rate=1.12
2026-09-09T13:30:00Z  burn_rate=0.94
2026-09-09T13:25:00Z  burn_rate=0.88
```

**Interpretación:** el burn rate cruzó 14.4 entre las 13:40 y las 13:45 y sigue subiendo. La página de fast burn se disparó. El cambio abrupto de 13:35 → 13:40 es característico de un fallo **inducido por un cambio**, no de una degradación gradual — andá a mirar qué se desplegó.

### 10.2 ¿Somos nosotros, o es Google?

```
$ gcloud beta service-health events list --location=global \
    --format="table(name.basename(),category,state,detailedState,updateTime)"
NAME                      CATEGORY  STATE     DETAILED_STATE  UPDATE_TIME
(no incidents affecting this project)
```

Nada del lado de Google. Es nuestro.

### 10.3 ¿Qué cambió?

```
$ gcloud deploy rollouts list \
    --delivery-pipeline=checkout-api \
    --release=- \
    --region=europe-west1 \
    --limit=5 \
    --format="table(name.basename(),targetId,state,phaseId,createTime)"
NAME                              TARGET_ID  STATE       PHASE_ID   CREATE_TIME
checkout-api-2-14-0-to-prod-0001  prod       IN_PROGRESS canary-25  2026-09-09T13:38:41Z
checkout-api-2-13-4-to-prod-0001  prod       SUCCEEDED   stable     2026-09-08T09:12:07Z
checkout-api-2-13-3-to-prod-0001  prod       SUCCEEDED   stable     2026-09-05T16:44:19Z
checkout-api-2-13-2-to-prod-0001  prod       SUCCEEDED   stable     2026-09-04T11:02:55Z
checkout-api-2-13-1-to-prod-0001  prod       SUCCEEDED   stable     2026-09-03T15:31:12Z
```

Un canary avanzó al 25% a las 13:38. El burn rate escalonó hacia arriba a las 13:40. **La correlación en el tiempo más un porcentaje de tráfico coincidente es evidencia suficiente para revertir.** Diagnosticá después de que pare la hemorragia.

```
$ gcloud deploy rollouts rollback checkout-api-2-14-0-to-prod-0001 \
    --delivery-pipeline=checkout-api \
    --region=europe-west1 \
    --release=checkout-api-2-14-0
Rolling back to release [checkout-api-2-13-4].
Created Cloud Deploy rollout [checkout-api-2-13-4-to-prod-0002] in target [prod].

$ gcloud deploy rollouts describe checkout-api-2-13-4-to-prod-0002 \
    --delivery-pipeline=checkout-api --release=checkout-api-2-13-4 \
    --region=europe-west1 --format="value(state)"
SUCCEEDED
```

Después confirmá que el presupuesto dejó de quemarse — no cierres el incidente porque el despliegue tuvo éxito:

```
$ watch -n 60 'curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/example-prod/timeSeries" \
    --data-urlencode "filter=select_slo_burn_rate(\"'"$SLO"'\", \"300s\")" \
    --data-urlencode "interval.startTime=$(date -u -d "-10 min" +%Y-%m-%dT%H:%M:%SZ)" \
    --data-urlencode "interval.endTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | jq -r ".timeSeries[0].points[0].value.doubleValue"'
0.41
```

### 10.4 Verificación a nivel de la carga de trabajo

```
$ kubectl -n checkout get deploy,hpa,pdb
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/checkout-api   18/18   18           18          214d

NAME                                              REFERENCE                 TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.../checkout-api           Deployment/checkout-api   cpu: 54%/60%, 71/80 (avg)      6         60        18         214d

NAME                                        MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/checkout-api     N/A             25%               4                     214d
```

Verificá que la distribución zonal realmente ocurrió — el manifiesto declara la intención, el cluster decide:

```
$ kubectl -n checkout get pods -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,STATUS:.status.phase' \
  --sort-by=.metadata.name | head -8
NAME                            NODE                          ZONE              STATUS
checkout-api-7c9f4d8b6-2xk9p    gke-apps-euw1-pool-a-9f2c     europe-west1-b    Running
checkout-api-7c9f4d8b6-4nqvz    gke-apps-euw1-pool-a-1d7e     europe-west1-c    Running
checkout-api-7c9f4d8b6-6bd8w    gke-apps-euw1-pool-a-3a11     europe-west1-d    Running
checkout-api-7c9f4d8b6-8fzt2    gke-apps-euw1-pool-a-9f2c     europe-west1-b    Running
checkout-api-7c9f4d8b6-9klmc    gke-apps-euw1-pool-a-1d7e     europe-west1-c    Running
checkout-api-7c9f4d8b6-b7rpn    gke-apps-euw1-pool-a-3a11     europe-west1-d    Running
checkout-api-7c9f4d8b6-cw4gh    gke-apps-euw1-pool-a-7c40     europe-west1-b    Running
checkout-api-7c9f4d8b6-dj2sq    gke-apps-euw1-pool-a-1d7e     europe-west1-c    Running

$ kubectl -n checkout get pods -o json \
  | jq -r '.items[].metadata.labels["topology.kubernetes.io/zone"]' | sort | uniq -c
      6 europe-west1-b
      6 europe-west1-c
      6 europe-west1-d
```

Distribución pareja entre tres zonas: perder cualquiera de ellas elimina el 33% de la capacidad, y el HPA más el headroom restante lo absorben.

### 10.5 Salud del backend y de los endpoints

```
$ gcloud compute backend-services get-health checkout-backend --global \
    --format="value(status.healthStatus[].instance.basename(),status.healthStatus[].healthState)"
checkout-x9k2  HEALTHY
checkout-mn4p  HEALTHY
checkout-qq81  UNHEALTHY
checkout-b3zv  HEALTHY
checkout-tt7c  HEALTHY
checkout-lp0d  HEALTHY

$ gcloud compute instance-groups managed list-instances checkout-mig \
    --region=europe-west1 \
    --format="table(name,zone.basename(),instanceStatus,currentAction,instanceHealth[0].detailedHealthState)"
NAME           ZONE            INSTANCE_STATUS  CURRENT_ACTION  DETAILED_HEALTH_STATE
checkout-x9k2  europe-west1-b  RUNNING          NONE            HEALTHY
checkout-mn4p  europe-west1-b  RUNNING          NONE            HEALTHY
checkout-qq81  europe-west1-c  RUNNING          RECREATING      UNHEALTHY
checkout-b3zv  europe-west1-c  RUNNING          NONE            HEALTHY
checkout-tt7c  europe-west1-d  RUNNING          NONE            HEALTHY
checkout-lp0d  europe-west1-d  RUNNING          NONE            HEALTHY
```

`CURRENT_ACTION: RECREATING` confirma que el autohealing está haciendo su trabajo. El sistema se está degradando con elegancia en lugar de fallar.

### 10.6 Consultas de logs que responden preguntas reales

```
$ gcloud logging read \
  'resource.type="k8s_container"
   resource.labels.namespace_name="checkout"
   severity>=ERROR
   timestamp>="2026-09-09T13:30:00Z"' \
  --limit=5 --format="value(timestamp, resource.labels.pod_name, jsonPayload.message)"
2026-09-09T13:52:11Z  checkout-api-7c9f4d8b6-2xk9p  upstream deadline exceeded: pricing-service (2500ms)
2026-09-09T13:52:09Z  checkout-api-7c9f4d8b6-8fzt2  upstream deadline exceeded: pricing-service (2500ms)
2026-09-09T13:52:04Z  checkout-api-7c9f4d8b6-cw4gh  upstream deadline exceeded: pricing-service (2500ms)
2026-09-09T13:51:58Z  checkout-api-7c9f4d8b6-2xk9p  connection pool exhausted (max=64, waiting=211)
2026-09-09T13:51:57Z  checkout-api-7c9f4d8b6-4nqvz  connection pool exhausted (max=64, waiting=211)
```

Desglosá los 5xx por backend para encontrar *qué salto* — la pregunta de §1.2:

```
$ gcloud logging read \
  'resource.type="http_load_balancer"
   httpRequest.status>=500
   timestamp>="2026-09-09T13:30:00Z"' \
  --format="value(jsonPayload.statusDetails)" --limit=2000 | sort | uniq -c | sort -rn
   1584 backend_timeout
    221 failed_to_pick_backend
     47 backend_connection_closed_before_data_sent_to_client
      6 response_sent_by_backend
```

Que domine `backend_timeout` significa que el backend está *lento*, no *caído*. Eso apunta a la dependencia pricing-service, no a los Pods de checkout — y explica por qué todos los health checks siguen pasando.

### 10.7 Un simulacro de DR: promover la réplica entre regiones

Nunca ejecutes esto por primera vez durante un desastre real.

```
$ gcloud sql instances describe orders-replica-euw4 \
    --format="value(state, masterInstanceName, region, replicaConfiguration.failoverTarget)"
RUNNABLE  example-prod:orders-primary-euw1  europe-west4  False

# Measure live RPO before promoting.
$ gcloud monitoring time-series list \
  --filter='metric.type="cloudsql.googleapis.com/database/replication/replica_lag" AND
            resource.labels.database_id="example-prod:orders-replica-euw4"' \
  --format="value(points[0].value.doubleValue)"
3.0

# 3 seconds of lag == 3 seconds of potential data loss. Within the 60s RPO.

$ gcloud sql instances promote-replica orders-replica-euw4 --quiet
Promoting Cloud SQL replica...done.
Promoted [https://sqladmin.googleapis.com/sql/v1beta4/projects/example-prod/instances/orders-replica-euw4].

$ gcloud sql instances describe orders-replica-euw4 \
    --format="value(state, masterInstanceName, instanceType)"
RUNNABLE    CLOUD_SQL_INSTANCE
```

`masterInstanceName` ahora está vacío y `instanceType` es `CLOUD_SQL_INSTANCE`: es un primario independiente. **La promoción es irreversible** — la relación de replicación no puede recrearse en la dirección original sin una reconstrucción. Por eso el simulacro tiene que ser programado, acotado y presupuestado, y por eso `failover_target = false` en el Terraform: nada debería promover una réplica entre regiones por accidente.

Compará con el failover de HA *intra-región*, que es reversible y rutinario:

```
$ gcloud sql instances failover orders-primary-euw1 --quiet
Failing over Cloud SQL instance...done.
Failed over [https://sqladmin.googleapis.com/sql/v1beta4/projects/example-prod/instances/orders-primary-euw1].

$ gcloud sql operations list --instance=orders-primary-euw1 --limit=1 \
    --format="table(name.basename(),operationType,status,startTime,endTime)"
NAME                                  OPERATION_TYPE  STATUS  START_TIME                END_TIME
9f2c1d4a-7b31-4c8e-a2f0-11de83c4b907  FAILOVER        DONE    2026-09-09T14:41:02.114Z  2026-09-09T14:42:07.883Z
```

**65 segundos de RTO medido, RPO = 0** (replicación regional sincrónica). Ese es el número real y evidenciado para el plan de DR — no una estimación.

### 10.8 Un game day de pérdida de zona

```
# Simulate losing europe-west1-c by cordoning and draining its nodes.
$ ZONE=europe-west1-c
$ kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o name | wc -l
4

$ kubectl cordon -l topology.kubernetes.io/zone=$ZONE
node/gke-apps-euw1-pool-a-1d7e cordoned
node/gke-apps-euw1-pool-a-4f88 cordoned
node/gke-apps-euw1-pool-a-6b02 cordoned
node/gke-apps-euw1-pool-a-8e5a cordoned

$ kubectl drain -l topology.kubernetes.io/zone=$ZONE \
    --ignore-daemonsets --delete-emptydir-data --timeout=300s
node/gke-apps-euw1-pool-a-1d7e already cordoned
evicting pod checkout/checkout-api-7c9f4d8b6-4nqvz
evicting pod checkout/checkout-api-7c9f4d8b6-9klmc
error when evicting pods/"checkout-api-7c9f4d8b6-dj2sq" -n "checkout" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
evicting pod checkout/checkout-api-7c9f4d8b6-dj2sq
pod/checkout-api-7c9f4d8b6-4nqvz evicted
pod/checkout-api-7c9f4d8b6-9klmc evicted
pod/checkout-api-7c9f4d8b6-dj2sq evicted
node/gke-apps-euw1-pool-a-1d7e drained
```

**El mensaje `Cannot evict pod as it would violate the pod's disruption budget` es el PDB funcionando correctamente, no un error.** El drenaje se autorreguló para mantener sirviendo al 75% de la flota. Si ese mensaje nunca aparece durante un drenaje, tu PDB es demasiado permisivo para estar protegiendo algo.

Después verificá que el SLO aguantó durante el simulacro:

```
$ curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/example-prod/timeSeries" \
    --data-urlencode "filter=select_slo_burn_rate(\"${SLO}\", \"1800s\")" \
    --data-urlencode "interval.startTime=$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)" \
    --data-urlencode "interval.endTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | jq -r '[.timeSeries[0].points[].value.doubleValue] | max'
1.34

$ kubectl uncordon -l topology.kubernetes.io/zone=$ZONE
node/gke-apps-euw1-pool-a-1d7e uncordoned
node/gke-apps-euw1-pool-a-4f88 uncordoned
node/gke-apps-euw1-pool-a-6b02 uncordoned
node/gke-apps-euw1-pool-a-8e5a uncordoned
```

Burn rate pico de 1.34 durante una pérdida total de zona simulada: el diseño la sobrevive con margen. **Ese número es el entregable del game day** — no "el simulacro se completó".

---

## 11. Guía de verificación y diagnóstico de fallos

### 11.1 Checklist de verificación pre-producción

| # | Afirmación | Comando que la prueba | Criterio de aprobación |
|---|---|---|---|
| 1 | El SLO existe y está siendo evaluado | `curl .../serviceLevelObjectives \| jq` | Objeto devuelto, `goal` coincide con el diseño |
| 2 | El alertado es multi-ventana, no único | `gcloud alpha monitoring policies list --format='value(displayName,combiner,conditions.len())'` | `combiner=AND`, 2 condiciones por política de burn |
| 3 | Las páginas realmente llegan a un humano | `gcloud alpha monitoring channels list` + enviar una prueba | Alerta de prueba reconocida por la guardia |
| 4 | La ceguera de caja blanca está cubierta | `gcloud monitoring uptime list-configs` | ≥1 uptime check desde ≥3 regiones |
| 5 | Las réplicas realmente abarcan zonas | `kubectl get pods -o json \| jq ... \| sort \| uniq -c` | ≥3 zonas, skew ≤ 1 |
| 6 | La disrupción voluntaria está acotada | `kubectl get pdb -A` | `ALLOWED DISRUPTIONS` > 0 y < réplicas |
| 7 | Liveness no prueba dependencias | `kubectl get deploy -o yaml \| yq '.spec.template.spec.containers[].livenessProbe'` | La ruta es local al proceso |
| 8 | El rollback está automatizado y probado | `gcloud deploy automations list --delivery-pipeline=... --region=...` | `repairRolloutRule` presente |
| 9 | El plan de DR tiene números medidos | Marcas de tiempo de las operaciones del simulacro (§10.7) | RTO/RPO medidos, no estimados |
| 10 | Los backups restauran | Restaurar a una instancia descartable y consultarla | Conteos de filas y checksums coinciden |

**El ítem 10 es el que los equipos se saltean.** Un backup que nunca fue restaurado no es un backup; es una hipótesis no probada con una factura de almacenamiento.

### 11.2 Tabla síntoma → diagnóstico

| Síntoma | Causa más probable | Comando que lo confirma | Arreglo |
|---|---|---|---|
| El burn rate escalona bruscamente en un timestamp | Fallo inducido por un cambio | `gcloud deploy rollouts list --limit=5` | Revertir primero, diagnosticar después |
| El burn rate deriva hacia arriba durante días | Capacidad/fuga/crecimiento de tráfico | `kubectl top pods`; tendencia de memoria en Monitoring | Redimensionar, arreglar la fuga, subir `maxReplicas` |
| 502 del LB, todos los Pods Ready | Pods que salen ante SIGTERM antes de desregistrarse del NEG | `gcloud logging read 'statusDetails="backend_connection_closed_before_data_sent_to_client"'` | Agregar `preStop` sleep ≥ tiempo de drenaje; `terminationGracePeriodSeconds` > preStop + tiempo de petición |
| `failed_to_pick_backend` del LB | Cero backends saludables | `gcloud compute backend-services get-health ... --global` | Arreglar la ruta/puerto del health check; revisar el firewall para `35.191.0.0/16`, `130.211.0.0/22` |
| Toda la flota se reinicia a la vez | Liveness probe verificando una dependencia | `kubectl get events -n <ns> --sort-by=.lastTimestamp \| grep Unhealthy` | Separar liveness (local) de readiness (consciente de dependencias) |
| HPA trabado en `<unknown>/60%` | Faltan **requests** de recursos, o el adaptador de métricas está caído | `kubectl describe hpa <name>` | Definir `resources.requests.cpu`; verificar el pipeline de métricas |
| El HPA oscila | Estabilización de `scaleDown` demasiado corta | `kubectl describe hpa` → eventos de escalado | Subir `scaleDown.stabilizationWindowSeconds` a 300–600 |
| Pods en `Pending` durante una pérdida de zona | `whenUnsatisfiable: DoNotSchedule` + sin capacidad | `kubectl describe pod` → `FailedScheduling` | Headroom del cluster autoscaler; o relajar a `ScheduleAnyway` para la restricción a nivel de nodo |
| Latencia de cola alta, CPU baja | Throttling por el límite de CPU | Métrica `container/cpu/cfs_throttled_periods` | Quitar el límite de CPU; mantener el request |
| Los errores suben sólo después de que arranca un reintento | Amplificación de reintentos | Comparar conteos de peticiones entrantes vs. salientes | Backoff exponencial + jitter; presupuesto de reintentos; circuit breaker |
| Una instancia sirve errores mientras está "saludable" | Health check demasiado superficial | Comparar tasas de 5xx por instancia | Profundizar el chequeo; habilitar `outlier_detection` |
| El failover de Cloud SQL tardó mucho más de 60 s | Transacciones de larga duración / mucho estado sin confirmar | Duraciones de `gcloud sql operations list` | Acortar las transacciones; volver a medir en el próximo simulacro |
| El lag de la réplica de DR crece | El volumen de escritura supera la capacidad de la réplica, o la red | Tendencia de la métrica `replica_lag` | Escalar el tier de la réplica; el RPO actual *es el lag*, así que actualizá el documento de DR |
| El SLO se ve bien, los usuarios se quejan | El SLI se mide en el lugar equivocado | Comparar métricas del LB vs. RUM del cliente | Mover el SLI al punto de vista del usuario |

### 11.3 La última fila merece su propia nota

Un SLI medido en el load balancer no puede ver: fallo de resolución DNS, fallo del handshake TLS, problemas de enrutamiento Anycast, errores de JavaScript del lado del cliente o la propia red del usuario. Un servicio puede estar al 100% según la contabilidad del propio LB mientras una fracción significativa de usuarios no puede alcanzarlo en absoluto.

Precisamente por eso el uptime check de §5 (`resource 7`) no es redundante con el SLO: **la sonda de caja negra mide el camino que el SLO no puede ver, y sigue reportando cuando la telemetría de caja blanca deja de llegar.** La caja blanca se queda ciega exactamente cuando el sistema está más roto.

### 11.4 Postmortem sin culpa — la estructura requerida

Un postmortem es un artefacto de las *operaciones modernas*, y sus propiedades son examinables.

| Sección | Contenido | Antipatrón a evitar |
|---|---|---|
| **Resumen** | Dos oraciones: qué se rompió, para quiénes, por cuánto tiempo | Jerga que nadie fuera del equipo entiende |
| **Impacto** | Usuarios afectados, peticiones fallidas, **error budget consumido**, exposición de ingresos/SLA | "Algunos usuarios pueden haber visto errores" |
| **Línea de tiempo** | Timestamps UTC: comienza el fallo → detectado → reconocido → mitigado → resuelto | Arrancar el reloj en "nos dimos cuenta" |
| **Causa raíz** | Factores contribuyentes, en plural; las condiciones sistémicas | El nombre de una persona |
| **Detección** | Cómo te enteraste; **MTTD**; ¿las alertas existentes lo habrían detectado? | "Nos avisó un cliente" sin ninguna acción de seguimiento |
| **Resolución** | Qué detuvo realmente la hemorragia | Confundir la mitigación con un arreglo permanente |
| **Ítems de acción** | Responsable + fecha límite + prioridad para cada uno; separar *prevenir* / *detectar más rápido* / *mitigar más rápido* | Una lista sin responsables, que es una lista de deseos |
| **Lecciones: qué salió bien / qué salió mal / dónde tuvimos suerte** | Especialmente "dónde tuvimos suerte" — la suerte es un riesgo no registrado | Omitir la sección de la suerte |

**Sin culpa no significa sin consecuencias.** Significa que el análisis apunta al *sistema* que permitió que un ingeniero competente causara una caída — la barrera de protección faltante, la interfaz confusa, el canary ausente — porque culpar al individuo suprime de manera fiable el reporte del que dependés para encontrar el próximo fallo.

---

## 12. Distinciones enfocadas al examen

Estos son los pares que más se confunden en el examen Cloud Digital Leader dentro de este objetivo:

| A | B | El discriminador |
|---|---|---|
| **SLO** | **SLA** | El SLO es interno y más estricto; el SLA es externo con remedio financiero |
| **SLI** | **SLO** | El SLI es la medición; el SLO es el objetivo para esa medición |
| **RTO** | **RPO** | RTO = *downtime* tolerable; RPO = *pérdida de datos* tolerable |
| **Alta disponibilidad** | **Recuperación ante desastres** | HA absorbe el fallo de componentes automáticamente dentro de la operación normal de un diseño; DR restaura el servicio después de que se superan los supuestos del diseño |
| **Backup** | **Replicación** | El backup es un punto en el tiempo al que podés volver (protege contra la corrupción lógica); la replicación es una copia viva (propaga la corrupción) |
| **Fiabilidad** | **Resiliencia** | Fiabilidad = se comporta correctamente a lo largo del tiempo; resiliencia = *se recupera* cuando fallan partes |
| **Monitoreo** | **Observabilidad** | El monitoreo responde preguntas conocidas; la observabilidad te deja hacer preguntas nuevas |
| **Escalabilidad** | **Elasticidad** | Escalabilidad = puede crecer; elasticidad = crece *y se achica* automáticamente con la demanda |
| **Escalado vertical** | **Escalado horizontal** | Máquina más grande vs. más máquinas; sólo el horizontal sobrevive al fallo de una máquina |
| **Toil** | **Trabajo operativo** | El toil es manual, repetitivo, automatizable y escala *linealmente con el crecimiento* |
| **DevOps** | **SRE** | SRE es una implementación concreta de DevOps, con el error budget como su mecanismo de arbitraje |
| **MTTR** | **MTBF** | Tiempo para recuperarse *de* un fallo vs. tiempo *entre* fallos |
| **Zona** | **Región** | Una zona es un dominio de fallo dentro de una región; una región contiene tres o más zonas |
| **Recurso regional** | **Recurso multirregional** | Sobrevive a la pérdida de una zona vs. sobrevive a la pérdida de una región |
| **CapEx** | **OpEx** | La nube convierte el gasto de capital en gasto operativo — el encuadre financiero de la Sección 6 |

### 12.1 La única frase que resume el objetivo

> **Las operaciones modernas en la nube reemplazan "prevenir todo fallo" por "definir la cantidad aceptable de fallo, medirla continuamente en el user journey, gastarla deliberadamente en velocidad de cambio y diseñar el sistema para que se recupere automáticamente cuando se supere."**

Toda técnica de este documento — SLIs, error budgets, alertado por burn rate, distribución multi-zona, PDBs, releases canary, autohealing, planificación de RTO/RPO, postmortems sin culpa — es un detalle de implementación de esa frase.

---

## Referencias

**Guía de examen (alcance autoritativo para este objetivo)**
- Google Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification page — https://cloud.google.com/learn/certification/cloud-digital-leader

**SRE, fiabilidad y error budgets**
- Google SRE Book (texto completo) — https://sre.google/sre-book/table-of-contents/
- Google SRE Book, Cap. 4 "Service Level Objectives" — https://sre.google/sre-book/service-level-objectives/
- Google SRE Book, Cap. 5 "Eliminating Toil" — https://sre.google/sre-book/eliminating-toil/
- Google SRE Book, Cap. 6 "Monitoring Distributed Systems" (Golden Signals) — https://sre.google/sre-book/monitoring-distributed-systems/
- Google SRE Book, Cap. 15 "Postmortem Culture" — https://sre.google/sre-book/postmortem-culture/
- The Site Reliability Workbook, Cap. 2 "Implementing SLOs" (multi-ventana multi-burn-rate) — https://sre.google/workbook/implementing-slos/
- The Site Reliability Workbook, Cap. 5 "Alerting on SLOs" — https://sre.google/workbook/alerting-on-slos/
- Índice de recursos de SRE — https://sre.google/resources/

**Well-Architected Framework**
- Google Cloud Well-Architected Framework — https://cloud.google.com/architecture/framework
- Pilar de fiabilidad — https://cloud.google.com/architecture/framework/reliability
- Pilar de excelencia operativa — https://cloud.google.com/architecture/framework/operational-excellence

**Observabilidad**
- Google Cloud Observability overview — https://cloud.google.com/stackdriver/docs
- Documentación de Cloud Monitoring — https://cloud.google.com/monitoring/docs
- Monitoreo de SLO — https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- Políticas de alerta — https://cloud.google.com/monitoring/alerts
- Uptime checks — https://cloud.google.com/monitoring/uptime-checks
- Documentación de Cloud Logging — https://cloud.google.com/logging/docs
- Métricas basadas en logs — https://cloud.google.com/logging/docs/logs-based-metrics
- Cloud Trace — https://cloud.google.com/trace/docs
- Cloud Profiler — https://cloud.google.com/profiler/docs
- Error Reporting — https://cloud.google.com/error-reporting/docs
- Managed Service for Prometheus — https://cloud.google.com/stackdriver/docs/managed-prometheus
- Personalized Service Health — https://cloud.google.com/service-health/docs

**Resiliencia, HA y recuperación ante desastres**
- Guía de planificación de disaster recovery — https://cloud.google.com/architecture/dr-scenarios-planning-guide
- Bloques de construcción de DR — https://cloud.google.com/architecture/dr-scenarios-building-blocks
- Patrones para apps escalables y resilientes — https://cloud.google.com/architecture/scalable-and-resilient-apps
- Geografía y regiones — https://cloud.google.com/docs/geography-and-regions
- Acuerdos de nivel de servicio de Google Cloud — https://cloud.google.com/terms/sla
- Backup and DR Service — https://cloud.google.com/backup-disaster-recovery/docs

**Compute, GKE y balanceo de carga**
- Grupos de instancias administrados regionales — https://cloud.google.com/compute/docs/instance-groups/distributing-instances-with-regional-instance-groups
- Autohealing de MIG — https://cloud.google.com/compute/docs/instance-groups/autohealing-instances-in-migs
- Autoescalado de grupos de instancias administrados — https://cloud.google.com/compute/docs/autoscaler
- Clusters regionales de GKE — https://cloud.google.com/kubernetes-engine/docs/concepts/types-of-clusters
- Horizontal Pod autoscaling en GKE — https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler
- Balanceo de carga nativo de contenedores (NEGs) — https://cloud.google.com/kubernetes-engine/docs/concepts/container-native-load-balancing
- GKE BackendConfig — https://cloud.google.com/kubernetes-engine/docs/how-to/ingress-features
- Documentación de Cloud Load Balancing — https://cloud.google.com/load-balancing/docs
- Rate limiting de Cloud Armor — https://cloud.google.com/armor/docs/rate-limiting-overview
- Kubernetes: Pod Disruption Budgets — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Kubernetes: Configurar liveness, readiness y startup probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes: Pod topology spread constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/

**Entrega y gestión del cambio**
- Documentación de Cloud Deploy — https://cloud.google.com/deploy/docs
- Estrategias de despliegue de Cloud Deploy (canary) — https://cloud.google.com/deploy/docs/deployment-strategies
- Automatización de Cloud Deploy — https://cloud.google.com/deploy/docs/automation
- Documentación de Cloud Build — https://cloud.google.com/build/docs
- Programa de investigación DORA — https://dora.dev/
- Catálogo de capacidades DORA — https://dora.dev/capabilities/
- Usar las Four Keys para medir el rendimiento de DevOps — https://cloud.google.com/blog/products/devops-sre/using-the-four-keys-to-measure-your-devops-performance

**Capa de datos**
- Alta disponibilidad de Cloud SQL — https://cloud.google.com/sql/docs/postgres/high-availability
- Replicación de Cloud SQL — https://cloud.google.com/sql/docs/postgres/replication
- Recuperación a un punto en el tiempo de Cloud SQL — https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr
- Configuraciones de instancia de Cloud Spanner — https://cloud.google.com/spanner/docs/instance-configurations
- Ubicaciones de buckets de Cloud Storage — https://cloud.google.com/storage/docs/locations

**Referencia del proveedor de Terraform**
- `google_monitoring_slo` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_slo
- `google_monitoring_alert_policy` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_alert_policy
- `google_compute_region_instance_group_manager` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_region_instance_group_manager