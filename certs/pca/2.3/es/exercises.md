# Ejercicios guiados — Tema 2.3: Comprendiendo las limitaciones de Prometheus

**Certificación:** Prometheus Certified Associate (PCA) · **Dominio:** Fundamentos de Prometheus · **Peso en el examen:** 4%

> Toda decisión madura sobre monitoreo es una decisión sobre lo que Prometheus *deliberadamente no hace*. Los autores de Prometheus son inusualmente explícitos sobre esto en la sección ["When does it not fit?"](https://prometheus.io/docs/introduction/overview/#when-does-it-not-fit) del overview: Prometheus valora la **confiabilidad por encima del 100% de exactitud**, corre como un **único nodo autocontenido** y conserva solo **datos locales de corto plazo**. Estos ejercicios reproducen cada limitación en tu propia máquina para que puedas *ver* el límite en lugar de memorizarlo.

## Prerrequisitos

- Docker Engine ≥ 24 y `curl` + `jq` instalados.
- ~1 GB de disco y RAM libres para los labs de TSDB/cardinalidad.
- Una red bridge dedicada para que los contenedores se resuelvan entre sí por nombre:

```bash
docker network create promlab
```

- Configuración de scrape base usada a lo largo de todo (`prometheus.yml`):

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
```

---

## Ejercicio 1 — El almacenamiento local es de corto plazo, de un solo nodo y no durable

Objetivo: demostrar que la TSDB local de Prometheus **elimina** activamente los datos viejos y está acotada por la retención, razón por la cual *no* es un almacén de largo plazo ni un sistema de registro (system of record).

### Pasos

1. Iniciá Prometheus con una retención **basada en tamaño** intencionalmente diminuta para que la maquinaria de eliminación se dispare rápido:

```bash
docker run -d --name prometheus --network promlab -p 9090:9090 \
  -v "$(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml" \
  prom/prometheus:v2.53.0 \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.size=64MB \
  --storage.tsdb.retention.time=6h
```

2. Inspeccioná la distribución en disco de la TSDB. Notá que es un **directorio local**, no un almacén en clúster:

```bash
docker exec prometheus ls -1 /prometheus
```

Salida esperada (ilustrativa) poco después de iniciar:

```
chunks_head
lock
queries.active
wal
```

El `wal/` (write-ahead log) y `chunks_head/` contienen el *head block* en memoria; los bloques persistidos (nombrados con ULIDs como `01J4Z3P...`) solo aparecen después de que se corta el primer bloque de 2 horas.

3. Leé los contadores de retención. Estos se incrementan **cada vez** que un bloque se elimina por exceder el límite de tiempo o de tamaño:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_time_retentions_total' \
  | jq -r '.data.result[0].value[1]'
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_size_retentions_total' \
  | jq -r '.data.result[0].value[1]'
```

Justo después de iniciar, ambos leen `0`. Una vez que la TSDB supera los 64 MB, `prometheus_tsdb_size_retentions_total` empieza a subir (`1`, `2`, …).

4. Observá cuánto hacia atrás llegan realmente tus datos — el horizonte práctico de un Prometheus sin asistencia:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=(time()-prometheus_tsdb_lowest_timestamp_seconds)/3600' \
  | jq -r '.data.result[0].value[1]'
```

El número es la antigüedad (en horas) de la muestra más vieja que todavía está en disco — **nunca** crecerá más allá de tu ventana de retención.

5. Mirá la vía de escape documentada. Prometheus no resuelve el almacenamiento de largo plazo internamente; expone `remote_write`. Agregá este bloque a `prometheus.yml` (un backend real como Mimir/Thanos/VictoriaMetrics lo recibiría):

```yaml
remote_write:
  - url: "http://mimir:9009/api/v1/push"
    queue_config:
      capacity: 10000
      max_shards: 50
      max_samples_per_send: 2000
```

Después del reload, el pipeline de salida es observable a través de:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_remote_storage_samples_pending' \
  | jq -r '.data.result[0].value[1]'
```

**Verificación de comprensión 1**

- **Q1.1** Si configurás `--storage.tsdb.retention.time=15d` en un único Prometheus, ¿qué le pasa a una muestra de métrica que tiene 16 días de antigüedad, y qué implica esto para la planificación de capacidad o para casos de uso de cumplimiento/auditoría (compliance/audit)?
- **Q1.2** Cuando se configuran *ambos*, `retention.time` y `retention.size`, ¿cuál dispara la eliminación?
- **Q1.3** ¿Por qué `remote_write` — y no un disco más grande — es la respuesta arquitectónicamente correcta a "necesitamos 13 meses de historia"? Nombrá dos capacidades que ganás además de una retención más larga.

---

## Ejercicio 2 — La cardinalidad es el verdadero límite de escalado

Objetivo: observar cómo la cantidad de series activas (y por lo tanto la memoria) explota cuando las labels llevan valores no acotados, y aprender las herramientas incorporadas para *encontrar* al culpable.

### Pasos

1. Lanzá [`avalanche`](https://github.com/prometheus-community/avalanche), el generador sintético de carga de métricas de la comunidad de Prometheus. Empezá con una forma **estable y moderada** — 100 métricas × 20 series = 2 000 series:

```bash
docker run -d --name avalanche --network promlab -p 9001:9001 \
  quay.io/prometheuscommunity/avalanche:v0.6.0 \
  --metric-count=100 --series-count=20 --label-count=5 \
  --value-interval=15 --series-interval=3600 --metric-interval=3600 \
  --port=9001
```

2. Agregá el target a `prometheus.yml` y recargá Prometheus (`docker kill -s HUP prometheus`):

```yaml
  - job_name: avalanche
    static_configs:
      - targets: ['avalanche:9001']
```

3. Después de ~30 s, leé la cantidad de head series — el número de **series de tiempo activas** mantenidas en memoria:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' \
  | jq -r '.data.result[0].value[1]'
```

Esperado (ilustrativo):

```
2712
```

(~2 000 de avalanche + ~700 de las propias métricas de Prometheus.)

4. Preguntale a la TSDB *quién* es costoso. El endpoint `/api/v1/status/tsdb` es el diagnóstico de cardinalidad de primera línea — los mismos datos que se muestran en la página de UI **Status → TSDB Stats**:

```bash
curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data | {headStats, seriesCountByMetricName: .seriesCountByMetricName[:3], labelValueCountByLabelName: .labelValueCountByLabelName[:3]}'
```

Esperado (ilustrativo):

```json
{
  "headStats": {
    "numSeries": 2712,
    "numLabelPairs": 648,
    "chunkCount": 2740,
    "minTime": 1723100000000,
    "maxTime": 1723100460000
  },
  "seriesCountByMetricName": [
    { "name": "avalanche_metric_mmmmm_0_0", "value": 20 },
    { "name": "avalanche_metric_mmmmm_0_1", "value": 20 },
    { "name": "avalanche_metric_mmmmm_0_2", "value": 20 }
  ],
  "labelValueCountByLabelName": [
    { "name": "__name__", "value": 100 },
    { "name": "series_id", "value": 20 },
    { "name": "cycle_id", "value": 1 }
  ]
}
```

5. Ahora **hacé explotar la cardinalidad** de la forma en que lo haría una label ingenua de `user_id` / `request_id` / `email` en producción. Reemplazá avalanche con una forma de alto abanico (fan-out) y churn — 500 métricas × 100 series, con labels *rotando cada 10 s* de modo que las series viejas nunca dejen de acumularse en el head:

```bash
docker rm -f avalanche
docker run -d --name avalanche --network promlab -p 9001:9001 \
  quay.io/prometheuscommunity/avalanche:v0.6.0 \
  --metric-count=500 --series-count=100 --label-count=10 \
  --value-interval=5 --series-interval=10 --metric-interval=10 \
  --port=9001
```

6. Volvé a leer las head series a lo largo de un minuto:

```bash
for i in 1 2 3 4; do
  curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' \
    | jq -r '.data.result[0].value[1]'
  sleep 15
done
```

Esperado (ilustrativo — notá el ascenso impulsado por el churn, y luego el diente de sierra del head-GC):

```
51873
78402
103661
64890
```

7. Confirmá que el costo de memoria es real:

```bash
docker stats --no-stream prometheus
```

Esperado (ilustrativo):

```
CONTAINER   NAME         CPU %   MEM USAGE / LIMIT
a1b2c3d4    prometheus   38.4%   612.7MiB / 7.6GiB
```

**Verificación de comprensión 2**

- **Q2.1** Total de series activas ≈ (número de nombres de métrica) × (producto de los valores distintos de cada label en esa métrica). Dado `http_requests_total` con `method` (5 valores), `status` (8), `path` (200) y una `user_id` recién agregada (50 000 valores), ¿cuántas series puede producir esta sola métrica?
- **Q2.2** ¿Cuáles dos campos de `/api/v1/status/tsdb` leerías primero para localizar una bomba de cardinalidad, y qué te dice cada uno?
- **Q2.3** ¿Por qué el *churn de labels* (valores que cambian con el tiempo, como nombres de `pod` o una `version` que rota) es especialmente peligroso incluso si la cardinalidad instantánea parece modesta?

---

## Ejercicio 3 — El modelo pull se pierde los jobs de vida corta (y los propios límites del Pushgateway)

Objetivo: demostrar que Prometheus hace scrape según un cronograma, de modo que un job que termina entre scrapes nunca es observado — y que el Pushgateway es un remedio *acotado*, no una conversión de Prometheus en un sistema push.

### Pasos

1. Simulá un job batch más corto que un intervalo de scrape. Expone una métrica durante 3 segundos y luego sale:

```bash
docker run -d --name batch --network promlab \
  python:3.12-alpine sh -c \
  'echo "backup_done 1" > /tmp/m; timeout 3 python -m http.server 8000 --directory /tmp; echo gone'
```

2. Apuntá Prometheus hacia él y recargá. Como el contenedor está arriba solo ~3 s y el intervalo de scrape es de 15 s, el target está casi siempre `down`:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{job="batch"}' \
  | jq -r '.data.result[]?.value[1] // "no data scraped"'
```

Esperado:

```
no data scraped
```

La métrica `backup_done` nunca aterriza en la TSDB — el planificador de pull y el tiempo de vida del job nunca se solaparon.

3. Desplegá el **Pushgateway**, el puente sancionado para *jobs batch a nivel de servicio*:

```bash
docker run -d --name pushgateway --network promlab -p 9091:9091 prom/pushgateway:v1.9.0
```

4. Hacé scrape al Pushgateway. `honor_labels: true` es obligatorio acá — explicate a vos mismo por qué antes de leer la respuesta:

```yaml
  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ['pushgateway:9091']
```

5. Hacé que el job batch **empuje** (push) su resultado al completarse, con clave por una agrupación (`job`/`instance`):

```bash
cat <<'EOF' | curl --data-binary @- http://localhost:9091/metrics/job/db_backup/instance/db01
# TYPE db_backup_records_processed counter
db_backup_records_processed 24519
# TYPE db_backup_duration_seconds gauge
db_backup_duration_seconds 42.7
# TYPE db_backup_last_success_timestamp_seconds gauge
db_backup_last_success_timestamp_seconds 1723100500
EOF
```

6. Consultá a Prometheus por la métrica empujada. Ahora está presente *aunque el job hace rato que se fue*:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=db_backup_last_success_timestamp_seconds' \
  | jq -r '.data.result[0] | "\(.metric.job) \(.metric.instance) = \(.value[1])"'
```

Esperado:

```
db_backup db01 = 1723100500
```

7. Ahora enfrentá la propia limitación del Pushgateway. Dejá de empujar y no borres nada. Esperá 5 minutos y volvé a ejecutar el paso 6 — **el valor sigue ahí, sin cambios**. El Pushgateway persiste el último push indefinidamente hasta que se lo elimine explícitamente:

```bash
curl -X DELETE http://localhost:9091/metrics/job/db_backup/instance/db01
```

**Verificación de comprensión 3**

- **Q3.1** ¿Por qué `up{job="batch"}` no devolvió datos — qué específicamente no logró alinear el planificador de pull?
- **Q3.2** Según la guía oficial ["When to use the Pushgateway"](https://prometheus.io/docs/practices/pushing/), ¿para qué único caso de uso legítimo es, y contra qué antipatrón explícito advierte?
- **Q3.3** Nombrá dos formas en que el Pushgateway *rompe* la semántica normal de Prometheus (pensá: qué le pasa a `up`, a la salud del target y a la staleness cuando la fuente desaparece?).

---

## Ejercicio 4 — Un único Prometheus no forma clúster; la federación no es clustering

Objetivo: construir una federación de dos niveles y ver que la federación *sube una porción seleccionada* de series — te da un rollup jerárquico, no un clúster escalado horizontalmente y de alta disponibilidad.

### Pasos

1. Iniciá un segundo Prometheus **"global"** cuyo único job es federar desde el primero. Configuración (`global.yml`):

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'federate'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{job="avalanche"}'
        - '{__name__=~"job:.*"}'   # convention: only pre-aggregated recording rules
    static_configs:
      - targets: ['prometheus:9090']
```

```bash
docker run -d --name prometheus-global --network promlab -p 9099:9090 \
  -v "$(pwd)/global.yml:/etc/prometheus/prometheus.yml" \
  prom/prometheus:v2.53.0 \
  --config.file=/etc/prometheus/prometheus.yml
```

2. Inspeccioná exactamente qué cruza el límite de la federación — pegale directamente al endpoint `/federate` de la hoja (leaf):

```bash
curl -s -G http://localhost:9090/federate \
  --data-urlencode 'match[]={job="avalanche"}' | head -5
```

Esperado (ilustrativo — notá que cada muestra lleva un timestamp explícito):

```
# TYPE avalanche_metric_mmmmm_0_0 untyped
avalanche_metric_mmmmm_0_0{cycle_id="0",series_id="0",instance="avalanche:9001",job="avalanche"} 42 1723100500123
avalanche_metric_mmmmm_0_0{cycle_id="0",series_id="1",instance="avalanche:9001",job="avalanche"} 17 1723100500123
```

3. Compará las cantidades de series entre los dos niveles para ver que el nivel global contiene un **subconjunto**, no una réplica:

```bash
echo "leaf:   $(curl -s 'http://localhost:9090/api/v1/query?query=count(count%20by%20(__name__)({__name__=~%22avalanche.%2B%22}))' | jq -r '.data.result[0].value[1]')"
echo "global: $(curl -s 'http://localhost:9099/api/v1/query?query=count(count%20by%20(__name__)({__name__=~%22avalanche.%2B%22}))' | jq -r '.data.result[0].value[1]')"
```

4. Demostrá que **no hay HA/dedup automático**. Corré una *segunda hoja idéntica* (`prometheus-b`) haciendo scrape al mismo target avalanche y federá ambas hacia global. Series idénticas ahora llegan dos veces y tenés que deduplicar con una capa externa (Thanos Querier, Mimir) o con `honor_labels` + external labels — Prometheus no las va a fusionar por vos.

**Verificación de comprensión 4**

- **Q4.1** En la federación jerárquica, ¿qué se *supone* que debés subir al nivel global, y por qué subir `{__name__=~".+"}` (todo) es un antipatrón?
- **Q4.2** Corrés dos réplicas idénticas de Prometheus para disponibilidad. Una consulta de dashboard ahora devuelve series duplicadas. ¿De quién es el trabajo de deduplicarlas, y por qué un único Prometheus no puede hacerlo?
- **Q4.3** La federación y `remote_write` ambas mueven datos fuera de un nodo. Enunciá la diferencia central en *dirección y propósito* de cada uno.

---

## Ejercicio 5 — Confiabilidad por encima del 100% de exactitud: resolución de scrape y aliasing

Objetivo: mostrar que Prometheus muestrea el mundo a una cadencia fija, de modo que los eventos sub-scrape se pierden — que es exactamente por qué la documentación dice que no es apto para facturación por request ni contabilidad exacta de eventos.

### Pasos

1. Reconfigurá el target avalanche para que cambie sus valores **cada segundo** mientras Prometheus sigue haciendo scrape cada 15 s. Corré avalanche con un churn de valor rápido:

```bash
docker rm -f avalanche
docker run -d --name avalanche --network promlab -p 9001:9001 \
  quay.io/prometheuscommunity/avalanche:v0.6.0 \
  --metric-count=1 --series-count=1 --label-count=1 \
  --value-interval=1 --port=9001
```

2. A lo largo de una ventana de 5 minutos, contá cuántas **muestras almacenó realmente Prometheus** para esa serie:

```bash
curl -s -G 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count_over_time(avalanche_metric_mmmmm_0_0[5m])' \
  | jq -r '.data.result[0].value[1]'
```

Esperado (ilustrativo): alrededor de `20` — una muestra por cada scrape de 15 s.

3. Compará contra la realidad: la fuente cambió su valor ~300 veces (una vez por segundo) en esos 5 minutos. **~280 de esos estados nunca fueron registrados.** Prometheus capturó una *muestra*, no el *flujo de eventos*.

4. Observá la segunda mitad de "confiabilidad por encima de exactitud": el manejo de la staleness. Matá el target y consultalo inmediatamente:

```bash
docker stop avalanche
curl -s 'http://localhost:9090/api/v1/query?query=up{job="avalanche"}' \
  | jq -r '.data.result[0].value[1]'
```

Por hasta 5 minutos, una consulta instantánea puede seguir devolviendo el **último valor conocido** con las reglas de staleness en lugar de dar error — Prometheus prefiere darte datos *aproximadamente-correctos y disponibles* antes que hacer fallar la consulta. Después de la ventana de staleness (5 min por defecto) la serie se vuelve stale y desaparece.

**Verificación de comprensión 5**

- **Q5.1** Tu equipo de facturación quiere cobrarles a los clientes por request de API usando `http_requests_total` scrapeado cada 30 s. Con referencia a la guía oficial "When does it not fit?", ¿por qué Prometheus es el sistema de registro equivocado para esto — y para qué *sí* es suficientemente bueno?
- **Q5.2** Un gauge (por ejemplo, `queue_depth`) brevemente sube a 40 000 durante 2 segundos entre dos scrapes de 15 s y vuelve a 10. ¿Qué mostrará tu dashboard, y qué enseña esto sobre gauges vs. counters bajo muestreo?
- **Q5.3** ¿Por qué `rate()` sobre un *counter* sobrevive esta limitación de muestreo mucho mejor que una lectura de gauge cruda?

---

<details>
<summary><strong>Clave de respuestas — clic para expandir</strong></summary>

### Ejercicio 1 — Almacenamiento local

- **A1.1** La muestra de 16 días es **eliminada permanentemente** por el job de retención; no hay forma de recuperarla desde ese nodo. El almacenamiento local está acotado y no es autoritativo, por lo que un único Prometheus no es adecuado como sistema de registro de auditoría/compliance ni para planificación de capacidad con look-back de largo alcance — dimensionás el disco para la *ventana de retención × tasa de ingesta*, no para "toda la historia". La historia larga debe vivir en un backend remoto/de downsampling.
- **A1.2** **El límite que se alcance primero.** Son techos independientes, ambos aplicados eliminando los bloques persistidos más viejos. `retention.time` elimina los bloques más viejos que la ventana; `retention.size` elimina los bloques más viejos una vez que la TSDB en disco supera el presupuesto en bytes.
- **A1.3** `remote_write` transmite muestras a un backend construido con ese propósito (Thanos, Cortex/Mimir, VictoriaMetrics). Además de una retención más larga ganás (dos cualesquiera de): una **vista de consulta global** a través de muchos Prometheus, **escalado/sharding horizontal** del almacenamiento, **downsampling** para consultas de largo alcance baratas, y **deduplicación HA** de Prometheus replicados. Un disco local más grande no da ninguno de estos — sigue siendo un nodo, un dominio de falla, un motor de consulta. (Docs: [storage](https://prometheus.io/docs/prometheus/latest/storage/).)

### Ejercicio 2 — Cardinalidad

- **A2.1** 5 × 8 × 200 × 50 000 = **400,000,000** series de un solo nombre de métrica — una bomba de cardinalidad de manual. `user_id` es no acotado/de alto churn y nunca debe ser una label. (Guía: [do not overuse labels](https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels), [naming/cardinality](https://prometheus.io/docs/practices/naming/).)
- **A2.2** `seriesCountByMetricName` — qué **nombre de métrica** posee la mayor cantidad de series (la métrica culpable); y `labelValueCountByLabelName` — qué **label** tiene la mayor cantidad de valores distintos (la dimensión culpable). Juntos apuntan a "la métrica X explotó porque la label Y no está acotada". (También se muestra en la página **Status → TSDB Stats**.)
- **A2.3** La cardinalidad instantánea puede parecer pequeña, pero cada *nuevo* valor de una label con churn (`pod`, `container_id`, `version` de despliegue, `ip` efímera) crea una serie totalmente nueva que queda en el head block hasta que se vuelve stale y es recolectada por el GC. El churn sostenido significa que la cuenta **acumulada** de series activas y el tamaño del índice siguen creciendo, elevando la memoria y bajando la latencia de consulta aunque "¿cuántos pods ahora?" sea un número chico. Por esto nunca etiquetás con valores que rotan con el tiempo.

### Ejercicio 3 — Modelo pull y Pushgateway

- **A3.1** El planificador de scrape se dispara con una cadencia fija de 15 s; el job existió solo ~3 s. La ventana de scrape y el tiempo de vida del job **nunca se solaparon**, así que Prometheus nunca hizo una petición HTTP exitosa hacia él — de ahí que no haya muestra `up` ni métrica. El monitoreo pull asume que el target está arriba el tiempo suficiente para ser scrapeado.
- **A3.2** Es para capturar el resultado de un **job batch a nivel de servicio** (un job no atado a una sola máquina/instancia) que es demasiado corto para ser scrapeado. El antipatrón explícito: **no** es una forma de convertir Prometheus en un sistema basado en push para métricas de aplicación regulares, ni un agregador general de eventos/mensajes — los servicios normales deben seguir siendo scrapeados. (Docs: [When to use the Pushgateway](https://prometheus.io/docs/practices/pushing/).)
- **A3.3** Dos cualesquiera de: (1) **Rompe la salud del target** — `up` refleja la salud del propio Pushgateway, no la del job, así que un job muerto igual parece estar bien. (2) **Anula la staleness** — el último valor empujado persiste para siempre hasta que se lo `DELETE`a explícitamente, así que una métrica puede volverse peligrosamente stale de forma silenciosa. (3) Es un **punto único de falla / punto de agregación compartido** entre muchos jobs, y (4) `honor_labels: true` es requerido precisamente porque las labels `job`/`instance` empujadas serían de otro modo sobrescritas por las propias labels de target del Pushgateway.

### Ejercicio 4 — Sin clustering; federación ≠ clúster

- **A4.1** Subís **series pre-agregadas y de baja cardinalidad** — típicamente la salida de recording rules (convención de nombres `job:...`) — al nivel global/superior para una vista general entre datacenters. Subir `{__name__=~".+"}` copia *cada serie cruda* por la red hacia un solo nodo, recreando el problema de cardinalidad/escala del que estabas tratando de escapar y anulando el sentido del rollup jerárquico.
- **A4.2** Una **capa externa** (Thanos Querier, Cortex/Mimir, o un paso de dedup con clave en `external_labels`) deduplica las réplicas. Un único Prometheus no puede: cada réplica es un nodo independiente y autocontenido sin conocimiento de su gemela — no hay clustering incorporado, gossip ni consenso compartido en Prometheus. La HA se logra corriendo scrapers redundantes y deduplicando *aguas abajo*.
- **A4.3** La **federación** es un *pull* desde un nivel superior que alcanza *hacia abajo* dentro de otro Prometheus y copia un **subconjunto seleccionado** de series (rollups, vista general entre DCs). **`remote_write`** es un *push* desde un Prometheus *hacia afuera/arriba* dentro de un backend de almacenamiento escalable y de largo plazo para **durabilidad, escala y consulta global**. La dirección y la intención difieren: federación = lectura jerárquica selectiva; remote_write = descarga continua del flujo completo.

### Ejercicio 5 — Confiabilidad por encima de exactitud

- **A5.1** Con un scrape de 30 s, Prometheus registra el valor del counter dos veces por minuto, no en cada request; entre scrapes interpola vía `rate()`/`increase()` y puede perder datos durante una falla de scrape. La documentación lo dice sin rodeos: *"If you need 100% accuracy, such as for per-request billing, Prometheus is not a good choice as the collected data will likely not be detailed and complete enough."* **Sí** es suficientemente bueno para tendencias, SLOs, umbrales de alerta y señales de capacidad — donde "aproximadamente correcto y siempre disponible" le gana a "perfecto pero frágil". ([When does it not fit?](https://prometheus.io/docs/introduction/overview/#when-does-it-not-fit))
- **A5.2** El dashboard muestra `queue_depth` ≈ **10** todo el tiempo — el pico de 40 000 cayó *entre* scrapes y nunca fue muestreado, así que es invisible. Lección: un **gauge bajo muestreo solo captura su valor en los instantes de scrape**; los picos transitorios se pierden por aliasing. Para atrapar los picos necesitás un histograma/`max_over_time` sobre un counter de mayor resolución, un intervalo de scrape más corto (a costo de cardinalidad/costo), o herramientas basadas en eventos — no un gauge simple.
- **A5.3** Un **counter** es monotónico y acumulativo: cada incremento entre scrapes todavía se refleja en la *diferencia* entre dos valores scrapeados, así que `rate()`/`increase()` recuperan la actividad promedio por segundo a lo largo del intervalo aunque los eventos individuales no hayan sido muestreados. Un **gauge** crudo solo lleva su valor instantáneo en el momento del scrape, así que cualquier cosa que haya pasado entre scrapes se pierde por completo. Por esto las *tasas* de request/error sobreviven al muestreo de Prometheus mientras que los picos instantáneos de gauge no.

</details>

---

### Fuentes

- Prometheus — Overview, *"When does it not fit?"*: https://prometheus.io/docs/introduction/overview/#when-does-it-not-fit
- Prometheus — Storage (TSDB local, retención, `remote_write`/`remote_read`): https://prometheus.io/docs/prometheus/latest/storage/
- Prometheus — Instrumentation best practices, *"Do not overuse labels"* (cardinalidad): https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels
- Prometheus — Metric and label naming: https://prometheus.io/docs/practices/naming/
- Prometheus — *"When to use the Pushgateway"*: https://prometheus.io/docs/practices/pushing/
- Prometheus — Federation: https://prometheus.io/docs/prometheus/latest/federation/
- Prometheus — Querying basics / staleness: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- `prometheus-community/avalanche` (generador sintético de carga de cardinalidad): https://github.com/prometheus-community/avalanche
- PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf