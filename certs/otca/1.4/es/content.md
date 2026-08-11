# OpenTelemetry Certified Associate (OTCA)
## Dominio 1 — Fundamentos de la Observabilidad
### Tema 1.4 — Análisis y Resultados

> **Peso en el examen:** 4.5 · **Perfil:** SRE avanzado / Arquitecto de plataforma
> **Prerrequisitos:** 1.1 Telemetría vs. Observabilidad · 1.2 Señales (traces, metrics, logs) · 1.3 Propagación de contexto

---

## 1. Motivación: el problema arquitectónico de los "datos sin decisiones"

La instrumentación es un medio, no un fin. Un servicio puede emitir un trace perfectamente modelado para cada request, un histogram para cada llamada a una dependencia y una línea de log estructurada para cada transición de estado — y aun así dejar al ingeniero de guardia a ciegas a las 03:14. La brecha no está en la *recolección*; está en el **análisis y en los resultados que el análisis produce.**

"Análisis y Resultados" es la competencia de OTCA que cierra el ciclo:

```
        ┌─────────────┐   ┌───────────┐   ┌────────────┐   ┌──────────────┐
signals │  instrument │ → │  collect  │ → │   store    │ → │   ANALYZE    │
        └─────────────┘   └───────────┘   └────────────┘   └──────┬───────┘
                                                                   │
                       outcomes ◄──────────────────────────────────┘
                       (detect · triage · RCA · improve)
```

El modo de fallo en producción que aborda este tema es concreto y costoso: los equipos instrumentan de forma agresiva, envían la telemetría a un backend y descubren durante el *primer* incidente real que los datos no pueden responder la pregunta que se está haciendo. Síntomas:

- **Falta el resultado de detección** — una regresión del SLO es real durante 20 minutos antes de que alguien lo note, porque la alerta se basa en un umbral sobre una métrica cruda (`cpu > 80%`) en lugar de en síntomas (ratio de errores de cara al usuario). El MTTD es alto.
- **Falta el resultado de triage** — una alerta se dispara pero la métrica que la disparó no puede pivotarse hacia los traces que la causaron. No hay exemplar, ni `trace_id` compartido, ni atributo de recurso correlacionado. El ingeniero tiene un número y ningún camino desde el número hasta una causa. El MTTR se dispara.
- **Falta el resultado de RCA** — el histogram muestra que la latencia p99 se duplicó, pero el sampler basado en cabecera (head-based) descartó justamente los traces lentos y con errores (la cola interesante), así que los traces de los exemplars son todos éxitos rápidos. Los datos que importaban fueron analizados hasta desaparecer *antes* de ser almacenados.
- **Resultado de costo/cardinalidad invertido** — una dimensión `user.id` con buenas intenciones convirtió una métrica de 40 series en una métrica de 4 millones de series; el backend de análisis ahora sufre OOM durante el mismo incidente que se suponía debía ayudar a resolver.

La idea arquitectónica que evalúa OTCA: **diseñás la telemetría para el análisis que pretendés realizar y el resultado que pretendés producir.** El nivel de agregación, el presupuesto de cardinalidad, la estrategia de sampling y las claves de correlación entre señales son todas *decisiones de análisis* tomadas en el momento de la instrumentación y del pipeline, no en el momento de la consulta.

---

## 2. La taxonomía de resultados — para *qué* sirve el análisis

Toda actividad analítica se corresponde con uno de cuatro resultados. Esta taxonomía es el modelo mental que espera el examen, y la checklist práctica que un arquitecto usa para justificar cada señal.

| Resultado | Pregunta que responde | Señal primaria | Señales secundarias | Presupuesto de latencia | Métrica clave |
|---|---|---|---|---|---|
| **Detección** | "¿Hay algo mal *para el usuario*?" | Metrics (SLIs) | Logs (tasa de errores) | segundos–minutos | **MTTD** (tiempo medio de detección) |
| **Triage** | "¿Dónde y qué tan grave?" | Metrics + Traces | Logs | minutos | alcance/radio de impacto |
| **Causa raíz (RCA)** | "¿*Por qué* está mal?" | Traces | Logs, profiles | minutos–horas | **MTTR** (tiempo medio de resolución) |
| **Mejora continua** | "¿El sistema mejora/empeora con el tiempo?" | Metrics (agregadas) | Traces (con sampling) | días–trimestres | tendencia del error budget, historial de SLO |

La cadena es direccional: **la detección dispara el triage, el triage acota hacia la RCA, la RCA alimenta la mejora.** El valor de OpenTelemetry es que la *misma* telemetría correlacionada sirve a los cuatro, porque las señales comparten contexto (`trace_id`, `span_id`) e identidad de recurso (`service.name`, `service.namespace`, `k8s.pod.name`).

### 2.1 Frameworks de señales de oro: RED vs. USE vs. Four Golden Signals

El análisis necesita una disciplina de *dimensionamiento* para medir las cosas correctas. Tres frameworks dominan; son complementarios, no competidores.

| Framework | Alcance | Señales que prescribe | Mejor para | Punto ciego |
|---|---|---|---|---|
| **RED** (Weaver) | Servicios orientados a requests | **R**ate, **E**rrors, **D**uration | Microservicios, APIs, cualquier cosa con requests | No dice nada sobre la saturación de recursos |
| **USE** (Gregg) | Recursos | **U**tilization, **S**aturation, **E**rrors | Hosts, discos, colas, CPU, memoria | Ignora la experiencia por request |
| **Four Golden Signals** (Google SRE) | Sistemas de cara al usuario | Latency, Traffic, Errors, Saturation | Salud del servicio de extremo a extremo | Amplio; necesita RED/USE para operativizarse |

Regla general del arquitecto: **RED para el camino del request (derivado de traces/spans), USE para los recursos que esos requests consumen (métricas de host/infra), Golden Signals como la capa de SLO por encima.** OpenTelemetry te permite generar métricas RED *a partir de traces* mediante el connector `spanmetrics` del Collector — una fuente de instrumentación, dos superficies de análisis (ver §4).

### 2.2 SLI → SLO → SLA → Error Budget — la matemática de los resultados

Este es el núcleo cuantitativo de los "resultados". Definiciones que el examen exige mantener bien diferenciadas:

- **SLI (Indicador)** — un ratio *medido* de eventos buenos sobre eventos válidos. Adimensional, en `[0,1]`.
  `SLI = good_events / valid_events`
- **SLO (Objetivo)** — un *objetivo* interno para el SLI sobre una ventana móvil. Ej. `SLI ≥ 0.999 over 28d`.
- **SLA (Acuerdo)** — un *contrato externo* con consecuencias financieras/legales; siempre más laxo que el SLO (el SLO es la línea de aviso temprano dentro del SLA).
- **Error Budget** — la falta de fiabilidad *permitida*: `1 − SLO`. Para `99.9%`, el budget es `0.1%` de los eventos válidos.

El **error budget sobre una ventana de 28 días** para un SLO de disponibilidad del 99,9%:

```
budget_fraction  = 1 − 0.999            = 0.001
window           = 28d = 40320 minutes
budget (time)    = 40320 × 0.001        = 40.32 minutes of "down" per 28 days
```

El **burn rate** normaliza la velocidad de consumo: un burn rate de `1` agota el budget justo al final de la ventana; `14.4` lo agota en `28d / 14.4 ≈ 2 days`; sobre una ventana de 1 hora, un burn rate de 14.4 significa que gastarías el `2%` de un budget de 30 días en esa hora. La alerta por burn rate (§4.3) es el reemplazo moderno de la alerta por umbral estático y es el mecanismo de "resultado" más examinable de todos.

---

## 3. Correlación entre señales — el mecanismo que hace posible el análisis

Un resultado solo es alcanzable si podés *pivotar* entre señales en mitad de la investigación. OpenTelemetry provee tres mecanismos de correlación, en precisión creciente:

| Mecanismo | Cómo ocurre el join | Precisión | Costo | Habilita |
|---|---|---|---|---|
| **Tiempo + atributos de recurso** | Mismo `service.name` / `k8s.pod.name` en el mismo bucket temporal | Gruesa (estadística) | gratis | "estos logs y esta métrica son del mismo pod" |
| **Contexto de trace en los logs** | El registro de log lleva `trace_id` + `span_id` (correlación de logs de OTel) | Exacta (por request) | un campo por log | "mostrame cada línea de log de *este* request fallido" |
| **Exemplars** | El bucket del histogram lleva un `trace_id` de muestra de un request que cayó en él | Exacta (métrica→trace) | ínfimo (con sampling) | "clic en el pico de latencia p99 → saltar a un trace lento" |

### 3.1 Exemplars — métricas que enlazan de vuelta a los traces

Los exemplars son la característica estrella de los "resultados de análisis" y muy evaluada. Un exemplar es una medición representativa adjunta a un data point de una métrica que lleva el `trace_id`/`span_id` del request que lo produjo. Cuando una observación de histogram se registra *dentro del contexto de un span con sampling*, el SDK de OTel (o el connector `spanmetrics` del Collector) adjunta el contexto de trace como un exemplar.

Consecuencia para el análisis: un panel de Grafana que muestra la `duration` p99 dibuja puntos de exemplar en el gráfico; hacer clic en uno enlaza directamente al trace exacto en Tempo/Jaeger. Ese es el salto de **detección → RCA** colapsado en un solo clic. Requisitos:
- La métrica debe ser un histogram (los exemplars se adjuntan a los buckets).
- La exposición debe ser **OpenMetrics** (el formato de texto de Prometheus no transporta exemplars) — `enable_open_metrics: true` en el exporter `prometheus` del Collector, y el scraper debe enviar `Accept: application/openmetrics-text`.

---

## 4. Infraestructura de producción — telemetría diseñada para resultados

Lo que sigue es un pipeline completo y desplegable que convierte traces OTLP crudos en **métricas RED listas para el análisis con exemplars**, y luego calcula SLIs y alertas por burn rate. No se omite nada.

### 4.1 OpenTelemetry Collector — generar métricas RED + exemplars a partir de traces

`otelcol-config.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Bound cardinality BEFORE it reaches the metrics pipeline: keep only the
  # dimensions that analysis actually pivots on; drop the unbounded ones.
  transform/scrub:
    metric_statements:
      - context: datapoint
        statements:
          - delete_key(attributes, "user.id")
          - delete_key(attributes, "http.url")   # unbounded (query strings)
  batch:
    timeout: 10s
    send_batch_size: 1024

connectors:
  # The spanmetrics connector consumes the TRACES pipeline and emits METRICS.
  # It is the canonical "derive RED from traces" component.
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
    # Only these span attributes become metric labels. Cardinality is a
    # first-class analysis budget: every dimension multiplies series count.
    dimensions:
      - name: http.request.method
      - name: http.route
      - name: http.response.status_code
    exemplars:
      enabled: true               # attach trace_id/span_id to histogram buckets
    exclude_dimensions: []
    metrics_flush_interval: 15s
    metrics_expiration: 5m        # evict stale series to bound memory
    namespace: traces.span.metrics
    aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE

exporters:
  # Traces to a trace backend (Tempo/Jaeger) for RCA.
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true
  # Metrics to a Prometheus-scrapable endpoint, in OpenMetrics so exemplars survive.
  prometheus:
    endpoint: 0.0.0.0:8889
    enable_open_metrics: true      # MANDATORY for exemplar exposition
    resource_to_telemetry_conversion:
      enabled: true                # copy resource attrs (service.name) to labels
    metric_expiration: 5m

service:
  pipelines:
    # Pipeline A: traces flow to the trace backend AND fan into spanmetrics.
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo, spanmetrics]
    # Pipeline B: spanmetrics acts as a RECEIVER here, feeding derived metrics out.
    metrics:
      receivers: [spanmetrics]
      processors: [transform/scrub, batch]
      exporters: [prometheus]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 0.0.0.0:8888        # the Collector's OWN metrics (for self-analysis)
```

El connector emite dos métricas bajo el namespace `traces.span.metrics`, expuestas por el exporter de Prometheus como:

- `traces_span_metrics_calls_total` — counter (**rate** de requests y **errors**)
- `traces_span_metrics_duration_milliseconds_bucket` — histogram (**duration**, lleva exemplars)

con las labels `service_name`, `span_name`, `span_kind`, `status_code`, y las dimensiones `http_*` incluidas en la whitelist.

### 4.2 Scrape de Prometheus + recording rules de SLI

`prometheus.yml` (bloque de scrape — el header `Accept` de OpenMetrics es implícito cuando el exporter lo anuncia, pero el almacenamiento de exemplars debe estar habilitado):

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# Exemplar storage is behind a feature flag on older releases; enable it.
# CLI: prometheus --enable-feature=exemplar-storage
storage:
  exemplars:
    max_exemplars: 100000

scrape_configs:
  - job_name: otel-collector-spanmetrics
    static_configs:
      - targets: ['otel-collector:8889']
  - job_name: otel-collector-internal
    static_configs:
      - targets: ['otel-collector:8888']

rule_files:
  - /etc/prometheus/rules/*.yml
```

`rules/sli-checkout.yml` — las recording rules precalculan el SLI para que los dashboards y las alertas lean una serie barata y estable en lugar de rederivarla. Los valores de la label `status_code` que emite el connector son `STATUS_CODE_UNSET | STATUS_CODE_OK | STATUS_CODE_ERROR`.

```yaml
groups:
  - name: sli:checkout:recording
    interval: 30s
    rules:
      # Total valid request rate for the checkout service (the SLI denominator).
      - record: sli:checkout:requests:rate5m
        expr: |
          sum(rate(traces_span_metrics_calls_total{
            service_name="checkout", span_kind="SPAN_KIND_SERVER"
          }[5m]))

      # Bad request rate (the SLI numerator's complement).
      - record: sli:checkout:errors:rate5m
        expr: |
          sum(rate(traces_span_metrics_calls_total{
            service_name="checkout", span_kind="SPAN_KIND_SERVER",
            status_code="STATUS_CODE_ERROR"
          }[5m]))

      # Availability SLI = 1 − (errors / total), guarded against 0/0.
      - record: sli:checkout:availability:ratio5m
        expr: |
          1 - (
            sli:checkout:errors:rate5m
            /
            clamp_min(sli:checkout:requests:rate5m, 1e-9)
          )

      # Latency SLI: fraction of requests served under the 500ms threshold.
      - record: sli:checkout:latency:ratio5m
        expr: |
          sum(rate(traces_span_metrics_duration_milliseconds_bucket{
            service_name="checkout", span_kind="SPAN_KIND_SERVER", le="500"
          }[5m]))
          /
          clamp_min(
            sum(rate(traces_span_metrics_duration_milliseconds_count{
              service_name="checkout", span_kind="SPAN_KIND_SERVER"
            }[5m])), 1e-9)
```

### 4.3 Alertas de SLO multi-ventana y multi-burn-rate (el resultado de "detección")

Los umbrales estáticos producen o bien detección lenta (ventana demasiado larga) o bien pages falsos (ventana demasiado corta). El patrón del Google SRE Workbook usa **dos ventanas por severidad**: una ventana larga que mide el consumo sostenido y una ventana corta que confirma que el problema *sigue ocurriendo* (matando la alerta rápidamente al recuperarse). Objetivos para un **SLO del 99,9%** (budget `0.001`):

| Severidad | Ventana larga | Ventana corta | Burn rate | Budget gastado si se sostiene | Significado |
|---|---|---|---|---|---|
| **Page** | 1h | 5m | 14.4 | ~2% en 1h | catastrófico; despertar a alguien |
| **Page** | 6h | 30m | 6 | ~5% en 6h | consumo rápido; despertar a alguien |
| **Ticket** | 24h | 2h | 3 | ~10% en 1d | notable; abrir un ticket |
| **Ticket** | 3d | 6h | 1 | ~10% en 3d | fuga lenta; investigar |

`rules/slo-checkout-alerts.yml`:

```yaml
groups:
  - name: slo:checkout:burnrate
    rules:
      # Error-budget burn = observed error ratio / (1 − SLO).
      # SLO = 0.999  →  budget = 0.001.
      - record: slo:checkout:error_budget_burn:5m
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[5m]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[5m])), 1e-9)
          ) / 0.001
      - record: slo:checkout:error_budget_burn:1h
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[1h]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[1h])), 1e-9)
          ) / 0.001
      - record: slo:checkout:error_budget_burn:30m
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[30m]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[30m])), 1e-9)
          ) / 0.001
      - record: slo:checkout:error_budget_burn:6h
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[6h]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[6h])), 1e-9)
          ) / 0.001

      # PAGE: fast burn (14.4×) confirmed on both 1h and 5m windows.
      - alert: CheckoutErrorBudgetFastBurn
        expr: |
          slo:checkout:error_budget_burn:1h > 14.4
          and
          slo:checkout:error_budget_burn:5m > 14.4
        for: 2m
        labels:
          severity: page
          slo: checkout-availability
        annotations:
          summary: "Checkout burning error budget at >14.4x (1h & 5m)"
          description: "At this rate the 28d budget is exhausted in ~2 days. Pivot: exemplars on duration histogram → Tempo."

      # PAGE: 6× burn confirmed on 6h and 30m windows.
      - alert: CheckoutErrorBudgetSlowerBurn
        expr: |
          slo:checkout:error_budget_burn:6h > 6
          and
          slo:checkout:error_budget_burn:30m > 6
        for: 5m
        labels:
          severity: page
          slo: checkout-availability
        annotations:
          summary: "Checkout burning error budget at >6x (6h & 30m)"
```

### 4.4 Despliegue del Collector en Kubernetes (gateway de la capa de análisis)

`otel-collector-gateway.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  otelcol-config.yaml: |
    # (contents of §4.1)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector-gateway
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
    app.kubernetes.io/component: gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-collector
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8889"
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.116.0
          args: ["--config=/conf/otelcol-config.yaml"]
          ports:
            - { name: otlp-grpc,   containerPort: 4317 }
            - { name: otlp-http,   containerPort: 4318 }
            - { name: prom-export, containerPort: 8889 }
            - { name: self-metric, containerPort: 8888 }
          resources:
            requests: { cpu: "500m", memory: "512Mi" }
            limits:   { cpu: "2",    memory: "2Gi" }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: config, mountPath: /conf }
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector:
    app.kubernetes.io/name: otel-collector
  ports:
    - { name: otlp-grpc,   port: 4317, targetPort: 4317 }
    - { name: otlp-http,   port: 4318, targetPort: 4318 }
    - { name: prom-export, port: 8889, targetPort: 8889 }
```

> **Nota arquitectónica:** `spanmetrics` debe correr en un **gateway** (una única instancia lógica por stream), no en un agent por nodo, porque la agregación RED a través de todos los pods requiere que todos los spans de un servicio converjan en un solo connector; de lo contrario obtenés N histogramas parciales que no pueden sumarse correctamente (temporalidad acumulativa por instancia). Balanceá la carga *por trace ID* aguas arriba (exporter `loadbalancing`) para que todos los spans de un trace — y por lo tanto una agregación consistente — lleguen a la misma réplica del gateway.

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Validar la configuración del Collector antes del despliegue

```console
$ otelcol-contrib validate --config=otelcol-config.yaml
2026-08-10T14:02:11.334Z  info  service@v0.116.0/service.go:135  Setting up own telemetry...
2026-08-10T14:02:11.335Z  info  spanmetricsconnector@v0.116.0/connector.go:180  Building spanmetrics connector
Configuration is valid.
$ echo $?
0
```

### 5.2 Confirmar que las métricas derivadas y las labels existen

```console
$ curl -s http://localhost:8889/metrics | grep traces_span_metrics_calls_total | head -3
traces_span_metrics_calls_total{service_name="checkout",span_kind="SPAN_KIND_SERVER",span_name="POST /cart/checkout",status_code="STATUS_CODE_OK",http_request_method="POST",http_route="/cart/checkout"} 18423
traces_span_metrics_calls_total{service_name="checkout",span_kind="SPAN_KIND_SERVER",span_name="POST /cart/checkout",status_code="STATUS_CODE_ERROR",http_request_method="POST",http_route="/cart/checkout"} 37
traces_span_metrics_calls_total{service_name="payment",span_kind="SPAN_KIND_CLIENT",span_name="charge",status_code="STATUS_CODE_OK"} 18386
```

### 5.3 Verificar que los exemplars sobrevivieron al pipeline (el chequeo de resultado crítico)

El formato de texto plano de Prometheus descarta los exemplars de forma silenciosa. DEBÉS solicitar OpenMetrics:

```console
$ curl -s -H 'Accept: application/openmetrics-text' \
    http://localhost:8889/metrics \
  | grep 'duration_milliseconds_bucket' | grep '#' | head -1
traces_span_metrics_duration_milliseconds_bucket{service_name="checkout",le="500.0"} 18201 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 431.7 1754835731.442
```

El `# {trace_id=...} 431.7 <ts>` del final **es** el exemplar. Si está ausente, los exemplars están rotos — ver 5.6.

### 5.4 Comprobar que la consulta del SLI devuelve datos

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=sli:checkout:availability:ratio5m' | jq '.data.result'
[
  {
    "metric": {},
    "value": [ 1754835800.221, "0.998" ]
  }
]
```

Disponibilidad de `0.998` contra un SLO de `0.999` → el budget se está consumiendo. Confirmá que la alerta por burn rate se dispararía:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=slo:checkout:error_budget_burn:5m' | jq -r '.data.result[0].value[1]'
19.6
```

`19.6 > 14.4` en la ventana de 5m; si la ventana de 1h coincide durante 2 minutos, `CheckoutErrorBudgetFastBurn` dispara un page.

### 5.5 Confirmar que los exemplars son consultables desde Prometheus (habilita los pivotes en Grafana)

```console
$ curl -s 'http://localhost:9090/api/v1/query_exemplars' \
    --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket{service_name="checkout"}' \
    --data-urlencode "start=$(date -d '-1 hour' +%s)" \
    --data-urlencode "end=$(date +%s)" | jq '.data[0].exemplars[0]'
{
  "labels": { "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736", "span_id": "00f067aa0ba902b7" },
  "value": "431.7",
  "timestamp": 1754835731.442
}
```

### 5.6 Matriz de diagnóstico — síntoma → causa raíz → solución

| Síntoma durante el análisis | Causa raíz probable | Verificación | Solución |
|---|---|---|---|
| La consulta del SLI devuelve `[]` vacío | Desajuste en el valor de la label `status_code` (se usó `"ERROR"` en vez de `"STATUS_CODE_ERROR"`) | `curl .../metrics \| grep status_code` y leer los valores reales | Coincidir exactamente con las cadenas del enum del connector |
| Faltan exemplars en Grafana | Métrica expuesta como texto de Prometheus, no OpenMetrics | 5.3 no muestra ningún `#{trace_id}` | Poner `enable_open_metrics: true`; iniciar Prometheus con `--enable-feature=exemplar-storage` |
| Exemplars presentes pero siempre rápidos/exitosos | El sampling basado en cabecera (head-based) descartó los traces lentos/con errores antes de que el connector los viera | Comparar la tasa de errores en las métricas vs. los traces en Tempo | Pasar a **tail-based sampling**; muestrear por `status=ERROR` y latencia alta |
| OOM de Prometheus tras agregar una dimensión | Label de cardinalidad no acotada (`user.id`, `http.url` con query string) | `count({__name__=~"traces_span_metrics.*"})` explota | Eliminarla en `transform` (§4.1) u omitirla de `dimensions` |
| La métrica RED suma mal entre réplicas | `spanmetrics` corriendo por agent; se suman histogramas acumulativos parciales | El conteo de series difiere por pod de gateway | Correr el connector en un gateway; balancear la carga por `trace_id` |
| La alerta por burn rate oscila (flapping) | Una sola ventana (larga); sin confirmación de ventana corta | La alerta se limpia lentamente tras la recuperación | Agregar el par multi-ventana (§4.3) |
| La consulta de latencia p99 es incorrecta tras un reinicio | No se maneja el reinicio del counter acumulativo | `_bucket` crudo sin `rate()` | Envolver siempre counters/buckets en `rate()`/`histogram_quantile(...rate())` |
| Los logs no pueden unirse al trace que falla | A los registros de log les falta `trace_id`/`span_id` | Inspeccionar los atributos de una línea de log | Habilitar la correlación de logs de OTel / inyección de contexto de trace en los logs |

### 5.7 Verificar el presupuesto de cardinalidad antes de que se convierta en un incidente

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count({__name__=~"traces_span_metrics_.*"})' \
  | jq -r '.data.result[0].value[1]'
2841
$ # Find the offending label if this number is unexpectedly large:
$ curl -s 'http://localhost:9090/api/v1/status/tsdb' \
  | jq '.data.seriesCountByLabelName[:5]'
[
  { "name": "http_route",  "value": 42 },
  { "name": "span_name",   "value": 40 },
  { "name": "status_code", "value": 3  },
  { "name": "__name__",    "value": 2  },
  { "name": "service_name","value": 11 }
]
```

Una superficie de análisis sana muestra valores de label *acotados*. Un `value` en las decenas de miles para cualquier nombre de label individual es la huella de una dimensión no acotada que degradará cada consulta en la que participe.

---

## 6. Referencias

- OTCA Curriculum (dominios y competencias oficiales) — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- OpenTelemetry — Observability Primer (señales, correlación, análisis) — https://opentelemetry.io/docs/concepts/observability-primer/
- OpenTelemetry — Exemplars (especificación y comportamiento del SDK) — https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars
- OpenTelemetry Collector — connector `spanmetrics` (RED a partir de traces) — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector
- OpenTelemetry Collector — exporter `prometheus` (OpenMetrics / exemplars) — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/prometheusexporter
- OpenTelemetry Collector — patrones de despliegue (agent vs. gateway) — https://opentelemetry.io/docs/collector/deployment/
- OpenTelemetry — Sampling (head vs. tail; efecto en el análisis) — https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry — Correlación de logs (`trace_id`/`span_id` en los registros de log) — https://opentelemetry.io/docs/specs/otel/logs/data-model/
- Google SRE Book — Service Level Objectives (SLI/SLO/SLA, error budgets) — https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook — Alerting on SLOs (multi-ventana, multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/
- Prometheus — Querying exemplars (API `query_exemplars`) — https://prometheus.io/docs/prometheus/latest/querying/api/#querying-exemplars
- Prometheus — Recording & alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- The RED Method (Tom Wilkie) — https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- The USE Method (Brendan Gregg) — https://www.brendangregg.com/usemethod.html