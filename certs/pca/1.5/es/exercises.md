# PCA — Tema 1.5: Operadores binarios (ejercicios guiados)

> **Dominio:** PromQL · **Peso en el examen:** 4
> **Qué vas a practicar:** operadores binarios aritméticos, de comparación y lógicos/de conjuntos; emparejamiento de vectores con `on` / `ignoring`; uniones de muchos a uno con `group_left` / `group_right`; el modificador `bool`; y la precedencia de operadores.
>
> **Fuentes principales**
> - Operadores de PromQL: https://prometheus.io/docs/prometheus/latest/querying/operators/
> - Fundamentos de consultas (vector instantáneo, escalar): https://prometheus.io/docs/prometheus/latest/querying/basics/
> - API HTTP de consultas: https://prometheus.io/docs/prometheus/latest/querying/api/
> - Métricas de node_exporter: https://github.com/prometheus/node_exporter
> - Currículo PCA de la CNCF: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

Cada consulta de abajo se ejecuta en el **navegador de expresiones de Prometheus** (`http://localhost:9090/graph`, pestaña *Table*) o a través de la **API HTTP** con `curl` + `jq`. Las salidas de ejemplo dependen de la máquina — lo que importa es la *forma* y las *etiquetas*, no los números exactos.

---

## Ejercicio 0 — Armá el laboratorio

Necesitás series reales con conjuntos de etiquetas ricos para que los operadores binarios tengan sentido. Ejecutamos Prometheus haciendo scraping de sí mismo más un `node_exporter`.

1. Creá un directorio de trabajo y una configuración de scrape:

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 5s
     evaluation_interval: 5s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']
     - job_name: node
       static_configs:
         - targets: ['node-exporter:9100']
   ```

2. Creá la definición del stack:

   ```yaml
   # docker-compose.yml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       ports: ["9090:9090"]
       volumes:
         - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
       command: ["--config.file=/etc/prometheus/prometheus.yml"]
     node-exporter:
       image: prom/node-exporter:v1.8.1
       ports: ["9100:9100"]
   ```

3. Levantalo y esperá ~15 s a los primeros scrapes:

   ```bash
   docker compose up -d
   sleep 15
   ```

4. Confirmá que ambos targets estén sanos. En el navegador de expresiones ejecutá `up`, o desde la shell:

   ```bash
   curl -s -G http://localhost:9090/api/v1/query \
     --data-urlencode 'query=up' | jq -r '.data.result[] | "\(.metric.job)\t\(.value[1])"'
   ```

   Esperado (aproximado):

   ```
   node       1
   prometheus 1
   ```

5. Definí un helper de shell que reutilizarás en cada ejercicio (requiere `jq`):

   ```bash
   promql() {
     curl -s -G http://localhost:9090/api/v1/query \
       --data-urlencode "query=$1" \
     | jq -r '.data.result[] | "\(.metric)  =>  \(.value[1])"'
   }
   ```

   Probalo con una prueba rápida:

   ```bash
   promql 'up'
   ```

**Comprobá lo que entendiste**

- **Q0.1** En el JSON que devuelve `/api/v1/query`, `value` es un array de dos elementos. ¿Cuáles son los dos elementos, y cuál imprime el helper `promql`?
- **Q0.2** La métrica `up` lleva una etiqueta `job` y una etiqueta `instance` aunque `prometheus.yml` nunca las define. ¿De dónde vienen esas dos etiquetas?

---

## Ejercicio 1 — Aritmética entre un vector y un escalar

Un operador aritmético binario (`+ - * / % ^`) aplicado entre un **vector instantáneo** y un **escalar** opera elemento por elemento sobre los valores de muestra del vector.

1. Leé la memoria total en bytes:

   ```bash
   promql 'node_memory_MemTotal_bytes'
   ```

   ```
   {__name__="node_memory_MemTotal_bytes",instance="node-exporter:9100",job="node"}  =>  16768331776
   ```

2. Convertila a **GiB** dividiendo por `1024^3`:

   ```bash
   promql 'node_memory_MemTotal_bytes / 1024 / 1024 / 1024'
   ```

   ```
   {instance="node-exporter:9100",job="node"}  =>  15.616...
   ```

3. Hacé la misma conversión con exponenciación en lugar de división encadenada:

   ```bash
   promql 'node_memory_MemTotal_bytes / 1024^3'
   ```

4. Calculá cuántos **segundos** lleva activo cada target de Prometheus desde el arranque de su proceso, luego compará con la métrica cruda:

   ```bash
   promql 'time() - process_start_time_seconds'
   ```

**Comprobá lo que entendiste**

- **Q1.1** Compará las etiquetas del paso 1 con las del paso 2. Una etiqueta desaparece en el resultado. ¿Cuál, y por qué la aritmética la elimina?
- **Q1.2** En el paso 3, ¿por qué `1024^3` se evalúa antes que la división? (Nombrá la regla.)
- **Q1.3** `time()` devuelve un **escalar**, y `process_start_time_seconds` es un **vector instantáneo**. ¿De qué tipo es el resultado del paso 4, y cuántas series contiene en relación con la cantidad de targets scrapeados?

---

## Ejercicio 2 — Aritmética entre dos vectores instantáneos (emparejamiento automático)

Cuando ambos operandos son vectores instantáneos, Prometheus realiza **emparejamiento de vectores uno a uno**: por cada elemento de la izquierda busca exactamente un elemento de la derecha cuyo **conjunto de etiquetas completo sea idéntico**, luego aplica el operador a los dos valores.

1. Calculá la **memoria disponible como porcentaje** del total:

   ```bash
   promql 'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100'
   ```

   ```
   {instance="node-exporter:9100",job="node"}  =>  47.13...
   ```

2. Calculá la **fracción de filesystem usada** por mountpoint (available y size comparten el mismo conjunto de etiquetas — `device`, `fstype`, `mountpoint`, `instance`, `job`):

   ```bash
   promql '1 - (node_filesystem_avail_bytes{fstype!="tmpfs"}
                / node_filesystem_size_bytes{fstype!="tmpfs"})'
   ```

   ```
   {device="overlay",fstype="overlay",mountpoint="/",instance="node-exporter:9100",job="node"}  =>  0.38...
   ```

3. Ahora rompé el emparejamiento a propósito. Agregá el denominador para que pierda sus etiquetas distintivas, luego dividí:

   ```bash
   promql 'node_filesystem_avail_bytes{fstype!="tmpfs"}
           / sum(node_filesystem_size_bytes{fstype!="tmpfs"})'
   ```

   Observá: el resultado está **vacío**.

**Comprobá lo que entendiste**

- **Q2.1** En el paso 1, tanto `MemAvailable` como `MemTotal` llevan solo `instance` y `job`. Explicá, en términos de emparejamiento, por qué se produce exactamente una serie de resultado.
- **Q2.2** ¿Por qué el resultado del paso 3 está vacío en lugar de dar un error? Describí los conjuntos de etiquetas de cada lado.
- **Q2.3** El resultado del paso 2 no tiene `__name__`. Si quisieras que la serie sobreviviente tuviera *nombre*, ¿qué familia de operadores tendrías que usar en lugar de la aritmética?

---

## Ejercicio 3 — Controlar el emparejamiento con `on` e `ignoring`

Por defecto el emparejamiento usa el conjunto de etiquetas **completo**. `ignoring(<labels>)` empareja por cada etiqueta *excepto* las listadas; `on(<labels>)` empareja *solo* por las listadas.

1. Reproducí el paso 1 del ejercicio 2, pero emparejá solo por `instance`:

   ```bash
   promql 'node_memory_MemAvailable_bytes
           / on(instance) node_memory_MemTotal_bytes'
   ```

   Mismo resultado numérico — pero fijate qué etiquetas sobreviven.

2. Obtené el mismo valor usando `ignoring` en su lugar:

   ```bash
   promql 'node_memory_MemAvailable_bytes
           / ignoring(job) node_memory_MemTotal_bytes'
   ```

3. Dispará el clásico error de **muchos a uno**. Dividí el contador de CPU crudo por modo entre un total por CPU que descartó la etiqueta `mode`:

   ```bash
   promql 'node_cpu_seconds_total
           / ignoring(mode) sum by (cpu, instance, job) (node_cpu_seconds_total)'
   ```

   Error esperado:

   ```
   Error executing query: multiple matches for labels:
   many-to-one matching must be explicit (group_left/group_right)
   ```

**Comprobá lo que entendiste**

- **Q3.1** En el paso 1, el resultado conserva `instance` pero descarta `job`. ¿Por qué `on(instance)` elimina `job` de la salida mientras que el paso 1 del ejercicio 2 conservaba ambas etiquetas?
- **Q3.2** Los pasos 1 y 2 devuelven el mismo número. ¿Bajo qué cambio en los datos dejarían `on(instance)` e `ignoring(job)` de ser equivalentes?
- **Q3.3** Explicá el error del paso 3 en términos de "cuántas series de la izquierda emparejan con una serie de la derecha".

---

## Ejercicio 4 — Operadores de comparación como filtros

Los operadores de comparación (`== != > < >= <=`) entre un vector instantáneo y un escalar (o dos vectores) **filtran**: los elementos para los que la comparación es falsa se descartan; los sobrevivientes **pasan sin cambios**, conservando su nombre de métrica y su valor original.

1. Listá los filesystems que están más del **60 % llenos**:

   ```bash
   promql '(1 - node_filesystem_avail_bytes{fstype!="tmpfs"}
              / node_filesystem_size_bytes{fstype!="tmpfs"}) > 0.60'
   ```

2. Listá solo los targets que están **caídos**:

   ```bash
   promql 'up == 0'
   ```

   En un laboratorio sano esto no devuelve **nada**.

3. Mostrá que los valores sobrevivientes conservan la identidad de métrica original:

   ```bash
   promql 'node_memory_MemAvailable_bytes > 100e6'
   ```

   ```
   {__name__="node_memory_MemAvailable_bytes",instance="node-exporter:9100",job="node"}  =>  7903137792
   ```

**Comprobá lo que entendiste**

- **Q4.1** En el paso 3 el valor impreso es `7903137792`, no `1`. Contrastá esto con lo que la aritmética le hizo al nombre de métrica en el ejercicio 2 — ¿qué preserva una comparación *de filtrado* que la aritmética no?
- **Q4.2** El paso 2 devuelve un resultado vacío cuando todo está sano. ¿Por qué "resultado vacío" es un resultado significativo e *intencional* para una expresión de alerta construida sobre `up == 0`?

---

## Ejercicio 5 — El modificador `bool`

Prefijá una comparación con `bool` y deja de filtrar: cada elemento de entrada sobrevive, pero su valor pasa a ser `1` (verdadero) o `0` (falso), y el **nombre de métrica se descarta**.

1. Contá los targets caídos de dos maneras distintas:

   ```bash
   promql 'count(up == 0)'        # filter, then count survivors
   promql 'sum(up == bool 0)'     # map to 0/1, then sum
   ```

2. Observá la diferencia cuando **todos los targets están activos**. Ejecutá ambas de nuevo en el laboratorio sano y compará las salidas — una está *vacía*, la otra es `0`.

3. Compará dos escalares. Este es el único lugar donde `bool` es **obligatorio**:

   ```bash
   promql '2 > bool 1'
   ```

   Después probalo sin `bool` y leé el error del parser:

   ```bash
   promql '2 > 1'
   ```

**Comprobá lo que entendiste**

- **Q5.1** En el paso 1, ambas expresiones devuelven `0` targets caídos en la mayoría de los estados. En el paso 2, ¿por qué `count(up == 0)` devuelve *vacío* mientras que `sum(up == bool 0)` devuelve el `0` literal? ¿Cuál es más seguro graficar como "cantidad de targets caídos a lo largo del tiempo"?
- **Q5.2** ¿Por qué Prometheus rechaza `2 > 1` entre dos escalares pero acepta `2 > bool 1`?

---

## Ejercicio 6 — Operadores lógicos / de conjuntos: `and`, `or`, `unless`

Estos operan **solo entre dos vectores instantáneos** y emparejan por conjuntos de etiquetas idénticos (ajustable con `on` / `ignoring`). `group_left` / `group_right` **no** están permitidos aquí.

- `and` → elementos del LHS que tienen un elemento coincidente en el RHS (intersección)
- `or` → todos los elementos del LHS, más los elementos del RHS que no tuvieron coincidencia en el LHS (unión)
- `unless` → elementos del LHS que **no** tienen coincidencia en el RHS (complemento)

1. Filesystems que están a la vez **>50 % llenos** *y* tienen **menos de 20 GiB libres**:

   ```bash
   promql '((1 - node_filesystem_avail_bytes{fstype!="tmpfs"}
                / node_filesystem_size_bytes{fstype!="tmpfs"}) > 0.50)
           and
           (node_filesystem_avail_bytes{fstype!="tmpfs"} < 20 * 1024^3)'
   ```

2. Filesystems más del 50 % llenos **excepto** el mount raíz:

   ```bash
   promql '((1 - node_filesystem_avail_bytes{fstype!="tmpfs"}
                / node_filesystem_size_bytes{fstype!="tmpfs"}) > 0.50)
           unless
           node_filesystem_avail_bytes{mountpoint="/"}'
   ```

3. Inspeccioná los valores que salen del paso 1.

**Comprobá lo que entendiste**

- **Q6.1** El operando izquierdo de `and` en el paso 1 es un resultado *aritmético/de comparación* (sin nombre de métrica), y el operando derecho es una métrica cruda. `and` empareja por el conjunto de etiquetas completo — ¿por qué estos dos igual emparejan a pesar de tener distinto `__name__`? (Pista: ¿es `__name__` parte del conjunto de etiquetas de emparejamiento acá?)
- **Q6.2** Para las series sobrevivientes del paso 1, ¿los **valores** vienen del lado izquierdo, del derecho, o de una combinación? ¿Y con `or`?
- **Q6.3** Reescribí la intención del paso 2 — "más del 50 % lleno **y no** raíz" — usando `and` en lugar de `unless`. ¿Qué tendrías que agregar a la consulta?

---

## Ejercicio 7 — Muchos a uno / uno a muchos: `group_left` y `group_right`

Cuando un lado tiene varias series que legítimamente se corresponden con una **única** serie del otro lado, tenés que declarar explícitamente el lado de "muchos". `group_left` = el lado **izquierdo** es el de "muchos"; `group_right` = el lado **derecho** es el de "muchos". Las etiquetas opcionales entre paréntesis se **copian desde el lado de "uno"** al resultado.

### Parte A — Corregí el error de muchos a uno del ejercicio 3

1. Agregá `group_left` para calcular la **fracción** de cada modo de CPU sobre el tiempo total de esa CPU:

   ```bash
   promql 'node_cpu_seconds_total
           / ignoring(mode) group_left
             sum by (cpu, instance, job) (node_cpu_seconds_total)'
   ```

   ```
   {cpu="0",mode="idle",instance="node-exporter:9100",job="node"}    =>  0.91...
   {cpu="0",mode="system",instance="node-exporter:9100",job="node"}  =>  0.02...
   {cpu="0",mode="user",instance="node-exporter:9100",job="node"}    =>  0.03...
   ...
   ```

2. Verificá la unión: las fracciones de una CPU deben sumar 1:

   ```bash
   promql 'sum by (cpu) (
             node_cpu_seconds_total
             / ignoring(mode) group_left
               sum by (cpu, instance, job) (node_cpu_seconds_total))'
   ```

### Parte B — Enriquecé métricas a partir de una métrica "info"

`node_uname_info` es una métrica de valor `1` que lleva etiquetas descriptivas (`nodename`, `release`, …). Multiplicar por ella preserva el valor de muestra (× 1) mientras **injerta** una etiqueta con `group_left`.

3. Adjuntá el `nodename` del host a cada contador de CPU por modo:

   ```bash
   promql 'node_cpu_seconds_total
           * on(instance, job) group_left(nodename)
             node_uname_info'
   ```

   ```
   {cpu="0",mode="idle",nodename="1f3c2a...",instance="node-exporter:9100",job="node"} => 41233.7
   ...
   ```

4. Reescribí el paso 3 usando `group_right` para que la métrica info quede a la izquierda. Predecí qué lado debe moverse antes de ejecutarlo.

**Comprobá lo que entendiste**

- **Q7.1** En la parte A, ¿qué lado es el de "muchos" y cuál el de "uno"? ¿Por qué `group_left` es la opción correcta en lugar de `group_right`?
- **Q7.2** El resultado del paso 1 no tiene `__name__` pero conserva la etiqueta `mode`. ¿De dónde viene `mode`, dado que el lado derecho la descartó vía `sum by`?
- **Q7.3** En el paso 3, `node_uname_info` tiene valor `1`. ¿Cuál es el propósito de multiplicar por ella acá, dado que el valor numérico no cambia? ¿Qué agrega `group_left(nodename)` que un `*` simple no podría?
- **Q7.4** Escribí la consulta del paso 4 (métrica info como operando *izquierdo*) que produce las mismas series de CPU enriquecidas.

---

## Ejercicio 8 — Precedencia y asociatividad de operadores

Precedencia, de mayor → menor:

1. `^`  2. `* / % atan2`  3. `+ -`  4. `== != <= < >= >`  5. `and unless`  6. `or`

`^` es **asociativo por la derecha**; todos los demás operadores son **asociativos por la izquierda**.

1. Asociatividad por la derecha de `^`:

   ```bash
   promql '2 ^ 3 ^ 2'
   ```

2. Multiplicación antes que suma — predecí, después ejecutá:

   ```bash
   promql '2 + 3 * 4'
   promql '(2 + 3) * 4'
   ```

3. Asociatividad por la izquierda de la resta:

   ```bash
   promql '10 - 2 - 3'
   ```

4. `and` liga más fuerte que `or`. Predecí el agrupamiento de esta expresión antes de ejecutarla contra el laboratorio:

   ```bash
   promql 'up == 1 or up == 0 and up == 1'
   ```

5. `*` y `/`, de la misma precedencia, se ejecutan de izquierda a derecha sobre un vector:

   ```bash
   promql 'node_filesystem_avail_bytes{mountpoint="/"}
           / node_filesystem_size_bytes{mountpoint="/"} * 100'
   ```

**Comprobá lo que entendiste**

- **Q8.1** ¿A qué evalúa `2 ^ 3 ^ 2`, y cuánto sería si `^` fuera asociativo por la izquierda?
- **Q8.2** Dá los paréntesis implícitos de `up == 1 or up == 0 and up == 1`.
- **Q8.3** En el paso 5, ¿la expresión es `(avail / size) * 100` o `avail / (size * 100)`? Enunciá la regla que lo decide.

---

## Limpieza

```bash
docker compose down
```

---

<details>
<summary><strong>Clave de respuestas — clic para expandir</strong></summary>

### Ejercicio 0
- **Q0.1** `value` es `[<unix_timestamp_seconds>, "<sample_value_as_string>"]`. El helper imprime `.value[1]`, el valor de muestra (Prometheus devuelve los valores de muestra como strings). `.value[0]` es el timestamp de evaluación.
- **Q0.2** Se adjuntan automáticamente por el proceso de scrape: `job` viene del `job_name` del `scrape_config`, e `instance` toma por defecto el `<host>:<port>` del target scrapeado. No están presentes en la salida de exposición — Prometheus las agrega.

### Ejercicio 1
- **Q1.1** La etiqueta `__name__` (`node_memory_MemTotal_bytes`) se descarta. Cualquier operador **aritmético** binario elimina el nombre de métrica, porque el resultado ya no es esa métrica — es un valor derivado.
- **Q1.2** **Precedencia** de operadores: `^` tiene la precedencia más alta de todos los operadores binarios, así que `1024^3` se calcula antes que la `/`.
- **Q1.3** El resultado es un **vector instantáneo** (la aritmética escalar-sobre-vector produce un vector). Contiene **una serie por cada serie de entrada** de `process_start_time_seconds` — una por target scrapeado — con el nombre de métrica descartado.

### Ejercicio 2
- **Q2.1** Ambos operandos llevan exactamente el mismo conjunto de etiquetas (`{instance, job}`) con valores idénticos, así que el emparejamiento uno a uno encuentra exactamente una pareja para el único elemento de la izquierda → exactamente una serie de resultado.
- **Q2.2** No hay **error**, solo un resultado **vacío**: el lado izquierdo tiene `{device, fstype, mountpoint, instance, job}` mientras que `sum(...)` colapsa todo a una única serie **sin etiquetas**. Ningún elemento de la izquierda encuentra un elemento de la derecha con un conjunto de etiquetas idéntico, así que nada empareja y la salida está vacía. (Una coincidencia *vacía* no es un error; una coincidencia *duplicada* sí lo es.)
- **Q2.3** Los operadores **lógicos/de conjuntos** (`and`, `or`, `unless`) — y las **comparaciones** de filtrado — pasan las series con sus nombres intactos. La aritmética siempre elimina `__name__`.

### Ejercicio 3
- **Q3.1** Con `on(instance)`, el emparejamiento considera *solo* `instance`; toda etiqueta que **no** esté en el conjunto de `on` (acá `job`) no forma parte de la coincidencia y por lo tanto se **descarta** de la salida. En el paso 1 del ejercicio 2, el emparejamiento por defecto usaba el conjunto de etiquetas completo, así que ambas etiquetas eran compartidas y ambas sobrevivieron.
- **Q3.2** Divergen en cuanto los dos lados difieren en alguna *otra* etiqueta. `ignoring(job)` sigue emparejando por todo excepto `job` (así que cualquier etiqueta compartida adicional también debe coincidir), mientras que `on(instance)` empareja solo por `instance` e ignora todas las demás etiquetas. Topologías de etiquetas distintas → coincidencias distintas (o ambiguas).
- **Q3.3** Por cada grupo `(cpu, instance, job)`, el lado izquierdo (`node_cpu_seconds_total`) tiene **muchas** series — una por `mode` — mientras que el lado derecho tiene exactamente **una** (mode fue sumado y eliminado). Muchos elementos de la izquierda emparejando con un elemento de la derecha es una relación de muchos a uno, que Prometheus rechaza a menos que la hagas explícita con `group_left`.

### Ejercicio 4
- **Q4.1** Una comparación *de filtrado* preserva el **nombre de métrica y el valor de muestra original** de cada elemento sobreviviente (solo elimina los que no pasan la prueba). La aritmética, en cambio, calcula un valor nuevo y descarta el nombre. Por eso el paso 3 imprime el conteo de bytes, no `1`.
- **Q4.2** Para una alerta querés que una serie **exista solo cuando se cumple la condición mala**. `up == 0` produce series exactamente para los targets caídos y nada en caso contrario, así que una regla de alerta se dispara precisamente cuando hay al menos una serie presente — el resultado vacío es la señal de "todo sano".

### Ejercicio 5
- **Q5.1** `up == 0` filtra: cuando nada está caído, no hay series sobrevivientes, así que `count(...)` agrega un vector vacío y devuelve **vacío** (sin punto de dato). `up == bool 0` conserva cada serie de `up` y la mapea a 0/1; con todos los targets activos, cada elemento es `0`, y `sum(...)` devuelve el valor tipo escalar **`0`**. Para un gráfico/medidor de "targets caídos a lo largo del tiempo", la **versión con `bool` es más segura** porque siempre emite un valor (`0`) en lugar de un hueco.
- **Q5.2** Una comparación entre **dos escalares** debe usar `bool`: sin él la operación no tiene semántica de filtrado definida (no hay vector que filtrar), así que Prometheus la rechaza como error de parseo. `bool` le da un resultado definido: `1` o `0`.

### Ejercicio 6
- **Q6.1** `and` empareja por el conjunto de etiquetas completo, pero `__name__` se trata como cualquier otra etiqueta **y ambos lados acá efectivamente carecen de una discrepancia de nombre distintiva en el conjunto de emparejamiento** — más precisamente, los operadores de conjunto emparejan por las etiquetas presentes, y como el nombre de métrica no forma parte de lo que debe ser igual para la coincidencia buscada (el lado izquierdo ya tenía su nombre eliminado por la aritmética), las etiquetas restantes (`device, fstype, mountpoint, instance, job`) coinciden. Los operandos emparejan por esas etiquetas compartidas.
- **Q6.2** Para `and`, las series sobrevivientes conservan los valores (y etiquetas) del lado **izquierdo** sin cambios; el lado derecho solo decide *si* cada elemento de la izquierda sobrevive. Para `or`, los valores vienen de la izquierda para las posiciones coincidentes, más los valores propios del lado **derecho** para los elementos que aporta y que no tuvieron coincidencia en la izquierda.
- **Q6.3** No podés expresar "no raíz" solo con `and`, porque `and` conserva solo los elementos que *coinciden* con el RHS. Necesitarías un operando derecho que represente "todo excepto raíz" — por ejemplo, filtrar con un matcher de etiquetas (`... and node_filesystem_avail_bytes{mountpoint!="/"}`) — que es exactamente el caso que `unless` maneja de forma más directa.

### Ejercicio 7
- **Q7.1** El lado **izquierdo** (`node_cpu_seconds_total`, muchos `mode` por CPU) es el de "muchos"; el lado **derecho** (el total sumado, uno por CPU) es el de "uno". Como el lado de muchos está a la izquierda, `group_left` es correcto. `group_right` declararía erróneamente al lado derecho como el lado de muchos.
- **Q7.2** `mode` viene del lado **izquierdo**. En el emparejamiento de muchos a uno el resultado lleva las etiquetas del lado de "muchos" (izquierdo), así que `mode` se conserva aunque el lado derecho la haya descartado vía `sum by`.
- **Q7.3** Multiplicar por la métrica info de valor `1` es una operación nula sobre el número (× 1) — su único propósito es realizar la **unión**. `group_left(nodename)` copia la etiqueta `nodename` del lado de "uno" (la métrica info) al resultado. Un `*` simple sin `group_left(nodename)` igual emparejaría, pero la etiqueta extra **no** se copiaría a la salida.
- **Q7.4**
  ```promql
  node_uname_info
  * on(instance, job) group_right(nodename)
    node_cpu_seconds_total
  ```
  El lado de muchos (`node_cpu_seconds_total`) ahora está a la derecha, así que se usa `group_right`; `nodename` sigue siendo la etiqueta copiada porque vive en el lado de "uno" (la métrica info, ahora a la izquierda).

### Ejercicio 8
- **Q8.1** `2 ^ 3 ^ 2 = 2 ^ (3 ^ 2) = 2 ^ 9 = 512` porque `^` es asociativo por la derecha. Si fuera asociativo por la izquierda sería `(2 ^ 3) ^ 2 = 8 ^ 2 = 64`.
- **Q8.2** `up == 1 or (up == 0 and up == 1)` — `and` liga más fuerte que `or`.
- **Q8.3** Es `(avail / size) * 100`. `*` y `/` comparten la misma precedencia y son **asociativos por la izquierda**, así que la evaluación va de izquierda a derecha.

</details>