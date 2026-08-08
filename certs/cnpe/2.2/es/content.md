# Measuring and Improving Platform Efficiency Using Deployment Metrics and Performance Indicators

> CNPE — Dominio 2 (Platform Analysis) · Tema 2.2 · Peso 6.67
> Perfil: Platform Architect / SRE Senior · Nivel producción

---

## 1. Motivación y problema arquitectónico de producción

Una Internal Developer Platform (IDP) es un **producto interno**, y todo producto sin telemetría de uso y de resultado se gestiona por anécdota. El fallo arquitectónico recurrente en plataformas cloud native no es técnico sino epistemológico: el equipo de plataforma no sabe si la plataforma *acelera* o *frena* la entrega de software, porque mide lo que es fácil (CPU, número de Pods) en lugar de lo que importa (con qué velocidad y seguridad el negocio pone cambios en producción, y a qué costo).

El problema se manifiesta en tres capas que hay que medir por separado y correlacionar:

1. **Flujo de entrega (delivery flow).** ¿Cuánto tarda un commit en llegar a producción? ¿Con qué frecuencia se despliega? ¿Qué porcentaje de despliegues rompe algo? ¿Cuánto se tarda en restaurar? Estas son las **cuatro métricas DORA**, el estándar de facto para *outcome* de entrega.
2. **Salud del servicio (service reliability).** ¿La plataforma cumple sus SLO? El *error budget* es la moneda que convierte fiabilidad en una decisión de negocio: mientras haya presupuesto, se prioriza velocidad; cuando se agota, se congela y se prioriza estabilidad.
3. **Eficiencia de recursos y costo (efficiency / FinOps).** ¿Cuánto de la CPU y memoria *reservada* (requests) se usa realmente? ¿Cuál es el ratio de bin-packing del scheduler? ¿Cuánto cuesta cada despliegue y cada equipo?

El anti-patrón de producción es medir la capa 2 y 3 pero no la 1, o medir vanity metrics (uptime del cluster) que no se correlacionan con la experiencia del developer ni con el resultado de negocio. La consecuencia: se invierte en la plataforma sin evidencia de retorno, y el *platform adoption* (¿los equipos usan realmente la golden path?) queda sin instrumentar.

La arquitectura de medición correcta es un **pipeline de telemetría de eventos de despliegue** (CDEvents/CloudEvents) → **almacenamiento de series temporales** (Prometheus/Mimir) → **derivación de indicadores** (recording rules, SLO generators) → **presupuesto y alerta** (multi-burn-rate) → **visualización y scorecards** (Grafana, Backstage). Todo el resto de este documento construye ese pipeline.

---

## 2. Taxonomía de métricas: qué mide cada framework y cuándo usarlo

No existe un único conjunto de métricas. Cada framework responde una pregunta distinta y opera en una capa distinta de la pila. Confundirlos es el error clásico.

| Framework | Pregunta que responde | Señales | Capa | Fuente de datos típica | Trade-off |
|---|---|---|---|---|---|
| **DORA / Four Keys** | ¿Entregamos rápido y seguro? | Deployment Frequency, Lead Time for Changes, Change Failure Rate, Failed Deployment Recovery Time (antes MTTR) | Outcome de delivery | Eventos de CI/CD, VCS, incident tracker | Métrica de *equipo/producto*, no de request; requiere instrumentar el pipeline, no la app |
| **Golden Signals** (Google SRE) | ¿El servicio está sano para el usuario? | Latency, Traffic, Errors, Saturation | Servicio (request-level) | Instrumentación de app / service mesh | Necesita separar latencia de éxito vs. error; saturation es la más difícil de definir |
| **RED** (Weave) | ¿Cómo se comporta un servicio request-driven? | Rate, Errors, Duration | Servicio | Métricas de app / spanmetrics | No cubre saturación; ideal para microservicios stateless |
| **USE** (Brendan Gregg) | ¿Un recurso está agotado? | Utilization, Saturation, Errors | Recurso (CPU, disco, red) | node-exporter, cAdvisor | Orientado a *resources*, no a *user experience*; complementa RED |
| **SPACE** | ¿Los developers son productivos y están sanos? | Satisfaction, Performance, Activity, Communication, Efficiency | Developer / socio-técnico | Encuestas + señales objetivas | Mezcla cualitativo y cuantitativo; ninguna métrica sola es válida |
| **SLI/SLO/Error Budget** | ¿Cumplimos el objetivo de fiabilidad acordado? | Ratio good/total events, burn rate | Contrato de servicio | Derivado de Golden Signals/RED | Requiere elegir el SLI *correcto* y una ventana; un mal SLI da falsa confianza |
| **Platform adoption / efficiency** | ¿Usan la plataforma y a qué costo? | % golden-path adoption, self-service ratio, cost per deploy, request/usage ratio | Producto plataforma | kube-state-metrics, Backstage, FinOps | Difícil de atribuir causalidad; requiere *labels* de ownership consistentes |

**Regla de composición:** DORA mide el *resultado* del sistema de entrega; Golden Signals/RED/USE miden la *salud* de lo entregado; SLO convierte esa salud en un *contrato* con presupuesto; SPACE y adoption miden el *efecto humano y económico*. Una plataforma madura instrumenta las cuatro y las correlaciona en un único dashboard de "platform health".

### 2.1. Las cuatro métricas DORA — definición formal

| Métrica | Definición operativa | Unidad | Elite (DORA 2023/2024) | Cómo se deriva |
|---|---|---|---|---|
| **Deployment Frequency (DF)** | Frecuencia con que la organización despliega a producción con éxito | despliegues/tiempo | On-demand (múltiples/día) | Contar `deployment.finished` con outcome=success |
| **Lead Time for Changes (LT)** | Tiempo desde que el código se commitea hasta que corre en producción | duración (p50/p95) | < 1 día | `deploy_time − commit_time` del change incluido |
| **Change Failure Rate (CFR)** | % de despliegues que causan una degradación que requiere remediación (rollback, hotfix, patch) | porcentaje | 5–10% | `failed_deploys / total_deploys` |
| **Failed Deployment Recovery Time** (ex-MTTR) | Tiempo para restaurar el servicio tras un despliegue fallido | duración | < 1 hora | `restore_time − failure_start_time` |

> Nota terminológica: DORA renombró "Time to Restore Service / MTTR" a **Failed Deployment Recovery Time** en los reportes recientes, para acotarlo a fallos originados en despliegues y no a incidentes cualesquiera. En el examen conviene reconocer ambos nombres.

---

## 3. Arquitectura de instrumentación: de eventos de despliegue a métricas

### 3.1. El estándar de eventos: CDEvents (CDF) sobre CloudEvents

Para computar DORA de forma vendor-neutral, la CD Foundation define **CDEvents**: un vocabulario común de eventos de ciclo de vida de entrega (encapsulados en CloudEvents de la CNCF). En lugar de acoplarse a la API de Jenkins, GitLab o Argo, cada herramienta emite eventos normalizados que un colector agrega.

Ejemplo de un CDEvent `dev.cdevents.service.deployed` que marca un despliegue exitoso a producción — es la materia prima de Deployment Frequency y el timestamp final de Lead Time:

```json
{
  "context": {
    "version": "0.4.1",
    "id": "271069a8-fc18-44f1-b38f-9d70a1695819",
    "source": "/argocd/prod-cluster",
    "type": "dev.cdevents.service.deployed.0.2.0",
    "timestamp": "2026-08-07T11:42:07.331Z"
  },
  "subject": {
    "id": "checkout-api",
    "source": "/argocd/prod-cluster",
    "type": "service",
    "content": {
      "environment": { "id": "production", "source": "/argocd/prod-cluster" },
      "artifactId": "pkg:oci/checkout-api@sha256:3f7a...c19b?tag=v2.14.0"
    }
  },
  "customData": {
    "commitSha": "9d70a1695819c4e2",
    "commitTimestamp": "2026-08-07T09:18:44Z",
    "deploymentOutcome": "success"
  }
}
```

`deploy_timestamp − commitTimestamp = Lead Time` para ese cambio (aquí ~2h23m). El `deploymentOutcome` alimenta CFR. Un `dev.cdevents.incident.detected`/`incident.resolved` posterior, correlacionado por `artifactId`, alimenta Failed Deployment Recovery Time.

### 3.2. Colector de eventos → serie temporal (patrón Four Keys / DevLake)

Dos enfoques dominan la industria:

| Enfoque | Herramienta | Modelo | Trade-off |
|---|---|---|---|
| **Event pipeline** | Google **Four Keys** (Cloud Events → BigQuery) | Webhooks de VCS/CD normalizados a eventos, queries SQL | Simple, pero acoplado a GCP/BigQuery |
| **Data integration** | Apache **DevLake** | Conectores a GitHub/GitLab/Jira/Jenkins → data lake → DORA dashboards | Muy completo, pesado de operar |
| **Metrics-native** | Exporter propio → **Prometheus** | Eventos de despliegue expuestos como métricas y derivados con recording rules | Encaja con el resto del stack CNCF; requiere escribir el exporter |

En una plataforma CNCF pura, el tercer enfoque integra mejor. Se expone un exporter que traduce CDEvents a métricas Prometheus:

```
# HELP cd_deployment_total Total de despliegues a producción por resultado
# TYPE cd_deployment_total counter
cd_deployment_total{service="checkout-api",environment="production",outcome="success",team="payments"} 1287
cd_deployment_total{service="checkout-api",environment="production",outcome="failure",team="payments"} 41

# HELP cd_lead_time_seconds Distribución del lead time commit→deploy
# TYPE cd_lead_time_seconds histogram
cd_lead_time_seconds_bucket{service="checkout-api",team="payments",le="3600"} 402
cd_lead_time_seconds_bucket{service="checkout-api",team="payments",le="14400"} 1190
cd_lead_time_seconds_bucket{service="checkout-api",team="payments",le="86400"} 1281
cd_lead_time_seconds_bucket{service="checkout-api",team="payments",le="+Inf"} 1287
cd_lead_time_seconds_sum{service="checkout-api",team="payments"} 9.32e6
cd_lead_time_seconds_count{service="checkout-api",team="payments"} 1287

# HELP cd_deploy_recovery_seconds Tiempo de restauración tras deploy fallido
# TYPE cd_deploy_recovery_seconds histogram
cd_deploy_recovery_seconds_bucket{service="checkout-api",team="payments",le="900"} 33
cd_deploy_recovery_seconds_bucket{service="checkout-api",team="payments",le="3600"} 40
cd_deploy_recovery_seconds_bucket{service="checkout-api",team="payments",le="+Inf"} 41
cd_deploy_recovery_seconds_sum{service="checkout-api",team="payments"} 78120
cd_deploy_recovery_seconds_count{service="checkout-api",team="payments"} 41
```

### 3.3. Recording rules: derivar las cuatro métricas DORA en Prometheus

Las recording rules pre-computan los indicadores caros para que el dashboard sea instantáneo y consistente. Manifiesto completo, sin recortar:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dora-metrics
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: platform-observability
    role: recording-rules
spec:
  groups:
    - name: dora.deployment_frequency
      interval: 30s
      rules:
        # Deployment Frequency: despliegues exitosos/día, ventana móvil de 7d
        - record: dora:deployment_frequency:rate7d
          expr: |
            sum by (team, service) (
              increase(cd_deployment_total{environment="production",outcome="success"}[7d])
            ) / 7

    - name: dora.lead_time
      interval: 30s
      rules:
        # Lead Time p50 y p95 (histograma), ventana 7d
        - record: dora:lead_time_seconds:p50_7d
          expr: |
            histogram_quantile(0.50,
              sum by (team, service, le) (
                rate(cd_lead_time_seconds_bucket[7d])
              )
            )
        - record: dora:lead_time_seconds:p95_7d
          expr: |
            histogram_quantile(0.95,
              sum by (team, service, le) (
                rate(cd_lead_time_seconds_bucket[7d])
              )
            )

    - name: dora.change_failure_rate
      interval: 30s
      rules:
        # CFR = fallidos / total, ventana 30d (numéricamente estable)
        - record: dora:change_failure_rate:ratio30d
          expr: |
            sum by (team, service) (increase(cd_deployment_total{environment="production",outcome="failure"}[30d]))
            /
            clamp_min(
              sum by (team, service) (increase(cd_deployment_total{environment="production"}[30d])),
              1
            )

    - name: dora.recovery_time
      interval: 30s
      rules:
        # Failed Deployment Recovery Time p95, ventana 30d
        - record: dora:deploy_recovery_seconds:p95_30d
          expr: |
            histogram_quantile(0.95,
              sum by (team, service, le) (
                rate(cd_deploy_recovery_seconds_bucket[30d])
              )
            )
```

`clamp_min(..., 1)` evita la división por cero cuando un servicio nuevo aún no tiene despliegues en la ventana — un fallo silencioso clásico que produce `NaN` en el panel.

---

## 4. SLIs, SLOs y error budget como indicador de eficiencia de fiabilidad

El SLO es el indicador que convierte "el servicio está bien" en un número accionable. La eficiencia de la plataforma se mide en parte por su capacidad de **cumplir SLOs mientras maximiza velocidad de cambio** — exactamente el trade-off que el error budget arbitra.

### 4.1. Elegir el SLI: el error más frecuente

| Tipo de SLI | Fórmula | Bueno para | Riesgo |
|---|---|---|---|
| **Availability (request-based)** | good requests / total requests | APIs request-driven | Requests desiguales sesgan el ratio |
| **Latency** | requests bajo umbral / total | Experiencia de usuario | Elegir mal el umbral (p95 vs p99) |
| **Quality/correctness** | responses correctas / total | Pipelines de datos | Difícil de instrumentar |
| **Freshness** | datos frescos / total | Batch, streaming | Necesita timestamp de origen |
| **Windowed / time-based** | ventanas buenas / ventanas totales | Servicios no-request | Menos sensible que event-based |

### 4.2. Generación de SLOs con Sloth (multi-window multi-burn-rate)

Escribir a mano las reglas de burn-rate es propenso a error. **Sloth** (proyecto CNCF-adjacent) genera desde una spec declarativa las recording rules del SLI, las metadata rules del error budget y las **alertas multiventana/multi-burn-rate** de la guía Google SRE. Spec de entrada:

```yaml
version: "prometheus/v1"
service: "checkout-api"
labels:
  team: "payments"
  tier: "critical"
slos:
  - name: "requests-availability"
    objective: 99.9        # 3 nueves → 0.1% error budget mensual
    description: "99.9% de las requests HTTP no-5xx en 30d"
    sli:
      events:
        error_query: |
          sum(rate(http_request_duration_seconds_count{job="checkout-api",code=~"5.."}[{{.window}}]))
        total_query: |
          sum(rate(http_request_duration_seconds_count{job="checkout-api"}[{{.window}}]))
    alerting:
      name: CheckoutApiHighErrorRate
      page_alert:
        labels:
          severity: page
      ticket_alert:
        labels:
          severity: ticket
```

Sloth genera (`sloth generate`) un `PrometheusRule` con reglas como estas — el corazón del error budget:

```yaml
# --- fragmento generado por Sloth (recording rules del error budget) ---
- record: slo:sli_error:ratio_rate5m
  expr: |
    (sum(rate(http_request_duration_seconds_count{job="checkout-api",code=~"5.."}[5m])))
    /
    (sum(rate(http_request_duration_seconds_count{job="checkout-api"}[5m])))
  labels: { sloth_service: checkout-api, sloth_slo: requests-availability, sloth_window: 5m }

- record: slo:error_budget:ratio
  expr: "1 - 0.999"
  labels: { sloth_service: checkout-api, sloth_slo: requests-availability }

# --- alerta multi-burn-rate: quema rápida (page) ---
- alert: CheckoutApiHighErrorRate
  expr: |
    (
      max(slo:sli_error:ratio_rate5m{sloth_slo="requests-availability"} > (14.4 * 0.001))
      and
      max(slo:sli_error:ratio_rate1h{sloth_slo="requests-availability"} > (14.4 * 0.001))
    )
    or
    (
      max(slo:sli_error:ratio_rate30m{sloth_slo="requests-availability"} > (6 * 0.001))
      and
      max(slo:sli_error:ratio_rate6h{sloth_slo="requests-availability"}  > (6 * 0.001))
    )
  labels: { severity: page, sloth_slo: requests-availability }
  annotations:
    summary: "Error budget de checkout-api quemándose demasiado rápido"
```

Los factores **14.4** (2% del presupuesto mensual en 1h → page inmediato) y **6** (5% en 6h → page) son la tabla canónica de burn rates del capítulo *Alerting on SLOs* del SRE Workbook. La combinación `AND` de ventana corta y larga elimina falsos positivos por picos transitorios.

### 4.3. SLO nativo de Kubernetes con Pyrra

**Pyrra** ofrece un CRD `ServiceLevelObjective` y una UI dedicada, generando también las reglas de Prometheus pero con un objeto Kubernetes gestionable por GitOps:

```yaml
apiVersion: pyrra.dev/v1alpha1
kind: ServiceLevelObjective
metadata:
  name: checkout-api-availability
  namespace: payments
  labels:
    pyrra.dev/team: payments
    pyrra.dev/tier: critical
spec:
  target: "99.9"          # objetivo
  window: 30d             # ventana rolling del budget
  description: "Disponibilidad HTTP de checkout-api"
  indicator:
    ratio:
      errors:
        metric: http_request_duration_seconds_count{job="checkout-api",code=~"5.."}
      total:
        metric: http_request_duration_seconds_count{job="checkout-api"}
  alerting:
    burnrates:
      enabled: true
```

| Herramienta | Modelo | Ventaja | Trade-off |
|---|---|---|---|
| **Sloth** | Genera PrometheusRule desde YAML (CLI o operator) | Reglas SRE-Workbook exactas, portable | El SLO no es un objeto de primera clase en el cluster |
| **Pyrra** | CRD + operator + UI | GitOps-native, UI de budget, filtrado por labels | Un componente más que operar |
| **OpenSLO** | Spec vendor-neutral (estándar) | Portable entre backends | Necesita un runtime que la compile |

---

## 5. Eficiencia de recursos y costo: del request/usage al cost-per-deploy

La eficiencia de la plataforma no es solo velocidad; es **entregar la fiabilidad objetivo al menor costo de recursos**. Aquí las métricas clave son el ratio request/usage (¿reservamos más CPU/memoria de la que usamos?), la eficiencia de bin-packing del scheduler y el costo atribuido por equipo.

### 5.1. Métricas de eficiencia de recursos (kube-state-metrics + cAdvisor)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-efficiency
  namespace: monitoring
  labels: { role: recording-rules }
spec:
  groups:
    - name: efficiency.resource_utilization
      interval: 60s
      rules:
        # Eficiencia de CPU: uso real / CPU reservada (requests). <1 = sobre-provisión.
        - record: efficiency:cpu_utilization:ratio
          expr: |
            sum by (namespace, team) (
              rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])
            )
            /
            clamp_min(
              sum by (namespace, team) (
                kube_pod_container_resource_requests{resource="cpu"}
              ), 0.001
            )

        # Eficiencia de memoria: working set / memoria reservada
        - record: efficiency:memory_utilization:ratio
          expr: |
            sum by (namespace, team) (
              container_memory_working_set_bytes{container!="",container!="POD"}
            )
            /
            clamp_min(
              sum by (namespace, team) (
                kube_pod_container_resource_requests{resource="memory"}
              ), 1
            )

        # Slack de CPU: núcleos reservados y NO usados (candidatos a recorte / ahorro)
        - record: efficiency:cpu_slack:cores
          expr: |
            sum by (namespace, team) (kube_pod_container_resource_requests{resource="cpu"})
            -
            sum by (namespace, team) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m]))

    - name: efficiency.bin_packing
      interval: 60s
      rules:
        # Eficiencia de bin-packing: requests totales / capacidad allocatable del cluster
        - record: efficiency:cluster_cpu_packing:ratio
          expr: |
            sum(kube_pod_container_resource_requests{resource="cpu"})
            /
            sum(kube_node_status_allocatable{resource="cpu"})
```

| Indicador | Fórmula | Objetivo saludable | Qué revela si está mal |
|---|---|---|---|
| CPU utilization ratio | usage / requests | 0.6–0.8 | <0.3: sobre-provisión masiva (dinero desperdiciado). >1: throttling, requests demasiado bajas |
| Memory utilization ratio | working set / requests | 0.6–0.85 | >0.9: riesgo de OOMKill; <0.4: requests infladas |
| Bin-packing ratio | Σrequests / Σallocatable | 0.5–0.7 | <0.3: cluster demasiado grande; >0.85: sin headroom para picos/drenaje de nodos |
| CFR vs. rollout speed | correlación DORA↔SLO | — | CFR alto + budget quemado = ir demasiado rápido para la madurez de la plataforma |

### 5.2. Recomendaciones automáticas: VerticalPodAutoscaler en modo recommender

VPA en modo `Off` (solo recomienda, no aplica) es un excelente motor de eficiencia: expone cuánto *deberían* pedir los Pods frente a lo que piden.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: checkout-api-recommender
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  updatePolicy:
    updateMode: "Off"          # solo recomienda; no reinicia Pods
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        controlledResources: ["cpu", "memory"]
        minAllowed: { cpu: 50m, memory: 64Mi }
        maxAllowed: { cpu: "2", memory: 2Gi }
```

### 5.3. Costo por despliegue y por equipo (OpenCost)

**OpenCost** (proyecto CNCF, especificación de referencia para Kubernetes cost monitoring) atribuye costo a namespaces/labels usando los requests y el precio de nodo. Combinado con `cd_deployment_total` se obtiene el **cost-per-deploy**, un KPI de eficiencia de plataforma de primer orden.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata: { name: cost-efficiency, namespace: monitoring }
spec:
  groups:
    - name: efficiency.cost
      interval: 300s
      rules:
        # Costo mensualizado por equipo (USD/mes) desde OpenCost
        - record: efficiency:cost_monthly_usd:by_team
          expr: |
            sum by (team) (
              node_total_hourly_cost * on(node) group_left
              (kube_node_labels)
            ) * 730
        # Cost-per-deploy: costo mensual del equipo / despliegues del mes
        - record: efficiency:cost_per_deploy_usd
          expr: |
            efficiency:cost_monthly_usd:by_team
            /
            clamp_min(
              sum by (team) (increase(cd_deployment_total{environment="production",outcome="success"}[30d])),
              1
            )
```

---

## 6. Cierre del loop: quality gates SLO-driven (Argo Rollouts / Keptn)

Medir no basta; el objetivo del tema es **improving** la eficiencia. El patrón de producción es usar los mismos indicadores como **compuerta automática** del despliegue: un canary solo progresa si sus SLIs se mantienen dentro del budget. Esto reduce directamente el CFR.

### 6.1. AnalysisTemplate de Argo Rollouts consultando Prometheus

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-and-latency
  namespace: payments
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      count: 5
      successCondition: result[0] >= 0.995
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus-operated.monitoring:9090
          query: |
            sum(rate(http_request_duration_seconds_count{
              job="{{args.service-name}}", code!~"5.."}[2m]))
            /
            sum(rate(http_request_duration_seconds_count{
              job="{{args.service-name}}"}[2m]))
    - name: p95-latency
      interval: 1m
      count: 5
      successCondition: result[0] <= 0.3        # 300 ms
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus-operated.monitoring:9090
          query: |
            histogram_quantile(0.95,
              sum by (le) (rate(http_request_duration_seconds_bucket{
                job="{{args.service-name}}"}[2m])))
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout-api
  namespace: payments
spec:
  replicas: 6
  selector:
    matchLabels: { app: checkout-api }
  template:
    metadata:
      labels: { app: checkout-api }
    spec:
      containers:
        - name: checkout-api
          image: registry.internal/checkout-api:v2.14.0
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits:   { cpu: "1",  memory: 512Mi }
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: success-rate-and-latency
            args:
              - name: service-name
                value: checkout-api
        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 100
```

Si el `AnalysisRun` falla (SLI fuera de umbral), Argo Rollouts hace **rollback automático** — el despliegue no cuenta como fallo de producción, mejorando CFR y recovery time simultáneamente.

### 6.2. Keptn Lifecycle Toolkit — evaluación de SLO como pre/post-deployment task

Keptn (proyecto CNCF) añade `KeptnMetric` y evaluaciones que bloquean o promueven un despliegue según objetivos declarados, extendiendo la observabilidad al ciclo de vida del workload:

```yaml
apiVersion: metrics.keptn.sh/v1
kind: KeptnMetric
metadata:
  name: checkout-error-rate
  namespace: payments
spec:
  provider:
    name: prometheus
  query: |
    sum(rate(http_request_duration_seconds_count{job="checkout-api",code=~"5.."}[5m]))
    / sum(rate(http_request_duration_seconds_count{job="checkout-api"}[5m]))
  fetchIntervalSeconds: 30
```

---

## 7. Comandos CLI y salidas de terminal reales

### 7.1. Validar las recording rules antes de aplicarlas

```console
$ promtool check rules dora-metrics.yaml
Checking dora-metrics.yaml
  SUCCESS: 6 rules found

$ kubectl apply -f dora-metrics.yaml
prometheusrule.monitoring.coreos.com/dora-metrics created
```

### 7.2. Consultar un indicador DORA por la HTTP API de Prometheus

```console
$ curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=dora:deployment_frequency:rate7d{team="payments"}' | jq '.data.result'
[
  {
    "metric": { "team": "payments", "service": "checkout-api" },
    "value": [ 1754566927.331, "5.428571428571429" ]
  }
]
```

→ 5.4 despliegues/día de media móvil 7d: nivel **Elite** de Deployment Frequency.

```console
$ curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=dora:lead_time_seconds:p95_7d{service="checkout-api"}' \
  | jq -r '.data.result[0].value[1]'
79320.5
```

→ p95 Lead Time = 79 320 s ≈ **22 h** → nivel High (por debajo de 1 día, cerca de Elite).

```console
$ curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=dora:change_failure_rate:ratio30d{service="checkout-api"}' \
  | jq -r '.data.result[0].value[1]'
0.031
```

→ CFR = 3.1% → **Elite** (< 5%).

### 7.3. Leer las recomendaciones del VPA (eficiencia de recursos)

```console
$ kubectl describe vpa checkout-api-recommender -n payments
Name:         checkout-api-recommender
Namespace:    payments
...
Status:
  Recommendation:
    Container Recommendations:
      Container Name:  checkout-api
      Lower Bound:
        Cpu:     120m
        Memory:  180Mi
      Target:
        Cpu:     180m
        Memory:  240Mi
      Uncapped Target:
        Cpu:     180m
        Memory:  240Mi
      Upper Bound:
        Cpu:     420m
        Memory:  410Mi
```

→ El Pod pide 250m CPU / 256Mi (§6.1) pero el *target* recomendado es 180m / 240Mi. **Slack de 70m por réplica × 6 = 420m** desperdiciados; recortar el request mejora el bin-packing sin riesgo.

### 7.4. Medir el ratio de eficiencia en vivo

```console
$ curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=efficiency:cpu_utilization:ratio{namespace="payments"}' \
  | jq -r '.data.result[0].value[1]'
0.34
```

→ 34% de la CPU reservada realmente en uso: sobre-provisión clara, oportunidad de ahorro confirmada por el VPA.

### 7.5. Estado de un canary con quality gate

```console
$ kubectl argo rollouts get rollout checkout-api -n payments --watch
Name:            checkout-api
Namespace:       payments
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          2/6
  SetWeight:     10
  ActualWeight:  10
Images:          registry.internal/checkout-api:v2.13.0 (stable)
                 registry.internal/checkout-api:v2.14.0 (canary)
Replicas:
  Desired:       6
  Current:       7
  Updated:       1
  Ready:         7
  Available:     7

NAME                                       KIND         STATUS        AGE  INFO
⟳ checkout-api                             Rollout      ॥ Paused      41d
├──# revision:24
│  └──⧉ checkout-api-6df9c88c4f            ReplicaSet   ✔ Healthy     92s  canary
│     └──□ checkout-api-6df9c88c4f-tzq8p   Pod          ✔ Running     92s  ready:1/1
└──# revision:23
   └──⧉ checkout-api-77bd5f9d64            ReplicaSet   ✔ Healthy     41d  stable
```

Y cuando el análisis SLO falla:

```console
$ kubectl argo rollouts get rollout checkout-api -n payments
Status:          ✖ Degraded
Message:         RolloutAborted: metric "success-rate" assessed Failed:
                 count: 2, failureLimit: 1
...
$ kubectl describe analysisrun checkout-api-6df9c88c4f-2-1 -n payments | grep -A3 'Measurements'
    Measurements:
      Value:       0.981          # < 0.995 → falla el gate
      Phase:       Failed
```

→ Rollback automático; el cambio no llega a "deployment failed" contable, sino a "aborted before impact".

---

## 8. Guía de verificación y diagnóstico de fallas

### 8.1. Ladder de verificación (de lo barato a lo caro)

| # | Qué verificar | Comando | Fallo típico |
|---|---|---|---|
| 1 | Sintaxis de las rules | `promtool check rules *.yaml` | Indentación PromQL, `le` faltante en histogram_quantile |
| 2 | Que las series existen | `curl .../api/v1/query?query=cd_deployment_total` → no vacío | Exporter caído; label `team` ausente |
| 3 | Que la recording rule evalúa | `curl .../api/v1/query?query=dora:...` | `NaN`/vacío por división por cero (falta `clamp_min`) |
| 4 | Cardinalidad sana | `curl .../api/v1/status/tsdb \| jq '.data.seriesCountByMetricName'` | Explosión de series por labels de alta cardinalidad |
| 5 | Alertas cargadas | `curl .../api/v1/rules \| jq '.data.groups[].rules[].name'` | Regla no recargada tras apply |
| 6 | Burn-rate dispara | test sintético con `promtool test rules` | Umbral de burn rate mal calculado |

### 8.2. Fallas concretas y su firma

**A. El panel DORA muestra `NaN` o "No data".**
Causa casi siempre: división por cero en CFR/utilización para un servicio sin datos en la ventana. Firma:

```console
$ curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=dora:change_failure_rate:ratio30d{service="new-svc"}'
{"status":"success","data":{"resultType":"vector","result":[]}}
```

Fix: envolver el denominador en `clamp_min(x, 1)` (ya aplicado en §3.3). Verificación: el query devuelve `0` en lugar de vacío.

**B. Lead Time p95 sube abruptamente y es imposible.**
Firma: `histogram_quantile` devuelve valores en el último bucket finito porque los buckets están mal dimensionados y todo cae en `+Inf`.

```console
$ curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=sum(rate(cd_lead_time_seconds_bucket{le="+Inf"}[7d])) - sum(rate(cd_lead_time_seconds_bucket{le="86400"}[7d]))' \
  | jq -r '.data.result[0].value[1]'
0.42
```

→ 42% de las muestras caen por encima del bucket de 1 día: los buckets no cubren el rango real. Fix: añadir buckets (p.ej. `604800` = 7d) al histograma del exporter. `histogram_quantile` **no puede** estimar por encima del último bucket finito.

**C. La alerta de burn-rate no dispara pese a incidente evidente.**
Diagnóstico con test unitario de reglas:

```console
$ promtool test rules slo_burnrate_test.yaml
Unit Testing:  slo_burnrate_test.yaml
  FAILED:
    alert CheckoutApiHighErrorRate, time 15m0s:
        exp:  [ severity="page" ]
        got:  [ ]
```

→ La condición `AND` de ventana larga (1h) aún no acumuló señal a los 15 min. Comportamiento correcto: la ventana larga evita falsos positivos. Si el incidente es real y sostenido, dispara al superar la ventana larga; para quema catastrófica, es la regla de 5m/1h la que actúa. Verificar que ambas recording rules `ratio_rate5m` y `ratio_rate1h` existen:

```console
$ curl -sG http://localhost:9090/api/v1/rules | jq -r \
    '.data.groups[].rules[] | select(.name|test("sli_error:ratio_rate")) | .name' | sort -u
slo:sli_error:ratio_rate1h
slo:sli_error:ratio_rate5m
slo:sli_error:ratio_rate6h
slo:sli_error:ratio_rate30m
```

Si falta alguna, la alerta multiventana nunca evalúa `true` (un `and` con vector vacío es vacío).

**D. Explosión de cardinalidad tras añadir label `commitSha` a una métrica.**
Firma: crecimiento de memoria de Prometheus y series únicas por commit (infinito). Nunca poner IDs de alta cardinalidad (`commitSha`, `deployId`, `pod uid`) como labels de métricas de counter/histogram; llevarlos a **exemplars** o a logs/traces.

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[] | select(.name=="cd_deployment_total")'
{ "name": "cd_deployment_total", "value": 1_284_530 }
```

→ 1.28M series para un counter de despliegues es una firma inequívoca de label mal elegido. Fix: quitar `commitSha` del label set; exponerlo como exemplar.

**E. La correlación DORA↔SLO revela el trade-off real.**
Diagnóstico de eficiencia, no de fallo: si `dora:deployment_frequency:rate7d` sube y a la vez `slo:sli_error:ratio` supera el budget, la plataforma va **más rápido de lo que su fiabilidad tolera**. La acción no es técnica sino de política: congelar despliegues no críticos hasta recuperar budget (política de error budget). Verificación: el panel de budget restante debe cruzar cero antes de aplicar el freeze.

### 8.3. Checklist de "métrica confiable"

- [ ] El SLI mide la experiencia del usuario, no un proxy interno (p.ej. éxito de request, no CPU).
- [ ] Toda ratio tiene `clamp_min` en el denominador.
- [ ] Los histogramas cubren el rango real (verificado con el bucket `+Inf` residual < 1%).
- [ ] Ningún label de counter/histogram tiene cardinalidad ilimitada.
- [ ] Las alertas de burn-rate tienen test unitario (`promtool test rules`) en CI.
- [ ] Los labels `team`/`service`/`environment` son consistentes en TODAS las fuentes (DORA, SLO, coste) para poder correlacionar.
- [ ] La ventana de CFR/recovery es suficientemente larga (≥30d) para ser estadísticamente estable.

---

## 9. Referencias

- CNPE Curriculum (CNCF/LF): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- DORA — DevOps Research and Assessment (Four Keys, capabilities): https://dora.dev/
- Google Cloud — Four Keys project: https://github.com/dora-team/fourkeys
- Google SRE Book — Service Level Objectives: https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook — Alerting on SLOs (multi-window multi-burn-rate): https://sre.google/workbook/alerting-on-slos/
- Google SRE Book — Monitoring Distributed Systems (Four Golden Signals): https://sre.google/sre-book/monitoring-distributed-systems/
- CDEvents (CD Foundation): https://cdevents.dev/
- CloudEvents (CNCF): https://cloudevents.io/
- Apache DevLake (DORA metrics platform): https://devlake.apache.org/
- Prometheus — Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — `histogram_quantile` y buckets: https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
- Prometheus Operator — PrometheusRule CRD: https://prometheus-operator.dev/docs/api-reference/api/
- Sloth — SLO generator para Prometheus: https://sloth.dev/
- Pyrra — SLOs para Kubernetes/Prometheus: https://github.com/pyrra-dev/pyrra
- OpenSLO — especificación vendor-neutral de SLOs: https://github.com/OpenSLO/OpenSLO
- OpenTelemetry (CNCF) — spanmetrics / RED: https://opentelemetry.io/docs/
- Argo Rollouts — Analysis y progressive delivery: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Keptn (CNCF) — Lifecycle Toolkit y KeptnMetric: https://keptn.sh/stable/docs/
- Kubernetes VerticalPodAutoscaler: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- OpenCost (CNCF) — Kubernetes cost monitoring: https://www.opencost.io/
- kube-state-metrics: https://github.com/kubernetes/kube-state-metrics
- The SPACE of Developer Productivity (ACM Queue): https://queue.acm.org/detail.cfm?id=3454124
- Brendan Gregg — USE Method: https://www.brendangregg.com/usemethod.html
- Weaveworks — RED Method: https://www.weave.works/blog/the-red-method-key-metrics-for-microservices-architecture/