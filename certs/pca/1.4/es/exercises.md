# Ejercicios Guiados — Tema 1.4: Agregación sobre Dimensiones

> **Dominio:** PromQL · **Peso en el examen:** 4 · **Certificación:** Prometheus Certified Associate (PCA)
>
> Estos ejercicios son **reproducibles**: construís un pequeño laboratorio de Prometheus + Pushgateway, cargás un dataset multidimensional *determinista*, y cada salida esperada que aparece abajo está calculada a mano a partir de esos datos. Recorré los pasos en orden, respondé las preguntas de control **antes** de expandir la sección de respuestas al final.
>
> **Fuentes de referencia (oficiales):**
> - Operadores de agregación — https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
> - Fundamentos de consultas (vectores instantáneos vs de rango) — https://prometheus.io/docs/prometheus/latest/querying/basics/
> - Funciones de consulta (`rate`, `*_over_time`) — https://prometheus.io/docs/prometheus/latest/querying/functions/
> - Buenas prácticas de recording-rules / agregación — https://prometheus.io/docs/practices/rules/
> - Pushgateway — https://github.com/prometheus/pushgateway
> - Currículum PCA — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

---

## Qué significa realmente "agregar sobre dimensiones"

Un **vector instantáneo** de Prometheus es un conjunto de series temporales, cada una identificada por una combinación única de etiquetas, evaluada en un único instante. Esas etiquetas *son* las dimensiones. Un **operador de agregación** colapsa una o más de esas dimensiones, plegando muchas series en menos (o en una) al combinar sus valores de muestra.

Mantené claros dos ejes ortogonales desde el principio — el examen evalúa la confusión entre ambos:

| | Colapsa la **dimensión de series (etiquetas)** | Colapsa la **dimensión de tiempo** |
|---|---|---|
| Opera en | un instante, a través de muchas series | una serie, a través de un rango de tiempo |
| Herramientas | **operadores** de agregación: `sum`, `avg`, `topk`, `quantile`, … con `by`/`without` | **funciones** de agregación: `sum_over_time`, `avg_over_time`, `max_over_time`, … |
| Entrada | vector instantáneo | vector de rango |

El Tema 1.4 es la **columna izquierda**. El Ejercicio 8 hace el contraste explícito para que nunca elijas la herramienta equivocada.

---

## Ejercicio 0 — Construir el laboratorio

**Pasos**

1. Creá un directorio de trabajo y la configuración de Prometheus. Fijate en `honor_labels: true` en el job de Pushgateway — hace que Prometheus mantenga las etiquetas que enviamos (`job="demo_api"`) en vez de sobrescribirlas.

   ```bash
   mkdir promql-agg && cd promql-agg
   ```

   `prometheus.yml`:
   ```yaml
   global:
     scrape_interval: 5s
     evaluation_interval: 5s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: pushgateway
       honor_labels: true          # keep pushed job/instance labels verbatim
       static_configs:
         - targets: ['pushgateway:9091']
   ```

2. Levantá Prometheus y Pushgateway con Compose.

   `docker-compose.yml`:
   ```yaml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       command:
         - --config.file=/etc/prometheus/prometheus.yml
       volumes:
         - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
       ports:
         - "9090:9090"

     pushgateway:
       image: prom/pushgateway:v1.9.0
       ports:
         - "9091:9091"
   ```

   ```bash
   docker compose up -d
   ```

3. Enviá el dataset determinista. Este es un conjunto *estático* de muestras counter/gauge — perfecto para la agregación de vectores instantáneos porque los valores nunca se mueven.

   ```bash
   cat <<'EOF' | curl --data-binary @- http://localhost:9091/metrics/job/demo_api
   # TYPE demo_http_requests_total counter
   demo_http_requests_total{region="us-east",app="checkout",method="GET",code="200"} 100
   demo_http_requests_total{region="us-east",app="checkout",method="GET",code="500"} 5
   demo_http_requests_total{region="us-east",app="checkout",method="POST",code="200"} 40
   demo_http_requests_total{region="us-east",app="cart",method="GET",code="200"} 200
   demo_http_requests_total{region="us-east",app="cart",method="GET",code="500"} 20
   demo_http_requests_total{region="eu-west",app="checkout",method="GET",code="200"} 80
   demo_http_requests_total{region="eu-west",app="checkout",method="GET",code="500"} 10
   demo_http_requests_total{region="eu-west",app="cart",method="GET",code="200"} 150
   demo_http_requests_total{region="eu-west",app="cart",method="POST",code="200"} 60
   demo_http_requests_total{region="eu-west",app="cart",method="POST",code="500"} 15
   # TYPE demo_pods_ready gauge
   demo_pods_ready{node="n1"} 3
   demo_pods_ready{node="n2"} 3
   demo_pods_ready{node="n3"} 5
   demo_pods_ready{node="n4"} 3
   demo_pods_ready{node="n5"} 5
   EOF
   ```

4. Esperá ~10 s a que haya un scrape, después confirmá que los datos llegaron. De acá en adelante podés ejecutar las consultas **ya sea** en el navegador de expresiones en http://localhost:9090/graph (usá la pestaña **Table**) **o** vía la API HTTP:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(demo_http_requests_total)' \
     | jq '.data.result[0].value[1]'
   ```

   Salida esperada:
   ```
   "10"
   ```

**Punto de control**

- **Q1.** `demo_http_requests_total` tiene diez series. ¿Cuáles *etiquetas* son las dimensiones disponibles para agregar? (Incluí las que agregó Pushgateway.)
- **Q2.** ¿Por qué la vista Table — y no la vista Graph — importa para las agregaciones que estás por ejecutar sobre este dataset estático?

---

## Ejercicio 1 — Tu primer colapso, y el nombre de métrica que desaparece

**Pasos**

1. Sumá cada serie en un único escalar-por-vector:

   ```
   sum(demo_http_requests_total)
   ```
   Esperado (vista Table):
   ```
   {}   680
   ```

2. Mirá con atención el conjunto de etiquetas del resultado: `{}`. Ahora compará contra una consulta que **no** agrega:

   ```
   demo_http_requests_total{app="cart",region="us-east"}
   ```
   Esperado:
   ```
   demo_http_requests_total{app="cart",code="200",method="GET",region="us-east",job="demo_api"}   200
   demo_http_requests_total{app="cart",code="500",method="GET",region="us-east",job="demo_api"}    20
   ```

3. Confirmá el total de forma independiente: `100+5+40+200+20+80+10+150+60+15 = 680`.

**Punto de control**

- **Q3.** El resultado agregado perdió la etiqueta `__name__` (el nombre de la métrica `demo_http_requests_total`) *y* todas las demás etiquetas. Enunciá la regla general sobre lo que los operadores de agregación le hacen a las etiquetas **cuando no se da una cláusula `by`/`without`**.
- **Q4.** Verdadero o falso: `sum(demo_http_requests_total)` y `sum(demo_pods_ready)` podrían llegar a colisionar en la misma serie de salida si se ejecutan en la misma expresión. Explicá en términos de conjuntos de etiquetas.

---

## Ejercicio 2 — Agrupar con `by`

`by (<labels>)` dice *mantené solo estas etiquetas*; todo lo demás se pliega.

**Pasos**

1. Requests por región:
   ```
   sum by (region) (demo_http_requests_total)
   ```
   Esperado:
   ```
   {region="us-east"}   365
   {region="eu-west"}   315
   ```

2. Requests por app:
   ```
   sum by (app) (demo_http_requests_total)
   ```
   Esperado:
   ```
   {app="checkout"}   235
   {app="cart"}       445
   ```

3. Agrupación bidimensional — región × clase de respuesta:
   ```
   sum by (region, code) (demo_http_requests_total)
   ```
   Esperado:
   ```
   {region="us-east",code="200"}   340
   {region="us-east",code="500"}    25
   {region="eu-west",code="200"}   290
   {region="eu-west",code="500"}    25
   ```

4. Vía la API, para ver la forma cruda:
   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=sum by (region) (demo_http_requests_total)' \
     | jq -c '.data.result[] | {metric, value: .value[1]}'
   ```
   Esperado:
   ```
   {"metric":{"region":"us-east"},"value":"365"}
   {"metric":{"region":"eu-west"},"value":"315"}
   ```

**Punto de control**

- **Q5.** Cada uno de los subtotales de los pasos 1–3 vuelve a sumar 680. ¿Por qué está garantizado eso para `sum`, y seguiría valiendo para `avg` o `max`?
- **Q6.** En el paso 3, series con el mismo par `(region, code)` se combinaron aunque difieren en `app` y `method`. Describí la regla de agrupación en una oración: ¿qué series terminan en el mismo grupo?

---

## Ejercicio 3 — `without`: el complemento (y por qué sobrevive a nuevas etiquetas)

`without (<labels>)` dice *descartá exactamente estas etiquetas, mantené todo el resto* (el nombre de métrica `__name__` igual se elimina). Es el inverso de `by`.

**Pasos**

1. Colapsá solo `method` y `code`, manteniendo intacto el resto de la identidad:
   ```
   sum without (method, code) (demo_http_requests_total)
   ```
   Esperado:
   ```
   {region="us-east",app="checkout",job="demo_api"}   145
   {region="us-east",app="cart",job="demo_api"}       220
   {region="eu-west",app="checkout",job="demo_api"}    90
   {region="eu-west",app="cart",job="demo_api"}       225
   ```

2. Escribí la consulta `by` que produce los **mismos números** pero un **conjunto de etiquetas distinto**:
   ```
   sum by (region, app) (demo_http_requests_total)
   ```
   Esperado:
   ```
   {region="us-east",app="checkout"}   145
   {region="us-east",app="cart"}       220
   {region="eu-west",app="checkout"}    90
   {region="eu-west",app="cart"}       225
   ```

3. Notá la diferencia: el resultado de `without` todavía lleva `job="demo_api"`; el resultado de `by` descartó `job`.

**Punto de control**

- **Q7.** Un compañero después agrega una nueva etiqueta `canary="true"` a algunas series y las vuelve a enviar. El dashboard usa `sum by (region, app) (...)`. ¿Aparece la nueva etiqueta `canary` en la salida? ¿Qué pasaría en cambio si la consulta usara `sum without (method, code) (...)`? ¿Cuál de las dos es más robusta ante *nuevas* dimensiones que aparecen, y cuál es más robusta ante dimensiones *no deseadas* que se filtran?
- **Q8.** Reescribí `sum by (region) (demo_http_requests_total)` como una cláusula `without` que produzca el conjunto de etiquetas idéntico `{region="…"}`. (Pista: tenés que nombrar cada etiqueta que *no* sea `region`, y va a mantener `job` a menos que lo listes.)

---

## Ejercicio 4 — Elegir el operador: `sum` / `avg` / `min` / `max` / `count` / `group`

La agrupación es ortogonal al *reductor*. El mismo `by (region)`, seis preguntas diferentes.

**Pasos**

1. Ejecutá cada uno y leé la semántica en los números:
   ```
   sum   by (region) (demo_http_requests_total)
   avg   by (region) (demo_http_requests_total)
   min   by (region) (demo_http_requests_total)
   max   by (region) (demo_http_requests_total)
   count by (region) (demo_http_requests_total)
   group by (region) (demo_http_requests_total)
   ```
   Esperado:
   ```
   sum     {region="us-east"} 365     {region="eu-west"} 315
   avg     {region="us-east"} 73      {region="eu-west"} 63
   min     {region="us-east"} 5       {region="eu-west"} 10
   max     {region="us-east"} 200     {region="eu-west"} 150
   count   {region="us-east"} 5       {region="eu-west"} 5
   group   {region="us-east"} 1       {region="eu-west"} 1
   ```

2. Contá los apps *distintos* en todo el dataset usando `group` como deduplicador:
   ```
   count(group by (app) (demo_http_requests_total))
   ```
   Esperado:
   ```
   {}   2
   ```

**Punto de control**

- **Q9.** `avg by (region)` devolvió 73 y 63. Confirmá 73 a mano a partir de las series de us-east, y enunciá exactamente por qué divide `avg`.
- **Q10.** `count` devolvió 5 por región, pero los *valores* de esas series van de 5 a 200. ¿Qué cuenta `count` — muestras, series, o la suma de los valores?
- **Q11.** `group` devolvió 1 para cada grupo sin importar los valores subyacentes. Dá una consulta de producción donde ese comportamiento "siempre 1" sea exactamente lo que querés.

---

## Ejercicio 5 — Agregadores parametrizados: `topk` / `bottomk` (y su trampa en consultas de rango)

`topk` y `bottomk` toman un **parámetro** numérico `k` antes del vector. A diferencia de `sum`/`avg`, **no colapsan** las series en un valor calculado — *seleccionan* las k series de entrada y las devuelven **con sus etiquetas originales y su nombre de métrica intactos**.

**Pasos**

1. Las tres series más ocupadas en total:
   ```
   topk(3, demo_http_requests_total)
   ```
   Esperado (fijate que las etiquetas completas *y* el nombre de métrica sobreviven):
   ```
   demo_http_requests_total{region="us-east",app="cart",code="200",method="GET"}       200
   demo_http_requests_total{region="eu-west",app="cart",code="200",method="GET"}       150
   demo_http_requests_total{region="us-east",app="checkout",code="200",method="GET"}   100
   ```

2. La serie individual más tranquila:
   ```
   bottomk(1, demo_http_requests_total)
   ```
   Esperado:
   ```
   demo_http_requests_total{region="us-east",app="checkout",code="500",method="GET"}   5
   ```

3. Combiná `topk` con una cláusula de agrupación para obtener el **top-1 por región**:
   ```
   topk(1, demo_http_requests_total) by (region)
   ```
   Esperado:
   ```
   demo_http_requests_total{region="us-east",app="cart",code="200",method="GET"}   200
   demo_http_requests_total{region="eu-west",app="cart",code="200",method="GET"}   150
   ```

4. `topk` sobre una pre-agregación — "los 2 pares (region, app) con más tráfico":
   ```
   topk(2, sum by (region, app) (demo_http_requests_total))
   ```
   Esperado:
   ```
   {region="eu-west",app="cart"}    225
   {region="us-east",app="cart"}    220
   ```

**Punto de control**

- **Q12.** En el paso 1, `topk` mantuvo `__name__` y todas las etiquetas, mientras que `sum` en el Ejercicio 1 las descartó. ¿Por qué ese es el comportamiento *correcto* específicamente para `topk`?
- **Q13.** Graficás `topk(3, rate(demo_http_requests_total[5m]))` sobre las últimas 6 horas y obtenés un desastre irregular donde las series aparecen y desaparecen. Explicá, en términos de *evaluación por instante*, por qué `topk` es peligroso en una consulta de **rango** y está bien en una consulta **instantánea**. ¿Cuál es la solución de producción habitual (pensá en paneles de alertas/tablas vs. paneles de series temporales)?

---

## Ejercicio 6 — `count_values`: convertir valores de muestra en una distribución

`count_values("<newlabel>", <vector>)` agrupa las series **por su valor de muestra**, y reporta cuántas series comparten cada valor — escribiendo ese valor en una etiqueta completamente nueva.

**Pasos**

1. ¿Cuántos nodos tienen cada conteo de pods listos?
   ```
   count_values("ready_pods", demo_pods_ready)
   ```
   Esperado:
   ```
   {ready_pods="3"}   3
   {ready_pods="5"}   2
   ```

2. Contrastá con `count`, que ignora los valores por completo:
   ```
   count(demo_pods_ready)
   ```
   Esperado:
   ```
   {}   5
   ```

**Punto de control**

- **Q14.** En el paso 1, la etiqueta original `node` desapareció y apareció una nueva etiqueta `ready_pods`. ¿Qué determina el *número de series de salida* de `count_values`?
- **Q15.** Nombrá un uso del mundo real: tenés `kube_pod_info` o una métrica estilo `build_info`. Esbozá una consulta `count_values(...)` que responda "¿cuántos targets están corriendo cada versión de la aplicación?" — y enunciá el único requisito que el **valor de muestra** de la métrica debe cumplir para que `count_values` sea la herramienta correcta.

---

## Ejercicio 7 — `quantile` / `stddev` / `stdvar` sobre la dimensión de series

Estos reducen un grupo de series a un estadístico de sus **valores de muestra actuales** — *a través de las series*, en un instante. (No confundas `quantile()` la agregación con `histogram_quantile()`, que reconstruye un cuantil a partir de series de buckets — un Tema diferente.)

**Pasos**

1. Mediana del conteo de requests a través de las diez series:
   ```
   quantile(0.5, demo_http_requests_total)
   ```
   Esperado:
   ```
   {}   50
   ```

2. Percentil 90 a través de todas las series:
   ```
   quantile(0.9, demo_http_requests_total)
   ```
   Esperado:
   ```
   {}   155
   ```

3. Dispersión del tráfico dentro de cada región:
   ```
   stddev by (region) (demo_http_requests_total)
   stdvar by (region) (demo_http_requests_total)
   ```
   Esperado (redondeado):
   ```
   stddev  {region="us-east"} 71.25    {region="eu-west"} 50.95
   stdvar  {region="us-east"} 5076     {region="eu-west"} 2596
   ```

**Punto de control**

- **Q16.** Prometheus calcula `quantile(0.5, …)` ordenando los valores del grupo e interpolando linealmente en el rango `φ·(n−1)`. Con los diez valores ordenados `5,10,15,20,40,60,80,100,150,200`, mostrá la aritmética que da **50** para φ=0.5.
- **Q17.** `stdvar by (region)` para us-east es 5076 = `stddev²` (71.25² ≈ 5076). ¿Prometheus divide las desviaciones al cuadrado por `n` o por `n−1`? Enunciá cuál (población vs. muestra) y por qué eso importa cuando comparás contra un valor que alguien calculó en una planilla de cálculo.

---

## Ejercicio 8 — Dimensión de series vs. dimensión de tiempo (la confusión clásica)

Los *operadores* de agregación necesitan un **vector instantáneo**. Si le pasás un **vector de rango**, obtenés un error de parseo — y la solución es una *función* de la dimensión de tiempo, no un operador.

**Pasos**

1. Provocá el error deliberadamente:
   ```
   sum(demo_http_requests_total[5m])
   ```
   Esperado:
   ```
   Error executing query: expected type instant vector in aggregation expression, got range vector
   ```

2. Colapsá la dimensión de **tiempo** de una serie con una función `_over_time` (valor máximo visto por serie en 5 minutos):
   ```
   max_over_time(demo_http_requests_total[5m])
   ```
   Esperado: diez series devueltas, cada una manteniendo su conjunto de etiquetas completo, valor = su muestra máxima en la ventana (acá igual al valor constante enviado, ej. `200`, `150`, …).

3. Colapsá **ambas** dimensiones — máximo sobre el tiempo, después sumado a través de las series — anidando el operador *por fuera* de la función:
   ```
   sum(max_over_time(demo_http_requests_total[5m]))
   ```
   Esperado:
   ```
   {}   680
   ```

**Punto de control**

- **Q18.** ¿Por qué exactamente falló el paso 1 mientras que el paso 3 tuvo éxito? Hacé referencia al tipo de entrada que recibió cada `sum`.
- **Q19.** Un colega quiere "el CPU promedio de cada instancia en la última hora". Escribió `avg by (instance) (node_cpu_seconds_total[1h])`. Diagnosticá los dos problemas (desajuste de tipo *y* el `rate` faltante) y escribí una expresión corregida.

---

## Ejercicio 9 — Agregá el rate; nunca hagas rate del agregado

El error de agregación más evaluado con **counters**: el orden importa. Debés calcular `rate()` **por serie primero**, después agregar — porque `rate` necesita detectar reinicios de counter *dentro de cada serie individual*, y los reinicios independientes se pierden en el momento en que sumás counters crudos.

**Pasos**

1. Generá tráfico de counter real, *creciente*, contra las propias métricas de Prometheus (cada consulta incrementa `prometheus_http_requests_total`):
   ```bash
   for i in $(seq 1 60); do
     curl -s 'http://localhost:9090/api/v1/query?query=up' >/dev/null
     sleep 1
   done
   ```

2. **Correcto** — hacé rate de cada serie de handler, después sumá:
   ```
   sum(rate(prometheus_http_requests_total[1m]))
   ```
   Esperado: un rate por segundo pequeño y positivo (ej. `~3.2`), estable y significativo.

3. **Incorrecto** — sumá los counters crudos, después intentá hacer rate del agregado con una subconsulta:
   ```
   rate(sum(prometheus_http_requests_total)[1m:15s])
   ```
   Esperado: un número que *parece* plausible en un sistema sano pero se comporta mal silenciosamente en el instante en que cualquier serie subyacente se reinicia (reinicio / target rotado), porque el agregado ya no puede ver los reinicios individuales.

4. Mirá los rates por serie antes de que se sumen:
   ```
   topk(5, rate(prometheus_http_requests_total[1m]))
   ```
   Esperado: los cinco handlers más ocupados (ej. `/api/v1/query`) con sus rates individuales por segundo.

**Punto de control**

- **Q20.** Enunciá la regla como un orden memorizable: para counters, ¿cuál de `rate()` / `sum()` debe ser la función **interna** y cuál la **externa**? Dá la razón en términos de detección de reinicios de counter.
- **Q21.** ¿Aplica la misma regla de "rate interno" a `demo_pods_ready` (un gauge)? ¿Por qué sí o por qué no?

---

## Ejercicio 10 — Diagnóstico: "la mitad de mis etiquetas desaparecieron"

Un escenario de guardia realista que combina todo lo anterior.

**Pasos**

1. La consulta de panel de un ingeniero es:
   ```
   sum(rate(demo_http_requests_total[5m])) by (region)
   ```
   Se queja de que el panel está plano en cero. Primero, confirmá que el *rate* es genuinamente cero acá:
   ```
   sum by (region) (rate(demo_http_requests_total[5m]))
   ```
   Esperado:
   ```
   {region="us-east"}   0
   {region="eu-west"}   0
   ```

2. Ahora confirmá que los *conteos* no son cero:
   ```
   sum by (region) (demo_http_requests_total)
   ```
   Esperado: `365` / `315` como en el Ejercicio 2.

3. Explicá el panel plano y registrá la solución (los valores enviados son constantes → `rate` es 0). Después reproducí un bug genuino de pérdida de etiquetas:
   ```
   sum by (app) (demo_http_requests_total)   # keeps only app
   ```
   y notá que `region`, `method`, `code`, `job` desaparecieron todas — esperado, pero una sorpresa frecuente.

**Punto de control**

- **Q22.** Las dos consultas del paso 1 (`sum(...) by (region)` vs `sum by (region) (...)`) — ¿son equivalentes, o una de ellas está mal? Explicá dónde se le permite ubicarse a la cláusula `by`.
- **Q23.** Dá la receta de diagnóstico en dos pasos que usarías siempre que un panel agregado esté "vacío/plano": ¿qué revisás primero sobre el **tipo/orden** de la agregación, y segundo sobre **qué etiquetas** retiene la cláusula `by`/`without`?

---

## Desmontaje

```bash
docker compose down -v
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** Las dimensiones son las etiquetas de cada serie: `region`, `app`, `method`, `code`, más `job="demo_api"` (agregada por Pushgateway) y un `instance=""` vacío. El nombre de la métrica se guarda en la etiqueta reservada `__name__`, que también es técnicamente una dimensión pero es descartada por todo operador de agregación excepto `topk`/`bottomk`/`limitk`/`limit_ratio`.

**Q2.** El dataset es estático, así que un *Graph* de series temporales solo mostraría líneas horizontales planas y ocultaría los conjuntos de etiquetas. La agregación produce **nuevos conjuntos de etiquetas** cuyos valores necesitás leer con exactitud — la vista **Table** muestra una fila por serie de salida con sus etiquetas completas y el valor instantáneo, que es lo que verifican estos ejercicios.

**Q3.** Sin cláusula `by`/`without`, un operador de agregación colapsa **todas** las series del vector en una **única** serie de salida y elimina **todas** las etiquetas, incluida `__name__`. El resultado lleva un conjunto de etiquetas vacío `{}`.

**Q4.** No pueden colisionar cuando se ejecutan como dos expresiones separadas (resultados diferentes), pero *conceptualmente* ambas producen el mismo conjunto de etiquetas vacío `{}`. Si intentaras combinarlas en una sola expresión mediante un operador binario con matching por defecto, los resultados con etiquetas vacías harían match y las identidades de métrica (ya perdidas) no podrían distinguirlos — una razón concreta por la que la agregación descarta `__name__`: para hacer los resultados deliberadamente agnósticos del nombre, y una razón para mantener al menos una etiqueta distintiva con `by` cuando planeás combinar resultados.

**Q5.** `sum` distribuye sobre la partición: cada serie cae en exactamente un grupo, así que los subtotales de grupo siempre vuelven a sumar el total general (365+315 = 235+445 = … = 680). Esto **no** vale para `avg` (el promedio de promedios de grupo ≠ el promedio general a menos que los grupos sean del mismo tamaño) ni para `max` (el máximo de los máximos de grupo es igual al máximo global, pero los máximos de grupo no "suman" nada significativo).

**Q6.** Dos series se colocan en el mismo grupo **si y solo si** tienen valores idénticos para todas las etiquetas nombradas en la cláusula `by` (o, para `without`, valores idénticos para todas las etiquetas *excepto* las nombradas). En el paso 3, todo lo que tenga el mismo par `(region, code)` se fusiona, sin importar `app` o `method`.

**Q7.** Con `sum by (region, app)`, la nueva etiqueta `canary` es **plegada** — no aparece, y las series canary + no-canary se fusionan en un número. Con `sum without (method, code)`, la consulta mantiene *todas* las etiquetas excepto las dos nombradas, así que `canary` **sí** aparece y canary/no-canary se mantienen separadas. `by` es más robusta ante *dimensiones nuevas no deseadas que se filtran* (enumerás exactamente lo que querés); `without` es más robusta en el sentido de que *preserva automáticamente etiquetas de identidad genuinamente nuevas* (enumerás solo lo que descartar). Elegí `by` para cardinalidad estable de dashboard; elegí `without` cuando querés quitar una etiqueta ruidosa conocida y mantener todo lo demás.

**Q8.** `sum without (app, method, code, job, instance) (demo_http_requests_total)`. Tenés que nombrar cada etiqueta que no sea `region`, **incluyendo** `job` e `instance`, o el resultado las mantiene y ya no hace match con `{region="…"}`. Esto es exactamente por qué `by (region)` es la elección idiomática — es más corta e inmune a etiquetas no listadas.

**Q9.** Los valores de us-east son `100, 5, 40, 200, 20`; suma = 365; `avg` divide por el **número de series en el grupo** (5): 365 / 5 = 73. `avg` divide por el conteo de series, nunca por un conteo de tiempo.

**Q10.** `count` cuenta **series** (elementos del vector) en cada grupo — acá 5 por región — no muestras sobre el tiempo y no la suma de los valores.

**Q11.** Deduplicación / existencia y conteo de cardinalidad. Ejemplo: `count(group by (instance) (up))` → número de instancias distintas actualmente scrapeadas, sin importar si cada una está up (1) o down (0); o `count(group by (app) (demo_http_requests_total))` para "cuántos apps distintos existen". `group` normaliza cada grupo a 1 para que el `count` externo no se distorsione por los valores subyacentes.

**Q12.** `topk`/`bottomk` **seleccionan** series de entrada reales en vez de calcular un nuevo valor agregado; el objetivo mismo es responder "*cuáles* series", así que la identidad (nombre de métrica + todas las etiquetas) debe preservarse para ser útil. `sum` calcula un nuevo número que ya no pertenece a ninguna serie de entrada individual, así que descarta la identidad.

**Q13.** `topk` se evalúa **independientemente en cada timestamp**. En una consulta de rango/gráfico, la *membresía* del conjunto top-k puede cambiar de paso a paso, así que distintas series entran y salen, produciendo un gráfico irregular y parpadeante — y ninguna línea individual es una "serie top" continua. En una consulta instantánea (un panel de tabla o una regla de alerta), evaluás en un momento, que es exactamente lo que significa "top 3 ahora mismo". Solución de producción: usá `topk` en **paneles de tabla / alertas**, y para gráficos de series temporales o bien graficá *todas* las series y confiá en la leyenda, o pre-agregá a un conjunto de series acotado y estable — no grafiques `topk` sobre un rango.

**Q14.** El número de **valores de muestra distintos** presentes a través de las series de entrada determina el conteo de series de salida. Los valores `3` y `5` aparecen ⇒ dos series de salida. La nueva etiqueta de cada salida (`ready_pods`) guarda el valor, y el conteo del grupo es cuántas series de entrada lo tenían.

**Q15.** `count_values("version", app_build_info)` donde el **valor de muestra** de la métrica **codifica la versión** (ej. un id de build numérico). Resultado: una serie por versión distinta, valuada por cuántos targets la corren. El requisito duro: lo que estás contando debe vivir en el **valor de muestra**, no en una etiqueta — si la versión es una etiqueta, usarías `count by (version) (...)` en su lugar. (Muchas métricas `*_info` reales ponen la versión en una *etiqueta* y están siempre valuadas en `1`; para esas, `count by (version)` es lo correcto, no `count_values`.)

**Q16.** n = 10, φ = 0.5. rango = φ·(n−1) = 0.5·9 = 4.5. Índice inferior = ⌊4.5⌋ = 4 → valor `40`; índice superior = 5 → valor `60`; peso = 4.5 − 4 = 0.5. Resultado = 40·(1−0.5) + 60·0.5 = 20 + 30 = **50**. (Para φ=0.9: rango = 8.1, valores `150` y `200`, peso 0.1 → 150·0.9 + 200·0.1 = 135 + 20 = **155**.)

**Q17.** Prometheus divide por **n** (varianza/desviación estándar poblacional), no por n−1. us-east: las desviaciones respecto de la media 73 son `27, −68, −33, 127, −53`; los cuadrados suman 25 380; ÷ 5 = **5076** = `stdvar`; √5076 ≈ **71.25** = `stddev`. El `STDEV`/`VAR` de una planilla (muestral, ÷ n−1) leerá *más alto* con los mismos datos; usá `STDEVP`/`VARP` para coincidir con Prometheus.

**Q18.** `sum` requiere un **vector instantáneo**. En el paso 1 el selector `[5m]` produjo un **vector de rango**, así que `sum` erró por el tipo. En el paso 3, `max_over_time(...[5m])` consumió el vector de rango y *devolvió un vector instantáneo* (un valor por serie), que `sum` luego agregó legalmente. El operador nunca ve un vector de rango.

**Q19.** Dos bugs: (1) `[1h]` genera un vector de rango, entrada ilegal para `avg`; (2) `node_cpu_seconds_total` es un counter, así que necesitás `rate` primero, y promediar counters de segundos no tiene sentido de todos modos. Corregido: `avg by (instance) (rate(node_cpu_seconds_total[5m]))` — `rate` convierte el counter en un vector instantáneo por segundo, después `avg by (instance)` agrega a través de las series de CPU/mode de cada instancia. (Usá `[5m]` o una ventana que cubra varios scrapes; `1h` es inusual para `rate`.)

**Q20.** `rate()` es la función **interna**, la agregación (`sum`) es la **externa**: `sum(rate(counter[5m]))`. `rate` debe correr por serie individual para poder detectar los reinicios de counter de esa serie (reinicios); si `sum()` los counters crudos primero, los reinicios independientes en series diferentes se cancelan/ocultan, y el `rate` externo calcula basura (caídas o negativos espurios). Regla mnemotécnica: **rate primero, agregar segundo.**

**Q21.** No. `demo_pods_ready` es un **gauge** — puede subir o bajar libremente y no tiene noción de reinicio de counter — así que `rate()` es inapropiado para él por completo. Los gauges se agregan directamente (`sum`, `avg`, `max` …). La regla del rate interno existe específicamente porque los **counters** crecen monótonamente y se reinician a cero, algo que solo `rate`/`increase`/`irate` saben manejar.

**Q22.** Son **equivalentes**. PromQL acepta el modificador en cualquiera de las dos posiciones: `<aggr>(<expr>) by (<labels>)` y `<aggr> by (<labels>) (<expr>)` significan lo mismo. El panel plano no es un problema de sintaxis — es que los valores de counter enviados son *constantes*, así que `rate(...[5m])` es genuinamente `0`. Solución para una demo: enviá valores crecientes a lo largo del tiempo (o usá un counter vivo como el Ejercicio 9), no cambiar la ubicación de `by`.

**Q23.** (1) **Tipo/orden:** confirmá que agregaste un vector *instantáneo* y, para counters, que `rate()` está dentro de la agregación (`sum(rate(...))`, no `rate(sum(...))` ni `sum(counter[range])`). Un panel plano en cero es muy a menudo un problema de constante/orden de `rate`. (2) **Etiquetas:** verificá que la cláusula `by`/`without` realmente retiene una etiqueta que tu leyenda/join espera — un resultado vacío `{}` o "series faltantes" suele significar que la agrupación colapsó la etiqueta por la que estabas indexando, o que un join del otro lado tiene una etiqueta que tu lado agregado descartó (`__name__` y todas las etiquetas que no están en `by` desaparecieron).

</details>