# PCA · Dominio 3.2 — Comprender Logs y Events

Ejercicios guiados y prácticos. Cada bloque es una secuencia de comandos que ejecutás vos; después de cada bloque, respondé las preguntas de comprensión antes de continuar. La solución completa está en la sección desplegable al final.

**Requisitos previos:** Docker Engine, `curl`, `jq`, y un cluster de Kubernetes descartable (`kind create cluster` o `minikube start`) para los Ejercicios 2 y 4b. Todo corre localmente; desmontá todo al final.

> **Modelo mental para este dominio.** Prometheus mismo almacena exactamente una señal: **metrics** (muestras numéricas a lo largo del tiempo). "Comprender logs y events" trata sobre las *otras dos señales discretas* — qué son, en qué se diferencian de las metrics, y cómo el ecosistema de Prometheus (Loki, LogQL, kube-state-metrics, exporters, exemplars) las conecta. El examen evalúa las *distinciones y los trade-offs*, no solo la sintaxis de las herramientas. Seguí preguntándote: ¿qué representa un "registro" (record), y cuál es su costo de cardinalidad?

---

## Ejercicio 1 — El mismo proceso, dos señales: metrics vs. logs

Un proceso en ejecución emite ambas de forma continua. Verlas una al lado de la otra es la forma más rápida de internalizar la diferencia.

**Bloque A — Iniciá una carga de trabajo que emite ambas señales**

```bash
# 1. Prometheus itself is a perfect specimen: it exposes /metrics AND logs to stdout.
docker run -d --name prom -p 9090:9090 prom/prometheus:v2.53.0

# 2. Read the LOGS (discrete, timestamped events).
docker logs prom
```

Salida esperada (logfmt, un evento por línea):

```
ts=2024-06-20T10:00:00.123Z caller=main.go:627 level=info msg="Starting Prometheus Server" mode=server version="(version=2.53.0, branch=HEAD, revision=a2c6d15)"
ts=2024-06-20T10:00:00.124Z caller=main.go:632 level=info build_context="(go=go1.22.4, platform=linux/amd64)"
ts=2024-06-20T10:00:00.130Z caller=web.go:565 level=info component=web msg="Start listening for connections" address=0.0.0.0:9090
ts=2024-06-20T10:00:00.150Z caller=head.go:626 level=info component=tsdb msg="Replaying on-disk memory mappable chunks if any"
ts=2024-06-20T10:00:00.161Z caller=main.go:1148 level=info msg="Server is ready to receive web and API requests."
```

**Bloque B — Leé las metrics del mismo proceso**

```bash
# 3. Read the METRICS (aggregated numeric samples).
curl -s localhost:9090/metrics | grep -E '^prometheus_tsdb_head_series '
```

Salida esperada:

```
prometheus_tsdb_head_series 1247
```

```bash
# 4. Scrape twice, ten seconds apart, and watch the value evolve.
curl -s localhost:9090/metrics | grep -E '^prometheus_http_requests_total.*handler="/metrics"'
sleep 10
curl -s localhost:9090/metrics | grep -E '^prometheus_http_requests_total.*handler="/metrics"'
```

Salida esperada (un counter que solo se incrementa):

```
prometheus_http_requests_total{code="200",handler="/metrics"} 4
prometheus_http_requests_total{code="200",handler="/metrics"} 5
```

> **Preguntas**
> - **Q1.1** — Tanto `docker logs prom` como `/metrics` describen el *mismo* proceso. Clasificá cada uno como un tipo de señal y explicá la diferencia fundamental en lo que representa un único "registro" (una línea de log vs. una muestra de metric).
> - **Q1.2** — Las líneas de log usan `ts=… caller=… level=info msg="…"`. ¿Cómo se llama este formato de línea, y por qué emitir logs de esta manera (en lugar de prosa libre) importa en el momento en que empezás a *agregar* logs de muchas instancias?
> - **Q1.3** — No podés calcular "el p95 del recuento de head-series durante la última hora" a partir de `docker logs`, y no podés recuperar "la cadena `revision` exacta con la que arrancó Prometheus" a partir de `/metrics`. Explicá ambas carencias, y enunciá la regla general de *cuándo* recurrís a metrics frente a logs.

---

## Ejercicio 2 — Kubernetes Events como señal discreta de primera clase

Los Events no son ni metrics ni logs de contenedor. Son registros estructurados de *cambios de estado* que el control plane quiere que notes. Esta es la parte que los estudiantes más a menudo confunden con "logs".

**Bloque A — Provocá una falla y observá los Events**

```bash
# 1. Create a Pod that cannot possibly start (image does not exist).
kubectl run broken --image=nginx:doesnotexist

# 2. List Events in time order.
kubectl get events --sort-by='.lastTimestamp'
```

Salida esperada:

```
LAST SEEN   TYPE      REASON      OBJECT       MESSAGE
25s         Normal    Scheduled   pod/broken   Successfully assigned default/broken to kind-control-plane
23s         Normal    Pulling     pod/broken   Pulling image "nginx:doesnotexist"
22s         Warning   Failed      pod/broken   Failed to pull image "nginx:doesnotexist": ... not found
22s         Warning   Failed      pod/broken   Error: ErrImagePull
8s          Warning   BackOff     pod/broken   Back-off pulling image "nginx:doesnotexist"
8s          Warning   Failed      pod/broken   Error: ImagePullBackOff
```

**Bloque B — Inspeccioná la estructura de un solo Event**

```bash
# 3. The same Events appear in `describe`, attached to the object.
kubectl describe pod broken | sed -n '/Events:/,$p'

# 4. Dump one Event as JSON to see its real fields.
kubectl get events -o json \
  | jq '.items[] | select(.reason=="Failed") | {reason, message, type, count, firstTimestamp, lastTimestamp, involvedObject: .involvedObject.name, source: .source.component}' \
  | head -20
```

Salida esperada:

```json
{
  "reason": "Failed",
  "message": "Failed to pull image \"nginx:doesnotexist\": ... not found",
  "type": "Warning",
  "count": 4,
  "firstTimestamp": "2024-06-20T10:05:10Z",
  "lastTimestamp": "2024-06-20T10:06:02Z",
  "involvedObject": "broken",
  "source": "kubelet"
}
```

```bash
# 5. Clean up.
kubectl delete pod broken
```

> **Preguntas**
> - **Q2.1** — En una oración cada uno, distinguí una **línea de log de contenedor** (`kubectl logs`) de un **Kubernetes Event** (`kubectl get events`). ¿Qué produce cada uno, y qué describe cada uno?
> - **Q2.2** — El Event `Failed` muestra `count: 4` con `firstTimestamp` y `lastTimestamp` distintos. ¿Qué está haciendo Kubernetes acá, y qué perderías si en cambio emitiera cuatro registros separados?
> - **Q2.3** — ¿Qué significa el campo `type` (`Normal` / `Warning`), y dado que la retención de events por defecto del API server es de ~1 hora (`--event-ttl`), por qué los Events *no* son un registro de auditoría confiable? ¿Qué desplegás para conservarlos?

---

## Ejercicio 3 — Agregar logs con Loki + Promtail, consultar con LogQL

Loki es el almacén de logs construido para ubicarse junto a Prometheus: **el mismo modelo de datos basado en labels, un lenguaje de consulta con forma de PromQL (LogQL).** Entender este paralelismo es central para el tema.

**Bloque A — Levantá un pipeline de logs**

Creá `promtail.yaml`:

```yaml
server:
  http_listen_port: 9080
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://loki:3100/loki/api/v1/push
scrape_configs:
  - job_name: flog
    static_configs:
      - targets: [localhost]
        labels:
          job: flog
          __path__: /logs/*.log
```

Creá `docker-compose.yaml`:

```yaml
services:
  loki:
    image: grafana/loki:3.0.0
    ports: ["3100:3100"]
    command: -config.file=/etc/loki/local-config.yaml

  flog:
    image: mingrammer/flog:0.4.3
    command: ["-f", "apache_combined", "-o", "/logs/access.log", "-t", "log", "-l", "-d", "200ms"]
    volumes:
      - logs:/logs

  promtail:
    image: grafana/promtail:3.0.0
    depends_on: [loki]
    volumes:
      - logs:/logs
      - ./promtail.yaml:/etc/promtail/config.yaml
    command: -config.file=/etc/promtail/config.yaml

volumes:
  logs:
```

```bash
# 1. Start the stack (Loki, a fake Apache-log generator, and Promtail shipping to Loki).
docker compose up -d

# 2. Give it ~15s, then confirm Loki knows the stream labels.
sleep 15
curl -sG http://localhost:3100/loki/api/v1/labels | jq
```

Salida esperada:

```json
{ "status": "success", "data": ["filename", "job", "service_name"] }
```

**Bloque B — Consultá logs y luego derivá una metric a partir de ellos**

```bash
# 3. A LOG query: return raw lines for a stream selected by labels.
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="flog"}' \
  --data-urlencode 'limit=2' | jq -r '.data.result[0].values[][1]'
```

Salida esperada (líneas Apache-combined en crudo):

```
102.34.11.9 - - [20/Jun/2024:10:10:01 +0000] "GET /wp-admin HTTP/1.1" 200 4881 "-" "Mozilla/5.0..."
88.4.201.3 - - [20/Jun/2024:10:10:01 +0000] "POST /list HTTP/1.1" 503 1198 "-" "curl/8.0"
```

```bash
# 4. A METRIC query over logs: count GET lines per minute across the stream.
curl -sG "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum(count_over_time({job="flog"} |= "GET" [1m]))' \
  | jq '.data.result[0].value[1]'
```

Salida esperada:

```
"143"
```

```bash
# 5. Tear down.
docker compose down -v
```

> **Preguntas**
> - **Q3.1** — En el selector `{job="flog"}`, ¿qué identifica exactamente `job="flog"` dentro de Loki, y cómo se corresponde eso con el propio modelo de datos de Prometheus? Definí un **stream** de Loki.
> - **Q3.2** — Supongamos que reconfigurás Promtail para extraer la ruta de solicitud completa y adjuntarla como una stream label (`path="/wp-admin"`, `path="/list?id=abc123"`, …). Explicá con precisión por qué esto es peligroso en Loki, usando el mismo razonamiento que aplicarías a una label de Prometheus.
> - **Q3.3** — La consulta del paso 4 devolvió un único número, `"143"`, a partir de un stream de *log*. ¿Qué clase de consulta LogQL es `sum(count_over_time(... [1m]))`, y qué demuestra su existencia sobre el límite entre logs y metrics?

---

## Ejercicio 4 — De logs y events a metrics, y la trampa de la cardinalidad

La última idea de este dominio: podés *derivar* metrics a partir de logs y events, pero solo colapsando el detalle de alta cardinalidad en labels acotadas.

**Bloque A — Razoná sobre derivar una metric a partir de un stream de log**

```bash
# 1. (Conceptual, using the Ex.3 pattern.) A LogQL metric query that keeps a BOUNDED label —
#    the HTTP status class — while discarding the unbounded request line:
#      sum by (status) (
#        count_over_time({job="flog"} | pattern `<_> - - <_> "<_>" <status> <_>` [1m])
#      )
#    Contrast with an attempt to keep the FULL request line as a label — which would create
#    one series per unique URL+query-string.
echo "status is bounded (~5 classes); request line is effectively unbounded"
```

**Bloque B — Events → metrics vía kube-state-metrics**

```bash
# 2. Recreate the failing Pod from Exercise 2.
kubectl run broken --image=nginx:doesnotexist

# 3. Deploy kube-state-metrics (KSM turns object *state* into Prometheus metrics).
kubectl apply -k github.com/kubernetes/kube-state-metrics//examples/standard
kubectl -n kube-system rollout status deploy/kube-state-metrics

# 4. Port-forward and read the state metric that mirrors the ImagePullBackOff condition.
kubectl -n kube-system port-forward svc/kube-state-metrics 8080:8080 >/dev/null 2>&1 &
sleep 3
curl -s localhost:8080/metrics | grep 'kube_pod_container_status_waiting_reason.*broken'
```

Salida esperada:

```
kube_pod_container_status_waiting_reason{namespace="default",pod="broken",container="broken",reason="ImagePullBackOff"} 1
```

```bash
# 5. Clean up.
kubectl delete pod broken
kubectl delete -k github.com/kubernetes/kube-state-metrics//examples/standard
```

> **Preguntas**
> - **Q4.1** — Nombrá dos herramientas que convierten *líneas de log no estructuradas* en metrics de Prometheus, y describí cómo se ve una serie temporal resultante (nombre de la metric + un conjunto de labels plausible + tipo de valor).
> - **Q4.2** — Querés paginar al on-call cuando un Pod queda atascado en `ImagePullBackOff`. Tus tres señales candidatas son: el **Event** de Kubernetes (`reason=Failed`), una **línea de log** del kubelet, o la **metric** `kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"}`. ¿Sobre cuál construís la alerta, y por qué las otras dos son malas opciones *para alertar*?
> - **Q4.3** — Describí el flujo de trabajo estándar de "drill-down" de tres señales que un operador sigue durante un incidente, y explicá dónde encajan los **exemplars** de Prometheus para coser las señales entre sí.

---

<details>
<summary><strong>Solución</strong> (desplegá solo después de intentar todas las preguntas)</summary>

### Ejercicio 1

**Q1.1** — `docker logs` es la señal de **logs**; `/metrics` es la señal de **metrics**.
- Un **registro** de log es un *evento discreto*: una cosa que ocurrió en un instante, que lleva un contexto rico, mayormente textual y no acotado ("Server is ready…", con la cadena de versión completa). Es de solo anexado (append-only) y un evento por línea.
- Un **registro** de metric es una *muestra*: un único valor numérico de una serie temporal nombrada y con labels en un timestamp de scrape (`prometheus_tsdb_head_series 1247`). Es un agregado/resumen de estado, deliberadamente de baja cardinalidad, y solo tiene sentido como parte de una serie a lo largo del tiempo.
La diferencia central: una línea de log responde *"¿qué pasó específicamente acá?"*; una muestra de metric responde *"¿cuánto / cuántos, ahora mismo, como un número sobre el que puedo hacer cálculos a lo largo del tiempo y entre instancias?"*

**Q1.2** — Es **logfmt** (logging estructurado `key=value`; JSON es el otro formato estructurado común). La estructura importa para la agregación porque un pipeline de logs (Promtail, Fluent Bit, Loki) puede **parsear campos de forma confiable** — filtrar por `level=error`, agrupar por `component`, extraer `caller` — en lugar de escribir regexes frágiles contra prosa libre. Una vez que enviás logs desde docenas de réplicas a un único almacén, los campos consistentes y parseables por máquina son lo que hace que la consulta, la extracción de labels y la conversión de log a metric sean siquiera posibles.

**Q1.3** — No podés calcular un p95 sobre una hora a partir de `docker logs` porque los logs son eventos discretos, no una serie numérica continua — no hay una serie temporal `head_series` preagregada sobre la cual correr un cuantil (tendrías que inventar metrics a partir del texto). No podés recuperar la cadena `revision` exacta a partir de `/metrics` porque las metrics descartan deliberadamente el detalle textual de alta cardinalidad y de única ocurrencia — esa cadena de build sería una label inútil y no acotada. **Regla:** usá **metrics** para números agregables, de cardinalidad acotada, sobre los que alertás y hacés tendencias ("¿está sano / cuánto?"); usá **logs** para el contexto específico y de alto detalle que necesitás para explicar *por qué* ocurrió un evento en particular.

### Ejercicio 2

**Q2.1** — Una **línea de log de contenedor** es producida por el *proceso de la aplicación* escribiendo a stdout/stderr; describe lo que sea que la app decidió decir. Un **Kubernetes Event** es producido por un *componente del control plane* (kubelet, scheduler, controllers) vía el API server; describe una *transición de estado o decisión sobre un objeto* (scheduled, pulling, failed, backing off). Uno es texto escrito por la app; el otro es escrito por el cluster, estructurado, y adjuntado a un `involvedObject` específico.

**Q2.2** — Kubernetes está **deduplicando ocurrencias idénticas repetidas en un único Event con un `count` y una ventana `first/lastTimestamp`** (agregación/fusión). Emitir cuatro registros separados inundaría etcd y el stream de Events con entradas casi idénticas; la forma count+ventana preserva *con qué frecuencia* y *durante qué lapso* mientras lo mantiene como un solo objeto. (En la API más nueva `events.k8s.io/v1` esto se modela explícitamente como una `series` con `count` + `lastObservedTime`.)

**Q2.3** — `type` clasifica el Event como rutinario (`Normal`) o algo que exige atención (`Warning`) — una severidad gruesa. Los Events **no** son un registro de auditoría porque se almacenan en etcd con un TTL corto (`--event-ttl`, ~1h por defecto) y son recolectados como basura (garbage-collected); cualquier cosa más antigua simplemente desaparece. Para conservarlos desplegás un **event exporter** (por ejemplo, `kubernetes-event-exporter`) que envía los Events hacia un destino durable (un almacén de logs como Loki/Elasticsearch, o un pipeline de metrics/alertas) antes de que expiren.

### Ejercicio 3

**Q3.1** — `job="flog"` es un **selector de labels**; Loki identifica datos de log por *conjuntos de labels*, exactamente como Prometheus identifica metrics por conjuntos de labels. Un **stream** es la unidad de almacenamiento en Loki: el conjunto de todas las líneas de log que comparten una combinación única de labels (por ejemplo, `{job="flog", filename="/logs/access.log"}`). Es el análogo, en el mundo de los logs, de una única serie temporal de Prometheus — el mismo modelo de "combinación única de labels = una entidad direccionable".

**Q3.2** — Cada combinación distinta de label-valor crea un **nuevo stream**, igual que cada combinación distinta de labels crea una nueva serie temporal de Prometheus. Las rutas de solicitud (especialmente con query strings o IDs) son efectivamente **no acotadas**, así que hacer de `path` una label produce una cantidad casi infinita de streams diminutos — "explosión de streams/cardinalidad". Esto revienta el índice de Loki, arruina el rendimiento de ingesta y de consulta, y puede causar OOM en los ingesters. Los datos de alta cardinalidad pertenecen *dentro de la línea de log* (consultados en tiempo de lectura con un filtro/parser de LogQL), **nunca** en una stream label — la disciplina idéntica que aplicás a las labels de Prometheus.

**Q3.3** — Es una **consulta de metric de LogQL** (una agregación de rango, `count_over_time`, envuelta en `sum`). Su existencia muestra que el límite log↔metric es *cruzable en tiempo de consulta*: podés calcular un resultado numérico con forma de PromQL *a partir de logs en crudo sobre la marcha*, sin haber precreado jamás esa metric. El trade-off es el costo — escanea líneas de log por consulta en lugar de leer una serie preagregada y barata — así que complementa, en lugar de reemplazar, un counter real de Prometheus para cualquier cosa que consultes o alertes con frecuencia.

### Ejercicio 4

**Q4.1** — Dos cualesquiera de: **mtail**, **grok_exporter**, o **recording rules de Loki / consultas de metric de LogQL** (la etapa `metrics` del pipeline de Promtail también califica). Una serie resultante se ve como un counter normal de Prometheus, por ejemplo `log_http_requests_total{method="GET", status="200"} 143` — un conjunto de labels acotado (method, clase de status) y un valor monótonamente creciente. El punto es que la herramienta *colapsa* el texto de log no acotado en un conjunto de labels pequeño y fijo.

**Q4.2** — Construí la alerta sobre la **metric** `kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"} == 1`. Es una serie temporal estable, evaluada continuamente, que Prometheus ya scrapea, así que una regla de alerta puede dispararse de forma determinista y describir *durante cuánto tiempo* se ha mantenido la condición (`for: 5m`). El **Event** es una fuente de alerta pobre porque es efímero (expira por TTL dentro de la hora) y no es scrapeado nativamente por Prometheus — puede desaparecer antes/después de que mires. La **línea de log** es pobre porque alertar sobre texto de log en crudo implica coincidencia de cadenas frágil y escaneo por línea; los logs son para *investigar después* de que la metric se dispara, no para el disparador.

**Q4.3** — El drill-down: **(1) Alerta de metrics** — una serie acotada y siempre activa (tasa de error, `ImagePullBackOff`, SLO de latencia) cruza un umbral y te pagina: *qué* está mal y *cuánto*. **(2) Traces/logs para localizar** — pivotás al servicio/ventana de tiempo afectado para encontrar *dónde* en la ruta de la solicitud se rompe y *cuáles* solicitudes específicas. **(3) Logs para causa raíz** — leés las líneas/events exactos de alto detalle que explican *por qué*. **Los exemplars** son el tejido conectivo: Prometheus puede adjuntar un exemplar (un trace ID, y a menudo suficiente contexto para llegar a los logs correspondientes) a una muestra de metric específica — por ejemplo, un bucket lento en un histograma de latencia — permitiéndote saltar directamente de "esta metric tuvo un pico" a "acá está el trace/log exacto de una de las solicitudes que lo causó", en lugar de adivinar la ventana de tiempo correlacionada.

</details>