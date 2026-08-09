# PCA 3.5 — Service Discovery · Ejercicios guiados

> **Dominio:** Prometheus Fundamentals → Configuration and Scraping · **Peso en el examen:** 3
> **Objetivo:** aprender cómo Prometheus *convierte una fuente de verdad en un conjunto de scrape targets*. Todo mecanismo de discovery termina en el mismo lugar — un target group con un `__address__` y un puñado de labels `__meta_*` — que luego es remodelado por `relabel_configs` antes de que ocurra el primer scrape. Si entendés ese pipeline, cada SD backend (static, file, HTTP, Kubernetes, DNS, Consul, EC2…) se vuelve el mismo ejercicio con un prefijo de label distinto.

### Entorno

Necesitás un único host Linux con:

- `prometheus` y `promtool` en el `PATH` (v2.45+; cualquier 2.x/3.x reciente sirve),
- `node_exporter` corriendo en `:9100` (un target real conveniente),
- `curl`, `jq`, `python3`, y (Ejercicio 5) `kind` + `kubectl`.

Iniciá siempre Prometheus con la lifecycle API habilitada para poder hacer hot-reload sin matar el proceso:

```bash
prometheus --config.file=prometheus.yml --web.enable-lifecycle
```

Recargá después de cada cambio de config con señal o con la API:

```bash
curl -sf -X POST http://localhost:9090/-/reload      # needs --web.enable-lifecycle
# or:  kill -HUP "$(pgrep -x prometheus)"
```

Fuente de verdad para todo lo de abajo:
- Configuration y todos los bloques `*_sd_config` — https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Relabeling — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- HTTP SD — https://prometheus.io/docs/prometheus/latest/http_sd/
- Guía de File SD — https://prometheus.io/docs/guides/file-sd/

---

## Ejercicio 1 — Targets estáticos y el ciclo de vida del target

### Pasos

1. Escribí una config mínima con dos static targets — el propio Prometheus y `node_exporter`:

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: node
       static_configs:
         - targets: ['localhost:9100']
           labels:
             env: lab
   ```

2. Validála *antes* de cargarla — acá no se testea SD, solo la sintaxis:

   ```bash
   promtool check config prometheus.yml
   ```
   ```console
   Checking prometheus.yml
    SUCCESS: prometheus.yml is valid prometheus config file syntax
   ```

3. Iniciá Prometheus (ver Entorno) y consultá la targets API, filtrando los campos interesantes:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | {scrapePool, discoveredLabels, labels, health}'
   ```
   ```json
   {
     "scrapePool": "node",
     "discoveredLabels": {
       "__address__": "localhost:9100",
       "__metrics_path__": "/metrics",
       "__scheme__": "http",
       "__scrape_interval__": "15s",
       "__scrape_timeout__": "10s",
       "env": "lab",
       "job": "node"
     },
     "labels": {
       "env": "lab",
       "instance": "localhost:9100",
       "job": "node"
     },
     "health": "up"
   }
   ```

4. Fijate lo que aparece en `labels` que nunca escribiste: `instance`. Abrí la web UI en `http://localhost:9090/targets` y confirmá que el target `node` está `UP`.

### Comprobá lo que entendiste

- **1a.** `discoveredLabels` tiene `__address__` pero `labels` no. ¿A dónde fue `__address__`, y por qué está ausente del conjunto final de labels?
- **1b.** Nunca definiste `instance`, y sin embargo aparece. ¿Cuál es su valor por defecto, y en qué etapa se completa?
- **1c.** ¿Qué URL va a scrapear realmente Prometheus para el target `node`, y cuáles tres labels con prefijo `__meta`/`__` la determinaron?

---

## Ejercicio 2 — Service discovery basado en archivos y hot reload

### Pasos

1. Reemplazá los `static_configs` del job `node` por `file_sd_configs` apuntando a un glob de directorio:

   ```yaml
     - job_name: node
       file_sd_configs:
         - files:
             - 'targets/*.json'
           refresh_interval: 30s
   ```

2. Creá los archivos de targets. File SD los vuelve a leer ante cada cambio *y* en cada `refresh_interval`, **sin necesidad de recargar Prometheus**:

   ```bash
   mkdir -p targets
   cat > targets/prod.json <<'EOF'
   [
     { "targets": ["localhost:9100"], "labels": { "env": "prod" } }
   ]
   EOF
   ```

3. Recargá una vez (porque cambiaste el propio `prometheus.yml`), luego confirmá que el target está vivo:

   ```bash
   curl -sf -X POST http://localhost:9090/-/reload
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="node") | .discoveredLabels'
   ```
   ```json
   {
     "__address__": "localhost:9100",
     "__meta_filepath": "/path/to/targets/prod.json",
     "__metrics_path__": "/metrics",
     "__scheme__": "http",
     "__scrape_interval__": "15s",
     "__scrape_timeout__": "10s",
     "env": "prod",
     "job": "node"
   }
   ```

4. Ahora agregá un segundo archivo de targets **sin tocar `prometheus.yml` y sin recargar**:

   ```bash
   cat > targets/staging.json <<'EOF'
   [
     { "targets": ["localhost:9101"], "labels": { "env": "staging" } }
   ]
   EOF
   ```

5. Esperá hasta `refresh_interval` (o unos segundos — los cambios de archivo también los detecta inotify) y volvé a consultar. Ahora deberías ver dos targets, uno `up` y uno `down` (nada está escuchando en `:9101`). Confirmá el refresh de file SD con la métrica:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_sd_file_scan_duration_seconds_count' | jq '.data.result'
   ```

### Comprobá lo que entendiste

- **2a.** Agregaste `staging.json` sin recargar y fue tomado. Nombrá los *dos* mecanismos independientes que hacen que File SD relea sus archivos.
- **2b.** Editar el glob `files:` de `prometheus.yml` requirió recargar, pero editar el contenido de `prod.json` no. ¿Por qué esa distinción es fundamental para el modo en que File SD está pensado para usarse?
- **2c.** ¿Qué es `__meta_filepath`, y por qué es útil aunque desaparezca de los labels finales?

---

## Ejercicio 3 — Relabeling: `replace`, `keep`, `drop`, y leer los dropped targets

### Pasos

`relabel_configs` corre como un pipeline ordenado sobre cada target descubierto, *antes* de scrapear. Acá vas a (a) promover un label `__meta_*` a un label real, y (b) filtrar targets para que solo se scrapee producción.

1. Agregá un bloque `relabel_configs` al job `node` (que sigue usando File SD del Ejercicio 2):

   ```yaml
     - job_name: node
       file_sd_configs:
         - files: ['targets/*.json']
       relabel_configs:
         # (a) derive a real label from the source filename
         - source_labels: [__meta_filepath]
           regex: '.*/([^/]+)\.json'
           replacement: '$1'
           target_label: sd_file

         # (b) keep only targets whose env label is "prod"; drop the rest
         - source_labels: [env]
           regex: prod
           action: keep
   ```

2. Recargá e inspeccioná los targets **activos** — solo `prod` sobrevive, y ahora lleva `sd_file="prod"`:

   ```bash
   curl -sf -X POST http://localhost:9090/-/reload
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="node") | .labels'
   ```
   ```json
   {
     "env": "prod",
     "instance": "localhost:9100",
     "job": "node",
     "sd_file": "prod"
   }
   ```

3. Ahora inspeccioná los targets **dropped**. Un `keep` que falla no da error — elimina el target silenciosamente, que es la causa más común de "¿por qué no aparece mi target?":

   ```bash
   curl -s 'http://localhost:9090/api/v1/targets?state=dropped' \
     | jq '.data.droppedTargets[] | .discoveredLabels | {__address__, env}'
   ```
   ```json
   {
     "__address__": "localhost:9101",
     "env": "staging"
   }
   ```

4. Abrí `http://localhost:9090/service-discovery` en el navegador. Para el pool `node` muestra cada target descubierto con **"Discovered Labels"** a la izquierda y **"Target Labels"** a la derecha; los dropped targets muestran la columna derecha tachada. Esta página es la ground truth para debuggear relabeling.

### Comprobá lo que entendiste

- **3a.** La regla `keep` dropeó `localhost:9101`, pero `/api/v1/targets` (por defecto) no mostró error ni target. ¿A dónde fue, y qué flag de query lo revela?
- **3b.** En la regla `sd_file`, ¿por qué `__meta_filepath` (un meta label con prefijo `__`) sobrevive lo suficiente como para ser leído, mientras que `__address__` también tiene prefijo `__` pero se *conserva* como la dirección de scrape? Enunciá la regla general sobre los labels con prefijo `__` después del relabeling.
- **3c.** Si intercambiaras el orden para que la regla `keep` corriera **primero** y la regla `replace` de `sd_file` corriera segunda, ¿el target `prod` sobreviviente igual obtendría `sd_file="prod"`? ¿Cambiaría algo respecto del target *dropeado*?
- **3d.** ¿Cuál es la diferencia entre `relabel_configs` y `metric_relabel_configs`, y cuál de los dos *no* podría haberse usado para filtrar el target de staging?

---

## Ejercicio 4 — Service discovery basado en HTTP

File SD requiere archivos en el host de Prometheus. HTTP SD mueve la fuente de verdad a cualquier endpoint HTTP que devuelva el mismo JSON de target-group — la forma moderna y agnóstica del lenguaje de escribir una integración de SD custom.

### Pasos

1. Creá un documento de target-group y servílo por HTTP. Prometheus requiere que la respuesta sea `200 OK` con `Content-Type: application/json`:

   ```bash
   mkdir -p httpsd && cd httpsd
   cat > targets.json <<'EOF'
   [
     {
       "targets": ["localhost:9100"],
       "labels": { "job": "node", "env": "prod", "team": "sre" }
     }
   ]
   EOF
   python3 -m http.server 8080 &   # serves .json as application/json
   cd ..
   ```

2. Apuntá un job al endpoint:

   ```yaml
     - job_name: http-sd-node
       http_sd_configs:
         - url: http://localhost:8080/targets.json
           refresh_interval: 30s
   ```

3. Recargá y confirmá el target, fijándote en el meta label de HTTP-SD:

   ```bash
   curl -sf -X POST http://localhost:9090/-/reload
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="http-sd-node") | .discoveredLabels'
   ```
   ```json
   {
     "__address__": "localhost:9100",
     "__meta_url": "http://localhost:8080/targets.json",
     "__metrics_path__": "/metrics",
     "__scheme__": "http",
     "__scrape_interval__": "15s",
     "__scrape_timeout__": "10s",
     "env": "prod",
     "job": "node",
     "team": "sre"
   }
   ```

4. Rompélo a propósito: pará el `http.server`, esperá `refresh_interval`, y volvé a consultar. El target **permanece** en su último estado conocido, y una métrica de fallo de discovery se incrementa:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_sd_http_failures_total' \
     | jq '.data.result[].value[1]'
   ```

### Comprobá lo que entendiste

- **4a.** Después de matar el servidor HTTP, el target no desapareció. ¿Por qué Prometheus conserva la última lista de targets exitosa ante un fallo de discovery en lugar de dropear todo, y cuál sería el peligro operacional del comportamiento opuesto?
- **4b.** HTTP SD y File SD consumen exactamente la misma forma de JSON (`[{ "targets": [...], "labels": {...} }]`). ¿Qué te dice eso sobre en qué punto del pipeline la *elección del SD backend* deja de importar?
- **4c.** Si el endpoint devolviera `Content-Type: text/plain`, ¿qué pasaría, y dónde verías el motivo?

---

## Ejercicio 5 — Service discovery de Kubernetes (roles + scraping guiado por annotations)

> Requiere un cluster. Uno descartable rápido: `kind create cluster --name pca`. Corré Prometheus **dentro** del cluster (con RBAC otorgado) o apuntá un Prometheus local al API server; la lógica de relabel es idéntica.

### Pasos

1. Entendé primero los roles — cada uno produce un target set y un prefijo de label distintos:

   | `role` | un target por… | labels `__meta` clave |
   |---|---|---|
   | `node` | Kubelet | `__meta_kubernetes_node_name`, `__meta_kubernetes_node_label_*` |
   | `pod` | **container port** del pod | `__meta_kubernetes_pod_name`, `__meta_kubernetes_pod_annotation_*`, `__meta_kubernetes_pod_container_port_number` |
   | `endpoints` | dirección en los Endpoints de un Service | `__meta_kubernetes_service_name`, `__meta_kubernetes_endpoint_ready` |
   | `endpointslice` | dirección en un EndpointSlice | `__meta_kubernetes_endpointslice_*` |
   | `service` | ClusterIP:port del Service (blackbox) | `__meta_kubernetes_service_annotation_*` |
   | `ingress` | path del Ingress (blackbox) | `__meta_kubernetes_ingress_*` |

2. Configurá el job de pods canónico guiado por annotations. Esto es *enteramente* relabeling — SD te da cada puerto de pod; las reglas seleccionan y reescriben:

   ```yaml
     - job_name: kubernetes-pods
       kubernetes_sd_configs:
         - role: pod
       relabel_configs:
         # keep only pods annotated prometheus.io/scrape: "true"
         - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
           action: keep
           regex: "true"

         # optional custom metrics path from annotation
         - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
           action: replace
           target_label: __metrics_path__
           regex: (.+)

         # rewrite host:port using the annotated port (address:port ⇐ podIP + annotation)
         - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
           action: replace
           regex: ([^:]+)(?::\d+)?;(\d+)
           replacement: $1:$2
           target_label: __address__

         # promote all pod labels to metric labels
         - action: labelmap
           regex: __meta_kubernetes_pod_label_(.+)

         # carry namespace and pod name as stable labels
         - source_labels: [__meta_kubernetes_namespace]
           target_label: namespace
         - source_labels: [__meta_kubernetes_pod_name]
           target_label: pod
   ```

3. Desplegá un workload con annotations y verificá que sea descubierto:

   ```bash
   kubectl create deployment web --image=nginx
   kubectl patch deployment web --type merge -p '{
     "spec":{"template":{"metadata":{"annotations":{
       "prometheus.io/scrape":"true","prometheus.io/port":"80"}}}}}'

   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="kubernetes-pods") | {labels, health}'
   ```

4. Diagnosticá las exclusiones en `/service-discovery`: los pods **sin** la annotation aparecen como dropped por la primera regla `keep` — probando que todo el cluster fue descubierto y luego filtrado, no "salteado".

### Comprobá lo que entendiste

- **5a.** Con `role: pod`, un pod nginx que expone un container port produce exactamente un target; un pod con tres container ports declarados produce tres. ¿Por qué — y qué label `__meta` los distingue?
- **5b.** En la regla de reescritura de `__address__`, el `regex` es `([^:]+)(?::\d+)?;(\d+)` y el separador entre los dos source labels es `;`. Recorré qué capturan `$1` y `$2`, y por qué el `(?::\d+)?` del medio es opcional.
- **5c.** Querés scrapear un Service como un único target lógico (estilo blackbox, balanceado por el ClusterIP) en lugar de cada pod de respaldo individualmente. ¿Qué role elegís, y por qué `endpoints`/`pod` es la respuesta *incorrecta* para esa intención?
- **5d.** Un compañero dice "el job de pods se salteó mi nuevo service". Dado este config, ¿cuál es la afirmación más precisa, y exactamente qué página lo confirma?

---

## Ejercicio 6 — Service discovery por DNS y un ejercicio de diagnóstico

### Pasos

1. Agregá un job DNS-SRV. `dns_sd_configs` resuelve los nombres periódicamente y convierte cada registro devuelto en un target:

   ```yaml
     - job_name: dns-srv
       dns_sd_configs:
         - names:
             - '_node-exporter._tcp.svc.lab.local'
           type: SRV
           refresh_interval: 30s
       relabel_configs:
         - source_labels: [__meta_dns_srv_record_target]
           target_label: srv_host
   ```
   *(Para un registro A/AAAA también tenés que proveer un `port:`, porque los registros A no llevan puerto; los registros SRV sí.)*

2. Validá la sintaxis y recargá:

   ```bash
   promtool check config prometheus.yml && curl -sf -X POST http://localhost:9090/-/reload
   ```

3. Inspeccioná los meta labels de DNS que SD adjunta (visibles en `/service-discovery` incluso cuando la resolución falla):

   - `__meta_dns_name` — el nombre de la query,
   - `__meta_dns_srv_record_target` / `__meta_dns_srv_record_port` — el host/puerto SRV resuelto,
   - `__meta_dns_mname` — el name server primario del registro SOA.

4. **Ejercicio de diagnóstico.** Para cada síntoma de abajo, decidí *qué única página o query* abrirías primero, luego confirmá reproduciéndolo con los jobs que ya construiste:

   | Síntoma | Primer lugar donde mirar |
   |---|---|
   | Target listado pero `health: down`, `lastError: "connection refused"` | `/targets` → columna `Error` |
   | El target que esperabas está completamente ausente | `/service-discovery` → ¿está en la columna *dropped*? |
   | El SD backend no devuelve nada en absoluto | métricas `prometheus_sd_*_failures_total` / `_sd_*_refresh_*` |
   | Target correcto, `instance`/labels incorrectos | `/service-discovery` → diff de Discovered vs Target labels |

### Comprobá lo que entendiste

- **6a.** ¿Por qué `dns_sd_configs` con `type: A` puede **requerir** un `port` explícito, mientras que `type: SRV` **no** debe necesitar ninguno?
- **6b.** Un target muestra `health: down` con `lastError: context deadline exceeded`. ¿Es esto un problema de service discovery? Justificá usando la distinción entre discovered y target labels.
- **6c.** Ves `up == 0` para un job pero `/service-discovery` muestra el target en la columna *dropped*. ¿Cuál de los dos — fallo de scrape o drop de relabel — está pasando, y por qué solo uno de ellos puede ser verdadero a la vez para una dirección dada?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
- **1a.** `__address__` no se elimina — se *consume*. Después del relabeling, Prometheus usa `__address__` (más `__scheme__` y `__metrics_path__`) para construir la scrape URL, luego quita todos los labels con prefijo `__` restantes del conjunto final de labels de la métrica. Así que sigue gobernando el scrape; simplemente no queda adjunto a la serie temporal resultante.
- **1b.** `instance` toma por defecto el valor de `__address__` (`localhost:9100`). Se completa *después* del relabeling, en el momento en que se dropean los labels con prefijo `__` — que es por lo que podés sobrescribir `instance` en `relabel_configs` pero, si no lo hacés, refleja la dirección.
- **1c.** Scrape URL = `http://localhost:9100/metrics`, construida a partir de `__scheme__` (`http`) + `__address__` (`localhost:9100`) + `__metrics_path__` (`/metrics`).

### Ejercicio 2
- **2a.** (1) Un watch del filesystem (inotify) que reacciona a la creación/modificación/borrado de archivos, y (2) el re-escaneo completo periódico de `refresh_interval` (5 minutos por defecto) como red de seguridad ante eventos perdidos/fusionados y filesystems en red.
- **2b.** El glob `files:` es *configuración de Prometheus* (cargada una vez al iniciar/recargar); el *contenido* de los archivos son *datos* que File SD posee y sondea continuamente. Todo el sentido de File SD es que un sistema separado (gestión de configuración, un script, un operador) reescriba los archivos de targets en runtime y Prometheus los siga sin recargar — desacoplando "qué scrapear" de "cómo está configurado Prometheus".
- **2c.** `__meta_filepath` es la ruta absoluta del archivo del que vino un target, inyectada por File SD. Desaparece de los labels finales (todos los `__meta_*` se dropean después del relabeling) pero podés leerlo durante el relabeling para derivar labels reales (p. ej. el environment o el shard a partir del nombre del archivo), que es lo que hace el Ejercicio 3.

### Ejercicio 3
- **3a.** Un `keep` cuyo regex no matchea remueve el target del conjunto activo y lo archiva bajo **dropped targets**. El `/api/v1/targets` por defecto los omite; `?state=dropped` (o `?state=any`) los revela, y `/service-discovery` los muestra con la columna de target-labels tachada. No se genera ningún error — ese silencio es la clásica trampa del "target faltante".
- **3b.** Regla general: los labels con prefijo `__` están disponibles *durante todo* el relabeling y solo se quitan al *final*, justo antes de que el target se finalice. Así que `__meta_filepath` es totalmente legible mientras corren las reglas; se dropea después como todo otro label `__`. `__address__` también se dropea del conjunto final de labels — no se "conserva como label", se *consume* para construir la scrape URL primero. Ambos siguen la misma regla; difieren solo en qué los lee.
- **3c.** El orden importa, pero no acá para el sobreviviente: las reglas de relabel sobre el *mismo target* corren en secuencia y `keep`/`drop` solo deciden si ese target continúa — no deshacen `replace`s anteriores. Así que el target `prod` sobreviviente igual obtiene `sd_file="prod"` sin importar el orden. El target de staging dropeado no se ve afectado en ningún caso (se dropea antes o después de una regla que, para él, no hace nada). El orden *sí* importaría si una regla posterior dependiera de un label que un `keep`/`drop` usó — pero drop/keep nunca mutan labels.
- **3d.** `relabel_configs` corre en **tiempo de discovery**, sobre los labels `__meta_*`/de dirección del target, decidiendo *qué targets scrapear y cómo*. `metric_relabel_configs` corre en **tiempo de ingesta**, sobre los labels de cada muestra scrapeada, decidiendo *qué series conservar/renombrar*. **No** podrías haber usado `metric_relabel_configs` para filtrar el target de staging, porque ese target igual habría sido descubierto y scrapeado — se contactaría el endpoint de staging (y, estando down, produciría errores de scrape). Solo `relabel_configs` evita que el scrape ocurra en absoluto.

### Ejercicio 4
- **4a.** Ante un fallo de refresh de discovery, Prometheus conserva el último target group exitoso para que una caída transitoria de SD (un parpadeo de red, un reinicio del endpoint) no haga flappear todos los targets a "desaparecido", lo que dejaría en blanco los dashboards, dispararía alertas espurias de `up==0`/absent, y detendría el scrapeo de servicios sanos. El comportamiento opuesto acoplaría la disponibilidad de tu *monitoreo* a la disponibilidad de tu *SD control plane* — un único punto de fallo amplificando incidentes.
- **4b.** Te dice que el trabajo del SD backend termina en el momento en que produce un target group `{targets, labels}`. Desde ese punto — relabeling, construcción de la dirección, scrapeo, ingesta — el pipeline es idéntico sin importar qué SD produjo el grupo. Elegir File vs HTTP vs Kubernetes cambia solo *cómo se obtiene el grupo y qué labels `__meta_*` lleva*, nada aguas abajo.
- **4c.** HTTP SD rechaza un `Content-Type` que no sea `application/json`; la lista de targets de ese endpoint no se actualiza (se retiene el último estado conocido), `prometheus_sd_http_failures_total` se incrementa, y el motivo queda registrado en los logs de Prometheus (y el endpoint muestra un fallo en `/service-discovery`).

### Ejercicio 5
- **5a.** `role: pod` crea un target por **container port declarado**, porque un pod puede exponer varios puertos y cada uno necesita su propia dirección de scrape. Un puerto de nginx → un target; tres puertos declarados → tres targets. `__meta_kubernetes_pod_container_port_number` (con `_name`/`_protocol`) los distingue. (Los pods sin puertos declarados igual producen un target sobre la IP del pod sin puerto — de ahí la regla de relabel que reescribe el puerto.)
- **5b.** Los source labels se unen con el separador `;`, dando `"<podIP>[:<port>];<annotationPort>"`. `([^:]+)` captura la IP como `$1`; `(?::\d+)?` matchea opcionalmente y descarta un `:port` existente que ya esté en `__address__` (un pod que *sí* declaró un puerto), para que no se duplique; `;` matchea el separador; `(\d+)` captura el puerto de la annotation como `$2`. `replacement: $1:$2` reconstruye `podIP:annotationPort`. El grupo del medio es opcional porque algunos targets llegan con un puerto en `__address__` y otros sin él.
- **5c.** Usá `role: service`: produce un target por ClusterIP:port del Service, así que los scrapes pasan por la VIP del Service y se balancean hacia cualquier pod que responda — la intención blackbox/"¿es alcanzable el servicio?". `endpoints`/`pod` enumeran los *backends individuales*, que es scrapeo whitebox por instancia — la intención opuesta; obtendrías N targets y evitarías la VIP.
- **5d.** Afirmación precisa: "este job es `role: pod`, así que nunca descubre *Services* en absoluto — descubre *pods*, y mi pod o bien no estaba anotado con `prometheus.io/scrape: "true"` (dropeado por el primer `keep`) o no tiene un puerto que matchee." `/service-discovery` para el pool `kubernetes-pods` lo confirma: el pod estará presente en la columna dropped con sus labels `__meta` descubiertos.

### Ejercicio 6
- **6a.** Los registros SRV codifican tanto el host **como** el puerto (`_service._proto.name → target:port`), así que Prometheus deriva el puerto del registro — proveer uno sería ambiguo/ignorado. Los registros A/AAAA devuelven solo direcciones IP sin puerto, así que Prometheus no puede saber dónde scrapear a menos que proveas `port:` explícitamente.
- **6b.** **No** es un problema de service discovery. El discovery claramente tuvo éxito — el target existe con *discovered labels* resueltos y una scrape URL construida (eso es lo que le permitió a Prometheus siquiera intentarlo). `context deadline exceeded` es un timeout en *tiempo de scrape* contra esa dirección (endpoint lento/inalcanzable, puerto incorrecto, firewall). El trabajo de SD (producir el target) está hecho; el fallo está aguas abajo, en el scrape. Lo confirmarías en `/targets` (columna Error), no en `/service-discovery`.
- **6c.** Es un **drop de relabel**, no un fallo de scrape. Si la dirección está en la columna *dropped*, el target fue removido durante el relabeling y por lo tanto **nunca se scrapea** — así que no hay ninguna serie `up` para él en absoluto (un "`up == 0`" que veas debe pertenecer a un target/instance *distinto* que sigue activo, o el panel está mostrando una serie vieja/otra serie). Para una dirección finalizada dada los dos son mutuamente excluyentes: un target o bien se conserva (y entonces se scrapea, produciendo `up` = 0 o 1) *o* se dropea (y nunca se scrapea, no produciendo ningún `up`). Un target no puede estar simultáneamente dropeado y scrapeado.

</details>