# Ejercicios Guiados — 3.6 Fundamentos de SLOs, SLAs y SLIs

> **Certificación:** Prometheus Certified Associate (PCA) — Dominio 3, *Data & Visualization / Observability practices*
> **Prerrequisitos:** Un Prometheus funcionando (`v2.4x+`) con un target instrumentado que exponga `http_requests_total` (counter, labels `job`, `code`) y `http_request_duration_seconds_*` (histogram). Si no tenés un target en vivo, los números de ejemplo incrustados en cada paso te permiten completar todos los cálculos a mano y verificar la lógica de PromQL contra ellos.
>
> A lo largo del texto, mantené el vocabulario claro: un **SLI** es una *medición*, un **SLO** es un *objetivo* para esa medición, y un **SLA** es un *contrato* (con consecuencias) construido sobre uno o más SLOs. Prometheus es donde los SLIs viven como PromQL, donde los SLOs se convierten en recording rules, y donde el consumo del error budget se convierte en alertas.

---

## Ejercicio 1 — Separar SLI, SLO y SLA

**Objetivo:** Fijar las tres definiciones antes de tocar cualquier query, porque la mayoría de las trampas del examen dependen de confundirlas.

1. Leé esta declaración tomada de la documentación pública y el runbook interno de un servicio ficticio:

   > *"Medimos la fracción de peticiones HTTP exitosas. Nuestro objetivo interno es que al menos el 99,9% de las peticiones tengan éxito en cualquier ventana móvil de 30 días. Nuestro contrato de nivel pago promete a los clientes un 99,5% de disponibilidad mensual; por debajo de eso, reciben un crédito de servicio del 10%."*

2. Subrayá (en papel) exactamente una cláusula que sea el **SLI**, una que sea el **SLO** y una que sea el **SLA**.

3. Anotá los dos porcentajes *diferentes* (99,9% y 99,5%) y escribí, en una oración, por qué un servicio bien gestionado deliberadamente fija su SLO **más estricto** que su SLA.

4. Clasificá cada uno de los siguientes como SLI, SLO, SLA, o "ninguno de estos":
   - a. `sum(rate(http_requests_total{code!~"5.."}[5m])) / sum(rate(http_requests_total[5m]))`
   - b. "El 99,95% de las escrituras se completan en menos de 200 ms, medido mensualmente."
   - c. "Si el uptime mensual cae por debajo del 99,9%, el cliente puede rescindir el contrato sin penalización."
   - d. "La CPU está corriendo al 73%."

> **Comprobá tu comprensión — 1**
> 1. ¿Cuál de los tres (SLI/SLO/SLA) es el único que acarrea **consecuencias comerciales o legales** cuando se incumple?
> 2. ¿Por qué una métrica de recursos cruda como `node_cpu_seconds_total` es normalmente un *mal* SLI, aunque sea una métrica perfectamente buena?
> 3. Si un equipo tiene un SLA del 99,5% pero ningún SLO interno, ¿qué capacidad operativa les falta?

---

## Ejercicio 2 — Construir un SLI de disponibilidad en PromQL

**Objetivo:** Convertir "fracción de peticiones exitosas" en una query de SLI real, adimensional, y entender por qué cada término usa `rate()`.

1. Asumí que tu target expone un counter `http_requests_total{job="api", code}`. Durante los últimos 5 minutos las tasas por segundo son:

   | `code` | `rate(...[5m])` (req/s) |
   |--------|--------------------------|
   | `200`  | 480 |
   | `301`  | 12  |
   | `404`  | 6   |
   | `500`  | 3   |
   | `503`  | 1   |

2. Escribí el SLI como el cociente entre los **eventos buenos** (todo lo que *no* sea un error de servidor) y los **eventos válidos totales**:

   ```promql
   sum(rate(http_requests_total{job="api", code!~"5.."}[5m]))
   /
   sum(rate(http_requests_total{job="api"}[5m]))
   ```

3. Calculá el numerador, el denominador y el cociente a mano a partir de la tabla del paso 1.

4. Ahora invertilo en el **SLI de ratio de error** más útil (esta es la forma que vas a alimentar a las alertas más adelante):

   ```promql
   sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
   /
   sum(rate(http_requests_total{job="api"}[5m]))
   ```

5. Ejecutá ambas. Confirmá que `availability_ratio + error_ratio == 1` para este conjunto de datos, y explicá en una línea por qué esa identidad se cumple **solo porque** contaste los `4xx` como "buenos".

> **Comprobá tu comprensión — 2**
> 1. ¿Por qué debe envolverse cada término en `rate()` en lugar de usar los valores crudos del counter directamente?
> 2. Un colega escribe el denominador como `sum(rate(http_requests_total{job="api", code=~"2.."}[5m]))`. ¿Qué bug sutil introduce esto en el SLI?
> 3. ¿Debería un `404 Not Found` contar como *fallo* en tu SLI de disponibilidad? Dá el razonamiento que lo decide (pista: ¿de quién es la culpa de un 404?).
> 4. ¿Qué significa, físicamente, que este SLI sea *adimensional* — y por qué es una propiedad deseable para un SLI?

---

## Ejercicio 3 — Un SLI de latencia a partir de un histogram

**Objetivo:** Expresar "peticiones servidas suficientemente rápido" como un cociente *eventos buenos / eventos totales* directamente a partir de los buckets del histogram — **no** con un percentil — y entender por qué esa distinción importa para los SLOs.

1. Tu servicio expone `http_request_duration_seconds_bucket{job="api", le}`. El umbral del SLO es **300 ms**. Durante los últimos 5 minutos:

   - `sum(rate(http_request_duration_seconds_bucket{job="api", le="0.3"}[5m]))` = **491**
   - `sum(rate(http_request_duration_seconds_count{job="api"}[5m]))`           = **502**

2. Escribí el SLI de latencia — la fracción de peticiones que cayeron en un bucket igual o por debajo del umbral:

   ```promql
   sum(rate(http_request_duration_seconds_bucket{job="api", le="0.3"}[5m]))
   /
   sum(rate(http_request_duration_seconds_count{job="api"}[5m]))
   ```

3. Calculá el cociente a partir de los números del paso 1.

4. Contrastalo con el enfoque de percentil:

   ```promql
   histogram_quantile(0.99,
     sum by (le) (rate(http_request_duration_seconds_bucket{job="api"}[5m])))
   ```

   Ejecutalo (o razonalo). Fijate que esto devuelve una **duración en segundos**, no un cociente.

5. Explicá por qué la forma de *bucket-ratio* (paso 2) es la forma correcta para un SLI, mientras que la forma de *quantile* (paso 4) es más adecuada para un panel de dashboard que para una comparación de SLO.

> **Comprobá tu comprensión — 3**
> 1. El bucket `le="0.3"` debe existir en la configuración de tu histogram para que el paso 2 funcione. ¿Qué le pasa al SLI si los límites de bucket definidos más cercanos son `le="0.25"` y `le="0.5"`, y consultás `le="0.3"`?
> 2. ¿Por qué comparar una salida de `histogram_quantile()` contra un umbral de SLO es estadísticamente más débil que el enfoque de bucket-ratio? (Pensá en la interpolación dentro del bucket.)
> 3. Tu SLO dice "el 99% de las peticiones por debajo de 300 ms". ¿Qué query — paso 2 o paso 4 — comparás contra `0.99`, y cuál contra `0.3`?

---

## Ejercicio 4 — Del SLO al error budget

**Objetivo:** Convertir un porcentaje de SLO en un error budget concreto expresado *tanto* como un cociente *como* en minutos de reloj, y ver cuánta falta de fiabilidad compra realmente el presupuesto.

1. Tomá el SLO: **99,9% de disponibilidad sobre una ventana móvil de 30 días.**

2. Calculá el **error budget como cociente**: `error_budget = 1 − SLO`.

3. Convertí 30 días a minutos, luego calculá el **downtime permitido** = `error_budget_ratio × window_minutes`.

4. Repetí el cálculo completo para tres objetivos de SLO vecinos y completá esta tabla:

   | SLO | Error budget (ratio) | Tiempo malo permitido / 30 días |
   |------|----------------------|-----------------------------|
   | 99%    | ? | ? |
   | 99.9%  | ? | ? |
   | 99.95% | ? | ? |
   | 99.99% | ? | ? |

5. En términos de Prometheus, expresá la *fracción de presupuesto ya consumido* sobre la ventana como una query, dado un SLI de ratio de error de 30 días precalculado llamado `job:slo_errors_per_request:ratio_rate30d`:

   ```promql
   job:slo_errors_per_request:ratio_rate30d{job="api"} / 0.001
   ```

   Un valor de `1.0` significa que el presupuesto está exactamente agotado; `0.5` significa medio gastado; `> 1.0` significa que el SLO ya está incumplido para la ventana.

> **Comprobá tu comprensión — 4**
> 1. Pasar de 99,9% a 99,99% multiplica el downtime permitido ¿por qué factor, y aproximadamente cuántos minutos/mes compra cada uno?
> 2. ¿Por qué un error budget se describe como algo que da a un equipo *permiso para fallar* en lugar de un objetivo a minimizar?
> 3. Si un servicio ha consumido el **0%** de su error budget tres semanas dentro de la ventana, ¿qué sugiere la filosofía SRE que ese equipo está haciendo *mal*?
> 4. Dos equipos tienen ambos un SLO del 99,9%, pero uno mide sobre una ventana *móvil* de 30 días y el otro sobre el *mes calendario*. ¿Cuál puede "resetear" un mal día simplemente esperando al día 1, y por qué eso cambia el comportamiento de las alertas?

---

## Ejercicio 5 — Precalcular el SLI con recording rules

**Objetivo:** Sacar la matemática del SLI de los dashboards ad-hoc y meterla en recording rules nombradas y versionadas, para que alertas y paneles lean todos el *mismo* número.

1. Creá un archivo de reglas `slo-api.rules.yml` con dos SLIs de ratio de error en distintas ventanas (corta y larga — vas a necesitar ambas en el Ejercicio 6):

   ```yaml
   groups:
     - name: slo-api-error-ratio
       rules:
         - record: job:slo_errors_per_request:ratio_rate5m
           expr: |
             sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
             /
             sum(rate(http_requests_total{job="api"}[5m]))
         - record: job:slo_errors_per_request:ratio_rate1h
           expr: |
             sum(rate(http_requests_total{job="api", code=~"5.."}[1h]))
             /
             sum(rate(http_requests_total{job="api"}[1h]))
   ```

2. Referencialo desde `prometheus.yml`:

   ```yaml
   rule_files:
     - "slo-api.rules.yml"
   ```

3. Validá el archivo de reglas **antes** de recargar — nunca recargues a ciegas:

   ```console
   $ promtool check rules slo-api.rules.yml
   Checking slo-api.rules.yml
   SUCCESS: 2 rules found
   ```

4. Recargá Prometheus y confirmá que las nuevas series existen:

   ```console
   $ curl -s -X POST http://localhost:9090/-/reload
   $ curl -s 'http://localhost:9090/api/v1/query?query=job:slo_errors_per_request:ratio_rate5m'
   ```

5. Inspeccioná la convención de nombres `job:slo_errors_per_request:ratio_rate5m`. Dividila en sus tres partes separadas por dos puntos y decí qué comunica cada parte.

> **Comprobá tu comprensión — 5**
> 1. ¿Qué codifica la convención de nombres de recording rules `level:metric:operations`, y qué parte te dice el *nivel* de agregación de la serie?
> 2. Dá dos razones concretas para precalcular un SLI como una recording rule en lugar de pegar la expresión cruda en cada alerta y dashboard.
> 3. `promtool check rules` pasó, pero después de recargar la nueva serie devuelve *sin datos*. Nombrá dos causas no sintácticas (la regla es válida, pero el valor está vacío).
> 4. ¿Por qué habilitar `--web.enable-lifecycle` (necesario para el endpoint `/-/reload`) es una decisión que deberías tomar deliberadamente en lugar de por defecto?

---

## Ejercicio 6 — Burn rate del error budget y alertas multi-ventana

**Objetivo:** Construir la alerta que pagina *solo* cuando el presupuesto se está gastando peligrosamente rápido, usando la técnica multi-ventana y multi-burn-rate del Google SRE Workbook.

1. Definí **burn rate**: es cuántas veces más rápido que "sostenible" estás consumiendo el error budget. Un burn rate de **1** agota todo el presupuesto de 30 días exactamente al final de la ventana; un burn rate de **2** lo agota en 15 días; **14.4** lo agota en ~50 horas.

2. Derivá el umbral de burn rate para una paginación. El primer nivel del SRE Workbook dice: *paginá si el 2% del presupuesto de 30 días se consumiría en 1 hora.* Calculalo:

   ```
   burn_rate = (budget_fraction) / (alert_window / SLO_window)
             = 0.02 / (1h / 720h)
   ```

3. Confirmá la tabla estándar de multi-burn-rate completando los burn rates faltantes (ventana del SLO = 30 d = 720 h):

   | Severidad | Ventana larga | Ventana corta | Presupuesto consumido | Burn rate |
   |----------|-------------|--------------|-----------------|-----------|
   | Page     | 1h  | 5m  | 2%  | ? |
   | Page     | 6h  | 30m | 5%  | ? |
   | Ticket   | 3d  | 6h  | 10% | ? |

4. Escribí la alerta **page**. Se dispara solo cuando **tanto** la ventana larga *como* la corta superan el umbral `burn_rate × error_budget_ratio` (con error budget = `1 − 0.999 = 0.001`). La ventana corta es la guarda rápida de "¿sigue pasando?" que hace que la alerta se resetee rápidamente una vez que el incidente termina:

   ```yaml
   groups:
     - name: slo-api-burnrate
       rules:
         - alert: ApiHighErrorBudgetBurn
           expr: |
             (
               job:slo_errors_per_request:ratio_rate1h{job="api"} > (14.4 * 0.001)
               and
               job:slo_errors_per_request:ratio_rate5m{job="api"} > (14.4 * 0.001)
             )
           for: 2m
           labels:
             severity: page
           annotations:
             summary: "API burning 30-day error budget 14.4x too fast"
             description: "1h and 5m error ratios both exceed the 2%-in-1h burn threshold."
   ```

5. Razoná sobre el diseño de dos ventanas: dada una breve interrupción total de 3 minutos, explicá por qué la **ventana larga sola** mantendría la alerta disparándose durante una hora después, y cómo agregar la cláusula `and` de **ventana corta** lo soluciona.

6. Validá y (opcionalmente) cargá:

   ```console
   $ promtool check rules slo-api.rules.yml
   Checking slo-api.rules.yml
   SUCCESS: 3 rules found
   ```

> **Comprobá tu comprensión — 6**
> 1. ¿Por qué el esquema multi-burn-rate usa *tanto* una ventana larga como una corta unidas por `and`, en lugar de una única ventana larga? Nombrá el modo de fallo específico que previene cada ventana.
> 2. Una única ventana de 1 hora con burn rate 14.4 tardaría ~55 minutos en notar una interrupción total. ¿Qué propiedad de la ventana *corta* acorta tanto el tiempo de detección *como* el de reseteo?
> 3. La alerta de nivel ticket tiene burn rate **1**. ¿Por qué eso intencionalmente *no* es una paginación — qué te está diciendo sobre el ritmo de consumo del presupuesto?
> 4. Si bajás el SLO de 99,9% a 99,5%, ¿el umbral numérico `14.4 × error_budget` sube o baja, y la alerta se vuelve más o menos sensible a una tasa de error real fija?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
**Paso 2 (clasificación de las cláusulas):**
- **SLI** — *"la fracción de peticiones HTTP exitosas"* — la medición en sí.
- **SLO** — *"al menos el 99,9% de las peticiones tengan éxito en cualquier ventana móvil de 30 días"* — el objetivo interno para esa medición.
- **SLA** — *"contrato promete a los clientes un 99,5% de disponibilidad mensual; por debajo de eso, reciben un crédito de servicio del 10%"* — el contrato externo *con una consecuencia* (el crédito).

**Paso 3:** El SLO se fija más estricto que el SLA para que el equipo obtenga un **buffer de alerta temprana**: pueden incumplir su propio objetivo interno y aún tener margen para reaccionar antes de incumplir el contrato con el cliente que cuesta dinero. La brecha entre 99,9% y 99,5% es un margen operativo deliberado.

**Paso 4:**
- a. **SLI** — un cociente de PromQL; es una medición.
- b. **SLO** — un objetivo con un umbral y una ventana, sin consecuencia contractual declarada.
- c. **SLA** — una cláusula de contrato externo con una consecuencia (derecho a rescindir).
- d. **Ninguno de estos** — una simple lectura de utilización de recursos; es solo una métrica, sin objetivo ni contrato.

**Comprobación 1:**
1. El **SLA** — es el único que acarrea consecuencias comerciales/legales (créditos, penalizaciones, derechos de rescisión).
2. `node_cpu_seconds_total` mide una *causa*, no la *experiencia visible para el usuario*. Los buenos SLIs miden lo que el usuario siente (éxito, latencia, frescura); la CPU puede estar al 90% con usuarios perfectamente contentos, o al 20% mientras el servicio está caído. Una métrica de recursos no mapea monótonamente a la satisfacción del usuario.
3. Pueden medir si *cumplieron* el contrato después del hecho, pero **no tienen margen de alerta temprana ni error budget** para guiar las decisiones del día a día — ninguna forma de saber que se dirigen a un incumplimiento *antes* de que ocurra.

### Ejercicio 2
**Paso 3:**
- Numerador (`code!~"5.."`): 480 + 12 + 6 = **498 req/s**.
- Denominador (todo): 480 + 12 + 6 + 3 + 1 = **502 req/s**.
- SLI de disponibilidad = 498 / 502 = **0,99203… ≈ 99,20%**.

**Paso 4:** Ratio de error = (3 + 1) / 502 = 4 / 502 = **0,00797… ≈ 0,80%**.

**Paso 5:** 0,99203 + 0,00797 = **1,0**. La identidad se cumple *porque* el conjunto "bueno" se define como el complemento exacto del conjunto "malo" (`code!~"5.."` vs `code=~"5.."`) sobre el *mismo* denominador; cada petición se cuenta como exactamente uno de bueno o malo, y los `4xx` se colocaron en el lado "bueno", así que los dos cocientes particionan el todo.

**Comprobación 2:**
1. Los counters solo aumentan y se resetean a 0 al reiniciar. Los valores crudos no tienen sentido como tasa y se corromperían al reiniciar; `rate()` calcula el incremento por segundo sobre la ventana y es consciente de reinicios, dando un throughput estable que podés dividir.
2. Usar `code=~"2.."` en el denominador hace que el denominador sea *más pequeño que el total real* (descarta 3xx, 4xx, 5xx). El SLI entonces mide "2xx entre 2xx", que puede exceder la realidad u ocultar fallos — el denominador debe ser **todos los eventos válidos**, no solo los exitosos.
3. Depende de la titularidad. Un `404` es normalmente el **cliente** pidiendo algo que no existe — no un fallo de *tu* servicio — así que típicamente cuenta como "bueno" (una respuesta correctamente servida). Solo lo contarías como malo si un bug en tu servicio está devolviendo 404 para recursos que deberían existir.
4. Adimensional significa que es un cociente puro en `[0,1]` con las unidades cancelándose (req/s ÷ req/s). Eso es deseable porque es directamente comparable a un porcentaje de SLO, es independiente del volumen de tráfico (un período de bajo tráfico a las 3 AM y un pico del mediodía se miden en la misma escala), y se compone limpiamente en la matemática del error budget.

### Ejercicio 3
**Paso 3:** SLI de latencia = 491 / 502 = **0,97809… ≈ 97,81%** de las peticiones servidas en 300 ms o menos.

**Paso 5:** La forma de bucket-ratio produce una *fracción de eventos buenos* — exactamente la forma de SLI que comparás con un SLO como `0.99`. `histogram_quantile()` produce un *valor de latencia en segundos* (p. ej. "p99 = 0.42 s"), que responde "¿qué tan lenta es la cola?" — genial para un dashboard, pero es una duración, no un cociente, así que no es lo natural para comparar contra un objetivo de "99% de las peticiones".

**Comprobación 3:**
1. `le` coincide con un *límite existente exacto*. Si solo existen `0.25` y `0.5`, `le="0.3"` no coincide con **ninguna serie** y la query devuelve vacío — el SLI se rompe silenciosamente. Debés definir un límite de bucket *en* tu umbral de SLO (aquí, agregar `le="0.3"`).
2. `histogram_quantile()` **interpola linealmente dentro del bucket** en el que cae el cuantil, asumiendo una distribución uniforme allí. Esa estimación puede errar por todo el ancho del bucket, especialmente con buckets anchos o datos sesgados. La forma de bucket-ratio usa solo el conteo acumulativo *exacto* en un límite real — sin interpolación, sin supuesto distribucional.
3. Comparás la query del **paso 2** contra `0.99` (fracción de peticiones buenas ≥ 99%). Comparás la query del **paso 4** contra `0.3` (¿es la latencia p99 ≤ 300 ms?) — una formulación válida pero distinta, basada en interpolación.

### Ejercicio 4
**Pasos 2–4:**

| SLO | Error budget (ratio) | Tiempo malo permitido / 30 días (43 200 min) |
|------|----------------------|------------------------------------------|
| 99%    | 0.01    | 432 min ≈ **7,2 h** |
| 99.9%  | 0.001   | 43,2 min |
| 99.95% | 0.0005  | 21,6 min |
| 99.99% | 0.0001  | 4,32 min |

(30 días = 30 × 24 × 60 = 43 200 min; downtime permitido = `error_budget_ratio × 43 200`.)

**Comprobación 4:**
1. Cada "nueve" extra recorta el downtime permitido en **10×** (99,9% → 99,99% pasa de 43,2 min a 4,32 min por 30 días, un factor de 10). Presupuestos mensuales aproximados: 99% ≈ 7,2 h, 99,9% ≈ 43 min, 99,99% ≈ 4,3 min.
2. Porque una fiabilidad del 100% no es ni alcanzable ni vale su costo, el presupuesto es la *cantidad aceptable de falta de fiabilidad*. Gastarlo — en releases más rápidos, experimentos arriesgados, mantenimiento planificado — es legítimo. Es un permiso, no una deuda que llevar a cero.
3. Están siendo **demasiado conservadores** — acumular el presupuesto significa que probablemente están desplegando demasiado lento o sobre-invirtiendo en fiabilidad que los usuarios no necesitan. El presupuesto sin gastar es una señal para tomar más riesgo (desplegar más rápido, correr experimentos), no una medalla de honor.
4. El equipo del **mes calendario** resetea el día 1: un mal día temprano en el mes puede "envejecerse" simplemente con el calendario dando la vuelta. La ventana del equipo **móvil** siempre mira exactamente 30 días hacia atrás, así que un mal día sigue contando contra ellos durante 30 días completos. Esto cambia las alertas: las ventanas móviles dan un seguimiento del presupuesto más suave y honesto; las ventanas calendario crean un diente de sierra donde la tolerancia al riesgo es alta justo después del reseteo y se aprieta hacia fin de mes.

### Ejercicio 5
**Paso 5:** `job:slo_errors_per_request:ratio_rate5m` se divide como `level:metric:operations`:
- `job` — el **nivel de agregación** (esta serie está agregada al nivel `job`; los labels por instancia se sumaron y desaparecieron).
- `slo_errors_per_request` — la **métrica/significado** (ratio de error del SLO, errores por petición).
- `ratio_rate5m` — las **operaciones aplicadas** (un cociente de `rate()`s sobre una ventana de 5 minutos).

**Comprobación 5:**
1. Codifica `level:metric:operations`. El **primer segmento** (`job`) es el nivel de agregación — te dice qué labels sobreviven y cuáles fueron agregados, así nunca sumás accidentalmente una serie ya sumada.
2. (a) **Fuente única de verdad** — alertas, dashboards e informes leen todos el valor idéntico, así que no pueden discrepar. (b) **Costo/rendimiento** — un cociente de ventana larga costoso (p. ej. `[30d]`) se calcula una vez por intervalo de evaluación en lugar de en cada refresco de dashboard y cada evaluación de alerta.
3. Cualquiera de dos: la métrica subyacente `http_requests_total{job="api"}` no existe o el valor del label `job` no coincide (typo/desajuste de label); el target aún no se scrapeó / no hay datos en el rango; una división por cero donde la tasa del denominador es 0 (sin tráfico) no produce resultado; o no ha pasado suficiente tiempo para que la regla evalúe su primera muestra.
4. `--web.enable-lifecycle` expone `/-/reload` (y `/-/quit`) sobre HTTP. Cualquiera que pueda alcanzar ese endpoint puede recargar o apagar Prometheus, así que es una pequeña superficie de ataque que deberías habilitar solo detrás de controles de red/autorización adecuados — una decisión de seguridad deliberada, no un default.

### Ejercicio 6
**Paso 2:** `0.02 / (1 / 720) = 0.02 × 720 = **14.4**`.

**Paso 3:**

| Severidad | Ventana larga | Ventana corta | Presupuesto consumido | Burn rate |
|----------|-------------|--------------|-----------------|-----------|
| Page     | 1h  | 5m  | 2%  | **14.4** (`0.02 / (1/720)`) |
| Page     | 6h  | 30m | 5%  | **6** (`0.05 / (6/720)`) |
| Ticket   | 3d  | 6h  | 10% | **1** (`0.10 / (72/720)`) |

**Paso 5:** Con solo la **ventana larga de 1 hora**, una interrupción total de 3 minutos empuja el ratio de error de 1h por encima del umbral, y como `rate(...[1h])` promedia sobre 60 minutos, ese ratio se mantiene elevado durante aproximadamente la *hora completa* después de que la interrupción termina — así que la paginación sigue disparándose mucho después de que el incidente terminó. Agregar `and job:...:ratio_rate5m > threshold` requiere que la ventana de **5 minutos** *también* esté caliente; una vez que la interrupción para, el ratio de 5m colapsa en ~5 minutos y el `and` se vuelve falso, reseteando la alerta rápidamente. La ventana corta confirma "esto sigue pasando ahora mismo".

**Comprobación 6:**
1. La **ventana larga** provee la *significancia* del burn rate — asegura que estás gastando presupuesto a una tasa genuinamente peligrosa sobre un lapso significativo, filtrando pequeños destellos (evita paginaciones falsas). La **ventana corta** provee *recencia/reseteo* — confirma que el problema está en curso y deja que la alerta se limpie rápido una vez que termina (evita paginaciones falsas positivas persistentes tras la recuperación). Unidas por `and`, obtenés tanto bajos falsos positivos *como* baja latencia de reseteo.
2. La ventana corta tiene un lapso de promedio mucho menor, así que su ratio *sube y baja rápidamente*. Eso hace que la detección de una interrupción repentina y severa sea rápida (cruza el umbral en minutos) y hace que la alerta se resetee prontamente tras la recuperación — una ventana larga sola es lenta en ambos bordes.
3. Un burn rate de 1 significa que el presupuesto se está consumiendo exactamente al ritmo que lo agotaría justo al final de la ventana de 30 días — un drenaje *lento y sostenido*, no una emergencia. No necesita despertar a nadie; necesita un **ticket** para que un ingeniero investigue en horario laboral antes de que la tendencia se convierta en un incumplimiento.
4. Error budget = `1 − SLO`, así que bajar el SLO a 99,5% *aumenta* el presupuesto a `0.005`, y el umbral `14.4 × 0.005 = 0.072` **sube** (vs `0.0144` al 99,9%). Un umbral más alto significa que la alerta es **menos sensible** a una tasa de error real fija — el SLO más laxo tolera más errores antes de paginar.

</details>

---

### Sources

- CNCF — *Prometheus Certified Associate (PCA) Curriculum*, Domain 3: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- Google — *Site Reliability Engineering*, Ch. 3 "Embracing Risk" and Ch. 4 "Service Level Objectives": https://sre.google/sre-book/service-level-objectives/
- Google — *The Site Reliability Workbook*, Ch. 2 "Implementing SLOs" (multi-window, multi-burn-rate alerting): https://sre.google/workbook/alerting-on-slos/
- Prometheus — Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Querying functions (`rate`, `histogram_quantile`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Metric and label naming best practices: https://prometheus.io/docs/practices/naming/