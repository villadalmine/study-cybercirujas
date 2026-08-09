# 3.2 Entender Logs y Events

> **Dominio:** Observability Concepts · **Peso en el examen:** 3 · **Certificación:** Prometheus Certified Associate (PCA)
>
> Prometheus es un sistema de *métricas*. **No** almacena, indexa ni consulta logs, y trata los Events de Kubernetes solo de manera indirecta. Sin embargo, el temario de la PCA exige que *entiendas* los logs y los events porque una métrica por sí sola responde **"cuánto / con qué frecuencia"** — nunca responde **"qué request, en qué pod, con qué cadena de error, en qué orden."** Este tema trata de saber con precisión dónde termina el pilar de las métricas, qué agregan los logs y los events, y cómo se correlacionan ambos planos en un stack de observabilidad de producción.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 La distinción central que una métrica no puede cruzar

Una métrica de Prometheus es una **muestra numérica** agregada sobre un conjunto de labels y muestreada en un intervalo de scrape fijo. Ese diseño te compra series temporales baratas, de cardinalidad acotada y retención larga — pero estructuralmente descarta dos cosas:

1. **El detalle por evento.** `http_requests_total{code="500"}` te dice que 47 requests fallaron en el último minuto. No puede decirte *cuáles* 47, el stack trace, el trace ID, ni el payload ofensor.
2. **El orden y las transiciones de estado discretas.** Un counter que pasa de `5 → 6` pierde el hecho de que "a las 14:03:22.114Z el pod `checkout-7f9` fue `OOMKilled` tras el reinicio `BackOff` #4."

Los logs recuperan (1); los events recuperan (2). Este es el clásico encuadre de los **tres (o cuatro) pilares**: *metrics, logs, traces* — con los **events** frecuentemente señalados como una cuarta señal distinta porque son discretos, autodescriptivos y típicamente de bajo volumen pero alto valor.

```
                    aggregated / numeric                discrete / textual
                 ┌──────────────────────────┐   ┌──────────────────────────────┐
   sampled  ───► │  METRICS (Prometheus)     │   │  TRACES (Tempo/Jaeger)       │
                 │  "how much, how often"    │   │  "where the time went"       │
                 └──────────────────────────┘   └──────────────────────────────┘
   per-event ──► ┌──────────────────────────┐   ┌──────────────────────────────┐
                 │  EVENTS (k8s API, CloudEvents) │  LOGS (Loki/ELK/OTel)        │
                 │  "what changed, in order" │   │  "what exactly happened"     │
                 └──────────────────────────┘   └──────────────────────────────┘
```

### 1.2 La brecha RED/USE en producción

Te llega la página: `ALERTS{alertname="HighErrorRate", service="checkout"}` se dispara. Prometheus te llevó hasta el **síntoma** y hasta el **servicio** (vía labels), pero la causa raíz — `pq: too many connections`, o `OOMKilled` — vive en los logs y los events. Un stack maduro se construye de modo que una sola alerta te lleve a través de los planos:

- **Métrica** (Prometheus): la tasa de errores cruzó el umbral → alerta con labels `namespace`, `pod`, `service`.
- **Event** (Kubernetes): `kubectl get events` muestra `Warning OOMKilling` / `BackOff` en ese pod.
- **Log** (Loki): el *mismo conjunto de labels* (`namespace`, `pod`) te lleva directo a la línea de stderr y al trace ID.
- **Trace** (Tempo): el trace ID del log abre el span exacto que falla.

El requisito arquitectónico son **convenciones de labels compartidas** para que un humano (o un "drilldown" de Grafana) pueda moverse entre planos sin volver a buscar. Loki fue diseñado explícitamente para que los logs se "sientan como Prometheus" precisamente para habilitar este pivote.

### 1.3 Los Events de Kubernetes son efímeros por diseño — el problema de la pérdida silenciosa

Los objetos `Event` de Kubernetes se almacenan en etcd como cualquier objeto de la API, pero el API server los **recolecta como basura tras `--event-ttl` (por defecto `1h0m0s`)**. Esta es la sorpresa de producción más común: el post-mortem empieza dos horas después del incidente y `kubectl get events` no muestra *nada*. Los events deben **exportarse fuera del cluster** a un sink duradero (Loki, Elasticsearch, un webhook, un bus de eventos) si han de sobrevivir a la revisión de un incidente. Esa exportación es una decisión arquitectónica explícita, no un valor por defecto.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Las cuatro señales de telemetría

| Dimensión | Metrics | Logs | Events (k8s) | Traces |
|---|---|---|---|---|
| Forma | Series temporales numéricas | Líneas de texto/JSON con timestamp | Objetos estructurados de la API | Spans en un DAG |
| Pregunta principal | Cuánto / con qué frecuencia | Qué pasó exactamente | Qué cambió, en qué orden | A dónde se fue la latencia |
| Tolerancia a la cardinalidad | **Baja** (labels acotados) | Alta (indexado solo por labels, en Loki) | Bajo volumen | Media |
| Costo de almacenamiento / GB de señal | El más bajo | El más alto (texto crudo) | Bajo | Alto |
| Retención (típica) | Semanas–meses | Días–semanas | **≈1h in-cluster** (hay que exportar) | Días |
| Lenguaje de consulta | PromQL | LogQL / Lucene / KQL | `kubectl`, field selectors | TraceQL |
| Modo de falla por cardinalidad | Explosión del TSDB (churn) | Explosión del índice (si se indexa el contenido) | Presión sobre etcd (event storms) | Pérdida por sampling |
| Herramienta CNCF/eco | Prometheus | Loki, Fluent Bit, ELK, OTel | kube-event-exporter, k8s API | Tempo, Jaeger |

**Insight clave a nivel de examen:** el *mismo* enemigo — la **alta cardinalidad** — perjudica a cada señal de manera diferente. En Prometheus hace explotar la cantidad de series activas; en un sistema de logs que indexa el contenido (ELK) hace explotar el índice invertido; en Loki se evita deliberadamente indexando **solo los labels** y manteniendo el cuerpo del log sin indexar y comprimido.

### 2.2 Arquitecturas de agregación de logs

| Propiedad | Loki | Elasticsearch (EFK/ELK) |
|---|---|---|
| Alcance del índice | **Solo labels** (metadata) | Índice invertido full-text sobre el contenido |
| Backend de almacenamiento | Object store (S3/GCS) + índice pequeño | Shards locales/replicados en SSD |
| Perfil de costo | Bajo (sin índice de contenido) | Alto (índice + almacenamiento caliente) |
| Modelo de consulta | Filtro por label → scan tipo **grep** de los chunks (LogQL) | Full-text rico, agregaciones |
| Mejor cuando | Alto volumen, acceso guiado por labels, tienda Prometheus | Búsqueda full-text ad-hoc, security/SIEM |
| Riesgo de cardinalidad | Los **labels** de alta cardinalidad lo matan (poné los IDs en la *línea*, no en labels) | Cardinalidad de contenido tolerada pero cara |
| Afinidad con Prometheus | Nativa (mismos labels, pivote en Grafana) | Requiere pegamento de correlación |

### 2.3 Convertir logs/events en métricas — donde se encuentran los planos

A veces necesitás un *número* a partir de un log o un event (p. ej. "tasa de líneas `panic:`"). Tres patrones canónicos:

| Herramienta / mecanismo | Entrada | Salida | Cuándo usarlo |
|---|---|---|---|
| **Loki LogQL metric queries** (`rate(... [5m])`, `unwrap`) | Stream de logs | Vector estilo Prometheus | Ad-hoc; ya corrés Loki |
| **google/mtail** | Líneas de archivos de log (programas regex) | Endpoint `/metrics` | Extraer métricas en el nodo, sin necesidad de backend de logs |
| **grok_exporter** | Líneas de log (patrones grok) | Endpoint `/metrics` | Logs legacy/no estructurados, patrones estilo Logstash |
| **kube-state-metrics** | Objetos de la API de k8s (incl. `kube_pod_status_reason`) | `/metrics` | El *estado* de los objetos como métricas (no events crudos) |
| **kubernetes-event-exporter → Prometheus** | Events de k8s | métricas/labels vía sink | Alertar sobre los *reasons* de los events (p. ej. `OOMKilling`) |

> **Anti-patrón:** parsear identificadores de alta cardinalidad (request IDs, user IDs) desde los logs hacia labels de Prometheus. Esto recrea la explosión de cardinalidad que Prometheus está diseñado para evitar. Mantené esos en el cuerpo del log / trace, y conservá solo dimensiones acotadas (`reason`, `code`, `service`) como labels de métrica.

---

## 3. Manifiestos completos e infraestructura

### 3.1 Loki (single-binary) + Promtail DaemonSet — el plano de logs adyacente a Prometheus

`loki-config.yaml` (montado dentro del pod de Loki):

```yaml
# loki-config.yaml — single-binary Loki suitable for a small/medium cluster.
# Source of options: https://grafana.com/docs/loki/latest/configure/
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:            # swap for S3/GCS in production (see storage_config)
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  # Guardrails that keep Loki healthy: bound label cardinality and stream churn.
  ingestion_rate_mb: 8
  ingestion_burst_size_mb: 16
  max_label_names_per_series: 15
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_streams_per_user: 10000

# Loki can run Prometheus-style recording/alerting rules over LogQL.
ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /loki/rules-temp
  alertmanager_url: http://alertmanager.monitoring.svc:9093
  enable_alertmanager_v2: true
```

`promtail.yaml` — el agente del nodo que descubre pods y adjunta **labels compatibles con Prometheus**:

```yaml
# promtail.yaml — Promtail scrapes container logs and relabels using the
# Kubernetes SD, mirroring Prometheus relabel semantics so labels line up.
# https://grafana.com/docs/loki/latest/send-data/promtail/configuration/
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /run/promtail/positions.yaml   # resume offset after restart (idempotency)

clients:
  - url: http://loki.monitoring.svc:3100/loki/api/v1/push

scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    pipeline_stages:
      - cri: {}                            # parse CRI log format (time, stream, flags, content)
      - match:
          selector: '{app="checkout"}'
          stages:
            - json:                        # extract structured fields from JSON logs
                expressions:
                  level: level
                  trace_id: trace_id
            - labels:
                level:                     # low-cardinality -> safe as a label
            # NOTE: trace_id is intentionally NOT promoted to a label
            #       (high cardinality); it stays queryable in the line body.
    relabel_configs:
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
      - source_labels: [__meta_kubernetes_pod_container_name]
        target_label: container
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node
      - source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
        target_label: __path__
        separator: /
        replacement: /var/log/pods/*$1/*.log
```

DaemonSet + RBAC para Promtail:

```yaml
# promtail-daemonset.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "services", "endpoints", "pods"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail
subjects:
  - kind: ServiceAccount
    name: promtail
    namespace: monitoring
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: monitoring
  labels: { app: promtail }
spec:
  selector:
    matchLabels: { app: promtail }
  template:
    metadata:
      labels: { app: promtail }
    spec:
      serviceAccountName: promtail
      tolerations:
        - effect: NoSchedule
          operator: Exists            # run on control-plane nodes too
      containers:
        - name: promtail
          image: grafana/promtail:3.0.0
          args: ["-config.file=/etc/promtail/promtail.yaml"]
          ports:
            - { name: http-metrics, containerPort: 9080 }
          volumeMounts:
            - { name: config,    mountPath: /etc/promtail }
            - { name: run,       mountPath: /run/promtail }
            - { name: pods,      mountPath: /var/log/pods, readOnly: true }
            - { name: containers,mountPath: /var/lib/docker/containers, readOnly: true }
      volumes:
        - name: config
          configMap: { name: promtail }
        - name: run
          hostPath: { path: /run/promtail }
        - name: pods
          hostPath: { path: /var/log/pods }
        - name: containers
          hostPath: { path: /var/lib/docker/containers }
```

### 3.2 kubernetes-event-exporter — hacer los Events efímeros duraderos y alertables

```yaml
# event-exporter-config.yaml
# https://github.com/resmoio/kubernetes-event-exporter
logLevel: info
logFormat: json
route:
  routes:
    - match:
        - receiver: "loki"          # everything -> Loki for durability + correlation
    - match:
        - type: "Warning"
          receiver: "alert-webhook" # only Warnings -> paging/webhook path
receivers:
  - name: "loki"
    loki:
      streamLabels:
        source: kubernetes-event-exporter
      url: "http://loki.monitoring.svc:3100/loki/api/v1/push"
  - name: "alert-webhook"
    webhook:
      endpoint: "http://alert-router.monitoring.svc/events"
      headers:
        Content-Type: application/json
```

```yaml
# event-exporter-deploy.yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: event-exporter, namespace: monitoring }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: event-exporter }
rules:
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]      # the modern events API group
    resources: ["events"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: event-exporter }
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: event-exporter
subjects:
  - kind: ServiceAccount
    name: event-exporter
    namespace: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: event-exporter, namespace: monitoring }
spec:
  replicas: 1                          # single writer avoids duplicate exports
  selector: { matchLabels: { app: event-exporter } }
  template:
    metadata: { labels: { app: event-exporter } }
    spec:
      serviceAccountName: event-exporter
      containers:
        - name: event-exporter
          image: ghcr.io/resmoio/kubernetes-event-exporter:v1.7
          args: ["-conf=/data/config.yaml"]
          volumeMounts:
            - { name: cfg, mountPath: /data }
      volumes:
        - name: cfg
          configMap: { name: event-exporter-cfg }
```

### 3.3 Logs → métricas con mtail (a nivel de nodo, sin necesidad de backend de logs)

`http_errors.mtail`:

```
# http_errors.mtail — compiled program that emits Prometheus metrics
# https://google.github.io/mtail/Programming-Guide.html
counter http_requests_total by code
counter panic_lines_total

/HTTP\/1\.[01]" (?P<code>\d{3})/ {
  http_requests_total[$code]++
}

/panic:/ {
  panic_lines_total++
}
```

El proceso mtail luego expone `/metrics` en `:3903`, scrapeado por Prometheus exactamente como cualquier exporter — el plano de logs alimenta el plano de métricas sin indexar nunca el texto crudo.

### 3.4 Alertar sobre Events de Kubernetes expuestos como métricas

`kube-state-metrics` expone estado que refleja los events que te importan, p. ej. `kube_pod_container_status_last_terminated_reason`. Una regla de Prometheus convierte "OOMKilled" (un *event*) en una *alerta*:

```yaml
# oom-alert.rules.yaml
groups:
  - name: pod-lifecycle
    rules:
      - alert: PodOOMKilled
        expr: |
          kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "OOMKilled: {{ $labels.namespace }}/{{ $labels.pod }}"
          description: "Container {{ $labels.container }} was OOMKilled. Pivot to logs: {namespace=\"{{ $labels.namespace }}\", pod=\"{{ $labels.pod }}\"}"
```

---

## 4. Comandos CLI y salida real de terminal

### 4.1 Events de Kubernetes — el plano de cambios de estado discretos

```console
$ kubectl get events -n shop --sort-by='.lastTimestamp'
LAST SEEN   TYPE      REASON              OBJECT                       MESSAGE
3m12s       Normal    Scheduled           pod/checkout-7f9c5-abcde     Successfully assigned shop/checkout-7f9c5-abcde to node-3
3m10s       Normal    Pulled              pod/checkout-7f9c5-abcde     Container image "checkout:1.4.2" already present on machine
3m10s       Normal    Created             pod/checkout-7f9c5-abcde     Created container checkout
3m09s       Normal    Started             pod/checkout-7f9c5-abcde     Started container checkout
90s         Warning   Unhealthy           pod/checkout-7f9c5-abcde     Readiness probe failed: HTTP probe failed with statuscode: 503
61s         Warning   OOMKilling          pod/checkout-7f9c5-abcde     Memory cgroup out of memory: Killed process 12841 (checkout)
58s         Warning   BackOff             pod/checkout-7f9c5-abcde     Back-off restarting failed container checkout in pod checkout-7f9c5-abcde
```

El subcomando moderno (`kubectl events`, GA desde 1.26) agrega watch y un filtrado más rico:

```console
$ kubectl events -n shop --for pod/checkout-7f9c5-abcde --types=Warning
LAST SEEN   TYPE      REASON       OBJECT                       MESSAGE
90s         Warning   Unhealthy    Pod/checkout-7f9c5-abcde     Readiness probe failed: statuscode 503
61s         Warning   OOMKilling   Pod/checkout-7f9c5-abcde     Memory cgroup out of memory: Killed process 12841 (checkout)

$ kubectl get event -n shop --field-selector type=Warning,reason=OOMKilling -o json \
    | jq -r '.items[] | "\(.count)x  \(.involvedObject.name)  \(.message)"'
4x  checkout-7f9c5-abcde  Memory cgroup out of memory: Killed process 12841 (checkout)
```

Fijate en `count: 4` — Kubernetes **agrega los events idénticos repetidos** en un solo objeto con un contador y `firstTimestamp`/`lastTimestamp`, razón por la cual un event storm no siempre significa miles de objetos.

La sección Events de `describe` es donde la mayoría de los operadores realmente los lee:

```console
$ kubectl describe pod checkout-7f9c5-abcde -n shop | sed -n '/^Events:/,$p'
Events:
  Type     Reason      Age                From               Message
  ----     ------      ----               ----               -------
  Normal   Scheduled   3m                 default-scheduler  Successfully assigned shop/checkout-7f9c5-abcde to node-3
  Warning  Unhealthy   90s (x3 over 2m)   kubelet            Readiness probe failed: statuscode 503
  Warning  OOMKilling  61s                kubelet            Memory cgroup out of memory: Killed process 12841
  Warning  BackOff     11s (x5 over 58s)  kubelet            Back-off restarting failed container
```

### 4.2 Logs de contenedores

```console
$ kubectl logs checkout-7f9c5-abcde -n shop --previous --tail=5
{"ts":"2026-08-08T14:03:21.980Z","level":"info","msg":"serving on :8080","trace_id":"9af1..."}
{"ts":"2026-08-08T14:03:22.101Z","level":"error","msg":"db pool exhausted","trace_id":"c73e...","code":500}
fatal error: runtime: out of memory
panic: cannot allocate 512 MiB

$ journalctl -u kubelet --since "5 min ago" -o cat | grep -i oom
memory cgroup out of memory: Killed process 12841 (checkout) total-vm:1048576kB
```

`--previous` lee los logs del contenedor **caído** — esencial cuando un pod está en CrashLooping, porque el log del contenedor actual está vacío o corresponde al nuevo intento.

### 4.3 Loki vía LogQL (`logcli`) — la consulta de logs con forma de métrica

```console
$ export LOKI_ADDR=http://loki.monitoring.svc:3100

# Raw filter: last error lines for the checkout pod
$ logcli query '{namespace="shop", app="checkout"} |= "error" | json | level="error"' --limit=3
2026-08-08T14:03:22Z {app="checkout", namespace="shop", pod="checkout-7f9c5-abcde"} db pool exhausted
2026-08-08T14:01:07Z {app="checkout", namespace="shop", pod="checkout-7f9c5-fghij"} db pool exhausted
2026-08-08T13:58:44Z {app="checkout", namespace="shop", pod="checkout-7f9c5-fghij"} timeout waiting for conn

# Metric query: error-line rate per pod — a Prometheus-style vector, from logs
$ logcli query 'sum by (pod) (rate({namespace="shop", app="checkout"} |= "error" [5m]))'
{pod="checkout-7f9c5-abcde"}  0.40
{pod="checkout-7f9c5-fghij"}  0.13
```

Esa segunda consulta es el núcleo de "entender logs y events": **LogQL deliberadamente refleja PromQL** (`rate(...[5m])`, `sum by (...)`) para que un stream de logs pueda reducirse a una métrica bajo demanda, y para que el modelo mental se transfiera directamente.

### 4.4 Confirmar la vista del plano de métricas del mismo incidente

```console
$ curl -s 'http://prometheus:9090/api/v1/query' \
    --data-urlencode 'query=kube_pod_container_status_last_terminated_reason{reason="OOMKilled",namespace="shop"}' \
    | jq -r '.data.result[] | "\(.metric.pod)  \(.value[1])"'
checkout-7f9c5-abcde  1
```

Un incidente, tres planos, un conjunto de labels (`namespace="shop"`, `pod="checkout-7f9c5-abcde"`): Prometheus dijo *que hubo OOMKilled*, el Event dijo *cuándo y qué PID*, el log dijo *por qué (db pool exhausted → OOM)*.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Verificar el pipeline de punta a punta

```console
# 1. Promtail is tailing and pushing (targets should be 'ready', not 'error')
$ kubectl exec -n monitoring ds/promtail -- \
    wget -qO- localhost:9080/metrics | grep -E 'promtail_(sent_bytes_total|dropped)'
promtail_sent_bytes_total{host="node-3"} 4.19e+07
promtail_dropped_bytes_total{reason="line_too_long"} 0

# 2. Loki is ingesting (rate should be non-zero under load)
$ curl -s localhost:3100/metrics | grep loki_distributor_lines_received_total
loki_distributor_lines_received_total{tenant="fake"} 918273

# 3. Labels actually exist (proves relabeling worked)
$ logcli labels
app  container  filename  job  namespace  node  pod  level

# 4. Event exporter is watching (informer synced, no auth errors)
$ kubectl logs -n monitoring deploy/event-exporter | grep -Ei 'started|forbidden'
{"level":"info","msg":"Starting EventWatcher"}
```

### 5.2 Catálogo de fallas

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| Loki OOM / `too many streams` | Un **label** de alta cardinalidad (p. ej. `trace_id` promovido a label) | `logcli series '{}'` muestra un conteo de streams explosivo | Mové el ID al cuerpo del log; quitá el stage `labels` |
| `kubectl get events` vacío durante el post-mortem | El `--event-ttl` los recolectó (~1h) | Los events más viejos que el TTL desaparecieron | Exportar vía kubernetes-event-exporter a Loki/ES |
| Promtail no envía nada | `__path__` / hostPath incorrecto, o formato CRI vs docker | `promtail_targets_active_total == 0`; chequeá `positions.yaml` | Corregí el mount, seteá el pipeline correcto (`cri:` vs `docker:`) |
| La métrica de tasa de logs está plana/en cero en LogQL | Rango de tiempo de la consulta más corto que `[range]`; o filtro de label demasiado estricto | Ampliá el selector, verificá primero con una consulta raw | Corregí los label matchers; chequeá step vs range |
| Event storm, presión sobre etcd | Loop de reconcile de un controller emitiendo Warnings | `kubectl get events --sort-by=.count`, mirá `count` subir | Arreglá el controller; los events ya agregan por identidad |
| Churn de labels en Prometheus / explosión del TSDB | IDs derivados de logs empujados a labels de métrica (mtail/grok) | `topk(10, count by (__name__)({...}))`; chequeá las series activas | Restringí los labels de métrica extraídos a dimensiones acotadas |
| Events exportados duplicados | >1 réplica de event-exporter | Dos escritores hacia el sink | Mantené `replicas: 1` (leader election si se necesita HA) |
| Faltan logs de un pod que está cayendo | Leyendo el contenedor actual, no el previo | `kubectl logs <pod> --previous` | Usá `--previous`; confiá en Loki para la durabilidad |

### 5.3 Auto-chequeo de cardinalidad (el único hábito que previene la mayoría de las caídas)

```console
# Loki: how many streams does a label set produce? (want tens–hundreds, not thousands)
$ logcli series '{namespace="shop"}' | wc -l
214

# Prometheus: which metric drives your active-series count?
$ curl -s 'http://prometheus:9090/api/v1/status/tsdb' \
    | jq '.data.seriesCountByMetricName[0:3]'
[
  {"name":"http_request_duration_seconds_bucket","value":48210},
  {"name":"kube_pod_container_status_last_terminated_reason","value":312}
]
```

Si cualquiera de los dos números crece sin un crecimiento equivalente en entidades reales (pods, services), un valor de alta cardinalidad se ha filtrado en un label — el modo de falla compartido entre los tres planos.

---

## 6. Referencias

- CNCF Curriculum (fuente de verdad de la PCA): https://github.com/cncf/curriculum — `PCA_Curriculum.pdf`
- Prometheus — Overview & data model: https://prometheus.io/docs/introduction/overview/ · https://prometheus.io/docs/concepts/data_model/
- Prometheus — Alerting / Alertmanager: https://prometheus.io/docs/alerting/latest/alertmanager/
- Grafana Loki — Documentation: https://grafana.com/docs/loki/latest/
- LogQL (log & metric queries): https://grafana.com/docs/loki/latest/query/
- Promtail configuration: https://grafana.com/docs/loki/latest/send-data/promtail/configuration/
- Loki configuration reference: https://grafana.com/docs/loki/latest/configure/
- Kubernetes — Events API (`events.k8s.io/v1`): https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- Kubernetes — `kube-apiserver` flags (`--event-ttl`, default `1h0m0s`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — `kubectl events` / logging architecture: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#events · https://kubernetes.io/docs/concepts/cluster-administration/logging/
- kube-state-metrics: https://github.com/kubernetes/kube-state-metrics
- kubernetes-event-exporter (fork mantenido): https://github.com/resmoio/kubernetes-event-exporter
- google/mtail — log-to-metric extraction: https://github.com/google/mtail
- grok_exporter: https://github.com/fstab/grok_exporter
- Fluent Bit / Fluentd: https://docs.fluentbit.io/ · https://docs.fluentd.org/
- OpenTelemetry — Logs specification: https://opentelemetry.io/docs/specs/otel/logs/
- CloudEvents specification (CNCF): https://cloudevents.io/