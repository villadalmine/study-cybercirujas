# PCA — Topic 4.1: Dashboarding Basics

## Guided Exercises

> **Escenario.** Corrés Prometheus en producción, pero los interesados no dejan de preguntar "¿está sana la máquina?" por Slack. En este lab construís la capa de visualización de punta a punta: desde el propio expression browser de Prometheus, a un panel de time series de Grafana, a un dashboard con plantillas (templating), hasta dashboards-como-código. Terminás con las viejas console templates de Prometheus para que las reconozcas en el terreno.
>
> **Prerrequisitos:** Docker + Docker Compose v2, puertos `3000`, `9090`, `9100` libres. ~15 minutos.

### Lab setup

Creá un directorio de trabajo y estos archivos.

**`prometheus.yml`**

```yaml
global:
  scrape_interval: 15s        # feeds $__rate_interval later; remember this number

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
  - job_name: node
    static_configs:
      - targets: ["node_exporter:9100"]   # container DNS name, not localhost
```

**`docker-compose.yml`**

```yaml
services:
  prometheus:
    image: prom/prometheus:v2.53.0
    container_name: prometheus
    ports: ["9090:9090"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./consoles:/etc/prometheus/consoles:ro
      - ./console_libraries:/etc/prometheus/console_libraries:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.console.templates=/etc/prometheus/consoles
      - --web.console.libraries=/etc/prometheus/console_libraries
      - --web.enable-lifecycle

  node_exporter:
    image: prom/node-exporter:v1.8.1
    container_name: node_exporter
    ports: ["9100:9100"]

  grafana:
    image: grafana/grafana:11.1.0
    container_name: grafana
    ports: ["3000:3000"]
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
```

Creá los directorios que los volúmenes esperan (vacíos por ahora):

```bash
mkdir -p consoles console_libraries grafana/provisioning/datasources \
         grafana/provisioning/dashboards grafana/dashboards
docker compose up -d
```

Esperado:

```
[+] Running 4/4
 ✔ Network dashboards_default  Created
 ✔ Container node_exporter     Started
 ✔ Container prometheus        Started
 ✔ Container grafana           Started
```

---

## Exercise 1 — The Prometheus expression browser

El dashboard más barato es el que Prometheus ya trae. Antes de Grafana, aprendé a leer la UI incorporada.

1. Abrí `http://localhost:9090/graph`.
2. En la caja de consulta escribí `up` y presioná **Execute**. Quedate en la pestaña **Table**. Deberías ver una fila por cada scrape target:

   ```
   up{instance="localhost:9090", job="prometheus"}   1
   up{instance="node_exporter:9100", job="node"}     1
   ```
3. Cambiá a la pestaña **Graph**. Fijate que `up` se renderiza como líneas planas en `1`. Los valores instantáneos se vuelven una línea porque Prometheus dibuja un punto por step a lo largo del rango de tiempo seleccionado.
4. Reemplazá la consulta por un **counter** e intentá graficarlo crudo:

   ```promql
   node_cpu_seconds_total{mode="idle"}
   ```

   En la pestaña Graph obtenés líneas que suben monótonamente — no es útil.
5. Ahora envolvelo en `rate()` sobre un range vector y ejecutá de nuevo:

   ```promql
   rate(node_cpu_seconds_total{mode="idle"}[5m])
   ```

   Ahora obtenés una línea por cada núcleo de CPU que ronda cerca de `~1` (segundos idle acumulados por segundo por núcleo).
6. En la pestaña Graph, cambiá el control de rango de `1h` a `15m`, después hacé clic en el campo **Res. (s)** y fijá una resolución (step) explícita de `15`. Volvé a correrla y observá cómo la línea se vuelve más densa.
7. Confirmá los mismos datos vía la HTTP API (esto es exactamente lo que una herramienta de dashboards llama por debajo):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq
   ```

   ```json
   {
     "status": "success",
     "data": {
       "resultType": "vector",
       "result": [
         { "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
           "value": [ 1723130400, "1" ] },
         { "metric": { "__name__": "up", "instance": "node_exporter:9100", "job": "node" },
           "value": [ 1723130400, "1" ] }
       ]
     }
   }
   ```

**Comprehension check 1**

- **1a.** En la pestaña **Table** solo podés mostrar un *instant vector*, nunca un *range vector* como `node_cpu_seconds_total[5m]`. ¿Por qué?
- **1b.** ¿Por qué el paso 5 necesitó `rate(...[5m])` en lugar de graficar el counter directamente?
- **1c.** En el paso 7, ¿qué dos endpoints de la API respaldan la pestaña Table y la pestaña Graph respectivamente, y cuál es la diferencia estructural en sus respuestas?

---

## Exercise 2 — Add Prometheus as a Grafana data source

1. Abrí `http://localhost:3000` e iniciá sesión con `admin` / `admin` (salteá el cambio de contraseña).
2. Andá a **Connections → Data sources → Add data source → Prometheus**.
3. Poné **Prometheus server URL** en:

   ```
   http://prometheus:9090
   ```
4. Dejá el modo de conexión en su valor por defecto. Bajá y hacé clic en **Save & test**. Deberías ver:

   ```
   ✔ Successfully queried the Prometheus API.
   ```
5. **Rompelo a propósito para aprender el modo de falla.** Cambiá la URL a `http://localhost:9090` y **Save & test** de nuevo. Falla:

   ```
   ✗ Post "http://localhost:9090/api/v1/query": dial tcp 127.0.0.1:9090: connect: connection refused
   ```

   Restaurala a `http://prometheus:9090`.
6. Ahora hacé lo mismo **como código**. Borrá el data source de la UI, después creá **`grafana/provisioning/datasources/prometheus.yaml`**:

   ```yaml
   apiVersion: 1
   datasources:
     - name: Prometheus
       uid: prometheus            # stable uid so dashboards can reference it
       type: prometheus
       access: proxy              # Grafana backend proxies the request
       url: http://prometheus:9090
       isDefault: true
       jsonData:
         httpMethod: POST
         timeInterval: 15s        # MUST match scrape_interval; drives $__rate_interval
   ```
7. Recargá Grafana y verificá que el source aprovisionado existe:

   ```bash
   docker compose restart grafana
   curl -s http://admin:admin@localhost:3000/api/datasources | jq '.[] | {name, uid, url}'
   ```

   ```json
   { "name": "Prometheus", "uid": "prometheus", "url": "http://prometheus:9090" }
   ```

**Comprehension check 2**

- **2a.** En el paso 5, Prometheus estaba claramente arriba (el Exercise 1 lo probó). ¿Por qué falló `http://localhost:9090` con `access: proxy`, y en qué modo *sí* sería `localhost` el host correcto?
- **2b.** Un data source aprovisionado no se puede editar ni borrar desde la UI de Grafana (los campos quedan grisados). ¿Por qué es ese el comportamiento buscado, y cómo lo cambiás?
- **2c.** ¿Qué se rompe en tus dashboards si `jsonData.timeInterval` se deja sin fijar o se pone en `1s` en lugar de `15s`?

---

## Exercise 3 — Build your first Time series panel

1. Andá a **Dashboards → New → New dashboard → Add visualization**. Elegí el data source **Prometheus**.
2. En el editor de consultas, cambiá al modo **Code** e ingresá:

   ```promql
   sum by (mode) (rate(node_cpu_seconds_total[$__rate_interval]))
   ```
3. En el campo **Legend** de la fila de la consulta, escribí:

   ```
   {{mode}}
   ```

   Cada serie queda ahora etiquetada como `idle`, `system`, `user`, `iowait`, … en lugar del string completo de la métrica.
4. Confirmá que el tipo de panel es **Time series** (el selector de visualización arriba a la derecha).
5. En el panel de la derecha, fijá **Standard options → Unit → Time → seconds (s)** (CPU-seconds por segundo es un ratio, pero esto mantiene los valores del hover legibles). Fijá **Graph styles → Stacking → Normal** para ver cómo se suma el desglose por modo.
6. Cambiá el tipo de consulta de **Range** a **Instant** (el toggle en la fila de opciones de la consulta) y observá el panel: un panel de time series con una consulta instantánea muestra solo el último punto. Volvelo a **Range**.
7. Hacé clic en **Apply**, después **Save dashboard** como `Node CPU`.

**Comprehension check 3**

- **3a.** ¿Por qué es `$__rate_interval` el rango recomendado para `rate()` dentro de un panel de Grafana, en lugar de un `[5m]` hardcodeado?
- **3b.** El formato de leyenda `{{mode}}` usa llaves dobles. ¿Es esto sintaxis de PromQL? ¿Dónde se evalúa?
- **3c.** Elegiste una visualización **Time series**. Nombrá otras dos visualizaciones incorporadas y una forma de métrica para la que cada una es más adecuada que un time series.

---

## Exercise 4 — Dashboard variables (templating)

Las instancias hardcodeadas no escalan. Agregá un dropdown para que un solo dashboard sirva a todos los nodos.

1. Abrí tu dashboard `Node CPU` → **Settings (gear) → Variables → New variable**.
2. Configurá:
   - **Select variable type:** `Query`
   - **Name:** `instance`
   - **Data source:** `Prometheus`
   - **Query type:** `Label values`
   - **Label:** `instance`
   - **Metric:** `node_cpu_seconds_total`

   El **Preview of values** al fondo debería mostrar `node_exporter:9100`. (Por debajo esto es la función `label_values(node_cpu_seconds_total, instance)`.)
3. Activá **Multi-value** e **Include All option**, después **Apply**.
4. De vuelta en el dashboard, editá la consulta del panel para filtrar por la variable:

   ```promql
   sum by (mode) (rate(node_cpu_seconds_total{instance=~"$instance"}[$__rate_interval]))
   ```

   Notá el matcher de regex `=~` — requerido porque una variable multi-value se expande a `node_exporter:9100|other:9100`.
5. Usá el dropdown `instance` en la parte superior del dashboard para cambiar la selección y observá cómo el panel vuelve a consultar.
6. Agregá una segunda variable, puramente cosmética, para ver el contraste: **New variable → Type: `Custom`**, nombre `threshold`, valores `70,80,90`. Esta nunca toca Prometheus.

**Comprehension check 4**

- **4a.** `label_values(node_cpu_seconds_total, instance)` — ¿es esto una función de PromQL? Si no, ¿qué es y quién la evalúa?
- **4b.** ¿Por qué el panel debe usar `instance=~"$instance"` (regex) en lugar de `instance="$instance"` (igualdad) una vez que Multi-value está habilitado?
- **4c.** ¿Cuál es la diferencia práctica entre una variable `Query` y una variable `Custom` en términos de carga sobre Prometheus?

---

## Exercise 5 — Provision a dashboard from JSON (dashboards-as-code)

Los dashboards construidos a clic no son reproducibles. Enviálos como archivos.

1. Creá el provider **`grafana/provisioning/dashboards/default.yaml`**:

   ```yaml
   apiVersion: 1
   providers:
     - name: default
       orgId: 1
       folder: ''
       type: file
       disableDeletion: false
       updateIntervalSeconds: 10
       allowUiUpdates: false
       options:
         path: /var/lib/grafana/dashboards
   ```
2. Creá el modelo del dashboard **`grafana/dashboards/node-cpu.json`**:

   ```json
   {
     "uid": "node-cpu",
     "title": "Node CPU (provisioned)",
     "schemaVersion": 39,
     "editable": true,
     "time": { "from": "now-1h", "to": "now" },
     "templating": {
       "list": [
         {
           "name": "instance",
           "type": "query",
           "datasource": { "type": "prometheus", "uid": "prometheus" },
           "query": { "query": "label_values(node_cpu_seconds_total, instance)", "refId": "StandardVariableQuery" },
           "includeAll": true,
           "multi": true
         }
       ]
     },
     "panels": [
       {
         "type": "timeseries",
         "title": "CPU usage by mode",
         "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
         "datasource": { "type": "prometheus", "uid": "prometheus" },
         "targets": [
           {
             "refId": "A",
             "expr": "sum by (mode) (rate(node_cpu_seconds_total{instance=~\"$instance\"}[$__rate_interval]))",
             "legendFormat": "{{mode}}"
           }
         ]
       }
     ]
   }
   ```
3. Reiniciá Grafana para que el provider levante los archivos:

   ```bash
   docker compose restart grafana
   ```
4. Confirmá que el dashboard se cargó desde disco (notá `provisioned: true`):

   ```bash
   curl -s http://admin:admin@localhost:3000/api/dashboards/uid/node-cpu \
     | jq '{title: .dashboard.title, provisioned: .meta.provisioned}'
   ```

   ```json
   { "title": "Node CPU (provisioned)", "provisioned": true }
   ```
5. Abrilo en `http://localhost:3000/d/node-cpu`. Notá que el datasource queda vinculado por **`uid: prometheus`** — el mismo uid que fijaste en el Exercise 2. Si los uids no coincidieran, el panel renderizaría **"Datasource prometheus was not found."**

**Comprehension check 5**

- **5a.** ¿Por qué el JSON del panel referenció el data source por `uid`, y por qué fijar `uid: prometheus` en el archivo de provisioning del *data source* importa para la portabilidad entre entornos?
- **5b.** Con `disableDeletion: false` y `allowUiUpdates: false`, ¿qué pasa si un colega edita este dashboard en la UI y hace clic en Save?
- **5c.** El JSON del panel no contiene IDs numéricos ni un campo `version`, y aun así Grafana lo acepta. ¿Por qué es `uid` el campo que realmente importa para la idempotencia del provisioning?

---

## Exercise 6 — (Advanced / legacy) Prometheus console templates

Antes de que Grafana fuera ubicuo, Prometheus servía sus propios dashboards HTML vía plantillas Go. Todavía vas a encontrar estas en stacks más viejos; el PCA espera que las reconozcas.

1. Creá **`consoles/hello.html`** — una plantilla autocontenida que llama a la función `query` del lado del servidor:

   ```html
   <!DOCTYPE html>
   <html>
   <head><title>Targets up</title></head>
   <body>
     <h1>Targets currently up</h1>
     <table border="1" cellpadding="4">
       <tr><th>job</th><th>instance</th><th>up</th></tr>
       {{ range query "up" }}
       <tr>
         <td>{{ .Labels.job }}</td>
         <td>{{ .Labels.instance }}</td>
         <td>{{ .Value }}</td>
       </tr>
       {{ end }}
     </table>
     <p>Rendered by Prometheus at <code>{{ .Path }}</code></p>
   </body>
   </html>
   ```
2. El archivo de compose ya monta `./consoles` y fija `--web.console.templates=/etc/prometheus/consoles`. Recreá Prometheus para que vea el nuevo archivo:

   ```bash
   docker compose up -d prometheus
   ```
3. Abrí `http://localhost:9090/consoles/hello.html`. Prometheus renderiza la tabla **en el servidor** corriendo la consulta `up` e iterando el vector de resultado — sin JavaScript en el navegador, sin Grafana.
4. Confirmalo con curl (obtenés HTML terminado, no JSON):

   ```bash
   curl -s http://localhost:9090/consoles/hello.html | grep -A1 node_exporter
   ```
   ```
   <td>node_exporter:9100</td>
   <td>1</td>
   ```

**Comprehension check 6**

- **6a.** Un panel de Grafana y esta console template muestran ambos el valor de `up`, pero la consulta se ejecuta en lugares fundamentalmente distintos. Contrastá dónde y cuándo cada una corre la PromQL.
- **6b.** ¿Por qué existen los dos flags `--web.console.*` como par, y qué provee normalmente `--web.console.libraries` que nuestra plantilla mínima evita deliberadamente?
- **6c.** Dado que Grafana existe, nombrá una situación operativa legítima donde una console template renderizada del lado del servidor sigue siendo la opción pragmática.

---

## Teardown

```bash
docker compose down -v
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1a.** La pestaña Table (Console) muestra una única evaluación en un instante, así que solo puede renderizar un **instant vector** (una muestra por serie). Un range vector como `[5m]` es un *conjunto* de muestras por serie a lo largo de una ventana — no tiene un valor único para ubicar en una celda, y la UI lo rechaza (`Error executing query: invalid expression type "range vector"`). Los range vectors solo son legales como argumentos de funciones como `rate()`, `increase()`, o `avg_over_time()`, que los colapsan de vuelta a un instant vector.

**1b.** `node_cpu_seconds_total` es un **counter** — solo siempre crece y se resetea a 0 en el reinicio del proceso. Su valor absoluto (millones de segundos acumulados) no tiene sentido en un gráfico; lo que te importa es el *incremento por segundo*. `rate(...[5m])` computa la tasa promedio de incremento por segundo sobre la ventana de 5 minutos y es consciente de los resets del counter, convirtiendo la línea siempre creciente en una tasa legible de "CPU-seconds por segundo por núcleo".

**1c.** La pestaña **Table** llama a `/api/v1/query` (una *instant query*): el `resultType` de la respuesta es `vector` y cada serie carga un único `value: [ts, "n"]`. La pestaña **Graph** llama a `/api/v1/query_range` (una *range query* con `start`, `end`, `step`): el `resultType` de la respuesta es `matrix` y cada serie carga un array `values: [[ts,"n"], …]` — un punto por step, que es lo que hace una línea.

### Exercise 2

**2a.** Con `access: proxy` (el default, mostrado como "Server" en la UI), el **backend de Grafana** hace la petición HTTP. Dentro del contenedor de Grafana, `localhost` es el propio contenedor de Grafana, que no tiene nada en `:9090`, así que la conexión es rechazada. La URL debe ser resoluble *desde el namespace de red de Grafana* — de ahí el nombre DNS de Docker `http://prometheus:9090`. `localhost` solo sería correcto en modo de acceso **direct/Browser**, donde el navegador del usuario final emite la petición (e incluso ahí solo si Prometheus estuviera publicado en la propia máquina del usuario, y CORS lo permitiera).

**2b.** Los recursos aprovisionados se declaran como **código**, así que Grafana trata a los archivos como la fuente de verdad y bloquea la UI para prevenir la deriva entre lo que hay en disco y lo que hay en la base de datos. Para cambiarlo editás el YAML de provisioning y recargás Grafana (reiniciar, o `docker compose restart grafana`) — no la UI.

**2c.** `timeInterval` es la noción del data source respecto del scrape interval y alimenta `$__rate_interval`. Si no se fija, Grafana no puede computar una ventana de rate segura y puede elegir un rango que arroje menos de las ~4 muestras que `rate()` necesita, produciendo **gráficos con huecos o vacíos** en rangos de tiempo amplios. Fijarlo en `1s` (una mentira sobre el scrape real de 15s) hace que `$__rate_interval` sea demasiado chico, así que `rate()` frecuentemente ve <2 muestras en la ventana y no devuelve datos.

### Exercise 3

**3a.** Un `[5m]` hardcodeado se rompe en ambos extremos del zoom: alejate lo suficiente y 5 minutos es más chico que el step de un píxel, causando aliasing/huecos; acercate y 5m suaviza de más. `$__rate_interval` se computa por render como aproximadamente `max(4 × scrape_interval, $__interval + scrape_interval)`, garantizando al menos ~4 muestras en la ventana a cualquier nivel de zoom mientras se mantiene lo más ajustado posible. Adapta la ventana de rate al ancho del panel y al scrape interval del data source automáticamente.

**3b.** No — `{{mode}}` **no** es PromQL. Es la **plantilla de leyenda** de Grafana, interpolada por Grafana *después* de que la consulta retorna, sustituyendo el valor del label `mode` de cada serie de resultado. PromQL nunca la ve.

**3c.** Ejemplos (dos cualesquiera): **Stat** (un único valor actual / número grande, ej. `up` o requests/s actuales); **Gauge** o **Bar gauge** (un valor contra un rango de umbrales, ej. % de disco usado); **Table** (instant vectors ricos en labels que querés inspeccionar fila por fila, ej. `up` por target); **Heatmap** (datos de histograma/bucket a lo largo del tiempo, ej. distribución de latencia de peticiones). Time series es para valores que evolucionan en el tiempo como líneas.

### Exercise 4

**4a.** **No** es una función de PromQL. `label_values()` es una **función de plantilla/variable de Grafana** (parte del data source de Prometheus en Grafana). La evalúa Grafana para poblar el dropdown de la variable — consulta la API de labels y devuelve los valores distintos de un label. No la podés usar en un `expr` de panel.

**4b.** Una variable multi-value se interpola a un string de alternación, ej. `node_exporter:9100|db01:9100`. Con igualdad (`instance="..."`) Prometheus busca un único label literalmente igual a ese string unido por pipes y no matchea nada. El matcher de regex `=~` trata a los pipes como alternación, matcheando cualquiera de las instancias seleccionadas (y la opción `All`, que se expande a `.*` o la lista completa).

**4c.** Una variable **Query** corre una consulta real contra Prometheus cada vez que se refresca (al cargar, al cambiar el rango de tiempo, o por intervalo, según su ajuste de refresh), así que agrega carga sobre la API de labels. Una variable **Custom** es una lista estática, tipeada a mano, guardada en el JSON del dashboard — nunca toca Prometheus y tiene costo de backend cero.

### Exercise 5

**5a.** Los paneles se vinculan a un data source por **`uid`**, no por nombre, porque los nombres pueden diferir o estar duplicados entre instancias de Grafana mientras que un `uid` es un handle estable. Al fijar `uid: prometheus` en el archivo de provisioning del data source, cada entorno (dev, staging, prod) expone el *mismo* uid, así que el JSON idéntico del dashboard resuelve su data source en todos lados sin ediciones. Si dependieras de uids autogenerados, el mismo JSON mostraría "Datasource not found" en un entorno distinto.

**5b.** Con `allowUiUpdates: false`, el Save de la UI es rechazado/no persistido para dashboards aprovisionados — el archivo en disco sigue siendo la fuente de verdad, y Grafana se resincroniza desde él en el próximo tick de `updateIntervalSeconds`, descartando el cambio de la UI. (`disableDeletion: false` solo gobierna si el dashboard puede borrarse, no editarse.)

**5c.** El provisioning basa su idempotencia en **`uid`**. En cada sincronización Grafana hace upsert del dashboard cuyo `uid` matchea, reemplazando su contenido — así que reaplicar el mismo archivo es un no-op y cambiar el archivo actualiza en el lugar en vez de crear duplicados. El `id` numérico y el `version` son manejados por la base de datos de Grafana y se omiten intencionalmente del JSON aprovisionado; suministrarlos pelearía con la propia contabilidad de Grafana.

### Exercise 6

**6a.** El **panel de Grafana** envía PromQL a la HTTP API de Prometheus *al momento de la vista, desde la sesión del cliente/navegador*; Prometheus devuelve JSON y Grafana lo renderiza en el navegador. La **console template** corre la PromQL *dentro del propio servidor Prometheus*, en el momento en que se pide la página, vía la función `query` de la plantilla Go; Prometheus devuelve HTML terminado. Una es dirigida por el cliente y basada en API; la otra es renderizada del lado del servidor sin herramienta separada y sin consultas del lado del navegador.

**6b.** `--web.console.templates` apunta al directorio de plantillas `.html` a servir bajo `/consoles/`; `--web.console.libraries` apunta a fragmentos de plantilla reutilizables y helpers JS (los partials `prom_*` de head/menu/graph y el widget de graficado `prometheus.js`) que consolas más ricas incluyen con `{{ template ... }}` en sus páginas. Nuestra plantilla mínima escribe HTML crudo y solo usa la función `query`, así que no necesita librerías — por eso renderiza incluso con un directorio `console_libraries` vacío.

**6c.** Cualquiera de: una **página de estado mínima y sin dependencias** en un host acotado donde no podés correr ni alcanzar un Grafana separado; una **vista interna de solo lectura rápida** renderizada directamente por Prometheus sin servicio extra que operar, autenticar o parchear; o un **appliance air-gapped/embebido** donde agregar Grafana es desproporcionado para la necesidad. La contrapartida es sin interactividad rica y una característica de plantilla que el proyecto trata como legacy.

</details>

---

### Sources

- Prometheus — Expression browser & visualization: https://prometheus.io/docs/visualization/browser/
- Prometheus — Querying basics (instant vs range vectors): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/query_range`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Console templates & template examples: https://prometheus.io/docs/visualization/consoles/ · https://prometheus.io/docs/prometheus/latest/configuration/template_examples/
- Grafana — Prometheus data source & query editor (`$__rate_interval`): https://grafana.com/docs/grafana/latest/datasources/prometheus/
- Grafana — Provisioning data sources and dashboards: https://grafana.com/docs/grafana/latest/administration/provisioning/
- Grafana — Variables and templating (`label_values`, multi-value): https://grafana.com/docs/grafana/latest/dashboards/variables/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum