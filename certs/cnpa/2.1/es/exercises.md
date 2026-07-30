# 2.1 Observability Fundamentals (Traces, Metrics, Logs, and Events)

> Referencia: [CNCF CNPA Curriculum](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

La **Observabilidad** es la capacidad de inferir los estados internos de un sistema complejo basándose en las señales de telemetría emitidas por sus componentes: **Métricas, Logs, Trazas (Traces) y Eventos**.

---

## 1. Las Cuatro Señales de Telemetría (MELT)

- **Metrics (Métricas)**: Valores numéricos agregados a lo largo del tiempo (ej: uso de CPU, tasa de peticiones `http_requests_total`).
- **Events (Eventos)**: Ocurrencias discretas puntuales en el tiempo (ej: reinicio de un Pod, evento `OOMKilled`).
- **Logs (Registros)**: Registros estructurados o texto plano emitidos por la aplicación en `stdout`/`stderr`.
- **Traces (Trazas)**: Diagramas de flujo distribuido que rastrean el trayecto completo de una petición a través de múltiples microservicios (Spans).

---

## 2. El Estándar OpenTelemetry (OTel)

OpenTelemetry (CNCF Incubating) proporciona un estándar unificado de APIs, SDKs y colectores (**OTel Collector**) para recibir, procesar y exportar telemetría sin depender de ningún proveedor propietario (*Vendor Lock-in*).

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector-app
spec:
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
    exporters:
      prometheus:
        endpoint: "0.0.0.0:8889"
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- OpenTelemetry Project Documentation — https://opentelemetry.io/docs/