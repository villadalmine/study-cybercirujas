# PCA 1.5 — Operadores binarios

> Dominio: PromQL · Peso en el examen: 4
> Perfil: SRE / Arquitecto de Plataforma — profundidad de producción

---

## 1. Motivación: el problema arquitectónico que resuelven los operadores binarios

Una base de datos de series temporales que solo pudiera *seleccionar* y *agregar* te dejaría responder "¿cuántas solicitudes por segundo está sirviendo este handler?", pero nunca las preguntas que realmente guían un SLO:

- ¿Qué **fracción** de las solicitudes son errores? (una división de dos vectores independientes)
- ¿El uso de memoria está **por encima** de un umbral *en relación con el limit*, no un conteo absoluto de bytes? (un ratio + comparación)
- ¿Qué instancias están **up pero no reciben tráfico**? (una diferencia de conjuntos entre dos métricas con distinto `__name__`)
- ¿Cuál es el **margen** (headroom) entre la capacidad aprovisionada y la demanda actual? (una resta entre dos familias de series que comparten solo *algunas* labels)

Ninguna de estas es una agregación. Son **operaciones por pares entre dos familias de series temporales**, y toda la dificultad — la parte que falla en producción y aparece en el examen — no es la aritmética. Es el **matching**: dado un vector izquierdo con N series y un vector derecho con M series, qué serie izquierda se empareja con qué serie derecha, y qué pasa con las labels del resultado.

Prometheus no hace un producto cartesiano. Realiza un **join relacional sobre el conjunto de labels**, y si ese join es ambiguo se niega a ejecutar la consulta. Los operadores binarios son, en efecto, la cláusula `JOIN` de PromQL, y `on` / `ignoring` / `group_left` / `group_right` son sus claves de join y sus declaraciones de cardinalidad. Un SRE que no interioriza esto escribe paneles de ratio que silenciosamente devuelven vacío, o reglas de alerta que lanzan `many-to-many matching not allowed` a las 3 de la mañana durante un incidente.

Hay tres familias de operadores binarios, y se comportan de forma distinta respecto al matching y a la salida de labels:

| Familia | Operadores | Resultado en `vector op vector` |
|---|---|---|
| **Aritméticos** | `+  -  *  /  %  ^  atan2` | Valor calculado por pares; **se descarta el nombre de la métrica**; el resultado conserva el conjunto de labels emparejado |
| **De comparación** | `==  !=  >  <  >=  <=` | Filtra (descarta las series que no coinciden) por defecto; con `bool` devuelve `0`/`1` y conserva las series |
| **Lógicos / de conjunto** | `and  or  unless` | Operaciones de conjunto sobre las *series* mismas; solo definidos para `vector op vector` |

---

## 2. Tipos de operandos y los tres regímenes de matching

Toda operación binaria tiene una de tres formas. La forma determina si hay matching o no.

| Izquierda | Derecha | ¿Matching? | Resultado | Notas |
|---|---|---|---|---|
| scalar | scalar | ninguno | scalar | Matemática pura: `4 * 1024` → `4096`. Las comparaciones dan `0`/`1`. |
| vector | scalar | ninguno | vector | Op aplicada a cada elemento. Nombre de métrica **conservado** (aritmética). |
| vector | vector | **sí** | vector | Requiere un join basado en labels. Nombre de métrica **descartado** (aritmética). |

### 2.1 Por qué desaparece el nombre de la métrica

Para la aritmética `vector op vector` y `vector op scalar`, Prometheus descarta `__name__` del resultado, porque `http_requests_total / 60` ya no es `http_requests_total` — es una cantidad derivada tipo rate sin nombre canónico. Esto es deliberado y tiene una consecuencia: **el resultado de una op aritmética es un vector anónimo**. Si después intentás combinarlo de nuevo, hacés el match solo sobre las labels *restantes*. Esta es la fuente más común de la confusión "por qué mi join está vacío".

### 2.2 Vector matching: uno-a-uno

Por defecto, dos operandos vectoriales hacen match **uno-a-uno**: para cada entrada de la izquierda, Prometheus busca exactamente una entrada de la derecha con un **conjunto de labels idéntico**, y produce un resultado. Las entradas sin pareja en el otro lado se descartan del resultado.

Reformulás la clave de join con:

- **`ignoring(<labels>)`** — hace match sobre todas las labels *excepto* las listadas.
- **`on(<labels>)`** — hace match *solo* sobre las labels listadas.

```promql
# Error ratio per (job, instance): numerator and denominator share
# job+instance but differ in `code`, so we must ignore `code`.
sum by (job, instance) (rate(http_requests_total{code=~"5.."}[5m]))
  /
sum by (job, instance) (rate(http_requests_total[5m]))
```

Aquí los dos resultados de `sum by (job, instance)` ya llevan solo `job` e `instance`, de modo que los conjuntos de labels son idénticos y el match uno-a-uno es exacto — no hace falta `on`/`ignoring`. Este es el patrón canónico: **agregá ambos lados al mismo conjunto de labels primero, y después dividí.** Sortea casi todos los problemas de matching.

### 2.3 Vector matching: muchos-a-uno y uno-a-muchos

Cuando los dos lados tienen **cardinalidad diferente** — muchas series de un lado comparten una sola serie del otro — debés declararlo explícitamente, o Prometheus aborta. `group_left` / `group_right` nombran el **lado "muchos"** y opcionalmente **copian labels adicionales del lado "uno"** al resultado.

```promql
# Requests per pod, joined against the pod's owning deployment info metric.
# Left has one series per (pod); right (kube_pod_info) is the "one" that
# carries `created_by_name`. We copy that label onto every left series.
rate(http_requests_total[5m])
  * on (pod, namespace) group_left (created_by_name)
kube_pod_info
```

- `group_left(labels)`  → **el lado izquierdo es muchos**, el derecho es uno; las `labels` se traen de la **derecha**.
- `group_right(labels)` → **el lado derecho es muchos**, el izquierdo es uno; las `labels` se traen de la **izquierda**.

Las labels dentro de `group_left(...)` son *aditivas*: extienden el conjunto de labels del resultado con valores del lado "uno". Así es como decorás una métrica de alta cardinalidad con metadatos (owner, team, tier) de una métrica tipo info.

| Situación | Construcción | Lado "muchos" | Las labels extra vienen de |
|---|---|---|---|
| Ambos lados con conjunto de labels idéntico | *(ninguna)* | — | — |
| Match sobre un subconjunto | `on(...)` / `ignoring(...)` | — | — |
| La izquierda tiene mayor cardinalidad | `group_left(...)` | izquierda | derecha (el "uno") |
| La derecha tiene mayor cardinalidad | `group_right(...)` | derecha | izquierda (el "uno") |

**Muchos-a-muchos nunca está permitido.** Si, tras aplicar `on`/`ignoring`, una sola serie izquierda hace match con múltiples series derechas *y* viceversa, Prometheus falla la consulta. El arreglo es siempre hacer que un lado sea único sobre la clave de join (normalmente agregándolo).

### 2.4 Operadores lógicos / de conjunto

Estos operan sobre la *presencia* de series, no sobre sus valores, y solo están definidos para `vector op vector`. El matching es uno-a-uno sobre el conjunto de labels completo (ajustable con `on`/`ignoring`).

| Operador | Semántica | Valores / labels del resultado |
|---|---|---|
| `and` (intersección) | Series izquierdas que tienen una serie coincidente en la derecha | Valores y labels de la **izquierda** |
| `or` (unión) | Todas las series izquierdas, más las series derechas sin match izquierdo | Valores/labels respectivos |
| `unless` (complemento) | Series izquierdas que **no** tienen serie coincidente en la derecha | Valores y labels de la **izquierda** |

```promql
# Instances that are up but currently serving zero traffic — a "dark" endpoint.
(up == 1) unless (rate(http_requests_total[5m]) > 0)
```

`and`/`unless` nunca cambian valores; filtran qué series sobreviven. Esto los hace la herramienta correcta para el **alerting condicional** ("dispará esto solo cuando *además* aquello").

---

## 3. Operadores de comparación: filtro vs. `bool`

Los operadores de comparación tienen dos modos, y la diferencia es central tanto para el alerting como para los dashboards.

### 3.1 Modo por defecto (de filtrado)

`vector > scalar` **elimina** toda serie cuyo valor no supera la comparación y conserva las series supervivientes **con su valor original**. Esto es lo que hace que una expresión de alerta dispare solo sobre las series que incumplen:

```promql
# Only instances whose 5xx ratio exceeds 5% survive — each with its real ratio.
sum by (instance) (rate(http_requests_total{code=~"5.."}[5m]))
  /
sum by (instance) (rate(http_requests_total[5m]))
  > 0.05
```

### 3.2 Modificador `bool`

Prefijar el operador con `bool` cambia el resultado a `0` (falso) o `1` (verdadero) **para cada serie de entrada**, conservándolas todas. Usalo cuando necesitás una serie-señal booleana en lugar de un filtro — p. ej. contar cuántas instancias incumplen, o graficar una función escalón.

```promql
# 1 when the instance is over budget, 0 otherwise — for every instance.
(rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m]))
  > bool 0.05

# How many instances are currently breaching?
count(
  (rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m]))
    > bool 0.05
)
```

Para las comparaciones **scalar `op` scalar**, `bool` es **obligatorio** — un `2 > 1` pelado es un error de parseo, porque una comparación de scalars debe resolver a un valor, y Prometheus te obliga a decirlo con `bool`.

| Necesidad | Usá | Resultado |
|---|---|---|
| Alertar solo sobre las series que incumplen | comparación pelada | vector filtrado, valores reales |
| Señal booleana para todas las series | comparación con `bool` | cada serie → `0` / `1` |
| Comparar dos scalars | `bool` **obligatorio** | `0` / `1` |
| Contar incumplimientos | `count(... > bool ...)` | conteo scalar |

---

## 4. Precedencia y asociatividad de operadores

Los operadores binarios ligan en un orden fijo. Equivocarse en esto cambia silenciosamente el significado de una expresión — `a / b * 100` es `(a / b) * 100` (correcto para un porcentaje), pero `a + b / c` es `a + (b / c)`.

**Precedencia, de mayor a menor:**

| Nivel | Operadores | Asociatividad |
|---|---|---|
| 1 | `^` | **derecha** |
| 2 | `*  /  %  atan2` | izquierda |
| 3 | `+  -` | izquierda |
| 4 | `==  !=  <=  <  >=  >` | izquierda |
| 5 | `and  unless` | izquierda |
| 6 | `or` | izquierda |

La asociatividad a derecha de `^` significa que `2 ^ 3 ^ 2` = `2 ^ (3 ^ 2)` = `2^9` = `512`, **no** `64`. Ante la duda, poné paréntesis — el PromQL de producción nunca debería depender de que el lector recuerde esta tabla.

```promql
# WRONG: precedence makes this  cache_hits + (cache_misses/anything) ...
# Always parenthesize ratios:
100 * (
  rate(cache_hits_total[5m])
  /
  (rate(cache_hits_total[5m]) + rate(cache_misses_total[5m]))
)
```

---

## 5. Manifiestos de producción

### 5.1 Configuración de scrape + rules de Prometheus

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: api
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: api
        action: keep
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

### 5.2 Recording rules — precalcular los joins

Las expresiones de ratio y de join son caras en tiempo de consulta y se reevalúan en cada refresco del dashboard. Horneálas en recording rules para que la operación binaria corra **una vez por intervalo de evaluación**, y Grafana lea una única serie barata.

```yaml
# /etc/prometheus/rules/slo.yml
groups:
  - name: slo-ratios
    interval: 30s
    rules:
      # ---- 5xx error ratio per service (vector / vector, one-to-one) ----
      - record: job:http_error_ratio:ratio5m
        expr: |
          sum by (job, namespace) (rate(http_requests_total{code=~"5.."}[5m]))
            /
          sum by (job, namespace) (rate(http_requests_total[5m]))

      # ---- Decorate with team ownership (many-to-one, group_left) ----
      - record: job:http_error_ratio:ratio5m:owned
        expr: |
          job:http_error_ratio:ratio5m
            * on (namespace) group_left (team)
          namespace_ownership_info

      # ---- Memory headroom as a fraction of the limit ----
      - record: pod:memory_utilization:ratio
        expr: |
          container_memory_working_set_bytes{container!=""}
            /
          on (namespace, pod, container)
          kube_pod_container_resource_limits{resource="memory"}
```

### 5.3 Alerting rules — comparación + operadores de conjunto

```yaml
# /etc/prometheus/rules/alerts.yml
groups:
  - name: slo-alerts
    rules:
      # Comparison in filtering mode: only breaching services survive.
      - alert: HighErrorRatio
        expr: job:http_error_ratio:ratio5m:owned > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.job }} error ratio {{ $value | humanizePercentage }} (team {{ $labels.team }})"

      # `unless`: pod is over its memory limit ratio AND not being throttled
      # away by an already-firing OOM alert (set complement).
      - alert: MemoryPressure
        expr: |
          (pod:memory_utilization:ratio > 0.90)
            unless
          (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
        for: 5m
        labels:
          severity: warning

      # Set intersection: instance is up AND its scrape target is stale.
      - alert: StaleButUp
        expr: |
          (up == 1)
            and
          (time() - process_start_time_seconds > 0)  # placeholder guard
            and
          (rate(http_requests_total[5m]) == 0)
        for: 15m
        labels:
          severity: warning
```

---

## 6. CLI: comandos reales y salida esperada

### 6.1 Validar las rules antes de enviarlas

```console
$ promtool check rules /etc/prometheus/rules/slo.yml /etc/prometheus/rules/alerts.yml
Checking /etc/prometheus/rules/slo.yml
  SUCCESS: 3 rules found
Checking /etc/prometheus/rules/alerts.yml
  SUCCESS: 3 rules found
```

### 6.2 Evaluar una instant query con `promtool`

```console
$ promtool query instant http://localhost:9090 \
    'sum by (job)(rate(http_requests_total{code=~"5.."}[5m])) / sum by (job)(rate(http_requests_total[5m]))'
{job="api"} => 0.032258064516129 @[1754640000]
{job="checkout"} => 0.114285714285714 @[1754640000]
{job="static"} => 0 @[1754640000]
```

Fijate que el resultado no lleva **ningún `__name__`** — la aritmética lo descartó — y solo sobrevivió la label `job`, porque ambos lados fueron agregados `by (job)`.

### 6.3 El modificador `bool`, visto en la API

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=(rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m])) > bool 0.05' \
  | jq '.data.result[] | {instance: .metric.instance, breach: .value[1]}'
{
  "instance": "10.1.4.7:8080",
  "breach": "0"
}
{
  "instance": "10.1.4.9:8080",
  "breach": "1"
}
```

Cada serie de entrada se retiene; el valor es el booleano. Quitá `bool` y solo aparecería `10.1.4.9:8080`, llevando su ratio real.

### 6.4 Reproducir una falla de matching a propósito

```console
$ promtool query instant http://localhost:9090 \
    'container_memory_working_set_bytes / kube_pod_container_resource_limits'
Error executing query: found duplicate series for the match group
{namespace="prod", pod="api-7c9", container="api"} on the right hand-side of
the operation: [...]; many-to-many matching not allowed: matching labels must
be unique on one side
```

El lado derecho tiene labels extra (`resource`, `unit`) que hacen que varias series colisionen sobre la misma clave de join. El arreglo es §2.3: acotar y fijar el join.

```console
$ promtool query instant http://localhost:9090 \
    'container_memory_working_set_bytes{container!=""}
       / on (namespace,pod,container)
     kube_pod_container_resource_limits{resource="memory"}'
{namespace="prod", pod="api-7c9", container="api"} => 0.734 @[1754640000]
```

---

## 7. Verificación y diagnóstico de fallas

| Síntoma | Causa raíz | Diagnóstico | Arreglo |
|---|---|---|---|
| La consulta devuelve **vector vacío** | Los conjuntos de labels difieren, así que el match uno-a-uno no encuentra parejas | Corré cada lado por separado; comparí los conjuntos de labels con `count by(__name__)(...)` o inspeccioná en el expression browser | Agregá ambos lados al mismo conjunto de labels, o añadí `on()`/`ignoring()` |
| `many-to-many matching not allowed` | Labels extra hacen que la clave de join no sea única en ambos lados | Mirá qué labels difieren entre los lados | Añadí `on(<join-keys>)`, y/o filtrá un lado para que sea único |
| `multiple matches for labels ... group_left/right` | El lado "uno" declarado en realidad tiene múltiples series por clave | El lado "uno" no es único | Agregá el lado "uno" (`max/min/sum by(...)`) o ajustá su selector |
| Ratio **> 1** o negativo | El numerador y el denominador no provienen de la misma población, o un reset de counter dentro de una resta sin `rate` | Comparí las series del numerador/denominador individualmente | Usá `rate()` en ambos; asegurate de que numerador ⊆ denominador |
| El panel de porcentaje muestra `0` en todos lados | Se dejó `bool` por accidente, o la precedencia convirtió el ratio en `a + b/c` | Leé el árbol de la expresión; buscá un `bool` extraviado | Quitá `bool`; poné paréntesis |
| El nombre de la métrica desaparece inesperadamente aguas abajo | Una op aritmética descartó `__name__`; un `on(__name__)` posterior ahora falla | Consultá el resultado intermedio | Hacé match sobre labels reales, no sobre `__name__`; usá recording rules para nombrarlo |
| Comparación de scalars rechazada en el parseo | `x > y` pelado donde ambos son scalars | Error de `promtool check` / de parseo | Añadí `bool`: `x > bool y` |

**Flujo de diagnóstico para cualquier join que falle:**

1. **Partilo.** Corré los operandos izquierdo y derecho como consultas separadas.
2. **Comparí los conjuntos de labels.** `sum without()(<left>)` vs `<right>` en el browser, o `count by (<join-key>) (<side>)` — cualquier conteo `> 1` en el lado "uno" es tu bug.
3. **Fijá la clave.** Añadí `on(<claves de join explícitas>)`; nunca dependas del matching implícito de labels completo en producción.
4. **Declará la cardinalidad.** Si un lado es legítimamente muchos, añadí `group_left`/`group_right` nombrando el lado muchos.
5. **Nombrá el resultado.** Promové la expresión que funciona a una recording rule para que las consultas aguas abajo nunca vuelvan a rederivar el join.

```console
# Step 2 in practice — is the "one" side actually unique on the key?
$ promtool query instant http://localhost:9090 \
    'count by (namespace, pod, container) (kube_pod_container_resource_limits{resource="memory"})'
{namespace="prod", pod="api-7c9", container="api"} => 1 @[1754640000]
{namespace="prod", pod="api-7c9", container="istio-proxy"} => 1 @[1754640000]
# Every count is 1 → the key is unique → the join is safe.
```

---

## 8. Referencias

- **CNCF Prometheus Certified Associate — Curriculum:** https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- **PromQL — Operators (binary operators, vector matching, precedence):** https://prometheus.io/docs/prometheus/latest/querying/operators/
- **PromQL — Basics (expression language data types, selectors):** https://prometheus.io/docs/prometheus/latest/querying/basics/
- **PromQL — Query examples (ratios, joins):** https://prometheus.io/docs/prometheus/latest/querying/examples/
- **Recording rules:** https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- **Alerting rules:** https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- **HTTP API — `/api/v1/query` (instant queries):** https://prometheus.io/docs/prometheus/latest/querying/api/
- **`promtool` (rule checking and query CLI):** https://github.com/prometheus/prometheus/blob/main/docs/command-line/promtool.md