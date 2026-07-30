# 2.1 Implementing Monitoring, Alerting, Logging, and Tracing Solutions

## Motivación y Pilares de la Observabilidad en Producción

La observabilidad en sistemas distribuidos cloud native no es opcional; es una capacidad fundamental de la ingeniería de plataformas para garantizar disponibilidad, medir **Service Level Objectives (SLOs)** y responder con rapidez ante incidentes. A diferencia del monitoreo tradicional (basado en polling de métricas aisladas), la observabilidad moderna se construye sobre cuatro pilares de telemetría interconectados bajo estándares abiertos (**OpenTelemetry**):

1. **Metrics (Métricas)**: Datos numéricos agregados en series temporales para evaluar la salud general de la infraestructura y de las aplicaciones.
2. **Logs (Registros)**: Eventos de texto estructurado emitidos por las aplicaciones para diagnosticar causas raíz.
3. **Traces (Trazas Distribuidas)**: Seguimiento del ciclo de vida de una petición HTTP/gRPC a través de múltiples microservicios.
4. **Events (Eventos de Kubernetes)**: Cambios de estado en los recursos del clúster emitidos por el `kube-apiserver`.

---

## 1. Métricas y Alertas con Prometheus Operator y ServiceMonitors

### 1.1 El Patrón ServiceMonitor

Prometheus Operator utiliza la Custom Resource Definition (CRD) `ServiceMonitor` para que las aplicaciones expongan sus métricas de forma declarativa sin modificar la configuración global del servidor de Prometheus.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: platform-api-servicemonitor
  namespace: platform-monitoring
  labels:
    release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: platform-api
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
    metricRelabelings:
    - action: keep
      sourceLabels: [__name__]
      regex: "(http_requests_total|http_request_duration_seconds_bucket|process_cpu_seconds_total)"
```

### 1.2 Reglas de Alerta Avanzadas con PrometheusRule

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-api-alertmanager-rules
  namespace: platform-monitoring
spec:
  groups:
  - name: platform-api-availability.rules
    rules:
    - alert: HighErrorRateHTTP5xx
      expr: |
        sum(rate(http_requests_total{status=~"5.."}[5m])) 
        / 
        sum(rate(http_requests_total[5m])) * 100 > 5
      for: 2m
      labels:
        severity: critical
        team: platform-sre
      annotations:
        summary: "La tasa de errores HTTP 5xx supera el 5% en la API de Plataforma"
        description: "En los últimos 5 minutos, la tasa de errores HTTP 5xx es de {{ $value | printf \"%.2f\" }}%."
```

---

## 2. Centralización de Logs con Grafana Loki y Vector / Fluentbit

Para evitar la saturación del disco de los nodos worker, los logs emitidos a `stdout`/`stderr` son recolectados por agentes livianos como **Vector** o **Fluentbit** y transferidos hacia **Grafana Loki**.

Configuración declarativa de Vector para añadir metadatos de Kubernetes a cada registro de log:

```yaml
apiVersion: vector.dev/v1alpha1
kind: Vector
metadata:
  name: vector-agent
  namespace: platform-logging
spec:
  role: Agent
  agent:
    sources:
      kubernetes_logs:
        type: kubernetes_logs
    transforms:
      parse_json:
        type: remap
        inputs: ["kubernetes_logs"]
        source: |
          .parsed = parse_json(.message) or {}
    sinks:
      loki:
        type: loki
        inputs: ["parse_json"]
        endpoint: "http://loki-gateway.platform-logging:80"
        encoding:
          codec: json
```

---

## 3. Trazado Distribuido con OpenTelemetry Collector y Grafana Tempo

El **OpenTelemetry Collector** actúa como el punto central de procesamiento de trazas (OTLP), añadiendo metadatos de la infraestructura (`k8sattributes`) antes de reenviar los Spans a herramientas como **Grafana Tempo** o **Jaeger**.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector-traces
  namespace: platform-monitoring
spec:
  config: |
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
        limit_percentage: 75
        spike_limit_percentage: 15
      batch:
        send_batch_size: 10000
        timeout: 10s
      k8sattributes:
        auth_type: "serviceAccount"
        passthrough: false
        extract:
          metadata:
            - k8s.pod.name
            - k8s.namespace.name
            - k8s.node.name
    exporters:
      otlp/tempo:
        endpoint: "tempo-distributor.platform-monitoring:4317"
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp/tempo]
```

---

## Verificación y Diagnóstico del Stack de Observabilidad

### Comandos de Diagnóstico en Tiempo Real

```bash
# Verificar la conectividad del ServiceMonitor en Prometheus
$ kubectl exec -n platform-monitoring deploy/prometheus-k8s -c prometheus -- curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="platform-api-servicemonitor")'
{
  "discoveredLabels": {
    "__address__": "10.244.2.45:8080",
    "app": "platform-api"
  },
  "health": "up",
  "lastScrape": "2026-07-30T03:03:00Z"
}

# Consultar logs centralizados con LogCLI de Loki
$ logcli query '{namespace="platform-prod", app="platform-api"} |= "error"' --limit=10
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenTelemetry Collector Architecture — https://opentelemetry.io/docs/collector/
- Prometheus Operator Documentation — https://prometheus-operator.dev/docs/operator/design/
- Grafana Loki Documentation — https://grafana.com/docs/loki/latest/