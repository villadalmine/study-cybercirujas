# Ejercicios guiados — Tema 2.1: Observability Fundamentals (Traces, Metrics, Logs & Events)

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) — currículum 2025-04-01
> **Peso en el examen:** 4.0 %
> **Modalidad:** laboratorio ejecutable de punta a punta sobre `kind`. Todo manifiesto de este documento es completo y aplicable con `kubectl apply -f -`.

---

## 0. Objetivos de aprendizaje

Al terminar estos ejercicios vas a poder:

1. Distinguir las cuatro señales (**traces, metrics, logs, events**) por su **modelo de datos**, no por el backend que las almacena.
2. Construir una topología **agent (DaemonSet) → gateway (Deployment)** de OpenTelemetry Collector y razonar por qué existe esa separación.
3. Leer el formato de exposición de Prometheus, calcular **cardinalidad** y explicar por qué un label mal elegido tira abajo un TSDB.
4. Parsear logs de contenedor y correlacionarlos con traces vía `trace_id` / `span_id`.
5. Construir a mano un payload OTLP y romper deliberadamente la **propagación de contexto** para ver cómo se manifiesta el fallo.
6. Tratar los **Kubernetes Events** como señal de primera clase, con sus límites de retención.
7. Derivar métricas RED desde spans (`spanmetrics`) y navegar métrica → **exemplar** → trace.
8. Diagnosticar el propio pipeline de telemetría con self-telemetry y `zpages`.

---

## 1. Entorno de laboratorio

| Componente | Versión validada | Notas |
|---|---|---|
| kind | ≥ 0.24 | cualquier k8s ≥ 1.29 |
| kubectl | ≥ 1.29 | |
| OpenTelemetry Collector Contrib | `0.119.0` | pinneá una versión concreta; el operador `container` del `filelog` existe desde `0.94.0` y el exporter `logging` fue **eliminado** en `0.120.0` (usá `debug`) |
| Prometheus | `v3.1.0` | |
| Jaeger all-in-one | `1.62.0` | |
| jq | ≥ 1.6 | |

> **Nota sobre versiones:** verificá siempre qué binario estás corriendo antes de culpar a la config:
> `kubectl -n observability exec deploy/otel-collector -- /otelcol-contrib --version`

---

## Bloque 0 — Bootstrap del cluster

### Pasos

1. Creá el cluster con los NodePorts que vamos a necesitar mapeados al host:

```bash
cat <<'EOF' | kind create cluster --name cnpa-obs --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30090   # Prometheus UI
        hostPort: 30090
        protocol: TCP
      - containerPort: 30686   # Jaeger UI
        hostPort: 30686
        protocol: TCP
  - role: worker
  - role: worker
EOF
```

Salida esperada (abreviada):

```
Creating cluster "cnpa-obs" ...
 ✓ Ensuring node image (kindest/node:v1.31.2) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-cnpa-obs"
```

2. Creá los namespaces:

```bash
kubectl create namespace observability
kubectl create namespace workloads
```

3. Verificá que los tres nodos están `Ready`:

```bash
kubectl get nodes -o wide
```

```
NAME                     STATUS   ROLES           AGE   VERSION
cnpa-obs-control-plane   Ready    control-plane   62s   v1.31.2
cnpa-obs-worker          Ready    <none>          45s   v1.31.2
cnpa-obs-worker2         Ready    <none>          45s   v1.31.2
```

### Preguntas de verificación

- **P0.1** — Pedimos dos workers además del control-plane. ¿Qué característica del pipeline de observabilidad no podríamos demostrar con un cluster de un solo nodo?
- **P0.2** — ¿Por qué usamos `extraPortMappings` + NodePort en vez de resolver todo con `kubectl port-forward`? Nombrá una limitación operativa concreta de `port-forward` en un entorno real.

---

## Bloque 1 — El Collector y el modelo de datos OTLP

Acá construimos el **gateway**: una instancia central que recibe OTLP y, por ahora, sólo imprime lo que recibe. El objetivo es ver la forma de los datos, no almacenarlos.

### Pasos

1. Creá el ServiceAccount y el RBAC del gateway (lo vamos a usar recién en el Bloque 5, pero lo dejamos listo):

```bash
cat <<'EOF' | kubectl apply -f -
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
    resources: ["events", "namespaces", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
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
EOF
```

2. Aplicá la configuración **v1** del gateway:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  collector.yaml: |
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
        spike_limit_percentage: 20
      batch:
        timeout: 5s
        send_batch_size: 512
        send_batch_max_size: 1024

    exporters:
      debug:
        verbosity: detailed
        sampling_initial: 5
        sampling_thereafter: 200

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 0.0.0.0:55679

    service:
      extensions: [health_check, zpages]
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
          processors: [memory_limiter, batch]
          exporters: [debug]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
EOF
```

3. Desplegá el gateway y su Service:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
    app.kubernetes.io/component: gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-collector
        app.kubernetes.io/component: gateway
      annotations:
        checksum/config: "v1"
    spec:
      serviceAccountName: otel-collector
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.119.0
          args: ["--config=/conf/collector.yaml"]
          ports:
            - { name: otlp-grpc,  containerPort: 4317 }
            - { name: otlp-http,  containerPort: 4318 }
            - { name: self-mtx,   containerPort: 8888 }
            - { name: promexport, containerPort: 8889 }
            - { name: zpages,     containerPort: 55679 }
          env:
            - name: GOMEMLIMIT
              value: "400MiB"
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              memory: 512Mi
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 5
          readinessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 5
          volumeMounts:
            - name: conf
              mountPath: /conf
      volumes:
        - name: conf
          configMap:
            name: otel-collector-conf
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  selector:
    app.kubernetes.io/name: otel-collector
  ports:
    - { name: otlp-grpc,  port: 4317, targetPort: 4317, protocol: TCP }
    - { name: otlp-http,  port: 4318, targetPort: 4318, protocol: TCP }
    - { name: self-mtx,   port: 8888, targetPort: 8888, protocol: TCP }
    - { name: promexport, port: 8889, targetPort: 8889, protocol: TCP }
EOF

kubectl -n observability rollout status deploy/otel-collector --timeout=120s
```

4. Abrí los logs del collector en una terminal aparte y dejalos corriendo:

```bash
kubectl -n observability logs -f deploy/otel-collector
```

5. En otra terminal, generá **traces** sintéticos con `telemetrygen`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: telemetrygen-traces
  namespace: workloads
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: telemetrygen
          image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.119.0
          args:
            - traces
            - --otlp-endpoint=otel-collector.observability.svc.cluster.local:4317
            - --otlp-insecure
            - --traces=3
            - --child-spans=2
            - --service=checkout
            - --otlp-attributes=deployment.environment.name="lab"
EOF
```

Fragmento representativo de lo que aparece en los logs del gateway:

```
2026-08-06T12:00:03.512Z  info  TracesExporter  {"kind":"exporter","data_type":"traces","name":"debug","resource spans":1,"spans":9}
ResourceSpans #0
Resource SchemaURL: https://opentelemetry.io/schemas/1.4.0
Resource attributes:
     -> service.name: Str(checkout)
     -> deployment.environment.name: Str(lab)
ScopeSpans #0
InstrumentationScope telemetrygen
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      :
    ID             : 00f067aa0ba902b7
    Name           : lets-go
    Kind           : Client
    Start time     : 2026-08-06 12:00:03.4 +0000 UTC
    End time       : 2026-08-06 12:00:03.4001 +0000 UTC
    Status code    : Unset
Attributes:
     -> net.peer.ip: Str(1.2.3.4)
     -> peer.service: Str(telemetrygen-server)
Span #1
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      : 00f067aa0ba902b7
    ID             : 6b0e1a2c9f7d4a31
    Name           : okey-dokey-0
    Kind           : Server
```

6. Generá **metrics** y **logs** con la misma herramienta:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: telemetrygen-signals
  namespace: workloads
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: metrics
          image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.119.0
          args:
            - metrics
            - --otlp-endpoint=otel-collector.observability.svc.cluster.local:4317
            - --otlp-insecure
            - --metrics=5
            - --metric-type=Sum
            - --service=checkout
        - name: logs
          image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.119.0
          args:
            - logs
            - --otlp-endpoint=otel-collector.observability.svc.cluster.local:4317
            - --otlp-insecure
            - --logs=5
            - --severity-text=Info
            - --service=checkout
EOF
```

7. Compará en los logs las tres estructuras. Fijate específicamente en:
   - `Resource attributes` → aparece en las **tres** señales, idéntico.
   - Un span tiene `Trace ID`, `Parent ID`, `ID`, `Kind`, `Start/End time`.
   - Un data point de métrica tiene `StartTimestamp`, `Timestamp`, `Value`, `AggregationTemporality`.
   - Un log record tiene `Body`, `SeverityNumber`, `SeverityText`, `TraceID`, `SpanID`.

8. Rompé el pipeline a propósito para entender la validación de config:

```bash
kubectl -n observability patch configmap otel-collector-conf --type merge -p \
  '{"data":{"collector.yaml":"receivers:\n  otlp:\n    protocols:\n      grpc:\n        endpoint: 0.0.0.0:4317\nexporters:\n  debug: {}\nservice:\n  pipelines:\n    traces:\n      receivers: [otlp]\n      exporters: []\n"}}'
kubectl -n observability rollout restart deploy/otel-collector
kubectl -n observability logs -l app.kubernetes.io/name=otel-collector --tail=20
```

Salida esperada:

```
Error: failed to build pipelines: pipeline "traces" must have at least one exporter
2026/08/06 12:04:11 collector server run finished with error: failed to build pipelines: ...
```

9. Restaurá la configuración v1 (repetí el paso 2) y hacé `rollout restart`.

### Preguntas de verificación

- **P1.1** — `memory_limiter` está listado antes que `batch`. ¿Qué determina el orden de los processors en un pipeline y qué pasaría si los invirtiéramos?
- **P1.2** — `service.name` apareció como *resource attribute*, no como atributo del span. ¿Cuál es la diferencia semántica entre resource attributes y span/log attributes, y por qué OTel exige `service.name`?
- **P1.3** — El collector se negó a arrancar con un pipeline sin exporter, en vez de arrancar degradado. Desde la óptica de platform engineering, ¿por qué es la conducta correcta?
- **P1.4** — El receiver expone OTLP en 4317 (gRPC) y 4318 (HTTP). ¿Cuándo elegirías cada uno para telemetría saliente de una aplicación?
- **P1.5** — El exporter `debug` está configurado con `sampling_initial: 5` y `sampling_thereafter: 200`. ¿Qué problema de producción previene ese sampling y por qué el `debug` exporter jamás debe quedar activo en un cluster real?

---

## Bloque 2 — Metrics: modelo, exposición, PromQL y cardinalidad

### Pasos

1. Desplegá Prometheus con RBAC y service discovery de pods:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/metrics", "services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-conf
  namespace: observability
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: cnpa-obs

    scrape_configs:
      - job_name: otel-collector-self
        static_configs:
          - targets: ["otel-collector.observability.svc.cluster.local:8888"]

      - job_name: otel-collector-export
        honor_labels: true
        static_configs:
          - targets: ["otel-collector.observability.svc.cluster.local:8889"]

      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
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
            target_label: __address__
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
          - source_labels: [__meta_kubernetes_namespace]
            action: replace
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            action: replace
            target_label: pod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: prom/prometheus:v3.1.0
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=2h
            - --web.enable-lifecycle
            - --web.enable-otlp-receiver
            - --enable-feature=exemplar-storage
          ports:
            - { name: http, containerPort: 9090 }
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { memory: 1Gi }
          volumeMounts:
            - { name: conf, mountPath: /etc/prometheus }
            - { name: data, mountPath: /prometheus }
      volumes:
        - name: conf
          configMap: { name: prometheus-conf }
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: observability
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: prometheus
  ports:
    - { name: http, port: 9090, targetPort: 9090, nodePort: 30090 }
EOF

kubectl -n observability rollout status deploy/prometheus --timeout=180s
```

2. Leé el **formato de exposición** crudo del collector, sin intermediarios:

```bash
kubectl -n observability run mtx-probe --rm -it --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  curl -s http://otel-collector.observability.svc.cluster.local:8888/metrics \
  | grep -E '^(# (HELP|TYPE) )?otelcol_(receiver_accepted_spans|exporter_sent_spans|processor_batch_batch_send_size)' \
  | head -30
```

Salida esperada (recortada):

```
# HELP otelcol_receiver_accepted_spans Number of spans successfully pushed into the pipeline.
# TYPE otelcol_receiver_accepted_spans counter
otelcol_receiver_accepted_spans_total{receiver="otlp",service_name="otelcol-contrib",transport="grpc"} 9
# HELP otelcol_processor_batch_batch_send_size Number of units in the batch
# TYPE otelcol_processor_batch_batch_send_size histogram
otelcol_processor_batch_batch_send_size_bucket{processor="batch",le="10"} 1
otelcol_processor_batch_batch_send_size_bucket{processor="batch",le="25"} 1
otelcol_processor_batch_batch_send_size_bucket{processor="batch",le="+Inf"} 2
otelcol_processor_batch_batch_send_size_sum{processor="batch"} 14
otelcol_processor_batch_batch_send_size_count{processor="batch"} 2
```

3. Identificá en esa salida, señalando la línea exacta:
   - la métrica de tipo `counter` y su sufijo obligatorio,
   - las tres series que compone un `histogram`,
   - el label reservado `le` y su semántica,
   - el label `service_name` inyectado por la self-telemetry.

4. Abrí la UI de Prometheus en `http://localhost:30090` y ejecutá, una por una:

```promql
# 1. Valor crudo de un counter (monótono, sin sentido operativo por sí solo)
otelcol_receiver_accepted_spans_total

# 2. Tasa por segundo — la forma correcta de consumir un counter
rate(otelcol_receiver_accepted_spans_total[5m])

# 3. Percentil 95 del tamaño de batch a partir del histogram
histogram_quantile(0.95, sum by (le) (rate(otelcol_processor_batch_batch_send_size_bucket[5m])))

# 4. Salud del pipeline: aceptado vs enviado
sum(rate(otelcol_receiver_accepted_spans_total[5m]))
  - sum(rate(otelcol_exporter_sent_spans_total[5m]))

# 5. Cardinalidad: las 10 métricas con más series
topk(10, count by (__name__) ({__name__=~".+"}))

# 6. Series totales en memoria del head block
prometheus_tsdb_head_series
```

5. Anotá el valor de `prometheus_tsdb_head_series`. Ahora provocá una **explosión de cardinalidad** controlada. Desplegá un exporter sintético que emita un label con un valor por request:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cardinality-bomb
  namespace: workloads
data:
  metrics.sh: |
    #!/bin/sh
    # Genera 5000 series de una sola métrica variando un único label.
    OUT=/data/metrics
    echo '# HELP orders_processed_total Orders processed.' > "$OUT"
    echo '# TYPE orders_processed_total counter' >> "$OUT"
    i=0
    while [ $i -lt 5000 ]; do
      echo "orders_processed_total{order_id=\"ord-$i\",region=\"eu-west-1\"} 1" >> "$OUT"
      i=$((i+1))
    done
    exec httpd -f -p 8080 -h /data
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cardinality-bomb
  namespace: workloads
spec:
  replicas: 1
  selector:
    matchLabels: { app: cardinality-bomb }
  template:
    metadata:
      labels: { app: cardinality-bomb }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: bomb
          image: busybox:1.36
          command: ["/bin/sh", "/scripts/metrics.sh"]
          ports:
            - { containerPort: 8080 }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: data, mountPath: /data }
      volumes:
        - name: scripts
          configMap: { name: cardinality-bomb, defaultMode: 0755 }
        - name: data
          emptyDir: {}
EOF
```

6. Esperá dos scrape intervals y volvé a medir:

```promql
prometheus_tsdb_head_series
count({__name__="orders_processed_total"})
```

Deberías ver `orders_processed_total` con ~5000 series y un salto equivalente en `prometheus_tsdb_head_series`.

7. Aplicá la mitigación estándar — **drop del label ofensivo en el relabeling**, no en la aplicación:

```bash
kubectl -n observability patch configmap prometheus-conf --type=json -p='[
  {"op":"add","path":"/data/prometheus.yml","value":"global:\n  scrape_interval: 15s\n  external_labels:\n    cluster: cnpa-obs\nscrape_configs:\n  - job_name: otel-collector-self\n    static_configs:\n      - targets: [\"otel-collector.observability.svc.cluster.local:8888\"]\n  - job_name: otel-collector-export\n    honor_labels: true\n    static_configs:\n      - targets: [\"otel-collector.observability.svc.cluster.local:8889\"]\n  - job_name: kubernetes-pods\n    kubernetes_sd_configs:\n      - role: pod\n    relabel_configs:\n      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]\n        action: keep\n        regex: \"true\"\n      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]\n        action: replace\n        target_label: __address__\n        regex: ([^:]+)(?::\\d+)?;(\\d+)\n        replacement: $1:$2\n      - source_labels: [__meta_kubernetes_namespace]\n        target_label: namespace\n      - source_labels: [__meta_kubernetes_pod_name]\n        target_label: pod\n    metric_relabel_configs:\n      - regex: order_id\n        action: labeldrop\n"}
]'

kubectl -n observability exec deploy/prometheus -- \
  wget -q -O- --post-data='' http://localhost:9090/-/reload
```

8. Verificá el colapso de series (los 5000 valores se agregan a 1 serie, y el counter queda **inconsistente** — ese es el punto):

```promql
count({__name__="orders_processed_total"})
```

9. Eliminá la bomba:

```bash
kubectl -n workloads delete deploy cardinality-bomb
kubectl -n workloads delete configmap cardinality-bomb
```

### Preguntas de verificación

- **P2.1** — ¿Por qué `rate()` es obligatorio sobre un counter y qué hace `rate()` cuando el proceso se reinicia y el contador vuelve a 0?
- **P2.2** — En un histogram de Prometheus, los buckets son **acumulativos**. Explicá qué significa `le="0.5"` y por qué `histogram_quantile()` devuelve una aproximación, no el percentil real. ¿Qué pasa si el bucket más alto es `le="1"` y la latencia real es de 8 s?
- **P2.3** — Calculá la cardinalidad de una métrica `http_requests_total` con los labels: `method` (7 valores), `status` (12), `endpoint` (40), `pod` (60), `cluster` (3). ¿Cuántas series son? Si además agregás `user_id` con 100 000 usuarios, ¿qué número te queda y por qué es inviable?
- **P2.4** — El `labeldrop` colapsó 5000 series en una. ¿Por qué el valor resultante del counter es incorrecto y qué debería haberse hecho en su lugar, del lado de la instrumentación?
- **P2.5** — OTel soporta temporalidad **delta** y **cumulative**; Prometheus sólo entiende cumulative en su modelo de scrape. ¿Qué componente del Collector resuelve la conversión y en qué dirección?
- **P2.6** — El job `otel-collector-export` tiene `honor_labels: true`. ¿Qué hace ese flag y por qué es necesario cuando scrapeás un collector que reexporta métricas de terceros?

---

## Bloque 3 — Logs: recolección, parsing y enriquecimiento

Acá agregamos el **agent**: un DaemonSet que lee los archivos de log de los contenedores en cada nodo, los parsea y los reenvía por OTLP al gateway.

### Pasos

1. Desplegá una aplicación que emita logs estructurados en JSON a `stdout`, incluyendo `trace_id` y `span_id`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: workloads
spec:
  replicas: 2
  selector:
    matchLabels: { app: order-service }
  template:
    metadata:
      labels:
        app: order-service
        app.kubernetes.io/name: order-service
        app.kubernetes.io/version: "1.4.2"
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["/bin/sh", "-c"]
          args:
            - |
              i=0
              while true; do
                i=$((i+1))
                if [ $((i % 5)) -eq 0 ]; then LVL="ERROR"; MSG="payment gateway timeout";
                else LVL="INFO"; MSG="order processed"; fi
                DUR=$(( (i * 37) % 900 ))
                printf '{"ts":"%s","level":"%s","msg":"%s","order_id":"ord-%05d","duration_ms":%d,"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7"}\n' \
                  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LVL" "$MSG" "$i" "$DUR"
                sleep 2
              done
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { memory: 32Mi }
EOF

kubectl -n workloads rollout status deploy/order-service --timeout=60s
```

2. Confirmá que el runtime está escribiendo esos logs en disco, en formato CRI:

```bash
kubectl -n workloads logs deploy/order-service --tail=2
NODE=$(kubectl -n workloads get pod -l app=order-service -o jsonpath='{.items[0].spec.nodeName}')
docker exec "$NODE" sh -c 'ls -1 /var/log/pods/workloads_order-service-*/app/ && head -1 /var/log/pods/workloads_order-service-*/app/0.log'
```

Salida esperada:

```
0.log
2026-08-06T12:11:04.882347113Z stdout F {"ts":"2026-08-06T12:11:04Z","level":"INFO","msg":"order processed","order_id":"ord-00001","duration_ms":37,...}
```

3. Desplegá el agent DaemonSet con `filelog` + `k8sattributes`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-agent
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
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
  agent.yaml: |
    receivers:
      filelog:
        include: [ /var/log/pods/*/*/*.log ]
        exclude:
          - /var/log/pods/observability_otel-agent-*/*/*.log
          - /var/log/pods/observability_otel-collector-*/*/*.log
        start_at: end
        include_file_path: true
        include_file_name: false
        retry_on_failure:
          enabled: true
        operators:
          # 1) Normaliza el envoltorio del runtime (containerd/CRI-O/docker)
          #    y extrae k8s.pod.name / k8s.namespace.name / k8s.container.name del path.
          - type: container
            id: container-parser
            add_metadata_from_filepath: true

          # 2) Si el mensaje es JSON, lo promueve a attributes.
          - type: json_parser
            id: json-parser
            if: 'hasPrefix(body, "{")'
            parse_from: body
            parse_to: attributes
            timestamp:
              parse_from: attributes.ts
              layout_type: strptime
              layout: '%Y-%m-%dT%H:%M:%SZ'
            severity:
              parse_from: attributes.level
              mapping:
                error: ERROR
                warn:  WARN
                info:  INFO
                debug: DEBUG

          # 3) Promueve trace_id/span_id a campos de primera clase del log record.
          - type: trace_parser
            id: trace-parser
            if: 'attributes?.trace_id != nil'
            trace_id:
              parse_from: attributes.trace_id
            span_id:
              parse_from: attributes.span_id

          # 4) El mensaje humano vuelve al body; los campos técnicos quedan en attributes.
          - type: move
            if: 'attributes?.msg != nil'
            from: attributes.msg
            to: body

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          node_from_env_var: K8S_NODE_NAME
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.node.name
            - k8s.container.name
          labels:
            - tag_name: service.name
              key: app.kubernetes.io/name
              from: pod
            - tag_name: service.version
              key: app.kubernetes.io/version
              from: pod
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: connection
      resourcedetection:
        detectors: [env, system]
        system:
          hostname_sources: [os]
      batch:
        timeout: 5s
        send_batch_size: 1024

    exporters:
      otlp/gateway:
        endpoint: otel-collector.observability.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          queue_size: 2000
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133

    service:
      extensions: [health_check]
      telemetry:
        logs:
          level: info
      pipelines:
        logs:
          receivers: [filelog]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp/gateway]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-agent
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-agent
        app.kubernetes.io/component: agent
    spec:
      serviceAccountName: otel-agent
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.119.0
          args: ["--config=/conf/agent.yaml"]
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "k8s.cluster.name=cnpa-obs"
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
          volumeMounts:
            - { name: conf, mountPath: /conf }
            - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 10
      volumes:
        - name: conf
          configMap: { name: otel-agent-conf }
        - name: varlogpods
          hostPath:
            path: /var/log/pods
            type: Directory
EOF

kubectl -n observability rollout status ds/otel-agent --timeout=120s
```

4. Observá el resultado en el gateway:

```bash
kubectl -n observability logs -f deploy/otel-collector | grep -A 25 "LogRecord #0"
```

Salida esperada:

```
Resource attributes:
     -> k8s.cluster.name: Str(cnpa-obs)
     -> k8s.pod.name: Str(order-service-6c8f9d7b4-x2kqz)
     -> k8s.namespace.name: Str(workloads)
     -> k8s.deployment.name: Str(order-service)
     -> k8s.container.name: Str(app)
     -> service.name: Str(order-service)
     -> service.version: Str(1.4.2)
LogRecord #0
ObservedTimestamp: 2026-08-06 12:14:22.114 +0000 UTC
Timestamp: 2026-08-06 12:14:20 +0000 UTC
SeverityText: ERROR
SeverityNumber: Error(17)
Body: Str(payment gateway timeout)
Attributes:
     -> order_id: Str(ord-00005)
     -> duration_ms: Double(185)
     -> logtag: Str(F)
     -> log.file.path: Str(/var/log/pods/workloads_order-service-.../app/0.log)
Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
Span ID: 00f067aa0ba902b7
```

5. Verificá que `Timestamp` (el del evento) y `ObservedTimestamp` (el de la recolección) son distintos. Anotá la diferencia en segundos.

6. Provocá el fallo clásico de recolección: reiniciá el agent y comprobá qué pasa con los logs emitidos durante la caída.

```bash
kubectl -n observability delete pod -l app.kubernetes.io/name=otel-agent
sleep 20
# Contá cuántos order_id faltan comparando el stdout del pod con lo recibido en el gateway
```

### Preguntas de verificación

- **P3.1** — El `filelog` usa `start_at: end`. ¿Qué implicancia tiene ese valor en el primer arranque del agent en un nodo con 20 GB de logs históricos, y cuándo usarías `beginning`?
- **P3.2** — Tras el reinicio del paso 6 se perdieron registros. ¿Qué extensión del Collector persiste el offset de lectura y cómo se configura conceptualmente? ¿Qué garantía de entrega ofrece OTLP: at-most-once, at-least-once o exactly-once?
- **P3.3** — Explicá la diferencia, en el data model de OTLP Logs, entre `Body`, `Attributes` y `Resource attributes`. ¿Por qué `SeverityNumber` existe además de `SeverityText`?
- **P3.4** — La config excluye explícitamente `/var/log/pods/observability_otel-agent-*`. ¿Qué pasa si se omite esa exclusión? Describí la dinámica del fallo.
- **P3.5** — `k8sattributes` tiene `filter.node_from_env_var: K8S_NODE_NAME`. ¿Qué problema de escala evita ese filtro en un cluster de 500 nodos?
- **P3.6** — El pod escribe a `stdout` en vez de a un archivo dentro del contenedor. Justificá por qué es la práctica correcta en Kubernetes y qué tres cosas se rompen si la app escribe a `/var/log/app.log` dentro de su propio filesystem.

---

## Bloque 4 — Traces: spans, contexto y propagación W3C

### Pasos

1. Desplegá Jaeger como backend de traces:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: jaeger }
  template:
    metadata:
      labels: { app.kubernetes.io/name: jaeger }
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/all-in-one:1.62.0
          env:
            - { name: COLLECTOR_OTLP_ENABLED, value: "true" }
            - { name: SPAN_STORAGE_TYPE, value: "memory" }
            - { name: METRICS_STORAGE_TYPE, value: "prometheus" }
            - { name: PROMETHEUS_SERVER_URL, value: "http://prometheus.observability.svc.cluster.local:9090" }
            - { name: PROMETHEUS_QUERY_SUPPORT_SPANMETRICS_CONNECTOR, value: "true" }
            - { name: PROMETHEUS_QUERY_NORMALIZE_CALLS, value: "true" }
            - { name: PROMETHEUS_QUERY_NORMALIZE_DURATION, value: "true" }
          ports:
            - { name: ui,        containerPort: 16686 }
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { memory: 1Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector: { app.kubernetes.io/name: jaeger }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
    - { name: otlp-http, port: 4318, targetPort: 4318 }
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-ui
  namespace: observability
spec:
  type: NodePort
  selector: { app.kubernetes.io/name: jaeger }
  ports:
    - { name: ui, port: 16686, targetPort: 16686, nodePort: 30686 }
EOF

kubectl -n observability rollout status deploy/jaeger --timeout=180s
```

2. Actualizá el gateway a la configuración **v2**: exporta traces a Jaeger y métricas a Prometheus.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  collector.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20
      batch:
        timeout: 5s
        send_batch_size: 512

    exporters:
      debug:
        verbosity: normal
      otlp/jaeger:
        endpoint: jaeger.observability.svc.cluster.local:4317
        tls: { insecure: true }
        sending_queue:
          enabled: true
          queue_size: 1000
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s
      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true
        resource_to_telemetry_conversion:
          enabled: true

    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }
      zpages:       { endpoint: 0.0.0.0:55679 }

    service:
      extensions: [health_check, zpages]
      telemetry:
        logs: { level: info }
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus: { host: 0.0.0.0, port: 8888 }
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/jaeger]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
EOF

kubectl -n observability rollout restart deploy/otel-collector
kubectl -n observability rollout status deploy/otel-collector --timeout=120s
```

3. Regenerá traces y verificalos en la UI (`http://localhost:30686`, servicio `checkout`):

```bash
kubectl -n workloads delete job telemetrygen-traces --ignore-not-found
kubectl -n workloads create job telemetrygen-traces \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.119.0 \
  -- telemetrygen traces \
     --otlp-endpoint=otel-collector.observability.svc.cluster.local:4317 \
     --otlp-insecure --traces=5 --child-spans=3 --service=checkout
```

4. Ahora construí un trace distribuido **a mano**, para ver el modelo de datos sin instrumentación de por medio. Abrí un pod con `curl`:

```bash
kubectl -n observability run otlp-curl --rm -it --restart=Never \
  --image=curlimages/curl:8.11.1 -- sh
```

Dentro del pod, ejecutá:

```sh
NOW=$(date +%s)
START=$((NOW))000000000
MID=$((NOW))120000000
END=$((NOW))450000000

cat > /tmp/trace.json <<EOF
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "frontend"}},
          {"key": "service.version", "value": {"stringValue": "2.1.0"}},
          {"key": "deployment.environment.name", "value": {"stringValue": "lab"}}
        ]
      },
      "scopeSpans": [
        {
          "scope": {"name": "manual-lab", "version": "1.0.0"},
          "spans": [
            {
              "traceId": "5b8aa5a2d2c872e8321cf37308d69df2",
              "spanId": "051581bf3cb55c13",
              "name": "GET /checkout",
              "kind": 2,
              "startTimeUnixNano": "$START",
              "endTimeUnixNano": "$END",
              "attributes": [
                {"key": "http.request.method", "value": {"stringValue": "GET"}},
                {"key": "url.path", "value": {"stringValue": "/checkout"}},
                {"key": "http.response.status_code", "value": {"intValue": "200"}}
              ],
              "status": {"code": 1}
            },
            {
              "traceId": "5b8aa5a2d2c872e8321cf37308d69df2",
              "spanId": "a1b2c3d4e5f60718",
              "parentSpanId": "051581bf3cb55c13",
              "name": "POST payments",
              "kind": 3,
              "startTimeUnixNano": "$MID",
              "endTimeUnixNano": "$END",
              "attributes": [
                {"key": "http.request.method", "value": {"stringValue": "POST"}},
                {"key": "server.address", "value": {"stringValue": "payments"}}
              ],
              "status": {"code": 1}
            }
          ]
        }
      ]
    },
    {
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "payments"}},
          {"key": "deployment.environment.name", "value": {"stringValue": "lab"}}
        ]
      },
      "scopeSpans": [
        {
          "scope": {"name": "manual-lab", "version": "1.0.0"},
          "spans": [
            {
              "traceId": "5b8aa5a2d2c872e8321cf37308d69df2",
              "spanId": "9f8e7d6c5b4a3928",
              "parentSpanId": "a1b2c3d4e5f60718",
              "name": "POST /charge",
              "kind": 2,
              "startTimeUnixNano": "$MID",
              "endTimeUnixNano": "$END",
              "attributes": [
                {"key": "http.request.method", "value": {"stringValue": "POST"}},
                {"key": "http.response.status_code", "value": {"intValue": "500"}},
                {"key": "error.type", "value": {"stringValue": "GatewayTimeout"}}
              ],
              "status": {"code": 2, "message": "upstream timeout"},
              "events": [
                {
                  "timeUnixNano": "$END",
                  "name": "exception",
                  "attributes": [
                    {"key": "exception.type", "value": {"stringValue": "TimeoutError"}},
                    {"key": "exception.message", "value": {"stringValue": "acquirer did not respond in 300ms"}}
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
EOF

curl -sS -X POST \
  -H "Content-Type: application/json" \
  -d @/tmp/trace.json \
  http://otel-collector.observability.svc.cluster.local:4318/v1/traces -w '\nHTTP %{http_code}\n'
```

Salida esperada:

```
{"partialSuccess":{}}
HTTP 200
```

5. Buscá en Jaeger el servicio `frontend`. Deberías ver **un solo trace de 3 spans que cruza dos servicios**, con el span de `payments` marcado en rojo y un log de span `exception`.

6. Escribí el header `traceparent` que un cliente HTTP real habría enviado desde `frontend` hacia `payments` para producir exactamente ese trace:

```
traceparent: 00-5b8aa5a2d2c872e8321cf37308d69df2-a1b2c3d4e5f60718-01
```

7. **Rompé la propagación.** Cambiá el `traceId` del tercer span (el de `payments`) por `00000000000000000000000000000042`, dejando el `parentSpanId` intacto, y volvé a enviar:

```sh
sed 's/"traceId": "5b8aa5a2d2c872e8321cf37308d69df2",\n              "spanId": "9f8e7d6c5b4a3928"/X/' /tmp/trace.json > /dev/null
# más simple y explícito: editá el bloque de payments y reemplazá sólo su traceId
sed -i '0,/9f8e7d6c5b4a3928/{s/5b8aa5a2d2c872e8321cf37308d69df2\(",\n *"spanId": "9f8e\)/X\1/}' /tmp/trace.json 2>/dev/null || true
```

> Si `sed` multilínea te resulta incómodo, simplemente reeditá el heredoc del paso 4 cambiando el `traceId` del span `9f8e7d6c5b4a3928` y reenvialo.

8. Volvé a Jaeger. Observá el síntoma: aparecen **dos traces**, uno de 2 spans (`frontend`) y otro de 1 span huérfano (`payments`) cuyo `parentSpanId` apunta a un span que no existe en su propio trace.

9. Salí del pod (`exit`).

### Preguntas de verificación

- **P4.1** — Descomponé el header `traceparent: 00-5b8aa5a2d2c872e8321cf37308d69df2-a1b2c3d4e5f60718-01` en sus cuatro campos. ¿Cuántos bytes tiene cada identificador y qué significa el último octeto?
- **P4.2** — En el paso 4, el span `POST payments` tiene `kind: 3` y el span `POST /charge` tiene `kind: 2`. Traducí los enums y explicá por qué un salto de red entre dos servicios instrumentados produce **dos** spans y no uno.
- **P4.3** — Un servicio intermedio no propaga el header `traceparent` (por ejemplo, un proxy legacy que descarta headers desconocidos). Describí exactamente qué ve el operador en la UI de traces.
- **P4.4** — El span de `payments` tiene `status.code: 2` y un `span event` de tipo `exception`. ¿Qué diferencia hay entre un *span event* y un *Kubernetes Event*? ¿Y entre un span event y un log record?
- **P4.5** — Si el reloj del nodo donde corre `payments` está 4 segundos adelantado respecto del de `frontend`, ¿qué se ve en la waterfall del trace? ¿Cómo se detecta y se mitiga en producción?
- **P4.6** — La respuesta OTLP fue `{"partialSuccess":{}}` con HTTP 200. ¿Qué información transporta `partialSuccess` cuando **no** está vacío y por qué un exporter que ignora ese campo puede perder datos silenciosamente?

---

## Bloque 5 — Events: la señal que Kubernetes te da gratis

### Pasos

1. Generá eventos de fallo deliberadamente. Primero, una imagen que no existe:

```bash
kubectl -n workloads run broken-image --image=registry.k8s.io/does-not-exist:v9 --restart=Never
```

Segundo, un pod imposible de schedulear:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: too-big
  namespace: workloads
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "500"
          memory: "800Gi"
EOF
```

Tercero, un contenedor que muere en loop:

```bash
kubectl -n workloads run crashloop --image=busybox:1.36 --restart=Always \
  -- /bin/sh -c "echo starting; exit 1"
```

2. Observá los eventos ordenados cronológicamente:

```bash
kubectl -n workloads get events --sort-by=.lastTimestamp -o wide | tail -20
```

Salida esperada (recortada):

```
LAST SEEN   TYPE      REASON              OBJECT                 SUBOBJECT           MESSAGE
25s         Warning   FailedScheduling    pod/too-big                                0/3 nodes are available: 3 Insufficient cpu, 3 Insufficient memory.
22s         Normal    Pulling             pod/broken-image       spec.containers{broken-image}  Pulling image "registry.k8s.io/does-not-exist:v9"
21s         Warning   Failed              pod/broken-image       spec.containers{broken-image}  Failed to pull image ...: not found
21s         Warning   Failed              pod/broken-image       spec.containers{broken-image}  Error: ErrImagePull
10s         Normal    BackOff             pod/broken-image       spec.containers{broken-image}  Back-off pulling image ...
8s          Warning   BackOff             pod/crashloop          spec.containers{crashloop}     Back-off restarting failed container
```

3. Inspeccioná la estructura completa de un Event:

```bash
kubectl -n workloads get events \
  --field-selector reason=BackOff -o json \
  | jq '.items[0] | {reason, type, count, firstTimestamp, lastTimestamp, reportingComponent, source, involvedObject, message}'
```

```json
{
  "reason": "BackOff",
  "type": "Warning",
  "count": 7,
  "firstTimestamp": "2026-08-06T12:22:11Z",
  "lastTimestamp": "2026-08-06T12:24:03Z",
  "reportingComponent": "kubelet",
  "source": { "component": "kubelet", "host": "cnpa-obs-worker" },
  "involvedObject": {
    "kind": "Pod",
    "namespace": "workloads",
    "name": "crashloop",
    "uid": "0f3a...",
    "fieldPath": "spec.containers{crashloop}"
  },
  "message": "Back-off restarting failed container crashloop in pod crashloop_workloads(0f3a...)"
}
```

4. Compará las dos APIs de Events que coexisten en el cluster:

```bash
kubectl api-resources | grep -i events
kubectl -n workloads get events.events.k8s.io -o json | jq '.items[0] | {reason, note, regarding, series, deprecatedCount}'
```

5. Comprobá la retención efectiva del apiserver:

```bash
docker exec cnpa-obs-control-plane \
  grep -E 'event-ttl|--event' /etc/kubernetes/manifests/kube-apiserver.yaml || \
  echo "flag ausente => vale el default: 1h"
```

6. Ingestá los Events al pipeline de observabilidad con el receiver `k8sobjects` **en el gateway** (no en el DaemonSet). Actualizá la ConfigMap del gateway agregando el receiver y un pipeline de logs dedicado:

```bash
kubectl -n observability get configmap otel-collector-conf -o jsonpath='{.data.collector\.yaml}' > /tmp/collector.yaml

python3 - <<'PY'
import re
p = "/tmp/collector.yaml"
c = open(p).read()
c = c.replace(
    "receivers:\n      otlp:",
    "receivers:\n      k8sobjects:\n        auth_type: serviceAccount\n        objects:\n          - name: events\n            mode: watch\n            group: events.k8s.io\n            namespaces: [workloads]\n      otlp:",
)
c = c.replace(
    "        logs:\n          receivers: [otlp]",
    "        logs:\n          receivers: [otlp]",
)
c += """        logs/k8sevents:
          receivers: [k8sobjects]
          processors: [memory_limiter, batch]
          exporters: [debug]
"""
open(p, "w").write(c)
PY

kubectl -n observability create configmap otel-collector-conf \
  --from-file=collector.yaml=/tmp/collector.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n observability rollout restart deploy/otel-collector
kubectl -n observability rollout status deploy/otel-collector --timeout=120s
```

7. Generá un evento nuevo y verificá que llega como **log record OTLP**:

```bash
kubectl -n workloads delete pod crashloop --force --grace-period=0 2>/dev/null
kubectl -n workloads run crashloop --image=busybox:1.36 --restart=Always -- /bin/sh -c "exit 1"

kubectl -n observability logs deploy/otel-collector --tail=60 | grep -A 12 "k8s.object.kind"
```

Salida esperada (recortada):

```
Resource attributes:
     -> k8s.object.kind: Str(Event)
     -> k8s.object.group: Str(events.k8s.io)
     -> k8s.object.name: Str(crashloop.185f3a2c1b0e7d41)
LogRecord #0
Body: Map({"apiVersion":"events.k8s.io/v1","kind":"Event","metadata":{...},
      "reason":"BackOff","note":"Back-off restarting failed container",
      "regarding":{"kind":"Pod","name":"crashloop","namespace":"workloads"},
      "type":"Warning"})
```

8. Limpiá los objetos rotos:

```bash
kubectl -n workloads delete pod broken-image too-big crashloop --ignore-not-found --force --grace-period=0
```

### Preguntas de verificación

- **P5.1** — Un Event tiene `count: 7` con `firstTimestamp` y `lastTimestamp` distintos. ¿Qué mecanismo del cliente de eventos produce eso y qué información se pierde en el proceso?
- **P5.2** — El TTL por defecto de los Events es **1 hora**. Enumerá dos consecuencias operativas concretas de ese valor durante un post-mortem, y dos formas de mitigarlo.
- **P5.3** — El evento `Warning FailedScheduling` del pod `too-big` **no aparece** en `kubectl logs`. ¿Por qué? ¿Qué componente lo emitió y sobre qué objeto?
- **P5.4** — Pusimos `k8sobjects` en el Deployment (gateway) y no en el DaemonSet (agent). ¿Qué pasaría si lo pusiéramos en el DaemonSet de un cluster de 3 nodos? ¿Y si el gateway escalara a `replicas: 3`?
- **P5.5** — Un ingeniero propone convertir cada Event en una métrica con labels `reason`, `namespace`, `pod` y `node`. Analizá la propuesta desde la cardinalidad y proponé una alternativa.
- **P5.6** — Distinguí tres cosas que se llaman "event" y suelen confundirse en el examen: **Kubernetes Event**, **span event** (OTel) y **CloudEvent** (CNCF). Una frase por cada una.

---

## Bloque 6 — Correlación entre señales: exemplars y spanmetrics

### Pasos

1. Agregá el connector `spanmetrics` al gateway. Esto deriva métricas **RED** (Rate, Errors, Duration) desde los spans, sin tocar la instrumentación de las aplicaciones:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  collector.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
      k8sobjects:
        auth_type: serviceAccount
        objects:
          - name: events
            mode: watch
            group: events.k8s.io
            namespaces: [workloads]

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20
      batch:
        timeout: 5s
        send_batch_size: 512

    connectors:
      spanmetrics:
        namespace: traces.span.metrics
        histogram:
          explicit:
            buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s]
        dimensions:
          - name: http.request.method
          - name: http.response.status_code
        exemplars:
          enabled: true
        exclude_dimensions: []
        metrics_flush_interval: 15s
        metrics_expiration: 5m
        aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE

    exporters:
      debug:
        verbosity: normal
      otlp/jaeger:
        endpoint: jaeger.observability.svc.cluster.local:4317
        tls: { insecure: true }
        sending_queue: { enabled: true, queue_size: 1000 }
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s
      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true
        resource_to_telemetry_conversion:
          enabled: true

    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }
      zpages:       { endpoint: 0.0.0.0:55679 }

    service:
      extensions: [health_check, zpages]
      telemetry:
        logs: { level: info }
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus: { host: 0.0.0.0, port: 8888 }
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/jaeger, spanmetrics]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
        metrics/spanmetrics:
          receivers: [spanmetrics]
          processors: [batch]
          exporters: [prometheus]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
        logs/k8sevents:
          receivers: [k8sobjects]
          processors: [memory_limiter, batch]
          exporters: [debug]
EOF

kubectl -n observability rollout restart deploy/otel-collector
kubectl -n observability rollout status deploy/otel-collector --timeout=120s
```

2. Generá tráfico sostenido para alimentar el connector:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trace-load
  namespace: workloads
spec:
  replicas: 1
  selector:
    matchLabels: { app: trace-load }
  template:
    metadata:
      labels: { app: trace-load }
    spec:
      containers:
        - name: gen
          image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.119.0
          args:
            - traces
            - --otlp-endpoint=otel-collector.observability.svc.cluster.local:4317
            - --otlp-insecure
            - --duration=30m
            - --rate=5
            - --child-spans=2
            - --service=checkout
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { memory: 128Mi }
EOF
```

3. Verificá el nombre exacto de las métricas derivadas — **no lo asumas, el prefijo depende de la versión del connector**:

```bash
kubectl -n observability run mtx-probe --rm -it --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  sh -c "curl -s http://otel-collector.observability.svc.cluster.local:8889/metrics | grep -E '^# TYPE.*span_metrics'"
```

```
# TYPE traces_span_metrics_calls_total counter
# TYPE traces_span_metrics_duration_milliseconds histogram
```

4. Pedí la exposición en **OpenMetrics** para ver los exemplars adjuntos a los buckets:

```bash
kubectl -n observability run mtx-probe --rm -it --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  sh -c "curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
    http://otel-collector.observability.svc.cluster.local:8889/metrics \
    | grep -m5 'trace_id'"
```

Salida esperada:

```
traces_span_metrics_duration_milliseconds_bucket{service_name="checkout",span_name="lets-go",span_kind="SPAN_KIND_CLIENT",status_code="STATUS_CODE_UNSET",le="10"} 42 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 8.4 1754481600.000
```

5. En Prometheus (`http://localhost:30090`), consultá las RED metrics:

```promql
# Rate por servicio y operación
sum by (service_name, span_name) (rate(traces_span_metrics_calls_total[5m]))

# Error ratio
sum by (service_name) (rate(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m]))
  /
sum by (service_name) (rate(traces_span_metrics_calls_total[5m]))

# Duration p99
histogram_quantile(0.99,
  sum by (service_name, span_name, le) (
    rate(traces_span_metrics_duration_milliseconds_bucket[5m])
  )
)
```

6. Consultá exemplars por API y extraé un `trace_id` real:

```bash
NOW=$(date +%s)
curl -sG "http://localhost:30090/api/v1/query_exemplars" \
  --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket' \
  --data-urlencode "start=$((NOW-600))" \
  --data-urlencode "end=$NOW" \
  | jq -r '.data[0].exemplars[0].labels.trace_id'
```

7. Pegá ese `trace_id` en la barra de búsqueda de Jaeger (`http://localhost:30686`). Acabás de recorrer el camino **métrica → exemplar → trace**.

8. Cerrá el triángulo: buscá logs con ese mismo `trace_id`:

```bash
kubectl -n observability logs deploy/otel-collector --tail=500 \
  | grep -B2 -A2 "4bf92f3577b34da6a3ce929d0e0e4736" | head -20
```

9. En Jaeger, andá a **Monitor** (pestaña SPM). Deberías ver las RED metrics del servicio `checkout` renderizadas desde Prometheus.

### Preguntas de verificación

- **P6.1** — El connector `spanmetrics` está en el pipeline `traces` como **exporter**, y en `metrics/spanmetrics` como **receiver**. Explicá qué es un connector y por qué esa doble declaración es obligatoria.
- **P6.2** — Suponé que agregás un `probabilistic_sampler` al 10 % en el pipeline `traces`, **antes** de `spanmetrics`. ¿Qué le pasa a `traces_span_metrics_calls_total`? ¿Dónde hay que ubicar el sampler para que las métricas sigan siendo correctas?
- **P6.3** — El `spanmetrics` está configurado con `dimensions: [http.request.method, http.response.status_code]`. ¿Qué pasaría si agregás `url.full` como dimensión en una app REST con IDs en la URL?
- **P6.4** — Los exemplars sólo aparecen cuando pedís `Accept: application/openmetrics-text`. ¿Por qué el formato clásico de Prometheus no puede transportarlos, y qué flag necesita Prometheus para almacenarlos?
- **P6.5** — Nombrá el campo que actúa como *join key* entre las tres señales y explicá qué hay que garantizar en la aplicación para que exista en los logs.
- **P6.6** — Ventaja y desventaja de derivar RED metrics desde spans frente a instrumentar contadores explícitos en la aplicación.

---

## Bloque 7 — Control de coste: sampling, filtrado y presupuesto de cardinalidad

### Pasos

1. Medí la línea base de volumen antes de tocar nada:

```promql
sum(rate(otelcol_receiver_accepted_spans_total[5m]))
sum(rate(otelcol_exporter_sent_spans_total[5m]))
sum(rate(otelcol_receiver_accepted_log_records_total[5m]))
prometheus_tsdb_head_series
```

Anotá los cuatro valores.

2. Aplicá **head sampling probabilístico** al 20 % en el gateway. Agregá al bloque `processors`:

```yaml
      probabilistic_sampler:
        sampling_percentage: 20
        hash_seed: 22
```

…y referencialo en el pipeline de traces **después** de `spanmetrics`, lo que en la práctica significa dividir el pipeline:

```yaml
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [spanmetrics, forward/sampled]
```

> En este laboratorio, aplicalo directamente sobre el pipeline `traces` y observá el efecto sobre `spanmetrics` — es exactamente el error que la pregunta **P6.2** te pidió anticipar.

3. Aplicá y comparaá aceptados vs enviados:

```promql
sum(rate(otelcol_receiver_accepted_spans_total[5m]))
  - sum(rate(otelcol_exporter_sent_spans_total{exporter="otlp/jaeger"}[5m]))
```

4. Sustituí el head sampling por **tail sampling**, que decide con el trace completo en mano:

```yaml
      tail_sampling:
        decision_wait: 10s
        num_traces: 50000
        expected_new_traces_per_sec: 200
        policies:
          - name: keep-errors
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: keep-slow
            type: latency
            latency:
              threshold_ms: 500
          - name: keep-critical-service
            type: string_attribute
            string_attribute:
              key: service.name
              values: [payments, checkout]
              enabled_regex_matching: false
          - name: baseline
            type: probabilistic
            probabilistic:
              sampling_percentage: 5
```

5. Reducí el volumen de logs descartando todo lo que esté por debajo de `WARN`, en el **agent**:

```yaml
      filter/severity:
        error_mode: ignore
        logs:
          log_record:
            - 'severity_number < SEVERITY_NUMBER_WARN'
```

6. Sanitizá atributos sensibles y de alta cardinalidad antes de que salgan del cluster:

```yaml
      attributes/scrub:
        actions:
          - key: order_id
            action: delete
          - key: enduser.id
            action: hash
          - key: http.request.header.authorization
            action: delete
```

7. Aplicá los cambios al agent y verificá la caída del volumen de logs:

```promql
sum(rate(otelcol_receiver_accepted_log_records_total[5m]))
sum(rate(otelcol_exporter_sent_log_records_total[5m]))
```

8. Calculá tu presupuesto de cardinalidad para el cluster de laboratorio:

```promql
topk(15, count by (__name__) ({__name__=~".+"}))
sum(scrape_samples_scraped)
```

### Preguntas de verificación

- **P7.1** — El `tail_sampling` necesita que **todos** los spans de un mismo trace lleguen a la **misma instancia** del collector. ¿Por qué? ¿Qué componente resuelve ese requisito cuando el gateway tiene 5 réplicas, y con qué `routing_key`?
- **P7.2** — Si `decision_wait: 10s` y hay traces cuya duración total es de 25 s, ¿qué se rompe exactamente? ¿Y si lo subís a 60 s?
- **P7.3** — El filtro de logs es `severity_number < SEVERITY_NUMBER_WARN`. El `filter` processor **descarta** lo que hace match. ¿Descarta los INFO o los conserva? Justificá.
- **P7.4** — Compará head sampling y tail sampling en tres ejes: dónde se toma la decisión, coste en la aplicación, coste en el pipeline. ¿Cuál garantiza capturar el 100 % de los errores?
- **P7.5** — Un service mesh agrega los labels `source_workload`, `destination_workload`, `response_code`, `connection_security_policy` a métricas por par de servicios. Con 80 servicios, ¿por qué el crecimiento es cuadrático y qué se hace al respecto?
- **P7.6** — `enduser.id` se aplica `hash` y no `delete`. ¿Qué capacidad analítica preserva el hash que el delete destruye, y qué riesgo residual sigue existiendo?

---

## Bloque 8 — Diagnóstico del propio pipeline de telemetría

> Regla operativa: *el pipeline de observabilidad es un sistema de producción más, y necesita su propia observabilidad.*

### Pasos

1. Exponé `zpages` y explorá el estado interno vivo:

```bash
kubectl -n observability port-forward deploy/otel-collector 55679:55679 &
sleep 2
curl -s http://localhost:55679/debug/servicez  | head -20
curl -s http://localhost:55679/debug/pipelinez | head -40
curl -s "http://localhost:55679/debug/tracez"  | head -30
```

2. Rompé el exporter a propósito: apuntá `otlp/jaeger` a un host inexistente.

```bash
kubectl -n observability get configmap otel-collector-conf -o jsonpath='{.data.collector\.yaml}' \
  | sed 's|endpoint: jaeger.observability.svc.cluster.local:4317|endpoint: jaeger-does-not-exist.observability.svc.cluster.local:4317|' \
  > /tmp/broken.yaml

kubectl -n observability create configmap otel-collector-conf \
  --from-file=collector.yaml=/tmp/broken.yaml --dry-run=client -o yaml | kubectl apply -f -

kubectl -n observability rollout restart deploy/otel-collector
sleep 60
```

3. Observá los síntomas en la self-telemetry:

```promql
# ¿Están fallando los envíos?
rate(otelcol_exporter_send_failed_spans_total[2m])

# ¿La cola se está llenando?
otelcol_exporter_queue_size
otelcol_exporter_queue_capacity

# ¿El receiver empezó a rechazar (backpressure hacia la app)?
rate(otelcol_receiver_refused_spans_total[2m])
```

Y en los logs del collector:

```
{"level":"error","msg":"Exporting failed. Will retry the request after interval.",
 "kind":"exporter","data_type":"traces","name":"otlp/jaeger",
 "error":"rpc error: code = Unavailable desc = ... no such host","interval":"9.3s"}
{"level":"error","msg":"Exporting failed. Rejecting data.",
 "kind":"exporter","name":"otlp/jaeger","dropped_items":512}
```

4. Restaurá el endpoint correcto y verificá la recuperación:

```bash
kubectl -n observability get configmap otel-collector-conf -o jsonpath='{.data.collector\.yaml}' \
  | sed 's|jaeger-does-not-exist|jaeger|' > /tmp/fixed.yaml
kubectl -n observability create configmap otel-collector-conf \
  --from-file=collector.yaml=/tmp/fixed.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl -n observability rollout restart deploy/otel-collector
kubectl -n observability rollout status deploy/otel-collector --timeout=120s
```

5. Escribí las reglas de alerta que un platform team debería tener sobre su propio pipeline. Aplicalas mentalmente contra las métricas que ya viste:

```yaml
groups:
  - name: telemetry-pipeline
    interval: 30s
    rules:
      - alert: CollectorDroppingData
        expr: sum(rate(otelcol_exporter_send_failed_spans_total[5m])) > 0
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "El collector está descartando spans"
          description: "Exporter {{ $labels.exporter }} falla desde hace 5m."

      - alert: CollectorQueueNearlyFull
        expr: (otelcol_exporter_queue_size / otelcol_exporter_queue_capacity) > 0.8
        for: 10m
        labels: { severity: warning }

      - alert: CollectorRefusingData
        expr: sum(rate(otelcol_receiver_refused_spans_total[5m])) > 0
        for: 5m
        labels: { severity: critical }

      - alert: TelemetryPipelineSilent
        expr: sum(rate(otelcol_receiver_accepted_spans_total[10m])) == 0
        for: 15m
        labels: { severity: critical }
        annotations:
          summary: "Ningún span ingresó al pipeline en 15 minutos"
```

### Preguntas de verificación

- **P8.1** — Diferenciá con precisión `otelcol_receiver_refused_*`, `otelcol_processor_dropped_*` y `otelcol_exporter_send_failed_*`. Cada una apunta a una causa raíz distinta: ¿cuál?
- **P8.2** — La `sending_queue` se llenó. ¿Qué hace el collector con los datos nuevos y cómo se propaga esa presión hacia la aplicación instrumentada? ¿Qué cambia si el receiver es OTLP/gRPC frente a un receiver de scrape como `prometheus`?
- **P8.3** — La cola por defecto es en memoria. Si el pod del gateway es reprogramado, ¿qué pasa con los datos encolados y qué extensión lo resuelve?
- **P8.4** — La alerta `TelemetryPipelineSilent` usa `== 0`. Explicá por qué esa alerta es estructuralmente distinta de las otras tres y qué falla clásica de monitoreo previene.
- **P8.5** — El `memory_limiter` empieza a rechazar datos cuando el proceso supera el 80 % del límite. ¿Por qué esa conducta es preferible a que el kernel mate el pod por OOM?

---

## Bloque 9 — Limpieza

```bash
kind delete cluster --name cnpa-obs
```

---

## Respuestas

<details>
<summary><strong>Desplegá acá las respuestas de todos los bloques</strong></summary>

### Bloque 0

**P0.1** — Con un solo nodo no se puede demostrar que el **agent** es un DaemonSet, es decir, que la recolección de logs de contenedor es una operación **local al nodo**: el `filelog` receiver lee `/var/log/pods` del host donde corre, y sólo ve los pods programados en ese host. Tampoco se ve el efecto del filtro `k8sattributes.filter.node_from_env_var`, ni el problema de **clock skew** entre nodos que rompe la waterfall de un trace, ni la duplicación de eventos si ponés `k8sobjects` en un DaemonSet.

**P0.2** — `kubectl port-forward` abre un túnel efímero contra **un pod concreto**, no contra el Service: si el pod se reinicia, el túnel muere y hay que relanzarlo; no balancea entre réplicas; requiere una sesión activa de kubectl con credenciales; y no sobrevive a un `rollout restart`. Para un laboratorio con reinicios frecuentes (hicimos varios `rollout restart`), un NodePort estable es más confiable. En producción, ninguno de los dos: se usa Ingress/Gateway API con autenticación.

---

### Bloque 1

**P1.1** — Los processors se ejecutan **en el orden exacto en que están listados** en el pipeline; la lista es una secuencia, no un conjunto. `memory_limiter` debe ir primero porque su función es rechazar datos **antes** de que consuman memoria en el resto de la cadena. Si `batch` fuera primero, el collector acumularía lotes de hasta 1024 items en memoria y recién después el limiter evaluaría la presión — es decir, el componente que causa el consumo actuaría antes que el que lo controla, y en un pico de tráfico el proceso moriría por OOM antes de poder aplicar backpressure.

**P1.2** — Un **resource attribute** describe la **entidad que produce** la telemetría (el proceso, el contenedor, el host, el pod): es invariante para todos los data points de esa fuente. Un **span/log attribute** describe **ese evento en particular** (el método HTTP de *esta* request, el `order_id` de *este* log). La distinción importa por eficiencia (el resource se serializa una sola vez por `ResourceSpans`/`ResourceLogs` y no por span) y por correlación: los backends indexan por resource para agrupar señales de una misma fuente. `service.name` es el único resource attribute **obligatorio** en la spec de OTel porque es la clave primaria de correlación entre traces, metrics y logs; si falta, la SDK lo setea a `unknown_service` y toda la telemetría de tu flota colapsa en un único servicio ficticio.

**P1.3** — Es **fail-fast**: una configuración inválida se detecta en el arranque, donde la detecta el pipeline de CI/CD o el `rollout status`, y no seis horas después cuando alguien busca un trace que nunca se guardó. Un pipeline de observabilidad que arranca "degradado" es el peor escenario posible, porque el sistema que debería avisarte de las fallas es el que está fallando en silencio. Operativamente esto se traduce en que la `readinessProbe` nunca pasa, el `rollout` no progresa, y el Deployment anterior sigue sirviendo tráfico.

**P1.4** — **gRPC (4317)** es el default para telemetría de alto volumen: HTTP/2 multiplexado, conexiones persistentes, serialización protobuf compacta, streaming bidireccional y menor overhead por request. **HTTP (4318)** se elige cuando hay un intermediario que no maneja bien gRPC (proxies L7 antiguos, algunos API gateways, WAFs), cuando la telemetría sale de un browser o de un entorno serverless con soporte gRPC limitado, o cuando necesitás debuggear con `curl` (como hicimos en el Bloque 4). OTLP/HTTP acepta tanto protobuf binario como JSON; JSON es más caro pero legible.

**P1.5** — `sampling_initial: 5` imprime los primeros 5 registros por intervalo y `sampling_thereafter: 200` luego uno de cada 200, lo que previene que el propio exporter de debug sature la salida y consuma CPU serializando texto. Aun así, `debug` con `verbosity: detailed` **nunca** debe quedar en producción: serializa cada span/métrica/log a texto legible, lo cual es órdenes de magnitud más caro que exportarlo en protobuf, y esa salida va a `stdout` del collector — que a su vez es recolectado por el agent, generando un bucle de amplificación.

---

### Bloque 2

**P2.1** — Un counter sólo puede crecer; su valor absoluto depende de cuándo arrancó el proceso, así que no es comparable entre réplicas ni interpretable por sí mismo. Lo operativamente relevante es la **derivada**: cuántos eventos por segundo. `rate()` calcula esa pendiente sobre la ventana indicada y, crucialmente, **detecta los resets**: si el valor de una muestra es menor que el de la anterior, asume que el proceso reinició y trata la caída como un reset a 0 en vez de como una tasa negativa, extrapolando la diferencia. Por eso `rate()` sobre un counter es correcto aun con reinicios, y por eso `rate()` no debe usarse sobre gauges.

**P2.2** — `le` es *less than or equal*: `..._bucket{le="0.5"}` cuenta **todas** las observaciones menores o iguales a 0.5 s, no las que caen entre el bucket anterior y ese. Por eso los buckets son acumulativos y `le="+Inf"` siempre iguala a `..._count`. `histogram_quantile()` no conoce los valores individuales, sólo los conteos por bucket, así que **interpola linealmente dentro del bucket** donde cae el cuantil buscado — el resultado es una aproximación cuya precisión depende enteramente de cuán bien elegiste los límites. Si el bucket más alto es `le="1"` y la latencia real es de 8 s, todas esas observaciones caen en el bucket `+Inf`, donde no hay límite superior para interpolar: Prometheus devuelve el borde superior del último bucket finito, o sea **1 s**. El p99 reportado sería 1 s mientras los usuarios esperan 8. Es el error más común y más caro en histogramas de latencia; los **native histograms** de Prometheus 3.x lo resuelven con buckets exponenciales automáticos.

**P2.3** — Sin `user_id`: 7 × 12 × 40 × 60 × 3 = **604 800 series**. Ya es mucho para una sola métrica. Con `user_id` de 100 000 valores: 604 800 × 100 000 = **6,048 × 10¹⁰ series**, o sea 60 mil millones. Es inviable porque en Prometheus **cada combinación única de labels es una time series independiente** con su propio índice invertido, su chunk de memoria en el head block y su entrada en el WAL. El coste no es de almacenamiento de valores, es de **metadata por serie** (~1–3 KB de RAM por serie activa). Además, `user_id` es un identificador de alta cardinalidad y sin valor agregado: nadie grafica "requests del usuario 87342". Ese dato pertenece a un **trace attribute** o a un **log attribute**, donde el coste es por evento y no por combinación.

**P2.4** — Es incorrecto porque el `labeldrop` ocurre **después** del scrape, en el `metric_relabel_configs`: 5000 series distintas colapsan al mismo identificador de serie, y Prometheus se queda con una de ellas de forma no determinística (además de emitir `duplicate sample for timestamp`). El resultado no es la suma sino un valor arbitrario. El `labeldrop` es una **mitigación de emergencia** para frenar una explosión en curso, no una solución. Lo correcto es del lado de la instrumentación: **no incluir `order_id` como label**; el counter debe agregarse en la aplicación (`orders_processed_total{region="eu-west-1"}` incrementado una vez por orden), y la trazabilidad de la orden individual vive en un span attribute o en un log.

**P2.5** — Prometheus modela el mundo como **cumulative**: cada scrape lee un total acumulado y el rate se deriva del delta entre scrapes. OTel soporta ambas temporalidades porque algunas fuentes (StatsD, sistemas push, funciones serverless de vida corta) sólo pueden reportar deltas. El Collector resuelve la conversión con dos processors: **`deltatocumulative`** para ingresar métricas delta a un backend Prometheus, y **`cumulativetodelta`** para el camino inverso (típicamente hacia backends comerciales que facturan y modelan por delta). La conversión delta→cumulative es stateful: el collector debe mantener el acumulado en memoria, lo que lo hace sensible a reinicios y a que las series estén siempre en la misma instancia.

**P2.6** — Por defecto, si el target expone un label que colisiona con uno que Prometheus quiere inyectar (`job`, `instance`, o cualquiera de los `external_labels`/relabels), Prometheus **renombra** el del target a `exported_<label>`. Con `honor_labels: true`, gana el valor del target. Es necesario en `otel-collector-export` porque el puerto 8889 reexporta métricas de **terceros** (las apps que enviaron OTLP al collector) que ya traen su propio `service_name`/`job`/`instance`; sin `honor_labels`, todas quedarían etiquetadas como si el collector fuera su origen, destruyendo la atribución.

---

### Bloque 3

**P3.1** — `start_at: end` hace que el receiver empiece a leer desde el final de cada archivo existente al momento de arrancar, ignorando el histórico. En un nodo con 20 GB de logs viejos, `beginning` provocaría que el agent intente ingerir esos 20 GB de golpe: saturación de CPU del nodo, saturación del gateway, saturación del backend, y una factura de ingest por datos que nadie pidió — todo esto en el peor momento posible, que es justo después de un reinicio. `beginning` se usa en casos acotados: primera instalación en un entorno donde el histórico sí importa, o recolección de archivos batch de vida corta que se escriben una vez y se leen una vez.

**P3.2** — La extensión **`file_storage`**, montada en un volumen persistente (un `hostPath` en un DaemonSet), y referenciada desde `filelog.storage: file_storage`. Persiste el offset de lectura y el fingerprint de cada archivo, de modo que tras un reinicio el receiver reanuda exactamente donde quedó en vez de saltar al final. Respecto de la garantía: OTLP ofrece **at-least-once** — el exporter reintenta ante fallo, así que un lote puede llegar duplicado si el ACK se pierde después de que el backend lo escribió. No hay exactly-once en el pipeline, y sin `file_storage` la garantía efectiva del `filelog` degrada a **at-most-once** frente a reinicios.

**P3.3** — **`Body`** es el mensaje en sí: el texto que un humano lee, o una estructura si el log era enteramente estructurado. **`Attributes`** son los campos clave-valor de **ese registro** (`order_id`, `duration_ms`, `log.file.path`). **`Resource attributes`** describen la **fuente** (pod, namespace, deployment, service.name) y son idénticos para todos los registros de ese contenedor. `SeverityNumber` existe además de `SeverityText` porque `SeverityText` es lo que la app escribió literalmente — `ERROR`, `err`, `E`, `crit`, `50` — y no es comparable ni ordenable entre aplicaciones. `SeverityNumber` es un entero normalizado (1–24, con `ERROR=17`, `WARN=13`, `INFO=9`, `DEBUG=5`) que permite escribir un filtro como `severity_number >= SEVERITY_NUMBER_WARN` que funciona uniformemente sobre toda la flota. Preservamos los dos: el número para filtrar, el texto para no perder el valor original.

**P3.4** — Sin la exclusión, el agent lee sus propios logs desde `/var/log/pods/observability_otel-agent-*`. Cada log que procesa genera (en nivel debug, o ante cualquier error de exportación) una línea en su propio stdout, que el agent lee en el siguiente ciclo, y que genera otra línea, y así sucesivamente. Es un **bucle de retroalimentación positiva**: el volumen crece exponencialmente hasta que el agent satura la CPU del nodo, llena el disco con `/var/log/pods`, o el `memory_limiter` empieza a rechazar todo — incluidos los logs legítimos de las aplicaciones. Por la misma razón se excluye el gateway.

**P3.5** — Sin el filtro, **cada réplica del `k8sattributes` procesador mantiene un informer/watch sobre TODOS los pods del cluster**. En 500 nodos eso son 500 watches completos contra el apiserver, cada uno cacheando el estado de todos los pods del cluster en memoria: presión brutal sobre el apiserver y etcd, y cientos de MB de RAM desperdiciados por nodo. Con `filter.node_from_env_var: K8S_NODE_NAME` cada agent limita su watch a los pods de **su propio nodo** (usando un `fieldSelector` sobre `spec.nodeName`), lo cual es exactamente el conjunto cuyos logs puede leer. Es una de las optimizaciones más importantes al escalar el pipeline.

**P3.6** — Escribir a `stdout`/`stderr` es la práctica correcta porque el **runtime del contenedor** captura esos streams y los escribe en un archivo rotado bajo `/var/log/pods/<ns>_<pod>_<uid>/<container>/N.log`, siguiendo un formato conocido (CRI) que kubelet, `kubectl logs` y cualquier recolector entienden sin configuración por aplicación. Si la app escribe a `/var/log/app.log` dentro de su propio filesystem: (1) **`kubectl logs` no muestra nada**, rompiendo la herramienta de diagnóstico universal; (2) el log **desaparece con el contenedor** — que es exactamente lo que pasa cuando el contenedor crashea, o sea justo cuando lo necesitás; (3) el recolector no lo ve, salvo que montes un volumen compartido y agregues un **sidecar** de recolección, lo que multiplica pods, memoria y superficie de configuración; y como bonus (4) el contenedor pierde su inmutabilidad y puede llenar su propio `ephemeral-storage` hasta ser desalojado por el kubelet.

---

### Bloque 4

**P4.1** —
| Campo | Valor | Bytes | Significado |
|---|---|---|---|
| `version` | `00` | 1 | versión del formato W3C Trace Context |
| `trace-id` | `5b8aa5a2d2c872e8321cf37308d69df2` | **16** | identificador global de la traza; debe ser distinto de todo cero |
| `parent-id` (span-id) | `a1b2c3d4e5f60718` | **8** | el span que **envía** la request; será el `parentSpanId` del receptor |
| `trace-flags` | `01` | 1 | bitfield; el bit menos significativo es `sampled` |

El trace-id es de 16 bytes (128 bits) para que dos servicios independientes puedan generarlo aleatoriamente sin coordinación y la probabilidad de colisión sea despreciable a escala global. El último octeto `01` significa **sampled = true**: el emisor decidió registrar esta traza y le está pidiendo a los servicios aguas abajo que hagan lo mismo.

**P4.2** — `kind: 3` es `SPAN_KIND_CLIENT` y `kind: 2` es `SPAN_KIND_SERVER` (`1`=INTERNAL, `4`=PRODUCER, `5`=CONSUMER). Un salto de red produce dos spans porque miden **cosas distintas**: el span CLIENT mide lo que el llamador percibe — incluye resolución DNS, establecimiento de conexión TLS, latencia de red de ida y vuelta, y tiempo en cola del cliente; el span SERVER mide sólo lo que el servidor tardó en procesar. La **diferencia entre ambos es la latencia de red y de encolamiento**, y es la única forma de distinguir "el backend está lento" de "la red entre nosotros está lenta". Colapsarlos en un span borra esa distinción, que suele ser la respuesta al incidente.

**P4.3** — El servicio aguas abajo no recibe contexto, así que su SDK genera un **trace-id nuevo** y crea un span raíz sin padre. En la UI se ven **dos trazas separadas**: una que termina abruptamente en el span CLIENT del llamador (sin hijos, con una duración inexplicablemente larga que no se puede desagregar), y otra que empieza de la nada en el servicio receptor. El síntoma característico es "todas mis trazas terminan en el proxy" o "tengo miles de trazas de un solo span". El diagnóstico se confirma inspeccionando si los servicios receptores tienen spans raíz de tipo SERVER (nunca deberían, salvo en el borde del sistema).

**P4.4** — Un **span event** es una anotación con timestamp **dentro** de un span, que comparte todo su contexto (trace_id, span_id, resource) y su ciclo de vida: existe sólo si el span existe y se muestra como un punto en la waterfall. Un **Kubernetes Event** es un objeto de la API de Kubernetes (`events.k8s.io/v1`), almacenado en etcd, con un TTL de 1 h, que describe un cambio de estado de un objeto del cluster (`involvedObject`/`regarding`) reportado por un componente del control plane — no tiene nada que ver con OTel. La diferencia entre span event y log record es más sutil: en el data model de OTel son **estructuralmente muy parecidos** (timestamp + nombre/body + atributos), y de hecho la spec desaconseja los span events para casos nuevos a favor de log records con trace context, precisamente porque un log record puede existir fuera de un span, tiene severidad, y se enruta al pipeline de logs, que suele ser más barato y con retención distinta a la de traces.

**P4.5** — Con `payments` 4 s adelantado, sus spans aparecen en la waterfall **empezando después** de que el span padre terminó, o incluso **fuera del rango del trace**: barras flotando a la derecha, duraciones negativas calculadas por la UI, o un span hijo que "empieza antes de que lo llamaran". Jaeger dibuja estos casos con un warning de *clock skew adjustment* y aplica una corrección heurística asumiendo que el hijo debe estar contenido en el padre. Se detecta buscando ese warning en la UI o monitoreando `node_timex_offset_seconds` / `node_timex_sync_status` de node-exporter. Se mitiga con **NTP/chrony correctamente configurado en todos los nodos** — es un requisito de infraestructura del tracing distribuido, no un detalle. Nótese que las **duraciones** de cada span individual son correctas aunque el reloj esté corrido; lo que se rompe es el **ordenamiento relativo** entre servicios.

**P4.6** — `partialSuccess` transporta `rejectedSpans`/`rejectedDataPoints`/`rejectedLogRecords` (cuántos items el backend descartó) y un `errorMessage` explicando por qué — típicamente por límites de tamaño, atributos inválidos, timestamps fuera de rango de retención, o cuota excedida. Es **HTTP 200 con pérdida parcial**: el request fue válido, el backend lo aceptó, pero no guardó todo. Un exporter que sólo mira el status code ve "200 OK", no reintenta, no incrementa ningún contador de error, y **pierde datos en absoluto silencio**. Por eso las métricas de `otelcol_exporter_send_failed_*` deben complementarse con la vigilancia de partial success en el backend de destino.

---

### Bloque 5

**P5.1** — Es la **agregación/deduplicación del `EventRecorder`** del cliente de Kubernetes: cuando el mismo componente emite repetidamente un evento con la misma combinación de `involvedObject` + `reason` + `message` + `source`, en vez de crear objetos nuevos hace un `PATCH` incrementando `count` y actualizando `lastTimestamp`. En la API `events.k8s.io/v1` esto se modela explícitamente con el campo `series` (`series.count`, `series.lastObservedTime`). Lo que se pierde son los **timestamps individuales de cada ocurrencia**: sabés que pasó 7 veces entre las 12:22 y las 12:24, pero no si fueron 7 veces seguidas al principio o distribuidas uniformemente. Para análisis de frecuencia hay que exportar los eventos a un backend de logs, como hicimos con `k8sobjects`.

**P5.2** — Consecuencias: (1) un incidente que empezó hace 3 horas ya **no tiene eventos**, y perdiste la evidencia de por qué el pod fue evicted, por qué falló el scheduling, o cuándo empezó el `BackOff`; (2) `kubectl describe pod` sobre un pod problemático muestra `Events: <none>` justo cuando lo necesitás, llevando al operador a conclusiones erróneas ("no hay eventos, entonces no pasó nada"). Mitigaciones: (a) **exportar los eventos a un backend de logs con retención larga**, que es exactamente lo que hace el receiver `k8sobjects` de este ejercicio, o herramientas como `kubernetes-event-exporter`; (b) subir `--event-ttl` en el kube-apiserver — con la advertencia de que los eventos viven en **etcd** y aumentar la retención aumenta la presión sobre el datastore del cluster, así que es la opción inferior. La regla operativa: **los Events son un buffer efímero, no un registro de auditoría**; para eso está el audit log del apiserver.

**P5.3** — Porque el pod `too-big` **nunca tuvo un contenedor corriendo**: se quedó en estado `Pending` y no hay proceso alguno cuyo stdout capturar, así que `kubectl logs` no tiene fuente. El evento lo emitió el **kube-scheduler**, un componente del control plane, sobre el objeto `Pod` como `involvedObject`. Este es exactamente el nicho que ocupan los Events y que ninguna otra señal cubre: describen lo que le pasa a un **objeto de la API** desde la perspectiva del control plane, incluso — y sobre todo — cuando no hay workload corriendo para emitir logs o métricas. Un pipeline de observabilidad que sólo recolecta logs de contenedor es ciego a toda la clase de fallos `Pending`/`FailedScheduling`/`FailedMount`/`Evicted`.

**P5.4** — Si `k8sobjects` estuviera en el DaemonSet de 3 nodos, cada réplica abriría su propio watch sobre los Events del apiserver y recibiría **todos** los eventos (los Events no están particionados por nodo). Resultado: **cada evento se ingiere 3 veces**, triplicando el volumen, el coste y — peor — inflando cualquier conteo de tipo "cuántos `BackOff` hubo" por un factor igual al número de nodos. Mismo problema si el gateway escalara a `replicas: 3`: se duplicaría por 3. Los receivers que consumen una **fuente global** (`k8sobjects`, `k8s_cluster`, `kubeletstats` sobre el apiserver) deben correr en **exactamente una** instancia: un Deployment con `replicas: 1`, o un StatefulSet con leader election vía la extensión correspondiente. Los receivers que consumen una **fuente local al nodo** (`filelog`, `hostmetrics`, `kubeletstats` local) van en el DaemonSet. Esa es la razón de fondo por la que existe la topología agent+gateway.

**P5.5** — Con `reason` (~50 valores conocidos), `namespace` (digamos 40), `pod` (5000 en un cluster mediano) y `node` (500), el techo teórico es 50 × 40 × 5000 × 500 = **5 × 10⁹ series**. En la práctica sólo se materializan las combinaciones que ocurren, pero el problema real es distinto y peor: `pod` es un label de **alta rotación** — cada deploy genera pods con hash nuevo, así que las series viejas quedan como *stale* ocupando índice y memoria durante horas. Se llama *churn* de cardinalidad y degrada Prometheus incluso cuando el conteo instantáneo de series parece aceptable. Alternativa correcta: emitir una métrica **agregada** `kube_events_total{reason, type, namespace}` — sin `pod` ni `node` — para alertar sobre tendencias ("los `FailedScheduling` en `prod` subieron 10x"), y **enviar el evento completo, con `pod` y `node`, al backend de logs**, donde el coste es por evento ingerido y no por combinación de labels. Es el principio general: *dimensiones acotadas y estables → métricas; identificadores de alta cardinalidad → logs y traces.*

**P5.6** —
- **Kubernetes Event**: objeto de la API de Kubernetes que reporta un cambio de estado de un recurso del cluster (`FailedScheduling`, `BackOff`), emitido por un componente del control plane, con TTL de ~1 h en etcd.
- **Span event**: anotación con timestamp dentro de un span de OpenTelemetry, que marca algo que ocurrió durante esa operación (típicamente una excepción), compartiendo el contexto del span.
- **CloudEvent**: especificación **CNCF** de un formato de sobre estándar (`id`, `source`, `type`, `specversion`, `data`) para interoperabilidad de eventos **de negocio/integración** entre sistemas dispares (Knative Eventing, EventBridge, brokers). No es una señal de observabilidad: es un contrato de mensajería.

---

### Bloque 6

**P6.1** — Un **connector** es un componente que actúa como **exporter en un pipeline y receiver en otro**: consume telemetría del final de un pipeline y produce telemetría — posiblemente de otra señal — al inicio de otro. Es el mecanismo por el que OTel permite derivar una señal de otra sin salir del proceso. La doble declaración es obligatoria porque es literalmente cómo se expresa la conexión: `spanmetrics` en `pipelines.traces.exporters` define de dónde toma los spans, y en `pipelines.metrics/spanmetrics.receivers` define adónde entrega las métricas resultantes. Si declarás sólo una de las dos, el collector falla al construir el grafo (`connector "spanmetrics" must be used as both receiver and exporter`). Otros connectors útiles: `forward` (unir/dividir pipelines), `routing` (enrutar por atributo), `count`, `servicegraph`.

**P6.2** — Si el sampler descarta el 90 % de los spans **antes** de que el connector los vea, `traces_span_metrics_calls_total` cuenta sólo el 10 % restante: la métrica de tasa queda subestimada 10x, y el *error ratio* queda **sesgado** de forma impredecible (el sampling probabilístico es uniforme, así que el ratio sobrevive en promedio, pero cualquier sampler basado en política — como tail sampling que prioriza errores — lo distorsiona brutalmente hacia arriba). El principio es: **calculá las métricas sobre el 100 % de los datos, muestreá sólo lo que vas a almacenar**. La forma de lograrlo es bifurcar el pipeline con el connector `forward` o con dos pipelines: uno `traces` sin sampler cuyo exporter es `spanmetrics`, y otro `traces/sampled` con el sampler que exporta al backend. Así el connector ve todo y Jaeger recibe la fracción muestreada.

**P6.3** — `url.full` con IDs en la ruta (`/orders/ord-00042/items`) produce **un valor de label por request única**, o sea cardinalidad ilimitada. Como `spanmetrics` genera una serie por combinación de dimensiones y mantiene ese estado en memoria hasta `metrics_expiration`, el connector empezaría a consumir memoria sin límite: el `memory_limiter` empezaría a rechazar, y si no está bien configurado, el collector muere por OOM. La dimensión correcta es la **ruta parametrizada** (`http.route` = `/orders/{id}/items`), que es un valor por endpoint y no por request — y por eso la semantic convention de OTel define `http.route` como un atributo separado de `url.path`.

**P6.4** — Un exemplar es un **puntero desde un data point agregado hacia una observación individual concreta** (con su `trace_id`, `span_id`, valor y timestamp). El formato de exposición clásico de Prometheus tiene una gramática de línea `nombre{labels} valor [timestamp]` que no tiene lugar sintáctico para adjuntar metadatos adicionales. **OpenMetrics** extiende esa gramática con el sufijo ` # {labels} valor timestamp` después del valor de la muestra, y limita los exemplars a buckets de histogram y a counters. Por eso hay que negociar el content type con `Accept: application/openmetrics-text`. Del lado de Prometheus hace falta `--enable-feature=exemplar-storage`, que habilita un buffer circular en memoria dedicado a exemplars (con su propia retención, independiente del TSDB) y la API `/api/v1/query_exemplars`. Los **native histograms** también soportan exemplars sin depender del formato de texto.

**P6.5** — El **`trace_id`** (y secundariamente el `span_id`). Para que exista en los logs hay que garantizar dos cosas en la aplicación: (1) que el **contexto de trace esté activo** en el momento de loguear, es decir que el logging ocurra dentro del scope del span — lo cual en la práctica significa usar la instrumentación de logging de OTel o un `MDC`/`contextvar` alimentado por la SDK; y (2) que el **logger emita ese campo** en la salida estructurada. Casi todos los frameworks tienen integración lista (`opentelemetry-instrumentation-logging` en Python, el `MDC` automático de OTel Java, `slog` handlers en Go). El fallo más común es loguear desde un thread pool o una goroutine a la que no se propagó el `Context`: el log sale sin trace_id y la correlación se pierde exactamente en el código asincrónico, que es donde más se necesita.

**P6.6** — **Ventaja**: obtenés RED metrics **uniformes para todos los servicios sin tocar una línea de código de aplicación** ni coordinar con 40 equipos sobre cómo nombrar sus contadores; la instrumentación de tracing, que ya existe, te da métricas gratis y consistentes, con dimensiones normalizadas por semantic conventions. **Desventaja**: las métricas dependen del pipeline de traces — si el sampling, un `memory_limiter` o una caída del collector afectan los spans, tus métricas mienten sin avisar; además hereda la cardinalidad de los `span_name`, que en apps mal instrumentadas pueden ser ilimitados. Un contador explícito en la aplicación es más barato, sobrevive a cualquier problema del pipeline de traces, y es la fuente de verdad correcta para un SLI que respalda un SLO contractual. La práctica madura: **spanmetrics para cobertura amplia y descubrimiento, contadores explícitos para los SLIs que importan.**

---

### Bloque 7

**P7.1** — Porque la decisión de tail sampling se toma sobre **propiedades del trace completo** ("¿tuvo algún span con error?", "¿la duración total superó 500 ms?"), y para evaluarlas el processor tiene que **bufferear en memoria todos los spans de ese trace_id** hasta que expire `decision_wait`. Si los spans de un mismo trace aterrizan en réplicas distintas — que es lo que pasa con un Service de Kubernetes balanceando por conexión — cada réplica ve un fragmento, evalúa políticas sobre datos incompletos, y decide distinto: el resultado son trazas parciales, con algunos spans guardados y otros descartados, que es peor que no tener la traza. Se resuelve con una **capa de collectors adicional** delante del gateway que usa el **`loadbalancing` exporter** con `routing_key: traceID`: hashea el trace_id y enruta consistentemente todos los spans de una traza a la misma instancia downstream. El mismo exporter soporta `routing_key: service` para otros casos.

**P7.2** — Con `decision_wait: 10s` y trazas de 25 s, el processor toma la decisión cuando aún faltan 15 s de spans por llegar. Los spans que llegan **después** de la decisión pertenecen a un trace_id ya evaluado y descartado (o ya emitido), así que se pierden o se emiten como fragmento tardío: obtenés **trazas truncadas** que muestran el principio de la operación y no el final — que suele ser donde está el error. Regla: `decision_wait` debe ser mayor que el p99 de la duración de tus trazas. Subirlo a 60 s tiene su propio costo: el buffer en memoria crece linealmente con `decision_wait × spans_por_segundo`, así que hay que subir también `num_traces` y la memoria del pod, y agregás 60 s de latencia entre que ocurre un error y que la traza es visible en el backend — lo que degrada el tiempo de diagnóstico durante un incidente.

**P7.3** — **Descarta los INFO y los DEBUG.** El `filter` processor con `error_mode`/`log_record` funciona con lógica de **drop-on-match**: las expresiones OTTL listadas son condiciones y todo registro que las satisface es eliminado del pipeline. `SEVERITY_NUMBER_WARN` es 13, `INFO` es 9 y `DEBUG` es 5, así que `severity_number < SEVERITY_NUMBER_WARN` matchea INFO y DEBUG y los tira, dejando pasar WARN (13), ERROR (17) y FATAL (21). Es una fuente de bugs frecuente porque la intuición inicial de mucha gente es que un "filtro" describe lo que se conserva; en este processor es exactamente al revés.

**P7.4** —
| Eje | Head sampling | Tail sampling |
|---|---|---|
| **Dónde se decide** | En el primer servicio del trace, **antes** de que la operación ocurra; la decisión viaja en el bit `sampled` del `traceparent` | En el collector, **después** de que la traza completa llegó y se bufferó |
| **Coste en la app** | Mínimo: los spans no muestreados nunca se crean ni se serializan | Alto: la app debe emitir el **100 %** de los spans, con su coste de CPU y red |
| **Coste en el pipeline** | Bajo: sólo circula la fracción muestreada | Alto: hay que ingerir, bufferear en memoria y enrutar consistentemente el 100 % |

**El tail sampling es el único que garantiza capturar el 100 % de los errores**, porque cuando decide ya sabe si hubo un error. El head sampling decide a ciegas: si sorteó descartar una traza y esa traza terminó fallando, la evidencia no existe. Por eso el patrón de producción típico es híbrido: head sampling agresivo para tráfico obviamente irrelevante (health checks, `/metrics`), y tail sampling con políticas para el resto.

**P7.5** — Las métricas de mesh se emiten **por par (origen, destino)**, así que la dimensión no es "80" sino "80 orígenes × 80 destinos" = hasta 6400 pares, multiplicado por `response_code` (~15 valores usados), `connection_security_policy` (2) y las dimensiones de reporter/protocolo. El crecimiento es cuadrático en el número de servicios porque el grafo de llamadas es el producto cartesiano potencial de los workloads. Mitigaciones estándar: (a) **desactivar dimensiones que nadie consulta** (`connection_security_policy`, `request_protocol`, `source_principal`) vía la configuración de telemetría del mesh; (b) **agregar en el collector** con el processor `metricstransform`/`transform` antes de exportar, colapsando dimensiones para las series de largo plazo; (c) usar **recording rules** en Prometheus para pre-agregar las consultas de dashboard y aplicar retención corta a las series crudas; (d) para el grafo de servicios en sí, considerar el connector `servicegraph`, que produce el mismo dato con dimensiones acotadas.

**P7.6** — El **hash preserva la capacidad de agrupar y contar**: podés seguir respondiendo "¿cuántos usuarios distintos fueron afectados por este error?" o "¿estas 40 requests fallidas son del mismo usuario o de 40 usuarios distintos?", que es información diagnóstica de primer orden, sin que el identificador real salga del cluster. El `delete` destruye eso por completo. El **riesgo residual** es que un hash sin sal (salt) de un espacio de identificadores enumerable o de baja entropía — emails, IDs numéricos secuenciales, teléfonos — es **reversible por fuerza bruta o por diccionario** en segundos: el atacante hashea todos los candidatos y compara. Es pseudonimización, no anonimización: bajo GDPR el dato pseudonimizado **sigue siendo dato personal**. Para uso real hay que salar el hash con un secreto rotado y tratar la salida con los mismos controles de acceso que el dato original.

---

### Bloque 8

**P8.1** —
- **`otelcol_receiver_refused_*`** — el receiver **rechazó datos en la entrada**, típicamente porque el `memory_limiter` está activo o la cola downstream está llena. La causa raíz está **dentro** del collector: está saturado. El emisor recibe un error y (si es OTLP) puede reintentar. Es la señal de que hay que escalar el collector o subirle recursos.
- **`otelcol_processor_dropped_*`** — un **processor descartó los datos deliberadamente**: sampling, filtrado, o el `memory_limiter` en modo drop. La causa raíz es **la configuración** — puede ser totalmente intencional. Hay que compararlo contra lo que esperabas descartar.
- **`otelcol_exporter_send_failed_*`** — el **backend de destino no aceptó los datos** tras agotar los reintentos: caído, inalcanzable, rechazando por autenticación, o aplicando rate limiting. La causa raíz está **fuera** del collector. Es pérdida de datos real y es lo que debe despertar a alguien.

**P8.2** — Cuando la `sending_queue` está llena, el exporter **rechaza los lotes nuevos inmediatamente** (`Exporting failed. Rejecting data` con `dropped_items`) en vez de bloquear. Ese rechazo se propaga hacia atrás por el pipeline hasta el receiver, que responde al emisor con un error. Con **OTLP/gRPC** el emisor recibe `RESOURCE_EXHAUSTED` o `UNAVAILABLE`, y la SDK de la aplicación aplica su propio retry con backoff y encola en su BSP (`BatchSpanProcessor`) — si la presión persiste, la SDK **descarta desde su propia cola**, protegiendo a la aplicación de quedarse sin memoria: hay backpressure real y end-to-end. Con un receiver de **scrape** como `prometheus` no hay backpressure posible: el collector simplemente no scrapea o descarta lo scrapeado, y el target nunca se entera; la pérdida es silenciosa del lado de la aplicación y sólo visible en las métricas del collector. Esa asimetría push/pull es una diferencia estructural entre los modelos.

**P8.3** — Los datos encolados **se pierden**: viven en el heap del proceso y desaparecen con él, sea por reprogramación, OOM kill, o un `rollout restart` como los que hicimos en este laboratorio. Lo resuelve la extensión **`file_storage`**, referenciada desde `sending_queue.storage`: la cola se persiste en disco (un PVC o un `hostPath`) y se reanuda al reiniciar. El trade-off es I/O de disco por cada lote y la necesidad de almacenamiento persistente para el pod, lo que convierte al gateway en un StatefulSet. La decisión depende de cuánto valen los datos en tránsito: para traces muestreados normalmente no vale la pena; para logs de auditoría o métricas de facturación, sí.

**P8.4** — Las otras tres alertan sobre **una condición anómala presente**: hay fallos, hay cola llena, hay rechazos — todas se disparan porque *aparece* algo malo. `TelemetryPipelineSilent` alerta sobre la **ausencia de datos**, y esa es la única que detecta el fallo más peligroso de un sistema de monitoreo: que **deje de recibir telemetría por completo**. Si el agent muere, si un NetworkPolicy corta el tráfico al gateway, si un cambio de config rompe el receiver, o si simplemente nadie desplegó la instrumentación, ninguna de las otras tres alertas se dispara — porque no hay datos que fallen. Todo se ve verde y el equipo concluye que no hay problemas. Es el patrón de **dead man's switch**, y toda plataforma de observabilidad necesita al menos uno: una alerta que se dispara por silencio, con un heartbeat sintético que la respalde.

**P8.5** — Porque el rechazo es **controlado, selectivo y observable**, mientras que el OOM kill es catastrófico e indiscriminado. Con `memory_limiter`: el collector rechaza datos nuevos, incrementa `otelcol_receiver_refused_*`, sigue vivo, sigue drenando su cola hacia el backend, sigue exponiendo su self-telemetry, y aplica backpressure al emisor — que puede reintentar. Cuando la presión cede, se recupera solo, sin intervención. Con un OOM kill: el kernel mata el proceso, **se pierde todo lo encolado en memoria**, el pod entra en `CrashLoopBackOff` (con backoff exponencial, así que las caídas se hacen cada vez más largas), y durante ese tiempo **no hay telemetría de nada** — incluida la telemetría que te explicaría el incidente que probablemente causó el pico de carga. Es la diferencia entre degradación elegante y falla total, y por eso `memory_limiter` es el primer processor de todo pipeline serio, junto con un `GOMEMLIMIT` coherente con el `resources.limits.memory` del contenedor.

</details>

---

## Fuentes

Todo el material de este documento es original; los conceptos, nombres de campo y comportamientos descritos se verifican contra la documentación oficial siguiente.

**Currículum y examen**
- CNCF — *CNPA Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf

**OpenTelemetry**
- Concepts / Signals: https://opentelemetry.io/docs/concepts/signals/
- Especificación OTLP: https://opentelemetry.io/docs/specs/otlp/
- Logs Data Model: https://opentelemetry.io/docs/specs/otel/logs/data-model/
- Trace Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
- Collector — Configuración: https://opentelemetry.io/docs/collector/configuration/
- Collector — Internal telemetry: https://opentelemetry.io/docs/collector/internal-telemetry/
- Collector — Deployment patterns (agent/gateway): https://opentelemetry.io/docs/collector/deployment/
- Sampling: https://opentelemetry.io/docs/concepts/sampling/
- `filelogreceiver`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
- `k8sobjectsreceiver`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/k8sobjectsreceiver
- `k8sattributesprocessor`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- `tailsamplingprocessor`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- `filterprocessor`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/filterprocessor
- `spanmetricsconnector`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector
- `loadbalancingexporter`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- `telemetrygen`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen

**W3C**
- Trace Context (Recommendation): https://www.w3.org/TR/trace-context/

**Prometheus / OpenMetrics**
- Data model: https://prometheus.io/docs/concepts/data_model/
- Metric types: https://prometheus.io/docs/concepts/metric_types/
- Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Naming conventions: https://prometheus.io/docs/practices/naming/
- Exemplars: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- Configuración y relabeling: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- OpenMetrics: https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md

**Kubernetes**
- Event v1 (core) API: https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- Logging architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Metrics for Kubernetes system components: https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- kube-apiserver flags (`--event-ttl`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/

**Jaeger**
- Documentación: https://www.jaegertracing.io/docs/
- Service Performance Monitoring (SPM): https://www.jaegertracing.io/docs/latest/spm/

**Fundamentos SRE**
- Google SRE Book — *Monitoring Distributed Systems* (Four Golden Signals): https://sre.google/sre-book/monitoring-distributed-systems/