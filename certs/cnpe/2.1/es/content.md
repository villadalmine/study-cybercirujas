# 2.1 Implementing Monitoring, Alerting, Logging, and Tracing Solutions

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

La observabilidad completa en plataformas cloud native requiere integrar las tres columnas fundamentales: **Métricas**, **Logs** y **Trazas distribuidas** (telemetría unificada bajo el estándar OpenTelemetry).

---

## 1. Métricas y Monitoreo con Prometheus & Grafana

### Arquitectura de Prometheus Operator & ServiceMonitor
Prometheus Operator utiliza la Custom Resource Definition (CRD) `ServiceMonitor` para descubrir y raspar métricas expuestas en `/metrics` por los Pods de la plataforma.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: platform-api-monitor
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
```

### Reglas de Alerta (Alertmanager)
Las alertas se definen de forma declarativa con `PrometheusRule`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-api-alerts
  namespace: platform-monitoring
spec:
  groups:
  - name: platform-api.rules
    rules:
    - alert: HighErrorRate
      expr: rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.05
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Tasa de errores HTTP 5xx superior al 5% en {{ $labels.instance }}"
```

---

## 2. Centralización de Logs (Loki / Fluentbit / Vector)

Los contenedores emiten logs a `stdout`/`stderr`. Agentes como **Fluentbit** o **Vector** leen las rutas `/var/log/pods/` del nodo y envían los logs estructurados hacia almacenes centralizados como **Grafana Loki**.

```yaml
apiVersion: config.fluentbit.io/v1alpha2
kind: ClusterFilter
metadata:
  name: kubernetes-filter
spec:
  match: kube.*
  filters:
  - kubernetes:
      kubeURL: https://kubernetes.default.svc:443
      mergeLog: "On"
```

---

## 3. Trazado Distribuido (Distributed Tracing con OpenTelemetry & Jaeger/Tempo)

Para rastrear solicitudes que atraviesan microservicios en la plataforma:
- **OpenTelemetry Collector**: Recibe trazas en formato OTLP (gRPC/HTTP), enriquece los spans con metadatos del Pod/Nodo de Kubernetes y los exporta a **Grafana Tempo** o **Jaeger**.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: platform-monitoring
spec:
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    processors:
      batch:
      k8sattributes:
    exporters:
      otlp/tempo:
        endpoint: tempo-distributor.monitoring:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [k8sattributes, batch]
          exporters: [otlp/tempo]
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenTelemetry Kubernetes Integration — https://opentelemetry.io/docs/kubernetes/
- Prometheus Operator & ServiceMonitors — https://prometheus-operator.dev/
- Grafana Loki Documentation — https://grafana.com/docs/loki/latest/