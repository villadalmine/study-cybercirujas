# 704.4 — Tracing

**LPI DevOps Tools Engineer — Exam 701-100, v2.0.0**
**Weight: 3.33**

---

## 1. El problema arquitectónico

### 1.1 Por qué las métricas y los logs dejan de funcionar a partir de cierta escala

Un monolito falla en un solo lugar, así que un stack trace es una explicación causal completa. Un sistema distribuido no falla en un solo lugar: falla *entre* lugares. Una vez que una única acción de usuario se abre en abanico hacia una docena de procesos, tres lenguajes, un message broker y dos bases de datos gestionadas, las tres señales clásicas de telemetría se degradan de maneras específicas y predecibles:

- **Las métricas** están preagregadas. `http_request_duration_seconds{service="checkout"}` te dice que el p99 es 4,2 s. No puede decirte *cuál* es ese 1% de requests, *por qué* fueron lentos, ni *qué salto downstream* consumió el tiempo. La agregación es lossy por construcción, y lo que se pierde es exactamente la información que necesitás durante un incidente.
- **Los logs** son por proceso y no están ordenados entre procesos. Podés hacer grep de `checkout`, podés hacer grep de `payments`, pero coser los dos requiere un identificador de correlación que alguien tiene que propagar — y si de todos modos vas a propagar un identificador, ya reinventaste el tracing, mal.
- **Ninguno responde la pregunta de causalidad**: *para este request específico, qué pasó, en qué orden, en qué máquinas, y adónde se fue realmente la latencia?*

El distributed tracing es la señal diseñada para esa pregunta. La unidad de análisis no es el proceso, es el **request**.

### 1.2 Los tres modos de falla en producción para los que está construido el tracing

| Modo de falla | Qué muestran las métricas | Qué muestran los logs | Qué muestra un trace |
|---|---|---|---|
| **Tail latency** (p99 es 4 s, p50 es 40 ms) | Un número, sin atribución | Nada — los requests lentos normalmente tienen éxito y no loguean nada inusual | Los 3,9 s gastados en un único loop de N+1 queries dentro de `inventory`, 6 saltos abajo |
| **Falla en cascada de dependencias** | Errores en 7 servicios a la vez; sin ordenamiento | 7 streams de error sin correlacionar | Un trace con un único span raíz causal y seis spans `ERROR` downstream que son consecuencias |
| **Topología desconocida** ("¿quién llama a este servicio?") | Nada | Nada confiable | Un grafo de servicios derivado de los pares de spans `CLIENT`/`SERVER` |

### 1.3 El argumento de la cardinalidad

Esta es la razón arquitectónica más profunda para correr tracing en lugar de "más métricas". Una serie temporal de Prometheus es un conjunto fijo de labels; agregar `user_id`, `tenant_id`, `order_id` o `request_id` como labels multiplica la cantidad de series y destruye la TSDB. La cardinalidad es el techo duro del modelo de métricas.

Un span **no tiene ese techo**. Los atributos de span se almacenan por evento, no por serie. `user.id`, `tenant.id`, `db.query.parameter` y `order.id` se pueden adjuntar libremente. Esto invierte la guía habitual:

> **Regla práctica:** si la dimensión no está acotada, pertenece a un span, no a un label de métrica. Derivá la métrica de baja cardinalidad *a partir* de los spans (connector `spanmetrics`), y mantené el detalle de alta cardinalidad en el trace.

### 1.4 El problema del costo, y por qué el sampling es una decisión de diseño de primer orden

Retener el 100% de los traces para un sistema que sirve 50 k req/s a un promedio de 20 spans por request son 1 M spans/s. A ~500 bytes/span serializado eso son ~500 MB/s ingeridos, ~43 TB/día. Este no es un problema de almacenamiento que se resuelva con un disco más grande; es un problema de arquitectura que se resuelve con **política de sampling**, y la política de sampling es la decisión más consecuente en una plataforma de tracing. La sección 4 la cubre en profundidad.

---

## 2. El modelo de datos

### 2.1 Trace, span, context

```
Trace  60d0d0c9d5b7a1e1b8a2c3d4e5f60718   (128-bit, 32 hex chars)
│
├─ Span  a1b2c3d4e5f60718   SERVER   frontend        GET /checkout            0 ms ────────────────── 412 ms
│  │
│  ├─ Span  b2c3d4e5f6071829  CLIENT   frontend        POST /api/cart          12 ms ──── 61 ms
│  │  └─ Span  c3d4e5f60718293a  SERVER  cart          POST /api/cart          14 ms ─── 58 ms
│  │     └─ Span  d4e5f60718293a4b  CLIENT cart         SELECT carts           18 ms ── 55 ms
│  │
│  ├─ Span  e5f60718293a4b5c  CLIENT   frontend        POST /api/payment       65 ms ─────────────── 405 ms
│  │  └─ Span  f60718293a4b5c6d  SERVER  payments      POST /api/payment       67 ms ────────────── 402 ms
│  │     ├─ Span  0718293a4b5c6d7e CLIENT payments     acquirer.example.com    70 ms ───────────── 398 ms  ⚠ 328 ms
│  │     └─ Span  18293a4b5c6d7e8f PRODUCER payments   ledger.events publish  399 ms ─ 401 ms
│  │
│  └─ Span  293a4b5c6d7e8f90  INTERNAL frontend        render.template        406 ms ─ 411 ms
```

Un **span** es el registro atómico. Sus campos obligatorios:

| Campo | Tipo | Notas |
|---|---|---|
| `trace_id` | 16 bytes / 32 hex | Constante para cada span del request. Todo en cero es inválido. |
| `span_id` | 8 bytes / 16 hex | Único dentro del trace. Todo en cero es inválido. |
| `parent_span_id` | 8 bytes / 16 hex | Vacío ⇒ este es el **span raíz**. |
| `name` | string | **Baja cardinalidad.** `GET /users/{id}`, nunca `GET /users/8412`. |
| `kind` | enum | `INTERNAL`, `SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER` |
| `start_time_unix_nano` / `end_time_unix_nano` | uint64 | Reloj de pared. El skew entre hosts es un riesgo operativo real — ver §6.5. |
| `status` | `UNSET` \| `OK` \| `ERROR` | Poné `OK` solamente cuando la aplicación juzga explícitamente que hubo éxito. |
| `attributes` | clave/valor | Aplican las semantic conventions. |
| `events` | registros con timestamp | Excepciones, cache misses, pausas de GC. |
| `links` | referencias a spans | Causalidad entre traces (consumidores por lotes, fan-in). |
| `resource` | clave/valor | Identidad inmutable del *emisor*: `service.name`, `k8s.pod.name`, `host.name`. |

**El span kind importa operativamente.** Los pares `CLIENT`/`SERVER` son lo que usa un generador de grafo de servicios para derivar la topología; `PRODUCER`/`CONSUMER` marcan fronteras asincrónicas donde el anidamiento por reloj de pared ya no implica bloqueo. Equivocarse con `kind` produce un mapa de topología silenciosamente incorrecto.

### 2.2 Propagación de contexto — W3C Trace Context

La propagación es todo el mecanismo por el cual un trace sigue siendo un solo trace. El estándar interoperable es **W3C Trace Context** (una W3C Recommendation), que define dos headers HTTP.

```
traceparent: 00-60d0d0c9d5b7a1e1b8a2c3d4e5f60718-e5f60718293a4b5c-01
             ^^ ^------------------------------^ ^--------------^ ^^
             |  trace-id (16 bytes, hex)         parent-id        trace-flags
             version                             (the caller's    bit 0 = sampled
                                                  span-id)
```

```
tracestate: congo=t61rcWkgMzE,rojo=00f067aa0ba902b7
```

- `traceparent` es **obligatorio** y se muta en cada salto: el receptor pone *su propio* span-id en `parent-id` antes de llamar al siguiente servicio.
- `tracestate` es específico del vendor, ordenado (el más reciente primero), máximo 32 entradas. Se usa para estado de sampling por vendor (por ejemplo `ot=th:8` para el threshold de consistent sampling de OpenTelemetry).
- El bit 0 de `trace-flags` (`01`) es el flag **sampled**. Esta es la señal en el cable que hace coherente el head-based sampling a lo largo de todo un request.
- **`baggage`** (una spec W3C separada) transporta pares clave/valor arbitrarios de usuario a lo largo de todo el trace: `baggage: tenant.tier=platinum,deploy.ring=canary`. El baggage *no* se copia automáticamente a los spans, y cruza fronteras de confianza — nunca pongas secretos ni PII ahí.

### 2.3 Comparación de formatos de propagación

| Formato | Headers | Ancho del trace-ID | Estado | Cuándo lo seguís necesitando |
|---|---|---|---|---|
| **W3C Trace Context** | `traceparent`, `tracestate` | 128-bit | Estándar; default de OTel | Siempre. Este es el estado objetivo. |
| **B3 multi** | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-ParentSpanId`, `X-B3-Sampled`, `X-B3-Flags` | 64 o 128-bit | Legacy (Zipkin) | Mallas Istio/Envoy, Spring Cloud Sleuth antiguo |
| **B3 single** | `b3: {trace}-{span}-{sampled}-{parent}` | 64 o 128-bit | Legacy | Proxies con presupuesto de headers limitado |
| **Jaeger** | `uber-trace-id: {trace}:{span}:{parent}:{flags}` | 64 o 128-bit | Legacy | SDKs de cliente Jaeger pre-OTel todavía en producción |
| **AWS X-Ray** | `X-Amzn-Trace-Id: Root=1-5759e988-...;Parent=...;Sampled=1` | Formato X-Ray | Vendor | Puertas de entrada ALB / API Gateway / Lambda |
| **OT Trace** | `ot-tracer-traceid`, … | 64-bit | Deprecado | LightStep legacy |

**Patrón de migración:** configurá el SDK para *extraer* varios formatos e *inyectar* varios, de modo que una flota mixta mantenga los traces enteros durante el rollout.

```bash
export OTEL_PROPAGATORS=tracecontext,baggage,b3multi,jaeger
```

Gana el primer propagator que extrae con éxito; todos los propagators listados inyectan.

### 2.4 Semantic conventions

Los nombres de atributos son una API estable. Los backends construyen UIs, métricas RED y grafos de servicios sobre ellos. Las semantic conventions de OpenTelemetry pasaron por un rename mayor de HTTP que todavía se ve en flotas en producción:

| Concepto | Legacy (pre-1.21) | Estable (actual) |
|---|---|---|
| Método HTTP | `http.method` | `http.request.method` |
| Código de estado | `http.status_code` | `http.response.status_code` |
| URL completa | `http.url` | `url.full` |
| Template de ruta | `http.route` | `http.route` (sin cambios) |
| Host par | `net.peer.name` | `server.address` |
| Puerto par | `net.peer.port` | `server.port` |
| Sentencia de DB | `db.statement` | `db.query.text` |
| Sistema de DB | `db.system` | `db.system.name` |

Durante la migración, muchos SDKs aceptan `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` para emitir **ambos** conjuntos, de modo que dashboards y alertas puedan migrarse sin un flag day.

---

## 3. Arquitectura: SDK → Collector → Backend

### 3.1 Por qué el OpenTelemetry Collector no es opcional en producción

Exportar directamente desde el SDK de la aplicación al backend de almacenamiento funciona en una demo y falla en producción por cinco razones:

1. **Acoplamiento al backend.** Cambiar de Jaeger → Tempo significa redesplegar cada servicio.
2. **Dispersión de credenciales.** Cada pod necesita credenciales del backend.
3. **Sin política central.** La redacción, el tail sampling, la normalización de atributos y el rate limiting hay que implementarlos N veces en N lenguajes.
4. **Sin enriquecimiento.** La aplicación no conoce su propio `k8s.node.name`, región de nube ni tipo de instancia.
5. **Backpressure.** Las colas de exportación del SDK son chicas; cuando el backend se degrada, las aplicaciones empiezan a descartar spans o, peor, a bloquearse.

El Collector es un binario de pipeline neutral respecto del vendor que resuelve las cinco.

```
┌──────────────┐   OTLP    ┌──────────────────┐  OTLP+LB  ┌──────────────────┐  OTLP  ┌─────────┐
│ app + SDK    │──────────▶│ Collector AGENT  │──────────▶│ Collector GATEWAY│───────▶│ Jaeger  │
│ (in-process) │  gRPC     │ DaemonSet        │ routing_  │ Deployment (HPA) │        │ Tempo   │
│              │  :4317    │ - k8sattributes  │ key=      │ - tail_sampling  │        │ Zipkin  │
└──────────────┘           │ - resourcedetect │ traceID   │ - spanmetrics    │        └─────────┘
                           │ - batch          │           │ - redaction      │
                           └──────────────────┘           └──────────────────┘
```

La división en **dos niveles** existe por una razón técnica dura: **el tail-based sampling requiere que todos los spans de un trace lleguen a la misma instancia del collector.** Un agente DaemonSet no puede satisfacer eso (los spans de un trace se originan en muchos nodos). Por eso el nivel de agentes usa el exporter `loadbalancing` con `routing_key: traceID` para rutear por hash de manera consistente hacia un nivel de gateway con estado.

### 3.2 Tipos de componentes del pipeline del Collector

| Tipo | Rol | Ejemplos relevantes en producción |
|---|---|---|
| **Receivers** | Ingesta | `otlp` (gRPC 4317 / HTTP 4318), `jaeger`, `zipkin`, `kafka`, `filelog` |
| **Processors** | Transforman, ordenados | `memory_limiter` (debe ir primero), `k8sattributes`, `resourcedetection`, `tail_sampling`, `transform`, `filter`, `batch` (debe ir último) |
| **Exporters** | Emiten | `otlp`, `otlphttp`, `loadbalancing`, `prometheus`, `debug`, `file` |
| **Connectors** | De pipeline a pipeline; consumen una señal, producen otra | `spanmetrics` (traces→metrics), `servicegraph` (traces→metrics), `forward` |
| **Extensions** | Capacidad fuera del pipeline | `health_check`, `pprof`, `zpages`, `basicauth`, `oauth2client`, `file_storage` |

> **El orden de los processors es semántica, no estilo.** `memory_limiter` primero (tiene que poder rechazar antes de que algo aloque memoria), `batch` último (batchear antes del enriquecimiento desperdicia trabajo y rompe la asociación por conexión de `k8sattributes`). Poner `batch` antes de `tail_sampling` es un bug de corrección, no de performance.

### 3.3 Comparación de backends

| | **Jaeger v2** | **Grafana Tempo** | **Zipkin** | **OpenSearch/Elastic APM** |
|---|---|---|---|---|
| Gobernanza | CNCF (graduado) | Grafana Labs (AGPLv3) | OpenZipkin | Elastic / OpenSearch |
| Construido sobre | OpenTelemetry Collector | Standalone (linaje Cortex) | JVM standalone | Elasticsearch |
| Ingesta nativa | OTLP | OTLP, Jaeger, Zipkin | Zipkin v1/v2, OTLP vía collector | OTLP |
| Almacenamiento | Cassandra, Elasticsearch/OpenSearch, ClickHouse, Badger, memoria | **Solo object storage** (S3/GCS/Azure) | Cassandra, ES, MySQL, memoria | Elasticsearch |
| Índice | Índice completo de atributos | **Solo trace-ID**, más escaneo de bloques TraceQL opcional | Índice completo | Índice completo |
| Lenguaje de consulta | Filtros de UI + API JSON | **TraceQL** | Filtros de UI | KQL / Lucene |
| Costo a escala | Domina el costo del índice; caro | **El más barato** — no hay índice que mantener | Domina el costo del índice | El más caro |
| Latencia de búsqueda | Rápida, indexada | Más lenta para búsquedas amplias (escaneo de bloques) | Rápida | Rápida |
| Métricas desde spans | SPM (vía `spanmetrics`) | `metrics_generator` incorporado | No | Sí |
| Mejor para | Búsqueda de fidelidad completa, sampling mixto | Volumen muy alto, "guardar todo, buscar por ID" | Instalaciones legacy | Equipos ya totalmente comprometidos con Elastic |

**Heurística de decisión:** si tu flujo de trabajo dominante es *"tengo un trace ID de una línea de log, mostrame el trace"*, la economía de Tempo es imbatible. Si es *"buscame todos los traces donde `tenant.id=acme` devolvió 503 el martes pasado"*, necesitás un índice — Jaeger sobre Elasticsearch o ClickHouse.

---

## 4. Sampling

### 4.1 Comparación de estrategias

| Estrategia | Punto de decisión | ¿Ve el trace completo? | ¿Coherente entre servicios? | ¿Captura todos los errores? | Modelo de costo |
|---|---|---|---|---|---|
| **AlwaysOn** | Raíz | n/a | Sí | Sí | Ilimitado |
| **AlwaysOff** | Raíz | n/a | Sí | No | Cero |
| **TraceIdRatioBased** | Raíz, hash del trace-id | No | Solo si todos los servicios usan el mismo ratio | No | Lineal, predecible |
| **ParentBased(root=ratio)** | Decide la raíz, los hijos obedecen `trace-flags` | No | **Sí** | No | Lineal, predecible |
| **Rate limiting** (spans/s) | Raíz | No | Débilmente | No | Con tope duro |
| **Jaeger adaptive/remote** | Raíz, por operación, dirigido por el servidor | No | Sí | Aproximadamente | Autoajustable |
| **Tail-based** | Gateway, después de `decision_wait` | **Sí** | Sí | **Sí** | Memoria de buffer + ingesta completa al gateway |

**El trade-off en una oración:** el head sampling es barato y decide *antes* de saber si el request era interesante; el tail sampling sabe todo y te cuesta ingesta de fidelidad completa y un nivel de gateway con estado y hambriento de memoria.

### 4.2 Head sampling — el default correcto

`parentbased_traceidratio` es el único head sampler que produce traces *completos*. Un `traceidratio` independiente e ingenuo en cada servicio produce fragmentos: el servicio A samplea, el servicio B no, y obtenés un stub de dos spans.

```bash
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.05      # 5% of root requests, whole trace or nothing
```

La decisión es determinista sobre el hash del trace-id, así que **cada SDK en cada lenguaje llega al mismo veredicto para el mismo trace-id** — que es lo que la hace segura incluso antes de que la propagación de `trace-flags` funcione del todo.

### 4.3 Tail sampling — el conjunto de políticas de producción

La política realista de producción es una **unión**: quedarse con todo lo interesante, más una línea base estadística para que tus histogramas de latencia no tengan sesgo de supervivencia.

- Todos los traces con estado `ERROR` → 100%
- Todos los traces más lentos que el umbral del SLO → 100%
- Tenants de tier platinum → 50%
- Todo lo demás → 2% de línea base

Dos restricciones operativas gobiernan `tail_sampling`:

1. **`decision_wait` es un trade-off entre latencia y completitud.** Demasiado corto y decidís antes de que lleguen los spans lentos, descartando sistemáticamente exactamente los traces lentos que querías. Ponelo por encima de la duración de request de tu p99.9.
2. **`num_traces × spans promedio × tamaño de span` es memoria residente.** 200 000 traces × 20 spans × 500 B ≈ 2 GB antes del overhead. Dimensioná el gateway en consecuencia y siempre combinalo con `memory_limiter`.

---

## 5. Manifiestos de infraestructura completos

Todo lo que sigue se despliega en un namespace `observability` y es autoconsistente: nivel de agentes → nivel de gateway → Tempo, más una aplicación instrumentada.

### 5.1 Namespace y RBAC para `k8sattributes`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    app.kubernetes.io/part-of: telemetry-platform
    pod-security.kubernetes.io/enforce: restricted
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
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
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

### 5.2 Nivel de agentes — DaemonSet + ConfigMap

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
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            max_recv_msg_size_mib: 8
            keepalive:
              server_parameters:
                max_connection_age: 30s
                max_connection_age_grace: 5s
          http:
            endpoint: 0.0.0.0:4318
      zipkin:
        endpoint: 0.0.0.0:9411
      jaeger:
        protocols:
          thrift_http:
            endpoint: 0.0.0.0:14268
          grpc:
            endpoint: 0.0.0.0:14250

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20

      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          node_from_env_var: KUBE_NODE_NAME
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.deployment.name
            - k8s.statefulset.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.pod.start_time
            - k8s.node.name
            - k8s.container.name
            - container.image.name
            - container.image.tag
          labels:
            - tag_name: service.version
              key: app.kubernetes.io/version
              from: pod
            - tag_name: deploy.ring
              key: deploy.example.com/ring
              from: pod
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: connection

      resourcedetection/env:
        detectors: [env, system]
        timeout: 5s
        override: false

      transform/redact:
        error_mode: ignore
        trace_statements:
          - context: span
            statements:
              - replace_pattern(attributes["url.full"], "(token|api_key)=[^&]*", "$$1=REDACTED")
              - delete_key(attributes, "http.request.header.authorization")
              - delete_key(attributes, "db.query.parameter.password")

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 2s

    exporters:
      loadbalancing:
        routing_key: traceID
        protocol:
          otlp:
            timeout: 10s
            tls:
              insecure: true
            sending_queue:
              enabled: true
              num_consumers: 10
              queue_size: 5000
            retry_on_failure:
              enabled: true
              initial_interval: 5s
              max_interval: 30s
              max_elapsed_time: 300s
        resolver:
          k8s:
            service: otel-gateway-headless.observability
            ports:
              - 4317

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      pprof:
        endpoint: 127.0.0.1:1777
      zpages:
        endpoint: 127.0.0.1:55679

    service:
      extensions: [health_check, pprof, zpages]
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
          receivers: [otlp, zipkin, jaeger]
          processors:
            - memory_limiter
            - k8sattributes
            - resourcedetection/env
            - transform/redact
            - batch
          exporters: [loadbalancing]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-agent
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-agent
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
    spec:
      serviceAccountName: otel-collector
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.115.1
          args: ["--config=/conf/config.yaml"]
          env:
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: GOMEMLIMIT
              value: "800MiB"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "k8s.cluster.name=prod-eu-1,deployment.environment=production"
          ports:
            - name: otlp-grpc
              containerPort: 4317
              hostPort: 4317
              protocol: TCP
            - name: otlp-http
              containerPort: 4318
              hostPort: 4318
              protocol: TCP
            - name: zipkin
              containerPort: 9411
              protocol: TCP
            - name: metrics
              containerPort: 8888
              protocol: TCP
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /conf
      volumes:
        - name: config
          configMap:
            name: otel-agent-config
            items:
              - key: config.yaml
                path: config.yaml
```

> **Nota sobre `GOMEMLIMIT`:** sin él, el runtime de Go crece alegremente más allá del límite del contenedor y el kernel mata el collector por OOM antes de que `memory_limiter` llegue siquiera a rechazar un batch. Ponelo en ~80% del límite de memoria. Esta única línea previene la caída de collector más común.

### 5.3 Nivel de gateway — tail sampling, span metrics, grafo de servicios

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
            max_recv_msg_size_mib: 16
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 15

      tail_sampling:
        decision_wait: 30s
        num_traces: 200000
        expected_new_traces_per_sec: 4000
        policies:
          - name: keep-all-errors
            type: status_code
            status_code:
              status_codes: [ERROR]

          - name: keep-http-5xx
            type: numeric_attribute
            numeric_attribute:
              key: http.response.status_code
              min_value: 500
              max_value: 599

          - name: keep-slow-requests
            type: latency
            latency:
              threshold_ms: 1500

          - name: keep-explicitly-marked
            type: boolean_attribute
            boolean_attribute:
              key: sampling.priority.force
              value: true

          - name: platinum-tenants-half
            type: and
            and:
              and_sub_policy:
                - name: is-platinum
                  type: string_attribute
                  string_attribute:
                    key: tenant.tier
                    values: [platinum]
                    enabled_regex_matching: false
                - name: half
                  type: probabilistic
                  probabilistic:
                    sampling_percentage: 50

          - name: drop-health-checks
            type: and
            and:
              and_sub_policy:
                - name: is-healthz
                  type: string_attribute
                  string_attribute:
                    key: http.route
                    values: ["/healthz", "/readyz", "/metrics"]
                - name: none
                  type: probabilistic
                  probabilistic:
                    sampling_percentage: 0

          - name: statistical-baseline
            type: probabilistic
            probabilistic:
              sampling_percentage: 2

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 5s

    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s, 10s, 30s]
        dimensions:
          - name: http.request.method
          - name: http.response.status_code
          - name: http.route
          - name: deployment.environment
          - name: k8s.namespace.name
        exclude_dimensions: ["span.kind"]
        exemplars:
          enabled: true
        dimensions_cache_size: 100000
        metrics_flush_interval: 15s
        metrics_expiration: 5m
        namespace: traces.span.metrics

      servicegraph:
        latency_histogram_buckets: [1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s, 10s]
        dimensions: [k8s.cluster.name, k8s.namespace.name]
        store:
          ttl: 5s
          max_items: 200000
        cache_loop: 1m
        store_expiration_loop: 2s

    exporters:
      otlp/tempo:
        endpoint: tempo.observability.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          num_consumers: 20
          queue_size: 10000
          storage: file_storage/queue
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 60s
          max_elapsed_time: 600s

      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true
        resource_to_telemetry_conversion:
          enabled: true

      debug:
        verbosity: basic
        sampling_initial: 5
        sampling_thereafter: 500

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      pprof:
        endpoint: 127.0.0.1:1777
      zpages:
        endpoint: 0.0.0.0:55679
      file_storage/queue:
        directory: /var/lib/otelcol/queue
        timeout: 10s

    service:
      extensions: [health_check, pprof, zpages, file_storage/queue]
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
          receivers: [otlp]
          processors: [memory_limiter, tail_sampling, batch]
          exporters: [otlp/tempo, spanmetrics, servicegraph]

        metrics/derived:
          receivers: [spanmetrics, servicegraph]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway-headless
  namespace: observability
spec:
  clusterIP: None
  publishNotReadyAddresses: false
  selector:
    app.kubernetes.io/name: otel-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
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
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: metrics
      port: 8888
      targetPort: 8888
    - name: prom-derived
      port: 8889
      targetPort: 8889
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: otel-gateway
  namespace: observability
spec:
  serviceName: otel-gateway-headless
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-gateway
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
    spec:
      serviceAccountName: otel-collector
      terminationGracePeriodSeconds: 60
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: otel-gateway
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.115.1
          args: ["--config=/conf/config.yaml"]
          env:
            - name: GOMEMLIMIT
              value: "6GiB"
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
            - name: metrics
              containerPort: 8888
            - name: prom-derived
              containerPort: 8889
            - name: zpages
              containerPort: 55679
          resources:
            requests:
              cpu: "2"
              memory: 6Gi
            limits:
              memory: 8Gi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /
              port: 13133
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /conf
            - name: queue
              mountPath: /var/lib/otelcol/queue
      volumes:
        - name: config
          configMap:
            name: otel-gateway-config
  volumeClaimTemplates:
    - metadata:
        name: queue
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
```

> **Por qué un `StatefulSet` y no un `Deployment`:** el resolver k8s del exporter `loadbalancing` hashea los trace-IDs sobre el conjunto actual de endpoints. Las identidades estables más el manejo de pods `Parallel` minimizan la ventana de reacomodamiento durante los rollouts — cada reacomodamiento parte los traces en vuelo entre dos gateways y corrompe las decisiones de tail sampling durante `decision_wait` segundos. El PVC respalda la cola de envío persistente para que un reinicio no descarte spans bufferizados.

### 5.4 Backend — Grafana Tempo (monolítico, S3)

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: observability
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
      grpc_listen_port: 9095
      log_level: info

    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
        jaeger:
          protocols:
            grpc:
              endpoint: 0.0.0.0:14250
            thrift_http:
              endpoint: 0.0.0.0:14268
        zipkin:
          endpoint: 0.0.0.0:9411
      log_received_spans:
        enabled: false

    ingester:
      max_block_duration: 5m
      max_block_bytes: 524288000
      complete_block_timeout: 15m

    compactor:
      compaction:
        block_retention: 720h
        compacted_block_retention: 1h
        compaction_window: 1h
        max_compaction_objects: 6000000

    metrics_generator:
      registry:
        external_labels:
          source: tempo
          cluster: prod-eu-1
      storage:
        path: /var/tempo/generator/wal
        remote_write:
          - url: http://prometheus.observability.svc.cluster.local:9090/api/v1/write
            send_exemplars: true
      traces_storage:
        path: /var/tempo/generator/traces
      processor:
        service_graphs:
          max_items: 20000
          wait: 10s
        span_metrics:
          histogram_buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1, 2.5, 5, 10]

    querier:
      max_concurrent_queries: 20
      search:
        query_timeout: 60s

    query_frontend:
      max_outstanding_per_tenant: 2000
      search:
        concurrent_jobs: 1000
        max_duration: 168h

    storage:
      trace:
        backend: s3
        wal:
          path: /var/tempo/wal
        local:
          path: /var/tempo/blocks
        s3:
          bucket: tempo-traces-prod-eu-1
          endpoint: s3.eu-central-1.amazonaws.com
          region: eu-central-1
          insecure: false
        pool:
          max_workers: 100
          queue_depth: 10000
        block:
          version: vParquet4

    overrides:
      defaults:
        metrics_generator:
          processors: [service-graphs, span-metrics, local-blocks]
        ingestion:
          rate_limit_bytes: 50000000
          burst_size_bytes: 100000000
          max_traces_per_user: 200000
        global:
          max_bytes_per_trace: 50000000
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: observability
spec:
  selector:
    app.kubernetes.io/name: tempo
  ports:
    - name: http
      port: 3200
      targetPort: 3200
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tempo
  namespace: observability
spec:
  serviceName: tempo
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: tempo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: tempo
    spec:
      serviceAccountName: tempo
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
      containers:
        - name: tempo
          image: grafana/tempo:2.6.1
          args:
            - "-config.file=/etc/tempo/tempo.yaml"
            - "-target=all"
          env:
            - name: AWS_REGION
              value: eu-central-1
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: tempo-s3
                  key: access_key_id
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: tempo-s3
                  key: secret_access_key
          ports:
            - containerPort: 3200
            - containerPort: 4317
            - containerPort: 4318
          resources:
            requests:
              cpu: "1"
              memory: 4Gi
            limits:
              memory: 8Gi
          readinessProbe:
            httpGet:
              path: /ready
              port: 3200
            initialDelaySeconds: 20
          volumeMounts:
            - name: config
              mountPath: /etc/tempo
            - name: data
              mountPath: /var/tempo
      volumes:
        - name: config
          configMap:
            name: tempo-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 100Gi
```

### 5.5 Backend alternativo — Jaeger v2 con Elasticsearch

Jaeger v2 es en sí mismo una distribución del OpenTelemetry Collector: la misma gramática de `receivers`/`processors`/`exporters`/`extensions`, más extensiones de storage y query específicas de Jaeger.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: jaeger-config
  namespace: observability
data:
  jaeger.yaml: |
    service:
      extensions: [jaeger_storage, jaeger_query, healthcheckv2]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [jaeger_storage_exporter]
      telemetry:
        logs:
          level: info
        metrics:
          level: detailed
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888

    extensions:
      healthcheckv2:
        use_v2: true
        http:
          endpoint: 0.0.0.0:13133

      jaeger_query:
        storage:
          traces: es_main
        base_path: /
        http:
          endpoint: 0.0.0.0:16686
        grpc:
          endpoint: 0.0.0.0:16685

      jaeger_storage:
        backends:
          es_main:
            elasticsearch:
              server_urls:
                - https://elasticsearch.observability.svc.cluster.local:9200
              indices:
                index_prefix: jaeger
                spans:
                  date_layout: "2006-01-02"
                  rollover_frequency: day
                  shards: 5
                  replicas: 1
              bulk:
                size: 5000000
                workers: 10
                flush_interval: 200ms
              tls:
                insecure_skip_verify: false
              auth:
                basic:
                  username: jaeger
                  password_file: /etc/jaeger/es-password

    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        send_batch_size: 5000
        timeout: 5s

    exporters:
      jaeger_storage_exporter:
        trace_storage: es_main
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector:
    app.kubernetes.io/name: jaeger
  ports:
    - name: ui
      port: 16686
      targetPort: 16686
    - name: otlp-grpc
      port: 4317
    - name: otlp-http
      port: 4318
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: jaeger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: jaeger
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/jaeger:2.1.0
          args: ["--config", "/etc/jaeger/jaeger.yaml"]
          ports:
            - containerPort: 16686
            - containerPort: 4317
            - containerPort: 4318
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /status
              port: 13133
          volumeMounts:
            - name: config
              mountPath: /etc/jaeger
            - name: es-credentials
              mountPath: /etc/jaeger/es-password
              subPath: es-password
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: jaeger-config
        - name: es-credentials
          secret:
            secretName: jaeger-es
```

**Referencia de puertos de Jaeger (todavía relevante para el examen):**

| Puerto | Protocolo | Propósito |
|---|---|---|
| 4317 | gRPC | OTLP — la ruta de ingesta moderna |
| 4318 | HTTP | OTLP/HTTP, path `/v1/traces` |
| 16686 | HTTP | API de consulta + UI web |
| 16685 | gRPC | API de consulta gRPC |
| 14268 | HTTP | Collector Jaeger Thrift legacy |
| 14250 | gRPC | Collector Jaeger model.proto legacy |
| 9411 | HTTP | Ingesta compatible con Zipkin |
| 13133 | HTTP | Health check |
| 5778 | HTTP | Configuración de remote sampling |

El **agent** de Jaeger v1 (UDP 6831/6832) desapareció en v2 — su rol lo cumple un DaemonSet de OTel Collector.

### 5.6 Aplicación instrumentada — inyección zero-code vía el OpenTelemetry Operator

```yaml
---
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: default-instrumentation
  namespace: shop
spec:
  exporter:
    endpoint: http://$(NODE_IP):4318
  propagators:
    - tracecontext
    - baggage
    - b3multi
  sampler:
    type: parentbased_traceidratio
    argument: "0.05"
  resource:
    addK8sUIDAttributes: true
    resourceAttributes:
      deployment.environment: production
  env:
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: http/protobuf
    - name: OTEL_SEMCONV_STABILITY_OPT_IN
      value: http/dup
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.50b0
    env:
      - name: OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED
        value: "true"
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.10.0
    env:
      - name: OTEL_INSTRUMENTATION_JDBC_ENABLED
        value: "true"
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.53.0
  go:
    image: ghcr.io/open-telemetry/opentelemetry-go-instrumentation/autoinstrumentation-go:v0.19.0-alpha
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: "3.4.1"
spec:
  replicas: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "3.4.1"
      annotations:
        instrumentation.opentelemetry.io/inject-python: "default-instrumentation"
    spec:
      containers:
        - name: checkout
          image: registry.example.com/shop/checkout:3.4.1
          ports:
            - containerPort: 8080
          env:
            - name: NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,service.version=3.4.1"
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 512Mi
```

### 5.7 Instrumentación manual donde importa

La auto-instrumentación te da las fronteras (HTTP de entrada, HTTP de salida, DB, cola). No puede decirte qué paso *de negocio* fue lento. Agregá spans manuales solo en los puntos de decisión.

**Python:**

```python
from opentelemetry import trace, baggage, context
from opentelemetry.trace import SpanKind, Status, StatusCode
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

resource = Resource.create({
    "service.name": "checkout",
    "service.version": "3.4.1",
    "service.namespace": "shop",
    "deployment.environment": "production",
})

provider = TracerProvider(
    resource=resource,
    sampler=ParentBased(root=TraceIdRatioBased(0.05)),
)
provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(endpoint="http://otel-agent:4317", insecure=True),
        max_queue_size=8192,
        max_export_batch_size=1024,
        schedule_delay_millis=2000,
        export_timeout_millis=30000,
    )
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("shop.checkout", "3.4.1")


def submit_order(order):
    with tracer.start_as_current_span(
        "checkout.submit_order",
        kind=SpanKind.INTERNAL,
        attributes={
            "order.id": order.id,               # high cardinality: fine on a span
            "order.item_count": len(order.items),
            "order.total_cents": order.total_cents,
            "tenant.id": order.tenant_id,
        },
    ) as span:
        ctx = baggage.set_baggage("tenant.tier", order.tenant_tier)
        token = context.attach(ctx)
        try:
            reserve_inventory(order)
            span.add_event("inventory.reserved",
                           attributes={"warehouse.id": order.warehouse_id})
            charge = authorize_payment(order)
            span.set_attribute("payment.authorization_code", charge.auth_code)
            span.set_status(Status(StatusCode.OK))
            return charge
        except PaymentDeclined as exc:
            # A declined card is a business outcome, NOT a system error.
            span.set_attribute("payment.decline_reason", exc.reason)
            span.add_event("payment.declined", attributes={"reason": exc.reason})
            raise
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise
        finally:
            context.detach(token)
```

> **La disciplina del estado `ERROR`:** marcá un span como `ERROR` solo cuando falló *tu servicio*. Un `404`, un rechazo de validación o una tarjeta declinada son resultados correctos. Los equipos que marcan todo lo que no sea 2xx como `ERROR` destruyen su propia política de tail sampling: la regla "quedarse con todos los errores" pasa entonces a quedarse con el 30% del tráfico y el presupuesto de sampling se evapora.

**Go — propagación a través de una frontera asincrónica de Kafka**, que es donde la auto-instrumentación rompe el trace más a menudo:

```go
package orders

import (
	"context"

	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("shop/orders")

// kafkaCarrier adapts kafka-go headers to the TextMapCarrier interface so that
// the W3C traceparent survives the queue hop.
type kafkaCarrier struct{ msg *kafka.Message }

func (c kafkaCarrier) Get(key string) string {
	for _, h := range c.msg.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}

func (c kafkaCarrier) Set(key, value string) {
	for i, h := range c.msg.Headers {
		if h.Key == key {
			c.msg.Headers[i].Value = []byte(value)
			return
		}
	}
	c.msg.Headers = append(c.msg.Headers, kafka.Header{Key: key, Value: []byte(value)})
}

func (c kafkaCarrier) Keys() []string {
	keys := make([]string, 0, len(c.msg.Headers))
	for _, h := range c.msg.Headers {
		keys = append(keys, h.Key)
	}
	return keys
}

func Publish(ctx context.Context, w *kafka.Writer, topic string, payload []byte) error {
	ctx, span := tracer.Start(ctx, topic+" publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.destination.name", topic),
			attribute.Int("messaging.message.body.size", len(payload)),
		),
	)
	defer span.End()

	msg := kafka.Message{Topic: topic, Value: payload}
	otel.GetTextMapPropagator().Inject(ctx, kafkaCarrier{msg: &msg})
	return w.WriteMessages(ctx, msg)
}

func Consume(ctx context.Context, msg kafka.Message, handle func(context.Context, []byte) error) error {
	// Extract restores the producer's context; WithLinks is the alternative when
	// one consumer span aggregates a batch from many producers.
	parent := otel.GetTextMapPropagator().Extract(ctx, kafkaCarrier{msg: &msg})

	ctx, span := tracer.Start(parent, msg.Topic+" process",
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.destination.name", msg.Topic),
			attribute.Int("messaging.kafka.partition", msg.Partition),
			attribute.Int64("messaging.kafka.offset", msg.Offset),
		),
	)
	defer span.End()

	return handle(ctx, msg.Value)
}

var _ propagation.TextMapCarrier = kafkaCarrier{}
```

### 5.8 Referencia de variables de entorno del SDK

| Variable | Efecto | Valor típico en producción |
|---|---|---|
| `OTEL_SERVICE_NAME` | Define `service.name` (identidad obligatoria) | `checkout` |
| `OTEL_RESOURCE_ATTRIBUTES` | K/V de recurso adicionales, separados por coma | `service.version=3.4.1,deployment.environment=production` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Endpoint base **incluyendo el esquema** | `http://otel-agent:4318` |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Específico de la señal; para HTTP debe incluir `/v1/traces` | `http://otel-agent:4318/v1/traces` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` \| `http/protobuf` \| `http/json` | `http/protobuf` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Headers de autenticación | `api-key=...` |
| `OTEL_TRACES_SAMPLER` | Nombre del sampler | `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | Argumento del sampler | `0.05` |
| `OTEL_PROPAGATORS` | Formatos de extracción/inyección | `tracecontext,baggage,b3multi` |
| `OTEL_BSP_MAX_QUEUE_SIZE` | Cola del batch processor | `8192` |
| `OTEL_BSP_SCHEDULE_DELAY` | Intervalo de exportación (ms) | `2000` |
| `OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT` | Tope por span | `128` |
| `OTEL_SDK_DISABLED` | Interruptor de corte | `false` |

> **La trampa del endpoint, en términos de examen:** con `OTEL_EXPORTER_OTLP_ENDPOINT` el SDK agrega `/v1/traces` para HTTP; con `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` **no** lo hace. La mitad de los incidentes de "no llegan traces" son esta única regla más un esquema `http://` faltante.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Puesta en marcha: probá el pipeline antes de culpar a la aplicación

```console
$ podman run --rm -d --name otelcol \
    -p 4317:4317 -p 4318:4318 -p 8888:8888 -p 55679:55679 \
    -v "$PWD/config.yaml:/etc/otelcol/config.yaml:Z" \
    otel/opentelemetry-collector-contrib:0.115.1 \
    --config=/etc/otelcol/config.yaml
6f3a1d9c04b7e2f18a5c3d9e7b21c4a806f5e93d1b7c2a4e6f80d5b3c1a9e742

$ podman exec otelcol /otelcol-contrib validate --config=file:/etc/otelcol/config.yaml
$ echo $?
0
```

Una salida distinta de cero imprime la ruta ofensora — este es el chequeo de sintaxis de configuración más rápido y corresponde ponerlo en CI:

```console
$ podman run --rm -v "$PWD/broken.yaml:/c.yaml:Z" \
    otel/opentelemetry-collector-contrib:0.115.1 validate --config=file:/c.yaml
Error: failed to get config: cannot unmarshal the configuration: decoding failed due to the
following error(s):

error decoding 'processors': unknown type: "tail_sampling_v2" for id: "tail_sampling_v2"
(valid values: [attributes batch cumulativetodelta deltatorate filter groupbyattrs
groupbytrace k8sattributes memory_limiter metricstransform probabilistic_sampler
redaction remotetap resource resourcedetection routing span tail_sampling transform])
$ echo $?
1
```

Confirmá que los listeners están realmente bindeados:

```console
$ ss -lntp | grep -E '4317|4318|8888'
LISTEN 0  4096  *:4317  *:*  users:(("otelcol-contrib",pid=1,fd=12))
LISTEN 0  4096  *:4318  *:*  users:(("otelcol-contrib",pid=1,fd=14))
LISTEN 0  4096  *:8888  *:*  users:(("otelcol-contrib",pid=1,fd=9))
```

### 6.2 Inyectá un span sintético de punta a punta

**OTLP/HTTP crudo con JSON** — sin SDK, sin aplicación, sin ambigüedad:

```console
$ cat > /tmp/span.json <<'EOF'
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "smoke-test"}},
        {"key": "deployment.environment", "value": {"stringValue": "production"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "manual-smoke", "version": "1.0.0"},
      "spans": [{
        "traceId": "5b8efff798038103d269b633813fc60c",
        "spanId": "eee19b7ec3c1b174",
        "name": "GET /healthz",
        "kind": 2,
        "startTimeUnixNano": "1756900000000000000",
        "endTimeUnixNano": "1756900000123000000",
        "attributes": [
          {"key": "http.request.method", "value": {"stringValue": "GET"}},
          {"key": "http.route", "value": {"stringValue": "/healthz"}},
          {"key": "http.response.status_code", "value": {"intValue": "200"}}
        ],
        "status": {"code": 1}
      }]
    }]
  }]
}
EOF

$ curl -sS -i -X POST http://localhost:4318/v1/traces \
    -H 'Content-Type: application/json' \
    --data-binary @/tmp/span.json
HTTP/1.1 200 OK
Content-Type: application/json
Date: Wed, 03 Sep 2026 09:41:07 GMT
Content-Length: 21

{"partialSuccess":{}}
```

`{"partialSuccess":{}}` con HTTP 200 es aceptación total. Un `partialSuccess.rejectedSpans` con contenido significa que el collector tomó algunos y descartó otros — leé siempre el cuerpo, nunca solo el código de estado.

**Con `otel-cli`**, para smoke tests de CI scriptables:

```console
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
$ otel-cli span --service smoke-test --name "deploy.verify" \
    --attrs "ci.pipeline=release,ci.build=4711" \
    --kind internal --verbose
trace_id: 4f1a2b3c5d6e7f8091a2b3c4d5e6f708
 span_id: 91a2b3c4d5e6f708
 endpoint: localhost:4317 (grpc)
 status: sent
```

### 6.3 Leé la propia telemetría del collector — el diagnóstico más útil

```console
$ curl -s http://localhost:8888/metrics | grep -E '^otelcol_(receiver|processor|exporter)' | sort
otelcol_exporter_queue_capacity{exporter="otlp/tempo"} 10000
otelcol_exporter_queue_size{exporter="otlp/tempo"} 47
otelcol_exporter_send_failed_spans_total{exporter="otlp/tempo"} 0
otelcol_exporter_sent_spans_total{exporter="otlp/tempo"} 1284933
otelcol_processor_batch_batch_send_size_bucket{le="10000",processor="batch"} 3122
otelcol_processor_batch_timeout_trigger_send_total{processor="batch"} 1877
otelcol_processor_refused_spans_total{processor="memory_limiter"} 0
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 1284933
otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc"} 0
```

**Los cuatro números que explican casi todos los incidentes:**

| Métrica | Saludable | Qué significa un valor no nulo / creciente |
|---|---|---|
| `otelcol_receiver_refused_spans_total` | 0 | El collector está rechazando ingesta — casi siempre backpressure de `memory_limiter` |
| `otelcol_processor_refused_spans_total{processor="memory_limiter"}` | 0 | Se alcanzó el techo de memoria; subí los límites o escalá horizontalmente |
| `otelcol_exporter_send_failed_spans_total` | 0 | Backend inalcanzable, falla de TLS, falla de autenticación o rechazo por cuota |
| `otelcol_exporter_queue_size` vs `_capacity` | < 50% | Sostenidamente cerca de la capacidad ⇒ el backend es más lento que la ingesta; los descartes son inminentes |

Un pipeline **saludable** satisface `receiver_accepted ≈ exporter_sent` (contemplando los descartes por sampling, que deberías contabilizar aparte vía las métricas de `tail_sampling`).

### 6.4 zPages — introspección en vivo dentro del proceso

```console
$ curl -s "http://localhost:55679/debug/tracez" | head -30
TraceZ Summary
Span Name                                    Running    Latency Samples             Errors
                                                        [0,10us) [10us,100us) ...
exporter/otlp/tempo/traces                         0           0            4  ...       0
processor/tail_sampling/TraceData                  3          12          188  ...       0
receiver/otlp/TraceDataReceived                    1           0          871  ...       0

$ curl -s "http://localhost:55679/debug/pipelinez"
```

`tracez` es el collector trazándose *a sí mismo*: muestra qué etapa interna tiene operaciones corriendo (trabadas) y dónde se acumula la latencia. Así distinguís "el exporter está lento" de "el receiver no está recibiendo nada".

### 6.5 Consultar el backend

**Tempo — traer por trace ID:**

```console
$ kubectl -n observability port-forward svc/tempo 3200:3200 >/dev/null 2>&1 &
$ curl -s "http://localhost:3200/api/traces/5b8efff798038103d269b633813fc60c" \
    | jq '.batches[].scopeSpans[].spans[] | {name, spanId, parentSpanId, kind}'
{
  "name": "GET /checkout",
  "spanId": "a1b2c3d4e5f60718",
  "parentSpanId": "",
  "kind": "SPAN_KIND_SERVER"
}
{
  "name": "POST /api/payment",
  "spanId": "e5f60718293a4b5c",
  "parentSpanId": "a1b2c3d4e5f60718",
  "kind": "SPAN_KIND_CLIENT"
}
```

**Tempo — TraceQL:**

```console
$ curl -sG "http://localhost:3200/api/search" \
    --data-urlencode 'q={ resource.service.name = "checkout" && span.http.response.status_code >= 500 } | select(span.http.route)' \
    --data-urlencode 'limit=5' \
    --data-urlencode 'start=1756896000' \
    --data-urlencode 'end=1756899600' | jq '.traces[] | {traceID, rootServiceName, durationMs}'
{
  "traceID": "60d0d0c9d5b7a1e1b8a2c3d4e5f60718",
  "rootServiceName": "frontend",
  "durationMs": 4127
}
{
  "traceID": "71e1e1dae6c8b2f2c9b3d4e5f6071829",
  "rootServiceName": "frontend",
  "durationMs": 3980
}
```

Modismos útiles de TraceQL:

```traceql
{ duration > 2s && resource.service.name = "payments" }
{ span.db.system.name = "postgresql" && span.db.query.text =~ ".*ORDER BY.*" }
{ status = error } && { resource.k8s.namespace.name = "shop" }
{ resource.service.name = "checkout" } >> { resource.service.name = "acquirer" }   # descendant
count() by (resource.service.name) | select(span.http.route)
```

**Jaeger — API de consulta:**

```console
$ curl -s "http://localhost:16686/api/services" | jq -r '.data[]'
frontend
cart
checkout
payments
inventory
jaeger-all-in-one

$ curl -s "http://localhost:16686/api/traces?service=checkout&operation=POST%20%2Fapi%2Fpayment&limit=2&lookback=1h&minDuration=1500ms" \
    | jq '.data[] | {traceID, spanCount: (.spans | length), duration: (.spans[0].duration)}'
{
  "traceID": "60d0d0c9d5b7a1e1b8a2c3d4e5f60718",
  "spanCount": 14,
  "duration": 4127311
}

$ curl -s "http://localhost:16686/api/dependencies?endTs=$(date +%s000)&lookback=3600000" \
    | jq -r '.data[] | "\(.parent) -> \(.child)  (\(.callCount))"'
frontend -> cart  (18422)
frontend -> checkout  (9130)
checkout -> payments  (9128)
payments -> inventory  (9128)
```

### 6.6 Verificar la propagación en el cable

Esta es la prueba definitiva para "por qué mi trace está partido en dos":

```console
$ kubectl -n shop exec -it deploy/frontend -- \
    curl -sv http://checkout.shop.svc.cluster.local:8080/api/order \
      -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
      -o /dev/null 2>&1 | grep -i -E 'traceparent|tracestate|b3|uber'
> traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
< traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-2f1a9b3c4d5e6f70-01
```

El `traceparent` de la respuesta mantiene el mismo `trace-id` y lleva un `parent-id` *nuevo* — la propagación funciona. Si el request saliente de `checkout` hacia `payments` lleva un **trace-id distinto**, el contexto se perdió dentro de `checkout`.

Inspeccioná qué emite realmente un servicio, sin backend:

```console
$ kubectl -n shop exec -it deploy/checkout -- \
    env | grep -E '^OTEL_'
OTEL_SERVICE_NAME=checkout
OTEL_EXPORTER_OTLP_ENDPOINT=http://10.42.3.17:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.05
OTEL_PROPAGATORS=tracecontext,baggage,b3multi
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,service.version=3.4.1,k8s.pod.uid=8c1b...
```

### 6.7 Catálogo de fallas

| Síntoma | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| **Cero traces en todos lados** | Puerto/protocolo mal apareados | El SDK loguea `connection refused` en 4317 mientras el collector sirve solo 4318 | Hacé coincidir `OTEL_EXPORTER_OTLP_PROTOCOL` con el puerto: `grpc`→4317, `http/protobuf`→4318 |
| **Cero traces, sin error del SDK** | `OTEL_SDK_DISABLED=true`, o el sampler es `always_off` | `env \| grep OTEL_` dentro del pod | Corregí las variables de entorno |
| **HTTP 404 desde el collector** | A `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` le falta `/v1/traces` | `curl -i` muestra `404 Not Found` | Agregá el path, o cambiá a la variable base `OTEL_EXPORTER_OTLP_ENDPOINT` |
| **`no such host` / `unsupported scheme`** | Endpoint dado sin `http://` | Log del SDK: `parse "otel-agent:4318": first path segment in URL cannot contain colon` | Incluí siempre el esquema |
| **Traces partidos en fragmentos; cada servicio tiene su propio trace-id** | Desajuste de propagators (el servicio A inyecta W3C, B extrae solo B3) | Comparación de headers con `curl -v` (§6.6) | Poné `OTEL_PROPAGATORS` como un superconjunto en cada servicio durante la migración |
| **El trace se corta en un salto específico** | Un reverse proxy / WAF elimina headers desconocidos | Compará los headers antes y después del proxy | Permitir explícitamente `traceparent`, `tracestate`, `baggage`, `b3` en el proxy |
| **El trace reinicia después de una cola** | El contexto no se transporta en los headers del mensaje | El span consumidor tiene `parentSpanId` vacío | Inyectar/extraer en los headers del mensaje (§5.7) |
| **El trace reinicia después de un thread pool / `asyncio.create_task`** | El contexto es local al hilo/tarea y no se copia | Aparecen spans raíz en medio del request | Usá el wrapper de executor consciente del contexto del SDK, o `context.attach()` explícitamente |
| **Solo ~5% de los traces, y cada uno incompleto** | `traceidratio` independiente por servicio en lugar de `parentbased_*` | Los ratios de sampling difieren entre servicios | Estandarizá en `parentbased_traceidratio` con un argumento idéntico |
| **Los traces lentos son exactamente los que faltan** | `tail_sampling.decision_wait` más corto que la latencia p99 | `otelcol_processor_tail_sampling_sampling_trace_dropped_too_early` > 0 | Subí `decision_wait` por encima del p99.9 |
| **El tail sampling se queda con fragmentos aleatorios** | Spans de un mismo trace llegando a réplicas distintas del gateway | Cada réplica del gateway tiene traces parciales | Usá el exporter `loadbalancing` con `routing_key: traceID` delante del nivel de gateway |
| **Spans con duraciones negativas o imposibles; el hijo empieza antes que el padre** | Clock skew entre nodos | `chronyc tracking` muestra offsets de decenas de ms | Imponé NTP/chrony; la UI de Jaeger aplica ajuste de clock skew, no te apoyes en eso |
| **El collector muere por OOM repetidamente** | `GOMEMLIMIT` sin definir, o `tail_sampling.num_traces` demasiado alto | `kubectl describe pod` → `Reason: OOMKilled`, exit code 137 | Poné `GOMEMLIMIT` en ~80% del límite; agregá `memory_limiter`; reducí `num_traces` |
| **`refused_spans` subiendo bajo carga** | `memory_limiter` haciendo su trabajo | `otelcol_processor_refused_spans_total` > 0 | Escalá horizontalmente las réplicas del gateway; los reintentos del SDK cubren el hueco |
| **`send_failed_spans` subiendo** | Backend caído / TLS / autenticación | Log del collector: `Exporting failed. Will retry ... rpc error: code = Unavailable` | Arreglá el backend; habilitá `sending_queue.storage` para que un reinicio no sea un evento de pérdida de datos |
| **gRPC a través del Ingress falla, HTTP funciona** | El proxy L7 usa HTTP/1.1 por defecto | `502` o `UNAVAILABLE` solo en 4317 | `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"`, asegurá HTTP/2 de punta a punta |
| **Explosión de series de Prometheus tras habilitar `spanmetrics`** | Dimensión de alta cardinalidad (URL cruda, user id) | `prometheus_tsdb_head_series` salta en millones | Usá `http.route`, nunca `url.full`; podá `dimensions`; definí `dimensions_cache_size` |
| **Todo es `ERROR`, el presupuesto de sampling se fue** | 4xx marcados como error de span | `tail_sampling` retiene ~40% del tráfico | Poné `StatusCode.ERROR` solo para fallas del lado del servidor |
| **El trace ID es todo ceros** | Contexto inválido/ausente; span creado fuera de un provider | `00000000000000000000000000000000` en los logs | Verificá que el `TracerProvider` esté registrado antes del primer span |
| **Traces en Grafana pero "trace not found" desde un enlace de log** | El trace ID del log fue emitido por un entorno/tenant *distinto*, o el trace fue descartado por sampling | Buscá el ID crudo directamente en Tempo | Logueá también el flag sampled; considerá `local-blocks` / mayor sampling de línea base |

### 6.8 Correlacionar las tres señales

La recompensa del tracing no es el flame graph — es la **navegación**. Cableá los identificadores de modo que cualquier señal salte a las otras dos.

**Logs → traces:** inyectá `trace_id` y `span_id` en cada línea de log.

```console
$ kubectl -n shop logs deploy/checkout --tail=1 | jq .
{
  "ts": "2026-09-03T09:41:07.512Z",
  "level": "error",
  "logger": "shop.checkout",
  "msg": "payment authorization timed out",
  "trace_id": "60d0d0c9d5b7a1e1b8a2c3d4e5f60718",
  "span_id": "0718293a4b5c6d7e",
  "trace_flags": "01",
  "service.name": "checkout"
}
```

**Métricas → traces:** exemplars. El connector `spanmetrics` adjunta un trace ID a los buckets del histograma, así que un pico de p99 en Grafana está a un clic de un trace de ejemplo que lo produjo.

```console
$ curl -s http://localhost:8889/metrics | grep -A0 'traces_span_metrics_duration_bucket' | head -2
traces_span_metrics_duration_milliseconds_bucket{service_name="payments",span_name="POST /api/payment",http_route="/api/payment",le="2000"} 4821 # {trace_id="60d0d0c9d5b7a1e1b8a2c3d4e5f60718",span_id="f60718293a4b5c6d"} 1873.4 1756899667.512
```

Prometheus debe arrancarse con `--enable-feature=exemplar-storage`, y el datasource Tempo de Grafana necesita `tracesToLogs` / `tracesToMetrics` configurados para que los enlaces se rendericen.

**Cableado del datasource de Grafana:**

```yaml
apiVersion: 1
datasources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo.observability.svc.cluster.local:3200
    jsonData:
      httpMethod: GET
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: '-5m'
        spanEndTimeShift: '5m'
        filterByTraceID: true
        filterBySpanID: false
        tags:
          - key: service.name
            value: service_name
      tracesToMetrics:
        datasourceUid: prometheus
        spanStartTimeShift: '-2m'
        spanEndTimeShift: '2m'
        tags:
          - key: service.name
            value: service_name
        queries:
          - name: 'Request rate'
            query: 'sum(rate(traces_span_metrics_calls_total{$$__tags}[5m]))'
      serviceMap:
        datasourceUid: prometheus
      nodeGraph:
        enabled: true
      lokiSearch:
        datasourceUid: loki
```

### 6.9 Una checklist de verificación que podés correr en cualquier cluster

```bash
#!/usr/bin/env bash
# verify-tracing.sh — end-to-end health check of the tracing pipeline.
set -euo pipefail

NS=observability
FAIL=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [ OK ] %s\n' "$name"
  else
    printf '  [FAIL] %s\n' "$name"
    FAIL=1
  fi
}

echo "== 1. Collector pods are ready =="
kubectl -n "$NS" get pods -l app.kubernetes.io/name=otel-agent \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

echo "== 2. Config validates =="
check "agent config" kubectl -n "$NS" exec ds/otel-agent -- \
  /otelcol-contrib validate --config=file:/conf/config.yaml

echo "== 3. Receivers accepting spans =="
ACCEPTED=$(kubectl -n "$NS" exec ds/otel-agent -- \
  wget -qO- http://localhost:8888/metrics |
  awk '/^otelcol_receiver_accepted_spans_total/ {s+=$2} END {print s+0}')
echo "  accepted spans: ${ACCEPTED}"
[ "${ACCEPTED}" -gt 0 ] || { echo "  [FAIL] no spans accepted"; FAIL=1; }

echo "== 4. No refusals, no export failures =="
for m in otelcol_receiver_refused_spans_total \
         otelcol_processor_refused_spans_total \
         otelcol_exporter_send_failed_spans_total; do
  V=$(kubectl -n "$NS" exec ds/otel-agent -- wget -qO- http://localhost:8888/metrics |
      awk -v pat="^${m}" '$0 ~ pat {s+=$2} END {print s+0}')
  printf '  %-45s %s\n' "$m" "$V"
  [ "$V" = "0" ] || FAIL=1
done

echo "== 5. Backend round-trip =="
TRACE_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
NOW_NS=$(( $(date +%s) * 1000000000 ))
kubectl -n "$NS" exec deploy/otel-gateway -- sh -c "cat > /tmp/s.json <<EOF
{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verify-script\"}}]},
\"scopeSpans\":[{\"spans\":[{\"traceId\":\"${TRACE_ID}\",\"spanId\":\"$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')\",
\"name\":\"verify\",\"kind\":1,\"startTimeUnixNano\":\"${NOW_NS}\",\"endTimeUnixNano\":\"$((NOW_NS + 1000000))\",
\"status\":{\"code\":2}}]}]}]}
EOF
wget -qO- --post-file=/tmp/s.json --header='Content-Type: application/json' \
  http://localhost:4318/v1/traces"

sleep 10
check "trace ${TRACE_ID} retrievable from Tempo" \
  kubectl -n "$NS" exec deploy/otel-gateway -- \
  wget -qO- "http://tempo:3200/api/traces/${TRACE_ID}"

exit "$FAIL"
```

```console
$ ./verify-tracing.sh
== 1. Collector pods are ready ==
otel-agent-4zk7p	Running
otel-agent-8mq2r	Running
otel-agent-bt9wl	Running
== 2. Config validates ==
  [ OK ] agent config
== 3. Receivers accepting spans ==
  accepted spans: 1284933
== 4. No refusals, no export failures ==
  otelcol_receiver_refused_spans_total          0
  otelcol_processor_refused_spans_total         0
  otelcol_exporter_send_failed_spans_total      0
== 5. Backend round-trip ==
{"partialSuccess":{}}
  [ OK ] trace 9c4e1a7b3f8d2065e1a7b3f8d2065e1a retrievable from Tempo
$ echo $?
0
```

---

## 7. Resumen para el examen

**Los conceptos que cargan el peso de este objetivo:**

- **Trace / span / span context** — un trace es un DAG de spans que comparten un `trace_id`; cada span tiene un `span_id` único y un `parent_span_id` (vacío en la raíz).
- **W3C Trace Context** — `traceparent: {version}-{trace-id}-{parent-id}-{trace-flags}` más `tracestate`. El bit 0 de `trace-flags` es el flag sampled. `baggage` es un header separado para pares clave/valor definidos por el usuario.
- **OpenTelemetry** es el estándar de la CNCF para la *generación y el transporte* de traces (y métricas y logs); no es un backend de almacenamiento. **OTLP** es su protocolo de cable: gRPC en 4317, HTTP en 4318 (`/v1/traces`).
- **Jaeger** y **Zipkin** son backends; **Grafana Tempo** es un backend optimizado para object storage y búsqueda por trace-ID, consultado con **TraceQL**.
- **El Collector** desacopla las aplicaciones de los backends y es donde vive la política central: enriquecimiento (`k8sattributes`), redacción (`transform`), sampling (`tail_sampling`), batching (`batch`) y protección de memoria (`memory_limiter`).
- **El head sampling** decide en la raíz, barato, ciego al resultado. **El tail sampling** decide en el gateway después de que el trace está completo — puede quedarse con todos los errores y todos los requests lentos, pero requiere ruteo afín al trace y memoria significativa.
- **La instrumentación** es automática (inyección por agente/operator) para las fronteras de framework y manual para las operaciones con significado de negocio. La auto-instrumentación se rompe sistemáticamente en fronteras asincrónicas — colas, thread pools, tareas en segundo plano — donde el contexto debe inyectarse y extraerse explícitamente.
- **Los nombres de span deben ser de baja cardinalidad; los atributos de span pueden ser de alta cardinalidad.** Esto es lo inverso de la regla de métricas y el error de diseño más común.

---

## 8. Referencias

**Objetivos del examen**
- LPI DevOps Tools Engineer, Exam 701 objectives — https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI DevOps Tools Engineer certification overview — https://www.lpi.org/our-certifications/devops-overview/

**Estándares**
- W3C Trace Context (Recommendation) — https://www.w3.org/TR/trace-context/
- W3C Baggage — https://www.w3.org/TR/baggage/
- OpenTelemetry Protocol (OTLP) specification — https://opentelemetry.io/docs/specs/otlp/
- OpenTelemetry Tracing API/SDK specification — https://opentelemetry.io/docs/specs/otel/trace/api/
- OpenTelemetry Semantic Conventions — https://opentelemetry.io/docs/specs/semconv/
- OpenTelemetry SDK environment variables — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/

**OpenTelemetry**
- Documentation home — https://opentelemetry.io/docs/
- Collector configuration — https://opentelemetry.io/docs/collector/configuration/
- Collector deployment patterns (agent / gateway) — https://opentelemetry.io/docs/collector/deployment/
- Collector troubleshooting — https://opentelemetry.io/docs/collector/troubleshooting/
- Sampling concepts — https://opentelemetry.io/docs/concepts/sampling/
- Contrib components (`tail_sampling`, `k8sattributes`, `loadbalancing`, `spanmetrics`, `servicegraph`) — https://github.com/open-telemetry/opentelemetry-collector-contrib
- OpenTelemetry Operator — https://github.com/open-telemetry/opentelemetry-operator
- Zero-code instrumentation — https://opentelemetry.io/docs/zero-code/

**Backends**
- Jaeger documentation — https://www.jaegertracing.io/docs/
- Jaeger v2 architecture — https://www.jaegertracing.io/docs/latest/architecture/
- Jaeger deployment and storage backends — https://www.jaegertracing.io/docs/latest/deployment/
- Zipkin — https://zipkin.io/ and API — https://zipkin.io/zipkin-api/
- Grafana Tempo — https://grafana.com/docs/tempo/latest/
- TraceQL language reference — https://grafana.com/docs/tempo/latest/traceql/
- Tempo metrics-generator — https://grafana.com/docs/tempo/latest/metrics-generator/

**Ecosistema**
- CNCF Observability Landscape — https://landscape.cncf.io/
- Prometheus exemplars — https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- Envoy tracing (mesh-level propagation) — https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/observability/tracing
- Istio distributed tracing — https://istio.io/latest/docs/tasks/observability/distributed-tracing/