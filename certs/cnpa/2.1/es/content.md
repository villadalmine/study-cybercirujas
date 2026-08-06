# 2.1 Observability Fundamentals — Traces, Metrics, Logs y Events

> **Dominio 2 — Platform Observability, Security and Conformance** · Peso en el examen: **4.0**
> Perfil: Platform Architect / SRE. El objetivo no es "instalar Prometheus", sino diseñar el **plano de observabilidad de una plataforma multi-tenant**: qué señal emite cada componente, quién la normaliza, dónde se decide qué se descarta, y cómo se demuestra que el pipeline no está mintiendo.

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El problema real no es "falta de datos", es "datos sin correlación"

Un cluster de producción de tamaño medio (40 nodos, 900 pods, 60 servicios) emite sin esfuerzo:

| Fuente | Volumen típico/día | Emisor |
|---|---|---|
| Métricas de infraestructura (kubelet + cAdvisor + kube-state-metrics + node-exporter) | 350k–900k active series | Cluster |
| Métricas de aplicación (RED por endpoint) | 100k–2M active series | Equipos de producto |
| Logs de contenedor (stdout/stderr) | 200 GB–2 TB | Runtime |
| Spans | 500M–5.000M | SDK/eBPF |
| Kubernetes Events | 200k–2M objetos | control plane |

El fallo de producción clásico **no** es que falte el dato: es que a las 03:14 el `p99` de `checkout` sube a 4 s, hay 900 pods candidatos, los logs están en un stack, las métricas en otro, los traces en un tercero, y **nada comparte identidad**. Un log dice `pod=checkout-7d9f-x2k9`, la métrica dice `instance=10.42.3.19:8080`, el span dice `service.name=checkout-svc`. Reconstruir a mano la correspondencia entre esas tres identidades es lo que convierte un MTTR de 4 minutos en uno de 90.

> **Tesis arquitectónica del dominio:** la observabilidad de plataforma es un problema de **normalización de identidad y de control de cardinalidad**, no de elección de backend. El backend es reemplazable; el esquema de atributos, no.

### 1.2 Monitoring vs Observability (la distinción que el examen evalúa)

| | Monitoring | Observability |
|---|---|---|
| Pregunta que responde | "¿Está roto lo que **yo predije** que se podía romper?" | "¿Por qué está roto **esto que nunca previmos**?" |
| Modelo formal | Conjunto finito de checks/thresholds definidos *a priori* | Inferencia del estado interno a partir de salidas externas (teoría de control, Kalman 1960) |
| Cardinalidad tolerada | Baja y acotada | Alta y exploratoria |
| Falla típica | Falso negativo: el modo de falla no estaba en la lista | Costo: el volumen y la cardinalidad crecen sin control |
| Artefacto | Alertas, dashboards | Consultas ad-hoc, correlación, alta dimensionalidad |

Ambos son necesarios. El monitoring **paga las alertas** (baratas, deterministas, SLO-driven); la observabilidad **paga la investigación**. Una plataforma que sólo tiene lo primero no puede depurar incidentes nuevos; una que sólo tiene lo segundo despierta gente por ruido.

### 1.3 Las señales: qué es cada una en términos de estructura de datos

No son "tres pilares" independientes (esa metáfora es un artefacto de vendors: tres silos, tres facturas). Son **cuatro proyecciones de un mismo evento**, unidas por `trace_id` y por los atributos de `Resource`.

- **Metric** — serie temporal: `(name, {labels}, timestamp, value)` con agregación **pre-decidida**. Costo O(series), no O(eventos). Responde *cuánto / con qué frecuencia*. Tipos OTel: `Counter`, `UpDownCounter`, `Gauge`, `Histogram`, `ExponentialHistogram`.
- **Log** — registro textual/estructurado con timestamp: `(timestamp, severity, body, {attributes}, trace_id?, span_id?)`. Costo O(bytes). Responde *qué dijo el proceso*.
- **Trace** — DAG de `Span`s con un `trace_id` (16 bytes) común; cada span: `(trace_id, span_id, parent_span_id, name, kind, start, end, status, {attributes}, [events], [links])`. Costo O(spans). Responde *dónde se fue el tiempo y quién llamó a quién*.
- **Event** — en Kubernetes, un objeto de API (`events.k8s.io/v1`) que describe una transición de estado observada por un controller: `OOMKilled`, `FailedScheduling`, `Unhealthy`, `BackOff`. **No es una métrica ni un log de aplicación**: es la narración del control plane sobre la reconciliación. En OTel, un "event" es un `LogRecord` con `event.name`, o un `Span Event` (timestamp anotado dentro de un span).
- **(Cuarta señal, emergente)** — **Profiles** (OTel Profiling / pprof, señal en desarrollo, donada por Elastic en 2024). Responde *qué línea de código quemó la CPU*.

**Baggage** no es una señal: es un mecanismo de propagación de contexto key/value en banda (header `baggage`, W3C) que permite enriquecer señales aguas abajo (p. ej. `tenant.id`) — con el riesgo de inyectar cardinalidad y datos sensibles.

### 1.4 Por qué esto es un problema de *plataforma* y no de cada equipo

Si cada equipo elige su SDK, su formato de log y su nombre de métrica, la plataforma obtiene N esquemas incompatibles y cero correlación transversal. El patrón de Platform Engineering es:

1. **La plataforma provee un golden path**: auto-instrumentación inyectada por operator, un endpoint OTLP único (`otel-agent`, DNS estable), retención y multi-tenancy resueltos.
2. **La plataforma impone el contrato**: `service.name`, `service.namespace`, `deployment.environment.name`, `k8s.*` — inyectados por la plataforma, no confiados al equipo.
3. **La plataforma opera los guardrails**: límites de cardinalidad, sampling, drop de métricas caras, redacción de PII — en el **Collector**, no en 60 repositorios.
4. **El equipo posee el significado**: sus SLIs, sus SLOs, sus dashboards y sus alertas de negocio.

Esto es exactamente el argumento de **OpenTelemetry** como capa de plataforma: desacopla *instrumentación* (en el código, estable, vendor-neutral) de *routing y backend* (en el Collector, cambiable sin redeploy de aplicaciones). Cambiar de Jaeger a Tempo pasa a ser un cambio de 4 líneas de YAML en un ConfigMap en vez de un rebuild de 60 imágenes.

### 1.5 Marcos de medición que el diseño debe soportar

| Marco | Señales | Aplica a | Métricas |
|---|---|---|---|
| **Four Golden Signals** (Google SRE) | metrics | Servicios | Latency, Traffic, Errors, Saturation |
| **RED** (Tom Wilkie) | metrics/traces | Servicios request-driven | Rate, Errors, Duration |
| **USE** (Brendan Gregg) | metrics | Recursos (CPU, disco, red) | Utilization, Saturation, Errors |
| **SLI/SLO + error budget** | metrics | Contrato con el usuario | Ratio good/total sobre ventana |

Regla de diseño: **RED por servicio, USE por recurso, SLO por journey de usuario.** Las alertas que despiertan gente se derivan del SLO (burn rate); las de USE y las de causa (p. ej. `OOMKilled`) van a ticket/dashboard, no a página.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Señal por señal

| Dimensión | Metrics | Logs | Traces | K8s Events |
|---|---|---|---|---|
| Unidad de costo | active series | bytes ingeridos | spans | objetos en etcd |
| Cardinalidad tolerable | **Baja** (producto cartesiano de labels) | Media (labels bajos + structured metadata) | Alta (atributos por span) | N/A |
| Retención típica | 13 meses (downsampled) | 7–30 días | 3–14 días | **1 hora** (`--event-ttl`) |
| Latencia de consulta | ms | s | s | ms |
| Determinismo | Alto (agregado, sin sampling) | Alto (si no hay drop) | **Bajo si hay sampling** | Alto pero efímero |
| Responde | ¿Cuánto? ¿Está fuera de SLO? | ¿Qué pasó en ese proceso? | ¿Dónde se fue el tiempo? | ¿Qué decidió el control plane? |
| Modo de falla | Explosión de cardinalidad → OOM del TSDB | Explosión de volumen → factura/drop | Traces incompletos → conclusiones falsas | **Pérdida silenciosa por TTL** |
| Apto para alertar | ✅ Sí (barato, determinista) | ⚠️ Sólo con métrica derivada | ❌ No (sampled) | ⚠️ Vía event-exporter → métrica |

**Consecuencia de diseño más importante de la tabla:** los Kubernetes Events **expiran en 1 hora por defecto** y viven en etcd. Un `OOMKilled` a las 02:00 es invisible a las 09:00 en el post-mortem. Toda plataforma seria exporta Events a logs (receiver `k8sobjects` o `kubernetes-event-exporter`) **y** a métricas (`kube_pod_container_status_last_terminated_reason` de kube-state-metrics).

### 2.2 Push vs Pull

| | Pull (scrape, Prometheus) | Push (OTLP, remote_write, StatsD) |
|---|---|---|
| Detección de "target caído" | **Nativa**: `up == 0` | Requiere heartbeat/`absent()` explícito |
| Service discovery | Del scraper (K8s SD) — centralizado | Del emisor — necesita config distribuida |
| Jobs efímeros (batch, Job/CronJob) | ❌ Mal encaje → Pushgateway | ✅ Encaje natural |
| Control de caudal | El scraper decide el intervalo → backpressure implícito | El emisor decide → puede saturar el backend |
| Atravesar NAT/firewall | Requiere conectividad entrante al pod | Sólo saliente |
| Cardinalidad | Contenida por `metric_relabel_configs` en el scraper | Se contiene en el Collector (processors) |

**Patrón híbrido de referencia (el que se usa en producción):** pull para infraestructura (`kubelet`, `kube-state-metrics`, `node-exporter`) donde `up` es el health check más valioso; push OTLP para aplicaciones, donde el mismo canal transporta las cuatro señales con el mismo `Resource`.

### 2.3 Head sampling vs Tail sampling

| | Head sampling | Tail sampling |
|---|---|---|
| Dónde decide | SDK, al crear el root span | Collector, tras esperar el trace completo |
| Información disponible | Ninguna (aún no pasó nada) | Latencia, status, atributos de todo el trace |
| Costo de red | **Bajo** (no se envía lo descartado) | Alto (se envía todo, se descarta al final) |
| Memoria del Collector | Nula | `num_traces × tamaño_trace` retenidos `decision_wait` |
| ¿Conserva todos los errores? | ❌ No (probabilístico) | ✅ Sí (política por `status_code`) |
| Requisito topológico | Ninguno | **Todos los spans de un `trace_id` en la misma instancia** → `loadbalancing` exporter |
| Consistencia | Debe propagarse por `tracestate` (`ot=th:…`) o los traces salen rotos | Consistente por construcción |

**Trade-off central:** head sampling al 1 % es barato y produce traces estadísticamente válidos pero **pierde el 99 % de los errores raros**, que es justamente lo que se busca. Tail sampling conserva el 100 % de los errores y de las colas de latencia a cambio de costo de red y una restricción topológica dura. El patrón estándar es **head sampling agresivo sólo para tráfico de health checks + tail sampling para el resto**.

### 2.4 Backends (para decidir, no para memorizar)

| Señal | Opción | Modelo | Trade-off dominante |
|---|---|---|---|
| Metrics | **Prometheus** (CNCF graduated) | TSDB local, pull | Simple y sólido; sin HA real ni retención larga sin ayuda |
| | **Thanos** / **Cortex** (CNCF incubating) | Sidecar+object storage / microservicios | Retención infinita y global query; complejidad operativa alta |
| | **Mimir** (Grafana, AGPL) | Cortex fork, multi-tenant | Escala y tenancy nativa; no CNCF |
| | **VictoriaMetrics** | TSDB propio | Menor footprint; divergencias sutiles en PromQL |
| Logs | **Loki** (Grafana) | Index de labels + chunks en object storage | Barato; consultas full-text amplias son caras |
| | **Elasticsearch/OpenSearch** | Índice invertido completo | Búsqueda rica; costo de CPU/disco muy superior |
| Traces | **Jaeger** (CNCF graduated) | Cassandra/ES/Badger | Maduro; el backend v1 quedó atado a su modelo |
| | **Tempo** (Grafana) | Sólo object storage, TraceQL | Costo mínimo; búsqueda por atributo requiere índices/TraceQL |
| Agentes | **Fluent Bit / Fluentd** (CNCF graduated) | Logs | Footprint mínimo (C) vs riqueza de plugins (Ruby) |
| | **OTel Collector** (CNCF incubating) | Las 4 señales | Un único agente para todo; superficie de configuración grande |
| | **Grafana Alloy** | Distro de OTel + Prometheus | Buena integración LGTM; opinado |

> **Para el examen:** Prometheus, OpenTelemetry, Jaeger, Fluentd/Fluent Bit, Thanos, Cortex y OpenCost son proyectos **CNCF**. Loki, Tempo, Mimir y Alloy son de **Grafana Labs** (AGPL/open source, no CNCF). OpenMetrics fue **archivado** en 2024 y su trabajo se absorbió en Prometheus.

---

## 3. Arquitectura de referencia y manifiestos completos

### 3.1 Topología

```
┌─────────────────────────────────────────────────────────────────────────┐
│ node-1 … node-N                                                         │
│  ┌────────────┐  OTLP :4317/4318   ┌──────────────────────────────┐     │
│  │  app pods  │───────────────────▶│  otel-agent (DaemonSet)      │     │
│  │  (SDK auto)│                    │  filelog  → logs de contenedor│     │
│  └────────────┘                    │  kubeletstats → USE del nodo  │     │
│                                    │  k8sattributes → identidad    │     │
│                                    └───────────────┬───────────────┘     │
└────────────────────────────────────────────────────┼─────────────────────┘
                     loadbalancing exporter (routing_key: traceID)
                                                     │
┌────────────────────────────────────────────────────▼─────────────────────┐
│  otel-gateway (Deployment, N réplicas)                                   │
│   tail_sampling · spanmetrics connector · transform/OTTL (PII+cardinal.) │
│   routing por tenant  ·  headers_setter (X-Scope-OrgID)                  │
└───────┬──────────────────────┬────────────────────────┬─────────────────┘
        │ OTLP traces          │ remote_write metrics   │ OTLP logs
        ▼                      ▼                        ▼
     Tempo/Jaeger        Prometheus/Mimir             Loki
        └──────────── Grafana (exemplars: metric → trace → log) ───────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  otel-cluster (Deployment, replicas: 1  ← SINGLETON OBLIGATORIO)         │
│   k8sobjects  → Kubernetes Events como logs                              │
│   k8s_cluster → métricas de estado del cluster                           │
└──────────────────────────────────────────────────────────────────────────┘
```

**Regla dura:** `k8sobjects` y `k8s_cluster` son *watchers* del API server. Con 3 réplicas se obtienen **3 copias de cada Event** y métricas de cluster triplicadas. Deben correr en un Deployment `replicas: 1` (o con leader election habilitada).

### 3.2 Namespace y RBAC (least privilege, separado por rol)

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    pod-security.kubernetes.io/enforce: privileged   # el agent monta /var/log
    app.kubernetes.io/part-of: platform-observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-agent
  namespace: observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-cluster
  namespace: observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-gateway
  namespace: observability
---
# ── Agent: identidad de pods (k8sattributes) + kubelet stats + resolver k8s
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent
rules:
  # k8sattributes processor
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  # kubeletstats receiver (auth_type: serviceAccount)
  - apiGroups: [""]
    resources: ["nodes/stats", "nodes/proxy"]
    verbs: ["get"]
  # loadbalancing exporter, resolver k8s (descubre los pods del gateway)
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["list", "watch", "get"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["list", "watch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-agent
subjects:
  - kind: ServiceAccount
    name: otel-agent
    namespace: observability
---
# ── Cluster collector: Events + estado del cluster (sólo lectura)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-cluster
rules:
  - apiGroups: [""]
    resources:
      ["events", "namespaces", "namespaces/status", "nodes", "nodes/spec",
       "pods", "pods/status", "replicationcontrollers", "replicationcontrollers/status",
       "resourcequotas", "services", "persistentvolumes", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["daemonsets", "deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-cluster
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-cluster
subjects:
  - kind: ServiceAccount
    name: otel-cluster
    namespace: observability
```

### 3.3 Agent (DaemonSet): logs de contenedor, USE del nodo e identidad

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-agent
  namespace: observability
spec:
  mode: daemonset
  # Pineá la versión: el proyecto publica releases cada ~2 semanas.
  image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.128.0
  serviceAccount: otel-agent
  hostNetwork: false
  tolerations:
    - operator: Exists          # el agent debe correr también en nodos con taints
  resources:
    requests: { cpu: 200m, memory: 384Mi }
    limits:   { memory: 768Mi }        # NO pongas límite de CPU: causa throttling y lag de export
  env:
    - name: K8S_NODE_NAME
      valueFrom:
        fieldRef: { fieldPath: spec.nodeName }
    - name: K8S_POD_IP
      valueFrom:
        fieldRef: { fieldPath: status.podIP }
    - name: GOMEMLIMIT
      value: "600MiB"                  # soft limit del GC de Go, por debajo del limit del contenedor
  volumeMounts:
    - name: varlogpods
      mountPath: /var/log/pods
      readOnly: true
    - name: varlibdockercontainers
      mountPath: /var/lib/docker/containers
      readOnly: true
    - name: filelogstate
      mountPath: /var/lib/otelcol
  volumes:
    - name: varlogpods
      hostPath: { path: /var/log/pods }
    - name: varlibdockercontainers
      hostPath: { path: /var/lib/docker/containers }
    - name: filelogstate
      hostPath: { path: /var/lib/otelcol, type: DirectoryOrCreate }
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: ${env:K8S_POD_IP}:4317
            max_recv_msg_size_mib: 16
          http:
            endpoint: ${env:K8S_POD_IP}:4318

      # Logs de contenedor desde el filesystem del nodo (CRI-O / containerd)
      filelog:
        include: [ /var/log/pods/*/*/*.log ]
        exclude: [ /var/log/pods/observability_otel-agent-*_*/*/*.log ]  # evita loop de logs
        start_at: end
        include_file_path: true
        include_file_name: false
        poll_interval: 200ms
        max_concurrent_files: 512
        fingerprint_size: 1kb
        storage: file_storage/filelog
        operators:
          - id: container-parser
            type: container                # parsea CRI/containerd/docker y reensambla multiline
            add_metadata_from_filepath: true
          - id: severity-from-json
            type: json_parser
            if: 'body matches "^\\{"'
            parse_from: body
            parse_to: attributes
            severity:
              parse_from: attributes.level
              mapping:
                error: [ "error", "err", "fatal", "panic" ]
                warn:  [ "warn", "warning" ]
                info:  [ "info" ]
                debug: [ "debug", "trace" ]
          # Correlación log ↔ trace: promueve trace_id/span_id a campos de primer nivel
          - id: trace-correlation
            type: trace_parser
            if: 'attributes["trace_id"] != nil'
            trace_id:  { parse_from: attributes.trace_id }
            span_id:   { parse_from: attributes.span_id }
            trace_flags: { parse_from: attributes.trace_flags }

      # USE del nodo/pod/contenedor directamente del kubelet
      kubeletstats:
        collection_interval: 20s
        auth_type: serviceAccount
        endpoint: https://${env:K8S_NODE_NAME}:10250
        insecure_skip_verify: true
        metric_groups: [ node, pod, container, volume ]
        k8s_api_config:
          auth_type: serviceAccount

      # Auto-scrape de pods con anotación prometheus.io/scrape (compatibilidad)
      prometheus:
        config:
          scrape_configs:
            - job_name: kubernetes-pods
              scrape_interval: 30s
              kubernetes_sd_configs:
                - role: pod
                  selectors:
                    - role: pod
                      field: spec.nodeName=${env:K8S_NODE_NAME}
              relabel_configs:
                - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
                  action: keep
                  regex: "true"
                - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
                  action: replace
                  target_label: __metrics_path__
                  regex: (.+)
                - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
                  action: replace
                  regex: ([^:]+)(?::\d+)?;(\d+)
                  replacement: $$1:$$2
                  target_label: __address__
                - source_labels: [__meta_kubernetes_namespace]
                  target_label: k8s_namespace_name
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: k8s_pod_name

    processors:
      # SIEMPRE primero en toda pipeline. Aplica backpressure antes del OOMKill.
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25

      # Identidad canónica: convierte IP/UID en atributos k8s.* comparables entre señales
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          node_from_env_var: K8S_NODE_NAME     # sin esto, cada agent watchea TODOS los pods
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.pod.start_time
            - k8s.deployment.name
            - k8s.statefulset.name
            - k8s.daemonset.name
            - k8s.job.name
            - k8s.cronjob.name
            - k8s.node.name
            - k8s.container.name
            - container.image.name
            - container.image.tag
          labels:
            - tag_name: service.namespace
              key: app.kubernetes.io/part-of
              from: pod
            - tag_name: service.version
              key: app.kubernetes.io/version
              from: pod
            - tag_name: tenant.id
              key: platform.internal/tenant
              from: namespace
        pod_association:
          - sources: [ { from: resource_attribute, name: k8s.pod.uid } ]
          - sources: [ { from: resource_attribute, name: k8s.pod.ip } ]
          - sources: [ { from: connection } ]     # fallback: IP de origen de la conexión gRPC

      resourcedetection/k8s:
        detectors: [ env, system, k8snode ]
        system:
          hostname_sources: [ os ]
        k8snode:
          auth_type: serviceAccount
          node_from_env_var: K8S_NODE_NAME
        override: false

      # Defaults obligatorios: sin service.name todo cae en "unknown_service"
      resource/defaults:
        attributes:
          - key: k8s.cluster.name
            value: prod-eu-west-1
            action: upsert
          - key: deployment.environment.name
            value: production
            action: insert
          - key: service.name
            from_attribute: k8s.deployment.name
            action: insert

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 5s

    extensions:
      health_check:
        endpoint: ${env:K8S_POD_IP}:13133
      pprof:
        endpoint: 127.0.0.1:1777
      zpages:
        endpoint: 127.0.0.1:55679
      file_storage/filelog:
        directory: /var/lib/otelcol          # persiste offsets: sin esto, un restart re-lee o pierde logs
        timeout: 10s

    exporters:
      # Rutea por trace_id para que el tail_sampling del gateway vea el trace COMPLETO
      loadbalancing:
        routing_key: traceID
        protocol:
          otlp:
            tls: { insecure: true }
            timeout: 10s
            sending_queue:
              enabled: true
              num_consumers: 10
              queue_size: 10000
            retry_on_failure:
              enabled: true
              initial_interval: 5s
              max_interval: 30s
              max_elapsed_time: 300s
        resolver:
          k8s:
            service: otel-gateway-collector.observability
            ports: [ 4317 ]

      otlp/gateway:
        endpoint: otel-gateway-collector.observability.svc.cluster.local:4317
        tls: { insecure: true }
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 10000
          storage: file_storage/filelog       # cola persistente: sobrevive al restart del pod
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

    service:
      extensions: [ health_check, pprof, zpages, file_storage/filelog ]
      pipelines:
        traces:
          receivers:  [ otlp ]
          processors: [ memory_limiter, k8sattributes, resourcedetection/k8s, resource/defaults, batch ]
          exporters:  [ loadbalancing ]
        metrics:
          receivers:  [ otlp, kubeletstats, prometheus ]
          processors: [ memory_limiter, k8sattributes, resourcedetection/k8s, resource/defaults, batch ]
          exporters:  [ otlp/gateway ]
        logs:
          receivers:  [ otlp, filelog ]
          processors: [ memory_limiter, k8sattributes, resourcedetection/k8s, resource/defaults, batch ]
          exporters:  [ otlp/gateway ]
      telemetry:
        logs:
          level: info
          encoding: json
        metrics:
          level: detailed
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
```

### 3.4 Cluster collector (SINGLETON): Kubernetes Events y estado del cluster

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-cluster
  namespace: observability
spec:
  mode: deployment
  replicas: 1                  # ⚠️ NO escalar: k8sobjects y k8s_cluster duplican datos por réplica
  image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.128.0
  serviceAccount: otel-cluster
  resources:
    requests: { cpu: 200m, memory: 512Mi }
    limits:   { memory: 1Gi }
  config:
    receivers:
      # Kubernetes Events → LogRecords OTLP. Esto es lo que los rescata del TTL de 1h en etcd.
      k8sobjects:
        auth_type: serviceAccount
        objects:
          - name: events
            group: events.k8s.io
            mode: watch
            interval: 15s
          - name: pods
            mode: pull
            interval: 5m
            label_selector: platform.internal/critical=true

      # Estado del cluster (equivalente conceptual a kube-state-metrics, nativo OTel)
      k8s_cluster:
        auth_type: serviceAccount
        collection_interval: 30s
        node_conditions_to_report: [ Ready, MemoryPressure, DiskPressure, PIDPressure ]
        allocatable_types_to_report: [ cpu, memory, ephemeral-storage, pods ]
        metrics:
          k8s.pod.status_reason:
            enabled: true

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25

      # Normaliza el Event a algo consultable y alertable
      transform/events:
        error_mode: ignore
        log_statements:
          - context: log
            statements:
              - set(severity_text, "ERROR")   where attributes["k8s.event.type"] == "Warning"
              - set(severity_number, 17)      where attributes["k8s.event.type"] == "Warning"
              - set(attributes["event.domain"], "k8s")
              - set(attributes["event.name"], attributes["k8s.event.reason"])
              - set(resource.attributes["service.name"], "kubernetes-events")

      # Los Events del control plane son ruidosos: descartá los que nadie consulta jamás
      filter/events_noise:
        error_mode: ignore
        logs:
          log_record:
            - 'attributes["k8s.event.reason"] == "Pulled"'
            - 'attributes["k8s.event.reason"] == "Created"'
            - 'attributes["k8s.event.reason"] == "Started"'

      # Convierte Warnings en una métrica alertable — los logs no se alertan bien
      batch:
        send_batch_size: 1024
        timeout: 5s

    connectors:
      # Event → métrica: permite alertar sobre OOMKilled/FailedScheduling sin depender de logs
      count:
        logs:
          k8s.events.count:
            description: Kubernetes Events observados, por reason y tipo
            attributes:
              - key: k8s.event.reason
              - key: k8s.event.type
              - key: k8s.namespace.name

    exporters:
      otlp/gateway:
        endpoint: otel-gateway-collector.observability.svc.cluster.local:4317
        tls: { insecure: true }
        retry_on_failure: { enabled: true }

    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }

    service:
      extensions: [ health_check ]
      pipelines:
        logs/events:
          receivers:  [ k8sobjects ]
          processors: [ memory_limiter, filter/events_noise, transform/events, batch ]
          exporters:  [ otlp/gateway, count ]
        metrics/events:
          receivers:  [ count ]
          processors: [ memory_limiter, batch ]
          exporters:  [ otlp/gateway ]
        metrics/cluster:
          receivers:  [ k8s_cluster ]
          processors: [ memory_limiter, batch ]
          exporters:  [ otlp/gateway ]
      telemetry:
        metrics:
          readers:
            - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
```

### 3.5 Gateway: tail sampling, span metrics, guardrails y multi-tenancy

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-gateway
  namespace: observability
spec:
  mode: deployment
  replicas: 3
  image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.128.0
  serviceAccount: otel-gateway
  podDisruptionBudget:
    minAvailable: 2
  resources:
    requests: { cpu: "1", memory: 3Gi }
    limits:   { memory: 6Gi }          # tail_sampling retiene traces en RAM: dimensioná con holgura
  env:
    - name: GOMEMLIMIT
      value: "4800MiB"
  autoscaler:
    minReplicas: 3
    maxReplicas: 12
    targetCPUUtilization: 70
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            max_recv_msg_size_mib: 32
            keepalive:
              server_parameters:
                max_connection_age: 60s          # fuerza rebalanceo de conexiones gRPC entre réplicas
                max_connection_age_grace: 10s
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20

      # ── Guardrail 1: PII y normalización de cardinalidad (OTTL)
      transform/scrub:
        error_mode: ignore
        trace_statements:
          - context: span
            statements:
              - delete_key(attributes, "http.request.header.authorization")
              - delete_key(attributes, "http.request.header.cookie")
              - delete_key(attributes, "db.statement.parameters")
              # /orders/98213 y /orders/98214 NO deben ser dos valores distintos de http.route
              - replace_pattern(attributes["url.path"], "/orders/[0-9]+", "/orders/{id}")
              - replace_pattern(attributes["url.path"], "/users/[0-9a-f-]{36}", "/users/{uuid}")
        metric_statements:
          - context: datapoint
            statements:
              - delete_key(attributes, "http.request.header.authorization")
              - delete_key(attributes, "net.peer.port")      # cardinalidad infinita, valor nulo
              - delete_key(attributes, "k8s.pod.uid")        # NO en métricas: cambia en cada rollout

      # ── Guardrail 2: drop de métricas caras conocidas
      filter/expensive_metrics:
        error_mode: ignore
        metrics:
          metric:
            - 'name == "apiserver_request_duration_seconds_bucket"'
            - 'IsMatch(name, "^etcd_request_duration_seconds_bucket$")'
            - 'IsMatch(name, "^rest_client_request_duration_seconds_bucket$")'

      # ── Tail sampling: exige que TODOS los spans del trace lleguen a esta réplica
      tail_sampling:
        decision_wait: 30s              # > p99 de duración de trace, o cortás traces largos
        num_traces: 200000              # traces en memoria; principal driver de RAM
        expected_new_traces_per_sec: 4000
        policies:
          # 1. Todo lo que falló se conserva, sin excepción
          - name: keep-errors
            type: status_code
            status_code: { status_codes: [ ERROR ] }
          # 2. Toda la cola de latencia se conserva
          - name: keep-slow
            type: latency
            latency: { threshold_ms: 800 }
          # 3. Todo lo de los servicios críticos de negocio
          - name: keep-critical-tenants
            type: and
            and:
              and_sub_policy:
                - name: ns-match
                  type: string_attribute
                  string_attribute:
                    key: k8s.namespace.name
                    values: [ payments, checkout ]
                    enabled_regex_matching: false
                - name: always
                  type: always_sample
          # 4. Health checks: descartados por completo (invertí el match)
          - name: drop-health
            type: string_attribute
            string_attribute:
              key: url.path
              values: [ "/healthz", "/readyz", "/livez", "/metrics" ]
              invert_match: true
          # 5. Baseline estadístico del tráfico sano
          - name: baseline
            type: probabilistic
            probabilistic: { sampling_percentage: 5 }

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 5s

    connectors:
      # RED metrics derivadas de spans: latencia/errores/rate por servicio SIN instrumentar métricas
      spanmetrics:
        histogram:
          explicit:
            buckets: [ 2ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s ]
        dimensions:
          - name: http.request.method
          - name: http.response.status_code
          - name: http.route
          - name: k8s.namespace.name
          - name: deployment.environment.name
        exemplars:
          enabled: true                 # ⚠️ ESTO es lo que permite saltar de la métrica al trace
        dimensions_cache_size: 100000
        metrics_flush_interval: 30s
        namespace: traces.spanmetrics

      # Grafo de servicios derivado de spans client/server
      servicegraph:
        latency_histogram_buckets: [ 10ms, 50ms, 100ms, 500ms, 1s, 5s ]
        dimensions: [ k8s.namespace.name ]
        store: { ttl: 5s, max_items: 100000 }

      # Multi-tenancy: separa el tráfico por tenant para backends con X-Scope-OrgID
      routing/tenant:
        default_pipelines: [ metrics/shared ]
        error_mode: ignore
        table:
          - context: resource
            condition: attributes["tenant.id"] == "payments"
            pipelines: [ metrics/payments ]

    exporters:
      otlp/tempo:
        endpoint: tempo-distributor.observability.svc.cluster.local:4317
        tls: { insecure: true }
        headers: { "X-Scope-OrgID": "platform" }
        sending_queue: { enabled: true, num_consumers: 20, queue_size: 20000 }
        retry_on_failure: { enabled: true, max_elapsed_time: 300s }

      prometheusremotewrite/mimir:
        endpoint: http://mimir-nginx.observability.svc.cluster.local/api/v1/push
        headers: { "X-Scope-OrgID": "platform" }
        target_info: { enabled: true }          # emite target_info para joins con resource attrs
        # ⚠️ resource_to_telemetry_conversion=true convierte TODO resource attr en label:
        #    es la causa #1 de explosión de cardinalidad. Mantener en false.
        resource_to_telemetry_conversion: { enabled: false }
        remote_write_queue: { enabled: true, num_consumers: 10, queue_size: 100000 }
        external_labels: { cluster: prod-eu-west-1 }

      otlphttp/loki:
        # Loki 3.x expone ingest OTLP nativo; el sufijo /v1/logs lo agrega el exporter
        endpoint: http://loki-gateway.observability.svc.cluster.local:3100/otlp
        headers: { "X-Scope-OrgID": "platform" }
        sending_queue: { enabled: true, queue_size: 20000 }
        retry_on_failure: { enabled: true }

      debug:
        verbosity: normal
        sampling_initial: 5
        sampling_thereafter: 200

    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }
      pprof:        { endpoint: 127.0.0.1:1777 }
      zpages:       { endpoint: 127.0.0.1:55679 }

    service:
      extensions: [ health_check, pprof, zpages ]
      pipelines:
        traces:
          receivers:  [ otlp ]
          processors: [ memory_limiter, transform/scrub, tail_sampling, batch ]
          exporters:  [ otlp/tempo, spanmetrics, servicegraph ]
        metrics:
          receivers:  [ otlp, spanmetrics, servicegraph ]
          processors: [ memory_limiter, filter/expensive_metrics, transform/scrub, batch ]
          exporters:  [ prometheusremotewrite/mimir ]
        logs:
          receivers:  [ otlp ]
          processors: [ memory_limiter, transform/scrub, batch ]
          exporters:  [ otlphttp/loki ]
      telemetry:
        logs: { level: info, encoding: json }
        metrics:
          level: detailed
          readers:
            - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
```

### 3.6 Auto-instrumentación: el golden path del desarrollador

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: platform-default
  namespace: observability
spec:
  exporter:
    endpoint: http://$(OTEL_K8S_NODE_IP):4318      # el agent del PROPIO nodo: 0 hops de red
  propagators:
    - tracecontext          # W3C traceparent — el estándar
    - baggage
    - b3multi               # compatibilidad con servicios legacy Zipkin/Istio
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"         # head sampling al 100%: la decisión real la toma el tail_sampling
  resource:
    addK8sUIDAttributes: true
  env:
    - name: OTEL_K8S_NODE_IP
      valueFrom:
        fieldRef: { fieldPath: status.hostIP }
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: http/protobuf
    - name: OTEL_METRICS_EXEMPLAR_FILTER
      value: trace_based    # sólo adjunta exemplars de requests sampleadas
  java:
    env:
      - name: OTEL_INSTRUMENTATION_COMMON_DEFAULT_ENABLED
        value: "true"
      - name: OTEL_INSTRUMENTATION_JDBC_STATEMENT_SANITIZER_ENABLED
        value: "true"       # elimina literales del SQL: PII + cardinalidad
    resources:
      requests: { cpu: 10m, memory: 64Mi }
      limits:   { memory: 128Mi }
  python:
    env:
      - name: OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED
        value: "true"
  nodejs: {}
  go:
    env:
      - name: OTEL_GO_AUTO_TARGET_EXE
        value: /app/server
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: payments
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/part-of: payments-platform     # → service.namespace
    app.kubernetes.io/version: "2.14.3"              # → service.version
spec:
  replicas: 6
  selector:
    matchLabels: { app.kubernetes.io/name: checkout }
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/part-of: payments-platform
        app.kubernetes.io/version: "2.14.3"
      annotations:
        # Una sola línea activa traces + metrics + logs correlacionados. Ese es el golden path.
        instrumentation.opentelemetry.io/inject-java: "observability/platform-default"
        instrumentation.opentelemetry.io/container-names: "checkout"
    spec:
      containers:
        - name: checkout
          image: registry.internal/payments/checkout:2.14.3
          ports:
            - { name: http, containerPort: 8080 }
            - { name: metrics, containerPort: 9090 }
          env:
            # Contrato de identidad de la plataforma — NO se delega al equipo
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=payments-platform,deployment.environment.name=production"
            - name: K8S_POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
          resources:
            requests: { cpu: 300m, memory: 512Mi }
            limits:   { memory: 1Gi }
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /livez, port: http }
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: checkout
  namespace: payments
  labels: { app.kubernetes.io/name: checkout }
spec:
  selector: { app.kubernetes.io/name: checkout }
  ports:
    - { name: http, port: 8080, targetPort: http }
    - { name: metrics, port: 9090, targetPort: metrics }
```

### 3.7 Scrape declarativo y alertas por burn rate de SLO

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: checkout
  namespace: payments
  labels: { release: kube-prometheus-stack }   # debe matchear serviceMonitorSelector del Prometheus
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: checkout }
  namespaceSelector:
    matchNames: [ payments ]
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      # Guardrail de cardinalidad aplicado en el scraper, no en la app
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: 'go_gc_duration_seconds.*|process_.*_fds'
          action: drop
        - sourceLabels: [http_route]
          regex: '(.*/[0-9a-f]{8}-[0-9a-f]{4}-.*)'   # rutas con UUID sin normalizar
          action: drop
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: checkout-slo
  namespace: payments
  labels: { release: kube-prometheus-stack }
spec:
  groups:
    # ── Recording rules: precalculan el SLI para que las alertas sean baratas
    - name: checkout.sli
      interval: 30s
      rules:
        - record: sli:checkout_requests:rate5m
          expr: sum(rate(http_server_request_duration_seconds_count{job="checkout"}[5m]))
        - record: sli:checkout_errors:ratio_rate5m
          expr: |
            sum(rate(http_server_request_duration_seconds_count{job="checkout",http_response_status_code=~"5.."}[5m]))
              /
            sum(rate(http_server_request_duration_seconds_count{job="checkout"}[5m]))
        - record: sli:checkout_errors:ratio_rate30m
          expr: |
            sum(rate(http_server_request_duration_seconds_count{job="checkout",http_response_status_code=~"5.."}[30m]))
              /
            sum(rate(http_server_request_duration_seconds_count{job="checkout"}[30m]))
        - record: sli:checkout_errors:ratio_rate1h
          expr: |
            sum(rate(http_server_request_duration_seconds_count{job="checkout",http_response_status_code=~"5.."}[1h]))
              /
            sum(rate(http_server_request_duration_seconds_count{job="checkout"}[1h]))
        - record: sli:checkout_errors:ratio_rate6h
          expr: |
            sum(rate(http_server_request_duration_seconds_count{job="checkout",http_response_status_code=~"5.."}[6h]))
              /
            sum(rate(http_server_request_duration_seconds_count{job="checkout"}[6h]))

    # ── Alertas SLO: multi-window, multi-burn-rate (Google SRE Workbook, cap. 5)
    #    SLO = 99.9% de disponibilidad → error budget = 0.001
    - name: checkout.slo
      rules:
        - alert: CheckoutErrorBudgetBurnFast
          # 14.4x consume el 2% del budget mensual en 1 hora → PAGE
          expr: |
            sli:checkout_errors:ratio_rate5m > (14.4 * 0.001)
              and
            sli:checkout_errors:ratio_rate1h > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            slo: checkout-availability
            team: payments
          annotations:
            summary: "checkout quema el error budget 14.4x (burn rápido)"
            description: >-
              Error ratio 5m={{ $value | humanizePercentage }} sobre un SLO de 99.9%.
              A este ritmo el budget mensual se agota en ~2 días.
            runbook_url: https://runbooks.internal/slo/checkout-availability
            trace_query: '{ resource.service.name="checkout" && status=error }'

        - alert: CheckoutErrorBudgetBurnSlow
          # 6x consume el 5% del budget en 6 horas → PAGE de menor urgencia
          expr: |
            sli:checkout_errors:ratio_rate30m > (6 * 0.001)
              and
            sli:checkout_errors:ratio_rate6h > (6 * 0.001)
          for: 15m
          labels: { severity: warning, slo: checkout-availability, team: payments }
          annotations:
            summary: "checkout quema el error budget 6x (burn sostenido)"
            runbook_url: https://runbooks.internal/slo/checkout-availability

    # ── Salud del PIPELINE de observabilidad (meta-monitoring: no negociable)
    - name: observability.pipeline
      rules:
        - alert: OtelCollectorDroppingData
          expr: |
            sum by (job, exporter) (rate(otelcol_exporter_send_failed_spans_total[5m])) > 0
              or
            sum by (job, exporter) (rate(otelcol_exporter_send_failed_metric_points_total[5m])) > 0
          for: 10m
          labels: { severity: critical, team: platform }
          annotations:
            summary: "El Collector {{ $labels.job }} está perdiendo telemetría vía {{ $labels.exporter }}"

        - alert: OtelCollectorRefusingData
          # memory_limiter aplicando backpressure = el Collector está subdimensionado
          expr: sum by (job) (rate(otelcol_receiver_refused_spans_total[5m])) > 0
          for: 5m
          labels: { severity: warning, team: platform }
          annotations:
            summary: "memory_limiter rechaza spans en {{ $labels.job }}: aumentá memoria o réplicas"

        - alert: OtelCollectorQueueNearFull
          expr: otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8
          for: 10m
          labels: { severity: warning, team: platform }

        - alert: PrometheusCardinalityExplosion
          expr: prometheus_tsdb_head_series > 1.5e6
          for: 30m
          labels: { severity: warning, team: platform }
          annotations:
            summary: "TSDB con {{ $value | humanize }} active series — revisá /api/v1/status/tsdb"

        - alert: KubeEventsOOMKilledSpike
          # Los Events expiran en 1h; esta métrica los vuelve alertables y retenibles
          expr: |
            sum by (k8s_namespace_name) (
              increase(k8s_events_count_total{k8s_event_reason="OOMKilling"}[15m])
            ) > 3
          labels: { severity: warning }
          annotations:
            summary: "≥3 OOMKilled en 15m en {{ $labels.k8s_namespace_name }}"

        - alert: ScrapeTargetDown
          expr: up == 0
          for: 5m
          labels: { severity: critical, team: platform }
          annotations:
            summary: "Target {{ $labels.job }}/{{ $labels.instance }} inalcanzable hace 5m"
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Estado del plano de observabilidad

```console
$ kubectl get otelcol -n observability
NAME           MODE         VERSION   READY   AGE   IMAGE                                                                                              MANAGEMENT
otel-agent     daemonset    0.128.0   6/6     14d   ghcr.io/open-telemetry/opentelemetry-collector-releases/...-contrib:0.128.0   managed
otel-cluster   deployment   0.128.0   1/1     14d   ghcr.io/open-telemetry/opentelemetry-collector-releases/...-contrib:0.128.0   managed
otel-gateway   deployment   0.128.0   3/3     14d   ghcr.io/open-telemetry/opentelemetry-collector-releases/...-contrib:0.128.0   managed

$ kubectl get pods -n observability -l app.kubernetes.io/component=opentelemetry-collector
NAME                                      READY   STATUS    RESTARTS      AGE
otel-agent-collector-4jm2p                1/1     Running   0             3d4h
otel-agent-collector-8xk7t                1/1     Running   0             3d4h
otel-agent-collector-b9dqz                1/1     Running   2 (26h ago)   3d4h
otel-cluster-collector-7c46b9f8d5-tq2wl   1/1     Running   0             3d4h
otel-gateway-collector-5f7b8c9d4-l8xmv    1/1     Running   0             6h12m
otel-gateway-collector-5f7b8c9d4-pq4rn    1/1     Running   0             6h12m
otel-gateway-collector-5f7b8c9d4-zw9kf    1/1     Running   0             6h12m
```

### 4.2 Auditar el propio pipeline (meta-observabilidad)

```console
$ kubectl -n observability port-forward deploy/otel-gateway-collector 8888:8888 >/dev/null 2>&1 &
$ curl -s localhost:8888/metrics | grep -E '^otelcol_(receiver|processor|exporter)' | grep -v '^#' | sort
otelcol_exporter_queue_capacity{exporter="otlp/tempo",...} 20000
otelcol_exporter_queue_size{exporter="otlp/tempo",...} 137
otelcol_exporter_send_failed_spans_total{exporter="otlp/tempo",...} 0
otelcol_exporter_sent_metric_points_total{exporter="prometheusremotewrite/mimir",...} 4.8271933e+07
otelcol_exporter_sent_spans_total{exporter="otlp/tempo",...} 1.2842937e+06
otelcol_processor_tail_sampling_count_traces_sampled{policy="baseline",sampled="false",...} 8.913442e+06
otelcol_processor_tail_sampling_count_traces_sampled{policy="baseline",sampled="true",...} 469128
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-errors",sampled="true",...} 21455
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-slow",sampled="true",...} 8802
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc",...} 9.7233821e+06
otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc",...} 0
```

**Cómo se lee esta salida (la ecuación de conservación del pipeline):**

```
accepted − refused − (dropped por processors) ≈ sent + queue_size + send_failed
```

Cualquier desbalance persistente es **pérdida silenciosa de telemetría**. `refused > 0` significa que `memory_limiter` está aplicando backpressure; `send_failed > 0` significa que el backend rechaza o está caído.

```console
$ curl -s localhost:8888/metrics | grep otelcol_processor_tail_sampling_sampling_trace_dropped_too_early
# HELP otelcol_processor_tail_sampling_sampling_trace_dropped_too_early Count of traces evicted before the decision
otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total{...} 0
```

> Si `dropped_too_early > 0`, `num_traces` es demasiado bajo: se están evictando traces del buffer **antes** de que venza `decision_wait`, y las decisiones de sampling se toman sobre traces incompletos.

### 4.3 Verificar la propagación de contexto W3C end-to-end

```console
$ kubectl -n payments run curl-probe --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
    curl -s -D- -o /dev/null http://checkout.payments.svc.cluster.local:8080/api/v1/cart \
    -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
HTTP/1.1 200 OK
content-type: application/json
traceresponse: 00-4bf92f3577b34da6a3ce929d0e0e4736-7d3a1c5e9b204f81-01
x-request-id: 8f2a1e04-9c33-4d1a-b7f6-2c0e5a913d44
date: Thu, 06 Aug 2026 09:41:07 GMT
pod "curl-probe" deleted
```

Anatomía del header `traceparent` (W3C Trace Context):

```
00      -  4bf92f3577b34da6a3ce929d0e0e4736  -  00f067aa0ba902b7  -  01
│          │                                    │                    │
version    trace-id (16 bytes / 32 hex)         parent-span-id       trace-flags
                                                (8 bytes/16 hex)     bit 0 = sampled
```

El `trace-id` devuelto es **el mismo** que se envió → la propagación funciona. Si difiere, algún hop rompió el contexto (proxy que no forwardea headers, thread pool sin propagación de contexto, cliente HTTP no instrumentado).

### 4.4 Correlacionar las cuatro señales sobre un mismo incidente

```console
# 1) MÉTRICA: ¿qué servicio está fuera de SLO?
$ curl -sG http://prometheus-operated.observability:9090/api/v1/query \
    --data-urlencode 'query=topk(3, sli:checkout_errors:ratio_rate5m)' | jq -r '.data.result[] | "\(.metric.job // "checkout")\t\(.value[1])"'
checkout	0.0417

# 2) EVENT: ¿el control plane vio algo? (ventana de 1h — corré esto YA)
$ kubectl events -n payments --types=Warning
LAST SEEN   TYPE      REASON      OBJECT                        MESSAGE
3m12s       Warning   Unhealthy   Pod/checkout-7d9f4c6b8-x2k9   Readiness probe failed: HTTP probe failed with statuscode: 503
4m01s       Warning   BackOff     Pod/checkout-7d9f4c6b8-x2k9   Back-off restarting failed container checkout
4m18s       Warning   OOMKilling  Pod/checkout-7d9f4c6b8-x2k9   Memory cgroup out of memory: Killed process 1 (java)
12m         Warning   FailedScheduling  Pod/checkout-7d9f4c6b8-nn41  0/6 nodes are available: 3 Insufficient memory.

# 3) TRACE: ¿dónde se fue el tiempo? (TraceQL contra Tempo)
$ curl -sG http://tempo-query-frontend.observability:3200/api/search \
    -H 'X-Scope-OrgID: platform' \
    --data-urlencode 'q={ resource.service.name="checkout" && status=error && duration>1s }' \
    --data-urlencode 'limit=3' | jq -r '.traces[] | "\(.traceID)  \(.durationMs)ms  \(.rootTraceName)"'
4bf92f3577b34da6a3ce929d0e0e4736  4182ms  POST /api/v1/cart
9a1c7e2b44d0518fbe0c33a17d290e55  3947ms  POST /api/v1/cart
c0ff33b4d4d0518f0e0c33a17d290e01  2210ms  POST /api/v1/cart

# 4) LOG: ¿qué dijo el proceso en ESE trace? (correlación por trace_id)
$ logcli query --addr=http://loki-gateway.observability:3100 --org-id=platform --limit=5 --since=30m \
    '{service_name="checkout"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"'
2026-08-06T09:38:41Z {service_name="checkout"} ERROR  java.lang.OutOfMemoryError: Java heap space
2026-08-06T09:38:41Z {service_name="checkout"} ERROR  at com.acme.cart.PriceEngine.recalculate(PriceEngine.java:214)
2026-08-06T09:38:40Z {service_name="checkout"} WARN   GC overhead 94% in last 60s, heap 1020M/1024M
2026-08-06T09:38:22Z {service_name="checkout"} INFO   cart.items=18400 promo_rules=7 (bulk import tenant=acme-corp)
2026-08-06T09:38:19Z {service_name="checkout"} INFO   POST /api/v1/cart tenant=acme-corp
```

Cadena causal reconstruida en cuatro comandos: un tenant importó 18.400 ítems → `PriceEngine` los recalculó en heap → OOM → `OOMKilling` → readiness 503 → error ratio fuera de SLO. **Ninguna señal sola alcanzaba; la correlación por `trace_id` y `service.name` es lo que hace la investigación posible.**

### 4.5 Validación estática antes de mergear

```console
$ promtool check rules /tmp/checkout-slo-rules.yaml
Checking /tmp/checkout-slo-rules.yaml
  SUCCESS: 13 rules found

$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
  SUCCESS: 4 rule files found
  SUCCESS: /etc/prometheus/rules/checkout-slo.yaml SUCCESS: 13 rules found

$ otelcol-contrib validate --config=/tmp/gateway-config.yaml
$ echo $?
0

$ otelcol-contrib validate --config=/tmp/broken.yaml
Error: failed to get config: cannot unmarshal the configuration: decoding failed due to the following error(s):

error decoding 'processors': unknown type: "tailsampling" for id: "tailsampling" (valid values: [attributes batch filter groupbyattrs k8sattributes memory_limiter probabilistic_sampler redaction resource resourcedetection tail_sampling transform])
$ echo $?
1

$ amtool check-config /etc/alertmanager/alertmanager.yml
Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
Found:
 - global config
 - route
 - 3 inhibit rules
 - 5 receivers
 - 1 templates
```

### 4.6 Auditoría de cardinalidad (la revisión mensual obligatoria)

```console
$ curl -s http://prometheus-operated.observability:9090/api/v1/status/tsdb | \
    jq -r '.data.seriesCountByMetricName[:6][] | "\(.value)\t\(.name)"'
482913	apiserver_request_duration_seconds_bucket
211044	container_memory_working_set_bytes
198722	http_server_request_duration_seconds_bucket
 96341	traces_spanmetrics_duration_milliseconds_bucket
 71208	kube_pod_container_resource_requests
 44190	container_network_receive_bytes_total

$ curl -s http://prometheus-operated.observability:9090/api/v1/status/tsdb | \
    jq -r '.data.labelValueCountByLabelName[:5][] | "\(.value)\t\(.name)"'
412990	id
118447	__name__
 91206	pod
 41833	http_route          # ← 41.833 rutas distintas: hay IDs sin normalizar en la ruta
  6412	uid

$ curl -sG http://prometheus-operated.observability:9090/api/v1/query \
    --data-urlencode 'query=prometheus_tsdb_head_series' | jq -r '.data.result[0].value[1]'
1743922
```

> `http_route` con 41.833 valores es un bug de instrumentación, no un problema de capacidad: alguien está poniendo el ID del recurso en la ruta. Se corrige con `replace_pattern` en el processor `transform` del gateway (§3.5) — **una vez, en la plataforma**, no en cada servicio.

### 4.7 Verificar que los Events llegan al pipeline de logs

```console
$ kubectl -n observability logs deploy/otel-cluster-collector --tail=3 | jq -r '.msg' 2>/dev/null
Everything is ready. Begin running and processing data.
Starting watch for object {events events.k8s.io}
Object watcher started

$ logcli query --addr=http://loki-gateway.observability:3100 --org-id=platform --limit=3 --since=10m \
    '{service_name="kubernetes-events"} | k8s_event_type="Warning"'
2026-08-06T09:38:44Z {service_name="kubernetes-events"} OOMKilling  payments/checkout-7d9f4c6b8-x2k9  Memory cgroup out of memory: Killed process 1 (java)
2026-08-06T09:38:52Z {service_name="kubernetes-events"} Unhealthy   payments/checkout-7d9f4c6b8-x2k9  Readiness probe failed: HTTP probe failed with statuscode: 503
2026-08-06T09:39:03Z {service_name="kubernetes-events"} BackOff     payments/checkout-7d9f4c6b8-x2k9  Back-off restarting failed container checkout
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Checklist de verificación tras cualquier cambio en el pipeline

| # | Verificación | Comando / señal | Criterio de éxito |
|---|---|---|---|
| 1 | Config válida | `otelcol-contrib validate --config=…` | exit 0 |
| 2 | Collector arriba | `curl :13133/` (health_check) | HTTP 200 |
| 3 | Recibe datos | `otelcol_receiver_accepted_spans_total` | crece monotónicamente |
| 4 | No rechaza | `otelcol_receiver_refused_*_total` | plano en 0 |
| 5 | Exporta | `otelcol_exporter_sent_*_total` | crece; `send_failed` = 0 |
| 6 | Cola sana | `queue_size / queue_capacity` | < 0.5 sostenido |
| 7 | Identidad presente | span/log/metric con `service.name` ≠ `unknown_service` | 0 series `unknown_service*` |
| 8 | Correlación viva | log con `trace_id` no vacío | > 90 % de logs de apps instrumentadas |
| 9 | Trace completo | trace de prueba con ≥ N spans esperados | sin spans huérfanos |
| 10 | Cardinalidad | `prometheus_tsdb_head_series` | delta < 10 % tras el cambio |
| 11 | Events fluyen | `{service_name="kubernetes-events"}` | eventos de los últimos 5 min |
| 12 | Alertas cargadas | `promtool check rules` + `/api/v1/rules` | estado `ok`, sin `err` |

### 5.2 Matriz de diagnóstico

| Síntoma | Señal de diagnóstico | Causa raíz típica | Remediación |
|---|---|---|---|
| Todo aparece como `unknown_service:java` | `service.name` ausente en Resource | El SDK no recibió `OTEL_SERVICE_NAME` ni `service.name` | Setear `OTEL_SERVICE_NAME` + fallback en el processor `resource/defaults` |
| Traces cortados: aparecen spans sueltos sin padre | `parent_span_id` referencia un span que no llegó | Tail sampling sin `loadbalancing` → los spans de un trace caen en réplicas distintas | Agregar `loadbalancing` con `routing_key: traceID` (§3.3) |
| Faltan traces de requests lentas justo cuando importan | `decision_wait` < duración del trace | Traces más largos que la ventana de decisión | Subir `decision_wait` por encima del p99 de duración de trace |
| `sampling_trace_dropped_too_early_total > 0` | Eviction del buffer de tail sampling | `num_traces` insuficiente para el caudal | Subir `num_traces` y memoria, o escalar réplicas del gateway |
| Collector `OOMKilled` cíclicamente | `container_memory_working_set_bytes` toca el limit | Falta `memory_limiter`, o `GOMEMLIMIT` no configurado, o `batch` demasiado grande | `memory_limiter` **primero** en cada pipeline; `GOMEMLIMIT` ≈ 80 % del limit |
| `otelcol_receiver_refused_spans_total` crece | Backpressure de `memory_limiter` | Collector subdimensionado o backend lento | Escalar réplicas; revisar latencia del backend antes de subir memoria |
| Latencia de export en aumento, cola llena | `queue_size` → `queue_capacity` | Backend saturado o red degradada | Subir `num_consumers`; investigar el backend. **Subir `queue_size` sólo esconde el problema** |
| Prometheus OOM tras un deploy | `prometheus_tsdb_head_series` salta | Cardinalidad: `pod`, `uid`, `instance` o IDs en la ruta usados como label | `metricRelabelings` drop + `transform` con `replace_pattern` |
| `up == 0` en un target | `up`, logs de Prometheus | NetworkPolicy, puerto mal nombrado, `ServiceMonitor` sin match del selector | Verificar `serviceMonitorSelector` del CR `Prometheus` y el label del SM |
| Métricas presentes pero no las scrapea nadie | Target ausente en `/targets` | Label del `ServiceMonitor` no matchea `serviceMonitorSelector` | Agregar el label `release: …` correcto |
| Logs sin `trace_id` | `trace_parser` no aplicado / SDK sin log correlation | Logs no estructurados o auto-instrumentación de logging desactivada | Activar `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED` / appender Java; `trace_parser` en filelog |
| Logs duplicados o perdidos tras restart del agent | Offsets de `filelog` no persistidos | Falta la extensión `file_storage` | Configurar `storage: file_storage/filelog` + hostPath |
| Un Event de hace 3 h no aparece en `kubectl` | TTL de eventos | `--event-ttl` del kube-apiserver (default 1 h) | Export continuo vía `k8sobjects` — **no** subir el TTL, presiona etcd |
| Cada Event aparece 3 veces | Múltiples réplicas del cluster collector | `k8sobjects`/`k8s_cluster` en Deployment con `replicas > 1` | `replicas: 1` o leader election |
| Timestamps desordenados / "log entries out of order" | Skew de reloj entre nodos | NTP/chrony desincronizado | Verificar `timedatectl`/`chronyc tracking` en los nodos |
| Exemplars no aparecen en Grafana | Prometheus sin `exemplar-storage` o SDK sin exemplar filter | Feature flag ausente | `--enable-feature=exemplar-storage` + `exemplars.enabled: true` en `spanmetrics` |
| El Collector se loguea a sí mismo en loop infinito | `filelog` incluye sus propios pods | Falta el `exclude` | `exclude: [/var/log/pods/observability_otel-agent-*_*/*/*.log]` |
| Métricas del kubelet ausentes tras un upgrade | Renombres semánticos (`k8s.pod.cpu.utilization` → `k8s.pod.cpu.usage`) | Breaking change del receiver | Leer el CHANGELOG del release; feature gates de transición |

### 5.3 Procedimiento de bisección: "faltan datos, ¿dónde se pierden?"

Recorré el pipeline **desde el emisor hacia el backend**, no al revés:

```console
# 1. ¿La app emite? — exportá a stdout temporalmente en el agent
#    (agregá 'debug' a los exporters de la pipeline sospechosa)
$ kubectl -n observability logs ds/otel-agent-collector | grep -m1 -A6 'ResourceSpans'
ResourceSpans #0
Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
Resource attributes:
     -> service.name: Str(checkout)
     -> k8s.namespace.name: Str(payments)
     -> k8s.pod.name: Str(checkout-7d9f4c6b8-x2k9)
     -> deployment.environment.name: Str(production)

# 2. ¿El agent acepta? (si accepted no crece: problema de red/SDK/endpoint)
$ kubectl -n observability exec ds/otel-agent-collector -- \
    wget -qO- localhost:8888/metrics | grep otelcol_receiver_accepted_spans_total
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 331982

# 3. ¿El agent exporta al gateway? (si send_failed crece: DNS/TLS/backpressure)
$ kubectl -n observability exec ds/otel-agent-collector -- \
    wget -qO- localhost:8888/metrics | grep -E 'send_failed_spans|queue_size'
otelcol_exporter_send_failed_spans_total{exporter="loadbalancing"} 0
otelcol_exporter_queue_size{exporter="loadbalancing"} 12

# 4. ¿El gateway descarta por política de sampling? (esperado, pero verificá el reparto)
$ kubectl -n observability exec deploy/otel-gateway-collector -- \
    wget -qO- localhost:8888/metrics | grep tail_sampling_count_traces_sampled

# 5. ¿El backend acepta? (429 = rate limit del tenant; 400 = payload inválido)
$ kubectl -n observability logs deploy/otel-gateway-collector | grep -m3 'Exporting failed'
{"level":"error","msg":"Exporting failed. Will retry the request after interval.",
 "kind":"exporter","name":"prometheusremotewrite/mimir",
 "error":"remote write returned HTTP status 429 Too Many Requests; err = %!w(<nil>): the request has been rejected because the tenant exceeded the ingestion rate limit"}
```

El punto donde el contador **deja de crecer** es el punto de pérdida. Es determinista y toma menos de dos minutos.

### 5.4 zPages: inspección en vivo sin backend

```console
$ kubectl -n observability port-forward deploy/otel-gateway-collector 55679:55679 >/dev/null 2>&1 &
$ curl -s "localhost:55679/debug/tracez" | head -20
# Muestra latency buckets y errores de los spans procesados por el propio Collector,
# útil cuando el backend está caído y hay que verificar el pipeline igual.

$ curl -s "localhost:55679/debug/pipelinez" | grep -A3 'traces'
```

### 5.5 Errores conceptuales frecuentes (nivel examen)

1. **"Los tres pilares son independientes."** No: sin `Resource` común y sin `trace_id` en los logs, no hay correlación y la investigación se vuelve manual.
2. **"Alerto sobre logs."** Los logs se alertan mal (costosos, tardíos, sin agregación). Derivá una métrica (`count` connector, `loki-ruler`, `kube-state-metrics`) y alertá sobre ella.
3. **"Los Kubernetes Events son logs."** Son objetos de la API con TTL de 1 h en etcd, sujetos a deduplicación (campos `count`/`series`). Si no se exportan, se pierden.
4. **"Subo `queue_size` y se arregla."** La cola absorbe picos, no caudal sostenido. Si crece de forma monótona, el cuello de botella está aguas abajo.
5. **"Pongo `resource_to_telemetry_conversion: true` para no perder contexto."** Convierte cada atributo de Resource (incluido `k8s.pod.name`, que rota en cada deploy) en label de métrica → explosión de cardinalidad garantizada.
6. **"Head sampling al 1 % es suficiente."** Descarta el 99 % de los errores raros, que son exactamente el objeto de estudio.
7. **"Aumento `--event-ttl` para retener Events."** Presiona etcd, que es el componente menos elástico del control plane. Exportá, no retengas.
8. **`memory_limiter` en cualquier posición.** Debe ser el **primer** processor de cada pipeline; si va después, el dato ya se materializó en memoria.

---

## 6. Referencias

**Currículum y certificación**
- CNPA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Certifications — https://www.cncf.io/training/certification/

**OpenTelemetry**
- OpenTelemetry Docs — https://opentelemetry.io/docs/
- Concepts: Signals — https://opentelemetry.io/docs/concepts/signals/
- Collector: Configuration — https://opentelemetry.io/docs/collector/configuration/
- Collector: Deployment patterns (agent / gateway) — https://opentelemetry.io/docs/collector/deployment/
- Collector: Internal telemetry y troubleshooting — https://opentelemetry.io/docs/collector/internal-telemetry/ · https://opentelemetry.io/docs/collector/troubleshooting/
- Semantic Conventions — https://opentelemetry.io/docs/specs/semconv/
- Resource semantic conventions (`service.*`, `k8s.*`) — https://opentelemetry.io/docs/specs/semconv/resource/
- Sampling (head y tail) — https://opentelemetry.io/docs/concepts/sampling/
- OTLP Specification — https://opentelemetry.io/docs/specs/otlp/
- Kubernetes Operator (CRDs `OpenTelemetryCollector`, `Instrumentation`) — https://opentelemetry.io/docs/platforms/kubernetes/operator/
- OTTL (OpenTelemetry Transformation Language) — https://pkg.go.dev/github.com/open-telemetry/opentelemetry-collector-contrib/pkg/ottl
- Collector Contrib (receivers `filelog`, `k8sobjects`, `k8s_cluster`, `kubeletstats`; processors `k8sattributes`, `tail_sampling`) — https://github.com/open-telemetry/opentelemetry-collector-contrib

**W3C**
- Trace Context (`traceparent`, `tracestate`) — https://www.w3.org/TR/trace-context/
- Baggage — https://www.w3.org/TR/baggage/

**Prometheus**
- Documentación oficial — https://prometheus.io/docs/introduction/overview/
- Best practices: naming e instrumentación — https://prometheus.io/docs/practices/naming/ · https://prometheus.io/docs/practices/instrumentation/
- Cardinalidad y "Why do I get so many time series?" — https://prometheus.io/docs/practices/naming/#labels
- Exposition formats / OpenMetrics — https://prometheus.io/docs/instrumenting/exposition_formats/
- Alerting rules y recording rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/ · https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus Operator (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`) — https://prometheus-operator.dev/docs/api-reference/api/
- kube-state-metrics — https://github.com/kubernetes/kube-state-metrics

**Kubernetes**
- Metrics for Kubernetes system components — https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Logging Architecture — https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Traces for Kubernetes System Components — https://kubernetes.io/docs/concepts/cluster-administration/system-traces/
- API Reference: Event (`events.k8s.io/v1`) — https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- kube-apiserver flags (`--event-ttl`) — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Resource Metrics Pipeline — https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/

**SRE / SLO**
- Google SRE Book — Monitoring Distributed Systems (Four Golden Signals) — https://sre.google/sre-book/monitoring-distributed-systems/
- Google SRE Workbook — Alerting on SLOs (multi-window multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/
- Google SRE Workbook — Implementing SLOs — https://sre.google/workbook/implementing-slos/

**Ecosistema CNCF y backends**
- CNCF Landscape (Observability & Analysis) — https://landscape.cncf.io/
- Jaeger — https://www.jaegertracing.io/docs/
- Fluent Bit / Fluentd — https://docs.fluentbit.io/ · https://docs.fluentd.org/
- Thanos — https://thanos.io/tip/thanos/getting-started.md/
- Cortex — https://cortexmetrics.io/docs/
- Grafana Loki (ingest OTLP) — https://grafana.com/docs/loki/latest/send-data/otel/
- Grafana Tempo (TraceQL) — https://grafana.com/docs/tempo/latest/traceql/
- Grafana Mimir (multi-tenancy, `X-Scope-OrgID`) — https://grafana.com/docs/mimir/latest/references/architecture/