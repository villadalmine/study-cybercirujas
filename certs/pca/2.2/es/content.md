# PCA 2.2 — Configuración y Scraping

> **Dominio 2 · Fundamentos de Prometheus** — Peso en el examen: 4
> Perfil: profundidad de SRE / Platform Architect de nivel producción. Todos los manifiestos son sintácticamente completos y están validados contra la semántica de Prometheus 2.5x.

---

## 1. Motivación y el problema arquitectónico de producción

Prometheus es un sistema de monitoreo basado en **pull**. Nada empuja métricas hacia él: el servidor es dueño del cronograma, de la lista de targets y de la identidad (labels) de cada serie temporal que almacena. Esa única decisión de diseño es lo que hace de `scrape_configs` la parte operativamente más consecuente de `prometheus.yml` — es simultáneamente el **contrato de service discovery**, la **autoridad del esquema de labels** y el **plano de control de cardinalidad**.

El problema de producción que resuelve:

- **En un datacenter estático**, podrías codificar a mano una lista de endpoints `host:port`. Está bien para 10 nodos.
- **En un cluster de Kubernetes**, los pods son efímeros. Las IPs cambian en cada rollout, la cantidad de réplicas autoescala, y los endpoints de un Deployment se recrean decenas de veces al día. Una lista de targets codificada a mano queda desactualizada en minutos.

Prometheus resuelve esto con **service discovery (SD)** alimentando un **pipeline de relabeling**. SD responde *"¿qué existe ahora mismo?"*; el relabeling responde *"¿cuáles de esos scrapeo, en qué path/puerto/scheme, y bajo qué identidad de label?"*. Equivocarse en la segunda pregunta es la causa raíz de los dos incidentes de Prometheus más costosos:

| Modo de falla | Causa raíz en territorio de 2.2 | Radio de impacto |
|---|---|---|
| **Explosión de cardinalidad** | Un label de los metadatos de SD (ej. `pod_name`, `container_id`) se convierte en label de una serie temporal; cada reinicio de pod acuña una serie nueva | OOM de memoria del TSDB, horas de replay del WAL, timeouts de consultas |
| **Huecos silenciosos de scrape** | El regex del `keep`/`drop` del relabel es demasiado amplio/estrecho; los targets nunca entran al pool de scrape | Puntos ciegos — alertas que nunca pueden dispararse |
| **Churn de targets / inestabilidad de labels** | El label `instance` deriva de una IP efímera en vez de una identidad estable | Cada deploy resetea los contadores; `rate()` produce picos |

**La perspicacia arquitectónica que el examen evalúa:** el conjunto de labels adjunto a una serie se decide *antes* del scrape (vía `relabel_configs`), y las muestras mismas pueden filtrarse/mutarse *después* del scrape (vía `metric_relabel_configs`). Estas son dos etapas distintas del pipeline con entradas diferentes, y confundirlas es el error clásico.

```
┌────────────┐   __meta_* labels    ┌──────────────────┐   target labels   ┌────────┐
│  Service   │ ───────────────────► │  relabel_configs │ ────────────────► │ SCRAPE │
│ Discovery  │  __address__, etc.   │  (target phase)  │  __address__→:port│  HTTP  │
└────────────┘                      └──────────────────┘                   └───┬────┘
                                                                               │ raw samples
                                                                               ▼
                                          stored series ◄───┬───────────────────────────┐
                                                            │  metric_relabel_configs    │
                                                            │  (sample phase, per-metric)│
                                                            └────────────────────────────┘
```

---

## 2. La estructura de nivel superior de `prometheus.yml`

Todo en 2.2 vive dentro de un archivo (más archivos incluidos opcionales). Las claves de nivel superior, en el orden en que importan:

| Clave | Propósito | ¿Recargable? |
|---|---|---|
| `global` | Valores por defecto heredados por cada scrape; `external_labels` estampados en federación/remote-write/alertas | Sí (SIGHUP / `/-/reload`) |
| `runtime` | Porcentaje de GC, tasas de profile de mutex/block | Sí |
| `scrape_configs` | Los scrapes (el corazón de 2.2) | Sí |
| `scrape_config_files` | Glob de archivos con `scrape_configs` adicionales (modularización) | Sí |
| `rule_files` | Globs de reglas de recording/alerting | Sí |
| `alerting` | Discovery de Alertmanager + relabeling | Sí |
| `remote_write` / `remote_read` | Integración de almacenamiento de largo plazo | Parcialmente |
| `storage` | Perillas de TSDB / exemplar / ventana OOO | Algunos campos |
| `tracing` | Tracing OTLP del propio servidor Prometheus | Sí |

### Bloque `global` — los valores por defecto que cascadean

```yaml
global:
  scrape_interval:     15s   # how often to scrape each target (default 1m)
  scrape_timeout:      10s   # must be <= scrape_interval (default 10s)
  evaluation_interval: 15s   # how often rules are evaluated (default 1m)

  # scrape_protocols negotiates the exposition format via Accept header.
  # Order = preference. PrometheusProto enables native histograms + created timestamps.
  scrape_protocols:
    - OpenMetricsText1.0.0
    - OpenMetricsText0.0.1
    - PrometheusText0.0.4

  # external_labels are NOT applied to locally-stored series. They are stamped
  # only on data LEAVING this server: remote_write, federation, and alerts.
  # This is how you disambiguate replicas in HA / global views.
  external_labels:
    cluster: prod-eu-west-1
    replica: prometheus-0

  # Global cardinality guardrails (0 = unlimited). Overridable per job.
  sample_limit: 0
  label_limit: 0
  label_name_length_limit: 0
  label_value_length_limit: 0
  target_limit: 0
  body_size_limit: 0
```

> **Trampa de examen:** los `external_labels` **no** aparecen en las series almacenadas en el TSDB local. Si hacés `sum by (cluster) (...)` localmente no obtenés nada — esos labels solo existen en los datos que salen por el cable.

---

## 3. Anatomía de un `scrape_config`

Un único job, anotado exhaustivamente. Este es el objeto de referencia para todo el tema.

```yaml
scrape_configs:
  - job_name: node          # REQUIRED. Becomes the `job` target label.

    # --- Timing (override global) ---
    scrape_interval: 15s
    scrape_timeout:  10s

    # --- Endpoint shape ---
    metrics_path: /metrics  # default; becomes __metrics_path__
    scheme: http            # http | https; becomes __scheme__
    params:                 # URL query params appended to every scrape
      collect[]: [cpu, meminfo]
    follow_redirects: true
    enable_http2: true

    # --- Label semantics ---
    honor_labels: false       # see §5
    honor_timestamps: true    # respect timestamps in exposition (federation!)
    track_timestamps_staleness: false

    # --- Per-job cardinality limits (override global) ---
    sample_limit: 5000        # drop the WHOLE scrape if it exposes > 5000 samples
    label_limit: 30
    label_name_length_limit: 200
    label_value_length_limit: 200
    target_limit: 100         # cap targets after relabeling

    # --- Authentication (mutually exclusive: basic_auth | authorization | oauth2) ---
    # basic_auth:
    #   username: prometheus
    #   password_file: /etc/prometheus/secrets/node-pw
    # authorization:
    #   type: Bearer
    #   credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    tls_config:
      ca_file:   /etc/prometheus/certs/ca.crt
      cert_file: /etc/prometheus/certs/client.crt
      key_file:  /etc/prometheus/certs/client.key
      insecure_skip_verify: false
      server_name: node-exporter.monitoring.svc

    # --- Service discovery (choose one or more) ---
    static_configs:
      - targets:
          - '10.0.1.10:9100'
          - '10.0.1.11:9100'
        labels:
          rack: a12

    # --- Relabeling (target phase — decides identity & whether to scrape) ---
    relabel_configs:
      - source_labels: [__address__]
        regex: '(.*):.*'
        target_label: instance
        replacement: '$1'

    # --- Metric relabeling (sample phase — filters/mutates ingested series) ---
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'go_gc_duration_seconds.*'
        action: drop
```

### Restricción de timing que debés poder enunciar

`scrape_timeout <= scrape_interval`. Prometheus **se niega a arrancar** si un job la viola. Y la resolución efectiva de las series está acotada por `scrape_interval`: un intervalo de 60s con reglas evaluadas cada 15s significa que tres de cada cuatro evaluaciones ven la misma muestra.

---

## 4. Mecanismos de service discovery — comparativa

SD puebla los labels `__meta_*` *y* el `__address__` obligatorio. El relabeling luego les da forma.

| Mecanismo de SD | Clave de config | Fuente de meta labels | Disparador de recarga | Uso típico |
|---|---|---|---|---|
| Static | `static_configs` | ninguna (solo tus `labels:`) | al recargar config | infra fija, exporters en hosts conocidos |
| File | `file_sd_configs` | `__meta_filepath` | mtime del archivo (auto, sin recarga) | pegamento desde CMDBs / scripts |
| Kubernetes | `kubernetes_sd_configs` | `__meta_kubernetes_*` (rico) | watch de la API (en vivo) | pods, endpoints, nodes, services, ingress |
| Consul | `consul_sd_configs` | `__meta_consul_*` | blocking queries de Consul | service mesh / flotas de VMs |
| DNS | `dns_sd_configs` | `__meta_dns_name` | periódico (`refresh_interval`) | headless services, registros SRV |
| EC2/GCE/Azure | `*_sd_configs` | tags de instancia cloud | polling periódico de la API | flotas de VMs cloud |

### Valores de `role` de Kubernetes SD (material de examen de alta frecuencia)

| `role` | Targets descubiertos | Address por defecto | Emparejamiento común |
|---|---|---|---|
| `node` | Cada nodo del cluster (Kubelet) | `InternalIP:10250` del nodo | cAdvisor, métricas de nodo |
| `pod` | Cada pod + puerto de contenedor declarado | IP del pod + puerto | anotaciones `prometheus.io/scrape` |
| `endpoints` | Direcciones detrás de un Service | IP del endpoint + puerto | servicios de app con un Service |
| `endpointslice` | Lo mismo vía la API EndpointSlice | IP del endpoint + puerto | reemplazo escalable de endpoints |
| `service` | ClusterIP del Service (blackbox probing) | DNS del service + puerto | probing de disponibilidad |
| `ingress` | Paths del Ingress | host/path del ingress | blackbox probing de rutas |

### Job completo de descubrimiento de pods de Kubernetes (el patrón canónico de anotaciones)

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # 1) Scrape only pods that opted in via annotation prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

      # 2) Override the metrics path if prometheus.io/path is set
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # 3) Rewrite __address__ to use the annotated port (IP:port assembly)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: '([^:]+)(?::\d+)?;(\d+)'
        replacement: '$1:$2'
        target_label: __address__

      # 4) Promote all pod labels into series labels (label_XXX)
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)

      # 5) Stable identity labels — NOT the ephemeral pod IP
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod

      # 6) Drop pods that are not Running (avoids scraping Pending/Terminating)
      - source_labels: [__meta_kubernetes_pod_phase]
        regex: (Failed|Succeeded)
        action: drop
```

---

## 5. Relabeling — el pipeline que decide todo

El relabeling es un pequeño motor de transformación aplicado a un conjunto de labels. Dos puntos de invocación:

- **`relabel_configs`** — corre sobre los conjuntos de labels del **target** (la bolsa de `__meta_*` + `__address__`). Su salida determina la identidad del target y si se scrapea en absoluto. Los labels que empiezan con `__` se **descartan después de esta fase** (salvo que dirijan el scrape).
- **`metric_relabel_configs`** — corre sobre el conjunto de labels de **cada muestra ingerida**, *después* del scrape. `__name__` está disponible (el nombre de la métrica). No puede traer de vuelta un target descartado; solo filtra/edita las series almacenadas.

### Los campos de la regla

| Campo | Por defecto | Significado |
|---|---|---|
| `source_labels` | `[]` | Labels concatenados (con `separator`) para formar el input de coincidencia |
| `separator` | `;` | Une múltiples source labels |
| `regex` | `(.*)` | Regex RE2, **totalmente anclado** (`^...$` implícito) |
| `target_label` | — | Label de destino para `replace`/`hashmod` |
| `replacement` | `$1` | Valor escrito; soporta capturas `$1`,`$2` o `${name}` |
| `modulus` | — | Para `hashmod` |
| `action` | `replace` | Ver tabla debajo |

### Acciones

| Acción | Efecto |
|---|---|
| `replace` | Si `regex` coincide con los `source_labels` unidos, escribe `replacement` (con capturas) en `target_label`. Sin coincidencia ⇒ la regla es un no-op. |
| `keep` | Mantiene el target/serie solo si `regex` coincide; de lo contrario lo descarta |
| `drop` | Descarta el target/serie si `regex` coincide |
| `keepequal` | Mantiene si el valor de `target_label` es igual a los source labels unidos |
| `dropequal` | Descarta si el valor de `target_label` es igual a los source labels unidos |
| `hashmod` | `target_label = hash(source_labels) % modulus` — usado para **sharding horizontal** |
| `labelmap` | Copia los labels cuyo *nombre* coincide con `regex` a nombres nuevos vía `replacement` |
| `labeldrop` | Elimina los labels cuyo nombre coincide con `regex` |
| `labelkeep` | Elimina todos los labels cuyo nombre **no** coincide con `regex` |
| `lowercase` / `uppercase` | Cambia el caso de los source labels unidos hacia `target_label` |

### Patrón de sharding (`hashmod`) — escalado horizontal de una única carga de scrape

Corré N réplicas de Prometheus, cada una scrapeando ~1/N de los targets:

```yaml
    relabel_configs:
      - source_labels: [__address__]
        modulus: 4                 # total shards
        target_label: __tmp_shard
        action: hashmod
      - source_labels: [__tmp_shard]
        regex: ^1$                 # this replica is shard 1 (0..3)
        action: keep
```

### Meta labels: namespace reservado y ciclo de vida

- `__address__` — **obligatorio**; el `host:port` que se scrapea.
- `__scheme__`, `__metrics_path__`, `__param_<name>` — configuran la solicitud HTTP.
- `__meta_*` — metadatos provistos por SD (entradas de solo lectura).
- `__tmp_*` — convención para labels de borrador que creás y descartás.
- Después de `relabel_configs`, cada label con prefijo `__` se elimina; solo los labels "reales" sobreviven como la identidad del target. Si `instance` nunca se configuró, Prometheus lo establece por defecto a `__address__`.

---

## 6. Tablas de trade-offs que el examen premia

### `relabel_configs` vs `metric_relabel_configs`

| Dimensión | `relabel_configs` (target) | `metric_relabel_configs` (sample) |
|---|---|---|
| Corre | Antes del scrape | Después del scrape, antes del almacenamiento |
| Input | Conjunto de labels del target (`__meta_*`, `__address__`) | Labels por muestra incl. `__name__` |
| ¿Puede detener un scrape? | Sí (`keep`/`drop` sobre el target) | No — el scrape ya ocurrió |
| ¿Ahorra ancho de banda de scrape? | Sí (nunca se contacta al target) | No (los datos se traen y luego se descartan) |
| ¿Reduce la cardinalidad almacenada? | Sí (menos targets) | Sí (menos series/editadas) |
| Uso típico | Elegir targets, fijar `instance`/`job`, reescribir puerto/path | Descartar métricas ruidosas, quitar labels de alta cardinalidad |

### Comportamiento de `honor_labels`

| `honor_labels` | Resolución de conflicto cuando el target expone un label que Prometheus también fija (ej. `job`, `instance`) |
|---|---|
| `false` (por defecto) | Gana el valor de Prometheus; el label conflictivo expuesto se renombra a `exported_<label>` |
| `true` | Gana el valor expuesto del **target**; Prometheus no lo sobrescribe |

> Usá `honor_labels: true` para scrapes de **federación** y **Pushgateway**, donde el `job`/`instance` expuesto son las identidades reales que debés preservar.

### Elección de SD para cargas de Kubernetes

| Necesidad | Role recomendado | Por qué |
|---|---|---|
| Métricas de app por réplica | `pod` | Un target por pod; sobrevive al churn del Service |
| Métricas detrás de un Service, dedup por endpoint | `endpointslice` | Escala mejor que `endpoints` con altos conteos de endpoints |
| Kubelet / cAdvisor | `node` | Targets `:10250` a nivel de nodo |
| Disponibilidad black-box de una ruta | `ingress` / `service` | Probe desde afuera vía blackbox_exporter |

---

## 7. `prometheus.yml` completo de nivel producción

Un archivo completo que combina exporters estáticos, Kubernetes SD, federación, remote-write y alerting — ejecutable por copy-paste.

```yaml
global:
  scrape_interval:     15s
  scrape_timeout:      10s
  evaluation_interval: 30s
  scrape_protocols:
    - OpenMetricsText1.0.0
    - PrometheusText0.0.4
  external_labels:
    cluster: prod-eu-west-1
    replica: $(POD_NAME)      # substituted at render time by your templating

runtime:
  gogc: 50

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_config_files:
  - /etc/prometheus/scrape.d/*.yml

alerting:
  alertmanagers:
    - kubernetes_sd_configs:
        - role: endpoints
      relabel_configs:
        - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
          regex: monitoring;alertmanager;web
          action: keep

remote_write:
  - url: https://thanos-receive.monitoring.svc:19291/api/v1/receive
    name: thanos
    remote_timeout: 30s
    queue_config:
      capacity: 10000
      max_shards: 50
      min_shards: 1
      max_samples_per_send: 2000
      batch_send_deadline: 5s
    write_relabel_configs:
      # Never ship debug/temp series to long-term storage
      - source_labels: [__name__]
        regex: '(go_|process_|prometheus_tsdb_).*'
        action: drop
    tls_config:
      ca_file: /etc/prometheus/certs/ca.crt

scrape_configs:
  # --- 1) Prometheus scraping itself ---
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  # --- 2) Node exporters via static list ---
  - job_name: node
    static_configs:
      - targets: ['10.0.1.10:9100', '10.0.1.11:9100']
        labels:
          role: worker
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+):.*'
        target_label: instance
        replacement: '$1'

  # --- 3) Kubernetes pods (opt-in annotations) ---
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_ip]
        regex: '(\d+);(.+)'
        replacement: '$2:$1'
        target_label: __address__
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
    metric_relabel_configs:
      # Cardinality guard: drop the histogram bucket series of a chatty client lib
      - source_labels: [__name__]
        regex: 'rpc_client_.*_bucket'
        action: drop

  # --- 4) Federation from a lower-tier Prometheus (honor_labels!) ---
  - job_name: federate
    honor_labels: true
    metrics_path: /federate
    params:
      'match[]':
        - '{job="node"}'
        - '{__name__=~"job:.*"}'
    static_configs:
      - targets: ['prometheus-team-a.monitoring.svc:9090']

  # --- 5) Blackbox probing of external URLs via blackbox_exporter ---
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://example.com
          - https://api.internal.svc/healthz
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter.monitoring.svc:9115
```

> **Patrón de blackbox para memorizar:** la *URL a probar* se pasa como `__param_target`, `instance` se fija a partir de ella, y `__address__` se reescribe hacia el **exporter** — Prometheus scrapea el exporter, que prueba el target real en su nombre.

---

## 8. CLI, validación y recarga

### Validá antes de enviar — `promtool`

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 1 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/rules/node.yml
 SUCCESS: 12 rules found
```

Una restricción de timeout mal formada falla ruidosamente:

```console
$ promtool check config prometheus.yml
Checking prometheus.yml
  FAILED: parsing YAML file prometheus.yml: scrape timeout greater than scrape interval for scrape config with job name "node"
```

### Dry-run de la lógica de relabeling offline

```console
$ promtool check config --lint-fatal prometheus.yml
$ promtool test rules tests/node_rules_test.yml
Unit Testing:  tests/node_rules_test.yml
  SUCCESS
```

### Hot-reload sin reinicio — dos caminos soportados

Prometheus debe iniciarse con `--web.enable-lifecycle` para el camino HTTP:

```console
$ curl -sX POST http://localhost:9090/-/reload
$ echo $?
0
```

O vía señal (siempre disponible, sin necesidad de flag):

```console
$ pkill -HUP prometheus
# or, when you know the PID:
$ kill -HUP "$(pgrep -x prometheus)"
```

Confirmá que la recarga tuvo éxito en los logs:

```console
$ journalctl -u prometheus --since "1 min ago" | grep -i reload
level=info ts=2026-08-08T10:14:22.881Z caller=main.go:1231 msg="Loading configuration file" filename=/etc/prometheus/prometheus.yml
level=info ts=2026-08-08T10:14:22.905Z caller=main.go:1268 msg="Completed loading of configuration file" filename=/etc/prometheus/prometheus.yml totalDuration=24.1ms
```

Una recarga fallida mantiene corriendo la config **anterior** (a prueba de fallos):

```console
$ curl -sX POST http://localhost:9090/-/reload
failed to reload config: couldn't load configuration (--config.file="/etc/prometheus/prometheus.yml"): parsing YAML file ...: unknown field "scrape_intervall"
```

### Inspeccioná lo que Prometheus realmente cargó

La config en ejecución se sirve de vuelta (secretos redactados como `<secret>`):

```console
$ curl -s http://localhost:9090/api/v1/status/config | jq -r '.data.yaml' | head -20
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 30s
  ...
```

---

## 9. Verificación y diagnóstico de fallas

### Paso 1 — ¿Están los targets descubiertos y UP?

La API de active-targets es tu verdad de base. Muestra los labels **posteriores al relabeling**, los labels pre-relabel descubiertos, la salud y el último error.

```console
$ curl -s http://localhost:9090/api/v1/targets | \
    jq -r '.data.activeTargets[] | [.labels.job, .scrapeUrl, .health, .lastError] | @tsv'
node       http://10.0.1.10:9100/metrics        up
node       http://10.0.1.11:9100/metrics        down   connection refused
kubernetes-pods  http://10.244.2.7:8080/metrics up
```

### Paso 2 — ¿Por qué un target fue descartado? (debugging de relabel)

Los targets descartados son invisibles en la UI. Consultá los targets **dropped** explícitamente:

```console
$ curl -s 'http://localhost:9090/api/v1/targets?state=dropped' | \
    jq -r '.data.droppedTargets[].discoveredLabels.__address__' | head
10.244.3.9:9090
10.244.1.4:53
```

Si falta un pod que esperabas, los culpables habituales:

| Síntoma | Causa probable | Arreglo |
|---|---|---|
| Target en `droppedTargets`, no en `activeTargets` | Un regex de `keep` no coincidió (ej. anotación faltante/mal escrita) | Verificá `prometheus.io/scrape: "true"` en el pod, revisá el anclaje del regex |
| `activeTargets` muestra `__address__` con puerto equivocado | Regex de ensamblaje de puerto en el relabel incorrecto | Inspeccioná `discoveredLabels` en la entrada dropped/active |
| `job`/`instance` inesperados | Sobrescritos por una regla `replace` o por `honor_labels` | Rastreá el orden de las reglas — el relabel es secuencial |

### Paso 3 — Salud del scrape desde las meta-métricas incorporadas

Cada scrape produce muestras sintéticas en la propia línea temporal del target:

| Métrica | Significado | Alertar sobre |
|---|---|---|
| `up` | 1 si el scrape tuvo éxito, 0 de lo contrario | `up == 0` durante N minutos |
| `scrape_duration_seconds` | Cuánto tardó el scrape | acercándose a `scrape_timeout` |
| `scrape_samples_scraped` | Muestras expuestas por el target | crecimiento súbito = riesgo de cardinalidad |
| `scrape_samples_post_metric_relabeling` | Muestras conservadas tras `metric_relabel_configs` | brecha vs. scraped = tus reglas de drop |
| `scrape_series_added` | Series nuevas en este scrape | churn alto = labels inestables |

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=up==0' | \
    jq -r '.data.result[] | [.metric.job, .metric.instance] | @tsv'
node   10.0.1.11:9100
```

### Paso 4 — Diagnosticá el disparo de `sample_limit` / cardinalidad

Cuando un target excede `sample_limit`, el **scrape entero es rechazado** y `up` va a 0 con un error revelador:

```console
$ curl -s http://localhost:9090/api/v1/targets | \
    jq -r '.data.activeTargets[] | select(.health=="down") | .lastError'
sample limit exceeded (5000)
```

Encontrá a los infractores antes de que le hagan OOM al servidor:

```promql
# Top targets by samples exposed
topk(10, scrape_samples_scraped)

# Series churn — unstable labels create new series every scrape
topk(10, scrape_series_added)
```

Diagnosticá *qué métrica* está explotando la cardinalidad:

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | \
    jq -r '.data.seriesCountByMetricName[] | [.value, .name] | @tsv' | head
483210  rpc_client_duration_seconds_bucket
120044  http_request_duration_seconds_bucket
 51002  container_network_receive_bytes_total
```

→ Agregá un `drop`/`labeldrop` de `metric_relabel_configs` para la entrada superior, recargá y volvé a chequear.

### Paso 5 — Confirmá que un drop de metric_relabel realmente surtió efecto

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=count({__name__=~"rpc_client_.*_bucket"})'
{"status":"success","data":{"resultType":"vector","result":[]}}
```

Resultado vacío ⇒ la regla de drop está activa. Compará `scrape_samples_scraped` vs `scrape_samples_post_metric_relabeling` para cuantificar lo que ahorraste:

```promql
scrape_samples_scraped - scrape_samples_post_metric_relabeling
```

### Paso 6 — Cordura de staleness

Si un target desaparece del SD, Prometheus inyecta un **marcador de staleness** y la serie deja de devolver valores ~5 minutos después (delta de lookback por defecto). Un target que *sigue* devolviendo valores obsoletos usualmente significa que todavía está descubierto pero devolviendo datos cacheados — revisá `honor_timestamps` y los timestamps del exporter.

---

## 10. Referencias

- Prometheus — Configuration reference: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — `<scrape_config>` and `<relabel_config>`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
- Prometheus — Kubernetes SD (`kubernetes_sd_config`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config
- Prometheus — Getting started / configuring scrape targets: https://prometheus.io/docs/prometheus/latest/getting_started/
- Prometheus — Federation: https://prometheus.io/docs/prometheus/latest/federation/
- Prometheus — Management API (`/-/reload`, lifecycle): https://prometheus.io/docs/prometheus/latest/management_api/
- Prometheus — Querying HTTP API (`/api/v1/targets`, `/status/tsdb`, `/status/config`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — `promtool` (bundled with the server): https://github.com/prometheus/prometheus/tree/main/cmd/promtool
- OpenMetrics specification: https://github.com/prometheus/OpenMetrics/blob/main/specification/OpenMetrics.md
- Relabeling best practices (Robust Perception, referenced by Prometheus docs): https://www.robustperception.io/life-of-a-label/
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf