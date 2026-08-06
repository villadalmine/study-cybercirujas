# Tema 2.1 — Observability Fundamentals: Traces, Metrics, Logs y Events

**Certificación:** CNPA (Cloud Native Platform Engineering Associate) — versión de currículum 2025‑04‑01
**Peso en el examen:** 4.0
**Perfil:** Principal Platform Architect / SRE Senior

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 Por qué el monitoring clásico se rompe en cloud native

En una arquitectura monolítica sobre hosts fijos, el modelo mental de operación es simple: hay N máquinas con nombre estable, un proceso por máquina, un archivo de log por proceso y un checkeo de salud por máquina. Cuando algo falla, el operador tiene una hipótesis corta: *o falló el host, o falló el proceso, o falló la base de datos*. El espacio de búsqueda es enumerable a mano.

En una plataforma Kubernetes multi-tenant ese modelo se desintegra por cuatro razones que son estructurales, no accidentales:

**a) Identidad efímera.** El Pod es la unidad de ejecución y su nombre (`checkout-7d9f8b6c4d-x2k9p`) es un identificador que vive minutos u horas. Cualquier señal indexada por hostname pierde continuidad en cada rollout. La identidad estable pasa a ser un conjunto de *labels* (`service.name`, `k8s.namespace.name`, `k8s.deployment.name`), no un nombre de máquina. Esto obliga a que la señal cargue su propia identidad semántica en origen — es exactamente el rol del `Resource` en OpenTelemetry.

**b) La causa raíz está entre los procesos, no dentro de ellos.** Una degradación de p99 en `checkout` puede originarse en un `retry storm` de `inventory` que satura el connection pool de `payments`, que a su vez está esperando un DNS lookup lento por un `ndots:5` mal configurado. Ningún dashboard por servicio muestra esa cadena. La única señal que codifica *causalidad entre procesos* es el trace distribuido.

**c) Explosión combinatoria de cardinalidad.** Una métrica `http_request_duration_seconds` con labels `method` (7) × `route` (200) × `status_code` (12) × `pod` (50) × `le` (12 buckets) genera 7 × 200 × 12 × 50 × 12 = **10.080.000 series activas** de una sola métrica. A ~3,5 KB de RAM por serie activa en el head de Prometheus, eso son ~35 GB de memoria residente. La cardinalidad no es un detalle de tuning: es el límite de diseño que define qué preguntas puede responder el sistema de métricas y cuáles hay que delegar a traces o logs.

**d) El costo de observabilidad escala más rápido que el workload.** Es habitual que el stack de observabilidad consuma entre 10 % y 30 % del presupuesto de cómputo de la plataforma. En cloud native ese costo lo genera el equipo de aplicación (agregando un label, subiendo el nivel de log) pero lo paga el equipo de plataforma. Sin un contrato explícito, el sistema converge a la ruina.

### 1.2 El framing de Platform Engineering: observability como *capability*, no como herramienta

El error clásico es tratar la observabilidad como "instalar Prometheus y Grafana". Desde la perspectiva de plataforma —que es la que evalúa CNPA— la observabilidad es una **capability del Internal Developer Platform** con un contrato de dos lados:

| El equipo de plataforma provee | El equipo de aplicación aporta |
|---|---|
| Pipeline de ingesta OTLP con endpoint estable en el cluster | Emitir OTLP o exponer `/metrics` en formato Prometheus |
| Enriquecimiento automático con metadata de Kubernetes | Declarar `service.name` y `service.version` correctos |
| Golden signals + dashboards + alertas por defecto (paved road) | Respetar semantic conventions de OpenTelemetry |
| Auto-instrumentación sin cambios de código (`Instrumentation` CR) | Propagar el contexto en trabajos asíncronos y colas |
| Retención, multi-tenancy, cuotas y control de cardinalidad | Mantenerse dentro del presupuesto de series/GB asignado |
| Correlación cruzada (exemplars, `trace_id` en logs) | No usar identificadores de alta cardinalidad como label |

La consecuencia de diseño es que la instrumentación debe ser **vendor-neutral en el borde de la aplicación**. Si el SDK que corre dentro del container es el de un vendor específico, migrar de backend implica un cambio de código en cientos de repositorios. Por eso OpenTelemetry —el segundo proyecto CNCF por velocidad después de Kubernetes— define un límite arquitectónico: la app habla **OTLP**, y el punto de decisión de a dónde van los datos es el **Collector**, que es infraestructura de plataforma.

```
┌────────────────────────────────────────────────────────────────────┐
│  Dominio de la aplicación (equipo de producto)                     │
│                                                                    │
│   [App + OTel SDK] ──OTLP/gRPC──┐    [App + /metrics] ──scrape──┐   │
│   [App auto-instr.] ──OTLP──────┤                              │   │
│   [stdout] ─────► /var/log/pods ┤                              │   │
└─────────────────────────────────┼──────────────────────────────┼───┘
                                  │                              │
┌─────────────────────────────────▼──────────────────────────────▼───┐
│  Dominio de la plataforma                                          │
│                                                                    │
│   Agent (DaemonSet)          Gateway (Deployment, HPA)             │
│   ├ filelog receiver         ├ otlp receiver                       │
│   ├ hostmetrics              ├ k8sobjects (Events)                 │
│   ├ k8sattributes ──────────►├ tail_sampling ──► routing por traceID│
│   └ otlp exporter            ├ transform / filter (cost control)   │
│                              └ exporters: OTLP / PRW / Loki        │
└────────────────────────────────────────────────────────────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
        Prometheus/Mimir       Tempo/Jaeger        Loki/ES
        (metrics)              (traces)            (logs+events)
```

### 1.3 La falacia de los "tres pilares"

La formulación popular —"logs, metrics y traces son los tres pilares de la observabilidad"— es pedagógicamente útil y arquitectónicamente peligrosa. Induce a construir **tres silos verticales**: tres agentes, tres backends, tres UIs, tres esquemas de metadata que no se cruzan. El resultado operativo es que durante un incidente el SRE hace *context switching* manual entre tres pestañas y reconstruye la correlación a ojo.

La formulación correcta es: hay **una sola señal telemétrica, observada en distintas resoluciones**, unificada por un `Resource` común y un `trace_id` común. La propiedad que define observabilidad no es "tener las tres" sino **poder navegar de una a otra sin salir del contexto**:

- Métrica con alto p99 → **exemplar** → trace específico que muestra ese p99.
- Span del trace → filtro `trace_id` → **logs** exactos de esa request.
- Todo lo anterior → `k8s.pod.name` → **Events** de Kubernetes de ese Pod (¿fue OOMKilled? ¿fue evicted? ¿falló el probe?).

Y a esto se suma la cuarta señal, que el currículum de CNPA nombra explícitamente y que la mayoría de los stacks ignora: los **Events** del control plane, que son la telemetría de la *plataforma misma* y no de la aplicación.

---

## 2. Las cuatro señales: modelo de datos y comparativa técnica

### 2.1 Tabla comparativa maestra

| Dimensión | **Metrics** | **Traces** | **Logs** | **Events (Kubernetes)** |
|---|---|---|---|---|
| Pregunta que responde | ¿Está roto? ¿Cuánto? ¿Desde cuándo? | ¿Dónde y por qué se rompió esta request? | ¿Qué pasó exactamente en este proceso? | ¿Qué le hizo el control plane a este objeto? |
| Unidad atómica | Sample: `(name, labels, ts, float64)` | Span: `(trace_id, span_id, parent, t0, t1, attrs)` | Record: `(ts, severity, body, attrs)` | Event: `(reason, action, note, regarding, series)` |
| Estructura temporal | Serie continua, regular | DAG por request | Discreta, irregular | Discreta, con agregación por series |
| Costo ∝ | Nº de series activas (cardinalidad) | Nº de spans × (1 − sampling) | Volumen en bytes | Tasa de cambio del cluster |
| Cardinalidad tolerada | **Baja** (≤ 10⁵–10⁶ series/tenant) | **Ilimitada** (atributos arbitrarios) | Alta (si no se indexa todo) | Media |
| Agregable a priori | Sí (es su razón de ser) | No (se pierde la causalidad) | Parcial (extracción a métricas) | Sí (campo `series.count`) |
| Retención típica | 13–15 meses (downsampled) | 3–15 días | 7–30 días | **1 hora en etcd** ⚠️ |
| Latencia señal→alerta | 15–60 s | 1–5 min (por `decision_wait`) | 10–60 s | 5–30 s |
| Apto para SLO/alerting | **Sí, es el único apto** | No (muestreado ⇒ sesgado) | Solo vía log→metric | No (best-effort, se pierden) |
| Determinismo de entrega | Pull: gap detectable (`up==0`) | Best-effort, sampling | Best-effort, puede haber drops | **Best-effort explícito, se descartan** |
| Protocolo dominante | Prometheus exposition / OpenMetrics / OTLP | OTLP, W3C Trace Context | OTLP logs, syslog, JSON lines | Kubernetes API (watch) |
| Backends CNCF | Prometheus, Thanos, Mimir, Cortex | Jaeger, Tempo, Zipkin | Loki, OpenSearch, Fluentd→X | API server / k8sobjects receiver |
| Uso primario en incidente | **Detección** | **Localización** | **Diagnóstico de causa** | **Contexto de plataforma** |

> **Regla de decisión operativa:** una dimensión de datos va a *metrics* si su cardinalidad está acotada y necesitás alertar sobre ella; va a *traces* si es de alta cardinalidad y necesitás correlacionarla con una request; va a *logs* si es texto no estructurado o volumen que solo se lee después de saber dónde mirar.

### 2.2 Metrics: modelo de datos y las trampas del tipado

Una serie temporal en el modelo de Prometheus es un par `(conjunto de labels, secuencia de (timestamp, float64))`. El nombre de la métrica no es especial: es el label reservado `__name__`. Por lo tanto:

```
series_totales = Σ_metrica ∏_label cardinalidad(label)
```

**Tipos y su semántica interna:**

| Tipo | Semántica | Reset handling | Función de consulta | Trampa habitual |
|---|---|---|---|---|
| `Counter` | Monótono creciente | `rate()` detecta resets | `rate()`, `increase()` | Usar `sum()` sin `rate()` — no significa nada tras un restart |
| `Gauge` | Valor instantáneo arbitrario | N/A | `avg`, `max`, `delta()` | Promediar gauges entre pods oculta el pico de uno |
| `Histogram` | Buckets acumulativos `le` + `_sum` + `_count` | Igual que counter | `histogram_quantile()` | El cuantil se interpola linealmente **dentro** del bucket: si el bucket es `[1, +Inf]`, el p99 es basura |
| `Summary` | Cuantiles precalculados en el cliente | N/A | Solo lectura directa | **No es agregable entre instancias**: no existe promedio de p99 |
| `Native histogram` | Buckets exponenciales auto-ajustados | Igual que counter | `histogram_quantile()` | Requiere `--enable-feature=native-histograms`; no todos los backends lo soportan |

El *native histogram* (Prometheus ≥ 2.40, experimental) es la respuesta directa al problema de cardinalidad de los histogramas clásicos: en lugar de N series (una por bucket `le`), es **una sola serie** con un esquema de buckets exponenciales de resolución configurable. Reduce el costo de un histograma de latencia de ~12–20 series a 1, lo que hace viable instrumentar por ruta HTTP.

**Pull vs push — el trade-off que define la topología:**

| Criterio | Pull (Prometheus scrape) | Push (OTLP, Remote Write, StatsD) |
|---|---|---|
| Detección de caída del target | Nativa: `up == 0` | Requiere heartbeat sintético |
| Service discovery | Necesario (Kubernetes SD) | No necesario, la app conoce el endpoint |
| Jobs efímeros (< intervalo de scrape) | **Falla**: requiere Pushgateway | Nativo |
| Control de sobrecarga del backend | El backend controla el ritmo | El cliente puede saturar; requiere backpressure |
| Redes con NAT / egress-only | Difícil | Natural |
| Temporalidad de datos | Cumulative | Delta o Cumulative (configurable) |
| Debug manual | Trivial (`curl` al `/metrics`) | Requiere inspeccionar el pipeline |

Una plataforma madura soporta **ambos**: scrape para workloads long-running (vía `ServiceMonitor`/`PodMonitor` o el `prometheus` receiver del Collector) y push OTLP para jobs, funciones y lenguajes con SDK OTel.

**Temporality — la incompatibilidad silenciosa:** OTLP soporta `CUMULATIVE` y `DELTA`. Prometheus solo entiende cumulative. Si un SDK exporta delta (default de las métricas del SDK .NET y de algunos exporters) y se envía a `prometheusremotewrite` sin conversión, los counters aparecen con valores absurdos. La solución es el `cumulativetodelta` / `deltatocumulative` processor en el Collector, o configurar el SDK con `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`.

### 2.3 Traces: causalidad distribuida y propagación de contexto

Un **trace** es un DAG de **spans**. Cada span lleva:

- `trace_id`: 16 bytes (32 hex), constante en todo el trace.
- `span_id`: 8 bytes (16 hex), único por span.
- `parent_span_id`: enlaza al padre; vacío ⇒ root span.
- `name`, `kind` (`SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER`, `INTERNAL`), `start_time`, `end_time`.
- `attributes`: alta cardinalidad permitida (`user.id`, `order.id`, `db.statement`).
- `events`: puntos en el tiempo dentro del span (ej. `exception`).
- `links`: relación causal no jerárquica (fan-in de batch, fan-out de cola).
- `status`: `UNSET` / `OK` / `ERROR`.

La propagación entre procesos usa **W3C Trace Context** (recomendación W3C, es el default de OTel):

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^^ ^------------ trace-id ---------^ ^--span-id---^ ^^
             |                                                   └ trace-flags (01 = sampled)
             └ version
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

`tracestate` es el canal para metadata específica de vendor; `baggage` (header separado) propaga pares clave-valor de negocio a todo el trace — con la advertencia de seguridad de que **baggage cruza límites de confianza**: nunca poner datos sensibles ahí.

**Sampling — el trade-off central de traces:**

| Estrategia | Dónde decide | Ventaja | Desventaja | Cuándo usarla |
|---|---|---|---|---|
| **Head-based, probabilístico** (`parentbased_traceidratio`) | En el root span, antes de generar los datos | Costo mínimo y predecible; sin estado | Descarta errores raros y outliers de latencia | Volumen muy alto, presupuesto fijo |
| **Head-based, always_on** | En el SDK | Trace completo garantizado | Costo lineal con el tráfico | Dev, staging, servicios de bajo QPS |
| **Tail-based** (`tail_sampling` processor) | En el Collector, tras ver el trace completo | Retiene 100 % de errores y colas de latencia | Requiere **buffer en memoria** y que todos los spans lleguen al mismo Collector | Producción; es el estándar de facto |
| **Remote / adaptive** (Jaeger) | Backend empuja la tasa al SDK | Auto-ajuste por endpoint | Complejidad operativa | Flotas grandes y heterogéneas |

⚠️ **La restricción de arquitectura más importante de tail sampling:** la decisión requiere tener *todos* los spans de un `trace_id` en la misma instancia. Con un Deployment de N réplicas detrás de un Service, los spans se reparten por round-robin y cada réplica ve un trace parcial ⇒ decisiones incoherentes y traces truncados. La solución obligatoria es una **capa de dos niveles**: un tier de Collectors con `loadbalancing` exporter y `routing_key: traceID` que hace hashing consistente hacia un segundo tier que corre `tail_sampling`.

### 2.4 Logs: de texto a señal estructurada

El log es la señal más antigua y la peor gobernada. En cloud native su ciclo de vida es:

1. El proceso escribe a **stdout/stderr** (regla del 12-factor; escribir a archivo dentro del container rompe la rotación y llena el `emptyDir`).
2. El container runtime (containerd/CRI-O) escribe en formato **CRI** a `/var/log/pods/<ns>_<pod>_<uid>/<container>/0.log`:
   ```
   2026-08-06T14:22:31.918273645Z stdout F {"level":"error","msg":"pool exhausted"}
   ```
   Los campos son: timestamp RFC3339Nano, stream, flag (`F` = full, `P` = partial/línea fragmentada a 16 KB), body.
3. Un agente en DaemonSet (`filelog` receiver del OTel Collector, Fluent Bit, Vector) sigue esos archivos, reensambla las líneas `P`, parsea y enriquece.
4. El backend indexa. Loki indexa **solo labels** y comprime el body — modelo de costo radicalmente distinto a Elasticsearch, que indexa todo el contenido.

**El fragmento `P` es una fuente clásica de bugs:** kubelet parte las líneas en 16 KB. Un stack trace de Java de 40 KB llega como 3 registros; si el agente no hace *multiline recombine*, el backend recibe JSON inválido y el log se pierde o se indexa como basura.

**Trade-off de estructuración:**

| Enfoque | Costo de ingesta | Consultabilidad | Costo de migración |
|---|---|---|---|
| Texto plano + regex en el agente | Bajo en la app, alto en el agente | Frágil: cambia el formato, se rompe el parser | Alto |
| JSON estructurado en la app | ~20–30 % más bytes | Alta, sin parsing | Bajo |
| OTLP logs desde el SDK | Igual a JSON, pero con `Resource` y `trace_id` nativos | Máxima: correlación automática | Mínimo |

**La regla de oro de correlación:** todo log emitido dentro de un span activo debe incluir `trace_id` y `span_id`. Los SDKs de OTel lo inyectan automáticamente vía los *log appenders* (Logback MDC en Java, `structlog` en Python, `slog` handler en Go). Sin esto, logs y traces son silos y la señal pierde la mitad de su valor.

### 2.5 Events: la telemetría del control plane

Este es el punto que los stacks de observabilidad tradicionales omiten y que el currículum de CNPA remarca. Un **Event de Kubernetes** no es un log de aplicación: es un objeto de la API que un controlador emite para describir un cambio de estado de otro objeto.

Existen dos APIs coexistentes:

| Campo | `v1` (core, legacy) | `events.k8s.io/v1` (moderno) |
|---|---|---|
| Objeto afectado | `involvedObject` | `regarding` |
| Objeto secundario | `related` | `related` |
| Texto | `message` | `note` (máx. 1024 caracteres) |
| Emisor | `source.component` / `source.host` | `reportingController` / `reportingInstance` |
| Primer registro | `firstTimestamp` | `eventTime` |
| Deduplicación | `count`, `lastTimestamp` | `series.count`, `series.lastObservedTime` |
| Verbo semántico | — | `action` |
| Clasificación | `type`: `Normal` \| `Warning` | igual |
| Motivo (enum-ish) | `reason` | `reason` |

**Propiedades operativas críticas — y la razón por la que Events NO son una fuente de verdad:**

1. **TTL de 1 hora.** El kube-apiserver arranca con `--event-ttl=1h0m0s` por defecto y los borra de etcd al vencer. Un incidente investigado 90 minutos después ya no tiene Events. **Consecuencia de diseño: los Events deben exportarse fuera del cluster de forma continua.**
2. **Rate limiting agresivo en el cliente.** `client-go` (`EventCorrelator`) aplica por clave de evento un token bucket de **QPS = 1/300 s con burst 25**. El evento número 26 del mismo tipo en 5 minutos simplemente se descarta y nunca llega a la API.
3. **Agregación.** Hasta 10 eventos similares en una ventana de 10 minutos se colapsan en uno con el sufijo `(combined from similar events)`.
4. **Entrega best-effort.** Si el apiserver está sobrecargado, el emisor descarta el evento; no hay reintento garantizado.
5. **No están ordenados de forma fiable** por `lastTimestamp` en la salida por defecto de `kubectl get events`.

Por eso: **nunca alertes directamente sobre la presencia de un Event**. Alertá sobre la métrica derivada (`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` de kube-state-metrics), y usá el Event como *contexto narrativo* durante la investigación.

**Reasons que todo SRE debe reconocer de inmediato:**

| `reason` | Emisor | Significado | Señal correlacionada |
|---|---|---|---|
| `FailedScheduling` | `default-scheduler` | Ningún nodo satisface requests/taints/affinity | `kube_pod_status_unschedulable` |
| `OOMKilling` / `Killing` | `kubelet` | cgroup superó `memory.limit` | `container_memory_working_set_bytes` vs limit |
| `BackOff` | `kubelet` | CrashLoopBackOff, backoff exponencial hasta 5 min | `kube_pod_container_status_restarts_total` |
| `Unhealthy` | `kubelet` | Falló liveness/readiness probe | `probe_success`, latencia p99 |
| `FailedMount` / `FailedAttachVolume` | `kubelet` / `attachdetach` | CSI no pudo montar el PV | Logs del CSI driver |
| `Evicted` | `kubelet` | Node pressure (disk/memory/pid) | `kubelet_evictions_total` |
| `NodeNotReady` | `node-controller` | Kubelet dejó de reportar heartbeat | `kube_node_status_condition` |
| `FailedCreatePodSandBox` | `kubelet` | Falla de CNI o del runtime | Logs de containerd + CNI |
| `SuccessfulRescale` | `horizontal-pod-autoscaler` | HPA cambió réplicas | `kube_hpa_status_desired_replicas` |
| `Preempting` | `default-scheduler` | Priority class desalojó a otro Pod | `kube_pod_status_reason` |

---

## 3. Manifiestos completos de infraestructura

Todo lo que sigue es un pipeline coherente y desplegable. El namespace es `observability`.

### 3.1 Namespace y RBAC del Collector

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    app.kubernetes.io/part-of: platform-observability
    pod-security.kubernetes.io/enforce: privileged   # el agente monta hostPath de logs
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector
rules:
  # k8sattributes processor: enriquecer telemetría con metadata del Pod
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets", "deployments", "daemonsets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  # k8sobjects receiver: capturar Events del control plane
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  # k8sclusterreceiver: métricas de estado del cluster
  - apiGroups: [""]
    resources: ["resourcequotas", "persistentvolumes", "persistentvolumeclaims",
                "replicationcontrollers", "replicationcontrollers/status"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
  # prometheus receiver con kubernetes_sd_configs
  - nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["nodes/metrics", "nodes/proxy", "nodes/stats"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: observability
```

### 3.2 Agent tier — DaemonSet (logs de nodo, hostmetrics, enriquecimiento)

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      # ---------- Traces y métricas OTLP desde las apps del mismo nodo ----------
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            max_recv_msg_size_mib: 16
          http:
            endpoint: 0.0.0.0:4318

      # ---------- Logs de containers en formato CRI ----------
      filelog:
        include: [ /var/log/pods/*/*/*.log ]
        exclude:
          - /var/log/pods/observability_otel-agent-*_*/*/*.log   # evitar bucle de feedback
        start_at: end
        include_file_path: true
        include_file_name: false
        poll_interval: 500ms
        fingerprint_size: 1kb
        max_log_size: 2MiB
        operators:
          # Parsea el formato CRI y reensambla líneas partidas (flag P)
          - type: container
            id: container-parser
            format: auto
            add_metadata_from_filepath: true
          # Intenta parsear el body como JSON estructurado; si falla, lo deja como texto
          - type: json_parser
            id: json-body
            if: 'body matches "^\\s*[{\\[]"'
            parse_from: body
            parse_to: attributes
            on_error: send_quiet
          # Normaliza severidad
          - type: severity_parser
            id: sev
            if: 'attributes["level"] != nil'
            parse_from: attributes.level
            on_error: send_quiet
            mapping:
              debug: [ debug, DEBUG, trace, TRACE ]
              info:  [ info, INFO, notice ]
              warn:  [ warn, WARN, warning, WARNING ]
              error: [ error, ERROR, err, eror ]
              fatal: [ fatal, FATAL, panic, critical, CRITICAL ]
          # Correlación log <-> trace
          - type: trace_parser
            id: trace-ctx
            if: 'attributes["trace_id"] != nil'
            trace_id:
              parse_from: attributes.trace_id
            span_id:
              parse_from: attributes.span_id

      # ---------- Métricas del host ----------
      hostmetrics:
        collection_interval: 30s
        root_path: /hostfs
        scrapers:
          cpu:
            metrics:
              system.cpu.utilization:
                enabled: true
          memory:
            metrics:
              system.memory.utilization:
                enabled: true
          load: {}
          disk: {}
          filesystem:
            exclude_mount_points:
              mount_points: [ "/var/lib/kubelet/*", "/proc/*", "/sys/*" ]
              match_type: regexp
          network: {}

      # ---------- cAdvisor y kubelet ----------
      kubeletstats:
        collection_interval: 30s
        auth_type: serviceAccount
        endpoint: "https://${env:K8S_NODE_NAME}:10250"
        insecure_skip_verify: true
        metric_groups: [ container, pod, node, volume ]
        extra_metadata_labels: [ container.id, k8s.volume.type ]

    processors:
      # Guardarraíl obligatorio: sin esto el Collector muere por OOM bajo pico
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20

      # Enriquecimiento con metadata de Kubernetes
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          node_from_env_var: K8S_NODE_NAME     # solo mira Pods de este nodo: menos RAM
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.pod.start_time
            - k8s.deployment.name
            - k8s.statefulset.name
            - k8s.daemonset.name
            - k8s.cronjob.name
            - k8s.job.name
            - k8s.node.name
            - k8s.container.name
            - container.image.name
            - container.image.tag
          labels:
            - tag_name: service.name
              key: app.kubernetes.io/name
              from: pod
            - tag_name: service.version
              key: app.kubernetes.io/version
              from: pod
            - tag_name: platform.tenant
              key: platform.internal/tenant
              from: namespace
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection

      resourcedetection:
        detectors: [ env, system, k8snode ]
        timeout: 5s
        override: false
        system:
          hostname_sources: [ os ]

      # Identidad del cluster, inyectada por la plataforma
      resource:
        attributes:
          - key: k8s.cluster.name
            value: ${env:CLUSTER_NAME}
            action: upsert
          - key: deployment.environment
            value: ${env:ENVIRONMENT}
            action: upsert

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 5s

    exporters:
      otlp/gateway:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls:
          insecure: true
        compression: zstd
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 5000
          storage: file_storage/otlp     # persistencia de la cola en disco
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      pprof:
        endpoint: 127.0.0.1:1777
      file_storage/otlp:
        directory: /var/lib/otelcol/queue
        timeout: 10s

    service:
      extensions: [ health_check, pprof, file_storage/otlp ]
      telemetry:
        logs:
          level: info
          encoding: json
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers:  [ otlp ]
          processors: [ memory_limiter, k8sattributes, resourcedetection, resource, batch ]
          exporters:  [ otlp/gateway ]
        metrics:
          receivers:  [ otlp, hostmetrics, kubeletstats ]
          processors: [ memory_limiter, k8sattributes, resourcedetection, resource, batch ]
          exporters:  [ otlp/gateway ]
        logs:
          receivers:  [ otlp, filelog ]
          processors: [ memory_limiter, k8sattributes, resourcedetection, resource, batch ]
          exporters:  [ otlp/gateway ]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-agent
    app.kubernetes.io/component: agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-agent
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-agent
        app.kubernetes.io/component: agent
      annotations:
        # Forzar rollout cuando cambia el ConfigMap
        checksum/config: "REPLACE_WITH_SHA256_OF_CONFIGMAP"
    spec:
      serviceAccountName: otel-collector
      priorityClassName: system-node-critical
      hostNetwork: false
      dnsPolicy: ClusterFirst
      terminationGracePeriodSeconds: 60
      tolerations:
        - operator: Exists          # correr en todos los nodos, incluidos control plane
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.128.0
          imagePullPolicy: IfNotPresent
          args: [ "--config=/conf/config.yaml" ]
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: K8S_POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: CLUSTER_NAME
              value: "prod-eu-west-1"
            - name: ENVIRONMENT
              value: "production"
            - name: GOMEMLIMIT
              value: "800MiB"        # ~80% del limit: evita OOM del GC de Go
          ports:
            - name: otlp-grpc
              containerPort: 4317
              protocol: TCP
            - name: otlp-http
              containerPort: 4318
              protocol: TCP
            - name: metrics
              containerPort: 8888
              protocol: TCP
            - name: health
              containerPort: 13133
              protocol: TCP
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              memory: 1Gi           # sin CPU limit: evita throttling en picos de log
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            runAsUser: 0            # necesario para leer /var/log/pods
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ "ALL" ]
          volumeMounts:
            - name: config
              mountPath: /conf
              readOnly: true
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: hostfs
              mountPath: /hostfs
              readOnly: true
              mountPropagation: HostToContainer
            - name: queue
              mountPath: /var/lib/otelcol/queue
      volumes:
        - name: config
          configMap:
            name: otel-agent-config
            items:
              - key: config.yaml
                path: config.yaml
        - name: varlogpods
          hostPath:
            path: /var/log/pods
            type: Directory
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
            type: DirectoryOrCreate
        - name: hostfs
          hostPath:
            path: /
            type: Directory
        - name: queue
          hostPath:
            path: /var/lib/otelcol/queue
            type: DirectoryOrCreate
```

### 3.3 Gateway tier — Deployment con tail sampling, Events y control de costo

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            max_recv_msg_size_mib: 32
            keepalive:
              server_parameters:
                max_connection_age: 120s        # fuerza rebalanceo de conexiones gRPC
                max_connection_age_grace: 30s
          http:
            endpoint: 0.0.0.0:4318

      # ---------- Events del control plane como logs OTLP ----------
      # NOTA: el receiver `k8s_events` está deprecado; `k8sobjects` es el sucesor.
      k8sobjects:
        auth_type: serviceAccount
        objects:
          - name: events
            mode: watch
            group: events.k8s.io
            # exclude_watch_type: [ "DELETED" ]
          - name: pods
            mode: pull
            interval: 5m
            label_selector: "platform.internal/observed=true"

      # ---------- Estado agregado del cluster ----------
      k8s_cluster:
        auth_type: serviceAccount
        collection_interval: 30s
        node_conditions_to_report: [ Ready, MemoryPressure, DiskPressure, PIDPressure ]
        allocatable_types_to_report: [ cpu, memory, ephemeral-storage, pods ]

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 15

      # ---------- Decisión de sampling con el trace completo a la vista ----------
      tail_sampling:
        decision_wait: 15s          # buffer: debe superar la duración p99 de los traces
        num_traces: 200000
        expected_new_traces_per_sec: 2000
        policies:
          - name: keep-all-errors
            type: status_code
            status_code:
              status_codes: [ ERROR ]
          - name: keep-slow-traces
            type: latency
            latency:
              threshold_ms: 1000
          - name: keep-http-5xx
            type: numeric_attribute
            numeric_attribute:
              key: http.response.status_code
              min_value: 500
              max_value: 599
          - name: keep-critical-tenants
            type: string_attribute
            string_attribute:
              key: platform.tenant
              values: [ "payments", "identity" ]
              enabled_regex_matching: false
          - name: drop-health-checks
            type: and
            and:
              and_sub_policy:
                - name: is-health-endpoint
                  type: string_attribute
                  string_attribute:
                    key: url.path
                    values: [ "/healthz", "/readyz", "/livez", "/metrics" ]
                - name: never-keep
                  type: probabilistic
                  probabilistic:
                    sampling_percentage: 0
          - name: baseline-sample
            type: probabilistic
            probabilistic:
              sampling_percentage: 5

      # ---------- Derivar métricas RED desde los spans (no muestreadas) ----------
      # (requiere el connector spanmetrics declarado más abajo)

      # ---------- Control de cardinalidad y de costo ----------
      transform/cardinality:
        error_mode: ignore
        metric_statements:
          - context: datapoint
            statements:
              # Elimina labels de alta cardinalidad conocidos
              - delete_key(attributes, "http.request.header.x_request_id")
              - delete_key(attributes, "k8s.pod.uid")
              # Normaliza rutas con IDs: /orders/9f2a-... -> /orders/{id}
              - replace_pattern(attributes["http.route"], "/[0-9a-fA-F-]{8,}", "/{id}")
              - replace_pattern(attributes["http.route"], "/[0-9]{3,}", "/{id}")

      filter/drop-noisy-metrics:
        error_mode: ignore
        metrics:
          metric:
            - 'IsMatch(name, "^go_gc_duration_seconds.*")'
            - 'IsMatch(name, "^promhttp_.*")'

      # Normaliza Events de Kubernetes hacia atributos consultables
      transform/k8s-events:
        error_mode: ignore
        log_statements:
          - context: log
            conditions:
              - 'resource.attributes["k8s.resource.name"] == "events"'
            statements:
              - set(severity_text, "WARN")     where body["type"] == "Warning"
              - set(severity_number, SEVERITY_NUMBER_WARN) where body["type"] == "Warning"
              - set(attributes["k8s.event.reason"],  body["reason"])
              - set(attributes["k8s.event.action"],  body["action"])
              - set(attributes["k8s.event.count"],   body["deprecatedCount"])
              - set(attributes["k8s.object.kind"],   body["regarding"]["kind"])
              - set(attributes["k8s.object.name"],   body["regarding"]["name"])
              - set(attributes["k8s.namespace.name"], body["regarding"]["namespace"])

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 10s

    connectors:
      # Genera métricas RED a partir de TODOS los spans, antes del sampling
      spanmetrics:
        histogram:
          explicit:
            buckets: [ 2ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s ]
        dimensions:
          - name: http.request.method
          - name: http.route
          - name: http.response.status_code
          - name: k8s.namespace.name
          - name: platform.tenant
        exemplars:
          enabled: true            # habilita el salto métrica -> trace
        metrics_flush_interval: 30s
        namespace: traces.span.metrics

    exporters:
      otlphttp/tempo:
        endpoint: http://tempo-distributor.observability.svc.cluster.local:4318
        compression: zstd
        sending_queue:
          enabled: true
          num_consumers: 20
          queue_size: 10000
        retry_on_failure:
          enabled: true
          max_elapsed_time: 300s

      prometheusremotewrite/mimir:
        endpoint: http://mimir-nginx.observability.svc.cluster.local/api/v1/push
        headers:
          X-Scope-OrgID: platform
        target_info:
          enabled: true
        add_metric_suffixes: true
        resource_to_telemetry_conversion:
          enabled: false           # true convierte TODO resource attr en label: bomba de cardinalidad
        remote_write_queue:
          enabled: true
          queue_size: 100000
          num_consumers: 10

      otlphttp/loki:
        endpoint: http://loki-gateway.observability.svc.cluster.local/otlp
        headers:
          X-Scope-OrgID: platform
        compression: gzip

      debug:
        verbosity: basic
        sampling_initial: 5
        sampling_thereafter: 200

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 127.0.0.1:55679

    service:
      extensions: [ health_check, zpages ]
      telemetry:
        logs:
          level: info
          encoding: json
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers:  [ otlp ]
          processors: [ memory_limiter, transform/cardinality, batch ]
          exporters:  [ spanmetrics, tail_sampling_forward ]
        # Segundo hop interno: spanmetrics ve el 100%, tail_sampling decide qué persiste
        traces/sampled:
          receivers:  [ otlp ]
          processors: [ memory_limiter, tail_sampling, batch ]
          exporters:  [ otlphttp/tempo ]
        metrics:
          receivers:  [ otlp, k8s_cluster, spanmetrics ]
          processors: [ memory_limiter, transform/cardinality, filter/drop-noisy-metrics, batch ]
          exporters:  [ prometheusremotewrite/mimir ]
        logs:
          receivers:  [ otlp, k8sobjects ]
          processors: [ memory_limiter, transform/k8s-events, batch ]
          exporters:  [ otlphttp/loki ]
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-gateway
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: otel-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
      appProtocol: grpc
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
    - name: metrics
      port: 8888
      targetPort: 8888
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-gateway
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-gateway
    spec:
      serviceAccountName: otel-collector
      terminationGracePeriodSeconds: 90     # drenar la cola antes de morir
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: otel-gateway
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.128.0
          args: [ "--config=/conf/config.yaml" ]
          env:
            - name: GOMEMLIMIT
              value: "3200MiB"
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: health,    containerPort: 13133 }
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              memory: 4Gi
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 20
            periodSeconds: 20
          readinessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: config
              mountPath: /conf
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: otel-gateway-config
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: otel-gateway
  namespace: observability
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: otel-gateway
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: otelcol_exporter_queue_size
        target:
          type: AverageValue
          averageValue: "3000"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: otel-gateway
  namespace: observability
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-gateway
```

> **Nota arquitectónica sobre el tail sampling:** el manifiesto anterior usa dos pipelines de traces sobre el mismo receiver para que `spanmetrics` vea el 100 % de los spans. En un cluster real con más de una réplica de gateway hay que interponer un **tier de load balancing** entre agente y gateway, porque `tail_sampling` requiere afinidad por `trace_id`.

### 3.4 Tier de load balancing por trace_id (requisito de tail sampling)

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-lb-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20

    exporters:
      loadbalancing:
        routing_key: traceID          # hashing consistente: todo el trace al mismo backend
        protocol:
          otlp:
            timeout: 10s
            tls:
              insecure: true
            sending_queue:
              enabled: true
              queue_size: 10000
        resolver:
          k8s:
            service: otel-gateway-headless.observability
            ports: [ 4317 ]
            timeout: 5s

    service:
      telemetry:
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers:  [ otlp ]
          processors: [ memory_limiter ]
          exporters:  [ loadbalancing ]
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway-headless
  namespace: observability
spec:
  clusterIP: None                     # headless: el resolver k8s necesita las IPs de los Pods
  selector:
    app.kubernetes.io/name: otel-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
```

### 3.5 Auto-instrumentación sin tocar código (OpenTelemetry Operator)

```yaml
---
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: platform-default
  namespace: observability
spec:
  exporter:
    endpoint: http://otel-agent.observability.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
    - b3multi            # compatibilidad con servicios legacy instrumentados con Zipkin
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"      # head sampling al 100%: la decisión real la toma el tail_sampling
  resource:
    addK8sUIDAttributes: true
  env:
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: http/protobuf
    - name: OTEL_METRICS_EXPORTER
      value: otlp
    - name: OTEL_LOGS_EXPORTER
      value: otlp
    - name: OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE
      value: cumulative                       # obligatorio si el destino final es Prometheus
    - name: OTEL_SEMCONV_STABILITY_OPT_IN
      value: http                             # semantic conventions HTTP estables (1.x)
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.15.0
    resources:
      requests: { cpu: 50m,  memory: 128Mi }
      limits:   { memory: 256Mi }
    env:
      - name: OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_LOG_ATTRIBUTES
        value: "true"
      - name: OTEL_INSTRUMENTATION_JDBC_DATASOURCE_ENABLED
        value: "true"
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.55b0
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.60.0
  dotnet:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-dotnet:1.12.0
  go:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-go:0.22.0
---
# Consumo desde el Deployment de la aplicación
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: "3.14.2"
spec:
  replicas: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "3.14.2"
      annotations:
        instrumentation.opentelemetry.io/inject-java: "observability/platform-default"
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: checkout
          image: registry.internal/shop/checkout:3.14.2
          ports:
            - { name: http,    containerPort: 8080 }
            - { name: metrics, containerPort: 9090 }
          env:
            # El Operator inyecta OTEL_SERVICE_NAME, pero declararlo explícito es más robusto
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,deployment.environment=production"
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { memory: 1Gi }
```

### 3.6 Scraping declarativo y reglas de SLO

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: checkout
  namespace: shop
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      honorLabels: false
      relabelings:
        - sourceLabels: [ __meta_kubernetes_pod_node_name ]
          targetLabel: node
        - sourceLabels: [ __meta_kubernetes_namespace ]
          targetLabel: namespace
      metricRelabelings:
        # Guardarraíl de cardinalidad: descartar métricas conocidas por ser caras
        - sourceLabels: [ __name__ ]
          regex: 'jvm_buffer_pool_.*|process_start_time_seconds'
          action: drop
        # Normalizar rutas con IDs
        - sourceLabels: [ path ]
          regex: '(/orders/)[0-9a-f-]+'
          targetLabel: path
          replacement: '${1}{id}'
  # Límites duros: el target se marca down si los excede, en lugar de tumbar Prometheus
  sampleLimit: 5000
  labelLimit: 30
  labelNameLengthLimit: 100
  labelValueLengthLimit: 300
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: checkout-slo
  namespace: shop
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    # ---------- Recording rules: precalcular las ventanas de burn rate ----------
    - name: checkout.sli.recording
      interval: 30s
      rules:
        - record: sli:checkout_requests:rate5m
          expr: sum(rate(http_server_request_duration_seconds_count{job="shop/checkout"}[5m]))
        - record: sli:checkout_errors:rate5m
          expr: |
            sum(rate(http_server_request_duration_seconds_count{
              job="shop/checkout", http_response_status_code=~"5.."}[5m]))
        - record: sli:checkout_error_ratio:5m
          expr: sli:checkout_errors:rate5m / clamp_min(sli:checkout_requests:rate5m, 1e-9)
        - record: sli:checkout_error_ratio:1h
          expr: |
            sum(rate(http_server_request_duration_seconds_count{
              job="shop/checkout", http_response_status_code=~"5.."}[1h]))
            / clamp_min(sum(rate(http_server_request_duration_seconds_count{job="shop/checkout"}[1h])), 1e-9)
        - record: sli:checkout_error_ratio:6h
          expr: |
            sum(rate(http_server_request_duration_seconds_count{
              job="shop/checkout", http_response_status_code=~"5.."}[6h]))
            / clamp_min(sum(rate(http_server_request_duration_seconds_count{job="shop/checkout"}[6h])), 1e-9)
        - record: sli:checkout_error_ratio:3d
          expr: |
            sum(rate(http_server_request_duration_seconds_count{
              job="shop/checkout", http_response_status_code=~"5.."}[3d]))
            / clamp_min(sum(rate(http_server_request_duration_seconds_count{job="shop/checkout"}[3d])), 1e-9)
        - record: sli:checkout_latency_p99:5m
          expr: |
            histogram_quantile(0.99, sum by (le) (
              rate(http_server_request_duration_seconds_bucket{job="shop/checkout"}[5m])))

    # ---------- Alertas multi-ventana / multi-burn-rate (Google SRE Workbook) ----------
    # SLO de disponibilidad: 99.9% => error budget = 0.001
    - name: checkout.slo.alerts
      rules:
        - alert: CheckoutErrorBudgetBurnFast
          # 14.4x => consume el 2% del budget mensual en 1 hora
          expr: |
            sli:checkout_error_ratio:1h > (14.4 * 0.001)
            and
            sli:checkout_error_ratio:5m > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            slo: checkout-availability
            page: "true"
          annotations:
            summary: "checkout quema el error budget 14.4x más rápido de lo sostenible"
            description: >-
              Ratio de error 1h={{ $value | humanizePercentage }}.
              A este ritmo el budget mensual se agota en ~2 días.
            runbook_url: "https://runbooks.internal/slo/checkout-availability"

        - alert: CheckoutErrorBudgetBurnSlow
          # 6x => consume el 5% del budget en 6 horas
          expr: |
            sli:checkout_error_ratio:6h > (6 * 0.001)
            and
            sli:checkout_error_ratio:1h > (6 * 0.001)
          for: 15m
          labels:
            severity: warning
            slo: checkout-availability
          annotations:
            summary: "Degradación sostenida de checkout (burn rate 6x)"
            runbook_url: "https://runbooks.internal/slo/checkout-availability"

    # ---------- Salud del propio pipeline de observabilidad (meta-monitoring) ----------
    - name: observability.pipeline.health
      rules:
        - alert: OtelCollectorRefusingData
          expr: |
            sum by (pod, receiver) (
              rate(otelcol_receiver_refused_spans_total[5m])
              + rate(otelcol_receiver_refused_metric_points_total[5m])
              + rate(otelcol_receiver_refused_log_records_total[5m])
            ) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "El Collector {{ $labels.pod }} está rechazando telemetría"
            description: "Casi siempre es memory_limiter aplicando backpressure. Escalar o subir el limit."

        - alert: OtelCollectorExportFailing
          expr: |
            sum by (pod, exporter) (rate(otelcol_exporter_send_failed_spans_total[5m])) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Fallo de export hacia {{ $labels.exporter }} — se está perdiendo telemetría"

        - alert: OtelCollectorQueueNearFull
          expr: |
            otelcol_exporter_queue_size / clamp_min(otelcol_exporter_queue_capacity, 1) > 0.8
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Cola del exporter al {{ $value | humanizePercentage }} — riesgo de drop"

        - alert: PrometheusTargetDown
          expr: up == 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Target {{ $labels.job }}/{{ $labels.instance }} caído"

        - alert: PrometheusCardinalityExplosion
          expr: |
            prometheus_tsdb_head_series > 8e6
            or
            deriv(prometheus_tsdb_head_series[1h]) > 5000
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Explosión de cardinalidad: {{ $value }} series activas"
            runbook_url: "https://runbooks.internal/observability/cardinality"
```

---

## 4. Comandos CLI y verificación en terminal

### 4.1 Validar la configuración antes de aplicarla

```
$ docker run --rm -v "$PWD/config.yaml:/conf/config.yaml" \
    otel/opentelemetry-collector-contrib:0.128.0 validate --config=/conf/config.yaml
```
```
$
```
*(salida vacía y exit code 0 = configuración válida). Con un error tipográfico:*

```
$ docker run --rm -v "$PWD/broken.yaml:/conf/config.yaml" \
    otel/opentelemetry-collector-contrib:0.128.0 validate --config=/conf/config.yaml
```
```
Error: failed to get config: cannot unmarshal the configuration: decoding failed due to
the following error(s):

error decoding 'processors': unknown type: "tail_samplng" for id: "tail_samplng"
(valid values: [attributes batch cumulativetodelta filter groupbyattrs k8sattributes
memory_limiter metricstransform probabilistic_sampler redaction resource
resourcedetection span tail_sampling transform ...])
2026/08/06 14:03:11 collector server run finished with error: failed to get config
$ echo $?
1
```

### 4.2 Verificar que los Pods de observabilidad están sanos

```
$ kubectl -n observability get pods -o wide
NAME                            READY   STATUS    RESTARTS      AGE   IP            NODE
otel-agent-4tzq9                1/1     Running   0             3h    10.42.1.17    ip-10-0-1-23
otel-agent-8kd2m                1/1     Running   0             3h    10.42.2.31    ip-10-0-2-88
otel-agent-p9wxr                1/1     Running   1 (2h ago)    3h    10.42.3.44    ip-10-0-3-11
otel-gateway-6c9d84f7b5-h2vmn   1/1     Running   0             47m   10.42.1.53    ip-10-0-1-23
otel-gateway-6c9d84f7b5-q7ktz   1/1     Running   0             47m   10.42.2.61    ip-10-0-2-88
otel-gateway-6c9d84f7b5-x4nlp   1/1     Running   0             47m   10.42.3.72    ip-10-0-3-11
tempo-distributor-79f5d6c4-bkwq2 1/1    Running   0             6h    10.42.2.19    ip-10-0-2-88
```

El `RESTARTS 1` en `otel-agent-p9wxr` es la primera pista a seguir:

```
$ kubectl -n observability describe pod otel-agent-p9wxr | sed -n '/Last State/,/Events/p'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Thu, 06 Aug 2026 11:41:02 +0000
      Finished:     Thu, 06 Aug 2026 12:18:44 +0000
    Ready:          True
    Restart Count:  1
    Limits:
      memory:  1Gi
    Requests:
      cpu:     200m
      memory:  512Mi
```

### 4.3 Inspeccionar la telemetría interna del Collector

Las métricas internas son la fuente de verdad sobre si el pipeline está perdiendo datos.

```
$ kubectl -n observability port-forward svc/otel-gateway 8888:8888 >/dev/null 2>&1 &
$ curl -s localhost:8888/metrics | grep -E '^otelcol_(receiver|processor|exporter)' | sort
```
```
otelcol_exporter_queue_capacity{exporter="otlphttp/tempo",...} 10000
otelcol_exporter_queue_size{exporter="otlphttp/tempo",...} 143
otelcol_exporter_send_failed_spans_total{exporter="otlphttp/tempo",...} 0
otelcol_exporter_sent_log_records_total{exporter="otlphttp/loki",...} 4.81233e+06
otelcol_exporter_sent_metric_points_total{exporter="prometheusremotewrite/mimir",...} 2.293441e+07
otelcol_exporter_sent_spans_total{exporter="otlphttp/tempo",...} 1.284117e+06
otelcol_processor_batch_batch_send_size_count{processor="batch",...} 3211
otelcol_processor_dropped_spans_total{processor="memory_limiter",...} 0
otelcol_receiver_accepted_log_records_total{receiver="k8sobjects",transport="",...} 18422
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc",...} 2.4106e+07
otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc",...} 0
```

**La ecuación de conservación que hay que verificar siempre:**

```
receiver_accepted − processor_dropped − exporter_send_failed ≈ exporter_sent + queue_size
```

Cualquier desbalance persistente es pérdida silenciosa de telemetría. En el ejemplo: `24.106.000` spans aceptados frente a `1.284.117` exportados ⇒ ratio de retención ≈ 5,3 %, consistente con la política de tail sampling configurada (5 % baseline + errores + lentos). Si el número estuviera cerca de 0, el sampling estaría mal configurado.

Métricas específicas del tail sampling:

```
$ curl -s localhost:8888/metrics | grep -E 'tail_sampling'
```
```
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-all-errors",sampled="true"} 24112
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-slow-traces",sampled="true"} 8901
otelcol_processor_tail_sampling_count_traces_sampled{policy="baseline-sample",sampled="true"} 61204
otelcol_processor_tail_sampling_count_traces_sampled{policy="drop-health-checks",sampled="false"} 891422
otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total 0
otelcol_processor_tail_sampling_new_trace_id_received_total 1284117
otelcol_processor_tail_sampling_sampling_traces_on_memory 41209
otelcol_processor_tail_sampling_sampling_decision_latency_bucket{le="50000"} 39877
```

> `sampling_trace_dropped_too_early_total > 0` significa que `decision_wait` es menor que la duración real de los traces: se están tomando decisiones sobre traces incompletos. Hay que subir `decision_wait` por encima del p99 de duración de trace.

### 4.4 Enviar telemetría de prueba end-to-end

```
$ kubectl -n observability run otel-probe --rm -it --restart=Never \
    --image=ghcr.io/equinix-labs/otel-cli:latest -- \
    span --endpoint http://otel-gateway:4318 --protocol http/protobuf \
         --service smoke-test --name synthetic-check --verbose
```
```
# trace id: 8f4c1d2e9a7b3f60c5e8d1a2b4f7c093
#  span id: 3a1f9c7d2e5b8046
# parent  :
# endpoint: http://otel-gateway:4318
# protocol: http/protobuf
# elapsed : 3.117ms
# status  : OK (200)
pod "otel-probe" deleted
```

Y verificar que llegó al backend:

```
$ kubectl -n observability exec -it deploy/grafana -- \
    curl -s "http://tempo-query-frontend:3100/api/traces/8f4c1d2e9a7b3f60c5e8d1a2b4f7c093" \
    | jq '.batches[0].scopeSpans[0].spans[0] | {name, traceId, spanId, startTimeUnixNano}'
```
```json
{
  "name": "synthetic-check",
  "traceId": "j0wdLpp7P2DF6NGitPfAkw==",
  "spanId": "Oh+cfS5bgEY=",
  "startTimeUnixNano": "1780582991918273645"
}
```

### 4.5 Verificar el scrape de métricas

```
$ kubectl -n shop exec -it deploy/checkout -c checkout -- \
    curl -s localhost:9090/metrics | grep -A3 'http_server_request_duration_seconds_bucket' | head -20
```
```
# HELP http_server_request_duration_seconds Duration of HTTP server requests
# TYPE http_server_request_duration_seconds histogram
http_server_request_duration_seconds_bucket{http_request_method="POST",http_route="/checkout",http_response_status_code="200",le="0.005"} 0
http_server_request_duration_seconds_bucket{http_request_method="POST",http_route="/checkout",http_response_status_code="200",le="0.01"} 12
http_server_request_duration_seconds_bucket{http_request_method="POST",http_route="/checkout",http_response_status_code="200",le="0.025"} 891
http_server_request_duration_seconds_bucket{http_request_method="POST",http_route="/checkout",http_response_status_code="200",le="0.05"} 4102 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 0.042 1780582991.918
```

La última línea, tras el `#`, es un **exemplar** en formato OpenMetrics: es literalmente el puente entre la métrica y el trace. Requiere que Prometheus corra con `--enable-feature=exemplar-storage` y que el scrape negocie `application/openmetrics-text`.

Estado del target desde el punto de vista de Prometheus:

```
$ kubectl -n observability exec -it sts/prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
    | jq -r '.data.activeTargets[] | select(.labels.job=="shop/checkout")
             | [.scrapeUrl, .health, .lastScrapeDuration, .lastError] | @tsv'
```
```
http://10.42.1.53:9090/metrics	up	0.041	
http://10.42.2.61:9090/metrics	up	0.038	
http://10.42.3.72:9090/metrics	down	10.001	Get "http://10.42.3.72:9090/metrics": context deadline exceeded
http://10.42.1.90:9090/metrics	down	0.212	sample limit exceeded (5000)
```

Las dos causas más frecuentes de `down`, ambas visibles aquí: timeout de scrape (el endpoint tarda más que `scrapeTimeout`) y `sampleLimit` excedido — este último es el guardarraíl de cardinalidad funcionando como se diseñó.

### 4.6 Consultar cardinalidad y encontrar al culpable

```
$ kubectl -n observability exec -it sts/prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/status/tsdb' \
    | jq -r '.data.seriesCountByMetricName[:8][] | "\(.value)\t\(.name)"'
```
```
2841902	http_server_request_duration_seconds_bucket
1102338	grpc_server_handled_total
 884211	container_memory_working_set_bytes
 421904	kafka_consumer_lag
 318772	jvm_gc_collection_seconds_bucket
 210441	http_client_request_duration_seconds_bucket
 118002	kube_pod_labels
  91230	node_cpu_seconds_total
```

```
$ kubectl -n observability exec -it sts/prometheus-...-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/status/tsdb' \
    | jq -r '.data.labelValueCountByLabelName[:6][] | "\(.value)\t\(.name)"'
```
```
 48211	http_route
 31007	pod
 12904	container_id
  9822	le
  4110	instance
   882	namespace
```

`http_route` con 48.211 valores distintos es el diagnóstico: hay IDs sin normalizar en las rutas (`/orders/9f2a-4b1c-...`). Ese es exactamente el caso que resuelve el `metricRelabelings` con `replace` del `PodMonitor`, o el `transform/cardinality` del Collector.

Consulta directa de cardinalidad por serie:

```
$ promtool query instant http://localhost:9090 \
    'topk(5, count by (__name__) ({__name__=~".+"}))'
```
```
count by(__name__) {__name__="http_server_request_duration_seconds_bucket"} => 2841902 @[1780582991.918]
count by(__name__) {__name__="grpc_server_handled_total"} => 1102338 @[1780582991.918]
count by(__name__) {__name__="container_memory_working_set_bytes"} => 884211 @[1780582991.918]
count by(__name__) {__name__="kafka_consumer_lag"} => 421904 @[1780582991.918]
count by(__name__) {__name__="jvm_gc_collection_seconds_bucket"} => 318772 @[1780582991.918]
```

### 4.7 Trabajar con Events de Kubernetes

```
$ kubectl get events -n shop --sort-by='.lastTimestamp' \
    -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.kind/.involvedObject.name,MSG:.message'
```
```
TIME                   TYPE      REASON              OBJ                              MSG
2026-08-06T14:11:02Z   Normal    Scheduled           Pod/checkout-7d9f8b6c4d-x2k9p    Successfully assigned shop/checkout-7d9f8b6c4d-x2k9p to ip-10-0-2-88
2026-08-06T14:11:04Z   Normal    Pulled              Pod/checkout-7d9f8b6c4d-x2k9p    Container image "registry.internal/shop/checkout:3.14.2" already present on machine
2026-08-06T14:11:05Z   Normal    Created             Pod/checkout-7d9f8b6c4d-x2k9p    Created container: checkout
2026-08-06T14:11:05Z   Normal    Started             Pod/checkout-7d9f8b6c4d-x2k9p    Started container checkout
2026-08-06T14:13:41Z   Warning   Unhealthy           Pod/checkout-7d9f8b6c4d-x2k9p    Readiness probe failed: HTTP probe failed with statuscode: 503
2026-08-06T14:14:22Z   Warning   BackOff             Pod/checkout-7d9f8b6c4d-x2k9p    Back-off restarting failed container checkout in pod checkout-7d9f8b6c4d-x2k9p_shop(...)
2026-08-06T14:15:00Z   Warning   FailedScheduling    Pod/checkout-7d9f8b6c4d-m4p2v    0/6 nodes are available: 3 Insufficient memory, 2 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 1 Insufficient cpu. preemption: 0/6 nodes are available: 6 No preemption victims found for incoming pod.
```

Solo los `Warning`, con seguimiento en vivo:

```
$ kubectl get events -A --field-selector type=Warning --watch
```
```
NAMESPACE   LAST SEEN   TYPE      REASON              OBJECT                                MESSAGE
shop        23s         Warning   Unhealthy           pod/checkout-7d9f8b6c4d-x2k9p         Readiness probe failed: HTTP probe failed with statuscode: 503
platform    5s          Warning   FailedMount         pod/artifact-cache-0                  Unable to attach or mount volumes: unmounted volumes=[data], unattached volumes=[], failed to process volumes=[]: timed out waiting for the condition
shop        2s          Warning   OOMKilling          pod/inventory-5f8c9d7b6-k3nqz         Memory cgroup out of memory: Killed process 1 (java) total-vm:8412332kB, anon-rss:2097152kB
```

La nueva API con más contexto:

```
$ kubectl get events.events.k8s.io -n shop -o yaml | head -40
```
```yaml
apiVersion: v1
items:
- action: Binding
  apiVersion: events.k8s.io/v1
  deprecatedCount: 1
  deprecatedFirstTimestamp: "2026-08-06T14:11:02Z"
  deprecatedLastTimestamp: "2026-08-06T14:11:02Z"
  eventTime: "2026-08-06T14:11:02.418273Z"
  kind: Event
  metadata:
    creationTimestamp: "2026-08-06T14:11:02Z"
    name: checkout-7d9f8b6c4d-x2k9p.1859f2a4c1e73b90
    namespace: shop
    resourceVersion: "48211903"
    uid: 4b1c9f2a-7d3e-4a80-b512-9c3f1e8d2a04
  note: Successfully assigned shop/checkout-7d9f8b6c4d-x2k9p to ip-10-0-2-88
  reason: Scheduled
  regarding:
    apiVersion: v1
    kind: Pod
    name: checkout-7d9f8b6c4d-x2k9p
    namespace: shop
    uid: 9f2a4b1c-3e7d-40a8-b125-1e8d2a04c3f9
  reportingController: default-scheduler
  reportingInstance: default-scheduler-ip-10-0-0-10
  type: Normal
```

Confirmar el TTL configurado en el apiserver:

```
$ kubectl -n kube-system get pod kube-apiserver-ip-10-0-0-10 \
    -o jsonpath='{.spec.containers[0].command}' | tr ' ' '\n' | grep -i event
```
```
--event-ttl=1h0m0s
```

Y confirmar que el Collector está exportando esos Events antes de que expiren:

```
$ kubectl -n observability logs deploy/otel-gateway --tail=3 | jq -r 'select(.kind=="k8sobjects")'
```
```json
{"level":"debug","ts":"2026-08-06T14:15:01.442Z","msg":"received object","kind":"k8sobjects","resource":"events","group":"events.k8s.io","count":42}
```

### 4.8 Recorrer la correlación completa durante un incidente

```
# 1) La alerta dispara sobre una métrica
$ promtool query instant http://localhost:9090 'sli:checkout_error_ratio:5m'
```
```
sli:checkout_error_ratio:5m{} => 0.0412 @[1780582991.918]
```
```
# 2) Obtener un exemplar: un trace_id concreto que representa ese error
$ curl -sG http://localhost:9090/api/v1/query_exemplars \
    --data-urlencode 'query=http_server_request_duration_seconds_bucket{job="shop/checkout"}' \
    --data-urlencode 'start=2026-08-06T14:10:00Z' \
    --data-urlencode 'end=2026-08-06T14:20:00Z' | jq -r '.data[0].exemplars[0]'
```
```json
{
  "labels": { "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736", "span_id": "00f067aa0ba902b7" },
  "value": "2.418",
  "timestamp": 1780582991.918
}
```
```
# 3) Traer el trace y ver dónde se fue el tiempo
$ curl -s "http://tempo-query-frontend:3100/api/traces/4bf92f3577b34da6a3ce929d0e0e4736" \
  | jq -r '.batches[].scopeSpans[].spans[]
           | "\(.name)\t\((.endTimeUnixNano|tonumber - (.startTimeUnixNano|tonumber))/1e6)ms\t\(.status.code // 0)"'
```
```
POST /checkout            2418.11ms   0
inventory.Reserve         2311.42ms   2
  postgres.query           2298.03ms   2
payments.Authorize          88.14ms   0
```
```
# 4) Buscar los logs exactos de ese trace
$ logcli query --limit=10 --since=30m \
    '{namespace="shop"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"'
```
```
2026-08-06T14:15:11Z {namespace="shop", pod="inventory-5f8c9d7b6-k3nqz"} {"level":"error","msg":"connection pool exhausted after 2.29s","pool.size":20,"pool.waiting":142,"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"a1b2c3d4e5f60718"}
```
```
# 5) Cerrar con el contexto de plataforma
$ kubectl get events -n shop --field-selector involvedObject.name=inventory-5f8c9d7b6-k3nqz
```
```
LAST SEEN   TYPE      REASON       OBJECT                              MESSAGE
6m          Warning   OOMKilling   pod/inventory-5f8c9d7b6-k3nqz       Memory cgroup out of memory: Killed process 1 (java)
6m          Normal    Killing      pod/inventory-5f8c9d7b6-k3nqz       Stopping container inventory
5m          Warning   BackOff      pod/inventory-5f8c9d7b6-k3nqz       Back-off restarting failed container
```

**Cadena causal reconstruida en cinco comandos:** métrica (detección) → exemplar (puente) → trace (localización: la latencia está en `postgres.query` dentro de `inventory`) → log (causa: pool agotado con 142 esperando) → Event (contexto: el Pod fue OOMKilled y en el reinicio el pool arrancó frío). Ninguna señal aislada da esta respuesta; la propiedad emergente es la **correlación**.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Checklist de verificación del pipeline (en orden estricto)

| # | Verificación | Comando | Resultado esperado |
|---|---|---|---|
| 1 | Config sintácticamente válida | `otelcol validate --config=...` | exit 0, sin salida |
| 2 | Pods Ready y sin restarts | `kubectl -n observability get pods` | `1/1 Running 0` |
| 3 | Health check activo | `curl -s :13133/` | `{"status":"Server available"}` |
| 4 | Receivers aceptando datos | `otelcol_receiver_accepted_*_total` | creciendo monótonamente |
| 5 | Cero rechazos | `otelcol_receiver_refused_*_total` | constante en 0 |
| 6 | Cero fallos de export | `otelcol_exporter_send_failed_*_total` | constante en 0 |
| 7 | Cola estable | `otelcol_exporter_queue_size` | oscilando, no creciendo |
| 8 | Ecuación de conservación | accepted − dropped ≈ sent + queue | desvío < 1 % |
| 9 | Telemetría en el backend | consulta por `service.name` | resultados no vacíos |
| 10 | Metadata de K8s presente | inspeccionar `k8s.pod.name` en el span | atributo poblado |
| 11 | Correlación operativa | exemplar → trace → log | los tres resuelven |
| 12 | Cardinalidad bajo control | `/api/v1/status/tsdb` | sin métrica dominante inesperada |

### 5.2 Matriz de fallas: síntoma → causa → verificación → remedio

| Síntoma | Causa más probable | Comando de verificación | Remedio |
|---|---|---|---|
| No llega **ninguna** telemetría de un servicio | `OTEL_EXPORTER_OTLP_ENDPOINT` mal configurado o NetworkPolicy bloqueando | `kubectl exec <pod> -- env \| grep OTEL`; `kubectl exec <pod> -- nc -zv otel-agent 4317` | Corregir endpoint; abrir egress a `observability/4317-4318` |
| Traces **parciales**: aparece el frontend, no el backend | Contexto no propagado: cliente HTTP no instrumentado, cola sin inyectar `traceparent`, thread pool custom | Inspeccionar headers: `kubectl exec -- curl -v` sobre el hop; buscar spans sin `parent_span_id` que no deberían ser root | Instrumentar el cliente; propagar manualmente en productores/consumidores de cola |
| Traces **truncados** de forma aleatoria | Múltiples réplicas de gateway con `tail_sampling` sin load balancing por `traceID` | `otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total > 0` | Insertar el tier `loadbalancing` con `routing_key: traceID` |
| Faltan solo los traces **lentos** | `decision_wait` < duración del trace | Comparar `decision_wait` con el p99 de `traces.span.metrics.duration` | Subir `decision_wait` (p99 + margen) |
| `otelcol_receiver_refused_*` > 0 | `memory_limiter` aplicando backpressure | `container_memory_working_set_bytes` vs `limits.memory`; logs con `"Memory usage is above soft limit"` | Escalar réplicas, subir `limits.memory`, ajustar `GOMEMLIMIT` a ~80 % del limit |
| Collector en `CrashLoopBackOff` con exit 137 | OOMKill: `GOMEMLIMIT` ausente o mayor que `limits.memory` | `kubectl describe pod \| grep -A3 'Last State'` | Fijar `GOMEMLIMIT` ≈ 80 % del limit; habilitar `memory_limiter` |
| `otelcol_exporter_queue_size` creciendo sin techo | El backend no absorbe el ritmo, o hay throttling 429 | `otelcol_exporter_send_failed_*`; logs con `"429 Too Many Requests"` | Escalar el backend; subir `queue_size` solo como paliativo; activar `file_storage` para no perder en el reinicio |
| Métricas presentes pero **sin labels de Kubernetes** | `k8sattributes` sin RBAC, o `pod_association` fallando | `kubectl auth can-i list pods --as=system:serviceaccount:observability:otel-collector`; logs con `"could not identify pod"` | Aplicar el ClusterRole; agregar `from: connection` a `pod_association`; usar `passthrough: false` en el gateway |
| Counter con valores absurdos / negativos en Prometheus | Mismatch de temporality: el SDK exporta `delta`, Prometheus asume `cumulative` | `curl` al endpoint OTLP debug; revisar `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | Fijar `cumulative` en el SDK, o insertar `deltatocumulative` en el pipeline |
| Prometheus consumiendo memoria sin control | Explosión de cardinalidad | `/api/v1/status/tsdb`; `prometheus_tsdb_head_series` | `metricRelabelings` con `drop`/`replace`; `sampleLimit` en el ServiceMonitor; considerar native histograms |
| Target en `down` con `sample limit exceeded` | El guardarraíl de cardinalidad se activó | `/api/v1/targets` campo `lastError` | Reducir cardinalidad en origen — **no** subir el límite sin analizar |
| `histogram_quantile` devuelve `NaN` o un valor absurdo | Todas las observaciones caen en el bucket `+Inf`, o se agregó sin `by (le)` | `rate(...bucket[5m])` y mirar la distribución por `le` | Rediseñar los buckets según la latencia real; siempre `sum by (le) (rate(...))` |
| Logs sin `trace_id` | El appender de logs no está integrado con el contexto de OTel | Inspeccionar un registro crudo: `kubectl logs <pod> \| head -1` | Habilitar el log appender del SDK; o `trace_parser` operator en `filelog` |
| Stack traces partidos en varios registros | Líneas > 16 KB partidas por kubelet (flag `P`) sin recombinar | `grep ' P ' /var/log/pods/.../0.log` | Usar el operator `container` (recombina nativamente) o `recombine` explícito |
| Logs duplicados masivamente | El agente re-lee archivos por cambio de fingerprint, o hay un bucle de feedback | `otelcol_receiver_accepted_log_records_total` con un salto escalonado | Subir `fingerprint_size`; **excluir los logs del propio agente** del `include` |
| Events faltantes en el backend | TTL de 1 h ya venció, o rate limiting de `client-go` descartó | `kubectl get events` vacío pero el Pod muestra restarts | Exportar Events continuamente; **no depender de Events para alertar** |
| `FailedScheduling` sin Events visibles | Se superó el burst de 25 por clave en 5 min | `kubectl describe pod` (muestra el estado, no solo eventos) | Usar `kube_pod_status_unschedulable` de kube-state-metrics |
| Métricas de spans no coinciden con el conteo de traces | `spanmetrics` colocado después del sampling | Revisar el orden del pipeline | `spanmetrics` **antes** de `tail_sampling`, siempre |

### 5.3 Los cinco antipatrones que cuestan más caro

1. **Labels de alta cardinalidad en métricas.** `user_id`, `request_id`, `session_id`, `email`, `pod_uid`, timestamps o cualquier UUID como label. Cada valor distinto es una serie nueva y permanente en el head del TSDB. *Regla:* si el conjunto de valores no está acotado y no lo podés enumerar de antemano, **es un atributo de span o de log, nunca un label de métrica**.

2. **Sampling de traces al 100 % en producción sin tail sampling.** El costo escala linealmente con el tráfico y el 99 % de lo almacenado son traces exitosos y aburridos. Con `tail_sampling` se retiene el 100 % de lo que importa (errores, cola de latencia, tenants críticos) al 3–7 % del costo.

3. **Alertar sobre logs o sobre Events.** Ambos son best-effort: se pierden bajo carga, que es exactamente el momento en que la alerta debería dispararse. Alertá sobre métricas, siempre. Los logs y los Events son para el diagnóstico posterior.

4. **`resource_to_telemetry_conversion: enabled: true` en el `prometheusremotewrite` exporter.** Convierte *todos* los resource attributes en labels de Prometheus — incluidos `k8s.pod.uid`, `container.id` y `host.id`, que son unbounded. Es la forma más rápida de tumbar un Prometheus.

5. **No monitorear el sistema de monitoreo.** Sin meta-monitoring, un Collector que descarta el 40 % de los spans es indistinguible de un sistema sano: los dashboards muestran datos, solo que menos. Las alertas del grupo `observability.pipeline.health` de §3.6 no son opcionales.

### 5.4 Modelo de costo por señal (orden de magnitud, para dimensionar)

| Señal | Driver de costo | Palanca de reducción | Impacto típico |
|---|---|---|---|
| Metrics | series activas × retención | drop de métricas no usadas | 30–50 % |
| Metrics | cardinalidad de labels | normalización de rutas, `metricRelabelings` | 60–90 % |
| Metrics | resolución de histogramas | native histograms | 90 % del costo del histograma |
| Traces | spans/s × (1 − sampling) | tail sampling con políticas | 90–97 % |
| Traces | atributos por span | límites de longitud y cantidad | 10–20 % |
| Logs | GB ingeridos × retención | filtrar `DEBUG` en el Collector | 40–70 % |
| Logs | labels indexados (Loki) | mantener < 15 labels de baja cardinalidad | 50 %+ y evita OOM del ingester |
| Events | tasa de cambio del cluster | filtrar `type=Normal` de bajo valor | 60–80 % |

---

## 6. Referencias

**Currículum y certificación**
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Curriculum repository: https://github.com/cncf/curriculum
- Certified Cloud Native Platform Engineering Associate (CNPA): https://training.linuxfoundation.org/certification/certified-cloud-native-platform-engineering-associate-cnpa/

**OpenTelemetry**
- Documentación oficial: https://opentelemetry.io/docs/
- Concepts — Signals: https://opentelemetry.io/docs/concepts/signals/
- Traces: https://opentelemetry.io/docs/concepts/signals/traces/
- Metrics: https://opentelemetry.io/docs/concepts/signals/metrics/
- Logs: https://opentelemetry.io/docs/concepts/signals/logs/
- Context Propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- Sampling: https://opentelemetry.io/docs/concepts/sampling/
- Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
- Collector — Configuration: https://opentelemetry.io/docs/collector/configuration/
- Collector — Deployment patterns: https://opentelemetry.io/docs/collector/deployment/
- Collector — Internal telemetry: https://opentelemetry.io/docs/collector/internal-telemetry/
- Collector — Scaling: https://opentelemetry.io/docs/collector/scaling/
- OTLP Specification: https://opentelemetry.io/docs/specs/otlp/
- Kubernetes Operator: https://opentelemetry.io/docs/platforms/kubernetes/operator/
- Auto-instrumentation injection: https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/
- Collector Contrib (receivers/processors/exporters): https://github.com/open-telemetry/opentelemetry-collector-contrib
- `tailsamplingprocessor`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- `k8sattributesprocessor`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- `k8sobjectsreceiver`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/k8sobjectsreceiver
- `filelogreceiver`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
- `loadbalancingexporter`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- `spanmetricsconnector`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector

**W3C**
- Trace Context (W3C Recommendation): https://www.w3.org/TR/trace-context/
- Baggage: https://www.w3.org/TR/baggage/

**Prometheus / OpenMetrics**
- Data model: https://prometheus.io/docs/concepts/data_model/
- Metric types: https://prometheus.io/docs/concepts/metric_types/
- Naming best practices: https://prometheus.io/docs/practices/naming/
- Instrumentation practices: https://prometheus.io/docs/practices/instrumentation/
- Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Exemplars: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- Kubernetes service discovery: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config
- Prometheus Operator API: https://prometheus-operator.dev/docs/api-reference/api/
- OpenMetrics specification: https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md

**Kubernetes**
- Logging Architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Metrics for Kubernetes system components: https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Traces for Kubernetes system components: https://kubernetes.io/docs/concepts/cluster-administration/system-traces/
- Event API (`events.k8s.io/v1`): https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- kube-apiserver flags (`--event-ttl`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- kube-state-metrics: https://github.com/kubernetes/kube-state-metrics/tree/main/docs

**CNCF Backends**
- Jaeger: https://www.jaegertracing.io/docs/latest/
- Grafana Tempo: https://grafana.com/docs/tempo/latest/
- Grafana Loki: https://grafana.com/docs/loki/latest/
- Grafana Mimir: https://grafana.com/docs/mimir/latest/
- Fluent Bit: https://docs.fluentbit.io/manual
- CNCF Observability Whitepaper: https://github.com/cncf/tag-observability/blob/main/whitepaper.md

**SRE**
- Google SRE Workbook — Alerting on SLOs: https://sre.google/workbook/alerting-on-slos/
- Google SRE Book — Monitoring Distributed Systems: https://sre.google/sre-book/monitoring-distributed-systems/
- Dapper (paper original de tracing distribuido): https://research.google/pubs/pub36356/