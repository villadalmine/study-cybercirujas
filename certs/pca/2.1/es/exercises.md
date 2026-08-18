# PCA — Dominio 2: Fundamentos de Prometheus
## Tema 2.1 — Arquitectura del Sistema · Ejercicios Guiados

> **Formato.** Cada ejercicio es un runbook numerado que ejecutás sobre un Prometheus real. Después de cada bloque hay **preguntas de comprensión**; las respuestas están en la sección plegable `<details>` al final. Todo está diseñado para correr en un único host Linux sin cluster.
>
> **Fuentes citadas a lo largo del documento:**
> - Overview y diagrama de arquitectura — https://prometheus.io/docs/introduction/overview/
> - Referencia de configuración — https://prometheus.io/docs/prometheus/latest/configuration/configuration/
> - Storage / TSDB — https://prometheus.io/docs/prometheus/latest/storage/
> - HTTP API — https://prometheus.io/docs/prometheus/latest/querying/api/
> - Modelo de datos — https://prometheus.io/docs/concepts/data_model/
> - Overview de alerting — https://prometheus.io/docs/alerting/latest/overview/
> - Federación — https://prometheus.io/docs/prometheus/latest/federation/
> - Currículo PCA — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

---

## Ejercicio 0 — Preparación del laboratorio

Necesitás tres piezas móviles para *ver* la arquitectura en lugar de leer sobre ella: el **servidor Prometheus** (que contiene el scraper, la TSDB y el motor de consultas), un **exporter** (un target HTTP que expone `/metrics`) y el **Pushgateway** (para contrastar pull vs. push). Instalamos los tres como binarios estáticos.

```bash
# 1. Prometheus server (adapt the version to the latest 3.x release you find)
VER=3.1.0
wget -q https://github.com/prometheus/prometheus/releases/download/v${VER}/prometheus-${VER}.linux-amd64.tar.gz
tar xzf prometheus-${VER}.linux-amd64.tar.gz
cd prometheus-${VER}.linux-amd64/

# 2. node_exporter — a real target that exposes host metrics
NVER=1.8.2
wget -q https://github.com/prometheus/node_exporter/releases/download/v${NVER}/node_exporter-${NVER}.linux-amd64.tar.gz
tar xzf node_exporter-${NVER}.linux-amd64.tar.gz

# 3. Pushgateway — the bridge for the push model
PVER=1.9.0
wget -q https://github.com/prometheus/pushgateway/releases/download/v${PVER}/pushgateway-${PVER}.linux-amd64.tar.gz
tar xzf pushgateway-${PVER}.linux-amd64.tar.gz
```

Arrancá el exporter y el pushgateway en segundo plano; no son más que servidores HTTP:

```bash
./node_exporter-${NVER}.linux-amd64/node_exporter >/tmp/node.log 2>&1 &   # :9100
./pushgateway-${PVER}.linux-amd64/pushgateway     >/tmp/pgw.log  2>&1 &   # :9091
```

Confirmá que cada uno *no es más que* un endpoint HTTP que sirve el formato de exposición:

```bash
curl -s localhost:9100/metrics | head -n 5
```

Forma esperada (los valores diferirán):

```
# HELP go_gc_duration_seconds A summary of the wall-time pause (stop-the-world) duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 1.9008e-05
go_gc_duration_seconds{quantile="0.25"} 3.6717e-05
go_gc_duration_seconds{quantile="0.5"} 5.4917e-05
```

**Verificación de comprensión 0**
1. El exporter que acabás de arrancar solo es alcanzable cuando *vos* llamás a `curl`. ¿Qué componente de la arquitectura de Prometheus es responsable de recolectar realmente estos números, y cómo llega al exporter?
2. Todavía no se ha "enviado" nada a Prometheus — de hecho Prometheus ni siquiera está corriendo. ¿Qué te dice eso sobre dónde vive físicamente una métrica antes de su primer scrape?

---

## Ejercicio 1 — Diseccionar los componentes internos del servidor

El único binario `prometheus` no es monolítico en su comportamiento; internamente es **Retrieval (scrape manager)** → **TSDB (local storage + WAL)** → **motor PromQL** → **HTTP/Web API**, más un **Rule manager** y un **Service Discovery manager**. Vas a exponer cada subsistema a través de su propio endpoint de status.

1. Escribí una config mínima que haga scrape del propio Prometheus más el node_exporter:

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: pca-lab

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: node
    static_configs:
      - targets: ["localhost:9100"]
```

2. Validá la config *antes* de arrancar — esto es `promtool`, el linter offline que viene en el mismo tarball:

```bash
./promtool check config prometheus.yml
```

Esperado:

```
Checking prometheus.yml
 SUCCESS: prometheus.yml is valid prometheus config file syntax
```

3. Lanzá el servidor, habilitando la API de lifecycle para poder hacer hot-reload más tarde:

```bash
./prometheus \
  --config.file=prometheus.yml \
  --storage.tsdb.path=./data \
  --storage.tsdb.retention.time=15d \
  --web.enable-lifecycle \
  >/tmp/prom.log 2>&1 &
```

4. Sondeá los dos endpoints separados de health/readiness — notá que Prometheus distingue *liveness* de *readiness* exactamente como lo haría un pod de Kubernetes:

```bash
curl -s localhost:9090/-/healthy   # process is alive
curl -s localhost:9090/-/ready     # WAL replayed, ready to serve
```

Esperado:

```
Prometheus Server is Healthy.
Prometheus Server is Ready.
```

5. Interrogá las cuatro status APIs, una por subsistema:

```bash
curl -s localhost:9090/api/v1/status/buildinfo  | jq .data.version
curl -s localhost:9090/api/v1/status/runtimeinfo | jq '{startTime,storageRetention,reloadConfigSuccess,goroutineCount}'
curl -s localhost:9090/api/v1/status/flags       | jq '."storage.tsdb.retention.time"'
curl -s localhost:9090/api/v1/status/config      | jq -r .data.yaml | head -n 6
```

Salida representativa de `runtimeinfo`:

```json
{
  "startTime": "2026-08-08T11:02:17.441Z",
  "storageRetention": "15d",
  "reloadConfigSuccess": true,
  "goroutineCount": 71
}
```

6. Demostrá que Prometheus se hace scrape *a sí mismo*: el servidor expone sus propios internos como métricas en `/metrics`, y esas métricas llevan el nombre de los subsistemas de arriba.

```bash
curl -s localhost:9090/metrics | grep -E '^prometheus_(tsdb_head_series|sd_discovered_targets|rule_group_iterations_total|engine_query_duration_seconds_count) ' | head
```

Esperado (los valores difieren):

```
prometheus_tsdb_head_series 1284
prometheus_sd_discovered_targets{config="node",name="scrape"} 1
prometheus_engine_query_duration_seconds_count{...} 42
```

**Verificación de comprensión 1**
1. `/-/healthy` devolvió OK en el instante en que arrancó el proceso, pero en un servidor con un WAL grande `/-/ready` puede quedar *not ready* durante minutos. ¿Qué trabajo ocurre entre "healthy" y "ready", y por qué un load balancer debe enrutar según el segundo, no el primero?
2. ¿A qué subsistema mapea cada prefijo de métrica: `prometheus_tsdb_*`, `prometheus_sd_*`, `prometheus_rule_*`, `prometheus_engine_*`?
3. Corriste `promtool check config` antes de arrancar. Nombrá una clase de error que `promtool` detecta y que un Prometheus en ejecución solo revelaría al momento del reload — y una que *no puede* detectar.

---

## Ejercicio 2 — El modelo pull, y dónde encaja el push

Prometheus **hace pull**: el servidor abre un `GET /metrics` HTTP contra cada target según un temporizador. Esta es una decisión arquitectónica deliberada — el servidor es dueño del schedule, el service discovery maneja la lista de targets, y un target que desaparece es *observable* (la métrica sintética `up` pasa a 0) en lugar de simplemente silencioso.

1. Mirá la lista de targets tal como la ve el scrape manager:

```bash
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, url:.scrapeUrl, health, lastScrape, scrapeInterval}'
```

Esperado:

```jsonl
{"job":"prometheus","url":"http://localhost:9090/metrics","health":"up","lastScrape":"2026-08-08T11:05:02.11Z","scrapeInterval":"15s"}
{"job":"node","url":"http://localhost:9100/metrics","health":"up","lastScrape":"2026-08-08T11:05:04.90Z","scrapeInterval":"15s"}
```

2. Observá las tres métricas que Prometheus **sintetiza** por cada scrape (son agregadas por el servidor, no por el target). Consultá la API:

```bash
curl -s 'localhost:9090/api/v1/query?query=up' | jq -r '.data.result[] | "\(.metric.job)=\(.value[1])"'
curl -s 'localhost:9090/api/v1/query?query=scrape_duration_seconds' | jq -r '.data.result[] | "\(.metric.job)=\(.value[1])s"'
```

Esperado:

```
prometheus=1
node=1
prometheus=0.004
node=0.019
```

3. Ahora rompé un target y observá cómo reacciona el modelo. Matá node_exporter y esperá un scrape interval:

```bash
pkill node_exporter
sleep 20
curl -s 'localhost:9090/api/v1/query?query=up{job="node"}' | jq -r '.data.result[0].value[1]'
```

Esperado:

```
0
```

El target sigue *conocido* (sigue en la config), así que `up` existe e igual a 0 — un pull fallido es dato, no ausencia. Reiniciálo:

```bash
./node_exporter-1.8.2.linux-amd64/node_exporter >/tmp/node.log 2>&1 &
```

4. Ahora el lado push. Los batch y cron jobs son demasiado efímeros como para hacerles scrape, así que **empujan (push)** al Pushgateway, que retiene el último valor hasta el próximo push y es *él mismo* scrapeado por Prometheus. Agregá el job:

```yaml
  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ["localhost:9091"]
```

Hacé hot-reload (gracias a `--web.enable-lifecycle`) y empujá una muestra:

```bash
curl -s -X POST localhost:9090/-/reload
echo 'batch_job_last_success_timestamp_seconds 1.7549e9' \
  | curl -s --data-binary @- localhost:9091/metrics/job/nightly_backup
curl -s 'localhost:9090/api/v1/query?query=batch_job_last_success_timestamp_seconds' | jq '.data.result'
```

**Verificación de comprensión 2**
1. `up{job="node"}` pasó a `0` pero no desapareció. Contrastá eso con lo que le pasa a `up` si *removés* el node job de la config por completo y hacés reload. ¿Por qué el modelo pull convierte al primer caso en un evento alertable y al segundo en uno silencioso?
2. `honor_labels: true` está configurado en el job del pushgateway pero no en los otros. ¿Qué problema resuelve, dado que el Pushgateway re-expone métricas que ya llevan un label `job` de quien las empujó?
3. Un colega propone empujar *todas* las métricas de aplicación a través del Pushgateway "para evitar abrir puertos para scraping". Da dos razones arquitectónicas por las que los docs de Prometheus advierten contra usar el Pushgateway como un proxy push general.

---

## Ejercicio 3 — Service discovery y relabeling

En producción nunca escribís a mano las listas de targets. **Service Discovery (SD)** produce un stream de targets, cada uno llevando labels de metadata `__meta_*`; **relabeling** luego filtra y reescribe ese stream en targets y labels finales. Este es el único lugar donde la arquitectura te deja remodelar *qué se scrapea* antes de que se almacene un solo byte.

1. Cambiá el node job a **file-based SD** para poder editar targets sin tocar `prometheus.yml`:

```yaml
  - job_name: node
    file_sd_configs:
      - files: ["targets/*.yml"]
        refresh_interval: 10s
    relabel_configs:
      # promote the SD-provided "dc" meta-label into a real target label
      - source_labels: [__meta_filepath]
        target_label: sd_file
      # drop any target explicitly marked disabled
      - source_labels: [__meta_enabled]
        regex: "false"
        action: drop
```

2. Creá el archivo de targets:

```bash
mkdir -p targets
cat > targets/node.yml <<'EOF'
- targets: ["localhost:9100"]
  labels:
    dc: home-lab
    __meta_enabled: "true"
EOF
```

3. Hacé reload e inspeccioná tanto los labels *descubiertos* como los *finales* del target:

```bash
curl -s -X POST localhost:9090/-/reload
curl -s localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.job=="node") | {discovered:.discoveredLabels, final:.labels}'
```

Vas a ver que `discoveredLabels` todavía contiene `__address__`, `__scheme__`, `__metrics_path__`, `__meta_filepath` y tus `dc`/`__meta_enabled` personalizados, mientras que `labels` contiene solo el conjunto sobreviviente sin prefijo `__` después del relabeling.

4. Demostrá que SD es dinámico. Agregá un segundo target *sin reiniciar nada*:

```bash
cat >> targets/node.yml <<'EOF'
- targets: ["localhost:9100"]
  labels:
    dc: edge
    __meta_enabled: "false"
EOF
sleep 12
curl -s localhost:9090/api/v1/targets | jq '[.data.activeTargets[] | select(.labels.job=="node")] | length'
```

Esperado: `1` — el segundo target fue **descartado** por la regla de relabel antes de convertirse siquiera en un target activo.

**Verificación de comprensión 3**
1. Los labels que empiezan con `__` (doble guión bajo) se comportan de manera diferente a los labels ordinarios al final del relabeling. ¿Qué les pasa, y por qué `__address__` es especial?
2. En el JSON del target, ¿cuál es la diferencia precisa entre `discoveredLabels` y `labels`? ¿En qué etapa del pipeline uno se convierte en el otro?
3. Usaste `action: drop` sobre `__meta_enabled="false"`. ¿En qué parte de la arquitectura ocurre este filtrado respecto del scrape — antes o después del `GET /metrics` HTTP? ¿Qué implica eso para el costo de un target descartado?

---

## Ejercicio 4 — Almacenamiento local: WAL, head block y compactación

La TSDB es el componente que la mayoría trata como caja negra. Su trabajo es ingerir muestras en un **head block** en memoria, anexarlas de forma durable a un **write-ahead log (WAL)** primero, y periódicamente volcar rangos cerrados de 2 horas en **blocks** inmutables en disco que luego **compactan** juntos.

1. Mirá el layout en disco:

```bash
ls -R data | head -n 25
```

Representativo (un servidor joven puede no tener blocks numerados todavía):

```
data:
01J9Q2 K...   chunks_head   wal   lock   queries.active

data/wal:
00000000  00000001  checkpoint.00000000

data/chunks_head:
000001
```

Una vez que existen blocks, cada uno es un directorio:

```
data/01J9Q2K.../
├── chunks/000001        # the compressed sample chunks
├── index                # inverted index: label pairs → series
├── meta.json            # time range, series/sample counts, compaction level
└── tombstones           # deletion markers
```

2. Leé el `meta.json` de un block:

```bash
cat data/01J*/meta.json 2>/dev/null | jq '{minTime,maxTime,stats:.stats,level:.compaction.level}' | head -n 20
```

Forma esperada:

```json
{
  "minTime": 1754640000000,
  "maxTime": 1754647200000,
  "stats": {"numSamples": 1839200, "numSeries": 1284, "numChunks": 15410},
  "level": 1
}
```

3. Preguntale a la TSDB sobre su **head** (la ventana en memoria, aún sin volcar) vía la API — este es el dashboard de cardinalidad donde vive cada SRE:

```bash
curl -s localhost:9090/api/v1/status/tsdb | jq '{numSeries:.data.headStats.numSeries, chunkCount:.data.headStats.chunkCount, minTime:.data.headStats.minTime, maxTime:.data.headStats.maxTime}'
curl -s localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[0:3]'
```

Esperado:

```
{"numSeries":1284,"chunkCount":1284,"minTime":1754647200110,"maxTime":1754648103110}
[{"name":"node_cpu_seconds_total","value":112},
 {"name":"go_gc_duration_seconds","value":40},
 {"name":"node_scrape_collector_duration_seconds","value":38}]
```

4. Inspeccioná blocks de forma offline con `promtool` (funciona incluso mientras Prometheus corre, pero solo sobre blocks ya volcados):

```bash
./promtool tsdb list ./data
```

Esperado:

```
BLOCK               MIN TIME             MAX TIME             DURATION   NUM SAMPLES  NUM CHUNKS  NUM SERIES
01J9Q2K...          2026-08-08 09:00     2026-08-08 11:00     2h0m0s     1839200      15410       1284
```

**Verificación de comprensión 4**
1. Ordená estos pasos en el camino de escritura de una única muestra: *anexar al WAL*, *reconocer el scrape*, *insertar en el head block*, *volcar a un block persistente*. ¿Cuáles de estos sobreviven a un `kill -9` y cuáles no?
2. `headStats.numSeries` es la métrica por la que te paginan. Explicá por qué un deployment que pone un `request_id` único en un label va a crashear Prometheus aunque el *volumen* total de requests no cambie.
3. El flag de retención era `--storage.tsdb.retention.time=15d`. La retención borra *blocks* enteros, no muestras individuales. ¿Qué implica esa granularidad sobre con cuánta precisión Prometheus honra los "15 días", y por qué el borrado a nivel de block es el trade-off correcto para una TSDB?

---

## Ejercicio 5 — El pipeline de alerting: el servidor evalúa, Alertmanager enruta

El alerting está dividido en **dos** componentes a propósito. El **servidor Prometheus** *evalúa* las reglas de alerting según `evaluation_interval` y, cuando una expresión permanece verdadera pasada su duración `for:`, dispara una alerta **hacia** Alertmanager. **Alertmanager** — un proceso separado — luego deduplica, agrupa, enruta, silencia e inhibe, y finalmente emite notificaciones. El servidor nunca envía un email.

1. Agregá un archivo de reglas y conectá Alertmanager en la config:

```yaml
# prometheus.yml additions
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

rule_files:
  - "rules/*.yml"
```

```yaml
# rules/pca.yml
groups:
  - name: architecture-demo
    rules:
      - alert: NodeExporterDown
        expr: up{job="node"} == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "node_exporter target {{ $labels.instance }} is down"
```

2. Lintá las reglas (de nuevo, offline):

```bash
./promtool check rules rules/pca.yml
```

Esperado:

```
Checking rules/pca.yml
  SUCCESS: 1 rules found
```

3. Hacé reload, luego disparaste la regla matando el exporter y observá la alerta atravesar la máquina de estados **inactive → pending → firing**:

```bash
curl -s -X POST localhost:9090/-/reload
pkill node_exporter
# within 30s it is "pending"; after the `for:` elapses it is "firing"
sleep 45
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | {name:.labels.alertname, state, activeAt}'
```

Esperado:

```json
{"name":"NodeExporterDown","state":"firing","activeAt":"2026-08-08T11:20:14.9Z"}
```

4. Observá que una alerta en firing es *también solo una métrica*: el rule manager escribe la serie sintética `ALERTS` en la TSDB.

```bash
curl -s 'localhost:9090/api/v1/query?query=ALERTS{alertname="NodeExporterDown"}' | jq '.data.result[0].metric'
```

Esperado:

```json
{"__name__":"ALERTS","alertname":"NodeExporterDown","alertstate":"firing","instance":"localhost:9100","job":"node","severity":"critical"}
```

Reiniciá el exporter; la alerta se limpia y `ALERTS` desaparece dentro de un ciclo de evaluación.

**Verificación de comprensión 5**
1. Trazá la frontera: ¿cuál de estos hace el **servidor Prometheus** y cuál **Alertmanager** — evaluar `expr`, honrar `for:`, agrupar 400 alertas en una notificación, aplicar un silence, enviar a PagerDuty, aplicar una regla de inhibition?
2. La cláusula `for: 30s` cambió el ciclo de vida de la alerta. Describí el estado `pending` y da la razón operativa por la que existe `for:` (¿qué modo de falla suprime?).
3. Alertmanager está diseñado para correr como un **cluster de ≥3 réplicas**, pero a Prometheus se le informan todas ellas vía `static_configs`. Dado que cada Prometheus envía *cada* alerta en firing a *cada* Alertmanager, ¿qué componente es responsable de asegurarse de que la persona de guardia reciba **un** page y no tres? Nombrá el mecanismo.

---

## Ejercicio 6 — Almacenamiento a largo plazo y la topología multi-servidor

Un único Prometheus es intencionalmente un store **local, standalone y no clusterizado** — esa es una decisión arquitectónica, no una limitación a resolver clusterizando la TSDB. La escala y la durabilidad vienen de la *composición*: **remote_write** envía muestras a un store externo de largo plazo, y **federation** permite que un Prometheus de nivel superior scrapee series agregadas de otros de nivel inferior.

1. Inspeccioná el endpoint de federation que tu servidor ya expone — es una scrape URL especial que devuelve series seleccionadas en formato de exposición, pensada para ser scrapeada *por otro Prometheus*:

```bash
curl -s -G 'http://localhost:9090/federate' \
  --data-urlencode 'match[]={job="node"}' \
  --data-urlencode 'match[]=up' | head -n 6
```

Esperado (notá el `instance`/`job` inyectados y el timestamp al final):

```
# TYPE up untyped
up{instance="localhost:9100",job="node",monitor="pca-lab"} 1 1754648220000
node_load1{instance="localhost:9100",job="node",monitor="pca-lab"} 0.14 1754648220000
```

2. Leé las perillas de remote_write sin necesitar un backend — los flags te dicen el modelo de durabilidad:

```bash
curl -s localhost:9090/api/v1/status/flags | jq 'to_entries[] | select(.key|startswith("storage.remote"))'
```

3. Razoná la topología a partir de `external_labels`. Configuraste `monitor: pca-lab` en el Ejercicio 1; confirmá que queda estampado en cada serie federada/remote-written (aparece en la salida de `/federate` de arriba). Este label es lo que mantiene distinguibles los datos de dos Prometheis una vez fusionados en un store global.

**Verificación de comprensión 6**
1. Los `external_labels` *no* se adjuntan a las series en el almacenamiento local pero *sí* se adjuntan a la salida (federation, remote_write, alertas). ¿Por qué la arquitectura los agrega solo en la frontera de egreso?
2. Federation y remote_write ambos mueven datos fuera de un Prometheus, pero responden preguntas diferentes. Establecé el uso previsto de cada uno: *"hierarchical federation"* vs. *"remote long-term storage"*. ¿Cuál es pull y cuál es push?
3. Alguien te pide hacer Prometheus "highly available" apuntando dos servidores al mismo directorio de TSDB en almacenamiento compartido. Explicá, a partir de lo que viste del WAL y el head block en el Ejercicio 4, por qué esto corrompe los datos — y cuál es el patrón de HA *correcto* en su lugar.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Verificación 0
1. El **scrape manager (Retrieval)** dentro del servidor Prometheus hace la recolección, realizando un `GET /metrics` HTTP contra `localhost:9100` según el schedule de scrape — el exporter es pasivo y nunca inicia una conexión. Este es el **modelo pull**.
2. Antes de su primer scrape la métrica vive **solo dentro de la memoria del proceso del exporter**, recomputada bajo demanda cada vez que se solicita `/metrics`. No hay historial ni almacenamiento en el exporter; sostiene un único valor actual. La persistencia empieza solo cuando Prometheus hace scrape y escribe a su TSDB. (https://prometheus.io/docs/introduction/overview/)

### Verificación 1
1. Entre *healthy* y *ready*, Prometheus **reproduce el WAL** para reconstruir el head block en memoria, recarga la config, y levanta los scrape/rule managers. `/-/healthy` solo dice que el proceso no se colgó; `/-/ready` dice que las consultas y scrapes van a funcionar de verdad. Un load balancer (o una readiness probe de Kubernetes) debe condicionarse a `/-/ready`, de lo contrario enruta consultas a un servidor cuyo head todavía está vacío, devolviendo resultados incorrectos/parciales.
2. `prometheus_tsdb_*` → **storage/TSDB** local; `prometheus_sd_*` → manager de **service discovery**; `prometheus_rule_*` → manager de **rule** (recording/alerting); `prometheus_engine_*` → **motor de consultas PromQL**.
3. `promtool` detecta **errores de sintaxis y de schema** (campos desconocidos, YAML malformado, duraciones/regex inválidas, expresiones de regla incorrectas). **No puede** detectar problemas **de runtime/semánticos**: un target que es inalcanzable, un `bearer_token_file` que no existe en disco, un backend de SD que no devuelve nada, o una regla que es sintácticamente válida pero lógicamente incorrecta. Esos afloran solo cuando Prometheus corre.

### Verificación 2
1. Cuando el target *falla en responder*, sigue en la config, así que `up{job="node"}` **existe e igual a 0** — un evento alertable. Cuando *borrás el job y hacés reload*, el target ya no se descubre, así que la serie `up` simplemente **deja de recibir muestras y se vuelve stale/ausente** — no hay señal para alertar. El modelo pull convierte "target presente pero roto" en dato explícito; no puede, por sí mismo, alertar sobre "target removido intencionalmente".
2. Las métricas empujadas al Pushgateway ya llevan sus propios labels `job`/`instance`. Sin `honor_labels: true`, Prometheus **sobrescribiría** esos con los labels del propio job del pushgateway (`job="pushgateway"`), colapsando cada métrica empujada sobre la identidad del gateway. `honor_labels: true` le indica al scrape que **conserve los labels ya presentes en las métricas expuestas** en lugar de reetiquetarlas hacia el job que scrapea.
3. Dos razones de los docs: (a) El Pushgateway es un **único punto de falla y un cuello de botella** — perdés la señal de health `up` por target (solo obtenés el `up` del gateway), y el valor stale de una instancia fallida **persiste para siempre** hasta que se lo borra explícitamente, enmascarando caídas. (b) Contradice el modelo de Prometheus: está pensado solo para **resultados de batch-jobs a nivel de servicio**, no para convertir un sistema pull en un proxy push para servicios de larga vida. (https://prometheus.io/docs/practices/pushing/)

### Verificación 3
1. Los labels que empiezan con `__` son **labels internos/meta**; se usan durante el relabeling pero se **descartan antes de la ingesta**, así que nunca aparecen en las series almacenadas. `__address__` es especial porque contiene el **`host:port` al que el scraper realmente se va a conectar**; combinado con `__scheme__` y `__metrics_path__` *construye la scrape URL*. Reescribís `__address__` vía relabeling para redirigir un scrape.
2. `discoveredLabels` es el **target crudo tal como lo produjo SD**, incluyendo todas las entradas `__meta_*` y `__address__`. `labels` es el **conjunto final de labels después de que corrieron los `relabel_configs`** y después de que se removieron los labels internos `__`. La transformación ocurre en la **etapa de relabeling**, entre el service discovery y el scrape.
3. El drop ocurre **antes del `GET /metrics` HTTP** — el relabeling corre sobre la lista de targets en el momento del discovery, así que un target descartado **nunca se scrapea en absoluto**. El costo es efectivamente cero: sin conexión, sin muestras, sin series, sin cardinalidad. (Por esto el relabel-drop es la herramienta correcta para excluir targets, no el filtrado post-scrape).

### Verificación 4
1. Orden del camino de escritura: **anexar al WAL → insertar en el head block → reconocer el scrape**; **volcar a un block persistente** ocurre más tarde, de forma asincrónica (aproximadamente cada 2 horas). El **WAL sobrevive a `kill -9`** (está fsync'd a disco y se reproduce al reiniciar para reconstruir el head); el **estado en memoria del head block no** sobrevive por sí solo — se reconstruye *a partir del* WAL.
2. `numSeries` cuenta **combinaciones únicas de conjuntos de labels**, y un `request_id` único por request significa que **cada request crea una serie nueva**. Esto es una **explosión de cardinalidad** ilimitada: el head block, el índice invertido y la memoria crecen sin límite independientemente de la tasa de requests, terminando por OOM-killear a Prometheus. El volumen está bien; el eje de escalamiento son las *series distintas*.
3. Porque el borrado es **de granularidad de block** (block por defecto ≈ 2 h, hasta ~10 % de la retención tras compactación), Prometheus retiene los datos hasta que el **block entero** cae fuera de la ventana, así que podés retener hasta aproximadamente una duración de block **más allá** de los 15 días nominales. Ese es el trade-off correcto: los blocks son **inmutables** (I/O barato, secuencial; sin reescritura), así que borrar archivos inmutables enteros es mucho más barato que remover quirúrgicamente muestras individuales de un índice vivo.

### Verificación 5
1. **Servidor Prometheus:** evaluar `expr`, honrar `for:` (pending→firing), escribir `ALERTS`, enviar la alerta en firing a Alertmanager. **Alertmanager:** agrupar 400 alertas en una notificación, aplicar silences, enviar a PagerDuty, aplicar reglas de inhibition.
2. `pending` significa que la expresión está **actualmente verdadera pero todavía no ha sido verdadera durante la duración completa de `for:`**. Si deja de ser verdadera antes de que transcurra `for:`, vuelve a inactive y nunca notifica. `for:` existe para suprimir **flapping / picos transitorios** — requiere que la condición persista, de modo que un único scrape malo no paginee a nadie.
3. **Alertmanager**, vía su **clustering / deduplicación basados en gossip**: las réplicas forman un cluster, se coordinan sobre el pipeline de notificación, y **deduplican alertas idénticas** de modo que se envíe exactamente una notificación aunque cada Prometheus haya disparado la alerta a todas las réplicas. El trabajo de Prometheus es solo *repartir la alerta a cada* Alertmanager (por redundancia); la deduplicación es responsabilidad de Alertmanager. (https://prometheus.io/docs/alerting/latest/overview/)

### Verificación 6
1. Los `external_labels` identifican **a este Prometheus entre muchos**. Agregarlos al almacenamiento local sería redundante (un servidor ya conoce sus propios datos) e inflaría cada serie; los labels solo importan una vez que los datos **salen** del servidor y se **fusionan** con los datos de otros Prometheis (en un store global, un padre que federa, o Alertmanager), donde tenés que poder distinguir las fuentes. De ahí que se estampen solo en la **frontera de egreso**.
2. **Hierarchical federation** = un Prometheus de nivel superior **hace pull** de un subconjunto *seleccionado y agregado* de series desde Prometheis de nivel inferior vía `/federate` (topologías de drill-down/roll-up). **Remote long-term storage** vía `remote_write` = Prometheus **empuja (push)** *todas* las muestras a un backend externo durable (p. ej. para retención más allá del disco local y consulta global). Federation es **pull**; remote_write es **push**.
3. Dos procesos Prometheus no pueden compartir un directorio de TSDB: cada uno tiene su **propio head block en memoria y su propio WAL**, y ambos anexarían a los mismos segmentos del WAL y archivos de block, produciendo **escrituras intercaladas y corruptas** (el archivo `lock` está exactamente ahí para evitar que dos servidores abran el mismo directorio). El patrón de HA correcto son **dos servidores Prometheus independientes, cada uno con su propio almacenamiento, scrapeando los mismos targets en paralelo**, ambos alimentando un **Alertmanager clusterizado** que deduplica — redundancia corriendo réplicas *idénticas e independientes*, no compartiendo estado. (https://prometheus.io/docs/prometheus/latest/storage/)

</details>