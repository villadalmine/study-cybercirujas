# Métricas de timestamp

**Certificación:** Prometheus Certified Associate (PCA) · **Dominio:** PromQL · **Tema 1.7** · **Peso en el examen: 4**

---

## 1. Motivación: los dos relojes y por qué una métrica puede *ser* un timestamp

Cada muestra que Prometheus almacena es una tripleta: `(series identity, value float64, sample timestamp ms)`. El **sample timestamp** responde *"¿cuándo observó esto Prometheus?"*. Lo asigna el bucle de scrape (o se copia del formato de exposición cuando `honor_timestamps` está activo) y es lo que la TSDB indexa en el eje temporal.

Una **métrica de timestamp** es algo completamente distinto que resulta parecerse: es un `gauge` común cuyo *valor* es un tiempo Unix epoch (segundos desde `1970-01-01T00:00:00Z`). La serie se scrapea cada 15 s como cualquier otro gauge, pero el número que lleva no es un rate ni un conteo — codifica *cuándo ocurrió un evento*:

| Métrica | Exporter / fuente | El valor significa… |
|---|---|---|
| `process_start_time_seconds` | cualquier client library | cuándo arrancó este proceso |
| `node_boot_time_seconds` | node_exporter | cuándo arrancó el kernel |
| `node_time_seconds` | node_exporter | el reloj de pared *propio* del nodo en el scrape |
| `probe_ssl_earliest_cert_expiry` | blackbox_exporter | cuándo expira primero la cadena TLS |
| `push_time_seconds` | Pushgateway (agregada automáticamente) | cuándo llegó el último push de este grupo |
| `kube_pod_start_time` | kube-state-metrics | cuándo se programó/inició el Pod |
| `prometheus_config_last_reload_success_timestamp_seconds` | el propio Prometheus | última recarga de config exitosa |
| `<job>_last_success_timestamp_seconds` | tus batch jobs → Pushgateway | última ejecución exitosa |

El problema de producción que resuelve este tema es **la frescura y los deadlines bajo un modelo pull**. Prometheus hace scrape; no recibe eventos. Por eso las preguntas que desvelan a un SRE — *"¿corrió el backup nocturno en las últimas 26 h?"*, *"¿expira algún certificado dentro de 7 días?"*, *"¿acaba de reiniciarse este proceso?"*, *"¿está el reloj de este nodo alejándose del de Prometheus?"* — no pueden responderse contando ni con rate. Se responden con aritmética entre **`time()` (el reloj de evaluación)** y una **métrica de timestamp (el reloj del evento)**.

El único idiom canónico es la resta:

```promql
# Age of a process, in seconds
time() - process_start_time_seconds

# Time remaining before a certificate expires, in seconds
probe_ssl_earliest_cert_expiry - time()
```

`time()` devuelve el **timestamp de evaluación** de la consulta como epoch en segundos — *no* `now()` en el servidor, sino el instante para el que se está evaluando la muestra (esto importa en range queries y backfills, donde cada step evalúa con su propio `time()`). Por eso una expresión `time() - X` graficada sobre un range produce un diente de sierra limpio que se reinicia en cada restart: cada step resta un `time()` *distinto*.

---

## 2. La familia de funciones y sus trade-offs

Tres mecanismos distintos se confunden habitualmente. Mantenelos separados:

| Función | Devuelve | Argumento | Uso típico |
|---|---|---|---|
| `time()` | tiempo de evaluación (epoch s) | ninguno | el lado "now" de todo cálculo de deadline/edad |
| `timestamp(v)` | el timestamp de la **muestra** de cada elemento de `v` (epoch s) | instant-vector | scrape lag, staleness, clock-skew, "cuándo se observó por última vez" |
| `<gauge value>` | el tiempo del **evento** codificado (epoch s) | — | el lado "then"; es solo dato |

Y los helpers de calendario, todos los cuales **interpretan su entrada como un timestamp Unix y devuelven UTC**, con `vector(time())` por defecto cuando se los llama sin argumento:

| Función | Rango | Notas |
|---|---|---|
| `year(v=vector(time()))` | p. ej. 2026 | UTC |
| `month(v)` | 1–12 | UTC |
| `day_of_month(v)` | 1–31 | UTC |
| `day_of_week(v)` | 0–6 | **0 = domingo**, 6 = sábado |
| `day_of_year(v)` | 1–366 | UTC |
| `days_in_month(v)` | 28–31 | consciente de años bisiestos |
| `hour(v)` | 0–23 | UTC |
| `minute(v)` | 0–59 | UTC |

> **Trampa #1 — todo es UTC.** `hour()` nunca respeta una zona horaria local. "Horario laboral 09:00–18:00 Buenos Aires (UTC−3)" debe escribirse como `hour() >= 12 and hour() < 21`. No hay argumento `tz`.

> **Trampa #2 — `timestamp()` es el reloj de la muestra, no el valor.** `timestamp(node_boot_time_seconds)` devuelve *cuándo lo scrapeó Prometheus*, no el tiempo de arranque. Para leer el tiempo de arranque usás la serie sin más. Confundir esto es el error de PromQL más común en este dominio.

### `time() - X` vs `timestamp()` — cuándo usar cada uno

| Objetivo | Expresión correcta | Por qué |
|---|---|---|
| Uptime de un proceso | `time() - process_start_time_seconds` | el valor es el tiempo del evento |
| Segundos hasta la expiración del cert | `probe_ssl_earliest_cert_expiry - time()` | el valor es un tiempo de evento futuro |
| Staleness de una métrica *push* / batch | `time() - push_time_seconds` | el valor es el tiempo del evento de push |
| **Scrape lag** — ¿qué antigüedad tiene la muestra más fresca? | `time() - timestamp(up)` | usa el reloj de la *muestra* |
| **Clock skew** nodo ↔ Prometheus | `node_time_seconds - timestamp(node_time_seconds)` | value=reloj del nodo, timestamp=reloj de Prom |
| Suprimir alertas los fines de semana | `... unless on() (day_of_week() == 0 or day_of_week() == 6)` | helper de calendario |

El idiom de clock-skew merece énfasis porque es el único lugar donde *deliberadamente* combinás una métrica de timestamp con `timestamp()`:

```promql
# Positive => node clock ahead of Prometheus; includes scrape+network latency (~ tens of ms)
node_time_seconds - timestamp(node_time_seconds)
```

Cualquier cosa más allá de ~1–2 s acá es drift de reloj real, no latencia — corroborá con `node_timex_offset_seconds` (la propia estimación de offset NTP del kernel).

### Detectar un restart vs. medir la edad

`time() - process_start_time_seconds` da la edad; para *alertar sobre un restart reciente* lo umbralizás bajo **y** te protegés contra gaps:

```promql
time() - process_start_time_seconds < 60
```

Preferí `changes(process_start_time_seconds[1h]) > 0` cuando te importa *"si se reinició en algún momento de la ventana"* en lugar de *"si es joven ahora mismo"* — esto último tiene un punto ciego de lookback de 5 minutos después de que el proceso reaparece.

---

## 3. Manifiestos e infraestructura (completo, sin abreviar)

### 3.1 Config de scrape — timestamps en el formato de exposición

El formato de exposición de Prometheus permite un **timestamp opcional en milisegundos** como tercer campo en cada línea de muestra:

```
# HELP http_requests_total Total HTTP requests.
# TYPE http_requests_total counter
http_requests_total{method="post",code="200"} 1027 1754640123456
# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE process_start_time_seconds gauge
process_start_time_seconds 1.7546400e+09
```

`honor_timestamps` controla si Prometheus adopta ese timestamp embebido (`1754640123456`) como el timestamp de la muestra, o lo sobrescribe con su propio tiempo de scrape. Este es el switch que conecta los "timestamps" con el pipeline de scrape:

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # Ordinary app scrape — trust our own scrape clock (recommended default).
  - job_name: app
    honor_timestamps: true        # default; use exporter-provided timestamps if present
    static_configs:
      - targets: ['app:8080']

  # Federation / Pushgateway — DO NOT overwrite the source timestamps.
  - job_name: pushgateway
    honor_timestamps: true
    honor_labels: true            # keep instance/job the pushing jobs set
    static_configs:
      - targets: ['pushgateway:9091']

  # A flaky exporter that emits bad/backdated timestamps — force our clock.
  - job_name: legacy-exporter
    honor_timestamps: false       # ignore embedded timestamps; stamp at scrape time
    static_configs:
      - targets: ['legacy:9200']

  # Blackbox TLS probes — source of probe_ssl_earliest_cert_expiry.
  - job_name: blackbox-tls
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://api.example.com
          - https://dashboard.example.com
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

> **Por qué `honor_timestamps: false` en el job legacy:** las muestras cuyo timestamp embebido es más antiguo que `now − storage.tsdb.out_of_order_time_window` (0 por defecto) se descartan como *out-of-order*, y las muestras demasiado en el futuro se rechazan como *too far in the future*. Un exporter mal configurado que emite timestamps viejos o desviados perderá datos silenciosamente a menos que sobrescribas su reloj.

### 3.2 Instrumentar un batch job con una métrica de timestamp (Pushgateway)

Los batch jobs son invisibles para un modelo pull entre ejecuciones. El patrón es: pushear un gauge `*_last_success_timestamp_seconds` a Pushgateway al tener éxito, y luego alertar sobre su staleness.

```bash
#!/usr/bin/env bash
# /opt/backup/run-backup.sh  — nightly database backup
set -euo pipefail

JOB="db_backup"
PGW="http://pushgateway:9091"

start="$(date +%s)"
if /opt/backup/pg_dump_to_s3.sh; then
  end="$(date +%s)"
  cat <<EOF | curl -sf --data-binary @- "${PGW}/metrics/job/${JOB}/instance/${HOSTNAME}"
# TYPE db_backup_last_success_timestamp_seconds gauge
# HELP db_backup_last_success_timestamp_seconds Unix time of the last successful backup.
db_backup_last_success_timestamp_seconds ${end}
# TYPE db_backup_duration_seconds gauge
db_backup_duration_seconds $((end - start))
EOF
else
  # Do NOT push a success timestamp on failure — let staleness fire the alert.
  exit 1
fi
```

Pushgateway decora automáticamente cada grupo con `push_time_seconds`, así que obtenés frescura incluso para jobs que olvidan emitir su propio timestamp.

### 3.3 Recording rules — pre-computar edades una sola vez

Las expresiones de edad son baratas, pero si una docena de dashboards y alertas restan `time()` de la misma métrica, elevalo a una recording rule para que los paneles queden legibles y la evaluación sea consistente:

```yaml
# /etc/prometheus/rules/timestamp-recording.yml
groups:
  - name: timestamp.recording
    interval: 30s
    rules:
      - record: instance:process_uptime:seconds
        expr: time() - process_start_time_seconds

      - record: instance:cert_time_to_expiry:seconds
        expr: probe_ssl_earliest_cert_expiry - time()

      - record: job:batch_last_success_age:seconds
        expr: time() - db_backup_last_success_timestamp_seconds

      - record: instance:clock_skew:seconds
        expr: node_time_seconds - timestamp(node_time_seconds)
```

### 3.4 Alerting rules — deadlines, frescura, skew, restarts

```yaml
# /etc/prometheus/rules/timestamp-alerts.yml
groups:
  - name: timestamp.alerts
    rules:
      # --- Certificate deadline: warn at 21 days, page at 7 ---
      - alert: CertificateExpiringSoon
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 21
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "TLS cert on {{ $labels.instance }} expires in {{ $value | humanizeDuration }}"

      - alert: CertificateExpiringCritical
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 7
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "TLS cert on {{ $labels.instance }} expires in under 7 days ({{ $value | humanize }} days)"

      # --- Batch job freshness: nightly job must succeed at least every 26h ---
      - alert: BackupStale
        expr: (time() - db_backup_last_success_timestamp_seconds) > 26 * 3600
        # absent() catches the case where the metric never appeared at all
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "db_backup has not succeeded in {{ $value | humanizeDuration }}"

      - alert: BackupMetricMissing
        expr: absent(db_backup_last_success_timestamp_seconds)
        for: 30m
        labels:
          severity: critical
        annotations:
          summary: "No db_backup_last_success_timestamp_seconds series exists — job never reported"

      # --- Fresh restart detection ---
      - alert: ProcessFlapping
        expr: changes(process_start_time_seconds[15m]) > 2
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.job }}/{{ $labels.instance }} restarted {{ $value }} times in 15m"

      # --- Clock skew, business-hours aware suppression ---
      - alert: NodeClockSkew
        expr: |
          abs(node_time_seconds - timestamp(node_time_seconds)) > 0.5
          and abs(node_timex_offset_seconds) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Clock on {{ $labels.instance }} skewed by {{ $value | humanizeDuration }}"

      # --- Scrape staleness independent of the `up` alert ---
      - alert: StaleTarget
        expr: (time() - timestamp(up)) > 300
        labels:
          severity: warning
        annotations:
          summary: "Freshest sample from {{ $labels.instance }} is {{ $value | humanizeDuration }} old"
```

---

## 4. CLI y salida real de terminal

Inspeccioná la exposición cruda, luego confirmá la aritmética de timestamps con `promtool`.

```console
$ curl -s http://app:8080/metrics | grep -E 'process_start_time_seconds'
# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE process_start_time_seconds gauge
process_start_time_seconds 1.754640000e+09
```

```console
$ date +%s
1754683215

$ promtool query instant http://localhost:9090 'time() - process_start_time_seconds'
process_start_time_seconds{instance="app:8080", job="app"} => 43215 @[1754683215]
```

43 215 s ≈ 12 h de uptime — consistente con `1754683215 − 1754640000`.

Cuenta regresiva del certificado, en días:

```console
$ promtool query instant http://localhost:9090 \
    '(probe_ssl_earliest_cert_expiry - time()) / 86400'
{instance="https://api.example.com", job="blackbox-tls"} => 12.83 @[1754683230]
{instance="https://dashboard.example.com", job="blackbox-tls"} => 64.11 @[1754683230]
```

`timestamp()` vs el valor — demostrando que difieren:

```console
$ promtool query instant http://localhost:9090 'node_time_seconds'
node_time_seconds{instance="node1:9100"} => 1754683231.44 @[1754683230]

$ promtool query instant http://localhost:9090 'timestamp(node_time_seconds)'
node_time_seconds{instance="node1:9100"} => 1754683230 @[1754683230]

$ promtool query instant http://localhost:9090 \
    'node_time_seconds - timestamp(node_time_seconds)'
{instance="node1:9100"} => 1.44 @[1754683230]        # ~1.44s skew — investigate NTP
```

Los helpers de calendario son UTC — verificá antes de escribir lógica de ventanas de tiempo:

```console
$ promtool query instant http://localhost:9090 'hour()'
{} => 14 @[1754683230]

$ promtool query instant http://localhost:9090 'day_of_week()'
{} => 5 @[1754683230]        # 5 = Friday (0 = Sunday)
```

Staleness de batch job y el caso de serie faltante:

```console
$ promtool query instant http://localhost:9090 \
    'time() - db_backup_last_success_timestamp_seconds'
db_backup_last_success_timestamp_seconds{instance="db01", job="db_backup"} => 5122 @[1754683240]

$ promtool query instant http://localhost:9090 'absent(db_backup_last_success_timestamp_seconds{job="db_backup"})'
# (empty result) => series exists, so absent() returns nothing — good.
```

Validá los archivos de reglas antes del reload:

```console
$ promtool check rules /etc/prometheus/rules/timestamp-alerts.yml
Checking /etc/prometheus/rules/timestamp-alerts.yml
  SUCCESS: 7 rules found

$ curl -s -X POST http://localhost:9090/-/reload && echo reloaded
reloaded
```

---

## 5. Verificación y diagnóstico de fallas

**A. `time() - X` es negativo o absurdamente grande.**
O bien el exporter emite milisegundos en lugar de segundos (valor ≈ `1.75e12` en lugar de `1.75e9` → la edad es un número negativo enorme), o restaste en el orden equivocado. Verificá la magnitud:

```console
$ promtool query instant http://localhost:9090 'process_start_time_seconds'
process_start_time_seconds{...} => 1.754640000e+12 @[...]   # ← milliseconds! divide by 1000
```

Corregilo con `process_start_time_seconds / 1000` o arreglá la instrumentación. Un valor correcto de epoch en segundos en 2026 tiene 10 dígitos enteros (`1.75…e+09`).

**B. La alerta de staleness nunca se dispara cuando un job muere.**
`time() - X > threshold` requiere que la serie `X` todavía exista. Si el target desaparece por completo, la serie queda stale después del lookback (5 m) y la expresión no arroja *ningún resultado* — no una violación. Siempre emparejá una alerta de frescura con `absent()` (ver `BackupMetricMissing`). Este es el falso negativo más común de este tema.

**C. `timestamp()` devuelve el mismo número que `time()`.**
Esperado para una serie recién scrapeada: el timestamp de la muestra ≈ tiempo de evaluación. Un gap *grande* significa staleness (`time() - timestamp(up)` es tu medidor de staleness). Si `timestamp()` en un target vivo está minutos atrasado, sospechá de `honor_timestamps: true` en un exporter que envía timestamps con fecha anterior.

**D. Muestras faltantes silenciosamente después de habilitar los timestamps propios de un exporter.**
Revisá los errores de scrape del target de Prometheus y los contadores de rechazo de la TSDB:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=rate(prometheus_target_scrapes_sample_out_of_bounds_total[5m])' | jq '.data.result'
[
  { "metric": {"instance":"legacy:9200"}, "value": [1754683250, "3.2"] }
]
```

Un `..._out_of_bounds_total` o `..._sample_duplicate_timestamp_total` distinto de cero significa que los timestamps embebidos del exporter están viejos/duplicados. Poné `honor_timestamps: false` en ese job.

**E. La lógica de ventana de tiempo / horario laboral se comporta mal en el cambio de hora (DST) o al cruzar la medianoche.**
Recordá que todos los helpers son **UTC** y `day_of_week()` cuenta el domingo como 0. Una condición "días de semana 09–17 local" escrita contra horas locales estará equivocada por el offset de UTC. Convertí una vez, comentá el offset, y volvé a chequear con `promtool query instant '... hour()'` a una hora de pared conocida.

**F. Verificar el tiempo del evento contra el reloj de pared durante backfill/range queries.**
`time()` es por step, así que una recording rule `time() - X` backfilleada sobre el histórico es correcta en cada step; pero una consola *instant* solo muestra "now". Cuando audités un incidente pasado usá el modificador `@` para fijar la evaluación:

```console
$ promtool query instant http://localhost:9090 \
    'time() - process_start_time_seconds @ 1754600000'
{...} => 39871 @[1754683260]     # age as it was at epoch 1754600000
```

---

## 6. Referencias

- Prometheus — Funciones de consulta (`time`, `timestamp`, `hour`, `day_of_week`, `year`, …): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Fundamentos de consulta, modificador `@` y `offset`: https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — Configuración, `scrape_config` y `honor_timestamps`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — Formatos de exposición (timestamp opcional por muestra): https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Alerting rules y templating (`humanizeDuration`): https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Pushgateway — `push_time_seconds` y el patrón de batch-job: https://github.com/prometheus/pushgateway#about-timestamps
- node_exporter (`node_time_seconds`, `node_boot_time_seconds`, `node_timex_offset_seconds`): https://github.com/prometheus/node_exporter
- blackbox_exporter (`probe_ssl_earliest_cert_expiry`): https://github.com/prometheus/blackbox_exporter
- kube-state-metrics (`kube_pod_start_time`): https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf