# Topic 5.3 — Exporters — Ejercicios guiados

> **Dominio PCA: Instrumentación y Exporters.** Un *exporter* es un proceso puente: lee el estado de un sistema que no habla Prometheus (el kernel, una base de datos, un endpoint HTTP) y lo vuelve a publicar en el formato de exposición de texto de Prometheus, en un endpoint HTTP `/metrics` que un servidor Prometheus puede scrapear. Estos ejercicios construyen un pipeline funcional — Node Exporter, el textfile collector y el Blackbox exporter — y luego lo rompen a propósito para que puedas diagnosticarlo.
>
> **Prerrequisitos:** un host Linux, un binario `prometheus` en ejecución (v2.x), `curl` y salida a internet. Los comandos asumen `bash`. Los números de versión en las descargas son ejemplos — consultá la página de releases para conocer la actual.
>
> **Referencia:** conceptos de exporters y la lista oficial — <https://prometheus.io/docs/instrumenting/exporters/>

---

## Exercise 1 — Desplegar el Node Exporter y leer su salida

El Node Exporter es el exporter de referencia para métricas de hardware y kernel de `*NIX`. Ejecutarlo te enseña la forma de todo exporter: un binario autocontenido que sirve `/metrics`.

**Pasos:**

1. Descargá y descomprimí el binario (ajustá la versión a la release actual):

   ```bash
   VERSION=1.8.2
   curl -sSLO https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz
   tar xzf node_exporter-${VERSION}.linux-amd64.tar.gz
   cd node_exporter-${VERSION}.linux-amd64
   ```

2. Iniciálo en primer plano y leé el log de arranque:

   ```bash
   ./node_exporter
   ```

   Esperado (abreviado):

   ```
   level=info msg="Starting node_exporter" version="(version=1.8.2, ...)"
   level=info msg="Enabled collectors" ... collector=cpu ... collector=filesystem ... collector=meminfo ...
   level=info msg="Listening on" address=[::]:9100
   ```

3. En una segunda terminal, scrapeálo a mano y mirá una sola familia de métricas:

   ```bash
   curl -s localhost:9100/metrics | grep -A2 '^# HELP node_cpu_seconds_total'
   ```

   Esperado:

   ```
   # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
   # TYPE node_cpu_seconds_total counter
   node_cpu_seconds_total{cpu="0",mode="idle"} 40663.94
   ```

4. Listá qué collectors están compilados y habilitados/deshabilitados por defecto:

   ```bash
   ./node_exporter --help 2>&1 | grep -E 'collector\.(cpu|systemd|textfile)'
   ```

5. Reiniciá el exporter con un collector opcional activado y un collector por defecto desactivado:

   ```bash
   ./node_exporter --collector.systemd --no-collector.arp
   ```

> **Comprobación de comprensión — Exercise 1**
> 1. ¿Cuáles son las dos líneas de comentario que preceden a `node_cpu_seconds_total`, y qué declara cada una?
> 2. `node_cpu_seconds_total` tiene una label `mode` con valores como `idle`, `system`, `user`. ¿Por qué es una única familia de métricas con una label en lugar de métricas separadas `node_cpu_idle_seconds`, `node_cpu_system_seconds`, …?
> 3. El valor mostrado es `40663.94` y el `# TYPE` es `counter`. ¿Es útil por sí solo el número crudo `40663.94` para un estudiante que mira el uso de CPU? ¿Qué debe hacerle PromQL primero?
> 4. ¿Cuál es la diferencia práctica entre `--collector.systemd` y `--no-collector.arp` en el paso 5?

---

## Exercise 2 — Scrapear el exporter desde Prometheus y validar con `up`

Un exporter que nadie scrapea no produce series temporales. Acá conectás el Node Exporter a un servidor Prometheus y confirmás que el target está sano usando la métrica sintética `up`.

**Pasos:**

1. Escribí `prometheus.yml` con un job que scrapee el exporter:

   ```yaml
   global:
     scrape_interval: 15s

   scrape_configs:
     - job_name: 'node'
       static_configs:
         - targets: ['localhost:9100']
   ```

2. Iniciá Prometheus apuntando a ese archivo:

   ```bash
   ./prometheus --config.file=prometheus.yml
   ```

3. Abrí <http://localhost:9090/targets> (o consultá la API). Confirmá que el target `node` muestra **State = UP**.

4. Consultá la métrica sintética de salud desde la CLI:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up{job="node"}' | \
     python3 -m json.tool
   ```

   Esperado (abreviado):

   ```json
   {
     "status": "success",
     "data": {
       "result": [
         {
           "metric": {"__name__": "up", "instance": "localhost:9100", "job": "node"},
           "value": [1723296000, "1"]
         }
       ]
     }
   }
   ```

5. Inspeccioná las dos métricas que Prometheus adjunta a cada scrape, independientemente del exporter:

   ```
   scrape_duration_seconds{job="node"}
   scrape_samples_scraped{job="node"}
   ```

6. Detené el Node Exporter (`Ctrl-C` en su terminal). Esperá ~30s, luego volvé a ejecutar la consulta `up` del paso 4.

> **Comprobación de comprensión — Exercise 2**
> 1. ¿De dónde proviene la métrica `up`? ¿La exporta el Node Exporter, o la produce Prometheus mismo?
> 2. En el paso 4 la label `instance` es `localhost:9100`, no `localhost` — ¿de dónde salió ese valor, y qué label de target por defecto se estableció a partir de él?
> 3. Después de que matás el exporter en el paso 6, ¿qué valor toma `up{job="node"}`, y la serie desaparece o permanece presente?
> 4. `scrape_samples_scraped` cuenta las muestras que devuelve el exporter en un scrape. Si este número de pronto se duplica de una release del exporter a la siguiente, ¿qué riesgo operativo señala eso?

---

## Exercise 3 — Extender las métricas con el textfile collector

No siempre podés ejecutar un daemon HTTP de larga vida — pensá en un script de backup nocturno o un cron job. El **textfile collector** resuelve esto: el Node Exporter lee archivos `*.prom` de un directorio y fusiona su contenido en su propio `/metrics`. Esta es la forma canónica de exponer métricas de trabajos batch y métricas de negocio personalizadas.

**Pasos:**

1. Creá el directorio del collector y reiniciá el Node Exporter apuntando a él:

   ```bash
   sudo mkdir -p /var/lib/node_exporter/textfile_collector
   ./node_exporter \
     --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
   ```

2. Escribí un archivo de métricas **atómicamente** — escribí en un archivo temporal, luego `mv` (renombrá) a su lugar para que el collector nunca lea un archivo escrito a medias:

   ```bash
   DIR=/var/lib/node_exporter/textfile_collector
   cat > "$DIR/backup.prom.$$" <<'EOF'
   # HELP job_last_success_timestamp_seconds Unix time of the last successful backup.
   # TYPE job_last_success_timestamp_seconds gauge
   job_last_success_timestamp_seconds{job="db_backup"} 1723295400
   # HELP job_duration_seconds Duration of the last backup run.
   # TYPE job_duration_seconds gauge
   job_duration_seconds{job="db_backup"} 42.7
   EOF
   mv "$DIR/backup.prom.$$" "$DIR/backup.prom"
   ```

3. Confirmá que la métrica ahora aparece en la salida del exporter:

   ```bash
   curl -s localhost:9100/metrics | grep job_last_success
   ```

   Esperado:

   ```
   job_last_success_timestamp_seconds{job="db_backup"} 1723295400
   ```

4. Verificá la métrica de salud propia del collector, que el Node Exporter agrega automáticamente:

   ```bash
   curl -s localhost:9100/metrics | grep node_textfile_scrape_error
   ```

   Esperado:

   ```
   node_textfile_scrape_error 0
   ```

5. Rompélo: escribí un archivo con una línea malformada (una línea de métrica duplicada con un valor distinto, que el parser rechaza) y volvé a verificar `node_textfile_scrape_error`:

   ```bash
   printf 'broken_metric 1\nbroken_metric 2\n' > "$DIR/bad.prom"
   curl -s localhost:9100/metrics | grep node_textfile_scrape_error
   ```

6. Borrá el archivo defectuoso y confirmá que la métrica de error vuelve a `0`:

   ```bash
   rm "$DIR/bad.prom"
   ```

> **Comprobación de comprensión — Exercise 3**
> 1. ¿Por qué es esencial el patrón escribir-en-temporal-y-luego-`mv` del paso 2? ¿Qué podría observar un scrape si escribieras directamente en `backup.prom` con una redirección?
> 2. Para un backup nocturno, ¿por qué `job_last_success_timestamp_seconds` (un timestamp Unix absoluto) es una métrica expuesta mejor que un booleano `backup_ok 1`? Escribí el PromQL que alertaría si el último éxito es más antiguo que 25 horas.
> 3. En el paso 5, ¿que `node_textfile_scrape_error` pase a `1` impide que las *otras* métricas de textfile (de `backup.prom`) se sigan sirviendo?
> 4. ¿Por qué un trabajo batch debería exponer `job_duration_seconds` como un `gauge` y no como un `counter`?

---

## Exercise 4 — El Blackbox exporter y el patrón multi-target de relabeling

El Blackbox exporter sondea endpoints (HTTP, TCP, ICMP, DNS) desde afuera. Su diseño es diferente: **no** hardcodeás los targets en el exporter — pasás el target como parámetro de URL en el momento del scrape. Cablear esto correctamente requiere el patrón multi-target `relabel_configs`, uno de los temas de exporters más evaluados.

**Pasos:**

1. Descargá, descomprimí e iniciá el Blackbox exporter con su config por defecto:

   ```bash
   VERSION=0.25.0
   curl -sSLO https://github.com/prometheus/blackbox_exporter/releases/download/v${VERSION}/blackbox_exporter-${VERSION}.linux-amd64.tar.gz
   tar xzf blackbox_exporter-${VERSION}.linux-amd64.tar.gz
   cd blackbox_exporter-${VERSION}.linux-amd64
   ./blackbox_exporter --config.file=blackbox.yml
   ```

2. Sondeá un target manualmente. Notá que **vos** proporcionás `target` y `module`, no el exporter:

   ```bash
   curl -s 'http://localhost:9115/probe?target=https://prometheus.io&module=http_2xx' | \
     grep -E '^probe_(success|http_status_code|duration_seconds)'
   ```

   Esperado (abreviado):

   ```
   probe_success 1
   probe_http_status_code 200
   probe_duration_seconds 0.183
   ```

3. Ahora agregá el scrape job a `prometheus.yml`. Leé con cuidado las cuatro reglas de relabeling — son el punto central de este ejercicio:

   ```yaml
   scrape_configs:
     - job_name: 'blackbox-http'
       metrics_path: /probe
       params:
         module: [http_2xx]
       static_configs:
         - targets:
             - https://prometheus.io
             - https://example.com
       relabel_configs:
         # 1. Move the target from __address__ into the ?target= URL param
         - source_labels: [__address__]
           target_label: __param_target
         # 2. Expose the probed URL as the human-readable instance label
         - source_labels: [__param_target]
           target_label: instance
         # 3. Point the actual scrape at the blackbox exporter, not the target
         - target_label: __address__
           replacement: localhost:9115
   ```

4. Recargá Prometheus (`kill -HUP <pid>` o reiniciá) y abrí <http://localhost:9090/targets>. Deberías ver **dos** targets `blackbox-http`, uno por cada URL sondeada, cada uno con una label `instance` del sitio que se está sondeando.

5. Consultá los resultados del probe a través de todos los targets:

   ```
   probe_success{job="blackbox-http"}
   probe_http_duration_seconds{job="blackbox-http"}
   ```

6. Inspeccioná la métrica de expiración de certificado que el módulo `http_2xx` emite para targets HTTPS, y escribí una expresión de alerta de expiración:

   ```
   (probe_ssl_earliest_cert_expiry - time()) / 86400
   ```

> **Comprobación de comprensión — Exercise 4**
> 1. Recorré las tres reglas de relabel. Después de que se ejecutan, ¿cuál es el valor de `__address__`, `__param_target` e `instance` para el target `https://prometheus.io`?
> 2. Si **omitís** la regla de relabel 3, ¿qué intentará scrapear Prometheus, y por qué fallará cada probe?
> 3. `module: [http_2xx]` está definido bajo `params`. ¿Cuál es la relación mecánica entre esto y el `&module=http_2xx` que tipeaste a mano en el paso 2?
> 4. ¿Dónde se computa físicamente `probe_success` — en el servidor Prometheus, o dentro del proceso del Blackbox exporter? ¿La ruta de red de qué host mide `probe_duration_seconds`?
> 5. ¿Por qué se lo llama el "multi-target exporter pattern", y por qué no podés simplemente poner `localhost:9115` directamente en `static_configs.targets` como hiciste con el Node Exporter?

---

## Exercise 5 — Diagnosticar un pipeline de exporter roto

Los problemas de exporters en producción casi siempre se manifiestan como `up == 0` o como series faltantes/estancadas. Este ejercicio te da una escalera de diagnóstico repetible.

**Pasos:**

1. Con Prometheus y el Node Exporter corriendo normalmente, confirmá la línea base:

   ```
   up{job="node"}          # expect 1
   ```

2. **Falla A — puerto equivocado.** Editá el target del job `node` a `localhost:9101` (nada escucha ahí), recargá Prometheus y observá el target en `/targets`. Anotá el string de error.

3. Desde la shell, reproducí lo que ve Prometheus:

   ```bash
   curl -v http://localhost:9101/metrics
   ```

   Esperado:

   ```
   *   Trying 127.0.0.1:9101...
   * connect to 127.0.0.1 port 9101 failed: Connection refused
   ```

4. Revertí el puerto a `9100`. **Falla B — exporter vivo pero lento/parcial.** Introducí una discrepancia de scrape timeout agregando al job `node`:

   ```yaml
       scrape_interval: 5s
       scrape_timeout: 10s
   ```

   Recargá y leé el error que reporta Prometheus.

5. Corregí el timeout (`scrape_timeout` debe ser ≤ `scrape_interval`). Ahora inspeccioná las dos series de diagnóstico que distinguen "target caído" de "target lento":

   ```
   up{job="node"}                       # 1 = HTTP scrape succeeded
   scrape_duration_seconds{job="node"}  # how long the scrape took
   ```

6. **Falla C — series estancadas.** Matá el Node Exporter. Consultá en el navegador de expresiones de Prometheus:

   ```
   up{job="node"}                 # goes to 0
   node_cpu_seconds_total         # what happens to these series?
   ```

   Esperá 5 minutos y volvé a consultar `node_cpu_seconds_total`.

> **Comprobación de comprensión — Exercise 5**
> 1. En la Falla A, `up` es `0` y el error del target es `connection refused`. ¿Prometheus conserva las métricas `node_*` del último scrape bueno, o las descarta de inmediato? ¿Qué única serie debería usar una alerta para capturar esta clase de falla de forma genérica?
> 2. La Falla B falla en la **carga de config**, no en el momento del scrape. ¿Por qué Prometheus rechaza un `scrape_timeout` que es mayor que `scrape_interval`?
> 3. `up == 1` pero `scrape_duration_seconds` está trepando hacia tu `scrape_timeout`. ¿Qué te está diciendo esto sobre el exporter, y por qué es invisible si solo alertás sobre `up`?
> 4. En la Falla C, después de que el exporter muere las series `node_cpu_seconds_total` se marcan como *stale* en lugar de conservarse para siempre. ¿Aproximadamente cuánto tiempo después del último scrape exitoso una serie deja de ser devuelta por una consulta instantánea, y por qué importa eso para los cálculos de `rate()` que abarcan la interrupción?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Exercise 1

1. `# HELP node_cpu_seconds_total …` es documentación legible por humanos para la familia de métricas; `# TYPE node_cpu_seconds_total counter` declara su tipo de métrica (counter). Ambas son parte del formato de exposición de texto y preceden a las muestras de esa familia. (Especificación del formato: <https://prometheus.io/docs/instrumenting/exposition_formats/>.)
2. Porque `cpu` y `mode` son *dimensiones* de la misma medición. Modelarlas como labels en una sola familia le permite a PromQL agregar libremente — `sum by (mode) (rate(node_cpu_seconds_total[5m]))` — y permite que nuevas CPUs o modos aparezcan sin cambiar el nombre de la métrica. Nombres de métrica separados serían inagregables y hardcodearían la cardinalidad.
3. No — `40663.94` es la cantidad acumulada de segundos desde el arranque, un counter que crece monótonamente. Por sí solo no significa nada para el "uso actual de CPU". PromQL debe aplicar `rate()` (o `irate()`) sobre un rango para convertir el counter en una tasa por segundo: `rate(node_cpu_seconds_total{mode="idle"}[5m])`.
4. `--collector.systemd` **habilita** un collector que está apagado por defecto (estados de units de systemd). `--no-collector.arp` **deshabilita** un collector (entradas ARP) que está encendido por defecto. Los collectors se activan individualmente para controlar la cardinalidad y el costo del scrape.

### Exercise 2

1. `up` la sintetiza el **servidor Prometheus**, no el exporter. Después de cada scrape Prometheus escribe `up{job,instance}` = `1` si el scrape HTTP tuvo éxito y el payload parseó, `0` en caso contrario. Ningún exporter la emite.
2. Vino de la entrada `targets: ['localhost:9100']`. Prometheus establece la label interna `__address__` a partir de ella, y por defecto copia `__address__` en la label visible `instance`.
3. `up{job="node"}` pasa a `0`, y la serie **permanece presente** (se sigue escribiendo en cada intento de scrape). Esta es exactamente la razón por la que `up` es la señal estándar de "¿está el target alcanzable?" — existe respondan o no los exporters.
4. Una duplicación de `scrape_samples_scraped` significa una explosión de cardinalidad en la salida del exporter — más series para ingestar, almacenar y consultar en cada scrape. Puede reventar silenciosamente la memoria del TSDB y cruzar umbrales de `sample_limit`, así que vale la pena alertar sobre ella.

### Exercise 3

1. El collector puede escanear y parsear el archivo en cualquier instante. Una redirección simple (`> backup.prom`) trunca y luego reescribe, así que un scrape que caiga a mitad de la escritura lee un archivo truncado o vacío y o bien descarta métricas o bien establece `node_textfile_scrape_error 1`. `mv` dentro del mismo filesystem es un rename atómico: el collector siempre ve o el archivo viejo completo o el archivo nuevo completo, nunca uno parcial.
2. Un booleano `backup_ok 1` no puede distinguir "tuvo éxito hace 10 minutos" de "tuvo éxito por última vez hace una semana y ha estado fallando desde entonces" — y si el trabajo muere por completo, nada actualiza el booleano, así que queda en `1` para siempre (stale-positivo). Un timestamp absoluto sigue envejeciendo, así que podés alertar sobre la *obsolescencia*:

   ```
   time() - job_last_success_timestamp_seconds{job="db_backup"} > 25 * 3600
   ```
3. No. El textfile collector parsea cada archivo de forma independiente; que `bad.prom` falle establece `node_textfile_scrape_error` en `1` y descarta solo las métricas de ese archivo. Las métricas de `backup.prom` se siguen sirviendo. La métrica de error es tu señal para investigar.
4. La duración de un backup no es acumulativa y puede subir o bajar entre corridas (es una medición instantánea de la última corrida), así que es un `gauge`. Un `counter` debe crecer monótonamente y está pensado para consumirse vía `rate()`; ninguna de esas propiedades encaja con "duración de la corrida más reciente".

### Exercise 4

1. Después de que las tres reglas se ejecutan para `https://prometheus.io`:
   - `__param_target` = `https://prometheus.io` (la regla 1 lo copió de `__address__`)
   - `instance` = `https://prometheus.io` (la regla 2 lo copió de `__param_target`)
   - `__address__` = `localhost:9115` (la regla 3 lo sobrescribió)

   Así que Prometheus scrapea `http://localhost:9115/probe?module=http_2xx&target=https://prometheus.io`, y las series resultantes llevan una `instance` legible del sitio sondeado.
2. Sin la regla 3, `__address__` sigue siendo igual a la URL sondeada (por ej. `https://prometheus.io`), así que Prometheus intenta scrapear `https://prometheus.io/probe?...`. Ese sitio no es un Blackbox exporter, así que cada scrape falla — estarías pidiéndole al target que se sondee a sí mismo.
3. Son el mismo parámetro de URL, inyectado de dos maneras distintas. `params: { module: [http_2xx] }` le dice a Prometheus que agregue `&module=http_2xx` a cada request a `/probe`, exactamente como lo tipeaste a mano en el paso 2. `params` es el equivalente declarativo del query string.
4. `probe_success` se computa **dentro del Blackbox exporter** — él realiza el probe y reporta el resultado; Prometheus solo scrapea el resultado. `probe_duration_seconds` mide la ruta de red desde el **host del Blackbox exporter** hacia el target, no desde Prometheus. (Docs: <https://github.com/prometheus/blackbox_exporter>.)
5. Una instancia del exporter sirve muchos targets, elegidos por scrape mediante el parámetro `target`, así que un único `localhost:9115` da la cara por una lista arbitraria de endpoints sondeados — ese es el patrón "multi-target". No podés listar `localhost:9115` directamente como el target porque entonces cada serie colapsaría sobre `instance="localhost:9115"` y perderías cuál URL se sondeó; el relabeling es lo que preserva la identidad por-URL mientras enruta el scrape HTTP real hacia el exporter.

### Exercise 5

1. Ante `connection refused` el scrape falla, así que Prometheus no recibe las muestras `node_*` de ese ciclo; esas series se marcan como stale y dejan de devolverse poco después (ver A4). Mantiene `up{job="node"} = 0`. La alerta genérica para toda esta clase es `up == 0` (opcionalmente `for: <duración>`), porque `up` se emite independientemente del estado del exporter.
2. Prometheus fuerza `scrape_timeout <= scrape_interval` en la validación de config: un timeout más largo que el intervalo dejaría un scrape aún corriendo cuando el siguiente vence, así que falla rápido en lugar de solapar scrapes silenciosamente y sesgar los tiempos.
3. Significa que el exporter está respondiendo pero tarda cada vez más en construir su payload — un collector grande, una consulta lenta a un backend, o crecimiento de cardinalidad. Si solo observás `up`, esto es invisible hasta que el scrape finalmente excede `scrape_timeout` y voltea `up` a `0`; observar `scrape_duration_seconds` te da una advertencia temprana mientras `up` sigue en `1`.
4. Después del último scrape exitoso, las series de un target se vuelven stale y dejan de ser devueltas por consultas instantáneas tras aproximadamente el horizonte de obsolescencia (cerca de **5 minutos** por defecto). Durante esa ventana una consulta instantánea todavía devuelve el último valor; pasada ella, la serie se desvanece hasta que el scraping se reanuda. Esto importa para `rate()`: un hueco más largo que la ventana de rango (o el horizonte de obsolescencia) no deja muestras adyacentes sobre las cuales computar una tasa, así que `rate()` no devuelve datos a través de la interrupción en lugar de un valor fabricado.

</details>

---

**Sources**

- Prometheus — Exporters and integrations: <https://prometheus.io/docs/instrumenting/exporters/>
- Prometheus — Text exposition formats: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Prometheus — Monitoring Linux host metrics with the Node Exporter: <https://prometheus.io/docs/guides/node-exporter/>
- `prometheus/node_exporter` (textfile collector, collector flags): <https://github.com/prometheus/node_exporter>
- `prometheus/blackbox_exporter` (multi-target probing, module config): <https://github.com/prometheus/blackbox_exporter>
- Prometheus — Configuration (`relabel_configs`, `scrape_timeout`, `params`): <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- PCA Curriculum: <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>