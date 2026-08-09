# 3.4 Push vs Pull

## 1. Motivación: el problema arquitectónico

Todo pipeline de métricas debe responder una pregunta antes de recolectar una sola muestra: **¿quién inicia la transferencia de datos — el proceso monitoreado, o el sistema de monitoreo?** Esta única decisión se propaga a tu modelo de service discovery, tus reglas de firewall, tu semántica de detección de fallas, y tu capacidad de razonar sobre "¿este target está realmente vivo?".

Prometheus toma una decisión con opinión: es un sistema **basado en pull** (basado en scrape). El servidor de Prometheus emite periódicamente un `GET /metrics` HTTP a cada target que ha descubierto, parsea el formato de exposición de texto, y agrega las muestras a su TSDB. El target es *pasivo* — mantiene un registro de métricas en memoria y las renderiza bajo demanda. No tiene conocimiento de Prometheus, ninguna dirección de backend configurada, y ninguna responsabilidad sobre la entrega.

Esto invierte el modelo de los sistemas basados en push (StatsD, Graphite, el line protocol de InfluxDB, la mayoría de los agentes APM), donde la aplicación transmite activamente métricas a un collector, usualmente sobre UDP o una conexión TCP persistente.

El problema de producción que aborda este tema: **pull es correcto para la gran mayoría de los servicios de larga duración, pero se rompe para una clase específica de workload — jobs efímeros y batch a nivel de servicio — que terminan antes de que Prometheus pueda hacerles scrape.** El arreglo ingenuo ("simplemente dejá que el job haga push") es una trampa que corrompe silenciosamente la semántica de liveness del target, crea un único punto de falla, y produce time series zombies que nunca mueren. La respuesta del ecosistema de Prometheus es un puente de push angosto y deliberadamente limitado (el **Pushgateway**) más una alternativa local a la máquina (el **textfile collector de node_exporter**). Saber *cuándo cada uno es apropiado* — y, más a menudo, cuándo ninguno lo es — es la verdadera competencia que este tema evalúa.

### Por qué Prometheus hace pull

La FAQ upstream es explícita en que esta es una preferencia leve, no una posición religiosa, pero las ventajas operativas son concretas:

- **El liveness del target es una señal de primera clase.** Si un scrape falla, Prometheus registra la serie sintética `up` como `0` para ese target. Con push, un proceso silencioso y un proceso muerto son indistinguibles — ambos simplemente dejan de enviar.
- **El sistema de monitoreo controla la carga.** Prometheus decide el `scrape_interval`. Un target que se comporta mal no puede inundar la TSDB, porque nunca inicia nada.
- **Los targets no necesitan ninguna configuración de backend.** Sin endpoint de monitoreo, sin credenciales, sin lógica de retry/buffering embebida en cada aplicación.
- **La redundancia horizontal es gratis.** Dos servidores de Prometheus (prod + staging, o un par HA) pueden hacer scrape del mismo target de forma independiente. En un modelo push hay que informarle al target sobre cada consumidor.
- **El debugging manual es trivial.** `curl http://target:port/metrics` reproduce exactamente lo que ve el servidor. Podés inspeccionar un target desde tu laptop.

### Dónde pull falla genuinamente

- **Jobs efímeros / batch / cron.** Un job que corre durante 8 segundos cada noche casi nunca coincidirá con un scrape. Sus métricas (registros procesados, duración, estado de salida) deben sobrevivir al proceso.
- **Invocaciones serverless / FaaS efímeras** sin endpoint estable al que hacer scrape.
- **Topologías de red solo de egress** donde el target puede alcanzar hacia afuera pero Prometheus no puede alcanzar hacia adentro (algunas situaciones de NAT/firewall — aunque esto usualmente se resuelve mejor con un proxy o un agente, no con push).

---

## 2. Comparación técnica y trade-offs

### 2.1 Pull vs Push — modelo fundamental

| Dimensión | Pull (scrape de Prometheus) | Push (Pushgateway / StatsD / OTLP) |
|---|---|---|
| Quién inicia | Servidor de monitoreo | Proceso monitoreado |
| Liveness del target (`up`) | Directamente observable por target | No observable; el servidor solo ve el collector |
| Control de carga | Del lado del servidor (`scrape_interval`) | Del lado del cliente; puede inundar el sink |
| Service discovery | Nativo (K8s, Consul, EC2, files…) | El cliente debe conocer la dirección del sink |
| Dirección del firewall | Servidor → target (ingress al target) | Target → sink (egress desde el target) |
| Jobs efímeros | Pobre — el job muere antes del scrape | Bueno — la razón por la que existen los puentes de push |
| Consumidores redundantes | Trivial (N servidores hacen scrape del mismo target) | El cliente debe distribuir a N sinks |
| Inspección manual | `curl /metrics` sobre el target | Inspeccionar el intermediario, no la fuente |
| Manejo de series stale | Automático (target desaparecido ⇒ `up=0`, las series quedan stale) | Manual — el Pushgateway **nunca olvida** |

### 2.2 Matriz de decisión — qué herramienta para qué workload

| Workload | Mecanismo recomendado | Por qué |
|---|---|---|
| Servicio de larga duración (API, DB, sidecar) | **Pull** — exponer `/metrics`, hacerle scrape | Modelo nativo; conservar la semántica de `up` |
| Job batch a nivel de máquina (un cron en *este* host) | **textfile collector de node_exporter** | La métrica está atada a una máquina a la que ya se le hace scrape |
| Job batch a nivel de servicio (un ETL nocturno, no atado a ningún host) | **Pushgateway** | El único caso de uso del Pushgateway oficialmente respaldado |
| Serverless / FaaS con un emisor | **push OTLP hacia Prometheus** (receiver nativo) o Pushgateway | Sin endpoint estable al que hacer scrape |
| Almacenamiento a largo plazo / vista global | **`remote_write`** (Prometheus *hace push* a Mimir/Thanos/Cortex/VictoriaMetrics) | Push a nivel de storage; ortogonal al scraping |

### 2.3 El Pushgateway NO es un interruptor de "hacer que Prometheus sea basado en push"

Este es el error conceptual más evaluado. Según la documentación oficial, el Pushgateway es apropiado **solo** para capturar el resultado de un job batch a *nivel de servicio*. Usarlo como punto de ingesta general para métricas de aplicación derrota el diseño:

| Consecuencia del mal uso | Modo de falla |
|---|---|
| `up` refleja el **Pushgateway**, no tu job | Perdés por completo la detección de liveness por job |
| El Pushgateway **nunca expira** las series pusheadas | Un job retirado deja métricas stale para siempre → dashboards/alertas falsos |
| Instancia única = SPOF y cuello de botella | Todas las métricas batch se canalizan a través de un proceso |
| Los counters parecen resetearse | Un grupo reemplazado puede hacer que los counters parezcan decrecer |
| El timestamp es el tiempo del **scrape**, no del push | Usá el `push_time_seconds` inyectado, nunca el timestamp de la muestra, para razonar sobre la frescura |

### 2.4 Métodos HTTP del Pushgateway

| Método | Path | Semántica |
|---|---|---|
| `PUT` | `/metrics/job/<job>{/<label>/<value>}` | Reemplaza **todas** las métricas en esta grouping key con el body |
| `POST` | `/metrics/job/<job>{/<label>/<value>}` | Reemplaza solo las métricas **con el mismo nombre** en este grupo; deja las otras |
| `DELETE` | `/metrics/job/<job>{/<label>/<value>}` | Elimina la grouping key entera |

La **grouping key** es `job` más cada par `<label>/<value>` en el path de la URL (convencionalmente al menos `instance`). Dos pushes con la misma grouping key se sobrescriben mutuamente; keys distintas coexisten.

### 2.5 Batch a nivel de máquina vs a nivel de servicio — textfile collector vs Pushgateway

| | textfile collector de node_exporter | Pushgateway |
|---|---|---|
| Alcance de la métrica | Atado a un host específico | Independiente de cualquier host |
| Entrega | El job escribe un archivo `*.prom` local | El job hace push HTTP sobre la red |
| Liveness | Hereda el `up` del host | Pierde el `up` por job |
| Staleness | Sigue el scrape del node; sobrescribir el archivo | Delete manual o alertar sobre `push_time_seconds` |
| Dominio de falla | Disco local | Red + intermediario compartido |
| Usar cuando | Script de backup, rotación de logs, renovación de cert en una máquina | ETL a nivel de cluster, resultado de pipeline de CI |

---

## 3. Manifiestos completos e infraestructura

### 3.1 Pushgateway en Kubernetes (Deployment + Service + PVC)

La persistencia (`--persistence.file`) es lo que permite que los grupos pusheados sobrevivan a un reinicio del Pushgateway; sin ella, un reschedule del pod descarta silenciosamente cada grupo hasta que cada job vuelve a hacer push.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pushgateway-data
  namespace: monitoring
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pushgateway
  namespace: monitoring
  labels:
    app.kubernetes.io/name: pushgateway
spec:
  replicas: 1                       # keep at 1: multiple replicas fragment grouping keys
  strategy:
    type: Recreate                  # RWO volume cannot be mounted by two pods at once
  selector:
    matchLabels:
      app.kubernetes.io/name: pushgateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pushgateway
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534            # nobody
        fsGroup: 65534
      containers:
        - name: pushgateway
          image: prom/pushgateway:v1.9.0
          args:
            - --persistence.file=/data/pushgateway.data
            - --persistence.interval=5m
            - --web.enable-admin-api          # enables PUT /api/v1/admin/wipe
            - --log.level=info
          ports:
            - name: http
              containerPort: 9091
          volumeMounts:
            - name: storage
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: http
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /-/ready
              port: http
      volumes:
        - name: storage
          persistentVolumeClaim:
            claimName: pushgateway-data
---
apiVersion: v1
kind: Service
metadata:
  name: pushgateway
  namespace: monitoring
  labels:
    app.kubernetes.io/name: pushgateway
spec:
  selector:
    app.kubernetes.io/name: pushgateway
  ports:
    - name: http
      port: 9091
      targetPort: http
```

### 3.2 Configuración de scrape de Prometheus — el requisito de `honor_labels`

`honor_labels: true` es obligatorio para un job de Pushgateway. Sin él, Prometheus sobrescribe el `job`/`instance` pusheado con los labels del target del *propio Pushgateway* y renombra los originales a `exported_job`/`exported_instance` — atribuyendo silenciosamente cada job batch al gateway.

```yaml
scrape_configs:
  - job_name: pushgateway
    honor_labels: true                 # keep job/instance from the pushed metrics
    scrape_interval: 15s
    static_configs:
      - targets: ["pushgateway.monitoring.svc:9091"]
    # In-cluster equivalent via Kubernetes SD + relabeling:
  - job_name: pushgateway-sd
    honor_labels: true
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [monitoring]
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
        action: keep
        regex: pushgateway
```

### 3.3 textfile collector de node_exporter — la alternativa a nivel de máquina

Habilitá el collector en node_exporter y escribí las métricas **atómicamente** para que el collector nunca lea un archivo a medio escribir:

```yaml
# node_exporter DaemonSet arg (excerpt)
args:
  - --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

```bash
#!/usr/bin/env bash
# /usr/local/bin/report-backup.sh — run from cron on the host
set -euo pipefail

TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
name=backup

# Do the work, capture outcome
start=$(date +%s)
if /usr/local/bin/do-backup.sh; then rc=0; else rc=1; fi
end=$(date +%s)

# Render to a temp file on the SAME filesystem, then atomically rename.
tmp="$(mktemp -p "$TEXTFILE_DIR" .${name}.XXXXXX)"
cat > "$tmp" <<EOF
# HELP node_backup_last_run_timestamp_seconds Unix time of the last backup attempt.
# TYPE node_backup_last_run_timestamp_seconds gauge
node_backup_last_run_timestamp_seconds ${end}
# HELP node_backup_success Whether the last backup succeeded (1) or failed (0).
# TYPE node_backup_success gauge
node_backup_success $([ "$rc" -eq 0 ] && echo 1 || echo 0)
# HELP node_backup_duration_seconds Duration of the last backup in seconds.
# TYPE node_backup_duration_seconds gauge
node_backup_duration_seconds $((end - start))
EOF
mv "$tmp" "$TEXTFILE_DIR/${name}.prom"   # atomic on the same FS
```

### 3.4 Job batch instrumentado que hace push al gateway (cliente Python)

```python
#!/usr/bin/env python3
"""Nightly ETL that reports its outcome to the Pushgateway on completion."""
from prometheus_client import CollectorRegistry, Counter, Gauge, push_to_gateway

PUSHGATEWAY = "pushgateway.monitoring.svc:9091"
JOB = "nightly_etl"
INSTANCE = "etl-runner-01"

registry = CollectorRegistry()  # isolated registry: push exactly these series
records = Counter("etl_records_processed_total",
                  "Records processed by the ETL run", registry=registry)
duration = Gauge("etl_duration_seconds",
                 "Wall-clock duration of the ETL run", registry=registry)
last_success = Gauge("etl_last_success_timestamp_seconds",
                     "Unix time of the last successful ETL run", registry=registry)

def main() -> None:
    with duration.time():
        n = run_etl()          # your work
        records.inc(n)
    last_success.set_to_current_time()

if __name__ == "__main__":
    try:
        main()
    finally:
        # PUT: replace the ENTIRE grouping key {job,instance} with this registry.
        push_to_gateway(
            PUSHGATEWAY, job=JOB,
            grouping_key={"instance": INSTANCE},
            registry=registry,
        )
```

Mapeo función del cliente ↔ método HTTP:

| Función del cliente | Verbo HTTP | Efecto sobre la grouping key |
|---|---|---|
| `push_to_gateway(...)` | `PUT` | Reemplaza todas las métricas en el grupo |
| `pushadd_to_gateway(...)` | `POST` | Agrega/reemplaza solo las métricas con el mismo nombre |
| `delete_from_gateway(...)` | `DELETE` | Elimina el grupo por completo |

---

## 4. Comandos CLI y salida de terminal real

### 4.1 Hacer push de una métrica con `curl`

```console
$ echo "example_metric 42" | curl -i --data-binary @- \
    http://localhost:9091/metrics/job/demo/instance/host-1
HTTP/1.1 200 OK
Date: Sat, 08 Aug 2026 09:14:22 GMT
Content-Length: 0
```

Hacer push de un grupo completo vía heredoc (nótese el salto de línea final requerido en el body):

```console
$ cat <<'EOF' | curl -s --data-binary @- \
    http://localhost:9091/metrics/job/nightly_etl/instance/etl-runner-01
# TYPE etl_records_processed_total counter
etl_records_processed_total 128443
# TYPE etl_duration_seconds gauge
etl_duration_seconds 42.7
# TYPE etl_last_success_timestamp_seconds gauge
etl_last_success_timestamp_seconds 1754643262
EOF
```

### 4.2 Inspeccionar lo que el Pushgateway expone ahora

El gateway inyecta `push_time_seconds` y `push_failure_time_seconds` por grupo — estas son tus señales de frescura, no los timestamps de las muestras.

```console
$ curl -s http://localhost:9091/metrics | grep -E 'etl_|push_time' | grep nightly_etl
etl_duration_seconds{instance="etl-runner-01",job="nightly_etl"} 42.7
etl_last_success_timestamp_seconds{instance="etl-runner-01",job="nightly_etl"} 1.754643262e+09
etl_records_processed_total{instance="etl-runner-01",job="nightly_etl"} 128443
push_failure_time_seconds{instance="etl-runner-01",job="nightly_etl"} 0
push_time_seconds{instance="etl-runner-01",job="nightly_etl"} 1.7546432627e+09
```

### 4.3 Diferencia POST vs PUT en la práctica

```console
# POST adds a new metric to the group without touching the others:
$ echo "etl_rows_rejected_total 12" | curl -s --data-binary @- -X POST \
    http://localhost:9091/metrics/job/nightly_etl/instance/etl-runner-01

$ curl -s http://localhost:9091/metrics | grep 'job="nightly_etl"' | wc -l
5      # 4 metrics + push_time; the earlier PUT payload survived

# A PUT with only one metric would have WIPED the other three.
```

### 4.4 Eliminar un grupo stale y borrar todo

```console
$ curl -s -X DELETE http://localhost:9091/metrics/job/nightly_etl/instance/etl-runner-01
$ curl -s http://localhost:9091/metrics | grep -c nightly_etl
0

# Wipe ALL groups (requires --web.enable-admin-api):
$ curl -s -X PUT http://localhost:9091/api/v1/admin/wipe
```

### 4.5 Confirmar que Prometheus lo ve correctamente (labels preservados)

```console
$ curl -sG http://prometheus:9090/api/v1/query \
    --data-urlencode 'query=etl_records_processed_total' | jq '.data.result[0].metric'
{
  "__name__": "etl_records_processed_total",
  "instance": "etl-runner-01",
  "job": "nightly_etl"
}
```

Si en cambio ves `"job": "pushgateway"` y `"exported_job": "nightly_etl"`, falta `honor_labels: true`.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 ¿Está sano el puente?

```promql
up{job="pushgateway"}          # 1 = Prometheus can scrape the gateway
```
Recordá: esto es el liveness del **gateway**, nunca el del job batch. Para la frescura del job debés usar el timestamp de push inyectado.

### 5.2 Detectar jobs batch stale / muertos (la brecha #1 de push)

Como el Pushgateway nunca olvida, un job que deja de correr deja sus últimos valores congelados para siempre. Alertá sobre la staleness explícitamente:

```yaml
groups:
  - name: batch-jobs
    rules:
      - alert: BatchJobNotRunning
        # No successful push in the last 25 hours for a daily job
        expr: time() - push_time_seconds{job="nightly_etl"} > 25 * 3600
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "nightly_etl has not pushed in over 25h"

      - alert: BatchJobFailing
        expr: push_failure_time_seconds{job="nightly_etl"} > push_time_seconds{job="nightly_etl"}
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "nightly_etl last push was a failure"

      - alert: BatchJobFailedRun
        # Requires the job to expose an explicit success gauge
        expr: etl_last_success_timestamp_seconds < time() - 25 * 3600
        for: 10m
        labels: { severity: critical }
```

### 5.3 Catálogo de fallas

| Síntoma | Causa raíz | Arreglo |
|---|---|---|
| Las métricas nunca aparecen en Prometheus | No se le hace scrape al Pushgateway | Verificar `up{job="pushgateway"}`, estado del target, network policy hacia :9091 |
| Todo etiquetado como `job="pushgateway"` / presente `exported_job` | Falta `honor_labels: true` | Agregarlo al job de scrape |
| Las métricas de un job retirado persisten para siempre | El Pushgateway nunca expira los grupos | Hacer `DELETE` del grupo al teardown; alertar sobre `push_time_seconds` |
| Un counter parece resetearse / decrecer | Un `PUT`/`POST` reemplazó el grupo con valores más bajos | Usar counters monotónicos; preferir `push_to_gateway` (PUT completo) con un registry estable |
| Todas las métricas batch desaparecieron tras un reinicio | Sin persistencia configurada | `--persistence.file` + un PVC |
| Dos valores de `instance` para un mismo job lógico | Múltiples runners comparten `job` pero no `instance` | Estandarizar la grouping key (`job`+`instance`) |
| `push_time` parece "ahora" pero los datos son viejos | Leíste el timestamp de la muestra (= tiempo del scrape), no el tiempo del push | Razonar sobre la frescura solo vía `push_time_seconds` |
| Métricas batch atadas a un host al que ya podés hacer scrape | Herramienta equivocada | Usar el **textfile collector** de node_exporter, no el Pushgateway |

### 5.4 Smoke test de extremo a extremo

```console
$ curl -s http://localhost:9091/-/ready && echo READY
READY
$ echo 'smoke_test 1' | curl -s --data-binary @- \
    http://localhost:9091/metrics/job/smoke/instance/ci
$ sleep 20   # allow one scrape_interval
$ curl -sG http://prometheus:9090/api/v1/query \
    --data-urlencode 'query=smoke_test{job="smoke"}' | jq '.data.result[0].value[1]'
"1"
$ curl -s -X DELETE http://localhost:9091/metrics/job/smoke/instance/ci   # clean up
```

### 5.5 Nota sobre las rutas de push nativas (contexto)

Existen dos flujos de "push" legítimos en el Prometheus moderno y no deben confundirse con el Pushgateway:

- **`remote_write`** — Prometheus mismo *hace push* de los datos scrapeados a almacenamiento de largo plazo (Thanos Receive, Mimir, Cortex, VictoriaMetrics). Esto es una cuestión de storage, aguas abajo del scraping.
- **Ingesta OTLP nativa** — el Prometheus reciente puede recibir métricas OpenTelemetry vía `/api/v1/otlp/v1/metrics` (habilitado con `--web.enable-otlp-receiver`, históricamente el feature flag `otlp-write-receiver`). Este es un verdadero ingress de push para emisores instrumentados con OTel y serverless, y es cada vez más la alternativa preferida al Pushgateway para esos casos.

---

## 6. Referencias

- Prometheus FAQ — *Why do you pull rather than push?*: https://prometheus.io/docs/introduction/faq/#why-do-you-pull-rather-than-push
- Pushing metrics — *When to use the Pushgateway*: https://prometheus.io/docs/practices/pushing/
- Pushgateway project (README, API, admin endpoints): https://github.com/prometheus/pushgateway
- Prometheus configuration — `scrape_config`, `honor_labels`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
- node_exporter textfile collector: https://github.com/prometheus/node_exporter#textfile-collector
- Prometheus client_python — Pushgateway helpers (`push_to_gateway`, `pushadd_to_gateway`, `delete_from_gateway`): https://prometheus.github.io/client_python/exporting/pushgateway/
- Exposition formats (text format the gateway/collector parse): https://prometheus.io/docs/instrumenting/exposition_formats/
- Remote write specification: https://prometheus.io/docs/specs/prw/remote_write_spec/
- OpenTelemetry ingestion into Prometheus: https://prometheus.io/docs/guides/opentelemetry/
- PCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf