# Tema 3.4 — Push vs Pull: Ejercicios Guiados

> **Dominio del examen:** Prometheus Fundamentals · **Referencia:** [PCA Curriculum](https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf)
>
> Estos labs demuestran, con procesos reales y tráfico HTTP real, *por qué* Prometheus es un sistema **basado en pull**, qué te da eso (liveness del target, debugging ad-hoc, configuración centralizada), dónde se rompe (jobs de vida corta, targets inalcanzables) y cómo el **Pushgateway** cubre la brecha sin convertir a Prometheus en un sistema push. También verás los dos lugares donde Prometheus mismo hace push: `remote_write` e, indirectamente, el Pushgateway.

---

## Prerrequisitos y preparación del entorno (Ejercicio 0)

Necesitás `docker`, `docker compose`, `curl` y `jq`. Todo lo de abajo corre localmente; nada sale de tu máquina.

**Paso 0.1 — Creá el directorio de trabajo y la config de Prometheus.**

```bash
mkdir -p pca-3.4-push-pull && cd pca-3.4-push-pull
```

Creá `prometheus.yml`:

```yaml
global:
  scrape_interval: 15s      # how often Prometheus pulls each target
  scrape_timeout: 10s       # must be <= scrape_interval

scrape_configs:
  # Prometheus scraping itself — the canonical pull example
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # A long-lived, always-on target: the textbook pull case
  - job_name: node
    static_configs:
      - targets: ["node-exporter:9100"]

  # The Pushgateway. honor_labels is REQUIRED here — see Exercise 4.
  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ["pushgateway:9091"]
```

**Paso 0.2 — Creá `docker-compose.yml`.**

```yaml
services:
  prometheus:
    image: prom/prometheus:v2.53.1
    ports: ["9090:9090"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml

  node-exporter:
    image: prom/node-exporter:v1.8.2
    ports: ["9100:9100"]

  pushgateway:
    image: prom/pushgateway:v1.10.0
    ports: ["9091:9091"]
```

**Paso 0.3 — Levantá el stack y confirmá que los tres están corriendo.**

```bash
docker compose up -d
docker compose ps
```

Esperado (abreviado):

```
NAME             IMAGE                          STATUS         PORTS
node-exporter    prom/node-exporter:v1.8.2      Up 5 seconds   0.0.0.0:9100->9100/tcp
prometheus       prom/prometheus:v2.53.1        Up 5 seconds   0.0.0.0:9090->9090/tcp
pushgateway      prom/pushgateway:v1.10.0       Up 5 seconds   0.0.0.0:9091->9091/tcp
```

**Preguntas**

- **Q0.1** En esta topología, ¿qué proceso abre la conexión TCP cuando se recolecta una métrica de `node-exporter` — Prometheus o el exporter?
- **Q0.2** `node-exporter` no tiene ninguna configuración que le diga dónde vive Prometheus. ¿Cómo es eso posible, y qué implica sobre *quién es dueño del calendario de recolección*?

---

## Ejercicio 1 — Observá el modelo pull en acción

**Objetivo:** ver que "scraping" no es nada más exótico que Prometheus emitiendo un HTTP `GET /metrics` según un calendario que vos controlás.

**Paso 1.1 — Sé Prometheus por un momento. Hacé el pull del exporter vos mismo:**

```bash
curl -s http://localhost:9100/metrics | grep -E '^node_cpu_seconds_total' | head -3
```

Esperado (los valores varían):

```
node_cpu_seconds_total{cpu="0",mode="idle"} 48213.44
node_cpu_seconds_total{cpu="0",mode="system"} 611.28
node_cpu_seconds_total{cpu="0",mode="user"} 1875.02
```

**Paso 1.2 — Confirmá que el exporter es un servidor HTTP común sin memoria de vos:**

```bash
curl -s -o /dev/null -w "status=%{http_code} method=GET\n" http://localhost:9100/metrics
```

Esperado:

```
status=200 method=GET
```

**Paso 1.3 — Ahora dejá que Prometheus haga lo mismo en su intervalo. Consultá la señal de salud del scrape que sintetiza para cada target:**

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq -r '.data.result[] | "\(.metric.job)\t\(.metric.instance)\tup=\(.value[1])"'
```

Esperado:

```
node          node-exporter:9100    up=1
prometheus    localhost:9090        up=1
pushgateway   pushgateway:9091      up=1
```

**Paso 1.4 — Observá los metadatos que Prometheus adjunta a *cada* scrape (los genera el que hace el pull, no el target):**

```bash
curl -s 'http://localhost:9090/api/v1/query?query=scrape_duration_seconds{job="node"}' | jq -r '.data.result[0].value[1]'
```

Esperado (segundos):

```
0.011473
```

**Paso 1.5 — Cambiá quién controla la cadencia. Editá `prometheus.yml`, sobreescribí el intervalo solo para el job `node`:**

```yaml
  - job_name: node
    scrape_interval: 5s        # <-- per-job override, faster than the 15s global
    static_configs:
      - targets: ["node-exporter:9100"]
```

Recargá sin reiniciar (Prometheus soporta recarga de config estilo SIGHUP por HTTP si se arranca con `--web.enable-lifecycle`; acá simplemente reiniciamos el contenedor):

```bash
docker compose restart prometheus
```

**Preguntas**

- **Q1.1** Los pasos 1.1 y 1.3 golpean el *mismo* endpoint. ¿Qué te dice eso sobre cuán debuggeable es un target pull comparado con un pipeline push?
- **Q1.2** `up`, `scrape_duration_seconds` y `scrape_samples_scraped` no aparecen en la salida `/metrics` del exporter. ¿De dónde vienen y por qué solo un *puller* puede producirlas?
- **Q1.3** En el Paso 1.5 cambiaste la frecuencia de scrape para `node` sin tocar `node-exporter`. En un sistema push, ¿dónde viviría esa perilla, y por qué es operacionalmente peor a escala?

---

## Ejercicio 2 — El pull te da liveness gratis

**Objetivo:** demostrar que el modelo pull detecta un target muerto de forma *inherente*, y que esta es una propiedad que las arquitecturas push deben reimplementar.

**Paso 2.1 — Matá el target mientras Prometheus sigue intentando alcanzarlo:**

```bash
docker compose stop node-exporter
```

**Paso 2.2 — Esperá un intervalo de scrape, luego volvé a consultar `up`:**

```bash
sleep 20
curl -s 'http://localhost:9090/api/v1/query?query=up{job="node"}' | jq -r '.data.result[0] | "up=\(.value[1])"'
```

Esperado:

```
up=0
```

**Paso 2.3 — Inspeccioná *por qué* falló el scrape (Prometheus registra la causa de la falla):**

```bash
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job=="node") | "health=\(.health) lastError=\(.lastError)"'
```

Esperado (el texto del mensaje varía según la plataforma):

```
health=down lastError=Get "http://node-exporter:9100/metrics": dial tcp: connect: connection refused
```

**Paso 2.4 — Esto es exactamente de lo que se agarra una alerta de producción. La regla clásica:**

```yaml
groups:
  - name: liveness
    rules:
      - alert: TargetDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }} target {{ $labels.instance }} is down"
```

**Paso 2.5 — Traelo de vuelta y confirmá la recuperación:**

```bash
docker compose start node-exporter
sleep 20
curl -s 'http://localhost:9090/api/v1/query?query=up{job="node"}' | jq -r '.data.result[0].value[1]'
```

Esperado:

```
1
```

**Preguntas**

- **Q2.1** Prometheus nunca recibió un "adiós" del exporter. ¿Cómo concluyó que el target estaba caído dentro de un intervalo?
- **Q2.2** En un sistema push puro, una aplicación que muere simplemente *deja de enviar*. ¿Por qué "ausencia de datos" es una señal de falla estrictamente más débil y más ambigua que `up == 0`?
- **Q2.3** Nombrá dos razones *no relacionadas con fallas* por las cuales una aplicación podría dejar de hacer push produciendo el mismo síntoma de "sin datos", y explicá por qué el modelo pull es inmune a la ambigüedad.

---

## Ejercicio 3 — Donde el pull se rompe: el job batch de vida corta

**Objetivo:** experimentar el único problema que el pull no puede resolver por sí solo, lo que motiva al Pushgateway.

**Paso 3.1 — Simulá un job de backup nocturno: arranca, hace trabajo, registra un resultado y sale en menos de un segundo.** Expone métricas solo mientras está vivo:

```bash
docker run --rm --network pca-34-push-pull_default python:3.12-slim sh -c '
  echo "backup ran, exit code 0";  # the whole process lives ~0.3s and is gone
'
```

Esperado:

```
backup ran, exit code 0
```

**Paso 3.2 — Intentá hacer que Prometheus scrapee un job así.** Con `scrape_interval: 15s`, la probabilidad de que el job esté siquiera *vivo* durante un scrape es minúscula, y su endpoint de red desaparece cuando sale. No hay un `instance` estable del cual hacer pull.

Razonalo en lugar de configurarlo: un target que existe por 300 ms no puede ser alcanzado de forma confiable por un poller de 15 s, y para cuando una alerta se dispararía sobre `up == 0`, el job *se suponía* que ya no estaba.

**Paso 3.3 — Enumerá los dos desajustes estructurales** (escribilos antes de mirar las respuestas):

1. **Duración de vida (Lifetime):** la vida del job es más corta que el intervalo de scrape.
2. **Direccionabilidad (Addressability):** el job no tiene una dirección de red de larga vida y descubrible desde la cual hacer pull.

**Preguntas**

- **Q3.1** Para un *servicio* (servidor web, base de datos) que vive por semanas, ¿por qué el pull es el ajuste natural? ¿Cuál de los dos desajustes de arriba simplemente no ocurre?
- **Q3.2** ¿Acortar `scrape_interval` a 1 s arreglaría el problema del job batch? Explicá qué resolvería y qué no.
- **Q3.3** ¿Qué único dato sobre un job de backup querés más que sobreviva a la muerte del job — un valor que no podés capturar con pull porque la fuente ya no está?

---

## Ejercicio 4 — El Pushgateway: push adentro, pull afuera

**Objetivo:** usar el Pushgateway correctamente, entender que es un *caché de métricas* que Prometheus todavía **hace pull**, e internalizar sus tres aristas filosas: `honor_labels`, staleness y liveness perdido.

**Paso 4.1 — Hacé push del resultado de un job batch como lo haría un job real, desde un hook de shell:**

```bash
cat <<'EOF' | curl --data-binary @- http://localhost:9091/metrics/job/backup/instance/db01
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds 1754640000
# TYPE backup_duration_seconds gauge
backup_duration_seconds 42.7
# TYPE backup_records_processed gauge
backup_records_processed 1875002
EOF
```

El path de la URL `/metrics/job/backup/instance/db01` es la **grouping key**: se convierte en las labels `job` e `instance` en cada serie pusheada. Se requiere una nueva línea final — `cat`/`echo` la proveen. Devuelve HTTP 200 con un body vacío.

**Paso 4.2 — Leé el propio `/metrics` del Pushgateway (esto es lo que Prometheus va a hacer pull):**

```bash
curl -s http://localhost:9091/metrics | grep -E 'backup_|push_time_seconds' 
```

Esperado:

```
backup_duration_seconds{instance="db01",job="backup"} 42.7
backup_last_success_timestamp_seconds{instance="db01",job="backup"} 1.754640000e+09
backup_records_processed{instance="db01",job="backup"} 1875002
push_time_seconds{instance="db01",job="backup"} 1.7546401e+09
push_failure_time_seconds{instance="db01",job="backup"} 0
```

Notá `push_time_seconds` — el Pushgateway lo sintetiza por grupo. Es tu único punto de agarre sobre la *frescura* (ver Paso 4.6).

**Paso 4.3 — Confirmá que Prometheus hizo pull de los datos pusheados con la label de job original intacta:**

```bash
sleep 20
curl -s 'http://localhost:9090/api/v1/query?query=backup_records_processed' \
  | jq -r '.data.result[0] | "job=\(.metric.job) instance=\(.metric.instance) value=\(.value[1])"'
```

Esperado:

```
job=backup instance=db01 value=1875002
```

**Paso 4.4 — Demostrá por qué importa `honor_labels: true`.** Quitá temporalmente `honor_labels` de la config de scrape del `pushgateway`, reiniciá Prometheus y volvé a consultar:

```bash
# after editing prometheus.yml to drop honor_labels, then:
docker compose restart prometheus && sleep 20
curl -s 'http://localhost:9090/api/v1/query?query=backup_records_processed' \
  | jq -r '.data.result[0].metric | "job=\(.job) exported_job=\(.exported_job) instance=\(.instance)"'
```

Esperado **sin** `honor_labels`:

```
job=pushgateway exported_job=backup instance=pushgateway:9091
```

Restaurá `honor_labels: true` y reiniciá antes de continuar.

**Paso 4.5 — Descubrí la salvedad de liveness.** Consultá `up` y notá *qué* cosa describe:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{job="backup"}' | jq '.data.result'
curl -s 'http://localhost:9090/api/v1/query?query=up{job="pushgateway"}' | jq -r '.data.result[0].value[1]'
```

Esperado:

```
[]        # there is NO up series for the backup job
1         # up only exists for the Pushgateway itself
```

**Paso 4.6 — Descubrí la salvedad de staleness.** El job hizo push una vez y salió. Esperá, luego volvé a leer Prometheus — el valor *sigue ahí, sin cambios, y parece fresco* porque Prometheus vuelve a scrapear la misma muestra cacheada en cada intervalo:

```bash
sleep 30
curl -s 'http://localhost:9090/api/v1/query?query=backup_records_processed' | jq -r '.data.result[0].value[1]'
```

Esperado (idéntico a antes — ningún backup nuevo corrió, pero la serie está "actual"):

```
1875002
```

La alerta correcta es, por lo tanto, sobre la **edad**, no sobre `up`:

```yaml
- alert: BackupStale
  expr: time() - backup_last_success_timestamp_seconds > 86400
  # or, using the gateway's own signal:
  # expr: time() - push_time_seconds{job="backup"} > 86400
  for: 10m
  annotations:
    summary: "No successful backup for db01 in over 24h"
```

**Paso 4.7 — Limpiá el grupo (el gateway nunca olvida por sí solo):**

```bash
curl -X DELETE http://localhost:9091/metrics/job/backup/instance/db01
curl -s http://localhost:9091/metrics | grep -c 'backup_records_processed'
```

Esperado:

```
0
```

**Preguntas**

- **Q4.1** Después del Paso 4.1, ¿el dato fluye "job → Prometheus" o "job → Pushgateway → Prometheus"? ¿Qué salto es push y cuál es pull, y sigue siendo Prometheus un sistema pull?
- **Q4.2** En el Paso 4.4, sin `honor_labels`, el `job="backup"` pusheado se convirtió en `exported_job="backup"` y la serie quedó etiquetada como `job="pushgateway"`. Explicá la regla de conflicto de labels que produce esto, y por qué la federación y el scraping del Pushgateway específicamente necesitan `honor_labels: true`.
- **Q4.3** En el Paso 4.5, `up{job="backup"}` no devolvió nada. Explicá con precisión qué *garantiza* y qué *no garantiza* `up{job="pushgateway"}=1` sobre tus backups.
- **Q4.4** En el Paso 4.6 la serie parecía fresca para siempre. ¿Por qué pasa esto mecánicamente, y por qué `time() - push_time_seconds` es la señal correcta de staleness en lugar de `up == 0`?
- **Q4.5** La documentación del Pushgateway advierte que "no es una manera de convertir a Prometheus en un sistema basado en push" y "no es un agregador". Si diez corridas de backup hacen push a la *misma* grouping key, ¿qué pasa con los valores anteriores, y qué te dice eso sobre cómo diseñar la grouping key?

---

## Ejercicio 5 — La otra dirección: Prometheus mismo hace push (`remote_write`)

**Objetivo:** evitar el malentendido común de que "Prometheus solo hace pull". *Recolecta* por pull pero puede *reenviar* por push, y conocer la distinción es relevante para el examen.

**Paso 5.1 — Razoná sobre el camino del dato.** `remote_write` hace que un servidor Prometheus transmita las muestras que ya scrapeó a un endpoint remoto (Grafana Mimir, Thanos Receive, Cortex, VictoriaMetrics) por HTTP. Forma de la configuración:

```yaml
remote_write:
  - url: "https://mimir.example.com/api/v1/push"
    queue_config:
      capacity: 10000
      max_shards: 50
      max_samples_per_send: 2000
    metadata_config:
      send: true
```

No necesitás un receptor en vivo para este ejercicio — leé la config y respondé las preguntas.

**Paso 5.2 — Ubicá cada mecanismo en el eje push/pull.** Completá la tabla (respuestas más abajo):

| Mecanismo | Prometheus recolecta por… | Prometheus reenvía por… |
|---|---|---|
| Scrapear node-exporter | ? | — |
| Pushgateway | pull (desde el gateway) | — |
| `remote_write` | pull (localmente) | ? |
| Receiver `prometheus` del OpenTelemetry Collector | ? | — |

**Preguntas**

- **Q5.1** La ingesta (meter métricas *dentro* de Prometheus) y el envío (sacarlas *hacia* almacenamiento de largo plazo) están en lados opuestos del eje push/pull. Indicá cuál es cuál y por qué el modelo pull para la ingesta no se ve afectado por usar `remote_write`.
- **Q5.2** Un compañero de equipo dice "nos salteamos el scraping y hacemos que cada app haga `remote_write` directo a nuestro Prometheus central, estilo push". ¿Qué garantías centrales de los Ejercicios 1–2 perdés, y cuándo se justifica igualmente ese trade-off (pista: pensá en NAT, serverless, edge)?
- **Q5.3** Según el propio encuadre de la Prometheus FAQ, ¿es el pull *fundamentalmente* superior al push, o es un ajuste para el modelo operativo de Prometheus? Dá una ventaja concreta de cada uno de los labs de arriba.

---

## Desmontaje

```bash
docker compose down
```

---

## Respuestas

<details>
<summary>Hacé clic para revelar todas las respuestas</summary>

**Q0.1** Prometheus abre la conexión. En un modelo pull el *servidor de monitoreo* es el cliente HTTP; emite `GET /metrics` hacia el target. El exporter es un servidor HTTP pasivo que solo responde.

**Q0.2** El exporter es stateless respecto del monitoreo: solo expone `/metrics` y le responde a quien pregunte. El calendario de recolección (intervalo, timeout, qué targets, relabeling, service discovery) vive enteramente del lado de Prometheus. Implicación: *el que hace pull es dueño del calendario*, así que podés agregar/quitar servidores Prometheus, correr un segundo para staging, cambiar intervalos, o hacerle curl al target a mano — todo sin tocar ni coordinar con el workload.

**Q1.1** Ambos golpean `GET /metrics`, así que un target pull es trivialmente debuggeable: cualquier persona o script puede reproducir *exactamente* lo que ve Prometheus con un solo `curl`, sin agente especial, credenciales, ni reproducción de un push stream. En un pipeline push solo podés inspeccionar lo que la app decidió emitir, después de que se fue, donde sea que haya aterrizado.

**Q1.2** Son **muestras sintéticas generadas por Prometheus en el momento del scrape**, no expuestas por el target. `up` es 1 si el scrape (conexión + HTTP 200 + parse) tuvo éxito y 0 en caso contrario; `scrape_duration_seconds` y `scrape_samples_scraped` describen el evento de scrape. Solo la parte que realiza el scrape puede medir si funcionó y cuánto tardó — una muestra pusheada no lleva ninguna señal equivalente de "¿tuvo éxito la recolección?".

**Q1.3** En un sistema push la cadencia vive *dentro de cada aplicación/agente* (el intervalo de push es del lado del cliente). Cambiarla significa reconfigurar y redesplegar N workloads en lugar de editar una config de un servidor. A escala eso es un rollout de toda la flota versus un cambio central de una línea; también hace imposible que el equipo de monitoreo estrangule la carga unilateralmente durante un incidente.

**Q2.1** Prometheus intentó su `GET /metrics` programado y el connect TCP fue rechazado (proceso del target desaparecido). Un scrape fallido deja `up=0` de forma determinista para ese intervalo. El liveness es un efecto secundario de *intentar activamente hacer pull*: el propio acto de recolección es también el health check.

**Q2.2** Con push, una app muerta simplemente deja de enviar, así que inferís la falla por **ausencia de datos** — pero la ausencia es ambigua. Podría significar que la app murió, que la red se cayó, que el push agent crasheó, que cambió un firewall, que la app fue escalada a cero a propósito, o que simplemente está entre intervalos de push. `up == 0` es un booleano por target, sin ambigüedad y con timestamp, que dice "intenté alcanzar esta instancia específica ahora mismo y no pude".

**Q2.3** Ejemplos: (1) el servicio fue escalado a cero a propósito / está en medio de un deploy; (2) una partición de red o cambio de firewall entre la app y el backend de monitoreo; (3) el push agent del lado del cliente (no la app) crasheó mientras la app está bien; (4) la app está viva pero simplemente no llegó a su próximo tick de push. El pull es inmune porque Prometheus decide *cuándo* chequear y registra el éxito/falla de ese intento específico, distinguiendo "lo alcancé y está caído/mal configurado" de "no pude alcanzarlo", en lugar de fusionar todo en silencio.

**Q3.1** Un servicio de larga vida no viola *ninguno* de los desajustes: vive muchísimo más que el intervalo de scrape (así que está alcanzable de forma confiable durante los scrapes) y tiene una dirección de red estable y descubrible (así que hay un `instance` fijo del cual hacer pull). Esa es exactamente la forma para la que el pull fue diseñado.

**Q3.2** No. Un intervalo de 1 s reduce pero no elimina el desajuste de *lifetime* (un job de 300 ms igual puede perderse), y no hace nada por el desajuste de *addressability* — el job sigue sin un endpoint persistente para scrapear, y ya se fue antes del próximo tick. También multiplica la carga de scrape 15× en toda la flota para un caso para el cual el pull es estructuralmente erróneo.

**Q3.3** El **resultado/outcome de la corrida** — p. ej. timestamp de éxito, exit status, duración, registros procesados. Como el proceso sale, no queda ningún endpoint del cual hacer pull; el valor debe capturarse *en el momento de la finalización* y guardarse en algún lado durable (el Pushgateway) para que Prometheus lo haga pull más tarde.

**Q4.1** El flujo es **job → Pushgateway (push) → Prometheus (pull)**. El job hace push una vez al finalizar; Prometheus todavía hace *pull* del Pushgateway en su intervalo de scrape normal como cualquier otro target. Prometheus sigue siendo un sistema pull puro — el Pushgateway es solo un target que resulta cachear muestras pusheadas. No convierte a Prometheus en basado en push.

**Q4.2** Regla de conflicto de labels: cuando el dato scrapeado ya contiene una label que Prometheus adjuntaría del lado del servidor (como `job`/`instance`), `honor_labels: false` (el default) *renombra* la label scrapeada a `exported_<label>` y aplica el valor del lado del servidor — de ahí `job="pushgateway"`, `exported_job="backup"`. `honor_labels: true` mantiene las labels scrapeadas y descarta las del lado del servidor que entran en conflicto. La federación y el scraping del Pushgateway llevan las identidades de los targets *originales* dentro del payload, así que debés preservarlas — de lo contrario cada serie federada/pusheada quedaría mal etiquetada como si viniera del endpoint de federación o del gateway.

**Q4.3** `up{job="pushgateway"}=1` garantiza únicamente que **Prometheus puede alcanzar y scrapear el proceso del Pushgateway**. No dice nada sobre si algún backup corrió, tuvo éxito, o es reciente. No hay una serie `up` para `job="backup"` porque no se está scrapeando nada *del job de backup* — solo sus valores cacheados desde el gateway. El liveness del job original es exactamente lo que perdés cuando ruteás a través de un Pushgateway.

**Q4.4** El Pushgateway retiene el último valor pusheado indefinidamente, y Prometheus lo vuelve a scrapear en cada intervalo, acuñando una *nueva muestra con el mismo valor y un timestamp actual* cada vez — así que la serie nunca queda stale en Prometheus aunque el job corrió una vez y murió. `up == 0` nunca se dispara (el gateway está sano). La señal de frescura correcta es la *edad del dato en sí*: `time() - push_time_seconds{...}` (o un `*_last_success_timestamp_seconds` emitido por el job), que crece sin límite una vez que los pushes se detienen.

**Q4.5** Cada push a una grouping key dada **reemplaza** el contenido previo de ese grupo (el gateway es un caché/último-en-escribir-gana por grupo, no un agregador ni un log). Diez corridas pusheando al mismo `job/instance` dejan solo los valores de la décima corrida. Implicación de diseño: poné lo que deba permanecer distinto dentro de la grouping key (p. ej. un `instance` estable por host), y nunca confíes en que el gateway sume, promedie o retenga historia — no hace ninguna de esas cosas. Además, los grupos persisten hasta que se los `DELETE` explícitamente (o se pierden al reiniciar cuando `--persistence.file` no está seteado), así que los grupos stale deben limpiarse.

**Q5.2 tabla**

| Mecanismo | Prometheus recolecta por… | Prometheus reenvía por… |
|---|---|---|
| Scrapear node-exporter | **pull** | — |
| Pushgateway | pull (desde el gateway) | — |
| `remote_write` | pull (localmente) | **push** |
| Receiver `prometheus` del OTel Collector | **pull** (el Collector scrapea) | — |

**Q5.1** La *ingesta* (scrapear targets → TSDB local) es **pull**; el *envío* (`remote_write` → store remoto) es **push**. Son etapas independientes. Activar `remote_write` cambia solo cómo las muestras ya recolectadas salen de Prometheus; cada target se sigue scrapeando exactamente como antes, así que todas las garantías del lado pull (`up`, curl ad-hoc, calendario central) quedan intactas.

**Q5.2** Saltearse el scraping para que cada app haga `remote_write` directamente pierde: el liveness por target (`up`), la capacidad de reproducir la exposición de un target con `curl`, el control centralizado de la cadencia/relabeling, y la contrapresión/rate-limiting natural del servidor. Heredás las ambigüedades del push de la Q2.2. Se justifica igualmente cuando el pull es *imposible o poco práctico*: targets detrás de NAT/firewalls que Prometheus no puede alcanzar, workloads serverless/FaaS y edge/IoT sin un endpoint scrapeable estable, o jobs de CI efímeros — el mismo nicho que sirve el Pushgateway, a escala de ingesta.

**Q5.3** Ninguno es universalmente superior; el pull es un *ajuste* para el modelo de Prometheus (servidor dinámico, con service discovery, que se automonitorea y es dueño de su propia carga). Ventajas concretas vistas en los labs: el pull da liveness por target gratis (`up == 0`, Ej. 2) y reproducibilidad trivial (`curl /metrics`, Ej. 1); el push (vía Pushgateway) es la herramienta correcta exactamente donde el pull falla estructuralmente — jobs batch de vida corta sin endpoint scrapeable (Ej. 3–4).

</details>

---

### Fuentes

- Prometheus FAQ — *Why do you pull rather than push?*: https://prometheus.io/docs/introduction/faq/#why-do-you-pull-rather-than-push
- Prometheus best practices — *When to use the Pushgateway*: https://prometheus.io/docs/practices/pushing/
- Pushgateway project (grouping keys, DELETE API, persistence, "not an aggregator"): https://github.com/prometheus/pushgateway
- `scrape_config` reference (`honor_labels`, `scrape_interval`, `scrape_timeout`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
- Jobs & instances, the `up` metric and synthetic scrape samples: https://prometheus.io/docs/concepts/jobs_instances/
- `remote_write` tuning and semantics: https://prometheus.io/docs/practices/remote_write/