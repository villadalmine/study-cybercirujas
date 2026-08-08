# Ejercicios guiados — Tema 6.2: DORA Metrics and Indicators for Platform Initiatives

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) — versión 2025-04-01
> **Peso en el examen:** 4.0
> **Fuente del temario:** [CNCF Curriculum — CNPA](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

Estos ejercicios te llevan del **dato crudo** (deployments, commits, incidentes) hasta la **decisión de plataforma**: calcular las cuatro métricas DORA, clasificar el rendimiento, instrumentarlas con eventos y consultarlas en Prometheus, y —lo más importante para un Platform Engineer— usarlas como *indicadores de una iniciativa de plataforma* sin caer en la ley de Goodhart.

**Idea central del tema.** Las métricas DORA son *lagging indicators* (indicadores de resultado) de todo el sistema de entrega de software. Una plataforma interna (IDP, golden paths, self-service) no aparece directamente en ellas: aparece a través del efecto que produce en los equipos que la adoptan. Por eso un Platform Team las combina con *leading indicators* propios (adopción, developer experience) y siempre las lee con un **grupo de control** y una **línea base**.

## Requisitos previos

Necesitás una shell POSIX con estas herramientas. Verificá:

```bash
jq --version        # >= 1.6  (cálculo de métricas)
git --version       # cualquier versión reciente
promtool --version  # opcional, para validar PromQL (viene con Prometheus)
```

Salida esperada (versiones a modo de ejemplo):

```
jq-1.7.1
git version 2.45.2
promtool, version 2.53.0
```

---

## Ejercicio 1 — Calcular las cuatro métricas DORA desde datos crudos

Vas a partir del registro de deployments de un servicio (`orders`) durante una ventana de **14 días** y a derivar las cuatro métricas a mano, para entender *qué mide cada una* antes de automatizarla.

Las cuatro métricas ([dora.dev/guides/dora-metrics-four-keys](https://dora.dev/guides/dora-metrics-four-keys/)):

| Métrica | Qué mide | Familia |
|---|---|---|
| **Deployment Frequency (DF)** | Con qué frecuencia se despliega a producción | *Throughput* |
| **Lead Time for Changes (LT)** | Tiempo desde el commit hasta que corre en producción | *Throughput* |
| **Change Failure Rate (CFR)** | % de deployments que degradan el servicio y requieren remediación | *Stability* |
| **Failed Deployment Recovery Time (FDRT)** | Cuánto se tarda en recuperarse de un deployment fallido | *Stability* |

> **Nota terminológica (la toman en el examen):** en el *State of DevOps Report 2023*, DORA renombró *Mean Time to Restore (MTTR)* como **Failed Deployment Recovery Time**, porque mide específicamente la recuperación ante un **fallo causado por un deployment**, no ante cualquier incidente. Fuente: [dora.dev/research/2024/dora-report](https://dora.dev/research/2024/dora-report/).

### Pasos

**1.** Creá el dataset de deployments:

```bash
cat > deployments.json <<'JSON'
[
  {"id":"d1","first_commit_at":"2026-07-01T08:00:00Z","deployed_at":"2026-07-01T12:00:00Z","caused_failure":false},
  {"id":"d2","first_commit_at":"2026-07-02T09:00:00Z","deployed_at":"2026-07-03T09:00:00Z","caused_failure":false},
  {"id":"d3","first_commit_at":"2026-07-04T10:00:00Z","deployed_at":"2026-07-04T16:00:00Z","caused_failure":true,"recovery_seconds":1800},
  {"id":"d4","first_commit_at":"2026-07-06T08:00:00Z","deployed_at":"2026-07-06T20:00:00Z","caused_failure":false},
  {"id":"d5","first_commit_at":"2026-07-08T09:00:00Z","deployed_at":"2026-07-09T09:00:00Z","caused_failure":false},
  {"id":"d6","first_commit_at":"2026-07-10T09:00:00Z","deployed_at":"2026-07-10T13:00:00Z","caused_failure":true,"recovery_seconds":5400},
  {"id":"d7","first_commit_at":"2026-07-12T09:00:00Z","deployed_at":"2026-07-12T11:00:00Z","caused_failure":false}
]
JSON
```

**2.** Definí una función `median` reutilizable (correcta para conteos pares e impares) y calculá **Deployment Frequency** sobre la ventana de 14 días:

```bash
jq -n --slurpfile d deployments.json '
  ($d[0]|length) as $n
  | {deployments: $n, per_day: ($n/14), per_week: ($n/14*7)}'
```

Salida esperada:

```json
{
  "deployments": 7,
  "per_day": 0.5,
  "per_week": 3.5
}
```

**3.** Calculá **Lead Time for Changes** como la **mediana** de `deployed_at − first_commit_at` (en segundos, luego en horas):

```bash
jq '
  def median: sort
    | if length==0 then null
      elif length%2==1 then .[(length/2)|floor]
      else (.[length/2-1] + .[length/2])/2 end;
  [ .[] | (.deployed_at|fromdateiso8601) - (.first_commit_at|fromdateiso8601) ]
  | median
  | {lead_time_seconds: ., lead_time_hours: (./3600)}' deployments.json
```

Salida esperada:

```json
{
  "lead_time_seconds": 21600,
  "lead_time_hours": 6
}
```

**4.** Calculá **Change Failure Rate** (deployments con `caused_failure=true` sobre el total):

```bash
jq '
  (map(select(.caused_failure)) | length) as $fail
  | (length) as $total
  | {failed: $fail, total: $total, cfr_percent: ($fail/$total*100)}' deployments.json
```

Salida esperada:

```json
{
  "failed": 2,
  "total": 7,
  "cfr_percent": 28.57142857142857
}
```

**5.** Calculá **Failed Deployment Recovery Time** como la mediana de `recovery_seconds` **solo sobre los deployments que fallaron**:

```bash
jq '
  def median: sort
    | if length==0 then null
      elif length%2==1 then .[(length/2)|floor]
      else (.[length/2-1] + .[length/2])/2 end;
  [ .[] | select(.caused_failure) | .recovery_seconds ]
  | median
  | {fdrt_seconds: ., fdrt_minutes: (./60)}' deployments.json
```

Salida esperada:

```json
{
  "fdrt_seconds": 3600,
  "fdrt_minutes": 60
}
```

### Preguntas de comprensión — Ejercicio 1

1. En el paso 3 usamos la **mediana** y no el **promedio** para Lead Time. ¿Por qué la mediana es el estadístico correcto para las métricas DORA de tiempo?
2. El Lead Time DORA arranca en el **primer commit**, no en la apertura del ticket ni en el merge del PR. ¿Qué parte del ciclo de entrega queda deliberadamente *excluida* de esta definición y por qué importa esa frontera?
3. Un compañero propone contar en el CFR también un incidente causado por una caída del proveedor de nube (no por un deployment). Según la definición de DORA, ¿ese incidente entra en el CFR? Justificá.
4. El servicio `orders` tiene **Lead Time = 6 h** (excelente) pero **CFR = 28,6 %** (pobre). ¿Qué te dice esa combinación sobre el sistema de entrega, y qué hipótesis de causa investigarías primero?

---

## Ejercicio 2 — Clasificar el rendimiento en clusters (Elite / High / Medium / Low)

DORA agrupa a los equipos en cuatro *performance clusters* mediante análisis de conglomerados sobre los resultados de la encuesta anual. Los umbrales se **recalculan cada año** (no son constantes), pero esta tabla de referencia —representativa del *Accelerate State of DevOps Report*— es la que se usa para ubicar a un equipo de un vistazo:

| Métrica | **Elite** | **High** | **Medium** | **Low** |
|---|---|---|---|---|
| Deployment Frequency | On-demand (varias/día) | 1/día – 1/semana | 1/semana – 1/mes | 1/mes – 1/6 meses |
| Lead Time for Changes | < 1 día | 1 día – 1 semana | 1 semana – 1 mes | 1 – 6 meses |
| Change Failure Rate | 0–15 % | 16–30 % | 16–30 % | 16–30 % |
| Failed Deployment Recovery Time | < 1 hora | < 1 día | 1 día – 1 semana | > 6 meses |

> Fuente: [dora.dev/research](https://dora.dev/research/) — verificá siempre el reporte del año vigente; en el reporte 2024, por ejemplo, el CFR de los Elite ronda el ~5 %. Podés autoclasificarte con el [DORA Quick Check](https://dora.dev/quickcheck/).

### Pasos

**1.** Recuperá los cuatro valores calculados para `orders` en el Ejercicio 1:

```
Deployment Frequency ....... 3,5 deploys/semana  (~1 cada 2 días)
Lead Time (mediana) ........ 6 horas
Change Failure Rate ........ 28,6 %
Failed Deployment Recovery . 60 minutos (mediana)
```

**2.** Ubicá **cada métrica por separado** en la tabla de clusters. No promedies las cuatro: DORA clasifica métrica por métrica y luego observa el patrón.

**3.** Anotá el cluster de cada métrica en una tabla como esta y completala:

```
| Métrica          | Valor orders | Cluster |
|------------------|--------------|---------|
| Deployment Freq. | 3,5/semana   | ?       |
| Lead Time        | 6 h          | ?       |
| Change Fail Rate | 28,6 %       | ?       |
| Recovery Time    | 60 min       | ?       |
```

### Preguntas de comprensión — Ejercicio 2

1. Completá la tabla del paso 3. ¿En qué cluster cae cada una de las cuatro métricas de `orders`?
2. Las métricas de `orders` no caen todas en el mismo cluster. ¿Es correcto entonces decir "`orders` es un equipo High"? ¿Cómo reportarías su rendimiento de forma honesta?
3. Un hallazgo central de la investigación DORA es que *throughput* y *stability* **no son un trade-off**: los equipos Elite son buenos en las dos familias a la vez. ¿Qué implica ese hallazgo para el caso de `orders`, que tiene throughput alto pero estabilidad de nivel Medium/Low?
4. ¿Por qué es un error de plataforma fijar como objetivo del equipo "llegar a Elite en Deployment Frequency" de forma aislada?

---

## Ejercicio 3 — Instrumentar DORA con eventos y consultarla en Prometheus

Calcular a mano no escala. En una plataforma real, cada etapa de entrega **emite un evento** y un colector deriva las métricas. Vas a modelar el flujo con **CDEvents** (el estándar CNCF/CDF para eventos de CI/CD, [cdevents.dev](https://cdevents.dev/)) y a expresar las cuatro métricas como **PromQL** sobre las series que ese colector expone.

### Pasos

**1.** Observá el evento que emite tu pipeline cuando un deployment llega a producción (CDEvent `service.deployed`):

```json
{
  "context": {
    "version": "0.4.1",
    "id": "271069a8-fc18-44f1-b38f-9d70a1695819",
    "source": "/argocd/prod",
    "type": "dev.cdevents.service.deployed.0.2.0",
    "timestamp": "2026-07-12T11:00:00Z"
  },
  "subject": {
    "id": "orders",
    "type": "service",
    "content": {
      "environment": {"id": "production"},
      "artifactId": "pkg:oci/orders@sha256:9f8e...",
      "outcome": "success"
    }
  }
}
```

**2.** Definí el **mapa evento → métrica DORA**. Esta correspondencia es la que se toma en el examen:

```
service.deployed (environment=production)          -> Deployment Frequency
service.deployed.timestamp − change.first_commit   -> Lead Time for Changes
incident.detected  ligado a un deployment          -> Change Failure Rate (numerador)
incident.resolved.timestamp − incident.detected    -> Failed Deployment Recovery Time
```

**3.** Suponé que el colector expone estas series de Prometheus:

```
deploys_total{service, environment, result}          # counter
deploy_lead_time_seconds_bucket{service, le}         # histogram
deploy_recovery_seconds_bucket{service, le}          # histogram (solo deploys fallidos)
```

**4.** Escribí y validá las cuatro consultas PromQL. **Deployment Frequency** (deploys a prod por día, ventana 7 días):

```promql
sum(increase(deploys_total{environment="production"}[7d])) / 7
```

**5. Change Failure Rate** (fallidos sobre total, ventana 30 días):

```promql
  sum(increase(deploys_total{environment="production", result="failure"}[30d]))
/ sum(increase(deploys_total{environment="production"}[30d]))
```

**6. Lead Time p50** (mediana, desde el histograma, ventana 30 días):

```promql
histogram_quantile(
  0.5,
  sum(rate(deploy_lead_time_seconds_bucket{environment="production"}[30d])) by (le)
)
```

**7. Failed Deployment Recovery Time p50**:

```promql
histogram_quantile(
  0.5,
  sum(rate(deploy_recovery_seconds_bucket[30d])) by (le)
)
```

**8.** Validá la sintaxis de una de ellas sin un servidor corriendo:

```bash
promtool check rules <(cat <<'YAML'
groups:
- name: dora
  rules:
  - record: dora:change_failure_rate:ratio30d
    expr: |
      sum(increase(deploys_total{environment="production", result="failure"}[30d]))
      / sum(increase(deploys_total{environment="production"}[30d]))
YAML
)
```

Salida esperada:

```
Checking <(...)
  SUCCESS: 1 rules found
```

### Preguntas de comprensión — Ejercicio 3

1. En el paso 4, ¿por qué se usa `increase()` sobre el counter y no `rate()` directamente para reportar "deploys por día"? ¿Qué pasaría con la interpretación si usaras `rate()`?
2. El Lead Time se modela como un **histogram** y no como un **gauge** con el último valor. ¿Qué propiedad de las métricas DORA hace que el histograma (y `histogram_quantile`) sea la representación correcta?
3. La familia `deploy_recovery_seconds_bucket` solo recibe muestras de deployments que fallaron. Si en 30 días no hubo ningún fallo, ¿qué devuelve `histogram_quantile` en el paso 7 y cómo debería tratarlo el dashboard?
4. Ventaja de derivar DORA desde **CDEvents estandarizados** en vez de parsear logs de cada herramienta (Jenkins, GitHub Actions, Argo CD) por separado. Nombrá dos.

---

## Ejercicio 4 — Medir el impacto de una iniciativa de plataforma (before/after + control)

Acá está el corazón del tema *"…for Platform Initiatives"*. El Platform Team lanzó un **golden path** (template + pipeline dorado + self-service en el portal) y quiere saber si movió la aguja. La trampa clásica: mirar solo el "antes vs. después" del cohorte que adoptó, y atribuirle a la plataforma cambios que hubieran ocurrido igual. La técnica correcta es **difference-in-differences** con un **grupo de control**.

### Pasos

**1.** Cargá las métricas agregadas de dos cohortes, medidas 90 días antes y 90 días después del lanzamiento:

```bash
cat > cohorts.json <<'JSON'
{
  "treatment": {
    "description": "12 equipos onboardeados al golden path",
    "before": {"df_per_week": 1.2, "lead_time_h": 72, "cfr_pct": 18, "fdrt_h": 5.0},
    "after":  {"df_per_week": 4.5, "lead_time_h": 20, "cfr_pct": 22, "fdrt_h": 3.0}
  },
  "control": {
    "description": "12 equipos comparables, NO onboardeados",
    "before": {"df_per_week": 1.1, "lead_time_h": 70, "cfr_pct": 17, "fdrt_h": 5.0},
    "after":  {"df_per_week": 1.3, "lead_time_h": 66, "cfr_pct": 17, "fdrt_h": 4.8}
  }
}
JSON
```

**2.** Calculá el delta simple (after − before) de cada cohorte:

```bash
jq '
  def delta(c): {
    df: (c.after.df_per_week - c.before.df_per_week),
    lead: (c.after.lead_time_h - c.before.lead_time_h),
    cfr: (c.after.cfr_pct - c.before.cfr_pct),
    fdrt: (c.after.fdrt_h - c.before.fdrt_h)
  };
  {treatment: delta(.treatment), control: delta(.control)}' cohorts.json
```

Salida esperada:

```json
{
  "treatment": { "df": 3.3, "lead": -52, "cfr": 4, "fdrt": -2 },
  "control":   { "df": 0.2, "lead": -4,  "cfr": 0, "fdrt": -0.2 }
}
```

**3.** Calculá el efecto **atribuible a la plataforma** = (delta treatment − delta control), *difference-in-differences*:

```bash
jq '
  def delta(c): {
    df: (c.after.df_per_week - c.before.df_per_week),
    lead: (c.after.lead_time_h - c.before.lead_time_h),
    cfr: (c.after.cfr_pct - c.before.cfr_pct),
    fdrt: (c.after.fdrt_h - c.before.fdrt_h)
  };
  (delta(.treatment)) as $t | (delta(.control)) as $c
  | {did_df: ($t.df - $c.df),
     did_lead: ($t.lead - $c.lead),
     did_cfr: ($t.cfr - $c.cfr),
     did_fdrt: ($t.fdrt - $c.fdrt)}' cohorts.json
```

Salida esperada:

```json
{
  "did_df": 3.1,
  "did_lead": -48,
  "did_cfr": 4,
  "did_fdrt": -1.8
}
```

**4.** Interpretá el vector resultante: throughput subió fuerte (**+3,1 deploys/semana**, **−48 h de lead time**), recovery mejoró (**−1,8 h**), pero el **CFR subió +4 puntos** *por encima* de lo que hizo el control.

### Preguntas de comprensión — Ejercicio 4

1. El cohorte *treatment* mejoró su Lead Time en 52 h; el *control* mejoró 4 h en el mismo período sin tocar la plataforma. ¿Qué representan esos 4 h del control y por qué restarlos (difference-in-differences) da una atribución más honesta que el "before/after" a secas?
2. El *State of DevOps Report 2024* encontró que adoptar plataform engineering **aumenta el throughput** pero puede **degradar la estabilidad** si la plataforma no es confiable. Tu resultado (CFR +4) es coherente con eso. ¿Cancela ese aumento de CFR el éxito de la iniciativa? ¿Con qué criterio lo decidirías?
3. Uno de los 12 equipos empezó a trocear cada cambio en 5 micro-deployments para "subir la Deployment Frequency" de cara al reporte trimestral. ¿Qué falla de medición es esta y cómo se llama el principio general que la describe?
4. ¿Qué habrías necesitado registrar **antes** de lanzar el golden path para que este análisis fuera posible, y por qué el CLAUDE.md/WORKFLOW de una plataforma insiste en "establecer la línea base primero"?

---

## Ejercicio 5 — Leading vs. lagging indicators: DORA dentro del tablero de la plataforma

Las cuatro métricas DORA son *lagging* (miden el resultado ya ocurrido). Para operar una plataforma **como producto** necesitás también *leading indicators* que se muevan **antes**: adopción, tiempo hasta el primer deploy, y developer experience (marcos como **SPACE** y **DevEx**). DORA sola no te dice *si tu plataforma* está funcionando; te dice si *el sistema de entrega* mejoró.

### Pasos

**1.** Tenés esta lista de métricas candidatas para el dashboard del Platform Team:

```
a. Deployment Frequency (agregada por cohorte)
b. % de servicios creados vía golden path template (adopción)
c. Change Failure Rate
d. Time-to-first-deploy de un servicio nuevo (onboarding)
e. Failed Deployment Recovery Time
f. Developer satisfaction / NPS interno del portal (SPACE: Satisfaction)
g. Lead Time for Changes
h. Nº de tickets de soporte al Platform Team por semana
i. % de pipelines que corren la versión dorada del pipeline (drift)
```

**2.** Clasificá cada una como **DORA (lagging / outcome)**, **Leading (adoption/onboarding)** o **DevEx/SPACE (experiencia)**.

**3.** Elegí **una North Star metric** para el Platform Team y justificá por qué esa y no una métrica DORA cruda. Pista: debe combinar *adopción* con *resultado*, para que nadie pueda "ganarla" degradando la otra mitad.

**4.** Ubicá la **quinta métrica** de DORA, **Reliability** (operational performance: cumplimiento de objetivos de disponibilidad/latencia, [dora.dev](https://dora.dev/)), en tu tablero y decidí de qué familia es.

### Preguntas de comprensión — Ejercicio 5

1. Completá la clasificación del paso 2 para las nueve métricas (a–i).
2. ¿Por qué un dashboard que muestra **solo** las cuatro métricas DORA es insuficiente para dirigir una *iniciativa de plataforma*? Da un escenario donde DORA mejora a nivel org pero la plataforma en realidad está fracasando (baja adopción).
3. La adopción (métrica **b**) es *leading* respecto de DORA: si sube hoy, DORA debería moverse en las próximas semanas. ¿Qué acción tomarías si la adopción sube pero DORA de los adoptantes **no** mejora a los 90 días?
4. ¿Por qué Reliability se agregó como quinta métrica y qué mide que las otras cuatro (todas centradas en *deployments*) dejan afuera?

---

## Respuestas

<details>
<summary>Mostrar/ocultar soluciones y justificaciones</summary>

### Ejercicio 1

1. **Mediana vs. promedio.** Las distribuciones de lead time y recovery time son fuertemente **asimétricas de cola larga** (long-tail): un puñado de cambios se demoran días por revisiones o incidentes raros. El promedio es arrastrado por esos outliers y sobrestima el tiempo "típico"; la mediana (p50) describe la experiencia habitual y es robusta a valores extremos. Por eso DORA reporta medianas/percentiles, no medias.
2. **Frontera del Lead Time.** Empieza en el **primer commit del cambio de código** y termina cuando ese cambio **corre en producción**. Queda deliberadamente afuera todo lo anterior al código: descubrimiento, priorización, diseño, escritura del ticket. Importa porque DORA mide la eficiencia del **camino de entrega técnico** (build → test → deploy), que es exactamente lo que una plataforma puede acelerar; mezclar el tiempo de producto/discovery contaminaría la señal que la plataforma controla.
3. **Caída del proveedor ≠ CFR.** No entra. El CFR cuenta **solo deployments** que degradan el servicio y requieren remediación (rollback, hotfix, patch). Un incidente originado por una falla de infraestructura del cloud sin un deployment detrás no es un *change failure*; iría, si acaso, contra la métrica de **Reliability** (5.ª métrica), no contra el CFR. Confundirlas infla el CFR y castiga al equipo por algo que no cambió.
4. **Lead Time excelente + CFR pobre.** Indica un sistema que **entrega rápido pero sin suficiente red de seguridad**: falta cobertura de tests, o hay pocos deployments progresivos (canary/blue-green), o no hay verificación automática post-deploy. La velocidad está exponiendo defectos a producción en vez de atajarlos antes. Primera hipótesis a investigar: **calidad de la etapa de verificación** (¿qué % de deploys pasa por tests de integración / gates automáticos?), porque el remedio (mejorar los gates del pipeline dorado) baja el CFR sin sacrificar el lead time.

### Ejercicio 2

1. **Clasificación por métrica de `orders`:**

   | Métrica | Valor | Cluster |
   |---|---|---|
   | Deployment Frequency | 3,5/semana (~1 cada 2 días) | **High** (entre 1/día y 1/semana) |
   | Lead Time | 6 h | **Elite** (< 1 día) |
   | Change Failure Rate | 28,6 % | **Medium/Low** (16–30 %) |
   | Recovery Time | 60 min | **High** (< 1 día; borde de Elite <1 h) |

2. **"¿Es un equipo High?"** No de forma limpia: las métricas caen en clusters distintos (Elite / High / Medium-Low / High). Lo honesto es reportar **las cuatro por separado** con su cluster, señalando el patrón: *throughput* fuerte (LT Elite, DF High) y *stability* rezagada (CFR Medium/Low). Colapsar todo en una sola etiqueta oculta justamente el problema accionable.
3. **Throughput y stability no son trade-off.** El hallazgo de DORA es que los Elite logran ambas a la vez; por lo tanto el CFR alto de `orders` **no es el "precio" de su velocidad**, es una deuda de ingeniería aparte. `orders` puede —y debería— mantener su lead time de 6 h y a la vez bajar el CFR a <15 % mejorando testing y despliegues progresivos. Aceptar el CFR como inevitable sería un error conceptual.
4. **Objetivo aislado de DF.** Porque optimizar una sola métrica invita a **gamearla** a costa de las demás (trocear cambios para inflar la frecuencia, saltear tests para acelerar). Las cuatro se leen como **conjunto balanceado** (dos de throughput + dos de stability); subir DF mientras el CFR empeora no es una mejora, es un traslado del problema.

### Ejercicio 3

1. **`increase()` vs `rate()`.** `increase()` devuelve el **conteo total** de deploys en la ventana (una cantidad entera de eventos), que es lo que significa "deploys por día" al dividir por los días. `rate()` devuelve un promedio **por segundo**, un número diminuto y poco interpretable para un evento discreto y esporádico como un deployment. Usar `rate()` te obligaría a multiplicar por 86 400 y suavizaría de más un evento que no es continuo.
2. **Por qué histogram y no gauge.** Las métricas DORA de tiempo se reportan como **percentiles de una distribución** (p50/mediana, a veces p90), no como "el último valor". Un gauge solo retiene la última muestra y pierde la distribución; el histogram acumula todas las observaciones en buckets y permite `histogram_quantile()` para recuperar la mediana sobre la ventana, que es exactamente la definición DORA.
3. **Sin fallos en 30 días.** No hay muestras en `deploy_recovery_seconds_bucket`, así que `histogram_quantile` devuelve **`NaN`** (o ningún resultado). No significa "recovery = 0" ni "recovery infinito": significa **"no hubo fallos que medir"**, la mejor noticia posible. El dashboard debe renderizarlo como *N/A / sin incidentes*, no como 0 ni como un hueco de error.
4. **CDEvents vs parsear logs. Dos ventajas:** (a) **desacoplás** el colector de métricas de la herramienta concreta: cambiar Jenkins por GitHub Actions no reescribe el pipeline de métricas, porque ambos emiten el mismo `dev.cdevents.service.deployed`; (b) **semántica consistente y tipada**: el evento ya trae `environment`, `artifactId` y `outcome` en un esquema versionado, evitando el parsing frágil de texto libre por regex que se rompe en cada actualización de la herramienta.

### Ejercicio 4

1. **El delta del control.** Esos 4 h de mejora del control representan la **tendencia de fondo** que hubiera ocurrido igual sin la plataforma (madurez general del equipo, mejores herramientas del mercado, estacionalidad, etc.). Restarla (difference-in-differences) aísla lo que **solo el treatment vivió** y que el control no: el efecto atribuible al golden path. El "before/after a secas" del treatment le adjudicaría a la plataforma esos 4 h que no le corresponden — sobreestimando el impacto.
2. **CFR +4, ¿cancela el éxito?** No automáticamente. Se decide con un **criterio de guardrail explícito**: el objetivo de la iniciativa era throughput, con el CFR como métrica-guardarraíl que no debe cruzar un umbral (p. ej. "CFR agregado ≤ 15 %"). Si tras el +4 sigue por debajo del umbral, la iniciativa es un éxito neto y se sigue; si lo cruza, se pausa la expansión y se endurecen los gates del pipeline dorado. La regla DORA de fondo: **no se acepta ganar throughput sacrificando stability**, porque los Elite tienen ambas.
3. **Trocear para inflar DF.** Es **gaming de la métrica**: se optimiza el proxy (frecuencia de deploys) en vez del objetivo real (entregar valor con seguridad). El principio general es la **Ley de Goodhart**: *"cuando una medida se convierte en objetivo, deja de ser una buena medida."* Contramedida: mirar las cuatro juntas (el troceo suele empeorar CFR o no mover el lead time real) y nunca usar una métrica DORA individual como objetivo de desempeño de un equipo.
4. **Qué registrar antes.** La **línea base** de las cuatro métricas para *ambos* cohortes (treatment y control) en el período previo. Sin el "before" no hay delta, y sin el control no hay difference-in-differences: quedarías con un after suelto imposible de interpretar. Por eso el flujo de una plataforma exige *snapshot/baseline primero*: una vez lanzada la iniciativa ya no podés reconstruir hacia atrás el estado previo sin la instrumentación puesta de antemano.

### Ejercicio 5

1. **Clasificación (a–i):**

   | # | Métrica | Familia |
   |---|---|---|
   | a | Deployment Frequency | **DORA (lagging/outcome)** |
   | b | % servicios vía golden path | **Leading (adoption)** |
   | c | Change Failure Rate | **DORA (lagging/outcome)** |
   | d | Time-to-first-deploy (onboarding) | **Leading (onboarding)** |
   | e | Failed Deployment Recovery Time | **DORA (lagging/outcome)** |
   | f | Developer satisfaction / NPS del portal | **DevEx/SPACE (Satisfaction)** |
   | g | Lead Time for Changes | **DORA (lagging/outcome)** |
   | h | Tickets de soporte/semana al Platform Team | **DevEx/SPACE (proxy de fricción; leading)** |
   | i | % pipelines en versión dorada (drift) | **Leading (adoption/salud de la plataforma)** |

2. **Solo DORA es insuficiente.** DORA mide el sistema de entrega global, no tu plataforma. **Escenario de fracaso oculto:** la org mejora sus métricas DORA porque un par de equipos fuertes adoptaron mejores prácticas por su cuenta, mientras tu golden path tiene **5 % de adopción** y todos lo evitan. El dashboard DORA se ve verde y aun así la plataforma está fracasando como producto: sin las métricas de adopción (b, i) y de experiencia (f, h) no lo verías.
3. **Adopción sube, DORA no mejora a 90 días.** Es la señal de que la plataforma **se está usando pero no está entregando el resultado prometido**: el golden path puede tener un pipeline lento, gates que fallan o mala DevEx que anula la ganancia. Acción: **investigar la brecha** — cruzar con las métricas SPACE/DevEx (f, h) y con el detalle por etapa del pipeline para encontrar dónde se pierde el beneficio, en vez de seguir empujando adopción de algo que no rinde.
4. **Reliability (5.ª métrica).** Se agregó porque las cuatro clásicas giran todas alrededor del **deployment** (velocidad y seguridad de *cambiar* el software) y no capturan cómo se comporta el servicio **en estado estacionario**, entre deployments: disponibilidad, latencia y cumplimiento de los objetivos de nivel de servicio (SLOs). Reliability mide la **performance operacional** —qué tan bien el servicio cumple sus targets de confiabilidad—, cerrando el hueco entre "entregamos rápido y seguro" y "el servicio efectivamente funciona bien para el usuario". Pertenece a la familia de **stability/operations**.

</details>

---

### Fuentes

- DORA — *DevOps Research and Assessment*: https://dora.dev/ · Guía de las cuatro métricas: https://dora.dev/guides/dora-metrics-four-keys/ · Quick Check: https://dora.dev/quickcheck/
- *Accelerate State of DevOps Report 2024*: https://dora.dev/research/2024/dora-report/
- Google Cloud — proyecto **Four Keys** (implementación de referencia de las métricas DORA): https://github.com/dora-team/fourkeys
- **CDEvents** (CNCF/CDF) — especificación de eventos de entrega continua: https://cdevents.dev/ · https://github.com/cdevents/spec
- **SPACE framework** (Forsgren et al., ACM Queue): https://queue.acm.org/detail.cfm?id=3454124
- CNCF Platforms White Paper / Platform Engineering Maturity Model (TAG App Delivery): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Curriculum — CNPA: https://github.com/cncf/curriculum