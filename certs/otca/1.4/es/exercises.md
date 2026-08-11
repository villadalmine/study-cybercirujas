# 1.4 Análisis y Resultados — Ejercicios Guiados

> **Dominio:** Fundamentos de Observabilidad · **Peso en el examen:** 4.5%
>
> Este tema trata sobre la *última milla* del pipeline: una vez que se han recolectado traces, métricas y logs, **¿qué análisis realizás, y qué resultado operativo genera ese análisis?** Los resultados con los que un entrevistador/examen espera que conectes la telemetría son: **dashboards, alerting, SLIs/SLOs/error budgets, y análisis de causa raíz (RCA) mediante correlación de señales.** Los ejercicios de abajo toman un sistema de microservicios totalmente instrumentado, y luego te llevan desde señales crudas → análisis → resultado concreto.
>
> Syllabus de referencia: OTCA Curriculum, Domain 1 (`https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf`).

---

## Entorno de laboratorio (hacé esto una sola vez)

Usamos la **OpenTelemetry Demo** oficial (la "Astronomy Shop"): ~15 microservicios en varios lenguajes, todos emitiendo traces, métricas y logs a través de un único Collector, con Prometheus, Jaeger, Grafana y un load generator conectados. Es el laboratorio de OTel canónico y reproducible.

Fuente: `https://opentelemetry.io/docs/demo/`

```bash
# 1. Clone and start (needs Docker + ~6 GB RAM)
git clone https://github.com/open-telemetry/opentelemetry-demo.git
cd opentelemetry-demo
docker compose up -d --no-build

# 2. Confirm the stack is healthy
docker compose ps --format 'table {{.Name}}\t{{.State}}' | head -n 20
```

Esperado (abreviado) — cada fila `running`:

```
NAME                       STATE
otel-col                   running
prometheus                 running
jaeger                     running
grafana                    running
frontend-proxy             running
load-generator             running
...
```

Todo es accesible a través del front-end proxy en el puerto **8080**:

| UI | URL |
|---|---|
| Web store (genera tráfico) | `http://localhost:8080/` |
| Grafana (datasources Prometheus + Jaeger) | `http://localhost:8080/grafana/` |
| Jaeger UI | `http://localhost:8080/jaeger/ui/` |
| Load generator (Locust) | `http://localhost:8080/loadgen/` |

El load generator ya genera tráfico continuo, así que la telemetría está fluyendo. Dejá el stack corriendo durante los cinco ejercicios.

> **Nota sobre version-drift (una habilidad de producción real):** los nombres exactos de métricas y labels dependen de las versiones del SDK/Collector. Por eso cada ejercicio de abajo *descubre* primero los nombres con el **metrics browser** de Prometheus (Grafana → Explore) antes de consultarlos. Nunca hardcodees un nombre de métrica que no hayas confirmado que existe en *este* backend.

---

## Ejercicio 1 — Análisis RED de un servicio (Rate, Errors, Duration)

**Objetivo:** convertir la telemetría cruda de requests en los tres números que describen *cualquier* servicio orientado a requests, y entender de dónde vienen esos números en OpenTelemetry.

El Collector de la demo ejecuta el **connector `spanmetrics`**, que agrega spans en métricas RED (un counter `calls` y un histograma `duration`) *sin* que los servicios necesiten emitir esas métricas por sí mismos. Este es el mecanismo de "análisis" más importante de entender para el examen.
Referencia: `https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector`

**Pasos**

1. Abrí **Grafana → Explore** (`http://localhost:8080/grafana/`, menú izquierdo → *Explore*) y seleccioná el datasource **Prometheus**.

2. Descubrí los nombres de las métricas RED generadas a partir de spans. En el cuadro de query, hacé clic en el **metric dropdown** y escribí `calls`, luego `duration`. Deberías encontrar un counter y un histograma, por ejemplo `calls_total` y `duration_milliseconds_bucket` (los nombres pueden llevar un prefijo de namespace en tu versión — usá lo que muestre el browser).

3. Inspeccioná las dimensiones que adjuntó el connector. Ejecutá:
   ```promql
   count by (service_name, status_code, span_kind) (calls_total)
   ```
   Fijate en los valores de `status_code`: `STATUS_CODE_OK`, `STATUS_CODE_ERROR`, `STATUS_CODE_UNSET`.

4. **Rate** — requests/segundo que entran al servicio checkout:
   ```promql
   sum(rate(calls_total{service_name="checkout", span_kind="SPAN_KIND_SERVER"}[5m]))
   ```

5. **Errors** — el error ratio (fracción de requests que fallaron), la forma en que los SREs realmente expresan "errors":
   ```promql
   sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[5m]))
     /
   sum(rate(calls_total{service_name="checkout"}[5m]))
   ```

6. **Duration** — la latencia p95, leída del histograma:
   ```promql
   histogram_quantile(
     0.95,
     sum by (le) (rate(duration_milliseconds_bucket{service_name="checkout"}[5m]))
   )
   ```

7. Ahora abrí el **load generator** (`http://localhost:8080/loadgen/`), aumentá el user count, y volvé a ejecutar los pasos 4–6 después de ~2 minutos. Mirá cómo sube el rate y cómo se mueve la duration p95.

**Verificación de comprensión 1**

- **1a.** Ni el servicio checkout ni su SDK de lenguaje registran explícitamente una métrica `calls_total`. ¿De dónde viene, y cuál es la ventaja arquitectónica de derivarla ahí en lugar de instrumentar cada servicio?
- **1b.** En el paso 6, ¿por qué debe aparecer `by (le)` *dentro* del `sum(...)` antes de `histogram_quantile`, y qué respuesta incorrecta obtenés si calculás el quantile por serie y luego promediás?
- **1c.** El error ratio del paso 5 es un *ratio de rates*, no `rate(errors) / instant(total)`. ¿Por qué es correcto dividir dos `rate()` sobre la *misma* ventana, y qué se rompe si el numerador y el denominador usan ventanas de tiempo distintas?
- **1d.** RED (Rate, Errors, Duration) es uno de tres métodos clásicos. Nombrá los otros dos y la situación para la que cada uno está diseñado.

---

## Ejercicio 2 — Del SLI al SLO al error budget

**Objetivo:** convertir la señal RED de "errors" en un **Service Level Indicator (SLI)**, definir un **Service Level Objective (SLO)**, y calcular el **error budget** — el resultado que decide si lanzás features o congelás y arreglás la confiabilidad.

Referencia: Google SRE Workbook, *Implementing SLOs* — `https://sre.google/workbook/implementing-slos/`

**Pasos**

1. Definí un **SLI de disponibilidad** para checkout = *good requests / valid requests*. En Grafana Explore, sobre una ventana representativa de 30 días:
   ```promql
   1 -
   (
     sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[30m]))
       /
     sum(rate(calls_total{service_name="checkout"}[30m]))
   )
   ```
   (El laboratorio tiene solo minutos de historia; tratá esta ventana de 30 minutos como sustituto de la ventana real de cumplimiento de 30 días.)

2. Definí el **SLO**: disponibilidad ≥ **99.9%** sobre 30 días. Anotá el objetivo: `SLO = 0.999`.

3. Calculá el **error budget** a mano:
   - Budget como fracción de requests: `1 − SLO = 0.001` (0.1%).
   - Budget como tiempo sobre 30 días: `30 d × 24 h × 60 min × 0.001 = ` ______ minutos.

4. Calculá el **budget restante** como una query (fracción de la asignación del mes todavía sin gastar). Usando el error ratio observado `q` del paso 1:
   ```promql
   1 - (
     ( sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[30m]))
         / sum(rate(calls_total{service_name="checkout"}[30m])) )
     / 0.001
   )
   ```
   Un resultado de `0` significa que el budget está totalmente gastado; negativo significa que estás *por encima* del budget.

5. Empujá el sistema más allá de su SLO a propósito: en el load generator, subí el user count lo suficiente como para que los servicios downstream empiecen a devolver errores, esperá ~2 min, y volvé a ejecutar el paso 4. Mirá cómo cae el budget restante.

**Verificación de comprensión 2**

- **2a.** Completá el paso 3: ¿cuántos minutos de indisponibilidad por cada 30 días permite un SLO del 99.9%? ¿Y con 99.95% y 99%?
- **2b.** Un SLI, un SLO y un SLA son tres cosas distintas. Definí cada uno e indicá cuál tiene consecuencias *financieras o contractuales*.
- **2c.** Tu dashboard muestra que el SLO se está cumpliendo actualmente pero que el error budget del mes está consumido en un 95% con dos semanas por delante. ¿Cuál es el *resultado* — la decisión que este análisis debería impulsar — y por qué "todavía estamos cumpliendo el SLO" es el enfoque equivocado?
- **2d.** ¿Por qué generalmente se prefiere un SLI de *ratio* (good events / valid events) por sobre un umbral sobre el *count* crudo de errores?

---

## Ejercicio 3 — Correlación métrica → trace con exemplars

**Objetivo:** cerrar la brecha entre "un gráfico de latencia tuvo un pico" y "acá está el *request exacto* que fue lento." Los **exemplars** son la funcionalidad del data-model de OpenTelemetry que adjunta un `trace_id`/`span_id` muestreado a un bucket de histograma, permitiéndote saltar desde un agregado directamente a un trace representativo.

Referencias:
- Exemplars en el data model de métricas — `https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars`
- Almacenamiento de exemplars en Prometheus — `https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage`

**Pasos**

1. Confirmá que el Collector está emitiendo exemplars y que Prometheus los está almacenando. Localizá el archivo override del Collector de la demo y los flags de Prometheus:
   ```bash
   find . -name 'otelcol-config-extras.yml'
   docker compose exec prometheus sh -c 'ps -o args= 1' | tr ' ' '\n' | grep -i exemplar
   ```
   Deberías ver que Prometheus arranca con `--enable-feature=exemplar-storage`. Si el connector `spanmetrics` en tu versión no emite exemplars, habilitalo en `otelcol-config-extras.yml`:
   ```yaml
   connectors:
     spanmetrics:
       exemplars:
         enabled: true
   ```
   luego `docker compose restart otel-col`.

2. En **Grafana → datasource settings → Prometheus**, asegurate de que **Exemplars** esté activado para la métrica de histograma (Grafana enlaza los exemplars al datasource **Jaeger** vía el label `trace_id`).

3. En **Explore**, graficá de nuevo la p95 de checkout:
   ```promql
   histogram_quantile(0.95, sum by (le) (rate(duration_milliseconds_bucket{service_name="checkout"}[5m])))
   ```
   Los exemplars aparecen como **marcadores de diamante** dispersos en el gráfico.

4. Pasá el mouse sobre un marcador en un *pico* de latencia. El tooltip muestra el `trace_id` muestreado. Hacé clic en **"Query with Jaeger"** (o copiá el `trace_id`).

5. En Jaeger, abrí ese trace. Leé el waterfall de spans para encontrar *qué span downstream* consumió la latencia (por ejemplo `checkout → cart → valkey`, o una llamada lenta a `productcatalog`).

**Verificación de comprensión 3**

- **3a.** Un bucket de histograma es un agregado sobre miles de requests. ¿Qué única pieza de información agrega un exemplar que un simple bucket count nunca puede darte, y por qué ese es todo el sentido de los exemplars para el RCA?
- **3b.** Los exemplars son *muestreados*, no exhaustivos. ¿Por qué un trace representativo por bucket suele ser suficiente para el RCA de latencia, y cuándo el muestreo te induciría activamente al error?
- **3c.** El sampling basado en traces (por ejemplo tail sampling) puede descartar el trace al que apunta un exemplar. ¿Cuál es la consecuencia de "el exemplar referencia un trace que fue descartado por el sampling," y cómo evitás la referencia colgada?

---

## Ejercicio 4 — Correlación trace ↔ log para análisis de causa raíz

**Objetivo:** realizar un RCA end-to-end que use **las tres señales juntas**: una métrica te dice que *algo está mal*, un trace te dice *dónde*, y los logs te dicen *por qué*. El mecanismo es el **trace context** compartido (`trace_id`/`span_id`) que OpenTelemetry estampa en cada log record emitido dentro de un span activo.

Referencia: OpenTelemetry logs & correlation — `https://opentelemetry.io/docs/concepts/signals/logs/`

**Pasos**

1. Empezá desde un request con error. Consultá el *rate* de errores por servicio para encontrar el más ruidoso:
   ```promql
   topk(3,
     sum by (service_name) (rate(calls_total{status_code="STATUS_CODE_ERROR"}[5m]))
   )
   ```

2. En **Jaeger**, buscá ese servicio, filtrá **Tags: `error=true`**, y abrí un trace fallido. Anotá el `Trace ID` y el span específico con el marcador rojo de error.

3. Leé los `events` de ese span (Jaeger los muestra bajo *Logs* en el span). Una excepción registrada vía la API de OTel aparece como un span event llamado `exception` con atributos `exception.type`, `exception.message` y `exception.stacktrace`.

4. Pivotá hacia los **logs** del backend para el mismo request. En **Grafana → Explore**, cambiá al datasource de logs y filtrá por el trace id:
   ```logql
   {service_name="<the-service>"} | trace_id="<paste-trace-id>"
   ```
   (Si tu build de la demo enruta los logs al `debug`/stdout del Collector en lugar de a un log store, seguilos directamente:)
   ```bash
   docker compose logs otel-col | grep '<paste-trace-id>'
   ```

5. Leé las líneas de log correlacionadas. Confirmá que llevan el *mismo* `trace_id` y el `span_id` del span que falla, y que el mensaje explica la falla (por ejemplo una connection refused downstream, una falla inducida por un feature-flag, o un error de serialización).

6. Enunciá la causa raíz en una sola oración, citando la *señal que probó cada paso*: métrica → qué servicio, trace → qué span, log/event → por qué.

**Verificación de comprensión 4**

- **4a.** ¿Qué campo(s) exacto(s), e inyectado(s) por qué componente, hacen posible ejecutar el filtro LogQL del paso 4? Si una línea de log carece de ellos, ¿en qué capa se perdió el trace context?
- **4b.** Ordená las tres señales según la pregunta de RCA que responde cada una, y explicá por qué empezar el RCA desde los *logs* (grepeando) en lugar de desde una *métrica/SLO* es el anti-patrón clásico.
- **4c.** En el paso 3 el error surgió como un **span event** (`exception.*`), no como un log record. ¿Cuál es la diferencia práctica entre registrar una excepción como span event versus emitirla como un log correlacionado, y por qué podrías hacer ambos?

---

## Ejercicio 5 — Convertir el análisis en un resultado de alerting (burn-rate alerts)

**Objetivo:** producir el *resultado* operativo que más importa: una alerta que paginee a un humano en el momento justo. Una alerta ingenua de "error rate > 1%" es o demasiado ruidosa o demasiado lenta. El resultado estándar de SRE es una alerta **multi-window, multi-burn-rate** atada al error budget del SLO.

Referencia: Google SRE Workbook, *Alerting on SLOs* — `https://sre.google/workbook/alerting-on-slos/`

**Pasos**

1. Entendé el **burn rate** = qué tan rápido estás gastando el error budget en relación con lo "sostenible." Error ratio sostenible = `1 − SLO = 0.001`. Si tu error ratio observado sobre una ventana es `0.0144`, el burn rate = `0.0144 / 0.001 = 14.4×`.

2. Verificá la intuición del "2% en 1 hora" a mano: un burn de 14.4× sostenido durante 1 hora de un budget de 30 días (720 h) consume `14.4 × (1/720) = ` ______ de todo el budget del mes. Por esto 14.4 es el umbral canónico de *fast-burn* para paginar.

3. Escribí la expresión de la alerta **fast-burn** (dispara solo cuando *tanto* una ventana larga de 1h *como* una ventana corta de 5m superan el umbral — la ventana corta hace que deje de disparar rápidamente una vez que el incidente se resuelve):
   ```promql
   (
     sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[1h]))
       / sum(rate(calls_total{service_name="checkout"}[1h]))    > (14.4 * 0.001)
   )
   and
   (
     sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[5m]))
       / sum(rate(calls_total{service_name="checkout"}[5m]))    > (14.4 * 0.001)
   )
   ```

4. Testeala contra la realidad. Pegá la expresión en Grafana Explore mientras el load generator está en carga *normal* — no debería devolver **ninguna serie** (sin alerta). Luego provocá un pico en el load generator para forzar errores, esperá unos minutos, y volvé a ejecutar — debería devolver `1` (la alerta dispararía).

5. Bosquejá la tabla completa de alertas que desplegarías (no tenés que conectar las tres a Alertmanager; solo registrá los parámetros):

   | Severity | Long window | Short window | Burn rate | Budget consumed |
   |---|---|---|---|---|
   | Page | 1h | 5m | 14.4 | 2% |
   | Page | 6h | 30m | 6 | 5% |
   | Ticket | 3d | 6h | 1 | 10% |

**Verificación de comprensión 5**

- **5a.** Completá el paso 2. ¿Por qué combinar una ventana larga (detección) con una ventana corta (reset) supera a una alerta de una sola ventana?
- **5b.** Una alerta fast-burn (14.4×) y una slow-burn (1×) detectan formas de falla diferentes. Describí una caída que cada una captura y que la otra se pierde, y por qué la fast-burn paginea mientras que la slow-burn solo tiquetea.
- **5c.** ¿Por qué alertar sobre el **burn rate del error-budget** para empezar, en lugar de directamente sobre la latencia p95 o el count crudo de 5xx? Atá tu respuesta de vuelta al SLO del Ejercicio 2.
- **5d.** Toda esta cadena — métrica → SLI → SLO → error budget → burn-rate alert — es un único pipeline continuo de "análisis y resultados." Nombrá el artefacto de análisis producido en cada uno de los cinco ejercicios y el único resultado que la cadena entrega en última instancia.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1a.** Es generada por el **connector `spanmetrics`** que corre dentro del Collector: consume el stream de traces/spans y agrega los spans en un counter `calls` y un histograma `duration`, indexados por dimensiones como `service.name`, `span.kind`, `status.code`. Ventaja arquitectónica: las métricas RED se producen **de forma uniforme y central**, independientemente del lenguaje de cada servicio, de la madurez de su SDK, o de si sus autores se acordaron de agregar instrumentación de métricas. Instrumentás *tracing* una vez y obtenés *métricas* gratis, con naming consistente a lo largo de una flota poliglota — y podés cambiar las dimensiones en un solo lugar (el Collector) en lugar de re-desplegar cada servicio.

**1b.** `histogram_quantile` necesita el conjunto completo de series `le` (límites de bucket) *sumadas primero a través de todas las demás dimensiones de labels*, así que `sum by (le)(rate(...))` reconstruye un único histograma agregado, y el quantile se calcula a partir de eso. Si en cambio calculás un quantile por serie y luego los promediás, estás **promediando percentiles**, lo cual es matemáticamente carente de sentido — el promedio de los p95 no es el p95 de la población, y típicamente *subestima* la tail latency (un subconjunto pequeño muy lento queda diluido).

**1c.** `rate()` sobre una ventana ya produce un promedio por segundo sobre esa ventana; dividir dos rates calculados sobre la **misma** ventana da la fracción de requests en esa ventana que fueron errores — un ratio propio y consistente en el tiempo. Si el numerador y el denominador usan ventanas *distintas*, cubren poblaciones de requests distintas, así que el "ratio" ya no corresponde a ningún conjunto real de requests: durante una rampa de tráfico las ventanas desalineadas pueden incluso producir un ratio por encima de 1 o por debajo de 0.

**1d.** **USE** (Utilization, Saturation, Errors) — para **recursos** (CPU, memoria, disco, NICs, colas); responde "¿es este recurso un cuello de botella?" **Four Golden Signals** (Latency, Traffic, Errors, Saturation) — el superconjunto de Google para **sistemas orientados al usuario**, que agrega *saturation* (qué tan lleno está el servicio) por encima de RED. Regla práctica: RED/Golden Signals para **servicios/requests**, USE para **recursos**.

### Ejercicio 2

**2a.** 99.9% → `43200 × 0.001 = ` **43.2 minutos** / 30 días. 99.95% → 21.6 minutos. 99% → 432 minutos (7.2 horas). Cada "nueve" adicional recorta el budget en 10×.

**2b.**
- **SLI** — la *medición*: un indicador cuantificado de la salud del servicio (por ejemplo, ratio de requests exitosos = 99.94%).
- **SLO** — el *objetivo interno* que el SLI debe cumplir (por ejemplo, ≥ 99.9% sobre 30 días). Es la línea que impulsa las decisiones de ingeniería.
- **SLA** — el *contrato externo* con los clientes, usualmente *más laxo* que el SLO, que acarrea **consecuencias financieras/contractuales** (créditos, penalidades) cuando se incumple. Solo el SLA tiene peso legal/financiero; el SLO es deliberadamente más estricto para que reacciones antes de que el SLA esté en riesgo.

**2c.** El resultado es una **decisión de política de error-budget: frenar o congelar los lanzamientos de features y redirigir el esfuerzo hacia la confiabilidad**, porque quemar el 95% del budget con medio mes por delante significa que vas camino a *agotarlo* e incumplir el SLO antes de fin de mes. "Estamos cumpliendo el SLO ahora mismo" es el enfoque equivocado porque el SLO es una pregunta sobre la *tasa de consumo* a lo largo de toda la ventana, no un estado instantáneo — el budget es el indicador adelantado, el cumplimiento actual es uno rezagado.

**2d.** Un SLI de ratio (good/valid) está **normalizado al tráfico**, así que el objetivo significa lo mismo a 10 rps y a 10,000 rps y mapea directamente a un error budget. Un umbral sobre el *count* crudo de errores se rompe cada vez que cambia el tráfico: el mismo count es catastrófico con bajo volumen y despreciable con alto volumen, así que un umbral de count fijo es simultáneamente demasiado sensible fuera de pico y demasiado laxo en pico.

### Ejercicio 3

**3a.** Un exemplar agrega un **`trace_id` (y `span_id`) concreto de un request real que cayó en ese bucket** — es decir, un puntero desde el *agregado estadístico* hacia un *ejemplo individual e inspeccionable*. Un bucket count te dice "N requests fueron lentos"; el exemplar te deja abrir el trace del *request lento real* y ver exactamente adónde se fue el tiempo. Ese salto del agregado al espécimen es toda la razón por la que existen los exemplars.

**3b.** Para el RCA de *latencia* generalmente querés saber *cómo se ve un request lento*, y los requests lentos en el mismo bucket tienden a compartir el mismo cuello de botella, así que un espécimen es representativo. El muestreo induce al error cuando el bucket contiene **causas heterogéneas** — por ejemplo, una latencia p99 impulsada por dos problemas no relacionados (una DB lenta *y* una pausa de GC); un único exemplar muestra solo uno, y podés "arreglar" el equivocado mientras el otro sigue quemando budget.

**3c.** Obtenés una **referencia colgada**: el `trace_id` del exemplar resuelve a nada en el trace store, así que el click-through queda en un callejón sin salida. Evitalo alineando el sampling de forma que cualquier trace *referenciado por un exemplar sea retenido* — por ejemplo, exemplar-aware/tail sampling que conserva los traces con error y con alta latencia, o una configuración de `spanmetrics`/exemplar que solo emita exemplars para spans que el sampler va a conservar. El modo de falla es sutil porque el lado de la métrica se ve perfectamente sano.

### Ejercicio 4

**4a.** Los campos **`trace_id`** (y `span_id`) sobre el log record. Son poblados por el logging bridge/appender cuando lee el **span activo del context** en el momento del log (la instrumentación de logging de OTel / la inyección de log-context del SDK). Si una línea carece de ellos, el trace context se perdió donde el log fue *emitido* — típicamente logueando fuera del alcance del span activo, un límite de thread/async que no propagó el context, o un framework de logging no conectado al context bridge de OTel.

**4b.** Orden: **Métrica/SLO → *¿hay* un problema y vale la pena despertar a alguien; Trace → *dónde* en el path del request; Log/event → *por qué* falló.** Empezar desde los logs (grepeando) es un anti-patrón porque los logs son no estructurados, de alta cardinalidad, y no dan noción de *alcance o impacto al usuario* — podés pasar una hora leyendo logs de un problema que nunca incumplió un SLO, o perderte un problema generalizado porque grepeaste el servicio equivocado. Las métricas acotan primero el radio de impacto; solo bajás a los logs una vez que un trace te dijo *cuáles* logs leer.

**4c.** Un **span event** (`exception.*`) está adjunto *dentro del trace*, así que queda automáticamente acotado al span/operación exacto y viaja con la decisión de sampling del trace — ideal para "esta operación lanzó acá." Un **log correlacionado** es un registro de primera clase, consultable de forma independiente, que sobrevive incluso si el trace es descartado por el sampling y puede llevar contexto más rico/libre y ser agregado a través de requests. A menudo hacés **ambos**: el span event hace que el trace se explique solo en el waterfall; el log garantiza que la falla sea buscable y contable incluso sin el trace.

### Ejercicio 5

**5a.** `14.4 × (1/720) = 0.02` = **2% del budget mensual en una hora** — el umbral canónico de fast-burn. Combinar ventanas supera a una sola ventana porque la **ventana larga (1h) da confianza estadística** (pocos pageos falsos por un blip breve) mientras que la **ventana corta (5m) hace que la alerta se *resetee rápidamente*** una vez que el incidente terminó — una ventana larga sola mantendría la alerta disparando por hasta una hora después de la recuperación, demorando la señal de "resuelto."

**5b.** La **fast-burn (14.4×)** captura una caída *aguda y severa* — por ejemplo, un mal deploy que manda 5–10% de los requests a 5xx; agota el budget en ~2 días, así que **paginea** de inmediato. La **slow-burn (1×)** captura una fuga *crónica de bajo grado* — por ejemplo, un error rate estable del 0.1–0.15% que nunca dispara la fast-burn pero drena silenciosamente todo el budget del mes; solo **tiquetea** porque no hay urgencia en un goteo lento, pero ignorado, igual incumple el SLO. Cada una es invisible para la otra: las ventanas cortas de la alerta rápida nunca se disparan con el goteo lento, y la alerta lenta reacciona demasiado tarde para el pico agudo.

**5c.** Porque el SLO/error budget es lo que realmente mapea al **dolor del usuario y a la política de lanzamientos**, mientras que los umbrales crudos de latencia/5xx son proxies que pierden significado a medida que cambian el tráfico y la infraestructura. Alertar sobre el burn rate ata el pageo directamente a "¿estamos a punto de romper la promesa del Ejercicio 2," dando alertas que son *basadas en síntomas, normalizadas al tráfico, y auto-ajustadas al SLO* — cambiás el SLO en un solo lugar y todos los umbrales de las alertas lo siguen, en lugar de re-tunear números arbitrarios por servicio.

**5d.** Artefactos: **Ej 1 →** métricas RED (rate/errors/duration) a partir de spans; **Ej 2 →** un SLI, un SLO, y un error budget calculado; **Ej 3 →** evidencia métrica-a-trace enlazada por exemplars; **Ej 4 →** una cadena completa de causa raíz trace↔log; **Ej 5 →** reglas de alerta multi-window de burn-rate. El único **resultado** entregado: un servicio en funcionamiento cuya confiabilidad es *medida contra un objetivo explícito y defendida por alerting automatizado y consciente del budget que paginea a un humano exactamente cuando — y solo cuando — la confiabilidad orientada al usuario está genuinamente en riesgo.*

</details>