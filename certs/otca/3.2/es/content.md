# 3.2 Deployment — El OpenTelemetry Collector en producción

> Dominio 3: El OpenTelemetry Collector · Tema 3.2 · Peso en el examen ≈ 5.2%
> Nivel: SRE / Arquitecto de plataforma — mecánica interna, compromisos de diseño, manifests completos, diagnóstico.

---

## 1. Motivación: el problema arquitectónico

La topología de observabilidad ingenua es **SDK → backend**: cada proceso instrumentado abre una conexión directa a Jaeger, Prometheus, Tempo o un endpoint de un proveedor. Funciona en una laptop y colapsa en una flota. Los modos de falla son estructurales, no accidentales:

- **Acoplamiento al backend.** Las URLs de endpoint, los tokens de autenticación, la política de sampling y el dialecto de protocolo quedan incrustados en cada workload. Rotar una credencial o cambiar de proveedor se vuelve un redespliegue de toda la flota. El destino de la telemetría es una decisión de tiempo de despliegue cuando debería ser una decisión operativa.
- **Sin buffering ni aislamiento de back-pressure.** Cuando el backend está lento o caído, la cola de reintentos del exporter vive *dentro del proceso de la aplicación*. Un corte de telemetría se convierte en un evento de presión de memoria de la aplicación. No hay mamparo (bulkhead).
- **Amplificación de egreso y cardinalidad.** N pods mantienen cada uno streams gRPC de larga duración hacia el backend, cada uno emitiendo datos sin batch, sin filtrar y de alta cardinalidad. El egreso cross-AZ/cross-region se factura por byte, y el backend ve N× la cantidad de conexiones que necesita.
- **Dispersión de credenciales.** Cada pod tiene credenciales de escritura del backend. El radio de impacto de un token filtrado es toda la flota.
- **Sin lugar para enriquecer o redactar.** Los metadatos de k8s (`pod.name`, `node`, `deployment`), el enrutamiento por tenant, el scrubbing de PII y el tail-based sampling requieren un punto de observación *stateful y centralizado* que un SDK por proceso no puede proveer.

El **Collector** es la respuesta: un **plano de control de telemetría** neutral respecto al proveedor — un pipeline de `receivers → processors/connectors → exporters` — que desacopla *lo que produce* telemetría de *lo que la almacena*. Instrumentá una sola vez contra OTLP; cambiá destinos, sampling y enriquecimiento en el Collector sin tocar un solo workload.

**El Tema 3.2 trata sobre *dónde ejecutás ese Collector*** — los patrones de despliegue, las distribuciones que entregás, las topologías de Kubernetes, y cómo las verificás y escalás.

---

## 2. Comparación de patrones de despliegue

OpenTelemetry define tres patrones canónicos. No son mutuamente excluyentes — en producción normalmente se **superponen agent + gateway**.

| Patrón | Dónde corre | Cardinalidad de Collectors | ¿Agrega salto de latencia? | Propósito principal | Riesgo principal |
|---|---|---|---|---|---|
| **Sin Collector** | En ningún lado — el SDK exporta directo | 0 | No | Prototipado, serverless sin acceso al host | Todos los problemas de acoplamiento/credenciales del §1 |
| **Agent — sidecar** | Un contenedor **por pod** | = cantidad de pods | No (localhost) | Aislamiento por workload, config por tenant, buffer local garantizado | Mayor overhead; el costo de recursos escala con los pods |
| **Agent — DaemonSet** | Un pod **por nodo** | = cantidad de nodos | No (node-local) | Métricas de host, tailing de logs (`filelog`), `kubeletstats`, descargar el batching de las apps | Radio de impacto node-local; noisy-neighbor entre pods del nodo |
| **Gateway** | `Deployment`/`StatefulSet` independiente detrás de un `Service` | Independiente (escalado por HPA) | Sí (salto de red) | Egreso central, tail sampling, enrutamiento por tenant, concentración de credenciales, rate limiting | Es un cuello de botella; necesita HA + autoscaling |

### La topología de producción en capas

```
┌────────────┐    OTLP     ┌────────────────┐    OTLP     ┌──────────────────┐   remote
│ App + SDK  │ ──localhost─▶│ Agent          │ ──cluster──▶│ Gateway          │ ─────────▶ Backend(s)
│ (no creds) │             │ (DaemonSet)    │             │ (Deployment/STS) │           Tempo/Mimir/
└────────────┘             │ batch, k8sattr │             │ tail_sampling,   │           vendor
                           │ hostmetrics    │             │ auth, routing    │
                           └────────────────┘             └──────────────────┘
```

- **Agent (DaemonSet)** recolecta señales node-local (métricas de host, logs de contenedores), adjunta metadatos de k8s de forma barata (sabe qué pods están en su nodo), hace el batching de primera pasada, y reenvía al gateway. Las apps **no** tienen credenciales del backend.
- **Gateway (Deployment/StatefulSet)** es la única capa con credenciales de egreso. Es dueña de las decisiones caras y stateful — **tail-based sampling**, enrutamiento multi-tenant, fan-out a los backends — y escala independientemente del workload.

**Heurísticas de decisión**

- ¿Necesitás `filelog`, `hostmetrics` o `kubeletstats`? → necesitás un **agent DaemonSet** (los datos node-scoped no se pueden recolectar desde un Deployment central).
- ¿Necesitás **tail sampling** o decisiones por traza? → necesitás un **gateway**, y el tráfico hacia él debe enrutarse **de forma trace-ID-aware** (ver §4.3), de lo contrario las decisiones se corren sobre trazas parciales.
- ¿Aislamiento estricto por pod / config de Collector por tenant / garantía dura de un buffer local incluso si el pod del DaemonSet es desalojado? → **sidecar**, aceptando el overhead.

---

## 3. Distribuciones: ¿qué binario entregás realmente?

El Collector es un conjunto de módulos Go ensamblados en tiempo de build. Nunca entregás "el Collector" — entregás una **distribución** con un conjunto de componentes fijo.

| Distribución | Binario | Conjunto de componentes | Cuándo usarla |
|---|---|---|---|
| **Core** | `otelcol` | OTLP + un conjunto mínimo y estable | Solo hablás OTLP de punta a punta |
| **Contrib** | `otelcol-contrib` | ~todo (todos los exporters de proveedores, `filelog`, `k8sattributes`, `tail_sampling`, `spanmetrics`…) | Para empezar, dev, "todo incluido" |
| **Custom (OCB)** | `otelcol-custom` | Exactamente los componentes que listás | **Producción**: superficie de ataque mínima, imagen más chica, sin receivers no usados abiertos |
| **k8s** | `otelcol-k8s` | Curada para Kubernetes (usada por los defaults de Helm) | Despliegues de Kubernetes |

**¿Por qué no correr contrib en todos lados?** Contrib incluye todos los receivers — cada uno es un listener abierto o un scrape target y parte de tu superficie de ataque, más superficie de cadena de suministro y tamaño de imagen. Producción se endurece construyendo una **distribución custom** con el **OpenTelemetry Collector Builder (OCB / `builder`)** que contenga solo lo que tus pipelines referencian.

### Manifest de build de OCB (`builder-config.yaml`) — completo

```yaml
dist:
  name: otelcol-custom
  description: Hardened OTel Collector for gateway tier
  output_path: ./_build
  otelcol_version: 0.115.0

# Core components live under go.opentelemetry.io/collector/...
# Contrib components under github.com/open-telemetry/opentelemetry-collector-contrib/...
receivers:
  - gomod: go.opentelemetry.io/collector/receiver/otlpreceiver v0.115.0

processors:
  - gomod: go.opentelemetry.io/collector/processor/memorylimiterprocessor v0.115.0
  - gomod: go.opentelemetry.io/collector/processor/batchprocessor v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/k8sattributesprocessor v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/resourcedetectionprocessor v0.115.0

exporters:
  - gomod: go.opentelemetry.io/collector/exporter/otlpexporter v0.115.0
  - gomod: go.opentelemetry.io/collector/exporter/debugexporter v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/exporter/loadbalancingexporter v0.115.0

extensions:
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/extension/healthcheckextension v0.115.0
  - gomod: go.opentelemetry.io/collector/extension/zpagesextension v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/extension/pprofextension v0.115.0
```

```console
$ builder --config builder-config.yaml
2026-02-10T14:03:11.204Z  INFO  internal/command.go:60  OpenTelemetry Collector Builder  {"version": "0.115.0"}
2026-02-10T14:03:11.205Z  INFO  internal/command.go:83  Using config file  {"path": "builder-config.yaml"}
2026-02-10T14:03:11.206Z  INFO  builder/config.go:142   Using go  {"go-executable": "/usr/local/go/bin/go"}
2026-02-10T14:03:11.210Z  INFO  builder/main.go:76      Sources created  {"path": "./_build"}
2026-02-10T14:03:17.882Z  INFO  builder/main.go:108     Getting go modules
2026-02-10T14:03:24.011Z  INFO  builder/main.go:87      Compiling
2026-02-10T14:03:41.559Z  INFO  builder/main.go:94      Compiled  {"binary": "./_build/otelcol-custom"}

$ ./_build/otelcol-custom components | head -n 20
buildinfo:
    command: otelcol-custom
    description: Hardened OTel Collector for gateway tier
    version: 0.115.0
receivers:
    - otlp
processors:
    - memory_limiter
    - batch
    - k8sattributes
    - tail_sampling
    - resourcedetection
exporters:
    - otlp
    - debug
    - loadbalancing
```

---

## 4. Manifests

Todos los ejemplos asumen el namespace `observability`. Cada pipeline sigue la regla de oro: **`memory_limiter` es el primer processor; `batch` es el último antes del exporter.**

### 4.1 Agent — DaemonSet (Kubernetes crudo)

Recolección node-local: métricas de host, logs de contenedores, enriquecimiento de k8s, reenvío al gateway.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-agent
  namespace: observability
---
# k8sattributes needs to read pods/namespaces cluster-wide.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "watch", "list"]
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
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-conf
  namespace: observability
data:
  relay: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      hostmetrics:
        collection_interval: 30s
        root_path: /hostfs
        scrapers:
          cpu: {}
          memory: {}
          load: {}
          filesystem: {}
          network: {}
      filelog:
        include: [ /var/log/pods/*/*/*.log ]
        include_file_path: true
        start_at: end
        operators:
          - type: container
            id: container-parser

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          # Only look at pods on THIS node — cheap, node-scoped watch.
          node_from_env_var: KUBE_NODE_NAME
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.node.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection
      batch:
        send_batch_size: 8192
        send_batch_max_size: 10000
        timeout: 5s

    exporters:
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
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

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 0.0.0.0:55679

    service:
      extensions: [health_check, zpages]
      telemetry:
        metrics:
          level: detailed
          address: 0.0.0.0:8888
        logs:
          level: info
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp]
        metrics:
          receivers: [otlp, hostmetrics]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels: { app: otel-agent }
spec:
  selector:
    matchLabels: { app: otel-agent }
  template:
    metadata:
      labels: { app: otel-agent }
    spec:
      serviceAccountName: otel-agent
      containers:
        - name: otel-agent
          image: otel/opentelemetry-collector-contrib:0.115.0
          args: ["--config=/conf/relay.yaml"]
          env:
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
          ports:
            - { name: otlp-grpc, containerPort: 4317, hostPort: 4317, protocol: TCP }
            - { name: otlp-http, containerPort: 4318, hostPort: 4318, protocol: TCP }
            - { name: metrics,   containerPort: 8888, protocol: TCP }
          resources:
            requests: { cpu: 100m, memory: 200Mi }
            limits:   { cpu: 500m, memory: 500Mi }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: config,   mountPath: /conf }
            - { name: hostfs,   mountPath: /hostfs, readOnly: true }
            - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
      volumes:
        - name: config
          configMap:
            name: otel-agent-conf
            items: [{ key: relay, path: relay.yaml }]
        - name: hostfs
          hostPath: { path: / }
        - name: varlogpods
          hostPath: { path: /var/log/pods }
      tolerations:
        - operator: Exists   # run on every node, including tainted control-plane nodes
```

> `limit_percentage`/`spike_limit_percentage` se leen contra el **límite de cgroup** que ve el contenedor, así que el `memory_limiter` se autoajusta si redimensionás el pod. Mantené el `limits.memory` del contenedor un poco por encima del límite blando (soft limit) para que el limiter reaccione *antes* de que lo haga el OOM killer.

### 4.2 Gateway — Deployment + Service + HPA

Capa de fan-out sin estado. Escala horizontalmente con el HPA.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-conf
  namespace: observability
data:
  relay: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch:
        send_batch_size: 8192
        send_batch_max_size: 10000
        timeout: 5s

    exporters:
      otlp/backend:
        endpoint: tempo-distributor.tracing.svc.cluster.local:4317
        tls: { insecure: true }
        sending_queue: { enabled: true, num_consumers: 20, queue_size: 10000 }
        retry_on_failure: { enabled: true }
      debug:
        verbosity: normal

    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }

    service:
      extensions: [health_check]
      telemetry:
        metrics: { level: detailed, address: 0.0.0.0:8888 }
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/backend]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability
  labels: { app: otel-gateway }
spec:
  replicas: 3
  selector:
    matchLabels: { app: otel-gateway }
  template:
    metadata:
      labels: { app: otel-gateway }
    spec:
      containers:
        - name: otel-gateway
          image: otel/opentelemetry-collector-contrib:0.115.0
          args: ["--config=/conf/relay.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
          resources:
            requests: { cpu: 500m, memory: 1Gi }
            limits:   { cpu: "2",  memory: 2Gi }
          livenessProbe:  { httpGet: { path: /, port: 13133 } }
          readinessProbe: { httpGet: { path: /, port: 13133 } }
          volumeMounts:
            - { name: config, mountPath: /conf }
      volumes:
        - name: config
          configMap:
            name: otel-gateway-conf
            items: [{ key: relay, path: relay.yaml }]
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability
spec:
  selector: { app: otel-gateway }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317, protocol: TCP }
    - { name: otlp-http, port: 4318, targetPort: 4318, protocol: TCP }
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
  maxReplicas: 15
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
    - type: Resource
      resource:
        name: memory
        target: { type: Utilization, averageUtilization: 75 }
```

> **gRPC + un `Service` `ClusterIP` balancean conexiones, no requests.** gRPC multiplexa sobre una única conexión HTTP/2 de larga duración, así que kube-proxy fija cada agent a un único pod del gateway. Se soluciona con un `Service` headless + round-robin del lado del cliente, un mesh L7 (Envoy/Linkerd), o el exporter `loadbalancing` (§4.3). De lo contrario, un gateway escalado ve carga desbalanceada.

### 4.3 Gateway trace-aware para tail sampling — StatefulSet + exporter `loadbalancing`

**El problema:** `tail_sampling` tiene que ver *cada span de una traza* para decidir. Si los spans de una traza caen en réplicas distintas del gateway, cada una decide sobre una traza parcial → sampling roto. **La solución:** un gateway de dos capas. La capa 1 enruta por trace ID con el exporter `loadbalancing` hacia un Service **headless**; la capa 2 (un `StatefulSet`) corre `tail_sampling`, garantizando que todos los spans de una traza lleguen al mismo pod.

```yaml
# ---------- Layer 1: routing gateway (Deployment) ----------
apiVersion: v1
kind: ConfigMap
metadata: { name: otel-router-conf, namespace: observability }
data:
  relay: |
    receivers:
      otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } }
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
    exporters:
      loadbalancing:
        routing_key: traceID        # consistent hashing per trace
        protocol:
          otlp:
            tls: { insecure: true }
        resolver:
          k8s:
            service: otel-sampler-headless.observability
            ports: [4317]
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter]
          exporters: [loadbalancing]
---
# ---------- Layer 2: sampling gateway (StatefulSet) ----------
apiVersion: v1
kind: ConfigMap
metadata: { name: otel-sampler-conf, namespace: observability }
data:
  relay: |
    receivers:
      otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } }
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
      tail_sampling:
        decision_wait: 10s
        num_traces: 100000
        policies:
          - name: errors
            type: status_code
            status_code: { status_codes: [ERROR] }
          - name: slow
            type: latency
            latency: { threshold_ms: 500 }
          - name: baseline-10pct
            type: probabilistic
            probabilistic: { sampling_percentage: 10 }
      batch: { timeout: 5s, send_batch_size: 8192 }
    exporters:
      otlp/backend:
        endpoint: tempo-distributor.tracing.svc.cluster.local:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, tail_sampling, batch]
          exporters: [otlp/backend]
---
apiVersion: v1
kind: Service
metadata: { name: otel-sampler-headless, namespace: observability }
spec:
  clusterIP: None                    # headless: the loadbalancing resolver reads each pod IP
  selector: { app: otel-sampler }
  ports: [{ name: otlp-grpc, port: 4317, targetPort: 4317 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: otel-sampler, namespace: observability }
spec:
  serviceName: otel-sampler-headless
  replicas: 3
  selector: { matchLabels: { app: otel-sampler } }
  template:
    metadata: { labels: { app: otel-sampler } }
    spec:
      containers:
        - name: otel-sampler
          image: otel/opentelemetry-collector-contrib:0.115.0
          args: ["--config=/conf/relay.yaml"]
          ports: [{ containerPort: 4317 }]
          resources:
            requests: { cpu: "1", memory: 2Gi }   # tail_sampling holds traces in RAM — size num_traces × avg trace
            limits:   { cpu: "2", memory: 4Gi }
          volumeMounts: [{ name: config, mountPath: /conf }]
      volumes:
        - name: config
          configMap: { name: otel-sampler-conf, items: [{ key: relay, path: relay.yaml }] }
```

> Escalar el `StatefulSet` del sampler reordena el anillo de hash de `loadbalancing`; el resolver vuelve a leer las IPs de los pods y rebalancea. Dale un `terminationGracePeriodSeconds` generoso para que las trazas en vuelo drenen antes de que muera un pod.

### 4.4 OpenTelemetry Operator — la vía del CRD

El Operator gestiona los Collectors de forma declarativa vía el CRD `OpenTelemetryCollector` (`mode: deployment | daemonset | statefulset | sidecar`) e inyecta sidecars automáticamente. Requiere **cert-manager**.

```console
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.1/cert-manager.yaml
$ kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
$ kubectl -n opentelemetry-operator-system get pods
NAME                                                        READY   STATUS    RESTARTS   AGE
opentelemetry-operator-controller-manager-6b8f9c7d4-jr2kx   2/2     Running   0          41s
```

**Agent DaemonSet vía CRD** (`config` estructurado, API `v1beta1`):

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: agent
  namespace: observability
spec:
  mode: daemonset
  image: otel/opentelemetry-collector-contrib:0.115.0
  resources:
    requests: { cpu: 100m, memory: 200Mi }
    limits:   { cpu: 500m, memory: 500Mi }
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
      batch: {}
    exporters:
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlp] }
        metrics: { receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlp] }
        logs:    { receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlp] }
```

**Inyección de sidecar** — un Collector por workload, habilitado por anotación:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: sidecar
  namespace: apps
spec:
  mode: sidecar
  config:
    receivers: { otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } } }
    processors: { batch: {} }
    exporters:
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces: { receivers: [otlp], processors: [batch], exporters: [otlp] }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: checkout, namespace: apps }
spec:
  replicas: 2
  selector: { matchLabels: { app: checkout } }
  template:
    metadata:
      labels: { app: checkout }
      annotations:
        sidecar.opentelemetry.io/inject: "true"   # operator injects the sidecar Collector here
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:1.7.0
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://localhost:4317        # export to the injected sidecar on localhost
```

```console
$ kubectl -n observability get opentelemetrycollectors
NAME    MODE        VERSION   READY   AGE   IMAGE
agent   daemonset   0.115.0   6/6     3m    otel/opentelemetry-collector-contrib:0.115.0

$ kubectl -n apps get pod -l app=checkout -o jsonpath='{.items[0].spec.containers[*].name}'
checkout otc-container
```

### 4.5 Helm — la vía rápida

El chart `opentelemetry-collector` usa **presets** que se expanden en el RBAC, los mounts y el cableado del pipeline para tareas comunes.

```console
$ helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
$ helm repo update
```

`values-agent.yaml`:

```yaml
mode: daemonset          # daemonset | deployment | statefulset
image:
  repository: otel/opentelemetry-collector-contrib
presets:
  kubernetesAttributes:  { enabled: true }   # wires k8sattributes + RBAC
  hostMetrics:           { enabled: true }
  kubeletMetrics:        { enabled: true }
  logsCollection:        { enabled: true, includeCollectorLogs: false }
resources:
  limits: { cpu: 500m, memory: 500Mi }
config:
  exporters:
    otlp:
      endpoint: otel-gateway.observability.svc.cluster.local:4317
      tls: { insecure: true }
  service:
    pipelines:
      traces:  { exporters: [otlp] }
      metrics: { exporters: [otlp] }
      logs:    { exporters: [otlp] }
```

```console
$ helm upgrade --install otel-agent open-telemetry/opentelemetry-collector \
    -n observability --create-namespace -f values-agent.yaml
Release "otel-agent" does not exist. Installing it now.
NAME: otel-agent
STATUS: deployed
REVISION: 1

$ kubectl -n observability rollout status daemonset/otel-agent
daemon set "otel-agent" successfully rolled out
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Validá la config *antes* de que se despliegue

```console
$ otelcol-contrib validate --config config.yaml
$ echo $?
0
```

Un pipeline malo falla ruidosamente con un error de ruta de componente:

```console
$ otelcol-contrib validate --config broken.yaml
Error: invalid configuration: service::pipelines::traces: references processor "tail_sampling" which is not configured
exit status 1
```

### 5.2 Las cuatro superficies de diagnóstico incorporadas

| Superficie | Extensión / puerto | Qué te dice |
|---|---|---|
| **Health** | `health_check` :13133 | ¿Está el Collector arriba y sus pipelines corriendo? (alimenta los probes de k8s) |
| **Pipeline en vivo** | `zpages` :55679 `/debug/tracez`, `/debug/pipelinez` | Muestras de span/error por componente, cableado del pipeline, en vivo |
| **Profiling** | `pprof` :1777 | Perfiles de CPU/heap/goroutine para leaks y hot paths |
| **Métricas internas** | `service.telemetry.metrics` :8888 (`/metrics`) | Las propias métricas Prometheus del Collector — la fuente de verdad |

```console
$ kubectl -n observability port-forward daemonset/otel-agent 13133:13133 8888:8888 55679:55679
$ curl -s localhost:13133 | jq .
{ "status": "Server available", "upSince": "2026-02-10T14:20:03Z", "uptime": "12m4s" }
```

### 5.3 Las métricas internas que realmente importan

Hacé scrape de `:8888/metrics`. Estas son tu primera parada ante cualquier incidente de pipeline:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|exporter|processor)_' | grep -v '^#'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1.284551e+06
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_processor_refused_spans{processor="memory_limiter"} 0
otelcol_exporter_sent_spans{exporter="otlp"} 1.284551e+06
otelcol_exporter_send_failed_spans{exporter="otlp"} 0
otelcol_exporter_queue_size{exporter="otlp"} 12
otelcol_exporter_queue_capacity{exporter="otlp"} 5000
otelcol_exporter_enqueue_failed_spans{exporter="otlp"} 0
```

**Leélas como ratios:**
- `receiver_refused_*` subiendo → el back-pressure llegó al receiver (normalmente `memory_limiter` aguas arriba).
- `processor_refused_spans{processor="memory_limiter"}` > 0 → el limiter está descartando carga; **estás perdiendo datos**.
- `exporter_send_failed_*` > 0 → el backend está rechazando/inalcanzable.
- `exporter_queue_size` acercándose a `queue_capacity` → el sink es más lento que la fuente; `enqueue_failed_*` empieza y los datos se pierden a continuación.

### 5.4 Probá el camino de punta a punta con `telemetrygen`

```console
$ kubectl -n observability port-forward daemonset/otel-agent 4317:4317 &
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 5
2026-02-10T14:33:09Z  INFO  traces/traces.go:58  generation of traces isn't being throttled
2026-02-10T14:33:09Z  INFO  traces/worker.go:96  traces generated  {"worker": 0, "traces": 5}
2026-02-10T14:33:09Z  INFO  traces/traces.go:83  stop the batch span processor
```

Confirmá que se movieron (un exporter `debug` es el chequeo de sanidad más rápido):

```console
$ kubectl -n observability logs daemonset/otel-agent | grep -i 'TracesExporter\|spans'
2026-02-10T14:33:10.114Z  info  TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 5, "spans": 5}
```

### 5.5 Playbook de fallas

| Síntoma (log / métrica) | Causa raíz | Solución |
|---|---|---|
| `data refused due to high memory usage` · `otelcol_processor_refused_spans{memory_limiter}` subiendo | Ingesta > procesamiento/egreso; el limiter descarta para evitar OOM | Agregá réplicas de gateway / subí el HPA; subí el `memory` limit del contenedor **y** `limit_percentage`; asegurate de que `batch` no esté configurado demasiado grande |
| Pod `OOMKilled` **sin** rechazos del limiter | `memory_limiter` faltante/último en el pipeline, o soft limit ≥ límite de cgroup | Poné `memory_limiter` **primero**; mantené `limits.memory` por encima del soft limit para que dispare primero |
| `sending_queue is full` · `otelcol_exporter_enqueue_failed_spans` > 0 | Backend más lento que la ingesta; cola saturada | Subí `sending_queue.queue_size` / `num_consumers`; agregá una **cola persistente** vía la extensión `file_storage` para que los reinicios no pierdan datos; escalá el backend |
| `Permanent error ... rpc error: code = InvalidArgument` — nunca reintentado | El backend rechaza el payload (schema/tenant header). Permanente ≠ transitorio → descartado inmediatamente | Corregí headers/tenant/atributos; subir `retry_on_failure` **no** ayudará ante un error permanente |
| `no such host` / `connection refused` hacia el gateway | DNS/Service mal, o gateway no `Ready` | Verificá el FQDN nombre/namespace del `Service`; `kubectl get endpoints otel-gateway`; comprobá que el readiness probe pase |
| Pods del gateway con CPU muy dispareja tras el scale-up | gRPC fija una conexión HTTP/2 por agent a un pod | Usá Service headless + round-robin del cliente, un mesh, o el exporter `loadbalancing` (§4.3) |
| El tail sampling conserva solo fragmentos de las trazas | Los spans de una traza repartidos entre réplicas del sampler | Poné al frente de los samplers un exporter `loadbalancing`, `routing_key: traceID` → Service headless (§4.3) |
| `bind: address already in use` en `hostPort` | Dos agents DaemonSet (o uno sobrante) reclaman `hostPort: 4317` en el nodo | Un agent por nodo; liberá el puerto o quitá `hostPort` y usá el ClusterIP |

```console
$ kubectl -n observability get endpoints otel-gateway
NAME           ENDPOINTS                                            AGE
otel-gateway   10.244.1.23:4317,10.244.2.41:4317,10.244.3.9:4317   9m

$ kubectl -n observability describe pod otel-gateway-6b8f9c7d4-xk2 | grep -A3 'Last State'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

---

## Referencias

- OpenTelemetry — Collector Deployment (overview): https://opentelemetry.io/docs/collector/deployment/
- OpenTelemetry — Agent pattern: https://opentelemetry.io/docs/collector/deployment/agent/
- OpenTelemetry — Gateway pattern: https://opentelemetry.io/docs/collector/deployment/gateway/
- OpenTelemetry — No Collector pattern: https://opentelemetry.io/docs/collector/deployment/no-collector/
- OpenTelemetry — Scaling the Collector: https://opentelemetry.io/docs/collector/scaling/
- OpenTelemetry — Collector configuration (receivers/processors/exporters/service): https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry — Building a custom Collector (OCB): https://opentelemetry.io/docs/collector/custom-collector/
- OpenTelemetry — Installation & distributions: https://opentelemetry.io/docs/collector/installation/
- OpenTelemetry — Internal telemetry & troubleshooting: https://opentelemetry.io/docs/collector/internal-telemetry/
- OpenTelemetry — Kubernetes Operator: https://opentelemetry.io/docs/platforms/kubernetes/operator/
- OpenTelemetry — Kubernetes Helm charts: https://opentelemetry.io/docs/platforms/kubernetes/helm/
- opentelemetry-collector (core): https://github.com/open-telemetry/opentelemetry-collector
- opentelemetry-collector-contrib (`k8sattributes`, `tail_sampling`, `loadbalancing`, `filelog`…): https://github.com/open-telemetry/opentelemetry-collector-contrib
- opentelemetry-operator: https://github.com/open-telemetry/opentelemetry-operator
- CNCF Curriculum (OTCA): https://github.com/cncf/curriculum