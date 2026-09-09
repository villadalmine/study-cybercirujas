# gcp-cdl — Tema 6.2
# Operaciones modernas, confiabilidad y resiliencia en la nube
## Ejercicios guiados (prácticos + analíticos)

**Examen:** Google Cloud Digital Leader, versión del temario `2026-08-12`
**Sección:** 6 — *Successfully implementing and operating in the cloud* · **Objetivo 6.2** · **Peso en el examen: 5.0%**
**Fuente principal:** [Cloud Digital Leader Exam Guide (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

---

## Cómo usar este documento

El examen CDL evalúa *conceptos y compromisos de negocio*, no memoria muscular de `kubectl`. Pero los conceptos que nunca tocaron una consola real se evaporan bajo la presión del examen. Por eso estos ejercicios están construidos en dos capas:

| Capa | Qué hacés | Por qué |
|---|---|---|
| **Bloques prácticos** (Ej. 1, 3, 4) | Ejecutás comandos `gcloud` reales, leés telemetría real | Vuelve concretos los conceptos de SLI/SLO/observabilidad |
| **Bloques analíticos** (Ej. 2, 5, 6, 7, 8) | Calculás presupuestos, diseñás topologías, clasificás patrones | Esta es la forma en la que el examen pregunta realmente |

Cada bloque termina con un **Checkpoint**. Respondelo *antes* de seguir scrolleando. La clave de respuestas completa está en la sección plegable `<details>` del final.

### Requisitos previos

- Un proyecto de Google Cloud con facturación habilitada (el Free Tier alcanza para todo excepto el bloque opcional de Cloud SQL).
- CLI de `gcloud` ≥ 450.0.0 instalada y autenticada, **o** usar [Cloud Shell](https://cloud.google.com/shell) — trae todo preinstalado y su uso es gratuito.
- Roles sobre el proyecto: `roles/run.admin`, `roles/monitoring.editor`, `roles/logging.viewer`, `roles/iam.serviceAccountUser`.

### Costo y seguridad

Cloud Run escala a cero y el tráfico que se genera acá son unos pocos cientos de peticiones — se mantiene dentro del Free Tier. Los uptime checks de Cloud Monitoring y el primer tramo de métricas personalizadas son gratuitos. **El paso 4 del Ejercicio 6 aprovisiona una instancia de Cloud SQL y sí cuesta dinero real (centavos por hora); está marcado explícitamente como opcional y existe un camino solo en papel.** Ejecutá el desmantelamiento del Ejercicio 9 cuando termines.

> ⚠️ Las superficies `gcloud alpha` / `gcloud beta` cambian entre releases del SDK. Donde se usa un comando alpha, se da también el equivalente REST, y `gcloud <group> --help` es la autoridad para *tu* versión instalada. No memorices flags para el examen — memorizá el concepto.

---

## Ejercicio 1 — El vocabulario: SLI, SLO, SLA y de dónde salen los números

**Objetivo:** dejar de tratar la "confiabilidad" como un adjetivo. Al terminar este bloque vas a haber medido una, con tus propias manos, a partir de logs de peticiones en crudo.

### Pasos

**1.** Configurá tu proyecto de trabajo y una región por defecto. Todos los comandos posteriores los heredan.

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
export SERVICE="reliability-lab"

gcloud config set project "$PROJECT_ID"
gcloud config set run/region "$REGION"

echo "Project: $PROJECT_ID | Region: $REGION"
```

Salida esperada:

```
Updated property [core/project].
Updated property [run/region].
Project: my-cdl-project-4471 | Region: us-central1
```

**2.** Habilitá las cuatro APIs que este laboratorio necesita. Es idempotente — reejecutarlo es gratis y silencioso.

```bash
gcloud services enable \
  run.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  cloudresourcemanager.googleapis.com
```

Salida esperada (la primera ejecución puede tardar 30–60 s):

```
Operation "operations/acat.p2-482910334471-9c1f...-a4e0" finished successfully.
```

**3.** Desplegá un servicio stateless. Usamos el contenedor de ejemplo público de Google, así no hay código fuente que compilar ni nada que mantener.

```bash
gcloud run deploy "$SERVICE" \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region="$REGION" \
  --allow-unauthenticated \
  --min-instances=0 \
  --max-instances=3
```

Salida esperada (abreviada):

```
Deploying container to Cloud Run service [reliability-lab] in project [my-cdl-project-4471] region [us-central1]
✓ Deploying new service... Done.
  ✓ Creating Revision...
  ✓ Routing traffic...
  ✓ Setting IAM Policy...
Done.
Service [reliability-lab] revision [reliability-lab-00001-xyz] has been deployed
and is serving 100 percent of traffic.
Service URL: https://reliability-lab-abc123def-uc.a.run.app
```

**4.** Capturá la URL en una variable y confirmá que el servicio responde.

```bash
export URL="$(gcloud run services describe "$SERVICE" \
  --region="$REGION" --format='value(status.url)')"

curl -s -o /dev/null -w "status=%{http_code} latency=%{time_total}s\n" "$URL"
```

Salida esperada:

```
status=200 latency=0.412s
```

Esa primera petición es lenta porque pagó un **cold start**. Anotá el número — vuelve a aparecer en el Ejercicio 3.

**5.** Generá una mezcla de tráfico controlada: 180 peticiones buenas y 20 fallos deliberados (una ruta que el contenedor no sirve). Esto nos da una verdad de referencia conocida contra la cual contrastar nuestra medición.

```bash
for i in $(seq 1 180); do curl -s -o /dev/null "$URL/"; done
for i in $(seq 1 20);  do curl -s -o /dev/null "$URL/does-not-exist-$i"; done
echo "traffic generated: 180 expected-good, 20 expected-bad"
```

**6.** Esperá ~60 segundos a que se ingesten los logs, y después contá los resultados **desde los logs**, no desde tu bucle. Esta es la diferencia entre lo que *creés* que serviste y lo que *realmente* serviste.

```bash
sleep 60
gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\" AND httpRequest.status!=\"\"" \
  --freshness=15m --limit=1000 \
  --format='value(httpRequest.status)' | sort -n | uniq -c
```

Salida esperada (tus conteos exactos van a diferir un poco — los health probes y los reintentos también son tráfico real):

```
    181 200
     20 404
```

**7.** Calculá el SLI de disponibilidad a mano. La definición estándar *basada en peticiones* es:

$$\text{SLI}_{\text{disponibilidad}} = \frac{\text{eventos buenos}}{\text{eventos válidos}} \times 100$$

```bash
gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\"" \
  --freshness=15m --limit=1000 --format='value(httpRequest.status)' \
| awk 'NF{t++; if ($1<500) g++} END {printf "valid=%d good=%d SLI=%.3f%%\n", t, g, 100*g/t}'
```

Salida esperada:

```
valid=201 good=201 SLI=100.000%
```

**8.** Ahora reejecutá el mismo cálculo pero clasificando `4xx` como malo:

```bash
gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\"" \
  --freshness=15m --limit=1000 --format='value(httpRequest.status)' \
| awk 'NF{t++; if ($1<400) g++} END {printf "valid=%d good=%d SLI=%.3f%%\n", t, g, 100*g/t}'
```

Salida esperada:

```
valid=201 good=181 SLI=90.050%
```

**El mismo servicio. El mismo segundo. Los mismos logs. 100% o 90% según una línea de la especificación.** Eso es lo más importante de este ejercicio.

**9.** Registrá el compromiso del lado del proveedor para comparar. Abrí [https://cloud.google.com/terms/sla](https://cloud.google.com/terms/sla), buscá el SLA de **Cloud Run** y anotá: (a) el Monthly Uptime Percentage comprometido, (b) qué recibe el cliente cuando no se cumple, y (c) qué queda explícitamente *excluido* del cálculo.

### Checkpoint 1

- **Q1.1** — En los pasos 7 y 8 el sistema subyacente se comportó de forma idéntica, y sin embargo la confiabilidad medida se movió 10 puntos. ¿Qué artefacto cambió, y cuál es el nombre correcto del documento que lo fija?
- **Q1.2** — Definí SLI, SLO y SLA en una oración cada uno, e indicá cuál de los tres es el único con consecuencias legales y financieras.
- **Q1.3** — El SLA de tu servicio promete 99.9%. Tu equipo discute si fijar el SLO interno en 99.9%, 99.5% o 99.95%. ¿Cuál es el correcto y por qué? ¿Cuál es el modo de fallo específico de las respuestas equivocadas?
- **Q1.4** — Los 404 del paso 5 los causaron clientes pidiendo una ruta que nunca existió. Argumentá *ambos* lados: ¿deberían contar como "eventos malos" en un SLI de disponibilidad?
- **Q1.5** — La primera petición del paso 4 tardó 412 ms; las siguientes tardan ~30 ms. ¿Por qué un SLI de latencia *promedio* es una mala elección acá, y qué deberías usar en su lugar?

---

## Ejercicio 2 — Error budgets y burn rate: convertir un porcentaje en una decisión

**Objetivo:** un SLO que no cambia el comportamiento de nadie es decoración. El error budget es el mecanismo que le da dientes.

### Pasos

**1.** Calculá el error budget basado en tiempo para una ventana de cumplimiento de 30 días. Un mes de 30 días tiene 43.200 minutos.

$$\text{Presupuesto}_{\text{minutos}} = (1 - \text{SLO}) \times 43{,}200$$

Completalo vos mismo antes de verificar:

```bash
for slo in 99 99.5 99.9 99.95 99.99 99.999; do
  python3 -c "print(f'SLO {$slo:>7}%  ->  {(1-$slo/100)*43200:9.2f} min/30d  ({(1-$slo/100)*43200/60:6.2f} h)')"
done
```

Salida esperada:

```
SLO      99%  ->    432.00 min/30d  (  7.20 h)
SLO    99.5%  ->    216.00 min/30d  (  3.60 h)
SLO    99.9%  ->     43.20 min/30d  (  0.72 h)
SLO   99.95%  ->     21.60 min/30d  (  0.36 h)
SLO   99.99%  ->      4.32 min/30d  (  0.07 h)
SLO  99.999%  ->      0.43 min/30d  (  0.01 h)
```

**2.** Calculá el presupuesto basado en peticiones para tu propio tráfico. Supongamos que el servicio maneja **10.000.000 de peticiones** en la ventana bajo un SLO del **99.9%**:

```bash
python3 - <<'PY'
total, slo = 10_000_000, 0.999
budget = total * (1 - slo)
print(f"allowed bad requests = {budget:,.0f}")
print(f"after 6,200 failures, budget consumed = {6200/budget:.1%}")
print(f"remaining budget       = {budget-6200:,.0f} requests")
PY
```

Salida esperada:

```
allowed bad requests = 10,000
after 6,200 failures, budget consumed = 62.0%
remaining budget       = 3,800 requests
```

**3.** Entendé el **burn rate**. El burn rate es qué tan rápido estás gastando presupuesto en relación con el ritmo que lo agotaría exactamente a lo largo de toda la ventana.

$$\text{Burn rate} = \frac{\text{ratio de error observado}}{1 - \text{SLO}}$$

```bash
python3 - <<'PY'
slo = 0.999
for err in (0.001, 0.003, 0.006, 0.0144, 0.05, 1.0):
    br = err / (1 - slo)
    print(f"error rate {err:7.2%}  -> burn rate {br:6.1f}x  "
          f"-> budget exhausted in {30/br*24:8.2f} h")
PY
```

Salida esperada:

```
error rate   0.10%  -> burn rate    1.0x  -> budget exhausted in   720.00 h
error rate   0.30%  -> burn rate    3.0x  -> budget exhausted in   240.00 h
error rate   0.60%  -> burn rate    6.0x  -> budget exhausted in   120.00 h
error rate   1.44%  -> burn rate   14.4x  -> budget exhausted in    50.00 h
error rate   5.00%  -> burn rate   50.0x  -> budget exhausted in    14.40 h
error rate 100.00%  -> burn rate 1000.0x  -> budget exhausted in     0.72 h
```

**4.** Estudiá la tabla canónica de alertado **multi-ventana, multi-burn-rate** del SRE Workbook. Esto es lo que un equipo de operaciones maduro usa para paginar — no "CPU > 80%".

| Presupuesto consumido | Ventana larga | Ventana corta | Burn rate | Acción |
|---|---|---|---|---|
| 2% | 1 hora | 5 min | **14.4×** | **Page** (despertar a un humano) |
| 5% | 6 horas | 30 min | **6×** | **Page** |
| 10% | 3 días | 6 horas | **1×** | **Ticket** (siguiente día hábil) |

Fuente: [SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/).

**5.** Registrá tu servicio de Cloud Run como *monitored service* para que Cloud Monitoring pueda alojar un SLO para él. Los servicios de Cloud Run se autodescubren; listalos:

```bash
gcloud alpha monitoring services list --format='table(name, displayName)' 2>/dev/null \
  || echo "alpha surface unavailable in this SDK — use the REST call below"
```

Salida esperada (abreviada):

```
NAME                                                        DISPLAY_NAME
projects/my-cdl-project-4471/services/canonical:us-central1:cloud-run:reliability-lab   reliability-lab
```

Equivalente REST, que es estable y siempre está disponible:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/services" \
  | python3 -m json.tool | head -30
```

**6.** Definí un SLO de disponibilidad del 99.9% sobre una ventana móvil de 28 días como un documento JSON. Fijate en la estructura: un *goal*, un *rolling period* y un *SLI* construido a partir de un ratio bueno/total.

```bash
cat > /tmp/slo.json <<'JSON'
{
  "displayName": "99.9% availability - 28d rolling",
  "goal": 0.999,
  "rollingPeriod": "2419200s",
  "serviceLevelIndicator": {
    "basicSli": {
      "availability": {}
    }
  }
}
JSON
python3 -m json.tool /tmp/slo.json
```

`2419200s` = 28 días × 86.400 s. Verificalo vos mismo — un documento de SLO con la ventana equivocada es un SLO silenciosamente equivocado.

**7.** Razoná sobre la *política*, que es la parte que no tiene nada que ver con la tecnología:

> **Política de error budget (borrador).** Mientras quede presupuesto, la velocidad de features es la prioridad y se permiten cambios riesgosos. Cuando el presupuesto se agota, entra en vigor un **feature freeze**: solo se despacha trabajo de confiabilidad y arreglos de seguridad hasta que el presupuesto se recupere. El freeze es automático y no requiere negociación.

### Checkpoint 2

- **Q2.1** — Un equipo propone un SLO del 99.999% para una herramienta interna de reportes de gastos. Calculá la tolerancia mensual de downtime y dá los dos argumentos de negocio más fuertes en contra de ese objetivo.
- **Q2.2** — Tu servicio al 99.9% consumió el 62% de su presupuesto en el día 9 de una ventana de 30 días. ¿Es aceptable? ¿Cuál es el burn rate, y qué debería concluir la persona de guardia?
- **Q2.3** — ¿Por qué la tabla de alertado del paso 4 combina una ventana **larga** con una ventana **corta**? ¿Qué fallo específico ocurriría si alertaras solo con la ventana larga? ¿Y solo con la corta?
- **Q2.4** — Un product manager pide "pausar la política de error budget" por un trimestre por una fecha límite de lanzamiento. Explicá, en el lenguaje de un ejecutivo, qué *es* realmente el error budget en términos organizacionales y en qué convierte al SLO el hecho de pausarlo.
- **Q2.5** — El servicio estuvo 100% disponible todo el mes y el presupuesto sigue intacto el día 30. Una lectura ingenua lo llama excelente. Dá la lectura SRE.

---

## Ejercicio 3 — Observabilidad: las cuatro señales doradas, y por qué métricas ≠ observabilidad

**Objetivo:** distinguir *monitoreo* (preguntas conocidas, dashboards predefinidos) de *observabilidad* (la capacidad de responder preguntas que no anticipaste). Después, instrumentar las cuatro señales doradas.

### Pasos

**1.** Las cuatro señales doradas ([SRE Book, Cap. 6](https://sre.google/sre-book/monitoring-distributed-systems/)):

| Señal | Pregunta que responde | Métrica de Cloud Run |
|---|---|---|
| **Latencia** | ¿Cuánto tarda una petición? | `run.googleapis.com/request_latencies` |
| **Tráfico** | ¿Cuánta demanda hay? | `run.googleapis.com/request_count` |
| **Errores** | ¿Qué fracción está fallando? | `request_count` filtrada por `response_code_class` |
| **Saturación** | ¿Qué tan lleno está el sistema? | `container/cpu/utilizations`, `container/memory/utilizations`, cantidad de instancias |

**2.** Listá los descriptores de métrica que tu servicio está emitiendo realmente:

```bash
gcloud monitoring metrics-descriptors list \
  --filter='metric.type=starts_with("run.googleapis.com/request")' \
  --format='table(type, metricKind, valueType)' 2>/dev/null | head -20
```

Salida esperada:

```
TYPE                                        METRIC_KIND  VALUE_TYPE
run.googleapis.com/request_count            DELTA        INT64
run.googleapis.com/request_latencies        DELTA        DISTRIBUTION
```

Fijate que `request_latencies` es una **DISTRIBUTION**, no un gauge. Eso es deliberado, y la Q3.4 pregunta por qué.

**3.** Consultá tráfico y errores con **PromQL**, que Cloud Monitoring soporta de forma nativa. Abrí **Monitoring → Metrics Explorer → PromQL** en la consola y ejecutá:

```promql
# Traffic: requests per second, by response class
sum by (response_code_class) (
  rate(run_googleapis_com:request_count{
    monitored_resource="cloud_run_revision",
    service_name="reliability-lab"
  }[5m])
)
```

```promql
# Errors: the availability SLI, as a live ratio
sum(rate(run_googleapis_com:request_count{service_name="reliability-lab",response_code_class!="5xx"}[5m]))
/
sum(rate(run_googleapis_com:request_count{service_name="reliability-lab"}[5m]))
```

**4.** Consultá percentiles de latencia — nunca la media:

```promql
histogram_quantile(0.99,
  sum by (le) (
    rate(run_googleapis_com:request_latencies_bucket{service_name="reliability-lab"}[5m])
  )
)
```

**5.** Creá una **métrica basada en logs** para contar una condición que ninguna métrica incorporada cubre. Este es el puente de los logs a las métricas:

```bash
gcloud logging metrics create client_errors_404 \
  --description="Count of 404 responses from reliability-lab" \
  --log-filter="resource.type=\"cloud_run_revision\"
                AND resource.labels.service_name=\"${SERVICE}\"
                AND httpRequest.status=404"
```

Salida esperada:

```
Created [client_errors_404].
```

**6.** Confirmá que existe y entendé qué acabás de construir:

```bash
gcloud logging metrics describe client_errors_404 \
  --format='yaml(name, filter, metricDescriptor.metricKind, metricDescriptor.valueType)'
```

Salida esperada:

```yaml
filter: |-
  resource.type="cloud_run_revision"
  AND resource.labels.service_name="reliability-lab"
  AND httpRequest.status=404
metricDescriptor:
  metricKind: DELTA
  valueType: INT64
name: client_errors_404
```

**7.** Nombrá las tres señales de telemetría y dónde vive cada una en Google Cloud. Completá la columna derecha de memoria, y después verificá en la consola:

| Señal | Qué es | Producto de Google Cloud |
|---|---|---|
| Métricas | Series temporales numéricas agregadas | ? |
| Logs | Eventos discretos, con timestamp, de alta cardinalidad | ? |
| Trazas | El recorrido de una petición a través de los servicios | ? |

**8.** Observá la señal de saturación forzando concurrencia. Ejecutá 40 peticiones en paralelo y después inspeccioná la cantidad de instancias en **Cloud Run → reliability-lab → Metrics**:

```bash
seq 1 40 | xargs -P 40 -I{} curl -s -o /dev/null -w "%{http_code} " "$URL/"
echo
```

Salida esperada:

```
200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200
```

Mirá cómo **Container instance count** sube de 0/1 hacia `--max-instances=3`, y después decae de vuelta a cero en los minutos siguientes.

### Checkpoint 3

- **Q3.1** — Definí la diferencia entre *monitoreo* y *observabilidad* usando un ejemplo concreto de este ejercicio.
- **Q3.2** — Nombrá las cuatro señales doradas y, para cada una, algo que un usuario notaría si se degradara.
- **Q3.3** — Completá la tabla del paso 7. Después indicá cuál de las tres señales es la más cara a escala y por qué.
- **Q3.4** — ¿Por qué `request_latencies` es una distribución y no un solo número? ¿Qué perderías si la plataforma almacenara únicamente la media?
- **Q3.5** — En el paso 8 la cantidad de instancias subió y después bajó. ¿Qué señal dorada es esa, y qué dos capacidades de este objetivo se están demostrando?
- **Q3.6** — Tu servicio llama a tres APIs downstream y la latencia p99 se duplicó. ¿Qué señal de telemetría identifica *cuál* llamada downstream es la responsable, y por qué las métricas por sí solas no pueden responderlo?

---

## Ejercicio 4 — Detección y respuesta a incidentes: uptime checks, alertas y el bucle humano

**Objetivo:** cerrar el circuito desde *algo se rompió* hasta *el humano correcto se entera en segundos*, y ubicar ese circuito dentro de un proceso definido de gestión de incidentes.

### Pasos

**1.** Creá un canal de notificación. Sustituí por tu propia dirección.

```bash
export EMAIL="you@example.com"

gcloud beta monitoring channels create \
  --display-name="CDL Lab On-Call" \
  --type=email \
  --channel-labels="email_address=${EMAIL}"
```

Salida esperada:

```
Created notification channel [projects/my-cdl-project-4471/notificationChannels/1029384756102938475].
```

**2.** Capturá el ID del canal:

```bash
export CHANNEL="$(gcloud beta monitoring channels list \
  --filter='displayName="CDL Lab On-Call"' --format='value(name)')"
echo "$CHANNEL"
```

**3.** Creá un **uptime check** — sondeo sintético, de caja negra, desde múltiples ubicaciones globales. Esto es fundamentalmente distinto de las métricas del Ejercicio 3.

```bash
export HOST="$(echo "$URL" | sed 's|https://||')"

gcloud monitoring uptime create "reliability-lab-https" \
  --resource-type=uptime-url \
  --resource-labels="host=${HOST},project_id=${PROJECT_ID}" \
  --protocol=https \
  --path="/" \
  --port=443 \
  --period=1 \
  --timeout=10
```

Salida esperada:

```
Created [projects/my-cdl-project-4471/uptimeCheckConfigs/reliability-lab-https-a1b2c3].
```

**4.** Verificalo y observá las ubicaciones de sondeo:

```bash
gcloud monitoring uptime list-configs \
  --format='table(displayName, monitoredResource.labels.host, period, selectedRegions)'
```

Salida esperada:

```
DISPLAY_NAME           HOST                                      PERIOD  SELECTED_REGIONS
reliability-lab-https  reliability-lab-abc123def-uc.a.run.app    60s     []
```

Un `selectedRegions` vacío significa *todas* las regiones — el sondeo corre desde América, Europa y Asia-Pacífico simultáneamente. Ese diseño multi-ubicación existe por una razón específica; la Q4.2 pregunta cuál es.

**5.** Creá una política de alertado sobre el uptime check. Notá que `--condition-filter` usa el lenguaje de filtros de Monitoring, y que la alerta requiere que el fallo persista 5 minutos.

```bash
gcloud alpha monitoring policies create \
  --display-name="reliability-lab uptime failure" \
  --condition-display-name="uptime check failing > 5m" \
  --condition-filter='metric.type="monitoring.googleapis.com/uptime_check/check_passed"
                      AND resource.type="uptime_url"' \
  --duration=300s \
  --if="< 1" \
  --aggregation='{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_FRACTION_TRUE"}' \
  --notification-channels="$CHANNEL" \
  --combiner=OR
```

> Si tu SDK rechaza estos flags, construí la política en **Monitoring → Alerting → Create policy**, o hacé un POST del JSON equivalente a
> `https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/alertPolicies`.
> El concepto que se está enseñando — *condición + duración + canal de notificación* — es idéntico en los tres caminos.

**6.** Listá tus políticas:

```bash
gcloud alpha monitoring policies list \
  --format='table(displayName, enabled, conditions[0].displayName)'
```

**7.** Mapeá el vocabulario de la línea de tiempo sobre lo que acabás de construir. Para una caída hipotética que empieza a las 14:00:00:

| Momento | Métrica | Qué artefacto tuyo lo determina |
|---|---|---|
| 14:00:00 | empieza la caída | — |
| 14:01:00 | primer sondeo fallido | uptime check `--period=1` |
| 14:05:00 | **MTTD** — detección | `--duration=300s` |
| 14:06:30 | **MTTA** — reconocimiento | canal de notificación + rotación de guardia |
| 14:41:00 | **MTTR** — servicio restaurado | runbook / rollback |

**8.** Entendé los roles de respuesta, que son proceso y no producto ([SRE Book — Managing Incidents](https://sre.google/sre-book/managing-incidents/)):

- **Incident Commander (IC)** — es dueño del incidente, decide, delega. *No* hace debugging.
- **Operations / Ops Lead** — la única persona que hace cambios en el sistema.
- **Communications Lead** — actualiza a los stakeholders y la página de estado.
- **Planning** — hace seguimiento de bugs, traspasos y el registro del postmortem.

**9.** Disparás un incidente real. Rompé el servicio quitando el acceso público, esperá, y después observá cómo se dispara la alerta y llega el email.

```bash
gcloud run services remove-iam-policy-binding "$SERVICE" \
  --region="$REGION" --member="allUsers" --role="roles/run.invoker"

curl -s -o /dev/null -w "status=%{http_code}\n" "$URL"
```

Salida esperada:

```
status=403
```

Esperá 6–8 minutos, después revisá **Monitoring → Alerting → Incidents**. Restaurá el servicio:

```bash
gcloud run services add-iam-policy-binding "$SERVICE" \
  --region="$REGION" --member="allUsers" --role="roles/run.invoker"
```

### Checkpoint 4

- **Q4.1** — El uptime check del paso 3 es monitoreo de *caja negra*; las métricas del Ejercicio 3 son de *caja blanca*. Definí ambos, y dá una cosa que cada uno detecta y el otro no puede.
- **Q4.2** — ¿Por qué el uptime check sondea desde varios continentes en lugar de uno? Describí la conclusión falsa específica que puede producir un sondeo de una sola ubicación.
- **Q4.3** — El paso 5 fijó `--duration=300s`. Explicá el compromiso que hiciste. ¿Qué sale mal con `30s`? ¿Qué sale mal con `3600s`?
- **Q4.4** — Definí MTTD, MTTA, MTTR y MTBF. Tu MTTR es de 35 minutos y la dirección lo quiere por debajo de 10. Nombrá dos cambios que reduzcan el MTTR *sin* hacer que el sistema sea menos propenso a fallar.
- **Q4.5** — Durante el incidente del paso 9, el IC tiene una hipótesis fuerte sobre la causa raíz. ¿Debería empezar a hacer debugging? Justificá desde las definiciones de los roles.
- **Q4.6** — Tu equipo recibe 60 alertas por semana, de las cuales 4 son accionables. Nombrá la patología, indicá su consecuencia de segundo orden, y dá la regla canónica de SRE sobre qué merece un page.

---

## Ejercicio 5 — Resiliencia: dominios de fallo, redundancia y arquetipos de despliegue

**Objetivo:** la confiabilidad es una propiedad que se *mide*; la resiliencia es una propiedad que se *diseña*. Este es el bloque donde ocurre la arquitectura.

### Pasos

**1.** Enumerá la jerarquía de dominios de fallo. Cada nivel contiene al anterior y falla de forma independiente de sus hermanos:

```
Resource  →  Zone  →  Region  →  Multi-region  →  Global
```

**2.** Inspeccioná la topología real de una región:

```bash
gcloud compute zones list --filter="region:( us-central1 )" \
  --format='table(name, status, region.basename())'
```

Salida esperada:

```
NAME           STATUS  REGION
us-central1-a  UP      us-central1
us-central1-b  UP      us-central1
us-central1-c  UP      us-central1
us-central1-f  UP      us-central1
```

```bash
gcloud compute regions list --format='table(name, status)' | head -8
```

**3.** Calculá la matemática de la redundancia. Las dependencias **en serie** se multiplican; la redundancia **en paralelo** multiplica las probabilidades de *fallo*.

$$A_{\text{serie}} = \prod_i A_i \qquad\qquad A_{\text{paralelo}} = 1 - \prod_i (1 - A_i)$$

```bash
python3 - <<'PY'
def budget(a): return (1-a)*43200
serial = 0.999 ** 4
print(f"4 services in series, each 99.9%  -> {serial:.5%}  ({budget(serial):.1f} min/30d)")
par2 = 1 - (1-0.99)**2
par3 = 1 - (1-0.99)**3
print(f"2 independent zones, each 99%     -> {par2:.5%}  ({budget(par2):.1f} min/30d)")
print(f"3 independent zones, each 99%     -> {par3:.5%}  ({budget(par3):.1f} min/30d)")
PY
```

Salida esperada:

```
4 services in series, each 99.9%  -> 99.60060%  (172.8 min/30d)
2 independent zones, each 99%     -> 99.99000%  (4.3 min/30d)
3 independent zones, each 99%     -> 99.99900%  (0.4 min/30d)
```

**4.** Estudiá los **arquetipos de despliegue** ([cloud.google.com/architecture/deployment-archetypes](https://cloud.google.com/architecture/deployment-archetypes)). Completá las columnas vacías antes de mirar la clave de respuestas:

| Arquetipo | ¿Sobrevive a un fallo de **zona**? | ¿Sobrevive a un fallo de **región**? | Costo relativo | Uso típico |
|---|---|---|---|---|
| **Zonal** | ? | ? | $ | Dev, batch, no crítico |
| **Regional** | ? | ? | $$ | La mayoría de las cargas de producción |
| **Multirregional** | ? | ? | $$$ | Crítico para el negocio, atado a DR |
| **Global** | ? | ? | $$$$ | Cara al usuario a escala planetaria |
| **Híbrido / Multicloud** | ? | ? | $$$$ | Regulatorio, salida de la nube, edge |

**5.** Clasificá tu propio servicio de laboratorio. Cloud Run es un producto **regional** — una revisión corre a través de las zonas de una región, gestionada por vos… bueno, por la plataforma.

```bash
gcloud run services describe "$SERVICE" --region="$REGION" \
  --format='value(metadata.labels."cloud.googleapis.com/location", status.url)'
```

Salida esperada:

```
us-central1	https://reliability-lab-abc123def-uc.a.run.app
```

**6.** Diseñá la promoción a multirregional — el diseño en papel es la parte relevante para el examen:

```
                       ┌──────────────────────────────────┐
   Users  ──────────▶  │  Global external Application LB  │  ← single anycast IP
                       │      (Cloud CDN + Cloud Armor)   │
                       └───────────┬──────────┬───────────┘
                                   │          │
                   serverless NEG  │          │  serverless NEG
                             ┌─────▼────┐ ┌───▼──────┐
                             │ Cloud Run│ │ Cloud Run│
                             │us-central1│ │europe-w1│
                             └─────┬────┘ └───┬──────┘
                                   │          │
                             ┌─────▼──────────▼─────┐
                             │  Spanner (multi-region)│  ← the hard part
                             └────────────────────────┘
```

Desplegá la segunda región para que el diseño sea real:

```bash
gcloud run deploy "$SERVICE" \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region=europe-west1 \
  --allow-unauthenticated \
  --max-instances=2

gcloud run services list --format='table(metadata.name, region, status.url)'
```

**7.** Nombrá los mecanismos de resiliencia y emparejá cada uno con aquello contra lo que protege. Hacelo de memoria primero:

| Mecanismo | Protege contra |
|---|---|
| Balanceo de carga + health checks | ? |
| Autoscaling | ? |
| Auto-healing de managed instance group | ? |
| Reintentos con exponential backoff **y jitter** | ? |
| Circuit breaker | ? |
| Graceful degradation | ? |
| Rate limiting / throttling | ? |
| Chaos engineering | ? |

**8.** Razoná sobre los dos modos de fallo más difíciles de la tabla anterior. Escribí dos oraciones sobre cada uno:

- **Retry storm / fallo metaestable**: un servicio se recupera, todos los clientes reintentan simultáneamente, el servicio recuperado se cae otra vez. ¿Por qué el *jitter* — y no solo el backoff — arregla esto?
- **Fallo en cascada**: el servicio C se degrada, los hilos de B se bloquean sobre C, los hilos de A se bloquean sobre B, y todo el stack está caído aunque solo C estaba enfermo. ¿Qué mecanismo de la tabla corta la cadena, y cómo?

### Checkpoint 5

- **Q5.1** — Completá la tabla de arquetipos del paso 4.
- **Q5.2** — Cuatro microservicios, cada uno al 99.9%, encadenados de forma síncrona. ¿Cuál es la disponibilidad de punta a punta, y cuál es la lección arquitectónica general? Nombrá un patrón que rompa la multiplicación.
- **Q5.3** — Un stakeholder dice "somos multi-zona, así que estamos cubiertos". Nombrá tres clases de fallo reales contra las que multi-zona *no* protege.
- **Q5.4** — En el diseño del paso 6, ¿por qué se describe a la capa de base de datos como "the hard part"? Nombrá la restricción física y el compromiso que fuerza.
- **Q5.5** — Completá la tabla de mecanismos del paso 7.
- **Q5.6** — Distinguí *confiabilidad* de *resiliencia* con precisión. Dá un sistema altamente confiable pero no resiliente, y otro resiliente pero con mala confiabilidad medida.
- **Q5.7** — ¿Qué es el chaos engineering, y cuál es el prerrequisito que un equipo debe tener en su lugar *antes* de correr su primer experimento?

---

## Ejercicio 6 — Recuperación ante desastres: RTO, RPO y elegir un patrón que puedas pagar

**Objetivo:** alta disponibilidad y recuperación ante desastres son disciplinas distintas con presupuestos distintos. Si los dos objetivos están bien puestos, el patrón se elige solo.

### Pasos

**1.** Fijá las definiciones:

- **RTO — Recovery Time Objective:** el *tiempo* máximo tolerable en que el servicio puede estar no disponible. Se mide en el reloj.
- **RPO — Recovery Point Objective:** la *pérdida de datos* máxima tolerable, expresada como una ventana de tiempo. Se mide hacia atrás desde el incidente.

**2.** Mapeá una línea de tiempo concreta. Los backups corren cada hora en punto; la región falla a las 14:47; el servicio se restaura en otro lado a las 16:20.

```
 13:00        14:00              14:47            16:20
   │            │                  │                │
 backup      backup            DISASTER          restored
              └──── RPO: 47 min ───┘                │
                                  └── RTO: 93 min ──┘
```

**3.** Calculá las dos cifras para un conjunto de escenarios:

```bash
python3 - <<'PY'
scenarios = [
    ("Hourly snapshot, manual restore",       60, 240),
    ("15-min snapshot, scripted restore",     15,  45),
    ("Continuous replication, warm standby",   1,  10),
    ("Synchronous multi-region, active-active", 0,  0),
]
print(f"{'Pattern':<42}{'RPO(min)':>10}{'RTO(min)':>10}")
for name, rpo, rto in scenarios:
    print(f"{name:<42}{rpo:>10}{rto:>10}")
PY
```

Salida esperada:

```
Pattern                                     RPO(min)  RTO(min)
Hourly snapshot, manual restore                   60       240
15-min snapshot, scripted restore                 15        45
Continuous replication, warm standby               1        10
Synchronous multi-region, active-active            0         0
```

**4.** Estudiá los patrones de DR ([cloud.google.com/architecture/disaster-recovery](https://cloud.google.com/architecture/disaster-recovery)). Completá esta tabla:

| Patrón | Estado del standby | RTO típico | RPO típico | Costo del standby |
|---|---|---|---|---|
| **Backup & restore** (frío) | Nada corriendo | ? | ? | ? |
| **Pilot light** | Núcleo mínimo, datos replicando | ? | ? | ? |
| **Warm standby** | Stack completo reducido, corriendo | ? | ? | ? |
| **Hot standby / multi-site** | Capacidad completa, sirviendo | ? | ? | ? |

**5.** *(Opcional — este paso aprovisiona un recurso facturable. Saltá al paso 6 para el camino solo en papel.)* Inspeccioná una configuración real de backup y point-in-time recovery:

```bash
gcloud sql instances create dr-lab \
  --database-version=POSTGRES_15 \
  --tier=db-f1-micro \
  --region="$REGION" \
  --enable-point-in-time-recovery \
  --retained-transaction-log-days=7 \
  --backup-start-time=03:00

gcloud sql instances describe dr-lab \
  --format='yaml(settings.backupConfiguration)'
```

Salida esperada:

```yaml
settings:
  backupConfiguration:
    backupRetentionSettings:
      retainedBackups: 7
      retentionUnit: COUNT
    enabled: true
    pointInTimeRecoveryEnabled: true
    startTime: '03:00'
    transactionLogRetentionDays: 7
```

**Borrala inmediatamente al terminar:**

```bash
gcloud sql instances delete dr-lab --quiet
```

**6.** Camino en papel: leé el efecto de los flags anteriores sin aprovisionar nada.

- `enabled: true` con `startTime: '03:00'` da backups diarios → **RPO de hasta 24 h**.
- `pointInTimeRecoveryEnabled: true` transmite el write-ahead log de forma continua → **el RPO cae a segundos**, a costa de almacenar esos logs.
- Ninguno de los dos flags cambia el **RTO** en absoluto. El RTO lo gobierna cuánto tarda un restore y si el procedimiento de restauración está automatizado y *ensayado*.

**7.** Asigná patrones a tres negocios. Justificá cada uno en una oración:

| Negocio | Restricción | Tu patrón |
|---|---|---|
| Procesador de pagos | Perder una transacción es un incidente regulatorio | ? |
| Catálogo de e-commerce | 30 min offline es sobrevivible; reconstruible desde la fuente de verdad | ? |
| Reportes internos de RR.HH. | Solo lectura, horario laboral, actualizado cada noche | ? |

**8.** El paso que la mayoría de las organizaciones se saltea:

```bash
# There is no gcloud command for this. Put it on a calendar.
echo "DR drill scheduled: restore prod backup into an isolated project, measure actual RTO."
```

### Checkpoint 6

- **Q6.1** — Definí RTO y RPO, y después calculá ambos para la línea de tiempo del paso 2.
- **Q6.2** — Completá la tabla de patrones de DR del paso 4.
- **Q6.3** — ¿Cuál de RTO o RPO está impulsado principalmente por la *frecuencia de backup*, y cuál por la *automatización y el ensayo de la restauración*? ¿Por qué los equipos mejoran rutinariamente uno y se olvidan del otro?
- **Q6.4** — Distinguí alta disponibilidad de recuperación ante desastres. Dá un fallo que HA maneja y DR no, y uno que DR maneja y HA no.
- **Q6.5** — Completá la tabla de asignación del paso 7.
- **Q6.6** — Un CTO pide "RPO cero y RTO cero" para todos los sistemas de la empresa. Explicá las consecuencias de costo y de ingeniería, y replanteá el pedido como la pregunta que en realidad deberían estar haciendo.
- **Q6.7** — ¿Por qué un backup que nunca fue restaurado no es un backup? Nombrá la práctica operativa que lo arregla.

---

## Ejercicio 7 — Operaciones modernas: DevOps, SRE, DORA y toil

**Objetivo:** la mitad de "operaciones modernas" del objetivo. Esto es cultura de ingeniería medible, no eslóganes.

### Pasos

**1.** Ubicá los tres términos:

- **DevOps** — el movimiento cultural y organizacional: propiedad compartida entre desarrollo y operaciones, cambios pequeños y frecuentes, automatización, bucles de feedback.
- **SRE** — una implementación concreta y opinionada de DevOps, inventada en Google, que funciona sobre SLOs, error budgets y límites de toil. *"class SRE implements DevOps."*
- **DORA** — el programa de investigación que mide si alguna de las dos está funcionando. [dora.dev](https://dora.dev/)

**2.** Las cuatro claves de DORA. Dos son de **throughput**, dos de **estabilidad** — y el hallazgo que hizo famoso a DORA es que se mueven *juntas*, no una contra la otra:

| Métrica | Tipo | Mide |
|---|---|---|
| **Frecuencia de despliegue** | Throughput | Cada cuánto despachás a producción |
| **Lead time de los cambios** | Throughput | Commit → corriendo en producción |
| **Tasa de fallo de cambios** | Estabilidad | % de despliegues que causan una degradación que requiere remediación |
| **Tiempo de recuperación de un despliegue fallido** | Estabilidad | Qué tan rápido te recuperás de un mal despliegue (informes anteriores lo llamaban MTTR) |

> Los umbrales de referencia se rederivan en el informe *State of DevOps* de cada año — citá el año, no memorices los números.

**3.** Calculá las cuatro claves a partir de un log de despliegues sintético:

```bash
cat > /tmp/deploys.csv <<'CSV'
deploy_id,commit_ts,deploy_ts,failed,restored_ts
d1,2026-09-01T09:00,2026-09-01T11:00,0,
d2,2026-09-01T14:00,2026-09-02T10:00,0,
d3,2026-09-03T08:00,2026-09-03T09:30,1,2026-09-03T10:15
d4,2026-09-04T10:00,2026-09-04T12:00,0,
d5,2026-09-07T09:00,2026-09-07T09:45,0,
d6,2026-09-08T11:00,2026-09-08T16:00,1,2026-09-08T16:20
CSV

python3 - <<'PY'
import csv, datetime as dt
f = "%Y-%m-%dT%H:%M"
rows = list(csv.DictReader(open("/tmp/deploys.csv")))
lead = [(dt.datetime.strptime(r["deploy_ts"],f)-dt.datetime.strptime(r["commit_ts"],f)).total_seconds()/3600 for r in rows]
fails = [r for r in rows if r["failed"]=="1"]
rec = [(dt.datetime.strptime(r["restored_ts"],f)-dt.datetime.strptime(r["deploy_ts"],f)).total_seconds()/60 for r in fails]
print(f"Deployment frequency        : {len(rows)} deploys / 8 days = {len(rows)/8:.2f}/day")
print(f"Lead time for changes (mean): {sum(lead)/len(lead):.1f} h")
print(f"Change failure rate         : {len(fails)/len(rows):.1%}")
print(f"Failed deploy recovery (mean): {sum(rec)/len(rec):.0f} min")
PY
```

Salida esperada:

```
Deployment frequency        : 6 deploys / 8 days = 0.75/day
Lead time for changes (mean): 6.5 h
Change failure rate         : 33.3%
Failed deploy recovery (mean): 32 min
```

**4.** Aplicá la definición SRE de **toil** ([SRE Book, Cap. 5](https://sre.google/sre-book/eliminating-toil/)). El trabajo es toil si es: *manual, repetitivo, automatizable, táctico, carente de valor duradero, y escala linealmente con el crecimiento del servicio.* Auditá esta semana:

| Tarea | ¿Toil? | Por qué / por qué no |
|---|---|---|
| Reiniciar manualmente cada noche un servicio que pierde memoria | ? | ? |
| Diseñar la migración multirregional del próximo trimestre | ? | ? |
| Copiar métricas a una planilla para un reporte semanal | ? | ? |
| Atender un incidente de producción genuinamente novedoso | ? | ? |
| Aprobar 30 pedidos de acceso idénticos por semana | ? | ? |
| Escribir un postmortem | ? | ? |

**5.** Entendé la regla del 50%: SRE limita el toil al **50%** del tiempo de una persona SRE; el resto debe ir a ingeniería que reduzca el toil futuro. Calculá el efecto compuesto:

```bash
python3 - <<'PY'
toil, growth, reduction = 0.35, 1.6, 0.30   # 60% yearly service growth, 30% yearly automation
for year in range(6):
    print(f"year {year}: toil = {min(toil,1):.0%}")
    toil = min(toil * growth * (1 - reduction), 1.0)
PY
```

Salida esperada:

```
year 0: toil = 35%
year 1: toil = 39%
year 2: toil = 44%
year 3: toil = 49%
year 4: toil = 55%
year 5: toil = 62%
```

Automatizar un 30% por año *no alcanza* si el servicio crece un 60% por año. Ese es todo el argumento a favor del tope.

**6.** Escribí un **postmortem sin culpa (blameless)** para el incidente del paso 9 del Ejercicio 4. Usá este esqueleto, y hacé cumplir la regla blameless: describí *qué permitió el sistema*, nunca *quién fue descuidado*.

```markdown
# Postmortem: reliability-lab returned 403 to all users

**Status:** resolved
**Impact:** 100% of requests failed for 12 minutes. Error budget consumed: ~28% of the 30-day budget.
**Detection:** uptime check `reliability-lab-https`, alert fired at T+5m (MTTD 5 min).
**Root cause:** an IAM policy change removed `allUsers:roles/run.invoker` from the
production service. The change had no review gate and no canary.

## Timeline
- T+0    IAM binding removed
- T+0.5  first probe failure (Americas, Europe, APAC)
- T+5    alert fires, on-call paged
- T+7    on-call acknowledges (MTTA 7 min)
- T+12   binding restored, probes green (MTTR 12 min)

## What went well
- Multi-region probing eliminated "is it just me?" from the first two minutes.

## What went wrong
- No pre-deploy diff on IAM policy for production services.
- The 5-minute alert duration is tuned for flakiness, not for total outage.

## Action items
| # | Action | Type | Owner | Due |
|---|---|---|---|---|
| 1 | Deny-policy blocking removal of `run.invoker` on prod without approval | prevent | @platform | 2026-09-19 |
| 2 | Add a fast-burn (14.4x/1h) alert alongside the 5-min uptime alert | detect  | @sre | 2026-09-16 |
| 3 | Runbook: "service returns 403 to everyone" | mitigate | @sre | 2026-09-23 |
```

**7.** Identificá las prácticas de automatización que este objetivo espera que sepas nombrar: **IaC** (Terraform / Config Controller), **CI/CD** (Cloud Build, Cloud Deploy), **GitOps**, **policy as code** (Organization Policy, Policy Controller), **entrega progresiva** (canary, blue/green, traffic splitting).

Cloud Run te da la última directamente:

```bash
gcloud run deploy "$SERVICE" \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region="$REGION" --no-traffic --tag=canary

gcloud run services update-traffic "$SERVICE" \
  --region="$REGION" --to-tags=canary=10
```

Salida esperada (abreviada):

```
✓ Routing traffic... Done.
Traffic:
  90% reliability-lab-00001-xyz
  10% reliability-lab-00002-abc  (tag: canary)
```

### Checkpoint 7

- **Q7.1** — Distinguí DevOps, SRE y DORA en una oración cada uno.
- **Q7.2** — Nombrá las cuatro claves de DORA, clasificá cada una como throughput o estabilidad, e indicá el hallazgo central y contraintuitivo de DORA.
- **Q7.3** — De la salida del paso 3, ¿qué métrica individual es la más alarmante y qué indica con mayor probabilidad sobre el pipeline de entrega?
- **Q7.4** — Completá la tabla de auditoría de toil del paso 4.
- **Q7.5** — Explicá la salida del paso 5 a un manager que cree que "automatizamos mucho el año pasado, así que el toil debería estar bajando".
- **Q7.6** — ¿Qué hace que un postmortem sea *blameless*, y cuál es el beneficio concreto de ingeniería — no el emocional?
- **Q7.7** — En el paso 7 enviaste el 10% del tráfico a una revisión nueva. Nombrá la práctica, y explicá cómo baja simultáneamente la *tasa de fallo de cambios* y el *tiempo de recuperación de un despliegue fallido*.

---

## Ejercicio 8 — Capstone: una revisión de confiabilidad bajo restricciones reales

**Objetivo:** integrar todos los bloques en una sola decisión, que es la forma que toma la pregunta de examen.

### Escenario

*Cordillera Health* opera una plataforma de turnos para pacientes sobre Google Cloud.

- Arquitectura actual: un MIG de Compute Engine en **una sola zona** de `southamerica-east1`, una instancia de Cloud SQL, sin réplica, backup nocturno a las 02:00.
- Tráfico: 08:00–20:00 hora local, con picos los lunes a la mañana de 8× la media diaria.
- Último trimestre: 3 caídas, de 52, 95 y 210 minutos. No existe ningún SLO. Las alertas se basan en umbrales de CPU; la guardia recibe ~80 alertas por semana.
- El directorio exige "99.99% de disponibilidad" tras la caída de 210 minutos.
- Regulatorio: los registros de turnos no se pueden perder. Los registros también se escriben en un sistema de registro on-premises.

### Pasos

**1.** Calculá la disponibilidad medida del último trimestre contra una ventana de 30 días:

```bash
python3 - <<'PY'
downtime = 52 + 95 + 210          # minutes over 90 days
window   = 90 * 24 * 60
a = 1 - downtime/window
print(f"measured availability = {a:.4%}")
for target in (0.99, 0.995, 0.999, 0.9999):
    print(f"  target {target:.2%}: budget {(1-target)*window:8.1f} min/90d "
          f"-> {'MET' if downtime <= (1-target)*window else 'MISSED'}")
PY
```

Salida esperada:

```
measured availability = 99.7183%
  target 99.00%: budget   1296.0 min/90d -> MET
  target 99.50%: budget    648.0 min/90d -> MET
  target 99.90%: budget    129.6 min/90d -> MISSED
  target 99.99%: budget     13.0 min/90d -> MISSED
```

**2.** Redactá la especificación de confiabilidad. Completá cada celda:

| Ítem | Tu respuesta |
|---|---|
| Definición del SLI de disponibilidad (buenos / válidos) | ? |
| Definición del SLI de latencia | ? |
| SLO propuesto y ventana | ? |
| Error budget resultante (min/30d) | ? |
| RTO | ? |
| RPO | ? |
| Arquetipo de despliegue | ? |
| Patrón de DR | ? |

**3.** Listá los cambios en orden de prioridad, y para cada uno indicá cuál de las caídas del *último* trimestre habría prevenido.

**4.** Escribí la respuesta de dos oraciones a la exigencia del directorio de "99.99%".

### Checkpoint 8

- **Q8.1** — Dá tu tabla completa del paso 2, con una línea de justificación por fila.
- **Q8.2** — ¿Cuál es tu lista de cambios en orden de prioridad, y qué cambio individual da la mayor mejora de disponibilidad por dólar?
- **Q8.3** — ¿Es 99.99% el objetivo correcto para esta plataforma? Respondé con números, no con opiniones, e indicá qué propondrías en su lugar.
- **Q8.4** — La guardia recibe 80 alertas por semana bajo umbrales de CPU. Describí con precisión qué las reemplaza y por qué el reemplazo produce alertas menos numerosas y mejores.
- **Q8.5** — Los registros también se escriben en un sistema de registro on-premises. ¿Cómo cambia ese hecho tu requisito de RPO, y de qué *no* te exime?

---

## Ejercicio 9 — Desmantelamiento

Ejecutá esto hayas completado o no el paso opcional de Cloud SQL. Dejar recursos corriendo es la forma más común en que un proyecto de Free Tier empieza a facturar.

```bash
gcloud run services delete "$SERVICE" --region="$REGION" --quiet
gcloud run services delete "$SERVICE" --region=europe-west1 --quiet

gcloud logging metrics delete client_errors_404 --quiet

UPTIME_ID="$(gcloud monitoring uptime list-configs \
  --filter='displayName="reliability-lab-https"' --format='value(name)')"
[ -n "$UPTIME_ID" ] && gcloud monitoring uptime delete "$UPTIME_ID" --quiet

POLICY="$(gcloud alpha monitoring policies list \
  --filter='displayName="reliability-lab uptime failure"' --format='value(name)')"
[ -n "$POLICY" ] && gcloud alpha monitoring policies delete "$POLICY" --quiet

[ -n "$CHANNEL" ] && gcloud beta monitoring channels delete "$CHANNEL" --quiet

gcloud sql instances delete dr-lab --quiet 2>/dev/null || true

echo "teardown complete"
```

Verificá que no queda nada:

```bash
gcloud run services list
gcloud monitoring uptime list-configs
gcloud sql instances list
```

---

<details>
<summary><strong>📖 Clave de respuestas — expandí solo después de intentar cada checkpoint</strong></summary>

## Ejercicio 1 — SLI, SLO, SLA

**A1.1** — Lo que cambió es la **definición de "evento bueno"**: el paso 7 contó como malo solo a los `5xx`; el paso 8 también contó a los `4xx`. El comportamiento del sistema fue idéntico. El documento que fija esto es la **especificación del SLI** — la declaración escrita y precisa de *eventos buenos / eventos válidos*. Un SLO sin ella no tiene sentido, y la disputa de confiabilidad más común del mundo real ("ingeniería dice 99.95%, soporte dice 97%") es casi siempre dos equipos usando especificaciones de SLI distintas y no escritas.

**A1.2**
- **SLI (Service Level Indicator):** una medición cuantitativa de un aspecto de la calidad del servicio, normalmente expresada como un ratio de eventos buenos sobre eventos válidos — por ejemplo, "la proporción de peticiones HTTP que devuelven no-5xx dentro de 300 ms".
- **SLO (Service Level Objective):** un valor objetivo para un SLI sobre una ventana declarada — por ejemplo, "99.9% de las peticiones a lo largo de 28 días móviles". Es interno, lo elige el equipo, y es la entrada del error budget.
- **SLA (Service Level Agreement):** un contrato con un cliente que contiene un SLO más **consecuencias** por incumplirlo — típicamente créditos de servicio.

**Solo el SLA tiene consecuencias legales y financieras.** Los SLIs miden, los SLOs guían la prioridad de ingeniería, los SLAs crean responsabilidad legal.

**A1.3** — **99.95%.** El SLO interno debe ser **más estricto** que el SLA externo, para que el SLO se incumpla — y dispare ingeniería correctiva — *antes* de que se incumpla el contrato y se deba dinero. Esa brecha es el margen de seguridad.

Modos de fallo de las respuestas equivocadas:
- **99.9% (igual al SLA):** no hay ningún aviso previo. En el instante en que se dispara tu alerta de SLO ya estás pagando créditos de servicio. Convertiste un sistema de alerta temprana en una notificación de facturación.
- **99.5% (más laxo que el SLA):** activamente dañino. Tu monitoreo reporta "SLO saludable" mientras estás en incumplimiento contractual — el dashboard está en verde durante un incidente legal.

**A1.4** — Ambas posiciones son defendibles, que es exactamente por qué hay que escribirlo:

*Contarlos como malos* — el usuario experimentó un fallo. Si los 404 vienen de un enlace roto que emite tu propio frontend, o de una ruta que un mal despliegue eliminó, la sesión del usuario está rota y ningún "técnicamente el servidor respondió correctamente" cambia eso. Los picos de `4xx` son una señal real de producción.

*No contarlos* — un SLI de disponibilidad mide si **tu servicio** está cumpliendo su contrato. Un cliente que pide `/nonexistent` recibe la respuesta semánticamente correcta; el servidor está sano. Contar comportamiento arbitrario del cliente como fallo tuyo hace al SLI trivialmente atacable: un solo scraper con mal comportamiento puede quemar todo tu error budget sin que tu servicio se degrade en absoluto.

**Práctica estándar:** excluir los `4xx` de la disponibilidad (habitualmente son eventos *inválidos*, no malos), pero rastrearlos por separado — a menudo como una métrica basada en logs, exactamente como en el Ejercicio 3 — y tratar un pico repentino de `4xx` como su propia condición de alertado. Si se sabe que un código `4xx` específico lo causa tu propio servicio (por ejemplo, un `429` de tu propio rate limiter), nombralo explícitamente en la especificación.

**A1.5** — Porque la media esconde la cola. Con 200 peticiones a 30 ms y una a 412 ms, la media es ≈ 32 ms — indistinguible de un servicio sin ningún cold start. Pero ese usuario esperó casi medio segundo. A escala de producción, la misma aritmética esconde *miles* de peticiones lentas detrás de un promedio de aspecto saludable, y esas peticiones corresponden desproporcionadamente a tus usuarios más activos (más peticiones → más chance de caer en un evento de cola).

Usá **percentiles**: p50 para la experiencia típica, p95 y p99 para la cola. El SLI canónico de latencia no es un percentil de latencia sino un **ratio**: *"la proporción de peticiones servidas en menos de 300 ms"* — lo que convierte la latencia en la misma forma bueno/válido que la disponibilidad y la hace directamente componible dentro de un error budget.

---

## Ejercicio 2 — Error budgets y burn rate

**A2.1** — 99.999% sobre 30 días permite **0,43 minutos ≈ 25,9 segundos** de downtime por mes.

Argumentos en contra:
1. **El costo es superlineal, el valor no.** Cada nueve adicional multiplica aproximadamente la inversión de ingeniería e infraestructura — multirregión activo-activo, replicación síncrona, despliegues sin downtime, guardia 24/7 siguiendo el sol. Para una herramienta interna de gastos, el valor marginal de pasar de 99.9% (43 min/mes) a 99.999% (26 s/mes) es esencialmente cero: los empleados cargan gastos en días hábiles, y una caída de 40 minutos cuesta unas pocas cargas postergadas.
2. **El SLO sería indetectable e inalcanzable en la práctica.** 26 segundos están dentro del piso de ruido: un solo reinicio de instancia, un despliegue, el SLA de una dependencia, o la propia latencia del pipeline de monitoreo pueden consumir todo el presupuesto. Un SLO que incumplís por razones fuera de tu control es ignorado en menos de dos meses — y cuando un SLO es ignorado, todos pierden autoridad.

El replanteo: preguntá cuánto le cuesta realmente el downtime al negocio por hora, y después comprá el objetivo más barato que mantenga ese costo aceptable. Para una herramienta interna eso suele ser **99.5% o 99.9%**.

**A2.2** — **No, no es aceptable.**

El día 9 de 30 es el 30% de la ventana transcurrida, pero está consumido el 62% del presupuesto. El burn rate promedio es 62/30 ≈ **2,07×**. A ese ritmo sostenido, el presupuesto se agota alrededor del día 14,5 — la mitad de la ventana — dejando 15+ días con presupuesto cero y un feature freeze automático.

La persona de guardia debería concluir: esto no es una emergencia de page (2× es una quema lenta, muy por debajo del umbral de quema rápida de 14.4×), pero *sí* es un ticket, y exige investigación ahora y no a fin de mes. Las acciones correctas son identificar qué cambió alrededor del comienzo de la quema, y advertirle al product owner que el freeze es probable — antes de que caiga como sorpresa.

**A2.3** — La **ventana larga** mide significancia; la **ventana corta** mide actualidad.

- **Solo la ventana larga:** una alerta que decae lentamente. Una vez que una ventana de 1 hora o 6 horas acumuló suficientes eventos malos como para incumplir, sigue incumpliendo el resto de esa ventana *incluso después de arreglada la caída*. La guardia arregla el problema a las 14:20 y el page sigue disparándose hasta las 15:20. Eso entrena a la gente a ignorarlo. La ventana corta actúa como **condición de reset** — la alerta se limpia apenas la tasa de error *actual* vuelve a la normalidad.
- **Solo la ventana corta:** ruido intolerable. Una ventana de 5 minutos sobre un servicio de bajo tráfico incumple con un puñado de peticiones fallidas, un solo reinicio de instancia o un despliegue. Paginarías decenas de veces por semana por eventos que consumen una fracción despreciable del presupuesto.

Exigir que **ambas** ventanas incumplan simultáneamente te da una alerta que es *significativa* (la ventana larga prueba que se está gastando presupuesto real) y *actual* (la ventana corta prueba que sigue ocurriendo). Ese es todo el diseño.

**A2.4** — A un ejecutivo:

> El error budget no es una métrica técnica — es el **acuerdo negociado entre producto e ingeniería sobre cuánto riesgo tomamos**. Acordamos que 99.9% es la confiabilidad que nuestros clientes necesitan; el presupuesto es ese 0,1% de falta de confiabilidad que deliberadamente nos permitimos *gastar* en despachar rápido. Cada lanzamiento riesgoso, cada test salteado, cada despliegue apurado lo consume. Cuando se termina, ya entregamos toda la falta de confiabilidad que nuestros clientes aceptaron tolerar este mes.
>
> Pausar la política no crea más presupuesto — simplemente elimina el mecanismo que nos avisa que nos quedamos sin él. Convierte al SLO de un compromiso en una sugerencia, y mueve el costo de nuestro roadmap a nuestros clientes, donde no podemos verlo hasta que se van.

La contrajugada correcta no es pausar la política sino **renegociar el SLO** — con los datos. Si el negocio genuinamente quiere más velocidad, proponé bajar el objetivo a 99.5% *explícitamente*, para que el riesgo sea una decisión registrada y no un accidente.

**A2.5** — Terminar sistemáticamente la ventana con el presupuesto intacto significa que el SLO está **fijado demasiado bajo respecto de lo que el sistema realmente entrega**, y eso es una forma de desperdicio:

1. **Estás sobreinvertido en confiabilidad.** El esfuerzo de ingeniería, la redundancia y la infraestructura que producen confiabilidad *por encima* del objetivo no compran nada que el negocio haya pedido. Esa capacidad debería ir a features.
2. **Estás despachando demasiado lento.** El presupuesto no gastado es permiso que te negaste a usar. Debería haberse gastado en releases más rápidos, experimentos más grandes, o una migración que venís postergando.
3. **Fijaste expectativas de cliente que no podés revertir.** Si los usuarios experimentan 100% durante seis meses, van a construir flujos de trabajo asumiéndolo — y tu compromiso real de 99.9% se vuelve políticamente inaplicable. (Por eso algunos equipos inyectan downtime controlado deliberadamente; el servicio de locks Chubby de Google es el ejemplo canónico.)

La respuesta es **subir el SLO para que coincida con la realidad, o gastar el presupuesto deliberadamente.** Un presupuesto que nunca se consume es un objetivo que no está haciendo su trabajo.

---

## Ejercicio 3 — Observabilidad

**A3.1**
- **El monitoreo** responde preguntas que sabías que había que hacer. En este ejercicio: el dashboard de Cloud Run mostrando cantidad de peticiones y latencia. Predefiniste la métrica, el dashboard y el umbral. Te dice **que** algo está mal.
- **La observabilidad** es la propiedad de un sistema que te permite responder preguntas que *no* anticipaste, a partir de sus salidas externas, sin desplegar código nuevo. En este ejercicio: la consulta `gcloud logging read` del paso 6, donde cortaste logs de peticiones en crudo por código de estado después del hecho — y la métrica basada en logs del paso 5, donde creaste una medición completamente nueva a partir de datos que ya se estaban emitiendo. Te dice **por qué**.

La prueba práctica: cuando ocurre un fallo novedoso, ¿podés investigarlo con la telemetría que ya tenés, o tenés que desplegar instrumentación nueva y esperar a que se repita? La segunda respuesta significa que tenés monitoreo, no observabilidad.

**A3.2**

| Señal | Degradación visible para el usuario |
|---|---|
| **Latencia** | La página se cuelga; el spinner gira; el checkout se siente roto aunque eventualmente funcione |
| **Tráfico** | Un colapso significa que los usuarios no pueden llegar a vos en absoluto (DNS, LB, upstream); un pico significa un lanzamiento, un bot o un ataque |
| **Errores** | Fallo explícito — una página 500, un pago fallido, un formulario perdido |
| **Saturación** | Nada todavía, y después todo de golpe — las colas crecen, después sube la latencia, después los timeouts se convierten en errores. La saturación es el indicador **adelantado**; se degrada antes de que los usuarios lo noten, y por eso es la que hay que alertar para capacidad |

**A3.3**

| Señal | Producto de Google Cloud |
|---|---|
| Métricas | **Cloud Monitoring** |
| Logs | **Cloud Logging** |
| Trazas | **Cloud Trace** |

(La suite más amplia agrega **Cloud Profiler** para profiling continuo de CPU/heap y **Error Reporting** para agregar excepciones.)

**Los logs son lo más caro a escala.** Las métricas están preagregadas — el costo de almacenamiento de un contador es prácticamente independiente de cuántos eventos cuenta. Los logs almacenan cada evento individual con contexto completo, así que el costo crece linealmente con el tráfico *y* con lo verbosa que sea cada entrada. Precisamente por eso existen las métricas basadas en logs: convertís el patrón de alto valor en un contador barato, y después dejás que los logs crudos expiren con una política de retención corta. La alta cardinalidad es la otra trampa — una etiqueta como `user_id` en una métrica hace explotar la cantidad de series temporales y puede costar más de lo que costaban los logs.

**A3.4** — La latencia no es un número por intervalo; son miles de números por intervalo. Una métrica de **distribución** los almacena como buckets de histograma, lo que preserva la *forma* de la población de tiempos de respuesta.

Si la plataforma almacenara solo la media, perderías:
- **Todos los percentiles.** p50, p95 y p99 no son recuperables a partir de una media — la aritmética simplemente no existe.
- **La multimodalidad.** Un servicio con un camino rápido de caché (5 ms) y un camino frío lento (500 ms) tiene la misma media que un servicio uniformemente mediocre a 250 ms, y necesitan arreglos completamente distintos.
- **La capacidad de definir un SLI de latencia siquiera.** "99% de las peticiones por debajo de 300 ms" requiere saber cuántas peticiones cayeron bajo 300 ms, que es un conteo de bucket.

Los buckets además agregan correctamente: podés sumar histogramas a través de regiones y revisiones y aun así calcular un p99 global válido. No podés promediar promedios.

**A3.5** — Eso es **saturación**, y demuestra **autoscaling** (elasticidad: capacidad siguiendo la demanda automáticamente en ambas direcciones) y **gestión de capacidad sin intervención manual** — se elimina la carga operativa de aprovisionar para el pico.

La sutileza que vale la pena notar: la cantidad de instancias se detuvo en 3 porque fijaste `--max-instances=3`. Un límite protege a las dependencias downstream de ser desbordadas y acota el costo descontrolado, pero también significa que más allá de ese punto la carga adicional se convierte en **encolamiento → latencia → errores**. Todo techo de autoscaling es una decisión deliberada sobre qué modo de fallo preferís.

**A3.6** — **Las trazas** (Cloud Trace) — específicamente el tracing distribuido, que propaga un contexto de traza a través de las fronteras entre servicios para que el recorrido completo de una petición se reconstruya como un árbol de spans cronometrados. La traza muestra de inmediato que el span de `inventory` pasó de 40 ms a 900 ms mientras los otros dos siguen igual.

Las métricas no pueden responder esto porque están **agregadas y desconectadas**. Podés ver que el p99 de tu servicio se duplicó, y por separado que tres servicios downstream tienen cada uno su propio p99 — pero no hay ningún join entre ellos. Los promedios sobre todas las peticiones ocultan el hecho de que solo las peticiones que pasan por cierto camino de código son lentas, y si dos servicios downstream se degradaron levemente no podés decir qué combinación produjo tu cola. Las trazas preservan la **causalidad dentro de una única petición**, que es exactamente la dimensión que la agregación destruye.

---

## Ejercicio 4 — Detección y respuesta a incidentes

**A4.1**
- **El monitoreo de caja negra** sondea el sistema desde afuera, como lo haría un usuario, sin conocimiento de los internos. El uptime check hace una petición HTTPS desde la internet pública y registra la respuesta. Está orientado a **síntomas**.
- **El monitoreo de caja blanca** usa telemetría que el propio sistema emite sobre sí mismo — métricas internas, logs, trazas. Está orientado a **causas**.

Lo que cada uno detecta de forma exclusiva:
- **Solo caja negra:** todo el camino de la petición fuera de tu aplicación — fallo de resolución DNS, un certificado TLS vencido, un balanceador mal configurado, un binding de IAM roto (exactamente el incidente del paso 9: tu contenedor estaba perfectamente sano y emitiendo métricas perfectamente sanas mientras el 100% de los usuarios recibía 403), un problema de BGP o de CDN. Si tu servicio está bien pero nadie puede alcanzarlo, solo la caja negra se entera.
- **Solo caja blanca:** cualquier cosa interna que todavía no llegó al usuario — una cola creciendo, una pérdida de memoria al 60% del límite, un pool de conexiones al 90% de saturación, un p99 subiendo pero dentro del SLO. Estas son las señales *predictivas* que te permiten actuar antes de una caída.

Necesitás ambos. La caja negra es sobre lo que paginás (correlaciona con el dolor del usuario); la caja blanca es con lo que hacés debugging.

**A4.2** — Porque una única ubicación de sondeo no puede distinguir **"el servicio está caído"** de **"el camino entre un sondeo y el servicio está caído"**.

La conclusión falsa específica: un problema de red local a una región — un problema de peering, una caída de un proveedor de tránsito, un fallo de resolvedor DNS regional — hace que el servicio parezca globalmente muerto cuando está sirviendo normalmente a todos los demás continentes. Despertás a la guardia a las 03:00 por un problema en la red de otro. El inverso es peor: un sondeo en la misma región que tu servicio puede tener éxito por un camino interno mientras todos los usuarios externos están fallando, así que ves verde durante una caída real.

El sondeo multi-ubicación convierte esto en un *quórum*: que fallen todas las ubicaciones es una caída real; que falle una es un evento de red a investigar pero no a paginar. Además te da datos de latencia regional gratis.

**A4.3** — El ajuste `--duration` es el compromiso entre **falsos positivos** y **tiempo de detección (MTTD)**.

- **Con `30s`:** paginás por ruido transitorio — un solo reinicio de instancia, un microcorte de red, un sondeo lento, un despliegue normal. Una alta tasa de falsos positivos lleva directamente a la fatiga de alertas (Q4.6). Comprás 4,5 minutos de MTTD y lo pagás con una rotación de guardia que deja de confiar en el pager.
- **Con `3600s`:** tenés un piso de MTTD de 60 minutos. Una caída total corre durante una hora antes de que se le avise a nadie. Si tu SLO es 99.9% (43 min/mes), *una sola* caída no detectada ya voló el presupuesto mensual completo antes de que la alerta se dispare. La alerta es aritméticamente incapaz de proteger al SLO para cuya protección existe.

La forma con principios de fijar esto no es adivinar una duración sino **derivarla del error budget**: elegí la ventana de la tabla de burn rate del Ejercicio 2 (14.4× sobre 1 hora con una ventana corta de 5 minutos). Así, la sensibilidad de la alerta es una consecuencia matemática del SLO en vez de una corazonada. En la práctica, un servicio real corre *ambas*: un page de quema rápida para el fallo catastrófico y un ticket de quema lenta para la degradación.

**A4.4**
- **MTTD — Mean Time To Detect:** empieza el incidente → el monitoreo lo nota.
- **MTTA — Mean Time To Acknowledge:** se dispara la alerta → un humano toma la responsabilidad.
- **MTTR — Mean Time To Repair/Recover/Restore:** empieza el incidente → el servicio está sano de nuevo. (Es ambiguo en el mundo real — algunas organizaciones lo miden desde la detección y no desde el inicio; definilo antes de reportarlo.)
- **MTBF — Mean Time Between Failures:** intervalo promedio entre incidentes. La disponibilidad los relaciona: `MTBF / (MTBF + MTTR)`.

Dos cambios que reducen el MTTR sin tocar la probabilidad de fallo:
1. **Rollback de un solo comando, siempre disponible.** La mayoría de los incidentes de producción son inducidos por cambios. Si volver a la última revisión buena conocida es un único comando que cualquier persona de guardia puede ejecutar sin entender la causa raíz, desacoplás la *recuperación* del *diagnóstico* — la mayor reducción de MTTR disponible para la mayoría de los equipos. El `update-traffic` de Cloud Run hacia una revisión anterior es exactamente esto.
2. **Runbooks enlazados directamente desde la alerta.** La alerta debería llevar un enlace a un documento que diga qué significa esa alerta, qué revisar primero y cuáles son las mitigaciones conocidas. Esto ataca el segmento "la guardia pasa 20 minutos redescubriendo el contexto" de toda línea de tiempo de incidente. Su primo cercano es reducir el MTTA con una rotación bien dotada y una política de escalamiento.

Notá que ambas son mejoras **operativas**. Cambian qué tan rápido te recuperás, no con qué frecuencia te rompés — que es precisamente por qué MTTR y MTBF son palancas separadas, y por qué DORA trata al tiempo de recuperación como una métrica de primera clase.

**A4.5** — **No.** El Incident Commander no debe hacer debugging.

La función del IC es sostener la imagen *global*: quién está haciendo qué, qué se probó, cuál es el impacto en el cliente, si hay que escalar, si se declara el incidente resuelto. En el momento en que el IC abre una terminal y empieza a investigar su hipótesis, pierde esa imagen — la atención se estrecha a una teoría, la coordinación se detiene, dos personas empiezan a hacer cambios en el mismo sistema sin saber una de la otra, y nadie está siguiendo si la hipótesis se está refutando.

La jugada correcta: el IC **le declara la hipótesis al Ops Lead y delega la investigación**, y sigue coordinando. El conocimiento del IC no se desperdicia — se convierte en una instrucción en vez de en una acción. La separación de roles existe porque el modo de fallo que previene (todos haciendo debugging, nadie comandando) es la forma más común en que una respuesta a incidentes se degrada en caos.

**A4.6** — La patología es la **fatiga de alertas**, impulsada por una relación señal/ruido muy baja (4/60 ≈ 7% accionable).

La consecuencia de segundo orden es la peligrosa: **el equipo deja de confiar en el pager**. Las alertas se silencian, se autofiltran a una carpeta, o se reconocen reflejamente sin investigar. Eventualmente llega una alerta *real* a ese flujo y se descarta con el mismo reflejo que las 56 ruidosas. La fatiga de alertas no solo molesta a la gente — **aumenta el MTTD de los incidentes genuinos**, así que un sistema de monitoreo ruidoso es mediblemente peor que uno silencioso. También impulsa el burnout y la rotación de la guardia, lo que elimina el conocimiento institucional que hace que los incidentes sean cortos.

La regla canónica de SRE: **paginá solo por síntomas que sean visibles para el usuario y requieran acción humana inmediata.** Todo lo demás es un ticket, un dashboard, o se borra. Concretamente, una alerta merece un page solo si es *urgente* (esperar a la mañana lo empeora), *accionable* (hay algo que un humano puede hacer ahora mismo — un page por una condición sin remedio es puro ruido) y *novedosa* (si la respuesta son siempre los mismos tres comandos, automatizalos). Alertar sobre el burn rate del SLO en vez de sobre umbrales de recursos hace casi todo este filtrado automáticamente: la CPU al 90% no es un síntoma, usuarios recibiendo errores sí.

---

## Ejercicio 5 — Resiliencia y arquitectura

**A5.1**

| Arquetipo | ¿Sobrevive a fallo de zona? | ¿Sobrevive a fallo de región? | Costo | Uso |
|---|---|---|---|---|
| **Zonal** | ❌ No | ❌ No | $ | Dev/test, batch reejecutable, herramientas internas no críticas |
| **Regional** | ✅ Sí | ❌ No | $$ | El default para la mayoría de las cargas de producción |
| **Multirregional** | ✅ Sí | ✅ Sí | $$$ | Sistemas críticos para el negocio, regulados, atados a DR |
| **Global** | ✅ Sí | ✅ Sí (+ ruteo por latencia) | $$$$ | Servicios cara al usuario a escala planetaria |
| **Híbrido / Multicloud** | ✅ Sí | ✅ Sí (+ fallo de proveedor) | $$$$ | Ley de residencia de datos, estrategia de salida de la nube, integración edge/on-prem |

Vale la pena retener la distinción entre multirregional y global: multirregional se trata de *tolerancia a fallos* entre regiones; global agrega un único punto de entrada anycast que rutea a cada usuario a la región sana más cercana, así que también compra *latencia* — y significa que un fallo regional lo maneja el balanceador de carga, de forma transparente, en vez de un procedimiento de failover.

**A5.2** — `0.999⁴ = 0.99601` → **99.601%**, un error budget de **172,8 min/30d** — cuatro veces peor que cualquier componente individual.

La lección: **las dependencias síncronas se multiplican, así que la disponibilidad solo puede bajar a medida que agregás saltos.** Una arquitectura de microservicios donde cada petición atraviesa cuatro servicios no puede ser más disponible que el producto de sus SLOs, no importa qué tan bueno sea cada uno. Este es el argumento cuantitativo contra las cadenas de llamadas síncronas profundas y la razón por la que "agreguemos un servicio más" nunca es gratis.

Patrones que rompen la multiplicación:
- **Desacoplamiento asíncrono** (Pub/Sub, colas de tareas): el llamador publica y retorna; el servicio downstream puede estar caído durante minutos sin que la petición del usuario falle. La dependencia se saca por completo del camino crítico.
- **Graceful degradation con un fallback:** si el servicio de recomendaciones está caído, servís una lista cacheada o genérica en vez de fallar la página. La dependencia pasa a ser opcional en vez de requerida.
- **Caching:** un hit de caché no consume la disponibilidad del servicio downstream en absoluto.
- **Redundancia en cada capa:** subir la disponibilidad propia de cada componente vía instancias en paralelo (ver la fórmula de paralelo) compensa parcialmente la multiplicación en serie.

**A5.3** — Multi-zona protege contra el fallo de *infraestructura* dentro de un datacenter. **No** protege contra:

1. **Fallo a nivel de región completa.** Las zonas comparten un área metropolitana — un desastre natural, un evento regional de red o de plano de control, o un fallo de red eléctrica a escala metropolitana pueden tumbar todas las zonas a la vez. Multi-zona es por definición de una sola región.
2. **Código y configuración defectuosos.** Este es el grande, y la causa más común de caídas reales. Un despliegue roto, un push de configuración corrupta, una política IAM mala (exactamente el incidente del paso 9) o una migración de esquema que dropea una columna se replican a todas las zonas *instantáneamente y por diseño*. La redundancia reproduce fielmente tu error por triplicado. Las mitigaciones son entrega progresiva, canaries y rollback rápido — no más zonas.
3. **Desastres a nivel de datos.** El borrado accidental, el ransomware y la corrupción lógica se propagan a todas las réplicas. La replicación no es backup: copia el daño. Para esto existen el point-in-time recovery y los backups inmutables y aislados.

Menciones honoríficas en la misma categoría: dependencia de un único plano de control global, una cuota compartida que se agota, un certificado vencido, y DNS.

**A5.4** — Porque el cómputo es stateless y el estado no. Podés correr contenedores idénticos de Cloud Run en dos regiones trivialmente — no guardan nada. La base de datos guarda la verdad, y la verdad no puede estar en dos lugares a la vez sin tomar una decisión.

La restricción física es **la velocidad de la luz**. De `us-central1` a `europe-west1` hay aproximadamente 100 ms de ida y vuelta, y ninguna ingeniería lo elimina. Entonces:

- **Replicación síncrona** — cada escritura es confirmada por ambas regiones antes de retornar. RPO = 0, sin pérdida de datos ante un fallo regional. Costo: cada escritura paga el round trip interregional, así que la latencia de escritura pasa de ~5 ms a más de ~100 ms. Para una carga transaccional intensiva en escritura esto suele ser inaceptable.
- **Replicación asíncrona** — el primario confirma inmediatamente y envía los cambios en segundo plano. La latencia de escritura se mantiene local. Costo: **RPO > 0** — un fallo regional pierde lo que estuviera en vuelo, y tenés que decidir si perder 5 segundos de escrituras es tolerable. También introduce una decisión de failover (¿promover la réplica? ¿arriesgar split-brain?) que suma al RTO.

Este es el compromiso CAP/PACELC con ropa operativa, y es por eso que **Cloud Spanner** aparece en el diagrama: provee consistencia síncrona multirregión con garantías de consistencia externa, usando TrueTime para acotar la incertidumbre de reloj — a un precio, y con un piso de latencia de escritura fijado por la geografía. Elegir el modo de replicación de tu base de datos *es* elegir tu RPO, y es la decisión que determina si "multirregión" significa failover real o un diagrama reconfortante.

**A5.5**

| Mecanismo | Protege contra |
|---|---|
| **Balanceo de carga + health checks** | Fallo de una instancia o backend individual — el tráfico se desvía automáticamente de los endpoints no sanos, normalmente antes de que los usuarios lo noten |
| **Autoscaling** | Saturación por demanda — picos de tráfico, picos de lunes a la mañana, eventos virales, y el costo de sobreaprovisionar para el pico |
| **Auto-healing de MIG** | Instancias que están corriendo pero rotas (proceso colgado, health check fallido) — la plataforma las recrea sin un humano |
| **Reintentos con exponential backoff + jitter** | Fallos transitorios: un paquete perdido, un 503 breve, una elección de líder. El backoff previene la amplificación; el **jitter** previene la sincronización |
| **Circuit breaker** | Fallo en cascada — deja de enviar peticiones a una dependencia que se sabe fallando, para que los llamadores fallen rápido en vez de agotar sus propios hilos/conexiones esperando |
| **Graceful degradation** | Fallo de una dependencia no esencial — servir una respuesta cacheada, simplificada o parcial en vez de una página de error. Convierte una caída total en una experiencia reducida |
| **Rate limiting / throttling** | Sobrecarga de cualquier origen: clientes abusivos, reintentos descontrolados, una integración con bugs, o un pico genuino mayor que tu capacidad. Protege a la mayoría rechazando el excedente de forma determinística |
| **Chaos engineering** | *Supuestos no verificados* — la creencia de que tu failover funciona. No previene un fallo; encuentra los que tu diseño no contempló, a plena luz del día, con todos mirando |

**A5.6**
- **La confiabilidad** es el resultado medido: ¿hace el servicio lo que los usuarios necesitan, al nivel prometido, a lo largo del tiempo? Es lo que cuantifica el marco SLI/SLO. Se *observa*.
- **La resiliencia** es la propiedad del sistema que la produce: la capacidad de absorber fallos, degradarse con gracia y recuperarse automáticamente sin intervención humana. Se *diseña*.

Confiable pero no resiliente: una VM de una sola zona que simplemente no falló en dos años. Su SLI marca 99.99%; su disponibilidad es enteramente cuestión de suerte. El primer evento a nivel de zona convierte ese 99.99% en una caída de varias horas, porque no hay ningún mecanismo para absorber el fallo — solo una ausencia de fallos hasta ahora. Este es el argumento "nunca tuvimos una caída", y es la oración más peligrosa en operaciones.

Resiliente pero con mala confiabilidad medida: un sistema multirregión bien arquitecturado en su primer mes, donde un mal despliegue y un mal push de configuración causaron cada uno incidentes visibles. La arquitectura absorbe fallos de infraestructura perfectamente — pero la resiliencia al fallo de *infraestructura* no da ninguna protección contra el fallo inducido por *cambios*, que es la mayoría de las caídas reales. Su SLI es malo por razones que la redundancia nunca fue diseñada para atender.

El par importa porque se mejoran con trabajos distintos: la confiabilidad midiendo y priorizando, la resiliencia con arquitectura — y ninguna sustituye a la otra.

**A5.7** — El **chaos engineering** es la práctica de inyectar deliberadamente fallos controlados en un sistema — terminar instancias, agregar latencia, tumbar una dependencia, fallar una zona — para *verificar empíricamente* que los mecanismos de resiliencia que diseñaste realmente funcionan, y para descubrir los modos de fallo que no anticipaste. Mueve el descubrimiento de un failover roto de las 03:00 de un domingo a las 14:00 de un martes con todo el equipo mirando.

El prerrequisito, y es innegociable: **tenés que poder observar y medir el radio de impacto, y detener el experimento.** Concretamente eso significa (a) SLOs y telemetría lo bastante buenos como para detectar el impacto inducido en segundos, (b) un procedimiento de aborto definido y probado, (c) un radio de impacto acotado — empezá en un entorno de preproducción o en una porción pequeña del tráfico, y (d) aprobación organizacional explícita, porque un experimento que nadie acordó es simplemente una caída que causaste vos.

Correr experimentos de caos sin observabilidad no es un experimento: rompés algo, no aprendés nada sobre el mecanismo, y no podés saber si el daño se detuvo. El orden siempre es **medir primero, después romper.** Por la misma razón, los equipos deberían arreglar los fallos que ya conocen antes de salir a cazar nuevos.

---

## Ejercicio 6 — Recuperación ante desastres

**A6.1**
- **RTO (Recovery Time Objective):** la duración máxima aceptable de la caída — cuánto tiempo hasta que el servicio esté restaurado. Un objetivo de *tiempo hasta recuperar*.
- **RPO (Recovery Point Objective):** la cantidad máxima aceptable de pérdida de datos, expresada como la ventana de tiempo cuyas escrituras podés permitirte perder. Un objetivo de *pérdida de datos*.

Para la línea de tiempo del paso 2:
- **RPO = 47 minutos.** El último backup exitoso fue a las 14:00; el desastre golpeó a las 14:47. Todo lo escrito en esa brecha de 47 minutos se perdió.
- **RTO = 93 minutos.** Desde las 14:47 (fallo) hasta las 16:20 (restaurado).

Notá que ambos son *objetivos* — metas a las que te comprometés — y lo que muestra la línea de tiempo es el valor *alcanzado*. Un plan de DR solo es significativo cuando los valores alcanzados, medidos en un simulacro real, están dentro de los objetivos.

**A6.2**

| Patrón | Estado del standby | RTO típico | RPO típico | Costo del standby |
|---|---|---|---|---|
| **Backup & restore** (frío) | Nada corriendo; backups en Cloud Storage | Horas a días | Horas (= intervalo de backup) | El más bajo — solo almacenamiento |
| **Pilot light** | Núcleo mínimo corriendo, datos replicando continuamente | Decenas de minutos a horas | Minutos a segundos | Bajo — una huella pequeña siempre encendida |
| **Warm standby** | Stack completo pero reducido, corriendo y replicando | Minutos | Segundos | Medio — una fracción de producción |
| **Hot standby / multi-site** | Capacidad completa, sirviendo activamente | Segundos a cero | Casi cero a cero | El más alto — una segunda producción completa |

La forma de la tabla es la lección: **el RTO y el RPO se compran con dinero**, aproximadamente de forma monótona. No existe una configuración que te dé recuperación de hot standby a costo de cold standby, y cualquier afirmación de un proveedor en contrario debe leerse con atención.

**A6.3**
- **El RPO lo determina la frecuencia de backup/replicación.** Snapshots por hora limitan tu RPO a una hora; el streaming continuo de WAL (PITR) lo baja a segundos. Es una propiedad del *plano de datos*.
- **El RTO lo determinan la automatización y el ensayo de la restauración.** Es la suma de: detectar → decidir → ejecutar → validar → derivar el tráfico. La frecuencia de backup tiene efecto cero sobre él. Es una propiedad de *proceso*.

Los equipos mejoran el RPO y se olvidan del RTO porque **el RPO es un checkbox y el RTO es una práctica.** Habilitar PITR es un flag, visible en un archivo de configuración, auditable, y queda hecho. El RTO requiere que alguien efectivamente restaure un backup de producción en un entorno limpio, descubra que faltan los bindings de IAM, que el TTL de DNS es de 24 horas, que el runbook referencia a una persona que se fue, y que nadie sabe quién es el dueño de la clave de descifrado — y después arregle todo eso, y lo vuelva a hacer el trimestre siguiente porque se deteriora. El cambio de configuración es permanente; la capacidad es perecedera.

El resultado es el fallo clásico: una organización con backups excelentes, un RPO de 15 segundos, y un RTO real de 14 horas que nadie midió nunca.

**A6.4**
- **La alta disponibilidad (HA)** se trata de sobrevivir al fallo de *componentes* dentro de un entorno operativo normal, de forma automática y continua — instancias redundantes, despliegue multi-zona, balanceo de carga con health checks, failover automático. Está siempre activa, se mide en el SLO, y no involucra ninguna decisión humana.
- **La recuperación ante desastres (DR)** se trata de sobrevivir a la pérdida de un entorno entero — una región, un dataset, una cuenta — e involucra un *procedimiento* deliberado de recuperación, normalmente con un punto de decisión humana, medido por RTO y RPO.

Manejado por HA pero no por DR: una sola VM que se cae, una zona que queda no disponible, un backend que falla un health check. El MIG la reemplaza o el balanceador la esquiva en segundos; no se invoca ningún plan de DR y no se restauran datos — de hecho, invocar un failover de DR por el fallo de una sola instancia sería un resultado mucho peor que el propio fallo.

Manejado por DR pero no por HA: **la destrucción lógica de datos.** Un `DROP TABLE`, ransomware, una mala migración, o un borrado masivo accidental. La replicación de HA propaga el daño a todas las réplicas a velocidad de máquina — eso es exactamente para lo que sirve la replicación. Solo una restauración point-in-time desde un backup inmutable lo recupera. La pérdida a nivel de región es el otro caso claro: HA dentro de una región no tiene nada a lo que hacer failover.

La regla que vale la pena llevarse: **la replicación no es backup.** HA protege contra que las cosas se rompan; DR protege contra que las cosas estén *mal*.

**A6.5**

| Negocio | Patrón | Justificación |
|---|---|---|
| **Procesador de pagos** | **Hot standby / multi-site**, replicación síncrona | El RPO debe ser cero — una transacción perdida es un incidente regulatorio y financiero, no una molestia. Eso obliga a escrituras síncronas multirregión (clase Spanner), y la penalidad de latencia de escritura y de costo es simplemente el precio del requisito de cumplimiento |
| **Catálogo de e-commerce** | **Warm standby** o pilot light | 30 minutos de RTO son explícitamente aceptables, y el catálogo es reconstruible desde una fuente de verdad upstream — así que la tolerancia de RPO es generosa. Pagar hot standby acá compra tiempo de recuperación que el negocio ya dijo que no necesita |
| **Reportes internos de RR.HH.** | **Backup & restore** (frío) | Solo lectura, horario laboral, refresco nocturno. Un RPO de 24 horas es inherente al propio ciclo de actualización de los datos — no podés perder datos que no cambiaron. Un RTO de varias horas le cuesta al negocio un reporte demorado. Cualquier cosa más es gastar dinero para protegerse contra un no-evento |

El meta-punto: las tres respuestas son correctas *para su restricción*, y la restricción viene del negocio, no del gusto de ingeniería. El examen evalúa si podés leer la restricción del escenario.

**A6.6** — Lo que "RPO 0 y RTO 0 para todo" realmente cuesta:

- **RPO 0** requiere replicación síncrona a una ubicación geográficamente separada para cada sistema con estado. Cada escritura paga el round trip interregional — realistamente 50–150 ms sumados a cada transacción — así que el throughput de los sistemas intensivos en escritura cae y algunas aplicaciones se vuelven inutilizables. Los sistemas que no pueden hacer replicación síncrona multirregión deben ser rearquitecturados o reemplazados.
- **RTO 0** requiere un segundo entorno completamente aprovisionado y sirviendo activamente para cada sistema, más failover automatizado, más verificación continua de que el failover funciona. Eso es aproximadamente **2× la factura de infraestructura**, más la ingeniería para construirlo y mantenerlo, más la cadencia continua de simulacros.
- Aplicado a *toda la empresa*, la mayoría de ese gasto protege sistemas donde una caída casi no cuesta nada — herramientas internas, reportes, pipelines batch.

El replanteo:

> "Cero es alcanzable, y esto es lo que cuesta. La pregunta que nos lleva a la respuesta correcta no es '¿qué recuperación queremos?' — todo el mundo quiere instantánea. Es **'¿cuánto le cuesta a este sistema específico una hora de caída, o una hora de datos perdidos?'** Después compramos para cada sistema la recuperación que su propio riesgo justifica. Para pagos eso va a ser genuinamente casi cero. Para la wiki interna va a ser un backup nocturno. Aplicarle a la wiki el estándar de pagos duplica nuestra factura de infraestructura para proteger algo cuya ausencia nadie notaría."

Esto es **tiering**, y es la respuesta profesional estándar: clasificar los sistemas en dos o tres niveles de recuperación, asignar RTO/RPO por nivel, y defender la clasificación en vez del número.

**A6.7** — Porque un backup no es un artefacto; es una **capacidad**, y el artefacto es solo una de sus partes. Un backup no probado es un *supuesto* no probado de que el archivo está completo, de que no está silenciosamente corrupto, de que su clave de cifrado sigue siendo accesible, de que el esquema todavía coincide con la aplicación actual, de que el procedimiento de restauración todavía funciona contra la infraestructura actual, de que alguien sabe ejecutarlo, y de que todo eso termina dentro de tu RTO. Cada uno de esos supuestos falló en incidentes reales, y cada uno falla *silenciosamente* — el job de backup reporta éxito hasta el mismísimo día en que lo necesitás.

La práctica que lo arregla es el **simulacro de DR / prueba de restauración**: restaurar periódicamente un backup real de producción en un entorno aislado, validar los datos, y **medir el tiempo transcurrido real** — que se convierte en tu RTO real y basado en evidencia en vez de una estimación. Corrélo con una cadencia (trimestral es común), rotá quién lo ejecuta para que la capacidad no sea el conocimiento de una sola persona, y tratá un simulacro fallido exactamente como un incidente de producción, con postmortem y elementos de acción. Las organizaciones maduras van más lejos y automatizan la restauración-y-verificación como un job continuo.

---

## Ejercicio 7 — Operaciones modernas

**A7.1**
- **DevOps** — un movimiento cultural y organizacional que elimina el muro entre desarrollo y operaciones: propiedad compartida de producción, cambios pequeños y frecuentes, automatización del camino a producción, y bucles de feedback rápidos. Declara metas y principios, no implementaciones.
- **SRE** — una implementación específica y prescriptiva de esos principios, desarrollada en Google, que trata a las operaciones como un problema de ingeniería de software. Aporta los mecanismos concretos que DevOps deja abiertos: SLIs/SLOs, error budgets como árbitro entre velocidad y estabilidad, un tope duro al toil, postmortems sin culpa, y un comando de incidentes definido. *"class SRE implements DevOps."*
- **DORA (DevOps Research and Assessment)** — el programa de investigación multianual que mide el desempeño de la entrega de software en miles de organizaciones e identifica qué capacidades predicen estadísticamente mejores resultados. Es la capa de evidencia: te dice si tu adopción de DevOps o SRE está funcionando realmente, usando las cuatro claves.

**A7.2**

| Métrica | Tipo |
|---|---|
| Frecuencia de despliegue | **Throughput** |
| Lead time de los cambios | **Throughput** |
| Tasa de fallo de cambios | **Estabilidad** |
| Tiempo de recuperación de un despliegue fallido | **Estabilidad** |

El hallazgo central, y la razón por la que las cuatro siempre se reportan juntas: **la velocidad y la estabilidad no son un compromiso — se mueven juntas.** La intuición de que despachar más rápido debe significar romper más es empíricamente falsa. Las organizaciones de alto desempeño despliegan mucho más frecuentemente *y* tienen menores tasas de fallo de cambios *y* se recuperan más rápido.

El mecanismo es directo una vez enunciado: los cambios pequeños y frecuentes son más fáciles de revisar, más fáciles de testear, más fáciles de razonar, y — críticamente — triviales de revertir, porque la superficie de causa de cualquier incidente es un diff pequeño en vez del trabajo acumulado de un trimestre. Los releases grandes e infrecuentes son riesgosos *porque* son grandes, y el miedo que producen lleva a releases menos frecuentes, lo que los hace más grandes. El desempeño de élite es la versión virtuosa de ese mismo bucle.

Por eso también es peligroso medir solo dos de las cuatro: throughput sin estabilidad premia la imprudencia, y estabilidad sin throughput premia la parálisis. El par es el punto.

**A7.3** — La **tasa de fallo de cambios de 33,3%** es la alarmante. Uno de cada tres despliegues causa una degradación que requiere remediación, contra una cifra de un solo dígito para los de alto desempeño.

Qué indica: **los problemas se están descubriendo en producción porque nada aguas arriba los está atrapando.** Las causas más probables, aproximadamente por frecuencia —

- Testing automatizado inadecuado, así que la primera validación real de un cambio ocurre cuando los usuarios lo golpean.
- **Sin entrega progresiva.** Los despliegues van directo al 100% del tráfico, así que cada defecto que se despacha es un incidente de radio de impacto completo. Un canary convertiría la mayoría de estos en un incidente del 5% detectado en tres minutos.
- Cambios grandes o agrupados: notá que el lead time promedia 6,5 horas pero un despliegue tardó 24 horas y otro 5 — la varianza sugiere tamaños de cambio inconsistentes, y los cambios grandes fallan más seguido.
- Deriva de entorno entre staging y producción.

La contraseñal alentadora es el tiempo de recuperación de 32 minutos, que muestra que el equipo *puede* responder. La palanca está entonces enteramente aguas arriba: la mayor victoria barata acá es una etapa de canary más rollback automático por burn rate del SLO, porque ataca la tasa de fallo de cambios y el tiempo de recuperación al mismo tiempo (ver A7.7).

**A7.4**

| Tarea | ¿Toil? | Por qué |
|---|---|---|
| Reiniciar manualmente cada noche un servicio con memory leak | ✅ **Sí** | Manual, repetitivo, automatizable, puramente táctico, sin valor duradero, y se repite para siempre. El ejemplo arquetípico — y notá que el arreglo *correcto* es encontrar el leak, no automatizar el reinicio |
| Diseñar la migración multirregional del próximo trimestre | ❌ **No** | Trabajo de ingeniería. Novedoso, creativo, produce valor duradero, y su salida cambia permanentemente las capacidades del sistema |
| Copiar métricas a una planilla semanalmente | ✅ **Sí** | Manual, repetitivo, enteramente automatizable (una consulta programada o un dashboard), y escala con la cantidad de servicios sobre los que se reporta |
| Atender un incidente de producción genuinamente novedoso | ❌ **No** | Novedoso por definición y requiere criterio. Es interruptivo e indeseado, pero no es toil — el postmortem que sigue produce valor duradero. (Si el incidente "novedoso" es el mismo por cuarta vez, se convirtió en toil) |
| Aprobar 30 pedidos de acceso idénticos por semana | ✅ **Sí** | Manual, repetitivo, escala linealmente con la dotación, y automatizable vía grupos de IAM, autoservicio con guardrails de política, o acceso just-in-time |
| Escribir un postmortem | ❌ **No** | Produce valor duradero: elementos de acción, un registro permanente, y aprendizaje organizacional que previene la recurrencia. Tedioso no es lo mismo que toil |

La distinción que resuelve la mayoría de las disputas: el toil no es "trabajo que me disgusta". Es trabajo que es **automatizable y no produce nada que perdure**, y cuyo volumen crece con el servicio. El trabajo desagradable que reduce permanentemente el trabajo futuro es ingeniería.

**A7.5** — Al manager:

> Las dos cosas son ciertas — la automatización funcionó, y el toil igual subió. La razón es que la automatización es sustractiva y el crecimiento es multiplicativo, y la multiplicación gana.
>
> El año pasado eliminamos alrededor del 30% del trabajo manual que teníamos. Pero el servicio creció cerca del 60%: más clientes, más servicios, más entornos, más incidentes, más pedidos de acceso. El toil escala con el tamaño del parque, así que un parque 60% más grande genera 60% más de toil, y nosotros solo eliminamos el 30%. Neto, retrocedimos — de 35% a 39% — aunque cada proyecto de automatización fue exitoso.
>
> La proyección muestra que cruzamos el 50% alrededor del año cuatro. Eso importa porque pasado el 50%, el equipo pasa la mayor parte de su tiempo en trabajo manual, lo que significa menos tiempo automatizando, lo que significa que el toil crece más rápido al año siguiente. Es un bucle de realimentación, y termina con un equipo de operaciones sin capacidad para hacer otra cosa que operar.
>
> Así que el pedido no es "automatizar más" como aspiración — es un **tope duro al toil en el 50% del tiempo del equipo**, con el resto protegido para ingeniería que reduzca el toil futuro. Esa mitad protegida es lo que impide que la curva se dispare. Concretamente: la automatización tiene que superar al crecimiento, no simplemente existir.

**A7.6** — Un postmortem es blameless cuando analiza **qué permitió el sistema** en vez de **quién actuó**. Los mismos hechos, distinto encuadre: no "Ana borró el binding de IAM" sino "un único comando sin revisión podía quitar el acceso público de un servicio de producción, y no existía guardrail ni canary que lo atrapara". La persona es un participante de la línea de tiempo, no su sujeto; las preguntas son qué información tenía, qué le hacía fácil el tooling, y qué habría hecho de la acción correcta el comportamiento por defecto.

El beneficio concreto de ingeniería — no el emocional:

**Los postmortems blameless son los únicos que obtienen información precisa.** En una cultura de culpa, la gente más cercana al incidente tiene un incentivo directo a minimizar, demorar, omitir y matizar. Reportan la caída más tarde, la describen de forma vaga, y omiten el detalle que los hace ver descuidados — que muy a menudo es el detalle que identifica la falla sistémica. Perdés los datos, así que arreglás lo equivocado, así que el incidente se repite con el nombre de otra persona.

Hay un segundo beneficio, igualmente práctico: los postmortems con culpa producen elementos de acción inútiles. "Ser más cuidadosos", "agregar una sesión de capacitación", "recordarle al equipo" — nada de eso cambia el sistema, y todo eso falla la próxima vez que alguien esté cansado a las 03:00. El análisis blameless fuerza elementos de acción que son *estructurales*: una política que bloquea el comando, una revisión obligatoria, un canary, un mensaje de error mejor. Solo esos previenen la recurrencia realmente.

La premisa de fondo es el supuesto SRE de que **las personas actúan razonablemente dadas la información y las herramientas disponibles**. Si un ingeniero competente causó una caída con un comando, el hallazgo es sobre el comando.

**A7.7** — La práctica es el **despliegue canary** (una forma de **entrega progresiva**, junto con blue/green y traffic splitting; Cloud Run lo implementa de forma nativa vía tags de revisión y `update-traffic`).

Reduce la **tasa de fallo de cambios** al achicar el radio de impacto *y* al convertir a producción en una etapa de detección. Solo el 10% del tráfico toca la revisión nueva, así que un defecto afecta al 10% de los usuarios en vez del 100% — y, más importante, podés comparar los SLIs de la revisión canary contra los de la estable sobre tráfico real antes de promoverla. Muchos defectos que ningún entorno de staging revelaría (formas de datos reales, concurrencia real, dependencias reales) se atrapan acá. Según cómo defina la organización la métrica, un canary atrapado y revertido es o bien un fallo mucho más chico, o directamente no es un fallo de producción.

Reduce el **tiempo de recuperación de un despliegue fallido** porque la recuperación es un cambio de peso de tráfico, no una recompilación ni un redespliegue. La revisión anterior sigue corriendo y sigue sana; mover el 100% del tráfico de vuelta a ella toma segundos y no requiere diagnóstico, ni build de imagen, ni entender la causa raíz. Compará eso con un rollback convencional, donde recompilás un artefacto, lo redesplegás, y esperás a que las instancias estén sanas — minutos en el mejor caso, y solo después de que alguien haya decidido qué salió mal.

El efecto compuesto es el verdadero premio: cableá la promoción del canary a una **verificación automatizada de burn rate del SLO**, y tanto la detección como el rollback dejan de requerir un humano en absoluto. Ese es el vínculo práctico entre la maquinaria de SLO de los Ejercicios 2–4 y las métricas de entrega de acá — el error budget deja de ser un reporte y se convierte en una entrada de control del pipeline de despliegue.

---

## Ejercicio 8 — Capstone

**A8.1**

| Ítem | Respuesta | Justificación |
|---|---|---|
| **SLI de disponibilidad** | Proporción de peticiones HTTP a la API de turnos que devuelven no-`5xx`, medida en el balanceador de carga, sobre peticiones válidas (excluyendo errores de cliente `4xx` y health probes) | Medido en el LB, no en la app, para que capture fallos del camino mismo — la lección del paso 9 |
| **SLI de latencia** | Proporción de peticiones de reserva de turno completadas en < 1000 ms | Expresado como ratio, no como percentil, para que componga en un error budget. La reserva es el camino crítico del usuario; la navegación puede tener un objetivo más laxo |
| **SLO** | **99.9%** de disponibilidad, ventana móvil de 30 días; **99%** de las reservas bajo 1000 ms | 99.9% es un paso significativo por encima del 99.72% medido — alcanzable en un trimestre, y el trimestre pasado se habría incumplido, así que crea presión real. Ver A8.3 sobre por qué no 99.99% |
| **Error budget** | **43,2 min / 30 días** | (1 − 0,999) × 43.200. Para dimensionar: la caída *más chica* del trimestre pasado (52 min) por sí sola habría agotado el presupuesto de un mes completo |
| **RTO** | **30 minutos** | El tráfico es de 08:00 a 20:00, así que una caída siempre tiene usuarios. 30 min es lo bastante agresivo como para forzar automatización, y alcanzable con una arquitectura regional y un failover ensayado |
| **RPO** | **~0 (segundos)** | Innegociable y fijado por el regulador: los registros de turnos no se pueden perder. Esto obliga a replicación síncrona o casi síncrona, no a backups nocturnos |
| **Arquetipo de despliegue** | **Regional** (multi-zona dentro de `southamerica-east1`), con un camino documentado de DR multirregional | Regional elimina toda la clase de punto único de fallo zonal a costo moderado. Multirregional pleno es el paso siguiente, no el primero — ver A8.2 |
| **Patrón de DR** | **Warm standby** en una segunda región, con replicación continua | Satisface RPO ≈ 0 vía replicación y RTO ≈ 30 min vía un stack reducido corriendo. Hot standby no está justificado por el impacto de negocio de una caída de turnos de 30 minutos |

**A8.2** — Orden de prioridad, con la caída que cada cambio atiende:

1. **Pasar a una arquitectura regional (multi-zona)** — MIG en ≥ 3 zonas detrás de un balanceador de carga regional con health checks, más una configuración **HA de Cloud SQL** (standby síncrono en una segunda zona) con failover automático. Esto elimina todos los modos de fallo de zona única en un solo cambio y es la mayor ganancia de disponibilidad disponible. También lleva el RPO a ~0 para el caso de fallo de zona.
2. **Definir el SLO y el error budget, e instrumentar los SLIs** — gratis, inmediato, y es el prerrequisito de toda decisión posterior, incluida la de si algo de esto funcionó. Sin eso el equipo está discutiendo opiniones.
3. **Reemplazar las alertas por umbral de CPU con alertas de burn rate del SLO** — ver A8.4. También gratis, y arregla la patología de 80 alertas por semana que hoy está inflando el MTTD de los incidentes reales.
4. **Habilitar point-in-time recovery en Cloud SQL y correr un simulacro de restauración** — medir el RTO *real* en vez de asumirlo. La caída de 210 minutos sugiere fuertemente que la recuperación es manual y no ensayada.
5. **Autoscaling dimensionado para el pico 8× de los lunes** — con margen y un máximo probado. Una caída por capacidad es probable entre las tres, dado el perfil de tráfico.
6. **CI/CD con despliegue canary y rollback automático por burn rate** — ataca el fallo inducido por cambios, contra el cual la arquitectura actual no tiene defensa alguna.
7. **Warm standby en una segunda región** — último, porque es lo más caro y protege contra la clase de fallo más rara. Hacerlo antes de los pasos 1–3 sería pagar redundancia regional mientras una sola zona todavía puede tumbarte.

**Mayor mejora por dólar: el paso 1 (regional/multi-zona).** Es un cambio de configuración y topología en vez de un entorno nuevo, aproximadamente un incremento moderado de costo, y elimina la clase de fallo que con más probabilidad explica la caída de 210 minutos. Los pasos 2 y 3 no cuestan prácticamente nada y deberían hacerse en paralelo — pero mejoran el *conocimiento*, no la disponibilidad, así que el paso 1 es la respuesta a la pregunta tal como fue formulada.

**A8.3** — **No. 99.99% es el objetivo equivocado, y la brecha no es marginal.**

Los números: la disponibilidad medida es **99,72%**. Un SLO de 99.99% permite **4,32 minutos por cada 30 días** — unos 13 minutos por trimestre. El downtime del trimestre pasado fue de **357 minutos**, aproximadamente **27×** ese presupuesto. Incluso la caída individual *más corta*, de 52 minutos, habría volado doce veces un presupuesto trimestral de 99.99%. Y 99.99% significa que una caída total debe ser detectada, diagnosticada y completamente recuperada en **menos de cuatro minutos**, siempre, lo que descarta cualquier camino de recuperación que involucre una decisión humana.

Alcanzarlo requeriría multirregión activo-activo con replicación síncrona, failover completamente automatizado, despliegues sin downtime, y guardia 24/7 con dotación — una reconstrucción, no una mejora, y un incremento permanente de costo muy por encima de lo que una plataforma regional de turnos puede justificar.

También hay un argumento de gobernanza: adoptar un objetivo que se incumple por 27× produce un SLO permanentemente incumplido. Un SLO permanentemente incumplido dispara un feature freeze permanente, que el negocio va a anular de inmediato, lo que destruye la autoridad del mecanismo de error budget antes de que se lo haya usado siquiera una vez. **Un objetivo que nadie puede cumplir es peor que no tener objetivo**, porque además desacredita el marco.

**Qué proponer en su lugar:** comprometerse a **99.9%** para los próximos dos trimestres — una reducción de ~3,5× del downtime, lograda con los pasos 1–5 de arriba, genuinamente alcanzable, y suficiente para volver imposible el patrón de incidentes del trimestre pasado. Reportar contra eso mensualmente con datos reales. Después, con dos trimestres de evidencia medida en mano, revisar si 99.95% vale su costo incremental. Presentarlo al directorio en sus términos: *"Nos comprometemos a recortar el downtime en aproximadamente tres cuartos este trimestre con un cambio que podemos entregar ahora, y les vamos a mostrar la medición todos los meses — en vez de comprometernos a un número que incumpliríamos en la primera semana."*

**A8.4** — Reemplazar los umbrales de CPU por **alertas multi-ventana, multi-burn-rate sobre los SLOs de disponibilidad y latencia** (Ejercicio 2, paso 4): un **page** a 14.4× sobre 1 h con ventana corta de 5 minutos, un **page** a 6× sobre 6 h con ventana corta de 30 minutos, y un **ticket** a 1× sobre 3 días. Agregar un **uptime check** de caja negra con sondeos multirregión como red de contención para los fallos fuera de la aplicación (DNS, TLS, LB, IAM), y mantener las métricas de recursos — CPU, memoria, pool de conexiones, retraso de réplica — en **dashboards** para diagnóstico, más un puñado pequeño de tickets genuinos de capacidad. Nada que no sea visible para el usuario paginará.

Por qué esto produce alertas menos numerosas y mejores:

- **La CPU es una causa, no un síntoma, y es mala.** CPU alta durante el pico 8× de los lunes es el sistema funcionando correctamente. CPU baja durante una caída total es exactamente lo que parece un servicio que dejó de recibir tráfico. La correlación entre CPU y dolor de usuario es débil en ambas direcciones, y por eso exactamente 56 de 60 alertas no son accionables — la métrica está midiendo lo equivocado, así que ningún ajuste de umbral puede arreglarlo.
- **Las alertas de burn rate son, por construcción, proporcionales al daño al usuario.** Se disparan cuando los usuarios están efectivamente experimentando fallos a un ritmo suficiente para amenazar el compromiso, y no se disparan en caso contrario. Cada page corresponde a presupuesto real consumido, así que actuar sobre él siempre está justificado — que es lo que significa "accionable".
- **La ventana corta suprime la clase de ruido de la que están hechos los umbrales de CPU** — picos transitorios, despliegues, reinicios de una sola instancia — porque un microcorte no puede incumplir simultáneamente una ventana de 1 hora.
- **La severidad se deriva en vez de adivinarse.** La quema rápida despierta a alguien; la quema lenta crea un ticket para el horario laboral. Bajo umbrales de CPU toda alerta tiene la misma urgencia indiferenciada, y por eso todas terminan siendo tratadas como ruido.

El efecto de segundo orden es el que hay que enunciarle al equipo: pasar de ~80 alertas a un puñado restaura la confianza en el pager, y la confianza restaurada es lo que realmente reduce el MTTD del próximo incidente real. El flujo actual de 80 alertas no es solo molesto — es un contribuyente medible a la caída de 210 minutos.

**A8.5** — El sistema de registro on-premises **cambia la consecuencia de la pérdida de datos, no el requisito de RPO en sí.**

Qué cambia: si cada escritura de turno también aterriza on-premises, entonces una pérdida de datos del lado de la nube es *recuperable por reconciliación* en vez de permanente. Eso reclasifica el fallo de "incidente regulatorio" a "procedimiento de recuperación", y significa que la base de datos en la nube puede legítimamente tratarse como una réplica de un almacén autoritativo en vez de como la única fuente de verdad. En términos de DR puede justificar un patrón más barato del lado de la nube — estás protegiendo disponibilidad y tiempo de recuperación más que la existencia de los datos.

De qué **no** te exime:

1. **Probar que la escritura dual es efectivamente atómica y completa.** Si la aplicación escribe a Cloud SQL y a on-prem como dos operaciones independientes, existe una ventana donde una tiene éxito y la otra no — y esa ventana es tu RPO real, sin importar lo que afirme el diagrama de arquitectura. Sin un transactional outbox, una cola durable, o una garantía equivalente, "también está on-prem" es un supuesto, no un control.
2. **La reconciliación tiene que estar construida, automatizada y probada.** Una copia de los datos que ninguna herramienta puede comparar, diferenciar y reproducir no es un camino de recuperación. Si el procedimiento es "alguien escribe un script durante el incidente", tu RTO ahora incluye escribir ese script bajo presión.
3. **El RTO no se ve afectado.** Tener los datos en otro lado no hace nada por cuánto tiempo está caído el servicio. Los pacientes no pueden reservar turnos durante la caída, sobrevivan o no los registros.
4. **El sistema on-premises ahora es una dependencia, y tiene su propia disponibilidad.** Si es un único datacenter con sus propios modos de fallo, no eliminaste el riesgo — moviste parte de él a un entorno con menos redundancia que la región de nube, y que está fuera del marco de SLO que acabás de construir. Necesita su propio backup, su propio plan de DR, y su propia medición.
5. **El requisito del regulador es sobre el registro, no sobre un sistema específico.** Igual tenés que poder demostrar — con evidencia de un simulacro, no de un diagrama — que ningún registro de turno se puede perder.

La conclusión arquitectónica correcta: mantener **RPO ≈ 0 como requisito**, pero notar que ahora puede satisfacerse mediante la *combinación* de replicación en la nube y reconciliación on-prem verificada, en vez de por replicación síncrona multirregión sola. Ese es un ahorro de costo legítimo — siempre que la verificación sea real.

</details>

---

## Fuentes

- **Guía del examen:** [Cloud Digital Leader Exam Guide (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)
- **SRE Book — Service Level Objectives:** https://sre.google/sre-book/service-level-objectives/
- **SRE Book — Monitoring Distributed Systems (señales doradas):** https://sre.google/sre-book/monitoring-distributed-systems/
- **SRE Book — Eliminating Toil:** https://sre.google/sre-book/eliminating-toil/
- **SRE Book — Managing Incidents:** https://sre.google/sre-book/managing-incidents/
- **SRE Book — Postmortem Culture:** https://sre.google/sre-book/postmortem-culture/
- **SRE Workbook — Alerting on SLOs (burn rate):** https://sre.google/workbook/alerting-on-slos/
- **Arquetipos de despliegue de Google Cloud:** https://cloud.google.com/architecture/deployment-archetypes
- **Guía de planificación de recuperación ante desastres:** https://cloud.google.com/architecture/disaster-recovery
- **Well-Architected Framework — pilar de confiabilidad:** https://cloud.google.com/architecture/framework/reliability
- **Monitoreo de SLO en Cloud Monitoring:** https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- **Uptime checks:** https://cloud.google.com/monitoring/uptime-checks
- **Métricas basadas en logs:** https://cloud.google.com/logging/docs/logs-based-metrics
- **Cloud Run — rollbacks, despliegues graduales y migración de tráfico:** https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration
- **Cloud SQL — point-in-time recovery:** https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr
- **Acuerdos de nivel de servicio de Google Cloud:** https://cloud.google.com/terms/sla
- **DORA — DevOps Research and Assessment:** https://dora.dev/