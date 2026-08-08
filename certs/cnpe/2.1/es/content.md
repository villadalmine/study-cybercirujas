# Tema 2.1 — Implementación de soluciones de Monitoring, Alerting, Logging y Tracing

> **Certificación:** Cloud Native Platform Engineer (CNPE) · **Dominio 2 (Observability & Reliability)** · **Peso:** 6.66 %
> **Perfil:** Platform Architect / SRE Senior · **Nivel:** producción

---

## 1. Motivación y problema arquitectónico de producción

Cuando una plataforma pasa de un puñado de servicios a cientos de `Deployments` repartidos en varios clusters, la pregunta operativa deja de ser *"¿está caído?"* y pasa a ser *"¿por qué esta petición concreta tardó 4 s, en qué salto se degradó, y a cuántos usuarios afectó?"*. Esa pregunta no se responde con un healthcheck: se responde con **observabilidad**, la capacidad de inferir el estado interno de un sistema a partir de sus salidas externas sin desplegar código nuevo.

La observabilidad cloud-native se apoya en **tres señales (pillars)** más una cuarta transversal:

| Señal | Pregunta que responde | Cardinalidad | Modelo de retención típico |
|---|---|---|---|
| **Metrics** | ¿Qué está pasando y cuánto? (agregado, barato) | Baja/controlada | Larga (meses/años con downsampling) |
| **Logs** | ¿Qué pasó exactamente en este evento? | Alta | Media (días/semanas) |
| **Traces** | ¿Dónde, en qué salto y por qué se degradó una petición? | Muy alta (por span) | Corta (horas/días) + muestreo |
| **Events / Profiles** (transversal) | ¿Qué cambió (deploy, scaling, OOM) y qué recurso lo causó? | Variable | Corta |

### El problema arquitectónico central

Las tres señales, tratadas por separado, producen **tres silos** que el SRE tiene que correlacionar *a mano* a las 3 de la mañana. El diseño de producción moderno persigue lo contrario: **una arquitectura correlacionada** donde una métrica te lleva por *exemplar* a una traza, la traza expone un `trace_id` que aparece en los logs, y el log te devuelve el `pod`, `node` y `namespace` exactos.

Tres tensiones estructurales gobiernan cualquier diseño:

1. **Cardinalidad vs. utilidad.** Cada combinación única de labels en Prometheus es una serie temporal independiente que consume RAM en el TSDB. Meter `user_id`, `request_id` o `pod_ip` en una métrica es la causa #1 de OOM del Prometheus. La regla dura: *dimensiones de alta cardinalidad van a logs/traces, no a metrics*.
2. **Pull vs. push.** Prometheus **hace pull** por diseño (descubre targets, los scrapea, y "no scrapear" es en sí una señal de caída). Los pipelines de logs y traces **hacen push** (OTLP, Fluent Bit forward). Mezclar ambos modelos sin entender la semántica de fallo lleva a alertas ciegas.
3. **Coste de retención vs. capacidad de diagnóstico.** Guardar el 100 % de las trazas de un servicio de alto tráfico es económicamente inviable; guardar el 0.1 % te hace perder justo la traza del incidente. El **sampling** (head vs. tail) es una decisión de arquitectura, no un flag.

### Anti-patrones que este tema busca erradicar

- **`kubectl logs` como estrategia de logging.** El log vive en el `emptyDir`/stdout del pod; cuando el pod se reprograma o hace `CrashLoopBackOff`, el log del incidente se pierde. Producción exige agregación fuera del ciclo de vida del pod.
- **Alertar sobre síntomas de caja (CPU > 80 %) en vez de síntomas de usuario.** La CPU alta no despierta a nadie; el error budget quemándose sí. Alertar sobre **SLOs**, no sobre recursos.
- **Un Prometheus monolítico como SPOT (single point of truth y de fallo).** Sin HA ni almacenamiento remoto, el reinicio del pod = ceguera durante el incidente.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Metrics — modelo de recolección

| Criterio | Prometheus (pull) | Push-based (Graphite/StatsD, OTLP push) |
|---|---|---|
| Detección de "target caído" | Nativa (`up == 0`) | Requiere heartbeat aparte |
| Jobs efímeros / batch | Necesita **Pushgateway** | Natural |
| Service discovery | Nativo (K8s SD, Consul, EC2) | Manual o via collector |
| Control de sobrecarga | El servidor decide el ritmo | El cliente puede inundar |
| Cardinalidad descontrolada | Riesgo alto en el TSDB local | Riesgo desplazado al backend |

### 2.2 Almacenamiento de larga duración / HA para Prometheus

| Solución | Modelo | Fortaleza | Trade-off |
|---|---|---|---|
| **Thanos** | Sidecar + object storage + Query fanout | Retención infinita barata (S3), global query, dedup de HA pairs | Latencia de query sobre bloques históricos; más componentes |
| **Cortex / Grafana Mimir** | Ingesters + object storage, multi-tenant | Escala horizontal masiva, tenancy fuerte | Operacionalmente pesado; consistencia eventual |
| **VictoriaMetrics** | TSDB reescrito, remote_write | Menor uso de RAM/CPU, ingest simple | Ecosistema menos estándar que Prometheus puro |
| **Prometheus local + HA pair** | 2 réplicas idénticas, sin dedup fuera de Grafana/Thanos | Simple | Sin retención larga; sin vista global |

### 2.3 Logging — backends

| Criterio | Loki | Elasticsearch / OpenSearch | Vector→object storage |
|---|---|---|---|
| Indexación | Solo **labels** (metadatos); el cuerpo no se indexa | Full-text de todo el documento | Configurable |
| Coste de almacenamiento | Muy bajo (object storage + chunks) | Alto (índices invertidos en disco) | Bajo |
| Consultas ad-hoc de texto | LogQL con grep sobre chunks (más lento en full-scan) | Muy rápido (índice invertido) | Depende |
| Correlación con Prometheus | Nativa (mismos labels, mismo Grafana) | Requiere pegamento | Requiere pegamento |
| Riesgo | Cardinalidad de **labels** (mismo problema que Prometheus) | Coste y operación del cluster ES | Menos features de query |

### 2.4 Agentes de recolección de logs

| Agente | Lenguaje / footprint | Punto fuerte | Cuándo elegirlo |
|---|---|---|---|
| **Fluent Bit** | C, ~límite RAM configurable, muy liviano | DaemonSet en cada nodo, alto rendimiento | Recolección en el edge del cluster |
| **Fluentd** | Ruby/C, más pesado, +1000 plugins | Agregador/router central complejo | Transformaciones y ruteo ricos |
| **Vector** | Rust, VRL como lenguaje de transformación | Rendimiento + observabilidad del propio pipeline | Pipelines complejos con backpressure |
| **OTel Collector (filelog)** | Go, unifica las 3 señales | Un solo agente para logs+metrics+traces | Estandarización sobre OTLP |

### 2.5 Tracing — sampling y backends

| Estrategia de sampling | Dónde decide | Ventaja | Coste |
|---|---|---|---|
| **Head-based** (probabilístico) | En el SDK, al inicio del trace | Simple, sin estado, barato | Decide *antes* de saber si el trace es interesante → pierde errores raros |
| **Tail-based** | En el Collector, tras ver el trace completo | Retiene errores y latencias altas selectivamente | Requiere bufferizar spans en memoria; con estado; más CPU/RAM |

| Backend de traces | Índice | Almacenamiento | Nota |
|---|---|---|---|
| **Grafana Tempo** | Sin índice (busca por `trace_id`; búsqueda via TraceQL/metrics-generator) | Object storage barato | Pareja natural de Loki/Prometheus |
| **Jaeger** | Con índice (Elasticsearch/Cassandra) | Depende del backend | Búsqueda por servicio/tags madura |

**Regla de arquitectura:** el **OpenTelemetry Collector** es la pieza que desacopla instrumentación de backend. Instrumentás una vez en OTLP; cambiás de Jaeger a Tempo tocando solo el `exporter` del Collector, sin recompilar la aplicación.

---

## 3. Manifiestos completos (producción, sin recortar)

Se asume un stack basado en **Prometheus Operator / kube-prometheus-stack**, **Loki**, **Fluent Bit** y **OpenTelemetry Collector + Tempo**. Todos los YAML son sintácticamente válidos y aplicables.

### 3.1 Prometheus Operator — descubrimiento de scrape con `ServiceMonitor`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payments-api
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # el Prometheus selecciona ServiceMonitors por este label
spec:
  jobLabel: app.kubernetes.io/name
  namespaceSelector:
    matchNames:
      - payments
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  endpoints:
    - port: http-metrics            # nombre del port del Service, NO el número
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      scheme: http
      honorLabels: false
      relabelings:
        # Propaga el nombre del nodo como label para facilitar correlación
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
      metricRelabelings:
        # Defensa anti-cardinalidad: descarta una métrica ruidosa conocida
        - sourceLabels: [__name__]
          regex: 'go_gc_duration_seconds.*'
          action: drop
```

### 3.2 `PrometheusRule` — recording rules + alerta SLO multi-burn-rate

Este es el patrón de alerting de producción recomendado por el SRE Workbook de Google: **multi-window, multi-burn-rate**. Alerta rápido cuando el error budget se quema rápido, y lento (pero seguro) cuando se quema despacio, minimizando falsos positivos.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payments-api-slo
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: payments-api.slo.recording
      interval: 30s
      rules:
        # Ratio de peticiones "buenas" (no-5xx) sobre el total, en varias ventanas.
        - record: job:http_request_error_rate:ratio5m
          expr: |
            sum(rate(http_requests_total{job="payments-api",code=~"5.."}[5m]))
              /
            sum(rate(http_requests_total{job="payments-api"}[5m]))
        - record: job:http_request_error_rate:ratio1h
          expr: |
            sum(rate(http_requests_total{job="payments-api",code=~"5.."}[1h]))
              /
            sum(rate(http_requests_total{job="payments-api"}[1h]))
        - record: job:http_request_error_rate:ratio6h
          expr: |
            sum(rate(http_requests_total{job="payments-api",code=~"5.."}[6h]))
              /
            sum(rate(http_requests_total{job="payments-api"}[6h]))

    - name: payments-api.slo.alerts
      rules:
        # SLO objetivo: 99.9% de éxito -> error budget = 0.1% = 0.001
        # Página RÁPIDA: quema 2% del budget mensual en 1h (burn rate 14.4x)
        - alert: PaymentsApiErrorBudgetBurnFast
          expr: |
            job:http_request_error_rate:ratio5m > (14.4 * 0.001)
            and
            job:http_request_error_rate:ratio1h > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            team: payments
            slo: availability
          annotations:
            summary: "Burn rate rápido del error budget en payments-api"
            description: >
              El error budget de disponibilidad se está quemando a 14.4x.
              Ratio 5m={{ $value | humanizePercentage }}. A este ritmo el
              budget mensual se agota en ~2 días.
            runbook_url: "https://runbooks.example.com/payments-api/error-budget-burn"

        # Página LENTA: burn rate 6x sostenido (6h/1h)
        - alert: PaymentsApiErrorBudgetBurnSlow
          expr: |
            job:http_request_error_rate:ratio6h > (6 * 0.001)
            and
            job:http_request_error_rate:ratio1h > (6 * 0.001)
          for: 15m
          labels:
            severity: warning
            team: payments
            slo: availability
          annotations:
            summary: "Burn rate lento sostenido en payments-api"
            runbook_url: "https://runbooks.example.com/payments-api/error-budget-burn"
```

### 3.3 Alertmanager — routing, grouping, inhibición y silenciamiento

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: payments-routing
  namespace: monitoring
  labels:
    alertmanagerConfig: main
spec:
  route:
    receiver: 'default-slack'
    groupBy: ['alertname', 'team', 'namespace']
    groupWait: 30s          # espera inicial para agrupar alertas correlacionadas
    groupInterval: 5m       # ritmo de reenvío de un grupo con novedades
    repeatInterval: 4h      # re-notifica si sigue firing
    routes:
      - matchers:
          - name: severity
            value: critical
        receiver: 'pagerduty-critical'
        continue: false     # no cae al receiver por defecto
      - matchers:
          - name: team
            value: payments
        receiver: 'payments-slack'
  inhibitRules:
    # Si el cluster/namespace está caído (critical), silencia los warnings ruidosos derivados
    - sourceMatch:
        - name: severity
          value: critical
      targetMatch:
        - name: severity
          value: warning
      equal: ['namespace', 'team']
  receivers:
    - name: 'default-slack'
      slackConfigs:
        - apiURL:
            name: alertmanager-slack
            key: url
          channel: '#alerts-default'
          sendResolved: true
    - name: 'payments-slack'
      slackConfigs:
        - apiURL:
            name: alertmanager-slack
            key: url
          channel: '#payments-alerts'
          sendResolved: true
    - name: 'pagerduty-critical'
      pagerdutyConfigs:
        - routingKey:
            name: alertmanager-pagerduty
            key: routingKey
          severity: 'critical'
```

### 3.4 Fluent Bit — DaemonSet de recolección hacia Loki

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Daemon        off
        Parsers_File  parsers.conf
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     2020
        storage.path  /var/log/flb-storage/
        storage.backlog.mem_limit 50M

    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/*.log
        multiline.parser  cri
        Mem_Buf_Limit     10MB
        Skip_Long_Lines   On
        Refresh_Interval  10
        DB                /var/log/flb-storage/tail.db   # cursor persistente: no re-lee tras reinicio

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [OUTPUT]
        Name                   loki
        Match                  kube.*
        Host                   loki-gateway.logging.svc
        Port                   80
        Labels                 job=fluentbit, cluster=prod
        Label_Keys            $kubernetes['namespace_name'],$kubernetes['pod_name'],$kubernetes['container_name']
        Auto_Kubernetes_Labels On
        Line_Format            json
  parsers.conf: |
    [PARSER]
        Name   json
        Format json
        Time_Key time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
  labels:
    app.kubernetes.io/name: fluent-bit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fluent-bit
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      tolerations:
        - operator: Exists          # corre también en control-plane y nodos con taints
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          ports:
            - containerPort: 2020
              name: http
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
          volumeMounts:
            - name: varlog
              mountPath: /var/log
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/
            - name: flb-storage
              mountPath: /var/log/flb-storage/
          livenessProbe:
            httpGet:
              path: /
              port: 2020
            initialDelaySeconds: 10
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
        - name: config
          configMap:
            name: fluent-bit-config
        - name: flb-storage
          hostPath:
            path: /var/log/flb-storage
```

### 3.5 OpenTelemetry Collector — pipeline con tail-sampling hacia Tempo

Se usa el **OpenTelemetry Operator** (`kind: OpenTelemetryCollector`), en modo `deployment` para tail-sampling (necesita ver el trace completo, por eso no va en DaemonSet).

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: gateway
  namespace: observability
spec:
  mode: deployment
  replicas: 2
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      # Tail-sampling: retiene el 100% de errores y latencias altas, muestrea el resto al 5%
      tail_sampling:
        decision_wait: 10s
        num_traces: 100000
        policies:
          - name: errors-policy
            type: status_code
            status_code: { status_codes: [ERROR] }
          - name: slow-traces-policy
            type: latency
            latency: { threshold_ms: 1000 }
          - name: probabilistic-policy
            type: probabilistic
            probabilistic: { sampling_percentage: 5 }
      batch:
        timeout: 5s
        send_batch_size: 1024
    exporters:
      otlp/tempo:
        endpoint: tempo-distributor.observability.svc:4317
        tls:
          insecure: true
      # Genera métricas RED (Rate, Errors, Duration) desde los spans
      prometheus:
        endpoint: 0.0.0.0:8889
    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [100ms, 250ms, 500ms, 1s, 2s, 5s]
        dimensions:
          - name: service.name
          - name: http.status_code
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, tail_sampling, batch]
          exporters: [otlp/tempo, spanmetrics]
        metrics:
          receivers: [spanmetrics]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
```

### 3.6 Instrumentación cero-código con el Operator (`Instrumentation`)

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: default-instrumentation
  namespace: payments
spec:
  exporter:
    endpoint: http://gateway-collector.observability.svc:4318
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"     # head-sampling 100%; el tail-sampling real ocurre en el Collector
  java:
    env:
      - name: OTEL_INSTRUMENTATION_LOGBACK_APPENDER_ENABLED
        value: "true"
```

El pod se auto-instrumenta con una annotation, sin tocar la imagen:

```yaml
# fragmento del pod template del Deployment payments-api
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-java: "true"
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Verificar que Prometheus descubrió los targets

```console
$ kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
$ curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health, lastError: .lastError}' | head -20
{
  "job": "payments-api",
  "health": "up",
  "lastError": ""
}
{
  "job": "payments-api",
  "health": "down",
  "lastError": "server returned HTTP status 403 Forbidden"
}
```

### 4.2 Consultar el estado del scrape con `up`

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=up{job="payments-api"}' | jq -r '.data.result[] | "\(.metric.instance) -> \(.value[1])"'
10.244.3.11:8080 -> 1
10.244.1.7:8080 -> 0
```

`up == 0` en `10.244.1.7` es una señal de primer orden: ese pod no responde el scrape.

### 4.3 Evaluar una regla de burn-rate manualmente

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=job:http_request_error_rate:ratio5m' | jq -r '.data.result[0].value[1]'
0.0234
```

`0.0234` (2.34 %) contra un umbral de `14.4 * 0.001 = 0.0144`: la alerta `PaymentsApiErrorBudgetBurnFast` está por encima del umbral → paginará tras el `for: 2m`.

### 4.4 Estado de las alertas en Alertmanager

```console
$ kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-alertmanager-0 -- \
    amtool alert query --alertmanager.url=http://localhost:9093 severity=critical
Alertname                          Starts At                Summary
PaymentsApiErrorBudgetBurnFast     2026-08-07 09:14:22 UTC  Burn rate rápido del error budget en payments-api

$ amtool silence add alertname="PaymentsApiErrorBudgetBurnFast" \
    --alertmanager.url=http://localhost:9093 \
    --duration="2h" --comment="Deploy fix en curso, ticket PAY-4821" --author="sre-oncall"
b3f1c0de-9a2b-4c77-8f1e-0a2b3c4d5e6f
```

### 4.5 Consultar logs correlacionados en Loki (LogQL)

```console
$ logcli query '{namespace="payments", container="payments-api"} |= "trace_id=4bf92f3577b34da6a3ce929d0e0e4736" | json | level="error"' \
    --addr=http://localhost:3100 --limit=5 --output=jsonl
{"ts":"2026-08-07T09:13:58Z","line":"level=error msg=\"payment gateway timeout\" trace_id=4bf92f3577b34da6a3ce929d0e0e4736 order_id=A-99123"}
```

Fijate en el flujo: la métrica disparó la alerta → una traza lenta expuso `trace_id=4bf9...` → ese mismo `trace_id` filtra el log exacto del error. Eso es la arquitectura correlacionada del punto 1 funcionando.

### 4.6 Recuperar una traza por ID en Tempo

```console
$ curl -s "http://tempo-query-frontend.observability.svc:3200/api/traces/4bf92f3577b34da6a3ce929d0e0e4736" \
    | jq '.batches[].scopeSpans[].spans[] | {name, durationMs: ((.endTimeUnixNano|tonumber) - (.startTimeUnixNano|tonumber))/1e6}'
{ "name": "POST /charge", "durationMs": 4021.5 }
{ "name": "SELECT accounts", "durationMs": 12.3 }
{ "name": "http POST stripe.com/v1/charges", "durationMs": 3980.1 }
```

El span `http POST stripe.com/...` acumula 3980 ms de los 4021 ms: la latencia es del proveedor externo, no de la base de datos ni del código. Diagnóstico en un vistazo.

### 4.7 Diagnóstico de cardinalidad (la causa #1 de OOM del Prometheus)

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:5]'
[
  { "name": "http_request_duration_seconds_bucket", "value": 481203 },
  { "name": "http_requests_total", "value": 92140 },
  { "name": "grpc_server_handled_total", "value": 33012 }
]

$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.labelValueCountByLabelName[] | select(.value > 10000)'
{ "name": "user_id", "value": 812004 }
```

`user_id` con 812 004 valores distintos es una **explosión de cardinalidad**: hay que dropearlo con `metricRelabelings` (como en el §3.1) o eliminarlo del instrumentado. Cada valor es una serie.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Checklist de verificación tras el despliegue

```console
# 1) El Operator reconcilió los CRDs
$ kubectl get servicemonitor,prometheusrule -n monitoring
NAME                                                    AGE
servicemonitor.monitoring.coreos.com/payments-api      3m
NAME                                                    AGE
prometheusrule.monitoring.coreos.com/payments-api-slo  3m

# 2) Prometheus cargó la config generada (recarga en caliente)
$ kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 -c prometheus | grep "Completed loading"
level=info msg="Completed loading of configuration file" filename=/etc/prometheus/config_out/prometheus.env.yaml

# 3) Las reglas están cargadas y evaluándose
$ curl -s http://localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[] | select(.type=="alerting") | "\(.name): \(.state)"'
PaymentsApiErrorBudgetBurnFast: inactive
PaymentsApiErrorBudgetBurnSlow: inactive
```

### 5.2 Matriz de diagnóstico de fallas

| Síntoma | Comando de diagnóstico | Causa raíz frecuente | Remediación |
|---|---|---|---|
| Target en estado `down`, `context deadline exceeded` | `curl -v` al `/metrics` desde un pod debug | `scrapeTimeout` < tiempo de render de métricas; endpoint lento | Subir `scrapeTimeout`, o aligerar el handler |
| Target `down`, HTTP 403 | Revisar `NetworkPolicy` y RBAC del ServiceMonitor | NetworkPolicy bloquea el namespace `monitoring` | Añadir ingress rule desde `monitoring` |
| `ServiceMonitor` ignorado (no aparece target) | Comparar `spec.selector` del Prometheus CR con los labels del ServiceMonitor | Falta el label `release:` que selecciona el Prometheus | Añadir el label esperado |
| Prometheus OOMKilled | `kubectl get pod -o jsonpath` + `/status/tsdb` | Explosión de cardinalidad (label de alta cardinalidad) | `metricRelabelings: drop`; subir `memory` limit temporalmente |
| Alerta firing pero sin notificación | `amtool config routes show`; logs de Alertmanager | Route mal emparejado o `inhibitRule` silenciándola | Testear ruteo con `amtool config routes test` |
| Logs no llegan a Loki | `curl :2020/api/v1/metrics` de Fluent Bit; buscar `retries`/`dropped` | Backpressure de Loki (429) o labels de alta cardinalidad rechazados | Reducir `Label_Keys`; escalar Loki ingesters |
| Trazas incompletas / spans huérfanos | Revisar `propagators` en `Instrumentation` | Falta propagación de contexto entre servicios (W3C `traceparent`) | Habilitar `tracecontext` + `baggage` en todos los servicios |
| Tempo no encuentra el trace | Verificar decisión de `tail_sampling` en el Collector | El trace fue descartado por el sampler | Confirmar policy de errores/latencia; head-sample al 100% |

### 5.3 Verificación del ruteo de alertas sin esperar un incidente real

```console
$ amtool config routes test --config.file=/etc/alertmanager/config/alertmanager.yaml \
    severity=critical team=payments
pagerduty-critical

$ amtool config routes test --config.file=/etc/alertmanager/config/alertmanager.yaml \
    severity=warning team=payments
payments-slack
```

Esto prueba, de forma determinista y offline, que una `critical` de `payments` va a PagerDuty y una `warning` a Slack — sin generar una alerta falsa en el sistema real.

### 5.4 Diagnóstico del pipeline de logs desde el propio Fluent Bit

```console
$ kubectl -n logging exec -it fluent-bit-abc12 -- curl -s http://localhost:2020/api/v1/metrics | \
    jq '.output["loki.0"]'
{
  "proc_records": 1841203,
  "proc_bytes": 984120233,
  "errors": 0,
  "retries": 14,
  "retries_failed": 0,
  "dropped_records": 0
}
```

`dropped_records: 0` y `retries_failed: 0` confirman que ningún log se perdió. Si `dropped_records` crece, hay backpressure aguas abajo (Loki saturado o rechazando por cardinalidad de labels).

### 5.5 Regla de oro del diagnóstico correlacionado

El orden de descenso durante un incidente es siempre el mismo, de barato a caro:

1. **Metric** (¿qué SLO se rompió y cuándo?) →
2. **Exemplar → Trace** (¿en qué salto de qué petición?) →
3. **Log filtrado por `trace_id`** (¿el mensaje de error exacto y el recurso K8s?).

Si tu arquitectura no permite saltar de (1) a (2) a (3) por un identificador compartido, tenés tres silos, no observabilidad.

---

## 6. Referencias

- CNCF — *CNPE Curriculum* (fuente oficial del temario): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Prometheus — *Documentation* (data model, scraping, PromQL): https://prometheus.io/docs/introduction/overview/
- Prometheus — *Alerting rules*: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus Operator — *ServiceMonitor / PrometheusRule API*: https://prometheus-operator.dev/docs/operator/api/
- Alertmanager — *Configuration (routing, inhibition, silences)*: https://prometheus.io/docs/alerting/latest/configuration/
- Google SRE — *The Site Reliability Workbook, cap. "Alerting on SLOs"* (multi-window multi-burn-rate): https://sre.google/workbook/alerting-on-slos/
- OpenTelemetry — *Collector / tail sampling processor*: https://opentelemetry.io/docs/collector/
- OpenTelemetry Operator — *Auto-instrumentation*: https://github.com/open-telemetry/opentelemetry-operator
- Grafana Loki — *LogQL & label best practices*: https://grafana.com/docs/loki/latest/
- Grafana Tempo — *Distributed tracing backend*: https://grafana.com/docs/tempo/latest/
- Fluent Bit — *Kubernetes filter & Loki output*: https://docs.fluentbit.io/manual/
- Thanos — *Long-term storage & global query*: https://thanos.io/tip/thanos/getting-started.md/
- Grafana Mimir — *Horizontally scalable Prometheus storage*: https://grafana.com/docs/mimir/latest/
- W3C — *Trace Context (propagación `traceparent`)*: https://www.w3.org/TR/trace-context/